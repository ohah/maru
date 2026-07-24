//! Same-PID exec를 넘어 살아남는 upgrade attempt/terminal-idempotency ledger codec.
//!
//! Raw process fd는 저장하지 않는다. runtime ID 집합, staged target과 rollback self-image의 exact inode identity를
//! 기록하며 target/rollback entry가 현재 process executable handle의 object identity와 검증한다.

const std = @import("std");
const wire = @import("upgrade_wire.zig");
const limits = @import("upgrade_limits.zig");
const handoff = @import("handoff_codec.zig");
const upgrade_wire = wire;

pub const schema_v2: u16 = 2;
pub const max_bytes = limits.max_attempt_record_bytes;
pub const max_runtime_count = limits.max_runtime_count;
pub const max_completed_count = limits.max_running_record_completed;
const max_path_bytes = limits.max_target_path_bytes;
const max_build_id_bytes = limits.max_build_id_bytes;
const header_len: usize = 48;
const magic = [8]u8{ 'M', 'R', 'U', 'A', 'T', 'P', '0', '1' };

pub const Error = std.mem.Allocator.Error || error{
    BadMagic,
    UnsupportedSchema,
    Truncated,
    TrailingBytes,
    ChecksumMismatch,
    InvalidValue,
    LimitExceeded,
    IntegerOverflow,
};

pub const CompletedView = struct {
    attempt_id: u128,
    request_path: []const u8,
    build_id: []const u8,
    sha256: [32]u8,
    reader_min: u16,
    reader_max: u16,
    report: wire.AttemptReport,
};

pub const ImageView = struct {
    /// Borrowed path. `View` encode 중에는 caller가 backing bytes를 소유하고, `State` accessor 결과는
    /// 해당 State의 `deinit` 전까지만 유효하다. 비동기 저장은 encode/copy로 ownership을 끊는다.
    path: []const u8,
    sha256: [32]u8,
    dev: i64,
    ino: u64,
    size: u64,
};

pub const View = struct {
    host_id: u128,
    attempt_id: u128,
    epoch_before: u64,
    expected_epoch_after: u64,
    /// Immutable handoff가 허용하는 rollback 횟수. target/backup이 같은 bytes를 읽으므로 소비 횟수가 아니다.
    rollback_budget: u8,
    request_path: []const u8,
    staged_path: []const u8,
    build_id: []const u8,
    sha256: [32]u8,
    dev: i64,
    ino: u64,
    size: u64,
    rollback_image: ImageView,
    reader_min: u16,
    reader_max: u16,
    runtime_ids: []const u128,
    completed: []const CompletedView,
};

pub const Completed = struct {
    attempt_id: u128,
    request_path: []u8,
    build_id: []u8,
    sha256: [32]u8,
    reader_min: u16,
    reader_max: u16,
    report: wire.AttemptReport,
};

pub const State = struct {
    allocator: std.mem.Allocator,
    host_id: u128,
    attempt_id: u128,
    epoch_before: u64,
    expected_epoch_after: u64,
    rollback_budget: u8,
    request_path: []u8,
    staged_path: []u8,
    build_id: []u8,
    sha256: [32]u8,
    dev: i64,
    ino: u64,
    size: u64,
    rollback_path: []u8,
    rollback_sha256: [32]u8,
    rollback_dev: i64,
    rollback_ino: u64,
    rollback_size: u64,
    reader_min: u16,
    reader_max: u16,
    runtime_ids: []u128,
    completed: []Completed,

    pub fn rollbackImage(self: State) ImageView {
        return .{
            .path = self.rollback_path,
            .sha256 = self.rollback_sha256,
            .dev = self.rollback_dev,
            .ino = self.rollback_ino,
            .size = self.rollback_size,
        };
    }

    pub fn targetImage(self: State) ImageView {
        return .{
            .path = self.staged_path,
            .sha256 = self.sha256,
            .dev = self.dev,
            .ino = self.ino,
            .size = self.size,
        };
    }

    pub fn deinit(self: *State) void {
        self.allocator.free(self.request_path);
        self.allocator.free(self.staged_path);
        self.allocator.free(self.build_id);
        self.allocator.free(self.rollback_path);
        self.allocator.free(self.runtime_ids);
        for (self.completed) |entry| {
            self.allocator.free(entry.request_path);
            self.allocator.free(entry.build_id);
        }
        self.allocator.free(self.completed);
        self.* = undefined;
    }
};

