const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

test "CR3a-2c3d C3-2 purge-first product drain boundary" {
    const allocator = std.testing.allocator;
    const transport = try readSource(allocator, "src/platform/macos/session_host/generation_transport.zig");
    defer allocator.free(transport);
    const attachment = try readSource(allocator, "src/platform/macos/session_host/generation_attachment.zig");
    defer allocator.free(attachment);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);

    const facade = between(transport, "pub const GenerationTransport = struct", "fn mapPrepareError(") orelse
        return error.TestExpectedEqual;
    try std.testing.expectEqual(@as(usize, 15), count(facade, "    pub fn "));
    try std.testing.expectEqual(@as(usize, 1), count(facade, "    pub fn purgeEndedStream("));
    try std.testing.expectEqual(@as(usize, 1), count(attachment, "    pub fn purgeEndedStream("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn drainGenerationObservationEvents("));

    // C3-2 keeps the existing raw Client event owner in the explicitly named legacy drain only.
    try expectIdentifierCountInFunction(allocator, runtime, "drainLegacyObservationEvents", "takeEventForStream", 1);
    try expectIdentifierCountInFunction(allocator, runtime, "drainLegacyObservationEvents", "releaseEvent", 1);
    try expectIdentifierCountInFunction(allocator, runtime, "drainLegacyObservationEvents", "dropBufferedStream", 1);
    try expectIdentifierCountInFunction(allocator, runtime, "drainGenerationObservationEvents", "takeEventForStream", 0);
    try expectIdentifierCountInFunction(allocator, runtime, "drainGenerationObservationEvents", "dropBufferedStream", 0);
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

fn count(haystack: []const u8, needle: []const u8) usize {
    var result: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        result += 1;
        offset = index + needle.len;
    }
    return result;
}

fn between(source: []const u8, start: []const u8, end: []const u8) ?[]const u8 {
    const start_index = std.mem.indexOf(u8, source, start) orelse return null;
    const end_index = std.mem.indexOfPos(u8, source, start_index + start.len, end) orelse return null;
    return source[start_index..end_index];
}

fn expectIdentifierCountInFunction(
    allocator: std.mem.Allocator,
    source: [:0]const u8,
    function_name: []const u8,
    identifier: []const u8,
    expected: usize,
) !void {
    var ast = try std.zig.Ast.parse(allocator, source, .zig);
    defer ast.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), ast.errors.len);
    var found: usize = 0;
    var references: usize = 0;
    for (ast.rootDecls()) |decl| {
        var buffer: [1]std.zig.Ast.Node.Index = undefined;
        const fn_decl = ast.fullFnProto(&buffer, decl) orelse continue;
        const name_token = fn_decl.name_token orelse continue;
        if (!std.mem.eql(u8, ast.tokenSlice(name_token), function_name)) continue;
        found += 1;
        const first = ast.firstToken(decl);
        const last = ast.lastToken(decl);
        var token = first;
        while (token <= last) : (token += 1) {
            if (ast.tokens.items(.tag)[token] == .identifier and
                std.mem.eql(u8, ast.tokenSlice(token), identifier)) references += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1), found);
    try std.testing.expectEqual(expected, references);
}
