//! 닫힌 파일의 문서·Term·entry를 준비 객체가 소유한다. pane 게시·편집·저장은 후속 coordinator의 책임이다.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../../app_session.zig");
const editor = @import("../../mod.zig");
const disk = @import("disk.zig");
const verify = @import("../verify.zig");
const process = @import("../process.zig");
const panels = @import("../../../file_panel.zig");
const terms = @import("../../../term.zig");
const dock = maru.session.dock_panel;
pub const Item = struct { term: *host.Term, target: disk.Target, proof: verify.Proof };
pub const Staged = struct {
    session: *host.AppSession,
    items: std.ArrayList(Item) = .empty,
    reserved: usize = 0,
    /// session보다 먼저 해제한다. 새 문서만 회수하며 기존 pane 목록·선택·이력에는 손대지 않는다.
    pub fn deinit(self: *Staged) void {
        const a = self.session.allocator;
        while (self.items.pop()) |item| {
            terms.destroyTerm(self.session, item.term);
            a.free(item.target.root);
            a.free(item.target.path);
        }
        self.items.deinit(a);
        self.session.editor_batch_reserved_entries -= self.reserved;
        self.reserved = 0;
    }
    fn owns(self: *const Staged, owner: *const maru.session.editor.document_registry.Registry, index: usize, generation: u64) bool {
        for (self.items.items) |item| {
            const lease = item.term.rt.editor_document_lease.?;
            if (lease.owner == owner and lease.document.slot == index and lease.document.generation == generation) return true;
        }
        return false;
    }
    /// caller는 worker에서 원문을 재검증한 Read를 가져와야 한다. 여기서는 namespace 신원·점유를 재확인한다.
    /// 전체 본문 재읽기를 UI actor에 추가하지 않는다. 입력은 복사하며 성공 후 caller가 해제해도 된다.
    pub fn prepare(session: *host.AppSession, targets: []const disk.Target, files: []const verify.Read) !Staged {
        if (targets.len != files.len) return error.StaleTargets;
        try inputReady(session);
        var count: usize = 0;
        var it = panels.fileEntries(session);
        while (it.next()) |_| count += 1;
        if (targets.len > dock.max_entries -| count -| session.editor_batch_reserved_entries) return error.TooManyEntries;
        var result: Staged = .{ .session = session, .reserved = targets.len };
        session.editor_batch_reserved_entries += targets.len;
        errdefer result.deinit();
        try result.items.ensureTotalCapacity(session.allocator, targets.len);
        // 자신의 임시 registry 항목을 점유로 오인하지 않도록, 모든 대상의 최초 검사를 등록 전에 끝낸다.
        for (targets, files, 0..) |target, file, index| {
            try guard(session, target, file.proof, null);
            var sha = std.crypto.hash.sha2.Sha256.init(.{});
            if (file.has_bom) sha.update(maru.session.editor.document.utf8_bom);
            sha.update(file.bytes);
            const raw = sha.finalResult();
            var hash: [32]u8 = undefined;
            std.crypto.hash.sha2.Sha256.hash(file.bytes, &hash, .{});
            if (!std.mem.eql(u8, &hash, &target.hash) or !std.mem.eql(u8, &raw, &file.proof.raw_hash)) return error.FileChanged;
            for (files[0..index]) |prior| if (prior.proof.sameFile(file.proof)) return error.AliasedTargets;
        }
        for (targets, files) |target, file| {
            const a = session.allocator;
            const root = try a.dupe(u8, target.root);
            errdefer a.free(root);
            const relative = try a.dupe(u8, target.path);
            errdefer a.free(relative);
            const absolute = try std.fs.path.resolve(a, &.{ root, relative });
            errdefer a.free(absolute);
            const entry = try a.create(dock.Entry);
            errdefer a.destroy(entry);
            entry.* = .{ .id = try host.app_runtime.entry_ids.next(), .path = absolute, .kind = .text, .mode = dock.Mode.defaultFor(.text), .native_editor = true };
            var prepared = try editor.prepareVerifiedText(session, absolute, file.bytes, file.has_bom);
            var attached = false;
            errdefer if (!attached) prepared.deinit(a);
            if (prepared.lease.owner.get(prepared.lease).?.opened.?.file.read_only) return error.ReadOnly;
            const term = try editor.createEditorTerm(session);
            // finishAttach의 파생 상태/참조를 Term에 넘긴 뒤에는 Term 하나가 전부 회수한다.
            editor.finishAttach(session, term, prepared);
            attached = true;
            term.file_entry = entry;
            entry.surface_id = term.surfaceId();
            result.items.appendAssumeCapacity(.{ .term = term, .target = .{ .root = root, .path = relative, .root_identity = target.root_identity, .hash = target.hash }, .proof = file.proof });
        }
        try result.validate();
        return result;
    }
    /// 늦게 열린 독립 문서·새 별칭·root/파일 교체를 검사한다. 자기 임시 문서만 점유에서 제외한다.
    pub fn validate(self: *const Staged) !void {
        try inputReady(self.session);
        for (self.items.items) |item| try guard(self.session, item.target, item.proof, self);
    }
};
fn inputReady(session: *host.AppSession) !void {
    if (session.ime_active or session.ime_editor_commit_pending) return error.InputTransactionPending;
    for (session.editor_search.fields) |field| if (field.preedit.items.len != 0) return error.InputTransactionPending;
}
fn identity(fd: std.c.fd_t) !maru.session.file_tree.Identity {
    var stat: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &stat) != 0) return error.StatFailed;
    const device: std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(stat.dev))) = @bitCast(stat.dev);
    return .{ .device = device, .inode = stat.ino, .kind = if (std.posix.S.ISREG(stat.mode)) 1 else 4 };
}
fn occupied(session: *host.AppSession, path: []const u8, absolute: []const u8, proof: verify.Proof) !void {
    const normalized = try std.fs.path.resolve(session.allocator, &.{path});
    defer session.allocator.free(normalized);
    if (std.mem.eql(u8, normalized, absolute)) return error.PathOccupied;
    const name = try session.allocator.dupeZ(u8, normalized);
    defer session.allocator.free(name);
    const fd = std.c.open(name, std.c.O{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true });
    if (fd < 0) {
        // 사라진 경로에는 현재 물리 파일이 없다. 다른 조회 실패로 별칭 검증이 끝났다고 판단하지 않는다.
        switch (std.posix.errno(fd)) {
            .NOENT, .NOTDIR => return,
            else => return error.UnverifiableOccupiedDocument,
        }
    }
    defer _ = std.c.close(fd);
    if ((try identity(fd)).eql(proof.identity)) return error.PathOccupied;
}
fn guard(session: *host.AppSession, target: disk.Target, proof: verify.Proof, staged: ?*const Staged) !void {
    const a = session.allocator;
    var root = try process.openRoot(a, session.io, target.root);
    defer root.deinit(a, session.io);
    const root_id = try identity(root.directory.handle);
    if (root_id.device != target.root_identity.device or root_id.inode != target.root_identity.inode or target.root_identity.kind != 2) return error.RootChanged;
    const relative = try a.dupeZ(u8, try maru.session.editor.search.request.relativePath(target.path));
    defer a.free(relative);
    const fd = std.c.openat(root.directory.handle, relative, std.c.O{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NONBLOCK = true });
    if (fd < 0) return error.FileChanged;
    defer _ = std.c.close(fd);
    var current: std.posix.Stat = undefined;
    if (std.c.fstat(fd, &current) != 0 or !proof.matchesStat(current)) return error.FileChanged;
    try process.validateRoot(session.io, &root);
    const absolute = try std.fs.path.resolve(a, &.{ target.root, target.path });
    defer a.free(absolute);
    if (!editor.isWritable(absolute) or panels.remoteViewPathIsReadOnly(absolute)) return error.ReadOnly;
    for (session.editor_documents.slots.items, 0..) |slot, index| {
        const doc = slot.document orelse continue;
        if (staged) |own| if (own.owns(session.editor_documents, index, slot.generation)) continue;
        if (doc.state.remote != null) continue;
        const path = doc.state.path orelse continue;
        try occupied(session, path, absolute, proof);
    }
    // registry에 없는 현재 창의 WebView와 diff entry도 선택 밖 점유다.
    var entries = panels.fileEntries(session);
    while (entries.next()) |entry| {
        if (entry.remote_origin_dest.len != 0) continue;
        try occupied(session, entry.path, absolute, proof);
    }
}
