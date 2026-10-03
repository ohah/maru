# -*- coding: utf-8 -*-
"""Opt-in actual-app preservation checks for unreadable and malformed checkpoints.
Every scenario uses its own disposable home and session-host namespace.
"""
from pathlib import Path
import subprocess, os, tempfile, signal, sys, json
root=Path(__file__).resolve().parents[1]
fixture=(root/'tests/fixtures/session-host/ended-runtime-workspace.v1').read_bytes()
results=[]
cases=[('truncated',fixture[:len(fixture)//2]),('invalid_utf8',b'\xff\xfe\x00broken'),('wrong_header',b'maru-workspace-v999\n'),('directory',None),('unreadable',fixture)]
if '--extended' in sys.argv:
 cuts=[1,8,fixture.index(b'window')+7,fixture.index(b'tab panes')+7,
       fixture.index(b'tree-node')+10,fixture.index(b'pane surfaces')+10,
       fixture.index(b'surface custom')+10,fixture.index(b'runtime-handle')+20,
       fixture.index(b'runtime-state')+20,fixture.index(b'fedcba')+10]
 cases=[('truncate-%02d'%i,fixture[:cut]) for i,cut in enumerate(cuts,1)]
 edits=[('header',b'maru.workspace.v2',b'maru.workspace.v999'),
        ('window-count',b'window tabs=1',b'window tabs=2'),
        ('window-active',b'active-tab=0',b'active-tab=invalid'),
        ('tab-count',b'tab panes=1',b'tab panes=2'),
        ('tab-active',b'active-pane=0',b'active-pane=invalid'),
        ('tree-pane',b'leaf pane=0',b'leaf pane=999999'),
        ('surface-count',b'pane surfaces=1',b'pane surfaces=2'),
        ('surface-active',b'active-term=0',b'active-term=invalid')]
 for name,before,after in edits:
  assert fixture.count(before)==1
  cases.append((name,fixture.replace(before,after)))
 cases.extend([('directory',None),('unreadable',fixture)])
 assert len(cases)==20
for case,payload in cases:
 work=Path(tempfile.mkdtemp(prefix='maru-hostile-'+case+'-'))
 parent=work/'Library/Application Support/maru';parent.mkdir(parents=True)
 path=parent/'workspace.v1';backup=parent/'workspace.v1.bak';backup.write_bytes(fixture)
 backup_inode=backup.stat().st_ino
 sibling=parent/'unrelated-state';sibling.write_bytes(b'unrelated sentinel')
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
 assert backup.stat().st_ino==backup_inode
 assert sibling.read_bytes()==b'unrelated sentinel'
 assert not (parent/'.workspace.v1.tmp').exists()
assert len(results)==len(cases)
print('all hostile app cases passed count='+str(len(results)))
if '--report' in sys.argv:
 output=Path(sys.argv[sys.argv.index('--report')+1]);output.write_text(json.dumps(results,indent=2))
