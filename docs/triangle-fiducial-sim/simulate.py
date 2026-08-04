#!/usr/bin/env python3
"""Measurement harness for the TriTag proposal (docs/triangle-fiducials.md).

Simulates a folk tabletop (camera + table + printed TriTag markers at
known mm scale) and measures, across optical resolutions (720p..4K)
and frame rates (15..120 Hz):

  Exp 1  single-frame 6DOF pose accuracy of one TriTag (3 corners +
         keystone dot) vs an equal-area square tag (4 corners).
  Exp 2  camera-model quality: the current uncalibrated fallback in
         builtin-programs/calibrate/load-calibration.folk (fx=width,
         principal point at center, no distortion, identity
         extrinsics) vs TriTag-based self-calibration from 3 taped
         reference markers plus N tilted views of an ordinary moving
         page. Metrics: focal error, on-table registration error,
         off-plane (lifted page) registration error, absolute depth
         error of a held marker.
  Exp 3  temporal behavior: background alternation refinement of
         intrinsics while a page moves; convergence time vs fps, and
         static jitter vs fps with/without a 100 ms EMA.
  Exp 4  (arithmetic) low-band structured-light budget for projector
         (self-)calibration, Lee/Hudson/Dietz TR2007-109 style.

Ground-truth camera: 70.4 deg HFOV (C920-class), off-center principal
point, radial+tangential distortion. Corner noise: sigma = 0.15 px at
1080p scaled by sqrt(w/1920) (same optics: blur covers more pixels at
higher resolution, so per-pixel noise grows ~sqrt while relative
precision still improves).

Run:  python3 simulate.py   (writes PNGs + results.txt next to itself)
"""
import os, sys, time, math
import numpy as np
from scipy.optimize import least_squares

OUT = os.path.dirname(os.path.abspath(__file__))
rng = np.random.default_rng(7)

RESOLUTIONS = [(1280, 720), (1920, 1080), (2560, 1440), (3840, 2160)]
RESNAMES = {720: "720p", 1080: "1080p", 1440: "1440p", 2160: "4K"}

# ---------------------------------------------------------------- camera

def true_intrinsics(w, h):
    fx = w / (2 * math.tan(math.radians(70.42) / 2))   # 70.4deg HFOV
    return dict(fx=fx, fy=fx * 1.002, cx=0.502 * w, cy=0.488 * h,
                k1=-0.09, k2=0.03, p1=0.0008, p2=-0.0005, w=w, h=h)

def guess_intrinsics(w, h):
    # load-calibration.folk uncalibrated fallback, verbatim.
    return dict(fx=float(w), fy=float(w), cx=w / 2.0, cy=h / 2.0,
                k1=0.0, k2=0.0, p1=0.0, p2=0.0, w=w, h=h)

def rodrigues(r):
    th = np.linalg.norm(r)
    if th < 1e-12: return np.eye(3)
    u = r / th; K = np.array([[0, -u[2], u[1]], [u[2], 0, -u[0]], [-u[1], u[0], 0]])
    return np.eye(3) + math.sin(th) * K + (1 - math.cos(th)) * (K @ K)

def project(intr, R, t, X):
    """X: Nx3 world (meters) -> Nx2 pixels, with distortion."""
    Xc = X @ R.T + t
    x = Xc[:, 0] / Xc[:, 2]; y = Xc[:, 1] / Xc[:, 2]
    r2 = x * x + y * y
    rad = 1 + intr["k1"] * r2 + intr["k2"] * r2 * r2
    xd = x * rad + 2 * intr["p1"] * x * y + intr["p2"] * (r2 + 2 * x * x)
    yd = y * rad + intr["p1"] * (r2 + 2 * y * y) + 2 * intr["p2"] * x * y
    return np.stack([intr["fx"] * xd + intr["cx"], intr["fy"] * yd + intr["cy"]], 1)

def backproject_to_plane(intr, R, t, uv, n, d, iters=6):
    """Pixels -> rays (undistorting iteratively) -> intersect plane n.X=d."""
    x = (uv[:, 0] - intr["cx"]) / intr["fx"]; y = (uv[:, 1] - intr["cy"]) / intr["fy"]
    x0, y0 = x.copy(), y.copy()
    for _ in range(iters):
        r2 = x * x + y * y
        rad = 1 + intr["k1"] * r2 + intr["k2"] * r2 * r2
        dx = 2 * intr["p1"] * x * y + intr["p2"] * (r2 + 2 * x * x)
        dy = intr["p1"] * (r2 + 2 * y * y) + 2 * intr["p2"] * x * y
        x = (x0 - dx) / rad; y = (y0 - dy) / rad
    rays_c = np.stack([x, y, np.ones_like(x)], 1)
    rays_w = rays_c @ R                      # R^T ray
    origin = -R.T @ t
    s = (d - origin @ n) / (rays_w @ n)
    return origin + rays_w * s[:, None]

