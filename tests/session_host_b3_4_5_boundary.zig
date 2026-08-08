const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "B3-4/5 transition permits remain leaf-owned and registry-mediated" {
    const allocator = std.testing.allocator;
    const leaf = try readSource(allocator, "src/platform/macos/session_host/rpc_response_authority.zig");
    defer allocator.free(leaf);
    const registry = try readSource(allocator, "src/platform/macos/session_host/attachment_cleanup_registry.zig");
    defer allocator.free(registry);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const leaf_product = productPrefix(leaf);
    const registry_product = productPrefix(registry);

    try std.testing.expectEqual(@as(usize, 1), count(leaf_product, "pub const PreparedRpcTransitionPermit = struct"));
    inline for (.{
        "preparePublish",
        "commitPublishedNoFail",
        "prepareBorrow",
        "commitBorrowedNoFail",
        "prepareBeginRelease",
        "commitReleasingNoFail",
        "prepareFinishReusable",
        "commitReusableNoFail",
        "prepareFinishTerminal",
        "commitTerminalNoFail",
        "preparePublishedTerminal",
        "commitPublishedTerminalNoFail",
    }) |name| {
        const declaration = try std.fmt.allocPrint(allocator, "pub fn {s}(", .{name});
        defer allocator.free(declaration);
        try std.testing.expectEqual(@as(usize, 1), count(leaf_product, declaration));
        const call = try std.fmt.allocPrint(allocator, ".rpc_response_authority.{s}(", .{name});
        defer allocator.free(call);
        try std.testing.expectEqual(@as(usize, 1), count(registry_product, call));
        try std.testing.expectEqual(@as(usize, 0), count(slot, call));
        try std.testing.expectEqual(@as(usize, 0), count(transport, call));
    }

    inline for (.{
        "prepareRpcResponsePublished",
        "commitRpcResponsePublished",
        "prepareRpcResponseBorrowed",
        "commitRpcResponseBorrowed",
        "prepareRpcResponseReleasing",
        "commitRpcResponseReleasing",
        "prepareRpcResponseReusable",
        "commitRpcResponseReusable",
        "prepareRpcResponseTerminal",
        "commitRpcResponseTerminal",
        "preparePublishedRpcResponseTerminal",
        "commitPublishedRpcResponseTerminal",
    }) |name| {
        const declaration = try std.fmt.allocPrint(allocator, "pub fn {s}(", .{name});
        defer allocator.free(declaration);
        try std.testing.expectEqual(@as(usize, 1), count(registry_product, declaration));
    }

    try std.testing.expectEqual(@as(usize, 0), count(registry_product, "rpc_response_authority: *"));
    try std.testing.expectEqual(@as(usize, 0), count(registry_product, "PreparedRpcTransitionPermit ="));
    inline for (.{ "client.zig", "client_slot.zig", "socket", "Allocator", "RemoteRuntime", "reconnect" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), countCodeTokens(leaf_product, forbidden));
    }
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        path,
        allocator,
        .limited(max_source_bytes),
    );
}

fn productPrefix(source: []const u8) []const u8 {
    return source[0 .. std.mem.indexOf(u8, source, "\ntest \"") orelse source.len];
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |index| {
        result += 1;
        rest = rest[index + needle.len ..];
    }
    return result;
}

fn countCodeTokens(source: []const u8, needle: []const u8) usize {
    var count_value: usize = 0;
    var line_iterator = std.mem.splitScalar(u8, source, '\n');
    while (line_iterator.next()) |line| {
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (std.mem.startsWith(u8, trimmed, "//")) continue;
        count_value += count(line, needle);
    }
    return count_value;
}
