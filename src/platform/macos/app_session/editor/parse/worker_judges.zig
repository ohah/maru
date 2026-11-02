//! 워커 내부 판정자를 별도 루트에서만 수집한다. 앱은 worker 라이브러리만 가져온다.
const std = @import("std");
const maru = @import("maru");
const syntax = @import("syntax");
const worker = @import("worker.zig");
const Service = worker.Service;
const Completion = worker.Completion;
const State = worker.testing.WorkerState;
const TestAudit = worker.TestAudit;
const Mode = worker.Mode;
const Outcome = worker.Outcome;
const buffer = maru.session.editor.buffer;
const request = maru.session.editor.syntax.request;

const test_input: request.Input = .{ .document = .{ .owner = 1, .slot = 2, .generation = 3 }, .revision = 1, .grammar = .{ .identity = @backingInt(syntax.Language.zig), .generation = 0 } };
fn testQueue(service: *Service, gate: *request.Gate, input: request.Input, source: buffer.Buffer, pause: ?*syntax.Cancellation.TestGate) !request.Request {
    var snapshot = source.snapshot();
    errdefer snapshot.deinit();
    return worker.testing.submit(service, gate, input, &snapshot, .zig, null, pause);
}
fn waitReady(service: *Service) void {
    const state = service.state;
    const io_value = worker.testing.io(state);
    state.mutex.lockUncancelable(io_value);
    defer state.mutex.unlock(io_value);
    while (state.completed.first == null) state.changed.waitUncancelable(io_value, &state.mutex);
}
fn testTake(service: *Service) Completion {
    waitReady(service);
    return service.take().?;
}
fn waitEntered(pause: *syntax.Cancellation.TestGate) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 10_000_000_000;
    while (!pause.entered.load(.acquire)) {
        if (std.Io.Clock.awake.now(std.testing.io).nanoseconds > deadline) return error.CallbackNotEntered;
        std.Thread.yield() catch {};
    }
}
fn largeTestBuffer(a: std.mem.Allocator) !buffer.Buffer {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(a);
    for (0..3000) |_| try text.appendSlice(a, "const item = 1;\n");
    return buffer.Buffer.init(a, text.items);
}

test "parse worker 최신 대기만 유지하고 실행 중인 이전 요청은 C 반환까지 보존한다" {
    const a = std.testing.allocator;
    var first = try largeTestBuffer(a);
    defer first.deinit();
    var second = try buffer.Buffer.init(a, "const second = 2;\n");
    defer second.deinit();
    var latest = try buffer.Buffer.init(a, "const latest = 3;\n");
    defer latest.deinit();
    var audit: TestAudit = .{ .main_thread = std.Thread.getCurrentId() };
    var copies = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
    {
        var service = try Service.init(a, .{ .audit = &audit, .copy_allocator = copies.allocator() });
        defer service.deinit() catch unreachable;
        var pause: syntax.Cancellation.TestGate = .{};
        defer pause.release();
        var gate: request.Gate = .{};
        _ = try testQueue(&service, &gate, test_input, first, &pause);
        try waitEntered(&pause);
        var input = test_input;
        input.revision += 1;
        _ = try testQueue(&service, &gate, input, second, null);
        input.revision += 1;
        const tag = try testQueue(&service, &gate, input, latest, null);
        service.reap(); // 교체된 미실행 노드의 snapshot은 메인에서 회수한다.
        pause.release();
        var old = testTake(&service);
        defer old.release();
        try std.testing.expectEqual(Outcome.cancelled, old.outcome());
        try std.testing.expect(!old.accept(&gate));
        var current = testTake(&service);
        defer current.release();
        try std.testing.expectEqual(tag, current.tag());
        try std.testing.expectEqual(Outcome.ready, current.outcome());
        try std.testing.expect(current.accept(&gate));
        try std.testing.expect(!current.accept(&gate));
        try std.testing.expect(current.provider().?.tree != null);
        const bytes = try current.job.snapshot.copyRange(a, 0, current.job.snapshot.byteLen());
        defer a.free(bytes);
        try std.testing.expectEqualStrings("const latest = 3;\n", bytes);
        try std.testing.expect(service.take() == null);
    }
    try std.testing.expectEqual(@as(usize, 0), audit.cancelled_with_tree.load(.acquire));
    try std.testing.expectEqual(audit.created.load(.acquire), audit.destroyed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 3), audit.reclaimed.load(.acquire));
    try std.testing.expect(!audit.wrong_thread.load(.acquire));
    try std.testing.expectEqual(copies.allocated_bytes, copies.freed_bytes);
}

