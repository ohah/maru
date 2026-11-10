"""동일 입력의 첫 drawable에 시각·획득 대기·포함 CPU 구간을 연결한다."""
import json
import math
from pathlib import Path
import statistics
import parse_stage_report
import protocol
import verify

MODES = ('untimed', 'timed')


def distribution(values):
    values = sorted(values)
    verify.require(bool(values), 'empty distribution')
    return dict(count=len(values), median=statistics.median(values), p95=values[math.ceil(.95*len(values))-1], maximum=max(values))


def overlap(rows, start, end):
    verify.require(0 < start <= end, 'interval window')
    selected = [row for row in rows if row[2] < end and row[3] > start] if start < end else []
    wall = sum(min(end, row[3])-max(start, row[2]) for row in selected)
    verify.require(wall <= end-start, 'overlapping interval ownership')
    return dict(wall_ms=wall/1e6, contained_cpu_ms=sum(row[4] for row in selected if start <= row[2] and row[3] <= end)/1e6, boundary_intervals=sum(not (start <= row[2] and row[3] <= end) for row in selected))


def intervals(app, keys, mode, main):
    require = verify.require
    started, completed = app.get('input_interval_started'), app.get('input_interval_completed')
    require(mode in MODES and app.get('input_display_mode') == mode, 'input interval mode')
    require(all(type(row) is list and len(row) == 2 and all(verify.uint(v) for v in row) for row in (started, completed)), 'interval counters')
    require(started[0] == completed[0]+1 and started[1] == completed[1] == len(keys) and completed[0] > 0, 'interval lifecycle')
    require(type(app.get('input_interval_errors')) is int and app['input_interval_errors'] == 0, 'interval error')
    rows = app.get('input_intervals')
    require(type(rows) is list and len(rows) <= 4096, 'interval population')
    require(verify.uint(app.get('input_finish_handler_begin')), 'finish boundary type')
    if mode == 'untimed':
        require(not rows and app['input_finish_handler_begin'] == 0, 'untimed measurements present')
        return {0: [], 1: []}
    require(all(type(row) is list and len(row) == 6 and all(verify.uint(v) for v in row) and row[0] in (0, 1) and 0 < row[2] < row[3] and row[4] <= row[3]-row[2] and row[5] == main for row in rows), 'interval row')
    own = {kind: [row for row in rows if row[0] == kind] for kind in (0, 1)}
    for kind in own:
        require(len(own[kind]) == completed[kind] and all(a[3] <= b[2] for a, b in zip(own[kind], own[kind][1:])), 'interval completion/order')
    require(all(row[1] == 0 for row in own[0]), 'observer interval token')
    require([row[1] for row in own[1]] == [row[1] for row in keys], 'native interval identity')
    require(all(key[3] <= row[2] < key[6] for row, key in zip(own[1], keys)), 'native interval arrival')
    finish = app['input_finish_handler_begin']
    require(max(key[6] for key in keys) <= finish and all(row[3] <= finish for row in own[0]), 'unfinished finish handler overlaps first display')
    return own


def key_trace(app, event, key, main):
    require = verify.require
    frames = [r for r in app['display_frames'] if r[0] == key[7]]
    draws = [r for r in app['display_draws'] if r[0] == key[7] and r[7] == key[6]]
    require(len(frames) == len(draws) == 1, 'input unique frame/drawable')
    frame, draw = frames[0], draws[0]
    require(frame[1] == app['baseline'][1]+frame[2] and frame[2] == draw[1] == key[8] and frame[3] == draw[2] == key[9], 'input frame ownership')
    require(frame[8] == draw[8] == main and main > 0, 'input frame thread')
    acquisitions = [r for r in app['input_drawables'] if r[0] == draw[0] and r[3] == draw[4]]
    require(len(acquisitions) == 1, 'input unique renderer invocation')
    acquired = acquisitions[0]
    require(acquired[:3] == draw[:3] and acquired[8] == main, 'input acquisition identity')
    points = [event['post_ns'], key[3], max(key[3], frame[5]), frame[6], frame[7], draw[3], draw[4], acquired[4], acquired[5], draw[5], draw[6], key[6]]
    require(all(verify.uint(v) and v > 0 for v in points) and all(a <= b for a, b in zip(points, points[1:])), 'input timeline order')
    overlay = 0
    if acquired[6] or acquired[7]:
        require(acquired[5] <= acquired[6] <= acquired[7] <= draw[5], 'overlay acquisition order')
        overlay = acquired[7]-acquired[6]
    parts = dict(post_to_native=(key[3]-event['post_ns'])/1e6,
                 native_to_tick=(points[2]-key[3])/1e6,
                 frame_prepare=(frame[6]-points[2])/1e6,
                 tick_finalize=(frame[7]-frame[6])/1e6,
                 wait_for_swift=(draw[3]-frame[7])/1e6,
                 swift_prepare=(draw[4]-draw[3])/1e6,
                 renderer_before_drawable=(acquired[4]-draw[4])/1e6,
                 terminal_drawable=(acquired[5]-acquired[4])/1e6,
                 overlay_drawable=overlay/1e6,
                 renderer_other=(draw[5]-acquired[5]-overlay)/1e6,
                 arm_to_commit=(draw[6]-draw[5])/1e6,
                 commit_to_present=(key[6]-draw[6])/1e6)
    total = (key[6]-event['post_ns'])/1e6
    require(abs(sum(parts.values())-total) < 1e-6, 'input interval sum')
    return dict(sequence=key[0], total_ms=total, native_to_present_ms=(key[6]-key[3])/1e6, parts_ms=parts)


