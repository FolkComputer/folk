#!/usr/bin/env python3
"""rig.py -- a web browser on a simulated Folk table, driven by emulated USB devices.

Puts the pieces of test/sim together:

    hidemu (USB keyboard + mouse) --FIFOs--> Folk (keyboard.folk, mouse.folk, the on-table
    editor, browser.folk -> Chromium) --headless display--> captured projector frames
                                                   \\--PulseAudio null sink--> captured sound
    test apps (appserver.py) report what the page itself saw (events, state, layout)

and offers the same abstract actions as tests/scenarios.json (click, drag, type, chord, wheel,
...) with oracles that do not trust Folk:

    state    what the page reports (POSTed to the app server) vs. what was expected
    strip    the page's state hash, read back from the pixels Folk would project
    pixels   Folk's projected picture of the page vs. Chromium's own screenshot; they may
             differ only where Folk draws the mouse cursor, which must be at the pointer
    pointer  where the page saw the mouse vs. the sum of what the USB mouse reported
    input    key/button events the page saw vs. hidemu's ground-truth log
    sound    tones in the captured audio vs. the notes the page says it played

The table (display pixels; 1 display pixel = 1 CSS pixel of the page):

    +--------------------------------------------+
    |  "browser-page" 1024x640 at (128, 8)       |   a page; its program is typed into the
    |                                            |   on-table editor by the emulated keyboard
    +--------------------------------------------+
                  [ "desk" ]                         a keyboard + mouse page pointing up at it
"""

import json
import math
import os
import shutil
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
SIM = os.path.dirname(HERE)
sys.path.insert(0, SIM)
sys.path.insert(0, os.path.join(SIM, "audio"))

from folksim import FolkSim, HidEmu, decode_strip, tcl_quote  # noqa: E402
from appserver import AppServer  # noqa: E402

PAGE = "browser-page"
DESK = "desk"
CURSOR_W, CURSOR_H = 12, 18     # the arrow browser.folk composites at the pointer (hot spot 0,0)


class OracleError(AssertionError):
    pass


def subset(expect, actual, path="state"):
    """None if `expect` is a subset of `actual` (dicts recursively; lists element for element;
    numbers within 0.01), else a description of the first difference."""
    if isinstance(expect, dict):
        if not isinstance(actual, dict):
            return "%s: expected an object, got %r" % (path, actual)
        for k, v in expect.items():
            if k not in actual:
                return "%s.%s is missing" % (path, k)
            d = subset(v, actual[k], "%s.%s" % (path, k))
            if d:
                return d
        return None
    if isinstance(expect, list):
        if not isinstance(actual, list) or len(actual) != len(expect):
            return "%s: expected %r, got %r" % (path, expect, actual)
        for i, (e, a) in enumerate(zip(expect, actual)):
            d = subset(e, a, "%s[%d]" % (path, i))
            if d:
                return d
        return None
    if isinstance(expect, (int, float)) and not isinstance(expect, bool) \
            and isinstance(actual, (int, float)) and not isinstance(actual, bool):
        return None if abs(expect - actual) <= 0.01 else "%s: expected %r, got %r" % (path, expect, actual)
    return None if expect == actual else "%s: expected %r, got %r" % (path, expect, actual)


def match_log(patterns, events):
    """None if the patterns match, in order, a subsequence of the events; else the first
    pattern that found no match."""
    i = 0
    for pat in patterns:
        while i < len(events) and subset(pat, events[i]) is not None:
            i += 1
        if i >= len(events):
            return pat
        i += 1
    return None


