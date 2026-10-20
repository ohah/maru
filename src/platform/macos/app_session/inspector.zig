//! Main-thread live diagnostic adapter. Only this collector touches product state;
//! the Metal panel and CLI serialize the same owned snapshot.
const std = @import("std");
const maru = @import("maru");
const root = @import("../app_session.zig");
const AppSession = root.AppSession;
const Term = root.Term;
const term_ops = @import("term.zig");
const pane_ops = @import("pane.zig");
const git = @import("git.zig");
const agent = @import("agent.zig");
const model = maru.session.inspector;
pub const layout = model.layout;
const panel = maru.chrome.components.inspector;
pub const picker = @import("inspector_picker.zig");

pub const State = struct {
    picking: bool = false,
    picker_hover: ?maru.chrome.ui.inspection.Key = null,
    picker_selected: ?maru.chrome.ui.inspection.Key = null,
    picker_capture: bool = false,
    collapsed: [512]maru.chrome.ui.inspection.Key = undefined,
    collapsed_len: usize = 0,
    window_id: ?u64 = null,
    rich_text: ?root.MeasuredTextCache = null,
    presentation: layout.State = .{},
    resizing: bool = false,
    hovered: ?u64 = null,
    input_focused: bool = false,
    window_focused: bool = false,
    copy_requested: bool = false,
    paused: bool = false,
    pinned: bool = false,
    anonymize_exports: bool = true,
    target: ?u64 = null,
    tab: panel.Tab = .overview,
    offset: usize = 0,
    selected_field: [128]u8 = undefined,
    selected_field_len: usize = 0,
    query: [128]u8 = undefined,
    query_len: usize = 0,
    preedit: [128]u8 = undefined,
    preedit_len: usize = 0,
    last_poll: u64 = 0,
    refresh: bool = true,
    json: ?[]u8 = null,
    status: []const u8 = "",
    pub fn deinit(self: *State, allocator: std.mem.Allocator) void {
        root.MeasuredTextCache.clear(&self.rich_text, allocator);
        if (self.json) |j| allocator.free(j);
        self.json = null;
    }
};

