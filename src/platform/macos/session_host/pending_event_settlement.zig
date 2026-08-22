//! 하나의 immutable pending generation event를 원자적으로 settle한다.
//!
//! coordinator는 하나의 final-address owner를 admit하고 닫힌 Client effect를 적용한 뒤, sealed receipt로
//! registry/quarantine/pin과 source ownership을 release한다. 중간 상태는 public authority가 아니며,
//! admission 이후 proof loss가 발생하면 추측 복구 없이 프로세스를 종료한다.

const contract = @import("pending_event_settlement_contract.zig");
const std = @import("std");
const builtin = @import("builtin");
const lifetime = @import("runtime_lifetime_owner.zig");
const pending_owner = @import("pending_event_owner.zig");
const attachment_mod = @import("generation_attachment.zig");
const process_seal = @import("process_seal_service.zig");
const prepared_types = @import("runtime_event_prepared_types.zig");
const pending_control = @import("runtime_pending_control.zig");
const maru = @import("maru");
const client_mod = @import("client.zig");
const framing = @import("framing.zig");
const host_adapter_mod = @import("host_adapter.zig");
const generation_transport = @import("generation_transport.zig");
const ProofLossRunnerChannel = if (builtin.is_test) struct {
    extern var maru_c3b3_death_stage_raw: u8;
    extern var maru_c3b3_death_child_path: [1024]u8;
    extern var maru_c3b3_death_child_path_len: usize;
} else struct {};
extern "c" fn getdtablesize() c_int;

const SettlementScratchRole = enum(u8) {
    lease,
    effect_out,
    release_out,
    effect_permit,
    release_permit,
    pending_permit,
    begun,
    lifetime_owner,
    pending_owner,
    attachment,
};
const SettlementAliasKind = enum(u8) { exact, left, right };
const SettlementAliasInjection = struct { role: SettlementScratchRole, kind: SettlementAliasKind };
var settlement_alias_injection: ?SettlementAliasInjection = null;

const ForkRejectedSettlementProjection = struct {
    lifetime_state_raw: u8,
    lifetime_operation_kind_raw: u8,
    lifetime_next_operation: u64,
    lifetime_active_operation: u64,
    lifetime_operation_seal: contract.Digest,
    pending_lifecycle_raw: u8,
    pending_next_attempt: u64,
    pending_active_attempt: u64,
    pending_operation_incarnation: u64,
    pending_release_digest: contract.Digest,
    pending_disposition_digest: contract.Digest,
    attachment_self_addr: usize,
    attachment_lifecycle_raw: u8,
    attachment_event_generation_mirror: u64,
    attachment_event_owner_digest: contract.Digest,
    attachment_correlation_digest: contract.Digest,
    client: attachment_mod.testing_api.ForkRejectedClientProjection,
    payload_free_count: usize,
};

fn forkProjectionDigest(value: anytype) contract.Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(std.mem.asBytes(&value));
    var digest: contract.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn forkProjectionContainsPointer(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .@"fn" => true,
        .array => |info| forkProjectionContainsPointer(info.child),
        .optional => |info| forkProjectionContainsPointer(info.child),
        .error_union => |info| forkProjectionContainsPointer(info.payload),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field|
                if (forkProjectionContainsPointer(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field|
                if (forkProjectionContainsPointer(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

/// fork 뒤 제품 권위를 열지 않고 child-local 메모리의 변경 0만 비교한다.
fn forkRejectedSettlementProjection(
    lifetime_owner: *const lifetime.RuntimeLifetimeOwner,
    pending: *const pending_owner.PendingEventOwner,
    attachment: *const attachment_mod.GenerationAttachment,
    adapter: *const host_adapter_mod.HostAdapter,
    payload_free_count: usize,
) ForkRejectedSettlementProjection {
    if (!builtin.is_test) unreachable;
    return .{
        .lifetime_state_raw = lifetime_owner.state_raw,
        .lifetime_operation_kind_raw = lifetime_owner.operation_kind_raw,
        .lifetime_next_operation = lifetime_owner.next_operation_incarnation,
        .lifetime_active_operation = lifetime_owner.active_operation_incarnation,
        .lifetime_operation_seal = lifetime_owner.operation_seal,
        .pending_lifecycle_raw = pending.lifecycle_raw,
        .pending_next_attempt = pending.next_attempt,
        .pending_active_attempt = pending.active_attempt,
        .pending_operation_incarnation = pending.operation_incarnation,
        .pending_release_digest = forkProjectionDigest(pending.release_receipt),
        .pending_disposition_digest = forkProjectionDigest(pending.settlement_disposition),
        .attachment_self_addr = attachment.self_addr,
        .attachment_lifecycle_raw = @intFromEnum(attachment.lifecycle),
        .attachment_event_generation_mirror = attachment.event_generation_mirror,
        .attachment_event_owner_digest = forkProjectionDigest(attachment.event_owner),
        .attachment_correlation_digest = forkProjectionDigest(attachment.transport.event_correlation),
        .client = attachment_mod.testing_api.forkRejectedClientProjection(adapter),
        .payload_free_count = payload_free_count,
    };
}

const SettlementDeathStage = enum(u8) {
    post_admission,
    post_callback,
    client_post_callback,
    first_byte_hang,
    prefix_pipe_hang,
    eof_alive,
    trailing_marker_hang,
    exact_cap_exit,
    signal_exit,
};
const SettlementDeathMarker = enum(u8) {
    invalid_owner = 0x31,
    projection_equal = 0x32,
    free0 = 0x33,
    callback0 = 0x34,
    ready = 0x41,
    admitted = 0x42,
    tombstones = 0x43,
    free_enter = 0x44,
    exact_payload = 0x45,
    free_return = 0x46,
    drift = 0x47,
    proof_loss_enter = 0x48,
    callback = 0x49,
    completion = 0x4A,
};
const settlement_death_marker_fd: std.c.fd_t = 198;

fn writeSettlementDeathMarker(fd: std.c.fd_t, marker: SettlementDeathMarker) void {
    const byte: [1]u8 = .{@intFromEnum(marker)};
    while (true) {
        const written = std.c.write(fd, &byte, byte.len);
        if (written == 1) return;
        if (written < 0 and std.posix.errno(written) == .INTR) continue;
        std.c._exit(126);
    }
}

fn settlementMonotonicMs() u64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) std.c._exit(126);
    return @as(u64, @intCast(ts.sec)) * 1000 +
        @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn killAndReapSettlementChild(child: std.c.pid_t) !c_int {
    const killed = std.c.kill(child, std.c.SIG.KILL);
    if (killed != 0 and std.posix.errno(killed) != .SRCH) return error.TestUnexpectedResult;
    var status: c_int = 0;
    while (true) {
        const waited = std.c.waitpid(child, &status, 0);
        if (waited == child) return status;
        if (waited < 0 and std.posix.errno(waited) == .INTR) continue;
        return error.TestUnexpectedResult;
    }
}

const SettlementChildObservation = struct {
    transcript: [16]u8 = [_]u8{0} ** 16,
    transcript_len: usize = 0,
    status: c_int = 0,
    eof: bool = false,
    eof_before_deadline: bool = false,
    reaped: bool = false,
    killed_at_deadline: bool = false,
    trailing_marker_seen: bool = false,
};

fn observeSettlementDeathChild(stage: SettlementDeathStage) !SettlementChildObservation {
    if (ProofLossRunnerChannel.maru_c3b3_death_child_path_len == 0 or
        ProofLossRunnerChannel.maru_c3b3_death_child_path_len >= ProofLossRunnerChannel.maru_c3b3_death_child_path.len)
        return error.TestUnexpectedResult;
    var marker_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&marker_pipe));
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = std.c.close(marker_pipe[0]);
        if (std.c.dup2(marker_pipe[1], settlement_death_marker_fd) < 0) std.c._exit(126);
        if (marker_pipe[1] != settlement_death_marker_fd) _ = std.c.close(marker_pipe[1]);
        const flags = std.c.fcntl(settlement_death_marker_fd, std.c.F.GETFD);
        if (flags < 0 or std.c.fcntl(
            settlement_death_marker_fd,
            std.c.F.SETFD,
            flags & ~@as(c_int, std.c.FD_CLOEXEC),
        ) < 0) std.c._exit(126);
        const max_fd = getdtablesize();
        var inherited_fd: c_int = 3;
        while (inherited_fd < max_fd) : (inherited_fd += 1) {
            if (inherited_fd != settlement_death_marker_fd) _ = std.c.close(inherited_fd);
        }
        const stage_arg: [*:0]const u8 = switch (stage) {
            .post_admission => "--maru-c3b3-death-stage=post-admission",
            .post_callback => "--maru-c3b3-death-stage=post-callback",
            .client_post_callback => "--maru-c3b3-death-stage=client-post-callback",
            .first_byte_hang => "--maru-c3b3-death-stage=first-byte-hang",
            .prefix_pipe_hang => "--maru-c3b3-death-stage=prefix-pipe-hang",
            .eof_alive => "--maru-c3b3-death-stage=eof-alive",
            .trailing_marker_hang => "--maru-c3b3-death-stage=trailing-marker-hang",
            .exact_cap_exit => "--maru-c3b3-death-stage=exact-cap-exit",
            .signal_exit => "--maru-c3b3-death-stage=signal-exit",
        };
        const path: [*:0]const u8 = @ptrCast(&ProofLossRunnerChannel.maru_c3b3_death_child_path);
        const argv = [_:null]?[*:0]const u8{
            path,
            stage_arg,
            "--maru-c3b3-marker-fd=198",
        };
        const child_env = [_:null]?[*:0]const u8{};
        _ = std.c.execve(path, &argv, &child_env);
        std.c._exit(127);
    }
    _ = std.c.close(marker_pipe[1]);
    const read_flags = std.c.fcntl(marker_pipe[0], std.c.F.GETFL);
    const nonblocking: c_int = @bitCast(std.posix.O{ .NONBLOCK = true });
    if (read_flags < 0 or std.c.fcntl(marker_pipe[0], std.c.F.SETFL, read_flags | nonblocking) < 0) {
        _ = killAndReapSettlementChild(child) catch {};
        _ = std.c.close(marker_pipe[0]);
        return error.TestUnexpectedResult;
    }
    var observation: SettlementChildObservation = .{};
    const deadline = settlementMonotonicMs() + 2000;
    while (!observation.reaped or !observation.eof) {
        while (!observation.eof and observation.transcript_len < observation.transcript.len) {
            const count = std.c.read(
                marker_pipe[0],
                observation.transcript[observation.transcript_len..].ptr,
                observation.transcript.len - observation.transcript_len,
            );
            if (count > 0) {
                observation.transcript_len += @intCast(count);
                continue;
            }
            if (count == 0) {
                observation.eof = true;
                observation.eof_before_deadline = settlementMonotonicMs() < deadline;
                break;
            }
            const read_errno = std.posix.errno(count);
            if (read_errno == .INTR) continue;
            if (read_errno != .AGAIN) {
                _ = killAndReapSettlementChild(child) catch {};
                _ = std.c.close(marker_pipe[0]);
                return error.TestUnexpectedResult;
            }
            break;
        }
        if (observation.transcript_len == observation.transcript.len and !observation.eof) {
            var trailing: [1]u8 = undefined;
            const count = std.c.read(marker_pipe[0], &trailing, trailing.len);
            if (count > 0) {
                observation.trailing_marker_seen = true;
                continue;
            }
            if (count == 0) {
                observation.eof = true;
                observation.eof_before_deadline = settlementMonotonicMs() < deadline;
            } else if (std.posix.errno(count) != .AGAIN and std.posix.errno(count) != .INTR) {
                _ = killAndReapSettlementChild(child) catch {};
                _ = std.c.close(marker_pipe[0]);
                return error.TestUnexpectedResult;
            }
        }
        if (!observation.reaped) {
            const waited = std.c.waitpid(child, &observation.status, std.c.W.NOHANG);
            if (waited == child) observation.reaped = true else if (waited < 0 and std.posix.errno(waited) != .INTR) {
                _ = killAndReapSettlementChild(child) catch {};
                _ = std.c.close(marker_pipe[0]);
                return error.TestUnexpectedResult;
            }
        }
        if (observation.reaped and observation.eof) break;
        const now = settlementMonotonicMs();
        if (now >= deadline) {
            observation.eof_before_deadline = observation.eof_before_deadline or observation.eof;
            if (!observation.reaped) {
                observation.status = try killAndReapSettlementChild(child);
                observation.reaped = true;
                observation.killed_at_deadline = true;
            }
            while (!observation.eof) {
                if (observation.transcript_len == observation.transcript.len) {
                    var trailing: [1]u8 = undefined;
                    const count = std.c.read(marker_pipe[0], &trailing, trailing.len);
                    if (count > 0) {
                        observation.trailing_marker_seen = true;
                        continue;
                    }
                    if (count == 0) {
                        observation.eof = true;
                        continue;
                    }
                    if (std.posix.errno(count) == .INTR) continue;
                    return error.TestUnexpectedResult;
                }
                const count = std.c.read(
                    marker_pipe[0],
                    observation.transcript[observation.transcript_len..].ptr,
                    observation.transcript.len - observation.transcript_len,
                );
                if (count > 0) {
                    observation.transcript_len += @intCast(count);
                    continue;
                }
                if (count == 0) observation.eof = true else if (std.posix.errno(count) == .INTR) continue else return error.TestUnexpectedResult;
            }
            _ = std.c.close(marker_pipe[0]);
            return observation;
        }
        var poll_fds = [_]std.c.pollfd{.{ .fd = marker_pipe[0], .events = std.c.POLL.IN | std.c.POLL.HUP, .revents = 0 }};
        const remaining: c_int = @intCast(@min(deadline - now, 25));
        const polled = std.c.poll(&poll_fds, 1, remaining);
        if (polled < 0 and std.posix.errno(polled) != .INTR) {
            if (!observation.reaped) _ = killAndReapSettlementChild(child) catch {};
            _ = std.c.close(marker_pipe[0]);
            return error.TestUnexpectedResult;
        }
    }
    _ = std.c.close(marker_pipe[0]);
    return observation;
}

fn runSettlementDeathChild(stage: SettlementDeathStage, expected: []const u8) !void {
    const observation = try observeSettlementDeathChild(stage);
    try std.testing.expect(!observation.killed_at_deadline);
    try std.testing.expect(!observation.trailing_marker_seen);
    try std.testing.expect(observation.eof);
    try std.testing.expect(observation.reaped);
    try std.testing.expectEqualSlices(u8, expected, observation.transcript[0..observation.transcript_len]);
    const unsigned: u32 = @bitCast(observation.status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned));
    try std.testing.expectEqual(@as(u8, 86), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
}

fn expectSettlementDeadlineKill(observation: SettlementChildObservation) !void {
    try std.testing.expect(observation.killed_at_deadline);
    try std.testing.expect(observation.reaped);
    try std.testing.expect(observation.eof);
    const unsigned: u32 = @bitCast(observation.status);
    try std.testing.expect(std.c.W.IFSIGNALED(unsigned));
    try std.testing.expectEqual(std.c.SIG.KILL, std.c.W.TERMSIG(unsigned));
}

const RejectedChildArgv = struct {
    first: [*:0]const u8,
    second: ?[*:0]const u8 = null,
    third: ?[*:0]const u8 = null,
    non_fifo_marker: bool = false,
};

fn verifyRejectedSettlementChild(case: RejectedChildArgv) !void {
    var marker_pipe: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&marker_pipe));
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        _ = std.c.close(marker_pipe[0]);
        const marker_source = if (case.non_fifo_marker) blk: {
            _ = std.c.close(marker_pipe[1]);
            const null_fd = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY });
            if (null_fd < 0) std.c._exit(126);
            break :blk null_fd;
        } else marker_pipe[1];
        if (std.c.dup2(marker_source, settlement_death_marker_fd) < 0) std.c._exit(126);
        if (marker_source != settlement_death_marker_fd) _ = std.c.close(marker_source);
        const flags = std.c.fcntl(settlement_death_marker_fd, std.c.F.GETFD);
        if (flags < 0 or std.c.fcntl(settlement_death_marker_fd, std.c.F.SETFD, @as(c_int, 0)) < 0)
            std.c._exit(126);
        const max_fd = getdtablesize();
        var inherited_fd: c_int = 3;
        while (inherited_fd < max_fd) : (inherited_fd += 1) {
            if (inherited_fd != settlement_death_marker_fd) _ = std.c.close(inherited_fd);
        }
        const path: [*:0]const u8 = @ptrCast(&ProofLossRunnerChannel.maru_c3b3_death_child_path);
        const argv = [_:null]?[*:0]const u8{ path, case.first, case.second, case.third };
        const child_env = [_:null]?[*:0]const u8{};
        _ = std.c.execve(path, &argv, &child_env);
        std.c._exit(127);
    }
    _ = std.c.close(marker_pipe[1]);
    var status: c_int = 0;
    const deadline = settlementMonotonicMs() + 2000;
    while (true) {
        const waited = std.c.waitpid(child, &status, std.c.W.NOHANG);
        if (waited == child) break;
        if (waited < 0 and std.posix.errno(waited) != .INTR) {
            _ = std.c.close(marker_pipe[0]);
            return error.TestUnexpectedResult;
        }
        if (settlementMonotonicMs() >= deadline) {
            _ = killAndReapSettlementChild(child) catch {};
            _ = std.c.close(marker_pipe[0]);
            return error.TestUnexpectedResult;
        }
        var delay = [_]std.c.pollfd{};
        _ = std.c.poll(&delay, 0, 1);
    }
    const unsigned: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned));
    try std.testing.expectEqual(@as(u8, 122), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
    var forbidden: [1]u8 = undefined;
    const count = std.c.read(marker_pipe[0], &forbidden, forbidden.len);
    _ = std.c.close(marker_pipe[0]);
    try std.testing.expectEqual(@as(isize, 0), count);
}

