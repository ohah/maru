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

/// GUI 가 소유하는 **불투명** 레이아웃 조각의 런타임당 상한.
///
/// host 는 이 바이트를 **해석하지 않는다.** 저장하고 handoff 로 나르기만 한다 — 그래야 「런타임 사실은
/// host, 표현은 GUI」라는 소유권이 안 깨진다. 한 host 에 여러 GUI 창이 붙을 수 있으므로 host 가 레이아웃을
/// 해석하기 시작하면 작성자가 둘이 되고 충돌 해소 문제가 새로 생긴다.
///
/// **왜 필요한가**: 2026-09-11 실측 — 복원이 불완전한 채 종료하면서 `workspace.v1` 이 343 B 로 덮였고,
/// 탭 이름·분할·순서가 전부 사라졌다. 세션 23 개는 host 에 멀쩡히 살아 있었지만 **어느 탭이었는지는
/// 어디에도 없어서** 복구가 「새 탭 23 개」로 끝났다. 워크스페이스 파일이 그 정보의 **단일 실패점**이다.
///
/// 4 KiB 는 탭 이름 + pane 경로 + 창 식별자에 넉넉하고, 23 개 런타임이면 92 KiB —
/// `max_handoff_commit_bytes`(64 MiB)의 0.14 % 다. 오늘 `state_too_large` 로 업그레이드가 막힌 적이
/// 있으므로 상한은 반드시 둔다.
const max_layout_blob_bytes: usize = 4 * 1024;
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
    .{ .tag = 99, .name = "saved_kitty_flags", .optional = true },
    // OSC 99 조립 조각. **새 tag 는 끝에서 이어 붙인다** — 가운데에 끼우면 이미 나간 handoff 의
    // 같은 번호가 다른 뜻이 돼 업그레이드가 남의 필드를 읽는다.
    //
    // **95~99 는 전부 `optional` 이다.** 2026-09-10 에 99(`saved_kitty_flags`)를 필수로 넣었다가, 그
    // tag 를 모르는 구 host 가 쓴 레코드가 `MissingRequiredField` 로 거부돼 **업그레이드가 통째로
    // 막혔다** — 새 빌드를 깔 때마다 host 가 하나씩 늘고 세션이 옛 host 에 갇혔다. `FieldSpec.optional`
    // 의 주석이 그 결과를 미리 적어 두었는데도 그랬다. 같은 날 들어온 95~98 도 같은 잠복 상태였다.
    .{ .tag = 95, .name = "osc99_title", .optional = true },
    .{ .tag = 96, .name = "osc99_body", .optional = true },
    .{ .tag = 97, .name = "osc99_id", .optional = true },
    .{ .tag = 98, .name = "osc99_active", .optional = true },
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
    // U=1 virtual placement(unicode placeholder). **optional** — 구 host 는 이 tag 를 모르므로
    // 건너뛰게 한다(신→구 rollback 이관에서 UnknownRequiredField 로 죽지 않게).
    .{ .tag = 92, .name = "kitty_virtual_placements", .optional = true },
    // `I=`(image number) 배정표와 다음 auto id. **optional** — 구 host 는 이 tag 를 모른다.
    .{ .tag = 93, .name = "kitty_image_numbers", .optional = true },
    .{ .tag = 94, .name = "kitty_next_auto_id", .optional = true },
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

/// v1 표가 처음 나갈 때(2026-07-25~27) 쓰인 마지막 tag. **이보다 큰 번호는 전부 「뒤늦게 추가」다.**
const v1_initial_last_tag: u32 = 89;

// **뒤늦게 추가된 tag 는 반드시 `optional` 이어야 한다 — 컴파일이 막는다.**
//
// 필수로 두면 그 tag 를 모르는 N-1 host 가 쓴 레코드가 `MissingRequiredField` 로 거부되고,
// `mapDecodeError` 가 그것을 `InvalidState` 로 접어 `reason=target_invalid` 한 줄만 남긴다. 그러면
// **실행 중 업그레이드가 통째로 막히고**, 새 빌드를 깔 때마다 host 가 하나씩 늘며 세션이 옛 host 에
// 갇힌다. 2026-09-10 에 tag 99 로 실제로 그렇게 됐다(같은 날 들어온 95~98 도 같은 잠복 상태였다).
//
// `FieldSpec.optional` 의 주석이 이 결과를 이미 문장으로 적어 두었는데도 두 번 어겼다. 그래서 규칙을
// 글이 아니라 **컴파일 오류**로 옮긴다 — 다음 사람은 잊을 수가 없다.
comptime {
    for (core_fields_v1) |spec| {
        if (spec.tag > v1_initial_last_tag and !spec.optional) {
            @compileError(
                "handoff tag " ++ spec.name ++ " 는 v1 이후에 추가됐으므로 `.optional = true` 여야 한다 — " ++
                    "필수로 두면 구 host 의 레코드가 MissingRequiredField 로 거부돼 업그레이드가 막힌다",
            );
        }
    }
}

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
    /// **스크롤백 하나가 쓸 수 있는 바이트 상한**(null = 무제한 = 종전 동작).
    ///
    /// 줄 수가 아니라 바이트로 자르는 이유: 줄 하나의 인코딩 크기가 내용에 따라 19 배까지 벌어진다
    /// (197 칸이 색까지 꽉 찬 줄 ≈ 3.8 KB, 프롬프트만 있는 줄 ≈ 0.2 KB). 「최근 300 줄」로 자르면 총량이
    /// 1.2 MB 일 수도 23 MB 일 수도 있어, 상한을 넘기거나 여유를 버린다. 바이트로 자르면 **세션이 몇 개든
    /// 총량이 예산으로 고정**되고, 가벼운 세션은 같은 예산에 훨씬 많은 과거를 지킨다.
    ///
    /// 이 필드는 생성기 경로(`encodeValue`)가 그대로 들고 다니므로 시그니처를 안 바꾸고 닿는다.
    scrollback_budget: ?u64 = null,
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

fn encodeScrollbackRow(writer: *Writer, sb: *const Scrollback, index: usize) Error!void {
    const row = sb.row(index) orelse return error.InvalidValue;
    try encodeLength(writer, row.len, @sizeOf(Cell));
    for (row) |cell| try encodeValue(writer, Cell, &cell);
    try writer.byte(@intFromBool(sb.rowWrapped(index)));
    const prompt = sb.rowPrompt(index);
    try encodeValue(writer, @TypeOf(prompt), &prompt);
}

/// 한 줄의 **인코딩 후** 크기. 필드 구성(색 union·grapheme·link)에 따라 달라지므로 계산으로 못 내고
/// 실제로 한 번 써 봐야 안다. 버리는 버퍼에 쓰고 길이만 취한다.
fn measureScrollbackRow(parent: *Writer, sb: *const Scrollback, index: usize) Error!u64 {
    var probe: Writer = .{ .allocator = parent.allocator };
    defer probe.deinit();
    try encodeScrollbackRow(&probe, sb, index);
    return @intCast(probe.bytes.items.len);
}

