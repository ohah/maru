//! 편집기 **호버 박스**(docs/editor-surface-tooling.md §8.2b · native-editor-ui §8.3) — 포인터가 낱말 위에 머물면 그 자리를 덮는
//! 진단(§5.4 목록)과 언어 서버의 `textDocument/hover` 를 한 상자에 낸다. `show_hover` 명령은 caret 자리로 같은 상자를 연다.
//!
//! **선택 헬퍼의 규율을 그대로 쓴다**(send-selection §6.2): 모달이 아니고(`.not_an_overlay`), 닫는 자리를 경로마다 심지 않고
//! **프레임마다 같은 질문 묶음을 다시 묻는다**(`refresh`) — 그 문서가 보이는가 · 그 줄이 아직 그려졌는가 · revision 이 같은가 ·
//! 오버레이가 없는가. 그 위에 즉시 닫는 것(포인터가 낱말 밖이면서 상자 밖 · 수정자 아닌 키 · 상자 밖 휠 · 상자 밖 클릭 · Esc)은
//! 각 입력 경로가 `hide` 를 부른다.
//!
//! 흐름: `notePointer`(hoverCursor 마다) → `tick`(정지 시간이 `editor.hover-delay` 를 넘으면 자리 판정 → 진단 + 요청) →
//! `onHoverResponse`(seq 대조 → 줄 만들기 → 열기) 또는 서버가 없으면 지연 뒤 진단만으로 연다.

const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const chrome = maru.chrome;
const editor_ops = @import("editor.zig");
const editor_lsp = @import("editor_lsp.zig");
const pane_ops = @import("pane.zig");
const term_ops = @import("term.zig");
const hover_box = chrome.components.hover_box;
const diagnostic = maru.session.editor.diagnostic;
const hover_text = maru.session.editor.hover_text;
const lsp = maru.session.editor.lsp;

/// 서버가 있는데 응답이 이 시간 안에 안 오면 진단만으로 연다(§8.2b 「요청」).
pub const response_timeout_ms: u64 = 2000;