fn verifyRejectedSettlementArgvMatrix() !void {
    const stage = "--maru-c3b3-death-stage=post-admission";
    const fd = "--maru-c3b3-marker-fd=198";
    const cases = [_]RejectedChildArgv{
        .{ .first = stage },
        .{ .first = stage, .second = fd, .third = "extra" },
        .{ .first = fd, .second = stage },
        .{ .first = "--maru-c3b3-death-stage=unknown", .second = fd },
        .{ .first = "--maru-c3b3-death-stage=Post-Admission", .second = fd },
        .{ .first = stage, .second = "--maru-c3b3-marker-fd=+198" },
        .{ .first = stage, .second = "--maru-c3b3-marker-fd= 198" },
        .{ .first = stage, .second = "--maru-c3b3-marker-fd=0198" },
        .{ .first = stage, .second = "--maru-c3b3-marker-fd=19x" },
        .{ .first = stage, .second = "--maru-c3b3-marker-fd=999999999999999999999999" },
        .{ .first = stage, .second = "--maru-c3b3-marker-fd=197" },
    };
    try std.testing.expectEqual(@as(usize, 11), cases.len);
    inline for (cases) |case| try verifyRejectedSettlementChild(case);
    try verifyRejectedSettlementChild(.{
        .first = stage,
        .second = fd,
        .non_fifo_marker = true,
    });
}

const CallbackForwardingAllocator = struct {
    parent: std.mem.Allocator,
    target_addr: usize = 0,
    target_len: usize = 0,
    context: ?*anyopaque = null,
    callback: ?*const fn (*anyopaque) void = null,
    armed: bool = false,
    fired: bool = false,
    invocation_count: usize = 0,
    death_marker_fd: ?std.c.fd_t = null,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }
    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, ra);
    }
    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) bool {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.resize(self.parent.ptr, memory, alignment, len, ra);
    }
    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, len: usize, ra: usize) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        return self.parent.vtable.remap(self.parent.ptr, memory, alignment, len, ra);
    }
    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *@This() = @ptrCast(@alignCast(ctx));
        if (self.armed and @intFromPtr(memory.ptr) == self.target_addr and memory.len == self.target_len) {
            self.armed = false;
            self.fired = true;
            self.invocation_count += 1;
            if (self.death_marker_fd) |fd| {
                writeSettlementDeathMarker(fd, .free_enter);
                writeSettlementDeathMarker(fd, .exact_payload);
            }
            if (self.callback) |callback| callback(self.context orelse @panic("settlement callback context missing"));
        }
        self.parent.vtable.free(self.parent.ptr, memory, alignment, ra);
        if (self.death_marker_fd != null and self.fired)
            writeSettlementDeathMarker(self.death_marker_fd.?, .free_return);
    }
};

const ActualSettlementOptions = struct {
    contention_count: usize = 0,
    reentry: bool = false,
    preserve_first_reason: bool = false,
    preserve_sibling_outbound: bool = false,
    pre_admission_fork: bool = false,
    death_stage: ?SettlementDeathStage = null,
};
const SettlementReentryContext = struct {
    lifetime_owner: *lifetime.RuntimeLifetimeOwner,
    pending: *pending_owner.PendingEventOwner,
    attachment: *attachment_mod.GenerationAttachment,
    correlation: generation_transport.EventCorrelation,
    effect: prepared_types.EffectRequest,
    sibling_lifetime_owner: ?*lifetime.RuntimeLifetimeOwner = null,
    sibling_pending: ?*pending_owner.PendingEventOwner = null,
    sibling_attachment: ?*attachment_mod.GenerationAttachment = null,
    sibling_correlation: generation_transport.EventCorrelation = .{},
    sibling_effect: prepared_types.EffectRequest = .none,
    same_busy: bool = false,
    sibling_busy: bool = false,
    post_unpublished: bool = false,

    fn invoke(raw: *anyopaque) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        settlePendingEvent(
            self.lifetime_owner,
            self.pending,
            self.attachment,
            self.correlation,
            self.effect,
        ) catch |err| {
            self.same_busy = err == error.Busy;
        };
        if (self.sibling_lifetime_owner != null and self.sibling_pending != null and self.sibling_attachment != null) {
            settlePendingEvent(
                self.sibling_lifetime_owner.?,
                self.sibling_pending.?,
                self.sibling_attachment.?,
                self.sibling_correlation,
                self.sibling_effect,
            ) catch |err| {
                self.sibling_busy = err == error.Busy;
            };
        }
        self.post_unpublished = attachment_mod.testing_api.takeEventReleasePostSnapshot() == null;
    }
};

// Zig lazy analysis가 모든 owner 선언을 언급하는 제품 경로를 instantiate하지 않아도 aggregate
// test root에서 owner module 테스트 inventory를 reachable로 유지한다.
comptime {
    _ = pending_owner;
}

fn red() !void {
    try contract.atomicSettlementImplemented();
}