/// **예산 안에 드는 「최신 K 줄」을 고른다.** 새 줄부터 거꾸로 담다가 예산이 차면 멈춘다.
fn scrollbackKeepCount(writer: *Writer, sb: *const Scrollback, budget: u64) Error!usize {
    var keep: usize = 0;
    var used: u64 = 0;
    var index = sb.count;
    while (index > 0) {
        index -= 1;
        const size = try measureScrollbackRow(writer, sb, index);
        const next = std.math.add(u64, used, size) catch return error.IntegerOverflow;
        if (next > budget) break;
        used = next;
        keep += 1;
    }
    return keep;
}

fn encodeScrollback(writer: *Writer, sb: *const Scrollback) Error!void {
    if (sb.cap > max_scrollback_rows or sb.count > max_scrollback_rows or sb.count > sb.cap)
        return error.LimitExceeded;
    if (sb.pushed_abs != std.math.add(usize, sb.evicted_abs, sb.count) catch return error.IntegerOverflow)
        return error.InvalidValue;

    // **자르기는 「앞줄이 밀려났다」로 표현한다 — 포맷을 안 바꾼다.**
    //
    // 스크롤백은 링 버퍼이고 `evicted_abs` 가 「앞에서 몇 줄이 밀려났나」다. 최신 K 줄만 실으면서
    // `evicted_abs = pushed_abs - K` 로 적으면 `pushed_abs == evicted_abs + count` 불변식이 그대로
    // 성립한다. 즉 **잘린 handoff 도 온전한 스크롤백**이라, 새 tag 도 스키마 변경도 필요 없고 구
    // reader 가 그대로 읽는다(2026-09-10 에 tag 99 를 필수로 추가했다가 업그레이드가 전멸한 것과
    // 정반대의 성질이다 — 여기엔 그 위험이 구조적으로 없다).
    const keep = if (writer.scrollback_budget) |budget|
        try scrollbackKeepCount(writer, sb, budget)
    else
        sb.count;
    const dropped = sb.count - keep;
    const evicted = std.math.add(usize, sb.evicted_abs, dropped) catch return error.IntegerOverflow;

    try writer.integer(usize, sb.cap);
    try writer.integer(usize, evicted);
    try writer.integer(usize, sb.pushed_abs);
    try writer.byte(@intFromBool(sb.rewrap_pending));
    try writer.integer(usize, keep);
    for (dropped..sb.count) |index| try encodeScrollbackRow(writer, sb, index);
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
        // **프레임까지 놓아준다.** `data` 만 free 하면 애니메이션 프레임이 통째로 샌다.
        errdefer image.freeAll(allocator);
        if (result.map.contains(image.id)) return error.DuplicateField;
        // **회계는 프레임을 포함한다.** 코덱은 저장소와 **독립으로** 합계를 다시 세어 대조하는데,
        // 그 계산이 `data.len` 만 보고 있었다 — 애니메이션이 있는 세션의 handoff 가 합계 불일치로
        // **통째로 거부됐다**(`InvalidValue`). 프레임 하나만 있어도 exec 가 실패한다(적대적 검증 실측).
        actual_total = std.math.add(usize, actual_total, image.totalBytes()) catch return error.IntegerOverflow;
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
    return encodeCoreWithScrollbackBudget(allocator, core, null);
}

/// 스크롤백을 **바이트 예산 안에서만** 싣는 인코더. `budget == null` 이면 `encodeCore` 와 byte-identical 이다.
///
/// 업그레이드 handoff 는 셸을 멈춘 채 5 초 안에 두 벌을 durable 하게 써야 해서 64 MiB 상한이 있다
/// (`upgrade_limits`). 세션이 쌓이면 그 상한을 넘겨 **업그레이드 자체가 거절**되고(`state_too_large`),
/// 그러면 새 host 가 떠 세션이 두 host 로 갈린다 — 2026-09-10 에 그렇게 갈린 pane 하나를 실제로 잃었다.
/// 「과거 몇천 줄」과 「세션 자체」 중 후자를 지키는 선택이다.
pub fn encodeCoreWithScrollbackBudget(
    allocator: std.mem.Allocator,
    core: *const TerminalCore,
    scrollback_budget: ?u64,
) Error![]u8 {
    if (core.response.items.len != 0) return error.InvalidValue;
    var writer: Writer = .{ .allocator = allocator, .scrollback_budget = scrollback_budget };
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
    /// GUI 소유 불투명 바이트. 비어 있으면 인코딩하지 않는다 — 구 host 가 만든 레코드와 구분되지 않는다.
    layout_blob: []const u8 = "",
};

/// 한 runtime 이 **무엇 때문에 큰지**를 태그별로 나눈 값(순수 계산 — 로그도 부작용도 없다).
///
/// 2026-09-11: 사용자 host 가 `state_too_large` 로 업그레이드에 실패했는데, **무엇이 64 MiB 를
/// 채웠는지 알 방법이 없었다.** footprint(62.2 MB)를 직렬화 크기로 오해해 「스크롤백이 93%」라고
/// 진단했다가, 실측해 보니 평범한 세션의 직렬화는 **1.64 MB/세션**(20 개 = 33 MB)으로 상한의 절반에
/// 불과했다 — 즉 **스크롤백은 주범이 아니었다.** 남은 후보(이미지·store·saved_screen)를 가르려면
/// 태그별로 재는 수밖에 없다.
///
/// 원인을 모르는 채로 업그레이드 경로를 고치지 않기 위해, **재는 것을 먼저 만든다.**
pub const RuntimeSizeBreakdown = struct {
    runtime_id: u128,
    total: usize,
    /// 화면 + 스크롤백(tag 2·31). 대개 여기가 가장 크다.
    screens: usize,
    /// kitty 이미지와 배치(tag 81·82·92·93·94). peak 639 MB 를 만든 축이라 1 순위 용의자다.
    images: usize,
    /// grapheme·link store(tag 43·45). 줄을 잘라도 **안 줄어드는** 몫이다(실측: 줄 98% 제거에 크기는 86% 감소).
    stores: usize,
    /// 나머지 전부.
    other: usize,
};

