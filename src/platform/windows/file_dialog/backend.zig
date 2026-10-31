//! One owned request per picker. Modal COM work stays on a detached STA worker;
//! closing the app requests cancellation and drops ownership without joining UI.
//! The allocator must outlive the detached worker and any returned result. App
//! hosts use a process-lifetime allocator; allocator-checking tests await quiescence.
const std = @import("std");
const builtin = @import("builtin");
const Native = opaque {};
extern fn maru_windows_file_dialog_create() ?*Native;
extern fn maru_windows_file_dialog_cancel(*Native) void;
extern fn maru_windows_file_dialog_run(*Native, ?*anyopaque, u32, ?[*:0]const u16, ?[*:0]const u16) i32;
extern fn maru_windows_file_dialog_path(*const Native) ?[*:0]const u16;
extern fn maru_windows_file_dialog_destroy(*Native) void;
extern fn maru_windows_file_dialog_probe_options(u32, *u32) i32;

pub const Kind = enum(u32) { file = 1, directory = 2 };
pub const Request = struct {
    kind: Kind,
    owner: ?*anyopaque = null,
    initial_directory: ?[]const u8 = null,
    title: ?[]const u8 = null,
    token: u64 = 0,
};
pub const Failure = union(enum) { native: i32, out_of_memory, missing_path };
pub const Outcome = union(enum) { selected: []u8, canceled, failed: Failure };
pub const Result = struct {
    allocator: std.mem.Allocator,
    token: u64,
    value: Outcome,
    pub fn deinit(self: *Result) void {
        freeOutcome(self.allocator, self.value);
        self.value = .canceled;
    }
};
fn freeOutcome(a: std.mem.Allocator, value: Outcome) void {
    if (value == .selected) a.free(value.selected);
}
fn directoryWide(a: std.mem.Allocator, text: ?[]const u8) !?[:0]u16 {
    const raw = text orelse return null;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidPath;
    // Common Item Dialog parsing rejects our normalized C:/ paths (E_INVALIDARG).
    // Convert separators only at this native boundary; retain WTF-16 code units.
    const wide = try std.unicode.wtf8ToWtf16LeAllocZ(a, raw);
    for (wide) |*unit| if (unit.* == '/') {
        unit.* = '\\';
    };
    return wide;
}
fn titleWide(a: std.mem.Allocator, text: ?[]const u8) !?[:0]u16 {
    const raw = text orelse return null;
    if (std.mem.indexOfScalar(u8, raw, 0) != null) return error.InvalidTitle;
    return try std.unicode.utf8ToUtf16LeAllocZ(a, raw);
}
const State = struct {
    allocator: std.mem.Allocator,
    refs: std.atomic.Value(usize) = .init(1),
    done: std.atomic.Value(bool) = .init(false),
    cancel_requested: std.atomic.Value(bool) = .init(false),
    native: *Native,
    kind: Kind,
    owner: ?*anyopaque,
    directory: ?[:0]u16,
    title: ?[:0]u16,
    token: u64,
    result: Outcome = .canceled,
    fn create(a: std.mem.Allocator, request: Request) !*State {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const directory = try directoryWide(a, request.initial_directory);
        errdefer if (directory) |s| a.free(s);
        const title = try titleWide(a, request.title);
        errdefer if (title) |s| a.free(s);
        const state = try a.create(State);
        errdefer a.destroy(state);
        const native = maru_windows_file_dialog_create() orelse return error.OutOfMemory;
        state.* = .{ .allocator = a, .native = native, .kind = request.kind, .owner = request.owner, .directory = directory, .title = title, .token = request.token };
        return state;
    }
    fn release(self: *State) void {
        if (self.refs.fetchSub(1, .acq_rel) != 1) return;
        const a = self.allocator;
        freeOutcome(a, self.result);
        if (self.directory) |s| a.free(s);
        if (self.title) |s| a.free(s);
        maru_windows_file_dialog_destroy(self.native);
        a.destroy(self);
    }
    fn cancel(self: *State) void {
        self.cancel_requested.store(true, .release);
        maru_windows_file_dialog_cancel(self.native);
    }
    fn perform(self: *State) Outcome {
        const hr = maru_windows_file_dialog_run(self.native, self.owner, @backingInt(self.kind), if (self.directory) |s| s.ptr else null, if (self.title) |s| s.ptr else null);
        if (@as(u32, @bitCast(hr)) == 0x800704c7) return .canceled;
        if (hr < 0) return .{ .failed = .{ .native = hr } };
        const wide = maru_windows_file_dialog_path(self.native) orelse return .{ .failed = .missing_path };
        const path = std.unicode.wtf16LeToWtf8Alloc(self.allocator, std.mem.span(wide)) catch return .{ .failed = .out_of_memory };
        return .{ .selected = path };
    }
    fn worker(self: *State) void {
        defer self.release();
        var result = self.perform();
        if (self.cancel_requested.load(.acquire)) {
            freeOutcome(self.allocator, result);
            result = .canceled;
        }
        self.result = result;
        self.done.store(true, .release);
    }
};
pub const Picker = struct {
    state: ?*State = null,
    taken: bool = false,
    pub fn start(a: std.mem.Allocator, request: Request) !Picker {
        const state = try State.create(a, request);
        errdefer state.release();
        _ = state.refs.fetchAdd(1, .monotonic);
        const thread = std.Thread.spawn(.{}, State.worker, .{state}) catch |err| {
            state.release();
            return err;
        };
        thread.detach();
        return .{ .state = state };
    }
    pub fn cancel(self: *Picker) void {
        if (self.state) |state| state.cancel();
    }
    pub fn poll(self: *Picker) ?Result {
        const state = self.state orelse return null;
        if (self.taken or !state.done.load(.acquire)) return null;
        self.taken = true;
        var value = state.result;
        state.result = .canceled;
        // Cancellation can arrive after native Show returned but before harvest.
        if (state.cancel_requested.load(.acquire)) {
            freeOutcome(state.allocator, value);
            value = .canceled;
        }
        return .{ .allocator = state.allocator, .token = state.token, .value = value };
    }
    pub fn deinit(self: *Picker) void {
        const state = self.state orelse return;
        self.state = null;
        state.cancel();
        state.release();
    }
};

