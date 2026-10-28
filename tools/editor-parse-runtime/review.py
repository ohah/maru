#!/usr/bin/env python3
"""독립 소스에서 수명·판·nonce·재무장·앱 close 연결의 실제 결함을 컴파일한다."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
ROOT = Path(__file__).resolve().parents[2]
WORKER = 'src/platform/macos/app_session/editor/parse/worker.zig'
RUNTIME = 'src/platform/macos/app_session/editor/parse/runtime.zig'
DISPATCH = 'src/platform/macos/app_session/editor/parse/dispatch.zig'
REGISTRY = 'src/session/editor/document_registry.zig'
def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()
def main():
    p = argparse.ArgumentParser()
    for name in ('output','deps','cache'):
        p.add_argument('--'+name, type=Path, required=True)
    p.add_argument("--scope", choices=("lifetime", "observation"), default="lifetime")
    args = p.parse_args()
    out, deps = args.output.resolve(), args.deps.resolve()
    if out.exists() or out == ROOT or ROOT in out.parents or not deps.is_dir():
        p.error('new external output and existing dependency directory required')
    out.mkdir(parents=True)
    source = out/'source'
    source.mkdir()
    inventory = {}
    for name in filter(None, subprocess.check_output(['git','ls-files','-z'], cwd=ROOT).decode().split('\0')):
        item = ROOT/name
        if not item.is_file(): continue
        target = source/name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(item,target)
        if name.startswith('src/') or name in ('build.zig','build.zig.zon','tools/simple_test_runner.zig'):
            inventory[name] = sha(item)
    for name in (WORKER,RUNTIME,DISPATCH,REGISTRY):
        if name not in inventory: raise RuntimeError('stage new source first: '+name)
    (source/'zig-pkg').symlink_to(deps, target_is_directory=True)
    baseline = {name:(source/name).read_text() for name in (WORKER,RUNTIME,DISPATCH,REGISTRY)}
    mutants = {
        'keeper_released_before_reap': (WORKER,'if (std.meta.eql(job.tag.input.document, document)) return true;','if (std.meta.eql(job.tag.input.document, document)) return false;'),
        'stale_revision_accepted': (RUNTIME,'opened.file.revision == tag.input.revision','(opened.file.revision == tag.input.revision or true)'),
        'document_nonce_reset': (REGISTRY,'if (doc.syntax_request_gate) |gate| return gate;','if (doc.syntax_request_gate) |gate| { gate.* = .{}; return gate; }'),
        'drain_not_rearmed': (RUNTIME,'_ = self.service.beginDrain();','_ = self.service.state.notification_pending.load(.acquire);'),
        'closed_view_not_cancelled': (DISPATCH,'        owner.sweep();','        if (owner.entries.items.len == 0) owner.sweep();'),
    }
    if args.scope == "observation":
        mutants = {
            'failure_discarded': (RUNTIME, 'if (entry.gate.abandon(value.tag())) entry.outcome = value.outcome();', '_ = entry.gate.abandon(value.tag());'),
            'stale_failure_overwrites': (RUNTIME, 'if (entry.gate.abandon(value.tag())) entry.outcome = value.outcome();', '_ = entry.gate.abandon(value.tag()); entry.outcome = value.outcome();'),
            'grammar_ignored': (RUNTIME, 'or !std.meta.eql(tag.input.grammar, grammar)', 'or (!std.meta.eql(tag.input.grammar, grammar) and false)'),
            'revision_ignored': (RUNTIME, 'opened.file.revision == tag.input.revision', '(opened.file.revision == tag.input.revision or true)'),
            'retry_keeps_failure': (RUNTIME, '        value.outcome = null;', '        // 결함 주입: 이전 완료 상태 보존'),
        }
    command = ['mise','exec','--','zig','build','test-editor-parse-runtime','test-editor-parse-host','test-editor-parse-main-queue','--cache-dir',str(args.cache.resolve()),'-j2','--verbose']
    env = dict(os.environ, ZIG_LOCAL_PKG_DIR=str(deps))
    rows = []
    try:
        for name in ('control-before',*mutants,'control-after'):
            if name in mutants:
                file,before,after = mutants[name]
                if baseline[file].count(before)!=1: raise RuntimeError('ambiguous mutation '+name)
                (source/file).write_text(baseline[file].replace(before,after))
            source_hash = {file:sha(source/file) for file in baseline}
            for file in baseline:
                (out/(name+'-'+Path(file).name)).write_text((source/file).read_text())
            log = out/(name+'.log')
            with log.open('xb') as stream:
                result = subprocess.run(command,cwd=source,env=env,stdout=stream,stderr=subprocess.STDOUT,timeout=900)
            text = log.read_text()
            tests = list(dict.fromkeys(re.findall(r'info\(verbose\): [^\n]*?(\S+/test) --maru-expect-tests=(?:6|8)',text)))
            natives = re.findall(r'info\(verbose\): (\S+/maru-parse-main-queue)\s*$',text,re.M)
            if len(tests)!=2 or not natives: raise RuntimeError('missing actual executions: '+name)
            archived = {}
            for i, binary in enumerate(tests+[natives[-1]]):
                path = Path(binary)
                if not path.is_absolute(): path = source/path
                target = out/(name+'-binary-'+str(i))
                shutil.copy2(path,target)
                archived[target.name] = sha(target)
            if name in mutants:
                if result.returncode==0 or not re.search(r'FAIL \(Test(?:UnexpectedResult|ExpectedEqual)\)',text):
                    raise RuntimeError('semantic fault survived: '+name)
            elif result.returncode or (text.count('All 6 tests passed.')!=1 or text.count('All 8 tests passed.')!=1) or 'PARSE_MAIN_QUEUE accepted=2 main_thread=1 closed_document_reaped=1 late_delivery=1' not in text:
                raise RuntimeError('normal control failed: '+name)
            rows.append(dict(name=name,returncode=result.returncode,source_sha256=source_hash,binaries=archived,log_sha256=sha(log)))
            for file,content in baseline.items(): (source/file).write_text(content)
    finally:
        for file,content in baseline.items(): (source/file).write_text(content)
    if any(sha(source/name)!=h for name,h in inventory.items()): raise RuntimeError('source restoration mismatch')
    shutil.copy2(__file__,out/'review.py')
    (out/'result.json').write_text(json.dumps(dict(recorded_head=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),source_sha256=inventory,runner_sha256=sha(Path(__file__)),command=command,results=rows),indent=2)+'\n')
    print(json.dumps(rows,indent=2))
if __name__=='__main__': main()
