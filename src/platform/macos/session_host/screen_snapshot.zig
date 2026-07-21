//! screen_snapshot — 실 `TerminalCore` 화면을 §12 `maru.screen-stream.v1` snapshot 레코드 스트림으로 투영한다(P3-e2d).
//!
//! `screen_stream.zig`는 snapshot/delta 레코드의 **codec**(바이트 ↔ 구조체)만 갖는다 — 그 레코드를 실제 화면에서
//! **만들어 내는** 투영기(조립기)는 여기다. host가 client attach에 첫 snapshot을 보낼 때(P3-e2d-2) 이 투영기로 현재
//! 화면을 레코드 스트림으로 바꾸고, 그 바이트를 `snapshot_chunk` MRSH frame으로 나눠 흘려 보낸다.
//!
//! 왜 별도 파일인가(레이어): 투영은 `maru.terminal`(TerminalCore/Cell/Style/Color)을 읽어야 하므로 `@import("maru")`가
//! 필요하다. 그래서 codec 순수 계층(screen_stream 등, platform-import-0)과 달리 이 파일은 macOS 전용(barrel 조건부)이고,
//! app 스택을 재사용하는 `runtime_manager`와 같은 부류다. 투영 자체는 OS 중립 순수 로직(syscall 없음)이라 실 core만 있으면
//! 테스트한다. §8 ANSI CLI client도 같은 중립 레코드를 소비하므로(새 parser 금지) 이 투영이 그 단일 출처다.
//!
//! 색 해석: 이 슬라이스는 config-light 기준선이다 — `.rgb`는 그대로, `.indexed`는 OSC4 override(`paletteOverride`) →
//! `xterm256` fallback, `.default`는 caller가 준 theme 기본 fg/bg로 푼다. reverse/dim/blink/conceal은 RGB에 **굽지 않고**
//! `StyleFlags`(inverse/dim/blink/invisible)로 실어 client 표시층이 적용한다(§9 표시 정책은 client). 완전한 theme-aware
//! 해석(config 16색 base·min-contrast·bold-is-bright·unfocused dim)은 config 배선이 붙는 후속(e2d-2/e3)에서 얹는다.
//!
//! 동시성: 이 투영은 순수 함수다(입력 `*const TerminalCore` → 소유 바이트). reader 스레드가 core를 쓰는 host 경로에선
//! **caller가 `Surface.core_mutex`를 잡은 채** 이 함수를 부르고(투영 동안 lock 유지, ~0.12ms), 반환된 소유 바이트만
//! unlock 뒤 전송한다(docs/io-render-threading.md — snapshot 슬라이스는 core 메모리 alias라 lock 밖으로 새면 안 됨).
//! 이 함수는 grapheme·색을 전부 소유 버퍼로 복사하므로 반환값은 core와 독립이다.

const std = @import("std");
const maru = @import("maru");
const terminal = maru.terminal;
const color = maru.color;
const screen_stream = @import("screen_stream.zig");
const screen_assembler = @import("screen_assembler.zig");

const Run = screen_stream.Run;

/// `ScreenMeta.modes` 비트 배치(§9 mode bitmask). core에 단일 u32 mode가 없어 개별 필드를 여기서 조립한다. 값은 wire
/// 약속이라 고정 — client가 같은 비트로 해석한다(예: app_cursor_keys면 화살표를 SS3로 인코딩).
pub const ModeBit = struct {
    pub const app_cursor_keys: u32 = 1 << 0; // DECCKM
    pub const app_keypad: u32 = 1 << 1; // DECKPAM
    pub const bracketed_paste: u32 = 1 << 2; // DECSET 2004
    pub const alternate_scroll: u32 = 1 << 3; // DECSET 1007
    pub const focus_events: u32 = 1 << 4; // DECSET 1004
    pub const origin_mode: u32 = 1 << 5; // DECOM
    pub const mouse_tracking: u32 = 1 << 6; // mouse_tracking != .none
    pub const sync_output: u32 = 1 << 7; // DECSET 2026
    pub const grapheme_cluster: u32 = 1 << 8; // DECSET 2027
};

