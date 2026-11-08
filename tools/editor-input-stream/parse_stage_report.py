"""진단 시각은 같은 요청의 마지막 입력에만 귀속한다. 단계 중앙값을 더하지 않는다."""
import argparse
import json
from pathlib import Path
import verify
import display_stages
import frame_wake_control
import target_frame_control
import observer_cpu
import observer_posts_control
import observer_work_control
import deferred_retry_control


def analyze(app, producer, meta):
    require = verify.require
    require(meta.get('diagnostic') is True, 'stage diagnostics required')
    display = meta.get('display_stages',False)
    require(type(display) is bool and display == any(name in app for name in ('display_stage_header','display_frames','display_draws')), 'display diagnostic label')
    verify.classify(app, producer, meta)
    rows = app.get('parse_stages')
    header = app.get('parse_stage_header')
    require(type(header) is list and len(header) == 2 and all(type(n) is int for n in header), 'stage header')
    require(type(rows) is list and 0 < len(rows) <= 2048 and header == [len(rows), 0], 'stage overflow/population')
    require(all(type(row) is list and len(row) == 9 and all(type(n) is int and 0 <= n < 2**64 for n in row) for row in rows), 'stage row shape')
    require(all(row[0] in range(1, 9) and row[1] > 0 and row[8] > 0 for row in rows), 'stage values')
    require(all(a[1] <= b[1] for a, b in zip(rows, rows[1:])), 'stage time order')
    revision = app['baseline'][1] + meta['count']
    accepted = [row for row in rows if row[0] == 5 and row[5] == revision]
    require(len(accepted) == 1, 'unique final accepted request')
    tag = accepted[0][2:7]
    final = [row for row in rows if row[2:7] == tag]
    stages = {number: [row for row in final if row[0] == number] for number in range(1, 9)}
    require(all(len(stages[n]) == 1 for n in range(1, 6)), 'final request lifecycle')
    count = 2 if meta['shared'] else 1
    require(all(len(stages[n]) == count for n in (6, 7, 8)), 'final view population')
    require(len({row[7] for row in stages[8]}) == count and all(row[7] > 0 for row in stages[8]), 'unique view installation')
    main = stages[1][0][8]
    require(all(row[8] == main for row in final if row[0] in (1, 5, 6, 7, 8)), 'main thread stages')
    worker = stages[2][0][8]
    require(worker != main and all(stages[n][0][8] == worker for n in (2, 3, 4)), 'worker thread stages')
    require(stages[3][0][7] == stages[4][0][7] == 0, 'final ready outcome')
    post = producer['events'][-1]['post_ns']
    timeline = [post, *(stages[n][0][1] for n in range(1, 6))]
    require(all(a <= b for a, b in zip(timeline, timeline[1:])), 'final lifecycle order')
    # 같은 메인 스레드의 준비/설치가 마지막 요청에서 순서대로 완료돼야 한다.
    views = [row for row in final if row[0] >= 6]
    require([row[0] for row in views] == [6, 7, 8] * count, 'view prepare/install order')
    require(views[0][1] >= timeline[-1], 'view before acceptance')
    shown = app['syntax_presentations'][-1][0]
    require(views[-1][1] <= shown, 'shown before install')
    points = timeline + [views[-1][1], shown]
    names = ('post_to_submit', 'queue', 'worker', 'publication', 'delivery', 'views', 'display')
    elapsed = {name: (end - start) / 1e6 for name, start, end in zip(names, points, points[1:])}
    elapsed['view_native_copy'] = sum(stages[7][i][1] - stages[6][i][1] for i in range(count)) / 1e6
    elapsed['last_post_to_syntax'] = (shown - post) / 1e6
    require(abs(sum(elapsed[n] for n in names) - elapsed['last_post_to_syntax']) < 1e-6, 'stage sum')
    result = dict(revision=revision, serial=tag[-1], views=count, elapsed_ms=elapsed)
    if display:
        result['display'] = display_stages.analyze(app,meta,views[-1][1],main,require)
    wake = meta.get('frame_wake_control')
    has_wake = any(name in app for name in ('frame_wake_mode','wake_input_start','wake_idle_start','wake_idle_end'))
    require((wake is not None) == has_wake, 'frame wake diagnostic label')
    retry_mode=meta.get('deferred_retry_control')
    require((retry_mode is not None)==any(name in app for name in ('deferred_retry_mode','retry_events','retry_header','retry_input_start','retry_idle_start','retry_idle_end')), 'retry diagnostic label')
    retry=deferred_retry_control.parse(app,meta,require) if retry_mode is not None else None
    if retry:result['deferred_retry']=retry
    if wake is not None:result['frame_wake'] = frame_wake_control.analyze(app,meta,require,retry)
    target = meta.get('target_frame_control',False)
    require(type(target) is bool and target == app.get('target_frame_control',False) and target == any(name in app for name in ('target_input_start','target_idle_start','target_idle_end','target_budget_header','target_budget_rows')), 'target diagnostic label')
    if target:result['target_frame'] = target_frame_control.analyze(app,meta,result['frame_wake'],require,retry)
    observer = meta.get('observer_cpu',False)
    require(type(observer) is bool and observer == app.get('observer_cpu',False) and observer == any(name in app for name in ('observer_input_start','observer_idle_start','observer_idle_end')), 'observer CPU label')
    if observer:result['observer_cpu'] = observer_cpu.analyze(app,result['frame_wake'],require)
    posts_mode=meta.get('observer_posts_control')
    require((posts_mode is not None)==any(name in app for name in ('observer_posts_mode','posts_input_start','posts_idle_start','posts_idle_end','posts_accepted_base64','posts_errors')), 'observer posts label')
    if posts_mode is not None:
        require(observer and target and retry is not None, 'observer posts dependency')
        result['observer_posts']=observer_posts_control.analyze(app,meta,result['observer_cpu'],require)
    work_mode=meta.get('observer_work_control')
    require((work_mode is not None)==any(n in app for n in ('observer_work_mode','work_input_start','work_idle_start','work_idle_end','work_events','work_errors')), 'observer work label')
    if work_mode is not None:
        require(posts_mode is not None, 'observer work dependency')
        result['observer_work']=observer_work_control.analyze(app,meta,result['observer_cpu'],result['observer_posts'],require)
    return result


