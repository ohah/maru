//! 같은 창의 연결된 에디터 뷰에 본문·줄·좌표를 게시하는 host coordinator.
//! 할당 가능한 준비를 정본 변경 앞으로 모으고 게시 자체는 할당하지 않는다.
const std = @import("std");
const maru = @import("maru");
const app_session = @import("../../app_session.zig");
const AppSession = app_session.AppSession;
const Term = app_session.Term;
const editor_ops = @import("mod.zig");
const editor_selection = maru.session.editor.selection;
const shared_policy = maru.session.editor.shared_edit;
const syntax_color = editor_ops.syntax_color;

// 정본 변경 전 연결 뷰의 줄 저장소를 모두 준비한다. 단일 뷰는 기존 빠른 경로를 유지한다.
// 현재 일반 UI는 두 view를 연결하지 않는다. cross-window/provider/IME 배선은 후속 단계다.
const SharedPreparedView = struct {
    term: *Term,
    lines: [][]const u8,
    scroll: ?editor_ops.ScrollAnchor,
    first_piece: u32,
    primary: ?editor_selection.Selection,
    extras: []editor_selection.Selection,
};

pub fn apply(self: *AppSession, term: *Term, d: maru.session.editor.delta.Delta, sels: *editor_selection.Selections) !maru.session.editor.delta.Inverse {
    const revision = (term.rt.editorDocument().opened orelse return error.DocumentNotOpen).file.revision;
    return applyAtRevision(self, term, d, sels, revision);
}

// 일반 타이핑은 같은 메인 스레드 사건 안에서 현재 revision을 넘긴다. 준비한 요청은 기준을 검증한다.
pub fn applyAtRevision(self: *AppSession, term: *Term, d: maru.session.editor.delta.Delta, sels: *editor_selection.Selections, base_revision: u64) !maru.session.editor.delta.Inverse {
    const state = term.rt.editorDocument();
    const opened = state.opened orelse return error.DocumentNotOpen;
    if (opened.file.revision != base_revision) return error.StaleRevision;
    if (opened.file.read_only) return error.ReadOnly;
    // Accepted edits survive a later history recording OOM; pushUndo clears old offsets.
    return applyPrepared(self, term, d, sels, sels.items.len);
}