pub fn settlePendingEvent(
    lifetime_owner: *lifetime.RuntimeLifetimeOwner,
    pending: *pending_owner.PendingEventOwner,
    attachment: *attachment_mod.GenerationAttachment,
    correlation: @import("generation_transport.zig").EventCorrelation,
    expected_effect: prepared_types.EffectRequest,
) error{ Busy, InvalidOwner }!void {
    if (!lifetime_owner.currentProcessDomainMatches()) return error.InvalidOwner;
    if (attachment.pendingEventReleaseCallbackActive()) return error.Busy;
    var lease_out: lifetime.RuntimeSettlementLease = .{};
    var effect_out: contract.EffectCommitEvidence = .{};
    var release_out: contract.EventReleaseCompletion = .{};
    var effect_permit: contract.PreparedEffectPermit = .{};
    var release_permit: contract.PreparedEventReleasePermit = .{};
    var pending_permit: contract.PreparedPendingSettlementPermit = .{};
    var begun: generation_transport.PendingEventReleaseBegun = .{};
    var replaced_payload: ?[]u8 = null;
    defer if (builtin.is_test) {
        if (replaced_payload) |payload| attachment_mod.testing_api.restoreEventPayload(attachment, payload);
    };
    if (builtin.is_test) if (settlement_alias_injection) |injection| {
        const inventory = try settlementScratchInventory(
            &lease_out,
            &effect_out,
            &release_out,
            &effect_permit,
            &release_permit,
            &pending_permit,
            &begun,
            lifetime_owner,
            pending,
            attachment,
        );
        const target = inventory[@intFromEnum(injection.role)];
        const alias = switch (injection.kind) {
            .exact => .{ target.start, target.end - target.start },
            .left => .{ target.start - 1, @as(usize, 2) },
            .right => .{ target.end - 1, @as(usize, 2) },
        };
        replaced_payload = attachment_mod.testing_api.replaceEventPayload(attachment, alias[0], alias[1]);
    };
    const range_proof = try preflightSettlementScratchRanges(
        lifetime_owner,
        pending,
        attachment,
        &lease_out,
        &effect_out,
        &release_out,
        &effect_permit,
        &release_permit,
        &pending_permit,
        &begun,
    );
    const proof = try preflightSettlementScratchPristine(
        range_proof,
        &lease_out,
        &effect_out,
        &release_out,
        &effect_permit,
        &release_permit,
        &pending_permit,
        &begun,
        lifetime_owner,
        pending,
        attachment,
    );
    const projection = try pending.settlementEffectProjection();
    if (!std.meta.eql(projection.effect_request, projectEffectRequest(expected_effect)))
        return error.InvalidOwner;
    const binding = try lifetime_owner.acquireSettlement(&lease_out, proof);
    var lease_prepared = true;
    defer if (lease_prepared) lifetime_owner.abortSettlementPreAdmissionNoFail(&lease_out);

    try attachment.preflightPendingSettlementTransport(
        correlation,
        projection,
        lifetime_owner,
        &lease_out,
        binding,
        &effect_out,
        &release_out,
        &effect_permit,
        &release_permit,
        &pending_permit,
        &begun,
        pending,
    );
    var transport_prepared = true;
    defer if (transport_prepared) attachment.abortPendingSettlementTransportPreAdmissionNoFail(
        &effect_permit,
        &release_permit,
    );
    try pending.preflightSettlement(lifetime_owner, &lease_out, .{
        .lease = binding,
        .pending_owner_addr = projection.pending_owner_addr,
        .owner_incarnation = projection.owner_incarnation,
        .attempt = projection.attempt,
        .source_lease_incarnation = projection.release.source_lease_incarnation,
        .event_generation = projection.event_generation,
        .effect_out_addr = @intFromPtr(&effect_out),
        .release_out_addr = @intFromPtr(&release_out),
        .release_receipt_digest = projection.release.release_seal,
    }, &pending_permit);

    pending.armSettlementNoFail(lifetime_owner, &lease_out, &pending_permit, binding);
    lease_prepared = false;
    transport_prepared = false;
    attachment.commitPendingEffectNoFail(
        lifetime_owner,
        &lease_out,
        binding,
        &effect_permit,
        &effect_out,
    );
    attachment.commitPendingReleaseNoFail(
        lifetime_owner,
        &lease_out,
        binding,
        &effect_permit,
        &effect_out,
        &release_permit,
        &begun,
        &release_out,
    );
    pending.publishSettlementNoFail(
        lifetime_owner,
        &lease_out,
        binding,
        &pending_permit,
        &effect_permit,
        &effect_out,
        &release_out,
    );
    lifetime_owner.consumeSettlementNoFail(&lease_out);
}

fn projectEffectRequest(value: prepared_types.EffectRequest) contract.EffectRequestProjection {
    return switch (value) {
        .none => .{},
        .poison => |reason| .{
            .tag_raw = @intFromEnum(contract.EffectRequestTag.poison),
            .requested_reason = .{ .present_raw = 1, .reason_raw = @intFromEnum(reason) },
        },
        .revoke_fence => |fence| .{
            .tag_raw = @intFromEnum(contract.EffectRequestTag.revoke_fence),
            .revoke_fence = fence,
        },
    };
}

test "C3-3b3 coordinator는 pristine owner를 변경 전에 거부한다" {
    var lifetime_owner: lifetime.RuntimeLifetimeOwner = .{};
    var pending: pending_owner.PendingEventOwner = .{};
    var attachment: attachment_mod.GenerationAttachment = .{};
    const correlation: @import("generation_transport.zig").EventCorrelation = .{};
    try std.testing.expectError(
        error.InvalidOwner,
        settlePendingEvent(&lifetime_owner, &pending, &attachment, correlation, .none),
    );
    try std.testing.expectEqualDeep(lifetime.RuntimeLifetimeOwner{}, lifetime_owner);
    try std.testing.expectEqualDeep(pending_owner.PendingEventOwner{}, pending);
    try std.testing.expectEqualDeep(attachment_mod.GenerationAttachment{}, attachment);
}

fn expectResealedPhaseBeforeContextReject(
    snapshot: attachment_mod.testing_api.EventReleasePostSnapshot,
    role: contract.EventReleasePhaseRole,
) !void {
    var context = snapshot.context;
    const receipt = switch (role) {
        .owner => &context.owner,
        .correlation => &context.correlation,
        .mirror => &context.mirror,
        .callback => &context.callback,
    };
    receipt.before_digest[0] ^= 1;
    receipt.seal = try contract.sealEventReleasePhaseReceipt(receipt.*);
    var post = snapshot.post;
    switch (role) {
        .owner => post.owner_tombstoned_digest = receipt.seal,
        .correlation => post.correlation_tombstoned_digest = receipt.seal,
        .mirror => post.mirror_tombstoned_digest = receipt.seal,
        .callback => post.callback_invoked_digest = receipt.seal,
    }
    var completion = snapshot.completion;
    completion.post_transcript_digest = contract.eventReleasePostTranscriptDigest(context.permit_seal, post).?;
    completion.authority_digest = contract.eventReleaseCompletionAuthorityDigest(completion);
    completion.seal = try contract.sealEventReleaseCompletion(completion);
    try std.testing.expect(contract.validEventReleasePostCompletionContext(context.permit_seal, post, completion));
    try std.testing.expect(!contract.validEventReleasePostContext(context, post, completion));
}