test "parse worker 한 문서 취소는 다른 문서 대기를 지우지 않는다" {
    const a = std.testing.allocator;
    var first = try largeTestBuffer(a);
    defer first.deinit();
    var other = try buffer.Buffer.init(a, "const other = 7;\n");
    defer other.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var pause: syntax.Cancellation.TestGate = .{};
    defer pause.release();
    var gate_a: request.Gate = .{};
    var gate_b: request.Gate = .{};
    _ = try testQueue(&service, &gate_a, test_input, first, &pause);
    try waitEntered(&pause);
    var input = test_input;
    input.document.owner += 1;
    _ = try testQueue(&service, &gate_b, input, other, null);
    gate_a.invalidate();
    service.cancelDocument(test_input.document);
    pause.release();
    var cancelled = testTake(&service);
    defer cancelled.release();
    try std.testing.expectEqual(Outcome.cancelled, cancelled.outcome());
    var ready = testTake(&service);
    defer ready.release();
    try std.testing.expect(ready.accept(&gate_b));
    try std.testing.expectEqual(input.document, ready.tag().input.document);
}

test "parse worker 준비 할당 실패는 snapshot을 가져가지 않고 이전 수락을 지운다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "const saved = 1;");
    defer source.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{});
    var service = try Service.init(failing.allocator(), .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    const old_tag = try testQueue(&service, &gate, test_input, source, null);
    var old = testTake(&service);
    defer old.release();
    try std.testing.expect(old.accept(&gate));
    var input = test_input;
    input.revision += 1;
    var snapshot = source.snapshot();
    var owns_snapshot = true;
    defer if (owns_snapshot) snapshot.deinit();
    failing.fail_index = failing.alloc_index;
    if (service.submit(&gate, input, &snapshot, .zig)) |_| {
        owns_snapshot = false;
        return error.ExpectedAllocationFailure;
    } else |err| try std.testing.expect(err == error.OutOfMemory);
    try std.testing.expect(!gate.isCurrent(old_tag));
    try std.testing.expectEqual(source.byteLen(), snapshot.byteLen());
}

test "parse worker 본문 복사 OOM은 실패 결과로 반환하고 원본 snapshot을 회수한다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "const n = 1;");
    defer source.deinit();
    var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = 0 });
    var service = try Service.init(a, .{ .copy_allocator = failing.allocator() });
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    var result = testTake(&service);
    defer result.release();
    try std.testing.expectEqual(Outcome.out_of_memory, result.outcome());
    try std.testing.expect(!result.accept(&gate));
    try std.testing.expect(result.provider() == null);
}

test "parse worker 결과를 빌린 동안 종료는 거절하고 반환 뒤 종료한다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "const n = 1;");
    defer source.deinit();
    var audit: TestAudit = .{ .main_thread = std.Thread.getCurrentId() };
    var copies = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
    var service = try Service.init(a, .{ .audit = &audit, .copy_allocator = copies.allocator() });
    var service_open = true;
    defer if (service_open) {
        service.deinit() catch unreachable;
    };
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    var result = testTake(&service);
    var result_open = true;
    defer if (result_open) result.release();
    try std.testing.expectError(error.ResultsHeld, service.deinit());
    try std.testing.expect(result.provider().?.tree != null);
    result.release();
    result_open = false;
    try service.deinit();
    service_open = false;
    try std.testing.expectEqual(@as(usize, 1), audit.created.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), audit.destroyed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), audit.reclaimed.load(.acquire));
    try std.testing.expect(!audit.wrong_thread.load(.acquire));
    try std.testing.expect(copies.allocated_bytes > 0);
    try std.testing.expectEqual(copies.allocated_bytes, copies.freed_bytes);
}