pub fn capture(self: *AppSession, term: *Term, a: std.mem.Allocator, window: ?u64) !model.Snapshot {
    term_ops.refreshTermObservation(self, term, true, true);
    const remote = root.termCwdIsRemote(term);
    var local: [std.fs.max_path_bytes]u8 = undefined;
    const decision: model.CwdDecision = if (remote) git.remoteCwdDecision(self, term) else blk: {
        const cwd = git.termCwd(self, term, &local) orelse break :blk .{ .path = "", .source = .unknown, .reason = .unavailable };
        const osc = term.rt.observation.cwd.items.len != 0;
        break :blk .{ .path = cwd, .source = if (osc) .osc7 else .kernel, .reason = if (osc) .no_hook else .kernel_fallback };
    };
    // The target decision owns the actual validation; diagnostics must not imitate it.
    var dest: [git.max_remote_dest_bytes]u8 = undefined;
    var ctl: [std.fs.max_path_bytes]u8 = undefined;
    var cwd: [std.fs.max_path_bytes]u8 = undefined;
    const scm = git.remoteScmDecisionFor(self, term, &dest, &ctl, &cwd);
    const o = &term.rt.observation;
    const slot = agent.primaryHookSlot(self, term);
    const now = self.awakeMs();
    const available = o.availability != .unavailable;
    var ti: usize = 0;
    var pi: usize = 0;
    for (self.tabs.items, 0..) |tab, t| for (tab.panes.items, 0..) |pane, p| for (pane.terms.items) |entry| {
        if (entry == term) {
            ti = t;
            pi = p;
        }
    };
    const modes = [_]u64{ @intFromBool(o.alt_active), @intFromBool(o.app_cursor_keys), @intFromBool(o.app_keypad), o.kitty_flags, @intFromBool(o.alternate_scroll), o.mouse_tracking_mode, @intFromBool(o.bracketed_paste), @intCast(@backingInt(o.semantic_state)) };
    term.rt.inspector_history.sample(now, .{
        .cwd = std.hash.Wyhash.hash(std.hash.Wyhash.hash(0, o.cwd_host.items), decision.path),
        .ssh = std.hash.Wyhash.hash(@intFromBool(o.ssh_remote_dest_present), o.ssh_remote_dest.items),
        .modes = std.hash.Wyhash.hash(0, std.mem.asBytes(&modes)),
        .size = (@as(u64, o.size.cols) << 32) | o.size.rows,
        .availability = @intCast(@backingInt(o.availability)),
        .revision = o.revision,
    });
    var snapshot: model.Snapshot = .{
        .overview = .{ .surface_id = term.surfaceId(), .window = window, .tab = ti, .pane = pi, .title = try a.dupe(u8, root.termLabel(term)), .backend = if (term.surface.remote != null) .session_host else .in_process, .observation = @tagName(o.availability), .observation_revision = o.revision, .observer_generation = o.observer_generation, .sampled_at_ms = now, .terminated = term.rt.terminated },
        .path = .{ .remote = remote, .selected_cwd = try a.dupe(u8, decision.path), .source = decision.source, .reason = decision.reason, .osc7_cwd = try a.dupe(u8, o.cwd.items), .osc7_host = try a.dupe(u8, o.cwd_host.items), .hook_cwd = try a.dupe(u8, slot.cwd.text()), .hook_host = try a.dupe(u8, slot.cwd.host()), .hook_age_ms = if (slot.cwd.isEmpty()) null else now -| slot.cwd.seen_ms, .hook_fresh = slot.cwd.fresh(now), .hook_host_matches = slot.cwd.hostMatches(git.termMachineKey(term)), .hook_slot = if (self.remote_agent_panes.latestFor(term.surfaceId()) != null) "latest_remote_pane_event" else "terminal", .ssh_destination = try a.dupe(u8, git.termRemoteDest(term)), .scm_target = if (scm.target) |r| try a.dupe(u8, r.cwd) else "", .scm_reason = if (remote) @tagName(scm.reason) else "local_repository_selection", .explorer_mode = if (self.remote_explorer.active) "remote" else "local", .explorer_root = if (self.remote_explorer.active) try a.dupe(u8, self.remote_explorer.root.items) else if (self.file_tree.rootAt(0)) |r| try a.dupe(u8, r) else "", .explorer_destination = if (self.remote_explorer.active) try a.dupe(u8, self.remote_explorer.dest.items) else "", .explorer_rows_remote = self.file_tree_rows_remote },
        .terminal = .{ .availability = @tagName(o.availability), .cols = o.size.cols, .rows = o.size.rows, .semantic_prompt = @tagName(o.semantic_state), .alternate_screen = o.alt_active, .application_cursor_keys = o.app_cursor_keys, .application_keypad = o.app_keypad, .kitty_flags = o.kitty_flags, .alternate_scroll = o.alternate_scroll, .mouse_tracking = o.mouse_tracking, .mouse_tracking_mode = o.mouse_tracking_mode, .bracketed_paste = o.bracketed_paste, .foreground_available = o.foreground_available, .foreground_pgid = o.foreground_pgid, .core_detail_support = if (term.surface.remote != null) "cursor from host screen; scroll region not transported" else "local core" },
        .events = .{ .protocol_support = if (term.surface.remote != null) "host shell-event transport unsupported; sampled metadata only" else "active terminal OSC 7/133 drain plus sampled metadata; SSH changes are sampled, not raw OSC 5379", .evicted = term.rt.inspector_history.next - term.rt.inspector_history.count, .items = try term.rt.inspector_history.copy(a) },
    };
    if (term.surface.remote != null) {
        if (root.app_remote_backend) |*backend| if (backend.runtimeIdFor(term.rt.handle)) |hex| {
            snapshot.overview.runtime_id = try a.dupe(u8, &hex);
        };
    }
    if (available and term.rt.live_initialized and !term.rt.terminated) {
        term.surface.lockCore(self.io);
        const screen = term.surface.renderSnapshot();
        snapshot.terminal.cursor = .{ .row = screen.cursor.row, .col = screen.cursor.col };
        if (term.surface.remote == null) snapshot.terminal.scroll_region = .{ .top = term.surface.core.scroll_top, .bottom = term.surface.core.scroll_bottom };
        term.surface.unlockCore(self.io);
    }
    snapshot.elements = try picker.snapshot(self, a, window);
    try model.addFieldInfo(a, &snapshot);
    return snapshot;
}

