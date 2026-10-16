# browser.folk: plan to close the open issues

Status: the first version is on branch `claude/browser-folk`. Its tests
pass in a container (`test/browser-{lib,render,e2e,tilt}.folk`), but
these issues are still open and none of them is acceptable to ship:

| # | Issue | Stage |
|---|-------|-------|
| A | A `/tmp/folk-browser-<pid>` folder is left behind on each run | 1 |
| B | Hovered-link statements are recalculated on every new frame | 2 |
| C | All browsers share one Chromium thread, so one slow page load pauses the others | 3 |
| D | Each Folk machine needs a manual Playwright/Chromium install | 4 |
| E | Never tried on a real projector and camera | 5a |
| F | Tilt direction never checked against real camera data | 5b |
| G | YouTube playback never actually tried | 5c |

The stages are ordered so that each one makes the next one easier. Each
stage is one commit, or a small PR if it's large. Each must leave all
browser tests green.

## Rules for every stage

- **Write the failing test first.** For each issue, add a test that
  shows the problem on the current code, check that it fails, and only
  then fix it.
- **Run new and changed tests 10 times in a row.** One flaky failure
  means the stage isn't done. The `db.c` signal bug was only found this
  way.
- **No sleep-based timing in assertions.** Wait for Folk statements
  with a deadline (`expectSteps`), never `sleep N` followed by a check.
- **Keep driver calls fast.** Folk cancels a rule body that runs longer
  than 100 ms once the rule is no longer needed (`db.c`, the `KILL`
  path). Any driver call made inside a rule should return in under
  20 ms; slow work belongs in the driver's background loop.
- **Compare against a baseline build.** Run the existing `make test`
  suite before and after each stage. Six existing tests already fail
  (`backtrace`, `fn`, `collect-race`, `homography`, `options`, `python`);
  the goal is "no new failures", not "all green".

---

## Stage 1: no frames on disk (A)

**Why it happens.** The driver writes each screenshot to a PNG file in
`/tmp/folk-browser-<pid>/`, Folk reads it back, and the folder is never
removed when Folk exits.

**Approach.** Take files out of the frame path completely:

1. The driver takes the screenshot into memory
   (`page.screenshot()` with no path) and returns the PNG bytes. The
   Python bridge already sends raw bytes back to Tcl (the `okb`
   response in `lib/python.tcl`).
2. Add a `loadPngFromMemory` to `image/png-lib.folk`. It can reuse the
   existing decoder by opening the byte buffer with `fmemopen()` instead
   of `fopen()`, so it's a few lines and benefits other programs too.
3. Return the frame's other details (URL, scroll position, links) in a
   separate small call, or as a header ahead of the bytes.
4. Delete `BrowserFrameDir`.

**Also clean up processes.** Check that Chromium and the Python worker
exit when Folk exits (`Exit!`, Ctrl-C, or a crash). The Python bridge's
cleanup (`UvxCleanup` in `lib/python.tcl`) only runs when a rule stops
matching, not when Folk exits.

**Tests.**

- After each browser test, assert that no `/tmp/folk-browser*` path
  exists.
- A helper looks for leftover `chrome`/`chromium` processes whose parent
  process tree was the test's Folk process, and fails if it finds any.
  Run this in a wrapper script (e.g. `test/run-browser-tests.sh`),
  because it has to check after Folk has exited.

**Done when** the browser tests leave no files and no processes behind,
over 10 runs.

## Stage 2: stop the hover churn (B)

**Why it happens.** The pointing rule in `browser.folk` matches on
`$surface has browser frame /any/ with metadata /meta/`. A new frame
arrives about every 0.2–0.5 s, so the rule re-runs that often. Each
re-run:

- removes and re-adds `has hovered link`, `is a link` and
  `is pointing at link`;
- calls `hover ""` and then `hover href` (the 0.3 s grace period in the
  driver hides this);
- creates a new per-pointer clock rule.

Anything listening for `/target/ is a link` therefore restarts, so
`When /target/ is a link { Wish $this renders $target in a browser }`
re-creates its own browser session on every frame.

