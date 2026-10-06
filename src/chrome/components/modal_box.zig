//! ModalBox — 중앙 모달 박스의 **공유 레이아웃 프리미티브**(디자인 시스템). notice(알림)·confirm(예/아니오 확인)·
//! 향후 모달이 같은 박스 기하를 재사용한다: 폭 clamp(전체 작업영역=사이드바·titlebar 제외, dock 포함), soft-lock 방지 가드, 중앙 배치,
//! 둥근 배경 quad + focus 테두리, 콘텐츠 셀 좌표 계산. 컴포넌트는 `layout`으로 Box(rect+콘텐츠 좌표)를 얻고, `frame`
//! 으로 배경/테두리를, `text`/`fillCells`/`centerX`/`rowY`로 콘텐츠를 그 안에 배치한다 — 클램프/중앙배치 로직을
//! 복붙하지 않고 한 곳(여기)에서만 둔다. State·handle(입력)·콘텐츠 구성(줄/버튼)은 각 컴포넌트가 소유한다.
//! 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");
const overlay_input = @import("overlay_input.zig"); // displayCols(EAW 표시폭) 공유 — 박스 폭을 placeText와 같은 폭 규약으로 잡는다
const text_layout = @import("../text_layout.zig"); // decodeCodepoint — 깨진 UTF-8 을 렌더러와 같은 단위로 걷는다

/// 이 박스가 그리는 레이어(최상위 모달). notice/confirm이 그대로 재노출한다.
pub const layer = draw.Layer.modal;

/// 박스에 그릴 한 줄(텍스트 + 색 역할). 보통 첫 줄=메시지(surface_fg), 이후=안내(muted_fg). notice가 view()에 쓴다.
pub const Line = struct { text: []const u8, role: tokens.ColorRole };

/// 배치된 모달 박스 — rect(backing px)와 콘텐츠 영역 좌표/메트릭. layout()이 반환하고, frame()·text()·fillCells()·
/// centerX()·rowY()가 이걸 받아 그 안에 콘텐츠를 둔다. inner_*는 사방 여백(modal_margin_cells열 + 1행)을 뺀 영역.
pub const Box = struct {
    rect: draw.Rect, // 박스 외곽(배경 quad/테두리)
    inner_x: i32, // 콘텐츠 좌측(px) = rect.x + 좌측 여백
    inner_y: i32, // 콘텐츠 상단(px) = rect.y + 위 여백 한 줄
    inner_cols: u32, // 콘텐츠 가로 칸 수(좌우 여백 제외) — 중앙 정렬 계산 기준
    cw: u32,
    ch: u32,
};

/// 콘텐츠 크기(셀 단위)로 박스 rect·중앙배치·폭 clamp·soft-lock 가드를 계산한다(**기하 단일 출처**). null=생략
/// (term_cols==0, 작업영역이 한 셀보다 좁음 — 중앙배치 뺄셈 언더플로 방지). 박스는 콘텐츠 사방에 여백
/// (좌우 modal_margin_cells열 + 위아래 1행)을 둔다. 폭은 **전체 작업영역(terminal+divider+dock)으로 clamp**한다 — 넘으면
/// 사이드바 침범/우측 오버플로. content_cols는 호출자가 **EAW 표시폭**(overlay_input.displayCols, 한글/CJK=2칸)으로
/// 재서 넘겨야 placeText 배치 폭과 맞아 한글이 안 잘린다(코드포인트 수로 재면 2배 과소측정돼 클리핑).
pub fn layout(content_cols: u32, content_rows: u32, p: props.ChromeProps, tk: *const tokens.Tokens) ?Box {
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const workspace = props.workspaceRect(m);
    if (workspace.w == 0 or workspace.h == 0) return null;
    const term_w_px = workspace.w;
    const term_cols = term_w_px / cw;
    if (term_cols == 0) return null;
    // C4b 패딩: rich lowering이 배경 quad를 ±pad 확장하므로, 그만큼 줄인 가용 칸으로 clamp(tui=0이면 무변화).
    const pad: u32 = p.shape.modal_padding_px;
    const avail_cols = (term_w_px -| 2 * pad) / cw;
    const margin = tk.space.modal_margin_cells;
    const box_cols = @max(@min(content_cols + 2 * margin, avail_cols), 1);
    const box_w = box_cols * cw;
    const box_h = (content_rows + 2) * ch; // 위/아래 여백 한 줄씩 + 콘텐츠 행
    const x = @as(i32, @intCast(workspace.x)) + @as(i32, @intCast((term_w_px - box_w) / 2));
    // 세로 중앙. 단 box_h가 뷰포트보다 크면(예: 세팅 섹션이 많고 창이 짧음) 중앙값이 음수가 돼 제목/상단이 화면 위로
    // 잘렸다(리뷰 #823) — y를 0 이상으로 clamp해 상단을 항상 보이게 한다(하단 초과분은 framebuffer가 클립, 네비
    // 스크롤은 후속). 폭 clamp(box_cols)와 같은 "모달을 화면 안에" 취지.
    const y = @as(i32, @intCast(workspace.y)) + @max(@as(i32, 0), @divTrunc(@as(i32, @intCast(workspace.h)) - @as(i32, @intCast(box_h)), 2));
    return .{
        .rect = .{ .x = x, .y = y, .w = box_w, .h = box_h },
        .inner_x = x + @as(i32, @intCast(margin * cw)),
        .inner_y = y + @as(i32, @intCast(ch)),
        .inner_cols = box_cols -| 2 * margin,
        .cw = cw,
        .ch = ch,
    };
}

