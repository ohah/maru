#!/usr/bin/env python3
"""집계기가 서로 다른 손상된 기록을 거절하는지 확인한다."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('summary', Path(__file__).with_name('summarize.py'))
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)
GOOD = 'FRAME key=0 foldSpansCached=100\nFOLD_QUERY key=0 changed_ranges=1 records_update=2 sort=3 dedup=4 coordinates_output=5 snapshot=6\n'


def main():
    assert module.parse(GOOD)[0]['remainder_ns'] == 79
    mutants = {
        'duplicate': GOOD + GOOD.splitlines()[1] + '\n',
        'missing_pair': GOOD.splitlines()[0] + '\n',
        'missing_stage': GOOD.replace(' sort=3', ''),
        'negative': GOOD.replace('sort=3', 'sort=-3'),
        'overlap': GOOD.replace('sort=3', 'sort=300'),
        'duplicate_field': GOOD.replace('sort=3', 'sort=3 sort=30'),
        'missing_sequence': GOOD.replace('key=0', 'key=1'),
    }
    for name, text in mutants.items():
        try:
            module.parse(text)
        except ValueError:
            print(name + ': rejected')
        else:
            raise AssertionError(name + ': accepted')
    assert module.parse(GOOD)[0]['remainder_ns'] == 79
    print('positive controls passed before and after')


if __name__ == '__main__':
    main()
