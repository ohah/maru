"""실제 프레임의 의미만 손상해 세대·준비·제출·표시 판정을 대조한다."""
import argparse
import copy
import json
from pathlib import Path
import parse_stage_report as report
import verify


def review(root, output):
    require = verify.require
    repository = Path(__file__).resolve().parents[2]
    require(not output.exists() and output != repository and repository not in output.parents, 'new external output required')
    proof = report.read(root)
    folder = root/'typing-0'
    original = [json.loads((folder/name).read_text()) for name in ('app.json','posts.json','record.json')]
    control = report.analyze(*copy.deepcopy(original))
    require('display' in control, 'display study required')
    generation = original[0]['syntax_presentations'][-1][1]
    shown = original[0]['syntax_presentations'][-1][0]
    fi = next(i for i,row in enumerate(original[0]['display_frames']) if row[0] == generation)
    di = next(i for i,row in enumerate(original[0]['display_draws']) if row[0] == generation and row[7] == shown)
    def f(column,value):return lambda a,p,m:a['display_frames'][fi].__setitem__(column,value)
    def d(column,value):return lambda a,p,m:a['display_draws'][di].__setitem__(column,value)
    faults = [
        ('hidden-diagnostic-label', lambda a,p,m:m.update(display_stages=False)),
        ('bad-header', lambda a,p,m:a.update(display_stage_header=[])),
        ('counter-boolean', lambda a,p,m:a['display_stage_header'].__setitem__(0,True)),
        ('overflow', lambda a,p,m:a['display_stage_header'].__setitem__(2,1)),
        ('pending-callback', lambda a,p,m:a['display_stage_header'].__setitem__(3,1)),
        ('frame-missing', lambda a,p,m:a.update(display_frames=[])),
        ('draw-missing', lambda a,p,m:a.update(display_draws=[])),
        ('frame-width', lambda a,p,m:a['display_frames'][fi].pop()),
        ('draw-width', lambda a,p,m:a['display_draws'][di].pop()),
        ('frame-generation', f(0,2**63)), ('draw-generation', d(0,2**63)),
        ('revision', f(1,2**63)), ('frame-prefix', f(2,0)), ('draw-prefix', d(1,0)),
        ('frame-not-ready', f(3,0)), ('draw-not-ready', d(2,0)), ('color-not-ready', f(4,2)),
        ('frame-wrong-thread', f(8,0)), ('draw-wrong-thread', d(8,0)),
        ('tick-clock-missing', f(5,0)), ('prepare-clock-missing', f(6,0)), ('tick-end-missing', f(7,0)),
        ('swift-clock-missing', d(3,0)), ('renderer-clock-missing', d(4,0)),
        ('arm-clock-missing', d(5,0)), ('commit-clock-missing', d(6,0)),
        ('wrong-presented-drawable', d(7,shown+1)), ('commit-after-present', d(6,shown+1)),
        ('negative-value', f(1,-1)), ('overflow-value', f(1,2**64)),
        ('boolean-value', d(2,True)), ('float-value', d(2,1.0)),
    ]
    output.mkdir(mode=0o700)
    rejected = []
    for name, mutate in faults:
        values = copy.deepcopy(original)
        mutate(*values)
        try:
            report.analyze(*values)
        except ValueError as error:
            reason = str(error)
        else:
            raise ValueError('mutation survived: '+name)
        require(report.analyze(*copy.deepcopy(original)) == control, 'normal control changed')
        (output/(name+'.json')).write_text(json.dumps(dict(app=values[0],posts=values[1],record=values[2]),indent=2)+'\n')
        rejected.append(dict(name=name,reason=reason))
    require(report.read(root) == proof, 'original study changed')
    result = dict(rejected=rejected,normal_controls=len(faults)+1,processes=proof['processes'],source_hashes={name:verify.sha(folder/name) for name in ('app.json','posts.json','record.json')})
    (output/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    print(json.dumps(review(args.root.resolve(),args.output.resolve()),indent=2))
