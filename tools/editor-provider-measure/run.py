#!/usr/bin/env python3
"""제품은 수정하지 않고 구문 편집의 native 파싱과 변경 범위 계산을 분리하는 진단 사본."""
from pathlib import Path
import argparse, hashlib, importlib.util, json, sys
ROOT=Path(__file__).resolve().parents[2]
spec=importlib.util.spec_from_file_location('point',ROOT/'tools/editor-fold-points/run.py')
point=importlib.util.module_from_spec(spec)
# 가져오는 도구가 우리 CLI의 플래그를 소비하거나 baseline을 켜지 못하게 한다.
saved_argv=sys.argv
try:
    sys.argv=saved_argv[:1]
    spec.loader.exec_module(point)
finally:
    sys.argv=saved_argv
base=point.base
STAGES=('on_edit','reset','sticky_edit','tree_edit','note_changed','changed_ranges','tree_release')
def setup(repo,output,deps,mode):
    source=point.setup(repo,output,deps,mode)
    p=source/'src/syntax/tree_sitter.zig';text=p.read_text()
    text+='\npub var provider_probe_ns: [7]i128 = @splat(0);\npub var provider_probe_calls: [7]u64 = @splat(0);\npub var provider_native_calls: u64 = 0;\nfn providerProbeNow() i128 { return std.Io.Clock.awake.now(std.testing.io).nanoseconds; }\n'
    def wrap(text,anchor,i):
        indent=anchor[:len(anchor)-len(anchor.lstrip())]
        return base.once(text,anchor,indent+'{\n'+indent+f'    const start = providerProbeNow();\n'+anchor+'\n'+indent+f'    provider_probe_ns[{i}] += providerProbeNow() - start;\n'+indent+f'    provider_probe_calls[{i}] += 1;\n'+indent+'}')
    anchor='    pub fn onEditBudgeted(self: *Provider, source: []const u8, e: Edit, budget_ns: u64) void {\n'
    text=base.once(text,anchor,anchor+'        const provider_start = providerProbeNow();\n        provider_probe_calls[0] += 1;\n        defer provider_probe_ns[0] += providerProbeNow() - provider_start;\n')
    begin=text.index(anchor);end=text.index('\n    /// 판 문서의 줄 수',begin)
    before,part,after=text[:begin],text[begin:end],text[end:]
    part=wrap(part,'        c.ts_parser_reset(self.parser);',1)
    part=wrap(part,'        self.sticky_summary.edit(&edit);',2)
    part=wrap(part,'        c.ts_tree_edit(old_tree, &edit);',3)
    text=before+part+after
    anchor='    fn noteChanged(self: *Provider, old: *c.TSTree, new: *c.TSTree) void {\n'
    text=base.once(text,anchor,anchor+'        const note_start = providerProbeNow();\n        provider_probe_calls[4] += 1;\n        defer provider_probe_ns[4] += providerProbeNow() - note_start;\n')
    anchor='        const ranges = c.ts_tree_get_changed_ranges(old, new, &count);'
    text=base.once(text,anchor,'        const ranges_start = providerProbeNow();\n'+anchor+'\n        provider_probe_ns[5] += providerProbeNow() - ranges_start;\n        provider_probe_calls[5] += 1;')
    text=wrap(text,'                if (old != t) c.ts_tree_delete(old);',6)
    anchor='        const next = c.ts_parser_parse_with_options(self.parser, old_tree, input, opts);'
    text=base.once(text,anchor,'        provider_native_calls += 1;\n'+anchor)
    p.write_text(text)
    p=source/'src/platform/macos/app_session/editor/mod.zig';text=p.read_text()
    anchor='        frame_probe_ns = @splat(0);'
    text=base.once(text,anchor,anchor+'\n        syntax_color.syntax.provider_probe_ns = @splat(0);\n        syntax_color.syntax.provider_probe_calls = @splat(0);\n        syntax_color.syntax.provider_native_calls = 0;')
    fields=' '.join(name+'={d} '+name+'_calls={d}' for name in STAGES)
    values=', '.join('syntax_color.syntax.provider_probe_ns['+str(i)+'], syntax_color.syntax.provider_probe_calls['+str(i)+']' for i in range(7))
    anchor='        const live_doc = term.rt.editorDocument().opened.?;'
    text=base.once(text,anchor,'        std.debug.print("PROVIDER key={d} '+fields+' native_calls={d}\\n", .{i, '+values+', syntax_color.syntax.provider_native_calls});\n'+anchor)
    p.write_text(text)
    p=output/'setup-1.json';info=json.loads(p.read_text())
    for name in ['src/syntax/tree_sitter.zig','src/platform/macos/app_session/editor/mod.zig']:
        info['instrumented_sha256'][name]=hashlib.sha256((source/name).read_bytes()).hexdigest()
    info['comparison_target']='provider-edit-attribution'
    info.pop('comparison_variant',None)
    for name,value in info['original_sha256'].items():
        raw=(repo/name).read_bytes()
        if hashlib.sha256(raw).hexdigest()!=value:raise RuntimeError('Original source changed during setup: '+name)
        saved=output/'original-product'/name
        saved.parent.mkdir(parents=True,exist_ok=True)
        saved.write_bytes(raw)
    info['provider_stages']=STAGES
    info['provider_scope']='Single-thread private fixture; on_edit includes native parse and note_changed; note_changed includes changed_ranges; do not add nested stages; no product optimization or HID proof'
    p.write_text(json.dumps(info,indent=2)+'\n')
    return source
def main():
    # 기존 호스트의 다른 workload는 이 계측의 호출 수 계약으로 판정하지 않는다.
    parser=argparse.ArgumentParser(add_help=False)
    parser.add_argument('--modes',choices=('1',),default='1')
    parser.add_argument('--workloads',default='typing,shared')
    parser.add_argument('--prefix',choices=('run','verify'),default='run')
    parser.add_argument('--verify-each-edit',type=int,choices=(0,1),default=0)
    parser.add_argument('--repetitions',type=int,default=3)
    parser.add_argument('--output',type=Path)
    parser.add_argument('--baseline',action='store_true')
    parser.add_argument('--baseline-ref')
    args,remaining=parser.parse_known_args()
    if args.baseline or args.baseline_ref is not None:
        parser.error('This is attribution, not a before/after comparison')
    workloads=args.workloads.split(',')
    if not workloads or len(workloads)!=len(set(workloads)) or not set(workloads)<= {'typing','shared'}:
        parser.error('Use typing and/or shared once each')
    if args.repetitions<0:parser.error('Use nonnegative repetitions')
    if (args.prefix=='verify')!=bool(args.verify_each_edit):parser.error('Use verify with the per-input oracle and run without it')
    if args.output is not None:
        # 성공한 원시 실행을 재실행으로 덮으면 초기/후속 표본을 구분할 수 없다.
        names=('flat-3000.zig','flat-15000.zig','flat-50000.zig','real-build.zig','real-host.swift')
        for rep in range(args.repetitions):
            for name in names:
                for work in workloads:
                    if (args.output/f'{args.prefix}-{rep}-1-{name}-{work}.log').exists():
                        parser.error('Raw log already exists; use a new output directory')
    sys.argv=[sys.argv[0],*remaining,'--modes','1','--workloads',args.workloads,'--prefix',args.prefix,'--verify-each-edit',str(args.verify_each_edit),'--repetitions',str(args.repetitions)]
    if args.output is not None:sys.argv.extend(['--output',str(args.output)])
    base.setup=setup
    base.main()

if __name__=='__main__':main()
