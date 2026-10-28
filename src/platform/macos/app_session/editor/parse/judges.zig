//! 실제 registry 문서와 native 서비스를 결합하되 OS 전달은 같은 drain의 명시적 호출로 제어한다.
const std = @import("std");
const maru = @import("maru");
const syntax = @import("syntax");
const Runtime = @import("runtime.zig").Runtime;
const dispatch = @import("dispatch.zig");
const registry = maru.session.editor.document_registry;
const a = std.testing.allocator;
const grammar: dispatch.request.Grammar = .{ .identity = 1, .generation = 0 };
fn document(owner: *registry.Registry) !registry.Lease {
    // 한글·보조 평면·CRLF를 포함하는 원문 검증 fixture이며 UI 문구가 아니다.
    const file = try maru.session.editor.edit_doc.EditableFile.init(a, "// 한글 😀\r\nconst first = 1;\n", false);
    var state: maru.session.editor.document_state.State = .{ .opened = .{ .file = file, .saved_hash = 0 } };
    defer state.clear(a);
    return owner.create(&state, a);
}
fn now() i128 {
    return std.Io.Clock.awake.now(std.testing.io).nanoseconds;
}
fn waitReady(owner: *Runtime, identity: registry.DocumentIdentity) !void {
    const deadline = now() + 10_000_000_000;
    while (owner.ready(identity, grammar, .zig) == null) {
        try std.testing.expect(now() < deadline);
        owner.poll();
        std.Thread.yield() catch {};
    }
}
fn waitCompletion(owner: *Runtime) void {
    const state = owner.service.state;
    const io = state.threaded.io();
    state.mutex.lockUncancelable(io);
    defer state.mutex.unlock(io);
    while (state.completed.first == null) state.changed.waitUncancelable(io, &state.mutex);
}
fn edit(owner: *registry.Registry, lease: registry.Lease) !void {
    var items = [_]maru.session.editor.selection.Selection{maru.session.editor.selection.Selection.at(0)};
    var selections = maru.session.editor.selection.Selections.init(&items, 0);
    var inverse = try owner.get(lease).?.opened.?.file.apply(.{ .changes = &.{.{ .start = 0, .end = 0, .text = "// next\n" }} }, &selections);
    inverse.deinit();
}
test "parse runtime 마지막 뷰가 닫혀도 실제 Snapshot 반환까지 문서를 보존한다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const view = try document(&docs);
    var open = true;
    defer {
        if (open) _ = docs.release(view) catch unreachable;
    }
    const identity = docs.identity(view).?;
    var owner = try Runtime.init(a, .{});
    defer owner.deinit() catch unreachable;
    _ = try owner.submit(view, grammar, .zig);
    try waitReady(&owner, identity);
    const pin = owner.entries.items[0].lease;
    try std.testing.expect(!try docs.release(view));
    open = false;
    owner.sweep();
    try std.testing.expect(owner.ready(identity, grammar, .zig) == null);
    // ready를 반납해도 main reap 전에는 작업이 살아 있다. worker의 큐 상태를 추측하지 않는다.
    try std.testing.expect(docs.get(pin) != null);
    try std.testing.expect(owner.service.hasJobs(identity));
    const deadline = now() + 10_000_000_000;
    while (docs.get(pin) != null) {
        try std.testing.expect(now() < deadline);
        owner.poll();
        std.Thread.yield() catch {};
    }
    try std.testing.expect(!owner.service.hasJobs(identity));
    const reopened = try document(&docs);
    defer _ = docs.release(reopened) catch unreachable;
    const next = docs.identity(reopened).?;
    try std.testing.expectEqual(identity.slot, next.slot);
    try std.testing.expect(identity.generation != next.generation);
    try std.testing.expect(owner.ready(identity, grammar, .zig) == null);
}
test "parse runtime 새 요청 없이 본문이 바뀌어도 이전 완료를 거절한다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const view = try document(&docs);
    defer _ = docs.release(view) catch unreachable;
    const identity = docs.identity(view).?;
    var owner = try Runtime.init(a, .{});
    defer owner.deinit() catch unreachable;
    _ = try owner.submit(view, grammar, .zig);
    waitCompletion(&owner);
    try edit(&docs, view);
    owner.poll();
    try std.testing.expect(owner.ready(identity, grammar, .zig) == null);
    _ = try owner.submit(view, grammar, .zig);
    try waitReady(&owner, identity);
    var fresh = syntax.Provider.init(docs.get(view).?.opened.?.file.content, .zig, 0).?;
    defer fresh.deinit();
    try std.testing.expect(syntax.testing.equal(fresh.tree.?, owner.ready(identity, grammar, .zig).?.provider().?.tree.?) != null);
}
test "parse runtime 공유 뷰 하나의 닫기는 파싱을 취소하지 않고 증분 기준을 보존한다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const first = try document(&docs);
    var first_open = true;
    defer {
        if (first_open) _ = docs.release(first) catch unreachable;
    }
    const second = try docs.retain(first, .view);
    defer _ = docs.release(second) catch unreachable;
    const identity = docs.identity(first).?;
    var owner = try Runtime.init(a, .{});
    defer owner.deinit() catch unreachable;
    const prior = try owner.submit(first, grammar, .zig);
    try waitReady(&owner, identity);
    try std.testing.expect(!try docs.release(first));
    first_open = false;
    owner.sweep();
    try std.testing.expect(owner.ready(identity, grammar, .zig) != null);
    var other = grammar;
    other.generation += 1;
    try std.testing.expect(owner.ready(identity, other, .zig) == null);
    try std.testing.expect(owner.ready(identity, grammar, .json) == null);
    try edit(&docs, second);
    try std.testing.expect(owner.ready(identity, grammar, .zig) == null);
    _ = try owner.submit(second, grammar, .zig);
    try waitReady(&owner, identity);
    const result = owner.ready(identity, grammar, .zig).?;
    try std.testing.expectEqual(dispatch.worker.Mode.incremental, result.mode());
    try std.testing.expectEqual(prior, result.basis().?);
}
test "parse runtime Job 준비 OOM은 이전 수락을 숨기고 본문과 이력을 보존한다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const view = try document(&docs);
    defer _ = docs.release(view) catch unreachable;
    const identity = docs.identity(view).?;
    var failing = std.testing.FailingAllocator.init(a, .{});
    var owner = try Runtime.init(failing.allocator(), .{});
    defer owner.deinit() catch unreachable;
    _ = try owner.submit(view, grammar, .zig);
    try waitReady(&owner, identity);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.submit(view, grammar, .zig));
    try std.testing.expect(owner.ready(identity, grammar, .zig) == null);
    try std.testing.expect(owner.observe(identity, grammar, .zig) == .none);
    try std.testing.expectEqualStrings("// 한글 😀\r\nconst first = 1;\n", docs.get(view).?.opened.?.file.content);
    try std.testing.expectEqual(@as(u64, 0), docs.get(view).?.opened.?.file.revision);
    try std.testing.expectEqual(@as(usize, 0), docs.get(view).?.history.undo_len);
    failing.fail_index = std.math.maxInt(usize);
    _ = try owner.submit(view, grammar, .zig);
    try waitReady(&owner, identity);
    try std.testing.expectEqual(dispatch.worker.Mode.reused, owner.ready(identity, grammar, .zig).?.mode());
}
test "parse runtime 늦은 전달은 종료된 소유자 대신 새 소유자를 조회한다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    defer {
        dispatch.shutdown();
        _ = dispatch.wake.deliverForTest();
    }
    const first = try document(&docs);
    var first_open = true;
    defer {
        if (first_open) _ = docs.release(first) catch unreachable;
    }
    const old = docs.identity(first).?;
    const prior = try dispatch.submit(first, grammar, .zig);
    const deadline = now() + 10_000_000_000;
    while (!dispatch.wake.queuedForTest()) {
        try std.testing.expect(now() < deadline);
        std.Thread.yield() catch {};
    }
    dispatch.shutdown();
    const read = try docs.retain(first, .read);
    var read_open = true;
    defer {
        if (read_open) _ = docs.release(read) catch unreachable;
    }
    try std.testing.expect(!try docs.release(first));
    first_open = false;
    const restored = try docs.retain(read, .view);
    var restored_open = true;
    defer {
        if (restored_open) _ = docs.release(restored) catch unreachable;
    }
    try std.testing.expectEqualDeep(old, docs.identity(restored).?);
    const repeated = try dispatch.submit(restored, grammar, .zig);
    try std.testing.expect(repeated.serial > prior.serial);
    dispatch.shutdown();
    try std.testing.expect(!try docs.release(read));
    read_open = false;
    try std.testing.expect(try docs.release(restored));
    restored_open = false;
    const second = try document(&docs);
    defer _ = docs.release(second) catch unreachable;
    const identity = docs.identity(second).?;
    _ = try dispatch.submit(second, grammar, .zig);
    while (dispatch.ready(identity, grammar, .zig) == null) {
        try std.testing.expect(now() < deadline);
        _ = dispatch.wake.deliverForTest();
        std.Thread.yield() catch {};
    }
    try std.testing.expect(dispatch.ready(old, grammar, .zig) == null);
    try std.testing.expectEqual(std.Thread.getCurrentId(), dispatch.lastPollThread().?);
}
test "parse runtime 최초 문서 등록 OOM은 request 참조를 남기지 않는다" {
    var registry_fail = std.testing.FailingAllocator.init(a, .{});
    var docs: registry.Registry = .{ .allocator = registry_fail.allocator() };
    defer docs.deinit() catch unreachable;
    const view = try document(&docs);
    var open = true;
    defer {
        if (open) _ = docs.release(view) catch unreachable;
    }
    var failing = std.testing.FailingAllocator.init(a, .{});
    var owner = try Runtime.init(failing.allocator(), .{});
    defer owner.deinit() catch unreachable;
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.submit(view, grammar, .zig));
    try std.testing.expectEqual(@as(usize, 0), owner.entries.items.len);
    failing.fail_index = std.math.maxInt(usize);
    // Keeper의 ref 배열 여유를 먼저 준비해 다음 실패가 문서 Gate 할당임을 확정한다.
    const read = try docs.retain(view, .read);
    _ = try docs.release(read);
    registry_fail.fail_index = registry_fail.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.submit(view, grammar, .zig));
    try std.testing.expectEqual(@as(usize, 0), owner.entries.items.len);
    try std.testing.expect(try docs.release(view));
    open = false;
}

