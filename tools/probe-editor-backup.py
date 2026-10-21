#!/usr/bin/env python3
"""격리한 소스 사본에서 실제 동기 백업의 메인 호출 비용을 잰다."""
import argparse
import hashlib
import json
from pathlib import Path
import platform
import re
import statistics
import subprocess
import tempfile


def once(path, old, new):
    text = path.read_text()
    if text.count(old) != 1:
        raise ValueError('Non-unique probe anchor: ' + old)
    path.write_text(text.replace(old, new))


def ensure_hashes(root, hashes):
    # assert는 python -O에서 사라지므로 측정 신원 검증에는 쓰지 않는다.
    if not all(hashlib.sha256((root / p).read_bytes()).hexdigest() == h for p, h in hashes.items()):
        raise ValueError('Source identity mismatch')


def mutation_failed(text, returncode, case):
    # 다른 검사 실패나 실행 도중 중단을 목표 회귀의 검출로 세지 않는다.
    headers = list(re.finditer(r'(?m)^(\d+)/18 [^\n]*', text))
    summary = re.findall(r'(?m)^(\d+) passed; 0 skipped; (\d+) failed\.$', text)
    if (returncode != 1 or [int(h[1]) for h in headers] != list(range(1, 19))
            or len(summary) != 1 or sum(map(int, summary[0])) != 18 or int(summary[0][1]) == 0):
        return False
    for i, header in enumerate(headers):
        if f'.test.U4a-{case} ' not in header[0]:
            continue
        end = headers[i + 1].start() if i + 1 < len(headers) else len(text)
        return re.search(r'FAIL \((TestUnexpectedResult|TestExpectedEqual|TestExpectedError)\)', text[header.start():end]) is not None
    return False