/// 박스 배경 quad + focus 테두리를 emit한다(notice/confirm 공유). tui(corner/border=0)면 셀 배경 + Op.border 셀,
/// rich(>0)면 둥근 quad + quad 테두리. 콘텐츠(text/fillCells)는 호출자가 이 뒤에 emit해 그 위에 그려진다.
pub fn frame(box: Box, p: props.ChromeProps, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const bg_r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    // 외곽선(별도 .border op)은 두지 않는다 — tui에서 박스보다 밝은 외곽선이 색이 튀어 어색했다(사용자 피드백).
    // tui(bw=0)는 외곽선 없는 박스 배경(surface_bg)만이고 화면과는 배경 밝기 차이로 구분된다. rich(bw>0)는 quad가
    // 둥근 모서리 + 얇은 **focus_accent 테두리** + 그림자로 떠 보이게 한다(rich 외곽선은 quad의 border_widths가 그린다).
    // 테두리 role = focus_accent(모달 버튼 [확인]과 같은 톤 — 사용자 요청 "모달 테두리를 닫기 버튼 색 톤으로"). 중립 테마는
    // focus_accent가 옅은 중립이라 은은한 외곽선, accent를 준 테마(dark_pink 등)는 그 accent 톤 외곽선으로 버튼과 코히어런트.
    try out.append(arena, .{ .quad = .{ .rect = box.rect, .fill_role = .surface_bg, .corner_radii = .{ bg_r, bg_r, bg_r, bg_r }, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent } });
}

/// 콘텐츠 row(0-based) 상단 y(px). 콘텐츠 영역 inner_y에서 row행 아래.
pub fn rowY(box: Box, row: u32) i32 {
    return box.inner_y + @as(i32, @intCast(row)) * @as(i32, @intCast(box.ch));
}

/// 콘텐츠 영역 안에서 `cols`칸 폭 콘텐츠를 가로 중앙 정렬한 좌측 x(px). cols가 inner_cols보다 크면 0 오프셋(좌측).
pub fn centerX(box: Box, cols: u32) i32 {
    return box.inner_x + @as(i32, @intCast((box.inner_cols -| cols) / 2 * box.cw));
}

/// (x, row) 위치에 텍스트 한 조각을 emit한다. x는 호출자가 centerX/inner_x로 정한다. runs는 arena 소유.
pub fn text(box: Box, x: i32, row: u32, label: []const u8, role: tokens.ColorRole, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    const runs = try arena.alloc(draw.Run, 1);
    runs[0] = .{ .text = label };
    try out.append(arena, .{ .text = .{ .origin = .{ .x = x, .y = rowY(box, row) }, .runs = runs, .role = role } });
}

