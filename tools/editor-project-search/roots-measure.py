#!/usr/bin/env python3
"""격리 corpus에서 단일/여러 root worker의 벽시계 시간과 time -l RSS를 비교한다."""
import argparse
import hashlib
import json
import re
import statistics
import subprocess
import tempfile
import time
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--worker', type=Path, required=True)
    parser.add_argument('--rg', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--files', type=int, default=2048)
    parser.add_argument('--bytes', type=int, default=32768)
    parser.add_argument('--samples', type=int, default=3)
    args = parser.parse_args()
    if args.files < 2 or args.bytes < 5 or args.samples < 1:
        raise ValueError('invalid corpus')
    args.output.mkdir(parents=True, exist_ok=True)
    out = Path(tempfile.mkdtemp(prefix='run-', dir=args.output)).resolve()
    root = out / 'corpus'; root.mkdir()
    left, right = root / 'left', root / 'right'; left.mkdir(); right.mkdir()
    body = 'x' * (args.bytes - 5) + '\nfoo\n'
    for i in range(args.files):
        ((left if i < args.files // 2 else right) / f'{i}.txt').write_text(body)
    worker, rg = args.worker.resolve(), args.rg.resolve()
    samples = []
    for mode in ['single', 'workspace']:
        for index in range(args.samples):
            command = [str(worker), str(rg), str(root if mode == 'single' else left), 'foo', '-1', str(64 * 1024 * 1024), '--execution-ms', '30000']
            if mode == 'workspace':
                command += ['--workspace-root', str(right)]
            started = time.perf_counter()
            child = subprocess.Popen(['/usr/bin/time', '-l', *command], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            first_row = None
            summary = None
            count = 0
            for line in child.stdout:
                value = json.loads(line)
                if 'path' in value:
                    if first_row is None:
                        first_row = (time.perf_counter() - started) * 1000
                    count += len(value['ranges'])
                else:
                    summary = value
            error = child.stderr.read()
            code = child.wait(timeout=5)
            elapsed = (time.perf_counter() - started) * 1000
            if code != 0 or summary is None or summary['status'] != 'complete' or count != args.files or summary['matches'] != args.files:
                raise RuntimeError((code, summary, count, error.decode(errors='replace')))
            rss = int(re.search(rb'(\d+)\s+maximum resident set size', error)[1])
            samples.append({'mode': mode, 'sample': index, 'wall_ms': round(elapsed, 2), 'first_row_ms': round(first_row, 2), 'maximum_resident_bytes': rss, 'children_started': summary['stats']['children_started']})
    report = {'files': args.files, 'bytes': args.files * args.bytes, 'worker_sha256': hashlib.sha256(worker.read_bytes()).hexdigest(), 'samples': samples, 'medians': {m: {key: statistics.median(s[key] for s in samples if s['mode'] == m) for key in ['wall_ms', 'first_row_ms', 'maximum_resident_bytes']} for m in ['single', 'workspace']}}
    (out / 'report.json').write_text(json.dumps(report, indent=2))
    print(out / 'report.json')
    print(json.dumps(report['medians']))


if __name__ == '__main__':
    main()
