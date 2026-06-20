//! ModalBox — 중앙 모달 박스의 공유 레이아웃/렌더. notice(알림)·confirm(예/아니오 확인)이 같은 박스 기하를
//! 공유한다: 폭 clamp(터미널 영역=사이드바 오른쪽), soft-lock 방지 가드, 중앙 배치, 둥근 배경 quad + focus 테두리,
//! 줄별 텍스트. 줄 수만 다르다(notice 1줄, confirm 메시지+안내 2줄). State·handle(입력)·라이프사이클은 각 컴포넌트가
//! 소유하고, 이 모듈은 "열렸을 때 줄들을 박스로 그리는" **순수 view**만 제공한다 — 두 컴포넌트가 클램프/중앙배치
//! 로직을 복붙하던 중복(및 한쪽만 고쳐 갈리는 위험)을 없앤다. 단일 출처: docs/chrome-strategy.md §5.4.

const std = @import("std");
const draw = @import("../draw.zig");
const tokens = @import("../tokens.zig");
const props = @import("../props.zig");

/// 이 박스가 그리는 레이어(최상위 모달). notice/confirm이 그대로 재노출한다.
pub const layer = draw.Layer.modal;

/// 박스에 그릴 한 줄(텍스트 + 색 역할). 보통 첫 줄=메시지(surface_fg), 이후=안내(muted_fg).
pub const Line = struct { text: []const u8, role: tokens.ColorRole };

/// lines를 중앙 모달 박스로 그려 out에 append한다(quad + border + 줄별 text). lines가 비면 무동작(호출자가 열림
/// 가드). 폭 = 가장 긴 줄 표시 폭 + 좌우 여백, **터미널 영역(사이드바 오른쪽)으로 clamp**한다 — 넘으면 사이드바
/// 침범/우측 오버플로. term_cols==0(터미널 영역이 한 셀보다 좁음)이면만 생략한다(중앙배치 뺄셈 언더플로 방지);
/// 1~3칸이어도 작은 박스라도 그린다 — '열림이지만 안 보임'이면 handle이 모든 키를 소비해 soft-lock이 된다. 표시
/// 폭은 코드포인트 근사라 wide(EAW=2) 문자는 과소측정될 수 있다(정확 보정은 후속). 높이 = (줄 수 + 위/아래 여백
/// 한 줄씩)·ch. ops·runs 슬라이스는 호출자가 준 frame arena가 소유한다.
pub fn view(
    lines: []const Line,
    p: props.ChromeProps,
    tk: *const tokens.Tokens,
    arena: std.mem.Allocator,
    out: *std.ArrayList(draw.Op),
) !void {
    if (lines.len == 0) return;
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);

    const term_w_px = m.backing_width_px -| m.sidebar_width_px;
    const term_cols = term_w_px / cw;
    if (term_cols == 0) return; // 터미널 영역 < 한 셀 — 중앙배치 뺄셈 언더플로 방지로 생략

    // C4b 패딩: 폭 상한을 2*pad만큼 줄인 가용 칸으로 box_cols를 clamp한다 — platform lowering이 배경 quad를 ±pad
    // 확장한 뒤에도 박스가 터미널 영역에 들도록 텍스트 폭을 양보한다. pad=0(tui)이면 avail_cols == term_cols(무변화).
    const pad: u32 = p.shape.modal_padding_px;
    const avail_cols = (term_w_px -| 2 * pad) / cw;
    var content_cols: u32 = 0;
    for (lines) |ln| {
        const c: u32 = @intCast(std.unicode.utf8CountCodepoints(ln.text) catch ln.text.len);
        content_cols = @max(content_cols, c);
    }
    const box_cols = @max(@min(content_cols + 2 * tk.space.modal_margin_cells, avail_cols), 1);
    const box_w = box_cols * cw;
    const box_h = (@as(u32, @intCast(lines.len)) + 2) * ch; // 위 여백 + 줄들 + 아래 여백

    // 터미널 영역 안에서 중앙 배치. box_w <= term_w_px(위 clamp)라 (term_w_px - box_w)는 비음수 → x는 항상 사이드바 오른쪽.
    const sidebar = @as(i32, @intCast(m.sidebar_width_px));
    const x = sidebar + @as(i32, @intCast((term_w_px - box_w) / 2));
    const y = @divTrunc(@as(i32, @intCast(m.backing_height_px)) - @as(i32, @intCast(box_h)), 2);
    const rect = draw.Rect{ .x = x, .y = y, .w = box_w, .h = box_h };

    const bg_r = p.shape.corner_radius_px;
    const bw = p.shape.border_width_px;
    // C4b 모달: 배경을 quad로(둥근+테두리) — tui(0)면 셀 배경 + 아래 Op.border 셀, rich(>0)면 둥근 quad + quad 테두리.
    try out.append(arena, .{ .quad = .{ .rect = rect, .fill_role = .surface_bg, .corner_radii = .{ bg_r, bg_r, bg_r, bg_r }, .border_widths = .{ bw, bw, bw, bw }, .border_role = .focus_accent } });
    try out.append(arena, .{ .border = .{
        .rect = rect,
        .sides = .{ .top = true, .right = true, .bottom = true, .left = true },
        .role = .focus_accent,
    } });

    // 줄 i는 좌측 여백 + (i+1)번째 줄(위 여백 한 줄 아래부터). runs는 arena 소유.
    const text_x = x + @as(i32, @intCast(tk.space.modal_margin_cells * cw));
    for (lines, 0..) |ln, i| {
        const runs = try arena.alloc(draw.Run, 1);
        runs[0] = .{ .text = ln.text };
        try out.append(arena, .{ .text = .{
            .origin = .{ .x = text_x, .y = y + @as(i32, @intCast(i + 1)) * @as(i32, @intCast(ch)) },
            .runs = runs,
            .role = ln.role,
        } });
    }
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
// 공유 박스 기하의 엣지케이스(soft-lock 가드·폭 clamp·rich 패딩 침범 방지)를 한 곳에서 증명한다 — notice/confirm은
// 이 view에 줄만 넘기므로, 여기서 기하를 검증하면 두 컴포넌트가 같은 보장을 받는다.

