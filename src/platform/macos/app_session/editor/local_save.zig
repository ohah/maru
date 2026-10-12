//! 이름 있는 로컬 저장의 자료·쓰기·완료를 분리한다. 현재 호출자는 세 단계를 동기로 실행한다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../app_session.zig");
const editor = @import("mod.zig");
const lsp = @import("lsp.zig");
const Identity = maru.session.editor.document_registry.DocumentIdentity;
pub const Prepared = struct {
    bytes: []const u8,
    path: []const u8,
    logical_start: usize,
    document: usize,
    identity: ?Identity,
    expected_disk: ?u64,
    written: bool = false,
    finished: bool = false,
    pub fn init(session: *host.AppSession, term: *host.Term, guard: editor.SaveGuard) editor.SaveError!Prepared {
        const state = term.rt.editorDocument();
        const doc = state.opened orelse return error.NotAnEditor;
        const path = state.path orelse return error.NotAnEditor;
        const bytes = doc.file.saveBytes(session.allocator) catch return error.WriteFailed;
        errdefer session.allocator.free(bytes);
        if (bytes.len > maru.session.file_panel_bridge.max_file_bytes) return error.TooLarge;
        const owned_path = session.allocator.dupe(u8, path) catch return error.WriteFailed;
        // 논리 본문은 소유한 저장 bytes에서 빌린다. 별도 전문 복사 없이 재편집 뒤에도 살아 있다.
        return .{ .bytes = bytes, .path = owned_path, .logical_start = bytes.len - doc.file.content.len, .document = @intFromPtr(state), .identity = identity(term), .expected_disk = switch (guard) {
            .cas => doc.disk_hash,
            .overwrite => null,
        } };
    }
    pub fn deinit(self: *Prepared, a: std.mem.Allocator) void {
        a.free(self.bytes);
        a.free(self.path);
        self.* = undefined;
    }
    pub fn content(self: *const Prepared) []const u8 {
        return self.bytes[self.logical_start..];
    }
    pub fn write(self: *Prepared, io: std.Io) editor.SaveError!void {
        if (!maru.session.editor.save_ops.writable(self.written, self.finished)) return error.WriteFailed;
        try writeBytes(io, self.path, self.bytes, self.expected_disk);
        self.written = true;
    }
    pub fn matches(self: *const Prepared, term: *host.Term) bool {
        if (term.kind != .editor or term.rt.editor_diff != null) return false;
        const state = term.rt.editorDocument();
        if (state.remote != null or state.untitled != null or state.opened == null) return false;
        const path = state.path orelse return false;
        const token: maru.session.editor.save_ops.Token = .{ .document = self.document, .identity = self.identity, .path = self.path };
        return token.matches(.{ .document = @intFromPtr(state), .identity = identity(term), .path = path });
    }
    /// 호출자는 쓰기 성공 후에만 부른다. 완료 거절은 디스크 쓰기의 취소/롤백을 뜻하지 않는다.
    pub fn finish(self: *Prepared, session: *host.AppSession, term: *host.Term) bool {
        if (!self.written or self.finished) return false;
        self.finished = true;
        if (!self.matches(term)) return false;
        @import("../../app_session.zig").editor_backup_ops.markClean(session, term, self.content(), null);
        term.rt.editorDocument().opened.?.disk_hash = editor.contentHash(self.bytes);
        session.metal_dirty = true;
        _ = lsp.noteSaved(session, term, self.content());
        if (maru.session.editor.conflict.hasUnresolved(term.rt.editor_lines)) session.showNoticeKey(.editor_conflict_markers_remain);
        return true;
    }
};
fn identity(term: *host.Term) ?Identity {
    const lease = term.rt.editor_document_lease orelse return null;
    return .{ .owner = @intFromPtr(lease.owner), .slot = lease.document.slot, .generation = lease.document.generation };
}

/// 파일 쓰기는 문서·UI를 읽지 않는다. I/O executor 수명은 호출자가 보장한다.
pub fn writeBytes(io: std.Io, path: []const u8, bytes: []const u8, expect_disk: ?u64) host.AppSession.FilePanelWriteError!void {
    // **이유를 지우지 않는다**(§3.9d). 예전에는 다섯 자리가 전부 `catch return false` 였고, 그래서
    // 읽기 실패·외부 변경·쓰기 실패가 한 개의 `false` 로 뭉개져 사용자는 `⌘S` 를 누르고 아무 일도
    // 없는 것을 봤다. 아래 층이 이미 `FilePanelWriteError` 를 내므로 **새 어휘를 짓지 않고 올린다**.
    var pinned = @import("../file_panel.zig").openPinnedFilePanelParent(io, path) catch return error.NotFound;
    defer pinned.dir.close(io);

    var original = pinned.dir.openFile(io, pinned.basename, .{ .mode = .read_only }) catch return error.NotFound;
    defer original.close(io);
    const stat = original.stat(io) catch return error.NotFound;

    // **지금 디스크에 있는 것의 해시를 넘긴다.** 0을 넘겨 "검사를 건너뛴다"고 적었다가 실제
    // 구현을 보니 **무조건 비교**한다 — 0이면 정상 파일이 늘 `ExternalConflict`가 된다.
    // 그 검사가 막는 것은 *"temp를 쓰는 동안 남이 같은 inode를 in-place로 고쳤다"*이므로,
    // 쓰기 직전에 읽은 값을 기준으로 두는 것이 맞다.
    const expected = try host.AppSession.stableOpenedFileHash(io, original, stat.inode);
    // ⚠️ **여기가 「연 뒤 바뀌었나」를 묻는 유일한 자리다.** 아래 `writePinnedFilePanel` 의 검사는
    // 「쓰는 동안 바뀌었나」라 이 질문에 답하지 않는다 — 그래서 예전에는 밖에서 고친 파일 위에
    // 조용히 덮어썼다(적대적 검증에서 판정자가 그것을 드러냈다).
    if (expect_disk) |want| if (want != expected) return error.ExternalConflict;

    try @import("../file_panel.zig").writePinnedFilePanel(
        io,
        pinned.dir,
        pinned.basename,
        original,
        stat,
        expected,
        bytes,
    );
}
