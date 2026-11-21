#!/usr/bin/env python3
"""folksim.py -- drive a headless Folk from outside (tests, fuzzers, oracles).

Python 3 stdlib + numpy + pillow only.

    from folksim import FolkSim, HidEmu
    with FolkSim(programs=["test/sim/programs/sim-setup.folk"]) as folk:
        folk.eval("expr {1 + 2}")                         # -> "3"
        folk.hold("p1", "Wish $this is outlined white")   # a held program
        folk.wait_for("/p/ is outlined /c/")              # -> {"p": ..., "c": "white"}
        folk.frame().save("frame.png")                    # what the projector shows

Wire format of the control channel
----------------------------------
Folk's web server (builtin-programs/web/web.folk, lib/ws.tcl) evaluates every
WebSocket text message on ws://127.0.0.1:<port>/ws as a Tcl script on the web
thread, inside `WsConnection onMsgRecv`, where `$chan`, `$ctx` (the wslay
context) and `$wsLib` are in scope; nothing is sent back unless the script
calls `$wsLib wsEmitMsg $ctx <text>`. lib/folk.js builds everything on that:
`run` sends raw Tcl, `send`/`watch`/`watchCollected`/`subscribe` send an
`Assert! when websocket $chan is connected {...}` whose body emits
`[list <channel-prefix> <payload>]`, and `hold` sends
`Hold! -noncapturing -on <on> -key <key> <program>`.

FolkSim.eval uses the same mechanism with its own framing. Request (one text
frame; <code> is quoted as one Tcl word):

    set __c [catch {apply [list {} <code>]} __v __o]
    $wsLib wsEmitMsg $ctx [list folksim <id> $__c $__v <errorinfo or {}>]

Reply (one text frame, a Tcl list): `folksim <id> <code> <value> <errorinfo>`;
<code> is Tcl's return code (0 ok, 1 error). The code runs in a fresh proc
scope on the web thread: `$this` is not set (so Hold! needs -on), locals do
not persist (use ::globals), and the web server serves nothing else while it
runs, so keep it short. If the socket cannot be used, the same script (ending
in `list folksim ...` instead of the emit) is sent as the body of an HTTP POST,
which web.folk evaluates and answers with the result (transport="post").

Everything else is plain HTTP: GET /display-frame (PNG of the next presented
frame of the headless display).
"""

import base64
import hashlib
import io
import os
import re
import shutil
import signal
import socket
import struct
import subprocess
import sys
import tempfile
import threading
import time

REPO = os.path.abspath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))

# Programs that cannot work in a container without sound devices / libghostty /
# sclang; their errors are not interesting for a simulation.
DEFAULT_IGNORE = ("audio.folk", "terminal.folk", "music.folk")


# --------------------------------------------------------------------------
# Tcl data <-> Python

class TclError(Exception):
    """A Tcl error raised by code evaluated in Folk."""

    def __init__(self, message, info=""):
        super().__init__(message)
        self.message = message
        self.info = info


_BARE = re.compile(r"^[A-Za-z0-9_./:@%+,=!?*^~<>|&'()-]+$")
_ESC = {" ": "\\ ", "$": "\\$", '"': '\\"', "[": "\\[", "]": "\\]", "{": "\\{", "}": "\\}",
        ";": "\\;", "\\": "\\\\", "\n": "\\n", "\r": "\\r", "\t": "\\t", "\f": "\\f",
        "\v": "\\v", "#": "\\#"}


def tcl_quote(s):
    """Quote a string as exactly one Tcl word (usable in a command or a list)."""
    s = str(s)
    if s == "":
        return "{}"
    if _BARE.match(s):
        return s
    if "\\" not in s:
        depth = 0
        for ch in s:
            if ch == "{":
                depth += 1
            elif ch == "}":
                depth -= 1
                if depth < 0:
                    break
        if depth == 0:
            return "{" + s + "}"
    return "".join(_ESC.get(ch, ch) for ch in s)


def tcl_list(items):
    return " ".join(tcl_quote(i) for i in items)


def _unescape(s, i):
    """s[i] is a backslash; returns (char(s), next index)."""
    n = len(s)
    if i + 1 >= n:
        return "\\", i + 1
    c = s[i + 1]
    simple = {"a": "\a", "b": "\b", "f": "\f", "n": "\n", "r": "\r", "t": "\t", "v": "\v"}
    if c in simple:
        return simple[c], i + 2
    if c == "x":
        m = re.compile(r"[0-9a-fA-F]{1,2}").match(s, i + 2)
        if m:
            return chr(int(m.group(0), 16)), m.end()
    if c in "uU":
        m = re.compile(r"\{([0-9a-fA-F]{1,6})\}|[0-9a-fA-F]{1,%d}" % (4 if c == "u" else 8)).match(s, i + 2)
        if m:
            return chr(int(m.group(1) or m.group(0), 16)), m.end()
    if c in "01234567":
        m = re.compile(r"[0-7]{1,3}").match(s, i + 1)
        return chr(int(m.group(0), 8)), m.end()
    if c == "\n":
        j = i + 2
        while j < n and s[j] in " \t":
            j += 1
        return " ", j
    return c, i + 2


