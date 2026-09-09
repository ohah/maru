//! U5 restore precommit matrix 전용 test runner.
//!
//! Target image만 strict fault prefix를 받고, canonical rollback exec는 제품과
//! 같은 `__session-host --upgrade-restore ...` argv로 다시 들어온다. 두 child
//! form 외에는 일반 Maru test runner에 위임한다.

const std = @import("std");
const simple = @import("simple_test_runner.zig");

extern fn maru_session_host_restore_precommit_child() callconv(.c) u8;

pub fn main(init: std.process.Init.Minimal) void {
    var iterator = std.process.Args.Iterator.init(init.args);
    _ = iterator.next();
    const first_z = iterator.next() orelse return simple.main(init);
    const first: []const u8 = first_z;
    if (std.mem.eql(u8, first, "--restore-activation-fault") or
        std.mem.eql(u8, first, "__session-host"))
    {
        std.process.exit(maru_session_host_restore_precommit_child());
    }
    simple.main(init);
}
