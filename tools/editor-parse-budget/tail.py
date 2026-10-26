#!/usr/bin/env python3
"""긴 재개 호출에서 마지막 progress 검사와 실제 C 반환 사이의 구간을 따로 관측한다."""
import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess

import contract
from run import ROOT, inventory, sha, write
from verify import verify


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('dataset',type=Path)
    parser.add_argument('--expected-head',required=True)
    parser.add_argument('--output',required=True,type=Path)
    args=parser.parse_args()
    base,out=args.dataset.resolve(),args.output.resolve()
    contract.require(not out.exists() and out!=ROOT and ROOT not in out.parents,'Use a new external output')
    verify(base,args.expected_head)
    original=inventory(base/'source-1')
    source=out/'source'
    shutil.copytree(base/'source-1',source,copy_function=os.link,symlinks=True,
                    ignore=shutil.ignore_patterns('.zig-cache','zig-pkg','zig-out','.git'))
    (source/'zig-pkg').symlink_to((base/'source-1/zig-pkg').resolve(),target_is_directory=True)
    path=source/'src/syntax/tree_sitter.zig'
    text=path.read_text()
    old='        const next = c.ts_parser_parse_with_options(self.parser, old_tree, input, opts);'
    contract.require(text.count(old)==1,'Ambiguous native call')
    text=text.replace(old,'''        budget_tail = .{ .start = monotonicNs(), .start_cpu = budgetCpuNs() };
'''+old+'''
        const tail_end = monotonicNs();
        const tail_cpu = budgetCpuNs();
        const last = if (budget_tail.calls > 0) budget_tail.last else budget_tail.start;
        std.debug.print("BUDGET_TAIL budget={d} native_ns={d} callbacks={d} last_elapsed={d} unchecked_tail={d} last_before_deadline={d} cancelled={d} done={d} max_gap={d} gap_cpu={d} native_cpu={d}\\n", .{
            budget_ns, tail_end - budget_tail.start, budget_tail.calls, last - budget_tail.start,
            tail_end - last, @intFromBool(last < ctx.deadline_ns), budget_tail.cancelled, @intFromBool(next != null),
            budget_tail.max_gap, budget_tail.gap_cpu, tail_cpu - budget_tail.start_cpu,
        });''')
    old='        return monotonicNs() >= ctx.deadline_ns;'
    contract.require(text.count(old)==1,'Ambiguous budget check')
    text=text.replace(old,'''        const current = monotonicNs();
        const current_cpu = budgetCpuNs();
        const previous = if (budget_tail.calls > 0) budget_tail.last else budget_tail.start;
        const previous_cpu = if (budget_tail.calls > 0) budget_tail.last_cpu else budget_tail.start_cpu;
        if (current - previous > budget_tail.max_gap) {
            budget_tail.max_gap = current - previous;
            budget_tail.gap_cpu = current_cpu - previous_cpu;
        }
        budget_tail.last = current;
        budget_tail.last_cpu = current_cpu;
        budget_tail.calls += 1;
        const expired = current >= ctx.deadline_ns;
        budget_tail.cancelled += @intFromBool(expired);
        return expired;''')
    text+='''
var budget_tail: struct { start:u64=0, start_cpu:u64=0, last:u64=0, last_cpu:u64=0,
    calls:u64=0, cancelled:u64=0, max_gap:u64=0, gap_cpu:u64=0 } = .{};
// 이 진단은 macOS 개발 도구다. 중립 제품 코드에 POSIX 시계를 넣지 않는다.
fn budgetCpuNs() u64 {
    var value: std.c.timespec = undefined;
    if (std.c.clock_gettime(.THREAD_CPUTIME_ID, &value) != 0) @panic("thread CPU clock failed");
    return @as(u64, @intCast(value.sec)) * std.time.ns_per_s + @as(u64, @intCast(value.nsec));
}
'''
    path.unlink()
    path.write_text(text)
    write(out/'source.json',dict(head=args.expected_head,original=original,instrumented=inventory(source),
          reader_sha256=sha(Path(__file__)),scope='Separate callback-tail diagnostic; does not alter budget decision or force expiry; timings excluded from performance populations'))
    env={k:v for k,v in os.environ.items() if not k.startswith('MARU_')}
    env.update(MARU_BUDGET_FILE=str(base/'fixtures/flat-50000.zig'),MARU_BUDGET_NS='4000000',MARU_BUDGET_ACCURACY='0')
    cache=source/'.zig-cache'
    cache.mkdir()
    with (cache/'measurement-active.lock').open('ab'):
        command=['mise','exec','--','zig','build','test-native-budget-measure','-Doptimize=ReleaseFast','-j2','--verbose']
        with (out/'build.log').open('xb') as stream:
            done=subprocess.run(command,cwd=source,env=env,stdout=stream,stderr=subprocess.STDOUT)
        contract.require(done.returncode==0,'Tail diagnostic failed; log preserved')
        text=(out/'build.log').read_text()
        contract.require('All 4 tests passed.' in text,'Missing actual diagnostic controls')
        # 시간 구간 내부의 진단 로그는 이 별도 실행에서만 존재한다.
        tails=[contract.fields(row) for row in re.findall(r'BUDGET_TAIL ([^\n]+)',text)]
        tails=[row for row in tails if row['budget']==4000000]
        contract.require(bool(tails),'Missing budgeted native returns')
        for row in tails:
            contract.require(row['native_ns']==row['last_elapsed']+row['unchecked_tail'],'Unbalanced native tail')
            contract.require(row['cancelled']<=row['callbacks'] and row['done'] in (0,1),'Invalid callback result')
        cleaned='\n'.join(line for line in text.splitlines() if 'BUDGET_TAIL ' not in line)
        parsed=contract.measure(cleaned,4000000,0)
        binary=re.findall(r'(\./\.zig-cache/o/[0-9a-f]+/test) --maru-expect-tests=4',text)[-1]
        shutil.copy2(source/binary,out/'archived-test')
        contract.require(inventory(base/'source-1')==original,'Original source changed')
        write(out/'result.json',dict(complete=True,head=args.expected_head,tails=tails,edits=parsed['edits'],
              command=command,exit=done.returncode,log_sha256=sha(out/'build.log'),binary_sha256=sha(out/'archived-test'),
              scope='C return versus last actual callback only; no attribution to a particular private C function and no performance distribution'))
        print('BUDGET_TAIL_DIAGNOSTIC_PASS',len(tails),flush=True)


if __name__=='__main__':
    main()
