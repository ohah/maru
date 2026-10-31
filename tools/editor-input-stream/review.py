#!/usr/bin/env python3
"""실제 원시 기록의 의미를 손상시켜 판정기가 거절하는지 확인한다. 원본은 보존한다."""
import argparse
import copy
import json
import pathlib
import verify


def review(root, output):
    proof = verify.read(root)
    verify.require(proof['kind']=='normal', 'normal control required')
    output=pathlib.Path(output).resolve()
    repository=pathlib.Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and output!=repository and repository not in output.parents, 'new external output required')
    output.mkdir(mode=0o700)
    manifest=json.loads((root/'manifest.json').read_text())
    path=root/manifest['runs'][0]['path']
    original=[json.loads((path/name).read_text()) for name in ['app.json','posts.json','record.json']]
    verify.require(original[2]['count']>=4, 'four inputs required')
    controls=[]
    faults=[
        ('source-not-restored',lambda a,p,m:a.__setitem__('restored',False)),
        ('foreground-lost',lambda a,p,m:a.__setitem__('foreground',False)),
        ('document-tail-invalid',lambda a,p,m:a.__setitem__('document_verified',False)),
        ('document-prefix-invalid',lambda a,p,m:a.__setitem__('visible_line','// wrong')),
        ('key-token-invalid',lambda a,p,m:a['keys'][0].__setitem__(1,0)),
        ('key-code-invalid',lambda a,p,m:a['keys'][0].__setitem__(4,99)),
        ('key-missing',lambda a,p,m:a['keys'][0].__setitem__(11,0)),
        ('key-duplicate',lambda a,p,m:a['keys'][0].__setitem__(11,2)),
        ('native-arrival-missing',lambda a,p,m:a['keys'][0].__setitem__(3,0)),
        ('presentation-missing',lambda a,p,m:a['keys'][0].__setitem__(6,0)),
        ('stale-generation',lambda a,p,m:a['keys'][0].__setitem__(7,a['baseline'][0])),
        ('frame-prefix-absent',lambda a,p,m:a['keys'][0].__setitem__(8,0)),
        ('callbacks-pending',lambda a,p,m:a['header'].__setitem__(8,1)),
        ('final-color-absent',lambda a,p,m:a['header'].__setitem__(4,0)),
        ('actual-mode-wrong',lambda a,p,m:a['state'].__setitem__(6,a['state'][6]^2)),
        ('actual-view-count-wrong',lambda a,p,m:a['state'].__setitem__(4,99)),
        ('producer-is-app',lambda a,p,m:p.__setitem__('pid',a['pid'])),
        ('schedule-feedback',lambda a,p,m:p['events'][1].__setitem__('scheduled_ns',p['events'][1]['scheduled_ns']+1)),
        ('producer-late',lambda a,p,m:p['events'][0].__setitem__('post_ns',p['events'][0]['scheduled_ns']+m['lateness_ns']+1)),
        ('post-source-wrong',lambda a,p,m:p['events'][0].__setitem__('source_verified',False)),
        ('provider-file-changed',lambda a,p,m:m.__setitem__('provider_after',{})),
        ('post-target-wrong',lambda a,p,m:p['events'][0].__setitem__('frontmost_pid',1)),
        ('input-count-missing',lambda a,p,m:a['keys'].pop()),
        ('suppression-in-normal',lambda a,p,m:a.__setitem__('suppressed_frames',1)),
    ]
    rejected=[]
    for name,mutate in faults:
        controls.append(verify.classify(*copy.deepcopy(original)))
        values=copy.deepcopy(original);mutate(*values)
        try: verify.classify(*values)
        except ValueError as error:
            reason=str(error)
        else: raise ValueError('mutation survived: '+name)
        (output/(name+'.json')).write_text(json.dumps(dict(app=values[0],producer=values[1],record=values[2]),indent=2)+'\n')
        rejected.append(dict(name=name,reason=reason))
        verify.require(verify.classify(*copy.deepcopy(original))==controls[-1], 'control changed')
    result=dict(schema=1,source=str(path),source_hashes={n:verify.sha(path/n) for n in ['app.json','posts.json','record.json']},
                rejected=rejected,normal_controls=len(controls)*2)
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('root',type=pathlib.Path);p.add_argument('--output',required=True,type=pathlib.Path)
    a=p.parse_args();print(json.dumps(review(a.root.resolve(),a.output),indent=2))