/// 각 runtime 을 **따로** 인코딩해 크기를 잰다. 태그별 몫은 해당 필드만 담은 코어를 다시 인코딩하는
/// 대신, 전체에서 그 필드를 뺀 차이로 구한다 — 코어를 복제하지 않으므로 pause 중에도 안전하다.
pub fn runtimeSizeBreakdown(
    allocator: std.mem.Allocator,
    view: RuntimeView,
) Error!RuntimeSizeBreakdown {
    const total_bytes = try encodeCore(allocator, view.core);
    defer allocator.free(total_bytes);

    var screens: usize = 0;
    var images: usize = 0;
    var stores: usize = 0;
    var writer: Writer = .{ .allocator = allocator };
    defer writer.deinit();
    inline for (core_fields_v1) |spec| {
        const before = writer.bytes.items.len;
        const Field = @TypeOf(@field(view.core.*, spec.name));
        try encodeValue(&writer, Field, &@field(view.core.*, spec.name));
        const size = writer.bytes.items.len - before;
        if (std.mem.eql(u8, spec.name, "screen") or std.mem.eql(u8, spec.name, "saved_screen")) {
            screens += size;
        } else if (std.mem.startsWith(u8, spec.name, "kitty_")) {
            images += size;
        } else if (std.mem.endsWith(u8, spec.name, "_store")) {
            stores += size;
        }
    }
    const counted = screens + images + stores;
    return .{
        .runtime_id = view.runtime_id,
        .total = total_bytes.len,
        .screens = screens,
        .images = images,
        .stores = stores,
        .other = if (total_bytes.len > counted) total_bytes.len - counted else 0,
    };
}

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
    /// 디코드된 GUI 소유 불투명 바이트. 태그가 없던 레코드(구 host)는 빈 슬라이스다.
    layout_blob: []u8 = &.{},

    fn deinit(self: *RuntimeState) void {
        // **blob 도 해제한다.** `core` 만 놓아 주면 런타임마다 최대 4 KiB 가 샌다 — host 는 업그레이드마다
        // 전 런타임을 디코드하므로 누수가 반복 누적된다.
        if (self.layout_blob.len != 0) self.core.allocator.free(self.layout_blob);
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
        // 태그 12 는 **반드시 optional** 이다. 구 host 의 디코더는 모르는 태그를 optional 일 때만
        // 건너뛴다 — 필수로 두면 신 host 가 쓴 레코드를 구 host 가 `UnknownRequiredField` 로 거부해
        // **롤백이 막힌다**(#3488 이 tag 99 로 겪은 그대로).
        if (runtime.layout_blob.len != 0) {
            if (runtime.layout_blob.len > max_layout_blob_bytes) return error.LimitExceeded;
            const layout_start = try writer.beginTlv(12, flag_optional);
            try writer.append(runtime.layout_blob);
            try writer.endTlv(layout_start);
        }
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
    var layout_blob: []u8 = &.{};
    var layout_seen = false;
    errdefer if (core_initialized) result.core.deinit();
    errdefer if (layout_blob.len != 0) allocator.free(layout_blob);
    while (section.pos < section.bytes.len) {
        const tag = try section.integer(u32);
        const flags = try section.integer(u16);
        _ = try section.integer(u16);
        const raw_len = try section.integer(u64);
        if (raw_len > max_single_blob_bytes) return error.LimitExceeded;
        var field = try section.sub(std.math.cast(usize, raw_len) orelse return error.LimitExceeded);
        if (tag == 12) {
            // **`seen` 에 넣지 않는다.** 그 배열은 「1..11 은 전부 있어야 한다」를 강제하는데, 태그 12 는
            // 구 host 의 레코드에 아예 없다 — 필수로 세면 업그레이드가 통째로 막힌다.
            if (flags & flag_optional == 0) return error.UnknownRequiredField;
            if (layout_seen) return error.DuplicateField;
            layout_seen = true;
            if (field.bytes.len > max_layout_blob_bytes) return error.LimitExceeded;
            if (field.bytes.len != 0)
                layout_blob = allocator.dupe(u8, field.bytes) catch return error.OutOfMemory;
            field.pos = field.bytes.len;
            continue;
        }
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
    result.layout_blob = layout_blob;
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

/// U1의 exhaustive fixture가 codec의 stable-tag 표를 두 번째 목록으로 복사하지 않게 한다. 각 필드의
/// canonical encoding을 같은 크기의 fresh core와 비교하므로 pointer/allocator 같은 native 표현이 아니라 실제
/// handoff wire에서 관측되는 logical value가 달라야 coverage로 센다.
fn observeNonDefaultCoreFields(
    coverage: *[core_fields_v1.len]bool,
    baseline: *const TerminalCore,
    candidate: *const TerminalCore,
) !void {
    inline for (core_fields_v1, 0..) |spec, index| {
        var baseline_writer: Writer = .{ .allocator = std.testing.allocator };
        defer baseline_writer.deinit();
        const Field = @TypeOf(@field(baseline.*, spec.name));
        try encodeValue(&baseline_writer, Field, &@field(baseline.*, spec.name));

        var candidate_writer: Writer = .{ .allocator = std.testing.allocator };
        defer candidate_writer.deinit();
        try encodeValue(&candidate_writer, Field, &@field(candidate.*, spec.name));
        coverage[index] = coverage[index] or
            !std.mem.eql(u8, baseline_writer.bytes.items, candidate_writer.bytes.items);
    }
}

fn expectCanonicalCoreRoundTrip(core: *const TerminalCore) !void {
    const allocator = std.testing.allocator;
    const encoded = try encodeCore(allocator, core);
    defer allocator.free(encoded);
    var restored = try decodeCore(allocator, encoded);
    defer restored.deinit();
    const reencoded = try encodeCore(allocator, &restored);
    defer allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, encoded, reencoded);
}

fn observeWriteFixture(coverage: *[core_fields_v1.len]bool, prefix: []const u8) !void {
    const allocator = std.testing.allocator;
    var seed = try TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer seed.deinit();
    const seed_bytes = try encodeCore(allocator, &seed);
    defer allocator.free(seed_bytes);
    var baseline = try decodeCore(allocator, seed_bytes);
    defer baseline.deinit();
    var candidate = try decodeCore(allocator, seed_bytes);
    defer candidate.deinit();
    try candidate.write(prefix);
    try observeNonDefaultCoreFields(coverage, &baseline, &candidate);
    try expectCanonicalCoreRoundTrip(&candidate);
}

const OomParserFixture = enum { osc52, notification, apc };

/// 제품 parser가 사용하는 allocator의 다음 grow를 실패시켜, 수십~수백 MiB를 실제로 채우지 않고도
/// 정상적으로 도달 가능한 bounded-overflow 상태를 만든다. FailingAllocator는 같은 backing allocator로
/// free/realloc을 전달하므로 기존 buffer ownership은 바뀌지 않는다.
fn observeOomParserFixture(
    coverage: *[core_fields_v1.len]bool,
    kind: OomParserFixture,
) !void {
    const allocator = std.testing.allocator;
    var seed = try TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer seed.deinit();
    const seed_bytes = try encodeCore(allocator, &seed);
    defer allocator.free(seed_bytes);
    var baseline = try decodeCore(allocator, seed_bytes);
    defer baseline.deinit();
    var candidate = try decodeCore(allocator, seed_bytes);
    defer candidate.deinit();

    switch (kind) {
        .osc52 => try candidate.write("\x1b]52;" ++ "a" ** 2048),
        .notification => try candidate.write("\x1b]777;notify;title;body"),
        .apc => try candidate.write("\x1b_Gpartial"),
    }
    const used, const capacity = switch (kind) {
        .osc52, .notification => .{ candidate.osc_buffer.items.len, candidate.osc_buffer.capacity },
        .apc => .{ candidate.apc_buffer.items.len, candidate.apc_buffer.capacity },
    };
    const grow_len = capacity - used + 1;
    const grow = try allocator.alloc(u8, grow_len);
    defer allocator.free(grow);
    @memset(grow, 'x');
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    candidate.allocator = failing.allocator();
    errdefer candidate.allocator = allocator;
    try candidate.write(grow);
    candidate.allocator = allocator;

    // OSC52의 large latch와 각 parser overflow는 terminator 전에 존재하는 실제 handoff state다.
    try observeNonDefaultCoreFields(coverage, &baseline, &candidate);
    try expectCanonicalCoreRoundTrip(&candidate);
    if (kind != .apc) {
        try candidate.write("\x07");
        try observeNonDefaultCoreFields(coverage, &baseline, &candidate);
        try expectCanonicalCoreRoundTrip(&candidate);
    }
}

test "handoff v1 exhaustive valid fixtures cover every stable core field and reencode canonically" {
    const allocator = std.testing.allocator;
    var coverage: [core_fields_v1.len]bool = .{false} ** core_fields_v1.len;

    var seed = try TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer seed.deinit();
    const seed_bytes = try encodeCore(allocator, &seed);
    defer allocator.free(seed_bytes);
    // 두 비교 객체를 같은 canonical bytes에서 만들어 `undefined`인 고정 버퍼의 사용하지 않는 tail이
    // 서로 다른 우연한 값을 가져 coverage를 위조하지 못하게 한다.
    var baseline = try decodeCore(allocator, seed_bytes);
    defer baseline.deinit();
    var candidate = try decodeCore(allocator, seed_bytes);
    defer candidate.deinit();
    // 이 fixture는 제품이 사용하는 공개 VT 입력과 config 주입 경로만으로 만든다. 한 core에서 동시에
    // 존재할 수 없는 parser continuation은 아래의 독립 fixture들로 나눈다.
    try candidate.resize(24, 5);
    candidate.ambiguous_wide = true; // set_ambiguous_wide core command의 제품 적용과 같은 mutation.
    candidate.emoji_wide = true; // set_emoji_wide core command의 제품 적용과 같은 mutation.
    candidate.setCellMetrics(8, 16);
    candidate.setDefaultColors(.{ .r = 1, .g = 2, .b = 3 }, .{ .r = 4, .g = 5, .b = 6 });
    var config_palette: [16]?maru.terminal.Rgb = .{null} ** 16;
    config_palette[1] = .{ .r = 7, .g = 8, .b = 9 };
    candidate.setConfigPalette(config_palette);
    candidate.setDefaultCursorShape(.bar);
    try candidate.write(
        "line0\r\nline1\r\nline2\r\nline3\r\nline4\r\nline5" ++
            "\x1b[2;3r\x1b[?6h" ++
            "\x1b[?1h\x1b=\x1b[?1007l\x1b[?2004h\x1b[?1004h" ++
            "\x1b[?1003h\x1b[?1016h\x1b[?2026h\x1b[?2026l\x1b[?2027h" ++
            "\x1b[?25l\x1b[6 q\x1b[4h\x1b[?7l\x1b[?5h\x1b[>3u" ++
            "\x1b]8;;https://example.com\x07e\xcc\x81\x1b]8;;\x07" ++
            "\x1b]133;A\x07\x1b]133;B\x07\x1b]133;C\x07\x1b]133;D;17\x07\x1b]133;A\x07" ++
            "\x1b]52;c;aGVsbG8=\x07\x1b]52;p;?\x07" ++
            "\x1b]777;notify;handoff;body\x07\x1b]9;4;1;42\x07" ++
            "\x1b(0\x1b)0\x0e\x07\x1bH" ++
            "\x1b]7;file://build-box/srv/app\x07" ++
            "\x1b]5379;ssh;me@build-box\x07\x1b]7;file://build-box/srv/app\x07" ++
            "\x1b]2;handoff title\x07" ++
            "\x1b]10;#112233\x07\x1b]11;#445566\x07\x1b]4;2;#778899\x07",
    );
    candidate.scrollViewport(2);
    candidate.selectionStart(0, 0);
    candidate.selectionExtend(1, 3);
    candidate.setSelectionBlock(true);
    // OSC 8를 닫지 않은 pen 상태도 실제 parser 도달 상태이며, 화면 cell의 link_store와는 별도 필드다.
    try candidate.write("\x1b]8;;https://active.example\x07");
    // OSC 99의 d=0 조각은 알림을 발사하지 않고 제품 조립 상태 네 필드를 모두 유지한다.
    try candidate.write("\x1b]99;i=build:d=0;빌드\x1b\\");
    try candidate.write("\x1b]99;i=build:d=0:p=body;4174개\x1b\\");
    try observeNonDefaultCoreFields(&coverage, &baseline, &candidate);
    try expectCanonicalCoreRoundTrip(&candidate);

    const rgba = [_]u8{ 9, 8, 7, 255 } ** 4;
    var b64: [64]u8 = undefined;
    const encoded_rgba = std.base64.standard.Encoder.encode(&b64, &rgba);
    var kitty_seq: [192]u8 = undefined;
    try candidate.write(try std.fmt.bufPrint(
        &kitty_seq,
        "\x1b_Ga=T,f=32,s=2,v=2,I=42,U=1,c=2,r=2;{s}\x1b\\",
        .{encoded_rgba},
    ));
    candidate.clearResponse(); // PTY-bound reply는 quiesce가 flush하며 U1 logical core payload에는 넣지 않는다.
    try candidate.write("\x1b_Ga=p,I=42,p=7,c=2,r=2,C=1\x1b\\");
    candidate.clearResponse();
    // alt 화면은 primary 전체를 saved_screen으로 옮기는 공개 DECSET 경로라 두 필드를 함께 검증한다.
    try candidate.write("\x1b[?1049halt-screen");
    // shell event queue의 공개 producer가 cap에 닿으면 마지막 event 대신 overflow latch를 보존한다.
    for (0..4097) |_| try candidate.write("\x1b]133;A\x07");
    try observeNonDefaultCoreFields(&coverage, &baseline, &candidate);
    try expectCanonicalCoreRoundTrip(&candidate);

    // parser state는 상호배타적이므로 각 continuation을 독립 core로 만든다.
    try observeWriteFixture(&coverage, &.{ 0xED, 0x95 });
    try observeWriteFixture(&coverage, "\x1b[?12:34 $");
    try observeWriteFixture(&coverage, "\x1b[1;2;3;4;5;6;7;8;9;10;11;12;13;14;15;16;17;");
    try observeWriteFixture(&coverage, "\x1b[?2026h");
    try observeWriteFixture(&coverage, "\x1b]2;partial");
    try observeWriteFixture(&coverage, "\x1bP" ++ "q" ** 65);
    try observeWriteFixture(&coverage, "\x1b_Ga=t,f=32,s=1,v=1,i=7,m=1;AAAA\x1b\\");
    try observeWriteFixture(&coverage, "\x1b_Gpartial");
    try observeOomParserFixture(&coverage, .osc52);
    try observeOomParserFixture(&coverage, .notification);
    try observeOomParserFixture(&coverage, .apc);

    var missing: [core_fields_v1.len]usize = undefined;
    var missing_count: usize = 0;
    inline for (core_fields_v1, 0..) |spec, index| {
        if (!coverage[index]) {
            _ = spec;
            missing[missing_count] = index;
            missing_count += 1;
        }
    }
    for (missing[0..missing_count]) |index| {
        const spec = core_fields_v1[index];
        std.debug.print("missing non-default handoff field: {s} (tag {d})\n", .{ spec.name, spec.tag });
    }
    try std.testing.expectEqual(@as(usize, 0), missing_count);
}

test "handoff v1 round-trips partial UTF-8 and escape parser continuations" {
    try expectCoreContinuation(&.{ 0xED, 0x95 }, &.{0x9C}); // 한 UTF-8 split
    try expectCoreContinuation("\x1b[31", "mred");
    try expectCoreContinuation("\x1b]2;partial", "\x07");
    try expectCoreContinuation("\x1bP$q", "m\x1b\\");
    try expectCoreContinuation("\x1b_Ga=t,f=32,s=1,v=1,i=7;AAAA", "\x1b\\");
}

test "handoff v1 이 조립 중인 OSC 99 알림을 넘긴다 (적대적 검증: 조합 경로)" {
    // **화면 왕복 판정자는 이걸 못 잡는다** — 조립 중인 알림은 아무것도 렌더하지 않아서, 통째로
    // 잃어도 `dumpUtf8` 비교가 초록이다. 그래서 조합 경로를 따로 꿴다: `d=0` 로 절반을 보낸 뒤
    // exec 를 건너가고, 나머지 `d=1` 조각을 **복원된 코어에** 먹여 온전한 알림이 서는지 본다.
    // 잃으면 뒤이어 오는 마지막 조각이 **제목 없는 알림**을 띄운다.
    const allocator = std.testing.allocator;
    var before = try TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer before.deinit();
    try before.write("\x1b]99;i=build:d=0;빌드\x1b\\");
    try before.write("\x1b]99;i=build:d=0:p=body;4174개\x1b\\");

    const bytes = try encodeCore(allocator, &before);
    defer allocator.free(bytes);
    var restored = try decodeCore(allocator, bytes);
    defer restored.deinit();

    try restored.write("\x1b]99;i=build:p=title; 완료\x1b\\");
    try std.testing.expectEqualStrings("빌드 완료", restored.notification_title.items);
    try std.testing.expectEqualStrings("4174개", restored.notification_body.items);
    try std.testing.expect(restored.notification_pending);
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

// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 세션은 host 에 살아남는데 **어느 탭이었는지**는
// `workspace.v1` 에만 있어, 그 파일이 상하면 복구가 「새 탭 N 개」로 끝난다. 2026-09-11 실측 — 복원이
// 불완전한 채 종료하면서 그 파일이 343 B 로 덮였고 탭 이름·분할·순서가 전부 사라졌다. 세션 23 개는
// 멀쩡했지만 배치는 복원할 근거가 없었다.
//
// host 가 **해석하지 않는 불투명 바이트**로 그 조각을 함께 나르면 단일 실패점이 사라진다. host 는
// 저장·운반만 하므로 「런타임 사실은 host, 표현은 GUI」소유권이 안 깨진다.
test "handoff v1 은 GUI 소유 불투명 레이아웃 조각을 런타임마다 그대로 나른다" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    var bare = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer bare.deinit();
    const blob = "tab=3;pane=0/1;name=\xed\x83\xad";
    const views = [_]RuntimeView{
        .{ .runtime_id = 1, .surface_id = 1, .child_pid = 101, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &core, .layout_blob = blob },
        // 두 번째는 **비어 있다** — 구 host 가 만든 레코드와 바이트가 구분되지 않아야 한다.
        .{ .runtime_id = 2, .surface_id = 2, .child_pid = 102, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 41, .pty_dev = 4, .pty_ino = 5, .pty_rdev = 6, .core = &bare },
    };
    const encoded = try encodeHost(allocator, .{
        .host_id = 0xCAFE,
        .upgrade_epoch = 1,
        .authority_generation = 1,
        .membership_generation = 1,
        .next_handle = 9,
        .runtimes = &views,
    });
    defer allocator.free(encoded);
    var decoded = try decodeHost(allocator, encoded);
    defer decoded.deinit();

    try std.testing.expectEqualStrings(blob, decoded.runtimes[0].layout_blob);
    try std.testing.expectEqual(@as(usize, 0), decoded.runtimes[1].layout_blob.len);

    // **빈 blob 은 바이트를 한 개도 안 쓴다.** 구 host 가 만든 레코드와 구분되지 않아야 하기 때문이다.
    // 헤더만이라도 쓰면 「blob 없음」과 「빈 blob」이 서로 다른 바이트가 되고, 그 차이가 업그레이드
    // 경로의 크기 비교·해시에 조용히 섞인다. 한 바이트짜리 blob 과의 **차이가 정확히 헤더+1** 인지로
    // 고정한다 — 빈 쪽이 헤더를 쓰면 이 차이가 1 로 줄어 빨개진다.
    var solo = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer solo.deinit();
    const empty_views = [_]RuntimeView{
        .{ .runtime_id = 1, .surface_id = 1, .child_pid = 101, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &solo },
    };
    const one_views = [_]RuntimeView{
        .{ .runtime_id = 1, .surface_id = 1, .child_pid = 101, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &solo, .layout_blob = "x" },
    };
    const host_base: HostView = .{
        .host_id = 1,
        .upgrade_epoch = 1,
        .authority_generation = 1,
        .membership_generation = 1,
        .next_handle = 9,
        .runtimes = &empty_views,
    };
    const without = try encodeHost(allocator, host_base);
    defer allocator.free(without);
    var with_host = host_base;
    with_host.runtimes = &one_views;
    const with_one = try encodeHost(allocator, with_host);
    defer allocator.free(with_one);
    try std.testing.expectEqual(tlv_header_len + @as(usize, 1), with_one.len - without.len);
}

// handoff 바이트는 디스크를 거쳐 오고 구/신 host 가 서로의 레코드를 읽는다. 길이 필드가 손상되면
// 디코더가 그걸 그대로 믿어선 안 된다.
//
// **이 테스트가 증명하지 «않는» 것**: 디코더의 `max_layout_blob_bytes` 검사 자체. 길이만 키우면 본문이
// 섹션을 넘어 **절단 오류가 먼저** 나므로 상한 검사에 닿지 않는다 — 그 검사를 지워도 이 테스트는
// 통과한다(적대적 검증 S3 생존). 정상 경로로는 과대 레코드를 만들 수 없어 여기서는 더 못 간다.
// 그 검사와 중복 태그 가드는 `tests/handoff_layout_blob_boundary.zig` 가 **소스 수준으로** 고정한다.
test "handoff v1 은 레이아웃 조각의 길이 필드가 손상된 레코드를 거절한다" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    const views = [_]RuntimeView{
        .{ .runtime_id = 1, .surface_id = 1, .child_pid = 101, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &core, .layout_blob = "ab" },
    };
    const encoded = try encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 1,
        .authority_generation = 1,
        .membership_generation = 1,
        .next_handle = 9,
        .runtimes = &views,
    });
    defer allocator.free(encoded);

    // 태그 12 TLV 를 찾는다: tag(u32=12) + flags(u16=1) + reserved(u16) + len(u64=2).
    // 이 코덱은 **빅엔디안**으로 쓴다(`Writer.integer`). 리틀로 찾으면 못 찾고 조용히 통과한다.
    var header: [tlv_header_len]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], 12, .big);
    std.mem.writeInt(u16, header[4..6], flag_optional, .big);
    std.mem.writeInt(u16, header[6..8], 0, .big);
    std.mem.writeInt(u64, header[8..16], 2, .big);
    const at = std.mem.indexOf(u8, encoded, &header) orelse {
        std.debug.print("태그 12 TLV 를 못 찾았다 — 헤더 형식이 바뀌었으면 이 테스트가 무의미해진다\n", .{});
        return error.LayoutTagHeaderNotFound;
    };

    const tampered = try allocator.dupe(u8, encoded);
    defer allocator.free(tampered);
    // 길이만 상한 너머로 키운다 — 디코더가 자기 상한으로 거절해야 한다.
    std.mem.writeInt(u64, tampered[at + 8 ..][0..8], max_layout_blob_bytes + 1, .big);
    if (decodeHost(allocator, tampered)) |ok| {
        var mutable = ok;
        mutable.deinit();
        std.debug.print("상한을 넘는 레이아웃 조각이 디코딩을 통과했다 — 런타임당 무제한 할당\n", .{});
        return error.OversizedLayoutBlobAccepted;
    } else |err| {
        // 어떤 거절이든 좋다 — **통과만 안 하면 된다.** 길이를 키웠으므로 상한·절단 어느 쪽으로도 걸린다.
        try std.testing.expect(err != error.OutOfMemory);
    }
}

