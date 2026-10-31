//! Windows settings event adapter and asynchronous config persistence.
//! UI snapshots borrow config strings from the app-lifetime config arena.
const std = @import("std");
const maru = @import("maru");
const widget = maru.chrome.components.settings;
const edit = maru.app.settings_edit;
const settings_scrollbar = @import("scrollbar.zig");

pub fn candidate(a: std.mem.Allocator, cfg: maru.config.Config, request: edit.Request) !maru.config.Config {
    var next = cfg;
    const key = request.key.slice();
    const value = request.value.slice();
    if (maru.config.schema.setBool(&next, key, false)) {
        const parsed = if (std.mem.eql(u8, value, "true")) true else if (std.mem.eql(u8, value, "false")) false else return error.InvalidValue;
        _ = maru.config.schema.setBool(&next, key, parsed);
    } else if (maru.config.schema.setNumber(&next, key, 0)) {
        const number = std.fmt.parseFloat(f64, value) catch return error.InvalidValue;
        if (!std.math.isFinite(number)) return error.InvalidValue;
        _ = maru.config.schema.setNumber(&next, key, number);
    } else if (try maru.config.schema.enumVariants(a, cfg, key)) |variants| {
        const index = for (variants, 0..) |v, i| {
            if (std.mem.eql(u8, value, v)) break i;
        } else return error.InvalidValue;
        if (!maru.config.schema.setEnumIndex(&next, key, index)) return error.InvalidValue;
    } else {
        // The file parser owns text metadata, including absolute paths and
        // Windows separator normalization. A GUI save must reject its forgiving
        // diagnostics rather than persist a value that reload will discard.
        var diags: std.ArrayList(maru.config.schema.Diag) = .empty;
        defer diags.deinit(a);
        if (!try maru.config.schema.tryParseFor(.windows, a, &next, key, value, &diags, 1) or diags.items.len != 0)
            return error.InvalidValue;
    }
    return next;
}

