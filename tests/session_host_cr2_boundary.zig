const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("support/posix_walk.zig").posixWalk;

const max_source_bytes = 16 * 1024 * 1024;

test "CR2a 경계는 generation field 열두 개와 stable shell exclusion을 고정한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);

    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR2a RemoteGeneration "));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub const RemoteGeneration = struct {"));

    const generation = between(
        runtime,
        "pub const RemoteGeneration = struct {",
        "const RemoteGenerationSlot =",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "connection: RuntimeConnection,",
        "connection_generation: u64 = 0,",
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
    try std.testing.expectEqual(@as(usize, 1), count(shell, "generation_owner: ReconnectGenerationOwner,"));
    inline for (.{
        "connection: RuntimeConnection,",
        "connection_generation: u64 = 0,",
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
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "@fieldParentPtr(\"generation\", generation)"));
    // 네 값은 `RemoteRuntime` 이 커질 때마다 함께 움직인다. macOS 둘은 **실측**이고, linux 둘은 이
    // 모듈이 macOS 전용이라(session_host.zig 배럴) 이 트리에서 컴파일되지 않아 잴 수 없다.
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".Debug => 11440,"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".ReleaseFast => 11376,"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".Debug => 11328,"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, ".ReleaseFast => 11280,"));
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
        "pub fn publishUnavailableFromLiveWithCommit(",
        "pub fn close(",
        "pub fn tryLock(",
        "pub fn unlockPinned(",
        "pub fn metrics(",
    }) |declaration| try std.testing.expectEqual(@as(usize, 1), count(proxy, declaration));
    try std.testing.expectEqual(@as(usize, 1), count(proxy, "const marker = \"[session unavailable]\";"));
    try std.testing.expectEqual(@as(usize, 1), count(proxy, "generation <= self.current.generation"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "screen_source: *stable_screen_source.StableScreenSource,"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "test \"CR2b RemoteRuntime attach는 Surface에 stable proxy를 한 번 게시한다\""));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.screen_source.?.publishLive("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "self.surface.remote = self.screen_source.screenSource();"));
    try std.testing.expectEqual(@as(usize, 4), count(runtime, "self.deinitGenerationOwnerAndScreenSource();"));
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
        "publishUnavailableFromLiveWithCommit(",
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
    try std.testing.expectEqual(@as(usize, 6), count(runtime, "const sequence = try self.nextInputSequence();"));
    const testing_queue = between(runtime, "const queue_testing = if (builtin.is_test) struct {", "fn failControlAdmission(") orelse
        return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(testing_queue, "const sequence = try self.nextInputSequence();"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn validateControlRecord("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "try self.validateControlRecord("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn retireControlRecordNoFail("));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "self.retireControlRecordNoFail();"));
}

test "CR2d3 경계는 stable shell event cursor와 Window cursor 제거를 고정한다" {
    const allocator = std.testing.allocator;
    const cursor = try readSource(allocator, "src/app/event_cursor.zig");
    defer allocator.free(cursor);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const app_session = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);
    const term = try readSource(allocator, "src/platform/macos/app_session/term.zig");
    defer allocator.free(term);
    const notification = try readSource(allocator, "src/platform/macos/app_session/notification.zig");
    defer allocator.free(notification);

    try std.testing.expectEqual(@as(usize, 2), count(cursor, "test \"CR2d3 event cursor"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "event_cursor: maru.app.EventCursor = .{},"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "test \"CR2d3 remote stable shell"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn takeBellFor("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn takeClipboardReadFor("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn installEventCursorRuntime("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn removeEventCursorRuntime("));
    const backend_testing = between(
        backend,
        "pub const testing_api = if (builtin.is_test) struct {",
        "pub const SettlementBlocker = enum {",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(backend_testing, "pub fn installEventCursorRuntime("));
    try std.testing.expectEqual(@as(usize, 1), count(backend_testing, "pub fn removeEventCursorRuntime("));
    inline for (.{
        "test \"host-backed 벨:",
        "test \"host-backed OSC 52 read:",
        "test \"host-backed 재접속:",
    }) |named_test| try std.testing.expectEqual(@as(usize, 1), count(app_session, named_test));
    try std.testing.expectEqual(@as(usize, 3), count(app_session, "try installCr2d3EventRuntime(&runtime, handle);"));
    try std.testing.expectEqual(@as(usize, 3), count(app_session, "defer removeCr2d3EventRuntime(handle);"));
    inline for (.{ "last_bell_count", "last_clipboard_write_seq", "last_clipboard_read_seq" }) |old|
        try std.testing.expectEqual(@as(usize, 0), count(app_session, old));
    try std.testing.expectEqual(@as(usize, 1), count(term, "rb.clipboardWriteFor(term.rt.handle)"));
    try std.testing.expectEqual(@as(usize, 1), count(notification, "backend.takeBellFor(term.rt.handle)"));
    inline for (.{ ".event_cursor.prepare(", ".event_cursor.commit(" }) |callee| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            callee,
            "app/event_cursor.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );
}

test "CR2d4 경계는 remote Window transfer 제거와 stable runtime parity를 고정한다" {
    const allocator = std.testing.allocator;
    const app_session = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app_session);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    inline for (.{
        "test \"CR2d4 마지막 workspace 이동과 source close는 stable input과 event cursor를 보존한다\"",
        "test \"CR2d4 window merge는 옛 Window transfer 없이 stable runtime 상태만 보존한다\"",
    }) |named_test| try std.testing.expectEqual(@as(usize, 1), count(app_session, named_test));

    const transfer = between(
        app_session,
        "pub fn preparePendingPasteTransfer(",
        "pub fn mergeSessionInto(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(transfer, "if (term.surface.remote != null) continue;"));
    try std.testing.expectEqual(@as(usize, 1), count(transfer, "src.pending_pastes.get(term.surface.id)"));
    try std.testing.expectEqual(@as(usize, 1), count(transfer, "dst.pending_pastes.get(term.surface.id)"));

    try std.testing.expectEqual(@as(usize, 2), count(app_session, "try installCr2d4StableRuntime(&runtime, handle);"));
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "defer removeCr2d4StableRuntime(handle);"));
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "src.pending_pastes.get(term.surface.id) == null"));
    try std.testing.expectEqual(@as(usize, 2), count(app_session, "dst.pending_pastes.get(term.surface.id) == null"));
    const build_gate = between(
        build,
        "const session_host_cr2d4_step = b.step(",
        "const session_host_cr2e_a_step = b.step(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(build_gate, ".filters = &.{\"CR2d4\"},"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=5"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=1"));
}

