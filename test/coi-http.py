"""A static server that sends COOP/COEP itself, for test/windows-host.ps1's demos:

    python coi-http.py <port> <directory>

The page is then cross-origin isolated at once. On a plain server (as GitHub Pages) it
gets there through coi-serviceworker, which registers and reloads the page; on the
Windows runner that reload sometimes never came and the demo waited for nothing (kit runs
41208207833 and 41221088501). The login test keeps the plain server, so that path stays
tested; the recordings use this one.
"""
import functools
import http.server
import sys


class Handler(http.server.SimpleHTTPRequestHandler):
    def end_headers(self):
        self.send_header("Cross-Origin-Opener-Policy", "same-origin")
        self.send_header("Cross-Origin-Embedder-Policy", "require-corp")
        super().end_headers()


port, directory = int(sys.argv[1]), sys.argv[2]
http.server.ThreadingHTTPServer(("127.0.0.1", port), functools.partial(Handler, directory=directory)).serve_forever()