const Writer = struct {
    allocator: std.mem.Allocator,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
    }

    fn append(self: *Writer, data: []const u8) Error!void {
        const next = std.math.add(usize, self.bytes.items.len, data.len) catch return error.IntegerOverflow;
        if (next > max_bytes) return error.LimitExceeded;
        try self.bytes.appendSlice(self.allocator, data);
    }

    fn integer(self: *Writer, comptime T: type, value: T) Error!void {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        var buf: [n]u8 = undefined;
        std.mem.writeInt(T, &buf, value, .big);
        try self.append(&buf);
    }

    fn string(self: *Writer, value: []const u8, cap: usize) Error!void {
        if (value.len == 0 or value.len > cap or std.mem.indexOfScalar(u8, value, 0) != null)
            return error.InvalidValue;
        try self.integer(u16, @intCast(value.len));
        try self.append(value);
    }
};

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, len: usize) Error![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.IntegerOverflow;
        if (end > self.bytes.len) return error.Truncated;
        defer self.pos = end;
        return self.bytes[self.pos..end];
    }

    fn integer(self: *Reader, comptime T: type) Error!T {
        const n = @divExact(@typeInfo(T).int.bits, 8);
        const data = try self.take(n);
        return std.mem.readInt(T, @ptrCast(data.ptr), .big);
    }

    fn string(self: *Reader, allocator: std.mem.Allocator, cap: usize) Error![]u8 {
        const len = try self.integer(u16);
        if (len == 0 or len > cap) return error.InvalidValue;
        const value = try self.take(len);
        if (std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidValue;
        return allocator.dupe(u8, value);
    }
};

pub fn encode(allocator: std.mem.Allocator, view: View) Error![]u8 {
    try validateView(view);
    var writer: Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try writer.append(&([_]u8{0} ** header_len));
    try writer.integer(u128, view.host_id);
    try writer.integer(u128, view.attempt_id);
    try writer.integer(u64, view.epoch_before);
    try writer.integer(u64, view.expected_epoch_after);
    try writer.integer(u8, view.rollback_budget);
    try writer.integer(u8, 0);
    try writer.integer(u16, 0);
    try writer.integer(i64, view.dev);
    try writer.integer(u64, view.ino);
    try writer.integer(u64, view.size);
    try writer.append(&view.sha256);
    try writer.integer(u16, view.reader_min);
    try writer.integer(u16, view.reader_max);
    try writer.integer(u16, @intCast(view.runtime_ids.len));
    try writer.integer(u16, @intCast(view.completed.len));
    try writer.string(view.request_path, max_path_bytes);
    try writer.string(view.staged_path, max_path_bytes);
    try writer.string(view.build_id, max_build_id_bytes);
    try writer.integer(i64, view.rollback_image.dev);
    try writer.integer(u64, view.rollback_image.ino);
    try writer.integer(u64, view.rollback_image.size);
    try writer.append(&view.rollback_image.sha256);
    try writer.string(view.rollback_image.path, max_path_bytes);
    for (view.runtime_ids) |runtime_id| try writer.integer(u128, runtime_id);
    for (view.completed) |entry| {
        try writer.integer(u128, entry.attempt_id);
        try writer.integer(u8, @intFromEnum(entry.report.status));
        try writer.integer(u8, @intFromEnum(entry.report.reason));
        try writer.integer(u16, entry.reader_min);
        try writer.integer(u16, entry.reader_max);
        try writer.append(&entry.sha256);
        try writer.string(entry.request_path, max_path_bytes);
        try writer.string(entry.build_id, max_build_id_bytes);
    }
    const payload = writer.bytes.items[header_len..];
    @memcpy(writer.bytes.items[0..8], &magic);
    std.mem.writeInt(u16, writer.bytes.items[8..10], schema_v2, .big);
    std.mem.writeInt(u16, writer.bytes.items[10..12], 0, .big);
    std.mem.writeInt(u32, writer.bytes.items[12..16], @intCast(payload.len), .big);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    @memcpy(writer.bytes.items[16..48], &digest);
    return writer.bytes.toOwnedSlice(allocator);
}

pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!State {
    if (bytes.len > max_bytes) return error.LimitExceeded;
    if (bytes.len < header_len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &magic)) return error.BadMagic;
    if (std.mem.readInt(u16, bytes[8..10], .big) != schema_v2) return error.UnsupportedSchema;
    if (std.mem.readInt(u16, bytes[10..12], .big) != 0) return error.InvalidValue;
    const payload_len = std.mem.readInt(u32, bytes[12..16], .big);
    const expected_len = std.math.add(usize, header_len, payload_len) catch return error.IntegerOverflow;
    if (expected_len != bytes.len) return if (expected_len > bytes.len) error.Truncated else error.TrailingBytes;
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[header_len..], &digest, .{});
    if (!std.crypto.timing_safe.eql([32]u8, digest, bytes[16..48].*)) return error.ChecksumMismatch;

    var reader: Reader = .{ .bytes = bytes[header_len..] };
    const host_id = try reader.integer(u128);
    const attempt_id = try reader.integer(u128);
    const epoch_before = try reader.integer(u64);
    const expected_epoch_after = try reader.integer(u64);
    const rollback_budget = try reader.integer(u8);
    if (try reader.integer(u8) != 0) return error.InvalidValue;
    if (try reader.integer(u16) != 0) return error.InvalidValue;
    const dev = try reader.integer(i64);
    const ino = try reader.integer(u64);
    const size = try reader.integer(u64);
    const sha256 = (try reader.take(32))[0..32].*;
    const reader_min = try reader.integer(u16);
    const reader_max = try reader.integer(u16);
    const runtime_count = try reader.integer(u16);
    const completed_count = try reader.integer(u16);
    if (runtime_count > max_runtime_count or completed_count > max_completed_count) return error.LimitExceeded;
    const request_path = try reader.string(allocator, max_path_bytes);
    errdefer allocator.free(request_path);
    const staged_path = try reader.string(allocator, max_path_bytes);
    errdefer allocator.free(staged_path);
    const build_id = try reader.string(allocator, max_build_id_bytes);
    errdefer allocator.free(build_id);
    const rollback_dev = try reader.integer(i64);
    const rollback_ino = try reader.integer(u64);
    const rollback_size = try reader.integer(u64);
    const rollback_sha256 = (try reader.take(32))[0..32].*;
    const rollback_path = try reader.string(allocator, max_path_bytes);
    errdefer allocator.free(rollback_path);
    const runtime_ids = try allocator.alloc(u128, runtime_count);
    errdefer allocator.free(runtime_ids);
    for (runtime_ids) |*runtime_id| runtime_id.* = try reader.integer(u128);
    const completed = try allocator.alloc(Completed, completed_count);
    var completed_built: usize = 0;
    errdefer {
        for (completed[0..completed_built]) |entry| {
            allocator.free(entry.request_path);
            allocator.free(entry.build_id);
        }
        allocator.free(completed);
    }
    for (completed) |*entry| {
        const completed_id = try reader.integer(u128);
        const status = std.enums.fromInt(wire.AttemptStatus, try reader.integer(u8)) orelse
            return error.InvalidValue;
        const reason = std.enums.fromInt(wire.AttemptReason, try reader.integer(u8)) orelse
            return error.InvalidValue;
        const completed_reader_min = try reader.integer(u16);
        const completed_reader_max = try reader.integer(u16);
        const completed_sha = (try reader.take(32))[0..32].*;
        const completed_path = try reader.string(allocator, max_path_bytes);
        errdefer allocator.free(completed_path);
        const completed_build = try reader.string(allocator, max_build_id_bytes);
        entry.* = .{
            .attempt_id = completed_id,
            .request_path = completed_path,
            .build_id = completed_build,
            .sha256 = completed_sha,
            .reader_min = completed_reader_min,
            .reader_max = completed_reader_max,
            .report = .{ .status = status, .reason = reason },
        };
        completed_built += 1;
    }
    if (reader.pos != reader.bytes.len) return error.TrailingBytes;
    var result: State = .{
        .allocator = allocator,
        .host_id = host_id,
        .attempt_id = attempt_id,
        .epoch_before = epoch_before,
        .expected_epoch_after = expected_epoch_after,
        .rollback_budget = rollback_budget,
        .request_path = request_path,
        .staged_path = staged_path,
        .build_id = build_id,
        .sha256 = sha256,
        .dev = dev,
        .ino = ino,
        .size = size,
        .rollback_path = rollback_path,
        .rollback_sha256 = rollback_sha256,
        .rollback_dev = rollback_dev,
        .rollback_ino = rollback_ino,
        .rollback_size = rollback_size,
        .reader_min = reader_min,
        .reader_max = reader_max,
        .runtime_ids = runtime_ids,
        .completed = completed,
    };
    errdefer result.deinit();
    try validateDecoded(result);
    return result;
}

