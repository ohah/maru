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
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".Debug => 9184,"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".ReleaseFast => 9120,"));
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

test "CR2c 경계는 InputOwner facade와 local remote parity를 고정한다" {
    const allocator = std.testing.allocator;
    const owner = try readSource(allocator, "src/app/input_owner.zig");
    defer allocator.free(owner);
    const app_facade = try readSource(allocator, "src/app.zig");
    defer allocator.free(app_facade);
    const backend = try readSource(allocator, "src/app/term_runtime_backend.zig");
    defer allocator.free(backend);
    const local = try readSource(allocator, "src/app/in_process_term_backend.zig");
    defer allocator.free(local);
    const remote = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(remote);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);

    try std.testing.expectEqual(@as(usize, 3), count(owner, "test \"CR2c InputOwner facade는 "));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "test \"CR2c TermRuntimeBackend는 opaque handle을 InputOwner facade에 exact 결속한다\""));
    try std.testing.expectEqual(@as(usize, 1), count(local, "test \"CR2c local InputOwner는 기존 UnknownSurface와 partial 의미를 그대로 쓴다\""));
    try std.testing.expectEqual(@as(usize, 1), count(remote, "test \"CR2c remote InputOwner는 기존 UnknownSurface와 partial 의미를 그대로 쓴다\""));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub const InputOwner = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub const VTable = struct {"));
    const input_vtable = between(owner, "pub const VTable = struct {", "pub const InputOwner = struct {") orelse
        return error.TestUnexpectedResult;
    inline for (.{
        "write:",
        "write_nonblocking:",
        "enqueue_core_command:",
    }) |field| try std.testing.expectEqual(@as(usize, 1), count(input_vtable, field));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn inputOwner("));
    try std.testing.expectEqual(@as(usize, 1), count(local, ".input_owner = &input_vtable,"));
    try std.testing.expectEqual(@as(usize, 1), count(remote, ".input_owner = &input_vtable,"));
    inline for (.{
        ".write = writeInput,",
        ".write_nonblocking = writeInputNonBlocking,",
        ".enqueue_core_command = enqueueCoreCommand,",
    }) |binding| {
        try std.testing.expectEqual(@as(usize, 1), count(
            between(local, "const input_vtable = InputOwnerVTable{", "pub fn init(") orelse
                return error.TestUnexpectedResult,
            binding,
        ));
        try std.testing.expectEqual(@as(usize, 1), count(
            between(remote, "const input_vtable = InputOwnerVTable{", "pub fn init(") orelse
                return error.TestUnexpectedResult,
            binding,
        ));
    }
    try std.testing.expectEqual(@as(usize, 1), count(app_facade, "pub const InputOwner = input_owner.InputOwner;"));

    // CR2c는 구조 seam만 만든다. ordered queue 이동을 앞당기거나 기존 RemoteRuntime field를 없애면 RED다.
    inline for (.{
        "direct_input: std.ArrayListUnmanaged(u8),",
        "direct_input_offset: usize,",
        "pending_controls: std.ArrayListUnmanaged(runtime_pending_control.RawQueuedRuntimeControl),",
        "blocking_flush_active: bool = false,",
    }) |field| try std.testing.expectEqual(@as(usize, 1), count(runtime, field));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "input_owner.InputOwner"));

    // CR2d1은 AppSession 한 곳만 facade를 materialize한다. 그 밖의 제품 source가 facade를 임의
    // 발급하면 stable queue owner 이관을 우회하므로 계속 막는다.
    try std.testing.expectEqual(
        @as(usize, 1),
        try countProductSourcesExceptThree(
            allocator,
            "inputOwner(",
            "app/term_runtime_backend.zig",
            "app/in_process_term_backend.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        ),
    );
    const app_session = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);
    try std.testing.expectEqual(@as(usize, 1), count(app_session, ".inputOwner(term.rt.handle)"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "InputOwner{",
            "app/input_owner.zig",
            "app/term_runtime_backend.zig",
        ),
    );
}

