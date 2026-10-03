# -*- coding: utf-8 -*-
"""Opt-in actual-app preservation checks for unreadable and malformed checkpoints.
Every scenario uses its own disposable home and session-host namespace.
"""
from pathlib import Path
import subprocess, os, tempfile, signal
root=Path(__file__).resolve().parents[1]
fixture=(root/'tests/fixtures/session-host/ended-runtime-workspace.v1').read_bytes()
results=[]
for case,payload in [('truncated',fixture[:len(fixture)//2]),('invalid_utf8',b'\xff\xfe\x00broken'),('wrong_header',b'maru-workspace-v999\n'),('directory',None),('unreadable',fixture)]:
 work=Path(tempfile.mkdtemp(prefix='maru-hostile-'+case+'-'))
 parent=work/'Library/Application Support/maru';parent.mkdir(parents=True)
 path=parent/'workspace.v1';backup=parent/'workspace.v1.bak';backup.write_bytes(fixture)
 if payload is None:
  path.mkdir();(path/'sentinel').write_bytes(b'preserve')
 else:path.write_bytes(payload)
 inode=path.stat().st_ino
 if case=='unreadable':path.chmod(0)
 config=work/'config';config.write_text('session.keep-alive-after-quit = false\n')
 env=dict(os.environ)
 for key in list(env):
  if key.startswith('MARU_'):env.pop(key)
 env.update(HOME=str(work),CFFIXED_USER_HOME=str(work),MARU_CONFIG=str(config),MARU_SESSION_HOST_ROOT=str(work/'host'),MARU_WEB_APP_ROOT=str(root/'web/dist'),MARU_SESSION_HOST_C4_QUIT_CANCEL_SMOKE='maru-test-only-v1')
 log=work/'app.log'
 with log.open('wb') as f:
  app=subprocess.Popen([str(root/'zig-out/Maru.app/Contents/MacOS/maru-macos-app')],env=env,cwd=root,stdout=f,stderr=f,start_new_session=True)
  try:code=app.wait(timeout=30)
  except subprocess.TimeoutExpired:os.killpg(app.pid,signal.SIGKILL);app.wait();raise
 text=log.read_text(errors='replace')
 if case=='unreadable':
  assert path.stat().st_mode & 0o777==0
  path.chmod(0o600)
 preserved=path.stat().st_ino==inode and backup.read_bytes()==fixture and ((path/'sentinel').read_bytes()==b'preserve' if payload is None else path.read_bytes()==payload)
 results.append((case,code,preserved,'restore was incomplete' in text,str(work)))
 print(results[-1],flush=True)
 assert code==0 and preserved and 'restore was incomplete' in text,text
print('all hostile app cases passed')
