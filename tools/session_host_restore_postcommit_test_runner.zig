//! U5 restore postcommit matrix 전용 test runner.
//!
//! Target image의 strict postcommit fault prefix만 child entry로 보낸다. 이
//! artifact는 postcommit 행의 rollback image이기도 하므로 canonical rollback
//! argv가 한 번이라도 실행되면 전용 exit code로 즉시 실패한다.

const std = @import("std");
const simple = @import("simple_test_runner.zig");

extern fn maru_session_host_restore_postcommit_child() callconv(.c) u8;

pub fn main(init: std.process.Init.Minimal) void {
    var iterator = std.process.Args.Iterator.init(init.args);
    _ = iterator.next();
    const first_z = iterator.next() orelse return simple.main(init);
    const first: []const u8 = first_z;
    if (std.mem.eql(u8, first, "--restore-activation-postcommit-fault"))
        std.process.exit(maru_session_host_restore_postcommit_child());
    if (std.mem.eql(u8, first, "__session-host")) std.process.exit(94);
    simple.main(init);
}
