"""
Autoexposure controllers for the AprilTag simulation.

Interface:
    ctl.name
    ctl.reset(start_exposure_us, cam)
    ctl.step(frame_u8, dets, exposure_cmd_us, t) -> next exposure (int us)

`dets` is a list of {"id", "hamming", "margin", "c", "p"} from the real
detector (p = 4 corners of the tag border quad). `frame_u8` is the gray
frame. Controllers may only use what a Folk program would have: the gray
frame, the detections, the currently *commanded* exposure, and their own
state. The camera's actual applied exposure lags by a couple of frames.

Add a controller by subclassing Controller and registering it in REGISTRY.
"""
import math
import numpy as np

from atsim import quad_stats


class Controller:
    name = "base"

    def reset(self, start_exposure_us, cam):
        self.cam = cam
        self.frame_i = 0

    def step(self, frame, dets, exposure_cmd, t):
        raise NotImplementedError


# --------------------------------------------------------------------------
# Baselines
# --------------------------------------------------------------------------

class Fixed(Controller):
    """What users have today: a manual exposure chosen once."""
    def __init__(self, us=4000):
        self.us = us
        self.name = f"fixed_{us}"

    def step(self, frame, dets, exposure_cmd, t):
        return self.us


class V4L2Auto(Controller):
    """
    Stand-in for the camera's built-in (aperture-priority) AE: drives the
    *whole-frame* mean luminance toward a target, slowly, in the log domain.
    Not tag-aware. Real UVC AE also adjusts gain; we fold that into exposure.
    """
    name = "v4l2_auto"

    def __init__(self, target=105.0, gain=0.35, period=2, lo=300, hi=33000):
        self.target, self.gain, self.period, self.lo, self.hi = target, gain, period, lo, hi

    def step(self, frame, dets, exposure_cmd, t):
        self.frame_i += 1
        if self.frame_i % self.period:
            return exposure_cmd
        mean = float(frame.mean())
        # work in linear-ish domain: luminance ~ exposure^(1/gamma)
        ratio = (self.target / max(mean, 1.0)) ** 2.2
        ratio = min(2.0, max(0.5, ratio))
        nxt = exposure_cmd * math.exp(self.gain * math.log(ratio))
        return int(min(self.hi, max(self.lo, nxt)))


# --------------------------------------------------------------------------
# The osnr/apriltag-autoexposure branch, reproduced
# --------------------------------------------------------------------------

def _branch_white(frame, dets):
    """avgWhite exactly as the branch computes it: mean over tags of the
    top-quartile mean of 64x64 samples inside the detected quad."""
    whites = []
    for d in dets:
        st = quad_stats(frame, d["p"])
        if st["count"] == 0:
            continue
        whites.append(st["white"])
    return whites


class BranchFinal(Controller):
    """
    builtin-programs/camera/autoexposure.folk @ 1f0595f2 (branch tip):
      target = cur * 250 / avgWhite
      next = 0.8*cur + 0.2*target, clamp [1000, 15000]
      apply only if int(next/100) != int(cur/100)
      then `sleep 5` (seconds!) -> period ~ 5s between updates
    `period_frames` lets us separate the control law from the cadence.
    """
    def __init__(self, period_frames=150, target=250.0, lo=1000, hi=15000, name=None):
        self.period_frames = period_frames
        self.target, self.lo, self.hi = target, lo, hi
        self.name = name or f"branch_final_p{period_frames}"

    def reset(self, start, cam):
        super().reset(start, cam)
        self.next_allowed = 0

    def step(self, frame, dets, exposure_cmd, t):
        self.frame_i += 1
        if self.frame_i < self.next_allowed:
            return exposure_cmd
        whites = _branch_white(frame, dets)
        if not whites:
            self.next_allowed = self.frame_i + self.period_frames
            return exposure_cmd
        avg = sum(whites) / len(whites)
        denom = max(avg, 1.0)
        target = int(exposure_cmd * self.target / denom)
        nxt = int(0.8 * exposure_cmd + 0.2 * target)
        nxt = min(self.hi, max(self.lo, nxt))
        self.next_allowed = self.frame_i + self.period_frames
        if int(nxt / 100) != int(exposure_cmd / 100):
            return nxt
        return exposure_cmd