fn runActualPreparedSettlement(options: ActualSettlementOptions) !void {
    try attachment_mod.testing_api.initializeProcessRuntime();
    var forwarding_allocator: CallbackForwardingAllocator = .{ .parent = std.testing.allocator };
    const allocator = forwarding_allocator.allocator();
    var fds: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(@as(c_int, 0), std.c.socketpair(
        std.posix.AF.UNIX,
        std.posix.SOCK.STREAM,
        0,
        &fds,
    ));
    defer _ = std.c.close(fds[1]);
    var client: client_mod.Client = .{
        .allocator = allocator,
        .fd = fds[0],
        .host_id = 0xC33B3E01,
        .parser = framing.FrameParser.init(allocator),
    };
    var adapter: host_adapter_mod.HostAdapter = undefined;
    try host_adapter_mod.HostAdapter.initInPlace(&adapter, allocator, &client);
    defer adapter.deinit();
    var attachment: attachment_mod.GenerationAttachment = .{};
    try attachment_mod.testing_api.initAttached(
        &attachment,
        &adapter,
        allocator,
        0xC33B3E02,
        0xC33B3E03,
    );
    const source_baseline = try attachment_mod.testing_api.eventReleaseSourceSnapshot(&adapter);
    const event_wire = if (options.preserve_sibling_outbound or options.preserve_first_reason or
        options.death_stage == .client_post_callback)
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000c33b3e02\",\"stream_id\":3275439619,\"controller_generation\":4,\"reason\":\"takeover\"}}"
    else
        "{\"event\":\"runtime.invalidated\"}";
    try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(
        0xC33B3E03,
        event_wire,
    );
    try std.testing.expectEqual(
        @import("generation_transport.zig").EventTakeOutcome.taken,
        try attachment.takeEvent(),
    );
    var pending: pending_owner.PendingEventOwner = .{};
    var lifetime_owner: lifetime.RuntimeLifetimeOwner = .{};
    const ready = try process_seal.currentReadyIdentity();
    const RuntimeFixture = struct {
        observation: maru.app.RuntimeObservation = .{},
        direct_input: std.ArrayListUnmanaged(u8) = .empty,
        direct_input_offset: usize = 0,
        pending_controls: std.ArrayListUnmanaged(pending_control.RawQueuedRuntimeControl) = .empty,
        blocking_flush_active: bool = false,
        resize_generation: u64 = 0,
        resize_baseline_present: bool = false,
    };
    var runtime: RuntimeFixture = .{};
    var sibling_runtime: RuntimeFixture = .{};
    defer runtime.observation.deinit(allocator);
    defer runtime.direct_input.deinit(allocator);
    defer runtime.pending_controls.deinit(allocator);
    defer sibling_runtime.observation.deinit(allocator);
    defer sibling_runtime.direct_input.deinit(allocator);
    defer sibling_runtime.pending_controls.deinit(allocator);
    try pending.initInPlace(1);
    try lifetime_owner.initInPlace(@intFromPtr(&runtime), @intFromPtr(&pending), ready.process_nonce, 1);
    const source = try attachment_mod.testing_api.preparePendingSettlement(
        &attachment,
        allocator,
        &lifetime_owner,
        &pending,
        @intFromPtr(&runtime),
        @sizeOf(RuntimeFixture),
        &runtime.observation,
        &runtime.direct_input,
        &runtime.direct_input_offset,
        &runtime.pending_controls,
        &runtime.blocking_flush_active,
        &runtime.resize_generation,
        &runtime.resize_baseline_present,
    );
    var source_before = try attachment_mod.testing_api.eventReleaseSourceSnapshot(&adapter);
    try std.testing.expectEqual(source_baseline.pin_count + 1, source_before.pin_count);
    try std.testing.expectEqual(@as(usize, 1), source_before.blocker_count);
    try std.testing.expectEqual(source_baseline.quarantine_occupied + 1, source_before.quarantine_occupied);
    try std.testing.expect(source_before.quarantine_retained_bytes > source_baseline.quarantine_retained_bytes);
    const prepared = try pending.borrowPrepared();
    if (options.preserve_first_reason or options.preserve_sibling_outbound) switch (prepared.effect) {
        .revoke_fence => |fence| try std.testing.expect(fence != 0),
        else => return error.TestUnexpectedResult,
    };
    var sibling_attachment: attachment_mod.GenerationAttachment = .{};
    var sibling_pending: pending_owner.PendingEventOwner = .{};
    var sibling_lifetime_owner: lifetime.RuntimeLifetimeOwner = .{};
    var sibling_source: attachment_mod.testing_api.PreparedSettlement = .{ .correlation = .{}, .event_generation = 0 };
    var sibling_effect: prepared_types.EffectRequest = .none;
    if (options.reentry) {
        try attachment_mod.testing_api.initAttached(
            &sibling_attachment,
            &adapter,
            allocator,
            0xC33B3E12,
            0xC33B3E13,
        );
        try host_adapter_mod.HostAdapter.testing.rawClient(&adapter).bufferGenerationEventForTest(
            0xC33B3E13,
            "{\"event\":\"runtime.invalidated\"}",
        );
        try std.testing.expectEqual(
            generation_transport.EventTakeOutcome.taken,
            try sibling_attachment.takeEvent(),
        );
        try sibling_pending.initInPlace(2);
        try sibling_lifetime_owner.initInPlace(
            @intFromPtr(&sibling_runtime),
            @intFromPtr(&sibling_pending),
            ready.process_nonce,
            2,
        );
        sibling_source = try attachment_mod.testing_api.preparePendingSettlement(
            &sibling_attachment,
            allocator,
            &sibling_lifetime_owner,
            &sibling_pending,
            @intFromPtr(&sibling_runtime),
            @sizeOf(RuntimeFixture),
            &sibling_runtime.observation,
            &sibling_runtime.direct_input,
            &sibling_runtime.direct_input_offset,
            &sibling_runtime.pending_controls,
            &sibling_runtime.blocking_flush_active,
            &sibling_runtime.resize_generation,
            &sibling_runtime.resize_baseline_present,
        );
        sibling_effect = (try sibling_pending.borrowPrepared()).effect;
        source_before = try attachment_mod.testing_api.eventReleaseSourceSnapshot(&adapter);
    }
    if (options.preserve_first_reason)
        try attachment_mod.testing_api.seedFirstReason(&adapter, 0);
    if (options.preserve_first_reason)
        try attachment_mod.testing_api.seedSiblingOutbound(
            &adapter,
            "target-partial-outbound",
            3,
            0xC33B3E03,
        );
    if (options.death_stage == .client_post_callback)
        try attachment_mod.testing_api.seedSiblingOutbound(
            &adapter,
            "client-post-callback-target",
            3,
            0xC33B3E03,
        );
    if (options.preserve_sibling_outbound)
        try attachment_mod.testing_api.seedSiblingOutbound(
            &adapter,
            "sibling-outbound-byte-exact",
            3,
            0xC33B3E04,
        );
    const effect_state_before = attachment_mod.testing_api.effectStateSnapshot(&adapter);
    if (options.death_stage) |stage| {
        attachment_mod.testing_api.armSettlementDeathCheckpoint(
            &attachment,
            settlement_death_marker_fd,
            switch (stage) {
                .post_admission => 1,
                .post_callback => 2,
                .client_post_callback => 3,
                else => unreachable,
            },
        );
        attachment_mod.testing_api.armSettlementProofLossMarker(
            settlement_death_marker_fd,
            switch (stage) {
                .post_admission => 1,
                .post_callback => 2,
                .client_post_callback => 3,
                else => unreachable,
            },
        );
        writeSettlementDeathMarker(settlement_death_marker_fd, .ready);
        if (stage == .post_callback) {
            const payload_range = try attachment_mod.testing_api.eventPayloadRange(&attachment);
            forwarding_allocator.target_addr = payload_range.address;
            forwarding_allocator.target_len = payload_range.len;
            forwarding_allocator.death_marker_fd = settlement_death_marker_fd;
            forwarding_allocator.armed = true;
        }
    }
    if (options.pre_admission_fork) {
        var marker_pipe: [2]std.c.fd_t = undefined;
        try std.testing.expectEqual(@as(c_int, 0), std.c.pipe(&marker_pipe));
        const lifetime_copy = lifetime_owner;
        const pending_copy = pending;
        const attachment_copy = attachment;
        const slot_copy = adapter.slot;
        const free_before = forwarding_allocator.invocation_count;
        const callback_before = attachment_mod.testing_api.pendingEventPayloadCallbackCount();
        const projection_before = forkRejectedSettlementProjection(
            &lifetime_owner,
            &pending,
            &attachment,
            &adapter,
            free_before,
        );
        const child = std.c.fork();
        if (child < 0) return error.TestUnexpectedResult;
        if (child == 0) {
            _ = std.c.close(marker_pipe[0]);
            if (settlePendingEvent(
                &lifetime_owner,
                &pending,
                &attachment,
                source.correlation,
                prepared.effect,
            )) |_| std.c._exit(124) else |err| {
                if (err != error.InvalidOwner) std.c._exit(125);
            }
            writeSettlementDeathMarker(marker_pipe[1], .invalid_owner);
            const projection_after = forkRejectedSettlementProjection(
                &lifetime_owner,
                &pending,
                &attachment,
                &adapter,
                forwarding_allocator.invocation_count,
            );
            if (!std.mem.eql(u8, std.mem.asBytes(&lifetime_copy), std.mem.asBytes(&lifetime_owner)) or
                !std.mem.eql(u8, std.mem.asBytes(&pending_copy), std.mem.asBytes(&pending)) or
                !std.mem.eql(u8, std.mem.asBytes(&attachment_copy), std.mem.asBytes(&attachment)) or
                !std.mem.eql(u8, std.mem.asBytes(&slot_copy), std.mem.asBytes(&adapter.slot)) or
                !std.meta.eql(projection_before, projection_after))
                std.c._exit(125);
            writeSettlementDeathMarker(marker_pipe[1], .projection_equal);
            if (forwarding_allocator.invocation_count != free_before) std.c._exit(125);
            writeSettlementDeathMarker(marker_pipe[1], .free0);
            if (attachment_mod.testing_api.pendingEventPayloadCallbackCount() != callback_before) std.c._exit(125);
            writeSettlementDeathMarker(marker_pipe[1], .callback0);
            std.c._exit(73);
        }
        _ = std.c.close(marker_pipe[1]);
        var poll_fds = [_]std.c.pollfd{.{ .fd = marker_pipe[0], .events = std.c.POLL.IN, .revents = 0 }};
        const polled = std.c.poll(&poll_fds, 1, 2000);
        if (polled != 1) {
            _ = std.c.kill(child, std.c.SIG.KILL);
            _ = std.c.close(marker_pipe[0]);
            var killed_status: c_int = 0;
            while (std.c.waitpid(child, &killed_status, 0) < 0) {}
            return error.TestUnexpectedResult;
        }
        var transcript: [5]u8 = undefined;
        var transcript_len: usize = 0;
        while (transcript_len < transcript.len) {
            const count = std.c.read(marker_pipe[0], transcript[transcript_len..].ptr, transcript.len - transcript_len);
            if (count > 0) {
                transcript_len += @intCast(count);
                continue;
            }
            if (count == 0) break;
            if (std.posix.errno(count) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        _ = std.c.close(marker_pipe[0]);
        try std.testing.expectEqual(@as(usize, 4), transcript_len);
        try std.testing.expectEqualSlices(u8, &.{ 0x31, 0x32, 0x33, 0x34 }, transcript[0..4]);
        var status: c_int = 0;
        while (true) {
            const waited = std.c.waitpid(child, &status, 0);
            if (waited == child) break;
            if (waited < 0 and std.posix.errno(waited) == .INTR) continue;
            return error.TestUnexpectedResult;
        }
        const unsigned: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFEXITED(unsigned));
        try std.testing.expectEqual(@as(u8, 73), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned))));
    }
    var reentry_context: SettlementReentryContext = .{
        .lifetime_owner = &lifetime_owner,
        .pending = &pending,
        .attachment = &attachment,
        .correlation = source.correlation,
        .effect = prepared.effect,
        .sibling_lifetime_owner = if (options.reentry) &sibling_lifetime_owner else null,
        .sibling_pending = if (options.reentry) &sibling_pending else null,
        .sibling_attachment = if (options.reentry) &sibling_attachment else null,
        .sibling_correlation = sibling_source.correlation,
        .sibling_effect = sibling_effect,
    };
    if (options.reentry) {
        const payload_range = try attachment_mod.testing_api.eventPayloadRange(&attachment);
        forwarding_allocator.target_addr = payload_range.address;
        forwarding_allocator.target_len = payload_range.len;
        forwarding_allocator.context = &reentry_context;
        forwarding_allocator.callback = SettlementReentryContext.invoke;
        forwarding_allocator.armed = true;
    }
    const callback_count_before_aliases = attachment_mod.testing_api.pendingEventPayloadCallbackCount();
    var alias_rows: usize = 0;
    inline for (std.meta.tags(SettlementScratchRole)) |role| {
        inline for (std.meta.tags(SettlementAliasKind)) |kind| {
            alias_rows += 1;
            settlement_alias_injection = .{ .role = role, .kind = kind };
            defer settlement_alias_injection = null;
            try std.testing.expectError(error.InvalidOwner, settlePendingEvent(
                &lifetime_owner,
                &pending,
                &attachment,
                source.correlation,
                prepared.effect,
            ));
            try std.testing.expectEqualDeep(
                source_before,
                try attachment_mod.testing_api.eventReleaseSourceSnapshot(&adapter),
            );
            const after_reject = attachment_mod.testing_api.settlementSourceSnapshot(&attachment);
            try std.testing.expect(!after_reject.owner_pristine);
            try std.testing.expect(!after_reject.correlation_pristine);
            try std.testing.expectEqual(source.event_generation, after_reject.event_generation_mirror);
            try std.testing.expectEqual(
                callback_count_before_aliases,
                attachment_mod.testing_api.pendingEventPayloadCallbackCount(),
            );
            settlement_alias_injection = null;
        }
    }
    try std.testing.expectEqual(@as(usize, 30), alias_rows);
    lifetime.testing.armSettlementContention(options.contention_count);
    const callback_count_before_contention = attachment_mod.testing_api.pendingEventPayloadCallbackCount();
    const lifetime_before_contention = lifetime_owner;
    const pending_before_contention = try pending.borrowPrepared();
    const projection_before_contention = try pending.settlementEffectProjection();
    const attachment_before_contention = attachment_mod.testing_api.settlementSourceSnapshot(&attachment);
    const effect_before_contention = attachment_mod.testing_api.effectStateSnapshot(&adapter);
    var contention_index: usize = 0;
    while (contention_index < options.contention_count) : (contention_index += 1) {
        try std.testing.expectError(error.Busy, settlePendingEvent(
            &lifetime_owner,
            &pending,
            &attachment,
            source.correlation,
            prepared.effect,
        ));
        _ = try pending.borrowPrepared();
        const retry_projection = try pending.settlementEffectProjection();
        try std.testing.expectEqual(@as(u64, 1), retry_projection.attempt);
        try std.testing.expectEqualDeep(lifetime_before_contention, lifetime_owner);
        try std.testing.expectEqualDeep(pending_before_contention, try pending.borrowPrepared());
        try std.testing.expectEqualDeep(projection_before_contention, retry_projection);
        try std.testing.expectEqualDeep(
            attachment_before_contention,
            attachment_mod.testing_api.settlementSourceSnapshot(&attachment),
        );
        try std.testing.expectEqualDeep(
            effect_before_contention,
            attachment_mod.testing_api.effectStateSnapshot(&adapter),
        );
        try std.testing.expectEqualDeep(
            source_before,
            try attachment_mod.testing_api.eventReleaseSourceSnapshot(&adapter),
        );
        try std.testing.expectEqual(
            callback_count_before_contention,
            attachment_mod.testing_api.pendingEventPayloadCallbackCount(),
        );
    }
    try settlePendingEvent(
        &lifetime_owner,
        &pending,
        &attachment,
        source.correlation,
        prepared.effect,
    );
    try std.testing.expectEqual(
        callback_count_before_contention + 1,
        attachment_mod.testing_api.pendingEventPayloadCallbackCount(),
    );
    if (options.reentry) {
        try std.testing.expect(forwarding_allocator.fired);
        try std.testing.expectEqual(@as(usize, 1), forwarding_allocator.invocation_count);
        try std.testing.expect(reentry_context.same_busy);
        try std.testing.expect(reentry_context.sibling_busy);
        try std.testing.expect(reentry_context.post_unpublished);
    }
    const effect_state_after = attachment_mod.testing_api.effectStateSnapshot(&adapter);
    if (options.preserve_first_reason) {
        try std.testing.expect(effect_state_after.first_reason_present);
        try std.testing.expectEqual(effect_state_before.first_reason_raw, effect_state_after.first_reason_raw);
        try std.testing.expect(effect_state_after.unusable);
        try std.testing.expectEqual(@as(usize, 0), effect_state_after.outbound_len);
    }
    if (options.preserve_sibling_outbound)
        try std.testing.expectEqualDeep(effect_state_before, effect_state_after);
    const post_snapshot = attachment_mod.testing_api.takeEventReleasePostSnapshot() orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(contract.validEventReleasePostContext(post_snapshot.context, post_snapshot.post, post_snapshot.completion));
    var post_splices = [_]contract.EventReleasePostProjection{post_snapshot.post} ** 7;
    post_splices[0].registry_closed_digest[0] ^= 1;
    post_splices[1].quarantine_closed_digest[0] ^= 1;
    post_splices[2].pin_consumed_digest[0] ^= 1;
    post_splices[3].callback_invoked_digest[0] ^= 1;
    post_splices[4].owner_tombstoned_digest[0] ^= 1;
    post_splices[5].correlation_tombstoned_digest[0] ^= 1;
    post_splices[6].mirror_tombstoned_digest[0] ^= 1;
    for (post_splices) |splice| try std.testing.expect(!contract.validEventReleasePostCompletionContext(
        post_snapshot.permit_seal,
        splice,
        post_snapshot.completion,
    ));
    var count_splice = post_snapshot.post;
    count_splice.callback_invocation_count = 0;
    try std.testing.expect(!contract.validEventReleasePostCompletionContext(
        post_snapshot.permit_seal,
        count_splice,
        post_snapshot.completion,
    ));
    count_splice = post_snapshot.post;
    count_splice.source_tombstone_count = 0;
    try std.testing.expect(!contract.validEventReleasePostCompletionContext(
        post_snapshot.permit_seal,
        count_splice,
        post_snapshot.completion,
    ));
    var permit_splice = post_snapshot.permit_seal;
    permit_splice[0] ^= 1;
    try std.testing.expect(!contract.validEventReleasePostCompletionContext(
        permit_splice,
        post_snapshot.post,
        post_snapshot.completion,
    ));
    var context_splices = [_]contract.EventReleasePostContext{post_snapshot.context} ** 7;
    context_splices[0].registry.identity_a +%= 1;
    context_splices[1].quarantine.before_a +%= 1;
    context_splices[2].pin.identity_e +%= 1;
    context_splices[3].owner.before_digest[0] ^= 1;
    context_splices[4].correlation.event_generation +%= 1;
    context_splices[5].mirror.after_digest[0] ^= 1;
    context_splices[6].callback.invocation_ordinal +%= 1;
    try std.testing.expect(!contract.validEventReleaseLeafReceipt(context_splices[0].registry, .registry));
    try std.testing.expect(!contract.validEventReleaseLeafReceipt(context_splices[1].quarantine, .quarantine));
    try std.testing.expect(!contract.validEventReleaseLeafReceipt(context_splices[2].pin, .pin));
    try std.testing.expect(!contract.validEventReleasePhaseReceipt(context_splices[3].owner, .owner));
    try std.testing.expect(!contract.validEventReleasePhaseReceipt(context_splices[4].correlation, .correlation));
    try std.testing.expect(!contract.validEventReleasePhaseReceipt(context_splices[5].mirror, .mirror));
    try std.testing.expect(!contract.validEventReleasePhaseReceipt(context_splices[6].callback, .callback));
    for (context_splices) |splice| try std.testing.expect(!contract.validEventReleasePostContext(
        splice,
        post_snapshot.post,
        post_snapshot.completion,
    ));
    var resealed_delta = post_snapshot.context;
    resealed_delta.quarantine.after_b +%= 1;
    resealed_delta.quarantine.seal = try contract.sealEventReleaseLeafReceipt(resealed_delta.quarantine);
    var resealed_delta_post = post_snapshot.post;
    resealed_delta_post.quarantine_closed_digest = resealed_delta.quarantine.seal;
    var resealed_delta_completion = post_snapshot.completion;
    resealed_delta_completion.post_transcript_digest = contract.eventReleasePostTranscriptDigest(
        resealed_delta.permit_seal,
        resealed_delta_post,
    ).?;
    resealed_delta_completion.authority_digest = contract.eventReleaseCompletionAuthorityDigest(resealed_delta_completion);
    resealed_delta_completion.seal = try contract.sealEventReleaseCompletion(resealed_delta_completion);
    try std.testing.expect(contract.validEventReleasePostCompletionContext(
        resealed_delta.permit_seal,
        resealed_delta_post,
        resealed_delta_completion,
    ));
    try std.testing.expect(!contract.validEventReleasePostContext(resealed_delta, resealed_delta_post, resealed_delta_completion));
    var resealed_identity = post_snapshot.context;
    resealed_identity.pin.identity_e +%= 1;
    resealed_identity.pin.seal = try contract.sealEventReleaseLeafReceipt(resealed_identity.pin);
    var resealed_identity_post = post_snapshot.post;
    resealed_identity_post.pin_consumed_digest = resealed_identity.pin.seal;
    var resealed_identity_completion = post_snapshot.completion;
    resealed_identity_completion.post_transcript_digest = contract.eventReleasePostTranscriptDigest(
        resealed_identity.permit_seal,
        resealed_identity_post,
    ).?;
    resealed_identity_completion.authority_digest = contract.eventReleaseCompletionAuthorityDigest(resealed_identity_completion);
    resealed_identity_completion.seal = try contract.sealEventReleaseCompletion(resealed_identity_completion);
    try std.testing.expect(contract.validEventReleasePostCompletionContext(
        resealed_identity.permit_seal,
        resealed_identity_post,
        resealed_identity_completion,
    ));
    try std.testing.expect(!contract.validEventReleasePostContext(resealed_identity, resealed_identity_post, resealed_identity_completion));
    try expectResealedPhaseBeforeContextReject(post_snapshot, .owner);
    try expectResealedPhaseBeforeContextReject(post_snapshot, .correlation);
    try expectResealedPhaseBeforeContextReject(post_snapshot, .mirror);
    try expectResealedPhaseBeforeContextReject(post_snapshot, .callback);
    var resealed_registry = post_snapshot.context;
    resealed_registry.registry.identity_a +%= 1;
    resealed_registry.registry.seal = try contract.sealEventReleaseLeafReceipt(resealed_registry.registry);
    var resealed_registry_post = post_snapshot.post;
    resealed_registry_post.registry_closed_digest = resealed_registry.registry.seal;
    var resealed_registry_completion = post_snapshot.completion;
    resealed_registry_completion.post_transcript_digest = contract.eventReleasePostTranscriptDigest(
        resealed_registry.permit_seal,
        resealed_registry_post,
    ).?;
    resealed_registry_completion.authority_digest = contract.eventReleaseCompletionAuthorityDigest(resealed_registry_completion);
    resealed_registry_completion.seal = try contract.sealEventReleaseCompletion(resealed_registry_completion);
    try std.testing.expect(contract.validEventReleasePostCompletionContext(
        resealed_registry.permit_seal,
        resealed_registry_post,
        resealed_registry_completion,
    ));
    try std.testing.expect(!contract.validEventReleasePostContext(
        resealed_registry,
        resealed_registry_post,
        resealed_registry_completion,
    ));
    try std.testing.expectEqual(@intFromEnum(pending_owner.PendingLifecycle.settling), pending.lifecycle_raw);
    if (options.reentry) {
        try settlePendingEvent(
            &sibling_lifetime_owner,
            &sibling_pending,
            &sibling_attachment,
            sibling_source.correlation,
            sibling_effect,
        );
        _ = attachment_mod.testing_api.takeEventReleasePostSnapshot() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(attachment_mod.DeinitOutcome.cleaned, sibling_attachment.tryDeinit(&adapter));
    }
    const attachment_after = attachment_mod.testing_api.settlementSourceSnapshot(&attachment);
    try std.testing.expect(attachment_after.owner_pristine);
    try std.testing.expect(attachment_after.correlation_pristine);
    try std.testing.expectEqual(@as(u64, 0), attachment_after.event_generation_mirror);
    const source_after = try attachment_mod.testing_api.eventReleaseSourceSnapshot(&adapter);
    try std.testing.expectEqual(source_baseline.pin_count, source_after.pin_count);
    try std.testing.expectEqual(@as(usize, 0), source_after.blocker_count);
    try std.testing.expectEqual(source_baseline.quarantine_occupied, source_after.quarantine_occupied);
    try std.testing.expectEqual(source_baseline.quarantine_retained_bytes, source_after.quarantine_retained_bytes);
    try std.testing.expectEqual(attachment_mod.DeinitOutcome.cleaned, attachment.tryDeinit(&adapter));
}

