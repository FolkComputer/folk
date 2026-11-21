#!/usr/bin/env python3
"""e2e_browser.py -- use complicated GUI apps in Folk's web browser, headless, end to end.

One Folk boots on a simulated table (see rig.py). An emulated USB keyboard types the browser
wish into the real on-table editor and saves it; the page becomes a web browser. Then every
scenario of scenarios.json (the same ones apps_reference.mjs runs through Playwright) is
replayed with the emulated USB keyboard and mouse, and checked with oracles that do not
trust Folk: the page's own report of what it saw, the page's state hash read back from the
projected pixels, Folk's picture against Chromium's screenshot, the pointer against the sum
of the mouse's reports, and (for the synth) the notes in the captured sound.

    python3 test/sim/tests/e2e_browser.py [--only kanban,paint] [--out DIR] [--no-audio]
                                          [--no-editor] [--keep]

Exit code 0 if everything holds. Frames, screenshots, the sound capture and results.json are
left in --out (default: a fresh directory under /tmp).
"""

import argparse
import json
import os
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rig import Rig, OracleError, PAGE  # noqa: E402


def check_sound(rig, wav, state):
    """The notes the synth says it played must be in the capture, in that order."""
    log = state.get("audioLog") or []
    # pair on/off per frequency -> [(freq, seconds)]
    on, notes, step = {}, [], None
    for e in log:
        if e["ev"] == "on" and e["f"] is not None:
            on[e["f"]] = e["t"]
        elif e["ev"] == "off" and e["f"] in on:
            notes.append((e["f"], (e["t"] - on.pop(e["f"])) / 1000.0, e["t"]))
        if e["ev"] in ("seq-step", "seq-end", "seq-stop") and step is not None:
            notes.append((step[0], (e["t"] - step[1]) / 1000.0, e["t"]))     # the sequencer's notes
            step = None
        if e["ev"] == "seq-step":
            step = (e["f"], e["t"])
    if not notes:
        raise OracleError("sound: the synth's audio log has no notes: %r" % log[:6])
    found = []
    for f, dur, _t in notes:
        if dur < 0.15:
            continue
        spans = wav.find_tone(f, tol_hz=12.0, max_gap=0.06)
        longest = max((b - a for a, b in spans), default=0.0)
        if longest < 0.5 * dur:
            raise OracleError("sound: a %.1f Hz note held %.2f s is in the capture for only %.2f s (%s)" % (
                f, dur, longest, wav.describe()[:400]))
        found.append((f, round(dur, 2), round(longest, 2)))
    # nothing may be sounding at the end
    total = wav.duration() if callable(wav.duration) else wav.duration
    wav.assert_silence(total - 0.25, total)
    return found


