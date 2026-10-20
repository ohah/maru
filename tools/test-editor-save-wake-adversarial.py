#!/usr/bin/env python3
"""통지 누락·재예약 유실·유휴 busy loop를 격리 사본에서 실제 실패로 확인한다."""
from pathlib import Path
import hashlib
import json
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
output = Path(tempfile.mkdtemp(prefix="maru-save-wake-adversarial-"))
source = output / "source"
subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules", "--exclude=references", "--exclude=.env*", str(root) + "/", str(source) + "/"], check=True)
base = "src/platform/macos/app_session/"
mutations = [
    ("admission", base + "editor/save/as.zig", 'pub fn firstSave(session: *host.AppSession, term: *host.Term, path: []const u8, overwriting: bool) void {\n    defer @import("wake.zig").request();', 'pub fn firstSave(session: *host.AppSession, term: *host.Term, path: []const u8, overwriting: bool) void {'),
    ("completion", base + "editor/save/worker.zig", '        @import("wake.zig").request();', ''),
    ("ime-resume", base + "input.zig", 'pub fn imeEnd(self: *AppSession, event: ?terminal.KeyEvent) void {\n    defer @import("editor/save/wake.zig").resumePending();', 'pub fn imeEnd(self: *AppSession, event: ?terminal.KeyEvent) void {'),
    ("lost-repost", base + "editor/save/wake.zig", '    if (!queued.swap(false, .acq_rel)) return;', '    if (!queued.load(.acquire)) return;\n    defer queued.store(false, .release);'),
    ("idle-spin", base + "editor/save/wake.zig", '    if (pending) request();', '    request();'),
    ("failure-repost", base + "editor/save/dispatch.zig", '        if (owner.queue.outcome != null) @import("wake.zig").request();', ''),
]
results = []
def run(name, expected):
    with (output / (name + ".log")).open("w") as log:
        p = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-save-wake", "-j2"], cwd=source, stdout=log, stderr=subprocess.STDOUT, timeout=600)
    text = (output / (name + ".log")).read_text()
    semantic = "FAIL (" in text and ("SaveWakeTimedOut" in text or "TestUnexpectedResult" in text or "TestExpectedEqual" in text)
    ok = p.returncode == 0 if expected else p.returncode != 0 and semantic
    results.append(dict(name=name, exit=p.returncode, expected_success=expected, semantic_failure=semantic, passed=ok))
    (output / "results.json").write_text(json.dumps(results, indent=2))
    print(name, "PASS" if ok else "FAIL", flush=True)
    if not ok:
        raise SystemExit(str(output))
run("normal", True)
for name, relative, old, new in mutations:
    path = source / relative
    original = path.read_text()
    if original.count(old) != 1:
        raise SystemExit("mutation anchor must occur once: " + name)
    try:
        path.write_text(original.replace(old, new))
        run(name, False)
    finally:
        path.write_text(original)
        assert hashlib.sha256(path.read_bytes()).digest() == hashlib.sha256(original.encode()).digest()
run("restored", True)
print(output)
