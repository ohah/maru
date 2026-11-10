"""GPU 실제 실행 시각과 CPU callback 시각을 구분해 제출→표시를 나눈다."""
import argparse
import json
from pathlib import Path
import input_display_report as base
import parse_stage_report
import submit_display as schema
import verify


def decode(raw):
    verify.require(type(raw) is list and len(raw) == schema.WIDTH and all(verify.uint(v) for v in raw), 'submit row shape')
    return dict(zip(schema.FIELDS, raw))


def partition(row):
    require = verify.require
    require(all(row[name] > 0 for name in schema.FIELDS if name not in ('ready','error')), 'submit missing data')
    require(row['ready'] in (0,1) and row['status'] == 4 and row['error'] == 0, 'command buffer outcome')
    require(row['command_buffer'] == row['scheduled_buffer'] == row['completed_buffer'] and row['drawable'] == row['presented_drawable'], 'submit callback ownership')
    require(row['commit'] <= row['gpu_start'] <= row['gpu_end'] <= row['presented'], 'submit GPU/present clock order')
    require(row['commit'] <= row['returned'] and row['kernel_start'] <= row['kernel_end'], 'submit host clock order')
    require(row['scheduled_cb'] >= row['commit'] and row['completed_cb'] >= max(row['gpu_end'],row['kernel_end']) and row['presented_cb'] >= row['presented'], 'submit callback clock order')
    primary = dict(commit_to_gpu_start=(row['gpu_start']-row['commit'])/1e6,
                   gpu_execution=(row['gpu_end']-row['gpu_start'])/1e6,
                   gpu_end_to_present=(row['presented']-row['gpu_end'])/1e6)
    total = (row['presented']-row['commit'])/1e6
    require(abs(sum(primary.values())-total)<1e-6, 'submit partition sum')
    # 커널 스케줄링과 GPU 실행의 직렬 관계를 미리 가정하지 않는다.
    clipped = max(0,min(row['kernel_end'],row['gpu_start'])-max(row['kernel_start'],row['commit']))
    before_gpu = row['gpu_start']-row['commit']
    serial = row['commit'] <= row['kernel_start'] <= row['kernel_end'] <= row['gpu_start']
    serial_parts = dict(commit_to_kernel_start=(row['kernel_start']-row['commit'])/1e6,
                        kernel_schedule=(row['kernel_end']-row['kernel_start'])/1e6,
                        kernel_end_to_gpu_start=(row['gpu_start']-row['kernel_end'])/1e6) if serial else None
    if serial:require(abs(sum(serial_parts.values())-primary['commit_to_gpu_start'])<1e-6, 'submit serial partition sum')
    return dict(parts_ms=primary,commit_to_present_ms=total,kernel_schedule_ms=(row['kernel_end']-row['kernel_start'])/1e6,
                kernel_inside_pre_gpu_ms=clipped/1e6,pre_gpu_outside_kernel_ms=(before_gpu-clipped)/1e6,
                serial_kernel_before_gpu=serial,serial_parts_ms=serial_parts,
                commit_call_ms=(row['returned']-row['commit'])/1e6,
                gpu_started_before_commit_return=row['gpu_start']<row['returned'],
                scheduled_callback_minus_kernel_end_ms=(row['scheduled_cb']-row['kernel_end'])/1e6,
                completed_callback_after_gpu_ms=(row['completed_cb']-row['gpu_end'])/1e6,
                presented_callback_after_present_ms=(row['presented_cb']-row['presented'])/1e6)


