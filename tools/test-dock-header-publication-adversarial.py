#!/usr/bin/env python3
"""Compile real dock-header defects in an isolated source copy."""
import json,pathlib,shutil,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
out=pathlib.Path(tempfile.mkdtemp(prefix='maru-header-mutants-',dir='/tmp'))
shutil.copytree(repo/'src',out/'src')
(out/'src/judge.zig').write_text('test { @import("std").testing.refAllDecls(@import("chrome/components/dock_view_bar/published.zig")); }\n')
pub='chrome/components/dock_view_bar/published.zig';inspection='chrome/ui/inspection.zig'
original={p:(out/'src'/p).read_text() for p in (pub,inspection)}
variants=[
('baseline',pub,None,None,True),
('lose-parent',pub,'.parent_index = if (root) null else 0','.parent_index = if (root) null else null',False),
('lose-clip',pub,'.effective_clip = if (root) null else self.entries[0].rect','.effective_clip = if (root) null else null',False),
('invert-selected',pub,'.selected = active,','.selected = !active,',False),
('ignore-view-meaning',pub,'self.active, self.actions.len','self.active - self.active, self.actions.len',False),
('ignore-action-meaning',pub,'h.update(std.mem.asBytes(&id))','h.update(std.mem.asBytes(&(id - id)))',False),
('keep-stale-generation',pub,'self.generation +|= 1','self.generation +|= 0',False),
('omit-actions',pub,'self.append(actionId(i), r, .button, false)','self.append(actionId(i), .{ .x=r.x+1, .y=r.y, .w=r.w, .h=r.h }, .button, false)',False),
('unbound-selection',inspection,'.dock_header, .pane_tabs,','.pane_tabs,',False),
('equivalent',pub,'return root_id + 1 + index;','return root_id + index + 1;',True),
('restored',pub,None,None,True)]
results=[]
for name,path,before,after,passes in variants:
 for p,data in original.items():(out/'src'/p).write_text(data)
 if before is not None:
  assert before in original[path],name
  (out/'src'/path).write_text(original[path].replace(before,after))
 cmd=['mise','exec','--','zig','test','--dep','type_info_fields','--dep','array_repeat',f'-Mroot={out}/src/judge.zig',f'-Mtype_info_fields={repo}/src/compat/type_info_fields.zig',f'-Marray_repeat={repo}/src/compat/array_repeat.zig','--test-filter','dock header publication']
 r=subprocess.run(cmd,cwd=repo,capture_output=True,text=True);log=r.stdout+r.stderr
 (out/f'{name}.log').write_text(log)
 ok=r.returncode==0 and 'All 4 tests passed' in log if passes else r.returncode!=0 and any(x in log for x in ('TestUnexpectedResult','TestExpectedEqual','attempt to use null value')) and 'compilation errors' not in log
 results.append(dict(name=name,passed=ok,returncode=r.returncode,expected_pass=passes))
 (out/'manifest.json').write_text(json.dumps(dict(passed=all(x['passed'] for x in results),results=results),indent=2))
 print(name,'PASS' if ok else 'FAIL',flush=True)
 if not ok:print(log[-2000:]);raise SystemExit(1)
print(out/'manifest.json')
