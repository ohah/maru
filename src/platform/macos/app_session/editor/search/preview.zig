//! 바꾸기 미리보기는 불변 전문과 worker를 소유하고, 재검증한 정본 문서에 명시적으로 적용·저장한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const search = maru.session.editor.search;
const backend = @import("backend.zig");
const owner = @import("owner.zig");
const dock = @import("dock.zig");
const verify = @import("verify.zig");
const editor = @import("../mod.zig");
const disk_apply = @import("disk_apply.zig");
const Source = union(enum) {
    model: maru.session.editor.buffer.Snapshot,
    disk: struct { root: []u8, path: []u8, identity: maru.session.file_tree.Identity, hash: ?[32]u8 = null },
};
const Input = struct {
    source: Source,
    needle: []u8,
    replacement: []u8,
    ranges: []search.event.Range,
    opts: search.query.Options,
    fn deinit(self: *Input, a: std.mem.Allocator) void {
        switch (self.source) {
            .model => |*snapshot| snapshot.deinit(),
            .disk => |disk| {
                a.free(disk.root);
                a.free(disk.path);
            },
        }
        a.free(self.needle);
        a.free(self.replacement);
        a.free(self.ranges);
    }
};
var workers = std.atomic.Value(usize).init(0);
pub fn outstandingWorkers() usize {
    return workers.load(.acquire) + disk_apply.outstandingWorkers();
}
const Job = struct {
    a: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(2),
    done: std.atomic.Value(bool) = .init(false),
    control: @import("process.zig").Control = .{},
    input: Input,
    plan: ?search.preview.Plan = null,
    failure: ?anyerror = null,
    fn start(a: std.mem.Allocator, input: Input) !*Job {
        const job = try a.create(Job);
        errdefer a.destroy(job);
        job.* = .{ .a = a, .input = input };
        _ = workers.fetchAdd(1, .acq_rel);
        const thread = std.Thread.spawn(.{}, execute, .{job}) catch |err| {
            _ = workers.fetchSub(1, .acq_rel);
            return err;
        };
        thread.detach();
        return job;
    }
    fn release(self: *Job) void {
        if (self.refs.fetchSub(1, .acq_rel) == 1) {
            if (self.plan) |*plan| plan.deinit(self.a);
            self.a.destroy(self);
        }
    }
    fn deinit(self: *Job) void {
        self.control.cancelled.store(true, .release);
        self.release();
    }
    fn execute(self: *Job) void {
        defer _ = workers.fetchSub(1, .acq_rel);
        defer self.release();
        defer self.done.store(true, .release);
        defer self.input.deinit(self.a);
        self.prepare() catch |err| {
            self.failure = err;
        };
    }
    fn prepare(self: *Job) !void {
        var threaded = std.Io.Threaded.init(self.a, .{ .async_limit = .nothing, .concurrent_limit = .nothing });
        defer threaded.deinit();
        const content = switch (self.input.source) {
            .model => |snapshot| blk: {
                if (snapshot.byteLen() > editor.read_limit_bytes) return error.TooLarge;
                break :blk try snapshot.copyRange(self.a, 0, snapshot.byteLen());
            },
            .disk => |disk| blk: {
                const loaded = try verify.read(self.a, threaded.io(), disk.root, disk.path, &self.control, editor.read_limit_bytes, disk.identity);
                errdefer self.a.free(loaded.bytes);
                if (disk.hash == null or !std.mem.eql(u8, &disk.hash.?, &loaded.hash)) return error.FileChanged;
                break :blk loaded.bytes;
            },
        };
        defer self.a.free(content);
        self.plan = try search.preview.prepare(self.a, content, self.input.needle, self.input.replacement, self.input.opts, self.input.ranges, editor.read_limit_bytes, &self.control.cancelled);
    }
};
const Expected = struct {
    match: search.event.Match,
    found: []bool,
    fn deinit(self: *Expected, a: std.mem.Allocator) void {
        self.match.deinit(a);
        a.free(self.found);
    }
};
pub const ModelTarget = struct { document: search.request.DocumentIdentity, revision: u64, surface: u64 };
pub const State = struct {
    target: ?ModelTarget = null,
    disk_target: ?disk_apply.Target = null,
    apply_check: ?*disk_apply.Check = null,
    phase: enum { idle, verifying, building, ready, applying, conflict, failed } = .idle,
    stamp: u64 = 0,
    settings_stamp: u64 = 0,
    title: []u8 = &.{},
    input: ?Input = null,
    verifier: ?backend.Backend = null,
    identity: ?search.request.Identity = null,
    expected: std.ArrayList(Expected) = .empty,
    job: ?*Job = null,
    plan: ?search.preview.Plan = null,
    failure: ?anyerror = null,
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        if (self.disk_target) |*target| target.deinit(a);
        if (self.apply_check) |job| job.deinit();
        if (self.input) |*input| input.deinit(a);
        if (self.verifier) |*job| job.deinit();
        if (self.job) |job| job.deinit();
        if (self.plan) |*plan| plan.deinit(a);
        for (self.expected.items) |*expected| expected.deinit(a);
        self.expected.deinit(a);
        if (self.title.len != 0) a.free(self.title);
        self.* = .{};
    }
    pub fn invalidate(self: *State, a: std.mem.Allocator) void {
        if (self.phase == .idle) return;
        if (self.apply_check) |job| job.deinit();
        self.apply_check = null;
        if (self.verifier) |*job| job.deinit();
        self.verifier = null;
        if (self.job) |job| job.deinit();
        self.job = null;
        if (self.input) |*input| input.deinit(a);
        self.input = null;
        for (self.expected.items) |*expected| expected.deinit(a);
        self.expected.clearRetainingCapacity();
        self.phase = .conflict;
    }
    pub fn active(self: *const State) bool {
        return self.phase != .idle;
    }
};
fn document(term: *host.Term) search.request.DocumentIdentity {
    const doc = term.rt.editorDocument();
    return if (term.rt.editor_document_lease) |lease| .{ .owner = @intFromPtr(lease.owner), .slot = lease.document.slot, .generation = lease.document.generation } else .{ .owner = @intFromPtr(doc), .slot = 0, .generation = 0 };
}
/// 파일 행은 그 파일의 전체 일치, 일치 행은 하나만 선택한다. 불완전한 검색 결과는 계획으로 승격하지 않는다.
pub fn start(self: *host.AppSession, visible_index: usize) !void {
    const st = &self.editor_search;
    if (!st.replacing or st.result.phase != .complete or st.stamp == null or st.stamp.? != owner.fingerprint(self) or !dock.canSearch(self)) return error.StaleRequest;
    if (visible_index >= st.result.model.visible.items.len) return error.StaleRequest;
    const chosen = st.result.model.visible.items[visible_index];
    const group_index = switch (chosen) {
        .file => |group| group,
        .hit => |hit| blk: {
            for (st.result.model.groups.items, 0..) |group, i| for (group.rows.items) |row| if (row == hit.row) break :blk i;
            return error.StaleRequest;
        },
    };
    const group = st.result.model.groups.items[group_index];
    var next: State = .{ .stamp = st.stamp.?, .settings_stamp = settingsStamp(self), .identity = st.result.identity };
    errdefer next.deinit(self.allocator);
    next.title = try self.allocator.dupe(u8, group.path);
    var ranges: std.ArrayList(search.event.Range) = .empty;
    defer ranges.deinit(self.allocator);
    for (group.rows.items) |index| {
        if (chosen == .hit and chosen.hit.row != index) continue;
        const row = st.result.model.rows.items[index];
        const spans = if (chosen == .hit) row.match.ranges[chosen.hit.range..][0..1] else row.match.ranges;
        try ranges.appendSlice(self.allocator, spans);
        if (group.source == .disk) {
            var expected: Expected = .{ .match = .{ .path = try self.allocator.dupe(u8, row.match.path), .text = undefined, .ranges = undefined, .text_start = row.match.text_start, .text_truncated = row.match.text_truncated }, .found = undefined };
            errdefer self.allocator.free(expected.match.path);
            expected.match.text = try self.allocator.dupe(u8, row.match.text);
            errdefer self.allocator.free(expected.match.text);
            expected.match.ranges = try self.allocator.dupe(search.event.Range, spans);
            errdefer self.allocator.free(expected.match.ranges);
            expected.found = try self.allocator.alloc(bool, spans.len);
            errdefer self.allocator.free(expected.found);
            @memset(expected.found, false);
            try next.expected.append(self.allocator, expected);
        }
    }
    var input_owned = false;
    const needle = try self.allocator.dupe(u8, st.fields[0].text.items);
    errdefer if (!input_owned) self.allocator.free(needle);
    const replacement = try self.allocator.dupe(u8, st.fields[3].text.items);
    errdefer if (!input_owned) self.allocator.free(replacement);
    const spans = try ranges.toOwnedSlice(self.allocator);
    errdefer if (!input_owned) self.allocator.free(spans);
    const opts: search.query.Options = .{ .regex = st.options[2], .whole_word = st.options[1], .match_case = st.options[0] };
    const source: Source = switch (group.source) {
        .model => |original| blk: {
            if (original.composition != 0) return error.StaleRequest;
            for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
                if (term.kind != .editor or !std.meta.eql(document(term), original.document)) continue;
                const opened = term.rt.editorDocument().opened orelse return error.NoDocument;
                if (opened.file.revision != original.revision or owner.compositionStamp(term) != 0) return error.StaleRequest;
                next.target = .{ .document = original.document, .revision = original.revision, .surface = term.surfaceId() };
                break :blk .{ .model = opened.file.snapshot() };
            };
            return error.StaleRequest;
        },
        .disk => blk: {
            const root = self.file_tree.rootAt(group.root_index) orelse return error.StaleRequest;
            const cap = self.file_tree.rootCapabilityForPath(root) orelse return error.StaleRequest;
            next.disk_target = try disk_apply.Target.init(self.allocator, root, try search.request.relativePath(group.path), cap.identity);
            const name = try self.allocator.dupe(u8, try search.request.relativePath(group.path));
            errdefer self.allocator.free(name);
            break :blk .{ .disk = .{ .root = try self.allocator.dupe(u8, root), .path = name, .identity = cap.identity } };
        },
    };
    // 모든 필드를 소유한 뒤에는 아래 State 하나만 정리 책임을 가진다.
    input_owned = true;
    next.input = .{ .source = source, .needle = needle, .replacement = replacement, .ranges = spans, .opts = opts };
    if (source == .disk) {
        const query = self.editor_project_search_query orelse return error.StaleRequest;
        next.verifier = .{ .a = self.allocator, .io = self.io };
        var state: search.request.State = .{ .identity = st.result.identity.?, .limits = dock.limits };
        defer state.deinit(self.allocator);
        var models: std.ArrayList(backend.model.Captured) = .empty;
        defer models.deinit(self.allocator);
        var budget = dock.budget;
        budget.navigation_bytes = editor.read_limit_bytes;
        const disk = source.disk;
        if (@import("builtin").is_test and query.helper_for_test != null) {
            try next.verifier.?.startTarget(query.helper_for_test.?, .{ .path = disk.root, .identity = disk.identity }, disk.path, query.text, query.options, &state, &models, budget);
        } else try next.verifier.?.startBundledTarget(.{ .path = disk.root, .identity = disk.identity }, disk.path, query.text, query.options, &state, &models, budget);
        next.phase = .verifying;
    } else {
        next.job = try Job.start(self.allocator, next.input.?);
        next.input = null;
        next.phase = .building;
    }
    st.preview.deinit(self.allocator);
    st.preview = next;
    st.scroll.reset();
    st.invalidate();
    st.result.generation +%= 1;
    self.metal_dirty = true;
}
fn drain(a: std.mem.Allocator, state: *State) void {
    if (state.verifier.?.take(state.identity.?)) |value| {
        var batch = value;
        defer batch.deinit(a);
        for (batch.rows.items) |row| for (state.expected.items) |*expected| {
            if (!std.meta.eql(row.match.text_start, expected.match.text_start) or !std.mem.eql(u8, row.match.text, expected.match.text) or row.match.text_truncated != expected.match.text_truncated) continue;
            for (expected.match.ranges, expected.found) |range, *found| for (row.match.ranges) |actual| if (std.meta.eql(range, actual)) {
                found.* = true;
            };
        };
    }
}
pub fn poll(self: *host.AppSession) void {
    const state = &self.editor_search.preview;
    if (!state.active() or state.phase == .conflict or state.phase == .failed) return;
    if (state.stamp != owner.fingerprint(self)) {
        state.invalidate(self.allocator);
        self.metal_dirty = true;
        return;
    }
    if (state.phase == .applying) {
        pollApply(self);
        return;
    }
    if (state.phase == .verifying) {
        drain(self.allocator, state);
        const done = state.verifier.?.completion() orelse return;
        drain(self.allocator, state);
        var valid = done.status == .complete;
        for (state.expected.items) |expected| for (expected.found) |found| if (!found) {
            valid = false;
        };
        const hash = state.verifier.?.targetHash();
        if (!valid or hash == null) {
            state.invalidate(self.allocator);
            state.failure = done.failure;
            self.metal_dirty = true;
            return;
        }
        state.input.?.source.disk.hash = hash;
        state.disk_target.?.hash = hash;
        state.job = Job.start(self.allocator, state.input.?) catch |err| {
            state.phase = .failed;
            state.failure = err;
            self.metal_dirty = true;
            return;
        };
        state.input = null;
        state.phase = .building;
    }
    if (state.phase == .building) {
        const job = state.job.?;
        if (!job.done.load(.acquire)) return;
        state.failure = job.failure;
        state.plan = job.plan;
        job.plan = null;
        job.deinit();
        state.job = null;
        state.phase = if (state.plan != null) .ready else if ((if (state.failure) |err| err == error.FileChanged or err == error.StaleMatch else false)) .conflict else .failed;
        if (state.plan) |plan| for (plan.rows.items, 0..) |row, index| if (row.kind != .context) {
            self.editor_search.scroll.offset_y_px = @intCast(@min(@as(u64, index -| 1) * dock.metrics(self).row, std.math.maxInt(u32)));
            break;
        };
        self.editor_search.invalidate();
        self.editor_search.result.generation +%= 1;
        self.metal_dirty = true;
    }
}
pub fn back(self: *host.AppSession) void {
    self.editor_search.preview.deinit(self.allocator);
    self.editor_search.scroll.reset();
    self.editor_search.invalidate();
    self.editor_search.result.generation +%= 1;
    self.metal_dirty = true;
}