// **구 host 의 레코드에는 태그 12 가 아예 없다.** 그것을 신 host 가 읽지 못하면 업그레이드가 통째로
// 막힌다 — #3488 이 tag 99 를 필수로 두어 겪은 그대로(업그레이드가 몇 시간 막혔고 설치마다 host 가
// 하나씩 쌓였다). 없으면 빈 슬라이스여야 하고, 나머지 필드는 전부 정상이어야 한다.
test "handoff v1 은 태그 12 가 없는 구 writer 레코드를 그대로 받는다" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    const views = [_]RuntimeView{
        .{ .runtime_id = 7, .surface_id = 3, .child_pid = 101, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &core },
    };
    const encoded = try encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 1,
        .authority_generation = 1,
        .membership_generation = 1,
        .next_handle = 9,
        .runtimes = &views,
    });
    defer allocator.free(encoded);
    // 빈 blob 은 인코딩되지 않으므로 이 바이트열에는 태그 12 가 **없다**.
    var decoded = try decodeHost(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(usize, 1), decoded.runtimes.len);
    try std.testing.expectEqual(@as(u128, 7), decoded.runtimes[0].runtime_id);
    try std.testing.expectEqual(@as(usize, 0), decoded.runtimes[0].layout_blob.len);
}

// 상한이 없으면 한 GUI 가 host 의 handoff 예산을 통째로 먹을 수 있다. 오늘 `state_too_large` 로
// 업그레이드가 막힌 적이 있으므로(#3527) 상한은 **인코딩 시점에** 거절해야 한다 — 디코드까지 가면
// 이미 쓴 뒤다.
test "handoff v1 은 상한을 넘는 레이아웃 조각을 인코딩에서 거절한다" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    const oversized = try allocator.alloc(u8, max_layout_blob_bytes + 1);
    defer allocator.free(oversized);
    @memset(oversized, 'x');
    const views = [_]RuntimeView{
        .{ .runtime_id = 1, .surface_id = 1, .child_pid = 101, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &core, .layout_blob = oversized },
    };
    try std.testing.expectError(error.LimitExceeded, encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 1,
        .authority_generation = 1,
        .membership_generation = 1,
        .next_handle = 9,
        .runtimes = &views,
    }));
    // 상한 **정확히** 는 통과해야 한다 — off-by-one 이면 경계 크기 레이아웃이 조용히 못 실린다.
    const exact = try allocator.alloc(u8, max_layout_blob_bytes);
    defer allocator.free(exact);
    @memset(exact, 'y');
    const ok_views = [_]RuntimeView{
        .{ .runtime_id = 1, .surface_id = 1, .child_pid = 101, .cols = 8, .rows = 2, .resize_generation = 0, .fd_slot = 40, .pty_dev = 1, .pty_ino = 2, .pty_rdev = 3, .core = &core, .layout_blob = exact },
    };
    const encoded = try encodeHost(allocator, .{
        .host_id = 1,
        .upgrade_epoch = 1,
        .authority_generation = 1,
        .membership_generation = 1,
        .next_handle = 9,
        .runtimes = &ok_views,
    });
    defer allocator.free(encoded);
    var decoded = try decodeHost(allocator, encoded);
    defer decoded.deinit();
    try std.testing.expectEqual(max_layout_blob_bytes, decoded.runtimes[0].layout_blob.len);
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

