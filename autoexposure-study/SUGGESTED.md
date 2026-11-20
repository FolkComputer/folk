# Suggested commits for `amg/autoexposure`

This branch (`ac/busy-albattani-puhmth`) is `amg/autoexposure` merged with
current `main`, plus seven small commits that turn the branch's measurement
loop into a working tag-based autoexposure, plus a simulator that tests it
under difficult lighting.

The seven commits touch only `builtin-programs/camera/autoexposure.folk`,
`builtin-programs/web/camera.folk` and a new `test/autoexposure.folk`. They
cherry-pick cleanly onto `amg/autoexposure` as it is today (`3fece215`):

    git checkout amg/autoexposure
    git cherry-pick e8be0be5 7730dce8 125920da 895e2a84 181bef1e 20f3c3ad 7d70d7ab

Do not cherry-pick `8dff7dc3` or later: those add `autoexposure-study/`
(the simulator and this document), which is not meant for `main`.

## What was and was not tested

- **Real Folk, fake camera:** `./folk test/autoexposure.folk` passes. It
  feeds the program gray frames whose brightness follows the wished
  exposure, and fake tag detections.
- **Simulation:** the control behaviour was run through 14 lighting
  scenarios, 2 seeds each, with the real AprilTag detector (results below).
- **Tcl vs. simulation:** the Tcl control law in the `.folk` file gives the
  same answers as the Python model used in the simulation, on 460 random
  cases (`sim/test_tcl_equiv.py`).
- **Not tested:** a real camera, the web page in a browser (its JavaScript
  was only syntax-checked), and virtual (cropped) cameras. The four
  intermediate commits before "Close the loop" were not run individually.

## The commits, in order

### 1. `e8be0be5` web/camera: Fix JS comment that broke the camera page

```js
-      # either disable hold when autoexposure, or match keys
+      // either disable hold when autoexposure, or match keys
```

The note added in `34ab1f39` is inside the page's `<script>`. `#` is a Tcl
comment, not a JavaScript one, so the whole script fails to parse and the
`/camera` page loses its preview and its exposure and gain controls. Commit 5
removes the note altogether; this commit is here so the page works even if
you stop after it.

### 2. `7730dce8` Measure inside the tag, bounds-checked, by quartile

Rewrites the C function `getTagLocalContrast`. It keeps its name and still
returns a struct, but the fields change from `{darkest brightest}` to
`{count white black satFrac}`.

```c
const int samples = 64;
for (int sy = 0; sy < samples; sy++) {
    double v = (sy + 0.5) / samples;
    for (int sx = 0; sx < samples; sx++) {
        double u = (sx + 0.5) / samples;
        double topX = corners[0][0] + u * (corners[1][0] - corners[0][0]);
        ...
        int x = (int)(topX + v * (botX - topX) + 0.5);
        int y = (int)(topY + v * (botY - topY) + 0.5);
```

- **Sampling grid:** this walks a 64×64 grid in the tag's own coordinates
  (interpolating between the four corners), so every sample is inside the
  tag even when it is rotated. The old loop walked the bounding box, which
  for a rotated tag is up to half paper and table.

```c
        if (x < 0 || y < 0 ||
            x >= (int)grayFrame.width || y >= (int)grayFrame.height) {
            continue;
        }
        histogram[grayFrame.data[y * grayFrame.bytesPerRow + x]]++;
```

- **Bounds check:** the old loop indexed `grayFrame.data` with whatever the
  corners said. A tag hanging off the edge of the frame gives negative or
  too-large coordinates, which reads memory outside the image. Samples off
  the frame are now skipped.
- **Histogram:** counting how many samples have each brightness (0–255)
  makes the next step cheap.

```c
uint32_t quarter = n / 4;
for (int i = 255; i >= 0 && whiteCount < quarter; i--) { ... whiteSum += i * take; ... }
for (int i = 0; i < 256 && blackCount < quarter; i++) { ... blackSum += i * take; ... }
ret.white   = (double)whiteSum / whiteCount;
ret.black   = (double)blackSum / blackCount;
ret.satFrac = (double)clippedCount / whiteCount;
```

- **`white` / `black`:** the mean of the brightest quarter and of the
  darkest quarter of the samples, instead of the single brightest and
  darkest pixel. One noisy pixel or one glint no longer decides the result.
- **`satFrac`:** the fraction of the bright quarter that is at 250 or above.
  When the whites are clipped, `white` reads about 255 however overexposed
  the camera is, so the control law needs to know that separately.
- **`count`:** how many samples landed on the frame; 0 means "ignore this
  tag".

The rest of the file (the once-a-second loop that prints the stats) is
unchanged in this commit.