def run_scenario(rig, sc, first, use_editor, results):
    name = sc["name"]
    session = "e2e-%s-%d" % (name, int(time.time()))
    r = {"name": name, "app": sc["app"], "ok": False}
    results.append(r)
    t0 = time.time()
    sound = rig.audio and sc["app"] == "synth"
    try:
        if sound:
            rig.record("synth")
        typed = rig.open(sc["app"], session, via_editor=first and use_editor)
        if typed:
            text, frame = typed
            frame.save(os.path.join(rig.out, "editor-typed.png"))
            rig.say("ok: typed the wish into the on-table editor with the USB keyboard and saved it: %s" % text)
        rig.say("%s: loaded (%d elements in its layout); pointer homed" % (name, len(rig.apps.layout(session))))
        r["pixelsStart"] = rig.check_pixels(name + "-start")
        rig.run(sc["actions"])
        rig.check_state(sc["expect"])
        rig.check_log(sc.get("expectLog", []))
        strip, frame = rig.check_strip()
        frame.save(os.path.join(rig.out, name + "-end.png"))
        rig.check_pointer()
        r["pixelsEnd"] = rig.check_pixels(name + "-end")
        r["strip"] = strip
        st = rig.check_health()
        r["stats"] = {k: st[k] for k in ("framesReceived", "framesUploaded", "inputEventsSent", "eventsReordered",
                                         "eventsLate", "gapsSkipped", "decodeErrors", "dialogs") if k in st}
        if sound:
            time.sleep(0.4)
            wav = rig.stop_record()
            r["sound"] = check_sound(rig, wav, rig.apps.state(session))
        r["events"] = len(rig.apps.events(session))
        r["ok"] = True
        rig.say("ok   %s: %d actions, the page logged %d events; strip hash %06x; picture vs Chromium: worst 4x4 block off by %.0f/255; %s%s" % (
            name, len(sc["actions"]), r["events"], strip["hash"], r["pixelsEnd"]["worstBlock"],
            " ".join("%s=%s" % kv for kv in r["stats"].items()),
            "; sound: %s" % r["sound"] if sound else ""))
    except Exception as e:
        r["error"] = "%s: %s" % (type(e).__name__, e)
        if not isinstance(e, (OracleError, TimeoutError)):
            r["trace"] = traceback.format_exc()
        rig.say("FAIL %s: %s" % (name, r["error"]))
        try:
            rig.folk.frame().save(os.path.join(rig.out, name + "-fail.png"))
            if sound:
                rig.stop_record()
        except Exception:
            pass
        try:
            with open(os.path.join(rig.out, name + "-log.json"), "w") as f:
                json.dump(rig.apps.dump(session), f, indent=1)
        except Exception:
            pass
    r["seconds"] = round(time.time() - t0, 1)
    return r["ok"]


def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--only", help="comma-separated scenario names")
    ap.add_argument("--out")
    ap.add_argument("--no-audio", action="store_true")
    ap.add_argument("--no-editor", action="store_true", help="set the page's program directly instead of typing it")
    ap.add_argument("--keep", action="store_true", help="keep Folk's HOME and logs")
    ap.add_argument("--mouse-hz", type=int, help="USB mouse polling rate (default 125)")
    args = ap.parse_args(argv)

    scenarios = json.load(open(os.path.join(HERE, "scenarios.json")))["scenarios"]
    if args.only:
        scenarios = [s for s in scenarios if s["name"] in args.only.split(",")]
    results = []
    rig = Rig(out=args.out, audio=not args.no_audio, keep=args.keep, mouse_hz=args.mouse_hz)
    print("output in %s" % rig.out, flush=True)
    problems = []
    try:
        rig.start()
        for i, sc in enumerate(scenarios):
            run_scenario(rig, sc, i == 0, not args.no_editor, results)
        if rig._handle is not None:
            # leaving: the wish goes away, Chromium must go with it
            pid = int(rig.stats()["pid"])
            rig.set_code("")
            deadline = time.time() + 20
            while os.path.exists("/proc/%d" % pid) and time.time() < deadline:
                time.sleep(0.2)
            if os.path.exists("/proc/%d" % pid):
                problems.append("Chromium (pid %d) is still running 20 s after the wish was removed" % pid)
            else:
                rig.say("ok: the wish is gone and so is Chromium (pid %d)" % pid)
    except Exception as e:
        problems.append("%s: %s" % (type(e).__name__, e))
        traceback.print_exc()
    finally:
        problems += rig.stop()
    failed = [r["name"] for r in results if not r["ok"]]
    with open(os.path.join(rig.out, "results.json"), "w") as f:
        json.dump({"results": results, "problems": problems}, f, indent=1)
    for p in problems:
        print("PROBLEM: %s" % p)
    if failed or problems or len(results) != len(scenarios):
        print("FAIL: %d/%d scenarios ok%s" % (len(results) - len(failed), len(scenarios),
                                              "; failed: " + ", ".join(failed) if failed else ""))
        return 1
    print("PASS: %d/%d scenarios through emulated USB keyboard and mouse" % (len(results), len(scenarios)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
