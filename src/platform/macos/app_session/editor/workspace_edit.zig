//! `WorkspaceEdit` 적용 규칙(docs/editor-surface-tooling.md §8.2f) — 파일 하나의 규칙(§8.2e: 정렬·겹침 거부·revision·undo 하나·caret 보존)
//! 위에 「여러 파일」에서만 생기는 넷을 얹는다:
//! - **전부 검증 뒤 적용** — root 밖·낡은 revision·읽기 전용·겹침·읽기 실패 중 하나라도 있으면 아무것도 적용하지 않는다(반만 바뀐 rename 은
//!   컴파일되지 않는 코드다).
//! - **열려 있지 않은 파일**은 `openPath`(§3.5 — UTF-8·BOM·CRLF 보존)로 읽어 메모리에서 적용하고 저장 경로(`writeDocumentBytes`)로 쓴다.
//! - **저장** — 관련 파일이 둘 이상이면 열린 Term 도 `saveDocument` 로 저장하고, 하나면 dirty 로 둔다(VS Code `files.refactoring.autoSave`).
//! - **기록** — 성공한 적용 하나를 든다(파일마다 경로·역연산·적용 직후 내용 해시). `undoLast` 는 그 기록의 모든 파일이 아직 그 해시일 때만
//!   역연산을 같은 길로 적용한다(하나라도 다르면 전체 거부). 서버에 다시 묻지 않는다.

const std = @import("std");
const maru = @import("maru");
const app_session_mod = @import("../../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("mod.zig");
const lsp = maru.session.editor.lsp;
const delta_mod = maru.session.editor.delta;
const editor_selection = maru.session.editor.selection;
const publication = @import("shared_edit.zig");
const forward = maru.session.editor.history_forward;

pub const FileRecord = struct {
    path: []u8,
    inverse: lsp.text_edits.Changes,
    /// 적용 직후의 내용 해시(`contentHash`) — 되돌리기의 전제.
    after_hash: u64,
};

pub const Record = struct {
    files: []FileRecord,
    /// 부분 적용 뒤에도 축소 할당 없이 준비한 저장소를 인계한다.
    allocation: ?[]FileRecord = null,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        for (self.files) |*f| {
            allocator.free(f.path);
            f.inverse.deinit(allocator);
        }
        allocator.free(self.allocation orelse self.files);
        self.* = .{ .files = &.{} };
    }
};

/// 요청 시점의 열린 문서 revision(§3.6 「revision 이 어긋나면 버린다」를 여러 파일로) — 응답 때 같아야 한다.
pub const VersionSnap = struct { surface_id: u64, version: u64 };

pub const State = struct {
    last: ?Record = null,
    /// 판정자 관측.
    applied_files: u64 = 0,
    applied_edits: u64 = 0,
    saved_files: u64 = 0,
    refused_outside: u64 = 0,
    refused_stale: u64 = 0,
    refused_rejected: u64 = 0,
    undone_files: u64 = 0,
    undo_refused: u64 = 0,

    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        if (self.last) |*r| r.deinit(allocator);
        self.last = null;
    }
};

pub const Refusal = union(enum) {
    outside_root: []const u8,
    stale,
    /// 파일 연산·겹침·모양·읽기 전용·읽기/쓰기 실패 — 경로.
    rejected: []const u8,
    out_of_memory,
};

pub const Outcome = union(enum) {
    /// 적용한 파일 수(0 = 바꿀 것 없음).
    applied: usize,
    refused: Refusal,
};

/// 계획 항목 — 검증을 지나 적용을 기다리는 파일 하나. 열린 Term 들(같은 경로를 든 것 전부) 또는 디스크의 문서.
const Item = struct {
    path: []u8,
    /// 서로 다른 정본마다 본문으로 만든 변경. 같은 State의 연결 뷰는 중복하지 않는다.
    open: []OpenItem = &.{},
    disk: ?DiskItem = null,

    fn deinit(self: *Item, allocator: std.mem.Allocator) void {
        for (self.open) |*o| o.changes.deinit(allocator);
        if (self.open.len > 0) allocator.free(self.open);
        if (self.disk) |*d| {
            d.changes.deinit(allocator);
            d.opened.deinit(allocator);
        }
        allocator.free(self.path);
    }
};
const OpenItem = struct { term: *Term, changes: lsp.text_edits.Changes };
const DiskItem = struct { opened: editor_ops.Opened, changes: lsp.text_edits.Changes };

