const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("posix_walk.zig").posixWalk;
/// 원장 판정 규칙의 단일 출처 — digest 가 무엇을 덮고 count 가 무엇을 세는지는 그 파일이 소유한다.
const source_digest = @import("source_digest.zig");

const ClientReceiverClass = enum { guarded, construction, unchecked, observation };
const ClientReceiverSpec = struct {
    name: []const u8,
    receiver_type: []const u8,
    class: ClientReceiverClass,
};
const ClientGuardProof = struct {
    receiver: []const u8,
    funnel: []const u8,
    gate: []const u8,
    gate_prefix: []const u8 = "self",
    gate_depth: usize = 1,
    release: []const u8 = "endPublicMutation",
    release_prefix: []const u8 = "self",
    release_depth: usize = 1,
    pre_gate_self_fields: []const []const u8 = &.{},
};
const ClientConstructionUse = struct {
    path: []const u8,
    enclosing_container: []const u8 = "<derived>",
    enclosing_fn: []const u8,
    count: usize = 1,
};
const ClientConstructionKind = enum { generation_init, external_transfer, external_adoption, external_teardown };
const ClientConstructionProof = struct {
    receiver: []const u8,
    kind: ClientConstructionKind,
    uses: []const ClientConstructionUse,
};
const ClientReflectionOwnerProof = struct {
    path: []const u8,
    container: []const u8 = "<root>",
    function: []const u8,
    expression: []const u8,
    count: usize,
};
const client_reflection_owners = [_]ClientReflectionOwnerProof{
    .{ .path = "src/platform/macos/session_host/pending_event_settlement.zig", .function = "hashPristineRecord", .expression = "@field(T{},field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_settlement.zig", .function = "hashSemanticValue", .expression = "@field(value,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client.zig", .function = "canonicalExternalInventory", .expression = "@field(source,entry[1])", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client.zig", .function = "canonicalExternalInventory", .expression = "@field(source,entry[2])", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client.zig", .function = "canonicalExternalInventory", .expression = "@field(source,entry[3])", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client.zig", .function = "canonicalExternalInventory", .expression = "@field(source,entry[4])", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client.zig", .function = "canonicalExternalInventory", .expression = "@field(result,entry[1])", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client.zig", .function = "canonicalExternalInventory", .expression = "@field(result,entry[2])", .count = 1 },
    .{ .path = "src/platform/macos/session_host/handoff_codec.zig", .function = "encodeValue", .expression = "@field(value.*,field.name)", .count = 2 },
    .{ .path = "src/platform/macos/session_host/handoff_codec.zig", .function = "encodeValue", .expression = "@field(Tag,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/handoff_codec.zig", .function = "decodeValue", .expression = "@field(result,field.name)", .count = 2 },
    .{ .path = "src/platform/macos/session_host/handoff_codec.zig", .function = "decodeValue", .expression = "@field(Tag,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/handoff_codec.zig", .function = "deinitValue", .expression = "@field(value.*,field.name)", .count = 2 },
    .{ .path = "src/platform/macos/session_host/handoff_codec.zig", .function = "deinitValue", .expression = "@field(Tag,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/handoff_codec.zig", .function = "encodeCoreFields", .expression = "@field(core.*,spec.name)", .count = 2 },
    .{ .path = "src/platform/macos/session_host/handoff_codec.zig", .function = "replaceCoreField", .expression = "@field(core.*,spec.name)", .count = 3 },
    .{ .path = "src/platform/macos/session_host/client_external_adoption.zig", .function = "transferSliceAuthority", .expression = "@field(value,primary_field)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client_external_adoption.zig", .function = "transferSliceAuthority", .expression = "@field(value,cleanup_field)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client_external_adoption.zig", .function = "transferSliceAuthority", .expression = "@field(value,addr_field)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client_external_adoption.zig", .function = "transferSliceAuthority", .expression = "@field(value,len_field)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client_poison.zig", .function = "outcomeForConnection", .expression = "@field(Outcome,@tagName(tag))", .count = 1 },
    .{ .path = "src/platform/macos/session_host/client_external_turn_authority.zig", .function = "writeSeed", .expression = "@field(seed,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/executed_response.zig", .function = "responseTranscriptDigest", .expression = "@field(response,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/event_cleanup_seal.zig", .function = "writeGraph", .expression = "@field(graph,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/event_cleanup_seal.zig", .function = "descriptorPresentMask", .expression = "@field(value.next_observation,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/event_cleanup_seal.zig", .function = "descriptorPresentMask", .expression = "@field(value.old_observation,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/process_seal_service.zig", .function = "updateGraph", .expression = "@field(graph,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/process_seal_service.zig", .function = "updateFixedValue", .expression = "@field(value,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_preparation.zig", .function = "pendingIdentity", .expression = "@field(result,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_preparation.zig", .function = "pendingIdentity", .expression = "@field(value,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_preparation.zig", .function = "cleanupIdentity", .expression = "@field(result,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_preparation.zig", .function = "cleanupIdentity", .expression = "@field(value,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_owner.zig", .function = "identityForSeal", .expression = "@field(out,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_owner.zig", .function = "identityForSeal", .expression = "@field(value,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_owner.zig", .function = "projectionFromRaw", .expression = "@field(projection,field.name)", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_owner.zig", .function = "projectionFromRaw", .expression = "@field(raw,field.name)", .count = 2 },
};
// external source digest 원장은 데이터 전용 파일로 뗐다(충돌 표면 축소 — 그 파일 머리 주석 참고).
const external_digests = @import("external_source_digests.zig");

test "CR3a-2c2b3b B3b-S shared guard oracle rejects alias late and unbound release shapes" {
    const good =
        "const Client = struct { fn sample(self: *Client) !void {" ++
        "const operation_fence_held = try self.ensureUsable();" ++
        "defer if (operation_fence_held) self.endPublicMutation(); _ = self.fd; } };";
    try checkSyntheticSharedGuard(good);
    const alias_before =
        "const Client = struct { fn sample(self: *Client) !void {" ++
        "helper(self); const operation_fence_held = try self.ensureUsable();" ++
        "defer if (operation_fence_held) self.endPublicMutation(); } };";
    try std.testing.expect(!syntheticSharedGuardValid(alias_before));
    const unrelated_defer =
        "const Client = struct { fn sample(self: *Client) !void {" ++
        "const operation_fence_held = try self.ensureUsable(); defer noop();" ++
        "self.endPublicMutation(); } };";
    try std.testing.expect(!syntheticSharedGuardValid(unrelated_defer));
    const late =
        "const Client = struct { fn sample(self: *Client) !void { _ = self.fd;" ++
        "const operation_fence_held = try self.ensureUsable();" ++
        "defer if (operation_fence_held) self.endPublicMutation(); } };";
    try std.testing.expect(!syntheticSharedGuardValid(late));
    const fail_open =
        "const Client = struct { fn sample(self: *Client) void {" ++
        "const operation_fence_held = self.ensureUsable() catch false;" ++
        "defer if (operation_fence_held) self.endPublicMutation(); _ = self.fd; } };";
    try std.testing.expect(!syntheticSharedGuardValid(fail_open));
    const catch_return =
        "const Client = struct { fn sample(self: *Client) bool {" ++
        "const operation_fence_held = self.ensureUsable() catch return false;" ++
        "defer if (operation_fence_held) self.endPublicMutation(); _ = self.fd; return true; } };";
    try checkSyntheticSharedGuard(catch_return);
    const catch_reads_client =
        "const Client = struct { fn sample(self: *Client) bool {" ++
        "const operation_fence_held = self.ensureUsable() catch return helper(self);" ++
        "defer if (operation_fence_held) self.endPublicMutation(); return true; } };";
    try std.testing.expect(!syntheticSharedGuardValid(catch_reads_client));
    const catch_block_reads_client =
        "const Client = struct { fn sample(self: *Client) bool {" ++
        "const operation_fence_held = self.ensureUsable() catch return blk: { _ = 0; break :blk helper(self); };" ++
        "defer if (operation_fence_held) self.endPublicMutation(); return true; } };";
    try std.testing.expect(!syntheticSharedGuardValid(catch_block_reads_client));
}

test "CR3a-2c2b3b B3b-S trusted guard oracle rejects pre-acquire graph and unbound errdefer" {
    const late_graph =
        "const Client = struct { fn ensureUsable(self: *const Client) !bool {" ++
        "_ = self.fd; const operation_fence_held = try self.beginPublicMutation();" ++
        "errdefer if (operation_fence_held) self.endPublicMutation(); return operation_fence_held; } };";
    try std.testing.expect(!syntheticTrustedSharedGuardValid(late_graph, "ensureUsable", "beginPublicMutation"));
    const unrelated_errdefer =
        "const Client = struct { fn ensureUsable(self: *const Client) !bool {" ++
        "const operation_fence_held = try self.beginPublicMutation(); errdefer noop();" ++
        "self.endPublicMutation(); return operation_fence_held; } };";
    try std.testing.expect(!syntheticTrustedSharedGuardValid(unrelated_errdefer, "ensureUsable", "beginPublicMutation"));
    const lost_capability =
        "const Client = struct { fn ensureUsable(self: *const Client) !bool {" ++
        "const operation_fence_held = try self.beginPublicMutation();" ++
        "errdefer if (operation_fence_held) self.endPublicMutation();" ++
        "if (force_short_success) return false; return operation_fence_held; } };";
    try std.testing.expect(!syntheticTrustedSharedGuardValid(lost_capability, "ensureUsable", "beginPublicMutation"));
    const post_delegate_escape =
        "const Client = struct { fn sample(self: *Client) void {" ++
        "self.funnel(); helper(self); } fn funnel(_: *Client) void {} };";
    try std.testing.expect(!syntheticDelegateValid(post_delegate_escape));

    const wrong_begin_mapping =
        "const Client = struct { fn beginPublicMutation(self: *const Client) ClientError!bool {" ++
        "const fence = self.operation_fence orelse { if (self.operation_fence_generation != 0) " ++
        "return error.ConnectionClosed; return false; };" ++
        "fence.tryEnterShared(@intFromPtr(self), self.operation_fence_generation) catch |err| " ++
        "return switch (err) { error.AdminBusy, error.CounterOverflow => error.ConnectionClosed, " ++
        "error.InvalidOwner, error.InvalidState => error.AdminBusy, }; return true; } };";
    try std.testing.expect(!syntheticTrustedLeafValid(wrong_begin_mapping, "beginPublicMutation"));
    const wrong_end_identity =
        "const Client = struct { fn endPublicMutation(self: *const Client) void {" ++
        "const fence = self.operation_fence orelse @panic(\"bound Client operation fence disappeared\");" ++
        "if (!fence.leaveShared(@intFromPtr(self), 0)) " ++
        "@panic(\"Client operation fence shared release failed\"); } };";
    try std.testing.expect(!syntheticTrustedLeafValid(wrong_end_identity, "endPublicMutation"));

    const exclusive_prefix =
        "const Client = struct { fn tryDeinit(self: *Client) bool {" ++
        "const operation_fence = self.operation_fence; var operation_fence_exclusive = false;" ++
        "if (operation_fence) |fence| { fence.tryAcquireExclusive(@intFromPtr(self), " ++
        "self.operation_fence_generation) ";
    const exclusive_latch = " operation_fence_exclusive = true;";
    const exclusive_guard_suffix =
        " } else if (self.operation_fence_generation != 0) return false;" ++
        "defer if (operation_fence_exclusive) { const fence = operation_fence.?;" ++
        "if (!fence.abortExclusive(@intFromPtr(self), self.operation_fence_generation)) " ++
        "@panic(\"Client deinit operation fence abort failed\"); };";
    const exclusive_terminal_prefix =
        "self.finishDeinitGraph();" ++
        "const client_addr = @intFromPtr(self); const operation_fence_generation = self.operation_fence_generation;" ++
        "if (operation_fence) |fence| { if (!fence.commitExclusiveTerminal(client_addr, operation_fence_generation)) " ++
        "@panic(\"Client deinit operation fence commit failed\"); operation_fence_exclusive = false;";
    const exclusive_terminal_suffix = " } self.* = undefined; return true; } };";
    const exclusive_swallow = exclusive_prefix ++ "catch {};" ++ exclusive_latch ++
        exclusive_guard_suffix ++ exclusive_terminal_prefix ++ exclusive_terminal_suffix;
    try std.testing.expect(!syntheticExclusiveGuardValid(exclusive_swallow));
    const exclusive_gap = exclusive_prefix ++ "catch return false;" ++ exclusive_latch ++
        " helper(self);" ++ exclusive_guard_suffix ++ exclusive_terminal_prefix ++ exclusive_terminal_suffix;
    try std.testing.expect(!syntheticExclusiveGuardValid(exclusive_gap));
    const exclusive_early_disarm = exclusive_prefix ++ "catch return false;" ++ exclusive_latch ++
        " operation_fence_exclusive = false;" ++ exclusive_guard_suffix ++
        exclusive_terminal_prefix ++ exclusive_terminal_suffix;
    try std.testing.expect(!syntheticExclusiveGuardValid(exclusive_early_disarm));
    const exclusive_alias_disarm = exclusive_prefix ++ "catch return false;" ++ exclusive_latch ++
        exclusive_guard_suffix ++ "const latch = &operation_fence_exclusive; latch.* = false;" ++
        exclusive_terminal_prefix ++ exclusive_terminal_suffix;
    try std.testing.expect(!syntheticExclusiveGuardValid(exclusive_alias_disarm));
    const exclusive_post_commit_use = exclusive_prefix ++ "catch return false;" ++ exclusive_latch ++
        exclusive_guard_suffix ++ exclusive_terminal_prefix ++ " helper(self);" ++ exclusive_terminal_suffix;
    try std.testing.expect(!syntheticExclusiveGuardValid(exclusive_post_commit_use));
}

test "CR3a-2c2b3b B3b-S construction oracle rejects unreviewed member references" {
    const good =
        "fn owner(client: anytype) void { client.sample(); }" ++
        "test \"ignored\" { client.sample(); }";
    try std.testing.expect(try syntheticConstructionPolicyValid(good, "owner", 1));
    const wrong_owner = "fn intruder(client: anytype) void { client.sample(); }";
    try std.testing.expect(!try syntheticConstructionPolicyValid(wrong_owner, "owner", 1));
    const alias = "fn owner() void { const escaped = Client.sample; _ = escaped; }";
    try std.testing.expect(!try syntheticConstructionPolicyValid(alias, "owner", 1));
    const duplicate = "fn owner(client: anytype) void { client.sample(); client.sample(); }";
    try std.testing.expect(!try syntheticConstructionPolicyValid(duplicate, "owner", 1));
    const reflected = "fn owner() void { _ = @field(Client, \"sample\"); }";
    try std.testing.expect(!try syntheticConstructionPolicyValid(reflected, "owner", 1));
    const joined_reflection = "fn owner() void { _ = @field(Client, \"sam\" ++ \"ple\"); }";
    try std.testing.expect(!try syntheticConstructionPolicyValid(joined_reflection, "owner", 1));
    const named_reflection =
        "fn owner() void { const name = \"sample\"; _ = @field((((Client))), name); }";
    try std.testing.expect(!try syntheticConstructionPolicyValid(named_reflection, "owner", 1));
    const aliased_type_reflection =
        "const C = Client; fn owner() void { const name = \"sample\"; _ = @field(C, name); }";
    try std.testing.expect(!try syntheticConstructionPolicyValid(aliased_type_reflection, "owner", 1));
    const typeof_reflection =
        "fn owner(client: *Client) void { const name = \"sample\"; _ = @field(@TypeOf(client.*), name); }";
    try std.testing.expect(!try syntheticConstructionPolicyValid(typeof_reflection, "owner", 1));
    const external_generic_reflection =
        "fn owner(value: anytype) void { const name = \"sample\";" ++
        "_ = @field(@TypeOf(value.*), name); value.sample(); }";
    try std.testing.expect(!try syntheticConstructionPolicyValidAtPath(
        external_generic_reflection,
        "src/support/invoke.zig",
        "owner",
        1,
    ));
    const admitted_reflection_owner =
        "fn canonicalExternalInventory(client: anytype, source: anytype, result: anytype, entry: anytype) void {" ++
        "_ = @field(source,entry[1]); _ = @field(source,entry[2]);" ++
        "_ = @field(source,entry[3]); _ = @field(source,entry[4]);" ++
        "_ = @field(result,entry[1]); _ = @field(result,entry[2]); client.sample(); }";
    try std.testing.expect(try syntheticConstructionPolicyValidAtPath(
        admitted_reflection_owner,
        "src/platform/macos/session_host/client.zig",
        "canonicalExternalInventory",
        1,
    ));
    const substituted_reflection_owner =
        "fn canonicalExternalInventory(client: anytype, source: anytype, result: anytype, entry: anytype) void {" ++
        "_ = @field(source,entry[1]); _ = @field(source,entry[2]);" ++
        "_ = @field(source,entry[3]); _ = @field(source,entry[4]);" ++
        "_ = @field(result,entry[1]); const C = Client; const name = \"sample\";" ++
        "_ = @field(C,name); client.sample(); }";
    try std.testing.expect(!try syntheticConstructionPolicyValidAtPath(
        substituted_reflection_owner,
        "src/platform/macos/session_host/client.zig",
        "canonicalExternalInventory",
        1,
    ));
    const test_reflection =
        "fn owner(client: anytype) void { client.sample(); }" ++
        "test \"ignored reflection\" { _ = @field(Client, \"sample\"); }";
    try std.testing.expect(try syntheticConstructionPolicyValid(test_reflection, "owner", 1));
    const same_name_intruder =
        "const Allowed = struct { fn owner(client: anytype) void { client.sample(); } };" ++
        "const Intruder = struct { fn owner(client: anytype) void { client.sample(); } };";
    try std.testing.expect(!try syntheticConstructionPolicyValidInContainer(
        same_name_intruder,
        "Allowed",
        "owner",
        1,
    ));
    const nested_intruder =
        "fn owner(client: anytype) void { client.sample();" ++
        "const Intruder = struct { fn steal(other: anytype) void { other.sample(); } };" ++
        "_ = Intruder; }";
    try std.testing.expect(!try syntheticConstructionPolicyValid(nested_intruder, "owner", 2));
    const same_leaf_different_outer =
        "const OuterA = struct { const Owner = struct { fn allowed(client: anytype) void { client.sample(); } }; };" ++
        "const OuterB = struct { const Owner = struct { fn allowed(client: anytype) void { client.sample(); } }; };";
    try std.testing.expect(!try syntheticConstructionPolicyValidInContainer(
        same_leaf_different_outer,
        "OuterA.Owner",
        "allowed",
        1,
    ));
    const unrelated_type =
        "const Other = struct { fn sample(_: *Other) void {} };" ++
        "fn owner(other: *Other) void { other.sample(); }";
    try std.testing.expect(!try syntheticConstructionPolicyValid(unrelated_type, "owner", 1));
    const nested_client_declaration =
        "const Outer = struct { const Client = struct { fn sample(_: *Client) void {} };" ++
        "fn owner(client: *Client) void { client.sample(); } };";
    try std.testing.expect(!try syntheticConstructionPolicyValidAtPath(
        nested_client_declaration,
        "src/platform/macos/session_host/client.zig",
        "owner",
        1,
    ));
    const late_bound_reject =
        "const Client = struct { fn enterExternalMode(self: *Client) !void {" ++
        "const operation_fence_held = try self.beginPublicMutation();" ++
        "defer if (operation_fence_held) self.endPublicMutation();" ++
        "self.mutate(); if (operation_fence_held) return error.Busy;" ++
        "return self.enterExternalModeWithOps(client_deadline.posix_ops); } };";
    try std.testing.expect(!syntheticEnterExternalModePolicyValid(late_bound_reject));
    const adjacency_good =
        "const Client = struct { fn move(self: *Client, destination: anytype) void {" ++
        "destination.* = self.*; self.rebindPreparedNormalizeExact(); self.* = .{}; } };";
    try expectNoUnlistedCallsBetweenMarkers(
        std.testing.allocator,
        adjacency_good,
        "Client",
        "move",
        "destination.* = self.*",
        "self.* =",
        &.{.{ .name = "rebindPreparedNormalizeExact", .count = 1 }},
    );
    const adjacency_gap =
        "const Client = struct { fn move(self: *Client, destination: anytype) void {" ++
        "destination.* = self.*; self.rebindPreparedNormalizeExact(); helper(); self.* = .{}; } };";
    try std.testing.expect(!syntheticNoUnlistedCallsValid(adjacency_gap));
    const builtin_gap =
        "const Client = struct { fn move(self: *Client, destination: anytype) void {" ++
        "destination.* = self.*; self.rebindPreparedNormalizeExact();" ++
        "@call(.auto, helper, .{}); self.* = .{}; } };";
    try std.testing.expect(!syntheticExactMoveRegionValid(builtin_gap));
    const wrong_receiver =
        "const Client = struct { fn move(self: *Client, destination: anytype, attacker: anytype) void {" ++
        "destination.* = self.*; attacker.rebindPreparedNormalizeExact(); self.* = .{}; } };";
    try std.testing.expect(!syntheticExactMoveRegionValid(wrong_receiver));
    const duplicate_start_gap =
        "const Client = struct { fn move(self: *Client, destination: anytype) void {" ++
        "destination.* = self.*; @call(.auto, helper, .{}); destination.* = self.*;" ++
        "self.rebindPreparedNormalizeExact(); self.* = .{}; } };";
    try std.testing.expect(!syntheticExactMoveRegionValid(duplicate_start_gap));
    const early_publish =
        "const ClientSlot = struct { fn initInPlaceWithIssuer() void {" ++
        "publishClientSlot(other); publishClientSlot(registry_reservation); } };";
    try std.testing.expect(!syntheticMarkerCountValid(early_publish, "publishClientSlot(", 1));
    const publish_alias =
        "const ClientSlot = struct { fn initInPlaceWithIssuer() void {" ++
        "const publish = publishClientSlot; publish(other); publishClientSlot(registry_reservation); } };";
    try std.testing.expect(!syntheticDirectIdentifierValid(publish_alias, "publishClientSlot"));
}

test "CR3a-2c2b3b B3b-S inventories every public Client receiver before policy closure" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client.zig",
    );
    defer allocator.free(source);

    const mutable = "*Client";
    const immutable = "*const Client";
    const manifest = [_]ClientReceiverSpec{
        .{ .name = "requireAdminRuntimeEnd", .receiver_type = mutable, .class = .guarded },
        .{ .name = "deinit", .receiver_type = mutable, .class = .guarded },
        .{ .name = "tryDeinit", .receiver_type = mutable, .class = .guarded },
        .{ .name = "requireBufferedGenerationBatch", .receiver_type = immutable, .class = .guarded },
        .{ .name = "enterExternalMode", .receiver_type = mutable, .class = .guarded },
        .{ .name = "call", .receiver_type = mutable, .class = .guarded },
        .{ .name = "callUntil", .receiver_type = mutable, .class = .guarded },
        .{ .name = "prepareBlockingRpcStorage", .receiver_type = mutable, .class = .guarded },
        .{ .name = "abortPreparedBlockingRpcStorage", .receiver_type = mutable, .class = .guarded },
        .{ .name = "abortPreparedBlockingRpcStorageCanonical", .receiver_type = mutable, .class = .guarded },
        .{ .name = "preflightPreparedBlockingRpcStorageExecution", .receiver_type = mutable, .class = .guarded },
        .{ .name = "executePreparedBlockingRpcStorageWithAllocator", .receiver_type = mutable, .class = .guarded },
        .{ .name = "executePreparedBlockingRpcStorageWithAllocatorObserved", .receiver_type = mutable, .class = .guarded },
        .{ .name = "executePreparedBlockingRpcStorageUntil", .receiver_type = mutable, .class = .guarded },
        .{ .name = "executePreparedBlockingRpcStorageUntilObserved", .receiver_type = mutable, .class = .guarded },
        .{ .name = "preparedBlockingRpcStorageMatches", .receiver_type = immutable, .class = .guarded },
        .{ .name = "refreshBufferedAuthorityEvidence", .receiver_type = mutable, .class = .guarded },
        .{ .name = "ingestReadableOutOfBandEvidence", .receiver_type = mutable, .class = .guarded },
        .{ .name = "runtimeInventory", .receiver_type = mutable, .class = .guarded },
        .{ .name = "runtimeInventoryBounded", .receiver_type = mutable, .class = .guarded },
        .{ .name = "runtimeInventoryUntil", .receiver_type = mutable, .class = .guarded },
        .{ .name = "prepareUpgrade", .receiver_type = mutable, .class = .guarded },
        .{ .name = "upgradeStatus", .receiver_type = mutable, .class = .guarded },
        .{ .name = "readSnapshot", .receiver_type = mutable, .class = .guarded },
        .{ .name = "readSnapshotUntil", .receiver_type = mutable, .class = .guarded },
        .{ .name = "readCatchupBarrierUntil", .receiver_type = mutable, .class = .guarded },
        .{ .name = "readCatchupBarrierPlanUntil", .receiver_type = mutable, .class = .guarded },
        .{ .name = "readStreamBatch", .receiver_type = mutable, .class = .guarded },
        .{ .name = "readGenerationBatch", .receiver_type = mutable, .class = .guarded },
        .{ .name = "dropBufferedStream", .receiver_type = mutable, .class = .guarded },
        .{ .name = "takeEventForStream", .receiver_type = mutable, .class = .guarded },
        .{ .name = "prepareGenerationEventTake", .receiver_type = mutable, .class = .guarded },
        .{ .name = "commitGenerationEventTake", .receiver_type = mutable, .class = .guarded },
        .{ .name = "abortGenerationEventTake", .receiver_type = immutable, .class = .guarded },
        .{ .name = "bufferGenerationEventForTest", .receiver_type = mutable, .class = .guarded },
        .{ .name = "peekEndedEventForStream", .receiver_type = immutable, .class = .guarded },
        .{ .name = "prepareEndedPurgeInventory", .receiver_type = immutable, .class = .guarded },
        .{ .name = "releaseEvent", .receiver_type = mutable, .class = .guarded },
        .{ .name = "sendInput", .receiver_type = mutable, .class = .guarded },
        .{ .name = "sendInputNonBlocking", .receiver_type = mutable, .class = .guarded },
        .{ .name = "sendScrollToBottomNonBlocking", .receiver_type = mutable, .class = .guarded },
        .{ .name = "sendResyncNonBlocking", .receiver_type = mutable, .class = .guarded },
        .{ .name = "sendCoreCommandNonBlocking", .receiver_type = mutable, .class = .guarded },
        .{ .name = "sendScrollToBottom", .receiver_type = mutable, .class = .guarded },
        .{ .name = "sendCoreCommand", .receiver_type = mutable, .class = .guarded },
        .{ .name = "pumpPendingOutput", .receiver_type = mutable, .class = .guarded },
        .{ .name = "fenceRevokedStream", .receiver_type = mutable, .class = .guarded },
        .{ .name = "hasBufferedControllerRevoke", .receiver_type = immutable, .class = .guarded },
        .{ .name = "hasBufferedControllerRevokeForStream", .receiver_type = immutable, .class = .guarded },
        .{ .name = "terminalReasonInvariant", .receiver_type = immutable, .class = .guarded },
        .{ .name = "poison", .receiver_type = mutable, .class = .guarded },
        .{ .name = "markDeferredPoisonForTest", .receiver_type = mutable, .class = .guarded },
        .{ .name = "firstPoisonReason", .receiver_type = immutable, .class = .guarded },
        .{ .name = "canTerminalizeSharedConnectionNoDestroy", .receiver_type = mutable, .class = .guarded },
        .{ .name = "terminalizeSharedConnectionNoDestroy", .receiver_type = mutable, .class = .guarded },

        .{ .name = "canMoveToGenerationNode", .receiver_type = immutable, .class = .construction },
        .{ .name = "canRetireFromGenerationNode", .receiver_type = immutable, .class = .construction },
        .{ .name = "retirementRangeAliasesOwnedBacking", .receiver_type = immutable, .class = .construction },
        .{ .name = "bindGenerationAccountingLedger", .receiver_type = mutable, .class = .construction },
        .{ .name = "moveToGenerationNode", .receiver_type = mutable, .class = .construction },
        .{ .name = "clientProjectionAuthorityDigest", .receiver_type = immutable, .class = .construction },
        .{ .name = "externalTransferProfile", .receiver_type = immutable, .class = .construction },
        .{ .name = "prepareExternalRecoveryDiscard", .receiver_type = immutable, .class = .construction },
        .{ .name = "validateExternalRecoveryDiscard", .receiver_type = immutable, .class = .construction },
        .{ .name = "prepareExternalPumpTransfer", .receiver_type = mutable, .class = .construction },
        .{ .name = "commitExternalPumpTransfer", .receiver_type = mutable, .class = .construction },
        .{ .name = "foldExternalAdoptionSource", .receiver_type = immutable, .class = .construction },
        .{ .name = "externalAdoptionFoldResultMatches", .receiver_type = immutable, .class = .construction },
        .{ .name = "materializeExternalMetadataEvent", .receiver_type = immutable, .class = .construction },
        .{ .name = "externalMetadataDtoMatchesEventCandidate", .receiver_type = immutable, .class = .construction },
        .{ .name = "previewExternalAdoption", .receiver_type = immutable, .class = .construction },
        .{ .name = "inspectExternalAdoption", .receiver_type = immutable, .class = .construction },
        .{ .name = "preflightExternalAdoptionDestination", .receiver_type = immutable, .class = .construction },
        .{ .name = "preflightExternalAdoptionDestinationWithScratch", .receiver_type = immutable, .class = .construction },
        .{ .name = "appendExternalOwnerRangesForTeardown", .receiver_type = immutable, .class = .construction },
        .{ .name = "prepareExternalOwnerRangeProof", .receiver_type = immutable, .class = .construction },
        .{ .name = "preflightExternalAdoption", .receiver_type = immutable, .class = .construction },
        .{ .name = "stageExternalScreenCopies", .receiver_type = immutable, .class = .construction },
        .{ .name = "externalScreenCopiesMatch", .receiver_type = immutable, .class = .construction },
        .{ .name = "validateExternalAdoptionPlan", .receiver_type = immutable, .class = .construction },
        .{ .name = "externalAdoptionDisarmMetadataBytes", .receiver_type = immutable, .class = .construction },
        .{ .name = "externalAdoptionDisarmMatchesInventory", .receiver_type = immutable, .class = .construction },
        .{ .name = "sealExternalAdoption", .receiver_type = immutable, .class = .construction },
        .{ .name = "validateSealedExternalAdoptionPlan", .receiver_type = immutable, .class = .construction },
        .{ .name = "prepareExternalAdoptionTake", .receiver_type = immutable, .class = .construction },
        .{ .name = "commitExternalAdoption", .receiver_type = mutable, .class = .construction },
        .{ .name = "prepareExternalModeDeinit", .receiver_type = mutable, .class = .construction },
        .{ .name = "reserveExternalModeDeinit", .receiver_type = mutable, .class = .construction },
        .{ .name = "finishReservedExternalModeDeinit", .receiver_type = mutable, .class = .construction },
        .{ .name = "cancelReservedExternalModeDeinit", .receiver_type = mutable, .class = .construction },
        .{ .name = "transferReservedExternalModeDeinit", .receiver_type = mutable, .class = .construction },
        .{ .name = "bindOperationFence", .receiver_type = mutable, .class = .construction },

        .{ .name = "beginGenerationAllocatorScope", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "restoreGenerationAllocatorScope", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "beginReadPumpPoisonCapture", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "endReadPumpPoisonCapture", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "prepareGenerationAccountingConsume", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "consumeGenerationAccountingUnchecked", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "tryAcquireEndedPurgeExclusive", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "prepareEndedPurgeCommit", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "commitEndedPurgePrepared", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "finalizeEndedPurgeNoFreePoison", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "tryAcquireClientSlotTeardownExclusive", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "abortClientSlotTeardownExclusive", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "tryDeinitClientSlotExclusiveHeld", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "beginClientSlotOperation", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "endClientSlotOperation", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "beginRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "endRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "callUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "validateGenerationEventTakeUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "commitGenerationEventTakeUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "abortGenerationEventTakeDuringRegisteredOperation", .receiver_type = immutable, .class = .unchecked },
        .{ .name = "abortGenerationEventTakeUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "sendInputUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "sendInputNonBlockingUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "sendScrollToBottomNonBlockingUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "sendResyncNonBlockingUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "sendCoreCommandNonBlockingUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "sendObservationProbeNonBlockingUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "sendScrollToBottomUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "sendCoreCommandUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "pumpPendingOutputUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "pumpRxDemuxUnderRegisteredOperationExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "beginConfirmedGenerationPoisonExclusive", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "endConfirmedGenerationPoisonExclusive", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "releaseEndedPurgeExclusiveClean", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "commitEndedPurgeExclusiveTerminal", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "enterGenerationAllocatorCallback", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "rejectGenerationAllocatorCallbackReentry", .receiver_type = immutable, .class = .unchecked },
        .{ .name = "leaveGenerationAllocatorCallbackUnchecked", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "beginPreparedRequestExecution", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "beginPreparedRequestExecutionFromRegisteredOperation", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "abortPreparedBlockingRpcStorageUnderExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "poisonPreparedRequestExecution", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "writePreparedRequestExecution", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "observePreparedRequestTerminalSinkEof", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "finishPreparedRequestExecution", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "restoreGenerationAllocatorScopeUnderExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "readPreparedResponseUnderExecutionLease", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "commitPreparedExecutionRecoveryPoisonNoFail", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "commitPreparedExecutionRecoveryCleanupNoFail", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "poisonDuringClientSlotOperationNoFail", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "terminalizePublishedIncidentChecked", .receiver_type = mutable, .class = .unchecked },
        .{ .name = "setNextExecutionCapabilityIdentityForTest", .receiver_type = mutable, .class = .unchecked },

        .{ .name = "endedPurgeFenceIntruded", .receiver_type = immutable, .class = .observation },
        .{ .name = "bufferedControllerRevokeUnderRegisteredOperationExecutionLease", .receiver_type = immutable, .class = .observation },
        .{ .name = "preparedRequestExecutionLeaseMatches", .receiver_type = immutable, .class = .observation },
        .{ .name = "preparedRequestExecutionPoisonReason", .receiver_type = immutable, .class = .observation },
        .{ .name = "preparedExecutionRecoveryPoisonedForTest", .receiver_type = immutable, .class = .observation },
        .{ .name = "nextExecutionCapabilityIdentityForTest", .receiver_type = immutable, .class = .observation },
        .{ .name = "revalidatePreparedResponsePublication", .receiver_type = immutable, .class = .observation },
        .{ .name = "screenRecoveryState", .receiver_type = immutable, .class = .observation },
        .{ .name = "hasBufferedRuntimeWork", .receiver_type = immutable, .class = .observation },
        .{ .name = "hasAnyBufferedRuntimeWork", .receiver_type = immutable, .class = .observation },
    };
    try expectClientReceiverManifest(allocator, source, &manifest);
    const guarded = [_]ClientGuardProof{
        .{ .receiver = "requireAdminRuntimeEnd", .funnel = "requireAdminRuntimeEnd", .gate = "requireBlockingMode" },
        .{ .receiver = "deinit", .funnel = "tryDeinit", .gate = "tryAcquireExclusive", .gate_prefix = "fence", .gate_depth = 2, .release = "abortExclusive", .release_prefix = "fence", .release_depth = 2, .pre_gate_self_fields = &.{ "operation_fence", "operation_fence_generation" } },
        .{ .receiver = "tryDeinit", .funnel = "tryDeinit", .gate = "tryAcquireExclusive", .gate_prefix = "fence", .gate_depth = 2, .release = "abortExclusive", .release_prefix = "fence", .release_depth = 2, .pre_gate_self_fields = &.{ "operation_fence", "operation_fence_generation" } },
        .{ .receiver = "beginGenerationAllocatorScope", .funnel = "beginGenerationAllocatorScope", .gate = "ensureUsable" },
        .{ .receiver = "requireBufferedGenerationBatch", .funnel = "requireBufferedGenerationBatch", .gate = "ensureUsable" },
        .{ .receiver = "restoreGenerationAllocatorScope", .funnel = "restoreGenerationAllocatorScope", .gate = "beginPublicMutation" },
        .{ .receiver = "enterExternalMode", .funnel = "enterExternalMode", .gate = "beginPublicMutation" },
        .{ .receiver = "call", .funnel = "callWithIo", .gate = "requireBlockingMode" },
        .{ .receiver = "callUntil", .funnel = "callUntilWithOps", .gate = "requireBlockingMode" },
        .{ .receiver = "prepareBlockingRpcStorage", .funnel = "prepareBlockingRpc", .gate = "requireBlockingMode" },
        .{ .receiver = "abortPreparedBlockingRpcStorage", .funnel = "abortPreparedBlockingRpcStorage", .gate = "beginPublicMutation" },
        .{ .receiver = "abortPreparedBlockingRpcStorageCanonical", .funnel = "abortPreparedBlockingRpcStorageCanonical", .gate = "beginPublicMutation" },
        .{ .receiver = "preflightPreparedBlockingRpcStorageExecution", .funnel = "preflightPreparedBlockingRpcStorageExecution", .gate = "ensureUsable" },
        .{ .receiver = "executePreparedBlockingRpcStorageWithAllocator", .funnel = "executePreparedBlockingRpcStorageWithAllocatorInternal", .gate = "beginPublicMutation" },
        .{ .receiver = "executePreparedBlockingRpcStorageWithAllocatorObserved", .funnel = "executePreparedBlockingRpcStorageWithAllocatorInternal", .gate = "beginPublicMutation" },
        .{ .receiver = "executePreparedBlockingRpcStorageUntil", .funnel = "executePreparedBlockingRpcStorageUntilObserved", .gate = "beginPublicMutation" },
        .{ .receiver = "executePreparedBlockingRpcStorageUntilObserved", .funnel = "executePreparedBlockingRpcStorageUntilObserved", .gate = "beginPublicMutation" },
        .{ .receiver = "preparedBlockingRpcStorageMatches", .funnel = "preparedBlockingRpcStorageMatches", .gate = "beginPublicMutation" },
        .{ .receiver = "refreshBufferedAuthorityEvidence", .funnel = "refreshBufferedAuthorityEvidence", .gate = "requireBlockingMode" },
        .{ .receiver = "ingestReadableOutOfBandEvidence", .funnel = "ingestReadableOutOfBandEvidence", .gate = "requireBlockingMode" },
        .{ .receiver = "runtimeInventory", .funnel = "runtimeInventory", .gate = "requireBlockingMode" },
        .{ .receiver = "runtimeInventoryBounded", .funnel = "runtimeInventoryBounded", .gate = "requireBlockingMode" },
        .{ .receiver = "runtimeInventoryUntil", .funnel = "runtimeInventoryUntil", .gate = "requireBlockingMode" },
        .{ .receiver = "prepareUpgrade", .funnel = "prepareUpgrade", .gate = "requireBlockingMode" },
        .{ .receiver = "upgradeStatus", .funnel = "upgradeStatus", .gate = "requireBlockingMode" },
        .{ .receiver = "readSnapshot", .funnel = "readSnapshotWithIo", .gate = "requireBlockingMode" },
        .{ .receiver = "readSnapshotUntil", .funnel = "readSnapshotUntilWithOps", .gate = "requireBlockingMode" },
        .{ .receiver = "readCatchupBarrierUntil", .funnel = "readCatchupBarrierPlanUntilWithOps", .gate = "requireBlockingMode" },
        .{ .receiver = "readCatchupBarrierPlanUntil", .funnel = "readCatchupBarrierPlanUntilWithOps", .gate = "requireBlockingMode" },
        .{ .receiver = "readStreamBatch", .funnel = "readStreamBatchWithIo", .gate = "requireBlockingMode" },
        .{ .receiver = "readGenerationBatch", .funnel = "readGenerationBatch", .gate = "requireBlockingMode" },
        .{ .receiver = "dropBufferedStream", .funnel = "dropBufferedStream", .gate = "beginPublicMutation" },
        .{ .receiver = "takeEventForStream", .funnel = "takeEventForStream", .gate = "beginPublicMutation" },
        .{ .receiver = "prepareGenerationEventTake", .funnel = "prepareGenerationEventTake", .gate = "beginPublicMutation" },
        .{ .receiver = "commitGenerationEventTake", .funnel = "commitGenerationEventTake", .gate = "beginPublicMutation" },
        .{ .receiver = "abortGenerationEventTake", .funnel = "abortGenerationEventTake", .gate = "beginPublicMutation" },
        .{ .receiver = "bufferGenerationEventForTest", .funnel = "bufferGenerationEventForTest", .gate = "beginPublicMutation" },
        .{ .receiver = "peekEndedEventForStream", .funnel = "peekEndedEventForStream", .gate = "beginPublicMutation" },
        .{ .receiver = "prepareEndedPurgeInventory", .funnel = "prepareEndedPurgeInventory", .gate = "beginPublicMutation" },
        .{ .receiver = "releaseEvent", .funnel = "releaseEvent", .gate = "beginPublicMutation" },
        .{ .receiver = "sendInput", .funnel = "sendInput", .gate = "requireBlockingMode" },
        .{ .receiver = "sendInputNonBlocking", .funnel = "sendInputNonBlocking", .gate = "requireBlockingMode" },
        .{ .receiver = "sendScrollToBottomNonBlocking", .funnel = "sendScrollToBottomNonBlocking", .gate = "requireBlockingMode" },
        .{ .receiver = "sendResyncNonBlocking", .funnel = "sendResyncNonBlocking", .gate = "requireBlockingMode" },
        .{ .receiver = "sendCoreCommandNonBlocking", .funnel = "sendCoreCommandNonBlocking", .gate = "requireBlockingMode" },
        .{ .receiver = "sendScrollToBottom", .funnel = "sendScrollToBottom", .gate = "requireBlockingMode" },
        .{ .receiver = "sendCoreCommand", .funnel = "sendCoreCommand", .gate = "requireBlockingMode" },
        .{ .receiver = "pumpPendingOutput", .funnel = "pumpPendingOutput", .gate = "requireBlockingMode" },
        .{ .receiver = "fenceRevokedStream", .funnel = "fenceRevokedStream", .gate = "requireBlockingMode" },
        .{ .receiver = "hasBufferedControllerRevoke", .funnel = "hasBufferedControllerRevokeForStream", .gate = "beginPublicMutation" },
        .{ .receiver = "hasBufferedControllerRevokeForStream", .funnel = "hasBufferedControllerRevokeForStream", .gate = "beginPublicMutation" },
        .{ .receiver = "terminalReasonInvariant", .funnel = "terminalReasonInvariant", .gate = "beginPublicMutation" },
        .{ .receiver = "poison", .funnel = "poison", .gate = "beginPublicMutation", .pre_gate_self_fields = &.{ "exactAllocatorCallbackOwner", "prepared_request_execution_lease_addr", "capturePreparedExecutionPoison", "captureReadPumpPoison" } },
        .{ .receiver = "markDeferredPoisonForTest", .funnel = "markDeferredPoisonForTest", .gate = "beginPublicMutation" },
        .{ .receiver = "firstPoisonReason", .funnel = "firstPoisonReason", .gate = "beginPublicMutation" },
        .{ .receiver = "canTerminalizeSharedConnectionNoDestroy", .funnel = "canTerminalizeSharedConnectionNoDestroy", .gate = "beginPublicMutation" },
        .{ .receiver = "terminalizeSharedConnectionNoDestroy", .funnel = "terminalizeSharedConnectionNoDestroy", .gate = "beginPublicMutation" },
    };
    try expectGuardedClientReceiverPolicies(allocator, source, &manifest, &guarded);
    const client_path = "src/platform/macos/session_host/client.zig";
    const slot_path = "src/platform/macos/session_host/client_slot.zig";
    const pump_path = "src/platform/macos/session_host/client_external_pump.zig";
    const adoption_path = "src/platform/macos/session_host/client_external_adoption.zig";
    const materialization_path = "src/platform/macos/session_host/external_event_materialization.zig";
    const decision_path = "src/platform/macos/session_host/external_source_decision.zig";
    const construction = [_]ClientConstructionProof{
        .{ .receiver = "canMoveToGenerationNode", .kind = .generation_init, .uses = &.{
            .{ .path = client_path, .enclosing_fn = "moveToGenerationNode" },
            .{ .path = slot_path, .enclosing_fn = "initInPlaceWithIssuer" },
            .{ .path = slot_path, .enclosing_fn = "prepareClientReplacement" },
            .{ .path = slot_path, .enclosing_fn = "reserveClientReplacementNode" },
            .{ .path = slot_path, .enclosing_fn = "preflightReservedClientReplacementNode" },
            .{ .path = slot_path, .enclosing_fn = "publishReservedClientReplacementAfterRetirementNoFail" },
        } },
        .{ .receiver = "canRetireFromGenerationNode", .kind = .generation_init, .uses = &.{
            .{ .path = slot_path, .enclosing_fn = "retiredNodeReadyForReclaim" },
        } },
        .{ .receiver = "retirementRangeAliasesOwnedBacking", .kind = .generation_init, .uses = &.{
            .{ .path = slot_path, .enclosing_fn = "overlapsRetiredNode" },
        } },
        .{ .receiver = "bindGenerationAccountingLedger", .kind = .generation_init, .uses = &.{
            .{ .path = slot_path, .enclosing_fn = "initInPlaceWithIssuer" },
            .{ .path = slot_path, .enclosing_fn = "prepareClientReplacement" },
            .{ .path = slot_path, .enclosing_fn = "publishReservedClientReplacementAfterRetirementNoFail" },
        } },
        .{ .receiver = "moveToGenerationNode", .kind = .generation_init, .uses = &.{
            .{ .path = slot_path, .enclosing_fn = "initInPlaceWithIssuer" },
            .{ .path = slot_path, .enclosing_fn = "prepareClientReplacement" },
            .{ .path = slot_path, .enclosing_fn = "publishReservedClientReplacementAfterRetirementNoFail" },
        } },
        .{ .receiver = "clientProjectionAuthorityDigest", .kind = .external_adoption, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "projectOwnerEventInternal", .count = 2 },
            .{ .path = "src/platform/macos/session_host/remote_term_backend.zig", .enclosing_container = "HostReconnectJob", .enclosing_fn = "sealInput" },
        } },
        .{ .receiver = "externalTransferProfile", .kind = .external_transfer, .uses = &.{
            .{ .path = client_path, .enclosing_fn = "prepareExternalPumpTransfer" },
            .{ .path = client_path, .enclosing_fn = "validate" },
            .{ .path = pump_path, .enclosing_fn = "initFromAttachPartsInPlace" },
            .{ .path = pump_path, .enclosing_fn = "prepareEventReduction", .count = 2 },
            .{ .path = pump_path, .enclosing_fn = "validate" },
            .{ .path = pump_path, .enclosing_fn = "validateEventReduction" },
        } },
        .{ .receiver = "prepareExternalRecoveryDiscard", .kind = .external_adoption, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "finishImmediateTerminal" },
            .{ .path = pump_path, .enclosing_fn = "finishNonAdopted" },
        } },
        .{ .receiver = "validateExternalRecoveryDiscard", .kind = .external_adoption, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "finishImmediateTerminal" },
            .{ .path = pump_path, .enclosing_fn = "finishNonAdopted" },
        } },
        .{ .receiver = "prepareExternalPumpTransfer", .kind = .external_transfer, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "initInPlaceWithOptions" },
        } },
        .{ .receiver = "commitExternalPumpTransfer", .kind = .external_transfer, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "initInPlaceWithOptions" },
        } },
        .{ .receiver = "foldExternalAdoptionSource", .kind = .external_adoption, .uses = &.{
            .{ .path = client_path, .enclosing_fn = "externalAdoptionFoldResultMatches" },
            .{ .path = pump_path, .enclosing_fn = "prepareAdoptionInner" },
        } },
        .{ .receiver = "externalAdoptionFoldResultMatches", .kind = .external_adoption, .uses = &.{
            .{ .path = client_path, .enclosing_fn = "externalMetadataDtoMatchesEventCandidate" },
            .{ .path = client_path, .enclosing_fn = "materializeExternalMetadataEvent", .count = 2 },
            .{ .path = decision_path, .enclosing_fn = "decide" },
            .{ .path = decision_path, .enclosing_fn = "decisionMatches" },
        } },
        .{ .receiver = "materializeExternalMetadataEvent", .kind = .external_adoption, .uses = &.{
            .{ .path = materialization_path, .enclosing_fn = "prepareInPlace" },
        } },
        .{ .receiver = "externalMetadataDtoMatchesEventCandidate", .kind = .external_adoption, .uses = &.{
            .{ .path = materialization_path, .enclosing_fn = "validate" },
        } },
        .{ .receiver = "previewExternalAdoption", .kind = .external_adoption, .uses = &.{
            .{ .path = adoption_path, .enclosing_fn = "preflightMetadata" },
        } },
        .{ .receiver = "inspectExternalAdoption", .kind = .external_adoption, .uses = &.{
            .{ .path = client_path, .enclosing_fn = "checkExternalAdoptionAllocation" },
            .{ .path = client_path, .enclosing_fn = "preflightExternalAdoption" },
            .{ .path = adoption_path, .enclosing_fn = "initInPlace" },
        } },
        .{ .receiver = "preflightExternalAdoptionDestination", .kind = .external_adoption, .uses = &.{
            .{ .path = client_path, .enclosing_fn = "prepareExternalAdoptionTake" },
            .{ .path = client_path, .enclosing_fn = "prepareExternalPumpTransfer", .count = 2 },
            .{ .path = client_path, .enclosing_fn = "stageExternalScreenCopies" },
            .{ .path = pump_path, .enclosing_fn = "initFromAttachPartsInPlace", .count = 3 },
            .{ .path = pump_path, .enclosing_fn = "initInPlaceWithOptions", .count = 2 },
            .{ .path = pump_path, .enclosing_fn = "prepareAdoptionInner" },
            .{ .path = adoption_path, .enclosing_fn = "initInPlace" },
            .{ .path = slot_path, .enclosing_fn = "prepareRetirementCleanup", .count = 4 },
        } },
        .{ .receiver = "preflightExternalAdoptionDestinationWithScratch", .kind = .external_adoption, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "metadataDtoBackingDisjointFromClient" },
            .{ .path = pump_path, .enclosing_fn = "prepareAdoptionInner", .count = 2 },
            .{ .path = pump_path, .enclosing_fn = "projectionScratchDisjoint" },
            .{ .path = pump_path, .enclosing_fn = "screenRangeDisjointFromClientAndMetadata" },
            .{ .path = pump_path, .enclosing_fn = "teardownUnderHeldOperationLease" },
            .{ .path = pump_path, .enclosing_fn = "validateFinalSeal", .count = 2 },
            .{ .path = pump_path, .enclosing_fn = "wholeTurnScratchDisjoint" },
            .{ .path = materialization_path, .enclosing_fn = "prepareInPlace" },
        } },
        .{ .receiver = "appendExternalOwnerRangesForTeardown", .kind = .external_adoption, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "buildRxOwnerAuthoritySnapshot" },
            .{ .path = pump_path, .enclosing_fn = "prepareAggregateOwnerRangeProof" },
            .{ .path = pump_path, .enclosing_fn = "rebuildProductReplacementInventory" },
        } },
        .{ .receiver = "prepareExternalOwnerRangeProof", .kind = .external_transfer, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "initInPlaceWithOptions" },
        } },
        .{ .receiver = "preflightExternalAdoption", .kind = .external_adoption, .uses = &.{
            .{ .path = client_path, .enclosing_fn = "checkExternalAdoptionAllocation" },
            .{ .path = adoption_path, .enclosing_fn = "initInPlace" },
        } },
        .{ .receiver = "stageExternalScreenCopies", .kind = .external_adoption, .uses = &.{
            .{ .path = adoption_path, .enclosing_fn = "initInPlace" },
        } },
        .{ .receiver = "externalScreenCopiesMatch", .kind = .external_adoption, .uses = &.{
            .{ .path = adoption_path, .enclosing_fn = "validate" },
        } },
        .{ .receiver = "validateExternalAdoptionPlan", .kind = .external_adoption, .uses = &.{
            .{ .path = client_path, .enclosing_fn = "checkExternalAdoptionAllocation" },
            .{ .path = client_path, .enclosing_fn = "sealExternalAdoption" },
            .{ .path = client_path, .enclosing_fn = "validateSealedExternalAdoptionPlan" },
            .{ .path = adoption_path, .enclosing_fn = "validate" },
        } },
        .{ .receiver = "externalAdoptionDisarmMetadataBytes", .kind = .external_adoption, .uses = &.{
            .{ .path = adoption_path, .enclosing_fn = "initInPlace" },
            .{ .path = adoption_path, .enclosing_fn = "validate" },
        } },
        .{ .receiver = "externalAdoptionDisarmMatchesInventory", .kind = .external_adoption, .uses = &.{
            .{ .path = adoption_path, .enclosing_fn = "validate" },
        } },
        .{ .receiver = "sealExternalAdoption", .kind = .external_adoption, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "prepareAdoptionInner" },
        } },
        .{ .receiver = "validateSealedExternalAdoptionPlan", .kind = .external_adoption, .uses = &.{
            .{ .path = client_path, .enclosing_fn = "prepareExternalAdoptionTake" },
            .{ .path = client_path, .enclosing_fn = "validate" },
            .{ .path = adoption_path, .enclosing_fn = "commitScreenSeeds" },
        } },
        .{ .receiver = "prepareExternalAdoptionTake", .kind = .external_adoption, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "prepareAdoptionInner" },
        } },
        .{ .receiver = "commitExternalAdoption", .kind = .external_adoption, .uses = &.{} },
        .{ .receiver = "prepareExternalModeDeinit", .kind = .external_teardown, .uses = &.{
            .{ .path = client_path, .enclosing_fn = "poisonAndTakeFd" },
            .{ .path = client_path, .enclosing_fn = "prepareDeinitGraph" },
        } },
        .{ .receiver = "reserveExternalModeDeinit", .kind = .external_teardown, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "closeUncommittedOwned" },
            .{ .path = pump_path, .enclosing_fn = "latchCommitTerminal" },
            .{ .path = pump_path, .enclosing_fn = "latchCrossOwnerAliasTerminal" },
            .{ .path = pump_path, .enclosing_fn = "teardownUnderHeldOperationLease" },
            .{ .path = slot_path, .enclosing_fn = "prepareRetirementCleanup" },
        } },
        .{ .receiver = "finishReservedExternalModeDeinit", .kind = .external_teardown, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "closeUncommittedOwned" },
            .{ .path = pump_path, .enclosing_fn = "latchCommitTerminal" },
            .{ .path = pump_path, .enclosing_fn = "latchCrossOwnerAliasTerminal" },
            .{ .path = pump_path, .enclosing_fn = "teardownUnderHeldOperationLease" },
            .{ .path = slot_path, .enclosing_fn = "finishRetirementCleanup" },
        } },
        .{ .receiver = "cancelReservedExternalModeDeinit", .kind = .external_teardown, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "teardownUnderHeldOperationLease" },
            .{ .path = slot_path, .enclosing_fn = "prepareRetirementCleanup" },
            .{ .path = slot_path, .enclosing_fn = "abortRetirementCleanup" },
        } },
        .{ .receiver = "transferReservedExternalModeDeinit", .kind = .external_teardown, .uses = &.{
            .{ .path = pump_path, .enclosing_fn = "teardownUnderHeldOperationLease", .count = 2 },
        } },
        .{ .receiver = "bindOperationFence", .kind = .generation_init, .uses = &.{
            .{ .path = slot_path, .enclosing_fn = "initInPlaceWithIssuer" },
            .{ .path = slot_path, .enclosing_fn = "prepareClientReplacement" },
            .{ .path = slot_path, .enclosing_fn = "publishReservedClientReplacementAfterRetirementNoFail" },
        } },
    };
    var wrong_construction_category = construction;
    wrong_construction_category[3].kind = .external_transfer;
    try std.testing.expect(!clientConstructionCategoriesValid(&wrong_construction_category));
    try expectClientConstructionCategories(&construction);
    const external_mode_manifest = [_]ClientReceiverSpec{.{
        .name = "enterExternalMode",
        .receiver_type = mutable,
        .class = .construction,
    }};
    const external_mode_proof = [_]ClientConstructionProof{.{
        .receiver = "enterExternalMode",
        .kind = .external_transfer,
        .uses = &.{
            .{ .path = client_path, .enclosing_fn = "checkClientExternalModeAllocation" },
            .{ .path = client_path, .enclosing_fn = "checkExternalAdoptionAllocation" },
            .{ .path = pump_path, .enclosing_fn = "initWithAllocator" },
            .{ .path = adoption_path, .enclosing_fn = "makePreparedClient" },
            .{ .path = materialization_path, .enclosing_fn = "init" },
            .{ .path = "src/platform/macos/session_host/external_attach.zig", .enclosing_fn = "enterExternalMode" },
            .{ .path = "src/platform/macos/session_host/external_attach_evidence.zig", .enclosing_fn = "init" },
            .{ .path = "src/platform/macos/session_host/external_pump_owner.zig", .enclosing_fn = "exerciseD3SocketpairRevokePosition" },
            .{ .path = "src/platform/macos/session_host/external_pump_owner.zig", .enclosing_container = "P5c3c2b3PreparedFixture", .enclosing_fn = "initWithAllocator" },
            .{ .path = slot_path, .enclosing_container = "<root>", .enclosing_fn = "enterExternalMode" },
        },
    }};
    var reviewed_manifest: [38]ClientReceiverSpec = undefined;
    var reviewed_index: usize = 0;
    for (manifest) |entry| {
        if (entry.class != .construction) continue;
        reviewed_manifest[reviewed_index] = entry;
        reviewed_index += 1;
    }
    reviewed_manifest[reviewed_index] = external_mode_manifest[0];
    reviewed_index += 1;
    try std.testing.expectEqual(reviewed_manifest.len, reviewed_index);
    var reviewed_proofs: [38]ClientConstructionProof = undefined;
    @memcpy(reviewed_proofs[0..construction.len], &construction);
    reviewed_proofs[construction.len] = external_mode_proof[0];
    try expectClientConstructionPolicies(allocator, &reviewed_manifest, &reviewed_proofs);
    try expectEnterExternalModeBoundReject(allocator, source);
    try expectClientMethodBodyPrefix(allocator, source, "canMoveToGenerationNode", &.{
        "if",   "(", "self",                       ".",  "operation_fence", "!=", "null",   "or",
        "self", ".", "operation_fence_generation", "!=", "0",               ")",  "return", "false",
        ";",
    });
    try expectClientMethodBodyPrefix(allocator, source, "externalTransferProfile", &.{
        "if",   "(", "self",                       ".",  "operation_fence", "!=", "null",   "or",
        "self", ".", "operation_fence_generation", "!=", "0",               ")",  "return", "null",
        ";",
    });
    try expectClientMethodBodyPrefix(allocator, source, "prepareExternalPumpTransfer", &.{
        "if",   "(",            "self",                       ".",  "operation_fence", "!=", "null",   "or",
        "self", ".",            "operation_fence_generation", "!=", "0",               ")",  "return", "error",
        ".",    "AlreadyBound", ";",
    });
    const slot_source = try readZigFileZ(allocator, slot_path);
    defer allocator.free(slot_source);
    try expectContainerMethodMarkersInOrder(
        allocator,
        slot_source,
        "ClientSlot",
        "initInPlaceWithIssuer",
        &.{
            "canMoveToGenerationNode(",
            "registerClientSlot(registry_reservation)",
            "moveToGenerationNode(",
            "bindOperationFence(",
            "bindGenerationAccountingLedger(",
            "out.* =",
            "publishClientSlot(registry_reservation)",
        },
    );
    try expectContainerMethodMarkerCount(
        allocator,
        slot_source,
        "ClientSlot",
        "initInPlaceWithIssuer",
        "registerClientSlot(registry_reservation)",
        1,
    );
    try expectOnlyDirectIdentifierReference(
        allocator,
        slot_source,
        "ClientSlot",
        "initInPlaceWithIssuer",
        "registerClientSlot",
    );
    try expectContainerMethodMarkerCount(
        allocator,
        slot_source,
        "ClientSlot",
        "initInPlaceWithIssuer",
        "registerClientSlot(",
        1,
    );
    try expectContainerMethodMarkersInOrder(
        allocator,
        source,
        "Client",
        "commitExternalPumpTransfer",
        &.{
            "destination.* = self.*",
            "self.* =",
            "prepared.lifecycle = .owners_moved",
        },
    );
    try expectContainerMethodMarkerCount(
        allocator,
        source,
        "Client",
        "commitEndedPurgePrepared",
        "scratch.*",
        0,
    );
    try expectContainerMethodMarkerCount(
        allocator,
        source,
        "Client",
        "commitExternalPumpTransfer",
        "self.* =",
        1,
    );
    try expectNoUnlistedCallsBetweenMarkers(
        allocator,
        source,
        "Client",
        "commitExternalPumpTransfer",
        "destination.* = self.*",
        "self.* =",
        &.{.{ .name = "rebindPreparedNormalizeExact", .count = 1 }},
    );
    try expectExactMethodTokenRegion(
        allocator,
        source,
        "Client",
        "commitExternalPumpTransfer",
        "destination.*=self.*;destination.*.?.ownership=.external_pump;" ++
            "self.parser.rebindPreparedNormalizeExact(&prepared.parser_replacement,&destination.*.?.parser,);self.*=",
        true,
    );
    const pump_source = try readZigFileZ(allocator, pump_path);
    defer allocator.free(pump_source);
    try expectContainerMethodMarkersInOrder(
        allocator,
        pump_source,
        "ExternalPumpStorage",
        "initInPlaceWithOptions",
        &.{
            "prepareExternalPumpTransfer(",
            "prepareExternalOwnerRangeProof(",
            "commitExternalPumpTransfer(",
            "moveInto(",
        },
    );
    inline for (.{
        .{ "prepareExternalPumpTransfer(", 1 },
        .{ "prepareExternalOwnerRangeProof(", 1 },
        .{ "commitExternalPumpTransfer(", 1 },
        .{ "moveInto(", 1 },
    }) |marker| try expectContainerMethodMarkerCount(
        allocator,
        pump_source,
        "ExternalPumpStorage",
        "initInPlaceWithOptions",
        marker[0],
        marker[1],
    );
    try expectNoUnlistedCallsBetweenMarkers(
        allocator,
        pump_source,
        "ExternalPumpStorage",
        "initInPlaceWithOptions",
        "commitExternalPumpTransfer(",
        "moveInto(",
        &.{
            .{ .name = "deinit", .count = 1 },
            .{ .name = "failed", .count = 1 },
        },
    );
    try expectExactMethodTokenRegion(
        allocator,
        pump_source,
        "ExternalPumpStorage",
        "initInPlaceWithOptions",
        "source.commitExternalPumpTransfer(&out.client_transfer,&out.owned_client,)catch{" ++
            "out.client_transfer.deinit();out.*=.{};return failed(.invalid_evidence,.preserved);};" ++
            "out.owned_evidence=.{};evidence.moveInto(",
        true,
    );
    try expectContainerMethodMarkersInOrder(
        allocator,
        pump_source,
        "ExternalPumpStorage",
        "teardownUnderHeldOperationLease",
        &.{
            "active_external_operation_addr != @intFromPtr(self)",
            "owned.reserveExternalModeDeinit()",
            "owned.cancelReservedExternalModeDeinit()",
            "source.transferReservedExternalModeDeinit(destination)",
            "owned.finishReservedExternalModeDeinit()",
        },
    );
    inline for (.{
        .{ "owned.reserveExternalModeDeinit()", 1 },
        .{ "owned.cancelReservedExternalModeDeinit()", 1 },
        .{ "source.transferReservedExternalModeDeinit(destination)", 2 },
        .{ "owned.finishReservedExternalModeDeinit()", 1 },
    }) |marker| try expectContainerMethodMarkerCount(
        allocator,
        pump_source,
        "ExternalPumpStorage",
        "teardownUnderHeldOperationLease",
        marker[0],
        marker[1],
    );
    try expectContainerMethodMarkerCount(
        allocator,
        slot_source,
        "ClientSlot",
        "initInPlaceWithIssuer",
        "publishClientSlot(registry_reservation)",
        1,
    );
    try expectOnlyDirectIdentifierReference(
        allocator,
        slot_source,
        "ClientSlot",
        "initInPlaceWithIssuer",
        "publishClientSlot",
    );
    try expectContainerMethodMarkerCount(
        allocator,
        slot_source,
        "ClientSlot",
        "initInPlaceWithIssuer",
        "publishClientSlot(",
        1,
    );
    try expectContainerMethodMarkersInOrder(
        allocator,
        source,
        "Client",
        "terminalReasonInvariant",
        &.{ "beginPublicMutation()", "self.unusable" },
    );
    try expectContainerMethodMarkersInOrder(
        allocator,
        source,
        "Client",
        "firstPoisonReason",
        &.{ "beginPublicMutation()", "self.first_poison_reason" },
    );
}

test "CR3a-2c2b3b prepare commit reads PID and callback TLS before graph then rechecks the fence at publish" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client.zig",
    );
    defer allocator.free(source);
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse
        return error.TestUnexpectedResult;
    const method = findContainerMethod(
        &tree,
        members,
        "Client",
        "prepareEndedPurgeCommit",
    ) orelse return error.TestUnexpectedResult;
    const body_start = functionBodyStart(&tree, method) orelse
        return error.TestUnexpectedResult;
    var process_id_token: ?std.zig.Ast.TokenIndex = null;
    var callback_tls_token: ?std.zig.Ast.TokenIndex = null;
    var first_self_token: ?std.zig.Ast.TokenIndex = null;
    var alias_gate_token: ?std.zig.Ast.TokenIndex = null;
    var ledger_gate_token: ?std.zig.Ast.TokenIndex = null;
    var token = body_start + 1;
    while (token <= tree.lastToken(method)) : (token += 1) {
        const text = tree.tokenSlice(token);
        if (process_id_token == null and std.mem.eql(u8, text, "currentProcessId"))
            process_id_token = token;
        if (callback_tls_token == null and
            std.mem.eql(u8, text, "generationAllocatorCallbackActive"))
            callback_tls_token = token;
        if (first_self_token == null and std.mem.eql(u8, text, "self")) first_self_token = token;
        if (alias_gate_token == null and
            std.mem.eql(u8, text, "validateEndedPurgeOwnerRanges"))
            alias_gate_token = token;
        if (ledger_gate_token == null and std.mem.eql(u8, text, "prepareDeinitGraph"))
            ledger_gate_token = token;
    }
    try std.testing.expect(process_id_token.? < callback_tls_token.?);
    try std.testing.expect(callback_tls_token.? < first_self_token.?);
    try std.testing.expect(alias_gate_token.? < ledger_gate_token.?);
    try expectContainerMethodMarkersInOrder(
        allocator,
        source,
        "Client",
        "prepareEndedPurgeCommit",
        &.{
            "candidate.lifecycle = .prepared;",
            "if (fence.owner_process_id != actual_pid",
            "if (!fence.sealExclusiveForPublication(",
            "scratch.lifecycle = .commit_frozen;",
            "out.* = candidate;",
        },
    );
    inline for (.{ "tryEnterShared", "tryAcquireExclusive" }) |receiver|
        try expectContainerMethodMarkerCount(
            allocator,
            source,
            "ClientOperationFence",
            receiver,
            "recordIntrusionIfExactExclusive(observed)",
            1,
        );
}

test "CR3a-2c2b3b finalizer gates PID and raw states before inherited graph access" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client.zig",
    );
    defer allocator.free(source);
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse
        return error.TestUnexpectedResult;
    const method = findContainerMethod(
        &tree,
        members,
        "Client",
        "finalizeEndedPurgeNoFreePoison",
    ) orelse return error.TestUnexpectedResult;
    const body_start = functionBodyStart(&tree, method) orelse
        return error.TestUnexpectedResult;
    var process_id_token: ?std.zig.Ast.TokenIndex = null;
    var proof_pid_token: ?std.zig.Ast.TokenIndex = null;
    var raw_state_gate_token: ?std.zig.Ast.TokenIndex = null;
    var first_fence_token: ?std.zig.Ast.TokenIndex = null;
    var token = body_start + 1;
    while (token <= tree.lastToken(method)) : (token += 1) {
        const text = tree.tokenSlice(token);
        if (process_id_token == null and std.mem.eql(u8, text, "currentProcessId"))
            process_id_token = token;
        if (proof_pid_token == null and std.mem.eql(u8, text, "process_id"))
            proof_pid_token = token;
        if (raw_state_gate_token == null and
            std.mem.eql(u8, text, "endedPurgeRawFinalizerStateValid"))
            raw_state_gate_token = token;
        if (first_fence_token == null and std.mem.eql(u8, text, "operation_fence"))
            first_fence_token = token;
    }
    try std.testing.expect(process_id_token != null);
    try std.testing.expect(proof_pid_token != null);
    try std.testing.expect(raw_state_gate_token != null);
    try std.testing.expect(first_fence_token != null);
    try std.testing.expect(process_id_token.? < proof_pid_token.?);
    try std.testing.expect(proof_pid_token.? < raw_state_gate_token.?);
    try std.testing.expect(raw_state_gate_token.? < first_fence_token.?);
}

test "CR3a-2c2b3a ended purge plan remains a neutral test-only leaf" {
    const allocator = std.testing.allocator;
    const leaf = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/ended_purge_transaction.zig",
    );
    defer allocator.free(leaf);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(leaf, "@import("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(leaf, "@import(\"std\")"));
    const forbidden = [_][]const u8{
        "@import(\"client.zig\")",
        "@import(\"client_slot.zig\")",
        "@import(\"generation_transport.zig\")",
        "@import(\"external_owner_seal.zig\")",
        "std.mem.Allocator",
        "*anyopaque",
        "@ptrFromInt",
    };
    for (forbidden) |needle|
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(leaf, needle));

    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or
            std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/ended_purge_transaction.zig",
            ) or
            std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/client.zig",
            ))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (std.mem.eql(u8, entry.path, "platform/macos/session_host.zig")) {
            try std.testing.expectEqual(
                @as(usize, 0),
                countStringLiteralOutsideTopLevelTests(source, "ended_purge_transaction.zig"),
            );
            try std.testing.expectEqual(
                @as(usize, 1),
                countOccurrences(source, "ended_purge_transaction.zig"),
            );
            try std.testing.expect(!joinedStringLiteralsContainOutsideTopLevelTests(
                source,
                "ended_purge_transaction.zig",
            ));
        } else {
            try std.testing.expectEqual(
                @as(usize, 0),
                countOccurrences(source, "ended_purge_transaction.zig"),
            );
            try std.testing.expect(!joinedStringLiteralsContain(
                source,
                "ended_purge_transaction.zig",
            ));
        }
    }
}

test "CR3a-2c2b3a joined import oracle excludes only top-level test bodies" {
    const product =
        "const leaf = @import(\"ended_purge_\" ++ \"transaction.zig\");\n";
    try std.testing.expect(joinedStringLiteralsContainOutsideTopLevelTests(
        product,
        "ended_purge_transaction.zig",
    ));
    const test_only =
        "test { _ = @import(\"ended_purge_\" ++ \"transaction.zig\"); }\n";
    try std.testing.expect(!joinedStringLiteralsContainOutsideTopLevelTests(
        test_only,
        "ended_purge_transaction.zig",
    ));
}

test "B3b-S reflection digest excludes top-level tests with a lexical token mask" {
    const allocator = std.testing.allocator;
    const source: [:0]const u8 =
        \\const Product = struct {
        \\    fn retained() void { const label = "test"; }
        \\    test "container declarations remain product input" { const containerRetained = true; _ = containerRetained; }
        \\};
        \\test "excluded" { const Hidden = struct { fn nested() void {} }; _ = Hidden; }
        \\test { const anonymousExcluded = true; _ = anonymousExcluded; }
        \\const After = struct { fn retainedAfter() void {} };
    ;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const excluded = try source_digest.topLevelTestTokenMask(allocator, &tree);
    defer allocator.free(excluded);

    var retained_count: usize = 0;
    var excluded_count: usize = 0;
    var anonymous_excluded_count: usize = 0;
    var container_retained_count: usize = 0;
    var retained_after_count: usize = 0;
    for (0..tree.tokens.len) |raw_token| {
        const token: std.zig.Ast.TokenIndex = @intCast(raw_token);
        const part = tree.tokenSlice(token);
        if (std.mem.eql(u8, part, "retained"))
            retained_count += @intFromBool(!excluded[token]);
        if (std.mem.eql(u8, part, "nested"))
            excluded_count += @intFromBool(excluded[token]);
        if (std.mem.eql(u8, part, "anonymousExcluded"))
            anonymous_excluded_count += @intFromBool(excluded[token]);
        if (std.mem.eql(u8, part, "containerRetained"))
            container_retained_count += @intFromBool(!excluded[token]);
        if (std.mem.eql(u8, part, "retainedAfter"))
            retained_after_count += @intFromBool(!excluded[token]);
    }
    try std.testing.expectEqual(@as(usize, 1), retained_count);
    try std.testing.expectEqual(@as(usize, 1), excluded_count);
    try std.testing.expectEqual(@as(usize, 2), anonymous_excluded_count);
    try std.testing.expectEqual(@as(usize, 2), container_retained_count);
    try std.testing.expectEqual(@as(usize, 1), retained_after_count);

    const malformed: [:0]const u8 = "const broken = ;";
    var malformed_tree = try std.zig.Ast.parse(allocator, malformed, .zig);
    defer malformed_tree.deinit(allocator);
    try std.testing.expect(malformed_tree.errors.len != 0);
    try std.testing.expectError(
        error.TestUnexpectedResult,
        source_digest.topLevelTestTokenMask(allocator, &malformed_tree),
    );
}

test "CR3a-2c2b3b declaration baseline admits only the doc-first owner delta" {
    const allocator = std.testing.allocator;
    const cases = [_]struct {
        path: []const u8,
        baseline_count: usize,
        baseline_digest: [32]u8,
        containers: []const []const u8,
        optional_containers: []const []const u8,
        allowed: []const DeclarationTuple,
    }{
        .{
            .path = "src/platform/macos/session_host/client.zig",
            .baseline_count = 535,
            // Event publication selector와 negotiated selection-state capability를 포함한
            // current Client declaration inventory를 고정한다. poison capture 두 곳이 사유 drift 를
            // 죽이지 않고 기록하게 되면서 로깅 함수 둘이 늘었다(530 → 532). E3c는 계측 import와
            // buffered runtime/connection 관측 둘만 추가한다(532 → 535).
            .baseline_digest = .{ 0xfe, 0xf5, 0xd4, 0x92, 0x3e, 0x89, 0x02, 0xee, 0xbc, 0x6f, 0x72, 0xca, 0x14, 0xba, 0xca, 0x7e, 0x82, 0x53, 0x39, 0x85, 0xf7, 0x5b, 0x7f, 0x77, 0x94, 0xc9, 0x83, 0x4e, 0xf5, 0x4b, 0xae, 0xfa },
            .containers = &.{ "Client", "EndedPurgeScratch", "PreparedEndedPurgeInventory" },
            .optional_containers = &.{ "PreparedEndedPurgeCommit", "ClientOperationFence" },
            .allowed = &.{
                // poison 이 어느 불변식에서 났는지 남기는 축(=진단). 판정은 안 바꾸고 사유만 적는다.
                .{ .parent = "Client", .kind = "const", .visibility = "pub", .modifier = "", .name = "ScopeInvalidAxis" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "logCanonicalScopeInvalid" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "notification_delivery_v1" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "catchup_barrier_contract" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "BufferedCatchupBarrier" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "writeProjectionCatchupBarriers" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ExternalCatchupBarrierPolicy" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "validateExternalSourceOwnerRangesWithPolicy" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "runtime_catchup_barrier_v1" },
                // Clear는 이미 배포된 core-command v1을 암묵 확장하지 않는 별도 N-1 협상 bit이다.
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "runtime_clear_screen_v1" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "pending_catchup_barriers" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "bufferCatchupBarrierFrame" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "preflightExternalAdoptionDestinationWithScratchPolicy" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "readCatchupBarrierUntil" },
                .{ .parent = "Client", .kind = "const", .visibility = "pub", .modifier = "", .name = "CatchupBarrierPlan" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "readCatchupBarrierPlanUntil" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "readCatchupBarrierUntilWithOps" },
                // P3-e4d-2b exact frozen GUI restore: public entrypoint rechecks the frozen hash,
                // while the private policy and leaves keep GUI/shutdown attestation independent.
                .{ .parent = "Client", .kind = "const", .visibility = "private", .modifier = "", .name = "LegacyHelloPolicy" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "connectFrozenGui" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "connectMajorWithPolicy" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "readCatchupBarrierPlanUntilWithOps" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "readCatchupBarrierWithIo" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "incident_binding_contract" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "incident_binding" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "incident_publication_contract" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "connection_incident" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "first_incident_id" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "incident_repeat_key" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "last_success_request_id" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "FdStatIdentity" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "FdSocketIdentity" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "fdStatIdentity" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "fdSocketIdentity" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventTakeKind" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "GenerationEventTakeLifecycle" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PreparedGenerationEventTake" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "OwnedGenerationEvent" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventPrepareError" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventCommitError" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "validateGenerationEventQueue" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "prepareGenerationEventTake" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitGenerationEventTake" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortGenerationEventTake" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "bufferGenerationEventForTest" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "bufferCanonicalEvent" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "ClientOperationFence" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "pub", .modifier = "", .name = "retirementAuthorityDigest" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "canRetireFromGenerationNode" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "retirementRangeAliasesOwnedBacking" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ended_purge_transaction" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ended_purge_quarantine" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "prepared_request_authority" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "operation_thread_identity" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "initRegisteredOperationExecutionCapabilityGuard" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "owner_process_nonce" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "executed_response_mod" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ObservedPreparedBlockingRpcExecutionError" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ObservedPreparedBlockingRpcExecution" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "executePreparedBlockingRpcStorageWithAllocatorObserved" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "executePreparedBlockingRpcStorageWithAllocatorInternal" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "discardFramePayloadObservation" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "readFrameWithAllocatorObserved" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedLifecycleRawValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedDescriptor" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedDescriptorRawMatches" },
                .{ .parent = "Client", .kind = "const", .visibility = "pub", .modifier = "", .name = "CanonicalPreparedAbortOutcome" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortPreparedBlockingRpcStorageCanonical" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PreparedEndedPurgeCommit" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "EndedPurgeCommitError" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "EndedPurgeClientCommitOutcome" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "prepareEndedPurgeCommit" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitEndedPurgePrepared" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "finalizeEndedPurgeNoFreePoison" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "tombstoneEndedPurgeOwnedGraph" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "publishEndedPurgeNoFreePoison" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "endedPurgePostValidate" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "publishEndedPurgeCompaction" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "cleanupEndedPurgeTargetDirect" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "operation_fence" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "operation_fence_generation" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "bindOperationFence" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "tryAcquireEndedPurgeExclusive" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "endedPurgeFenceIntruded" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginClientSlotOperation" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "endClientSlotOperation" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginConfirmedGenerationPoisonExclusive" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "endConfirmedGenerationPoisonExclusive" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "releaseEndedPurgeExclusiveClean" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitEndedPurgeExclusiveTerminal" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginPublicMutation" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "endPublicMutation" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "canTerminalizeSharedConnectionNoDestroy" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "terminalizeSharedConnectionNoDestroy" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "DeadlinePreparedBlockingRpcError" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "DeadlinePreparedBlockingRpcExecution" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "DeadlineRuntimeInventoryExecution" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "connectAdminUntil" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "connectFrozenShutdownUntil" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "connectMajorUntilWithOpsPolicy" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "finishHelloWithPolicy" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "executePreparedBlockingRpcStorageUntil" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "DeadlineObservedPreparedBlockingRpcExecutionError" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "DeadlineObservedPreparedBlockingRpcExecution" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "executePreparedBlockingRpcStorageUntilObserved" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "readFrameUntilEstablishedObserved" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "runtimeInventoryUntil" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "endedPurgeCompleteOwnerSeal" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "endedPurgeFinalizationSeal" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "endedPurgeRawFinalizerStateValid" },
                .{ .parent = "EndedPurgeScratch", .kind = "const", .visibility = "private", .modifier = "", .name = "PendingOutboundDescriptor" },
                .{ .parent = "EndedPurgeScratch", .kind = "const", .visibility = "private", .modifier = "", .name = "Lifecycle" },
                .{ .parent = "EndedPurgeScratch", .kind = "field", .visibility = "private", .modifier = "", .name = "build_id" },
                .{ .parent = "EndedPurgeScratch", .kind = "field", .visibility = "private", .modifier = "", .name = "client_lifecycle" },
                .{ .parent = "EndedPurgeScratch", .kind = "field", .visibility = "private", .modifier = "", .name = "lifecycle" },
                .{ .parent = "EndedPurgeScratch", .kind = "field", .visibility = "private", .modifier = "", .name = "pending_outbound" },
                .{ .parent = "PreparedEndedPurgeInventory", .kind = "field", .visibility = "private", .modifier = "", .name = "demux_owned_extent_bytes" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "const", .visibility = "private", .modifier = "", .name = "Lifecycle" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "self_addr" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "client_addr" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "scratch_addr" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "inventory_addr" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "target_stream" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "captured_fd" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "complete_owned_extent_bytes" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "complete_owner_seal" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "pre_callback_survivor_seal" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "batch_plan" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "stream_plan" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "event_plan" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "partial_plan" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "batch_cleanup_ordinal" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "stream_cleanup_ordinal" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "event_cleanup_ordinal" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "partial_cleanup_ordinal" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "finalization_seal" },
                .{ .parent = "PreparedEndedPurgeCommit", .kind = "field", .visibility = "private", .modifier = "", .name = "lifecycle" },
                .{ .parent = "ClientOperationFence", .kind = "const", .visibility = "private", .modifier = "", .name = "shared_count_mask" },
                .{ .parent = "ClientOperationFence", .kind = "const", .visibility = "private", .modifier = "", .name = "reserved_mask" },
                .{ .parent = "ClientOperationFence", .kind = "const", .visibility = "private", .modifier = "", .name = "publication_bit" },
                .{ .parent = "ClientOperationFence", .kind = "const", .visibility = "private", .modifier = "", .name = "terminal_bit" },
                .{ .parent = "ClientOperationFence", .kind = "const", .visibility = "private", .modifier = "", .name = "intrusion_bit" },
                .{ .parent = "ClientOperationFence", .kind = "const", .visibility = "private", .modifier = "", .name = "exclusive_bit" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "self_addr" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "client_addr" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "owner_process_id" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "slot_incarnation" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "node_incarnation" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "fence_generation" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "state" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "pub", .modifier = "", .name = "initInPlace" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "tryEnterShared" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "leaveShared" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "tryAcquireExclusive" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "recordIntrusionIfExactExclusive" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "sealExclusiveForPublication" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "intruded" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "abortExclusive" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "releaseExclusiveClean" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "commitExclusiveTerminal" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "identityMatches" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "generationAllocatorCallbackActive" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "read_pump_poison_capture_addr" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "prepareDeinitGraph" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "finishDeinitGraph" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "tryAcquireClientSlotTeardownExclusive" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortClientSlotTeardownExclusive" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "tryDeinitClientSlotExclusiveHeld" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "bufferedControllerRevokeForStreamUnchecked" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "sendScrollToBottomWithOps" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "sendScrollToBottomGuardedWithOps" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "sendCoreCommandWithOps" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "sendCoreCommandGuardedWithOps" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "writeBlockingStreamFrameWithOps" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "checkBlockingControlInjectedWrite" },
                .{ .parent = "Client", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationAllocatorPurpose" },
                .{ .parent = "Client", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationAllocatorScopeLifecycle" },
                .{ .parent = "Client", .kind = "const", .visibility = "private", .modifier = "", .name = "GenerationAllocatorScopeIdentity" },
                .{ .parent = "Client", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationAllocatorScope" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "allocatorEql" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "generation_allocator_scope_epoch" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "active_generation_allocator_scope" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PreparedRequestWireProgress" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedRequestExecutionLeaseLifecycle" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedRequestExecutionFenceMode" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PreparedRequestExecutionLease" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedExecutionLeaseSeal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedExecutionLeaseRawValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedExecutionFenceLeaseIdentity" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "externalRangeOverlapsClient" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedExecutionWriteResult" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedExecutionWriteOps" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedExecutionWriteProbe" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "", .name = "next_client_operation_fence_incarnation" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "issueClientOperationFenceIncarnation" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "RegisteredOperationExecutionCapability" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "RegisteredOperationExecutionHandle" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PinnedExecutionCapabilityGuard" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "RegisteredOperationExecutionMintReceipt" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "ExecutionCapabilityPublicationTestHook" },
                .{ .parent = "root", .kind = "var", .visibility = "pub", .modifier = "", .name = "execution_capability_publication_test_hook" },
                .{ .parent = "root", .kind = "var", .visibility = "pub", .modifier = "", .name = "execution_capability_read_test_hook" },
                .{ .parent = "ClientOperationFence", .kind = "const", .visibility = "private", .modifier = "", .name = "execution_lease_bit" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "fence_incarnation" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "execution_capability_addr" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "execution_capability_identity" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "execution_owner_thread_id" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "execution_owner_thread_incarnation" },
                .{ .parent = "ClientOperationFence", .kind = "field", .visibility = "private", .modifier = "", .name = "next_execution_capability_identity" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "tryAcquireExecutionLease" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "releaseExecutionLease" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "upgradeSingleSharedToExecutionLease" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "downgradeExecutionLeaseToSingleShared" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "executionLeaseHeld" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "issueExecutionCapabilityIdentity" },
                .{ .parent = "ClientOperationFence", .kind = "fn", .visibility = "private", .modifier = "", .name = "executionCapabilityMatches" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "requireRegisteredOperationExecutionCapability" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "endRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "setNextExecutionCapabilityIdentityForTest" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "nextExecutionCapabilityIdentityForTest" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "bufferedControllerRevokeUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "prepared_request_execution_lease_addr" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "prepared_request_execution_fence_addr" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "prepared_request_execution_fence_incarnation" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "prepared_request_execution_fence_lease_identity" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "prepared_request_execution_fence_mode" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginPreparedRequestExecution" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginPreparedRequestExecutionFromRegisteredOperation" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginPreparedRequestExecutionMode" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preparedRequestExecutionLeaseMatches" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedRequestExecutionLeaseAuthorityMatches" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preparedRequestExecutionPoisonReason" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "poisonPreparedRequestExecution" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "writePreparedRequestExecution" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "writePreparedRequestExecutionWithOps" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "setPreparedExecutionProgress" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "exactAllocatorCallbackOwner" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "capturePreparedExecutionPoison" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginReadPumpPoisonCapture" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "endReadPumpPoisonCapture" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "captureReadPumpPoison" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "poisonWhilePreparedExecutionHeld" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortPreparedBlockingRpcStorageUnderExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "abortPreparedBlockingRpcStorageCanonicalUnchecked" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "observePreparedRequestTerminalSinkEof" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "finishPreparedRequestExecution" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "releasePreparedRequestExecutionLeaseCanonical" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "flushPendingOutboundForPreparedExecution" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "flushPendingOutboundBlockingWithOps" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "restoreGenerationAllocatorScopeUnderExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "readPreparedResponseUnderExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitPreparedExecutionRecoveryPoisonNoFail" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preparedExecutionRecoveryPoisonedForTest" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitPreparedExecutionRecoveryCleanupNoFail" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "revalidatePreparedResponsePublication" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "restoreGenerationAllocatorScopeUnchecked" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "readCorrelatedPreparedResponse" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "readFrameWithAllocatorObservedUnderExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "readFrameWithAllocatorObservedUnchecked" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "bufferPendingScreenBatch" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "discardBufferedScreenStream" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "invalidateBufferedScreenStream" },
                .{ .parent = "Client", .kind = "const", .visibility = "private", .modifier = "", .name = "StreamFenceMode" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "pumpRxDemuxUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "poisonFrameRead" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "poisonDuringClientSlotOperationNoFail" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "terminalizePublishedIncidentChecked" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "markDeferredPoisonForTest" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "ValidatedGenerationEventTake" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventHeldError" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "callGuardedWithIo" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "callUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "prepareBlockingRpcGuarded" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "poisonMutationIo" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "validateGenerationEventTakeCore" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "commitValidatedGenerationEventTakeCore" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "validateGenerationEventTakeUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitGenerationEventTakeUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortGenerationEventTakeDuringRegisteredOperation" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortGenerationEventTakeUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "sendInputGuarded" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendInputUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "sendInputNonBlockingGuarded" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendInputNonBlockingUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "sendScrollToBottomNonBlockingGuarded" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendScrollToBottomNonBlockingUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "sendResyncNonBlockingGuarded" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendResyncNonBlockingUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "screenRecoveryState" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "sendCoreCommandNonBlockingGuarded" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendCoreCommandNonBlockingUnderRegisteredOperationExecutionLease" },
                // P4 user-action freshness uses the existing registered-operation control lease;
                // capability and sender are the only new Client declarations.
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "async_observation_probe_v1" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendObservationProbeNonBlockingUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendScrollToBottomUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendCoreCommandUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "flushPendingOutboundBlockingMode" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "pumpPendingOutputGuarded" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "pumpPendingOutputUnderRegisteredOperationExecutionLease" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "sendDontWait" },
                .{ .parent = "Client", .kind = "fn", .visibility = "pub", .modifier = "", .name = "ingestReadableOutOfBandEvidence" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "pollReadableOrTerminal" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "retirement_cleanup_testing_api" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "screen_inbox" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "ScreenRecoveryState" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "screenOverflowDuringCallPeer" },
                .{ .parent = "Client", .kind = "field", .visibility = "private", .modifier = "", .name = "screen_recovery" },
                .{ .parent = "Client", .kind = "fn", .visibility = "private", .modifier = "", .name = "screenInboxItems" },
            },
        },
        .{
            .path = "src/platform/macos/session_host/client_slot.zig",
            .baseline_count = 129,
            .baseline_digest = .{ 0x70, 0x0a, 0x3d, 0x6a, 0x2e, 0x4d, 0xd6, 0xa8, 0x5a, 0x65, 0xa7, 0x59, 0x2d, 0x1e, 0xed, 0xf9, 0x66, 0x18, 0x7e, 0x8f, 0xaa, 0x63, 0xfd, 0x3d, 0xe6, 0xd8, 0x61, 0xf5, 0x90, 0x35, 0x16, 0xef },
            .containers = &.{ "ClientSlot", "EndedPurgePreparation" },
            .optional_containers = &.{
                "PreparedExecutionTxn",
                "PreparedExecutionCleanup",
                "RegisteredNodeOperation",
                "RpcPublicationPayloadCleanup",
                "RpcPublicationFailureByteOutcome",
            },
            .allowed = &.{
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "encodeGenerationRequestParamsWithCapabilities" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "catchup_barrier_contract" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "client_deadline" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "DeadlineGenerationExecuteError" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "executeGenerationRequestUntil" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "executeGenerationRequestInternal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePublishedRpcResponseWithoutDecode" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "readAttachmentCatchupBarrierPlanUntil" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "requestAttachmentCatchupUntil" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightAttachmentControllerPromotion" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "promoteAttachmentControllerNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "callCurrentUntil" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "attachmentConnectionFailureReason" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightAttachmentConnectionFailedClosed" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "failCloseAttachmentConnection" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightAttachmentConnectionUsable" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightAttachmentDrop" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "readInitialSnapshotGuardedUntil" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "readInitialSnapshotGuardedInternal" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "incident_binding_contract" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "max_retired_clients" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PreparedRetiredClientReclaim" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedRetiredClientReclaimLifecycleRawValid" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "retiredNodeValidAt" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "retiredNodesValid" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "retiredClientCountUnchecked" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "firstEmptyRetiredIndex" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "overlapsRetiredNode" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "retiredClientCount" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "retiredClientNodeDigest" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "pub", .modifier = "", .name = "RetiredClientReclaimError" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "retiredClientReclaimSeal" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedRetiredClientReclaimValid" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "retiredNodeReadyForReclaim" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "prepareRetiredClientReclaim" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitRetiredClientReclaimNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightRetiredClientReclaim" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PublicationProcessIdentity" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "registered_operation_poison_testing_api" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "RegisteredOperationPoisonCaptureRequest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "armRegisteredOperationPoisonCapture" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "captureRegisteredOperationPoison" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePreWireTerminalForDeferredPublication" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePreWireTerminalWithLeaseImpl" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePreparedRpcLeaseOwnedWithReasonAndReleaseOrFailStop" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalizePreparedExecutionPoisonCaptureNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginReadPumpPoisonCapture" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "endReadPumpPoisonCapture" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "readAttachmentBatchInternal" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "publicationProcessIdentity" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "initManagedInPlace" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparationProjectionTestHook" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "preparation_projection_test_hook" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "testing" },
                .{ .parent = "testing", .kind = "fn", .visibility = "pub", .modifier = "", .name = "armPreparationProjectionReentry" },
                .{ .parent = "testing", .kind = "fn", .visibility = "pub", .modifier = "", .name = "enterExternalMode" },
                .{ .parent = "testing", .kind = "fn", .visibility = "pub", .modifier = "", .name = "rollbackGenerationEventPreparationPending" },
                .{ .parent = "testing", .kind = "const", .visibility = "pub", .modifier = "", .name = "AttachmentLease" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventPreparationProjection" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "GenerationEventPreparationProjectionContract" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "projectionFieldPointerFree" },
                .{ .parent = "root", .kind = "node", .visibility = "private", .modifier = "", .name = "comptime" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "GenerationEventEvidence" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "validatedGenerationEventEvidence" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "generationEventPreparationProjection" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginGenerationEventPreparationPending" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rollbackGenerationEventPreparationPendingForTest" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "TrustedGenerationEventEvidence" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "generationEventPreparationCandidateAllowed" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "process_seal_service" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "EventCorrelationInternal" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "EventCorrelation" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "EventCorrelationInput" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "eventCorrelationInternal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "eventCorrelationInternalConst" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "eventCorrelationDigest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "eventCorrelationInputValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "mintEventCorrelation" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "eventCorrelationMatches" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "FinalAdmissionKind" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rxDemuxAdmissionTransactionWithOperation" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "pumpGenerationRxDemux" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "operation_thread_identity" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "mintRegisteredOperationExecutionReceipt" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "runtime_event_wire" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventTakeRequest" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventIdentity" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventPublication" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventTakeOutcome" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventError" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationPoisonError" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventAttachmentReadiness" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEndedPurgeOutcome" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEndedPurgeError" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "purgeGenerationEndedStream" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "poisonGenerationConnection" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "generationEventCorrupt" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "takeGenerationEvent" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "generationEventAttachmentReadiness" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "generationEventOwnerCurrent" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "discardGenerationEventForTest" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventQuarantineReservation" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventQuarantineIdentity" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "generation_event_release_callback_active_addr" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventTrustedView" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventReleaseProjection" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventReleaseRequest" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationEventReleasePrepared" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "prepared_event_release_storage_size" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PreparedGenerationEventRelease" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "generationEventTrustedView" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "prepareGenerationEventRelease" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitGenerationEventRelease" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "pinProjectionFromMirror" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "generation_event_quarantine" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "GenerationEventQuarantine" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "", .name = "generation_event_quarantine_registry" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedEventReleaseLifecycle" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedEventReleaseDisposition" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedEventReleasePermitState" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedEventReleaseInternal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedEventRelease" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "compatibility" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "prepared_request_authority" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "client_poison" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "rpc_response_authority" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "CapabilityProjectionError" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "CapabilityProjectionRequest" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationRequestError" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationControlError" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationControlSend" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendGenerationControl" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendGenerationControlNonBlocking" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginGenerationControlOwner" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "mapGenerationControlClientError" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationRequestPrepare" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationPreparedRequest" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationRequestAbort" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationTransportOwnerQuery" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationRequestExecute" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationExecuteError" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ExecuteDisposition" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedExecutionPhase" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "FailStopReason" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedExecutionSettlementTag" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedExecutionSettlement" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "SettlementOutcome" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedExecutionSnapshot" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedExecutionCanonical" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedExecutionTxn" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "identityFromCanonical" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlementMatchesOutcome" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "failStopPreparedExecution" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RegisteredNodeLookup" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RegisteredNodeOperation" },
                .{ .parent = "RegisteredNodeOperation", .kind = "field", .visibility = "private", .modifier = "", .name = "node" },
                .{ .parent = "RegisteredNodeOperation", .kind = "field", .visibility = "private", .modifier = "", .name = "registry_index" },
                .{ .parent = "RegisteredNodeOperation", .kind = "field", .visibility = "private", .modifier = "", .name = "operation_id" },
                .{ .parent = "RegisteredNodeOperation", .kind = "field", .visibility = "private", .modifier = "", .name = "pid" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "max_registered_node_operations" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RegisteredNodeOperationEntry" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "", .name = "registered_node_operation_mutex" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "", .name = "registered_node_operations" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "", .name = "registered_node_operation_free_stack" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "", .name = "registered_node_operation_free_count" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "", .name = "next_registered_node_operation_id" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RegisteredNodeOperationReservation" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "reserveRegisteredNodeOperation" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "abortRegisteredNodeOperationReservation" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "publishRegisteredNodeOperation" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "resolveRegisteredNodeOperation" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "GenerationRequestOwner" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "streamOperationNodeIdle" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginRegisteredNodeOperation" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "endRegisteredNodeOperation" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "FinalAdmissionDecision" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "FinalAdmissionBlockers" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "FinalAdmissionProtectedRange" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "max_final_admission_protected_ranges" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "FinalAdmissionTransaction" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "FinalAdmissionBindingStatus" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalAdmissionOwnershipRawValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalAdmissionLifecycleRawValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "bindFinalAdmissionTransactionNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalAdmissionTransactionBindingStatus" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalAdmissionTransactionAddressActive" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "consumeFinalAdmissionTransactionNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalAdmissionTransactionSeal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalAdmissionDestinationValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginFinalAdmissionTransactionCore" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalAdmissionTransaction" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalAdmissionTransactionWithOperation" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginGenerationRequestOwner" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "projectGenerationCapabilities" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "stringifyGenerationParams" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "encodeGenerationRequestParams" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "encodeGenerationCoreCommand" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "prepareGenerationRequest" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortGenerationRequest" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "executeGenerationRequest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rollbackExecutingRequest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "terminalizeExecutingRequest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "terminalizeExecutingRequestWithStorageCleanup" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "responseDestinationValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "responseOwnerStillPristine" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "response_payload_allocation" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ResponsePayloadObserverBridge" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "failStopResponsePayloadProvenance" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "failStopResponsePayloadTransfer" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedExecutionCleanup" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ExecutionSettlementIntent" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "settleExecutionAfterCleanup" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "const", .visibility = "private", .modifier = "", .name = "CleanupStage" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "const", .visibility = "private", .modifier = "", .name = "CleanupLifecycle" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "const", .visibility = "private", .modifier = "", .name = "CleanupFailure" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "const", .visibility = "private", .modifier = "", .name = "CleanupOutcome" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "field", .visibility = "private", .modifier = "", .name = "self_addr" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "field", .visibility = "private", .modifier = "", .name = "lifecycle" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "field", .visibility = "private", .modifier = "", .name = "stage" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "field", .visibility = "private", .modifier = "", .name = "first_failure_raw" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "fn", .visibility = "private", .modifier = "", .name = "init" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "fn", .visibility = "private", .modifier = "", .name = "advance" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "fn", .visibility = "private", .modifier = "", .name = "finish" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "fn", .visibility = "private", .modifier = "", .name = "finishOrFailStop" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "fn", .visibility = "private", .modifier = "", .name = "ensureFinishedOrFailStop" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "fn", .visibility = "private", .modifier = "", .name = "revalidateFinishing" },
                .{ .parent = "PreparedExecutionCleanup", .kind = "fn", .visibility = "private", .modifier = "", .name = "rawValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "byteRangeFullyContained" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "byteRangesOverlap" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "issueGenerationResponseIncarnation" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ScopeTokenAliasAllocator" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightGenerationTransportTerminalize" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "terminalizeGenerationTransportOwner" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "mapGenerationRequestClientError" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ended_purge_quarantine" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "", .name = "ended_purge_quarantine_registry" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "", .name = "process_runtime_pid" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "", .name = "generation_response_incarnation_issuer" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "prepared_execution_cleanup_active_addr" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "finish_permit_alias_case_for_test" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RpcSubstrateFailStopTestHook" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "rpc_substrate_fail_stop_test_hook" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "pub", .modifier = "", .name = "ProcessRuntimeInitError" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "pub", .modifier = "", .name = "EndedPurgeCommitError" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "pub", .modifier = "", .name = "EndedPurgeResult" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedStreamOperationPermitConsume" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "private", .modifier = "", .name = "ExclusiveTeardownReservation" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "private", .modifier = "", .name = "RegisteredClientOperation" },
                .{ .parent = "RegisteredClientOperation", .kind = "field", .visibility = "private", .modifier = "", .name = "operation_id" },
                .{ .parent = "RegisteredClientOperation", .kind = "field", .visibility = "private", .modifier = "", .name = "registry_index" },
                .{ .parent = "RegisteredClientOperation", .kind = "field", .visibility = "private", .modifier = "", .name = "pid" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "initializeProcessRuntime" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitEndedPurge" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "streamOperationPermitRawTagsValid" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "streamOperationPermitSeal" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "prepareStreamOperationPermitConsume" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "consumeStreamOperationPermitUnchecked" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginRegisteredClientOperation" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "endRegisteredClientOperation" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginCanonicalAuthorityAccess" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "controllerAuthorityLive" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "controllerRevokePending" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginControllerRevoke" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "finishControllerRevoke" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginRegisteredExclusiveTeardown" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "abortRegisteredExclusiveTeardown" },
                .{ .parent = "EndedPurgePreparation", .kind = "fn", .visibility = "private", .modifier = "", .name = "rawTagsValid" },
                .{ .parent = "EndedPurgePreparation", .kind = "fn", .visibility = "private", .modifier = "", .name = "sealForCommit" },
                .{ .parent = "EndedPurgePreparation", .kind = "fn", .visibility = "private", .modifier = "", .name = "consumeAfterPermit" },
                .{ .parent = "PreparedExecutionTxn", .kind = "const", .visibility = "private", .modifier = "", .name = "InitError" },
                .{ .parent = "PreparedExecutionTxn", .kind = "const", .visibility = "private", .modifier = "", .name = "SettlementError" },
                .{ .parent = "PreparedExecutionTxn", .kind = "field", .visibility = "private", .modifier = "", .name = "self_addr" },
                .{ .parent = "PreparedExecutionTxn", .kind = "field", .visibility = "private", .modifier = "", .name = "node_addr" },
                .{ .parent = "PreparedExecutionTxn", .kind = "field", .visibility = "private", .modifier = "", .name = "operation_id" },
                .{ .parent = "PreparedExecutionTxn", .kind = "field", .visibility = "private", .modifier = "", .name = "reservation" },
                .{ .parent = "PreparedExecutionTxn", .kind = "field", .visibility = "private", .modifier = "", .name = "binding_identity" },
                .{ .parent = "PreparedExecutionTxn", .kind = "field", .visibility = "private", .modifier = "", .name = "canonical_prepared" },
                .{ .parent = "PreparedExecutionTxn", .kind = "field", .visibility = "private", .modifier = "", .name = "prepared_identity" },
                .{ .parent = "PreparedExecutionTxn", .kind = "field", .visibility = "private", .modifier = "", .name = "phase" },
                .{ .parent = "PreparedExecutionTxn", .kind = "field", .visibility = "private", .modifier = "", .name = "settlement" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "initBeforeBeginExecute" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "commitBeginExecute" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settleUnbegun" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "revalidatePreWire" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "rollbackPreWire" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePreWireTerminal" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "retireIssuerExhausted" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePostExecuteReusable" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePostExecuteTerminal" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePostExecuteTerminalWithLease" },
                .{ .parent = "PreparedRpcExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settleRecoveredTerminal" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "rollbackPreWireWithLease" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePreWireTerminalWithLease" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "failStopCleanupFailure" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "requireCleanupClosed" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "finishOrFailStop" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "ensureSettledOrFailStop" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "rawTagsValid" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "rawEmbeddedTagsValid" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "semanticPristine" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "ownerNode" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "snapshot" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "matchesSnapshot" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "canonicalExecuting" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "canonicalStillExact" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "canonicalStorage" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "postExecuteReady" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "publishReusable" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "publishTerminal" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "failStopSettlement" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "failStopAfterCallbackDrift" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedRpcExecutionPhase" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RpcExecutedResponse" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "responseDestinationSeal" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedRpcExecutionTxn" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "registeredNodeOperationOwnerEntry" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finishPreparedRpcLeaseOrFailStop" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePreparedRpcLeaseOwnedAndReleaseOrFailStop" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedRpcExecutionTestFailure" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "executePreparedRpcTerminalSink" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "B33DestinationOccupyingAllocator" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "B33CompositeScenario" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "runB33CompositeScenario" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RpcPublicationPayloadCleanup" },
                .{ .parent = "RpcPublicationPayloadCleanup", .kind = "field", .visibility = "private", .modifier = "", .name = "self_addr" },
                .{ .parent = "RpcPublicationPayloadCleanup", .kind = "field", .visibility = "private", .modifier = "", .name = "receipt" },
                .{ .parent = "RpcPublicationPayloadCleanup", .kind = "field", .visibility = "private", .modifier = "", .name = "failure_release" },
                .{ .parent = "RpcPublicationPayloadCleanup", .kind = "field", .visibility = "private", .modifier = "", .name = "test_pre_release_stage_drift" },
                .{ .parent = "RpcPublicationPayloadCleanup", .kind = "field", .visibility = "private", .modifier = "", .name = "armed" },
                .{ .parent = "RpcPublicationPayloadCleanup", .kind = "field", .visibility = "private", .modifier = "", .name = "seal" },
                .{ .parent = "RpcPublicationPayloadCleanup", .kind = "fn", .visibility = "private", .modifier = "", .name = "arm" },
                .{ .parent = "RpcPublicationPayloadCleanup", .kind = "fn", .visibility = "private", .modifier = "", .name = "takeIfExact" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rpcPublicationPayloadCleanupSeal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rpcPublicationFailureFreeEvidence" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RpcPublicationFailureByteDisposition" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RpcPublicationFailureByteOutcome" },
                .{ .parent = "RpcPublicationFailureByteOutcome", .kind = "field", .visibility = "private", .modifier = "", .name = "disposition" },
                .{ .parent = "RpcPublicationFailureByteOutcome", .kind = "field", .visibility = "private", .modifier = "", .name = "response_epoch" },
                .{ .parent = "RpcPublicationFailureByteOutcome", .kind = "field", .visibility = "private", .modifier = "", .name = "free_evidence" },
                .{ .parent = "RpcPublicationFailureByteOutcome", .kind = "field", .visibility = "private", .modifier = "", .name = "retire_clean_evidence" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "closeRpcPublicationDestinationNoFree" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "settleRpcPublicationFailureBytes" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "runB345RpcProduct" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "rpc_executed_response" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "RpcFreeEvidenceState" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "RpcFreeEvidenceRecord" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rpcFreeEvidenceStateRawValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rpcFreeEvidenceSeal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rpcFreeEvidenceFixture" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rpcOwnerIdentity" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rpcAuthorityCanonical" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "rpcTerminalEvidence" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedRpcPublicationScope" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedRpcExecutionMode" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PreparedRpcFreeEvidenceRetirePermit" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationRpcSubstrateExecute" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "ResponseDestination" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RpcExecutionDestination" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "resolveResponseDestination" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "executeGenerationRpcSubstrate" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "canonicalRpcResponseAddress" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "executePreparedRpcPrivate" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "publishPreparedRpcResponse" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "failStopRpcPublication" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "executePreparedRpcCorrelatedResponseForTest" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "RpcResponseDisposition" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "failStopPermitAliasPreflight" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "FinishPermitRawStorage" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "armFinishPermitAliasForTest" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "armRpcSubstrateFailStopForTest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginRpcResponseBorrow" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finishRpcResponseOwned" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "terminalizeBorrowedRpcResponseNoFree" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "failStopFreedRpcResponse" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePostExecuteReusableUnderPublicationScope" },
                .{ .parent = "PreparedExecutionTxn", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlePostExecuteReusableUnchecked" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationInputError" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "EventTakeActivationTransaction" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "EventTakeActivationTestHook" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "const", .visibility = "private", .modifier = "", .name = "Lifecycle" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "self_addr" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "lifecycle_raw" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "admission" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "prepared_addr" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "permit_registry_id" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "quarantine_reservation" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "pin_projection" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "authority_receipt" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "quarantine_live" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "pin_live" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "authority_live" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "field", .visibility = "private", .modifier = "", .name = "seal" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "fn", .visibility = "private", .modifier = "", .name = "digest" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "fn", .visibility = "private", .modifier = "", .name = "reseal" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "fn", .visibility = "private", .modifier = "", .name = "setQuarantineLive" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "fn", .visibility = "private", .modifier = "", .name = "setPinLive" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "fn", .visibility = "private", .modifier = "", .name = "setAuthorityLive" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "fn", .visibility = "private", .modifier = "", .name = "setResourceLive" },
                .{ .parent = "EventTakeActivationTransaction", .kind = "fn", .visibility = "private", .modifier = "", .name = "finish" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginEventTakeActivationTransaction" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "runC3a3ProductTakeFaultCase" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalAdmissionTransactionWithOperationPermitAndRegistry" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finalAdmissionTransactionWithOperationAndRegistry" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "pumpGenerationPendingOutput" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendGenerationInput" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendGenerationInputNonBlocking" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginGenerationInputOwner" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginBoundControllerMutationOwner" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "sendGenerationResyncNonBlocking" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "generationScreenRecoveryState" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "callGenerationRpc" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "consumeStreamOperationPermitNoFail" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "settlement_contract" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "event_release_proof_loss_marker_fd" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "event_release_death_stage_raw" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "pendingEventReleaseCallbackActive" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "writeEventReleaseDeathMarker" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PendingEventReleaseCallbackBinding" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "pending_event_release_callback_binding" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "EventReleasePostSnapshot" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "event_release_post_snapshot" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "pending_event_payload_callback_count" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "anyGenerationEventReleaseCallbackActive" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "pendingEventCorrelationDigest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "reasonProjection" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "settlementDigest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "deriveCanonicalEffectPlan" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "setPlanTerminalFd" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "setPlanAllocatorCleanup" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "descriptorMatchesPlan" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "validateCanonicalEffectPrestate" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "validateCanonicalEffectPoststate" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "executeCanonicalEffectPlanNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "effectProofLoss" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightPendingEffect" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "operationFromEffectPermit" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortPendingEffectPreAdmissionNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitPendingEffectNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightPendingEventReleaseUnderEffect" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "PendingEventReleaseBegunLifecycle" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PendingEventReleaseBegun" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "pristinePendingEventReleaseBegunDigest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "pendingEventReleaseBegunSeal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "validPendingEventReleaseBegun" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "advancePendingEventReleaseBegunNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "validatePendingEventReleaseFinal" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preparePendingEventReleaseBegunNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "markPendingEventOwnerTombstonedNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginPendingEventReleaseResourcesNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "markPendingEventCorrelationTombstonedNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "markPendingEventMirrorTombstonedNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "finishPendingEventReleaseNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "releaseAttachmentBatchResult" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "pinProjectionFromEventReleasePermit" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "hashInt" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "registryEventReleaseFromComposite" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "incident_publication_contract" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "connection_incident" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "IncidentOperationQuery" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "IncidentOperationError" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finishSemanticDigest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "incidentAuthorityDigest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "incidentCommitDigest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "incidentRepeatCommitDigest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "incidentOperationReceiptDigest" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "IncidentPublicationTestHook" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "incident_publication_testing" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "traceIncidentPublication" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "incidentOperationSeal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "incidentRepeatKeySeal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "incidentOperationProofLoss" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "incidentOperationOwner" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginIncidentClientOperation" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "resolveIncidentClientOperation" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "bindIncidentClientPublication" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "bindIncidentClientRepeatPublication" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitFirstIncidentClientPublicationNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitRepeatIncidentClientPublicationNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "finishIncidentClientOperationNoFail" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "TerminalDrainRunnerChannel" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "terminal_contract" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "extern", .name = "getdtablesize" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "TerminalDrainCallbackBinding" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "terminal_drain_callback_binding" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "TerminalDrainContinuation" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "TerminalDrainTestHook" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "terminal_drain_test_hook" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "terminal_drain_subprocess_stage_raw" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "terminalDrainIdentitySealInput" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "terminalDrainStateSealInput" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "terminalDrainContinuationCurrent" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "advanceTerminalDrainContinuationNoFail" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "terminalDrainProofLoss" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "TerminalDrainReentryProbe" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "publishTerminalDrainFixture" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "TerminalDrainProofStage" },
                .{ .parent = "root", .kind = "const", .visibility = "private", .modifier = "", .name = "terminal_drain_marker_fd" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "terminalDrainMonotonicMs" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "killAndReapTerminalDrainChild" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "runTerminalDrainProofChild" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "dispatchTerminalDrainProofChild" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "terminalDrainMarkerIsFifo" },
                .{ .parent = "root", .kind = "var", .visibility = "private", .modifier = "threadlocal", .name = "rpc_decoder_callback_active" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "GenerationRpcDecodedExecute" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "executeGenerationRpcDecoded" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "beginRpcResponseBorrowUnderOwner" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "finishRpcResponseOwnedUnderOwner" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "terminalAttachmentBatchKind" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightTerminalAttachmentBatch" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "prepareTerminalCleanupSummary" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "beginTerminalCleanupPublicationNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "publishTerminalAttachmentBatchNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "tryDeinitWithTerminalCleanup" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "AdmissionLifecycle" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PreparedAdmissionClose" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PreparedRetirementCleanup" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "cr3bR1Client" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "admissionLifecycleRawValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedAdmissionCloseLifecycleRawValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedRetirementCleanupLifecycleRawValid" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "pub", .modifier = "", .name = "CurrentBorrowError" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "pub", .modifier = "", .name = "AdmissionCloseError" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "admissionCloseSeal" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "admissionClosePermitValid" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "withCurrent" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "connectionGeneration" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "mapCurrentBorrowError" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "callCurrent" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "ingestCurrentReadableEvidence" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "currentCanTerminalizeNoDestroy" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "terminalizeCurrentNoDestroy" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "prepareAdmissionClose" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitAdmissionClose" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "cancelAdmissionClose" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "retirementCleanupSeal" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "retirementCleanupValid" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "pub", .modifier = "", .name = "RetirementCleanupError" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "prepareRetirementCleanup" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "retirementCleanupMatchesClient" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightRetirementCleanup" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortRetirementCleanup" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitRetirementCleanupNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "finishRetirementCleanup" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "RetirementLifecycle" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "retirementLifecycleRawValid" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "pub", .modifier = "", .name = "RetirementDetachError" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightRetirementDetach" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "commitRetirementDetachNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "validateRetirementPlaceholder" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PreparedClientReplacement" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedClientReplacementLifecycleRawValid" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "publishClientSlotReplacement" },
                .{ .parent = "ClientSlot", .kind = "field", .visibility = "private", .modifier = "", .name = "retired" },
                .{ .parent = "ClientSlot", .kind = "field", .visibility = "private", .modifier = "", .name = "reserved_replacement_addr" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "retiredNodeValid" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "consumedRetirementCleanupValid" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "clientReplacementSeal" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "bindReplacementIncidentIdentityNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "replacementIncidentIdentityPreflight" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "preparedClientReplacementValid" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "clientReplacementCandidateDigest" },
                .{ .parent = "ClientSlot", .kind = "const", .visibility = "pub", .modifier = "", .name = "ClientReplacementError" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "reserveClientReplacementNode" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightReservedClientReplacementNode" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortReservedClientReplacementNode" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "reservedClientReplacementReceiptValid" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "publishReservedClientReplacementAfterRetirementNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "prepareClientReplacement" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "abortClientReplacement" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "publishClientReplacementNoFail" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightClientReplacement" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightPublishedClientReplacement" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightRetirementCleanupBeforeAdmissionClose" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "pub", .modifier = "", .name = "preflightRetirementDetachBeforeAdmissionClose" },
                .{ .parent = "ClientSlot", .kind = "fn", .visibility = "private", .modifier = "", .name = "clientReplacementSealAfterPublish" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "ManagedPoisonError" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "managedPoisonSeal" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "prepareManagedPoison" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "prepareManagedPoisonRequest" },
                .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "PreparedExecutionPoisonCaptureRequest" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "prepareManagedPoisonRequestPinned" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "incidentParserPhase" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "incidentOutboundPhase" },
                .{ .parent = "root", .kind = "fn", .visibility = "private", .modifier = "", .name = "prepareManagedPoisonPinned" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "managedPoisonQuery" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "managedPoisonWillPublishFirst" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "consumeManagedPoison" },
                .{ .parent = "root", .kind = "fn", .visibility = "pub", .modifier = "", .name = "terminalizeManagedPoisonNoFail" },
            },
        },
    };
    for (cases) |case| {
        const source = try readZigFileZ(allocator, case.path);
        defer allocator.free(source);
        const inventory = try declarationInventory(
            allocator,
            source,
            case.containers,
            case.optional_containers,
            case.allowed,
        );
        try std.testing.expect(inventory.total_count >= case.baseline_count);
        if (inventory.total_count > case.baseline_count + case.allowed.len)
            std.debug.print(
                "declaration budget exceeded for {s}: total={d} frozen={d} observed-baseline={d} allowed={d}\n",
                .{ case.path, inventory.total_count, case.baseline_count, inventory.baseline_count, case.allowed.len },
            );
        try std.testing.expect(inventory.total_count <= case.baseline_count + case.allowed.len);
        try std.testing.expectEqual(case.baseline_count, inventory.baseline_count);
        try std.testing.expectEqual(case.baseline_digest, inventory.baseline_digest);
        for (case.allowed) |allowed|
            try std.testing.expect((try inventoryCount(
                allocator,
                source,
                allowed,
            )) <= 1);
    }
    const client = try readZigFileZ(allocator, cases[0].path);
    defer allocator.free(client);
    const client_slot = try readZigFileZ(allocator, cases[1].path);
    defer allocator.free(client_slot);
    try expectExactImport(
        allocator,
        client,
        "ended_purge_transaction",
        "@import(\"ended_purge_transaction.zig\")",
    );
    try expectExactImport(
        allocator,
        client,
        "ended_purge_quarantine",
        "@import(\"ended_purge_quarantine.zig\")",
    );
    try expectAbsentOrExactImport(
        allocator,
        client_slot,
        "ended_purge_quarantine",
        "@import(\"ended_purge_quarantine.zig\")",
    );
    if (countIdentifierOutsideTopLevelTests(client_slot, "ended_purge_quarantine_registry") != 0) {
        try expectRootConstTypeAndInitializer(
            allocator,
            client_slot,
            "ended_purge_quarantine_registry",
            "?ended_purge_quarantine.Registry",
            "null",
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            countOccurrences(client_slot, "ended_purge_quarantine.Registry.init()"),
        );
    }
    if (countIdentifierOutsideTopLevelTests(client_slot, "process_runtime_pid") != 0) {
        try expectRootConstTypeAndInitializer(
            allocator,
            client_slot,
            "process_runtime_pid",
            "std.atomic.Value(u32)",
            ".init(0)",
        );
    }
    try expectRootContainerFieldsWithOptional(
        allocator,
        client,
        "ClientOwnership",
        &.{ "standalone", "external_pump", "moved" },
        "quarantined_no_free",
    );
    try expectRootContainerFieldsWithOptional(
        allocator,
        client_slot,
        "EndedPurgePreparationLifecycle",
        &.{ "empty", "prepared", "committing", "consumed", "aborted" },
        "__forbidden__",
    );
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(client_slot, "const State = enum(u8) { empty, live, consume_reserved, consumed };"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(client_slot, "state: std.atomic.Value(u8) = .init(@intFromEnum(State.empty)),"));
    try expectPreparedEndedPurgeCommitSchema(allocator, client);
    try expectPreparedStreamOperationPermitConsumeSchema(allocator, client_slot);
    inline for (.{
        "prepareEndedPurgeCommit",
        "commitEndedPurgePrepared",
        "finalizeEndedPurgeNoFreePoison",
    }) |method_name| try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(client, method_name),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try inventoryCount(allocator, client, .{
            .parent = "Client",
            .kind = "fn",
            .visibility = "pub",
            .modifier = "",
            .name = "prepareEndedPurgeCommit",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try inventoryCount(allocator, client, .{
            .parent = "Client",
            .kind = "fn",
            .visibility = "pub",
            .modifier = "",
            .name = "finalizeEndedPurgeNoFreePoison",
        }),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try inventoryCount(allocator, client, .{
            .parent = "Client",
            .kind = "fn",
            .visibility = "pub",
            .modifier = "",
            .name = "commitEndedPurgePrepared",
        }),
    );
    try expectClientOperationFenceSchema(allocator, client);
    try expectClientOperationFenceBindingSchema(allocator, client);
    try expectClientNodeOperationFenceSchema(allocator, client_slot);
    try expectClientSlotOperationReservationSchemas(allocator, client_slot);
    const fence_bit_contract = [_][]const u8{
        "const shared_count_mask: u64 = (@as(u64, 1) << 31) - 1;",
        "const reserved_mask: u64 = ((@as(u64, 1) << 60) - 1) & ~shared_count_mask;",
        "const publication_bit: u64 = @as(u64, 1) << 60;",
        "const terminal_bit: u64 = @as(u64, 1) << 61;",
        "const intrusion_bit: u64 = @as(u64, 1) << 62;",
        "const exclusive_bit: u64 = @as(u64, 1) << 63;",
    };
    for (fence_bit_contract) |declaration|
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(client, declaration));
    try std.testing.expectEqual(
        // Initial publication, ordinary replacement, and CR5b reserved-node publication each
        // create one node-local operation fence before the Client becomes current.
        @as(usize, 3),
        countOccurrences(client_slot, "client_mod.ClientOperationFence.initInPlace("),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        countIdentifierOutsideTopLevelTests(client_slot, "bindOperationFence"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(client_slot, "beginClientSlotOperation"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(client_slot, "endClientSlotOperation"),
    );
    try std.testing.expectEqual(
        // R1 stack borrow/admission, managed poison, R2a/R2b와 CR3c pre-admission 두 preflight가 같은 operation으로 current node를 고정한다.
        @as(usize, 20),
        countIdentifierOutsideTopLevelTests(client_slot, "beginRegisteredClientOperation"),
    );
    try std.testing.expectEqual(
        // 위 operation들과 CR4c controller 승격, CR5 host-wide attachment-drop preflight가
        // 같은 등록 operation을 닫는다.
        @as(usize, 27),
        countIdentifierOutsideTopLevelTests(client_slot, "endRegisteredClientOperation"),
    );
    try std.testing.expectEqual(
        // 일반 teardown, 2d2 terminal aggregate teardown, R2c ordinary replacement와 CR5b
        // reserved-node publication이 같은 배타적 fence를 연다.
        @as(usize, 5),
        countIdentifierOutsideTopLevelTests(client_slot, "beginRegisteredExclusiveTeardown"),
    );
    try std.testing.expectEqual(
        // 일반 teardown, 2d2 terminal aggregate teardown과 R2c abort가
        // 모두 같은 exclusive fence 해제 함수로 수렴한다.
        @as(usize, 6),
        countIdentifierOutsideTopLevelTests(client_slot, "abortRegisteredExclusiveTeardown"),
    );
    try std.testing.expectEqual(
        // 두 번째 참조는 builtin.is_test 활성화 경합 probe이고 세 번째는 unpublished
        // R2c candidate abort다.
        @as(usize, 3),
        countIdentifierOutsideTopLevelTests(client_slot, "tryAcquireClientSlotTeardownExclusive"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(client_slot, "abortClientSlotTeardownExclusive"),
    );
    try std.testing.expectEqual(
        // ordinary slot deinit, unpublished R2c abort와 test-only retired fixture reclaim.
        @as(usize, 3),
        countIdentifierOutsideTopLevelTests(client_slot, "tryDeinitClientSlotExclusiveHeld"),
    );
    try expectContainerMethodMarkersInOrder(
        allocator,
        client_slot,
        "ClientSlot",
        "tryDeinit",
        &.{
            "beginRegisteredExclusiveTeardown",
            "defer if (exclusive_reserved)",
            "self.valid()",
            "cleanup_registry.preflightDeinit",
            "tryDeinitClientSlotExclusiveHeld",
        },
    );
    try expectContainerMethodMarkersInOrder(
        allocator,
        client_slot,
        "ClientSlot",
        "prepareStreamOperationPermit",
        &.{
            "client_mod.generationAllocatorCallbackActive()",
            "beginRegisteredClientOperation",
            "registerStreamOperationPermit",
        },
    );
    const client_teardown_commit_marker = "if (!node.client.tryDeinitClientSlotExclusiveHeld()) return .busy;";
    const client_teardown_commit = std.mem.indexOf(
        u8,
        client_slot,
        client_teardown_commit_marker,
    ) orelse return error.TestUnexpectedResult;
    const ordinary_slot_deinit_end = std.mem.indexOfPos(
        u8,
        client_slot,
        client_teardown_commit,
        "    pub fn tryDeinitWithTerminalCleanup(self: *ClientSlot) DeinitOutcome",
    ) orelse return error.TestUnexpectedResult;
    const post_client_teardown = client_slot[client_teardown_commit + client_teardown_commit_marker.len .. ordinary_slot_deinit_end];
    try std.testing.expect(!std.mem.containsAtLeast(u8, post_client_teardown, 1, "return .busy"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, post_client_teardown, 1, "return .corrupt"));
    const client_fence_first = [_]struct { name: []const u8, markers: []const []const u8 }{
        .{ .name = "tryDeinit", .markers = &.{ "const operation_fence = self.operation_fence", "checkedAllocatorReentry" } },
        .{ .name = "ensureUsable", .markers = &.{ "beginPublicMutation", "checkedAllocatorReentry" } },
        .{ .name = "poison", .markers = &.{ "beginPublicMutation", "checkedAllocatorReentry" } },
        .{ .name = "dropBufferedStream", .markers = &.{ "beginPublicMutation", "checkedAllocatorReentry" } },
        .{ .name = "takeEventForStream", .markers = &.{ "beginPublicMutation", "checkedAllocatorReentry" } },
        .{ .name = "releaseEvent", .markers = &.{ "beginPublicMutation", "checkedAllocatorReentry" } },
        .{ .name = "readGenerationBatch", .markers = &.{ "requireBlockingMode", "checkedAllocatorReentry" } },
        .{ .name = "prepareBlockingRpc", .markers = &.{"requireBlockingMode"} },
        .{ .name = "abortPreparedBlockingRpcStorage", .markers = &.{ "beginPublicMutation", "checkedAllocatorReentry" } },
        .{ .name = "preflightPreparedBlockingRpcStorageExecution", .markers = &.{"ensureUsable"} },
        .{ .name = "executePreparedBlockingRpcStorageWithAllocatorInternal", .markers = &.{ "beginPublicMutation", "checkedAllocatorReentry" } },
    };
    for (client_fence_first) |contract_entry|
        try expectContainerMethodMarkersInOrder(
            allocator,
            client,
            "Client",
            contract_entry.name,
            contract_entry.markers,
        );
    const slot_aggregate = [_]struct { name: []const u8, mutation: []const u8 }{
        .{ .name = "reserveAttachmentBinding", .mutation = "cleanup_registry.reserve" },
        .{ .name = "prepareStreamOperationPermit", .mutation = "registerStreamOperationPermit" },
        .{ .name = "releaseAttachmentBatchResult", .mutation = "prepareGenerationAccountingConsume" },
    };
    for (slot_aggregate) |contract_entry|
        try expectContainerMethodMarkersInOrder(
            allocator,
            client_slot,
            "ClientSlot",
            contract_entry.name,
            &.{ "beginRegisteredClientOperation", "defer self.endRegisteredClientOperation(operation)", contract_entry.mutation },
        );
    for ([_][]const u8{
        "tryAcquireEndedPurgeExclusive",
        "releaseEndedPurgeExclusiveClean",
    }) |exclusive_wrapper|
        try std.testing.expectEqual(
            @as(usize, 1),
            countIdentifierOutsideTopLevelTests(client_slot, exclusive_wrapper),
        );
    for ([_][]const u8{
        "endedPurgeFenceIntruded",
        "commitEndedPurgeExclusiveTerminal",
    }) |exclusive_wrapper|
        try std.testing.expectEqual(
            @as(usize, 0),
            countIdentifierOutsideTopLevelTests(client_slot, exclusive_wrapper),
        );
    inline for (.{
        "prepareEndedPurgeCommit",
        "commitEndedPurgePrepared",
        "finalizeEndedPurgeNoFreePoison",
    }) |client_method| try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(client_slot, client_method),
    );
    try expectContainerMethodMarkersInOrder(
        allocator,
        client_slot,
        "ClientSlot",
        "commitEndedPurge",
        &.{
            "tryAcquireEndedPurgeExclusive",
            "prepareEndedPurgeCommit",
            "quarantine_registry.reserve",
            "prepareStreamOperationPermitConsume",
            "sealForCommit",
            "commitEndedPurgePrepared",
            "quarantine_registry.commit",
            "quarantine_registry.consumeCommitted",
            "finalizeEndedPurgeNoFreePoison",
            "consumeStreamOperationPermitUnchecked",
            "consumeAfterPermit",
        },
    );
    try expectContainerMethodMarkerCount(
        allocator,
        client_slot,
        "ClientSlot",
        "commitEndedPurge",
        "unregisterStreamOperationPermit",
        0,
    );
    try expectEndedPurgeInventorySubtotalMigration(allocator, client);
    try expectEndedPurgeScratchDelta(allocator, client);
    try expectRootErrorSetExact(
        allocator,
        client,
        "EndedPurgeCommitError",
        &.{ "InvalidOwner", "InvalidState", "Corrupt", "ArithmeticOverflow", "DestinationOccupied" },
    );
    try expectRootEnumExact(
        allocator,
        client,
        "EndedPurgeClientCommitOutcome",
        &.{ "clean", "drift_pending_finalize" },
    );
    try expectNestedErrorSetAbsentOrExact(
        allocator,
        client_slot,
        "ClientSlot",
        "ProcessRuntimeInitError",
        &.{ "ProcessDomainMismatch", "ProcessSealUnavailable" },
    );
    try expectNestedErrorSetAbsentOrExact(
        allocator,
        client_slot,
        "ClientSlot",
        "EndedPurgeCommitError",
        &.{ "InvalidOwner", "InvalidState", "Busy", "Corrupt", "ArithmeticOverflow", "DestinationOccupied", "QuarantineUnavailable" },
    );
    try expectNestedEnumAbsentOrExact(
        allocator,
        client_slot,
        "ClientSlot",
        "EndedPurgeResult",
        &.{"purged"},
    );
}

test "CR3a-2c2b3b quarantine leaf is absent or exposes only the frozen public API" {
    const allocator = std.testing.allocator;
    const source = (try readOptionalZigFileZ(
        allocator,
        "src/platform/macos/session_host/ended_purge_quarantine.zig",
    )) orelse return;
    defer allocator.free(source);
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(source, "@import("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "@import(\"std\")"));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "@import(\"process_identity.zig\")"),
    );
    const expected = [_]DeclarationTuple{
        .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "max_ended_purge_quarantine_bytes" },
        .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "Error" },
        .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "Reservation" },
        .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "CommitReceipt" },
        .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "ConsumedCommitProof" },
        .{ .parent = "root", .kind = "const", .visibility = "pub", .modifier = "", .name = "Registry" },
    };
    try expectPublicRootDeclarationsExact(allocator, source, &expected);
    const forbidden = [_][]const u8{
        "client.zig",
        "client_slot.zig",
        "std.mem.Allocator",
        "*anyopaque",
        "@ptrFromInt",
        "callback",
        "payload",
    };
    for (forbidden) |needle|
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(source, needle));
    try expectEndedPurgeQuarantineSchema(allocator, source);
    try expectRootConstTypeAndInitializer(
        allocator,
        source,
        "max_ended_purge_quarantine_bytes",
        "usize",
        "64 * 1024 * 1024",
    );
}

test "CR3a-2c2b3b product process bootstrap stays explicit before AppSession ownership" {
    const allocator = std.testing.allocator;
    const client_slot = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_slot.zig",
    );
    defer allocator.free(client_slot);
    const host_adapter = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/host_adapter.zig",
    );
    defer allocator.free(host_adapter);
    const app_session = try readZigFileZ(
        allocator,
        "src/platform/macos/app_session.zig",
    );
    defer allocator.free(app_session);

    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            host_adapter,
            "client_slot_mod.ClientSlot.initializeProcessRuntime()",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 9),
        countOccurrences(
            app_session,
            "RemoteSessionAdapter.initializeProcessRuntime()",
        ),
    );
    const bootstrap = std.mem.indexOf(
        u8,
        app_session,
        "RemoteSessionAdapter.initializeProcessRuntime()",
    ) orelse return error.TestUnexpectedResult;
    const owner_publish = std.mem.indexOfPos(
        u8,
        app_session,
        bootstrap,
        "self.* = .{",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(bootstrap < owner_publish);
    try std.testing.expect(std.mem.indexOf(
        u8,
        client_slot,
        "builtin.is_test and process_runtime_pid",
    ) == null);
}

test "CR3a-2a generation attachment contract remains a neutral authority leaf" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/generation_attachment_contract.zig",
    );
    defer allocator.free(source);
    // The leaf carries scalar identities only. In particular, a stored address is never turned
    // back into an owner pointer here; only the node-specific adapter may access backing owners.
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(source, "@import("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "@import(\"std\")"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "@import(\"runtime_control_types.zig\")"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(source, "@ptrFromInt"));
    const forbidden = [_][]const u8{
        "@import(\"client.zig\")",
        "@import(\"client_slot.zig\")",
        "@import(\"host_adapter.zig\")",
        "@import(\"remote_runtime.zig\")",
        "@import(\"remote_attachment.zig\")",
    };
    for (forbidden) |needle|
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(source, needle));
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(source, "*anyopaque"));
    const decoder_start = std.mem.indexOf(u8, source, "pub const RpcDecoder =") orelse
        return error.TestUnexpectedResult;
    const decoder_end = std.mem.indexOfPos(u8, source, decoder_start, "pub const RpcPreDecodeDisposition =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source[decoder_start..decoder_end], "*anyopaque"),
    );
    const pre_decode_start = std.mem.indexOfPos(u8, source, decoder_end, "pub const RpcPreDecode =") orelse
        return error.TestUnexpectedResult;
    const pre_decode_end = std.mem.indexOfPos(u8, source, pre_decode_start, "fn typeContainsPointer") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source[pre_decode_start..pre_decode_end], "*anyopaque"),
    );
}

test "CR3a-2a attachment cleanup registry stays node-local and callback-free" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/attachment_cleanup_registry.zig",
    );
    defer allocator.free(source);
    // 기존 다섯 import에 settlement receipt 계약과 process seal leaf만 추가된다.
    try std.testing.expectEqual(@as(usize, 7), countOccurrences(source, "@import("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "@import(\"std\")"));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "@import(\"generation_attachment_contract.zig\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "@import(\"prepared_request_authority.zig\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "@import(\"rpc_response_authority.zig\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "@import(\"pending_event_settlement_contract.zig\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "@import(\"process_seal_service.zig\")"),
    );
    const forbidden = [_][]const u8{
        "@import(\"client.zig\")",
        "@import(\"remote_runtime.zig\")",
        "@import(\"remote_attachment.zig\")",
        "*anyopaque",
        "callback: ",
        "CleanupPermit",
        "Batch",
    };
    for (forbidden) |needle|
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(source, needle));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "pub fn preparedRequestForReceipt("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "pub fn executingRequestForReceipt("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "fn requestForReceipt("),
    );
}

test "CR3a-2c3b prepared request authority remains pointer-free node-local mechanics" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/prepared_request_authority.zig",
    );
    defer allocator.free(source);
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(source, "@import("));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(source, "@ptrFromInt"));
    const forbidden = [_][]const u8{
        "@import(\"client.zig\")",
        "@import(\"client_slot.zig\")",
        "@import(\"attachment_cleanup_registry.zig\")",
        "@import(\"generation_transport.zig\")",
        "@import(\"remote_runtime.zig\")",
        "*anyopaque",
        "std.mem.Allocator",
        "[]u8",
        "[]const u8",
    };
    for (forbidden) |needle|
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(source, needle));
}

test "CR3a-2c3 generation transport keeps the exact reviewed public facade" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/generation_transport.zig",
    );
    defer allocator.free(source);
    const first_test = std.mem.indexOf(u8, source, "\ntest \"") orelse
        return error.TestUnexpectedResult;
    const product_source = source[0..first_test];
    const methods = [_][]const u8{
        "    pub fn capabilities(",
        "    pub fn prepareRequest(",
        "    pub fn executePreparedRequest(",
        "    pub fn abortPreparedRequest(",
        "    pub fn sendInput(",
        "    pub fn sendInputNonBlocking(",
        "    pub fn sendControl(",
        "    pub fn sendControlNonBlocking(",
        "    pub fn pumpPendingOutput(",
        "    pub fn takeEvent(",
        "    pub fn releaseEvent(",
        "    pub fn purgeEndedStream(",
        "    pub fn fenceRevoke(",
        "    pub fn readInitialSnapshot(",
        "    pub fn poison(",
        "    pub fn pendingEventReleaseCallbackActive(",
        "    pub fn preflightPendingEffect(",
        "    pub fn settlementCorrelationDigest(",
        "    pub fn preflightPendingEventReleaseUnderEffect(",
        "    pub fn abortPendingEffectPreAdmissionNoFail(",
        "    pub fn commitPendingEffectNoFail(",
        "    pub fn preparePendingEventReleaseBegunNoFail(",
        "    pub fn tombstonePendingEventOwnerNoFail(",
        "    pub fn beginPendingEventReleaseResourcesNoFail(",
        "    pub fn tombstonePendingEventCorrelationNoFail(",
        "    pub fn markPendingEventMirrorTombstonedNoFail(",
        "    pub fn validatePendingEventReleaseFinal(",
        "    pub fn finishPendingEventReleaseNoFail(",
    };
    try std.testing.expectEqual(@as(usize, methods.len), countOccurrences(product_source, "    pub fn "));
    for (methods) |signature|
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(product_source, signature));
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(product_source, "*anyopaque"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(product_source, "pub fn call("));
    const facade_start = std.mem.indexOf(u8, product_source, "pub const GenerationTransport = struct") orelse
        return error.TestUnexpectedResult;
    const facade_end = std.mem.indexOfPos(u8, product_source, facade_start, "pub fn sendResyncNonBlockingOwned(") orelse
        return error.TestUnexpectedResult;
    const facade_source = product_source[facade_start..facade_end];
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(facade_source, "*anyopaque"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(facade_source, "method: []const u8"));
    const direct_prepared_client_apis = [_][]const u8{
        ".prepareBlockingRpcStorage(",
        ".abortPreparedBlockingRpcStorage",
        ".preparedBlockingRpcStorageMatches(",
    };
    for (direct_prepared_client_apis) |needle|
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(product_source, needle));

    const contract_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/generation_attachment_contract.zig",
    );
    defer allocator.free(contract_source);
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(contract_source, "EncodedRequestParams"),
    );
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(contract_source, "json: ?[]const u8"));
}

test "CR3a-2c3b capability projection and shared RemoteRuntime raw-read baselines cannot expand" {
    const allocator = std.testing.allocator;
    const transport_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/generation_transport.zig",
    );
    defer allocator.free(transport_source);
    const transport_first_test = std.mem.indexOf(u8, transport_source, "\ntest \"") orelse
        return error.TestUnexpectedResult;
    const transport_product = transport_source[0..transport_first_test];
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(transport_product, "client_slot_mod.projectGenerationCapabilities("),
    );
    const capability_start = std.mem.indexOf(
        u8,
        transport_product,
        "    pub fn capabilities(",
    ) orelse return error.TestUnexpectedResult;
    const capability_end = std.mem.indexOfPos(
        u8,
        transport_product,
        capability_start,
        "\n    pub fn prepareRequest(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(transport_product[capability_start..capability_end], ".logicalClient"),
    );

    const runtime_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime_source);
    const runtime_first_test = std.mem.indexOf(u8, runtime_source, "\ntest \"") orelse
        return error.TestUnexpectedResult;
    const runtime_product = runtime_source[0..runtime_first_test];
    const raw_baseline = [_]struct { name: []const u8, count: usize }{
        .{ .name = "wire_major", .count = 5 },
        .{ .name = "screen_codec_version", .count = 5 },
        .{ .name = "metadata_support", .count = 8 },
        .{ .name = "peer_attach_generation", .count = 4 },
        .{ .name = "screen_viewport_scrolled_v1", .count = 1 },
        .{ .name = "async_scroll_to_bottom_v1", .count = 2 },
        .{ .name = "async_observation_probe_v1", .count = 1 },
        .{ .name = "notification_stream_auth_v1", .count = 1 },
        .{ .name = "notification_delivery_v1", .count = 2 },
        .{ .name = "runtime_clipboard_v1", .count = 1 },
        .{ .name = "runtime_core_command_v1", .count = 6 },
        .{ .name = "runtime_clear_screen_v1", .count = 3 },
        .{ .name = "runtime_link_at_v1", .count = 1 },
        .{ .name = "runtime_selected_text_v1", .count = 1 },
    };
    for (raw_baseline) |entry|
        try std.testing.expectEqual(entry.count, countOccurrences(runtime_product, entry.name));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(runtime_product, ".expected_major = self.connectionCapabilities().wire_major"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(runtime_product, "client.compatibility_profile"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(runtime_product, "profile.attach_schema"),
    );
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(runtime_product, ".capabilities()"));
}

test "CR3a-2c3b B3-0a response provenance has one strict production path" {
    const allocator = std.testing.allocator;
    const slot_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_slot.zig",
    );
    defer allocator.free(slot_source);
    const client_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client.zig",
    );
    defer allocator.free(client_source);
    const framing_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/framing.zig",
    );
    defer allocator.free(framing_source);
    const ledger_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/response_payload_allocation.zig",
    );
    defer allocator.free(ledger_source);
    const response_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/executed_response.zig",
    );
    defer allocator.free(response_source);
    const attachment_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/generation_attachment.zig",
    );
    defer allocator.free(attachment_source);
    // These exact seam names have no test-only callsites; whole-file counting makes any future
    // bypass explicit even in fixtures instead of relying on declaration order.
    const slot_product = slot_source;
    const client_product = client_source;
    const framing_product = framing_source;
    const ledger_product = ledger_source;
    const limits_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_queue_limits.zig",
    );
    defer allocator.free(limits_source);

    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(limits_source, "pub const max_observed_response_payloads: usize = 1;"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(ledger_product, "entry_storage: [max_entries]Entry"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            ledger_product,
            "pub const max_entries: usize = client_queue_limits.max_observed_response_payloads;",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(ledger_product, "allocator.alloc(Entry"),
    );

    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(slot_product, ".executePreparedBlockingRpcStorageWithAllocatorObserved("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(slot_product, ".executePreparedBlockingRpcStorageUntilObserved("),
    );
    // Blocking and absolute-deadline readers share the same observed payload provenance leaf.
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(client_product, ".nextWithPayloadObserver("),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        countIdentifierOutsideTopLevelTests(slot_product, "classifyResponsePayloadProvenance"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(slot_product, ".transferPromotedResponse("),
    );
    try std.testing.expectEqual(
        // B3-3 adds the composite request/response transaction's closed fail-stop branches;
        // B3-4/5 adds two publication-recovery terminal branches without another public entrypoint.
        @as(usize, 17),
        countIdentifierOutsideTopLevelTests(slot_product, "fail_stop_required"),
    );
    const prepared_execution_signatures = [_][]const u8{
        "fn initBeforeBeginExecute(\n        self: *PreparedExecutionTxn,\n        operation: RegisteredNodeOperation,\n        request: GenerationRequestAbort,\n        identity: contract.BindingIdentity,\n        canonical: prepared_request_authority.Prepared,\n    ) PreparedExecutionTxn.InitError!void {",
        "fn commitBeginExecute(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) void {",
        "fn revalidatePreWire(\n        self: *PreparedExecutionTxn,\n        operation: RegisteredNodeOperation,\n    ) error{ InvalidOwner, InvalidReceipt }!void {",
        "fn rollbackPreWire(\n        self: *PreparedExecutionTxn,\n        operation: RegisteredNodeOperation,\n    ) SettlementError!SettlementOutcome {",
        "fn retireIssuerExhausted(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) SettlementError!SettlementOutcome {",
        "fn settlePostExecuteReusable(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) SettlementError!SettlementOutcome {",
        "fn settlePostExecuteTerminal(\n        self: *PreparedExecutionTxn,\n        operation: RegisteredNodeOperation,\n        fallback_reason: client_poison.ConnectionReason,\n    ) SettlementError!SettlementOutcome {",
        "fn finishOrFailStop(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation, outcome: SettlementOutcome) void {",
        "fn ensureSettledOrFailStop(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) void {",
    };
    for (prepared_execution_signatures) |signature|
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(slot_product, signature));
    const removed_execution_helpers = [_][]const u8{
        "ExecuteDisposition",
        "rollbackExecutingRequest",
        "terminalizeExecutingRequest",
        "terminalizeExecutingRequestWithStorageCleanup",
    };
    for (removed_execution_helpers) |identifier|
        try std.testing.expectEqual(
            @as(usize, 0),
            countIdentifierOutsideTopLevelTests(slot_product, identifier),
        );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            slot_product,
            "var execution_txn: PreparedExecutionTxn = .{};\n    defer execution_txn.ensureSettledOrFailStop(admission.operation);",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            slot_product,
            "try execution_txn.initBeforeBeginExecute(\n        admission.operation,\n        request,\n        identity,\n        canonical,\n    );\n    execution_txn.commitBeginExecute(admission.operation);",
        ),
    );
    const execute_generation_start = std.mem.indexOf(
        u8,
        slot_product,
        "pub fn executeGenerationRequest(",
    ) orelse return error.TestUnexpectedResult;
    const execute_generation_source = slot_product[execute_generation_start..];
    const containment_at = std.mem.indexOf(
        u8,
        execute_generation_source,
        "if (!byteRangeFullyContained(\n        execution.response_out_addr,",
    ) orelse return error.TestUnexpectedResult;
    const owner_admission_at = std.mem.indexOf(
        u8,
        execute_generation_source,
        "const admission = try beginGenerationRequestOwner(request, false);",
    ) orelse return error.TestUnexpectedResult;
    const response_pointer_at = std.mem.indexOf(
        u8,
        execute_generation_source,
        "@ptrFromInt(\n        execution.response_out_addr,\n    );",
    ) orelse return error.TestUnexpectedResult;
    const canonical_destination_at = std.mem.indexOf(
        u8,
        execute_generation_source,
        "resolveResponseDestination(admission.owner, .{ .attach = response_out })",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(containment_at < owner_admission_at);
    try std.testing.expect(owner_admission_at < response_pointer_at);
    try std.testing.expect(response_pointer_at < canonical_destination_at);
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            execute_generation_source[0..response_pointer_at],
            "byteRangeFullyContained(",
        ),
    );
    const canonical_owner_at = std.mem.indexOf(
        u8,
        execute_generation_source[owner_admission_at..response_pointer_at],
        "execution.owner_addr != admission.owner.owner_addr",
    ) orelse return error.TestUnexpectedResult;
    _ = canonical_owner_at;
    const execute_generation_end = std.mem.indexOf(
        u8,
        execute_generation_source,
        "\nfn responseDestinationValid(",
    ) orelse return error.TestUnexpectedResult;
    const execute_body = execute_generation_source[0..execute_generation_end];
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            execute_body,
            "var execution_cleanup: PreparedExecutionCleanup = undefined;",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(execute_body, "execution_cleanup.init();"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(execute_body, "defer execution_cleanup.ensureFinishedOrFailStop("));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(execute_body, "execution_cleanup.finishOrFailStop("));
    try std.testing.expectEqual(@as(usize, 21), countOccurrences(execute_body, "settleExecutionAfterCleanup("));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(execute_body, ".{ .start = @intFromPtr(&execution_txn), .len = @sizeOf(PreparedExecutionTxn) },"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(execute_body, ".{ .start = @intFromPtr(&execution_cleanup), .len = @sizeOf(PreparedExecutionCleanup) },"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(execute_body, ".{ .start = @intFromPtr(&cleanup_expected_stage), .len = @sizeOf(PreparedExecutionCleanup.CleanupStage) },"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(execute_body, ".{ .start = @intFromPtr(&cleanup_completion), .len = @sizeOf(u8) },"));
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(execute_body, "execution_txn.rollbackPreWire"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(execute_body, "execution_txn.retireIssuerExhausted"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(execute_body, "execution_txn.settlePostExecuteTerminal"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(execute_body, "execution_txn.settlePostExecuteReusable"));
    try std.testing.expectEqual(
        @as(usize, 5),
        countOccurrences(slot_product, "try self.requireCleanupClosed(operation);"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            slot_product,
            "fn requireCleanupClosed(self: *PreparedExecutionTxn, operation: RegisteredNodeOperation) SettlementError!void {\n        const node = self.ownerNode(operation) orelse return error.ProtocolError;",
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(execute_body, "defer guard.endOperationGuard()"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(execute_body, "defer node.client.restoreGenerationAllocatorScope"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(execute_body, "defer payload_ledger.endOperation()"));
    const settlement_seam_start = std.mem.indexOf(
        u8,
        slot_product,
        "fn settleExecutionAfterCleanup(",
    ) orelse return error.TestUnexpectedResult;
    const settlement_seam_end = std.mem.indexOf(
        u8,
        slot_product[settlement_seam_start..],
        "\n/// Executes the attach-compatible request",
    ) orelse return error.TestUnexpectedResult;
    const settlement_seam = slot_product[settlement_seam_start .. settlement_seam_start + settlement_seam_end];
    const seam_cleanup_at = std.mem.indexOf(u8, settlement_seam, "cleanup.finishOrFailStop(") orelse return error.TestUnexpectedResult;
    const seam_switch_at = std.mem.indexOf(u8, settlement_seam, "const outcome = switch (intent)") orelse return error.TestUnexpectedResult;
    const seam_finish_at = std.mem.indexOf(u8, settlement_seam, "txn.finishOrFailStop(operation, outcome);") orelse return error.TestUnexpectedResult;
    try std.testing.expect(seam_cleanup_at < seam_switch_at);
    try std.testing.expect(seam_switch_at < seam_finish_at);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(settlement_seam, "txn.rollbackPreWire(operation)"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(settlement_seam, "txn.retireIssuerExhausted(operation)"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(settlement_seam, "txn.settlePostExecuteReusable(operation)"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(settlement_seam, "txn.settlePostExecuteTerminal(operation, reason)"));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            slot_product,
            "const RegisteredNodeOperation = struct {\n    node: *ClientNode,\n    registry_index: u16,\n    operation_id: u64,\n    pid: u32,\n};",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(slot_product, "self: *PreparedExecutionTxn, node: *ClientNode"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            slot_product,
            "registered_node_operation_mutex.unlock();\n    const expected = observed orelse return null;\n    while (!client_slot_registry_mutex.tryLock())",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            slot_product,
            "const reservation = reserveRegisteredNodeOperation(lookup) catch return error.Busy;\n    errdefer abortRegisteredNodeOperationReservation(reservation);\n    // The sole nested order is ClientSlot registry -> operation registry publication.\n    while (!client_slot_registry_mutex.tryLock())",
        ),
    );
    try std.testing.expectEqual(
        // One declaration plus the reviewed direct accesses sealed below. C3-3a2 adds four
        // transaction-registry accesses and three whole-registry fail-stop/alias references.
        // b2b3 adds one registered-operation lookup for candidate-range revalidation.
        @as(usize, 23),
        countIdentifierOutsideTopLevelTests(slot_product, "registered_node_operations"),
    );
    const registered_operation_direct_accesses = [_]struct {
        expected: usize,
        source: []const u8,
    }{
        .{ .expected = 1, .source = "var registered_node_operations:" },
        .{ .expected = 1, .source = "registered_node_operations[index].state" },
        .{ .expected = 1, .source = "registered_node_operations[index] = entry" },
        .{ .expected = 2, .source = "&registered_node_operations[reservation.index]" },
        // Incident publication reconstructs one sealed operation handle and validates its index
        // before any Client destination access.
        .{ .expected = 5, .source = "registered_node_operations.len" },
        .{ .expected = 1, .source = "const candidate = registered_node_operations[index];" },
        .{ .expected = 1, .source = "const candidate = &registered_node_operations[index];" },
        .{ .expected = 1, .source = "const entry = &registered_node_operations[index];" },
        .{ .expected = 1, .source = "const entry = registered_node_operations[index];" },
        .{ .expected = 3, .source = "&registered_node_operations[operation.registry_index]" },
        .{ .expected = 1, .source = "const entry = registered_node_operations[operation.registry_index];" },
        // Includes the bounded production fail-stop scan and the existing test oracle scan.
        .{ .expected = 2, .source = "for (registered_node_operations) |entry|" },
        // 제품 alias preflight와 closed hostile table이 같은 backing 시작 주소를 각각 고정한다.
        .{ .expected = 2, .source = "@intFromPtr(&registered_node_operations)" },
        .{ .expected = 1, .source = "@sizeOf(@TypeOf(registered_node_operations))" },
        .{ .expected = 1, .source = "rangesOverlapTyped(out, &registered_node_operations)" },
    };
    for (registered_operation_direct_accesses) |access|
        try std.testing.expectEqual(access.expected, countOccurrences(slot_product, access.source));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(slot_product, "rangesOverlapTyped(out, &registered_node_operation_free_stack)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            slot_product,
            "registered_node_operation_free_count -= 1;\n    const index: usize = registered_node_operation_free_stack[registered_node_operation_free_count];",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(
            slot_product,
            "registered_node_operation_free_stack[registered_node_operation_free_count] =",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        countIdentifierOutsideTopLevelTests(slot_product, "failStopResponsePayloadProvenance"),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        countIdentifierOutsideTopLevelTests(slot_product, "failStopResponsePayloadTransfer"),
    );
    try std.testing.expectEqual(
        // 기존 일곱 leaf와 C3-3b3 effect, CR3a-2d3 terminal drain, CR0b incident operation만
        // 검토된 noreturn 권위를 가진다.
        @as(usize, 10),
        countOccurrences(slot_product, ") noreturn {"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(slot_product, "fn effectProofLoss() noreturn {"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(slot_product, "fn terminalDrainProofLoss(comptime message: []const u8) noreturn {"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            slot_product,
            "const payload_receipt = switch (payload_ledger.classifyResponsePayloadProvenance(",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            slot_product,
            "switch (payload_ledger.transferPromotedResponse(",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(ledger_product, ".initAcceptedFromPromotedInPlace("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(
            response_source,
            "initAcceptedFromPromotedInPlace",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(
            ledger_source,
            "initAcceptedFromPromotedInPlace",
        ),
    );
    // The maintained fixture seam exists only in the builtin.is_test namespace. The retired
    // event-specific helper must stay absent so fixtures share one reviewed low-level response
    // assembly path without adding a callable production symbol.
    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(
            attachment_source,
            "initAcceptedFromPromotedInPlace",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(attachment_source, "fn initAttachedForEventTest("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(attachment_source, "pub const testing_api = if (builtin.is_test) struct"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(attachment_source, "pub fn initAttached("),
    );
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(slot_product, ".promoteObserved("));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(ledger_product, "promoteExact"));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(framing_product, "pub fn nextWithPayloadObserver("),
    );

    // The raw publisher and ledger transitions are source-closed across the complete production
    // tree, including the sibling barrel and future files outside this directory.
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const is_response = std.mem.endsWith(
            u8,
            entry.path,
            "platform/macos/session_host/executed_response.zig",
        );
        const is_ledger = std.mem.endsWith(
            u8,
            entry.path,
            "platform/macos/session_host/response_payload_allocation.zig",
        );
        const is_slot = std.mem.endsWith(
            u8,
            entry.path,
            "platform/macos/session_host/client_slot.zig",
        );
        const is_client = std.mem.endsWith(
            u8,
            entry.path,
            "platform/macos/session_host/client.zig",
        );
        const is_framing = std.mem.endsWith(
            u8,
            entry.path,
            "platform/macos/session_host/framing.zig",
        );
        const is_attachment = std.mem.endsWith(
            u8,
            entry.path,
            "platform/macos/session_host/generation_attachment.zig",
        );
        try std.testing.expectEqual(
            // RemoteRuntime uses testing_api.initAttached and must not name the raw response seam.
            @as(usize, @intFromBool(is_response)) + @as(usize, @intFromBool(is_ledger)) +
                @as(usize, @intFromBool(is_attachment)),
            countIdentifierOutsideTopLevelTests(source, "initAcceptedFromPromotedInPlace"),
        );
        try std.testing.expectEqual(
            @as(usize, @intFromBool(is_ledger)) + 2 * @as(usize, @intFromBool(is_slot)),
            countIdentifierOutsideTopLevelTests(source, "classifyResponsePayloadProvenance"),
        );
        try std.testing.expectEqual(
            @as(usize, @intFromBool(is_ledger)) + @as(usize, @intFromBool(is_slot)),
            countIdentifierOutsideTopLevelTests(source, "transferPromotedResponse"),
        );
        try std.testing.expectEqual(
            @as(usize, @intFromBool(is_ledger)) +
                3 * @as(usize, @intFromBool(is_slot)),
            countIdentifierOutsideTopLevelTests(source, "releasePromotedResponse"),
        );
        inline for (.{
            "bindForbiddenRanges",
            "reserveObserved",
            "commitObserved",
            "abortObserved",
            "discardObserved",
        }) |name| {
            const slot_count: usize = if (std.mem.eql(u8, name, "bindForbiddenRanges")) 2 else 1;
            try std.testing.expectEqual(
                @as(usize, @intFromBool(is_ledger)) +
                    slot_count * @as(usize, @intFromBool(is_slot)),
                countIdentifierOutsideTopLevelTests(source, name),
            );
        }
        if (!is_ledger and !is_slot)
            try std.testing.expectEqual(
                @as(usize, 0),
                countIdentifierOutsideTopLevelTests(source, "PayloadProvenanceOutcome"),
            );
        if (!is_framing and !is_client and !is_slot)
            try std.testing.expectEqual(
                @as(usize, 0),
                countIdentifierOutsideTopLevelTests(source, "payload_observation_generation"),
            );
    }
}

test "B3-0.4 focused product gate stays nonempty and dual-mode" {
    const allocator = std.testing.allocator;
    const transport_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/generation_transport.zig",
    );
    defer allocator.free(transport_source);
    const build_source = try readZigFileZ(allocator, "build.zig");
    defer allocator.free(build_source);

    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            transport_source,
            "const B3ActualSocketScenario = enum {\n    eof_after_request,\n    partial_header_eof,\n    partial_payload_eof,\n};",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            transport_source,
            "test \"B3-0.4 actual socket uncertain settlement follows full request then EOF boundaries\"",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            transport_source,
            "test \"B3-0.4 execute allocation fail index settles every actual socket attempt\"",
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(transport_source, "for (0..32) |fail_offset|"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_source, "const response_payload = try allocator.alloc(u8, 64 * 1024);"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_source, ".eof_after_request => .connection_eof"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_source, ".partial_header_eof, .partial_payload_eof => .frame_malformed"));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(build_source, "\"test-session-host-b3-0-4\""),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(build_source, ".filters = &.{\"B3-0.4\"}"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(build_source, "std.builtin.OptimizeMode.Debug"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(build_source, "std.builtin.OptimizeMode.ReleaseFast"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(build_source, "run_b3_0_4_tests.addArg(\"--maru-expect-tests=8\")"),
    );
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_source, "const B3Scenario = enum {"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_source, "const b3_expected_rows = [_]B3Expected{"));
    const table_start = std.mem.indexOf(u8, transport_source, "const b3_expected_rows = [_]B3Expected{") orelse
        return error.TestUnexpectedResult;
    const table_end = std.mem.indexOfPos(u8, transport_source, table_start, "\n};") orelse
        return error.TestUnexpectedResult;
    const table_source = transport_source[table_start .. table_end + 3];
    try std.testing.expectEqual(@as(usize, 13), countOccurrences(table_source, ".scenario = ."));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_source, "const B3ErrorClass = enum"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_source, "const B3ResponseClass = enum"));
    try std.testing.expectEqual(@as(usize, 13), countOccurrences(table_source, ".final_zero = "));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(transport_source, "MARU_SESSION_HOST_B3_STRICT_GATE"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(build_source, "run_b3_0_4_tests.step.dependOn(&run_b3_strict_cleanup_tests.step)"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(build_source, "run_b3_0_4_tests.step.dependOn(&run_b3_issuer_cleanup_tests.step)"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(build_source, ".filters = &.{\"B3-0.1 pre-wire issuer exhaustion\"}"));
    // CR6a-2 app-host aggregate 격리는 C2 다섯 행을 같은 generation_transport root의
    // fresh exact artifact에서 실행하므로 이 owner 경로가 하나 늘어난다.
    try std.testing.expectEqual(
        @as(usize, 15),
        countOccurrences(build_source, "src/platform/macos/session_host/generation_transport.zig"),
    );
}

test "external pump acquires storage claim before reading owned Client" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(source);
    const function_start = std.mem.indexOf(
        u8,
        source,
        "pub fn acquireWholeTurnLease(",
    ) orelse return error.TestUnexpectedResult;
    const function_end = std.mem.indexOfPos(
        u8,
        source,
        function_start,
        "\n    pub fn ",
    ) orelse return error.TestUnexpectedResult;
    const body = source[function_start..function_end];
    const claim = std.mem.indexOf(
        u8,
        body,
        "self.access_claim.cmpxchgStrong(",
    ) orelse return error.TestUnexpectedResult;
    const client_read = std.mem.indexOf(
        u8,
        body,
        "const client = if (self.owned_client)",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(claim < client_read);
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(body, "self.owned_client"),
    );
}

test "d2d whole-turn authority stays a pure owner-free leaf" {
    const allocator = std.testing.allocator;
    const leaf = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_turn_authority.zig",
    );
    defer allocator.free(leaf);
    const forbidden = [_][]const u8{
        "client_external_pump",
        "client.zig",
        "client_pump",
        "ExternalPumpStorage",
        "external_inbox_ledger",
        "external_rx_intent",
        "external_rx_turn",
        "callback",
    };
    for (forbidden) |needle|
        try std.testing.expectEqual(
            @as(usize, 0),
            countOccurrences(leaf, needle),
        );
    const lifecycle_apis = [_][]const u8{
        "pub fn prepare(",
        "pub fn validate(",
        "pub fn consume(",
        "pub fn validateConsumed(",
        "pub fn abort(",
        "pub fn abortForCleanup(",
        "pub fn poisonPreparedForTerminal(",
        "pub fn resetSpent(",
        "pub fn resetConsumedAfterTx(",
    };
    for (lifecycle_apis) |signature|
        try std.testing.expectEqual(
            @as(usize, 1),
            countOccurrences(leaf, signature),
        );
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            pump,
            "@import(\"client_external_turn_authority.zig\")",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            pump,
            "pub const AuthorityGeneration = client_external_turn_authority.AuthorityGeneration;",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            pump,
            "pub const AttachmentRole = client_external_turn_authority.AttachmentRole;",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            pump,
            "pub const OwnerAuthorityFlow = client_external_turn_authority.OwnerAuthorityFlow;",
        ),
    );

    var importers: usize = 0;
    var prepare_calls: usize = 0;
    var validate_calls: usize = 0;
    var abort_calls: usize = 0;
    var cleanup_abort_calls: usize = 0;
    var poison_calls: usize = 0;
    var reset_spent_calls: usize = 0;
    var consume_calls: usize = 0;
    var validate_consumed_calls: usize = 0;
    var reset_consumed_calls: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const references = countOccurrences(
            source,
            "client_external_turn_authority.zig",
        );
        if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        )) {
            try std.testing.expectEqual(@as(usize, 1), references);
            try std.testing.expect(joinedStringLiteralsContain(
                source,
                "client_external_turn_authority.zig",
            ));
            importers += references;
        } else {
            try std.testing.expectEqual(@as(usize, 0), references);
            try std.testing.expect(!joinedStringLiteralsContain(
                source,
                "client_external_turn_authority.zig",
            ));
        }
        prepare_calls += countOccurrences(
            source,
            "client_external_turn_authority.prepare(",
        );
        validate_calls += countOccurrences(
            source,
            "client_external_turn_authority.validate(",
        );
        abort_calls += countOccurrences(
            source,
            "client_external_turn_authority.abort(",
        );
        cleanup_abort_calls += countOccurrences(
            source,
            "client_external_turn_authority.abortForCleanup(",
        );
        poison_calls += countOccurrences(
            source,
            "client_external_turn_authority.poisonPreparedForTerminal(",
        );
        reset_spent_calls += countOccurrences(
            source,
            "client_external_turn_authority.resetSpent(",
        );
        consume_calls += countOccurrences(
            source,
            "client_external_turn_authority.consume(",
        );
        validate_consumed_calls += countOccurrences(
            source,
            "client_external_turn_authority.validateConsumed(",
        );
        reset_consumed_calls += countOccurrences(
            source,
            "client_external_turn_authority.resetConsumedAfterTx(",
        );
    }
    try std.testing.expectEqual(@as(usize, 1), importers);
    // D2 owns one auditable lifecycle edge per operation. f1 consumes the prepared authority for
    // the same-turn TX suffix, validates it across callbacks, and resets it exactly once.
    try std.testing.expectEqual(@as(usize, 1), prepare_calls);
    try std.testing.expectEqual(@as(usize, 1), validate_calls);
    try std.testing.expectEqual(@as(usize, 1), abort_calls);
    try std.testing.expectEqual(@as(usize, 1), cleanup_abort_calls);
    try std.testing.expectEqual(@as(usize, 1), poison_calls);
    try std.testing.expectEqual(@as(usize, 1), reset_spent_calls);
    try std.testing.expectEqual(@as(usize, 1), consume_calls);
    try std.testing.expectEqual(@as(usize, 1), validate_consumed_calls);
    try std.testing.expectEqual(@as(usize, 1), reset_consumed_calls);
}

test "d2d adapter pins authority records and a monotonic turn generation in canonical scratch" {
    const allocator = std.testing.allocator;
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);

    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            pump,
            "authority_permit: client_external_turn_authority.PreparedAuthorityPermit",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            pump,
            "authority_cleanup_seed: client_external_turn_authority.FrozenCleanupSeed",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(pump,
            \\    authority_permit: client_external_turn_authority.PreparedAuthorityPermit = .{},
            \\    authority_cleanup_seed: client_external_turn_authority.FrozenCleanupSeed = .{},
            \\    tx_cancellation: client_external_tx.PreparedTxCancellation = .{},
            \\    tx_cancellation_permit: client_external_tx.TxCancellationCommitPermit = .{},
            \\    tx_cancellation_cleanup: client_external_tx.FrozenTxCancellationCleanup = .{},
            \\    revoked_commit_graph: PreparedRevokedCommitGraph = .{},
            \\    post_cancellation_receipt: client_external_tx.PostCancellationReceipt = .{},
            \\    turn_generation: u64 = 0,
        ),
    );
}

test "d2d RX preparation leaf cannot publish scheduling policy" {
    const allocator = std.testing.allocator;
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(pump, "fn prepareRxTurn("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(pump, "fn pumpInjectedRxUnderHeldLease("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(pump,
            \\const RxPolicyFacts = struct {
            \\        turn: client_pump.TurnInput,
            \\        parser: client_pump.ParserReadiness = .empty,
            \\        inherited_blocker: bool = false,
            \\        rx_frame_budget_exhausted: bool = false,
            \\        rx_read_budget_exhausted: bool = false,
            \\        work_budget_exhausted: bool = false,
            \\        terminal: ?client_pump.ExternalPumpTerminal = null,
            \\        deadlines: [5]?i128 = .{null} ** 5,
            \\    };
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(pump,
            \\const RxPreparedSummary = struct {
            \\        policy: RxPolicyFacts,
            \\        rx_read_bytes: usize = 0,
            \\        rx_bytes: usize = 0,
            \\        rx_frames: usize = 0,
            \\    };
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(pump,
            \\const RxPreparation = union(enum) {
            \\        terminal: RxPreparedSummary,
            \\        without_drain: RxPreparedSummary,
            \\        drained: RxPreparedSummary,
            \\    };
        ),
    );
    const prepare_start = std.mem.indexOf(
        u8,
        pump,
        "fn prepareRxTurn(",
    ) orelse return error.TestUnexpectedResult;
    const prepare_end = std.mem.indexOfPos(
        u8,
        pump,
        prepare_start,
        "\n    fn publishRxPreparationUnderHeldLease(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(
            pump[prepare_start..prepare_end],
            "client_pump.decide(",
        ),
    );
}

test "session host neutral cleanup leaf has no owner reverse dependencies" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_owner_cleanup.zig",
    );
    defer allocator.free(source);
    const forbidden = [_][]const u8{
        "client_external_pump",
        "external_rx_intent",
        "external_inbox_ledger",
        "external_event_materialization",
        "client.zig",
    };
    for (forbidden) |needle|
        try std.testing.expectEqual(
            @as(usize, 0),
            countOccurrences(source, needle),
        );
}

test "d2b3b classified intent mechanics stay private and test-only at the pump boundary" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const owner_path = "external_rx_intent.zig";
    const pump_path = "client_external_pump.zig";
    var owner_seen = false;
    var pump_seen = false;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root, entry.path },
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const scratch_refs = countOccurrences(source, "ExternalRxIntentScratch");
        if (std.mem.eql(u8, entry.path, owner_path)) {
            owner_seen = true;
            try std.testing.expect(scratch_refs != 0);
            try std.testing.expectEqual(
                @as(usize, 0),
                countOccurrences(source, "client_external_pump.zig"),
            );
            try std.testing.expectEqual(
                @as(usize, 0),
                countOccurrences(source, "external_inbox_ledger.zig"),
            );
        } else {
            try std.testing.expectEqual(@as(usize, 0), scratch_refs);
        }
        if (std.mem.eql(u8, entry.path, pump_path)) {
            pump_seen = true;
            try std.testing.expectEqual(
                @as(usize, 0),
                countOccurrences(source, "external_rx_intent.moveFrame("),
            );
            try std.testing.expectEqual(
                @as(usize, 1),
                countOccurrences(source, "external_rx_intent.allocate("),
            );
            try std.testing.expect(
                countOccurrences(
                    source,
                    "fn moveIntentFrameForTest(",
                ) == 1 and
                    countOccurrences(
                        source,
                        "fn createIntentScratch(",
                    ) == 1,
            );
            const move_start = std.mem.indexOf(
                u8,
                source,
                "fn moveIntentFrameForTest(",
            ) orelse return error.TestUnexpectedResult;
            const move_end = std.mem.indexOfPos(
                u8,
                source,
                move_start,
                "fn activateSyntheticLiveOwnersForTest(",
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expect(std.mem.indexOf(
                u8,
                source[move_start..move_end],
                "if (comptime !builtin.is_test) unreachable;",
            ) != null);
            const first_test = std.mem.indexOf(u8, source, "\ntest \"") orelse
                return error.TestUnexpectedResult;
            // d2b3d promotes the storage-bound scratch creator from a test wrapper to one product
            // traversal caller. The pre-test source contains its declaration, product call, and
            // the allocator-reentry probe call used by the hostile teardown matrix.
            try std.testing.expectEqual(
                @as(usize, 3),
                countOccurrences(
                    source[0..first_test],
                    "createIntentScratch(",
                ),
            );
        }
    }
    try std.testing.expect(owner_seen);
    try std.testing.expect(pump_seen);

    const barrel = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host.zig",
    );
    defer allocator.free(barrel);
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(barrel, "external_rx_intent"),
    );
}

test "session host owner projection capability stays in its reviewed mechanics file" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    const protected = [_][]const u8{
        "BorrowedMetadataView",
        "OwnerEventView",
        "OwnerEventProjector",
        "projectOwnerEventInternal",
    };
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig"))
            continue;
        if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        ))
            continue;
        const is_barrel =
            std.mem.eql(u8, entry.path, "platform/macos/session_host.zig");
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        var tokenizer = std.zig.Tokenizer.init(source);
        var protected_counts = [_]usize{0} ** protected.len;
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag != .identifier and token.tag != .string_literal) continue;
            const spelling = source[token.loc.start..token.loc.end];
            for (protected, 0..) |name, index| {
                if (std.mem.indexOf(u8, spelling, name) != null) {
                    if (!is_barrel) return error.TestUnexpectedResult;
                    protected_counts[index] += 1;
                }
            }
        }
        if (is_barrel)
            for (protected_counts) |count|
                try std.testing.expectEqual(@as(usize, 1), count);
    }
}

// 이 테스트는 docs/plans/core-slices.md의 facade import 경계를 강제한다.
// Maru 아키텍처 전체는 TerminalCore가 PTY/platform/renderer를 모른다는 전제 위에
// 서 있다(clean-room VT 코어를 교체 가능하고 headless로 테스트 가능하게 유지하기
// 위해서다). "리뷰에서 조심한다"는 규칙만으로는 이를 보장할 수 없으므로, 한 레이어가
// 금지된 레이어를 import하는 순간 빌드를 실패시킨다.
//
// 금지에는 두 종류가 있다(plans/core-slices.md "1단계 boundary checker 최소 요구사항"의 초기 금지 규칙).
//   - 레이어 전체 금지: 공개 barrel("layer.zig")과 구현 디렉터리("layer/...") 모두 금지.
//     예) terminal -> pty/platform/renderer, renderer -> pty, plugin -> pty.
//   - private 구현만 금지: 구현 디렉터리("layer/...")만 금지하고 공개 barrel은 허용.
//     예) pty/plugin -> terminal. pty는 terminal.Size 같은 공개 타입은 써도 되지만
//     terminal/core.zig 같은 내부 구현은 만지면 안 된다.
//
// 새 파일이 추가될 때마다 이 테스트 파일을 고치는 방식은 쉽게 빠뜨린다.
// 그래서 facade barrel 파일은 명시하되, 구현 폴더는 재귀적으로 훑어 새
// `*.zig` 파일도 자동으로 경계 검사를 받게 한다.

const Forbidden = struct {
    layer: []const u8,
    // true이면 구현 디렉터리("layer/...")만 금지하고 공개 barrel("layer.zig")은 허용한다.
    private_only: bool = false,
};

const Rule = struct {
    layer: []const u8,
    barrel: []const u8,
    implementation_dir: []const u8,
    forbidden: []const Forbidden,
};

const rules = [_]Rule{
    .{
        // terminal(L1 VT 코어)의 facade 계약(docs/facade-contracts.md TerminalCore "몰라야 하는 것"): PTY/platform
        // API·renderer/GPU뿐 아니라 **workspace/tab/split·plugin runtime**도 몰라야 한다. workspace/tab/split은 3차
        // 추출로 session(L2)에 있으므로 session을, plugin runtime은 plugin을 각각 금지해 "L1은 위 레이어를 모른다"를
        // 강제한다(과거엔 pty/platform/renderer만 막아 terminal→session/plugin이 뚫려 있었다 — 문서화됐으나 미강제).
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "renderer" },
            .{ .layer = "session" }, // workspace/tab/split 모델이 사는 곳 — L1이 L2를 import하면 위상 역전
            .{ .layer = "plugin" }, // plugin runtime을 몰라야 한다(facade-contracts.md:28)
        },
    },
    .{
        // renderer(L1 중립 frame 계약)는 위상의 바닥이다 — terminal snapshot을 DrawList·Glyph*Frame으로 바꾸는
        // 백엔드-무관 도메인. OS 백엔드(platform·pty)도, 위 레이어(session·chrome)도, 앱 런타임(app)도 import하면
        // 안 된다(아래로만 의존 — terminal·color·std만 허용). WebGPU/다른 OS 백엔드가 같은 frame 계약을 재사용
        // 하려면 L1이 OS·상위에 안 묶여야 한다(docs/layering-and-portability.md §2·§8, renderer-strategy.md).
        .layer = "renderer",
        .barrel = "src/renderer.zig",
        .implementation_dir = "src/renderer",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "session" },
            .{ .layer = "chrome" },
            .{ .layer = "app" },
        },
    },
    .{
        // chrome(L3 디자인 시스템)은 플랫폼 중립이어야 한다 — semantic ChromeDraw만 뱉고 session을 **props로만**
        // 읽는다(raw *Pane/*Split·session 모듈을 import하지 않는다). OS/렌더 백엔드(platform·pty), 코어 내부
        // (terminal·renderer), 세션·앱 런타임(session·app)을 import하면 props-only seam과 이식성이 깨지므로 빌드
        // 에서 막는다(docs/layering-and-portability.md §2·§8). 허용: std, color(top-level), 자기 하위 모듈.
        // session 금지는 C1~C3 이주에서 chrome 컴포넌트가 session을 직접 만지지 않고 props만 쓰게 강제한다.
        .layer = "chrome",
        .barrel = "src/chrome.zig",
        .implementation_dir = "src/chrome",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "terminal" },
            .{ .layer = "renderer" },
            .{ .layer = "session" },
            .{ .layer = "app" },
        },
    },
    .{
        // session(L2 세션 코어)은 OS-중립이어야 한다 — 순수 모델·연산·입력 수학만. platform(L4 OS 어댑터)과
        // pty(OS 프로세스)를 직접 import하면 이식성이 깨지므로 막는다(docs/layering-and-portability.md §2·§8).
        // renderer(L1)는 의존 방향이 L2→L1이라 허용한다(금지 안 함). terminal(중립 입력 타입)도 허용. chrome(L3)은
        // 위 레이어라 금지한다(L2가 L3를 import하면 위상 역전).
        //
        // session→app 금지(D3, 3차 추출 완료): 세션 모델이 쓰던 app의 중립 타입(Surface·split_tree·workspace·
        // window·core_command)을 3차(D1·D2)로 session으로 옮겨 session→app 직접 의존이 0이 됐다. 이제 app을
        // 통째 금지해 의존 소거를 가드로 고정한다(과거엔 "app 경유 중립 타입"이 컨벤션이었으나 이제 강제 —
        // docs/app-layer-decomposition.md). app.zig는 pty·platform을 transitive로 끌어오므로, app 금지가 곧 그
        // 차단이기도 하다(직접 @import만 보는 한계는 동일하나, session→app=0이면 transitive 누수 경로가 닫힌다).
        .layer = "session",
        .barrel = "src/session.zig",
        .implementation_dir = "src/session",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "platform" },
            .{ .layer = "chrome" },
            .{ .layer = "app" },
        },
    },
    .{
        // plugin(future Wasm 경계)의 facade 계약(docs/facade-contracts.md:290-291): plugin은 domain event·action
        // facade로만 상호작용하고, TerminalCore private storage·PTY handle·**renderer resource**를 직접 받지 않는다.
        // 그래서 pty(전체)·terminal(private 구현)에 더해 renderer(전체 — 프레임/atlas/GPU resource)를 금지한다
        // (문서화됐으나 pty/terminal만 막혀 plugin→renderer가 뚫려 있었다). plugin은 현재 registry stub이라 위반 0.
        .layer = "plugin",
        .barrel = "src/plugin.zig",
        .implementation_dir = "src/plugin",
        .forbidden = &.{
            .{ .layer = "pty" },
            .{ .layer = "terminal", .private_only = true },
            .{ .layer = "renderer" }, // renderer resource(프레임·atlas·GPU)를 직접 받지 않는다(facade-contracts.md:291)
        },
    },
    .{
        .layer = "pty",
        .barrel = "src/pty.zig",
        .implementation_dir = "src/pty",
        .forbidden = &.{.{ .layer = "terminal", .private_only = true }},
    },
};

test "facade layers do not import forbidden layers" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;

    for (rules) |rule| {
        try checkFile(allocator, rule, rule.barrel, &violations);
        try checkDirectory(allocator, rule, rule.implementation_dir, &violations);
    }

    try std.testing.expectEqual(@as(usize, 0), violations);
}

test "provider cleanup module remains absent" {
    try std.testing.expectError(
        error.FileNotFound,
        std.Io.Dir.cwd().statFile(std.testing.io, "src/platform/macos/agent_hook_cleanup.zig", .{}),
    );
}

test "session host unchecked adoption leaves stay behind the aggregate permit boundary" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const Leaf = struct {
        prefix: []const u8,
        suffix: []const u8,
        owner_file: []const u8,
        aggregate_calls: usize = 1,
    };
    const leaves = [_]Leaf{
        .{
            .prefix = "commitExternalAdoption",
            .suffix = "TakeUnchecked(",
            .owner_file = "client.zig",
        },
        .{
            .prefix = "commitInto",
            .suffix = "Unchecked(",
            .owner_file = "client_external_adoption.zig",
        },
        .{
            .prefix = "commitOwnerMetadata",
            .suffix = "TakeUnchecked(",
            .owner_file = "external_event_materialization.zig",
        },
        .{
            .prefix = "commitExternalRecoveryDiscard",
            .suffix = "Unchecked(",
            .owner_file = "client.zig",
        },
    };
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    for (leaves) |leaf| {
        const needle = try std.fmt.allocPrint(
            allocator,
            "{s}{s}",
            .{ leaf.prefix, leaf.suffix },
        );
        defer allocator.free(needle);
        var aggregate_calls: usize = 0;
        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or
                !std.mem.endsWith(u8, entry.basename, ".zig"))
                continue;
            const path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ root, entry.path },
            );
            defer allocator.free(path);
            const source = try readZigFileZ(allocator, path);
            defer allocator.free(source);
            const count = countOccurrences(source, needle);
            if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
                aggregate_calls += count;
            } else if (!std.mem.eql(u8, entry.path, leaf.owner_file) and
                count != 0)
            {
                std.debug.print(
                    "unchecked adoption leaf boundary violation: {s} contains {s}\n",
                    .{ path, needle },
                );
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(leaf.aggregate_calls, aggregate_calls);
    }
}

test "session host aggregate screen cleanup has one owner and one caller" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const seams = [_][]const u8{
        "moveIntoAggregateCleanupSnapshot",
        "abandonAggregateCleanup",
        "prepareAggregateCleanup",
        "finishAggregateCleanup",
    };
    for (seams) |seam| {
        const definition_needle = try std.fmt.allocPrint(
            allocator,
            "pub fn {s}(",
            .{seam},
        );
        defer allocator.free(definition_needle);
        const call_needle = try std.fmt.allocPrint(
            allocator,
            ".{s}(",
            .{seam},
        );
        defer allocator.free(call_needle);
        var owner_definitions: usize = 0;
        var aggregate_calls: usize = 0;
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or
                !std.mem.endsWith(u8, entry.basename, ".zig"))
                continue;
            const path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ root, entry.path },
            );
            defer allocator.free(path);
            const source = try readZigFileZ(allocator, path);
            defer allocator.free(source);
            if (std.mem.eql(u8, entry.path, "client_external_adoption.zig")) {
                owner_definitions += countOccurrences(source, definition_needle);
            } else if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
                aggregate_calls += countOccurrences(source, call_needle);
            } else if (countOccurrences(source, call_needle) != 0 or
                countOccurrences(source, definition_needle) != 0)
            {
                std.debug.print(
                    "aggregate screen cleanup boundary violation: {s}\n",
                    .{path},
                );
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), owner_definitions);
        try std.testing.expectEqual(@as(usize, 1), aggregate_calls);
    }

    const Symbol = struct {
        name: []const u8,
        owner_files: []const []const u8,
        aggregate_references: usize,
    };
    const symbols = [_]Symbol{
        .{
            .name = "commitFreezeAllForOwnerTeardownUnchecked",
            .owner_files = &.{"external_inbox_ledger.zig"},
            .aggregate_references = 1,
        },
        .{
            .name = "restoreFinishedOwnerTeardownUnchecked",
            .owner_files = &.{"external_inbox_ledger.zig"},
            .aggregate_references = 1,
        },
        .{
            .name = "commitFrozenCleanupUnchecked",
            .owner_files = &.{
                "client_external_adoption.zig",
                "external_event_materialization.zig",
            },
            .aggregate_references = 2,
        },
        .{
            .name = "commitExternalAdoptionTakeFrozenCleanupUnchecked",
            .owner_files = &.{"client.zig"},
            .aggregate_references = 1,
        },
    };
    for (symbols) |symbol| {
        var aggregate_references: usize = 0;
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or
                !std.mem.endsWith(u8, entry.basename, ".zig"))
                continue;
            var owner_file = false;
            for (symbol.owner_files) |allowed|
                owner_file = owner_file or std.mem.eql(u8, entry.path, allowed);
            const path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ root, entry.path },
            );
            defer allocator.free(path);
            const source = try readZigFileZ(allocator, path);
            defer allocator.free(source);
            // Count the identifier itself, not only direct `symbol(` calls. This also rejects
            // function-value aliases and facade re-exports of ReleaseFast unchecked authority.
            const references = countOccurrences(source, symbol.name);
            if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
                aggregate_references += references;
            } else if (!owner_file and references != 0) {
                std.debug.print(
                    "frozen teardown symbol escaped owner boundary: {s} contains {s}\n",
                    .{ path, symbol.name },
                );
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(
            symbol.aggregate_references,
            aggregate_references,
        );
    }
}

test "session host aggregate screen cleanup has no public shortcut" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_adoption.zig",
    );
    defer allocator.free(source);
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(source, "pub fn deinitForAggregate("),
    );
}

test "session host screen retirement unchecked commit has one product caller" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const symbol = "commitScreenRetirementUnchecked";
    var product_references: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ root, entry.path });
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const references = countOccurrences(source, symbol);
        if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
            product_references += references;
        } else if (!std.mem.eql(u8, entry.path, "external_inbox_ledger.zig") and
            references != 0)
        {
            std.debug.print(
                "screen retirement unchecked authority escaped owner boundary: {s}\n",
                .{path},
            );
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), product_references);
}

test "session host barrel does not re-export unchecked owner modules" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host.zig",
    );
    defer allocator.free(source);
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(source, "pub const external_event_materialization"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(source, "pub const client = if (builtin.os.tag == .macos)\n    @import"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(source, "pub const Client = client_impl.Client;"),
    );
}

test "session host unchecked teardown authority cannot escape anywhere in src" {
    const allocator = std.testing.allocator;
    const Symbol = struct {
        name: []const u8,
        owner_suffixes: []const []const u8,
        pump_references: usize,
    };
    const symbols = [_]Symbol{
        .{
            .name = "leaveGenerationAllocatorCallbackUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/client.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "consumeUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/generation_batch_registry.zig",
                "platform/macos/session_host/client.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "completeCleanupUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/generation_batch_registry.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "finishReleaseUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/generation_batch_registry.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "initTransferredUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/generation_batch_registry.zig",
                "platform/macos/session_host/client.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "commitIngressUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/generation_batch_registry.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "beginReleaseUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/generation_batch_registry.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "consumeGenerationAccountingUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/client.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "initFromReservedPinUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/connection_lease.zig",
                "platform/macos/session_host/client_slot.zig",
                "platform/macos/session_host/generation_event_contract.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "releaseDuringActiveCleanupUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/connection_lease.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "rollbackCanonicalPinUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/connection_lease.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "commitPreparedPinReleaseUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/connection_lease.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "abortPreparedPinReleaseUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/connection_lease.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "consumeCanonicalPinUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/connection_lease.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "consumeCanonicalPinWithReceiptUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/connection_lease.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "abortPreparedReleaseUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/generation_batch_registry.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "beginPreparedReleaseUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/generation_batch_registry.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "finishPreparedReleaseUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/generation_batch_registry.zig",
                "platform/macos/session_host/client_slot.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "commitExternalAdoptionTakeUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/client.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitExternalRecoveryDiscardUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/client.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitExternalAdoptionTakeFrozenCleanupUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/client.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitScreenRetirementUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitFreezeAllForOwnerTeardownUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "restoreFinishedOwnerTeardownUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitIntoUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/client_external_adoption.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitOwnerMetadataTakeUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitFrozenCleanupUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/client_external_adoption.zig",
                "platform/macos/session_host/external_event_materialization.zig",
            },
            .pump_references = 2,
        },
        .{
            .name = "consumePreparedLiveCommitUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 2,
        },
        .{
            .name = "consumePreparedLiveCommitWithOutputUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            // The legacy committed-source path and F3c2's projected same-drain path are the two
            // private, prevalidated consumers. F3d must orchestrate them through the enclosing
            // semantic take rather than adding a third direct ledger call.
            .pump_references = 2,
        },
        .{
            .name = "claimCommittedLiveOutputUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            // The legacy and projected semantic leaves plus hostile claim-owner/ABA tests remain
            // confined to the same private pump module.
            .pump_references = 6,
        },
        .{
            .name = "consumeClaimedCommittedLiveOutputUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 4,
        },
        .{
            .name = "commitLiveBatchAbortUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitMovedIntentPayloadTransferUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitOwnerMetadataCleanupOnlyUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitOwnerMetadataPublishFirstUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitOwnerMetadataReplaceNewerUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitFrozenCleanupToDescriptorUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitLiveMetadataAbortUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_event_materialization.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitNeutralRetirementUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 1,
        },
        .{
            .name = "commitIntentAbortUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 1,
        },
        .{
            .name = "consumePreparedIntentCommitUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 2,
        },
        .{
            .name = "commitPreparedDestroyUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 1,
        },
        .{
            .name = "moveCommittedLiveBatchAbortCleanupUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_inbox_ledger.zig"},
            .pump_references = 1,
        },
        .{
            .name = "moveCommittedIntentAbortCleanupUnchecked",
            .owner_suffixes = &.{"platform/macos/session_host/external_rx_intent.zig"},
            .pump_references = 1,
        },
        .{
            .name = "moveFrozenUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/external_owner_cleanup.zig",
                "platform/macos/session_host/external_inbox_ledger.zig",
                "platform/macos/session_host/external_rx_intent.zig",
            },
            .pump_references = 4,
        },
        .{
            .name = "freezeOwnedSliceUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/external_owner_cleanup.zig",
                "platform/macos/session_host/external_event_materialization.zig",
            },
            .pump_references = 0,
        },
        .{
            .name = "freezeOwnedSliceAlignedUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/external_owner_cleanup.zig",
            },
            .pump_references = 2,
        },
        .{
            .name = "freezeOwnedSliceFromSealUnchecked",
            .owner_suffixes = &.{
                "platform/macos/session_host/external_owner_cleanup.zig",
                "platform/macos/session_host/external_event_materialization.zig",
                "platform/macos/session_host/external_rx_intent.zig",
            },
            .pump_references = 0,
        },
    };
    var unchecked_declarations: usize = 0;
    var inventory_dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer inventory_dir.close(std.testing.io);
    var inventory_walker = try posixWalk(inventory_dir, allocator);
    defer inventory_walker.deinit();
    while (try inventory_walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/platform/macos/session_host/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        var lines = std.mem.splitScalar(u8, source, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (!std.mem.startsWith(u8, trimmed, "pub fn ")) continue;
            const rest = trimmed["pub fn ".len..];
            const end = std.mem.indexOfScalar(u8, rest, '(') orelse continue;
            const name = rest[0..end];
            if (!std.mem.endsWith(u8, name, "Unchecked")) continue;
            unchecked_declarations += 1;
            var known = false;
            for (symbols) |symbol| known = known or std.mem.eql(u8, name, symbol.name);
            if (!known) {
                std.debug.print("unchecked authority missing from global inventory: {s}\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }
    // Allocator restoration is now a checked one-shot token consume, so it intentionally no
    // longer contributes an `*Unchecked` declaration to this global authority inventory.
    try std.testing.expectEqual(@as(usize, 49), unchecked_declarations);
    for (symbols) |symbol| {
        var pump_references: usize = 0;
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
        defer dir.close(std.testing.io);
        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig"))
                continue;
            const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
            defer allocator.free(path);
            const source = try readZigFileZ(allocator, path);
            defer allocator.free(source);
            const references = countOccurrences(source, symbol.name);
            if (std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/client_external_pump.zig",
            )) {
                pump_references += references;
                continue;
            }
            var owner = false;
            for (symbol.owner_suffixes) |suffix|
                owner = owner or std.mem.eql(u8, entry.path, suffix);
            if (!owner and references != 0) {
                std.debug.print(
                    "unchecked session-host authority escaped into {s}: {s}\n",
                    .{ path, symbol.name },
                );
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(symbol.pump_references, pump_references);
    }
}

test "generation batch Client ownership mutations have one node-bound production caller" {
    const allocator = std.testing.allocator;
    const client_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client.zig",
    );
    defer allocator.free(client_source);
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(client_source, "pub fn readGenerationBatch("),
    );

    var read_references: usize = 0;
    var prepare_references: usize = 0;
    var bind_references: usize = 0;
    var begin_allocator_references: usize = 0;
    var restore_allocator_references: usize = 0;
    var enter_callback_references: usize = 0;
    var leave_callback_references: usize = 0;
    var reject_callback_references: usize = 0;
    var require_buffered_references: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig") or
            std.mem.eql(u8, entry.path, "client.zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/platform/macos/session_host/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const read_count = countOccurrences(source, ".readGenerationBatch(");
        const prepare_count = countOccurrences(source, ".prepareGenerationAccountingConsume(");
        const bind_count = countOccurrences(source, ".bindGenerationAccountingLedger(");
        const begin_allocator_count = countOccurrences(source, ".beginGenerationAllocatorScope(");
        const restore_allocator_count = countOccurrences(
            source,
            ".restoreGenerationAllocatorScope(",
        );
        const enter_callback_count = countIdentifierOutsideTopLevelTests(
            source,
            "enterGenerationAllocatorCallback",
        );
        const leave_callback_count = countIdentifierOutsideTopLevelTests(
            source,
            "leaveGenerationAllocatorCallbackUnchecked",
        );
        const reject_callback_count = countOccurrences(
            source,
            ".rejectGenerationAllocatorCallbackReentry(",
        );
        const require_buffered_count = countOccurrences(
            source,
            ".requireBufferedGenerationBatch(",
        );
        if ((read_count != 0 or prepare_count != 0 or bind_count != 0 or
            begin_allocator_count != 0 or restore_allocator_count != 0 or
            enter_callback_count != 0 or leave_callback_count != 0 or
            reject_callback_count != 0 or require_buffered_count != 0) and
            !std.mem.eql(u8, entry.path, "client_slot.zig"))
        {
            std.debug.print("generation batch Client take escaped into {s}\n", .{path});
            return error.TestUnexpectedResult;
        }
        read_references += read_count;
        prepare_references += prepare_count;
        bind_references += bind_count;
        begin_allocator_references += begin_allocator_count;
        restore_allocator_references += restore_allocator_count;
        enter_callback_references += enter_callback_count;
        leave_callback_references += leave_callback_count;
        reject_callback_references += reject_callback_count;
        require_buffered_references += require_buffered_count;
    }
    try std.testing.expectEqual(@as(usize, 1), read_references);
    // 일반 release와 2d2 terminal aggregate drain이 같은 canonical accounting permit을 쓴다.
    try std.testing.expectEqual(@as(usize, 2), prepare_references);
    // 최초 node, R2c ordinary replacement와 CR5b reserved replacement node가 같은 canonical
    // accounting ledger binding을 쓴다.
    try std.testing.expectEqual(@as(usize, 3), bind_references);
    // Batch, one-shot initial snapshot, RPC prepare/execute/publication과 R2b test-only external
    // fixture는 purpose-tagged node-local allocator scope를 공유한다. 그 밖의 파일에는 raw
    // allocator authority가 없다.
    try std.testing.expectEqual(@as(usize, 6), begin_allocator_references);
    try std.testing.expectEqual(@as(usize, 7), restore_allocator_references);
    // C3-3b3 effect settlement까지 다섯 guarded callback owner만 남는다. remap은 parent가
    // 크기 변경을 commit한 뒤 alias를 거부할 수 없으므로 callback에 들어가지 않고 선제 거부한다.
    try std.testing.expectEqual(@as(usize, 5), enter_callback_references);
    try std.testing.expectEqual(@as(usize, 5), leave_callback_references);
    const slot_source = try readZigFileZ(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot_source);
    const retirement_fixture = betweenMarkers(
        slot_source,
        "pub fn enterExternalMode(slot: *ClientSlot) !void {",
        "pub fn rpcDecoderCallbackActive() bool",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(retirement_fixture, ".beginGenerationAllocatorScope("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(retirement_fixture, ".restoreGenerationAllocatorScope("));
    const effect_executor = betweenMarkers(
        slot_source,
        "fn executeCanonicalEffectPlanNoFail(",
        "fn effectProofLoss() noreturn",
    ) orelse return error.TestUnexpectedResult;
    const effect_executor_z = try allocator.dupeZ(u8, effect_executor);
    defer allocator.free(effect_executor_z);
    try std.testing.expectEqual(@as(usize, 1), countIdentifierOutsideTopLevelTests(effect_executor_z, "enterGenerationAllocatorCallback"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifierOutsideTopLevelTests(effect_executor_z, "leaveGenerationAllocatorCallbackUnchecked"));
    // 모든 node-local mutation은 callback TLS를 한 공통 guard에서만 읽는다.
    try std.testing.expectEqual(@as(usize, 1), reject_callback_references);
    try std.testing.expectEqual(@as(usize, 1), require_buffered_references);
}

test "session host frozen teardown commits have one aggregate product caller" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const Seam = struct {
        name: []const u8,
        owner_file: []const u8,
        aggregate_call: []const u8,
    };
    const seams = [_]Seam{
        .{
            .name = "commitFreezeAllForOwnerTeardownUnchecked",
            .owner_file = "external_inbox_ledger.zig",
            .aggregate_call = ".inbox_ledger.commitFreezeAllForOwnerTeardownUnchecked(",
        },
        .{
            .name = "restoreFinishedOwnerTeardownUnchecked",
            .owner_file = "external_inbox_ledger.zig",
            .aggregate_call = ".inbox_ledger.restoreFinishedOwnerTeardownUnchecked(",
        },
        .{
            .name = "commitFrozenCleanupUnchecked",
            .owner_file = "client_external_adoption.zig",
            .aggregate_call = ".committed_screen.commitFrozenCleanupUnchecked(",
        },
        .{
            .name = "commitFrozenCleanupUnchecked",
            .owner_file = "external_event_materialization.zig",
            .aggregate_call = ".owner_metadata.commitFrozenCleanupUnchecked(",
        },
        .{
            .name = "commitExternalAdoptionTakeFrozenCleanupUnchecked",
            .owner_file = "client.zig",
            .aggregate_call = "client_mod.commitExternalAdoptionTakeFrozenCleanupUnchecked(",
        },
    };
    for (seams) |seam| {
        const definition_needle = try std.fmt.allocPrint(
            allocator,
            "pub fn {s}(",
            .{seam.name},
        );
        defer allocator.free(definition_needle);
        var definitions: usize = 0;
        var aggregate_calls: usize = 0;
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
        defer dir.close(std.testing.io);
        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file or
                !std.mem.endsWith(u8, entry.basename, ".zig"))
                continue;
            const path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}",
                .{ root, entry.path },
            );
            defer allocator.free(path);
            const source = try readZigFileZ(allocator, path);
            defer allocator.free(source);
            if (std.mem.eql(u8, entry.path, seam.owner_file)) {
                definitions += countOccurrences(source, definition_needle);
            }
            if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
                aggregate_calls += countOccurrences(source, seam.aggregate_call);
            } else if (countOccurrences(source, seam.aggregate_call) != 0) {
                std.debug.print(
                    "frozen teardown boundary violation: {s} exposes {s}\n",
                    .{ path, seam.name },
                );
                return error.TestUnexpectedResult;
            }
        }
        try std.testing.expectEqual(@as(usize, 1), definitions);
        try std.testing.expectEqual(@as(usize, 1), aggregate_calls);
    }
}

test "session host deferred seed retirement has one ledger owner and one adoption caller" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const definition_needle = "pub fn commitSeedsDeferredRetirement(";
    const call_needle = ".commitSeedsDeferredRetirement(";
    var definitions: usize = 0;
    var ledger_calls: usize = 0;
    var adoption_calls: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root, entry.path },
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (std.mem.eql(u8, entry.path, "external_inbox_ledger.zig")) {
            definitions += countOccurrences(source, definition_needle);
            ledger_calls += countOccurrences(source, call_needle);
        } else if (std.mem.eql(
            u8,
            entry.path,
            "client_external_adoption.zig",
        )) {
            adoption_calls += countOccurrences(source, call_needle);
        } else if (countOccurrences(source, definition_needle) != 0 or
            countOccurrences(source, call_needle) != 0)
        {
            std.debug.print(
                "deferred seed retirement boundary violation: {s}\n",
                .{path},
            );
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), definitions);
    try std.testing.expectEqual(@as(usize, 1), ledger_calls);
    try std.testing.expectEqual(@as(usize, 1), adoption_calls);
}

test "session host live batch unchecked mutation stays behind three ledger entrypoints" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const definition_needle = "fn commitPreparedLiveBatchUnchecked(";
    const call_needle = "self.commitPreparedLiveBatchUnchecked(";
    var definitions: usize = 0;
    var calls: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root, entry.path },
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (std.mem.eql(u8, entry.path, "external_inbox_ledger.zig")) {
            definitions += countOccurrences(source, definition_needle);
            calls += countOccurrences(source, call_needle);
            try std.testing.expect(std.mem.indexOf(
                u8,
                source,
                "commitPreparedLegacyMergeUnchecked",
            ) == null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                source,
                "commitPreparedLegacyReleaseUnchecked",
            ) == null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                source,
                "pub const FrozenPayloadCleanup",
            ) == null);
            const cleanup_start = std.mem.indexOf(
                u8,
                source,
                "const FrozenPayloadCleanup = struct {",
            ) orelse return error.TestUnexpectedResult;
            const cleanup_end = std.mem.indexOfPos(
                u8,
                source,
                cleanup_start,
                "\n};",
            ) orelse return error.TestUnexpectedResult;
            const cleanup_type = source[cleanup_start..cleanup_end];
            try std.testing.expect(std.mem.indexOf(
                u8,
                cleanup_type,
                "fn ",
            ) == null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                cleanup_type,
                ".free(",
            ) == null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                cleanup_type,
                ".deinit(",
            ) == null);
        } else if (std.mem.eql(u8, entry.path, "client_external_pump.zig")) {
            try std.testing.expect(std.mem.indexOf(
                u8,
                source,
                "ledger.mergeInto(",
            ) == null);
            try std.testing.expect(std.mem.indexOf(
                u8,
                source,
                "ledger.release(",
            ) == null);
            if (countOccurrences(source, definition_needle) != 0 or
                countOccurrences(source, call_needle) != 0)
                return error.TestUnexpectedResult;
        } else if (countOccurrences(source, definition_needle) != 0 or
            countOccurrences(source, call_needle) != 0)
        {
            std.debug.print(
                "live batch unchecked mutation boundary violation: {s}\n",
                .{path},
            );
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), definitions);
    // The legacy checked API and the sealed-permit unchecked consume each converge
    // on the same mutation leaf. No caller outside this owner module may bypass
    // either entrypoint.
    try std.testing.expectEqual(@as(usize, 3), calls);
}

test "session host live commit permit keeps checked consume ledger-private" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    const checked_needle = "consumePreparedLiveCommitChecked(";
    const unchecked_needle = "consumePreparedLiveCommitUnchecked(";
    var checked_outside_ledger: usize = 0;
    var unchecked_definitions: usize = 0;
    var unchecked_pump_calls: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root, entry.path },
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (std.mem.eql(u8, entry.path, "external_inbox_ledger.zig")) {
            unchecked_definitions += countOccurrences(
                source,
                "pub fn consumePreparedLiveCommitUnchecked(",
            );
        } else {
            checked_outside_ledger += countOccurrences(source, checked_needle);
            if (std.mem.eql(u8, entry.path, "client_external_pump.zig"))
                unchecked_pump_calls += countOccurrences(source, unchecked_needle)
            else
                try std.testing.expectEqual(
                    @as(usize, 0),
                    countOccurrences(source, unchecked_needle),
                );
        }
    }
    try std.testing.expectEqual(@as(usize, 0), checked_outside_ledger);
    try std.testing.expectEqual(@as(usize, 1), unchecked_definitions);
    // d2b3c owns the aggregate commit suffix and d2b3d adds one head-only live FIFO release
    // suffix. Any third caller would bypass one of those two sealed owner transactions.
    try std.testing.expectEqual(@as(usize, 2), unchecked_pump_calls);
}

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |found| {
        count += 1;
        offset = found + needle.len;
    }
    return count;
}

fn betweenMarkers(source: []const u8, begin: []const u8, end: []const u8) ?[]const u8 {
    const begin_at = std.mem.indexOf(u8, source, begin) orelse return null;
    const body_at = begin_at + begin.len;
    const end_relative = std.mem.indexOf(u8, source[body_at..], end) orelse return null;
    return source[body_at .. body_at + end_relative];
}

test "session host RX unchecked append has one validating aggregate caller" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_mode.zig",
    );
    defer allocator.free(source);
    // One private definition plus one call from `commitPreparedAdmit`. Tests and future d2 callers
    // must use the validating aggregate entry instead of the unchecked ownership suffix.
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(source, "commitAdmitUnchecked("),
    );
}

test "session host guarded RX admit has one C4 pump product callsite" {
    const allocator = std.testing.allocator;
    const root = "src/platform/macos/session_host";
    var guarded_calls_in_pump: usize = 0;
    var guarded_calls_elsewhere: usize = 0;
    var legacy_calls_outside_mode: usize = 0;
    var synthetic_fixture_calls_in_pump: usize = 0;
    var synthetic_fixture_calls_elsewhere: usize = 0;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "{s}/{s}",
            .{ root, entry.path },
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (std.mem.eql(u8, entry.path, "client_external_mode.zig")) {
            inline for (.{
                "@import(\"client_external_pump.zig\")",
                "@import(\"external_inbox_ledger.zig\")",
                "@import(\"external_owner_range.zig\")",
                "@import(\"external_pump_owner.zig\")",
                "cross_owner_quarantine_latched",
                "cross_owner_quarantine_events",
                "CrossOwnerQuarantineStatus",
            }) |forbidden|
                try std.testing.expect(!std.mem.containsAtLeast(
                    u8,
                    source,
                    1,
                    forbidden,
                ));
            continue;
        }
        const guarded_calls =
            countOccurrences(source, "prepareAdmitGuarded(") +
            countOccurrences(source, "commitPreparedAdmitGuarded(") +
            countOccurrences(source, "abortPreparedAdmitGuarded(");
        if (std.mem.eql(u8, entry.path, "client_external_pump.zig"))
            guarded_calls_in_pump += guarded_calls
        else
            guarded_calls_elsewhere += guarded_calls;
        legacy_calls_outside_mode += countOccurrences(source, "prepareAdmit(");
        legacy_calls_outside_mode += countOccurrences(source, "commitPreparedAdmit(");
        legacy_calls_outside_mode += countOccurrences(source, "abortPreparedAdmit(");
        if (std.mem.eql(u8, entry.path, "client_external_pump.zig"))
            synthetic_fixture_calls_in_pump +=
                countOccurrences(source, "client_external_mode.testing.admitBuffered(")
        else
            synthetic_fixture_calls_elsewhere +=
                countOccurrences(source, "client_external_mode.testing.admitBuffered(");
    }
    // C2 keeps the guarded leaf mode-local. C4 projects product owner inventory through one
    // prepare/commit/abort callsite set in the pump and nowhere else.
    try std.testing.expectEqual(@as(usize, 3), guarded_calls_in_pump);
    try std.testing.expectEqual(@as(usize, 0), guarded_calls_elsewhere);
    try std.testing.expectEqual(@as(usize, 0), legacy_calls_outside_mode);
    try std.testing.expectEqual(@as(usize, 3), synthetic_fixture_calls_in_pump);
    try std.testing.expectEqual(@as(usize, 0), synthetic_fixture_calls_elsewhere);
}

test "session host external RX DTO and classifier preserve neutral ownership boundaries" {
    const allocator = std.testing.allocator;
    const types_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_rx_types.zig",
    );
    defer allocator.free(types_source);
    const mode_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_mode.zig",
    );
    defer allocator.free(mode_source);
    const ledger_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_inbox_ledger.zig",
    );
    defer allocator.free(ledger_source);
    const demux_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_rx_demux.zig",
    );
    defer allocator.free(demux_source);
    const barrel_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host.zig",
    );
    defer allocator.free(barrel_source);

    try std.testing.expect(!std.mem.containsAtLeast(u8, types_source, 1, "client_external_mode.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, types_source, 1, "external_inbox_ledger.zig"));
    try std.testing.expect(std.mem.containsAtLeast(u8, mode_source, 1, "external_rx_types.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, mode_source, 1, "external_inbox_ledger.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, ledger_source, 1, "client_external_mode.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, demux_source, 1, ".alloc("));
    try std.testing.expect(!std.mem.containsAtLeast(u8, demux_source, 1, "std.json"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, demux_source, 1, "client_external_pump.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, demux_source, 1, "external_inbox_ledger.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(u8, demux_source, 1, "external_owner_seal.zig"));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(mode_source, "result.pair_seal = externalRxFrameDigest(&result);"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(demux_source, "testing.sealExternalRxFrame(&result);"),
    );
    try std.testing.expect(std.mem.containsAtLeast(u8, barrel_source, 1, "external_rx_types.zig"));
    try std.testing.expect(!std.mem.containsAtLeast(
        u8,
        barrel_source,
        1,
        "pub const external_rx_demux",
    ));
}

test "session host client pump policy imports only dependency-neutral leaves" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_pump.zig",
    );
    defer allocator.free(source);

    var imports: usize = 0;
    var import_builtins: usize = 0;
    var tokenizer = std.zig.Tokenizer.init(source);
    var saw_import = false;
    var saw_paren = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .builtin => {
                saw_import = std.mem.eql(u8, source[token.loc.start..token.loc.end], "@import");
                if (saw_import) import_builtins += 1;
                saw_paren = false;
            },
            .l_paren => {
                saw_paren = saw_import;
            },
            .string_literal => {
                if (saw_import and saw_paren) {
                    imports += 1;
                    const literal = source[token.loc.start..token.loc.end];
                    try std.testing.expect(
                        std.mem.eql(u8, literal, "\"std\"") or
                            std.mem.eql(
                                u8,
                                literal,
                                "\"external_recovery_types.zig\"",
                            ) or
                            std.mem.eql(
                                u8,
                                literal,
                                "\"request_id_state.zig\"",
                            ),
                    );
                }
                saw_import = false;
                saw_paren = false;
            },
            else => {
                if (saw_import and token.tag != .doc_comment) {
                    saw_import = false;
                    saw_paren = false;
                }
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 3), import_builtins);
    try std.testing.expectEqual(@as(usize, 3), imports);
    try std.testing.expect(!containsForbiddenExternalBuiltin(source));
    try std.testing.expect(!containsForbiddenPumpToken(source));
    try std.testing.expect(!containsForbiddenStdChild(source));

    const forbidden_fixture: [:0]const u8 =
        \\const std = @import("std");
        \\const Leaked = std.mem.Allocator;
    ;
    try std.testing.expect(containsForbiddenPumpToken(forbidden_fixture));
    const forbidden_heap: [:0]const u8 =
        \\const std = @import("std");
        \\const allocator = std.heap.page_allocator;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_heap));
    const forbidden_os: [:0]const u8 =
        \\const std = @import("std");
        \\const os = std.os;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_os));
    const forbidden_fs: [:0]const u8 =
        \\const std = @import("std");
        \\const Handle = std.fs.File.Handle;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_fs));
    const forbidden_c_import: [:0]const u8 =
        \\const c = @cImport({ @cInclude("unistd.h"); });
    ;
    try std.testing.expect(containsForbiddenExternalBuiltin(forbidden_c_import));
    const forbidden_import_alias: [:0]const u8 =
        \\const system = @import("std");
        \\const allocator = system.heap.page_allocator;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_import_alias));
    const forbidden_bare_alias: [:0]const u8 =
        \\const std = @import("std");
        \\const system = std;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_bare_alias));
    const forbidden_std_field: [:0]const u8 =
        \\const std = @import("std");
        \\const heap = @field(std, "heap");
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_std_field));
    const forbidden_extern: [:0]const u8 =
        \\extern fn close(fd: i32) c_int;
    ;
    try std.testing.expect(containsForbiddenExternalBuiltin(forbidden_extern));
    const forbidden_extern_builtin: [:0]const u8 =
        \\const errno = @extern(*i32, .{ .name = "errno" });
    ;
    try std.testing.expect(containsForbiddenExternalBuiltin(forbidden_extern_builtin));
    const forbidden_fake_std: [:0]const u8 =
        \\const std = 1;
        \\const system = @import("std");
        \\const allocator = system.heap.page_allocator;
    ;
    try std.testing.expect(containsForbiddenStdChild(forbidden_fake_std));
}

test "P4 R3 screen inbox recovery stays allocation free and below Client ownership" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/screen_inbox.zig",
    );
    defer allocator.free(source);
    try std.testing.expectEqual(@as(usize, 3), countOccurrences(source, "@import("));
    const forbidden = [_][]const u8{
        "std.mem.Allocator",
        "@import(\"client.zig\")",
        "@import(\"client_slot.zig\")",
        "@import(\"remote_runtime.zig\")",
        "@import(\"server.zig\")",
    };
    for (forbidden) |needle|
        try std.testing.expectEqual(@as(usize, 0), countOccurrences(source, needle));
}

test "session host runtime event wire stays below framing and product ownership" {
    const allocator = std.testing.allocator;
    const event_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/runtime_event_wire.zig",
    );
    defer allocator.free(event_source);
    const event_types_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/runtime_event_types.zig",
    );
    defer allocator.free(event_types_source);
    const event_reducer_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/runtime_event_reducer.zig",
    );
    defer allocator.free(event_reducer_source);
    const metadata_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/runtime_metadata_wire.zig",
    );
    defer allocator.free(metadata_source);

    const forbidden = [_][]const u8{
        "framing.zig",
        "client.zig",
        "client_pump.zig",
        "client_external_pump.zig",
        "external_inbox_ledger.zig",
    };
    for (forbidden) |name| {
        try std.testing.expect(!joinedStringLiteralsContain(event_source, name));
        try std.testing.expect(!joinedStringLiteralsContain(event_types_source, name));
        try std.testing.expect(!joinedStringLiteralsContain(event_reducer_source, name));
    }
    // Owning metadata must consume the bounded Scanner preflight. Reintroducing a heap DOM parser
    // here would make malformed/resource precedence depend on allocator state again.
    try std.testing.expect(std.mem.indexOf(
        u8,
        metadata_source,
        "parseFromSlice",
    ) == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        metadata_source,
        "std.json.Value",
    ) == null);

    const client_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client.zig",
    );
    defer allocator.free(client_source);
    const runtime_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime_source);
    const attachment_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_attachment.zig",
    );
    defer allocator.free(attachment_source);
    const external_attach_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_attach.zig",
    );
    defer allocator.free(external_attach_source);

    try std.testing.expect(std.mem.indexOf(u8, client_source, "resize_wire.parseEvent") == null);
    try std.testing.expect(std.mem.indexOf(u8, runtime_source, "resize_wire.parseEvent") == null);
    try std.testing.expect(std.mem.indexOf(u8, attachment_source, "decodeRevoked") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, runtime_source, "classifyAndMaterializeEvent(") != null,
    );
    try std.testing.expect(std.mem.indexOf(
        u8,
        runtime_source,
        "extractU64Field(resp, \"\\\"metadata_revision\\\":\"",
    ) == null);
    try std.testing.expect(std.mem.indexOf(u8, metadata_source, "EnvelopeKind") == null);
    try std.testing.expect(std.mem.indexOf(u8, metadata_source, "decodeSeed") == null);
    try std.testing.expect(std.mem.indexOf(u8, attachment_source, "pub fn decodeAttach(") == null);
    try std.testing.expect(
        std.mem.indexOf(u8, attachment_source, "pub fn decodeAttachForCapabilities(") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, attachment_source, "pub fn decodeFrozenV1ControllerAttach(") == null,
    );

    const attach_start = std.mem.indexOf(
        u8,
        external_attach_source,
        "fn attachSnapshot",
    ) orelse return error.TestUnexpectedResult;
    const attach_tail = external_attach_source[attach_start..];
    const attach_end = std.mem.indexOf(u8, attach_tail, "\nfn ") orelse attach_tail.len;
    const attach_body = attach_tail[0..attach_end];
    try std.testing.expect(std.mem.indexOf(u8, attach_body, "decodeAttachResponse(") != null);
    try std.testing.expect(std.mem.indexOf(u8, attach_body, "responseErrorExit(") == null);
    try std.testing.expect(std.mem.indexOf(u8, attach_body, "decodeWireError(") == null);

    const gui_attach_start = std.mem.indexOf(
        u8,
        runtime_source,
        "fn attachAndAssemble",
    ) orelse return error.TestUnexpectedResult;
    const gui_attach_tail = runtime_source[gui_attach_start..];
    const gui_attach_end = std.mem.indexOf(u8, gui_attach_tail, "\n    fn ") orelse
        gui_attach_tail.len;
    const gui_attach_body = gui_attach_tail[0..gui_attach_end];
    try std.testing.expect(
        std.mem.indexOf(u8, gui_attach_body, "decodeAttachResponse(") != null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, gui_attach_body, "decodeWireError(") == null,
    );
    try std.testing.expect(
        std.mem.indexOf(u8, gui_attach_body, "attachFailureCode(") == null,
    );
}

test "session host source transcript encoder imports only std" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_source_transcript.zig",
    );
    defer allocator.free(source);

    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "@import("),
    );
    try std.testing.expect(
        std.mem.indexOf(u8, source, "@import(\"std\")") != null,
    );
    inline for (.{
        "client.zig",
        "protocol.zig",
        "framing.zig",
        "runtime_event_wire.zig",
        "runtime_event_types.zig",
        "runtime_event_reducer.zig",
    }) |forbidden| {
        try std.testing.expect(!joinedStringLiteralsContain(source, forbidden));
    }
}

test "validated metadata token construction and materialization stay in classifier product path" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    var classifier_field_count: usize = 0;
    var validated_type_count: usize = 0;
    var private_materializer_count: usize = 0;
    var product_classifier_definition_count: usize = 0;
    var product_classifier_call_count: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);

        const is_types = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/runtime_event_types.zig",
        );
        const is_metadata_wire = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/runtime_metadata_wire.zig",
        );
        const is_event_preparation = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/runtime_event_preparation.zig",
        );
        const is_pending_event_preparation = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/pending_event_preparation.zig",
        );
        const is_remote_runtime = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/remote_runtime.zig",
        );
        const is_client = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client.zig",
        );
        const is_external_event_materialization = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_event_materialization.zig",
        );

        const field_refs = std.mem.count(u8, source, "classifier_preflight");
        if (field_refs != 0) {
            try std.testing.expect(is_types or is_pending_event_preparation);
            classifier_field_count += field_refs;
        }
        const type_refs = std.mem.count(u8, source, "ValidatedMetadataView");
        if (type_refs != 0) {
            try std.testing.expect(is_types or is_metadata_wire or is_event_preparation);
            validated_type_count += type_refs;
        }
        if (std.mem.indexOf(u8, source, "decodeMetadataEvent") != null)
            try std.testing.expect(is_metadata_wire);

        const exact_event_materializer_refs = std.mem.count(
            u8,
            source,
            "materializeExactEventMetadata",
        );
        if (exact_event_materializer_refs != 0)
            try std.testing.expect(
                is_metadata_wire or is_client or
                    is_external_event_materialization,
            );

        inline for (.{
            "sealOwnedMetadataDto",
            "validateOwnedMetadataDescriptor",
            "validateOwnedMetadataSeal",
        }) |owned_seal_api| {
            if (std.mem.indexOf(u8, source, owned_seal_api) != null)
                try std.testing.expect(
                    is_metadata_wire or is_external_event_materialization,
                );
        }
        if (std.mem.indexOf(
            u8,
            source,
            "ownedMetadataSemanticEqlEvent",
        ) != null)
            try std.testing.expect(is_metadata_wire or is_client);

        const private_materializer_refs = std.mem.count(
            u8,
            source,
            "materializePreparedEventMetadata",
        );
        if (private_materializer_refs != 0) {
            try std.testing.expect(is_metadata_wire);
            private_materializer_count += private_materializer_refs;
        }
        const product_classifier_refs = std.mem.count(
            u8,
            source,
            "classifyAndMaterializeEvent",
        );
        if (product_classifier_refs != 0) {
            if (is_metadata_wire) {
                product_classifier_definition_count += std.mem.count(
                    u8,
                    source,
                    "pub fn classifyAndMaterializeEvent(",
                );
            } else if (is_remote_runtime) {
                product_classifier_call_count += product_classifier_refs;
            } else return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(@as(usize, 4), classifier_field_count);
    try std.testing.expectEqual(@as(usize, 5), validated_type_count);
    try std.testing.expectEqual(@as(usize, 2), private_materializer_count);
    try std.testing.expectEqual(@as(usize, 1), product_classifier_definition_count);
    try std.testing.expectEqual(@as(usize, 1), product_classifier_call_count);
}

test "d2c pre-entry partial transition has one product decision source" {
    const allocator = std.testing.allocator;
    const demux = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_rx_demux.zig",
    );
    defer allocator.free(demux);
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);
    const traversal = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_rx_turn.zig",
    );
    defer allocator.free(traversal);
    const demux_product_end =
        std.mem.indexOf(u8, demux, "\ntest \"") orelse
        return error.TestUnexpectedResult;
    const pump_product_end =
        std.mem.indexOf(u8, pump, "\ntest \"") orelse
        return error.TestUnexpectedResult;

    var demux_advance_identifiers: usize = 0;
    var demux_tokenizer = std.zig.Tokenizer.init(demux);
    while (true) {
        const token = demux_tokenizer.next();
        if (token.tag == .eof or token.loc.start >= demux_product_end) break;
        if (token.tag != .identifier) continue;
        if (std.mem.eql(
            u8,
            demux[token.loc.start..token.loc.end],
            "advanceValidatedPartial",
        )) demux_advance_identifiers += 1;
    }
    // One definition and one classifier call. Traversal consumes the sealed result.
    try std.testing.expectEqual(@as(usize, 2), demux_advance_identifiers);

    var pump_advance_identifiers: usize = 0;
    var pump_traversal_identifiers: usize = 0;
    var pump_tokenizer = std.zig.Tokenizer.init(pump);
    while (true) {
        const token = pump_tokenizer.next();
        if (token.tag == .eof or token.loc.start >= pump_product_end) break;
        if (token.tag != .identifier) continue;
        const spelling = pump[token.loc.start..token.loc.end];
        if (std.mem.eql(u8, spelling, "advanceValidatedPartial"))
            pump_advance_identifiers += 1;
        if (std.mem.eql(u8, spelling, "traverseBuffered"))
            pump_traversal_identifiers += 1;
    }
    try std.testing.expectEqual(@as(usize, 0), pump_advance_identifiers);
    try std.testing.expectEqual(@as(usize, 1), pump_traversal_identifiers);

    var traversal_move_identifiers: usize = 0;
    var traversal_partial_identifiers: usize = 0;
    var traversal_parser_identifiers: usize = 0;
    var traversal_tokenizer = std.zig.Tokenizer.init(traversal);
    while (true) {
        const token = traversal_tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag != .identifier) continue;
        const spelling = traversal[token.loc.start..token.loc.end];
        if (std.mem.eql(u8, spelling, "moveFrame"))
            traversal_move_identifiers += 1;
        if (std.mem.eql(u8, spelling, "partialAfterMove"))
            traversal_partial_identifiers += 1;
        if (std.mem.eql(u8, spelling, "nextOutcomeWithRangeGuarded"))
            traversal_parser_identifiers += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), traversal_move_identifiers);
    try std.testing.expectEqual(@as(usize, 1), traversal_partial_identifiers);
    try std.testing.expectEqual(@as(usize, 1), traversal_parser_identifiers);
    inline for (.{
        "ExternalPumpStorage",
        "ExternalWholeTurnLease",
        "LiveScreenConsumePermit",
        "PreparedRxAggregate",
        "external_inbox_ledger",
        "external_pump_owner",
        "std.posix",
        "std.c",
    }) |forbidden|
        try std.testing.expectEqual(
            @as(usize, 0),
            countOccurrences(traversal, forbidden),
        );

    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (!std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_rx_turn_test_support.zig",
        ))
            try std.testing.expectEqual(
                @as(usize, 0),
                countOccurrences(
                    source,
                    "client_external_rx_turn_test_support.zig",
                ),
            );
        var traverse_count: usize = 0;
        var move_count: usize = 0;
        var guarded_parser_count: usize = 0;
        var unguarded_parser_count: usize = 0;
        const product_end = if (std.mem.indexOf(u8, source, "\ntest \"")) |start|
            start
        else
            source.len;
        var tokenizer = std.zig.Tokenizer.init(source);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag != .identifier) continue;
            const spelling = source[token.loc.start..token.loc.end];
            if (std.mem.eql(u8, spelling, "traverseBuffered"))
                traverse_count += 1;
            if (token.loc.start >= product_end) continue;
            if (std.mem.eql(u8, spelling, "moveFrame"))
                move_count += 1;
            if (std.mem.eql(u8, spelling, "nextOutcomeWithRangeGuarded"))
                guarded_parser_count += 1;
            if (std.mem.eql(u8, spelling, "nextOutcomeWithRange"))
                unguarded_parser_count += 1;
        }
        const expected: usize = if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_rx_turn.zig",
        ) or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        ))
            1
        else if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_rx_turn_test_support.zig",
        ))
            2
        else
            0;
        try std.testing.expectEqual(expected, traverse_count);
        const expected_move: usize = if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_rx_intent.zig",
        ))
            1
        else if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_rx_turn.zig",
        ))
            2
        else
            0;
        try std.testing.expectEqual(expected_move, move_count);
        const expected_guarded: usize = if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_mode.zig",
        ))
            2
        else if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_rx_turn.zig",
        ))
            1
        else
            0;
        try std.testing.expectEqual(expected_guarded, guarded_parser_count);
        const expected_unguarded: usize = if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_mode.zig",
        ))
            1
        else
            0;
        try std.testing.expectEqual(expected_unguarded, unguarded_parser_count);
    }
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(traversal, ".buf"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(traversal, ".head"),
    );
}

test "d2c C4 collector integration stays transport-leaf and pump-private" {
    const allocator = std.testing.allocator;
    const collector = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_rx_read.zig",
    );
    defer allocator.free(collector);
    const fixture = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_rx_read_test_support.zig",
    );
    defer allocator.free(fixture);
    const mode = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_mode.zig",
    );
    defer allocator.free(mode);
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);

    // C3 owns injected transport only. Parser admission, traversal, persistent owner state, and
    // real syscalls remain on the C4/C5 side of the boundary.
    inline for (.{
        "std.posix.read",
        "std.c.read",
        "recv(",
        "traverseBuffered",
        "ExternalPumpStorage",
        "external_inbox_ledger",
        "client_external_rx_turn",
        "prepareAdmitGuarded(",
        "commitPreparedAdmitGuarded(",
        "abortPreparedAdmitGuarded(",
    }) |forbidden|
        try std.testing.expectEqual(
            @as(usize, 0),
            countOccurrences(collector, forbidden),
        );
    inline for (.{
        "pub fn collectInjected(",
        "pub fn borrowStopped(",
        "pub fn stoppedBytes(",
        "pub fn settleStopped(",
        "pub fn teardown(",
    }) |definition|
        try std.testing.expectEqual(
            @as(usize, 1),
            countOccurrences(collector, definition),
        );
    inline for (.{
        "read.collectInjected(",
        "read.borrowStopped(",
        "read.stoppedBytes(",
        "read.settleStopped(",
        "read.teardown(",
        "mode.resetFinishedPreparedAdmit(",
        "pump.accountGuardedAdmitQuarantine(",
        "mode.finalizeQuarantinedPreparedAdmit(",
    }) |fixture_call|
        try std.testing.expectEqual(
            @as(usize, 1),
            countOccurrences(fixture, fixture_call),
        );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(mode, "pub fn resetFinishedPreparedAdmit("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(mode, "pub fn finalizeQuarantinedPreparedAdmit("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(mode, "pub fn markQuarantinedPreparedAdmitAccounted("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(pump, "pub fn accountGuardedAdmitQuarantine("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            pump,
            "client_external_mode.markQuarantinedPreparedAdmitAccounted(",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(pump, "fn resetCompletedPreparedAdmit("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(pump, "fn finalizeGuardedAdmitQuarantine("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(pump, "fn completeGuardedAdmitQuarantine("),
    );
    try std.testing.expectEqual(
        @as(usize, 4),
        countOccurrences(pump, "resetCompletedPreparedAdmit("),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        countOccurrences(pump, "finalizeGuardedAdmitQuarantine("),
    );
    try std.testing.expectEqual(
        @as(usize, 7),
        countOccurrences(pump, "completeGuardedAdmitQuarantine("),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(pump, "accountGuardedAdmitQuarantine("),
    );

    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var product_imports: usize = 0;
    var product_collector_calls: usize = 0;
    var product_completion_calls: usize = 0;
    var product_prepared_use_begin_calls: usize = 0;
    var product_prepared_use_finish_calls: usize = 0;
    var product_prepared_use_reset_calls: usize = 0;
    var accounting_seam_calls_outside_pump: usize = 0;
    var completion_helper_calls_outside_pump: usize = 0;
    var owner_heap_creates: usize = 0;
    var pump_product_type_tokens: usize = 0;
    var pump_fixture_type_tokens: usize = 0;
    var owner_type_tokens: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or
            !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const product_end = std.mem.indexOf(u8, source, "\ntest \"") orelse
            source.len;
        const product_source = source[0..product_end];
        const is_fixture = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_rx_read_test_support.zig",
        );
        if (!is_fixture) {
            if (!std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/client_external_pump.zig",
            )) {
                completion_helper_calls_outside_pump += countOccurrences(
                    product_source,
                    "resetCompletedPreparedAdmit(",
                );
                completion_helper_calls_outside_pump += countOccurrences(
                    product_source,
                    "finalizeGuardedAdmitQuarantine(",
                );
                completion_helper_calls_outside_pump += countOccurrences(
                    product_source,
                    "completeGuardedAdmitQuarantine(",
                );
            }
            product_imports += countOccurrences(
                source,
                "@import(\"client_external_rx_read.zig\")",
            );
            product_collector_calls += countOccurrences(
                product_source,
                ".collectInjected(",
            );
            product_completion_calls += countOccurrences(
                product_source,
                ".resetFinishedPreparedAdmit(",
            );
            product_completion_calls += countOccurrences(
                product_source,
                ".finalizeQuarantinedPreparedAdmit(",
            );
            product_completion_calls += countOccurrences(
                product_source,
                ".accountGuardedAdmitQuarantine(",
            );
            product_prepared_use_begin_calls += countOccurrences(
                product_source,
                ".beginPreparedAdmitUse(",
            );
            product_prepared_use_finish_calls += countOccurrences(
                product_source,
                ".finishPreparedAdmitUse(",
            );
            product_prepared_use_reset_calls += countOccurrences(
                product_source,
                ".resetFinishedPreparedAdmitUse(",
            );
            if (!std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/client_external_pump.zig",
            ) and !std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/client_external_mode.zig",
            )) {
                var seam_tokenizer = std.zig.Tokenizer.init(source);
                while (true) {
                    const seam_token = seam_tokenizer.next();
                    if (seam_token.tag == .eof) break;
                    if (seam_token.tag == .identifier and std.mem.eql(
                        u8,
                        source[seam_token.loc.start..seam_token.loc.end],
                        "markQuarantinedPreparedAdmitAccounted",
                    ))
                        accounting_seam_calls_outside_pump += 1;
                }
            }
        }
        if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_pump_owner.zig",
        )) {
            owner_heap_creates += countOccurrences(
                source,
                "create(client_external_pump.ExternalRxTurnScratch)",
            );
        }

        // Exact identifier allowlists catch multiline declarations, arrays, by-value returns,
        // and explicit stack construction rather than relying on one-line `var` spelling.
        var tokenizer = std.zig.Tokenizer.init(source);
        while (true) {
            const token = tokenizer.next();
            if (token.tag == .eof) break;
            if (token.tag != .identifier or
                !std.mem.eql(
                    u8,
                    source[token.loc.start..token.loc.end],
                    "ExternalRxTurnScratch",
                ))
                continue;
            if (std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/client_external_pump.zig",
            )) {
                if (token.loc.start < product_end)
                    pump_product_type_tokens += 1
                else
                    pump_fixture_type_tokens += 1;
            } else if (std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/external_pump_owner.zig",
            )) {
                owner_type_tokens += 1;
            } else {
                return error.TestUnexpectedResult;
            }
        }
    }
    // C4 mechanics and C5's sole POSIX product owner are the only consumers of the RX leaf.
    try std.testing.expectEqual(@as(usize, 2), product_imports);
    try std.testing.expectEqual(@as(usize, 1), product_collector_calls);
    try std.testing.expectEqual(@as(usize, 2), product_completion_calls);
    try std.testing.expectEqual(@as(usize, 1), product_prepared_use_begin_calls);
    try std.testing.expectEqual(@as(usize, 1), product_prepared_use_finish_calls);
    try std.testing.expectEqual(@as(usize, 1), product_prepared_use_reset_calls);
    try std.testing.expectEqual(
        @as(usize, 0),
        accounting_seam_calls_outside_pump,
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        completion_helper_calls_outside_pump,
    );
    try std.testing.expectEqual(@as(usize, 1), owner_heap_creates);
    // The identifier may grow new product or hostile-test uses without weakening ownership:
    // the tokenizer loop above rejects every file outside the pump and final owner.
    try std.testing.expect(pump_product_type_tokens > 0);
    try std.testing.expect(pump_fixture_type_tokens > 0);
    try std.testing.expect(owner_type_tokens > 0);
}

test "d2c S3-D drain evidence is one-shot and has one scheduling publication" {
    const allocator = std.testing.allocator;
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);
    const rx_read = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_rx_read.zig",
    );
    defer allocator.free(rx_read);
    const product_end = std.mem.indexOf(u8, pump, "\ntest \"") orelse
        pump.len;
    const product = pump[0..product_end];

    // S3-D owns one declaration and an exact allowlist of product orchestration edges. Abort and
    // finish intentionally occur in both the ordinary suffix and the terminal finalizer.
    inline for (.{
        .{ "prepareRxDrainEvidence", 2 },
        .{ "armRxDrainEvidence", 2 },
        .{ "consumeRxDrainEvidence", 2 },
        .{ "abortRxDrainEvidence", 3 },
        .{ "finishRxDrainEvidence", 5 },
        // The integrated loop adds one sibling-operation settlement edge. It retires only a
        // completed RX turn before control/TX admission; it cannot reset active drain evidence.
        .{ "resetFinishedRxDrainEvidence", 3 },
    }) |entry| {
        const helper = entry[0];
        const expected_occurrences: usize = entry[1];
        const declaration = try std.fmt.allocPrint(
            allocator,
            "fn {s}(",
            .{helper},
        );
        defer allocator.free(declaration);
        const use = try std.fmt.allocPrint(allocator, "{s}(", .{helper});
        defer allocator.free(use);
        try std.testing.expectEqual(
            @as(usize, 1),
            countOccurrences(product, declaration),
        );
        try std.testing.expectEqual(
            expected_occurrences,
            countOccurrences(product, use),
        );
    }

    // The pre-S3-D combined helper bypasses the prepared/armed/settled capability lifecycle.
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(product, "prepareAndConsumeDrainEvidence"),
    );

    // Lifecycle reset must use the authenticated reset helper, never assignment to the embedded
    // field. The field declaration itself uses `:` and is intentionally allowed.
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(product, ".drain_evidence ="),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(product, "drain_evidence = .{}"),
    );

    // A consumed evidence capability is projected through one local value into decide. No product
    // branch may manufacture the scheduling fact with a true literal.
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(product, "socket_rx_drained = true"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(product, "var socket_rx_drained = false"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(product, ".socket_rx_drained = socket_rx_drained"),
    );

    // Tokenization keeps the authority as a real private product type rather than text in a
    // comment or test fixture.
    var tokenizer = std.zig.Tokenizer.init(pump);
    var evidence_identifier_count: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof or token.loc.start >= product_end) break;
        if (token.tag == .identifier and std.mem.eql(
            u8,
            product[token.loc.start..token.loc.end],
            "RxDrainEvidence",
        ))
            evidence_identifier_count += 1;
    }
    try std.testing.expect(evidence_identifier_count > 0);

    // The C3 leaf is the sole owner of the private receipt/borrow/permit/seed graph. Pump code
    // receives two authenticated value-only projections instead of reconstructing leaf digests.
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(rx_read, "pub const DrainSeedAuthorityPhase ="),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(rx_read, "pub const DrainSeedAuthorityProjection = struct {"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(rx_read, "pub fn snapshotDrainSeedAuthority("),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(product, ".snapshotDrainSeedAuthority("),
    );

    const projection_start = std.mem.indexOf(
        u8,
        rx_read,
        "pub const DrainSeedAuthorityProjection = struct {",
    ) orelse return error.TestUnexpectedResult;
    const projection_tail = rx_read[projection_start..];
    const projection_end_rel = std.mem.indexOf(u8, projection_tail, "};") orelse
        return error.TestUnexpectedResult;
    const projection_end = projection_start + projection_end_rel + 2;
    var projection_tokenizer = std.zig.Tokenizer.init(rx_read);
    var phase_fields: usize = 0;
    var continuity_fields: usize = 0;
    var digest_fields: usize = 0;
    var raw_digest_fields: usize = 0;
    while (true) {
        const token = projection_tokenizer.next();
        if (token.tag == .eof or token.loc.start >= projection_end) break;
        if (token.loc.start < projection_start or token.tag != .identifier) continue;
        const identifier = rx_read[token.loc.start..token.loc.end];
        if (std.mem.eql(u8, identifier, "phase")) phase_fields += 1;
        if (std.mem.eql(u8, identifier, "continuity_digest"))
            continuity_fields += 1;
        if (std.mem.eql(u8, identifier, "digest")) digest_fields += 1;
        inline for (.{
            "receipt_digest",
            "borrow_digest",
            "permit_digest",
            "seed_digest",
        }) |forbidden| {
            if (std.mem.eql(u8, identifier, forbidden)) {
                raw_digest_fields += 1;
            }
        }
    }
    try std.testing.expectEqual(@as(usize, 1), phase_fields);
    try std.testing.expectEqual(@as(usize, 1), continuity_fields);
    try std.testing.expectEqual(@as(usize, 1), digest_fields);
    try std.testing.expectEqual(@as(usize, 0), raw_digest_fields);

    // Each product projection call carries one explicit phase; no third phase/call may appear.
    var phase_cursor: usize = 0;
    inline for (.{ ".prepared,", ".consumed," }) |phase| {
        const call_start = std.mem.indexOfPos(
            u8,
            product,
            phase_cursor,
            ".snapshotDrainSeedAuthority(",
        ) orelse return error.TestUnexpectedResult;
        const call_end = std.mem.indexOfPos(
            u8,
            product,
            call_start,
            ") orelse",
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            @as(usize, 1),
            countOccurrences(product[call_start..call_end], phase),
        );
        phase_cursor = call_end;
    }

    // Parser authority is a typed seal. Byte-casting it in the pump would bypass its structural
    // contract even if the resulting digest happened to remain stable.
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(product, "asBytes(&evidence.parser_seal"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(product, "asBytes(&state.rx_provenance.parser_seal"),
    );

    // D1 returns consumed evidence to the callback-free outer adapter. The outer adapter must
    // validate that exact evidence before publishing the drained scheduling fact, decide once,
    // and only then finish the evidence.
    const consume_start = std.mem.lastIndexOf(
        u8,
        product,
        "self.consumeRxDrainEvidence(",
    ) orelse return error.TestUnexpectedResult;
    const consume_end = std.mem.indexOfPos(
        u8,
        product,
        consume_start,
        ");",
    ) orelse return error.TestUnexpectedResult;
    const fresh_validation = std.mem.indexOfPos(
        u8,
        product,
        consume_end,
        "self.consumedRxDrainEvidenceCurrent(",
    ) orelse return error.TestUnexpectedResult;
    const drained_branch = std.mem.lastIndexOf(
        u8,
        product[0..fresh_validation],
        ".drained => |summary|",
    ) orelse return error.TestUnexpectedResult;
    const publication = std.mem.indexOfPos(
        u8,
        product,
        fresh_validation,
        "recordRxDrainTestEvent(.published)",
    ) orelse return error.TestUnexpectedResult;
    const decide = std.mem.indexOfPos(
        u8,
        product,
        publication,
        "recordRxDrainTestEvent(.decide)",
    ) orelse return error.TestUnexpectedResult;
    const policy = std.mem.indexOfPos(
        u8,
        product,
        decide,
        "self.policyResultFromRxSummary(summary, true)",
    ) orelse return error.TestUnexpectedResult;
    const finish = std.mem.indexOfPos(
        u8,
        product,
        policy,
        "finishRxDrainEvidence(scratch)",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(
        consume_end < fresh_validation and
            fresh_validation < publication and
            publication < decide and
            decide < policy and
            policy < finish,
    );
    const publication_suffix = product[drained_branch..fresh_validation];
    inline for (.{
        "classifyAcceptedAllowanceStop(",
        "liveOwnerBlockerProjection(",
        "currentDrainBlockerProjection(",
        "buildRxOwnerAuthoritySnapshot(",
        "acquirePumpCallbackRegion(",
        "finishPumpCallbackRegion(",
        "client_pump.decide(",
    }) |forbidden|
        try std.testing.expectEqual(
            @as(usize, 0),
            countOccurrences(publication_suffix, forbidden),
        );
}

test "d2b3d live owner substrate stays private with one buffered product traversal" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    var owner_module_count: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig"))
            continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const mentions_owner =
            std.mem.indexOf(u8, source, "LivePartialBatch") != null or
            std.mem.indexOf(u8, source, "LiveScreenBacklog") != null or
            std.mem.indexOf(u8, source, "CompletedControlOwner") != null;
        if (!mentions_owner) continue;
        try std.testing.expect(std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        ));
        owner_module_count += 1;
        try std.testing.expect(
            std.mem.indexOf(u8, source, "pub const LivePartialBatch") == null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, source, "pub const LiveScreenBacklog") == null,
        );
        try std.testing.expect(
            std.mem.indexOf(u8, source, "pub const CompletedControlOwner") == null,
        );
        inline for (.{
            "pub const ControlCorrelationOwner",
            "pub const PreparedControlResponseTake",
            "pub const FrozenControlResponse",
            "pub fn takeControlResponse",
            "pub fn publishControlCorrelation",
        }) |forbidden_control_api|
            try std.testing.expect(
                std.mem.indexOf(u8, source, forbidden_control_api) == null,
            );
        inline for (.{
            "pub fn publishLivePartial",
            "pub fn publishLiveScreen",
            "pub fn publishCompletedControl",
            "pub fn takeCompletedControl",
        }) |forbidden_writer|
            try std.testing.expect(
                std.mem.indexOf(u8, source, forbidden_writer) == null,
            );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "pub fn pumpRxTurn("),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                source,
                "client_external_mode.nextOutcomeWithRangeGuarded(",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                source,
                "client_external_mode.nextOutcomeWithRange(",
            ),
        );
        const activation_start = std.mem.indexOf(
            u8,
            source,
            "fn activateSyntheticLiveOwnersForTest(",
        ) orelse return error.TestUnexpectedResult;
        const activation_tail = source[activation_start..];
        const activation_end_rel = std.mem.indexOfPos(
            u8,
            activation_tail,
            3,
            "\nfn ",
        ) orelse return error.TestUnexpectedResult;
        const activation_source = activation_tail[0..activation_end_rel];
        const fixture_start = activation_start + activation_end_rel + 1;
        const fixture_tail = source[fixture_start..];
        const fixture_end_rel = std.mem.indexOfPos(
            u8,
            fixture_tail,
            3,
            "\nfn ",
        ) orelse return error.TestUnexpectedResult;
        const fixture_source = fixture_tail[0..fixture_end_rel];
        try std.testing.expect(
            std.mem.indexOf(
                u8,
                activation_source,
                "if (comptime !builtin.is_test) unreachable;",
            ) != null,
        );
        try std.testing.expectEqual(
            @as(usize, 2),
            std.mem.count(u8, source, "activateSyntheticLiveOwnersForTest"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                fixture_source,
                "activateSyntheticLiveOwnersForTest(",
            ),
        );
        // A private writer or direct field assignment still has to create these active tags.
        // Keeping each exact activation assignment unique to the guarded synthetic fixture makes
        // product-writer zero a source boundary instead of a public-name convention.
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "storage.live_partial = .{ .assembling"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                activation_source,
                "storage.live_partial = .{ .assembling",
            ),
        );
        // The aggregate writer publishes through the exact presealed destination address instead
        // of naming the persistent field a second time. d2b3d opens one product traversal facade,
        // but it must keep this fixed writer unique and must not expose a second public writer.
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "target.* = .{ .assembling"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                source,
                "storage.live_screen = .{\n        .saved_self_addr",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                activation_source,
                "storage.live_screen = .{\n        .saved_self_addr",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "storage.completed_control = .{ .completed"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "target.* = .{ .completed"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                activation_source,
                "storage.completed_control = .{ .completed",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                source,
                "fn commitResponseDestinationPlanUnchecked(",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                source,
                "commitResponseDestinationPlanUnchecked(\n            storage,\n            @ptrFromInt(write.prepared_backing_addr),",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "self.live_partial = .{ .assembling"),
        );
        const aggregate_commit_start = std.mem.indexOf(
            u8,
            source,
            "    fn commitRxAggregate(",
        ) orelse return error.TestUnexpectedResult;
        const aggregate_commit_tail = source[aggregate_commit_start..];
        const aggregate_commit_end = std.mem.indexOfPos(
            u8,
            aggregate_commit_tail,
            4,
            "\n    fn ",
        ) orelse return error.TestUnexpectedResult;
        const aggregate_commit_source =
            aggregate_commit_tail[0..aggregate_commit_end];
        const validate_start = std.mem.indexOf(
            u8,
            source,
            "    fn validateAndPrepareRxAggregateCommit(",
        ) orelse return error.TestUnexpectedResult;
        const validate_tail = source[validate_start..];
        const validate_end = std.mem.indexOf(
            u8,
            validate_tail,
            "\n    const PublishedRxAggregateCommit",
        ) orelse return error.TestUnexpectedResult;
        const validate_source = validate_tail[0..validate_end];
        const publish_start = std.mem.indexOf(
            u8,
            source,
            "    fn publishRxAggregateUnchecked(",
        ) orelse return error.TestUnexpectedResult;
        const publish_tail = source[publish_start..];
        const publish_end = std.mem.indexOf(
            u8,
            publish_tail,
            "\n    fn finishPublishedRxAggregateCommit(",
        ) orelse return error.TestUnexpectedResult;
        const publish_source = publish_tail[0..publish_end];
        const finish_start = publish_start + publish_end;
        const finish_tail = source[finish_start..];
        const finish_end = std.mem.indexOf(
            u8,
            finish_tail,
            "\n    fn commitRxAggregateUnchecked(",
        ) orelse return error.TestUnexpectedResult;
        const finish_source = finish_tail[0..finish_end];
        const first_test = std.mem.indexOf(u8, source, "\ntest \"") orelse
            return error.TestUnexpectedResult;
        const product_source = source[0..first_test];
        const schema_start = std.mem.indexOf(
            u8,
            product_source,
            "\nfn exactCr3aOwnerSchema(",
        ) orelse return error.TestUnexpectedResult;
        const owner_product_source = product_source[0..schema_start];
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                owner_product_source,
                "control_correlation: ControlCorrelationOwner",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                owner_product_source,
                "completed_control: CompletedControlOwner",
            ),
        );
        try std.testing.expectEqual(
            // Terminal detach is the fifth reviewed frame family beside input/resize/resync and
            // the existing control path. It uses the same sealed progress ledger.
            @as(usize, 5),
            std.mem.count(
                u8,
                product_source,
                "client_external_tx.requestFrameProgress(",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 2),
            std.mem.count(u8, product_source, "commitRxAggregate("),
        );
        // The declaration plus the one buffered product traversal call are the only pre-test
        // occurrences. Test-only exercises may grow without opening another product caller.
        try std.testing.expect(
            std.mem.count(u8, source, "commitRxAggregate(") >= 2,
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                aggregate_commit_source,
                "commitScreenDestinationPlanUnchecked(",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                publish_source,
                "commitDestinationWriteUnchecked(self, aggregate, write)",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                validate_source,
                "commitDestinationWriteUnchecked(",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                finish_source,
                "commitDestinationWriteUnchecked(",
            ),
        );
        // The suffix consumes the presealed writer kind; it must not reinterpret the ledger
        // disposition after the aggregate has crossed the commit barrier.
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                source,
                "aggregate.dispositions[write.mutation_index]",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                aggregate_commit_source,
                "commitEventScalarDestinationsUnchecked",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(
                u8,
                product_source,
                "storage.live_screen.len += 1",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "self.completed_control = .{ .completed"),
        );
        // Count every canonical raw LHS, not only active literals. `zig fmt --check` makes these
        // spellings stable; a helper-return assignment such as `self.live_partial = next` or an
        // extra private writer changes the total even when it avoids the active literal.
        try std.testing.expectEqual(
            @as(usize, 7),
            std.mem.count(u8, source, "self.live_partial ="),
        );
        try std.testing.expectEqual(
            @as(usize, 6),
            std.mem.count(u8, source, "self.live_screen ="),
        );
        try std.testing.expectEqual(
            @as(usize, 10),
            std.mem.count(u8, source, "self.completed_control ="),
        );
        const revoke_canonical_writer = betweenMarkers(
            product_source,
            "MARU_CLEANUP_CANONICAL_WRITER_BEGIN",
            "MARU_CLEANUP_CANONICAL_WRITER_END",
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                revoke_canonical_writer,
                "self.completed_control = .none",
            ),
        );
        const response_publish_start = std.mem.indexOf(
            u8,
            product_source,
            "    fn publishControlResponseTakeUnchecked(",
        ) orelse return error.TestUnexpectedResult;
        const response_publish_tail = product_source[response_publish_start..];
        const response_publish_end = std.mem.indexOf(
            u8,
            response_publish_tail,
            "\n    fn commitControlResponseTakeUncheckedUnderHeldLease(",
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(
                u8,
                response_publish_tail[0..response_publish_end],
                "self.completed_control = .none",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "self.live_partial == .none"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "self.completed_control == .none"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "storage.live_partial = .{"),
        );
        try std.testing.expectEqual(
            @as(usize, 2),
            std.mem.count(u8, source, "storage.live_screen ="),
        );
        try std.testing.expectEqual(
            @as(usize, 2),
            std.mem.count(u8, product_source, "storage.completed_control ="),
        );
        try std.testing.expectEqual(
            @as(usize, 5),
            std.mem.count(u8, source, "self.live_partial = .terminal"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "self.live_partial = .none"),
        );
        try std.testing.expectEqual(
            @as(usize, 5),
            std.mem.count(
                u8,
                source,
                "self.live_screen = .{ .lifecycle = .cleaned_tombstone }",
            ),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "self.live_screen = .{}"),
        );
        try std.testing.expectEqual(
            @as(usize, 5),
            std.mem.count(u8, source, "self.completed_control = .terminal"),
        );
        try std.testing.expectEqual(
            // One legacy reset site plus the response-take publication and the two callback
            // restores pinned above. Their individual function slices prevent this total from
            // laundering a new arbitrary writer.
            @as(usize, 3),
            std.mem.count(u8, source, "self.completed_control = .none"),
        );
        // Whole-owner pointer aliases could otherwise hide `owner.* = active`; keep every
        // address-taking spelling bounded as well. Nested payload borrows are not whole owners.
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "&self.live_partial"),
        );
        try std.testing.expectEqual(
            @as(usize, 5),
            std.mem.count(u8, source, "&self.live_screen"),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "&self.completed_control"),
        );
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, source, "&storage.live_partial"),
        );
        try std.testing.expectEqual(
            @as(usize, 8),
            std.mem.count(u8, source, "&storage.live_screen"),
        );
        try std.testing.expectEqual(
            // The product writer is the only pre-test whole-owner address borrow. Hostile
            // fixtures may inspect a local storage owner without opening another product writer.
            @as(usize, 1),
            std.mem.count(u8, product_source, "&storage.completed_control"),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "@field(self, \"live_partial\")"),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "@field(self, \"live_screen\")"),
        );
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, source, "@field(self, \"completed_control\")"),
        );
    }
    try std.testing.expectEqual(@as(usize, 1), owner_module_count);
    const product_owner = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_pump_owner.zig",
    );
    defer allocator.free(product_owner);
    const mechanics_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(mechanics_source);
    const product_owner_end = std.mem.indexOf(
        u8,
        product_owner,
        "const client_mod = @import(\"client.zig\");",
    ) orelse return error.TestUnexpectedResult;
    const product_owner_boundary = product_owner[0..product_owner_end];
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, product_owner_boundary, ".pumpRxTurn("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            product_owner_boundary,
            "client_external_pump.RxTurnOps{",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, product_owner_boundary, "pub fn pumpRx("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, product_owner_boundary, "pumpBufferedRx"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, product_owner_boundary, "c.recv("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, product_owner_boundary, "c.send("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, product_owner_boundary, "c.write("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, product_owner_boundary, "c.read("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, mechanics_source, "pub const RxTurnOps = struct"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, mechanics_source, "pub fn pumpRxTurn("),
    );
    // F3 revoke arbitration has one product decision point. Cancellation preparation may only
    // consume this plan; a second switch in the external pump would silently fork precedence.
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            mechanics_source,
            "client_pump.planRevokeIntegration(",
        ),
    );
    const revoke_publish = betweenMarkers(
        mechanics_source,
        "MARU_REVOKE_CONSUME_PUBLISH_BEGIN",
        "MARU_REVOKE_CONSUME_PUBLISH_END",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(
            u8,
            revoke_publish,
            "consumePreparedCancellationUnderHeldLease(",
        ),
    );
    // The second reviewed consumer is normal 3b cleanup's offset-zero input cancellation. Both
    // paths share the same held-lease final check; neither exposes the unchecked commit.
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(
            u8,
            mechanics_source,
            "consumePreparedCancellationUnderHeldLease(",
        ),
    );
    inline for (.{ "finishCancellationCleanup(", "finishPublishedRxAggregateCommit(", ".allocator", ".free(" }) |forbidden|
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, revoke_publish, forbidden),
        );
    const revoke_validate = betweenMarkers(
        mechanics_source,
        "MARU_REVOKE_PURE_VALIDATE_BEGIN",
        "MARU_REVOKE_PURE_VALIDATE_END",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(
            u8,
            revoke_validate,
            "consumePreparedCancellationUnderHeldLease(",
        ),
    );
    inline for (.{ "abortPreparedCancellation(", "resetCancellationGraphForNextTurn(" }) |mutation|
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, revoke_validate, mutation),
        );
    const revoke_callbacks = betweenMarkers(
        mechanics_source,
        "MARU_REVOKE_CALLBACK_TAIL_BEGIN",
        "MARU_REVOKE_CALLBACK_TAIL_END",
    ) orelse return error.TestUnexpectedResult;
    const canonical_writer = betweenMarkers(
        mechanics_source,
        "MARU_CLEANUP_CANONICAL_WRITER_BEGIN",
        "MARU_CLEANUP_CANONICAL_WRITER_END",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "consumePreparedCancellationUnderHeldLease(",
        "publishControlResponseTakeUnchecked(",
        "publishRxAggregateUnchecked(",
        "self.control_correlation =",
        "control_correlation.generation =",
        "self.owner_authority =",
        "self.owner_authority_seal =",
        "self.completed_control =",
        "self.completed_control_generation =",
        "self.semantic_state =",
    }) |forbidden|
        try std.testing.expectEqual(
            @as(usize, 0),
            std.mem.count(u8, revoke_callbacks, forbidden),
        );
    inline for (.{
        "self.control_correlation = canonical.correlation",
        "self.owner_authority = canonical.authority",
        "self.owner_authority_seal = canonical.authority_seal",
        "self.completed_control = .none",
        "self.completed_control_generation = canonical.completed_generation",
        "self.semantic_state = canonical.semantic",
    }) |writer|
        try std.testing.expectEqual(
            @as(usize, 1),
            std.mem.count(u8, canonical_writer, writer),
        );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, mechanics_source, "pumpInjectedRxTurnForTest"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        std.mem.count(u8, product_owner_boundary, "nextOutcomeWithRange("),
    );
}

test "f2 control correlation reducer stays dependency neutral" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_control_correlation.zig",
    );
    defer allocator.free(source);
    try std.testing.expectEqual(
        @as(usize, 3),
        std.mem.count(u8, source, "@import(\""),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "@import(\"std\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "@import(\"client_pump.zig\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, source, "@import(\"control_response_wire.zig\")"),
    );
    inline for (.{
        "client_external_pump.zig",
        "client_external_tx.zig",
        "client_external_mode.zig",
        "protocol.zig",
    }) |forbidden_import|
        try std.testing.expect(
            std.mem.indexOf(u8, source, forbidden_import) == null,
        );
}

test "f3c0 control wire is the typed product codec without drain capability" {
    const allocator = std.testing.allocator;
    const codec = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/control_response_wire.zig",
    );
    defer allocator.free(codec);
    const runtime = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);
    const protocol_source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/protocol.zig",
    );
    defer allocator.free(protocol_source);

    try std.testing.expectEqual(@as(usize, 3), std.mem.count(u8, codec, "@import(\""));
    try std.testing.expect(std.mem.indexOf(u8, codec, "client_external_pump.zig") == null);
    try std.testing.expect(std.mem.indexOf(u8, codec, "remote_runtime.zig") == null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        protocol_source,
        "host_protocol.max_control_json",
    ) != null);
    try std.testing.expect(std.mem.indexOf(
        u8,
        codec,
        "host_protocol.max_control_json",
    ) != null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, runtime, "control_response_wire.decodeResizeResponse("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, runtime, "control_response_wire.decodeResyncEnvelope("),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        std.mem.count(u8, runtime, "control_response_wire.encodeParams("),
    );
    try std.testing.expect(std.mem.indexOf(u8, runtime, "fn parseResizeReply(") == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, pump, "control_response_wire.encodeRequest("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, pump, "const PreparedWholeDrainPermit = struct"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, pump, "const PreparedControlSemanticVerdict = struct"),
    );
    const permit = betweenMarkers(
        pump,
        "const PreparedWholeDrainPermit = struct {",
        "const ControlSemanticValue = union(enum) {",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "saved_self_addr",       "storage_addr",               "lease_addr",             "owner_incarnation",
        "operation_generation",  "turn_generation",            "parser_generation",      "parser_absolute_start",
        "parser_absolute_end",   "parser_seal_digest",         "sampled_now_ns",         "authority_generation",
        "authority_seal_digest", "completed_owner_generation", "correlation_generation", "tx_queue_generation",
        "lifecycle",             "digest",
    }) |field| try std.testing.expect(std.mem.indexOf(u8, permit, field) != null);
    const verdict = betweenMarkers(
        pump,
        "const PreparedControlSemanticVerdict = struct {",
        "const ConsumeResyncAckResult = enum {",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "completed_payload_seal", "request_id",           "control_kind",          "expectation",
        "target",                 "authority_generation", "authority_seal_digest", "permit_digest",
        "lifecycle",              "digest",
    }) |field| try std.testing.expect(std.mem.indexOf(u8, verdict, field) != null);
    inline for (.{ "consumed", "stale", "invalid", "terminal" }) |outcome|
        try std.testing.expect(std.mem.indexOf(u8, pump, outcome) != null);
    try std.testing.expect(std.mem.indexOf(u8, pump, "const ConsumeResyncAckUnderHeldLeaseFn") != null);
}

test "recovery integration contract keeps future ledger generation out of control authority" {
    const allocator = std.testing.allocator;
    const recovery_types = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_recovery_types.zig",
    );
    defer allocator.free(recovery_types);
    const codec = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/control_response_wire.zig",
    );
    defer allocator.free(codec);
    const policy = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_pump.zig",
    );
    defer allocator.free(policy);
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);

    const authority = betweenMarkers(
        recovery_types,
        "pub const ControlAuthority = struct {",
        "pub const MarkResult = enum {",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, authority, "expected_token_generation") == null);
    const request = betweenMarkers(
        codec,
        "pub const ResyncRequest = struct {",
        "pub const WireRequest = union(enum) {",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, request, "recovery_authority") != null);
    try std.testing.expect(std.mem.indexOf(u8, request, "expected_token_generation") == null);
    try std.testing.expect(std.mem.indexOf(u8, pump, "spec.request.resync.recovery_key") == null);
    try std.testing.expectEqual(
        @as(usize, 1),
        std.mem.count(u8, pump, "test \"f3c0 recovery integration contract"),
    );

    const awaiting = betweenMarkers(
        policy,
        "pub const AwaitingSnapshot = struct {",
        "pub const SnapshotInFlight = struct {",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, awaiting, "recovery_barrier_absolute") != null);
    try std.testing.expect(std.mem.indexOf(u8, awaiting, "expected_token_generation") == null);
    const in_flight = betweenMarkers(
        policy,
        "pub const SnapshotInFlight = struct {",
        "pub const HostRecoveryPhase = union(enum) {",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, in_flight, "recovery_barrier_absolute") != null);
    try std.testing.expect(std.mem.indexOf(u8, in_flight, "expected_token_generation") != null);
    try std.testing.expect(std.mem.indexOf(u8, policy, "pub fn planRecoverySnapshotBinding(") != null);
    try std.testing.expect(std.mem.count(u8, pump, ".snapshot_in_flight =>") >= 4);
}

// 파일 탐색기 **셀 투영은 공유 모듈에 살고, 쓰는 쪽은 Windows 뿐이다**(FT3).
//
// macOS 제품 트리는 typed component 가 그린다(FT1·FT2). 이 투영이 남아 있는 이유는 **Windows 제품이
// 그것으로 도크 트리를 그리기 때문**이다(W8.7a2). 이 게이트를 처음 쓸 때는 소비자가 스모크 하나였고
// "언젠가 지운다" 가 목표였는데, 그 사이 Windows 가 제품 화면을 그 위에 올렸다 — 이제 **삭제 대상이
// 아니라 한 플랫폼의 렌더 경로**다. 그래서 세는 것은 "언제 지울까" 가 아니라 **어디에 사는지**와
// **macOS 가 되돌아오지 않는가** 다.
//
// ⑴ `platform/cell_text.zig`(macOS·Windows 공유 L4)가 정의를 소유한다. `platform/macos` 로 되돌아가면
//    `src/main.zig` 가 다시 macOS 파일을 import 하게 되고, 그게 이 이동이 없앤 층 냄새다.
// ⑵ macOS 제품·스모크에는 호출이 0 이다. 되돌아오면 렌더 경로가 둘이 되고 그 둘은 조용히 갈린다
//    (FT1 이 정확히 그 상태를 정리했다 — "렌더가 그 창을 쓴다" 단언이 죽은 경로를 보고 있었다).
test "파일 트리 셀 투영은 공유 모듈이 소유하고 Windows 만 쓴다" {
    const allocator = std.testing.allocator;
    const shared = try readZigFileZ(allocator, "src/platform/cell_text.zig");
    defer allocator.free(shared);
    const macos_builder = try readZigFileZ(allocator, "src/platform/macos/coretext_frame_builder.zig");
    defer allocator.free(macos_builder);
    const main_source = try readZigFileZ(allocator, "src/main.zig");
    defer allocator.free(main_source);
    const smoke = try readZigFileZ(allocator, "src/platform/macos/coretext_smoke.zig");
    defer allocator.free(smoke);
    const app_session = try readZigFileZ(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);

    // ⑴ 정의는 공유 모듈에만 있다.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(shared, "pub fn buildFileTreeDrawList("));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(macos_builder, "pub fn buildFileTreeDrawList("));
    // 그리고 Windows 스모크는 macOS 파일이 아니라 공유 모듈을 든다.
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(main_source, "platform/macos/coretext_frame_builder.zig"));

    // ⑵ Windows 가 **실제로 쓴다** — 0 이 되면 함수를 지울 수 있다는 뜻이므로 이 게이트도 함께
    //    없애야 한다(그 판단을 사람이 하도록 여기서 실패시킨다).
    //
    //    **둘인 이유**: ⑴ `win32-file-tree-draw-smoke`(§2m.6 — 표면 하나만 창에 띄운다)와
    //    ⑵ `win32-terminal` 의 도크(§2m.31 ⒜2 — 터미널 옆에 트리를 그린다). 두 자리가 **다른 것을
    //    판정한다**: 앞은 투영 자체가 맞는가, 뒤는 그것이 도크 사각형 안에 서는가. 합치면 한쪽이
    //    사라진다. 이 수를 올릴 때는 여기에 그 자리가 무엇을 재는지 적는다.
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(main_source, "buildFileTreeDrawList("));
    // macOS 제품·스모크에는 호출이 없다(주석 언급은 여는 괄호가 없어 안 세진다).
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(smoke, "buildFileTreeDrawList("));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(app_session, "buildFileTreeDrawList("));
}

/// Zig **코드**에 플랫폼 접근성 어휘가 있으면 그 낱말을 돌려준다. 없으면 null.
///
/// **주석은 안 본다.** 이 경계가 막으려는 것은 "Zig 가 플랫폼 타입을 만지는 것"이지 "문서가 계약을
/// 인용하는 것"이 아니다. 실제로 이 게이트의 첫 실행에서 유일한 위반이 `ui/semantics.zig` 의 머리말
/// 이었다 — 계약 원문(*"Zig tree는 `NSAccessibility` object나 delegate를 보유하지 않는다"*)을 그대로
/// 인용한 자리다. 인용을 금지하면 계약이 사는 파일이 계약을 못 적는다.
///
/// 그래서 `std.zig.Tokenizer` 로 훑고 주석 토큰(`doc_comment`·`container_doc_comment`)은 건너뛴다.
/// 일반 주석(`//`)은 애초에 토큰이 아니다. 남는 것은 식별자·문자열·키워드 — 코드가 실제로 만지는 것뿐이다.
fn platformAccessibilityVocabularyInCode(source: [:0]const u8, needles: []const []const u8) ?[]const u8 {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .doc_comment, .container_doc_comment => continue,
            else => {},
        }
        const text = source[token.loc.start..token.loc.end];
        for (needles) |needle| {
            if (std.mem.indexOf(u8, text, needle) != null) return needle;
        }
    }
    return null;
}

// 접근성 서술자는 **뜻만 담고 플랫폼 어휘를 담지 않는다**(CIM §3).
//
// > Swift adapter만 이 descriptor를 native accessibility element로 투영하고, Zig tree는
// > `NSAccessibility` object나 delegate를 보유하지 않는다.
//
// 이 경계가 무너지는 방식은 하나다 — adapter 를 붙이는 날 "여기서 문자열 하나만 만들면 편한데"가
// 되는 것이다. 그 한 줄이 들어오면 같은 사실(이 줄의 역할)의 주인이 둘이 되고, 둘은 조용히 갈린다.
// Windows(UI Automation)·모바일이 같은 tree 를 쓸 수 없게 되는 것도 그 순간이다.
//
// 그래서 **Zig 어디에도** 플랫폼 접근성 어휘가 없어야 한다. adapter 가 오면 그 코드는 `.m`/Swift 에
// 산다(이 스캔은 `.zig` 만 본다).
test "Zig 는 플랫폼 접근성 어휘를 갖지 않는다 — 투영은 adapter 만 한다" {
    const allocator = std.testing.allocator;
    const platform_vocabulary = [_][]const u8{
        "NSAccessibility",
        "AXUIElement",
        "isAccessibilityElement",
        "accessibilityLabel",
        // Windows 쪽 어휘도 같은 규율이다 — 지금 없고, 없는 채로 둔다.
        "IRawElementProvider",
        "UIA_",
    };
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (platformAccessibilityVocabularyInCode(source, &platform_vocabulary)) |needle| {
            std.debug.print("접근성 플랫폼 어휘가 Zig 코드에 들어왔다: {s} in {s}\n", .{ needle, path });
            return error.TestUnexpectedResult;
        }
    }

    // 그리고 **뜻을 담은 계약은 실제로 있다** — 위 단언이 "파일이 없어서" 통과하는 상태를 막는다.
    const contract = try readZigFileZ(allocator, "src/chrome/ui/semantics.zig");
    defer allocator.free(contract);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(contract, "pub const Role = enum {"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(contract, "pub const Semantics = struct {"));
}

// 스크롤 목록을 그리는 host 는 **글자를 자를 뷰포트를 컴포넌트에서 받는다**.
//
// measured chrome 글자는 tree 의 `effective_clip` 이 안 자른다(그건 quad 만 자른다 —
// `docs/scroll-area.md` §5.1). 자르는 것은 host 가 `collectMeasuredTextFromCache` 에 넘긴
// 사각형 하나뿐이고, 그 산출은 컴포넌트가 소유한다(`…build.scrollTextViewport`).
//
// 2026-08-25 이전에는 셋 중 **agent 도크만** 그 값을 넘겼다. SCM·파일 트리는 넘기지 않아 반쯤
// 스크롤된 첫 행의 라벨이 목록 위 고정 chrome 위에 그려졌고, 그 상태를 아무 판정자도 말하지
// 않았다(그 자리를 보던 골든은 crop 이 quad 를 잡고 있어 초록이었다). 인자를 필수로 만들어
// **잊는 것**은 막았지만, `null` 을 고르는 것은 여전히 컴파일된다 — 이 게이트가 그쪽을 본다.
//
// 새 도크를 더하면 여기서 실패한다. 그때 할 일은 목록에 파일을 더하는 것이거나(스크롤 목록이면),
// 왜 뷰포트가 없어도 되는지를 적는 것이다(고정 밴드면 — 사이드바 검색 줄이 그런 경우다).
test "스크롤 목록 host 는 글자 뷰포트를 컴포넌트에서 받아 넘긴다" {
    const allocator = std.testing.allocator;

    // 스크롤 목록을 그리는 도크 셋. 각자 자기 컴포넌트의 헬퍼를 부르고, 그 값을 수집 함수에 넘긴다.
    const docks = [_][]const u8{
        "src/platform/macos/app_session/scm_dock.zig",
        "src/platform/macos/app_session/file_tree_dock.zig",
        "src/platform/macos/app_session/agent_dock.zig",
    };
    for (docks) |path| {
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        // 산출을 host 가 다시 쓰지 않는다 — 컴포넌트 헬퍼를 부른다.
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "build.scrollTextViewport("));
        // 그 값을 실제로 넘긴다. `null` 을 넘기면 이 이름이 안 보여 실패한다.
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "collectMeasuredTextFromCache("));
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "scroll_clip,"));
    }

    // **소비처 전수.** 위 셋 말고 이 함수를 부르는 곳은 사이드바 검색 줄 둘뿐이고, 그 둘은 고정
    // 밴드라 뷰포트가 없다(`null` 을 명시한다). 새 소비처가 생기면 여기서 실패해 사람이 어느 쪽인지
    // 정하게 된다.
    const fixed_band = [_][]const u8{
        "src/platform/macos/app_session/pane.zig",
        "src/platform/macos/app_session/sidebar.zig",
    };
    for (fixed_band) |path| {
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, "collectMeasuredTextFromCache(collected, dl, cache, builder, null,"));
    }

    // 그리고 **그 다섯 말고는 없다.** 수집 함수 자신이 사는 파일만 정의를 들고 있다.
    const owner = try readZigFileZ(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(owner);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(owner, "pub fn collectMeasuredTextFromCache("));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(owner, "self.collectMeasuredTextFromCache("));
}

test "f3c1 semantic producer remains private with one f3d product callsite" {
    const allocator = std.testing.allocator;
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);
    const product = betweenMarkers(
        pump,
        "const ControlSemanticPreparationResult = enum {",
        "const F3c1FailAllocator = struct {",
    ) orelse return error.TestUnexpectedResult;
    // F3d adds exactly one product orchestration call beside the private declaration.
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(product, "prepareCompletedControlSemanticUnderHeldLease("),
    );
}

test "f3c1 terminal binding and consumer remain private with one f3d product callsite" {
    const allocator = std.testing.allocator;
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);
    const product = betweenMarkers(
        pump,
        "const ControlSemanticPreparationResult = enum {",
        "const F3c1FailAllocator = struct {",
    ) orelse return error.TestUnexpectedResult;
    // Each private entry occurs once as its declaration and once in F3d orchestration.
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(product, "prepareControlSemanticTerminalBindingUnderHeldLease("),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        countOccurrences(product, "consumeControlSemanticTerminalUnderHeldLease("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(product, "const PreparedControlSemanticTerminalBinding = struct"),
    );
    // The shared payload cleanup leaf has one declaration and three direct product callers:
    // terminal binding, legacy F2, and F3 revoke. Resize/resync semantic take first moves the
    // payload into its callback-local frozen owner, so it intentionally has no direct call here.
    // F3d must reuse these enclosing consumers rather than add another direct cleanup call.
    try std.testing.expectEqual(
        @as(usize, 4),
        countOccurrences(product, "finishControlResponsePayloadCleanupUnchecked("),
    );
    const binding_prepare = betweenMarkers(
        product,
        "fn prepareControlSemanticTerminalBindingUnderHeldLease(",
        "fn preparedControlSemanticTerminalBindingCurrent(",
    ) orelse return error.TestUnexpectedResult;
    const terminal_consumer = betweenMarkers(
        product,
        "fn consumeControlSemanticTerminalUnderHeldLease(",
        "fn prepareControlResponseTake(",
    ) orelse return error.TestUnexpectedResult;
    // Binding seals existing owners only. It must not grow a second decoder, payload owner,
    // cleanup implementation, or state machine beside the F3c0/F2 single sources.
    for ([_][]const u8{ binding_prepare, terminal_consumer }) |slice| {
        try std.testing.expect(std.mem.indexOf(u8, slice, "decodeResizeResponse") == null);
        try std.testing.expect(std.mem.indexOf(u8, slice, "decodeResyncResponse") == null);
        try std.testing.expect(std.mem.indexOf(u8, slice, "OwnedPayload") == null);
        try std.testing.expect(std.mem.indexOf(u8, slice, ".deinit(") == null);
    }
}

test "session host has zero raw untyped Client invalidation callsites" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var client_source: ?[:0]u8 = null;
    defer if (client_source) |source| allocator.free(source);

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/platform/macos/session_host/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer if (!std.mem.eql(u8, entry.path, "client.zig")) allocator.free(source);
        try std.testing.expect(std.mem.indexOf(u8, source, ".failClosed(") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, ".invalidateConnection(") == null);
        try std.testing.expect(std.mem.indexOf(u8, source, ".invalidateConnectionWithOps(") == null);
        if (std.mem.eql(u8, entry.path, "client.zig")) {
            client_source = source;
        } else if (std.mem.eql(u8, entry.path, "client_slot.zig")) {
            const confirmed = betweenMarkers(
                source,
                "pub fn poisonGenerationConnection(",
                "fn reasonProjection(",
            ) orelse return error.TestUnexpectedResult;
            try std.testing.expectEqual(@as(usize, 8), countFieldAssignments(source, "unusable"));
            try std.testing.expectEqual(@as(usize, 4), countFieldAssignments(source, "first_poison_reason"));
            const confirmed_z = try allocator.dupeZ(u8, confirmed);
            defer allocator.free(confirmed_z);
            try std.testing.expectEqual(@as(usize, 1), countFieldAssignments(confirmed_z, "unusable"));
            try std.testing.expectEqual(@as(usize, 1), countFieldAssignments(confirmed_z, "first_poison_reason"));
            const effect_executor = betweenMarkers(
                source,
                "fn executeCanonicalEffectPlanNoFail(",
                "fn effectProofLoss() noreturn",
            ) orelse return error.TestUnexpectedResult;
            const effect_executor_z = try allocator.dupeZ(u8, effect_executor);
            defer allocator.free(effect_executor_z);
            try std.testing.expectEqual(@as(usize, 2), countFieldAssignments(effect_executor_z, "unusable"));
            try std.testing.expectEqual(@as(usize, 1), countFieldAssignments(effect_executor_z, "first_poison_reason"));
            const incident_suffix = betweenMarkers(
                source,
                "pub fn commitFirstIncidentClientPublicationNoFail(",
                "pub fn finishIncidentClientOperationNoFail(",
            ) orelse return error.TestUnexpectedResult;
            const incident_suffix_z = try allocator.dupeZ(u8, incident_suffix);
            defer allocator.free(incident_suffix_z);
            try std.testing.expectEqual(@as(usize, 1), countFieldAssignments(incident_suffix_z, "first_poison_reason"));
            const retirement_cleanup_suffix = betweenMarkers(
                source,
                "pub fn commitRetirementCleanupNoFail(",
                "pub fn finishRetirementCleanup(",
            ) orelse return error.TestUnexpectedResult;
            const retirement_cleanup_suffix_z = try allocator.dupeZ(u8, retirement_cleanup_suffix);
            defer allocator.free(retirement_cleanup_suffix_z);
            try std.testing.expectEqual(@as(usize, 1), countFieldAssignments(retirement_cleanup_suffix_z, "unusable"));
            try std.testing.expectEqual(@as(usize, 0), countFieldAssignments(retirement_cleanup_suffix_z, "first_poison_reason"));
        } else if (std.mem.eql(u8, entry.path, "generation_attachment.zig")) {
            const testing_facade = betweenMarkers(
                source,
                "pub const testing_api = if (builtin.is_test) struct {",
                "} else struct {};",
            ) orelse return error.TestUnexpectedResult;
            const testing_facade_z = try allocator.dupeZ(u8, testing_facade);
            defer allocator.free(testing_facade_z);
            const product_prefix_z = try allocator.dupeZ(
                u8,
                source[0 .. @intFromPtr(testing_facade.ptr) - @intFromPtr(source.ptr)],
            );
            defer allocator.free(product_prefix_z);
            try std.testing.expectEqual(@as(usize, 1), countFieldAssignments(testing_facade_z, "unusable"));
            try std.testing.expectEqual(@as(usize, 1), countFieldAssignments(source, "unusable"));
            try std.testing.expectEqual(@as(usize, 0), countFieldAssignments(product_prefix_z, "unusable"));
        } else {
            try std.testing.expectEqual(
                @as(usize, 0),
                countFieldAssignments(source, "unusable"),
            );
            try std.testing.expectEqual(
                @as(usize, 0),
                countFieldAssignments(source, "first_poison_reason"),
            );
        }
    }
    const source = client_source orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 6), countFieldAssignments(source, "unusable"));
    const allowed = [_][]const u8{
        betweenMarkers(source, "fn externalAdoptionSnapshot(", "fn externalAdoptionSnapshotForProof(") orelse return error.TestUnexpectedResult,
        betweenMarkers(source, "pub fn commitExternalPumpTransfer(", "/// Runs only after Client and metadata evidence") orelse return error.TestUnexpectedResult,
        betweenMarkers(source, "pub fn moveToGenerationNode(", "/// Deep snapshot of the descriptors") orelse return error.TestUnexpectedResult,
        betweenMarkers(source, "fn poisonAndTakeFd(", "fn latchFirstPoisonReason(") orelse return error.TestUnexpectedResult,
        betweenMarkers(source, "fn markPoisonedForDeferredCleanup(", "pub fn terminalReasonInvariant(") orelse return error.TestUnexpectedResult,
        betweenMarkers(source, "test \"client source seal binds explicit schema descriptors", "test \"external source fold keeps seed tags") orelse return error.TestUnexpectedResult,
    };
    for (allowed) |slice|
        try std.testing.expectEqual(@as(usize, 1), countOccurrences(slice, ".unusable ="));

    // The first-fatal latch is immutable in product code. The other five assignments are an
    // ownership snapshot and four deliberately scoped mutation tests; adding or moving any direct
    // assignment must update this inventory instead of silently bypassing poison(reason).
    try std.testing.expectEqual(
        @as(usize, 6),
        countFieldAssignments(source, "first_poison_reason"),
    );
    const reason_assignment_owners = [_][]const u8{
        betweenMarkers(source, "fn externalAdoptionSnapshot(", "fn externalAdoptionSnapshotForProof(") orelse return error.TestUnexpectedResult,
        betweenMarkers(source, "fn latchFirstPoisonReason(", "fn markPoisonedForDeferredCleanup(") orelse return error.TestUnexpectedResult,
        betweenMarkers(source, "test \"client source seal binds explicit schema descriptors and ordered payload bytes\"", "test \"external source fold keeps seed tags and scans terminal FIFO tails\"") orelse return error.TestUnexpectedResult,
        betweenMarkers(source, "test \"client poison reason participates in projection authority", "test \"external transfer normalize quarantine") orelse return error.TestUnexpectedResult,
    };
    for (reason_assignment_owners, 0..) |slice, index| {
        const sentinel_slice = try allocator.dupeZ(u8, slice);
        defer allocator.free(sentinel_slice);
        try std.testing.expectEqual(
            @as(usize, if (index == 2) 3 else 1),
            countFieldAssignments(sentinel_slice, "first_poison_reason"),
        );
    }
}

test "2c3b executed response owner seal mutation stays in its canonical boundary" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src/platform/macos/session_host",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    var init_in_owner: usize = 0;
    var init_in_registry_fixture: usize = 0;
    var terminalize_in_owner: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/platform/macos/session_host/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        const init_count = countOccurrences(source, "ExecutedResponseOwnerSeal.initInPlace(");
        const terminalize_count = countOccurrences(
            source,
            "                owner_seal.terminalize(",
        );
        if (std.mem.eql(u8, entry.path, "executed_response.zig")) {
            init_in_owner = init_count;
            terminalize_in_owner = terminalize_count;
        } else if (std.mem.eql(u8, entry.path, "attachment_cleanup_registry.zig")) {
            init_in_registry_fixture = init_count;
            try std.testing.expectEqual(@as(usize, 0), terminalize_count);
        } else {
            try std.testing.expectEqual(@as(usize, 0), init_count);
            try std.testing.expectEqual(@as(usize, 0), terminalize_count);
        }
    }
    // The registry occurrence is a top-level integration fixture. Production mutation remains
    // inside ExecutedResponse so callers cannot synthesize or retire response authority.
    try std.testing.expectEqual(@as(usize, 2), init_in_owner);
    try std.testing.expectEqual(@as(usize, 1), init_in_registry_fixture);
    try std.testing.expectEqual(@as(usize, 2), terminalize_in_owner);
}

test "CR3a-2b2 generation GUI batch path is node-bound while legacy fallback stays explicit" {
    const allocator = std.testing.allocator;
    const runtime = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const attachment = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/generation_attachment.zig",
    );
    defer allocator.free(attachment);
    const remote = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_attachment.zig",
    );
    defer allocator.free(remote);
    const adapter = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/generation_batch_adapter.zig",
    );
    defer allocator.free(adapter);
    const host_adapter = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/host_adapter.zig",
    );
    defer allocator.free(host_adapter);
    const slot = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_slot.zig",
    );
    defer allocator.free(slot);

    // Legacy GUI fallback은 raw Client transport 한 곳만 유지한다. Generation commit은 이
    // transport를 인자로 받거나 fallback으로 되찾을 수 없다.
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(runtime, "attachmentTransport(self.legacyConnection())"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(attachment, "legacy_batch_transport"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(attachment, "batch_adapter:"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(attachment, ".reserveGenerationBatchAdapter("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(host_adapter, "GenerationBatchAdapter.initReservedInPlace("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(attachment, ".mintGenerationBatchAdapter("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(remote, "generation: generation_batch_registry.Token"),
    );

    // Inline adapter는 닫힌 leaf다. sealed ClientSlot 주소만 내부에 보존하고 raw
    // Client/HostAdapter capability를 노출하거나 canonical stream drop을 중복하지 않는다.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(adapter, "slot_addr: usize = 0"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(adapter, "*client_mod.Client"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(adapter, "*host_adapter_mod.HostAdapter"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(adapter, ".dropBufferedStream("));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(adapter, ".readGenerationBatch("));

    // Raw Client ownership은 exact node owner 뒤에만 남고 sibling adapter는 이를 우회하지 못한다.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(slot, ".readGenerationBatch("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(slot, ".dropBufferedStream("));
    // Initial snapshot과 ended-event queue 정리는 2c의 명시적 raw Client allowlist다.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(runtime, "self.legacyConnection().readSnapshot("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(runtime, "self.legacyConnection().dropBufferedStream("));
}

test "CR3a-2c1 initial snapshot ownership stays final-address and generation-bound" {
    const allocator = std.testing.allocator;
    const runtime = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const transport = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/generation_transport.zig",
    );
    defer allocator.free(transport);
    const owner = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/initial_snapshot_owner.zig",
    );
    defer allocator.free(owner);
    const slot = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_slot.zig",
    );
    defer allocator.free(slot);
    const owner_type = betweenMarkers(
        owner,
        "pub const InitialSnapshotOwner = struct {",
        "\nfn currentPid()",
    ) orelse return error.TestUnexpectedResult;
    const transport_product = if (std.mem.indexOf(u8, transport, "\ntest \"")) |index| transport[0..index] else return error.TestUnexpectedResult;

    // Generation initial snapshot은 raw Client 호출이나 bare slice 반환이 아니라 exact
    // final-address owner를 통해서만 제품 attach stack에 도달한다.
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(runtime, "self.legacyConnection().readSnapshot("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_product, "pub fn readInitialSnapshot("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_product, ".readInitialSnapshotGuarded("));
    try std.testing.expectEqual(
        @as(usize, 1),
        countIdentifierOutsideTopLevelTests(slot, "readSnapshot"),
    );
    // Existing-generation attach와 CR4a final candidate가 각각 같은 guarded snapshot leaf를 쓴다.
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(runtime, ".readInitialSnapshot("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(owner_type, "self_addr: usize = 0"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(owner_type, "actual_allocator:"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(owner_type, "transport_incarnation: u64 = 0"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(owner_type, "stream_id: u64 = 0"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(owner_type, "binding_incarnation: u64 = 0"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(owner_type, "binding_storage_addr: usize = 0"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(owner_type, "binding_destination_addr: usize = 0"));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(owner_type, "binding_reservation_id: u64 = 0"));
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(
            owner_type,
            "canonical_permit: client_slot_mod.InitialSnapshotPermit = undefined",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_product, "InitialSnapshotOwner.initInPlace("));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(runtime, "InitialSnapshotOwner.initInPlace("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_product, ".prepareInitialSnapshotPermit("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(transport_product, ".abortInitialSnapshotPermit("));
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(owner, ".consumeInitialSnapshotPermit("));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(owner, "*client_mod.Client"));

    // Batch registry와 ended purge는 각각 2b2와 2c2의 별도 권위다.
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(transport, "readAttachmentBatch("));
    try std.testing.expectEqual(
        @as(usize, 0),
        countIdentifierOutsideTopLevelTests(transport, "dropBufferedStream"),
    );
}

test "CR3a-1 ownership capabilities stay in their exact production boundaries" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);

        const is_client_slot = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_slot.zig",
        );
        const is_lease_module = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/connection_lease.zig",
        );
        const is_host_adapter = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/host_adapter.zig",
        );
        const is_generation_attachment = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/generation_attachment.zig",
        );
        const is_generation_transport = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/generation_transport.zig",
        );
        const is_generation_event_contract = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/generation_event_contract.zig",
        );
        const is_remote_attachment = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/remote_attachment.zig",
        );
        // Count the filename rather than one relative spelling so imports from anywhere under
        // `src/` cannot bypass the product-wide mint/consume-zero gate with a longer path.
        const imports_lease = countStringLiteralOutsideTopLevelTests(source, "connection_lease.zig");
        try std.testing.expectEqual(
            @as(usize, if (is_client_slot or is_host_adapter or is_generation_attachment or
                is_generation_event_contract) 1 else 0),
            imports_lease,
        );
        const lease_type_count = countIdentifierOutsideTopLevelTests(source, "ConnectionLease");
        if (is_lease_module) {
            // The defining module necessarily names the type in its methods.  Its exact internal
            // count is not an architecture boundary; only production references outside the
            // defining module are forbidden until CR3a-2 wires the compatibility adapter.
            try std.testing.expect(lease_type_count > 0);
        } else {
            // CR3a-2a stores the lease only in the final-address GUI attachment, while HostAdapter
            // forwards its exact address to ClientSlot. ClientSlot additionally names the type in
            // the ended-purge destination range preflight. 2c3d C1 adds two event-owner range
            // checks and C2 adds one trusted-mirror pointer reconstruction for prepared normal
            // release; it still does not store or mint another lease. Transport and external
            // movable owners may not name the cleanup capability. C3-3a3 adds one exact
            // event-lease destination range to the activation transaction preflight. CR5 adds one
            // ClientSlot preflight signature and one HostAdapter forwarding signature for the
            // host-wide attachment-drop preflight.
            const expected_lease_count: usize = if (is_client_slot)
                18
            else if (is_host_adapter)
                5
            else if (is_generation_attachment)
                1
            else if (is_generation_event_contract)
                2
            else
                0;
            try std.testing.expectEqual(
                expected_lease_count,
                lease_type_count,
            );
        }
        const move_count = countIdentifierOutsideTopLevelTests(source, "moveToGenerationNode");
        const expected_move_count: usize = if (is_client_slot)
            // Initial node, ordinary replacement, and CR5b reserved replacement publication.
            3
        else if (std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client.zig",
        )) 1 else 0;
        try std.testing.expectEqual(expected_move_count, move_count);
        if (!is_client_slot)
            try std.testing.expectEqual(
                @as(usize, 0),
                countIdentifierOutsideTopLevelTests(source, "slot.current"),
            );
        try std.testing.expectEqual(
            // GenerationAttachment는 일반 payload teardown, terminal handoff, CR5b host-wide
            // prepare와 no-fail commit에서 source-zero를 각각 확인한다.
            @as(usize, if (is_remote_attachment) 1 else if (is_generation_attachment) 4 else 0),
            countIdentifierOutsideTopLevelTests(source, "deinitPayloadOnly"),
        );
        try std.testing.expectEqual(
            // b2b3's canonical real-take harness owns one additional test-only terminalization.
            @as(usize, if (is_generation_transport) 6 else if (is_generation_attachment) 1 else 0),
            countIdentifierOutsideTopLevelTests(source, "terminalizeOwned"),
        );
        if (is_generation_transport) {
            // Three lexical terminalize calls and the B3-6 helper references are confined to
            // private test harnesses; the public facade/product callsite remains unchanged.
            try std.testing.expectEqual(
                @as(usize, 4),
                countIdentifierOutsideTopLevelTests(source, "B3ExecutionHarness"),
            );
        }
        const owned_helpers = [_]struct {
            name: []const u8,
            transport_count: usize,
            attachment_count: usize = 1,
        }{
            // 기존 fixture 네 곳과 C1 actual-socket fixture 한 곳만 attachment 결속을 연다.
            .{ .name = "bindCommittedStreamOwned", .transport_count = 5 },
            // 기존 fallible revoke와 b4의 이미 확정된 effect suffix가 같은 권위를 한 번씩 연다.
            .{ .name = "beginControllerRevokeOwned", .transport_count = 1, .attachment_count = 2 },
            .{ .name = "finishControllerRevokeOwned", .transport_count = 1, .attachment_count = 2 },
            .{ .name = "mutationAllowedOwned", .transport_count = 1 },
            .{ .name = "bufferedControllerRevokeOwned", .transport_count = 1 },
            // 기존 두 제품 경로, CR4b test-only readiness와 CR5 host-wide retirement가 preflight한다.
            .{ .name = "preflightTerminalizeOwned", .transport_count = 3, .attachment_count = 4 },
        };
        for (owned_helpers) |helper| {
            const expected: usize = if (is_generation_transport)
                helper.transport_count
            else if (is_generation_attachment)
                helper.attachment_count
            else
                0;
            try std.testing.expectEqual(
                expected,
                countIdentifierOutsideTopLevelTests(source, helper.name),
            );
        }
    }

    const app = try readZigFileZ(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const backend = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_term_backend.zig",
    );
    defer allocator.free(backend);
    const runtime = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const pump = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/client_external_pump.zig",
    );
    defer allocator.free(pump);
    const pool = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/host_pool.zig",
    );
    defer allocator.free(pool);

    // 두 제품 caller는 managed publication으로 전환했고 singleton rollback fixture 3개, C3-3b6 fixture 2개,
    // bootstrap5 owned-pool settlement fixture 1개만 legacy init을 쓴다.
    try std.testing.expectEqual(
        @as(usize, 6),
        countOccurrences(app, "RemoteSessionAdapter.initInPlace("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(app, "RemoteSessionAdapter.initManagedInPlace("),
    );
    // R1은 pooled adapter의 raw Client escape 두 곳을 closed HostAdapter operation으로 치환한다.
    try std.testing.expectEqual(
        @as(usize, 0),
        countIdentifierOutsideTopLevelTests(backend, "logicalClient"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(backend, "try rr.spawnWithAdapter("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(backend, "try rr.spawnWithAdapterAndNotification("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(backend, "try rr.attachExistingWithAdapter("),
    );
    // CR2e-e2a는 제품 current를 piecewise overwrite하지 않고 InitialRemoteGenerationArgs를
    // GenerationSlot initializer에 넘긴다. 제품/테스트 선언 7개와 canonical projection 2개만 허용한다.
    try std.testing.expectEqual(@as(usize, 7), countOccurrences(runtime, "connection: RuntimeConnection,"));
    try std.testing.expectEqual(@as(usize, 0), countOccurrences(runtime, "        self.currentGeneration().connection = connection;"));
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(runtime, "                .connection = connection,"));
    // CR3a-2c3a moves generation input/revoke/output-progress behind RuntimeAttachment's closed
    // switch. The one raw call per primitive is the explicit legacy arm; product methods must not
    // regain a direct self.client call while RemoteRuntime.client still exists for 2c4.
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(runtime, "self.client.sendInput("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(runtime, "self.client.sendInputNonBlocking("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(runtime, "self.client.pumpPendingOutput("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(runtime, "self.client.fenceRevokedStream("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(runtime, "self.client.hasBufferedControllerRevoke("),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        countOccurrences(runtime, "self.client.hasBufferedControllerRevokeForStream("),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(runtime, "client.sendInput(value.streamId(), bytes)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(runtime, "client.sendInputNonBlocking(value.streamId(), bytes)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(runtime, ".legacy => (client orelse return error.ProtocolError).pumpPendingOutput(),"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(runtime, "(client orelse return error.ProtocolError).fenceRevokedStream(value.streamId())"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(runtime, ".legacy => client.hasBufferedControllerRevoke(),"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(runtime, "        .context = client,"),
    );
    try std.testing.expectEqual(
        @as(usize, 3),
        countOccurrences(
            runtime,
            "const client: *client_mod.Client = @ptrCast(@alignCast(context));",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        countOccurrences(pump, "    owned_client: ?client_mod.Client = null,"),
    );
    try std.testing.expectEqual(@as(usize, 2), countOccurrences(pool, "adapter.deinit();"));
}

fn countIdentifierOutsideTopLevelTests(source: [:0]const u8, wanted: []const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var count: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return count,
            .keyword_test => if (brace_depth == 0 and test_body_depth == null) {
                waiting_for_test_body = true;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                }
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth)
                    test_body_depth = null;
                if (brace_depth > 0) brace_depth -= 1;
            },
            .identifier => if (test_body_depth == null and
                std.mem.eql(u8, source[token.loc.start..token.loc.end], wanted))
            {
                count += 1;
            },
            else => {},
        }
    }
}

fn countStringLiteralOutsideTopLevelTests(source: [:0]const u8, wanted: []const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var count: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return count,
            .keyword_test => if (brace_depth == 0 and test_body_depth == null) {
                waiting_for_test_body = true;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                }
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth)
                    test_body_depth = null;
                if (brace_depth > 0) brace_depth -= 1;
            },
            .string_literal => if (test_body_depth == null and
                std.mem.indexOf(u8, source[token.loc.start..token.loc.end], wanted) != null)
            {
                count += 1;
            },
            else => {},
        }
    }
}

fn countFieldAssignments(source: [:0]const u8, field_name: []const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var state: enum { start, period, field } = .start;
    var count: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return count;
        const text = source[token.loc.start..token.loc.end];
        switch (state) {
            .start => {
                if (std.mem.eql(u8, text, ".")) state = .period;
            },
            .period => {
                if (std.mem.eql(u8, text, field_name))
                    state = .field
                else
                    state = if (std.mem.eql(u8, text, ".")) .period else .start;
            },
            .field => {
                if (std.mem.eql(u8, text, "=")) count += 1;
                state = if (std.mem.eql(u8, text, ".")) .period else .start;
            },
        }
    }
}

fn containsForbiddenExternalBuiltin(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .keyword_extern, .keyword_asm => return true,
            .builtin => {
                const builtin_name = source[token.loc.start..token.loc.end];
                if (std.mem.eql(u8, builtin_name, "@cImport") or
                    std.mem.eql(u8, builtin_name, "@cInclude") or
                    std.mem.eql(u8, builtin_name, "@embedFile") or
                    std.mem.eql(u8, builtin_name, "@extern"))
                    return true;
            },
            else => {},
        }
    }
}

test "session host external pump facade callsites stay in the final owner boundary" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const allowed = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        ) or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_pump_owner.zig",
        ) or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_attach_evidence.zig",
        ) or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_rx_read_test_support.zig",
        ) or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_tx.zig",
        );
        if (allowed) continue;
        const path = try std.fmt.allocPrint(
            allocator,
            "src/{s}",
            .{entry.path},
        );
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        try std.testing.expect(!containsFacadeAccess(source));
    }

    const forbidden_identifier: [:0]const u8 =
        \\const Leak = module.ExternalPumpFacade;
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_identifier));
    const forbidden_field: [:0]const u8 =
        \\const Leak = @field(module, "ExternalPumpFacade");
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_field));
    const forbidden_import: [:0]const u8 =
        \\const pump = @import("platform/macos/session_host/client_external_pump.zig");
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_import));
    const forbidden_computed: [:0]const u8 =
        \\const pump = @import("platform/macos/session_host/" ++ "client_" ++ "external_" ++ "pump." ++ "zig");
        \\const Leak = @field(pump, "External" ++ "Pump" ++ "Facade");
    ;
    try std.testing.expect(containsFacadeAccess(forbidden_computed));
}

test "session host stable pump storage and Client transfer stay in mechanics boundary" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(
        std.testing.io,
        "src",
        .{ .iterate = true },
    );
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const mechanics_file = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        );
        const framing_file = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/framing.zig",
        );
        const rx_parser_transaction_file = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_mode.zig",
        ) or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_rx_turn_test_support.zig",
        );
        const storage_type_allowed = mechanics_file or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_pump_owner.zig",
        );
        const transfer_allowed = mechanics_file or std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client.zig",
        );
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        try std.testing.expect(!containsRestrictedName(source, "transferToExternalPump"));
        if (containsRestrictedName(source, "initFromAttachPartsInPlace")) {
            try std.testing.expect(mechanics_file or std.mem.eql(
                u8,
                entry.path,
                "platform/macos/session_host/external_attach_evidence.zig",
            ));
        }
        if (!mechanics_file) {
            try std.testing.expect(!containsRestrictedName(source, "cleanup_seed"));
            try std.testing.expect(!containsRestrictedName(source, "cleanup_seed_seal"));
        }
        if (!framing_file and !rx_parser_transaction_file) {
            try std.testing.expect(!containsRestrictedName(source, "cleanup_replacement"));
            try std.testing.expect(!containsRestrictedName(source, "normalize_cleanup_allocator"));
        }
        if (mechanics_file) continue;
        if (!storage_type_allowed)
            try std.testing.expect(!containsRestrictedName(source, "ExternalPumpStorage"));
        if (!mechanics_file) {
            try std.testing.expect(!containsRestrictedName(source, "owned_client"));
            try std.testing.expect(!containsRestrictedName(source, "inbox_ledger"));
            // The paired suffix's only seed owner until c3c. Raw access outside mechanics could
            // free the seed behind the cleanup mirror's back.
            try std.testing.expect(!containsRestrictedName(source, "owned_evidence"));
        }
        if (!transfer_allowed) {
            try std.testing.expect(!containsRestrictedName(source, "prepareExternalPumpTransfer"));
            try std.testing.expect(!containsRestrictedName(source, "commitExternalPumpTransfer"));
            // All three stages are gated, not just the two that move ownership: calling `finish`
            // out of order panics instead of returning a typed error.
            try std.testing.expect(!containsRestrictedName(source, "finishExternalPumpTransfer"));
            try std.testing.expect(!containsRestrictedName(
                source,
                "PreparedExternalOwnerRangeProof",
            ));
            try std.testing.expect(!containsRestrictedName(
                source,
                "prepareExternalOwnerRangeProof",
            ));
        }
        if (!framing_file and !transfer_allowed and !rx_parser_transaction_file) {
            // The staged parser swap is a mechanics-only leaf for the same reason: its misuse paths
            // are `@panic`, so the compiler cannot keep a new caller honest. `client.zig` owns the
            // three transfer stages that drive it.
            try std.testing.expect(!containsRestrictedName(source, "prepareNormalizeExact"));
            try std.testing.expect(!containsRestrictedName(source, "commitPreparedNormalizeExact"));
            try std.testing.expect(!containsRestrictedName(source, "rebindPreparedNormalizeExact"));
        }
    }

    const forbidden_storage: [:0]const u8 =
        \\const storage: ExternalPumpStorage = .{};
        \\const raw = &storage.inbox_ledger;
    ;
    try std.testing.expect(containsExactIdentifier(forbidden_storage, "ExternalPumpStorage"));
    try std.testing.expect(containsExactIdentifier(forbidden_storage, "inbox_ledger"));
    const forbidden_computed_storage: [:0]const u8 =
        \\const raw = &@field(storage, "inbox_" ++ "ledger");
        \\const copied = @field(module, "External" ++ "PumpStorage");
    ;
    try std.testing.expect(containsRestrictedName(
        forbidden_computed_storage,
        "inbox_ledger",
    ));
    try std.testing.expect(containsRestrictedName(
        forbidden_computed_storage,
        "ExternalPumpStorage",
    ));
    const forbidden_transfer: [:0]const u8 =
        \\try client.transferToExternalPump(&slot, cap);
        \\const transfer = @field(client, "transfer" ++ "ToExternalPump");
    ;
    try std.testing.expect(containsRestrictedName(
        forbidden_transfer,
        "transferToExternalPump",
    ));
}

test "session host external adoption import direction and mechanics stay closed" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const is_client = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client.zig",
        );
        const is_adoption = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_adoption.zig",
        );
        const is_pump = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/client_external_pump.zig",
        );
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);

        if (!is_pump)
            try std.testing.expect(!joinedStringLiteralsContain(
                source,
                "client_external_adoption.zig",
            ));
        if (is_client or is_adoption)
            try std.testing.expect(!joinedStringLiteralsContain(
                source,
                "client_external_pump.zig",
            ));
        if (!is_adoption and !is_pump)
            try std.testing.expect(!containsRestrictedName(source, "PreparedScreenBacklog"));
        if (!is_client and !is_adoption)
            try std.testing.expect(!containsRestrictedName(source, "PreparedClientDisarm"));
    }
}

test "session host external source decision stays outside pump and owning materialization" {
    const allocator = std.testing.allocator;
    const source = try readZigFileZ(
        allocator,
        "src/platform/macos/session_host/external_source_decision.zig",
    );
    defer allocator.free(source);

    try std.testing.expect(!joinedStringLiteralsContain(
        source,
        "client_external_pump.zig",
    ));
    try std.testing.expect(!joinedStringLiteralsContain(
        source,
        "client_external_adoption.zig",
    ));
    try std.testing.expect(!joinedStringLiteralsContain(
        source,
        "runtime_metadata_wire.zig",
    ));
    try std.testing.expect(!joinedStringLiteralsContain(
        source,
        "external_inbox_ledger.zig",
    ));
    try std.testing.expect(!joinedStringLiteralsContain(
        source,
        "std.mem.Allocator",
    ));
}

test "session host prepared metadata mechanics stay inside their final-address owner" {
    const allocator = std.testing.allocator;
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const is_owner = std.mem.eql(
            u8,
            entry.path,
            "platform/macos/session_host/external_event_materialization.zig",
        );
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        if (!is_owner)
            try std.testing.expect(!containsRestrictedName(
                source,
                "PreparedOwnedMetadata",
            ));
    }
}

fn containsExactIdentifier(source: [:0]const u8, expected: []const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .identifier => if (std.mem.eql(
                u8,
                source[token.loc.start..token.loc.end],
                expected,
            )) return true,
            else => {},
        }
    }
}

fn containsRestrictedName(source: [:0]const u8, expected: []const u8) bool {
    return containsExactIdentifier(source, expected) or
        joinedStringLiteralsEqual(source, expected);
}

fn joinedStringLiteralsEqual(source: [:0]const u8, expected: []const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var joined: [128]u8 = undefined;
    var joined_len: usize = 0;
    var have_literal = false;
    var expect_literal = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .string_literal => {
                if (!expect_literal) joined_len = 0;
                const literal = source[token.loc.start + 1 .. token.loc.end - 1];
                if (joined_len + literal.len > joined.len) {
                    joined_len = 0;
                    have_literal = false;
                    expect_literal = false;
                    continue;
                }
                @memcpy(joined[joined_len..][0..literal.len], literal);
                joined_len += literal.len;
                have_literal = true;
                expect_literal = false;
            },
            .plus_plus => {
                if (have_literal and !expect_literal) {
                    expect_literal = true;
                } else {
                    joined_len = 0;
                    have_literal = false;
                    expect_literal = false;
                }
            },
            .eof => return have_literal and !expect_literal and
                std.mem.eql(u8, joined[0..joined_len], expected),
            else => {
                if (have_literal and !expect_literal and
                    std.mem.eql(u8, joined[0..joined_len], expected))
                    return true;
                joined_len = 0;
                have_literal = false;
                expect_literal = false;
            },
        }
    }
}

fn containsForbiddenStdChild(source: [:0]const u8) bool {
    if (!hasExactCanonicalStdImport(source)) return true;
    const allowed = [_][]const u8{ "math", "meta", "testing" };
    var tokenizer = std.zig.Tokenizer.init(source);
    const AfterStd = enum { none, declaration, selector };
    var after_std: AfterStd = .none;
    var expect_child = false;
    var previous_const = false;
    var canonical_bindings: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (after_std != .none) {
            switch (after_std) {
                .declaration => {
                    if (token.tag != .equal) return true;
                    canonical_bindings += 1;
                },
                .selector => {
                    if (token.tag != .period) return true;
                    expect_child = true;
                },
                .none => unreachable,
            }
            after_std = .none;
            previous_const = false;
            continue;
        }
        if (expect_child) {
            if (token.tag != .identifier) return true;
            const child = source[token.loc.start..token.loc.end];
            var accepted = false;
            for (allowed) |name| {
                if (std.mem.eql(u8, child, name)) {
                    accepted = true;
                    break;
                }
            }
            if (!accepted) return true;
            expect_child = false;
            previous_const = false;
            continue;
        }
        switch (token.tag) {
            .eof => return canonical_bindings != 1,
            .keyword_const => {
                previous_const = true;
            },
            .identifier => {
                const identifier = source[token.loc.start..token.loc.end];
                if (std.mem.eql(u8, identifier, "std")) {
                    after_std = if (previous_const) .declaration else .selector;
                }
                previous_const = false;
            },
            else => {
                previous_const = false;
            },
        }
    }
}

fn hasExactCanonicalStdImport(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var state: u4 = 0;
    var matches: usize = 0;
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) return matches == 1 and state == 0;
        const text = source[token.loc.start..token.loc.end];
        const matched = switch (state) {
            0 => token.tag == .keyword_const,
            1 => token.tag == .identifier and std.mem.eql(u8, text, "std"),
            2 => token.tag == .equal,
            3 => token.tag == .builtin and std.mem.eql(u8, text, "@import"),
            4 => token.tag == .l_paren,
            5 => token.tag == .string_literal and std.mem.eql(u8, text, "\"std\""),
            6 => token.tag == .r_paren,
            7 => token.tag == .semicolon,
            else => unreachable,
        };
        if (matched) {
            state += 1;
            if (state == 8) {
                matches += 1;
                state = 0;
            }
        } else {
            state = if (token.tag == .keyword_const) 1 else 0;
        }
    }
}

fn containsForbiddenPumpToken(source: [:0]const u8) bool {
    const forbidden = [_][]const u8{
        "posix",
        "c",
        "json",
        "mem",
        "Allocator",
        "FrameParser",
        "ExternalInboxLedger",
    };
    var tokenizer = std.zig.Tokenizer.init(source);
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .identifier => {
                const identifier = source[token.loc.start..token.loc.end];
                for (forbidden) |name| {
                    if (std.mem.eql(u8, identifier, name)) return true;
                }
            },
            else => {},
        }
    }
}

fn containsFacadeAccess(source: [:0]const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var saw_client_external = false;
    var saw_pump_file = false;
    var saw_external_pump = false;
    var saw_facade = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return (saw_client_external and saw_pump_file) or
                (saw_external_pump and saw_facade) or
                joinedStringLiteralsContain(source, "client_external_pump.zig") or
                joinedStringLiteralsContain(source, "ExternalPumpFacade"),
            .identifier => {
                if (std.mem.eql(
                    u8,
                    source[token.loc.start..token.loc.end],
                    "ExternalPumpFacade",
                )) return true;
            },
            .string_literal => {
                const literal = source[token.loc.start..token.loc.end];
                saw_client_external = saw_client_external or
                    std.mem.indexOf(u8, literal, "client_external_") != null;
                saw_pump_file = saw_pump_file or
                    std.mem.indexOf(u8, literal, "pump.zig") != null;
                saw_external_pump = saw_external_pump or
                    std.mem.indexOf(u8, literal, "ExternalPump") != null;
                saw_facade = saw_facade or
                    std.mem.indexOf(u8, literal, "Facade") != null;
            },
            else => {},
        }
    }
}

fn joinedStringLiteralsContain(source: [:0]const u8, needle: []const u8) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var matched: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .string_literal => {
                const literal = source[token.loc.start + 1 .. token.loc.end - 1];
                for (literal) |byte| {
                    if (byte == needle[matched]) {
                        matched += 1;
                        if (matched == needle.len) return true;
                    } else {
                        matched = if (byte == needle[0]) 1 else 0;
                    }
                }
            },
            else => {},
        }
    }
}

fn joinedStringLiteralsContainOutsideTopLevelTests(
    source: [:0]const u8,
    needle: []const u8,
) bool {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var matched: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return false,
            .keyword_test => if (brace_depth == 0 and test_body_depth == null) {
                waiting_for_test_body = true;
            },
            .l_brace => {
                brace_depth += 1;
                if (waiting_for_test_body) {
                    test_body_depth = brace_depth;
                    waiting_for_test_body = false;
                    matched = 0;
                }
            },
            .r_brace => {
                if (test_body_depth != null and test_body_depth.? == brace_depth) {
                    test_body_depth = null;
                    matched = 0;
                }
                if (brace_depth > 0) brace_depth -= 1;
            },
            .string_literal => if (test_body_depth == null) {
                const literal = source[token.loc.start + 1 .. token.loc.end - 1];
                for (literal) |byte| {
                    if (byte == needle[matched]) {
                        matched += 1;
                        if (matched == needle.len) return true;
                    } else {
                        matched = if (byte == needle[0]) 1 else 0;
                    }
                }
            },
            else => {},
        }
    }
}

const DeclarationTuple = struct {
    parent: []const u8,
    kind: []const u8,
    visibility: []const u8,
    modifier: []const u8,
    name: []const u8,
};

const DeclarationInventory = struct {
    total_count: usize,
    baseline_count: usize,
    baseline_digest: [32]u8,
};

fn declarationInventory(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    containers: []const []const u8,
    optional_containers: []const []const u8,
    allowed: []const DeclarationTuple,
) !DeclarationInventory {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), tree.errors.len);
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    var result: DeclarationInventory = .{
        .total_count = 0,
        .baseline_count = 0,
        .baseline_digest = undefined,
    };
    try hashDeclarationNodes(&tree, "root", tree.rootDecls(), allowed, &hasher, &result);
    for (containers) |container_name| {
        const members = findRootContainerMembers(&tree, container_name) orelse
            return error.TestUnexpectedResult;
        try hashDeclarationNodes(
            &tree,
            container_name,
            members,
            allowed,
            &hasher,
            &result,
        );
    }
    for (optional_containers) |container_name| {
        const members = findRootContainerMembers(&tree, container_name) orelse continue;
        try hashDeclarationNodes(
            &tree,
            container_name,
            members,
            allowed,
            &hasher,
            &result,
        );
    }
    hasher.final(&result.baseline_digest);
    return result;
}

fn hashDeclarationNodes(
    tree: *const std.zig.Ast,
    parent: []const u8,
    nodes: []const std.zig.Ast.Node.Index,
    allowed: []const DeclarationTuple,
    hasher: *std.crypto.hash.sha2.Sha256,
    result: *DeclarationInventory,
) !void {
    for (nodes) |node| {
        if (tree.nodeTag(node) == .test_decl) continue;
        const tuple = declarationTuple(tree, parent, node);
        result.total_count += 1;
        var is_allowed = false;
        for (allowed) |candidate| {
            if (declarationTupleEql(tuple, candidate)) {
                is_allowed = true;
                break;
            }
        }
        if (is_allowed) continue;
        result.baseline_count += 1;
        inline for (.{ tuple.parent, tuple.kind, tuple.visibility, tuple.modifier, tuple.name }) |part| {
            hasher.update(part);
            hasher.update(&.{0});
        }
    }
}

fn declarationTuple(
    tree: *const std.zig.Ast,
    parent: []const u8,
    node: std.zig.Ast.Node.Index,
) DeclarationTuple {
    if (tree.fullVarDecl(node)) |decl| {
        const modifier_token = decl.extern_export_token orelse
            decl.threadlocal_token orelse decl.comptime_token;
        return .{
            .parent = parent,
            .kind = tree.tokenSlice(decl.ast.mut_token),
            .visibility = if (decl.visib_token != null) "pub" else "private",
            .modifier = if (modifier_token) |token| tree.tokenSlice(token) else "",
            .name = tree.tokenSlice(decl.ast.mut_token + 1),
        };
    }
    var fn_buffer: [1]std.zig.Ast.Node.Index = undefined;
    if (tree.fullFnProto(&fn_buffer, node)) |decl| {
        const name_token = decl.name_token orelse tree.nodeMainToken(node);
        return .{
            .parent = parent,
            .kind = "fn",
            .visibility = if (decl.visib_token != null) "pub" else "private",
            .modifier = if (decl.extern_export_inline_token) |token|
                tree.tokenSlice(token)
            else
                "",
            .name = tree.tokenSlice(name_token),
        };
    }
    if (tree.fullContainerField(node)) |_| {
        return .{
            .parent = parent,
            .kind = "field",
            .visibility = "private",
            .modifier = "",
            .name = tree.tokenSlice(tree.nodeMainToken(node)),
        };
    }
    return .{
        .parent = parent,
        .kind = "node",
        .visibility = "private",
        .modifier = "",
        .name = @tagName(tree.nodeTag(node)),
    };
}

fn declarationTupleEql(a: DeclarationTuple, b: DeclarationTuple) bool {
    return std.mem.eql(u8, a.parent, b.parent) and
        std.mem.eql(u8, a.kind, b.kind) and
        std.mem.eql(u8, a.visibility, b.visibility) and
        std.mem.eql(u8, a.modifier, b.modifier) and
        std.mem.eql(u8, a.name, b.name);
}

fn findRootContainerMembers(
    tree: *const std.zig.Ast,
    wanted: []const u8,
) ?[]const std.zig.Ast.Node.Index {
    for (tree.rootDecls()) |node| {
        const variable = tree.fullVarDecl(node) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(variable.ast.mut_token + 1), wanted)) continue;
        const init = variable.ast.init_node.unwrap() orelse return null;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, init) orelse return null;
        return container.ast.members;
    }
    return null;
}

fn findRootVariableInitializer(
    tree: *const std.zig.Ast,
    wanted: []const u8,
) ?std.zig.Ast.Node.Index {
    for (tree.rootDecls()) |node| {
        const variable = tree.fullVarDecl(node) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(variable.ast.mut_token + 1), wanted)) continue;
        return variable.ast.init_node.unwrap();
    }
    return null;
}

fn inventoryCount(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    wanted: DeclarationTuple,
) !usize {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    var count: usize = 0;
    const nodes = if (std.mem.eql(u8, wanted.parent, "root"))
        tree.rootDecls()
    else
        findRootContainerMembers(&tree, wanted.parent) orelse return 0;
    for (nodes) |node| {
        if (tree.nodeTag(node) == .test_decl) continue;
        count += @intFromBool(declarationTupleEql(
            declarationTuple(&tree, wanted.parent, node),
            wanted,
        ));
    }
    return count;
}

fn expectAbsentOrExactImport(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    identifier: []const u8,
    exact_initializer: []const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    var matches: usize = 0;
    for (tree.rootDecls()) |node| {
        if (tree.nodeTag(node) == .test_decl) continue;
        const variable = tree.fullVarDecl(node) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(variable.ast.mut_token + 1), identifier)) continue;
        matches += 1;
        const init = variable.ast.init_node.unwrap() orelse return error.TestUnexpectedResult;
        const first = tree.tokenStart(tree.firstToken(init));
        const last_token = tree.lastToken(init);
        const last = tree.tokenStart(last_token) + tree.tokenSlice(last_token).len;
        try std.testing.expectEqualStrings(exact_initializer, source[first..last]);
    }
    try std.testing.expect(matches <= 1);
}

fn expectExactImport(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    identifier: []const u8,
    exact_initializer: []const u8,
) !void {
    try expectAbsentOrExactImport(allocator, source, identifier, exact_initializer);
    try std.testing.expectEqual(@as(usize, 1), countOccurrences(source, exact_initializer));
}

fn expectPublicRootDeclarationsExact(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    expected: []const DeclarationTuple,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    var found: usize = 0;
    for (tree.rootDecls()) |node| {
        if (tree.nodeTag(node) == .test_decl) continue;
        const tuple = declarationTuple(&tree, "root", node);
        if (!std.mem.eql(u8, tuple.visibility, "pub")) continue;
        var matched = false;
        for (expected) |candidate| matched = matched or declarationTupleEql(tuple, candidate);
        try std.testing.expect(matched);
        found += 1;
    }
    try std.testing.expectEqual(expected.len, found);
}

fn expectRootContainerFieldsWithOptional(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    container_name: []const u8,
    baseline: []const []const u8,
    optional_last: []const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, container_name) orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(members.len == baseline.len or members.len == baseline.len + 1);
    for (baseline, 0..) |name, index| {
        const tuple = declarationTuple(&tree, container_name, members[index]);
        try std.testing.expectEqualStrings("field", tuple.kind);
        try std.testing.expectEqualStrings(name, tuple.name);
    }
    if (members.len == baseline.len + 1) {
        const tuple = declarationTuple(&tree, container_name, members[baseline.len]);
        try std.testing.expectEqualStrings("field", tuple.kind);
        try std.testing.expectEqualStrings(optional_last, tuple.name);
    }
}

fn expectPreparedEndedPurgeCommitSchema(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "PreparedEndedPurgeCommit") orelse
        return error.TestUnexpectedResult;
    const fields = [_]struct { name: []const u8, type_name: []const u8 }{
        .{ .name = "self_addr", .type_name = "usize" },
        .{ .name = "client_addr", .type_name = "usize" },
        .{ .name = "scratch_addr", .type_name = "usize" },
        .{ .name = "inventory_addr", .type_name = "usize" },
        .{ .name = "target_stream", .type_name = "u64" },
        .{ .name = "captured_fd", .type_name = "c.fd_t" },
        .{ .name = "complete_owned_extent_bytes", .type_name = "usize" },
        .{ .name = "complete_owner_seal", .type_name = "owner_seal.Digest" },
        .{ .name = "pre_callback_survivor_seal", .type_name = "owner_seal.Digest" },
        .{ .name = "batch_plan", .type_name = "ended_purge_transaction.QueuePlan" },
        .{ .name = "stream_plan", .type_name = "ended_purge_transaction.QueuePlan" },
        .{ .name = "event_plan", .type_name = "ended_purge_transaction.QueuePlan" },
        .{ .name = "partial_plan", .type_name = "ended_purge_transaction.QueuePlan" },
        .{ .name = "batch_cleanup_ordinal", .type_name = "usize" },
        .{ .name = "stream_cleanup_ordinal", .type_name = "usize" },
        .{ .name = "event_cleanup_ordinal", .type_name = "usize" },
        .{ .name = "partial_cleanup_ordinal", .type_name = "usize" },
        .{ .name = "finalization_seal", .type_name = "owner_seal.Digest" },
        .{ .name = "lifecycle", .type_name = "Lifecycle" },
    };
    try std.testing.expectEqual(fields.len + 1, members.len);
    const lifecycle_decl = tree.fullVarDecl(members[0]) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("Lifecycle", tree.tokenSlice(lifecycle_decl.ast.mut_token + 1));
    const lifecycle_init = lifecycle_decl.ast.init_node.unwrap() orelse return error.TestUnexpectedResult;
    var lifecycle_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const lifecycle = tree.fullContainerDecl(&lifecycle_buffer, lifecycle_init) orelse
        return error.TestUnexpectedResult;
    try expectFieldNames(
        &tree,
        lifecycle.ast.members,
        &.{ "pristine", "prepared", "finalization_pending", "consumed" },
    );
    for (fields, 0..) |expected, index| {
        const field = tree.fullContainerField(members[index + 1]) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected.name, tree.tokenSlice(field.ast.main_token));
        const type_node = field.ast.type_expr.unwrap() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(expected.type_name, nodeSource(&tree, source, type_node));
    }
}

fn expectPreparedStreamOperationPermitConsumeSchema(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const client_slot_members = findRootContainerMembers(&tree, "ClientSlot") orelse
        return error.TestUnexpectedResult;
    var receipt_decl: ?std.zig.Ast.Node.Index = null;
    for (client_slot_members) |member| {
        const tuple = declarationTuple(&tree, "ClientSlot", member);
        if (std.mem.eql(u8, tuple.name, "PreparedStreamOperationPermitConsume"))
            receipt_decl = member;
    }
    const variable = tree.fullVarDecl(receipt_decl orelse return error.TestUnexpectedResult) orelse
        return error.TestUnexpectedResult;
    const init = variable.ast.init_node.unwrap() orelse return error.TestUnexpectedResult;
    var receipt_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const receipt = tree.fullContainerDecl(&receipt_buffer, init) orelse
        return error.TestUnexpectedResult;
    const fields = [_]struct { name: []const u8, type_name: []const u8 }{
        .{ .name = "self_addr", .type_name = "usize" },
        .{ .name = "registry_index", .type_name = "u16" },
        .{ .name = "registry_id", .type_name = "u64" },
        .{ .name = "slot_addr", .type_name = "usize" },
        .{ .name = "slot_incarnation", .type_name = "u64" },
        .{ .name = "node_incarnation", .type_name = "u64" },
        .{ .name = "operation_generation", .type_name = "u64" },
        .{ .name = "permit_seal", .type_name = "owner_seal.Digest" },
        .{ .name = "lifecycle", .type_name = "PreparedStreamOperationPermitConsume.Lifecycle" },
    };
    try std.testing.expectEqual(fields.len + 1, receipt.ast.members.len);
    const lifecycle_decl = tree.fullVarDecl(receipt.ast.members[0]) orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "Lifecycle",
        tree.tokenSlice(lifecycle_decl.ast.mut_token + 1),
    );
    const lifecycle_init = lifecycle_decl.ast.init_node.unwrap() orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(
        "enum(u8) { pristine, prepared, consumed }",
        nodeSource(&tree, source, lifecycle_init),
    );
    var lifecycle_buffer: [2]std.zig.Ast.Node.Index = undefined;
    const lifecycle = tree.fullContainerDecl(&lifecycle_buffer, lifecycle_init) orelse
        return error.TestUnexpectedResult;
    try expectFieldNames(&tree, lifecycle.ast.members, &.{ "pristine", "prepared", "consumed" });
    for (fields, 0..) |field, index|
        try expectTypedField(
            &tree,
            source,
            receipt.ast.members[index + 1],
            field.name,
            field.type_name,
        );
}

fn expectClientOperationFenceSchema(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "ClientOperationFence") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 40), members.len);
    const constants = [_][]const u8{
        "shared_count_mask",
        "execution_lease_bit",
        "reserved_mask",
        "publication_bit",
        "terminal_bit",
        "intrusion_bit",
        "exclusive_bit",
    };
    for (constants, 0..) |name, index| {
        const tuple = declarationTuple(&tree, "ClientOperationFence", members[index]);
        try std.testing.expectEqualStrings("const", tuple.kind);
        try std.testing.expectEqualStrings(name, tuple.name);
    }
    try expectTypedFieldWithDefault(&tree, source, members[7], "self_addr", "usize", "0");
    try expectTypedFieldWithDefault(&tree, source, members[8], "client_addr", "usize", "0");
    try expectTypedFieldWithDefault(&tree, source, members[9], "owner_process_id", "u32", "0");
    try expectTypedFieldWithDefault(&tree, source, members[10], "owner_process_nonce", "u64", "0");
    try expectTypedFieldWithDefault(&tree, source, members[11], "slot_incarnation", "u64", "0");
    try expectTypedFieldWithDefault(&tree, source, members[12], "node_incarnation", "u64", "0");
    try expectTypedFieldWithDefault(&tree, source, members[13], "fence_generation", "u64", "0");
    try expectTypedFieldWithDefault(&tree, source, members[14], "fence_incarnation", "u64", "0");
    try expectTypedFieldWithDefault(
        &tree,
        source,
        members[15],
        "state",
        "std.atomic.Value(u64)",
        ".init(0)",
    );
    try expectTypedFieldWithDefault(
        &tree,
        source,
        members[16],
        "execution_capability_addr",
        "std.atomic.Value(usize)",
        ".init(0)",
    );
    inline for (.{
        "execution_capability_identity",
        "execution_owner_thread_id",
        "execution_owner_thread_incarnation",
        "next_execution_capability_identity",
    }, 17..) |name, index| try expectTypedFieldWithDefault(
        &tree,
        source,
        members[index],
        name,
        "std.atomic.Value(u64)",
        if (std.mem.eql(u8, name, "next_execution_capability_identity")) ".init(1)" else ".init(0)",
    );
    const methods = [_][]const u8{
        "initInPlace",
        "tryEnterShared",
        "leaveShared",
        "tryAcquireExclusive",
        "tryAcquireExecutionLease",
        "releaseExecutionLease",
        "upgradeSingleSharedToExecutionLease",
        "downgradeExecutionLeaseToSingleShared",
        "executionLeaseHeld",
        "issueExecutionCapabilityIdentity",
        "executionCapabilityMatches",
        "recordIntrusionIfExactExclusive",
        "sealExclusiveForPublication",
        "intruded",
        "retirementAuthorityDigest",
        "abortExclusive",
        "releaseExclusiveClean",
        "commitExclusiveTerminal",
        "identityMatches",
    };
    for (methods, 0..) |name, index| {
        const tuple = declarationTuple(&tree, "ClientOperationFence", members[index + 21]);
        try std.testing.expectEqualStrings("fn", tuple.kind);
        try std.testing.expectEqualStrings(name, tuple.name);
    }
}

fn expectClientOperationFenceBindingSchema(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse
        return error.TestUnexpectedResult;
    var fence_field: ?std.zig.Ast.Node.Index = null;
    var generation_field: ?std.zig.Ast.Node.Index = null;
    for (members) |member| {
        const tuple = declarationTuple(&tree, "Client", member);
        if (std.mem.eql(u8, tuple.name, "operation_fence")) fence_field = member;
        if (std.mem.eql(u8, tuple.name, "operation_fence_generation")) generation_field = member;
    }
    try expectTypedFieldWithDefault(
        &tree,
        source,
        fence_field orelse return error.TestUnexpectedResult,
        "operation_fence",
        "?*ClientOperationFence",
        "null",
    );
    try expectTypedFieldWithDefault(
        &tree,
        source,
        generation_field orelse return error.TestUnexpectedResult,
        "operation_fence_generation",
        "u64",
        "0",
    );
}

fn expectClientNodeOperationFenceSchema(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "ClientNode") orelse
        return error.TestUnexpectedResult;
    var operation_fence: ?std.zig.Ast.Node.Index = null;
    for (members) |member| {
        const tuple = declarationTuple(&tree, "ClientNode", member);
        if (std.mem.eql(u8, tuple.name, "operation_fence")) {
            if (operation_fence != null) return error.TestUnexpectedResult;
            operation_fence = member;
        }
    }
    try expectTypedField(
        &tree,
        source,
        operation_fence orelse return error.TestUnexpectedResult,
        "operation_fence",
        "client_mod.ClientOperationFence",
    );
}

fn expectClientSlotOperationReservationSchemas(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "ClientSlot") orelse
        return error.TestUnexpectedResult;
    const Field = struct { name: []const u8, type_name: []const u8 };
    const Expected = struct {
        name: []const u8,
        fields: []const Field,
    };
    const registered_fields = [_]Field{
        .{ .name = "node", .type_name = "*ClientNode" },
        .{ .name = "registry_index", .type_name = "u16" },
        .{ .name = "operation_id", .type_name = "u64" },
        .{ .name = "pid", .type_name = "u32" },
    };
    const exclusive_fields = [_]Field{
        .{ .name = "registry_entry", .type_name = "ClientSlotRegistryEntry" },
        .{ .name = "node", .type_name = "*ClientNode" },
    };
    const expected = [_]Expected{
        .{ .name = "RegisteredClientOperation", .fields = &registered_fields },
        .{ .name = "ExclusiveTeardownReservation", .fields = &exclusive_fields },
    };
    for (expected) |contract| {
        var declaration: ?std.zig.Ast.Node.Index = null;
        for (members) |member| {
            const tuple = declarationTuple(&tree, "ClientSlot", member);
            if (std.mem.eql(u8, tuple.name, contract.name)) declaration = member;
        }
        const var_decl = tree.fullVarDecl(declaration orelse return error.TestUnexpectedResult) orelse
            return error.TestUnexpectedResult;
        const init = var_decl.ast.init_node.unwrap() orelse return error.TestUnexpectedResult;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, init) orelse
            return error.TestUnexpectedResult;
        try std.testing.expectEqual(contract.fields.len, container.ast.members.len);
        for (contract.fields, 0..) |field, index|
            try expectTypedField(
                &tree,
                source,
                container.ast.members[index],
                field.name,
                field.type_name,
            );
    }
}

fn expectEndedPurgeInventorySubtotalMigration(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "PreparedEndedPurgeInventory") orelse
        return error.TestUnexpectedResult;
    var old_count: usize = 0;
    var new_count: usize = 0;
    for (members) |member| {
        const tuple = declarationTuple(&tree, "PreparedEndedPurgeInventory", member);
        old_count += @intFromBool(std.mem.eql(u8, tuple.name, "quarantine_bytes"));
        new_count += @intFromBool(std.mem.eql(u8, tuple.name, "demux_owned_extent_bytes"));
        try std.testing.expect(!std.mem.eql(u8, tuple.name, "complete_owned_extent_bytes"));
    }
    try std.testing.expectEqual(@as(usize, 1), old_count + new_count);
}

fn expectRootEnumExact(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    name: []const u8,
    fields: []const []const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const init = findRootVariableInitializer(&tree, name) orelse
        return error.TestUnexpectedResult;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, init) orelse
        return error.TestUnexpectedResult;
    try expectFieldNames(&tree, container.ast.members, fields);
}

fn expectNestedEnumAbsentOrExact(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    parent_name: []const u8,
    name: []const u8,
    fields: []const []const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const parent = findRootContainerMembers(&tree, parent_name) orelse
        return error.TestUnexpectedResult;
    for (parent) |member| {
        const variable = tree.fullVarDecl(member) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(variable.ast.mut_token + 1), name)) continue;
        const init = variable.ast.init_node.unwrap() orelse return error.TestUnexpectedResult;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const container = tree.fullContainerDecl(&buffer, init) orelse return error.TestUnexpectedResult;
        return expectFieldNames(&tree, container.ast.members, fields);
    }
}

fn expectRootErrorSetExact(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    name: []const u8,
    fields: []const []const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const init = findRootVariableInitializer(&tree, name) orelse
        return error.TestUnexpectedResult;
    try expectErrorSetNodeFields(&tree, init, fields);
}

fn expectNestedErrorSetAbsentOrExact(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    parent_name: []const u8,
    name: []const u8,
    fields: []const []const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const parent = findRootContainerMembers(&tree, parent_name) orelse
        return error.TestUnexpectedResult;
    for (parent) |member| {
        const variable = tree.fullVarDecl(member) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(variable.ast.mut_token + 1), name)) continue;
        const init = variable.ast.init_node.unwrap() orelse return error.TestUnexpectedResult;
        return expectErrorSetNodeFields(&tree, init, fields);
    }
}

fn expectErrorSetNodeFields(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    expected: []const []const u8,
) !void {
    try std.testing.expectEqual(std.zig.Ast.Node.Tag.error_set_decl, tree.nodeTag(node));
    var index: usize = 0;
    var token = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (token <= last) : (token += 1) {
        if (tree.tokenTag(token) != .identifier) continue;
        try std.testing.expect(index < expected.len);
        try std.testing.expectEqualStrings(expected[index], tree.tokenSlice(token));
        index += 1;
    }
    try std.testing.expectEqual(expected.len, index);
}

fn expectEndedPurgeScratchDelta(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "EndedPurgeScratch") orelse
        return error.TestUnexpectedResult;
    const names = [_][]const u8{
        "PendingOutboundDescriptor",
        "Lifecycle",
        "build_id",
        "client_lifecycle",
        "lifecycle",
        "pending_outbound",
    };
    var counts = [_]usize{0} ** names.len;
    var nodes = [_]?std.zig.Ast.Node.Index{null} ** names.len;
    for (members) |member| {
        const tuple = declarationTuple(&tree, "EndedPurgeScratch", member);
        for (names, 0..) |name, index| {
            if (std.mem.eql(u8, tuple.name, name)) {
                counts[index] += 1;
                nodes[index] = member;
            }
        }
    }
    const present = counts[0];
    try std.testing.expectEqual(@as(usize, 1), present);
    for (counts) |count| try std.testing.expectEqual(@as(usize, 1), count);
    if (nodes[0]) |node| {
        const variable = tree.fullVarDecl(node) orelse return error.TestUnexpectedResult;
        const init = variable.ast.init_node.unwrap() orelse return error.TestUnexpectedResult;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        const descriptor = tree.fullContainerDecl(&buffer, init) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(@as(usize, 4), descriptor.ast.members.len);
        try expectTypedField(&tree, source, descriptor.ast.members[0], "frame_address", "usize");
        try expectTypedField(&tree, source, descriptor.ast.members[1], "frame_len", "usize");
        try expectTypedField(&tree, source, descriptor.ast.members[2], "stream_id", "u64");
        try expectTypedField(&tree, source, descriptor.ast.members[3], "offset", "usize");
    }
    try expectNestedEnumAbsentOrExact(
        allocator,
        source,
        "EndedPurgeScratch",
        "Lifecycle",
        &.{ "empty", "inventory_prepared", "commit_frozen", "consumed" },
    );
    const zero_descriptor = ".{ .address = 0, .len = 0, .capacity = 0 }";
    try expectTypedFieldWithDefault(
        &tree,
        source,
        nodes[2].?,
        "build_id",
        "ExternalArrayDescriptor",
        zero_descriptor,
    );
    try expectTypedFieldWithDefault(
        &tree,
        source,
        nodes[3].?,
        "client_lifecycle",
        "ExternalArrayDescriptor",
        zero_descriptor,
    );
    try expectTypedFieldWithDefault(
        &tree,
        source,
        nodes[4].?,
        "lifecycle",
        "Lifecycle",
        ".empty",
    );
    try expectTypedFieldWithDefault(
        &tree,
        source,
        nodes[5].?,
        "pending_outbound",
        "?PendingOutboundDescriptor",
        "null",
    );
}

fn expectEndedPurgeQuarantineSchema(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const error_node = findRootVariableInitializer(&tree, "Error") orelse
        return error.TestUnexpectedResult;
    try expectErrorSetNodeFields(
        &tree,
        error_node,
        &.{ "InvalidOwner", "InvalidState", "ArithmeticOverflow", "CapacityExceeded" },
    );

    const reservation = findRootContainerMembers(&tree, "Reservation") orelse
        return error.TestUnexpectedResult;
    const reservation_fields = [_]struct { name: []const u8, type_name: []const u8 }{
        .{ .name = "self_addr", .type_name = "usize" },
        .{ .name = "registry_addr", .type_name = "usize" },
        .{ .name = "reservation_generation", .type_name = "u64" },
        .{ .name = "process_id", .type_name = "u64" },
        .{ .name = "node_incarnation", .type_name = "u64" },
        .{ .name = "operation_generation", .type_name = "u64" },
        .{ .name = "bytes", .type_name = "usize" },
        .{ .name = "lifecycle", .type_name = "Lifecycle" },
    };
    try std.testing.expectEqual(reservation_fields.len + 1, reservation.len);
    try expectNestedEnum(&tree, reservation[0], "Lifecycle", &.{ "pristine", "reserved", "spent" });
    for (reservation_fields, 0..) |expected, index|
        try expectTypedField(&tree, source, reservation[index + 1], expected.name, expected.type_name);

    const receipt = findRootContainerMembers(&tree, "CommitReceipt") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(reservation_fields.len + 1, receipt.len);
    try expectNestedEnum(&tree, receipt[0], "Lifecycle", &.{ "pristine", "committed", "consumed" });
    for (reservation_fields, 0..) |expected, index|
        try expectTypedField(&tree, source, receipt[index + 1], expected.name, expected.type_name);

    const proof = findRootContainerMembers(&tree, "ConsumedCommitProof") orelse
        return error.TestUnexpectedResult;
    const proof_fields = [_]struct { name: []const u8, type_name: []const u8 }{
        .{ .name = "reservation_generation", .type_name = "u64" },
        .{ .name = "process_id", .type_name = "u64" },
        .{ .name = "node_incarnation", .type_name = "u64" },
        .{ .name = "operation_generation", .type_name = "u64" },
        .{ .name = "bytes", .type_name = "usize" },
    };
    try std.testing.expectEqual(proof_fields.len + 1, proof.len);
    for (proof_fields, 0..) |expected, index|
        try expectTypedField(&tree, source, proof[index], expected.name, expected.type_name);
    const matches_tuple = declarationTuple(&tree, "ConsumedCommitProof", proof[proof_fields.len]);
    try std.testing.expectEqualStrings("fn", matches_tuple.kind);
    try std.testing.expectEqualStrings("pub", matches_tuple.visibility);
    try std.testing.expectEqualStrings("matches", matches_tuple.name);
    try expectFnSignature(
        &tree,
        source,
        proof[proof_fields.len],
        &.{ "self", "process_id", "node_incarnation", "operation_generation", "bytes" },
        &.{ "ConsumedCommitProof", "u64", "u64", "u64", "usize" },
        "bool",
    );

    const registry = findRootContainerMembers(&tree, "Registry") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 23), registry.len);
    try expectNestedEnum(&tree, registry[0], "State", &.{ "idle", "reserved", "committed" });
    try expectTypedField(&tree, source, registry[1], "mutex", "std.atomic.Mutex");
    try expectTypedField(&tree, source, registry[2], "owner_process_id", "u64");
    try expectTypedField(&tree, source, registry[3], "state", "State");
    try expectTypedField(&tree, source, registry[4], "next_generation", "u64");
    try expectTypedField(&tree, source, registry[5], "reserved_reservation_addr", "usize");
    try expectTypedField(&tree, source, registry[6], "reserved_generation", "u64");
    try expectTypedField(&tree, source, registry[7], "reserved_process_id", "u64");
    try expectTypedField(&tree, source, registry[8], "reserved_node_incarnation", "u64");
    try expectTypedField(&tree, source, registry[9], "reserved_operation_generation", "u64");
    try expectTypedField(&tree, source, registry[10], "reserved_bytes", "usize");
    try expectTypedField(&tree, source, registry[11], "committed_receipt_addr", "usize");
    try expectTypedField(&tree, source, registry[12], "committed_generation", "u64");
    try expectTypedField(&tree, source, registry[13], "committed_process_id", "u64");
    try expectTypedField(&tree, source, registry[14], "committed_node_incarnation", "u64");
    try expectTypedField(&tree, source, registry[15], "committed_operation_generation", "u64");
    try expectTypedField(&tree, source, registry[16], "committed_bytes", "usize");
    try expectTypedField(&tree, source, registry[17], "finalization_consumed", "bool");
    const methods = [_][]const u8{ "init", "reserve", "release", "commit", "consumeCommitted" };
    for (methods, 0..) |name, index| {
        const tuple = declarationTuple(&tree, "Registry", registry[index + 18]);
        try std.testing.expectEqualStrings("fn", tuple.kind);
        try std.testing.expectEqualStrings("pub", tuple.visibility);
        try std.testing.expectEqualStrings(name, tuple.name);
    }
    try expectFnSignature(&tree, source, registry[18], &.{}, &.{}, "Registry");
    try expectFnSignature(
        &tree,
        source,
        registry[19],
        &.{ "self", "node_incarnation", "operation_generation", "bytes", "out" },
        &.{ "*Registry", "u64", "u64", "usize", "*Reservation" },
        "Error!void",
    );
    try expectFnSignature(
        &tree,
        source,
        registry[20],
        &.{ "self", "reservation" },
        &.{ "*Registry", "*Reservation" },
        "bool",
    );
    try expectFnSignature(
        &tree,
        source,
        registry[21],
        &.{ "self", "reservation", "out" },
        &.{ "*Registry", "*Reservation", "*CommitReceipt" },
        "bool",
    );
    try expectFnSignature(
        &tree,
        source,
        registry[22],
        &.{ "self", "receipt", "out" },
        &.{ "*Registry", "*CommitReceipt", "*ConsumedCommitProof" },
        "bool",
    );
}

fn expectFnSignature(
    tree: *const std.zig.Ast,
    source: [:0]const u8,
    node: std.zig.Ast.Node.Index,
    names: []const []const u8,
    types: []const []const u8,
    return_type: []const u8,
) !void {
    var buffer: [1]std.zig.Ast.Node.Index = undefined;
    var proto = tree.fullFnProto(&buffer, node) orelse return error.TestUnexpectedResult;
    var iterator = proto.iterate(tree);
    var index: usize = 0;
    while (iterator.next()) |param| : (index += 1) {
        try std.testing.expect(index < names.len);
        const name_token = param.name_token orelse return error.TestUnexpectedResult;
        const type_node = param.type_expr orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(names[index], tree.tokenSlice(name_token));
        try std.testing.expectEqualStrings(types[index], nodeSource(tree, source, type_node));
    }
    try std.testing.expectEqual(names.len, index);
    const result = proto.ast.return_type.unwrap() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(return_type, nodeSource(tree, source, result));
}

fn expectClientReceiverManifest(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    manifest: []const ClientReceiverSpec,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse
        return error.TestUnexpectedResult;
    var found_count: usize = 0;
    for (members) |member| {
        const tuple = declarationTuple(&tree, "Client", member);
        if (!std.mem.eql(u8, tuple.kind, "fn") or
            !std.mem.eql(u8, tuple.visibility, "pub"))
            continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        var proto = tree.fullFnProto(&buffer, member) orelse
            return error.TestUnexpectedResult;
        var params = proto.iterate(&tree);
        const first = params.next() orelse continue;
        const type_node = first.type_expr orelse continue;
        const receiver_type = nodeSource(&tree, source, type_node);
        if (!std.mem.eql(u8, receiver_type, "*Client") and
            !std.mem.eql(u8, receiver_type, "*const Client"))
            continue;
        var match_count: usize = 0;
        for (manifest) |expected| {
            if (!std.mem.eql(u8, expected.name, tuple.name)) continue;
            try std.testing.expectEqualStrings(expected.receiver_type, receiver_type);
            _ = expected.class;
            match_count += 1;
        }
        if (match_count != 1)
            std.debug.print("unreviewed public Client receiver: {s} ({s})\n", .{
                tuple.name,
                receiver_type,
            });
        try std.testing.expectEqual(@as(usize, 1), match_count);
        found_count += 1;
    }
    try std.testing.expectEqual(manifest.len, found_count);
}

fn expectClientConstructionPolicies(
    allocator: std.mem.Allocator,
    manifest: []const ClientReceiverSpec,
    proofs: []const ClientConstructionProof,
) !void {
    var construction_count: usize = 0;
    for (manifest) |entry| {
        if (entry.class != .construction) continue;
        construction_count += 1;
        var matches: usize = 0;
        for (proofs) |proof|
            matches += @intFromBool(std.mem.eql(u8, entry.name, proof.receiver));
        try std.testing.expectEqual(@as(usize, 1), matches);
    }
    try std.testing.expectEqual(construction_count, proofs.len);

    var expected_edges: usize = 0;
    for (proofs, 0..) |proof, proof_index| {
        for (proofs[0..proof_index]) |prior|
            try std.testing.expect(!std.mem.eql(u8, prior.receiver, proof.receiver));
        for (proof.uses, 0..) |use, use_index| {
            try std.testing.expect(use.count > 0);
            expected_edges += 1;
            for (proof.uses[0..use_index]) |prior|
                try std.testing.expect(!clientConstructionUseEql(prior, use));
        }
    }
    const observed = try allocator.alloc(usize, expected_edges);
    defer allocator.free(observed);
    @memset(observed, 0);
    var unreviewed: usize = 0;

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readZigFileZ(allocator, path);
        defer allocator.free(source);
        var tree = try std.zig.Ast.parse(allocator, source, .zig);
        defer tree.deinit(allocator);
        try scanClientConstructionSource(&tree, path, proofs, observed, &unreviewed, true);
    }

    var flat_index: usize = 0;
    for (proofs) |proof| {
        for (proof.uses) |use| {
            if (use.count != observed[flat_index]) std.debug.print(
                "Client construction reference count mismatch: {s} {s}:{s}.{s} expected={} observed={}\n",
                .{
                    proof.receiver,
                    use.path,
                    expectedClientConstructionContainer(proof.receiver, use),
                    use.enclosing_fn,
                    use.count,
                    observed[flat_index],
                },
            );
            try std.testing.expectEqual(use.count, observed[flat_index]);
            flat_index += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 0), unreviewed);
}

fn expectClientConstructionCategories(proofs: []const ClientConstructionProof) !void {
    try std.testing.expect(clientConstructionCategoriesValid(proofs));
}

fn clientConstructionCategoriesValid(proofs: []const ClientConstructionProof) bool {
    var counts = [_]usize{0} ** 4;
    for (proofs) |proof| {
        const expected: ClientConstructionKind = if (stringInSet(proof.receiver, &.{
            "canMoveToGenerationNode",
            "canRetireFromGenerationNode",
            "retirementRangeAliasesOwnedBacking",
            "moveToGenerationNode",
            "bindOperationFence",
            "bindGenerationAccountingLedger",
        }))
            .generation_init
        else if (stringInSet(proof.receiver, &.{
            "externalTransferProfile",
            "prepareExternalPumpTransfer",
            "commitExternalPumpTransfer",
            "prepareExternalOwnerRangeProof",
        }))
            .external_transfer
        else if (stringInSet(proof.receiver, &.{
            "prepareExternalModeDeinit",
            "reserveExternalModeDeinit",
            "finishReservedExternalModeDeinit",
            "cancelReservedExternalModeDeinit",
            "transferReservedExternalModeDeinit",
        }))
            .external_teardown
        else
            .external_adoption;
        if (expected != proof.kind) return false;
        counts[@intFromEnum(proof.kind)] += 1;
    }
    return std.mem.eql(usize, &.{ 6, 4, 22, 5 }, &counts);
}

fn stringInSet(value: []const u8, set: []const []const u8) bool {
    for (set) |candidate| if (std.mem.eql(u8, value, candidate)) return true;
    return false;
}

fn scanClientConstructionSource(
    tree: *const std.zig.Ast,
    path: []const u8,
    proofs: []const ClientConstructionProof,
    observed: []usize,
    unreviewed: *usize,
    report_unreviewed: bool,
) !void {
    const top_level_test_tokens = try source_digest.topLevelTestTokenMask(std.testing.allocator, tree);
    defer std.testing.allocator.free(top_level_test_tokens);
    var reflection_observed = [_]usize{0} ** client_reflection_owners.len;
    // **digest 와 count 는 `source_digest` 가 소유한다.** 아래 루프는 session_host 반사 심사(닫힌 세계
    // 계약)를 계속 하지만, 원장에 들어가는 두 값은 여기서 손으로 세지 않는다 — 규칙이 두 곳에 있으면
    // 그 둘이 갈리는 순간 조용히 어긋난다.
    const external = try source_digest.compute(std.testing.allocator, tree, path);
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node) orelse continue;
        const name_token = proto.name_token orelse continue;
        if (top_level_test_tokens[name_token]) continue;
        const name = tree.tokenSlice(name_token);
        for (proofs) |proof| {
            if (std.mem.eql(u8, proof.receiver, "enterExternalMode") or
                !std.mem.eql(u8, proof.receiver, name)) continue;
            const owner = innermostFunctionOwner(tree, name_token) orelse
                return error.TestUnexpectedResult;
            if (!std.mem.eql(u8, path, "src/platform/macos/session_host/client.zig") or
                !std.mem.eql(u8, owner.container, "Client") or
                owner.container_identity != expectedContainerPathIdentity("Client"))
            {
                if (report_unreviewed) std.debug.print(
                    "unreviewed Client construction declaration: {s}:{s}.{s}\n",
                    .{ path, owner.container, name },
                );
                return error.TestUnexpectedResult;
            }
        }
    }
    var token: std.zig.Ast.TokenIndex = 0;
    while (token + 1 < tree.tokens.len) : (token += 1) {
        if (top_level_test_tokens[token]) continue;
        if (std.mem.eql(u8, tree.tokenSlice(token), "@field")) {
            var lookahead = token + 1;
            while (lookahead < tree.tokens.len and
                !std.mem.eql(u8, tree.tokenSlice(lookahead), "(")) : (lookahead += 1)
            {}
            if (lookahead == tree.tokens.len) return error.TestUnexpectedResult;
            var depth: usize = 1;
            lookahead += 1;
            while (lookahead < tree.tokens.len and depth != 0) : (lookahead += 1) {
                const part = tree.tokenSlice(lookahead);
                if (std.mem.eql(u8, part, "(")) depth += 1;
                if (std.mem.eql(u8, part, ")")) depth -= 1;
            }
            if (depth != 0) return error.TestUnexpectedResult;
            const reflection_closed_world = std.mem.startsWith(
                u8,
                path,
                "src/platform/macos/session_host/",
            ) or std.mem.eql(u8, path, "synthetic.zig");
            if (!reflection_closed_world) continue;
            const owner = innermostFunctionOwner(tree, token) orelse
                return error.TestUnexpectedResult;
            var admitted = false;
            for (client_reflection_owners, 0..) |proof, proof_index| {
                if (!std.mem.eql(u8, proof.path, path) or
                    !std.mem.eql(u8, proof.function, owner.function) or
                    expectedContainerPathIdentity(proof.container) != owner.container_identity) continue;
                const expression_tokens = try tokenizeMarker(std.testing.allocator, proof.expression);
                defer std.testing.allocator.free(expression_tokens);
                if (findTreeTokenSequence(
                    tree,
                    token,
                    lookahead - 1,
                    proof.expression,
                    expression_tokens,
                ) != token) continue;
                reflection_observed[proof_index] += 1;
                admitted = true;
                break;
            }
            if (!admitted) {
                if (report_unreviewed) std.debug.print(
                    "unreviewed session-host reflection: {s}:{s}.{s}\n",
                    .{ path, owner.container, owner.function },
                );
                return error.TestUnexpectedResult;
            }
        }
        if (!std.mem.eql(u8, tree.tokenSlice(token), ".")) continue;
        const receiver = tree.tokenSlice(token + 1);
        var proof_match: ?usize = null;
        for (proofs, 0..) |proof, index| {
            if (std.mem.eql(u8, proof.receiver, receiver)) {
                proof_match = index;
                break;
            }
        }
        const proof_index = proof_match orelse continue;
        if (token + 2 >= tree.tokens.len or
            !std.mem.eql(u8, tree.tokenSlice(token + 2), "("))
            return error.TestUnexpectedResult;
        const owner = innermostFunctionOwner(tree, token) orelse
            ClientReferenceOwner{
                .container = "<root>",
                .container_identity = expectedContainerPathIdentity("<root>"),
                .function = "<root>",
                .first_token = token,
                .last_token = token,
            };
        var flat_index: usize = 0;
        var matched = false;
        for (proofs, 0..) |proof, index| {
            for (proof.uses) |use| {
                const expected_container = expectedClientConstructionContainer(proof.receiver, use);
                if (index == proof_index and std.mem.eql(u8, use.path, path) and
                    std.mem.eql(u8, expectedContainerLeaf(expected_container), owner.container) and
                    expectedContainerPathIdentity(expected_container) == owner.container_identity and
                    std.mem.eql(u8, use.enclosing_fn, owner.function))
                {
                    observed[flat_index] += 1;
                    matched = true;
                }
                flat_index += 1;
            }
        }
        if (!matched) {
            if (report_unreviewed)
                std.debug.print("unreviewed Client construction reference: {s} {s} {s}.{s}\n", .{
                    receiver,
                    path,
                    owner.container,
                    owner.function,
                });
            unreviewed.* += 1;
        }
    }
    for (client_reflection_owners, 0..) |proof, proof_index| {
        if (!std.mem.eql(u8, proof.path, path)) continue;
        if (reflection_observed[proof_index] != proof.count) {
            if (report_unreviewed) std.debug.print(
                "session-host reflection count mismatch: {s}:{s}.{s} expected={} observed={}\n",
                .{ proof.path, proof.container, proof.function, proof.count, reflection_observed[proof_index] },
            );
            return error.TestUnexpectedResult;
        }
    }
    if (!std.mem.startsWith(u8, path, "src/platform/macos/session_host/") and
        !std.mem.eql(u8, path, "synthetic.zig"))
    {
        const digest_hex = external.digestHex();
        var proof_match: ?external_digests.Proof = null;
        for (external_digests.inventory) |proof| {
            if (!std.mem.eql(u8, proof.path, path)) continue;
            proof_match = proof;
            break;
        }
        if (proof_match) |proof| {
            if (proof.count != external.reflection_count or
                !std.mem.eql(u8, proof.digest_hex, &digest_hex))
            {
                if (report_unreviewed) std.debug.print(
                    "external source inventory mismatch: {s} count={} digest={s}\n",
                    .{ path, external.reflection_count, &digest_hex },
                );
                return error.TestUnexpectedResult;
            }
        } else if (external.reflection_count != 0) {
            if (report_unreviewed) std.debug.print(
                "unreviewed external reflection inventory: {s} count={} digest={s}\n",
                .{ path, external.reflection_count, &digest_hex },
            );
            return error.TestUnexpectedResult;
        }
    }
}

fn expectedContainerLeaf(path: []const u8) []const u8 {
    const separator = std.mem.lastIndexOfScalar(u8, path, '.') orelse return path;
    return path[separator + 1 ..];
}

fn syntheticConstructionPolicyValid(
    source: [:0]const u8,
    enclosing_fn: []const u8,
    count: usize,
) !bool {
    return syntheticConstructionPolicyValidInContainer(source, "<root>", enclosing_fn, count);
}

fn syntheticConstructionPolicyValidAtPath(
    source: [:0]const u8,
    path: []const u8,
    enclosing_fn: []const u8,
    count: usize,
) !bool {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const proofs = [_]ClientConstructionProof{.{
        .receiver = "sample",
        .kind = .external_adoption,
        .uses = &.{.{ .path = path, .enclosing_fn = enclosing_fn, .count = count }},
    }};
    var observed = [_]usize{0};
    var unreviewed: usize = 0;
    scanClientConstructionSource(&tree, path, &proofs, &observed, &unreviewed, false) catch
        return false;
    return unreviewed == 0 and observed[0] == count;
}

fn syntheticConstructionPolicyValidInContainer(
    source: [:0]const u8,
    enclosing_container: []const u8,
    enclosing_fn: []const u8,
    count: usize,
) !bool {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const proofs = [_]ClientConstructionProof{.{
        .receiver = "sample",
        .kind = .external_adoption,
        .uses = &.{.{
            .path = "synthetic.zig",
            .enclosing_container = enclosing_container,
            .enclosing_fn = enclosing_fn,
            .count = count,
        }},
    }};
    var observed = [_]usize{0};
    var unreviewed: usize = 0;
    scanClientConstructionSource(&tree, "synthetic.zig", &proofs, &observed, &unreviewed, false) catch
        return false;
    return unreviewed == 0 and observed[0] == count;
}

fn syntheticEnterExternalModePolicyValid(source: [:0]const u8) bool {
    expectEnterExternalModeBoundReject(std.testing.allocator, source) catch return false;
    return true;
}

fn syntheticNoUnlistedCallsValid(source: [:0]const u8) bool {
    expectNoUnlistedCallsBetweenMarkers(
        std.testing.allocator,
        source,
        "Client",
        "move",
        "destination.* = self.*",
        "self.* =",
        &.{.{ .name = "rebindPreparedNormalizeExact", .count = 1 }},
    ) catch return false;
    return true;
}

fn syntheticExactMoveRegionValid(source: [:0]const u8) bool {
    expectExactMethodTokenRegion(
        std.testing.allocator,
        source,
        "Client",
        "move",
        "destination.*=self.*;self.rebindPreparedNormalizeExact();self.*=",
        false,
    ) catch return false;
    return true;
}

fn syntheticMarkerCountValid(source: [:0]const u8, marker: []const u8, count: usize) bool {
    const observed = containerMethodMarkerCount(
        std.testing.allocator,
        source,
        "ClientSlot",
        "initInPlaceWithIssuer",
        marker,
    ) catch return false;
    return observed == count;
}

fn syntheticDirectIdentifierValid(source: [:0]const u8, identifier: []const u8) bool {
    expectOnlyDirectIdentifierReference(
        std.testing.allocator,
        source,
        "ClientSlot",
        "initInPlaceWithIssuer",
        identifier,
    ) catch return false;
    return true;
}

fn expectEnterExternalModeBoundReject(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse
        return error.TestUnexpectedResult;
    var method: ?std.zig.Ast.Node.Index = null;
    for (members) |member| {
        const tuple = declarationTuple(&tree, "Client", member);
        if (std.mem.eql(u8, tuple.kind, "fn") and
            std.mem.eql(u8, tuple.name, "enterExternalMode")) method = member;
    }
    const node = method orelse return error.TestUnexpectedResult;
    const release = nodeCallToken(&tree, node, "self", "endPublicMutation") orelse
        return error.TestUnexpectedResult;
    const release_close = matchingCloseParen(&tree, node, release + 3) orelse
        return error.TestUnexpectedResult;
    const suffix = [_][]const u8{
        ";",     "if",                       "(",    "operation_fence_held", ")",      "return",
        "error", ".",                        "Busy", ";",                    "return", "self",
        ".",     "enterExternalModeWithOps", "(",    "client_deadline",      ".",      "posix_ops",
        ")",     ";",
    };
    try expectTokensAt(&tree, release_close + 1, &suffix);
}

fn expectClientMethodBodyPrefix(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    method_name: []const u8,
    expected: []const []const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse
        return error.TestUnexpectedResult;
    var method: ?std.zig.Ast.Node.Index = null;
    for (members) |member| {
        const tuple = declarationTuple(&tree, "Client", member);
        if (std.mem.eql(u8, tuple.kind, "fn") and
            std.mem.eql(u8, tuple.name, method_name)) method = member;
    }
    const node = method orelse return error.TestUnexpectedResult;
    const open = findTokenAfter(&tree, node, tree.firstToken(node), "{") orelse
        return error.TestUnexpectedResult;
    try expectTokensAt(&tree, open + 1, expected);
}

fn clientConstructionUseEql(a: ClientConstructionUse, b: ClientConstructionUse) bool {
    return std.mem.eql(u8, a.path, b.path) and
        std.mem.eql(u8, a.enclosing_container, b.enclosing_container) and
        std.mem.eql(u8, a.enclosing_fn, b.enclosing_fn);
}

fn expectedClientConstructionContainer(receiver: []const u8, use: ClientConstructionUse) []const u8 {
    if (!std.mem.eql(u8, use.enclosing_container, "<derived>")) return use.enclosing_container;
    if (std.mem.eql(u8, receiver, "enterExternalMode")) {
        if (std.mem.eql(u8, use.path, "src/platform/macos/session_host/external_attach_evidence.zig") and
            std.mem.eql(u8, use.enclosing_fn, "init")) return "TestPrepared";
        if (std.mem.eql(u8, use.path, "src/platform/macos/session_host/external_event_materialization.zig") and
            std.mem.eql(u8, use.enclosing_fn, "init")) return "TestClient";
        if (std.mem.eql(u8, use.path, "src/platform/macos/session_host/client_external_pump.zig") and
            std.mem.eql(u8, use.enclosing_fn, "initWithAllocator")) return "TestClient";
    }
    if (std.mem.eql(u8, use.path, "src/platform/macos/session_host/client_slot.zig"))
        return "ClientSlot";
    if (std.mem.eql(u8, use.path, "src/platform/macos/session_host/client.zig")) {
        if (std.mem.eql(u8, use.enclosing_fn, "overlapsCommittedOwnedRange") or
            (std.mem.eql(u8, use.enclosing_fn, "validate") and
                std.mem.eql(u8, receiver, "validateSealedExternalAdoptionPlan")))
            return "ExternalAdoptionTake";
        if (std.mem.eql(u8, use.enclosing_fn, "validate") and
            std.mem.eql(u8, receiver, "externalTransferProfile"))
            return "PreparedExternalPumpTransfer";
        if (stringInSet(use.enclosing_fn, &.{
            "moveToGenerationNode",
            "prepareExternalPumpTransfer",
            "externalAdoptionFoldResultMatches",
            "materializeExternalMetadataEvent",
            "externalMetadataDtoMatchesEventCandidate",
            "preflightExternalAdoption",
            "stageExternalScreenCopies",
            "sealExternalAdoption",
            "validateSealedExternalAdoptionPlan",
            "prepareExternalAdoptionTake",
            "prepareExternalRecoveryDiscard",
            "prepareDeinitGraph",
            "poisonAndTakeFd",
        })) return "Client";
        return "<root>";
    }
    if (std.mem.eql(u8, use.path, "src/platform/macos/session_host/client_external_pump.zig")) {
        if (std.mem.eql(u8, use.enclosing_fn, "initFromAttachPartsInPlace") or
            (std.mem.eql(u8, use.enclosing_fn, "validate") and
                std.mem.eql(u8, receiver, "externalTransferProfile")))
            return "PreparedAdoptionEvidence";
        if (stringInSet(use.enclosing_fn, &.{
            "consumeProjectedRecoverySnapshotUnchecked",
            "publishRxAggregateUnchecked",
            "publishRecoverySnapshotCommitUnchecked",
            "committedRecoverySnapshotBindingCurrent",
            "finishPublishedRxAggregateCommit",
            "captureResyncSemanticCleanupSnapshot",
            "detectResyncSemanticCleanupDrift",
            "wholeTurnScratchDisjoint",
            "initInPlaceWithOptions",
            "projectOwnerEventInternal",
            "projectionScratchDisjoint",
            "prepareAdoptionInner",
            "finishNonAdopted",
            "finishImmediateTerminal",
            "validateFinalSeal",
            "latchCommitTerminal",
            "latchCrossOwnerAliasTerminal",
            "teardownUnderHeldOperationLease",
            "prepareAggregateOwnerRangeProof",
            "closeUncommittedOwned",
        })) return "ExternalPumpStorage";
        return "<root>";
    }
    if (std.mem.eql(u8, use.path, "src/platform/macos/session_host/client_external_adoption.zig") and
        stringInSet(use.enclosing_fn, &.{ "initInPlace", "validate", "commitScreenSeeds" }))
        return "PreparedScreenBacklog";
    if (std.mem.eql(u8, use.path, "src/platform/macos/session_host/external_event_materialization.zig") and
        std.mem.eql(u8, use.enclosing_fn, "validate"))
        return "Prepared";
    return "<root>";
}

const ClientReferenceOwner = struct {
    container: []const u8,
    container_identity: u64,
    function: []const u8,
    first_token: std.zig.Ast.TokenIndex,
    last_token: std.zig.Ast.TokenIndex,
};

fn innermostFunctionOwner(tree: *const std.zig.Ast, token: std.zig.Ast.TokenIndex) ?ClientReferenceOwner {
    var function: ?[]const u8 = null;
    var function_first: std.zig.Ast.TokenIndex = 0;
    var function_last: std.zig.Ast.TokenIndex = 0;
    var result_span: usize = std.math.maxInt(usize);
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (token < first or token > last) continue;
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const proto = tree.fullFnProto(&buffer, node) orelse continue;
        const name_token = proto.name_token orelse continue;
        const span: usize = @intCast(last - first);
        if (span >= result_span) continue;
        function = tree.tokenSlice(name_token);
        function_first = first;
        function_last = last;
        result_span = span;
    }
    const function_name = function orelse return null;
    var container: []const u8 = "<root>";
    var container_span: usize = std.math.maxInt(usize);
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        const variable = tree.fullVarDecl(node) orelse continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        _ = tree.fullContainerDecl(&buffer, init) orelse continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (token < first or token > last) continue;
        const span: usize = @intCast(last - first);
        if (span >= container_span) continue;
        container = tree.tokenSlice(variable.ast.mut_token + 1);
        container_span = span;
    }
    return .{
        .container = container,
        .container_identity = containerPathIdentity(tree, token),
        .function = function_name,
        .first_token = function_first,
        .last_token = function_last,
    };
}

fn containerPathIdentity(tree: *const std.zig.Ast, token: std.zig.Ast.TokenIndex) u64 {
    const Container = struct { name: []const u8, span: usize };
    var containers: [16]Container = undefined;
    var count: usize = 0;
    for (0..tree.nodes.len) |raw_node| {
        const node: std.zig.Ast.Node.Index = @enumFromInt(raw_node);
        const variable = tree.fullVarDecl(node) orelse continue;
        const init = variable.ast.init_node.unwrap() orelse continue;
        var buffer: [2]std.zig.Ast.Node.Index = undefined;
        _ = tree.fullContainerDecl(&buffer, init) orelse continue;
        const first = tree.firstToken(node);
        const last = tree.lastToken(node);
        if (token < first or token > last) continue;
        if (count == containers.len) return 0;
        containers[count] = .{
            .name = tree.tokenSlice(variable.ast.mut_token + 1),
            .span = @intCast(last - first),
        };
        count += 1;
    }
    var index: usize = 1;
    while (index < count) : (index += 1) {
        const current = containers[index];
        var destination = index;
        while (destination > 0 and containers[destination - 1].span < current.span) : (destination -= 1)
            containers[destination] = containers[destination - 1];
        containers[destination] = current;
    }
    var identity: u64 = 14695981039346656037;
    if (count == 0) return pathIdentityPart(identity, "<root>");
    for (containers[0..count], 0..) |entry, ordinal| {
        if (ordinal != 0) identity = pathIdentityPart(identity, ".");
        identity = pathIdentityPart(identity, entry.name);
    }
    return identity;
}

fn expectedContainerPathIdentity(path: []const u8) u64 {
    const identity: u64 = 14695981039346656037;
    return pathIdentityPart(identity, path);
}

fn pathIdentityPart(initial: u64, bytes: []const u8) u64 {
    var identity = initial;
    for (bytes) |byte| {
        identity ^= byte;
        identity *%= 1099511628211;
    }
    return identity;
}

fn expectGuardedClientReceiverPolicies(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    manifest: []const ClientReceiverSpec,
    proofs: []const ClientGuardProof,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse
        return error.TestUnexpectedResult;

    var guarded_count: usize = 0;
    var guarded_authority_count: usize = 0;
    for (manifest) |entry| {
        const guarded_authority = entry.class == .unchecked and
            (std.mem.eql(u8, entry.name, "beginGenerationAllocatorScope") or
                std.mem.eql(u8, entry.name, "restoreGenerationAllocatorScope"));
        if (entry.class != .guarded and !guarded_authority) continue;
        if (guarded_authority) guarded_authority_count += 1 else guarded_count += 1;
        var proof_count: usize = 0;
        for (proofs) |proof| proof_count += @intFromBool(std.mem.eql(u8, entry.name, proof.receiver));
        try std.testing.expectEqual(@as(usize, 1), proof_count);
    }
    try std.testing.expectEqual(guarded_count + guarded_authority_count, proofs.len);
    try std.testing.expectEqual(@as(usize, 2), guarded_authority_count);

    for (proofs) |proof| {
        var receiver_node: ?std.zig.Ast.Node.Index = null;
        var funnel_node: ?std.zig.Ast.Node.Index = null;
        for (members) |member| {
            const tuple = declarationTuple(&tree, "Client", member);
            if (!std.mem.eql(u8, tuple.kind, "fn")) continue;
            if (std.mem.eql(u8, tuple.name, proof.receiver)) receiver_node = member;
            if (std.mem.eql(u8, tuple.name, proof.funnel)) funnel_node = member;
        }
        const receiver = receiver_node orelse return error.TestUnexpectedResult;
        if (!std.mem.eql(u8, proof.receiver, proof.funnel)) {
            const delegation = nodeCallToken(&tree, receiver, "self", proof.funnel) orelse
                return error.TestUnexpectedResult;
            try expectNoUnlistedSelfFieldBefore(&tree, receiver, delegation, &.{});
            try std.testing.expectEqual(@as(usize, 1), tokenBraceDepthAt(&tree, receiver, delegation));
            try std.testing.expectEqual(@as(usize, 1), countBodySelfTokens(&tree, receiver));
        }
        const gate_token = nodeCallToken(
            &tree,
            funnel_node orelse return error.TestUnexpectedResult,
            proof.gate_prefix,
            proof.gate,
        ) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(proof.gate_depth, tokenBraceDepthAt(
            &tree,
            funnel_node.?,
            gate_token,
        ));
        if (std.mem.eql(u8, proof.gate_prefix, "self")) {
            const previous = tree.tokenSlice(gate_token - 1);
            try std.testing.expect(std.mem.eql(u8, previous, "try") or
                std.mem.eql(u8, previous, "="));
        }
        try expectNoUnlistedSelfFieldBefore(
            &tree,
            funnel_node.?,
            gate_token,
            proof.pre_gate_self_fields,
        );
        if (std.mem.eql(u8, proof.gate_prefix, "self")) {
            try expectSharedGuardPrologue(
                &tree,
                funnel_node.?,
                gate_token,
                proof.gate,
                "defer",
                proof.release_prefix,
                proof.release,
                proof.release_depth,
            );
        } else {
            try expectExclusiveDeinitGuard(
                &tree,
                funnel_node.?,
                gate_token,
                proof.gate_prefix,
                proof.gate,
                proof.release_prefix,
                proof.release,
                proof.release_depth,
            );
        }
    }
    try expectTrustedClientGuardChain(allocator, source);
}

fn expectExclusiveDeinitGuard(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    gate_token: std.zig.Ast.TokenIndex,
    gate_prefix: []const u8,
    gate: []const u8,
    release_prefix: []const u8,
    release: []const u8,
    release_depth: usize,
) !void {
    if (!std.mem.eql(u8, gate_prefix, "fence") or
        !std.mem.eql(u8, gate, "tryAcquireExclusive") or
        !std.mem.eql(u8, release_prefix, "fence") or
        !std.mem.eql(u8, release, "abortExclusive"))
        return error.TestUnexpectedResult;
    const acquire = [_][]const u8{
        "fence", ".", "tryAcquireExclusive",        "(", "@intFromPtr", "(", "self", ")", ",",
        "self",  ".", "operation_fence_generation", ")",
    };
    try expectTokensAt(tree, gate_token, &acquire);
    const close_paren = matchingCloseParen(tree, node, gate_token + 3) orelse
        return error.TestUnexpectedResult;
    const acquire_tail = [_][]const u8{
        "catch", "return", "false", ";", "operation_fence_exclusive", "=", "true", ";",
    };
    try expectTokensAt(tree, close_paren + 1, &acquire_tail);

    const abort = nodeCallTokenAfter(
        tree,
        node,
        release_prefix,
        release,
        close_paren + 1,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(release_depth, tokenBraceDepthAt(tree, node, abort));
    const defer_token = findTokenAfter(tree, node, close_paren + 1, "defer") orelse
        return error.TestUnexpectedResult;
    const acquire_to_defer = [_][]const u8{
        "catch", "return", "false",  ";",     "operation_fence_exclusive", "=", "true",                       ";",
        "}",     "else",   "if",     "(",     "self",                      ".", "operation_fence_generation", "!=",
        "0",     ")",      "return", "false", ";",
    };
    try expectTokensAt(tree, close_paren + 1, &acquire_to_defer);
    try std.testing.expectEqual(
        close_paren + 1 + @as(std.zig.Ast.TokenIndex, @intCast(acquire_to_defer.len)),
        defer_token,
    );
    const defer_prefix = [_][]const u8{
        "defer",           "if", "(", "operation_fence_exclusive", ")",  "{", "const", "fence", "=",
        "operation_fence", ".",  "?", ";",                         "if", "(", "!",
    };
    try expectTokensAt(tree, defer_token, &defer_prefix);
    try std.testing.expectEqual(
        defer_token + @as(std.zig.Ast.TokenIndex, @intCast(defer_prefix.len)),
        abort,
    );
    const abort_call = [_][]const u8{
        "fence", ".", "abortExclusive",             "(", "@intFromPtr", "(",      "self", ")",                                              ",",
        "self",  ".", "operation_fence_generation", ")", ")",           "@panic", "(",    "\"Client deinit operation fence abort failed\"", ")",
        ";",     "}", ";",
    };
    try expectTokensAt(tree, abort, &abort_call);

    const commit = nodeCallTokenAfter(
        tree,
        node,
        "fence",
        "commitExclusiveTerminal",
        abort + 1,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), tokenBraceDepthAt(tree, node, commit));
    try std.testing.expectEqual(@as(usize, 1), countPrefixedMemberCalls(
        tree,
        node,
        "fence",
        "commitExclusiveTerminal",
    ));
    const finish = nodeCallTokenAfter(
        tree,
        node,
        "self",
        "finishDeinitGraph",
        abort + 1,
    ) orelse return error.TestUnexpectedResult;
    const terminal_prefix = [_][]const u8{
        "self",  ".",                          "finishDeinitGraph", "(",                          ")", ";",
        "const", "client_addr",                "=",                 "@intFromPtr",                "(", "self",
        ")",     ";",                          "const",             "operation_fence_generation", "=", "self",
        ".",     "operation_fence_generation", ";",                 "if",                         "(", "operation_fence",
        ")",     "|",                          "fence",             "|",                          "{", "if",
        "(",     "!",
    };
    try expectTokensAt(tree, finish, &terminal_prefix);
    try std.testing.expectEqual(
        finish + @as(std.zig.Ast.TokenIndex, @intCast(terminal_prefix.len)),
        commit,
    );
    const commit_sequence = [_][]const u8{
        "fence",                      ".", "commitExclusiveTerminal",   "(",      "client_addr", ",",
        "operation_fence_generation", ")", ")",                         "@panic", "(",           "\"Client deinit operation fence commit failed\"",
        ")",                          ";", "operation_fence_exclusive", "=",      "false",       ";",
    };
    try expectTokensAt(tree, commit, &commit_sequence);
    const terminal_suffix = [_][]const u8{
        "}", "self", ".*", "=", "undefined", ";", "return", "true", ";", "}",
    };
    try expectTokensAt(
        tree,
        commit + @as(std.zig.Ast.TokenIndex, @intCast(commit_sequence.len)),
        &terminal_suffix,
    );
    try expectExclusiveLatchAssignments(tree, node);
}

fn expectExclusiveLatchAssignments(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) !void {
    var assignment_count: usize = 0;
    var true_count: usize = 0;
    var false_count: usize = 0;
    var use_count: usize = 0;
    var condition_count: usize = 0;
    var token = functionBodyStart(tree, node) orelse return error.TestUnexpectedResult;
    while (token + 2 <= tree.lastToken(node)) : (token += 1) {
        if (!std.mem.eql(u8, tree.tokenSlice(token), "operation_fence_exclusive")) continue;
        use_count += 1;
        if (std.mem.eql(u8, tree.tokenSlice(token + 1), "=")) {
            assignment_count += 1;
            true_count += @intFromBool(std.mem.eql(u8, tree.tokenSlice(token + 2), "true"));
            false_count += @intFromBool(std.mem.eql(u8, tree.tokenSlice(token + 2), "false"));
            continue;
        }
        const exact_condition = token >= 1 and
            std.mem.eql(u8, tree.tokenSlice(token - 1), "(") and
            std.mem.eql(u8, tree.tokenSlice(token + 1), ")");
        if (!exact_condition) return error.TestUnexpectedResult;
        condition_count += 1;
    }
    // The declaration initializes false, acquire arms true, and terminal commit disarms false.
    try std.testing.expectEqual(@as(usize, 3), assignment_count);
    try std.testing.expectEqual(@as(usize, 1), true_count);
    try std.testing.expectEqual(@as(usize, 2), false_count);
    try std.testing.expectEqual(@as(usize, 1), condition_count);
    try std.testing.expectEqual(@as(usize, 4), use_count);
}

fn countPrefixedMemberCalls(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    prefix: []const u8,
    member: []const u8,
) usize {
    var count: usize = 0;
    var token = functionBodyStart(tree, node) orelse return 0;
    while (token + 3 <= tree.lastToken(node)) : (token += 1) {
        if (std.mem.eql(u8, tree.tokenSlice(token), prefix) and
            std.mem.eql(u8, tree.tokenSlice(token + 1), ".") and
            std.mem.eql(u8, tree.tokenSlice(token + 2), member) and
            std.mem.eql(u8, tree.tokenSlice(token + 3), "("))
        {
            count += 1;
        }
    }
    return count;
}

fn expectSharedGuardPrologue(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    gate_token: std.zig.Ast.TokenIndex,
    gate: []const u8,
    release_keyword: []const u8,
    release_prefix: []const u8,
    release: []const u8,
    release_depth: usize,
) !void {
    const has_try = std.mem.eql(u8, tree.tokenSlice(gate_token - 1), "try");
    const start = gate_token - @as(std.zig.Ast.TokenIndex, if (has_try) 4 else 3);
    const prefix = if (has_try)
        [_][]const u8{ "const", "operation_fence_held", "=", "try" }
    else
        [_][]const u8{ "const", "operation_fence_held", "=", "self" };
    for (prefix, 0..) |wanted, index|
        if (!std.mem.eql(u8, wanted, tree.tokenSlice(start + @as(std.zig.Ast.TokenIndex, @intCast(index)))))
            return error.TestUnexpectedResult;
    if (has_try and !std.mem.eql(u8, "self", tree.tokenSlice(gate_token)))
        return error.TestUnexpectedResult;
    if (!std.mem.eql(u8, gate, tree.tokenSlice(gate_token + 2)) or
        tokenBraceDepthAt(tree, node, start) != 1)
        return error.TestUnexpectedResult;

    const close_paren = matchingCloseParen(tree, node, gate_token + 3) orelse
        return error.TestUnexpectedResult;
    if (has_try) {
        if (!std.mem.eql(u8, tree.tokenSlice(close_paren + 1), ";"))
            return error.TestUnexpectedResult;
    } else {
        var suffix = close_paren + 1;
        if (!std.mem.eql(u8, tree.tokenSlice(suffix), "catch"))
            return error.TestUnexpectedResult;
        suffix += 1;
        if (std.mem.eql(u8, tree.tokenSlice(suffix), "|")) {
            suffix += 1;
            if (std.mem.eql(u8, tree.tokenSlice(suffix), "|"))
                return error.TestUnexpectedResult;
            while (!std.mem.eql(u8, tree.tokenSlice(suffix), "|")) : (suffix += 1)
                if (suffix >= tree.lastToken(node)) return error.TestUnexpectedResult;
            suffix += 1;
        }
        if (!std.mem.eql(u8, tree.tokenSlice(suffix), "return"))
            return error.TestUnexpectedResult;
        var returned = suffix + 1;
        while (returned <= tree.lastToken(node) and
            !std.mem.eql(u8, tree.tokenSlice(returned), ";")) : (returned += 1)
        {
            if (std.mem.eql(u8, tree.tokenSlice(returned), "self"))
                return error.TestUnexpectedResult;
        }
    }

    var statement_end = gate_token;
    while (statement_end <= tree.lastToken(node)) : (statement_end += 1)
        if (std.mem.eql(u8, tree.tokenSlice(statement_end), ";") and
            tokenBraceDepthAt(tree, node, statement_end) == 1) break;
    if (!has_try) {
        var returned = close_paren + 1;
        while (returned < statement_end) : (returned += 1)
            if (std.mem.eql(u8, tree.tokenSlice(returned), "self"))
                return error.TestUnexpectedResult;
    }
    const expected = [_][]const u8{
        release_keyword, "if", "(", "operation_fence_held", ")", release_prefix, ".",
        release,         "(",  ")", ";",
    };
    for (expected, 0..) |wanted, index|
        if (!std.mem.eql(u8, wanted, tree.tokenSlice(
            statement_end + 1 + @as(std.zig.Ast.TokenIndex, @intCast(index)),
        ))) return error.TestUnexpectedResult;
    const release_token = nodeCallTokenAfter(
        tree,
        node,
        release_prefix,
        release,
        statement_end + 1,
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(release_depth, tokenBraceDepthAt(tree, node, release_token));
}

fn syntheticSharedGuardValid(source: [:0]const u8) bool {
    checkSyntheticSharedGuard(source) catch return false;
    return true;
}

fn checkSyntheticSharedGuard(source: [:0]const u8) !void {
    const allocator = std.testing.allocator;
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse
        return error.TestUnexpectedResult;
    var method: ?std.zig.Ast.Node.Index = null;
    for (members) |member| {
        const tuple = declarationTuple(&tree, "Client", member);
        if (std.mem.eql(u8, tuple.name, "sample")) method = member;
    }
    const node = method orelse return error.TestUnexpectedResult;
    const gate = nodeCallToken(&tree, node, "self", "ensureUsable") orelse
        return error.TestUnexpectedResult;
    try expectNoUnlistedSelfFieldBefore(&tree, node, gate, &.{});
    try expectSharedGuardPrologue(
        &tree,
        node,
        gate,
        "ensureUsable",
        "defer",
        "self",
        "endPublicMutation",
        1,
    );
}

fn expectTrustedClientGuardChain(allocator: std.mem.Allocator, source: [:0]const u8) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse
        return error.TestUnexpectedResult;
    const require_blocking = findContainerMethod(&tree, members, "Client", "requireBlockingMode") orelse
        return error.TestUnexpectedResult;
    const ensure_usable = findContainerMethod(&tree, members, "Client", "ensureUsable") orelse
        return error.TestUnexpectedResult;
    const begin_mutation = findContainerMethod(&tree, members, "Client", "beginPublicMutation") orelse
        return error.TestUnexpectedResult;
    const end_mutation = findContainerMethod(&tree, members, "Client", "endPublicMutation") orelse
        return error.TestUnexpectedResult;
    try expectTrustedSharedGuard(&tree, require_blocking, "ensureUsable");
    try expectOnlySelfMembers(&tree, require_blocking, &.{ "ensureUsable", "endPublicMutation", "io_mode" }, &.{});
    try expectHeldCapabilityReturn(&tree, require_blocking);
    try expectTrustedSharedGuard(&tree, ensure_usable, "beginPublicMutation");
    try expectOnlySelfMembers(
        &tree,
        ensure_usable,
        &.{ "beginPublicMutation", "endPublicMutation", "ownership", "unusable" },
        &.{"checkedAllocatorReentry"},
    );
    try expectHeldCapabilityReturn(&tree, ensure_usable);
    try expectTrustedBeginPublicMutation(&tree, begin_mutation);
    try expectTrustedEndPublicMutation(&tree, end_mutation);
}

fn expectTrustedSharedGuard(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    gate_name: []const u8,
) !void {
    const gate = nodeCallToken(tree, node, "self", gate_name) orelse
        return error.TestUnexpectedResult;
    try expectNoUnlistedSelfFieldBefore(tree, node, gate, &.{});
    try expectSharedGuardPrologue(
        tree,
        node,
        gate,
        gate_name,
        "errdefer",
        "self",
        "endPublicMutation",
        1,
    );
    try std.testing.expectEqual(@as(usize, 1), countSelfMemberUses(tree, node, gate_name));
    try std.testing.expectEqual(@as(usize, 1), countSelfMemberUses(tree, node, "endPublicMutation"));
    try expectNonErrorReturnsHeld(tree, node);
}

fn expectNonErrorReturnsHeld(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) !void {
    var token = functionBodyStart(tree, node) orelse return error.TestUnexpectedResult;
    while (token + 1 <= tree.lastToken(node)) : (token += 1) {
        if (!std.mem.eql(u8, tree.tokenSlice(token), "return")) continue;
        const next = tree.tokenSlice(token + 1);
        if (std.mem.eql(u8, next, "error")) continue;
        if (!std.mem.eql(u8, next, "operation_fence_held"))
            return error.TestUnexpectedResult;
    }
}

fn countSelfMemberUses(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    member: []const u8,
) usize {
    var count: usize = 0;
    var token = functionBodyStart(tree, node) orelse return 0;
    while (token + 2 <= tree.lastToken(node)) : (token += 1) {
        if (std.mem.eql(u8, tree.tokenSlice(token), "self") and
            std.mem.eql(u8, tree.tokenSlice(token + 1), ".") and
            std.mem.eql(u8, tree.tokenSlice(token + 2), member))
        {
            count += 1;
        }
    }
    return count;
}

fn expectTrustedBeginPublicMutation(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) !void {
    const gate = nodeCallToken(tree, node, "fence", "tryEnterShared") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), tokenBraceDepthAt(tree, node, gate));
    const body_start = functionBodyStart(tree, node) orelse return error.TestUnexpectedResult;
    const prefix = [_][]const u8{
        "if",                                           "(",                "self",                                  ".",               "prepared_request_execution_lease_addr", "!=", "0",                                               "or",
        "self",                                         ".",                "prepared_request_execution_fence_addr", "!=",              "0",                                     "or", "self",                                            ".",
        "prepared_request_execution_fence_incarnation", "!=",               "0",                                     "or",              "self",                                  ".",  "prepared_request_execution_fence_lease_identity", "!=",
        "0",                                            "or",               "self",                                  ".",               "prepared_request_execution_fence_mode", "!=", ".",                                               "unbound",
        ")",                                            "return",           "error",                                 ".",               "AdminBusy",                             ";",  "const",                                           "fence",
        "=",                                            "self",             ".",                                     "operation_fence", "orelse",                                "{",  "if",                                              "(",
        "self",                                         ".",                "operation_fence_generation",            "!=",              "0",                                     ")",  "return",                                          "error",
        ".",                                            "ConnectionClosed", ";",                                     "return",          "false",                                 ";",  "}",                                               ";",
    };
    try expectTokensAt(tree, body_start + 1, &prefix);
    try std.testing.expectEqual(body_start + 1 + prefix.len, gate);
    const acquire = [_][]const u8{
        "fence", ".", "tryEnterShared",             "(", "@intFromPtr", "(", "self", ")", ",",
        "self",  ".", "operation_fence_generation", ")",
    };
    try expectTokensAt(tree, gate, &acquire);
    const close_paren = matchingCloseParen(tree, node, gate + 3) orelse
        return error.TestUnexpectedResult;
    const suffix = [_][]const u8{
        "catch",     "|", "err",              "|", "return",       "switch", "(",               "err",  ")",            "{",
        "error",     ".", "AdminBusy",        ",", "error",        ".",      "CounterOverflow", "=>",   "error",        ".",
        "AdminBusy", ",", "error",            ".", "InvalidOwner", ",",      "error",           ".",    "InvalidState", "=>",
        "error",     ".", "ConnectionClosed", ",", "}",            ";",      "return",          "true", ";",
    };
    try expectTokensAt(tree, close_paren + 1, &suffix);
    try std.testing.expectEqualStrings("}", tree.tokenSlice(
        close_paren + 1 + @as(std.zig.Ast.TokenIndex, @intCast(suffix.len)),
    ));
}

fn expectTrustedEndPublicMutation(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) !void {
    const body_start = functionBodyStart(tree, node) orelse return error.TestUnexpectedResult;
    const body = [_][]const u8{
        "const",                                        "fence",       "=",      "self", ".",                                                "operation_fence", "orelse", "@panic", "(",
        "\"bound Client operation fence disappeared\"", ")",           ";",      "if",   "(",                                                "!",               "fence",  ".",      "leaveShared",
        "(",                                            "@intFromPtr", "(",      "self", ")",                                                ",",               "self",   ".",      "operation_fence_generation",
        ")",                                            ")",           "@panic", "(",    "\"Client operation fence shared release failed\"", ")",               ";",
    };
    try expectTokensAt(tree, body_start + 1, &body);
    try std.testing.expectEqualStrings("}", tree.tokenSlice(
        body_start + 1 + @as(std.zig.Ast.TokenIndex, @intCast(body.len)),
    ));
}

fn expectHeldCapabilityReturn(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) !void {
    var matches: usize = 0;
    var token = functionBodyStart(tree, node) orelse return error.TestUnexpectedResult;
    while (token + 2 <= tree.lastToken(node)) : (token += 1) {
        if (tokenBraceDepthAt(tree, node, token) == 1 and
            std.mem.eql(u8, tree.tokenSlice(token), "return") and
            std.mem.eql(u8, tree.tokenSlice(token + 1), "operation_fence_held") and
            std.mem.eql(u8, tree.tokenSlice(token + 2), ";"))
        {
            matches += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), matches);
}

fn expectOnlySelfMembers(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    allowed: []const []const u8,
    allowed_bare_calls: []const []const u8,
) !void {
    var token = functionBodyStart(tree, node) orelse return error.TestUnexpectedResult;
    while (token + 2 <= tree.lastToken(node)) : (token += 1) {
        if (!std.mem.eql(u8, tree.tokenSlice(token), "self")) continue;
        if (!std.mem.eql(u8, tree.tokenSlice(token + 1), ".")) {
            var admitted_bare = token >= 2 and std.mem.eql(u8, tree.tokenSlice(token - 1), "(");
            if (admitted_bare) {
                admitted_bare = false;
                for (allowed_bare_calls) |name| {
                    admitted_bare = admitted_bare or std.mem.eql(u8, name, tree.tokenSlice(token - 2));
                }
            }
            if (!admitted_bare) return error.TestUnexpectedResult;
            continue;
        }
        var admitted = false;
        for (allowed) |name| {
            admitted = admitted or std.mem.eql(u8, name, tree.tokenSlice(token + 2));
        }
        if (!admitted) return error.TestUnexpectedResult;
    }
}

fn expectTokensAt(
    tree: *const std.zig.Ast,
    start: std.zig.Ast.TokenIndex,
    expected: []const []const u8,
) !void {
    for (expected, 0..) |wanted, index|
        if (!std.mem.eql(u8, wanted, tree.tokenSlice(
            start + @as(std.zig.Ast.TokenIndex, @intCast(index)),
        ))) return error.TestUnexpectedResult;
}

fn functionBodyStart(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
) ?std.zig.Ast.TokenIndex {
    var token = tree.firstToken(node);
    while (token <= tree.lastToken(node)) : (token += 1)
        if (std.mem.eql(u8, tree.tokenSlice(token), "{")) return token;
    return null;
}

fn syntheticTrustedSharedGuardValid(
    source: [:0]const u8,
    method_name: []const u8,
    gate_name: []const u8,
) bool {
    const allocator = std.testing.allocator;
    var tree = std.zig.Ast.parse(allocator, source, .zig) catch return false;
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse return false;
    const node = findContainerMethod(&tree, members, "Client", method_name) orelse return false;
    expectTrustedSharedGuard(&tree, node, gate_name) catch return false;
    return true;
}

fn syntheticDelegateValid(source: [:0]const u8) bool {
    const allocator = std.testing.allocator;
    var tree = std.zig.Ast.parse(allocator, source, .zig) catch return false;
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse return false;
    const node = findContainerMethod(&tree, members, "Client", "sample") orelse return false;
    const call = nodeCallToken(&tree, node, "self", "funnel") orelse return false;
    if (tokenBraceDepthAt(&tree, node, call) != 1) return false;
    return countBodySelfTokens(&tree, node) == 1;
}

fn syntheticTrustedLeafValid(source: [:0]const u8, method_name: []const u8) bool {
    const allocator = std.testing.allocator;
    var tree = std.zig.Ast.parse(allocator, source, .zig) catch return false;
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse return false;
    const node = findContainerMethod(&tree, members, "Client", method_name) orelse return false;
    if (std.mem.eql(u8, method_name, "beginPublicMutation")) {
        expectTrustedBeginPublicMutation(&tree, node) catch return false;
    } else if (std.mem.eql(u8, method_name, "endPublicMutation")) {
        expectTrustedEndPublicMutation(&tree, node) catch return false;
    } else return false;
    return true;
}

fn syntheticExclusiveGuardValid(source: [:0]const u8) bool {
    const allocator = std.testing.allocator;
    var tree = std.zig.Ast.parse(allocator, source, .zig) catch return false;
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, "Client") orelse return false;
    const node = findContainerMethod(&tree, members, "Client", "tryDeinit") orelse return false;
    const gate = nodeCallToken(&tree, node, "fence", "tryAcquireExclusive") orelse return false;
    expectExclusiveDeinitGuard(
        &tree,
        node,
        gate,
        "fence",
        "tryAcquireExclusive",
        "fence",
        "abortExclusive",
        2,
    ) catch return false;
    return true;
}

fn findContainerMethod(
    tree: *const std.zig.Ast,
    members: []const std.zig.Ast.Node.Index,
    container_name: []const u8,
    method_name: []const u8,
) ?std.zig.Ast.Node.Index {
    var found: ?std.zig.Ast.Node.Index = null;
    for (members) |member| {
        const tuple = declarationTuple(tree, container_name, member);
        if (!std.mem.eql(u8, tuple.kind, "fn") or
            !std.mem.eql(u8, tuple.name, method_name)) continue;
        if (found != null) return null;
        found = member;
    }
    return found;
}

fn matchingCloseParen(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    open: std.zig.Ast.TokenIndex,
) ?std.zig.Ast.TokenIndex {
    if (!std.mem.eql(u8, tree.tokenSlice(open), "(")) return null;
    var depth: usize = 0;
    var token = open;
    while (token <= tree.lastToken(node)) : (token += 1) {
        const slice = tree.tokenSlice(token);
        if (std.mem.eql(u8, slice, "(")) depth += 1 else if (std.mem.eql(u8, slice, ")")) {
            depth -= 1;
            if (depth == 0) return token;
        }
    }
    return null;
}

fn countBodySelfTokens(tree: *const std.zig.Ast, node: std.zig.Ast.Node.Index) usize {
    var count: usize = 0;
    var token = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (token <= last and !std.mem.eql(u8, tree.tokenSlice(token), "{")) : (token += 1) {}
    while (token <= last) : (token += 1)
        count += @intFromBool(std.mem.eql(u8, tree.tokenSlice(token), "self"));
    return count;
}

fn nodeCallTokenAfter(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    prefix: []const u8,
    callee: []const u8,
    start: std.zig.Ast.TokenIndex,
) ?std.zig.Ast.TokenIndex {
    var token = @max(tree.firstToken(node), start);
    const last = tree.lastToken(node);
    while (token + 3 <= last) : (token += 1)
        if (std.mem.eql(u8, tree.tokenSlice(token), prefix) and
            std.mem.eql(u8, tree.tokenSlice(token + 1), ".") and
            std.mem.eql(u8, tree.tokenSlice(token + 2), callee) and
            std.mem.eql(u8, tree.tokenSlice(token + 3), "(")) return token;
    return null;
}

fn findTokenAfter(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    start: std.zig.Ast.TokenIndex,
    wanted: []const u8,
) ?std.zig.Ast.TokenIndex {
    var token = @max(tree.firstToken(node), start);
    while (token <= tree.lastToken(node)) : (token += 1)
        if (std.mem.eql(u8, tree.tokenSlice(token), wanted)) return token;
    return null;
}

fn tokenRangeContains(
    tree: *const std.zig.Ast,
    first: std.zig.Ast.TokenIndex,
    last: std.zig.Ast.TokenIndex,
    wanted: []const u8,
) bool {
    var token = first;
    while (token < last) : (token += 1)
        if (std.mem.eql(u8, tree.tokenSlice(token), wanted)) return true;
    return false;
}

fn tokenBraceDepthAt(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    target: std.zig.Ast.TokenIndex,
) usize {
    var depth: usize = 0;
    var token = tree.firstToken(node);
    while (token < target) : (token += 1) {
        const slice = tree.tokenSlice(token);
        if (std.mem.eql(u8, slice, "{")) depth += 1 else if (std.mem.eql(u8, slice, "}")) depth -= 1;
    }
    return depth;
}

fn nodeHasCallTokens(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    prefix: ?[]const u8,
    callee: []const u8,
) bool {
    return nodeCallToken(tree, node, prefix, callee) != null;
}

fn nodeCallToken(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    prefix: ?[]const u8,
    callee: []const u8,
) ?std.zig.Ast.TokenIndex {
    var token = tree.firstToken(node);
    const last = tree.lastToken(node);
    while (token <= last) : (token += 1) {
        if (prefix) |wanted_prefix| {
            if (token + 3 > last or
                !std.mem.eql(u8, tree.tokenSlice(token), wanted_prefix) or
                !std.mem.eql(u8, tree.tokenSlice(token + 1), ".") or
                !std.mem.eql(u8, tree.tokenSlice(token + 2), callee) or
                !std.mem.eql(u8, tree.tokenSlice(token + 3), "("))
                continue;
            return token;
        }
        if (token + 1 <= last and
            std.mem.eql(u8, tree.tokenSlice(token), callee) and
            std.mem.eql(u8, tree.tokenSlice(token + 1), "("))
            return token;
    }
    return null;
}

fn expectNoUnlistedSelfFieldBefore(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    gate_token: std.zig.Ast.TokenIndex,
    allowed: []const []const u8,
) !void {
    var token = tree.firstToken(node);
    while (token < gate_token and !std.mem.eql(u8, tree.tokenSlice(token), "{")) : (token += 1) {}
    while (token + 2 < gate_token) : (token += 1) {
        if (!std.mem.eql(u8, tree.tokenSlice(token), "self")) continue;
        if (std.mem.eql(u8, tree.tokenSlice(token + 1), ".")) {
            const field = tree.tokenSlice(token + 2);
            var admitted = false;
            for (allowed) |name| admitted = admitted or std.mem.eql(u8, name, field);
            try std.testing.expect(admitted);
            continue;
        }
        const final_address_identity = token >= 2 and
            std.mem.eql(u8, tree.tokenSlice(token - 1), "(") and
            std.mem.eql(u8, tree.tokenSlice(token - 2), "@intFromPtr");
        try std.testing.expect(allowed.len != 0 and final_address_identity);
    }
}

fn expectContainerMethodMarkersInOrder(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    container_name: []const u8,
    method_name: []const u8,
    markers: []const []const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, container_name) orelse
        return error.TestUnexpectedResult;
    var method_node: ?std.zig.Ast.Node.Index = null;
    for (members) |member| {
        const tuple = declarationTuple(&tree, container_name, member);
        if (std.mem.eql(u8, tuple.kind, "fn") and std.mem.eql(u8, tuple.name, method_name)) {
            if (method_node != null) return error.TestUnexpectedResult;
            method_node = member;
        }
    }
    const method = method_node orelse return error.TestUnexpectedResult;
    var cursor = tree.firstToken(method);
    for (markers) |marker| {
        const marker_tokens = try tokenizeMarker(allocator, marker);
        defer allocator.free(marker_tokens);
        const found = findTreeTokenSequence(
            &tree,
            cursor,
            tree.lastToken(method),
            marker,
            marker_tokens,
        ) orelse
            return error.TestUnexpectedResult;
        cursor = found + @as(std.zig.Ast.TokenIndex, @intCast(marker_tokens.len));
    }
}

fn expectContainerMethodMarkerCount(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    container_name: []const u8,
    method_name: []const u8,
    marker: []const u8,
    expected: usize,
) !void {
    try std.testing.expectEqual(expected, try containerMethodMarkerCount(
        allocator,
        source,
        container_name,
        method_name,
        marker,
    ));
}

fn expectOnlyDirectIdentifierReference(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    container_name: []const u8,
    method_name: []const u8,
    identifier: []const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const method = try findUniqueContainerMethod(&tree, container_name, method_name);
    var references: usize = 0;
    var token = tree.firstToken(method);
    while (token <= tree.lastToken(method)) : (token += 1) {
        if (!std.mem.eql(u8, tree.tokenSlice(token), identifier)) continue;
        references += 1;
        if (token + 1 > tree.lastToken(method) or tree.tokenTag(token + 1) != .l_paren)
            return error.TestUnexpectedResult;
    }
    try std.testing.expectEqual(@as(usize, 1), references);
}

fn expectExactMethodTokenRegion(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    container_name: []const u8,
    method_name: []const u8,
    region: []const u8,
    report_mismatch: bool,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const method = try findUniqueContainerMethod(&tree, container_name, method_name);
    const region_tokens = try tokenizeMarker(allocator, region);
    defer allocator.free(region_tokens);
    const prefix_len = @min(region_tokens.len, 6);
    const prefix = findTreeTokenSequence(
        &tree,
        tree.firstToken(method),
        tree.lastToken(method),
        region,
        region_tokens[0..prefix_len],
    ) orelse return error.TestUnexpectedResult;
    if (findTreeTokenSequence(
        &tree,
        prefix + 1,
        tree.lastToken(method),
        region,
        region_tokens[0..prefix_len],
    ) != null) return error.TestUnexpectedResult;
    for (region_tokens, 0..) |expected, offset| {
        const actual_token = prefix + @as(std.zig.Ast.TokenIndex, @intCast(offset));
        if (actual_token > tree.lastToken(method)) return error.TestUnexpectedResult;
        const actual = tree.tokenSlice(actual_token);
        const wanted = region[expected.start..expected.end];
        if (!std.mem.eql(u8, actual, wanted)) {
            if (report_mismatch) std.debug.print(
                "exact token region mismatch {s}.{s} offset={} expected={s} actual={s}\n",
                .{ container_name, method_name, offset, wanted, actual },
            );
            return error.TestUnexpectedResult;
        }
    }
}

fn findUniqueContainerMethod(
    tree: *const std.zig.Ast,
    container_name: []const u8,
    method_name: []const u8,
) !std.zig.Ast.Node.Index {
    const members = findRootContainerMembers(tree, container_name) orelse
        return error.TestUnexpectedResult;
    var method_node: ?std.zig.Ast.Node.Index = null;
    for (members) |member| {
        const tuple = declarationTuple(tree, container_name, member);
        if (!std.mem.eql(u8, tuple.kind, "fn") or
            !std.mem.eql(u8, tuple.name, method_name)) continue;
        if (method_node != null) return error.TestUnexpectedResult;
        method_node = member;
    }
    return method_node orelse error.TestUnexpectedResult;
}

fn containerMethodMarkerCount(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    container_name: []const u8,
    method_name: []const u8,
    marker: []const u8,
) !usize {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, container_name) orelse
        return error.TestUnexpectedResult;
    var method_node: ?std.zig.Ast.Node.Index = null;
    for (members) |member| {
        const tuple = declarationTuple(&tree, container_name, member);
        if (!std.mem.eql(u8, tuple.kind, "fn") or
            !std.mem.eql(u8, tuple.name, method_name)) continue;
        if (method_node != null) return error.TestUnexpectedResult;
        method_node = member;
    }
    const method = method_node orelse return error.TestUnexpectedResult;
    const marker_tokens = try tokenizeMarker(allocator, marker);
    defer allocator.free(marker_tokens);
    var count: usize = 0;
    var cursor = tree.firstToken(method);
    while (findTreeTokenSequence(
        &tree,
        cursor,
        tree.lastToken(method),
        marker,
        marker_tokens,
    )) |found| {
        count += 1;
        cursor = found + @as(std.zig.Ast.TokenIndex, @intCast(marker_tokens.len));
    }
    return count;
}

fn tokenizeMarker(allocator: std.mem.Allocator, marker: []const u8) ![]std.zig.Token.Loc {
    var tokens: std.ArrayList(std.zig.Token.Loc) = .empty;
    errdefer tokens.deinit(allocator);
    const terminated = try allocator.dupeZ(u8, marker);
    defer allocator.free(terminated);
    var tokenizer = std.zig.Tokenizer.init(terminated);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try tokens.append(allocator, token.loc);
    }
    return tokens.toOwnedSlice(allocator);
}

fn findTreeTokenSequence(
    tree: *const std.zig.Ast,
    start: std.zig.Ast.TokenIndex,
    last: std.zig.Ast.TokenIndex,
    marker: []const u8,
    marker_tokens: []const std.zig.Token.Loc,
) ?std.zig.Ast.TokenIndex {
    if (marker_tokens.len == 0) return null;
    var candidate = start;
    while (candidate <= last) : (candidate += 1) {
        if (@as(usize, @intCast(last - candidate + 1)) < marker_tokens.len) return null;
        for (marker_tokens, 0..) |expected, offset| {
            const actual = tree.tokenSlice(candidate + @as(std.zig.Ast.TokenIndex, @intCast(offset)));
            if (!std.mem.eql(u8, actual, marker[expected.start..expected.end])) break;
        } else return candidate;
    }
    return null;
}

const CallAllowance = struct { name: []const u8, count: usize };

fn expectNoUnlistedCallsBetweenMarkers(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    container_name: []const u8,
    method_name: []const u8,
    start_marker: []const u8,
    end_marker: []const u8,
    allowed: []const CallAllowance,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    const members = findRootContainerMembers(&tree, container_name) orelse
        return error.TestUnexpectedResult;
    var method_node: ?std.zig.Ast.Node.Index = null;
    for (members) |member| {
        const tuple = declarationTuple(&tree, container_name, member);
        if (!std.mem.eql(u8, tuple.kind, "fn") or
            !std.mem.eql(u8, tuple.name, method_name)) continue;
        if (method_node != null) return error.TestUnexpectedResult;
        method_node = member;
    }
    const method = method_node orelse return error.TestUnexpectedResult;
    const start_tokens = try tokenizeMarker(allocator, start_marker);
    defer allocator.free(start_tokens);
    const end_tokens = try tokenizeMarker(allocator, end_marker);
    defer allocator.free(end_tokens);
    const start = findTreeTokenSequence(
        &tree,
        tree.firstToken(method),
        tree.lastToken(method),
        start_marker,
        start_tokens,
    ) orelse return error.TestUnexpectedResult;
    const after_start = start + @as(std.zig.Ast.TokenIndex, @intCast(start_tokens.len));
    const end = findTreeTokenSequence(
        &tree,
        after_start,
        tree.lastToken(method),
        end_marker,
        end_tokens,
    ) orelse return error.TestUnexpectedResult;
    const observed = try allocator.alloc(usize, allowed.len);
    defer allocator.free(observed);
    @memset(observed, 0);
    var token = after_start;
    while (token + 1 < end) : (token += 1) {
        if (tree.tokenTag(token) != .identifier or tree.tokenTag(token + 1) != .l_paren) continue;
        const call = tree.tokenSlice(token);
        var admitted = false;
        for (allowed, 0..) |entry, index| {
            if (!std.mem.eql(u8, call, entry.name)) continue;
            observed[index] += 1;
            admitted = true;
            break;
        }
        if (!admitted) return error.TestUnexpectedResult;
    }
    for (allowed, observed) |entry, count| try std.testing.expectEqual(entry.count, count);
}

fn expectRootConstTypeAndInitializer(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    name: []const u8,
    type_name: []const u8,
    initializer: []const u8,
) !void {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    for (tree.rootDecls()) |node| {
        const variable = tree.fullVarDecl(node) orelse continue;
        if (!std.mem.eql(u8, tree.tokenSlice(variable.ast.mut_token + 1), name)) continue;
        const type_node = variable.ast.type_node.unwrap() orelse return error.TestUnexpectedResult;
        const init_node = variable.ast.init_node.unwrap() orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(type_name, nodeSource(&tree, source, type_node));
        try std.testing.expectEqualStrings(initializer, nodeSource(&tree, source, init_node));
        return;
    }
    return error.TestUnexpectedResult;
}

fn expectNestedEnum(
    tree: *const std.zig.Ast,
    node: std.zig.Ast.Node.Index,
    name: []const u8,
    fields: []const []const u8,
) !void {
    const variable = tree.fullVarDecl(node) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(name, tree.tokenSlice(variable.ast.mut_token + 1));
    const init = variable.ast.init_node.unwrap() orelse return error.TestUnexpectedResult;
    var buffer: [2]std.zig.Ast.Node.Index = undefined;
    const container = tree.fullContainerDecl(&buffer, init) orelse return error.TestUnexpectedResult;
    try expectFieldNames(tree, container.ast.members, fields);
}

fn expectTypedField(
    tree: *const std.zig.Ast,
    source: [:0]const u8,
    node: std.zig.Ast.Node.Index,
    name: []const u8,
    type_name: []const u8,
) !void {
    const field = tree.fullContainerField(node) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(name, tree.tokenSlice(field.ast.main_token));
    const type_node = field.ast.type_expr.unwrap() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(type_name, nodeSource(tree, source, type_node));
}

fn expectTypedFieldWithDefault(
    tree: *const std.zig.Ast,
    source: [:0]const u8,
    node: std.zig.Ast.Node.Index,
    name: []const u8,
    type_name: []const u8,
    initializer: []const u8,
) !void {
    const field = tree.fullContainerField(node) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(name, tree.tokenSlice(field.ast.main_token));
    const type_node = field.ast.type_expr.unwrap() orelse return error.TestUnexpectedResult;
    const value_node = field.ast.value_expr.unwrap() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(type_name, nodeSource(tree, source, type_node));
    try std.testing.expectEqualStrings(initializer, nodeSource(tree, source, value_node));
}

fn expectFieldNames(
    tree: *const std.zig.Ast,
    members: []const std.zig.Ast.Node.Index,
    expected: []const []const u8,
) !void {
    try std.testing.expectEqual(expected.len, members.len);
    for (members, expected) |member, name| {
        const tuple = declarationTuple(tree, "enum", member);
        try std.testing.expectEqualStrings("field", tuple.kind);
        try std.testing.expectEqualStrings(name, tuple.name);
    }
}

fn nodeSource(tree: *const std.zig.Ast, source: [:0]const u8, node: std.zig.Ast.Node.Index) []const u8 {
    const first = tree.tokenStart(tree.firstToken(node));
    const last_token = tree.lastToken(node);
    return source[first .. tree.tokenStart(last_token) + tree.tokenSlice(last_token).len];
}

fn checkDirectory(
    allocator: std.mem.Allocator,
    rule: Rule,
    dir_path: []const u8,
    violations: *usize,
) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
        defer allocator.free(path);

        try checkFile(allocator, rule, path, violations);
    }
}

// 스캐너용 POSIX walker는 정본 1개 + 복제본 3개다. Zig가 모듈 루트 밖 상대 `@import`를 막아서
// (`import of file outside module path`) 하위 디렉터리 테스트가 `../support/`에 닿지 못하기 때문이다.
// 복제는 **주석으로 부탁하면 반드시 갈라진다** — 이 코드베이스가 `src/width.zig`↔`coretext_smoke.m`
// 미러를 테스트로 못박는 것과 같은 이유로, 여기서 본문 동일성을 게이트한다. 정본을 고치면 이 테스트가
// 복제본을 함께 고치라고 알려 준다.
test "boundary: posix_walk 복제본 3개가 정본과 같은 본문을 유지한다" {
    const allocator = std.testing.allocator;
    const canonical = try readZigFileZ(allocator, "tests/support/posix_walk.zig");
    defer allocator.free(canonical);
    // 정본은 파일 문서주석(`//!`)으로 시작하고, 복제본은 "복제본이다" 헤더로 시작한다.
    // 헤더는 서로 다른 것이 정상이므로 **첫 코드 줄부터** 비교한다.
    const marker = "const std = @import(\"std\");";
    const canonical_body = canonical[std.mem.indexOf(u8, canonical, marker) orelse
        return error.TestUnexpectedResult ..];

    for ([_][]const u8{
        "tests/boundary/posix_walk.zig",
        "tests/config_docs/posix_walk.zig",
        "tests/doc_links/posix_walk.zig",
    }) |path| {
        const copy = try readZigFileZ(allocator, path);
        defer allocator.free(copy);
        const copy_body = copy[std.mem.indexOf(u8, copy, marker) orelse
            return error.TestUnexpectedResult ..];
        if (!std.mem.eql(u8, canonical_body, copy_body)) {
            std.debug.print(
                "\n{s}가 정본(tests/support/posix_walk.zig)과 갈라졌다 — 정본 본문을 그대로 복사한다.\n",
                .{path},
            );
            return error.TestExpectedEqual;
        }
    }
}

const max_boundary_source_bytes = 8 * 1024 * 1024;

// .zig 소스를 sentinel 종료 버퍼([:0]u8 — std.zig.Tokenizer가 요구)로 읽는다. 호출자가 free한다.
// 이 scanner는 repo 소스만 읽되 메모리 사용 상한을 유지한다. app_session.zig가 4 MiB를 넘어
// 기존 제한에 걸렸으므로 8 MiB까지 허용한다. 더 큰 파일은 scanner가 조용히 일부만 검사하지 않고 실패한다.
fn readZigFileZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_boundary_source_bytes)) catch |err| {
        std.debug.print("boundary scan could not read {s}: {s}\n", .{ path, @errorName(err) });
        return err;
    };
    defer allocator.free(text);
    return allocator.dupeZ(u8, text);
}

fn readOptionalZigFileZ(allocator: std.mem.Allocator, path: []const u8) !?[:0]u8 {
    const text = std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(max_boundary_source_bytes),
    ) catch |err| switch (err) {
        error.FileNotFound => return null,
        else => return err,
    };
    defer allocator.free(text);
    return @as(?[:0]u8, try allocator.dupeZ(u8, text));
}

fn checkFile(
    allocator: std.mem.Allocator,
    rule: Rule,
    path: []const u8,
    violations: *usize,
) !void {
    const text_z = try readZigFileZ(allocator, path);
    defer allocator.free(text_z);
    scanImports(text_z, rule, path, violations);
}

// @import 경로를 훑어 금지 레이어 import를 센다. 단순 부분문자열 스캔이 아니라
// std.zig.Tokenizer로 토큰화해 실제 `@import` `(` string_literal 시퀀스만 import로 본다.
// 그래야 (1) `@import`와 `(` 사이에 주석·개행·공백이 있어도 잡고(부분문자열 스캐너는
// `@import // 주석\n(...)`을 놓쳤다), (2) 주석이나 문자열 리터럴 안에 적힌
// `@import("../x")`를 오탐하지 않는다. 토크나이저는 일반 주석을 토큰으로 내보내지 않고,
// doc 주석·일반/multiline 문자열은 builtin이 아닌 단일 토큰으로 내보내므로 둘 다 자연히 처리된다.
fn scanImports(text: [:0]const u8, rule: Rule, path: []const u8, violations: *usize) void {
    scanImportsWithDiagnostics(text, rule, path, violations, true);
}

fn scanImportsQuiet(text: [:0]const u8, rule: Rule, path: []const u8, violations: *usize) void {
    scanImportsWithDiagnostics(text, rule, path, violations, false);
}

fn scanImportsWithDiagnostics(
    text: [:0]const u8,
    rule: Rule,
    path: []const u8,
    violations: *usize,
    emit_diagnostics: bool,
) void {
    var tokenizer = std.zig.Tokenizer.init(text);
    // `@import` / `(` / string_literal 가 연속으로 나올 때만 실제 import로 본다.
    var saw_import = false;
    var saw_paren = false;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .builtin => {
                saw_import = std.mem.eql(u8, text[token.loc.start..token.loc.end], "@import");
                saw_paren = false;
            },
            .l_paren => {
                saw_paren = saw_import;
                saw_import = false;
            },
            .string_literal => {
                if (saw_paren) {
                    // string_literal 토큰은 따옴표를 포함한다("..."). import 경로는
                    // 이스케이프 없는 단순 경로라 양끝 따옴표만 벗긴다.
                    const raw = text[token.loc.start..token.loc.end];
                    const import_path = raw[1 .. raw.len - 1];
                    for (rule.forbidden) |forbidden| {
                        if (importTraversesLayer(import_path, forbidden)) {
                            // 실제 파일을 검사할 때만 진단을 출력한다. 아래 unit test는 일부러
                            // 금지 import fixture를 넣기 때문에, 거기서 같은 메시지를 찍으면
                            // `mise run check`가 성공해도 실패처럼 보여 triage를 방해한다.
                            if (emit_diagnostics) {
                                std.debug.print(
                                    "boundary violation: {s} ({s} layer) imports forbidden layer '{s}' via \"{s}\"\n",
                                    .{ path, rule.layer, forbidden.layer, import_path },
                                );
                            }
                            violations.* += 1;
                        }
                    }
                }
                saw_import = false;
                saw_paren = false;
            },
            else => {
                saw_import = false;
                saw_paren = false;
            },
        }
    }
}

fn importTraversesLayer(import_path: []const u8, forbidden: Forbidden) bool {
    // import 경로는 "../pty/types.zig"나 "core.zig" 같은 상대 경로다.
    var it = std.mem.splitScalar(u8, import_path, '/');
    while (it.next()) |seg| {
        // 구현 디렉터리로 진입: segment가 정확히 레이어 이름("pty", "terminal" ...).
        if (std.mem.eql(u8, seg, forbidden.layer)) return true;
        // 공개 barrel("layer.zig"): 레이어 전체 금지일 때만 위반으로 본다.
        if (!forbidden.private_only and
            std.mem.endsWith(u8, seg, ".zig") and
            std.mem.eql(u8, seg[0 .. seg.len - 4], forbidden.layer)) return true;
    }
    return false;
}

test "importTraversesLayer distinguishes barrel from private implementation" {
    // 레이어 전체 금지: barrel과 구현 디렉터리 둘 다 잡는다.
    try std.testing.expect(importTraversesLayer("../pty/types.zig", .{ .layer = "pty" }));
    try std.testing.expect(importTraversesLayer("../pty.zig", .{ .layer = "pty" }));
    // private 구현만 금지: 구현 디렉터리는 잡고 공개 barrel은 허용한다.
    try std.testing.expect(importTraversesLayer("../terminal/core.zig", .{ .layer = "terminal", .private_only = true }));
    try std.testing.expect(!importTraversesLayer("../terminal.zig", .{ .layer = "terminal", .private_only = true }));
    // 무관한 import는 잡지 않는다.
    try std.testing.expect(!importTraversesLayer("core.zig", .{ .layer = "pty" }));
    try std.testing.expect(!importTraversesLayer("std", .{ .layer = "renderer" }));
}

test "boundary rules enforce documented facade contracts (terminal↛session/plugin, plugin↛renderer)" {
    // 이 테스트가 증명하는 것: facade-contracts.md의 "몰라야 하는 것" 경계 중 예전엔 미강제였던 항목을 rules가
    // 실제로 잡는다는 것 — 규칙 추가가 no-op(영원히 안 걸림)이 아니라 위반 fixture에서 정확히 발화한다. 실제 소스는
    // 위반이 0이라(top의 "facade layers..." 테스트가 전 파일 스캔) 여기선 fixture 문자열로 규칙 자체의 발화를 고정한다.
    const findRule = struct {
        fn run(layer: []const u8) Rule {
            for (rules) |r| {
                if (std.mem.eql(u8, r.layer, layer)) return r;
            }
            unreachable;
        }
    }.run;

    // terminal → session(workspace/tab/split이 사는 L2): 위상 역전이라 잡아야 한다.
    {
        var v: usize = 0;
        scanImportsQuiet("const w = @import(\"../session/workspace.zig\");", findRule("terminal"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // terminal → plugin: plugin runtime을 몰라야 한다.
    {
        var v: usize = 0;
        scanImportsQuiet("const p = @import(\"../plugin/registry.zig\");", findRule("terminal"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // plugin → renderer(전체 — barrel도 금지): renderer resource를 직접 받지 않는다.
    {
        var v: usize = 0;
        scanImportsQuiet("const r = @import(\"../renderer.zig\");", findRule("plugin"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
        var v2: usize = 0;
        scanImportsQuiet("const r = @import(\"../renderer/metal_frame.zig\");", findRule("plugin"), "fixture", &v2);
        try std.testing.expectEqual(@as(usize, 1), v2); // 구현부도
    }
    // 반대로 허용된 import는 여전히 통과 — terminal이 중립 top-level(color/width)·자기 모듈을 쓰는 건 정상.
    {
        var v: usize = 0;
        scanImportsQuiet("const c = @import(\"../color.zig\");\nconst w = @import(\"width.zig\");", findRule("terminal"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // plugin이 action/config facade로 상호작용하는 건 계약상 허용(pty/terminal-private/renderer만 금지) — config는 안 막힌다.
    {
        var v: usize = 0;
        scanImportsQuiet("const cfg = @import(\"../config.zig\");\nconst t = @import(\"../terminal.zig\");", findRule("plugin"), "fixture", &v);
        try std.testing.expectEqual(@as(usize, 0), v); // config·terminal 공개 barrel은 허용(terminal은 private_only 금지)
    }
}

test "scanImports catches zig fmt-clean whitespace and multi-line @import forms" {
    const rule = Rule{
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{.{ .layer = "pty" }},
    };

    // 단일행: 기존에도 잡혔다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import(\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // trailing comma 줄바꿈 형태: zig fmt --check를 통과하면서 예전 `@import("` 마커를 빠져나갔다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import(\n    \"../pty/types.zig\",\n);", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // @import 와 `(` 사이 공백.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import (\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 허용되는 import(std, 공개 barrel)는 잡지 않는다.
    {
        var v: usize = 0;
        scanImportsQuiet("const s = @import(\"std\");\nconst t = @import(\"../terminal.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}

test "scanImports tokenizes, so comments and string literals neither evade nor false-positive" {
    const rule = Rule{
        .layer = "terminal",
        .barrel = "src/terminal.zig",
        .implementation_dir = "src/terminal",
        .forbidden = &.{.{ .layer = "pty" }},
    };

    // `@import`와 `(` 사이 줄 주석: zig fmt-clean이고 유효한 Zig지만 부분문자열 스캐너는
    // 놓쳤다. 토크나이저는 주석을 건너뛰므로 실제 import로 잡아야 한다.
    {
        var v: usize = 0;
        scanImportsQuiet("const a = @import // sneaky\n    (\"../pty/types.zig\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 줄 주석 안의 금지 경로 언급: 실제 import가 아니므로 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("// historically used @import(\"../pty/types.zig\")\nconst a = @import(\"std\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // doc 주석 안의 금지 경로 언급: 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("/// see @import(\"../pty/types.zig\")\npub const a = @import(\"std\");", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // multiline 문자열 안의 금지 경로 언급: 오탐하면 안 된다.
    {
        var v: usize = 0;
        scanImportsQuiet("const s =\n    \\\\@import(\"../pty/types.zig\")\n;", rule, "test", &v);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}

// ── 중립성 가드(B): OS-특정 타입명이 중립 레이어(L1~L3) 코드에 식별자로 등장하지 않음을 강제 ──────────────────
// import 금지(위 rules)는 platform을 못 끌어오게 막지만, 어떤 중립 barrel이 OS 타입을 re-export하면 import 없이도
// 이름이 샐 수 있다. 이 가드는 그 누수를 직접 막는다 — renderer-strategy.md의 WebGPU 조건 1("L1~L3가 중립 frame만
// 소비함을 테스트로 증명")의 실제 충족이자 docs/layering-and-portability.md §8의 "Metal-by-name" 규칙이다.
// std.zig.Tokenizer로 **.identifier 토큰만** 검사하므로, 중립 계약을 설명하는 주석·문자열 안의 "Metal"/"CoreText"
// 언급은 오탐하지 않는다(주석은 토큰이 아니고 doc 주석·문자열은 별도 태그).
//
// 비범위: app은 의도적으로 섞인 레이어(pty/runtime + 중립 모델)라 스캔 안 한다 — 그 중립성은 컨벤션으로 다룬다
// (위 session 규칙 주석 참고). transitive·app 규칙 강제는 후속.

const NeutralLayer = struct { layer: []const u8, barrel: []const u8, dir: []const u8 };

const neutral_layers = [_]NeutralLayer{
    .{ .layer = "terminal", .barrel = "src/terminal.zig", .dir = "src/terminal" }, // L1 VT 코어 — 가장 순수한 중립
    .{ .layer = "renderer", .barrel = "src/renderer.zig", .dir = "src/renderer" },
    .{ .layer = "session", .barrel = "src/session.zig", .dir = "src/session" },
    .{ .layer = "chrome", .barrel = "src/chrome.zig", .dir = "src/chrome" },
};

// platform/macos가 정의·노출하는 OS 경계 타입 + 대표 OS(CoreText/CoreGraphics/AppKit/Metal) 타입명. 이 이름이
// 중립 레이어 코드에 식별자로 나타나면 OS 결합이 샌 것이다. 정확 일치라 오탐 0(전부 명백한 OS 타입명 — 부분
// 문자열·소문자 변형은 안 잡는다). 누락이 있어도 import 금지가 1차로 막으므로 이건 2차(re-export) 가드다.
const forbidden_os_type_names = [_][]const u8{
    // GPU 백엔드 런타임 타입(maru_metal_renderer — 실제 Metal API). metal_frame DTO(NativeMetalCell·MetalFrame·
    // MetalFrameBuffer·NativeMetalRasterUpload)는 §8 이주로 renderer(중립 frame 계약)가 소유하므로 더는 OS 타입
    // 가드 대상이 아니다 — 이름만 "Metal"이고 OS 의존 없는 ABI 표현이다. chrome은 import 가드(chrome→renderer 금지)로 여전히 차단.
    "MetalRenderer",
    // CoreText / CoreGraphics(제품 shaper·raster 경계 — C @cImport는 platform 전용이어야 한다).
    "CTFont",
    "CTRun",
    "CTLine",
    "CGGlyph",
    "CGFloat",
    "CGRect",
    "CGSize",
    "CGPoint",
    "CGContext",
    // AppKit / Metal(OS host·GPU 백엔드 전용).
    "NSColor",
    "NSView",
    "NSWindow",
    "NSString",
    "NSEvent",
    "MTLDevice",
    "MTLBuffer",
    "MTLTexture",
};

test "neutral layers (terminal·renderer·session·chrome) do not name OS-specific types" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;
    for (neutral_layers) |nl| {
        try checkFileForOsTypes(allocator, nl.layer, nl.barrel, &violations); // barrel(re-export 경로)
        try checkDirectoryForOsTypes(allocator, nl, &violations); // 구현부
    }
    try std.testing.expectEqual(@as(usize, 0), violations);
}

fn checkDirectoryForOsTypes(allocator: std.mem.Allocator, nl: NeutralLayer, violations: *usize) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, nl.dir, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ nl.dir, entry.path });
        defer allocator.free(path);

        try checkFileForOsTypes(allocator, nl.layer, path, violations);
    }
}

fn checkFileForOsTypes(allocator: std.mem.Allocator, layer: []const u8, path: []const u8, violations: *usize) !void {
    const text_z = try readZigFileZ(allocator, path);
    defer allocator.free(text_z);
    scanForbiddenIdentifiers(text_z, layer, path, violations, true);
}

// .identifier 토큰만 보고 forbidden_os_type_names와 정확 일치하면 위반으로 센다. 주석(토큰 아님)·doc 주석/
// 문자열(별도 태그)은 자연히 건너뛴다 — scanImports와 같은 토크나이저 규율.
fn scanForbiddenIdentifiers(text: [:0]const u8, layer: []const u8, path: []const u8, violations: *usize, emit_diagnostics: bool) void {
    var tokenizer = std.zig.Tokenizer.init(text);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        if (token.tag != .identifier) continue;
        const ident = text[token.loc.start..token.loc.end];
        for (forbidden_os_type_names) |name| {
            if (std.mem.eql(u8, ident, name)) {
                if (emit_diagnostics) {
                    std.debug.print(
                        "neutrality violation: {s} ({s} layer) names OS-specific type '{s}' (L1~L3는 중립이어야 한다)\n",
                        .{ path, layer, name },
                    );
                }
                violations.* += 1;
            }
        }
    }
}

test "scanForbiddenIdentifiers flags code identifiers but not comments or strings" {
    // 코드 식별자(qualified access의 끝 식별자 포함)로 등장하면 위반.
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("const c = shaper.CTFont;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 줄 주석 안의 언급은 오탐 아님(중립 계약 설명).
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("// CoreText shaper consumes CTFont\nconst x = 1;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // doc 주석 안의 언급도 오탐 아님.
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("/// produces CGFloat-free output\npub const x = 1;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 문자열 리터럴 안도 오탐 아님.
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("const s = \"NSView is OS-only\";", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 무관한/유사하지만 다른 식별자는 통과(정확 일치라 부분문자열 오탐 없음).
    {
        var v: usize = 0;
        scanForbiddenIdentifiers("const cell = grid.cell; const myCTFontWrapper = 0;", "renderer", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}

// ── core_mutex 직접 lock/unlock 금지 가드 ────────────────────────────────────────────────────────────────
// core_mutex(Surface 소유)는 재진입을 lock 전에 감지하는 owner-추적 래퍼(`Surface.lockCore`/`unlockCore`,
// `CoreOwner.lock`/`unlock`)로만 잡아야 한다. `core_mutex.lockUncancelable`/`.unlock` 직접 호출이 새로 들어오면
// owner 추적이 비어 재진입 안전망(docs/io-render-threading.md §6-5)이 새고, 이번 IME hang 같은 self-deadlock이
// 다시 런타임에서만 드러난다. 식별자 시퀀스 `core_mutex` `.` (`lockUncancelable`|`unlock`)를 토크나이저로 잡아
// 빌드에서 막는다 — 주석·문자열 속 언급은 토큰이 아니라 오탐 0이고, 필드 선언(`core_mutex:` 뒤가 `:`)이나
// 포인터 전달(`&x.core_mutex,` 뒤가 `,`)은 `.lock*`가 아니라 통과한다.

fn scanCoreMutexDirectCalls(text: [:0]const u8, path: []const u8, violations: *usize, emit_diagnostics: bool) void {
    var tokenizer = std.zig.Tokenizer.init(text);
    var saw_core_mutex = false; // 직전 식별자가 `core_mutex`였나
    var saw_dot = false; // `core_mutex` 직후 `.`를 봤나
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => break,
            .identifier => {
                const ident = text[token.loc.start..token.loc.end];
                if (saw_dot and (std.mem.eql(u8, ident, "lockUncancelable") or std.mem.eql(u8, ident, "unlock"))) {
                    if (emit_diagnostics) {
                        std.debug.print(
                            "core_mutex direct-call violation: {s} calls core_mutex.{s} directly — use Surface.lockCore/unlockCore (또는 CoreOwner.lock/unlock)\n",
                            .{ path, ident },
                        );
                    }
                    violations.* += 1;
                    saw_core_mutex = false;
                    saw_dot = false;
                } else {
                    saw_core_mutex = std.mem.eql(u8, ident, "core_mutex");
                    saw_dot = false;
                }
            },
            .period => {
                saw_dot = saw_core_mutex;
                saw_core_mutex = false;
            },
            else => {
                saw_core_mutex = false;
                saw_dot = false;
            },
        }
    }
}

fn scanTreeForCoreMutexCalls(allocator: std.mem.Allocator, dir_path: []const u8, violations: *usize) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, dir_path, .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ dir_path, entry.path });
        defer allocator.free(path);

        const text_z = try readZigFileZ(allocator, path);
        defer allocator.free(text_z);
        scanCoreMutexDirectCalls(text_z, path, violations, true);
    }
}

test "core_mutex is acquired only via owner-tracking wrappers (no direct lockUncancelable/unlock)" {
    const allocator = std.testing.allocator;
    var violations: usize = 0;
    try scanTreeForCoreMutexCalls(allocator, "src", &violations);
    try scanTreeForCoreMutexCalls(allocator, "tests", &violations);
    try std.testing.expectEqual(@as(usize, 0), violations);
}

test "scanCoreMutexDirectCalls flags direct lock but not wrappers/fields/pointers/comments" {
    // 직접 호출은 잡는다.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("s.core_mutex.lockUncancelable(io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("surface.core_mutex.unlock(self.io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 1), v);
    }
    // 포인터 전달(owner-추적 래퍼로 넘김)은 통과 — 뒤가 `,`라 `.lock*`가 아니다.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("self.core.owner_dbg.lock(&self.core_mutex, io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 필드 선언·optional 언랩은 통과.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("core_mutex: std.Io.Mutex = .init,\nconst m = self.core_mutex.?;", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 주석 속 언급은 오탐 아님(토큰이 아니다).
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("// 옛 방식: active.core_mutex.lockUncancelable(io)\nconst x = 1;", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
    // 다른 변수의 lockUncancelable(예: 큐 mutex)은 통과.
    {
        var v: usize = 0;
        scanCoreMutexDirectCalls("self.mutex.lockUncancelable(self.io);", "test", &v, false);
        try std.testing.expectEqual(@as(usize, 0), v);
    }
}
