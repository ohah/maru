//! 창의 검색 입력·worker 수신·도크 수명을 연결한다. 본문 검색은 worker가 한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const AppSession = host.AppSession;
const chrome = maru.chrome;
const component = chrome.components.project_search;
const search = maru.session.editor.search;
const owner = @import("owner.zig");
const backend = @import("backend.zig");
const dock = @import("../../dock.zig");
const pane = @import("../../pane.zig");
const render = @import("dock/render.zig");
const navigation = @import("navigation.zig");
pub const preview = @import("preview.zig");
pub const collect = render.collect;
pub const publish = render.publish;

// 14,048개 결과의 제품 RSS·지연 실측 후 채택한 초기 요청 방벽이다. 앱 전체 메모리 상한은 아니다.
pub const limits: search.request.Limits = .{ .matches = 20_000, .result_bytes = 8 * 1024 * 1024, .event_bytes = 4 * 1024 * 1024 };
pub const budget: backend.Budget = .{ .timing = .{ .execution_ms = 10_000, .reap_ms = 1000 }, .snapshot_bytes = 64 * 1024 * 1024, .preview_bytes = 256, .selection_bytes = 8 * 1024 * 1024 };
pub const State = struct {
    result: search.presentation.State = .{},
    fields: [4]chrome.components.text_field.TextField = .{ .{}, .{}, .{}, .{} },
    replacing: bool = false,
    preview: preview.State = .{},
    focused: ?usize = null,
    options: [3]bool = .{ false, false, false },
    expanded: bool = false,
    stamp: ?u64 = null,
    scroll: chrome.ui.scroll_area.State = .{},
    entries: std.ArrayList(chrome.ui.tree.RectEntry) = .empty,
    actions: std.ArrayList(component.ids.Entry) = .empty,
    interaction: chrome.ui.interaction.InteractionState = .{},
    field_drag: ?struct { index: usize, anchor: usize, generation: u64 } = null,
    published_generation: u64 = 0,
    published_content: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    published_offset: u32 = 0,
    published_scale: u32 = 0,
    cache: ?host.MeasuredTextCache = null,
    accessibility: host.accessibility.Snapshot = .{},
    nav: ?navigation.Ticket = null,
    pending: ?backend.Batch = null,
    consumed: usize = 0,
    pub fn dropPending(self: *State, a: std.mem.Allocator) void {
        if (self.pending) |*batch| {
            for (batch.rows.items[self.consumed..]) |*row| row.match.deinit(a);
            batch.rows.deinit(a);
        }
        self.pending = null;
        self.consumed = 0;
    }
    pub fn invalidate(self: *State) void {
        self.entries.clearRetainingCapacity();
        self.actions.clearRetainingCapacity();
        self.accessibility.elements.clearRetainingCapacity();
        self.accessibility.strings.clearRetainingCapacity();
        self.interaction = .{};
        self.field_drag = null;
        self.published_generation = 0;
    }
    pub fn deinit(self: *State, a: std.mem.Allocator) void {
        self.invalidate();
        self.dropPending(a);
        self.preview.deinit(a);
        self.result.deinit(a);
        for (&self.fields) |*field| field.deinit(a);
        self.entries.deinit(a);
        self.actions.deinit(a);
        host.MeasuredTextCache.clear(&self.cache, a);
        self.accessibility.deinit(a);
        if (self.nav) |*nav| nav.deinit(a);
        self.* = .{};
    }
};
fn visible(self: *const AppSession) bool {
    if (!dock.dockVisible(self) or self.dock.view != .project_search) return false;
    const content = dock.dockGeometry(self).tree_content;
    return content.w != 0 and content.h != 0 and dock.dockListTextWidthPx(self) != 0;
}
pub fn ownsInput(self: *const AppSession) bool {
    return visible(self) and self.editor_search.focused != null;
}
pub fn focused(self: *AppSession) ?*chrome.components.text_field.TextField {
    return if (self.editor_search.focused) |index| &self.editor_search.fields[index] else null;
}
pub fn now(self: *const AppSession) u64 {
    return @intCast(@max(0, @divTrunc(std.Io.Clock.awake.now(self.io).nanoseconds, std.time.ns_per_ms)));
}
pub fn scaleMilli(self: *const AppSession) u32 {
    return @import("../../agent_dock.zig").agentSessionDockScaleMilli(self);
}
pub fn metrics(self: *const AppSession) component.types.Metrics {
    return component.types.Metrics.resolveForWidth(scaleMilli(self), self.editor_search.expanded, self.editor_search.replacing, dock.dockListTextWidthPx(self));
}
pub fn resultRect(self: *const AppSession) maru.session.SplitRect {
    var rect = dock.dockGeometry(self).tree_content;
    const header = @min(rect.h, metrics(self).header);
    rect.y += header;
    rect.h -= header;
    return rect;
}
pub fn scrollExtent(self: *const AppSession) AppSession.FileTreeScrollExtent {
    const st = &self.editor_search;
    if (st.preview.active()) {
        const count = if (st.preview.plan) |plan| plan.rows.items.len else 0;
        const height: u32 = @intCast(@min(@as(u64, count) *| metrics(self).row, std.math.maxInt(u32)));
        return .{ .content_h_px = height, .viewport_h_px = resultRect(self).h, .max_offset_px = height -| resultRect(self).h };
    }
    const window = st.result.model.window(metrics(self).row, resultRect(self).h, st.scroll.offset_y_px);
    return .{ .content_h_px = window.content_height, .viewport_h_px = resultRect(self).h, .max_offset_px = window.max_offset };
}
pub fn setScroll(self: *AppSession, offset: i64) void {
    if (self.editor_search.scroll.setOffsetPx(offset, scrollExtent(self).max_offset_px)) {
        cancelPointer(self);
        self.dock_list_scrollbar_idle_ticks = 0;
        self.metal_dirty = true;
    }
}
pub fn remote(self: *const AppSession) bool {
    if (self.tabs.items.len == 0) return false;
    const term = pane.activePane(@constCast(self)).activeTerm();
    if (term.file_entry) |entry| if (entry.remote_origin_dest.len != 0 or entry.diff_remote_dest.len != 0) return true;
    return host.termCwdIsRemote(term) or (term.kind == .editor and term.rt.editorDocument().remote != null);
}
pub fn localRoots(self: *const AppSession) bool {
    if (!self.file_tree_initialized or self.tabs.items.len == 0 or self.file_tree.rootCount() == 0) return false;
    for (0..self.file_tree.rootCount()) |index| {
        const root = self.file_tree.rootAt(index) orelse return false;
        if (self.file_tree.rootCapabilityForPath(root) == null) return false;
    }
    return !remote(self);
}
pub fn canSearch(self: *const AppSession) bool {
    for (self.editor_search.fields) |field| if (field.preedit.items.len != 0) return false;
    return visible(self) and localRoots(self) and self.editor_search.fields[0].text.items.len != 0 and
        !self.ime_active and !self.ime_editor_commit_pending;
}
fn stopRequest(self: *AppSession) void {
    self.editor_search.preview.invalidate(self.allocator);
    owner.cancel(self);
    self.editor_search.dropPending(self.allocator);
    if (self.editor_project_search_query) |*query| query.deinit(self.allocator);
    self.editor_project_search_query = null;
    self.editor_project_search_failure = null;
    if (self.editor_search.nav) |*nav| nav.cancel();
}
pub fn changed(self: *AppSession) void {
    stopRequest(self);
    self.editor_search.invalidate();
    self.editor_search.result.changed(self.allocator, now(self), self.editor_search.fields[0].text.items.len != 0);
    self.editor_search.stamp = if (localRoots(self)) owner.fingerprint(self) else null;
    self.editor_search.scroll.reset();
    self.metal_dirty = true;
}
fn edited(self: *AppSession) void {
    if (self.editor_search.focused == 3) {
        self.editor_search.preview.invalidate(self.allocator);
        self.editor_search.invalidate();
        self.editor_search.result.generation +%= 1;
        self.metal_dirty = true;
    } else changed(self);
}
pub fn setPreedit(self: *AppSession, bytes: []const u8) void {
    const field = focused(self) orelse return;
    if (bytes.len == 0 and field.preedit.items.len == 0) return;
    // 기존 조합을 비우기 전에 예약한다. 새 조합의 할당 실패도 이전 조합을 보존한다.
    field.preedit.ensureTotalCapacity(self.allocator, bytes.len) catch return;
    field.setPreedit(self.allocator, bytes) catch return;
    if (self.editor_search.focused == 3) {
        edited(self);
        return;
    }
    stopRequest(self);
    self.editor_search.invalidate();
    self.editor_search.result.preedit(self.allocator);
    self.metal_dirty = true;
}
pub fn commitText(self: *AppSession, bytes: []const u8) bool {
    const field = focused(self) orelse return false;
    const selected_len = if (field.selection) |selection| selection.hi() - selection.lo() else 0;
    const required = std.math.add(usize, field.text.items.len - selected_len, bytes.len) catch return false;
    // TextField는 선택 삭제 뒤 capacity를 늘린다. 검색 확정은 삭제 전에 예약해 실패 시 원문을 보존한다.
    field.text.ensureTotalCapacity(self.allocator, required) catch return false;
    field.insertText(self.allocator, bytes) catch return false;
    field.preedit.clearRetainingCapacity();
    edited(self);
    return true;
}
pub fn commitPreedit(self: *AppSession) bool {
    const field = focused(self) orelse return true;
    return field.preedit.items.len == 0 or commitText(self, field.preedit.items);
}
pub fn open(self: *AppSession) void {
    if (!self.tryCommitComposition()) return;
    dock.openDockTo(self, .project_search);
    self.chrome_host.find.input_focused = false;
    @import("../../web.zig").cancelAddrEdit(self, false);
    self.sidebar_search_active = false;
    self.agent_session_archive_search_active = false;
    @import("../../scm_dock.zig").blurCommit(self);
    self.editor_search.focused = 0;
    self.editor_search.fields[0].selectAll();
    changed(self);
}
pub fn blur(self: *AppSession) bool {
    if (!commitPreedit(self)) return false;
    self.editor_search.focused = null;
    self.metal_dirty = true;
    return true;
}
pub fn leave(self: *AppSession) bool {
    if (!commitPreedit(self)) return false;
    self.editor_search.focused = null;
    stopRequest(self);
    self.editor_search.invalidate();
    self.editor_search.result.cancel(self.allocator);
    return true;
}
pub fn cancel(self: *AppSession) void {
    stopRequest(self);
    self.editor_search.invalidate();
    self.editor_search.result.cancel(self.allocator);
    self.metal_dirty = true;
}
fn fail(self: *AppSession, err: anyerror) void {
    std.log.warn("project search failed: {s}", .{@errorName(err)});
    cancel(self);
    self.editor_search.result.phase = .failed;
    self.editor_search.result.failure = err;
}
/// 쉼표는 brace/class 바깥에서만 구분자다. 결과는 입력 문자열을 빌리며 Query가 다시 소유한다.
pub const patterns = search.query.splitList;
pub fn run(self: *AppSession) void {
    if (!canSearch(self)) return;
    if (self.editor_search.result.phase == .composing) changed(self);
    const st = &self.editor_search;
    var includes: std.ArrayList([]const u8) = .empty;
    defer includes.deinit(self.allocator);
    var excludes: std.ArrayList([]const u8) = .empty;
    defer excludes.deinit(self.allocator);
    patterns(self.allocator, st.fields[1].text.items, &includes) catch |err| {
        fail(self, err);
        return;
    };
    excludes.appendSlice(self.allocator, &search.query.default_excludes) catch |err| {
        fail(self, err);
        return;
    };
    patterns(self.allocator, st.fields[2].text.items, &excludes) catch |err| {
        fail(self, err);
        return;
    };
    const opts: search.query.Options = .{ .match_case = st.options[0], .whole_word = st.options[1], .regex = st.options[2], .multiline = st.options[2], .includes = includes.items, .excludes = excludes.items };
    self.requestWorkspaceProjectSearch(st.fields[0].text.items, opts, limits, budget) catch |err| {
        fail(self, err);
        return;
    };
    st.invalidate();
    const identity: search.request.Identity = .{ .request = self.editor_project_search_request, .root = self.file_tree.rootGeneration(), .models = owner.fingerprint(self) };
    _ = st.result.begin(self.allocator, identity, self.ime_active or self.ime_editor_commit_pending);
    st.stamp = identity.models;
    self.metal_dirty = true;
}
pub fn refreshForFocus(self: *AppSession) void {
    if (self.editor_project_search_query == null) if (self.editor_project_search_live) |*live| if (live.job.done()) {
        live.job.deinit();
        self.editor_project_search_live = null;
    };
    if (!visible(self)) {
        if (self.editor_search.nav != null or self.editor_search.focused != null or self.editor_search.result.phase == .running or self.editor_search.result.phase == .waiting or self.editor_search.result.phase == .composing) _ = leave(self);
        cancelPointer(self);
        return;
    }
    const st = &self.editor_search;
    const stamp = if (localRoots(self)) owner.fingerprint(self) else null;
    if (st.stamp != stamp) changed(self);
    if (self.anyModalOverlayOpen() or self.chrome_host.notice.open) cancelPointer(self);
    if (st.nav == null and st.result.ready(now(self), self.ime_active or self.ime_editor_commit_pending)) run(self);
    st.scroll.clamp(scrollExtent(self).max_offset_px);
}
pub fn pump(self: *AppSession) void {
    refreshForFocus(self);
    const st = &self.editor_search;
    if (st.result.phase == .running) {
        if (self.editor_project_search_failure) |err| {
            fail(self, err);
            return;
        }
        if (st.pending == null) st.pending = self.takeProjectSearchBatch();
        var updated = false;
        if (st.pending) |*batch| {
            const end = @min(batch.rows.items.len, st.consumed + 256);
            while (st.consumed < end) {
                const row = batch.rows.items[st.consumed];
                if (!(st.result.append(self.allocator, batch.identity, row) catch |err| {
                    fail(self, err);
                    return;
                })) break;
                st.consumed += 1;
                updated = true;
            }
            if (st.consumed == batch.rows.items.len) st.dropPending(self.allocator);
        }
        if (updated) {
            st.invalidate();
            st.result.publish(self.allocator) catch |err| {
                fail(self, err);
                return;
            };
            self.metal_dirty = true;
        }
        if (st.pending == null) if (self.projectSearchCompletion()) |completion| {
            if (self.takeProjectSearchBatch()) |extra| {
                if (extra.rows.items.len != 0) {
                    st.pending = extra;
                    self.metal_dirty = true;
                    return;
                }
                var empty = extra;
                empty.deinit(self.allocator);
            }
            if (st.result.finish(completion.identity, completion.status, completion.excluded, completion.failure)) self.metal_dirty = true;
        };
    }
    navigation.poll(self);
    preview.poll(self);
    st.scroll.clamp(scrollExtent(self).max_offset_px);
}
pub fn handleRawKey(self: *AppSession, event: maru.terminal.KeyEvent) bool {
    const field = focused(self) orelse return false;
    switch (event.key) {
        .delete => {
            field.deleteForward();
            edited(self);
        },
        .home => {
            field.moveHome(event.modifiers.shift);
            self.metal_dirty = true;
        },
        .end => {
            field.moveEnd(event.modifiers.shift);
            self.metal_dirty = true;
        },
        .page_up => setScroll(self, @as(i64, self.editor_search.scroll.offset_y_px) - resultRect(self).h),
        .page_down => setScroll(self, @as(i64, self.editor_search.scroll.offset_y_px) + resultRect(self).h),
        else => return handleKey(self, @import("../../input.zig").chromeInputFromKeyEvent(event)),
    }
    return true;
}
pub fn handleKey(self: *AppSession, event: chrome.input.InputEvent) bool {
    const field = focused(self) orelse return false;
    const k = switch (event) {
        .key => |key| key,
        else => return false,
    };
    switch (k.key) {
        .escape => {
            if (!self.tryCommitComposition()) return true;
            self.editor_search.focused = null;
            cancel(self);
        },
        .enter => {
            if (self.editor_search.focused == 3) return true;
            if (field.preedit.items.len == 0 and (!self.ime_active or !self.ime_had_marked)) {
                changed(self);
                if (self.editor_search.result.phase == .waiting) self.editor_search.result.due_ms = now(self);
                if (!self.ime_active) run(self);
            }
        },
        .tab => {
            if (!self.tryCommitComposition()) return true;
            const order = if (self.editor_search.expanded) (if (self.editor_search.replacing) &[_]usize{ 0, 3, 1, 2 } else &[_]usize{ 0, 1, 2 }) else if (self.editor_search.replacing) &[_]usize{ 0, 3 } else &[_]usize{0};
            for (order, 0..) |index, i| if (index == self.editor_search.focused.?) {
                self.editor_search.focused = order[(i + (if (k.mods.shift) order.len - 1 else 1)) % order.len];
                break;
            };
            self.metal_dirty = true;
        },
        .left => {
            if (k.mods.command) field.moveHome(k.mods.shift) else if (k.mods.option) field.moveWordLeft(" -_./:", k.mods.shift) else field.moveLeft(k.mods.shift);
            self.metal_dirty = true;
        },
        .right => {
            if (k.mods.command) field.moveEnd(k.mods.shift) else if (k.mods.option) field.moveWordRight(" -_./:", k.mods.shift) else field.moveRight(k.mods.shift);
            self.metal_dirty = true;
        },
        .backspace => {
            if (k.mods.command) field.deleteToLineStart() else if (k.mods.option) field.deleteWordBackward(" -_./:") else field.deleteBackward();
            edited(self);
        },
        .char => {
            if (k.mods.command and (k.codepoint == 'a' or k.codepoint == 'A')) {
                field.selectAll();
                self.metal_dirty = true;
                return true;
            }
            if (k.mods.command and (k.codepoint == 'x' or k.codepoint == 'X')) {
                cut(self);
                return true;
            }
            if (k.mods.control and (k.codepoint == 'a' or k.codepoint == 'A')) {
                field.moveHome(k.mods.shift);
                self.metal_dirty = true;
                return true;
            }
            if (k.mods.control and (k.codepoint == 'e' or k.codepoint == 'E')) {
                field.moveEnd(k.mods.shift);
                self.metal_dirty = true;
                return true;
            }
            if (k.mods.command or k.mods.control or k.mods.option) return false;
            if (k.codepoint >= 0x20 and k.codepoint != 0x7f) {
                field.text.ensureUnusedCapacity(self.allocator, 4) catch return true;
                field.insertCp(self.allocator, k.codepoint) catch return true;
                edited(self);
            }
        },
        .up => {
            field.moveHome(k.mods.shift);
            self.metal_dirty = true;
        },
        .down => {
            field.moveEnd(k.mods.shift);
            self.metal_dirty = true;
        },
        .other => return true,
    }
    return true;
}
pub fn paste(self: *AppSession, text: []const u8) void {
    const field = focused(self) orelse return;
    self.commitComposition();
    if (field.preedit.items.len != 0) return;
    _ = commitText(self, text);
}
pub fn cut(self: *AppSession) void {
    const field = focused(self) orelse return;
    const selected = field.selection orelse return;
    const bytes = field.text.items[selected.lo()..selected.hi()];
    if (bytes.len == 0) return;
    const copy = self.allocator.dupe(u8, bytes) catch return;
    if (self.chrome_clipboard_write.len > 0) self.allocator.free(self.chrome_clipboard_write);
    self.chrome_clipboard_write = copy;
    _ = field.deleteSelection();
    edited(self);
}
pub fn cancelPointer(self: *AppSession) void {
    if (self.editor_search.interaction.hovered != null or self.editor_search.interaction.capture != null) self.metal_dirty = true;
    self.editor_search.interaction = .{};
    self.editor_search.field_drag = null;
}
pub fn clearHover(self: *AppSession) void {
    if (self.editor_search.interaction.hovered != null) self.metal_dirty = true;
    self.editor_search.interaction.hovered = null;
}
pub fn pointer(self: *AppSession, phase: chrome.ui.interaction.UiPointerPhase, x: f64, y: f64) void {
    if (phase == .down and !self.tryCommitComposition()) return;
    refreshForFocus(self);
    if (!publish(self)) return;
    const st = &self.editor_search;
    const tree: chrome.ui.tree.UiRectTree = .{ .entries = st.entries.items, .generation = st.published_generation };
    if (phase != .down) if (st.field_drag) |drag| {
        if (drag.generation != st.result.generation or st.focused != drag.index) {
            cancelPointer(self);
            return;
        }
        if (phase == .move or phase == .up) {
            const at = byteForPoint(self, drag.index, x) catch {
                cancelPointer(self);
                return;
            };
            const field = &st.fields[drag.index];
            field.selection = .{ .anchor = drag.anchor, .focus = field.caret };
            field.selectTo(at);
            self.metal_dirty = true;
        }
        if (phase == .up or phase == .cancel) {
            cancelPointer(self);
            return;
        }
    };
    var actual = phase;
    if (phase == .up) if (st.interaction.capture) |capture| {
        const hit = chrome.ui.interaction.hitAction(tree, x, y);
        if (hit == null or hit.?.id != capture.id or hit.?.action_id != capture.action_id) actual = .cancel;
    };
    const dispatched = chrome.ui.interaction.dispatch(&st.interaction, tree, .{ .phase = actual, .x_px = x, .y_px = y, .timestamp_ns = 0, .generation = st.result.generation }) catch return;
    self.metal_dirty = true;
    if (phase == .down) if (chrome.ui.interaction.hitAction(tree, x, y)) |hit| {
        var table = component.ids.Table.init(st.actions.items);
        table.count = st.actions.items.len;
        if (table.resolve(hit.action_id, st.result.generation)) |intent| if (intent == .field) {
            const index = intent.field;
            const at = byteForPoint(self, index, x) catch {
                cancelPointer(self);
                return;
            };
            apply(self, intent, st.result.generation);
            if (st.focused != index) return;
            const field = &st.fields[index];
            field.caret = maru.grapheme.snapToBoundary(field.text.items, at);
            field.clearSelection();
            st.field_drag = .{ .index = index, .anchor = field.caret, .generation = st.result.generation };
        };
    };
    if (dispatched.action) |action| {
        var table = component.ids.Table.init(st.actions.items);
        table.count = st.actions.items.len;
        if (table.resolve(action, st.result.generation)) |intent| apply(self, intent, st.result.generation);
    }
}
pub fn apply(self: *AppSession, intent: component.ids.Intent, generation: u64) void {
    refreshForFocus(self);
    const st = &self.editor_search;
    if (!visible(self) or generation != st.result.generation) return;
    switch (intent) {
        .field => |index| {
            if (index >= 4 or index == 3 and !st.replacing or index > 0 and index < 3 and !st.expanded or !self.tryCommitComposition()) return;
            self.chrome_host.find.input_focused = false;
            @import("../../web.zig").cancelAddrEdit(self, false);
            self.sidebar_search_active = false;
            self.agent_session_archive_search_active = false;
            @import("../../scm_dock.zig").blurCommit(self);
            st.focused = index;
            st.fields[index].moveEnd(false);
        },
        .option => |index| {
            if (!self.tryCommitComposition()) return;
            if (index < 3) {
                st.options[index] = !st.options[index];
                changed(self);
            } else if (index == 8) {
                _ = @import("report.zig").open(self) catch |err| {
                    self.showNoticeKey(if (err == error.OutOfMemory) .dbg_editor_oom else .dbg_editor_unreadable);
                    return;
                };
            } else if (index == 7) {
                preview.back(self);
            } else if (index == 6) {
                preview.back(self);
                st.replacing = !st.replacing;
                if (!st.replacing and st.focused == 3) st.focused = 0;
                st.invalidate();
                st.result.generation +%= 1;
            } else if (index == 3) {
                st.expanded = !st.expanded;
                if (!st.expanded and st.focused != null and st.focused.? > 0 and st.focused.? < 3) st.focused = 0;
                st.invalidate();
                st.result.generation +%= 1;
            }
        },
        .run => run(self),
        .cancel => cancel(self),
        .row => |index| {
            if (st.preview.active()) return;
            if (index >= st.result.model.visible.items.len) return;
            if (st.replacing) {
                preview.start(self, index) catch |err| {
                    if (err == error.StaleRequest) changed(self) else {
                        // 실패한 다음 준비가 이미 읽는 미리보기까지 덮어쓰지 않는다.
                        if (!st.preview.active()) {
                            st.preview.phase = .failed;
                            st.preview.failure = err;
                        }
                        self.showNoticeKey(if (err == error.OutOfMemory) .dbg_editor_oom else .dbg_editor_unreadable);
                    }
                };
                self.metal_dirty = true;
                return;
            }
            switch (st.result.model.visible.items[index]) {
                .file => |group| {
                    st.result.model.groups.items[group].collapsed = !st.result.model.groups.items[group].collapsed;
                    st.invalidate();
                    st.result.publish(self.allocator) catch |err| {
                        fail(self, err);
                        return;
                    };
                },
                .hit => |hit| navigation.start(self, hit.row, hit.range) catch |err| switch (err) {
                    error.NavigationPending => {},
                    error.StaleRequest => changed(self),
                    else => fail(self, err),
                },
            }
        },
    }
    self.metal_dirty = true;
}
pub fn caretRect(self: *AppSession) ?chrome.draw.Rect {
    if (!ownsInput(self) or !publish(self)) return null;
    const index = self.editor_search.focused.?;
    const tree: chrome.ui.tree.UiRectTree = .{ .entries = self.editor_search.entries.items, .generation = self.editor_search.published_generation };
    const rect = tree.entries[tree.find(component.build.fieldId(index)) orelse return null].rect;
    const m = metrics(self);
    const display = makeDisplay(self.allocator, &self.editor_search.fields[index], "", @as(usize, @intFromFloat(@max(0, rect.width - @as(f32, @floatFromInt(m.inset * 2))))) / @max(self.cell_width_px, 1)) catch return null;
    defer self.allocator.free(display.text);
    const positions = measure(self, display.text, .{ display.caret, display.caret, display.caret }, @as(u32, @intFromFloat(rect.width)) -| m.inset * 2) catch return null;
    return .{ .x = @intFromFloat(rect.x + @as(f32, @floatFromInt(m.inset)) + positions[0]), .y = @intFromFloat(rect.y + @as(f32, @floatFromInt(m.inset))), .w = @max(1, scaleMilli(self) / 1000), .h = m.row -| m.inset * 2 };
}

