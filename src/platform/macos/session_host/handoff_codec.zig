//! `maru.host-handoff.v1` logical TerminalCore codec(U1).
//!
//! 이 wire는 MRSH/screen snapshot과 독립이다. native struct dump나 field 순서를 wire로 쓰지 않고, 아래
//! `core_fields_v1`의 명시적 stable tag가 v1 schema다. U0 inventory는 이 목록의 coverage만 검증한다.
//! decode는 새 candidate core를 완성·검증한 뒤 반환하므로 live owner를 부분 mutate하지 않는다.

const std = @import("std");
const maru = @import("maru");
const inventory = @import("handoff_inventory.zig");
const upgrade_limits = @import("upgrade_limits.zig");

const TerminalCore = maru.terminal.TerminalCore;
const Screen = @FieldType(TerminalCore, "screen");
const Scrollback = @FieldType(Screen, "sb");
const KittyImageStorage = @FieldType(TerminalCore, "kitty_images");
const KittyImage = @FieldType(@FieldType(KittyImageStorage, "map").KV, "value");
const Cell = maru.terminal.Cell;

pub const schema_v1: u16 = 1;
pub const reader_min: u16 = 1;
pub const reader_max: u16 = 1;

pub const max_total_bytes: u64 = 8 * 1024 * 1024 * 1024;
pub const max_runtime_section_bytes: u64 = 1024 * 1024 * 1024;
pub const max_single_blob_bytes: u64 = 512 * 1024 * 1024;
pub const max_grid_cells: usize = 16_777_216;
pub const max_scrollback_rows: usize = 100_000;
pub const max_store_entries: usize = 1_000_000;
pub const max_link_bytes: usize = 64 * 1024 * 1024;
pub const max_grapheme_bytes: usize = 64 * 1024 * 1024;
pub const max_link_len: usize = 1024 * 1024;
pub const max_grapheme_codepoints: usize = 4096;

const magic = [8]u8{ 'M', 'R', 'U', 'H', 'O', 'F', '0', '1' };
const envelope_header_len = 64;
const tlv_header_len = 16;
const flag_optional: u16 = 1;
const section_terminal_core: u32 = 1;
const section_host_meta: u32 = 2;
const section_runtime: u32 = 3;
const section_attempt_record: u32 = 4;
const section_notification_journal: u32 = 5;
const section_notification_metadata: u32 = 6;
pub const max_runtime_count = upgrade_limits.max_runtime_count;
pub const max_attempt_record_bytes = upgrade_limits.max_attempt_record_bytes;
pub const max_notification_handoff_bytes: usize = 2 * 1024 * 1024;
pub const max_notification_metadata_handoff_bytes: usize = 128 * 1024;
const max_section_count: usize = max_runtime_count + 4;

pub const Error = std.mem.Allocator.Error || error{
    BadMagic,
    UnsupportedSchema,
    Truncated,
    TrailingBytes,
    ChecksumMismatch,
    DuplicateField,
    UnknownRequiredField,
    MissingRequiredField,
    InvalidValue,
    InvalidReference,
    LimitExceeded,
    IntegerOverflow,
};

const FieldSpec = struct {
    tag: u32,
    name: []const u8,
    /// **구 writer가 안 보냈어도 decode를 실패시키지 않는** 필드. v1에 뒤늦게 추가된 tag는 반드시 이것이어야 한다 —
    /// 필수로 두면 N-1 host가 인코딩한 레코드에 그 tag가 없어 `MissingRequiredField`로 떨어지고, 실행 중 업그레이드가
    /// 통째로 막힌다(docs/session-host-upgrade.md의 "required/optional field tag" 계약). 값이 없으면 그 필드는 새 core의
    /// 기본값으로 남고, 셸이 다음에 보고할 때 채워진다.
    optional: bool = false,
};

// Stable v1 wire tags. Never derive these from native field order. A native rename updates `name` while retaining its
// tag; a semantic/type change requires a new schema reader/converter.
const core_fields_v1 = [_]FieldSpec{
    .{ .tag = 1, .name = "size" },
    .{ .tag = 2, .name = "screen" },
    .{ .tag = 3, .name = "utf8_tail" },
    .{ .tag = 4, .name = "utf8_tail_len" },
    .{ .tag = 5, .name = "parser" },
    .{ .tag = 6, .name = "csi_params" },
    .{ .tag = 7, .name = "csi_param_count" },
    .{ .tag = 8, .name = "csi_has_digit" },
    .{ .tag = 9, .name = "csi_marker" },
    .{ .tag = 10, .name = "csi_intermediate" },
    .{ .tag = 11, .name = "csi_overflow" },
    .{ .tag = 12, .name = "scroll_top" },
    .{ .tag = 13, .name = "scroll_bottom" },
    .{ .tag = 14, .name = "origin_mode" },
    .{ .tag = 15, .name = "alt_active" },
    .{ .tag = 16, .name = "application_cursor_keys" },
    .{ .tag = 17, .name = "application_keypad" },
    .{ .tag = 18, .name = "alternate_scroll" },
    .{ .tag = 19, .name = "bracketed_paste" },
    .{ .tag = 20, .name = "focus_events" },
    .{ .tag = 21, .name = "mouse_tracking" },
    .{ .tag = 22, .name = "mouse_format" },
    .{ .tag = 23, .name = "sync_output" },
    .{ .tag = 24, .name = "sync_esu_count" },
    .{ .tag = 25, .name = "sync_bsu_count" },
    .{ .tag = 26, .name = "kitty_flags" },
    .{ .tag = 27, .name = "grapheme_cluster_mode" },
    .{ .tag = 28, .name = "cursor_visible" },
    .{ .tag = 29, .name = "cursor_shape" },
    .{ .tag = 30, .name = "cursor_blink" },
    .{ .tag = 31, .name = "saved_screen" },
    .{ .tag = 32, .name = "csi_subparam" },
    .{ .tag = 33, .name = "semantic_state" },
    .{ .tag = 34, .name = "last_command_exit" },
    .{ .tag = 35, .name = "shell_events" },
    .{ .tag = 36, .name = "shell_events_overflow" },
    .{ .tag = 37, .name = "ambiguous_wide" },
    .{ .tag = 38, .name = "emoji_wide" },
    .{ .tag = 39, .name = "view_offset" },
    .{ .tag = 40, .name = "selection_anchor" },
    .{ .tag = 41, .name = "selection_head" },
    .{ .tag = 42, .name = "selection_block" },
    .{ .tag = 43, .name = "link_store" },
    .{ .tag = 44, .name = "pen_link" },
    .{ .tag = 45, .name = "grapheme_store" },
    .{ .tag = 46, .name = "osc_buffer" },
    .{ .tag = 47, .name = "osc_overflow" },
    .{ .tag = 48, .name = "osc_large_ok" },
    .{ .tag = 49, .name = "dcs_buffer" },
    .{ .tag = 50, .name = "dcs_len" },
    .{ .tag = 51, .name = "dcs_overflow" },
    .{ .tag = 52, .name = "apc_buffer" },
    .{ .tag = 53, .name = "apc_overflow" },
    .{ .tag = 54, .name = "kitty_chunk" },
    .{ .tag = 55, .name = "kitty_chunk_cmd" },
    .{ .tag = 56, .name = "cell_width_px" },
    .{ .tag = 57, .name = "cell_height_px" },
    .{ .tag = 58, .name = "default_fg_rgb" },
    .{ .tag = 59, .name = "default_bg_rgb" },
    .{ .tag = 60, .name = "default_fg_override" },
    .{ .tag = 61, .name = "default_bg_override" },
    .{ .tag = 62, .name = "palette_override" },
    .{ .tag = 63, .name = "config_palette" },
    .{ .tag = 64, .name = "clipboard_write" },
    .{ .tag = 65, .name = "clipboard_write_rejected" },
    .{ .tag = 66, .name = "clipboard_read_pending" },
    .{ .tag = 67, .name = "clipboard_read_target" },
    .{ .tag = 68, .name = "notification_pending" },
    .{ .tag = 69, .name = "notification_title" },
    .{ .tag = 70, .name = "notification_body" },
    .{ .tag = 71, .name = "agent_progress" },
    .{ .tag = 72, .name = "charset_g0" },
    .{ .tag = 73, .name = "charset_g1" },
    .{ .tag = 74, .name = "charset_gl" },
    .{ .tag = 75, .name = "escape_intermediate_byte" },
    .{ .tag = 76, .name = "tabstops" },
    .{ .tag = 77, .name = "bell_pending" },
    .{ .tag = 78, .name = "insert_mode" },
    .{ .tag = 79, .name = "autowrap" },
    .{ .tag = 80, .name = "reverse_screen" },
    .{ .tag = 81, .name = "kitty_images" },
    .{ .tag = 82, .name = "kitty_placements" },
    .{ .tag = 83, .name = "cwd" },
    .{ .tag = 84, .name = "ssh_remote_dest" },
    .{ .tag = 85, .name = "title" },
    .{ .tag = 86, .name = "title_generation" },
    .{ .tag = 87, .name = "observer_generation" },
    .{ .tag = 88, .name = "default_cursor_shape" },
    .{ .tag = 89, .name = "cursor_shape_overridden" },
    // cwd(83)와 한 쌍인 OSC 7 authority. 기존 태그를 재사용하지 않고 새 태그를 붙인다 — 태그는 stable schema라
    // 옛 host가 쓴 레코드를 새 host가 읽을 때 의미가 바뀌면 안 된다. **optional이어야 한다**: v1에 뒤늦게 추가된
    // 필드라 N-1 host가 인코딩한 레코드에는 이 태그가 아예 없고, 필수로 두면 그 레코드가 `MissingRequiredField`로
    // 거부돼 실행 중 업그레이드가 막힌다. 없으면 `null`(=로컬 취급)로 남고 다음 OSC 7 보고가 채운다.
    //
    // 그동안 cwd만 남고 host가 비어 **원격 경로가 로컬로 보이는 창**이 생기는데, 이는 이관 직후 다음 프롬프트까지의
    // 짧은 구간이고 그 방향의 degrade는 안전하다(폴더줄이 예전처럼 브랜치 조건에 묶일 뿐 — ssh-integration.md §9.5의
    // "보고자가 없을 때" 상태와 같다). 반대로 업그레이드를 막는 쪽은 세션 전체를 잃는다.
    .{ .tag = 90, .name = "cwd_host", .optional = true },
    // N2a overflow observability. Old writers did not expose this one-shot bit, so absence safely
    // means false; new writers preserve it rather than losing the bounded drop at same-PID exec.
    .{ .tag = 91, .name = "notification_write_rejected", .optional = true },
};

