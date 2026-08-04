# TriTag measurements: resolution, temporal refinement, and calibration vs. guessing

_Companion to [triangle-fiducials.md](triangle-fiducials.md). All
numbers from the Monte-Carlo harness in
[`triangle-fiducial-sim/simulate.py`](triangle-fiducial-sim/simulate.py)
(`python3 simulate.py` regenerates `results.txt` and the figures)._

**Simulated rig.** Table plane with the camera 1.15 m above it, pitched
28°. Ground-truth camera: 70.4° HFOV (C920-class), off-center principal
point, radial + tangential distortion. The "current fallback" model is
copied verbatim from `builtin-programs/calibrate/load-calibration.folk`:
`fx = fy = width`, principal point at the image center, zero distortion,
identity extrinsics — i.e. a **+41% focal-length error** plus ignored
distortion. Markers: 64 mm-tall TriTags (3 corners + keystone = 4
correspondence points each); "pages" carry **two TriTags 180 mm apart at
a known printed layout** (folk pages already carry several AprilTags
each today, so this is the status quo, not a new requirement). Corner
noise: σ = 0.15 px at 1080p, scaled by √(w/1920) — same optics, so blur
spans more pixels at higher resolution and per-pixel noise grows while
relative precision still improves.

## Exp 1 — single-frame 6DOF pose vs. optical resolution

One 64 mm TriTag at ~1.2 m, known-true intrinsics, 300 trials
(fig1_pose_vs_resolution.png):

| resolution | span (px) | lateral RMSE | depth RMSE | rotation RMSE | bearing RMSE |
|---|---|---|---|---|---|
| 720p  | 58  | 1.90 mm | 4.15 mm | 0.82° | 0.26° |
| 1080p | 87  | 1.62 mm | 3.55 mm | 0.68° | 0.22° |
| 1440p | 115 | 1.31 mm | 2.85 mm | 0.58° | 0.19° |
| 4K    | 173 | 1.01 mm | 2.22 mm | 0.48° | 0.15° |

- Resolution buys roughly √-scaling under the blur-limited noise model:
  720p→4K halves every error. Depth is always the weak axis (~2× the
  lateral error) — it leans on foreshortening rather than image position.
- The equal-footprint **square tag tracks slightly worse laterally and
  in depth** (e.g. 4K: 1.38/3.02 mm vs 1.01/2.22 mm): the triangle+
  keystone spreads its constraints better for the same printed area,
  while bearing is a wash. The marker-shape choice is not the bottleneck
  either way — the *calibration model* is (Exp 2).
- Bearing (the SLAM-relevant orientation signal) is already 0.26° at
  720p on a 58 px marker: orientation-from-silhouette survives low
  resolution far better than the payload does.

## Exp 2 — the current guess vs. TriTag background self-calibration

Protocol: **3 taped reference TriTags** (known mm scale, positions
unknown) plus J snapshots of one ordinary dual-tag page being handled
above the table at natural tilts (18–38°). A staged solve (Zhang
closed-form seed from the page homographies → joint bundle over
intrinsics + per-view poses, distortion frozen then freed) with
robustness gates; medians of 4 runs (fig2_registration.png).

Metrics: *table registration* = where the model believes camera pixels
land on the table (mm RMS over the table); *lifted* = same for content
10 cm above the table (a raised page); *depth* = absolute range error
to a held marker.

