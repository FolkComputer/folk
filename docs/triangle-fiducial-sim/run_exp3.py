#!/usr/bin/env python3
"""Standalone runner for simulate.py's Exp 3 (temporal) + Exp 4.

The temporal experiment at 40 s x 4 frame rates doesn't fit in one
process budget alongside Exps 1-2, so this reruns it alone, appends to
results-temporal.txt, and regenerates fig3_temporal.png."""
import importlib.util, os, sys
import numpy as np

OUT = os.path.dirname(os.path.abspath(__file__))
spec = importlib.util.spec_from_file_location("sim", f"{OUT}/simulate.py")
sim = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sim)

with open(f"{OUT}/results-temporal.txt", "w", buffering=1) as f:
    class Tee:
        def write(self, s): sys.__stdout__.write(s); f.write(s)
        def flush(self): sys.__stdout__.flush(); f.flush()
    sys.stdout = Tee()
    r3 = sim.exp3()
    sim.exp4()
    sys.stdout = sys.__stdout__

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
fig, ax = plt.subplots(1, 2, figsize=(10.5, 3.6))
for fps, r in r3.items():
    c = np.array(r["curve"])
    ax[0].plot(c[:, 0], np.abs(c[:, 1]), label=f"{fps} fps")
ax[0].set_yscale("log"); ax[0].set_xlabel("time (s)")
ax[0].set_title("|fx error| %, background refinement"); ax[0].grid(alpha=.3)
ax[0].axhline(2, color="gray", ls=":"); ax[0].legend()
fpss = list(r3.keys())
ax[1].plot(fpss, [r3[f]["jitter_raw"] for f in fpss], "o-", label="raw")
ax[1].plot(fpss, [r3[f]["jitter_ema"] for f in fpss], "s-", label="100ms EMA")
ax[1].set_xlabel("fps"); ax[1].set_title("static pose jitter (mm)")
ax[1].grid(alpha=.3); ax[1].legend()
fig.suptitle("Exp 3: temporal resolution — convergence & jitter (1080p)")
fig.tight_layout(); fig.savefig(f"{OUT}/fig3_temporal.png", dpi=110)
print("fig3 written")
