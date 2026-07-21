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
const ScreenSource = maru.session.surface.ScreenSource;

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

/// 원격 host runtime의 client 쪽 화면 소스(P3-e2e-2c). 조립기(runs 모델)를 소유하고, snapshot/delta를 적용할 때마다
/// 렌더용 `CellGrid`를 다시 편다. `Surface`에 `screenSource()`로 주입하면 그 Surface의 `renderSnapshot()`/`lockCore`가
/// 로컬 `TerminalCore` 대신 이걸 쓴다 — GUI 렌더는 로컬/원격을 모른다(SSOT, docs/persistent-session-host.md §8).
///
/// 스레딩: delta를 받는 쪽(client read)과 렌더 쪽이 다른 스레드라, 자체 `mutex`로 apply와 render를 직렬화한다(로컬
/// `core_mutex`와 동형 역할 — 단 core가 아니라 조립 화면 캐시라 owner-추적 없이 단순 std.Io.Mutex). `render_snapshot`이
/// 돌려주는 slice는 `grid`를 alias하므로 caller(Surface)가 `lock`/`unlock` 안에서 읽고 복사한다.
pub const RemoteScreen = struct {
    allocator: std.mem.Allocator,
    assembler: screen_assembler.ScreenAssembler,
    grid: CellGrid, // 현재 조립 상태를 편 cell 격자(apply마다 재구축, render가 읽음).
    mutex: std.Io.Mutex = .init,

    const source_vtable = ScreenSource.VTable{ .render_snapshot = srcRenderSnapshot, .lock = srcLock, .unlock = srcUnlock };

    pub fn init(allocator: std.mem.Allocator) error{OutOfMemory}!RemoteScreen {
        var assembler = screen_assembler.ScreenAssembler.init(allocator);
        errdefer assembler.deinit();
        const grid = try build(allocator, &assembler); // 빈 조립기 → 0x0 격자.
        return .{ .allocator = allocator, .assembler = assembler, .grid = grid };
    }

    pub fn deinit(self: *RemoteScreen) void {
        self.grid.deinit();
        self.assembler.deinit();
        self.* = undefined;
    }

    /// `Surface.remote`에 넣을 화면 소스 핸들. Surface는 이 vtable만 알고 RemoteScreen 구체타입을 모른다(레이어 경계).
    pub fn screenSource(self: *RemoteScreen) ScreenSource {
        return .{ .ctx = self, .vtable = &source_vtable };
    }

    /// host의 snapshot record로 화면을 리셋한다(attach 첫 화면·gap 복구). 조립기를 갱신하고 렌더 격자를 다시 편다.
    pub fn applySnapshot(self: *RemoteScreen, bytes: []const u8, io: std.Io) (screen_assembler.ApplyError || error{OutOfMemory})!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.assembler.applySnapshot(bytes);
        try self.rebuildGrid();
    }

    /// host의 delta record를 적용한다(화면 증분). base_generation gap이면 `GenerationGap`(caller가 fresh snapshot 재요청).
    pub fn applyDelta(self: *RemoteScreen, bytes: []const u8, io: std.Io) (screen_assembler.ApplyError || error{OutOfMemory})!void {
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        try self.assembler.applyDelta(bytes);
        try self.rebuildGrid();
    }

    fn rebuildGrid(self: *RemoteScreen) error{OutOfMemory}!void {
        const new_grid = try build(self.allocator, &self.assembler);
        self.grid.deinit();
        self.grid = new_grid;
    }

    fn srcRenderSnapshot(ctx: *anyopaque) terminal.RenderSnapshot {
        const self: *RemoteScreen = @ptrCast(@alignCast(ctx));
        return self.grid.renderSnapshot();
    }
    fn srcLock(ctx: *anyopaque, io: std.Io) void {
        const self: *RemoteScreen = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(io);
    }
    fn srcUnlock(ctx: *anyopaque, io: std.Io) void {
        const self: *RemoteScreen = @ptrCast(@alignCast(ctx));
        self.mutex.unlock(io);
    }
};

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

test "remote screen: a Surface backed by RemoteScreen renders the assembled remote screen, updated by delta" {
    const allocator = testing.allocator;
    const io = testing.io;
    const Surface = maru.session.Surface;

    // host 화면을 투영해 원격 screen에 적용한다("remote!").
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 10, .rows = 2 });
    defer core.deinit();
    try core.write("remote!");
    const snap = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 1 });
    defer allocator.free(snap);

    var rs = try RemoteScreen.init(allocator);
    defer rs.deinit();
    try rs.applySnapshot(snap, io);

    // Surface에 원격 소스를 주입한다. 로컬 core는 빈 화면 — renderSnapshot이 로컬이 아니라 조립된 원격을 줘야 한다.
    var surface = try Surface.init(allocator, 1, .{ .cols = 10, .rows = 2 });
    defer surface.deinit();
    surface.remote = rs.screenSource();

    surface.lockCore(io);
    const rendered = surface.renderSnapshot();
    const c0 = rendered.cells[0].codepoint; // lock 아래에서 값만 복사(현행 계약).
    const c1 = rendered.cells[1].codepoint;
    surface.unlockCore(io);
    try testing.expectEqual(@as(u21, 'r'), c0); // 로컬 core라면 공백이었을 것 — 원격이 반영됐다.
    try testing.expectEqual(@as(u21, 'e'), c1);

    // host 화면을 바꾸고 delta를 적용하면 Surface.renderSnapshot이 반영한다.
    try core.write("\r\nsecond"); // row1 = "second".
    const d = try screen_snapshot.computeDelta(allocator, snap, &core, .{ .generation = 1 });
    defer allocator.free(d);
    try rs.applyDelta(d, io);

    surface.lockCore(io);
    const r2 = surface.renderSnapshot();
    const row1_c0 = r2.cells[10].codepoint; // row1 col0.
    surface.unlockCore(io);
    try testing.expectEqual(@as(u21, 's'), row1_c0);
}