// 두 원문 복사를 따로 멈춰 이전 실행의 취소 완료와 새 요청 대기를 결정적으로 분리한다.
const CopyBarrier = struct {
    calls: usize = 0,
    first_entered: std.atomic.Value(bool) = .init(false),
    first_released: std.atomic.Value(bool) = .init(false),
    entered: std.atomic.Value(bool) = .init(false),
    released: std.atomic.Value(bool) = .init(false),
    fn allocator(self: *CopyBarrier) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }
    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret: usize) ?[*]u8 {
        const self: *CopyBarrier = @ptrCast(@alignCast(context));
        self.calls += 1;
        if (self.calls == 1) {
            self.first_entered.store(true, .release);
            while (!self.first_released.load(.acquire)) std.Thread.yield() catch {};
            return null;
        }
        if (self.calls == 2) {
            self.entered.store(true, .release);
            while (!self.released.load(.acquire)) std.Thread.yield() catch {};
        }
        return std.heap.page_allocator.rawAlloc(len, alignment, ret);
    }
    fn free(_: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret: usize) void {
        std.heap.page_allocator.rawFree(memory, alignment, ret);
    }
};
// 실패 자료는 완료 큐를 실제로 지나며, 표시·재시도 UX 없이 현재 시도의 사실만 검사한다.
test "parse runtime 실패 완료와 게시 대기를 구분하고 같은 입력 재시도는 옛 실패를 지운다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const view = try document(&docs);
    defer _ = docs.release(view) catch unreachable;
    const identity = docs.identity(view).?;
    var copies = std.testing.FailingAllocator.init(std.heap.page_allocator, .{ .fail_index = 0 });
    var owner = try Runtime.init(a, .{ .copy_allocator = copies.allocator() });
    defer owner.deinit() catch unreachable;
    try std.testing.expect(owner.observe(identity, grammar, .zig) == .none);
    const first = try owner.submit(view, grammar, .zig);
    try std.testing.expectEqual(first, owner.observe(identity, grammar, .zig).pending);
    waitCompletion(&owner);
    owner.poll();
    try std.testing.expect(owner.observe(identity, grammar, .zig) == .finished);
    const failed = owner.observe(identity, grammar, .zig).finished;
    try std.testing.expectEqual(first, failed.tag);
    try std.testing.expectEqual(dispatch.worker.Outcome.out_of_memory, failed.outcome);
    try std.testing.expect(owner.ready(identity, grammar, .zig) == null);
    var other = grammar;
    other.generation += 1;
    try std.testing.expect(owner.observe(identity, other, .zig) == .none);
    try std.testing.expect(owner.observe(identity, grammar, .json) == .none);
    // worker가 실패한 copy 호출에서 이미 반환했다. 다음 시도 전까지만 allocator 설정을 고친다.
    copies.fail_index = std.math.maxInt(usize);
    const next = try owner.submit(view, grammar, .zig);
    try std.testing.expect(next.serial > first.serial);
    try std.testing.expect(owner.observe(identity, grammar, .zig) == .pending);
    try std.testing.expectEqual(next, owner.observe(identity, grammar, .zig).pending);
    try waitReady(&owner, identity);
    try std.testing.expectEqual(dispatch.worker.Outcome.ready, owner.observe(identity, grammar, .zig).finished.outcome);
    try edit(&docs, view);
    try std.testing.expect(owner.observe(identity, grammar, .zig) == .none);
}
test "parse runtime 늦은 취소 완료는 같은 본문의 새 언어 설정 요청을 덮어쓰지 않는다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const view = try document(&docs);
    defer _ = docs.release(view) catch unreachable;
    const identity = docs.identity(view).?;
    var copies: CopyBarrier = .{};
    var owner = try Runtime.init(a, .{ .copy_allocator = copies.allocator() });
    defer owner.deinit() catch unreachable;
    defer copies.released.store(true, .release);
    defer copies.first_released.store(true, .release);
    _ = try owner.submit(view, grammar, .zig);
    const deadline = now() + 10_000_000_000;
    while (!copies.first_entered.load(.acquire)) {
        try std.testing.expect(now() < deadline);
        std.Thread.yield() catch {};
    }
    var changed = grammar;
    changed.generation += 1;
    const latest = try owner.submit(view, changed, .zig);
    copies.first_released.store(true, .release);
    while (!copies.entered.load(.acquire)) {
        try std.testing.expect(now() < deadline);
        std.Thread.yield() catch {};
    }
    owner.poll();
    const observed = owner.observe(identity, changed, .zig);
    try std.testing.expect(observed == .pending);
    try std.testing.expectEqual(latest, observed.pending);
    copies.released.store(true, .release);
    while (owner.ready(identity, changed, .zig) == null) {
        try std.testing.expect(now() < deadline);
        owner.poll();
        std.Thread.yield() catch {};
    }
    try std.testing.expect(owner.observe(identity, grammar, .zig) == .none);
}

