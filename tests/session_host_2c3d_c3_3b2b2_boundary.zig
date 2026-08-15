//! C3-3b2b2 source boundary: pure recipes remain value-only and compatibility-owned.

const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("support/posix_walk.zig").posixWalk;

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
    try std.testing.expectEqual(@as(usize, 2), countIdentifierOutsideTopLevelTests(
        preparation,
        "buildEventPreparationRecipe",
    ));
    try std.testing.expectEqual(@as(usize, 1), countIdentifierOutsideTopLevelTests(
        metadata_wire,
        "buildEventPreparationRecipe",
    ));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "buildEventPreparationRecipe",
        &.{
            "platform/macos/session_host/runtime_event_preparation.zig",
            "platform/macos/session_host/runtime_metadata_wire.zig",
            // b2b3 owns the first immutable owner-preparation caller.
            "platform/macos/session_host/pending_event_preparation.zig",
        },
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        preparation,
        "pub fn fillMetadataRecipe(",
    ));
    try std.testing.expectEqual(@as(usize, 1), countIdentifierOutsideTopLevelTests(
        preparation,
        "fillMetadataRecipe",
    ));
    try std.testing.expectEqual(@as(usize, 1), countIdentifierOutsideTopLevelTests(
        metadata_wire,
        "fillMetadataRecipe",
    ));
    try std.testing.expectEqual(@as(usize, 0), try countProductIdentifiersExcept(
        allocator,
        "fillMetadataRecipe",
        &.{
            "platform/macos/session_host/runtime_event_preparation.zig",
            "platform/macos/session_host/runtime_metadata_wire.zig",
            // b2b3 owns the first immutable owner-preparation caller.
            "platform/macos/session_host/pending_event_preparation.zig",
        },
    ));

    // The semantic count is useful only if every reviewed category remains present. Keep the
    // exact names here so a deleted hostile category cannot be replaced by a trivial tenth test.
    inline for (.{
        "C3-3b2b2 recipe projects all five accepted event arms",
        "C3-3b2b2 recipe preserves every closed violation arm without parsing payload",
        "C3-3b2b2 metadata recipe is pointer free and records decoded destination layout",
        "C3-3b2b2 metadata fill decodes strings and process values into caller storage",
        "C3-3b2b2 SSH absent and present-empty remain distinct canonical recipes",
        "C3-3b2b2 unavailable foreground canonicalizes pgid count and process tail",
        "C3-3b2b2 process name 128 is accepted and 129 is a resource violation before recipe fill",
        "C3-3b2b2 accepted metadata cannot be paired with different payload bytes",
        "C3-3b2b2 fill rejects wrong destination size before changing either scratch",
        "C3-3b2b2 fill rejects noncanonical raw recipe state before changing scratch",
    }) |name| try expectExactTestName(preparation, name);
    inline for (.{
        "C3-3b2b2 compatibility keeps non-metadata accepted and violation allocation-free",
        "C3-3b2b2 compatibility preserves zero or one allocation and metadata semantics",
        "C3-3b2b2 compatibility reports OOM only at the owning allocation",
        "C3-3b2b2 compatibility rejects allocator callback scalar and string drift locally",
        "C3-3b2b2 compatibility separates peer violation from forged local provenance",
    }) |name| try expectExactTestName(metadata_wire, name);
    try expectExactTestName(
        runtime,
        "C3-3b2b2 compatibility maps event materialization failures by provenance",
    );

    // Runtime tests must prove the exact reflected shape and every forbidden type family. A
    // pointer-only recursive predicate is insufficient because function and allocator fields can
    // otherwise enter the supposedly value-only recipe without changing the test count.
    inline for (.{
        "std.meta.fields(StringRecipe)",
        "std.meta.fields(ProcessRecipe)",
        "std.meta.fields(MetadataPreparationRecipe)",
        "std.meta.fields(AcceptedPreparationRecipe)",
        "std.meta.fields(EventPreparationRecipe)",
        "std.meta.fields(FilledRange)",
        "std.meta.fields(MetadataFillProjection)",
        ".@\"fn\" => true",
    }) |shape_proof| try std.testing.expectEqual(
        @as(usize, 1),
        count(preparation, shape_proof),
    );
    inline for (.{
        "pub const StringRecipe = struct {",
        "pub const ProcessRecipe = struct {",
        "pub const MetadataPreparationRecipe = struct {",
        "pub const AcceptedPreparationTag = enum(u8) {",
        "pub const AcceptedPreparationRecipe = union(AcceptedPreparationTag) {",
        "pub const EventPreparationTag = enum(u8) {",
        "pub const EventPreparationRecipe = union(EventPreparationTag) {",
        "pub const FilledRange = struct {",
        "pub const MetadataFillProjection = struct {",
    }) |declaration| try std.testing.expectEqual(
        @as(usize, 1),
        count(preparation, declaration),
    );

    const recipe_tests = preparation[firstB2b2Test(preparation)..];
    inline for (.{
        "error.DestinationMismatch",
        "error.DestinationOverlap",
        "std.math.maxInt(usize)",
        "final digest",
        "std.meta.fields(runtime_event_types.FrameViolation)",
        "std.meta.fields(runtime_event_types.IdentityViolation)",
        "std.meta.fields(runtime_event_types.AuthorityViolation)",
    }) |semantic_sentinel| try std.testing.expect(
        count(recipe_tests, semantic_sentinel) > 0,
    );
    try std.testing.expectEqual(@as(usize, 1), count(
        preparation,
        "const fill_post_copy_testing = if (builtin.is_test)",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        preparation,
        "threadlocal var hook: ?FillPostCopyTestHook = null;",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        preparation,
        "runFillPostCopyTestHook();",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(preparation, "pub const FillPostCopy"));
    try std.testing.expectEqual(@as(usize, 0), count(preparation, "pub fn runFillPostCopy"));
    try std.testing.expectEqual(@as(usize, 1), count(
        metadata_wire,
        "pub const EventMaterializationError = DecodeError || error{LocalInvariant};",
    ));
    try std.testing.expectEqual(@as(usize, 0), count(
        metadata_wire[metadataWireStart(metadata_wire)..metadataWireEnd(metadata_wire)],
        "LocalInvariant",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        runtime[0..firstB2b2Test(runtime)],
        "eventMaterializationPoisonReason(err)",
    ));
    const mapper_start = std.mem.indexOf(
        u8,
        runtime,
        "fn eventMaterializationPoisonReason(",
    ).?;
    const mapper_end = std.mem.indexOfPos(
        u8,
        runtime,
        mapper_start,
        "fn pumpResyncIntent(",
    ).?;
    const mapper = runtime[mapper_start..mapper_end];
    inline for (.{
        "error.OutOfMemory => .local_resource_exhausted",
        "error.LocalInvariant => .local_invariant_violation",
        "error.Malformed,",
        "error.ResourceExhausted,",
        "error.CapabilityViolation,",
        "=> .peer_contract_violation",
    }) |mapping| try std.testing.expectEqual(@as(usize, 1), count(mapper, mapping));
    try std.testing.expectEqual(@as(usize, 0), count(mapper, "else =>"));
    try std.testing.expectEqual(@as(usize, 0), countIdentifierOutsideTopLevelTests(runtime, "event_preparation"));
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
    const b2b2_build_start = std.mem.indexOf(
        u8,
        build,
        "const event_c3_3b2b2_preparation_module",
    ).?;
    const b2b2_build_end = std.mem.indexOfPos(
        u8,
        build,
        b2b2_build_start,
        "const event_c3_3b2b3_control_types_module",
    ).?;
    const b2b2_build = build[b2b2_build_start..b2b2_build_end];
    try std.testing.expectEqual(@as(usize, 1), count(
        b2b2_build,
        "--maru-expect-tests=10",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        b2b2_build,
        "--maru-expect-tests=5",
    ));
    try std.testing.expectEqual(@as(usize, 2), count(
        b2b2_build,
        "addArg(\"--maru-expect-tests=1\");",
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
    var walker = try posixWalk(dir, allocator);
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
    var walker = try posixWalk(dir, allocator);
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

fn countProductIdentifiersExcept(
    allocator: std.mem.Allocator,
    identifier: []const u8,
    excluded_paths: []const []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        var excluded = false;
        for (excluded_paths) |path| {
            if (std.mem.eql(u8, entry.path, path)) {
                excluded = true;
                break;
            }
        }
        if (excluded) continue;
        const path = try std.fmt.allocPrint(allocator, "src/{s}", .{entry.path});
        defer allocator.free(path);
        const source = try readSource(allocator, path);
        defer allocator.free(source);
        total += countIdentifierOutsideTopLevelTests(source, identifier);
    }
    return total;
}

fn expectExactTestName(source: []const u8, name: []const u8) !void {
    const declaration = try std.fmt.allocPrint(
        std.testing.allocator,
        "test \"{s}\"",
        .{name},
    );
    defer std.testing.allocator.free(declaration);
    try std.testing.expectEqual(@as(usize, 1), count(source, declaration));
}

fn firstB2b2Test(source: []const u8) usize {
    return std.mem.indexOf(u8, source, "test \"C3-3b2b2").?;
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