const Job = struct {
    io: std.Io,
    path: []const u8,
    request: edit.Request,
    cfg: maru.config.Config,
    thread: ?std.Thread = null,
    done: std.atomic.Value(bool) = .init(false),
    failure: ?anyerror = null,
    fn run(self: *Job) void {
        self.write() catch |err| {
            self.failure = err;
        };
        self.done.store(true, .release);
    }
    fn write(self: *Job) !void {
        maru.app.config_write_lock.lock(self.io);
        defer maru.app.config_write_lock.unlock(self.io);
        const a = std.heap.smp_allocator;
        const original = std.Io.Dir.cwd().readFileAlloc(self.io, self.path, a, .limited(1 << 20)) catch |err| switch (err) {
            error.FileNotFound => try a.dupe(u8, ""),
            else => return err,
        };
        defer a.free(original);
        const updated = try maru.config.serialize.updateForKeys(a, original, self.cfg, &.{self.request.key.slice()});
        defer a.free(updated);
        if (updated.len > (1 << 20)) return error.StreamTooLong;
        var atomic = try std.Io.Dir.cwd().createFileAtomic(self.io, self.path, .{ .make_path = true, .replace = true });
        defer atomic.deinit(self.io);
        var buffer: [4096]u8 = undefined;
        var writer = atomic.file.writer(self.io, &buffer);
        try writer.interface.writeAll(updated);
        try writer.flush();
        try atomic.file.sync(self.io);
        try atomic.replace(self.io);
    }
};
pub const Host = struct {
    form: maru.app.settings_form.Form = .{},
    a: std.mem.Allocator,
    config_arena: std.mem.Allocator,
    io: std.Io,
    cfg: *maru.config.Config,
    path: ?[]const u8,
    job: ?*Job = null,
    changed: bool = false,
    // Only a successful explicit save of this row permits irreversible trim.
    scrollback_shrink: ?u32 = null,
    saves: usize = 0,
    save_errors: usize = 0,
    request_errors: usize = 0,
    previews: usize = 0,
    rollbacks: usize = 0,
    preview_generation: ?u64 = null,
    wheel_acc: maru.session.input_math.WheelAccumulator = .{},
    wheel_events: usize = 0,
    scroll_moves: usize = 0,
    scroll_peak: u32 = 0,
    swallow_left_up: bool = false,
    scrollbar: settings_scrollbar.Bar = .{},
    pub fn takeScrollbackShrink(self: *Host) ?u32 {
        const value = self.scrollback_shrink;
        self.scrollback_shrink = null;
        return value;
    }
    pub fn init(a: std.mem.Allocator, config_arena: std.mem.Allocator, io: std.Io, cfg: *maru.config.Config) !Host {
        return .{ .a = a, .config_arena = config_arena, .io = io, .cfg = cfg, .path = try maru.config.loader.defaultConfigPath(a) };
    }
    pub fn deinit(self: *Host) void {
        if (self.job) |job| {
            job.thread.?.join();
            std.heap.smp_allocator.destroy(job);
        }
        if (self.path) |path| self.a.free(path);
    }
    pub fn ownsInput(self: *const Host) bool {
        return self.form.state.open or self.swallow_left_up;
    }
    pub fn toggle(self: *Host) void {
        if (self.job != null) return;
        self.scrollbar.hide();
        self.wheel_acc.reset();
        if (self.form.state.open) {
            if (self.form.edit.rollback()) |request| {
                self.apply(.{ .request = request, .finish = true }) catch return;
            }
            self.form.state.hide();
        } else self.form.state.show();
    }
    pub fn tick(self: *Host) void {
        if (!self.form.state.open or self.job != null or self.form.state.dropdown.open or self.form.state.picking) self.scrollbar.hide() else self.scrollbar.tick(&self.form.state.scroll);
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        job.thread.?.join();
        const success = job.failure == null;
        if (success) {
            self.saves += 1;
            self.cfg.* = job.cfg;
            if (std.mem.eql(u8, job.request.key.slice(), "scrollback.lines")) self.scrollback_shrink = job.cfg.scrollback.lines;
            self.changed = true;
            self.form.state.clearMessage();
            if (self.preview_generation == job.request.generation) self.preview_generation = null;
        } else {
            self.save_errors += 1;
            self.form.state.setMessage(maru.i18n.t(.app_save_failed));
        }
        self.form.complete(job.request, true, success);
        std.heap.smp_allocator.destroy(job);
        self.job = null;
    }
    fn apply(self: *Host, result: maru.app.settings_form.Result) !void {
        const request = result.request orelse return;
        // Inline text changes are not previews. Cancelling one must only retire
        // its transaction: the unchanged original may legally be an empty
        // default (for example automatic shell selection), not a new GUI value.
        if (!request.persist and result.finish and self.preview_generation != request.generation) {
            self.rollbacks += 1;
            self.form.complete(request, true, true);
            return;
        }
        const cfg = try candidate(self.config_arena, self.cfg.*, request);
        if (!request.persist) {
            if (result.finish) {
                self.rollbacks += 1;
                self.preview_generation = null;
            } else {
                self.previews += 1;
                self.preview_generation = request.generation;
            }
            self.cfg.* = cfg;
            self.changed = true;
            self.form.complete(request, result.finish, true);
            return;
        }
        const path = self.path orelse return error.MissingConfigPath;
        const job = try std.heap.smp_allocator.create(Job);
        errdefer std.heap.smp_allocator.destroy(job);
        job.* = .{ .io = self.io, .path = path, .request = request, .cfg = cfg };
        job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
        self.job = job;
    }
    pub fn key(self: *Host, event: maru.terminal.KeyEvent) void {
        if (self.job != null or event.event_type == .release) return;
        self.scrollbar.cancel();
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const f = self.form.frame(arena.allocator(), self.cfg.*) catch return;
        const intent = widget.handle(maru.app.chrome_key.chromeKeyEvent(event), &self.form.state);
        self.updateScrollContext(intent);
        const result = self.form.action(arena.allocator(), self.cfg.*, f, intent) catch {
            self.form.state.setMessage(maru.i18n.t(.app_save_failed));
            return;
        };
        self.apply(result) catch {
            self.request_errors += 1;
            self.form.state.setMessage(maru.i18n.t(.app_save_failed));
        };
    }
    pub fn preedit(self: *Host, text: []const u8) void {
        if (self.job != null) {
            self.form.state.setEditPreedit("");
            self.form.state.setSearchPreedit("");
            return;
        }
        self.form.state.setEditPreedit(text);
        if (self.form.state.editing) self.form.state.setSearchPreedit("") else self.form.state.setSearchPreedit(text);
    }
    pub fn pointer(self: *Host, event: maru.chrome.input.PointerEvent, raw_props: maru.chrome.props.ChromeProps, tokens: *const maru.chrome.Tokens) void {
        var props = raw_props;
        props.metrics.overlay_scroll_gutter_px = settings_scrollbar.metrics.gutterPx();
        if (event.phase == .up and event.button == .left and self.swallow_left_up) {
            self.swallow_left_up = false;
            return;
        }
        if (self.job != null or !self.form.state.open) return;
        if (self.form.state.dropdown.open or self.form.state.picking) self.scrollbar.hide() else if (self.scrollbar.pointer(event, &self.form.state.scroll)) return;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const f = self.form.frame(arena.allocator(), self.cfg.*) catch return;
        const intent = widget.handlePointer(event, f.sections, f.rows, f.dropdown, props, tokens, &self.form.state);
        self.updateScrollContext(intent);
        if (!self.form.state.open and event.phase == .down) self.swallow_left_up = true;
        const result = self.form.action(arena.allocator(), self.cfg.*, f, intent) catch return;
        self.apply(result) catch {
            self.request_errors += 1;
            self.form.state.setMessage(maru.i18n.t(.app_save_failed));
        };
    }
    fn updateScrollContext(self: *Host, intent: widget.Action) void {
        if (intent == .search_changed or intent == .section_changed) {
            self.scrollbar.hide();
            self.wheel_acc.reset();
            self.form.state.scroll = .{};
            self.form.state.followed_selected = null;
        } else if (intent == .close) {
            self.wheel_acc.reset();
            self.scrollbar.hide();
        }
    }
    pub fn wheel(self: *Host, delta: i32, lines_per_notch: u32, horizontal: bool, raw_props: maru.chrome.props.ChromeProps, tokens: *const maru.chrome.Tokens) void {
        var props = raw_props;
        props.metrics.overlay_scroll_gutter_px = settings_scrollbar.metrics.gutterPx();
        self.wheel_events += 1;
        if (horizontal) return;
        self.scrollbar.cancel();
        if (self.job != null or !self.form.state.open or self.form.state.dropdown.open or self.form.state.picking or lines_per_notch == 0 or props.metrics.cell_height_px == 0 or props.metrics.cell_width_px == 0) {
            self.wheel_acc.reset();
            return;
        }
        const notches = self.wheel_acc.feed(delta);
        if (notches == 0) return;
        const lines = maru.session.input_math.WheelAccumulator.linesForNotches(notches, lines_per_notch);
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const f = self.form.frame(arena.allocator(), self.cfg.*) catch return;
        // Establish selection following before the first wheel event. Otherwise
        // the first draw would undo scrolling that arrived before that draw.
        widget.ensureSelectedVisible(&self.form.state, f.sections, f.rows, props, tokens);
        if (widget.scrollByRows(&self.form.state, f.sections, f.rows, props, tokens, lines)) self.scroll_moves += 1;
        self.scroll_peak = @max(self.scroll_peak, self.form.state.scroll.offset_y_px);
    }
    /// Reuse painted modal caret geometry for IMM; a terminal cursor is
    /// unrelated to the active search or field editor.
    pub fn imeCaret(self: *Host, raw_props: maru.chrome.props.ChromeProps, tokens: *const maru.chrome.Tokens) ?maru.session.mouse_coordinates.ImeCaret {
        var props = raw_props;
        props.metrics.overlay_scroll_gutter_px = settings_scrollbar.metrics.gutterPx();
        if (!self.form.state.open or (!self.form.state.searching and !self.form.state.editing) or self.form.state.picking) return null;
        var arena = std.heap.ArenaAllocator.init(self.a);
        defer arena.deinit();
        const f = self.form.frame(arena.allocator(), self.cfg.*) catch return null;
        // An inline edit can retain the filter query; keyboard handling gives
        // the editor precedence, so IMM must do the same.
        const rect = (if (self.form.state.editing)
            widget.editCaretRect(&self.form.state, f.sections, f.rows, props, tokens)
        else
            widget.searchCaretRect(&self.form.state, f.sections, f.rows, props, tokens)) orelse return null;
        return .{
            .row = 0,
            .col = 0,
            .cell_w = rect.w,
            .cell_h = rect.h,
            .origin_x = @intCast(@max(0, rect.x)),
            .origin_y = @intCast(@max(0, rect.y)),
        };
    }
    pub fn draw(self: *Host, a: std.mem.Allocator, raw_props: maru.chrome.props.ChromeProps, tokens: *const maru.chrome.Tokens, ops: *std.ArrayList(maru.chrome.draw.Op)) !void {
        errdefer self.scrollbar.hide();
        var props = raw_props;
        props.metrics.overlay_scroll_gutter_px = settings_scrollbar.metrics.gutterPx();
        const f = try self.form.frame(a, self.cfg.*);
        widget.ensureSelectedVisible(&self.form.state, f.sections, f.rows, props, tokens);
        try widget.view(&self.form.state, f.sections, f.rows, f.dropdown, props, tokens, a, ops);
        if (self.job != null or self.form.state.dropdown.open or self.form.state.picking) {
            self.scrollbar.hide();
            return;
        }
        if (widget.scrollView(&self.form.state, f.sections, f.rows, props, tokens)) |view| {
            try self.scrollbar.publish(view, props.metrics.cell_height_px, tokens, a, ops);
        } else self.scrollbar.hide();
    }
    pub fn cancelGestures(self: *Host) void {
        self.scrollbar.hide();
        self.form.state.dragging = false;
        self.wheel_acc.reset();
    }
};