/// 취소 후 소유자 참조를 놓은 job도 allocator 결산보다 먼저 물러나야 한다. 제품 종료는 기다리지 않는다.
pub fn quietForTest(self: *host.AppSession) void {
    const wait = @import("../../../detached_worker_wait.zig");
    if (self.editor_search.preview.verifier) |*job| {
        job.cancel();
        if (job.active) |active| wait.quietState(active, self.io);
    }
    if (self.editor_search.preview.apply_check) |job| {
        job.control.cancelled.store(true, .release);
        wait.quietState(job, self.io);
    }
    if (self.editor_search.preview.job) |job| {
        job.control.cancelled.store(true, .release);
        wait.quietState(job, self.io);
    }
    const deadline = std.Io.Clock.awake.now(self.io).nanoseconds + wait.timeout_ns;
    while (outstandingWorkers() != 0) {
        if (std.Io.Clock.awake.now(self.io).nanoseconds >= deadline) return;
        std.Thread.yield() catch {};
    }
}

/// 경로가 아닌 정본 신원으로 찾는다. 같은 경로의 독립 문서는 적용 대상이 아니다.
fn targetTerm(self: *host.AppSession) ?*host.Term {
    const target = self.editor_search.preview.target orelse return null;
    var result: ?*host.Term = null;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (term.kind != .editor or !std.meta.eql(document(term), target.document)) continue;
        if (term.rt.editor_diff != null or term.rt.editor_merge != null or term.rt.editor_search_report != null) return null;
        const state = term.rt.editorDocument();
        const opened = state.opened orelse return null;
        if (state.path == null or state.untitled != null or state.remote != null or opened.file.read_only or
            opened.file.revision != target.revision or owner.compositionStamp(term) != 0) return null;
        if (result == null or term.surfaceId() == target.surface) result = term;
    };
    return result;
}
fn settingsStamp(self: *host.AppSession) u64 {
    var hash = std.hash.Wyhash.init(0);
    for (self.editor_search.fields) |field| {
        hash.update(std.mem.asBytes(&field.text.items.len));
        hash.update(field.text.items);
    }
    hash.update(std.mem.asBytes(&self.editor_search.options));
    hash.update(std.mem.asBytes(&self.editor_search.replacing));
    return hash.final();
}
pub fn canApply(self: *host.AppSession) bool {
    const state = &self.editor_search.preview;
    if (self.ime_active or self.ime_editor_commit_pending or state.phase != .ready or state.plan == null or state.plan.?.edits.items.len == 0) return false;
    for (self.editor_search.fields) |field| if (field.preedit.items.len > 0) return false;
    return state.settings_stamp == settingsStamp(self) and state.stamp == owner.fingerprint(self) and (if (state.disk_target) |target| diskUnoccupied(self, target.absolute) else targetTerm(self) != null);
}
pub const ApplyResult = union(enum) { pending, saved, save_failed: editor.SaveError };
/// 편집과 저장은 별도 결과다. 저장 실패가 이미 적용된 본문과 Undo를 되감지 않는다.
pub fn apply(self: *host.AppSession) !ApplyResult {
    if (!canApply(self)) return error.StaleRequest;
    if (self.editor_search.preview.disk_target) |target| {
        const job = try disk_apply.Check.start(self.allocator, target, editor.read_limit_bytes);
        self.editor_search.preview.apply_check = job;
        self.editor_search.preview.phase = .applying;
        self.editor_search.invalidate();
        self.editor_search.result.generation +%= 1;
        self.metal_dirty = true;
        return .pending;
    }
    var term = targetTerm(self) orelse return error.StaleRequest;
    const state = &self.editor_search.preview;
    const current = term.rt.editorDocument().opened.?.file.content;
    if (!std.mem.eql(u8, current, state.plan.?.before)) return error.StaleRequest;
    // 편집 통지로 도크가 무효화되어도 delta가 빌린 after는 이 호출이 소유한다.
    var plan = state.plan.?;
    state.plan = null;
    const generation = self.editor_search.result.generation;
    const stamp = state.stamp;
    var applied = false;
    defer {
        if (!applied and self.editor_search.result.generation == generation and self.editor_search.preview.plan == null)
            self.editor_search.preview.plan = plan
        else
            plan.deinit(self.allocator);
    }
    const changes = try plan.changes(self.allocator);
    defer self.allocator.free(changes);
    if (self.editor_search.result.generation != generation or self.editor_search.preview.stamp != stamp or self.editor_search.preview.settings_stamp != settingsStamp(self) or owner.fingerprint(self) != stamp) return error.StaleRequest;
    term = targetTerm(self) orelse return error.StaleRequest;
    if (!editor.applyEditAsOneWithUndo(self, term, changes)) return error.ApplyFailed;
    applied = true;
    const result: ApplyResult = if (editor.saveDocument(self, term)) |_| .saved else |err| .{ .save_failed = err };
    self.editor_search.focused = null;
    _ = self.activateExistingFileTerm(term);
    if (term.rt.editor_selection == null) term.rt.editor_selection = maru.session.editor.selection.Selection.at(changes[0].start);
    dock.changed(self);
    self.editor_search.preview.deinit(self.allocator);
    return result;
}

