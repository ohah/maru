//! 활성 문서의 도크 어댑터. 문서 신원 검증은 여기서, 목록 규칙과 기하는 중립 모듈에서 한다.
const std = @import("std");
const maru = @import("maru");
const syntax = @import("syntax");
const host = @import("../../app_session.zig");
const AppSession = host.AppSession;
const editor = @import("mod.zig");
const symbols_client = @import("symbols.zig");
const pane = @import("../pane.zig");
const dock = @import("../dock.zig");
const agent_dock = @import("../agent_dock.zig");
const chrome = maru.chrome;
const component = chrome.components.outline;
const model = maru.session.editor.outline;
const render = @import("outline/render.zig");

pub const collect = render.collect;
pub const publish = render.publish;
pub const Status = enum { not_editor, pending, empty, ready, failed };
const Key = struct {
    source: editor.SymbolPickerSource,
    lsp: bool,
    provider: usize,
    tree: usize,
    applied: u64,
    pending: bool,
};

pub const State = struct {
    model: model.Model = .{},
    key: ?Key = null,
    generation: u64 = 1,
    status: Status = .not_editor,
    active: ?usize = null,
    caret: ?usize = null,
    scroll: chrome.ui.scroll_area.State = .{},
    entries: std.ArrayList(chrome.ui.tree.RectEntry) = .empty,
    actions: std.ArrayList(component.ids.Entry) = .empty,
    interaction: chrome.ui.interaction.InteractionState = .{},
    published_generation: u64 = 0,
    published_content: maru.session.SplitRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    published_offset: u32 = 0,
    published_scale: u32 = 0,
    cache: ?host.MeasuredTextCache = null,
    accessibility: host.accessibility.Snapshot = .{},

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.model.deinit(allocator);
        self.entries.deinit(allocator);
        self.actions.deinit(allocator);
        host.MeasuredTextCache.clear(&self.cache, allocator);
        self.accessibility.deinit(allocator);
        self.* = .{};
    }

    /// 모델을 풀기 전에 빌린 라벨과 입력을 함께 거둔다. OOM 뒤 옛 행으로 이동하지 않게 한다.
    pub fn invalidate(self: *State) void {
        self.generation +%= 1;
        if (self.generation == 0) self.generation = 1;
        self.entries.clearRetainingCapacity();
        self.actions.clearRetainingCapacity();
        self.accessibility.elements.clearRetainingCapacity();
        self.accessibility.strings.clearRetainingCapacity();
        self.interaction = .{};
        self.published_generation = 0;
        self.caret = null;
        self.active = null;
    }
};

fn currentKey(self: *AppSession) ?Key {
    const term = pane.activePane(self).activeTerm();
    const source = editor.symbolPickerSource(term) orelse return null;
    // diff는 본문 쪽을 고르는 별도 계약이 필요하다. 일반 편집 문서의 심볼만 노출한다.
    if (term.rt.editor_diff != null or term.rt.editor_merge != null) return null;
    const st = &term.rt.editor_syntax;
    const lsp = symbols_client.fresh(term);
    return .{
        .source = source,
        .lsp = lsp,
        .provider = if (!lsp and st.provider != null) @intFromPtr(st.provider.?.slot.language) else 0,
        .tree = if (!lsp and st.provider != null and st.provider.?.tree != null) @intFromPtr(st.provider.?.tree.?) else 0,
        .applied = if (lsp) term.rt.editor_symbols.applied else 0,
        .pending = !lsp and st.pending,
    };
}

/// tick와 입력 입구 모두 같은 키를 비교한다. LSP 응답은 본문 리비전이 같아도 목록을 바꿀 수 있다.
pub fn refreshForFocus(self: *AppSession) void {
    if (!dock.dockVisible(self) or self.dock.view != .outline) {
        self.editor_outline.interaction = .{};
        return;
    }
    const state = &self.editor_outline;
    const key = currentKey(self);
    if (!std.meta.eql(state.key, key)) {
        const same_document = if (key) |now| if (state.key) |old| now.source.surface_id == old.source.surface_id and
            now.source.registry == old.source.registry and std.meta.eql(now.source.document, old.source.document) else false else false;
        state.invalidate();
        state.model.deinit(self.allocator);
        state.key = key;
        if (!same_document) state.scroll.reset();
        state.status = if (key == null) .not_editor else if (key.?.pending) .pending else .empty;
        if (key != null and !key.?.pending) rebuild(self) catch {
            state.status = .failed;
        };
        self.metal_dirty = true;
    }
    if (key != null) {
        const caret = if (pane.activePane(self).activeTerm().rt.editor_selection) |selection| selection.focus else 0;
        if (state.caret != caret) {
            const next = state.model.active(caret);
            if (next != state.active) self.metal_dirty = true;
            state.active = next;
            state.caret = caret;
        }
    }
    state.scroll.clamp(scrollExtent(self).max_offset_px);
}