extern "c" fn maru_macos_coretext_chrome_offsets(text: [*]const u8, len: usize, offsets: *const [3]usize, positions: *[3]f64, family: [*]const u8, family_len: usize, fallback: [*]const u8, fallback_len: usize, font_px: f64, weight: u32, width: f64) c_int;
pub const Display = struct { text: []u8, caret: usize, selected: ?struct { start: usize, end: usize } = null };
pub fn makeDisplay(a: std.mem.Allocator, field: *const chrome.components.text_field.TextField, glyph: []const u8, cols: usize) !Display {
    var surrogate = field.*;
    var replacement: ?[]u8 = null;
    defer if (replacement) |bytes| a.free(bytes);
    if (field.preedit.items.len != 0) if (field.selection) |sel| {
        replacement = try std.mem.concat(a, u8, &.{ field.text.items[0..sel.lo()], field.text.items[sel.hi()..] });
        surrogate.text.items = replacement.?;
        surrogate.caret = sel.lo();
        surrogate.selection = null;
    };
    const text = try chrome.components.inline_edit.composeLineFit(a, &surrogate, glyph, cols);
    for (text) |*byte| if (byte.* == '\n' or byte.* == '\r') {
        byte.* = ' ';
    };
    const caret = @min(surrogate.caret + surrogate.preedit.items.len, text.len);
    const selected = if (surrogate.selection) |sel| Display{ .text = text, .caret = caret, .selected = .{ .start = @min(sel.lo() + (if (sel.lo() >= surrogate.caret) glyph.len else 0), text.len), .end = @min(sel.hi() + (if (sel.hi() > surrogate.caret) glyph.len else 0), text.len) } } else Display{ .text = text, .caret = caret };
    return selected;
}
pub fn measure(self: *AppSession, text: []const u8, offsets: [3]usize, width: u32) ![3]f32 {
    if (width == 0) return .{ 0, 0, 0 };
    if (@import("builtin").os.tag != .macos) return .{ 0, 0, 0 };
    const token = chrome.ui.typography.token(.control);
    var values: [3]f64 = undefined;
    const family = self.appearance.font.family;
    const fallback = self.appearance.font.fallback;
    if (maru_macos_coretext_chrome_offsets(text.ptr, text.len, &offsets, &values, family.ptr, family.len, fallback.ptr, fallback.len, @as(f64, @floatFromInt(token.point_size)) * @as(f64, @floatFromInt(scaleMilli(self))) / 1000.0, @intFromEnum(token.weight), @floatFromInt(width)) != 0) return error.MeasureFailed;
    return .{ @floatCast(values[0]), @floatCast(values[1]), @floatCast(values[2]) };
}

