#!/usr/bin/env python3
"""기준 커밋과 현재 제품을 별도 사본에서 빌드해 실제 Metal PNG를 대조한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import shutil

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument('--output', type=Path, required=True)
parser.add_argument('--baseline', default='711591ffa99236fafe024e22eaceae3be0b671f3')
parser.add_argument('--deps', type=Path, required=True)
args = parser.parse_args()
repo = Path(__file__).resolve().parents[2]
root = args.output.resolve()
if root.exists() or repo == root or repo in root.parents or not args.deps.resolve().is_dir():
    parser.error('저장소 밖의 새 경로와 유효한 의존성이 필요합니다')
root.mkdir(parents=True)
sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
fixture = Path(__file__).with_name('capture.zig.inc')
(root / 'capture.py').write_bytes(Path(__file__).read_bytes())
(root / 'capture.zig.inc').write_bytes(fixture.read_bytes())
records = {}
for variant in ('before', 'after'):
    out = root / variant
    source = out / 'source'
    out.mkdir()
    source.mkdir()
    if variant == 'before':
        archive = out / 'source.tar'
        with archive.open('xb') as stream:
            subprocess.run(['git', 'archive', '--format=tar', args.baseline], cwd=repo, stdout=stream, check=True)
        subprocess.run(['tar', '-xf', str(archive), '-C', str(source)], check=True)
        archive.unlink()
    else:
        subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=zig-pkg', '--exclude=references', '--exclude=.env*', str(repo)+'/', str(source)+'/'], check=True)
    (source / 'zig-pkg').symlink_to(args.deps.resolve(), target_is_directory=True)
    original = {str(p.relative_to(source)): sha(p) for p in (source / 'src').rglob('*') if p.is_file()}
    build = source / 'build.zig'
    original_build = sha(build)
    text = build.read_text()
    anchor = '    const shared_editor_tests = addProjectTest(b, .{'
    assert text.count(anchor) == 1
    code = '''    editor_test_module.addIncludePath(b.path("src/platform/macos"));
    inline for (.{ "chrome_lab_smoke.m", "maru_metal_renderer.m" }) |file|
        editor_test_module.addCSourceFile(.{ .file = b.path("src/platform/macos/" ++ file), .flags = &.{ "-fobjc-arc", "-fno-sanitize=undefined" } });
    const color_capture = addProjectTest(b, .{ .root_module = editor_tests.root_module, .filters = &.{".test.visible color GPU capture"} });
    const run_color_capture = b.addRunArtifact(color_capture);
    run_color_capture.setCwd(b.path("."));
    run_color_capture.has_side_effects = true;
    b.step("test-visible-color-capture", "Capture product color coverage").dependOn(&run_color_capture.step);
'''
    build.write_text(text.replace(anchor, code + anchor))
    host = source / 'src/platform/macos/app_session/editor/mod.zig'
    host.write_text(host.read_text() + '\n' + fixture.read_text().replace('__ARTIFACT_DIR__', json.dumps(str(out))[1:-1]))
    observed = {str(p.relative_to(source)): sha(p) for p in (source / 'src').rglob('*') if p.is_file()}
    build_hash = sha(build)
    record = {'source': original, 'original_build': original_build, 'instrumented_source': observed, 'instrumented_build': build_hash}
    (out / 'prebuild.json').write_text(json.dumps(record, indent=2)+'\n')
    env = {k: v for k, v in os.environ.items() if not k.startswith('MARU_')}
    with (out / 'build.log').open('xb') as stream:
        subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-visible-color-capture', '-Doptimize=ReleaseFast', '-j2', '--summary', 'all', '--verbose'], cwd=source, env=env, stdout=stream, stderr=subprocess.STDOUT, check=True)
    log = (out / 'build.log').read_text()
    observations = re.findall(r'COLOR_GPU first=(\d+) rows=(\d+) queried=(\d+) body_y=(-?\d+) cell_h=(\d+) status=0 png=1', log)
    assert len(observations) == 1 and 'FAIL (' not in log
    observation = tuple(map(int, observations[0]))
    assert observation[0] == 31 and observation[1] > 256
    if variant == 'before':
        assert observation[2] == 256
    else:
        assert observation[1] <= observation[2] <= observation[1] + 2
    assert (out / 'frame.png').read_bytes().startswith(b'\x89PNG\r\n\x1a\n')
    assert all(sha(source / name) == digest for name, digest in observed.items()) and sha(build) == build_hash
    executables = re.findall(r'info\(verbose\): (?:cd \. && )?(\./\.zig-cache/o/[0-9a-f]+/test)(?: |$)', log, re.MULTILINE)
    assert executables, '실행 파일 경로 누락'
    shutil.copy2(source / executables[-1], out / 'test')
    records[variant] = {'binary_sha256': sha(out / 'test'), 'observations': observation, 'png_sha256': sha(out / 'frame.png'), 'ppm_sha256': sha(out / 'frame.ppm'), 'log_sha256': sha(out / 'build.log')}
    print(variant, observation, 'PASS', flush=True)
assert records['before']['png_sha256'] != records['after']['png_sha256']
assert records['before']['observations'][:2] == records['after']['observations'][:2]
assert records['before']['observations'][3:] == records['after']['observations'][3:]
def pixels(path):
    magic, dimensions, maximum, data = path.read_bytes().split(b'\n', 3)
    assert (magic, dimensions, maximum) == (b'P6', b'800 4800', b'255')
    assert len(data) == 800 * 4800 * 3
    return data
before = pixels(root / 'before/frame.ppm')
after = pixels(root / 'after/frame.ppm')
stride = 800 * 3
changed_rows = [y for y in range(4800) if before[y*stride:(y+1)*stride] != after[y*stride:(y+1)*stride]]
assert changed_rows
_, _, _, body_y, cell_h = records['before']['observations']
first_missing = body_y + 256 * cell_h
assert min(changed_rows) >= first_missing - cell_h
assert max(changed_rows) > first_missing
pixel_proof = {'changed_rows': len(changed_rows), 'first_changed_y': min(changed_rows), 'last_changed_y': max(changed_rows), 'unchanged_prefix_through_y': first_missing - cell_h}

(root / 'result.json').write_text(json.dumps({'complete': True, 'baseline': args.baseline, 'producer_sha256': sha(Path(__file__)), 'fixture_sha256': sha(fixture), 'frames': records, 'pixels': pixel_proof}, indent=2)+'\n')
