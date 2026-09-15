const std = @import("std");
const terminal = @import("../terminal.zig");
const width = @import("../width.zig");

/// 줄 오른쪽의 «그릴 것이 없는» 구간은 DrawList 에 싣지 않는다.
///
/// 왜: 터미널 브라우저처럼 본문이 통째로 kitty 이미지인 화면은 텍스트 셀이 사실상 비어 있는데, 한때
/// 행×열 전부를 CoreText 셰이퍼에 넘겨 **빈 칸을 셰이핑하는** 비용을 냈다(실측: 11842셀 빈 화면에
/// grid 3.3ms). 베이스는 Ghostty `font/shaper/run.zig` `RunIterator.next` 의 첫 동작 —
/// `Trim the right side of a row that might be empty` — 이고 코드는 maru 자체다.
///
/// 하이라이트는 이 trim 에 안 깨진다: 선택·검색 배경은 `metal_frame` 의 **격자 기반 pass** 가 칠하므로
/// DrawList 에 그 칸이 있든 없든 결과가 같다(한때 이 trim 이 줄 끝 선택을 지웠고, 그 회귀가 하이라이트를
/// 격자로 옮긴 계기였다). 경위는 docs/io-render-present.md §10.6.
/// 줄 끝 trim 후보인가 — «이 셀은 그려도 화면에 아무것도 안 남는가»를 보수적으로 판정한다.
///
/// 보수적인 이유: DrawCell 은 글리프만이 아니라 **셀 배경**도 낳는다. 그래서 배경이 기본이 아니거나
/// (reverse 로 전경이 배경이 되는 경우 포함) 장식선이 붙은 셀은 빼면 화면이 깨진다. 선택 영역·검색
/// 하이라이트·커서는 이 단계 **뒤에** CellColors/overlay 로 얹히므로, 이 실험 플래그를 제품으로 올릴
/// 선택·검색·커서는 이 단계 **뒤에** 얹히므로 여기서 볼 필요가 없다 — 앞의 둘은 격자 pass 가, 커서는
/// overlay 가 각각 자기 경로로 칠한다.
fn isTrimmableBlank(codepoint: u21, grapheme_id: u32, style: terminal.Style) bool {
    if (!(codepoint == 0 or codepoint == ' ')) return false;
    if (grapheme_id != 0) return false;
    if (style.background != .default) return false;
    if (style.reverse) return false;
    if (style.underline or style.underline_double or style.strikethrough or style.overline) return false;
    return true;
}

pub const DrawCell = struct {
    row: u16,
    col: u16,
    codepoint: u21,
    // grapheme cluster 본체(base 뒤 extra 코드포인트 — 악센트·VS16·NFD 한글 V/T·키캡·ZWJ)를
    // DrawList.grapheme_pool의 [offset, offset+count)로 가리킨다. count>0이면 CoreText 셰이퍼가 풀의
    // 코드포인트를 base 뒤에 모두 붙여 cluster 전체를 셰이핑한다(무손실). count==0이면 extra 없음.
    grapheme_offset: u32 = 0,
    grapheme_count: u16 = 0,
    width: u2 = 1,
    style: terminal.Style = .{},
};

/// 창 포커스 잃었을 때 커서 처리(renderer 중립 — app이 window_focused·config.cursor.unfocused로 정해 buildDrawList에
/// 넘긴다). normal=현행(채운 커서), hollow=빈 사각형 테두리, hidden=안 그림. config theme.UnfocusedCursor와 1:1이되
/// renderer는 config를 모르므로 별도 enum으로 둔다(경계 — terminal/config 의존 없이 snapshot+이 모드만 읽는다).
pub const CursorUnfocused = enum { normal, hollow, hidden };

pub const CursorOverlay = struct {
    row: u16,
    col: u16,
    visible: bool = true,
    // DECSCUSR 모양. 렌더러가 block(반전)/underline(하단 바)/bar(좌측 세로 바)로 투영한다.
    shape: terminal.CursorShape = .block,
    // 창 포커스 잃음 + cursor.unfocused=hollow일 때 true — 렌더러가 채운 커서 대신 **빈 사각형 테두리**(외곽선)로
    // 그린다(shape 무관). app이 window_focused·appearance.cursor.unfocused로 정한다(unfocused=hidden은 visible=false).
    hollow: bool = false,
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
    // DrawCell.grapheme_offset/count가 가리키는 cluster 본체 풀(base 제외한 extra 코드포인트, u32로
    // 노출 — ObjC ABI와 동형). CoreText 셰이퍼가 통째로 ObjC에 넘긴다. cluster 없는 셀이 대부분이라
    // 보통 비어 있다(append 비용 0). DrawList가 소유하고 deinit에서 free한다(snapshot 수명과 분리).
    grapheme_pool: []u32 = &.{},

    pub fn deinit(self: *DrawList, allocator: std.mem.Allocator) void {
        allocator.free(self.cells);
        allocator.free(self.overlays);
        if (self.grapheme_pool.len > 0) allocator.free(self.grapheme_pool);
        self.* = undefined;
    }
};

