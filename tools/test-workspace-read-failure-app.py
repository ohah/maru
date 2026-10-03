# -*- coding: utf-8 -*-
"""Opt-in actual-app read-failure preservation smoke, with an isolated test home."""
from pathlib import Path
import os, subprocess, tempfile, signal
ROOT=Path(__file__).resolve().parents[1]
work=Path(tempfile.mkdtemp(prefix='maru-read-failure-app-'))
parent=work/'Library/Application Support/maru';parent.mkdir(parents=True,mode=0o700)
config=work/'.config/maru/config';config.parent.mkdir(parents=True);config.write_text('session.keep-alive-after-quit = false\n')
checkpoint=parent/'workspace.v1'
original=(ROOT/'tests/fixtures/session-host/ended-runtime-workspace.v1').read_bytes()
checkpoint.write_bytes(original);checkpoint.chmod(0o600)
backup=parent/'workspace.v1.bak';backup.write_bytes(original);backup.chmod(0o600)
inode=checkpoint.stat().st_ino;checkpoint.chmod(0)
env=dict(os.environ)
for name in ['MARU_MACOS_APP_SMOKE_MS','MARU_NO_WORKSPACE_RESTORE','MARU_SESSION_HOST_R7_CHECKPOINT_SMOKE','MARU_SESSION_HOST_R2A_CHECKPOINT_SMOKE']:
 env.pop(name,None)
env.update({'HOME':str(work),'CFFIXED_USER_HOME':str(work),'MARU_CONFIG':str(config),'MARU_SESSION_HOST_ROOT':str(work/'host'),'MARU_WEB_APP_ROOT':str(ROOT/'web/dist'),'MARU_SESSION_HOST_C4_QUIT_CANCEL_SMOKE':'maru-test-only-v1'})
log=work/'app.stderr'
app=None
try:
 with log.open('wb') as output:
  app=subprocess.Popen([str(ROOT/'zig-out/Maru.app/Contents/MacOS/maru-macos-app')],cwd=ROOT,env=env,stdout=output,stderr=output,start_new_session=True)
  result=app.wait(timeout=30)
 assert result==0,log.read_text()
 text=log.read_text()
 assert 'final-quit save skipped' in text and 'restore was incomplete' in text,text
 assert checkpoint.stat().st_ino==inode
 assert checkpoint.stat().st_mode & 0o777==0
 checkpoint.chmod(0o600)
 assert checkpoint.read_bytes()==original and backup.read_bytes()==original
 assert not (parent/'.workspace.v1.tmp').exists()
 print('actual_app_read_failure_preserved=true inode_preserved=true backup_preserved=true')
 print('artifacts='+str(work))
finally:
 checkpoint.chmod(0o600)
 if app is not None and app.poll() is None:
  os.killpg(app.pid,signal.SIGKILL);app.wait(timeout=10)
