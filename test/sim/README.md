# Headless simulation of a Folk table

Everything here runs without a projector, camera, GPU, keyboard, mouse or
sound card: Folk renders to an offscreen display (Mesa lavapipe is enough),
pages are placed on an emulated tabletop instead of being seen by a camera,
USB input comes from an emulator, and sound goes to a capturable sink.

It exists to test `builtin-programs/browser.folk` (a web browser on a page:
`Wish $this is a web browser showing "https://..."`) with the things a
person at the table would use: the on-table editor, a USB keyboard and a USB
mouse.

    ./run.sh            # all of it (~6 min)
    ./run.sh --quick    # Folk-level tests + the end-to-end test (~2.5 min)

## What is emulated, and how faithfully

| Real table | Here |
|---|---|
| Projector | `FOLK_HEADLESS=1280x720 ./folk`: a `headless` display (Vulkan `VK_EXT_headless_surface`). `Wish display headless is captured` gives `display headless has frame /im/ at timestamp /t/`; `GET /display-frame` returns the next presented frame as PNG. Same swapchain and draw path as a real display. |
| Camera + printed pages (AprilTags) | `programs/table.folk`: `Wish the simulated table has page <name> at <x> <y> <w> <h> with code <code>` produces the quad, geometry and program a detected page would have, in display pixels. No camera or pose estimation is exercised. `programs/sim-setup.folk` supplies an ideal calibration. |
| USB keyboard and mouse | `hidemu/`: models HID boot-protocol reports (6-key rollover, int8 mouse deltas split over polling intervals) and the kernel's hid-input/evdev translation (MSC_SCAN, EV_KEY, EV_REL, SYN_REPORT, software autorepeat), and writes `struct input_event` to FIFOs that `keyboard.folk` and `mouse.folk` read like `/dev/input/event*`. It logs every report and event with timestamps: the ground truth for the oracles. (This kernel has no uinput/uhid, so there is no real `/dev/input` node and no udev discovery.) |
| Speakers | `audio/sink.sh`: a private PulseAudio daemon with one null sink, recorded to WAV. Chromium (and Folk's `audio.folk`) play into it unmodified. `audio/analyze.py` finds tones and silences. |
| A person | `tests/rig.py`: abstract actions (click, drag, type, chord, wheel, ...) turned into USB traffic; `folksim.py` boots and inspects Folk from outside. |

The on-table editor, the keyboard/mouse drivers, the browser, the GPU
pipeline and Chromium are the real ones.

## Layout

    folksim.py        FolkSim (boot a headless Folk, eval Tcl, query statements, fetch frames),
                      HidEmu (drive hidemu), decode_strip (read a test app's state from pixels)
    appserver.py      serves apps/ and records what the pages report (events, state, layout)
    apps/             GUI test apps: events (raw input logger), paint, kanban, editor, form, synth
    hidemu/           the USB HID emulator (C)
    programs/         sim programs loaded into the simulated Folk (sim-setup, table)
    audio/            sink.sh, analyze.py, a self-test
    tests/
      editor.sh           the real editor on a virtual page, typed into with the USB keyboard
      apps_reference.mjs  scenarios.json through Playwright: the reference oracle
      rig.py              browser page + keyboard/mouse page + all the oracles
      e2e_browser.py      type the browser wish into the editor, then use six GUI apps
      fuzz_browser.py     seeded fuzzing: structured (+ differential), raw HID, sound

Folk-level tests that need no external driver live in `test/` and run as
`./folk test/<name>.folk`: `headless-display`, `mouse`, `keyboard-seq`,
`sim-table`, `browser`.

## The oracles

None of them trusts Folk's own account of what happened.

- **state**: each test app reports its state and a log of the trusted DOM
  events it saw to `appserver.py`; scenarios say what state must result.
- **strip**: each app paints a 24-bit hash of its state as colour blocks along
  its bottom edge. The hash read from the *projected frame* must be the hash
  the page reported. When it is not, the oracle says who is behind (it also
  reads Chromium's own screenshot).
- **pixels**: the page as Folk projects it must be Chromium's screenshot plus
  the mouse cursor at the pointer, compared as 4x4 block means (frames reach
  Folk as JPEG).
- **pointer**: where Folk and the page have the pointer must be the sum of
  the mouse's reports.
- **input**: after every action the page must have seen the events it implies
  (nothing lost); in monkey mode the page's log must equal hidemu's log edge
  for edge.
- **sound**: tones in the capture must match the notes the page played.
- **differential**: the recorded actions of a structured fuzz case are
  replayed through Playwright; the final application state must be the same.

## Fuzzing

    python3 tests/fuzz_browser.py --seed 7 --structured 20 --monkey 5 --audio 2
    python3 tests/fuzz_browser.py --replay <out>/cases/structured-form-2.json

Every case (seed, generated actions) is written to `<out>/cases/`; failures
also leave the projected frame and the page's log there.

Found by the simulation and fixed in `browser.folk`:

- every key typed twice (two subscriptions per keyboard page);
- the projected picture one step behind the page after keyboard scrolling
  (Chromium drops the last screencast frame; the browser now refreshes once
  frames and input go quiet);
- `<select>` option lists invisible and unclickable (Chromium draws them
  outside the page's picture; `lib/browser-page-shim.js` makes a list opened
  with the mouse part of the page).

Found in code review, confirmed by experiment, and fixed: a size change
leaked the old Chromium (inherited destructors); a page titled `-keep`
stopped all state updates; held buttons stuck when a mouse page moved away
mid-drag; input after a device's reader restarted was dropped; the pointer
froze for up to 400 ms at the start of a stroke.

## Requirements

Ubuntu packages: `mesa-vulkan-drivers libvulkan-dev glslc libturbojpeg0-dev
libpng-dev console-data kbd pulseaudio pulseaudio-utils` (plus what the main
README lists), Python 3 with `numpy` and `pillow`, and a Chromium: set
`FOLK_BROWSER`, or have `chromium-headless-shell`, `chromium`,
`chromium-browser` or `google-chrome` on the PATH (Playwright's download
under `/opt/pw-browsers` is found too). `apps_reference.mjs` and the
differential oracle need Node and Playwright.

## Limits

- Not shown on the table at all (Chromium draws them outside the page):
  date/time/colour pickers, datalist suggestions, native context menus,
  tooltips. Pages that need them don't work with the mouse.
- As root (the usual container), Chromium runs with `--no-sandbox`.

- Timing is real time: the oracles wait for conditions rather than sleep, but
  a badly overloaded machine can still fail them.
- Keyboard and mouse are separate devices with separate sequence numbers;
  order *between* them is arrival order, as with real USB devices.
- A keyboard page that targets the browser types into the page; to edit the
  page's program again, use the web editor or take the wish away.
- Pointer position is the clamped sum of mouse reports. `mouse.folk` may merge
  queued motion-only frames, so after a sweep into a screen edge under load
  the result can differ by the merged amount.