// The native owner token is the same membership identity used by the CLI collector.
// Binding never rewrites a paused diagnostic sample; Refresh owns that transition.
pub fn setWindowId(self: *AppSession, id: u64) void {
    self.inspector.window_id = if (id == 0) null else id;
    if (visible(self) and !self.inspector.paused) {
        self.inspector.refresh = true;
        poll(self);
    }
}

fn target(self: *AppSession) ?*Term {
    const id = self.inspector.target orelse return null;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (term.kind == .terminal and term.surfaceId() == id) return term;
    };
    return null;
}

/// The inspector owns its own presentation, independent from the ordinary dock.
pub fn visible(self: *const AppSession) bool {
    return self.chrome_host.inspector.open and !self.chrome_minimal;
}
pub fn geometry(self: *const AppSession) layout.Geometry {
    const available: maru.session.SplitRect = .{
        .x = self.sidebar_width_px,
        .y = self.titlebar_strip_px,
        .w = self.backing_width_px -| self.sidebar_width_px,
        .h = self.backing_height_px -| self.titlebar_strip_px -| @import("status_bar.zig").statusBarHeightPx(self),
    };
    if (!visible(self)) return layout.geometry(.{}, available, self.scale_milli);
    var state = self.inspector.presentation;
    state.open = true;
    return layout.geometry(state, available, self.scale_milli);
}
pub fn detached(self: *const AppSession) bool {
    return visible(self) and self.inspector.presentation.placement == .window;
}
fn renderScale(self: *const AppSession) u32 {
    return if (detached(self)) self.inspector.presentation.window_scale else self.scale_milli;
}
pub fn setPlacement(self: *AppSession, placement: layout.Placement) void {
    if (!self.tryCommitComposition()) return;
    self.inspector.resizing = false;
    self.inspector.presentation.placement = placement;
    if (placement != .window) self.inspector.window_focused = false;
    self.chrome_host.inspector.open = true;
    relayout(self);
}
fn relayout(self: *AppSession) void {
    for (self.tabs.items) |tab| pane_ops.resizeTabPanes(self, tab);
    pane_ops.recomputeActivePaneRect(self);
    self.last_resize_size = null;
    self.metal_dirty = true;
}
pub fn resizeWindow(self: *AppSession, w: u32, h: u32, scale: u32) void {
    self.inspector.presentation.window_width_px = std.math.clamp(w, 160, 16384);
    self.inspector.presentation.window_height_px = std.math.clamp(h, 160, 16384);
    self.inspector.presentation.window_scale = std.math.clamp(scale, 250, 8000);
    self.metal_dirty = true;
}
pub fn dividerContains(self: *const AppSession, x: f64, y: f64) bool {
    if (!visible(self) or detached(self)) return false;
    var r = geometry(self).divider;
    if (r.w == 0 or r.h == 0) return false;
    const slop = 4 * @max(self.scale_milli / 1000, 1);
    if (r.w == 1) {
        const delta = @min(r.x, slop);
        r.x -= delta;
        r.w += delta + slop;
    } else {
        const delta = @min(r.y, slop);
        r.y -= delta;
        r.h += delta + slop;
    }
    return layout.contains(r, x, y);
}
pub fn resizePointer(self: *AppSession, kind: i32, x: f64, y: f64) bool {
    if (!visible(self) or detached(self) or !std.math.isFinite(x) or !std.math.isFinite(y)) return false;
    if (kind == 1) {
        self.inspector.resizing = dividerContains(self, x, y);
        return self.inspector.resizing;
    }
    if (!self.inspector.resizing) return false;
    if (kind == 3) {
        self.inspector.resizing = false;
        return true;
    }
    if (kind != 2) return false;
    const raw = switch (self.inspector.presentation.placement) {
        .left => x - @as(f64, @floatFromInt(self.sidebar_width_px)),
        .right => @as(f64, @floatFromInt(self.backing_width_px)) - x,
        .top => y - @as(f64, @floatFromInt(self.titlebar_strip_px)),
        .bottom => @as(f64, @floatFromInt(self.backing_height_px -| @import("status_bar.zig").statusBarHeightPx(self))) - y,
        .window => return false,
    };
    const points: u32 = @intFromFloat(std.math.clamp(raw * 1000 / @as(f64, @floatFromInt(@max(self.scale_milli, 1))), 80, 8192));
    if (self.inspector.presentation.placement == .left or self.inspector.presentation.placement == .right) self.inspector.presentation.width_pt = points else self.inspector.presentation.height_pt = points;
    relayout(self);
    return true;
}
pub fn ownsInput(self: *const AppSession) bool {
    return visible(self) and (self.inspector.input_focused or (detached(self) and self.inspector.window_focused));
}
pub fn contains(self: *const AppSession, x: f64, y: f64) bool {
    return visible(self) and !detached(self) and layout.contains(geometry(self).content, x, y);
}
pub fn blur(self: *AppSession) void {
    if (!self.inspector.input_focused) return;
    commitPreedit(self);
    self.inspector.input_focused = false;
    self.metal_dirty = true;
}
pub fn releaseWindowFocus(self: *AppSession) void {
    blur(self);
    clearHover(self);
    self.inspector.window_focused = false;
}
pub fn close(self: *AppSession) void {
    picker.cancel(self);
    releaseWindowFocus(self);
    self.inspector.resizing = false;
    self.chrome_host.inspector.open = false;
    relayout(self);
}
pub fn toggle(self: *AppSession) void {
    if (visible(self)) return close(self);
    if (self.chrome_host.confirm.open or !self.tryCommitComposition()) return;
    self.cancelPointerGesture();
    self.chrome_host.inspector.open = true;
    relayout(self);
    self.inspector.input_focused = false;
    self.inspector.refresh = true;
    self.inspector.hovered = null;
    self.inspector.paused = false;
    self.inspector.pinned = false;
    self.inspector.offset = 0;
    poll(self);
    self.metal_dirty = true;
}

