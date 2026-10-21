#!/usr/bin/env python3
"""Compile real file-header defects in an isolated source copy."""
import json,pathlib,shutil,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
out=pathlib.Path(tempfile.mkdtemp(prefix='maru-file-header-mutants-',dir='/tmp'))
shutil.copytree(repo/'src',out/'src')
(out/'src/judge.zig').write_text('test { @import("std").testing.refAllDecls(@import("chrome/components/file_header.zig")); }\n')
pub='chrome/components/file_header.zig';inspection='chrome/ui/inspection.zig'
original={p:(out/'src'/p).read_text() for p in (pub,inspection)}
variants=[
('baseline',pub,None,None,True),
('alias-pane',pub,'@as(u64, @intCast(index)) * 0x100000000','@as(u64, @intCast(index-index)) * 0x100000000',False),
('lose-parent',pub,'.parent_index = parent,','.parent_index = if (parent==999999) parent else null,',False),
('ignore-owner',pub,'m.identity, m.rect.x','m.identity-m.identity, m.rect.x',False),
('ignore-active',pub,'@intFromBool(c.active)','@intFromBool(c.active and !c.active)',False),
('ignore-epoch',pub,'std.hash.Wyhash.init(epoch)','std.hash.Wyhash.init(epoch-epoch)',False),
('erase-clip',pub,'const r = layout.intersectRect(c.rect.ui(), clip);','const r = c.rect.ui();',False),
('keep-partial-frame',pub,'self.invalidate();\n            return err;','return err;',False),
('hash-invalid-controls',pub,'if (m.count > m.controls.len) continue;\n        for (m.controls[0..m.count])','for (m.controls[0..@min(m.count, 3)])',False),
('unbound-selection',inspection,'.file_header, .dock_header,','.dock_header,',False),
('equivalent',pub,'return rootId(index) + 1 + tag;','return rootId(index) + tag + 1;',True),
('restored',pub,None,None,True)]
results=[]
for name,path,before,after,passes in variants:
 for p,data in original.items():(out/'src'/p).write_text(data)
 if before is not None:
  assert before in original[path],name
  (out/'src'/path).write_text(original[path].replace(before,after))
 cmd=['mise','exec','--','zig','test','--dep','type_info_fields','--dep','array_repeat',f'-Mroot={out}/src/judge.zig',f'-Mtype_info_fields={repo}/src/compat/type_info_fields.zig',f'-Marray_repeat={repo}/src/compat/array_repeat.zig','--test-filter','inspector file header publication']
 r=subprocess.run(cmd,cwd=repo,capture_output=True,text=True);log=r.stdout+r.stderr
 (out/f'{name}.log').write_text(log)
 ok=r.returncode==0 and 'All 3 tests passed' in log if passes else r.returncode!=0 and any(x in log for x in ('TestUnexpectedResult','TestExpectedEqual','attempt to use null value')) and 'compilation errors' not in log
 results.append(dict(name=name,passed=ok,returncode=r.returncode,expected_pass=passes))
 (out/'manifest.json').write_text(json.dumps(dict(passed=all(x['passed'] for x in results),results=results),indent=2))
 print(name,'PASS' if ok else 'FAIL',flush=True)
 if not ok:print(log[-2000:]);raise SystemExit(1)
print(out/'manifest.json')