/// 포커스 정보 없는 호출용(테스트·기본) — 커서를 현행(normal)으로 그린다. 실제 app은 window_focused·
/// config.cursor.unfocused를 반영하려 buildDrawListWithUnfocused를 직접 부른다.
pub fn buildDrawList(allocator: std.mem.Allocator, snapshot: terminal.RenderSnapshot) !DrawList {
    return buildDrawListWithUnfocused(allocator, snapshot, .normal);
}

pub fn buildDrawListWithUnfocused(
    allocator: std.mem.Allocator,
    snapshot: terminal.RenderSnapshot,
    unfocused: CursorUnfocused,
) !DrawList {
    // DrawList는 GPU 명령이 아니라 renderer backend가 공유해서 소비할 중립 계약이다.
    // 여기서 PTY나 parser를 보지 않고 snapshot만 읽어야 Metal/WebGPU backend를
    // 나중에 바꿔도 terminal core를 다시 설계하지 않아도 된다.
    var cells: std.ArrayList(DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var overlays: std.ArrayList(DrawOverlay) = .empty;
    errdefer overlays.deinit(allocator);
    // grapheme cluster 본체 풀 — cluster가 있는 셀만 채운다(대부분 비어 있다). DrawCell이 offset/count로
    // 참조하고, CoreText 셰이퍼가 base 뒤에 붙여 cluster 전체를 셰이핑한다(단일 combining 손실 보정).
    var grapheme_pool: std.ArrayList(u32) = .empty;
    errdefer grapheme_pool.deinit(allocator);

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
                    // 줄 오른쪽의 그릴 것 없는 구간을 잘라낸다(위 isTrimmableBlank 주석).
                    //
                    // **DECSCNM(화면 반전)이면 자르지 않는다.** 반전 화면의 빈 칸은 「그릴 것 없는 칸」이 아니다 —
                    // 렌더러가 전경색 quad 로 칠해야 반전이 보인다(`packBackground` 의 `style.reverse != screen_reverse`).
                    // 단일 pane 에서는 clear color 도 전경색이라 자르는 게 안 드러나지만, split 의 **비활성** 반전
                    // pane 은 clear color 가 활성 pane 기준이라 잘린 칸이 정상 배경으로 비친다(/code-review 가 잡았다).
                    // 반전은 드물고 켜진 동안만 trim 을 포기하는 것이라 절감 손실은 없다.
                    var row_cols = col_count;
                    while (!snapshot.reverse_screen and row_cols > 0) : (row_cols -= 1) {
                        const last = snapshot.cells[index(snapshot.size, row, row_cols - 1)];
                        if (last.continuation) continue;
                        if (!isTrimmableBlank(last.codepoint, last.grapheme_id, last.style)) break;
                    }
                    for (0..row_cols) |col| {
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

                        // **kitty unicode placeholder 셀은 글자가 아니다** — 그 셀의 codepoint·전경색·결합문자는
                        // 「어느 이미지의 어느 타일을 여기에 놓아라」는 **좌표**다(kitty graphics protocol,
                        // "Unicode placeholders"). 텍스트로 넘기면 폰트에 없는 U+10EEEE 가 tofu 박스로 찍혀
                        // **화면이 통째로 쓰레기가 된다** — 실측(2026-09-15): tmux 안 terminal-browser 의 이미지가
                        // 원격 투영 상한에 막히자 그 pane 전체가 박스 문자로 덮였다. 이미지가 못 오는 것과
                        // 「그 자리에 쓰레기를 그리는 것」은 다른 결함이고, 뒤엣것이 이 자리다.
                        //
                        // 그림은 이 경로가 아니라 `metal_frame.buildGpuImages` 가 **snapshot.cells 를 직접 읽어**
                        // 타일 quad 로 만든다 — 그래서 여기서 지워도 이미지는 그대로 뜬다. 배경색은 남긴다
                        // (셀 배경은 텍스트가 아니라 그 칸의 칠이다).
                        const placeholder_cell = cell.codepoint == terminal.unicode_placeholder_codepoint;

                        // cluster 본체(grapheme_id가 있으면 store에서, 없으면 풀 미사용 → combining 폴백)를
                        // 풀에 적재하고 셀이 [offset, count)로 참조하게 한다. 셰이퍼가 base 뒤에 붙인다.
                        // placeholder 의 결합문자는 타일 좌표라 셰이퍼에 넘길 이유가 없다(셀 수만큼 헛일이다).
                        var g_offset: u32 = 0;
                        var g_count: u16 = 0;
                        if (!placeholder_cell and cell.grapheme_id != 0 and cell.grapheme_id <= snapshot.graphemes.len) {
                            const cluster = snapshot.graphemes[cell.grapheme_id - 1];
                            g_offset = @intCast(grapheme_pool.items.len);
                            for (cluster) |cp| try grapheme_pool.append(allocator, @as(u32, cp));
                            g_count = @intCast(cluster.len);
                        }

                        cells.appendAssumeCapacity(.{
                            .row = @intCast(row),
                            .col = @intCast(col),
                            .codepoint = if (placeholder_cell) ' ' else cell.codepoint,
                            .grapheme_offset = g_offset,
                            .grapheme_count = g_count,
                            .width = render_width,
                            .style = cell.style,
                        });

                        // 텍스트 장식선(underline/strikethrough/overline)은 draw-time overlay다 —
                        // glyph cell 밖에 둬 atlas가 "A"와 "밑줄 A"를 따로 캐시하지 않게 한다. 셋은
                        // 독립 비트라 한 셀이 셋을 다 낼 수 있고, kind만 다른 같은 모양이라 한 헬퍼로 낸다.
                        if (cell.style.underline) {
                            // double underline은 하단 텍스트 선(reserved 9) + 둘째 선(reserved 7, 위)으로 2개 방출 —
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
            overlays.appendAssumeCapacity(.{
                .cursor = .{
                    .row = snapshot.cursor.row,
                    .col = snapshot.cursor.col,
                    .visible = snapshot.cursor.visible and unfocused != .hidden, // hidden: 포커스 잃으면 안 그림
                    .shape = snapshot.cursor_shape,
                    .hollow = unfocused == .hollow, // hollow: 채운 블록 대신 외곽선 테두리
                },
            });
        }
    }

    return .{
        .size = snapshot.size,
        .cursor = snapshot.cursor,
        .dirty = snapshot.dirty,
        .cells = try cells.toOwnedSlice(allocator),
        .overlays = try overlays.toOwnedSlice(allocator),
        .grapheme_pool = try grapheme_pool.toOwnedSlice(allocator),
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
    // 셀은 'A' 하나뿐이다 — 뒤 3칸은 그릴 것이 없어 줄끝 trim이 잘라낸다(isTrimmableBlank).
    // 그 칸에 선택·검색이 걸려도 하이라이트는 metal_frame 의 격자 pass 가 칠하므로 화면은 온전하다.
    try std.testing.expectEqual(@as(usize, 1), draw_list.cells.len);
    try std.testing.expectEqual(@as(u16, 0), draw_list.cells[0].row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.cells[0].col);
    try std.testing.expectEqual(@as(u21, 'A'), draw_list.cells[0].codepoint);
    try std.testing.expectEqual(@as(u16, 0), draw_list.dirty.?.start_row);
    try std.testing.expectEqual(@as(u16, 0), draw_list.dirty.?.end_row);
    try std.testing.expectEqual(@as(usize, 1), draw_list.overlays.len);
    try std.testing.expectEqual(@as(u16, 0), draw_list.overlays[0].cursor.row);
    try std.testing.expectEqual(@as(u16, 1), draw_list.overlays[0].cursor.col);
}

test "buildDrawListWithUnfocused: hollow/hidden이 cursor overlay에 반영 (F1-4b-2)" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 4, .rows = 2 });
    defer core.deinit();
    try core.write("A"); // 커서가 보이는 상태로

    // normal(포커스 있음/block): 현행 — hollow 아님, visible.
    var normal_dl = try buildDrawListWithUnfocused(std.testing.allocator, core.snapshot(), .normal);
    defer normal_dl.deinit(std.testing.allocator);
    try std.testing.expect(!normal_dl.overlays[0].cursor.hollow);
    try std.testing.expect(normal_dl.overlays[0].cursor.visible);

    // hollow: 외곽선 테두리 — hollow=true, 여전히 visible(그려짐).
    var hollow_dl = try buildDrawListWithUnfocused(std.testing.allocator, core.snapshot(), .hollow);
    defer hollow_dl.deinit(std.testing.allocator);
    try std.testing.expect(hollow_dl.overlays[0].cursor.hollow);
    try std.testing.expect(hollow_dl.overlays[0].cursor.visible);

    // hidden: 안 그림 — visible=false(hollow도 아님).
    var hidden_dl = try buildDrawListWithUnfocused(std.testing.allocator, core.snapshot(), .hidden);
    defer hidden_dl.deinit(std.testing.allocator);
    try std.testing.expect(!hidden_dl.overlays[0].cursor.visible);
    try std.testing.expect(!hidden_dl.overlays[0].cursor.hollow);

    // 기본 buildDrawList(2-arg)는 normal과 동일(테스트·기본 경로).
    var default_dl = try buildDrawList(std.testing.allocator, core.snapshot());
    defer default_dl.deinit(std.testing.allocator);
    try std.testing.expect(!default_dl.overlays[0].cursor.hollow);
    try std.testing.expect(default_dl.overlays[0].cursor.visible);
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

    // A·한·B 셋. 옛 기대값 4는 'B' 뒤 빈칸 하나를 포함한 것이었는데, 줄끝 trim 이 그것을 잘라낸다.
    // wide glyph 계약(continuation 을 안 낸다)은 그대로다 — 아래 col/width 단언이 그것을 고정한다.
    try std.testing.expectEqual(@as(usize, 3), draw_list.cells.len);
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

