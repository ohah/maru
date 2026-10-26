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

var inspector_fixture_ready = false;
fn inspectorSceneDetached() bool {
    const raw = std.c.getenv("MARU_INSPECTOR_IME_DETACHED") orelse return false;
    return std.mem.eql(u8,std.mem.span(raw),"1");
}
export fn maru_address_fixture_start(mode: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    if (mode != 0 or self.tabs.items.len != 1) return 0;
    const term = pane_ops.activePane(self).activeTerm();
    if (!inspector_fixture_ready) {
        const label = self.allocator.dupe(u8,"한") catch return 0;
        if (term.surface.custom_name) |old| self.allocator.free(old);
        term.surface.custom_name = label;
        inspector_fixture_ready = true;
    }
    const ops = @import("inspector.zig");
    if (!ops.visible(self)) ops.toggle(self);
    ops.setPlacement(self,if(inspectorSceneDetached()) .window else .right);
    ops.clearSearch(self);
    self.inspector.tab = .overview;
    self.inspector.paused = false;
    self.inspector.pinned = false;
    self.inspector.refresh = true;
    ops.poll(self);
    self.inspector.paused = true;
    self.inspector.pinned = true;
    ops.focusInput(self,inspectorSceneDetached());
    self.metal_dirty = true;
    return @intFromBool(self.inspector.json != null and self.inspector.input_focused);
}
fn inspectorScale(self: *AppSession) u32 {
    return if(@import("inspector.zig").detached(self)) self.inspector.presentation.window_scale else self.scale_milli;
}
fn projectGlyphAdvance(self: *AppSession, bytes: []const u8) ?f64 {
    const scale_milli = inspectorScale(self);
    const values = @import("chrome_text_offsets.zig").measure(self,bytes,.{bytes.len,bytes.len,bytes.len},4096,scale_milli) catch return null;
    const scale = @as(f64,@floatFromInt(scale_milli))/1000;
    if (scale <= 0 or !std.math.isFinite(values[0]) or values[0] <= 0) return null;
    return @floor(@as(f64,values[0]))/scale;
}
// Observe the actual shared paint/hit query and first visible data row; no input is injected here.
fn inspectorFirstKey(self: *AppSession, a: std.mem.Allocator) []const u8 {
    const ops = @import("inspector.zig");
    const panel = maru.chrome.components.inspector;
    const query = ops.displayQuery(self,a) catch return "";
    const props = ops.propsFor(self);
    const rect = panel.dataControlRect(self.inspector.tab,query,self.inspector.offset,self.inspector.json orelse "{}",props,inspectorScale(self),a,100) orelse return "";
    const x = @as(f64,@floatFromInt(rect.x)) + @as(f64,@floatFromInt(rect.w))/2;
    const y = @as(f64,@floatFromInt(rect.y)) + @as(f64,@floatFromInt(rect.h))/2;
    const field = panel.fieldAt(self.inspector.tab,query,self.inspector.offset,self.inspector.json orelse "{}",props,inspectorScale(self),a,x,y) orelse return "";
    return field.key;
}
export fn maru_palette_ime_witness(field: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    const s = &self.inspector;
    const ops = @import("inspector.zig");
    if (field >= 12 and field <= 15) {
        const rect = ops.caretRect(self) orelse return 0;
        return switch(field){12=>@intCast(@max(0,rect.x)),13=>@intCast(@max(0,rect.y)),14=>rect.w,15=>rect.h,else=>unreachable};
    }
    const projected = @import("chrome_ime.zig").projection(self);
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const key = if(field==27 or field==40) inspectorFirstKey(self,arena.allocator()) else "";
    return switch(field) {
        0=>1, 1,28=>@intFromBool(ops.ownsInput(self)),2=>@intFromBool(self.inputFocus()==.inspector),
        3=>@import("chrome_ime.zig").generation(self) orelse 0,
        4=>s.query_len,5=>paletteIMEHash(s.query[0..s.query_len]),6=>s.preedit_len,7=>paletteIMEHash(s.preedit[0..s.preedit_len]),
        8=>@intFromBool(s.copy_requested or s.picking or s.status.len != 0),9=>self.total_terminal_input_bytes,
        10=>if(self.app_window.active()) |term| term.id else 0,11=>paletteIMEBaseGeneration(self),
        17=>if(projected) |p| paletteIMEHash(p.text()) else 0,18=>if(projected) |p| p.text().len else 0,
        19=>if(projected) |p| p.selectedRange().?.location else s.query_len,
        27=>@intFromBool(std.mem.eql(u8,key,"overview.title")),
        30=>paletteIMEHash(app_session_mod.termLabel(pane_ops.activePane(self).activeTerm())),31=>self.tabs.items.len,33=>self.app_window.active_tab,
        38=>if(projectGlyphAdvance(self,"한")) |v| @intFromFloat(@round(v*1000)) else 0,
        39=>if(projectGlyphAdvance(self,"韓")) |v| @intFromFloat(@round(v*1000)) else 0,
        40=>paletteIMEHash(key),else=>0,
    };
}
