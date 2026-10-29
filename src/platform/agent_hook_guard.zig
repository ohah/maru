//! One wall-clock budget for the complete installed hook, including stdin and writer children.
const std = @import("std");
const builtin = @import("builtin");

pub const budget_ms = 1500;

pub fn run(io: std.Io, args: []const []const u8) !void {
    if (args.len != 1 or args[0].len == 0 or std.mem.indexOfScalar(u8, args[0], 0) != null)
        return error.InvalidArguments;
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.UnsupportedPlatform;
    const deadline = std.Io.Clock.awake.now(io).nanoseconds + budget_ms * std.time.ns_per_ms;
    // Only the script is in argv. Provider payload remains on inherited stdin.
    // pgid=0 creates a private group so timeout also stops a blocked record/receipt child.
    var child = try std.process.spawn(io, .{
        .argv = &.{ "/bin/sh", "-c", args[0] },
        .pgid = 0,
        .stdin = .inherit,
        // Codex SessionStart deliberately emits an attribution receipt on stdout.
        .stdout = .inherit,
        .stderr = .ignore,
    });
    defer {
        if (child.id) |pid| _ = std.c.kill(-pid, std.c.SIG.KILL);
        child.kill(io);
    }
    while (true) {
        var status: c_int = 0;
        const waited = std.c.waitpid(child.id.?, &status, std.c.W.NOHANG);
        if (waited == child.id.?) {
            child.id = null; // Reaped here; inherited/ignored stdio has no owned pipe handles.
            return;
        }
        if (waited < 0 and std.c._errno().* != @backingInt(std.posix.E.INTR))
            return error.WaitFailed;
        if (std.Io.Clock.awake.now(io).nanoseconds >= deadline) return;
        try std.Io.sleep(io, .fromMilliseconds(2), .awake);
    }
}