test "CR2d1 경계는 remote stable batch queue와 Window queue exclusion을 고정한다" {
    const allocator = std.testing.allocator;
    const owner = try readSource(allocator, "src/app/input_owner.zig");
    defer allocator.free(owner);
    const local = try readSource(allocator, "src/app/in_process_term_backend.zig");
    defer allocator.free(local);
    const remote = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(remote);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const app_session = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);
    const app_input = try readSource(allocator, "src/platform/macos/app_session/input.zig");
    defer allocator.free(app_input);

    try std.testing.expectEqual(@as(usize, 2), count(owner, "test \"CR2d1 InputOwner batch"));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub const InputBatchKind = enum(u8) {"));
    const batch_kind = between(owner, "pub const InputBatchKind = enum(u8) {", "pub const InputBatch = struct {") orelse
        return error.TestUnexpectedResult;
    inline for (.{ "paste = 1,", "ime_commit = 2,", "osc52_response = 3," }) |entry|
        try std.testing.expectEqual(@as(usize, 1), count(batch_kind, entry));
    inline for (.{
        "epoch: u64 = 1,",
        "next_sequence: u64 = 0,",
        "records: std.ArrayListUnmanaged(QueueRecord) = .empty,",
        "enqueue_batch:",
    }) |entry| try std.testing.expectEqual(@as(usize, 1), count(owner, entry));

    try std.testing.expectEqual(@as(usize, 1), count(local, "test \"CR2d1 local InputOwner batch는"));
    const local_batch = between(local, "fn enqueueInputBatch(", "pub fn init(") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(local_batch, "return .caller_owned;"));
    try std.testing.expectEqual(@as(usize, 1), count(remote, "test \"CR2d1 remote InputOwner batch는"));
    const remote_batch = between(remote, "fn enqueueInputBatch(", "fn resize(") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(remote_batch, "try rr.enqueueInputBatch(batch);"));
    try std.testing.expectEqual(@as(usize, 1), count(remote_batch, "return .backend_owned;"));

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "test \"CR2d1 remote input owner는"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "input_batches: input_owner_mod.StableQueueState,"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn enqueueInputBatch("));
    try std.testing.expectEqual(@as(usize, 0), try countProductSourcesExceptTwo(
        allocator,
        "enqueueInputBatch(batch)",
        "platform/macos/session_host/remote_runtime.zig",
        "platform/macos/session_host/remote_term_backend.zig",
    ));

    try std.testing.expectEqual(@as(usize, 1), count(app_session, "test \"CR2d1 AppSession batch routing은"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "fn remoteInputOwner("));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, "if (admission == .backend_owned) return true;"));
    // 기존 focus-loss OOM mutation0 행과 CR2d1 backend-owned 행이 각각 queue absence를 고정한다.
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "session.pending_pastes.get(target_id) == null"));
    try std.testing.expectEqual(@as(usize, 1), count(app_session, ".osc52_response, resp, false"));
    try std.testing.expectEqual(@as(usize, 2), count(app_input, ".ime_commit"));
}

test "CR2d2 경계는 key와 control의 단일 epoch sequence transcript를 고정한다" {
    const allocator = std.testing.allocator;
    const owner = try readSource(allocator, "src/app/input_owner.zig");
    defer allocator.free(owner);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);

    try std.testing.expectEqual(@as(usize, 1), count(owner, "pub const QueueRecordKind = enum(u8) {"));
    const kinds = between(owner, "pub const QueueRecordKind = enum(u8) {", "pub const QueueRecord = struct {") orelse
        return error.TestUnexpectedResult;
    inline for (.{
        "paste = 1,",
        "ime_commit = 2,",
        "osc52_response = 3,",
        "key_bytes = 4,",
        "scroll_to_bottom = 5,",
        "core_command = 6,",
    }) |entry| try std.testing.expectEqual(@as(usize, 1), count(kinds, entry));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR2d2 remote"));
    const key_admission = between(runtime, "pub fn sendInput(", "pub fn sendInputNonBlocking(") orelse
        return error.TestUnexpectedResult;
    const scroll_admission = between(runtime, "pub fn requestScrollToBottom(", "pub fn queueCoreCommand(") orelse
        return error.TestUnexpectedResult;
    const command_admission = between(runtime, "pub fn queueCoreCommand(", "const max_direct_input_bytes") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(key_admission, ".kind = .key_bytes,"));
    try std.testing.expectEqual(@as(usize, 1), count(scroll_admission, ".kind = .scroll_to_bottom,"));
    try std.testing.expectEqual(@as(usize, 1), count(command_admission, ".kind = .core_command,"));
    try std.testing.expectEqual(@as(usize, 5), count(runtime, "const sequence = try self.nextInputSequence();"));
    const testing_queue = between(runtime, "const queue_testing = if (builtin.is_test) struct {", "fn failControlAdmission(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(testing_queue, "const sequence = try self.nextInputSequence();"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn validateControlRecord("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "try self.validateControlRecord("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn retireControlRecordNoFail("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "self.retireControlRecordNoFail();"));
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

fn countProductSourcesExceptThree(
    allocator: std.mem.Allocator,
    needle: []const u8,
    first_excluded_path: []const u8,
    second_excluded_path: []const u8,
    third_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try dir.walk(allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, first_excluded_path) or
            std.mem.eql(u8, entry.path, second_excluded_path) or
            std.mem.eql(u8, entry.path, third_excluded_path)) continue;
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
