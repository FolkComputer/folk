"""One-shot planar quad reconstruction in the calibrated projector frame (meters)."""
import json
import cv2
import numpy as np


def corners(segment):
    contours = [np.asarray(c, np.float32).reshape(-1, 2) for c in segment['contours'] if len(c) >= 4]
    if not contours:
        raise ValueError('No four-sided segment was found.')
    contour = max(contours, key=lambda c: abs(cv2.contourArea(c)))
    hull = cv2.convexHull(contour).reshape(-1, 2)
    perimeter = cv2.arcLength(hull, True)
    quad = None
    for epsilon in np.linspace(.002, .08, 160):
        approx = cv2.approxPolyDP(hull, epsilon * perimeter, True).reshape(-1, 2)
        if len(approx) == 4:
            quad = approx.astype(float)
            break
        if len(approx) < 4:
            break
    if quad is None or abs(cv2.contourArea(quad.astype(np.float32))) < 25:
        raise ValueError('The segment does not have four usable corners.')
    area = abs(cv2.contourArea(contour))
    quad_area = abs(cv2.contourArea(quad.astype(np.float32)))
    if abs(area - quad_area) / quad_area > .18:
        raise ValueError('The segment is not close enough to a flat quadrilateral.')
    # Fit each edge to contour samples, then intersect adjacent lines. This
    # avoids letting a single rounded or noisy mask pixel determine a corner.
    edges = np.roll(quad, -1, axis=0) - quad
    lengths = np.linalg.norm(edges, axis=1)
    rel = contour[:, None, :] - quad[None, :, :]
    along = np.sum(rel * edges, axis=2) / lengths**2
    distances = np.abs(rel[:, :, 0] * edges[:, 1] - rel[:, :, 1] * edges[:, 0]) / lengths
    assignment = distances.argmin(axis=1)
    lines = []
    for i in range(4):
        selected = contour[(assignment == i) & (along[:, i] > .08) & (along[:, i] < .92)
                           & (distances[:, i] < max(2, lengths[i] * .04))]
        if len(selected) < 3:
            lines.append((edges[i] / lengths[i], quad[i]))
        else:
            vx, vy, x, y = cv2.fitLine(selected, cv2.DIST_HUBER, 0, .01, .01).ravel()
            lines.append((np.array([vx, vy]), np.array([x, y])))
    refined = []
    for i in range(4):
        direction, origin = lines[i-1]
        next_direction, next_origin = lines[i]
        matrix = np.column_stack((direction, -next_direction))
        if abs(np.linalg.det(matrix)) < .1:
            raise ValueError('The segment has nearly parallel adjacent edges.')
        point = origin + np.linalg.solve(matrix, next_origin - origin)[0] * direction
        refined.append(point if np.linalg.norm(point - quad[i]) < .08 * min(lengths[i-1], lengths[i]) else quad[i])
    quad = np.array(refined)
    return np.roll(quad, -np.argmin(quad[:, 0] + quad[:, 1]), axis=0)


def intrinsics(raw):
    return {k: float(v) for k, v in raw.items()}


def undistort(points, intr, size):
    # Calibration coordinates may differ from the frozen frame resolution.
    pixels = points * [intr['width'] / size[0], intr['height'] / size[1]]
    target = (pixels - [intr['cx'], intr['cy']]) / [intr['fx'], intr['fy']]
    xy = target.copy()
    for _ in range(100):
        x, y = xy.T
        r2 = x*x + y*y
        radial = 1 + intr.get('k1', 0)*r2 + intr.get('k2', 0)*r2*r2
        dx = 2*intr.get('p1', 0)*x*y + intr.get('p2', 0)*(r2 + 2*x*x)
        dy = intr.get('p1', 0)*(r2 + 2*y*y) + 2*intr.get('p2', 0)*x*y
        updated = (target - np.column_stack((dx, dy))) / radial[:, None]
        if not np.isfinite(updated).all():
            raise ValueError('Camera distortion could not be inverted at these corners.')
        delta = np.max(abs(updated-xy))
        xy = updated
        if delta < 1e-12:
            break
    else:
        raise ValueError('Camera distortion did not converge at these corners.')
    xy[:, 0] -= intr.get('s', 0) / intr['fx'] * xy[:, 1]
    return xy


def project(points, intr, size):
    x, y = (points[:, :2] / points[:, 2, None]).T
    # Match Folk's pose-library distortion model, including skew before distortion.
    x = x + intr.get('s', 0) / intr['fx'] * y
    r2 = x*x + y*y
    radial = 1 + intr.get('k1', 0)*r2 + intr.get('k2', 0)*r2*r2
    dx = 2*intr.get('p1', 0)*x*y + intr.get('p2', 0)*(r2 + 2*x*x)
    dy = intr.get('p1', 0)*(r2 + 2*y*y) + 2*intr.get('p2', 0)*x*y
    return np.column_stack(((x*radial+dx)*intr['fx']+intr['cx'],
                            (y*radial+dy)*intr['fy']+intr['cy'])) * [size[0]/intr['width'], size[1]/intr['height']]