comptime {
    @setEvalBranchQuota(100_000);
    var covered: usize = 0;
    for (inventory.terminal_core_groups) |group| {
        if (group.disposition != .serialized) continue;
        for (group.fields) |field_name| {
            var matches: usize = 0;
            for (core_fields_v1) |spec| if (std.mem.eql(u8, spec.name, field_name)) {
                matches += 1;
            };
            if (matches != 1) @compileError("handoff v1 must map each serialized TerminalCore field exactly once: " ++ field_name);
            covered += 1;
        }
    }
    if (covered != core_fields_v1.len) @compileError("handoff v1 contains a non-serialized or duplicate TerminalCore field");
    for (core_fields_v1, 0..) |spec, index| {
        if (!@hasField(TerminalCore, spec.name)) @compileError("handoff v1 references a missing TerminalCore field: " ++ spec.name);
        for (core_fields_v1[0..index]) |prior| {
            if (prior.tag == spec.tag) @compileError("handoff v1 duplicate stable tag");
            if (std.mem.eql(u8, prior.name, spec.name)) @compileError("handoff v1 duplicate native field mapping");
        }
    }
}

const Writer = struct {
    allocator: std.mem.Allocator,
    max_bytes: u64 = max_total_bytes,
    bytes: std.ArrayList(u8) = .empty,

    fn deinit(self: *Writer) void {
        self.bytes.deinit(self.allocator);
    }

    fn append(self: *Writer, data: []const u8) Error!void {
        const next = std.math.add(usize, self.bytes.items.len, data.len) catch return error.IntegerOverflow;
        if (@as(u64, @intCast(next)) > @min(max_total_bytes, self.max_bytes))
            return error.LimitExceeded;
        try self.bytes.appendSlice(self.allocator, data);
    }

    fn byte(self: *Writer, value: u8) Error!void {
        try self.append(&.{value});
    }

    fn integer(self: *Writer, comptime T: type, value: T) Error!void {
        const info = @typeInfo(T).int;
        const U = std.meta.Int(.unsigned, info.bits);
        const Storage = std.meta.Int(.unsigned, @max(info.bits, 8));
        const unsigned: U = if (info.signedness == .signed) @bitCast(value) else value;
        const stored: Storage = unsigned;
        const n = (info.bits + 7) / 8;
        var buf: [n]u8 = undefined;
        inline for (0..n) |index| {
            const shift = (n - 1 - index) * 8;
            buf[index] = @truncate(stored >> shift);
        }
        try self.append(&buf);
    }

    fn beginTlv(self: *Writer, tag: u32, flags: u16) Error!usize {
        const start = self.bytes.items.len;
        try self.integer(u32, tag);
        try self.integer(u16, flags);
        try self.integer(u16, 0);
        try self.integer(u64, 0);
        return start;
    }

    fn endTlv(self: *Writer, start: usize) Error!void {
        const body_start = std.math.add(usize, start, tlv_header_len) catch return error.IntegerOverflow;
        if (body_start > self.bytes.items.len) return error.InvalidValue;
        const len = self.bytes.items.len - body_start;
        if (@as(u64, @intCast(len)) > max_single_blob_bytes) return error.LimitExceeded;
        var buf: [8]u8 = undefined;
        std.mem.writeInt(u64, &buf, @intCast(len), .big);
        @memcpy(self.bytes.items[start + 8 .. start + 16], &buf);
    }
};

fn finishEnvelope(writer: *Writer, section_count: u16) Error![]u8 {
    const payload = writer.bytes.items[envelope_header_len..];
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    @memcpy(writer.bytes.items[0..8], &magic);
    std.mem.writeInt(u16, writer.bytes.items[8..10], schema_v1, .big);
    std.mem.writeInt(u16, writer.bytes.items[10..12], reader_min, .big);
    std.mem.writeInt(u16, writer.bytes.items[12..14], reader_max, .big);
    std.mem.writeInt(u16, writer.bytes.items[14..16], section_count, .big);
    std.mem.writeInt(u64, writer.bytes.items[16..24], @intCast(payload.len), .big);
    @memcpy(writer.bytes.items[24..56], &digest);
    @memset(writer.bytes.items[56..64], 0);
    return writer.bytes.toOwnedSlice(writer.allocator);
}

const Envelope = struct {
    section_count: u16,
    payload: []const u8,
};

fn readEnvelope(bytes: []const u8, payload_cap: u64) Error!Envelope {
    if (@as(u64, @intCast(bytes.len)) > max_total_bytes) return error.LimitExceeded;
    if (bytes.len < envelope_header_len) return error.Truncated;
    if (!std.mem.eql(u8, bytes[0..8], &magic)) return error.BadMagic;
    const schema = std.mem.readInt(u16, bytes[8..10], .big);
    if (schema != schema_v1) return error.UnsupportedSchema;
    if (std.mem.readInt(u16, bytes[10..12], .big) > reader_max or
        std.mem.readInt(u16, bytes[12..14], .big) < reader_min) return error.UnsupportedSchema;
    const payload_len = std.mem.readInt(u64, bytes[16..24], .big);
    if (payload_len > payload_cap) return error.LimitExceeded;
    const payload_len_usize = std.math.cast(usize, payload_len) orelse return error.LimitExceeded;
    const expected_len = std.math.add(usize, envelope_header_len, payload_len_usize) catch return error.IntegerOverflow;
    if (expected_len != bytes.len) return if (expected_len > bytes.len) error.Truncated else error.TrailingBytes;
    var actual_digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes[envelope_header_len..], &actual_digest, .{});
    if (!std.crypto.timing_safe.eql([32]u8, actual_digest, bytes[24..56].*)) return error.ChecksumMismatch;
    return .{
        .section_count = std.mem.readInt(u16, bytes[14..16], .big),
        .payload = bytes[envelope_header_len..],
    };
}

const Reader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn take(self: *Reader, len: usize) Error![]const u8 {
        const end = std.math.add(usize, self.pos, len) catch return error.IntegerOverflow;
        if (end > self.bytes.len) return error.Truncated;
        defer self.pos = end;
        return self.bytes[self.pos..end];
    }

    fn byte(self: *Reader) Error!u8 {
        return (try self.take(1))[0];
    }

    fn integer(self: *Reader, comptime T: type) Error!T {
        const info = @typeInfo(T).int;
        const U = std.meta.Int(.unsigned, info.bits);
        const Storage = std.meta.Int(.unsigned, @max(info.bits, 8));
        const n = (info.bits + 7) / 8;
        const data = try self.take(n);
        var stored: Storage = 0;
        for (data, 0..) |b, index| {
            const shift: std.math.Log2Int(Storage) = @intCast((n - 1 - index) * 8);
            stored |= @as(Storage, b) << shift;
        }
        const value: U = @truncate(stored);
        return if (info.signedness == .signed) @bitCast(value) else value;
    }

    fn sub(self: *Reader, len: usize) Error!Reader {
        return .{ .bytes = try self.take(len) };
    }

    fn finish(self: *const Reader) Error!void {
        if (self.pos != self.bytes.len) return error.TrailingBytes;
    }
};

fn isArrayList(comptime T: type) bool {
    const info = @typeInfo(T);
    if (info != .@"struct") return false;
    const fields = info.@"struct".fields;
    return fields.len == 2 and
        std.mem.eql(u8, fields[0].name, "items") and
        std.mem.eql(u8, fields[1].name, "capacity") and
        @typeInfo(fields[0].type) == .pointer and
        @typeInfo(fields[0].type).pointer.size == .slice and
        fields[1].type == usize;
}

fn arrayListChild(comptime T: type) type {
    return @typeInfo(@typeInfo(T).@"struct".fields[0].type).pointer.child;
}

fn encodeLength(writer: *Writer, len: usize, elem_size: usize) Error!void {
    const bytes = std.math.mul(usize, len, elem_size) catch return error.IntegerOverflow;
    if (@as(u64, @intCast(bytes)) > max_single_blob_bytes) return error.LimitExceeded;
    try writer.integer(u64, @intCast(len));
}

