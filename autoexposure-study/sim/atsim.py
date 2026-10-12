"""
AprilTag autoexposure simulation harness.

Renders real tagStandard52h13 tags (via the vendored libapriltag) into a
synthetic tabletop scene, applies a physically-motivated camera/exposure
model (linear sensor + shot/read noise + saturation + gamma + 8-bit
quantization + MJPEG roundtrip), runs the real AprilTag detector on each
frame, and closes the loop through a pluggable autoexposure controller.

The scene supports adversarial lighting: window light drift/steps, strong
spatial illumination gradients, moving hand shadows, specular highlights,
projector overlays (including a *feedback* overlay that is drawn only when
a tag is currently detected, mimicking Folk projecting around a detected
program), low light, and bright sun.

Usage (single run):
    python3 atsim.py --controller branch_fast --scenario window_drift --seed 1
"""
import argparse
import ctypes
import json
import math
import os
import sys
import time

import numpy as np
import cv2

HERE = os.path.dirname(os.path.abspath(__file__))

# --------------------------------------------------------------------------
# libapriltag via ctypes shim
# --------------------------------------------------------------------------

class AprilTagLib:
    def __init__(self, quad_decimate=2.0, nthreads=1):
        self.lib = ctypes.CDLL(os.path.join(HERE, "libatshim.so"))
        L = self.lib
        L.shim_detector_create.restype = ctypes.c_void_p
        L.shim_detector_create.argtypes = [ctypes.c_float, ctypes.c_int]
        L.shim_detector_destroy.argtypes = [ctypes.c_void_p]
        L.shim_family_total_width.restype = ctypes.c_int
        L.shim_family_width_at_border.restype = ctypes.c_int
        L.shim_family_ncodes.restype = ctypes.c_int
        L.shim_render_tag.restype = ctypes.c_int
        L.shim_render_tag.argtypes = [ctypes.c_uint32, ctypes.c_void_p]
        L.shim_detect.restype = ctypes.c_int
        L.shim_detect.argtypes = [ctypes.c_void_p, ctypes.c_void_p, ctypes.c_int,
                                  ctypes.c_int, ctypes.c_void_p, ctypes.c_int]
        self.td = L.shim_detector_create(quad_decimate, nthreads)
        self.total_width = L.shim_family_total_width()
        self.width_at_border = L.shim_family_width_at_border()
        self.ncodes = L.shim_family_ncodes()
        self._out = np.zeros((64, 13), dtype=np.float64)

    def render_tag(self, idx):
        w = self.total_width
        buf = np.zeros((w, w), dtype=np.uint8)
        self.lib.shim_render_tag(idx, buf.ctypes.data)
        return buf

    def detect(self, gray):
        gray = np.ascontiguousarray(gray, dtype=np.uint8)
        h, w = gray.shape
        n = self.lib.shim_detect(self.td, gray.ctypes.data, w, h,
                                 self._out.ctypes.data, self._out.shape[0])
        n = min(n, self._out.shape[0])
        dets = []
        for i in range(n):
            o = self._out[i]
            dets.append({
                "id": int(o[0]),
                "hamming": int(o[1]),
                "margin": float(o[2]),
                "c": (float(o[3]), float(o[4])),
                "p": [(float(o[5 + 2 * k]), float(o[6 + 2 * k])) for k in range(4)],
            })
        return dets


# --------------------------------------------------------------------------
# Scene: reflectance map + tag placements
# --------------------------------------------------------------------------

PAPER_WHITE = 0.85
INK_BLACK = 0.10
WOOD = 0.40


class TagPlacement:
    def __init__(self, tag_id, cx, cy, size_px, angle_deg, persp=0.0):
        self.tag_id = tag_id
        self.cx, self.cy = cx, cy
        self.size_px = size_px
        self.angle = math.radians(angle_deg)
        self.persp = persp
        self.corners = None  # ground truth quad corners (width_at_border) in frame
        self.bbox = None