test "draw list carries style and grapheme cluster for font layout" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    // DrawList는 나중에 glyph shaping과 atlas upload의 입력이 된다. 그래서 화면에 보이는 글자뿐 아니라
    // style과 grapheme cluster 본체(grapheme_pool)도 같이 이동해야 한다(combining mark는 풀에 담긴다).
    try core.write("e\u{0301}");
    core.screen.cells[0].style = .{
        .foreground = .{ .indexed = 2 },
        .background = .{ .rgb = .{ .r = 1, .g = 2, .b = 3 } },
        .underline = true,
    };

    var draw_list = try buildDrawList(std.testing.allocator, core.snapshot());
    defer draw_list.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(u21, 'e'), draw_list.cells[0].codepoint);
    // combining mark는 grapheme_pool에 cluster 본체로 실린다 — DrawCell이 [offset, count)로 참조.
    try std.testing.expectEqual(@as(u16, 1), draw_list.cells[0].grapheme_count);
    try std.testing.expectEqual(@as(u32, 0x0301), draw_list.grapheme_pool[draw_list.cells[0].grapheme_offset]);
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
    core.screen.cells[0].style = .{
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

    // 두 칸 다 빈 셀이라 줄끝 trim 이 잘라낸다 — 이 테스트가 고정하려는 것은 **커서 overlay 억제**이고
    // (아래 overlays.len==0), 셀 수는 그 계약과 무관하다.
    try std.testing.expectEqual(@as(usize, 0), draw_list.cells.len);
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
    try std.testing.expect(core.screen.cells[0].style.underline);
    try std.testing.expect(core.screen.cells[0].style.underline_double);

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
    try std.testing.expect(!core.screen.cells[1].style.underline);
    try std.testing.expect(!core.screen.cells[1].style.underline_double);
}

