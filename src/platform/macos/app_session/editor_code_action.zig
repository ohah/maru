//! code action(docs/editor-surface-tooling.md §8.2h) — `⌘.`/팔레트로 `textDocument/codeAction` 을 묻고(범위 + 겹치는 진단), `edit` 이 있거나
//! resolve 할 수 있는 항목만 **컨텍스트 메뉴**(`context_menu` 의 `code_action_menu` 갈래)로 caret 아래에 낸다. 고르면 `edit` 을 §8.2f 의
//! `apply` 로(WorkspaceEdit 의 두 번째 소비자 — 전부 검증·저장 정책·기록), `edit` 이 없으면 `codeAction/resolve` 를 보내고 그 응답의 `edit` 을
//! 같은 길로. `command` 는 실행하지 않는다(§8.2 seam).
//!
//! 요청은 `7_000_000_000+seq`(resolve 는 `8e9+seq`) — 응답은 지금 기다리는 seq 일 때만. 항목은 **복사**해 든다(title 과 원래 JSON 텍스트 —
//! resolve 에 그대로 되돌려 주려고).

const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const editor_lsp = @import("editor_lsp.zig");
const editor_rename = @import("editor_rename.zig");
const editor_wse = @import("editor_workspace_edit.zig");
const pane_ops = @import("pane.zig");
const settings_ops = @import("settings.zig");
const term_ops = @import("term.zig");
const lsp = maru.session.editor.lsp;

/// 메뉴 항목 상한 — `context_menu_items_buf` 의 크기.
pub const max_items: usize = app_session_mod.ctx_menu_count;

pub const Owned = struct {
    title: []u8,
    /// 원래 항목의 JSON 텍스트 — `edit` 이 없을 때 resolve 에 그대로.
    raw: []u8,
    has_edit: bool,

    fn deinit(self: *Owned, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.raw);
    }
};

pub const State = struct {
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_surface: u64 = 0,
    resolve_waiting: bool = false,
    resolve_seq: u32 = 0,
    /// 요청 시점의 열린 문서 revision(§8.2f 검증).
    snaps: [64]editor_wse.VersionSnap = undefined,
    snaps_len: usize = 0,
    /// 메뉴의 주인 문서.
    surface_id: u64 = 0,
    items: std.ArrayList(Owned) = .empty,
    /// 판정자 관측.
    opened_count: u64 = 0,
    notified_none: u64 = 0,
    notified_error: u64 = 0,
    applied: u64 = 0,
    resolved: u64 = 0,
    hidden: u64 = 0,

    pub fn clearItems(self: *State, allocator: std.mem.Allocator) void {
        for (self.items.items) |*it| it.deinit(allocator);
        self.items.clearRetainingCapacity();
    }

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearItems(allocator);
        self.items.deinit(allocator);
    }
};

pub fn deinit(self: *AppSession) void {
    self.editor_code_action.deinit(self.allocator);
}

/// `quick_fix` 명령·`⌘.` — 활성 편집기의 선택(없으면 caret)에서. 보냈으면 true.
pub fn quickFix(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;
    const sel = term.rt.editor_selection orelse return false;
    const st = &self.editor_code_action;
    const seq = editor_lsp.requestCodeAction(self, term, @min(sel.start(), doc.file.content.len), @min(sel.end(), doc.file.content.len)) orelse return false;
    st.waiting = true;
    st.waiting_seq = seq;
    st.waiting_surface = term.surface.id;
    snapshotVersions(self);
    return true;
}

/// codeAction 응답(`editor_lsp` 가 부른다). 낡은 seq 는 버린다. 낼 것이 없으면 알림, 있으면 메뉴.
pub fn onResponse(self: *AppSession, seq: u32, result: ?std.json.Value, is_error: bool, error_message: ?[]const u8) void {
    const st = &self.editor_code_action;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    if (is_error) {
        st.notified_error += 1;
        self.showNoticeFmt(.ca_error, &.{.{ .s = error_message orelse "" }});
        return;
    }
    const term = visibleEditorTerm(self, st.waiting_surface) orelse return;
    const caps = editor_lsp.codeActionCapsFor(self, term) orelse return;
    var list = lsp.code_action.parse(self.allocator, result, caps.resolve) catch {
        st.notified_none += 1;
        self.showNoticeKey(.ca_none);
        return;
    };
    defer list.deinit(self.allocator);
    st.hidden += list.hidden;
    st.clearItems(self.allocator);
    for (list.items) |it| {
        if (st.items.items.len >= max_items) break;
        const raw = std.json.Stringify.valueAlloc(self.allocator, it.raw, .{}) catch break;
        const title = self.allocator.dupe(u8, it.title) catch {
            self.allocator.free(raw);
            break;
        };
        st.items.append(self.allocator, .{ .title = title, .raw = raw, .has_edit = it.edit != null }) catch {
            self.allocator.free(raw);
            self.allocator.free(title);
            break;
        };
    }
    if (st.items.items.len == 0) {
        st.notified_none += 1;
        self.showNoticeKey(.ca_none);
        return;
    }
    // 메뉴 — caret 셀 **아래**(`at_anchor` 는 앵커에서 시작하므로 한 셀 내리고, 모달 quad 의 padding 이 caret 줄을 덮지 않게 그만큼 더 띄운다 —
    // 호버 상자와 같은 간격, 캡처 실측). 앵커가 없으면(아직 안 그려짐) 화면 원점 근처.
    const sel = term.rt.editor_selection orelse return;
    const a = editor_rename.anchorAt(term, @min(sel.focus, term.rt.editor_doc.?.file.content.len)) orelse editor_rename.Anchor{ .x = 0, .y = 0, .h = 0 };
    const gap: i32 = @intCast(self.buildChromeProps().shape.modal_padding_px);
    settings_ops.closeContextMenu(self);
    for (st.items.items, 0..) |it, i| self.context_menu_items_buf[i] = it.title;
    self.context_menu_items_len = st.items.items.len;
    st.surface_id = term.surface.id;
    self.code_action_menu = true;
    self.chrome_host.context_menu.show(a.x, a.y + @as(i32, @intCast(a.h)) + gap, st.items.items.len);
    st.opened_count += 1;
    self.metal_dirty = true;
}