def tcl_split(s):
    """Split a Tcl list into its elements (strings)."""
    out, i, n = [], 0, len(s)
    ws = " \t\n\r\f\v"
    while True:
        while i < n and s[i] in ws:
            i += 1
        if i >= n:
            return out
        if s[i] == "{":
            depth, j = 1, i + 1
            while j < n:
                ch = s[j]
                if ch == "\\":
                    j += 2
                    continue
                if ch == "{":
                    depth += 1
                elif ch == "}":
                    depth -= 1
                    if depth == 0:
                        break
                j += 1
            out.append(s[i + 1:j])
            i = j + 1
        elif s[i] == '"':
            j, buf = i + 1, []
            while j < n and s[j] != '"':
                if s[j] == "\\":
                    ch, j = _unescape(s, j)
                    buf.append(ch)
                else:
                    buf.append(s[j])
                    j += 1
            out.append("".join(buf))
            i = j + 1
        else:
            j, buf = i, []
            while j < n and s[j] not in ws:
                if s[j] == "\\":
                    ch, j = _unescape(s, j)
                    buf.append(ch)
                else:
                    buf.append(s[j])
                    j += 1
            out.append("".join(buf))
            i = j


def tcl_dict(s):
    """Parse a Tcl dict (flat key/value list) into a Python dict of strings."""
    items = tcl_split(s)
    return dict(zip(items[0::2], items[1::2]))


# --------------------------------------------------------------------------
# Minimal RFC 6455 client (text messages, client-side masking, ping/pong)