fn encodeScrollback(writer: *Writer, sb: *const Scrollback) Error!void {
    if (sb.cap > max_scrollback_rows or sb.count > max_scrollback_rows or sb.count > sb.cap)
        return error.LimitExceeded;
    if (sb.pushed_abs != std.math.add(usize, sb.evicted_abs, sb.count) catch return error.IntegerOverflow)
        return error.InvalidValue;
    try writer.integer(usize, sb.cap);
    try writer.integer(usize, sb.evicted_abs);
    try writer.integer(usize, sb.pushed_abs);
    try writer.byte(@intFromBool(sb.rewrap_pending));
    try writer.integer(usize, sb.count);
    for (0..sb.count) |index| {
        const row = sb.row(index) orelse return error.InvalidValue;
        try encodeLength(writer, row.len, @sizeOf(Cell));
        for (row) |cell| try encodeValue(writer, Cell, &cell);
        try writer.byte(@intFromBool(sb.rowWrapped(index)));
        const prompt = sb.rowPrompt(index);
        try encodeValue(writer, @TypeOf(prompt), &prompt);
    }
}

fn decodeScrollback(reader: *Reader, allocator: std.mem.Allocator) Error!Scrollback {
    const cap = try reader.integer(usize);
    const evicted_abs = try reader.integer(usize);
    const pushed_abs = try reader.integer(usize);
    const rewrap_pending = switch (try reader.byte()) {
        0 => false,
        1 => true,
        else => return error.InvalidValue,
    };
    const count = try reader.integer(usize);
    if (cap > max_scrollback_rows or count > max_scrollback_rows or count > cap)
        return error.LimitExceeded;
    if (pushed_abs != std.math.add(usize, evicted_abs, count) catch return error.IntegerOverflow)
        return error.InvalidValue;

    var result: Scrollback = .{ .arena_alloc = allocator, .cap = cap, .evicted_abs = evicted_abs, .pushed_abs = evicted_abs };
    errdefer result.deinit(allocator);
    for (0..count) |_| {
        const len_u64 = try reader.integer(u64);
        const len = std.math.cast(usize, len_u64) orelse return error.LimitExceeded;
        const cell_bytes = std.math.mul(usize, len, @sizeOf(Cell)) catch return error.IntegerOverflow;
        if (len > max_grid_cells or @as(u64, @intCast(cell_bytes)) > max_single_blob_bytes) return error.LimitExceeded;
        const cells = try allocator.alloc(Cell, len);
        defer allocator.free(cells);
        for (cells) |*cell| cell.* = try decodeValue(reader, Cell, allocator);
        const wrapped = switch (try reader.byte()) {
            0 => false,
            1 => true,
            else => return error.InvalidValue,
        };
        const Prompt = @TypeOf((Scrollback{}).rowPrompt(0));
        const prompt = try decodeValue(reader, Prompt, allocator);
        if (!result.pushRow(allocator, cells, wrapped, prompt)) return error.OutOfMemory;
    }
    result.rewrap_pending = rewrap_pending;
    if (result.pushed_abs != pushed_abs or result.count != count) return error.InvalidValue;
    return result;
}

fn encodeKittyStorage(writer: *Writer, storage: *const KittyImageStorage) Error!void {
    try writer.integer(usize, storage.total_bytes);
    try writer.integer(u64, storage.gen_counter);
    try writer.integer(usize, storage.limit);
    try writer.integer(usize, storage.map.count());
    var it = storage.map.iterator();
    while (it.next()) |entry| try encodeValue(writer, KittyImage, entry.value_ptr);
}

fn decodeKittyStorage(reader: *Reader, allocator: std.mem.Allocator) Error!KittyImageStorage {
    const declared_total = try reader.integer(usize);
    const gen_counter = try reader.integer(u64);
    const limit = try reader.integer(usize);
    const count = try reader.integer(usize);
    if (count > max_store_entries or declared_total > limit or declared_total > 320 * 1000 * 1000) return error.LimitExceeded;
    var result: KittyImageStorage = .{ .gen_counter = gen_counter, .limit = limit };
    errdefer result.deinit(allocator);
    var actual_total: usize = 0;
    for (0..count) |_| {
        const image = try decodeValue(reader, KittyImage, allocator);
        errdefer allocator.free(image.data);
        if (result.map.contains(image.id)) return error.DuplicateField;
        actual_total = std.math.add(usize, actual_total, image.data.len) catch return error.IntegerOverflow;
        if (actual_total > declared_total or actual_total > limit) return error.LimitExceeded;
        try result.map.put(allocator, image.id, image);
    }
    if (actual_total != declared_total) return error.InvalidValue;
    result.total_bytes = actual_total;
    return result;
}

fn encodeValue(writer: *Writer, comptime T: type, value: *const T) Error!void {
    if (T == Scrollback) return encodeScrollback(writer, value);
    if (T == KittyImageStorage) return encodeKittyStorage(writer, value);
    if (T == std.atomic.Value(u32)) return writer.integer(u32, value.load(.monotonic));
    if (T == std.atomic.Value(u64)) return writer.integer(u64, value.load(.monotonic));
    if (comptime isArrayList(T)) {
        const Child = arrayListChild(T);
        try encodeLength(writer, value.items.len, @sizeOf(Child));
        for (value.items) |*item| try encodeValue(writer, Child, item);
        return;
    }

    switch (@typeInfo(T)) {
        .void => {},
        .bool => try writer.byte(@intFromBool(value.*)),
        .int => try writer.integer(T, value.*),
        .float => {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            try writer.integer(U, @bitCast(value.*));
        },
        .@"enum" => |info| try writer.integer(info.tag_type, @intFromEnum(value.*)),
        .array => |info| {
            if (info.child == u8) {
                try writer.append(value);
            } else {
                for (value) |*item| try encodeValue(writer, info.child, item);
            }
        },
        .pointer => |info| switch (info.size) {
            .slice => {
                try encodeLength(writer, value.len, @sizeOf(info.child));
                if (info.child == u8) {
                    try writer.append(value.*);
                } else {
                    for (value.*) |*item| try encodeValue(writer, info.child, item);
                }
            },
            .one => try encodeValue(writer, info.child, value.*),
            else => @compileError("handoff v1 does not encode raw/many pointers: " ++ @typeName(T)),
        },
        .optional => |info| {
            if (value.*) |*payload| {
                try writer.byte(1);
                try encodeValue(writer, info.child, payload);
            } else try writer.byte(0);
        },
        .@"struct" => |info| {
            inline for (info.fields) |field| {
                const field_value = @field(value.*, field.name);
                try encodeValue(writer, field.type, &field_value);
            }
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse @compileError("handoff v1 requires tagged unions");
            const tag = std.meta.activeTag(value.*);
            try writer.integer(@typeInfo(Tag).@"enum".tag_type, @intFromEnum(tag));
            inline for (info.fields) |field| {
                if (tag == @field(Tag, field.name)) {
                    try encodeValue(writer, field.type, &@field(value.*, field.name));
                    return;
                }
            }
            return error.InvalidValue;
        },
        else => @compileError("handoff v1 unsupported type: " ++ @typeName(T)),
    }
}

fn checkedDecodedLength(reader: *Reader, comptime Child: type) Error!usize {
    const raw = try reader.integer(u64);
    const len = std.math.cast(usize, raw) orelse return error.LimitExceeded;
    const bytes = std.math.mul(usize, len, @sizeOf(Child)) catch return error.IntegerOverflow;
    if (@as(u64, @intCast(bytes)) > max_single_blob_bytes) return error.LimitExceeded;
    return len;
}

fn decodeValue(reader: *Reader, comptime T: type, allocator: std.mem.Allocator) Error!T {
    if (T == Scrollback) return decodeScrollback(reader, allocator);
    if (T == KittyImageStorage) return decodeKittyStorage(reader, allocator);
    if (T == std.atomic.Value(u32)) return .init(try reader.integer(u32));
    if (T == std.atomic.Value(u64)) return .init(try reader.integer(u64));
    if (comptime isArrayList(T)) {
        const Child = arrayListChild(T);
        const len = try checkedDecodedLength(reader, Child);
        var result: T = .empty;
        errdefer {
            for (result.items) |*item| deinitValue(Child, item, allocator);
            result.deinit(allocator);
        }
        try result.ensureTotalCapacity(allocator, len);
        while (result.items.len < len) {
            const item = try decodeValue(reader, Child, allocator);
            result.appendAssumeCapacity(item);
        }
        return result;
    }

    return switch (@typeInfo(T)) {
        .void => {},
        .bool => switch (try reader.byte()) {
            0 => false,
            1 => true,
            else => error.InvalidValue,
        },
        .int => try reader.integer(T),
        .float => blk: {
            const U = std.meta.Int(.unsigned, @bitSizeOf(T));
            break :blk @bitCast(try reader.integer(U));
        },
        .@"enum" => |info| std.enums.fromInt(T, try reader.integer(info.tag_type)) orelse return error.InvalidValue,
        .array => |info| blk: {
            var result: T = undefined;
            if (info.child == u8) {
                @memcpy(&result, try reader.take(info.len));
            } else {
                var initialized: usize = 0;
                errdefer for (result[0..initialized]) |*item| deinitValue(info.child, item, allocator);
                while (initialized < info.len) : (initialized += 1)
                    result[initialized] = try decodeValue(reader, info.child, allocator);
            }
            break :blk result;
        },
        .pointer => |info| switch (info.size) {
            .slice => blk: {
                const len = try checkedDecodedLength(reader, info.child);
                const result = try allocator.alloc(info.child, len);
                var initialized: usize = 0;
                errdefer {
                    for (result[0..initialized]) |*item| deinitValue(info.child, item, allocator);
                    allocator.free(result);
                }
                if (info.child == u8) {
                    @memcpy(result, try reader.take(len));
                    initialized = len;
                } else while (initialized < len) : (initialized += 1)
                    result[initialized] = try decodeValue(reader, info.child, allocator);
                break :blk result;
            },
            .one => blk: {
                const result = try allocator.create(info.child);
                errdefer allocator.destroy(result);
                result.* = try decodeValue(reader, info.child, allocator);
                break :blk result;
            },
            else => @compileError("handoff v1 does not decode raw/many pointers: " ++ @typeName(T)),
        },
        .optional => |info| switch (try reader.byte()) {
            0 => null,
            1 => try decodeValue(reader, info.child, allocator),
            else => error.InvalidValue,
        },
        .@"struct" => |info| blk: {
            var result: T = undefined;
            var initialized: usize = 0;
            errdefer if (comptime info.layout != .@"packed") {
                inline for (info.fields, 0..) |field, index| {
                    if (index < initialized) deinitValue(field.type, &@field(result, field.name), allocator);
                }
            };
            inline for (info.fields) |field| {
                @field(result, field.name) = try decodeValue(reader, field.type, allocator);
                initialized += 1;
            }
            break :blk result;
        },
        .@"union" => |info| blk: {
            const Tag = info.tag_type orelse @compileError("handoff v1 requires tagged unions");
            const tag_int = try reader.integer(@typeInfo(Tag).@"enum".tag_type);
            const tag = std.enums.fromInt(Tag, tag_int) orelse return error.InvalidValue;
            inline for (info.fields) |field| {
                if (tag == @field(Tag, field.name)) {
                    const payload = try decodeValue(reader, field.type, allocator);
                    break :blk @unionInit(T, field.name, payload);
                }
            }
            return error.InvalidValue;
        },
        else => @compileError("handoff v1 unsupported type: " ++ @typeName(T)),
    };
}

