const std = @import("std");
const simple = @import("simple_test_runner.zig");
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;
extern var maru_cr0b_gui_bootstrap_child_path: [1024]u8;
extern var maru_cr0b_gui_bootstrap_child_path_len: usize;
extern var maru_cr0b_daemon_bootstrap_child_path: [1024]u8;
extern var maru_cr0b_daemon_bootstrap_child_path_len: usize;

pub fn main(init: std.process.Init.Minimal) void {
    var iterator = std.process.Args.Iterator.init(init.args);
    _ = iterator.next();
    var index: usize = 0;
    while (iterator.next()) |arg_z| {
        const arg: []const u8 = arg_z;
        if (std.mem.startsWith(u8, arg, "--")) continue;
        const target = if (index == 0) &maru_cr0b_gui_bootstrap_child_path else if (index == 1)
            &maru_cr0b_daemon_bootstrap_child_path else std.process.exit(122);
        const canonical = realpath(arg_z.ptr, target) orelse std.process.exit(122);
        const len = std.mem.len(canonical);
        if (len == 0 or len >= target.len or target[0] != '/') std.process.exit(122);
        if (index == 0) maru_cr0b_gui_bootstrap_child_path_len = len else maru_cr0b_daemon_bootstrap_child_path_len = len;
        index += 1;
    }
    if (index != 2) std.process.exit(122);
    const gui_path = maru_cr0b_gui_bootstrap_child_path[0..maru_cr0b_gui_bootstrap_child_path_len];
    const daemon_path = maru_cr0b_daemon_bootstrap_child_path[0..maru_cr0b_daemon_bootstrap_child_path_len];
    if (std.mem.eql(u8, gui_path, daemon_path)) std.process.exit(122);
    simple.main(init);
}