pub const State = struct {
    // ── 포인터 ────────────────────────────────────────────────────────────────
    pointer_x: f64 = 0,
    pointer_y: f64 = 0,
    pointer_moved_ms: u64 = 0,
    pointer_valid: bool = false,
    /// 이 정지에 대해 이미 판정했다(같은 자리에서 tick 마다 다시 열지 않는다). 움직이면 풀린다.
    stop_judged: bool = false,

    // ── 요청 대기 ─────────────────────────────────────────────────────────────
    waiting: bool = false,
    waiting_seq: u32 = 0,
    waiting_surface: u64 = 0,
    waiting_offset: u32 = 0,
    waiting_since_ms: u64 = 0,
    /// 대기 중인 호버가 포인터에서 왔는가(아니면 `show_hover` — caret 앵커).
    waiting_from_pointer: bool = true,

    // ── 열림 ─────────────────────────────────────────────────────────────────
    shown_surface: u64 = 0,
    /// 앵커 낱말의 문서 범위 — 포인터가 이 밖으로(그리고 상자 밖으로) 나가면 닫는다.
    word_lo: u32 = 0,
    word_hi: u32 = 0,
    /// 열 때의 revision(`editor_lsp_version` 과 같은 축) — 편집되면 닫는다.
    shown_version: u64 = 0,
    lines: std.ArrayList(hover_box.Line) = .empty,
    owned: std.ArrayList([]u8) = .empty,
    /// 판정자 관측: 연 횟수.
    opened_count: u64 = 0,

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

/// 상자를 그리는 props 와 **같은 것**(`buildChromeOverlayPrep` 의 props — shape 의 모달 padding 이 간격과 보이는 rect 를 정한다).
fn chromeProps(self: *const AppSession) chrome.props.ChromeProps {
    return self.buildChromeProps();
}

fn enabled(self: *const AppSession) bool {
    return self.loaded_config.config.editor.hover;
}

fn delayMs(self: *const AppSession) u64 {
    return self.loaded_config.config.editor.hover_delay;
}

// ── 포인터 ───────────────────────────────────────────────────────────────────────

/// 버튼 없는 포인터 이동(`hoverCursor` 마다). 열려 있으면 sticky 판정 — 낱말 위·상자 위는 남고 그 밖은 닫는다.
pub fn notePointer(self: *AppSession, x_px: f64, y_px: f64) void {
    const st = &self.editor_hover;
    if (st.pointer_valid and st.pointer_x == x_px and st.pointer_y == y_px) return;
    st.pointer_x = x_px;
    st.pointer_y = y_px;
    st.pointer_valid = true;
    st.pointer_moved_ms = self.awakeMs();
    st.stop_judged = false;
    if (self.editor_signature.active) return; // 상자의 주인이 시그니처다(§8.2d) — 포인터가 열지도 닫지도 않는다
    // 완성 팝업(§8.2g)의 가드는 여기가 아니라 `tick` 에 있다 — 여기 두면 앞서 세워 둔 `pointer_valid` 를 못 막고(적대적 3회차 C10), `tick` 에
    // 두면 여기 것은 등가다(4회차 C10). 하나만 둔다.
    if (self.chrome_host.hover_box.open) {
        if (hover_box.contains(&self.chrome_host.hover_box, st.lines.items, chromeProps(self), x_px, y_px)) return;
        if (shownTerm(self)) |term| {
            if (pointerOffset(term, x_px, y_px)) |off| {
                if (off >= st.word_lo and off < st.word_hi) return;
            }
        }
        hide(self);
    }
}

/// 세션 tick — 정지 시간이 지연을 넘으면 그 자리로 연다. 응답 대기가 오래되면 진단만으로 연다.
pub fn tick(self: *AppSession) void {
    const st = &self.editor_hover;
    const now = self.awakeMs();
    if (st.waiting) {
        if (now -| st.waiting_since_ms >= response_timeout_ms) {
            st.waiting = false;
            openWith(self, st.waiting_surface, st.waiting_offset, null, null, st.waiting_from_pointer);
        }
        return;
    }
    // 시그니처가 열려 있으면 상자가 열려 있다(`onResponse` 가 둘을 한 자리에서 세운다) — 그래서 `hover_box.open` 하나가 둘 다 막는다
    // (`editor_signature.active` 를 따로 보던 조건은 등가였다 — 적대적 3회차 C6).
    if (!enabled(self) or !st.pointer_valid or st.stop_judged or self.chrome_host.hover_box.open) return;
    // 완성 팝업은 다른 상자라 `hover_box.open` 이 막지 않는다 — 팝업이 뜬 동안 포인터가 멈춰 있어도 열지 않는다(§8.2g, 적대적 3회차 C10 은
    // `notePointer` 의 가드만으로는 앞서 세워 둔 `pointer_valid` 를 못 막았다).
    if (self.editor_completion.active) return;
    if (now -| st.pointer_moved_ms < delayMs(self)) return;
    st.stop_judged = true;
    if (self.pointer_gesture_owner != .none) return; // 드래그 중에는 안 연다
    if (self.anyOverlayOpen()) return;
    const term = pane_ops.activePane(self).activeTerm();
    const off = pointerOffset(term, st.pointer_x, st.pointer_y) orelse return;
    begin(self, term, off, true);
}

/// `show_hover` 명령 — caret 자리로 연다(§8.2b 「키보드」). `editor.hover` 를 꺼도 온다.
pub fn showAtCaret(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    const sel = term.rt.editor_selection orelse return false;
    if (self.anyOverlayOpen()) return false;
    hide(self);
    const off: usize = @min(sel.focus, doc.file.content.len);
    if (!charAt(doc.file.content, off)) return false;
    begin(self, term, off, false);
    return true;
}

/// 자리가 정해졌다 — 서버가 있으면 요청하고 기다린다, 없으면 진단만으로 바로 연다.
fn begin(self: *AppSession, term: *Term, offset: usize, from_pointer: bool) void {
    const st = &self.editor_hover;
    if (editor_lsp.requestHover(self, term, offset)) |seq| {
        st.waiting = true;
        st.waiting_seq = seq;
        st.waiting_surface = term.surface.id;
        st.waiting_offset = @intCast(offset);
        st.waiting_since_ms = self.awakeMs();
        st.waiting_from_pointer = from_pointer;
        return;
    }
    openWith(self, term.surface.id, @intCast(offset), null, null, from_pointer);
}

/// hover 응답(`editor_lsp` 가 부른다). 지금 기다리는 seq 가 아니면 버린다.
pub fn onHoverResponse(self: *AppSession, seq: u32, markdown: ?[]const u8, range: ?lsp.rpc.Range, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_hover;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    openWith(self, st.waiting_surface, st.waiting_offset, markdown, if (range) |r| .{ .range = r, .enc = enc } else null, st.waiting_from_pointer);
}

const RangeIn = struct { range: lsp.rpc.Range, enc: lsp.rpc.PositionEncoding };

/// 줄을 만들고 앵커를 세워 연다. 진단도 서버 내용도 없으면 열지 않는다.
fn openWith(self: *AppSession, surface_id: u64, offset: u32, markdown: ?[]const u8, range: ?RangeIn, from_pointer: bool) void {
    const st = &self.editor_hover;
    const term = visibleEditorTerm(self, surface_id) orelse return;
    const doc = term.rt.editor_doc orelse return;
    const content = doc.file.content;
    if (offset >= content.len) return;
    // 포인터에서 왔으면 포인터가 아직 그 자리인지 본다 — 기다리는 동안 딴 데로 갔으면 열지 않는다.
    if (from_pointer) {
        const now_off = pointerOffset(term, st.pointer_x, st.pointer_y) orelse return;
        const w = maru.session.editor.selection.wordRangeAt(content, offset);
        if (now_off < w.lo or now_off >= w.hi) return;
    }
    st.clearLines(self.allocator);
    buildDiagnosticLines(self, term, offset) catch {
        st.clearLines(self.allocator);
        return;
    };
    if (markdown) |md| {
        if (st.lines.items.len > 0) appendLine(self, "", .surface_fg) catch {};
        var reduced = hover_text.reduce(self.allocator, md) catch {
            st.clearLines(self.allocator);
            return;
        };
        defer reduced.deinit(self.allocator);
        for (reduced.items.items) |l| appendLine(self, l.text, .surface_fg) catch {
            st.clearLines(self.allocator);
            return;
        };
    }
    if (st.lines.items.len == 0) return;
    // 앵커 낱말 — 서버의 range 가 있으면 그것, 없으면 낱말 규칙.
    var lo: usize = 0;
    var hi: usize = 0;
    if (range) |r| {
        lo = lsp.position.offsetOf(content, doc.file.lines, r.range.start_line, r.range.start_char, r.enc);
        hi = lsp.position.offsetOf(content, doc.file.lines, r.range.end_line, r.range.end_char, r.enc);
    }
    if (hi <= lo or offset < lo or offset >= hi) {
        const w = maru.session.editor.selection.wordRangeAt(content, offset);
        lo = w.lo;
        hi = @max(w.hi, w.lo + 1);
    }
    const anchor = anchorFor(term, lo) orelse {
        st.clearLines(self.allocator);
        return;
    };
    st.shown_surface = surface_id;
    st.word_lo = @intCast(lo);
    st.word_hi = @intCast(hi);
    st.shown_version = term.rt.editor_lsp_version;
    st.opened_count += 1;
    self.chrome_host.hover_box.show(anchor.x, anchor.y, anchor.h);
    self.metal_dirty = true;
    _ = refresh(self);
}

fn appendLine(self: *AppSession, text: []const u8, role: chrome.tokens.ColorRole) error{OutOfMemory}!void {
    const st = &self.editor_hover;
    const owned = try self.allocator.dupe(u8, text);
    errdefer self.allocator.free(owned);
    try st.owned.append(self.allocator, owned);
    try st.lines.append(self.allocator, .{ .text = owned, .role = role });
}

/// 그 offset 을 덮는 진단 → **VS Code 마커 호버의 모양**(§8.2b 「내용 순서」 ①, 2026-09-17 사용자 결정): 메시지는 평문 한 줄(아이콘·색 없음 —
/// gutter 글리프가 이미 든다), 그 아래 흐린 색으로 한 칸 들여 `출처(코드)`(출처만·코드만도 가능, 둘 다 없으면 줄 없음). 구문 오류는 i18n 문장에
/// 출처 줄 없음. severity 높은 것부터 — 목록은 start 순·같은 start 는 severity 순이라 덮는 것끼리 다시 고른다.
fn buildDiagnosticLines(self: *AppSession, term: *Term, offset: u32) error{OutOfMemory}!void {
    if (!self.loaded_config.config.editor.diagnostics) return;
    const server_name: []const u8 = if (editor_lsp.serverFor(self, term.rt.editor_grammar)) |s| s.exe else "";
    // 덮는 것을 모아 severity 로 고른다(안정 정렬 — 같은 severity 는 목록 순).
    var covering: [16]diagnostic.Diagnostic = undefined;
    var n: usize = 0;
    for (term.rt.editor_diagnostics.list.items) |d| {
        if (offset < d.start or offset >= @max(d.end, d.start + 1)) continue;
        if (n == covering.len) break;
        covering[n] = d;
        n += 1;
    }
    std.mem.sort(diagnostic.Diagnostic, covering[0..n], {}, struct {
        fn f(_: void, a: diagnostic.Diagnostic, b: diagnostic.Diagnostic) bool {
            return @intFromEnum(a.severity) > @intFromEnum(b.severity);
        }
    }.f);
    var buf: [512]u8 = undefined;
    for (covering[0..n]) |d| {
        const text: []const u8 = switch (d.source) {
            .syntax => if (d.message.len > 0)
                maru.i18n.format(&buf, maru.i18n.t(.diag_missing), &.{.{ .s = d.message }})
            else
                maru.i18n.t(.diag_syntax_error),
            .lsp, .lint => firstLine(d.message),
        };
        try appendLine(self, text, .surface_fg);
        const source: []const u8 = if (d.source == .syntax) "" else server_name;
        if (source.len == 0 and d.code.len == 0) continue;
        var src_buf: [256]u8 = undefined;
        const src_line = if (source.len > 0 and d.code.len > 0)
            std.fmt.bufPrint(&src_buf, " {s}({s})", .{ source, d.code }) catch continue
        else if (source.len > 0)
            std.fmt.bufPrint(&src_buf, " {s}", .{source}) catch continue
        else
            // 코드만 있는 갈래는 오늘 **닿을 수 없다**(적대적 3회차 C2, 등가) — `.lsp` 진단은 서버 이름이 늘 있고 `.lint` 는 아직 없다.
            // 남기는 이유는 계약(§8.2b 「코드만이면 `(코드)`」)이 린트를 위해 그 모양을 정해 뒀기 때문이다.
            std.fmt.bufPrint(&src_buf, " ({s})", .{d.code}) catch continue;
        try appendLine(self, src_line, .muted_fg);
    }
}

/// 진단 message 의 첫 줄만 — 서버가 여러 줄을 보내면(clangd 의 note 나열) 첫 줄이 요지다.
fn firstLine(s: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, s, '\n') orelse return s;
    return s[0..nl];
}

