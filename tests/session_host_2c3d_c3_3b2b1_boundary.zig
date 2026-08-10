//! C3-3b2b1 source boundary: typed seals and the trusted projection stay dormant and leaf-owned.

const std = @import("std");

test "C3-3b2b1 trusted preparation seal boundary" {
    const allocator = std.testing.allocator;
    const neutral = try readSource(
        allocator,
        "src/platform/macos/session_host/event_cleanup_seal.zig",
    );
    defer allocator.free(neutral);
    const service = try readSource(
        allocator,
        "src/platform/macos/session_host/process_seal_service.zig",
    );
    defer allocator.free(service);
    const slot = try readSource(allocator, "src/platform/macos/session_host/client_slot.zig");
    defer allocator.free(slot);
    const contract = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_event_contract.zig",
    );
    defer allocator.free(contract);
    const transport = try readSource(
        allocator,
        "src/platform/macos/session_host/generation_transport.zig",
    );
    defer allocator.free(transport);
    const runtime = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);

    try std.testing.expectEqual(@as(usize, 1), count(
        service,
        "pub fn cleanupTranscriptSeal(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        service,
        "pub fn cleanupProgressSeal(",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(service, "pub fn generic"));
    try std.testing.expectEqual(@as(usize, 0), count(service, "rawKey"));
    try std.testing.expectEqual(@as(usize, 0), count(neutral, "std.mem.Allocator"));
    inline for (.{
        "cleanupDescriptorCanonical",
        "cleanupPlanCanonical",
        "cleanupTranscriptInputCanonical",
        "cleanupProgressInputCanonical",
        "foregroundProcessesInputCanonical",
        "observationCleanupInputCanonical",
        "progressCanonical",
    }) |validator| try std.testing.expectEqual(
        @as(usize, 0),
        count(neutral, "pub fn " ++ validator),
    );
    try std.testing.expectEqual(@as(usize, 1), count(
        neutral,
        "pub fn assertCleanupTranscriptCanonical(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        neutral,
        "pub fn assertCleanupProgressCanonical(",
    ));
    inline for (.{ "RemoteRuntime", "PendingEventOwner", "EventCorrelation", "../pty" }) |forbidden| {
        try std.testing.expectEqual(@as(usize, 0), count(neutral, forbidden));
        try std.testing.expectEqual(@as(usize, 0), count(service, forbidden));
    }

    try std.testing.expectEqual(@as(usize, 1), count(
        slot,
        "pub fn generationEventPreparationProjection(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        contract,
        "client_slot.generationEventPreparationProjection(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        transport,
        "generation_event.preparationEventView(owner, self.event_correlation)",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(
        transport,
        "pub const PreparationEventView",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "PreparationEventView"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "cleanupTranscriptSeal"));
    try std.testing.expectEqual(
        @as(usize, 1),
        try countProductSources(allocator, "@import(\"event_cleanup_seal.zig\")"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countProductSources(
            allocator,
            "generation_event.preparationEventView(owner, self.event_correlation)",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 2),
        try countProductSources(allocator, "@import(\"process_seal_service.zig\")"),
    );
    inline for (.{
        .{ "generationEventPreparationProjection", 2 },
        .{ "GenerationEventPreparationProjection", 7 },
        .{ "preparationEventView", 3 },
        .{ "PreparationEventView", 3 },
        .{ "cleanupTranscriptSeal", 3 },
        .{ "cleanupProgressSeal", 3 },
    }) |entry| try std.testing.expectEqual(
        @as(usize, entry[1]),
        try countProductIdentifiers(allocator, entry[0]),
    );
}

fn countProductSources(allocator: std.mem.Allocator, needle: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += count(source, needle);
    }
    return total;
}

fn countProductIdentifiers(allocator: std.mem.Allocator, identifier: []const u8) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += countIdentifierOutsideTopLevelTests(source, identifier);
    }
    return total;
}

fn countIdentifierOutsideTopLevelTests(source: [:0]const u8, wanted: []const u8) usize {
    var tokenizer = std.zig.Tokenizer.init(source);
    var brace_depth: usize = 0;
    var waiting_for_test_body = false;
    var test_body_depth: ?usize = null;
    var result: usize = 0;
    while (true) {
        const token = tokenizer.next();
        switch (token.tag) {
            .eof => return result,
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
                result += 1;
            },
            else => {},
        }
    }
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(16 * 1024 * 1024),
        .of(u8),
        0,
    );
}

fn count(haystack: []const u8, needle: []const u8) usize {
    var total: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |index| {
        total += 1;
        offset = index + needle.len;
    }
    return total;
}
