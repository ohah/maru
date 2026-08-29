//! CR4c C1 controller binding promotion의 sole owner chain과 publication 0 경계를 고정한다.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const max_source_bytes = 16 * 1024 * 1024;

test "CR4c C1 경계는 evidenced observer binding만 unpublished controller로 승격한다" {
    const allocator = std.testing.allocator;
    const contract = try readSource(allocator, "src/platform/macos/session_host/generation_attachment_contract.zig");
    defer allocator.free(contract);
    const rpc = try readSource(allocator, "src/platform/macos/session_host/rpc_response_authority.zig");
    defer allocator.free(rpc);
    const registry = try readSource(allocator, "src/platform/macos/session_host/attachment_cleanup_registry.zig");
    defer allocator.free(registry);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const attachment_c1 = functionSlice(
        attachment,
        "pub fn promoteControllerEvidence(",
        "pub const ForcedResizeResult = struct",
    );
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    const registry_commit = functionSlice(registry, "pub fn promoteControllerNoFail(", "pub fn reserveEventGeneration(");
    try std.testing.expect(
        index(registry_commit, "replaceSettledBindingNoFail(") <
            index(registry_commit, "entry.controller_authority = .live;"),
    );
    const attachment_promote = functionSlice(
        attachment,
        "pub fn promoteControllerEvidence(",
        "pub fn validatePromotedController(",
    );
    try std.testing.expect(
        index(attachment_promote, "preflightControllerPromotionOwned(") <
            index(attachment_promote, "promoteControllerNoFailOwned("),
    );
    try std.testing.expect(
        index(attachment_promote, "promoteControllerNoFailOwned(") <
            index(attachment_promote, "self.payloadMut().state.role = .controller;"),
    );
    try std.testing.expect(
        index(attachment_promote, "self.payloadMut().state.controller_generation = controller_generation;") <
            index(attachment_promote, "self.catchup_stage_owner.state = .controller_promoted;"),
    );
    const backend_promote = functionSlice(
        backend,
        "pub fn promoteHostReconnectControllerBinding(",
        "fn finishHostReconnectTakeoverOutcome(",
    );
    try std.testing.expect(
        index(backend_promote, "RemoteRuntime.backend_api.promoteReconnectControllerEvidence(") <
            index(backend_promote, "job.state_raw = @intFromEnum(HostReconnectJobState.controller_promoted);"),
    );

    const inventories = .{
        .{ "sameExceptRole", &.{
            "platform/macos/session_host/generation_attachment_contract.zig",
            "platform/macos/session_host/rpc_response_authority.zig",
        } },
        .{ "preflightSettledBindingReplacement", &.{
            "platform/macos/session_host/rpc_response_authority.zig",
            "platform/macos/session_host/attachment_cleanup_registry.zig",
        } },
        .{ "replaceSettledBindingNoFail", &.{
            "platform/macos/session_host/rpc_response_authority.zig",
            "platform/macos/session_host/attachment_cleanup_registry.zig",
        } },
        .{ "preflightControllerPromotion", &.{
            "platform/macos/session_host/attachment_cleanup_registry.zig",
            "platform/macos/session_host/client_slot.zig",
        } },
        .{ "promoteControllerNoFail", &.{
            "platform/macos/session_host/attachment_cleanup_registry.zig",
            "platform/macos/session_host/client_slot.zig",
        } },
        .{ "preflightAttachmentControllerPromotion", &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/generation_transport.zig",
        } },
        .{ "promoteAttachmentControllerNoFail", &.{
            "platform/macos/session_host/client_slot.zig",
            "platform/macos/session_host/generation_transport.zig",
        } },
        .{ "preflightControllerPromotionOwned", &.{
            "platform/macos/session_host/generation_transport.zig",
            "platform/macos/session_host/generation_attachment.zig",
        } },
        .{ "promoteControllerNoFailOwned", &.{
            "platform/macos/session_host/generation_transport.zig",
            "platform/macos/session_host/generation_attachment.zig",
        } },
        .{ "promoteControllerEvidence", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "validatePromotedController", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "releasePromotedController", &.{
            "platform/macos/session_host/generation_attachment.zig",
            "platform/macos/session_host/remote_runtime.zig",
        } },
        .{ "promoteReconnectControllerEvidence", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "validateReconnectPromotedController", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "abortReconnectPromotedController", &.{
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        } },
        .{ "promoteHostReconnectControllerBinding", &.{
            "platform/macos/session_host/remote_term_backend.zig",
        } },
    };
    inline for (inventories) |inventory| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductIdentifiersExcept(allocator, inventory[0], inventory[1]),
    );

    try std.testing.expectEqual(@as(usize, 1), countIdentifier(contract, "sameExceptRole"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(rpc, "preflightSettledBindingReplacement"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(rpc, "replaceSettledBindingNoFail"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(registry, "preflightControllerPromotion"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(registry, "promoteControllerNoFail"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(slot, "preflightAttachmentControllerPromotion"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(slot, "promoteAttachmentControllerNoFail"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(transport, "preflightControllerPromotionOwned"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(transport, "promoteControllerNoFailOwned"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment_c1, "promoteControllerEvidence"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(attachment_c1, "validatePromotedController"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(attachment_c1, "releasePromotedController"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "promoteReconnectControllerEvidence"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "validateReconnectPromotedController"));
    try std.testing.expectEqual(@as(usize, 1), countIdentifier(runtime, "abortReconnectPromotedController"));
    // CR5b-2c reuses the sole product promotion entry in its three-runtime loop.
    // CR6e-c3b2b adds the reviewed one-state frame driver caller.
    try std.testing.expectEqual(@as(usize, 5), countIdentifier(backend, "promoteHostReconnectControllerBinding"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "test \"CR4c C1 actual host job은"));

    const gate = functionSlice(build, "const session_host_cr4c_c1_step =", "const session_host_cr4c_c2_step =");
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr4c-c1\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr4c_c1_step.dependOn(session_host_cr4b_step);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "CR4c C1 actual host job은"));
    try std.testing.expectEqual(@as(usize, 2), count(gate, "--maru-expect-tests=1"));

    // C1 itself ends at controller_promoted; C2 owns the sole publication entry separately.
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn publishHostReconnectGeneration("));
}

fn functionSlice(source: []const u8, start: []const u8, end: []const u8) []const u8 {
    const from = index(source, start);
    return source[from..indexFrom(source, from, end)];
}

fn index(source: []const u8, needle: []const u8) usize {
    return std.mem.indexOf(u8, source, needle) orelse @panic("missing boundary anchor");
}

fn indexFrom(source: []const u8, from: usize, needle: []const u8) usize {
    return std.mem.indexOfPos(u8, source, from, needle) orelse @panic("missing boundary end anchor");
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |at| {
        total += 1;
        offset = at + needle.len;
    }
    return total;
}

fn identifierByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

fn countIdentifier(haystack: []const u8, identifier: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, identifier)) |at| {
        const end = at + identifier.len;
        if ((at == 0 or !identifierByte(haystack[at - 1])) and
            (end == haystack.len or !identifierByte(haystack[end]))) total += 1;
        offset = end;
    }
    return total;
}

fn countProductIdentifiersExcept(
    allocator: std.mem.Allocator,
    identifier: []const u8,
    excluded: []const []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        var skip = false;
        for (excluded) |path| if (std.mem.eql(u8, entry.path, path)) {
            skip = true;
            break;
        };
        if (skip) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += countIdentifier(source, identifier);
    }
    return total;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
}
