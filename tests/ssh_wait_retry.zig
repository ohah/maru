// Interrupt real child waits after stdout EOF. SSH callers must see the real
// exit status and release child ownership even when the host receives signals.
const std = @import("std");
const ssh = @import("ssh_upload");
extern "c" fn ualarm(u32, u32) u32;
var signals = std.atomic.Value(u32).init(0);
fn onAlarm(_: std.c.SIG) callconv(.c) void {
    _ = signals.fetchAdd(1, .monotonic);
}
fn probe(ending: []const u8, expected: c_int, interval: u32, interrupted: bool) !void {
    var old: std.posix.Sigaction = undefined;
    const action: std.posix.Sigaction = .{ .handler = .{ .handler = onAlarm }, .mask = std.posix.sigemptyset(), .flags = 0 };
    std.posix.sigaction(.ALRM, &action, &old);
    defer std.posix.sigaction(.ALRM, &old, null);
    signals.store(0, .monotonic);
    if (interrupted) _ = ualarm(50_000, interval);
    defer _ = ualarm(0, 0);
    const script = try std.fmt.allocPrint(std.testing.allocator, "printf '%s' \"$$\"; exec 1>&-; /bin/sleep 0.3; {s}", .{ending});
    defer std.testing.allocator.free(script);
    var out: []u8 = undefined;
    const code = try ssh.runArgvCapped(std.testing.allocator, &.{ "/bin/sh", "-c", script }, 1024, &out);
    _ = ualarm(0, 0);
    defer std.testing.allocator.free(out);
    const pid = try std.fmt.parseInt(std.c.pid_t, out, 10);
    // Always clean up even against the defective implementation; a late reap
    // is evidence of failure rather than a zombie left behind by the test.
    var status: c_int = 0;
    const reaped = std.c.waitpid(pid, &status, 0);
    const wait_errno = std.c._errno().*;
    const count = signals.load(.monotonic);
    std.debug.print("SSH_WAIT signals={d} reported={d} late_reap={d}\n", .{ count, code, reaped });
    try std.testing.expectEqual(expected, code);
    try std.testing.expectEqual(@as(std.c.pid_t, -1), reaped);
    try std.testing.expectEqual(@as(c_int, @backingInt(std.c.E.CHILD)), wait_errno);
    if (interrupted) try std.testing.expect(count >= if (interval == 0) @as(u32, 1) else @as(u32, 2));
}
test "SSHW1 interrupted zero exit still reaps" {
    try probe("exit 0", 0, 0, true);
}
test "SSHW2 interrupted nonzero exit" {
    try probe("exit 7", 7, 0, true);
}
test "SSHW3 repeated interrupts preserve exit 127" {
    try probe("exit 127", 127, 30_000, true);
}
test "SSHW4 signal termination stays failure" {
    try probe("kill -TERM $$", -1, 0, true);
}
test "SSHW5 repeated interrupts reap nonzero child" {
    try probe("exit 7", 7, 20_000, true);
}
test "SSHW6 uninterrupted control" {
    try probe("exit 7", 7, 0, false);
}
