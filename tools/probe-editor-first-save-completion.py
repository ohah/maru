#!/usr/bin/env python3
"""준비한 AppKit 사본에서 첫 저장의 구간과 이벤트 통지 유무를 비교한다. 제품 소스는 바꾸지 않는다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import statistics
import subprocess


def replace_once(text, old, new):
    if text.count(old) != 1:
        raise ValueError(f'Expected one injection anchor: {old!r}')
    return text.replace(old, new, 1)


def parse_phases(log):
    points = {}
    for line in log.splitlines():
        if 'UNTITLED_PHASE' not in line:
            continue
        match = re.fullmatch(r'UNTITLED_PHASE name=(\w+) ns=(\d+)', line)
        if not match:
            raise ValueError('Malformed phase record')
        name, raw = match.groups()
        if name in ('tick_begin', 'tick_end'):
            continue
        if name in points:
            raise ValueError('Duplicate phase')
        points[name] = int(raw)
    required = {'request', 'prepare_begin', 'prepare_end', 'worker_submitted', 'worker_enter',
                'worker_done', 'collected', 'adopted', 'postprocess_end', 'finished', 'probe_ready'}
    if set(points) != required:
        raise ValueError('Missing or unknown phase')
    # 스레드가 먼저 실행될 수 있으므로 worker_enter와 submitted의 로그 순서를 강제하지 않는다.
    for order in [
        ['request', 'prepare_begin', 'prepare_end', 'worker_submitted', 'collected'],
        ['prepare_end', 'worker_enter', 'worker_done', 'collected'],
        ['collected', 'adopted', 'postprocess_end', 'finished', 'probe_ready'],
    ]:
        if any(points[a] > points[b] for a, b in zip(order, order[1:])):
            raise ValueError('Contradictory phase clocks')
    intervals = {'start_wait': ('request', 'prepare_begin'), 'prepare': ('prepare_begin', 'prepare_end'),
                 'worker': ('worker_enter', 'worker_done'), 'completion_wait': ('worker_done', 'collected'),
                 'apply': ('collected', 'finished'), 'after_apply': ('finished', 'probe_ready'),
                 'model_ready': ('request', 'probe_ready')}
    return {key + '_ns': points[end] - points[start] for key, (start, end) in intervals.items()}


HELPER = '''
pub fn completionProbeMark(name: []const u8) void {
    if (std.c.getenv("MARU_UNTITLED_BENCHMARK") == null) return;
    std.debug.print("UNTITLED_PHASE name={s} ns={d}\\n", .{name, std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).nanoseconds});
}
extern fn maru_untitled_phase_wake() callconv(.c) void;
'''


def instrument(source):
    if (source / 'src/platform/macos/app_session/editor/save/wake.zig').exists():
        raise ValueError('Historical probe requires a source before production save wake; use probe-editor-save-wake.py for current sources')
    # rsync는 symlink를 보존한다. 계측 대상이 사본 밖을 가리키면 원본을 수정하지 않고 거절한다.
    names = ['app_session/editor/save/as.zig', 'app_session/editor/save/worker.zig',
             'app_session.zig', 'app_session/debug_fixtures.zig', 'MaruAppHost.swift', 'coretext_smoke.m']
    targets = [source / 'src/platform/macos' / name for name in names]
    targets.append(source / 'tools/editor-project-search-app/run.py')
    if any(not target.resolve().is_relative_to(source.resolve()) for target in targets):
        raise ValueError('Instrumentation target escapes source copy')
    actor = source / 'src/platform/macos/app_session/editor/save/as.zig'
    text = actor.read_text()
    if 'UNTITLED_PHASE' in text:
        raise ValueError('Source already instrumented')
    for old, new in [
        ('    firstSaveFallible(session, term, path, overwriting) catch |err| {', '    completionProbeMark("request");\n    firstSaveFallible(session, term, path, overwriting) catch |err| {'),
        ('    };\n}\nfn firstSaveFallible(', '    };\n    if (std.c.getenv("MARU_UNTITLED_EVENT_WAKE") != null) maru_untitled_phase_wake();\n}\nfn firstSaveFallible('),
        ('fn prepare(op: *Operation, view: View) !void {', 'fn prepare(op: *Operation, view: View) !void {\n    completionProbeMark("prepare_begin");\n    defer completionProbeMark("prepare_end");'),
        ('        op.prepared.?.work = null;', '        completionProbeMark("worker_submitted");\n        op.prepared.?.work = null;'),
        ('        if (service.?.take()) |result| {', '        if (service.?.take()) |result| {\n            completionProbeMark("collected");'),
        ('            op.lease.owner.get(op.lease).?.notifications.lsp_version +|= 1;', '            completionProbeMark("adopted");\n            op.lease.owner.get(op.lease).?.notifications.lsp_version +|= 1;'),
        ('            finish(op, true, null);', '            completionProbeMark("postprocess_end");\n            finish(op, true, null);\n            completionProbeMark("finished");'),
    ]:
        text = replace_once(text, old, new)
    actor.write_text(text + HELPER)
    worker = source / 'src/platform/macos/app_session/editor/save/worker.zig'
    text = replace_once(worker.read_text(), '    fn execute(self: *Job) void {', '    fn execute(self: *Job) void {\n        completionProbeMark("worker_enter");')
    text = replace_once(text, '        self.done.store(true, .release);', '        completionProbeMark("worker_done");\n        self.done.store(true, .release);\n        if (std.c.getenv("MARU_UNTITLED_EVENT_WAKE") != null) maru_untitled_phase_wake();')
    worker.write_text(text + HELPER)
    app = source / 'src/platform/macos/app_session.zig'
    app.write_text(replace_once(app.read_text(), '    pub fn tick(self: *AppSession) !FrameSummary {', '''    pub fn tick(self: *AppSession) !FrameSummary {
        const measured_tick = @import("app_session/editor/save/as.zig").pending() != 0;
        if (measured_tick) @import("app_session/editor/save/as.zig").completionProbeMark("tick_begin");
        defer if (measured_tick) @import("app_session/editor/save/as.zig").completionProbeMark("tick_end");'''))
    fixture = source / 'src/platform/macos/app_session/debug_fixtures.zig'
    text = replace_once(fixture.read_text(), '    if (@import("editor/save/as.zig").pending() != 0) return 0;', '    if (@import("editor/save/as.zig").pending() != 0) return 0;\n    @import("editor/save/as.zig").completionProbeMark("probe_ready");')
    fixture.write_text(text + '\nexport fn maru_untitled_phase_poll() callconv(.c) void { @import("editor/save/as.zig").poll(); }\n')
    host = source / 'src/platform/macos/MaruAppHost.swift'
    host.write_text(host.read_text() + '''
@_silgen_name("maru_untitled_phase_poll") private func phaseSavePoll()
@_cdecl("maru_untitled_phase_wake") func phaseSaveWake() {
    DispatchQueue.main.async {
        FileHandle.standardError.write(Data("UNTITLED_EVENT_WAKE delivered=true\\n".utf8))
        phaseSavePoll()
    }
}
''')
    # 독립 ABI 링크는 Swift를 포함하지 않는다. 실험 앱은 strong Swift 심볼과 실제 전달 로그를 검사한다.
    bridge = source / 'src/platform/macos/coretext_smoke.m'
    bridge.write_text(bridge.read_text() + '\n__attribute__((weak)) void maru_untitled_phase_wake(void) {}\n')
    runner = source / 'tools/editor-project-search-app/run.py'
    anchor = '    env = {key: value for key, value in os.environ.items() if not key.startswith("MARU_")}'
    runner.write_text(replace_once(runner.read_text(), anchor, anchor + '\n    if os.environ.get("MARU_UNTITLED_EVENT_WAKE") == "1": env["MARU_UNTITLED_EVENT_WAKE"] = "1"'))


def summarize(root):
    binary = set()
    reports = []
    for mode in ('tick', 'event'):
        rows = json.loads((root / mode / 'samples.json').read_text())
        if len(rows) != 12:
            raise ValueError('Expected twelve samples per mode')
        for row in rows:
            if type(row['bytes']) is not int or row['bytes'] not in (65536, 1048576) or type(row['injected_delay_ms']) is not int or row['injected_delay_ms'] not in (0, 200):
                raise ValueError('Unexpected sample condition')
            manifest = Path(row['manifest'])
            report = json.loads(manifest.read_text())
            log = (manifest.parent / 'app.log').read_text()
            deliveries = log.count('UNTITLED_EVENT_WAKE delivered=true')
            if (mode == 'tick' and deliveries) or (mode == 'event' and deliveries < 2):
                raise ValueError('Unexpected event transport evidence')
            digest = report['binary_sha256']
            if not isinstance(digest, str) or re.fullmatch(r'[0-9a-f]{64}', digest) is None:
                raise ValueError('Invalid binary identity')
            binary.add(digest)
            phases = parse_phases(log)
            if phases['worker_ns'] < row['injected_delay_ms'] * 1_000_000:
                raise ValueError('Injected delay missing from worker phase')
            reports.append(dict(mode=mode, manifest=str(manifest), bytes=row['bytes'], delay_ms=row['injected_delay_ms'],
                                deliveries=deliveries, call_ns=row['call_ns'], next_ns=row['next_event_ns'],
                                settled_ns=row['settled_ns'], **phases))
    if len(binary) != 1:
        raise ValueError('Counterfactual must use one binary')
    groups = []
    for mode in ('tick', 'event'):
        for size in (65536, 1048576):
            for delay in (0, 200):
                rows = [row for row in reports if (row['mode'], row['bytes'], row['delay_ms']) == (mode, size, delay)]
                if len(rows) != 3:
                    raise ValueError('Expected three samples per condition')
                metrics = {key[:-3] + '_ms': statistics.median(row[key] for row in rows) / 1e6
                           for key in rows[0] if key.endswith('_ns')}
                groups.append(dict(mode=mode, bytes=size, delay_ms=delay, medians=metrics))
    (root / 'completion-phases.json').write_text(json.dumps(dict(scope='Debug model-ready observation; first saved paint is outside this metric', probe_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(), binary_sha256=next(iter(binary)), samples=reports, groups=groups), indent=2) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path, required=True, help='기존 첫 저장 측정 실행기가 준비한 source 사본')
    parser.add_argument('--output', type=Path, required=True, help='저장소 밖의 새 디렉터리')
    args = parser.parse_args()
    original, root = args.source.resolve(), args.output.resolve()
    repo = Path(__file__).resolve().parents[1]
    if root == original or original in root.parents or root == repo or repo in root.parents or root.exists():
        parser.error('Output must be new and outside source/repository')
    if 'maru_untitled_benchmark_probe' not in (original / 'src/platform/macos/MaruAppHost.swift').read_text():
        parser.error('Use a source prepared by the untitled benchmark runner')
    root.mkdir(parents=True)
    source = root / 'source'
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.codex-worktrees', '--exclude=.env*', str(original) + '/', str(source) + '/'], check=True)
    instrument(source)
    if not (source / 'web').resolve().is_relative_to(source.resolve()):
        raise ValueError('Build directory escapes source copy')
    for command, cwd, name in [(['mise', 'exec', '--', 'bun', 'install', '--frozen-lockfile'], source / 'web', 'dependencies'),
                                (['mise', 'exec', '--', 'zig', 'build', 'macos-app-bundle', '-j2', '-Doptimize=Debug'], source, 'build')]:
        with (root / (name + '.log')).open('w') as log:
            subprocess.run(command, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1200)
    app = source / 'zig-out/Maru.app/Contents/MacOS/maru-macos-app'
    for mode in ('tick', 'event'):
        env = {key: value for key, value in os.environ.items() if not key.startswith('MARU_')}
        if mode == 'event':
            env['MARU_UNTITLED_EVENT_WAKE'] = '1'
        command = ['python3', str(source / 'tools/measure-editor-untitled-save.py'), '--app', str(app), '--output', str(root / mode)]
        with (root / (mode + '.log')).open('w') as log:
            subprocess.run(command, cwd=source, env=env, stdout=log, stderr=subprocess.STDOUT, check=True)
    summarize(root)
    print(root / 'completion-phases.json')


if __name__ == '__main__':
    main()
