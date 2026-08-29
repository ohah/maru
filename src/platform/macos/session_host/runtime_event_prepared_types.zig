//! Pointer-free policy and budget values for prepared runtime events.
//!
//! The eventual pending owner stores raw bytes and owning observations elsewhere.  This leaf only
//! decides which semantic arm should be published and proves its retained-byte budget, so allocator
//! callbacks and transport ownership cannot silently change policy.

const std = @import("std");
const maru = @import("maru");
const terminal_types = maru.terminal;
const host_protocol = maru.session.host_protocol;
const client_poison = @import("client_poison.zig");
const decision_seal = @import("runtime_prepared_decision_seal.zig");

pub const PreparedEventTag = decision_seal.PreparedEventTag;
pub const EffectTag = decision_seal.EffectTag;
pub const PreparationFailure = decision_seal.PreparationFailure;
pub const DecisionSealProjection = decision_seal.Projection;

pub const EffectRequest = union(EffectTag) {
    none,
    poison: client_poison.ConnectionReason,
    revoke_fence: u64,
};

pub const PreparedResizeCommit = struct {
    size: terminal_types.Size,
    resize_generation: u64,
};

pub const PreparedEventProjection = union(PreparedEventTag) {
    ignored,
    ended,
    invalidated,
    resize_noop,
    resize_commit: PreparedResizeCommit,
    metadata_noop,
    metadata_commit,
    revoked: u64,
    failure: PreparationFailure,
};

pub const PreparedDecision = struct {
    projection: PreparedEventProjection,
    effect: EffectRequest,
    /// Exact probe correlation carried through PendingEventOwner. Zero means an ordinary event.
    observation_probe_nonce: u64 = 0,
};

comptime {
    if (@intFromEnum(client_poison.ConnectionReason.local_resource_exhausted) !=
        decision_seal.local_resource_exhausted_reason_raw)
        @compileError("local resource poison wire mapping drift");
    if (@intFromEnum(client_poison.ConnectionReason.peer_contract_violation) !=
        decision_seal.peer_contract_violation_reason_raw)
        @compileError("peer contract poison wire mapping drift");
}

pub fn sealProjection(value: PreparedDecision) DecisionSealProjection {
    var out: DecisionSealProjection = .{
        .bound_raw = 1,
        .prepared_tag_raw = @intFromEnum(std.meta.activeTag(value.projection)),
        .effect_tag_raw = @intFromEnum(std.meta.activeTag(value.effect)),
        .observation_probe_nonce = value.observation_probe_nonce,
    };
    switch (value.projection) {
        .resize_commit => |resize| {
            out.cols = resize.size.cols;
            out.rows = resize.size.rows;
            out.semantic_generation = resize.resize_generation;
        },
        .revoked => |fence| out.semantic_generation = fence,
        .failure => |failure_value| out.failure_raw = @intFromEnum(failure_value),
        else => {},
    }
    switch (value.effect) {
        .none, .revoke_fence => {},
        .poison => |reason| out.connection_reason_raw = @intFromEnum(reason),
    }
    return out;
}

pub const ResizePolicyInput = struct {
    baseline_present: bool,
    current_generation: u64,
    current_size: terminal_types.Size,
    incoming_generation: u64,
    incoming_size: terminal_types.Size,
};

pub const MetadataPolicyInput = struct {
    current_revision: u64,
    incoming_revision: u64,
    semantic_equal: bool,
    content_equal: bool,
};

pub const RevokedPolicyInput = struct {
    successor_fence: u64,
    successor_fence_valid: bool,
};

pub const PolicyInput = union(enum(u8)) {
    ended,
    invalidated,
    resize: ResizePolicyInput,
    metadata: MetadataPolicyInput,
    revoked: RevokedPolicyInput,
    violation,
    connection_closed,
    out_of_memory,
    local_resource_exhausted,
};

/// Reduces an already classified event and immutable runtime snapshot to one closed publication.
pub fn decide(input: PolicyInput) PreparedDecision {
    return switch (input) {
        .ended => decision(.ended, .none),
        .invalidated => decision(.invalidated, .none),
        .resize => |value| decideResize(value),
        .metadata => |value| decideMetadata(value),
        .revoked => |value| if (value.successor_fence_valid)
            decision(
                .{ .revoked = value.successor_fence },
                .{ .revoke_fence = value.successor_fence },
            )
        else
            protocolFailure(),
        .violation => protocolFailure(),
        .connection_closed => failure(.connection_closed, .none),
        .out_of_memory => failure(
            .out_of_memory,
            .{ .poison = .local_resource_exhausted },
        ),
        .local_resource_exhausted => failure(
            .local_resource_exhausted,
            .{ .poison = .local_resource_exhausted },
        ),
    };
}

fn decideResize(input: ResizePolicyInput) PreparedDecision {
    if (!input.baseline_present or input.incoming_generation > input.current_generation)
        return decision(.{ .resize_commit = .{
            .size = input.incoming_size,
            .resize_generation = input.incoming_generation,
        } }, .none);
    if (input.incoming_generation < input.current_generation or
        std.meta.eql(input.incoming_size, input.current_size))
        return decision(.resize_noop, .none);
    return protocolFailure();
}