# ---------------------------------------------------------------- scene

# World: table plane z=0, x right, y toward camera-ish. Camera 1.15 m
# above table center, pitched 28 deg off straight-down.
def make_camera_pose():
    pitch = math.radians(180 - 28)          # look down, tilted
    Rx = rodrigues(np.array([pitch, 0, 0]))
    Rz = rodrigues(np.array([0, 0, math.radians(4)]))
    R = Rz @ Rx
    C = np.array([0.0, -0.55, 1.15])        # camera center in world
    return R, -R @ C

CAM_R, CAM_T = make_camera_pose()

# TriTag correspondence points in marker frame (units of scale s),
# matching user-programs/folk-cwe/triangle-fiducial-demo.folk:
# apex, baseR, baseL, keystone. Marker scale: s=40mm -> 54x64 mm tag.
TRI_PTS = np.array([[0, -1.05], [0.68, 0.55], [-0.68, 0.55], [0, -0.60]])
SQ_HALF = 1.043 / 2  # square with equal footprint area to the triangle
SQ_PTS = np.array([[-SQ_HALF, -SQ_HALF], [SQ_HALF, -SQ_HALF],
                   [SQ_HALF, SQ_HALF], [-SQ_HALF, SQ_HALF]])
S_MARKER = 0.040

# An ordinary printed folk page carrying two TriTags 180 mm apart at a
# known printed layout (folk pages already carry several AprilTags
# each today). 16 points per page view -> 10 redundant constraints
# per view instead of the 2 a lone minimal 4-point tag provides.
PAGE_OFF = 0.090 / S_MARKER
PAGE_PTS = np.vstack([TRI_PTS + [-PAGE_OFF, 0], TRI_PTS + [PAGE_OFF, 0]])

def marker_world(pts2, s, pose6):
    """pose6 = (rx,ry,rz, x,y,z): marker-frame pts -> world 3D."""
    R = rodrigues(pose6[:3])
    P = np.concatenate([pts2 * s, np.zeros((len(pts2), 1))], 1)
    return P @ R.T + pose6[3:]

def noise_sigma(w):
    return 0.15 * math.sqrt(w / 1920.0)

# ------------------------------------------------- pose estimation (GN)

def estimate_pose(intr, pts2, s, uv_obs, init6):
    def resid(p):
        return (project(intr, CAM_R @ rodrigues(p[:3]),
                        CAM_R @ (p[3:] - (-CAM_R.T @ CAM_T)) if False else None, None))
    # marker pose composed with fixed camera: world pose of marker.
    def resid(p):
        X = marker_world(pts2, s, p)
        return (project(intr, CAM_R, CAM_T, X) - uv_obs).ravel()
    sol = least_squares(resid, init6, method="lm", max_nfev=200)
    return sol.x

def perturb(pose6, rmag=0.15, tmag=0.03):
    p = pose6.copy()
    p[:3] += rng.normal(0, rmag, 3); p[3:] += rng.normal(0, tmag, 3)
    return p

# ---------------------------------------------------------------- Exp 1

