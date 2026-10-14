#!/usr/bin/env python3
"""Actual owned GUI quit/restore; invoke inside the existing private SSH carrier."""
import hashlib, json, os, re, shlex, signal, subprocess, sys, time, uuid
from pathlib import Path

def verify_provider_gui(text, provider):
    """Require the same real session in live hooks, the product badge and the sealed store."""
    sessions = re.findall(r'PROVIDER_APPLIED provider=' + provider + r' event=stop session=(\S+) replay=false', text)
    # Startup fixtures can race the initial watermark; their identities are not provider proof.
    sessions = [sid for sid in sessions if sid not in {'native-case', 'legacy-case'}]
    if len(set(sessions)) != 1: raise RuntimeError(provider + ' requires one unambiguous live Stop session')
    if not any(re.search(r'PROVIDER_APPLIED provider=' + provider + r' event=\w+ session=' + re.escape(sid) + r' replay=false state=running', text) for sid in sessions):
        raise RuntimeError(provider + ' running badge was not observed')
    if not any(re.search(r'PROVIDER_BADGE provider=' + provider + r' state=running session=' + re.escape(sid), text) for sid in sessions):
        raise RuntimeError(provider + ' product badge was not observed running')
    if not any(re.search(r'PROVIDER_CAPTURE session=' + re.escape(sid) + r' capture=[1-9]\d* remote=true shell_calls=[1-9]', text) for sid in sessions):
        raise RuntimeError(provider + ' remote shell turn was not sealed')
    return set(sessions)

def verify_runtime_ended_gui(text, runtime_id):
    if not re.fullmatch(r'[0-9a-f]{32}', runtime_id): raise RuntimeError('invalid runtime identity')
    identity = re.search(r'^REMOTE_ENDED_DISCONNECTED host=([0-9a-f]{32}) runtime=' + re.escape(runtime_id) + r'$', text, re.M)
    if not identity: raise RuntimeError('missing runtime-ended target identity')
    host = identity.group(1)
    markers = ['^' + re.escape(identity.group(0)) + '$',
               r'^REMOTE_ENDED_JOB host=' + host + r' state=replacement_published$',
               r'^REMOTE_ENDED_JOB host=' + host + r' state=candidate_rejected$',
               r'^info: reconnect terminal: host=' + host + r' total=1 published_old=0 published_new=0 frozen=1 ended=0 retry_reserved=1$',
               r'^REMOTE_ENDED_GUI visible=true$']
    cursor = 0
    for marker in markers:
        match = re.search(marker, text[cursor:], re.M)
        if not match: raise RuntimeError('missing or unordered runtime-ended evidence: ' + marker)
        cursor += match.end()
    if any(marker in text for marker in ['fatal integrity:', 'coordinator turn failed:', 'REMOTE_ENDED_FAULT_ERROR']):
        raise RuntimeError('runtime-ended path reported a fatal or unhandled fault')

