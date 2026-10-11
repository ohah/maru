//! 완료 검색의 행과 시작 Ticket을 동결한다. 닫힌 파일은 같은 rg 결과와 전문 hash를 재검증한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../../app_session.zig");
const search = maru.session.editor.search;
const actor = @import("../batch.zig");
const worker = @import("mixed_worker.zig");
const backend = @import("../backend.zig");
const dock = @import("../dock.zig");
const load = @import("load.zig");
const panels = @import("../../../file_panel.zig");
const editor = @import("../../mod.zig");
const Expected = struct {
    disk: usize,
    match: search.event.Match,
    found: []bool,
    fn deinit(self: *Expected, a: std.mem.Allocator) void {
        self.match.deinit(a);
        a.free(self.found);
    }
};
fn positionLess(a: search.event.Position, b: search.event.Position) bool {
    return a.line < b.line or (a.line == b.line and a.byte < b.byte);
}
fn expectedLess(_: void, a: Expected, b: Expected) bool {
    return a.disk < b.disk or (a.disk == b.disk and positionLess(a.match.text_start, b.match.text_start));
}
fn rangeLess(_: void, a: search.event.Range, b: search.event.Range) bool {
    return positionLess(a.start, b.start) or (std.meta.eql(a.start, b.start) and positionLess(a.end, b.end));
}
fn markRanges(expected: []const search.event.Range, found: []bool, actual: []search.event.Range) void {
    // 한 줄의 빈 매치도 수천 개가 될 수 있다. 원래 범위를 하나씩 전체 재순회하지 않는다.
    std.mem.sort(search.event.Range, actual, {}, rangeLess);
    for (expected, found) |range, *flag| {
        var lo: usize = 0;
        var hi = actual.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (rangeLess({}, actual[mid], range)) lo = mid + 1 else hi = mid;
        }
        if (lo < actual.len and std.meta.eql(range, actual[lo])) flag.* = true;
    }
}
pub const State = struct {
    a: std.mem.Allocator,
    io: std.Io,
    spec: ?search.batch.Specification = null,
    ticket: actor.Ticket,
    models: []worker.Model = &.{},
    captured: usize = 0,
    disks: std.ArrayList(worker.Disk) = .empty,
    occupied: std.ArrayList(maru.session.file_tree.Identity) = .empty,
    expected: std.ArrayList(Expected) = .empty,
    verifier: ?backend.Backend = null,
    cursor: usize = 0,
    query: []const u8 = "",
    options: search.query.Options,
    helper: ?[]const u8 = null,
    pub fn cancel(self: *State) void {
        if (self.verifier) |*job| job.cancel();
    }
    pub fn deinit(self: *State) void {
        self.cancel();
        self.closeVerifier();
        if (self.spec) |*spec| spec.deinit(self.a);
        for (self.models[0..self.captured]) |*model| model.snapshot.deinit();
        self.a.free(self.models);
        for (self.disks.items) |item| {
            self.a.free(item.target.root);
            self.a.free(item.target.path);
        }
        self.disks.deinit(self.a);
        self.occupied.deinit(self.a);
        for (self.expected.items) |*item| item.deinit(self.a);
        self.expected.deinit(self.a);
        self.a.free(self.query);
        if (self.helper) |helper| self.a.free(helper);
    }
    fn closeVerifier(self: *State) void {
        if (self.verifier) |*job| {
            // 테스트에서는 숨겨진 마지막 worker 참조도 결산 전에 놓는다. 제품은 기다리지 않는다.
            if (@import("builtin").is_test) if (job.active) |active| @import("../../../../detached_worker_wait.zig").quietState(active, self.io);
            job.deinit();
            self.verifier = null;
        }
    }
    /// 성공 때만 spec을 인계한다. 수집 실패는 이전 검색 화면과 명세를 그대로 남긴다.
    pub fn init(session: *host.AppSession, spec: *search.batch.Specification, ticket: actor.Ticket) !State {
        const query = session.editor_project_search_query orelse return error.StaleRequest;
        var self: State = .{ .a = session.allocator, .io = session.io, .ticket = ticket, .options = query.options };
        errdefer self.deinit();
        self.query = try self.a.dupe(u8, query.text);
        if (@import("builtin").is_test) if (query.helper_for_test) |helper| {
            self.helper = try self.a.dupe(u8, helper);
        };
        var count: usize = 0;
        for (spec.targets.items) |target| if (target.source == .model) {
            count += 1;
        };
        self.models = try self.a.alloc(worker.Model, count);
        var bytes: usize = 0;
        for (spec.targets.items, 0..) |target, index| {
            if (target.source == .model) {
                const snapshot = try actor.captureSnapshot(session, target);
                self.models[self.captured] = .{ .index = index, .source = target.source, .snapshot = snapshot };
                self.captured += 1;
                if (snapshot.byteLen() > editor.read_limit_bytes or snapshot.byteLen() > dock.budget.snapshot_bytes -| bytes) return error.TooLarge;
                bytes += snapshot.byteLen();
                continue;
            }
            const root = session.file_tree.rootAt(target.root_index) orelse return error.StaleRequest;
            const cap = session.file_tree.rootCapabilityForPath(root) orelse return error.StaleRequest;
            const path = @import("../owner.zig").relativeToRoot(root, target.absolute) orelse return error.StaleRequest;
            _ = try search.request.relativePath(path);
            var owns_paths = true;
            const owned_root = try self.a.dupe(u8, root);
            errdefer if (owns_paths) self.a.free(owned_root);
            const owned_path = try self.a.dupe(u8, path);
            errdefer if (owns_paths) self.a.free(owned_path);
            const disk_index = self.disks.items.len;
            try self.disks.append(self.a, .{ .index = index, .target = .{ .root = owned_root, .path = owned_path, .root_identity = cap.identity, .hash = undefined } });
            owns_paths = false;
            // append 후에는 State가 경로를 소유한다. 이후 expected 복제는 별도 함수에서 실패를 처리한다.
            try self.captureExpected(session, target, path, disk_index);
        }
        for (session.editor_documents.slots.items) |slot| {
            const doc = slot.document orelse continue;
            if (doc.state.remote != null) continue;
            if (doc.state.path) |path| if (try load.namespaceIdentity(self.a, path)) |id| try self.occupied.append(self.a, id);
        }
        var entries = panels.fileEntries(session);
        while (entries.next()) |entry| {
            if (entry.remote_origin_dest.len != 0) continue;
            if (try load.namespaceIdentity(self.a, entry.path)) |id| try self.occupied.append(self.a, id);
        }
        std.mem.sort(Expected, self.expected.items, {}, expectedLess);
        try ticket.validate(session, spec);
        self.spec = spec.*;
        spec.* = undefined;
        return self;
    }
    fn captureExpected(self: *State, session: *host.AppSession, target: search.batch.Target, path: []const u8, disk_index: usize) !void {
        var found = false;
        for (session.editor_search.result.model.groups.items) |group| {
            if (group.source != .disk or group.root_index != target.root_index or !std.mem.eql(u8, try search.request.relativePath(group.path), path)) continue;
            for (group.rows.items) |row_index| {
                const row = session.editor_search.result.model.rows.items[row_index];
                if (row.source != .disk or row.root_index != target.root_index) return error.StaleSources;
                var match = row.match;
                match.path = try self.a.dupe(u8, match.path);
                errdefer self.a.free(match.path);
                match.text = try self.a.dupe(u8, match.text);
                errdefer self.a.free(match.text);
                match.ranges = try self.a.dupe(search.event.Range, match.ranges);
                errdefer self.a.free(match.ranges);
                const flags = try self.a.alloc(bool, match.ranges.len);
                errdefer self.a.free(flags);
                @memset(flags, false);
                try self.expected.append(self.a, .{ .disk = disk_index, .match = match, .found = flags });
                found = true;
            }
        }
        if (!found) return error.StaleSources;
    }
    fn begin(self: *State, session: *host.AppSession) !void {
        const target = self.disks.items[self.cursor].target;
        var request: search.request.State = .{ .identity = self.ticket.identity, .limits = dock.limits };
        defer request.deinit(self.a);
        var models: std.ArrayList(backend.model.Captured) = .empty;
        defer models.deinit(self.a);
        var budget = dock.budget;
        budget.navigation_bytes = editor.read_limit_bytes;
        var next: backend.Backend = .{ .a = self.a, .io = session.io };
        errdefer next.deinit();
        if (self.helper) |helper| try next.startTarget(helper, .{ .path = target.root, .identity = target.root_identity }, target.path, self.query, self.options, &request, &models, budget) else try next.startBundledTarget(.{ .path = target.root, .identity = target.root_identity }, target.path, self.query, self.options, &request, &models, budget);
        self.verifier = next;
    }
    fn drain(self: *State) void {
        // take는 빈 batch도 반환한다. frame당 한 번 가져와야 빈 queue를 계속 순회하지 않는다.
        if (self.verifier.?.take(self.ticket.identity)) |value| {
            var batch = value;
            defer batch.deinit(self.a);
            for (batch.rows.items) |row| {
                var lo: usize = 0;
                var hi = self.expected.items.len;
                while (lo < hi) {
                    const mid = lo + (hi - lo) / 2;
                    const item = self.expected.items[mid];
                    if (item.disk < self.cursor or (item.disk == self.cursor and positionLess(item.match.text_start, row.match.text_start))) lo = mid + 1 else hi = mid;
                }
                for (self.expected.items[lo..]) |*expected| {
                    if (expected.disk != self.cursor or !std.meta.eql(row.match.text_start, expected.match.text_start)) break;
                    if (!std.mem.eql(u8, row.match.text, expected.match.text) or row.match.text_truncated != expected.match.text_truncated) continue;
                    markRanges(expected.match.ranges, expected.found, row.match.ranges);
                }
            }
        }
    }
    /// 호출자는 frame마다 ticket을 확인한다. 완료한 결과도 그 원래 Ticket으로만 worker를 시작한다.
    pub fn poll(self: *State, session: *host.AppSession) !?*worker.Job {
        try self.ticket.validate(session, &self.spec.?);
        if (self.cursor < self.disks.items.len) {
            if (self.verifier == null) try self.begin(session);
            self.drain();
            const done = self.verifier.?.completion() orelse return null;
            self.drain();
            if (done.status != .complete) return done.failure orelse error.StaleSources;
            for (self.expected.items) |expected| if (expected.disk == self.cursor) for (expected.found) |found| if (!found) return error.StaleSources;
            self.disks.items[self.cursor].target.hash = self.verifier.?.targetHash() orelse return error.StaleSources;
            self.closeVerifier();
            self.cursor += 1;
            if (self.cursor < self.disks.items.len) return null;
        }
        const job = try worker.Job.start(self.a, &self.spec.?, self.models, self.disks.items, self.occupied.items, self.ticket, dock.budget.snapshot_bytes, editor.read_limit_bytes);
        self.spec = null;
        self.models = &.{};
        self.captured = 0;
        return job;
    }
};

