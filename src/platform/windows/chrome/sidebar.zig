//! Sidebar width gestures and asynchronous, partial config persistence.
const std = @import("std");
const maru = @import("maru");

pub fn widthForPointer(x: i32, offset: i32, cell_width: u32) u32 {
    const minimum: i64 = @intCast(@min(@max(120, @as(u64, cell_width) * 13), 480));
    return @intCast(std.math.clamp(@as(i64, x) + offset, minimum, 480));
}

pub fn writeWidth(a: std.mem.Allocator, io: std.Io, path: []const u8, width: u32) !void {
    if (width < 120 or width > 480) return error.InvalidWidth;
    const original = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(1 << 20)) catch |err| switch (err) {
        error.FileNotFound => try a.dupe(u8, ""),
        else => return err,
    };
    defer a.free(original);
    var parsed = try maru.config.loader.parse(a, original);
    defer parsed.deinit();
    parsed.config.sidebar.width_pt = width;
    // Respect an existing Windows override without rewriting the shared base value.
    var windows_override = false;
    var lines = std.mem.splitScalar(u8, original, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOfScalar(u8, line, '=')) |eq| {
            if (std.mem.eql(u8, std.mem.trim(u8, line[0..eq], &std.ascii.whitespace), "sidebar.width.windows")) windows_override = true;
        }
    }
    var width_buffer: [16]u8 = undefined;
    const value = try std.fmt.bufPrint(&width_buffer, "{d}", .{width});
    const updated = if (windows_override)
        try maru.config.loader.updateConfigText(a, original, &.{.{ .key = "sidebar.width.windows", .value = value }})
    else
        try maru.config.serialize.updateForKeys(a, original, parsed.config, &.{"sidebar.width"});
    defer a.free(updated);
    var atomic = try std.Io.Dir.cwd().createFileAtomic(io, path, .{ .make_path = true, .replace = true });
    defer atomic.deinit(io);
    var buffer: [4096]u8 = undefined;
    var writer = atomic.file.writer(io, &buffer);
    try writer.interface.writeAll(updated);
    try writer.flush();
    try atomic.file.sync(io);
    try atomic.replace(io);
}

// A heap-stable worker owns its path; no borrowed config survives a frame.
// Only one writer runs. Repeated releases coalesce to the latest pending width.
pub const Writer = struct {
    io: std.Io,
    path: ?[]const u8,
    pending: ?u32 = null,
    job: ?*Job = null,
    const allocator = std.heap.smp_allocator;
    const Job = struct {
        io: std.Io,
        path: []const u8,
        width: u32,
        done: std.atomic.Value(bool) = .init(false),
        thread: ?std.Thread = null,
        failure: ?anyerror = null,
        fn run(self: *Job) void {
            writeWidth(allocator, self.io, self.path, self.width) catch |err| {
                self.failure = err;
            };
            self.done.store(true, .release);
        }
    };
    pub fn init(io: std.Io) !Writer {
        return .{ .io = io, .path = try maru.config.loader.defaultConfigPath(allocator) };
    }
    pub fn schedule(self: *Writer, width: u32) void {
        self.pending = width;
    }
    pub fn tick(self: *Writer) !void {
        var failure: ?anyerror = null;
        if (self.job) |job| {
            if (!job.done.load(.acquire)) return;
            job.thread.?.join();
            failure = job.failure;
            allocator.destroy(job);
            self.job = null;
        }
        if (self.pending) |width| {
            if (self.path) |path| {
                const job = try allocator.create(Job);
                errdefer allocator.destroy(job);
                job.* = .{ .io = self.io, .path = path, .width = width };
                job.thread = try std.Thread.spawn(.{}, Job.run, .{job});
                self.job = job;
            }
            self.pending = null;
        }
        if (failure) |err| return err;
    }
    pub fn deinit(self: *Writer) void {
        // Normal shutdown drains the already authorized final release.
        while (self.job != null or self.pending != null) {
            if (self.job) |job| job.thread.?.join();
            if (self.job) |job| {
                if (job.failure) |err| std.log.warn("sidebar config save failed({s})", .{@errorName(err)});
                allocator.destroy(job);
                self.job = null;
            }
            self.tick() catch |err| {
                std.log.warn("sidebar config save failed({s})", .{@errorName(err)});
                self.pending = null;
            };
        }
        if (self.path) |path| allocator.free(path);
        self.* = undefined;
    }
};