fn decideMetadata(input: MetadataPolicyInput) PreparedDecision {
    if (input.incoming_revision < input.current_revision)
        return decision(.ignored, .none);
    if (input.incoming_revision > input.current_revision)
        return decision(.metadata_commit, .none);
    if (input.semantic_equal and input.content_equal)
        return decision(.metadata_noop, .none);
    return protocolFailure();
}

fn protocolFailure() PreparedDecision {
    return failure(.protocol_error, .{ .poison = .peer_contract_violation });
}

fn failure(value: PreparationFailure, effect: EffectRequest) PreparedDecision {
    return decision(.{ .failure = value }, effect);
}

fn decision(projection: PreparedEventProjection, effect: EffectRequest) PreparedDecision {
    return .{ .projection = projection, .effect = effect };
}

pub const owner_count = 7;
pub const PreparationBudgetInput = struct {
    payload_len: u64,
    dto_capacity: u64,
    next_capacity: [owner_count]u64,
    old_capacity: [owner_count]u64,
    old_owner_exact: bool,
};

pub const PreparationBudget = struct {
    next_capacity: u64,
    old_capacity: u64,
    prepare_peak: u64,
    published_peak: u64,
};

pub const BudgetError = error{
    LocalResourceExhausted,
    LocalInvariant,
};

/// Checks both the four-part preparation peak and the three-part published rehash peak.
pub fn checkBudget(input: PreparationBudgetInput) BudgetError!PreparationBudget {
    if (!input.old_owner_exact) return error.LocalInvariant;

    const component_cap: u64 = host_protocol.max_control_json;
    if (input.payload_len > component_cap or input.dto_capacity > component_cap)
        return error.LocalResourceExhausted;

    const next_capacity = try sumCapacities(input.next_capacity, component_cap);
    const old_capacity = try sumCapacities(input.old_capacity, component_cap);
    const prepare_cap = std.math.mul(u64, component_cap, 4) catch
        return error.LocalResourceExhausted;
    const published_cap = std.math.mul(u64, component_cap, 3) catch
        return error.LocalResourceExhausted;

    var prepare_peak = std.math.add(u64, input.payload_len, input.dto_capacity) catch
        return error.LocalResourceExhausted;
    prepare_peak = std.math.add(u64, prepare_peak, next_capacity) catch
        return error.LocalResourceExhausted;
    prepare_peak = std.math.add(u64, prepare_peak, old_capacity) catch
        return error.LocalResourceExhausted;

    var published_peak = std.math.add(u64, input.payload_len, next_capacity) catch
        return error.LocalResourceExhausted;
    published_peak = std.math.add(u64, published_peak, old_capacity) catch
        return error.LocalResourceExhausted;
    if (prepare_peak > prepare_cap or published_peak > published_cap)
        return error.LocalResourceExhausted;

    return .{
        .next_capacity = next_capacity,
        .old_capacity = old_capacity,
        .prepare_peak = prepare_peak,
        .published_peak = published_peak,
    };
}

fn sumCapacities(values: [owner_count]u64, component_cap: u64) BudgetError!u64 {
    var total: u64 = 0;
    for (values) |value| {
        if (value > component_cap) return error.LocalResourceExhausted;
        total = std.math.add(u64, total, value) catch
            return error.LocalResourceExhausted;
    }
    return total;
}

fn expectTags(actual: PreparedDecision, projection: PreparedEventTag, effect: EffectTag) !void {
    try std.testing.expectEqual(projection, std.meta.activeTag(actual.projection));
    try std.testing.expectEqual(effect, std.meta.activeTag(actual.effect));
}

fn typeContainsForbidden(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .optional, .error_union, .@"fn" => true,
        .array => |info| typeContainsForbidden(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field|
                if (typeContainsForbidden(field.type)) break :blk true;
            break :blk false;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field|
                if (typeContainsForbidden(field.type)) break :blk true;
            break :blk false;
        },
        else => false,
    };
}

test "C3-3b2b3 prepared tag ABI is stable" {
    inline for (.{
        .{ PreparedEventTag.ignored, 0 },         .{ PreparedEventTag.ended, 1 },
        .{ PreparedEventTag.invalidated, 2 },     .{ PreparedEventTag.resize_noop, 3 },
        .{ PreparedEventTag.resize_commit, 4 },   .{ PreparedEventTag.metadata_noop, 5 },
        .{ PreparedEventTag.metadata_commit, 6 }, .{ PreparedEventTag.revoked, 7 },
        .{ PreparedEventTag.failure, 8 },
    }) |case| try std.testing.expectEqual(@as(u8, case[1]), @intFromEnum(case[0]));
    try std.testing.expectEqual(@as(u8, 0), @intFromEnum(EffectTag.none));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(EffectTag.poison));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(EffectTag.revoke_fence));
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(PreparationFailure.out_of_memory));
    try std.testing.expectEqual(@as(u8, 4), @intFromEnum(PreparationFailure.connection_closed));
}