/// 투영 정책. `generation`은 이 snapshot의 base generation(client가 이후 delta의 base로 대조 — 보통 runtime의 resize
/// generation 등 host가 정한 단조 값). `default_fg`/`default_bg`는 `.default` 색을 풀 theme 기본값(0x00RRGGBB).
pub const ProjectOptions = struct {
    generation: u64 = 0,
    default_fg: u32 = 0xFFFFFF,
    default_bg: u32 = 0x000000,
};

/// 현재 화면을 length-prefixed 레코드 스트림(screen_meta + row*)으로 투영한다(caller 소유 바이트). client는 이 바이트를
/// `screen_stream.RecordStream`으로 순회해 화면을 조립한다. **동시 core 쓰기가 있으면 caller가 core lock을 잡고 부른다.**
pub fn projectSnapshot(allocator: std.mem.Allocator, core: *const terminal.TerminalCore, opts: ProjectOptions) screen_stream.DecodeError![]u8 {
    const snap = core.snapshot();
    const palette = core.paletteOverride();

    var stream: std.ArrayListUnmanaged(u8) = .empty;
    errdefer stream.deinit(allocator);

    // screen_meta 레코드(snapshot의 첫 레코드).
    const meta = screen_stream.ScreenMeta{
        .cols = snap.size.cols,
        .rows = snap.size.rows,
        .active_screen = if (core.alt_active) 1 else 0,
        .cursor = .{
            .col = snap.cursor.col,
            .row = snap.cursor.row,
            .visible = snap.cursor.visible,
            .shape = @intFromEnum(snap.cursor_shape),
        },
        .modes = composeModes(core),
    };
    const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = opts.generation }, meta);
    defer allocator.free(meta_rec);
    try screen_stream.appendRecord(&stream, allocator, meta_rec);

    // 각 행을 run으로 압축해 row 레코드로 담는다.
    var row: u16 = 0;
    while (row < snap.size.rows) : (row += 1) {
        try appendRowRecord(allocator, snap, palette, opts, row, &stream);
    }
    return stream.toOwnedSlice(allocator) catch return error.OutOfMemory;
}

/// core의 개별 mode 필드를 §9 mode bitmask로 조립한다.
pub fn composeModes(core: *const terminal.TerminalCore) u32 {
    var m: u32 = 0;
    if (core.application_cursor_keys) m |= ModeBit.app_cursor_keys;
    if (core.application_keypad) m |= ModeBit.app_keypad;
    if (core.bracketed_paste) m |= ModeBit.bracketed_paste;
    if (core.alternate_scroll) m |= ModeBit.alternate_scroll;
    if (core.focus_events) m |= ModeBit.focus_events;
    if (core.origin_mode) m |= ModeBit.origin_mode;
    if (core.mouse_tracking != .none) m |= ModeBit.mouse_tracking;
    if (core.sync_output) m |= ModeBit.sync_output;
    if (core.grapheme_cluster_mode) m |= ModeBit.grapheme_cluster;
    return m;
}

/// 임시 run(grapheme는 pool 오프셋으로 참조 — pool realloc이 슬라이스를 무효화하지 않게 offset/len으로 든다).
const RunTmp = struct { g_off: usize, g_len: usize, width: u8, count: u32, fg: u32, bg: u32, ul: u32, flags: u32 };

/// 한 행의 runs(소유 — grapheme는 pool을 참조). caller가 `deinit`으로 runs 슬라이스와 grapheme pool을 함께 해제한다.
/// snapshot(encodeRow)과 delta(runsEqual 비교 + encodeSetRuns) 둘 다 이 빌더를 재사용해 같은 압축 규칙을 공유한다.
const RowRuns = struct {
    runs: []Run,
    pool: []u8,
    fn deinit(self: RowRuns, allocator: std.mem.Allocator) void {
        allocator.free(self.runs);
        allocator.free(self.pool);
    }
};

