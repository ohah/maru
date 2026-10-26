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

var sidebar_fixture_ready = false;
export fn maru_address_fixture_start(mode: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    if (mode != 0) return 0;
    if (!sidebar_fixture_ready) {
        if (self.tabs.items.len != 1) return 0;
        _ = tab_ops.newTab(self) catch return 0;
        if (self.tabs.items.len != 2) return 0;
        for (self.tabs.items, [_][]const u8{"한","韓"}) |tab,name| {
            const label = self.allocator.dupe(u8,name) catch return 0;
            if (tab.custom_name) |previous| self.allocator.free(previous);
            tab.custom_name = label;
        }
        _ = tab_ops.switchTab(self,0);
        sidebar_fixture_ready = true;
    }
    if (self.tabs.items.len != 2 or self.app_window.active_tab != 0) return 0;
    const native = @import("sidebar_ime.zig");
    native.setActive(self, false);
    self.sidebar_search_input.clear();
    self.sidebar_ime.projection.invalidate();
    native.setActive(self, true);
    @import("sidebar.zig").rebuildSidebar(self) catch return 0;
    self.metal_dirty = true;
    return 1;
}
fn projectGlyphAdvance(self: *AppSession, bytes: []const u8) ?f64 {
    const values = @import("chrome_text_offsets.zig").measure(self, bytes, .{bytes.len,bytes.len,bytes.len},4096,self.scale_milli) catch return null;
    const scale = @as(f64,@floatFromInt(self.scale_milli))/1000;
    if (scale <= 0 or !std.math.isFinite(values[0]) or values[0] <= 0) return null;
    return @floor(@as(f64,values[0]))/scale;
}
export fn maru_palette_ime_witness(field: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    const state = &self.sidebar_search_input;
    if (field >= 12 and field <= 15) {
        const rect = @import("sidebar.zig").sidebarSearchTextRect(self) orelse return 0;
        return switch(field) {12=>@intCast(@max(0,rect.x)),13=>@intCast(@max(0,rect.y)),14=>rect.w,15=>rect.h,else=>unreachable};
    }
    const projected = @import("chrome_ime.zig").projection(self);
    return switch (field) {
        0 => 1,
        1 => @intFromBool(self.sidebar_search_active),
        2 => @intFromBool(self.inputFocus() == .sidebar_search),
        3 => @import("chrome_ime.zig").generation(self) orelse 0,
        4 => state.query.items.len, 5=>paletteIMEHash(state.query.items),
        6 => state.preedit.items.len, 7=>paletteIMEHash(state.preedit.items),
        8=>0, 9=>self.total_terminal_input_bytes,
        10 => if(self.app_window.active()) |term| term.id else 0,
        11=>paletteIMEBaseGeneration(self),
        17 => if(projected) |p| paletteIMEHash(p.text()) else 0,
        18 => if(projected) |p| p.text().len else 0,
        19 => if(self.sidebar_ime.projection.current(state)) |c| c.selected.end else state.query.items.len,
        27 => blk: {var count:u64=0;for(self.sidebar_rows.items) |row| {if(row==.card) count+=1;} break :blk count;},
        28 => @intFromBool(self.sidebar_search_active),
        30 => if(self.tabs.items.len==2 and std.mem.eql(u8,app_session_mod.workspaceLabel(self.tabs.items[0]),"한") and std.mem.eql(u8,app_session_mod.workspaceLabel(self.tabs.items[1]),"韓")) paletteIMEHash("한韓") else 0,
        31 => self.tabs.items.len,
        32 => blk: {var mask:u64=0;for(self.sidebar_rows.items) |row| {switch(row) {.card=>|c| {if(c.tab<64) mask|=@as(u64,1)<<@intCast(c.tab);},else=>{}}}break :blk mask;},
        33 => self.app_window.active_tab,
        38 => if(projectGlyphAdvance(self,"한")) |v| @intFromFloat(@round(v*1000)) else 0,
        39 => if(projectGlyphAdvance(self,"韓")) |v| @intFromFloat(@round(v*1000)) else 0,
        else=>0,
    };
}
