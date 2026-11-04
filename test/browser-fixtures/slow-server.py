#!/usr/bin/env python3
# A tiny HTTP server for the browser tests. Serves this directory, plus
#
#     /slow?ms=N      waits N milliseconds, then serves index.html
#     /crash          serves a page whose <a> points at chrome://crash
#
# usage: slow-server.py PORT FOLK_PID
#
# It exits on its own when the Folk process that started it is gone,
# so a test can't leave it behind.

import http.server, os, sys, threading, time, urllib.parse

port = int(sys.argv[1])
folk_pid = int(sys.argv[2])
here = os.path.dirname(os.path.abspath(__file__))


class Handler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *a, **kw):
        super().__init__(*a, directory=here, **kw)

    def log_message(self, *a):
        pass

    def do_GET(self):
        url = urllib.parse.urlparse(self.path)
        if url.path == "/slow":
            ms = int(urllib.parse.parse_qs(url.query).get("ms", ["1000"])[0])
            time.sleep(ms / 1000.0)
            self.path = "/index.html"
        return super().do_GET()


def watchdog():
    while True:
        time.sleep(0.5)
        try:
            os.kill(folk_pid, 0)
        except OSError:
            os._exit(0)


threading.Thread(target=watchdog, daemon=True).start()
http.server.ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