**Approach.**

1. **Publish links separately.** Put the links in their own statement,
   `$surface has browser links $links`, and only update it when the
   links actually change. The driver compares this frame's links with
   the previous frame's and reports whether they changed. Scrolling
   changes link positions, which is a real change.
2. **Make pointing depend on links only.** The pointing rule matches
   that links statement instead of the frame.
3. **Hold the hovered link per pointer.** Work out the hovered link,
   then
   `Hold! -key [list hover $pointer $surface] Claim … hovered link $href`,
   and only re-hold it when the link differs from what is currently
   held. Clear it in the rule's `On unmatch`.
4. **Move the dwell timer into the driver.** The driver's frame loop
   already ticks regularly; it should advance the hover progress
   itself. Then the per-pointer clock rule goes away, and with it the
   grace-period workaround in `_hover`.
5. **Smooth the pointer.** Camera noise jitters pointer positions every
   frame. Add a small dead band so a still hand doesn't flicker between
   two neighbouring links (keep the current link unless the whisker tip
   moves more than about 8 px away from it).

**Tests (in `browser-e2e`).**

- **No churn:** hold the pointer still for 5 s, count matches of
  `When /href/ is a link` (a counter statement), and expect exactly 1.
- **Jitter:** replay pointer positions with ±2 mm of noise and expect
  the same: one hover, and the dwell still follows the link.
- **Moving between links:** move the pointer from link 1 to link 2 (the
  fixture needs a second link). Expect exactly one change of hovered
  link, and the dwell timer restarts.

**Done when** a still pointer produces one hover and one `is a link`
for its whole duration.

## Stage 3: browsers that don't block each other (C)

**Why it happens.** The driver is a single thread running Playwright's
synchronous API. Every call waits in one queue, so a 20 s page load
holds up screenshots for every other browser. On top of that, the
screenshot happens inside Folk's clock rule, which can take over 100 ms
and get cancelled.

**Approach.** Rewrite the driver around Playwright's asynchronous API:

1. **One event loop thread** owns Playwright. Each session has its own
   task and its own lock, so sessions run at the same time.
2. **Folk's calls only change state and read state.**
   - `openSession`, `navigate`, `scrollBy` and `hover` record what's
     wanted and return immediately. The session's task does the actual
     work.
   - Navigation becomes asynchronous: it reports `loading` and
     `loaded` in the frame details instead of making the caller wait.
3. **Each session produces its own frames** on its own loop:
   - Use Chromium's screencast feature (CDP `Page.startScreencast`,
     which pushes frames as the page changes) instead of polling for
     screenshots.
   - Keep only the newest frame in the session.
   - Folk's clock rule calls `latestFrame sid lastN`, which returns
     nothing if there's no new frame. That call is a memory read and
     takes well under 20 ms.
   - Stage 1's in-memory frames make this simple.
4. **Recover from page crashes.** If a page crashes or Chromium
   disconnects, recreate the page or browser and report the error on
   the page that asked for it (`$p has error …`) rather than going
   silent.
5. **Rate limits per session.** Cap the frame rate (e.g. 10 fps for
   pages, the video rate for Stage 5c), and lower it for sessions whose
   frames haven't changed.

**Tests.**

- **A local test web server.** Add a tiny Python HTTP server, started by
  the test, with a `/slow?ms=10000` route. Do not use `file://` URLs for
  this; they can't be slowed down.
- **Isolation:** session A loads `/slow?ms=10000` while session B shows
  the fixture page. B must keep getting new frames (scroll B and expect
  the new scroll position in a frame within 1 s), and A must report
  `loading` while it waits.
- **Speed:** every driver call made from Folk returns in under 20 ms
  (the 99th-percentile time over a 30 s run). Measure with
  `clock microseconds` around the calls.
- **Crash recovery:** send a page to `chrome://crash` and expect the
  session to come back and show its URL again.
- **Folk must never cancel a browser rule:** there should be no
  `KILL (` lines in the test's stderr.

**Done when** a slow site never delays another browser, and the
browser never trips Folk's 100 ms cancellation.

