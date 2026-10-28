// Private setup opens only owned files and approves only its own controlled-server root.
var palette_ime_observed_session: ?*AppSession = null;
var symbol_surface: u64 = 0;
pub fn observePaletteIME(self: *AppSession) void {
    if (std.c.getenv("MARU_PALETTE_IME") != null and self.dock_initialized) palette_ime_observed_session = self;
}
fn paletteIMEHash(bytes: []const u8) u64 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.mem.readInt(u64,digest[0..8],.little);
}
export fn maru_address_fixture_start(mode:u32) u64 {
    const self=palette_ime_observed_session orelse return 0;
    if(mode!=0 or !self.surface_initialized or !self.dock_initialized) return 0;
    const root=std.mem.span(std.c.getenv("MARU_UNTITLED_PROJECT") orelse return 0);
    const term=pane_ops.activePane(self).activeTerm();
    if(term.kind!=.editor or term.rt.editor_syntax.pending) return 0;
    const path=term.rt.editorDocument().path orelse return 0;
    if(!std.mem.eql(u8,std.fs.path.dirname(path) orelse "",root)) return 0;
    if(self.pending_confirm==.lsp_trust) {
        const key=self.editor_lsp.asking_key orelse return 0;
        if(key.dest.len!=0 or !std.mem.eql(u8,key.path,root)) return 0;
        // This is fixture setup for its own known server, not evidence of user trust UX.
        // Trust defaults to cancel; use the ordinary two-step explicit confirmation.
        if (!self.chrome_host.confirm.rechecking) {
            if (self.chrome_host.confirm.focused != .confirm)
                _=self.handleKeyEvent(.{.key=.arrow_left}) catch return 0;
            if (self.chrome_host.confirm.focused == .confirm)
                _=self.handleKeyEvent(.{.key=.enter}) catch return 0;
        } else {
            _=self.handleKeyEvent(.{.key=.enter,.modifiers=.{.command=true}}) catch return 0;
        }
        return 0;
    }
    const client=editor_ops.lsp_client.readyClientFor(self,term) orelse return 0;
    const doc=client.findDoc(term) orelse return 0;
    if(doc.sent_version!=term.rt.editorDocument().notifications.lsp_version) return 0;
    const bytes=term.rt.editorDocument().opened.?.file.content;
    const word=std.mem.indexOf(u8,bytes,"base") orelse return 0;
    term.rt.editor_selection=maru.session.editor.selection.Selection.at(word+2);
    symbol_surface=term.surface.id;
    return @intFromBool(editor_ops.rename_client.startAtCaret(self));
}
export fn maru_palette_ime_witness(field: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    if (self.tabs.items.len == 0) return 0;
    const term = pane_ops.activePane(self).activeTerm();
    const state = &self.rename_input;
    if (field >= 12 and field <= 15) {
        const rect = @import("settings.zig").renameCaretRect(self) orelse return 0;
        return switch (field) { 12 => @intCast(@max(0, rect.x)), 13 => @intCast(@max(0, rect.y)), 14 => rect.w, 15 => rect.h, else => unreachable };
    }
    const projected = @import("chrome_ime.zig").projection(self);
    return switch (field) {
        0 => 1,
        1 => @intFromBool(self.rename != null),
        2 => @intFromBool(self.inputFocus() == .rename),
        3 => @import("chrome_ime.zig").generation(self) orelse 0,
        4 => state.text.items.len, 5 => paletteIMEHash(state.text.items),
        6 => state.preedit.items.len, 7 => paletteIMEHash(state.preedit.items),
        8 => @intFromBool(self.editor_rename.waiting),
        9 => self.total_terminal_input_bytes,
        10 => if (self.app_window.active()) |t| t.id else 0,
        17 => if (projected) |p| paletteIMEHash(p.text()) else 0,
        18 => if (projected) |p| p.text().len else 0,
        19 => state.caret,
        27 => paletteIMEHash(blk: {
            const target=self.rename orelse break :blk "";
            if(target!=.symbol) break :blk "";
            break :blk editor_ops.rename_client.seedFor(self,target.symbol) orelse "";
        }),
        30 => if (term.kind == .editor) @intFromBool(term.rt.editorDocument().untitled != null) else 0,
        31 => if (term.kind == .editor) paletteIMEHash(term.rt.editorDocument().opened.?.file.content) else 0,
        32 => if (term.kind == .editor) @intFromBool(editor_ops.isDirty(term)) else 0,
        33 => @intFromBool(self.chrome_host.confirm.open),
        34 => term.surface.id,
        37 => @intFromBool(self.chrome_host.notice.open),
        40 => self.editor_rename.sent_count,
        41 => self.editor_rename.notified_done,
        42 => self.editor_rename.notified_error,
        43 => self.editor_rename.refused_stale_at_commit,
        45 => term.rt.editorDocument().notifications.lsp_version,
        46 => term.rt.editorDocument().history.undo_len,
        else => 0,
    };
}

