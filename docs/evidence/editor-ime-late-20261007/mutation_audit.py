from pathlib import Path
import hashlib,json,subprocess,sys
repo=Path(__file__).resolve().parents[3];out=Path(sys.argv[1]).resolve();out.mkdir(parents=True,exist_ok=True)
if any(out.iterdir()): raise SystemExit('Supply a new empty output directory')
s=(repo/'tools/shared-restore-app/ime_handoffs.py').read_text();t=(repo/'tools/shared-restore-app/test_ime_handoffs.py').read_text()
variants=[
('ignore-before-observation',"elif active is not None and line.startswith('[IME] callback_arrival '):","elif active is not None and active['observed'] is not None and line.startswith('[IME] callback_arrival '):",False),
('hide-new-owner',"[r for r in handoff['callbacks'] if r['owner'] == handoff['target']]","[]",False),
('hide-after-observation',"[r for r in handoff['callbacks'] if r['time'] >= handoff['observed']]","[]",False),
('count-following-key',"            active = None\n    for handoff", "            pass\n    for handoff",False),
('allow-same-owner',"active['source'] == active['target'] or active['observed'] < active['posted']","active['observed'] < active['posted']",False),
('allow-incomplete',"if handoff['observed'] is None:","if False:",False),
('equivalent-new-owner',"r['owner'] == handoff['target']","not r['owner'] != handoff['target']",True),
('equivalent-observed',"active['observed'] < active['posted']","not active['observed'] >= active['posted']",True),
]
rows=[]
for name,old,new,expected in variants:
 if s.count(old)!=1: raise SystemExit((name,s.count(old)))
 root=out/name;root.mkdir(exist_ok=True);p=root/'ime_handoffs.py';p.write_text(s.replace(old,new));(root/'test_ime_handoffs.py').write_text(t)
 r=subprocess.run(['python3',str(root/'test_ime_handoffs.py')],capture_output=True,text=True,timeout=10)
 (root/'test.log').write_text(r.stdout+r.stderr)
 rows.append(dict(name=name,expected_pass=expected,exit=r.returncode,matched=(r.returncode==0)==expected,sha256=hashlib.sha256(p.read_bytes()).hexdigest()))
(out/'results.json').write_text(json.dumps(rows,indent=2))
if not all(row['matched'] for row in rows): raise SystemExit(1)
print('6 mutations rejected; 2 equivalent controls passed')
