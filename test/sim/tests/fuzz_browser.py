#!/usr/bin/env python3
"""fuzz_browser.py -- fuzz Folk's web browser with emulated USB input, headless.

One Folk on a simulated table (rig.py); a seed; three kinds of runs, each with oracles that do
not trust Folk:

  structured   Random GUI actions (click, double click, right click, drag, type, keys, chords,
               wheel) on random elements of a test app, generated from the layout the page
               reports and played with the emulated USB keyboard and mouse. Checked while
               running (every input must reach the page; the state hash in the projected
               pixels must be the page's; Folk's picture must be Chromium's screenshot plus the
               cursor; the pointer must be the sum of the mouse's reports) and afterwards
               DIFFERENTIALLY: the same recorded actions are replayed through Playwright
               (apps_reference.mjs) and the final application state must be the same.

  monkey       Raw random HID traffic (hidemu's own `fuzz`: bursts of typing, held keys that
               autorepeat, chords, mouse jitter, long sweeps into the screen edges, clicks,
               multi-button presses, wheel) at the page that logs raw events. The page's log
               must be exactly what the devices sent according to hidemu's ground-truth log:
               every key press and release, in order; every button edge, in order; the wheel
               total. Nothing may be stuck afterwards.

  audio        Random notes on the synth (mouse on the on-screen keys, keyboard keys, chords)
               with random hold times. The captured sound must contain each note as often and
               about as long as it was held, and silence otherwise (a lost key release is a
               stuck note; a lost press is a missing one).

    python3 test/sim/tests/fuzz_browser.py --seed 1 --structured 12 --monkey 3 --audio 2
    python3 test/sim/tests/fuzz_browser.py --replay /tmp/x/cases/structured-kanban-3.json

Every case is written to <out>/cases/ (seed + actions) so a failure can be replayed. Exit code
0 if no oracle failed.
"""

import argparse
import json
import os
import random
import subprocess
import sys
import time
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
from rig import Rig, OracleError  # noqa: E402

STRUCTURED_APPS = ["kanban", "editor", "form", "paint", "events"]
TEXT = "abcdefghijklmnopqrstuvwxyz ABCXYZ 0123456789 .,;:!?-_=+()[]{}$/'\""
KEYS = ["ENTER", "ESC", "TAB", "BACKSPACE", "DELETE", "HOME", "END", "LEFT", "RIGHT", "UP", "DOWN"]
CHORDS = ["CTRL+A", "CTRL+C", "CTRL+V", "CTRL+X", "CTRL+Z", "CTRL+Y", "SHIFT+LEFT", "SHIFT+RIGHT",
          "SHIFT+UP", "SHIFT+DOWN", "CTRL+SHIFT+Z", "SHIFT+TAB"]

# evdev key name (hidemu's log) -> KeyboardEvent.code
CODE = {"SPACE": "Space", "DOT": "Period", "COMMA": "Comma", "SEMICOLON": "Semicolon", "MINUS": "Minus",
        "EQUAL": "Equal", "SLASH": "Slash", "BACKSLASH": "Backslash", "APOSTROPHE": "Quote", "GRAVE": "Backquote",
        "LEFTBRACE": "BracketLeft", "RIGHTBRACE": "BracketRight", "ENTER": "Enter", "ESC": "Escape",
        "TAB": "Tab", "BACKSPACE": "Backspace", "DELETE": "Delete", "HOME": "Home", "END": "End",
        "LEFT": "ArrowLeft", "RIGHT": "ArrowRight", "UP": "ArrowUp", "DOWN": "ArrowDown",
        "LEFTSHIFT": "ShiftLeft", "RIGHTSHIFT": "ShiftRight", "LEFTCTRL": "ControlLeft",
        "RIGHTCTRL": "ControlRight", "LEFTALT": "AltLeft", "RIGHTALT": "AltRight", "PAGEUP": "PageUp",
        "PAGEDOWN": "PageDown", "INSERT": "Insert", "CAPSLOCK": "CapsLock"}


def dom_code(key_name):
    k = key_name[4:] if key_name.startswith("KEY_") else key_name
    if k in CODE:
        return CODE[k]
    if len(k) == 1 and k.isalpha():
        return "Key" + k
    if len(k) == 1 and k.isdigit():
        return "Digit" + k
    return k