// 잘못 수락하는 결함에서도 반환한 참조를 먼저 정산해 검사 실패의 누수와 섞이지 않게 한다.
fn expectNoAcquire(owner: *Runtime, identity: registry.DocumentIdentity, g: dispatch.request.Grammar, language: syntax.Language) !void {
    var result = try owner.acquire(identity, g, language);
    const rejected = result == null;
    if (result) |*held| held.release();
    try std.testing.expect(rejected);
}
test "parse runtime 보유한 이전 결과는 새 결과 설치와 종료 거절 뒤에도 살아 있다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const view = try document(&docs);
    defer _ = docs.release(view) catch unreachable;
    const identity = docs.identity(view).?;
    var owner = try Runtime.init(a, .{});
    defer owner.deinit() catch unreachable;
    try expectNoAcquire(&owner, identity, grammar, .zig);
    const first = try owner.submit(view, grammar, .zig);
    try waitReady(&owner, identity);
    var held = (try owner.acquire(identity, grammar, .zig)).?;
    var live = true;
    defer if (live) held.release();
    try std.testing.expectError(error.ResultsHeld, owner.canDeinit());
    try std.testing.expectError(error.ResultsHeld, owner.deinit());
    try std.testing.expectEqual(first, owner.ready(identity, grammar, .zig).?.tag());
    const old_tree = held.provider().?.tree.?;
    var cold = syntax.Provider.init(docs.get(view).?.opened.?.file.content, .zig, 0).?;
    defer cold.deinit();
    try edit(&docs, view);
    try expectNoAcquire(&owner, identity, grammar, .zig);
    const latest = try owner.submit(view, grammar, .zig);
    try waitReady(&owner, identity);
    try std.testing.expectEqual(latest, owner.ready(identity, grammar, .zig).?.tag());
    try std.testing.expectEqual(first, held.tag());
    try std.testing.expect(syntax.testing.equal(cold.tree.?, old_tree) != null);
    var wrong = grammar;
    wrong.generation += 1;
    try expectNoAcquire(&owner, identity, wrong, .zig);
    try expectNoAcquire(&owner, identity, grammar, .json);
    held.release();
    live = false;
}
test "parse runtime 마지막 뷰가 닫혀도 소비자 반환 전에는 문서와 종료 소유자를 지킨다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const view = try document(&docs);
    var open = true;
    defer {
        if (open) _ = docs.release(view) catch unreachable;
    }
    const identity = docs.identity(view).?;
    var owner = try Runtime.init(a, .{});
    defer owner.deinit() catch unreachable;
    _ = try owner.submit(view, grammar, .zig);
    try waitReady(&owner, identity);
    var held = (try owner.acquire(identity, grammar, .zig)).?;
    var live = true;
    defer if (live) held.release();
    const keeper = owner.entries.items[0].lease;
    _ = try docs.release(view);
    open = false;
    owner.sweep();
    try std.testing.expectError(error.ResultsHeld, owner.canDeinit());
    try std.testing.expectError(error.ResultsHeld, owner.deinit());
    try std.testing.expect(docs.get(keeper) != null);
    try expectNoAcquire(&owner, identity, grammar, .zig);
    try std.testing.expect(held.provider() != null);
    held.release();
    live = false;
    const deadline = now() + 10_000_000_000;
    while (docs.get(keeper) != null) {
        try std.testing.expect(now() < deadline);
        owner.poll();
        std.Thread.yield() catch {};
    }
    try owner.canDeinit();
}

