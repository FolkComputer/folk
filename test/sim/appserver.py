#!/usr/bin/env python3
"""appserver.py -- serves test/sim/apps/ and records what the apps report.

Python 3 stdlib only.

    from appserver import AppServer
    with AppServer() as apps:
        url = apps.url("kanban", "s1")        # http://127.0.0.1:<port>/kanban.html?session=s1
        ... point a browser at url, drive it ...
        apps.wait_event("s1", lambda e: e["k"] == "app" and e["a"] == "move")
        apps.events("s1"); apps.layout("s1"); apps.state("s1")

Protocol (see apps/common.js):

    POST /log?session=ID    body: JSON {"app": name, "events": [record...],
                            "layout": {testid: {x,y,w,h}} (only when it changed),
                            "state": <window.__state()>, "hash": <24-bit state hash>}
                            -> 204. Records carry `i` (per-page sequence number from 0) and are
                            stored once, ordered by `i`; a page (re)load starts a new `load` number.
    GET  /log?session=ID    -> JSON {"events": [...], "layout": {...}, "state": {...}, "hash": n,
                            "app": name, "posts": n}
    GET  /log               -> JSON list of session ids
    DELETE /log?session=ID  forget the session
    GET  /<file>            static files from the apps directory, `Cache-Control: no-store`

CLI: python3 test/sim/appserver.py [--port N] [--root DIR]   (prints the URLs, serves until killed)
"""

import json
import os
import sys
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import parse_qs, quote, urlsplit

APPS = os.path.join(os.path.dirname(os.path.abspath(__file__)), "apps")

CONTENT_TYPES = {
    ".html": "text/html; charset=utf-8", ".js": "text/javascript; charset=utf-8",
    ".mjs": "text/javascript; charset=utf-8", ".css": "text/css; charset=utf-8",
    ".json": "application/json; charset=utf-8", ".txt": "text/plain; charset=utf-8",
    ".png": "image/png", ".jpg": "image/jpeg", ".svg": "image/svg+xml", ".ico": "image/x-icon",
    ".wav": "audio/wav",
}


class _Session:
    def __init__(self):
        self.events = {}      # (load, i) -> record
        self.layout = {}
        self.state = None
        self.hash = None
        self.app = None
        self.posts = 0
        self.loads = {}       # page load id -> load number
        self.layout_order = (-1, -1)
        self.state_order = (-1, -1)