# ---------------------------------------------------------------------------------- structured

def gen_action(rng, rig, last):
    """One random action against what the page says is on screen right now. Targets are
    recorded as literal points so that the reference replays exactly the same thing."""
    layout = {k: r for k, r in rig.apps.layout(rig.session).items()
              if k != "strip" and r["w"] >= 6 and r["h"] >= 6 and r["x"] >= 0 and r["y"] >= 0
              and r["x"] + r["w"] <= rig.page[2] and r["y"] + r["h"] <= 616}

    def pt():
        if layout and rng.random() < 0.9:
            name = rng.choice(sorted(layout))
            r = layout[name]
            return {"x": int(r["x"] + r["w"] * rng.uniform(0.2, 0.8)), "y": int(r["y"] + r["h"] * rng.uniform(0.2, 0.8)), "id": name}
        return {"x": rng.randrange(4, rig.page[2] - 4), "y": rng.randrange(4, 612), "id": None}

    r = rng.random()
    out = []
    if r < 0.30:
        a = {"op": "click", "target": pt()}
    elif r < 0.38:
        a = {"op": "dblclick", "target": pt()}
    elif r < 0.44:
        a = {"op": "rightclick", "target": pt()}
    elif r < 0.58:
        a = {"op": "drag", "from": pt(), "to": pt(), "steps": rng.randrange(2, 10)}
    elif r < 0.76:
        a = {"op": "type", "text": "".join(rng.choice(TEXT) for _ in range(rng.randrange(1, 9)))}
    elif r < 0.87:
        a = {"op": "key", "key": rng.choice(KEYS), "count": rng.randrange(1, 4)}
    elif r < 0.94:
        a = {"op": "chord", "keys": rng.choice(CHORDS)}
    else:
        a = {"op": "wheel", "target": pt(), "dy": rng.choice([-3, -2, -1, 1, 2, 3])}
    # A second press near the previous one within the double-click time IS a double click for
    # a real mouse; the reference would not make it one. Keep them apart in time for both.
    press = a.get("target") if a["op"] in ("click", "dblclick", "rightclick") else a.get("from") if a["op"] == "drag" else None
    if press is not None and last.get("press") is not None and \
            abs(press["x"] - last["press"]["x"]) <= 8 and abs(press["y"] - last["press"]["y"]) <= 8:
        out.append({"op": "wait", "ms": 650})
    if a["op"] in ("click", "dblclick", "rightclick"):
        last["press"] = a["target"]
    elif a["op"] == "drag":
        last["press"] = a["to"]
    out.append(a)
    return out


def run_structured(rig, case, check_every=6):
    app, actions = case["app"], case.get("actions")
    rng = random.Random(case["seed"])
    session = "fz-%s-%d" % (case["name"], int(time.time() * 1000) % 10 ** 9)
    rig.open(app, session)
    recorded, last = [], {}
    replay = actions is not None
    n = len(actions) if replay else case["n"]
    i = 0
    while i < n:
        batch = [actions[i]] if replay else gen_action(rng, rig, last)
        for a in batch:
            case["at"] = len(recorded)
            recorded.append(a)
            case["actions"] = recorded
            rig.act(a)
        i += 1
        if i % check_every == 0:
            rig.check_strip()
            rig.check_pointer()
    rig.settle(quiet=0.3)
    case.pop("at", None)
    strip, _frame = rig.check_strip()
    rig.check_pointer()
    case["pixels"] = rig.check_pixels(case["name"])
    st = rig.check_health()
    case["stable"] = rig.js("window.__stableState()")
    case["hash"] = rig.js("window.__hash()")
    if strip["hash"] != case["hash"]:
        raise OracleError("strip shows hash %06x, the page's is %06x" % (strip["hash"], case["hash"]))
    case["stats"] = {k: st[k] for k in ("inputEventsSent", "eventsReordered", "eventsLate", "gapsSkipped",
                                         "eventsDuplicate", "dialogs") if k in st}


