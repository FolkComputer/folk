"""Markdown tables from results-amg/summary.csv (mean over seeds).

    python3 make_amg_table.py [results-amg]
"""
import csv
import os
import sys
from collections import defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
out_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(HERE, "results-amg")
ORDER = ["amg_asis", "v4l2_auto", "branch_asis", "amg_minmax_1hz", "amg_quartile_1hz",
         "amg_quartile_10hz", "amg_suggested", "amg_suggested_contrast"]

rows = list(csv.DictReader(open(os.path.join(out_dir, "summary.csv"))))
acc = defaultdict(lambda: defaultdict(list))
for r in rows:
    for k in ("all_tags_rate", "mean_tag_rate", "flicker_per_min", "exposure_changes_per_min"):
        acc[(r["controller"], r["scenario"])][k].append(float(r[k]))
mean = lambda xs: sum(xs) / len(xs)
ctls = [c for c in ORDER if any(k[0] == c for k in acc)]
scens = sorted({k[1] for k in acc})

print("| controller | all 4 tags seen | avg per-tag | flicker/min | exposure writes/min | scenarios >= 95% |")
print("|---|---|---|---|---|---|")
for c in ctls:
    a = [mean(acc[(c, s)]["all_tags_rate"]) for s in scens]
    m = [mean(acc[(c, s)]["mean_tag_rate"]) for s in scens]
    f = [mean(acc[(c, s)]["flicker_per_min"]) for s in scens]
    e = [mean(acc[(c, s)]["exposure_changes_per_min"]) for s in scens]
    print(f"| {c} | {100*mean(a):.0f}% | {100*mean(m):.0f}% | {mean(f):.0f} | {mean(e):.0f} | "
          f"{sum(x >= 0.95 for x in m)}/{len(scens)} |")
print()
print("Per-tag detection rate (% of frames, averaged over the 4 tags) by scenario:")
print()
print("| scenario | " + " | ".join(ctls) + " |")
print("|---|" + "---|" * len(ctls))
for s in scens:
    print(f"| {s} | " + " | ".join(f"{100*mean(acc[(c, s)]['mean_tag_rate']):.0f}" for c in ctls) + " |")
