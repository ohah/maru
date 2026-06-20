const std = @import("std");
const terminal = @import("../terminal.zig");
const width = @import("../width.zig");

pub const DrawCell = struct {
    row: u16,
    col: u16,
    codepoint: u21,
    combining: ?u21 = null,
    width: u2 = 1,
    style: terminal.Style = .{},
};

pub const CursorOverlay = struct {
    row: u16,
    col: u16,
    visible: bool = true,
    // DECSCUSR 모양. 렌더러가 block(반전)/underline(하단 바)/bar(좌측 세로 바)로 투영한다.
    shape: terminal.CursorShape = .block,
};

// 텍스트 장식선의 종류 — 셀 안에서 선이 그려지는 위치를 정한다(렌더러가 reserved kind로 환산).
pub const LineKind = enum {
    underline, // SGR 4 — 셀 하단
    double_underline, // SGR 21 — 셀 하단 2중선
    strikethrough, // SGR 9 — 셀 중앙
    overline, // SGR 53 — 셀 상단
};

// 텍스트 장식선(underline/strikethrough/overline) overlay. 셋은 같은 draw-time overlay라 glyph
// atlas가 "A"와 "밑줄 A"를 따로 캐시하지 않고, 독립 비트라 한 셀이 셋을 다 방출할 수 있다. kind가
// 셀 내 위치를, dim(SGR 2)이 렌더러의 faint 보간 여부를 정한다 — dim 텍스트의 장식선도 전경처럼
// 흐려지게(packForeground와 같은 규칙).
pub const LineOverlay = struct {
    row: u16,
    col: u16,
    width: u2 = 1,
    color: terminal.Color = .default,
    dim: bool = false,
    kind: LineKind,
};

// OSC 133 거터 마크 — 프롬프트 시작 행 왼쪽 가장자리의 세로 색 바. 명령 성공(초록)/실패(빨강)을
// 보여준다. 렌더러는 커서 bar(좌측 세로 부분 사각형)와 같은 kind를 col 0에 재사용한다(셰이더 불변).
pub const GutterMark = struct {
    row: u16,
    success: bool, // 종료코드 0이면 true(초록), 아니면 false(빨강)
};

pub const DrawOverlay = union(enum) {
    cursor: CursorOverlay,
    line: LineOverlay,
    gutter: GutterMark,
};

pub const DrawList = struct {
    size: terminal.Size,
    cursor: terminal.Cursor,
    dirty: ?terminal.DirtyRegion,
    cells: []DrawCell,
    overlays: []DrawOverlay,

    pub fn deinit(self: *DrawList, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.overlays);
        self.* = undefined;
    }
};

