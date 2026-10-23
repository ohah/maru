#!/usr/bin/env python3
"""증분 프로토타입의 서로 다른 결함 가설을 독립 사본에서 주입하고 원본 대조군과 비교한다."""
import argparse
import fcntl
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path)
    parser.add_argument("--name", default="review-v2")
    args = parser.parse_args()
    output = args.output.resolve()
    lock = (output/".lock").open("a")
    try:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError:
        parser.error("Finish the timing run before starting fault reviews")
    if not args.name or args.name in (".","..") or Path(args.name).name != args.name: parser.error("Use a simple review directory name")
    review_root = output/args.name
    if review_root.exists(): parser.error("Review directory exists; preserve previous evidence")
    review_root.mkdir()
    source = review_root/"source"
    if source.exists(): parser.error("review-source already exists; preserve it and use a new review directory")
    subprocess.run(["rsync","-a","--exclude=.zig-cache","--exclude=zig-out","--exclude=zig-pkg",str(output/"source-1")+"/",str(source)+"/"],check=True)
    (source/"zig-pkg").symlink_to((output/"source-1/zig-pkg").resolve(),target_is_directory=True)
    path = source/"src/syntax/tree_sitter.zig"
    text = path.read_text()
    needle = "    try std.testing.expectEqualDeep(expected.items, got.items);\n}\n\ntest \"EW2 fold cache"
    extra = '''    try std.testing.expectEqualDeep(expected.items, got.items);
    if (FoldProbe.mode == 1 and p.tree != null) {
        try std.testing.expect(p.fold_probe.tree != null);
        var cursor = c.ts_tree_cursor_new(c.ts_tree_root_node(p.tree.?));
        defer c.ts_tree_cursor_delete(&cursor);
        var eligible: std.AutoHashMapUnmanaged(u64,void) = .empty;
        defer eligible.deinit(a);
        outer: while (true) {
            if (FoldProbe.candidate(p, c.ts_tree_cursor_current_node(&cursor))) |record| {
                try eligible.put(a,(@as(u64,record.lo)<<32)|record.hi,{});
            }
            if (c.ts_tree_cursor_goto_first_child(&cursor)) continue;
            while (true) {
                if (c.ts_tree_cursor_goto_next_sibling(&cursor)) break;
                if (!c.ts_tree_cursor_goto_parent(&cursor)) break :outer;
            }
        }
        try std.testing.expect(p.fold_probe.records.items.len <= eligible.count());
        const visited = p.fold_probe.nodes;
        for (0..2) |_| {
            try p.foldSpans(a, &got);
            try std.testing.expectEqualDeep(expected.items, got.items);
            try std.testing.expectEqual(visited, p.fold_probe.nodes);
        }
    }
}

test "EW2 fold cache'''
    assert text.count(needle)==1
    text = text.replace(needle,extra,1)
    needle_replace = "            p.setSource(next);\n            try foldProbeJudge(&p);"
    assert text.count(needle_replace)==1
    text=text.replace(needle_replace,"            p.setSource(next);\n            if (FoldProbe.mode == 1) try std.testing.expect(p.fold_probe.tree == null and p.fold_probe.records.items.len == 0);\n            try foldProbeJudge(&p);",1)
    needle_cases = '    for ([_]Language{.zig, .python, .dart, .swift, .markdown}) |language| {'
    assert text.count(needle_cases)==1
    samples = [("markdown", "# A\n# B\n"), ("json", '{ "a": [\n1\n],\n"b": 1\n}\n')]
    sample_code = "    for ([_]struct { language: Language, source: []const u8 }{\n"
    sample_code += "".join("        .{.language=." + language + ",.source=" + json.dumps(data) + "},\n" for language,data in samples)
    sample_code += "    }) |sample| {\n        var p = Provider.init(sample.source, sample.language, 0) orelse return error.NoProvider;\n        defer p.deinit();\n        try foldProbeJudge(&p);\n    }\n"
    text=text.replace(needle_cases,sample_code+needle_cases,1)

    extra_test = r"""
test "EW2 fold cache 정상 문서의 행 이동과 문법 영향 확장" {
    const a = std.testing.allocator;
    var source: std.ArrayList(u8) = .empty;
    defer source.deinit(a);
    for (0..500) |i| try source.print(a,"fn f{d}() void {{\n return;\n}}\n",.{i});
    var p = Provider.init(source.items,.zig,0) orelse return error.NoProvider;
    defer p.deinit();
    try foldProbeJudge(&p);
    const visited = p.fold_probe.nodes;
    try source.insertSlice(a,0,"\n");
    p.onEdit(source.items,.{.start_byte=0,.old_end_byte=0,.new_end_byte=1,.start_point=.{.row=0,.column=0},.old_end_point=.{.row=0,.column=0},.new_end_point=.{.row=1,.column=0}});
    if (FoldProbe.mode == 1) try std.testing.expect(c.ts_node_has_changes(c.ts_tree_root_node(p.fold_probe.tree.?)));
    try foldProbeJudge(&p);
    if (FoldProbe.mode == 1) try std.testing.expect(p.fold_probe.nodes-visited < p.nodeCount()/4);
    const before = "func f() {\n let x = 1\n}\nfunc g() {\n return\n}\n";
    var swift = Provider.init(before,.swift,0) orelse return error.NoProvider;
    defer swift.deinit();
    try foldProbeJudge(&swift);
    const at = std.mem.indexOf(u8,before,"let").?;
    const after = try std.mem.concat(a,u8,&.{before[0..at],"/*",before[at..]});
    defer a.free(after);
    swift.onEdit(after,.{.start_byte=@intCast(at),.old_end_byte=@intCast(at),.new_end_byte=@intCast(at+2),.start_point=stickyPoint(before,at),.old_end_point=stickyPoint(before,at),.new_end_point=stickyPoint(after,at+2)});
    try foldProbeJudge(&swift);
    const before_js = "/*\nfunction g() {\n return 1;\n}\n*/\nfunction f() {\n return 2;\n}\n";
    var js = Provider.init(before_js,.javascript,0) orelse return error.NoProvider;
    defer js.deinit();
    try foldProbeJudge(&js);
    const after_js = try std.mem.concat(a,u8,&.{"//",before_js[2..]});
    defer a.free(after_js);
    const change: Edit = .{.start_byte=0,.old_end_byte=2,.new_end_byte=2,.start_point=.{.row=0,.column=0},.old_end_point=.{.row=0,.column=2},.new_end_point=.{.row=0,.column=2}};
    js.onEdit(after_js,change);
    try foldProbeJudge(&js);
    js.onEdit(before_js,change);
    try foldProbeJudge(&js);
}
"""
    text += extra_test
    build = source/"build.zig"
    build.write_text(build.read_text().replace('run_fold_cache.addArg("--maru-expect-tests=3")','run_fold_cache.addArg("--maru-expect-tests=4")').replace('run_fold_cache.addArg("--maru-expect-passed=3")','run_fold_cache.addArg("--maru-expect-passed=4")'))
    path.write_text(text)
    probe_at = text.index("pub const FoldProbe = struct {")
    prefix, original = text[:probe_at], text[probe_at:]
    cases = [
        ("snapshot-edit","if (self.tree) |t| c.ts_tree_edit(t, e);","if (self.tree) |t| { _ = t; }","cached syntax snapshot must receive edits"),
        ("actual-range","else if (self.dirty) |r| r.lo else continue","else if (self.dirty) |r| r.lo + (std.math.maxInt(u32) - r.lo) else continue","shape-preserving edits still require the actual edit range"),
        ("syntax-range","for (0..count + 1) |i|","for (count..count + 1) |i|","parser changes may extend beyond the text edit"),
        ("byte-shift","next.lo = r.lo - e.old_end_byte + e.new_end_byte;","next.lo = r.lo;","unaffected record byte starts move with text"),
        ("start-row-shift","next.start = movePoint(r.start, e);","next.start = r.start;","unaffected folding heads move after newlines"),
        ("end-row-shift","next.end = movePoint(r.end, e);","next.end = r.end;","unaffected folding ends move after newlines"),
        ("column-shift","if (p.row == e.old_end_point.row) p.column - e.old_end_point.column + e.new_end_point.column else p.column","p.column","ending at column zero is not equivalent to ending later on that row"),
        ("dirty-extent","self.dirty = .{ .lo = lo, .hi = hi };","self.dirty = .{ .lo = lo, .hi = @min(hi,lo) };","inserted multiline bodies extend beyond the first edited byte"),
        ("stale-records","if (r.lo <= hi and r.hi >= lo) continue;","if (r.lo <= hi and r.hi >= lo and hi == std.math.maxInt(u32)) continue;","expanded syntax changes must discard stale records"),
        ("new-records","if (candidate(p, node)) |r| try self.records.append(a, r);","if (candidate(p, node)) |r| { if (r.lo == std.math.maxInt(u32)) try self.records.append(a, r); }","eligible new nodes must be collected"),
        ("descendants","if (if (full or lo == 0)","if (if (!full and lo == 0)","initial and changed subtrees must include descendants"),
        ("kind-filter","row <= sp.row or !Provider.hasKind(p.slot.fold_kinds, c.ts_node_type(node))","row <= sp.row or p.slot.fold_kinds.len == std.math.maxInt(usize)","multiline nodes are not all foldable kinds"),
        ("candidate-column-zero","if (ep.column == 0 and ep.row > sp.row) 1 else 0","if (ep.column == 0 and ep.row > sp.row) 0 else 0","column zero excludes the following logical line"),
        ("longest-head","@max(out.items[out.items.len-1].end_row, ep)","@min(out.items[out.items.len-1].end_row, ep)","a folding head must retain its longest eligible range"),
        ("retained-records","if (self.tree) |previous| {\n            var count","if (self.tree) |previous| {\n            self.records.clearRetainingCapacity();\n            var count","local updates must retain unaffected folds"),
        ("deduplication","if (n > 0 and std.meta.eql(self.records.items[n-1], r)) continue;","if (n > 0 and std.meta.eql(self.records.items[n-1], r) and n == std.math.maxInt(usize)) continue;","overlapping ranges must not grow duplicate records"),
        ("snapshot-retention","self.tree = next;","self.tree = null;\n        c.ts_tree_delete(next);","an incremental cache must retain its classified snapshot"),
        ("native-lifetime","if (self.tree) |t| c.ts_tree_delete(t);","if (self.tree) |t| { _ = t; }","C snapshot references must be released"),
        ("whole-replacement",None,None,"whole-source replacement invalidates cached coordinates"),
        ("output-clear","out.clearRetainingCapacity();","out.ensureTotalCapacity(a,out.items.len) catch {};","repeated queries replace rather than append outputs"),
    ]
    reports = review_root/"reports"
    reports.mkdir()
    def run(name):
        target=reports/(name+".log")
        with target.open("wb") as log:
            result=subprocess.run(["mise","exec","--","zig","build","test-editor-fold-cache","-Doptimize=ReleaseFast","-j2"],cwd=source,stdout=log,stderr=subprocess.STDOUT)
        log=target.read_text()
        return result.returncode,log
    results=[]
    try:
        code,_=run("control-before")
        if code: raise RuntimeError("Unmodified review control failed")
        for index,(name,old,new,hypothesis) in enumerate(cases,1):
            changed=original
            if name=="whole-replacement":
                needle="pub fn setSourceBudgeted(self: *Provider, source: []const u8, budget_ns: u64) ParseStatus {\n        self.fold_probe.deinit();"
                assert prefix.count(needle)==1
                mutated_prefix=prefix.replace(needle,needle.replace("self.fold_probe.deinit();","self.fold_probe.mapped = false;"),1)
            else:
                mutated_prefix=prefix
                if name=="candidate-column-zero":
                    # candidate 함수 안의 조건만 바꿔 출력 변환과 독립적으로 공격한다.
                    assert changed.count(old)==1
                assert changed.count(old)==1,(name,changed.count(old))
                changed=changed.replace(old,new,1)
            path.write_text(mutated_prefix+changed)
            code,log=run(f"{index:02}-{name}")
            status="runtime-detected" if code and ("FAIL (" in log or "panic:" in log) else "compile-error" if code else "survived"
            if name in ("column-shift","deduplication") and not code: status="equivalent-control-pass"
            result=dict(review=index,hypothesis=hypothesis,mutation=name,original_sha256=hashlib.sha256(text.encode()).hexdigest(),expected="runtime rejects the injected defect",actual=status)
            (reports/f"{index:02}-{name}.json").write_text(json.dumps(result,indent=2)+"\n")
            results.append(result)
            print(index,name,status,flush=True)
    finally:
        path.write_text(text)
        (review_root/"results.json").write_text(json.dumps(results,indent=2)+"\n")
    code,_=run("control-after")
    if code: raise RuntimeError("Restored review control failed")
    unexpected=[r for r in results if r["actual"] not in ("runtime-detected","equivalent-control-pass")]
    if unexpected: raise RuntimeError("Unresolved fault hypotheses; inspect results.json")


if __name__ == "__main__":
    main()