def validate(rows):
    expected = {(route, size, action, sample)
                for route in ['untitled', 'local-id']
                for size in [65536, 1048576, 8388608]
                for action, samples in [('first', [0]), ('rewrite', [1, 2, 3]), ('drop', [0])]
                for sample in samples}
    seen = set()
    for row in rows:
        if (type(row['bytes']) is not int or type(row['sample']) is not int
                or type(row['route']) is not str or type(row['action']) is not str):
            raise ValueError('Invalid condition type')
        key = (row['route'], row['bytes'], row['action'], row['sample'])
        if key not in expected or key in seen or row['verified'] is not True:
            raise ValueError('Missing, duplicated or unverified condition')
        seen.add(key)
        total, write, encode, read = (row[k] for k in ['total_ns', 'write_ns', 'encode_ns', 'read_ns'])
        if any(type(n) is not int or n < 0 for n in [total, write, encode, read]) or not total >= write >= encode + read:
            raise ValueError('Invalid timing hierarchy')
        if row['action'] != 'drop' and (write == 0 or encode == 0):
            raise ValueError('Write or encoding was not measured')
        if (row['action'] == 'drop' and (write != 0 or encode != 0 or read != 0)
                or row['route'] == 'untitled' and read != 0
                or row['action'] == 'first' and read != 0
                or row['route'] == 'local-id' and row['action'] == 'rewrite' and read == 0):
            raise ValueError('Stage does not match the product route')
    if seen != expected:
        raise ValueError('Incomplete matrix')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--optimize', choices=['Debug', 'ReleaseFast'], default='ReleaseFast')
    parser.add_argument('--adversarial', action='store_true', help='백업 계약을 깨는 다섯 변이와 원복 대조군도 실행')
    args = parser.parse_args()
    if platform.system() != 'Darwin':
        parser.error('macOS is required')
    root = Path(__file__).resolve().parents[1]
    output = Path(tempfile.mkdtemp(prefix='maru-backup-probe-'))
    source = output / 'source'
    print(output, flush=True)
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', str(root) + '/', str(source) + '/'], check=True, timeout=120)
    base = 'src/platform/macos/app_session/editor/'
    files = [base + 'backup.zig', base + 'recovery_store.zig', base + 'mod.zig', 'src/session/editor/backup.zig', 'build.zig']
    digest = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    provenance = dict(head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=root, text=True).strip(), optimize=args.optimize, allocator='std.heap.smp_allocator', platform=platform.platform(), original={p: digest(root / p) for p in files}, fixture=digest(root / 'tools/editor-backup-probe.zig.inc'))
    ensure_hashes(source, provenance['original'])
    mod = source / (base + 'mod.zig')
    mod.write_text(mod.read_text() + '\n' + (root / 'tools/editor-backup-probe.zig.inc').read_text())
    # 측정 지점은 사본에만 둔다. 일반 빌드와 기본 CI에는 계측 비용이 없다.
    encoder = source / 'src/session/editor/backup.zig'
    for signature in ['pub fn encode(allocator: std.mem.Allocator, doc: Doc, content: []const u8) std.mem.Allocator.Error![]u8 {', 'pub fn encodeRecovery(allocator: std.mem.Allocator, id: recovery.Id, doc: Doc.Path, content: []const u8) ParseError![]u8 {']:
        once(encoder, signature, signature + '\n    const probe_start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;\n    defer { probe_encode_ns += std.Io.Clock.awake.now(std.testing.io).nanoseconds - probe_start; probe_encode_calls += 1; }')
    encoder.write_text(encoder.read_text() + '\npub var probe_encode_ns: i128 = 0;\npub var probe_encode_calls: usize = 0;\n')
    for file, signature, counter in [
        (base + 'backup.zig', 'fn writeCurrent(self: *AppSession, term: *Term, doc: backup.Doc, content: []const u8) bool {', 'probe_write_ns'),
        (base + 'recovery_store.zig', '    fn readFd(self: *Reservation, fd: c.fd_t) !Record {', 'probe_read_ns'),
    ]:
        path = source / file
        once(path, signature, signature + '\n        const probe_start = std.Io.Clock.awake.now(std.testing.io).nanoseconds;\n        defer ' + counter + ' += std.Io.Clock.awake.now(std.testing.io).nanoseconds - probe_start;')
        path.write_text(path.read_text() + '\npub var ' + counter + ': i128 = 0;\n')
    once(source / 'build.zig', '.filters = &.{"SAVEWAKE"},', '.filters = &.{ "BACKUPPROBE", ".test.U4a-" },')
    for count in ['tests', 'passed']:
        once(source / 'build.zig', f'run_save_wake_tests.addArg("--maru-expect-{count}=12")', f'run_save_wake_tests.addArg("--maru-expect-{count}=19")')
    provenance['instrumented'] = {p: digest(source / p) for p in files}
    (output / 'provenance.json').write_text(json.dumps(provenance, indent=2))
    with (output / 'run.log').open('w') as log:
        subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-save-wake', '-j2', '-Doptimize=' + args.optimize], cwd=source, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=900)
    rows = [json.loads(line.removeprefix('BACKUP_PROBE ')) for line in (output / 'run.log').read_text().splitlines() if line.startswith('BACKUP_PROBE ')]
    validate(rows)
    (output / 'samples.json').write_text(json.dumps(rows, indent=2))
    groups = []
    for route in ['untitled', 'local-id']:
        for size in [65536, 1048576, 8388608]:
            for action in ['first', 'rewrite', 'drop']:
                selected = [r for r in rows if (r['route'], r['bytes'], r['action']) == (route, size, action)]
                groups.append(dict(route=route, bytes=size, action=action, samples=len(selected), median_ms={k: statistics.median(r[k] for r in selected) / 1e6 for k in ['total_ns', 'write_ns', 'encode_ns', 'read_ns']}))
    (output / 'summary.json').write_text(json.dumps(groups, indent=2))
    if args.adversarial:
        # 큰 문서 준비를 매번 반복하지 않고 제품의 기존 실패·주기·삭제 회귀를 대상으로 삼는다.
        once(source / 'build.zig', '.filters = &.{ "BACKUPPROBE", ".test.U4a-" },', '.filters = &.{".test.U4a-"},')
        for count in ['tests', 'passed']:
            once(source / 'build.zig', f'run_save_wake_tests.addArg("--maru-expect-{count}=19")', f'run_save_wake_tests.addArg("--maru-expect-{count}=18")')
        path = source / (base + 'backup.zig')
        original = path.read_bytes()
        variants = [
            ('ignore-debounce', 'if (now_ns < term.rt.editorDocument().notifications.backup_due_ns) continue;', 'if (now_ns < term.rt.editorDocument().notifications.backup_due_ns and false) continue;'),
            ('all-documents-per-tick', '                settle(self, term);\n                return;', '                settle(self, term);'),
            ('lost-publication-state', 'if (writeCurrent(self, term, doc, opened.file.content)) {', 'if (writeCurrent(self, term, doc, opened.file.content) and false) {'),
            ('lost-retry', '        term.rt.editorDocument().notifications.backup_dirty = true;\n        term.rt.editorDocument().notifications.backup_due_ns', '        term.rt.editorDocument().notifications.backup_dirty = false;\n        term.rt.editorDocument().notifications.backup_due_ns'),
            ('skipped-deletion', 'if (!term.rt.editorDocument().notifications.backup_on_disk) return;', 'if (term.kind == .editor) return;'),
        ]
        results = []
        targets = {'ignore-debounce': 1, 'all-documents-per-tick': 13, 'lost-publication-state': 1, 'lost-retry': 10, 'skipped-deletion': 3}
        for label, old, new in variants + [('restored', None, None)]:
            try:
                if old is not None:
                    once(path, old, new)
                with (output / (label + '.log')).open('w') as log:
                    result = subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'test-editor-save-wake', '-j2', '-Doptimize=' + args.optimize], cwd=source, stdout=log, stderr=subprocess.STDOUT, timeout=900)
                text = (output / (label + '.log')).read_text()
                semantic = old is not None and mutation_failed(text, result.returncode, targets[label])
                passed = result.returncode == 0 if old is None else result.returncode != 0 and semantic
                results.append(dict(name=label, exit=result.returncode, semantic_failure=semantic, passed=passed))
                (output / 'adversarial.json').write_text(json.dumps(results, indent=2))
                print(label, 'PASS' if passed else 'FAIL', flush=True)
                if not passed:
                    raise RuntimeError('Mutation or restored control failed: ' + label)
            finally:
                path.write_bytes(original)
                if path.read_bytes() != original:
                    raise ValueError('Mutation restoration failed')
    ensure_hashes(root, provenance['original'])
    print(json.dumps(groups, indent=2))
    print(output, flush=True)


if __name__ == '__main__':
    main()