def normalize(app, state):
    """Drop what legitimately depends on how finely the mouse's path was sampled."""
    s = json.loads(json.dumps(state))
    if app == "paint":
        for stroke in s.get("strokes", []):
            pts = stroke.get("points")
            if isinstance(pts, list) and len(pts) > 2 and stroke.get("tool") in ("pen", "eraser"):
                stroke["points"] = [pts[0], pts[-1]]
        s.pop("canvasHash", None)       # antialiasing along a pen stroke follows its samples
    if app == "events" and isinstance(s.get("lastMouse"), dict):
        s["lastMouse"].pop("x", None)   # the pad also follows mousemoves: where the path last
        s["lastMouse"].pop("y", None)   # crossed it depends on how the path was sampled
    return s


def differential(rig, cases, out):
    """Replay the recorded cases through Playwright and compare the final application state."""
    path = os.path.join(out, "reference-scenarios.json")
    with open(path, "w") as f:
        json.dump({"scenarios": [{"name": c["name"], "app": c["app"], "actions": c["actions"], "expect": {}}
                                 for c in cases]}, f)
    refdir = os.path.join(out, "reference")
    p = subprocess.run(["node", os.path.join(HERE, "apps_reference.mjs"), "--scenarios", path, "--out", refdir,
                        "--keep-going"], capture_output=True, text=True, timeout=900)
    try:
        ref = json.load(open(os.path.join(refdir, "reference.json")))["scenarios"]
    except Exception:
        raise OracleError("the reference run produced nothing: %s" % (p.stdout + p.stderr)[-800:])
    from rig import subset
    for c in cases:
        r = ref.get(c["name"])
        if r is None or "stable" not in r:
            c["diff"] = "the reference has no result (%s)" % (r or {}).get("problems")
            continue
        a, b = normalize(c["app"], c["stable"]), normalize(c["app"], r["stable"])
        d = subset(b, a, "state") or subset(a, b, "state")
        c["referenceHash"] = r.get("hash")
        if d is None:
            c["diff"] = None
        else:
            c["diff"] = "Folk + USB devices and the Playwright reference end in different states: %s" % d
            c["referenceStable"] = r["stable"]


# -------------------------------------------------------------------------------------- monkey

