"""
Equivalence test: the pure-Tcl control law (proposal/ae-law.tcl, run under
the vendored jimsh) must produce the same next-exposure as the Python
Proposal controller used in the simulation, over random inputs.
"""
import math
import os
import random
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
SCRATCH = os.path.dirname(HERE)
JIMSH = os.path.join(SCRATCH, "jimtcl-build", "jimsh")
LAW = os.path.join(SCRATCH, "proposal", "ae-law.tcl")


def py_law(cur, stats, lo, hi, target=200.0, deadband=12.0, gain=0.6, max_ratio=1.5,
           clip_frac=0.25, clip_step=0.7):
    """Single-step version of controllers.Proposal (median, persist 1, hold 0)."""
    if not stats:
        return cur
    whites = sorted(s["white"] for s in stats)
    sats = sorted(s["satFrac"] for s in stats)
    mid = len(whites) // 2
    white, sat = whites[mid], sats[mid]
    if sat > clip_frac:
        ratio = clip_step
    else:
        err = target - white
        if abs(err) <= deadband:
            return cur
        white = max(white, 1.0)
        ratio = (target / white) ** (2.2 * gain)
        ratio = min(max_ratio, max(1 / max_ratio, ratio))
    nxt = int(cur * ratio) // 100 * 100
    if nxt == cur:
        nxt = cur + 100 if ratio > 1.0 else cur - 100
    nxt = min(hi, max(lo, nxt))
    return nxt


def py_sweep(cur, d, lo, hi, step=1.6):
    if d > 0:
        nxt = int(cur * step) // 100 * 100
        if nxt >= hi:
            nxt, d = hi, -1
    else:
        nxt = int(cur / step) // 100 * 100
        if nxt <= lo:
            nxt, d = lo, 1
    return nxt, d


def main():
    rng = random.Random(7)
    cases = []
    for _ in range(400):
        cur = rng.choice([300, 500, 1000, 1500, 3000, 4000, 7900, 12000, 15999, 16000])
        n = rng.choice([0, 1, 1, 2, 3, 4, 5])
        stats = []
        for _ in range(n):
            w = rng.choice([30, 90, 150, 185, 195, 200, 205, 215, 240, 252, 255])
            w += rng.uniform(-3, 3)
            stats.append({"white": round(max(0.0, min(255.0, w)), 3),
                          "black": round(rng.uniform(10, 120), 3),
                          "satFrac": round(rng.choice([0.0, 0.0, 0.1, 0.3, 0.6, 1.0]), 3)})
        cases.append((cur, stats))
    lo, hi = 300, 16000
    script = ["source " + LAW]
    for cur, stats in cases:
        st = " ".join("{white %s black %s satFrac %s}" % (s["white"], s["black"], s["satFrac"]) for s in stats)
        script.append(f"puts [aeNextExposure {cur} [list {st}] {lo} {hi}]")
    sweeps = [(rng.choice([300, 480, 1000, 4000, 9999, 10000, 16000]), rng.choice([1, -1])) for _ in range(60)]
    for cur, d in sweeps:
        script.append(f"puts [aeSweepExposure {cur} {d} {lo} {hi}]")
    out = subprocess.run([JIMSH], input="\n".join(script) + "\n", capture_output=True, text=True)
    if out.returncode != 0:
        print("jimsh failed:", out.stderr)
        sys.exit(1)
    lines = out.stdout.strip().split("\n")
    assert len(lines) == len(cases) + len(sweeps), (len(lines), len(cases), len(sweeps))
    bad = 0
    for (cur, stats), line in zip(cases, lines[:len(cases)]):
        exp = py_law(cur, stats, lo, hi)
        got = int(line)
        if exp != got:
            bad += 1
            if bad <= 10:
                print("MISMATCH", cur, stats, "py", exp, "tcl", got)
    for (cur, d), line in zip(sweeps, lines[len(cases):]):
        exp = py_sweep(cur, d, lo, hi)
        got = tuple(int(x) for x in line.split())
        if exp != got:
            bad += 1
            if bad <= 10:
                print("SWEEP MISMATCH", cur, d, "py", exp, "tcl", got)
    print(f"{len(cases)} law cases + {len(sweeps)} sweep cases, {bad} mismatches")
    sys.exit(1 if bad else 0)


if __name__ == "__main__":
    main()