pub fn propsFor(self: *AppSession) maru.chrome.ChromeProps {
    var p = self.buildChromeProps();
    const rect = geometry(self).content;
    if (detached(self)) {
        p.metrics.backing_width_px = rect.w;
        p.metrics.backing_height_px = rect.h;
    }
    p.metrics.workspace_present = true;
    p.metrics.workspace_x_px = rect.x;
    p.metrics.workspace_y_px = rect.y;
    p.metrics.workspace_width_px = rect.w;
    p.metrics.workspace_height_px = rect.h;
    return p;
}

pub fn poll(self: *AppSession) void {
    const s = &self.inspector;
    if (!visible(self) or self.tabs.items.len == 0) return;
    const now = self.awakeMs();
    if (!s.refresh and (s.paused or now -| s.last_poll < 250)) return;
    if (!s.pinned and !s.paused and term_ops.activeTermIsTerminal(self)) s.target = pane_ops.activePane(self).activeTerm().surfaceId();
    s.refresh = false;
    s.last_poll = now;
    const term = target(self) orelse {
        s.status = maru.i18n.t(.inspector_target_closed);
        self.metal_dirty = true;
        return;
    };
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const snap = capture(self, term, arena.allocator(), s.window_id) catch {
        s.status = "snapshot allocation failed";
        return;
    };
    const json = model.serialize(self.allocator, snap) catch {
        s.status = "snapshot serialization failed";
        return;
    };
    if (s.json) |old| self.allocator.free(old);
    s.json = json;
    s.status = "";
    self.metal_dirty = true;
}

fn cycle(self: *AppSession, backwards: bool) void {
    var first: ?u64 = null;
    var last: ?u64 = null;
    var previous: ?u64 = null;
    var chosen: ?u64 = null;
    var after = false;
    for (self.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (term.kind != .terminal) continue;
        const id = term.surfaceId();
        if (first == null) first = id;
        last = id;
        if (!backwards and after and chosen == null) chosen = id;
        if (self.inspector.target == id) {
            if (backwards) chosen = previous;
            after = true;
        }
        previous = id;
    };
    self.inspector.target = chosen orelse (if (backwards) last else first);
    self.inspector.pinned = true;
    self.inspector.refresh = true;
    self.inspector.offset = 0;
    poll(self);
}

