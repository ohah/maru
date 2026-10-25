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

var project_fixture_ready = false;
var project_fixture_root: [std.fs.max_path_bytes]u8 = undefined;
var project_fixture_root_len: usize = 0;
fn projectFixtureField() usize {
    const raw = std.c.getenv("MARU_PROJECT_FIELD") orelse return 0;
    return std.fmt.parseInt(usize, std.mem.span(raw), 10) catch 99;
}
fn projectFixtureHash(self: *AppSession) u64 {
    if (!project_fixture_ready) return 0;
    const root = project_fixture_root[0..project_fixture_root_len];
    const dir = std.Io.Dir.cwd().openDir(self.io, root, .{}) catch return 0;
    defer dir.close(self.io);
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(self.allocator);
    for ([_][]const u8{ "한", "韓" }) |name| {
        const bytes = dir.readFileAlloc(self.io, name, self.allocator, .limited(4096)) catch return 0;
        defer self.allocator.free(bytes);
        combined.appendSlice(self.allocator, bytes) catch return 0;
    }
    return paletteIMEHash(combined.items);
}
export fn maru_address_fixture_start(mode: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    const which = projectFixtureField();
    if (which >= 4) return 0;
    if (mode == 1) return @intFromBool(self.inputFocus() == .terminal);
    if (mode != 0) return 0;
    if (!project_fixture_ready) {
        const run = std.mem.span(std.c.getenv("MARU_PALETTE_IME") orelse return 0);
        var scratch: [std.fs.max_path_bytes]u8 = undefined;
        const path = std.fmt.bufPrint(&scratch, "{s}/ime-search-root", .{run}) catch return 0;
        std.Io.Dir.cwd().createDirPath(self.io, path) catch return 0;
        const dir = std.Io.Dir.cwd().openDir(self.io, path, .{ .iterate = true }) catch return 0;
        defer dir.close(self.io);
        for ([_][]const u8{ "한", "韓" }) |name| dir.writeFile(self.io, .{ .sub_path = name, .data = "한 한 韓 韓" }) catch return 0;
        project_fixture_root_len = dir.realPath(self.io, &project_fixture_root) catch return 0;
        const root = project_fixture_root[0..project_fixture_root_len];
        self.file_tree.replaceExplicitRoots(&.{root}) catch return 0;
        var metadata: std.posix.Stat = undefined;
        if (std.c.fstat(dir.handle, &metadata) != 0) return 0;
        if (!self.file_tree.pinRootIdentity(root, .{ .device = @intCast(metadata.dev), .inode = @intCast(metadata.ino), .kind = 2 })) return 0;
        self.editor_project_search_watch_generation = self.file_tree.rootGeneration();
        project_fixture_ready = true;
    }
    const search_dock = @import("editor/search/dock.zig");
    search_dock.open(self);
    search_dock.cancel(self);
    const state = &self.editor_search;
    for (&state.fields, &state.ime_models) |*field, *model| {
        field.clear();
        model.invalidate(self.allocator);
    }
    state.expanded = true;
    state.replacing = true;
    state.setFocused(0); // All later field movement is actual external Tab.
    if (which != 0) state.fields[0].setText(self.allocator, "한") catch return 0;
    search_dock.changed(self);
    self.metal_dirty = true;
    return 1;
}
export fn maru_palette_ime_witness(field: u32) u64 {
    const self = palette_ime_observed_session orelse return 0;
    const search_dock = @import("editor/search/dock.zig");
    const state = &self.editor_search;
    const index = state.focused orelse 0;
    if (index >= 4) return 0;
    const input = &state.fields[index];
    if (field >= 12 and field <= 15) {
        if (!search_dock.publish(self)) return 0;
        const tree: maru.chrome.ui.tree.UiRectTree = .{ .entries = state.entries.items, .generation = state.published_generation };
        const rect = tree.entries[tree.find(maru.chrome.components.project_search.build.fieldId(index)) orelse return 0].rect;
        return switch (field) { 12 => @intFromFloat(@max(0, rect.x)), 13 => @intFromFloat(@max(0, rect.y)), 14 => @intFromFloat(rect.width), 15 => @intFromFloat(rect.height), else => unreachable };
    }
    const projected = @import("chrome_ime.zig").projection(self);
    return switch (field) {
        0 => 1,
        1 => @intFromBool(state.focused != null),
        2 => @intFromBool(self.inputFocus() == .project_search),
        3 => @import("chrome_ime.zig").generation(self) orelse 0,
        4 => input.text.items.len,
        5 => paletteIMEHash(input.text.items),
        6 => input.preedit.items.len,
        7 => paletteIMEHash(input.preedit.items),
        8 => @intFromBool(state.batch.active()),
        9 => self.total_terminal_input_bytes,
        10 => if (self.app_window.active()) |term| term.id else 0,
        11 => paletteIMEBaseGeneration(self),
        17 => if (projected) |p| paletteIMEHash(p.text()) else 0,
        18 => if (projected) |p| p.text().len else 0,
        19 => input.caret + (input.preedit_caret orelse input.preedit.items.len),
        27 => state.result.model.matches,
        28 => @intFromBool(self.dock.presented and !self.dock.collapsed),
        29 => state.focused orelse 99,
        30 => projectFixtureHash(self),
        31 => 30,
        32 => @intFromBool(state.result.phase == .composing),
        33 => @intFromBool(state.result.phase == .complete),
        34 => @intFromBool(state.result.identity != null),
        35 => state.result.generation,
        36 => paletteIMEHash(state.fields[0].text.items),
        37 => state.fields[0].text.items.len,
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