/// 파일별 `TextEdit[]`(`workspace_edit.parse` 의 결과)을 적용한다. 전부 검증 → 적용 → 저장 정책 → 기록. `expected` 는 요청 시점의 열린
/// 문서 revision — 그 뒤 바뀐 문서가 하나라도 있으면 전체 거부(요청 뒤에 열린 문서는 아직 편집되지 않았을 때만 통과).
pub fn apply(self: *AppSession, parsed: lsp.workspace_edit.Parsed, enc: lsp.rpc.PositionEncoding, expected: []const VersionSnap) Outcome {
    const st = &self.editor_workspace_edit;
    var items: std.ArrayList(Item) = .empty;
    defer {
        for (items.items) |*it| it.deinit(self.allocator);
        items.deinit(self.allocator);
    }
    // ── 검증 ──
    for (parsed.files) |f| {
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        const path = lsp.rpc.pathFromFileUri(f.uri, &path_buf) orelse {
            st.refused_rejected += 1;
            return .{ .refused = .{ .rejected = f.uri } };
        };
        if (!editor_ops.withinNavRoot(self, path)) {
            st.refused_outside += 1;
            // 알림에 실을 경로는 응답 트리 밖에서 살아야 한다 — 호출자가 곧바로 쓰므로 정적 버퍼로.
            return .{ .refused = .{ .outside_root = keepPath(path) } };
        }
        var item: Item = .{ .path = self.allocator.dupe(u8, path) catch return .{ .refused = .out_of_memory } };
        var opens: std.ArrayList(OpenItem) = .empty;
        defer {
            for (opens.items) |*o| o.changes.deinit(self.allocator);
            opens.deinit(self.allocator);
        }
        var it = TermIter{ .self = self };
        while (it.next()) |term| {
            if (term.kind != .editor or term.rt.editor_diff != null) continue;
            const doc = term.rt.editorDocument().opened orelse continue;
            const tpath = term.rt.editorDocument().path orelse continue;
            if (!std.mem.eql(u8, tpath, path)) continue;
            if (doc.file.read_only) {
                item.deinit(self.allocator);
                st.refused_rejected += 1;
                return .{ .refused = .{ .rejected = keepPath(path) } };
            }
            // §3.6 revision — 요청 때의 version 그대로여야 하고(요청 뒤에 연 문서는 아직 편집 전이어야), 응답이 version 을 들면 그것도 같아야 한다.
            const now = term.rt.editorDocument().notifications.lsp_version;
            const snap: ?u64 = for (expected) |e| {
                if (e.surface_id == term.surface.id) break e.version;
            } else null;
            const stale = (if (snap) |v| v != now else now > 1) or (f.version != null and f.version.? != @as(i64, @intCast(now)));
            if (stale) {
                item.deinit(self.allocator);
                st.refused_stale += 1;
                return .{ .refused = .stale };
            }
            // 연결된 뷰는 모두 stale 검증하지만 정본에는 한 번만 적용한다.
            const already_prepared = for (opens.items) |open| {
                if (open.term.rt.editorDocument() == term.rt.editorDocument()) break true;
            } else false;
            if (already_prepared) continue;
            const changes = lsp.text_edits.toChanges(self.allocator, .{ .array = .{ .items = f.edits, .capacity = f.edits.len, .allocator = self.allocator } }, doc.file.content, doc.file.lines, enc) catch |err| {
                item.deinit(self.allocator);
                if (err == error.OutOfMemory) return .{ .refused = .out_of_memory };
                st.refused_rejected += 1;
                return .{ .refused = .{ .rejected = keepPath(path) } };
            };
            opens.append(self.allocator, .{ .term = term, .changes = changes }) catch {
                var c = changes;
                c.deinit(self.allocator);
                item.deinit(self.allocator);
                return .{ .refused = .out_of_memory };
            };
        }
        if (opens.items.len > 0) {
            item.open = opens.toOwnedSlice(self.allocator) catch {
                item.deinit(self.allocator);
                return .{ .refused = .out_of_memory };
            };
        } else {
            var opened = editor_ops.openPath(self.io, self.allocator, path) catch |err| {
                item.deinit(self.allocator);
                if (err == error.OutOfMemory) return .{ .refused = .out_of_memory };
                st.refused_rejected += 1;
                return .{ .refused = .{ .rejected = keepPath(path) } };
            };
            if (opened.file.read_only) {
                opened.deinit(self.allocator);
                item.deinit(self.allocator);
                st.refused_rejected += 1;
                return .{ .refused = .{ .rejected = keepPath(path) } };
            }
            const changes = lsp.text_edits.toChanges(self.allocator, .{ .array = .{ .items = f.edits, .capacity = f.edits.len, .allocator = self.allocator } }, opened.file.content, opened.file.lines, enc) catch |err| {
                opened.deinit(self.allocator);
                item.deinit(self.allocator);
                if (err == error.OutOfMemory) return .{ .refused = .out_of_memory };
                st.refused_rejected += 1;
                return .{ .refused = .{ .rejected = keepPath(path) } };
            };
            item.disk = .{ .opened = opened, .changes = changes };
        }
        items.append(self.allocator, item) catch {
            item.deinit(self.allocator);
            return .{ .refused = .out_of_memory };
        };
    }
    return applyPlan(self, items.items);
}