def run_monkey(rig, case):
    session = "fz-%s-%d" % (case["name"], int(time.time() * 1000) % 10 ** 9)
    rig.open("events", session)
    rig.act({"op": "click", "target": "pad"})
    rig.settle(quiet=0.3)
    base = len(rig.apps.events(session))
    rig.hid.mark("monkey-start %s" % case["name"])
    rig.hid.seed(case["seed"])
    rig.hid.cmd("fuzz %d all" % case["n"], timeout=600)
    rig.hid.release_all()
    rig.hid.cmd("cps 10")
    rig.hid.mark("monkey-end")
    # what the devices sent (the kernel's view, from hidemu's log)
    log, on = [], False
    for r in rig.hid.log():
        if r["kind"] == "cmd" and r.get("text", "").startswith("mark "):
            on = r["text"] == "mark monkey-start %s" % case["name"]
            continue
        if on:
            log.append(r)
    keys = [(dom_code(r["code"]), r["value"]) for r in log
            if r["dev"] == "kbd" and r["kind"] == "event" and r["type"] == "EV_KEY" and r["value"] in (0, 1)]
    repeats = sum(1 for r in log if r["dev"] == "kbd" and r["kind"] == "event" and r["type"] == "EV_KEY" and r["value"] == 2)
    btn = {"BTN_LEFT": 0, "BTN_MOUSE": 0, "BTN_MIDDLE": 1, "BTN_RIGHT": 2}   # BTN_MOUSE == BTN_LEFT
    buttons = [(btn[r["code"]], r["value"]) for r in log
               if r["dev"] == "mouse" and r["kind"] == "event" and r["type"] == "EV_KEY" and r["code"] in btn]
    wheel = sum(r["value"] for r in log if r["dev"] == "mouse" and r["kind"] == "event" and r["code"] == "REL_WHEEL")
    hwheel = sum(r["value"] for r in log if r["dev"] == "mouse" and r["kind"] == "event" and r["code"] == "REL_HWHEEL")
    case["sent"] = {"keyEdges": len(keys), "keyRepeats": repeats, "buttonEdges": len(buttons), "wheel": wheel, "hwheel": hwheel,
                    "mouseReports": sum(1 for r in log if r["dev"] == "mouse" and r["kind"] == "report")}

    # what the page saw: wait until it has seen as many key and button edges as were sent
    def seen():
        ev = rig.apps.events(session)[base:]
        k = [(e["code"], 1 if e["k"] == "keydown" else 0) for e in ev if e["k"] in ("keydown", "keyup") and not e.get("r")]
        b = [(e["b"], 1 if e["k"] == "mousedown" else 0) for e in ev if e["k"] in ("mousedown", "mouseup")]
        return ev, k, b
    deadline = time.time() + 20
    while True:
        ev, k, b = seen()
        if (len(k) >= len(keys) and len(b) >= len(buttons)) or time.time() > deadline:
            break
        time.sleep(0.05)
    rig.settle(quiet=0.5, timeout=4)
    ev, k, b = seen()
    case["saw"] = {"keyEdges": len(k), "keyRepeats": sum(1 for e in ev if e["k"] == "keydown" and e.get("r")),
                   "buttonEdges": len(b), "wheelEvents": sum(1 for e in ev if e["k"] == "wheel"),
                   "wheelDy": sum(e["dy"] for e in ev if e["k"] == "wheel"), "wheelDx": sum(e["dx"] for e in ev if e["k"] == "wheel")}

    def first_diff(sent, got, what):
        for i, (s, g) in enumerate(zip(sent, got)):
            if s != g:
                return "%s edge %d: the device sent %s, the page saw %s (sent %d, saw %d)" % (what, i, s, g, len(sent), len(got))
        if len(sent) != len(got):
            return "%s: the device sent %d edges, the page saw %d (first extra/missing: %s)" % (
                what, len(sent), len(got), (sent + got)[min(len(sent), len(got))])
        return None
    for problem in (first_diff(keys, k, "key"), first_diff(buttons, b, "mouse button")):
        if problem:
            raise OracleError(problem)
    if case["saw"]["wheelDy"] != -100 * wheel:
        raise OracleError("wheel: the mouse sent %d detents, the page saw deltaY %s" % (wheel, case["saw"]["wheelDy"]))
    if abs(case["saw"]["wheelDx"]) != 100 * abs(hwheel):
        raise OracleError("horizontal wheel: the mouse sent %d detents, the page saw deltaX %s" % (hwheel, case["saw"]["wheelDx"]))
    # nothing may be left held, and Folk and the page must agree where the pointer ended up
    state = rig.apps.state(session)
    if state.get("down") or state.get("buttons"):
        raise OracleError("stuck after releasing everything: keys %s, buttons %s" % (state.get("down"), state.get("buttons")))
    folk_ptr = rig.pointer_statement()
    page_ptr = rig.js("window.__pointer()")
    if page_ptr and page_ptr.get("x") is not None and case["sent"]["mouseReports"]:
        deadline = time.time() + 3
        while (folk_ptr[0], folk_ptr[1]) != (page_ptr["x"], page_ptr["y"]) and time.time() < deadline:
            time.sleep(0.1)
            folk_ptr, page_ptr = rig.pointer_statement(), rig.js("window.__pointer()")
        if (folk_ptr[0], folk_ptr[1]) != (page_ptr["x"], page_ptr["y"]):
            raise OracleError("pointer: Folk has it at %s, the page last saw the mouse at %s" % (folk_ptr[:2], page_ptr))
    # and after the chaos the pointer must still be steerable to an exact place
    rig.home_pointer()
    rig.act({"op": "click", "target": "pad", "at": [0.5, 0.5]})
    rig.check_pointer()
    rig.check_strip()
    case["pixels"] = rig.check_pixels(case["name"])
    st = rig.check_health()
    case["stats"] = {k2: st[k2] for k2 in ("inputEventsSent", "eventsReordered", "eventsLate", "gapsSkipped",
                                           "eventsDuplicate") if k2 in st}


# --------------------------------------------------------------------------------------- audio

