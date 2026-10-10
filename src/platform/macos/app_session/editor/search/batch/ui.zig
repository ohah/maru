//! 완료 검색의 열린 문서 전체를 동결한다. 적용 중 자원은 검색 상태 밖으로 옮겨 보존한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../../app_session.zig");
const search = maru.session.editor.search;
const dock = @import("../dock.zig");
const owner = @import("../owner.zig");
const preview = @import("../preview.zig");
const actor = @import("../batch.zig");
const worker = @import("worker.zig");
pub const State = struct {
    phase: enum { idle, building, ready, conflict, failed, completed } = .idle,
    job: ?*worker.Job = null,
    ready: ?worker.Ready = null,
    ticket: ?actor.Ticket = null,
    files: usize = 0,
    matches: usize = 0,
    omitted: usize = 0,
    result: actor.Result = .{},
    failure: ?anyerror = null,
    display_root: []const u8 = "",
    pub fn active(self: *const State) bool {
        return self.phase != .idle;
    }
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        if (self.job) |job| job.deinit();
        if (self.ready) |*ready| ready.deinit(a);
        self.* = .{};
    }
    pub fn invalidate(self: *State, a: std.mem.Allocator) void {
        if (!self.active() or self.phase == .completed) return;
        if (self.job) |job| job.deinit();
        self.job = null;
        if (self.ready) |*ready| ready.deinit(a);
        self.ready = null;
        self.display_root = "";
        self.phase = .conflict;
    }
    pub fn rowCount(self: *const State) usize {
        var count: usize = if (self.phase == .completed) 0 else 1;
        if (self.ready) |ready| for (ready.prepared.items.items) |item| {
            count +|= 1;
            if (self.phase != .completed) count +|= item.plan.rows.items.len;
        };
        return count;
    }
    pub fn displayPath(self: *const State, absolute: []const u8) []const u8 {
        return owner.relativeToRoot(self.display_root, absolute) orelse absolute;
    }
};
fn displayRoot(targets: []const search.batch.Target) []const u8 {
    var common = std.fs.path.dirname(targets[0].absolute) orelse "/";
    for (targets) |target| while (common.len > 1 and owner.relativeToRoot(common, target.absolute) == null) {
        common = std.fs.path.dirname(common) orelse "/";
    };
    return common;
}
pub fn canStart(self: *host.AppSession) bool {
    const st = &self.editor_search;
    if (!dock.canSearch(self) or !st.replacing or st.preview.active() or st.batch.active() or st.result.phase != .complete) return false;
    for (st.result.model.groups.items) |group| if (group.source == .model) return true;
    return false;
}
fn current(self: *host.AppSession) bool {
    const st = &self.editor_search;
    const ticket = st.batch.ticket orelse return false;
    return dock.canSearch(self) and st.replacing and st.result.phase == .complete and
        st.result.identity != null and std.meta.eql(st.result.identity.?, ticket.identity) and
        st.stamp == ticket.stamp and owner.fingerprint(self) == ticket.stamp and preview.settingsStamp(self) == ticket.settings;
}
pub fn canApply(self: *host.AppSession) bool {
    return self.editor_search.batch.phase == .ready and self.editor_search.batch.ready != null and current(self);
}
pub fn start(self: *host.AppSession) !void {
    if (!canStart(self)) return error.StaleRequest;
    const st = &self.editor_search;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var selections: std.ArrayList(search.batch.Selection) = .empty;
    var omitted: std.StringHashMapUnmanaged(void) = .{};
    for (st.result.model.groups.items) |group| {
        const root = self.file_tree.rootAt(group.root_index) orelse return error.StaleRequest;
        const name = try search.request.relativePath(group.path);
        const absolute = try std.fs.path.resolve(a, &.{ root, name });
        if (group.source == .disk) {
            try omitted.put(a, absolute, {});
            continue;
        }
        var ranges: std.ArrayList(search.event.Range) = .empty;
        for (group.rows.items) |index| {
            const row = st.result.model.rows.items[index];
            if (!std.meta.eql(row.source, group.source) or row.root_index != group.root_index) return error.StaleRequest;
            try ranges.appendSlice(a, row.match.ranges);
        }
        try selections.append(a, .{ .absolute = absolute, .root_index = group.root_index, .source = group.source, .ranges = ranges.items });
    }
    const query = self.editor_project_search_query orelse return error.StaleRequest;
    var spec = try search.batch.Specification.capture(self.allocator, st.result.identity.?, .complete, st.fields[0].text.items, st.fields[3].text.items, query.options, selections.items);
    var owns_spec = true;
    defer if (owns_spec) spec.deinit(self.allocator);
    const ticket = try actor.Ticket.capture(self, &spec);
    const models = try self.allocator.alloc(worker.Model, spec.targets.items.len);
    var captured: usize = 0;
    var owns_models = true;
    defer if (owns_models) {
        for (models[0..captured]) |*model| model.snapshot.deinit();
        self.allocator.free(models);
    };
    for (spec.targets.items, models) |target, *model| {
        model.* = .{ .source = target.source, .snapshot = try actor.captureSnapshot(self, target) };
        captured += 1;
    }
    const files = spec.targets.items.len;
    const matches = spec.matches;
    const job = try worker.Job.start(self.allocator, &spec, models, ticket, dock.budget.snapshot_bytes, @import("../../mod.zig").read_limit_bytes);
    owns_spec = false;
    owns_models = false;
    st.batch = .{ .phase = .building, .job = job, .ticket = ticket, .files = files, .matches = matches, .omitted = omitted.count() };
    st.scroll.reset();
    st.invalidate();
    st.result.generation +%= 1;
    self.metal_dirty = true;
}
pub fn poll(self: *host.AppSession) void {
    const st = &self.editor_search;
    if (st.batch.phase != .building and st.batch.phase != .ready) return;
    if (!current(self)) {
        st.batch.invalidate(self.allocator);
        st.invalidate();
        st.result.generation +%= 1;
        self.metal_dirty = true;
        return;
    }
    const job = st.batch.job orelse return;
    const ready = job.take() catch |err| {
        job.deinit();
        st.batch.job = null;
        st.batch.phase = .failed;
        st.batch.failure = err;
        st.invalidate();
        st.result.generation +%= 1;
        self.metal_dirty = true;
        return;
    } orelse return;
    job.deinit();
    st.batch.job = null;
    st.batch.ready = ready;
    // 같은 이름의 다른 디렉터리 파일을 구분한다. 과거 결과의 라벨은 현재 root 설정에 기대지 않는다.
    st.batch.display_root = displayRoot(ready.specification.targets.items);
    st.batch.phase = .ready;
    st.invalidate();
    st.result.generation +%= 1;
    self.metal_dirty = true;
}
pub fn back(self: *host.AppSession) void {
    self.editor_search.batch.deinit(self.allocator);
    self.editor_search.scroll.reset();
    self.editor_search.invalidate();
    self.editor_search.result.generation +%= 1;
    self.metal_dirty = true;
}
pub fn apply(self: *host.AppSession) !void {
    if (!canApply(self)) return error.StaleRequest;
    // 자기 commit의 changed 통지가 검색 결과를 해제해도 명세·Plan·결과 슬롯은 살아 있다.
    var transaction = self.editor_search.batch;
    self.editor_search.batch = .{};
    const ready = &transaction.ready.?;
    transaction.result = actor.apply(self, &ready.specification, &ready.prepared, ready.ticket) catch |err| {
        transaction.phase = .conflict;
        transaction.failure = err;
        self.editor_search.batch = transaction;
        self.editor_search.invalidate();
        self.editor_search.result.generation +%= 1;
        self.metal_dirty = true;
        return err;
    };
    transaction.phase = .completed;
    self.editor_search.batch = transaction;
    self.editor_search.scroll.reset();
    self.editor_search.invalidate();
    self.editor_search.result.generation +%= 1;
    self.metal_dirty = true;
}

