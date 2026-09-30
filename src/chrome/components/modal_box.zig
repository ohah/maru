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
const text_layout = @import("../text_layout.zig"); // wrap 이 자르는 자리 — grapheme cluster 경계(폭은 overlay_input 셈법)

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
    for (lines) |ln| content_cols = @max(content_cols, overlay_input.displayCols(ln.text)); // EAW 표시폭(placeText와 동일 규약)
    const box = layout(content_cols, @intCast(lines.len), p, tk) orelse return;
    try frame(box, p, arena, out);
    for (lines, 0..) |ln, i| try text(box, box.inner_x, @intCast(i), ln.text, ln.role, arena, out);
}

/// 박스에 한 줄로 안 들어가는 메시지를 콘텐츠 폭 안에 들도록 여러 줄로 나눈다(notice 용 — 한 줄로만 그리던 때는 긴
/// 안내가 박스 밖으로 넘쳤다). 폭 = 박스가 이 작업영역에서 가질 수 있는 콘텐츠 칸 수(layout 의 폭 clamp 와 같은 규약),
/// 줄 수 상한 = 박스가 세로로 들어가는 콘텐츠 행 수(rich 패딩이 배경을 위아래로 넓히는 만큼 뺀다) — 넘치면 마지막 줄을
/// `…` 로 끝낸다. 규약은 `wrapCols`. null=박스를 둘 수 없는 작업영역(layout 과 같은 조건).
pub fn wrap(message: []const u8, p: props.ChromeProps, tk: *const tokens.Tokens, arena: std.mem.Allocator) !?[]const []const u8 {
    const widest = layout(std.math.maxInt(u32) / 4, 1, p, tk) orelse return null;
    // 콘텐츠 칸이 없는 작업영역(5 칸 미만)이면 글자가 어차피 안 보인다 — 한 줄로 두어 빈 박스만 세로로 커지지 않게.
    if (widest.inner_cols == 0) return try wrapCols(message, std.math.maxInt(u32), 1, arena);
    const max_cols = widest.inner_cols;
    const workspace = props.workspaceRect(p.metrics);
    const usable_h = workspace.h -| 2 * p.shape.modal_padding_px;
    const max_rows: u32 = @max(usable_h / @max(p.metrics.cell_height_px, 1), 3) - 2; // 위아래 여백 한 줄씩
    return try wrapCols(message, max_cols, max_rows, arena);
}

