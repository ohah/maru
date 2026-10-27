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
    defer owner.deinit();
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
    defer owner.deinit();
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
    defer owner.deinit();
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
    defer owner.deinit();
    _ = try owner.submit(view, grammar, .zig);
    try waitReady(&owner, identity);
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, owner.submit(view, grammar, .zig));
    try std.testing.expect(owner.ready(identity, grammar, .zig) == null);
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
    defer owner.deinit();
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
