//! Owns one canonical, credential-free timing record emitted from GitHub's Jobs API.

const std = @import("std");

pub const schema = "maru.session-host-release-live-timing.v1";
pub const repository = "ohah/maru";
pub const workflow = "release.yml";
pub const job_name = "universal dmg (signed + notarized)";
pub const step_name = "Run session host live release workflow";
pub const input_cap: usize = 16 * 1024;
const timestamp_cap: usize = 35;
const max_duration_ms: u64 = 24 * 60 * 60 * 1000;

pub const Value = struct {
    run_id: u64,
    run_attempt: u64,
    source_sha: []const u8,
    started_at: []const u8,
    completed_at: []const u8,
    duration_ms: u64,
};

pub const Record = struct {
    owner: ?*@This() = null,
    run_id: u64 = 0,
    run_attempt: u64 = 0,
    source: [40]u8 = @splat(0),
    started: [timestamp_cap]u8 = @splat(0),
    started_len: usize = 0,
    completed: [timestamp_cap]u8 = @splat(0),
    completed_len: usize = 0,
    duration_ms: u64 = 0,
    seal: [32]u8 = @splat(0),

    pub fn value(self: *const @This()) ?Value {
        if (self.owner != self or self.run_id == 0 or self.run_attempt == 0 or self.started_len == 0 or
            self.started_len > self.started.len or self.completed_len == 0 or self.completed_len > self.completed.len or
            self.duration_ms == 0 or self.duration_ms > max_duration_ms or !validSource(&self.source) or
            !allZero(self.started[self.started_len..]) or !allZero(self.completed[self.completed_len..]) or
            !std.mem.eql(u8, &self.seal, &metadataSeal(self))) return null;
        const started = parseTimestamp(self.started[0..self.started_len]) catch return null;
        const completed = parseTimestamp(self.completed[0..self.completed_len]) catch return null;
        if (completed.epoch_ns <= started.epoch_ns or completed.epoch_ms <= started.epoch_ms or
            completed.epoch_ms - started.epoch_ms != self.duration_ms) return null;
        return .{
            .run_id = self.run_id,
            .run_attempt = self.run_attempt,
            .source_sha = &self.source,
            .started_at = self.started[0..self.started_len],
            .completed_at = self.completed[0..self.completed_len],
            .duration_ms = self.duration_ms,
        };
    }

    pub fn deinit(self: *@This()) !void {
        if (self.owner != self or self.value() == null) return error.InvalidOwner;
        self.* = .{};
    }
};

const Wire = struct {
    schema: []const u8,
    repository: []const u8,
    workflow: []const u8,
    run_id: u64,
    run_attempt: u64,
    source_sha: []const u8,
    job_name: []const u8,
    step_name: []const u8,
    started_at: []const u8,
    completed_at: []const u8,
    duration_ms: u64,
};

const ParsedTimestamp = struct {
    epoch_ns: i128,
    epoch_ms: u64,
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8, result: *Record) !void {
    if (!pristine(result) or overlaps(std.mem.asBytes(result), bytes)) return error.InvalidOwner;
    if (bytes.len == 0 or bytes.len > input_cap) return error.InvalidRecord;

    var parsed = std.json.parseFromSlice(Wire, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidRecord,
    };
    defer parsed.deinit();
    const wire = parsed.value;
    try validateFixed(wire);
    const started = parseTimestamp(wire.started_at) catch return error.InvalidRecord;
    const completed = parseTimestamp(wire.completed_at) catch return error.InvalidRecord;
    if (completed.epoch_ns <= started.epoch_ns or completed.epoch_ms <= started.epoch_ms) return error.InvalidRecord;
    const derived = completed.epoch_ms - started.epoch_ms;
    if (wire.duration_ms != derived or derived == 0 or derived > max_duration_ms) return error.InvalidRecord;

    const canonical = std.fmt.allocPrint(
        allocator,
        "{{\"schema\":\"{s}\",\"repository\":\"{s}\",\"workflow\":\"{s}\",\"run_id\":{d},\"run_attempt\":{d},\"source_sha\":\"{s}\",\"job_name\":\"{s}\",\"step_name\":\"{s}\",\"started_at\":\"{s}\",\"completed_at\":\"{s}\",\"duration_ms\":{d}}}\n",
        .{ schema, repository, workflow, wire.run_id, wire.run_attempt, wire.source_sha, job_name, step_name, wire.started_at, wire.completed_at, wire.duration_ms },
    ) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer allocator.free(canonical);
    if (!std.mem.eql(u8, canonical, bytes)) return error.InvalidRecord;

    @memcpy(&result.source, wire.source_sha);
    @memcpy(result.started[0..wire.started_at.len], wire.started_at);
    @memcpy(result.completed[0..wire.completed_at.len], wire.completed_at);
    result.run_id = wire.run_id;
    result.run_attempt = wire.run_attempt;
    result.started_len = wire.started_at.len;
    result.completed_len = wire.completed_at.len;
    result.duration_ms = derived;
    result.owner = result;
    result.seal = metadataSeal(result);
}

fn validateFixed(wire: Wire) !void {
    if (!std.mem.eql(u8, wire.schema, schema) or !std.mem.eql(u8, wire.repository, repository) or
        !std.mem.eql(u8, wire.workflow, workflow) or !std.mem.eql(u8, wire.job_name, job_name) or
        !std.mem.eql(u8, wire.step_name, step_name) or wire.run_id == 0 or wire.run_attempt == 0 or
        wire.source_sha.len != 40 or wire.started_at.len == 0 or wire.started_at.len > timestamp_cap or
        wire.completed_at.len == 0 or wire.completed_at.len > timestamp_cap) return error.InvalidRecord;
    if (!validSource(wire.source_sha)) return error.InvalidRecord;
}