test "CR2e-a 경계는 pointer-free reducer와 단일 제품 executor caller를 고정한다" {
    const allocator = std.testing.allocator;
    const reducer = try readSource(allocator, "src/platform/macos/session_host/reconnect_reducer.zig");
    defer allocator.free(reducer);
    const tests = try readSource(allocator, "tests/session_host_cr2e_reducer.zig");
    defer allocator.free(tests);
    const cr5_runtime_set = try readSource(
        allocator,
        "src/platform/macos/session_host/host_reconnect_runtime_ledger.zig",
    );
    defer allocator.free(cr5_runtime_set);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    inline for (.{
        "pub const JobPhase = enum(u8) {",
        "pub const RuntimeLedger = enum(u8) {",
        "pub const LocalState = enum(u8) {",
        "pub const MutationState = enum(u8) {",
        "pub const CloseTag = enum(u8) {",
        "pub const CloseState = union(CloseTag) {",
        "pub const EventTag = enum(u8) {",
        "pub const Event = union(EventTag) {",
        "pub const Decision = enum(u8) {",
        "pub const TerminalSummary = struct {",
        "pub fn reduce(before: State, event: Event) Error!Result {",
        "pub fn completeJob(before: State, summary: TerminalSummary) Error!Result {",
    }) |declaration| try std.testing.expectEqual(@as(usize, 1), count(reducer, declaration));
    try std.testing.expectEqual(@as(usize, 5), count(tests, "test \"CR2e-a reducer는"));
    // CR5a reuses the CR2e tags for host-wide aggregation instead of defining parallel enums.
    try std.testing.expectEqual(@as(usize, 1), count(
        cr5_runtime_set,
        "const reconnect_reducer = @import(\"reconnect_reducer.zig\");",
    ));
    // RemoteRuntime executes transitions, the CR5 ledger reuses tags, and CR5d verifies the exact
    // abandon decision at its backend-owned Window commit boundary.
    try std.testing.expectEqual(
        @as(usize, 3),
        try countProductSourcesExceptTwo(
            allocator,
            "@import(\"reconnect_reducer",
            "platform/macos/session_host/reconnect_reducer.zig",
            "platform/macos/session_host/reconnect_reducer.zig",
        ),
    );
    const build_gate = between(
        build,
        "const session_host_cr2e_a_step = b.step(",
        "const session_host_cr2e_b_step = b.step(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(build_gate, ".filters = &.{\"CR2e-a"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=5"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=1"));
}