// ============================================================================
// [적대적 검증] 줄끝 trim 의 안전 주장을 «깨뜨리려고» 쓴 테스트들.
//
// 주장을 확인하는 테스트가 아니라 **반증을 시도하는** 테스트다. 통과하면 그 주장이 살아남은 것이고,
// 실패하면 주장이 틀린 것이다. 커서·배경·장식이 잘리지 않는다는 계약의 단일 출처가 이 파일이다.
// ============================================================================

test "[적대] 줄끝 trim: 커서가 줄 끝 빈 칸에 있어도 cursor overlay 가 사라지지 않는다" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 20, .rows = 2 });
    defer core.deinit();
    try core.write("AB"); // 커서는 col=2 — 그 뒤 18칸이 전부 빈 칸이라 trim 대상이다

    var dl = try buildDrawList(std.testing.allocator, core.snapshot());
    defer dl.deinit(std.testing.allocator);

    // 커서 칸(col=2)은 빈 칸이라 cells 에서는 잘려 나가야 한다(= trim 이 실제로 일어났다).
    for (dl.cells) |c| {
        try std.testing.expect(!(c.row == 0 and c.col == 2));
    }
    // 그런데 커서 overlay 는 살아 있어야 한다 — 이게 「커서는 안전하다」의 반증 시도다.
    var found_cursor = false;
    for (dl.overlays) |o| switch (o) {
        .cursor => |cur| {
            found_cursor = true;
            try std.testing.expectEqual(@as(u16, 0), cur.row);
            try std.testing.expectEqual(@as(u16, 2), cur.col);
            try std.testing.expect(cur.visible);
        },
        else => {},
    };
    try std.testing.expect(found_cursor);
}