/// 한 행 셀을 RLE run으로 압축해 소유 `RowRuns`를 만든다(wide=width2·continuation 생략·resolved RGB·StyleFlags).
fn buildRowRuns(
    allocator: std.mem.Allocator,
    snap: terminal.RenderSnapshot,
    palette: *const [256]?terminal.Rgb,
    opts: ProjectOptions,
    row: u16,
) screen_stream.DecodeError!RowRuns {
    const cols = snap.size.cols;
    var tmp: std.ArrayListUnmanaged(RunTmp) = .empty;
    defer tmp.deinit(allocator);
    var pool: std.ArrayListUnmanaged(u8) = .empty; // run별 grapheme 바이트 풀(offset으로 참조).
    errdefer pool.deinit(allocator);
    var cur: std.ArrayListUnmanaged(u8) = .empty; // 현재 셀 grapheme 임시(coalesce 비교용).
    defer cur.deinit(allocator);

    const base = @as(usize, row) * cols;
    var col: usize = 0;
    while (col < cols) {
        const cell = snap.cells[base + col];
        if (cell.continuation) { // wide glyph의 2번째 셀 — 앞선 width=2 run이 이미 덮는다.
            col += 1;
            continue;
        }
        const width: u8 = if (cell.width >= 2) 2 else 1;
        try encodeCellGrapheme(&cur, allocator, cell, snap.graphemes);
        const fg = resolveColor(cell.style.foreground, opts.default_fg, palette);
        const bg = resolveColor(cell.style.background, opts.default_bg, palette);
        const ul = resolveColor(cell.style.underline_color, fg, palette); // default 밑줄색 = 전경색.
        const flags = styleFlags(cell.style);

        // 직전 run과 grapheme·width·색·스타일이 모두 같으면 count만 늘린다(RLE — 공백/반복 문자 압축).
        if (tmp.items.len > 0) {
            const last = &tmp.items[tmp.items.len - 1];
            if (last.width == width and last.fg == fg and last.bg == bg and last.ul == ul and last.flags == flags and
                std.mem.eql(u8, pool.items[last.g_off..][0..last.g_len], cur.items))
            {
                last.count += 1;
                col += width;
                continue;
            }
        }
        const g_off = pool.items.len;
        pool.appendSlice(allocator, cur.items) catch return error.OutOfMemory;
        tmp.append(allocator, .{ .g_off = g_off, .g_len = cur.items.len, .width = width, .count = 1, .fg = fg, .bg = bg, .ul = ul, .flags = flags }) catch return error.OutOfMemory;
        col += width;
    }

    // pool을 소유 슬라이스로 확정한 뒤 RunTmp를 실 Run으로 실체화한다(grapheme = 안정 pool 슬라이스).
    const runs = allocator.alloc(Run, tmp.items.len) catch return error.OutOfMemory;
    errdefer allocator.free(runs);
    const pool_slice = pool.toOwnedSlice(allocator) catch return error.OutOfMemory;
    for (tmp.items, 0..) |t, i| {
        runs[i] = .{ .grapheme = pool_slice[t.g_off..][0..t.g_len], .width = t.width, .count = t.count, .fg = t.fg, .bg = t.bg, .underline_color = t.ul, .style_flags = t.flags };
    }
    return .{ .runs = runs, .pool = pool_slice };
}

fn appendRowRecord(
    allocator: std.mem.Allocator,
    snap: terminal.RenderSnapshot,
    palette: *const [256]?terminal.Rgb,
    opts: ProjectOptions,
    row: u16,
    stream: *std.ArrayListUnmanaged(u8),
) screen_stream.DecodeError!void {
    const rr = try buildRowRuns(allocator, snap, palette, opts, row);
    defer rr.deinit(allocator);
    const rec = try screen_stream.encodeRow(allocator, .{ .kind = .row, .generation = opts.generation }, .{ .row_index = row, .runs = rr.runs });
    defer allocator.free(rec);
    try screen_stream.appendRecord(stream, allocator, rec);
}

