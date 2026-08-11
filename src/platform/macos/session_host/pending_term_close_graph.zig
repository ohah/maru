//! 창 단위 terminal close를 topology 변경 전에 한 묶음으로 봉인하는 final-address 권위다.
//!
//! 이 모듈은 AppSession이나 backend를 역참조하지 않는다. 호출자가 현재 graph membership을 매 단계 다시
//! 투영하고, 이 leaf는 그 scalar projection과 허용된 lifecycle 전이만 process seal로 인증한다.

const std = @import("std");
const process_seal = @import("process_seal_service.zig");

pub const Seal = process_seal.CleanupSeal;
pub const Digest = [32]u8;

pub const RequestKind = enum(u8) {
    close_and_detach = 1,
};

pub const TermLifecycle = enum(u8) {
    pristine = 0,
    reserved = 1,
    backend_pending = 2,
    backend_complete = 3,
    consumed = 4,
    aborted = 5,
};

pub const GraphLifecycle = enum(u8) {
    pristine = 0,
    prepared = 1,
    published = 2,
    complete = 3,
    consumed = 4,
};

pub const TargetProjection = struct {
    term_addr: u64,
    surface_id: u64,
    handle: u64,
    term_close_generation: u64,
};

pub const PendingTermClose = struct {
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    self_addr: u64 = 0,
    app_session_addr: u64 = 0,
    app_session_generation: u64 = 0,
    term_addr: u64 = 0,
    surface_id: u64 = 0,
    handle: u64 = 0,
    term_close_generation: u64 = 0,
    request_generation: u64 = 0,
    request_kind_raw: u8 = 0,
    phase_raw: u8 = 0,
    graph_seal: Seal = [_]u8{0} ** 32,
    seal: Seal = [_]u8{0} ** 32,
};

pub const PendingTermCloseGraph = struct {
    pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    self_addr: u64 = 0,
    app_session_addr: u64 = 0,
    app_session_generation: u64 = 0,
    graph_generation: u64 = 0,
    target_count: u32 = 0,
    target_digest: Digest = [_]u8{0} ** 32,
    lifecycle_raw: u8 = 0,
    seal: Seal = [_]u8{0} ** 32,
};

pub fn fatalProofLoss() noreturn {
    process_seal.fatalIntegrity(.proof_loss);
}

pub fn targetDigest(targets: []const TargetProjection) Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hashInt(&hasher, u32, @intCast(targets.len));
    for (targets) |target| {
        hashInt(&hasher, u64, target.term_addr);
        hashInt(&hasher, u64, target.surface_id);
        hashInt(&hasher, u64, target.handle);
        hashInt(&hasher, u64, target.term_close_generation);
    }
    return hasher.finalResult();
}

pub fn prepareGraph(
    graph: *PendingTermCloseGraph,
    app_session_addr: u64,
    app_session_generation: u64,
    graph_generation: u64,
    targets: []const TargetProjection,
) !void {
    if (!std.meta.eql(graph.*, PendingTermCloseGraph{}) or app_session_addr == 0 or
        app_session_generation == 0 or graph_generation == 0 or targets.len == 0 or
        targets.len > std.math.maxInt(u32)) return error.InvalidOwner;
    const ready = try process_seal.currentReadyIdentity();
    graph.* = .{
        .pid = ready.pid,
        .process_nonce = ready.process_nonce,
        .thread_id = @intCast(std.Thread.getCurrentId()),
        .self_addr = @intFromPtr(graph),
        .app_session_addr = app_session_addr,
        .app_session_generation = app_session_generation,
        .graph_generation = graph_generation,
        .target_count = @intCast(targets.len),
        .target_digest = targetDigest(targets),
        .lifecycle_raw = @intFromEnum(GraphLifecycle.prepared),
    };
    errdefer graph.* = .{};
    graph.seal = try graphSeal(graph);
    if (!validGraph(graph, app_session_addr, targets)) return error.InvalidOwner;
}

