// Sweep allocation failures through real local children and a private fake SSH
// executable. Partial replies must never look successful or leave zombies.
const std = @import("std");
const ssh = @import("ssh_upload");
const Kind = enum { small, large, empty, remote_script, remote_capped };
fn run(kind: Kind, a: std.mem.Allocator, out: *[]u8) !c_int {
    return switch (kind) {
        .small => ssh.runArgvCapped(a, &.{ "/bin/sh", "-c", "printf 0123456789abcdef" }, 100_000, out),
        .large => ssh.runArgvCapped(a, &.{ "/usr/bin/head", "-c", "32769", "/dev/zero" }, 100_000, out),
        .empty => ssh.runArgvCapped(a, &.{"/usr/bin/true"}, 100_000, out),
        .remote_script => ssh.runRemoteScript(a, "/unused", "unused", "ignored", &.{}, null, out),
        .remote_capped => ssh.runRemoteCapped(a, "/unused", "unused", "ignored", &.{}, 100_000, out),
    };
}
fn verify(kind: Kind, out: []const u8) !void {
    switch (kind) {
        .large => {
            try std.testing.expectEqual(@as(usize, 32769), out.len);
            for (out) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
        },
        .empty => try std.testing.expectEqual(@as(usize, 0), out.len),
        else => try std.testing.expectEqualStrings("0123456789abcdef", out),
    }
}
fn sweep(kind: Kind) !void {
    var failures: usize = 0;
    var successes: usize = 0;
    for (0..32) |index| {
        // Keep resizing from bypassing a fail_index, including in ReleaseFast.
        var stable = std.testing.allocator;
        var vtable = stable.vtable.*;
        vtable.resize = std.mem.Allocator.noResize;
        vtable.remap = std.mem.Allocator.noRemap;
        stable.vtable = &vtable;
        var failing = std.testing.FailingAllocator.init(stable, .{ .fail_index = index });
        var marker: [1]u8 = .{42};
        var out: []u8 = &marker;
        const outcome = run(kind, failing.allocator(), &out);
        // The runner owns all test children. Any child available to reap here
        // means the product returned without settling its child ownership.
        var status: c_int = 0;
        const late = std.c.waitpid(-1, &status, 0);
        const wait_errno = std.c._errno().*;
        if (outcome) |code| {
            defer failing.allocator().free(out);
            try std.testing.expectEqual(@as(c_int, 0), code);
            try verify(kind, out);
            successes += 1;
        } else |err| {
            try std.testing.expect(err == error.OutOfMemory);
            try std.testing.expect(out.ptr == &marker);
            failures += 1;
        }
        try std.testing.expectEqual(@as(std.c.pid_t, -1), late);
        try std.testing.expectEqual(@as(c_int, @backingInt(std.c.E.CHILD)), wait_errno);
    }
    std.debug.print("SSH_OOM {s} errors={d} healthy={d}\n", .{ @tagName(kind), failures, successes });
    try std.testing.expect(failures > 0 and successes > 0);
}
test "SSHO1 short output allocation failures" {
    try sweep(.small);
}
test "SSHO2 multi-chunk allocation failures" {
    try sweep(.large);
}
test "SSHO3 empty output preparation failures" {
    try sweep(.empty);
}
test "SSHO4 remote script errors propagate" {
    try sweep(.remote_script);
}
test "SSHO5 remote capped errors propagate" {
    try sweep(.remote_capped);
}
