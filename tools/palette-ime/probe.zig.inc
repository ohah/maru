// Private-copy instrumentation: these exports read product state and never edit input.
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
export fn maru_palette_ime_witness(field: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    const state = &self.chrome_host.palette;
    if (field >= 12 and field <= 15) {
        const layout = chrome.components.overlay_input.panelLayout(self.buildChromeProps()) orelse return 0;
        return switch (field) {
            12 => @intCast(@max(0, layout.x)),
            13 => @intCast(@max(0, layout.y)),
            14 => layout.panel_cols * layout.cw,
            15 => layout.ch,
            else => unreachable,
        };
    }
    return switch (field) {
        0 => 1,
        1 => @intFromBool(state.open),
        2 => @intFromBool(self.inputFocus() == .palette),
        3 => @import("chrome_ime.zig").generation(self) orelse 0,
        4 => state.input.query.items.len,
        5 => paletteIMEHash(state.input.query.items),
        6 => state.input.preedit.items.len,
        7 => paletteIMEHash(state.input.preedit.items),
        8 => self.palette_filtered.items.len,
        9 => self.total_terminal_input_bytes,
        10 => if (self.app_window.active()) |term| term.id else 0,
        11 => paletteIMEBaseGeneration(self),
        16 => state.selected,
        else => 0,
    };
}
