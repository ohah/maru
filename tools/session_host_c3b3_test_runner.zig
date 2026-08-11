const std = @import("std");
const simple = @import("simple_test_runner.zig");
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

pub fn main(init: std.process.Init.Minimal) void {
    var iterator = std.process.Args.Iterator.init(init.args);
    _ = iterator.next();
    if (iterator.next()) |first_z| {
        const first: []const u8 = first_z;
        const stage_prefix = "--maru-c3b3-death-stage=";
        if (std.mem.startsWith(u8, first, stage_prefix)) {
            const fd_z = iterator.next() orelse std.process.exit(122);
            if (iterator.next() != null or
                !std.mem.eql(u8, fd_z, "--maru-c3b3-marker-fd=198")) std.process.exit(122);
            const stage = first[stage_prefix.len..];
            if (!std.mem.eql(u8, stage, "post-admission") and
                !std.mem.eql(u8, stage, "post-callback") and
                !std.mem.eql(u8, stage, "client-post-callback") and
                !std.mem.eql(u8, stage, "first-byte-hang") and
                !std.mem.eql(u8, stage, "prefix-pipe-hang") and
                !std.mem.eql(u8, stage, "eof-alive") and
                !std.mem.eql(u8, stage, "trailing-marker-hang") and
                !std.mem.eql(u8, stage, "exact-cap-exit") and
                !std.mem.eql(u8, stage, "signal-exit")) std.process.exit(122);
            simple.maru_c3b3_death_stage_raw = if (std.mem.eql(u8, stage, "post-admission")) 1 else if (std.mem.eql(u8, stage, "post-callback")) 2 else if (std.mem.eql(u8, stage, "client-post-callback")) 3 else if (std.mem.eql(u8, stage, "first-byte-hang")) 4 else if (std.mem.eql(u8, stage, "prefix-pipe-hang")) 5 else if (std.mem.eql(u8, stage, "eof-alive")) 6 else if (std.mem.eql(u8, stage, "trailing-marker-hang")) 7 else if (std.mem.eql(u8, stage, "exact-cap-exit")) 8 else 9;
        } else if (!std.mem.startsWith(u8, first, "--maru-expect-tests=")) {
            const count_arg = iterator.next() orelse std.process.exit(122);
            if (iterator.next() != null or first.len == 0 or first.len >= simple.maru_c3b3_death_child_path.len or
                std.mem.indexOfScalar(u8, first, 0) != null or
                !std.mem.eql(u8, count_arg, "--maru-expect-tests=5")) std.process.exit(122);
            const canonical = realpath(first_z.ptr, &simple.maru_c3b3_death_child_path) orelse std.process.exit(122);
            const canonical_len = std.mem.len(canonical);
            if (canonical_len == 0 or canonical_len >= simple.maru_c3b3_death_child_path.len or
                simple.maru_c3b3_death_child_path[0] != '/') std.process.exit(122);
            simple.maru_c3b3_death_child_path_len = canonical_len;
        }
    }
    simple.main(init);
}