fn validateView(view: View) Error!void {
    if (view.host_id == 0 or view.rollback_budget != 1 or
        view.reader_min == 0 or view.reader_min > view.reader_max or view.runtime_ids.len > max_runtime_count or
        view.completed.len > max_completed_count or view.size == 0 or view.size > limits.max_staged_image_bytes or
        view.rollback_image.size == 0 or view.rollback_image.size > limits.max_staged_image_bytes or
        !validPath(view.request_path) or !validPath(view.staged_path) or
        !validPath(view.rollback_image.path) or
        std.mem.eql(u8, view.staged_path, view.rollback_image.path) or
        (view.dev == view.rollback_image.dev and view.ino == view.rollback_image.ino) or
        view.reader_min > handoff.schema_v1 or view.reader_max < handoff.schema_v1 or
        !buildIdMatches(view.build_id, view.sha256))
        return error.InvalidValue;
    const next = std.math.add(u64, view.epoch_before, 1) catch return error.InvalidValue;
    if (view.expected_epoch_after != next) return error.InvalidValue;
    var previous: u128 = 0;
    for (view.runtime_ids, 0..) |runtime_id, index| {
        if (index != 0 and runtime_id <= previous) return error.InvalidValue;
        previous = runtime_id;
    }
    for (view.completed, 0..) |entry, index| {
        if (entry.reader_min == 0 or entry.reader_min > entry.reader_max or
            entry.reader_min > handoff.schema_v1 or entry.reader_max < handoff.schema_v1 or
            !wire.validReport(entry.report) or entry.report.status == .pending or
            !validPath(entry.request_path) or
            !buildIdMatches(entry.build_id, entry.sha256))
            return error.InvalidValue;
        if (entry.attempt_id == view.attempt_id) return error.InvalidValue;
        for (view.completed[0..index]) |prior|
            if (prior.attempt_id == entry.attempt_id) return error.InvalidValue;
    }
}

fn validPath(path: []const u8) bool {
    return path.len != 0 and path.len <= max_path_bytes and path[0] == '/' and
        std.mem.indexOfScalar(u8, path, 0) == null and std.unicode.utf8ValidateSlice(path);
}

pub fn validateDecoded(state: State) Error!void {
    if (state.completed.len > max_completed_count) return error.LimitExceeded;
    var completed_views: [max_completed_count]CompletedView = undefined;
    for (state.completed, 0..) |entry, index| completed_views[index] = .{
        .attempt_id = entry.attempt_id,
        .request_path = entry.request_path,
        .build_id = entry.build_id,
        .sha256 = entry.sha256,
        .reader_min = entry.reader_min,
        .reader_max = entry.reader_max,
        .report = entry.report,
    };
    return validateView(.{
        .host_id = state.host_id,
        .attempt_id = state.attempt_id,
        .epoch_before = state.epoch_before,
        .expected_epoch_after = state.expected_epoch_after,
        .rollback_budget = state.rollback_budget,
        .request_path = state.request_path,
        .staged_path = state.staged_path,
        .build_id = state.build_id,
        .sha256 = state.sha256,
        .dev = state.dev,
        .ino = state.ino,
        .size = state.size,
        .rollback_image = .{
            .path = state.rollback_path,
            .sha256 = state.rollback_sha256,
            .dev = state.rollback_dev,
            .ino = state.rollback_ino,
            .size = state.rollback_size,
        },
        .reader_min = state.reader_min,
        .reader_max = state.reader_max,
        .runtime_ids = state.runtime_ids,
        .completed = completed_views[0..state.completed.len],
    });
}

fn buildIdMatches(build_id: []const u8, digest: [32]u8) bool {
    if (build_id.len != "sha256:".len + 64 or !std.mem.startsWith(u8, build_id, "sha256:")) return false;
    const expected = std.fmt.bytesToHex(digest, .lower);
    return std.mem.eql(u8, build_id["sha256:".len..], &expected);
}

