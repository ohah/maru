//! CR6b explicit one-item adopt authority boundary.

const std = @import("std");
const posixWalk = @import("support/posix_walk.zig").posixWalk;

test "CR6b 경계는 projection을 직접 attach 권위로 쓰지 않고 fresh evidence validator 하나를 연다" {
    const allocator = std.testing.allocator;
    const build = try read(allocator, "build.zig");
    defer allocator.free(build);
    const barrel = try read(allocator, "src/platform/macos/session_host.zig");
    defer allocator.free(barrel);
    const contract = try read(allocator, "src/platform/macos/session_host/recovered_session_adopt.zig");
    defer allocator.free(contract);
    const persistent = try read(allocator, "docs/persistent-session-host.md");
    defer allocator.free(persistent);

    try std.testing.expectEqual(@as(usize, 1), count(barrel, "@import(\"session_host/recovered_session_adopt.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(contract, "pub fn validateFreshEvidence("));
    try std.testing.expectEqual(@as(usize, 3), count(contract, "test \"CR6b recovered adopt"));
    try std.testing.expect(std.mem.indexOf(u8, persistent, "host.info") != null);
    try std.testing.expect(std.mem.indexOf(u8, persistent, "runtime.get") != null);
    try std.testing.expectEqual(@as(usize, 1), try countProductIdentifiersExcept(
        allocator,
        "validateFreshEvidence",
        &.{"platform/macos/session_host/recovered_session_adopt.zig"},
    ));
    const app_session = try read(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);
    const host_adapter = try read(allocator, "src/platform/macos/session_host/host_adapter.zig");
    defer allocator.free(host_adapter);
    const workspace = try read(allocator, "src/platform/macos/app_session/workspace.zig");
    defer allocator.free(workspace);
    const client_slot = try read(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(client_slot);
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "pub fn activateRecoveredSessionAt("));
    try std.testing.expectEqual(@as(usize, 7), count(app_session, "test \"CR6b "));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "recovered_session_adopt.validateFreshEvidence("));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "app_recovered_sessions_projection.validateExact("));
    const activation = between(app_session, "pub fn activateRecoveredSessionAt(", "fn replaceRecoveredEnded(") orelse
        return error.TestUnexpectedResult;
    const ended_replacement = between(app_session, "fn replaceRecoveredEnded(", "pub fn setPrimaryWindow(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "app_recovered_sessions_projection.consumeExactNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(activation, "app_recovered_sessions_projection.consumeExactNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(ended_replacement, "app_recovered_sessions_projection.consumeExactNoFail("));
    try std.testing.expectEqual(@as(usize, 1), count(activation, "AbsoluteDeadline.after("));
    try std.testing.expectEqual(@as(usize, 2), count(activation, "adapter.callUntil("));
    try std.testing.expectEqual(@as(usize, 0), count(activation, "adapter.call("));
    const host_info_pos = std.mem.indexOf(u8, activation, "adapter.callUntil(\"host.info\"") orelse
        return error.TestUnexpectedResult;
    const runtime_get_pos = std.mem.indexOf(u8, activation, "adapter.callUntil(\"runtime.get\"") orelse
        return error.TestUnexpectedResult;
    const evidence_pos = std.mem.indexOf(u8, activation, "recovered_session_adopt.validateFreshEvidence(") orelse
        return error.TestUnexpectedResult;
    const orphan_publish_pos = std.mem.indexOf(u8, activation, "tab_ops.newTab(self)") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(host_info_pos < runtime_get_pos);
    try std.testing.expect(runtime_get_pos < evidence_pos);
    try std.testing.expect(evidence_pos < orphan_publish_pos);
    try std.testing.expectEqual(@as(usize, 1), count(host_adapter, "pub fn callUntil("));
    try std.testing.expectEqual(@as(usize, 1), count(host_adapter, "self.slot.callCurrentUntil("));
    try std.testing.expectEqual(@as(usize, 1), count(workspace, "try assignEndedManifestOrdinals(new_tabs.items, win);"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "pub fn recoveredEndedManifestIndexForRestore("));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(app_session, "bindRecoveredEndedManifestOrdinals"));
    try std.testing.expectEqual(@as(usize, 1), count(workspace, "app_session_mod.recoveredEndedManifestIndexForRestore("));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "recoveredEndedManifestIndexForRestore",
        &.{ "platform/macos/app_session.zig", "platform/macos/app_session/workspace.zig" },
    ));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "term.rt.ended_manifest_index != manifest_index"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(app_session, "registerRecoveredSessionWindow"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(app_session, "unregisterRecoveredSessionWindow"));
    try std.testing.expectEqual(@as(usize, 2), countIdentifier(app_session, "locateRecoveredEnded"));
    try std.testing.expectEqual(@as(usize, 3), countIdentifier(app_session, "recoveredEndedLocationCurrent"));
    // Interleaved runtime.ended can make pre-decode return after the response was published. All five
    // non-proceed dispositions must settle that exact response owner before AppSession teardown.
    try std.testing.expectEqual(@as(usize, 1), count(client_slot, "fn settlePublishedRpcResponseWithoutDecode("));
    try std.testing.expectEqual(@as(usize, 6), countIdentifier(client_slot, "settlePublishedRpcResponseWithoutDecode"));
    const sidebar = try read(allocator, "src/platform/macos/app_session/sidebar.zig");
    defer allocator.free(sidebar);
    try std.testing.expectEqual(@as(usize, 1), count(sidebar, "self.activateRecoveredSessionAt(index)"));

    const gate = between(build, "const session_host_cr6b_step =", "const b3_1_boundary_tests =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr6b\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "\"test-session-host-cr6b-product\""));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "session_host_cr6b_step.dependOn(session_host_cr6a2_step);"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "--maru-expect-tests=3"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "run_cr6b_projection_tests.addArg(\"--maru-expect-tests=1\");"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "run_cr6b_boundary_tests.addArg(\"--maru-expect-tests=1\");"));
    try std.testing.expectEqual(@as(usize, 1), count(gate, "run_cr6b_product_tests.addArg(\"--maru-expect-tests=10\");"));
}

fn read(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(8 * 1024 * 1024));
}

fn count(haystack: []const u8, needle: []const u8) usize {
    return std.mem.count(u8, haystack, needle);
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const from = std.mem.indexOf(u8, source, start) orelse return null;
    const to = std.mem.indexOfPos(u8, source, from, end) orelse return null;
    return source[from..to];
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

fn countProductIdentifiersExcept(allocator: std.mem.Allocator, identifier: []const u8, excluded: []const []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        var skip = false;
        for (excluded) |path| if (std.mem.eql(u8, entry.path, path)) {
            skip = true;
            break;
        };
        if (skip) continue;
        const bytes = try dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(8 * 1024 * 1024));
        defer allocator.free(bytes);
        total += countIdentifier(bytes, identifier);
    }
    return total;
}