pub fn buildDrawList(
    allocator: std.mem.Allocator,
    snapshot: terminal.RenderSnapshot,
) !DrawList {
    // DrawList는 GPU 명령이 아니라 renderer backend가 공유해서 소비할 중립 계약이다.
    // 여기서 PTY나 parser를 보지 않고 snapshot만 읽어야 Metal/WebGPU backend를
    // 나중에 바꿔도 terminal core를 다시 설계하지 않아도 된다.
    var cells: std.ArrayList(DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var overlays: std.ArrayList(DrawOverlay) = .empty;
    errdefer overlays.deinit(allocator);

    if (snapshot.dirty) |dirty| {
        const row_count: usize = snapshot.size.rows;
        const col_count: usize = snapshot.size.cols;
        if (row_count != 0 and col_count != 0) {
            // snapshot.cells는 size 그대로의 그리드를 담는다는 계약이다. dirty row를
            // size 기준으로 인덱싱하므로, 이 전제가 깨진 snapshot(size/cells 불일치)은
            // 조용히 엉뚱한 셀을 읽는 대신 여기서 바로 드러나야 한다.
            std.debug.assert(snapshot.cells.len >= row_count * col_count);

            const start_row = @min(@as(usize, dirty.start_row), row_count - 1);
            const end_row = @min(@as(usize, dirty.end_row), row_count - 1);

            if (start_row <= end_row) {
                // dirty row 전체를 그리므로 만들 cell 수의 상한이 정해져 있다. 미리
                // 한 번에 확보해 frame마다 append가 슬라이스를 반복 재할당하지 않게 한다.
                // continuation cell은 건너뛰므로 실제 개수는 이 상한 이하라 안전하다.
                try cells.ensureTotalCapacity(allocator, (end_row - start_row + 1) * col_count);
                // overlay도 같은 상한을 쓴다: cell마다 underline+strikethrough+overline overlay가 최대
                // 3개, 행마다 OSC 133 거터 마크가 최대 1개, 루프 뒤에 cursor overlay가 최대 1개 더 붙으므로
                // (3*cols+1)*행수+1이다. cells와 같은 이유로 미리 확보해 per-frame 재할당을 없앤다.
                try overlays.ensureTotalCapacity(allocator, (end_row - start_row + 1) * (4 * col_count + 1) + 1); // 셀당 최대 4 line overlay(underline+double+strike+overline) + cursor

                for (start_row..end_row + 1) |row| {
                    // isWideRenderSymbol이 다음 빈 셀을 흡수(2칸 렌더)하면 그 셀은 emit하지 않는다 — 행마다 리셋.
                    var skip_one = false;
                    for (0..col_count) |col| {
                        if (skip_one) {
                            skip_one = false;
                            continue;
                        }
                        const cell = snapshot.cells[index(snapshot.size, row, col)];
                        if (cell.continuation) continue;

                        // EAW Ambiguous(폭 1)지만 폰트가 ~2칸으로 그리는 심볼(동그란/괄호친 영숫자 — 동그란 번호 등)은,
                        // 다음 셀이 비었으면 **그릴 폭**을 2칸으로 키워 온전한 크기로 그린다(작아짐/잘림 방지). advance/커서는
                        // grid가 1로 유지하므로(DrawCell.width는 렌더 전용 — 커서는 snapshot.cursor에서 별도) 셸 wcwidth와
                        // 정합이 안 깨진다. 흡수한 다음 빈 셀은 emit 안 함(wide continuation과 동형 — 안 그러면 그 셀 bg가
                        // 심볼 오른쪽 절반을 덮어쓴다). 다음 셀이 차있으면 1칸 유지(constrain이 축소) — Ghostty constraintWidth와 동일.
                        var render_width = cell.width;
                        if (cell.width == 1 and width.isWideRenderSymbol(cell.codepoint) and col + 1 < col_count) {
                            const next = snapshot.cells[index(snapshot.size, row, col + 1)];
                            if (!next.continuation and (next.codepoint == 0 or next.codepoint == ' ')) {
                                render_width = 2;
                                skip_one = true;
                            }
                        }

                        cells.appendAssumeCapacity(.{
                            .row = @intCast(row),
                            .col = @intCast(col),
                            .codepoint = cell.codepoint,
                            .combining = cell.combining,
                            .width = render_width,
                            .style = cell.style,
                        });

                        // 텍스트 장식선(underline/strikethrough/overline)은 draw-time overlay다 —
                        // glyph cell 밖에 둬 atlas가 "A"와 "밑줄 A"를 따로 캐시하지 않게 한다. 셋은
                        // 독립 비트라 한 셀이 셋을 다 낼 수 있고, kind만 다른 같은 모양이라 한 헬퍼로 낸다.
                        if (cell.style.underline) {
                            // double underline은 하단 선(reserved 2) + 둘째 선(reserved 7, 위)으로 2개 방출 —
                            // .m이 셀당 한 띠만 그려서 두 줄을 두 overlay로 낸다. single은 하단 선만.
                            overlays.appendAssumeCapacity(.{ .line = lineOverlay(row, col, cell, .underline) });
                            if (cell.style.underline_double) overlays.appendAssumeCapacity(.{ .line = lineOverlay(row, col, cell, .double_underline) });
                        }
                        if (cell.style.strikethrough) overlays.appendAssumeCapacity(.{ .line = lineOverlay(row, col, cell, .strikethrough) });
                        if (cell.style.overline) overlays.appendAssumeCapacity(.{ .line = lineOverlay(row, col, cell, .overline) });
                    }

                    // OSC 133 거터 마크: 종료코드는 프롬프트 시작 행에만 스탬프되므로, exit가 있으면
                    // 곧 그 행이 명령 결과를 가진 프롬프트 시작 행이다 — 왼쪽 가장자리에 ✓(초록)/✗(빨강) 바.
                    if (row < snapshot.prompt_marks.len) {
                        if (snapshot.prompt_marks[row].exit) |code| {
                            overlays.appendAssumeCapacity(.{ .gutter = .{
                                .row = @intCast(row),
                                .success = code == 0,
                            } });
                        }
                    }
                }
            }
        }

        if (cursorVisibleInSnapshot(snapshot) and dirtyIncludesRow(dirty, snapshot.cursor.row)) {
            // Cursor is also a draw-time overlay. TerminalCore owns the dirty
            // decision for cursor movement, so the renderer only consumes the
            // row range instead of comparing old/new snapshots itself.
            // rows/cols가 0이 아니면 위 dirty-row 블록이 반드시 실행돼 +1 자리를
            // 확보해 두므로 cursor overlay도 assumeCapacity로 붙일 수 있다.
            overlays.appendAssumeCapacity(.{ .cursor = .{
                .row = snapshot.cursor.row,
                .col = snapshot.cursor.col,
                .visible = snapshot.cursor.visible,
                .shape = snapshot.cursor_shape,
            } });
        }
    }

    return .{
        .size = snapshot.size,
        .cursor = snapshot.cursor,
        .dirty = snapshot.dirty,
        .cells = try cells.toOwnedSlice(allocator),
        .overlays = try overlays.toOwnedSlice(allocator),
    };
}

fn lineOverlay(row: usize, col: usize, cell: terminal.Cell, kind: LineKind) LineOverlay {
    // underline은 SGR 58 underline_color가 있으면 그 색으로(없으면 전경색). strikethrough/overline은 전경색.
    // nvim/helix가 LSP 진단을 전경과 다른 색의 밑줄로 표시한다(G1 underline color).
    const line_color: terminal.Color = if (kind == .underline or kind == .double_underline) switch (cell.style.underline_color) {
        .default => cell.style.foreground,
        else => cell.style.underline_color,
    } else cell.style.foreground;
    return .{
        .row = @intCast(row),
        .col = @intCast(col),
        .width = cell.width,
        .color = line_color,
        .dim = cell.style.dim,
        .kind = kind,
    };
}

fn index(size: terminal.Size, row: usize, col: usize) usize {
    return row * size.cols + col;
}

fn cursorVisibleInSnapshot(snapshot: terminal.RenderSnapshot) bool {
    return snapshot.cursor.visible and
        snapshot.size.rows != 0 and
        snapshot.size.cols != 0 and
        snapshot.cursor.row < snapshot.size.rows and
        snapshot.cursor.col < snapshot.size.cols;
}

fn dirtyIncludesRow(dirty: terminal.DirtyRegion, row: u16) bool {
    return row >= dirty.start_row and row <= dirty.end_row;
}

test "draw list emits drawable cells from dirty rows only" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();

    // 이 테스트는 renderer가 전체 화면을 매번 그리지 않아도 되는 첫 계약을 고정한다.
    // 현재 core의 dirty는 row 범위이므로, 한 글자만 바뀌어도 해당 row의 셀만 DrawList에 들어간다.
    core.clearDirty();
    try core.write("A");

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u16, 4), draw_list.size.cols);
    try std.testing.expectEqual(@as(usize, 4), draw_list.cells.len);
    try std.testing.expectEqual(@as(u16, 0), draw_list.cells[0].row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.cells[0].col);
    try std.testing.expectEqual(@as(u21, 'A'), draw_list.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 0), draw_list.dirty.?.start_row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.dirty.?.end_row);
    try std.testing.expectEqual(@as(usize, 1), draw_list.overlays.len);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].cursor.row);
    try std.testing.expectEqual(@as(u16, 1), draw_list.overlays[0].cursor.col);
}