class Scene:
    """Static reflectance field with tags rendered in. Illumination applied later."""

    def __init__(self, atl, width=640, height=480, placements=None, seed=0,
                 sheet_margin_cells=1.5):
        self.W, self.H = width, height
        self.atl = atl
        rng = np.random.default_rng(seed)
        # Wood background with low-frequency variation and fine grain.
        low = cv2.resize(rng.standard_normal((6, 8)).astype(np.float32), (width, height),
                         interpolation=cv2.INTER_CUBIC)
        grain = rng.standard_normal((height, width)).astype(np.float32)
        grain = cv2.GaussianBlur(grain, (0, 0), 1.2)
        R = WOOD + 0.05 * low + 0.02 * grain
        self.R = np.clip(R, 0.05, 1.0).astype(np.float32)
        self.placements = placements or []
        self.tag_mask = np.zeros((height, width), dtype=np.float32)  # 1 inside paper
        for pl in self.placements:
            self._render_placement(pl, sheet_margin_cells)

    def _render_placement(self, pl, margin_cells):
        atl = self.atl
        tw = atl.total_width
        bits = atl.render_tag(pl.tag_id)  # tw x tw of 0/255
        # Canvas in cell units: paper sheet margin around the tag.
        m = margin_cells
        cells = tw + 2 * m
        s = 16  # px per cell at canvas resolution
        cw = int(round(cells * s))
        canvas = np.full((cw, cw), PAPER_WHITE, dtype=np.float32)
        off = int(round(m * s))
        tile = np.where(bits > 127, PAPER_WHITE, INK_BLACK).astype(np.float32)
        tile = cv2.resize(tile, (tw * s, tw * s), interpolation=cv2.INTER_NEAREST)
        canvas[off:off + tw * s, off:off + tw * s] = tile
        # Ink is not perfectly uniform: slight texture
        # Map canvas -> frame. Tag size in frame = size_px for the total tag width.
        scale = pl.size_px / (tw * s)
        # Pre-blur to avoid aliasing when downscaling, plus lens PSF.
        sigma_canvas = max(0.3, 0.6 / scale)  # ~0.6px in frame space
        canvas_b = cv2.GaussianBlur(canvas, (0, 0), sigma_canvas)
        ca, sa = math.cos(pl.angle), math.sin(pl.angle)
        # Canvas center -> frame center with rotation+scale, mild perspective.
        c0 = cw / 2.0
        src = np.float32([[0, 0], [cw, 0], [cw, cw], [0, cw]])
        dst = []
        for (x, y) in src:
            dx, dy = (x - c0) * scale, (y - c0) * scale
            fx = pl.cx + ca * dx - sa * dy
            fy = pl.cy + sa * dx + ca * dy
            # perspective: squash y with x
            fy += pl.persp * dx * (dy / max(1.0, cw * scale))
            dst.append([fx, fy])
        dst = np.float32(dst)
        Hm = cv2.getPerspectiveTransform(src, dst)
        warped = cv2.warpPerspective(canvas_b, Hm, (self.W, self.H),
                                     flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT,
                                     borderValue=-1.0)
        mask = (warped >= 0).astype(np.float32)
        # soften sheet edge slightly
        mask_b = cv2.GaussianBlur(mask, (0, 0), 0.7)
        self.R = (mask_b * np.maximum(warped, 0) + (1 - mask_b) * self.R).astype(np.float32)
        self.tag_mask = np.maximum(self.tag_mask, mask)
        # Ground-truth corners of the width_at_border quad (what the detector reports).
        wab = atl.width_at_border
        b0 = (tw - wab) / 2.0
        quad_src = np.float32([[off + b0 * s, off + b0 * s],
                               [off + (b0 + wab) * s, off + b0 * s],
                               [off + (b0 + wab) * s, off + (b0 + wab) * s],
                               [off + b0 * s, off + (b0 + wab) * s]])
        quad_dst = cv2.perspectiveTransform(quad_src.reshape(1, -1, 2), Hm).reshape(-1, 2)
        pl.corners = quad_dst
        tag_src = np.float32([[off, off], [off + tw * s, off], [off + tw * s, off + tw * s],
                              [off, off + tw * s]])
        tag_dst = cv2.perspectiveTransform(tag_src.reshape(1, -1, 2), Hm).reshape(-1, 2)
        pl.tag_quad = tag_dst
        x0, y0 = tag_dst.min(axis=0)
        x1, y1 = tag_dst.max(axis=0)
        pl.bbox = (float(x0), float(y0), float(x1), float(y1))