/// 두 run 목록이 같은가(같은 grapheme·width·count·색·스타일). delta가 바뀐 행만 골라내는 비교 기준이다.
fn runsEqual(a: []const Run, b: []const Run) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x.width != y.width or x.count != y.count or x.fg != y.fg or x.bg != y.bg or
            x.underline_color != y.underline_color or x.style_flags != y.style_flags or
            !std.mem.eql(u8, x.grapheme, y.grapheme)) return false;
    }
    return true;
}

fn cursorsEqual(a: screen_stream.Cursor, b: screen_stream.Cursor) bool {
    return a.col == b.col and a.row == b.row and a.visible == b.visible and a.shape == b.shape;
}

pub const DeltaError = screen_stream.DecodeError || error{
    /// grid 크기나 alt-screen이 바뀌어 delta로 표현할 수 없다 — caller가 fresh snapshot을 보내야 한다(§9). delta는
    /// 같은 grid 위 증분(set_runs/cursor/modes)만 담는다.
    SnapshotRequired,
};

/// `computeDelta` 결과. `delta`는 바뀐 것만(빈 스트림 가능), `snapshot`은 현재 full snapshot(다음 base이자 render용).
/// **같은 row build 한 번에서** 둘 다 도출한다(재투영 없음). 둘 다 caller 소유이고 별개 버퍼다.
pub const DeltaResult = struct {
    delta: []u8,
    snapshot: []u8,

    pub fn deinit(self: DeltaResult, allocator: std.mem.Allocator) void {
        allocator.free(self.delta);
        allocator.free(self.snapshot);
    }
};