test "draw list emits OSC 133 gutter marks for prompt rows with a recorded exit" {
    // 종료코드는 프롬프트 시작 행에만 스탬프되므로(exit != null), 그 행마다 거터 마크가 나와야 한다.
    // 성공(exit 0)=초록(success=true), 실패(≠0)=빨강. exit 없는 행은 거터 없음.
    var cells = [_]terminal.Cell{.{}} ** 4; // 2 cols × 2 rows
    const marks = [_]terminal.RowPrompt{
        .{ .kind = .input, .exit = 0 }, // row0: 성공 명령의 프롬프트 시작
        .{ .kind = .command, .exit = null }, // row1: 출력 — 거터 없음
    };
    const snapshot: terminal.RenderSnapshot = .{
        .size = .{ .cols = 2, .rows = 2 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .cells = &cells,
        .prompt_marks = &marks,
        .dirty = .{ .start_row = 0, .end_row = 1 },
    };
    var draw_list = try buildDrawList(std.testing.allocator, snapshot);
    defer draw_list.deinit(std.testing.allocator);

    var gutters: usize = 0;
    for (draw_list.overlays) |o| switch (o) {
        .gutter => |g| {
            gutters += 1;
            try std.testing.expectEqual(@as(u16, 0), g.row); // 프롬프트 시작 행
            try std.testing.expect(g.success); // exit 0 → 초록
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), gutters); // 출력 행(exit null)엔 거터 없음
}

test "draw list emits a red gutter mark for a failed command" {
    var cells = [_]terminal.Cell{.{}} ** 2; // 2 cols × 1 row
    const marks = [_]terminal.RowPrompt{.{ .kind = .input, .exit = 1 }};
    const snapshot: terminal.RenderSnapshot = .{
        .size = .{ .cols = 2, .rows = 1 },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .cells = &cells,
        .prompt_marks = &marks,
        .dirty = .{ .start_row = 0, .end_row = 0 },
    };
    var draw_list = try buildDrawList(std.testing.allocator, snapshot);
    defer draw_list.deinit(std.testing.allocator);
    var found = false;
    for (draw_list.overlays) |o| switch (o) {
        .gutter => |g| {
            found = true;
            try std.testing.expect(!g.success); // exit 1 → 빨강
        },
        else => {},
    };
    try std.testing.expect(found);
}

test "draw list emits no cells when snapshot is clean" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // clean snapshot은 "renderer가 새로 그릴 셀이 없다"는 뜻이다.
    // 이 구분이 없으면 future frame loop가 불필요한 redraw를 계속 만들 수 있다.
    core.clearDirty();

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expect(draw_list.dirty == null);
    try std.testing.expectEqual(@as(usize, 0), draw_list.cells.len);
    try std.testing.expectEqual(@as(usize, 0), draw_list.overlays.len);
}

