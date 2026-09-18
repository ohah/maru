//! 시그니처 힌트(docs/editor-surface-tooling.md §8.2d) — `textDocument/signatureHelp` 의 활성 시그니처를 caret 아래 **호버 박스**에 낸다
//! (native-editor-ui §8.3 「한 박스」). 활성 파라미터는 accent 색(raster 는 run 마다 색만 낸다).
//!
//! 트리거: 타이핑한 글자가 서버의 `triggerCharacters` 에 있으면(`noteTyped`) · 열려 있는 동안 `retriggerCharacters` 도 · 열려 있는 동안
//! revision·caret 이 바뀌면 다시 묻는다(`refresh` — 요청이 나가 있으면 표시해 두었다가 응답 뒤 한 번) · `trigger_parameter_hints` 명령.
//! 결과가 없으면 닫는다. **키 입력은 닫지 않는다** — 타이핑하면서 보는 것이 존재 이유다(호버와 다른 점). `Esc`·상자 밖 클릭(마우스로 caret 을 옮기는 클릭도 그것이다 — `mouse()` 머리의 `hover_client.mouseDown`)·
//! 문서가 안 보임·오버레이가 닫는다. 상자의 주인은 하나: 열려 있는 동안 호버는 열지도 닫지도 않는다(`editor_hover` 가 `active` 를 본다).

const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const chrome = maru.chrome;
const editor_ops = @import("editor.zig");
const editor_lsp = @import("editor_lsp.zig");
const editor_hover = @import("editor_hover.zig");
const pane_ops = @import("pane.zig");
const term_ops = @import("term.zig");
const hover_box = chrome.components.hover_box;
const hover_text = maru.session.editor.hover_text;
const lsp = maru.session.editor.lsp;

pub const State = struct {
    /// 상자가 시그니처의 것으로 열려 있다.
    active: bool = false,
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_surface: u64 = 0,
    /// 응답을 기다리는 동안 다시 물을 일이 생겼다(revision·caret) — 응답 뒤 한 번 더.
    dirty: bool = false,
    shown_surface: u64 = 0,
    /// 마지막으로 물은 자리(revision·caret) — 바뀌면 다시 묻는다.
    asked_version: u64 = 0,
    asked_focus: usize = 0,
    lines: std.ArrayList(hover_box.Line) = .empty,
    owned: std.ArrayList([]u8) = .empty,
    /// 판정자 관측.
    opened_count: u64 = 0,
    closed_by_result: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        self.clearLines(allocator);
        self.lines.deinit(allocator);
        self.owned.deinit(allocator);
        self.* = .{};
    }

    fn clearLines(self: *State, allocator: std.mem.Allocator) void {
        for (self.owned.items) |o| allocator.free(o);
        self.owned.clearRetainingCapacity();
        self.lines.clearRetainingCapacity();
    }
};

fn enabled(self: *const AppSession) bool {
    return self.loaded_config.config.editor.parameter_hints;
}

/// 타이핑(`insertText`)의 마지막 byte — 서버의 트리거 글자면 묻는다, 열려 있고 재트리거 글자여도 묻는다(§8.2d 「트리거」 ⑴⑵).
pub fn noteTyped(self: *AppSession, term: *Term, last: u8) void {
    if (!enabled(self)) return;
    const st = &self.editor_signature;
    const triggers = editor_lsp.signatureTriggersFor(self, term) orelse return;
    if (triggers.isTrigger(last)) {
        _ = ask(self, term, .trigger_character, last, st.active);
    } else if (st.active and triggers.isRetrigger(last)) {
        _ = ask(self, term, .trigger_character, last, true);
    }
}

/// `trigger_parameter_hints` 명령·`⇧⌘Space` — caret 자리에서(`triggerKind` 1). 설정을 꺼도 온다. 보냈으면 true.
pub fn triggerManual(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    if (term.rt.editor_selection == null) return false;
    return ask(self, term, .invoked, null, self.editor_signature.active);
}

