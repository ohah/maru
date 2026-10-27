#!/usr/bin/env python3
"""Actual first-save IME input with private files and an unchanged external capture app."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys

from prepare import load, prepare
from verify import CASES, SENTINEL, validate, validate_diagnostic

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
# Shared imports must resolve to the palette module's helpers during loading.
saved = {name: sys.modules.pop(name, None) for name in ('prepare', 'verify')}
sys.path.insert(0, str(REPO / 'tools/palette-ime'))
try:
    common = load('first_save_palette_runner', REPO / 'tools/palette-ime/run.py')
finally:
    sys.path.pop(0)
    for name, module in saved.items():
        if module is not None:
            sys.modules[name] = module
common.validate_diagnostic = validate_diagnostic
common.validate = validate
base_launch = common.GUIApp


def run(app, output, scenario, capture_app):
    projects = []
    def launch(binary, env, gui, **kwargs):
        root = Path(env['MARU_PALETTE_IME'])
        project = root / 'project'
        project.mkdir(mode=0o700)
        projects.append(project)
        config = Path(env['MARU_CONFIG'])
        config.write_text(config.read_text() + 'workspace.root = ' + str(project.resolve()) + '\n')
        if scenario in ('overwrite', 'reject'):
            (project / '韓').write_bytes(SENTINEL)
        if scenario == 'write-failure':
            project.chmod(0o500)
        env.update(MARU_UNTITLED_PROJECT=str(project.resolve()), MARU_UNTITLED_IME_CASE=scenario,
                   MARU_UNTITLED_CAPTURE_APP=str(capture_app.resolve()))
        return base_launch(binary, env, gui, **kwargs)
    common.GUIApp = launch
    hashes = {name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
              for name in ('run.py', 'prepare.py', 'probe.zig.inc', 'finish.swift.inc', 'capture.swift.inc', 'verify.py')}
    shared = ('tools/rename-ime/prepare.py', 'tools/rename-ime/driver.swift.inc', 'tools/rename-ime/probe.zig.inc',
              'tools/palette-ime/run.py', 'tools/palette-ime/prepare.py', 'tools/palette-ime/relay.swift',
              'tools/palette-ime/PointerPolicy.swift', 'tools/shared-restore-app/gui_launch.py',
              'src/platform/macos/SessionHostInputSourcePolicy.swift')
    shared_hashes = {name: hashlib.sha256((REPO/name).read_bytes()).hexdigest() for name in shared}
    (output / 'first-save-harness.json').write_text(json.dumps(
        {'scenario': scenario, 'files_sha256': hashes, 'shared_files_sha256': shared_hashes}, indent=2)+'\n')
    try:
        common.run(app, output, 'diagnostic')
    finally:
        common.GUIApp = base_launch
        for project in projects:
            project.chmod(0o700)
        # The shared runner copies even failed evidence; restore only our private copied mode.
        if (output / 'run/project').exists():
            (output / 'run/project').chmod(0o700)
    report = json.loads((output / 'run/result.json').read_text())
    result = validate_diagnostic(report, output / 'run')
    (output / 'validation.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--app', type=Path)
    parser.add_argument('--case', choices=CASES, default='hanja')
    parser.add_argument('--capture-app', type=Path, default=Path.home()/'Applications/Maru Screen Capture.app')
    parser.add_argument('--prepare-only', action='store_true')
    args = parser.parse_args()
    output = args.output.resolve()
    if output.exists() or output.is_relative_to(REPO.resolve()):
        parser.error('a new external output directory is required')
    if not args.capture_app.is_dir():
        parser.error('an existing authorized native capture app is required')
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
    print(json.dumps(run(app, output, args.case, args.capture_app), ensure_ascii=False))


if __name__ == '__main__':
    main()
