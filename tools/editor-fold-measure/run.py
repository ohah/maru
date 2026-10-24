#!/usr/bin/env python3
"""같은 원문으로 전체·증분·조용 시계 접힘 프로토타입을 격리 빌드하고 제품 편집/프레임을 실측한다."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess


def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"Expected one anchor: {old[:90]!r}, found {text.count(old)}")
    return text.replace(old, new)


def setup(repo, output, deps, mode):
    source = output / ("source-" + str(mode))
    subprocess.run(["rsync", "-a", "--exclude=.git", "--exclude=.zig-cache", "--exclude=zig-out", "--exclude=node_modules",
                    "--exclude=zig-pkg", "--exclude=references", "--exclude=.env*", str(repo) + "/", str(source) + "/"], check=True)
    if not (source / "zig-pkg").exists(): (source / "zig-pkg").symlink_to(deps, target_is_directory=True)
    p = source / "src/syntax/tree_sitter.zig"
    text = p.read_text()
    text = once(text, "    sticky_summary: symbol_windows.Summary = .{},", "    fold_probe: FoldProbe = .{},\n    sticky_summary: symbol_windows.Summary = .{},")
    text = text.replace("self.sticky_summary.invalidate();", "self.fold_probe.deinit();\n        self.sticky_summary.invalidate();")
    text = once(text, "        self.sticky_summary.edit(&edit);", "        self.fold_probe.edit(&edit);\n        self.sticky_summary.edit(&edit);")
    old = "    pub fn foldSpans(self: *Provider, allocator: std.mem.Allocator, out: *std.ArrayList(FoldSpan)) error{OutOfMemory}!void {"
    new = old + "\n        if (FoldProbe.mode == 1) return self.fold_probe.query(self, allocator, out);\n        return self.foldSpansFull(allocator, out);\n    }\n\n" + old.replace("fn foldSpans(", "fn foldSpansFull(")
    text = once(text, old, new)
    text += "\n" + (repo / "tools/editor-fold-measure/probe.zig.inc").read_text().replace("EW2_MODE", str(mode))
    cases_start = text.index('test "sticky ancestors 언어별')
    cases_start = text.index('        .{ .language =', cases_start)
    cases_end = text.index('    }) |case|', cases_start)
    text += "\n" + (repo / "tools/editor-fold-measure/syntax.zig.inc").read_text().replace("EW2_CASES", text[cases_start:cases_end])
    p.write_text(text)
    p = source / "src/platform/macos/app_session/editor/mod.zig"
    text = p.read_text()
    # 동일한 영속 Provider payload를 세 방식 모두 명시적으로 사용한다.
    text = once(text, "    var prov = &(st.provider orelse return);\n    if (prov.tree == null) return;", "    const prov = if (st.provider) |*p| p else return;\n    if (prov.tree == null) return;")
    anchor = "    if (st.pending) return; // 아직 파는 중이다 — 다음 프레임에 다시 본다"
    text = once(text, anchor, anchor + "\n    if (syntax_mod.FoldProbe.mode == 2 and !syntax_mod.FoldProbe.force and st.provider != null and syntax_mod.FoldProbe.clock_ns < st.provider.?.fold_probe.deadline) return;")
    old = "    return refreshViewAfterEditImpl(self, term, edit, false);"
    new = """    const mapped = if (term.rt.editor_syntax.provider) |*p| blk: {
        const ready = p.fold_probe.mapped;
        p.fold_probe.mapped = false;
        break :blk ready;
    } else false;
    return refreshViewAfterEditImpl(self, term, edit, mapped);"""
    text = once(text, old, new)
    text += "\n" + (repo / "tools/editor-fold-measure/host.zig.inc").read_text()
    p.write_text(text)
    p = source / "src/platform/macos/app_session/editor/shared_edit.zig"
    text = p.read_text()
    old = "if ((view == term and restore_source) or view.rt.editor_folded_len == 0) null else prepareFolds"
    text = once(text, old, "if (syntax_color.syntax.FoldProbe.mode != 2 and ((view == term and restore_source) or view.rt.editor_folded_len == 0)) null else prepareFolds")
    old = "            if (v.term == self.term and self.restore_source) continue;"
    text = once(text, old, """            if (v.term == self.term and self.restore_source) {
                if (syntax_color.syntax.FoldProbe.mode == 2) {
                    if (v.folds) |folds| {
                        editor_ops.publishMappedFolds(self.session, v.term, folds.ranges, folds.folded, folds.previous, folds.marks, folds.len);
                        if (v.term.rt.editor_syntax.provider) |*p| p.fold_probe.mapped = true;
                    }
                }
                continue;
            }""")
    text = once(text, "    if (count <= 1) return state.opened.?.file.apply(d, sels);", "    if (count <= 1 and syntax_color.syntax.FoldProbe.mode != 2) return state.opened.?.file.apply(d, sels);")
    if text.count("folds.marks, folds.len);") != 2: raise RuntimeError("Unexpected mapped fold publication count")
    text = text.replace("folds.marks, folds.len);", "folds.marks, if (syntax_color.syntax.FoldProbe.mode == 2 and self.views.len == 1) 0 else folds.len);")
    p.write_text(text)
    p = source / "build.zig"
    text = p.read_text()
    anchor = '    const edit_cost_tests = addProjectTest(b, .{ .root_module = editor_tests.root_module, .filters = &.{".test.EW0"} });'
    added = '''    const fold_measure_tests = addProjectTest(b, .{ .root_module = editor_tests.root_module, .filters = &.{".test.EW2 fold measure"} });
    const run_fold_measure = b.addRunArtifact(fold_measure_tests);
    run_fold_measure.setCwd(b.path("."));
    run_fold_measure.addArg("--maru-expect-tests=5");
    run_fold_measure.addArg("--maru-expect-passed=5");
    b.step("test-editor-fold-measure", "Measure fold strategy prototypes").dependOn(&run_fold_measure.step);
    const fold_cache_tests = addProjectTest(b, .{ .root_module = syntax_mod, .filters = &.{"EW2 fold cache"} });
    const run_fold_cache = b.addRunArtifact(fold_cache_tests);
    run_fold_cache.addArg("--maru-expect-tests=3");
    run_fold_cache.addArg("--maru-expect-passed=3");
    b.step("test-editor-fold-cache", "Judge fold cache against full traversal").dependOn(&run_fold_cache.step);
'''
    p.write_text(once(text, anchor, added + anchor))
    names = ("src/syntax/tree_sitter.zig", "src/platform/macos/app_session/editor/mod.zig", "src/platform/macos/app_session/editor/shared_edit.zig", "build.zig")
    manifest = {"head": subprocess.check_output(["git", "rev-parse", "HEAD"], cwd=repo, text=True).strip(),
                "mode": mode, "original_sha256": {name: hashlib.sha256((repo/name).read_bytes()).hexdigest() for name in names},
                "instrumented_sha256": {name: hashlib.sha256((source/name).read_bytes()).hexdigest() for name in names},
                "templates_sha256": {name: hashlib.sha256((repo/"tools/editor-fold-measure"/name).read_bytes()).hexdigest() for name in ("host.zig.inc", "syntax.zig.inc", "probe.zig.inc", "run.py")}}
    (output / f"setup-{mode}.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--deps", type=Path, required=True)
    parser.add_argument("--modes", default="0,1,2")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--run-only", action="store_true")
    parser.add_argument("--delay-ms", type=int, default=150)
    parser.add_argument("--verify-each-edit", type=int, choices=(0,1), default=0)
    parser.add_argument("--prefix", default="run")
    parser.add_argument("--workloads", default="typing,slow,structure,paste,undo,shared,folded,command")
    args = parser.parse_args()
    if not args.prefix or Path(args.prefix).name != args.prefix or args.prefix in (".",".."): parser.error("Use a simple log prefix")
    repo = Path(__file__).resolve().parents[2]
    needs_setup = args.refresh or not args.resume or any(not (args.output/f"source-{mode}").exists() for mode in map(int,args.modes.split(",")))
    if not args.run_only and needs_setup and "prov.foldSpansCached(self.allocator" in (repo/"src/platform/macos/app_session/editor/mod.zig").read_text():
        parser.error("Historical prototype setup requires revision 7d7b3357d; use tools/editor-fold-product/run.py for integrated EW2")
    output = args.output.resolve()
    deps = args.deps.resolve()
    if repo == output or repo in output.parents or not deps.is_dir():
        parser.error("Output must be outside the repository; deps must exist")
    if output.exists() and any(output.iterdir()) and not args.resume:
        parser.error("Use a new output directory or --resume")
    output.mkdir(parents=True, exist_ok=True)
    lock_file = (output / ".lock").open("w")
    try:
        fcntl.flock(lock_file, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("Another measurement is already using this output directory")
    fixtures = output / "fixtures"
    fixtures.mkdir(exist_ok=True)
    for name, path in (("real-build.zig", "build.zig"), ("real-host.swift", "src/platform/macos/MaruAppHost.swift")):
        if not (fixtures / name).exists():
            (fixtures / name).write_bytes(subprocess.check_output(["git", "show", "HEAD:" + path], cwd=repo))
    for count in (3000, 15000, 50000):
        name = f"flat-{count}.zig"
        if not (fixtures / name).exists():
            (fixtures / name).write_text("".join(f"pub fn f{i}() u32 {{\n    const x = {i};\n    return x + 1;\n}}\n" for i in range(count)))
    # 가장 큰 입력도 파싱 상한 안에 둔다. 상한 밖은 이 전략 비교의 대상이 아니다.
    fixture_paths=[fixtures/name for name in ("flat-3000.zig","flat-15000.zig","flat-50000.zig","real-build.zig","real-host.swift")]
    assert all(p.stat().st_size < 4*1024*1024 for p in fixture_paths)
    inputs = {p.name: {"bytes": p.stat().st_size, "sha256": hashlib.sha256(p.read_bytes()).hexdigest()} for p in fixture_paths}
    (output / "inputs.json").write_text(json.dumps(inputs, indent=2) + "\n")
    if args.run_only:
        recorded=json.loads((output/"binaries.json").read_text())
        builds={}
        for mode in map(int,args.modes.split(",")):
            info=recorded[str(mode)]
            binary=Path(info["binary"])
            if hashlib.sha256(binary.read_bytes()).hexdigest()!=info["sha256"]: raise RuntimeError("Recorded binary changed")
            builds[mode]=(Path(info["cwd"]),binary)
    else:
        builds = {}
        for mode in map(int, args.modes.split(",")):
            source = output / f"source-{mode}"
            if args.refresh or not args.resume or not source.exists(): source = setup(repo, output, deps, mode)
            log_path = output / f"build-{mode}.log"
            env = {k:v for k,v in os.environ.items() if not k.startswith("MARU_")}
            env.update(MARU_EW2_FILE=str(fixtures / "flat-3000.zig"), MARU_EW2_WORKLOAD="typing",MARU_EW2_VERIFY_EACH_EDIT="1",MARU_EW2_DELAY_MS=str(args.delay_ms))
            print("build", mode, flush=True)
            with log_path.open("wb") as log:
                result = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-fold-measure", "test-editor-fold-cache", "-Doptimize=ReleaseFast", "-j2", "--verbose"], cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT)
            if result.returncode: raise RuntimeError(f"Build/control failed: {log_path}")
            paths = re.findall(r'(\./\.zig-cache/o/[0-9a-f]+/test) --maru-expect-tests=5', log_path.read_text())
            if not paths: raise RuntimeError("No test binary recorded")
            builds[mode] = (source, source / paths[-1])
        old_binaries=json.loads((output/"binaries.json").read_text()) if (output/"binaries.json").exists() else {}
        old_binaries.update({str(mode): {"cwd": str(pair[0]), "binary": str(pair[1]), "sha256": hashlib.sha256(pair[1].read_bytes()).hexdigest()} for mode,pair in builds.items()})
        (output / "binaries.json").write_text(json.dumps(old_binaries,indent=2))
    # 빌드를 모두 끝낸 뒤 실행 순서를 번갈아 바꾼다.
    for rep in range(args.repetitions):
        modes = list(builds) if rep % 2 == 0 else list(reversed(builds))
        for path in sorted(fixture_paths):
            for work in args.workloads.split(","):
                for mode in modes:
                    source, binary = builds[mode]
                    env = {k:v for k,v in os.environ.items() if not k.startswith("MARU_")}
                    env.update(MARU_EW2_FILE=str(path), MARU_EW2_WORKLOAD=work,MARU_EW2_VERIFY_EACH_EDIT=str(args.verify_each_edit),MARU_EW2_DELAY_MS=str(args.delay_ms))
                    log_path = output / f"{args.prefix}-{rep}-{mode}-{path.name}-{work}.log"
                    with log_path.open("wb") as log:
                        result = subprocess.run(["/usr/bin/time", "-l", str(binary), "--maru-expect-tests=5", "--maru-expect-passed=5"], cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT)
                    print(rep, mode, path.name, work, result.returncode, flush=True)
                    if result.returncode: raise RuntimeError(f"Behavior or measurement failed: {log_path}")

    for path in fixture_paths:
        if hashlib.sha256(path.read_bytes()).hexdigest() != inputs[path.name]["sha256"]:
            raise RuntimeError("Fixture changed during measurement")


if __name__ == "__main__":
    main()