fn save(self: *AppSession) void {
    const json = copyJson(self);
    if (json.len == 0) return;
    const home_z = std.c.getenv("HOME") orelse return;
    const path = std.fmt.allocPrint(self.allocator, "{s}/.cache/maru/inspector", .{std.mem.span(home_z)}) catch return;
    defer self.allocator.free(path);
    std.Io.Dir.cwd().createDirPath(self.io, path) catch {
        self.inspector.status = maru.i18n.t(.inspector_save_failed);
        return;
    };
    var dir = std.Io.Dir.cwd().openDir(self.io, path, .{}) catch return;
    defer dir.close(self.io);
    var name_buf: [96]u8 = undefined;
    const name = std.fmt.bufPrint(&name_buf, "snapshot-{d}-{d}.json", .{ self.inspector.target orelse 0, std.Io.Clock.real.now(self.io).nanoseconds }) catch return;
    var file = dir.createFile(self.io, name, .{ .exclusive = true, .permissions = .fromMode(0o600) }) catch {
        self.inspector.status = maru.i18n.t(.inspector_save_failed);
        return;
    };
    defer file.close(self.io);
    file.writeStreamingAll(self.io, json) catch {
        self.inspector.status = maru.i18n.t(.inspector_save_failed);
        return;
    };
    self.inspector.status = maru.i18n.t(.inspector_saved);
}

pub fn key(self: *AppSession, e: maru.terminal.KeyEvent) void {
    const s = &self.inspector;
    if (e.event_type == .release) return;
    // Resolve the toggle through config while the filter owns keyboard focus.
    // Repeating the physical chord here would break user overrides and unbinds.
    var encoded: [maru.terminal.input.encoded_key_buffer_len]u8 = undefined;
    const resolved = self.loaded_config.keyBindingResolver().resolve(e, &encoded, .{}) catch return;
    if (resolved == .app_action and resolved.app_action == .toggle_inspector) {
        close(self);
        self.metal_dirty = true;
        return;
    }
    const raw_cp: u21 = if (e.key == .char) e.key.char else 0;
    const cp: u21 = if (raw_cp < 128) std.ascii.toLower(@intCast(raw_cp)) else raw_cp;
    if (e.key == .escape) {
        if (s.query_len != 0) s.query_len = 0 else blur(self);
    } else if (e.modifiers.command and cp == 'w') {
        close(self);
    } else if (e.modifiers.command and cp == 'c') {
        self.pending_clipboard_action = .copy;
    } else if (e.modifiers.command and cp == 's') {
        save(self);
    } else if (e.modifiers.command and cp == 'r') {
        s.refresh = true;
        poll(self);
    } else if (e.key == .tab) {
        s.tab = @fromBackingInt(@intCast((@as(u8, @intCast(@backingInt(s.tab))) + (if (e.modifiers.shift) @as(u8, 4) else @as(u8, 1))) % 5));
        s.offset = 0;
        s.selected_field_len = 0;
    } else if (e.key == .arrow_down or e.key == .page_down) {
        s.offset +|= if (e.key == .page_down) @as(usize, 10) else 1;
    } else if (e.key == .arrow_up or e.key == .page_up) {
        s.offset -|= if (e.key == .page_up) @as(usize, 10) else 1;
    } else if (e.key == .backspace) {
        if (s.query_len > 0) {
            s.query_len -= 1;
            while (s.query_len > 0 and s.query[s.query_len] & 0xc0 == 0x80) s.query_len -= 1;
        }
        s.offset = 0;
    } else if (e.key == .char and !e.modifiers.command and !e.modifiers.control and cp >= 32) {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(raw_cp, &buf) catch return;
        if (s.query_len + len <= s.query.len) {
            @memcpy(s.query[s.query_len..][0..len], buf[0..len]);
            s.query_len += len;
            s.offset = 0;
        }
    }
    self.metal_dirty = true;
}

pub fn scroll(self: *AppSession, delta: f64) void {
    if (!std.math.isFinite(delta)) return;
    if (delta > 0) self.inspector.offset -|= 3 else if (delta < 0) self.inspector.offset +|= 3;
    self.metal_dirty = true;
}