const test_rollback_image: ImageView = .{
    .path = "/tmp/maru/rollback-current",
    .sha256 = [_]u8{0x33} ** 32,
    .dev = 7,
    .ino = 8,
    .size = 9,
};

test "upgrade attempt record round-trips running authority runtime set and completed ledger" {
    const completed = [_]CompletedView{.{
        .attempt_id = 0x10,
        .request_path = "/Applications/old",
        .build_id = "sha256:1111111111111111111111111111111111111111111111111111111111111111",
        .sha256 = [_]u8{0x11} ** 32,
        .reader_min = 1,
        .reader_max = 1,
        .report = .{ .status = .resumed, .reason = .exec_failed },
    }};
    const encoded = try encode(std.testing.allocator, .{
        .host_id = 0xAA,
        .attempt_id = 0x20,
        .epoch_before = 7,
        .expected_epoch_after = 8,
        .rollback_budget = 1,
        .request_path = "/Applications/Maru.app/Contents/MacOS/maru",
        .staged_path = "/tmp/maru/attempt/target",
        .build_id = "sha256:2222222222222222222222222222222222222222222222222222222222222222",
        .sha256 = [_]u8{0x22} ** 32,
        .dev = 4,
        .ino = 5,
        .size = 6,
        .rollback_image = test_rollback_image,
        .reader_min = 1,
        .reader_max = 1,
        .runtime_ids = &.{ 2, 9 },
        .completed = &completed,
    });
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqual(schema_v2, std.mem.readInt(u16, encoded[8..10], .big));
    var decoded = try decode(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(u128, 0x20), decoded.attempt_id);
    try std.testing.expectEqualSlices(u128, &.{ 2, 9 }, decoded.runtime_ids);
    try std.testing.expectEqual(wire.AttemptStatus.resumed, decoded.completed[0].report.status);
    try std.testing.expectEqualStrings("/tmp/maru/attempt/target", decoded.staged_path);
    try std.testing.expectEqualStrings(test_rollback_image.path, decoded.rollback_path);
    try std.testing.expectEqual(test_rollback_image.ino, decoded.rollback_ino);
    decoded.staged_path[1] = 0;
    try std.testing.expectError(error.InvalidValue, validateDecoded(decoded));
    decoded.staged_path[1] = 't';
    const original_staged_path = decoded.staged_path;
    const oversized_path = try std.testing.allocator.alloc(u8, max_path_bytes + 1);
    defer std.testing.allocator.free(oversized_path);
    @memset(oversized_path, 'x');
    oversized_path[0] = '/';
    decoded.staged_path = oversized_path;
    try std.testing.expectError(error.InvalidValue, validateDecoded(decoded));
    decoded.staged_path = original_staged_path;
    decoded.rollback_path[1] = 0;
    try std.testing.expectError(error.InvalidValue, validateDecoded(decoded));
    decoded.rollback_path[1] = 't';
    const original_rollback_path = decoded.rollback_path;
    decoded.rollback_path = decoded.staged_path;
    try std.testing.expectError(error.InvalidValue, validateDecoded(decoded));
    decoded.rollback_path = original_rollback_path;
    const original_rollback_dev = decoded.rollback_dev;
    const original_rollback_ino = decoded.rollback_ino;
    decoded.rollback_dev = decoded.dev;
    decoded.rollback_ino = decoded.ino;
    try std.testing.expectError(error.InvalidValue, validateDecoded(decoded));
    decoded.rollback_dev = original_rollback_dev;
    decoded.rollback_ino = original_rollback_ino;

    const host_bytes = try handoff.encodeHost(std.testing.allocator, .{
        .host_id = 0xAA,
        .upgrade_epoch = 7,
        .next_handle = 1,
        .runtimes = &.{},
        .attempt_record = encoded,
    });
    defer std.testing.allocator.free(host_bytes);
    var host = try handoff.decodeHost(std.testing.allocator, host_bytes);
    defer host.deinit();
    var nested = try decode(std.testing.allocator, host.attempt_record.?);
    defer nested.deinit();
    try std.testing.expectEqual(@as(u64, 8), nested.expected_epoch_after);

    var saw_success = false;
    for (0..64) |fail_index| {
        var failing = std.testing.FailingAllocator.init(
            std.testing.allocator,
            .{ .fail_index = fail_index },
        );
        var failed_state = decode(failing.allocator(), encoded) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        failed_state.deinit();
        saw_success = true;
        break;
    }
    try std.testing.expect(saw_success);
}