/// (x, row)부터 `cols`칸을 배경 색(role)으로 채운다 — 버튼/하이라이트 배경. 텍스트보다 **먼저** emit해야 글자가
/// 그 위에 그려진다(painter order). rich 모달에서도 surface_bg가 아닌 배경이라 평탄화가 skip하지 않는다.
pub fn fillCells(box: Box, x: i32, row: u32, cols: u32, role: tokens.ColorRole, arena: std.mem.Allocator, out: *std.ArrayList(draw.Op)) !void {
    try out.append(arena, .{ .fill = .{ .rect = .{ .x = x, .y = rowY(box, row), .w = cols * box.cw, .h = box.ch }, .role = role } });
}

/// 한 줄이 차지할 수 있는 줄 수 상한. 브라우저 권한 확인처럼 URL 이 그대로 들어간 메시지는 길이에 끝이 없다 —
/// 상한이 없으면 상자가 창을 덮는다. 넘치면 마지막 줄이 「…」로 끝난다.
pub const max_wrap_rows: u32 = 6;
pub const ellipsis = "…";

pub const Wrapped = struct { rows: u32, truncated: bool };

/// 줄바꿈(`\n`)으로 나눈 조각 중 가장 넓은 것의 표시 폭 — 상자 폭을 이것으로 잰다. 메시지 전체로 재면 `\n` 이
/// 섞인 문구(LSP 오류 메시지가 그대로 끼는 notice)가 줄은 짧아도 상자만 작업영역 폭까지 넓어졌다.
pub fn widestLineCols(message: []const u8) u32 {
    var widest: u32 = 0;
    var it = std.mem.splitScalar(u8, message, '\n');
    while (it.next()) |seg| widest = @max(widest, overlay_input.displayCols(std.mem.trim(u8, seg, " \r")));
    return widest;
}

/// 메시지를 `cols` 칸(표시 폭 — 한글 2칸) 줄로 나눠 `out` 에 담는다. 공백에서 끊고, 공백 없이 긴 토큰(URL·경로·
/// 실행 파일 이름)은 글자 경계에서 자른다. 줄이 `out.len` 을 넘으면 마지막 줄을 「…」 자리만큼 줄이고 truncated.
/// 슬라이스는 message 를 빌린다(할당 없음 — view 와 hitTest 가 프레임마다 부른다). 빈 메시지도 한 줄(빈 줄)이다.
/// confirm(메시지)과 notice(`view`)가 함께 쓴다 — 줄바꿈 규칙을 두 벌 두면 한쪽이 낡는다.
pub fn wrapLine(message: []const u8, cols: u32, out: *[max_wrap_rows][]const u8) Wrapped {
    if (cols == 0) {
        out[0] = message; // 상자가 한 칸도 없다 — 나눌 수 없으니 예전처럼 한 줄(호출자가 상자를 생략하는 갈래와 같다)
        return .{ .rows = 1, .truncated = false };
    }
    const ellipsis_cols = overlay_input.displayCols(ellipsis);
    var rows: u32 = 0;
    var rest = std.mem.trim(u8, message, " ");
    while (rest.len > 0) {
        const last_slot = rows + 1 == max_wrap_rows;
        // 마지막 자리에서 다 안 들어가면 「…」 를 붙일 자리를 남긴다 — 먼저 전부 들어가는지 보고, 아니면 줄인 폭으로 다시.
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        // `\r\n` 은 줄바꿈 하나다 — `\r` 을 줄 안의 한 칸으로 세면 딱 맞는 줄의 마지막 낱말이 다음 줄로 밀렸다.
        const seg_end = if (nl) |n| (if (n > 0 and rest[n - 1] == '\r') n - 1 else n) else rest.len;
        // 「전부 들어간다」 = 이 줄이 폭 안이고 그 뒤에 **남는 글자가 없다**. 메시지 끝의 줄바꿈 하나 때문에 마지막 자리에서
        // 들어가는 줄을 「…」 자리만큼 잘라 내지 않는다.
        const nothing_after = if (nl) |n| std.mem.trim(u8, rest[n + 1 ..], " \r\n").len == 0 else true;
        const full_fits = overlay_input.displayCols(rest[0..seg_end]) <= cols and nothing_after;
        const limit = if (last_slot and !full_fits) cols -| ellipsis_cols else cols;
        var width: u32 = 0;
        var fit_end: usize = 0;
        var last_space: ?usize = null;
        var i: usize = 0;
        while (i < seg_end) {
            // 렌더러(`placeText` — `text_layout.decodeCodepoint`)와 같은 단위로 걷는다. lead 바이트의 길이로만 묶으면 깨진
            // 바이트 뒤의 온전한 글자가 그 덩어리에 먹혀, 줄이 그 글자 **중간**에서 끊겼다.
            const end = @min(i + text_layout.decodeCodepoint(rest, i).advance, seg_end);
            const w = overlay_input.displayCols(rest[i..end]);
            if (width + w > limit) break;
            width += w;
            if (rest[i] == ' ') last_space = i;
            i = end;
            fit_end = i;
        }
        var line_end = fit_end;
        var next = fit_end;
        if (fit_end < seg_end) {
            if (rest[fit_end] == ' ') {
                next = fit_end + 1; // 넘친 글자가 공백이면 여기서 딱 끊긴다
            } else if (last_space) |sp| {
                if (sp > 0) {
                    line_end = sp;
                    next = sp + 1;
                }
            }
            if (line_end == 0) {
                // 첫 글자부터 폭을 넘는다(아주 좁은 상자의 2칸 글자) — 그 글자 하나를 한 줄로 내 무한 반복을 막는다.
                line_end = @min(text_layout.decodeCodepoint(rest, 0).advance, seg_end);
                next = line_end;
            }
        } else if (nl) |n| {
            next = n + 1; // 줄바꿈 문자(`\r\n` 이면 둘 다)까지 먹는다
        }
        out[rows] = std.mem.trimEnd(u8, rest[0..line_end], " \r"); // CRLF 의 \r 은 칸을 차지하는 글자로 남기지 않는다
        rows += 1;
        rest = std.mem.trimStart(u8, rest[next..], " ");
        if (rows == max_wrap_rows) return .{ .rows = rows, .truncated = rest.len > 0 };
    }
    if (rows == 0) {
        out[0] = "";
        rows = 1;
    }
    return .{ .rows = rows, .truncated = false };
}