pub fn click(self: *AppSession, x: f64, y: f64) void {
    const p = propsFor(self);
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const filter = panel.caretRectForTab(p, renderScale(self), arena.allocator(), self.inspector.tab);
    if (filter) |r| if (x >= @as(f64, @floatFromInt(r.x)) and y >= @as(f64, @floatFromInt(r.y)) and x < @as(f64, @floatFromInt(r.x)) + @as(f64, @floatFromInt(r.w)) and y < @as(f64, @floatFromInt(r.y)) + @as(f64, @floatFromInt(r.h))) {
        if (!self.tryCommitComposition()) return;
        self.inspector.input_focused = true;
        self.metal_dirty = true;
        return;
    };
    const hit = panel.hit(p, renderScale(self), arena.allocator(), x, y) orelse {
        if (panel.fieldAt(self.inspector.tab, self.inspector.query[0..self.inspector.query_len], self.inspector.offset, self.inspector.json orelse "{}", p, renderScale(self), arena.allocator(), x, y)) |field| {
            if (field.element) |element| {
                picker.select(self, element, field.disclosure);
                return;
            }
            self.inspector.selected_field_len = @min(field.key.len, self.inspector.selected_field.len);
            @memcpy(self.inspector.selected_field[0..self.inspector.selected_field_len], field.key[0..self.inspector.selected_field_len]);
            self.metal_dirty = true;
        }
        return;
    };
    switch (hit) {
        .placement => |placement| setPlacement(self, @fromBackingInt(@as(u3, @intCast(placement)))),
        .picker => picker.toggle(self),
        .privacy => self.inspector.anonymize_exports = !self.inspector.anonymize_exports,
        .tab => |t| {
            self.inspector.tab = t;
            self.inspector.selected_field_len = 0;
            self.inspector.offset = 0;
        },
        .tool => |tool| switch (tool) {
            0 => cycle(self, true),
            1 => cycle(self, false),
            2 => self.inspector.pinned = !self.inspector.pinned,
            3 => {
                self.inspector.paused = !self.inspector.paused;
                if (self.inspector.paused) picker.cancel(self);
            },
            4 => {
                self.inspector.refresh = true;
                poll(self);
            },
            5 => {
                self.inspector.copy_requested = true;
                self.pending_clipboard_action = .copy;
            },
            6 => save(self),
            7 => close(self),
            else => {},
        },
    }
    self.metal_dirty = true;
}

pub fn collectInspectorDraws(self: *AppSession, p: maru.chrome.ChromeProps, tk: *const maru.chrome.Tokens, a: std.mem.Allocator, out: *std.ArrayList(maru.chrome.ChromeDraw)) !void {
    const s = &self.inspector;
    if (!visible(self)) return;
    const query = try std.mem.concat(a, u8, &.{ s.query[0..s.query_len], s.preedit[0..s.preedit_len] });
    try panel.collect(s.tab, @intCast(@backingInt(s.presentation.placement)), s.paused, s.picking, s.pinned, s.anonymize_exports, query, &s.offset, s.status, s.json orelse "{}", p, renderScale(self), tk, a, s.hovered, s.selected_field[0..s.selected_field_len], out);
}

pub fn copyJson(self: *AppSession) []const u8 {
    const json = self.inspector.json orelse return "";
    if (self.copy_buffer.len > 0) self.allocator.free(self.copy_buffer);
    self.copy_buffer = &.{};
    self.copy_buffer = (if (self.inspector.anonymize_exports) model.anonymizeJson(self.allocator, json, .{
        .home = if (std.c.getenv("HOME")) |h| std.mem.span(h) else null,
        .username = if (std.c.getenv("USER")) |u| std.mem.span(u) else null,
    }) else self.allocator.dupe(u8, json)) catch return "";
    return self.copy_buffer;
}

pub fn paste(self: *AppSession, bytes: []const u8) void {
    const s = &self.inspector;
    for (bytes) |c| {
        if (c < 32 or c == 127 or s.query_len == s.query.len) continue;
        s.query[s.query_len] = c;
        s.query_len += 1;
    }
    // Boundaries must remain valid when a paste exceeds the fixed query buffer.
    while (s.query_len > 0 and !std.unicode.utf8ValidateSlice(s.query[0..s.query_len])) s.query_len -= 1;
    s.offset = 0;
    s.selected_field_len = 0;
    self.metal_dirty = true;
}