def run_audio(rig, case):
    rng = random.Random(case["seed"])
    session = "fz-%s-%d" % (case["name"], int(time.time() * 1000) % 10 ** 9)
    notes = [("C4", "a"), ("D4", "s"), ("E4", "d"), ("F4", "f"), ("G4", "g"), ("A4", "h"), ("B4", "j"), ("C5", "k")]
    rig.record(case["name"])
    rig.open("synth", session)
    played = []        # (frequencies, seconds held)
    plan = []
    for _ in range(case["n"]):
        how = rng.choice(["mouse", "key", "key", "chord"])
        hold = round(rng.uniform(0.35, 0.9), 2)
        gap = round(rng.uniform(0.35, 0.6), 2)
        picks = rng.sample(notes, 2 if how == "chord" else 1)
        plan.append({"how": how, "notes": [p[0] for p in picks], "hold": hold, "gap": gap})
        t0 = time.time()
        if how == "mouse":
            rig.act({"op": "mousedown", "target": "key-" + picks[0][0]})
        else:
            for p in picks:
                rig.act({"op": "keydown", "key": p[1]})
        sounding = rig.apps.wait_state(session, lambda s: len(s.get("sounding", [])) == len(picks), timeout=5)["sounding"]
        time.sleep(max(0.0, t0 + hold - time.time()))
        if how == "mouse":
            rig.act({"op": "mouseup", "target": "key-" + picks[0][0]})
        else:
            for p in picks:
                rig.act({"op": "keyup", "key": p[1]})
        held = time.time() - t0
        rig.apps.wait_state(session, lambda s: not s.get("sounding"), timeout=5)
        played.append((sounding, held))
        time.sleep(gap)
    case["plan"] = plan
    time.sleep(0.4)
    wav = rig.stop_record()
    total = wav.duration() if callable(wav.duration) else wav.duration
    by_freq = {}
    for freqs, held in played:
        for f in freqs:
            by_freq.setdefault(f, []).append(held)
    report = []
    for f, holds in sorted(by_freq.items()):
        spans = [(a, b) for a, b in wav.find_tone(f, tol_hz=10.0, max_gap=0.08) if b - a >= 0.15]
        report.append((f, [round(h, 2) for h in holds], [round(b - a, 2) for a, b in spans]))
        if len(spans) != len(holds):
            raise OracleError("sound: %.1f Hz was played %d time(s) (held %s s) but is in the capture %d time(s) (%s s)" % (
                f, len(holds), [round(h, 2) for h in holds], len(spans), [round(b - a, 2) for a, b in spans]))
        for (a, b), h in zip(spans, holds):
            if not (h - 0.45 <= b - a <= h + 0.3):
                raise OracleError("sound: a %.1f Hz note held for %.2f s sounds for %.2f s" % (f, h, b - a))
    wav.assert_silence(total - 0.3, total)
    case["sound"] = report
    rig.check_strip()
    rig.check_health()


# ---------------------------------------------------------------------------------------- main

