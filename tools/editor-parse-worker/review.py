#!/usr/bin/env python3
"""독립 소스 사본에서 실제 파싱 서비스의 결함을 컴파일·실행한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

ROOT = Path(__file__).resolve().parents[2]
LEAF = 'src/platform/macos/app_session/editor/parse/worker.zig'
NATIVE = 'src/syntax/tree_sitter.zig'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--deps', type=Path, required=True)
    parser.add_argument('--cache', type=Path, required=True)
    args = parser.parse_args()
    out, deps = args.output.resolve(), args.deps.resolve()
    if out.exists() or out == ROOT or ROOT in out.parents or not deps.is_dir():
        parser.error('new external output and existing dependencies required')
    out.mkdir(parents=True)
    source = out / 'source'
    source.mkdir()
    tracked = subprocess.check_output(['git', 'ls-files', '-z'], cwd=ROOT).decode().split('\0')
    original = {}
    for name in filter(None, tracked):
        item = ROOT / name
        if not item.is_file():
            continue
        target = source / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item, target)
        if name.startswith('src/') or name in ('build.zig', 'build.zig.zon', 'tools/simple_test_runner.zig'):
            original[name] = sha(item)
    if LEAF not in original:
        raise RuntimeError('stage the new source before snapshotting')
    (source / 'zig-pkg').symlink_to(deps, target_is_directory=True)
    leaf = source / LEAF
    baseline = leaf.read_text()
    native = source / NATIVE
    native_baseline = native.read_text()
    mutants = {
        'native_cancel_ignored': (NATIVE, '            if (token.isRequested()) return true;', '            _ = token.isRequested();'),
        'waiting_not_replaced': (LEAF, '                if (job.basis != null) self.retiring.push(job) else self.returned.push(job);', '                kept.push(job);'),
        'copy_oom_status': (LEAF, '        const bytes = self.snapshot.copyRange(allocator, 0, self.snapshot.byteLen()) catch {\n            self.outcome = .out_of_memory;', '        const bytes = self.snapshot.copyRange(allocator, 0, self.snapshot.byteLen()) catch {\n            self.outcome = .unavailable;'),
        'old_completion_kept': (LEAF, '            if (std.meta.eql(old.tag.input.document, input.document)) state_for_retire.retiring.push(old) else kept.push(old);', '            kept.push(old);'),
        'prepare_rollback': (LEAF, '        const job = self.state.allocator.create(Job) catch |err| {\n            _ = gate.abandon(tag);', '        const job = self.state.allocator.create(Job) catch |err| {\n            gate.* = previous;'),
    }
    env = dict(os.environ, ZIG_LOCAL_PKG_DIR=str(deps))
    command = ['mise', 'exec', '--', 'zig', 'build', 'test-editor-parse-worker', '--cache-dir', str(args.cache.resolve()), '-j2', '--verbose']
    results = []
    try:
        for name in ('control-before', *mutants, 'control-after'):
            changed, changed_native = baseline, native_baseline
            if name in mutants:
                path, before, after = mutants[name]
                text = native_baseline if path == NATIVE else baseline
                if text.count(before) != 1: raise RuntimeError('ambiguous mutation anchor: '+name)
                text = text.replace(before, after)
                if name == 'prepare_rollback':
                    anchor = '        const tag = gate.begin(input) catch |err| {'
                    if text.count(anchor)!=1: raise RuntimeError('ambiguous rollback anchor')
                    text = text.replace(anchor, '        const previous = gate.*;\n'+anchor)
                if path == NATIVE: changed_native = text
                else: changed = text
            leaf.write_text(changed)
            native.write_text(changed_native)
            (out / (name + '.zig')).write_text(changed)
            (out / (name + '-native.zig')).write_text(changed_native)
            with (out / (name + '.log')).open('xb') as log:
                result = subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, timeout=600)
            text = (out / (name + '.log')).read_text()
            binaries = re.findall(r'info\(verbose\): (\S+/test) --maru-expect-tests=23', text)
            if not binaries:
                raise RuntimeError('no actual test execution: ' + name)
            binary = Path(binaries[-1])
            if not binary.is_absolute(): binary = source / binary
            archive = out / (name + '-test')
            shutil.copy2(binary, archive)
            if name in mutants:
                if result.returncode == 0 or not re.search(r'FAIL \(Test(?:UnexpectedResult|ExpectedEqual)\)', text):
                    raise RuntimeError('semantic fault not detected: ' + name)
            elif result.returncode or 'All 23 tests passed.' not in text:
                raise RuntimeError('normal control failed: ' + name)
            results.append({'name': name, 'returncode': result.returncode, 'source_sha256': sha(leaf),
                            'native_sha256': sha(native), 'binary_sha256': sha(archive), 'log_sha256': sha(out / (name + '.log'))})
    finally:
        leaf.write_text(baseline)
        native.write_text(native_baseline)
    if any(sha(source / name) != digest for name, digest in original.items()):
        raise RuntimeError('source restoration or unrelated drift')
    shutil.copy2(__file__, out / 'review.py')
    (out / 'result.json').write_text(json.dumps({'base_head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=ROOT, text=True).strip(),
        'source_sha256': original, 'runner_sha256': sha(Path(__file__)), 'command': command, 'results': results}, indent=2) + '\n')
    print(json.dumps(results, indent=2))

if __name__ == '__main__':
    main()