test "RPBU9 많은 한 줄 범위도 순서와 중복에 의존하지 않고 원래 선택만 검증한다" {
    const a = std.testing.allocator;
    const ranges = try a.alloc(search.event.Range, 20_000);
    defer a.free(ranges);
    for (ranges, 0..) |*range, i| range.* = .{ .start = .{ .line = 0, .byte = @intCast(20_000 - i) }, .end = .{ .line = 0, .byte = @intCast(20_000 - i) } };
    const expected = [_]search.event.Range{
        .{ .start = .{ .line = 0, .byte = 1 }, .end = .{ .line = 0, .byte = 1 } },
        .{ .start = .{ .line = 0, .byte = 20_000 }, .end = .{ .line = 0, .byte = 20_000 } },
        .{ .start = .{ .line = 0, .byte = 20_001 }, .end = .{ .line = 0, .byte = 20_001 } },
        .{ .start = .{ .line = 0, .byte = 1 }, .end = .{ .line = 0, .byte = 1 } },
    };
    var flags = [_]bool{false} ** 4;
    markRanges(&expected, &flags, ranges);
    try std.testing.expectEqualSlices(bool, &.{ true, true, false, true }, &flags);
    // 독립 선형 oracle은 포함된 범위만 true임을 대조한다.
    for (expected, flags) |range, flag| {
        var present = false;
        for (ranges) |actual| if (std.meta.eql(range, actual)) {
            present = true;
            break;
        };
        try std.testing.expectEqual(present, flag);
    }
}
