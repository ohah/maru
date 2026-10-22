#!/usr/bin/env python3
"""Compile real sidebar-header defects in an isolated source copy."""
import json,pathlib,shutil,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
out=pathlib.Path(tempfile.mkdtemp(prefix='maru-sidebar-header-mutants-',dir='/tmp'))
shutil.copytree(repo/'src',out/'src')
(out/'src/judge.zig').write_text('test { @import("std").testing.refAllDecls(@import("chrome/components/sidebar/header.zig")); }\n')
pub='chrome/components/sidebar/header.zig';inspection='chrome/ui/inspection.zig'
original={p:(out/'src'/p).read_text() for p in (pub,inspection)}
variants=[
('baseline',pub,None,None,True),
('lose-parent',pub,'.parent_index = 0,','.parent_index = if(self.len==999) 0 else null,',False),
('ignore-owner',pub,'std.hash.Wyhash.init(m.identity)','std.hash.Wyhash.init(m.identity-m.identity)',False),
('ignore-focus',pub,'@intFromBool(m.search_active)','@intFromBool(m.search_active and !m.search_active)',False),
('erase-clip',pub,'layout.intersectRect(m.icon_clip, m.viewport)','m.viewport',False),
('lose-action',pub,'.action = .{ .id = partId(part) }','.action = null',False),
('keep-malformed-frame',pub,'self.invalidate();\n            return err;','return err;',False),
('unbound-selection',inspection,'.sidebar_header, .file_header_details,','.file_header_details,',False),
('closed-right-edge',pub,'x < @as(f64, r.x) + r.width','x <= @as(f64, r.x) + r.width',False),
('equivalent',pub,'return root_id + 1 + @backingInt(part);','return root_id + @backingInt(part) + 1;',True),
('restored',pub,None,None,True)]
results=[]
for name,path,before,after,passes in variants:
 for p,data in original.items():(out/'src'/p).write_text(data)
 if before is not None:
  assert before in original[path],name
  (out/'src'/path).write_text(original[path].replace(before,after))
 cmd=['mise','exec','--','zig','test','--dep','type_info_fields','--dep','array_repeat',f'-Mroot={out}/src/judge.zig',f'-Mtype_info_fields={repo}/src/compat/type_info_fields.zig',f'-Marray_repeat={repo}/src/compat/array_repeat.zig','--test-filter','inspector sidebar header']
 r=subprocess.run(cmd,cwd=repo,capture_output=True,text=True);log=r.stdout+r.stderr
 (out/f'{name}.log').write_text(log)
 ok=r.returncode==0 and 'All 3 tests passed' in log if passes else r.returncode!=0 and any(x in log for x in ('TestUnexpectedResult','TestExpectedEqual','attempt to use null value')) and 'compilation errors' not in log
 results.append(dict(name=name,passed=ok,returncode=r.returncode,expected_pass=passes))
 (out/'manifest.json').write_text(json.dumps(dict(passed=all(x['passed'] for x in results),results=results),indent=2))
 print(name,'PASS' if ok else 'FAIL',flush=True)
 if not ok:print(log[-2000:]);raise SystemExit(1)
print(out/'manifest.json')
