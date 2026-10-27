// Scalar IME witnesses are read-only. Separate fixture/model exports arrange setup
// and exercise Undo/Redo only after the real save/cancel has settled.
var palette_ime_observed_session: ?*AppSession = null;
var first_save_surface: u64 = 0;
var first_save_root_requested = false;
pub fn observePaletteIME(self: *AppSession) void {
    if (std.c.getenv("MARU_PALETTE_IME") != null and self.surface_initialized) palette_ime_observed_session = self;
}
fn paletteIMEHash(bytes: []const u8) u64 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.mem.readInt(u64, digest[0..8], .little);
}
export fn maru_address_fixture_start(mode: u32) u64 {
    const self = palette_ime_observed_session orelse { std.debug.print("FIRST_SAVE_SETUP no_session\n", .{}); return 0; };
    std.debug.print("FIRST_SAVE_SETUP surface={any} tree={any} dock={any} requested={any} roots={d}\n", .{self.surface_initialized,self.file_tree_initialized,self.dock_initialized,first_save_root_requested,self.file_tree.rootCount()});
    const root = std.mem.span(std.c.getenv("MARU_UNTITLED_PROJECT") orelse return 0);
    if (mode != 0 or !self.surface_initialized or !self.file_tree_initialized) return 0;
    const root_ready = self.file_tree.rootCount() == 1 and
        std.mem.eql(u8, self.file_tree.rootAt(0).?, root) and self.file_tree.rootCapabilityForPath(root) != null;
    if (!root_ready) {
        // Startup may already be validating the configured root. Wait for that request;
        // if it was superseded/busy, submit again only after the pending owner retires.
        if (self.file_tree_root_validation != null) return 0;
        self.file_tree_root_picker_inflight = .replace;
        self.provideFileTreeRootPick(root);
        first_save_root_requested = true;
        return 0;
    }
    if (first_save_surface == 0) {
        self.focusWorkspaceInput();
        const term = editor_ops.openUntitledInActivePane(self) catch |err| { std.debug.print("FIRST_SAVE_OPEN {s}\n", .{@errorName(err)}); return 0; };
        first_save_surface = term.surface.id;
        if (!editor_ops.insertText(self, term, "first save body\n")) return 0;
    }
    const term = pane_ops.activePane(self).activeTerm();
    if (term.surface.id != first_save_surface or term.kind != .editor) return 0;
    // Use the ordinary first-save entry, including its empty-name contract.
    return @intFromBool(@import("editor/untitled_save.zig").begin(self, term));
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
        8 => @import("editor/save/as.zig").pending(),
        9 => self.total_terminal_input_bytes,
        10 => if (self.app_window.active()) |t| t.id else 0,
        17 => if (projected) |p| paletteIMEHash(p.text()) else 0,
        18 => if (projected) |p| p.text().len else 0,
        19 => state.caret,
        27 => paletteIMEHash(if (term.kind == .editor) term.rt.editorDocument().path orelse "" else ""),
        30 => if (term.kind == .editor) @intFromBool(term.rt.editorDocument().untitled != null) else 0,
        31 => if (term.kind == .editor) paletteIMEHash(term.rt.editorDocument().opened.?.file.content) else 0,
        32 => if (term.kind == .editor) @intFromBool(editor_ops.isDirty(term)) else 0,
        33 => @intFromBool(self.chrome_host.confirm.open),
        34 => term.surface.id,
        37 => @intFromBool(self.chrome_host.notice.open),
        else => 0,
    };
}
export fn maru_untitled_model() u64 {
    const self = palette_ime_observed_session orelse return 0;
    const term = pane_ops.activePane(self).activeTerm();
    if (term.kind != .editor or term.surface.id != first_save_surface) return 0;
    const doc = term.rt.editorDocument();
    const before = self.allocator.dupe(u8, doc.opened.?.file.content) catch return 0;
    defer self.allocator.free(before);
    if (!editor_ops.undoEdit(self, term) or std.mem.eql(u8, before, doc.opened.?.file.content)) return 0;
    if (!editor_ops.redoEdit(self, term) or !std.mem.eql(u8, before, doc.opened.?.file.content)) return 0;
    const root = std.mem.span(std.c.getenv("MARU_PALETTE_IME") orelse return 0);
    const path = std.fs.path.join(self.allocator, &.{ root, "model.json" }) catch return 0;
    defer self.allocator.free(path);
    const bytes = std.json.Stringify.valueAlloc(self.allocator, .{
        .schema = "maru.untitled-first-save-model.v1", .pid = std.c.getpid(), .surface_id = first_save_surface,
        .path = doc.path, .untitled = doc.untitled != null, .body = doc.opened.?.file.content,
        .dirty = editor_ops.isDirty(term), .pending = @import("editor/save/as.zig").pending(),
        .history_verified = true, .notice = self.chrome_host.notice.open,
    }, .{}) catch return 0;
    defer self.allocator.free(bytes);
    std.Io.Dir.cwd().writeFile(self.io, .{ .sub_path = path, .data = bytes }) catch return 0;
    return 1;
}
