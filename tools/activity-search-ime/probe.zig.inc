// Private-copy fixture arranges an isolated transcript; text edits and body submit use real HID.
var palette_ime_observed_session: ?*AppSession = null;
pub fn observePaletteIME(self: *AppSession) void {
    if (std.c.getenv("MARU_PALETTE_IME") != null and self.dock_initialized) palette_ime_observed_session = self;
}
fn paletteIMEHash(bytes: []const u8) u64 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.mem.readInt(u64,digest[0..8],.little);
}
fn paletteIMEBaseGeneration(self: *AppSession) u64 {
    const term = pane_ops.activePane(self).activeTerm();
    term.surface.lockCore(self.io); defer term.surface.unlockCore(self.io);
    return term.surface.core.observerGeneration();
}
export fn maru_address_fixture_start(mode: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    if (self.tabs.items.len != 1) return 0;
    if (mode == 1) {
        if (!self.agent_activity.built or self.agent_activity.count() != 1) return 0;
        self.agent_activity.key_focus = true;
        _ = @import("agent_activity.zig").focusSearch(self);
        return 1;
    }
    if (mode != 0) return 0;
    const raw = std.c.getenv("MARU_ACTIVITY_IME_FIXTURE") orelse return 0;
    const term = pane_ops.activePane(self).activeTerm();
    const slot = @import("agent.zig").primaryHookSlot(self, term);
    _ = slot.image_source.set(std.mem.span(raw));
    if (!std.mem.eql(u8,slot.image_source.path(),std.mem.span(raw))) return 0;
    self.dock.presented = true; self.dock.collapsed = false; self.dock.side = .right;
    if (self.dock.view != .agent_activity) dock_ops.setDockView(self,.agent_activity) else @import("agent_activity.zig").refresh(self,false);
    const ops = @import("agent_activity.zig");
    self.agent_activity.key_focus = true;
    ops.setFilter(self,.all);
    if (self.agent_activity.search.query.items.len != 0 or self.agent_activity.search.preedit.items.len != 0) _ = ops.handleSearchKey(self,.{.key=.escape});
    _ = ops.focusSearch(self);
    self.metal_dirty = true;
    return 1;
}
fn activityGlyphAdvance(self: *AppSession, bytes: []const u8) u64 {
    var buf: [64]u8 = undefined;
    const line = maru.chrome.components.activity_search_ime.line(&buf,"",.{.text=bytes,.caret=bytes.len},"",64);
    return @intFromFloat(@round(@as(f64,@floatFromInt(line.caret_cols*self.cell_width_px))*1000000.0/@as(f64,@floatFromInt(self.scale_milli))));
}
fn projectGlyphAdvance(self: *AppSession, bytes: []const u8) ?f64 {
    if (self.scale_milli == 0) return null;
    return @as(f64, @floatFromInt(activityGlyphAdvance(self, bytes))) / 1000;
}
export fn maru_palette_ime_witness(field: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    const s = &self.agent_activity;
    if(field>=12 and field<=15) {
        const content=dock_ops.dockGeometry(self).tree_content;
        return switch(field){12=>content.x,13=>content.y,14=>content.w,15=>self.cell_height_px,else=>unreachable};
    }
    const p = @import("chrome_ime.zig").projection(self);
    return switch(field){
        0=>1,1,28=>@intFromBool(s.search_active),2=>@intFromBool(self.inputFocus()==.agent_activity_search),
        3=>@import("chrome_ime.zig").generation(self) orelse 0,
        4=>s.search.query.items.len,5=>paletteIMEHash(s.search.query.items),6=>s.search.preedit.items.len,7=>paletteIMEHash(s.search.preedit.items),
        8=>@intFromBool(s.body.query.items.len!=0 or s.body.awaiting!=0 or s.body.answered),9=>self.total_terminal_input_bytes,
        10=>if(self.app_window.active()) |t| t.id else 0,11=>paletteIMEBaseGeneration(self),
        17=>if(p) |v| paletteIMEHash(v.text()) else 0,18=>if(p) |v| v.text().len else 0,
        19=>if(p) |v| v.selectedRange().?.location else 0,
        27=>s.shown_label_matches,30=>if(s.all_labels.items.len > 0) paletteIMEHash(s.all_labels.items[0].text()) else 0,31=>self.tabs.items.len,33=>self.app_window.active_tab,
        38=>activityGlyphAdvance(self,"한"),39=>activityGlyphAdvance(self,"韓"),40=>paletteIMEHash(s.body.query.items),
        41=>@intFromBool(s.built and s.count()==1),42=>@intFromBool(s.body.answered),43=>s.shown_body_matches,
        44=>s.body.read_bytes,45=>@intFromBool(s.key_focus),46=>s.all_hits.items.len,47=>@intFromBool(s.built),else=>0,
    };
}
export fn maru_address_pointer_rect(kind: u32,out:[*]f64) u32 {
    const self=palette_ime_observed_session orelse return 0;
    if(kind!=2) return 0;
    const leaf=pane_ops.activeLeafRect(self) orelse return 0;
    const r=pane_ops.paneGeometry(self,leaf).grid;
    out[0]=@floatFromInt(r.x);out[1]=@floatFromInt(r.y);out[2]=@floatFromInt(r.w);out[3]=@floatFromInt(r.h);return 1;
}
export fn maru_address_pointer_quartz(ptr: [*]const u8, length: usize, out: [*]f64) u32 {
    if (length == 0 or length > 16384) return 0;
    const self = palette_ime_observed_session orelse return 0;
    const Input = struct { anchor_appkit: AddressEvidence.Rect, displays: []const AddressEvidence.DisplayTranscript };
    var parsed = std.json.parseFromSlice(Input, self.allocator, ptr[0..length], .{}) catch return 0;
    defer parsed.deinit();
    const result = AddressEvidence.appKitToQuartz(parsed.value.anchor_appkit, parsed.value.displays) catch return 0;
    out[0] = result.rect.x;
    out[1] = result.rect.y;
    out[2] = result.rect.w;
    out[3] = result.rect.h;
    return 1;
}