/// `wrap` 의 순수 핵심 — 폭 `max_cols`(≥1)·줄 수 `max_rows`(≥1) 안으로 나눈다(시험한다).
/// - 폭은 **모달을 실제로 그리는 `metal_lowering.placeText` 와 같은 셈법** — 코드포인트마다 `max(1, EAW)` 칸
///   (`overlay_input.displayCols`, 박스 폭도 이것으로 잰다). 그래서 NFD 한글 한 음절은 4칸, 결합 문자·VS16·ZWJ 도 각 1칸
///   이다(cluster 로 재면 실제 그림보다 좁게 재어 줄이 박스 밖으로 넘쳤다 — 3 차 적대 검증).
/// - **자르는 자리는 grapheme cluster 경계**(`text_layout`) — 받침·결합 문자·ZWJ 이모지가 두 줄로 갈리지 않게.
/// - 손상 UTF-8 은 바이트마다 U+FFFD 로 바꾼 사본으로 나눈다(`placeText` 는 손상 run 을 통째로 버려 그 줄이 사라졌다).
/// - 줄은 공백·탭에서 나눈다. 한 줄 **안의** 간격은 원문 그대로 둔다(경로 `My  Docs` 가 `My Docs` 로 바뀌지 않게, 탭은
///   한 칸 공백으로). 줄이 바뀌는 자리의 간격은 버리고, 문단 첫 줄의 들여쓰기는 남긴다.
/// - `\n` 은 문단을 끊고(CRLF 의 `\r` 은 뗀다) 빈 문단은 빈 줄 하나. 메시지 끝의 공백·줄바꿈은 뗀다.
/// - 줄 수를 넘으면 들어가는 마지막 줄을 **반드시** `…` 로 끝낸다.
/// 한 줄에 들어가는 짧은 메시지(줄바꿈·탭·CR 없음)는 복사 없이 그대로 돌려준다.
pub fn wrapCols(message_in: []const u8, max_cols: u32, max_rows: u32, arena: std.mem.Allocator) ![]const []const u8 {
    var lines: std.ArrayList([]const u8) = .empty;
    const valid = if (std.unicode.utf8ValidateSlice(message_in)) message_in else try replaceInvalid(message_in, arena);
    // 앞의 빈 줄(공백·탭만 있는 줄 포함)과 끝의 공백·줄바꿈은 뗀다 — 내용이 처음 나오는 줄의 들여쓰기는 남긴다.
    const message = std.mem.trimEnd(u8, skipBlankLines(valid), " \t\r\n");
    if (std.mem.indexOfAny(u8, message, "\n\t\r") == null and widthOf(message) <= max_cols) {
        try lines.append(arena, message);
        return lines.items;
    }
    const rows = @max(max_rows, 1);
    // 줄이 `rows` 를 넘으면 더 나누지 않는다 — 넘쳤다는 것만 알면 된다(매 프레임 불리므로 긴 메시지·긴 단어에서 끝까지
    // 계산하지 않게 — 6 차 적대 검증: 상한 없는 호출자라면 10KB 한 단어가 프레임당 100ms 를 넘었다).
    var paragraphs = std.mem.splitScalar(u8, message, '\n');
    outer: while (paragraphs.next()) |para_raw| {
        const para = std.mem.trimEnd(u8, para_raw, "\r"); // CRLF
        var line: std.ArrayList(u8) = .empty;
        var line_cols: u32 = 0;
        var any = false; // 이 문단이 줄을 하나라도 냈나 — 빈 문단만 빈 줄 하나
        var first = true; // 문단의 첫 단어 — 앞 간격(들여쓰기)을 남긴다
        var i: usize = 0;
        while (i < para.len) {
            const word_start = std.mem.indexOfNonePos(u8, para, i, " \t") orelse para.len;
            if (word_start == para.len) break;
            const sep = para[i..word_start];
            const word_end = std.mem.indexOfAnyPos(u8, para, word_start, " \t") orelse para.len;
            const word = para[word_start..word_end];
            i = word_end;
            const word_cols = widthOf(word);
            const keep_sep = line_cols != 0 or first; // 줄 머리의 간격은 문단 첫 줄에서만
            const sep_cols: u32 = if (keep_sep) @intCast(sep.len) else 0; // 공백·탭 모두 한 칸
            first = false;
            if (line_cols + sep_cols + word_cols <= max_cols) {
                if (keep_sep) for (sep) |_| try line.append(arena, ' ');
                try line.appendSlice(arena, word);
                line_cols += sep_cols + word_cols;
                continue;
            }
            if (line_cols != 0) {
                try lines.append(arena, line.items);
                if (lines.items.len > rows) break :outer;
                any = true;
                line = .empty;
                line_cols = 0;
            }
            // 한 줄보다 긴 단어 — cluster 경계에서 폭만큼씩 자른다.
            var rest = word;
            while (widthOf(rest) > max_cols) {
                const cut = fitCols(rest, max_cols, true);
                try lines.append(arena, rest[0..cut]);
                if (lines.items.len > rows) break :outer;
                any = true;
                rest = rest[cut..];
            }
            try line.appendSlice(arena, rest);
            line_cols = widthOf(rest);
        }
        if (line_cols != 0 or !any) try lines.append(arena, line.items);
        if (lines.items.len > rows) break;
    }
    if (lines.items.len > rows) {
        // 넘친 줄이 있다 — 들어가는 마지막 줄을 **반드시** `…` 로 끝낸다(다음 줄과 합쳐 자르던 때는 `\n` 으로 나뉜
        // 짧은 줄끼리 합쳐도 폭 안이라 말줄임 없이 뒷줄이 조용히 사라졌다 — 적대 검증).
        const last = rows - 1;
        lines.items[last] = try withEllipsis(lines.items[last], max_cols, arena);
        lines.shrinkRetainingCapacity(rows);
    }
    return lines.items;
}

/// 앞에서부터 공백·탭·CR 만 있는 줄을 건너뛴 나머지(내용 있는 첫 줄의 시작부터).
fn skipBlankLines(bytes: []const u8) []const u8 {
    var start: usize = 0;
    while (std.mem.indexOfScalarPos(u8, bytes, start, '\n')) |nl| {
        if (std.mem.indexOfNone(u8, bytes[start..nl], " \t\r") != null) break;
        start = nl + 1;
    }
    return bytes[start..];
}

