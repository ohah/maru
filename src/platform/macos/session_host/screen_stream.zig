//! `maru.screen-stream.v1` — session-host의 화면 snapshot/delta record codec(§12).
//!
//! `snapshot_chunk`/`delta_chunk`(MRSH kind 6/7)의 payload는 native struct memory dump가 **아니라** 이 파일의
//! versioned record codec이다. renderer의 `RenderSnapshot`이나 debug용 `maru.snapshot.v3`을 그대로 IPC ABI로 쓰지
//! 않는 이유는 그것들이 in-process view/부분 직렬화라 Zig/Swift padding·pointer·palette 참조에 묶여 있기 때문이다.
//! 이 codec은 **resolved** 화면 상태만 중립 wire로 나른다(padding/pointer 없음, 색은 이미 resolve된 RGB).
//!
//! 단일 출처는 [영속 터미널 세션 호스트](../../../../docs/persistent-session-host.md) §12다. §12는 record **필드
//! 목록**을 정하고 "모든 정수 network byte order, 문자열 `length:u32 + UTF-8`, blob은 문자열 field에 넣지 않는다"를
//! 못박는다. 각 필드의 정확한 바이트 크기·순서는 이 구현이 확정하며(§12에 반영), 아래 record 주석이 그 레이아웃의
//! 미러다. 순수 OS-중립 codec(platform import 0)이라 non-macOS에서 wire 회귀를 고정한다.
//!
//! record 하나 = **28-byte record header + record body**:
//!   codec_version:u16=1 | record_kind:u16 | generation:u64 | sequence:u64 | chunk_index:u32 | chunk_count:u32
//!   = 2 + 2 + 8 + 8 + 4 + 4 = 28.
//! snapshot record는 `sequence=0`과 한 generation, delta record는 body에 `base_generation`을 더하고 sequence를 1씩
//! 올린다(§12). chunk_index는 0부터 연속이고 마지막 chunk의 count가 맞아야 상위가 publish한다.

const std = @import("std");

/// codec 버전. decode가 다른 값을 보면 `BadCodecVersion`(상위가 fresh snapshot 재요청).
pub const codec_version: u16 = 1;

/// record header 크기(바이트). body는 이 뒤에 이어진다.
pub const record_header_size = 28;

/// snapshot/delta record 종류. `enum(u16)` + `_`로 open enum — 모르는 값도 decode되어 상위가 optional/required로
/// 처리를 가른다(§12: unknown optional은 length로 skip, unknown required는 snapshot 전체 reject). 값은 wire 약속이라 고정.
/// snapshot record는 1~9, delta record는 10~19로 대역을 나눠 사람이 로그에서 구분하기 쉽게 한다.
pub const RecordKind = enum(u16) {
    // snapshot records (full screen 조립)
    screen_meta = 1,
    row = 2,
    image_placement = 3,
    image_blob = 4,
    // delta records (증분 변경)
    set_runs = 10,
    clear_rect = 11,
    scroll_rect = 12,
    cursor = 13,
    modes = 14,
    image_place = 15,
    image_remove = 16,
    _,

    pub fn isKnown(self: RecordKind) bool {
        return switch (self) {
            .screen_meta, .row, .image_placement, .image_blob, .set_runs, .clear_rect, .scroll_rect, .cursor, .modes, .image_place, .image_remove => true,
            _ => false,
        };
    }
};

/// resolved cell 스타일 비트(§12 "resolved ... style flags"). palette 참조가 아니라 이미 해석된 표현이다.
/// underline은 스타일 존재(single/double/curly)와 색(`underline_color`)을 분리한다.
pub const StyleFlags = struct {
    pub const bold: u32 = 1 << 0;
    pub const dim: u32 = 1 << 1;
    pub const italic: u32 = 1 << 2;
    pub const underline: u32 = 1 << 3;
    pub const underline_double: u32 = 1 << 4;
    pub const underline_curly: u32 = 1 << 5;
    pub const blink: u32 = 1 << 6;
    pub const inverse: u32 = 1 << 7;
    pub const invisible: u32 = 1 << 8;
    pub const strikethrough: u32 = 1 << 9;
    pub const overline: u32 = 1 << 10;
    pub const known_mask: u32 = (1 << 11) - 1;
};

/// 커서 상태. `shape`는 0=block,1=underline,2=bar(§ terminal DECSCUSR 관례) — 상위가 매핑한다.
pub const Cursor = struct {
    col: u16 = 0,
    row: u16 = 0,
    visible: bool = true,
    shape: u8 = 0,
};