/// 이전 snapshot(`projectSnapshot`이 낸 record 바이트)과 현재 화면을 비교해 `delta`(바뀐 것만: `set_runs` 전체 행·`cursor`·
/// `modes`)와 `snapshot`(현재 full snapshot)을 **한 번의 row build로** 함께 만든다(caller 소유, length-prefixed). 안 바뀌면
/// delta는 빈 스트림. grid 크기/alt-screen이 바뀌면 `error.SnapshotRequired`(delta 불가 — caller가 fresh snapshot 전송).
/// **동시 core 쓰기가 있으면 caller가 core lock을 잡고 부른다**(`projectSnapshot`과 동일). base_generation은 `opts.generation`.
pub fn computeDelta(allocator: std.mem.Allocator, prev_bytes: []const u8, core: *const terminal.TerminalCore, opts: ProjectOptions) DeltaError!DeltaResult {
    // 이전 snapshot을 decode한다: screen_meta + rows.
    var rs = screen_stream.RecordStream{ .bytes = prev_bytes };
    const first = (try rs.next()) orelse return error.SnapshotRequired; // 빈 prev면 delta base가 없다.
    const fs = try screen_stream.RecordStream.split(first);
    if (fs.header.kind != .screen_meta) return error.SnapshotRequired;
    const prev_meta = try screen_stream.decodeScreenMeta(fs.body);

    const prev_rows = allocator.alloc(?[]Run, prev_meta.rows) catch return error.OutOfMemory;
    @memset(prev_rows, null);
    defer {
        for (prev_rows) |maybe| if (maybe) |r| allocator.free(r);
        allocator.free(prev_rows);
    }
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        if (s.header.kind != .row) continue; // 현재 투영은 row만 내지만, 미래 image record 등은 delta 비교에서 건너뛴다.
        const dr = try screen_stream.decodeRow(allocator, s.body);
        if (dr.row_index < prev_meta.rows) {
            if (prev_rows[dr.row_index]) |old| allocator.free(old); // 중복 row_index 방어.
            prev_rows[dr.row_index] = dr.runs;
        } else {
            dr.deinit(allocator);
        }
    }

    // 현재 화면을 읽는다. grid/alt-screen이 바뀌면 delta로는 못 잇는다 → fresh snapshot 필요.
    const snap = core.snapshot();
    const palette = core.paletteOverride();
    const cur_active: u8 = if (core.alt_active) 1 else 0;
    const cur_modes = composeModes(core);
    if (snap.size.cols != prev_meta.cols or snap.size.rows != prev_meta.rows or cur_active != prev_meta.active_screen) {
        return error.SnapshotRequired;
    }

    var delta: std.ArrayListUnmanaged(u8) = .empty;
    errdefer delta.deinit(allocator);
    var snapshot: std.ArrayListUnmanaged(u8) = .empty;
    errdefer snapshot.deinit(allocator);

    // snapshot의 screen_meta(현재 커서/모드) — projectSnapshot과 같은 첫 레코드.
    const cur_cursor = screen_stream.Cursor{ .col = snap.cursor.col, .row = snap.cursor.row, .visible = snap.cursor.visible, .shape = @intFromEnum(snap.cursor_shape) };
    {
        const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = opts.generation }, .{
            .cols = snap.size.cols,
            .rows = snap.size.rows,
            .active_screen = cur_active,
            .cursor = cur_cursor,
            .modes = cur_modes,
        });
        defer allocator.free(meta_rec);
        try screen_stream.appendRecord(&snapshot, allocator, meta_rec);
    }

    // 각 행을 **한 번만** build해서 (a) snapshot의 row 레코드로 담고 (b) prev와 다르면 delta의 set_runs로 담는다(재투영 제거).
    var row: u16 = 0;
    while (row < snap.size.rows) : (row += 1) {
        const rr = try buildRowRuns(allocator, snap, palette, opts, row);
        defer rr.deinit(allocator);
        const row_rec = try screen_stream.encodeRow(allocator, .{ .kind = .row, .generation = opts.generation }, .{ .row_index = row, .runs = rr.runs });
        defer allocator.free(row_rec);
        try screen_stream.appendRecord(&snapshot, allocator, row_rec);

        const prev = prev_rows[row] orelse &[_]Run{};
        if (!runsEqual(rr.runs, prev)) {
            const rec = try screen_stream.encodeSetRuns(allocator, .{ .kind = .set_runs, .generation = opts.generation }, .{ .base_generation = opts.generation, .row_index = row, .start_col = 0, .runs = rr.runs });
            defer allocator.free(rec);
            try screen_stream.appendRecord(&delta, allocator, rec);
        }
    }

    // 커서/모드 변화 → delta.
    if (!cursorsEqual(cur_cursor, prev_meta.cursor)) {
        const rec = try screen_stream.encodeCursor(allocator, .{ .kind = .cursor, .generation = opts.generation }, .{ .base_generation = opts.generation, .cursor = cur_cursor });
        defer allocator.free(rec);
        try screen_stream.appendRecord(&delta, allocator, rec);
    }
    if (cur_modes != prev_meta.modes) {
        const rec = try screen_stream.encodeModes(allocator, .{ .kind = .modes, .generation = opts.generation }, .{ .base_generation = opts.generation, .modes = cur_modes });
        defer allocator.free(rec);
        try screen_stream.appendRecord(&delta, allocator, rec);
    }

    const delta_owned = delta.toOwnedSlice(allocator) catch return error.OutOfMemory;
    errdefer allocator.free(delta_owned);
    const snapshot_owned = snapshot.toOwnedSlice(allocator) catch return error.OutOfMemory;
    return .{ .delta = delta_owned, .snapshot = snapshot_owned };
}

/// 셀의 표시 grapheme을 UTF-8로 만든다(base codepoint + grapheme_store cluster 본체). 빈 셀(codepoint 0)은 공백.
fn encodeCellGrapheme(cur: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, cell: terminal.Cell, graphemes: []const []const u21) screen_stream.DecodeError!void {
    cur.clearRetainingCapacity();
    const base_cp: u21 = if (cell.codepoint == 0) ' ' else cell.codepoint;
    try appendUtf8(cur, allocator, base_cp);
    if (cell.grapheme_id != 0 and cell.grapheme_id <= graphemes.len) {
        for (graphemes[cell.grapheme_id - 1]) |extra| try appendUtf8(cur, allocator, extra);
    }
}

fn appendUtf8(cur: *std.ArrayListUnmanaged(u8), allocator: std.mem.Allocator, cp: u21) screen_stream.DecodeError!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        cur.appendSlice(allocator, "\u{FFFD}") catch return error.OutOfMemory; // surrogate 등 잘못된 코드포인트 → U+FFFD
        return;
    };
    cur.appendSlice(allocator, buf[0..n]) catch return error.OutOfMemory;
}

