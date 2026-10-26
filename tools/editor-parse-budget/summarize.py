#!/usr/bin/env python3
"""반복 시간과 첫 입력·재개·전체 변경 비율을 서로 다른 지표로 집계한다."""
import argparse
import math
from pathlib import Path
import statistics

from run import sha, write
from verify import load, verify


def distribution(values):
    ordered = sorted(values)
    return dict(n=len(values), p50=statistics.median(ordered),
                p95=ordered[math.ceil(len(ordered)*0.95)-1], max=ordered[-1])


def summarize(dataset, receipt):
    groups = {}
    meta = load(dataset/'result.json')
    for key, report in receipt['reports'].items():
        run = meta['runs'][key]
        if run['accuracy']:
            continue
        group = groups.setdefault(run['fixture']+'/'+str(run['budget_ns']),dict(edits=[],first=[],native=[],ranges=[]))
        group['edits'] += report['edits']
        group['first'].append(report['edits'][0])
        for edit in report['edits']:
            slices=[s for s in report['slices'] if s['key']==edit['key']]
            group['native'].append(sum(s['native_ns'] for s in slices))
            group['ranges'].append(sum(s['range_ns'] for s in slices))
    answer={}
    for key,group in groups.items():
        edits=group['edits']
        answer[key]=dict(times_ns={field:distribution([e[field] for e in edits])
                for field in ('first_ns','call_ns','max_ns','wall_ns','color_ns')},
            native_ns=distribution(group['native']), range_ns=distribution(group['ranges']),
            first_inputs_ns={field:distribution([e[field] for e in group['first']]) for field in ('first_ns','call_ns','color_ns')},
            resumed_inputs=sum(e['resumes']>0 for e in edits), full_change_inputs=sum(e['changed_all'] for e in edits),
            resume_calls=sum(e['resumes'] for e in edits))
    return answer


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dataset',type=Path)
    parser.add_argument('--expected-head',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    dataset=args.dataset.resolve()
    receipt=verify(dataset,args.expected_head)
    write(args.output.resolve(),dict(complete=True,head=args.expected_head,groups=summarize(dataset,receipt),
          reader_sha256=sha(Path(__file__)),scope='Nanoseconds; three independent processes of 20 inputs per group; color query and logging outside parse-call sum; boundary instrumentation, no GUI speedup'))
    print('BUDGET_SUMMARY_10_GROUPS')


if __name__=='__main__':
    main()