### 3. `125920da` Add the control law (`aeNextExposure`, `aeSweepExposure`)

Two functions, defined with `fn` so that the nested `When` in commit 4 can
call them. They are plain Tcl and are not called yet.

```tcl
fn aeNextExposure {cur stats lo hi} {
    set target 200.0
    set deadband 12.0
    set gain 0.6
    set maxRatio 1.5
    set clipFrac 0.25
    set clipStep 0.7
```

- **`target 200`:** where we want the tags' white cells, out of 255. It
  leaves headroom below clipping.
- **`deadband 12`:** between 188 and 212 we do nothing, so noise does not
  cause constant small exposure changes.
- **`gain 0.6`, `maxRatio 1.5`:** each step goes 60% of the way to the
  estimated ideal (in the log domain) and never changes exposure by more
  than ×1.5 or ÷1.5. A USB camera takes 1–3 frames to apply a new exposure,
  and a full-size step would overshoot.
- **`clipFrac`, `clipStep`:** if more than 25% of the white samples are
  clipped, multiply exposure by 0.7 without trying to compute how far off
  we are.

```tcl
    set whites [lsort -real [lmap s $stats {dict get $s white}]]
    set sats [lsort -real [lmap s $stats {dict get $s satFrac}]]
    set mid [expr {[llength $whites] / 2}]
    set white [lindex $whites $mid]
```

- **Median across tags:** one tag under projector spill, a glint or a hand
  shadow does not move the exposure for all the others.

```tcl
        set ratio [expr {pow($target / $white, 2.2 * $gain)}]
```

- **The `2.2`:** cameras apply a tone curve, so pixel value goes roughly as
  exposure^(1/2.2). To change a pixel value by some ratio, exposure has to
  change by that ratio to the power 2.2.

```tcl
    set next [expr {int($cur * $ratio) / 100 * 100}]
    if {$next == $cur} {
        set next [expr {$ratio > 1.0 ? $cur + 100 : $cur - 100}]
    }
```

- **100 µs grid:** V4L2 exposure is set in units of 100 µs. Without the
  second line, a small correction at a short exposure rounds back to the
  same value and the loop stalls.

`aeSweepExposure {cur dir lo hi}` multiplies or divides the exposure by 1.6
and reverses direction at either end of the range. It is used when no tag is
visible.

### 4. `895e2a84` Close the loop

Replaces the `while true { sleep 1 ... }` loop with the control loop. It
only runs when someone asks for it:

```tcl
When /someone/ wishes camera /camera/ uses AprilTag-based autoexposure {
    set exposureCamera [lindex $camera 0]
    set lo 300
    set hi 15000
```

- **Opt-in wish:** nothing changes for anyone who has not made this wish.
- **`exposureCamera`:** for a virtual (cropped) camera `{/dev/video0 1}`,
  tags are detected on the crop but exposure belongs to `/dev/video0`.
- **`lo` / `hi`:** 300 µs is about as short as UVC cameras go; 15 ms is the
  longest that fits in a frame at the 60 fps Folk requests.

```tcl
    When -serially camera $camera has gray frame /grayFrame/ at timestamp /frameTs/ {
        set state {lastRunTs 0 lostSince {} lastSweepTs 0 sweepDir 1 ...}
        foreach r [Query! camera $camera has autoexposure state /state/] {
            set state [dict get $r state]
        }
        if {$frameTs - [dict get $state lastRunTs] < 0.1} { return }
```

- **`When` on each gray frame:** the same pattern `apriltags.folk` uses. The
  frame is the one this `When` matched, so it stays valid while the body
  runs. The old loop looked up "the gray frame at the detection's
  timestamp", which has usually been replaced by a newer frame by then.
- **State in a held claim:** a `When` body starts from a fresh copy of its
  variables each time, so anything that must survive between frames is kept
  in one held statement.
- **Rate limit by returning early:** it acts at most about 10 times a
  second, so the camera has applied the last change before we measure
  again. It returns instead of sleeping, so it does not tie up a worker.

```tcl
        if {[llength [Query! /someone/ wishes camera $exposureCamera \
                          temporarily uses exposure time /us/ us]] > 0} { return }
```

- **Calibration:** `calibrate` takes over the exposure with a "temporarily
  uses" wish. Autoexposure stands down while one exists.

```tcl
        foreach r [Query! /someone/ wishes camera $exposureCamera uses exposure time /us/ us] {
            set cur [dict get $r us]
        }
        if {$cur < $lo || $cur > $hi} { ...seed 3000 (or $hi), hold it, return }
```