/// 화면 좌표 사각형(cell 단위). delta clear/scroll/image 배치에 쓴다.
pub const Rect = struct {
    x: u16 = 0,
    y: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
};

/// 같은 스타일·같은 grapheme의 연속 묶음. `width`는 grapheme 셀 폭(1/2), `count`는 그 grapheme의 **반복 수**다.
/// 이 run이 채우는 grid cell 수 = `width * count`(wide "한" 하나면 width=2·count=1·cell=2, "aaa"면 width=1·count=3·cell=3).
/// 조립기는 Σ(width*count)==cols로 wide-cell continuation 불일치를 검증한다(rowWidthMatches). `grapheme`은 UTF-8이고
/// codec 버퍼를 참조한다(decode 후 caller가 버퍼를 유지하는 zero-copy). 색은 resolved RGB.
pub const Run = struct {
    grapheme: []const u8,
    width: u8 = 1,
    count: u32 = 1,
    fg: u32 = 0,
    bg: u32 = 0,
    underline_color: u32 = 0,
    style_flags: u32 = 0,
};

/// 화면 메타(snapshot의 첫 record). cols/rows·active/alternate screen·커서·mode bitmask.
/// wire: cols:u16 | rows:u16 | active_screen:u8 | cursor(col:u16,row:u16,visible:u8,shape:u8) | modes:u32.
pub const ScreenMeta = struct {
    cols: u16,
    rows: u16,
    active_screen: u8 = 0, // 0=primary, 1=alternate
    cursor: Cursor = .{},
    modes: u32 = 0,
};

/// 한 행의 run 목록. wire: row_index:u16 | run_count:u32 | run*. `runs`는 decode가 allocator로 소유(caller가 `deinit`).
pub const Row = struct {
    row_index: u16,
    runs: []Run,

    pub fn deinit(self: Row, allocator: std.mem.Allocator) void {
        allocator.free(self.runs);
    }
};

/// 화면 위 이미지 배치. wire: blob_id:u64 | rect(x,y,w,h:u16) | z:i32.
pub const ImagePlacement = struct {
    blob_id: u64,
    rect: Rect = .{},
    z: i32 = 0,
};

/// 이미지 원본 바이트(kitty/sixel 등). blob은 **문자열 field가 아니라** 전용 record로 나른다(§12). wire:
/// blob_id:u64 | mime(str) | byte_len:u32 | bytes.
pub const ImageBlob = struct {
    blob_id: u64,
    mime: []const u8,
    bytes: []const u8,
};

/// 28-byte record header. body는 record_kind에 따라 이 뒤에 이어진다.
pub const RecordHeader = struct {
    kind: RecordKind,
    generation: u64 = 0,
    sequence: u64 = 0,
    chunk_index: u32 = 0,
    chunk_count: u32 = 1,
    version: u16 = codec_version,

    pub fn encode(self: RecordHeader) [record_header_size]u8 {
        var buf: [record_header_size]u8 = undefined;
        std.mem.writeInt(u16, buf[0..2], self.version, .big);
        std.mem.writeInt(u16, buf[2..4], @intFromEnum(self.kind), .big);
        std.mem.writeInt(u64, buf[4..12], self.generation, .big);
        std.mem.writeInt(u64, buf[12..20], self.sequence, .big);
        std.mem.writeInt(u32, buf[20..24], self.chunk_index, .big);
        std.mem.writeInt(u32, buf[24..28], self.chunk_count, .big);
        return buf;
    }

    pub fn decode(bytes: *const [record_header_size]u8) DecodeError!RecordHeader {
        const version = std.mem.readInt(u16, bytes[0..2], .big);
        if (version != codec_version) return error.BadCodecVersion;
        return .{
            .version = version,
            .kind = @enumFromInt(std.mem.readInt(u16, bytes[2..4], .big)),
            .generation = std.mem.readInt(u64, bytes[4..12], .big),
            .sequence = std.mem.readInt(u64, bytes[12..20], .big),
            .chunk_index = std.mem.readInt(u32, bytes[20..24], .big),
            .chunk_count = std.mem.readInt(u32, bytes[24..28], .big),
        };
    }
};

pub const DecodeError = error{
    /// codec_version이 1이 아니다 — 상위가 fresh snapshot을 재요청한다.
    BadCodecVersion,
    /// body가 선언된 필드보다 짧다(truncated). 손상/부분 chunk.
    Truncated,
    /// str/blob length가 남은 바이트나 cap을 넘는다.
    LengthOverflow,
    /// grapheme/mime 문자열이 valid UTF-8이 아니다(§12: UTF-8 손상은 reject).
    InvalidUtf8,
    /// run count·row 등 선언 수가 cap을 넘는다(메모리 폭주 방지).
    TooManyItems,
    OutOfMemory,
};