## Stage 4: zero-step setup (D)

**Why it happens.** Playwright needs its own matching Chromium build,
plus system libraries. Today someone has to run
`uvx … playwright install --with-deps chromium` by hand.

**Approach.**

1. **Detect Chromium in this order.** If none is found, go to step 2.
   - `FOLK_BROWSER_CHROMIUM`, if set;
   - the Chromium that matches the pinned Playwright version;
   - a system `chromium`, `chromium-browser` or `google-chrome`
     (Playwright can drive a newer Chrome through `executable_path`;
     check this works with the pinned version on Debian and Raspberry
     Pi OS).
2. **Install it automatically.** If nothing is found, the driver runs
   `playwright install chromium` itself (no root needed). While that
   runs it reports `the browser driver is installing`, and
   `browser.folk` shows "Installing browser…" on every page that asked
   for a browser instead of showing nothing.
3. **System libraries** (the `--with-deps` part) need root. Add them to
   Folk's normal machine setup, wherever the README's install steps
   live, so new machines get them. If they're missing at launch, turn
   Chromium's "missing shared library" error into a readable message on
   the page with the exact `apt install` line.
4. **One Playwright version.** Keep the pinned version in one place
   (`browser-driver.folk`), so it can't drift between the install and
   the launch.

**Tests.**

- **Opt-in, needs network:** set `PLAYWRIGHT_BROWSERS_PATH` to an empty
  temp folder and start a session. Expect the "installing" statement,
  then a rendered frame. Name it `test/browser-install.folk` and skip it
  unless `FOLK_TEST_NETWORK=1`.
- **Unit:** a broken `FOLK_BROWSER_CHROMIUM=/nonexistent` produces
  `$p has error` with a useful message, within 5 s.

**Done when** a new Folk machine with the standard setup shows a web
page with no manual steps beyond Folk's normal install.

## Stage 5: real-hardware validation

### 5a. Drawing on the projector and camera (E)

**Not yet tested:** the actual drawing path (canvas → GPU texture →
composited onto the table), and whether adjacent placements
(`below`, etc.) get a canvas and show up.

1. **Try a software GPU first.** Try to run `gpu.folk` without a
   display using lavapipe, Mesa's software Vulkan
   (`mesa-vulkan-drivers`). If that works, write
   `test/browser-gpu.folk`: render the fixture page onto a page, read
   the page's canvas back from the GPU, and check pixel colours as the
   current tests do.
   - The red header and blue link should land where the fixture says.
   - A `below` placement should be one page-height lower.
   - If no GPU readback exists yet, adding one to `gpu/textures.folk`
     is part of this stage.
2. **Memory soak:** run a session that changes every frame (an animated
   page) for 10 minutes, and check that GPU texture count and RSS stay
   flat. Each frame gets a new `uniq` and therefore a new texture, so
   this checks that old textures really are freed.
3. **Manual check on a real table.** Write it as a checklist in this
   file, and record the outcome with photos:
   - Does the page land on the paper?
   - Is it readable?
   - Does it follow when you move the paper?
   - Does each of the four placements sit beside the page?
   - Does pointing outline the right link?

### 5b. Tilt in real camera coordinates (F)

**What we know.** Page positions are in camera space, and the camera
follows OpenCV's convention: x right, y down, z away from the camera.
For a camera looking down at a table, a page's normal from
`cross(right, down)` points away from the camera, which is the
convention `browser-lib`'s `tiltDegrees` assumes. So the sign is
probably right, but nothing has confirmed it with real data.

**Real problems to fix.**

- **The resting position is taken from the page's first sighting.** A
  page first seen while in someone's hand gets a wrong "flat". Use the
  table itself as the reference instead:
  - from calibration (a camera-to-table transform, if calibration
    already produces one), or
  - the median normal of all pages that have been still for more than
    2 s.
- **Camera pose noise jitters the tilt angle.** Low-pass filter the
  angle (e.g. an exponential moving average with τ≈150 ms) and add
  hysteresis at the deadzone edge.