test "parse worker 실행과 대기가 있어도 종료는 모든 소유 자료를 회수한다" {
    const a = std.testing.allocator;
    var first = try largeTestBuffer(a);
    var first_open = true;
    defer if (first_open) first.deinit();
    var other = try buffer.Buffer.init(a, "const other = 7;");
    defer other.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    // 작은 결과를 세 소비자가 보유하고, 다음 C 작업을 멈춰 퇴역 큐 공개 시점을 판정한다.
    var initial_gate: request.Gate = .{};
    var initial_input = test_input;
    initial_input.document.slot += 2;
    _ = try testQueue(&service, &initial_gate, initial_input, other, null);
    const original = testTake(&service);
    var handles = [_]Completion{ original, try original.retain(), try original.retain() };
    var live = [_]bool{ true, true, true };
    defer for (&handles, live) |*handle, active| {
        if (active) handle.release();
    };
    const refs_after_retain = original.job.main_refs;
    const held_after_retain = service.heldCount();
    // 잘못된 참조 수를 주입한 실행도 보유 핸들 세 개를 안전하게 반납한 뒤 실패를 보고한다.
    original.job.main_refs = 3;
    service.state.held = 3;
    try std.testing.expectEqual(@as(usize, 3), refs_after_retain);
    try std.testing.expectEqual(@as(usize, 3), held_after_retain);
    original.job.main_refs = std.math.maxInt(usize);
    const overflow_refs = original.retain();
    original.job.main_refs = 3;
    try std.testing.expectError(error.ReferenceOverflow, overflow_refs);
    try std.testing.expectEqual(@as(usize, 3), service.heldCount());
    service.state.held = std.math.maxInt(usize);
    const overflow_held = original.retain();
    service.state.held = 3;
    try std.testing.expectError(error.ReferenceOverflow, overflow_held);
    try std.testing.expectEqual(@as(usize, 3), original.job.main_refs);
    var pause: syntax.Cancellation.TestGate = .{};
    defer pause.release();
    var gate_a: request.Gate = .{};
    var gate_b: request.Gate = .{};
    _ = try testQueue(&service, &gate_a, test_input, first, &pause);
    try waitEntered(&pause);
    handles[0].release();
    live[0] = false;
    handles[1].release();
    live[1] = false;
    try std.testing.expectEqual(@as(usize, 1), original.job.main_refs);
    {
        const state = service.state;
        const io = worker.testing.io(state);
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        const premature = state.retiring.first != null;
        // C 작업 장벽이 있으므로 잘못 게시한 노드는 아직 워커가 만지지 않았다. 검사 실패의 cleanup만 복구한다.
        if (premature) state.retiring = .{};
        try std.testing.expect(!premature);
    }
    handles[2].release();
    live[2] = false;
    {
        const state = service.state;
        const io = worker.testing.io(state);
        state.mutex.lockUncancelable(io);
        defer state.mutex.unlock(io);
        try std.testing.expect(state.retiring.first == original.job);
    }
    first.deinit();
    first_open = false;
    var input = test_input;
    input.document.slot += 1;
    _ = try testQueue(&service, &gate_b, input, other, null);
    pause.release();
}

test "parse worker 빈 입력과 미지원 언어를 구분한다" {
    const a = std.testing.allocator;
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    const oversized = try a.alloc(u8, syntax.max_parse_bytes + 1);
    defer a.free(oversized);
    @memset(oversized, 'x');
    for (0..3) |kind| {
        const language: syntax.Language = if (kind == 1) .other else .zig;
        var source = try buffer.Buffer.init(a, if (kind == 0) "" else if (kind == 1) "text" else oversized);
        defer source.deinit();
        var snapshot = source.snapshot();
        var input = test_input;
        input.grammar.identity = @backingInt(language);
        _ = service.submit(&gate, input, &snapshot, language) catch |err| {
            snapshot.deinit();
            return err;
        };
        var result = testTake(&service);
        defer result.release();
        try std.testing.expectEqual(if (kind == 0) Outcome.ready else Outcome.unavailable, result.outcome());
        const expected_reason: ?worker.UnavailableReason = if (kind == 0) null else if (kind == 1) .unsupported_language else .input_limit;
        try std.testing.expectEqual(expected_reason, result.unavailableReason());
        try std.testing.expectEqual(kind == 0, result.accept(&gate));
    }
}

