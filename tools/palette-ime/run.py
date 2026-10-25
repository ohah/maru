#!/usr/bin/env python3
"""Real palette Korean/Hanja test with a private app, external HID and independent PNG oracle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import stat
import shutil
import subprocess
import sys
import tempfile
import time

from prepare import prepare
from verify import validate, validate_diagnostic

REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / 'tools/shared-restore-app'))
from gui_launch import GUIApp, stage_app


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(app, output, mode='live', wait_timeout=115):
    private = Path(tempfile.mkdtemp(prefix='maru-palette-live-', dir='/tmp'))
    # Keep app-opened files outside privacy-protected Documents/Desktop paths.
    # The authorized parent copies evidence to the requested destination afterward.
    root = private / 'run'
    for path in (root / 'home', root / 'gui', root / 'captures', private / 'host'):
        path.mkdir(parents=True, mode=0o700)
    helper_dir = private / 'relay'
    helper_dir.mkdir()
    (helper_dir / 'main.swift').write_text((REPO / 'tools/palette-ime/relay.swift').read_text())
    subprocess.run(['xcrun', 'swiftc', str(REPO / 'src/platform/macos/SessionHostInputSourcePolicy.swift'),
                    str(REPO / 'tools/palette-ime/PointerPolicy.swift'), str(helper_dir / 'main.swift'), '-o', str(private / 'hid-relay')], check=True, capture_output=True, timeout=60)
    subprocess.run(['xcrun', 'swiftc', str(REPO / 'src/platform/macos/SessionHostInputSourcePolicy.swift'),
                    str(REPO / 'src/platform/macos/SessionHostInputSourceRestore.swift'), '-o', str(private / 'restore-input')], check=True, capture_output=True, timeout=60)
    config = root / 'config'
    config.write_text('font.size = 14\ninput.option-as-meta = false\nshell.command = /bin/cat\nshell.args =\n')
    env = dict(os.environ, HOME=str(root / 'home'), CFFIXED_USER_HOME=str(root / 'home'),
               MARU_CONFIG=str(config), MARU_SESSION_HOST_ROOT=str(private / 'host'), MARU_IME_DEBUG='1',
               MARU_PALETTE_IME=str(root), MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT=str(root),
               # This existing renderer-only gate enables one-shot GPU captures;
               # it has no Inspector UI/input consumer in this source revision.
               MARU_INSPECTOR_APP_TEST='1')
    env['MARU_PALETTE_IME_MODE'] = mode
    # TCC grants name this exact app: keep it across reboots, unlike /private/tmp.
    stage_root = Path.home() / 'Library/Application Support/Maru IME Verification/Palette'
    stage_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    info = stage_root.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o077:
        raise RuntimeError('unsafe staged app root')
    app = stage_app(app, stage_root)
    manifest = dict(app=str(app), app_sha256=sha(app), cli_sha256=sha(app.with_name('maru')),
                    git_head=subprocess.check_output(['git', 'rev-parse', 'HEAD'], cwd=REPO, text=True).strip(),
                    tools_sha256={name: sha(REPO / 'tools/palette-ime' / name) for name in
                                  ('prepare.py', 'driver.swift.inc', 'probe.zig.inc', 'relay.swift', 'PointerPolicy.swift', 'verify.py', 'run.py')},
                    scope='private read-only witnesses; product input and renderer; external actual HID')
    (root / 'manifest.json').write_text(json.dumps(manifest, indent=2) + '\n')
    child = relay = None
    relay_log = (root / 'hid-relay.log').open('w')
    try:
        child = GUIApp(app, env, root / 'gui', expected_binaries={app.name: manifest['app_sha256'], 'maru': manifest['cli_sha256']}, stage_root=stage_root)
        end = time.monotonic() + 20
        while True:
            try:
                pid = child.pid
                break
            except RuntimeError:
                if time.monotonic() > end:
                    raise
                time.sleep(.05)
        # A background app's activate(ignoringOtherApps:) is no longer sufficient
        # on recent macOS. Hand off activation from the initiating parent first.
        activation = subprocess.run(['swift', '-e',
            'import AppKit; import Foundation; '
            f'guard let app=NSRunningApplication(processIdentifier: {pid}) else {{ exit(1) }}; '
            'for _ in 0..<200 { if app.isFinishedLaunching { break }; Thread.sleep(forTimeInterval:0.05) }; '
            'guard app.activate(options:[.activateAllWindows]) else { exit(2) }'],
            capture_output=True, text=True, timeout=20)
        (root / 'gui/activation.log').write_text(activation.stdout + activation.stderr)
        if activation.returncode:
            raise RuntimeError('could not activate the owned fixture app')
        relay = subprocess.Popen([str(private / 'hid-relay'), str(root), str(pid)], stdout=relay_log, stderr=subprocess.STDOUT)
        code = child.wait(timeout=wait_timeout)
        report = json.loads((root / 'result.json').read_text())
        if code or report.get('passed') is not True:
            raise RuntimeError('palette GUI failed: ' + repr(report.get('failures')))
        if mode == 'diagnostic':
            validate_diagnostic(report)
            return dict(mode=mode, full_validation=False, input_diagnostic_passed=True, manifest=manifest)
        candidate = json.loads((root / 'candidate.json').read_text())
        validate(report, candidate)
        oracle = private / 'candidate-pixel-oracle'
        subprocess.run(['xcrun', 'swiftc', str(REPO / 'tools/verify-ime-candidate-captures.swift'), '-o', str(oracle)], check=True, capture_output=True, timeout=60)
        result = subprocess.run([str(oracle), str(root / 'candidate.json')], capture_output=True, text=True, timeout=45)
        (root / 'candidate-pixel-oracle.log').write_text(result.stdout + result.stderr)
        if result.returncode:
            raise RuntimeError('independent candidate pixel oracle failed')
        for ppm in (root / 'captures').glob('*.ppm'):
            subprocess.run(['sips', '-s', 'format', 'png', str(ppm), '--out', str(ppm.with_suffix('.png'))], check=True, capture_output=True, timeout=15)
        return dict(passed=True, manifest=manifest, candidates=5, hanja_selection=True, terminal_return=True)
    finally:
        if relay is not None and relay.poll() is None:
            relay.terminate()
            relay.wait(timeout=5)
        relay_log.close()
        if child is not None:
            try:
                if child.poll() is None:
                    child.kill()
            finally:
                child.close()
        if (root / 'input-source.json').exists():
            restored = subprocess.run([str(private / 'restore-input'), str(root / 'input-source.json')], capture_output=True, text=True, timeout=15)
            (root / 'source-fallback.log').write_text(restored.stdout + restored.stderr)
        shutil.copytree(root, output / 'run')
        (output / 'private-root.txt').write_text(str(private) + '\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--prepare-only', action='store_true')
    parser.add_argument('--mode', choices=('live', 'diagnostic'), default='live')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or output.is_relative_to(REPO.resolve()):
        parser.error('a new external output directory is required')
    output.mkdir(parents=True, mode=0o700)
    app = args.app.resolve() if args.app else None
    if app is None:
        snapshot = output / 'snapshot'
        prepare(REPO, snapshot)
        if args.prepare_only:
            print(snapshot)
            return
        with (output / 'build.log').open('w') as log:
            subprocess.run(['mise', 'exec', '--', 'zig', 'build', 'macos-app-build', '-j2'], cwd=snapshot,
                           stdout=log, stderr=subprocess.STDOUT, check=True)
        app = snapshot / 'zig-out/Maru.app/Contents/MacOS/maru-macos-app'
    result = run(app, output, args.mode)
    name = 'validation.json' if args.mode == 'live' else 'diagnostic.json'
    (output / name).write_text(json.dumps(result, indent=2) + '\n')
    print(json.dumps(result))


if __name__ == '__main__':
    main()