test "modal_box: lines 0이면 ops 0, 1줄이면 quad+border+text(3), 2줄이면 +text(4)" {
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
    try std.testing.expectEqual(@as(usize, 3), out.items.len);
    try std.testing.expect(out.items[0] == .quad);
    try std.testing.expect(out.items[1] == .border);
    try std.testing.expect(out.items[2] == .text);
    const h1 = out.items[0].quad.rect.h;

    out.clearRetainingCapacity();
    try view(&.{ .{ .text = "메시지", .role = .surface_fg }, .{ .text = "안내", .role = .muted_fg } }, p, &tk, arena, &out);
    try std.testing.expectEqual(@as(usize, 4), out.items.len); // 2줄 → text 2개
    try std.testing.expect(out.items[3] == .text);
    try std.testing.expect(out.items[3].text.origin.y > out.items[2].text.origin.y); // 둘째 줄이 아래
    try std.testing.expect(out.items[0].quad.rect.h > h1); // 2줄 박스가 1줄보다 한 줄 큼
    try std.testing.expect(out.items[0].quad.rect.x >= 40); // 사이드바 오른쪽
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
    try std.testing.expectEqual(@as(usize, 3), out.items.len); // 작아도 그린다(보여서 Esc 가능)
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
    try std.testing.expectEqual(@as(usize, 4), out.items.len); // quad+border+text+text
    const ch = p.metrics.cell_height_px; // 16
    const box2 = out.items[0].quad.rect;
    try std.testing.expect(box2.w + 2 * pad <= term_w_px); // 폭 clamp 동일
    try std.testing.expect(box2.x - @as(i32, @intCast(pad)) >= @as(i32, @intCast(sidebar)));
    try std.testing.expect(box2.h == box.h + ch); // 2줄 박스가 1줄보다 정확히 한 줄(ch) 큼
    try std.testing.expect(out.items[3].text.origin.y == out.items[2].text.origin.y + @as(i32, @intCast(ch))); // 둘째 줄 = 첫째 + ch
}
