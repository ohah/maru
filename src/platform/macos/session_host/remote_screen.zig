//! remote_screen — 조립기(`screen_assembler`)의 runs 모델을 renderer가 소비하는 `terminal.RenderSnapshot`(cells)로
//! 변환한다(P3-e2e-2a). §8 "중립 screen DTO" = `RenderSnapshot`이다: Metal renderer도 ANSI CLI도 같은 `RenderSnapshot`을
//! 본다. 그래서 **원격 runtime의 화면도 이 변환을 거쳐 in-process와 똑같은 DTO로 렌더**된다 — 렌더 경로가 로컬/원격에서
//! 갈리지 않는 SSOT다(host TerminalCore.snapshot()도, 이 조립기도 같은 `RenderSnapshot`을 만든다).
//!
//! 레이어: `terminal.Cell/Style/Color`를 만들어야 해서 `@import("maru")`가 필요하다(macOS 전용, barrel 조건부 —
//! screen_snapshot과 같은 부류). 조립기(순수)는 wire-native run 형태로 화면을 들고, 이 파일이 렌더 시점에 그것을 cell
//! 격자로 편다. run은 host가 이미 해석한 상태(resolved RGB·StyleFlags)라 여기선 색을 다시 풀지 않고 그대로 rgb cell로 옮긴다
//! (§8 "새 parser 금지"). 완전한 theme-aware 재해석은 screen_snapshot의 config-light 기준선과 대칭으로 후속이다.

const std = @import("std");
const maru = @import("maru");
const terminal = maru.terminal;
const screen_stream = @import("screen_stream.zig");
const screen_assembler = @import("screen_assembler.zig");

const Run = screen_stream.Run;

/// 조립기에서 편 소유 cell 격자. `RenderSnapshot`이 이 `cells`/`graphemes`를 빌려 렌더러에 노출한다(cells·cluster store를
/// 이 격자가 소유 — snapshot은 alias). 원격 화면이 바뀌면(delta 적용) 렌더 시점에 다시 `build`한다.
pub const CellGrid = struct {
    allocator: std.mem.Allocator,
    cells: []terminal.Cell,
    graphemes: std.ArrayListUnmanaged([]u21),
    size: terminal.Size,
    cursor: terminal.Cursor,
    cursor_shape: terminal.CursorShape,

    pub fn deinit(self: *CellGrid) void {
        self.allocator.free(self.cells);
        for (self.graphemes.items) |g| self.allocator.free(g);
        self.graphemes.deinit(self.allocator);
        self.* = undefined;
    }

    /// 렌더러가 소비하는 중립 DTO. cells/graphemes는 이 격자를 빌린다(격자 수명 안에서 유효). in-process
    /// `TerminalCore.snapshot()`이 돌려주는 것과 같은 타입이라, 렌더 경로가 로컬/원격에서 동일하다.
    pub fn renderSnapshot(self: *const CellGrid) terminal.RenderSnapshot {
        return .{
            .size = self.size,
            .cursor = self.cursor,
            .cursor_shape = self.cursor_shape,
            .cursor_blink = true, // wire는 blink를 따로 싣지 않는다(ScreenMeta.cursor=visible+shape). 정적 렌더라 무해.
            .cells = self.cells,
            .graphemes = self.graphemes.items,
            // prompt_marks/placements/images/dirty: 원격 wire엔 아직 없다(후속) — 기본값(빈/null).
        };
    }
};