test "upgrade attempt record rejects checksum ordering and cap violations" {
    const encoded = try encode(std.testing.allocator, .{
        .host_id = 0xAA,
        .attempt_id = 1,
        .epoch_before = 0,
        .expected_epoch_after = 1,
        .rollback_budget = 1,
        .request_path = "/a",
        .staged_path = "/b",
        .build_id = "sha256:0101010101010101010101010101010101010101010101010101010101010101",
        .sha256 = [_]u8{1} ** 32,
        .dev = 1,
        .ino = 2,
        .size = 3,
        .rollback_image = test_rollback_image,
        .reader_min = 1,
        .reader_max = 1,
        .runtime_ids = &.{1},
        .completed = &.{},
    });
    defer std.testing.allocator.free(encoded);
    const corrupt = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(corrupt);
    corrupt[corrupt.len - 1] ^= 1;
    try std.testing.expectError(error.ChecksumMismatch, decode(std.testing.allocator, corrupt));
    const old_schema = try std.testing.allocator.dupe(u8, encoded);
    defer std.testing.allocator.free(old_schema);
    std.mem.writeInt(u16, old_schema[8..10], 1, .big);
    try std.testing.expectError(error.UnsupportedSchema, decode(std.testing.allocator, old_schema));
    try std.testing.expectError(error.InvalidValue, encode(std.testing.allocator, .{
        .host_id = 0xAA,
        .attempt_id = 1,
        .epoch_before = 0,
        .expected_epoch_after = 1,
        .rollback_budget = 1,
        .request_path = "/a",
        .staged_path = "/b",
        .build_id = "sha256:0101010101010101010101010101010101010101010101010101010101010101",
        .sha256 = [_]u8{1} ** 32,
        .dev = 1,
        .ino = 2,
        .size = 3,
        .rollback_image = test_rollback_image,
        .reader_min = 1,
        .reader_max = 1,
        .runtime_ids = &.{ 2, 1 },
        .completed = &.{},
    }));
    const oversized = try std.testing.allocator.alloc(u8, max_bytes + 1);
    defer std.testing.allocator.free(oversized);
    try std.testing.expectError(error.LimitExceeded, decode(std.testing.allocator, oversized));
}

test "running attempt record permits opaque zero id and reserves one terminal history slot" {
    var completed: [limits.max_completed_history]CompletedView = undefined;
    for (&completed, 0..) |*entry, index| entry.* = .{
        .attempt_id = index,
        .request_path = "/old",
        .build_id = "sha256:0101010101010101010101010101010101010101010101010101010101010101",
        .sha256 = [_]u8{1} ** 32,
        .reader_min = 1,
        .reader_max = 1,
        .report = .{ .status = .committed },
    };
    const view: View = .{
        .host_id = 0xAA,
        .attempt_id = std.math.maxInt(u128),
        .epoch_before = 0,
        .expected_epoch_after = 1,
        .rollback_budget = 1,
        .request_path = "/a",
        .staged_path = "/b",
        .build_id = "sha256:0202020202020202020202020202020202020202020202020202020202020202",
        .sha256 = [_]u8{2} ** 32,
        .dev = 1,
        .ino = 2,
        .size = 3,
        .rollback_image = test_rollback_image,
        .reader_min = 1,
        .reader_max = 1,
        .runtime_ids = &.{0},
        .completed = completed[0..limits.max_running_record_completed],
    };
    const encoded = try encode(std.testing.allocator, view);
    defer std.testing.allocator.free(encoded);
    var decoded = try decode(std.testing.allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(limits.max_running_record_completed, decoded.completed.len);
    var too_many = view;
    too_many.completed = &completed;
    try std.testing.expectError(error.InvalidValue, encode(std.testing.allocator, too_many));

    var zero = view;
    zero.attempt_id = 0;
    zero.completed = &.{};
    const zero_bytes = try encode(std.testing.allocator, zero);
    defer std.testing.allocator.free(zero_bytes);
    var zero_state = try decode(std.testing.allocator, zero_bytes);
    defer zero_state.deinit();
    try std.testing.expectEqual(@as(u128, 0), zero_state.attempt_id);
}