/// lines를 중앙 모달 박스로 그린다(notice용 — 줄 텍스트만, 좌측 정렬). 빈 lines면 무동작(호출자 열림 가드).
/// 박스 기하는 layout/frame 단일 출처에 위임한다. ops·runs 슬라이스는 호출자가 준 frame arena가 소유한다.
pub fn view(
    lines: []const Line,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (lines.len == 0) return;
    var content_cols: u32 = 0;
    for (lines) |ln| content_cols = @max(content_cols, widestLineCols(ln.text)); // EAW 표시폭(placeText와 동일 규약)
    // 폭은 행 수와 무관하다 — 한 행으로 재서 상자 안쪽 폭을 얻고, 그 폭으로 줄마다 나눈 뒤 실제 행 수로 다시 잰다.
    // 안 나누면 작업영역보다 긴 줄(host 연결 실패 안내처럼 원인 코드가 끼는 notice)이 상자 밖으로 넘쳐 창 가장자리에서
    // 잘렸다(2026-10-06 실제 앱 캡처). 안쪽 폭에 들어가는 줄은 한 줄 그대로다(앞뒤 공백을 걷고 `\n` 에서 나누는 것 외에는).
    // 규칙은 confirm 과 같은 `wrapLine`.
    const width_probe = layout(content_cols, 1, p, tk) orelse return;
    const Piece = struct { text: []const u8, role: tokens.ColorRole };
    var pieces: std.ArrayList(Piece) = .empty;
    for (lines) |ln| {
        var wrapped_lines: [max_wrap_rows][]const u8 = undefined;
        const w = wrapLine(ln.text, width_probe.inner_cols, &wrapped_lines);
        for (wrapped_lines[0..w.rows], 0..) |part, i| {
            const last_cut = w.truncated and i + 1 == w.rows;
            const shown = if (last_cut) try std.fmt.allocPrint(arena, "{s}{s}", .{ part, ellipsis }) else part;
            try pieces.append(arena, .{ .text = shown, .role = ln.role });
        }
    }
    const box = layout(content_cols, @intCast(pieces.items.len), p, tk) orelse return;
    try frame(box, p, arena, out);
    for (pieces.items, 0..) |piece, i| try text(box, box.inner_x, @intCast(i), piece.text, piece.role, arena, out);
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 공유 박스 기하의 엣지케이스(soft-lock 가드·폭 clamp·rich 패딩 침범 방지)를 한 곳에서 증명한다 — notice/confirm은
// 이 view에 줄만 넘기므로, 여기서 기하를 검증하면 두 컴포넌트가 같은 보장을 받는다.

test "modal_box: lines 0이면 ops 0, 1줄이면 quad+text(2), 2줄이면 +text(3)" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 800,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    try view(&.{}, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // 빈 줄 → 무동작

    try view(&.{.{ .text = "한 줄", .role = .surface_fg }}, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .text);
    const h1 = out.items[0].quad.rect.h;

    out.clearRetainingCapacity();
    try view(&.{ .{ .text = "메시지", .role = .surface_fg }, .{ .text = "안내", .role = .muted_fg } }, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len); // 2줄 → text 2개
    try std.testing.expect(out.items[2] == .text);
    try std.testing.expect(out.items[2].text.origin.y > out.items[1].text.origin.y); // 둘째 줄이 아래
    try std.testing.expect(out.items[0].quad.rect.h > h1); // 2줄 박스가 1줄보다 한 줄 큼
    try std.testing.expect(out.items[0].quad.rect.x >= 40); // 사이드바 오른쪽
}

test "modal_box: 한글(wide) 메시지는 EAW 표시폭만큼 박스를 넓힌다 — 코드포인트 수로 재면 잘리던 버그" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    // 넓은 창(clamp 안 걸림)이라 박스 폭은 콘텐츠 표시폭이 결정한다.
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 1200,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    const msg = "실행 중인 명령이 있습니다. 닫을까요?"; // 한글=2칸이라 표시폭 ≫ 코드포인트 수
    try view(&.{.{ .text = msg, .role = .surface_fg }}, p, &tk, arena, &out);
    const box_cols = out.items[0].quad.rect.w / 8; // cw=8
    const disp = overlay_input.displayCols(msg);
    const cps: u32 = @intCast(std.unicode.utf8CountCodepoints(msg) catch msg.len);
    try std.testing.expect(disp > cps); // 한글이라 표시폭 > 코드포인트 수(전제)
    // 박스 안쪽 폭(좌우 여백 제외)이 EAW 표시폭을 담아야 placeText가 안 자른다. 코드포인트 수로 쟀다면 box_cols가
    // disp보다 작아 텍스트가 박스 밖으로 넘쳐 잘렸다(이 테스트가 그 회귀를 막는다).
    try std.testing.expect(box_cols >= disp + 2 * tk.space.modal_margin_cells);
}