class BranchV1(Controller):
    """
    autoexposure.folk @ a131ec8b (first version): deadband 180..240 on
    avgWhite, minimum +-100us step, black>80 -> *0.9, clamp [1000,10000].
    """
    def __init__(self, period_frames=150, name=None):
        self.period_frames = period_frames
        self.name = name or f"branch_v1_p{period_frames}"

    def reset(self, start, cam):
        super().reset(start, cam)
        self.next_allowed = 0

    def step(self, frame, dets, exposure_cmd, t):
        self.frame_i += 1
        if self.frame_i < self.next_allowed:
            return exposure_cmd
        ws, bs = [], []
        for d in dets:
            st = quad_stats(frame, d["p"])
            if st["count"] == 0:
                continue
            ws.append(st["white"]); bs.append(st["black"])
        self.next_allowed = self.frame_i + self.period_frames
        if not ws:
            return exposure_cmd
        avgW = sum(ws) / len(ws); avgB = sum(bs) / len(bs)
        cur = exposure_cmd
        nxt = cur
        if avgW < 180:
            nxt = int(cur * 210.0 / max(avgW, 1.0))
            nxt = max(nxt, cur + 100)
            nxt = min(nxt, 10000)
        elif avgW > 240:
            nxt = int(cur * 220.0 / avgW)
            nxt = min(nxt, cur - 100)
            nxt = max(nxt, 1000)
        elif avgB > 80 and cur > 1000:
            nxt = max(int(cur * 0.9), 1000)
        return nxt


# --------------------------------------------------------------------------
# Proposed controllers (small, targeted changes to the branch's law)
# --------------------------------------------------------------------------

class Proposal(Controller):
    """
    Common machinery for the proposals. Each knob corresponds to one small
    diff against the branch:

      target/deadband : aim whites at ~200 (not 250) with a +-deadband so
                        noise does not cause churn
      aggregate       : 'mean' (branch) | 'median' | 'min' | 'max' | 'geomean'
                        across tags
      clip_aware      : if the white samples are saturating, we cannot
                        measure how overexposed we are; force a fixed
                        decrease instead of trusting 250/255
      log_gain        : proportional step in the log domain with a max
                        per-step ratio (replaces the 0.8/0.2 EMA)
      period_frames   : control cadence (1 = every detection)
      hold_frames     : minimum frames between actuator writes
      fallback        : when no tags are detected for `lost_frames`,
                        sweep exposure geometrically through the range so
                        the loop cannot get stuck saturated/black
      lo/hi           : exposure clamp (us)
    """
    def __init__(self, name, target=200.0, deadband=12.0, aggregate="median",
                 clip_aware=True, clip_frac=0.25, clip_step=0.7, log_gain=0.6,
                 max_ratio=1.5, period_frames=1, hold_frames=3, fallback=True,
                 lost_frames=15, lo=300, hi=16000, persist_frames=2, sweep_period=12):
        self.name = name
        self.target, self.deadband, self.aggregate = target, deadband, aggregate
        self.clip_aware, self.clip_frac, self.clip_step = clip_aware, clip_frac, clip_step
        self.log_gain, self.max_ratio = log_gain, max_ratio
        self.period_frames, self.hold_frames = period_frames, hold_frames
        self.fallback, self.lost_frames = fallback, lost_frames
        self.lo, self.hi = lo, hi
        self.persist_frames = persist_frames
        self.sweep_period = sweep_period

    def reset(self, start, cam):
        super().reset(start, cam)
        self.last_write = -10**9
        self.lost = 0
        self.sweep_dir = +1
        self.err_sign_run = 0
        self.last_sign = 0

    def _fallback(self, cur):
        """No decodable tag: after lost_frames control steps, sweep the range
        geometrically, one step every sweep_period frames (0.4s at 30fps)."""
        self.lost += 1
        if self.fallback and self.lost >= self.lost_frames and \
                self.frame_i - self.last_write >= max(self.hold_frames, self.sweep_period):
            nxt = int(cur * 1.6) // 100 * 100 if self.sweep_dir > 0 else int(cur / 1.6) // 100 * 100
            if nxt >= self.hi:
                nxt, self.sweep_dir = self.hi, -1
            if nxt <= self.lo:
                nxt, self.sweep_dir = self.lo, +1
            self.last_write = self.frame_i
            return int(nxt)
        return cur

    def aggregate_whites(self, stats):
        ws = np.array([s["white"] for s in stats])
        a = self.aggregate
        if a == "mean":
            return float(ws.mean())
        if a == "median":
            return float(np.median(ws))
        if a == "min":
            return float(ws.min())
        if a == "max":
            return float(ws.max())
        if a == "geomean":
            return float(np.exp(np.log(np.maximum(ws, 1)).mean()))
        raise ValueError(a)

    def step(self, frame, dets, exposure_cmd, t):
        self.frame_i += 1
        if self.frame_i % self.period_frames:
            return exposure_cmd
        stats = [quad_stats(frame, d["p"]) for d in dets if d["hamming"] <= 1]
        stats = [s for s in stats if s["count"] > 0]
        cur = exposure_cmd
        if not stats:
            return self._fallback(cur)
        self.lost = 0
        if self.frame_i - self.last_write < self.hold_frames:
            return cur
        white = self.aggregate_whites(stats)
        sat = float(np.median([s["sat_frac"] for s in stats])) if self.aggregate == "median" \
            else float(np.mean([s["sat_frac"] for s in stats]))
        if self.clip_aware and sat > self.clip_frac:
            ratio = self.clip_step
        else:
            err = self.target - white
            if abs(err) <= self.deadband:
                self.err_sign_run = 0
                return cur
            # require the error to persist for a couple of control steps
            sign = 1 if err > 0 else -1
            self.err_sign_run = self.err_sign_run + 1 if sign == self.last_sign else 1
            self.last_sign = sign
            if self.err_sign_run < self.persist_frames:
                return cur
            # pixel value ~ exposure^(1/2.2) so exposure ratio ~ (target/white)^2.2
            ratio = (self.target / max(white, 1.0)) ** 2.2
            ratio = math.exp(self.log_gain * math.log(ratio))
            ratio = min(self.max_ratio, max(1 / self.max_ratio, ratio))
        nxt = int(cur * ratio) // 100 * 100
        if nxt == cur:
            nxt = cur + 100 if ratio > 1.0 else cur - 100
        nxt = int(min(self.hi, max(self.lo, nxt)))
        if nxt == cur:
            return cur
        self.last_write = self.frame_i
        return nxt


