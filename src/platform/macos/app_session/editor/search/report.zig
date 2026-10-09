//! 검색 탭은 원문 문서가 아니라 소유한 결과 snapshot이다. 저장·복구 신원은 만들지 않는다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const editor = @import("../mod.zig");
const owner = @import("owner.zig");
const navigation = @import("navigation.zig");
const pane = @import("../../pane.zig");
const search = maru.session.editor.search;
pub const Report = struct {
    title: []u8,
    query: owner.Query,
    identity: search.request.Identity,
    roots: std.ArrayList(Root) = .empty,
    hits: std.ArrayList(Hit) = .empty,
    rows: std.ArrayList(search.request.Row) = .empty,
    const Root = struct { path: []u8, device: u64, inode: u64 };
    const Hit = struct { line: usize, row: usize, range: usize };
    pub fn destroy(self: *Report, a: std.mem.Allocator) void {
        a.free(self.title);
        self.query.deinit(a);
        for (self.roots.items) |root| a.free(root.path);
        self.roots.deinit(a);
        for (self.rows.items) |*row| row.match.deinit(a);
        self.rows.deinit(a);
        self.hits.deinit(a);
        a.destroy(self);
    }
};
fn clone(a: std.mem.Allocator, row: search.request.Row) !search.request.Row {
    var result = row;
    result.match.path = try a.dupe(u8, row.match.path);
    errdefer a.free(result.match.path);
    result.match.text = try a.dupe(u8, row.match.text);
    errdefer a.free(result.match.text);
    result.match.ranges = try a.dupe(search.event.Range, row.match.ranges);
    return result;
}
/// 모든 준비가 성공한 뒤 한 번만 게시한다. 실패한 결과 열기가 빈 탭을 남기지 않는다.
pub fn open(self: *host.AppSession) !*host.Term {
    if (self.ime_active or self.ime_editor_commit_pending) return error.InputTransactionPending;
    const state = &self.editor_search;
    if (state.stamp == null or state.stamp.? != owner.fingerprint(self) or state.result.phase != .complete) return error.StaleRequest;
    const previewing = state.preview.active();
    if (previewing and state.preview.phase != .ready) return error.StaleRequest;
    const original = self.editor_project_search_query orelse return error.StaleRequest;
    const a = self.allocator;
    const report = try a.create(Report);
    errdefer a.destroy(report);
    const title = try std.fmt.allocPrint(a, "{s}: {s}", .{ if (previewing) maru.i18n.t(.project_replace_preview) else maru.i18n.t(.project_search_pane_title), original.text });
    errdefer a.free(title);
    var query = try owner.Query.init(a, original.root_index, original.text, original.options, original.limits, original.budget);
    errdefer query.deinit(a);
    if (original.helper_for_test) |helper| query.helper_for_test = try a.dupe(u8, helper);
    query.all_roots = original.all_roots;
    report.* = .{ .title = title, .query = query, .identity = state.result.identity orelse return error.StaleRequest };
    // title/query는 아래 aggregate cleanup이 소유한다. 실패 시 중복 정산하지 않도록 별도 범위를 둔다.
    var roots: std.ArrayList(Report.Root) = .empty;
    defer {
        for (roots.items) |root| a.free(root.path);
        roots.deinit(a);
    }
    for (0..self.file_tree.rootCount()) |index| {
        const path = self.file_tree.rootAt(index).?;
        const cap = self.file_tree.rootCapabilityForPath(path) orelse return error.StaleRequest;
        const copied = try a.dupe(u8, path);
        errdefer a.free(copied);
        try roots.append(a, .{ .path = copied, .device = cap.identity.device, .inode = cap.identity.inode });
    }
    var rows: std.ArrayList(search.request.Row) = .empty;
    defer {
        for (rows.items) |*row| row.match.deinit(a);
        rows.deinit(a);
    }
    var hits: std.ArrayList(Report.Hit) = .empty;
    defer {
        hits.deinit(a);
    }
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendSlice(a, title);
    try bytes.appendSlice(a, "\n");
    if (!previewing) try bytes.appendSlice(a, maru.i18n.t(.project_search_pane_hint));
    try bytes.appendSlice(a, "\n\n");
    var line: usize = std.mem.count(u8, bytes.items, "\n");
    if (previewing) {
        const plan = state.preview.plan orelse return error.StaleRequest;
        for (plan.rows.items) |row| {
            const heading = try std.fmt.allocPrint(a, "{s} {d}: ", .{ if (row.kind == .added) "+" else if (row.kind == .removed) "-" else " ", row.line });
            defer a.free(heading);
            try bytes.appendSlice(a, heading);
            try bytes.appendSlice(a, row.text);
            if (!std.mem.endsWith(u8, row.text, "\n")) try bytes.appendSlice(a, "\n");
            if (bytes.items.len > editor.read_limit_bytes) return error.TooLarge;
        }
    } else for (state.result.model.rows.items) |row| {
        const row_index = rows.items.len;
        {
            const owned = try clone(a, row);
            errdefer {
                var failed = owned;
                failed.match.deinit(a);
            }
            try rows.append(a, owned);
        }
        for (row.match.ranges, 0..) |range, range_index| {
            const heading = try std.fmt.allocPrint(a, "[{d}] {s}:{d}:{d}\n", .{ row.root_index + 1, row.match.path, range.start.line + 1, range.start.byte + 1 });
            defer a.free(heading);
            // 파일 이름의 줄바꿈도 화면 구조를 바꾸지 않게 정리한다. 원래 경로는 hit가 보관한다.
            for (heading[0 .. heading.len - 1]) |*byte| if (byte.* < 0x20) {
                byte.* = ' ';
            };
            try hits.append(a, .{ .line = line, .row = row_index, .range = range_index });
            try bytes.appendSlice(a, heading);
            try bytes.appendSlice(a, row.match.text);
            if (row.match.text_truncated) try bytes.appendSlice(a, "…");
            try bytes.appendSlice(a, "\n\n");
            if (bytes.items.len > editor.read_limit_bytes) return error.TooLarge;
            line += 1 + std.mem.count(u8, row.match.text, "\n") + 2;
        }
    }
    var prepared = try editor.prepareSearchReport(self, bytes.items);
    errdefer prepared.deinit(a);
    const term = try editor.createEditorTerm(self);
    errdefer @import("../../term.zig").destroyTerm(self, term);
    const active_pane = pane.activePane(self);
    try active_pane.terms.append(a, term);
    // 이 아래에는 실패 지점이 없다.
    report.roots = roots;
    roots = .empty;
    report.rows = rows;
    rows = .empty;
    report.hits = hits;
    hits = .empty;
    editor.finishAttach(self, term, prepared);
    term.rt.editor_search_report = report;
    term.rt.editor_selection = maru.session.editor.selection.Selection.at(0);
    state.focused = null;
    self.focusTerm(active_pane.terms.items.len - 1);
    self.metal_dirty = true;
    return term;
}
pub fn activate(self: *host.AppSession, term: *host.Term) !void {
    if (self.ime_active or self.ime_editor_commit_pending or term.rt.editor_preedit.len > 0) return error.InputTransactionPending;
    const report = term.rt.editor_search_report orelse return;
    const doc = term.rt.editorDocument().opened orelse return error.NoDocument;
    const selection = term.rt.editor_selection orelse return;
    const line = doc.file.lines.lineAt(@min(selection.focus, doc.file.content.len));
    // 빈 행이나 설명 행의 Enter가 바로 앞 결과를 여는 일은 없다.
    for (report.hits.items) |hit| {
        const row = report.rows.items[hit.row];
        const last = hit.line + 1 + std.mem.count(u8, row.match.text, "\n") - @intFromBool(std.mem.endsWith(u8, row.match.text, "\n"));
        if (line < hit.line or line > last) continue;
        const root = report.roots.items[row.root_index];
        const current = self.file_tree.rootAt(row.root_index) orelse return error.StaleRequest;
        if (!std.mem.eql(u8, current, root.path)) return error.StaleRequest;
        const cap = self.file_tree.rootCapabilityForPath(current) orelse return error.StaleRequest;
        if (cap.identity.device != root.device or cap.identity.inode != root.inode) return error.StaleRequest;
        try navigation.startRow(self, row, hit.range, report.query, report.identity, null);
        if (self.editor_search.nav) |*ticket| ticket.origin_surface = term.surfaceId();
        return;
    }
}