class WebSocket:
    def __init__(self, host, port, path="/ws", timeout=10):
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        key = base64.b64encode(os.urandom(16)).decode()
        self.sock.sendall((
            "GET %s HTTP/1.1\r\nHost: %s:%d\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n"
            "Sec-WebSocket-Key: %s\r\nSec-WebSocket-Version: 13\r\n\r\n" % (path, host, port, key)).encode())
        self.buf = b""
        while b"\r\n\r\n" not in self.buf:
            chunk = self.sock.recv(4096)
            if not chunk:
                raise ConnectionError("websocket: connection closed during handshake")
            self.buf += chunk
        head, self.buf = self.buf.split(b"\r\n\r\n", 1)
        lines = head.decode("latin-1").split("\r\n")
        if " 101 " not in lines[0] + " ":
            raise ConnectionError("websocket: handshake refused: " + lines[0])
        accept = base64.b64encode(hashlib.sha1(
            (key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").encode()).digest()).decode()
        headers = {l.split(":", 1)[0].strip().lower(): l.split(":", 1)[1].strip() for l in lines[1:] if ":" in l}
        if headers.get("sec-websocket-accept") != accept:
            raise ConnectionError("websocket: bad Sec-WebSocket-Accept")
        self._fragments = []

    def _send_frame(self, opcode, payload):
        mask = os.urandom(4)
        n = len(payload)
        head = bytes([0x80 | opcode])
        if n < 126:
            head += bytes([0x80 | n])
        elif n < 65536:
            head += bytes([0x80 | 126]) + struct.pack(">H", n)
        else:
            head += bytes([0x80 | 127]) + struct.pack(">Q", n)
        # mask with a repeated 4-byte key
        import numpy as np
        data = np.frombuffer(payload, dtype=np.uint8) ^ np.resize(np.frombuffer(mask, dtype=np.uint8), n) \
            if n else np.zeros(0, dtype=np.uint8)
        self.sock.sendall(head + mask + data.tobytes())

    def send(self, text):
        self._send_frame(0x1, text.encode("utf-8"))

    def _read(self, n, deadline):
        while len(self.buf) < n:
            left = deadline - time.monotonic()
            if left <= 0:
                raise TimeoutError("websocket: timed out")
            self.sock.settimeout(left)
            try:
                chunk = self.sock.recv(65536)
            except socket.timeout:
                raise TimeoutError("websocket: timed out")
            if not chunk:
                raise ConnectionError("websocket: connection closed")
            self.buf += chunk
        out, self.buf = self.buf[:n], self.buf[n:]
        return out

    def recv(self, timeout=10):
        """Next complete text/binary message as str. Raises TimeoutError / ConnectionError.
        (A timeout in the middle of a frame leaves the stream unusable: reconnect.)"""
        deadline = time.monotonic() + timeout
        while True:
            b0, b1 = self._read(2, deadline)
            fin, opcode, n = b0 & 0x80, b0 & 0x0F, b1 & 0x7F
            if n == 126:
                n = struct.unpack(">H", self._read(2, deadline))[0]
            elif n == 127:
                n = struct.unpack(">Q", self._read(8, deadline))[0]
            mask = self._read(4, deadline) if b1 & 0x80 else None
            payload = self._read(n, deadline)
            if mask:
                payload = bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
            if opcode == 0x9:
                self._send_frame(0xA, payload)
            elif opcode == 0x8:
                raise ConnectionError("websocket: closed by peer")
            elif opcode in (0x0, 0x1, 0x2):
                self._fragments.append(payload)
                if fin:
                    data, self._fragments = b"".join(self._fragments), []
                    return data.decode("utf-8", "replace")

    def close(self):
        try:
            self._send_frame(0x8, b"")
        except OSError:
            pass
        try:
            self.sock.close()
        except OSError:
            pass


# --------------------------------------------------------------------------
# Process hygiene

def _session_pids(sid):
    """PIDs of all live (non-zombie) processes whose session or process group is `sid`."""
    out = []
    for name in os.listdir("/proc"):
        if not name.isdigit():
            continue
        try:
            with open("/proc/%s/stat" % name) as f:
                stat = f.read()
        except OSError:
            continue
        fields = stat[stat.rindex(")") + 2:].split()
        state, pgrp, session = fields[0], int(fields[2]), int(fields[3])
        if state != "Z" and (session == sid or pgrp == sid):
            out.append(int(name))
    return out


def _kill_session(sid, grace=3.0):
    """SIGTERM, then SIGKILL, everything in session/process group `sid`. Returns survivors."""
    for sig, wait in ((signal.SIGTERM, grace), (signal.SIGKILL, 3.0)):
        pids = _session_pids(sid)
        if not pids:
            return []
        for pid in pids:
            try:
                os.kill(pid, sig)
            except OSError:
                pass
        deadline = time.monotonic() + wait
        while time.monotonic() < deadline and _session_pids(sid):
            time.sleep(0.05)
    return _session_pids(sid)


_REAPER = r"""
import os, signal, sys, time
sid = int(sys.argv[1])
if sys.stdin.readline().strip() == "ok": sys.exit(0)   # the owner cleaned up itself
def pids():
    out = []
    for name in os.listdir("/proc"):
        if not name.isdigit(): continue
        try: stat = open("/proc/%s/stat" % name).read()
        except OSError: continue
        f = stat[stat.rindex(")") + 2:].split()
        if f[0] != "Z" and (int(f[3]) == sid or int(f[2]) == sid): out.append(int(name))
    return out
for sig, wait in ((signal.SIGTERM, 3), (signal.SIGKILL, 0)):
    for p in pids():
        try: os.kill(p, sig)
        except OSError: pass
    t = time.time() + wait
    while time.time() < t and pids(): time.sleep(0.1)
"""


class _Reaper:
    """A sidecar that kills session `sid` if this Python process dies without cleaning up
    (it notices through EOF on a pipe, so it also works after SIGKILL of the harness)."""

    def __init__(self, sid):
        self.proc = subprocess.Popen([sys.executable, "-c", _REAPER, str(sid)], stdin=subprocess.PIPE,
                                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                                     start_new_session=True, close_fds=True)

    def dismiss(self):
        try:
            self.proc.stdin.write(b"ok\n")
            self.proc.stdin.close()
            self.proc.wait(timeout=5)
        except (OSError, subprocess.TimeoutExpired, ValueError):
            pass


def _truthy(v):
    try:
        return bool(v)
    except ValueError:   # e.g. a numpy array
        return v is not None


def _free_port():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


# --------------------------------------------------------------------------
# FolkSim

class FolkSim:
    """One headless Folk process with an isolated HOME, driven over its web interface."""

    def __init__(self, repo=None, display="1280x720", port=None, programs=(), env=None, home=None,
                 boot_timeout=180, keep=False, ignore=DEFAULT_IGNORE, transport="ws"):
        self.repo = os.path.abspath(repo or REPO)
        self.display = display
        self.port = port
        self.programs = list(programs)
        self.env = dict(env or {})
        self.home = home
        self.boot_timeout = boot_timeout
        self.keep = keep
        self.ignore = tuple(ignore)
        self.transport = transport
        self.proc = None
        self.pid = None
        self.boot_seconds = None
        self.survivors = []
        self._ws = None
        self._lock = threading.RLock()
        self._next_id = 0
        self._own_home = False
        self._reaper = None
        self._out = None

    # ---- lifecycle

    def start(self):
        if self.proc is not None:
            raise RuntimeError("FolkSim already started")
        if not os.access(os.path.join(self.repo, "folk"), os.X_OK):
            raise RuntimeError("no ./folk binary in %s (run make)" % self.repo)
        if self.home is None:
            self.home = tempfile.mkdtemp(prefix="folksim-home-")
            self._own_home = True
        self.home = os.path.abspath(self.home)
        progdir = os.path.join(self.home, "folk-data", "local-program")
        os.makedirs(progdir, exist_ok=True)
        for p in self.programs:
            src = p if os.path.isabs(p) else os.path.join(self.repo, p)
            if not os.path.exists(src):
                src = os.path.abspath(p)
            shutil.copy(src, progdir)
        if self.port is None:
            self.port = _free_port()
        env = dict(os.environ)
        env.update({"HOME": self.home, "FOLK_WEB_PORT": str(self.port),
                    "FOLK_PID_FILE": os.path.join(self.home, "folk.pid"),
                    "FOLK_HEADLESS": self.display, "TERM": "dumb"})
        env.update(self.env)
        self.out_path = os.path.join(self.home, "folk.out")
        self._out = open(self.out_path, "ab")
        t0 = time.monotonic()
        # Own session (hence own process group): everything Folk spawns can be found and killed.
        self.proc = subprocess.Popen([os.path.join(self.repo, "folk")], cwd=self.repo, env=env,
                                     stdin=subprocess.DEVNULL, stdout=self._out, stderr=subprocess.STDOUT,
                                     start_new_session=True, close_fds=True)
        self.pid = self.proc.pid
        self._reaper = _Reaper(self.pid)
        try:
            self._wait_ready(t0)
        except BaseException:
            tail = self.output()[-3000:]
            self.stop(keep=self.keep)
            sys.stderr.write("folksim: boot failed; output tail:\n%s\n" % tail)
            raise
        self.boot_seconds = time.monotonic() - t0
        return self

    def _wait_ready(self, t0):
        deadline = t0 + self.boot_timeout
        name = "headless"
        while True:
            if self.proc.poll() is not None:
                raise RuntimeError("folk exited with %s during boot" % self.proc.returncode)
            if time.monotonic() > deadline:
                raise TimeoutError("folk did not become ready in %.0f s" % self.boot_timeout)
            try:
                if self.query("display %s has width /w/ height /h/" % name, timeout=5):
                    return
            except (OSError, TimeoutError, TclError):
                self._drop_ws()
            time.sleep(0.25)

    def stop(self, keep=None):
        """Graceful Exit!, then kill the whole session. Returns the list of surviving PIDs
        (always empty unless something is unkillable)."""
        keep = self.keep if keep is None else keep
        if self.proc is None:
            return []
        if self.proc.poll() is None:
            try:
                self.run("Exit! 0")
            except Exception:
                pass
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                pass
        self._drop_ws()
        self.survivors = _kill_session(self.pid)
        try:
            self.proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            pass
        if self._reaper:
            self._reaper.dismiss()
            self._reaper = None
        if self._out:
            self._out.close()
            self._out = None
        if not keep:
            shutil.rmtree("/var/tmp/folk-%d" % self.pid, ignore_errors=True)
            if self._own_home:
                shutil.rmtree(self.home, ignore_errors=True)
        self.proc = None
        return self.survivors

    def __enter__(self):
        return self.start()

    def __exit__(self, exc_type, exc, tb):
        if exc_type is not None and not self.keep and self.proc is not None:
            # keep the evidence of a failed run
            sys.stderr.write("folksim: failed; keeping %s and /var/tmp/folk-%s\n" % (self.home, self.pid))
            self.stop(keep=True)
        else:
            self.stop()
        return False

    # ---- control channel

    def _drop_ws(self):
        if self._ws is not None:
            self._ws.close()
            self._ws = None

    def _script(self, code, ident, emit):
        tail = "[list folksim %d $__c $__v [expr {$__c == 1 ? [dict getdef $__o -errorinfo {}] : {}}]]" % ident
        return "set __c [catch {apply [list {} %s]} __v __o]; %s" % (
            tcl_quote(code), ("$wsLib wsEmitMsg $ctx " + tail) if emit else tail[1:-1])

    def eval(self, code, timeout=30):
        """Evaluate Tcl in Folk (web thread, fresh proc scope); returns the result as str.
        Raises TclError on a Tcl error, TimeoutError if no reply arrives."""
        with self._lock:
            self._next_id += 1
            ident = self._next_id
            if self.transport == "post":
                reply = self._http("POST", "/", self._script(code, ident, False).encode(), timeout)[1].decode("utf-8", "replace")
                parts = tcl_split(reply)
                if len(parts) != 5 or parts[0] != "folksim":
                    raise TclError(reply)
            else:
                try:
                    if self._ws is None:
                        self._ws = WebSocket("127.0.0.1", self.port, timeout=min(timeout, 10))
                    self._ws.send(self._script(code, ident, True))
                    deadline = time.monotonic() + timeout
                    while True:
                        parts = tcl_split(self._ws.recv(max(0.01, deadline - time.monotonic())))
                        if len(parts) == 5 and parts[0] == "folksim" and parts[1] == str(ident):
                            break
                except (OSError, TimeoutError):
                    self._drop_ws()
                    raise
            status, value, info = int(parts[2]), parts[3], parts[4]
            if status == 1:
                raise TclError(value, info)
            return value

    def run(self, code):
        """Evaluate Tcl in Folk without waiting for (or getting) a result."""
        with self._lock:
            if self._ws is None:
                self._ws = WebSocket("127.0.0.1", self.port, timeout=5)
            self._ws.send(code)

    def query(self, pattern, timeout=30, refs=False):
        """`Query!` the statement database. `pattern` is Tcl words with /wildcards/, e.g.
        "/p/ has error /e/ with info /i/". Returns one dict of bindings (strings) per match."""
        rows = [tcl_dict(r) for r in tcl_split(self.eval("Query! " + pattern, timeout=timeout))]
        if not refs:
            for r in rows:
                r.pop("__ref", None)
        return rows

    def wait_for(self, what, timeout=30, poll=0.1):
        """Poll until `what` holds: a query pattern (returns the first match) or a callable
        (returns its first truthy result). TimeoutError (listing recent errors) otherwise."""
        deadline = time.monotonic() + timeout
        last = None
        while True:
            try:
                res = what() if callable(what) else self.query(what)
                last = None
            except (TclError, OSError, TimeoutError, AssertionError) as e:
                res, last = None, e
            if _truthy(res):
                return res if callable(what) else res[0]
            if time.monotonic() > deadline:
                try:
                    errs = self.errors()[-5:]
                except Exception as e:
                    errs = ["(errors() failed: %s)" % e]
                raise TimeoutError("wait_for(%s) timed out after %.1f s%s; recent errors: %s" % (
                    getattr(what, "__name__", what), timeout, " (last exception: %r)" % last if last else "", errs))
            time.sleep(poll)

    def hold(self, key, code, this=None):
        """Run `code` as a held program (like FolkWS.hold): `Hold! -on folksim -key <key>` of a
        `when` whose `$this` is `this` (default "folksim:<key>"). Holding the same key again
        replaces the previous program (and everything it claimed/wished)."""
        this = this or "folksim:%s" % key
        self.eval("Hold! -on folksim -key %s when %s with environment [list [list this %s]]; list" % (
            tcl_quote(key), tcl_quote(code), tcl_quote(this)))
        return this

    def hold_statement(self, key, statement):
        """Hold a plain statement, e.g. hold_statement("p1", "Wish the simulated table has page ...")."""
        self.eval("Hold! -on folksim -key %s %s; list" % (tcl_quote(key), statement))

    def unhold(self, key):
        self.eval("Hold! -on folksim -key %s {}; list" % tcl_quote(key))

    # ---- observation

    def _http(self, method, path, body=None, timeout=30):
        s = socket.create_connection(("127.0.0.1", self.port), timeout=timeout)
        try:
            req = "%s %s HTTP/1.1\r\nHost: 127.0.0.1:%d\r\nConnection: close\r\n" % (method, path, self.port)
            if body is not None:
                req += "Content-Length: %d\r\n" % len(body)
            s.sendall(req.encode() + b"\r\n" + (body or b""))
            data = b""
            while True:
                chunk = s.recv(1 << 16)
                if not chunk:
                    break
                data += chunk
        finally:
            s.close()
        # web.folk separates headers with \n or \r\n depending on the route
        cut = min((i for i in (data.find(b"\r\n\r\n"), data.find(b"\n\n")) if i >= 0), default=-1)
        if cut < 0:
            raise OSError("malformed HTTP response from Folk: %r" % data[:80])
        sep = 4 if data[cut:cut + 4] == b"\r\n\r\n" else 2
        return data[:cut].decode("latin-1"), data[cut + sep:]

    def frame(self, timeout=30):
        """The next frame presented on the headless display, as an RGB PIL.Image."""
        from PIL import Image
        with self._lock:
            head, body = self._http("GET", "/display-frame", timeout=timeout)
        if " 200 " not in head.split("\n", 1)[0] + " ":
            raise RuntimeError("GET /display-frame failed: %s %s" % (head.split("\n", 1)[0], body[:300]))
        return Image.open(io.BytesIO(body)).convert("RGB")

    def frame_stable(self, n=2, timeout=20, mask=()):
        """Fetch frames until `n` consecutive ones are identical (ignoring the `mask`
        rectangles (x, y, w, h)); returns the last one."""
        import numpy as np
        deadline = time.monotonic() + timeout
        prev, same, im = None, 1, None
        while True:
            im = self.frame()
            a = np.asarray(im).copy()
            for (x, y, w, h) in mask:
                a[y:y + h, x:x + w] = 0
            same = same + 1 if prev is not None and np.array_equal(a, prev) else 1
            if same >= n:
                return im
            if time.monotonic() > deadline:
                raise TimeoutError("display did not settle: no %d identical frames in %.0f s" % (n, timeout))
            prev = a

    def all_errors(self):
        return [(r["p"], r["e"]) for r in self.query("/p/ has error /e/ with info /i/")]

    def errors(self):
        """(program, message) for every `<program> has error ...` statement, minus the ignore list
        (matched against the end of the program name)."""
        return [(p, e) for (p, e) in self.all_errors() if not any(p.endswith(i) for i in self.ignore)]

    def logs(self, program, stream=None):
        """What `program` printed: /var/tmp/folk-<pid>/<program with / -> __>.stdout + .stderr."""
        base = "/var/tmp/folk-%d/%s" % (self.pid, program.replace("/", "__"))
        out = ""
        for ext in ((stream,) if stream else ("stdout", "stderr")):
            try:
                with open(base + "." + ext, errors="replace") as f:
                    out += f.read()
            except OSError:
                pass
        return out

    def output(self):
        """Folk's own stdout/stderr."""
        try:
            with open(self.out_path, errors="replace") as f:
                return f.read()
        except OSError:
            return ""


# --------------------------------------------------------------------------
# HidEmu

class HidEmu:
    """Emulated USB keyboard + mouse (test/sim/hidemu) writing evdev events to two FIFOs.

    Commands go over hidemu's --ctl unix socket: one line per command, answered with `ok` or
    `err MESSAGE` once the command has been emitted completely (cmd() blocks that long)."""

    def __init__(self, rundir=None, repo=None, start=True, extra_args=()):
        self.repo = os.path.abspath(repo or REPO)
        self._own_dir = rundir is None
        self.rundir = os.path.abspath(rundir or tempfile.mkdtemp(prefix="hidemu-"))
        os.makedirs(self.rundir, exist_ok=True)
        self.kbd_path = os.path.join(self.rundir, "kbd0")
        self.mouse_path = os.path.join(self.rundir, "mouse0")
        self.log_path = os.path.join(self.rundir, "hidemu.log")
        self.ctl_path = os.path.join(self.rundir, "hidemu.sock")
        self._ctl_dir = None
        if len(os.fsencode(self.ctl_path)) > 100:
            # a unix socket's path must fit into sockaddr_un (108 bytes)
            self._ctl_dir = tempfile.mkdtemp(prefix="hidemu-")
            self.ctl_path = os.path.join(self._ctl_dir, "ctl.sock")
        self.extra_args = list(extra_args)
        self.proc = None
        self._sock = None
        self._file = None
        self._reaper = None
        self._lock = threading.Lock()
        if start:
            self.start()

    def build(self):
        d = os.path.join(self.repo, "test", "sim", "hidemu")
        exe = os.path.join(d, "hidemu")
        src = os.path.join(d, "hidemu.c")
        if not os.path.exists(exe) or os.path.getmtime(exe) < os.path.getmtime(src):
            subprocess.run(["make", "-C", d], check=True, stdout=subprocess.DEVNULL)
        return exe

    def start(self):
        exe = self.build()
        for p in (self.kbd_path, self.mouse_path):
            if not os.path.exists(p):
                os.mkfifo(p)
        self.proc = subprocess.Popen([exe, "--kbd", self.kbd_path, "--mouse", self.mouse_path,
                                      "--log", self.log_path, "--ctl", self.ctl_path, "--quiet"] + self.extra_args,
                                     stdin=subprocess.DEVNULL, start_new_session=True, close_fds=True)
        self._reaper = _Reaper(self.proc.pid)
        deadline = time.monotonic() + 10
        while True:
            try:
                self._sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                self._sock.connect(self.ctl_path)
                break
            except OSError:
                self._sock.close()
                if self.proc.poll() is not None or time.monotonic() > deadline:
                    raise RuntimeError("hidemu did not start (exit code %s)" % self.proc.poll())
                time.sleep(0.02)
        self._file = self._sock.makefile("rw", encoding="utf-8", newline="\n")
        return self

    def cmd(self, line, timeout=120):
        """Run one hidemu command; returns when it has been emitted. Raises on `err ...`."""
        if "\n" in line:
            raise ValueError("one command per call")
        with self._lock:
            self._sock.settimeout(timeout)
            self._file.write(line + "\n")
            self._file.flush()
            reply = self._file.readline().strip()
        if reply != "ok":
            raise RuntimeError("hidemu: %r -> %r" % (line, reply or "(connection closed)"))

    # thin helpers over the command language (see hidemu.c)
    def type(self, text, cps=None):
        if cps:
            self.cmd("cps %d" % cps)
        esc = text.replace("\\", "\\\\").replace('"', '\\"').replace("\n", "\\n").replace("\t", "\\t")
        self.cmd('type "%s"' % esc)

    def tap(self, name, hold_ms=None):
        self.cmd("tap %s" % name + (" %d" % hold_ms if hold_ms is not None else ""))

    def chord(self, keys, hold_ms=None):
        self.cmd("chord %s" % keys + (" %d" % hold_ms if hold_ms is not None else ""))

    def key_down(self, name):
        self.cmd("key down %s" % name)

    def key_up(self, name):
        self.cmd("key up %s" % name)

    def move(self, dx, dy, ms=None):
        self.cmd("move %d %d" % (dx, dy) + (" %d" % ms if ms is not None else ""))

    def button(self, name, down):
        self.cmd("button %s %s" % (name, "down" if down else "up"))

    def click(self, name="left", hold_ms=None, count=None):
        self.cmd("click %s" % name + (" %d" % (hold_ms if hold_ms is not None else 20) if (hold_ms is not None or count) else "")
                 + (" %d" % count if count else ""))

    def wheel(self, n):
        self.cmd("wheel %d" % n)

    def sleep(self, ms):
        self.cmd("sleep %d" % ms)

    def mark(self, text):
        self.cmd("mark %s" % text)

    def seed(self, n):
        self.cmd("seed %d" % n)

    def fuzz(self, n, what="all"):
        self.cmd("fuzz %d %s" % (n, what), timeout=600)

    def rate(self, dev, hz):
        self.cmd("rate %s %d" % (dev, hz))

    def release_all(self):
        self.cmd("releaseall")

    def log(self):
        """Ground truth: one dict per log line, in order. Common keys: t (unix seconds), dev
        (kbd|mouse|emu), kind. kind=="report": bytes (list of ints, the raw HID report);
        kind=="event": type, code, value (int; e.g. EV_KEY KEY_A 1; SYN_REPORT ends a frame);
        kind=="cmd": text; others (start, stats, error, blocked, dropped): text."""
        out = []
        try:
            with open(self.log_path, errors="replace") as f:
                lines = f.read().split("\n")
        except OSError:
            return out
        for line in lines:
            f = line.split("\t")
            if len(f) < 3:
                continue
            rec = {"t": float(f[0]), "dev": f[1], "kind": f[2]}
            if f[2] == "report":
                rec["bytes"] = [int(b, 16) for b in f[3].split()]
            elif f[2] == "event" and len(f) >= 6:
                rec["type"], rec["code"], rec["value"] = f[3], f[4], int(f[5], 0)
            else:
                rec["text"] = "\t".join(f[3:])
            out.append(rec)
        return out

    def key_events(self):
        """[(t, KEY_NAME, value)] for the keyboard's EV_KEY events (1 down, 0 up, 2 repeat)."""
        return [(r["t"], r["code"], r["value"]) for r in self.log()
                if r["dev"] == "kbd" and r["kind"] == "event" and r["type"] == "EV_KEY"]

    def close(self):
        """Quit hidemu, remove its socket (and the run directory if it was created here).
        Returns surviving PIDs (always empty unless something is unkillable)."""
        if self.proc is None:
            return []
        try:
            if self.proc.poll() is None and self._file is not None:
                self._sock.settimeout(2)
                self._file.write("quit\n")
                self._file.flush()
                self._file.readline()
        except (OSError, ValueError):
            pass
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        survivors = _kill_session(self.proc.pid, grace=1.0)
        try:
            self.proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        for obj in (self._file, self._sock):
            try:
                obj and obj.close()
            except OSError:
                pass
        if self._reaper:
            self._reaper.dismiss()
            self._reaper = None
        if self._own_dir:
            shutil.rmtree(self.rundir, ignore_errors=True)
        else:
            for p in (self.ctl_path,):
                try:
                    os.unlink(p)
                except OSError:
                    pass
        if self._ctl_dir:
            shutil.rmtree(self._ctl_dir, ignore_errors=True)
        self.proc = None
        return survivors

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()
        return False


# --------------------------------------------------------------------------
# Pixel oracle for the test apps

STRIP_APPS = {1: "events", 2: "paint", 3: "kanban", 4: "editor", 5: "form", 6: "synth"}


def decode_strip(image, x0=0, y0=616, scale=1.0):
    """Decode the status strip of a sim test app (encoding: see apps/common.js) from pixels.

    `image` is a PIL image in which the app's 1024x640 viewport appears axis-aligned with its
    top-left corner at (x0 - 0, y0 - 616*scale) -- i.e. (x0, y0) is the top-left corner of the
    strip -- at `scale` image pixels per CSS pixel. For a plain browser screenshot the defaults
    are right. Returns {"app", "app_id", "count", "hash", "flags", "mouse_down", "key_down",
    "modal"}; raises ValueError if the calibration blocks are not where they should be."""
    import numpy as np
    a = np.asarray(image.convert("RGB")).astype(int)
    r = max(1, int(3 * scale))
    digits = []
    for b in range(21):
        cx, cy = int(round(x0 + (24 * b + 12) * scale)), int(round(y0 + 12 * scale))
        patch = a[max(0, cy - r):cy + r + 1, max(0, cx - r):cx + r + 1].reshape(-1, 3)
        if len(patch) == 0:
            raise ValueError("status strip block %d is outside the image" % b)
        m = patch.mean(axis=0)
        digits.append(4 * (m[0] > 128) + 2 * (m[1] > 128) + 1 * (m[2] > 128))
    digits = [int(d) for d in digits]
    if digits[:5] != [7, 0, 4, 2, 1] or digits[20] != 7:
        raise ValueError("no status strip at (%s, %s) scale %s: blocks read %s" % (x0, y0, scale, digits))

    def number(ds):
        n = 0
        for d in ds:
            n = n * 8 + d
        return n
    app_id, flags = number(digits[5:7]), digits[19]
    return {"app": STRIP_APPS.get(app_id, "?"), "app_id": app_id, "count": number(digits[7:11]),
            "hash": number(digits[11:19]), "flags": flags, "mouse_down": bool(flags & 1),
            "key_down": bool(flags & 2), "modal": bool(flags & 4)}


# --------------------------------------------------------------------------
# Self-test

def selftest(keep=False, verbose=True):
    import numpy as np

    def say(msg):
        if verbose:
            print("selftest: " + msg, flush=True)

    # Tcl quoting round trip (no Folk needed)
    samples = ["", "a", "a b", "{", "}", "a{b", 'q"uote', "back\\slash", "new\nline", "$x [y] ;z", "{bal anced}", "#c"]
    assert tcl_split(tcl_list(samples)) == samples, tcl_split(tcl_list(samples))

    t_start = time.monotonic()
    folk = FolkSim(programs=["test/sim/programs/sim-setup.folk"], keep=keep)
    emu = None
    with folk:
        say("booted in %.1f s (pid %d, port %d)" % (folk.boot_seconds, folk.pid, folk.port))

        # eval: results, errors, quoting through Tcl and back
        assert folk.eval("expr {1+2}") == "3"
        for s in samples:
            assert folk.eval("return %s" % tcl_quote(s)) == s, s
            assert tcl_split(folk.eval("list %s x" % tcl_quote(s))) == [s, "x"], s
        try:
            folk.eval("error boom")
            raise AssertionError("no TclError")
        except TclError as e:
            assert e.message == "boom", e.message
        folk.transport = "post"
        assert folk.eval("expr {6*7}") == "42"
        try:
            folk.eval("error boom2")
            raise AssertionError("no TclError")
        except TclError as e:
            assert e.message == "boom2", e.message
        folk.transport = "ws"
        say("eval ok (ws + post)")

        w, h = (int(v) for v in folk.display.split("@")[0].split("x"))
        d = folk.wait_for("display headless has width /w/ height /h/")
        assert (int(d["w"]), int(d["h"])) == (w, h), d

        # a virtual page (graphics.md 1d) filling a known pixel rect with a known colour
        x0, y0, pw, ph = 200, 120, 320, 240
        this = folk.hold("page", """
            Claim $this has resolved geometry [dict create width %f height %f]
            Wish $this has a canvas with width %d height %d
            When the quad library is /quadLib/ &\\
                 display /disp/ has width /dispW/ height /dispH/ &\\
                 display /disp/ has intrinsics /intr/ {
                set unproject [list apply {{intr px py} {
                    list [expr {($px - [dict get $intr cx]) / [dict get $intr fx]}] \\
                         [expr {($py - [dict get $intr cy]) / [dict get $intr fy]}] 1.0
                }} $intr]
                Claim $this has quad [$quadLib create "display $disp" [list \\
                    [{*}$unproject %d %d] [{*}$unproject %d %d] \\
                    [{*}$unproject %d %d] [{*}$unproject %d %d]]]
            }
            Wish $this is filled with color lime
        """ % (pw / w, ph / w, pw, ph, x0, y0, x0 + pw, y0, x0 + pw, y0 + ph, x0, y0 + ph))
        folk.wait_for("%s has quad /q/" % tcl_quote(this), timeout=60)

        def page_drawn():
            a = np.asarray(folk.frame()).astype(int)
            inside = a[y0 + 2:y0 + ph - 2, x0 + 2:x0 + pw - 2]
            return a if (inside[..., 1] > 200).all() else None

        t0 = time.monotonic()
        a = folk.wait_for(page_drawn, timeout=60, poll=0.05)
        inside = a[y0 + 2:y0 + ph - 2, x0 + 2:x0 + pw - 2].reshape(-1, 3)
        assert (inside == (0, 255, 0)).all(), "page is not uniformly lime: %s" % (inside[0],)
        outside = a.copy()
        outside[y0 - 2:y0 + ph + 2, x0 - 2:x0 + pw + 2] = 0
        assert outside.max() == 0, "pixels outside the page are not black (max %d)" % outside.max()
        say("virtual page drawn at %d,%d %dx%d colour %s, outside black (%.1f s after the hold)" % (
            x0, y0, pw, ph, tuple(int(v) for v in inside[0]), time.monotonic() - t0))
        im = folk.frame_stable(n=2, timeout=20)
        assert im.size == (w, h), im.size

        # replace, then remove the held program: the page must disappear
        folk.unhold("page")
        folk.wait_for(lambda: np.asarray(folk.frame()).max() == 0, timeout=30)
        say("unhold removes the page")

        # emulated keyboard -> unmodified keyboard.folk -> a held subscriber
        emu = HidEmu()
        folk.hold("keys", """
            Claim %s is a keyboard device
            Subscribe: keyboard %s claims key /key/ is /state/ with /...options/ {
                if {$state eq "down" && [dict exists $options printable]} {
                    set ts [dict get $options timestamp]
                    Hold! -on folksim -key [list typed $ts $key] \\
                        Claim folksim typed [dict get $options printable] at $ts
                }
            }
        """ % (tcl_quote(emu.kbd_path), tcl_quote(emu.kbd_path)))

        def typed():
            rows = folk.query("folksim typed /c/ at /t/")
            return "".join(r["c"] for r in sorted(rows, key=lambda r: float(r["t"])))

        # the reader thread needs a moment to open the FIFO and subscribe: probe with one key
        deadline = time.monotonic() + 60
        while "x" not in typed():
            assert time.monotonic() < deadline, "keyboard.folk never delivered a key: %s" % folk.errors()
            emu.tap("x")
            time.sleep(0.3)
        n_probe = len(typed())
        emu.type("abc")
        folk.wait_for(lambda: typed()[n_probe:] == "abc", timeout=30)
        downs = [code for (_, code, value) in emu.key_events() if value == 1]
        assert downs[-3:] == ["KEY_A", "KEY_B", "KEY_C"], downs
        kinds = {r["kind"] for r in emu.log()}
        assert {"cmd", "report", "event"} <= kinds, kinds
        say("typed %r through hidemu -> keyboard.folk (after %d probe key(s)); log has %d records" % (
            typed()[n_probe:], n_probe, len(emu.log())))
        try:
            emu.cmd("nonsense")
            raise AssertionError("hidemu accepted nonsense")
        except RuntimeError:
            pass
        folk.unhold("keys")

        errs = folk.errors()
        assert errs == [], "unexpected program errors: %r" % errs
        ignored = sorted({p for p, _ in folk.all_errors()})
        say("no program errors (ignored: %s)" % (", ".join(ignored) or "none"))
        assert "web: " in folk.logs("builtin-programs/web/web.folk"), "logs() is empty"
        pid, emu_pid = folk.pid, emu.proc.pid

    left = folk.survivors + (emu.close() if emu else [])
    assert left == [], "survivors: %r" % left
    assert _session_pids(pid) == [] and _session_pids(emu_pid) == [], "processes left running"
    assert keep or not os.path.exists(folk.home)
    say("stopped; nothing left running")
    print("selftest: PASS (boot %.1f s, total %.1f s)" % (folk.boot_seconds, time.monotonic() - t_start), flush=True)
    return 0


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description="Boot a headless Folk for simulation; see the module docstring.")
    ap.add_argument("--selftest", action="store_true", help="run the harness self-test")
    ap.add_argument("--decode-strip", metavar="PNG", help="decode a test app's status strip from a screenshot (JSON)")
    ap.add_argument("--keep", action="store_true", help="keep HOME and logs")
    ap.add_argument("--display", default="1280x720")
    ap.add_argument("--port", type=int)
    ap.add_argument("--seconds", type=float, default=0, help="with programs: run this long, then stop")
    ap.add_argument("--frame", help="save a frame to this PNG before stopping")
    ap.add_argument("programs", nargs="*", help="sim programs to load (e.g. test/sim/programs/sim-setup.folk)")
    args = ap.parse_args(argv)
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(143))
    if args.decode_strip:
        import json
        from PIL import Image
        print(json.dumps(decode_strip(Image.open(args.decode_strip))))
        return 0
    if args.selftest:
        return selftest(keep=args.keep)
    with FolkSim(display=args.display, port=args.port, programs=args.programs, keep=args.keep) as folk:
        print("folk pid %d port %d home %s boot %.1f s" % (folk.pid, folk.port, folk.home, folk.boot_seconds), flush=True)
        time.sleep(args.seconds)
        if args.frame:
            folk.frame_stable().save(args.frame)
        for p, e in folk.errors():
            print("error: %s: %s" % (p, e))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