- **Current exposure:** read from the same wish the manual slider holds.
- **Seeding:** if nobody has wished an exposure, or it is 0 (the camera's
  built-in auto mode), start from 3000 µs.

```tcl
        foreach r [Query! /detector/ detects tags /tags/ on camera $camera \
                       at timestamp /detTs/ in time /detTime/] {
            if {$frameTs - [dict get $r detTs] > 0.5} { continue }
            foreach tag [dict get $r tags] {
                dict set corners [dict get $tag id] [dict get $tag p]
            }
        }
```

- **Corners:** the latest corners of every tag, from both the entire-frame
  and the incremental detector. They can be a frame or two older than the
  frame being measured; tags move slowly compared to that, and the C
  function is bounds-checked.

```tcl
        if {[llength $stats] > 0} {
            set next [aeNextExposure $cur $stats $lo $hi]
        } elseif {...no tag for 0.5s, not resting, 0.4s since last sweep step...} {
            ...sweep, or after touching both ends: go home and rest 5s
        }
```

- **Normal case:** ask the control law.
- **No tags:** after half a second, sweep the range one step every 0.4 s.
  Once it has been to both ends without finding a tag, the table is
  probably empty, so it returns to where it started and rests for 5 s. This
  keeps the picture from pulsing forever for other programs that use the
  camera.

```tcl
        if {$next != $cur} {
            Hold! -on builtin-programs/web/setup.folk -key "exposure $exposureCamera" \
                Wish camera $exposureCamera uses exposure time $next us
        }
```

- **Same `-on` and `-key` as the slider:** this is the "match keys" option
  from the note in `web/camera.folk`. There is only ever one exposure wish,
  and when autoexposure is switched off the camera stays where it was left.
- **No `-save`:** saving would rewrite the hold file about 10 times a
  second.

### 5. `181bef1e` web/camera: Checkbox for tag-based autoexposure

- **New checkbox** "Auto-exposure from tags". It holds
  `Wish camera <camera> uses AprilTag-based autoexposure` (saved, so it
  survives a restart). The existing checkbox is relabelled "Camera's
  built-in auto-exposure".
- **Manual controls greyed out while it is on**, and `updateExposure` no
  longer sends a value in that state. This is the "disable hold when
  autoexposure" half of the note: the slider and the program never both
  write the wish.
- **Known gap:** when you untick it, the number box still shows the value
  from page load, not the exposure the tags chose, until you reload.

### 6. `20f3c3ad` test: Closed-loop autoexposure test with a fake camera

`./folk test/autoexposure.folk`. Output of a passing run (it is written to
`/var/tmp/folk-<pid>/test__autoexposure.folk.stdout`):

    1. normal light:  white=196 exposure=3000us
    2. bright light:  white=202 exposure=400us
    3. dim light:     white=192 exposure=9600us
    4. temp exposure: exposure stayed 9600us
    5. no tags:       swept through 300 500 800 1300 2200 3600 5800 9300 9600 15000
       resting at 9600us (home was 9600us)
    6. switched off:  exposure stayed 9600us

One of the two fake tags hangs off the frame, to exercise the bounds check.

### 7. `7d70d7ab` Start the no-tag sweep in the likelier direction

Adds `getFrameBrightness` (mean of every 8th pixel of the frame). When the
tags are first lost, a mostly bright frame means "probably overexposed", so
the sweep goes shorter first; otherwise longer first. In simulated direct
sun this finds the tags about 2 s sooner.

## Simulation results

Each column is one controller, each run is 15–60 s of simulated camera at
30 fps with four tags on a table, scored by how often the real AprilTag
detector finds them. Numbers are means over two seeds.

- `amg_asis`: the branch today. It measures but never sets exposure.
- `v4l2_auto`: a model of the camera's built-in autoexposure.
- `branch_asis`: `osnr/apriltag-autoexposure` as it stands.
- `amg_minmax_1hz`: the shortest path from the branch's TODOs to a loop: its
  own brightest-pixel statistic driven to 200 once a second.
- `amg_quartile_1hz`: with commit 2's statistic.
- `amg_quartile_10hz`: at ~10 Hz instead of `sleep 1`.
- `amg_suggested`: all seven commits.
- `amg_suggested_contrast`: the same, with a "keep every tag's white in a
  band" objective instead of the median.