def read(root):
    require = verify.require
    root = Path(root).resolve()
    manifest = json.loads((root/'study.json').read_text())
    require(manifest['kind'] == 'parse-stage-diagnostic' and manifest['complete'] is True, 'incomplete diagnostics')
    source = manifest['source']
    require(type(source.get('frame_wake_control',False)) is bool, 'frame wake source flag')
    require(source.get('parse_stages') is True and source.get('fold_reuse_control') is True, 'instrumented build required')
    build = Path(manifest['build'])
    require(json.loads((build/'source.json').read_text()) == source, 'build receipt drift')
    require(verify.sha(build/'source/zig-out/Maru.app/Contents/MacOS/maru-macos-app') == source['app_sha256'], 'stage app drift')
    require(verify.sha(build/'producer') == source['producer_sha256'], 'stage producer drift')
    require(all(verify.sha(build/'source'/name) == digest for name, digest in source['instrumented'].items()), 'instrumented source drift')
    require(all(verify.sha(root/'tools'/name) == digest for name, digest in manifest['tools'].items()), 'tool snapshot drift')
    repetitions = manifest['repetitions']
    require(type(repetitions) is int and 1 <= repetitions <= 3, 'diagnostic repetition bounds')
    expected = {f'{flow}-{rep}' for rep in range(repetitions) for flow in ('typing', 'shared')}
    require(len(manifest['runs']) == len(expected) and {run['path'] for run in manifest['runs']} == expected, 'diagnostic matrix')
    results = []
    for run in manifest['runs']:
        folder = root/run['path']
        require(verify.sha(folder/'record.json') == run['record_sha256'], 'record drift')
        meta = json.loads((folder/'record.json').read_text())
        require(type(source.get('observer_work_control',False)) is bool and (meta.get('observer_work_control') is not None)==source.get('observer_work_control',False), 'observer work source agreement')
        require(type(source.get('observer_posts_control',False)) is bool and (meta.get('observer_posts_control') is not None)==source.get('observer_posts_control',False), 'observer posts source agreement')
        require(type(source.get('deferred_retry_control',False)) is bool and (meta.get('deferred_retry_control') is not None)==source.get('deferred_retry_control',False), 'retry source agreement')
        require(type(source.get('observer_cpu',False)) is bool and meta.get('observer_cpu',False) is source.get('observer_cpu',False), 'observer CPU source agreement')
        require(type(source.get('target_frame_control',False)) is bool and meta.get('target_frame_control',False) is source.get('target_frame_control',False), 'target source agreement')
        require((meta.get('frame_wake_control') is not None) == source.get('frame_wake_control',False), 'frame wake source agreement')
        require(type(meta.get('display_stages',False)) is bool and meta.get('display_stages',False) is source.get('display_stages',False), 'display diagnostic source agreement')
        require(meta['error'] is None and meta['count'] == 30 and meta['size'] == 50000 and meta['period_ns'] == 50000000 and meta['mode'] == 'async' and meta['fixture_kind'] == 'multiline' and meta['fold_reuse_control'] == 'prepared', 'diagnostic condition')
        require(run['path'] == f"{meta['flow']}-{meta['repeat']}" and meta['shared'] == (meta['flow'] == 'shared'), 'diagnostic row label')
        require(all(verify.sha(folder/name) == meta[name+'_sha256'] for name in ('app.json', 'posts.json', 'app.log', 'producer.log', 'config', 'ready.json', 'source-record.json', 'source-recovery.json')), 'raw artifact drift')
        app = json.loads((folder/'app.json').read_text())
        posts = json.loads((folder/'posts.json').read_text())
        result = analyze(app, posts, meta)
        require(result == json.loads((folder/'stages.json').read_text()), 'stage summary differs from raw')
        results.append(dict(path=run['path'], **result))
    return dict(kind='parse-stage-diagnostic', head=source['head'], app_sha256=source['app_sha256'], processes=len(results), inputs=30*len(results), runs=results)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('root', type=Path)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    with args.output.open('x') as output:
        output.write(json.dumps(read(args.root), indent=2)+'\n')
