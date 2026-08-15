const std = @import("std");
const simple = @import("simple_test_runner.zig");

extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
extern var maru_cr2e_e3a2_rss_child_path: [1024]u8;
extern var maru_cr2e_e3a2_rss_child_path_len: usize;

pub fn main(init: std.process.Init.Minimal) void {
    var iterator = std.process.Args.Iterator.init(init.args);
    _ = iterator.next();
    while (iterator.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.startsWith(u8, arg, "--")) continue;
        if (maru_cr2e_e3a2_rss_child_path_len != 0) std.process.exit(122);
        const canonical = realpath(arg_z.ptr, &maru_cr2e_e3a2_rss_child_path) orelse
            std.process.exit(122);
        const len = std.mem.len(canonical);
        if (len == 0 or len >= maru_cr2e_e3a2_rss_child_path.len or
            maru_cr2e_e3a2_rss_child_path[0] != '/') std.process.exit(122);
        maru_cr2e_e3a2_rss_child_path_len = len;
    }
    if (maru_cr2e_e3a2_rss_child_path_len == 0) std.process.exit(122);
    simple.main(init);
}