test "[적대] 줄끝 trim: 배경색이 있는 빈 칸은 잘리지 않는다" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 1 });
    defer core.deinit();
    // 빨간 배경으로 공백 세 칸을 칠한다 — 글자는 없지만 화면에는 색이 남아야 한다.
    try core.write("\x1b[41m   \x1b[0m");

    var dl = try buildDrawList(std.testing.allocator, core.snapshot());
    defer dl.deinit(std.testing.allocator);

    var colored: usize = 0;
    for (dl.cells) |c| {
        if (c.style.background != .default) colored += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), colored);
}

test "[적대] 줄끝 trim: 밑줄·취소선·윗줄·reverse 가 붙은 빈 칸은 잘리지 않는다" {
    const cases = [_][]const u8{
        "\x1b[4m \x1b[0m", // underline
        "\x1b[9m \x1b[0m", // strikethrough
        "\x1b[53m \x1b[0m", // overline
        "\x1b[7m \x1b[0m", // reverse
    };
    for (cases) |seq| {
        var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 10, .rows = 1 });
        defer core.deinit();
        try core.write(seq);

        var dl = try buildDrawList(std.testing.allocator, core.snapshot());
        defer dl.deinit(std.testing.allocator);

        // 장식이 붙은 그 한 칸은 반드시 남아 있어야 한다(안 남으면 화면에서 장식이 사라진다).
        try std.testing.expect(dl.cells.len >= 1);
        try std.testing.expectEqual(@as(u16, 0), dl.cells[0].col);
    }
}

test "[적대] 줄끝 trim: 글자로 꽉 찬 줄은 한 칸도 잘리지 않는다" {
    // trim 이 「자를 것이 없을 때 아무것도 안 자른다」를 고정한다. 마지막 칸까지 글자인 줄에서 한 칸이라도
    // 사라지면 화면 오른쪽 끝 글자가 통째로 빠진다.
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 1 });
    defer core.deinit();
    try core.write("ABCDEFGH");

    var dl = try buildDrawList(std.testing.allocator, core.snapshot());
    defer dl.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 8), dl.cells.len);
    try std.testing.expectEqual(@as(u21, 'A'), dl.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'H'), dl.cells[7].codepoint);
    try std.testing.expectEqual(@as(u16, 7), dl.cells[7].col);
}

test "[적대] 줄끝 trim: 줄 중간 빈 칸은 자르지 않는다(오른쪽 끝만)" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 12, .rows = 1 });
    defer core.deinit();
    try core.write("A    B"); // 가운데 공백 4칸은 남고, B 뒤 6칸만 잘려야 한다

    var dl = try buildDrawList(std.testing.allocator, core.snapshot());
    defer dl.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 6), dl.cells.len); // col 0..5
    try std.testing.expectEqual(@as(u21, 'A'), dl.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'B'), dl.cells[5].codepoint);
}

test "[적대] 줄끝 trim: 16칸 줄에 글자 둘이면 두 칸만 남는다" {
    // 절감의 크기를 그대로 고정한다 — 14칸이 CoreText 셰이퍼에 안 간다. 이 칸들에 선택·검색이 걸려도
    // 하이라이트는 `metal_frame` 의 격자 pass 가 칠하므로 화면은 온전하다(그쪽 적대적 테스트가 고정).
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 16, .rows = 1 });
    defer core.deinit();
    try core.write("hi");

    var dl = try buildDrawList(std.testing.allocator, core.snapshot());
    defer dl.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 2), dl.cells.len);
    try std.testing.expectEqual(@as(u21, 'h'), dl.cells[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'i'), dl.cells[1].codepoint);
}

