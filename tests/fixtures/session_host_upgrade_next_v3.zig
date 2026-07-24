//! U3 N+1 fixture. N의 두 번째 handoff를 decode한 뒤 controlled pre-commit failure를 주입하고 N image로 rollback한다.

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
    while (offset < bytes.len) {
        const rc = c.read(fd, bytes.ptr + offset, bytes.len - offset);
        if (rc < 0) {
            if (std.posix.errno(rc) == .INTR) continue;
            return error.ReadFailed;
        }
        if (rc == 0) return error.Truncated;
        offset += @intCast(rc);
    }
    return bytes;
}

fn validateHost(allocator: std.mem.Allocator, bytes: []const u8) !void {
    var host = try session_host.handoff_codec.decodeHost(allocator, bytes);
    defer host.deinit();
    if (host.host_id != host_id_sentinel or host.upgrade_epoch != 2 or host.runtimes.len != 1 or
        host.runtimes[0].runtime_id != 0xAABBCCDD or host.runtimes[0].fd_slot != pty_slot)
        return error.IdentityMismatch;
}

fn preflight(allocator: std.mem.Allocator) !void {
    try session_host.exec_fd_set.assertExactOpen(&.{primary_state_slot});
    const bytes = try readState(allocator, primary_state_slot);
    defer allocator.free(bytes);
    try validateHost(allocator, bytes);
}

const Context = struct {
    allocator: std.mem.Allocator,
    rollback_path: []const u8,
    result_path: []const u8,
    owner_dir: []const u8,
    target_identity: session_host.staged_image.Identity,
    rollback_identity: session_host.staged_image.Identity,
};

fn rollback(ctx: Context) noreturn {
    if (c.lseek(backup_state_slot, 0, c.SEEK.SET) < 0) c._exit(131);
    const rollback_z = ctx.allocator.dupeZ(u8, ctx.rollback_path) catch c._exit(132);
    const result_z = ctx.allocator.dupeZ(u8, ctx.result_path) catch c._exit(132);
    const owner_z = ctx.allocator.dupeZ(u8, ctx.owner_dir) catch c._exit(132);
    const actual_rollback = session_host.staged_image.inspect(rollback_z) catch c._exit(131);
    if (!session_host.staged_image.identityEqual(ctx.rollback_identity, actual_rollback)) c._exit(131);
    const rollback_dev_z = std.fmt.allocPrintSentinel(ctx.allocator, "{d}", .{ctx.rollback_identity.dev}, 0) catch c._exit(132);
    const rollback_ino_z = std.fmt.allocPrintSentinel(ctx.allocator, "{d}", .{ctx.rollback_identity.ino}, 0) catch c._exit(132);
    const rollback_size_z = std.fmt.allocPrintSentinel(ctx.allocator, "{d}", .{ctx.rollback_identity.size}, 0) catch c._exit(132);
    const rollback_sha_hex = std.fmt.bytesToHex(ctx.rollback_identity.sha256, .lower);
    const rollback_sha_z = ctx.allocator.dupeZ(u8, &rollback_sha_hex) catch c._exit(132);
    const rollback_arg: [*:0]const u8 = "--rollback-target-v2";
    const argv = [_:null]?[*:0]const u8{
        rollback_z.ptr,
        rollback_arg,
        result_z.ptr,
        owner_z.ptr,
        rollback_dev_z.ptr,
        rollback_ino_z.ptr,
        rollback_size_z.ptr,
        rollback_sha_z.ptr,
    };
    _ = execv(rollback_z.ptr, &argv);
    c._exit(133);
}

fn restore(ctx: Context) !void {
    try session_host.exec_fd_set.assertExactOpen(&.{ pty_slot, primary_state_slot, backup_state_slot, owner_slot });
    const target_path = try std.fmt.allocPrintSentinel(ctx.allocator, "{s}/target-current", .{ctx.owner_dir}, 0);
    defer ctx.allocator.free(target_path);
    const actual_identity = try session_host.staged_image.inspect(target_path);
    if (!session_host.staged_image.identityEqual(ctx.target_identity, actual_identity))
        return error.StagedIdentityChanged;

    const bytes = try readState(ctx.allocator, primary_state_slot);
    defer ctx.allocator.free(bytes);
    var host = try session_host.handoff_codec.decodeHost(ctx.allocator, bytes);
    defer host.deinit();
    if (host.host_id != host_id_sentinel or host.upgrade_epoch != 2 or host.runtimes.len != 1)
        return error.IdentityMismatch;
    const runtime = &host.runtimes[0];
    var prepared = try maru.pty.PtySession.PreparedAdoption.prepareExact(
        pty_slot,
        runtime.child_pid,
        .{ .cols = runtime.cols, .rows = runtime.rows },
        .{ .dev = runtime.pty_dev, .ino = runtime.pty_ino, .rdev = runtime.pty_rdev },
    );
    defer prepared.discard();
    // 두 번째 upgrade의 controlled pre-commit failure. PTY working owner는 아직 commit되지 않았다.
    return error.InjectedSecondUpgradeFailure;
}

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var args = try init.minimal.args.iterateAllocator(allocator);
    defer args.deinit();
    _ = args.next();
    const mode_or_rollback_path = args.next() orelse return error.MissingArgument;
    if (std.mem.eql(u8, mode_or_rollback_path, "--upgrade-preflight"))
        return preflight(allocator);
    const result_path = args.next() orelse return error.MissingArgument;
    const scenario = args.next() orelse return error.MissingArgument;
    if (!std.mem.eql(u8, scenario, "two-upgrade")) return error.InvalidScenario;
    const owner_dir = args.next() orelse return error.MissingArgument;
    const target_dev = try std.fmt.parseInt(i64, args.next() orelse return error.MissingArgument, 10);
    const target_ino = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
    const target_size = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
    const sha_hex = args.next() orelse return error.MissingArgument;
    if (sha_hex.len != 64) return error.InvalidIdentity;
    var target_sha256: [32]u8 = undefined;
    const decoded = try std.fmt.hexToBytes(&target_sha256, sha_hex);
    if (decoded.len != target_sha256.len) return error.InvalidIdentity;
    const rollback_dev = try std.fmt.parseInt(i64, args.next() orelse return error.MissingArgument, 10);
    const rollback_ino = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
    const rollback_size = try std.fmt.parseInt(u64, args.next() orelse return error.MissingArgument, 10);
    const rollback_sha_hex = args.next() orelse return error.MissingArgument;
    if (rollback_sha_hex.len != 64) return error.InvalidIdentity;
    var rollback_sha256: [32]u8 = undefined;
    const rollback_decoded = try std.fmt.hexToBytes(&rollback_sha256, rollback_sha_hex);
    if (rollback_decoded.len != rollback_sha256.len or args.next() != null) return error.InvalidIdentity;
    const ctx: Context = .{
        .allocator = allocator,
        .rollback_path = mode_or_rollback_path,
        .result_path = result_path,
        .owner_dir = owner_dir,
        .target_identity = .{
            .dev = target_dev,
            .ino = target_ino,
            .size = target_size,
            .sha256 = target_sha256,
        },
        .rollback_identity = .{
            .dev = rollback_dev,
            .ino = rollback_ino,
            .size = rollback_size,
            .sha256 = rollback_sha256,
        },
    };
    restore(ctx) catch rollback(ctx);
}
