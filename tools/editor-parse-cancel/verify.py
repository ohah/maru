#!/usr/bin/env python3
"""보존된 원시 로그를 결과 JSON과 독립적으로 대조한다."""
import argparse, ast, hashlib, json, re
from pathlib import Path
FILES = ('flat-3000.zig', 'flat-15000.zig', 'flat-50000.zig', 'real-build.zig', 'real-host.swift')
METRICS = ('cases', 'good')
def sha(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def verify(root):
    manifest=json.loads((root/'manifest.json').read_text())
    result=json.loads((root/'result.json').read_text())
    if sha(root/'archived-test') != result['binary_sha256']: raise ValueError('binary hash')
    for name, item in manifest['inputs'].items():
        f=root/'fixtures'/name
        if sha(f)!=item['sha256'] or f.stat().st_size!=item['bytes']: raise ValueError('fixture hash')
    for name, digest in manifest['original'].items():
        if name in ('build.zig','src/syntax/tree_sitter.zig'): continue
        if sha(root/'source'/name)!=digest: raise ValueError('product drift: '+name)
    if sha(root/'tool-snapshot/probe.zig.inc')!=manifest['probe_sha256']: raise ValueError('probe hash')
    if sha(root/'tool-snapshot/run.py')!=manifest['runner_sha256']: raise ValueError('runner hash')
    probe=(root/'tool-snapshot/probe.zig.inc').read_text()
    syntax=(root/'source/src/syntax/tree_sitter.zig').read_text()
    suffix='\n'+probe
    if not syntax.endswith(suffix): raise ValueError('probe suffix')
    runner_tree=ast.parse((root/'tool-snapshot/run.py').read_text())
    constants={node.targets[0].id:ast.literal_eval(node.value) for node in ast.walk(runner_tree) if isinstance(node,ast.Assign) and isinstance(node.targets[0],ast.Name) and node.targets[0].id in ('hook_anchor','hook')}
    base=syntax[:-len(suffix)]
    injected=constants['hook_anchor']+constants['hook']
    if base.count(injected)!=1: raise ValueError('callback injection identity')
    base=base.replace(injected,constants['hook_anchor'])
    if hashlib.sha256(base.encode()).hexdigest()!=manifest['original']['src/syntax/tree_sitter.zig']: raise ValueError('instrumented syntax drift')
    assignments=[node for node in ast.walk(ast.parse((root/'tool-snapshot/run.py').read_text())) if isinstance(node,ast.Assign) and any(isinstance(t,ast.Name) and t.id=='extra' for t in node.targets)]
    if len(assignments)!=1: raise ValueError('build patch identity')
    extra=ast.literal_eval(assignments[0].value)
    build=(root/'source/build.zig').read_text()
    if build.count(extra)!=1 or hashlib.sha256(build.replace(extra,'').encode()).hexdigest()!=manifest['original']['build.zig']: raise ValueError('instrumented build drift')
    rows=[]
    pattern=re.compile(r'CANCEL iteration=(\d+) bytes=(\d+) cases=4 callbacks=(\d+) good=1')
    for rep in range(2):
        for name in FILES:
            text=(root/f'run-{rep}-{name}.log').read_text()
            matches=pattern.findall(text)
            if len(matches)!=5 or text.count('CANCEL ')!=5 or 'All 2 tests passed.' not in text: raise ValueError('run completeness')
            for index, match in enumerate(matches):
                values=list(map(int,match))
                if values[:2]!=[index,manifest['inputs'][name]['bytes']]: raise ValueError('input identity')
                if values[2] < 3: raise ValueError('callback coverage')
                rows.append(dict(iteration=values[0],bytes=values[1],cases=4,callbacks=values[2],good=1,fixture=name,rep=rep))
    if rows!=result['rows']: raise ValueError('raw rows differ')
    summary={}
    for name in FILES:
        group=[r for r in rows if r['fixture']==name]
        summary[name]={key:{'p50':sorted(r[key] for r in group)[len(group)//2],'max':max(r[key] for r in group)} for key in METRICS}
    if summary!=result['summary']: raise ValueError('summary differs')
    faults=json.loads((root/'faults.json').read_text())
    if set(faults)!={'ignore_cancel','false_cancel','corrupt_copy','ignore_oom','skip_barrier'}: raise ValueError('fault coverage')
    for fault, item in faults.items():
        log=root/f'fault-{fault}.log'
        if not item['returncode'] or sha(log)!=item['log_sha256'] or not re.search(r'FAIL \(Test(?:UnexpectedResult|ExpectedEqual)\)', log.read_text()): raise ValueError('fault detection')
    return {'samples':len(rows),'processes':10, 'cases':sum(r['cases'] for r in rows),'faults_rejected':len(faults),'summary':summary}
def main():
    p=argparse.ArgumentParser();p.add_argument('output',type=Path);args=p.parse_args()
    print(json.dumps(verify(args.output),indent=2))
if __name__=='__main__':main()