fn deinitScreen(screen: *Screen, allocator: std.mem.Allocator) void {
    if (screen.cells.len > 0) allocator.free(screen.cells);
    if (screen.wrapped.len > 0) allocator.free(screen.wrapped);
    if (screen.prompt_marks.len > 0) allocator.free(screen.prompt_marks);
    screen.sb.deinit(allocator);
    screen.* = .{};
}

fn deinitValue(comptime T: type, value: *T, allocator: std.mem.Allocator) void {
    if (T == Screen) return deinitScreen(value, allocator);
    if (T == Scrollback) {
        value.deinit(allocator);
        value.* = .{};
        return;
    }
    if (T == KittyImageStorage) {
        value.deinit(allocator);
        value.* = .{};
        return;
    }
    if (T == std.atomic.Value(u32) or T == std.atomic.Value(u64)) return;
    if (comptime isArrayList(T)) {
        const Child = arrayListChild(T);
        for (value.items) |*item| deinitValue(Child, item, allocator);
        value.deinit(allocator);
        value.* = .empty;
        return;
    }
    switch (@typeInfo(T)) {
        .pointer => |info| switch (info.size) {
            .slice => {
                for (value.*) |*item| deinitValue(info.child, item, allocator);
                if (value.len > 0) allocator.free(value.*);
            },
            .one => {
                deinitValue(info.child, value.*, allocator);
                allocator.destroy(value.*);
            },
            else => {},
        },
        .optional => |info| if (value.*) |*payload| deinitValue(info.child, payload, allocator),
        .array => |info| for (value) |*item| deinitValue(info.child, item, allocator),
        .@"struct" => |info| if (info.layout != .@"packed") {
            inline for (info.fields) |field| deinitValue(field.type, &@field(value.*, field.name), allocator);
        },
        .@"union" => |info| {
            const Tag = info.tag_type orelse return;
            const tag = std.meta.activeTag(value.*);
            inline for (info.fields) |field| if (tag == @field(Tag, field.name))
                deinitValue(field.type, &@field(value.*, field.name), allocator);
        },
        else => {},
    }
}

fn encodeCoreFields(writer: *Writer, core: *const TerminalCore) Error!void {
    inline for (core_fields_v1) |spec| {
        // optional 필드는 flag를 실어 보낸다 — **구 reader**가 모르는 tag를 만나도 `UnknownRequiredField`로
        // 죽지 않고 건너뛰게 한다(신 host → 구 host 방향의 rollback 이관).
        const start = try writer.beginTlv(spec.tag, if (spec.optional) flag_optional else 0);
        const Field = @TypeOf(@field(core.*, spec.name));
        try encodeValue(writer, Field, &@field(core.*, spec.name));
        try writer.endTlv(start);
    }
}

fn replaceCoreField(core: *TerminalCore, tag: u32, reader: *Reader, allocator: std.mem.Allocator) Error!bool {
    inline for (core_fields_v1) |spec| {
        if (tag == spec.tag) {
            const Field = @TypeOf(@field(core.*, spec.name));
            const replacement = try decodeValue(reader, Field, allocator);
            deinitValue(Field, &@field(core.*, spec.name), allocator);
            @field(core.*, spec.name) = replacement;
            return true;
        }
    }
    return false;
}

fn validateScreen(screen: *const Screen, size: maru.terminal.Size, allow_empty: bool) Error!void {
    if (allow_empty and screen.cells.len == 0) {
        if (screen.wrapped.len != 0 or screen.prompt_marks.len != 0 or screen.sb.count != 0) return error.InvalidValue;
        return;
    }
    const grid_len = std.math.mul(usize, size.cols, size.rows) catch return error.IntegerOverflow;
    if (grid_len > max_grid_cells or screen.cells.len != grid_len) return error.LimitExceeded;
    if (screen.wrapped.len != size.rows or screen.prompt_marks.len != size.rows) return error.InvalidValue;
    if (screen.cursor.row >= size.rows or screen.cursor.col >= size.cols) return error.InvalidValue;
}

fn rebuildAndValidate(core: *TerminalCore, allocator: std.mem.Allocator) Error!void {
    if (core.size.cols < 2 or core.size.rows < 1) return error.InvalidValue;
    try validateScreen(&core.screen, core.size, false);
    try validateScreen(&core.saved_screen, core.size, !core.alt_active);
    if (core.utf8_tail_len > core.utf8_tail.len or core.csi_param_count > core.csi_params.len) return error.InvalidValue;
    if (core.dcs_len > core.dcs_buffer.len or core.scroll_top > core.scroll_bottom or core.scroll_bottom >= core.size.rows)
        return error.InvalidValue;
    if (core.view_offset > core.screen.sb.count) return error.InvalidValue;
    if (core.link_store.items.len > max_store_entries or core.grapheme_store.items.len > max_store_entries)
        return error.LimitExceeded;

    var link_bytes: usize = 0;
    for (core.link_store.items, 0..) |link, index| {
        if (link.len > max_link_len or !std.unicode.utf8ValidateSlice(link)) return error.InvalidValue;
        link_bytes = std.math.add(usize, link_bytes, link.len) catch return error.IntegerOverflow;
        if (link_bytes > max_link_bytes) return error.LimitExceeded;
        const gop = try core.link_ids.getOrPut(allocator, link);
        if (gop.found_existing) return error.DuplicateField;
        gop.value_ptr.* = @intCast(index + 1);
    }

    var grapheme_bytes: usize = 0;
    for (core.grapheme_store.items, 0..) |cluster, index| {
        if (cluster.len > max_grapheme_codepoints) return error.LimitExceeded;
        const bytes = std.math.mul(usize, cluster.len, @sizeOf(u21)) catch return error.IntegerOverflow;
        grapheme_bytes = std.math.add(usize, grapheme_bytes, bytes) catch return error.IntegerOverflow;
        if (grapheme_bytes > max_grapheme_bytes) return error.LimitExceeded;
        const gop = try core.grapheme_ids.getOrPut(allocator, cluster);
        if (gop.found_existing) return error.DuplicateField;
        gop.value_ptr.* = @intCast(index + 1);
    }

    const screens = [_]*const Screen{ &core.screen, &core.saved_screen };
    for (screens) |screen| {
        for (screen.cells) |cell| {
            if (cell.link > core.link_store.items.len or cell.grapheme_id > core.grapheme_store.items.len)
                return error.InvalidReference;
        }
        for (0..screen.sb.count) |row_index| {
            const row = screen.sb.row(row_index) orelse return error.InvalidValue;
            for (row) |cell| {
                if (cell.link > core.link_store.items.len or cell.grapheme_id > core.grapheme_store.items.len)
                    return error.InvalidReference;
            }
        }
    }
    if (core.pen_link > core.link_store.items.len) return error.InvalidReference;
    for (core.kitty_placements.items) |placement| {
        if (!core.kitty_images.map.contains(placement.image_id)) return error.InvalidReference;
    }
    core.dirty = maru.terminal.core.fullDirty(core.size);
}

/// A complete v1 envelope containing one required TerminalCore section.
pub fn encodeCore(allocator: std.mem.Allocator, core: *const TerminalCore) Error![]u8 {
    if (core.response.items.len != 0) return error.InvalidValue;
    var writer: Writer = .{ .allocator = allocator };
    errdefer writer.deinit();
    try writer.append(&([_]u8{0} ** envelope_header_len));
    const section_start = try writer.beginTlv(section_terminal_core, 0);
    try encodeCoreFields(&writer, core);
    try writer.endTlv(section_start);

    const payload = writer.bytes.items[envelope_header_len..];
    if (@as(u64, @intCast(payload.len)) > max_runtime_section_bytes) return error.LimitExceeded;
    return finishEnvelope(&writer, 1);
}

