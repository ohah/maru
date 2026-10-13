#!/usr/bin/env python3
"""Owned loopback SSH: old/new process formats, real installed hooks and mixed wire.
No user SSH/provider settings or credentials are modified. Provider payloads are synthetic.
"""
import argparse,json,os,queue,re,shlex,shutil,socket,subprocess,sys,tempfile,threading,time
from pathlib import Path

def run(argv, **kw):
    result=subprocess.run(argv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=15,**kw)
    if result.returncode: raise AssertionError((argv[0],result.returncode,result.stderr.decode(errors='replace')[-1000:]))
    return result

def emit_offline_hooks(remote, identity="offline", nonce="4331_7"):
    settings = json.loads((remote / '.claude/settings.json').read_text())
    for profile in [1, 2]:
        env = dict(os.environ, HOME=str(remote), XDG_CACHE_HOME=str(remote / '.cache'),
                   LC_MARU_PANE=nonce, LC_MARU_LOG_FORMAT=str(profile))
        for key in ['CLAUDE_CONFIG_DIR', 'CODEX_HOME', 'MARU_HOOK_INSTANCE', 'MARU_HOOK_PANE', 'TMUX', 'TMUX_PANE']:
            env.pop(key, None)
        for event in ['UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop']:
            command = settings['hooks'][event][0]['hooks'][0]['command']
            payload = {'hook_event_name': event, 'session_id': f'{identity}-{profile}',
                       'cwd': str(remote), 'prompt': 'synthetic offline turn',
                       'transcript_path': str(remote / f'{identity}-{profile}.jsonl'),
                       'tool_name': 'Bash', 'tool_use_id': f'{identity}-tool-{profile}',
                       'tool_input': {'command': 'pwd'}}
            run(['/bin/sh', '-c', command], input=json.dumps(payload).encode(), env=env)