/// terminal 색을 resolved 0x00RRGGBB로 푼다. `.default`는 caller theme 기본값, `.indexed`는 OSC4 override → xterm256.
fn resolveColor(c: terminal.Color, default_rgb: u32, palette: *const [256]?terminal.Rgb) u32 {
    return switch (c) {
        .default => default_rgb,
        .rgb => |v| packRgb(v),
        .indexed => |n| if (palette[n]) |ov| packRgb(ov) else packRgb(color.xterm256(n)),
    };
}

fn packRgb(v: terminal.Rgb) u32 {
    return (@as(u32, v.r) << 16) | (@as(u32, v.g) << 8) | @as(u32, v.b);
}

/// core `Style`을 `screen_stream.StyleFlags` 비트로 옮긴다. reverse→inverse, conceal→invisible. (core Style엔 curly
/// underline이 없어 그 비트는 안 켠다.)
fn styleFlags(s: terminal.Style) u32 {
    const SF = screen_stream.StyleFlags;
    var f: u32 = 0;
    if (s.bold) f |= SF.bold;
    if (s.dim) f |= SF.dim;
    if (s.italic) f |= SF.italic;
    if (s.underline) f |= SF.underline;
    if (s.underline_double) f |= SF.underline_double;
    if (s.blink) f |= SF.blink;
    if (s.reverse) f |= SF.inverse;
    if (s.conceal) f |= SF.invisible;
    if (s.strikethrough) f |= SF.strikethrough;
    if (s.overline) f |= SF.overline;
    return f;
}

// ─────────────────────────────────────────────────────────────────────────────
// 투영 단위 테스트 (실 TerminalCore)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 재접속·`maru attach`는 host의 화면을 client가 **똑같이**
// 재구성할 수 있어야 성립한다(§8 — raw PTY를 중간부터 못 주므로 versioned snapshot을 투영한다). 실제 ANSI를 먹인
// TerminalCore를 snapshot 레코드로 투영하고 다시 decode해, 텍스트·resolved 색·wide cell·커서·mode가 원본 화면과
// 일치하는지 고정한다. 순수 투영이라 실 PTY 없이 core만으로 macOS에서 검증한다(barrel이 non-macOS에서 제외).
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

/// 투영 스트림을 decode해 (meta, rows)로 되돌리는 테스트 helper. rows[i]는 row_index i의 runs다(caller가 deinit).
const Decoded = struct {
    meta: screen_stream.ScreenMeta,
    rows: []screen_stream.Row,

    fn deinit(self: Decoded, allocator: std.mem.Allocator) void {
        for (self.rows) |r| r.deinit(allocator);
        allocator.free(self.rows);
    }
};

fn decodeSnapshot(allocator: std.mem.Allocator, bytes: []const u8) !Decoded {
    var rs = screen_stream.RecordStream{ .bytes = bytes };
    const first = (try rs.next()).?;
    const fs = try screen_stream.RecordStream.split(first);
    try testing.expectEqual(screen_stream.RecordKind.screen_meta, fs.header.kind);
    const meta = try screen_stream.decodeScreenMeta(fs.body);

    var rows: std.ArrayListUnmanaged(screen_stream.Row) = .empty;
    errdefer {
        for (rows.items) |r| r.deinit(allocator);
        rows.deinit(allocator);
    }
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        try testing.expectEqual(screen_stream.RecordKind.row, s.header.kind);
        const dr = try screen_stream.decodeRow(allocator, s.body);
        try rows.append(allocator, dr);
    }
    return .{ .meta = meta, .rows = try rows.toOwnedSlice(allocator) };
}