def default_placements():
    # Four tags in different parts of the table.
    return [
        TagPlacement(0, 120, 120, 58, 12, persp=0.05),    # top-left (window side)
        TagPlacement(1, 470, 130, 62, -28, persp=0.03),   # top-right (projector zone)
        TagPlacement(2, 150, 360, 52, 41, persp=0.04),    # bottom-left (shadow zone)
        TagPlacement(3, 470, 350, 66, 4, persp=0.02),     # bottom-right
    ]


# --------------------------------------------------------------------------
# Camera model
# --------------------------------------------------------------------------

class Camera:
    """Linear sensor with shot+read noise, saturation, gamma, 8-bit, MJPEG."""

    def __init__(self, fullwell=2500.0, read_noise=0.004, gamma=2.2,
                 jpeg_quality=85, nominal_us=4000.0, nominal_lin=0.75,
                 min_us=300, max_us=50000, latency_frames=2, step_us=100,
                 glare=0.035, bloom=0.06, bloom_sigma=14.0):
        self.fullwell = fullwell
        self.read_noise = read_noise
        self.gamma = gamma
        self.jpeg_quality = jpeg_quality
        # Veiling glare: a fraction of the mean scene light spreads over the
        # whole sensor (cheap lens, dust); bloom: local spread from bright
        # areas. Both lift the black level and are what make overexposure
        # hurt tag contrast on real webcams.
        self.glare, self.bloom, self.bloom_sigma = glare, bloom, bloom_sigma
        # Calibrate so that white paper (0.85) under unit illumination at
        # nominal exposure lands at nominal_lin of full scale.
        self.K = nominal_lin / (PAPER_WHITE * nominal_us)
        self.min_us, self.max_us = min_us, max_us
        self.latency_frames = latency_frames
        self.step_us = step_us

    def quantize_exposure(self, us):
        us = int(round(us / self.step_us)) * self.step_us
        return int(min(self.max_us, max(self.min_us, us)))

    def capture(self, radiance, exposure_us, rng):
        if self.glare or self.bloom:
            flare = np.float32(self.glare * float(radiance.mean()))
            if self.bloom:
                flare = flare + self.bloom * cv2.GaussianBlur(radiance, (0, 0), self.bloom_sigma)
            radiance = radiance + flare
        lin = radiance * (exposure_us * self.K)
        sigma = np.sqrt(np.maximum(lin, 0.0) / self.fullwell) + self.read_noise
        lin = lin + rng.standard_normal(lin.shape, dtype=np.float32) * sigma
        lin = np.clip(lin, 0.0, 1.0)
        v = 255.0 * np.power(lin, 1.0 / self.gamma)
        img = np.clip(np.rint(v), 0, 255).astype(np.uint8)
        if self.jpeg_quality:
            ok, enc = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, self.jpeg_quality])
            img = cv2.imdecode(enc, cv2.IMREAD_GRAYSCALE)
        return img


# --------------------------------------------------------------------------
# Scenarios: illumination over time, projector behavior, tag visibility
# --------------------------------------------------------------------------