pub fn decodeCore(allocator: std.mem.Allocator, bytes: []const u8) Error!TerminalCore {
    const envelope = try readEnvelope(bytes, max_runtime_section_bytes);

    var core = try TerminalCore.init(allocator, .{ .cols = 2, .rows = 1 });
    errdefer core.deinit();
    var payload_reader: Reader = .{ .bytes = envelope.payload };
    var saw_core = false;
    for (0..envelope.section_count) |_| {
        const tag = try payload_reader.integer(u32);
        const flags = try payload_reader.integer(u16);
        _ = try payload_reader.integer(u16);
        const raw_len = try payload_reader.integer(u64);
        if (raw_len > max_single_blob_bytes) return error.LimitExceeded;
        const len = std.math.cast(usize, raw_len) orelse return error.LimitExceeded;
        var section = try payload_reader.sub(len);
        if (tag == section_terminal_core) {
            if (saw_core) return error.DuplicateField;
            saw_core = true;
            var seen: [core_fields_v1.len]bool = .{false} ** core_fields_v1.len;
            while (section.pos < section.bytes.len) {
                const field_tag = try section.integer(u32);
                const field_flags = try section.integer(u16);
                _ = try section.integer(u16);
                const field_raw_len = try section.integer(u64);
                if (field_raw_len > max_single_blob_bytes) return error.LimitExceeded;
                const field_len = std.math.cast(usize, field_raw_len) orelse return error.LimitExceeded;
                var field_reader = try section.sub(field_len);
                var known = false;
                inline for (core_fields_v1, 0..) |spec, index| {
                    if (field_tag == spec.tag) {
                        if (seen[index]) return error.DuplicateField;
                        seen[index] = true;
                        known = try replaceCoreField(&core, field_tag, &field_reader, allocator);
                    }
                }
                if (!known and field_flags & flag_optional == 0) return error.UnknownRequiredField;
                if (known) try field_reader.finish();
            }
            // optional로 선언된 tag는 없어도 된다 — 그 자리는 새 core의 기본값으로 남는다. 필수 필드의 누락은
            // 그대로 거부해, "일부만 복원된 core"가 조용히 통과하는 일은 계속 막는다.
            inline for (seen, core_fields_v1) |present, spec| if (!present and !spec.optional) return error.MissingRequiredField;
        } else if (flags & flag_optional == 0) return error.UnknownRequiredField;
    }
    try payload_reader.finish();
    if (!saw_core) return error.MissingRequiredField;
    try rebuildAndValidate(&core, allocator);
    return core;
}

pub const RuntimeView = struct {
    runtime_id: u128,
    surface_id: u64,
    child_pid: i32,
    cols: u16,
    rows: u16,
    resize_generation: u64,
    fd_slot: u16,
    pty_dev: i64,
    pty_ino: u64,
    pty_rdev: i64,
    core: *const TerminalCore,
};

pub const HostView = struct {
    host_id: u128,
    upgrade_epoch: u64,
    authority_generation: u64 = 1,
    membership_generation: u64 = 1,
    next_handle: u64,
    runtimes: []const RuntimeView,
    /// Daemon attempt registry의 versioned opaque record. Outer optional section이라 frozen old reader는 안전하게
    /// 건너뛰고, current target/rollback entrypoint는 자체 codec으로 필수 검증한다.
    attempt_record: ?[]const u8 = null,
    /// Host-owned notification journal. Optional outer section keeps an N1-era writer readable by
    /// the new successor while a writer that advertises the section is validated strictly.
    notification_handoff: ?[]const u8 = null,
    notification_metadata_handoff: ?[]const u8 = null,
};

pub const RuntimeState = struct {
    runtime_id: u128,
    surface_id: u64,
    child_pid: i32,
    cols: u16,
    rows: u16,
    resize_generation: u64,
    fd_slot: u16,
    pty_dev: i64,
    pty_ino: u64,
    pty_rdev: i64,
    core: TerminalCore,

    fn deinit(self: *RuntimeState) void {
        self.core.deinit();
        self.* = undefined;
    }
};

pub const HostState = struct {
    allocator: std.mem.Allocator,
    host_id: u128,
    upgrade_epoch: u64,
    authority_generation: u64 = 1,
    membership_generation: u64 = 1,
    next_handle: u64,
    runtimes: []RuntimeState,
    attempt_record: ?[]u8,
    notification_handoff: ?[]u8 = null,
    notification_metadata_handoff: ?[]u8 = null,

    pub fn deinit(self: *HostState) void {
        for (self.runtimes) |*runtime| runtime.deinit();
        self.allocator.free(self.runtimes);
        if (self.attempt_record) |record| self.allocator.free(record);
        if (self.notification_handoff) |record| self.allocator.free(record);
        if (self.notification_metadata_handoff) |record| self.allocator.free(record);
        self.* = undefined;
    }
};

fn encodeTaggedValue(writer: *Writer, tag: u32, comptime T: type, value: *const T) Error!void {
    const start = try writer.beginTlv(tag, 0);
    try encodeValue(writer, T, value);
    try writer.endTlv(start);
}

fn encodeOptionalTaggedValue(writer: *Writer, tag: u32, comptime T: type, value: *const T) Error!void {
    const start = try writer.beginTlv(tag, flag_optional);
    try encodeValue(writer, T, value);
    try writer.endTlv(start);
}

fn encodeTaggedBytes(writer: *Writer, tag: u32, bytes: []const u8) Error!void {
    const start = try writer.beginTlv(tag, 0);
    try writer.append(bytes);
    try writer.endTlv(start);
}

pub fn encodedAttemptSectionBytes(record_len: usize) Error!usize {
    if (record_len == 0 or record_len > max_attempt_record_bytes) return error.LimitExceeded;
    return std.math.add(usize, tlv_header_len, record_len) catch return error.IntegerOverflow;
}

/// Host 전체 logical DTO. Runtime section은 반복 가능하지만 각 runtime 내부 field tag는 exactly-once다.
pub fn encodeHost(allocator: std.mem.Allocator, host: HostView) Error![]u8 {
    return encodeHostWithMaxBytes(allocator, host, max_total_bytes);
}

pub fn encodeHostWithMaxBytes(
    allocator: std.mem.Allocator,
    host: HostView,
    max_bytes: usize,
) Error![]u8 {
    if (max_bytes == 0 or @as(u64, @intCast(max_bytes)) > max_total_bytes)
        return error.LimitExceeded;
    if (host.host_id == 0 or host.authority_generation == 0 or host.membership_generation == 0)
        return error.InvalidValue;
    if (host.runtimes.len > max_runtime_count or
        host.next_handle == 0 or
        host.next_handle == std.math.maxInt(u64))
        return error.LimitExceeded;
    // Count cap must precede element inspection: callers may provide capacity-only/uninitialized storage
    // when asserting cap+1, and rejected elements are outside the codec's readable domain.
    for (host.runtimes) |runtime| if (runtime.runtime_id == 0) return error.InvalidValue;
    for (host.runtimes) |runtime| {
        // RuntimeManager reserves handle 0 as the opaque-pointer null value,
        // and its next cursor must be strictly above every restored handle.
        // Rejecting this in the codec keeps a valid handoff from restoring
        // successfully only to collide on the first later runtime.spawn.
        if (runtime.surface_id == 0 or runtime.surface_id >= host.next_handle)
            return error.InvalidValue;
    }
    var writer: Writer = .{ .allocator = allocator, .max_bytes = @intCast(max_bytes) };
    errdefer writer.deinit();
    try writer.append(&([_]u8{0} ** envelope_header_len));

    const host_start = try writer.beginTlv(section_host_meta, 0);
    try encodeTaggedValue(&writer, 1, u128, &host.host_id);
    try encodeTaggedValue(&writer, 2, u64, &host.upgrade_epoch);
    try encodeTaggedValue(&writer, 3, u64, &host.next_handle);
    const runtime_count: u16 = @intCast(host.runtimes.len);
    try encodeTaggedValue(&writer, 4, u16, &runtime_count);
    try encodeOptionalTaggedValue(&writer, 5, u64, &host.membership_generation);
    try encodeOptionalTaggedValue(&writer, 6, u64, &host.authority_generation);
    try writer.endTlv(host_start);

    if (host.attempt_record) |record| {
        _ = try encodedAttemptSectionBytes(record.len);
        const attempt_start = try writer.beginTlv(section_attempt_record, flag_optional);
        try writer.append(record);
        try writer.endTlv(attempt_start);
    }

    if (host.notification_handoff) |record| {
        if (record.len == 0 or record.len > max_notification_handoff_bytes) return error.LimitExceeded;
        const notification_start = try writer.beginTlv(section_notification_journal, flag_optional);
        try writer.append(record);
        try writer.endTlv(notification_start);
    }
    if (host.notification_metadata_handoff) |record| {
        if (record.len == 0 or record.len > max_notification_metadata_handoff_bytes) return error.LimitExceeded;
        const metadata_start = try writer.beginTlv(section_notification_metadata, flag_optional);
        try writer.append(record);
        try writer.endTlv(metadata_start);
    }

    for (host.runtimes) |runtime| {
        if (runtime.child_pid <= 0 or runtime.cols < 2 or runtime.rows < 1 or
            runtime.fd_slot < 3 or runtime.core.response.items.len != 0) return error.InvalidValue;
        const runtime_start = try writer.beginTlv(section_runtime, 0);
        try encodeTaggedValue(&writer, 1, u128, &runtime.runtime_id);
        try encodeTaggedValue(&writer, 2, u64, &runtime.surface_id);
        try encodeTaggedValue(&writer, 3, i32, &runtime.child_pid);
        try encodeTaggedValue(&writer, 4, u16, &runtime.cols);
        try encodeTaggedValue(&writer, 5, u16, &runtime.rows);
        try encodeTaggedValue(&writer, 6, u64, &runtime.resize_generation);
        try encodeTaggedValue(&writer, 7, u16, &runtime.fd_slot);
        const core_bytes = try encodeCore(allocator, runtime.core);
        defer allocator.free(core_bytes);
        try encodeTaggedBytes(&writer, 8, core_bytes);
        try encodeTaggedValue(&writer, 9, i64, &runtime.pty_dev);
        try encodeTaggedValue(&writer, 10, u64, &runtime.pty_ino);
        try encodeTaggedValue(&writer, 11, i64, &runtime.pty_rdev);
        try writer.endTlv(runtime_start);
        if (writer.bytes.items.len - runtime_start > max_runtime_section_bytes) return error.LimitExceeded;
    }
    return finishEnvelope(&writer, @intCast(host.runtimes.len + 1 +
        @intFromBool(host.attempt_record != null) + @intFromBool(host.notification_handoff != null) +
        @intFromBool(host.notification_metadata_handoff != null)));
}

