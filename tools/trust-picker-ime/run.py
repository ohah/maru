#!/usr/bin/env python3
"""Actual trust-picker IME scene using the shared GUI launcher, HID relay and pixel oracle."""
import hashlib
import json
import os
from pathlib import Path
import sys

from prepare import load, prepare
from verify import validate, validate_diagnostic, validate_anchors, validate_windows

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
shared_gui = common.GUIApp
SCENE = os.environ.get('MARU_TRUST_IME_SCENE', 'trust')
if SCENE not in ('trust', 'env_names'): raise ValueError('unknown trust picker scene')
FIXTURE = 'original editor\n'


def scene_gui(app, env, *args, **kwargs):
    # Keep only the launcher's private controls and fixed system paths. The
    # environment scene must never inspect inherited user environment values.
    keys=('HOME','CFFIXED_USER_HOME','MARU_CONFIG','MARU_SESSION_HOST_ROOT','MARU_IME_DEBUG','MARU_PALETTE_IME','MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT','MARU_INSPECTOR_APP_TEST','MARU_PALETTE_IME_MODE')
    env={k:env[k] for k in keys}
    env.update(PATH='/usr/bin:/bin:/usr/sbin:/sbin',LANG='en_US.UTF-8',MARU_TRUST_IME_SCENE=SCENE,MARU_TEST_NAME_ONE='fixture',MARU_TEST_NAME_TWO='fixture')
    home=Path(env['HOME'])
    fixture=home/'trust-original.txt';fixture.write_text(FIXTURE)
    env['MARU_NATIVE_EDITOR']=str(fixture)
    trust_dir=home/'Library/Application Support/maru';trust_dir.mkdir(mode=0o700,parents=True)
    for word in ('한','韓'): (home/word).mkdir(mode=0o700)
    trust_file=trust_dir/'lsp-trust'
    trust_file.write_text(''.join('deny\t1\t'+str(home/word)+'\n' for word in ('한','韓')))
    trust_file.chmod(0o600)
    with Path(env['MARU_CONFIG']).open('a') as stream:
        stream.write('ui.language = en\nlsp.shell-environment = false\nlsp.enabled = '+('true' if SCENE=='env_names' else 'false')+'\n')
    return shared_gui(app,env,*args,**kwargs)


common.GUIApp = scene_gui


def run(app, output, mode='live'):
    # Shared manifest hashes describe the shared runner, not this private scene.
    # Record the actual scene/independent checker separately before any GUI input.
    manifest = {'schema': 'maru.trust-picker-ime-harness.v1', 'workflow': 'fixture', 'scene': SCENE, 'files_sha256': {
        name: hashlib.sha256((HERE / name).read_bytes()).hexdigest()
        for name in ('prepare.py', 'run.py', 'verify.py', 'driver.swift.inc', 'probe.zig.inc')
    }}
    manifest['shared_files_sha256'] = {name: hashlib.sha256((REPO / name).read_bytes()).hexdigest() for name in ('tools/address-ime/verify.py', 'tools/project-search-ime/probe.zig.inc', 'tools/project-search-ime/verify.py', 'tools/verify-ime-candidate-captures.swift')}
    (output / 'trust-harness.json').write_text(json.dumps(manifest, indent=2) + '\n')
    result = shared_run(app, output, mode, wait_timeout=225)
    report=json.loads((output/'run/result.json').read_text())
    raw=json.loads((output/'run/window-transcript.json').read_text())
    if (output/'run/home/trust-original.txt').read_text() != FIXTURE:
        raise RuntimeError('private source file changed on disk')
    private=Path((output/'private-root.txt').read_text().strip())/'run/home'
    expected=''.join('deny\t1\t'+str(private/word)+'\n' for word in ('한','韓'))
    if (output/'run/home/Library/Application Support/maru/lsp-trust').read_text()!=expected:
        raise RuntimeError('private trust decisions changed')
    validate_anchors(report,raw)
    validate_windows(report,raw,json.loads((output/'run/candidate.json').read_text()) if mode == 'live' else None)
    result.pop('terminal_return', None)
    result['editor_return'] = True
    return result


common.run = run
if __name__ == '__main__':
    common.main()
