//! 스냅샷 할당 실패와 요청 재사용을 실제 API로 검사한다. 제품 UI 검증을 대신하지 않는다.
const std = @import("std");
const editor = @import("maru").session.editor;
const api = @import("search_backend");
const search = editor.search;
const Control = struct { cancelled: std.atomic.Value(bool) = .init(false) };
const identity: search.request.Identity = .{ .request = 1, .root = 1, .models = 1 };
const document: search.request.DocumentIdentity = .{ .owner = 1, .slot = 1, .generation = 1 };
const budget: api.Budget = .{ .timing = .{ .execution_ms = 1000, .reap_ms = 1000 }, .snapshot_bytes = 1024, .preview_bytes = 3 };
fn captureFailures(a: std.mem.Allocator, file: *const editor.edit_doc.EditableFile) !void {
    var state: search.request.State = .{ .identity = identity, .limits = .{ .result_bytes = 1024, .event_bytes = 1024 } };
    defer state.deinit(a);
    var models: std.ArrayList(api.model.Captured) = .empty;
    defer {
        for (models.items) |*item| item.deinit(a);
        models.deinit(a);
    }
    var retained: usize = 0;
    _ = try api.model.captureUnique(a, &state, &models, "a.txt", document, 7, file, &retained, 1024);
    try std.testing.expectEqual(@as(usize, 1), models.items.len);
    try std.testing.expectEqual(file.buf.byteLen(), retained);
    try std.testing.expect(!try api.model.captureUnique(a, &state, &models, "a.txt", document, 7, file, &retained, 1024));
}
const Sink = struct {
    calls: usize = 0,
    fail: bool = false,
    fn accept(self: *@This(), source: search.request.Source, match: search.event.Match) !bool {
        try std.testing.expectEqual(@as(u64, 7), source.model.composition);
        try std.testing.expect(std.unicode.utf8ValidateSlice(match.text));
        try std.testing.expectEqual(@as(usize, 0), match.text.len);
        try std.testing.expect(match.text_truncated);
        self.calls += 1;
        if (self.fail) return error.CallbackFailure;
        return false;
    }
};
fn runFailures(a: std.mem.Allocator, captured: *const api.model.Captured, use_regex: bool) !void {
    var control: Control = .{};
    var sink: Sink = .{};
    try api.model.run(a, captured, "\xf0\x9f\x98\x80", .{ .match_case = true, .regex = use_regex }, &control, 1024, 3, &sink, Sink.accept);
    try std.testing.expectEqual(@as(usize, 1), sink.calls);
}
fn overlayFailures(a: std.mem.Allocator, file: *const editor.edit_doc.EditableFile, use_regex: bool) !void {
    var state: search.request.State = .{ .identity = identity, .limits = .{ .result_bytes = 1024, .event_bytes = 1024 } };
    defer state.deinit(a);
    var captured = try api.model.capture(a, &state, "a.txt", document, 7, file);
    defer captured.deinit(a);
    try api.model.addOverlay(a, &captured, 4, 7, "\xf0\x9f\x98\x80");
    var control: Control = .{};
    var sink: Sink = .{};
    try api.model.run(a, &captured, "\xf0\x9f\x98\x80", .{ .match_case = true, .regex = use_regex }, &control, 1024, 3, &sink, Sink.accept);
    try std.testing.expectEqual(@as(usize, 2), sink.calls);
}
fn invalidOverlays(a: std.mem.Allocator, file: *const editor.edit_doc.EditableFile) !void {
    for (0..2) |invalid| {
        var state: search.request.State = .{ .identity = identity, .limits = .{ .result_bytes = 1024, .event_bytes = 1024 } };
        defer state.deinit(a);
        var captured = try api.model.capture(a, &state, "a.txt", document, 7, file);
        defer captured.deinit(a);
        try api.model.addOverlay(a, &captured, 4, 7, if (invalid == 0) "\x80" else "foo");
        if (invalid == 1) try api.model.addOverlay(a, &captured, 5, 6, "bar");
        var control: Control = .{};
        var sink: Sink = .{};
        try std.testing.expectError(error.InvalidOverlay, api.model.run(a, &captured, "foo", .{}, &control, 1024, 3, &sink, Sink.accept));
        try std.testing.expectEqual(@as(usize, 0), sink.calls);
    }
    for ([_][2]usize{ .{ 1, 1 }, .{ 4, 8 }, .{ 7, 4 } }) |range| {
        var state: search.request.State = .{ .identity = identity, .limits = .{ .result_bytes = 1024, .event_bytes = 1024 } };
        defer state.deinit(a);
        var captured = try api.model.capture(a, &state, "a.txt", document, 7, file);
        defer captured.deinit(a);
        try api.model.addOverlay(a, &captured, range[0], range[1], "foo");
        var control: Control = .{};
        var sink: Sink = .{};
        try std.testing.expectError(error.InvalidOverlay, api.model.run(a, &captured, "foo", .{}, &control, 1024, 3, &sink, Sink.accept));
        try std.testing.expectEqual(@as(usize, 0), sink.calls);
    }
}
fn pathPrepareFailures(a: std.mem.Allocator, file: *const editor.edit_doc.EditableFile, root: []const u8) !void {
    var state: search.request.State = .{ .identity = identity, .limits = .{ .result_bytes = 1024, .event_bytes = 1024 } };
    defer state.deinit(a);
    var models: std.ArrayList(api.model.Captured) = .empty;
    defer {
        for (models.items) |*item| item.deinit(a);
        models.deinit(a);
    }
    var retained: usize = 0;
    _ = try api.model.captureUnique(a, &state, &models, "A.TXT", document, 7, file, &retained, 1024);
    try state.occupy(a, "missing.txt");
    var control: Control = .{};
    try api.path.prepare(a, root, &state, &models, &control);
    try std.testing.expectEqual(@as(usize, 1), models.items.len);
    try std.testing.expect(state.occupied.contains(models.items[0].path));
    try std.testing.expect(state.occupied.contains("missing.txt"));
    try std.testing.expectEqual(@as(usize, 7), models.items[0].snapshot.byteLen());
}
fn wait(backend: *api.Backend, io: std.Io) !void {
    const started = std.Io.Timestamp.now(io, .awake);
    while (!backend.done()) {
        if (started.untilNow(io, .awake).toMilliseconds() > 5000) return error.AuditDeadline;
        try std.Io.sleep(io, .fromMilliseconds(1), .awake);
    }
}
pub fn run(a: std.mem.Allocator, io: std.Io, helper: []const u8, root: []const u8) !void {
    var file = try editor.edit_doc.EditableFile.init(a, "\xf0\x9f\x98\x80foo", false);
    defer file.deinit();
    try std.testing.checkAllAllocationFailures(a, captureFailures, .{&file});
    try std.testing.checkAllAllocationFailures(a, pathPrepareFailures, .{ &file, root });
    try std.testing.checkAllAllocationFailures(a, overlayFailures, .{ &file, false });
    try std.testing.checkAllAllocationFailures(a, overlayFailures, .{ &file, true });
    try invalidOverlays(a, &file);
    var state: search.request.State = .{ .identity = identity, .limits = .{ .result_bytes = 1024, .event_bytes = 1024 } };
    defer state.deinit(a);
    var captured = try api.model.capture(a, &state, "a.txt", document, 7, &file);
    defer captured.deinit(a);
    try std.testing.checkAllAllocationFailures(a, runFailures, .{ &captured, false });
    try std.testing.checkAllAllocationFailures(a, runFailures, .{ &captured, true });
    var control: Control = .{};
    var sink: Sink = .{ .fail = true };
    try std.testing.expectError(error.CallbackFailure, api.model.run(a, &captured, "\xf0\x9f\x98\x80", .{}, &control, 1024, 3, &sink, Sink.accept));
    control.cancelled.store(true, .release);
    try std.testing.expectError(error.Cancelled, api.model.run(a, &captured, "foo", .{}, &control, 1024, 3, &sink, Sink.accept));
    try std.testing.expectError(error.SnapshotBudget, api.model.run(a, &captured, "foo", .{}, &control, 6, 3, &sink, Sink.accept));
    {
        var limited: search.request.State = .{ .identity = identity, .limits = state.limits };
        defer limited.deinit(a);
        var selected: std.ArrayList(api.model.Captured) = .empty;
        defer {
            for (selected.items) |*item| item.deinit(a);
            selected.deinit(a);
        }
        var retained: usize = 0;
        try std.testing.expect(!try api.model.captureUnique(a, &limited, &selected, "excluded.txt", document, 7, &file, &retained, 6));
        try std.testing.expect(limited.occupied.contains("excluded.txt"));
        try std.testing.expectEqual(@as(usize, 1), limited.excluded);
        try std.testing.expectEqual(@as(usize, 0), retained);
        try std.testing.expect(try api.model.captureUnique(a, &limited, &selected, "a.txt", document, 7, &file, &retained, 7));
        try std.testing.expectEqual(@as(usize, 7), retained);
        try std.testing.expect(!try api.model.captureUnique(a, &limited, &selected, "b.txt", .{ .owner = 2, .slot = 1, .generation = 1 }, 7, &file, &retained, 7));
        try std.testing.expectEqual(@as(usize, 1), selected.items.len);
        try std.testing.expectEqual(@as(usize, 2), limited.excluded);
    }
    var backend: api.Backend = .{ .a = a, .io = io };
    defer backend.deinit();
    var models: std.ArrayList(api.model.Captured) = .empty;
    defer {
        for (models.items) |*item| item.deinit(a);
        models.deinit(a);
    }
    var retained_before_start: usize = 0;
    _ = try api.model.captureUnique(a, &state, &models, "a.txt", document, 7, &file, &retained_before_start, 1024);
    try std.testing.expectError(error.UntrustedExecutable, backend.start("relative-helper", root, "foo", .{}, &state, &models, budget));
    try std.testing.expectError(error.EmptyQuery, backend.start(helper, root, "", .{}, &state, &models, budget));
    try std.testing.expectEqual(@as(usize, 1), models.items.len);
    try std.testing.expect(state.occupied.contains("a.txt"));
    try std.testing.expectEqual(identity, state.identity);
    try std.testing.expect(backend.active == null);
    for (0..8) |n| {
        state.identity.request = n + 1;
        try backend.start(helper, root, if (n % 4 == 1) "foo" else "absent", .{}, &state, &models, budget);
        try std.testing.expectError(error.Busy, backend.start(helper, root, "absent", .{}, &state, &models, budget));
        try std.testing.expectError(error.Busy, backend.startBundled(root, "absent", .{}, &state, &models, budget));
        if (n % 4 == 0) backend.cancel();
        if (n % 4 >= 2) {
            var stale = state.identity;
            if (n % 4 == 2) stale.request += 1 else stale.models += 1;
            try std.testing.expect(backend.take(stale) == null);
        }
        try wait(&backend, io);
        const completion = backend.completion().?;
        try std.testing.expectEqual(n + 1, completion.identity.request);
        try std.testing.expectEqual(if (n % 4 != 1) search.request.Status.cancelled else search.request.Status.complete, completion.status);
        if (backend.stats().?.child_pid != null) try std.testing.expect(backend.stats().?.reaped);
        if (backend.take(completion.identity)) |value| {
            var batch = value;
            defer batch.deinit(a);
            try std.testing.expectEqual(@as(usize, 3), batch.matches);
            var total: usize = 0;
            for (batch.rows.items) |row| total += row.match.ranges.len;
            try std.testing.expectEqual(@as(usize, 3), total);
            if (backend.take(completion.identity)) |second| {
                var empty = second;
                defer empty.deinit(a);
                try std.testing.expectEqual(@as(usize, 0), empty.rows.items.len);
                try std.testing.expectEqual(@as(usize, 3), empty.matches);
            } else return error.MissingBatch;
        }
        try std.testing.expect(backend.reset());
    }
    backend.deinit();
    try std.testing.expectError(error.Closed, backend.startBundled(root, "absent", .{}, &state, &models, budget));
    try std.testing.expectError(error.Closed, backend.start(helper, root, "absent", .{}, &state, &models, budget));
}