test "screen snapshot: projects a real TerminalCore screen to decodable records (text, color, cursor)" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();

    // 빨간 전경으로 "hi", 커서는 그 뒤.
    try core.write("\x1b[31mhi\x1b[0m");

    const bytes = try projectSnapshot(allocator, &core, .{ .generation = 7, .default_fg = 0xCCCCCC, .default_bg = 0x101010 });
    defer allocator.free(bytes);

    const dec = try decodeSnapshot(allocator, bytes);
    defer dec.deinit(allocator);

    // meta: 크기·generation·커서 col(2, "hi" 뒤).
    try testing.expectEqual(@as(u16, 10), dec.meta.cols);
    try testing.expectEqual(@as(u16, 3), dec.meta.rows);
    try testing.expectEqual(@as(usize, 3), dec.rows.len);
    try testing.expectEqual(@as(u16, 2), dec.meta.cursor.col);

    // row 0: 첫 run "h"는 빨강(indexed 1 → xterm256 → 0x00RRGGBB, non-zero). 각 행은 Σ(width*count)==cols.
    const row0 = dec.rows[0];
    try testing.expect(screen_stream.rowWidthMatches(row0, 10));
    try testing.expectEqualStrings("h", row0.runs[0].grapheme);
    try testing.expect(row0.runs[0].fg != 0xCCCCCC); // 빨강이 default_fg가 아니게 풀렸다.
    // 마지막 run은 공백(default fg/bg)이고 RLE로 뭉쳐 있다.
    const last = row0.runs[row0.runs.len - 1];
    try testing.expectEqualStrings(" ", last.grapheme);
    try testing.expectEqual(@as(u32, 0xCCCCCC), last.fg);
    try testing.expectEqual(@as(u32, 0x101010), last.bg);
    // 빈 행(row 1,2)은 공백 한 run(count=cols)으로 압축된다.
    try testing.expectEqual(@as(usize, 1), dec.rows[1].runs.len);
    try testing.expectEqual(@as(u32, 10), dec.rows[1].runs[0].count);
}

test "screen snapshot: wide CJK cell projects width=2 and skips the continuation cell" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 6, .rows = 1 });
    defer core.deinit();
    try core.write("한A"); // 한=wide(2셀), A=narrow(1셀) → 3 cell 소비, 3칸 공백.

    const bytes = try projectSnapshot(allocator, &core, .{});
    defer allocator.free(bytes);
    const dec = try decodeSnapshot(allocator, bytes);
    defer dec.deinit(allocator);

    const row = dec.rows[0];
    try testing.expect(screen_stream.rowWidthMatches(row, 6)); // Σ(width*count)=6 — 연속 검증 통과.
    try testing.expectEqualStrings("한", row.runs[0].grapheme);
    try testing.expectEqual(@as(u8, 2), row.runs[0].width); // wide는 width=2, continuation은 run으로 안 나온다.
    try testing.expectEqualStrings("A", row.runs[1].grapheme);
    try testing.expectEqual(@as(u8, 1), row.runs[1].width);
}

test "screen snapshot: style flags and alt-screen/modes are captured" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();
    // bold+underline "B", 그리고 bracketed paste 모드 on(DECSET 2004), 대체 화면 전환(1049).
    try core.write("\x1b[1;4mB\x1b[0m");
    try core.write("\x1b[?2004h");

    // 대체 화면 전 modes/flag 확인.
    {
        const bytes = try projectSnapshot(allocator, &core, .{});
        defer allocator.free(bytes);
        const dec = try decodeSnapshot(allocator, bytes);
        defer dec.deinit(allocator);
        const SF = screen_stream.StyleFlags;
        const r0 = dec.rows[0].runs[0];
        try testing.expect((r0.style_flags & SF.bold) != 0 and (r0.style_flags & SF.underline) != 0);
        try testing.expect((dec.meta.modes & ModeBit.bracketed_paste) != 0);
        try testing.expectEqual(@as(u8, 0), dec.meta.active_screen); // 아직 primary.
    }

    try core.write("\x1b[?1049h"); // 대체 화면 진입.
    {
        const bytes = try projectSnapshot(allocator, &core, .{});
        defer allocator.free(bytes);
        const dec = try decodeSnapshot(allocator, bytes);
        defer dec.deinit(allocator);
        try testing.expectEqual(@as(u8, 1), dec.meta.active_screen); // alternate.
    }
}

