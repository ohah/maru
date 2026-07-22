//! remote_screen — 조립기(`screen_assembler`)의 runs 모델을 renderer가 소비하는 `terminal.RenderSnapshot`(cells)로
//! 변환한다(P3-e2e-2a). §8 "중립 screen DTO" = `RenderSnapshot`이다: Metal renderer도 ANSI CLI도 같은 `RenderSnapshot`을
//! 본다. 그래서 **원격 runtime의 화면도 이 변환을 거쳐 in-process와 똑같은 DTO로 렌더**된다 — 렌더 경로가 로컬/원격에서
//! 갈리지 않는 SSOT다(host TerminalCore.snapshot()도, 이 조립기도 같은 `RenderSnapshot`을 만든다).
//!
//! 레이어: `terminal.Cell/Style/Color`를 만들어야 해서 `@import("maru")`가 필요하다(macOS 전용, barrel 조건부 —
//! screen_snapshot과 같은 부류). 조립기(순수)는 wire-native run 형태로 화면을 들고, 이 파일이 렌더 시점에 그것을 cell
//! 격자로 편다. run 색은 host가 굽지 않은 **태그드 Color intent**(§screen_stream.ColorTag·StyleFlags)라, 여기선 그 intent를
//! 풀어(unpackColorIntent) cell Color에 그대로 실어 렌더가 자기 theme로 해석하게 한다(config 16색·bold-is-bright·min-contrast·
//! default 색 — in-process와 동일). 여기서 색을 다시 "파싱"하는 게 아니라 wire intent→core Color 1:1 매핑이다(§8 "새 parser 금지").

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
    // kitty 이미지(#1 I4). placements=이 격자가 소유(값 복사), images=이 격자가 배열은 소유하되 각 view의 `pixels`는
    // **조립기 픽셀을 빌린다**(zero-copy — 매 프레임 MB 복사 회피). 격자는 apply마다 재구축되고 render는 mutex 아래
    // 읽으므로(RemoteScreen), 빌린 픽셀은 격자 수명 동안 유효하다(조립기가 mutex 밖에서 안 바뀜).
    placements: []terminal.KittyPlacement = &.{},
    images: []terminal.KittyImageView = &.{},
    // 행별 OSC 133 prompt 마크(dense; 마크 없으면 empty). 이 격자가 소유(조립기 wire → terminal 타입 값 복사).
    prompt_marks: []terminal.RowPrompt = &.{},

    pub fn deinit(self: *CellGrid) void {
        self.allocator.free(self.cells);
        for (self.graphemes.items) |g| self.allocator.free(g);
        self.graphemes.deinit(self.allocator);
        if (self.placements.len != 0) self.allocator.free(self.placements);
        if (self.images.len != 0) self.allocator.free(self.images); // 배열만 — 픽셀은 조립기 소유.
        if (self.prompt_marks.len != 0) self.allocator.free(self.prompt_marks);
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
            // 이미지(#1 I4): placement + view(픽셀은 조립기 빌림)를 노출한다 — 렌더러 buildGpuImages가 image_id/generation으로
            // GPU 텍스처를 캐시해 in-process와 동일하게 그린다. dirty는 아직 원격 wire에 없다(후속) — 기본값.
            .placements = self.placements,
            .images = self.images,
            .prompt_marks = self.prompt_marks, // OSC 133 거터(✓/✗)·prompt 네비 입력.
        };
    }
};