def exp1(trials=300):
    print("== Exp 1: single-frame 6DOF pose accuracy (marker at 0.25,0.15, yaw 40deg)")
    pose = np.array([0, 0, math.radians(40), 0.25, 0.15, 0.0])
    rows = []
    for (w, h) in RESOLUTIONS:
        intr = true_intrinsics(w, h); sig = noise_sigma(w)
        for name, pts in (("TriTag", TRI_PTS), ("square", SQ_PTS)):
            uv_true = project(intr, CAM_R, CAM_T, marker_world(pts, S_MARKER, pose))
            size_px = np.linalg.norm(uv_true.max(0) - uv_true.min(0))
            terr, rerr, berr = [], [], []
            for _ in range(trials):
                uv = uv_true + rng.normal(0, sig, uv_true.shape)
                est = estimate_pose(intr, pts, S_MARKER, uv, perturb(pose))
                terr.append(est[3:] - pose[3:])
                dR = rodrigues(est[:3]) @ rodrigues(pose[:3]).T
                ang = math.degrees(math.acos(np.clip((np.trace(dR) - 1) / 2, -1, 1)))
                rerr.append(ang)
                yaw_t = pose[2]
                # bearing = in-plane orientation of marker x-axis
                ex = rodrigues(est[:3])[:2, 0]
                berr.append(math.degrees(abs(math.atan2(ex[1], ex[0]) - yaw_t)))
            terr = np.array(terr) * 1000
            rows.append((RESNAMES[h], name, size_px,
                         np.sqrt((terr[:, :2] ** 2).mean()),  # lateral RMSE mm
                         np.sqrt((terr[:, 2] ** 2).mean()),   # depth RMSE mm
                         np.sqrt(np.square(rerr).mean()),
                         np.sqrt(np.square(berr).mean())))
            print(f"  {RESNAMES[h]:>5} {name:7s} span {size_px:5.0f}px | "
                  f"lateral {rows[-1][3]:5.2f} mm  depth {rows[-1][4]:6.2f} mm  "
                  f"rot {rows[-1][5]:5.2f} deg  bearing {rows[-1][6]:5.3f} deg")
    return rows

# ---------------------------------------------------------------- Exp 2

REF_POSES = [np.array([0, 0, math.radians(15), -0.45, -0.25, 0]),
             np.array([0, 0, math.radians(160), 0.50, -0.20, 0]),
             np.array([0, 0, math.radians(275), 0.05, 0.30, 0])]

def random_page_pose():
    """An ordinary folk page being handled above the table: tilted."""
    tilt = math.radians(rng.uniform(18, 38)); az = rng.uniform(0, 2 * math.pi)
    return np.array([tilt * math.cos(az), tilt * math.sin(az),
                     rng.uniform(0, 2 * math.pi),
                     rng.uniform(-0.45, 0.45), rng.uniform(-0.3, 0.3),
                     rng.uniform(0.0, 0.18)])

def observe(intr_true, pts, s, pose6, sig):
    uv = project(intr_true, CAM_R, CAM_T, marker_world(pts, s, pose6))
    return uv + rng.normal(0, sig, uv.shape)

def rodrigues_inv(R):
    th = math.acos(np.clip((np.trace(R) - 1) / 2, -1, 1))
    if th < 1e-9: return np.zeros(3)
    return th / (2 * math.sin(th)) * np.array(
        [R[2, 1] - R[1, 2], R[0, 2] - R[2, 0], R[1, 0] - R[0, 1]])

def dlt_homography(xy, uv):
    """xy: Nx2 plane coords (meters), uv: Nx2 pixels -> 3x3 H."""
    def norm(p):
        m = p.mean(0); s = math.sqrt(2) / np.linalg.norm(p - m, axis=1).mean()
        T = np.array([[s, 0, -s * m[0]], [0, s, -s * m[1]], [0, 0, 1]])
        return (p - m) * s, T
    a, Ta = norm(xy); b, Tb = norm(uv)
    rows = []
    for (x, y), (u, v) in zip(a, b):
        rows.append([-x, -y, -1, 0, 0, 0, u * x, u * y, u])
        rows.append([0, 0, 0, -x, -y, -1, v * x, v * y, v])
    _, _, vt = np.linalg.svd(np.array(rows))
    H = vt[-1].reshape(3, 3)
    return np.linalg.inv(Tb) @ H @ Ta

