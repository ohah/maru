//! U3 new-image fixture. Frozen old fixture가 만든 inherited PTY와 handoff를 target-side prepared adoption으로 복구한다.

const std = @import("std");
const maru = @import("maru");
const session_host = @import("session_host");
const c = std.c;
extern "c" fn execv(path: [*:0]const u8, argv: [*:null]const ?[*:0]const u8) c_int;

const pty_slot: c.fd_t = 40;
const primary_state_slot: c.fd_t = 41;
const backup_state_slot: c.fd_t = 42;
const owner_slot: c.fd_t = 43;
const host_id_sentinel: u128 = 0x102030405060708090A0B0C0D0E0F001;

fn readState(allocator: std.mem.Allocator, fd: c.fd_t) ![]u8 {
    if (c.lseek(fd, 0, c.SEEK.SET) < 0) return error.ReadFailed;
    var stat: std.posix.Stat = undefined;
    if (c.fstat(fd, &stat) != 0 or stat.size < 0) return error.InvalidState;
    const len = std.math.cast(usize, stat.size) orelse return error.InvalidState;
    const bytes = try allocator.alloc(u8, len);
    errdefer allocator.free(bytes);
    var offset: usize = 0;
    while (offset < len) {
        const rc = c.read(fd, bytes.ptr + offset, len - offset);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) return error.Truncated;
        offset += @intCast(rc);
    }
    return bytes;
}

fn preflight(allocator: std.mem.Allocator, scenario: []const u8) !void {
    try session_host.exec_fd_set.assertExactOpen(&.{primary_state_slot});
    const bytes = try readState(allocator, primary_state_slot);
    defer allocator.free(bytes);
    var host = try session_host.handoff_codec.decodeHost(allocator, bytes);
    defer host.deinit();
    if (host.host_id != host_id_sentinel or host.runtimes.len != 1 or
        host.runtimes[0].runtime_id != 0xAABBCCDD or host.runtimes[0].surface_id != 7 or
        host.runtimes[0].fd_slot != pty_slot)
        return error.IdentityMismatch;
    if (std.mem.eql(u8, scenario, "target-preflight-fail"))
        return error.InjectedPreflightFailure;
}

