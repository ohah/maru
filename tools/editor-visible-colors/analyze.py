#!/usr/bin/env python3
"""색 조회 재현 로그의 모집단·좌표·대조 성공과 함수 비용을 검사한다."""
import argparse
import hashlib
import json
from pathlib import Path
import statistics
import re

FILES = ('flat-3000.zig', 'real-build.zig', 'real-host.swift')
HEIGHTS = (180, 640, 10000)


def read_log(text, name):
    rows, costs = {}, {}
    for line in text.splitlines():
        line = re.sub(r'^2/5 app_session\.editor\.mod\.test\.visible color query .*?\.\.\.(?=VISIBLE_COLOR )', '', line)
        if not line.startswith(('VISIBLE_COLOR ', 'VISIBLE_COLOR_COST ')):
            continue
        kind, *fields = line.split()
        values = dict(field.split('=', 1) for field in fields)
        assert values.pop('file') == name, '다른 파일 기록'
        values = {key: int(value) for key, value in values.items()}
        height = values['height']
        assert height in HEIGHTS, '알 수 없는 창 크기'
        if kind == 'VISIBLE_COLOR':
            assert height not in rows, '중복 창 크기'
            assert values['first'] == 31 and values['queried_rows'] == 256, '기존 범위/스크롤 불일치'
            assert values['full_oracle'] == 1, '색 대조 미완료'
            assert all(values[key] == 0 for key in ('wrap', 'folded', 'ime')), '범위 밖 모드'
            assert values['body_h'] > 0 and values['cell_h'] > 0
            upper = (values['body_h'] + values['cell_h'] - 1) // values['cell_h']
            assert values['visible_upper'] == upper, '화면 상한 불일치'
            assert values['bounded_rows'] == upper + 1, '후보 범위 불일치'
            rows[height] = values
        else:
            key = (height, values['rep'], values['bounded'])
            assert values['rep'] in range(6) and values['bounded'] in (0, 1)
            assert values['calls'] == 32 and values['ns'] > 0, '함수 표본 불일치'
            assert key not in costs, '중복 함수 표본'
            costs[key] = values['ns'] / 32 / 1e6
    assert set(rows) == set(HEIGHTS), '창 크기 누락'
    assert set(costs) == {(h, r, b) for h in HEIGHTS for r in range(6) for b in (0, 1)}, '함수 표본 누락'
    assert rows[180]['bounded_rows'] < rows[640]['bounded_rows'] < rows[10000]['bounded_rows']
    assert 'All 5 tests passed.' in text, '실행 미완료'
    return [{**rows[h], 'old_ms_p50': statistics.median(costs[h, r, 0] for r in range(6)),
             'bounded_ms_p50': statistics.median(costs[h, r, 1] for r in range(6))} for h in HEIGHTS]


def analyze(root):
    sha = lambda path: hashlib.sha256(path.read_bytes()).hexdigest()
    receipt = json.loads((root / 'result.json').read_text())
    assert receipt['complete'] is True
    assert sha(root / 'test') == receipt['binary_sha256']
    assert all(sha(root / name) == digest for name, digest in receipt['logs'].items())
    proof = json.loads((root / 'prebuild.json').read_text())
    assert sha(root / 'source/build.zig') == proof['build']
    assert all(sha(root / 'source' / name) == digest for name, digest in proof['source'].items())
    assert all(sha(root / 'fixtures' / name) == digest for name, digest in proof['fixtures'].items())
    assert sha(root / 'generator.py') == proof['generator']
    assert sha(root / 'query.zig.inc') == proof['template']
    assert set(proof['fixtures']) == set(FILES)
    return {name: read_log((root / (name + '.log')).read_text(), name) for name in FILES}


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('root', type=Path)
    print(json.dumps(analyze(parser.parse_args().root), indent=2, ensure_ascii=False))
