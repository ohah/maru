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

def main():
    ap=argparse.ArgumentParser();ap.add_argument('--cli',required=True);ap.add_argument('--old-cli');ap.add_argument('--providers',action='store_true');ap.add_argument('--frames-output');args=ap.parse_args()
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
''')
            force=root/'force.sh';force.write_text("#!/bin/sh\nexec "+shlex.join([sys.executable,str(worker),str(remote),source_home,*provider_paths,os.environ.get("PATH","/usr/bin:/bin")])+"\n");force.chmod(0o700)
            proxy=bindir/'ssh';trace=root/'trace.jsonl'
            proxy.write_text(f'''#!{sys.executable}\nimport json,os,sys\na=sys.argv[1:];control=next((v.split("=",1)[1] for v in a if v.startswith("ControlPath=")),None)\nwith open({str(trace)!r},"a") as out:out.write(json.dumps({{"control":control,"format":os.environ.get("LC_MARU_LOG_FORMAT"),"prepare":any("agent-hooks" in v for v in a)}})+"\\n")\nos.execv("/usr/bin/ssh",["ssh"]+a)\n''');proxy.chmod(0o700)
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
                if peer==cli:
                    command=f'"{peer}" agent-events --stdio --dir="{remote}/.cache/maru" --log-format=mixed --heartbeat-ms=200'
                    proc=subprocess.Popen(['/usr/bin/ssh','-F',str(sshconfig),alias,command],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
                    q=queue.Queue();reader=threading.Thread(target=lambda:[q.put(l) for l in iter(proc.stdout.readline,b'')],daemon=True);reader.start();frames=[];raw_frames=[];deadline=time.monotonic()+1
                    try:
                        while time.monotonic()<deadline:
                            try:
                                line=q.get(timeout=max(.01,deadline-time.monotonic()));raw_frames.append(line);frames.append(json.loads(line))
                            except queue.Empty:break
                    finally:proc.terminate();proc.wait(timeout=3);proc.stdout.close();proc.stderr.close();reader.join(timeout=1)
                    assert frames[0]=={'hello':'maru-agent-events-mixed','v':3},frames[:1]
                    if args.frames_output and tag=='allowed':
                        target=Path(args.frames_output);target.write_bytes(b''.join(raw_frames));target.chmod(0o600)
                    profiles={f['format'] for f in frames[1:] if 'line' in f.get('frame',{}) and 'UserPromptSubmit' in f['frame']['line']}
                    assert profiles==({1,2} if tag=='allowed' else {1}),profiles
                    print(json.dumps({'case':tag,'actual_ssh_mixed_profiles':sorted(profiles)}),flush=True)
            finally:
                if trace.exists():controls.update(e['control'] for e in map(json.loads,trace.read_text().splitlines()) if e['control'])
                for control in controls:subprocess.run(['/usr/bin/ssh','-F',str(sshconfig),'-S',control,'-O','exit',alias],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=3)
                server.terminate();server.wait(timeout=3);serverlog.close()
if __name__=='__main__':main()