/// 표시폭 — `placeText` 와 같은 셈법(코드포인트마다 `max(1, EAW)`).
fn widthOf(bytes: []const u8) u32 {
    return overlay_input.displayCols(bytes);
}

/// 손상 UTF-8 을 바이트마다 U+FFFD 로 바꾼 사본(`text_layout.decodeCodepoint` 와 같은 규칙).
fn replaceInvalid(bytes: []const u8, arena: std.mem.Allocator) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < bytes.len) {
        const d = text_layout.decodeCodepoint(bytes, i);
        if (d.cp == 0xFFFD and d.advance == 1) {
            try out.appendSlice(arena, "\u{FFFD}");
        } else try out.appendSlice(arena, bytes[i .. i + d.advance]);
        i += d.advance;
    }
    return out.items;
}

/// `line` 끝에 `…`(1칸)을 붙인다 — 폭이 모자라면 앞을 `max_cols - 1` 칸까지 cluster 경계에서 자르고 붙인다.
/// 결과 표시폭 ≤ max(max_cols, 1).
fn withEllipsis(line: []const u8, max_cols: u32, arena: std.mem.Allocator) ![]const u8 {
    if (max_cols <= 1) return "…";
    const keep = if (widthOf(line) + 1 <= max_cols) line.len else fitCols(line, max_cols - 1, false);
    return std.fmt.allocPrint(arena, "{s}…", .{line[0..keep]});
}

/// `bytes` 앞에서 표시폭 `max_cols` 안에 드는 가장 긴 cluster 경계(바이트 수). cluster 의 폭은 그 안 코드포인트들의
/// `placeText` 폭 합. `at_least_one` 이면 첫 cluster 는 폭을 넘어도 넣는다(전진 보장) — 그래서 **한 줄보다 넓은 cluster
/// 하나**(긴 ZWJ 이모지, 결합 문자가 수십 개 붙은 글자)는 통째로 한 줄이 되어 폭을 넘고, 넘친 부분은 박스 clamp·셀 격자
/// 에서 잘린다(cluster 를 가르지 않는 대가).
fn fitCols(bytes: []const u8, max_cols: u32, at_least_one: bool) usize {
    var i: usize = 0;
    var used: u32 = 0;
    while (i < bytes.len) {
        const base = text_layout.decodeCodepoint(bytes, i);
        const end = text_layout.clusterEndAfter(bytes, i, base.advance);
        const w = widthOf(bytes[i..end]);
        if (used + w > max_cols and !(at_least_one and i == 0)) break;
        used += w;
        i = end;
    }
    return i;
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

    // 2줄(confirm 류)도 같은 폭 clamp가 걸린다 — 다줄 box_h 증가가 폭/중앙배치를 깨지 않는지(rich 패딩 조합) 확인.
    out.clearRetainingCapacity();
    try view(&.{
        .{ .text = "this is a fairly long message to force the width clamp", .role = .surface_fg },
        .{ .text = "Enter to close   Esc to cancel", .role = .muted_fg },
    }, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 3), out.items.len); // quad+text+text
    const ch = p.metrics.cell_height_px; // 16
    const box2 = out.items[0].quad.rect;
    try std.testing.expect(box2.w + 2 * pad <= term_w_px); // 폭 clamp 동일
    try std.testing.expect(box2.x - @as(i32, @intCast(pad)) >= @as(i32, @intCast(sidebar)));
    try std.testing.expect(box2.h == box.h + ch); // 2줄 박스가 1줄보다 정확히 한 줄(ch) 큼
    try std.testing.expect(out.items[2].text.origin.y == out.items[1].text.origin.y + @as(i32, @intCast(ch))); // 둘째 줄 = 첫째 + ch
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

test "modal_box wrap: a short message stays one line; a long one wraps at spaces within the width" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const short = try wrapCols("file corrupt", 40, 10, arena);
    try std.testing.expectEqual(@as(usize, 1), short.len);
    try std.testing.expectEqualStrings("file corrupt", short[0]);
    const msg = "The Chromium engine could not start. Reinstall it with brew reinstall maru-chromium, then restart maru.";
    const lines = try wrapCols(msg, 40, 10, arena);
    try std.testing.expect(lines.len >= 3);
    var joined: std.ArrayList(u8) = .empty;
    for (lines, 0..) |ln, i| {
        try std.testing.expect(overlay_input.displayCols(ln) <= 40);
        try std.testing.expect(ln.len > 0 and ln[0] != ' ' and ln[ln.len - 1] != ' ');
        if (i != 0) try joined.append(arena, ' ');
        try joined.appendSlice(arena, ln);
    }
    try std.testing.expectEqualStrings(msg, joined.items); // 단어를 잃거나 바꾸지 않는다
}