// ── 자리 ────────────────────────────────────────────────────────────────────────

/// 포인터 아래의 **글자** offset. 본문 밖·gutter·줄 끝 뒤·공백은 `null`(§8.2b 「글자가 없는 자리는 열지 않는다」).
pub fn pointerOffset(term: *Term, x_px: f64, y_px: f64) ?usize {
    if (term.kind != .editor or term.rt.editor_diff != null) return null;
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const rows_len = term.rt.editor_hit_rows_len;
    if (rows_len == 0) return null;
    const geom = term.rt.editor_hit_geom;
    // `bodyPoint` 는 세로를 clamp 한다 — 본문 밖은 여기서 거른다(클릭은 같은 clamp 를 일부러 쓴다).
    const top: f64 = @floatFromInt(geom.body_y);
    const bottom: f64 = top + @as(f64, @floatFromInt(rows_len)) * @as(f64, @floatFromInt(geom.cell_h_px));
    if (y_px < top or y_px >= bottom) return null;
    const left: f64 = @floatFromInt(geom.body_x);
    if (x_px < left) return null;
    // **글자 아래**(`.cluster`)다 — 클릭의 중점 반올림(caret)을 쓰면 셀 오른쪽 절반에서 다음 글자가 잡힌다(HOVB1 실측: 1 → 2).
    const off = editor_ops.hitTestBodyMode(.cluster, term, x_px, y_px) orelse return null;
    const doc = term.rt.editor_doc orelse return null;
    if (!charAt(doc.file.content, off)) return null;
    return off;
}

