const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

test "2c4 경계는 RuntimeConnection 하나만 mode 권위로 허용한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);

    const product = between(
        runtime,
        "pub const RemoteRuntime = struct {",
        "pub const testing_api = if (builtin.is_test) struct",
    ) orelse return error.TestUnexpectedResult;

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "const RuntimeConnection = union(enum) {"));
    const connection = between(
        runtime,
        "const RuntimeConnection = union(enum) {",
        "};",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(connection, "legacy: *client_mod.Client,"));
    try std.testing.expectEqual(@as(usize, 1), count(connection, "generation: *host_adapter_mod.HostAdapter,"));
    const generation_fields = between(runtime, "pub const RemoteGeneration = struct {", "const RemoteGenerationSlot =") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(generation_fields, "connection: RuntimeConnection,"));
    try std.testing.expectEqual(@as(usize, 0), count(generation_fields, "client: *client_mod.Client,"));
    try std.testing.expectEqual(@as(usize, 0), count(product, "generation_adapter:"));
    try std.testing.expectEqual(@as(usize, 0), count(product, "self.generation_adapter"));
    try std.testing.expectEqual(@as(usize, 0), count(product, "spawnWithOwner("));
    try std.testing.expectEqual(@as(usize, 0), count(product, "attachExistingWithOwner("));
    try std.testing.expectEqual(@as(usize, 0), count(product, "deinitWithAdapter("));
    try std.testing.expectEqual(@as(usize, 0), count(product, "initializePendingEventOwner(generation_adapter)"));
    try std.testing.expectEqual(@as(usize, 1), count(product, "fn spawnWithConnection("));
    try std.testing.expectEqual(@as(usize, 1), count(product, "fn attachExistingWithConnection("));
    try std.testing.expectEqual(@as(usize, 1), count(product, "fn initializePendingEventOwner("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn deinitWithConnection("));

    const semantic_methods = [_][]const u8{
        "capabilities",
        "prepareRequest",
        "executePreparedRequest",
        "abortPreparedRequest",
        "sendInput",
        "sendInputNonBlocking",
        "sendControl",
        "sendControlNonBlocking",
        "pumpPendingOutput",
        "takeEvent",
        "releaseEvent",
        "fenceRevoke",
        "readInitialSnapshot",
        "purgeEndedStream",
        "poison",
    };
    try std.testing.expectEqual(@as(usize, 15), semantic_methods.len);
    for (semantic_methods) |name| {
        var declaration: [96]u8 = undefined;
        const needle = try std.fmt.bufPrint(&declaration, "pub fn {s}(", .{name});
        try std.testing.expectEqual(@as(usize, 1), count(transport, needle));
    }

    const generation_arm = between(
        product,
        "fn generationConnection(",
        "fn legacyConnection(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 0), count(generation_arm, "logicalClient()"));
    try std.testing.expectEqual(@as(usize, 0), count(generation_arm, "client_mod.Client"));
    try std.testing.expectEqual(@as(usize, 0), count(product, "connectExistingHost("));
    try std.testing.expectEqual(@as(usize, 0), count(product, "withCurrent("));
}

fn between(source: []const u8, start_marker: []const u8, end_marker: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, source, start_marker) orelse return null;
    const tail = source[start..];
    const end = std.mem.indexOf(u8, tail, end_marker) orelse return null;
    return tail[0..end];
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var rest = haystack;
    while (std.mem.indexOf(u8, rest, needle)) |at| {
        total += 1;
        rest = rest[at + needle.len ..];
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