test "[적대] 줄끝 trim: DECSCNM(CSI ?5h) 반전 화면에서는 빈 칸을 자르지 않는다" {
    // /code-review 가 잡은 회귀. 반전 화면의 빈 칸은 렌더러가 **전경색 quad** 로 칠해야 반전이 보이는데,
    // trim 이 그 칸을 빼면 quad 가 없어 clear color 가 비친다 — split 의 비활성 반전 pane 은 clear color 가
    // 활성 pane 기준이라 오른쪽·빈 줄이 정상 배경으로 남는다. 반전이 켜지면 trim 이 통째로 꺼져야 한다.
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 8, .rows = 2 });
    defer core.deinit();
    try core.write("AB");

    // 반전 전: 'A','B' 두 칸만(줄끝 trim, 둘째 줄은 통째로 빈 줄).
    {
        var dl = try buildDrawList(std.testing.allocator, core.snapshot());
        defer dl.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), dl.cells.len);
    }
    // 반전 후: 두 줄 × 8칸 = 16칸 전부 실려야 한다(옛 동작 그대로).
    try core.write("\x1b[?5h");
    try std.testing.expect(core.reverseScreen());
    {
        var dl = try buildDrawList(std.testing.allocator, core.snapshot());
        defer dl.deinit(std.testing.allocator);
        try std.testing.expect(dl.dirty != null);
        try std.testing.expectEqual(@as(usize, 16), dl.cells.len);
    }
    // 반전을 끄면 다시 잘린다.
    try core.write("\x1b[?5l");
    {
        var dl = try buildDrawList(std.testing.allocator, core.snapshot());
        defer dl.deinit(std.testing.allocator);
        try std.testing.expectEqual(@as(usize, 2), dl.cells.len);
    }
}

test "TBPROBE kitty unicode placeholder 셀은 텍스트로 새지 않는다 — 글자도 결합문자도 넘기지 않는다" {
    // **회귀 판정**(2026-09-15). placeholder 셀의 codepoint·전경색·결합문자는 글자가 아니라 「어느
    // 이미지의 어느 타일을 여기 놓아라」는 좌표다(kitty graphics protocol, "Unicode placeholders").
    // 그것을 셰이퍼에 넘기면 폰트에 없는 U+10EEEE 가 tofu 박스로 찍혀 화면이 통째로 덮인다 —
    // 실측(2026-09-15): tmux 안 terminal-browser 의 이미지가 원격 투영 상한에 막히자 그 pane 전체가
    // 박스 문자로 채워졌다. 이미지가 못 오는 것과 그 자리에 쓰레기를 그리는 것은 **다른 결함**이고,
    // 이 판정자는 뒤엣것을 지킨다(이미지가 없어도 그 칸은 **빈 칸**이어야 한다).
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 2, .rows = 1 });
    defer core.deinit();

    // 전경색 rgb(0,0,7) = image_id 7. 결합문자 둘 = 타일 (0,0). 이미지는 **일부러 안 보낸다** —
    // 유실 상황에서 화면이 어떻게 되는지가 이 판정자의 대상이다.
    try core.write("\x1b[38;2;0;0;7m");
    var utf8: [8]u8 = undefined;
    var n = try std.unicode.utf8Encode(terminal.unicode_placeholder_codepoint, &utf8);
    try core.write(utf8[0..n]);
    n = try std.unicode.utf8Encode(0x0305, &utf8);
    try core.write(utf8[0..n]);
    n = try std.unicode.utf8Encode(0x0305, &utf8);
    try core.write(utf8[0..n]);
    try std.testing.expectEqual(terminal.unicode_placeholder_codepoint, core.screen.cells[0].codepoint); // 코어는 그대로 보관한다
    try std.testing.expect(core.screen.cells[0].grapheme_id != 0);

    var dl = try buildDrawList(std.testing.allocator, core.snapshot());
    defer dl.deinit(std.testing.allocator);
    var saw_cell = false;
    for (dl.cells) |c| {
        if (c.row != 0 or c.col != 0) continue;
        saw_cell = true;
        try std.testing.expectEqual(@as(u21, ' '), c.codepoint); // 글자로 새지 않는다
        try std.testing.expectEqual(@as(u16, 0), c.grapheme_count); // 타일 좌표를 셰이퍼에 넘기지 않는다
    }
    try std.testing.expect(saw_cell); // 셀 자체는 나온다 — 배경은 그 칸의 칠이라 남아야 한다
    // grapheme 풀에도 안 쌓인다 — 전면 이미지면 셀 수만큼 헛일이 된다(59x59 = 3481 셀).
    try std.testing.expectEqual(@as(usize, 0), dl.grapheme_pool.len);
}