test "draw list keeps wide glyph metadata and skips continuation cells" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
    defer core.deinit();

    // 한글/CJK처럼 2칸을 차지하는 glyph는 하나의 draw command여야 한다.
    // continuation cell까지 그리면 backend가 같은 glyph를 두 번 그릴 수 있다.
    try core.write("A한B");

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 4), draw_list.cells.len);
    try std.testing.expectEqual(@as(u16, 1), draw_list.cells[1].col);
    try std.testing.expectEqual(@as(u21, '한'), draw_list.cells[1].codepoint);
    try std.testing.expectEqual(@as(u2, 2), draw_list.cells[1].width);
    try std.testing.expectEqual(@as(u16, 3), draw_list.cells[2].col);
    try std.testing.expectEqual(@as(u21, 'B'), draw_list.cells[2].codepoint);
}

test "draw list renders wide-render symbol (circled number) at 2 cells when next is blank, 1 when occupied" {
    // ③(U+2462)는 EAW Ambiguous(폭 1)지만 폰트가 ~2칸으로 그린다. 다음 셀이 비면 그릴 폭을 2칸으로 키워 온전히
    // 그린다(advance는 grid가 1로 유지 — Ghostty constraintWidth). 다음 셀이 차있으면 1칸(constrain이 축소·겹침 방지).
    {
        var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
        defer core.deinit();
        try core.write("③ X"); // ③ 다음 공백 → 2칸 렌더, 공백 흡수
        var dl = try buildDrawList(std.testing.allocator, core.snapshot());
        defer dl.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u21, 0x2462), dl.cells[0].codepoint);
        try std.testing.expectEqual(@as(u2, 2), dl.cells[0].width); // 공백 흡수 → 2칸 렌더
        try std.testing.expectEqual(@as(u16, 2), dl.cells[1].col); // col1(공백) 흡수 → 다음 emit은 col2의 X
        try std.testing.expectEqual(@as(u21, 'X'), dl.cells[1].codepoint);
    }
    {
        var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 5, .rows = 1 });
        defer core.deinit();
        try core.write("③X"); // ③ 다음 글자 점유 → 1칸 유지(겹침 방지)
        var dl = try buildDrawList(std.testing.allocator, core.snapshot());
        defer dl.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(u21, 0x2462), dl.cells[0].codepoint);
        try std.testing.expectEqual(@as(u2, 1), dl.cells[0].width); // 다음 셀 점유 → 1칸
        try std.testing.expectEqual(@as(u16, 1), dl.cells[1].col); // X는 col1(흡수 안 함)
        try std.testing.expectEqual(@as(u21, 'X'), dl.cells[1].codepoint);
    }
}

