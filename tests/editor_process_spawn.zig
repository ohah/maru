//! Real macOS process contracts shared by LSP and formatter launch migration.
//! The C oracle observes group/FD state before shell startup can hide inheritance.
const std = @import("std");
const c = std.c;
const lsp = @import("lsp_process");
const fmt = @import("format_process");
const t = std.testing;
const budget_ms = 10_000;
const empty_env = [_:null]?[*:0]const u8{};

fn probe(storage: *[4096]u8) ![:0]const u8 {
    const n = try std.Io.Dir.cwd().realPathFile(t.io, @import("editor_process_probe").path, storage[0..4095]);
    storage[n] = 0;
    return storage[0..n :0];
}
fn fdCount() usize {
    var n: usize = 0;
    for (0..1024) |fd| if (c.fcntl(@intCast(fd), c.F.GETFD) >= 0) {
        n += 1;
    };
    return n;
}
fn sleep() void {
    std.Io.sleep(t.io, std.Io.Duration.fromMilliseconds(2), .awake) catch {};
}
fn collect(p: *lsp.Process) ![]u8 {
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(t.allocator);
    for (0..budget_ms / 2) |_| {
        if (try lsp.readInto(p, t.allocator, &output, 1 << 20) == .eof) return output.toOwnedSlice(t.allocator);
        sleep();
    }
    return error.NoEof;
}
fn lspOutput(exe: []const u8, args: []const []const u8, cwd: []const u8, env: ?[*:null]const ?[*:0]const u8) ![]u8 {
    var p = try lsp.spawn(t.allocator, exe, args, cwd, env);
    defer lsp.stopNow(&p, t.allocator);
    return collect(&p);
}
fn lspFailure(exe: []const u8, args: []const []const u8, cwd: []const u8) !void {
    const before = fdCount();
    if (lsp.spawn(t.allocator, exe, args, cwd, &empty_env)) |unexpected| {
        var p = unexpected;
        lsp.stopNow(&p, t.allocator);
        return error.ExpectedCreationFailure;
    } else |err| try t.expectEqual(error.Spawn, err);
    try t.expectEqual(before, fdCount());
}
fn formatted(req: fmt.Request) !*fmt.Result {
    const id = fmt.start(req) orelse return error.StartFailed;
    for (0..budget_ms / 2) |_| {
        if (fmt.take(id)) |result| {
            if (!fmt.waitIdleForTest(budget_ms)) {
                result.deinit();
                return error.WorkerNotIdle;
            }
            return result;
        }
        sleep();
    }
    fmt.abandon(id);
    _ = fmt.waitIdleForTest(budget_ms);
    return error.NoResult;
}
fn fmtFailure(exe: []const u8, cwd: []const u8) !void {
    const before = fdCount();
    const r = try formatted(.{ .argv = &.{exe}, .cwd = cwd, .envp = &empty_env, .stdin = "" });
    defer r.deinit();
    try t.expect(r.outcome == .spawn_failed);
    try t.expectEqual(before, fdCount());
}
fn expectGroup(bytes: []const u8) !void {
    var fields = std.mem.splitScalar(u8, std.mem.trim(u8, bytes, "\n"), '|');
    const pid = try std.fmt.parseInt(c.pid_t, fields.next().?, 10);
    const group = try std.fmt.parseInt(c.pid_t, fields.next().?, 10);
    try t.expect(pid > 0 and pid == group and fields.next() == null);
}
fn withClosed(mask: u3, comptime body: fn () anyerror!void) !void {
    var saved: [3]c.fd_t = @splat(-1);
    defer for (saved, 0..) |fd, i| if (fd >= 0) {
        _ = c.dup2(fd, @intCast(i));
        _ = c.close(fd);
    };
    for (&saved, 0..) |*fd, i| if (mask & (@as(u3, 1) << @intCast(i)) != 0) {
        fd.* = c.fcntl(@intCast(i), c.F.DUPFD_CLOEXEC, @as(c_int, 64));
        try t.expect(fd.* >= 64);
    };
    for (saved, 0..) |fd, i| if (fd >= 0) {
        _ = c.close(@intCast(i));
    };
    try body();
}
fn lspClosed() !void {
    var storage: [4096]u8 = undefined;
    const exe = try probe(&storage);
    const bytes = try lspOutput(exe, &.{"streams"}, "/", &empty_env);
    defer t.allocator.free(bytes);
    try t.expectEqualStrings("out", bytes);
}
fn fmtClosed() !void {
    var storage: [4096]u8 = undefined;
    const exe = try probe(&storage);
    const r = try formatted(.{ .argv = &.{ exe, "streams" }, .cwd = "/", .envp = &empty_env, .stdin = "" });
    defer r.deinit();
    try t.expect(r.outcome == .exited);
    try t.expectEqualStrings("out", r.outcome.exited.stdout);
    try t.expectEqualStrings("err", r.outcome.exited.stderr);
}
fn highDescriptor(comptime formatter: bool) !void {
    var storage: [4096]u8 = undefined;
    const exe = try probe(&storage);
    const fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(c.mode_t, 0));
    try t.expect(fd >= 0);
    defer _ = c.close(fd);
    const high = c.fcntl(fd, c.F.DUPFD, @as(c_int, 512));
    try t.expect(high >= 512);
    defer _ = c.close(high);
    const saved = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{ .cur = 256, .max = saved.max });
    defer std.posix.setrlimit(.NOFILE, saved) catch {};
    var number_storage: [32]u8 = undefined;
    const number = try std.fmt.bufPrint(&number_storage, "{d}", .{high});
    if (formatter) {
        const r = try formatted(.{ .argv = &.{ exe, "fd", number }, .cwd = "/", .envp = &empty_env, .stdin = "" });
        defer r.deinit();
        try t.expect(r.outcome == .exited);
        try t.expectEqualStrings("closed\n", r.outcome.exited.stdout);
    } else {
        const bytes = try lspOutput(exe, &.{ "fd", number }, "/", &empty_env);
        defer t.allocator.free(bytes);
        try t.expectEqualStrings("closed\n", bytes);
    }
}
fn context(comptime formatter: bool) !void {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var root_storage: [4096]u8 = undefined;
    const root = root_storage[0..try tmp.dir.realPath(t.io, &root_storage)];
    var before_storage: [4096]u8 = undefined;
    const before_len = try std.Io.Dir.cwd().realPath(t.io, &before_storage);
    var storage: [4096]u8 = undefined;
    const exe = try probe(&storage);
    const env = [_:null]?[*:0]const u8{"EDITOR_SPAWN_PROBE=present"};
    var expected_storage: [8192]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_storage, "argument with spaces|{s}|present\n", .{root});
    if (formatter) {
        const r = try formatted(.{ .argv = &.{ exe, "context", "argument with spaces" }, .cwd = root, .envp = &env, .stdin = "" });
        defer r.deinit();
        try t.expect(r.outcome == .exited);
        try t.expectEqualStrings(expected, r.outcome.exited.stdout);
    } else {
        const bytes = try lspOutput(exe, &.{ "context", "argument with spaces" }, root, &env);
        defer t.allocator.free(bytes);
        try t.expectEqualStrings(expected, bytes);
    }
    var after_storage: [4096]u8 = undefined;
    const after_len = try std.Io.Dir.cwd().realPath(t.io, &after_storage);
    try t.expectEqualStrings(before_storage[0..before_len], after_storage[0..after_len]);
}

