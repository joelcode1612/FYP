"""Local production preview with the same SPA fallback required by hosting."""
import argparse
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import urlsplit


class ClientPreviewHandler(SimpleHTTPRequestHandler):
    def do_GET(self):
        route = urlsplit(self.path).path
        target = Path(self.translate_path(route))
        if not target.exists() and not Path(route).suffix:
            self.path = "/index.html"
        super().do_GET()

    def end_headers(self):
        self.send_header("Cache-Control", "no-cache")
        super().end_headers()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", type=int, default=8091)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1] / "build" / "jaspr"
    if not (root / "index.html").is_file():
        parser.error("Production output is missing. Run jaspr build first.")
    server = ThreadingHTTPServer(
        ("127.0.0.1", args.port), partial(ClientPreviewHandler, directory=str(root))
    )
    print(f"Sitewise preview: http://127.0.0.1:{args.port}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