def zhang_init(obs, intr0):
    """Closed-form intrinsics from plane homographies (Zhang 2000).
    Returns None when views are degenerate (e.g. all markers coplanar
    with each other: static taped refs alone give one effective plane,
    so the image of the absolute conic is under-constrained and fx is
    unrecoverable — the classic single-plane degeneracy)."""
    # Only views with point redundancy (multi-tag pages, >=6 pts) give
    # least-squares homographies stable enough to seed the IAC solve;
    # minimal 4-pt views produce exact-fit (noise-dominated) H's.
    obs = [o for o in obs if len(o[1]) >= 6]
    if len(obs) < 3: return None
    Hs = [dlt_homography(pts * s, uv) for (uv, pts, s, _) in obs]
    def v(H, i, j):
        return np.array([H[0, i] * H[0, j],
                         H[0, i] * H[1, j] + H[1, i] * H[0, j],
                         H[1, i] * H[1, j],
                         H[2, i] * H[0, j] + H[0, i] * H[2, j],
                         H[2, i] * H[1, j] + H[1, i] * H[2, j],
                         H[2, i] * H[2, j]])
    V = np.array([r for H in Hs for r in (v(H, 0, 1), v(H, 0, 0) - v(H, 1, 1))])
    b = np.linalg.svd(V)[2][-1]
    B11, B12, B22, B13, B23, B33 = b
    den = B11 * B22 - B12 ** 2
    try:
        cy = (B12 * B13 - B11 * B23) / den
        lam = B33 - (B13 ** 2 + cy * (B12 * B13 - B11 * B23)) / B11
        fx = math.sqrt(lam / B11); fy = math.sqrt(lam * B11 / den)
        cx = -B13 * fx ** 2 / lam
    except (ValueError, ZeroDivisionError):
        return None
    w = intr0["w"]
    if not (0.3 * w < fx < 3 * w and 0.3 * w < fy < 3 * w):
        return None
    return dict(intr0, fx=fx, fy=fy, cx=cx, cy=cy, k1=0.0, k2=0.0)

def pose_from_homography(intr, H):
    """Planar pose (marker->world via fixed camera) from H = K[r1 r2 t]."""
    K = np.array([[intr["fx"], 0, intr["cx"]],
                  [0, intr["fy"], intr["cy"]], [0, 0, 1]])
    G = np.linalg.inv(K) @ H
    if G[2, 2] < 0: G = -G
    lam = 1.0 / np.linalg.norm(G[:, 0])
    r1, r2, t = lam * G[:, 0], lam * G[:, 1], lam * G[:, 2]
    Rcm = np.stack([r1, r2, np.cross(r1, r2)], 1)
    U, _, Vt = np.linalg.svd(Rcm); Rcm = U @ Vt
    Rm = CAM_R.T @ Rcm
    tm = CAM_R.T @ (t - CAM_T)
    return np.concatenate([rodrigues_inv(Rm), tm])

def batch_rodrigues(rv):
    """rv: Vx3 rotation vectors -> Vx3x3 matrices, vectorized."""
    th = np.linalg.norm(rv, axis=1)
    u = rv / np.where(th < 1e-12, 1.0, th)[:, None]
    zero = np.zeros(len(rv))
    K = np.stack([np.stack([zero, -u[:, 2], u[:, 1]], 1),
                  np.stack([u[:, 2], zero, -u[:, 0]], 1),
                  np.stack([-u[:, 1], u[:, 0], zero], 1)], 1)
    s = np.sin(th)[:, None, None]; c = (1 - np.cos(th))[:, None, None]
    R = np.eye(3)[None] + s * K + c * (K @ K)
    R[th < 1e-12] = np.eye(3)
    return R

