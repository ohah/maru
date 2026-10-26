#!/usr/bin/env python3
"""실측 사본의 다섯 독립 의미 손상과 전후 정상 대조를 검사한다."""
import argparse
import json
import os
from pathlib import Path
import shutil

import contract
from run import ROOT, sha, write
from verify import load, verify


def replace(path, data):
    # 사본은 hardlink다. 쓰기 전에 링크를 끊어 원본 증거를 보존한다.
    path.unlink()
    path.write_bytes(data)


def put(path, value):
    replace(path, (json.dumps(value, indent=2)+'\n').encode())


def clone(source, out):
    shutil.copytree(source, out, copy_function=os.link, symlinks=True,
                    ignore=shutil.ignore_patterns('.zig-cache','zig-pkg'))
    meta = load(out/'result.json')
    for row in meta['runs'].values():
        row['command'][0] = str(out/'archived-measure')
        row['environment']['MARU_BUDGET_FILE'] = str(out/'fixtures'/row['fixture'])
    put(out/'result.json',meta)


def record(out, mutate):
    value = load(out/'result.json')
    mutate(value)
    put(out/'result.json',value)


def log_change(out, key, old, new):
    path = out/(key+'.log')
    text = path.read_text()
    contract.require(old in text, 'Fault anchor absent')
    replace(path, text.replace(old,new,1).encode())
    record(out, lambda value:value['runs'][key].update(log_sha256=sha(path)))


def missing_dependency(out):
    path = out/'producer.json'
    producer = load(path)
    name = 'tools/editor-frame-measure/contract.py'
    del producer['tools_sha256'][name]
    (out/'tool-snapshot'/name).unlink()
    put(path,producer)
    record(out,lambda value:value.update(producer_sha256=sha(path)))


def binary_collision(out):
    replace(out/'archived-state',(out/'archived-measure').read_bytes())
    record(out,lambda value:value['binaries']['state'].update(sha256=value['binaries']['measure']['sha256']))


def runner_source(out):
    path=out/'source-1/tools/simple_test_runner.zig'
    replace(path,path.read_bytes()+b'\n// mismatched build input\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dataset',type=Path)
    parser.add_argument('--expected-head',required=True)
    parser.add_argument('--output',type=Path,required=True)
    args = parser.parse_args()
    source,out = args.dataset.resolve(),args.output.resolve()
    contract.require(not out.exists() and out != ROOT and ROOT not in out.parents,'Use a new external output')
    original = {p.name:sha(p) for p in source.glob('*.log')}
    original['result.json'] = sha(source/'result.json')
    verify(source,args.expected_head)
    out.mkdir(parents=True)
    timing='run-0-0-flat-3000.zig-0'
    accuracy='run-1-0-flat-3000.zig-0'
    groups = [
        ('population',[
            ('missing-process',lambda p:record(p,lambda v:v['runs'].pop(timing)),'Missing or extra run population'),
            ('wrong-input-count',lambda p:record(p,lambda v:v.update(accuracy_inputs=180)),'Invalid accuracy population'),
            ('bool-version',lambda p:record(p,lambda v:v.update(schema=True)),'Invalid schema')]),
        ('timing',[
            ('wrong-sum',lambda p:log_change(p,timing,'call_ns=','call_ns=1'),'Wrong timing aggregate'),
            ('negative-duration',lambda p:log_change(p,timing,'ns=','ns=-'),'Invalid integer field'),
            ('overflow-counter',lambda p:log_change(p,timing,'key=0','key='+str(2**64)),'Counter exceeds u64')]),
        ('completion',[
            ('never-done',lambda p:log_change(p,timing,'done=1','done=0'),'Edit never completed'),
            ('wrong-resume-count',lambda p:log_change(p,timing,'resumes=0','resumes=1'),'Wrong resume population'),
            ('wrong-slice-order',lambda p:log_change(p,timing,'slice=0','slice=1'),'Reordered or missing slice')]),
        ('freshness',[
            ('stale-latest-input',lambda p:log_change(p,accuracy,'latest_equal=1','latest_equal=0'),'Missing latest-input oracle'),
            ('oracle-control-ignored',lambda p:log_change(p,accuracy,'shifted_rejected=1','shifted_rejected=0'),'Missing native oracle control'),
            ('pending-chain-omitted',lambda p:log_change(p,accuracy,'stage=1 pending=1','stage=1 pending=0'),'Missing real pending input chain')]),
        ('identity',[
            ('wrong-build-runner-source',runner_source,'File hash differs: simple_test_runner.zig'),
            ('coherent-binary-collision',binary_collision,'Measurement and state binaries must differ'),
            ('wrong-executable',lambda p:record(p,lambda v:v['runs'][timing]['command'].__setitem__(0,str(p/'archived-state'))),'Wrong executed target'),
            ('missing-producer-contract',missing_dependency,'Missing executed producer dependency'),
            ('failed-process',lambda p:record(p,lambda v:v['runs'][timing].update(exit=1)),'Invalid exit')]),
    ]
    rejected,controls=[],[]
    for group,cases in groups:
        verify(source,args.expected_head)
        controls.append(group+':before')
        for name,mutate,reason in cases:
            case=out/group/name
            clone(source,case)
            mutate(case)
            try:
                verify(case,args.expected_head)
            except ValueError as error:
                contract.require(reason in str(error),'Wrong rejection for '+group+'/'+name+': '+str(error))
                rejected.append(dict(group=group,case=name,reason=str(error)))
            else:
                raise AssertionError('Actual semantic fault accepted: '+group+'/'+name)
        verify(source,args.expected_head)
        controls.append(group+':after')
    equivalent=out/'runner-display-equivalent'
    clone(source,equivalent)
    log_change(equivalent,timing,'tree_sitter.test.budget measure edit slices and complete tree oracle',
               'other display text')
    verify(equivalent,args.expected_head)
    controls.append('runner-display-equivalent')
    contract.require(original == ({p.name:sha(p) for p in source.glob('*.log')} |
                     {'result.json':sha(source/'result.json')}),'Original evidence changed')
    write(out/'result.json',dict(complete=True,hypotheses=5,rejected=rejected,normal_controls=controls,
          reader_sha256={name:sha(Path(__file__).with_name(name)) for name in ('verify.py','contract.py','adversarial.py')},
          scope='Real records with recomputed log hashes; compiler/selection failures are not semantic detections; native shifted-tree oracle is a separate compiled control'))
    print('BUDGET_ADVERSARIAL_PASS',len(rejected),len(controls))


if __name__=='__main__':
    main()