class Scenario:
    """
    Subclass hooks:
      ambient(t) -> float            global illumination multiplier
      spatial() -> HxW float32       static spatial illumination multiplier
      shadow(t) -> HxW float32|None  multiplicative shadow field
      projector(t, feedback) -> HxW float32|None  additive radiance
      tags_visible(t) -> bool
      start_exposure_us
      duration_s
    """
    name = "base"
    duration_s = 20.0
    start_exposure_us = 4000
    events = []  # list of times where a step change happens (for convergence metrics)
    projector_feedback = False

    def __init__(self, scene):
        self.scene = scene
        H, W = scene.H, scene.W
        self.yy, self.xx = np.mgrid[0:H, 0:W].astype(np.float32)
        self._spatial = self.spatial()

    def ambient(self, t):
        return 1.0

    def spatial(self):
        return np.ones((self.scene.H, self.scene.W), dtype=np.float32)

    def shadow(self, t):
        return None

    def projector(self, t, detected_ids):
        return None

    def tags_visible(self, t):
        return True

    def radiance(self, t, detected_ids, rng):
        sc = self.scene
        illum = self._spatial * np.float32(self.ambient(t))
        sh = self.shadow(t)
        if sh is not None:
            illum = illum * sh
        R = sc.R if self.tags_visible(t) else self.cover_R()
        rad = R * illum
        pj = self.projector(t, detected_ids)
        if pj is not None:
            # projected light reflects off the surface (reflectance applies)
            rad = rad + pj * R
        return rad.astype(np.float32)

    def cover_R(self):
        if not hasattr(self, "_cover"):
            # cover the tags with a plain sheet (paper white)
            self._cover = np.where(self.scene.tag_mask > 0.5, PAPER_WHITE, self.scene.R).astype(np.float32)
        return self._cover

    # helpers
    def window_gradient(self, left=1.0, right=1.0):
        W = self.scene.W
        g = left + (right - left) * (self.xx / (W - 1))
        return g.astype(np.float32)

    def ellipse_shadow(self, cx, cy, rx, ry, depth=0.7, soft=18.0):
        d = ((self.xx - cx) / rx) ** 2 + ((self.yy - cy) / ry) ** 2
        core = np.clip(1.0 - d, 0, 1)
        core = (core > 0).astype(np.float32)
        core = cv2.GaussianBlur(core, (0, 0), soft)
        return (1.0 - depth * core).astype(np.float32)

    def rect_light(self, x0, y0, x1, y1, power, soft=2.0):
        m = np.zeros((self.scene.H, self.scene.W), dtype=np.float32)
        m[int(y0):int(y1), int(x0):int(x1)] = 1.0
        if soft:
            m = cv2.GaussianBlur(m, (0, 0), soft)
        return m * np.float32(power)


class SteadyFromDark(Scenario):
    name = "steady_from_dark"
    duration_s = 15.0
    start_exposure_us = 600


class SteadyFromBright(Scenario):
    name = "steady_from_bright"
    duration_s = 20.0
    start_exposure_us = 20000  # badly overexposed: tags saturate -> maybe undetectable


class WindowDrift(Scenario):
    """Window light swinging 16x (0.25..4x room light) over a 30s cycle."""
    name = "window_drift"
    duration_s = 60.0
    start_exposure_us = 4000

    def ambient(self, t):
        return 4.0 ** math.sin(2 * math.pi * t / 30.0)

    def spatial(self):
        return self.window_gradient(1.3, 0.75)


class CloudSteps(Scenario):
    name = "cloud_steps"
    duration_s = 45.0
    start_exposure_us = 4000
    events = [10.0, 25.0, 35.0]

    def ambient(self, t):
        if t < 10:
            return 1.0
        if t < 25:
            return 5.0
        if t < 35:
            return 0.2
        return 1.0

    def spatial(self):
        return self.window_gradient(1.2, 0.8)


class MixedIllumination(Scenario):
    """Sun on the left half, shade on the right: no single exposure is ideal."""
    name = "mixed_illumination"
    duration_s = 30.0
    start_exposure_us = 4000

    def spatial(self):
        return self.window_gradient(2.8, 0.3)


class ProjectorFeedback(Scenario):
    """
    Dim room. The projector draws an overlay next to tag 1 *only while tag 1
    is detected* (like Folk drawing a program's outline/labels), and the
    overlay spills onto 30% of the tag. Tag 3 has an unrelated 2Hz blinking
    projected element on top of it.
    """
    name = "projector_feedback"
    duration_s = 30.0
    start_exposure_us = 4000
    projector_feedback = True

    ambient_level = 0.35
    P = 3.0          # projector white relative to unit ambient (~8x the room light)
    spill = 0.45     # fraction of tag 1's width covered by the feedback overlay

    def ambient(self, t):
        return self.ambient_level

    def projector(self, t, detected_ids):
        sc = self.scene
        add = np.full((sc.H, sc.W), 0.02 * self.P, dtype=np.float32)  # projector black level
        P = self.P
        pl1 = sc.placements[1]
        x0, y0, x1, y1 = pl1.bbox
        if 1 in detected_ids:
            # overlay to the left of tag 1, spilling onto part of its width
            w = x1 - x0
            add += self.rect_light(x0 - 90, y0 - 10, x0 + self.spill * w, y1 + 10, P)
        pl3 = sc.placements[3]
        x0, y0, x1, y1 = pl3.bbox
        if int(t * 4) % 2 == 0:  # 2 Hz blink
            w = x1 - x0
            add += self.rect_light(x0 + 0.55 * w, y0 - 20, x1 + 60, y1 + 20, P)
        return add