def reconnect_probe(peer, remote, sshconfig, alias, controls, frames):
    """Drop the owned master, write offline hooks, resume through a fresh SSH transport."""
    cursors = {}
    for row in frames[1:]:
        frame = row.get('frame', {})
        if 'cur' in frame:
            cursors[row['format'], frame['cur']] = frame
    assert (1, '4331_7') in cursors and (2, '4331_7') in cursors
    for control in controls:
        run(['/usr/bin/ssh', '-F', str(sshconfig), '-S', control, '-O', 'exit', alias])
    emit_offline_hooks(remote)
    resumes = []
    for (profile, name), frame in cursors.items():
        entry = f"{profile}:{name}:{frame['at']}"
        if profile == 2:
            entry += ':' + frame['gen']
        resumes.append(entry)
    command = shlex.join([peer, 'agent-events', '--stdio', f'--dir={remote}/.cache/maru',
                          '--log-format=mixed', '--heartbeat-ms=200', '--resume=' + ','.join(resumes)])
    proc = subprocess.Popen(['/usr/bin/ssh', '-F', str(sshconfig), alias, command],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    q = queue.Queue()
    reader = threading.Thread(target=lambda: [q.put(line) for line in iter(proc.stdout.readline, b'')], daemon=True)
    reader.start()
    received = []; raw = []; deadline = time.monotonic() + 2
    try:
        while time.monotonic() < deadline:
            try:
                line = q.get(timeout=max(.01, deadline - time.monotonic()))
                raw.append(line); received.append(json.loads(line))
            except queue.Empty:
                break
    finally:
        proc.terminate(); proc.wait(timeout=3); proc.stdout.close(); proc.stderr.close(); reader.join(timeout=1)
    assert received and received[0] == {'hello': 'maru-agent-events-mixed', 'v': 3}
    events = []
    for row in received[1:]:
        frame = row.get('frame', {})
        if frame.get('nonce') == '4331_7' and 'line' in frame:
            payload = json.loads(frame['line'].split('\t', 1)[1])
            events.append((row['format'], payload['session_id'], payload['hook_event_name']))
    expected = [(profile, f'offline-{profile}', event)
                for profile in [1, 2] for event in ['UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop']]
    assert sorted(events) == sorted(expected), events
    print(json.dumps({'case': 'reconnect', 'offline_events': len(events), 'old_events_replayed': 0}), flush=True)
    return b''.join(raw)

def automatic_wrapper_probe(cli, root, remote, sshconfig, alias, env, trace):
    """The product shell wrapper, not this harness, opens the second connection."""
    settings = Path(env['MARU_CONFIG'])
    settings.write_text('sidebar.agent-hooks = true\nssh.reconnect = true\n')
    hold = remote / 'automatic-hold'; hold.touch()
    childenv = dict(env, MARU_AGENT_REMOTE_PROTOCOL='3')
    before = len(trace.read_text().splitlines())
    proc = subprocess.Popen([cli, 'ssh', '-F', str(sshconfig), '-T', alias], env=childenv,
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    q = queue.Queue(); output = []
    reader = threading.Thread(target=lambda: [q.put(line) for line in iter(proc.stdout.readline, b'')], daemon=True)
    reader.start()
    try:
        for phase in [1, 2]:
            deadline = time.monotonic() + 15
            while True:
                line = q.get(timeout=max(.01, deadline - time.monotonic())); output.append(line)
                if b'held:' + str(phase).encode() in line: break
                assert time.monotonic() < deadline
            if phase == 1:
                entries = [json.loads(line) for line in trace.read_text().splitlines()[before:]]
                control = next(e['control'] for e in reversed(entries) if e['control'] and not e['prepare'])
                run(['/usr/bin/ssh', '-F', str(sshconfig), '-S', control, '-O', 'exit', alias])
                (remote / 'release-1').touch()
                # Current config changes cannot rewrite the running wrapper's pinned format.
                settings.write_text('sidebar.agent-hooks = false\nssh.reconnect = true\n')
            else:
                (remote / 'release-2').touch()
        proc.wait(timeout=5)
        reader.join(timeout=1)
        while not q.empty(): output.append(q.get())
        stderr = proc.stderr.read()
        assert proc.returncode == 0, stderr.decode(errors='replace')
        wire = b''.join(output)
        replies = [json.loads(v) for v in re.findall(rb'fixture:(\{[^\r\n]+\})', wire)]
        assert [v['received'] for v in replies] == ['2', '2'], replies
        entries = [json.loads(line) for line in trace.read_text().splitlines()[before:]]
        assert sum(e['prepare'] for e in entries) == 1, entries
        assert b'reconnecting in' in stderr
        assert wire.count(b'\x1b]5379;ssh;') == 2 and wire.count(b'\x1b]5379;ssh-end') == 2
        print(json.dumps({'case': 'automatic-wrapper', 'connections': 2, 'preparations': 1, 'formats': [2, 2]}), flush=True)
    finally:
        (remote / 'release-1').touch(); (remote / 'release-2').touch(); hold.unlink(missing_ok=True)
        if proc.poll() is None: proc.kill(); proc.wait(timeout=3)
        proc.stdout.close(); proc.stderr.close(); reader.join(timeout=1)
        settings.write_text('sidebar.agent-hooks = true\nssh.reconnect = false\n')

def automatic_gui_probe(test_binary, root, remote, sshconfig, alias, env, trace):
    """Let the product scheduler own replacement SSH spawn; the carrier only drops transport."""
    entries = [json.loads(line) for line in trace.read_text().splitlines()]
    control = next(e['control'] for e in reversed(entries) if e['control'])
    run(['/usr/bin/ssh', '-F', str(sshconfig), '-S', control, '-M', '-N', '-f',
         '-o', 'ControlPersist=no', alias])
    (root / 'gui-dest').write_text(alias); (root / 'gui-control').write_text(control)
    childenv = dict(env, MARU_REMOTE_AUTO_ROOT=str(root),
                    MARU_TEST_KEEP_ONLY_PREFIX='app_session.test.remote automatic reconnect')
    log = (root / 'gui-test.log').open('wb')
    proc = subprocess.Popen([test_binary, '--maru-expect-tests=6', '--maru-expect-passed=1'],
                            env=childenv, stdout=log, stderr=log)
    try:
        deadline = time.monotonic() + 10
        while not (root / 'gui-ready').exists():
            assert proc.poll() is None, (root / 'gui-test.log').read_text()[-3000:]
            assert time.monotonic() < deadline, 'GUI initial stream timeout'
            time.sleep(.02)
        run(['/usr/bin/ssh', '-F', str(sshconfig), '-S', control, '-O', 'exit', alias])
        emit_offline_hooks(remote, 'gui-offline', (root / 'gui-ready').read_text())
        proc.wait(timeout=25)
        if proc.returncode != 0:
            failure = Path('/tmp/remote-native-auto-gui-failure.log'); failure.write_bytes((root / 'gui-test.log').read_bytes()); failure.chmod(0o600)
            raise AssertionError(failure.read_text()[:3500])
        print(json.dumps({'case': 'automatic-gui', 'retry_spawn': 'product', 'badge': 'idle', 'capture': 'sealed'}), flush=True)
    finally:
        if proc.poll() is None: proc.kill(); proc.wait(timeout=3)
        log.close()
        subprocess.run(['/usr/bin/ssh', '-F', str(sshconfig), '-S', control, '-O', 'exit', alias],
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=3)

def terminal_cancel_probe(cli, root, remote, sshconfig, alias, env, trace):
    """Actual Terminal.app tty and guarded GUI Ctrl+C, never kill a user terminal."""
    settings = Path(env['MARU_CONFIG'])
    settings.write_text('sidebar.agent-hooks = true\nssh.reconnect = true\n')
    hold = remote / 'automatic-hold'; hold.touch()
    for name in ['automatic-count', 'release-1', 'release-2']:
        (remote / name).unlink(missing_ok=True)
    log = root / 'terminal.log'; result = root / 'terminal.exit'
    runner = root / 'cancel.command'
    childenv = dict(env, MARU_AGENT_REMOTE_PROTOCOL='3')
    command = shlex.join(['/usr/bin/env', '-i'] + [k + '=' + v for k, v in childenv.items()] +
                         [cli, 'ssh', '-F', str(sshconfig), '-T', alias])
    runner.write_text('#!/bin/sh\ntrap ":" INT\n' + command + ' >' + shlex.quote(str(log)) +
                      ' 2>&1\nrc=$?\nprintf "%s" "$rc" >' + shlex.quote(str(result)) + '\nexit "$rc"\n')
    runner.chmod(0o700)
    before = len(trace.read_text().splitlines())
    def wait_for(predicate, label, seconds=15):
        deadline = time.monotonic() + seconds
        while not predicate():
            if time.monotonic() >= deadline:
                raise AssertionError(label + ': ' + (log.read_text(errors='replace')[-2000:] if log.exists() else 'no log'))
            time.sleep(.02)
    def wire():
        return log.read_bytes() if log.exists() else b''
    opened = False
    try:
        run(['/usr/bin/swift', '-e', 'import CoreGraphics; let s = CGSessionCopyCurrentDictionary() as? [String: Any]; if s == nil || s?["CGSSessionScreenIsLocked"] as? Int == 1 { exit(1) }'])
        run(['/usr/bin/open', '-a', 'Terminal', str(runner)]); opened = True
        wait_for(lambda: b'held:1' in wire(), 'GUI initial SSH')
        entries = [json.loads(line) for line in trace.read_text().splitlines()[before:]]
        control = next(e['control'] for e in reversed(entries) if e['control'] and not e['prepare'])
        run(['/usr/bin/ssh', '-F', str(sshconfig), '-S', control, '-O', 'exit', alias])
        (remote / 'release-1').touch()
        wait_for(lambda: b'reconnecting in' in wire(), 'GUI retry wait')
        # AX window ownership plus foreground guard prevents input reaching another tab.
        script = '\n'.join(['tell application "System Events"', 'tell process "Terminal"',
            'if frontmost is false then error "Test terminal lost focus"',
            'if name of front window does not contain ' + json.dumps(str(runner).replace('/private/tmp/', '/tmp/')) +
                ' then error "Owned test window missing"',
            'keystroke "c" using control down', 'end tell', 'end tell'])
        run(['/usr/bin/osascript', '-e', script])
        wait_for(result.exists, 'GUI Ctrl+C exit', 5)
        assert result.read_text() == '130', (result.read_text(), wire())
        time.sleep(1.1)
        entries = [json.loads(line) for line in trace.read_text().splitlines()[before:]]
        assert sum(not e['prepare'] for e in entries) == 1, entries
        assert wire().count(b'\x1b]5379;ssh;') == 1 and wire().count(b'\x1b]5379;ssh-end') == 1, wire()
        print(json.dumps({'case': 'terminal-ctrl-c', 'exit': 130, 'connections': 1,
                          'input': 'GUI Control+C', 'retry_after_cancel': False}), flush=True)
    finally:
        (remote / 'release-1').touch(); hold.unlink(missing_ok=True)
        settings.write_text('sidebar.agent-hooks = true\nssh.reconnect = false\n')
        # Close only a completed owned window. On failure preserve it for inspection.
        if opened and result.exists():
            script = '\n'.join(['tell application "System Events"', 'tell process "Terminal"',
                'if frontmost and name of front window contains ' + json.dumps(str(runner).replace('/private/tmp/', '/tmp/')) + ' then',
                'keystroke "w" using command down', 'end if', 'end tell', 'end tell'])
            run(['/usr/bin/osascript', '-e', script])

def replay_boundary_probe(peer, remote, sshconfig, alias):
    """Independent event IDs distinguish startup records from appends across chunks."""
    for index in range(100):
        emit_offline_hooks(remote, f'boundary-old-{index}')
    command = shlex.join([peer, 'agent-events', '--stdio', f'--dir={remote}/.cache/maru',
                          '--log-format=mixed', '--replay-boundary', '--heartbeat-ms=200'])
    first = subprocess.Popen(['/usr/bin/ssh', '-F', str(sshconfig), alias, command],
                             stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    initial = queue.Queue()
    initial_reader = threading.Thread(target=lambda: [initial.put(line) for line in iter(first.stdout.readline, b'')], daemon=True)
    initial_reader.start()
    positions = {}; deadline = time.monotonic() + 10
    try:
        while len(positions) < 2:
            row = json.loads(initial.get(timeout=max(.01, deadline - time.monotonic())))
            frame = row.get('frame', {})
            if frame.get('cur') == '4331_7': positions[row['format']] = frame
            assert time.monotonic() < deadline
    finally:
        first.terminate(); first.wait(timeout=3)
        first.stdout.close(); first.stderr.close(); initial_reader.join(timeout=1)
    resumes = []; replay_states = []
    for profile, frame in sorted(positions.items()):
        assert frame['at'] == 0, frame
        resume = f"{profile}:4331_7:0"
        state = f"{profile}:4331_7:{frame['replay_at']}"
        if profile == 2:
            resume += ':' + frame['gen']; state += ':' + frame['replay_gen']
        resumes.append(resume); replay_states.append(state + ':' + str(frame['replay_inode']))
    command += ' ' + shlex.join(['--resume=' + ','.join(resumes), '--replay-state=' + ','.join(replay_states)])
    proc = subprocess.Popen(['/usr/bin/ssh', '-F', str(sshconfig), alias, command],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    q = queue.Queue()
    reader = threading.Thread(target=lambda: [q.put(line) for line in iter(proc.stdout.readline, b'')], daemon=True)
    reader.start()
    seen = []; raw = []; live_written = False; deadline = time.monotonic() + 15
    try:
        while time.monotonic() < deadline:
            line = q.get(timeout=max(.01, deadline - time.monotonic()))
            raw.append(line)
            row = json.loads(line)
            if not live_written and row.get('hello'):
                # The startup snapshot must precede hello: appending now cannot join it.
                emit_offline_hooks(remote, 'boundary-live')
                live_written = True
            frame = row.get('frame', {})
            if 'line' not in frame: continue
            event = json.loads(frame['line'].split('\t', 1)[1])
            sid = event.get('session_id', '')
            if not sid.startswith('boundary-'): continue
            seen.append((row['format'], sid, event['hook_event_name'], row.get('replay')))
            if sum(sid.startswith('boundary-live') for _, sid, _, _ in seen) == 8 and len(seen) == 808: break
        expected = {(profile, f'boundary-old-{index}-{profile}', event, True)
                    for index in range(100) for profile in [1, 2]
                    for event in ['UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop']}
        expected.update((profile, f'boundary-live-{profile}', event, False)
                        for profile in [1, 2] for event in ['UserPromptSubmit', 'PreToolUse', 'PostToolUse', 'Stop'])
        assert len(seen) == 808 and set(seen) == expected, (len(seen), list(set(seen) ^ expected)[:10])
        print(json.dumps({'case': 'startup-boundary', 'old': 800, 'live': 8, 'duplicates': 0}), flush=True)
        return b''.join(raw)
    finally:
        proc.terminate(); proc.wait(timeout=3)
        proc.stdout.close(); proc.stderr.close(); reader.join(timeout=1)

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--cli',required=True);ap.add_argument('--old-cli');ap.add_argument('--providers',action='store_true');ap.add_argument('--frames-output');ap.add_argument('--automatic',action='store_true');ap.add_argument('--gui-test');ap.add_argument('--restart-test');ap.add_argument('--terminal-cancel',action='store_true');args=ap.parse_args()
    cli=str(Path(args.cli).resolve());old=str(Path(args.old_cli).resolve()) if args.old_cli else None
    provider_paths=[shutil.which(name) or '' for name in ['claude','codex']] if args.providers else ['', '']
    if args.providers:assert all(provider_paths),'installed Claude/Codex required'
    source_home=str(Path.home())
    cases=[('allowed',True,cli),('denied',False,cli),('disabled',True,cli)]
    if old:cases.append(('old-peer',True,old))
    for tag,allow,peer in cases:
        with tempfile.TemporaryDirectory(prefix='remote-native-ssh-',dir='/tmp') as raw:
            root=Path(raw).resolve();os.chmod(root,0o700)
            remote=root/'remote';local=root/'local';bindir=root/'bin'
            for path in [remote,local,bindir]:path.mkdir(mode=0o700)
            (remote/'.local/bin').mkdir(parents=True,mode=0o700);(remote/'.local/bin/maru').symlink_to(peer)
            worker=root/'worker.py'
            worker.write_text(r'''import json,os,subprocess,sys
from pathlib import Path
root=Path(sys.argv[1]);env=dict(os.environ,HOME=str(root),XDG_CACHE_HOME=str(root/".cache"))
for key in ["CLAUDE_CONFIG_DIR","CODEX_HOME","MARU_HOOK_INSTANCE","MARU_HOOK_PANE","TMUX","TMUX_PANE"]:env.pop(key,None)
command=env.get("SSH_ORIGINAL_COMMAND","")
if command:sys.exit(subprocess.call(["/bin/sh","-c",command],env=env))
settings=json.loads((root/".claude/settings.json").read_text())
for event in ["UserPromptSubmit","Stop"]:
 command=settings["hooks"][event][0]["hooks"][0]["command"]
 payload={"hook_event_name":event,"session_id":"native-case" if env.get("LC_MARU_LOG_FORMAT")=="2" else "legacy-case","cwd":str(root),"prompt":"synthetic migration fixture","transcript_path":None}
 result=subprocess.run(["/bin/sh","-c",command],input=json.dumps(payload).encode(),env=env,timeout=3)
 assert result.returncode==0
if len(sys.argv)>4 and sys.argv[3] and env.get("LC_MARU_LOG_FORMAT")=="2":
 import shutil
 source=Path(sys.argv[2]);project=root/"project";project.mkdir(exist_ok=True)
 prompt="Execute exactly pwd once, do not read or modify files, then answer OK."
 auth=source/".codex/auth.json"
 if auth.is_file():shutil.copyfile(auth,root/".codex/auth.json");(root/".codex/auth.json").chmod(0o600)
 commands=[("claude",[sys.argv[3],"--print","--setting-sources","","--settings",str(root/".claude/settings.json"),"--no-session-persistence","--allowedTools","Bash(pwd)","--model","haiku","--max-budget-usd","0.20",prompt]),("codex",[sys.argv[4],"exec","--skip-git-repo-check","--ephemeral","--sandbox","read-only","-c","features.hooks=true","-c",'model_reasoning_effort="low"',prompt])]
 for provider,argv in commands:
  penv=dict(env,HOME=str(source)) if provider=="claude" else dict(env,CODEX_HOME=str(root/".codex"))
  penv["PATH"]=sys.argv[5]
  result=subprocess.run(argv,cwd=project,env=penv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=60)
  if result.returncode:
   Path("/tmp/remote-native-provider-failure.log").write_bytes(result.stderr);Path("/tmp/remote-native-provider-failure.log").chmod(0o600)
   raise RuntimeError("installed provider failed: "+provider)
  version=subprocess.run([argv[0],"--version"],env=penv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=5).stdout.decode().strip()
  print("provider:"+json.dumps({"name":provider,"version":version,"completed":True}),flush=True)
print("fixture:"+json.dumps({"received":env.get("LC_MARU_LOG_FORMAT"),"hooks":2}),flush=True)
if (root/"automatic-hold").exists():
 import time
 counter=root/"automatic-count"
 phase=int(counter.read_text())+1 if counter.exists() else 1
 counter.write_text(str(phase))
 print("held:"+str(phase),flush=True)
 deadline=time.monotonic()+20
 while not (root/("release-"+str(phase))).exists():
  assert time.monotonic()<deadline,"owned hold timeout"
  time.sleep(.02)

''')
            force=root/'force.sh';force.write_text("#!/bin/sh\nexec "+shlex.join([sys.executable,str(worker),str(remote),source_home,*provider_paths,os.environ.get("PATH","/usr/bin:/bin")])+"\n");force.chmod(0o700)
            proxy=bindir/'ssh';trace=root/'trace.jsonl'
            proxy.write_text(f'''#!{sys.executable}\nimport json,os,sys\na=sys.argv[1:];control=next((v.split("=",1)[1] for v in a if v.startswith("ControlPath=")),None)\nwith open({str(trace)!r},"a") as out:out.write(json.dumps({{"control":control,"format":os.environ.get("LC_MARU_LOG_FORMAT"),"prepare":any("agent-hooks" in v for v in a)}})+"\\n")\nos.execv("/usr/bin/ssh",["ssh","-F",{str(root / "ssh_config")!r}]+a)\n''');proxy.chmod(0o700)
            for name in ['hostkey','userkey']:run(['/usr/bin/ssh-keygen','-q','-t','ed25519','-N','','-f',str(root/name)])
            (root/'authorized_keys').write_bytes((root/'userkey.pub').read_bytes());(root/'authorized_keys').chmod(0o600)
            with socket.socket() as sock:sock.bind(('127.0.0.1',0));port=sock.getsockname()[1]
            config=root/'sshd_config';config.write_text(f'''Port {port}\nListenAddress 127.0.0.1\nHostKey {root}/hostkey\nPidFile {root}/sshd.pid\nStrictModes no\nUsePAM no\nPubkeyAuthentication yes\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nAuthorizedKeysFile {root}/authorized_keys\nPermitRootLogin no\nPermitUserRC no\nPermitUserEnvironment no\nAcceptEnv LANG {'LC_*' if allow else 'LC_MARU_PANE'}\nAllowTcpForwarding no\nAllowAgentForwarding no\nX11Forwarding no\nForceCommand /bin/sh {force}\n''')
            alias='native-'+root.name.rsplit('-',1)[-1]+'-'+tag
            sshconfig=root/'ssh_config';sshconfig.write_text(f'Host {alias}\n HostName 127.0.0.1\n Port {port}\n IdentityFile {root}/userkey\n IdentitiesOnly yes\n BatchMode yes\n StrictHostKeyChecking no\n UserKnownHostsFile /dev/null\n ControlPersist 15\n')
            env=dict(os.environ,HOME=str(local),PATH=str(bindir)+':/usr/bin:/bin',XDG_CACHE_HOME=str(local/'.cache'),MARU_HOOK_INSTANCE='4331',MARU_HOOK_PANE='7',LC_MARU_LOG_FORMAT='2')
            for key in ['CLAUDE_CONFIG_DIR','CODEX_HOME']:env.pop(key,None)
            settings=root/'config';settings.write_text('sidebar.agent-hooks = '+('false' if tag=='disabled' else 'true')+'\nssh.reconnect = false\n');env['MARU_CONFIG']=str(settings)
            cache=local/'.cache/maru';cache.mkdir(parents=True,mode=0o700);(cache/'ssh-terminfo-hosts').write_text(alias+'\n')
            seed=dict(env,HOME=str(remote),LC_MARU_LOG_FORMAT='1');seed.pop('MARU_HOOK_INSTANCE',None);seed.pop('MARU_HOOK_PANE',None)
            for provider in ['claude','codex']:run([peer,'agent-hooks','install',f'--provider={provider}','--scope=remote',f'--dir={remote}/.cache/maru/remote-agent-events'],env=seed)
            serverlog=(root/'sshd.log').open('wb');server=subprocess.Popen(['/usr/sbin/sshd','-D','-e','-f',str(config)],stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=serverlog)
            controls=set()
            try:
                deadline=time.monotonic()+3
                while True:
                    try:
                        with socket.create_connection(('127.0.0.1',port),timeout=.1):break
                    except OSError:
                        assert server.poll() is None,'sshd exited'
                        if time.monotonic()>deadline:raise TimeoutError('sshd readiness')
                        time.sleep(.02)
                for capability in ['0','3']:
                    childenv=dict(env,MARU_AGENT_REMOTE_PROTOCOL=capability)
                    outcome=subprocess.run([cli,'ssh','-F',str(sshconfig),'-T',alias],env=childenv,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=150 if args.providers else 15)
                    assert outcome.returncode==0,('SSH fixture failed',tag,capability)
                    for row in re.findall(r'provider:(\{[^\r\n]+\})',outcome.stdout.decode()):print('provider:'+row,flush=True)
                    output=outcome.stdout.decode()
                    reply=json.loads(re.search(r'fixture:(\{[^\r\n]+\})',output).group(1))
                    expected='2' if capability=='3' and allow and tag not in ['disabled','old-peer'] else ('1' if allow else None)
                    assert reply['received']==expected,(tag,capability,reply)
                    print(json.dumps({'case':tag,'gui_capability':capability,'chosen_format':2 if expected=='2' else 1,'installed_hooks':reply['hooks']}),flush=True)
                entries=[json.loads(line) for line in trace.read_text().splitlines()]
                controls={entry['control'] for entry in entries if entry['control']}
                assert any(e['prepare'] for e in entries)==(tag!='disabled'),entries
                legacy=remote/'.cache/maru/remote-agent-events/4331_7.ndjson';native=remote/'.cache/maru/remote-agent-events-v2/4331_7.ndjson'
                assert legacy.exists() and b'UserPromptSubmit' in legacy.read_bytes()
                if tag=='allowed':assert native.read_bytes().startswith(b'MARU_AGENT_LOG_V2\t') and b'Stop' in native.read_bytes()
                else:assert not native.exists()
                if args.automatic and tag == 'allowed':
                    automatic_wrapper_probe(cli, root, remote, sshconfig, alias, env, trace)
                if args.terminal_cancel and tag == 'allowed':
                    terminal_cancel_probe(cli, root, remote, sshconfig, alias, env, trace)
                    run(['/usr/bin/ssh', '-F', str(sshconfig), '-S', next(iter(controls)),
                         '-M', '-N', '-f', '-o', 'ControlPersist=no', alias])
                if peer==cli:
                    command=f'"{peer}" agent-events --stdio --dir="{remote}/.cache/maru" --log-format=mixed --heartbeat-ms=200' + (' --replay-boundary' if args.restart_test and tag == 'allowed' else '')
                    proc=subprocess.Popen(['/usr/bin/ssh','-F',str(sshconfig),'-S',next(iter(controls)),alias,command],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                    q=queue.Queue();reader=threading.Thread(target=lambda:[q.put(l) for l in iter(proc.stdout.readline,b'')],daemon=True);reader.start();frames=[];raw_frames=[];deadline=time.monotonic()+1
                    try:
                        while time.monotonic()<deadline:
                            try:
                                line=q.get(timeout=max(.01,deadline-time.monotonic()));raw_frames.append(line);frames.append(json.loads(line))
                            except queue.Empty:break
                    finally:
                        if tag == 'allowed':
                            # Drop the transport while its stream is still alive, rather than gracefully stopping it.
                            assert proc.poll() is None
                            for control in controls:
                                run(['/usr/bin/ssh', '-F', str(sshconfig), '-S', control, '-O', 'exit', alias])
                            controls.clear()
                            try:
                                proc.wait(timeout=3)
                            except subprocess.TimeoutExpired:
                                proc.kill(); proc.wait(timeout=3)
                                raise AssertionError('owned master did not disconnect its stream')
                            assert proc.returncode != 0, 'transport loss must terminate the live SSH stream'
                        else:
                            proc.terminate(); proc.wait(timeout=3)
                        proc.stdout.close();proc.stderr.close();reader.join(timeout=1)
                    assert frames[0] == ({'hello': 'maru-agent-events-mixed-replay', 'v': 4} if args.restart_test and tag == 'allowed' else {'hello':'maru-agent-events-mixed','v':3}), frames[:1]
                    if args.frames_output and tag=='allowed':
                        target=Path(args.frames_output);target.write_bytes(b''.join(raw_frames));target.chmod(0o600)
                    profiles={f['format'] for f in frames[1:] if 'line' in f.get('frame',{}) and 'UserPromptSubmit' in f['frame']['line']}
                    assert profiles==({1,2} if tag=='allowed' else {1}),profiles
                    print(json.dumps({'case':tag,'actual_ssh_mixed_profiles':sorted(profiles)}),flush=True)
                    if tag == 'allowed' and args.restart_test:
                        events = [r for r in frames if 'line' in r.get('frame', {})]
                        assert events and all(r.get('replay') is True for r in events), events
                        frame_path = root / 'restart-wire.ndjson'
                        frame_path.write_bytes(b''.join(raw_frames))
                        childenv = dict(env, MARU_REMOTE_NATIVE_FRAMES=str(frame_path),
                                        MARU_TEST_KEEP_ONLY_PREFIX='app_session.test.remote restart replay')
                        run([str(Path(args.restart_test).resolve()), '--maru-expect-tests=6', '--maru-expect-passed=1'], env=childenv)
                        # Negative control: a peer that labels all old records live must fail
                        # the receiver oracle, rather than silently weakening its assertion.
                        frame_path.write_bytes(b''.join(raw_frames).replace(b'"replay":true', b'"replay":false'))
                        bad = subprocess.run([str(Path(args.restart_test).resolve()), '--maru-expect-tests=6', '--maru-expect-passed=1'], env=childenv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=15)
                        assert bad.returncode != 0 and b'expected .none, found .done' in bad.stderr, bad.stderr[-1000:]
                        frame_path.write_bytes(b''.join(raw_frames))
                        print(json.dumps({'case': 'fresh-app-replay', 'profiles': [1, 2], 'old_notice': False}), flush=True)
                    if tag == 'allowed':
                        resumed_wire = reconnect_probe(peer, remote, sshconfig, alias, controls, frames)
                        controls.clear()
                        if args.restart_test:
                            live_wire = replay_boundary_probe(peer, remote, sshconfig, alias)
                            frame_path.write_bytes(live_wire)
                            childenv['MARU_REMOTE_REPLAY_LIVE'] = '1'
                            run([str(Path(args.restart_test).resolve()), '--maru-expect-tests=6', '--maru-expect-passed=1'], env=childenv)
                            print(json.dumps({'case': 'fresh-app-live-after-replay', 'new_notice': True, 'sealed_capture': True}), flush=True)
                            records = [json.loads(line) for line in live_wire.splitlines()]
                            live_prompt = next(row for row in records if row.get('format') == 1 and row.get('replay') is False and 'line' in row.get('frame', {}) and json.loads(row['frame']['line'].split('\t', 1)[1]).get('hook_event_name') == 'UserPromptSubmit')
                            old_stop = next(row for row in records if row.get('format') == 2 and row.get('replay') is True and 'line' in row.get('frame', {}) and json.loads(row['frame']['line'].split('\t', 1)[1]).get('hook_event_name') == 'Stop')
                            old_prompt = next(row for row in records if row.get('format') == 2 and row.get('replay') is True and 'line' in row.get('frame', {}) and json.loads(row['frame']['line'].split('\t', 1)[1]).get('hook_event_name') == 'UserPromptSubmit')
                            frame_path.write_text('\n'.join(json.dumps(row, separators=(',', ':')) for row in [records[0], live_prompt, old_prompt, old_stop]) + '\n')
                            childenv['MARU_REMOTE_REPLAY_ORDER'] = '1'
                            run([str(Path(args.restart_test).resolve()), '--maru-expect-tests=6', '--maru-expect-passed=1'], env=childenv)
                            print(json.dumps({'case': 'live-before-other-profile-history', 'state': 'running'}), flush=True)
                        if args.frames_output:
                            Path(args.frames_output + '.reconnect').write_bytes(resumed_wire)
                            Path(args.frames_output + '.reconnect').chmod(0o600)
                        if args.gui_test:
                            automatic_gui_probe(str(Path(args.gui_test).resolve()), root, remote, sshconfig, alias, env, trace)

            finally:
                if trace.exists():controls.update(e['control'] for e in map(json.loads,trace.read_text().splitlines()) if e['control'])
                for control in controls:subprocess.run(['/usr/bin/ssh','-F',str(sshconfig),'-S',control,'-O','exit',alias],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=3)
                server.terminate();server.wait(timeout=3);serverlog.close()
if __name__=='__main__':main()