test "modal_box: 좁은 창(1~3칸)도 작은 박스를 그리되 term_cols==0이면 생략 (soft-lock 방지)" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    // term 영역 = 60 − 40 = 20px, cw=8 → term_cols=2.
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 40,
        .backing_width_px = 60,
        .backing_height_px = 600,
    } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    try view(&.{.{ .text = "긴 메시지를 넘침", .role = .surface_fg }}, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len); // 작아도 그린다(보여서 Esc 가능)
    const box = out.items[0].quad.rect;
    try std.testing.expect(box.w > 0 and box.w <= 20); // term 영역 안
    try std.testing.expect(box.x >= 40);

    out.clearRetainingCapacity();
    const narrow = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 40, .backing_width_px = 45, .backing_height_px = 600 } };
    try view(&.{.{ .text = "x", .role = .surface_fg }}, narrow, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 0), out.items.len); // term_w=5px < cw=8 → term_cols=0 → 생략
}

test "modal_box: rich 패딩이어도 확장 박스(box_w + 2*pad)가 터미널 영역 안 — 사이드바 침범 방지" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const pad: u32 = 12;
    const sidebar: u32 = 40;
    const backing: u32 = 200;
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = sidebar,
        .backing_width_px = backing,
        .backing_height_px = 600,
    }, .shape = .{ .modal_padding_px = @intCast(pad) } };
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var out: std.ArrayList(draw.Op) = .empty;

    try view(&.{.{ .text = "this is a fairly long message to force the width clamp", .role = .surface_fg }}, p, &tk, arena, &out);
    const box = out.items[0].quad.rect;
    const term_w_px = backing - sidebar;
    try std.testing.expect(box.w + 2 * pad <= term_w_px);
    try std.testing.expect(box.x - @as(i32, @intCast(pad)) >= @as(i32, @intCast(sidebar)));
    try std.testing.expect(box.x + @as(i32, @intCast(box.w + pad)) <= @as(i32, @intCast(sidebar + term_w_px)));

    // 긴 줄은 안쪽 폭에서 나뉜다(`wrapLine`) — 폭 clamp 된 상자 안에 조각이 여럿이다.
    const rows1 = out.items.len - 1;
    try std.testing.expect(rows1 > 1);

    // 2줄(confirm 류)도 같은 폭 clamp가 걸린다 — 다줄 box_h 증가가 폭/중앙배치를 깨지 않는지(rich 패딩 조합) 확인.
    out.clearRetainingCapacity();
    try view(&.{
        .{ .text = "this is a fairly long message to force the width clamp", .role = .surface_fg },
        .{ .text = "Enter to close   Esc to cancel", .role = .muted_fg },
    }, p, &tk, arena, &out);
    const rows2 = out.items.len - 1;
    try std.testing.expect(rows2 > rows1); // 둘째 줄이 조각을 더한다
    const ch = p.metrics.cell_height_px; // 16
    const box2 = out.items[0].quad.rect;
    try std.testing.expect(box2.w + 2 * pad <= term_w_px); // 폭 clamp 동일
    try std.testing.expect(box2.x - @as(i32, @intCast(pad)) >= @as(i32, @intCast(sidebar)));
    try std.testing.expect(box2.h == box.h + @as(u32, @intCast(rows2 - rows1)) * ch); // 더한 조각 수만큼 정확히 커진다
    for (out.items[2..], 2..) |op, i| // 조각은 한 줄(ch)씩 아래로 — 첫째 줄 조각 다음에 둘째 줄이 이어진다
        try std.testing.expect(op.text.origin.y == out.items[i - 1].text.origin.y + @as(i32, @intCast(ch)));
    try std.testing.expectEqual(tokens.ColorRole.muted_fg, out.items[out.items.len - 1].text.role); // 마지막 조각은 둘째 줄
    // 조각마다 안쪽 폭 안이다 — 나눌 폭을 패딩·사이드바를 빼기 전 값으로 잡으면 여기서 넘친다. 둘째 줄도 나뉘어
    // 내용이 다 남는다(첫 줄만 나누면 둘째 줄 한 조각이 안쪽을 넘는다).
    const margin: i32 = @intCast(tk.space.modal_margin_cells);
    const inner_left = box2.x + margin * 8;
    const inner_right = box2.x + @as(i32, @intCast(box2.w)) - margin * 8;
    var second: std.ArrayList(u8) = .empty;
    for (out.items[1..]) |op| {
        try std.testing.expectEqual(inner_left, op.text.origin.x);
        try std.testing.expect(op.text.origin.x + @as(i32, @intCast(overlay_input.displayCols(op.text.runs[0].text))) * 8 <= inner_right);
        if (op.text.role == .muted_fg) for (op.text.runs[0].text) |b| if (b != ' ') try second.append(arena, b);
    }
    try std.testing.expectEqualStrings("EntertocloseEsctocancel", second.items);
}

