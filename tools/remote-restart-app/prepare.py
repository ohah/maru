#!/usr/bin/env python3
"""Build an immutable source-copy GUI observer; no user app or settings are changed."""
import argparse, hashlib, json, subprocess
from pathlib import Path

def replace_once(text, old, new):
    if text.count(old) != 1:
        raise RuntimeError('ambiguous observer insertion: ' + old)
    return text.replace(old, new)

def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--snapshot', required=True)
    ap.add_argument('--dependency-root', required=True)
    args = ap.parse_args()
    repo = Path(__file__).resolve().parents[2]
    snapshot = Path(args.snapshot).resolve()
    if snapshot.is_relative_to(repo):
        raise RuntimeError('snapshot must be outside the source checkout')
    if snapshot.exists():
        raise RuntimeError('snapshot already exists; preserve it')
    snapshot.mkdir(parents=True)
    subprocess.run(['rsync', '-a', '--exclude=.git', '--exclude=.zig-cache', '--exclude=zig-out',
                    '--exclude=node_modules', '--exclude=references', '--exclude=.env*',
                    str(repo) + '/', str(snapshot) + '/'], check=True)
    dependency_root = Path(args.dependency_root).resolve()
    for name in ('web/package.json', 'web/bun.lock'):
        if (repo / name).read_bytes() != (dependency_root / name).read_bytes():
            raise RuntimeError('dependency snapshot differs: ' + name)
    (snapshot / 'web/node_modules').symlink_to(dependency_root / 'web/node_modules', target_is_directory=True)
    debug = snapshot / 'src/platform/macos/app_session/debug_fixtures.zig'
    debug.write_text(debug.read_text() + '\n' + (repo / 'tools/remote-restart-app/observe.zig.inc').read_text())
    debug.write_text(debug.read_text() + '\n' + (repo / 'tools/remote-restart-app/ended.zig.inc').read_text())
    backend = snapshot / 'src/platform/macos/session_host/remote_term_backend.zig'
    backend.write_text(backend.read_text() + '\n' + (repo / 'tools/remote-restart-app/ended_backend.zig.inc').read_text())
    session = snapshot / 'src/platform/macos/app_session.zig'
    session.write_text(replace_once(session.read_text(), '        debug_fixtures.maybeDebugOpenNativeEditor(self);',
        '        debug_fixtures.maybeDebugOpenNativeEditor(self);\n        debug_fixtures.remoteRestartObserve(self);'))
    session.write_text(replace_once(session.read_text(),
        '    defer backend.maintenanceEventTick();',
        '    if (debug_fixtures.remoteEndedBeforeCoordinator(backend)) return .idle;\n'
        '    defer backend.maintenanceEventTick();'))
    host = snapshot / 'src/platform/macos/MaruAppHost.swift'
    host.write_text(replace_once(host.read_text(), '        maybeRunEditorIMESmoke()\n',
        '        maybeRunEditorIMESmoke()\n        maybeRunRemoteRestart()\n') + '\n' +
        (repo / 'tools/remote-restart-app/driver.swift.inc').read_text())
    renderer = snapshot / 'src/platform/macos/maru_metal_renderer.m'
    renderer.write_text(replace_once(renderer.read_text(), '    static const char *const gates[] = {',
        '    static const char *const gates[] = {\n        "MARU_REMOTE_RESTART_CAPTURE",'))
    agent = snapshot / 'src/platform/macos/app_session/agent.zig'
    agent.write_text(replace_once(agent.read_text(),
        '    const body = slot.notice.text();\n',
        (repo / 'tools/remote-restart-app/notice.zig.inc').read_text() +
        '    const body = slot.notice.text();\n'))
    agent.write_text(replace_once(agent.read_text(), '                if (e.replay) slot.notice.clear();\n',
        '                if (e.replay) slot.notice.clear();\n' +
        (repo / 'tools/remote-restart-app/match.zig.inc').read_text()))
    agent.write_text(replace_once(agent.read_text(),
        'pub fn captureTurnSnapshot(self: *AppSession, surface_id: u64, facts: TurnFacts, capture_id: turn_capture.Id) void {\n',
        'pub fn captureTurnSnapshot(self: *AppSession, surface_id: u64, facts: TurnFacts, capture_id: turn_capture.Id) void {\n' +
        (repo / 'tools/remote-restart-app/capture.zig.inc').read_text()))
    subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'macos-app-bundle'], cwd=snapshot, check=True)
    # Bind the result to the injected sources and the exact signed binaries, not just git HEAD.
    names = ['observe.zig.inc', 'driver.swift.inc', 'notice.zig.inc', 'match.zig.inc', 'capture.zig.inc', 'ended.zig.inc', 'ended_backend.zig.inc']
    binaries = ['maru', 'maru-macos-app']
    manifest = {
        'head': subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=repo, text=True).strip(),
        'observer_sources': {n: hashlib.sha256((repo / 'tools/remote-restart-app' / n).read_bytes()).hexdigest() for n in names},
        'signed_binaries': {n: hashlib.sha256((snapshot / 'zig-out/Maru.app/Contents/MacOS' / n).read_bytes()).hexdigest() for n in binaries},
    }
    (snapshot / 'remote-restart-source.json').write_text(json.dumps(manifest, indent=2) + '\n')

if __name__ == '__main__':
    main()