| controller | all 4 tags seen | avg per-tag | flicker/min | exposure writes/min | scenarios >= 95% |
|---|---|---|---|---|---|
| amg_asis | 63% | 82% | 457 | 0 | 7/14 |
| v4l2_auto | 90% | 97% | 182 | 136 | 12/14 |
| branch_asis | 81% | 88% | 157 | 6 | 9/14 |
| amg_minmax_1hz | 85% | 89% | 166 | 19 | 11/14 |
| amg_quartile_1hz | 85% | 89% | 168 | 17 | 11/14 |
| amg_quartile_10hz | 87% | 91% | 152 | 47 | 12/14 |
| amg_suggested | 94% | 98% | 152 | 51 | 12/14 |
| amg_suggested_contrast | 92% | 97% | 170 | 102 | 12/14 |

Per-tag detection rate (% of frames, averaged over the 4 tags) by scenario:

| scenario | amg_asis | v4l2_auto | branch_asis | amg_minmax_1hz | amg_quartile_1hz | amg_quartile_10hz | amg_suggested | amg_suggested_contrast |
|---|---|---|---|---|---|---|---|---|
| bright_sun | 0 | 98 | 0 | 0 | 0 | 0 | 94 | 94 |
| cloud_steps | 83 | 99 | 83 | 78 | 79 | 97 | 98 | 98 |
| hand_shadow | 100 | 97 | 100 | 100 | 100 | 100 | 100 | 100 |
| light_jitter | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| low_light | 80 | 100 | 100 | 99 | 99 | 100 | 100 | 100 |
| mixed_illumination | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| projector_feedback | 75 | 74 | 74 | 74 | 74 | 74 | 74 | 74 |
| projector_feedback_mild | 100 | 87 | 100 | 100 | 100 | 100 | 100 | 95 |
| specular | 100 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| steady_from_bright | 67 | 100 | 100 | 98 | 98 | 100 | 100 | 100 |
| steady_from_dark | 98 | 100 | 100 | 100 | 100 | 100 | 100 | 100 |
| tags_appear_late | 67 | 100 | 100 | 98 | 98 | 100 | 100 | 100 |
| window_drift | 98 | 100 | 93 | 100 | 100 | 100 | 100 | 100 |
| window_drift_mixed | 86 | 100 | 83 | 100 | 100 | 100 | 100 | 100 |

What the numbers say:

- **The suggested code works:** per-tag detection goes from 82% (exposure
  left alone) to 98%, and flicker drops to a third.
- **The sweep is the biggest single step.** Without it, direct sun is 0%:
  the tags are never seen, so there is nothing to measure.
- **Cadence is the second.** Going from once a second to ~10 Hz fixes sudden
  light changes (`cloud_steps` 79% → 97%).
- **The statistic change does not show up in detection rate.** Brightest
  pixel and quartile mean score the same here (89% each). Commit 2 is
  justified by the out-of-bounds read and by robustness on real, noisier
  images, not by these numbers.
- **The median beats the per-tag band** slightly, with half the exposure
  writes.
- **It does not beat the camera's built-in autoexposure overall in this
  simulation** (98% vs 97% per tag). Built-in is better in direct sun (98%
  vs 94%, because it never loses the tags in the first place) and worse when
  a projection lands near a tag (`projector_feedback_mild` 87% vs 100%).
  The built-in model here is a generic stand-in, and the scenarios have
  only small projected areas, so the real comparison needs a real table.
- **`projector_feedback` is 74% for everyone.** One tag has projected light
  across 45% of it and cannot be decoded at any exposure. Exposure cannot
  fix that case.

## Re-running the simulation

    cd autoexposure-study/sim
    pip install numpy opencv-python-headless
    A=../../vendor/apriltag
    gcc -O2 -fPIC -shared -o libatshim.so atshim.c $A/apriltag.c \
        $A/apriltag_quad_thresh.c $A/tagStandard52h13.c $A/common/*.c -I$A -lm -lpthread
    python3 run_matrix.py --controllers amg_asis,v4l2_auto,branch_asis,amg_minmax_1hz,amg_quartile_1hz,amg_quartile_10hz,amg_suggested,amg_suggested_contrast \
        --scenarios all --seeds 1,2 --out results-amg
    python3 make_amg_table.py
    python3 test_tcl_equiv.py   # needs vendor/jimtcl/jimsh (make deps)

About 20 minutes on 4 cores. `results-amg/summary.csv` is committed; the
per-run timelines are not.

## Left for later

- **Gain.** Once exposure reaches the 15 ms cap in a dark room there is
  nothing left to adjust. `main` now has `Wish camera ... uses gain`, so
  raising gain at the cap is the natural next step.
- **Real exposure range and frame rate.** `lo`/`hi` are constants. The
  camera's actual range and the frame rate it negotiated (often 30 fps, not
  the 60 requested) would allow longer exposures in dim rooms.
- **Starting point.** `usb.folk` has `getExposure`, but nothing claims the
  value, so the loop seeds from 3000 µs when no exposure has been wished.