test "C3-3b3 coordinator는 시작 권위로 준비된 event를 settle한다" {
    try runActualPreparedSettlement(.{});
}

const ScratchRange = struct { start: usize, end: usize, alignment: usize };

fn settlementScratchInventory(
    lease_out: anytype,
    effect_out: anytype,
    release_out: anytype,
    effect_permit: anytype,
    release_permit: anytype,
    pending_permit: anytype,
    begun: anytype,
    lifetime_owner: anytype,
    pending: anytype,
    attachment: anytype,
) error{InvalidOwner}![std.meta.fields(SettlementScratchRole).len]ScratchRange {
    return .{
        try scratchRange(lease_out),     try scratchRange(effect_out),     try scratchRange(release_out),
        try scratchRange(effect_permit), try scratchRange(release_permit), try scratchRange(pending_permit),
        try scratchRange(begun),         try scratchRange(lifetime_owner), try scratchRange(pending),
        try scratchRange(attachment),
    };
}

pub fn preflightSettlementScratchRanges(
    lifetime_owner: *const lifetime.RuntimeLifetimeOwner,
    pending: *const pending_owner.PendingEventOwner,
    attachment: *const attachment_mod.GenerationAttachment,
    lease_out: *lifetime.RuntimeSettlementLease,
    effect_out: *contract.EffectCommitEvidence,
    release_out: *contract.EventReleaseCompletion,
    effect_permit: *contract.PreparedEffectPermit,
    release_permit: *contract.PreparedEventReleasePermit,
    pending_permit: *contract.PreparedPendingSettlementPermit,
    begun: *generation_transport.PendingEventReleaseBegun,
) error{InvalidOwner}!contract.SettlementScratchRangeProof {
    const ranges = try settlementScratchInventory(
        lease_out,
        effect_out,
        release_out,
        effect_permit,
        release_permit,
        pending_permit,
        begun,
        lifetime_owner,
        pending,
        attachment,
    );
    for (ranges, 0..) |left, left_index| {
        for (ranges[left_index + 1 ..]) |right|
            if (rangesOverlap(left, right)) return error.InvalidOwner;
    }
    const disposition = try scratchRange(&pending.settlement_disposition);
    const pending_range = ranges[8];
    if (disposition.start < pending_range.start or disposition.end > pending_range.end)
        return error.InvalidOwner;
    const disposition_offset = disposition.start - pending_range.start;

    const ready = process_seal.currentReadyIdentity() catch return error.InvalidOwner;
    var proof: contract.SettlementScratchRangeProof = .{
        .pid = ready.pid,
        .process_nonce = ready.process_nonce,
        .thread_id = @intCast(std.Thread.getCurrentId()),
        .ranges_digest = digestScratchAuthority(ranges, disposition_offset),
        .disposition_offset = disposition_offset,
    };
    proof.proof_seal = contract.sealScratchRangeProof(proof) catch return error.InvalidOwner;
    return proof;
}