fn testRequest(key: []const u8, value: []const u8) !edit.Request {
    var transaction: edit.Edit = .{};
    try transaction.begin(key, "");
    return (try transaction.request(key, value, true)).?;
}
test "Windows settings rejects an unknown key" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidValue, candidate(arena.allocator(), .{}, try testRequest("missing.setting", "true")));
}
test "Windows settings rejects malformed boolean values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidValue, candidate(arena.allocator(), .{}, try testRequest("input.paste-protection", "maybe")));
}
test "Windows settings rejects nonfinite numeric values" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidValue, candidate(arena.allocator(), .{}, try testRequest("font.size", "nan")));
}
test "Windows settings rejects unknown enum variants" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidValue, candidate(arena.allocator(), .{}, try testRequest("input.right-click", "missing")));
}
test "Windows settings rejects malformed colors" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.InvalidValue, candidate(arena.allocator(), .{}, try testRequest("theme.background", "#zzzzzz")));
}

test "Windows settings text paths reject relative and tilde commands" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{ "cmd.exe", "./cmd.exe", "../cmd.exe", "C:cmd.exe", "~/bin/shell.exe" }) |value|
        try std.testing.expectError(error.InvalidValue, candidate(arena.allocator(), .{}, try testRequest("shell.command", value)));
}

test "Windows settings text paths normalize native absolute paths" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const changed = try candidate(arena.allocator(), .{}, try testRequest("shell.command", "  C:\\Program Files\\shell.exe  "));
    try std.testing.expectEqualStrings("C:/Program Files/shell.exe", changed.shell.command);
    const network = try candidate(arena.allocator(), .{}, try testRequest("shell.command", "\\\\server\\share\\shell.exe"));
    try std.testing.expectEqualStrings("//server/share/shell.exe", network.shell.command);
    // A Windows adapter must remain testable on a POSIX runner, while the
    // shared parser must still reject Windows drive paths for POSIX configs.
    var posix: maru.config.Config = .{};
    var diags: std.ArrayList(maru.config.schema.Diag) = .empty;
    try std.testing.expect(try maru.config.schema.tryParseFor(.linux, arena.allocator(), &posix, "shell.command", "C:\\shell.exe", &diags, 1));
    try std.testing.expectEqual(@as(usize, 1), diags.items.len);
    try std.testing.expectEqualStrings("", posix.shell.command);
    diags.clearRetainingCapacity();
    try std.testing.expect(try maru.config.schema.tryParseFor(.linux, arena.allocator(), &posix, "shell.command", "/bin/shell\\literal", &diags, 1));
    try std.testing.expectEqual(@as(usize, 0), diags.items.len);
    try std.testing.expectEqualStrings("/bin/shell\\literal", posix.shell.command);
}

test "Windows settings text paths preserve nonpath text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const changed = try candidate(arena.allocator(), .{}, try testRequest("font.family", "  Family\\literal  "));
    try std.testing.expectEqualStrings("Family\\literal", changed.font.family);
    try std.testing.expectError(error.InvalidValue, candidate(arena.allocator(), changed, try testRequest("font.family", " \t ")));
}

test "Windows settings text paths own accepted request bytes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var request = try testRequest("shell.command", "C:\\safe\\shell.exe");
    const changed = try candidate(arena.allocator(), .{}, request);
    @memset(request.value.bytes[0..request.value.len], 'x');
    try std.testing.expectEqualStrings("C:/safe/shell.exe", changed.shell.command);
}

test "Windows settings text paths allocation failure preserves input" {
    const Probe = struct {
        fn run(a: std.mem.Allocator) !void {
            var cfg: maru.config.Config = .{};
            cfg.shell.command = "C:/original/shell.exe";
            defer std.testing.expectEqualStrings("C:/original/shell.exe", cfg.shell.command) catch unreachable;
            const changed = try candidate(a, cfg, try testRequest("shell.command", "C:\\new\\shell.exe"));
            try std.testing.expectEqualStrings("C:/new/shell.exe", changed.shell.command);
            a.free(changed.shell.command);
        }
    };
    try std.testing.checkAllAllocationFailures(std.testing.allocator, Probe.run, .{});
}
fn rollbackTestHost(a: std.mem.Allocator, cfg: *maru.config.Config) Host {
    return .{ .a = a, .config_arena = a, .io = std.testing.io, .cfg = cfg, .path = null };
}

test "Windows settings rollback cancels empty unpreviewed text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = rollbackTestHost(arena.allocator(), &cfg);
    try host.form.edit.begin("shell.command", "");
    try host.apply(.{ .request = host.form.edit.rollback(), .finish = true });
    try std.testing.expectEqualStrings("", cfg.shell.command);
    try std.testing.expect(!host.changed and !host.form.edit.active);
    try host.form.edit.begin("font.family", cfg.font.family);
}