test "parse worker 완료 후에도 take 전 취소된 결과를 수락하지 않는다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "const n = 1;");
    defer source.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    // 성공뿐 아니라 이미 원인이 기록된 미지원 완료도 취소되면 그 이유를 숨겨야 한다.
    for ([_]syntax.Language{ .zig, .other }) |language| {
        var snapshot = source.snapshot();
        _ = service.submit(&gate, test_input, &snapshot, language) catch |err| {
            snapshot.deinit();
            return err;
        };
        waitReady(&service);
        gate.invalidate();
        service.cancelDocument(test_input.document);
        var result = service.take().?;
        defer result.release();
        try std.testing.expectEqual(Outcome.cancelled, result.outcome());
        try std.testing.expectEqual(@as(?worker.UnavailableReason, null), result.unavailableReason());
        try std.testing.expect(!result.accept(&gate));
        try std.testing.expect(result.provider() == null);
    }
}

test "parse worker 새 입력은 아직 빌리지 않은 이전 완료도 퇴역시킨다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "const n = 1;");
    defer source.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    const old = try testQueue(&service, &gate, test_input, source, null);
    waitReady(&service);
    var input = test_input;
    input.revision += 1;
    const latest = try testQueue(&service, &gate, input, source, null);
    var result = testTake(&service);
    defer result.release();
    try std.testing.expect(old.serial != result.tag().serial);
    try std.testing.expectEqual(latest, result.tag());
    try std.testing.expect(result.accept(&gate));
    try std.testing.expect(service.take() == null);
}

fn testQueueFrom(service: *Service, gate: *request.Gate, input: request.Input, source: buffer.Buffer, base: *const Completion, pause: ?*syntax.Cancellation.TestGate) !request.Request {
    var snapshot = source.snapshot();
    errdefer snapshot.deinit();
    return worker.testing.submit(service, gate, input, &snapshot, .zig, base, pause);
}
fn expectTree(result: *const Completion, source: []const u8, language: syntax.Language) !void {
    var cold = syntax.Provider.init(source, language, 0) orelse return error.NoProvider;
    defer cold.deinit();
    try std.testing.expect(syntax.testing.equal(cold.tree.?, result.provider().?.tree.?) != null);
    var token: syntax.Cancellation = .{};
    try cold.prepareStickySummary(std.testing.allocator, &token);
    try std.testing.expect(result.provider().?.sticky_summary.tree != null);
    try std.testing.expectEqual(cold.sticky_summary.count, result.provider().?.sticky_summary.count);
    try std.testing.expectEqual(result.provider().?.tree_gen, result.provider().?.sticky_summary.generation);
}

test "parse worker 증분과 같은 본문 재사용은 cold 전체 노드와 같고 원본은 불변이다" {
    // 넓은 재파싱은 잘못된 편집 point를 덮을 수 있으므로 입력 좌표 계약도 따로 대조한다.
    try std.testing.expectEqual(syntax.Point{ .row = 1, .column = 7 }, syntax.pointAt("a\r\n가😀", 10));
    try std.testing.expectEqual(syntax.Point{ .row = 0, .column = 2 }, syntax.pointAt("a\r\n가😀", 2));
    const a = std.testing.allocator;
    const before = "// 가 😀\r\npub fn first() void {\r\n const s = \"가\"; _ = s;\r\n}\r\n";
    const after = "// 가 😁\r\npub fn second() void {\r\n const s = \"각\"; _ = s;\r\n}\r\npub fn tail() void {}\r\n";
    var source_a = try buffer.Buffer.init(a, before);
    defer source_a.deinit();
    var source_b = try buffer.Buffer.init(a, after);
    defer source_b.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    const tag_a = try testQueue(&service, &gate, test_input, source_a, null);
    var first = testTake(&service);
    defer first.release();
    try std.testing.expect(first.accept(&gate));
    var input = test_input;
    input.revision += 1;
    const tag_b = try testQueueFrom(&service, &gate, input, source_b, &first, null);
    var next = testTake(&service);
    defer next.release();
    try std.testing.expectEqual(Mode.incremental, next.mode());
    try std.testing.expectEqual(tag_a, next.basis().?);
    try std.testing.expect(next.accept(&gate));
    try expectTree(&next, after, .zig);
    try expectTree(&first, before, .zig);
    input.revision += 1;
    _ = try testQueueFrom(&service, &gate, input, source_b, &next, null);
    var same = testTake(&service);
    defer same.release();
    try std.testing.expectEqual(Mode.reused, same.mode());
    try std.testing.expectEqual(tag_b, same.basis().?);
    try std.testing.expect(same.accept(&gate));
    try expectTree(&same, after, .zig);
    var empty = try buffer.Buffer.init(a, "");
    defer empty.deinit();
    input.revision += 1;
    _ = try testQueueFrom(&service, &gate, input, empty, &same, null);
    var cleared = testTake(&service);
    defer cleared.release();
    try std.testing.expectEqual(Mode.incremental, cleared.mode());
    try std.testing.expect(cleared.accept(&gate));
    try std.testing.expect(cleared.provider().?.tree == null);
    input.revision += 1;
    _ = try testQueueFrom(&service, &gate, input, source_b, &cleared, null);
    var restored = testTake(&service);
    defer restored.release();
    try std.testing.expectEqual(Mode.cold, restored.mode());
    try std.testing.expect(restored.basis() == null);
    try std.testing.expect(restored.accept(&gate));
    try expectTree(&restored, after, .zig);
}