test "modal_box: 박스가 뷰포트보다 높으면 y를 0으로 clamp (상단/제목 화면 위로 안 잘림 — 리뷰 #823)" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    // 짧은 창(backing_height 작게) + 많은 콘텐츠 행 → box_h > backing_height.
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 800, .backing_height_px = 120 } };
    const box = layout(20, 30, p, &tk).?; // 30행 콘텐츠 → box_h=(30+2)*16=512 ≫ 120
    try std.testing.expect(box.rect.y >= 0); // 상단이 화면 위로 안 나감
    try std.testing.expect(box.inner_y >= 0); // 첫 콘텐츠 행도 화면 안
    // 넉넉한 창에선 중앙 정렬(양수 y) 유지.
    const p2 = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 800, .backing_height_px = 600 } };
    const box2 = layout(20, 6, p2, &tk).?;
    try std.testing.expect(box2.rect.y > 0); // 중앙
}

test "modal_box: explicit workspace centers the modal across terminal and file dock" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const workspace = props.PaneRect{ .x = 200, .y = 40, .w = 1200, .h = 860 };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 10,
        .cell_height_px = 20,
        .sidebar_width_px = 200,
        .backing_width_px = 1400,
        .backing_height_px = 900,
        .workspace_x_px = workspace.x,
        .workspace_y_px = workspace.y,
        .workspace_width_px = workspace.w,
        .workspace_height_px = workspace.h,
        .workspace_present = true,
    } };
    const box = layout(20, 4, p, &tk).?;
    try std.testing.expectEqual(@as(i32, @intCast(workspace.x + workspace.w / 2)), box.rect.x + @divTrunc(@as(i32, @intCast(box.rect.w)), 2));
    try std.testing.expectEqual(@as(i32, @intCast(workspace.y + workspace.h / 2)), box.rect.y + @divTrunc(@as(i32, @intCast(box.rect.h)), 2));
}

