#!/usr/bin/env python3
"""검증된 실제 자료에 의미 변조를 넣고 단계 분석의 거절과 원본 보존을 재현한다."""
import argparse
import copy
import json
import pathlib
import stages
import verify


def main():
    p = argparse.ArgumentParser()
    p.add_argument('root', type=pathlib.Path)
    p.add_argument('--output', required=True, type=pathlib.Path)
    a = p.parse_args()
    root, out = a.root.resolve(), a.output.resolve()
    if out.exists() or root == out or root in out.parents:
        p.error('new independent output required')
    verify.verify(root)
    m = json.loads((root/'manifest.json').read_text())
    run = next(r for r in m['runs'] if r['mode'] == 'async')
    value = json.loads((root/run['path']/'result.json').read_text())
    checks = [
        ('failure', lambda v: v.__setitem__('error', 'injected'), 'run failure'),
        ('source_restore', lambda v: v.__setitem__('restored', False), 'run failure'),
        ('process', lambda v: v.__setitem__('pid', run['pid']+1), 'process identity'),
        ('mode_identity', lambda v: v.__setitem__('mode', 'sync'), 'identity'),
        ('flow_identity', lambda v: v.__setitem__('flow', 'other'), 'identity'),
        ('missing_input', lambda v: v['rows'].pop(), 'missing event'),
        ('missing_memory', lambda v: v['memory'].__setitem__(1, 0), 'memory counter'),
        ('reversed_peak', lambda v: v['memory'].__setitem__(0, v['baseline_memory'][0]-1), 'peak counter reversed'),
        ('sequence', lambda v: v['rows'][0].__setitem__('seq', 2), 'event sequence'),
        ('foreground', lambda v: v['rows'][0].__setitem__('foreground', False), 'foreground/text'),
        ('input_text', lambda v: v['rows'][0].__setitem__('visible_line', 'wrong'), 'visible input mismatch'),
        ('float_clock', lambda v: v['rows'][0]['timing'].__setitem__(3, float(v['rows'][0]['timing'][3])), 'record types'),
        ('arrival_before_post', lambda v: v['rows'][0]['timing'].__setitem__(3, v['rows'][0]['timing'][1]-1), 'presentation order'),
        ('missing_present', lambda v: v['rows'][0]['timing'].__setitem__(5, 0), 'presentation order'),
        ('superseded_receipt', lambda v: v['rows'][0]['timing'].__setitem__(9, v['rows'][1]['timing'][1]+1), 'receipt after superseding input'),
        ('reversed_color', lambda v: v['rows'][0]['timing'].__setitem__(6, v['rows'][0]['timing'][5]-1), 'color presentation order'),
        ('missing_final_color', lambda v: v['rows'][-1]['timing'].__setitem__(9, 0), 'last input color incomplete'),
        ('event_clock', lambda v: v['rows'][0]['timing'].__setitem__(2, v['rows'][0]['timing'][3]+1), 'event clock domain'),
        ('hid_key', lambda v: v['rows'][0]['timing'].__setitem__(4, 49), 'wrong HID key'),
        ('stale_generation', lambda v: v['rows'][0]['timing'].__setitem__(7, v['rows'][0]['before'][0]), 'stale frame generation'),
    ]
    out.mkdir()
    result = []
    for name, mutate, wanted in checks:
        stages.run_stages(value, run, m['events'])
        changed = copy.deepcopy(value)
        mutate(changed)
        (out/(name+'.json')).write_text(json.dumps(changed))
        try:
            stages.run_stages(changed, run, m['events'])
        except ValueError as error:
            if str(error) != wanted:
                raise AssertionError((name, str(error), wanted))
            result.append({'fault': name, 'rejected': str(error)})
        else:
            raise AssertionError('corruption survived: '+name)
        stages.run_stages(value, run, m['events'])
    verify.verify(root)
    (out/'review.json').write_text(json.dumps({'controls_preserved': True, 'faults': result}, indent=2)+'\n')
    print(out)


if __name__ == '__main__':
    main()
