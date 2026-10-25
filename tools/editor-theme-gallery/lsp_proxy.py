#!/usr/bin/env python3
"""Forward real LSP bytes unchanged; retain only bounded protocol observations.

No response or semantic token is fabricated. The gallery uses this to distinguish
an enabled setting from an initialized server and an actual token response.
"""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import threading
import time


def main():
    config = json.loads(Path(sys.argv[1]).read_text())
    root = Path(config["root"])
    log = (root / "protocol.ndjson").open("a", buffering=1)
    lock = threading.Lock()
    pending = {}

    def record(event):
        with lock:
            log.write(json.dumps(dict(time_ns=time.monotonic_ns(), **event)) + "\n")

    env = dict(config["server_environment"])
    with (root / "server.stderr").open("ab") as err:
        child = subprocess.Popen(config["argv"], cwd=root, env=env, stdin=subprocess.PIPE,
                                 stdout=subprocess.PIPE, stderr=err, start_new_session=True)
        record(dict(event="spawn", argv=config["argv"], pid=child.pid))

        def stop(*_):
            try:
                os.killpg(child.pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
            try:
                child.wait(timeout=3)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait(timeout=3)

        signal.signal(signal.SIGTERM, lambda *_: (stop(), sys.exit(0)))

        def observe(direction, message):
            method = message.get("method")
            identity = message.get("id")
            if direction == "client" and method:
                if identity is not None:
                    pending[str(identity)] = method
                if method in ("initialize", "initialized", "textDocument/didOpen") or "semanticTokens" in method:
                    record(dict(event="request", method=method, id=identity))
            if direction != "server":
                return
            request = pending.pop(str(identity), None) if identity is not None else None
            if request == "initialize":
                result = message.get("result") or {}
                caps = result.get("capabilities") or {}
                record(dict(event="initialize_response", server_info=result.get("serverInfo"),
                            semantic_provider=caps.get("semanticTokensProvider"), error=message.get("error")))
            elif request and "semanticTokens" in request:
                result = message.get("result") or {}
                record(dict(event="semantic_response", method=request, integers=len(result.get("data") or []),
                            error=message.get("error")))
            elif method == "textDocument/publishDiagnostics":
                record(dict(event="diagnostics", count=len(message.get("params", {}).get("diagnostics", []))))

        def forward(source, target, direction):
            buffer = b""
            try:
                while True:
                    data = os.read(source.fileno(), 65536)
                    if not data:
                        break
                    buffer += data
                    while b"\r\n\r\n" in buffer:
                        header, body = buffer.split(b"\r\n\r\n", 1)
                        sizes = [int(row.split(b":", 1)[1]) for row in header.split(b"\r\n")
                                 if row.lower().startswith(b"content-length:")]
                        if not sizes or sizes[0] > 32 * 1024 * 1024:
                            raise RuntimeError("Invalid or oversized LSP frame")
                        if len(body) < sizes[0]:
                            break
                        payload, buffer = body[:sizes[0]], body[sizes[0]:]
                        observe(direction, json.loads(payload))
                    # Register request IDs before forwarding them. A fast server
                    # can otherwise respond before the observing thread sees it.
                    target.write(data)
                    target.flush()
            except (BrokenPipeError, OSError):
                pass
            except Exception as exc:
                record(dict(event="observer_error", error=str(exc)))
            finally:
                if direction == "client":
                    try:
                        target.close()
                    except OSError:
                        pass

        incoming = threading.Thread(target=forward, args=(sys.stdin.buffer, child.stdin, "client"), daemon=True)
        incoming.start()
        try:
            forward(child.stdout, sys.stdout.buffer, "server")
        finally:
            stop()
            record(dict(event="exit", code=child.returncode))


if __name__ == "__main__":
    main()