fn writeResult(path: []const u8, text: []const u8, allocator: std.mem.Allocator) !void {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const fd = c.open(path_z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.OpenFailed;
    defer _ = c.close(fd);
    var offset: usize = 0;
    while (offset < text.len) {
        const rc = c.write(fd, text.ptr + offset, text.len - offset);
        if (rc <= 0) return error.WriteFailed;
        offset += @intCast(rc);
    }
}

const Context = struct {
    allocator: std.mem.Allocator,
    old_path: []const u8,
    result_path: []const u8,
    scenario: []const u8,
    owner_dir: []const u8,
    target_identity: session_host.staged_image.Identity,
};

fn rollback(ctx: Context) noreturn {
    // Target-created state는 전혀 commit하지 않았으므로 backup offset만 되감아 frozen old image로 돌아간다.
    if (c.lseek(backup_state_slot, 0, c.SEEK.SET) < 0) c._exit(121);
    const old_z = ctx.allocator.dupeZ(u8, ctx.old_path) catch c._exit(122);
    const result_z = ctx.allocator.dupeZ(u8, ctx.result_path) catch c._exit(122);
    const owner_z = std.fmt.allocPrintSentinel(ctx.allocator, "{s}", .{ctx.owner_dir}, 0) catch c._exit(122);
    const rollback_arg: [*:0]const u8 = "--rollback-target";
    const argv = [_:null]?[*:0]const u8{ old_z.ptr, rollback_arg, result_z.ptr, owner_z.ptr };
    _ = execv(old_z.ptr, &argv);
    // rollback exec 실패는 재귀 재시도하지 않는 fail-stop이다.
    c._exit(123);
}

fn restore(ctx: Context) !void {
    const allocator = ctx.allocator;
    try session_host.exec_fd_set.assertExactOpen(&.{ pty_slot, primary_state_slot, backup_state_slot, owner_slot });
    const bytes = try readState(allocator, primary_state_slot);
    defer allocator.free(bytes);
    var host = try session_host.handoff_codec.decodeHost(allocator, bytes);
    defer host.deinit();
    if (host.runtimes.len != 1 or host.host_id != host_id_sentinel or
        host.runtimes[0].runtime_id != 0xAABBCCDD or host.runtimes[0].surface_id != 7 or
        host.runtimes[0].fd_slot != pty_slot) return error.IdentityMismatch;

    const runtime = &host.runtimes[0];
    const staged_target_path = try std.fmt.allocPrintSentinel(allocator, "{s}/target-current", .{ctx.owner_dir}, 0);
    defer allocator.free(staged_target_path);
    const staged_target_identity = try session_host.staged_image.inspect(staged_target_path);
    if (!session_host.staged_image.identityEqual(ctx.target_identity, staged_target_identity))
        return error.StagedIdentityChanged;
    if (std.mem.eql(u8, ctx.scenario, "target-adopt-fail")) return error.InjectedAdoptionFailure;
    var prepared = try maru.pty.PtySession.PreparedAdoption.prepareExact(
        pty_slot,
        runtime.child_pid,
        .{ .cols = runtime.cols, .rows = runtime.rows },
        .{ .dev = runtime.pty_dev, .ino = runtime.pty_ino, .rdev = runtime.pty_rdev },
    );
    defer prepared.discard();
    if (std.mem.eql(u8, ctx.scenario, "target-rollback")) return error.InjectedPreCommitFailure;
    var owner = try session_host.owner_lease.OwnerLease.adoptInherited(owner_slot);
    defer owner.deinit();
    const owner_z = try std.fmt.allocPrintSentinel(allocator, "{s}/owner.lock", .{ctx.owner_dir}, 0);
    defer allocator.free(owner_z);
    try std.testing.expectError(error.AlreadyOwned, session_host.owner_lease.OwnerLease.acquire(owner_z));
    var session = prepared.commit();
    defer session.deinit();
    _ = c.close(pty_slot);
    _ = c.close(primary_state_slot);
    _ = c.close(backup_state_slot);
    _ = c.close(owner_slot);
    if (!session.upgradeEligible()) c._exit(124);
    serveCommitted(ctx, &session, runtime, &host, staged_target_identity) catch c._exit(124);
    c._exit(0);
}

/// Irreversible PTY ownership commit 뒤의 오류는 old-image rollback으로 돌아가지 않는다.
fn serveCommitted(
    ctx: Context,
    session: *maru.pty.PtySession,
    runtime: *session_host.handoff_codec.RuntimeState,
    host: *session_host.handoff_codec.HostState,
    staged_target_identity: session_host.staged_image.Identity,
) !void {
    const allocator = ctx.allocator;
    const self_path = try std.fmt.allocPrintSentinel(allocator, "{s}/self-current", .{ctx.owner_dir}, 0);
    defer allocator.free(self_path);
    const target_path = try std.fmt.allocPrintSentinel(allocator, "{s}/target-current", .{ctx.owner_dir}, 0);
    defer allocator.free(target_path);
    const previous_path = try std.fmt.allocPrintSentinel(allocator, "{s}/self-previous", .{ctx.owner_dir}, 0);
    defer allocator.free(previous_path);
    const owner_dir_z = try std.fmt.allocPrintSentinel(allocator, "{s}", .{ctx.owner_dir}, 0);
    defer allocator.free(owner_dir_z);
    const inject_promotion = std.mem.eql(u8, ctx.scenario, "target-promotion-fail");
    const promotion = session_host.staged_image.promote(
        owner_dir_z,
        target_path,
        staged_target_identity,
        self_path,
        previous_path,
        inject_promotion,
    );
    // promotion은 commit 이후 bookkeeping이다. 실패하면 runtime을 rollback/종료하지 않고 다음 upgrade capability만 철회한다.
    var capability: []const u8 = "enabled";
    if (promotion) |_| {} else |_| {
        capability = "withdrawn";
    }

    try session.writeInput("hello\n");
    var exit_ok = false;
    while (!exit_ok) {
        const event = try session.readEvent(allocator);
        defer event.deinit(allocator);
        switch (event) {
            .output => |output| try runtime.core.write(output),
            .exited => |status| switch (status) {
                .exited => |code| {
                    if (code != 23) return error.WrongExit;
                    exit_ok = true;
                },
                else => return error.WrongExit,
            },
        }
    }
    if (try session.reapIfExited() != null) return error.DoubleReap;
    const dump = try runtime.core.dumpUtf8(allocator);
    defer allocator.free(dump);
    if (std.mem.indexOf(u8, dump, "MIGRATED:hello") == null or runtime.core.parser != .ground)
        return error.ParserContinuationFailed;

    const result = try std.fmt.allocPrint(
        allocator,
        "host_pid={d}\nchild_pid={d}\nhost_id={x}\nruntime_id={x}\nowner_lease=ok\nparser=ground\nexit=23\ninput_output=ok\nupgrade_capability={s}\n",
        .{ c.getpid(), runtime.child_pid, host.host_id, runtime.runtime_id, capability },
    );
    defer allocator.free(result);
    try writeResult(ctx.result_path, result, allocator);
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const mode_or_old_path = args.next() orelse return error.MissingArgument;
    if (std.mem.eql(u8, mode_or_old_path, "--upgrade-preflight"))
        return preflight(allocator, args.next() orelse return error.MissingArgument);
    const result_path = args.next() orelse return error.MissingArgument;
    const scenario = args.next() orelse return error.MissingArgument;
    const owner_dir = args.next() orelse return error.MissingArgument;
    const target_dev = try std.fmt.parseInt(i64, args.next() orelse return error.MissingArgument, 10);
    const target_ino = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
    const target_size = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
    var target_sha256: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&target_sha256, args.next() orelse return error.MissingArgument);
    const ctx: Context = .{
        .allocator = allocator,
        .old_path = mode_or_old_path,
        .result_path = result_path,
        .scenario = scenario,
        .owner_dir = owner_dir,
        .target_identity = .{
            .dev = target_dev,
            .ino = target_ino,
            .size = target_size,
            .sha256 = target_sha256,
        },
    };
    restore(ctx) catch rollback(ctx);
}