class ProjectorFeedbackMild(ProjectorFeedback):
    """Same, but the overlay only grazes the tag (15%) and the room is brighter."""
    name = "projector_feedback_mild"
    ambient_level = 0.7
    P = 2.0
    spill = 0.15


class HandShadow(Scenario):
    name = "hand_shadow"
    duration_s = 30.0
    start_exposure_us = 4000

    def spatial(self):
        return self.window_gradient(1.2, 0.8)

    def shadow(self, t):
        # a soft arm/hand shadow sweeping left->right every 6s
        period = 6.0
        u = (t % period) / period
        cx = -120 + u * (self.scene.W + 240)
        cy = 240 + 80 * math.sin(2 * math.pi * t / 7.0)
        return self.ellipse_shadow(cx, cy, 130, 90, depth=0.85, soft=22.0)


class Specular(Scenario):
    name = "specular"
    duration_s = 20.0
    start_exposure_us = 4000

    def projector(self, t, detected_ids):
        # a static specular highlight (e.g. lamp reflection in glossy paper) on tag 0
        pl = self.scene.placements[0]
        cx = pl.cx + 14
        cy = pl.cy - 10
        d2 = (self.xx - cx) ** 2 + (self.yy - cy) ** 2
        return (4.0 * np.exp(-d2 / (2 * 22.0 ** 2))).astype(np.float32)


class LowLight(Scenario):
    name = "low_light"
    duration_s = 30.0
    start_exposure_us = 4000

    def ambient(self, t):
        return 0.11


class BrightSun(Scenario):
    """Direct sun on the table (~30x room light). Only very short exposures
    keep the black cells from washing out; tests the lower exposure clamp."""
    name = "bright_sun"
    duration_s = 30.0
    start_exposure_us = 4000

    def ambient(self, t):
        return 30.0

    def spatial(self):
        return self.window_gradient(1.3, 0.8)


class TagsAppearLate(Scenario):
    """No tags on the table for 10s while exposure starts badly; then tags appear."""
    name = "tags_appear_late"
    duration_s = 30.0
    start_exposure_us = 20000
    events = [10.0]

    def tags_visible(self, t):
        return t >= 10.0


class LightJitter(Scenario):
    """LED/PWM beat: per-frame random brightness jitter plus slow drift."""
    name = "light_jitter"
    duration_s = 30.0
    start_exposure_us = 4000

    def __init__(self, scene):
        super().__init__(scene)
        self._rng = np.random.default_rng(1234)

    def ambient(self, t):
        return (2.5 ** math.sin(2 * math.pi * t / 20.0)) * (1.0 + 0.18 * self._rng.standard_normal())


class WindowDriftMixed(Scenario):
    """Strong gradient *and* drifting ambient: the hardest realistic case."""
    name = "window_drift_mixed"
    duration_s = 60.0
    start_exposure_us = 4000

    def ambient(self, t):
        return 3.5 ** math.sin(2 * math.pi * t / 25.0)

    def spatial(self):
        return self.window_gradient(2.2, 0.45)


SCENARIOS = {c.name: c for c in [
    SteadyFromDark, SteadyFromBright, WindowDrift, CloudSteps, MixedIllumination,
    ProjectorFeedback, ProjectorFeedbackMild, HandShadow, Specular, LowLight, BrightSun,
    TagsAppearLate, LightJitter, WindowDriftMixed,
]}


# --------------------------------------------------------------------------
# Tag statistics (mirrors autoExposureStats in camera/autoexposure.folk)
# --------------------------------------------------------------------------