test "Windows settings rollback restores matching preview and retires generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    cfg.input.right_click = .paste;
    var host = rollbackTestHost(arena.allocator(), &cfg);
    try host.form.edit.begin("input.right-click", "paste");
    try host.apply(.{ .request = try host.form.edit.request("input.right-click", "menu", false) });
    try std.testing.expectEqual(maru.config.theme.RightClick.menu, cfg.input.right_click);
    try std.testing.expectEqual(@as(?u64, host.form.edit.generation), host.preview_generation);
    try host.apply(.{ .request = host.form.edit.rollback(), .finish = true });
    try std.testing.expectEqual(maru.config.theme.RightClick.paste, cfg.input.right_click);
    try std.testing.expect(host.preview_generation == null and !host.form.edit.active);
}

test "Windows settings rollback retains preview after failed save admission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    cfg.input.right_click = .paste;
    var host = rollbackTestHost(arena.allocator(), &cfg);
    try host.form.edit.begin("input.right-click", "paste");
    try host.apply(.{ .request = try host.form.edit.request("input.right-click", "menu", false) });
    try std.testing.expectError(error.MissingConfigPath, host.apply(.{ .request = try host.form.edit.request("input.right-click", "menu", true), .finish = true }));
    try std.testing.expectEqual(@as(?u64, host.form.edit.generation), host.preview_generation);
    try host.apply(.{ .request = host.form.edit.rollback(), .finish = true });
    try std.testing.expectEqual(maru.config.theme.RightClick.paste, cfg.input.right_click);
}

test "Windows settings rollback ignores stale preview generation" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = rollbackTestHost(arena.allocator(), &cfg);
    try host.form.edit.begin("shell.command", "");
    host.preview_generation = host.form.edit.generation - 1;
    cfg.shell.command = "C:/current/shell.exe";
    try host.apply(.{ .request = host.form.edit.rollback(), .finish = true });
    try std.testing.expectEqualStrings("C:/current/shell.exe", cfg.shell.command);
    try std.testing.expect(!host.changed and !host.form.edit.active);
}

test "Windows settings rollback toggle closes empty unpreviewed editor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = rollbackTestHost(arena.allocator(), &cfg);
    host.form.state.show();
    try host.form.edit.begin("shell.command", "");
    host.toggle();
    try std.testing.expect(!host.form.state.open and !host.form.edit.active and !host.changed);
    try std.testing.expectEqual(@as(usize, 1), host.rollbacks);
}

test "Windows settings patch preserves unrelated settings" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    cfg.font.size = 22;
    const changed = try candidate(arena.allocator(), cfg, try testRequest("input.paste-protection", "false"));
    try std.testing.expect(!changed.input.paste_protection);
    try std.testing.expectEqual(@as(f32, 22), changed.font.size);
}

test "Windows settings and sidebar serialize partial config writes" {
    const Runner = struct {
        io: std.Io,
        path: []const u8,
        ready: *std.atomic.Value(u32),
        width: ?u32,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            _ = self.ready.fetchAdd(1, .acq_rel);
            while (self.ready.load(.acquire) < 2) std.Thread.yield() catch {};
            for (0..8) |_| {
                if (self.width) |width| {
                    @import("../chrome/sidebar.zig").writeWidth(std.heap.smp_allocator, self.io, self.path, width) catch |err| {
                        self.failure = err;
                        return;
                    };
                } else {
                    var cfg: maru.config.Config = .{};
                    cfg.input.paste_protection = false;
                    var job: Job = .{ .io = self.io, .path = self.path, .cfg = cfg, .request = testRequest("input.paste-protection", "false") catch unreachable };
                    job.write() catch |err| {
                        self.failure = err;
                        return;
                    };
                }
            }
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buffer: [4096]u8 = undefined;
    const dir = buffer[0..try tmp.dir.realPath(std.testing.io, &buffer)];
    const path = try std.fmt.allocPrint(std.testing.allocator, "{s}/config", .{dir});
    defer std.testing.allocator.free(path);
    for ([_]u32{ 120, 200, 300, 400, 480 }) |width| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config", .data = "# keep comment\nfuture.key = keep\nsidebar.width = 180\ninput.paste-protection = true\n" });
        var ready: std.atomic.Value(u32) = .init(0);
        var first: Runner = .{ .io = std.testing.io, .path = path, .ready = &ready, .width = width };
        var second: Runner = .{ .io = std.testing.io, .path = path, .ready = &ready, .width = null };
        const left = try std.Thread.spawn(.{}, Runner.run, .{&first});
        const right = std.Thread.spawn(.{}, Runner.run, .{&second}) catch |err| {
            ready.store(2, .release);
            left.join();
            return err;
        };
        left.join();
        right.join();
        try std.testing.expect(first.failure == null and second.failure == null);
        const bytes = try tmp.dir.readFileAlloc(std.testing.io, "config", std.testing.allocator, .limited(1 << 20));
        defer std.testing.allocator.free(bytes);
        var parsed = try maru.config.loader.parse(std.testing.allocator, bytes);
        defer parsed.deinit();
        try std.testing.expectEqual(width, parsed.config.sidebar.width_pt);
        try std.testing.expect(!parsed.config.input.paste_protection);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "# keep comment") != null and std.mem.indexOf(u8, bytes, "future.key = keep") != null);
    }
}