test "modal_box wrap: Korean counts two columns per syllable, a word longer than a line is cut, newlines break" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const ko = try wrapCols("Chromium 엔진을 시작하지 못했습니다. 다시 설치한 뒤 maru 를 다시 켜 주세요.", 20, 10, arena);
    for (ko) |ln| try std.testing.expect(overlay_input.displayCols(ln) <= 20);
    try std.testing.expect(ko.len >= 3);
    const long_word = try wrapCols("/Users/someone/Library/Caches/maru/web-osr-run/run-1-abcdef", 16, 10, arena);
    try std.testing.expect(long_word.len >= 4);
    for (long_word) |ln| try std.testing.expect(overlay_input.displayCols(ln) <= 16 and ln.len > 0);
    const wide_word = try wrapCols("가나다라마바사아자차카타파하", 5, 10, arena); // 한 줄 5칸 — 두 글자(4칸)씩
    for (wide_word) |ln| try std.testing.expectEqual(@as(u32, 4), overlay_input.displayCols(ln));
    const nl = try wrapCols("first\nsecond", 40, 10, arena);
    try std.testing.expectEqual(@as(usize, 2), nl.len);
    try std.testing.expectEqualStrings("second", nl[1]);
    // 폭 1 에서도 끝난다(한 칸보다 넓은 글자도 한 줄에 하나).
    const tiny = try wrapCols("가 b", 1, 10, arena);
    try std.testing.expect(tiny.len == 2);
}

test "modal_box wrap: a line that exactly fills the width stays one line; trailing newlines, CR and tabs make no extra lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const exact = try wrapCols("aaaa bbbb cc", 9, 10, arena); // "aaaa bbbb" 가 딱 9 칸
    try std.testing.expectEqual(@as(usize, 2), exact.len);
    try std.testing.expectEqualStrings("aaaa bbbb", exact[0]);
    const trailing = try wrapCols("hello world\n", 5, 10, arena);
    try std.testing.expectEqual(@as(usize, 2), trailing.len);
    const crlf = try wrapCols("def\r\nghi", 40, 10, arena);
    try std.testing.expectEqual(@as(usize, 2), crlf.len);
    try std.testing.expectEqualStrings("def", crlf[0]);
    const tab = try wrapCols("aaaa\tbbb", 5, 10, arena);
    try std.testing.expectEqualStrings("aaaa", tab[0]);
    try std.testing.expectEqualStrings("bbb", tab[1]);
    const wide_last = try wrapCols("가", 1, 10, arena); // 폭보다 넓은 한 글자 — 빈 줄을 뒤에 남기지 않는다
    try std.testing.expectEqual(@as(usize, 1), wide_last.len);
    const blank_para = try wrapCols("a\n\nb", 40, 10, arena); // 가운데 빈 문단은 빈 줄로 남는다
    try std.testing.expectEqual(@as(usize, 3), blank_para.len);
    try std.testing.expectEqualStrings("", blank_para[1]);
}