pub fn prepareTerm(
    owner: *PendingTermClose,
    graph: *const PendingTermCloseGraph,
    target: TargetProjection,
    request_generation: u64,
) !void {
    if (!std.meta.eql(owner.*, PendingTermClose{}) or !validGraphHeader(graph) or request_generation == 0)
        return error.InvalidOwner;
    owner.* = .{
        .pid = graph.pid,
        .process_nonce = graph.process_nonce,
        .thread_id = graph.thread_id,
        .self_addr = @intFromPtr(owner),
        .app_session_addr = graph.app_session_addr,
        .app_session_generation = graph.app_session_generation,
        .term_addr = target.term_addr,
        .surface_id = target.surface_id,
        .handle = target.handle,
        .term_close_generation = target.term_close_generation,
        .request_generation = request_generation,
        .request_kind_raw = @intFromEnum(RequestKind.close_and_detach),
        .phase_raw = @intFromEnum(TermLifecycle.reserved),
        .graph_seal = graph.seal,
    };
    errdefer owner.* = .{};
    owner.seal = try termSeal(owner);
    if (!validTerm(owner, graph, target)) return error.InvalidOwner;
}

pub fn publishGraph(graph: *PendingTermCloseGraph, targets: []const TargetProjection) !void {
    if (!validGraph(graph, graph.app_session_addr, targets) or
        graph.lifecycle_raw != @intFromEnum(GraphLifecycle.prepared)) return error.InvalidOwner;
    graph.lifecycle_raw = @intFromEnum(GraphLifecycle.published);
    graph.seal = try graphSeal(graph);
}

pub fn advanceGraph(graph: *PendingTermCloseGraph, targets: []const TargetProjection, next: GraphLifecycle) !void {
    if (!validGraph(graph, graph.app_session_addr, targets)) return error.InvalidOwner;
    const current = std.enums.fromInt(GraphLifecycle, graph.lifecycle_raw) orelse return error.InvalidOwner;
    const allowed = switch (current) {
        .published => next == .complete,
        .complete => next == .consumed,
        else => false,
    };
    if (!allowed) return error.InvalidOwner;
    graph.lifecycle_raw = @intFromEnum(next);
    graph.seal = try graphSeal(graph);
}

pub fn advanceTerm(owner: *PendingTermClose, graph: *const PendingTermCloseGraph, target: TargetProjection, next: TermLifecycle) !void {
    if (!validTerm(owner, graph, target)) return error.InvalidOwner;
    const current = std.enums.fromInt(TermLifecycle, owner.phase_raw) orelse return error.InvalidOwner;
    const allowed = switch (current) {
        .reserved => next == .backend_pending or next == .backend_complete or next == .aborted,
        .backend_pending => next == .backend_pending or next == .backend_complete,
        .backend_complete => next == .consumed,
        else => false,
    };
    if (!allowed) return error.InvalidOwner;
    owner.phase_raw = @intFromEnum(next);
    owner.seal = try termSeal(owner);
}

pub fn validGraph(graph: *const PendingTermCloseGraph, app_session_addr: u64, targets: []const TargetProjection) bool {
    if (!validGraphHeader(graph) or graph.app_session_addr != app_session_addr or
        graph.target_count != targets.len or !std.mem.eql(u8, &graph.target_digest, &targetDigest(targets))) return false;
    const expected = graphSeal(graph) catch return false;
    return std.crypto.timing_safe.eql(Seal, expected, graph.seal);
}

pub fn validTerm(owner: *const PendingTermClose, graph: *const PendingTermCloseGraph, target: TargetProjection) bool {
    if (!validGraphHeader(graph) or owner.self_addr != @intFromPtr(owner) or owner.pid != graph.pid or
        owner.process_nonce != graph.process_nonce or owner.thread_id != graph.thread_id or
        owner.app_session_addr != graph.app_session_addr or owner.app_session_generation != graph.app_session_generation or
        owner.term_addr != target.term_addr or owner.surface_id != target.surface_id or owner.handle != target.handle or
        owner.term_close_generation != target.term_close_generation or owner.request_generation == 0 or
        owner.request_kind_raw != @intFromEnum(RequestKind.close_and_detach) or
        !std.mem.eql(u8, &owner.graph_seal, &graph.seal)) return false;
    if (std.enums.fromInt(TermLifecycle, owner.phase_raw) == null) return false;
    const expected = termSeal(owner) catch return false;
    return std.crypto.timing_safe.eql(Seal, expected, owner.seal);
}

