"""외부 trace와 첫 입력 drawable을 label·command buffer·surface로 연결한다."""
import json
from pathlib import Path
import external_trace_xml as xml
from external_display_trace import SCHEMAS
import submit_display_report as submit
import verify


def analyze(target):
    target=Path(target)
    app,posts,meta=[json.loads((target/n).read_text()) for n in ('app.json','posts.json','record.json')]
    parent=submit.analyze(app,posts,meta,'enabled')
    marker=meta.get('observer_start',{});mode=marker.get('external_trace_mode')
    verify.require(mode in ('disabled','enabled'),'external trace mode')
    verify.require(marker.get('input_display_mode')=='untimed' and marker.get('submit_display_mode')=='enabled','external trace fixed diagnostics')
    result=dict(mode=mode,submit=parent)
    if mode=='disabled':
        verify.require(not (target/'recording.trace').exists(),'disabled external trace present');return result
    stopped=meta.get('observer_stop',{})
    verify.require(stopped.get('mode')=='enabled' and stopped.get('exit')==0,'external trace outcome')
    exports=stopped.get('exports')
    verify.require(type(exports) is dict and set(exports)==set(SCHEMAS),'external export inventory')
    for name,digest in exports.items():verify.require(verify.sha(target/(name+'.xml'))==digest,'external export drift')
    epoch=xml.epoch(xml.Table(target/'time-info.xml','time-info'))
    table=xml.Table(target/'metal-application-command-buffer-submissions.xml','metal-application-command-buffer-submissions')
    labelled=xml.submissions(table,meta['app_pid'])
    completed=xml.Table(target/'metal-command-buffer-completed.xml','metal-command-buffer-completed');completed.require_columns('timestamp','cmdbuffer-id')
    completions={}
    for row in completed.rows:
        identity=completed.integer(row['cmdbuffer-id']);completions.setdefault(identity,[]).append(epoch+completed.integer(row['timestamp']))
    requests=xml.Table(target/'ca-client-present-request.xml','ca-client-present-request');requests.require_columns('timestamp','cmdbuffer-id','surface-id','process')
    presents={}
    for row in requests.rows:
        if requests.pid(row['process'])==meta['app_pid']:
            identity=requests.integer(row['cmdbuffer-id'])
            surface=requests.resolve(row['surface-id'])
            # surface-id의 typed payload를 보존한다. display-surface-swap과의 실제 신원 연결은 schema를 본 뒤 확정한다.
            presents.setdefault(identity,[]).append(dict(timestamp=epoch+requests.integer(row['timestamp']),surface_type=surface.tag,surface_payload=''.join(surface.itertext()),surface_format=surface.get('fmt')))
    aligned=[]
    for raw in app['submit_rows']:
        row=submit.decode(raw);label=f"maru-submit:{row['generation']}:{row['renderer']}"
        verify.require(label in labelled,'external trace missing exact frame label')
        command=labelled[label];identity=command['command_buffer_id']
        verify.require(len(completions.get(identity,[]))==1,'external trace completion identity')
        verify.require(bool(presents.get(identity)),'external trace presentation request missing')
        aligned.append(dict(label=label,command_buffer_id=identity,trace_commit=epoch+command['committed'],app_commit=row['commit'],
            gpu_end=row['gpu_end'],completed_event=completions[identity][0],presented=row['presented'],requests=presents[identity]))
    verify.require(len(labelled)==len(aligned),'external trace labelled population mismatch')
    return dict(**result,epoch=epoch,aligned=aligned,surface_join_complete=False)