def analyze(app, producer, meta, mode):
    parent = parse_stage_report.analyze(app, producer, meta)
    header, acquired = app.get('input_draw_header'), app.get('input_drawables')
    require = verify.require
    require(type(header) is list and len(header) == 4 and all(verify.uint(v) for v in header), 'acquisition header')
    require(type(acquired) is list and 0 < len(acquired) <= 2048 and header[:2] == [len(acquired), 0], 'acquisition overflow/count')
    require(all(type(row) is list and len(row) == 9 and all(verify.uint(v) for v in row) for row in acquired), 'acquisition row shape')
    require(len(acquired) == len(app['display_draws']) and len({(row[0], row[3]) for row in acquired}) == len(acquired), 'renderer invocation population')
    main = next(row[8] for row in app['parse_stages'] if row[0] == 1)
    own = intervals(app, app['keys'], mode, main)
    rows = []
    for event, key in zip(producer['events'], app['keys']):
        trace = key_trace(app, event, key, main)
        if mode == 'timed':
            trace['observer_in_native_to_present'] = overlap(own[0], key[3], key[6])
            trace['native_handler_in_native_to_present'] = overlap([row for row in own[1] if row[1] == key[1]], key[3], key[6])
        rows.append(trace)
    return dict(parent=parent, keys=rows, drawable_failures=dict(terminal=header[2], overlay=header[3]), observer_completed_handlers=len(own[0]), observer_inclusive_cpu_ms=sum(row[4] for row in own[0])/1e6 if mode == 'timed' else None)


def cohort_manifest(manifest, source):
    expected = {f'{flow}-{rep}' for rep in range(3) for flow in ('typing', 'shared')}
    verify.require(manifest.get('source') == source, 'input display source pairing')
    verify.require(manifest.get('repetitions') == 3, 'input display three process repetitions required')
    rows = manifest.get('runs')
    verify.require(type(rows) is list and len(rows) == len(expected) and all(type(row) is dict and type(row.get('path')) is str for row in rows) and {row.get('path') for row in rows} == expected, 'input display actual cohort population')


def read(root):
    root = Path(root).resolve()
    study = json.loads((root / 'study.json').read_text())
    verify.require(study.get('kind') == 'current-input-display' and study.get('complete') is True, 'incomplete input display study')
    source = study['source']
    verify.require(source.get('input_display') is True and source.get('display_stages') is True, 'input display capability')
    verify.require(not any(source.get(name, False) for name in ('frame_wake_control', 'target_frame_control', 'observer_cpu', 'deferred_retry_control', 'observer_posts_control', 'observer_work_control')), 'experimental policy mixed into product attribution')
    reports = {}
    for mode in MODES:
        folder = root / mode
        manifest = json.loads((folder / 'study.json').read_text())
        cohort_manifest(manifest, source)
        common = parse_stage_report.read(folder)
        runs = []
        for item in manifest['runs']:
            target = folder / item['path']
            app = json.loads((target / 'app.json').read_text())
            producer = json.loads((target / 'posts.json').read_text())
            meta = json.loads((target / 'record.json').read_text())
            marker=meta.get('observer_start')
            verify.require(type(marker) is dict and marker.get('input_display_mode') == mode, 'requested interval mode')
            result=analyze(app, producer, meta, mode)
            verify.require(result == json.loads((target / 'input-display.json').read_text()), 'input summary differs from raw')
            runs.append(dict(path=item['path'], flow=meta['flow'], **result))
        groups = {}
        for flow in ('typing', 'shared'):
            keys = [key for run in runs if run['flow'] == flow for key in run['keys']]
            groups[flow] = dict(total=distribution([r['total_ms'] for r in keys]), native_to_present=distribution([r['native_to_present_ms'] for r in keys]), parts={part: distribution([r['parts_ms'][part] for r in keys]) for part in keys[0]['parts_ms']})
        reports[mode] = dict(head=common['head'], app_sha256=common['app_sha256'], runs=runs, groups=groups)
    expected = {f'{flow}-{rep}' for rep in range(3) for flow in ('typing', 'shared')}
    pairs = study.get('pairs')
    verify.require(type(pairs) is list and len(pairs) == len(expected) and {p['path'] for p in pairs} == expected, 'input display pairing')
    for pair in pairs:
        repetition = int(pair['path'].rsplit('-', 1)[1])
        verify.require(pair['order'] == list(MODES if repetition % 2 == 0 else MODES[::-1]), 'input display execution order')
    return dict(kind='current-input-display', source=source, reader_sha256=verify.sha(Path(__file__)), base_reader_sha256=verify.sha(Path(parse_stage_report.__file__)), **reports)


if __name__ == '__main__':
    import argparse
    parser=argparse.ArgumentParser()
    parser.add_argument('root',type=Path)
    parser.add_argument('--output',type=Path,required=True)
    args=parser.parse_args()
    with args.output.open('x') as stream:stream.write(json.dumps(read(args.root),indent=2)+'\n')
