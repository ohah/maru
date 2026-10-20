#!/usr/bin/env python3
"""격리 제품 앱 하나에서 저장 통지만 켜고 끄며 완료 관측을 비교한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import statistics
import subprocess


def once(text, old, new):
    if text.count(old) != 1:
        raise ValueError('Expected exactly one instrumentation anchor: ' + old)
    return text.replace(old, new)


def validate_sample(report, size, delay, mode, deliveries, binary):
    metrics = report['untitled_save_benchmark']
    if (mode not in ['tick', 'event'] or report.get('binary_sha256') != binary
            or report.get('optimize') != 'Debug' or report.get('product_passed') is not True
            or metrics['bytes'] != size or metrics['injected_delay_ms'] != delay
            or (mode == 'tick' and deliveries != 0) or (mode == 'event' and deliveries < 1)):
        raise ValueError('Condition, notification delivery or binary identity mismatch')
    # 완료를 틱이 먼저 수거하면 종료 전 전달이 한 번일 수 있다. 두 번 전달을 강제하지 않는다.
    return metrics


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--source', type=Path, required=True, help='첫 저장 하네스의 준비 source')
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--reuse-prepared', action='store_true', help='이 도구로 이미 계측·빌드한 source를 그대로 재사용')
    args = p.parse_args()
    original = args.source.resolve(strict=True)
    output = args.output.resolve()
    repo = Path(__file__).resolve().parents[1]
    if output.exists() or output == repo or repo in output.parents or output == original or original in output.parents or output in original.parents:
        p.error('Output must be a new directory outside the repository and input source')
    output.mkdir(parents=True)
    if args.reuse_prepared:
        source = original
        wake = source / 'src/platform/macos/app_session/editor/save/wake.zig'
        if 'MARU_SAVE_WAKE_PROBE_MODE' not in wake.read_text() or 'SAVE_WAKE_PROBE delivered=true' not in wake.read_text():
            raise ValueError('Input is not a prepared production-wake probe')
        production = None
    else:
        source = output / 'source'
        subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out', '--exclude=node_modules', '--exclude=references', '--exclude=.env*', str(original) + '/', str(source) + '/'], check=True, timeout=120)
        targets = ['src/platform/macos/app_session/editor/save/wake.zig', 'tools/editor-project-search-app/run.py']
        for name in targets:
            if not (source / name).resolve(strict=True).is_relative_to(source):
                raise ValueError('Instrumentation target escapes source: ' + name)
        wake = source / targets[0]
        production = hashlib.sha256(wake.read_bytes()).hexdigest()
        text = once(wake.read_text(), 'pub fn request() void {', '''pub fn request() void {
        if (std.c.getenv("MARU_SAVE_WAKE_PROBE_MODE")) |mode| if (std.mem.eql(u8, std.mem.span(mode), "tick")) return;''')
        text = once(text, '    if (!queued.swap(false, .acq_rel)) return;', '    if (!queued.swap(false, .acq_rel)) return;\n    std.debug.print("SAVE_WAKE_PROBE delivered=true\\n", .{});')
        wake.write_text(text)
        runner = source / targets[1]
        anchor = '    env = {key: value for key, value in os.environ.items() if not key.startswith("MARU_")}'
        runner.write_text(once(runner.read_text(), anchor, anchor + '\n    env["MARU_SAVE_WAKE_PROBE_MODE"] = os.environ.get("MARU_SAVE_WAKE_PROBE_MODE", "event")'))
        for name, cmd, cwd in [('dependencies', ['mise', 'exec', '--', 'bun', 'install', '--frozen-lockfile'], source / 'web'), ('build', ['mise', 'exec', '--', 'zig', 'build', 'macos-app-bundle', '-j2', '-Doptimize=Debug'], source)]:
            with (output / (name + '.log')).open('w') as log:
                subprocess.run(cmd, cwd=cwd, stdout=log, stderr=subprocess.STDOUT, check=True, timeout=1200)
    app = source / 'zig-out/Maru.app/Contents/MacOS/maru-macos-app'
    runner = source / 'tools/editor-project-search-app/run.py'
    binary = hashlib.sha256(app.read_bytes()).hexdigest()
    identity = dict(binary=binary, wake=hashlib.sha256(wake.read_bytes()).hexdigest(), runner=hashlib.sha256(runner.read_bytes()).hexdigest())
    if args.reuse_prepared:
        if json.loads((source.parent / 'build-identity.json').read_text()) != identity:
            raise ValueError('Prepared source or binary changed after build')
    (output / 'build-identity.json').write_text(json.dumps(identity, indent=2))
    rows = []
    for size in [65536, 1048576]:
        for delay in [0, 200]:
            for sample in range(3):
                for mode in (['tick', 'event'] if sample % 2 == 0 else ['event', 'tick']):
                    label = f'{size}-{delay}-{sample}-{mode}'
                    dest = output / label
                    cmd = ['python3', str(runner), '--untitled-save-benchmark', '--untitled-bytes', str(size), '--untitled-delay-ms', str(delay), '--count', '3', '--app', str(app), '--output', str(dest)]
                    with (output / (label + '.log')).open('w') as log:
                        subprocess.run(cmd, cwd=source, env=dict(os.environ, MARU_SAVE_WAKE_PROBE_MODE=mode), stdout=log, stderr=subprocess.STDOUT, check=True, timeout=180)
                    report = json.loads((dest / 'manifest.json').read_text())
                    deliveries = (dest / 'app.log').read_text().count('SAVE_WAKE_PROBE delivered=true')
                    metrics = validate_sample(report, size, delay, mode, deliveries, binary)
                    if hashlib.sha256(app.read_bytes()).hexdigest() != binary:
                        raise ValueError('Binary changed during sampling: ' + label)
                    rows.append(dict(mode=mode, sample=sample, deliveries=deliveries, manifest=str(dest / 'manifest.json'), multiple_wake_deliveries_observed=deliveries >= 2 if mode == 'event' else False, **metrics))
                    (output / 'samples.json').write_text(json.dumps(rows, indent=2))
                    print(label, metrics['settled_ns'] / 1e6, flush=True)
    groups = []
    for size in [65536, 1048576]:
        for delay in [0, 200]:
            for mode in ['tick', 'event']:
                group = [r for r in rows if r['bytes'] == size and r['injected_delay_ms'] == delay and r['mode'] == mode]
                if len(group) != 3:
                    raise ValueError('Incomplete samples')
                groups.append(dict(bytes=size, delay_ms=delay, mode=mode, samples=3, delivery_counts=[r['deliveries'] for r in group], **{key.removesuffix('_ns') + '_ms': statistics.median(r[key] for r in group) / 1e6 for key in ['call_ns', 'next_event_ns', 'settled_ns']}))
    (output / 'summary.json').write_text(json.dumps(dict(binary_sha256=binary, production_wake_sha256=production, prepared_wake_sha256=hashlib.sha256(wake.read_bytes()).hexdigest(), groups=groups), indent=2))
    print(output, flush=True)


if __name__ == '__main__':
    main()
