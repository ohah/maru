from pathlib import Path
import subprocess,json,hashlib,sys
repo=Path(__file__).resolve().parents[4]
out=Path(sys.argv[1]).resolve()
out.mkdir(parents=True, exist_ok=True)
if any(out.iterdir()): raise SystemExit('Supply a new empty output directory')
source=(repo/'tools/shared-restore-app/run.py').read_text()
test=(repo/'tools/shared-restore-app/test_runner.py').read_text()
variants=[
 ('r1-negative-frame','int(actual["hit_rows"]) <= 0','int(actual["hit_rows"]) == 0',False),
 ('r1-equivalent','int(actual["hit_rows"]) <= 0','not int(actual["hit_rows"]) > 0',True),
 ('r2-backup-count',"require(len(records) == 1, 'closing one view removed shared backup')","require(True, 'closing one view removed shared backup')",False),
 ('r2-backup-body',"require(records[0].read_bytes().split(b'\\n\\n', 1)[1] == expected_backup)","require(True)",False),
 ('r2-equivalent',"require(len(records) == 1, 'closing one view removed shared backup')","require(not len(records) != 1, 'closing one view removed shared backup')",True),
 ('r3-child-exit',"require(code == 0 and 'SHARED_RESTORE_ERROR' not in transcript, (phase, code, str(output)))","require('SHARED_RESTORE_ERROR' not in transcript, (phase, code, str(output)))",False),
 ('r3-optimized','if not condition:','if not condition and __debug__:',False),
 ('r3-equivalent','if not condition:','if bool(condition) is False:',True),
 ('r4-git-root','env=env, check=True, timeout=15','check=True, timeout=15',False),
 ('r4-equivalent','if not key.startswith("GIT_")','if key[:4] != "GIT_"',True),
]
results=[]
for name,old,new,expect in variants:
 if source.count(old)!=1: raise RuntimeError((name,source.count(old)))
 root=out/name;root.mkdir(exist_ok=True)
 candidate=root/'run.py';candidate.write_text(source.replace(old,new))
 suite=root/'test_runner.py';suite.write_text(test)
 result=subprocess.run(['python3',str(suite)],capture_output=True,text=True,timeout=30)
 (root/'test.log').write_text(result.stdout+result.stderr)
 passed=result.returncode==0
 results.append(dict(variant=name,exit=result.returncode,expected_pass=expect,matched=passed==expect,sha256=hashlib.sha256(candidate.read_bytes()).hexdigest()))
 if passed!=expect: print(name,'UNEXPECTED',result.stderr[-1200:])
(out/'rounds-1-4.json').write_text(json.dumps(results,indent=2))
if not all(r['matched'] for r in results): raise SystemExit(1)
print('All 10 runtime mutation/equivalence controls matched')
