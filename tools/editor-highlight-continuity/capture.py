#!/usr/bin/env python3
"""이전/후보의 동일 입력을 제품 Metal 경로로 렌더한다. 사용자 앱과 설정은 건드리지 않는다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', required=True, type=Path)
p.add_argument('--baseline', required=True)
p.add_argument('--deps', required=True, type=Path)
p.add_argument('--cache', required=True, type=Path)
a = p.parse_args()
repo = Path(__file__).resolve().parents[2]
root = a.output.resolve()
if root.exists() or repo == root or repo in root.parents or not a.deps.is_dir():
    p.error('저장소 밖의 새 경로와 의존성 디렉터리가 필요합니다')
root.mkdir(parents=True)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
fixture = Path(__file__).with_name('capture.zig.inc').read_text()
records = {}
for variant in ('before', 'after'):
    out = root / variant
    source = out / 'source'
    source.mkdir(parents=True)
    if variant == 'before':
        archive = out / 'source.tar'
        with archive.open('xb') as f:
            subprocess.run(['git', 'archive', '--format=tar', a.baseline], cwd=repo, stdout=f, check=True)
        subprocess.run(['tar', '-xf', str(archive), '-C', str(source)], check=True)
        archive.unlink()
    else:
        subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=zig-pkg', '--exclude=references', '--exclude=.env*', str(repo)+'/', str(source)+'/'], check=True)
    (source / 'zig-pkg').symlink_to(a.deps.resolve(), target_is_directory=True)
    original = {str(x.relative_to(source)): sha(x) for x in (source / 'src').rglob('*') if x.is_file()}
    build = source / 'build.zig'
    original_build = sha(build)
    text = build.read_text()
    anchor = '    const shared_editor_tests = addProjectTest(b, .{'
    assert text.count(anchor) == 1
    code = '''    editor_test_module.addIncludePath(b.path("src/platform/macos"));
    inline for (.{ "chrome_lab_smoke.m", "maru_metal_renderer.m" }) |file|
        editor_test_module.addCSourceFile(.{ .file = b.path("src/platform/macos/" ++ file), .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" } });
    const highlight_capture = addProjectTest(b, .{ .root_module = editor_tests.root_module, .filters = &.{".test.highlight continuity GPU capture"} });
    const run_highlight_capture = b.addRunArtifact(highlight_capture);
    run_highlight_capture.setCwd(b.path("."));
    run_highlight_capture.has_side_effects = true;
    b.step("test-highlight-capture", "Capture pending highlight continuity").dependOn(&run_highlight_capture.step);
'''
    build.write_text(text.replace(anchor, code + anchor))
    host = source / 'src/platform/macos/app_session/editor/mod.zig'
    host.write_text(host.read_text() + '\n' + fixture.replace('__ARTIFACT_DIR__', json.dumps(str(out))[1:-1]))
    instrumented = {str(x.relative_to(source)): sha(x) for x in (source / 'src').rglob('*') if x.is_file()}
    build_hash = sha(build)
    (out / 'source.json').write_text(json.dumps({'original': original, 'instrumented': instrumented, 'original_build': original_build, 'instrumented_build': build_hash}, indent=2)+'\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith('MARU_')}
    env['ZIG_LOCAL_PKG_DIR'] = str(a.deps.resolve())
    with (out / 'build.log').open('xb') as f:
        subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-highlight-capture', '-Doptimize=ReleaseFast', '--cache-dir', str(a.cache.resolve()), '-j2', '--summary', 'all'], cwd=source, env=env, stdout=f, stderr=subprocess.STDOUT, check=True)
    log = (out / 'build.log').read_text()
    assert 'HIGHLIGHT_GPU ready pending completed captured' in log and 'FAIL (' not in log
    assert all(sha(source / name) == digest for name, digest in instrumented.items()) and sha(build) == build_hash
    records[variant] = {name: sha(out / (name+'.png')) for name in ('ready', 'pending', 'completed')}
    print(variant, 'PASS', flush=True)
# 완료 화면은 동일해야 하며, 차이는 의도한 대기 화면에 있어야 한다.
assert records['before']['ready'] == records['after']['ready']
assert records['before']['completed'] == records['after']['completed']
assert records['before']['pending'] != records['after']['pending']
(root / 'verification.json').write_text(json.dumps({'baseline': a.baseline, 'candidate_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(), 'candidate_dirty': subprocess.check_output(['git', 'status', '--porcelain'], cwd=repo, text=True), 'images': records}, indent=2)+'\n')
