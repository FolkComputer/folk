"""Render markdown tables from results/summary.csv and splice them into a
report template at <!-- TABLE:name --> markers.

    python3 make_report_tables.py --results results --template REPORT.in.md --out REPORT.md
"""
import argparse
import collections
import csv
import re

import numpy as np

SCENARIO_ORDER = [
    "steady_from_dark", "steady_from_bright", "tags_appear_late", "window_drift", "window_drift_mixed",
    "cloud_steps", "light_jitter", "mixed_illumination", "hand_shadow", "specular",
    "projector_feedback_mild", "projector_feedback", "low_light", "bright_sun",
]
SHORT = {
    "steady_from_dark": "steady, dark start", "steady_from_bright": "steady, bright start",
    "tags_appear_late": "tags appear late", "window_drift": "window drift 16x",
    "window_drift_mixed": "drift + gradient", "cloud_steps": "cloud steps 25x",
    "light_jitter": "LED jitter", "mixed_illumination": "sun/shade split",
    "hand_shadow": "hand shadow", "specular": "specular highlight",
    "projector_feedback_mild": "projector spill 15%", "projector_feedback": "projector spill 45%",
    "low_light": "low light", "bright_sun": "direct sun",
}


def load(path):
    rows = list(csv.DictReader(open(path)))
    by = collections.defaultdict(lambda: collections.defaultdict(list))
    for r in rows:
        by[r["controller"]][r["scenario"]].append(r)
    return by


def mean_metric(by, c, s, m):
    xs = [float(r[m]) for r in by[c][s]] if s in by[c] else []
    return float(np.mean(xs)) if xs else float("nan")


def table(by, controllers, metric, fmt, scenarios=None, lower_better=False, title=None, mean_col=True):
    scenarios = scenarios or [s for s in SCENARIO_ORDER if any(s in by[c] for c in controllers)]
    head = "| scenario | " + " | ".join(controllers) + " |"
    sep = "|---|" + "---:|" * len(controllers)
    lines = [head, sep]
    for s in scenarios:
        vals = [mean_metric(by, c, s, metric) for c in controllers]
        finite = [v for v in vals if not np.isnan(v)]
        best = (min(finite) if lower_better else max(finite)) if finite else None
        cells = []
        for v in vals:
            if np.isnan(v):
                cells.append("–")
            else:
                txt = fmt.format(v)
                cells.append(f"**{txt}**" if best is not None and abs(v - best) < 1e-9 else txt)
        lines.append(f"| {SHORT.get(s, s)} | " + " | ".join(cells) + " |")
    if mean_col:
        means = [np.nanmean([mean_metric(by, c, s, metric) for s in scenarios]) for c in controllers]
        lines.append("| **mean** | " + " | ".join(f"**{fmt.format(m)}**" for m in means) + " |")
    return "\n".join(lines)


def seeds_note(by, controllers):
    n = {c: sorted({r["seed"] for s in by[c] for r in by[c][s]}) for c in controllers}
    return ", ".join(f"{c}: seeds {','.join(v)}" for c, v in n.items())


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--results", default="results")
    ap.add_argument("--template", required=True)
    ap.add_argument("--out", required=True)
    args = ap.parse_args()
    by = load(f"{args.results}/summary.csv")
    main_ctls = ["fixed_4000", "v4l2_auto", "branch_asis", "branch_fast", "prop_tcl", "prop_contrast_tcl"]
    abl_ctls = ["prop_tcl", "prop_white_mean", "prop_white_max", "prop_white_min",
                "prop_white_median_noclip", "prop_white_median_nofallback", "prop_tcl_lo1000",
                "prop_tcl_p10", "branch_fast_t200", "prop_margin"]
    tables = {
        "all_tags": table(by, main_ctls, "all_tags_rate", "{:.0%}"),
        "flicker": table(by, main_ctls, "flicker_per_min", "{:.0f}", lower_better=True),
        "churn": table(by, main_ctls, "exposure_changes_per_min", "{:.0f}", lower_better=True),
        "margin": table(by, main_ctls, "mean_margin", "{:.0f}"),
        "ablation_all_tags": table(by, abl_ctls, "all_tags_rate", "{:.0%}"),
        "ablation_flicker": table(by, abl_ctls, "flicker_per_min", "{:.0f}", lower_better=True),
        "ablation_churn": table(by, abl_ctls, "exposure_changes_per_min", "{:.0f}", lower_better=True),
        "seeds": seeds_note(by, main_ctls),
    }
    tmpl = open(args.template).read()
    def sub(m):
        name = m.group(1)
        return tables.get(name, f"<!-- missing table {name} -->")
    out = re.sub(r"<!-- TABLE:(\w+) -->", sub, tmpl)
    open(args.out, "w").write(out)
    print("wrote", args.out)


if __name__ == "__main__":
    main()
