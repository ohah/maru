"""화면 예상 경계와 실제 drawable 표시를 구분해 원시 자료를 다시 읽는다."""
import argparse
import bisect
import json
from pathlib import Path
import display_timing as schema
import input_display_report as base
import parse_stage_report
import submit_display_report as submit
import verify


def timing(value,mode):
    need=verify.require
    need(mode in ('disabled','enabled') and type(value) is dict and value.get('mode')==mode,'display timing mode')
    for name in ('started','ended','errors','overflow','observations'):
        need(verify.uint(value.get(name)),'display timing scalar')
    need(0<value['started']<value['ended'] and value['observations']>1 and value['errors']==value['overflow']==0,'display timing outcome')
    context=value.get('context')
    need(type(context) is list and len(context)==len(schema.CONTEXT) and all(verify.uint(v) for v in context),'display context schema')
    context=dict(zip(schema.CONTEXT,context))
    need(all(context[n]>0 for n in ('display_id','maximum_frames_per_second','layer','frame_loop_hz')) and context['display_sync'] in (0,1) and context['transaction'] in (0,1) and context['maximum_drawables'] in (2,3),'display context values')
    raw=value.get('rows');need(type(raw) is list and len(raw)<=4096,'display timing capacity')
    need(bool(raw) if mode=='enabled' else not raw,'display timing population')
    rows=[]
    for r in raw:
        need(type(r) is list and len(r)==len(schema.FIELDS) and all(verify.uint(v) and v>0 for v in r),'display timing row')
        row=dict(zip(schema.FIELDS,r))
        need(value['started']<=row['begin']<=row['end']<=value['ended'] and row['timestamp']<row['target'] and row['timestamp']<=row['begin'],'display timing clock')
        if rows:need(rows[-1]['end']<=row['begin'] and rows[-1]['timestamp']<=row['timestamp'],'display timing order')
        rows.append(row)
    return context,rows


def associate(rows,gpu):
    # 관측되지 않은 refresh를 만들어 넣거나 target을 실제 표시로 바꾸지 않는다.
    need=verify.require
    stamps=sorted({r['timestamp'] for r in rows})
    need(bool(stamps),'missing display timing')
    result=[]
    for row in gpu:
        end=row['gpu_end'];present=row['presented']
        need(stamps[0]<=end<=stamps[-1],'GPU end outside observed display coverage')
        brackets=[r for r in rows if r['timestamp']<=end<r['target']]
        following=stamps[bisect.bisect_left(stamps,end)]
        first=(following-end)/1e6;second=(present-following)/1e6
        need(abs(first+second-(present-end)/1e6)<1e-6,'display timing partition sum')
        result.append(dict(generation=row['generation'],renderer=row['renderer'],
            observed_brackets=len(brackets),gpu_end_to_next_observed_timestamp_ms=first,
            next_observed_timestamp_to_present_ms=second))
    return result


def analyze(app,producer,meta,mode):
    parent=submit.analyze(app,producer,meta,'enabled')
    context,rows=timing(app.get('display_timing'),mode)
    result=dict(submit=parent,context=context,callbacks=len(rows))
    if mode=='disabled':return result
    gpu=[submit.decode(r) for r in app['submit_rows']]
    need=verify.require
    need(all(app['display_timing']['started']<=r['commit']<=r['presented']<=app['display_timing']['ended'] for r in gpu),'GPU outside timing lifetime')
    aligned=associate(rows,gpu)
    first=[]
    for key in app['keys']:
        matches=[(g,a) for g,a in zip(gpu,aligned) if g['generation']==key[7] and g['presented']==key[6]]
        need(len(matches)==1,'first display timing identity')
        first.append(dict(sequence=key[0],**matches[0][1]))
    result.update(keys=first,all_drawables=aligned,
        callback_body_ms=base.distribution([(r['end']-r['begin'])/1e6 for r in rows]),
        callback_lateness_ms=base.distribution([(r['begin']-r['timestamp'])/1e6 for r in rows]),
        callback_body_total_ms=sum(r['end']-r['begin'] for r in rows)/1e6,
        expected_interval_ms=base.distribution([(r['target']-r['timestamp'])/1e6 for r in rows]),
        late_after_target=sum(r['begin']>r['target'] for r in rows))
    return result


def read(root):
    root=Path(root).resolve();study=json.loads((root/'study.json').read_text());need=verify.require
    need(study.get('kind')=='display-timing-comparison' and study.get('complete') is True,'incomplete display timing study')
    source=study['source'];need(source.get('display_timing') is True and source.get('submit_display') is True,'display timing build')
    need(not any(source.get(n,False) for n in ('frame_wake_control','target_frame_control','observer_cpu','deferred_retry_control','observer_posts_control','observer_work_control')),'display timing product policy')
    modes={}
    for mode in ('disabled','enabled'):
        folder=root/mode;manifest=json.loads((folder/'study.json').read_text());base.cohort_manifest(manifest,source);parse_stage_report.read(folder)
        runs=[]
        for item in manifest['runs']:
            target=folder/item['path'];app,posts,meta=[json.loads((target/n).read_text()) for n in ('app.json','posts.json','record.json')]
            marker=meta.get('observer_start',{})
            need(marker.get('input_display_mode')=='untimed' and marker.get('submit_display_mode')=='enabled' and marker.get('display_timing_mode')==mode,'display timing requested mode')
            measured=analyze(app,posts,meta,mode)
            need(measured==json.loads((target/'display-timing.json').read_text()),'display timing saved summary')
            runs.append(dict(path=item['path'],flow=meta['flow'],**measured))
        modes[mode]=runs
    pairs=study.get('pairs');expected={f'{f}-{r}' for r in range(3) for f in ('typing','shared')}
    need(type(pairs) is list and len(pairs)==6 and {p['path'] for p in pairs}==expected,'display timing pairs')
    for p in pairs:
        rep=int(p['path'].rsplit('-',1)[1]);need(p['order']==(['disabled','enabled'] if rep%2==0 else ['enabled','disabled']),'display timing order')
    for pair in pairs:
        controls=[next(r for r in modes[mode] if r['path']==pair['path'])['context'] for mode in ('disabled','enabled')]
        need(all(controls[0][n]==controls[1][n] for n in schema.CONTEXT if n!='layer'),'display timing paired context changed')
    groups={}
    for mode,runs in modes.items():
        groups[mode]={}
        for flow in ('typing','shared'):
            own=[r for r in runs if r['flow']==flow]
            inputs=[k for r in own for k in r['submit']['input_display']['keys']]
            group=dict(inputs=len(inputs),native_to_present=base.distribution([k['native_to_present_ms'] for k in inputs]))
            if mode=='enabled':
                keys=[k for r in own for k in r['keys']]
                group.update(gpu_end_to_next_observed_timestamp=base.distribution([k['gpu_end_to_next_observed_timestamp_ms'] for k in keys]),
                    next_observed_timestamp_to_present=base.distribution([k['next_observed_timestamp_to_present_ms'] for k in keys]),
                    ambiguous_brackets=sum(k['observed_brackets']>1 for k in keys),missing_brackets=sum(k['observed_brackets']==0 for k in keys),
                    callback_body_total_ms=sum(r['callback_body_total_ms'] for r in own),callbacks=sum(r['callbacks'] for r in own))
            groups[mode][flow]=group
    return dict(kind='display-timing-comparison',source=source,reader_sha256=verify.sha(Path(__file__)),runs=modes,groups=groups)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    result=read(args.root)
    with args.output.open('x') as stream:stream.write(json.dumps(result,indent=2)+'\n')