/// 조립기 상태를 소유 cell 격자로 편다(caller가 `CellGrid.deinit`). run(resolved RGB·StyleFlags)을 cell(rgb Color·Style
/// bool·codepoint/grapheme_id)로 옮긴다. wide run(width>=2)은 lead cell(width=2) + continuation cell(width=0)로 편다.
pub fn build(allocator: std.mem.Allocator, asm_: *const screen_assembler.ScreenAssembler) error{OutOfMemory}!CellGrid {
    const cols = asm_.cols;
    const rows = asm_.rows_count;
    const cells = try allocator.alloc(terminal.Cell, @as(usize, cols) * rows);
    errdefer allocator.free(cells);
    for (cells) |*c| c.* = .{}; // blank(codepoint=' ', width=1, default style)로 채운다(누락 열 대비).

    var graphemes: std.ArrayListUnmanaged([]u21) = .empty;
    errdefer {
        for (graphemes.items) |g| allocator.free(g);
        graphemes.deinit(allocator);
    }

    var cps: std.ArrayListUnmanaged(u21) = .empty; // run별 grapheme 코드포인트 임시.
    defer cps.deinit(allocator);

    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        const runs = asm_.rowRuns(row);
        const base = @as(usize, row) * cols;
        var col: usize = 0;
        for (runs) |run| {
            const style = runStyle(run);
            try decodeCodepoints(&cps, allocator, run.grapheme);
            const cp0: u21 = if (cps.items.len > 0) cps.items[0] else ' ';
            // cluster 본체(base 뒤 코드포인트)는 store에 한 번 담고, 이 run의 모든 반복이 같은 grapheme_id를 공유한다.
            var gid: u32 = 0;
            if (cps.items.len > 1) {
                const owned = try allocator.dupe(u21, cps.items[1..]);
                graphemes.append(allocator, owned) catch {
                    allocator.free(owned);
                    return error.OutOfMemory;
                };
                gid = @intCast(graphemes.items.len); // 1-based(grapheme_id 규약).
            }
            const wide = run.width >= 2;
            var rep: u32 = 0;
            while (rep < run.count) : (rep += 1) {
                if (col >= cols) break; // 행 overflow 방어.
                cells[base + col] = .{ .codepoint = cp0, .style = style, .width = if (wide) 2 else 1, .grapheme_id = gid };
                col += 1;
                if (wide and col < cols) {
                    cells[base + col] = .{ .style = style, .width = 0, .continuation = true }; // wide의 2번째 셀.
                    col += 1;
                }
            }
        }
    }

    return .{
        .allocator = allocator,
        .cells = cells,
        .graphemes = graphemes,
        .size = .{ .cols = cols, .rows = rows },
        .cursor = .{ .col = asm_.cursor.col, .row = asm_.cursor.row, .visible = asm_.cursor.visible },
        .cursor_shape = if (asm_.cursor.shape <= 2) @enumFromInt(asm_.cursor.shape) else .block, // 0=block/1=underline/2=bar.
    };
}

/// grapheme UTF-8을 코드포인트 목록으로 푼다(첫 = base, 이후 = cluster 본체). 잘못된 UTF-8은 U+FFFD 하나로 대체한다(방어).
fn decodeCodepoints(out: *std.ArrayListUnmanaged(u21), allocator: std.mem.Allocator, g: []const u8) error{OutOfMemory}!void {
    out.clearRetainingCapacity();
    const view = std.unicode.Utf8View.init(g) catch {
        try out.append(allocator, 0xFFFD);
        return;
    };
    var it = view.iterator();
    while (it.nextCodepoint()) |cp| try out.append(allocator, cp);
    if (out.items.len == 0) try out.append(allocator, ' ');
}

fn unpackRgb(v: u32) terminal.Rgb {
    return .{ .r = @intCast((v >> 16) & 0xFF), .g = @intCast((v >> 8) & 0xFF), .b = @intCast(v & 0xFF) };
}

/// run의 resolved RGB·StyleFlags를 cell `Style`로 옮긴다. 색은 이미 풀린 값이라 `.rgb`로 싣고, flag는 bool로 편다
/// (inverse→reverse, invisible→conceal). curly underline은 wire flag엔 있지만 core Style엔 없어 생략한다.
fn runStyle(run: Run) terminal.Style {
    const SF = screen_stream.StyleFlags;
    const f = run.style_flags;
    return .{
        .foreground = .{ .rgb = unpackRgb(run.fg) },
        .background = .{ .rgb = unpackRgb(run.bg) },
        .underline_color = .{ .rgb = unpackRgb(run.underline_color) },
        .bold = f & SF.bold != 0,
        .dim = f & SF.dim != 0,
        .italic = f & SF.italic != 0,
        .underline = f & SF.underline != 0,
        .underline_double = f & SF.underline_double != 0,
        .strikethrough = f & SF.strikethrough != 0,
        .overline = f & SF.overline != 0,
        .reverse = f & SF.inverse != 0,
        .blink = f & SF.blink != 0,
        .conceal = f & SF.invisible != 0,
    };
}

// ─────────────────────────────────────────────────────────────────────────────
// 단위 테스트 (macOS — terminal.Cell/Style 필요)
//
// 이 테스트가 증명하는 것(그리고 터미널에서 왜 중요한가): 원격 runtime의 화면이 in-process와 **같은 RenderSnapshot**으로
// 렌더돼야 렌더 경로가 하나로 유지된다(SSOT). 조립기가 든 run을 cell로 펴서 텍스트·wide 셀·색·커서·grapheme cluster가
// 정확한지, 그리고 실 화면을 투영→조립→cell로 펴면 원본 화면의 텍스트·레이아웃과 일치하는지 고정한다.
// ─────────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const screen_snapshot = @import("screen_snapshot.zig");

