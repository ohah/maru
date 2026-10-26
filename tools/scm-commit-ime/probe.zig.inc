// Private-copy instrumentation: witness exports only observe product state.
// The separately named fixture export arranges topology and URL metadata;
// pointer mode never uses it to edit text, select, or return focus.
var palette_ime_observed_session: ?*AppSession = null;
pub fn observePaletteIME(self: *AppSession) void {
    if (std.c.getenv("MARU_PALETTE_IME") != null and self.dock_initialized)
        palette_ime_observed_session = self;
}
fn paletteIMEHash(bytes: []const u8) u64 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.mem.readInt(u64, digest[0..8], .little);
}
fn paletteIMEBaseGeneration(self: *AppSession) u64 {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.surface.remote != null) {
        const backend = if (app_session_mod.app_remote_backend) |*value| value else return std.math.maxInt(u64);
        return backend.screenGenerationFor(term.rt.handle) orelse std.math.maxInt(u64);
    }
    term.surface.lockCore(self.io);
    defer term.surface.unlockCore(self.io);
    return term.surface.core.observerGeneration();
}

// The one private writer-entry observer is outside all Git guards.
pub var scm_ime_commit_attempts: u64 = 0;
export fn maru_address_fixture_start(mode: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    if (mode != 0) return 0;
    const run = std.mem.span(std.c.getenv("MARU_PALETTE_IME") orelse return 0);
    var scratch: [std.fs.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&scratch, "{s}/scm-repo", .{run}) catch return 0;
    const dir = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch return 0;
    defer dir.close(self.io);
    var canonical: [std.fs.max_path_bytes]u8 = undefined;
    const length = dir.realPath(self.io, &canonical) catch return 0;
    const root = canonical[0..length];
    // Only scene setup touches topology/draft. All typing and candidate actions use HID.
    scm_dock_ops.blurCommit(self);
    git_ops.rememberGitRepo(self, root);
    self.dock.presented = true;
    self.dock.collapsed = false;
    self.dock.view = .source_control;
    self.scm_tab = .changes;
    git_ops.refreshGitStatus(self);
    scm_dock_ops.focusCommitRepo(self, root);
    if (self.scm_commit_focus_repo == null) return 0;
    self.scm_commit_field.clear();
    @import("scm_commit_ime.zig").retire(self);
    self.scm_commit_first_row = 0;
    self.metal_dirty = true;
    return 1;
}
fn projectGlyphAdvance(self: *AppSession, bytes: []const u8) ?f64 {
    if (self.scale_milli == 0 or self.cell_width_px == 0) return null;
    return @as(f64, @floatFromInt(chrome.components.text_field.displayCols(bytes) * self.cell_width_px)) * 1000.0 / @as(f64, @floatFromInt(self.scale_milli));
}
export fn maru_palette_ime_witness(field: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    const state = &self.scm_commit_field;
    if (field >= 12 and field <= 15) {
        const box = scm_dock_ops.commitBoxRect(self) orelse return 0;
        const content = dock_ops.dockGeometry(self).tree_content;
        return switch (field) {
            12 => @intFromFloat(@as(f32,@floatFromInt(content.x)) + box.x),
            13 => @intFromFloat(@as(f32,@floatFromInt(content.y)) + box.y),
            14 => @intFromFloat(box.width), 15 => @intFromFloat(box.height), else => unreachable,
        };
    }
    const projected = @import("chrome_ime.zig").projection(self);
    return switch(field) {
        0 => 1,
        1, 28 => @intFromBool(self.scm_commit_focus_repo != null),
        2 => @intFromBool(self.inputFocus() == .scm_commit),
        3 => @import("chrome_ime.zig").generation(self) orelse 0,
        4 => state.text.items.len, 5 => paletteIMEHash(state.text.items),
        6 => state.preedit.items.len, 7 => paletteIMEHash(state.preedit.items),
        8 => scm_ime_commit_attempts, 9 => self.total_terminal_input_bytes,
        10 => if(self.app_window.active()) |term| term.id else 0,
        11 => paletteIMEBaseGeneration(self),
        17 => if(projected) |p| paletteIMEHash(p.text()) else 0,
        18 => if(projected) |p| p.text().len else 0,
        19 => state.caret,
        38 => if(projectGlyphAdvance(self,"한")) |v| @intFromFloat(@round(v*1000)) else 0,
        39 => if(projectGlyphAdvance(self,"韓")) |v| @intFromFloat(@round(v*1000)) else 0,
        else => 0,
    };
}
