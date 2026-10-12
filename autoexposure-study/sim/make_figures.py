"""
Figures for the autoexposure study, from results/*.json.

    python3 make_figures.py --results results --out figures \
        --controllers branch_asis,branch_fast,prop_white_median,prop_contrast

Palette and mark rules follow the dataviz reference palette (light surface).
"""
import argparse
import glob
import json
import os

import numpy as np
import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
from matplotlib.colors import LinearSegmentedColormap

SURFACE = "#fcfcfb"
INK = "#0b0b0b"
INK2 = "#52514e"
MUTED = "#898781"
GRID = "#e1e0d9"
AXIS = "#c3c2b7"
SEQ = ["#cde2fb", "#9ec5f4", "#6da7ec", "#3987e5", "#256abf", "#184f95", "#0d366b"]
CAT = ["#2a78d6", "#eb6834", "#1baf7a", "#eda100", "#e87ba4", "#008300", "#6250d6", "#e34948"]
CRIT = "#d03b3b"

plt.rcParams.update({
    "font.family": "sans-serif",
    "font.sans-serif": ["DejaVu Sans", "Segoe UI", "Helvetica", "Arial"],
    "figure.facecolor": SURFACE, "axes.facecolor": SURFACE, "savefig.facecolor": SURFACE,
    "axes.edgecolor": AXIS, "axes.labelcolor": INK2, "xtick.color": MUTED, "ytick.color": MUTED,
    "axes.spines.top": False, "axes.spines.right": False,
    "axes.grid": True, "grid.color": GRID, "grid.linewidth": 1.0, "grid.linestyle": "-",
    "axes.titlecolor": INK, "axes.titlesize": 11, "axes.labelsize": 9,
    "xtick.labelsize": 8, "ytick.labelsize": 8, "legend.fontsize": 8, "legend.frameon": False,
})


def load(results_dir):
    runs = {}
    for p in glob.glob(os.path.join(results_dir, "*.json")):
        with open(p) as fh:
            r = json.load(fh)
        runs[(r["controller"], r["scenario"], r["seed"])] = r
    return runs


def agg(runs, metric):
    """mean over seeds -> {(controller, scenario): value}"""
    acc = {}
    for (c, s, seed), r in runs.items():
        acc.setdefault((c, s), []).append(r["metrics"][metric])
    return {k: float(np.mean(v)) for k, v in acc.items()}


def heatmap(runs, controllers, scenarios, metric, title, fname, fmt="{:.0%}", vmin=0, vmax=1,
            lower_is_better=False, cap=None):
    vals = agg(runs, metric)
    M = np.full((len(controllers), len(scenarios)), np.nan)
    for i, c in enumerate(controllers):
        for j, s in enumerate(scenarios):
            if (c, s) in vals:
                M[i, j] = vals[(c, s)]
    cmap = LinearSegmentedColormap.from_list("seq", SEQ)
    if lower_is_better:
        cmap = cmap.reversed()
    fig, ax = plt.subplots(figsize=(1.1 * len(scenarios) + 3.2, 0.42 * len(controllers) + 1.6))
    ax.grid(False)
    show = M.copy()
    if cap is not None:
        show = np.minimum(show, cap)
    ax.imshow(show, cmap=cmap, vmin=vmin, vmax=vmax if cap is None else cap, aspect="auto")
    # 2px surface gap between cells
    ax.set_xticks(np.arange(len(scenarios) + 1) - 0.5, minor=True)
    ax.set_yticks(np.arange(len(controllers) + 1) - 0.5, minor=True)
    ax.grid(which="minor", color=SURFACE, linewidth=2)
    ax.tick_params(which="minor", length=0)
    ax.set_xticks(range(len(scenarios)))
    ax.set_xticklabels(scenarios, rotation=35, ha="right")
    ax.set_yticks(range(len(controllers)))
    ax.set_yticklabels(controllers)
    for i in range(len(controllers)):
        for j in range(len(scenarios)):
            v = M[i, j]
            if np.isnan(v):
                continue
            norm = (min(v, cap) if cap else v) / (cap if cap else vmax)
            if lower_is_better:
                norm = 1 - norm
            ax.text(j, i, fmt.format(v), ha="center", va="center", fontsize=7.5,
                    color=SURFACE if norm > 0.55 else INK)
    ax.set_title(title, loc="left")
    for sp in ax.spines.values():
        sp.set_visible(False)
    fig.tight_layout()
    fig.savefig(fname, dpi=160)
    plt.close(fig)