// 선택·이력·공유 뷰 게시 자원까지 준비한다. L2 forward가 본문과 Undo를 준비하며,
// 이 배선은 기존 단일 문서 Undo 계약을 유지한다(연결된 작업을 새로 만들지 않는다).
const PreparedOpen = struct {
    session: *AppSession,
    term: *Term,
    changes: lsp.text_edits.Changes,
    sels: editor_selection.Selections = undefined,
    have_sels: bool = false,
    model: ?forward.Prepared = null,
    view: ?publication.Publication = null,
    no_selection: bool,
    scroll: ?editor_ops.ScrollAnchor,
    rows: usize,
    cols: u16,
    max_cols: u32,
    span: ?editor_ops.syntax_color.EditSpan = null,

    fn prepare(self: *PreparedOpen) !void {
        const a = self.session.allocator;
        self.sels = editor_ops.snapshotSelections(a, self.term) catch |err| blk: {
            if (err != error.NoSelection) return err;
            break :blk editor_selection.Selections.init(try a.dupe(editor_selection.Selection, &.{editor_selection.Selection.at(0)}), 0);
        };
        self.have_sels = true;
        const state = self.term.rt.editorDocument();
        const targets = [_]forward.Target{.{ .file = &state.opened.?.file, .state = &state.history, .selections = &self.sels, .changes = self.changes.items, .view_id = self.term.surface.id }};
        self.model = try forward.Prepared.prepareIncludingUnchanged(a, &targets);
        self.span = editor_ops.syntax_color.spanFromInverse(self.model.?.items.items[0].entry.inverse.changes);
        self.view = try publication.preparePublication(self.session, self.term, self.changes.delta(), self.sels.items.len, true);
    }
    fn deinit(self: *PreparedOpen) void {
        if (self.view) |*view| view.deinit();
        if (self.model) |*model| model.deinit();
        if (self.have_sels) self.session.allocator.free(self.sels.items);
    }
    fn commit(self: *PreparedOpen) !void {
        try self.model.?.commit();
        self.view.?.publish();
        editor_ops.completion_client.noteDocumentEdit(self.session, self.term, self.changes.delta());
        editor_ops.writeBackSelections(self.session, self.term, self.sels);
        if (self.no_selection) self.term.rt.editor_selection = null;
        self.view.?.finish(self.span);
        editor_ops.refreshAfterEdit(self.session, self.term, self.span) catch {};
        editor_ops.restoreScrollAnchor(self.session, self.term, self.scroll, self.changes.delta());
        editor_ops.revealPrimaryCaretRows(self.session, self.term, self.rows);
        editor_ops.revealPrimaryCaretCols(self.session, self.term, self.cols, self.max_cols);
        self.session.metal_dirty = true;
    }
};
const PreparedFile = struct {
    open: []PreparedOpen = &.{},
    initialized: usize = 0,
    bytes: ?[]u8 = null,
    record: ?FileRecord = null,
    fn deinit(self: *PreparedFile, a: std.mem.Allocator) void {
        for (self.open[0..self.initialized]) |*o| o.deinit();
        a.free(self.open);
        if (self.bytes) |bytes| a.free(bytes);
        if (self.record) |*r| {
            a.free(r.path);
            r.inverse.deinit(a);
        }
    }
};
/// 준비 실패는 모든 정본과 기존 기록을 보존한다. 디스크 쓰기 실패는 기존 정책대로
/// 그때까지 적용한 파일만 기록하여 되돌릴 수 있게 한다.
fn applyPlan(self: *AppSession, items: []Item) Outcome {
    return applyPreparedPlan(self, items) catch |err| {
        if (err == error.OutOfMemory) return .{ .refused = .out_of_memory };
        self.editor_workspace_edit.refused_rejected += 1;
        return .{ .refused = .{ .rejected = keepPath(if (items.len > 0) items[0].path else "") } };
    };
}
fn applyPreparedPlan(self: *AppSession, items: []Item) !Outcome {
    const a = self.allocator;
    const st = &self.editor_workspace_edit;
    const prepared = try a.alloc(PreparedFile, items.len);
    defer a.free(prepared);
    @memset(prepared, .{});
    defer for (prepared) |*p| p.deinit(a);
    var records: std.ArrayList(FileRecord) = .empty;
    defer {
        for (records.items) |*r| {
            a.free(r.path);
            r.inverse.deinit(a);
        }
        records.deinit(a);
    }
    try records.ensureTotalCapacity(a, items.len);
    // 반영 전에 파일 내용·Undo·뷰 게시·디스크 bytes·경로/역연산 기록을 전부 준비한다.
    for (items, prepared) |*item, *p| {
        p.open = try a.alloc(PreparedOpen, item.open.len);
        for (item.open) |o| {
            if (o.changes.items.len == 0) continue;
            const slot = &p.open[p.initialized];
            slot.* = .{ .session = self, .term = o.term, .changes = o.changes, .no_selection = editor_ops.selections(o.term).count() == 0, .scroll = editor_ops.captureScrollAnchor(o.term), .rows = editor_ops.drawnDocLines(o.term), .cols = editor_ops.drawnContentCols(o.term), .max_cols = o.term.rt.editor_max_cols };
            p.initialized += 1;
            try slot.prepare();
        }
        const record_changes = if (p.initialized > 0) p.open[p.initialized - 1].changes else if (item.disk) |d| d.changes else continue;
        if (record_changes.items.len == 0) continue;
        const before = if (p.initialized > 0) p.open[p.initialized - 1].term.rt.editorDocument().opened.?.file.content else item.disk.?.opened.file.content;
        var inv = try lsp.text_edits.inverseOf(a, before, record_changes.items);
        errdefer inv.deinit(a);
        const path = try a.dupe(u8, item.path);
        p.record = .{ .path = path, .inverse = inv, .after_hash = 0 };
        // 이후 실패 정리는 PreparedFile이 소유한다.
        inv = .{};
        if (item.disk) |*d| {
            var sel_items = [_]editor_selection.Selection{editor_selection.Selection.at(0)};
            var sels = editor_selection.Selections.init(&sel_items, 0);
            var inverse = try d.opened.file.apply(d.changes.delta(), &sels);
            inverse.deinit();
            p.bytes = try d.opened.file.saveBytes(a);
            p.record.?.after_hash = editor_ops.contentHash(d.opened.file.content);
        } else {
            p.record.?.after_hash = editor_ops.contentHash(p.open[p.initialized - 1].model.?.items.items[0].next.content);
        }
    }
    // URI 철자가 달라도 같은 정본을 가리킬 수 있다. 뒤쪽 결산에서 낡음을
    // 발견하기 전에 중립 코어의 중복 검사를 전체 대상에 적용한다.
    var targets: std.ArrayList(forward.Target) = .empty;
    defer targets.deinit(a);
    for (prepared) |*p| for (p.open[0..p.initialized]) |*o| {
        try targets.append(a, o.model.?.items.items[0].target);
    };
    try forward.validateDistinct(targets.items);
    var edits_total: usize = 0;
    var failed_write: ?[]const u8 = null;
    // 준비와 결산은 같은 actor에서 진행한다. 본문·이력 교체에는 할당이 없다.
    for (items, prepared) |*item, *p| {
        if (p.record == null) continue;
        for (p.open[0..p.initialized]) |*o| {
            try o.commit();
            edits_total += o.changes.items.len;
        }
        if (p.bytes) |bytes| {
            editor_ops.writeDocumentBytes(self, item.path, bytes, null) catch {
                failed_write = keepPath(item.path);
                break;
            };
            st.saved_files += 1;
            edits_total += item.disk.?.changes.items.len;
        }
        records.appendAssumeCapacity(p.record.?);
        p.record = null;
    }
    const touched = records.items.len;
    // 기존 여러 파일 자동 저장 정책은 유지한다. 저장 실패는 dirty 문서와 Undo를 남긴다.
    if (touched > 1) for (items, prepared) |*item, *p| {
        if (p.record != null) continue; // 쓰기 실패 뒤 아직 적용하지 않은 문서는 저장하지 않는다.
        for (item.open) |o| {
            if (o.changes.items.len == 0 or o.term.rt.editorDocument().remote != null) continue;
            if (editor_ops.isDirty(o.term)) {
                if (editor_ops.saveDocument(self, o.term)) |_| {
                    st.saved_files += 1;
                } else |_| {}
            }
        }
    };
    if (touched > 0 or failed_write == null) {
        if (st.last) |*old| old.deinit(a);
        st.last = if (touched > 0) .{ .files = records.items, .allocation = records.allocatedSlice() } else null;
        if (touched > 0) records = .empty;
    }
    st.applied_files += touched;
    st.applied_edits += edits_total;
    if (failed_write) |path| {
        st.refused_rejected += 1;
        return .{ .refused = .{ .rejected = path } };
    }
    return .{ .applied = touched };
}