def probe(app, cli, root, remote, sshconfig, alias, env, emit_hooks, artifacts, providers=False, runtime_ended=False):
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
    if providers: childenv["MARU_REMOTE_PROVIDER_GUI"] = "1"
    if runtime_ended: childenv["MARU_REMOTE_ENDED_FAULT"] = "1"
    cache = home / '.cache/maru'; cache.mkdir(parents=True)
    (cache / 'ssh-terminfo-hosts').write_text(alias + '\n')
    (remote / 'gui-hold').touch()
    children = []; owned_hosts = {}; replay_expected = 10
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
        expected = 2 if name == 'seed' else replay_expected
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
        if runtime_ended:
            runtime_id = first[3].rsplit('_', 1)[-1]
            inventory = subprocess.run([cli, 'runtime', 'list', '--json'], env=childenv,
                                       capture_output=True, timeout=10, check=True)
            rows = json.loads(inventory.stdout)['runtimes']
            if len(rows) != 1 or rows[0]['runtime_id'] != runtime_id:
                raise RuntimeError('runtime-ended target does not match the sole GUI runtime')
            def wait_alive(predicate, label):
                def observed():
                    if seed.poll() is not None: raise RuntimeError(label + ': GUI exited ' + str(seed.poll()))
                    return predicate()
                wait_for(observed, label, 15)
            (seed_output / 'disconnect').touch()
            wait_alive(lambda: (seed_output / 'candidate-ready').exists(), 'observer scheduling barrier missing')
            ended = subprocess.run([cli, 'runtime', 'end', runtime_id, '--yes'], env=childenv,
                                   capture_output=True, timeout=10, check=True)
            (artifacts / 'runtime-end.stdout').write_bytes(ended.stdout)
            (artifacts / 'runtime-end.stderr').write_bytes(ended.stderr)
            (seed_output / 'continue').touch()
            wait_alive(lambda: 'reconnect terminal:' in (seed_output / 'app.stderr.txt').read_text(errors='replace'),
                       'canonical runtime-ended settlement missing')
            (seed_output / 'verify-after').touch()
            wait_alive(lambda: (seed_output / 'after-ready').exists(), 'post-failure GUI frame missing')
            text = (seed_output / 'app.stderr.txt').read_text(errors='replace')
            verify_runtime_ended_gui(text, runtime_id)
            time.sleep(2)
            if seed.poll() is not None: raise RuntimeError('GUI exited after runtime-ended settlement')
            quit_phase(seed, seed_output)
            (artifacts / 'result.json').write_text(json.dumps(dict(runtime_id=runtime_id,
                actual_windows=True, actual_terminate=True, observer_rejected=True,
                canonical_settlement=True, normal_quit=True, partial_frame_cause_verified=False), indent=2) + '\n')
            return
        if providers:
            (remote / 'provider-start').touch()
            wait_for(lambda: (remote / 'provider-done').exists(), 'real providers did not complete', 140)
            wait_for(lambda: all('PROVIDER_APPLIED provider=' + name + ' event=stop ' in
                (seed_output / 'app.stderr.txt').read_text(errors='replace') for name in ['claude', 'codex']),
                'provider exit preceded missing GUI Stop')
            provider_text = (seed_output / 'app.stderr.txt').read_text(errors='replace')
            provider_sessions = {}
            for provider in ['claude', 'codex']:
                record = json.loads((remote / ('provider-' + provider + '.json')).read_text())
                (artifacts / ('provider-' + provider + '.json')).write_text(json.dumps(record) + '\n')
                provider_sessions[provider] = verify_provider_gui(provider_text, provider)
            # Read the provider-written files through an independent CLI reader. Synthetic
            # startup IDs are excluded by matching each actual provider's GUI session IDs.
            reader = subprocess.Popen([cli, 'agent-events', '--stdio', '--dir=' + str(remote / '.cache/maru'),
                '--log-format=mixed', '--heartbeat-ms=200'], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            try:
                try: raw, err = reader.communicate(timeout=1)
                except subprocess.TimeoutExpired:
                    reader.terminate(); raw, err = reader.communicate(timeout=5)
            finally:
                if reader.poll() is None: reader.kill(); reader.wait(timeout=5)
            source_events = []
            for line in raw.splitlines():
                row = json.loads(line); frame = row.get('frame', {})
                if frame.get('nonce') != owner['nonce'] or 'line' not in frame: continue
                name, payload = frame['line'].split('\t', 1); event = json.loads(payload)
                if name not in ['claude', 'codex']: continue
                sid = event.get('session_id', '')
                if sid in provider_sessions[name]:
                    tool_input = event.get('tool_input') or {}
                    command = tool_input.get('command', tool_input.get('cmd', '')) if isinstance(tool_input, dict) else ''
                    source_events.append({'provider': name, 'session_id': sid, 'format': row['format'],
                        'event': event['hook_event_name'], 'command': command})
            for name in ['claude', 'codex']:
                events = {e['event'] for e in source_events if e['provider'] == name and e['format'] == 2}
                if not {'UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop'}.issubset(events):
                    raise RuntimeError(name + ' actual provider file oracle lacks expected hooks: ' + repr(events))
                commands = [e['command'] for e in source_events if e['provider'] == name and e['event'] == 'PreToolUse']
                if commands != ['pwd']: raise RuntimeError(name + ' did not execute exactly one read-only pwd tool')
            (artifacts / 'provider-hook-oracle.json').write_text(json.dumps(source_events, indent=2) + '\n')
            replay_expected = provider_text.count('REMOTE_RESTART_APPLIED replay=') + 8
            (artifacts / 'provider-gui.json').write_text(json.dumps({'actual_providers': ['claude', 'codex'], 'live_reader': True, 'remote_sealed_capture': True}) + '\n')
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
            restored_runtime=True, runtime_nonce=first[3], replay_events=replay_expected, live_events=8,
            past_notice=False, live_notice=True, actual_windows=True, os_banner_verified=False), indent=2) + '\n')
    finally:
        discover_hosts() # Readiness failures must also settle their owned persistent host.
        # Keep bounded diagnostics after the private carrier removes its temporary root.
        for path in list((host_root / 'session-host').glob('*.log')) + [root / 'trace.jsonl', root / 'sshd.log', remote / 'gui-owner.json', home / 'Library/Application Support/maru/workspace.v1']:
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
