//! 테두리 계산이 없는 **단색 사각 백엔드**를 위한 `fill`·`quad` 평탄화 — Windows D3D11 셀 셰이더가 그 백엔드다
//! (`solidCell`: 사각 + 모서리 반지름 + 단색). 그 셰이더로도 rich 모양(둥근 모서리·테두리·모달 패딩)이 macOS 와 같은
//! 그림이 되게 하는 규칙이 여기 있다. 호스트는 결과를 자기 셀로 옮기고(원점·창 자르기) 이 규칙을 다시 적지 않는다
//! (docs/layering-and-portability.md §3.5).
//!
//! 규칙 셋:
//! - **그리는 순서가 곧 z 순서다.** 채움을 먼저, 테두리를 그 뒤에 낸다 — 앞에 내면 불투명 채움이 덮는다.
//! - **둥근 상자의 테두리는 바깥판 + 들인 채움이다.** 직각 변 넷을 얹으면 둥근 채움 밖으로 모서리가 각지게 비어져
//!   나온다. 바깥을 테두리 색으로 둥글게 채우고, 변 폭만큼 들인 채움(모서리도 그만큼 줄인다)을 그 뒤에 얹어 띠만
//!   남긴다. 채움이 비치면(알파 < 255) 바깥판이 섞여 보이므로 그때는 변 넷으로 간다.
//! - **모달 패널은 패딩만큼 키운다**(`flattenModal`). macOS rich lowering 이 모달의 첫 quad 를 그렇게 그리고
//!   (`metal_lowering.appendModalQuad`), `modal_box.layout` 은 그 폭을 미리 양보해 둔다. 보이는 사각형은
//!   `draw.Op.Quad.panelRect` 하나가 정한다.
//!
//! 그라디언트 quad 는 내지 않는다 — 단색으로 근사하면 화면이 틀린 채로 그럴듯해진다. 호출자가 그 수를 센다.

const std = @import("std");
const draw = @import("draw.zig");
const tokens = @import("tokens.zig");

/// 단색 사각 하나. `argb` 는 0xAARRGGBB, `radii` 는 [좌상, 우상, 우하, 좌하](`Quad.corner_radii` 와 같은 규약).
pub const SolidRect = struct {
    rect: draw.Rect,
    argb: u32,
    radii: [4]u16 = .{ 0, 0, 0, 0 },
};

/// `ops` 의 단색 몫을 그리는 순서대로 `out` 에 붙인다. 빈 사각은 내지 않는다.
pub fn flatten(a: std.mem.Allocator, ops: []const draw.Op, tk: *const tokens.Tokens, out: *std.ArrayList(SolidRect)) !void {
    for (ops) |op| switch (op) {
        .fill => |f| try put(a, out, f.rect, argbOf(tk, f.role, f.alpha), .{ 0, 0, 0, 0 }),
        .quad => |q| if (q.gradient == .solid) try flattenQuad(a, q, tk, out),
        else => {},
    };
}

/// 모달 draw(확인 모달 등)를 평탄화한다 — **첫 quad 가 둥글면 패널**이고 그것만 `panelRect` 로 키운다. 모달 컴포넌트는
/// 상자(`modal_box.frame`)를 첫 quad 로 낸다. macOS lowering 이 「첫 둥근 quad = 패널」로 고르는 것과 같은 규칙이다 —
/// 모서리 0(기반 토큰)이면 macOS 도 키우지 않고 셀 배경으로 그린다.
pub fn flattenModal(a: std.mem.Allocator, ops: []const draw.Op, tk: *const tokens.Tokens, out: *std.ArrayList(SolidRect)) !void {
    var panel_done = false;
    for (ops) |op| {
        if (!panel_done and op == .quad) {
            panel_done = true;
            var q = op.quad;
            const r = q.corner_radii;
            if (r[0] != 0 or r[1] != 0 or r[2] != 0 or r[3] != 0) q.rect = q.panelRect(tk.space.modal_padding_px);
            if (q.gradient == .solid) try flattenQuad(a, q, tk, out);
            continue;
        }
        try flatten(a, &.{op}, tk, out);
    }
}

