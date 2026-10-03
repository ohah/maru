//! 창 checkpoint의 문서 표와 pane별 뷰를 연결한다. staging 동안 문서는 한 번만 읽고,
//! 모든 Term은 호출자의 새 pane 트리에 귀속된다. 실패하면 기존 live tree는 건드리지 않는다.
const std = @import("std");
const maru = @import("maru");
const app = @import("../../app_session.zig");
const editor = @import("mod.zig");
const backup = @import("backup.zig");
const term_ops = @import("../term.zig");
const codec = maru.session.editor.workspace_state;

pub fn eligible(term: *const app.Term) bool {
    const doc = term.rt.editorDocument();
    return term.kind == .editor and term.rt.editor_diff == null and term.rt.editor_merge == null and
        doc.path != null and doc.remote == null and doc.untitled == null and doc.recovery_id != null and
        !@import("../file_panel.zig").remoteViewPathIsReadOnly(doc.path.?);
}

pub const Capture = struct {
    allocator: std.mem.Allocator,
    documents: std.ArrayList(codec.Document) = .empty,
    sources: std.ArrayList(Source) = .empty,
    const Source = struct { state: *maru.session.editor.document_state.State, revision: u64 };

    pub fn view(self: *Capture, term: *app.Term, index: usize) !codec.View {
        const state = term.rt.editorDocument();
        const opened = state.opened.?;
        const document: u32 = blk: {
            for (self.sources.items, 0..) |source, i| if (source.state == state) break :blk @intCast(i);
            const i = std.math.cast(u32, self.documents.items.len) orelse return error.TooManyDocuments;
            try self.documents.append(self.allocator, .{
                .index = i,
                .recovery_id = state.recovery_id.?,
                .path = try self.allocator.dupe(u8, state.path.?),
                .disk_hash = opened.disk_hash,
                .content_hash = editor.contentHash(opened.file.content),
            });
            try self.sources.append(self.allocator, .{ .state = state, .revision = opened.file.revision });
            break :blk i;
        };
        return .{
            .index = index,
            .document = document,
            .primary = term.rt.editor_selection orelse codec.Selection.at(0),
            .extras = try self.allocator.dupe(codec.Selection, term.rt.editor_extra_selections),
            .first_line = term.rt.editor_first_line,
            .first_piece = term.rt.editor_first_piece,
            .first_col = term.rt.editor_first_col,
            .wrap = term.rt.editor_wrap,
            .folded = try self.allocator.dupe(u32, editor.foldedHeads(term)),
        };
    }
    pub fn finish(self: *Capture) ![]const codec.Document {
        for (self.sources.items) |source| {
            if (source.state.opened == null or source.state.opened.?.file.revision != source.revision)
                return error.CaptureChanged;
        }
        return self.documents.toOwnedSlice(self.allocator);
    }
};

pub const Staging = struct {
    session: *app.AppSession,
    documents: []const codec.Document,
    terms: []?*app.Term,
    restored_content: bool = false,

    pub fn init(session: *app.AppSession, documents: []const codec.Document) !Staging {
        const terms = try session.allocator.alloc(?*app.Term, documents.len);
        @memset(terms, null);
        return .{ .session = session, .documents = documents, .terms = terms };
    }
    pub fn deinit(self: *Staging) void {
        self.session.allocator.free(self.terms);
    }
    pub fn createView(self: *Staging, value: codec.View) !*app.Term {
        const i = for (self.documents, 0..) |doc, n| {
            if (doc.index == value.document) break n;
        } else return error.MissingDocument;
        const doc = self.documents[i];
        var prepared = if (self.terms[i]) |source|
            try editor.prepareRetainedRestoreView(self.session, source)
        else
            try editor.prepareRecoveryPath(self.session, doc.path, doc.recovery_id);
        const term = editor.createEditorTerm(self.session) catch |err| {
            prepared.deinit(self.session.allocator);
            return err;
        };
        editor.finishAttach(self.session, term, prepared);
        errdefer term_ops.destroyTerm(self.session, term);
        if (self.terms[i] == null) self.restored_content = (try backup.restoreRecovery(self.session, term)) or self.restored_content;
        const matching = editor.contentHash(term.rt.editorDocument().opened.?.file.content) == doc.content_hash;
        try editor.restoreViewState(self.session, term, value, matching);
        if (self.terms[i]) |source| {
            // 복원 뷰의 검색은 새 빈 상태다. 기존 창의 검색 입력을 staging에 복사하지 않는다.
            @import("../find.zig").enableSharedViewFind(self.session, source, term, null);
        }
        if (!matching) std.log.scoped(.app).warn("editor restore degraded: document={d} reason=content-changed", .{doc.index});
        if (self.terms[i] == null) self.terms[i] = term;
        return term;
    }
};
