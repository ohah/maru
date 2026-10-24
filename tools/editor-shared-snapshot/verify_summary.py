#!/usr/bin/env python3
"""첫 입력·초기 준비를 빼거나 겹친 기록이 집계에 통과하지 않는지 확인한다."""
import importlib.util
from pathlib import Path

spec = importlib.util.spec_from_file_location('summary', Path(__file__).with_name('summarize.py'))
summary = importlib.util.module_from_spec(spec)
spec.loader.exec_module(summary)
GOOD = 'SHARED_SPLIT ns=5\nSHARED_READY ns=15 native_parse=7 primary_cache=1 peer_cache=0\n'
GOOD += ''.join(f'FRAME key={key} foldSpansCached=3\nSTORAGE key={key} total_ns=10\n' for key in range(20))


def main():
    assert summary.parse(GOOD)['ready_first_ns']==25
    cases = {
        'missing-startup': GOOD.replace('SHARED_SPLIT ns=5\n',''),
        'overlapping-startup': GOOD.replace('SHARED_SPLIT ns=5','SHARED_SPLIT ns=20'),
        'parse-exceeds-startup': GOOD.replace('native_parse=7','native_parse=16'),
        'missing-first-input': GOOD.replace('STORAGE key=0 total_ns=10\n',''),
        'duplicate-input': GOOD+'FRAME key=0 foldSpansCached=3\n',
        'negative-interval': GOOD.replace('native_parse=7','native_parse=-1'),
        'duplicate-field': GOOD.replace('ns=15','ns=15 ns=14'),
    }
    for name,text in cases.items():
        try:summary.parse(text)
        except ValueError:print(name+': rejected')
        else:raise AssertionError(name+': accepted')
    assert summary.parse(GOOD)['ready_first_ns']==25
    print('positive controls passed before and after')


if __name__=='__main__':main()