test "handoff v1 이 애니메이션 프레임과 재생 상태를 나른다 (적대적 검증)" {
    // #3505 본문에 «reflection 코덱이 중첩 슬라이스를 그대로 나른다» 고 **적어 놓고 재지 않았다**.
    // 프레임은 `[]KittyFrame` 이고 그 안에 또 `[]u8` 이 있다 — 코덱이 이 중첩을 못 다루면 exec 를
    // 넘어가며 돌던 애니메이션이 첫 프레임에서 멈추고, 앱은 자기가 보낸 프레임이 사라진 것을 모른다
    // (다시 보내지 않는다).
    const allocator = std.testing.allocator;
    var before = try TerminalCore.init(allocator, .{ .cols = 10, .rows = 4 });
    defer before.deinit();
    var b64: [64]u8 = undefined;
    var seq: [200]u8 = undefined;
    const red = [_]u8{ 255, 0, 0, 255 } ** 4;
    const green = [_]u8{ 0, 255, 0, 255 } ** 4;
    try before.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=t,f=32,s=2,v=2,i=1,q=2;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&b64, &red)}));
    try before.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=f,f=32,s=2,v=2,i=1,z=70,q=2;{s}\x1b\\", .{std.base64.standard.Encoder.encode(&b64, &green)}));
    try before.write("\x1b_Ga=p,i=1,q=2\x1b\\");
    try before.write("\x1b_Ga=a,i=1,r=1,z=70,s=3,v=5,q=2\x1b\\");
    _ = before.advanceAnimations(70); // 프레임 2 로 넘어간 상태로 exec 를 넘긴다

    const img_before = before.kitty_images.map.get(1).?;
    try std.testing.expectEqual(@as(u32, 2), img_before.frameCount());
    try std.testing.expectEqual(@as(u32, 2), img_before.current_frame);

    const bytes = try encodeCore(allocator, &before);
    defer allocator.free(bytes);
    var after = try decodeCore(allocator, bytes);
    defer after.deinit();

    const img = after.kitty_images.map.get(1) orelse return error.TestUnexpectedResult;
    // 프레임 픽셀이 살아 있다 — 중첩 슬라이스가 온전히 건너왔는가.
    try std.testing.expectEqual(@as(u32, 2), img.frameCount());
    try std.testing.expectEqualSlices(u8, &red, img.framePixels(1));
    try std.testing.expectEqualSlices(u8, &green, img.framePixels(2));
    // 재생 상태도 살아 있다 — 이게 없으면 복원 뒤 애니메이션이 처음부터 다시 돈다.
    try std.testing.expectEqual(@as(u32, 2), img.current_frame);
    try std.testing.expectEqual(@as(u32, 5), img.loops_left);
    try std.testing.expectEqual(@as(u32, 70), img.frameGapMs(1));
    // 회계도 프레임을 포함한 채 복원돼야 한다 — 안 그러면 예산이 어긋난 채 이어진다.
    try std.testing.expectEqual(before.kitty_images.total_bytes, after.kitty_images.total_bytes);
    // 복원된 코어에서 **이어서 돈다**(상태만 있고 안 돌면 반쪽이다).
    try std.testing.expect(after.advanceAnimations(70));
    try std.testing.expectEqual(@as(u32, 1), after.kitty_images.map.get(1).?.current_frame);
}