fn parseTimestamp(input: []const u8) !ParsedTimestamp {
    if (input.len < 20 or input.len > timestamp_cap or input[4] != '-' or input[7] != '-' or
        input[10] != 'T' or input[13] != ':' or input[16] != ':') return error.InvalidTimestamp;
    const year = try decimal(u16, input[0..4]);
    const month = try decimal(u8, input[5..7]);
    const day = try decimal(u8, input[8..10]);
    const hour = try decimal(u8, input[11..13]);
    const minute = try decimal(u8, input[14..16]);
    const second = try decimal(u8, input[17..19]);
    if (year < 1970 or month == 0 or month > 12 or day == 0 or day > daysInMonth(year, month) or
        hour > 23 or minute > 59 or second > 59) return error.InvalidTimestamp;

    var cursor: usize = 19;
    var fraction_ns: u32 = 0;
    if (cursor < input.len and input[cursor] == '.') {
        cursor += 1;
        const fraction_start = cursor;
        while (cursor < input.len and std.ascii.isDigit(input[cursor])) : (cursor += 1) {
            if (cursor - fraction_start == 9) return error.InvalidTimestamp;
            fraction_ns = fraction_ns * 10 + (input[cursor] - '0');
        }
        const digits = cursor - fraction_start;
        if (digits == 0) return error.InvalidTimestamp;
        var remaining = 9 - digits;
        while (remaining > 0) : (remaining -= 1) fraction_ns *= 10;
    }

    var offset_seconds: i128 = 0;
    if (cursor < input.len and input[cursor] == 'Z') {
        cursor += 1;
    } else {
        if (cursor + 6 != input.len or (input[cursor] != '+' and input[cursor] != '-') or input[cursor + 3] != ':')
            return error.InvalidTimestamp;
        const offset_hour = try decimal(u8, input[cursor + 1 .. cursor + 3]);
        const offset_minute = try decimal(u8, input[cursor + 4 .. cursor + 6]);
        if (offset_hour > 23 or offset_minute > 59) return error.InvalidTimestamp;
        offset_seconds = @as(i128, offset_hour) * 3600 + @as(i128, offset_minute) * 60;
        if (input[cursor] == '-') offset_seconds = -offset_seconds;
        cursor += 6;
    }
    if (cursor != input.len) return error.InvalidTimestamp;

    const local_seconds = @as(i128, daysSinceEpoch(year, month, day)) * 86400 +
        @as(i128, hour) * 3600 + @as(i128, minute) * 60 + @as(i128, second);
    const utc_seconds = local_seconds - offset_seconds;
    if (utc_seconds < 0) return error.InvalidTimestamp;
    const epoch_ns = utc_seconds * std.time.ns_per_s + fraction_ns;
    return .{ .epoch_ns = epoch_ns, .epoch_ms = @intCast(@divFloor(epoch_ns, std.time.ns_per_ms)) };
}

fn decimal(comptime T: type, bytes: []const u8) !T {
    if (bytes.len == 0) return error.InvalidTimestamp;
    var value: T = 0;
    for (bytes) |byte| {
        if (!std.ascii.isDigit(byte)) return error.InvalidTimestamp;
        value = value * 10 + @as(T, @intCast(byte - '0'));
    }
    return value;
}

fn daysSinceEpoch(year: u16, month: u8, day: u8) u64 {
    var days: u64 = 0;
    var current_year: u16 = 1970;
    while (current_year < year) : (current_year += 1) days += if (leap(current_year)) 366 else 365;
    var current_month: u8 = 1;
    while (current_month < month) : (current_month += 1) days += daysInMonth(year, current_month);
    return days + day - 1;
}

fn daysInMonth(year: u16, month: u8) u8 {
    return switch (month) {
        1, 3, 5, 7, 8, 10, 12 => 31,
        4, 6, 9, 11 => 30,
        2 => if (leap(year)) 29 else 28,
        else => 0,
    };
}

fn leap(year: u16) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn pristine(result: *const Record) bool {
    return result.owner == null and result.run_id == 0 and result.run_attempt == 0 and result.started_len == 0 and
        result.completed_len == 0 and result.duration_ms == 0 and allZero(&result.source) and allZero(&result.started) and
        allZero(&result.completed) and allZero(&result.seal);
}

fn validSource(source: []const u8) bool {
    if (source.len != 40) return false;
    for (source) |byte| if (!std.ascii.isDigit(byte) and (byte < 'a' or byte > 'f')) return false;
    return true;
}

fn metadataSeal(result: *const Record) [32]u8 {
    var hasher = std.crypto.hash.Blake3.init(.{});
    hasher.update(std.mem.asBytes(&result.run_id));
    hasher.update(std.mem.asBytes(&result.run_attempt));
    hasher.update(&result.source);
    hasher.update(std.mem.asBytes(&result.started_len));
    hasher.update(result.started[0..result.started_len]);
    hasher.update(std.mem.asBytes(&result.completed_len));
    hasher.update(result.completed[0..result.completed_len]);
    hasher.update(std.mem.asBytes(&result.duration_ms));
    var seal: [32]u8 = undefined;
    hasher.final(&seal);
    return seal;
}

fn allZero(bytes: []const u8) bool {
    for (bytes) |byte| if (byte != 0) return false;
    return true;
}

fn overlaps(left: []const u8, right: []const u8) bool {
    if (left.len == 0 or right.len == 0) return false;
    const left_start = @intFromPtr(left.ptr);
    const right_start = @intFromPtr(right.ptr);
    return left_start < right_start + right.len and right_start < left_start + left.len;
}