test "CR2e-b 경계는 mutation seal substrate와 CR4b stable runtime owner만 연다" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, "src/platform/macos/session_host/reconnect_mutation_seal.zig");
    defer allocator.free(source);
    const tests = try readSource(allocator, "tests/session_host_cr2e_mutation.zig");
    defer allocator.free(tests);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);
    const remote_runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(remote_runtime);

    inline for (.{
        "pub const MutationLifecycle = enum(u8)",
        "pub const MutationLease = struct {",
        "pub const MutationOwner = struct {",
        "pub const GlobalPasteBudget = struct {",
        "pub const PausedInputMetadata = struct {",
        "pub const PausedPasteProjection = struct {",
        "pub const PreparedResend = struct {",
        "pub const PausedPasteStore = struct {",
        "pub const testing_api = if (@import(\"builtin\").is_test) struct {",
    }) |declaration| try std.testing.expectEqual(@as(usize, 1), count(source, declaration));
    inline for (.{
        "pub const max_paste_bytes: usize = 1024 * 1024;",
        "pub const max_global_bytes: usize = 8 * 1024 * 1024;",
        "pub const max_mutation_leases: usize = 64;",
        "pub const ttl_ns: i96 = 10 * 60 * std.time.ns_per_s;",
    }) |constant| try std.testing.expectEqual(@as(usize, 1), count(source, constant));
    try std.testing.expectEqual(@as(usize, 1), count(source, "std.crypto.secureZero(u8, bytes);"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(remote_runtime, "const reconnect_mutation_seal = @import(\"reconnect_mutation_seal.zig\");"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(remote_runtime, "mutation_owner: reconnect_mutation_seal.MutationOwner = .{},"),
    );
    try std.testing.expectEqual(@as(usize, 4), count(tests, "test \"CR2e-b"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptFour(
            allocator,
            "@import(\"reconnect_mutation_seal",
            "platform/macos/session_host/reconnect_mutation_seal.zig",
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/reconnect_resident_budget.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        ),
    );
    const build_gate = between(
        build,
        "const session_host_cr2e_b_step = b.step(",
        "const session_host_cr2e_c_step = b.step(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(build_gate, ".filters = &.{\"CR2e-b"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=4"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=1"));
}

test "CR2e-c 경계는 heap-pinned generation slot과 다음 단일 제품 owner를 고정한다" {
    const allocator = std.testing.allocator;
    const source = try readSource(allocator, "src/platform/macos/session_host/reconnect_generation_slot.zig");
    defer allocator.free(source);
    const tests = try readSource(allocator, "tests/session_host_cr2e_generation_slot.zig");
    defer allocator.free(tests);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(source, "pub fn GenerationSlot(comptime Payload: type) type"));
    inline for (.{
        "pub fn initInPlace(",
        "pub fn beginCandidate(",
        "pub fn initializeCandidate(",
        "pub fn abortEmptyCandidate(",
        "pub fn publishCandidate(",
        "pub fn abortCandidate(",
        "pub fn reclaimRetiring(",
        "pub fn deinit(",
    }) |declaration| try std.testing.expectEqual(@as(usize, 1), count(source, declaration));
    try std.testing.expectEqual(@as(usize, 4), count(tests, "test \"CR2e-c generation slot은"));
    try std.testing.expectEqual(
        @as(usize, 1),
        try countProductSourcesExceptTwo(
            allocator,
            "@import(\"reconnect_generation_slot",
            "platform/macos/session_host/reconnect_generation_slot.zig",
            "platform/macos/session_host/reconnect_generation_slot.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        try countProductSourcesExceptTwo(
            allocator,
            "GenerationSlot(",
            "platform/macos/session_host/reconnect_generation_slot.zig",
            "platform/macos/session_host/reconnect_generation_slot.zig",
        ),
    );
    const build_gate = between(
        build,
        "const session_host_cr2e_c_step = b.step(",
        "const session_host_cr2e_d_step = b.step(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(build_gate, ".filters = &.{\"CR2e-c"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=4"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=1"));
}

test "CR2e-d 경계는 actual RemoteGeneration PreparedReconnect와 in-place destructor를 고정한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const slot = try readSource(allocator, "src/platform/macos/session_host/reconnect_generation_slot.zig");
    defer allocator.free(slot);
    const screen = try readSource(allocator, "src/platform/macos/session_host/stable_screen_source.zig");
    defer allocator.free(screen);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub const PreparedReconnect = struct {"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub const ReconnectGenerationOwner = struct {"));
    const owner = between(
        runtime,
        "pub const ReconnectGenerationOwner = struct {",
        "fn generationScreenSource(",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "pub fn prepare(",
        "pub fn publish(",
        "pub fn abort(",
        "pub fn reclaimRetiring(",
    }) |declaration| try std.testing.expectEqual(@as(usize, 1), count(owner, declaration));
    try std.testing.expectEqual(@as(usize, 4), count(runtime, "test \"CR2e-d PreparedReconnect"));
    inline for (.{
        "pub fn candidatePayload(",
        "pub fn preflightPublishCandidate(",
        "pub fn publishCandidateNoFail(",
        "pub fn abortCandidateInPlace(",
        "pub fn reclaimRetiringInPlace(",
        "pub fn deinitInPlace(",
    }) |declaration| try std.testing.expectEqual(@as(usize, 1), count(slot, declaration));
    try std.testing.expectEqual(@as(usize, 1), count(screen, "pub fn publishLiveWithCommit("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "attachment.deinit(adapter),"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "attachment.deinit(),"));
    inline for (.{
        "candidatePayload(",
        "preflightPublishCandidate(",
        "publishCandidateNoFail(",
        "abortCandidateInPlace(",
        "reclaimRetiringInPlace(",
        "deinitInPlace(",
    }) |callee| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            callee,
            "platform/macos/session_host/reconnect_generation_slot.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "publishLiveWithCommit(",
            "platform/macos/session_host/stable_screen_source.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "ReconnectGenerationOwner",
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );

    const build_gate = between(
        build,
        "const session_host_cr2e_d_step = b.step(",
        "const session_host_cr2e_e1_step = b.step(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(build_gate, ".filters = &.{\"CR2e-d"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=4"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=1"));
}

