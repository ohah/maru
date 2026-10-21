#!/usr/bin/env python3
"""Compile pane-tab geometry, identity and failure-path defects in an isolated copy."""
import json
import pathlib
import shutil
import subprocess
import tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
out=pathlib.Path(tempfile.mkdtemp(prefix='maru-pane-tabs-mutants-',dir='/tmp'))
shutil.copytree(repo/'src',out/'src')
(out/'src/judge.zig').write_text('test { @import("std").testing.refAllDecls(@import("chrome/components/tabbar/published.zig")); }\n')
pub='chrome/components/tabbar/published.zig';tabs='chrome/components/tabbar.zig';inspect='chrome/ui/inspection.zig'
original={name:(out/'src'/name).read_text() for name in (pub,tabs,inspect)}
variants=[
 ('baseline',pub,None,None,True),
 ('ignore-scroll',pub,'const seg = m.rawSegOf(ti);','var raw = m; raw.scroll_cols = 0; const seg = raw.rawSegOf(ti);',False),
 ('lose-close-parent',pub,'closeId(pi, ti), parent, r','closeId(pi, ti), if (parent == root) parent else root, r',False),
 ('alias-pane-identities',pub,'@as(u64, @intCast(pane)) * 0x100000000','@as(u64, @intCast(pane - pane)) * 0x100000000',False),
 ('ignore-epoch',pub,'std.hash.Wyhash.init(epoch)','std.hash.Wyhash.init(epoch -% epoch)',False),
 ('ignore-term-identity',pub,'[_]u64{ t.identity, @intFromBool(t.active) }','[_]u64{ 0, @intFromBool(t.active) }',False),
 ('invert-active-state',pub,'clip, .tab, tab.active, true','clip, .tab, !tab.active, true',False),
 ('keep-partial-failed-frame',pub,'self.invalidate();\n            return err;','return err;',False),
 ('disconnect-paint-input',tabs,'if (self.publication) |p| {','if (if (self.publication != null) null else self.publication) |p| {',False),
 ('extend-plus-into-fractional-cell',pub,'const end = @min(col + cols, m.cols);','const end = col + cols;',False),
 ('erase-visible-clip',pub,'.effective_clip = clip,','.effective_clip = .{ .x=clip.x, .y=clip.y, .width=0, .height=clip.height },',False),
 ('unbound-selection-generation',inspect,'.pane_tabs, .sidebar, .file_tree,','.sidebar, .file_tree,',False),
 ('equivalent-control-position',pub,'r.x += @floatFromInt(col * m.cell_width_px);','r.x += @as(f32, 0) + @as(f32, @floatFromInt(col * m.cell_width_px));',True),
 ('restored',pub,None,None,True),
]
results=[]
for name,path,before,after,passes in variants:
 for file,data in original.items():(out/'src'/file).write_text(data)
 if before is not None:
  assert before in original[path],name
  (out/'src'/path).write_text(original[path].replace(before,after))
 cmd=['mise','exec','--','zig','test','--dep','type_info_fields','--dep','array_repeat',f'-Mroot={out}/src/judge.zig',f'-Mtype_info_fields={repo}/src/compat/type_info_fields.zig',f'-Marray_repeat={repo}/src/compat/array_repeat.zig','--test-filter','pane tab']
 r=subprocess.run(cmd,cwd=repo,capture_output=True,text=True);log=r.stdout+r.stderr
 (out/f'{name}.log').write_text(log)
 ok=r.returncode==0 if passes else r.returncode!=0 and any(x in log for x in ('TestUnexpectedResult','TestExpectedEqual')) and 'compilation errors' not in log
 results.append(dict(name=name,passed=ok,expected_pass=passes,returncode=r.returncode))
 (out/'manifest.json').write_text(json.dumps(dict(passed=all(x['passed'] for x in results),results=results),indent=2))
 print(name,'PASS' if ok else 'FAIL',flush=True)
 if not ok:
  print(log[-1600:]);raise SystemExit(1)
print(out/'manifest.json')
