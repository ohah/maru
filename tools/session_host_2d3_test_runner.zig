const std = @import("std");
const simple = @import("simple_test_runner.zig");
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

pub fn main(init: std.process.Init.Minimal) void {
    var iterator = std.process.Args.Iterator.init(init.args);
    _ = iterator.next();
    const stage_prefix = "--maru-2d3-proof-stage=";
    var child_path: ?[:0]const u8 = null;
    var stage_seen = false;
    while (iterator.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.startsWith(u8, arg, stage_prefix)) {
            if (stage_seen) std.process.exit(122);
            stage_seen = true;
            const stage = arg[stage_prefix.len..];
            if (!std.mem.eql(u8, stage, "pre-callback") and
                !std.mem.eql(u8, stage, "post-callback") and
                !std.mem.eql(u8, stage, "callback-reentry")) std.process.exit(122);
            const fd_z = iterator.next() orelse std.process.exit(122);
            if (!std.mem.eql(u8, fd_z, "--maru-2d3-marker-fd=198")) std.process.exit(122);
            continue;
        }
        if (!std.mem.startsWith(u8, arg, "--") and child_path == null)
            child_path = arg_z;
    }
    if (!stage_seen) if (child_path) |path_z| {
        const path: []const u8 = path_z;
        if (path.len == 0 or path.len >= simple.maru_c3b3_death_child_path.len) std.process.exit(122);
        const canonical = realpath(path_z.ptr, &simple.maru_c3b3_death_child_path) orelse std.process.exit(122);
        const canonical_len = std.mem.len(canonical);
        if (canonical_len == 0 or canonical_len >= simple.maru_c3b3_death_child_path.len or
            simple.maru_c3b3_death_child_path[0] != '/') std.process.exit(122);
        simple.maru_c3b3_death_child_path_len = canonical_len;
    };
    simple.main(init);
}
