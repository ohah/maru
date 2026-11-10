"""기존 유효 GPU 자료의 표시 간격·관측된 이전 프레임 겹침을 분석한다."""
import argparse
import json
from pathlib import Path
import input_display_report as base
import submit_display_report as submit
import verify


def timeline(rows):
    # callback 도착 순서는 GPU 제출 순서가 아니므로 commit 시각으로 정렬한다.
    rows = sorted(rows, key=lambda r: (r['commit'], r['renderer']))
    verify.require(bool(rows), 'empty presentation timeline')
    verify.require(len({(r['generation'],r['renderer']) for r in rows})==len(rows), 'duplicate timeline invocation')
    for row in rows:
        submit.partition(row)
    result = []
    for index,row in enumerate(rows):
        prior = rows[:index]
        result.append(dict(generation=row['generation'],renderer=row['renderer'],
            prior_unpresented_at_commit=sum(r['presented']>row['commit'] for r in prior),
            prior_unpresented_at_gpu_end=sum(r['presented']>row['gpu_end'] for r in prior),
            gpu_end_to_present_ms=(row['presented']-row['gpu_end'])/1e6,
            previous_present_gap_ms=(row['presented']-prior[-1]['presented'])/1e6 if prior else None))
    return result


def summarize(rows):
    gaps=[r['previous_present_gap_ms'] for r in rows if r['previous_present_gap_ms'] is not None]
    # 주사율을 추정해 끼워 맞추지 않는다. 순서 역전과 동시 표시도 그대로 보존한다.
    return dict(drawables=len(rows),previous_present_gaps=base.distribution(gaps) if gaps else None,
        reversed_present_pairs=sum(g<0 for g in gaps),simultaneous_present_pairs=sum(g==0 for g in gaps),
        by_prior_unpresented_at_gpu_end={str(n):dict(count=sum(r['prior_unpresented_at_gpu_end']==n for r in rows),
            gpu_end_to_present=base.distribution([r['gpu_end_to_present_ms'] for r in rows if r['prior_unpresented_at_gpu_end']==n]))
            for n in sorted({r['prior_unpresented_at_gpu_end'] for r in rows})})


def read(root):
    root=Path(root).resolve()
    proof=submit.read(root)  # 원래 cohort·첫 표시·해시 검사를 건너뛰지 않는다.
    runs=[]
    for run in proof['enabled']['runs']:
        app=json.loads((root/'enabled'/run['path']/'app.json').read_text())
        rows=timeline([submit.decode(r) for r in app['submit_rows']])
        runs.append(dict(path=run['path'],flow=run['flow'],rows=rows,summary=summarize(rows)))
    return dict(kind='observed-presentation-timeline',reader_sha256=verify.sha(Path(__file__)),
        source_reader_sha256=proof['reader_sha256'],source=proof['source'],runs=runs,
        groups={flow:summarize([row for run in runs if run['flow']==flow for row in run['rows']]) for flow in ('typing','shared')},
        limits=['Only recorded terminal drawables after input arming; earlier unrecorded work is unknown.',
                'Observed pending drawables are not compositor queue depth or proof of causal blocking.',
                'Sparse submissions do not establish display refresh rate or missed refresh deadlines.'])


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    result=read(args.root)
    with args.output.open('x') as stream:stream.write(json.dumps(result,indent=2)+'\n')