test "budget preview encoder stops at the operational allocation cap" {
    const host: HostView = .{
        .host_id = 1,
        .upgrade_epoch = 2,
        .next_handle = 3,
        .runtimes = &.{},
    };
    const encoded = try encodeHost(std.testing.allocator, host);
    defer std.testing.allocator.free(encoded);
    try std.testing.expectError(
        error.LimitExceeded,
        encodeHostWithMaxBytes(std.testing.allocator, host, encoded.len - 1),
    );
    const exact = try encodeHostWithMaxBytes(std.testing.allocator, host, encoded.len);
    defer std.testing.allocator.free(exact);
    try std.testing.expectEqualSlices(u8, encoded, exact);
}

fn readTagged(comptime T: type, field: *Reader, allocator: std.mem.Allocator) Error!T {
    const result = try decodeValue(field, T, allocator);
    try field.finish();
    return result;
}

fn decodeHostMeta(section: *Reader, host_id: *u128, epoch: *u64, authority_generation: *u64, membership_generation: *u64, next_handle: *u64, runtime_count: *u16) Error!void {
    var seen: [6]bool = .{false} ** 6;
    while (section.pos < section.bytes.len) {
        const tag = try section.integer(u32);
        const flags = try section.integer(u16);
        _ = try section.integer(u16);
        const raw_len = try section.integer(u64);
        if (raw_len > max_single_blob_bytes) return error.LimitExceeded;
        var field = try section.sub(std.math.cast(usize, raw_len) orelse return error.LimitExceeded);
        if (tag < 1 or tag > 6) {
            if (flags & flag_optional == 0) return error.UnknownRequiredField;
            continue;
        }
        const index: usize = @intCast(tag - 1);
        if (seen[index]) return error.DuplicateField;
        seen[index] = true;
        switch (tag) {
            1 => host_id.* = try readTagged(u128, &field, std.heap.page_allocator),
            2 => epoch.* = try readTagged(u64, &field, std.heap.page_allocator),
            3 => next_handle.* = try readTagged(u64, &field, std.heap.page_allocator),
            4 => runtime_count.* = try readTagged(u16, &field, std.heap.page_allocator),
            5 => membership_generation.* = try readTagged(u64, &field, std.heap.page_allocator),
            6 => authority_generation.* = try readTagged(u64, &field, std.heap.page_allocator),
            else => unreachable,
        }
    }
    for (seen[0..4]) |present| if (!present) return error.MissingRequiredField;
}

fn decodeRuntime(allocator: std.mem.Allocator, section: *Reader) Error!RuntimeState {
    var result: RuntimeState = undefined;
    var seen: [11]bool = .{false} ** 11;
    var core_initialized = false;
    errdefer if (core_initialized) result.core.deinit();
    while (section.pos < section.bytes.len) {
        const tag = try section.integer(u32);
        const flags = try section.integer(u16);
        _ = try section.integer(u16);
        const raw_len = try section.integer(u64);
        if (raw_len > max_single_blob_bytes) return error.LimitExceeded;
        var field = try section.sub(std.math.cast(usize, raw_len) orelse return error.LimitExceeded);
        if (tag < 1 or tag > 11) {
            if (flags & flag_optional == 0) return error.UnknownRequiredField;
            continue;
        }
        const index: usize = @intCast(tag - 1);
        if (seen[index]) return error.DuplicateField;
        seen[index] = true;
        switch (tag) {
            1 => result.runtime_id = try readTagged(u128, &field, allocator),
            2 => result.surface_id = try readTagged(u64, &field, allocator),
            3 => result.child_pid = try readTagged(i32, &field, allocator),
            4 => result.cols = try readTagged(u16, &field, allocator),
            5 => result.rows = try readTagged(u16, &field, allocator),
            6 => result.resize_generation = try readTagged(u64, &field, allocator),
            7 => result.fd_slot = try readTagged(u16, &field, allocator),
            8 => {
                result.core = try decodeCore(allocator, field.bytes);
                core_initialized = true;
                field.pos = field.bytes.len;
            },
            9 => result.pty_dev = try readTagged(i64, &field, allocator),
            10 => result.pty_ino = try readTagged(u64, &field, allocator),
            11 => result.pty_rdev = try readTagged(i64, &field, allocator),
            else => unreachable,
        }
    }
    for (seen) |present| if (!present) return error.MissingRequiredField;
    if (result.child_pid <= 0 or result.cols < 2 or result.rows < 1 or result.fd_slot < 3 or
        result.core.size.cols != result.cols or result.core.size.rows != result.rows) return error.InvalidValue;
    return result;
}

/// 모든 runtime candidate를 먼저 완성·교차검증한 뒤 HostState를 반환한다. 한 runtime 손상도 부분 publish하지 않는다.
pub fn decodeHost(allocator: std.mem.Allocator, bytes: []const u8) Error!HostState {
    const envelope = try readEnvelope(bytes, max_total_bytes - envelope_header_len);
    if (envelope.section_count == 0 or envelope.section_count > max_section_count) return error.LimitExceeded;
    var runtimes = std.ArrayList(RuntimeState).empty;
    errdefer {
        for (runtimes.items) |*runtime| runtime.deinit();
        runtimes.deinit(allocator);
    }
    var host_id: u128 = 0;
    var epoch: u64 = 0;
    var authority_generation: u64 = 1;
    var membership_generation: u64 = 1;
    var next_handle: u64 = 0;
    var declared_count: u16 = 0;
    var saw_meta = false;
    var attempt_record: ?[]u8 = null;
    errdefer if (attempt_record) |record| allocator.free(record);
    var notification_handoff: ?[]u8 = null;
    errdefer if (notification_handoff) |record| allocator.free(record);
    var notification_metadata_handoff: ?[]u8 = null;
    errdefer if (notification_metadata_handoff) |record| allocator.free(record);
    var payload = Reader{ .bytes = envelope.payload };
    for (0..envelope.section_count) |_| {
        const tag = try payload.integer(u32);
        const flags = try payload.integer(u16);
        _ = try payload.integer(u16);
        const raw_len = try payload.integer(u64);
        if (raw_len > max_runtime_section_bytes) return error.LimitExceeded;
        var section = try payload.sub(std.math.cast(usize, raw_len) orelse return error.LimitExceeded);
        switch (tag) {
            section_host_meta => {
                if (saw_meta) return error.DuplicateField;
                saw_meta = true;
                try decodeHostMeta(&section, &host_id, &epoch, &authority_generation, &membership_generation, &next_handle, &declared_count);
            },
            section_runtime => {
                if (runtimes.items.len == max_runtime_count) return error.LimitExceeded;
                var runtime = try decodeRuntime(allocator, &section);
                runtimes.append(allocator, runtime) catch |err| {
                    runtime.deinit();
                    return err;
                };
            },
            section_attempt_record => {
                if (flags & flag_optional == 0 or attempt_record != null or section.bytes.len == 0 or
                    section.bytes.len > max_attempt_record_bytes) return error.InvalidValue;
                attempt_record = allocator.dupe(u8, section.bytes) catch return error.OutOfMemory;
                section.pos = section.bytes.len;
            },
            section_notification_journal => {
                if (flags & flag_optional == 0 or notification_handoff != null or section.bytes.len == 0 or
                    section.bytes.len > max_notification_handoff_bytes) return error.InvalidValue;
                notification_handoff = allocator.dupe(u8, section.bytes) catch return error.OutOfMemory;
                section.pos = section.bytes.len;
            },
            section_notification_metadata => {
                if (flags & flag_optional == 0 or notification_metadata_handoff != null or section.bytes.len == 0 or
                    section.bytes.len > max_notification_metadata_handoff_bytes) return error.InvalidValue;
                notification_metadata_handoff = allocator.dupe(u8, section.bytes) catch return error.OutOfMemory;
                section.pos = section.bytes.len;
            },
            else => if (flags & flag_optional == 0) return error.UnknownRequiredField,
        }
    }
    try payload.finish();
    if (!saw_meta or host_id == 0 or declared_count != runtimes.items.len or next_handle == 0 or
        authority_generation == 0 or membership_generation == 0)
        return error.MissingRequiredField;
    if (next_handle == std.math.maxInt(u64)) return error.LimitExceeded;
    for (runtimes.items, 0..) |runtime, index| {
        if (runtime.runtime_id == 0) return error.InvalidValue;
        if (runtime.surface_id == 0 or runtime.surface_id >= next_handle)
            return error.InvalidValue;
        for (runtimes.items[0..index]) |prior| {
            if (prior.runtime_id == runtime.runtime_id or prior.surface_id == runtime.surface_id or prior.fd_slot == runtime.fd_slot)
                return error.DuplicateField;
        }
    }
    return .{
        .allocator = allocator,
        .host_id = host_id,
        .upgrade_epoch = epoch,
        .authority_generation = authority_generation,
        .membership_generation = membership_generation,
        .next_handle = next_handle,
        .runtimes = try runtimes.toOwnedSlice(allocator),
        .attempt_record = attempt_record,
        .notification_handoff = notification_handoff,
        .notification_metadata_handoff = notification_metadata_handoff,
    };
}

