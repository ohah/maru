//! App URL policy is independent of AppKit and the filesystem. A URL requests one
//! file; it never grants LSP trust, registers a workspace, or runs a command.
const std = @import("std");

pub const max_url_bytes = 16 * 1024;
pub const max_path_bytes = 4096;
pub const max_pending = 32;
pub const max_pending_bytes = 64 * 1024;
pub const Error = error{ InvalidURL, TooLong, OutOfMemory };

pub const Request = struct {
    id: u64 = 0,
    path: []u8,
    line: ?u32 = null, // one-based; conversion happens only after validation.
    column: u32 = 1,
    raw_len: usize,

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        self.* = undefined;
    }
};

fn decode(value: []const u8, out: []u8) Error![]const u8 {
    var input: usize = 0;
    var count: usize = 0;
    while (input < value.len) {
        if (count == out.len) return error.TooLong;
        const byte: u8 = if (value[input] == '%') blk: {
            if (value.len - input < 3) return error.InvalidURL;
            const hi = std.fmt.charToDigit(value[input + 1], 16) catch return error.InvalidURL;
            const lo = std.fmt.charToDigit(value[input + 2], 16) catch return error.InvalidURL;
            input += 3;
            break :blk hi * 16 + lo;
        } else blk: {
            const b = value[input];
            input += 1;
            break :blk b;
        };
        if (byte < 32 or byte == 127) return error.InvalidURL;
        out[count] = byte;
        count += 1;
    }
    const result = out[0..count];
    if (!std.unicode.utf8ValidateSlice(result)) return error.InvalidURL;
    return result;
}

fn positive(value: []const u8) Error!u32 {
    if (value.len == 0) return error.InvalidURL;
    var n: u32 = 0;
    for (value) |b| {
        if (b < '0' or b > '9') return error.InvalidURL;
        n = std.math.mul(u32, n, 10) catch return error.InvalidURL;
        n = std.math.add(u32, n, b - '0') catch return error.InvalidURL;
    }
    if (n == 0) return error.InvalidURL;
    return n;
}

pub fn parse(allocator: std.mem.Allocator, raw: []const u8) Error!Request {
    if (raw.len > max_url_bytes) return error.TooLong;
    const prefix = "maru://open?";
    if (raw.len < prefix.len or !std.ascii.eqlIgnoreCase(raw[0..prefix.len], prefix)) return error.InvalidURL;
    // Reject fragments before splitting or decoding so encoded '#' remains a filename.
    if (std.mem.indexOfScalar(u8, raw, '#') != null) return error.InvalidURL;
    var path_buffer: [max_path_bytes]u8 = undefined;
    var path: ?[]const u8 = null;
    var line: ?u32 = null;
    var column: ?u32 = null;
    var parts = std.mem.splitScalar(u8, raw[prefix.len..], '&');
    while (parts.next()) |part| {
        const equal = std.mem.indexOfScalar(u8, part, '=') orelse return error.InvalidURL;
        const key = part[0..equal];
        const value = part[equal + 1 ..];
        if (std.mem.eql(u8, key, "path")) {
            if (path != null) return error.InvalidURL;
            path = try decode(value, &path_buffer);
            if (path.?.len == 0 or path.?[0] != '/') return error.InvalidURL;
        } else if (std.mem.eql(u8, key, "line") or std.mem.eql(u8, key, "column")) {
            // Numbers share the value decoder, but their bounded decimal syntax remains strict.
            // Leading zeros are valid decimals; only numeric overflow and the
            // URL's global limit constrain them, not an undocumented digit cap.
            var numeric_buffer: [max_url_bytes]u8 = undefined;
            const number = positive(decode(value, &numeric_buffer) catch return error.InvalidURL) catch return error.InvalidURL;
            if (std.mem.eql(u8, key, "line")) {
                if (line != null) return error.InvalidURL;
                line = number;
            } else {
                if (column != null) return error.InvalidURL;
                column = number;
            }
        } else return error.InvalidURL;
    }
    if (path == null or (column != null and line == null)) return error.InvalidURL;
    return .{ .path = try allocator.dupe(u8, path.?), .line = line, .column = column orelse 1, .raw_len = raw.len };
}

/// Main-thread coordinator: no borrowed URL/Term/Window pointers survive receipt.
/// A fixed ring bounds slots, while independently accounting raw bytes bounds bursts.
pub const Queue = struct {
    state: enum { starting, ready, stopped } = .starting,
    entries: [max_pending]?Request = @splat(null),
    head: usize = 0,
    count: usize = 0,
    raw_bytes: usize = 0,
    next_id: u64 = 1,

    pub fn offer(self: *Queue, allocator: std.mem.Allocator, raw: []const u8) (Error || error{ Full, Stopped })!void {
        if (self.state == .stopped) return error.Stopped;
        if (raw.len > max_url_bytes) return error.TooLong;
        if (self.count == max_pending or raw.len > max_pending_bytes - self.raw_bytes) return error.Full;
        if (self.next_id == std.math.maxInt(u64)) return error.Full;
        var request = try parse(allocator, raw);
        request.id = self.next_id;
        self.next_id += 1;
        self.entries[(self.head + self.count) % max_pending] = request;
        self.count += 1;
        self.raw_bytes += raw.len;
    }

    pub fn ready(self: *Queue) void {
        if (self.state == .starting) self.state = .ready;
    }

    pub fn take(self: *Queue) ?Request {
        if (self.state != .ready or self.count == 0) return null;
        const request = self.entries[self.head].?;
        self.entries[self.head] = null;
        self.head = (self.head + 1) % max_pending;
        self.count -= 1;
        self.raw_bytes -= request.raw_len;
        return request;
    }

    pub fn stop(self: *Queue, allocator: std.mem.Allocator) void {
        self.state = .ready;
        while (self.take()) |value| {
            var request = value;
            request.deinit(allocator);
        }
        self.state = .stopped;
    }
};
