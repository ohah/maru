#!/usr/bin/env python3
"""같은 원문으로 기존 전체 순회·제품 증분 접힘을 격리 빌드하고 제품 편집/프레임을 실측한다."""
import argparse
import fcntl
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import shutil


def once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError(f"Expected one anchor: {old[:90]!r}, found {text.count(old)}")
    return text.replace(old, new)


def setup(repo, output, deps, mode):
    source=output/f"source-{mode}"
    subprocess.run(["rsync","-a","--exclude=.git","--exclude=.zig-cache","--exclude=zig-out","--exclude=node_modules","--exclude=zig-pkg","--exclude=references","--exclude=.env*",str(repo)+"/",str(source)+"/"],check=True)
    if not (source/"zig-pkg").exists(): (source/"zig-pkg").symlink_to(deps,target_is_directory=True)
    p=source/"src/platform/macos/app_session/editor/mod.zig"
    text=p.read_text()
    if mode==0:
        text=once(text,"prov.foldSpansCached(self.allocator, &st.folds, doc.file.lines.lines, &spans)","prov.foldSpans(self.allocator, &spans)")
    elif mode!=1: raise ValueError("Only full traversal and production cache are supported")
    text+="\n"+(repo/"tools/editor-fold-product/host.zig.inc").read_text().replace("EW2_PRODUCT_MODE",str(mode))
    p.write_text(text)
    p=source/"build.zig"
    added='''    const production_measure = addProjectTest(b, .{ .root_module = editor_tests.root_module, .filters = &.{".test.EW2 fold measure"} });
    const run_production_measure = b.addRunArtifact(production_measure);
    run_production_measure.setCwd(b.path("."));
    run_production_measure.addArg("--maru-expect-tests=5");
    run_production_measure.addArg("--maru-expect-passed=5");
    b.step("test-editor-fold-measure", "Measure production fold cache and full traversal").dependOn(&run_production_measure.step);
'''
    p.write_text(once(p.read_text(),"    const edit_cost_tests =",added+"    const edit_cost_tests ="))
    names=("src/syntax/tree_sitter.zig","src/syntax/folds.zig","src/platform/macos/app_session/editor/mod.zig","src/platform/macos/app_session/editor/syntax.zig","build.zig")
    manifest=dict(head=subprocess.check_output(["git","rev-parse","HEAD"],cwd=repo,text=True).strip(),mode=mode,
        original_sha256={name:hashlib.sha256((repo/name).read_bytes()).hexdigest() for name in names},
        instrumented_sha256={name:hashlib.sha256((source/name).read_bytes()).hexdigest() for name in names})
    (output/f"setup-{mode}.json").write_text(json.dumps(manifest,indent=2)+"\n")
    return source


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--fixtures",type=Path)
    parser.add_argument("--deps", type=Path, required=True)
    parser.add_argument("--modes", default="0,1")
    parser.add_argument("--repetitions", type=int, default=3)
    parser.add_argument("--resume", action="store_true")
    parser.add_argument("--refresh", action="store_true")
    parser.add_argument("--run-only", action="store_true")
    parser.add_argument("--verify-each-edit", type=int, choices=(0,1), default=0)
    parser.add_argument("--prefix", default="run")
    parser.add_argument("--workloads", default="typing,slow,structure,paste,undo,shared,folded,command")
    args = parser.parse_args()
    if not args.prefix or Path(args.prefix).name != args.prefix or args.prefix in (".",".."): parser.error("Use a simple log prefix")
    repo = Path(__file__).resolve().parents[2]
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
    if args.fixtures:
        for name in ("flat-3000.zig","flat-15000.zig","flat-50000.zig","real-build.zig","real-host.swift"):
            target=fixtures/name
            if not target.exists(): shutil.copyfile(args.fixtures/name,target)
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
    if args.resume and (output/"inputs.json").exists() and json.loads((output/"inputs.json").read_text())!=inputs:
        raise RuntimeError("Pinned fixtures changed before resuming")
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
            env.update(MARU_EW2_FILE=str(fixtures / "flat-3000.zig"), MARU_EW2_WORKLOAD="typing",MARU_EW2_VERIFY_EACH_EDIT="1")
            print("build", mode, flush=True)
            with log_path.open("wb") as log:
                result = subprocess.run(["mise", "exec", "--", "zig", "build", "test-editor-fold-measure", "-Doptimize=ReleaseFast", "-j2", "--verbose"], cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT)
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
                    env.update(MARU_EW2_FILE=str(path), MARU_EW2_WORKLOAD=work,MARU_EW2_VERIFY_EACH_EDIT=str(args.verify_each_edit))
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