const wheel_test_props: maru.chrome.props.ChromeProps = .{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 1000, .backing_height_px = 240, .overlay_scroll_gutter_px = 16 } };
fn scrollbarTestDraw(host: *Host, a: std.mem.Allocator, props: maru.chrome.props.ChromeProps) ![]const maru.chrome.draw.Op {
    var ops: std.ArrayList(maru.chrome.draw.Op) = .empty;
    const tk = wheelTestTokens();
    try host.draw(a, props, &tk, &ops);
    return ops.items;
}
fn scrollbarTestDown(host: *Host, at_bottom: bool) void {
    const g = host.scrollbar.geometry.?;
    const tk = wheelTestTokens();
    host.pointer(.{ .phase = .down, .x_px = g.track_x + g.track_w / 2, .y_px = if (at_bottom) g.track_y + g.track_h - 1 else g.thumb_y + g.thumb_h / 2 }, wheel_test_props, &tk);
}
test "Windows settings scrollbar paints published overflow only" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(a, &cfg);
    const ops = try scrollbarTestDraw(&host, a, wheel_test_props);
    try std.testing.expectEqual(@as(usize, 3), host.scrollbar.count);
    try std.testing.expect(host.scrollbar.geometry != null);
    try std.testing.expect(ops.len >= 2 and ops[ops.len - 1] == .quad and ops[ops.len - 2] == .quad);
    host.form.state.startSearch();
    for ("__no_setting__") |cp| host.form.state.appendSearchCp(cp);
    _ = try scrollbarTestDraw(&host, a, wheel_test_props);
    try std.testing.expectEqual(@as(usize, 0), host.scrollbar.count);
    try std.testing.expect(host.scrollbar.geometry == null);
}
test "Windows settings scrollbar paint allocation failure retires hit targets" {
    var bar: settings_scrollbar.Bar = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var ops: std.ArrayList(maru.chrome.draw.Op) = .empty;
    defer ops.deinit(failing.allocator());
    const tk = wheelTestTokens();
    try std.testing.expectError(error.OutOfMemory, bar.publish(.{
        .viewport = .{ .x = 100, .y = 100, .w = 200, .h = 100 },
        .total = 100,
        .visible = 5,
        .win_start = 0,
    }, 20, &tk, failing.allocator(), &ops));
    try std.testing.expectEqual(@as(usize, 0), bar.count);
    try std.testing.expect(bar.geometry == null and !bar.drag.active);
    try std.testing.expectEqual(@as(usize, 0), ops.items.len);
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(arena.allocator(), &cfg);
    _ = try scrollbarTestDraw(&host, arena.allocator(), wheel_test_props);
    var frame_failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var frame_ops: std.ArrayList(maru.chrome.draw.Op) = .empty;
    defer frame_ops.deinit(frame_failing.allocator());
    try std.testing.expectError(error.OutOfMemory, host.draw(frame_failing.allocator(), wheel_test_props, &tk, &frame_ops));
    try std.testing.expectEqual(@as(usize, 0), host.scrollbar.count);
}
test "Windows settings scrollbar track jump uses final release coordinate" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(a, &cfg);
    _ = try scrollbarTestDraw(&host, a, wheel_test_props);
    const g = host.scrollbar.geometry.?;
    scrollbarTestDown(&host, true);
    try std.testing.expect(host.scrollbar.drag.active and host.form.state.scroll.offset_y_px > 0);
    const tk = wheelTestTokens();
    host.pointer(.{ .phase = .up, .x_px = g.track_x, .y_px = g.track_y - 100 }, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    try std.testing.expect(!host.scrollbar.drag.active and host.scrollbar.interaction.capture == null);
}
test "Windows settings scrollbar ignores unrelated release and coalesces movement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(a, &cfg);
    _ = try scrollbarTestDraw(&host, a, wheel_test_props);
    const g = host.scrollbar.geometry.?;
    const tk = wheelTestTokens();
    // The reserved gutter edge is outside the narrow painted thumb, but is
    // still a published track action and must acquire typed capture.
    host.pointer(.{ .phase = .down, .x_px = g.hit_x + 0.5, .y_px = g.thumb_y + g.thumb_h / 2 }, wheel_test_props, &tk);
    try std.testing.expect(host.scrollbar.interaction.capture != null);
    host.pointer(.{ .phase = .up, .button = .other, .x_px = g.track_x, .y_px = g.track_y + g.track_h }, wheel_test_props, &tk);
    try std.testing.expect(host.scrollbar.drag.active);
    host.pointer(.{ .phase = .move, .x_px = g.track_x, .y_px = g.track_y + g.track_h }, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    host.tick();
    try std.testing.expect(host.form.state.scroll.offset_y_px > 0);
    host.pointer(.{ .phase = .up, .x_px = -100, .y_px = -100 }, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    try std.testing.expect(host.form.state.open);
}
test "Windows settings scrollbar cancels on owner changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(a, &cfg);
    _ = try scrollbarTestDraw(&host, a, wheel_test_props);
    scrollbarTestDown(&host, false);
    host.cancelGestures();
    try std.testing.expect(!host.scrollbar.drag.active);
    _ = try scrollbarTestDraw(&host, a, wheel_test_props);
    scrollbarTestDown(&host, false);
    host.key(.{ .key = .{ .char = '/' } });
    try std.testing.expect(!host.scrollbar.drag.active);
    _ = try scrollbarTestDraw(&host, a, wheel_test_props);
    scrollbarTestDown(&host, false);
    host.form.state.dropdown.open = true;
    host.tick();
    try std.testing.expect(!host.scrollbar.drag.active);
    host.form.state.dropdown.open = false;
    _ = try scrollbarTestDraw(&host, a, wheel_test_props);
    scrollbarTestDown(&host, false);
    host.toggle();
    try std.testing.expect(!host.scrollbar.drag.active and !host.form.state.open);
}
test "Windows settings scrollbar carries scroll redraw but cancels resized geometry" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(a, &cfg);
    _ = try scrollbarTestDraw(&host, a, wheel_test_props);
    const g = host.scrollbar.geometry.?;
    const tk = wheelTestTokens();
    scrollbarTestDown(&host, false);
    host.pointer(.{ .phase = .move, .x_px = g.track_x, .y_px = g.track_y + g.track_h }, wheel_test_props, &tk);
    host.tick();
    _ = try scrollbarTestDraw(&host, a, wheel_test_props);
    try std.testing.expect(host.scrollbar.drag.active and host.scrollbar.interaction.capture != null);
    var resized = wheel_test_props;
    resized.metrics.backing_width_px += 200;
    _ = try scrollbarTestDraw(&host, a, resized);
    try std.testing.expect(!host.scrollbar.drag.active and host.scrollbar.interaction.capture == null);
}

