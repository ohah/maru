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
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const Term = app_session_mod.Term;
const editor_ops = @import("editor.zig");
const lsp = maru.session.editor.lsp;
const delta_mod = maru.session.editor.delta;
const editor_selection = maru.session.editor.selection;

pub const FileRecord = struct {
    path: []u8,
    inverse: lsp.text_edits.Changes,
    /// 적용 직후의 내용 해시(`contentHash`) — 되돌리기의 전제.
    after_hash: u64,
};

pub const Record = struct {
    files: []FileRecord,

    pub fn deinit(self: *Record, allocator: std.mem.Allocator) void {
        for (self.files) |*f| {
            allocator.free(f.path);
            f.inverse.deinit(allocator);
        }
        allocator.free(self.files);
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
    /// 열린 Term 마다 그 Term 의 본문으로 만든 변경.
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
        errdefer item.deinit(self.allocator);
        var opens: std.ArrayList(OpenItem) = .empty;
        defer opens.deinit(self.allocator);
        var it = TermIter{ .self = self };
        while (it.next()) |term| {
            if (term.kind != .editor or term.rt.editor_diff != null) continue;
            const doc = term.rt.editor_doc orelse continue;
            const tpath = term.rt.editor_path orelse continue;
            if (!std.mem.eql(u8, tpath, path)) continue;
            if (doc.file.read_only) {
                item.deinit(self.allocator);
                st.refused_rejected += 1;
                return .{ .refused = .{ .rejected = keepPath(path) } };
            }
            // §3.6 revision — 요청 때의 version 그대로여야 하고(요청 뒤에 연 문서는 아직 편집 전이어야), 응답이 version 을 들면 그것도 같아야 한다.
            const now = term.rt.editor_lsp_version;
            const snap: ?u64 = for (expected) |e| {
                if (e.surface_id == term.surface.id) break e.version;
            } else null;
            const stale = (if (snap) |v| v != now else now > 1) or (f.version != null and f.version.? != @as(i64, @intCast(now)));
            if (stale) {
                item.deinit(self.allocator);
                st.refused_stale += 1;
                return .{ .refused = .stale };
            }
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
                for (opens.items) |*o| o.changes.deinit(self.allocator);
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

/// 검증을 지난 계획을 적용한다(`apply` 와 `undoLast` 가 같이 쓴다). 열린 Term 은 `applyEditAsOne`(undo 하나), 디스크는 메모리 적용 → 쓰기.
/// 그 뒤 저장 정책과 기록. 디스크 쓰기가 중간에 실패하면 거기서 멈추고 그때까지의 것을 기록한다(되돌릴 수 있게).
fn applyPlan(self: *AppSession, items: []Item) Outcome {
    const st = &self.editor_workspace_edit;
    var records: std.ArrayList(FileRecord) = .empty;
    errdefer {
        for (records.items) |*r| {
            self.allocator.free(r.path);
            r.inverse.deinit(self.allocator);
        }
        records.deinit(self.allocator);
    }
    var edits_total: usize = 0;
    var touched: usize = 0;
    var failed_write: ?[]const u8 = null;
    for (items) |*item| {
        var any = false;
        var inverse: ?lsp.text_edits.Changes = null;
        var after_hash: u64 = 0;
        for (item.open) |o| {
            if (o.changes.items.len == 0) continue;
            const doc = o.term.rt.editor_doc.?;
            const inv = lsp.text_edits.inverseOf(self.allocator, doc.file.content, o.changes.items) catch return .{ .refused = .out_of_memory };
            if (!editor_ops.applyEditAsOne(self, o.term, o.changes.items)) {
                var i = inv;
                i.deinit(self.allocator);
                continue;
            }
            any = true;
            edits_total += o.changes.items.len;
            // 같은 경로를 든 Term 이 여럿이면 기록은 하나(내용이 같아야 되돌릴 수 있다 — 첫 것 기준).
            if (inverse) |*old| {
                old.deinit(self.allocator);
            }
            inverse = inv;
            after_hash = editor_ops.contentHash(o.term.rt.editor_doc.?.file.content);
        }
        if (item.disk) |*d| {
            if (d.changes.items.len > 0) {
                const inv = lsp.text_edits.inverseOf(self.allocator, d.opened.file.content, d.changes.items) catch return .{ .refused = .out_of_memory };
                var sel_items = [_]editor_selection.Selection{.{ .anchor_start = 0, .anchor_end = 0, .focus = 0 }};
                var sels = editor_selection.Selections.init(&sel_items, 0);
                var applied_inv = d.opened.file.apply(d.changes.delta(), &sels) catch {
                    var i = inv;
                    i.deinit(self.allocator);
                    failed_write = keepPath(item.path);
                    break;
                };
                applied_inv.deinit();
                const bytes = d.opened.file.saveBytes(self.allocator) catch return .{ .refused = .out_of_memory };
                defer self.allocator.free(bytes);
                // ⚠️ **일괄 경로는 파일마다 알림을 띄우지 않는다**(§3.9d) — 스무 파일을 고치면 스무
                // 개가 뜬다. 이유는 여기서 버리고, 그 자리의 요약이 「몇 개가 됐나」로 말한다.
                editor_ops.writeDocumentBytes(self, item.path, bytes, null) catch {
                    var i = inv;
                    i.deinit(self.allocator);
                    failed_write = keepPath(item.path);
                    break;
                };
                any = true;
                edits_total += d.changes.items.len;
                inverse = inv;
                after_hash = editor_ops.contentHash(d.opened.file.content);
                st.saved_files += 1;
            }
        }
        if (!any) continue;
        touched += 1;
        records.append(self.allocator, .{
            .path = self.allocator.dupe(u8, item.path) catch return .{ .refused = .out_of_memory },
            .inverse = inverse.?,
            .after_hash = after_hash,
        }) catch return .{ .refused = .out_of_memory };
    }
    // 저장 정책 — 관련 파일이 둘 이상이면 열린 Term 도 저장한다(하나면 dirty 로 둔다).
    if (touched > 1) {
        for (items) |*item| {
            for (item.open) |o| {
                if (o.changes.items.len == 0) continue;
                // 일괄 경로 — 이유는 여기서 버린다(§3.9d: 파일마다 알림을 띄우지 않는다). 성공만 센다.
                if (editor_ops.isDirty(o.term)) {
                    if (editor_ops.saveDocument(self, o.term)) |_| {
                        st.saved_files += 1;
                    } else |_| {}
                }
            }
        }
    }
    if (st.last) |*old| old.deinit(self.allocator);
    st.last = if (records.items.len > 0) .{ .files = records.toOwnedSlice(self.allocator) catch return .{ .refused = .out_of_memory } } else null;
    st.applied_files += touched;
    st.applied_edits += edits_total;
    if (failed_write) |p| {
        st.refused_rejected += 1;
        return .{ .refused = .{ .rejected = p } };
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
        defer opens.deinit(self.allocator);
        var it = TermIter{ .self = self };
        while (it.next()) |term| {
            if (term.kind != .editor or term.rt.editor_diff != null) continue;
            const doc = term.rt.editor_doc orelse continue;
            const tpath = term.rt.editor_path orelse continue;
            if (!std.mem.eql(u8, tpath, f.path)) continue;
            if (doc.file.read_only or editor_ops.contentHash(doc.file.content) != f.after_hash) {
                item.deinit(self.allocator);
                st.undo_refused += 1;
                return .{ .changed = keepPath(f.path) };
            }
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
                for (opens.items) |*o| o.changes.deinit(self.allocator);
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
