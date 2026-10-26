#!/usr/bin/env python3
"""다섯 실제 C/제품 상태 판정 결함을 격리 사본에 컴파일해 검출력을 확인한다."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess

import contract
from run import ROOT, inventory, sha, write
from verify import load, verify


def change(path, old, new):
    text=path.read_text()
    contract.require(text.count(old)==1,'Ambiguous semantic mutation')
    path.unlink()
    path.write_text(text.replace(old,new))


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dataset',type=Path)
    parser.add_argument('--expected-head',required=True)
    parser.add_argument('--output',type=Path,required=True)
    parser.add_argument('--resume',action='store_true')
    args=parser.parse_args()
    base,out=args.dataset.resolve(),args.output.resolve()
    contract.require((not out.exists() or args.resume) and out!=ROOT and ROOT not in out.parents
                     and not (out/'result.json').exists(),'Use a new external output or resume an incomplete one')
    verify(base,args.expected_head)
    original=inventory(base/'source-1')
    reader=sha(Path(__file__))
    contract_reader=sha(Path(__file__).with_name('contract.py'))
    suffix=reader[:12]
    out.mkdir(parents=True,exist_ok=args.resume)
    cache=out/'cache'
    cache.mkdir(exist_ok=args.resume)
    env={k:v for k,v in os.environ.items() if not k.startswith('MARU_')}
    env.update(MARU_BUDGET_FILE=str(base/'fixtures/flat-50000.zig'),MARU_BUDGET_NS='4000000',MARU_BUDGET_ACCURACY='1')
    state='src/platform/macos/app_session/editor/syntax.zig'
    native='src/syntax/tree_sitter.zig'
    native_text=(base/'source-1'/native).read_text()
    begin=native_text.index('    pub fn onEditBudgeted(')
    reset_line='        c.ts_parser_reset(self.parser);'
    reset_end=native_text.index(reset_line,begin)+len(reset_line)
    reset_block=native_text[begin:reset_end]
    cases=[
        ('pending-stamp',state,'    if (self.pending) return false;\n    const p = if (self.provider)',
            '    if (false) return false;\n    const p = if (self.provider)','state','budget state contract'),
        ('pending-copy',state,'    if (source.pending) return null;',
            '    if (false) return null;','state','budget state contract'),
        ('resume-stamp',state,'    if (!self.pending) return false;\n    clearInputProofs(self);',
            '    if (!self.pending) return false;','state','budget state contract'),
        ('pending-reset',native,reset_block,reset_block.replace(reset_line,''),
            'measure','pending edits discard older parse state'),
        ('node-geometry',native,
            '        if (c.ts_node_start_byte(ln) != c.ts_node_start_byte(rn) or c.ts_node_end_byte(ln) != c.ts_node_end_byte(rn)) return null;\n        if (!std.meta.eql(c.ts_node_start_point(ln), c.ts_node_start_point(rn)) or\n            !std.meta.eql(c.ts_node_end_point(ln), c.ts_node_end_point(rn))) return null;',
            '        // 격리 결함: 실제 C 노드의 좌표를 판정에서 제외한다.','measure','oracle rejects a shifted native tree'),
    ]

    def copy_source(name):
        source=out/name/'source'
        if source.exists():
            contract.require(args.resume,'Existing source without resume')
            return source
        shutil.copytree(base/'source-1',source,copy_function=os.link,symlinks=True,
                        ignore=shutil.ignore_patterns('.zig-cache','zig-pkg','zig-out','.git'))
        (source/'zig-pkg').symlink_to((base/'source-1/zig-pkg').resolve(),target_is_directory=True)
        return source

    control=copy_source('normal')
    contract.require(inventory(control)==original,'Normal source differs from the captured original')
    records=[]

    def execute(source,kind,log):
        command=['mise','exec','--','zig','build','test-native-budget-'+kind,'-Doptimize=ReleaseFast','-j2',
                 '--cache-dir',str(cache)]
        with log.open('xb') as stream:
            done=subprocess.run(command,cwd=source,env=env,stdout=stream,stderr=subprocess.STDOUT)
        return done.returncode,command,log.read_text()

    with (cache/'measurement-active.lock').open('ab'):
        for name,path,old,new,kind,witness in cases:
            count=4 if kind=='measure' else 2
            before=out/('normal-'+name+'-before-'+suffix+'.log')
            code,command,text=execute(control,kind,before)
            contract.require(code==0 and f'All {count} tests passed.' in text,'Normal compiled control failed')
            source=copy_source(name)
            if inventory(source)==original:
                change(source/path,old,new)
            expected=dict(original)
            original_text=(base/'source-1'/path).read_text()
            contract.require(original_text.count(old)==1,'Invalid original mutation anchor')
            expected[path]=__import__('hashlib').sha256(original_text.replace(old,new).encode()).hexdigest()
            contract.require(inventory(source)==expected,'Mutant source has unrelated changes')
            log=out/name/('mutant-'+suffix+'.log')
            code,mutant_command,text=execute(source,kind,log)
            contract.require(code!=0 and re.search(r':\d+:\d+: error:',text) is None,
                             'Compiler failure or accepted mutant: '+name)
            contract.require(contract.semantic_failure(text,witness),
                             'No intended semantic test failure: '+name)
            after=out/('normal-'+name+'-after-'+suffix+'.log')
            normal_code,_,normal_text=execute(control,kind,after)
            contract.require(normal_code==0 and f'All {count} tests passed.' in normal_text,'Normal restore failed')
            records.append(dict(case=name,mutation=dict(path=path,old=old,new=new),witness=witness,
                command=mutant_command,exit=code,log_sha256=sha(log),
                log=str(log),before_log=str(before),after_log=str(after),
                before_sha256=sha(before),after_sha256=sha(after),source_sha256=inventory(source)))
            print('COMPILED_BUDGET_FAULT_REJECTED',name,flush=True)
    contract.require(inventory(base/'source-1')==original and sha(Path(__file__))==reader
                     and sha(Path(__file__).with_name('contract.py'))==contract_reader,'Evidence or reader changed')
    write(out/'result.json',dict(complete=True,head=args.expected_head,cases=records,reader_sha256=reader,
          contract_sha256=contract_reader,original_source_sha256=original,
          scope='Five compiled semantic faults and ten normal controls; compile errors and test-selection failures are excluded; resume revalidates exact sources and preserves old logs'))


if __name__=='__main__':
    main()