class AppServer:
    def __init__(self, root=APPS, port=0, host="127.0.0.1"):
        self.root = os.path.abspath(root)
        self.host = host
        self.port = port
        self._sessions = {}
        self._cond = threading.Condition()
        self._httpd = None
        self._thread = None

    # ---- lifecycle

    def start(self):
        server = self

        class Handler(BaseHTTPRequestHandler):
            protocol_version = "HTTP/1.1"

            def log_message(self, fmt, *args):
                pass

            def _send(self, code, body=b"", ctype="text/plain; charset=utf-8"):
                self.send_response(code)
                self.send_header("Content-Type", ctype)
                self.send_header("Content-Length", str(len(body)))
                self.send_header("Cache-Control", "no-store")
                self.end_headers()
                if self.command != "HEAD":
                    self.wfile.write(body)

            def _json(self, obj):
                self._send(200, json.dumps(obj).encode(), CONTENT_TYPES[".json"])

            def do_GET(self):
                url = urlsplit(self.path)
                if url.path == "/log":
                    session = parse_qs(url.query).get("session", [None])[0]
                    self._json(server.sessions() if session is None else server.dump(session))
                    return
                rel = os.path.normpath(url.path.lstrip("/") or "index.html")
                path = os.path.join(server.root, rel)
                if rel.startswith("..") or not os.path.isfile(path):
                    if rel == "index.html":
                        links = "".join('<li><a href="%s">%s</a>' % (n, n) for n in server.apps())
                        self._send(200, ("<!doctype html><title>sim apps</title><ul>%s</ul>" % links).encode(),
                                   CONTENT_TYPES[".html"])
                    else:
                        self._send(404, b"not found\n")
                    return
                with open(path, "rb") as f:
                    body = f.read()
                self._send(200, body, CONTENT_TYPES.get(os.path.splitext(path)[1], "application/octet-stream"))

            do_HEAD = do_GET

            def do_POST(self):
                url = urlsplit(self.path)
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                if url.path != "/log":
                    self._send(404, b"not found\n")
                    return
                session = parse_qs(url.query).get("session", [""])[0]
                try:
                    server.record(session, json.loads(body.decode("utf-8")))
                except (ValueError, KeyError, TypeError, AttributeError) as e:
                    self._send(400, ("bad log record: %s\n" % e).encode())
                    return
                self._send(204)

            def do_DELETE(self):
                url = urlsplit(self.path)
                server.clear(parse_qs(url.query).get("session", [""])[0])
                self._send(204)

        self._httpd = ThreadingHTTPServer((self.host, self.port), Handler)
        self._httpd.daemon_threads = True
        self.port = self._httpd.server_address[1]
        self._thread = threading.Thread(target=self._httpd.serve_forever, kwargs={"poll_interval": 0.05}, daemon=True)
        self._thread.start()
        return self

    def stop(self):
        if self._httpd:
            self._httpd.shutdown()
            self._httpd.server_close()
            self._httpd = None

    def __enter__(self):
        return self.start()

    def __exit__(self, *exc):
        self.stop()
        return False

    # ---- data

    def apps(self):
        return sorted(n for n in os.listdir(self.root) if n.endswith(".html"))

    def url(self, app, session=None, **params):
        """URL of an app ("kanban" or "kanban.html"), with ?session=... and extra query parameters."""
        name = app if app.endswith(".html") else app + ".html"
        query = "&".join("%s=%s" % (k, quote(str(v))) for k, v in
                         ([("session", session)] if session is not None else []) + sorted(params.items()))
        return "http://%s:%d/%s%s" % (self.host, self.port, name, "?" + query if query else "")

    def record(self, session, batch):
        with self._cond:
            s = self._sessions.setdefault(session, _Session())
            s.posts += 1
            s.app = batch.get("app", s.app)
            load = s.loads.setdefault(batch.get("load"), len(s.loads))
            for r in batch.get("events") or []:
                r["load"] = load
                s.events.setdefault((load, r["i"]), r)
            # POSTs can overtake each other: layout and state come from the newest one only
            order = (load, batch.get("p", s.posts))
            if batch.get("layout") is not None and order >= s.layout_order:
                s.layout, s.layout_order = batch["layout"], order
            if "state" in batch and order >= s.state_order:
                s.state, s.hash, s.state_order = batch["state"], batch.get("hash"), order
            self._cond.notify_all()

    def sessions(self):
        with self._cond:
            return sorted(self._sessions)

    def events(self, session, kinds=None):
        """All records of the session, in page order. Each: {"i": seq, "t": ms since page load,
        "k": kind (keydown, keyup, beforeinput, input, mousedown, mouseup, click, dblclick,
        contextmenu, wheel, app, load), ...}; optionally only the given kinds."""
        with self._cond:
            s = self._sessions.get(session)
            out = [s.events[k] for k in sorted(s.events)] if s else []
        return [e for e in out if kinds is None or e["k"] in kinds]

    def layout(self, session):
        """Latest {testid: {"x","y","w","h"}} (viewport px) the app reported."""
        with self._cond:
            s = self._sessions.get(session)
            return dict(s.layout) if s else {}

    def state(self, session):
        """Latest window.__state() the app reported (None before the first report)."""
        with self._cond:
            s = self._sessions.get(session)
            return s.state if s else None

    def dump(self, session):
        with self._cond:
            s = self._sessions.get(session)
            if not s:
                return {"events": [], "layout": {}, "state": None, "hash": None, "app": None, "posts": 0}
            return {"events": [s.events[k] for k in sorted(s.events)], "layout": s.layout, "state": s.state,
                    "hash": s.hash, "app": s.app, "posts": s.posts}

    def clear(self, session):
        with self._cond:
            self._sessions.pop(session, None)

    def wait_event(self, session, predicate, timeout=10, start=0):
        """First record (at index >= start in events(session)) for which predicate(record) is true."""
        deadline = time.monotonic() + timeout
        with self._cond:
            while True:
                s = self._sessions.get(session)
                events = [s.events[k] for k in sorted(s.events)] if s else []
                for e in events[start:]:
                    if predicate(e):
                        return e
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError("no matching event in session %r after %.1f s (%d events)" % (
                        session, timeout, len(events)))
                self._cond.wait(left)

    def wait_state(self, session, predicate, timeout=10):
        """Wait until predicate(latest reported state) is true; returns that state."""
        deadline = time.monotonic() + timeout
        with self._cond:
            while True:
                s = self._sessions.get(session)
                if s and s.state is not None and predicate(s.state):
                    return s.state
                left = deadline - time.monotonic()
                if left <= 0:
                    raise TimeoutError("state of session %r did not match after %.1f s: %r" % (
                        session, timeout, s.state if s else None))
                self._cond.wait(left)


def main(argv):
    import argparse
    ap = argparse.ArgumentParser(description="Serve the sim test apps and record their event logs.")
    ap.add_argument("--port", type=int, default=0)
    ap.add_argument("--root", default=APPS)
    args = ap.parse_args(argv)
    server = AppServer(root=args.root, port=args.port).start()
    print("appserver listening on http://127.0.0.1:%d" % server.port, flush=True)
    for name in server.apps():
        print("  " + server.url(name, "demo"), flush=True)
    try:
        while True:
            time.sleep(3600)
    except KeyboardInterrupt:
        pass
    finally:
        server.stop()
    return 0


if __name__ == "__main__":
    import signal
    signal.signal(signal.SIGTERM, lambda *a: sys.exit(0))
    sys.exit(main(sys.argv[1:]))
