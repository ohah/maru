"""같은 command buffer/drawable과 GPU 시각의 실제 자료 손상 대조다."""
import argparse
import copy
import json
from pathlib import Path
import submit_display as schema
import submit_display_report as report
import verify


def review(root,output):
    root,output=Path(root).resolve(),Path(output).resolve()
    proof=report.read(root)
    repository=Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and output!=repository and repository not in output.parents,'new external review output required')
    target=root/'enabled/typing-0'
    original=[json.loads((target/name).read_text()) for name in ('app.json','posts.json','record.json')]
    app=original[0];key=app['keys'][0]
    index=next(i for i,r in enumerate(app['submit_rows']) if r[schema.FIELDS.index('generation')]==key[7] and r[schema.FIELDS.index('presented')]==key[6])
    def column(name,value):return lambda a,p,m:a['submit_rows'][index].__setitem__(schema.FIELDS.index(name),value)
    faults=[
        ('mode',lambda a,p,m:a.update(submit_display_mode='disabled')),
        ('schema',lambda a,p,m:a['submit_fields'].reverse()),
        ('overflow',lambda a,p,m:a['submit_header'].__setitem__(1,1)),
        ('pending',lambda a,p,m:a['submit_header'].__setitem__(2,1)),
        ('callback-error',lambda a,p,m:a['submit_header'].__setitem__(4,1)),
        ('generation',column('generation',0)),('renderer',column('renderer',0)),
        ('commit',column('commit',0)),('returned',column('returned',0)),
        ('gpu-start-missing',column('gpu_start',0)),('gpu-end-missing',column('gpu_end',0)),
        ('gpu-end-after-present',column('gpu_end',key[6]+1)),
        ('kernel-end-missing',column('kernel_end',0)),
        ('scheduled-buffer',column('scheduled_buffer',0)),('completed-buffer',column('completed_buffer',0)),
        ('presented-drawable',column('presented_drawable',0)),
        ('scheduled-callback',column('scheduled_cb',1)),('completed-callback',column('completed_cb',1)),
        ('presented-callback',column('presented_cb',1)),
        ('command-outcome',column('status',5)),('command-error',column('error',1)),
        ('wrong-main-thread',column('main_thread',0)),
        ('bool-gpu-time',column('gpu_start',True)),('negative-gpu-time',column('gpu_end',-1)),
    ]
    output.mkdir(mode=0o700);baseline=report.analyze(*copy.deepcopy(original),'enabled');rejected=[]
    for name,mutate in faults:
        verify.require(report.analyze(*copy.deepcopy(original),'enabled')==baseline,'normal control changed')
        changed=copy.deepcopy(original);mutate(*changed)
        try:report.analyze(*changed,'enabled')
        except ValueError as error:reason=str(error)
        else:raise ValueError('mutation survived: '+name)
        (output/(name+'.json')).write_text(json.dumps(dict(app=changed[0],producer=changed[1],record=changed[2]),indent=2)+'\n')
        rejected.append(dict(name=name,reason=reason))
        verify.require(report.analyze(*copy.deepcopy(original),'enabled')==baseline,'normal post-control changed')
    equivalent=copy.deepcopy(original);equivalent[0]['unrelated_note']='equivalent control'
    verify.require(report.analyze(*equivalent,'enabled')==baseline,'equivalent control rejected')
    result=dict(source=str(target),source_hashes={name:verify.sha(target/name) for name in ('app.json','posts.json','record.json')},rejected=rejected,normal_controls=2*len(faults),equivalent_controls=1)
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    verify.require(report.read(root)==proof,'original submit study changed')
    return result


if __name__=='__main__':
    parser=argparse.ArgumentParser();parser.add_argument('root',type=Path);parser.add_argument('--output',type=Path,required=True);args=parser.parse_args()
    print(json.dumps(review(args.root,args.output),indent=2))
