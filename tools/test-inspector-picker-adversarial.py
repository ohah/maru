#!/usr/bin/env python3
"""Compile real picker defects in an isolated copy; require behavioral failures."""
import json,pathlib,shutil,subprocess,tempfile
repo=pathlib.Path(__file__).resolve().parents[1]
out=pathlib.Path(tempfile.mkdtemp(prefix='maru-picker-mutants-',dir='/tmp'))
(out/'chrome').mkdir();shutil.copytree(repo/'src/chrome/ui',out/'chrome/ui')
for src,dst in [('src/chrome/tokens.zig','chrome/tokens.zig'),('src/color.zig','color.zig')]:shutil.copy2(repo/src,out/dst)
(out/'root.zig').write_text('test { @import("std").testing.refAllDecls(@import("chrome/ui/inspection.zig")); }\n')
p=out/'chrome/ui/inspection.zig';original=p.read_text()
variants=[('baseline',None,None,True),('ignore-ancestor-clip','layout.intersectRect(e.rect, clip)','layout.intersectRect(e.rect, if (clip.width >= 0) e.rect else clip)',False),('reverse-paint-order','contains(nodes[i].visible_rect, x, y)','contains(nodes[nodes.len - 1 - i].visible_rect, x, y)',False),('reuse-stale-row','(k.generation == 0 or n.generation == k.generation)','(k.generation == 0 or n.generation == k.generation or n.generation != k.generation)',False),('ignore-source-identity','n.source == k.source and n.id','(n.source == k.source or n.source != k.source) and n.id',False),('include-exclusive-edge','x < @as(f64, r.x) + r.width','x <= @as(f64, r.x) + r.width',False),('equivalent-offset','rect.x += dx;','rect.x += dx + 0;',True),('restored',None,None,True)]
results=[]
for name,before,after,passes in variants:
    if before is not None:assert before in original,name
    p.write_text(original if before is None else original.replace(before,after))
    cmd=['mise','exec','--','zig','test','--dep','type_info_fields','--dep','array_repeat',f'-Mroot={out}/root.zig',f'-Mtype_info_fields={repo}/src/compat/type_info_fields.zig',f'-Marray_repeat={repo}/src/compat/array_repeat.zig','--test-filter','inspector inspection']
    r=subprocess.run(cmd,cwd=repo,capture_output=True,text=True);text=r.stdout+r.stderr
    (out/f'{name}.log').write_text(text)
    ok=r.returncode==0 if passes else r.returncode!=0 and ('TestUnexpectedResult' in text or 'TestExpectedEqual' in text) and 'compilation errors' not in text
    results.append({'case':name,'expected_pass':passes,'exit':r.returncode,'passed':ok})
    print(name,'PASS' if ok else 'FAIL',flush=True)
    if not ok:print(text);break
(out/'manifest.json').write_text(json.dumps(results,indent=2));print(out)
raise SystemExit(0 if len(results)==len(variants) and all(r['passed'] for r in results) else 1)
