#!/usr/bin/env python3
"""독립 사본에서 Provider의 마지막 참조를 워커가 해제하는 비용을 측정한다."""
import argparse, hashlib, json, os, re, shutil, subprocess
from pathlib import Path
ROOT = Path(__file__).resolve().parents[2]
FILES = ('flat-3000.zig', 'flat-15000.zig', 'flat-50000.zig', 'real-build.zig', 'real-host.swift')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p = argparse.ArgumentParser()
    p.add_argument('--output', type=Path, required=True)
    p.add_argument('--deps', type=Path, required=True)
    p.add_argument('--fixtures', type=Path, required=True)
    p.add_argument('--cache', type=Path)
    args = p.parse_args()
    out, deps = args.output.resolve(), args.deps.resolve()
    if out.exists() or ROOT == out or ROOT in out.parents or not deps.is_dir(): p.error('new external output and existing dependencies required')
    if subprocess.check_output(['git','status','--porcelain','--','src','build.zig','build.zig.zon'],cwd=ROOT): p.error('product source must be clean')
    out.mkdir(parents=True)
    source = out / 'source'
    source.mkdir()
    tracked = subprocess.check_output(['git','ls-files','-z'],cwd=ROOT).decode().split('\0')
    original = {}
    for name in filter(None, tracked):
        item = ROOT / name
        if not item.is_file(): continue
        target = source / name
        target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copy2(item,target)
        if name.startswith('src/') or name in ('build.zig','build.zig.zon'): original[name] = sha(item)
    if args.cache: (source/'.zig-cache').symlink_to(args.cache.resolve(), target_is_directory=True)
    (source/'zig-pkg').symlink_to(deps, target_is_directory=True)
    shutil.copytree(Path(__file__).parent, out/'tool-snapshot', ignore=shutil.ignore_patterns('__pycache__'))
    probe = Path(__file__).with_name('probe.zig.inc')
    target = source/'src/syntax/tree_sitter.zig'
    target.write_text(target.read_text()+'\n'+probe.read_text())
    build = source/'build.zig'
    text = build.read_text()
    anchor = '    const syntax_tests ='
    assert text.count(anchor)==1
    extra = '''    const handoff_buffer = b.createModule(.{ .root_source_file = b.path("src/session/editor/buffer.zig"), .target = target, .optimize = optimize });
    handoff_buffer.addImport("array_repeat", b.createModule(.{ .root_source_file = b.path("src/compat/array_repeat.zig") }));
    syntax_mod.addImport("handoff_buffer", handoff_buffer);
    const handoff_test = addProjectTest(b, .{ .root_module = syntax_mod, .filters = &.{".test.handoff measure "} });
    const handoff_run = b.addRunArtifact(handoff_test);
    handoff_run.addArg("--maru-expect-tests=2");
    handoff_run.addArg("--maru-expect-passed=2");
    handoff_run.has_side_effects = true;
    b.step("test-handoff-measure", "Measure independent snapshot handoff").dependOn(&handoff_run.step);
'''
    build.write_text(text.replace(anchor,extra+anchor))
    inputs={}
    (out/'fixtures').mkdir()
    for name in FILES:
        dst=out/'fixtures'/name
        shutil.copy2(args.fixtures/name,dst)
        inputs[name]={'sha256':sha(dst),'bytes':dst.stat().st_size}
    env=dict(os.environ,ZIG_LOCAL_PKG_DIR=str(deps),MARU_HANDOFF_FILE=str(out/'fixtures'/FILES[0]))
    command=['mise','exec','--','zig','build','test-handoff-measure','-Doptimize=ReleaseFast','-j2','--verbose']
    manifest={'head':subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),'original':original,'probe_sha256':sha(probe),'runner_sha256':sha(Path(__file__)),'inputs':inputs,'command':command}
    (out/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    with (out/'build.log').open('xb') as log: subprocess.run(command,cwd=source,env=env,stdout=log,stderr=subprocess.STDOUT,check=True)
    found=re.findall(r'(\./\.zig-cache/o/[0-9a-f]+/test) --maru-expect-tests=2', (out/'build.log').read_text())
    if not found: raise RuntimeError('missing executed binary')
    binary=out/'archived-test';shutil.copy2(source/found[-1],binary)
    faults = {}
    for fault in ('geometry', 'metadata', 'provider', 'thread', 'missingrelease'):
        with (out/f'fault-{fault}.log').open('xb') as log:
            done = subprocess.run([str(binary),'--maru-expect-tests=2','--maru-expect-passed=2'],cwd=source,env=dict(env,MARU_HANDOFF_FAULT=fault),stdout=log,stderr=subprocess.STDOUT)
        text = (out/f'fault-{fault}.log').read_text()
        if done.returncode == 0 or 'FAIL' not in text or 'TestUnexpectedResult' not in text: raise RuntimeError('fault not rejected: '+fault)
        faults[fault] = {'returncode':done.returncode,'log_sha256':sha(out/f'fault-{fault}.log')}
    (out/'faults.json').write_text(json.dumps(faults,indent=2)+'\n')
    rows=[]
    for rep in range(3):
        for name in FILES:
            with (out/f'run-{rep}-{name}.log').open('xb') as log:
                subprocess.run([str(binary),'--maru-expect-tests=2','--maru-expect-passed=2'],cwd=source,env=dict(env,MARU_HANDOFF_FILE=str(out/'fixtures'/name)),stdout=log,stderr=subprocess.STDOUT,check=True)
            text=(out/f'run-{rep}-{name}.log').read_text()
            records=[dict((k,int(v)) for k,v in re.findall(r'(\w+)=(\d+)',line)) for line in text.splitlines() if 'HANDOFF ' in line]
            if len(records)!=20 or [r['iteration'] for r in records]!=list(range(20)) or any(r['good']!=1 or r['bytes']!=inputs[name]['bytes'] for r in records): raise RuntimeError('incomplete run')
            rows.extend(dict(r,fixture=name,rep=rep) for r in records)
    summary={}
    for name in FILES:
        group=[r for r in rows if r['fixture']==name]
        summary[name]={key:{'p50':sorted(r[key] for r in group)[len(group)//2],'max':max(r[key] for r in group)} for key in group[0] if key.endswith('_ns')}
    (out/'result.json').write_text(json.dumps({'binary_sha256':sha(binary),'rows':rows,'summary':summary},indent=2)+'\n')
    print(json.dumps(summary,indent=2))
if __name__=='__main__': main()