def timeline(runs, pairs, scenario, fname, title, seed=1, max_s=None):
    """Exposure trace + per-tag detection raster for up to 3 controllers on one scenario."""
    rows = [p for p in pairs if (p, scenario, seed) in runs]
    if not rows:
        return
    n = len(rows)
    fig, axes = plt.subplots(n + 1, 1, figsize=(9.5, 1.9 + 1.05 * n), sharex=True,
                             gridspec_kw={"height_ratios": [2.2] + [1.0] * n})
    ax0 = axes[0]
    for k, c in enumerate(rows):
        r = runs[(c, scenario, seed)]
        fps = r["fps"]
        e = np.array(r["timeline"]["exposure_us"], dtype=float)
        t = np.arange(len(e)) / fps
        if max_s:
            m = t <= max_s
            t, e = t[m], e[m]
        ax0.plot(t, e / 1000.0, color=CAT[k], lw=2, solid_joinstyle="round", solid_capstyle="round",
                 label=c)
        ax0.text(t[-1], e[-1] / 1000.0, "  " + c, color=INK2, fontsize=8, va="center")
    ax0.set_ylabel("commanded exposure (ms)")
    ax0.set_yscale("log")
    ax0.set_title(title, loc="left")
    ax0.legend(loc="upper left", ncol=3)
    for k, c in enumerate(rows):
        ax = axes[k + 1]
        r = runs[(c, scenario, seed)]
        fps = r["fps"]
        det = r["timeline"]["detected"]
        tags = sorted(det.keys(), key=int)
        D = np.array([det[tg] for tg in tags], dtype=float)
        if max_s:
            D = D[:, : int(max_s * fps) + 1]
        # raster: detected = series color, lost = critical, not visible = surface
        img = np.zeros(D.shape + (3,))
        col_det = np.array(matplotlib.colors.to_rgb(CAT[k]))
        col_lost = np.array(matplotlib.colors.to_rgb(CRIT))
        col_na = np.array(matplotlib.colors.to_rgb(GRID))
        img[D == 1] = col_det
        img[D == 0] = col_lost
        img[D == -1] = col_na
        ax.imshow(img, aspect="auto", interpolation="nearest",
                  extent=[0, D.shape[1] / fps, len(tags) - 0.5, -0.5])
        ax.set_yticks(range(len(tags)))
        ax.set_yticklabels([f"tag {tg}" for tg in tags])
        ax.grid(False)
        ax.set_ylabel(c, rotation=0, ha="right", va="center", fontsize=8, color=INK2)
        m = r["metrics"]
        ax.text(1.0, 0.5, f" all-tags {m['all_tags_rate']:.0%}\n flicker {m['flicker_per_min']:.0f}/min",
                transform=ax.transAxes, fontsize=7.5, color=INK2, va="center")
    axes[-1].set_xlabel("time (s)")
    fig.text(0.01, 0.005, "raster: series color = detected, red = tag visible but not detected, gray = tag not on table",
             fontsize=7, color=MUTED)
    fig.tight_layout(rect=(0, 0.02, 0.9, 1))
    fig.savefig(fname, dpi=160)
    plt.close(fig)


def barchart(runs, controllers, metric, title, fname, scenarios=None, fmt="{:.0f}", lower_is_better=True):
    vals = agg(runs, metric)
    per = {}
    for c in controllers:
        xs = [v for (cc, s), v in vals.items() if cc == c and (scenarios is None or s in scenarios)]
        per[c] = float(np.mean(xs)) if xs else np.nan
    order = sorted(controllers, key=lambda c: per[c], reverse=not lower_is_better)
    fig, ax = plt.subplots(figsize=(7.5, 0.34 * len(order) + 1.4))
    y = np.arange(len(order))
    v = [per[c] for c in order]
    ax.barh(y, v, height=0.62, color=CAT[0])
    for yi, vi in zip(y, v):
        ax.text(vi, yi, " " + fmt.format(vi), va="center", fontsize=8, color=INK2)
    ax.set_yticks(y)
    ax.set_yticklabels(order)
    ax.invert_yaxis()
    ax.grid(axis="y", visible=False)
    ax.set_title(title, loc="left")
    fig.tight_layout()
    fig.savefig(fname, dpi=160)
    plt.close(fig)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="results")
    ap.add_argument("--out", default="figures")
    ap.add_argument("--controllers", default=None)
    ap.add_argument("--timelines", default=None,
                    help="semicolon-separated 'scenario:ctl1,ctl2,ctl3' groups")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    runs = load(args.results)
    ctls = sorted({k[0] for k in runs}) if not args.controllers else args.controllers.split(",")
    scens = sorted({k[1] for k in runs})
    heatmap(runs, ctls, scens, "all_tags_rate", "Fraction of frames with every visible tag detected",
            os.path.join(args.out, "heatmap_all_tags.png"))
    heatmap(runs, ctls, scens, "flicker_per_min",
            "Detection flicker (detected/lost transitions per minute, summed over tags; lower is better)",
            os.path.join(args.out, "heatmap_flicker.png"), fmt="{:.0f}", lower_is_better=True, cap=300)
    heatmap(runs, ctls, scens, "mean_margin", "Mean AprilTag decision margin of detections (higher is better)",
            os.path.join(args.out, "heatmap_margin.png"), fmt="{:.0f}", vmax=160)
    barchart(runs, ctls, "all_tags_rate", "Mean all-tags detection rate across scenarios",
             os.path.join(args.out, "bar_all_tags.png"), fmt="{:.1%}", lower_is_better=False)
    barchart(runs, ctls, "flicker_per_min", "Mean flicker per minute across scenarios (lower is better)",
             os.path.join(args.out, "bar_flicker.png"))
    barchart(runs, ctls, "exposure_changes_per_min", "Exposure writes per minute (actuator churn)",
             os.path.join(args.out, "bar_churn.png"))
    if args.timelines:
        for grp in args.timelines.split(";"):
            scen, cl = grp.split(":")
            timeline(runs, cl.split(","), scen, os.path.join(args.out, f"timeline_{scen}.png"),
                     f"{scen}: exposure and per-tag detection")
    print("figures ->", args.out)


if __name__ == "__main__":
    main()