test "draw list carries style and combining mark for font layout" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // DrawList는 나중에 glyph shaping과 atlas upload의 입력이 된다. 그래서 화면에
    // 보이는 글자뿐 아니라 style과 combining mark도 같이 이동해야 한다.
    try core.write("e\u{0301}");
    core.cells[0].style = .{
        .foreground = .{ .indexed = 2 },
        .background = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .underline = true,
    };

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u21, 'e'), draw_list.cells[0].codepoint);
    try std.testing.expectEqual(@as(?u21, 0x0301), draw_list.cells[0].combining);
    try std.testing.expectEqual(terminal.Color{ .indexed = 2 }, draw_list.cells[0].style.foreground);
    try std.testing.expectEqual(terminal.Color{ .rgb = .{ .r = 1, .g = 2, .b = 3 } }, draw_list.cells[0].style.background);
    try std.testing.expect(draw_list.cells[0].style.underline);
    try std.testing.expectEqual(@as(usize, 2), draw_list.overlays.len);
    try std.testing.expectEqual(LineKind.underline, draw_list.overlays[0].line.kind);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].line.row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].line.col);
    try std.testing.expectEqual(@as(u2, 1), draw_list.overlays[0].line.width);
    try std.testing.expectEqual(terminal.Color{ .indexed = 2 }, draw_list.overlays[0].line.color);
    // The cursor overlay is appended after the cell loop, so it trails the
    // underline. Pin its tag and position so a regression that drops or
    // misplaces it (e.g. a second underline instead of the cursor) fails here.
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[1].cursor.row);
    try std.testing.expectEqual(@as(u16, 1), draw_list.overlays[1].cursor.col);
}

test "G1 underline color: underline overlay uses underline_color, strikethrough keeps fg" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();
    try core.write("a");
    // 전경 indexed 2, underline_color rgb(9,8,7), underline+strikethrough 켜짐.
    core.cells[0].style = .{
        .foreground = .{ .indexed = 2 },
        .underline = true,
        .strikethrough = true,
        .underline_color = .{ .rgb = .{ .r = 9, .g = 8, .b = 7 } },
    };
    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);
    // overlay 순서: underline, strikethrough(, cursor). underline은 underline_color, strikethrough는 전경색.
    try std.testing.expectEqual(LineKind.underline, draw_list.overlays[0].line.kind);
    try std.testing.expectEqual(terminal.Color{ .rgb = .{ .r = 9, .g = 8, .b = 7 } }, draw_list.overlays[0].line.color);
    try std.testing.expectEqual(LineKind.strikethrough, draw_list.overlays[1].line.kind);
    try std.testing.expectEqual(terminal.Color{ .indexed = 2 }, draw_list.overlays[1].line.color);
}