test "parse worker 증분 native 중단은 남은 이전 트리를 성공으로 공개하지 않는다" {
    const a = std.testing.allocator;
    const before = "pub fn first() void {}\n";
    var source_a = try buffer.Buffer.init(a, before);
    defer source_a.deinit();
    var source_b = try largeTestBuffer(a);
    defer source_b.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var pause: syntax.Cancellation.TestGate = .{ .abort = true };
    defer pause.release();
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source_a, null);
    var first = testTake(&service);
    defer first.release();
    var input = test_input;
    input.revision += 1;
    _ = try testQueueFrom(&service, &gate, input, source_b, &first, &pause);
    try waitEntered(&pause);
    try expectTree(&first, before, .zig); // 다른 핸들의 ts_tree_edit 뒤, C가 아직 반환하지 않은 시점이다.
    pause.release();
    var stopped = testTake(&service);
    defer stopped.release();
    try std.testing.expectEqual(Outcome.unavailable, stopped.outcome());
    try std.testing.expectEqual(worker.UnavailableReason.native_parse, stopped.unavailableReason().?);
    try std.testing.expect(!stopped.accept(&gate));
    try std.testing.expect(stopped.provider() == null);
}

test "parse worker 문서와 문법 판 및 언어가 다른 기준은 cold로 처리한다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "pub fn first() void {}\n");
    defer source.deinit();
    var service = try Service.init(a, .{});
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    var first = testTake(&service);
    defer first.release();
    for (0..3) |kind| {
        var input = test_input;
        var language: syntax.Language = .zig;
        if (kind == 0) input.document.generation += 1;
        if (kind == 1) input.grammar.generation += 1;
        if (kind == 2) {
            language = .json;
            input.grammar.identity = @backingInt(language);
        }
        var snapshot = source.snapshot();
        _ = service.submitFrom(&gate, input, &snapshot, language, &first) catch |err| {
            snapshot.deinit();
            return err;
        };
        var result = testTake(&service);
        defer result.release();
        try std.testing.expectEqual(Mode.cold, result.mode());
        try std.testing.expect(result.basis() == null);
        try std.testing.expect(result.accept(&gate));
    }
}