/// str(grapheme·mime) length cap(바이트). 단일 grapheme·mime는 이보다 훨씬 작지만, 손상 length가 거대 alloc을 유발하지 않게 막는다.
pub const max_string_len: usize = 64 * 1024;
/// image_blob 원본 바이트 cap. grapheme/mime과 달리 kitty/sixel 이미지 원본은 수백 KiB라, str cap(64 KiB)이 아니라 단일
/// binary chunk 상한(1 MiB)에 맞춘다 — 64 KiB로 막으면 큰 인라인 이미지가 있는 화면을 재접속 시 직렬화하지 못한다.
/// screen_stream은 protocol을 import하지 않으므로 그 `max_binary_chunk`(1 MiB)를 자체 상수로 미러한다.
pub const max_image_blob: usize = 1024 * 1024;
/// 한 row의 run 수 cap. 폭 8K 화면도 8K run 미만이라 넉넉하며 손상 count를 막는다.
pub const max_runs_per_row: usize = 65536;

// ── primitive writer/reader ──────────────────────────────────────────────────

/// body를 big-endian으로 쌓는다. 문자열은 `length:u32 + UTF-8`. 실패는 OOM만(cap은 caller가 확인).
const BodyWriter = struct {
    buf: *std.ArrayListUnmanaged(u8),
    allocator: std.mem.Allocator,

    fn u8v(self: BodyWriter, v: u8) DecodeError!void {
        self.buf.append(self.allocator, v) catch return error.OutOfMemory;
    }
    fn u16v(self: BodyWriter, v: u16) DecodeError!void {
        var b: [2]u8 = undefined;
        std.mem.writeInt(u16, &b, v, .big);
        self.buf.appendSlice(self.allocator, &b) catch return error.OutOfMemory;
    }
    fn u32v(self: BodyWriter, v: u32) DecodeError!void {
        var b: [4]u8 = undefined;
        std.mem.writeInt(u32, &b, v, .big);
        self.buf.appendSlice(self.allocator, &b) catch return error.OutOfMemory;
    }
    fn i32v(self: BodyWriter, v: i32) DecodeError!void {
        return self.u32v(@bitCast(v));
    }
    fn u64v(self: BodyWriter, v: u64) DecodeError!void {
        var b: [8]u8 = undefined;
        std.mem.writeInt(u64, &b, v, .big);
        self.buf.appendSlice(self.allocator, &b) catch return error.OutOfMemory;
    }
    fn str(self: BodyWriter, s: []const u8) DecodeError!void {
        if (s.len > max_string_len) return error.LengthOverflow;
        try self.u32v(@intCast(s.len));
        self.buf.appendSlice(self.allocator, s) catch return error.OutOfMemory;
    }
    fn cursor(self: BodyWriter, c: Cursor) DecodeError!void {
        try self.u16v(c.col);
        try self.u16v(c.row);
        try self.u8v(@intFromBool(c.visible));
        try self.u8v(c.shape);
    }
    fn rect(self: BodyWriter, r: Rect) DecodeError!void {
        try self.u16v(r.x);
        try self.u16v(r.y);
        try self.u16v(r.w);
        try self.u16v(r.h);
    }
    fn run(self: BodyWriter, r: Run) DecodeError!void {
        try self.str(r.grapheme);
        try self.u8v(r.width);
        try self.u32v(r.count);
        try self.u32v(r.fg);
        try self.u32v(r.bg);
        try self.u32v(r.underline_color);
        try self.u32v(r.style_flags);
    }
};

