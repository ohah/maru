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
        "screen_source:",
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
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".ReleaseFast => 9088,"));
}

test "CR2b 경계는 stable proxy와 sole runtime wiring을 고정한다" {
    const allocator = std.testing.allocator;
    const proxy = try readSource(allocator, "src/platform/macos/session_host/stable_screen_source.zig");
    defer allocator.free(proxy);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const surface = try readSource(allocator, "src/session/surface.zig");
    defer allocator.free(surface);

    try std.testing.expectEqual(@as(usize, 6), count(proxy, "test \"CR2b stable proxy는 "));
    try std.testing.expectEqual(@as(usize, 1), count(proxy, "pub const StableScreenSource = struct {"));
    const proxy_fields = between(
        proxy,
        "pub const StableScreenSource = struct {",
        "const vtable = ScreenSource.VTable{",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "owner_addr: usize = 0,",
        "owner_thread_id: u64 = 0,",
        "io: std.Io,",
        "gate: std.Io.Mutex = .init,",
        "writer_pending: std.atomic.Value(bool) = .init(false),",
        "reader_thread: std.atomic.Value(usize) = .init(0),",
        "render_started_ns: u64 = 0,",
        "render_sections: std.atomic.Value(u64) = .init(0),",
        "render_total_ns: std.atomic.Value(u64) = .init(0),",
        "render_max_ns: std.atomic.Value(u64) = .init(0),",
        "writer_waits: std.atomic.Value(u64) = .init(0),",
        "writer_wait_total_ns: std.atomic.Value(u64) = .init(0),",
        "writer_wait_max_ns: std.atomic.Value(u64) = .init(0),",
        "lifecycle: Lifecycle = .ready,",
        "unavailable: UnavailableCore,",
        "current: Target,",
        "pinned_target: ?Target = null,",
    }) |field| try std.testing.expectEqual(@as(usize, 1), count(proxy_fields, field));
    inline for (.{
        "pub fn publishLive(",
        "pub fn publishUnavailable(",
        "pub fn close(",
        "pub fn tryLock(",
        "pub fn unlockPinned(",
        "pub fn metrics(",
    }) |declaration| try std.testing.expectEqual(@as(usize, 1), count(proxy, declaration));
    try std.testing.expectEqual(@as(usize, 1), count(proxy, "const marker = \"[session unavailable]\";"));
    try std.testing.expectEqual(@as(usize, 1), count(proxy, "generation != self.current.generation + 1"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "screen_source: *stable_screen_source.StableScreenSource,"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "test \"CR2b RemoteRuntime attach는 Surface에 stable proxy를 한 번 게시한다\""));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.screen_source.publishLive("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.surface.remote = self.screen_source.screenSource();"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "self.deinitScreenSource();"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "self.surface.remote = self.generation.attachment.screenPtr().?.screenSource();"));
    try std.testing.expectEqual(@as(usize, 1), count(surface, "remote: ?ScreenSource = null,"));
    try std.testing.expectEqual(@as(usize, 1), count(surface, "r.vtable.lock(r.ctx, io);"));
    try std.testing.expectEqual(@as(usize, 1), count(surface, "r.vtable.unlock(r.ctx, io);"));

    // Qualified receiver spelling만 세면 다른 import alias로 low-level writer를 호출하는 회귀를
    // 놓친다. callee/type symbol을 전 제품 source에서 다시 세어 proxy 구현과 sole runtime owner
    // 밖의 stable-screen authority가 계속 0인지 함께 고정한다.
    inline for (.{
        "StableScreenSource",
        "initUnavailableInPlace(",
        "publishLive(",
        "publishUnavailable(",
        "unlockPinned(",
    }) |symbol| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            symbol,
            "platform/macos/session_host/stable_screen_source.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );
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

fn countProductSourcesExceptTwo(
    allocator: std.mem.Allocator,
    needle: []const u8,
    excluded_path: []const u8,
    second_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, excluded_path) or
            std.mem.eql(u8, entry.path, second_excluded_path)) continue;
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
        .limited(max_source_bytes),
        .of(u8),
        0,
    );
}