def analyze(app, producer, meta, mode):
    require = verify.require
    parent = base.analyze(app,producer,meta,'untimed')
    require(mode in schema.MODES and app.get('submit_display_mode') == mode, 'submit mode label')
    require(app.get('submit_fields') == list(schema.FIELDS), 'submit field schema')
    header, raw = app.get('submit_header'), app.get('submit_rows')
    require(type(header) is list and len(header)==5 and all(verify.uint(v) for v in header), 'submit header shape')
    require(type(raw) is list and len(raw)<=2048 and header==[len(raw),0,0,int(mode=='enabled'),0], 'submit overflow/pending/errors')
    if mode == 'disabled':
        require(not raw, 'disabled GPU measurements present')
        return dict(input_display=parent,keys=[],command_buffers=0)
    require(len(raw)==len(app['display_draws']) and len(raw)>0, 'submit command buffer population')
    rows = [decode(value) for value in raw]
    require(len({(row['generation'],row['renderer']) for row in rows})==len(rows), 'duplicate submit renderer invocation')
    frames = {}
    for row in rows:
        matching = [draw for draw in app['display_draws'] if draw[0]==row['generation'] and draw[4]==row['renderer']]
        require(len(matching)==1, 'submit unmatched draw')
        draw = matching[0]
        require([row['generation'],row['prefix'],row['ready']]==draw[:3] and row['commit']==draw[6] and row['presented']==draw[7] and row['main_thread']==draw[8], 'submit drawable/source identity')
        frames[(row['generation'],row['presented'])] = partition(row)
    keys = []
    for key in app['keys']:
        identity = (key[7],key[6])
        require(identity in frames, 'first input submit frame missing')
        trace = frames[identity]
        base_key = next(item for item in parent['keys'] if item['sequence']==key[0])
        require(abs(trace['commit_to_present_ms']-base_key['parts_ms']['commit_to_present'])<1e-6, 'GPU interval differs from first drawable')
        keys.append(dict(sequence=key[0],generation=key[7],**trace))
    return dict(input_display=parent,keys=keys,command_buffers=len(rows))


def read(root):
    root = Path(root).resolve()
    study = json.loads((root/'study.json').read_text())
    require = verify.require
    require(study.get('kind')=='submit-display-comparison' and study.get('complete') is True, 'incomplete submit study')
    source = study['source']
    require(source.get('submit_display') is True and source.get('input_display') is True, 'submit build capability')
    require(not any(source.get(name,False) for name in ('frame_wake_control','target_frame_control','observer_cpu','deferred_retry_control','observer_posts_control','observer_work_control')), 'experimental policy mixed into submit attribution')
    result = {}
    for mode in schema.MODES:
        folder = root/mode
        manifest = json.loads((folder/'study.json').read_text())
        base.cohort_manifest(manifest,source)
        common = parse_stage_report.read(folder)
        runs = []
        for item in manifest['runs']:
            target = folder/item['path']
            app,posts,meta = [json.loads((target/name).read_text()) for name in ('app.json','posts.json','record.json')]
            marker = meta.get('observer_start')
            require(type(marker) is dict and marker.get('input_display_mode')=='untimed' and marker.get('submit_display_mode')==mode, 'submit requested mode')
            measured = analyze(app,posts,meta,mode)
            require(measured==json.loads((target/'submit-display.json').read_text()), 'submit summary differs from raw')
            runs.append(dict(path=item['path'],flow=meta['flow'],**measured))
        groups = {}
        for flow in ('typing','shared'):
            own = [row for run in runs if run['flow']==flow for row in run['keys']]
            input_keys = [row for run in runs if run['flow']==flow for row in run['input_display']['keys']]
            group = dict(inputs=len(input_keys),total=base.distribution([row['total_ms'] for row in input_keys]),native_to_present=base.distribution([row['native_to_present_ms'] for row in input_keys]))
            if mode=='enabled':
                group['parts']={name:base.distribution([row['parts_ms'][name] for row in own]) for name in own[0]['parts_ms']}
                group['serial_kernel_inputs']=sum(row['serial_kernel_before_gpu'] for row in own)
                group['serial_parts']={name:base.distribution([row['serial_parts_ms'][name] for row in own if row['serial_kernel_before_gpu']]) for name in ('commit_to_kernel_start','kernel_schedule','kernel_end_to_gpu_start')} if group['serial_kernel_inputs'] else None
                group['kernel_schedule']=base.distribution([row['kernel_schedule_ms'] for row in own])
                group['commit_call']=base.distribution([row['commit_call_ms'] for row in own])
            groups[flow]=group
        result[mode]=dict(head=common['head'],app_sha256=common['app_sha256'],runs=runs,groups=groups)
    expected={f'{flow}-{rep}' for rep in range(3) for flow in ('typing','shared')}
    pairs=study.get('pairs')
    require(type(pairs) is list and len(pairs)==len(expected) and {p['path'] for p in pairs}==expected, 'submit comparison pairing')
    for pair in pairs:
        rep=int(pair['path'].rsplit('-',1)[1]);require(pair['order']==list(schema.MODES if rep%2==0 else schema.MODES[::-1]), 'submit comparison order')
    return dict(kind='submit-display-comparison',source=source,reader_sha256=verify.sha(Path(__file__)),**result)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    with args.output.open('x') as stream:stream.write(json.dumps(read(args.root),indent=2)+'\n')
