"""native 관측과 기존 제품 결과·호출 수를 연결한다. 제공 바이트를 소비량으로 해석하지 않는다."""
import importlib.util
from pathlib import Path
import re

FIELDS = ('calls', 'old_tree_calls', 'source_bytes', 'budget_ns', 'done', 'pending',
          'read_calls', 'eof_calls', 'offered_bytes', 'progress_calls', 'cancel_returns',
          'range_calls', 'range_items', 'nonempty_ranges')
PATTERN = re.compile(r'NATIVE_PROBE schema=1 key=(\d+) ' + ' '.join(name + r'=(\d+)' for name in FIELDS))
ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location('native_provider_summary', ROOT / 'tools/editor-provider-measure/summarize.py')
provider = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provider)


def read_probe(text, providers, frames):
    rows = []
    for line in text.splitlines():
        if not line.startswith('NATIVE_PROBE'):
            continue
        match = PATTERN.fullmatch(line)
        if match is None:
            raise ValueError('Malformed or unknown native probe schema')
        row = dict(zip(('key',) + FIELDS, map(int, match.groups())))
        if any(value > 2**64 - 1 for value in row.values()):
            raise ValueError('Native counter exceeds u64')
        rows.append(row)
    if [row['key'] for row in rows] != list(range(20)) or len(providers) != 20 or len(frames) != 20:
        raise ValueError('Missing duplicate or reordered native keys')
    for row, parsed, frame in zip(rows, providers, frames):
        if row['key'] != parsed['key'] or row['key'] != frame['key']:
            raise ValueError('Native and product keys differ')
        if row['calls'] != parsed['native_calls'] or row['calls'] != 1:
            raise ValueError('Native call coverage differs from provider')
        if row['old_tree_calls'] > row['calls'] or row['done'] + row['pending'] != row['calls']:
            raise ValueError('Native tree or outcome counts disagree')
        if row['source_bytes'] != frame['bytes']:
            raise ValueError('Native source length differs from edited product')
        if row['eof_calls'] > row['read_calls']:
            raise ValueError('EOF calls exceed reader calls')
        nonempty = row['read_calls'] - row['eof_calls']
        if not nonempty <= row['offered_bytes'] <= nonempty * row['source_bytes']:
            raise ValueError('Offered byte total disagrees with reader calls')
        if row['cancel_returns'] > row['progress_calls']:
            raise ValueError('Cancellation returns exceed progress calls')
        if row['range_calls'] != parsed['changed_ranges_calls']:
            raise ValueError('Native changed range coverage differs from provider')
        if row['nonempty_ranges'] > row['range_calls'] or row['range_items'] < row['nonempty_ranges']:
            raise ValueError('Native range item counts disagree')
        if row['nonempty_ranges'] == 0 and row['range_items'] != 0:
            raise ValueError('Range items without a nonempty call')
    return rows


def validate(text, workload, data, filename, setup):
    if (any(type(setup.get(name)) is not int for name in ('native_probe_schema', 'provider_schema', 'frame_schema'))
            or setup.get('native_probe_schema') != 1
            or setup.get('native_probe_fields') != list(FIELDS)
            or setup.get('provider_schema') != 3 or setup.get('frame_schema') != 2
            or setup.get('provider_execution') != 'revision-snapshots'):
        raise ValueError('Unsupported diagnostic execution schema')
    # 진단 표본은 전수 대조를 켠 별도 실행이다. 성능 원시 기록에 추가 필드만 끼워 넣지 않는다.
    rows = provider.validate(text, workload, data, filename, 1, 3, 'revision-snapshots', 2)
    frames = provider.frame.validate(text, workload, len(data), data.count(b'\n') + 1, 2)
    return read_probe(text, rows, frames)
