#!/usr/bin/env python3
"""Actual owned GUI quit/restore; invoke inside the existing private SSH carrier."""
import hashlib, json, os, re, shlex, signal, subprocess, sys, time, uuid
from pathlib import Path

def probe(app, cli, root, remote, sshconfig, alias, env, emit_hooks, artifacts):
    sys.path.insert(0, str(Path(__file__).resolve().parents[1] / 'shared-restore-app'))
    from gui_launch import GUIApp, process_identity
    app = Path(app).resolve()
    artifacts = Path(artifacts).resolve()
    artifacts.mkdir(parents=True, exist_ok=False)
    source_manifest = app.parents[4] / 'remote-restart-source.json'
    manifest = json.loads(source_manifest.read_text())
    for name, path in [('maru-macos-app', app), ('maru', Path(cli))]:
        if hashlib.sha256(path.read_bytes()).hexdigest() != manifest['signed_binaries'][name]:
            raise RuntimeError('signed binary differs from source manifest: ' + name)
    (artifacts / 'source.json').write_bytes(source_manifest.read_bytes())
    state = subprocess.run(['swift', '-e', 'import CoreGraphics; if (CGSessionCopyCurrentDictionary() as? [String:Any])?["CGSSessionScreenIsLocked"] as? Int == 1 { exit(1) }'], capture_output=True)
    if state.returncode: raise RuntimeError('screen locked; GUI probe has not launched')
    home = root / 'gui-home'; home.mkdir()
    host_root = root / 'gui-host'
    marker = 'maru-restart-' + str(uuid.uuid4())
    config = root / 'gui-config'
    pane = root / 'gui-pane.sh'
    pane.write_text('#!/bin/sh\nexport HOME=' + shlex.quote(str(home)) + '\nexport XDG_CACHE_HOME=' +
                    shlex.quote(str(home / '.cache')) + '\nexport MARU_CONFIG=' + shlex.quote(str(config)) +
                    '\nexec ' + shlex.join([cli, 'ssh', '-F', str(sshconfig), '-T', alias]) + '\n')
    pane.chmod(0o700)
    config.write_text(f'shell.command = {pane}\nshell.args =\nsidebar.agent-hooks = true\nssh.reconnect = false\nsession.keep-alive-after-quit = true\n')
    childenv = {k: v for k, v in env.items() if not k.startswith('MARU_')}
    childenv.update(HOME=str(home), CFFIXED_USER_HOME=str(home), XDG_CACHE_HOME=str(home / '.cache'),
                    MARU_CONFIG=str(config), MARU_SESSION_HOST_ROOT=str(host_root),
                    MARU_REMOTE_RESTART_NOTICE_ID=marker, MARU_REMOTE_RESTART_CAPTURE="1")
    cache = home / '.cache/maru'; cache.mkdir(parents=True)
    (cache / 'ssh-terminfo-hosts').write_text(alias + '\n')
    (remote / 'gui-hold').touch()
    children = []; owned_hosts = {}
    def wait_for(predicate, label, seconds=45):
        deadline = time.monotonic() + seconds
        while not predicate():
            if time.monotonic() >= deadline: raise RuntimeError(label)
            time.sleep(.1)
    def run_phase(name):
        output = artifacts / name; output.mkdir()
        phaseenv = dict(childenv, MARU_REMOTE_RESTART_PHASE=name, MARU_REMOTE_RESTART_OUTPUT=str(output))
        child = GUIApp(app, phaseenv, output); children.append(child)
        wait_for(lambda: (output / 'ready').exists() and (output / 'frame.ppm').exists(), name + ' GUI/SSH did not become ready')
        # Every initial and offline event must traverse the actual reader before judging replay.
        expected = 2 if name == 'seed' else 10
        wait_for(lambda: (output / 'app.stderr.txt').read_text(errors='replace').count(
            'REMOTE_RESTART_APPLIED replay=' + ('true' if name == 'restore' else '')) == expected, name + ' missing replay events')
        text = (output / 'app.stderr.txt').read_text(errors='replace')
        rows = re.findall(r'REMOTE_RESTART state=(\w+) notice=(\w+) matched=(\d+) nonce=(\S+) surface=(\d+)', text)
        if 'REMOTE_RESTART_DELIVER' in text: raise RuntimeError('old notice reached delivery queue')
        if not rows or rows[-1][0:2] != ('idle', 'none'): raise RuntimeError(name + ' bad state: ' + repr(rows[-2:]))
        return child, output, rows[-1]
    def discover_hosts():
        bundles = [child.executable.parents[2] for child in children]
        for row in subprocess.check_output(['ps', '-axo', 'pid,command'], text=True).splitlines()[1:]:
            fields = row.strip().split(None, 1)
            if len(fields) != 2 or f' __session-host {host_root}/session-host ' not in fields[1]: continue
            pid = int(fields[0]); identity = process_identity(pid)
            if identity and identity[0] == os.getuid() and any(Path(identity[2]).is_relative_to(b) for b in bundles):
                owned_hosts[pid] = identity
    def quit_phase(child, output):
        (output / 'quit').touch()
        if child.wait(timeout=20) != 0: raise RuntimeError('owned GUI quit failed')
        child.close()
    try:
        seed, seed_output, first = run_phase('seed')
        discover_hosts()
        if not owned_hosts: raise RuntimeError('owned persistent host not identified')
        owner = json.loads((remote / 'gui-owner.json').read_text())
        if owner['nonce'] != first[3] or owner['format'] != '2':
            raise RuntimeError('remote process and GUI identity/profile disagree')
        quit_phase(seed, seed_output)
        if not all(process_identity(pid) == identity for pid, identity in owned_hosts.items()):
            raise RuntimeError('persistent host did not survive app quit')
        inventory = subprocess.run([cli, 'runtime', 'list', '--json'], env=childenv, capture_output=True, timeout=15)
        (artifacts / 'runtime-after-quit.json').write_bytes(inventory.stdout)
        (artifacts / 'runtime-after-quit.stderr').write_bytes(inventory.stderr)
        runtimes = json.loads(inventory.stdout).get('runtimes', []) if not inventory.returncode else []
        if len(runtimes) != 1 or runtimes[0]['runtime_id'] != first[3].rsplit('_', 1)[-1] or runtimes[0]['has_controller']:
            raise RuntimeError('expected exact detached runtime after normal Quit')
        emit_hooks(remote, 'gui-offline', owner['nonce'])
        restored, restore_output, second = run_phase('restore')
        owner_token = first[3].rsplit('_', 1)[-1]
        if len(owner_token) != 32 or first[3] != second[3]:
            raise RuntimeError('restored runtime owner changed')
        if json.loads((remote / 'gui-owner.json').read_text()) != owner:
            raise RuntimeError('restore restarted SSH rather than reattaching persistent PTY')
        emit_hooks(remote, marker, owner['nonce'], message=marker)
        wait_for(lambda: 'REMOTE_RESTART_DELIVER kind=done' in
            (restore_output / 'app.stderr.txt').read_text(errors='replace'), 'new live completion was not delivered')
        wait_for(lambda: (restore_output / 'app.stderr.txt').read_text(errors='replace').count('REMOTE_RESTART_APPLIED replay=false') == 8, 'new live events were lost')
        quit_phase(restored, restore_output)
        (artifacts / 'result.json').write_text(json.dumps(dict(seed_pid=seed.pid, restore_pid=restored.pid,
            restored_runtime=True, runtime_nonce=first[3], replay_events=10, live_events=8,
            past_notice=False, live_notice=True, actual_windows=True, os_banner_verified=False), indent=2) + '\n')
    finally:
        discover_hosts() # Readiness failures must also settle their owned persistent host.
        # Keep bounded diagnostics after the private carrier removes its temporary root.
        for path in [root / 'trace.jsonl', root / 'sshd.log', remote / 'gui-owner.json', home / 'Library/Application Support/maru/workspace.v1']:
            if path.exists(): (artifacts / path.name).write_bytes(path.read_bytes()[-131072:])
        (remote / 'gui-release').touch(); (remote / 'gui-hold').unlink(missing_ok=True)
        for child in children:
            if child.poll() is None: child.kill()
            child.close()
        for pid, identity in owned_hosts.items():
            if process_identity(pid) == identity:
                os.kill(pid, signal.SIGTERM)
                deadline = time.monotonic() + 5
                while process_identity(pid) == identity and time.monotonic() < deadline: time.sleep(.05)
                if process_identity(pid) == identity:
                    os.kill(pid, signal.SIGKILL)
                    wait_for(lambda: process_identity(pid) != identity, 'owned host cleanup timed out', 5)
