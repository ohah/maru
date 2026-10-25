#!/usr/bin/env python3
"""제품을 바꾸지 않고 실제 색 조회 행 수와 보수적인 화면 상한을 관측한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--output', type=Path, required=True)
p.add_argument('--deps', type=Path, required=True)
a = p.parse_args()
repo = Path(__file__).resolve().parents[2]
out = a.output.resolve()
if out.exists() or out == repo or repo in out.parents or not a.deps.resolve().is_dir():
    p.error('저장소 밖의 새 출력 경로와 실제 dependency 경로가 필요합니다')
source = out / 'source'
source.mkdir(parents=True)
subprocess.run(['git','diff','--exit-code','--','src','build.zig','build.zig.zon'],cwd=repo,check=True)
subprocess.run(['rsync','-a','--exclude=.git','--exclude=.zig-cache','--exclude=zig-out','--exclude=node_modules','--exclude=zig-pkg','--exclude=references','--exclude=.env*',str(repo)+'/',str(source)+'/'],check=True)
(source/'zig-pkg').symlink_to(a.deps.resolve(),target_is_directory=True)
fixtures=out/'fixtures';fixtures.mkdir()
for name,path in [('real-build.zig','build.zig'),('real-host.swift','src/platform/macos/MaruAppHost.swift')]:
    (fixtures/name).write_bytes((repo/path).read_bytes())
(fixtures/'flat-3000.zig').write_text(''.join(f'pub fn f{i}() u32 {{\n    const x = {i};\n    return x + 1;\n}}\n' for i in range(3000)))
sha=lambda path:hashlib.sha256(path.read_bytes()).hexdigest()
original={str(x.relative_to(repo)):sha(x) for x in (repo/'src').rglob('*') if x.is_file()}
fixture=Path(__file__).with_name('query.zig.inc');host=source/'src/platform/macos/app_session/editor/mod.zig';host.write_text(host.read_text()+'\n'+fixture.read_text())
build=source/'build.zig';text=build.read_text();anchor='    const edit_cost_tests =';assert text.count(anchor)==1
text=text.replace(anchor,'''    const visible_color = addProjectTest(b, .{ .root_module = editor_tests.root_module, .filters = &.{".test.visible color query"} });
    const run_visible_color = b.addRunArtifact(visible_color);
    run_visible_color.setCwd(b.path("."));
    run_visible_color.addArg("--maru-expect-tests=5");
    run_visible_color.addArg("--maru-expect-passed=5");
    b.step("test-visible-color-query", "Observe visible color query bounds and cost").dependOn(&run_visible_color.step);
'''+anchor);build.write_text(text)
proof={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=repo,text=True).strip(),'original_source':original,'source':{str(x.relative_to(source)):sha(x) for x in (source/'src').rglob('*') if x.is_file()},'build':sha(build),'fixtures':{x.name:sha(x) for x in fixtures.iterdir()},'generator':sha(Path(__file__)),'template':sha(fixture)}
(out/'prebuild.json').write_text(json.dumps(proof,indent=2)+'\n');shutil.copyfile(__file__,out/'generator.py');shutil.copyfile(fixture,out/'query.zig.inc')
env={k:v for k,v in os.environ.items() if not k.startswith('MARU_')};env['MARU_VISIBLE_COLOR_FILE']=str(fixtures/'flat-3000.zig')
with (out/'build.log').open('xb') as f:code=subprocess.run(['mise','exec','--','zig','build','test-visible-color-query','-Doptimize=ReleaseFast','-j2','--verbose'],cwd=source,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
assert code==0,'prepare failed; preserve this output and use a new directory after correction'
log=(out/'build.log').read_text();assert 'All 5 tests passed.' in log;matches=re.findall(r'(\./\.zig-cache/o/[0-9a-f]+/test) --maru-expect-tests=5',log);assert matches
exe=out/'test';shutil.copy2(source/matches[-1],exe);(out/'binary.json').write_text(json.dumps({'path':str(exe),'cwd':str(source),'sha256':sha(exe)},indent=2)+'\n')
for file in sorted(fixtures.iterdir()):
    env['MARU_VISIBLE_COLOR_FILE']=str(file)
    with (out/(file.name+'.log')).open('xb') as f:code=subprocess.run([str(exe),'--maru-expect-tests=5','--maru-expect-passed=5'],cwd=source,env=env,stdout=f,stderr=subprocess.STDOUT).returncode
    assert code==0,file.name
    print(file.name,'PASS',flush=True)
assert sha(exe)==json.loads((out/'binary.json').read_text())['sha256']
assert all(sha(source/name)==h for name,h in proof['source'].items())
assert sha(build)==proof['build'];assert all(sha(fixtures/name)==h for name,h in proof['fixtures'].items())
(out/'result.json').write_text(json.dumps({'complete':True,'binary_sha256':sha(exe),'logs':{x.name:sha(x) for x in out.glob('*.log')}},indent=2)+'\n')