test "CR2e-e1 경계는 current accessor와 backend facade만 generation을 읽게 한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    const runtime_owner = between(
        runtime,
        "pub const RemoteRuntime = struct {",
        "fn decodeResizeReply(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(runtime_owner, "generation_owner: ReconnectGenerationOwner,"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_owner, "fn currentGeneration("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_owner, "fn currentGenerationConst("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_owner, "pub const backend_api = struct {"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime_owner, "generation_storage"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime_owner, "generation_owner.slot.currentPayload()"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime_owner, "generation: RemoteGeneration,"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "@fieldParentPtr(\"generation\""));
    try std.testing.expectEqual(@as(usize, 0), count(backend, ".generation."));
    inline for (.{
        .{ "RemoteRuntime.backend_api.frameSummaryReady(", 1 },
        .{ "RemoteRuntime.backend_api.prepareFrameSummary(", 1 },
        // E3c stores the shared-connection probe and the remaining selected owners separately.
        .{ "RemoteRuntime.backend_api.storeFrameSummary(", 2 },
        .{ "RemoteRuntime.backend_api.takeFrameSummary(", 1 },
        .{ "RemoteRuntime.backend_api.pumpEnded(", 1 },
        .{ "RemoteRuntime.backend_api.markPumpEnded(", 2 },
        .{ "RemoteRuntime.backend_api.foregroundProcessGroup(", 1 },
        .{ "RemoteRuntime.backend_api.copyForegroundProcessNames(", 1 },
        .{ "RemoteRuntime.backend_api.observationMatches(", 1 },
        .{ "RemoteRuntime.backend_api.copyObservation(", 2 },
        .{ "RemoteRuntime.backend_api.dumpRecentText(", 1 },
    }) |entry| try std.testing.expectEqual(@as(usize, entry[1]), count(backend, entry[0]));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            ".backend_api.",
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
        ),
    );
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR2e-e1"));

    const build_gate = between(
        build,
        "const session_host_cr2e_e1_step = b.step(",
        "const session_host_cr2e_e2a_step = b.step(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(build_gate, ".filters = &.{\"CR2e-e1"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=2"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=1"));
}

test "CR2e-e2a 경계는 제품 runtime의 actual GenerationSlot current 저장소를 고정한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    const runtime_owner = between(
        runtime,
        "pub const RemoteRuntime = struct {",
        "fn decodeResizeReply(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(runtime_owner, "generation_owner: ReconnectGenerationOwner,"));
    try std.testing.expectEqual(@as(usize, 0), count(runtime_owner, "generation_storage"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime_owner, "generation_owner.slot.currentPayload()"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime_owner, "try self.initializeGenerationOwner("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_owner, "try self.generation_owner.publishInitial();"));
    try std.testing.expectEqual(@as(usize, 4), count(runtime_owner, "self.deinitGenerationOwnerAndScreenSource();"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR2e-e2a"));

    const build_gate = between(
        build,
        "const session_host_cr2e_e2a_step = b.step(",
        "const session_host_cr2e_e2b_step = b.step(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(build_gate, ".filters = &.{\"CR2e-e2a"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=2"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=1"));
}

test "CR2e-e2b 경계는 reducer Decision과 actual generation effect parity를 고정한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(runtime, "const ReconnectGenerationEffect = enum(u8) {"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(runtime, "fn reconnectGenerationEffect(decision: reconnect_reducer.Decision) ReconnectGenerationEffect {"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "const ReconnectProductExecutor = struct {"));
    inline for (.{
        "pub const ReconnectGenerationEffect",
        "pub fn reconnectGenerationEffect(",
        "pub const ReconnectProductExecutor",
    }) |shipping_surface| try std.testing.expectEqual(@as(usize, 0), count(runtime, shipping_surface));
    const executor = between(
        runtime,
        "const ReconnectProductExecutor = struct {",
        "/// CR2e-d의 제품 generation owner.",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "fn initInPlace(",
        "fn apply(",
        "fn completeJob(",
        "fn deinit(",
        "fn executeEffect(",
        "fn validate(",
    }) |declaration| try std.testing.expectEqual(@as(usize, 1), count(executor, declaration));
    try std.testing.expectEqual(@as(usize, 1), count(executor, "try self.executeEffect("));
    try std.testing.expectEqual(@as(usize, 1), count(executor, "reconnectRetiringMatchesLocal("));
    try std.testing.expectEqual(@as(usize, 3), count(executor, "self.state = result.state;"));
    const execute_effect = std.mem.indexOf(u8, executor, "try self.executeEffect(") orelse
        return error.TestUnexpectedResult;
    const first_state_publish = std.mem.indexOf(u8, executor, "self.state = result.state;") orelse
        return error.TestUnexpectedResult;
    try std.testing.expect(execute_effect < first_state_publish);
    const runtime_owner = between(
        runtime,
        "pub const RemoteRuntime = struct {",
        "fn decodeResizeReply(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(runtime_owner, "reconnect_executor: ReconnectProductExecutor,"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime_owner, "self.reconnect_executor = .{};"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(runtime_owner, "try self.reconnect_executor.initInPlace(&self.generation_owner, 1);"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(runtime_owner, "self.reconnect_executor.deinit(&self.generation_owner) catch"),
    );
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "reconnect_reducer.reduce(self.state.?, event)"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "reconnect_reducer.completeJob(self.state.?, summary)"));
    try std.testing.expectEqual(@as(usize, 4), count(runtime, "test \"CR2e-e2b"));
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "reconnect_executor.",
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );

    const build_gate = between(
        build,
        "const session_host_cr2e_e2b_step = b.step(",
        "const session_host_cr2e_e3a1_step = b.step(",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 2), count(build_gate, ".filters = &.{\"CR2e-e2b"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=4"));
    try std.testing.expectEqual(@as(usize, 1), count(build_gate, "--maru-expect-tests=1"));
}

