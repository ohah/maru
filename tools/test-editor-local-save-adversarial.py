#!/usr/bin/env python3
"""로컬 저장 분리의 실제 오류·본문·완료 판정에 결함을 주입한다."""
import json
from pathlib import Path
import subprocess
import tempfile
repo = Path(__file__).resolve().parents[1]
root = Path(tempfile.mkdtemp(prefix='maru-local-save-adversarial-'))
source = root / 'source'
subprocess.run(['rsync','-a','--exclude=.git','--exclude=.zig-cache','--exclude=zig-out','--exclude=node_modules','--exclude=references','--exclude=.env*','--exclude=.codex-worktrees',str(repo)+'/',str(source)+'/'],check=True)
path = source/'src/platform/macos/app_session/editor/local_save.zig'
original = path.read_text()
cases = [
 ('control', None, None),
 ('include-bom-in-logical-text','bytes.len - doc.file.content.len','0'),
 ('ignore-external-conflict','.cas => doc.disk_hash,','.cas => null,'),
 ('finish-wrong-target','if (!self.matches(term)) return false;','if (false and !self.matches(term)) return false;'),
 ('mark-new-edit-saved','markClean(session, term, self.content(), null)','markClean(session, term, term.rt.editorDocument().opened.?.file.content, null)'),
 ('use-logical-disk-hash','disk_hash = editor.contentHash(self.bytes);','disk_hash = editor.contentHash(self.content());'),
 ('restored-control', None, None),
]
results=[]
for name,old,new in cases:
 if old:
  assert original.count(old)==1,old
  path.write_text(original.replace(old,new,1))
 else:path.write_text(original)
 run=subprocess.run(['mise','exec','--','zig','build','test-editor-local-save','-j2','--cache-dir',str(root/'cache')],cwd=source,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=300)
 (root/(name+'.log')).write_text(run.stdout)
 if old:assert run.returncode!=0 and 'FAIL (' in run.stdout,(name,run.stdout[-3000:])
 else:assert run.returncode==0 and 'All 17 tests passed' in run.stdout,(name,run.stdout[-3000:])
 results.append({'case':name,'mutation':old is not None,'exit_code':run.returncode})
 print(name+': verified',flush=True)
path.write_text(original)
(root/'results.json').write_text(json.dumps(results,indent=2)+'\n')
print(root/'results.json',flush=True)