test "Windows settings composition paints preview at the only active caret" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tk = wheelTestTokens();
    var state: widget.State = .{};
    state.show();
    state.startSearch();
    state.appendSearchCp('.');
    state.enterEdit("a");
    state.setEditPreedit("\xea\xb0\x80");
    const rows = [_]widget.FieldRow{.{ .label = "value", .kind = .{ .text = "" } }};
    var ops: std.ArrayList(maru.chrome.draw.Op) = .empty;
    try widget.view(&state, &.{}, &rows, &.{}, wheel_test_props, &tk, a, &ops);
    var cursors: usize = 0;
    var preview = false;
    const caret = widget.editCaretRect(&state, &.{}, &rows, wheel_test_props, &tk).?;
    for (ops.items) |op| {
        if (op == .fill and op.fill.role == .cursor) cursors += 1;
        if (op == .text) for (op.text.runs) |run| {
            if (std.mem.eql(u8, run.text, "\xea\xb0\x80")) {
                preview = true;
                try std.testing.expectEqual(caret.x, op.text.origin.x);
                try std.testing.expectEqual(caret.y, op.text.origin.y);
            }
        };
    }
    try std.testing.expectEqual(@as(usize, 1), cursors);
    try std.testing.expect(preview);
    try std.testing.expectEqualStrings("a", state.editText());
}
test "Windows settings composition routes preview without changing the filter" {
    var cfg: maru.config.Config = .{};
    var host: Host = .{ .a = std.testing.allocator, .config_arena = std.testing.allocator, .io = std.testing.io, .cfg = &cfg, .path = null };
    host.form.state.show();
    host.form.state.startSearch();
    host.form.state.appendSearchCp('.');
    host.form.state.enterEdit("old");
    var bytes = [_]u8{ 0xea, 0xb0, 0x80 };
    host.preedit(&bytes);
    bytes[0] = 0;
    try std.testing.expectEqualStrings("\xea\xb0\x80", host.form.state.editPreedit());
    try std.testing.expectEqualStrings("", host.form.state.searchPreedit());
    try std.testing.expectEqualStrings(".", host.form.state.searchQuery());
    try std.testing.expectEqualStrings("old", host.form.state.editText());
    host.form.state.cancelEdit();
    host.preedit("search");
    try std.testing.expectEqualStrings("", host.form.state.editPreedit());
    try std.testing.expectEqualStrings("search", host.form.state.searchPreedit());
}
test "Windows settings composition cancels and commits without replaying preview" {
    var state: widget.State = .{};
    state.show();
    state.enterEdit("old");
    state.setEditPreedit("pending");
    state.cancelEdit();
    state.enterEdit("new");
    try std.testing.expectEqualStrings("", state.editPreedit());
    state.setEditPreedit("\xea\xb0\x80");
    state.appendEditCp(0xAC00);
    try std.testing.expectEqualStrings("new\xea\xb0\x80", state.editText());
    try std.testing.expectEqualStrings("", state.editPreedit());
    state.setEditPreedit("pending");
    state.hide();
    state.show();
    state.enterEdit("next");
    try std.testing.expectEqualStrings("", state.editPreedit());
}
test "Windows settings composition bounds UTF8 and rejects invalid previews" {
    var state: widget.State = .{};
    state.show();
    state.enterEdit("");
    var long: [36]u8 = undefined;
    for (0..12) |i| @memcpy(long[i * 3 ..][0..3], "\xea\xb0\x80");
    state.setEditPreedit(&long);
    try std.testing.expectEqual(@as(usize, 30), state.editPreedit().len);
    _ = try std.unicode.Utf8View.init(state.editPreedit());
    state.setEditPreedit(&.{0xff});
    try std.testing.expectEqualStrings("", state.editPreedit());
    state.cancelEdit();
    state.setEditPreedit("inactive");
    try std.testing.expectEqualStrings("", state.editPreedit());
}
test "Windows settings composition does not draw past the field edge" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const tk = wheelTestTokens();
    var state: widget.State = .{};
    state.show();
    state.enterEdit("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa");
    state.setEditPreedit("\xea\xb0\x80");
    const rows = [_]widget.FieldRow{.{ .label = "value", .kind = .{ .text = "" } }};
    var ops: std.ArrayList(maru.chrome.draw.Op) = .empty;
    try widget.view(&state, &.{}, &rows, &.{}, wheel_test_props, &tk, arena.allocator(), &ops);
    for (ops.items) |op| if (op == .text) {
        for (op.text.runs) |run| try std.testing.expect(!std.mem.eql(u8, run.text, "\xea\xb0\x80"));
    };
}

fn inlineCaretMatchesPaint(kind: widget.FieldRow.Kind) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const tk = wheelTestTokens();
    var state: widget.State = .{};
    state.show();
    state.enterEdit("a\xea\xb0\x80");
    const rows = [_]widget.FieldRow{.{ .label = "value", .kind = kind }};
    var ops: std.ArrayList(maru.chrome.draw.Op) = .empty;
    try widget.view(&state, &.{}, &rows, &.{}, wheel_test_props, &tk, a, &ops);
    var painted: ?maru.chrome.draw.Rect = null;
    for (ops.items) |op| if (op == .fill and op.fill.role == .cursor) {
        painted = op.fill.rect;
    };
    try std.testing.expect(painted != null);
    try std.testing.expectEqualDeep(painted.?, widget.editCaretRect(&state, &.{}, &rows, wheel_test_props, &tk).?);
}
test "Windows settings inline IME number matches padded painted caret" {
    try inlineCaretMatchesPaint(.{ .number = .{ .value = 12, .min = 0, .max = 100 } });
}
test "Windows settings inline IME text matches wide painted caret" {
    try inlineCaretMatchesPaint(.{ .text = "" });
    try inlineCaretMatchesPaint(.{ .font = "" });
}
test "Windows settings inline IME color matches swatch prefix" {
    try inlineCaretMatchesPaint(.{ .color = .{ .hex = "#000000", .rgb = .{ .r = 0, .g = 0, .b = 0 } } });
}
test "Windows settings inline IME rejects hidden and nonediting rows" {
    const tk = wheelTestTokens();
    var state: widget.State = .{};
    const rows = [_]widget.FieldRow{.{ .label = "value", .kind = .{ .text = "" } }};
    state.enterEdit("");
    try std.testing.expect(widget.editCaretRect(&state, &.{}, &rows, wheel_test_props, &tk) == null);
    state.show();
    try std.testing.expect(widget.editCaretRect(&state, &.{}, &rows, wheel_test_props, &tk) == null);
    state.enterEdit("");
    state.selected = 20;
    try std.testing.expect(widget.editCaretRect(&state, &.{}, &rows, wheel_test_props, &tk) == null);
    state.selected = 0;
    state.picking = true;
    try std.testing.expect(widget.editCaretRect(&state, &.{}, &rows, wheel_test_props, &tk) == null);
}
test "Windows settings inline IME editor takes precedence over retained search" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(a, &cfg);
    const tk = wheelTestTokens();
    host.form.state.startSearch();
    host.form.state.appendSearchCp('.');
    const f = try host.form.frame(a, cfg);
    for (f.rows, 0..) |row, i| if (row.kind == .number) {
        host.form.state.selected = i;
        break;
    } else continue;
    widget.ensureSelectedVisible(&host.form.state, f.sections, f.rows, wheel_test_props, &tk);
    host.form.state.enterEdit("12");
    const rect = widget.editCaretRect(&host.form.state, f.sections, f.rows, wheel_test_props, &tk).?;
    const anchor = host.imeCaret(wheel_test_props, &tk).?.anchor().?;
    try std.testing.expectEqual(rect.x, anchor.top_left.x);
    try std.testing.expectEqual(rect.y, anchor.top_left.y);
}