test "CR2e-e3a1 경계는 candidate base resident ledger와 final zero를 고정한다" {
    const allocator = std.testing.allocator;
    const runtime = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const build_gate = try readSource(allocator, "build.zig");
    defer allocator.free(build_gate);

    try std.testing.expectEqual(
        @as(usize, 1),
        count(runtime, "const ReconnectResidentLedger = if (builtin.is_test) struct {"),
    );
    try std.testing.expectEqual(@as(usize, 0), count(runtime, "pub const ReconnectResidentLedger"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn reconnectCandidateResidentBytes() !usize"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, ".Debug => 3568,"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, ".ReleaseFast => 3552,"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "else => error.SkipZigTest,"));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "test \"CR2e-e3a1"));
    const e3a_tests = between(
        runtime,
        "test \"CR2e-e3a1 candidate base resident ledger는",
        "fn expectEveryReconnectDecisionReachable()",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 3), count(e3a_tests, "try owner.prepare("));
    try std.testing.expectEqual(@as(usize, 1), count(e3a_tests, "try owner.abort(&prepared);"));
    try std.testing.expectEqual(@as(usize, 2), count(e3a_tests, "try owner.publish(&prepared);"));
    try std.testing.expectEqual(@as(usize, 4), count(e3a_tests, "owner.reclaimRetiring()"));
    try std.testing.expectEqual(@as(usize, 1), count(
        build_gate,
        "const session_host_cr2e_e3a1_step = b.step(",
    ));
    try std.testing.expectEqual(@as(usize, 2), count(build_gate, ".filters = &.{\"CR2e-e3a1\"}"));
    try std.testing.expectEqual(@as(usize, 1), count(
        build_gate,
        "run_cr2e_e3a1_tests.addArg(\"--maru-expect-tests=2\")",
    ));
    try std.testing.expectEqual(@as(usize, 1), count(
        build_gate,
        "run_cr2e_e3a1_boundary_tests.addArg(\"--maru-expect-tests=1\")",
    ));
}

