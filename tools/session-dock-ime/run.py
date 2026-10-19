#!/usr/bin/env python3
"""Opt-in Session Dock input checks; callbacks and actual Korean HID are separate gates."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import sys
import tempfile

from prepare import prepare, require_external_destination
from verify import validate_report, validate_candidate_transitions
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools/shared-restore-app'))
from gui_launch import GUIApp


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(app, output, mode):
    private = Path(tempfile.mkdtemp(prefix='maru-session-dock-ime-', dir='/tmp')).resolve()
    root = private / 'zig-out/maru-agent-session-archive-smoke'
    home = root / 'home'
    logs = root / 'gui'
    host = private / 'host'
    for path in (home, logs, host, root / 'captures', root / 'bin'):
        path.mkdir(parents=True, exist_ok=True, mode=0o700)
    source = home / '.codex/sessions/2026/08/03/rollout-fixture.jsonl'
    source.parent.mkdir(parents=True)
    fixtures = REPO / 'tests/fixtures/agent-session-archive'
    shutil.copy2(fixtures / 'codex-ready.jsonl', source)
    for name in ('second', 'third'):
        path = source.with_name('rollout-list-' + name + '.jsonl')
        shutil.copy2(fixtures / ('codex-list-' + name + '.jsonl'), path)
        os.utime(path, (946684800, 946684800))
    for name in ('codex', 'claude'):
        path = root / 'bin' / name
        shutil.copy2(fixtures / ('fake-' + name + '.sh'), path)
        path.chmod(0o700)
    config = root / 'config'
    shutil.copy2(fixtures / 'font-size-14.config', config)
    # Match the existing actual-IME gate: Option-Return must reach the input method
    # rather than the terminal's default Option-as-Meta shortcut route.
    with config.open('a') as stream:
        stream.write('\ninput.option-as-meta = false\n')
    env = dict(os.environ, HOME=str(home), CFFIXED_USER_HOME=str(home),
        XDG_CONFIG_HOME=str(home / '.config'), XDG_DATA_HOME=str(home / '.local/share'),
        XDG_STATE_HOME=str(home / '.local/state'), XDG_CACHE_HOME=str(home / '.cache'),
        MARU_SESSION_HOST_ROOT=str(host), MARU_CONFIG=str(config), MARU_IME_DEBUG='1',
        MARU_APP_SUMMARY_PATH=str(root / 'app.summary.txt'), MARU_MACOS_APP_SMOKE_MS='120000',
        MARU_SESSION_DOCK_IME=mode, MARU_AGENT_SESSION_ARCHIVE_SMOKE='1',
        MARU_AGENT_SESSION_ARCHIVE_SMOKE_SCENARIO='resume-pointer',
        MARU_AGENT_SESSION_ARCHIVE_SMOKE_MARKER=str(root / 'fake-provider.verdict'),
        MARU_AGENT_SESSION_ARCHIVE_SMOKE_FAKE_CODEX=str(root / 'bin/codex'),
        MARU_AGENT_SESSION_ARCHIVE_SMOKE_FAKE_CLAUDE=str(root / 'bin/claude'),
        MARU_AGENT_SESSION_ARCHIVE_SMOKE_REVEAL_PATH=str(source),
        MARU_AGENT_SESSION_ARCHIVE_SMOKE_ARTIFACT_DIR=str(root),
        MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT=str(root))
    cli = app.with_name('maru')
    digests = {app.name: sha(app), cli.name: sha(cli)}
    child = None
    try:
        if mode == 'live':
            subprocess.run(['swiftc', str(REPO / 'src/platform/macos/SessionHostInputSourcePolicy.swift'),
                str(REPO / 'src/platform/macos/SessionHostInputSourceRestore.swift'), '-o', str(private / 'restore-input-source')],
                check=True, capture_output=True, timeout=60)
        # Keep one byte-identical staged path across retries so a TCC grant is not tied to a
        # temporary bundle that cleanup removes. The per-run HOME and evidence remain private.
        stage_root = Path('/private/tmp') / ('maru-session-dock-ime-apps-' + str(os.getuid()))
        stage_root.mkdir(mode=0o700, exist_ok=True)
        info = stage_root.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
            raise RuntimeError('unsafe staged bundle owner or permissions')
        child = GUIApp(app, env, logs, expected_binaries=digests, stage_root=stage_root)
        (root / 'staged-app-path.txt').write_text(str(child.executable.parents[2]) + '\n')
        code = child.wait(timeout=110)
        report = json.loads((root / 'result.json').read_text())
        validate_report(report, mode)
        if code != 0:
            raise RuntimeError('GUI waiter failed')
        if mode == 'live':
            candidate = json.loads((root / 'candidate.json').read_text())
            validate_candidate_transitions(candidate, report)
            (root / 'candidate-query-verifier.json').write_text(json.dumps(dict(passed=True, observations=5)) + '\n')
            oracle = private / 'verify-candidate-captures'
            subprocess.run(['swiftc', str(REPO / 'tools/verify-ime-candidate-captures.swift'), '-o', str(oracle)], check=True, capture_output=True, timeout=60)
            verification = subprocess.run([str(oracle), str(root / 'candidate.json')], text=True, capture_output=True, timeout=45)
            (root / 'candidate-pixel-verifier.log').write_text(verification.stdout + verification.stderr)
            if verification.returncode:
                raise RuntimeError('independent candidate pixel verification failed')
        for ppm in (root / 'captures').glob('*.ppm'):
            subprocess.run(['sips', '-s', 'format', 'png', str(ppm), '--out', str(ppm.with_suffix('.png'))], check=True, capture_output=True, timeout=15)
        return dict(passed=True, mode=mode, app_sha256=digests[app.name], cli_sha256=digests[cli.name])
    finally:
        try:
            if child is not None:
                try:
                    if child.poll() is None:
                        child.kill()
                finally:
                    child.close()
        finally:
            # Restoration owns only our Korean selection. The helper preserves a third user choice.
            restorer = private / 'restore-input-source'
            if restorer.exists() and (root / 'input-source.json').exists():
                restored = subprocess.run([str(restorer), str(root / 'input-source.json')], capture_output=True, text=True, timeout=15)
                (root / 'input-source-fallback.log').write_text(restored.stdout + restored.stderr)
            subprocess.run(['cp', '-cR', str(root), str(output / 'run')], check=True)
            active = subprocess.run(['lsof', '-t', '+D', str(private)], capture_output=True, text=True)
            if active.returncode == 1 and not active.stderr:
                shutil.rmtree(private)
            else:
                (output / 'retained-private-root.txt').write_text(str(private) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True, help='new directory for artifacts and optional source copy')
    parser.add_argument('--mode', choices=('callbacks', 'live'), default='callbacks')
    parser.add_argument('--app', type=Path, help='reuse the exact already-built instrumented app executable')
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    require_external_destination(REPO, output)
    if output.exists():
        parser.error('output must be a new directory')
    output.mkdir(parents=True, mode=0o700)
    app = args.app.resolve() if args.app else None
    if app is None:
        snapshot = output / 'snapshot'
        prepare(REPO, snapshot)
        if args.prepare_only:
            print(snapshot); return
        with (output / 'build.log').open('w') as log:
            subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'macos-app-bundle'], cwd=snapshot,
                stdout=log, stderr=subprocess.STDOUT, check=True)
        app = snapshot / 'zig-out/Maru.app/Contents/MacOS/maru-macos-app'
    result = run(app, output, args.mode)
    (output / 'validation.json').write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