/// 마지막 기록을 되돌린다(§8.2f `undo_workspace_edit`). 모든 파일이 아직 기록의 해시여야 한다 — 하나라도 다르면 전체 거부.
pub const UndoOutcome = union(enum) {
    undone: usize,
    nothing,
    changed: []const u8,
    failed: []const u8,
    out_of_memory,
};

pub fn undoLast(self: *AppSession) UndoOutcome {
    const st = &self.editor_workspace_edit;
    const rec = st.last orelse return .nothing;
    var items: std.ArrayList(Item) = .empty;
    defer {
        for (items.items) |*it| it.deinit(self.allocator);
        items.deinit(self.allocator);
    }
    for (rec.files) |f| {
        var item: Item = .{ .path = self.allocator.dupe(u8, f.path) catch return .out_of_memory };
        var opens: std.ArrayList(OpenItem) = .empty;
        defer {
            for (opens.items) |*o| o.changes.deinit(self.allocator);
            opens.deinit(self.allocator);
        }
        var it = TermIter{ .self = self };
        while (it.next()) |term| {
            if (term.kind != .editor or term.rt.editor_diff != null) continue;
            const doc = term.rt.editorDocument().opened orelse continue;
            const tpath = term.rt.editorDocument().path orelse continue;
            if (!std.mem.eql(u8, tpath, f.path)) continue;
            if (doc.file.read_only or editor_ops.contentHash(doc.file.content) != f.after_hash) {
                item.deinit(self.allocator);
                st.undo_refused += 1;
                return .{ .changed = keepPath(f.path) };
            }
            const already_prepared = for (opens.items) |open| {
                if (open.term.rt.editorDocument() == term.rt.editorDocument()) break true;
            } else false;
            if (already_prepared) continue;
            const changes = dupChanges(self.allocator, f.inverse) catch {
                item.deinit(self.allocator);
                return .out_of_memory;
            };
            opens.append(self.allocator, .{ .term = term, .changes = changes }) catch {
                var c = changes;
                c.deinit(self.allocator);
                item.deinit(self.allocator);
                return .out_of_memory;
            };
        }
        if (opens.items.len > 0) {
            item.open = opens.toOwnedSlice(self.allocator) catch {
                item.deinit(self.allocator);
                return .out_of_memory;
            };
        } else {
            var opened = editor_ops.openPath(self.io, self.allocator, f.path) catch |err| {
                item.deinit(self.allocator);
                if (err == error.OutOfMemory) return .out_of_memory;
                st.undo_refused += 1;
                return .{ .failed = keepPath(f.path) };
            };
            if (opened.file.read_only or editor_ops.contentHash(opened.file.content) != f.after_hash) {
                opened.deinit(self.allocator);
                item.deinit(self.allocator);
                st.undo_refused += 1;
                return .{ .changed = keepPath(f.path) };
            }
            const changes = dupChanges(self.allocator, f.inverse) catch {
                opened.deinit(self.allocator);
                item.deinit(self.allocator);
                return .out_of_memory;
            };
            item.disk = .{ .opened = opened, .changes = changes };
        }
        items.append(self.allocator, item) catch {
            item.deinit(self.allocator);
            return .out_of_memory;
        };
    }
    // 적용은 같은 길 — 성공하면 기록이 갈아 끼워지는데(되감은 것의 역연산 = 원래 rename), 첫 조각은 redo 를 두지 않으므로 비운다.
    const outcome = applyPlan(self, items.items);
    switch (outcome) {
        .applied => |n| {
            if (st.last) |*r| r.deinit(self.allocator);
            st.last = null;
            st.undone_files += n;
            return .{ .undone = n };
        },
        .refused => |r| switch (r) {
            .out_of_memory => return .out_of_memory,
            .rejected => |p| return .{ .failed = p },
            else => return .{ .failed = keepPath(rec.files[0].path) },
        },
    }
}

