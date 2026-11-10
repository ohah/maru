"""검증된 실제 원시 자료에 첫 표시 소유권·획득·CPU 손상을 넣고 원본 대조를 유지한다."""
import argparse
import copy
import json
from pathlib import Path
import input_display_report as report
import verify


def review(root, output):
    root, output = Path(root).resolve(), Path(output).resolve()
    proof = report.read(root)
    repository = Path(__file__).resolve().parents[2]
    verify.require(not output.exists() and output != repository and repository not in output.parents, 'new external review output required')
    target = root / 'timed/typing-0'
    original = [json.loads((target / name).read_text()) for name in ('app.json', 'posts.json', 'record.json')]
    app = original[0]
    key = app['keys'][0]
    draw_index = next(i for i, row in enumerate(app['display_draws']) if row[0] == key[7] and row[7] == key[6])
    renderer = app['display_draws'][draw_index][4]
    acquired_index = next(i for i, row in enumerate(app['input_drawables']) if row[0] == key[7] and row[3] == renderer)
    native_index = next(i for i, row in enumerate(app['input_intervals']) if row[0] == 1 and row[1] == key[1])
    observer_index = next(i for i, row in enumerate(app['input_intervals']) if row[0] == 0)

    def acquired(column, value):
        return lambda value_app, p, m: value_app['input_drawables'][acquired_index].__setitem__(column, value)

    faults = [
        ('mode', lambda a,p,m:a.update(input_display_mode='untimed')),
        ('counter-error', lambda a,p,m:a.update(input_interval_errors=1)),
        ('missing-key-completion', lambda a,p,m:a['input_interval_completed'].__setitem__(1,0)),
        ('missing-observer-start', lambda a,p,m:a['input_interval_started'].__setitem__(0,0)),
        ('finish-overlap', lambda a,p,m:a.update(input_finish_handler_begin=1)),
        ('native-token', lambda a,p,m:a['input_intervals'][native_index].__setitem__(1,0)),
        ('native-thread', lambda a,p,m:a['input_intervals'][native_index].__setitem__(5,0)),
        ('native-cpu', lambda a,p,m:a['input_intervals'][native_index].__setitem__(4,2**63)),
        ('observer-cpu', lambda a,p,m:a['input_intervals'][observer_index].__setitem__(4,2**63)),
        ('observer-token', lambda a,p,m:a['input_intervals'][observer_index].__setitem__(1,1)),
        ('acquisition-overflow', lambda a,p,m:a['input_draw_header'].__setitem__(1,1)),
        ('acquisition-count', lambda a,p,m:a['input_draw_header'].__setitem__(0,0)),
        ('acquisition-duplicate', lambda a,p,m:a['input_drawables'].append(copy.deepcopy(a['input_drawables'][acquired_index]))),
        ('generation', acquired(0,0)),
        ('prefix', acquired(1,0)),
        ('ready', acquired(2,1-key[9])),
        ('renderer-invocation', acquired(3,0)),
        ('terminal-begin', acquired(4,0)),
        ('terminal-end', acquired(5,2**63)),
        ('overlay-order', acquired(6,1)),
        ('thread', acquired(8,0)),
        ('bool-timestamp', acquired(4,True)),
        ('negative-timestamp', acquired(4,-1)),
        ('pending-callback', lambda a,p,m:a['display_stage_header'].__setitem__(3,1)),
    ]
    output.mkdir(mode=0o700)
    baseline = report.analyze(*copy.deepcopy(original), 'timed')
    rejected = []
    for name, mutate in faults:
        verify.require(report.analyze(*copy.deepcopy(original), 'timed') == baseline, 'normal control changed')
        changed = copy.deepcopy(original)
        mutate(*changed)
        try:
            report.analyze(*changed, 'timed')
        except ValueError as error:
            reason = str(error)
        else:
            raise ValueError('mutation survived: ' + name)
        (output / (name + '.json')).write_text(json.dumps(dict(app=changed[0], producer=changed[1], record=changed[2]), indent=2) + '\n')
        rejected.append(dict(name=name, reason=reason))
        verify.require(report.analyze(*copy.deepcopy(original), 'timed') == baseline, 'normal post-control changed')
    equivalent = copy.deepcopy(original)
    equivalent[0]['unrelated_note'] = 'equivalent control'
    verify.require(report.analyze(*equivalent, 'timed') == baseline, 'equivalent control rejected')
    result = dict(source=str(target), source_hashes={name:verify.sha(target / name) for name in ('app.json', 'posts.json', 'record.json')}, rejected=rejected, normal_controls=len(faults)*2, equivalent_controls=1)
    (output / 'summary.json').write_text(json.dumps(result, indent=2) + '\n')
    verify.require(report.read(root) == proof, 'original study changed')
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    print(json.dumps(review(args.root, args.output), indent=2))