/// body를 big-endian으로 읽는다. OOB는 `Truncated`. str은 codec 버퍼를 참조(zero-copy)하고 UTF-8을 검증한다.
const BodyReader = struct {
    bytes: []const u8,
    pos: usize = 0,

    fn need(self: *BodyReader, n: usize) DecodeError!void {
        if (self.pos + n > self.bytes.len) return error.Truncated;
    }
    fn u8v(self: *BodyReader) DecodeError!u8 {
        try self.need(1);
        defer self.pos += 1;
        return self.bytes[self.pos];
    }
    fn u16v(self: *BodyReader) DecodeError!u16 {
        try self.need(2);
        defer self.pos += 2;
        return std.mem.readInt(u16, self.bytes[self.pos..][0..2], .big);
    }
    fn u32v(self: *BodyReader) DecodeError!u32 {
        try self.need(4);
        defer self.pos += 4;
        return std.mem.readInt(u32, self.bytes[self.pos..][0..4], .big);
    }
    fn i32v(self: *BodyReader) DecodeError!i32 {
        return @bitCast(try self.u32v());
    }
    fn u64v(self: *BodyReader) DecodeError!u64 {
        try self.need(8);
        defer self.pos += 8;
        return std.mem.readInt(u64, self.bytes[self.pos..][0..8], .big);
    }
    /// UTF-8 검증된 문자열(codec 버퍼 참조). caller가 버퍼를 유지하는 동안만 유효하다.
    fn str(self: *BodyReader) DecodeError![]const u8 {
        const len = try self.u32v();
        if (len > max_string_len) return error.LengthOverflow;
        try self.need(len);
        const s = self.bytes[self.pos .. self.pos + len];
        if (!std.unicode.utf8ValidateSlice(s)) return error.InvalidUtf8;
        self.pos += len;
        return s;
    }
    /// 임의 바이트 blob(UTF-8 검증 안 함 — image 원본). length는 별도 u32. cap은 image 전용(1 MiB), str(64 KiB) 아님.
    fn bytesField(self: *BodyReader) DecodeError![]const u8 {
        const len = try self.u32v();
        if (len > max_image_blob) return error.LengthOverflow;
        try self.need(len);
        const s = self.bytes[self.pos .. self.pos + len];
        self.pos += len;
        return s;
    }
    fn cursor(self: *BodyReader) DecodeError!Cursor {
        return .{
            .col = try self.u16v(),
            .row = try self.u16v(),
            .visible = (try self.u8v()) != 0,
            .shape = try self.u8v(),
        };
    }
    fn rect(self: *BodyReader) DecodeError!Rect {
        return .{ .x = try self.u16v(), .y = try self.u16v(), .w = try self.u16v(), .h = try self.u16v() };
    }
    fn run(self: *BodyReader) DecodeError!Run {
        return .{
            .grapheme = try self.str(),
            .width = try self.u8v(),
            .count = try self.u32v(),
            .fg = try self.u32v(),
            .bg = try self.u32v(),
            .underline_color = try self.u32v(),
            .style_flags = try self.u32v(),
        };
    }
};

// ── snapshot record encode/decode ────────────────────────────────────────────

/// full record 하나(header + body)를 한 버퍼로 직렬화한다(caller 소유). `encodeScreenMeta`/`encodeRow` 등이 이 helper로 수렴한다.
fn finishRecord(allocator: std.mem.Allocator, header: RecordHeader, body: []const u8) DecodeError![]u8 {
    var out = allocator.alloc(u8, record_header_size + body.len) catch return error.OutOfMemory;
    @memcpy(out[0..record_header_size], &header.encode());
    @memcpy(out[record_header_size..], body);
    return out;
}