/// 모든 탭·pane 의 Term 을 차례로 — 같은 경로를 든 Term 이 어느 탭에 있든 찾는다(포맷의 「문서에 적용」과 같은 규율).
const TermIter = struct {
    self: *AppSession,
    ti: usize = 0,
    pi: usize = 0,
    ki: usize = 0,

    fn next(it: *TermIter) ?*Term {
        while (it.ti < it.self.tabs.items.len) {
            const tab = it.self.tabs.items[it.ti];
            while (it.pi < tab.panes.items.len) {
                const pane = tab.panes.items[it.pi];
                if (it.ki < pane.terms.items.len) {
                    const t = pane.terms.items[it.ki];
                    it.ki += 1;
                    return t;
                }
                it.pi += 1;
                it.ki = 0;
            }
            it.ti += 1;
            it.pi = 0;
            it.ki = 0;
        }
        return null;
    }
};

fn dupChanges(allocator: std.mem.Allocator, src: lsp.text_edits.Changes) error{OutOfMemory}!lsp.text_edits.Changes {
    if (src.items.len == 0) return .{};
    var texts = try allocator.alloc([]u8, src.items.len);
    var owned: usize = 0;
    errdefer {
        for (texts[0..owned]) |t| allocator.free(t);
        allocator.free(texts);
    }
    for (src.items) |c| {
        texts[owned] = try allocator.dupe(u8, c.text);
        owned += 1;
    }
    const items = try allocator.alloc(delta_mod.Change, src.items.len);
    for (src.items, 0..) |c, i| items[i] = .{ .start = c.start, .end = c.end, .text = texts[i] };
    return .{ .items = items, .texts = texts };
}

/// 알림용 경로 — 응답 트리·계획이 사라진 뒤에도 살도록 정적 버퍼에 복사한다(알림은 곧바로 낸다).
var notice_path_buf: [std.fs.max_path_bytes]u8 = undefined;
fn keepPath(path: []const u8) []const u8 {
    const n = @min(path.len, notice_path_buf.len);
    @memcpy(notice_path_buf[0..n], path[0..n]);
    return notice_path_buf[0..n];
}
