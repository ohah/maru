#!/usr/bin/env python3
"""동일 제품 바이너리로 배치 크기와 저장 지연을 분리해 반복 측정한다."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import subprocess
import sys

def verify_sample(manifest, binary_sha, files, peer_bytes, lines, delay, output):
    if not manifest['product_passed'] or manifest['binary_sha256'] != binary_sha or manifest.get('optimize') != 'ReleaseFast':
        raise RuntimeError(f'Unverified or changed artifact: {output}')
    if (manifest['batch_open_files'], manifest['batch_peer_bytes'], manifest['disk_padding_lines'], manifest['batch_save_delay_ms']) != (files, peer_bytes, lines, delay):
        raise RuntimeError(f'Changed experiment parameters: {output}')
    m = manifest['metrics']
    for key in ('batch_apply_ns', 'batch_save_ns', 'batch_main_queue_ns'):
        if len(m[key]) != 1:
            raise RuntimeError(f'Ambiguous metric {key}: {output}')
    if not m['batch_plans'] or any(plan != m['batch_plans'][0] for plan in m['batch_plans']):
        raise RuntimeError(f'Preview changed between captures: {output}')
    plan = m['batch_plans'][0]
    symbols = "pub const Widget = struct {\n    pub fn first() void {}\n    pub fn second() void {}\n};\n\n" + "".join(f"pub fn sample{i:02}() void {{\n    const value = {i};\n    _ = value;\n}}\n\n" for i in range(20))
    expected_bytes = len(symbols.encode()) + (files - 1) * (len(b"pub fn sample_peer() void {}\n") + (peer_bytes + 3 if peer_bytes else 0)) + 2 * (12 + 13 * lines)
    # fixture 원문으로 개수·길이를 확인한다. Plan끼리만 비교하면 동일한 누락을 감출 수 있다.
    if plan['files'] != files + 2 or plan['closed'] != 2 or plan['matches'] != files + 21 or plan['input_bytes'] != expected_bytes or plan['output_bytes'] - plan['input_bytes'] != plan['matches']:
        raise RuntimeError(f'Independent fixture oracle mismatch: {output}: {plan}')
    if m['batch_apply_ns'][0] < m['batch_save_ns'][0] or m['batch_main_queue_ns'][0] < m['batch_apply_ns'][0]:
        raise RuntimeError(f'Invalid phase ordering: {output}')
    if m['batch_save_ns'][0] < (files + 2) * delay * 1_000_000:
        raise RuntimeError(f'Missing injected delay: {output}')
    return m

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--repetitions', type=int, default=3)
    args = parser.parse_args()
    if not 2 <= args.repetitions <= 5:
        parser.error('Repetitions must be 2..5')
    app = args.app.resolve()
    root = args.output.resolve()
    repo = Path(__file__).resolve().parents[2]
    if root == repo or repo in root.parents or root.exists():
        parser.error('Use a new output directory outside the repository')
    root.mkdir(parents=True)
    binary_sha = hashlib.sha256(app.read_bytes()).hexdigest()
    cases = [
        ('small-4-files', 2, 0, 5000, 0),
        ('small-34-files', 32, 0, 5000, 0),
        ('small-66-files', 64, 0, 5000, 0),
        ('large-34-files', 32, 262144, 83333, 0),
        ('large-66-files', 64, 262144, 83333, 0),
        ('large-34-files-delay-10ms', 32, 262144, 83333, 10),
        ('near-limit-66-files', 64, 983040, 83333, 0),
    ]
    result = {'scope': 'ReleaseFast product AppKit apply/save/linked Undo; main queue delay is not a frame interval',
              'binary_sha256': binary_sha, 'samples': [], 'summary': []}
    # 조건별로 몰아서 실행하지 않고 매 반복에서 전 조건을 실행해 시간 경과의 영향을 드러낸다.
    for repetition in range(args.repetitions):
        for label, files, peer_bytes, lines, delay in cases:
            output = root / f'{label}-{repetition + 1}'
            command = [sys.executable, str(Path(__file__).with_name('run.py')), '--app', str(app),
                       '--optimize', 'ReleaseFast', '--output', str(output), '--replace-batch', '--disk-files', '2',
                       '--count', '20', '--batch-open-files', str(files), '--batch-peer-bytes', str(peer_bytes),
                       '--disk-padding-lines', str(lines), '--batch-save-delay-ms', str(delay), '--timeout-seconds', '180']
            with (root / f'{label}-{repetition + 1}.log').open('w') as log:
                completed = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT)
            if completed.returncode != 0:
                result['failure'] = {'case': label, 'repetition': repetition + 1, 'output': str(output)}
                (root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
                raise RuntimeError(f'Measurement failed: {output}')
            manifest = json.loads((output / 'manifest.json').read_text())
            m = verify_sample(manifest, binary_sha, files, peer_bytes, lines, delay, output)
            sample = {'case': label, 'repetition': repetition + 1, 'manifest': str(output / 'manifest.json'),
                      'plan': m['batch_plans'][0], 'apply_ms': m['batch_apply_ns'][0] / 1e6,
                      'save_ms': m['batch_save_ns'][0] / 1e6, 'main_queue_ms': m['batch_main_queue_ns'][0] / 1e6,
                      'prepare_ms': m['batch_prepare_ns'][0] / 1e6, 'capture_ms': m['batch_capture_ns'][0] / 1e6,
                      'whole_app_peak_rss_mib': m['peak_rss_bytes'] / 1048576}
            result['samples'].append(sample)
            (root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
            print(json.dumps(sample), flush=True)
    for label, *_ in cases:
        samples = [s for s in result['samples'] if s['case'] == label]
        row = {'case': label, 'plan': samples[0]['plan']}
        for key in ('apply_ms', 'save_ms', 'main_queue_ms', 'prepare_ms', 'capture_ms', 'whole_app_peak_rss_mib'):
            values = [s[key] for s in samples]
            row[key] = {'median': statistics.median(values), 'min': min(values), 'max': max(values)}
        result['summary'].append(row)
    (root / 'results.json').write_text(json.dumps(result, indent=2) + '\n')
    print(root / 'results.json', flush=True)

if __name__ == "__main__":
    main()
