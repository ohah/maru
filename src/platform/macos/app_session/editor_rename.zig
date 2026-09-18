//! 심볼 이름 바꾸기(docs/editor-surface-tooling.md §8.2f) — `F2`·팔레트로 caret 아래 **낱말**을 씨앗으로 인라인 rename 상자(기존
//! `RenameTarget`·`rename_input` 모달)를 낱말 첫 글자 아래 팝업으로 띄우고, `Enter` 면 `textDocument/rename` 을 보낸다. 응답의
//! `WorkspaceEdit` 는 `editor_workspace_edit.apply` 가 §8.2f 규칙으로 적용한다(전부 검증 뒤 적용·저장 정책·기록).
//!
//! 요청은 `5_000_000_000+seq` — 응답은 지금 기다리는 seq 일 때만 쓰고 낡은 것은 버린다. 서버가 없거나 `renameProvider` 가 없으면 상자를
//! 열지 않는다(무동작). `prepareRename` 은 하지 않는다 — 못 바꾸는 자리는 서버의 오류 응답을 알림으로 낸다.

const std = @import("std");
const maru = @import("maru");
const chrome = maru.chrome;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const editor_lsp = @import("editor_lsp.zig");
const editor_wse = @import("editor_workspace_edit.zig");
const pane_ops = @import("pane.zig");
const settings_ops = @import("settings.zig");
const term_ops = @import("term.zig");
const lsp = maru.session.editor.lsp;

/// 인라인 rename 의 심볼 대상 — 어느 문서의 어느 자리(낱말 시작)인가, 그리고 열 때의 revision(모달이라 바뀔 일은 없지만 대조한다).
pub const Target = struct {
    surface_id: u64,
    /// 낱말의 [start, end) byte.
    start: usize,
    end: usize,
    version: u64,
};

pub const State = struct {
    waiting: bool = false,
    waiting_seq: u32 = 0,
    /// 요청 시점의 열린 문서 revision 들(§8.2f 검증) — 응답 때 대조한다. 상한 넘는 문서는 「없음」으로 남아 편집 전일 때만 통과.
    snaps: [64]editor_wse.VersionSnap = undefined,
    snaps_len: usize = 0,
    /// 판정자 관측.
    opened_count: u64 = 0,
    sent_count: u64 = 0,
    notified_error: u64 = 0,
    notified_done: u64 = 0,
};

/// `rename_symbol` 명령·`F2`. 상자를 열었으면 true.
pub fn startAtCaret(self: *AppSession) bool {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.rt.editor_diff != null) return false;
    const doc = term.rt.editor_doc orelse return false;
    if (doc.file.read_only) return false;
    if (!editor_lsp.renameSupportedFor(self, term)) return false; // 서버가 없거나 rename 을 못 하면 상자도 없다
    const sel = term.rt.editor_selection orelse return false;
    const word = wordAt(doc.file.content, @min(sel.focus, doc.file.content.len)) orelse return false;
    const target: Target = .{ .surface_id = term.surface.id, .start = word.start, .end = word.end, .version = term.rt.editor_lsp_version };
    settings_ops.startRename(self, .{ .symbol = target }); // 씨앗은 startRename 이 `seedFor` 로 읽는다
    self.editor_rename.opened_count += 1;
    return true;
}

/// `startRename` 의 씨앗 — 낱말 그대로.
pub fn seedFor(self: *AppSession, t: Target) ?[]const u8 {
    const term = termFor(self, t.surface_id) orelse return null;
    const doc = term.rt.editor_doc orelse return null;
    if (t.end > doc.file.content.len or t.start > t.end) return null;
    return doc.file.content[t.start..t.end];
}

/// `Enter` — `commitRename` 이 부른다. 비었거나 같은 이름이면 요청 없이 닫는다; 아니면 요청을 보낸다. 상자는 어느 쪽이든 닫힌다.
pub fn commit(self: *AppSession, t: Target, new_name: []const u8) void {
    const st = &self.editor_rename;
    defer settings_ops.closeRename(self);
    if (new_name.len == 0) return;
    const term = termFor(self, t.surface_id) orelse return;
    const doc = term.rt.editor_doc orelse return;
    if (term.rt.editor_lsp_version != t.version) return; // 모달 동안 바뀔 수 없지만, 바뀌었다면 이 자리는 그 낱말이 아니다
    const old = seedFor(self, t) orelse return;
    if (std.mem.eql(u8, old, new_name)) return;
    if (doc.file.read_only) return;
    const seq = editor_lsp.requestRename(self, term, t.start, new_name) orelse return;
    st.waiting = true;
    st.waiting_seq = seq;
    st.sent_count += 1;
    snapshotVersions(self);
}

/// rename 응답(`editor_lsp` 가 부른다). 낡은 seq 는 버린다. 오류 응답은 알림(서버 message).
pub fn onResponse(self: *AppSession, seq: u32, result: ?std.json.Value, is_error: bool, error_message: ?[]const u8, enc: lsp.rpc.PositionEncoding) void {
    const st = &self.editor_rename;
    if (!st.waiting or seq != st.waiting_seq) return;
    st.waiting = false;
    if (is_error) {
        st.notified_error += 1;
        self.showNoticeFmt(.rn_error, &.{.{ .s = error_message orelse "" }});
        return;
    }
    var parsed = lsp.workspace_edit.parse(self.allocator, result) catch |err| switch (err) {
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
            st.notified_done += 1;
            self.showNoticeFmt(.rn_done, &.{.{ .d = @intCast(n) }});
        },
        .refused => |r| notifyRefusal(self, r),
    }
}