test "modal_box: authoritative zero-size workspace fails closed instead of using legacy backing" {
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{
        .cell_width_px = 10,
        .cell_height_px = 20,
        .sidebar_width_px = 200,
        .backing_width_px = 1400,
        .backing_height_px = 900,
        .workspace_x_px = 200,
        .workspace_y_px = 900,
        .workspace_width_px = 1200,
        .workspace_height_px = 0,
        .workspace_present = true,
    } };
    try std.testing.expectEqual(@as(?Box, null), layout(20, 4, p, &tk));
}

// `wrapLine` 의 가장자리 셋을 정확한 입력으로 못박는다(notice·confirm 공유 규칙).
test "modal_box wrapLine: 깨진 바이트·CR·끝 줄바꿈 — 글자를 반으로 가르지 않고, CR 은 칸이 아니며, 끝 줄바꿈은 「…」가 아니다" {
    var out: [max_wrap_rows][]const u8 = undefined;
    // ① 깨진 lead(E0) 뒤의 온전한 「가」(EA B0 80) — 렌더러처럼 E0 하나만 깨진 글자(1칸)로 보고 「가」는 통째로 다음 줄.
    //    lead 길이로 E0 EA B0 을 묶으면 「가」가 두 줄로 갈렸다.
    const broken = wrapLine("ab\xE0\xEA\xB0\x80", 3, &out);
    try std.testing.expectEqual(@as(u32, 2), broken.rows);
    try std.testing.expectEqualStrings("ab\xE0", out[0]);
    try std.testing.expectEqualStrings("\xEA\xB0\x80", out[1]);
    // ② 줄 끝의 CR 은 남기지 않는다(줄바꿈 없이 끝나는 CR 도).
    const cr = wrapLine("abc\r", 10, &out);
    try std.testing.expectEqual(@as(u32, 1), cr.rows);
    try std.testing.expectEqualStrings("abc", out[0]);
    // ③ 여섯째 줄이 딱 맞고 메시지가 줄바꿈 하나로 끝나면 잘린 것이 아니다 — 「…」 자리만큼 줄이지 않는다.
    const tail = wrapLine("aaaaa bbbbb ccccc ddddd eeeee fffff\n", 5, &out);
    try std.testing.expectEqual(@as(u32, 6), tail.rows);
    try std.testing.expect(!tail.truncated);
    try std.testing.expectEqualStrings("fffff", out[5]);
    // 대조: 정말 더 남으면 잘리고 「…」 자리를 비운다.
    const more = wrapLine("aaaaa bbbbb ccccc ddddd eeeee fffff\nggggg", 5, &out);
    try std.testing.expect(more.truncated);
    try std.testing.expect(overlay_input.displayCols(out[5]) + overlay_input.displayCols(ellipsis) <= 5);
    try std.testing.expectEqualStrings("ffff", out[5]); // 「…」 자리(1칸)만 비우고 나머지는 채운다
}