fn flattenQuad(a: std.mem.Allocator, q: draw.Op.Quad, tk: *const tokens.Tokens, out: *std.ArrayList(SolidRect)) !void {
    const fill = argbOf(tk, q.fill_role, q.alpha);
    const w = q.border_widths;
    const br = q.border_role orelse return put(a, out, q.rect, fill, q.corner_radii);
    if (w[0] == 0 and w[1] == 0 and w[2] == 0 and w[3] == 0) return put(a, out, q.rect, fill, q.corner_radii);
    const border = argbOf(tk, br, q.border_alpha orelse q.alpha);
    const r = q.corner_radii;
    const rounded = r[0] != 0 or r[1] != 0 or r[2] != 0 or r[3] != 0;
    if (rounded and q.alpha == 0xFF) {
        try put(a, out, q.rect, border, r);
        // `border_widths` 는 [위, 오른쪽, 아래, 왼쪽] 이다(`Quad` 규약).
        const inner: draw.Rect = .{
            .x = q.rect.x + @as(i32, w[3]),
            .y = q.rect.y + @as(i32, w[0]),
            .w = q.rect.w -| (@as(u32, w[1]) + w[3]),
            .h = q.rect.h -| (@as(u32, w[0]) + w[2]),
        };
        const t = @max(@max(w[0], w[1]), @max(w[2], w[3]));
        return put(a, out, inner, fill, .{ r[0] -| t, r[1] -| t, r[2] -| t, r[3] -| t });
    }
    try put(a, out, q.rect, fill, r);
    const rc = q.rect;
    try put(a, out, .{ .x = rc.x, .y = rc.y, .w = rc.w, .h = w[0] }, border, .{ 0, 0, 0, 0 }); // 위
    try put(a, out, .{ .x = rc.x + @as(i32, @intCast(rc.w -| w[1])), .y = rc.y, .w = w[1], .h = rc.h }, border, .{ 0, 0, 0, 0 }); // 오른쪽
    try put(a, out, .{ .x = rc.x, .y = rc.y + @as(i32, @intCast(rc.h -| w[2])), .w = rc.w, .h = w[2] }, border, .{ 0, 0, 0, 0 }); // 아래
    try put(a, out, .{ .x = rc.x, .y = rc.y, .w = w[3], .h = rc.h }, border, .{ 0, 0, 0, 0 }); // 왼쪽
}

fn put(a: std.mem.Allocator, out: *std.ArrayList(SolidRect), rect: draw.Rect, argb: u32, radii: [4]u16) !void {
    if (rect.w == 0 or rect.h == 0) return;
    try out.append(a, .{ .rect = rect, .argb = argb, .radii = radii });
}

fn argbOf(tk: *const tokens.Tokens, role: tokens.ColorRole, alpha: u8) u32 {
    const c = tk.get(role);
    return (@as(u32, alpha) << 24) | (@as(u32, c.r) << 16) | (@as(u32, c.g) << 8) | c.b;
}

const testing = std.testing;

fn testTokens() tokens.Tokens {
    var tk = tokens.Tokens.rich(std.mem.zeroes(tokens.ThemeColors));
    tk.palette.set(.surface_bg, .{ .r = 30, .g = 30, .b = 30 });
    tk.palette.set(.focus_accent, .{ .r = 200, .g = 100, .b = 50 });
    tk.palette.set(.tab_hover_bg, .{ .r = 60, .g = 60, .b = 60 });
    return tk;
}

test "모달(확인 모달): 패널은 패딩만큼 키우고, 둥근 테두리는 바깥판 뒤에 들인 채움 — 그 뒤의 것은 띠 안쪽에만 선다" {
    // 실제 `confirm.view` 의 ops 로 잰다 — Windows 확인 모달이 이 길로 그린다(`main.zig` `appendConfirmSolids`).
    const confirm = @import("components/confirm.zig");
    const props = @import("props.zig");
    const tk = testTokens();
    var state: confirm.State = .{};
    state.show("실행 중인 명령이 있습니다. 닫을까요?", .{ .confirm = "닫기", .cancel = "취소" });
    const p: props.ChromeProps = .{
        .metrics = .{ .cell_width_px = 8, .cell_height_px = 16, .sidebar_width_px = 200, .backing_width_px = 1200, .backing_height_px = 800 },
        .shape = .fromTokens(&tk),
    };
    var arena_state = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var ops: std.ArrayList(draw.Op) = .empty;
    try confirm.view(&state, p, &tk, arena, &ops);
    const frame_q = for (ops.items) |op| {
        if (op == .quad) break op.quad;
    } else return error.NoFrameQuad;

    var out: std.ArrayList(SolidRect) = .empty;
    try flattenModal(arena, ops.items, &tk, &out);

    const r = tk.space.corner_radius_px;
    const bw = tk.space.border_width_px;
    const panel = frame_q.panelRect(tk.space.modal_padding_px);
    try testing.expect(panel.w > frame_q.rect.w); // 전제: rich 는 패딩이 있다
    try testing.expect(out.items.len >= 2);
    // 바깥판: 패널 전체를 테두리 색·둥근 모서리로.
    try testing.expectEqual(SolidRect{ .rect = panel, .argb = 0xFFC86432, .radii = .{ r, r, r, r } }, out.items[0]);
    // 들인 채움: 테두리 폭만큼 안쪽, 모서리도 그만큼 줄인다.
    const inner: draw.Rect = .{ .x = panel.x + bw, .y = panel.y + bw, .w = panel.w - 2 * bw, .h = panel.h - 2 * bw };
    try testing.expectEqual(SolidRect{ .rect = inner, .argb = 0xFF1E1E1E, .radii = .{ r - bw, r - bw, r - bw, r - bw } }, out.items[1]);
    // 띠를 덮는 것이 없다: 그 뒤의 것(버튼 배경)은 모두 테두리 안쪽에 선다.
    try testing.expect(out.items.len > 2); // 전제: 버튼 배경이 있다(빈 목록이면 아래가 공회전한다)
    for (out.items[2..]) |s| {
        try testing.expect(s.rect.x >= inner.x and s.rect.y >= inner.y);
        try testing.expect(s.rect.x + @as(i32, @intCast(s.rect.w)) <= inner.x + @as(i32, @intCast(inner.w)));
        try testing.expect(s.rect.y + @as(i32, @intCast(s.rect.h)) <= inner.y + @as(i32, @intCast(inner.h)));
    }
}