pub fn encodeScreenMeta(allocator: std.mem.Allocator, header: RecordHeader, meta: ScreenMeta) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(meta.cols);
    try w.u16v(meta.rows);
    try w.u8v(meta.active_screen);
    try w.cursor(meta.cursor);
    try w.u32v(meta.modes);
    return finishRecord(allocator, .{ .kind = .screen_meta, .generation = header.generation, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeScreenMeta(body: []const u8) DecodeError!ScreenMeta {
    var r = BodyReader{ .bytes = body };
    return .{
        .cols = try r.u16v(),
        .rows = try r.u16v(),
        .active_screen = try r.u8v(),
        .cursor = try r.cursor(),
        .modes = try r.u32v(),
    };
}

pub fn encodeRow(allocator: std.mem.Allocator, header: RecordHeader, row: Row) DecodeError![]u8 {
    if (row.runs.len > max_runs_per_row) return error.TooManyItems;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(row.row_index);
    try w.u32v(@intCast(row.runs.len));
    for (row.runs) |rn| try w.run(rn);
    return finishRecord(allocator, .{ .kind = .row, .generation = header.generation, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

/// row body를 decode한다. `runs`는 allocator 소유(caller가 `Row.deinit`). run 수 cap과 UTF-8을 검증한다.
pub fn decodeRow(allocator: std.mem.Allocator, body: []const u8) DecodeError!Row {
    var r = BodyReader{ .bytes = body };
    const row_index = try r.u16v();
    const count = try r.u32v();
    if (count > max_runs_per_row) return error.TooManyItems;
    const runs = allocator.alloc(Run, count) catch return error.OutOfMemory;
    errdefer allocator.free(runs);
    for (runs) |*slot| slot.* = try r.run();
    return .{ .row_index = row_index, .runs = runs };
}

/// 한 row의 run 폭 합이 `cols`와 정확히 맞는지 검증한다(§12: run이 row 폭을 넘거나 wide-cell continuation이 어긋나면
/// snapshot 전체 reject). 조립기(P3-c)가 `ScreenMeta.cols`로 각 row를 통과시킨다. codec의 row decode 자체는 cols를 몰라
/// 여기서 분리한다. width*count 누적이 cols를 넘으면 overflow, 부족하면 underfill이다.
pub fn rowWidthMatches(row: Row, cols: u16) bool {
    var total: usize = 0;
    for (row.runs) |rn| {
        total += @as(usize, rn.width) * @as(usize, rn.count);
        if (total > cols) return false; // wide cell이 경계를 넘음 = continuation 불일치
    }
    return total == cols;
}

pub fn encodeImagePlacement(allocator: std.mem.Allocator, header: RecordHeader, p: ImagePlacement) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(p.blob_id);
    try w.rect(p.rect);
    try w.i32v(p.z);
    return finishRecord(allocator, .{ .kind = header.kind, .generation = header.generation, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeImagePlacement(body: []const u8) DecodeError!ImagePlacement {
    var r = BodyReader{ .bytes = body };
    return .{ .blob_id = try r.u64v(), .rect = try r.rect(), .z = try r.i32v() };
}

pub fn encodeImageBlob(allocator: std.mem.Allocator, header: RecordHeader, blob: ImageBlob) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(blob.blob_id);
    try w.str(blob.mime);
    if (blob.bytes.len > max_image_blob) return error.LengthOverflow; // image 전용 cap(1 MiB) — str(64 KiB) 아님
    try w.u32v(@intCast(blob.bytes.len));
    body.appendSlice(allocator, blob.bytes) catch return error.OutOfMemory;
    return finishRecord(allocator, .{ .kind = .image_blob, .generation = header.generation, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeImageBlob(body: []const u8) DecodeError!ImageBlob {
    var r = BodyReader{ .bytes = body };
    return .{ .blob_id = try r.u64v(), .mime = try r.str(), .bytes = try r.bytesField() };
}

// ── delta record encode/decode ───────────────────────────────────────────────

/// set_runs: 한 행의 특정 컬럼부터 run들을 덮어쓴다. wire: base_generation:u64 | row_index:u16 | start_col:u16 | run_count:u32 | run*.
pub const SetRuns = struct {
    base_generation: u64,
    row_index: u16,
    start_col: u16,
    runs: []Run,

    pub fn deinit(self: SetRuns, allocator: std.mem.Allocator) void {
        allocator.free(self.runs);
    }
};

pub fn encodeSetRuns(allocator: std.mem.Allocator, header: RecordHeader, op: SetRuns) DecodeError![]u8 {
    if (op.runs.len > max_runs_per_row) return error.TooManyItems;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.u16v(op.row_index);
    try w.u16v(op.start_col);
    try w.u32v(@intCast(op.runs.len));
    for (op.runs) |rn| try w.run(rn);
    return finishRecord(allocator, .{ .kind = .set_runs, .generation = header.generation, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeSetRuns(allocator: std.mem.Allocator, body: []const u8) DecodeError!SetRuns {
    var r = BodyReader{ .bytes = body };
    const base_generation = try r.u64v();
    const row_index = try r.u16v();
    const start_col = try r.u16v();
    const count = try r.u32v();
    if (count > max_runs_per_row) return error.TooManyItems;
    const runs = allocator.alloc(Run, count) catch return error.OutOfMemory;
    errdefer allocator.free(runs);
    for (runs) |*slot| slot.* = try r.run();
    return .{ .base_generation = base_generation, .row_index = row_index, .start_col = start_col, .runs = runs };
}

/// scroll_rect: 사각형 안 내용을 `dy` 행만큼(양수=위로) 이동한다. wire: base_generation:u64 | rect | dy:i32.
pub const ScrollRect = struct { base_generation: u64, rect: Rect, dy: i32 };
/// clear_rect: 사각형을 default cell로 지운다. wire: base_generation:u64 | rect.
pub const ClearRect = struct { base_generation: u64, rect: Rect };

pub fn encodeScrollRect(allocator: std.mem.Allocator, header: RecordHeader, op: ScrollRect) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.rect(op.rect);
    try w.i32v(op.dy);
    return finishRecord(allocator, .{ .kind = .scroll_rect, .generation = header.generation, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeScrollRect(body: []const u8) DecodeError!ScrollRect {
    var r = BodyReader{ .bytes = body };
    return .{ .base_generation = try r.u64v(), .rect = try r.rect(), .dy = try r.i32v() };
}

pub fn encodeClearRect(allocator: std.mem.Allocator, header: RecordHeader, op: ClearRect) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.rect(op.rect);
    return finishRecord(allocator, .{ .kind = .clear_rect, .generation = header.generation, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeClearRect(body: []const u8) DecodeError!ClearRect {
    var r = BodyReader{ .bytes = body };
    return .{ .base_generation = try r.u64v(), .rect = try r.rect() };
}

/// cursor delta: 커서만 바꾼다. wire: base_generation:u64 | cursor.
pub const CursorDelta = struct { base_generation: u64, cursor: Cursor };
/// modes delta: mode bitmask만 바꾼다. wire: base_generation:u64 | modes:u32.
pub const ModesDelta = struct { base_generation: u64, modes: u32 };

pub fn encodeCursor(allocator: std.mem.Allocator, header: RecordHeader, op: CursorDelta) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.cursor(op.cursor);
    return finishRecord(allocator, .{ .kind = .cursor, .generation = header.generation, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeCursor(body: []const u8) DecodeError!CursorDelta {
    var r = BodyReader{ .bytes = body };
    return .{ .base_generation = try r.u64v(), .cursor = try r.cursor() };
}

pub fn encodeModes(allocator: std.mem.Allocator, header: RecordHeader, op: ModesDelta) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.u32v(op.modes);
    return finishRecord(allocator, .{ .kind = .modes, .generation = header.generation, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeModes(body: []const u8) DecodeError!ModesDelta {
    var r = BodyReader{ .bytes = body };
    return .{ .base_generation = try r.u64v(), .modes = try r.u32v() };
}

/// image_remove: 배치된 이미지를 지운다. wire: base_generation:u64 | blob_id:u64.
pub const ImageRemove = struct { base_generation: u64, blob_id: u64 };

pub fn encodeImageRemove(allocator: std.mem.Allocator, header: RecordHeader, op: ImageRemove) DecodeError![]u8 {
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u64v(op.base_generation);
    try w.u64v(op.blob_id);
    return finishRecord(allocator, .{ .kind = .image_remove, .generation = header.generation, .sequence = header.sequence, .chunk_index = header.chunk_index, .chunk_count = header.chunk_count }, body.items);
}

pub fn decodeImageRemove(body: []const u8) DecodeError!ImageRemove {
    var r = BodyReader{ .bytes = body };
    return .{ .base_generation = try r.u64v(), .blob_id = try r.u64v() };
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 재접속·다른 terminal attach는 host의 화면 상태를 이
// codec으로만 받는다. record 한 필드라도 어긋나면 재접속 첫 화면이 깨지거나 wide CJK/이미지가 밀린다. 28-byte
// header, resolved run(grapheme·width·count·색·style), 커서/rect/이미지, delta op, 그리고 row 폭 검증·UTF-8/truncation/
// cap 거부를 왕복으로 고정한다. 순수 codec이라 non-macOS에서 wire 회귀를 잡는다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "screen-stream: record header round-trips with 28-byte big-endian layout" {
    const h = RecordHeader{ .kind = .row, .generation = 0x1122334455667788, .sequence = 5, .chunk_index = 2, .chunk_count = 9 };
    const bytes = h.encode();
    try testing.expectEqual(@as(usize, 28), bytes.len);
    try testing.expectEqual(@as(u16, 1), std.mem.readInt(u16, bytes[0..2], .big)); // codec_version
    try testing.expectEqual(@as(u16, 2), std.mem.readInt(u16, bytes[2..4], .big)); // row=2
    const back = try RecordHeader.decode(&bytes);
    try testing.expectEqual(h.kind, back.kind);
    try testing.expectEqual(h.generation, back.generation);
    try testing.expectEqual(h.sequence, back.sequence);
    try testing.expectEqual(h.chunk_index, back.chunk_index);
    try testing.expectEqual(h.chunk_count, back.chunk_count);
}

test "screen-stream: header rejects a foreign codec version" {
    var bytes = (RecordHeader{ .kind = .screen_meta }).encode();
    std.mem.writeInt(u16, bytes[0..2], 2, .big);
    try testing.expectError(error.BadCodecVersion, RecordHeader.decode(&bytes));
}

test "screen-stream: record kind is an open enum for future records" {
    var bytes = (RecordHeader{ .kind = .row }).encode();
    std.mem.writeInt(u16, bytes[2..4], 9999, .big);
    const back = try RecordHeader.decode(&bytes);
    try testing.expect(!back.kind.isKnown()); // 상위가 optional/required로 처리
}

test "screen-stream: screen_meta round-trips through the full record" {
    const allocator = testing.allocator;
    const meta = ScreenMeta{ .cols = 120, .rows = 40, .active_screen = 1, .cursor = .{ .col = 10, .row = 3, .visible = false, .shape = 2 }, .modes = 0xDEAD };
    const rec = try encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 7 }, meta);
    defer allocator.free(rec);
    const header = try RecordHeader.decode(rec[0..record_header_size]);
    try testing.expectEqual(RecordKind.screen_meta, header.kind);
    try testing.expectEqual(@as(u64, 7), header.generation);
    const back = try decodeScreenMeta(rec[record_header_size..]);
    try testing.expectEqual(meta.cols, back.cols);
    try testing.expectEqual(meta.rows, back.rows);
    try testing.expectEqual(meta.active_screen, back.active_screen);
    try testing.expectEqual(meta.cursor.col, back.cursor.col);
    try testing.expectEqual(meta.cursor.visible, back.cursor.visible);
    try testing.expectEqual(meta.cursor.shape, back.cursor.shape);
    try testing.expectEqual(meta.modes, back.modes);
}

test "screen-stream: row of resolved runs round-trips including wide CJK" {
    const allocator = testing.allocator;
    var runs = [_]Run{
        .{ .grapheme = "a", .width = 1, .count = 3, .fg = 0xFF0000, .bg = 0x000000, .style_flags = StyleFlags.bold },
        .{ .grapheme = "한", .width = 2, .count = 1, .fg = 0x00FF00, .underline_color = 0x0000FF, .style_flags = StyleFlags.underline | StyleFlags.underline_curly },
    };
    const rec = try encodeRow(allocator, .{ .kind = .row, .generation = 1 }, .{ .row_index = 4, .runs = &runs });
    defer allocator.free(rec);
    const row = try decodeRow(allocator, rec[record_header_size..]);
    defer row.deinit(allocator);
    try testing.expectEqual(@as(u16, 4), row.row_index);
    try testing.expectEqual(@as(usize, 2), row.runs.len);
    try testing.expectEqualStrings("a", row.runs[0].grapheme);
    try testing.expectEqual(@as(u32, 3), row.runs[0].count);
    try testing.expectEqual(StyleFlags.bold, row.runs[0].style_flags);
    try testing.expectEqualStrings("한", row.runs[1].grapheme);
    try testing.expectEqual(@as(u8, 2), row.runs[1].width);
    try testing.expectEqual(@as(u32, 0x0000FF), row.runs[1].underline_color);
}

test "screen-stream: rowWidthMatches enforces cols and catches wide-cell continuation overflow" {
    // 폭 5: "a"(1x3) + "한"(2x1) = 3 + 2 = 5 → 정확히 맞음.
    var ok_runs = [_]Run{
        .{ .grapheme = "a", .width = 1, .count = 3 },
        .{ .grapheme = "한", .width = 2, .count = 1 },
    };
    try testing.expect(rowWidthMatches(.{ .row_index = 0, .runs = &ok_runs }, 5));
    try testing.expect(!rowWidthMatches(.{ .row_index = 0, .runs = &ok_runs }, 4)); // 넘침(continuation 불일치)
    try testing.expect(!rowWidthMatches(.{ .row_index = 0, .runs = &ok_runs }, 6)); // 부족(underfill)
    // wide cell이 폭 경계를 1칸 넘김: "한"(2x1)이 폭 1에 안 들어감.
    var wide = [_]Run{.{ .grapheme = "한", .width = 2, .count = 1 }};
    try testing.expect(!rowWidthMatches(.{ .row_index = 0, .runs = &wide }, 1));
}

test "screen-stream: decode rejects truncated body and invalid UTF-8 grapheme" {
    const allocator = testing.allocator;
    // truncated: screen_meta body를 잘라 낸다.
    try testing.expectError(error.Truncated, decodeScreenMeta(&[_]u8{ 0, 120 })); // cols만 있고 나머지 없음
    // invalid UTF-8 grapheme in a row run.
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(0); // row_index
    try w.u32v(1); // run_count
    try w.u32v(2); // grapheme len = 2
    try body.appendSlice(allocator, &[_]u8{ 0xFF, 0xFE }); // invalid UTF-8
    try testing.expectError(error.InvalidUtf8, decodeRow(allocator, body.items));
}

test "screen-stream: image blob carries opaque bytes without UTF-8 checks" {
    const allocator = testing.allocator;
    const blob = ImageBlob{ .blob_id = 42, .mime = "image/png", .bytes = &[_]u8{ 0x89, 0x50, 0x4E, 0x47, 0x00, 0xFF } };
    const rec = try encodeImageBlob(allocator, .{ .kind = .image_blob, .generation = 3 }, blob);
    defer allocator.free(rec);
    const back = try decodeImageBlob(rec[record_header_size..]);
    try testing.expectEqual(@as(u64, 42), back.blob_id);
    try testing.expectEqualStrings("image/png", back.mime);
    try testing.expectEqualSlices(u8, blob.bytes, back.bytes);
}

test "screen-stream: delta ops round-trip (set_runs, scroll_rect, clear_rect, cursor, modes, image)" {
    const allocator = testing.allocator;

    var runs = [_]Run{.{ .grapheme = "x", .width = 1, .count = 2, .fg = 0x123456 }};
    const sr = try encodeSetRuns(allocator, .{ .kind = .set_runs, .generation = 11, .sequence = 3 }, .{ .base_generation = 10, .row_index = 2, .start_col = 5, .runs = &runs });
    defer allocator.free(sr);
    {
        const h = try RecordHeader.decode(sr[0..record_header_size]);
        try testing.expectEqual(RecordKind.set_runs, h.kind);
        try testing.expectEqual(@as(u64, 3), h.sequence);
        const op = try decodeSetRuns(allocator, sr[record_header_size..]);
        defer op.deinit(allocator);
        try testing.expectEqual(@as(u64, 10), op.base_generation);
        try testing.expectEqual(@as(u16, 5), op.start_col);
        try testing.expectEqualStrings("x", op.runs[0].grapheme);
    }

    const sc = try encodeScrollRect(allocator, .{ .kind = .scroll_rect }, .{ .base_generation = 10, .rect = .{ .x = 0, .y = 1, .w = 80, .h = 20 }, .dy = -3 });
    defer allocator.free(sc);
    try testing.expectEqual(@as(i32, -3), (try decodeScrollRect(sc[record_header_size..])).dy);

    const cl = try encodeClearRect(allocator, .{ .kind = .clear_rect }, .{ .base_generation = 10, .rect = .{ .x = 2, .y = 2, .w = 4, .h = 1 } });
    defer allocator.free(cl);
    try testing.expectEqual(@as(u16, 4), (try decodeClearRect(cl[record_header_size..])).rect.w);

    const cu = try encodeCursor(allocator, .{ .kind = .cursor }, .{ .base_generation = 10, .cursor = .{ .col = 7, .row = 9, .visible = true, .shape = 1 } });
    defer allocator.free(cu);
    try testing.expectEqual(@as(u16, 7), (try decodeCursor(cu[record_header_size..])).cursor.col);

    const mo = try encodeModes(allocator, .{ .kind = .modes }, .{ .base_generation = 10, .modes = 0xBEEF });
    defer allocator.free(mo);
    try testing.expectEqual(@as(u32, 0xBEEF), (try decodeModes(mo[record_header_size..])).modes);

    const ip = try encodeImagePlacement(allocator, .{ .kind = .image_place }, .{ .blob_id = 5, .rect = .{ .x = 1, .y = 1, .w = 10, .h = 5 }, .z = 2 });
    defer allocator.free(ip);
    try testing.expectEqual(@as(u64, 5), (try decodeImagePlacement(ip[record_header_size..])).blob_id);

    const ir = try encodeImageRemove(allocator, .{ .kind = .image_remove }, .{ .base_generation = 10, .blob_id = 5 });
    defer allocator.free(ir);
    try testing.expectEqual(@as(u64, 5), (try decodeImageRemove(ir[record_header_size..])).blob_id);
}

test "screen-stream: run count cap rejects a corrupt declared count before allocating" {
    const allocator = testing.allocator;
    var body: std.ArrayListUnmanaged(u8) = .empty;
    defer body.deinit(allocator);
    const w = BodyWriter{ .buf = &body, .allocator = allocator };
    try w.u16v(0); // row_index
    try w.u32v(@intCast(max_runs_per_row + 1)); // 손상된 거대 run_count
    try testing.expectError(error.TooManyItems, decodeRow(allocator, body.items));
}