test "parse runtime 공유 뷰의 같은 입력은 대기와 완료 모두 할당 없이 같은 요청을 재사용한다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const first = try document(&docs);
    defer _ = docs.release(first) catch unreachable;
    const second = try docs.retain(first, .view);
    defer _ = docs.release(second) catch unreachable;
    const other = try document(&docs);
    defer _ = docs.release(other) catch unreachable;
    var allocations = std.testing.FailingAllocator.init(a, .{});
    var owner = try Runtime.init(allocations.allocator(), .{});
    defer owner.deinit() catch unreachable;
    const initial = try owner.ensure(first, grammar, .zig);
    try std.testing.expect(initial.published);
    allocations.fail_index = allocations.alloc_index;
    const pending = owner.ensure(second, grammar, .zig) catch return error.TestUnexpectedResult;
    try std.testing.expect(!pending.published);
    try std.testing.expectEqual(initial.tag, pending.tag);
    try waitReady(&owner, docs.identity(first).?);
    const complete = owner.ensure(second, grammar, .zig) catch return error.TestUnexpectedResult;
    try std.testing.expect(!complete.published);
    try std.testing.expectEqual(initial.tag, complete.tag);
    try std.testing.expect(!allocations.has_induced_failure);
    allocations.fail_index = std.math.maxInt(usize);
    const independent = try owner.ensure(other, grammar, .zig);
    try std.testing.expect(independent.published);
    try std.testing.expect(!std.meta.eql(independent.tag.input.document, initial.tag.input.document));
    var changed = grammar;
    changed.generation += 1;
    const settings = try owner.ensure(second, changed, .zig);
    try std.testing.expect(settings.published and settings.tag.serial > initial.tag.serial);
    const language = try owner.ensure(first, changed, .json);
    try std.testing.expect(language.published and language.tag.serial > settings.tag.serial);
    try edit(&docs, first);
    const revision = try owner.ensure(second, changed, .json);
    try std.testing.expect(revision.published and revision.tag.input.revision > language.tag.input.revision);
}
test "parse runtime 공유 실패는 재게시하지 않고 마지막 뷰 닫기 뒤 같은 문서를 새로 요청한다" {
    var docs: registry.Registry = .{ .allocator = a };
    defer docs.deinit() catch unreachable;
    const source = try document(&docs);
    var open = true;
    defer {
        if (open) _ = docs.release(source) catch unreachable;
    }
    const reader = try docs.retain(source, .read);
    defer _ = docs.release(reader) catch unreachable;
    var copies = std.testing.FailingAllocator.init(std.heap.page_allocator, .{});
    var owner = try Runtime.init(a, .{ .copy_allocator = copies.allocator() });
    defer owner.deinit() catch unreachable;
    _ = try owner.ensure(source, grammar, .zig);
    try waitReady(&owner, docs.identity(source).?);
    var old = (try owner.acquire(docs.identity(source).?, grammar, .zig)).?;
    var old_live = true;
    defer if (old_live) old.release();
    copies.fail_index = copies.alloc_index;
    const retry = try owner.submit(source, grammar, .zig);
    waitCompletion(&owner);
    owner.poll();
    try std.testing.expectEqual(dispatch.worker.Outcome.out_of_memory, owner.observe(docs.identity(source).?, grammar, .zig).finished.outcome);
    const failed = try owner.ensure(source, grammar, .zig);
    try std.testing.expect(!failed.published);
    try std.testing.expectEqual(retry, failed.tag);
    copies.fail_index = std.math.maxInt(usize);
    _ = try docs.release(source);
    open = false;
    owner.sweep();
    try std.testing.expectError(error.NoViews, owner.ensure(reader, grammar, .zig));
    try std.testing.expectError(error.StaleReference, owner.ensure(source, grammar, .zig));
    const restored = try docs.retain(reader, .view);
    defer _ = docs.release(restored) catch unreachable;
    const reopened = try owner.ensure(restored, grammar, .zig);
    try std.testing.expect(reopened.published and reopened.tag.serial > retry.serial);
    try waitReady(&owner, docs.identity(restored).?);
    old.release();
    old_live = false;
}
