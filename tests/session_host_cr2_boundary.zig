const std = @import("std");

const max_source_bytes = 16 * 1024 * 1024;

test "CR2a 경계는 generation field 열한 개와 stable shell exclusion을 고정한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);

    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR2a RemoteGeneration "));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub const RemoteGeneration = struct {"));

    const generation = between(
        runtime,
        "pub const RemoteGeneration = struct {",
        "pub const RemoteRuntime = struct {",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "connection: RuntimeConnection,",
        "attachment: RuntimeAttachment,",
        "event_generation_tracking: EventGenerationTracking,",
        "resize_seq: u64,",
        "resize_generation: u64,",
        "resize_baseline_present: bool,",
        "pump_ended: bool,",
        "resync_needed: bool,",
        "frame_summary_ready: bool = false,",
        "frame_summary: runtime_pump_mod.DrainSummary = .{},",
        "observation: term_backend.RuntimeObservation,",
    }) |field| try std.testing.expectEqual(@as(usize, 1), count(generation, field));
    inline for (.{
        "allocator:",
        "io:",
        "runtime_id_hex:",
        "direct_input:",
        "direct_input_offset:",
        "pending_controls:",
        "blocking_flush_active:",
        "pending_event_owner:",
        "close_authority:",
        "shutdown_attempt_authority:",
        "shutdown_current_admin:",
        "runtime_lifetime:",
        "surface:",
    }) |field| try std.testing.expectEqual(@as(usize, 0), count(generation, field));

    const shell = between(
        runtime,
        "pub const RemoteRuntime = struct {",
        "fn generationConnection(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(shell, "generation: RemoteGeneration,"));
    inline for (.{
        "connection: RuntimeConnection,",
        "attachment: RuntimeAttachment,",
        "event_generation_tracking: EventGenerationTracking,",
        "resize_seq: u64,",
        "resize_generation: u64,",
        "resize_baseline_present: bool,",
        "pump_ended: bool,",
        "resync_needed: bool,",
        "frame_summary_ready: bool = false,",
        "frame_summary: runtime_pump_mod.DrainSummary = .{},",
        "observation: term_backend.RuntimeObservation,",
    }) |field| try std.testing.expectEqual(@as(usize, 0), count(shell, field));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "@fieldParentPtr(\"generation\", generation)"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".Debug => 9136,"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".ReleaseFast => 9072,"));
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