extern "c" fn maru_macos_coretext_chrome_index(text: [*]const u8, len: usize, family: [*]const u8, family_len: usize, fallback: [*]const u8, fallback_len: usize, font_px: f64, weight: u32, width: f64, x: f64, byte_index: *usize) c_int;
pub fn byteForPoint(self: *AppSession, index: usize, x: f64) !usize {
    if (index >= 4) return error.InvalidField;
    const st = &self.editor_search;
    const tree: chrome.ui.tree.UiRectTree = .{ .entries = st.entries.items, .generation = st.published_generation };
    const rect = tree.entries[tree.find(component.build.fieldId(index)) orelse return error.NoField].rect;
    const m = metrics(self);
    const inset: f64 = @floatFromInt(m.inset);
    const field = &st.fields[index];
    if (@import("builtin").os.tag != .macos) return field.caret;
    if (x <= rect.x + inset) return 0;
    if (x >= rect.x + rect.width - inset) return field.text.items.len;
    const width = @as(u32, @intFromFloat(rect.width)) -| m.inset * 2;
    if (width == 0) return 0;
    const glyph = "";
    const display = try makeDisplay(self.allocator, field, glyph, width / @max(self.cell_width_px, 1));
    defer self.allocator.free(display.text);
    const token = chrome.ui.typography.token(.control);
    const family = self.appearance.font.family;
    const fallback = self.appearance.font.fallback;
    var at: usize = 0;
    if (maru_macos_coretext_chrome_index(display.text.ptr, display.text.len, family.ptr, family.len, fallback.ptr, fallback.len, @as(f64, @floatFromInt(token.point_size)) * @as(f64, @floatFromInt(scaleMilli(self))) / 1000.0, @intFromEnum(token.weight), @floatFromInt(width), x - rect.x - inset, &at) != 0) return error.MeasureFailed;
    if (glyph.len != 0 and at > display.caret) at -|= glyph.len;
    return maru.grapheme.snapToBoundary(field.text.items, @min(at, field.text.items.len));
}
