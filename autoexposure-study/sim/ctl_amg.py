"""
Controllers for evaluating amg/autoexposure (Audrey's branch) and the code
suggested on top of it. Each one adds a single step, so the simulation can
say what each suggested commit buys:

  amg_asis          the branch today: it measures and prints, but never
                    sets exposure, so the camera stays where it started
  amg_minmax_1hz    the shortest path from the branch's TODOs to a working
                    loop: its own statistic (single brightest pixel in the
                    tag's axis-aligned bounding box), averaged over tags,
                    driven toward 200 once a second (its `sleep 1`)
  amg_quartile_1hz  + statistics inside the quad: top-quartile mean,
                    clip-aware, median across tags (suggested commit 2)
  amg_quartile_10hz + ~10 Hz cadence instead of `sleep 1`
  amg_suggested     + sweep when no tag is visible, bounded: after touching
                    both ends it returns home and rests 5 s. This mirrors
                    builtin-programs/camera/autoexposure.folk as suggested
                    (range 300..15000 us, corners one frame stale).
"""
import math
import numpy as np

from controllers import Controller, Proposal


class HoldStart(Controller):
    name = "amg_asis"

    def step(self, frame, dets, exposure_cmd, t):
        return exposure_cmd


def aabb_brightest(frame, corners):
    """getTagLocalContrast @ 3fece215: min/max over the bounding box of the
    4 corners (int-truncated, max exclusive), here clamped to the frame."""
    H, W = frame.shape
    xs = [int(c[0]) for c in corners]
    ys = [int(c[1]) for c in corners]
    x0, x1 = max(0, min(xs)), min(W, max(xs))
    y0, y1 = max(0, min(ys)), min(H, max(ys))
    if x1 <= x0 or y1 <= y0:
        return None
    roi = frame[y0:y1, x0:x1]
    return int(roi.max()), int(roi.min())


class MinMax(Controller):
    def __init__(self, name, period_frames=30, target=200.0, deadband=12.0,
                 log_gain=0.6, max_ratio=1.5, lo=300, hi=15000):
        self.name = name
        self.period_frames = period_frames
        self.target, self.deadband = target, deadband
        self.log_gain, self.max_ratio, self.lo, self.hi = log_gain, max_ratio, lo, hi

    def step(self, frame, dets, exposure_cmd, t):
        self.frame_i += 1
        if self.frame_i % self.period_frames:
            return exposure_cmd
        brights = [s[0] for s in (aabb_brightest(frame, d["p"]) for d in dets) if s]
        if not brights:
            return exposure_cmd
        white = sum(brights) / len(brights)
        if abs(self.target - white) <= self.deadband:
            return exposure_cmd
        ratio = (self.target / max(white, 1.0)) ** (2.2 * self.log_gain)
        ratio = min(self.max_ratio, max(1 / self.max_ratio, ratio))
        cur = exposure_cmd
        nxt = int(cur * ratio) // 100 * 100
        if nxt == cur:
            nxt = cur + 100 if ratio > 1.0 else cur - 100
        return int(min(self.hi, max(self.lo, nxt)))


class Suggested(Proposal):
    """Proposal law + the Folk program's plumbing: detections that are one
    frame old, no hamming filter (apriltags.folk does not report it), upper
    median, and the bounded sweep (home + 5 s rest)."""

    def __init__(self, name, det_lag=1, rest_s=5.0, fps=30, **kw):
        kw.setdefault("aggregate", "median")
        kw.setdefault("persist_frames", 1)
        kw.setdefault("hold_frames", 0)
        kw.setdefault("period_frames", 3)
        kw.setdefault("lost_frames", 5)
        kw.setdefault("lo", 300)
        kw.setdefault("hi", 15000)
        super().__init__(name, **kw)
        self.det_lag, self.rest_frames = det_lag, int(rest_s * fps)

    def reset(self, start, cam):
        super().reset(start, cam)
        self.det_q = []
        self.home, self.bounces, self.rest_until = None, 0, 0

    def aggregate_whites(self, stats):
        if self.aggregate == "median":
            ws = sorted(s["white"] for s in stats)
            return ws[len(ws) // 2]
        return super().aggregate_whites(stats)

    def _fallback(self, cur):
        self.lost += 1
        if not self.fallback or self.lost < self.lost_frames:
            return cur
        if self.frame_i < self.rest_until or self.frame_i - self.last_write < self.sweep_period:
            return cur
        if self.home is None:
            self.home, self.bounces = cur, 0
        self.last_write = self.frame_i
        if self.bounces >= 2:
            nxt, self.home = self.home, None
            self.rest_until = self.frame_i + self.rest_frames
            return int(nxt)
        if self.sweep_dir > 0:
            nxt = int(cur * 1.6) // 100 * 100
            if nxt >= self.hi:
                nxt, self.sweep_dir = self.hi, -1
                self.bounces += 1
        else:
            nxt = int(cur / 1.6) // 100 * 100
            if nxt <= self.lo:
                nxt, self.sweep_dir = self.lo, +1
                self.bounces += 1
        return int(nxt)

    def step(self, frame, dets, exposure_cmd, t):
        self.det_q.append([dict(d, hamming=0) for d in dets])
        stale = self.det_q[0] if len(self.det_q) > self.det_lag else []
        if len(self.det_q) > self.det_lag:
            self.det_q.pop(0)
        had_lost = self.lost
        out = super().step(frame, stale, exposure_cmd, t)
        if self.lost == 0 and had_lost:
            self.home, self.bounces, self.rest_until = None, 0, 0
        return out


def register(REGISTRY):
    REGISTRY["amg_asis"] = lambda: HoldStart()
    REGISTRY["amg_minmax_1hz"] = lambda: MinMax("amg_minmax_1hz")
    REGISTRY["amg_quartile_1hz"] = lambda: Suggested("amg_quartile_1hz", period_frames=30, fallback=False)
    REGISTRY["amg_quartile_10hz"] = lambda: Suggested("amg_quartile_10hz", fallback=False)
    REGISTRY["amg_suggested"] = lambda: Suggested("amg_suggested")
    # the same with the per-tag "keep every tag's white in a band" objective
    from controllers import ContrastProposal

    class SuggestedContrast(Suggested, ContrastProposal):
        pass
    REGISTRY["amg_suggested_contrast"] = lambda: SuggestedContrast("amg_suggested_contrast")
