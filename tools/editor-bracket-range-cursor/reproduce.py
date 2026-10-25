#!/usr/bin/env python3
"""고정 입력에서 byte cursor seek와 실제 자식 범위를 대조한다. 제품 소스는 바꾸지 않는다."""
import argparse
import hashlib
import json
from pathlib import Path
import subprocess

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--deps', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
out = args.output.resolve()
if out.exists() or out == repo or repo in out.parents:
    parser.error('저장소 밖의 새 출력 경로가 필요합니다')
src = out / 'source'
src.mkdir(parents=True)
subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=zig-pkg', '--exclude=.env*', str(repo) + '/', str(src) + '/'], check=True)
(src / 'zig-pkg').symlink_to(args.deps.resolve(), target_is_directory=True)
p = src / 'src/syntax/tree_sitter.zig'
fixture = Path(__file__).with_name('padding_fixture.zig.in')
p.write_text(p.read_text() + '\n' + fixture.read_text())
p = src / 'build.zig'
s = p.read_text()
anchor = '    const bracket_edit_tests = addProjectTest'
assert s.count(anchor) == 1
s = s.replace(anchor, '''    const cursor_diag = addProjectTest(b, .{ .root_module = syntax_mod, .filters = &.{"cursor padding diagnostic"} });
    const run_cursor_diag = b.addRunArtifact(cursor_diag);
    run_cursor_diag.addArg("--maru-expect-tests=2");
    run_cursor_diag.addArg("--maru-expect-passed=2");
    b.step("test-cursor-padding-diagnostic", "Check the byte cursor padding counterexample").dependOn(&run_cursor_diag.step);
''' + anchor)
p.write_text(s)
sha = lambda p: hashlib.sha256(p.read_bytes()).hexdigest()
proof = {'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(), 'source': {str(p.relative_to(src)): sha(p) for p in (src / 'src').rglob('*') if p.is_file()}, 'build': sha(src / 'build.zig'), 'generator': sha(Path(__file__)), 'fixture': sha(fixture)}
(out / 'prebuild.json').write_text(json.dumps(proof, indent=2) + '\n')
with (out / 'run.log').open('xb') as stream:
    code = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-cursor-padding-diagnostic', '-j2', '--summary', 'all'], cwd=src, stdout=stream, stderr=subprocess.STDOUT).returncode
(out / 'result.json').write_text(json.dumps({'exit': code, 'log_sha256': sha(out / 'run.log')}, indent=2) + '\n')
raise SystemExit(code)