export fn maru_symbol_invalidate() u64 {
    const self=palette_ime_observed_session orelse return 0;
    const term=pane_ops.activePane(self).activeTerm();
    if(term.surface.id!=symbol_surface or self.rename==null) return 0;
    term.rt.editor_selection=maru.session.editor.selection.Selection.at(0);
    return @intFromBool(editor_ops.insertText(self,term,"// local change\n"));
}
export fn maru_symbol_undo() u64 {
    const self=palette_ime_observed_session orelse return 0;
    self.dispatchAppAction(.undo_workspace_edit);
    return 1;
}
export fn maru_symbol_model(stage:u32) u64 {
    const self=palette_ime_observed_session orelse return 0;
    const term=pane_ops.activePane(self).activeTerm();
    if(term.kind!=.editor or term.surface.id!=symbol_surface) return 0;
    const doc=term.rt.editorDocument();
    const root=std.mem.span(std.c.getenv("MARU_PALETTE_IME") orelse return 0);
    const project=std.mem.span(std.c.getenv("MARU_UNTITLED_PROJECT") orelse return 0);
    const other=std.fs.path.join(self.allocator,&.{project,"other.c"}) catch return 0;
    defer self.allocator.free(other);
    const main_disk=std.Io.Dir.cwd().readFileAlloc(self.io,doc.path.?,self.allocator,.limited(32768)) catch return 0;
    defer self.allocator.free(main_disk);
    const other_disk=std.Io.Dir.cwd().readFileAlloc(self.io,other,self.allocator,.limited(32768)) catch return 0;
    defer self.allocator.free(other_disk);
    const path=std.fs.path.join(self.allocator,&.{root,if(stage==0) "applied.json" else "model.json"}) catch return 0;
    defer self.allocator.free(path);
    const bytes=std.json.Stringify.valueAlloc(self.allocator,.{
        .schema="maru.symbol-rename-model.v1",.pid=std.c.getpid(),.surface_id=symbol_surface,
        .path=doc.path,.body=doc.opened.?.file.content,.dirty=editor_ops.isDirty(term),
        .version=doc.notifications.lsp_version,.undo_len=doc.history.undo_len,
        .main_disk=main_disk,.other_disk=other_disk,.other_open=file_panel_ops.fileTermForPath(self,other)!=null,
        .pending=self.editor_rename.waiting,.sent=self.editor_rename.sent_count,
        .done=self.editor_rename.notified_done,.errors=self.editor_rename.notified_error,
        .refused_stale=self.editor_rename.refused_stale_at_commit,
        .applied_files=self.editor_workspace_edit.applied_files,.saved_files=self.editor_workspace_edit.saved_files,
        .undone_files=self.editor_workspace_edit.undone_files,.notice=self.chrome_host.notice.open,
    },.{}) catch return 0;
    defer self.allocator.free(bytes);
    std.Io.Dir.cwd().writeFile(self.io,.{.sub_path=path,.data=bytes}) catch return 0;
    return 1;
}