pub fn preflightSettlementScratchPristine(
    range_proof: contract.SettlementScratchRangeProof,
    lease_out: *const lifetime.RuntimeSettlementLease,
    effect_out: *const contract.EffectCommitEvidence,
    release_out: *const contract.EventReleaseCompletion,
    effect_permit: *const contract.PreparedEffectPermit,
    release_permit: *const contract.PreparedEventReleasePermit,
    pending_permit: *const contract.PreparedPendingSettlementPermit,
    begun: *const generation_transport.PendingEventReleaseBegun,
    lifetime_owner: *const lifetime.RuntimeLifetimeOwner,
    pending: *const pending_owner.PendingEventOwner,
    attachment: *const attachment_mod.GenerationAttachment,
) error{InvalidOwner}!contract.SettlementScratchPreflightProof {
    const current_ranges = try settlementScratchInventory(
        lease_out,
        effect_out,
        release_out,
        effect_permit,
        release_permit,
        pending_permit,
        begun,
        lifetime_owner,
        pending,
        attachment,
    );
    const disposition = try scratchRange(&pending.settlement_disposition);
    if (disposition.start < current_ranges[8].start or disposition.end > current_ranges[8].end)
        return error.InvalidOwner;
    const current_offset = disposition.start - current_ranges[8].start;
    const current_digest = digestScratchAuthority(current_ranges, current_offset);
    if (!contract.validScratchRangeProof(range_proof) or
        range_proof.pid != process_seal.currentProcessId() or
        range_proof.thread_id != @as(u64, @intCast(std.Thread.getCurrentId())) or
        range_proof.disposition_offset != current_offset or
        !std.crypto.timing_safe.eql(contract.Digest, range_proof.ranges_digest, current_digest) or
        !std.meta.eql(lease_out.*, lifetime.RuntimeSettlementLease{}) or
        !std.meta.eql(effect_out.*, contract.EffectCommitEvidence{}) or
        !std.meta.eql(release_out.*, contract.EventReleaseCompletion{}) or
        !std.meta.eql(effect_permit.*, contract.PreparedEffectPermit{}) or
        !std.meta.eql(release_permit.*, contract.PreparedEventReleasePermit{}) or
        !std.meta.eql(pending_permit.*, contract.PreparedPendingSettlementPermit{}) or
        !begun.pristineExact() or
        !std.meta.eql(pending.settlement_disposition, contract.SettlementDisposition{}))
        return error.InvalidOwner;

    var pristine_hasher = std.crypto.hash.Blake3.init(.{});
    pristine_hasher.update("maru.settlement-scratch-pristine.v1\x00");
    pristine_hasher.update(&range_proof.ranges_digest);
    var offset_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &offset_bytes, range_proof.disposition_offset, .little);
    pristine_hasher.update(&offset_bytes);
    hashPristineRecord(&pristine_hasher, lifetime.RuntimeSettlementLease, "runtime-settlement-lease", 1, "self_addr,lifecycle_raw,reserved,operation,ranges_digest,pristine_digest,preflight_proof_seal_digest,lease_seal");
    hashPristineRecord(&pristine_hasher, contract.EffectCommitEvidence, "effect-commit-evidence", 1, "self_addr,lifecycle_raw,consumed_raw,outcome_raw,recovery_raw,reserved,pid,reserved_pid,process_nonce,thread_id,pending_owner_addr,owner_incarnation,attempt,event_generation,first_reason_before,first_reason_after,unusable_before_raw,unusable_after_raw,fd_disposition_raw,close_attempt_count,outbound_relation_raw,outbound_disposition_raw,cleanup_mode_raw,reserved_effect,fd_before,fd_after,cleanup_count,reserved_count,commit_authority_digest,outbound_descriptor_digest,cleanup_completion_digest,confirmed_effect_digest,seal");
    hashPristineRecord(&pristine_hasher, contract.EventReleaseCompletion, "event-release-completion", 3, "self_addr,lifecycle_raw,outcome_raw,detail_raw,reserved,pid,reserved_pid,process_nonce,thread_id,pending_owner_addr,owner_incarnation,attempt,event_generation,registry_incarnation,binding_reservation_id,event_node_incarnation,stream_id,event_owner_addr,source_lease_incarnation,ordering_class_raw,reserved_ordering,release_receipt_digest,permit_digest,consumed_blocker_count,freed_payload_count,consumed_pin_count,settled_quarantine_count,reserved_count,post_transcript_digest,authority_digest,seal");
    hashPristineRecord(&pristine_hasher, contract.PreparedEffectPermit, "prepared-effect-permit", 1, "self_addr,lifecycle_raw,consumed_raw,reserved,pid,reserved_pid,process_nonce,thread_id,pending_owner_addr,owner_incarnation,attempt,event_generation,correlation_digest,prepared_effect_digest,effect_request,slot_incarnation,node_incarnation,binding_incarnation,transport_incarnation,operation_node_addr,operation_id,operation_registry_index,reserved_operation,target_stream_id,action_raw,first_reason_before,first_reason_after,unusable_before_raw,unusable_after_raw,reserved_action,fd_before,fd_after,fd_disposition_raw,close_attempt_count,outbound_relation_raw,outbound_disposition_raw,cleanup_mode_raw,cleanup_count,reserved_outbound,outbound_offset,outbound_len,outbound_descriptor_digest,cleanup_callback_provenance_digest,effect_out_addr,effect_out_extent,effect_out_alignment,effect_out_pristine_digest,scratch_ranges_digest,scratch_pristine_digest,preflight_proof_seal_digest,lease_seal_digest,preflight_authority_digest,seal");
    hashPristineRecord(&pristine_hasher, contract.PreparedEventReleasePermit, "prepared-event-release-permit", 3, "self_addr,lifecycle_raw,consumed_raw,reserved,pid,reserved_pid,process_nonce,thread_id,registry_addr,registry_incarnation,binding_reservation_id,entry_index,reserved_entry,event_node_incarnation,stream_id,event_generation,event_owner_addr,pending_owner_addr,pending_owner_incarnation,source_lease_incarnation,attempt,ordering_class_raw,reserved_ordering,expected_blocker_count,completion_addr,completion_extent,completion_alignment,completion_pristine_digest,begun_addr,begun_extent,begun_alignment,begun_pristine_digest,scratch_ranges_digest,scratch_pristine_digest,preflight_proof_seal_digest,lease_seal_digest,release_receipt_digest,event_owner_seal,payload_addr,payload_len,payload_digest,allocator_ptr,allocator_vtable,pin_owner_addr,lease_addr,slot_addr,node_addr,pin_slot_incarnation,pin_node_incarnation,host_id,connection_generation,pin_process_nonce,quarantine_slot_index,reserved_quarantine,quarantine_reservation_generation,source_authority_digest,seal");
    hashPristineRecord(&pristine_hasher, contract.PreparedPendingSettlementPermit, "prepared-pending-settlement-permit", 1, "self_addr,lifecycle_raw,consumed_raw,reserved,pid,reserved_pid,process_nonce,thread_id,pending_owner_addr,owner_incarnation,attempt,source_lease_incarnation,event_generation,effect_out_addr,release_out_addr,disposition_addr,scratch_ranges_digest,scratch_pristine_digest,preflight_proof_seal_digest,lease_seal_digest,release_receipt_digest,seal");
    hashPristineRecord(&pristine_hasher, generation_transport.PendingEventReleaseBegun, "pending-event-release-begun", 3, "self_addr,pid,process_nonce,thread_id,effect_permit_addr,release_permit_addr,operation_id,event_owner_addr,event_generation,pin_count_before,correlation_digest,effect_permit_seal,release_permit_seal,pin_receipt,owner_tombstone_receipt,correlation_tombstone_receipt,mirror_tombstone_receipt,callback_returned_receipt,lifecycle_raw,callback_active_raw,seal");
    hashPristineRecord(&pristine_hasher, contract.SettlementDisposition, "settlement-disposition", 1, "self_addr,lifecycle_raw,disposition_raw,reserved,pid,reserved_pid,process_nonce,thread_id,pending_owner_addr,owner_incarnation,attempt,event_generation,effect_evidence_digest,registry_completion_digest,consumed_receipt_digest,seal");
    var pristine_digest: contract.Digest = undefined;
    pristine_hasher.final(&pristine_digest);
    var proof: contract.SettlementScratchPreflightProof = .{
        .pid = range_proof.pid,
        .process_nonce = range_proof.process_nonce,
        .thread_id = range_proof.thread_id,
        .ranges_digest = range_proof.ranges_digest,
        .pristine_digest = pristine_digest,
    };
    proof.proof_seal = contract.sealScratchPreflightProof(proof) catch return error.InvalidOwner;
    return proof;
}

fn hashPristineRecord(
    hasher: *std.crypto.hash.Blake3,
    comptime T: type,
    comptime role_tag: []const u8,
    comptime schema_version: u64,
    comptime field_allowlist: []const u8,
) void {
    const record_length = std.meta.fields(T).len;
    comptime {
        @setEvalBranchQuota(10_000);
        if (@typeInfo(T) != .@"struct") @compileError("pristine transcript records must be structs");
        var cursor: usize = 0;
        for (std.meta.fields(T), 0..) |field, index| {
            const end = std.mem.indexOfScalarPos(u8, field_allowlist, cursor, ',') orelse field_allowlist.len;
            if (!std.mem.eql(u8, field_allowlist[cursor..end], field.name))
                @compileError(role_tag ++ " pristine transcript field allowlist is stale at " ++ field.name);
            cursor = if (index + 1 == record_length) end else end + 1;
        }
        if (cursor != field_allowlist.len)
            @compileError(role_tag ++ " pristine transcript field allowlist has trailing data");
    }
    hashTranscriptU64(hasher, role_tag.len);
    hasher.update(role_tag);
    hashTranscriptU64(hasher, schema_version);
    hashTranscriptU64(hasher, @sizeOf(T));
    hashTranscriptU64(hasher, @alignOf(T));
    hashTranscriptU64(hasher, record_length);
    hashTranscriptU64(hasher, field_allowlist.len);
    hasher.update(field_allowlist);
    var semantic = std.crypto.hash.Blake3.init(.{});
    semantic.update("maru.settlement-scratch-pristine-record.v1\x00");
    hashTranscriptU64(&semantic, role_tag.len);
    semantic.update(role_tag);
    hashTranscriptU64(&semantic, schema_version);
    inline for (std.meta.fields(T)) |field| {
        hashTranscriptU64(&semantic, field.name.len);
        semantic.update(field.name);
        const type_name = @typeName(field.type);
        hashTranscriptU64(&semantic, type_name.len);
        semantic.update(type_name);
        hashSemanticValue(&semantic, @field(T{}, field.name));
    }
    var semantic_digest: contract.Digest = undefined;
    semantic.final(&semantic_digest);
    hasher.update(&semantic_digest);
}

fn hashSemanticValue(hasher: *std.crypto.hash.Blake3, value: anytype) void {
    const T = @TypeOf(value);
    const type_name = @typeName(T);
    hashTranscriptU64(hasher, type_name.len);
    hasher.update(type_name);
    switch (@typeInfo(T)) {
        .int => {
            var bytes: [@divExact(@typeInfo(T).int.bits, 8)]u8 = undefined;
            std.mem.writeInt(T, &bytes, value, .little);
            hasher.update(&bytes);
        },
        .array => |array| {
            if (array.child == u8) {
                hasher.update(&value);
            } else {
                for (value) |item| hashSemanticValue(hasher, item);
            }
        },
        .@"enum" => hashSemanticValue(hasher, @intFromEnum(value)),
        .@"struct" => inline for (std.meta.fields(T)) |field| {
            hashTranscriptU64(hasher, field.name.len);
            hasher.update(field.name);
            hashSemanticValue(hasher, @field(value, field.name));
        },
        .optional => if (value) |payload| {
            hasher.update(&.{1});
            hashSemanticValue(hasher, payload);
        } else hasher.update(&.{0}),
        else => @compileError("settlement scratch pristine transcript must remain semantic and pointer-free"),
    }
}

fn hashTranscriptU64(hasher: *std.crypto.hash.Blake3, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .little);
    hasher.update(&bytes);
}

fn scratchRange(pointer: anytype) error{InvalidOwner}!ScratchRange {
    const Pointer = @TypeOf(pointer);
    const info = @typeInfo(Pointer).pointer;
    const start = @intFromPtr(pointer);
    const extent = @sizeOf(info.child);
    const alignment = @alignOf(info.child);
    if (start == 0 or extent == 0 or start % alignment != 0) return error.InvalidOwner;
    const end = std.math.add(usize, start, extent) catch return error.InvalidOwner;
    return .{ .start = start, .end = end, .alignment = alignment };
}

fn rangesOverlap(left: ScratchRange, right: ScratchRange) bool {
    return left.start < right.end and right.start < left.end;
}

fn digestScratchAuthority(ranges: [10]ScratchRange, disposition_offset: usize) contract.Digest {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update("maru.settlement-scratch-ranges.v1");
    for (ranges) |range| inline for (.{ range.start, range.end, range.alignment }) |value| {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, @intCast(value), .little);
        hasher.update(&bytes);
    };
    var offset_bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &offset_bytes, @intCast(disposition_offset), .little);
    hasher.update(&offset_bytes);
    var result: contract.Digest = undefined;
    hasher.final(&result);
    return result;
}