// Committed text follows InputFocus; marked text stays out of the terminal core.
pub fn setPreedit(self: *AppSession, bytes: []const u8) void {
    const s = &self.inspector;
    var n = @min(bytes.len, s.preedit.len);
    while (n > 0 and !std.unicode.utf8ValidateSlice(bytes[0..n])) n -= 1;
    @memcpy(s.preedit[0..n], bytes[0..n]);
    s.preedit_len = n;
    self.metal_dirty = true;
}
pub fn commitPreedit(self: *AppSession) void {
    const s = &self.inspector;
    paste(self, s.preedit[0..s.preedit_len]);
    s.preedit_len = 0;
}
pub fn caretRect(self: *AppSession) ?maru.chrome.draw.Rect {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    return panel.caretRectForTab(propsFor(self), renderScale(self), arena.allocator(), self.inspector.tab);
}

// Leaving the viewport must clear the painted state as well as the native cursor.
pub fn clearHover(self: *AppSession) void {
    if (!visible(self)) return;
    if (self.inspector.hovered != null) {
        self.inspector.hovered = null;
        self.metal_dirty = true;
    }
}

/// Hover uses the same published control geometry as click and paint.
pub fn hover(self: *AppSession, x: f64, y: f64) root.CursorKind {
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const found = panel.hit(propsFor(self), renderScale(self), arena.allocator(), x, y);
    const picked = if (found == null) panel.fieldAt(self.inspector.tab, self.inspector.query[0..self.inspector.query_len], self.inspector.offset, self.inspector.json orelse "{}", propsFor(self), renderScale(self), arena.allocator(), x, y) else null;
    const id = if (found) |h| h.nodeId() else if (picked) |field| field.id else null;
    if (self.inspector.hovered != id) {
        self.inspector.hovered = id;
        self.metal_dirty = true;
    }
    if (picked) |field| if (field.element != null) return .link;
    return switch (panel.cursorForTab(propsFor(self), renderScale(self), arena.allocator(), x, y, self.inspector.tab)) {
        .arrow => .default,
        .text => .text,
        .hand => .link,
    };
}

/// Reuse the dock's measured text and chrome composition; no modal overlay is emitted.
pub fn collect(self: *AppSession, collected: *std.ArrayList(AppSession.CollectedPane), builder: root.coretext_frame_builder.CoreTextFrameBuilder, colors: root.metal_frame.CellColors) void {
    if (!visible(self)) return;
    var arena = std.heap.ArenaAllocator.init(self.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tokens = self.buildChromeTokens();
    var draws: std.ArrayList(maru.chrome.ChromeDraw) = .empty;
    collectInspectorDraws(self, propsFor(self), &tokens, a, &draws) catch return;
    if (draws.items.len == 0) return;
    const ops = draws.items[0].ops;
    root.chrome_draw_lowering.appendBackgroundQuads(self.allocator, draws.items, &tokens, 0, 0, &self.gpu_quads, root.chrome_draw_lowering.layers.inspector);
    const geometry_key = root.chrome_draw_lowering.richTextFingerprint(ops, &tokens, self.cell_width_px, self.cell_height_px, 0, 0, 0) ^ (@as(u64, renderScale(self)) *% 0x9e3779b185ebca87);
    const face = std.hash.Wyhash.hash(geometry_key, self.appearance.font.family);
    const fingerprint = std.hash.Wyhash.hash(face, self.appearance.font.fallback);
    if (!root.MeasuredTextCache.hit(self.inspector.rich_text, fingerprint)) {
        const artifact = root.chrome_system_text.shapeOps(self.allocator, &self.renderer_state.font_registry, ops, &tokens, self.cell_width_px, .{ .family = self.appearance.font.family, .fallback = self.appearance.font.fallback }, renderScale(self)) catch return;
        root.MeasuredTextCache.store(&self.inspector.rich_text, self.allocator, fingerprint, artifact, 0);
    }
    const cache = &self.inspector.rich_text.?;
    const rect = geometry(self).content;
    self.collectMeasuredTextFromCache(collected, root.chrome_system_text.emptyDrawList(self.allocator, cache.records.len) catch return, cache, builder, .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h }, .{ .inspector = .{ .origin_x = 0, .origin_y = 0, .colors = colors } });
}
