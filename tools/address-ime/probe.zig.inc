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

const address_fixture_web = @import("web.zig");
var address_pointer_browser: ?u64 = null;
var address_pointer_terminal: ?u64 = null;
fn addressPointerMode() bool {
    const raw = std.c.getenv("MARU_ADDRESS_POINTER") orelse return false;
    return std.mem.eql(u8, std.mem.span(raw), "1");
}
export fn maru_address_fixture_start(mode: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    if (addressPointerMode()) {
        // Arrange topology/readonly navigation metadata only. All editing and
        // focus changes after arrangement must arrive through actual CGEvents.
        if (mode == 1) return 0;
        if (mode == 2) {
            const sid = address_pointer_browser orelse return 0;
            address_fixture_web.setWebNavState(self, sid, false, false, "https://a.invalid/😀/z");
            self.metal_dirty = true;
            return sid;
        }
        if (address_pointer_browser) |sid| return sid;
        address_pointer_terminal = pane_ops.activePane(self).activeTerm().surfaceId();
        pane_ops.splitActivePane(self, .horizontal) catch return 0;
        const sid = address_fixture_web.createAdoptedWebTermInActivePane(self) catch return 0;
        address_pointer_browser = sid;
        return sid;
    }
    if (mode == 1) {
        address_fixture_web.cancelAddrEdit(self, false);
        self.focusTerm(0);
        self.metal_dirty = true;
        return 1;
    }
    const sid = if (self.addr_edit) |current| current else address_fixture_web.createAdoptedWebTermInActivePane(self) catch return 0;
    address_fixture_web.enterAddrEdit(self, sid, "https://a.invalid/😀/z");
    self.addr_field.caret = "https://a.invalid/".len;
    self.addr_field.selection = .{ .anchor = self.addr_field.caret, .focus = self.addr_field.caret + "😀".len };
    return sid;
}
export fn maru_palette_ime_witness(field: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    const state = &self.addr_field;
    if (field >= 12 and field <= 15) {
        const pb = if (addressPointerMode()) addressPointerBar(self) orelse return 0 else pane_ops.addrEditPaneBar(self) orelse return 0;
        return switch (field) {
            12 => pb.full.x,
            13 => pb.full.y + pb.full.h,
            14 => pb.full.w,
            15 => pb.full.h,
            else => unreachable,
        };
    }
    const projected = @import("chrome_ime.zig").projection(self);
    return switch (field) {
        0 => 1,
        1 => @intFromBool(self.addr_edit != null),
        2 => @intFromBool(self.inputFocus() == .addr_edit),
        3 => @import("chrome_ime.zig").generation(self) orelse 0,
        4 => state.text.items.len,
        5 => paletteIMEHash(state.text.items),
        6 => state.preedit.items.len,
        7 => paletteIMEHash(state.preedit.items),
        8 => @intFromBool(self.addr_navigate_pending != null),
        9 => self.total_terminal_input_bytes,
        10 => if (self.app_window.active()) |term| term.id else 0,
        11 => blk: {
            var term = pane_ops.activePane(self).terms.items[0];
            if (addressPointerMode()) {
                var found = false;
                for (tab_ops.activeTab(self).panes.items) |pane| {
                    for (pane.terms.items) |candidate| {
                        if (candidate.surfaceId() == address_pointer_terminal) {
                            term = candidate;
                            found = true;
                        }
                    }
                }
                if (!found) break :blk std.math.maxInt(u64);
            }
            term.surface.lockCore(self.io);
            defer term.surface.unlockCore(self.io);
            break :blk term.surface.core.observerGeneration();
        },
        17 => if (projected) |p| paletteIMEHash(p.text()) else 0,
        18 => if (projected) |p| p.text().len else 0,
        19 => state.caret,
        20 => if (state.selection) |selection| selection.lo() else state.caret,
        21 => if (state.selection) |selection| selection.hi() else state.caret,
        22 => self.cell_width_px,
        23 => @as(u64, app_session_mod.nav_button_count) * app_session_mod.nav_button_w,
        24 => address_pointer_terminal orelse 0,
        25 => chrome.components.text_field.displayCols("https://a.invalid/"),
        26 => chrome.components.text_field.displayCols("😀"),
        else => 0,
    };
}
const AddressEvidence = @import("../session_host/ime_candidate_evidence.zig");
const AddressRawSnapshot = struct {
    search: ?AddressEvidence.SearchState = null,
    app_captures: []const AddressEvidence.AppCapture = &.{},
    windows: []const AddressEvidence.Window,
    counters: AddressEvidence.Counters,
    anchor_appkit: AddressEvidence.Rect,
    displays: []const AddressEvidence.DisplayTranscript,
};
const AddressRawRow = struct { before: AddressRawSnapshot, opened: AddressRawSnapshot, closed: AddressRawSnapshot };
export fn maru_address_validate_windows(ptr: [*]const u8, length: usize) u32 {
    if (length == 0 or length > 1048576) return 0;
    const self = palette_ime_observed_session orelse return 0;
    var parsed = std.json.parseFromSlice([]AddressRawRow, self.allocator, ptr[0..length], .{ .ignore_unknown_fields = false }) catch return 0;
    defer parsed.deinit();
    if (parsed.value.len != 5) return 0;
    var candidates: [5]AddressEvidence.Candidate = undefined;
    for (parsed.value, 0..) |row, index| {
        if (row.before.app_captures.len != 0 or row.closed.app_captures.len != 0) return 0;
        candidates[index] = AddressEvidence.reduceWindowTriplet(std.c.getpid(), .{
            .app_captures = row.opened.app_captures,
            .before = row.before.windows, .opened = row.opened.windows, .closed = row.closed.windows,
            .before_counters = row.before.counters, .opened_counters = row.opened.counters, .closed_counters = row.closed.counters,
        }) catch |err| {
            std.debug.print("address_candidate_window row={d} error={s}\n", .{index, @errorName(err)});
            return 0;
        };
        const anchor = AddressEvidence.appKitToQuartz(row.before.anchor_appkit, row.before.displays) catch return 0;
        const opened = AddressEvidence.appKitToQuartz(row.opened.anchor_appkit, row.opened.displays) catch return 0;
        const closed = AddressEvidence.appKitToQuartz(row.closed.anchor_appkit, row.closed.displays) catch return 0;
        if (!std.meta.eql(anchor, opened) or !std.meta.eql(anchor, closed)) return 0;
    }
    _ = AddressEvidence.validateSeries(&candidates) catch |err| {
        std.debug.print("address_candidate_series error={s}\n", .{@errorName(err)});
        return 0;
    };
    return 1;
}