test "Windows settings IME respects closed and non-search owners" {
    var cfg: maru.config.Config = .{};
    var host: Host = .{ .a = std.testing.allocator, .config_arena = std.testing.allocator, .io = std.testing.io, .cfg = &cfg, .path = null };
    const tk = wheelTestTokens();
    host.form.state.startSearch();
    try std.testing.expect(host.imeCaret(wheel_test_props, &tk) == null);
    host.form.state.show();
    try std.testing.expect(host.imeCaret(wheel_test_props, &tk) == null);
    host.form.state.startSearch();
    host.form.state.picking = true;
    try std.testing.expect(host.imeCaret(wheel_test_props, &tk) == null);
}

test "Windows settings IME maps painted search cell to client anchor" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(a, &cfg);
    const tk = wheelTestTokens();
    host.form.state.startSearch();
    const f = try host.form.frame(a, cfg);
    const rect = widget.searchCaretRect(&host.form.state, f.sections, f.rows, wheel_test_props, &tk).?;
    const anchor = host.imeCaret(wheel_test_props, &tk).?.anchor().?;
    try std.testing.expectEqual(rect.x, anchor.top_left.x);
    try std.testing.expectEqual(rect.y, anchor.top_left.y);
    try std.testing.expectEqual(rect.x + @as(i32, @intCast(rect.w)), anchor.bottom_right.x);
    try std.testing.expectEqual(rect.y + @as(i32, @intCast(rect.h)), anchor.below.y);
}

test "Windows settings IME advances by display cells for wide committed text" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(arena.allocator(), &cfg);
    const tk = wheelTestTokens();
    host.form.state.startSearch();
    const before = host.imeCaret(wheel_test_props, &tk).?.anchor().?;
    host.form.state.appendSearchCp('a');
    host.form.state.appendSearchCp(0xAC00);
    const after = host.imeCaret(wheel_test_props, &tk).?.anchor().?;
    try std.testing.expectEqual(before.top_left.x + 24, after.top_left.x);
    try std.testing.expectEqual(before.top_left.y, after.top_left.y);
}

test "Windows settings IME stays at composition start until commit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(arena.allocator(), &cfg);
    const tk = wheelTestTokens();
    host.form.state.startSearch();
    const before = host.imeCaret(wheel_test_props, &tk).?;
    host.form.state.setSearchPreedit("\xea\xb0\x80");
    try std.testing.expectEqualDeep(before, host.imeCaret(wheel_test_props, &tk).?);
    try std.testing.expect(host.form.state.commitSearchPreedit());
    try std.testing.expectEqual(before.origin_x + 16, host.imeCaret(wheel_test_props, &tk).?.origin_x);
    host.form.state.endSearch();
    try std.testing.expect(host.imeCaret(wheel_test_props, &tk) == null);
}

test "Windows settings IME cache key follows resized modal and font metrics" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(arena.allocator(), &cfg);
    const tk = wheelTestTokens();
    host.form.state.startSearch();
    const before = host.imeCaret(wheel_test_props, &tk).?;
    var props = wheel_test_props;
    props.metrics.backing_width_px += 200;
    const resized = host.imeCaret(props, &tk).?;
    try std.testing.expectEqual(before.origin_x + 100, resized.origin_x);
    props.metrics.cell_width_px = 10;
    props.metrics.cell_height_px = 20;
    const font = host.imeCaret(props, &tk).?;
    try std.testing.expectEqual(@as(u32, 10), font.cell_w);
    try std.testing.expectEqual(@as(u32, 20), font.cell_h);
    try std.testing.expect(!std.meta.eql(resized, font));
}