test "직각 테두리는 채움 **뒤에** 변 넷 — 앞에 두면 불투명 채움이 덮는다" {
    const tk = testTokens();
    const q: draw.Op.Quad = .{ .rect = .{ .x = 10, .y = 20, .w = 100, .h = 40 }, .fill_role = .surface_bg, .border_widths = .{ 1, 2, 3, 4 }, .border_role = .focus_accent };
    var out: std.ArrayList(SolidRect) = .empty;
    defer out.deinit(testing.allocator);
    try flatten(testing.allocator, &.{.{ .quad = q }}, &tk, &out);
    try testing.expectEqual(@as(usize, 5), out.items.len);
    try testing.expectEqual(SolidRect{ .rect = q.rect, .argb = 0xFF1E1E1E }, out.items[0]);
    try testing.expectEqual(SolidRect{ .rect = .{ .x = 10, .y = 20, .w = 100, .h = 1 }, .argb = 0xFFC86432 }, out.items[1]); // 위
    try testing.expectEqual(SolidRect{ .rect = .{ .x = 108, .y = 20, .w = 2, .h = 40 }, .argb = 0xFFC86432 }, out.items[2]); // 오른쪽
    try testing.expectEqual(SolidRect{ .rect = .{ .x = 10, .y = 57, .w = 100, .h = 3 }, .argb = 0xFFC86432 }, out.items[3]); // 아래
    try testing.expectEqual(SolidRect{ .rect = .{ .x = 10, .y = 20, .w = 4, .h = 40 }, .argb = 0xFFC86432 }, out.items[4]); // 왼쪽
}

test "테두리 알파는 border_alpha 를 따른다 — 채움 0 + 또렷한 테두리(현재 줄 상자)가 사라지지 않는다" {
    const tk = testTokens();
    const q: draw.Op.Quad = .{ .rect = .{ .x = 0, .y = 0, .w = 50, .h = 20 }, .fill_role = .surface_bg, .alpha = 0, .border_alpha = 0xFF, .border_widths = .{ 1, 1, 1, 1 }, .border_role = .focus_accent, .corner_radii = .{ 3, 3, 3, 3 } };
    var out: std.ArrayList(SolidRect) = .empty;
    defer out.deinit(testing.allocator);
    try flatten(testing.allocator, &.{.{ .quad = q }}, &tk, &out);
    // 채움이 비치므로 바깥판이 아니라 변 넷이다.
    try testing.expectEqual(@as(usize, 5), out.items.len);
    try testing.expectEqual(@as(u32, 0x00), out.items[0].argb >> 24);
    for (out.items[1..]) |s| try testing.expectEqual(@as(u32, 0xFF), s.argb >> 24);
}

test "모달의 패널 키우기: 첫 quad 가 둥글 때 그것 하나뿐 — 직각(기반 토큰)이면 macOS 처럼 안 키운다" {
    const tk = testTokens();
    const round: draw.Op.Quad = .{ .rect = .{ .x = 50, .y = 50, .w = 10, .h = 10 }, .fill_role = .surface_bg, .corner_radii = .{ 4, 4, 4, 4 } };
    const second: draw.Op.Quad = .{ .rect = .{ .x = 100, .y = 100, .w = 10, .h = 10 }, .fill_role = .surface_bg, .corner_radii = .{ 4, 4, 4, 4 } };
    var out: std.ArrayList(SolidRect) = .empty;
    defer out.deinit(testing.allocator);
    try flattenModal(testing.allocator, &.{ .{ .quad = round }, .{ .quad = second } }, &tk, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(round.panelRect(tk.space.modal_padding_px), out.items[0].rect);
    try testing.expectEqual(second.rect, out.items[1].rect); // 둘째 quad 는 키우지 않는다

    out.clearRetainingCapacity();
    const square: draw.Op.Quad = .{ .rect = .{ .x = 50, .y = 50, .w = 10, .h = 10 }, .fill_role = .surface_bg };
    try flattenModal(testing.allocator, &.{.{ .quad = square }}, &tk, &out);
    try testing.expectEqual(square.rect, out.items[0].rect);
}

test "그라디언트 quad 는 내지 않는다 — 단색 근사는 틀린 화면을 그럴듯하게 만든다" {
    const tk = testTokens();
    const grad: draw.Op.Quad = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .fill_role = .surface_bg, .gradient = .vertical, .fill_role_end = .focus_accent };
    var out: std.ArrayList(SolidRect) = .empty;
    defer out.deinit(testing.allocator);
    try flatten(testing.allocator, &.{.{ .quad = grad }}, &tk, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
}
