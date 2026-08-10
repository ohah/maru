//! C3-3b2b2 source boundary: pure recipes remain value-only and compatibility-owned.

const std = @import("std");

test "C3-3b2b2 pure preparation recipe boundary" {
    const allocator = std.testing.allocator;
    const preparation = try readSource(
        allocator,
        "src/platform/macos/session_host/runtime_event_preparation.zig",
    );
    defer allocator.free(preparation);
    const metadata_types = try readSource(
        allocator,
        "src/platform/macos/session_host/runtime_metadata_types.zig",
    );
    defer allocator.free(metadata_types);
    const metadata_wire = try readSource(
        allocator,
        "src/platform/macos/session_host/runtime_metadata_wire.zig",
    );
    defer allocator.free(metadata_wire);
    const event_types = try readSource(
        allocator,
        "src/platform/macos/session_host/runtime_event_types.zig",
    );
    defer allocator.free(event_types);
    const runtime = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    inline for (.{
        "protocol.zig",
        "resize_wire.zig",
        "runtime_event_types.zig",
        "runtime_event_wire.zig",
        "runtime_metadata_types.zig",
    }) |dependency| try std.testing.expectEqual(
        @as(usize, 1),
        count(preparation, "@import(\"" ++ dependency ++ "\")"),
    );
    inline for (.{
        "std.mem.Allocator",
        "OwnedMetadataDto",
        "RuntimeObservation",
        "RemoteRuntime",
        "GenerationAttachment",
        "Client",
        "resident_bytes",
    }) |forbidden| try std.testing.expectEqual(
        @as(usize, 0),
        count(preparation, forbidden),
    );
    try std.testing.expectEqual(@as(usize, 1), count(
        metadata_wire,
        "@import(\"runtime_event_preparation.zig\")",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(
        preparation,
        "@import(\"runtime_metadata_wire.zig\")",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        metadata_types,
        "pub const max_process_name_bytes",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        metadata_types,
        "pub const ProcessValue",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        metadata_wire,
        "pub const Process = runtime_metadata_types.ProcessValue;",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        preparation,
        "pub const FilledProcess = runtime_metadata_types.ProcessValue;",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        preparation,
        "pub fn buildEventPreparationRecipe(",
    ));
    try std.testing.expectEqual(@as(usize, 2), try countProductSources(
        allocator,
        "buildEventPreparationRecipe(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        preparation,
        "pub fn fillMetadataRecipe(",
    ));
    try std.testing.expectEqual(@as(usize, 1), try countProductSources(
        allocator,
        "fillMetadataRecipe(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        metadata_wire,
        "pub const EventMaterializationError = DecodeError || error{LocalInvariant};",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(
        metadata_wire[metadataWireStart(metadata_wire)..metadataWireEnd(metadata_wire)],
        "LocalInvariant",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        runtime,
        ".local_invariant_violation",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "event_preparation"));
    try std.testing.expectEqual(@as(usize, 1), count(
        event_types,
        "pub fn classifyEventView(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        metadata_wire,
        "pub fn classifyAndMaterializeEvent(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        runtime,
        "runtime_metadata_wire.classifyAndMaterializeEvent(",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        build,
        "\"test-session-host-2c3d-c3-3b2b2\"",
    ));
    try std.testing.expectEqual(@as(usize, 2), count(
        build,
        "--maru-expect-tests=10",
    ));
    try std.testing.expectEqual(@as(usize, 2), count(
        build,
        "--maru-expect-tests=6",
    ));
}

fn metadataWireStart(source: []const u8) usize {
    return std.mem.indexOf(u8, source, "pub const DecodeError = error{").?;
}

fn metadataWireEnd(source: []const u8) usize {
    return std.mem.indexOfPos(u8, source, metadataWireStart(source), "};").? + 2;
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