test "스크롤백 바이트 예산: 최신 줄만 남고 잘린 결과도 온전한 스크롤백이다" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();

    // 화면 2 줄짜리에 40 줄을 써서 38 줄을 스크롤백으로 밀어 올린다.
    for (0..40) |i| {
        var line_buf: [24]u8 = undefined;
        const line = try std.fmt.bufPrint(&line_buf, "line{d:0>3}\r\n", .{i});
        try core.write(line);
    }
    const full_rows = core.screen.sb.count;
    try std.testing.expect(full_rows > 10);

    // 예산 없음 = 종전과 동일해야 한다(byte-identical).
    const unbounded = try encodeCore(allocator, &core);
    defer allocator.free(unbounded);
    const explicit_null = try encodeCoreWithScrollbackBudget(allocator, &core, null);
    defer allocator.free(explicit_null);
    try std.testing.expectEqualSlices(u8, unbounded, explicit_null);

    // 한 줄 크기를 재서, 다섯 줄만 들어갈 예산을 만든다.
    var probe: Writer = .{ .allocator = allocator };
    defer probe.deinit();
    try encodeScrollbackRow(&probe, &core.screen.sb, full_rows - 1);
    const row_bytes: u64 = @intCast(probe.bytes.items.len);
    const budget = row_bytes * 5;

    const trimmed_bytes = try encodeCoreWithScrollbackBudget(allocator, &core, budget);
    defer allocator.free(trimmed_bytes);
    try std.testing.expect(trimmed_bytes.len < unbounded.len);

    // **디코드가 통과해야 한다** — 자르기를 「앞줄이 밀려났다」로 표현하므로 포맷은 그대로다.
    var trimmed = try decodeCore(allocator, trimmed_bytes);
    defer trimmed.deinit();

    const sb = &trimmed.screen.sb;
    try std.testing.expect(sb.count <= 5);
    try std.testing.expect(sb.count > 0);
    // 불변식: pushed_abs == evicted_abs + count. 깨지면 decode 가 이미 거절했겠지만 값으로도 못 박는다.
    try std.testing.expectEqual(sb.pushed_abs, sb.evicted_abs + sb.count);
    // 총 줄 수(pushed_abs)는 보존된다 — 「몇 줄이 흘러갔는가」는 잘라도 사실이 바뀌지 않는다.
    try std.testing.expectEqual(core.screen.sb.pushed_abs, sb.pushed_abs);
    // 남은 것은 **최신** 쪽이어야 한다.
    const newest_original = core.screen.sb.row(full_rows - 1).?;
    const newest_trimmed = sb.row(sb.count - 1).?;
    try std.testing.expectEqual(newest_original.len, newest_trimmed.len);
    for (newest_original, newest_trimmed) |a, b| try std.testing.expectEqual(a.codepoint, b.codepoint);

    // 예산이 한 줄도 못 담을 만큼 작으면 스크롤백은 비고, 그래도 온전해야 한다.
    const starved = try encodeCoreWithScrollbackBudget(allocator, &core, 1);
    defer allocator.free(starved);
    var empty = try decodeCore(allocator, starved);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.screen.sb.count);
    try std.testing.expectEqual(empty.screen.sb.pushed_abs, empty.screen.sb.evicted_abs);
}

