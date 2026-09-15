#!/usr/bin/env python3
import json
import os
import pty
import signal
import subprocess
import threading
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

PORT = int(os.environ.get("PORT", "8471"))
REPO_ROOT = os.environ.get("REPO_ROOT", os.getcwd())

IOS_CMDS = {"build", "install", "uninstall", "watch", "test", "tsan-test", "e2e",
            "e2e-run", "screenshot", "screenshots", "see", "ui", "logs", "debug", "sentry"}
SERVER_CMDS = {"build", "test", "lint", "format", "docs", "sqlc", "watch"}
LIVE_SUBS = {"status", "logs", "snapshots", "clusters",
             "deployments", "releases", "machines", "sentry"}
GUARDED_SUBS = {"deploy", "rollback"}

run_lock = threading.Lock()
proc_lock = threading.Lock()
holder = {"proc": None}

def now():
    return datetime.now(timezone.utc).isoformat()


def resolve(op, args):
    if op.startswith("ios-"):
        cmd = op[len("ios-"):]
        if cmd in IOS_CMDS:
            return (["./build.sh", "ios", cmd] + args, None, None)
    elif op.startswith("server-live-"):
        sub = op[len("server-live-"):]
        if sub in LIVE_SUBS:
            return (["./build.sh", "server", "live", sub] + args, None, None)
        if sub in GUARDED_SUBS:
            if "--dry-run" in args:
                return (["./build.sh", "server", "live", sub] + args, None, None)
            return (None, 403, "refused: %s requires --dry-run" % op)
    elif op.startswith("server-"):
        cmd = op[len("server-"):]
        if cmd in SERVER_CMDS:
            return (["./build.sh", "server", cmd] + args, None, None)
    return (None, 400, "unknown op: %s" % op)


class Handler(BaseHTTPRequestHandler):
    def send_text(self, code, body):
        raw = body.encode()
        self.send_response(code)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_GET(self):
        if self.path == "/health":
            self.send_text(200, "ok")
        else:
            self.send_text(404, "not found")

    def do_POST(self):
        if self.path == "/kill":
            self.handle_kill()
        elif self.path == "/run":
            self.handle_run()
        else:
            self.send_text(404, "not found")

    def handle_kill(self):
        length = int(self.headers.get("Content-Length") or 0)
        if length:
            self.rfile.read(length)
        with proc_lock:
            proc = holder["proc"]
            if proc is None or proc.poll() is not None:
                killed = False
            else:
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                    killed = True
                except (ProcessLookupError, PermissionError):
                    killed = False
        raw = json.dumps({"killed": killed}).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def handle_run(self):
        length = int(self.headers.get("Content-Length") or 0)
        raw = self.rfile.read(length) if length else b""
        try:
            data = json.loads(raw.decode() or "{}")
            op = data.get("op", "")
            args = data.get("args", [])
            if not isinstance(args, list):
                raise ValueError("args must be a list")
            args = [str(a) for a in args]
        except (ValueError, UnicodeDecodeError) as e:
            self.send_text(400, "bad request: %s" % e)
            return
        argv, err_code, err_msg = resolve(op, args)
        if err_code:
            self.send_text(err_code, err_msg)
            return
        if not run_lock.acquire(blocking=False):
            self.send_text(409, "busy")
            return
        try:
            print("%s start op=%s args=%s" % (now(), op, json.dumps(args)), flush=True)
            env = dict(os.environ)
            env["PYTHONUNBUFFERED"] = "1"
            env.pop("SCODE_SANDBOXED", None)
            proc = None
            primary = None
            replica = None
            try:
                primary, replica = pty.openpty()
                proc = subprocess.Popen(
                    argv,
                    cwd=REPO_ROOT,
                    stdin=subprocess.DEVNULL,
                    stdout=replica,
                    stderr=subprocess.STDOUT,
                    start_new_session=True,
                    close_fds=True,
                    env=env,
                )
                os.close(replica)
            except Exception:
                if primary is not None:
                    os.close(primary)
                if replica is not None:
                    os.close(replica)
                raise
            with proc_lock:
                holder["proc"] = proc
            self.send_response(200)
            self.send_header("Content-Type", "application/octet-stream")
            self.end_headers()
            try:
                while True:
                    try:
                        chunk = os.read(primary, 1024)
                    except OSError:
                        break
                    if not chunk:
                        break
                    self.wfile.write(chunk.replace(b"\r\n", b"\n"))
                    self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
            finally:
                os.close(primary)
            code = proc.wait()
            print("%s finish op=%s exit=%d" % (now(), op, code), flush=True)
            try:
                # Leading newline: the child may end without one (or with a
                # dangling ANSI reset), so frame the trailer on its own line.
                self.wfile.write(("\n__TURN_SRV_EXIT=%d\n" % code).encode())
                self.wfile.flush()
            except (BrokenPipeError, ConnectionResetError):
                pass
        finally:
            with proc_lock:
                holder["proc"] = None
            run_lock.release()

    def log_message(self, *a):
        pass


def main():
    srv = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    print("%s build-server listening on 127.0.0.1:%d repo=%s" % (now(), PORT, REPO_ROOT), flush=True)
    srv.serve_forever()


if __name__ == "__main__":
    main()