/// 앱 전역 정본과 현재 창의 웹 패널도 점유로 본다. 디스크 결과가 새로 열린 문서를 대신 수정하면 안 된다.
fn diskUnoccupied(self: *host.AppSession, path: []const u8) bool {
    for (self.editor_documents.slots.items) |slot| {
        const doc = slot.document orelse continue;
        if (doc.state.remote != null) continue;
        const existing = doc.state.path orelse continue;
        const normalized = std.fs.path.resolve(self.allocator, &.{existing}) catch return false;
        defer self.allocator.free(normalized);
        if (std.mem.eql(u8, normalized, path)) return false;
    }
    return @import("../../file_panel.zig").fileTermForPath(self, path) == null;
}
fn pollApply(self: *host.AppSession) void {
    const state = &self.editor_search.preview;
    const check = state.apply_check orelse return;
    if (!check.done.load(.acquire)) return;
    if (check.failure) |err| {
        state.failure = err;
        state.invalidate(self.allocator);
        dock.applyFailure(self, err);
        return;
    }
    if (state.settings_stamp != settingsStamp(self) or self.ime_active or self.ime_editor_commit_pending) {
        state.invalidate(self.allocator);
        return;
    }
    for (self.editor_search.fields) |field| if (field.preedit.items.len > 0) {
        state.invalidate(self.allocator);
        return;
    };
    // 열기·편집 통지가 live preview를 정산해도 이 호출의 원문/대체 텍스트는 살아 있어야 한다.
    var transaction = state.*;
    state.* = .{};
    defer transaction.deinit(self.allocator);
    const result = finishDiskApply(self, &transaction) catch |err| {
        transaction.phase = .conflict;
        transaction.failure = err;
        if (transaction.apply_check) |job| job.deinit();
        transaction.apply_check = null;
        self.editor_search.preview.deinit(self.allocator);
        self.editor_search.preview = transaction;
        transaction = .{};
        self.editor_search.invalidate();
        self.editor_search.result.generation +%= 1;
        dock.applyFailure(self, err);
        return;
    };
    dock.applyFinished(self, result);
}
fn finishDiskApply(self: *host.AppSession, transaction: *State) !ApplyResult {
    const target = transaction.disk_target.?;
    if (!diskUnoccupied(self, target.absolute)) return error.StaleRequest;
    // worker 완료 뒤에도 root를 다시 확인한다. 전문을 main에서 다시 해시하지는 않는다.
    var root = try @import("process.zig").openRoot(self.allocator, self.io, target.root);
    defer root.deinit(self.allocator, self.io);
    if (@as(u64, @intCast(root.device)) != target.identity.device or root.stat.inode != target.identity.inode) return error.RootChanged;
    try @import("process.zig").validateRoot(self.io, &root);
    const changes = try transaction.plan.?.changes(self.allocator);
    defer self.allocator.free(changes);
    const opened = try @import("../../pane.zig").openNativeFileTermInActivePane(self, target.absolute);
    if (!opened.created) return error.StaleRequest;
    const term = opened.term;
    const doc = term.rt.editorDocument();
    // 열기 도중 디스크가 달라졌거나 기존 복구 백업이 붙었다면 원문을 덮지 않는다.
    if (doc.opened.?.file.read_only or doc.opened.?.isDirty() or !std.mem.eql(u8, doc.opened.?.file.content, transaction.plan.?.before)) return error.FileChanged;
    try @import("process.zig").validateRoot(self.io, &root);
    if (!editor.applyEditAsOneWithUndo(self, term, changes)) return error.ApplyFailed;
    const result: ApplyResult = if (editor.saveDocument(self, term)) |_| .saved else |err| .{ .save_failed = err };
    self.editor_search.focused = null;
    if (term.rt.editor_selection == null) term.rt.editor_selection = maru.session.editor.selection.Selection.at(changes[0].start);
    dock.changed(self);
    self.editor_search.preview.deinit(self.allocator);
    return result;
}