test "EGS01 LSP starts as group leader" {
    std.debug.print("editor_spawn_mode mode={s}\n", .{@tagName(@import("builtin").mode)});
    var storage: [4096]u8 = undefined;
    const bytes = try lspOutput(try probe(&storage), &.{"group"}, "/", &empty_env);
    defer t.allocator.free(bytes);
    try expectGroup(bytes);
}
test "EGS02 LSP preserves argv environment and held cwd without changing parent" {
    try context(false);
}
test "EGS03 LSP missing executable creates no owner or FD leak" {
    try lspFailure("/nonexistent/maru-lsp", &.{}, "/");
}
test "EGS04 LSP missing cwd is synchronous failure" {
    try lspFailure("/bin/pwd", &.{}, "/nonexistent/maru-root");
}
test "EGS05 LSP executable permission denial is creation failure" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "denied", .data = "#!/bin/sh\nexit 0\n" });
    var path: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(t.io, &path);
    const exe = try std.fmt.bufPrint(path[n..], "/denied", .{});
    _ = exe;
    try lspFailure(path[0 .. n + 7], &.{}, "/");
}
test "EGS06 LSP rejects embedded NUL instead of launching a truncated command" {
    try lspFailure("/bin/echo", &.{"ok\x00truncated"}, "/");
}
test "EGS07 LSP closes high ambient FD above reduced soft limit" {
    try highDescriptor(false);
}
test "EGS08 LSP closed stdin mappings remain intact" {
    try withClosed(1, lspClosed);
}
test "EGS09 LSP closed stdout and stderr cannot overwrite mapping sources" {
    try withClosed(6, lspClosed);
}
fn allocationPath(allocator: std.mem.Allocator) !void {
    const before = fdCount();
    if (lsp.spawn(allocator, "/usr/bin/true", &.{ "extra", "arguments" }, "/", &empty_env)) |result| {
        var p = result;
        lsp.stopNow(&p, allocator);
    } else |err| {
        try t.expectEqual(before, fdCount());
        return err;
    }
    try t.expectEqual(before, fdCount());
}
test "EGS10 LSP every argv allocation failure revokes temporary memory and descriptors" {
    const Backing = struct {
        const vtable: std.mem.Allocator.VTable = .{
            .alloc = t.allocator.vtable.alloc,
            .resize = std.mem.Allocator.noResize,
            .remap = std.mem.Allocator.noRemap,
            .free = t.allocator.vtable.free,
        };
    };
    try t.checkAllAllocationFailures(.{ .ptr = t.allocator.ptr, .vtable = &Backing.vtable }, allocationPath, .{});
}
test "EGS11 formatter starts as group leader" {
    var storage: [4096]u8 = undefined;
    const r = try formatted(.{ .argv = &.{ try probe(&storage), "group" }, .cwd = "/", .envp = &empty_env, .stdin = "" });
    defer r.deinit();
    try t.expect(r.outcome == .exited);
    try expectGroup(r.outcome.exited.stdout);
}
test "EGS12 formatter preserves stdout and stderr separately" {
    try fmtClosed();
}
test "EGS13 formatter missing executable is creation failure" {
    try fmtFailure("/nonexistent/maru-formatter", "/");
}
test "EGS14 formatter missing cwd is creation failure" {
    try fmtFailure("/bin/pwd", "/nonexistent/maru-root");
}
test "EGS15 formatter real exit 126 remains an executed program outcome" {
    var storage: [4096]u8 = undefined;
    const r = try formatted(.{ .argv = &.{ try probe(&storage), "exit", "126" }, .cwd = "/", .envp = &empty_env, .stdin = "" });
    defer r.deinit();
    try t.expect(r.outcome == .exited);
    try t.expectEqual(@as(?u8, 126), r.outcome.exited.code);
}
test "EGS16 formatter preserves argv environment and held cwd without changing parent" {
    try context(true);
}
test "EGS17 formatter closes high ambient FD above reduced soft limit" {
    try highDescriptor(true);
}
test "EGS18 formatter all closed stdio slots cannot corrupt source mappings" {
    try withClosed(7, fmtClosed);
}
test "EGS19 formatter FD exhaustion cleans partial creation" {
    const saved = try std.posix.getrlimit(.NOFILE);
    try std.posix.setrlimit(.NOFILE, .{ .cur = 128, .max = saved.max });
    defer std.posix.setrlimit(.NOFILE, saved) catch {};
    var held: [128]c.fd_t = undefined;
    var n: usize = 0;
    defer for (held[0..n]) |fd| {
        _ = c.close(fd);
    };
    while (n < held.len) {
        const fd = c.open("/dev/null", .{ .ACCMODE = .RDONLY, .CLOEXEC = true }, @as(c.mode_t, 0));
        if (fd < 0) break;
        held[n] = fd;
        n += 1;
    }
    try t.expect(n >= 9);
    // Six pipe ends and cwd consume seven slots; source pinning must fail and unwind.
    for (0..8) |_| {
        n -= 1;
        _ = c.close(held[n]);
    }
    const before = fdCount();
    const r = try formatted(.{ .argv = &.{"/usr/bin/true"}, .cwd = "/", .envp = &empty_env, .stdin = "" });
    defer r.deinit();
    try t.expect(r.outcome == .spawn_failed);
    try t.expectEqual(before, fdCount());
}
test "EGS20 formatter timeout retains group cleanup and returns no successful body" {
    var storage: [4096]u8 = undefined;
    const before = fdCount();
    const r = try formatted(.{ .argv = &.{ try probe(&storage), "sleep" }, .cwd = "/", .envp = &empty_env, .stdin = "", .timeout_ms = 50 });
    defer r.deinit();
    try t.expect(r.outcome == .timeout);
    try t.expectEqual(before, fdCount());
}