def reconstruct(payload):
    if isinstance(payload, str):
        payload = json.loads(payload)
    data = {k: json.loads(v) if isinstance(v, str) else v for k, v in payload.items()}
    segments = [data['left'], data['right']]
    intr = [intrinsics(data['intrLeft']), intrinsics(data['intrRight'])]
    extr = [data['extLeft'], data['extRight']]
    rotations = [np.asarray(e['R'], float) for e in extr]  # camera -> projector
    translations = [np.asarray(e['t'], float) for e in extr]
    if np.linalg.norm(translations[0] - translations[1]) < .01:
        raise ValueError('The calibrated stereo baseline is too small.')
    matrices = [np.column_stack((r.T, -r.T @ t)) for r, t in zip(rotations, translations)]
    sizes = [(s['width'], s['height']) for s in segments]
    quads = [corners(s) for s in segments]
    rays = [undistort(q, k, size) for q, k, size in zip(quads, intr, sizes)]
    candidates = []
    for reverse in (False, True):
        order = np.arange(4)[::-1] if reverse else np.arange(4)
        for offset in range(4):
            indices = np.roll(order, offset)
            homogeneous = cv2.triangulatePoints(matrices[0], matrices[1], rays[0].T, rays[1][indices].T).T
            if np.any(abs(homogeneous[:, 3]) < 1e-10):
                continue
            points = homogeneous[:, :3] / homogeneous[:, 3, None]
            cameras = [(points - t) @ r for r, t in zip(rotations, translations)]
            if min(points[:, 2].min(), *(p[:, 2].min() for p in cameras)) <= 0:
                continue
            observed = [quads[0], quads[1][indices]]
            predicted = [project(p, k, size) for p, k, size in zip(cameras, intr, sizes)]
            error = np.concatenate([p - q for p, q in zip(predicted, observed)])
            rms = float(np.sqrt(np.mean(np.sum(error**2, axis=1))))
            candidates.append((rms, indices, points, observed))
    if not candidates:
        raise ValueError('No corner correspondence triangulates in front of both cameras and projector.')
    candidates.sort(key=lambda c: c[0])
    rms, indices, points, observed = candidates[0]
    if rms > 5:
        raise ValueError(f'The two segments disagree with stereo calibration ({rms:.1f} px reprojection error). Select the same flat face in both cameras.')
    if len(candidates) > 1 and candidates[1][0] < max(.5, rms * 1.2):
        raise ValueError('Corner correspondence is ambiguous. Try a more clearly segmented surface.')
    center = points.mean(axis=0)
    _, _, axes = np.linalg.svd(points-center)
    normal = axes[-1]
    deviation = (points-center) @ normal
    side_lengths = np.linalg.norm(np.roll(points, -1, axis=0) - points, axis=1)
    if np.min(side_lengths) < .003:
        raise ValueError('The reconstructed quad is degenerate or too small.')
    if max(abs(deviation)) > max(.005, .03 * side_lengths.mean()):
        raise ValueError('The corners are not coplanar. Select the same flat face in both cameras.')
    points = points - deviation[:, None] * normal
    predicted = [project((points-t) @ r, k, size) for r, t, k, size in zip(rotations, translations, intr, sizes)]
    errors = np.concatenate([p-q for p, q in zip(predicted, observed)])
    rms = float(np.sqrt(np.mean(np.sum(errors**2, axis=1))))
    if rms > 5 or np.linalg.norm(errors, axis=1).max() > 12:
        raise ValueError(f'A flat quad does not fit both segments ({rms:.1f} px reprojection error).')
    lengths = np.linalg.norm(np.roll(points, -1, axis=0)-points, axis=1)
    xaxis = (points[1]-points[0]) / lengths[0]
    yaxis = np.cross(normal, xaxis)
    plane = np.column_stack(((points-points[0]) @ xaxis, (points-points[0]) @ yaxis))
    projector = intrinsics(data['projector'])
    display_size = [int(v) for v in data['displaySize']]
    projected = project(points, projector, display_size)
    return {'corners': [q.tolist() for q in observed], 'cameraQuads': [q.tolist() for q in predicted],
            'points3d': points.tolist(), 'lengths': lengths.tolist(), 'planeQuad': plane.tolist(),
            'projectorQuad': projected.tolist(), 'displaySize': display_size,
            'reprojectionRms': rms, 'planarityError': float(max(abs(deviation))),
            'center': points.mean(axis=0).tolist(), 'normal': normal.tolist(),
            'pose': {'origin': points[0].tolist(), 'R': np.column_stack((xaxis, yaxis, normal)).tolist()}}
