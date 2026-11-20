"""Gallery of scenarios (one frame each at a fixed 4000us exposure) and a
plot of the control laws' step ratio vs measured white."""
import math
import os
import sys

import numpy as np
import cv2
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import atsim

SURFACE, INK, INK2, MUTED, GRID = "#fcfcfb", "#0b0b0b", "#52514e", "#898781", "#e1e0d9"
CAT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100"]
plt.rcParams.update({
    "font.family": "sans-serif", "figure.facecolor": SURFACE, "axes.facecolor": SURFACE,
    "savefig.facecolor": SURFACE, "axes.edgecolor": "#c3c2b7", "axes.labelcolor": INK2,
    "xtick.color": MUTED, "ytick.color": MUTED, "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 1.0, "axes.titlecolor": INK,
    "axes.titlesize": 10, "axes.labelsize": 9, "xtick.labelsize": 8, "ytick.labelsize": 8,
    "legend.fontsize": 8, "legend.frameon": False,
})


def gallery(out):
    atl = atsim.AprilTagLib()
    scene = atsim.Scene(atl, 640, 480, atsim.default_placements(), seed=0)
    cam = atsim.Camera()
    rng = np.random.default_rng(3)
    names = ["steady_from_dark", "window_drift", "cloud_steps", "mixed_illumination",
             "projector_feedback", "projector_feedback_mild", "hand_shadow", "specular",
             "low_light", "bright_sun", "light_jitter", "window_drift_mixed"]
    # time at which to sample each scenario, and which exposure
    when = {"window_drift": 7.5, "cloud_steps": 12.0, "hand_shadow": 2.2, "window_drift_mixed": 6.0,
            "projector_feedback": 1.0, "projector_feedback_mild": 1.0, "light_jitter": 5.0}
    fig, axes = plt.subplots(3, 4, figsize=(13, 7.6))
    for ax, name in zip(axes.ravel(), names):
        scen = atsim.SCENARIOS[name](scene)
        t = when.get(name, 1.0)
        rad = scen.radiance(t, {1} if scen.projector_feedback else set(), rng)
        frame = cam.capture(rad, 4000, rng)
        dets = atl.detect(frame)
        vis = cv2.cvtColor(frame, cv2.COLOR_GRAY2RGB)
        for d in dets:
            pts = np.int32(d["p"]).reshape(-1, 1, 2)
            cv2.polylines(vis, [pts], True, (27, 175, 122), 2)
        ax.imshow(vis)
        ax.set_title(f"{name}  ({len(dets)}/4 tags at 4 ms, t={t:.0f}s)", loc="left", fontsize=9)
        ax.set_xticks([]); ax.set_yticks([]); ax.grid(False)
        for sp in ax.spines.values():
            sp.set_visible(False)
    fig.suptitle("What the camera sees in each scenario at a fixed 4000 us exposure (green = detected)",
                 x=0.01, ha="left", fontsize=11, color=INK)
    fig.tight_layout(rect=(0, 0, 1, 0.97))
    fig.savefig(os.path.join(out, "scenario_gallery.png"), dpi=130)
    plt.close(fig)


def law_plot(out):
    w = np.linspace(40, 255, 400)
    # branch tip: next = 0.8 cur + 0.2 cur*250/w  (one step; cadence 5s)
    branch = 0.8 + 0.2 * 250.0 / np.maximum(w, 1)
    # proposal: ratio = (200/w)^(2.2*0.6) clipped to [1/1.5, 1.5]; deadband 188..212 -> 1;
    # clipped whites (sat > 25%) -> 0.7  (approximate: w >= 250)
    prop = np.clip((200.0 / w) ** (2.2 * 0.6), 1 / 1.5, 1.5)
    prop[np.abs(200 - w) <= 12] = 1.0
    prop[w >= 250] = 0.7
    fig, ax = plt.subplots(figsize=(7.5, 4))
    ax.axhline(1.0, color="#c3c2b7", lw=1)
    ax.plot(w, branch, color=CAT[1], lw=2, label="branch tip (target 250, EMA 0.8/0.2)")
    ax.plot(w, prop, color=CAT[0], lw=2, label="proposal (target 200, log-domain, clip-aware)")
    ax.axvspan(250, 255, color=GRID, alpha=0.6, lw=0)
    ax.text(252.5, 1.45, "clipped", rotation=90, fontsize=8, color=INK2, ha="center", va="top")
    ax.set_xlabel("measured tag white (0-255)")
    ax.set_ylabel("exposure multiplier per control step")
    ax.set_title("One control step as a function of the measured white", loc="left")
    ax.legend(loc="upper right")
    ax.text(255, branch[-1], f"  x{branch[-1]:.3f} when clipped", fontsize=8, color=INK2, va="center")
    ax.set_xlim(40, 275)
    fig.tight_layout()
    fig.savefig(os.path.join(out, "control_law_shape.png"), dpi=160)
    plt.close(fig)


if __name__ == "__main__":
    out = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "figures")
    os.makedirs(out, exist_ok=True)
    gallery(out)
    law_plot(out)
    print("ok", out)
