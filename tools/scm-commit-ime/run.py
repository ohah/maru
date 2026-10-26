#!/usr/bin/env python3
"""Actual scm-commit IME scene using the shared GUI launcher, HID relay and pixel oracle."""
import hashlib
import json
import os
from pathlib import Path
import sys
import subprocess

from prepare import load, prepare
from verify import validate, validate_diagnostic, validate_anchors, git_unchanged

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
# Load shared orchestration under a distinct module name. Its imports must resolve
# to its own palette helpers; the address scene is explicitly injected afterward.
address_prepare = prepare
address_validate = validate
address_diagnostic = validate_diagnostic
saved = {name: sys.modules.pop(name, None) for name in ('prepare', 'verify')}
sys.path.insert(0, str(REPO / 'tools/palette-ime'))
try:
    common = load('palette_runner', REPO / 'tools/palette-ime/run.py')
finally:
    sys.path.pop(0)
    for name, module in saved.items():
        if module is not None:
            sys.modules[name] = module
common.prepare = address_prepare
common.validate = address_validate
common.validate_diagnostic = address_diagnostic
shared_run = common.run
shared_gui_app = common.GUIApp


def fixture_app(app, env, *args, **kwargs):
    # Arrange the actual shell cwd before launch; product Git discovery reads it.
    root = (Path(env['MARU_PALETTE_IME']) / 'scm-repo').resolve()
    root.mkdir(mode=0o700)
    def git(*args):
        subprocess.run(['/usr/bin/git', '-c', 'core.hooksPath=/dev/null', '-c', 'commit.gpgsign=false', '-C', str(root), *args], check=True, capture_output=True, timeout=15)
    git('init', '-q', '-b', 'main', '--template=')
    (root/'message.txt').write_text('initial\n')
    git('add', 'message.txt')
    git('-c', 'user.name=IME Fixture', '-c', 'user.email=ime@example.invalid', 'commit', '-qm', 'fixture')
    (root/'message.txt').write_text('staged\n')
    git('add', 'message.txt')
    config = Path(env['MARU_CONFIG'])
    with config.open('a') as stream:
        stream.write('workspace.root = ' + str(root) + '\n')
    return shared_gui_app(app, env, *args, **kwargs)


common.GUIApp = fixture_app


def run(app, output, mode='live'):
    # Shared manifest hashes describe the shared runner, not this private scene.
    # Record the actual scene/independent checker separately before any GUI input.
    manifest = {'schema': 'maru.scm-commit-ime-harness.v1', 'workflow': 'fixture', 'files_sha256': {
        name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
        for name in ('prepare.py', 'run.py', 'verify.py', 'driver.swift.inc', 'probe.zig.inc')
    }}
    manifest['shared_files_sha256'] = {name: hashlib.sha256((REPO / name).read_bytes()).hexdigest() for name in ('tools/address-ime/verify.py', 'tools/project-search-ime/probe.zig.inc', 'tools/project-search-ime/verify.py', 'tools/verify-ime-candidate-captures.swift')}
    (output / 'scm-harness.json').write_text(json.dumps(manifest, indent=2) + '\n')
    result = shared_run(app, output, mode, wait_timeout=195)
    git_unchanged(output / "run")
    validate_anchors(json.loads((output/"run/result.json").read_text()), json.loads((output/"run/window-transcript.json").read_text()))
    return result


common.run = run
if __name__ == '__main__':
    common.main()