class ContrastProposal(Proposal):
    """
    Like Proposal but with a *per-tag* objective: each tag wants its white
    in [white_lo, white_hi] and its contrast (white-black) >= min_contrast.
    The exposure ratio is chosen so the brightest tag does not clip
    (upper bound from max white) while lifting the darkest tag as far as
    that bound allows. This is the 'target contrast / protect everyone'
    option from the iMessage thread.
    """
    def __init__(self, name, white_lo=150.0, white_hi=235.0, min_contrast=50.0, **kw):
        super().__init__(name, **kw)
        self.white_lo, self.white_hi, self.min_contrast = white_lo, white_hi, min_contrast

    def step(self, frame, dets, exposure_cmd, t):
        self.frame_i += 1
        if self.frame_i % self.period_frames:
            return exposure_cmd
        stats = [quad_stats(frame, d["p"]) for d in dets if d["hamming"] <= 1]
        stats = [s for s in stats if s["count"] > 0]
        cur = exposure_cmd
        if not stats:
            return self._fallback(cur)
        self.lost = 0
        if self.frame_i - self.last_write < self.hold_frames:
            return cur
        whites = np.array([s["white"] for s in stats])
        sats = np.array([s["sat_frac"] for s in stats])
        wmax, wmin = float(whites.max()), float(whites.min())
        # upper bound on ratio so the brightest tag stays below white_hi
        r_hi = (self.white_hi / max(wmax, 1.0)) ** 2.2
        # desired ratio to bring the darkest tag to the middle of the band
        r_lo = (0.5 * (self.white_lo + self.white_hi) / max(wmin, 1.0)) ** 2.2
        if sats.max() > self.clip_frac:
            ratio = self.clip_step
        elif wmin >= self.white_lo and wmax <= self.white_hi:
            self.err_sign_run = 0
            return cur
        else:
            ratio = min(r_hi, r_lo)
            if ratio < 1.0 and wmax <= self.white_hi:
                # nothing is clipping; do not darken just because the
                # darkest tag's ideal is unreachable
                ratio = max(ratio, 1.0)
            ratio = math.exp(self.log_gain * math.log(ratio))
            ratio = min(self.max_ratio, max(1 / self.max_ratio, ratio))
            if abs(math.log(ratio)) < math.log(1.03):
                return cur
        nxt = int(cur * ratio) // 100 * 100
        if nxt == cur:
            nxt = cur + 100 if ratio > 1.0 else cur - 100
        nxt = int(min(self.hi, max(self.lo, nxt)))
        if nxt == cur:
            return cur
        self.last_write = self.frame_i
        return nxt