fn nowNs() u64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

test "스크롤백 바이트 예산: 측정 비용이 pause 예산을 위협하지 않는다 (실측)" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 197, .rows = 60 });
    defer core.deinit();
    // 실사용 규모: 세션 하나의 스크롤백 약 800 줄.
    for (0..900) |i| {
        var buf: [220]u8 = undefined;
        const line = try std.fmt.bufPrint(&buf, "row{d:0>4} " ++ ("x" ** 180) ++ "\r\n", .{i});
        try core.write(line);
    }
    const rows = core.screen.sb.count;
    try std.testing.expect(rows > 500);

    const plain_start = nowNs();
    const plain = try encodeCore(allocator, &core);
    defer allocator.free(plain);
    const plain_ns = nowNs() - plain_start;

    // 예산을 «전부 담을 만큼» 크게 주면 모든 줄을 재게 된다 — 최악의 경우다.
    const worst_start = nowNs();
    const worst = try encodeCoreWithScrollbackBudget(allocator, &core, std.math.maxInt(u32));
    defer allocator.free(worst);
    const worst_ns = nowNs() - worst_start;

    std.debug.print(
        "\n  줄 {d} | 예산없음 {d:.1} ms | 최악(전량 측정) {d:.1} ms | 배수 {d:.2}x\n",
        .{ rows, @as(f64, @floatFromInt(plain_ns)) / 1e6, @as(f64, @floatFromInt(worst_ns)) / 1e6, @as(f64, @floatFromInt(worst_ns)) / @as(f64, @floatFromInt(plain_ns)) },
    );
    // 전량 측정이어도 결과는 같아야 한다(예산이 충분하므로 아무것도 안 잘림).
    try std.testing.expectEqualSlices(u8, plain, worst);
}