fn validGraphHeader(graph: *const PendingTermCloseGraph) bool {
    if (graph.self_addr != @intFromPtr(graph) or graph.app_session_addr == 0 or graph.app_session_generation == 0 or
        graph.graph_generation == 0 or graph.target_count == 0 or graph.thread_id != @as(u64, @intCast(std.Thread.getCurrentId()))) return false;
    if (std.enums.fromInt(GraphLifecycle, graph.lifecycle_raw) == null) return false;
    const ready = process_seal.currentReadyIdentity() catch return false;
    return graph.pid == ready.pid and graph.process_nonce == ready.process_nonce;
}

fn graphSeal(graph: *const PendingTermCloseGraph) process_seal.ReadyError!Seal {
    return process_seal.pendingTermCloseGraphSeal(graph.pid, graph.process_nonce, .{
        .self_addr = @intFromPtr(graph),
        .app_session_addr = graph.app_session_addr,
        .app_session_generation = graph.app_session_generation,
        .graph_generation = graph.graph_generation,
        .target_count = graph.target_count,
        .target_digest = graph.target_digest,
        .lifecycle_raw = graph.lifecycle_raw,
    });
}

fn termSeal(owner: *const PendingTermClose) process_seal.ReadyError!Seal {
    return process_seal.pendingTermCloseSeal(owner.pid, owner.process_nonce, .{
        .self_addr = @intFromPtr(owner),
        .app_session_addr = owner.app_session_addr,
        .app_session_generation = owner.app_session_generation,
        .term_addr = owner.term_addr,
        .surface_id = owner.surface_id,
        .handle = owner.handle,
        .term_close_generation = owner.term_close_generation,
        .request_generation = owner.request_generation,
        .request_kind_raw = owner.request_kind_raw,
        .phase_raw = owner.phase_raw,
        .graph_seal = owner.graph_seal,
    });
}

fn hashInt(hasher: *std.crypto.hash.sha2.Sha256, comptime T: type, value: T) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

test "C3-3b5 close graph는 final address와 exact target membership을 봉인한다" {
    _ = try @import("remote_close_authority.zig").testing.ensureSealReady();
    var graph: PendingTermCloseGraph = .{};
    const targets = [_]TargetProjection{
        .{ .term_addr = 0x1000, .surface_id = 1, .handle = 11, .term_close_generation = 7 },
        .{ .term_addr = 0x2000, .surface_id = 2, .handle = 22, .term_close_generation = 8 },
    };
    try prepareGraph(&graph, 0xA000, 3, 9, &targets);
    try std.testing.expect(validGraph(&graph, 0xA000, &targets));
    const copied = graph;
    try std.testing.expect(!validGraph(&copied, 0xA000, &targets));
    var drifted = targets;
    drifted[1].handle += 1;
    try std.testing.expect(!validGraph(&graph, 0xA000, &drifted));
}

test "C3-3b5 close graph의 Term reservation은 복사와 phase replay를 거부한다" {
    _ = try @import("remote_close_authority.zig").testing.ensureSealReady();
    var graph: PendingTermCloseGraph = .{};
    const targets = [_]TargetProjection{
        .{ .term_addr = 0x3000, .surface_id = 3, .handle = 33, .term_close_generation = 10 },
    };
    try prepareGraph(&graph, 0xA000, 4, 10, &targets);
    var owner: PendingTermClose = .{};
    try prepareTerm(&owner, &graph, targets[0], 1);
    try std.testing.expect(validTerm(&owner, &graph, targets[0]));
    const copied = owner;
    try std.testing.expect(!validTerm(&copied, &graph, targets[0]));
    try advanceTerm(&owner, &graph, targets[0], .backend_pending);
    try std.testing.expectError(error.InvalidOwner, advanceTerm(&owner, &graph, targets[0], .reserved));
}