test "CR2e-e3a2 경계는 fixed resident budget과 ReleaseFast child RSS artifact를 고정한다" {
    const allocator = std.testing.allocator;
    const budget = try readSource(
        allocator,
        "src/platform/macos/session_host/reconnect_resident_budget.zig",
    );
    defer allocator.free(budget);
    const runtime = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const rss = try readSource(allocator, "tests/session_host_reconnect_rss.zig");
    defer allocator.free(rss);
    const validator = try readSource(
        allocator,
        "tools/perf/session_host_reconnect_rss_validator.zig",
    );
    defer allocator.free(validator);
    const rss_runner = try readSource(
        allocator,
        "tools/session_host_cr2e_e3a2_rss_test_runner.zig",
    );
    defer allocator.free(rss_runner);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    inline for (.{
        "pub const max_entry_bytes: usize = connection_slot.base_update_max_bytes;",
        "pub const max_entries: usize = reconnect_mutation.max_mutation_leases;",
        "pub const max_tracked_bytes: usize = max_entry_bytes * max_entries;",
        "pub const Role = enum(u8) { candidate, current, retiring, retry };",
        "pub const Lease = struct {",
        "pub const Snapshot = struct {",
        "fn BudgetType(",
        "const StructuralInventoryBudget = BudgetType(",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(budget, phrase));
    try std.testing.expectEqual(@as(usize, 5), count(budget, "test \"CR2e-e3a2 resident budget은"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub const rss_testing_api = if (builtin.is_test) struct {"));
    try std.testing.expectEqual(
        // e3c1 reconnect-only coordinator와 CR6e-c3b2a product coordinator가 policy owner를
        // 이동하지 않은 채 one-turn budget authority를 검사한다.
        @as(usize, 6),
        try countProductSourcesExceptTwo(
            allocator,
            "reconnect_resident_budget.zig",
            "platform/macos/session_host/reconnect_resident_budget.zig",
            "platform/macos/session_host/reconnect_resident_budget.zig",
        ),
    );
    const rss_testing_slice = between(
        runtime,
        "pub const rss_testing_api = if (builtin.is_test) struct {",
        "} else struct {};",
    ) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(usize, 1), count(rss_testing_slice, "@import(\"reconnect_resident_budget.zig\")"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub const owner_count: usize = resident_budget.max_entries;"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "test \"CR2e-e3a2 RSS workload는"));
    try std.testing.expectEqual(@as(usize, 3), count(rss, "test \"CR2e-e3a2 RSS"));
    try std.testing.expectEqual(@as(usize, 1), count(rss, "proc_pid_rusage(pid, mac.RUSAGE_INFO_V4"));
    try std.testing.expectEqual(@as(usize, 1), count(rss, "_ = c.execve(path.ptr, &argv, &env);"));
    try std.testing.expectEqual(@as(usize, 1), count(rss, "while (inherited_fd < getdtablesize())"));
    try std.testing.expectEqual(@as(usize, 2), count(rss, "run_nonce: [16]u8"));
    try std.testing.expectEqual(@as(usize, 1), count(rss, "peer_pid != c.getppid()"));
    try std.testing.expectEqual(@as(usize, 1), count(rss, "pub export var maru_cr2e_e3a2_rss_child_path:"));
    try std.testing.expectEqual(@as(usize, 1), count(rss_runner, "extern var maru_cr2e_e3a2_rss_child_path:"));
    try std.testing.expectEqual(@as(usize, 1), count(rss, "deinitAndSnapshot()"));
    try std.testing.expectEqual(@as(usize, 1), count(rss, "const measurement_tolerance_bytes: u64 = 64 * 1024 * 1024;"));
    try std.testing.expectEqual(@as(usize, 1), count(rss, "const deadline_ms: u64 = 10_000;"));
    try std.testing.expectEqual(@as(usize, 1), count(rss, "c.kill(pid, c.SIG.KILL)"));
    try std.testing.expectEqual(@as(usize, 2), count(rss, "c.waitpid(pid,"));
    try std.testing.expectEqual(@as(usize, 2), count(validator, "test \"CR2e-e3a2 RSS validator는"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, ".duplicate_field_behavior = .@\"error\","));
    try std.testing.expectEqual(@as(usize, 1), count(validator, ".ignore_unknown_fields = false,"));
    try std.testing.expectEqual(@as(usize, 1), count(validator, "final_live_allocations: u64"));
    try std.testing.expectEqual(@as(usize, 2), count(validator, "error.LogicalBoundExceeded"));

    const gate = between(
        build,
        "const session_host_cr2e_e3a2_step = b.step(",
        "const b3_1_boundary_tests = addProjectTest(b, .{",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "run_cr2e_e3a2_budget_tests.addArg(\"--maru-expect-tests=5\")",
        "run_cr2e_e3a2_validator_tests.addArg(\"--maru-expect-tests=2\")",
        "run_cr2e_e3a2_boundary_tests.addArg(\"--maru-expect-tests=1\")",
        "run_cr2e_e3a2_workload_tests.addArg(\"--maru-expect-tests=1\")",
        "run_cr2e_e3a2_rss_tests.addArtifactArg(cr2e_e3a2_rss_child_tests)",
        "run_cr2e_e3a2_rss_tests.addArg(\"--maru-expect-tests=2\")",
        "tests/artifacts/perf/session-host-reconnect-rss-macos.json",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(gate, phrase));
}

test "CR2e-e3b1 경계는 queued 64와 active 8 및 128 MiB 정책을 분리한다" {
    const allocator = std.testing.allocator;
    const budget = try readSource(
        allocator,
        "src/platform/macos/session_host/reconnect_resident_budget.zig",
    );
    defer allocator.free(budget);
    const policy = try readSource(
        allocator,
        "src/platform/macos/session_host/reconnect_admission_policy.zig",
    );
    defer allocator.free(policy);
    const queue_owner = try readSource(
        allocator,
        "src/platform/macos/session_host/reconnect_admission_owner.zig",
    );
    defer allocator.free(queue_owner);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    inline for (.{
        "pub const max_queued_admissions: usize = policy.max_queued_admissions;",
        "pub const max_active_entries: usize = policy.max_active_resident_entries;",
        "pub const max_policy_bytes: usize = policy.max_resident_bytes;",
        "pub const ReconnectAdmissionBudget = BudgetType(",
        "const StructuralInventoryBudget = BudgetType(",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(budget, phrase));
    try std.testing.expectEqual(@as(usize, 3), count(budget, "owner_incarnation: u64 = 0,"));
    try std.testing.expectEqual(@as(usize, 3), count(budget, "process_nonce: u64 = 0,"));
    try std.testing.expectEqual(@as(usize, 3), count(budget, "owner_pid: u32 = 0,"));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(budget, "var next_budget_owner_incarnation: std.atomic.Value(u64) = .init(1);"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(budget, "pub fn initInPlace(self: *Self, process_nonce: u64) !void {"),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(budget, "const process_seal = @import(\"process_seal_service.zig\");"),
    );
    inline for (.{
        "fn readExactBeforeForTest(",
        "fn reapChildForTest(",
        "std.c.waitpid(pid, &status, std.c.W.NOHANG)",
        "std.c.poll(@ptrCast(&ready), 1, @intCast(deadline_ms - now))",
        "reapChildForTest(child, true, &child_reaped)",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(budget, phrase));
    inline for (.{
        "pub const max_queued_admissions: usize = 64;",
        "pub const max_active_resident_entries: usize = 8;",
        "pub const max_resident_bytes: usize = 128 * 1024 * 1024;",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(policy, phrase));
    try std.testing.expectEqual(
        @as(usize, 1),
        count(queue_owner, "pub const capacity: usize = policy.max_queued_admissions;"),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "reconnect_admission_policy.zig",
            "platform/macos/session_host/reconnect_admission_owner.zig",
            "platform/macos/session_host/reconnect_resident_budget.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 1),
        count(budget, "test \"CR2e-e3b1 reconnect admission budget은"),
    );
    try std.testing.expectEqual(
        // app-process owner, backend drain, e3c1 coordinator와 c3b2a product coordinator가
        // policy budget을 각각 소유/소비한다.
        @as(usize, 4),
        try countProductSourcesExceptTwo(
            allocator,
            "reconnect_resident_budget.zig",
            "platform/macos/session_host/reconnect_resident_budget.zig",
            "platform/macos/session_host/remote_runtime.zig",
        ),
    );

    const gate = between(
        build,
        "const session_host_cr2e_e3b1_step = b.step(",
        "const b3_1_boundary_tests = addProjectTest(b, .{",
    ) orelse return error.TestUnexpectedResult;
    inline for (.{
        "session_host_cr2e_e3b1_step.dependOn(session_host_cr2e_e3a2_step)",
        "run_cr2e_e3b1_budget_tests.addArg(\"--maru-expect-tests=1\")",
        "run_cr2e_e3b1_boundary_tests.addArg(\"--maru-expect-tests=1\")",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(gate, phrase));
}

test "CR2e-e3b2 경계는 sealed queue drain과 stable executor lease의 sole product caller를 고정한다" {
    const allocator = std.testing.allocator;
    const app = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const owner = try readSource(
        allocator,
        "src/platform/macos/session_host/app_process_incident_owner.zig",
    );
    defer allocator.free(owner);
    const backend = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_term_backend.zig",
    );
    defer allocator.free(backend);
    const runtime = try readSource(
        allocator,
        "src/platform/macos/session_host/remote_runtime.zig",
    );
    defer allocator.free(runtime);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(owner, "reconnect_budget: reconnect_budget_mod.ReconnectAdmissionBudget = .{},"));
    // e3c1부터 AppSession은 backend leaf를 직접 호출하지 않고 coordinator sole drain을 탄다.
    try std.testing.expectEqual(@as(usize, 0), count(app, "backend.drainReconnectAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(app, "app_session_host_coordinator.drainReconnectAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn drainReconnectAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "test \"CR2e-e3b2 admission drain은"));
    // 실패 복구 defer, runtime Busy, resident cap의 세 경로가 모두 같은 sealed row를 재시도 상태로 돌린다.
    try std.testing.expectEqual(@as(usize, 3), count(backend, "admissions.settleDispatch(dispatch, .retry_later)"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "fn bindAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "resident_lease: reconnect_resident_budget.Lease = .{},"));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "test \"CR2e-e3b2 actual stable executor는"));
    inline for (.{
        "const session_host_cr2e_e3b2_step = b.step(",
        "session_host_cr2e_e3b2_step.dependOn(session_host_cr2e_e3b1_step)",
        "run_cr2e_e3b2_runtime_tests.addArg(\"--maru-expect-tests=1\")",
        "run_cr2e_e3b2_drain_tests.addArg(\"--maru-expect-tests=1\")",
        "run_cr2e_e3b2_boundary_tests.addArg(\"--maru-expect-tests=1\")",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(build, phrase));
}

test "CR2e-e3c1 경계는 coordinator sole drain과 기존 owner 보존을 고정한다" {
    const allocator = std.testing.allocator;
    const app = try readSource(allocator, "src/platform/macos/app_session.zig");
    defer allocator.free(app);
    const owner = try readSource(allocator, "src/platform/macos/session_host/app_process_incident_owner.zig");
    defer allocator.free(owner);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const coordinator = try readSource(allocator, "src/platform/macos/session_host/session_host_coordinator.zig");
    defer allocator.free(coordinator);
    const product_coordinator = try readSource(
        allocator,
        "src/platform/macos/session_host/reconnect_product_coordinator.zig",
    );
    defer allocator.free(product_coordinator);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(owner, "reconnect_admissions: reconnect_owner_mod.Owner = .{},"));
    try std.testing.expectEqual(@as(usize, 1), count(owner, "reconnect_budget: reconnect_budget_mod.ReconnectAdmissionBudget = .{},"));
    try std.testing.expectEqual(@as(usize, 0), count(app, "backend.drainReconnectAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(app, "app_session_host_coordinator.drainReconnectAdmission("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "return backend.drainReconnectAdmission(admissions, budget);"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn validateReconnectCoordinatorTarget("));
    try std.testing.expectEqual(@as(usize, 1), count(product_coordinator, "validateReconnectCoordinatorTarget("));
    try std.testing.expectEqual(
        @as(usize, 1),
        try countProductSourcesExceptTwo(
            allocator,
            "validateReconnectCoordinatorTarget(",
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/session_host/session_host_coordinator.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptThree(
            allocator,
            ".drainReconnectAdmission(",
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/session_host/session_host_coordinator.zig",
            "platform/macos/app_session.zig",
        ),
    );
    inline for (.{
        "sessionHostCoordinatorSeal(",
        "copied_coordinator.self_addr = @intFromPtr(&copied_coordinator);",
        "std.Thread.spawn(",
        "try replacement_backend.claimProductSingleton();",
        "var stale_backend_copy = stale_backend;",
    }) |phrase| try std.testing.expect(count(coordinator, phrase) >= 1);
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "test \"CR2e-e3c1 coordinator는"));
    inline for (.{
        "const session_host_cr2e_e3c1_step = b.step(",
        "session_host_cr2e_e3c1_step.dependOn(session_host_cr2e_e3b2_step)",
        "run_cr2e_e3c1_coordinator_tests.addArg(\"--maru-expect-tests=1\")",
        "run_cr2e_e3c1_boundary_tests.addArg(\"--maru-expect-tests=1\")",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(build, phrase));
}

test "CR2e-e3c2 경계는 typed external receipt와 sole runtime consumer를 고정한다" {
    const allocator = std.testing.allocator;
    const coordinator = try readSource(allocator, "src/platform/macos/session_host/session_host_coordinator.zig");
    defer allocator.free(coordinator);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "pub const DirectReleaseReceipt = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "pub const DirectReleaseEvidence = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "pub fn prepareDirectReleaseReceipt("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "pub fn applyExternalReconnectEvent("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn directReleaseTarget("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn applyDirectReleaseTarget("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "pub fn applyDirectReleaseProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(runtime, "reconnect_reducer.reduce(runtime.reconnect_executor.state.?, .retry_direct_granted)"));
    // e3c2 owns two direct-release checks; CR6e-c3a's exact incident validator deliberately
    // delegates its connection half to the same canonical predicate instead of cloning it.
    try std.testing.expectEqual(@as(usize, 3), count(runtime, "matchesReconnectAdmission(runtime, admission)"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "RemoteRuntime.backend_api.directReleaseProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "RemoteRuntime.backend_api.applyDirectReleaseProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "backend.directReleaseTarget("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "backend.applyDirectReleaseTarget("));
    inline for (.{
        "directReleaseProjection(",
        "applyDirectReleaseProjection(",
    }) |callee| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptThree(
            allocator,
            callee,
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/session_host/session_host_coordinator.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "directReleaseTarget(",
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/session_host/session_host_coordinator.zig",
        ),
    );
    inline for (.{
        "prepareDirectReleaseReceipt(",
        "applyExternalReconnectEvent(",
    }) |callee| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            callee,
            "platform/macos/session_host/session_host_coordinator.zig",
            "",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            ".applyDirectReleaseTarget(",
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/session_host/session_host_coordinator.zig",
        ),
    );
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "test \"CR2e-e3c2 typed direct release receipt는"));
    inline for (.{
        "const session_host_cr2e_e3c2_step = b.step(",
        "session_host_cr2e_e3c2_step.dependOn(session_host_cr2e_e3c1_step)",
        "run_cr2e_e3c2_coordinator_tests.addArg(\"--maru-expect-tests=1\")",
        "run_cr2e_e3c2_boundary_tests.addArg(\"--maru-expect-tests=1\")",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(build, phrase));
}

test "CR2e-e3c3 경계는 typed close receipt와 mixed outcome sole consumer를 고정한다" {
    const allocator = std.testing.allocator;
    const coordinator = try readSource(allocator, "src/platform/macos/session_host/session_host_coordinator.zig");
    defer allocator.free(coordinator);
    const backend = try readSource(allocator, "src/platform/macos/session_host/remote_term_backend.zig");
    defer allocator.free(backend);
    const runtime = try readSource(allocator, "src/platform/macos/session_host/remote_runtime.zig");
    defer allocator.free(runtime);
    const seal = try readSource(allocator, "src/platform/macos/session_host/process_seal_service.zig");
    defer allocator.free(seal);
    const build = try readSource(allocator, "build.zig");
    defer allocator.free(build);

    inline for (.{
        "pub const CloseEventEvidence = struct",
        "pub const CloseEventReceipt = struct",
        "pub fn prepareCloseEventReceipt(",
        "pub fn applyCloseEvent(",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(coordinator, phrase));
    inline for (.{
        "pub const CloseEventTag = enum(u8)",
        "pub const CloseEvent = struct",
        "pub const CloseStateProjection = struct",
        "pub const CloseTransitionProjection = struct",
        "pub fn applyCloseTransitionProjection(",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(runtime, phrase));
    try std.testing.expectEqual(@as(usize, 2), count(runtime, "pub fn closeTransitionProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub const CloseTransitionTarget = struct"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, ".runtime_id = entry.runtime.appQuitRuntimeId(),"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "!std.mem.eql(u8, &runtime_id, &target.runtime_id)"));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn closeTransitionTarget("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "pub fn applyCloseTransitionTarget("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "backend.closeTransitionTarget("));
    try std.testing.expectEqual(@as(usize, 1), count(coordinator, "backend.applyCloseTransitionTarget("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "RemoteRuntime.backend_api.closeTransitionProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(backend, "RemoteRuntime.backend_api.applyCloseTransitionProjection("));
    try std.testing.expectEqual(@as(usize, 1), count(seal, "maru.reconnect-close-receipt.v1"));
    inline for (.{
        "closeTransitionProjection(",
        "applyCloseTransitionProjection(",
    }) |callee| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptThree(
            allocator,
            callee,
            "platform/macos/session_host/remote_runtime.zig",
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/session_host/session_host_coordinator.zig",
        ),
    );
    try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            "closeTransitionTarget(",
            "platform/macos/session_host/remote_term_backend.zig",
            "platform/macos/session_host/session_host_coordinator.zig",
        ),
    );
    inline for (.{
        "prepareCloseEventReceipt(",
        "applyCloseEvent(",
    }) |callee| try std.testing.expectEqual(
        @as(usize, 0),
        try countProductSourcesExceptTwo(
            allocator,
            callee,
            "platform/macos/session_host/session_host_coordinator.zig",
            "",
        ),
    );
    inline for (.{
        "session_host_cr2e_e3c3_step.dependOn(session_host_cr2e_e3c2_step)",
        "run_cr2e_e3c3_coordinator_tests.addArg(\"--maru-expect-tests=1\")",
        "run_cr2e_e3c3_boundary_tests.addArg(\"--maru-expect-tests=1\")",
    }) |phrase| try std.testing.expectEqual(@as(usize, 1), count(build, phrase));
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
    var walker = try posixWalk(dir, allocator);
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
    var walker = try posixWalk(dir, allocator);
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

fn countProductSourcesExceptFour(
    allocator: std.mem.Allocator,
    needle: []const u8,
    first_excluded_path: []const u8,
    second_excluded_path: []const u8,
    third_excluded_path: []const u8,
    fourth_excluded_path: []const u8,
) !usize {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src", .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    var total: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        if (std.mem.eql(u8, entry.path, first_excluded_path) or
            std.mem.eql(u8, entry.path, second_excluded_path) or
            std.mem.eql(u8, entry.path, third_excluded_path) or
            std.mem.eql(u8, entry.path, fourth_excluded_path)) continue;
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
