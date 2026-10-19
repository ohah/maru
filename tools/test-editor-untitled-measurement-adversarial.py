#!/usr/bin/env python3
"""실측 판정 보호를 제거하면 반례 검사가 실제로 실패하는지 격리 사본에서 확인한다."""
import json
from pathlib import Path
import subprocess
import tempfile

repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-untitled-oracle-adversarial-'))
module = root / 'tools/editor-project-search-app/untitled_oracle.py'
module.parent.mkdir(parents=True)
original = (repo / 'tools/editor-project-search-app/untitled_oracle.py').read_text()
test = root / 'tools/test-editor-untitled-measurement.py'
test.write_bytes((repo / 'tools/test-editor-untitled-measurement.py').read_bytes())
cases = [
    ('control', None, None),
    ('accept-success-suffix', 're.fullmatch(pattern, lines[0])', 're.match(pattern, lines[0])'),
    ('accept-duplicates', 'if len(lines) != 1 or (match :=', 'if not lines or (match :='),
    ('truthy-success', "if report.get('product_passed') is not True:", "if not report.get('product_passed'):"),
    ('mix-provenance', 'if previous is not None and provenance != previous:', 'if False:'),
    ('ignore-phase-sum', "metrics['serialize_ns'] + metrics['io_ns'] + delay * 1_000_000", 'delay * 1_000_000'),
    ('restored-control', None, None),
]
results = []
for name, before, after in cases:
    if before:
        assert original.count(before) == 1, before
        module.write_text(original.replace(before, after, 1))
    else:
        module.write_text(original)
    # 다른 길이의 소스도 Python 캐시의 타임스탬프/크기에 기대지 않게 한다.
    result = subprocess.run(['python3', '-B', str(test)], capture_output=True, text=True, timeout=30)
    log = result.stdout + result.stderr
    (root / (name + '.log')).write_text(log)
    if before:
        assert result.returncode != 0 and 'FAIL:' in log and 'SyntaxError' not in log, (name, log)
    else:
        assert result.returncode == 0 and 'OK' in log, (name, log)
    results.append(dict(case=name, rejected=bool(before), exit_code=result.returncode))
    print(name + ': verified', flush=True)
module.write_text(original)
(root / 'results.json').write_text(json.dumps(results, indent=2) + '\n')
print(root / 'results.json', flush=True)
