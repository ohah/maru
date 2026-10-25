//! Windows settings event adapter and asynchronous config persistence.
//! UI snapshots borrow config strings from the app-lifetime config arena.
const std = @import("std");
const maru = @import("maru");
const widget = maru.chrome.components.settings;
const edit = maru.app.settings_edit;

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
        if (!maru.config.schema.setText(&next, key, value)) return error.InvalidValue;
        const owned = try a.dupe(u8, value);
        _ = maru.config.schema.setText(&next, key, owned);
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
    saves: usize = 0,
    save_errors: usize = 0,
    request_errors: usize = 0,
    previews: usize = 0,
    rollbacks: usize = 0,
    wheel_acc: maru.session.input_math.WheelAccumulator = .{},
    wheel_events: usize = 0,
    scroll_moves: usize = 0,
    scroll_peak: u32 = 0,
    swallow_left_up: bool = false,
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
        self.wheel_acc.reset();
        if (self.form.state.open) {
            if (self.form.edit.rollback()) |request| {
                if (candidate(self.config_arena, self.cfg.*, request)) |cfg| {
                    self.cfg.* = cfg;
                    self.changed = true;
                    self.form.complete(request, true, true);
                    self.rollbacks += 1;
                } else |_| return;
            }
            self.form.state.hide();
        } else self.form.state.show();
    }
    pub fn tick(self: *Host) void {
        const job = self.job orelse return;
        if (!job.done.load(.acquire)) return;
        job.thread.?.join();
        const success = job.failure == null;
        if (success) {
            self.saves += 1;
            self.cfg.* = job.cfg;
            self.changed = true;
            self.form.state.clearMessage();
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
        const cfg = try candidate(self.config_arena, self.cfg.*, request);
        if (!request.persist) {
            if (result.finish) self.rollbacks += 1 else self.previews += 1;
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
    pub fn pointer(self: *Host, event: maru.chrome.input.PointerEvent, props: maru.chrome.props.ChromeProps, tokens: *const maru.chrome.Tokens) void {
        if (event.phase == .up and event.button == .left and self.swallow_left_up) {
            self.swallow_left_up = false;
            return;
        }
        if (self.job != null or !self.form.state.open) return;
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
            self.wheel_acc.reset();
            self.form.state.scroll = .{};
            self.form.state.followed_selected = null;
        } else if (intent == .close) self.wheel_acc.reset();
    }
    pub fn wheel(self: *Host, delta: i32, lines_per_notch: u32, horizontal: bool, props: maru.chrome.props.ChromeProps, tokens: *const maru.chrome.Tokens) void {
        self.wheel_events += 1;
        if (horizontal) return;
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
    pub fn draw(self: *Host, a: std.mem.Allocator, props: maru.chrome.props.ChromeProps, tokens: *const maru.chrome.Tokens, ops: *std.ArrayList(maru.chrome.draw.Op)) !void {
        const f = try self.form.frame(a, self.cfg.*);
        widget.ensureSelectedVisible(&self.form.state, f.sections, f.rows, props, tokens);
        try widget.view(&self.form.state, f.sections, f.rows, f.dropdown, props, tokens, a, ops);
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

const wheel_test_props: maru.chrome.props.ChromeProps = .{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 1000, .backing_height_px = 240 } };
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