pub fn applyPrepared(
    self: *AppSession,
    term: *Term,
    d: maru.session.editor.delta.Delta,
    sels: *editor_selection.Selections,
    result_selection_count: usize,
) !maru.session.editor.delta.Inverse {
    const state = term.rt.editorDocument();
    const file = &(state.opened orelse return error.DocumentNotOpen).file;
    const lease = term.rt.editor_document_lease orelse return state.opened.?.file.apply(d, sels);
    const count = lease.owner.viewCount(lease) orelse return error.DocumentNotRegistered;
    if (count <= 1) return state.opened.?.file.apply(d, sels);
    if (file.read_only) return error.ReadOnly;
    if (!d.isWellFormed()) return error.MalformedDelta;
    if (d.changes.len > 0 and d.changes[d.changes.len - 1].end > file.content.len) return error.OutOfRange;
    var line_count = file.lineCount();
    for (d.changes) |c| {
        line_count -= std.mem.count(u8, file.content[c.start..c.end], "\n");
        line_count += std.mem.count(u8, c.text, "\n");
    }
    const prepared = try self.allocator.alloc(SharedPreparedView, count);
    defer self.allocator.free(prepared);
    var n: usize = 0;
    var published = false;
    defer if (!published) {
        for (prepared[0..n]) |v| {
            self.allocator.free(v.lines);
            self.allocator.free(v.extras);
        }
    };
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |view| {
        if (view.kind != .editor or view.rt.editorDocument() != state) continue;
        if (n == count) return error.SharedViewCountMismatch;
        if (view != term and (view.rt.editor_preedit.len > 0 or (self.ime_editor_commit_pending and self.ime_terminal_target_id == view.surface.id))) return error.SharedCompositionBusy;
        const lines = try self.allocator.alloc([]const u8, line_count);
        errdefer self.allocator.free(lines);
        var primary = view.rt.editor_selection;
        var extras: []editor_selection.Selection = undefined;
        if (view == term) {
            extras = try self.allocator.alloc(editor_selection.Selection, result_selection_count -| 1);
        } else if (primary) |sel| {
            // 매핑으로 서로 겹친 선택도 정본 변경 전에 합친다. primary 소유는 유지한다.
            const mapped = try self.allocator.alloc(editor_selection.Selection, view.rt.editor_extra_selections.len + 1);
            defer self.allocator.free(mapped);
            mapped[0] = shared_policy.mapSelection(d, sel);
            for (view.rt.editor_extra_selections, 1..) |extra, i| mapped[i] = shared_policy.mapSelection(d, extra);
            const merged = editor_selection.mergeOverlapping(mapped, 0);
            primary = mapped[merged.primary];
            extras = try self.allocator.alloc(editor_selection.Selection, merged.len - 1);
            var k: usize = 0;
            for (mapped[0..merged.len], 0..) |item, i| {
                if (i == merged.primary) continue;
                extras[k] = item;
                k += 1;
            }
        } else {
            extras = try self.allocator.alloc(editor_selection.Selection, 0);
        }
        prepared[n] = .{ .term = view, .lines = lines, .scroll = editor_ops.captureScrollAnchor(view), .first_piece = view.rt.editor_first_piece, .primary = primary, .extras = extras };
        n += 1;
    };
    // 다른 창의 view는 아직 이 coordinator에 연결하지 않았다. 부분 게시로 넘기지 않는다.
    if (n != count) return error.SharedViewCountMismatch;
    const before = try self.allocator.dupe(editor_selection.Selection, sels.items);
    defer self.allocator.free(before);
    const before_state = sels.*;
    const inverse = state.opened.?.file.apply(d, sels) catch |err| {
        @memcpy(sels.items, before);
        sels.* = before_state;
        return err;
    };
    // 여기부터 줄 배열과 offset의 게시에는 할당이 없다. 옛 본문을 빌린 배열은 모두 갈아 끼운다.
    for (prepared) |v| {
        for (0..line_count) |i| v.lines[i] = state.opened.?.file.lineText(i) orelse "";
        if (v.term.rt.editor_lines.len > 0) self.allocator.free(v.term.rt.editor_lines);
        v.term.rt.editor_lines = v.lines;
        v.term.rt.editor_shared_lines_ready = true;
        if (v.term == term) {
            if (term.rt.editor_shared_selection_buf) |buf| self.allocator.free(buf);
            term.rt.editor_shared_selection_buf = v.extras;
            continue;
        }
        v.term.rt.editor_selection = v.primary;
        if (v.term.rt.editor_extra_selections.len > 0) self.allocator.free(v.term.rt.editor_extra_selections);
        v.term.rt.editor_extra_selections = v.extras;
        v.term.rt.editor_column_anchor = null;
        if (v.term.rt.editor_auto_closed_at) |at| {
            v.term.rt.editor_auto_closed_at = shared_policy.mapAutoClose(d, at);
        }
    }
    published = true;
    const span = syntax_color.spanFromInverse(inverse.changes);
    for (prepared) |v| {
        if (v.term == term) continue;
        editor_ops.refreshAfterEdit(self, v.term, span) catch {};
        // 다른 뷰는 같은 위치 삽입도 원래 보던 텍스트를 anchor로 유지한다.
        const mapped_scroll: ?editor_ops.ScrollAnchor = if (v.scroll) |a| .{
            .off = shared_policy.mapSelection(d, editor_selection.Selection.at(a.off)).focus,
        } else null;
        editor_ops.restoreScrollAnchor(self, v.term, mapped_scroll, .{ .changes = &.{} });
        v.term.rt.editor_first_piece = v.first_piece;
    }
    return inverse;
}