test "parse worker 증분 대기 교체와 기준 반환 뒤에도 복사 핸들을 워커가 회수한다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "pub fn first() void {}\n");
    defer source.deinit();
    var next_source = try buffer.Buffer.init(a, "pub fn last() void { const x = 2; _ = x; }\n");
    defer next_source.deinit();
    var blocker = try largeTestBuffer(a);
    defer blocker.deinit();
    var audit: TestAudit = .{ .main_thread = std.Thread.getCurrentId() };
    var copies = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
    {
        var service = try Service.init(a, .{ .audit = &audit, .copy_allocator = copies.allocator() });
        defer service.deinit() catch unreachable;
        var pause: syntax.Cancellation.TestGate = .{};
        defer pause.release();
        var gate: request.Gate = .{};
        _ = try testQueue(&service, &gate, test_input, source, null);
        var first = testTake(&service);
        var first_open = true;
        defer if (first_open) first.release();
        var other_gate: request.Gate = .{};
        var other_input = test_input;
        other_input.document.owner += 1;
        _ = try testQueue(&service, &other_gate, other_input, blocker, &pause);
        try waitEntered(&pause);
        var input = test_input;
        input.revision += 1;
        _ = try testQueueFrom(&service, &gate, input, next_source, &first, null);
        input.revision += 1;
        const latest = try testQueueFrom(&service, &gate, input, next_source, &first, null);
        first.release();
        first_open = false;
        pause.release();
        var other = testTake(&service);
        defer other.release();
        try std.testing.expect(other.accept(&other_gate));
        var result = testTake(&service);
        defer result.release();
        try std.testing.expectEqual(latest, result.tag());
        try std.testing.expectEqual(Mode.incremental, result.mode());
        try std.testing.expect(result.accept(&gate));
        try expectTree(&result, "pub fn last() void { const x = 2; _ = x; }\n", .zig);
    }
    try std.testing.expectEqual(audit.created.load(.acquire), audit.destroyed.load(.acquire));
    try std.testing.expectEqual(@as(usize, 4), audit.reclaimed.load(.acquire));
    try std.testing.expect(!audit.wrong_thread.load(.acquire));
    try std.testing.expectEqual(copies.allocated_bytes, copies.freed_bytes);
}

test "parse worker 기준 원문 복사 OOM도 원본과 native 핸들을 보존해 회수한다" {
    const a = std.testing.allocator;
    var source = try buffer.Buffer.init(a, "pub fn first() void {}\n");
    defer source.deinit();
    var failing = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
    var service = try Service.init(a, .{ .copy_allocator = failing.allocator() });
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    var first = testTake(&service);
    defer first.release();
    failing.fail_index = failing.alloc_index + 1;
    var input = test_input;
    input.revision += 1;
    _ = try testQueueFrom(&service, &gate, input, source, &first, null);
    var failed = testTake(&service);
    defer failed.release();
    try std.testing.expectEqual(Outcome.out_of_memory, failed.outcome());
    try std.testing.expect(!failed.accept(&gate));
    try expectTree(&first, "pub fn first() void {}\n", .zig);
}

