#!/usr/bin/env python3
"""독립 검증에 통과한 정상 실행만 조건별로 모은다. 첫 입력을 포함한다."""
import argparse
import json
import math
import pathlib
import statistics
import verify


def summarize(root):
    proof = verify.read(root)
    manifest=json.loads((pathlib.Path(root)/'manifest.json').read_text())
    verify.require(proof['kind']=='normal', 'normal measurements required')
    groups = {}
    for run in proof['runs']:
        size, period, flow, _, mode = run['identity']
        app=json.loads((pathlib.Path(root)/run['path']/'app.json').read_text())
        groups.setdefault((size,period,flow,mode), []).append((run['metrics'],app))
    rows = []
    for (size,period,flow,mode), runs in sorted(groups.items()):
        row = dict(size=size, period_ms=period, flow=flow, mode=mode, processes=len(runs))
        for metric in ['post_to_present_ms','post_to_native_ms','native_to_present_ms']:
            values = sorted(v for run,_ in runs for v in run[metric])
            row[metric] = dict(count=len(values), median=statistics.median(values),
                               p95=values[math.ceil(len(values)*.95)-1], maximum=max(values))
        row['coalesced_keys'] = sum(run['coalesced_keys'] for run,_ in runs)
        row['final_color_after_last_post_ms'] = [run['final_color_after_last_post_ms'] for run,_ in runs]
        row['max_producer_lateness_ms'] = max(run['max_producer_lateness_ms'] for run,_ in runs)
        row['memory_per_process_bytes'] = [dict(peak=app['memory'][0],baseline_resident=app['baseline_memory'][1],final_resident=app['memory'][1]) for _,app in runs]
        rows.append(row)
    return dict(schema=1, protocol=proof['protocol'], root=str(pathlib.Path(root).resolve()),
                head=proof['head'], app_sha256=proof['app_sha256'], producer_sha256=proof['producer_sha256'],
                manifest_sha256=verify.sha(pathlib.Path(root)/'manifest.json'),verifier_sha256=proof['verifier_sha256'],
                summary_tool_sha256=verify.sha(__file__),host=manifest.get('host'),processes=len(proof['runs']),
                inputs=sum(row['post_to_present_ms']['count'] for row in rows),
                aggregation='all keys including first; pooled median and nearest-rank p95; no trimming', conditions=rows)


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path)
    a=p.parse_args();verify.require(not a.output.exists(),'new output required')
    a.output.write_text(json.dumps(summarize(a.root),indent=2)+'\n')