class Rig:
    def __init__(self, out=None, display=(1280, 720), page=(128, 8, 1024, 640), audio=False,
                 keep=False, verbose=True, mouse_hz=None, kbd_hz=None, cps=None, env=None):
        self.out = os.path.abspath(out or tempfile.mkdtemp(prefix="folk-rig-"))
        os.makedirs(self.out, exist_ok=True)
        self.display = display
        self.page = page
        self.audio = audio
        self.keep = keep
        self.verbose = verbose
        self.mouse_hz, self.kbd_hz, self.cps = mouse_hz, kbd_hz, cps
        self.env = dict(env or {})
        self.folk = self.hid = self.apps = None
        self.session = None
        self.px = self.py = None      # where the pointer must be, in page CSS px
        self.edited = False           # the page's program came from the on-table editor
        self.t0 = time.time()
        self.wav = None
        self._lib = self._handle = None
        self._sink_dir = None
        self.counts = {}
        self.whisker = (0, 0, 0, 0)
        self.t_input = time.time()

    def say(self, msg):
        if self.verbose:
            print("%7.2f  %s" % (time.time() - self.t0, msg), flush=True)

    # ---- lifecycle

    def start(self):
        if self.audio:
            # (short path: PulseAudio's socket lives in it, and sockaddr_un holds 108 bytes)
            self._sink_dir = tempfile.mkdtemp(prefix="folk-sink-")
            lines = subprocess.run([os.path.join(SIM, "audio", "sink.sh"), "start", self._sink_dir],
                                   check=True, capture_output=True, text=True).stdout.split()
            self.env.update(dict(line.split("=", 1) for line in lines if "=" in line))
        self.apps = AppServer().start()
        self.hid = HidEmu(rundir=os.path.join(self.out, "hid"))
        if self.mouse_hz is not None:
            self.hid.rate("mouse", self.mouse_hz)
        if self.kbd_hz is not None:
            self.hid.rate("kbd", self.kbd_hz)
        self.folk = FolkSim(display="%dx%d" % self.display,
                            programs=[os.path.join(SIM, "programs", "sim-setup.folk"),
                                      os.path.join(SIM, "programs", "table.folk")],
                            env=self.env, home=os.path.join(self.out, "home"), keep=self.keep)
        self.folk.start()
        self.say("Folk booted in %.1f s (pid %d, port %d)" % (self.folk.boot_seconds, self.folk.pid, self.folk.port))
        x, y, w, h = self.page
        # A keyboard page points up at whatever is within 0.3 of its own height above it; Folk
        # draws a dot there ("whisker"), on top of the page. Keep it off the strip's blocks.
        dw, dh = 200, 60
        dx, dy = x + w - dw - 20, y + h + 4
        self.whisker = (dx + dw // 2 - 20 - x, dy - int(0.3 * dh) - 20 - y, dx + dw // 2 + 20 - x, h)
        self.folk.hold_statement("desk", "Wish the simulated table has keyboard %s at %d %d %d %d with path %s mouse %s" % (
            DESK, dx, dy, dw, dh, tcl_quote(self.hid.kbd_path), tcl_quote(self.hid.mouse_path)))
        self._table_code("")
        return self

    def stop(self):
        problems = []
        for name, closer in (("hid", lambda: self.hid.close()), ("folk", lambda: self.folk.stop()),
                             ("apps", lambda: self.apps.stop())):
            try:
                if getattr(self, name) is not None:
                    closer()
            except Exception as e:      # keep tearing down
                problems.append("%s: %s" % (name, e))
        if self._sink_dir:
            subprocess.run([os.path.join(SIM, "audio", "sink.sh"), "stop", self._sink_dir],
                           capture_output=True, text=True)
            shutil.rmtree(self._sink_dir, ignore_errors=True)
        if self.folk is not None and self.folk.survivors:
            problems.append("processes survived Folk: %s" % self.folk.survivors)
        return problems

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()
        return False

    # ---- the page's program

    def _table_code(self, code):
        x, y, w, h = self.page
        self.folk.hold_statement("page", "Wish the simulated table has page %s at %d %d %d %d with code %s" % (
            PAGE, x, y, w, h, tcl_quote(code)))

    def set_code(self, code):
        """Replace the page's program without typing (what saving in the editor does)."""
        if self.edited:
            self.folk.eval("Hold! -on builtin-programs/programs.folk -key %s Wish program %s is replaced with code %s editedTime [clock seconds]; list" % (
                tcl_quote("new-code-for:" + PAGE), PAGE, tcl_quote(code)))
        else:
            self._table_code(code)

    def wish_line(self, url):
        w, h = self.page[2], self.page[3]
        return 'Wish $this is a web browser showing "%s" with width %d height %d' % (url, w, h)

    def open_via_editor(self, url, cps=25):
        """Type the browser wish into Folk's on-table editor with the USB keyboard, save with
        Ctrl+S. Returns the text the editor held when it was saved."""
        self.folk.wait_for("%s is typing into /editor/" % DESK, timeout=60)
        self.folk.wait_for("editor buffer for %s is /code/" % PAGE, timeout=60)
        line = self.wish_line(url)
        # keyboard.folk drops key events until the editor has subscribed; probe with a key that
        # leaves the (empty) buffer as it is
        deadline = time.time() + 60
        while True:
            self.hid.type("x")
            time.sleep(0.4)
            code = self.folk.query("editor buffer for %s is /code/" % PAGE)[0]["code"]
            if code:
                for _ in code:
                    self.hid.tap("BACKSPACE")
                break
            if time.time() > deadline:
                raise OracleError("the on-table editor never received a key")
        self.folk.wait_for(lambda: self.folk.query("editor buffer for %s is /code/" % PAGE)[0]["code"] == "", timeout=10)
        self.hid.cmd("cps %d" % cps)
        self.hid.type(line)
        typed = self.folk.wait_for(lambda: (lambda c: c if c == line else None)(
            self.folk.query("editor buffer for %s is /code/" % PAGE)[0]["code"]), timeout=30)
        frame = self.folk.frame()
        self.hid.chord("CTRL+S")
        self.edited = True
        return typed, frame

    def open(self, app, session, via_editor=False, **params):
        """Show a test app in the page and wait until it has loaded and reported its layout."""
        self.session = session
        url = self.apps.url(app, session, **params)
        result = None
        if via_editor:
            result = self.open_via_editor(url)
        else:
            self.set_code(self.wish_line(url))
        self.wait_browser()
        self.apps.wait_state(session, lambda s: s is not None, timeout=60)
        deadline = time.time() + 20
        while not self.apps.layout(session):
            if time.time() > deadline:
                raise OracleError("%s never reported its layout" % app)
            time.sleep(0.05)
        self.folk.wait_for("web browser %s has loading state complete" % PAGE, timeout=30)
        self.counts = {}
        self.home_pointer()
        return result

    def wait_browser(self):
        r = self.folk.wait_for("%s has web browser /b/" % PAGE, timeout=90)
        self._handle = r["b"]
        self._lib = self.folk.wait_for("the web browser library is /lib/", timeout=30)["lib"]
        self.folk.wait_for("%s is typing into %s" % (DESK, PAGE), timeout=30)
        self.folk.wait_for("%s is pointing into %s" % (DESK, PAGE), timeout=30)
        return self._handle

    def browser(self, proc, *args):
        return self.folk.eval("%s %s %s %s" % (self._lib, proc, self._handle, " ".join(tcl_quote(a) for a in args)))

    def js(self, expr):
        return json.loads(self.browser("browserEval", expr))

    def stats(self):
        words = self.browser("browserStats").split()
        return dict(zip(words[0::2], words[1::2]))

    # ---- the pointer

    def pointer_statement(self):
        r = self.folk.query("web browser %s has pointer /x/ /y/ buttons /b/" % PAGE)
        return (int(float(r[0]["x"])), int(float(r[0]["y"])), int(r[0]["b"])) if r else None

    def home_pointer(self):
        """Push the pointer into the top-left corner; from there on its position is the sum of
        what the mouse reports (1 unit = 1 CSS px), which is what the oracles check."""
        self.hid.move(-(self.page[2] + 200), -(self.page[3] + 200))
        self.px, self.py = 0, 0
        self.folk.wait_for(lambda: self.pointer_statement() == (0, 0, 0), timeout=10)

    def move_to(self, x, y, steps=1):
        x0, y0 = self.px, self.py
        for i in range(1, steps + 1):
            nx = x0 + round((x - x0) * i / steps)
            ny = y0 + round((y - y0) * i / steps)
            if (nx, ny) != (self.px, self.py):
                self.hid.move(nx - self.px, ny - self.py)
                self.px, self.py = nx, ny

    def point(self, a, key="target"):
        t = a[key]
        if isinstance(t, str):
            t = {"target": t}
        if "x" in t:
            return t["x"], t["y"]
        layout = self.apps.layout(self.session)
        if t["target"] not in layout:
            raise OracleError("no element %r in the layout the page reported" % t["target"])
        r = layout[t["target"]]
        fx, fy = t.get("at", a.get("at", [0.5, 0.5]) if key == "target" else [0.5, 0.5])
        return r["x"] + math.floor(r["w"] * fx), r["y"] + math.floor(r["h"] * fy)

    # ---- what the page saw

    def count(self, kind):
        return sum(1 for e in self.apps.events(self.session) if e["k"] == kind)

    def expect_events(self, kind, n, timeout=5.0, what="", instead=None):
        """The page must have seen n more trusted events of this kind than before (events of
        kind `instead` count as well: a native drag ends with dragend, not mouseup)."""
        kinds = (kind,) + ((instead,) if instead else ())
        seen = lambda: sum(self.count(k) - self.counts.get(k, 0) for k in kinds)
        deadline = time.time() + timeout
        while seen() < n:
            if time.time() > deadline:
                raise OracleError("input lost: the page saw %d of %d expected %s events%s" % (
                    seen(), n, kind, " (%s)" % what if what else ""))
            time.sleep(0.01)

    def wheel_sum(self):
        return sum(e["dy"] for e in self.apps.events(self.session) if e["k"] == "wheel")

    def snapshot_counts(self):
        ev = self.apps.events(self.session)
        self.counts = {}
        for e in ev:
            self.counts[e["k"]] = self.counts.get(e["k"], 0) + 1

    def settle(self, quiet=0.12, timeout=1.5):
        """Wait until the page has stopped reporting new events."""
        deadline = time.time() + timeout
        last, since = None, time.time()
        while time.time() < deadline:
            # (a held key repeats 30 times a second for as long as it is held)
            cur = sum(1 for e in self.apps.events(self.session) if not e.get("r"))
            if cur != last:
                last, since = cur, time.time()
            elif time.time() - since >= quiet:
                return
            time.sleep(0.02)

    # ---- actions (the vocabulary of tests/scenarios.json)

    def act(self, a):
        op = a["op"]
        self.snapshot_counts()
        if op in ("click", "dblclick", "rightclick"):
            self.move_to(*self.point(a))
            button = "right" if op == "rightclick" else "left"
            n = 2 if op == "dblclick" else 1
            self.hid.click(button, count=n)
            self.expect_events("mouseup", n, what=op)
        elif op == "move":
            self.move_to(*self.point(a), steps=a.get("steps", 4))
        elif op == "mousedown":
            self.move_to(*self.point(a))
            self.hid.button(a.get("button", "left"), True)
            self.expect_events("mousedown", 1, what=op)
        elif op == "mouseup":
            self.move_to(*self.point(a))
            self.hid.button(a.get("button", "left"), False)
            self.expect_events("mouseup", 1, what=op, instead="dragend")
        elif op == "drag":
            p0, p1 = self.point(a, "from"), self.point(a, "to")
            self.move_to(*p0)
            self.hid.button("left", True)
            self.expect_events("mousedown", 1, what="drag start")
            self.move_to(*p1, steps=a.get("steps", 8))
            self.hid.button("left", False)
            self.expect_events("mouseup", 1, what="drag end", instead="dragend")
        elif op == "type":
            if self.cps:
                self.hid.cmd("cps %d" % self.cps)
            self.hid.type(a["text"])
            self.expect_events("keyup", len(a["text"]), timeout=5 + len(a["text"]) * 0.2, what="type %r" % a["text"])
        elif op == "key":
            for _ in range(a.get("count", 1)):
                self.hid.tap(a["key"])
            self.expect_events("keyup", a.get("count", 1), what="key %s" % a["key"])
        elif op == "chord":
            n = a.get("count", 1)
            for _ in range(n):
                self.hid.chord(a["keys"])
            self.expect_events("keyup", n * len(a["keys"].split("+")), what="chord %s" % a["keys"])
        elif op == "keydown":
            self.hid.key_down(a["key"])
            self.expect_events("keydown", 1, what=op)
        elif op == "keyup":
            self.hid.key_up(a["key"])
            self.expect_events("keyup", 1, what=op)
        elif op == "wheel":
            self.move_to(*self.point(a))
            dy = a["dy"]
            before = self.wheel_sum()
            self.hid.wheel(-dy)        # REL_WHEEL: + is away from the user = scroll up
            # (mouse.folk may merge queued detents into one report, so the page can get fewer
            # wheel events with larger deltas: the scrolled distance is what must arrive)
            deadline = time.time() + 5
            while self.wheel_sum() - before != 100 * dy:
                if time.time() > deadline:
                    raise OracleError("input lost: the wheel turned %d detent(s), the page saw deltaY %+d" % (
                        dy, self.wheel_sum() - before))
                time.sleep(0.01)
        elif op == "wait":
            # scenario time: counted from the end of the previous action's input
            time.sleep(max(0.0, self.t_input + a["ms"] / 1000.0 - time.time()))
            self.t_input = time.time()
            return
        elif op == "expect":
            try:
                self.apps.wait_state(self.session, lambda s: subset(a["state"], s) is None, timeout=a.get("timeout", 5))
            except TimeoutError:
                raise OracleError("expect: " + subset(a["state"], self.apps.state(self.session)))
            return
        else:
            raise ValueError("unknown op %r" % op)
        self.t_input = time.time()
        self.settle()

    def run(self, actions, on_step=None):
        for i, a in enumerate(actions):
            try:
                self.act(a)
            except OracleError as e:
                raise OracleError("action %d %s: %s" % (i, json.dumps(a), e)) from None
            if on_step:
                on_step(i, a)

    # ---- oracles

    def check_state(self, expect, timeout=5):
        try:
            self.apps.wait_state(self.session, lambda s: subset(expect, s) is None, timeout=timeout)
        except TimeoutError:
            raise OracleError("final state: " + subset(expect, self.apps.state(self.session)))

    def check_log(self, patterns):
        missing = match_log(patterns, self.apps.events(self.session))
        if missing is not None:
            raise OracleError("event log: no match (in order) for %s" % json.dumps(missing))

    def check_strip(self, timeout=4):
        """The state hash the page shows in its status strip, read from the projected frame,
        must be the hash of the state the page reported to the app server."""
        x, y, w, h = self.page
        deadline = time.time() + timeout
        while True:
            frame = self.folk.frame()
            d = self.apps.dump(self.session)
            try:
                strip = decode_strip(frame, x0=x, y0=y + 616, scale=1.0)
                problem = None if strip["hash"] == d["hash"] and strip["app"] == d["app"] else \
                    "the projected frame shows %s hash %06x, the page reported %s hash %06x" % (
                        strip["app"], strip["hash"], d["app"], d["hash"] or 0)
            except ValueError as e:
                strip, problem = None, str(e)
            if problem is None:
                return strip, frame
            if time.time() > deadline:
                frame.save(os.path.join(self.out, "strip-mismatch.png"))
                # who is behind: Folk's picture, or the page's own strip / report?
                try:
                    from PIL import Image
                    shot = os.path.join(self.out, "strip-mismatch-chromium.png")
                    self.browser("browserScreenshot", shot)
                    own = "%06x" % decode_strip(Image.open(shot))["hash"]
                except Exception as e:
                    own = "unreadable (%s)" % e
                problem += "; Chromium's own screenshot shows hash %s; the page's live hash is %06x" % (
                    own, self.js("window.__hash()"))
                raise OracleError("strip: " + problem)
            time.sleep(0.1)

    def check_pointer(self, timeout=3):
        """Where Folk says the pointer is and where the page last saw the mouse must both be
        the sum of the mouse's reports."""
        want = (self.px, self.py)
        try:
            self.folk.wait_for(lambda: (lambda p: p is not None and p[:2] == want)(self.pointer_statement()), timeout=timeout)
        except TimeoutError:
            raise OracleError("pointer: mouse reports sum to %s, Folk has it at %s" % (want, self.pointer_statement()))
        seen = self.js("window.__pointer ? window.__pointer() : null")
        if seen and "x" in seen and seen["x"] is not None and (seen["x"], seen["y"]) != want:
            raise OracleError("pointer: mouse reports sum to %s, the page saw it at %s" % (want, seen))

    def check_pixels(self, name="pixels", tolerance=28, max_bad=0.003, timeout=5):
        """Folk's projected picture of the page must be Chromium's own screenshot plus the mouse
        cursor at the pointer, and nothing else.

        The picture reaches Folk as JPEG (4:2:0), which rings around sharp edges and smears
        saturated colours by a pixel, so the comparison is between 4x4 block means: anything
        that is really wrong (a stale or shifted frame, wrong colours, a missing region) moves
        whole blocks; coding noise does not."""
        import numpy as np
        from PIL import Image
        x, y, w, h = self.page
        shot_path = os.path.join(self.out, name + "-chromium.png")
        deadline = time.time() + timeout
        while True:
            self.browser("browserScreenshot", shot_path)
            frame = self.folk.frame().convert("RGB")
            shot = np.asarray(Image.open(shot_path).convert("RGB")).astype(int)
            mine = np.asarray(frame.crop((x, y, x + w, y + h))).astype(int)
            if shot.shape != mine.shape:
                raise OracleError("pixels: Chromium's screenshot is %s, the page on the display is %s" % (shot.shape, mine.shape))
            raw = np.abs(shot - mine).max(axis=2)
            cx0, cy0 = max(0, self.px), max(0, self.py)
            cx1, cy1 = min(w, self.px + CURSOR_W), min(h, self.py + CURSOR_H)
            cursor = raw[cy0:cy1, cx0:cx1].copy()
            # where Folk draws on top of the page: the cursor, and the keyboard page's whisker
            wx0, wy0, wx1, wy1 = self.whisker
            for (a0, b0, a1, b1) in ((cx0, cy0, cx1, cy1), (wx0, wy0, wx1, wy1)):
                mine[max(0, b0):b1, max(0, a0):a1] = shot[max(0, b0):b1, max(0, a0):a1]
            hh, ww = h - h % 4, w - w % 4
            blocks = lambda im: im[:hh, :ww].reshape(hh // 4, 4, ww // 4, 4, 3).mean(axis=(1, 3))
            diff = np.abs(blocks(shot) - blocks(mine)).max(axis=2)
            bad = float((diff > tolerance).mean())
            # the arrow has a black outline and a white fill: over any page it changes pixels
            cursor_seen = cursor.size == 0 or int((cursor > 64).sum()) >= 12
            problem = None
            if bad > max_bad:
                ys, xs = np.nonzero(diff > tolerance)
                problem = "%.2f%% of the page differs from Chromium's screenshot (bounding box x %d..%d, y %d..%d)" % (
                    bad * 100, xs.min() * 4, xs.max() * 4 + 3, ys.min() * 4, ys.max() * 4 + 3)
            elif not cursor_seen:
                problem = "no mouse cursor drawn at the pointer (%d, %d)" % (self.px, self.py)
            if problem is None:
                return {"bad": bad, "mean": float(raw.mean()), "worstBlock": float(diff.max()),
                        "cursorPixels": int((cursor > 64).sum())}
            if time.time() > deadline:
                frame.save(os.path.join(self.out, name + "-folk.png"))
                Image.fromarray(np.clip(raw * 4, 0, 255).astype("uint8")).save(os.path.join(self.out, name + "-diff.png"))
                raise OracleError("pixels: " + problem)
            time.sleep(0.15)

    def check_input(self):
        """Every key press and release hidemu emitted must have reached the page, in order."""
        names = {"LEFTSHIFT": "ShiftLeft", "RIGHTSHIFT": "ShiftRight", "LEFTCTRL": "ControlLeft",
                 "RIGHTCTRL": "ControlRight", "LEFTALT": "AltLeft", "RIGHTALT": "AltRight"}
        sent = [(c, v) for (_t, c, v) in self.hid.key_events() if v in (0, 1)]
        return sent, names

    def check_health(self):
        errs = self.folk.errors()
        if errs:
            raise OracleError("Folk programs have errors: %s" % errs[:3])
        st = self.stats()
        if st.get("state") != "complete" and st.get("ready") != "1":
            raise OracleError("browser is not healthy: %s" % st)
        return st

    # ---- sound

    def record(self, name="audio"):
        self.wav = os.path.join(self.out, name + ".wav")
        subprocess.run([os.path.join(SIM, "audio", "sink.sh"), "record", self._sink_dir, self.wav],
                       check=True, capture_output=True, text=True)
        return self.wav

    def stop_record(self):
        subprocess.run([os.path.join(SIM, "audio", "sink.sh"), "stop-record", self._sink_dir],
                       check=True, capture_output=True, text=True)
        import analyze
        return analyze.load(self.wav)