fn ask(self: *AppSession, term: *Term, kind: lsp.rpc.SignatureTriggerKind, trigger_char: ?u8, is_retrigger: bool) bool {
    const st = &self.editor_signature;
    const doc = term.rt.editor_doc orelse return false;
    const sel = term.rt.editor_selection orelse return false;
    const focus = @min(sel.focus, doc.file.content.len);
    if (st.waiting) {
        st.dirty = true; // 응답 뒤 한 번 더 — 요청은 한 번에 하나
        return true;
    }
    const seq = editor_lsp.requestSignatureHelp(self, term, focus, kind, trigger_char, is_retrigger) orelse return false;
    st.waiting = true;
    st.waiting_seq = seq;
    st.waiting_surface = term.surface.id;
    st.asked_version = term.rt.editor_lsp_version;
    st.asked_focus = focus;
    st.dirty = false;
    return true;
}

/// 응답(`editor_lsp` 가 부른다). 지금 기다리는 seq 가 아니면 버린다. 결과가 없으면 닫는다.
pub fn onResponse(self: *AppSession, seq: u32, view: ?lsp.rpc.SignatureView) void {
    const st = &self.editor_signature;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    const v = view orelse {
        if (st.active) st.closed_by_result += 1;
        hide(self);
        return;
    };
    const term = visibleEditorTerm(self, st.waiting_surface) orelse {
        hide(self);
        return;
    };
    st.clearLines(self.allocator);
    buildLines(self, v) catch {
        st.clearLines(self.allocator);
        hide(self);
        return;
    };
    // 편집 직후에는 행 배열이 비어 앵커가 없을 수 있다(`refreshAfterEdit` 가 스냅숏을 버린다) — 다음 프레임의 `refresh` 가 행을 세운 뒤
    // 자리를 잡으므로 여기서는 임시 자리로 연다.
    const anchor = caretAnchor(term) orelse Anchor{ .x = 0, .y = 0, .h = 0 };
    // 시그니처가 상자의 주인이 된다 — 호버가 열려 있었으면 내린다.
    if (!st.active) {
        editor_hover.hide(self);
        st.opened_count += 1;
    }
    st.active = true;
    st.shown_surface = term.surface.id;
    if (!self.chrome_host.hover_box.open) self.chrome_host.hover_box.show(anchor.x, anchor.y, anchor.h) else {
        self.chrome_host.hover_box.anchor_x = anchor.x;
        self.chrome_host.hover_box.anchor_y = anchor.y;
        self.chrome_host.hover_box.anchor_h = anchor.h;
    }
    self.metal_dirty = true;
    if (st.dirty) {
        st.dirty = false;
        _ = ask(self, term, .content_change, null, true);
    }
}

/// 줄: ① `‹i/N› ‹label›`(N > 1 일 때만 카운터) — 활성 파라미터 구간은 accent ② 파라미터 documentation ③ 시그니처 documentation.
fn buildLines(self: *AppSession, v: lsp.rpc.SignatureView) error{OutOfMemory}!void {
    const st = &self.editor_signature;
    var head_buf: [32]u8 = undefined;
    const head: []const u8 = if (v.count > 1) std.fmt.bufPrint(&head_buf, "{d}/{d} ", .{ v.index + 1, v.count }) catch "" else "";
    const label = try std.mem.concat(self.allocator, u8, &.{ head, v.label });
    st.owned.append(self.allocator, label) catch |e| {
        self.allocator.free(label); // 목록에 못 들어갔으면 여기서 놓는다 — 들어간 뒤에는 `clearLines` 가 놓는다(이중 해제 금지)
        return e;
    };
    var line: hover_box.Line = .{ .text = label, .role = .surface_fg };
    if (v.param) |p| {
        const shift: u32 = @intCast(head.len);
        if (p.hi + shift <= label.len) line.emphasis = .{ .lo = p.lo + shift, .hi = p.hi + shift, .role = .accent_bar };
    }
    try st.lines.append(self.allocator, line);
    if (v.param_doc) |d| try appendMarkdown(self, d);
    if (v.doc) |d| {
        if (v.param_doc != null) try appendOwned(self, "", .surface_fg);
        try appendMarkdown(self, d);
    }
}