test "screen snapshot: computeDelta emits set_runs for changed rows and a cursor delta" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    try core.write("hi"); // row0="hi", cursor (row0,col2).
    const a = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(a);

    try core.write("\r\nworld"); // row1="world", cursor (row1,col5). row0은 그대로.
    const result = try computeDelta(allocator, a, &core, .{ .generation = 1 });
    defer result.deinit(allocator);
    const delta = result.delta;
    try testing.expect(delta.len > 0);

    var rs = screen_stream.RecordStream{ .bytes = delta };
    var saw_row0 = false;
    var saw_row1 = false;
    var saw_cursor = false;
    while (try rs.next()) |rec| {
        const s = try screen_stream.RecordStream.split(rec);
        switch (s.header.kind) {
            .set_runs => {
                const sr = try screen_stream.decodeSetRuns(allocator, s.body);
                defer sr.deinit(allocator);
                if (sr.row_index == 0) saw_row0 = true;
                if (sr.row_index == 1) {
                    saw_row1 = true;
                    try testing.expectEqual(@as(u16, 0), sr.start_col); // 전체 행 교체.
                    try testing.expectEqualStrings("w", sr.runs[0].grapheme);
                }
            },
            .cursor => {
                const cd = try screen_stream.decodeCursor(s.body);
                saw_cursor = true;
                try testing.expectEqual(@as(u16, 1), cd.cursor.row);
                try testing.expectEqual(@as(u16, 5), cd.cursor.col);
            },
            else => {},
        }
    }
    try testing.expect(saw_row1 and saw_cursor);
    try testing.expect(!saw_row0); // row0은 안 바뀌어 set_runs를 내지 않는다(증분만).
}

test "screen snapshot: computeDelta is empty when the screen is unchanged" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("abc");
    const a = try projectSnapshot(allocator, &core, .{ .generation = 3 });
    defer allocator.free(a);
    const result = try computeDelta(allocator, a, &core, .{ .generation = 3 });
    defer result.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), result.delta.len); // 변화 없음 → 빈 delta(caller는 아무것도 안 보낸다).
}

test "screen snapshot: computeDelta requires a fresh snapshot when the grid geometry changes" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 3 });
    defer core.deinit();
    try core.write("resize me");
    const a = try projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(a);

    try core.resize(20, 5); // grid가 바뀌면 delta로는 못 잇는다.
    try testing.expectError(error.SnapshotRequired, computeDelta(allocator, a, &core, .{ .generation = 2 }));
}

test "screen snapshot: projection and assembler are inverses on a real screen (snapshot + delta round-trip)" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 3 });
    defer core.deinit();
    try core.write("\x1b[32mgreen\x1b[0m"); // row0 = 초록 "green".

    // project → assemble → re-serialize == projection(조립기가 화면을 무손실 재구성).
    const p = try projectSnapshot(allocator, &core, .{ .generation = 4 });
    defer allocator.free(p);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(p);
    {
        const re = try asm_.toSnapshot(allocator);
        defer allocator.free(re);
        try testing.expectEqualSlices(u8, p, re);
    }

    // 화면을 바꾸고 delta를 계산해 조립기에 적용하면, 새 projection과 같아진다(증분 재구성).
    try core.write("\r\nsecond"); // row1 = "second", 커서 이동.
    const result = try computeDelta(allocator, p, &core, .{ .generation = 4 });
    defer result.deinit(allocator);
    try testing.expect(result.delta.len > 0);
    try asm_.applyDelta(result.delta);

    const p2 = try projectSnapshot(allocator, &core, .{ .generation = 4 });
    defer allocator.free(p2);
    const re2 = try asm_.toSnapshot(allocator);
    defer allocator.free(re2);
    try testing.expectEqualSlices(u8, p2, re2); // delta 적용 후 조립기 == 새 화면 projection.
    try testing.expectEqualSlices(u8, p2, result.snapshot); // computeDelta의 snapshot == 별도 projection(#6: 한 번 build 재사용).
}