def main(argv):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--seed", type=int, default=1)
    ap.add_argument("--structured", type=int, default=6, metavar="N", help="number of structured cases")
    ap.add_argument("--actions", type=int, default=30, help="actions per structured case")
    ap.add_argument("--apps", default=",".join(STRUCTURED_APPS))
    ap.add_argument("--monkey", type=int, default=2, metavar="N", help="number of raw HID cases")
    ap.add_argument("--monkey-commands", type=int, default=150, help="hidemu fuzz commands per monkey case")
    ap.add_argument("--audio", type=int, default=1, metavar="N", help="number of sound cases")
    ap.add_argument("--notes", type=int, default=8, help="notes per sound case")
    ap.add_argument("--mouse-hz", type=int, help="USB mouse polling rate (default 125)")
    ap.add_argument("--no-reference", action="store_true", help="skip the Playwright differential")
    ap.add_argument("--replay", metavar="CASE.json", help="replay one recorded case")
    ap.add_argument("--out")
    ap.add_argument("--keep", action="store_true")
    args = ap.parse_args(argv)

    cases = []
    if args.replay:
        c = json.load(open(args.replay))
        cases.append({k: c[k] for k in ("name", "kind", "app", "seed", "n", "actions") if k in c})
    else:
        apps = args.apps.split(",")
        for i in range(args.structured):
            app = apps[i % len(apps)]
            cases.append({"name": "structured-%s-%d" % (app, i), "kind": "structured", "app": app,
                          "seed": args.seed * 1000 + i, "n": args.actions})
        for i in range(args.monkey):
            cases.append({"name": "monkey-%d" % i, "kind": "monkey", "app": "events",
                          "seed": args.seed * 1000 + 500 + i, "n": args.monkey_commands})
        for i in range(args.audio):
            cases.append({"name": "audio-%d" % i, "kind": "audio", "app": "synth",
                          "seed": args.seed * 1000 + 900 + i, "n": args.notes})

    rig = Rig(out=args.out, audio=any(c["kind"] == "audio" for c in cases), keep=args.keep, mouse_hz=args.mouse_hz)
    os.makedirs(os.path.join(rig.out, "cases"), exist_ok=True)
    print("output in %s; seed %d; %d cases" % (rig.out, args.seed, len(cases)), flush=True)
    problems = []
    try:
        rig.start()
        for c in cases:
            t0 = time.time()
            try:
                {"structured": run_structured, "monkey": run_monkey, "audio": run_audio}[c["kind"]](rig, c)
                c["ok"] = True
            except Exception as e:
                c["ok"] = False
                c["error"] = "%s: %s" % (type(e).__name__, e)
                if not isinstance(e, (OracleError, TimeoutError)):
                    c["trace"] = traceback.format_exc()
                try:
                    rig.folk.frame().save(os.path.join(rig.out, c["name"] + "-fail.png"))
                    with open(os.path.join(rig.out, c["name"] + "-pagelog.json"), "w") as f:
                        json.dump(rig.apps.dump(rig.session), f)
                    if c["kind"] == "audio":
                        rig.stop_record()
                    rig.hid.release_all()
                except Exception:
                    pass
            c["seconds"] = round(time.time() - t0, 1)
            extra = ""
            if c["kind"] == "structured":
                extra = "%d actions, hash %s, %s" % (len(c.get("actions", [])), "%06x" % c["hash"] if "hash" in c else "?", c.get("stats", ""))
            elif c["kind"] == "monkey":
                extra = "sent %s; saw %s; %s" % (c.get("sent"), c.get("saw"), c.get("stats", ""))
            elif c["kind"] == "audio":
                extra = "notes (Hz, held, heard): %s" % c.get("sound")
            rig.say("%s %s (%.0f s): %s%s" % ("ok  " if c["ok"] else "FAIL", c["name"], c["seconds"], extra,
                                               "" if c["ok"] else "\n         " + c["error"]))
            with open(os.path.join(rig.out, "cases", c["name"] + ".json"), "w") as f:
                json.dump(c, f, indent=1)
        structured = [c for c in cases if c["kind"] == "structured" and c.get("ok")]
        if structured and not args.no_reference:
            differential(rig, structured, rig.out)
            for c in structured:
                if c["diff"]:
                    c["ok"] = False
                    c["error"] = c["diff"]
                    rig.say("FAIL %s: %s" % (c["name"], c["diff"]))
                    with open(os.path.join(rig.out, "cases", c["name"] + ".json"), "w") as f:
                        json.dump(c, f, indent=1)
            rig.say("differential: %d/%d structured cases end in the same state as the Playwright reference" % (
                sum(1 for c in structured if not c["diff"]), len(structured)))
    except Exception as e:
        problems.append("%s: %s" % (type(e).__name__, e))
        traceback.print_exc()
    finally:
        problems += rig.stop()
    failed = [c["name"] for c in cases if not c.get("ok")]
    with open(os.path.join(rig.out, "fuzz-results.json"), "w") as f:
        json.dump({"seed": args.seed, "cases": cases, "problems": problems}, f, indent=1)
    for p in problems:
        print("PROBLEM: %s" % p)
    if failed or problems:
        print("FAIL: %d/%d cases ok; failed: %s" % (len(cases) - len(failed), len(cases), ", ".join(failed)))
        return 1
    print("PASS: %d/%d cases (seed %d)" % (len(cases), len(cases), args.seed))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