/// 조립기 상태를 소유 cell 격자로 편다(caller가 `CellGrid.deinit`). run(태그드 Color intent·StyleFlags)을 cell(Color intent·
/// Style bool·codepoint/grapheme_id)로 옮긴다 — 색은 host가 굽지 않은 의도라 client 렌더가 자기 theme로 푼다(theme-aware).
/// wide run(width>=2)은 lead cell(width=2) + continuation cell(width=0)로 편다.
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

    // 이미지(#1 I4): placement를 terminal 타입으로 1:1 복사하고, 참조된 image_id마다 저장 이미지를 KittyImageView로 빌린다
    // (픽셀 zero-copy — 조립기 소유). 렌더러(buildGpuImages)가 이 둘로 in-process와 동일하게 그린다.
    const src_placements = asm_.imagePlacements();
    const placements: []terminal.KittyPlacement = if (src_placements.len == 0) &.{} else pl: {
        const arr = try allocator.alloc(terminal.KittyPlacement, src_placements.len);
        for (src_placements, 0..) |p, i| arr[i] = .{
            .image_id = p.image_id,
            .placement_id = p.placement_id,
            .row = p.row,
            .col = p.col,
            .cell_x_offset = p.cell_x_offset,
            .cell_y_offset = p.cell_y_offset,
            .src_x = p.src_x,
            .src_y = p.src_y,
            .src_width = p.src_width,
            .src_height = p.src_height,
            .columns = p.columns,
            .rows = p.rows,
            .z = p.z,
        };
        break :pl arr;
    };
    errdefer if (placements.len != 0) allocator.free(placements);

    var images: std.ArrayListUnmanaged(terminal.KittyImageView) = .empty;
    errdefer images.deinit(allocator);
    for (src_placements) |p| {
        var seen = false; // placement가 참조하는 image_id 중복 제거(같은 이미지의 여러 placement).
        for (images.items) |iv| {
            if (iv.image_id == p.image_id) {
                seen = true;
                break;
            }
        }
        if (seen) continue;
        if (asm_.imageById(p.image_id)) |img| {
            images.append(allocator, .{
                .image_id = p.image_id,
                .width = img.width,
                .height = img.height,
                .bpp = img.bpp,
                .generation = img.generation,
                .pixels = img.pixels, // 조립기 픽셀 빌림(zero-copy).
            }) catch return error.OutOfMemory;
        }
    }
    const images_slice = images.toOwnedSlice(allocator) catch return error.OutOfMemory;

    // prompt_marks: 조립기의 wire(RowPromptWire)를 core terminal.RowPrompt로 1:1 환산(kind u8→SemanticPrompt, 손상 방어로 clamp).
    const src_pm = asm_.promptMarks();
    const prompt_marks: []terminal.RowPrompt = if (src_pm.len == 0) &.{} else pm: {
        const arr = try allocator.alloc(terminal.RowPrompt, src_pm.len);
        for (src_pm, 0..) |w, i| arr[i] = .{
            .kind = if (w.kind <= 3) @enumFromInt(w.kind) else .unknown,
            .exit = w.exit,
        };
        break :pm arr;
    };
    errdefer if (prompt_marks.len != 0) allocator.free(prompt_marks);

    return .{
        .allocator = allocator,
        .cells = cells,
        .graphemes = graphemes,
        .size = .{ .cols = cols, .rows = rows },
        .cursor = .{ .col = asm_.cursor.col, .row = asm_.cursor.row, .visible = asm_.cursor.visible },
        .cursor_shape = if (asm_.cursor.shape <= 2) @enumFromInt(asm_.cursor.shape) else .block, // 0=block/1=underline/2=bar.
        .placements = placements,
        .images = images_slice,
        .prompt_marks = prompt_marks,
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

/// Run wire의 태그드 u32 Color intent를 core `Color`로 푼다(§screen_stream.ColorTag). host가 구운 RGB가 아니라 의도라,
/// client 렌더가 이 intent를 자기 theme로 해석한다(config 16색 base·bold-is-bright·min-contrast·default 색 — in-process 동일).
fn unpackColorIntent(v: u32) terminal.Color {
    const Tag = screen_stream.ColorTag;
    return switch (v >> Tag.shift) {
        Tag.default => .default,
        Tag.indexed => .{ .indexed = @intCast(v & Tag.index_mask) },
        else => .{ .rgb = unpackRgb(v & Tag.rgb_mask) }, // Tag.rgb — unpackRgb가 채널별 &0xFF로 태그 바이트를 이미 버린다.
    };
}

/// run의 태그드 Color intent·StyleFlags를 cell `Style`로 옮긴다. 색은 intent 그대로 실어 렌더가 theme로 풀고, flag는 bool로
/// 편다(inverse→reverse, invisible→conceal). curly underline은 wire flag엔 있지만 core Style엔 없어 생략한다.
fn runStyle(run: Run) terminal.Style {
    const SF = screen_stream.StyleFlags;
    const f = run.style_flags;
    return .{
        .foreground = unpackColorIntent(run.fg),
        .background = unpackColorIntent(run.bg),
        .underline_color = unpackColorIntent(run.underline_color),
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
    const Tag = screen_stream.ColorTag;
    // row 0: bold rgb빨강 "h", wide "한"(2셀, indexed 2), 결합 문자 "e\u{0301}"(cluster, default fg), 공백.
    // 색은 태그드 Color intent다 — build가 이 intent를 풀어 셀 Color에 그대로 실어야 렌더가 theme로 해석한다.
    // Σ(width*count)=1+2+1+1=5=cols.
    var runs0 = [_]Run{
        .{ .grapheme = "h", .width = 1, .count = 1, .fg = (Tag.rgb << Tag.shift) | 0xFF0000, .style_flags = SF.bold },
        .{ .grapheme = "한", .width = 2, .count = 1, .fg = (Tag.indexed << Tag.shift) | 2 },
        .{ .grapheme = "e\u{0301}", .width = 1, .count = 1 }, // fg 미지정 = 0 = default intent.
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
    // cell 0: "h", width 1, bold, fg = rgb intent(0xFF0000) → `.rgb` Color 그대로.
    try testing.expectEqual(@as(u21, 'h'), snap.cells[0].codepoint);
    try testing.expectEqual(@as(u2, 1), snap.cells[0].width);
    try testing.expect(snap.cells[0].style.bold);
    try testing.expectEqual(terminal.Color{ .rgb = .{ .r = 0xFF, .g = 0, .b = 0 } }, snap.cells[0].style.foreground);
    // cell 1: "한"(U+D55C), width 2, fg = indexed intent(2) → `.indexed` 유지(렌더가 config 16색으로 푼다); cell 2: continuation.
    try testing.expectEqual(@as(u21, 0xD55C), snap.cells[1].codepoint);
    try testing.expectEqual(@as(u2, 2), snap.cells[1].width);
    try testing.expectEqual(terminal.Color{ .indexed = 2 }, snap.cells[1].style.foreground);
    try testing.expect(snap.cells[2].continuation);
    // cell 3: "e" + 결합 acute(U+0301) → codepoint 'e' + grapheme_id로 cluster 본체 참조. fg = default intent(0) → `.default`.
    try testing.expectEqual(terminal.Color.default, snap.cells[3].style.foreground);
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
    defer d.deinit(allocator);
    try rs.applyDelta(d.delta, io);

    surface.lockCore(io);
    const r2 = surface.renderSnapshot();
    const row1_c0 = r2.cells[10].codepoint; // row1 col0.
    surface.unlockCore(io);
    try testing.expectEqual(@as(u21, 's'), row1_c0);
}

test "remote screen: build exposes kitty images + placements from the assembler (I4)" {
    const allocator = testing.allocator;
    // 이미지가 실린 snapshot 스트림: meta + image_blob(2x1 RGBA) + image_placement(row 1, col 2, z 3).
    var stream: std.ArrayListUnmanaged(u8) = .empty;
    defer stream.deinit(allocator);
    const meta_rec = try screen_stream.encodeScreenMeta(allocator, .{ .kind = .screen_meta, .generation = 1 }, .{ .cols = 4, .rows = 2 });
    defer allocator.free(meta_rec);
    try screen_stream.appendRecord(&stream, allocator, meta_rec);
    const px = [_]u8{ 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88 };
    const blob_rec = try screen_stream.encodeImageBlob(allocator, .{ .kind = .image_blob, .generation = 1 }, .{ .image_id = 5, .generation = 9, .width = 2, .height = 1, .bpp = 4, .pixels = &px });
    defer allocator.free(blob_rec);
    try screen_stream.appendRecord(&stream, allocator, blob_rec);
    const pl_rec = try screen_stream.encodeImagePlacement(allocator, .{ .kind = .image_placement, .generation = 1 }, .{ .image_id = 5, .placement_id = 0, .row = 1, .col = 2, .columns = 2, .rows = 1, .z = 3 });
    defer allocator.free(pl_rec);
    try screen_stream.appendRecord(&stream, allocator, pl_rec);

    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(stream.items);

    // build가 조립기의 이미지/placement를 renderSnapshot에 노출한다(픽셀은 조립기 빌림 — zero-copy).
    var grid = try build(allocator, &asm_);
    defer grid.deinit();
    const snap = grid.renderSnapshot();

    try testing.expectEqual(@as(usize, 1), snap.placements.len);
    try testing.expectEqual(@as(u32, 5), snap.placements[0].image_id);
    try testing.expectEqual(@as(u16, 2), snap.placements[0].col);
    try testing.expectEqual(@as(i32, 1), snap.placements[0].row);
    try testing.expectEqual(@as(i32, 3), snap.placements[0].z);
    try testing.expectEqual(@as(u32, 2), snap.placements[0].columns);

    try testing.expectEqual(@as(usize, 1), snap.images.len);
    try testing.expectEqual(@as(u32, 5), snap.images[0].image_id);
    try testing.expectEqual(@as(u32, 2), snap.images[0].width);
    try testing.expectEqual(@as(u8, 4), snap.images[0].bpp);
    try testing.expectEqual(@as(u64, 9), snap.images[0].generation); // 렌더러 GPU 캐시 키.
    try testing.expectEqualSlices(u8, &px, snap.images[0].pixels);
}

/// **원격 파이프라인 parity 인프라(#1 이후 드리프트 방어).** in-process `renderSnapshot`과 원격 파이프라인
/// (`projectSnapshot`→`ScreenAssembler`→`build`)의 결과가 **렌더 관점에서 동등**한지 단언한다. 원격이 싣기로 한 축
/// (size·cursor·cursor_shape·cells[style·색 intent·grapheme 해석]·placements·images)을 비교하고, 의도적 드롭
/// (cursor_blink 하드코딩·prompt_marks·last_command_exit·dirty)은 제외한다. **comptime로 `RenderSnapshot`의 모든 필드가
/// "비교" 또는 "드롭"으로 분류됐는지 강제**한다 — 새 필드가 추가되면 여기서 **컴파일 에러**가 나 원격 경로 배선(투영/조립/
/// 노출)을 잊지 않게 한다. 색·이미지가 조용히 유실됐던 재발을 막는 안전망이다.
fn expectSnapshotParity(local: terminal.RenderSnapshot, remote: terminal.RenderSnapshot) !void {
    // ── comptime 필드 커버리지: RenderSnapshot 새 필드는 반드시 아래 둘 중 하나로 분류돼야 한다 ──
    const compared = [_][]const u8{ "size", "cursor", "cursor_shape", "cells", "graphemes", "placements", "images", "prompt_marks" };
    const dropped = [_][]const u8{ "cursor_blink", "last_command_exit", "dirty" };
    comptime {
        for (@typeInfo(terminal.RenderSnapshot).@"struct".fields) |f| {
            var classified = false;
            for (compared) |c| {
                if (std.mem.eql(u8, f.name, c)) classified = true;
            }
            for (dropped) |d| {
                if (std.mem.eql(u8, f.name, d)) classified = true;
            }
            if (!classified) @compileError("RenderSnapshot 필드 '" ++ f.name ++ "'가 parity 테스트에서 미분류다 — 원격 경로에 실었으면 `compared`에, 의도적 드롭이면 `dropped`에 추가하라(드리프트 방어).");
        }
    }

    // size.
    try testing.expectEqual(local.size.cols, remote.size.cols);
    try testing.expectEqual(local.size.rows, remote.size.rows);
    // cursor(+shape). cursor_blink는 원격이 항상 true(의도적 드롭)라 제외.
    try testing.expectEqual(local.cursor.col, remote.cursor.col);
    try testing.expectEqual(local.cursor.row, remote.cursor.row);
    try testing.expectEqual(local.cursor.visible, remote.cursor.visible);
    try testing.expectEqual(local.cursor_shape, remote.cursor_shape);
    // cells: codepoint(0→space 정규화)·width·continuation·style(색 Color intent 포함 전 필드)·grapheme cluster(store id 번호는
    // 다를 수 있어 해석된 본체로 대조).
    try testing.expectEqual(local.cells.len, remote.cells.len);
    for (local.cells, remote.cells) |lc, rc| {
        const lcp: u21 = if (lc.codepoint == 0) ' ' else lc.codepoint; // 투영은 빈 셀(0)을 공백으로 낸다.
        try testing.expectEqual(lcp, rc.codepoint);
        try testing.expectEqual(lc.width, rc.width);
        try testing.expectEqual(lc.continuation, rc.continuation);
        try testing.expectEqual(lc.style, rc.style); // foreground/background/underline_color(Color intent) + bold/dim/italic/… 전부.
        if (lc.grapheme_id != 0) {
            try testing.expect(rc.grapheme_id != 0);
            try testing.expectEqualSlices(u21, local.graphemes[lc.grapheme_id - 1], remote.graphemes[rc.grapheme_id - 1]);
        } else {
            try testing.expectEqual(@as(u32, 0), rc.grapheme_id);
        }
    }
    // placements: 순서·전 필드 동일(원격 placement_list = 투영 순서 = local buildPlacementViews 순서).
    try testing.expectEqual(local.placements.len, remote.placements.len);
    for (local.placements, remote.placements) |lp, rp| try testing.expectEqual(lp, rp);
    // images: local은 전체(map 순), remote는 placement 참조분(placement 순)이라 image_id로 매칭 비교(순서 무관).
    for (remote.images) |ri| {
        var matched = false;
        for (local.images) |li| {
            if (li.image_id != ri.image_id) continue;
            try testing.expectEqual(li.width, ri.width);
            try testing.expectEqual(li.height, ri.height);
            try testing.expectEqual(li.bpp, ri.bpp);
            try testing.expectEqual(li.generation, ri.generation);
            try testing.expectEqualSlices(u8, li.pixels, ri.pixels);
            matched = true;
        }
        try testing.expect(matched); // 원격이 노출한 이미지는 로컬에 반드시 있다.
    }
    // 원격 placement가 참조하는 이미지가 원격 images에 다 있는지(누락 방어).
    for (remote.placements) |rp| {
        if (rp.image_id == 0) continue;
        var have = false;
        for (remote.images) |ri| {
            if (ri.image_id == rp.image_id) have = true;
        }
        try testing.expect(have);
    }
    // prompt_marks(OSC 133): local은 항상 length-rows(core), remote는 마크 없으면 empty이므로 행별 의미로 대조(범위 밖=default).
    var pr: u16 = 0;
    while (pr < local.size.rows) : (pr += 1) {
        const lm: terminal.RowPrompt = if (pr < local.prompt_marks.len) local.prompt_marks[pr] else .{};
        const rm: terminal.RowPrompt = if (pr < remote.prompt_marks.len) remote.prompt_marks[pr] else .{};
        try testing.expectEqual(lm.kind, rm.kind);
        try testing.expectEqual(lm.exit, rm.exit);
    }
}

test "remote screen: full RenderSnapshot parity with in-process (styles, colors, wide, grapheme, cursor shape, image)" {
    const allocator = testing.allocator;
    var core = try terminal.TerminalCore.init(allocator, .{ .cols = 20, .rows = 4 });
    defer core.deinit();

    // 다양한 스타일·색축을 한 화면에 태운다 — 하나라도 원격 경로에서 유실되면 parity가 깨진다.
    try core.write("\x1b[1;31mB\x1b[0m"); // bold + indexed(ANSI 1 red)
    try core.write("\x1b[3;38;5;120mI\x1b[0m"); // italic + 256색(120)
    try core.write("\x1b[4;38;2;10;20;30mU\x1b[0m"); // underline + truecolor rgb
    try core.write("\x1b[7mR\x1b[0m"); // reverse
    try core.write("\x1b[2;9mD\x1b[0m"); // dim + strikethrough
    try core.write("한"); // wide CJK(width 2 + continuation)
    try core.write("e\u{0301}"); // grapheme cluster(e + combining acute)
    try core.write("\x1b[4 q"); // DECSCUSR: underline 커서 모양
    try core.write("\r\n\x1b]133;A\x1b\\$ x"); // OSC 133 A: 다음 행을 prompt로 마킹 — prompt_marks 축을 실제로 태운다.

    // kitty 이미지 transmit+display(2x2 RGBA, i=1).
    var raw = [_]u8{ 0x10, 0x20, 0x30, 0x40, 0x50, 0x60, 0x70, 0x80, 0x90, 0xA0, 0xB0, 0xC0, 0xD0, 0xE0, 0xF0, 0x11 };
    var b64: [32]u8 = undefined;
    const b64s = std.base64.standard.Encoder.encode(&b64, &raw);
    var seq: [96]u8 = undefined;
    try core.write(try std.fmt.bufPrint(&seq, "\x1b_Ga=T,f=32,s=2,v=2,i=1;{s}\x1b\\", .{b64s}));

    // 원격 파이프라인: 투영 → 조립 → 격자.
    const p = try screen_snapshot.projectSnapshot(allocator, &core, .{ .generation = 7 });
    defer allocator.free(p);
    var asm_ = screen_assembler.ScreenAssembler.init(allocator);
    defer asm_.deinit();
    try asm_.applySnapshot(p);
    var grid = try build(allocator, &asm_);
    defer grid.deinit();

    // in-process 기준 화면(뷰포트 인지 — projectSnapshot과 같은 소스)과 렌더 관점 동등성 단언.
    const local = core.renderSnapshot();
    // fixture가 실제로 prompt 마크를 만들었는지(=prompt_marks 경로를 태우는지) 보장 — 안 그러면 all-default parity로 헛통과.
    var has_mark = false;
    for (local.prompt_marks) |m| if (m.kind != .unknown) {
        has_mark = true;
    };
    try testing.expect(has_mark);
    try expectSnapshotParity(local, grid.renderSnapshot());
}