test "스크롤백 바이트 예산: store 는 안 잘려 절감이 덜 된다 (한계 실측)" {
    const allocator = std.testing.allocator;
    var core = try TerminalCore.init(allocator, .{ .cols = 60, .rows = 2 });
    defer core.deinit();
    // grapheme cluster(결합 문자)와 OSC 8 링크를 섞어 store 를 채운다.
    for (0..300) |i| {
        var buf: [256]u8 = undefined;
        const line = try std.fmt.bufPrint(
            &buf,
            "\x1b]8;;https://example.com/{d}\x1b\\링크\u{0301}{d}\x1b]8;;\x1b\\ 가\u{0301}나\u{0301}다\u{0301}\r\n",
            .{ i, i },
        );
        try core.write(line);
    }
    const full = try encodeCore(allocator, &core);
    defer allocator.free(full);
    // 최신 5 줄만 남기는 예산.
    var probe: Writer = .{ .allocator = allocator };
    defer probe.deinit();
    try encodeScrollbackRow(&probe, &core.screen.sb, core.screen.sb.count - 1);
    const budget: u64 = @as(u64, @intCast(probe.bytes.items.len)) * 5;
    const trimmed = try encodeCoreWithScrollbackBudget(allocator, &core, budget);
    defer allocator.free(trimmed);

    const kept_ratio = @as(f64, @floatFromInt(trimmed.len)) / @as(f64, @floatFromInt(full.len));
    std.debug.print(
        "\n  줄 {d}→5 로 잘랐는데 크기는 {d}B→{d}B ({d:.1}% 남음) — store 가 안 잘린 몫\n",
        .{ core.screen.sb.count, full.len, trimmed.len, kept_ratio * 100 },
    );
    try std.testing.expect(trimmed.len < full.len);
    var decoded = try decodeCore(allocator, trimmed);
    defer decoded.deinit();
    try std.testing.expect(decoded.screen.sb.count <= 5);
}

test "전제 검증: 실사용 규모 세션의 «직렬화» 크기는 얼마인가" {
    const allocator = std.testing.allocator;
    // 사용자 환경 실측값: 197x60, 스크롤백 약 800 줄.
    var core = try TerminalCore.init(allocator, .{ .cols = 197, .rows = 60 });
    defer core.deinit();
    for (0..900) |i| {
        var buf: [220]u8 = undefined;
        // 평범한 로그성 출력(색·결합문자·링크 없음) — 가장 흔한 모양.
        const line = try std.fmt.bufPrint(&buf, "[{d:0>5}] build step completed in 12ms, artifacts written to dist/\r\n", .{i});
        try core.write(line);
    }
    const bytes = try encodeCore(allocator, &core);
    defer allocator.free(bytes);
    const rows = core.screen.sb.count;
    const per_mb = @as(f64, @floatFromInt(bytes.len)) / 1048576.0;
    std.debug.print(
        "\n  Cell {d} B | 스크롤백 {d} 줄 | 직렬화 {d:.2} MB/세션 → 20 세션 {d:.1} MB (상한 64 MB)\n",
        .{ @sizeOf(Cell), rows, per_mb, per_mb * 20 },
    );
    try std.testing.expect(bytes.len > 0);
}

test "전제 검증: 크기 분해가 «무엇이 큰지» 를 실제로 가른다" {
    const allocator = std.testing.allocator;

    // (1) 평범한 로그 세션 — 화면·스크롤백이 지배해야 한다.
    var plain = try TerminalCore.init(allocator, .{ .cols = 197, .rows = 60 });
    defer plain.deinit();
    for (0..400) |i| {
        var buf: [220]u8 = undefined;
        try plain.write(try std.fmt.bufPrint(&buf, "[{d:0>5}] build step completed\r\n", .{i}));
    }
    const plain_view: RuntimeView = .{
        .runtime_id = 1,
        .surface_id = 1,
        .child_pid = 1,
        .cols = 197,
        .rows = 60,
        .resize_generation = 1,
        .fd_slot = 40,
        .pty_dev = 1,
        .pty_ino = 1,
        .pty_rdev = 1,
        .core = &plain,
    };
    const a = try runtimeSizeBreakdown(allocator, plain_view);

    // (2) 결합문자·링크가 많은 세션 — store 몫이 눈에 띄게 커야 한다.
    var rich = try TerminalCore.init(allocator, .{ .cols = 197, .rows = 60 });
    defer rich.deinit();
    for (0..400) |i| {
        var buf: [256]u8 = undefined;
        try rich.write(try std.fmt.bufPrint(
            &buf,
            "\x1b]8;;https://example.com/{d}\x1b\\가\u{0301}나\u{0301}다\u{0301}\x1b]8;;\x1b\\\r\n",
            .{i},
        ));
    }
    var rich_view = plain_view;
    rich_view.runtime_id = 2;
    rich_view.core = &rich;
    const b = try runtimeSizeBreakdown(allocator, rich_view);

    const kb = struct {
        fn f(v: usize) f64 {
            return @as(f64, @floatFromInt(v)) / 1024.0;
        }
    }.f;
    std.debug.print(
        "\n  평범 : total {d:.0} KB | screens {d:.0} | images {d:.0} | stores {d:.0} | other {d:.0}" ++
            "\n  결합 : total {d:.0} KB | screens {d:.0} | images {d:.0} | stores {d:.0} | other {d:.0}\n",
        .{ kb(a.total), kb(a.screens), kb(a.images), kb(a.stores), kb(a.other), kb(b.total), kb(b.screens), kb(b.images), kb(b.stores), kb(b.other) },
    );

    // 평범한 세션은 화면이 지배한다.
    try std.testing.expect(a.screens > a.images);
    try std.testing.expect(a.screens > a.stores);
    // **가르는 힘이 있는가** — 결합문자 세션의 store 몫이 평범한 쪽보다 확실히 커야 한다.
    try std.testing.expect(b.stores > a.stores);
}