test "modal_box wrap: grapheme clusters are never split, inner spacing is kept, exactly max_rows lines get no ellipsis" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    // NFD 한글(ᄒ+ᅡ+ᆫ) 경로 — 받침이나 모음이 줄 머리로 떨어지지 않는다.
    const nfd = "/Users/x/\u{1112}\u{1161}\u{11AB}\u{1100}\u{1173}\u{11AF}\u{1112}\u{1161}\u{11AB}.txt";
    const nfd_lines = try wrapCols(nfd, 10, 10, arena);
    try std.testing.expect(nfd_lines.len >= 2);
    for (nfd_lines) |ln| {
        const cp = std.unicode.utf8Decode(ln[0..(std.unicode.utf8ByteSequenceLength(ln[0]) catch 1)]) catch 0;
        try std.testing.expect(!(cp >= 0x1160 and cp <= 0x11FF)); // 가운뎃소리·끝소리로 시작하지 않는다
        try std.testing.expect(widthOf(ln) <= 10);
    }
    // 결합 문자(é = e + U+0301)도 앞 글자와 붙어 다닌다.
    const combining = try wrapCols("e\u{301}e\u{301}e\u{301}e\u{301}", 3, 10, arena);
    for (combining) |ln| try std.testing.expect(!std.mem.startsWith(u8, ln, "\u{301}"));
    // 한 줄 안의 간격은 원문 그대로 — 줄이 바뀌는 자리의 간격만 버린다.
    const spaced = try wrapCols("My  Docs is  here and there", 14, 10, arena);
    try std.testing.expectEqualStrings("My  Docs is", spaced[0]);
    try std.testing.expectEqualStrings("here and there", spaced[1]);
    // 문단 첫 줄의 들여쓰기는 남는다(스택 트레이스 모양).
    const indented = try wrapCols("error:\n    at foo (a.js:1)", 40, 10, arena);
    try std.testing.expectEqualStrings("    at foo (a.js:1)", indented[1]);
    // 짧아도 탭이 있으면 긴 길로 — 탭은 한 칸 공백.
    const tabbed = try wrapCols("a\tb", 40, 10, arena);
    try std.testing.expectEqualStrings("a b", tabbed[0]);
    // 끝의 공백+줄바꿈도 뗀다.
    const trailing = try wrapCols("hello world \n", 5, 10, arena);
    try std.testing.expectEqual(@as(usize, 2), trailing.len);
    // 줄 수가 정확히 상한이면 말줄임을 붙이지 않는다.
    const exact_rows = try wrapCols("a\nb", 40, 2, arena);
    try std.testing.expectEqualStrings("b", exact_rows[1]);
    // ASCII 긴 단어는 폭만큼씩 정확히 자른다.
    const long_ascii = try wrapCols("abcdefghij", 4, 10, arena);
    try std.testing.expectEqualStrings("abcd", long_ascii[0]);
    try std.testing.expectEqualStrings("efgh", long_ascii[1]);
    try std.testing.expectEqualStrings("ij", long_ascii[2]);
    // 말줄임이 넓은 글자에서 멈춘다(넘기고 뒤 글자를 넣지 않는다).
    try std.testing.expectEqualStrings("ab…", try withEllipsis("ab가c", 4, arena));
}

test "modal_box wrap: widths follow the overlay painter (one column per code point), leading blank lines and first-line indentation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    try std.testing.expectEqual(@as(u32, 4), widthOf("\u{1112}\u{1161}\u{11AB}")); // NFD 한 음절 = 2 + 1 + 1
    try std.testing.expectEqual(@as(u32, 2), widthOf("e\u{301}"));
    const mixed = try wrapCols("가나다 xy", 5, 10, arena);
    try std.testing.expectEqual(@as(usize, 2), mixed.len);
    try std.testing.expectEqualStrings("가나", mixed[0]);
    try std.testing.expectEqualStrings("다 xy", mixed[1]);
    const leading = try wrapCols("\n\n\nabc", 40, 2, arena);
    try std.testing.expectEqual(@as(usize, 1), leading.len);
    try std.testing.expectEqualStrings("abc", leading[0]);
    const indent_first = try wrapCols("  indented first line wraps", 12, 10, arena);
    try std.testing.expect(std.mem.startsWith(u8, indent_first[0], "  "));
    const trailing_space_line = try wrapCols("a\n ", 40, 10, arena);
    try std.testing.expectEqual(@as(usize, 1), trailing_space_line.len);
}

test "modal_box wrap: rows follow the workspace height minus the rich padding, width uses every column the box can take" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const many = "one\ntwo\nthree\nfour\nfive\nsix\nseven";
    // 높이 48(3 행) → 콘텐츠 1 줄.
    var p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 320, .backing_height_px = 48 } };
    try std.testing.expectEqual(@as(usize, 1), (try wrap(many, p, &tk, arena)).?.len);
    // 높이 100·rich 패딩 12 → (100 - 24) / 16 = 4 행 → 콘텐츠 2 줄.
    p.metrics.backing_height_px = 100;
    p.shape.modal_padding_px = 12;
    try std.testing.expectEqual(@as(usize, 2), (try wrap(many, p, &tk, arena)).?.len);
    // 폭: 박스가 가질 수 있는 콘텐츠 칸을 다 쓴다.
    p.shape.modal_padding_px = 0;
    p.metrics.backing_height_px = 600;
    const inner = (layout(std.math.maxInt(u32) / 4, 1, p, &tk) orelse return error.NoBox).inner_cols;
    const exact = try arena.alloc(u8, inner);
    @memset(exact, 'x');
    const msg = try std.fmt.allocPrint(arena, "{s} tail", .{exact});
    const lines = (try wrap(msg, p, &tk, arena)).?;
    try std.testing.expectEqual(@as(usize, inner), lines[0].len);
}

