// Private fixture setup and read-only witnesses. All text edits use the external HID relay.
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
    const term=pane_ops.activePane(self).activeTerm();
    term.surface.lockCore(self.io); defer term.surface.unlockCore(self.io);
    return term.surface.core.observerGeneration();
}
var recovery_fixture_ready = false;
var recovery_fixture_initial_terms: usize = 0;
export fn maru_address_fixture_start(mode: u32) u64 {
    const self=palette_ime_observed_session orelse return 0;
    if(!self.surface_initialized or self.tabs.items.len!=1) return 0;
    const term=pane_ops.activePane(self).activeTerm();
    if(term.kind!=.editor or term.rt.editor_syntax.pending) return 0;
    const doc=term.rt.editorDocument().opened orelse return 0;
    if(doc.file.revision!=0) return 0;
    if(mode==1) return @intFromBool(self.chrome_host.recovery_picker.open and self.editor_recovery.catalog != null and self.editor_recovery.catalog.?.complete and self.editor_recovery.shown.items.len==2);
    if(mode!=0) return 0;
    if(term.rt.editor_selection==null) term.rt.editor_selection=maru.session.editor.selection.Selection.at(0);
    if(!recovery_fixture_ready) {
        recovery_fixture_initial_terms = pane_ops.activePane(self).terms.items.len;
        const root=std.mem.span(std.c.getenv("MARU_EDITOR_BACKUP_ROOT") orelse return 0);
        const home=std.mem.span(std.c.getenv("HOME") orelse return 0);
        // The private runner owns this HOME and root. Refuse any fallback to user backups.
        const expected=std.fmt.allocPrint(self.allocator,"{s}/backups",.{home}) catch return 0;
        defer self.allocator.free(expected);
        if(!std.mem.eql(u8,root,expected) or !std.mem.startsWith(u8,home,"/private/tmp/maru-palette-live-") and !std.mem.startsWith(u8,home,"/tmp/maru-palette-live-")) return 0;
        const store=@import("editor/recovery_store.zig");
        for([_] []const u8{"한","韓"},0..) |word,i| {
            const path=std.fmt.allocPrint(self.allocator,"{s}/{s}.txt",.{home,word}) catch return 0;
            defer self.allocator.free(path);
            const owner=store.Owner.create(self.allocator,self.io,.{.bytes=@splat(@as(u8,@intCast(80+i)))}) catch return 0;
            defer owner.release();
            owner.write(root,path,null,if(i==0) "recovered han\n" else "recovered hanja\n") catch return 0;
        }
        recovery_fixture_ready=true;
    }
    self.dismissMessageOverlays();
    @import("editor/recovery.zig").open(self);
    self.metal_dirty=true;
    return @intFromBool(self.chrome_host.recovery_picker.open);
}
fn projectGlyphAdvance(self:*AppSession,bytes:[]const u8) ?f64 {
    if(self.scale_milli==0) return null;
    return @as(f64,@floatFromInt(maru.chrome.components.overlay_input.displayCols(bytes)*self.cell_width_px))*1000/@as(f64,@floatFromInt(self.scale_milli));
}
export fn maru_palette_ime_witness(field:u32) u64 {
    const self=palette_ime_observed_session orelse return 0;
    if(self.tabs.items.len==0) return 0;
    const term=pane_ops.activePane(self).activeTerm();
    const doc=term.rt.editorDocument().opened orelse return 0;
    const s=&self.chrome_host.recovery_picker;
    if(field>=12 and field<=15) {
        const lay=chrome.components.overlay_input.panelLayout(self.buildChromeProps()) orelse return 0;
        return switch(field){12=>@intCast(@max(0,lay.x)),13=>@intCast(@max(0,lay.y)),14=>lay.panel_cols*lay.cw,15=>lay.ch,else=>unreachable};
    }
    const p=@import("chrome_ime.zig").projection(self);
    return switch(field){
        0=>@intFromBool(term.kind==.editor and !term.rt.editor_syntax.pending),
        1,28=>@intFromBool(s.open),2=>@intFromBool(self.inputFocus()==.recovery_picker),3=>@import("chrome_ime.zig").generation(self) orelse 0,
        4=>s.input.query.items.len,5=>paletteIMEHash(s.input.query.items),6=>s.input.preedit.items.len,7=>paletteIMEHash(s.input.preedit.items),
        8,43=>pane_ops.activePane(self).terms.items.len - recovery_fixture_initial_terms,9=>self.total_terminal_input_bytes,10=>self.app_window.active().?.id,11=>paletteIMEBaseGeneration(self),
        17=>if(p) |v| paletteIMEHash(v.text()) else 0,18=>if(p) |v| v.text().len else 0,19=>if(p) |v| v.selectedRange().?.location else 0,
        27=>self.editor_recovery.shown.items.len,30=>paletteIMEHash(doc.file.content),31=>self.tabs.items.len,33=>self.app_window.active_tab,
        38=>if(projectGlyphAdvance(self,"한")) |v| @intFromFloat(@round(v*1000)) else 0,
        39=>if(projectGlyphAdvance(self,"韓")) |v| @intFromFloat(@round(v*1000)) else 0,
        40=>doc.file.revision,42=>if(term.rt.editor_selection) |v| v.focus else std.math.maxInt(u64),44=>doc.file.content.len,
        46=>self.editor_recovery.shown.items.len,47=>@intFromBool(!term.rt.editor_syntax.pending),
        51=>@intFromBool(recovery_fixture_ready),
        52=>@intFromBool(term.rt.editorDocument().path==null and doc.isDirty()),
        50=>std.mem.indexOf(u8,doc.file.content,"recovered hanja\n") orelse 0,else=>0,
    };
}
