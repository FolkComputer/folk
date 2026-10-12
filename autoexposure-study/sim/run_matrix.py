"""
Run controllers x scenarios x seeds in parallel and write results.

    python3 run_matrix.py --controllers a,b,c --scenarios all --seeds 1 --out results/

Each run writes results/<controller>__<scenario>__s<seed>.json (skipped if it
already exists, so the matrix is resumable) and summary.csv is regenerated.
"""
import argparse
import csv
import glob
import json
import os
import sys
import time
from multiprocessing import Pool

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)


def one(job):
    ctl_name, scen, seed, out_dir, fps, latency = job
    path = os.path.join(out_dir, f"{ctl_name}__{scen}__s{seed}.json")
    if os.path.exists(path):
        return path, "cached"
    import atsim
    import controllers
    ctl = controllers.make(ctl_name)
    t0 = time.time()
    res = atsim.run(ctl, scen, seed=seed, fps=fps, latency_frames=latency)
    res["wall_s"] = time.time() - t0
    tmp = path + ".tmp"
    with open(tmp, "w") as fh:
        json.dump(res, fh)
    os.replace(tmp, path)
    return path, f"{res['wall_s']:.0f}s"


METRIC_COLS = ["all_tags_rate", "mean_tag_rate", "flicker_per_min", "exposure_changes_per_min",
               "exposure_tail_std_log", "mean_margin", "min_margin_p10", "frac_over_16ms",
               "exposure_final_us"]


def summarize(out_dir):
    rows = []
    for p in sorted(glob.glob(os.path.join(out_dir, "*.json"))):
        with open(p) as fh:
            r = json.load(fh)
        m = r["metrics"]
        conv = m.get("converge_s", [])
        row = {
            "controller": r["controller"], "scenario": r["scenario"], "seed": r["seed"],
            "converge0_s": conv[0] if conv else None,
            "converge_worst_s": max([c if c is not None else 999 for c in conv]) if conv else None,
        }
        for k in METRIC_COLS:
            row[k] = m.get(k)
        rows.append(row)
    cols = ["controller", "scenario", "seed", "converge0_s", "converge_worst_s"] + METRIC_COLS
    with open(os.path.join(out_dir, "summary.csv"), "w", newline="") as fh:
        w = csv.DictWriter(fh, fieldnames=cols)
        w.writeheader()
        for row in rows:
            w.writerow(row)
    return rows


def main():
    import atsim
    import controllers
    ap = argparse.ArgumentParser()
    ap.add_argument("--controllers", default="all")
    ap.add_argument("--scenarios", default="all")
    ap.add_argument("--seeds", default="1")
    ap.add_argument("--out", default=os.path.join(HERE, "results"))
    ap.add_argument("--procs", type=int, default=4)
    ap.add_argument("--fps", type=int, default=30)
    ap.add_argument("--latency", type=int, default=2)
    ap.add_argument("--summary-only", action="store_true")
    args = ap.parse_args()
    os.makedirs(args.out, exist_ok=True)
    if args.summary_only:
        rows = summarize(args.out)
        print(f"{len(rows)} rows -> {args.out}/summary.csv")
        return
    ctls = sorted(controllers.REGISTRY) if args.controllers == "all" else args.controllers.split(",")
    scens = sorted(atsim.SCENARIOS) if args.scenarios == "all" else args.scenarios.split(",")
    seeds = [int(s) for s in args.seeds.split(",")]
    jobs = [(c, s, sd, args.out, args.fps, args.latency) for c in ctls for s in scens for sd in seeds]
    # longest scenarios first for better packing
    dur = {name: cls.duration_s for name, cls in atsim.SCENARIOS.items()}
    jobs.sort(key=lambda j: -dur[j[1]])
    print(f"{len(jobs)} jobs on {args.procs} procs", flush=True)
    t0 = time.time()
    done = 0
    with Pool(args.procs) as pool:
        for path, status in pool.imap_unordered(one, jobs):
            done += 1
            print(f"[{done}/{len(jobs)} {time.time()-t0:.0f}s] {os.path.basename(path)} {status}", flush=True)
    rows = summarize(args.out)
    print(f"done: {len(rows)} rows -> {args.out}/summary.csv")


if __name__ == "__main__":
    main()