| model (1080p) | fx error | table reg. | lifted +10 cm | held depth |
|---|---|---|---|---|
| fallback guess (today's uncalibrated path) | +41.1% | 123 mm | 123 mm | **483 mm** |
| 3 refs only (J=0) | *refused: single plane* | — | — | — |
| refs + 2 page views | *refused: too few tilted views* | — | — | — |
| refs + 5 page views | +0.85% | 37 mm | 34 mm | 15 mm |
| refs + 20 page views | +0.15% | 20 mm | 19 mm | 8 mm |
| refs + 20 views @ 4K | −0.76% | 12 mm | 12 mm | 9 mm |

- Against the fallback, tag-based calibration is a **~10× registration
  improvement and a ~50× absolute-depth improvement**, and it converges
  from ~20 casual page views — about a minute of someone moving a page
  around, no calibration board, no dedicated session.
- The refusals are load-bearing results, not failures. **Static coplanar
  markers alone cannot fix the focal length** (single-plane IAC
  degeneracy): the taped refs pin metric scale, the table frame, and
  drift anchoring, while *tilted* views of moving pages supply the Zhang
  constraints. Folk's tables are full of moving pages, so the data is
  free; the refiner just has to wait for it.
- Also measured (1080p row "degenerate"): views carrying a **single
  minimal 4-point tag cannot drive the refinement** — each view's
  homography fits exactly, only 2 IAC constraints survive per view, and
  the bundle reaches near-zero residual at wrong intrinsics (early
  harness revisions "converged" to fx +20–36% this way). Two tags per
  page at a known printed spacing (16 points/view, 10 redundant
  constraints) makes the problem well-posed. This sets a hard design
  requirement: **print pages with ≥2 TriTags at known layout.**
- An unguarded background refiner occasionally installs a garbage model
  and destroys live tracking (observed: meter-scale registration after a
  bad update). The gates that fixed it are cheap and should be in any
  implementation: refuse on <3 tilted multi-tag views or <12° normal
  spread, refuse implausible intrinsics or bundle RMS > 1 px, and
  install updates damped.

## Exp 3 — temporal resolution: background refinement under motion

A dual-tag page follows a handheld trajectory (±12 cm sinusoids, ±22°
tilt wobble, like the moving simulated display in Lee/Hudson/Dietz
TR2007-109 Fig. 1) while the refiner banks tilted views and re-solves
every ~3 s, starting from the fallback guess; damped (50%) installs
(fig3_temporal.png; final numbers in `results.txt`):

- **Convergence is view-diversity-limited, not fps-limited.** All frame
  rates converge in a few tens of seconds of casual motion; higher fps
  reaches the banked-view quota sooner but 15 fps is entirely usable for
  the *background* loop. Moving-page absolute depth error falls from
  ~430 mm (guess) to tens of mm as the model converges, while the
  tracker keeps running in real time throughout — refinement never
  blocks the frame loop (bundles are ~0.5–2 s of off-thread work every
  few seconds).
- **Jitter is where temporal resolution pays.** Raw static pose jitter
  (~3–4 mm frame-to-frame for a lone 64 mm tag at 1080p) is per-frame-
  noise-limited and roughly fps-independent, but a fixed 100 ms EMA
  window averages more frames at higher fps: ~1.4 mm at 15 fps → ~0.9 mm
  at 30 → ~0.4 mm at 60 → ~0.2 mm at 120, at constant latency. High fps
  buys smoothness for *tracking*; it buys little for *calibration*.

## Exp 4 — low-band visible/IR structured light (the MERL connection)

TR2007-109 hides Gray-code pixel-address patterns in IR so tracking
never disturbs visible content; folk's projector is visible-light only,
but the same budget arithmetic applies to low-contrast (few-%
luminance) patterns interleaved sparsely — or duty-cycled IR if folk
ever grows an IR channel:

| projector | rate | interleave | patterns | full sweep |
|---|---|---|---|---|
| 1080p | 60 Hz | every frame | 24 | 0.4 s |
| 1080p | 60 Hz | 1 in 8 | 24 | 3.2 s |
| 1080p | 30 Hz | 1 in 30 | 24 | 24 s |
| 4K | 120 Hz | 1 in 8 | 26 | 1.7 s |

A full Gray sweep resolves *every* camera-visible projector pixel, i.e.
a dense camera↔projector correspondence map — the projector-side
equivalent of Exp 2's camera solve (a projector is an inverse camera;
the same bundle applies). Steady-state upkeep is far cheaper than full
sweeps: reprojecting a handful of low-contrast dots near the three taped
markers a few times per second is enough to servo the extrinsics
against drift and bumps.

## Bottom line

1. **Calibration with these tags beats guessing by an order of
   magnitude everywhere it matters, and by ~50× where it matters most.**
   The fallback's +41% focal error is invisible for flat projection
   (both in-span table mappings interpolate it away) but fatal for
   anything 6DOF: half-meter depth errors, 12 cm misregistration on
   lifted surfaces. Tag-based background calibration gets absolute
   depth to ~10–20 mm and registration to 12–37 mm depending on
   resolution — resolution helps (≈√), but *view diversity* is the real
   currency.
2. **Yes — 2–3 taped known-scale TriTags + slow background refinement
   is sufficient for realtime, stable, metric 6DOF of moving surfaces**,
   with three provisos the measurements make sharp: (a) the taped
   markers alone are degenerate — the moving pages themselves must feed
   the refiner (they do, for free, within a minute of normal use);
   (b) pages need ≥2 tags at known printed spacing, or the refinement
   is underdetermined no matter how many views arrive; (c) the refiner
   must gate and damp its updates or it will eventually poison live
   tracking. The realtime loop (30–120 Hz pose servoing) and the slow
   loop (~0.3 Hz gated bundle) compose cleanly, exactly in the spirit
   of TR2007-109's split between invisible location discovery and
   visible content — with low-band projected structured light as the
   natural third loop for the projector side of the model.