// OS main queue 대신 원자적 통지만 기록한다. 첫 검사는 mutex 해제 상태도 별도로 계측한다.
var notice_count: std.atomic.Value(usize) = .init(0);
var notice_main: std.Thread.Id = undefined;
var notice_wrong_thread: std.atomic.Value(bool) = .init(false);
var notice_locked: std.atomic.Value(bool) = .init(false);
var notice_inspect: ?*State = null;
fn recordNotice() void {
    if (std.Thread.getCurrentId() == notice_main) notice_wrong_thread.store(true, .release);
    if (notice_inspect) |state| {
        if (state.mutex.tryLock()) state.mutex.unlock(worker.testing.io(state)) else notice_locked.store(true, .release);
    }
    _ = notice_count.fetchAdd(1, .release);
}
fn resetNotices() void {
    notice_main = std.Thread.getCurrentId();
    notice_count.store(0, .release);
    notice_wrong_thread.store(false, .release);
    notice_locked.store(false, .release);
    notice_inspect = null;
}
fn waitNotices(count: usize) !void {
    const deadline = std.Io.Clock.awake.now(std.testing.io).nanoseconds + 5_000_000_000;
    while (notice_count.load(.acquire) < count) {
        try std.testing.expect(std.Io.Clock.awake.now(std.testing.io).nanoseconds < deadline);
        std.Thread.yield() catch {};
    }
}
fn waitCompleted(service: *Service, count: usize) void {
    const state = service.state;
    state.mutex.lockUncancelable(worker.testing.io(state));
    defer state.mutex.unlock(worker.testing.io(state));
    while (true) {
        var found: usize = 0;
        var next = state.completed.first;
        while (next) |job| : (next = job.next) found += 1;
        if (found >= count) return;
        state.changed.waitUncancelable(worker.testing.io(state), &state.mutex);
    }
}
test "parse worker 완료 통지는 mutex 밖 워커에서 게시 뒤 전달한다" {
    resetNotices();
    var source = try buffer.Buffer.init(std.testing.allocator, "const n = 1;");
    defer source.deinit();
    var service = try Service.init(std.testing.allocator, .{ .notify = recordNotice });
    defer {
        service.deinit() catch unreachable;
        notice_inspect = null;
    }
    notice_inspect = service.state;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    try waitNotices(1);
    try std.testing.expect(!notice_wrong_thread.load(.acquire));
    try std.testing.expect(!notice_locked.load(.acquire));
    try std.testing.expect(service.beginDrain());
    service.reap();
    var result = service.take() orelse return error.TestUnexpectedResult;
    defer result.release();
    try std.testing.expect(result.accept(&gate));
}
test "parse worker 여러 문서 완료는 drain 전 통지 하나로 합친다" {
    resetNotices();
    var source = try buffer.Buffer.init(std.testing.allocator, "const n = 1;");
    defer source.deinit();
    var service = try Service.init(std.testing.allocator, .{ .notify = recordNotice });
    defer service.deinit() catch unreachable;
    var gates = [_]request.Gate{ .{}, .{} };
    for (&gates, 0..) |*gate, i| {
        var input = test_input;
        input.document.slot += @intCast(i);
        _ = try testQueue(&service, gate, input, source, null);
    }
    // 세 번째 C 호출 장벽까지 진행하면 앞선 두 통지 callback도 실제 반환한 상태다.
    var blocker = try largeTestBuffer(std.testing.allocator);
    defer blocker.deinit();
    var pause: syntax.Cancellation.TestGate = .{};
    defer pause.release();
    var third_gate: request.Gate = .{};
    var third_input = test_input;
    third_input.document.slot += 2;
    _ = try testQueue(&service, &third_gate, third_input, blocker, &pause);
    try waitEntered(&pause);
    waitCompleted(&service, 2);
    try waitNotices(1);
    try std.testing.expectEqual(@as(usize, 1), notice_count.load(.acquire));
    try std.testing.expect(service.beginDrain());
    for (&gates) |*gate| {
        var result = service.take() orelse return error.TestUnexpectedResult;
        defer result.release();
        try std.testing.expect(result.accept(gate));
    }
    pause.release();
    var third = testTake(&service);
    defer third.release();
    try std.testing.expect(third.accept(&third_gate));
}
test "parse worker drain 재무장 뒤 새 완료는 별도 통지를 전달한다" {
    resetNotices();
    var source = try buffer.Buffer.init(std.testing.allocator, "const n = 1;");
    defer source.deinit();
    var service = try Service.init(std.testing.allocator, .{ .notify = recordNotice });
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    try waitNotices(1);
    try std.testing.expect(service.beginDrain());
    var first = service.take() orelse return error.TestUnexpectedResult;
    defer first.release();
    try std.testing.expect(first.accept(&gate));
    var input = test_input;
    input.document.slot += 1;
    var other: request.Gate = .{};
    _ = try testQueue(&service, &other, input, source, null);
    try waitNotices(2);
    try std.testing.expect(service.beginDrain());
    var second = service.take() orelse return error.TestUnexpectedResult;
    defer second.release();
    try std.testing.expect(second.accept(&other));
}
test "parse worker native 퇴역 반환도 tick 없이 메인 회수를 깨운다" {
    resetNotices();
    var source = try buffer.Buffer.init(std.testing.allocator, "const n = 1;");
    defer source.deinit();
    var audit: TestAudit = .{ .main_thread = std.Thread.getCurrentId() };
    var service = try Service.init(std.testing.allocator, .{ .notify = recordNotice, .audit = &audit });
    defer service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    try waitNotices(1);
    try std.testing.expect(service.beginDrain());
    var result = service.take() orelse return error.TestUnexpectedResult;
    result.release();
    try waitNotices(2);
    try std.testing.expect(service.beginDrain());
    service.reap();
    try std.testing.expectEqual(@as(usize, 1), audit.reclaimed.load(.acquire));
    try std.testing.expect(service.take() == null);
}
test "parse worker 종료는 미전달 완료를 회수하고 추가 통지를 만들지 않는다" {
    resetNotices();
    var source = try buffer.Buffer.init(std.testing.allocator, "const n = 1;");
    defer source.deinit();
    var audit: TestAudit = .{ .main_thread = std.Thread.getCurrentId() };
    var service = try Service.init(std.testing.allocator, .{ .notify = recordNotice, .audit = &audit });
    var open = true;
    defer if (open) service.deinit() catch unreachable;
    var gate: request.Gate = .{};
    _ = try testQueue(&service, &gate, test_input, source, null);
    try waitNotices(1);
    try std.testing.expect(service.beginDrain());
    try service.deinit();
    open = false;
    try std.testing.expectEqual(@as(usize, 1), notice_count.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), audit.reclaimed.load(.acquire));
    try std.testing.expectEqual(audit.created.load(.acquire), audit.destroyed.load(.acquire));
}

