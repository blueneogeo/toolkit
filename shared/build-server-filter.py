# Renamed to ../build-server/server-filter.py — shim so older checkouts/paths don't break; delete once downstream checkouts bump.
import os, runpy; runpy.run_path(os.path.join(os.path.dirname(__file__), "..", "build-server", "server-filter.py"), run_name="__main__")