test "C3-3b2b3 prepared values recursively contain no pointers or ownership" {
    inline for (.{ PreparedEventProjection, EffectRequest, PreparedDecision, PolicyInput, PreparationBudgetInput, PreparationBudget }) |T|
        try std.testing.expect(!typeContainsForbidden(T));
}

test "C3-3b2b3 prepared resize policy is exhaustive" {
    const base = terminal_types.Size{ .cols = 80, .rows = 24 };
    const changed = terminal_types.Size{ .cols = 120, .rows = 40 };
    const cases = .{
        .{ ResizePolicyInput{ .baseline_present = false, .current_generation = 9, .current_size = base, .incoming_generation = 1, .incoming_size = changed }, PreparedEventTag.resize_commit, EffectTag.none },
        .{ ResizePolicyInput{ .baseline_present = true, .current_generation = 9, .current_size = base, .incoming_generation = 10, .incoming_size = changed }, PreparedEventTag.resize_commit, EffectTag.none },
        .{ ResizePolicyInput{ .baseline_present = true, .current_generation = 9, .current_size = base, .incoming_generation = 8, .incoming_size = changed }, PreparedEventTag.resize_noop, EffectTag.none },
        .{ ResizePolicyInput{ .baseline_present = true, .current_generation = 9, .current_size = base, .incoming_generation = 9, .incoming_size = base }, PreparedEventTag.resize_noop, EffectTag.none },
        .{ ResizePolicyInput{ .baseline_present = true, .current_generation = 9, .current_size = base, .incoming_generation = 9, .incoming_size = changed }, PreparedEventTag.failure, EffectTag.poison },
    };
    inline for (cases) |case| try expectTags(decide(.{ .resize = case[0] }), case[1], case[2]);
}

test "C3-3b2b3 prepared metadata policy is exhaustive" {
    const cases = .{
        .{ MetadataPolicyInput{ .current_revision = 8, .incoming_revision = 7, .semantic_equal = false, .content_equal = false }, PreparedEventTag.ignored, EffectTag.none },
        .{ MetadataPolicyInput{ .current_revision = 8, .incoming_revision = 8, .semantic_equal = true, .content_equal = true }, PreparedEventTag.metadata_noop, EffectTag.none },
        .{ MetadataPolicyInput{ .current_revision = 8, .incoming_revision = 8, .semantic_equal = false, .content_equal = true }, PreparedEventTag.failure, EffectTag.poison },
        .{ MetadataPolicyInput{ .current_revision = 8, .incoming_revision = 8, .semantic_equal = true, .content_equal = false }, PreparedEventTag.failure, EffectTag.poison },
        .{ MetadataPolicyInput{ .current_revision = 8, .incoming_revision = 9, .semantic_equal = false, .content_equal = false }, PreparedEventTag.metadata_commit, EffectTag.none },
    };
    inline for (cases) |case| try expectTags(decide(.{ .metadata = case[0] }), case[1], case[2]);
}

test "C3-3b2b3 prepared terminal revoke and failure policy is exhaustive" {
    try expectTags(decide(.ended), .ended, .none);
    try expectTags(decide(.invalidated), .invalidated, .none);
    try expectTags(decide(.{ .revoked = .{ .successor_fence = 11, .successor_fence_valid = true } }), .revoked, .revoke_fence);
    try expectTags(decide(.{ .revoked = .{ .successor_fence = 11, .successor_fence_valid = false } }), .failure, .poison);
    try expectTags(decide(.violation), .failure, .poison);
    try expectTags(decide(.connection_closed), .failure, .none);
    try expectTags(decide(.out_of_memory), .failure, .poison);
    try expectTags(decide(.local_resource_exhausted), .failure, .poison);
}

test "C3-3b2b3 prepared budget accepts cap and rejects cap plus one" {
    const cap: u64 = host_protocol.max_control_json;
    var input = PreparationBudgetInput{
        .payload_len = cap,
        .dto_capacity = cap,
        .next_capacity = [_]u64{0} ** owner_count,
        .old_capacity = [_]u64{0} ** owner_count,
        .old_owner_exact = true,
    };
    input.next_capacity[0] = cap;
    input.old_capacity[0] = cap;
    const result = try checkBudget(input);
    try std.testing.expectEqual(4 * cap, result.prepare_peak);
    try std.testing.expectEqual(3 * cap, result.published_peak);

    input.dto_capacity += 1;
    try std.testing.expectError(error.LocalResourceExhausted, checkBudget(input));
}

test "C3-3b2b3 prepared budget rejects component sum overflow and inexact old owner" {
    var input = PreparationBudgetInput{
        .payload_len = 0,
        .dto_capacity = 0,
        .next_capacity = [_]u64{0} ** owner_count,
        .old_capacity = [_]u64{0} ** owner_count,
        .old_owner_exact = true,
    };
    input.next_capacity[0] = std.math.maxInt(u64);
    try std.testing.expectError(error.LocalResourceExhausted, checkBudget(input));
    input.next_capacity[0] = 0;
    input.old_owner_exact = false;
    try std.testing.expectError(error.LocalInvariant, checkBudget(input));
}
