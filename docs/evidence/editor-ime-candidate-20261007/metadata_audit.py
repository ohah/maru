from pathlib import Path
import subprocess,json,hashlib,sys
repo=Path(__file__).resolve().parents[3];base=Path(sys.argv[1]).resolve();base.mkdir(parents=True,exist_ok=True)
if any(base.iterdir()): raise SystemExit('Supply a new empty output directory')
s=(repo/'tools/shared-restore-app/candidate_artifact.py').read_text();test=(repo/'tools/shared-restore-app/test_candidate_artifact.py').read_text();rows=[]
variants=[
('allow-unopened',"require(set(opened) - set(before) == {wid}, 'exactly one new window')","require(True, 'exactly one new window')",False),
('allow-retained-popup',"require(wid not in closed and row.get('popup_closed') is True, 'candidate still open')","require(True, 'candidate still open')",False),
('allow-mismatched-window',"proof.get('window_id') == wid","True",False),
('allow-other-owner',"owner.get('pid') == artifact['app_pid']","True",False),
('allow-path-traversal',"re.fullmatch(rf'candidate-{index}-{wid}\\.png', name) is not None","True",False),
('allow-wrong-source',"require(artifact['source_id'] == 'com.apple.inputmethod.Korean.2SetKorean', 'input source')","require(True, 'input source')",False),
('equivalent-fresh',"set(opened) - set(before) == {wid}","not set(opened) - set(before) != {wid}",True),
('equivalent-source',"artifact['source_id'] == 'com.apple.inputmethod.Korean.2SetKorean'","not artifact['source_id'] != 'com.apple.inputmethod.Korean.2SetKorean'",True)]
for name,old,new,expect in variants:
 if s.count(old)!=1: raise SystemExit((name,s.count(old)))
 root=base/name;root.mkdir(exist_ok=True);source=root/'candidate_artifact.py';source.write_text(s.replace(old,new));(root/'test_candidate_artifact.py').write_text(test)
 r=subprocess.run(['python3',str(root/'test_candidate_artifact.py')],capture_output=True,text=True,timeout=10)
 (root/'test.log').write_text(r.stdout+r.stderr);rows.append(dict(name=name,expected_pass=expect,exit=r.returncode,matched=(r.returncode==0)==expect,source_sha256=hashlib.sha256(source.read_bytes()).hexdigest()))
(base/'metadata-mutations.json').write_text(json.dumps(rows,indent=2))
if not all(r['matched'] for r in rows): raise SystemExit(1)
print('6 metadata mutations rejected; 2 equivalent implementations passed')
for i in range(1,6):
 r=subprocess.run(['python3',str(repo/'tools/shared-restore-app/test_candidate_artifact.py')],capture_output=True,text=True,timeout=10)
 (base/f'metadata-round-{i}.log').write_text(r.stdout+r.stderr)
 if r.returncode: raise SystemExit(r.returncode)
print('Metadata suite passed five consecutive rounds')