/// 그 offset 에 글자가 있는가(공백·개행·문서 끝은 아니다).
fn charAt(content: []const u8, off: usize) bool {
    if (off >= content.len) return false;
    return switch (content[off]) {
        ' ', '\t', '\n', '\r' => false,
        else => true,
    };
}

const Anchor = struct { x: i32, y: i32, h: u32 };

/// 낱말 첫 글자 셀의 좌상단(창 좌표)과 높이 — 헬퍼와 같은 출처(`bodyAnchor`, 렌더가 굳힌 행 배열). 안 그려졌으면 `null`.
fn anchorFor(term: *Term, offset: usize) ?Anchor {
    const rows_len = term.rt.editor_hit_rows_len;
    if (rows_len == 0) return null;
    const doc = term.rt.editor_doc orelse return null;
    const geom = term.rt.editor_hit_geom;
    const off = @min(offset, doc.file.content.len);
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

/// 그 surface 의 편집기 Term — **보이는 자리에 있을 때만**(활성 탭·그 pane 의 앞 Term). 헬퍼의 `sendHelperTerm` 과 같은 조건.
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

fn shownTerm(self: *AppSession) ?*Term {
    if (!self.chrome_host.hover_box.open) return null;
    return visibleEditorTerm(self, self.editor_hover.shown_surface);
}

// ── 닫힘 ────────────────────────────────────────────────────────────────────────

/// **매 프레임 다시 묻는다** — 그 문서가 보이는가 · revision 이 같은가 · 그 줄이 아직 그려졌는가 · 오버레이가 없는가. 살아 있으면
/// 앵커를 이 프레임의 좌표로 갱신한다. 열려 있고 그릴 수 있으면 true.
pub fn refresh(self: *AppSession) bool {
    // `editor_signature.active` 검사는 오늘 **등가**다(적대적 3회차 C7) — 프레임 빌드가 시그니처의 refresh 를 먼저 묻고 그것이 참이면 여기 안
    // 오며, 와도 `hide` 가 같은 가드를 든다. 남기는 이유는 호출자가 하나 더 생기는 날 이 함수가 남의 상자를 옮기지 않게 하는 것이다.
    if (!self.chrome_host.hover_box.open or self.editor_signature.active) return false;
    const st = &self.editor_hover;
    const term = shownTerm(self) orelse {
        hide(self);
        return false;
    };
    if (term.rt.editor_lsp_version != st.shown_version or self.anyOverlayOpen()) {
        hide(self);
        return false;
    }
    const anchor = anchorFor(term, st.word_lo) orelse {
        hide(self);
        return false;
    };
    self.chrome_host.hover_box.anchor_x = anchor.x;
    self.chrome_host.hover_box.anchor_y = anchor.y;
    self.chrome_host.hover_box.anchor_h = anchor.h;
    return true;
}

/// 내린다(대기 중이던 요청도 잊는다). 닫혀 있었으면 다시 그리지 않는다.
pub fn hide(self: *AppSession) void {
    const st = &self.editor_hover;
    st.waiting = false;
    if (!self.chrome_host.hover_box.open or self.editor_signature.active) return; // 시그니처의 상자는 시그니처가 닫는다
    self.chrome_host.hover_box.hide();
    st.clearLines(self.allocator);
    self.metal_dirty = true;
}

/// 키가 왔다 — 수정자만이면 남고 그 밖은 닫힌다(§8.2b 「닫힘」). 키는 소비하지 않는다.
pub fn noteKey(self: *AppSession, modifier_only: bool) void {
    if (modifier_only) return;
    hide(self);
}

/// 휠 — 상자 안이면 행 단위로 스크롤하고 **소비**(true), 밖이면 닫고 흘려보낸다(false).
pub fn wheel(self: *AppSession, x_px: f64, y_px: f64, delta_y: f64) bool {
    if (!self.chrome_host.hover_box.open) return false;
    const shown = boxLines(self);
    if (!hover_box.contains(&self.chrome_host.hover_box, shown, chromeProps(self), x_px, y_px)) {
        hideOwner(self);
        return false;
    }
    const rows: i32 = if (delta_y > 0) -1 else if (delta_y < 0) 1 else 0;
    if (rows != 0 and self.chrome_host.hover_box.scrollBy(rows, shown.len)) self.metal_dirty = true;
    return true;
}

/// 버튼 눌림 — 상자 밖이면 닫는다(그 클릭은 흘러간다). 상자 안이면 삼킨다(true).
pub fn mouseDown(self: *AppSession, x_px: f64, y_px: f64) bool {
    if (!self.chrome_host.hover_box.open) return false;
    if (hover_box.contains(&self.chrome_host.hover_box, boxLines(self), chromeProps(self), x_px, y_px)) return true;
    hideOwner(self);
    return false;
}

/// 지금 상자를 든 쪽의 줄 — 시그니처가 열려 있으면 그것, 아니면 호버(§8.2d 「한 박스」).
fn boxLines(self: *const AppSession) []const hover_box.Line {
    if (self.editor_signature.active) return self.editor_signature.lines.items;
    return self.editor_hover.lines.items;
}

fn hideOwner(self: *AppSession) void {
    if (self.editor_signature.active) @import("editor_signature.zig").hide(self) else hide(self);
}

/// 그릴 줄(닫혀 있으면 빈 슬라이스).
pub fn lines(self: *const AppSession) []const hover_box.Line {
    if (!self.chrome_host.hover_box.open) return &.{};
    return self.editor_hover.lines.items;
}

pub fn deinit(self: *AppSession) void {
    self.editor_hover.deinit(self.allocator);
}