test "draw list suppresses cursor overlay when its row is outside the dirty range" {
    // renderer-strategy.md의 계약: cursor overlay는 dirty row에 cursor가 포함될
    // 때만 생성한다. TerminalCore는 cursor 이동 시 그 row를 항상 dirty로 만들지만,
    // 다른 row만 바뀐 frame에서 cursor를 다시 그리면 redraw가 낭비된다. core 경로로는
    // cursor row가 빠진 dirty를 만들 수 없어 snapshot을 직접 구성해 guard를 고정한다.
    var cells = [_]terminal.Cell{.{}} ** 4;
    const snapshot: terminal.RenderSnapshot = .{
        .size = .{ .cols = 2, .rows = 2 },
        .cursor = .{ .row = 1, .col = 0, .visible = true },
        .cells = &cells,
        .dirty = .{ .start_row = 0, .end_row = 0 },
    };

    var draw_list = try buildDrawList(std.testing.allocator, snapshot);
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), draw_list.cells.len);
    try std.testing.expectEqual(@as(usize, 0), draw_list.overlays.len);
}

test "draw list emits cursor overlay for cursor-only dirty movement" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 1 });
    defer core.deinit();

    // Carriage return does not change glyph cells, but it moves the cursor.
    // The DrawList must expose that as an overlay command so a future Metal
    // backend does not bake cursor pixels into glyph atlas entries.
    try core.write("AB");
    core.clearDirty();
    try core.write("\r");

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 1), draw_list.overlays.len);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].cursor.row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].cursor.col);
}

test "draw list emits a strikethrough overlay for SGR 9 cells, independent of underline" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // SGR 9 strikethrough는 underline과 같은 draw-time overlay지만 독립 비트다 — 둘 다(9;4) 켜면
    // 셀 하나가 underline overlay와 strikethrough overlay를 각각 낸다(전경색을 색으로 캐리).
    try core.write("\x1b[9;4mA");

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    var underlines: usize = 0;
    var strikes: usize = 0;
    for (draw_list.overlays) |o| switch (o) {
        .line => |l| switch (l.kind) {
            .underline => {
                underlines += 1;
                try std.testing.expectEqual(@as(u16, 0), l.col);
            },
            .strikethrough => {
                strikes += 1;
                try std.testing.expectEqual(@as(u16, 0), l.col);
                try std.testing.expectEqual(@as(u2, 1), l.width);
            },
            .overline, .double_underline => {},
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), underlines);
    try std.testing.expectEqual(@as(usize, 1), strikes);
}

test "draw list emits an overline overlay for SGR 53 cells, independent of strikethrough and underline" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // SGR 53 overline은 underline·strikethrough와 독립 비트다 — 셋 다(4;9;53) 켜면 셀 하나가
    // underline·strikethrough·overline overlay를 각각 낸다(전경색 캐리).
    try core.write("\x1b[4;9;53mA");

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    var underlines: usize = 0;
    var strikes: usize = 0;
    var overlines: usize = 0;
    for (draw_list.overlays) |o| switch (o) {
        .line => |l| switch (l.kind) {
            .underline => underlines += 1,
            .strikethrough => strikes += 1,
            .overline => {
                overlines += 1;
                try std.testing.expectEqual(@as(u16, 0), l.col);
                try std.testing.expectEqual(@as(u2, 1), l.width);
            },
            .double_underline => {},
        },
        else => {},
    };
    try std.testing.expectEqual(@as(usize, 1), underlines);
    try std.testing.expectEqual(@as(usize, 1), strikes);
    try std.testing.expectEqual(@as(usize, 1), overlines);
}

test "G1 double underline: SGR 21 sets underline_double and emits underline + double_underline overlays" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();
    try core.write("\x1b[21mA"); // SGR 21 = double underline
    try std.testing.expect(core.cells[0].style.underline);
    try std.testing.expect(core.cells[0].style.underline_double);

    var dl = try buildDrawList(std.testing.allocator, core.snapshot());
    defer dl.deinit(std.testing.allocator);
    var has_underline = false;
    var has_double = false;
    for (dl.overlays) |o| switch (o) {
        .line => |l| switch (l.kind) {
            .underline => has_underline = true,
            .double_underline => has_double = true,
            else => {},
        },
        else => {},
    };
    // double underline은 하단 선(.underline)과 둘째 선(.double_underline) 2개를 낸다.
    try std.testing.expect(has_underline);
    try std.testing.expect(has_double);

    // SGR 24는 둘 다 끈다.
    try core.write("\x1b[24mB");
    try std.testing.expect(!core.cells[1].style.underline);
    try std.testing.expect(!core.cells[1].style.underline_double);
}
