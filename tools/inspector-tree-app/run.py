#!/usr/bin/env python3
"""Real published dock trees -> native inspector clicks -> CLI and Metal evidence."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time


def identity(node):
    if node is None:
        return None
    generation = node['generation'] if node['source'] in ('file_tree', 'scm', 'agent_sessions', 'pane_divider') else 0
    return node['source'], node['id'], generation


def run(app, output, number):
    dest = output / f'round-{number:02d}'
    dest.mkdir()
    root = Path(tempfile.mkdtemp(prefix='mit-', dir='/tmp'))
    for directory in ('home', 'work', 'cache', 'state', 'host', 'backups'):
        (root / directory).mkdir()
    source = 'file_tree' if number <= 5 or number > 15 else 'scm' if number <= 10 else 'agent_sessions'
    dock = {'file_tree': '1', 'scm': 'scm', 'agent_sessions': 'sessions'}[source]
    work = root / 'work'
    (work / 'sample.txt').write_text('tree fixture\n')
    (work / 'folder').mkdir()
    (work / 'folder' / 'nested.txt').write_text('nested\n')
    subprocess.run(['git', 'init', '-q', str(work)], check=True)
    subprocess.run(['git', '-C', str(work), 'add', '.'], check=True)
    subprocess.run(['git', '-C', str(work), '-c', 'user.name=Fixture', '-c', 'user.email=fixture@example.invalid', 'commit', '-qm', 'fixture'], check=True)
    (work / 'sample.txt').write_text('changed tree fixture\n')
    archive = root / 'home/.codex/sessions/2026/10/21'
    archive.mkdir(parents=True)
    fixture = Path(__file__).resolve().parents[2] / 'tests/fixtures/agent-session-archive/codex-ready.jsonl'
    (archive / 'rollout-tree.jsonl').write_text(fixture.read_text().replace('"cwd":"/tmp"', '"cwd":' + json.dumps(str(work))))
    (root / 'demo.sh').write_text(f'cd "{work}"\nexec /bin/sh -i\n')
    (root / 'config').write_text(f'session.keep-alive-after-quit=false\nworkspace.restore=false\nworkspace.root={work}\nshell.command=/bin/sh\nshell.args={root}/demo.sh\nui.language={"en" if number % 2 else "ko"}\n')
    placement = (number - 1) % 5
    paused = 11 <= number <= 15
    phases = ['ready', 'selected', 'collapsed', 'searched', 'cleared', 'expanded', 'picked']
    point = dest / 'point.json'
    lines = ['sleep 1500', f'inspect-click {40 + placement}', 'inspect-click 24', 'sleep 700', f'inspect-main-capture {dest}/baseline.ppm', 'inspect-report ready', f'waitfile {dest}/ready-ok',
             'inspect-click 48', 'sleep 150', 'inspect-hover 100 row', 'inspect-click 100', 'sleep 400', f'inspect-main-capture {dest}/selected.ppm', 'inspect-report selected', f'waitfile {dest}/selected-ok']
    if paused:
        lines += ['inspect-click 13']
    lines += ['inspect-click 20000', 'sleep 400', f'inspect-main-capture {dest}/collapsed.ppm', 'inspect-report collapsed', f'waitfile {dest}/collapsed-ok',
              'inspect-click 6', f'inspect-text {source}', 'sleep 600', f'inspect-main-capture {dest}/searched.ppm', 'inspect-report searched', f'waitfile {dest}/searched-ok',
              'inspect-key 53 U+001B', 'sleep 500', 'inspect-report cleared', f'waitfile {dest}/cleared-ok',
              'inspect-click 20000', 'sleep 400', 'inspect-report expanded', f'waitfile {dest}/expanded-ok',
              'inspect-click 48', 'sleep 350', f'waitfile {point}', f'inspect-owner-pointer {point} hover', f'inspect-owner-pointer {point} click', 'sleep 500',
              f'inspect-main-capture {dest}/picked.ppm']
    if placement == 4:
        lines += [f'inspect-capture {dest}/detached.ppm', 'sleep 300']
    lines += ['inspect-report picked', f'waitfile {dest}/picked-ok', 'inspect-finish']
    (dest / 'input.txt').write_text('\n'.join(lines) + '\n')
    report = dest / 'report.txt'
    env = {k: v for k, v in os.environ.items() if not k.startswith('MARU_')}
    env.update(HOME=str(root / 'home'), CFFIXED_USER_HOME=str(root / 'home'), MARU_CONFIG=str(root / 'config'),
               XDG_CONFIG_HOME=str(root / 'home/.config'), XDG_CACHE_HOME=str(root / 'cache'), XDG_STATE_HOME=str(root / 'state'),
               MARU_SESSION_HOST_ROOT=str(root / 'host'), MARU_EDITOR_BACKUP_ROOT=str(root / 'backups'), MARU_NO_WORKSPACE_RESTORE='1',
               MARU_OPEN_INSPECTOR='1', MARU_INSPECTOR_WITH_DOCK=dock, MARU_INSPECTOR_APP_TEST='1', MARU_INSPECTOR_TAB='elements',
               MARU_WEB_OSR_TEST_INPUT=str(dest / 'input.txt'), MARU_WEB_OSR_TEST_REPORT=str(report))
    if number in (2, 7, 12, 17):
        env.update(MARU_SCREENSHOT=str(dest / 'auto.ppm'), MARU_SCREENSHOT_DELAY_MS='60000', MARU_SCREENSHOT_TIMEOUT_MS='70000', MARU_SCREENSHOT_RENDER_SCALE_MILLI='2000')
    observations = []
    errors = []
    done = set()
    initial = None
    selected_key = None
    expected_pick = None
    outline_node = None
    with (dest / 'app.log').open('w') as log:
        process = subprocess.Popen([str(app)], env=env, stdout=log, stderr=log, start_new_session=True)
        try:
            deadline = time.monotonic() + 50
            while time.monotonic() < deadline and process.poll() is None:
                text = report.read_text() if report.exists() else ''
                result = subprocess.run([str(app.parent / 'maru'), 'session', 'inspect', '1', '--json'], env=env, capture_output=True, text=True, timeout=3)
                if result.returncode == 0:
                    data = json.loads(result.stdout)
                    observations.append(data)
                    e = data['elements']
                    for phase in phases:
                        if phase in done or f'label={phase} ' not in text:
                            continue
                        tree = e['tree']
                        if phase == 'ready':
                            if not tree or tree[0]['key']['source'] != source or not tree[0]['children']:
                                raise RuntimeError(f'expected real {source} root, got {[(v["key"], v["children"]) for v in tree]}')
                            initial = tree
                            outline_node = tree[0]['node']
                            if data['field_info']['elements.query']['availability'] != 'available':
                                errors.append('empty query mislabeled as missing data')
                            # Verify the exported hierarchy against original published parents.
                            seen = {}
                            for branch in tree:
                                node = branch['node']
                                parent = seen.get((node['source'], node['parent_id'], node['generation']))
                                if branch['depth'] != (parent['depth'] + 1 if parent else 0):
                                    errors.append('CLI hierarchy depth disagrees with published parents')
                                if parent and tuple(branch['parent'][k] for k in ('source','id','generation')) != tuple(parent['key'][k] for k in ('source','id','generation')):
                                    errors.append('CLI hierarchy parent identity disagrees with published tree')
                                seen[(node['source'], node['id'], node['generation'])] = branch
                            selected_key = identity(tree[0]['node'])
                        elif phase == 'selected':
                            if e['picking']:
                                errors.append('tree selection retained Pick mode')
                            if identity(e['selected']) != selected_key:
                                errors.append('tree click did not select published root')
                            if 'label=row actual=hand' not in text:
                                errors.append('tree row cursor was not hand')
                        elif phase == 'collapsed':
                            if len(tree) >= len(initial) or tree[0]['expanded']:
                                errors.append('collapse retained descendants')
                            if identity(e['selected']) != selected_key:
                                errors.append('collapse changed selection')
                        elif phase == 'searched':
                            if e['query'] != source or not tree or not all(v['expanded'] for v in tree) or len(tree) <= 1:
                                errors.append('search did not reveal collapsed source ancestry')
                        elif phase == 'cleared':
                            if e['query'] or not tree or tree[0]['expanded']:
                                errors.append('clearing search lost collapse state')
                        elif phase == 'expanded':
                            if not tree or not tree[0]['expanded'] or len(tree) < len(initial):
                                errors.append('expand failed to restore tree')
                            candidates = [v for v in e['nodes'] if v['source'] == source and v['visible_rect']['width'] >= 4 and v['visible_rect']['height'] >= 4]
                            node = next((v for v in reversed(candidates) if v['action_id'] is not None), candidates[-1])
                            r = node['visible_rect']
                            x, y = r['x'] + r['width'] / 2, r['y'] + r['height'] / 2
                            expected_pick = next(v for v in reversed(e['nodes']) if v['visible_rect']['x'] <= x < v['visible_rect']['x'] + v['visible_rect']['width'] and v['visible_rect']['y'] <= y < v['visible_rect']['y'] + v['visible_rect']['height'])
                            point.write_text(json.dumps({'x': x, 'y': y}))
                        elif phase == 'picked':
                            if e['picking'] or identity(e['selected']) != identity(expected_pick):
                                errors.append('screen pick did not synchronize tree identity')
                            if not any(identity(v['node']) == identity(expected_pick) for v in tree):
                                errors.append('picked node missing from revealed hierarchy')
                        done.add(phase)
                        (dest / f'{phase}-ok').touch()
                if 'inspector finished' in text:
                    break
                time.sleep(.12)
            if done != set(phases):
                errors.append(f'missing phases {set(phases) - done}')
        except Exception as exc:
            errors.append(str(exc))
        finally:
            if process.poll() is None:
                try:
                    process.wait(timeout=2)
                except subprocess.TimeoutExpired:
                    os.killpg(process.pid, signal.SIGTERM)
                    process.wait(timeout=4)
    for name in ('baseline', 'selected', 'collapsed', 'searched', 'picked') + (('detached',) if placement == 4 else ()):
        ppm = dest / f'{name}.ppm'
        if ppm.exists():
            subprocess.run(['sips', '-s', 'format', 'png', str(ppm), '--out', str(ppm.with_suffix('.png'))], check=True, stdout=subprocess.DEVNULL)
        else:
            errors.append(f'missing actual Metal capture {name}')
    # Check the actual owner boundary pixels independently of the CLI selection.
    before = dest / 'baseline.ppm'
    after = dest / 'selected.ppm'
    if outline_node and before.exists() and after.exists():
        a, b = before.read_bytes().split(b'\n', 3), after.read_bytes().split(b'\n', 3)
        width, height = map(int, a[1].split())
        r = outline_node['visible_rect']
        x, y, w, h = [int(r[k]) for k in ('x', 'y', 'width', 'height')]
        if a[1] != b[1] or not (0 <= x < x+w <= width and 0 <= y < y+h <= height):
            errors.append('selected outline ROI outside owner capture')
        else:
            edge = [(xx, yy) for yy in range(y, y+h) for xx in range(x, x+w)
                    if xx-x < 2 or x+w-xx <= 2 or yy-y < 2 or y+h-yy <= 2]
            changed = sum(a[3][(yy*width+xx)*3:(yy*width+xx)*3+3] != b[3][(yy*width+xx)*3:(yy*width+xx)*3+3] for xx, yy in edge)
            (dest / 'pixels.json').write_text(json.dumps(dict(outline_edge_changed_pixels=changed, roi=[x,y,w,h])))
            if not changed:
                errors.append('tree selection did not paint owner outline')
    (dest / 'observations.json').write_text(json.dumps(observations, indent=2))
    result = dict(round=number, source=source, placement=placement, paused=paused, passed=not errors, errors=errors,
                  hypothesis=f'{source} hierarchy select/collapse/search/pick stays synchronized in placement {placement}, paused={paused}, language={"en" if number % 2 else "ko"}, retina={number in (2,7,12,17)}',
                  cli_samples=len(observations), root=str(root), transport='native NSEvent callbacks, live CLI, Metal readback; not physical HID')
    (dest / 'result.json').write_text(json.dumps(result, indent=2))
    return result


def main():
    p = argparse.ArgumentParser()
    p.add_argument('--app', type=Path, required=True)
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--start', type=int, default=1)
    p.add_argument('--rounds', type=int, default=20)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=False)
    results = []
    for number in range(args.start, args.start + args.rounds):
        result = run(args.app.resolve(), args.output.resolve(), number)
        results.append(result)
        print(number, 'PASS' if result['passed'] else 'FAIL', result['errors'], flush=True)
        (args.output / 'manifest.json').write_text(json.dumps(dict(binary_sha256=hashlib.sha256(args.app.read_bytes()).hexdigest(), passed=all(v['passed'] for v in results), rounds=results), indent=2))
        if not result['passed']:
            raise SystemExit(1)


if __name__ == '__main__':
    main()