test "C3-3b3 lease owner는 final address에 봉인된다" {
    var fixture: LeaseFixture = .{};
    try fixture.init(1);
    var copied = fixture.lease;
    try std.testing.expect(fixture.owner.validateSettlement(&fixture.lease));
    try std.testing.expect(!fixture.owner.validateSettlement(&copied));
    fixture.owner.abortSettlementPreAdmissionNoFail(&fixture.lease);
}
test "C3-3b3 lease owner는 settlement ordinal을 봉인한다" {
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(lifetime.OperationKind.settlement));
    var fixture: LeaseFixture = .{};
    try fixture.init(2);
    try std.testing.expectEqual(@as(u8, 3), fixture.lease.operation.operation_kind_raw);
    fixture.owner.abortSettlementPreAdmissionNoFail(&fixture.lease);
}
test "C3-3b3 lease owner는 짝지은 preflight만 허용한다" {
    const nonce = try ensureReady();
    var owner: lifetime.RuntimeLifetimeOwner = .{};
    var pending: pending_owner.PendingEventOwner = .{};
    var attachment: attachment_mod.GenerationAttachment = .{};
    var lease_out: lifetime.RuntimeSettlementLease = .{};
    var effect_out: contract.EffectCommitEvidence = .{};
    var release_out: contract.EventReleaseCompletion = .{};
    var effect_permit: contract.PreparedEffectPermit = .{};
    var release_permit: contract.PreparedEventReleasePermit = .{};
    var pending_permit: contract.PreparedPendingSettlementPermit = .{};
    var begun: generation_transport.PendingEventReleaseBegun = .{};
    try owner.initInPlace(0x1003, @intFromPtr(&pending), nonce, 3);
    try pending.initInPlace(3);

    const range_proof = try preflightSettlementScratchRanges(
        &owner,
        &pending,
        &attachment,
        &lease_out,
        &effect_out,
        &release_out,
        &effect_permit,
        &release_permit,
        &pending_permit,
        &begun,
    );
    try std.testing.expect(contract.validScratchRangeProof(range_proof));
    try std.testing.expectEqual(
        @as(u64, @offsetOf(pending_owner.PendingEventOwner, "settlement_disposition")),
        range_proof.disposition_offset,
    );
    try std.testing.expectError(error.InvalidOwner, preflightSettlementScratchRanges(
        &owner,
        &pending,
        &attachment,
        &lease_out,
        @ptrCast(&lease_out),
        &release_out,
        &effect_permit,
        &release_permit,
        &pending_permit,
        &begun,
    ));
    effect_out.outcome_raw = 1;
    try std.testing.expectError(error.InvalidOwner, preflightSettlementScratchPristine(
        range_proof,
        &lease_out,
        &effect_out,
        &release_out,
        &effect_permit,
        &release_permit,
        &pending_permit,
        &begun,
        &owner,
        &pending,
        &attachment,
    ));
    effect_out = .{};
    var moved_effect_out: contract.EffectCommitEvidence = .{};
    try std.testing.expectError(error.InvalidOwner, preflightSettlementScratchPristine(
        range_proof,
        &lease_out,
        &moved_effect_out,
        &release_out,
        &effect_permit,
        &release_permit,
        &pending_permit,
        &begun,
        &owner,
        &pending,
        &attachment,
    ));
    effect_permit.lifecycle_raw = @intFromEnum(contract.AuthorityLifecycle.prepared);
    try std.testing.expectError(error.InvalidOwner, preflightSettlementScratchPristine(
        range_proof,
        &lease_out,
        &effect_out,
        &release_out,
        &effect_permit,
        &release_permit,
        &pending_permit,
        &begun,
        &owner,
        &pending,
        &attachment,
    ));
    effect_permit = .{};
    const proof = try preflightSettlementScratchPristine(
        range_proof,
        &lease_out,
        &effect_out,
        &release_out,
        &effect_permit,
        &release_permit,
        &pending_permit,
        &begun,
        &owner,
        &pending,
        &attachment,
    );
    const binding = try owner.acquireSettlement(&lease_out, proof);
    try std.testing.expect(contract.validRuntimeSettlementBinding(binding));
    try std.testing.expect(std.crypto.timing_safe.eql(contract.Digest, proof.ranges_digest, binding.ranges_digest));
    try std.testing.expect(std.crypto.timing_safe.eql(contract.Digest, proof.pristine_digest, binding.pristine_digest));
    owner.abortSettlementPreAdmissionNoFail(&lease_out);

    var prepared_effect: contract.PreparedEffectPermit = .{
        .self_addr = @intFromPtr(&effect_permit),
        .pid = process_seal.currentProcessId(),
        .process_nonce = nonce,
        .thread_id = @intCast(std.Thread.getCurrentId()),
        .pending_owner_addr = @intFromPtr(&pending),
        .owner_incarnation = 3,
        .attempt = 1,
        .event_generation = 13,
        .correlation_digest = [_]u8{0x41} ** 32,
        .prepared_effect_digest = [_]u8{0x42} ** 32,
        .slot_incarnation = 5,
        .node_incarnation = 7,
        .binding_incarnation = 9,
        .transport_incarnation = 11,
        .operation_node_addr = 0x1000,
        .operation_id = 1,
        .target_stream_id = 17,
        .action_raw = @intFromEnum(contract.EffectAction.none),
        .fd_before = 9,
        .fd_after = 9,
        .effect_out_addr = @intFromPtr(&effect_out),
        .effect_out_extent = @sizeOf(contract.EffectCommitEvidence),
        .effect_out_alignment = @alignOf(contract.EffectCommitEvidence),
        .effect_out_pristine_digest = [_]u8{0x43} ** 32,
        .scratch_ranges_digest = proof.ranges_digest,
        .scratch_pristine_digest = proof.pristine_digest,
        .preflight_proof_seal_digest = proof.proof_seal,
        .lease_seal_digest = binding.lease_seal_digest,
        .preflight_authority_digest = [_]u8{0x44} ** 32,
    };
    prepared_effect.seal = try contract.sealPreparedEffectPermit(prepared_effect);
    effect_permit = prepared_effect;
    effect_permit.lifecycle_raw = @intFromEnum(contract.AuthorityLifecycle.prepared);
    try std.testing.expect(contract.validPreparedEffectPermit(&effect_permit));
    var copied_effect = effect_permit;
    try std.testing.expect(!contract.validPreparedEffectPermit(&copied_effect));
    contract.publishEffectCommitEvidenceNoFail(&effect_permit, binding, &effect_out);
    try std.testing.expect(contract.validEffectCommitEvidenceFor(&effect_permit, binding, &effect_out));
    var spliced_evidence = effect_out;
    spliced_evidence.cleanup_completion_digest[0] ^= 1;
    spliced_evidence.seal = try contract.sealEffectCommitEvidence(spliced_evidence);
    try std.testing.expect(!contract.validEffectCommitEvidenceFor(&effect_permit, binding, &spliced_evidence));
}
test "C3-3b3 lease owner는 pre-admission abort를 한 번만 허용한다" {
    var fixture: LeaseFixture = .{};
    try fixture.init(4);
    fixture.owner.abortSettlementPreAdmissionNoFail(&fixture.lease);
    try std.testing.expectEqual(@as(u8, 3), fixture.lease.lifecycle_raw);
    try std.testing.expectEqual(@as(u8, 1), fixture.lease.operation.consumed_raw);
    _ = try fixture.owner.preflightPreparation();
}
test "C3-3b3 lease owner는 admission을 한 번만 소비한다" {
    var fixture: LeaseFixture = .{};
    try fixture.init(5);
    fixture.owner.admitSettlementNoFail(&fixture.lease, fixture.binding);
    try std.testing.expect(fixture.owner.validateAdmittedSettlementBinding(&fixture.lease, fixture.binding));
    fixture.owner.consumeSettlementNoFail(&fixture.lease);
    try std.testing.expectEqual(@as(u8, 3), fixture.lease.lifecycle_raw);
    try std.testing.expect(!fixture.owner.validateSettlement(&fixture.lease));
}
test "C3-3b3 lease owner는 same-address ABA를 거부한다" {
    var fixture: LeaseFixture = .{};
    try fixture.init(6);
    const stale_binding = fixture.binding;
    fixture.owner.abortSettlementPreAdmissionNoFail(&fixture.lease);
    fixture.lease = .{};
    fixture.proof = try makeProof(readyNonce(), 7);
    fixture.binding = try fixture.owner.acquireSettlement(&fixture.lease, fixture.proof);
    try std.testing.expect(stale_binding.operation_identity.operation_incarnation != fixture.binding.operation_identity.operation_incarnation);
    try std.testing.expect(contract.validRuntimeSettlementBinding(stale_binding));
    try std.testing.expect(contract.validRuntimeSettlementBinding(fixture.binding));
    try std.testing.expect(!fixture.owner.validatePreparedSettlementBinding(&fixture.lease, stale_binding));
    try std.testing.expect(fixture.owner.validatePreparedSettlementBinding(&fixture.lease, fixture.binding));
    fixture.owner.abortSettlementPreAdmissionNoFail(&fixture.lease);
}

const LeaseFixture = struct {
    owner: lifetime.RuntimeLifetimeOwner = .{},
    lease: lifetime.RuntimeSettlementLease = .{},
    proof: contract.SettlementScratchPreflightProof = .{},
    binding: contract.RuntimeSettlementLeaseBinding = .{},

    fn init(self: *LeaseFixture, seed: u8) !void {
        const nonce = try ensureReady();
        self.proof = try makeProof(nonce, seed);
        try self.owner.initInPlace(
            0x1000 + @as(u64, seed),
            0x2000 + @as(u64, seed),
            nonce,
            seed,
        );
        self.binding = try self.owner.acquireSettlement(&self.lease, self.proof);
    }
};

fn ensureReady() !u64 {
    if (process_seal.currentReadyIdentity()) |identity| return identity.process_nonce else |err| switch (err) {
        error.NotReady => {},
        else => return err,
    }
    const nonce: u64 = 0xc33b_3000_0000_0001;
    const prepared = try process_seal.prepare(process_seal.currentProcessId(), nonce);
    process_seal.commitReady(prepared);
    return nonce;
}

fn readyNonce() u64 {
    return (process_seal.currentReadyIdentity() catch unreachable).process_nonce;
}

fn makeProof(nonce: u64, seed: u8) !contract.SettlementScratchPreflightProof {
    var proof: contract.SettlementScratchPreflightProof = .{
        .pid = process_seal.currentProcessId(),
        .process_nonce = nonce,
        .thread_id = @intCast(std.Thread.getCurrentId()),
        .ranges_digest = [_]u8{seed} ** 32,
        .pristine_digest = [_]u8{seed +% 1} ** 32,
    };
    proof.proof_seal = try contract.sealScratchPreflightProof(proof);
    return proof;
}

fn effectPlanFixture(action: contract.EffectAction, relation: contract.OutboundRelation) contract.PreparedEffectPermit {
    const present = relation != .absent;
    var value: contract.PreparedEffectPermit = .{
        .action_raw = @intFromEnum(action),
        .fd_before = 17,
        .fd_after = 17,
        .outbound_relation_raw = @intFromEnum(relation),
        .outbound_disposition_raw = @intFromEnum(if (present)
            contract.OutboundDisposition.preserved
        else
            contract.OutboundDisposition.absent),
        .outbound_offset = if (present) 0 else 0,
        .outbound_len = if (present) 16 else 0,
        .outbound_descriptor_digest = if (present) [_]u8{0x61} ** 32 else contract.zero_digest,
    };
    switch (action) {
        .none => {},
        .poison => {
            value.effect_request = .{ .tag_raw = @intFromEnum(contract.EffectRequestTag.poison), .requested_reason = .{ .present_raw = 1, .reason_raw = 7 } };
            value.first_reason_after = value.effect_request.requested_reason;
            value.unusable_after_raw = 1;
            value.fd_after = -1;
            value.fd_disposition_raw = @intFromEnum(contract.FdDisposition.detached_close_attempted);
            value.close_attempt_count = 1;
            if (present) setAllocatorCleanup(&value, .freed);
        },
        .revoke_clean => value.effect_request = .{ .tag_raw = @intFromEnum(contract.EffectRequestTag.revoke_fence), .revoke_fence = 23 },
        .revoke_cancel => {
            value.effect_request = .{ .tag_raw = @intFromEnum(contract.EffectRequestTag.revoke_fence), .revoke_fence = 23 };
            setAllocatorCleanup(&value, .cancelled);
        },
        .revoke_partial_poison => {
            value.effect_request = .{ .tag_raw = @intFromEnum(contract.EffectRequestTag.revoke_fence), .revoke_fence = 23 };
            value.first_reason_after = .{ .present_raw = 1, .reason_raw = 5 };
            value.unusable_after_raw = 1;
            value.fd_after = -1;
            value.fd_disposition_raw = @intFromEnum(contract.FdDisposition.detached_close_attempted);
            value.close_attempt_count = 1;
            value.outbound_offset = 1;
            setAllocatorCleanup(&value, .partial_poisoned);
        },
        .terminal_cleanup => {
            value.first_reason_before = .{ .present_raw = 1, .reason_raw = 6 };
            value.first_reason_after = value.first_reason_before;
            value.unusable_before_raw = 1;
            value.unusable_after_raw = 1;
            value.fd_before = -1;
            value.fd_after = -1;
            value.fd_disposition_raw = @intFromEnum(contract.FdDisposition.already_detached);
            if (present) setAllocatorCleanup(&value, .freed);
        },
    }
    return value;
}

fn setAllocatorCleanup(value: *contract.PreparedEffectPermit, disposition: contract.OutboundDisposition) void {
    value.outbound_disposition_raw = @intFromEnum(disposition);
    value.cleanup_mode_raw = @intFromEnum(contract.CleanupMode.allocator_free);
    value.cleanup_count = 1;
    value.cleanup_callback_provenance_digest = [_]u8{0x63} ** 32;
}

fn validEffectPlan(value: *const contract.PreparedEffectPermit) bool {
    const plan = contract.effectPlanFromPermit(value);
    return contract.validCanonicalEffectPlanShape(&plan);
}