fn rebuild(self: *AppSession) !void {
    const term = pane.activePane(self).activeTerm();
    const doc = term.rt.editorDocument().opened orelse return;
    var scratch: std.ArrayList(syntax.Provider.Symbol) = .empty;
    defer scratch.deinit(self.allocator);
    const syms = symbols_client.list(term) orelse blk: {
        const provider = if (term.rt.editor_syntax.provider) |*p| p else return;
        try provider.symbolsChecked(self.allocator, &scratch);
        break :blk scratch.items;
    };
    var projected: std.ArrayList(model.Symbol) = .empty;
    defer projected.deinit(self.allocator);
    try projected.ensureTotalCapacity(self.allocator, syms.len);
    for (syms) |sym| {
        if (sym.name_start >= sym.name_end or sym.name_end > doc.file.content.len) continue;
        projected.appendAssumeCapacity(.{ .label = doc.file.content[sym.name_start..sym.name_end], .start = sym.start, .end = sym.end, .target = sym.name_start });
    }
    try self.editor_outline.model.replace(self.allocator, projected.items, doc.file.content.len);
    self.editor_outline.status = if (self.editor_outline.model.items.items.len == 0) .empty else .ready;
}

pub fn scaleMilli(self: *const AppSession) u32 {
    return agent_dock.agentSessionDockScaleMilli(self);
}
pub fn rowHeight(self: *const AppSession) u32 {
    return component.types.Metrics.resolve(scaleMilli(self)).row_h;
}

pub fn scrollExtent(self: *const AppSession) AppSession.FileTreeScrollExtent {
    const viewport = dock.dockGeometry(self).tree_content.h;
    const count = @max(self.editor_outline.model.visible.items.len, 1);
    const height: u32 = @intCast(@min(@as(u64, count) * rowHeight(self), std.math.maxInt(u32)));
    return .{ .content_h_px = height, .viewport_h_px = viewport, .max_offset_px = height -| viewport };
}

pub fn setScroll(self: *AppSession, offset: i64) void {
    if (self.editor_outline.scroll.setOffsetPx(offset, scrollExtent(self).max_offset_px)) {
        self.editor_outline.interaction = .{};
        self.dock_list_scrollbar_idle_ticks = 0;
        self.metal_dirty = true;
    }
}

pub fn clearHover(self: *AppSession) void {
    if (self.editor_outline.interaction.hovered != null) {
        self.editor_outline.interaction.hovered = null;
        self.metal_dirty = true;
    }
}

pub fn pointer(self: *AppSession, phase: chrome.ui.interaction.UiPointerPhase, x: f64, y: f64) void {
    if (!dock.dockVisible(self) or self.dock.view != .outline) return;
    // 조합을 먼저 확정해야 심볼 offset과 선택이 같은 문서 판을 가리킨다. 실패하면 이동도 멈춘다.
    if (phase == .down and !self.tryCommitComposition()) return;
    refreshForFocus(self);
    // 매 이벤트가 같은 build를 지나므로 resize·scroll 직후에도 이전 기하를 쓰지 않는다.
    if (!publish(self)) return;
    const state = &self.editor_outline;
    if (dock.dockListScrollbarGeometry(self)) |geometry| if (geometry.trackContains(x, y)) {
        state.interaction = .{};
        return;
    };
    const dispatched = chrome.ui.interaction.dispatch(&state.interaction, .{ .entries = state.entries.items, .generation = state.published_generation }, .{
        .phase = phase,
        .x_px = x,
        .y_px = y,
        .timestamp_ns = 0,
        .generation = state.generation,
    }) catch return;
    for (dispatched.dirty.ids) |id| if (id != null) {
        self.metal_dirty = true;
        break;
    };
    if (dispatched.action) |action| {
        var table = component.ids.Table.init(state.actions.items);
        table.count = state.actions.items.len;
        if (table.resolve(action, state.generation)) |intent| apply(self, intent, state.generation);
    }
}

/// 포인터·접근성 모두 실행 순간의 문서 신원을 다시 묻는다. 공개는 제품 경로를 판정하기 위해서다.
pub fn apply(self: *AppSession, intent: component.ids.Intent, generation: u64) void {
    refreshForFocus(self);
    const state = &self.editor_outline;
    if (!dock.dockVisible(self) or self.dock.view != .outline or state.status != .ready or
        generation != state.generation or !std.meta.eql(state.key, currentKey(self))) return;
    switch (intent) {
        .navigate => |index| {
            if (index >= state.model.items.items.len) return;
            editor.navigateTo(self, .{ .offset = state.model.items.items[index].symbol.target }) catch return;
            agent_dock.releaseAgentSessionDockKeyFocus(self);
            refreshForFocus(self);
        },
        .toggle => |index| {
            if (state.model.toggle(index)) {
                state.invalidate();
                refreshForFocus(self);
                self.metal_dirty = true;
            }
        },
    }
}