test "modal_box wrap: invalid bytes become U+FFFD in place, blank leading lines go, a wide cluster never pulls a space to the line head" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const repl = try wrapCols("ok \xff done", 40, 10, arena);
    try std.testing.expectEqualStrings("ok \u{FFFD} done", repl[0]);
    const blank_lead = try wrapCols("  \n\t\r\nabc", 40, 10, arena);
    try std.testing.expectEqual(@as(usize, 1), blank_lead.len);
    try std.testing.expectEqualStrings("abc", blank_lead[0]);
    const indent_kept = try wrapCols(" \n  abc", 40, 10, arena);
    try std.testing.expectEqualStrings("  abc", indent_kept[0]);
    const family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}";
    const after_wide = try wrapCols(family ++ " b", 5, 10, arena);
    try std.testing.expectEqualStrings("b", after_wide[after_wide.len - 1]);
    const tight = try wrapCols("가나다\n라", 2, 1, arena); // 말줄임도 폭 안에서
    try std.testing.expectEqual(@as(usize, 1), tight.len);
    try std.testing.expect(widthOf(tight[0]) <= 2);
    const zero_rows = try wrapCols("a\nb", 40, 0, arena); // 줄 수 0 은 1 로
    try std.testing.expectEqual(@as(usize, 1), zero_rows.len);
    try std.testing.expectEqualStrings("a…", zero_rows[0]);
}

test "modal_box wrap: a workspace too narrow for any content column gives one line instead of a tall empty box" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const Rgb = @import("../../color.zig").Rgb;
    const tk = tokens.Tokens{ .palette = std.EnumArray(tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const p = props.ChromeProps{ .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 0, .backing_width_px = 24, .backing_height_px = 600 } };
    const box = layout(std.math.maxInt(u32) / 4, 1, p, &tk) orelse return error.NoBox;
    try std.testing.expectEqual(@as(u32, 0), box.inner_cols);
    try std.testing.expectEqual(@as(usize, 1), (try wrap("one two three four five six", p, &tk, arena)).?.len);
}

test "modal_box wrap: short paragraphs past the last row still end in an ellipsis instead of silently merging" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try wrapCols("a\nb\nc\nd", 40, 2, arena);
    try std.testing.expectEqual(@as(usize, 2), lines.len);
    try std.testing.expectEqualStrings("a", lines[0]);
    try std.testing.expectEqualStrings("b…", lines[1]);
    const full = try wrapCols("aaaa\nbbbb\ncccc", 4, 2, arena); // 마지막 줄이 폭을 꽉 채웠으면 한 칸 잘라 `…`
    try std.testing.expectEqualStrings("bbb…", full[1]);
    // 손상 UTF-8 은 U+FFFD 로 바뀌어(그리는 쪽이 손상 run 을 통째로 버리지 않게) 폭 안에서 `…` 로 끝난다.
    const bad = try wrapCols("aaaa\n\xff\xff\xff\xff\xff\nc", 4, 2, arena);
    try std.testing.expect(std.unicode.utf8ValidateSlice(bad[1]));
    try std.testing.expect(std.mem.endsWith(u8, bad[1], "…"));
    try std.testing.expect(widthOf(bad[1]) <= 4);
}

test "modal_box wrap: more lines than fit are cut to the rows, the last one ending in an ellipsis" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const lines = try wrapCols("one two three four five six seven eight nine ten", 9, 3, arena);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expect(std.mem.endsWith(u8, lines[2], "…"));
    try std.testing.expect(overlay_input.displayCols(lines[2]) <= 9);
}

test "modal_box wrap: once the rows overflow it stops splitting — a long unbroken word in a tiny box is cut after rows + 1 lines" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const word = "x" ** 5000;
    const lines = try wrapCols(word, 2, 3, arena);
    try std.testing.expectEqual(@as(usize, 3), lines.len);
    try std.testing.expectEqualStrings("xx", lines[0]);
    try std.testing.expectEqualStrings("x…", lines[2]);
    // 잘린 뒤의 나머지를 줄로 만들지 않았다 — arena 에 5000/2 줄치 슬라이스가 쌓이지 않는다.
    try std.testing.expect(arena_state.queryCapacity() < 4096);
}