test "C3-3b3 닫힌 결과 plan shape none은 보존 relation만 허용한다" {
    for ([_]contract.OutboundRelation{ .absent, .target, .sibling }) |relation| {
        var plan = effectPlanFixture(.none, relation);
        try std.testing.expect(validEffectPlan(&plan));
        plan.outbound_disposition_raw = @intFromEnum(contract.OutboundDisposition.freed);
        try std.testing.expect(!validEffectPlan(&plan));
    }
}
test "C3-3b3 닫힌 결과 plan shape poison은 fd와 outbound를 정리하고 첫 reason을 보존한다" {
    for ([_]contract.OutboundRelation{ .absent, .target, .sibling }) |relation| {
        var plan = effectPlanFixture(.poison, relation);
        try std.testing.expect(validEffectPlan(&plan));
        plan.fd_after = plan.fd_before;
        try std.testing.expect(!validEffectPlan(&plan));
    }
    var preserve = effectPlanFixture(.poison, .target);
    preserve.first_reason_before = .{ .present_raw = 1, .reason_raw = 0 };
    preserve.first_reason_after = preserve.first_reason_before;
    try std.testing.expect(validEffectPlan(&preserve));
    preserve.first_reason_after.reason_raw = 7;
    try std.testing.expect(!validEffectPlan(&preserve));
}
test "C3-3b3 닫힌 결과 plan shape revoke_clean은 target descriptor를 거부하고 형제를 보존한다" {
    for ([_]contract.OutboundRelation{ .absent, .sibling }) |relation|
        try std.testing.expect(validEffectPlan(&effectPlanFixture(.revoke_clean, relation)));
    try std.testing.expect(!validEffectPlan(&effectPlanFixture(.revoke_clean, .target)));
}
test "C3-3b3 닫힌 결과 plan shape revoke_cancel은 offset 0 대상만 취소한다" {
    var plan = effectPlanFixture(.revoke_cancel, .target);
    try std.testing.expect(validEffectPlan(&plan));
    plan.outbound_offset = 1;
    try std.testing.expect(!validEffectPlan(&plan));
    plan.outbound_offset = plan.outbound_len;
    try std.testing.expect(!validEffectPlan(&plan));
    try std.testing.expect(!validEffectPlan(&effectPlanFixture(.revoke_cancel, .sibling)));
}
test "C3-3b3 닫힌 결과 plan shape revoke_partial_poison은 부분 전송 대상만 poison한다" {
    var plan = effectPlanFixture(.revoke_partial_poison, .target);
    try std.testing.expect(validEffectPlan(&plan));
    plan.outbound_offset = 0;
    try std.testing.expect(!validEffectPlan(&plan));
    plan.outbound_offset = plan.outbound_len;
    try std.testing.expect(!validEffectPlan(&plan));
    try std.testing.expect(!validEffectPlan(&effectPlanFixture(.revoke_partial_poison, .sibling)));
}
test "C3-3b3 닫힌 결과 plan shape terminal_cleanup은 detached 또는 deferred close를 허용한다" {
    for ([_]contract.OutboundRelation{ .absent, .target, .sibling }) |relation|
        try std.testing.expect(validEffectPlan(&effectPlanFixture(.terminal_cleanup, relation)));
    var deferred = effectPlanFixture(.terminal_cleanup, .sibling);
    deferred.fd_before = 17;
    deferred.fd_disposition_raw = @intFromEnum(contract.FdDisposition.detached_close_attempted);
    deferred.close_attempt_count = 1;
    try std.testing.expect(validEffectPlan(&deferred));
    deferred.first_reason_before = .{};
    try std.testing.expect(!validEffectPlan(&deferred));
}

test "C3-3b3 payload 보호 범위는 정확·부분·오버플로 겹침을 거부한다" {
    var first: u64 = 0;
    var second: u32 = 0;
    const start = @intFromPtr(&first);
    const extent = @sizeOf(@TypeOf(first));
    try std.testing.expect(!attachment_mod.testing_api.payloadExcludesProtected(start, extent, .{ &first, &second }));
    try std.testing.expect(!attachment_mod.testing_api.payloadExcludesProtected(start - 1, 2, .{ &first, &second }));
    try std.testing.expect(!attachment_mod.testing_api.payloadExcludesProtected(start + extent - 1, 2, .{ &first, &second }));
    try std.testing.expect(attachment_mod.testing_api.payloadExcludesProtected(start + extent, 1, .{&first}));
    try std.testing.expect(!attachment_mod.testing_api.payloadExcludesProtected(std.math.maxInt(usize) - 1, 4, .{&first}));
}

test "C3-3b3 POST transcript는 모든 단일 필드 splice를 거부한다" {
    const permit = [_]u8{0x20} ** 32;
    const base: contract.EventReleasePostProjection = .{
        .registry_closed_digest = [_]u8{0x31} ** 32,
        .quarantine_closed_digest = [_]u8{0x32} ** 32,
        .pin_consumed_digest = [_]u8{0x33} ** 32,
        .callback_invoked_digest = [_]u8{0x34} ** 32,
        .owner_tombstoned_digest = [_]u8{0x35} ** 32,
        .correlation_tombstoned_digest = [_]u8{0x36} ** 32,
        .mirror_tombstoned_digest = [_]u8{0x37} ** 32,
        .callback_invocation_count = 1,
        .source_tombstone_count = 1,
    };
    const expected = contract.eventReleasePostTranscriptDigest(permit, base).?;
    var splices = [_]contract.EventReleasePostProjection{base} ** 7;
    splices[0].registry_closed_digest[0] ^= 1;
    splices[1].quarantine_closed_digest[0] ^= 1;
    splices[2].pin_consumed_digest[0] ^= 1;
    splices[3].callback_invoked_digest[0] ^= 1;
    splices[4].owner_tombstoned_digest[0] ^= 1;
    splices[5].correlation_tombstoned_digest[0] ^= 1;
    splices[6].mirror_tombstoned_digest[0] ^= 1;
    for (splices) |splice|
        try std.testing.expect(!std.crypto.timing_safe.eql(contract.Digest, expected, contract.eventReleasePostTranscriptDigest(permit, splice).?));
    var bad_count = base;
    bad_count.callback_invocation_count = 0;
    try std.testing.expect(contract.eventReleasePostTranscriptDigest(permit, bad_count) == null);
    bad_count = base;
    bad_count.source_tombstone_count = 2;
    try std.testing.expect(contract.eventReleasePostTranscriptDigest(permit, bad_count) == null);
}

test "C3-3b3 재시도 callback 첫 Busy는 변경을 남기지 않는다" {
    try runActualPreparedSettlement(.{ .contention_count = 1 });
}
test "C3-3b3 재시도 callback 둘째 Busy는 변경을 남기지 않는다" {
    try runActualPreparedSettlement(.{ .contention_count = 2 });
}
test "C3-3b3 재시도 callback 셋째 Busy 뒤 같은 attempt가 성공한다" {
    try runActualPreparedSettlement(.{ .contention_count = 3 });
}
test "C3-3b3 재시도 callback 중 동일 대상과 형제 reentry는 Busy다" {
    try runActualPreparedSettlement(.{ .reentry = true });
}
test "C3-3b3 재시도 callback은 첫 poison reason을 보존한다" {
    try runActualPreparedSettlement(.{ .preserve_first_reason = true });
}
test "C3-3b3 재시도 callback은 형제 outbound를 byte-exact 보존한다" {
    try runActualPreparedSettlement(.{ .preserve_sibling_outbound = true });
}

test "C3-3b3 proof-loss child는 선택된 허용 stage를 dispatch한다" {
    if (ProofLossRunnerChannel.maru_c3b3_death_stage_raw == 0) return;
    if (ProofLossRunnerChannel.maru_c3b3_death_stage_raw > 9) std.process.exit(122);
    var stat: std.posix.Stat = undefined;
    if (std.c.fstat(settlement_death_marker_fd, &stat) != 0 or !std.posix.S.ISFIFO(stat.mode))
        std.process.exit(122);
    if (ProofLossRunnerChannel.maru_c3b3_death_stage_raw == 4) while (true) {
        var delay = [_]std.c.pollfd{};
        _ = std.c.poll(&delay, 0, 1000);
    };
    if (ProofLossRunnerChannel.maru_c3b3_death_stage_raw == 5) {
        writeSettlementDeathMarker(settlement_death_marker_fd, .ready);
        while (true) {
            var delay = [_]std.c.pollfd{};
            _ = std.c.poll(&delay, 0, 1000);
        }
    }
    if (ProofLossRunnerChannel.maru_c3b3_death_stage_raw == 6) {
        writeSettlementDeathMarker(settlement_death_marker_fd, .ready);
        _ = std.c.close(settlement_death_marker_fd);
        while (true) {
            var delay = [_]std.c.pollfd{};
            _ = std.c.poll(&delay, 0, 1000);
        }
    }
    if (ProofLossRunnerChannel.maru_c3b3_death_stage_raw == 7) {
        var marker_count: usize = 0;
        while (marker_count < 17) : (marker_count += 1)
            writeSettlementDeathMarker(settlement_death_marker_fd, .ready);
        while (true) {
            var delay = [_]std.c.pollfd{};
            _ = std.c.poll(&delay, 0, 1000);
        }
    }
    if (ProofLossRunnerChannel.maru_c3b3_death_stage_raw == 8) {
        var marker_count: usize = 0;
        while (marker_count < 16) : (marker_count += 1)
            writeSettlementDeathMarker(settlement_death_marker_fd, .ready);
        std.process.exit(73);
    }
    if (ProofLossRunnerChannel.maru_c3b3_death_stage_raw == 9) {
        _ = std.c.raise(std.c.SIG.ABRT);
        std.c._exit(126);
    }
    const selected: SettlementDeathStage = switch (ProofLossRunnerChannel.maru_c3b3_death_stage_raw) {
        1 => .post_admission,
        2 => .post_callback,
        3 => .client_post_callback,
        else => unreachable,
    };
    try runActualPreparedSettlement(.{ .death_stage = selected });
    std.process.exit(121);
}

test "C3-3b3 subprocess는 fork inherited authority를 admission 전에 거부한다" {
    if (ProofLossRunnerChannel.maru_c3b3_death_child_path_len == 0) return error.SkipZigTest;
    try std.testing.expect(!forkProjectionContainsPointer(ForkRejectedSettlementProjection));
    try verifyRejectedSettlementArgvMatrix();
    try runActualPreparedSettlement(.{ .pre_admission_fork = true });
}
test "C3-3b3 subprocess는 post-admission proof loss에서 fail-stop한다" {
    if (ProofLossRunnerChannel.maru_c3b3_death_child_path_len == 0) return error.SkipZigTest;
    try runSettlementDeathChild(.post_admission, &.{ 0x41, 0x42, 0x47, 0x48 });
}
test "C3-3b3 subprocess는 post-callback proof loss에서 fail-stop한다" {
    if (ProofLossRunnerChannel.maru_c3b3_death_child_path_len == 0) return error.SkipZigTest;
    try runSettlementDeathChild(.post_callback, &.{ 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48 });
}
test "C3-3b3 subprocess는 Client POST callback drift에서 fail-stop한다" {
    if (ProofLossRunnerChannel.maru_c3b3_death_child_path_len == 0) return error.SkipZigTest;
    try runSettlementDeathChild(.client_post_callback, &.{ 0x41, 0x42, 0x44, 0x45, 0x46, 0x47, 0x48 });
}
test "C3-3b3 subprocess watchdog은 무응답·열린 pipe·EOF 이후 hang·exact cap EOF·trailing marker·signal을 구분한다" {
    if (ProofLossRunnerChannel.maru_c3b3_death_child_path_len == 0) return error.SkipZigTest;
    const no_byte = try observeSettlementDeathChild(.first_byte_hang);
    try std.testing.expectEqual(@as(usize, 0), no_byte.transcript_len);
    try expectSettlementDeadlineKill(no_byte);
    try std.testing.expect(!no_byte.eof_before_deadline);

    const open_pipe = try observeSettlementDeathChild(.prefix_pipe_hang);
    try std.testing.expectEqualSlices(u8, &.{0x41}, open_pipe.transcript[0..open_pipe.transcript_len]);
    try expectSettlementDeadlineKill(open_pipe);
    try std.testing.expect(!open_pipe.eof_before_deadline);

    const eof_alive = try observeSettlementDeathChild(.eof_alive);
    try std.testing.expectEqualSlices(u8, &.{0x41}, eof_alive.transcript[0..eof_alive.transcript_len]);
    try expectSettlementDeadlineKill(eof_alive);
    try std.testing.expect(eof_alive.eof_before_deadline);

    const trailing = try observeSettlementDeathChild(.trailing_marker_hang);
    try std.testing.expectEqual(@as(usize, 16), trailing.transcript_len);
    try expectSettlementDeadlineKill(trailing);
    try std.testing.expect(trailing.trailing_marker_seen);

    const exact_cap = try observeSettlementDeathChild(.exact_cap_exit);
    try std.testing.expectEqual(@as(usize, 16), exact_cap.transcript_len);
    try std.testing.expect(exact_cap.eof and exact_cap.eof_before_deadline and exact_cap.reaped);
    try std.testing.expect(!exact_cap.killed_at_deadline and !exact_cap.trailing_marker_seen);
    const exact_cap_status: u32 = @bitCast(exact_cap.status);
    try std.testing.expect(std.c.W.IFEXITED(exact_cap_status));
    try std.testing.expectEqual(@as(u8, 73), @as(u8, @intCast(std.c.W.EXITSTATUS(exact_cap_status))));

    const signaled = try observeSettlementDeathChild(.signal_exit);
    try std.testing.expect(!signaled.killed_at_deadline);
    try std.testing.expect(signaled.reaped and signaled.eof);
    try std.testing.expectEqual(@as(usize, 0), signaled.transcript_len);
    const unsigned: u32 = @bitCast(signaled.status);
    try std.testing.expect(std.c.W.IFSIGNALED(unsigned));
    try std.testing.expectEqual(std.c.SIG.ABRT, std.c.W.TERMSIG(unsigned));
}