- **Projector-camera rigs are often angled.** Confirm that a page lying
  flat reads ≈0° anywhere on the table, not just at the centre.

**Approach: record once, replay forever.**

1. Write a small recorder (`builtin-programs/browser/record-quads.folk`,
   off by default) that logs `$p has quad` with timestamps to a file.
2. On a real Folk machine, record one page in each of these positions:
   - flat in several places on the table;
   - top edge raised by 15° and 30°;
   - bottom edge raised by 15° and 30°;
   - left and right edges raised;
   - picked up and put back down.
3. Commit the recordings as `test/browser-fixtures/quads-*.tcl` and
   write `test/browser-tilt-replay.folk`. It replays them through
   `browser.folk` and checks:
   - the sign and size of the angle (±5°);
   - zero scroll while flat anywhere on the table;
   - no drift after pick-up and put-down.

**Done when** the replay test passes on recorded data from at least two
machines.

### 5c. YouTube playback (G)

**Risks.**

- **Codecs:** Playwright's Chromium has no H.264/AAC. YouTube usually
  sends VP9/AV1 with Opus, which is fine, but this hasn't been checked.
- **Blocked embeds:** some embeds show "Video unavailable" (for example,
  when the uploader disallows embedding). A missing `Referer` can also
  trigger error 153.
- **Other blockers:** cookie and consent walls (EU) and ads.
- **Sound:** the current URL uses `mute=1`. With
  `--autoplay-policy=no-user-gesture-required` set, playing unmuted
  should work, but whether headless Chromium's sound reaches the
  machine's speakers (PulseAudio/PipeWire/ALSA) is unknown.
- **Frame rate:** 2 screenshots a second isn't video. Stage 3's
  screencast helps; measure the frame rate on the slowest target
  machine (e.g. a Raspberry Pi 5).

**Approach.**

1. **Spike, about 1 day.** On a real Folk machine, measure:
   - screencast fps at 1024×576;
   - CPU load;
   - whether sound plays;
   - how many of 10 popular videos actually play in the embed.

   Write down the numbers here.
2. **If the spike looks good** (≥20 fps, sound works, ≥8/10 videos
   play), keep the browser path. Turn `mute` off, add a small loading
   overlay, and detect YouTube's error screen by checking for its
   `.ytp-error` element on the page. When it appears, claim
   `$p has error "video can't be embedded"`.
3. **If the spike looks bad,** don't use the browser for video:
   - `yt-dlp` resolves the stream address;
   - `ffmpeg` decodes it straight into the same frame ring that
     `browser.folk` already uses, at the video's frame rate;
   - sound goes through `audio.folk` (miniaudio).

   The `plays YouTube video` wish stays the same; only what happens
   behind it changes.
4. **The binder:** print a real two-video binder and check the pages
   are recognised and each one plays its video.

**Tests.**

- **No network needed:** use `ffmpeg` to make a test video of solid
  colours that changes every 0.5 s, and play it in a local fixture page.
  Assert the frames go through at least 3 different colours in order
  within 3 s, which shows the video is actually playing.
- **Opt-in, needs network:** play one known embeddable public video and
  assert that the page doesn't show `.ytp-error` and that frames
  change.

**Done when** a printed binder page plays its video, with sound, at
≥20 fps on a real Folk machine. If that isn't possible, the reason must
be shown on the page itself.

---

## Suggested order and size

| Stage | Size | Depends on |
|-------|------|-----------|
| 1 no frames on disk | S (½ day) | — |
| 2 hover churn | S–M (1 day) | — |
| 3 non-blocking driver | M–L (2–3 days) | 1 |
| 4 zero-step setup | S–M (1 day) | 3, so it isn't done twice |
| 5a GPU path | M (1–2 days) + table time | 1 |
| 5b tilt replay | M (1 day) + recording session | real Folk machine |
| 5c YouTube | spike 1 day, then S or L | 3, real Folk machine |

5a, 5b and 5c need someone at a real Folk machine; the rest can be done
in a container.

Also still to do: the `db.c` signal fix (commit `754b522`) should go
upstream on its own, separate from the browser work.