def quad_stats(frame, corners, samples=64):
    """Sample a 64x64 grid in tag-local coords inside the detected quad.
    Returns dict(count, white, black, sat_frac, p95, p05)."""
    c = np.asarray(corners, dtype=np.float64)
    u = (np.arange(samples) + 0.5) / samples
    v = u
    top = c[0][None, :] + u[:, None] * (c[1] - c[0])[None, :]
    bot = c[3][None, :] + u[:, None] * (c[2] - c[3])[None, :]
    pts = top[None, :, :] + v[:, None, None] * (bot - top)[None, :, :]
    x = np.floor(pts[..., 0] + 0.5).astype(int).ravel()
    y = np.floor(pts[..., 1] + 0.5).astype(int).ravel()
    H, W = frame.shape
    ok = (x >= 0) & (y >= 0) & (x < W) & (y < H)
    if not ok.any():
        return {"count": 0, "white": 0.0, "black": 0.0, "sat_frac": 0.0}
    vals = np.sort(frame[y[ok], x[ok]].astype(np.float64))
    n = vals.size
    q = max(1, n // 4)
    white_vals = vals[-q:]
    black_vals = vals[:q]
    return {
        "count": int(n),
        "white": float(white_vals.mean()),
        "black": float(black_vals.mean()),
        "sat_frac": float((white_vals >= 250).mean()),
        "p95": float(vals[int(0.95 * (n - 1))]),
        "p05": float(vals[int(0.05 * (n - 1))]),
    }


# --------------------------------------------------------------------------
# Simulation loop
# --------------------------------------------------------------------------

def run(controller, scenario_name, seed=0, fps=30, width=640, height=480,
        quad_decimate=2.0, jpeg_quality=85, latency_frames=2, record_frames=None,
        placements=None, verbose=False):
    """
    controller: object with .reset(start_exposure_us, cam) and
                .step(frame, dets, exposure_cmd_us, t) -> new exposure (int us)
    """
    atl = AprilTagLib(quad_decimate=quad_decimate)
    scene = Scene(atl, width, height, placements or default_placements(), seed=seed)
    scen = SCENARIOS[scenario_name](scene)
    cam = Camera(jpeg_quality=jpeg_quality, latency_frames=latency_frames)
    rng = np.random.default_rng(seed + 17)

    nframes = int(scen.duration_s * fps)
    exposure_cmd = cam.quantize_exposure(scen.start_exposure_us)
    pipeline = [exposure_cmd] * (latency_frames + 1)
    controller.reset(exposure_cmd, cam)

    tag_ids = [pl.tag_id for pl in scene.placements]
    det_hist = {tid: [] for tid in tag_ids}
    margin_hist = {tid: [] for tid in tag_ids}
    exp_hist = []
    applied_hist = []
    changes = 0
    last_detected = set()
    frames_saved = []
    t_detect = 0.0

    for f in range(nframes):
        t = f / fps
        applied = pipeline.pop(0)
        rad = scen.radiance(t, last_detected if scen.projector_feedback else set(), rng)
        frame = cam.capture(rad, applied, rng)
        t0 = time.perf_counter()
        dets = atl.detect(frame)
        t_detect += time.perf_counter() - t0
        det_ids = {d["id"] for d in dets if d["hamming"] <= 1}
        visible = scen.tags_visible(t)
        for tid in tag_ids:
            det_hist[tid].append(1 if (tid in det_ids) else (0 if visible else -1))
            m = [d["margin"] for d in dets if d["id"] == tid]
            margin_hist[tid].append(m[0] if m else float("nan"))
        last_detected = det_ids
        exp_hist.append(exposure_cmd)
        applied_hist.append(applied)
        if record_frames and f in record_frames:
            frames_saved.append((f, frame.copy(), [d["p"] for d in dets]))

        new_cmd = controller.step(frame, dets, exposure_cmd, t)
        new_cmd = cam.quantize_exposure(new_cmd)
        if new_cmd != exposure_cmd:
            changes += 1
            exposure_cmd = new_cmd
        pipeline.append(exposure_cmd)

    metrics = compute_metrics(det_hist, margin_hist, exp_hist, scen, fps, changes)
    metrics["detect_ms_per_frame"] = 1000.0 * t_detect / nframes
    result = {
        "controller": controller.name,
        "scenario": scenario_name,
        "seed": seed,
        "fps": fps,
        "metrics": metrics,
        "timeline": {
            "exposure_us": exp_hist,
            "detected": det_hist,
            "margin": {k: [None if math.isnan(x) else round(x, 2) for x in v] for k, v in margin_hist.items()},
        },
    }
    if record_frames:
        result["_frames"] = frames_saved
    return result


def compute_metrics(det_hist, margin_hist, exp_hist, scen, fps, changes):
    tag_ids = list(det_hist.keys())
    n = len(exp_hist)
    D = np.array([det_hist[t] for t in tag_ids])  # tags x frames, -1 = not visible
    vis = D[0] >= 0
    nvis = int(vis.sum())
    all_det = (D[:, vis] == 1).all(axis=0) if nvis else np.array([], dtype=bool)
    any_det = (D[:, vis] == 1).any(axis=0) if nvis else np.array([], dtype=bool)
    per_tag = {str(t): float((D[i, vis] == 1).mean()) if nvis else 0.0 for i, t in enumerate(tag_ids)}
    # flicker: detected<->undetected transitions per tag per minute (visible frames only)
    flick = 0
    for i in range(len(tag_ids)):
        s = D[i, vis]
        if s.size > 1:
            flick += int(np.abs(np.diff(s)).sum())
    minutes = max(1e-9, nvis / fps / 60.0)
    # convergence: frames until all tags detected continuously for 1s, measured
    # from start and after each event
    conv = []
    starts = [0] + [int(e * fps) for e in scen.events]
    for s0 in starts:
        c = None
        win = fps
        for f in range(s0, n - win):
            if D[:, f:f + win].min() == 1:
                c = (f - s0) / fps
                break
        conv.append(c)
    E = np.array(exp_hist, dtype=np.float64)
    tail = E[int(0.6 * n):]
    margins = np.array([m for t in tag_ids for m in margin_hist[t] if not math.isnan(m)])
    return {
        "all_tags_rate": float(all_det.mean()) if nvis else 0.0,
        "any_tag_rate": float(any_det.mean()) if nvis else 0.0,
        "mean_tag_rate": float(np.mean(list(per_tag.values()))),
        "per_tag_rate": per_tag,
        "flicker_per_min": float(flick / minutes),
        "converge_s": conv,
        "exposure_changes": int(changes),
        "exposure_changes_per_min": float(changes / (n / fps / 60.0)),
        "exposure_tail_std_log": float(np.std(np.log(tail))) if tail.size else 0.0,
        "exposure_final_us": int(E[-1]),
        "exposure_mean_us": float(E.mean()),
        "frac_over_16ms": float((E > 16667).mean()),
        "mean_margin": float(margins.mean()) if margins.size else 0.0,
        "min_margin_p10": float(np.percentile(margins, 10)) if margins.size else 0.0,
    }


def main():
    import controllers
    ap = argparse.ArgumentParser()
    ap.add_argument("--controller", required=True)
    ap.add_argument("--scenario", required=True)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--out", default=None)
    ap.add_argument("--save-frames", default=None, help="dir to dump sample frames as PNG")
    ap.add_argument("--latency", type=int, default=2)
    args = ap.parse_args()
    ctl = controllers.make(args.controller)
    rec = None
    if args.save_frames:
        rec = set(range(0, 100000, 150))
    res = run(ctl, args.scenario, seed=args.seed, fps=args.fps, latency_frames=args.latency,
              record_frames=rec)
    if args.save_frames:
        os.makedirs(args.save_frames, exist_ok=True)
        for f, img, quads in res.pop("_frames"):
            vis = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
            for q in quads:
                pts = np.int32(q).reshape(-1, 1, 2)
                cv2.polylines(vis, [pts], True, (0, 255, 0), 1)
            cv2.imwrite(os.path.join(args.save_frames,
                                     f"{args.controller}_{args.scenario}_f{f:05d}.png"), vis)
    m = res["metrics"]
    print(json.dumps({k: v for k, v in m.items()}, indent=1))
    if args.out:
        with open(args.out, "w") as fh:
            json.dump(res, fh)


if __name__ == "__main__":
    main()