/// 메뉴에서 고른 항목(`acceptContextMenu` 가 부른다 — 메뉴는 이미 닫혔다).
pub fn accept(self: *AppSession, index: usize) void {
    const st = &self.editor_code_action;
    if (index >= st.items.items.len) return;
    const item = st.items.items[index];
    const term = visibleEditorTerm(self, st.surface_id) orelse return;
    if (item.has_edit) {
        applyRaw(self, term, item.raw);
        return;
    }
    // resolve — 항목 JSON 그대로.
    const seq = editor_lsp.requestCodeActionResolve(self, term, item.raw) orelse {
        st.notified_none += 1;
        self.showNoticeKey(.ca_none);
        return;
    };
    st.resolve_waiting = true;
    st.resolve_seq = seq;
}

/// resolve 응답 — `edit` 을 같은 길로.
pub fn onResolveResponse(self: *AppSession, seq: u32, result: ?std.json.Value, is_error: bool, error_message: ?[]const u8, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_code_action;
    if (!st.resolve_waiting or seq != st.resolve_seq) return;
    st.resolve_waiting = false;
    if (is_error) {
        st.notified_error += 1;
        self.showNoticeFmt(.ca_error, &.{.{ .s = error_message orelse "" }});
        return;
    }
    const r = result orelse {
        st.notified_none += 1;
        self.showNoticeKey(.ca_none);
        return;
    };
    if (r != .object) return;
    const edit = r.object.get("edit") orelse {
        st.notified_none += 1;
        self.showNoticeKey(.ca_none);
        return;
    };
    st.resolved += 1;
    applyEdit(self, edit, enc);
}

/// 항목 JSON 텍스트의 `edit` 을 적용한다.
fn applyRaw(self: *AppSession, term: *Term, raw: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, raw, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const edit = parsed.value.object.get("edit") orelse return;
    const c = editor_lsp.readyClientFor(self, term) orelse return;
    applyEdit(self, edit, c.encoding);
}

fn applyEdit(self: *AppSession, edit: std.json.Value, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_code_action;
    var parsed = lsp.workspace_edit.parse(self.allocator, edit) catch |err| switch (err) {
        error.Unsupported, error.Malformed => {
            self.editor_workspace_edit.refused_rejected += 1;
            self.showNoticeFmt(.rn_rejected, &.{.{ .s = if (err == error.Unsupported) "file operation" else "malformed" }});
            return;
        },
        error.OutOfMemory => return,
    };
    defer parsed.deinit(self.allocator);
    switch (editor_wse.apply(self, parsed, enc, st.snaps[0..st.snaps_len])) {
        .applied => |n| {
            st.applied += 1;
            self.showNoticeFmt(.ca_applied, &.{.{ .d = @intCast(n) }});
        },
        .refused => |r| switch (r) {
            .outside_root => |p| self.showNoticeFmt(.rn_outside_root, &.{.{ .s = p }}),
            .stale => self.showNoticeKey(.rn_stale),
            .rejected => |p| self.showNoticeFmt(.rn_rejected, &.{.{ .s = p }}),
            .out_of_memory => {},
        },
    }
}

fn snapshotVersions(self: *AppSession) void {
    const st = &self.editor_code_action;
    st.snaps_len = 0;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |t| {
        if (t.kind != .editor or t.rt.editor_doc == null) continue;
        if (st.snaps_len >= st.snaps.len) return;
        st.snaps[st.snaps_len] = .{ .surface_id = t.surface.id, .version = t.rt.editor_lsp_version };
        st.snaps_len += 1;
    };
}

fn visibleEditorTerm(self: *AppSession, surface_id: u64) ?*Term {
    const loc = term_ops.findTermWhere(self, surface_id, struct {
        fn pred(want: u64, t: *Term) bool {
            return t.kind == .editor and t.surface.id == want;
        }
    }.pred) orelse return null;
    if (loc.tab_index != self.app_window.active_tab) return null;
    const term = loc.pane.terms.items[loc.term_index];
    if (loc.pane.activeTerm() != term) return null;
    return term;
}