fn appendMarkdown(self: *AppSession, md: []const u8) error{OutOfMemory}!void {
    var reduced = try hover_text.reduce(self.allocator, md);
    defer reduced.deinit(self.allocator);
    for (reduced.items.items) |l| try appendOwned(self, l.text, .surface_fg);
}

fn appendOwned(self: *AppSession, text: []const u8, role: chrome.tokens.ColorRole) error{OutOfMemory}!void {
    const st = &self.editor_signature;
    const owned = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(owned);
    try st.owned.append(self.allocator, owned);
    try st.lines.append(self.allocator, .{ .text = owned, .role = role });
}

const Anchor = struct { x: i32, y: i32, h: u32 };

/// caret 셀의 좌상단(창 좌표) — 호버의 낱말 앵커와 같은 출처(`bodyAnchor`).
fn caretAnchor(term: *Term) ?Anchor {
    const rows_len = term.rt.editor_hit_rows_len;
    if (rows_len == 0) return null;
    const doc = term.rt.editor_doc orelse return null;
    const sel = term.rt.editor_selection orelse return null;
    const geom = term.rt.editor_hit_geom;
    const off = @min(sel.focus, doc.file.content.len);
    const line_idx = doc.file.lines.lineAt(off);
    const line = doc.file.lines.line(line_idx) orelse return null;
    const a = chrome.components.editor_view.hit.bodyAnchor(
        .{
            .body_x = geom.body_x,
            .body_y = geom.body_y,
            .content_left_px = geom.content_left_px,
            .content_width = geom.content_width,
            .cell_w_px = geom.cell_w_px,
            .cell_h_px = geom.cell_h_px,
            .tab_width = geom.tab_width,
        },
        term.rt.editor_hit_rows[0..rows_len],
        term.rt.editor_hit_lines[0..rows_len],
        term.rt.editor_lines,
        line_idx,
        off -| line.start,
    ) orelse return null;
    return .{ .x = a.x_px, .y = a.y_px, .h = geom.cell_h_px };
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

/// **매 프레임 다시 묻는다**(호버와 같은 규율): 그 문서가 보이는가 · 오버레이가 없는가 · caret 줄이 그려졌는가. revision 이나 caret 이
/// 바뀌었으면 다시 요청한다(응답이 갈아 끼우거나 닫는다). 열려 있고 그릴 수 있으면 true.
pub fn refresh(self: *AppSession) bool {
    const st = &self.editor_signature;
    if (!st.active) return false;
    const term = visibleEditorTerm(self, st.shown_surface) orelse {
        hide(self);
        return false;
    };
    if (self.anyOverlayOpen() or term.rt.editor_diff != null) {
        hide(self);
        return false;
    }
    const doc = term.rt.editor_doc orelse {
        hide(self);
        return false;
    };
    const sel = term.rt.editor_selection orelse {
        hide(self);
        return false;
    };
    const focus = @min(sel.focus, doc.file.content.len);
    if (term.rt.editor_lsp_version != st.asked_version or focus != st.asked_focus) {
        _ = ask(self, term, .content_change, null, true);
    }
    const anchor = caretAnchor(term) orelse {
        hide(self);
        return false;
    };
    self.chrome_host.hover_box.anchor_x = anchor.x;
    self.chrome_host.hover_box.anchor_y = anchor.y;
    self.chrome_host.hover_box.anchor_h = anchor.h;
    return true;
}

pub fn hide(self: *AppSession) void {
    const st = &self.editor_signature;
    st.waiting = false;
    st.dirty = false;
    if (!st.active) return;
    st.active = false;
    st.clearLines(self.allocator);
    if (self.chrome_host.hover_box.open) self.chrome_host.hover_box.hide();
    self.metal_dirty = true;
}

/// `Esc` — 닫는다(소비하지 않는다). 다른 키는 닫지 않는다(§8.2d 「닫힘」).
pub fn noteEscape(self: *AppSession) void {
    hide(self);
}

pub fn lines(self: *const AppSession) []const hover_box.Line {
    if (!self.editor_signature.active) return &.{};
    return self.editor_signature.lines.items;
}

pub fn deinit(self: *AppSession) void {
    self.editor_signature.deinit(self.allocator);
}