pub fn resultTerm(self: *host.AppSession, index: usize) ?*host.Term {
    const st = &self.editor_search.batch;
    if (st.phase != .completed or st.ready == null) return null;
    const targets = st.ready.?.specification.targets.items;
    if (index >= targets.len) return null;
    const source = targets[index].source.model.document;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (term.kind != .editor) continue;
        const lease = term.rt.editor_document_lease orelse continue;
        if (source.owner == @intFromPtr(lease.owner) and source.slot == lease.document.slot and source.generation == lease.document.generation) return term;
    };
    return null;
}
pub fn openResult(self: *host.AppSession, index: usize) void {
    const term = resultTerm(self, index) orelse return;
    // 같은 활성 Term 재선택은 기존 focus 함수의 조합 확정을 건너뛴다. 입력 트랜잭션을 먼저 지킨다.
    if (self.ime_active or self.ime_editor_commit_pending or !self.tryCommitComposition()) return;
    // 이름 변경·닫기 뒤 경로로 다른 문서를 다시 열지 않는다. 사용자가 고른 살아 있는 정본만 연다.
    _ = self.activateExistingFileTerm(term);
    if (@import("../../../pane.zig").activePane(self).activeTerm() != term) return;
    self.editor_search.focused = null;
    self.metal_dirty = true;
}