test "remote screen: build converts runs to cells (text, wide cell, rgb color, style, cluster)" {
    const allocator = testing.allocator;
    const SF = screen_stream.StyleFlags;
    // row 0: bold 빨강 "h", wide "한"(2셀), 결합 문자 "e\u{0301}"(cluster), 공백. Σ(width*count)=1+2+1+1=5=cols.
    var runs0 = [_]Run{
        .{ .grapheme = "h", .width = 1, .count = 1, .fg = 0xFF0000, .style_flags = SF.bold },
        .{ .grapheme = "한", .width = 2, .count = 1, .fg = 0x00FF00 },
        .{ .grapheme = "e\u{0301}", .width = 1, .count = 1 },
        .{ .grapheme = " ", .width = 1, .count = 1 },
    };
    const row0: screen_stream.Row = .{ .row_index = 0, .runs = &runs0 };
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(allocator);
    {
        const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 1 }, .{ .cols = 5, .rows = 1, .cursor = .{ .col = 4, .row = 0 } });
        defer allocator.free(meta_rec);
        try screen_stream.appendRecord(&stream, allocator, meta_rec);
        const row_rec = try screen_stream.encodeRow(allocator, .{ .kind = .row, .generation = 1 }, row0);
        defer allocator.free(row_rec);
        try screen_stream.appendRecord(&stream, allocator, row_rec);
    }

    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(stream.items);

    var grid = try build(allocator, &asm_);
    defer grid.deinit();
    const snap = grid.renderSnapshot();

    try testing.expectEqual(@as(u16, 5), snap.size.cols);
    try testing.expectEqual(@as(u16, 4), snap.cursor.col);
    // cell 0: "h", width 1, bold, fg rgb(0xFF0000).
    try testing.expectEqual(@as(u21, 'h'), snap.cells[0].codepoint);
    try testing.expectEqual(@as(u2, 1), snap.cells[0].width);
    try testing.expect(snap.cells[0].style.bold);
    try testing.expectEqual(terminal.Color{ .rgb = .{ .r = 0xFF, .g = 0, .b = 0 } }, snap.cells[0].style.foreground);
    // cell 1: "한"(U+D55C), width 2; cell 2: continuation.
    try testing.expectEqual(@as(u21, 0xD55C), snap.cells[1].codepoint);
    try testing.expectEqual(@as(u2, 2), snap.cells[1].width);
    try testing.expect(snap.cells[2].continuation);
    // cell 3: "e" + 결합 acute(U+0301) → codepoint 'e' + grapheme_id로 cluster 본체 참조.
    try testing.expectEqual(@as(u21, 'e'), snap.cells[3].codepoint);
    try testing.expect(snap.cells[3].grapheme_id != 0);
    try testing.expectEqual(@as(u21, 0x0301), snap.graphemes[snap.cells[3].grapheme_id - 1][0]);
}

test "remote screen: projection→assembler→cells preserves a real screen's text and layout" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 12, .rows = 2 });
    defer core.deinit();
    try core.write("한A bc"); // wide + narrow 혼합.

    const p = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 2 });
    defer allocator.free(p);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(p);
    var grid = try build(allocator, &asm_);
    defer grid.deinit();
    const remote = grid.renderSnapshot();

    // 조립→cell 결과가 원본 core 화면과 셀별 codepoint·width·continuation이 같다(색은 표현이 달라 텍스트·레이아웃만 대조).
    const local = core.snapshot();
    try testing.expectEqual(local.size.cols, remote.size.cols);
    try testing.expectEqual(local.size.rows, remote.size.rows);
    try testing.expectEqual(local.cells.len, remote.cells.len);
    for (local.cells, remote.cells, 0..) |lc, rc, i| {
        const lcp: u21 = if (lc.codepoint == 0) ' ' else lc.codepoint; // 투영은 빈 셀(0)을 공백으로 낸다.
        try testing.expectEqual(lcp, rc.codepoint);
        try testing.expectEqual(lc.width, rc.width);
        try testing.expectEqual(lc.continuation, rc.continuation);
        _ = i;
    }
    try testing.expectEqual(local.cursor.col, remote.cursor.col);
    try testing.expectEqual(local.cursor.row, remote.cursor.row);
}