test "parse worker 요약 준비 중 취소는 완료를 수락하지 않고 native 자원을 회수한다" {
    const a = std.testing.allocator;
    var text = try buffer.Buffer.init(a, "pub fn first() void {}\n");
    defer text.deinit();
    var audit: TestAudit = .{ .main_thread = std.Thread.getCurrentId() };
    {
        var service = try Service.init(a, .{ .audit = &audit });
        defer service.deinit() catch unreachable;
        var gate: request.Gate = .{};
        var pause: syntax.Cancellation.TestGate = .{ .stage = .summary };
        defer pause.release();
        _ = try testQueue(&service, &gate, test_input, text, &pause);
        try waitEntered(&pause);
        service.cancelDocument(test_input.document);
        pause.release();
        var result = testTake(&service);
        defer result.release();
        try std.testing.expectEqual(Outcome.cancelled, result.outcome());
        try std.testing.expect(!result.accept(&gate));
    }
    try std.testing.expectEqual(@as(usize, 1), audit.cancelled_with_tree.load(.acquire));
    try std.testing.expectEqual(audit.created.load(.acquire), audit.destroyed.load(.acquire));
    try std.testing.expect(!audit.wrong_thread.load(.acquire));
}

test "parse worker 선택적 요약 OOM은 준비된 파싱과 기존 조회 재구축을 보존한다" {
    const a = std.testing.allocator;
    var before = try buffer.Buffer.init(a, "pub fn first() void {}\n");
    defer before.deinit();
    var after = try buffer.Buffer.init(a, "pub fn renamed() void {}\npub fn tail() void {}\n");
    defer after.deinit();
    var copies = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
    {
        var service = try Service.init(a, .{ .copy_allocator = copies.allocator() });
        defer service.deinit() catch unreachable;
        var gate: request.Gate = .{};
        _ = try testQueue(&service, &gate, test_input, before, null);
        var first = testTake(&service);
        defer first.release();
        try std.testing.expect(first.accept(&gate));
        try std.testing.expect(first.provider().?.sticky_summary.tree != null);
        var pause: syntax.Cancellation.TestGate = .{ .stage = .summary };
        defer pause.release();
        var input = test_input;
        input.revision += 1;
        _ = try testQueueFrom(&service, &gate, input, after, &first, &pause);
        try waitEntered(&pause);
        copies.fail_index = copies.alloc_index;
        pause.release();
        var next = testTake(&service);
        defer next.release();
        try std.testing.expectEqual(Outcome.ready, next.outcome());
        try std.testing.expect(next.accept(&gate));
        try std.testing.expectEqual(Mode.incremental, next.mode());
        var view = next.provider().?.copyReady(.zig) orelse return error.NoSnapshot;
        defer view.deinit();
        try std.testing.expect(view.sticky_summary.tree == null);
        var symbols: std.ArrayList(syntax.Provider.Symbol) = .empty;
        defer symbols.deinit(a);
        try std.testing.expect(try view.stickySymbols(a, &.{0}, &symbols));
        try std.testing.expectEqual(@as(usize, 2), view.sticky_summary.count);
        try std.testing.expect(view.sticky_work.rebuild_nodes > 0);
    }
    try std.testing.expectEqual(copies.allocated_bytes, copies.freed_bytes);
}
