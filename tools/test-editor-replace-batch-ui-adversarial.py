#!/usr/bin/env python3
"""프로젝트 전체 바꾸기 UI의 범위·검색 행·문서 세대·file proof·단회 적용 보호를 격리 source에서 검증한다."""
import hashlib
import json
from pathlib import Path
import subprocess
import tempfile
import sys

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix="maru-project-all-ui-adversarial-"))
source = root / "source"
subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules", "--exclude=references", "--exclude=.env*", "--exclude=.codex-worktrees", str(repo) + "/", str(source) + "/"], check=True)
for name in ("node_modules", "web/node_modules"):
    if (repo / name).exists():
        (source / name).symlink_to(repo / name, target_is_directory=True)
ui = Path("src/platform/macos/app_session/editor/search/batch/ui.zig")
collect = Path("src/platform/macos/app_session/editor/search/batch/collect.zig")
load = Path("src/platform/macos/app_session/editor/search/batch/load.zig")
coordinator = Path("src/platform/macos/app_session/editor/search/batch/coordinator.zig")
original = {path: (source / path).read_text() for path in (ui, collect, load, coordinator)}
def mutate(path, old, new):
    assert original[path].count(old) == 1, old
    result = dict(original)
    result[path] = result[path].replace(old, new, 1)
    return result
repeat = dict(original)
repeat[ui] = repeat[ui].replace("return self.editor_search.batch.phase == .ready and", "return (self.editor_search.batch.phase == .ready or self.editor_search.batch.phase == .completed) and", 1).replace("fn current(self: *host.AppSession) bool {", "fn current(self: *host.AppSession) bool {\n    if (self.editor_search.batch.phase == .completed) return true;", 1)
cases = [
    ("control", original, True),
    ("omit-disk-targets", mutate(ui, "for (st.result.model.groups.items) |group| {", "for (st.result.model.groups.items) |group| {\n        if (group.source == .disk) continue;"), False),
    ("trust-changed-row", mutate(collect, "for (expected.found) |found| if (!found) return error.StaleSources;", "for (expected.found) |found| if (false and !found) return error.StaleSources;"), False),
    ("reuse-document-generation", mutate(ui, " and source.generation == lease.document.generation", ""), False),
    ("ignore-file-stamp", mutate(load, " or !proof.matchesStat(current)", " or (false and !proof.matchesStat(current))"), False),
    ("reactivate-applied-button", repeat, False),
    ("skip-sidebar-projection", mutate(coordinator, '@import("../../../tab.zig").recomputeVisibleTabs(session);', 'if (false) @import("../../../tab.zig").recomputeVisibleTabs(session);'), False),
    ("equivalent-control", mutate(collect, "self.cursor += 1;", "self.cursor = self.cursor + 1;"), True),
    ("restored-control", original, True),
]
# 저장 재시도는 편집 commit과 별도이므로 기존 UI 변이와 독립 실행한다.
if "--save-retry" in sys.argv:
    cases = [
        ("control", original, True),
        ("overwrite-external-change", mutate(ui, '.saveDocument(self, term) catch |err| {', '.overwriteDocument(self, term) catch |err| {'), False),
        ("save-during-ime", mutate(ui, 'if (self.ime_active or self.ime_editor_commit_pending or owner.documentCompositionStamp(self, term) != 0) return error.InputTransactionPending;', 'if (false and (self.ime_active or self.ime_editor_commit_pending or owner.documentCompositionStamp(self, term) != 0)) return error.InputTransactionPending;'), False),
        ("keep-failed-count", mutate(ui, 'st.result.save_failed -= 1;', 'st.result.save_failed -= 0;'), False),
        ("repeat-successful-save", mutate(ui, 'if (target.outcome != .save_failed) return error.StaleRequest;', 'if (target.outcome == .saved) return; if (target.outcome != .save_failed) return error.StaleRequest;'), False),
        ("reuse-document-generation", mutate(ui, ' and source.generation == lease.document.generation', ''), False),
        ("restored-control", original, True),
    ]
if "--selection" in sys.argv:
    cases = [
        ("control", original, True),
        ("include-excluded-ranges", mutate(ui, "if (st.result.model.includes(index, range_index))", "if (true or st.result.model.includes(index, range_index))"), False),
        ("omit-selected-model", mutate(ui, "for (st.result.model.groups.items) |group| {", "for (st.result.model.groups.items) |group| {\n        if (group.source == .model) continue;"), False),
        ("omit-selected-disk", mutate(ui, "for (st.result.model.groups.items) |group| {", "for (st.result.model.groups.items) |group| {\n        if (group.source == .disk) continue;"), False),
        ("retain-empty-target", mutate(ui, "if (ranges.items.len == 0) continue;", "if (false and ranges.items.len == 0) continue;"), False),
        ("wrong-selected-count", mutate(ui, "const matches = spec.matches;", "const matches = st.result.model.matches;"), False),
        ("restored-control", original, True),
    ]
if "--save-retry" in sys.argv or "--selection" in sys.argv:
    # 전체 OOM 탐색은 원본 gate로 별도 검증한다. 결함 주입은 저장·문서 세대 판정에 집중한다.
    build = source / "build.zig"
    build_text = build.read_text()
    needle = '.filters = &.{".test.RPBU"}'
    assert build_text.count(needle) == 1
    count_arg = 'run_batch_ui.addArg("--maru-expect-tests=14");'
    assert build_text.count(count_arg) == 1
    filters = '.filters = &.{".test.RPBU10"}' if "--selection" in sys.argv else '.filters = &.{".test.RPBU3", ".test.RPBU7"}'
    focused_count = 5 if "--selection" in sys.argv else 6
    build.write_text(build_text.replace(needle, filters).replace(count_arg, f'run_batch_ui.addArg("--maru-expect-tests={focused_count}");'))
expected_count = 5 if "--selection" in sys.argv else 6 if "--save-retry" in sys.argv else 14
results = []
for name, changed, passing in cases:
    for path, content in changed.items():
        (source / path).write_text(content)
    result = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-project-replace-batch-ui", "-j2", "--cache-dir", str(root / ("cache" if "--save-retry" in sys.argv or "--selection" in sys.argv else name + "/cache"))], cwd=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, timeout=300)
    (root / f"{name}.log").write_text(result.stdout)
    if passing:
        assert result.returncode == 0 and f"All {expected_count} tests passed" in result.stdout, (name, result.stdout[-4000:])
    else:
        assert result.returncode != 0 and "FAIL (" in result.stdout, (name, result.stdout[-4000:])
    results.append(dict(name=name, expected_pass=passing, exit_code=result.returncode, sha256={str(path): hashlib.sha256(content.encode()).hexdigest() for path, content in changed.items()}))
    print(name + ": verified", flush=True)
for path, content in original.items():
    (source / path).write_text(content)
(root / "results.json").write_text(json.dumps(dict(scope="completed search to mixed replacement UI; AppKit/Metal visual verification is a separate harness", results=results), indent=2) + "\n")
print(root / "results.json", flush=True)
