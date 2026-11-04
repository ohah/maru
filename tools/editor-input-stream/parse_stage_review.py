"""실제 마지막 요청의 단계만 손상시키고 정상 대조와 함께 재판정한다."""
import argparse
import copy
import json
from pathlib import Path
import parse_stage_report as report
import verify


def review(root, output):
    require = verify.require
    require(not output.exists() and output != Path(__file__).resolve().parents[2] and Path(__file__).resolve().parents[2] not in output.parents, 'new external output required')
    proof = report.read(root)
    output.mkdir(mode=0o700)
    folder = root/'typing-0'
    original = [json.loads((folder/name).read_text()) for name in ('app.json', 'posts.json', 'record.json')]
    revision = original[0]['baseline'][1]+original[2]['count']
    rows = original[0]['parse_stages']
    ids = {stage: next(i for i,row in enumerate(rows) if row[0] == stage and row[5] == revision) for stage in range(1,9)}
    def cell(stage, column, value):
        return lambda a,p,m:a['parse_stages'][ids[stage]].__setitem__(column,value)
    faults = [
        ('not-diagnostic', lambda a,p,m:m.update(diagnostic=False)),
        ('overflow', lambda a,p,m:a['parse_stage_header'].__setitem__(1,1)),
        ('wrong-population', lambda a,p,m:a['parse_stage_header'].__setitem__(0,0)),
        ('row-width', lambda a,p,m:a['parse_stages'][ids[1]].pop()),
        ('boolean-stage', cell(1,0,True)),
        ('unknown-stage', cell(1,0,9)),
        ('missing-clock', cell(1,1,0)),
        ('negative-owner', cell(1,2,-1)),
        ('serial-overflow', cell(1,6,2**64)),
        ('missing-thread', cell(1,8,0)),
        ('backwards-clock', cell(2,1,1)),
        ('missing-acceptance', cell(5,0,1)),
        ('different-document', cell(1,2,0)),
        ('different-request', cell(1,6,2**63)),
        ('missing-view', cell(8,0,7)),
        ('missing-view-identity', cell(8,7,0)),
        ('acceptance-off-main', cell(5,8,rows[ids[2]][8])),
        ('worker-on-main', cell(2,8,rows[ids[1]][8])),
        ('worker-not-ready', cell(3,7,1)),
        ('publication-not-ready', cell(4,7,1)),
        ('view-copy-order', cell(6,0,7)),
        ('installation-before-acceptance', cell(8,1,rows[ids[5]][1]-1)),
        ('view-wrong-thread', cell(8,8,rows[ids[2]][8])),
        ('late-request-submission', cell(1,1,original[0]['syntax_presentations'][-1][0]+1)),
    ]
    controls = report.analyze(*copy.deepcopy(original))
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
        require(report.analyze(*copy.deepcopy(original)) == controls, 'normal control changed')
        (output/(name+'.json')).write_text(json.dumps(dict(app=values[0], posts=values[1], record=values[2]), indent=2)+'\n')
        rejected.append(dict(name=name, reason=reason))
    require(report.read(root) == proof, 'original study changed')
    result = dict(rejected=rejected, normal_controls=len(faults)+1, original_processes=proof['processes'], source_hashes={name:verify.sha(folder/name) for name in ('app.json','posts.json','record.json')})
    (output/'summary.json').write_text(json.dumps(result, indent=2)+'\n')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(review(args.root.resolve(), args.output.resolve()), indent=2))
