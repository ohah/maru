"""양쪽 원시 자료를 독립 재계산하고 같은 앱·짝·실제 분기를 검증한다."""
import argparse
import json
from pathlib import Path
import parse_stage_report
import verify


def read(root):
    root = Path(root).resolve()
    study = json.loads((root/'study.json').read_text())
    verify.require(study['kind'] == 'frame-wake-comparison' and study['complete'] is True, 'incomplete frame wake comparison')
    reports = {}
    populations = []
    for mode in ('scheduled','immediate'):
        manifest = json.loads((root/mode/'study.json').read_text())
        verify.require(manifest['source'] == study['source'], 'frame wake source differs')
        report = parse_stage_report.read(root/mode)
        verify.require(all(row['frame_wake']['mode'] == mode for row in report['runs']), 'frame wake cohort label differs')
        for row in report['runs']:
            folder = root/mode/row['path']
            app = json.loads((folder/'app.json').read_text())
            posts = json.loads((folder/'posts.json').read_text())
            meta = json.loads((folder/'record.json').read_text())
            validated = verify.classify(app,posts,meta)
            names = ('post_to_present_ms','coalesced_keys','syntax_ready_before_next_post','syntax_ready_on_first_present_count','max_producer_lateness_ms')
            row['input_display'] = {name:validated[name] for name in names}
            row['memory_bytes'] = dict(peak=app['memory'][0],baseline_resident=app['baseline_memory'][1],final_resident=app['memory'][1])
        populations.append({row['path'] for row in report['runs']})
        reports[mode] = report
    verify.require(populations[0] == populations[1], 'frame wake pairing differs')
    pairs = study['pairs']
    verify.require(len(pairs) == len(populations[0]) and {pair['path'] for pair in pairs} == populations[0], 'frame wake comparison population')
    for pair in pairs:
        rep = int(pair['path'].rsplit('-',1)[1])
        expected = ['scheduled','immediate'] if rep%2 == 0 else ['immediate','scheduled']
        verify.require(pair['order'] == expected, 'frame wake comparison order')
    here = Path(__file__).resolve().parent
    readers = ('frame_wake_report.py','parse_stage_report.py','frame_wake_control.py','display_stages.py','verify.py','protocol.py','summary_control.py','fold_control.py','bracket_control.py','fold_reuse_control.py','target_frame_control.py','target_frame_budget.c.inc','observer_cpu.py')
    return dict(kind='frame-wake-comparison',variant='target-coalesced' if study['source'].get('target_frame_control') else 'global-tick',reader_dependencies={name:verify.sha(here/name) for name in readers},**reports)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    with args.output.open('x') as output:
        output.write(json.dumps(read(args.root),indent=2)+'\n')