class MarginHillClimb(Proposal):
    """
    Experimental: uses the detector's decision margin (exposed via a 1-line
    change to apriltags.folk) and hill-climbs exposure to maximize the
    minimum margin across tags. Falls back to the white-target law when
    margins are unavailable. Changes exposure in small steps and keeps the
    direction while min-margin improves.
    """
    def __init__(self, name, step_ratio=1.12, **kw):
        super().__init__(name, **kw)
        self.step_ratio = step_ratio

    def reset(self, start, cam):
        super().reset(start, cam)
        self.dir = +1
        self.prev_score = None
        self.prev_n = 0

    def step(self, frame, dets, exposure_cmd, t):
        self.frame_i += 1
        if self.frame_i % self.period_frames:
            return exposure_cmd
        good = [d for d in dets if d["hamming"] <= 1]
        cur = exposure_cmd
        if not good:
            self.prev_score = None
            return self._fallback(cur)
        self.lost = 0
        if self.frame_i - self.last_write < self.hold_frames:
            return cur
        stats = [quad_stats(frame, d["p"]) for d in good]
        sat = float(np.max([s["sat_frac"] for s in stats]))
        n = len(good)
        score = min(d["margin"] for d in good) + 1000 * n  # more tags always wins
        if sat > self.clip_frac:
            ratio = self.clip_step
        elif self.prev_score is not None and score < self.prev_score - 1.0:
            self.dir = -self.dir
            ratio = self.step_ratio ** self.dir
        elif self.prev_score is not None and abs(score - self.prev_score) <= 1.0:
            # plateau: hold
            self.prev_score = score
            return cur
        else:
            ratio = self.step_ratio ** self.dir
        self.prev_score = score
        nxt = int(min(self.hi, max(self.lo, cur * ratio)))
        if int(nxt / 100) == int(cur / 100):
            return cur
        self.last_write = self.frame_i
        return nxt



# --------------------------------------------------------------------------
# Registry
# --------------------------------------------------------------------------

def make(name):
    if name in REGISTRY:
        return REGISTRY[name]()
    raise KeyError(f"unknown controller {name}; known: {sorted(REGISTRY)}")


REGISTRY = {
    # baselines
    "fixed_4000": lambda: Fixed(4000),
    "v4l2_auto": lambda: V4L2Auto(),
    # the branch as it is (sleep 5 => ~5s period at 30fps) and with the
    # cadence fixed, to separate the two problems
    "branch_asis": lambda: BranchFinal(period_frames=150, name="branch_asis"),
    "branch_fast": lambda: BranchFinal(period_frames=1, name="branch_fast"),
    "branch_v1_fast": lambda: BranchV1(period_frames=1, name="branch_v1_fast"),
    # single-knob diffs on top of branch_fast, to attribute the gains
    "branch_fast_t200": lambda: BranchFinal(period_frames=1, target=200.0, name="branch_fast_t200"),
    "branch_fast_t200_lo300": lambda: BranchFinal(period_frames=1, target=200.0, lo=300, name="branch_fast_t200_lo300"),
    # proposals
    "prop_white_median": lambda: Proposal("prop_white_median", aggregate="median"),
    "prop_white_mean": lambda: Proposal("prop_white_mean", aggregate="mean"),
    "prop_white_min": lambda: Proposal("prop_white_min", aggregate="min"),
    "prop_white_max": lambda: Proposal("prop_white_max", aggregate="max"),
    "prop_white_median_noclip": lambda: Proposal("prop_white_median_noclip", aggregate="median", clip_aware=False),
    "prop_white_median_nofallback": lambda: Proposal("prop_white_median_nofallback", aggregate="median", fallback=False),
    "prop_white_median_p5": lambda: Proposal("prop_white_median_p5", aggregate="median", period_frames=5),
    "prop_contrast": lambda: ContrastProposal("prop_contrast"),
    "prop_contrast_p5": lambda: ContrastProposal("prop_contrast_p5", period_frames=5),
    "prop_margin": lambda: MarginHillClimb("prop_margin"),
}


# --------------------------------------------------------------------------
# Plugins: any ctl_*.py next to this file may define REGISTRY = {name: factory}
# (or a register(REGISTRY) function). Used by workflow agents to add variants
# without editing this file.
# --------------------------------------------------------------------------

def _load_plugins():
    import glob as _glob
    import importlib.util as _ilu
    import os as _os
    here = _os.path.dirname(_os.path.abspath(__file__))
    for path in sorted(_glob.glob(_os.path.join(here, "ctl_*.py"))):
        modname = _os.path.splitext(_os.path.basename(path))[0]
        try:
            spec = _ilu.spec_from_file_location(modname, path)
            mod = _ilu.module_from_spec(spec)
            spec.loader.exec_module(mod)
        except Exception as e:  # a broken plugin must not take down the matrix
            print(f"controllers: failed to load plugin {path}: {e}", file=sys.stderr)
            continue
        if hasattr(mod, "register"):
            mod.register(REGISTRY)
        elif hasattr(mod, "REGISTRY"):
            REGISTRY.update(mod.REGISTRY)


import sys
_load_plugins()
