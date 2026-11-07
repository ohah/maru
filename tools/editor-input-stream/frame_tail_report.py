"""모든 입력의 첫 표시를 같은 frame/drawable/예산 기록에 연결한다."""
import argparse
import json
import math
from pathlib import Path
import statistics
import frame_wake_report
import deferred_retry_report
import verify


def key_trace(app, event, key, require):
    frames=[row for row in app['display_frames'] if row[0]==key[7]]
    draws=[row for row in app['display_draws'] if row[0]==key[7] and row[7]==key[6]]
    require(len(frames)==len(draws)==1,'tail unique frame/drawable')
    frame,draw=frames[0],draws[0]
    require(frame[1]==app['baseline'][1]+frame[2] and frame[2]==draw[1]==key[8] and frame[3]==draw[2]==key[9],'tail input/frame stamp')
    permits=[row for row in app['target_budget_rows'] if frame[5]<=row[1]<=frame[6]]
    require(len(permits)==1 and permits[0][3]==1,'tail producing projection permit')
    main_threads={row[8] for row in app['parse_stages'] if row[0]==1}
    require(len(main_threads)==1 and frame[8]==draw[8]==next(iter(main_threads)) and frame[8]>0,'tail frame thread')
    require(type(key[0]) is int and key[0]>0,'tail key sequence')
    points=[event['post_ns'],key[3],max(key[3],frame[5]),permits[0][1],frame[6],frame[7],draw[3],draw[4],draw[5],draw[6],key[6]]
    require(all(type(n) is int and 0<n<2**64 for n in points) and all(a<=b for a,b in zip(points,points[1:])),'tail timeline order')
    names=('post_to_native','native_to_tick','tick_to_permit','projection','tick_finalize','wait_for_swift','swift','renderer','arm_to_commit','commit_to_present')
    parts={name:(b-a)/1e6 for name,a,b in zip(names,points,points[1:])}
    total=(key[6]-event['post_ns'])/1e6
    require(abs(sum(parts.values())-total)<1e-6,'tail interval sum')
    denied=[row for row in app['target_budget_rows'] if not row[3] and key[3]<=row[1]<frame[6]]
    documents={tuple(row[2:5]) for row in app['parse_stages'] if row[0]==5 and row[5]==app['state'][1]}
    require(len(documents)==1,'tail document identity')
    document=next(iter(documents))
    installs=[row[1] for row in app['parse_stages'] if row[0]==8 and tuple(row[2:5])==document and row[5]==frame[1]]
    contexts=[]
    for denial in denied:
        before=[row for row in app['target_budget_rows'] if row[3] and row[0]==denial[0] and row[1]<denial[1]]
        after=[row for row in app['target_budget_rows'] if row[3] and row[0]==denial[0] and row[1]>denial[1]]
        require(before and after,'tail denial neighbours')
        previous,following=before[-1],after[0]
        require(previous[2]==denial[2]==following[2] and 1<=denial[2]<=1000,'tail denial Hz')
        due=previous[1]+(1000000000+denial[2]-1)//denial[2]
        require(denial[1]<due<=following[1],'tail denied deadline order')
        prior=[r for r in app['display_frames'] if r[5]<=previous[1]<=r[6]]
        contexts.append(dict(previous_prefix=prior[0][2] if len(prior)==1 else None,
                             budget_due_after_native_ms=(due-key[3])/1e6,
                             next_permit_after_due_ms=(following[1]-due)/1e6,
                             next_permit_is_first_frame=following==permits[0],
                             matching_install_after_native_ms=(min(installs)-key[3])/1e6 if installs else None,
                             matching_install_after_next_permit=min(installs)>following[1] if installs else None))
    return dict(sequence=key[0],total_ms=total,denied_before_first_frame=len(denied),parts_ms=parts,denial_context=contexts)


def distribution(rows):
    values=sorted(row['total_ms'] for row in rows)
    return dict(count=len(values),median_ms=statistics.median(values),p95_ms=values[math.ceil(.95*len(values))-1],maximum_ms=max(values))


def read(root):
    root=Path(root).resolve()
    retry=json.loads((root/'study.json').read_text()).get('kind')=='deferred-frame-comparison'
    source=deferred_retry_report.read(root) if retry else frame_wake_report.read(root)
    verify.require(source['variant']=='target-coalesced','target comparison required')
    groups={}
    for mode in (('without_retry','with_retry') if retry else ('scheduled','immediate')):
        for flow in ('typing','shared'):
            rows=[];idle=[];first_key_checks=[]
            for run in source[mode]['runs']:
                if not run['path'].startswith(flow+'-'):continue
                folder=root/mode/run['path']
                app=json.loads((folder/'app.json').read_text());posts=json.loads((folder/'posts.json').read_text())
                for key,event in zip(app['keys'],posts['events']):rows.append(dict(path=run['path'],**key_trace(app,event,key,verify.require)))
                a,b=app['wake_idle_start'],app['wake_idle_end']
                idle.append(dict(path=run['path'],wall_seconds=(b[0]-a[0])/1e9,user_ms=(b[7]-a[7])/1e6,system_ms=(b[8]-a[8])/1e6,extra_session_ticks=run['target_frame']['idle']['extra_session_ticks']))
                beginning=app['wake_input_start'][0];arrival=app['keys'][0][3]
                installs=[r for r in app['parse_stages'] if r[0]==8 and beginning<=r[1]<arrival]
                first_key_checks.append(dict(path=run['path'],installs_between_input_start_and_first_native=len(installs)))
            verify.require(len(rows)==90,'tail 90-key condition')
            ordered=sorted(rows,key=lambda row:(row['total_ms'],row['path'],row['sequence']))
            tail=ordered[-math.ceil(len(rows)*.05):]
            groups[mode+'-'+flow]=dict(official=distribution(rows),first_two=distribution([r for r in rows if r['sequence']<=2]),remaining=distribution([r for r in rows if r['sequence']>2]),tail=tail,all_keys=rows,idle=idle,first_key_checks=first_key_checks)
    here=Path(__file__).resolve().parent
    return dict(kind='target-frame-tail-attribution',head=source['without_retry' if retry else 'scheduled']['head'],app_sha256=source['without_retry' if retry else 'scheduled']['app_sha256'],source_readers=source['reader_dependencies'],reader_sha256=verify.sha(here/'frame_tail_report.py'),groups=groups)


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    with args.output.open('x') as output:output.write(json.dumps(read(args.root),indent=2)+'\n')
