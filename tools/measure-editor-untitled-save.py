#!/usr/bin/env python3
"""격리 AppKit 앱의 첫 저장 호출과 다음 main 이벤트를 순차 실측한다."""
import argparse
import json
from pathlib import Path
import statistics
import subprocess
import tempfile
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent / "editor-project-search-app"))
from untitled_oracle import validate_report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--optimize', choices=['Debug', 'ReleaseFast'], default='Debug')
    parser.add_argument('--app', type=Path, help='같은 하네스로 준비한 앱; 생략하면 첫 실행에서 빌드')
    parser.add_argument('--output', type=Path)
    parser.add_argument('--repetitions', type=int, default=3)
    parser.add_argument('--sizes', type=int, nargs='+', default=[65536, 1048576])
    args = parser.parse_args()
    if not 1 <= args.repetitions <= 10 or not args.sizes or any(not 2 <= n <= 8 * 1024 * 1024 for n in args.sizes):
        parser.error('Use 1..10 repetitions and sizes between 2 and 8388608')
    if len(set(args.sizes)) != len(args.sizes):
        parser.error('Duplicate sizes would mix repeated sample groups')
    repo = Path(__file__).resolve().parents[1]
    root = (args.output or Path(tempfile.mkdtemp(prefix='maru-untitled-measure-'))).resolve()
    if root == repo or repo in root.parents or (root.exists() and any(root.iterdir())):
        parser.error('Output must be a new empty directory outside the repository')
    root.mkdir(parents=True, exist_ok=True)
    rows = []
    app = args.app
    provenance = None
    for size in args.sizes:
        for delay in [0, 200]:
            for sample in range(args.repetitions):
                label = f'{size}-{delay}-{sample}'
                command = ['python3', str(repo / 'tools/editor-project-search-app/run.py'),
                           '--untitled-save-benchmark', '--optimize', args.optimize, '--untitled-bytes', str(size),
                           '--untitled-delay-ms', str(delay), '--count', '3', '--timeout-seconds', '120']
                if app: command += ['--app', str(app)]
                with (root / (label + '.log')).open('w') as log:
                    # 하위 실행기가 복사/빌드/앱 각각의 timeout과 finally 정리를 소유한다.
                    # 전체 timeout으로 실행기만 먼저 죽여 분리된 앱을 남기지 않는다.
                    result = subprocess.run(command, cwd=repo, stdout=log, stderr=subprocess.STDOUT)
                if result.returncode:
                    raise RuntimeError(f'{label} failed; inspect {root / (label + ".log")}')
                manifest = Path((root / (label + '.log')).read_text().splitlines()[-1])
                report = json.loads(manifest.read_text())
                metrics, provenance = validate_report(report, size, delay, provenance)
                row = dict(metrics, manifest=str(manifest))
                rows.append(row)
                if not app: app = manifest.parent / 'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app'
                # 중단돼도 이미 끝난 표본의 경로·수치는 보존한다.
                (root / 'samples.json').write_text(json.dumps(rows, indent=2) + '\n')
                print(json.dumps(row), flush=True)
    summary = []
    for size in args.sizes:
        for delay in [0, 200]:
            group = [r for r in rows if r['bytes'] == size and r['injected_delay_ms'] == delay]
            metrics = {}
            for key in ['call_ns', 'next_event_ns', 'serialize_ns', 'io_ns']:
                values = [r[key] / 1e6 for r in group]
                metrics[key.removesuffix('_ns') + '_ms'] = dict(min=min(values), median=statistics.median(values), max=max(values))
            summary.append(dict(bytes=size, injected_delay_ms=delay, samples=len(group), metrics=metrics))
    (root / 'summary.json').write_text(json.dumps(summary, indent=2) + '\n')
    print(root / 'summary.json', flush=True)


if __name__ == '__main__':
    main()