fn expectCoreContinuation(prefix: []const u8, suffix: []const u8) !void {
    const allocator = std.testing.allocator;
    var uninterrupted = try TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer uninterrupted.deinit();
    try uninterrupted.write(prefix);

    const bytes = try encodeCore(allocator, &uninterrupted);
    defer allocator.free(bytes);
    var restored = try decodeCore(allocator, bytes);
    defer restored.deinit();

    try uninterrupted.write(suffix);
    try restored.write(suffix);
    const expected = try uninterrupted.dumpUtf8(allocator);
    defer allocator.free(expected);
    const actual = try restored.dumpUtf8(allocator);
    defer allocator.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectEqual(uninterrupted.parser, restored.parser);
    try std.testing.expectEqual(uninterrupted.screen.cursor, restored.screen.cursor);
}

test "handoff v1 round-trips partial UTF-8 and escape parser continuations" {
    try expectCoreContinuation(&.{ 0xED, 0x95 }, &.{0x9C}); // 한 UTF-8 split
    try expectCoreContinuation("\x1b[31", "mred");
    try expectCoreContinuation("\x1b]2;partial", "\x07");
    try expectCoreContinuation("\x1bP$q", "m\x1b\\");
    try expectCoreContinuation("\x1b_Ga=t,f=32,s=1,v=1,i=7;AAAA", "\x1b\\");
}

test "handoff v1 rejects checksum damage before candidate publication" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("hello");
    const bytes = try encodeCore(allocator, &core);
    defer allocator.free(bytes);
    bytes[bytes.len - 1] ^= 0xff;
    try std.testing.expectError(error.ChecksumMismatch, decodeCore(allocator, bytes));
}

fn refreshEnvelope(bytes: []u8, section_count: u16) void {
    const payload = bytes[envelope_header_len..];
    std.mem.writeInt(u16, bytes[14..16], section_count, .big);
    std.mem.writeInt(u64, bytes[16..24], @intCast(payload.len), .big);
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(payload, &digest, .{});
    @memcpy(bytes[24..56], &digest);
}

fn appendEmptySection(allocator: std.mem.Allocator, original: []const u8, tag: u32, flags: u16) ![]u8 {
    const result = try allocator.alloc(u8, original.len + tlv_header_len);
    @memcpy(result[0..original.len], original);
    @memset(result[original.len..], 0);
    var tag_bytes: [4]u8 = undefined;
    var flag_bytes: [2]u8 = undefined;
    std.mem.writeInt(u32, &tag_bytes, tag, .big);
    std.mem.writeInt(u16, &flag_bytes, flags, .big);
    @memcpy(result[original.len .. original.len + 4], &tag_bytes);
    @memcpy(result[original.len + 4 .. original.len + 6], &flag_bytes);
    refreshEnvelope(result, 2);
    return result;
}

/// core 섹션에서 필드 TLV 하나를 통째로 들어내 **그 tag를 모르던 구 writer의 레코드**를 흉내 낸다. 섹션 길이와
/// envelope(체크섬·payload 길이)을 함께 갱신하므로 decode가 정상 레코드로 읽는다. 첫 섹션이 core라는 전제는
/// encodeCore가 그렇게 쓰기 때문이고, 아니면 테스트가 즉시 실패해 전제를 알린다.
fn stripCoreField(allocator: std.mem.Allocator, original: []const u8, field_tag: u32) ![]u8 {
    const section_start = envelope_header_len;
    const section_tag = std.mem.readInt(u32, original[section_start..][0..4], .big);
    try std.testing.expectEqual(section_terminal_core, section_tag);
    const section_len = std.mem.readInt(u64, original[section_start + 8 ..][0..8], .big);
    const body_start = section_start + tlv_header_len;
    const body_end = body_start + @as(usize, @intCast(section_len));

    // 필드 TLV들을 훑어 대상 tag의 [시작, 끝)을 찾는다.
    var cut_start: ?usize = null;
    var cut_end: usize = 0;
    var pos: usize = body_start;
    while (pos < body_end) {
        const tag = std.mem.readInt(u32, original[pos..][0..4], .big);
        const len: usize = @intCast(std.mem.readInt(u64, original[pos + 8 ..][0..8], .big));
        const next = pos + tlv_header_len + len;
        if (tag == field_tag) {
            cut_start = pos;
            cut_end = next;
            break;
        }
        pos = next;
    }
    const start = cut_start orelse return error.FieldTagNotFound;
    const removed = cut_end - start;

    const result = try allocator.alloc(u8, original.len - removed);
    @memcpy(result[0..start], original[0..start]);
    @memcpy(result[start..], original[cut_end..]);
    std.mem.writeInt(u64, result[section_start + 8 ..][0..8], section_len - removed, .big);
    refreshEnvelope(result, 1);
    return result;
}

// **구 host가 만든 레코드를 새 host가 읽을 수 있어야 한다.** v1에 뒤늦게 추가한 tag를 필수로 두면 N-1 레코드에
// 그 tag가 없어 decode가 `MissingRequiredField`로 떨어지고, 실행 중 업그레이드가 통째로 막힌다(적대적 검증에서
// 발견 — 처음 구현은 실제로 필수였다). optional 계약이 살아 있는지 여기서 고정한다.
test "handoff v1 accepts an older writer record that lacks the optional cwd_host tag" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("\x1b]7;file://build-box/srv\x07");
    try std.testing.expectEqualStrings("build-box", core.currentCwdHost()); // writer 쪽엔 값이 있다

    const encoded = try encodeCore(allocator, &core);
    defer allocator.free(encoded);
    const old_record = try stripCoreField(allocator, encoded, 90);
    defer allocator.free(old_record);

    var restored = try decodeCore(allocator, old_record);
    defer restored.deinit();
    // 나머지 필드는 그대로 복원되고, 없는 optional 필드만 기본값(=authority 미보고 → 로컬 취급)으로 남는다.
    try std.testing.expectEqualStrings("/srv", restored.currentCwd());
    try std.testing.expectEqualStrings("", restored.currentCwdHost());
}

test "handoff v1 skips unknown optional sections and rejects unknown required sections" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    const encoded = try encodeCore(allocator, &core);
    defer allocator.free(encoded);

    const optional = try appendEmptySection(allocator, encoded, 99, flag_optional);
    defer allocator.free(optional);
    var decoded = try decodeCore(allocator, optional);
    decoded.deinit();

    const required = try appendEmptySection(allocator, encoded, 99, 0);
    defer allocator.free(required);
    try std.testing.expectError(error.UnknownRequiredField, decodeCore(allocator, required));
}

test "handoff v1 rejects duplicate required sections and declared caps before allocation" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    const encoded = try encodeCore(allocator, &core);
    defer allocator.free(encoded);

    const payload = encoded[envelope_header_len..];
    const duplicate = try allocator.alloc(u8, envelope_header_len + payload.len * 2);
    defer allocator.free(duplicate);
    @memcpy(duplicate[0..encoded.len], encoded);
    @memcpy(duplicate[encoded.len..], payload);
    refreshEnvelope(duplicate, 2);
    try std.testing.expectError(error.DuplicateField, decodeCore(allocator, duplicate));

    const oversized = try allocator.dupe(u8, encoded);
    defer allocator.free(oversized);
    std.mem.writeInt(u64, oversized[16..24], max_runtime_section_bytes + 1, .big);
    try std.testing.expectError(error.LimitExceeded, decodeCore(allocator, oversized));
}

test "handoff v1 rejects every truncated prefix, trailing bytes, cap plus one, and checked overflow" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("boundary");
    const encoded = try encodeCore(allocator, &core);
    defer allocator.free(encoded);

    for (0..encoded.len) |prefix_len|
        try std.testing.expectError(error.Truncated, decodeCore(allocator, encoded[0..prefix_len]));

    const trailing = try allocator.alloc(u8, encoded.len + 1);
    defer allocator.free(trailing);
    @memcpy(trailing[0..encoded.len], encoded);
    trailing[encoded.len] = 0;
    try std.testing.expectError(error.TrailingBytes, decodeCore(allocator, trailing));

    const payload_cap = try allocator.dupe(u8, encoded);
    defer allocator.free(payload_cap);
    std.mem.writeInt(u64, payload_cap[16..24], max_runtime_section_bytes, .big);
    try std.testing.expectError(error.Truncated, decodeCore(allocator, payload_cap));
    std.mem.writeInt(u64, payload_cap[16..24], max_runtime_section_bytes + 1, .big);
    try std.testing.expectError(error.LimitExceeded, decodeCore(allocator, payload_cap));

    const field_cap = try allocator.dupe(u8, encoded);
    defer allocator.free(field_cap);
    std.mem.writeInt(u64, field_cap[envelope_header_len + 8 .. envelope_header_len + 16], max_single_blob_bytes, .big);
    refreshEnvelope(field_cap, 1);
    try std.testing.expectError(error.Truncated, decodeCore(allocator, field_cap));
    std.mem.writeInt(u64, field_cap[envelope_header_len + 8 .. envelope_header_len + 16], max_single_blob_bytes + 1, .big);
    refreshEnvelope(field_cap, 1);
    try std.testing.expectError(error.LimitExceeded, decodeCore(allocator, field_cap));

    var reader: Reader = .{ .bytes = "" };
    reader.pos = std.math.maxInt(usize);
    try std.testing.expectError(error.IntegerOverflow, reader.take(1));
    var writer: Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try std.testing.expectError(error.IntegerOverflow, encodeLength(&writer, std.math.maxInt(usize), 2));
}