test "Windows file dialog native COM options distinguish file and folder without showing UI" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var file: u32 = 0;
    var folder: u32 = 0;
    try std.testing.expectEqual(@as(i32, 0), maru_windows_file_dialog_probe_options(1, &file));
    try std.testing.expectEqual(@as(i32, 0), maru_windows_file_dialog_probe_options(2, &folder));
    const required: u32 = 0x40 | 0x8 | 0x800 | 0x1000 | 0x02000000;
    try std.testing.expectEqual(required, file & required);
    try std.testing.expectEqual(required, folder & required);
    try std.testing.expect(file & 0x20 == 0 and folder & 0x20 != 0);
}
test "Windows file dialog pending request has no result" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    var picker: Picker = .{ .state = try State.create(std.testing.allocator, .{ .kind = .file }) };
    defer picker.deinit();
    try std.testing.expect(picker.poll() == null);
}
test "Windows file dialog canceled worker preserves token and result is consumed once" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const state = try State.create(std.testing.allocator, .{ .kind = .directory, .token = 81 });
    var picker: Picker = .{ .state = state };
    defer picker.deinit();
    picker.cancel();
    _ = state.refs.fetchAdd(1, .monotonic);
    State.worker(state);
    var result = picker.poll().?;
    defer result.deinit();
    try std.testing.expectEqual(@as(u64, 81), result.token);
    try std.testing.expect(result.value == .canceled);
    try std.testing.expect(picker.poll() == null);
}
test "Windows file dialog owner can disappear while worker keeps its own reference" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const state = try State.create(std.testing.allocator, .{ .kind = .file });
    _ = state.refs.fetchAdd(1, .monotonic);
    var picker: Picker = .{ .state = state };
    var worker_owned = true;
    defer if (worker_owned) {
        // Keep failing teardown tests from leaving a native request behind.
        state.cancel();
        State.worker(state);
    };
    picker.deinit();
    try std.testing.expect(picker.state == null);
    try std.testing.expect(state.cancel_requested.load(.acquire));
    try std.testing.expectEqual(@as(usize, 1), state.refs.load(.acquire));
    State.worker(state); // canceled before COM; the worker frees the final reference.
    worker_owned = false;
}
test "Windows file dialog rejects NUL instead of silently truncating request strings" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectError(error.InvalidPath, State.create(std.testing.allocator, .{ .kind = .file, .initial_directory = "C:/one\x00two" }));
    try std.testing.expectError(error.InvalidTitle, State.create(std.testing.allocator, .{ .kind = .file, .title = "one\x00two" }));
}
test "Windows file dialog keeps native path surrogate code units and Unicode titles" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const raw = "C:/\xed\xa0\x80/\xed\x95\x9c";
    const state = try State.create(std.testing.allocator, .{ .kind = .file, .initial_directory = raw, .title = "열기" });
    defer state.release();
    const back = try std.unicode.wtf16LeToWtf8Alloc(std.testing.allocator, state.directory.?);
    defer std.testing.allocator.free(back);
    try std.testing.expectEqualStrings("C:\\\xed\xa0\x80\\\xed\x95\x9c", back);
    try std.testing.expect(state.title.?[0] == 0xc5f4);
}
fn allocationRequest(a: std.mem.Allocator) !void {
    const state = try State.create(a, .{ .kind = .directory, .initial_directory = "C:/private/folder", .title = "Pick a folder" });
    state.release();
}
test "Windows file dialog owns all request strings across allocation failures" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.checkAllAllocationFailures(std.testing.allocator, allocationRequest, .{});
}

test "Windows file dialog late cancellation discards an already completed selection" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const state = try State.create(std.testing.allocator, .{ .kind = .file, .token = 19 });
    var picker: Picker = .{ .state = state };
    defer picker.deinit();
    state.result = .{ .selected = try std.testing.allocator.dupe(u8, "C:/private/chosen.txt") };
    state.done.store(true, .release);
    picker.cancel();
    var result = picker.poll().?;
    defer result.deinit();
    try std.testing.expect(result.value == .canceled);
    try std.testing.expectEqual(@as(u64, 19), result.token);
}

test "Windows file dialog adapts normalized drive UNC and extended directory separators" {
    if (builtin.os.tag != .windows) return error.SkipZigTest;
    const cases = .{
        .{ "C:/one/two", "C:\\one\\two" },
        .{ "C:\\one/two", "C:\\one\\two" },
        .{ "//server/share/folder", "\\\\server\\share\\folder" },
        .{ "//?/C:/one/two", "\\\\?\\C:\\one\\two" },
        .{ "//?/UNC/server/share", "\\\\?\\UNC\\server\\share" },
    };
    inline for (cases) |case| {
        const wide = (try directoryWide(std.testing.allocator, case[0])).?;
        defer std.testing.allocator.free(wide);
        const back = try std.unicode.wtf16LeToWtf8Alloc(std.testing.allocator, wide);
        defer std.testing.allocator.free(back);
        try std.testing.expectEqualStrings(case[1], back);
    }
}
