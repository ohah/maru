const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "B3-1 RPC authority remains leaf-owned while B3-3 opens only registry execution transitions" {
    const allocator = std.testing.allocator;
    const leaf_path = "src/platform/macos/session_host/rpc_response_authority.zig";
    const registry_path = "src/platform/macos/session_host/attachment_cleanup_registry.zig";
    const leaf = try readSource(allocator, leaf_path);
    defer allocator.free(leaf);
    const registry = try readSource(allocator, registry_path);
    defer allocator.free(registry);
    const leaf_product = productPrefix(leaf);
    const registry_product = productPrefix(registry);

    // B3-3 adds only the builtin test-mode gate for its destructive epoch-exhaustion fixture.
    try std.testing.expectEqual(@as(usize, 4), count(leaf_product, "@import(\""));
    inline for (.{
        "@import(\"std\")",
        "@import(\"generation_attachment_contract.zig\")",
        "@import(\"external_owner_seal.zig\")",
    }) |allowed| try std.testing.expectEqual(@as(usize, 1), count(leaf_product, allowed));
    inline for (.{
        "client.zig",
        "client_slot.zig",
        "generation_transport.zig",
        "executed_response.zig",
        "socket",
        "Allocator",
        "RemoteRuntime",
        "reconnect",
    }) |forbidden| try std.testing.expectEqual(@as(usize, 0), countCodeTokens(leaf_product, forbidden));
    inline for (.{
        "pub fn reserveExecuting(",
        "pub fn rollbackExecuting(",
        "pub fn settleExecutingTerminal(",
    }) |public_transition| try std.testing.expectEqual(
        @as(usize, 1),
        count(leaf_product, public_transition),
    );
    inline for (.{ "publish", "borrow", "beginRelease", "finishReusable" }) |private_name| {
        const public_decl = try std.fmt.allocPrint(allocator, "pub fn {s}(", .{private_name});
        defer allocator.free(public_decl);
        try std.testing.expectEqual(@as(usize, 0), count(leaf_product, public_decl));
        const private_decl = try std.fmt.allocPrint(allocator, "fn {s}(", .{private_name});
        defer allocator.free(private_decl);
        try std.testing.expectEqual(@as(usize, 1), count(leaf_product, private_decl));
    }

    try std.testing.expectEqual(
        @as(usize, 1),
        count(registry_product, "@import(\"rpc_response_authority.zig\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(registry_product, "rpc_response_authority: rpc_response_authority.Authority = .{}"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        count(registry_product, "identity: ?contract.BindingIdentity"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(registry_product, ".rpc_response_authority.initInPlace(self.incarnation, identity)"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(
            registry_product,
            "entry.rpc_response_authority.settledExactFor(registry_incarnation, identity)",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(registry_product, "entry.rpc_response_authority.pristineExact()"),
    );
    inline for (.{
        ".rpc_response_authority.reserveExecuting(",
        ".rpc_response_authority.rollbackExecuting(",
        ".rpc_response_authority.settleExecutingTerminal(",
    }) |b3_3_transition| try std.testing.expectEqual(
        @as(usize, 1),
        count(registry_product, b3_3_transition),
    );
    inline for (.{
        ".rpc_response_authority.publish(",
        ".rpc_response_authority.borrow(",
        ".rpc_response_authority.beginRelease(",
        ".rpc_response_authority.finishReusable(",
    }) |future_transition| try std.testing.expectEqual(
        @as(usize, 0),
        count(registry_product, future_transition),
    );

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        if (std.mem.eql(u8, path, leaf_path) or std.mem.eql(u8, path, registry_path)) continue;
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        const expected: usize = if (std.mem.eql(
            u8,
            path,
            "src/platform/macos/session_host/client_slot.zig",
        )) 20 else if (std.mem.eql(
            u8,
            path,
            "src/platform/macos/session_host/rpc_executed_response.zig",
        )) 1 else 0;
        try std.testing.expectEqual(expected, count(source, "rpc_response_authority"));
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

// The source contract is identifier/import oriented. Comments deliberately explain the forbidden
// dependencies, so quoted prose is ignored for the handful of token names checked above.
fn countCodeTokens(source: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |line| {
        const code = line[0 .. std.mem.indexOf(u8, line, "//") orelse line.len];
        result += count(code, needle);
    }
    return result;
}