test "handoff v1 rejects scrollback configured cap plus one before allocation" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    core.screen.sb.cap = max_scrollback_rows + 1;
    try std.testing.expectError(error.LimitExceeded, encodeCore(allocator, &core));

    var writer: Writer = .{ .allocator = allocator };
    defer writer.deinit();
    try writer.integer(usize, max_scrollback_rows + 1);
    try writer.integer(usize, 0);
    try writer.integer(usize, 0);
    try writer.byte(0);
    try writer.integer(usize, 0);
    var reader: Reader = .{ .bytes = writer.bytes.items };
    try std.testing.expectError(error.LimitExceeded, decodeScrollback(&reader, allocator));
}

test "handoff v1 host envelope enforces exact declared section and runtime count boundaries" {
    const allocator = std.testing.allocator;
    const encoded = try encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 0,
        .next_handle = 1,
        .runtimes = &.{},
    });
    defer allocator.free(encoded);

    const declared = try allocator.dupe(u8, encoded);
    defer allocator.free(declared);
    std.mem.writeInt(u16, declared[14..16], max_runtime_count + 1, .big);
    try std.testing.expectError(error.Truncated, decodeHost(allocator, declared));
    std.mem.writeInt(u16, declared[14..16], max_section_count, .big);
    try std.testing.expectError(error.Truncated, decodeHost(allocator, declared));
    std.mem.writeInt(u16, declared[14..16], max_section_count + 1, .big);
    try std.testing.expectError(error.LimitExceeded, decodeHost(allocator, declared));

    var too_many: [max_runtime_count + 1]RuntimeView = undefined;
    try std.testing.expectError(error.LimitExceeded, encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 0,
        .next_handle = 1,
        .runtimes = &too_many,
    }));

    var core = try TerminalCore.init(allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();
    var maximum: [max_runtime_count]RuntimeView = undefined;
    for (&maximum, 0..) |*runtime, index| runtime.* = .{
        .runtime_id = index + 1,
        .surface_id = index + 1,
        .child_pid = 1,
        .cols = 2,
        .rows = 1,
        .resize_generation = 0,
        .fd_slot = @intCast(index + 40),
        .pty_dev = 1,
        .pty_ino = @intCast(index + 1),
        .pty_rdev = 2,
        .core = &core,
    };
    const maximum_encoded = try encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 0,
        .next_handle = max_runtime_count + 1,
        .runtimes = &maximum,
        .attempt_record = "opaque-attempt",
    });
    defer allocator.free(maximum_encoded);
    var maximum_decoded = try decodeHost(allocator, maximum_encoded);
    defer maximum_decoded.deinit();
    try std.testing.expectEqual(max_runtime_count, maximum_decoded.runtimes.len);
    try std.testing.expectEqualStrings("opaque-attempt", maximum_decoded.attempt_record.?);
}

test "handoff v1 allocation failure never publishes a partial candidate" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("owned candidate");
    const encoded = try encodeCore(allocator, &core);
    defer allocator.free(encoded);

    var saw_success = false;
    for (0..512) |fail_index| {
        var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = fail_index });
        var decoded = decodeCore(failing.allocator(), encoded) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            continue;
        };
        decoded.deinit();
        saw_success = true;
        break;
    }
    try std.testing.expect(saw_success);
}

test "handoff v1 validates cell store references after complete decode" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    core.screen.cells[0].link = 1;
    const encoded = try encodeCore(allocator, &core);
    defer allocator.free(encoded);
    try std.testing.expectError(error.InvalidReference, decodeCore(allocator, encoded));
}

test "handoff v1 host DTO atomically round-trips multiple runtime identities and cores" {
    const allocator = std.testing.allocator;
    var first = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer first.deinit();
    try first.write("one");
    var second = try TerminalCore.init(allocator, .{ .cols = 10, .rows = 3 });
    defer second.deinit();
    try second.write("\x1b[31");
    const views = [_]RuntimeView{
        .{ .runtime_id = 0xAA, .surface_id = 7, .child_pid = 101, .cols = 8, .rows = 2, .resize_generation = 3, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &first },
        .{ .runtime_id = 0xBB, .surface_id = 8, .child_pid = 102, .cols = 10, .rows = 3, .resize_generation = 4, .fd_slot = 41, .pty_dev = 4, .pty_ino = 5, .pty_rdev = 6, .core = &second },
    };
    const encoded = try encodeHost(allocator, .{
        .host_id = 0xCAFE,
        .upgrade_epoch = 9,
        .authority_generation = 31,
        .membership_generation = 77,
        .next_handle = 12,
        .runtimes = &views,
        .attempt_record = "attempt-v1",
    });
    defer allocator.free(encoded);
    var decoded = try decodeHost(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqual(@as(u128, 0xCAFE), decoded.host_id);
    try std.testing.expectEqual(@as(u64, 9), decoded.upgrade_epoch);
    try std.testing.expectEqual(@as(u64, 31), decoded.authority_generation);
    try std.testing.expectEqual(@as(u64, 77), decoded.membership_generation);
    try std.testing.expectEqual(@as(u64, 12), decoded.next_handle);
    try std.testing.expectEqual(@as(usize, 2), decoded.runtimes.len);
    try std.testing.expectEqual(@as(u128, 0xAA), decoded.runtimes[0].runtime_id);
    try std.testing.expectEqual(@as(u16, 41), decoded.runtimes[1].fd_slot);
    try std.testing.expectEqual(second.parser, decoded.runtimes[1].core.parser);
    try std.testing.expectEqualStrings("attempt-v1", decoded.attempt_record.?);
}

test "handoff v1 host DTO rejects duplicate inherited slots without publishing any runtime" {
    const allocator = std.testing.allocator;
    var first = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer first.deinit();
    var second = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer second.deinit();
    const views = [_]RuntimeView{
        .{ .runtime_id = 1, .surface_id = 1, .child_pid = 101, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &first },
        .{ .runtime_id = 2, .surface_id = 2, .child_pid = 102, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &second },
    };
    const encoded = try encodeHost(allocator, .{ .host_id = 1, .upgrade_epoch = 0, .next_handle = 3, .runtimes = &views });
    defer allocator.free(encoded);
    try std.testing.expectError(error.DuplicateField, decodeHost(allocator, encoded));
}

test "handoff v1 host DTO reserves zero host and runtime identities" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    const runtime = [_]RuntimeView{.{
        .runtime_id = 0,
        .surface_id = 1,
        .child_pid = 101,
        .cols = 8,
        .rows = 2,
        .resize_generation = 0,
        .fd_slot = 40,
        .pty_dev = 1,
        .pty_ino = 2,
        .pty_rdev = 3,
        .core = &core,
    }};
    try std.testing.expectError(error.InvalidValue, encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 0,
        .next_handle = 2,
        .runtimes = &runtime,
    }));
    try std.testing.expectError(error.InvalidValue, encodeHost(allocator, .{
        .host_id = 0,
        .upgrade_epoch = 0,
        .next_handle = 2,
        .runtimes = &.{},
    }));
}

test "handoff v1 host DTO rejects zero and non-advancing restored handles" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    const base = RuntimeView{
        .runtime_id = 1,
        .surface_id = 0,
        .child_pid = 101,
        .cols = 8,
        .rows = 2,
        .resize_generation = 0,
        .fd_slot = 40,
        .pty_dev = 1,
        .pty_ino = 2,
        .pty_rdev = 3,
        .core = &core,
    };
    try std.testing.expectError(error.InvalidValue, encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 0,
        .next_handle = 1,
        .runtimes = &.{base},
    }));
    var colliding = base;
    colliding.surface_id = 7;
    try std.testing.expectError(error.InvalidValue, encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 0,
        .next_handle = 7,
        .runtimes = &.{colliding},
    }));
    try std.testing.expectError(error.LimitExceeded, encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 0,
        .next_handle = std.math.maxInt(u64),
        .runtimes = &.{},
    }));
}

test "handoff v1 host DTO allocation failure never publishes a partial runtime set" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("atomic");
    const views = [_]RuntimeView{
        .{ .runtime_id = 1, .surface_id = 1, .child_pid = 101, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &core },
    };
    const encoded = try encodeHost(allocator, .{ .host_id = 1, .upgrade_epoch = 0, .next_handle = 2, .runtimes = &views });
    defer allocator.free(encoded);

    var saw_success = false;
    for (0..1024) |fail_index| {
        var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
        var failing = std.testing.FailingAllocator.init(debug_allocator.allocator(), .{ .fail_index = fail_index });
        var decoded = decodeHost(failing.allocator(), encoded) catch |err| {
            try std.testing.expectEqual(error.OutOfMemory, err);
            if (debug_allocator.deinit() == .leak) {
                std.debug.print("handoff host decode leaked at fail_index={d}\n", .{fail_index});
                return error.TestUnexpectedResult;
            }
            continue;
        };
        decoded.deinit();
        try std.testing.expectEqual(std.heap.Check.ok, debug_allocator.deinit());
        saw_success = true;
        break;
    }
    try std.testing.expect(saw_success);
}