/// `undo_workspace_edit` 명령(§8.2f).
pub fn undoLast(self: *AppSession) void {
    switch (editor_wse.undoLast(self)) {
        .undone => |n| self.showNoticeFmt(.rn_undone, &.{.{ .d = @intCast(n) }}),
        .nothing => self.showNoticeKey(.rn_nothing_to_undo),
        .changed => |p| self.showNoticeFmt(.rn_undo_changed, &.{.{ .s = p }}),
        .failed => |p| self.showNoticeFmt(.rn_rejected, &.{.{ .s = p }}),
        .out_of_memory => {},
    }
}

fn notifyRefusal(self: *AppSession, r: editor_wse.Refusal) void {
    switch (r) {
        .outside_root => |p| self.showNoticeFmt(.rn_outside_root, &.{.{ .s = p }}),
        .stale => self.showNoticeKey(.rn_stale),
        .rejected => |p| self.showNoticeFmt(.rn_rejected, &.{.{ .s = p }}),
        .out_of_memory => {},
    }
}

/// 상자에 보일 글(query + 조합 중 글자) — 오버레이 프레임이 부른다.
pub fn boxText(self: *AppSession, arena: std.mem.Allocator) ![]const u8 {
    const q = self.rename_input.query.items;
    const p = self.rename_input.preedit.items;
    if (p.len == 0) return q;
    const out = try arena.alloc(u8, q.len + p.len);
    @memcpy(out[0..q.len], q);
    @memcpy(out[q.len..], p);
    return out;
}

/// 상자의 앵커(낱말 첫 글자 셀) — 프레임마다 다시 잰다(스크롤·랩이 바뀌면 자리가 바뀐다). 그 문서가 그려져 있지 않으면 null(상자는 그 프레임에 없다).
pub fn refreshAnchor(self: *AppSession, t: Target) bool {
    const term = termFor(self, t.surface_id) orelse return false;
    const rows_len = term.rt.editor_hit_rows_len;
    if (rows_len == 0) return false;
    const doc = term.rt.editor_doc orelse return false;
    const geom = term.rt.editor_hit_geom;
    const off = @min(t.start, doc.file.content.len);
    const line_idx = doc.file.lines.lineAt(off);
    const line = doc.file.lines.line(line_idx) orelse return false;
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
    ) orelse return false;
    self.chrome_host.rename_box.show(a.x_px, a.y_px, geom.cell_h_px);
    return true;
}

/// 모든 탭의 편집기 문서 revision 을 적는다 — 요청과 응답 사이에 바뀐 문서를 응답 때 가려내기 위해.
fn snapshotVersions(self: *AppSession) void {
    const st = &self.editor_rename;
    st.snaps_len = 0;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |t| {
        if (t.kind != .editor or t.rt.editor_doc == null) continue;
        if (st.snaps_len >= st.snaps.len) return;
        st.snaps[st.snaps_len] = .{ .surface_id = t.surface.id, .version = t.rt.editor_lsp_version };
        st.snaps_len += 1;
    };
}

fn termFor(self: *AppSession, surface_id: u64) ?*Term {
    const loc = term_ops.findTermWhere(self, surface_id, struct {
        fn pred(want: u64, t: *Term) bool {
            return t.kind == .editor and t.surface.id == want;
        }
    }.pred) orelse return null;
    return loc.pane.terms.items[loc.term_index];
}

pub const Word = struct { start: usize, end: usize };

/// caret 아래(또는 바로 앞) 식별자 — 글자·숫자·`_`·비ASCII. 없으면 null.
pub fn wordAt(content: []const u8, off: usize) ?Word {
    var start = off;
    var end = off;
    while (start > 0 and isIdent(content[start - 1])) start -= 1;
    while (end < content.len and isIdent(content[end])) end += 1;
    if (start == end) return null;
    return .{ .start = start, .end = end };
}

fn isIdent(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80;
}

test "RNM0 wordAt — 낱말 안·끝·앞, 비ASCII, 없음 (§8.2f)" {
    const c = "int add2(한글x, b);";
    try std.testing.expectEqual(Word{ .start = 4, .end = 8 }, wordAt(c, 5).?);
    try std.testing.expectEqual(Word{ .start = 4, .end = 8 }, wordAt(c, 8).?); // 낱말 끝(뒤 caret)
    try std.testing.expectEqual(Word{ .start = 4, .end = 8 }, wordAt(c, 4).?); // 낱말 앞
    try std.testing.expectEqual(Word{ .start = 9, .end = 16 }, wordAt(c, 12).?); // 한글x
    try std.testing.expectEqual(Word{ .start = 0, .end = 3 }, wordAt(c, 3).?); // 'int' 바로 뒤
    try std.testing.expect(wordAt("a (b)", 2) == null);
}