fn wheelTestTokens() maru.chrome.Tokens {
    return .{ .palette = std.EnumArray(maru.chrome.tokens.ColorRole, maru.color.Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
}
fn wheelTestHost(a: std.mem.Allocator, cfg: *maru.config.Config) !Host {
    var host: Host = .{ .a = a, .config_arena = a, .io = std.testing.io, .cfg = cfg, .path = null };
    host.form.state.show();
    const f = try host.form.frame(a, cfg.*);
    for (f.sections, 0..) |section, i| if (std.mem.eql(u8, section, maru.app.settings_model.settingsSectionLabel(.theme))) {
        host.form.state.section = i;
        break;
    };
    return host;
}
test "Windows settings wheel preserves fractional events and first draw" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(arena.allocator(), &cfg);
    const tk = wheelTestTokens();
    host.wheel(-40, 3, false, wheel_test_props, &tk);
    host.wheel(-40, 3, false, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    host.wheel(-40, 3, false, wheel_test_props, &tk);
    const offset = host.form.state.scroll.offset_y_px;
    try std.testing.expect(offset > 0);
    var ops: std.ArrayList(maru.chrome.draw.Op) = .empty;
    try host.draw(arena.allocator(), wheel_test_props, &tk, &ops);
    try std.testing.expectEqual(offset, host.form.state.scroll.offset_y_px);
}
test "Windows settings wheel horizontal input cannot complete vertical residue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(arena.allocator(), &cfg);
    const tk = wheelTestTokens();
    host.wheel(-40, 3, false, wheel_test_props, &tk);
    host.wheel(-80, 3, true, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    host.wheel(-80, 3, false, wheel_test_props, &tk);
    try std.testing.expect(host.form.state.scroll.offset_y_px > 0);
}
test "Windows settings wheel respects child modal and pending write ownership" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(arena.allocator(), &cfg);
    const tk = wheelTestTokens();
    host.form.state.dropdown.open = true;
    host.wheel(-120, 3, false, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    host.form.state.dropdown.open = false;
    host.form.state.picking = true;
    host.wheel(-120, 3, false, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    host.form.state.picking = false;
    var job: Job = .{ .io = std.testing.io, .path = "", .cfg = cfg, .request = try testRequest("font.size", "14") };
    host.job = &job;
    host.wheel(-120, 3, false, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    host.job = null;
    host.form.state.hide();
    host.wheel(-120, 3, false, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
}
test "Windows settings wheel disabled policy discards old residue" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(arena.allocator(), &cfg);
    const tk = wheelTestTokens();
    host.wheel(-60, 3, false, wheel_test_props, &tk);
    host.wheel(-60, 0, false, wheel_test_props, &tk);
    host.wheel(-60, 3, false, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    host.wheel(-60, 3, false, wheel_test_props, &tk);
    try std.testing.expect(host.form.state.scroll.offset_y_px > 0);
}
test "Windows settings wheel wide values clamp at viewport bounds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(arena.allocator(), &cfg);
    const tk = wheelTestTokens();
    var acc: maru.session.input_math.WheelAccumulator = .{};
    _ = acc.feed(std.math.maxInt(i32));
    const positive = acc.feed(std.math.maxInt(i32));
    try std.testing.expectEqual(@as(i32, 2147483647), maru.session.input_math.WheelAccumulator.linesForNotches(positive, std.math.maxInt(u32)));
    host.wheel(std.math.minInt(i32), std.math.maxInt(u32), false, wheel_test_props, &tk);
    try std.testing.expect(host.form.state.scroll.offset_y_px > 0);
    host.wheel(std.math.maxInt(i32), std.math.maxInt(u32), false, wheel_test_props, &tk);
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
}

test "Windows settings wheel resets on search and section changes" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = try wheelTestHost(arena.allocator(), &cfg);
    const tk = wheelTestTokens();
    host.wheel(-120, 3, false, wheel_test_props, &tk);
    try std.testing.expect(host.form.state.scroll.offset_y_px > 0);
    host.key(.{ .key = .{ .char = '/' } });
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    host.key(.{ .key = .{ .char = '.' } });
    host.wheel(-120, 3, false, wheel_test_props, &tk);
    try std.testing.expect(host.form.state.scroll.offset_y_px > 0);
    host.key(.{ .key = .escape });
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
    host.wheel(-120, 3, false, wheel_test_props, &tk);
    try std.testing.expect(host.form.state.scroll.offset_y_px > 0);
    host.key(.{ .key = .arrow_left });
    host.key(.{ .key = .arrow_up });
    try std.testing.expectEqual(@as(u32, 0), host.form.state.scroll.offset_y_px);
}

// Complete the real host tick with an asynchronous success/failure receipt.
// File replacement itself is covered by the existing settings persistence tests.
fn shrinkCommit(host: *Host, key: []const u8, value: []const u8, succeeds: bool) !void {
    try host.form.edit.begin(key, "1000");
    const request = (try host.form.edit.request(key, value, true)).?;
    const next = try candidate(host.config_arena, host.cfg.*, request);
    const job = try std.heap.smp_allocator.create(Job);
    job.* = .{ .io = host.io, .path = "", .request = request, .cfg = next, .failure = if (succeeds) null else error.InjectedSaveFailure };
    const Worker = struct {
        fn run(result: *Job) void {
            result.done.store(true, .release);
        }
    };
    job.thread = try std.Thread.spawn(.{}, Worker.run, .{job});
    host.job = job;
    while (!job.done.load(.acquire)) try std.Io.sleep(std.testing.io, std.Io.Duration.fromMilliseconds(1), .awake);
    host.tick();
}
test "Windows settings shrink preview never authorizes history deletion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = rollbackTestHost(arena.allocator(), &cfg);
    try host.form.edit.begin("scrollback.lines", "1000");
    try host.apply(.{ .request = try host.form.edit.request("scrollback.lines", "5", false) });
    try std.testing.expectEqual(@as(u32, 5), cfg.scrollback.lines);
    try std.testing.expect(host.takeScrollbackShrink() == null);
}
test "Windows settings shrink successful zero commit is a one shot permit" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = rollbackTestHost(arena.allocator(), &cfg);
    try shrinkCommit(&host, "scrollback.lines", "0", true);
    try std.testing.expectEqual(@as(u32, 0), cfg.scrollback.lines);
    try std.testing.expectEqual(@as(?u32, 0), host.takeScrollbackShrink());
    try std.testing.expect(host.takeScrollbackShrink() == null and host.saves == 1);
}
test "Windows settings shrink failed save leaves history permission absent" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = rollbackTestHost(arena.allocator(), &cfg);
    try shrinkCommit(&host, "scrollback.lines", "5", false);
    try std.testing.expectEqual(@as(u32, 1000), cfg.scrollback.lines);
    try std.testing.expect(host.takeScrollbackShrink() == null and host.save_errors == 1);
}
test "Windows settings shrink unrelated save cannot grant permission" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = rollbackTestHost(arena.allocator(), &cfg);
    try shrinkCommit(&host, "font.size", "24", true);
    try std.testing.expectEqual(@as(f32, 24), cfg.font.size);
    try std.testing.expect(host.takeScrollbackShrink() == null);
}
test "Windows settings shrink undelivered permit survives unrelated completion" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var cfg: maru.config.Config = .{};
    var host = rollbackTestHost(arena.allocator(), &cfg);
    try shrinkCommit(&host, "scrollback.lines", "5", true);
    try shrinkCommit(&host, "font.size", "24", true);
    try std.testing.expectEqual(@as(?u32, 5), host.takeScrollbackShrink());
    try std.testing.expect(host.takeScrollbackShrink() == null);
}