fn addressPointerBar(self: *AppSession) ?AppSession.PaneBar {
    const sid = address_pointer_browser orelse return null;
    for (tab_ops.activeTab(self).panes.items) |pane| {
        if (pane.activeTerm().surfaceId() == sid) return pane_ops.paneBarForLeaf(self, pane);
    }
    return null;
}

// Geometry is read from the same layout as paint/hit-test, never written to the field.
export fn maru_address_pointer_rect(kind: u32, out: [*]f64) u32 {
    const self = palette_ime_observed_session orelse return 0;
    if (!addressPointerMode()) return 0;
    if (kind == 1) {
        const pb = addressPointerBar(self) orelse return 0;
        out[0] = @floatFromInt(pb.full.x);
        out[1] = @floatFromInt(pb.full.y + pb.full.h);
        out[2] = @floatFromInt(pb.full.w);
        out[3] = @floatFromInt(pb.full.h);
        return 1;
    }
    if (kind != 2) return 0;
    var leaves: std.ArrayList(app_session_mod.PaneTree.LeafRect) = .empty;
    defer leaves.deinit(self.allocator);
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaves) catch return 0;
    for (leaves.items) |leaf| {
        if (leaf.leaf.activeTerm().surfaceId() != address_pointer_terminal) continue;
        const rect = pane_ops.paneGeometry(self, leaf.rect).grid;
        out[0] = @floatFromInt(rect.x);
        out[1] = @floatFromInt(rect.y);
        out[2] = @floatFromInt(rect.w);
        out[3] = @floatFromInt(rect.h);
        return 1;
    }
    return 0;
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