def refine_intrinsics(obs, intr0, max_nfev=6000):
    """Staged joint bundle: Zhang closed-form seed, homography pose
    seeds, then shared intrinsics + one 6DOF pose per view in a single
    least-squares — first with distortion frozen, then free.

    Two hard-won implementation notes (both reproduced by earlier
    revisions of this script): (1) a pose<->intrinsics *alternation*
    stalls, because per-view pose solves absorb the focal error into
    each view's depth (fx and tz are nearly perfectly correlated for a
    small marker), leaving no residual for the intrinsics pass; the
    joint solve is required. (2) views carrying a single minimal
    4-point tag leave the bundle under-determined at realistic noise
    (each view's homography fits exactly; only 2 IAC constraints per
    view survive) — the optimizer then reaches near-zero cost at wrong
    intrinsics. Multi-tag pages at a known printed layout fix this.

    A refiner that updates on degenerate geometry destroys a working
    model, so this refuses (returns intr0, refused=True) unless the
    Zhang seed succeeds AND the view plane normals span > 12 deg
    (3 taped refs alone are one plane: always refused)."""
    intr = dict(intr0)
    zi = zhang_init(obs, intr0)
    inits = []
    for (uv, pts, s, pinit) in obs:
        try:
            inits.append(pose_from_homography(intr if zi is None else zi,
                                              dlt_homography(pts * s, uv)))
        except Exception:
            inits.append(pinit)
    rich = [i for i, o in enumerate(obs) if len(o[1]) >= 6]
    normals = np.array([rodrigues(inits[i][:3])[:, 2] for i in rich]) \
        if len(rich) >= 2 else np.zeros((1, 3))
    spread = math.degrees(math.acos(np.clip(
        (normals @ normals.T).min(), -1, 1)))
    if zi is None or spread < 12:
        return dict(intr0), [o[3] for o in obs], True
    intr = zi
    intr["k1"] = intr["k2"] = 0.0
    V = len(obs)
    uv_all = np.concatenate([o[0] for o in obs])
    counts = [len(o[1]) for o in obs]
    vidx = np.repeat(np.arange(V), counts)
    P_all = np.concatenate([np.c_[o[1] * o[2], np.zeros(len(o[1]))] for o in obs])
    def bundle(intr, inits, with_dist, nfev):
        nI = 6 if with_dist else 4
        p0 = np.concatenate(
            [[intr["fx"], intr["fy"], intr["cx"], intr["cy"]] +
             ([intr["k1"], intr["k2"]] if with_dist else [])] + list(inits))
        def resid(p):
            it = dict(intr, fx=p[0], fy=p[1], cx=p[2], cy=p[3])
            if with_dist: it.update(k1=p[4], k2=p[5])
            pv = p[nI:].reshape(V, 6)
            R = batch_rodrigues(pv[:, :3])
            Xw = np.einsum('nij,nj->ni', R[vidx], P_all) + pv[vidx, 3:]
            return (project(it, CAM_R, CAM_T, Xw) - uv_all).ravel()
        sol = least_squares(resid, p0, method="lm", max_nfev=nfev)
        it = dict(intr, fx=sol.x[0], fy=sol.x[1], cx=sol.x[2], cy=sol.x[3])
        if with_dist: it.update(k1=sol.x[4], k2=sol.x[5])
        return it, [sol.x[nI + 6 * i:nI + 6 + 6 * i] for i in range(V)]
    intr, inits = bundle(intr, inits, False, max_nfev // 2)
    intr, poses = bundle(intr, inits, True, max_nfev)
    # Post-solve gates: a background refiner must never install an
    # implausible or badly-fit model over a working one.
    w, h = intr0["w"], intr0["h"]
    pv = np.array(poses)
    R = batch_rodrigues(pv[:, :3])
    Xw = np.einsum('nij,nj->ni', R[vidx], P_all) + pv[vidx, 3:]
    rms = float(np.sqrt(((project(intr, CAM_R, CAM_T, Xw) - uv_all) ** 2).mean()))
    plausible = (0.45 * w < intr["fx"] < 1.6 * w and
                 0.45 * w < intr["fy"] < 1.6 * w and
                 abs(intr["cx"] - w / 2) < 0.1 * w and
                 abs(intr["cy"] - h / 2) < 0.1 * h and
                 abs(intr["k1"]) < 0.4 and abs(intr["k2"]) < 0.8)
    if not plausible or rms > 1.0:
        return dict(intr0), [o[3] for o in obs], True
    return intr, poses, False

def registration_errors(intr_est, intr_true, plane_h=0.0):
    """True camera images a grid at height plane_h; estimated model
    back-projects those pixels to that plane. Error = where folk would
    believe table/page content is, in mm."""
    gx, gy = np.meshgrid(np.linspace(-0.55, 0.55, 12), np.linspace(-0.35, 0.35, 8))
    X = np.stack([gx.ravel(), gy.ravel(), np.full(gx.size, plane_h)], 1)
    uv = project(intr_true, CAM_R, CAM_T, X)
    keep = (uv[:, 0] > 0) & (uv[:, 0] < intr_true["w"]) & \
           (uv[:, 1] > 0) & (uv[:, 1] < intr_true["h"])
    Xb = backproject_to_plane(intr_est, CAM_R, CAM_T, uv[keep],
                              np.array([0, 0, 1.0]), plane_h)
    return float(np.sqrt(((Xb[:, :2] - X[keep, :2]) ** 2).sum(1).mean()) * 1000)

def exp2(page_views=(0, 2, 5, 10, 20)):
    print("== Exp 2: fallback guess vs TriTag self-calibration")
    held = np.array([math.radians(20), 0, math.radians(30), 0.1, 0.0, 0.10])
    out = {}
    for (w, h) in RESOLUTIONS:
        intr_t = true_intrinsics(w, h); intr_g = guess_intrinsics(w, h)
        sig = noise_sigma(w)
        # depth error of a held marker under an intrinsics model:
        def depth_err(intr_est):
            uv = observe(intr_t, TRI_PTS, S_MARKER, held, sig)
            est = estimate_pose(intr_est, TRI_PTS, S_MARKER, uv, perturb(held))
            cam_c = -CAM_R.T @ CAM_T
            return 1000 * abs(np.linalg.norm(est[3:] - cam_c)
                              - np.linalg.norm(held[3:] - cam_c))
        def calibrate(J, page_pts, reps=4):
            metrics, n_refused = [], 0
            for _ in range(reps):
                obs = [(observe(intr_t, TRI_PTS, S_MARKER, p, sig), TRI_PTS,
                        S_MARKER, perturb(p)) for p in REF_POSES]
                for _ in range(J):
                    p = random_page_pose()
                    obs.append((observe(intr_t, page_pts, S_MARKER, p, sig),
                                page_pts, S_MARKER, perturb(p)))
                intr_e, _, refused = refine_intrinsics(obs, intr_g)
                n_refused += refused
                metrics.append([100 * (intr_e["fx"] / intr_t["fx"] - 1),
                                registration_errors(intr_e, intr_t, 0.0),
                                registration_errors(intr_e, intr_t, 0.10),
                                np.mean([depth_err(intr_e) for _ in range(8)])])
            med = np.median(np.array(metrics), axis=0)
            return dict(fx_err=med[0], table=med[1], lifted=med[2],
                        depth=med[3], refused=n_refused, reps=reps)
        res = {"guess": dict(fx_err=100 * (intr_g["fx"] / intr_t["fx"] - 1),
                             table=registration_errors(intr_g, intr_t, 0.0),
                             lifted=registration_errors(intr_g, intr_t, 0.10),
                             depth=np.mean([depth_err(intr_g) for _ in range(12)]))}
        for J in page_views:
            res[f"J{J}"] = calibrate(J, PAGE_PTS)
        out[h] = res
        g = res["guess"]
        print(f"  {RESNAMES[h]:>5} guess: fx {g['fx_err']:+5.1f}%  table "
              f"{g['table']:6.1f} mm  lifted@10cm {g['lifted']:6.1f} mm  "
              f"depth {g['depth']:6.1f} mm")
        for J in page_views:
            r = res[f"J{J}"]
            print(f"         3 refs + {J:2d} page views: fx {r['fx_err']:+6.2f}%  "
                  f"table {r['table']:6.2f} mm  lifted {r['lifted']:6.2f} mm  "
                  f"depth {r['depth']:5.1f} mm  "
                  f"(refused {r['refused']}/{r['reps']})")
        if h == 1080:
            r = calibrate(10, TRI_PTS)   # identifiability failure demo
            print(f"         [degenerate: 10 single-tag (4-pt) page views: "
                  f"fx {r['fx_err']:+6.2f}%  lifted {r['lifted']:6.2f} mm — "
                  f"minimal views underdetermine the bundle]")
            out["single_tag_1080"] = r
    return out

# ---------------------------------------------------------------- Exp 3

def exp3(fps_list=(15, 30, 60, 120), dur=40.0, res=(1920, 1080)):
    print("== Exp 3: temporal — background refinement + jitter (1080p)")
    w, h = res
    intr_t = true_intrinsics(w, h); sig = noise_sigma(w)
    results = {}
    for fps in fps_list:
        ckpt = f"{OUT}/exp3_{fps}.npz"
        if os.path.exists(ckpt):        # resume from checkpoint
            z = np.load(ckpt, allow_pickle=True)
            tc = float(z["t_conv"])
            results[fps] = dict(curve=[tuple(r) for r in z["curve"]],
                                t_conv=None if math.isnan(tc) else tc,
                                jitter_raw=float(z["jitter_raw"]),
                                jitter_ema=float(z["jitter_ema"]),
                                depth_before=float(z["depth_before"]),
                                depth_after=float(z["depth_after"]))
            r = results[fps]
            print(f"  {fps:3d} fps (checkpoint): fx<2% after "
                  f"{r['t_conv'] if r['t_conv'] is not None else float('nan'):5.1f} s"
                  f" | moving-page depth err {r['depth_before']:5.0f} -> "
                  f"{r['depth_after']:4.1f} mm | static jitter "
                  f"{r['jitter_raw']:5.3f} mm raw, {r['jitter_ema']:5.3f} mm w/ 100ms EMA")
            continue
        n = int(dur * fps); dt = 1.0 / fps
        intr_e = guess_intrinsics(w, h)
        bank, fx_curve, depth_curve, t_conv = [], [], [], None
        # moving page trajectory (handled surface, Lee Fig.1 style):
        def traj(t):
            return np.array([
                math.radians(22) * math.sin(2 * math.pi * 0.21 * t),
                math.radians(18) * math.sin(2 * math.pi * 0.13 * t + 1),
                0.6 * t,
                0.12 * math.sin(2 * math.pi * 0.4 * t),
                0.10 * math.sin(2 * math.pi * 0.27 * t + 0.7),
                0.08 + 0.05 * math.sin(2 * math.pi * 0.23 * t)])
        prev = traj(0.0)
        cam_c = -CAM_R.T @ CAM_T
        for i in range(n):
            t = i * dt
            pose = traj(t)
            uv = observe(intr_t, PAGE_PTS, S_MARKER, pose, sig)
            est = estimate_pose(intr_e, PAGE_PTS, S_MARKER, uv, prev)  # warm start
            prev = est
            depth_curve.append((t, 1000 * abs(
                np.linalg.norm(est[3:] - cam_c) - np.linalg.norm(pose[3:] - cam_c))))
            tilt = math.degrees(np.linalg.norm(est[:2]))
            if tilt > 12 and (not bank or t - bank[-1][0] > 0.3):
                bank.append((t, uv, est))
                bank = bank[-16:]
            if i % int(max(1, fps * 3)) == 0 and len(bank) >= 5:   # every ~3 s
                obs = [(uv, PAGE_PTS, S_MARKER, p) for (_, uv, p) in bank]
                obs += [(observe(intr_t, TRI_PTS, S_MARKER, p, sig), TRI_PTS,
                         S_MARKER, perturb(p)) for p in REF_POSES]
                ie2, _, refused = refine_intrinsics(obs, intr_e, max_nfev=4000)
                if not refused:
                    # damped install (never jump the live model)
                    for k in ("fx", "fy", "cx", "cy", "k1", "k2"):
                        intr_e[k] = 0.5 * intr_e[k] + 0.5 * ie2[k]
            fx_curve.append((t, 100 * (intr_e["fx"] / intr_t["fx"] - 1)))
            if t_conv is None and abs(fx_curve[-1][1]) < 2.0:
                t_conv = t
        # static jitter after convergence (warm-started, like folk's
        # servoing estimator):
        static = np.array([0, 0, 1.0, -0.1, 0.05, 0.0])
        ests, prev = [], perturb(static)
        for _ in range(int(4 * fps)):
            uv = observe(intr_t, TRI_PTS, S_MARKER, static, sig)
            prev = estimate_pose(intr_e, TRI_PTS, S_MARKER, uv, prev)
            ests.append(prev)
        E = np.array(ests)[:, 3:] * 1000
        jit_raw = float(np.linalg.norm(np.diff(E, axis=0), axis=1).std())
        alpha = 1 - math.exp(-dt / 0.1)                      # 100 ms EMA
        F = E.copy()
        for i in range(1, len(F)):
            F[i] = F[i - 1] + alpha * (E[i] - F[i - 1])
        jit_f = float(np.linalg.norm(np.diff(F, axis=0), axis=1).std())
        dc = np.array(depth_curve)
        d_before = dc[dc[:, 0] < 4.0, 1].mean()
        d_after = dc[dc[:, 0] > dur - 4.0, 1].mean()
        results[fps] = dict(curve=fx_curve, t_conv=t_conv,
                            jitter_raw=jit_raw, jitter_ema=jit_f,
                            depth_before=d_before, depth_after=d_after)
        np.savez(ckpt, curve=np.array(fx_curve),
                 t_conv=float('nan') if t_conv is None else t_conv,
                 jitter_raw=jit_raw, jitter_ema=jit_f,
                 depth_before=d_before, depth_after=d_after)
        print(f"  {fps:3d} fps: fx<2% after {t_conv if t_conv else float('nan'):5.1f} s"
              f" | moving-page depth err {d_before:5.0f} -> {d_after:4.1f} mm"
              f" | static jitter {jit_raw:5.3f} mm raw, {jit_f:5.3f} mm w/ 100ms EMA")
    return results

# ---------------------------------------------------------------- Exp 4

def exp4():
    print("== Exp 4: low-band structured-light budget (TR2007-109 style)")
    rows = []
    for (w, h) in [(1920, 1080), (3840, 2160)]:
        bits = math.ceil(math.log2(w)) + math.ceil(math.log2(h)) + 2
        for fps in (30, 60, 120):
            for duty in (1, 8, 30):
                tsweep = bits * duty / fps
                rows.append((f"{w}x{h}", fps, f"1/{duty}", bits, tsweep))
                print(f"  {w}x{h} @{fps:3d}Hz, 1 pattern per {duty:2d} frames: "
                      f"{bits} patterns -> full Gray sweep {tsweep:6.1f} s")
    return rows

# ---------------------------------------------------------------- plots

def plots(r1, r2, r3):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    xs = [RESNAMES[h] for (_, h) in RESOLUTIONS]

    fig, ax = plt.subplots(1, 3, figsize=(13, 3.6))
    for name, m in (("TriTag", "o"), ("square", "s")):
        rows = [r for r in r1 if r[1] == name]
        ax[0].plot(xs, [r[3] for r in rows], m + "-", label=name)
        ax[1].plot(xs, [r[4] for r in rows], m + "-", label=name)
        ax[2].plot(xs, [r[6] for r in rows], m + "-", label=name)
    for a, t in zip(ax, ["lateral RMSE (mm)", "depth RMSE (mm)",
                         "bearing RMSE (deg)"]):
        a.set_title(t); a.grid(alpha=.3); a.legend()
    fig.suptitle("Exp 1: single-frame 6DOF pose, 64mm marker @ ~1.2m, sigma 0.15px@1080p")
    fig.tight_layout(); fig.savefig(f"{OUT}/fig1_pose_vs_resolution.png", dpi=110)

    fig, ax = plt.subplots(1, 3, figsize=(13, 3.6))
    Js = [0, 2, 5, 10, 20]
    for metric, a, ttl in (("table", ax[0], "on-table registration (mm)"),
                           ("lifted", ax[1], "registration @ +10cm (mm)"),
                           ("depth", ax[2], "held-marker depth error (mm)")):
        for (_, h) in RESOLUTIONS:
            a.plot(Js, [r2[h][f"J{J}"][metric] for J in Js], "o-",
                   label=RESNAMES[h])
        a.axhline(r2[1080]["guess"][metric], color="crimson", ls="--",
                  label="fallback guess (1080p)")
        a.set_yscale("log"); a.set_xlabel("tilted page views used")
        a.set_title(ttl); a.grid(alpha=.3, which="both")
    ax[0].legend(fontsize=8)
    fig.suptitle("Exp 2: current fallback vs TriTag self-calibration (3 taped refs + moving pages)")
    fig.tight_layout(); fig.savefig(f"{OUT}/fig2_registration.png", dpi=110)

    fig, ax = plt.subplots(1, 2, figsize=(10.5, 3.6))
    for fps, r in r3.items():
        c = np.array(r["curve"])
        ax[0].plot(c[:, 0], np.abs(c[:, 1]), label=f"{fps} fps")
    ax[0].set_yscale("log"); ax[0].set_xlabel("time (s)")
    ax[0].set_title("|fx error| %, background refinement"); ax[0].grid(alpha=.3)
    ax[0].axhline(1, color="gray", ls=":"); ax[0].legend()
    fpss = list(r3.keys())
    ax[1].plot(fpss, [r3[f]["jitter_raw"] for f in fpss], "o-", label="raw")
    ax[1].plot(fpss, [r3[f]["jitter_ema"] for f in fpss], "s-", label="100ms EMA")
    ax[1].set_xlabel("fps"); ax[1].set_title("static pose jitter (mm)")
    ax[1].grid(alpha=.3); ax[1].legend()
    fig.suptitle("Exp 3: temporal resolution — convergence & jitter (1080p)")
    fig.tight_layout(); fig.savefig(f"{OUT}/fig3_temporal.png", dpi=110)

if __name__ == "__main__":
    t0 = time.time()
    log = []
    class Tee:
        def __init__(self, f): self.f = f
        def write(self, s): sys.__stdout__.write(s); self.f.write(s)
        def flush(self): sys.__stdout__.flush(); self.f.flush()
    with open(f"{OUT}/results.txt", "w", buffering=1) as f:
        sys.stdout = Tee(f)
        r1 = exp1()
        r2 = exp2()
        r3 = exp3()
        r4 = exp4()
        print(f"total {time.time()-t0:.0f}s")
        sys.stdout = sys.__stdout__
    plots(r1, r2, r3)
    print("figures written")
