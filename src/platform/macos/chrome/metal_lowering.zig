//! macOS Chrome Metal lowering — backend-neutral `ChromeDraw`를 제품 Metal frame 입력으로 바꾼다.
//!
//! 이 leaf는 세션·PTY·provider·`AppSession`을 모른다. 일반 Chrome과 Chrome Lab이 같은
//! 변환을 공유하도록, semantic draw를 cell/quad/shadow 입력으로만 투영한다.

const std = @import("std");
const maru = @import("maru");
const chrome = maru.chrome;
const renderer = maru.renderer;
const terminal = maru.terminal;
const Rgb = maru.color.Rgb;
const metal_frame = renderer.metal_frame;

/// 한 Chrome overlay를 제품 frame에 합성하기 직전의 소유 버퍼.
pub const OverlayRaster = struct {
    cells: std.ArrayList(renderer.DrawCell),
    gpu_quads: std.ArrayList(metal_frame.GpuQuad),
    gpu_shadows: std.ArrayList(metal_frame.GpuShadow),
    cols: u16,
    rows: u16,
    origin_x: u32,
    origin_y: u32,
    cursor: ?terminal.Cursor = null,
    clip_rect: ?chrome.draw.Rect = null,
};

/// ChromeDraw의 painter order를 보존하며 셀과 rich GPU primitives로 투영한다.
/// `transparent_default`는 흩어진 단축키 배지가 하위 chrome/terminal을 가리지 않게 한다.
pub fn lower(
    allocator: std.mem.Allocator,
    draws: []const chrome.ChromeDraw,
    tk: *const chrome.Tokens,
    cw: u32,
    ch: u32,
    transparent_default: bool,
) !OverlayRaster {
    if (cw == 0 or ch == 0) return error.NoMetrics;

    var gpu_quads: std.ArrayList(metal_frame.GpuQuad) = .empty;
    errdefer gpu_quads.deinit(allocator);
    var gpu_shadows: std.ArrayList(metal_frame.GpuShadow) = .empty;
    errdefer gpu_shadows.deinit(allocator);

    var min_x: i32 = std.math.maxInt(i32);
    var min_y: i32 = std.math.maxInt(i32);
    var max_x: i32 = std.math.minInt(i32);
    var max_y: i32 = std.math.minInt(i32);
    var have_box = false;
    // 프레임 clip(`.clip` op)이 있는가 — 있으면 격자를 그 clip 끝까지 **올림**으로 덮는다(아래 rows).
    var frame_clip = false;
    for (draws) |d| for (d.ops) |op| {
        if (op == .clip) frame_clip = true;
        const rect: ?chrome.draw.Rect = switch (op) {
            .fill => |f| f.rect,
            .border => |b| b.rect,
            .quad => |q| q.rect,
            else => null,
        };
        if (rect) |rr| {
            have_box = true;
            min_x = @min(min_x, rr.x);
            min_y = @min(min_y, rr.y);
            max_x = @max(max_x, rr.x + @as(i32, @intCast(rr.w)));
            max_y = @max(max_y, rr.y + @as(i32, @intCast(rr.h)));
        }
    };
    if (!have_box) return error.NoBox;
    const origin_x: u32 = if (min_x < 0) 0 else @intCast(min_x);
    const origin_y: u32 = if (min_y < 0) 0 else @intCast(min_y);
    const cols_u = @as(u32, @intCast(@max(max_x - min_x, 0))) / cw;
    // 행 수는 보통 내림이다(상자 밖으로 셀을 안 낸다). **프레임 clip 이 있으면 올림** — 그 overlay 는 마지막 걸친 행을
    // clip 이 픽셀로 잘라 보이게 하는 계약이다(알림 패널: 뷰포트 바닥에 걸친 카드 줄, `docs/notifications.md`). 내림이면 그
    // 행이 격자에 없어 글자가 통째로 사라졌다 — 예전엔 패널 밖에 잘못 그어지던 구분선이 상자를 우연히 늘려 줘서만 보였다.
    // 넘친 몫은 같은 clip(셀 scissor, v169)이 자르므로 상자 밖에 그려지지 않는다.
    const span_y: u32 = @intCast(@max(max_y - min_y, 0));
    const rows_u = if (frame_clip) std.math.divCeil(u32, span_y, ch) catch unreachable else span_y / ch;
    if (cols_u == 0 or rows_u == 0) return error.TooSmall;
    const cols: u16 = @intCast(@min(cols_u, @as(u32, std.math.maxInt(u16))));
    const rows: u16 = @intCast(@min(rows_u, @as(u32, std.math.maxInt(u16))));

    const n = @as(usize, cols) * @as(usize, rows);
    const bg = try allocator.alloc(terminal.Color, n);
    defer allocator.free(bg);
    const fg = try allocator.alloc(terminal.Color, n);
    defer allocator.free(fg);
    const cp = try allocator.alloc(u21, n);
    defer allocator.free(cp);
    const cwid = try allocator.alloc(u2, n);
    defer allocator.free(cwid);
    const surface_bg = terminal.Color{ .rgb = tk.get(.surface_bg) };
    @memset(bg, surface_bg);
    @memset(fg, terminal.Color{ .rgb = tk.get(.surface_fg) });
    @memset(cp, ' ');
    @memset(cwid, 1);

    // 첫 rounded quad는 overlay의 배경·shadow이고, 그 뒤 rounded quad는 선택 행 위에 떠야 하는 widget이다.
    // 이 painter-order 규칙을 lowerer 한 곳에 둬 cell과 GPU pass의 z-order가 갈라지지 않게 한다.
    var cursor: ?terminal.Cursor = null;
    var clip_rect: ?chrome.draw.Rect = null;
    var modal_bg_quad = false;
    for (draws) |d| {
        var panel_bg_quad = false;
        const background_seen = if (d.independent_panel) &panel_bg_quad else &modal_bg_quad;
        for (d.ops) |op| switch (op) {
            .fill => |f| {
                if (f.role == .cursor) {
                    const col = @divTrunc(f.rect.x - @as(i32, @intCast(origin_x)), @as(i32, @intCast(cw)));
                    const row = @divTrunc(f.rect.y - @as(i32, @intCast(origin_y)), @as(i32, @intCast(ch)));
                    if (col >= 0 and col < cols and row >= 0 and row < rows)
                        cursor = .{ .row = @intCast(row), .col = @intCast(col), .visible = true };
                } else if (isHairline(f.rect, cw, ch)) {
                    // 셀보다 얇은 fill(구분선 등)은 **셀 격자로 표현할 수 없다.** paintRectBg는 픽셀 rect를
                    // `trunc(y/ch) .. trunc((y+h)/ch)` 행 범위로 내리므로, 1px이 행 마지막 픽셀에 걸리면 그 행이
                    // **통째로** 칠해지고(알림 카드 구분선이 18px 회색 밴드로 보이던 결함) 행 중간에 걸리면
                    // r0==r1이라 **아예 안 보인다**. 위치에 따라 둘 중 하나라 규율로 피할 수도 없다.
                    //
                    // 그래서 헤어라인만 GPU quad로 내린다 — `.swatch`/`.quad`가 "둥근 모서리는 셀로 못 그리니
                    // quad로"와 같은 규칙이고, 여기서는 '두께'가 그 이유다. 모달 배경 quad보다 **뒤에** append돼
                    // 같은 over 버킷 안에서 위에 그려진다(배경이 먼저 나오는 것은 lowerer의 painter 규칙).
                    appendHairline(&gpu_quads, allocator, f.rect, f.role, tk);
                } else paintRectBg(bg, cols, rows, origin_x, origin_y, cw, ch, f.rect, .{ .rgb = tk.get(f.role) }, null);
            },
            .border => |b| if (!background_seen.*) paintRectBg(bg, cols, rows, origin_x, origin_y, cw, ch, b.rect, .{ .rgb = tk.get(b.role) }, b.sides),
            .text => |t| placeText(cp, fg, cwid, cols, rows, origin_x, origin_y, cw, ch, t, tk),
            .swatch => |sw| {
                const rounded = sw.corner_radii[0] != 0 or sw.corner_radii[1] != 0 or sw.corner_radii[2] != 0 or sw.corner_radii[3] != 0;
                if (!rounded) {
                    paintRectBg(bg, cols, rows, origin_x, origin_y, cw, ch, sw.rect, .{ .rgb = sw.rgb }, null);
                } else appendSwatch(&gpu_quads, allocator, sw);
            },
            .rule => {},
            .clip => |rect| clip_rect = rect,
            .quad => |q| {
                const rounded = q.corner_radii[0] != 0 or q.corner_radii[1] != 0 or q.corner_radii[2] != 0 or q.corner_radii[3] != 0;
                if (!rounded and (!d.independent_panel or background_seen.*)) {
                    paintRectBg(bg, cols, rows, origin_x, origin_y, cw, ch, q.rect, .{ .rgb = tk.get(q.fill_role) }, null);
                } else if (background_seen.*) {
                    appendWidgetQuad(&gpu_quads, allocator, q, tk);
                } else {
                    appendModalQuad(&gpu_quads, &gpu_shadows, allocator, q, tk);
                    background_seen.* = true;
                    modal_bg_quad = true;
                }
            },
        };
    }

    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    try cells.ensureTotalCapacity(allocator, n);
    var row: u16 = 0;
    while (row < rows) : (row += 1) {
        var col: u16 = 0;
        while (col < cols) {
            const idx = @as(usize, row) * @as(usize, cols) + col;
            const width = cwid[idx];
            if ((modal_bg_quad or transparent_default) and cp[idx] == ' ' and std.meta.eql(bg[idx], surface_bg)) {
                col += if (width == 2) 2 else 1;
                continue;
            }
            const cell_bg: terminal.Color = if ((modal_bg_quad or transparent_default) and std.meta.eql(bg[idx], surface_bg)) .default else bg[idx];
            cells.appendAssumeCapacity(.{ .row = row, .col = col, .codepoint = cp[idx], .width = width, .style = .{ .foreground = fg[idx], .background = cell_bg } });
            col += if (width == 2) 2 else 1;
        }
    }
    return .{ .cells = cells, .gpu_quads = gpu_quads, .gpu_shadows = gpu_shadows, .cols = cols, .rows = rows, .origin_x = origin_x, .origin_y = origin_y, .cursor = cursor, .clip_rect = clip_rect };
}

/// 셀 격자로 표현할 수 없는 얇은 rect인가 — 한 축이라도 셀보다 얇으면 그렇다(가로선 h<ch·세로선 w<cw).
/// 셀 하나가 최소 단위라 이보다 얇은 것은 반올림되어 **행/열 전체**가 되거나 사라진다.
fn isHairline(rect: chrome.draw.Rect, cw: u32, ch: u32) bool {
    return rect.h < ch or rect.w < cw;
}

/// 헤어라인 fill을 픽셀 그대로의 GPU quad로 낸다(모서리 곡률·테두리 없음). layer 1 = 모달 위젯 층 —
/// 모달 배경 quad와 같은 층이되 뒤에 append되므로 그 위에 그려진다.
fn appendHairline(quads: *std.ArrayList(metal_frame.GpuQuad), allocator: std.mem.Allocator, rect: chrome.draw.Rect, role: chrome.tokens.ColorRole, tk: *const chrome.Tokens) void {
    appendQuad(quads, allocator, rect, .{ 0, 0, 0, 0 }, .{ 0, 0, 0, 0 }, role, null, tk, 1, null);
}

fn appendSwatch(quads: *std.ArrayList(metal_frame.GpuQuad), allocator: std.mem.Allocator, sw: chrome.draw.Op.Swatch) void {
    const fill = packOpaqueRgb(sw.rgb);
    quads.append(allocator, .{ .x = @floatFromInt(sw.rect.x), .y = @floatFromInt(sw.rect.y), .w = @floatFromInt(sw.rect.w), .h = @floatFromInt(sw.rect.h), .corner_radii = .{ @floatFromInt(sw.corner_radii[0]), @floatFromInt(sw.corner_radii[1]), @floatFromInt(sw.corner_radii[2]), @floatFromInt(sw.corner_radii[3]) }, .border_widths = .{ 0, 0, 0, 0 }, .fill_color0 = fill, .fill_color1 = fill, .border_color = 0, .gradient_kind = 0, .layer = 3 }) catch {};
}

fn appendWidgetQuad(quads: *std.ArrayList(metal_frame.GpuQuad), allocator: std.mem.Allocator, q: chrome.draw.Op.Quad, tk: *const chrome.Tokens) void {
    appendQuad(quads, allocator, q.rect, q.corner_radii, q.border_widths, q.fill_role, q.border_role, tk, 3, q.clip);
}

fn appendModalQuad(quads: *std.ArrayList(metal_frame.GpuQuad), shadows: *std.ArrayList(metal_frame.GpuShadow), allocator: std.mem.Allocator, q: chrome.draw.Op.Quad, tk: *const chrome.Tokens) void {
    // content rect와 box shadow가 같은 outset box를 공유해야 padding·border·shadow의 가장자리가 어긋나지 않는다.
    const p = tk.space.modal_padding_px;
    const box = q.rect.outset(.{ .left = p, .right = p, .top = p, .bottom = p });
    // **여기만 clip을 전달하지 않는다.** 위에서 rect를 padding만큼 **키웠으므로** component가 실은 clip
    // (키우기 전 rect 기준)과 좌표계가 어긋난다. 그대로 적용하면 방금 더한 padding과 그 그림자가 잘린다.
    // clip을 함께 키우는 것도 답이 아니다 — clip은 "여기까지만 그린다"는 약속이라 넓히면 그 약속이 깨진다
    // (`ui/tree.zig`가 스크롤바 gutter에서 같은 이유로 상한을 함께 본다). 모달은 최상위 오버레이라 자를
    // 컨테이너가 없으므로 null이 맞다. clip을 존중해야 하는 것은 outset이 없는 widget quad 쪽이다.
    appendQuad(quads, allocator, box, q.corner_radii, q.border_widths, q.fill_role, q.border_role, tk, 1, null);
    shadows.append(allocator, .{ .x = @floatFromInt(box.x), .y = @as(f32, @floatFromInt(box.y)) + @as(f32, @floatFromInt(tk.space.shadow_offset_y_px)), .w = @floatFromInt(box.w), .h = @floatFromInt(box.h), .corner_radii = .{ @floatFromInt(q.corner_radii[0]), @floatFromInt(q.corner_radii[1]), @floatFromInt(q.corner_radii[2]), @floatFromInt(q.corner_radii[3]) }, .blur_radius = @floatFromInt(tk.space.shadow_blur_px), .color = @as(u32, tk.space.shadow_alpha) << 24 }) catch {};
}

fn appendQuad(quads: *std.ArrayList(metal_frame.GpuQuad), allocator: std.mem.Allocator, rect: chrome.draw.Rect, radii: [4]u16, widths: [4]u16, fill_role: chrome.tokens.ColorRole, border_role: ?chrome.tokens.ColorRole, tk: *const chrome.Tokens, layer: u32, clip: ?chrome.draw.Rect) void {
    // 면적 0 clip은 "한 픽셀도 안 보인다"인데 shader 규약은 폭 0을 **"클립 없음"**으로 읽는다
    // (maru_metal_shader.h). 제품 lowerer(`chrome_draw_lowering`)와 같은 판정을 여기서도 해야 Lab
    // 골든이 제품과 같은 그림을 증명한다 — 이 경로가 clip을 통째로 버리고 있어서, 스크롤로 뷰포트를
    // 벗어난 카드 배경이 고정 chrome 위에 그려진 사용자 보고를 골든이 **재현조차 못 했다**.
    if (clip) |c| if (c.w == 0 or c.h == 0) return;
    const fill = packOpaqueRgb(tk.get(fill_role));
    const border = if (border_role) |role| packOpaqueRgb(tk.get(role)) else 0;
    quads.append(allocator, .{ .x = @floatFromInt(rect.x), .y = @floatFromInt(rect.y), .w = @floatFromInt(rect.w), .h = @floatFromInt(rect.h), .corner_radii = .{ @floatFromInt(radii[0]), @floatFromInt(radii[1]), @floatFromInt(radii[2]), @floatFromInt(radii[3]) }, .border_widths = .{ @floatFromInt(widths[0]), @floatFromInt(widths[1]), @floatFromInt(widths[2]), @floatFromInt(widths[3]) }, .fill_color0 = fill, .fill_color1 = fill, .border_color = border, .gradient_kind = 0, .layer = layer, .clip_x = if (clip) |c| @floatFromInt(c.x) else 0, .clip_y = if (clip) |c| @floatFromInt(c.y) else 0, .clip_w = if (clip) |c| @floatFromInt(c.w) else 0, .clip_h = if (clip) |c| @floatFromInt(c.h) else 0 }) catch {};
}

fn paintRectBg(bg: []terminal.Color, cols: u16, rows: u16, origin_x: u32, origin_y: u32, cw: u32, ch: u32, rect: chrome.draw.Rect, color: terminal.Color, sides: ?chrome.draw.Sides) void {
    const ox: i32 = @intCast(origin_x);
    const oy: i32 = @intCast(origin_y);
    const c0 = std.math.clamp(@divTrunc(rect.x - ox, @as(i32, @intCast(cw))), 0, @as(i32, cols));
    const r0 = std.math.clamp(@divTrunc(rect.y - oy, @as(i32, @intCast(ch))), 0, @as(i32, rows));
    const c1 = std.math.clamp(@divTrunc(rect.x + @as(i32, @intCast(rect.w)) - ox, @as(i32, @intCast(cw))), 0, @as(i32, cols));
    const r1 = std.math.clamp(@divTrunc(rect.y + @as(i32, @intCast(rect.h)) - oy, @as(i32, @intCast(ch))), 0, @as(i32, rows));
    var row: i32 = r0;
    while (row < r1) : (row += 1) {
        var col: i32 = c0;
        while (col < c1) : (col += 1) {
            const on_edge = if (sides) |s| (s.top and row == r0) or (s.bottom and row == r1 - 1) or (s.left and col == c0) or (s.right and col == c1 - 1) else true;
            if (on_edge) bg[@as(usize, @intCast(row)) * @as(usize, cols) + @as(usize, @intCast(col))] = color;
        }
    }
}

fn placeText(cp: []u21, fg: []terminal.Color, cwid: []u2, cols: u16, rows: u16, origin_x: u32, origin_y: u32, cw: u32, ch: u32, t: chrome.draw.Op.Text, tk: *const chrome.Tokens) void {
    // 이 경로는 셀 격자에 찍으므로 부분 클립이 불가능하다. 대신 셀 단위로 판정한다 — 같은 행의 배경
    // quad는 GPU가 픽셀 단위로 자르는데 글자만 그대로 남으면 배경 반쪽에 글자가 떠 있는 그림이 된다.
    // ⚠️ 이 남김/버림 규칙(origin 이 clip 안 · 행 = trunc)은 알림 패널의 강조 배경이 **그대로 따라 쓴다**
    // (`components/notifications.zig` view — clip 이 없는 `.fill` 을 줄마다 같은 조건으로 낸다). 바꾸면 그쪽도
    // 함께 — 판정자 「알림 패널: 걸친 카드의 강조 배경은 …」이 실제 배치된 글자 행과 비교해 어긋남을 잡는다.
    if (t.clip) |clip| {
        if (t.origin.y < clip.y or t.origin.y >= clip.y + @as(i32, @intCast(clip.h))) return;
        if (t.origin.x < clip.x or t.origin.x >= clip.x + @as(i32, @intCast(clip.w))) return;
    }
    const row_i = @divTrunc(t.origin.y - @as(i32, @intCast(origin_y)), @as(i32, @intCast(ch)));
    if (row_i < 0 or row_i >= rows) return;
    const row: usize = @intCast(row_i);
    var col_i = @divTrunc(t.origin.x - @as(i32, @intCast(origin_x)), @as(i32, @intCast(cw)));
    for (t.runs) |run| {
        // **run 이 제 색을 가지면 그것이 이긴다**(`run.role orelse text.role`) — 제품 lowering
        // (`chrome_draw_lowering.zig`)이 쓰는 것과 **같은 규칙**이다.
        //
        // 이 줄이 없어서 Lab 캡처가 무색이었다: 구문 색이 op 의 run 까지 흘렀는데 여기서
        // op 색 하나로 덮였다. **캡처 하네스가 그 기능을 원리상 못 밟는 상태**였고, 그래서
        // 골든 게이트도 색 회귀를 잡을 수 없었다(2026-08-28 실측).
        const color: terminal.Color = .{ .rgb = tk.get(run.role orelse t.role) };
        const view = std.unicode.Utf8View.init(run.text) catch continue;
        var it = view.iterator();
        while (it.nextCodepoint()) |codepoint| {
            // wide 문자는 한 DrawCell의 width=2로 남기고 continuation cell은 emit하지 않는다. 그렇지 않으면
            // continuation의 배경 quad가 CoreText glyph의 오른쪽 절반을 덮어 한글/CJK가 잘린다.
            const width: u2 = if (t.wide_icons and renderer.icon_glyph.isRegisteredIcon(codepoint))
                chrome.ui.icon.chrome_run_span
            else
                @max(1, terminal.width.cellWidth(codepoint));
            if (col_i >= 0 and col_i < cols) {
                const idx = row * @as(usize, cols) + @as(usize, @intCast(col_i));
                cp[idx] = codepoint;
                fg[idx] = color;
                cwid[idx] = @intCast(@min(width, 2));
            }
            col_i += width;
        }
    }
}

fn packOpaqueRgb(rgb: Rgb) u32 {
    return 0xFF000000 | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

test "Lab lowering carries the component clip and drops a quad whose clip has zero area" {
    // 적대적 검증에서 찾은 갭(2026-08-12): 이 경로는 `Op.Quad.clip`을 통째로 버리고 있었다. 제품
    // lowerer(`chrome_draw_lowering`)는 같은 값을 GpuQuad에 실어 shader가 자르게 한다. 두 host가
    // 갈리면 Lab 골든은 **제품과 다른 그림**을 증명한다 — 실제로 "스크롤로 뷰포트를 벗어난 카드 배경이
    // 고정 chrome 위에 그려진다"는 사용자 보고를 이 경로로는 재현조차 할 수 없었다.
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    const ops = [_]chrome.draw.Op{
        // 첫 rounded quad는 modal 배경 경로다(padding outset + shadow).
        .{ .quad = .{
            .rect = .{ .x = 0, .y = 0, .w = 160, .h = 64 },
            .fill_role = .surface_bg,
            .corner_radii = .{ 8, 8, 8, 8 },
            .clip = .{ .x = 0, .y = 0, .w = 160, .h = 32 },
        } },
        // 그 뒤는 widget 경로다. 면적이 있는 clip은 그대로 실려야 한다.
        .{ .quad = .{
            .rect = .{ .x = 0, .y = 0, .w = 160, .h = 64 },
            .fill_role = .surface_bg,
            .corner_radii = .{ 8, 8, 8, 8 },
            .clip = .{ .x = 0, .y = 0, .w = 160, .h = 24 },
        } },
        // 면적 0 clip은 "한 픽셀도 안 보인다"이므로 아예 나가면 안 된다 — shader는 폭 0을
        // "클립 없음"으로 읽어 정반대로 자르지 않은 quad를 그린다.
        .{ .quad = .{
            .rect = .{ .x = 0, .y = -400, .w = 160, .h = 64 },
            .fill_role = .surface_bg,
            .corner_radii = .{ 8, 8, 8, 8 },
            .clip = .{ .x = 0, .y = 0, .w = 160, .h = 0 },
        } },
    };

    var raster = try lower(std.testing.allocator, &.{.{ .layer = .sidebar, .ops = &ops }}, &tk, 8, 16, true);
    defer {
        raster.cells.deinit(std.testing.allocator);
        raster.gpu_quads.deinit(std.testing.allocator);
        raster.gpu_shadows.deinit(std.testing.allocator);
    }

    // modal 배경(첫 rounded quad)은 padding만큼 **키운** box를 그리므로 clip을 전달하지 않는다 — 키우기
    // 전 rect 기준의 clip을 적용하면 그 padding이 잘린다. 그래서 남는 것은 widget quad 하나뿐이고,
    // 그 quad가 component의 clip을 그대로 들고 있어야 한다.
    try std.testing.expectEqual(@as(usize, 2), raster.gpu_quads.items.len);
    try std.testing.expectEqual(@as(f32, 0), raster.gpu_quads.items[0].clip_w);
    const widget = raster.gpu_quads.items[1];
    try std.testing.expectEqual(@as(f32, 160), widget.clip_w);
    try std.testing.expectEqual(@as(f32, 24), widget.clip_h);
}

test "EF31 independent find panels each retain their background and shadow" {
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 9, .g = 9, .b = 9 }) };
    for ([_]u16{ 0, 8 }) |radius| {
        const left = [_]chrome.draw.Op{.{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 160, .h = 64 }, .fill_role = .surface_bg, .corner_radii = .{ radius, radius, radius, radius } } }};
        const right = [_]chrome.draw.Op{.{ .quad = .{ .rect = .{ .x = 320, .y = 0, .w = 160, .h = 64 }, .fill_role = .surface_bg, .corner_radii = .{ radius, radius, radius, radius } } }};
        var raster = try lower(std.testing.allocator, &.{
            .{ .layer = .modal, .ops = &left, .independent_panel = true },
            .{ .layer = .modal, .ops = &right, .independent_panel = true },
        }, &tk, 8, 16, false);
        defer {
            raster.cells.deinit(std.testing.allocator);
            raster.gpu_quads.deinit(std.testing.allocator);
            raster.gpu_shadows.deinit(std.testing.allocator);
        }
        try std.testing.expectEqual(@as(usize, 2), raster.gpu_quads.items.len);
        try std.testing.expectEqual(@as(usize, 2), raster.gpu_shadows.items.len);
        try std.testing.expectEqual(raster.gpu_quads.items[0].w, raster.gpu_quads.items[1].w);
        try std.testing.expectEqual(raster.gpu_quads.items[0].h, raster.gpu_quads.items[1].h);
        try std.testing.expectEqual(@as(usize, 0), raster.cells.items.len);
    }
}

// ML3b 경계: 알림 패널을 스크롤해 카드가 뷰포트 경계(위·아래)에 걸치면, 그 카드의 강조 배경(선택·호버)은 **헤더와
// 뷰포트 밖을 칠하지 않고**, 칠한 행은 그 카드의 글자가 놓인 행과 **같아야** 한다. `.fill` 은 셀 행 단위(`trunc`)로
// 내려가고 카드 프레임 clip 은 패널 전체(헤더 포함)라, 컴포넌트가 배경을 글자와 같은 규칙(줄마다, origin 이 뷰포트
// 안일 때만)으로 내지 않으면 위로 걸친 카드의 첫 행이 헤더 행으로 내림돼 헤더 한 줄이 통째로 카드색이 됐다(2026-10-06
// 실측 — 1px 만 밀려도). 뷰포트 사각형으로 자르면 이번엔 아래로 걸친 줄의 배경이 빠진다. 제품과 같은 lowering 을 탄다.
test "알림 패널: 걸친 카드의 강조 배경은 헤더·뷰포트 밖을 칠하지 않고, 그 카드 글자가 놓인 행만 칠한다 (ML3b)" {
    const notifications = chrome.components.notifications;
    var pal = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 10, .g = 10, .b = 10 });
    pal.set(.tab_active_bg, .{ .r = 200, .g = 0, .b = 0 });
    pal.set(.tab_hover_bg, .{ .r = 0, .g = 200, .b = 0 });
    const tk = chrome.Tokens{ .palette = pal };
    const cw: u32 = 8;
    const gutter_px: u32 = 24; // 카드 폭 < 패널 폭 — 강조가 gutter 까지 칠하면 잡힌다
    // 넘치게 — 카드를 실제로 걸치게 하려면 스크롤 상한이 카드 한 장보다 커야 한다.
    const count = 40;
    // **카드마다 다른 글자**다(제목 U+0100+i, 본문 U+0180+i). 모두 같은 글자면 구분선이 «남의 카드» 본문 행 바닥에
    // 있어도 통과한다. 출력 셀에서 카드별 제목·본문 행을 읽어 «선이 있어야 할 자리»를 제품 공식과 **따로** 구한다.
    var title_utf8: [count][4]u8 = undefined;
    var body_utf8: [count][4]u8 = undefined;
    var title_len: [count]u3 = undefined;
    var body_len: [count]u3 = undefined;
    for (0..count) |i| {
        title_len[i] = try std.unicode.utf8Encode(@intCast(0x100 + i), &title_utf8[i]);
        body_len[i] = try std.unicode.utf8Encode(@intCast(0x180 + i), &body_utf8[i]);
    }
    // 경계마다 «그 카드 글자가 실제로 보인» 경우를 센다 — 둘 다 빈 집합이면 `lit == text` 는 그냥 참이다.
    var seen_top: usize = 0;
    var seen_bottom: usize = 0;
    var dividers_checked: usize = 0;
    // 기하를 바꿔 돈다 — 패널 y 가 0 이고 셀 높이·뷰포트가 한 가지면 «rect.y 를 빼먹은» 공식이나 바닥 경계 off-by-one 이
    // 출력 바이트까지 같아 통과했다(적대적 검증). 제품 패널 y 는 `2ch + modal padding` 이라 행 배수가 아니다.
    for ([_]u32{ 16, 17 }) |ch| for ([_]i32{ 0, 7 }) |anchor_y| for ([_]u32{ 300, 303, 305 }) |backing_h| {
        const p = chrome.props.ChromeProps{ .metrics = .{ .cell_width_px = cw, .cell_height_px = ch, .sidebar_width_px = 0, .backing_width_px = 800, .backing_height_px = backing_h, .overlay_scroll_gutter_px = gutter_px } };
        const card_px: u32 = 2 * ch;
        var shift: u32 = 0;
        while (shift < card_px) : (shift += 1) {
            // 위(맨 위 카드)와 아래(맨 아래 카드) 경계를 따로 본다.
            for ([_]bool{ true, false }) |top_edge| {
                // 0 = 선택, 1 = 호버, 2 = 강조 없음(강조 fill 이 상자를 늘려 걸친 행을 «우연히» 살리는 일이 없는 경우 —
                // 사용자가 가장 흔히 보는 상태다).
                for ([_]u8{ 0, 1, 2 }) |mode| {
                    var s: notifications.State = .{};
                    var items_buf: [count]notifications.Item = undefined;
                    for (&items_buf, 0..) |*it, i| it.* = .{ .title = title_utf8[i][0..title_len[i]], .body = body_utf8[i][0..body_len[i]], .relative_time = "now", .is_read = true, .is_alive = true };
                    s.show(0, anchor_y, count);
                    s.scroll.offset_y_px = card_px + shift;
                    const sv = notifications.scrollView(&s, &items_buf, p) orelse return error.NotScrollable;
                    try std.testing.expectEqual(card_px + shift, sv.offset_px); // 상한에 안 깎였다(전제)
                    const target: usize = if (top_edge) 1 else (card_px + shift + sv.viewport.h - 1) / card_px; // 걸친 카드
                    items_buf[target].title = "Q";
                    items_buf[target].body = "W";
                    s.selected = 0; // 화면 위로 지나간 카드 — 선택색이 다른 경우의 판정에 섞이지 않게
                    switch (mode) {
                        0 => s.selected = target,
                        1 => s.hovered = target,
                        else => {},
                    }
                    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
                    defer arena_state.deinit();
                    var out: std.ArrayList(chrome.draw.Op) = .empty;
                    try notifications.view(&s, &items_buf, p, &tk, arena_state.allocator(), &out);
                    var raster = try lower(std.testing.allocator, &.{.{ .layer = .modal, .ops = out.items }}, &tk, cw, ch, false);
                    defer {
                        raster.cells.deinit(std.testing.allocator);
                        raster.gpu_quads.deinit(std.testing.allocator);
                        raster.gpu_shadows.deinit(std.testing.allocator);
                    }
                    try std.testing.expectEqual(@as(u32, @intCast(anchor_y)), raster.origin_y); // 격자 원점 = 패널 y(전제 — 행 배수가 아닐 수 있다)
                    const ch_i: i32 = @intCast(ch);
                    const ox: i32 = @intCast(raster.origin_x);
                    const oy: i32 = @intCast(raster.origin_y);
                    const vp_bottom = sv.viewport.y + @as(i32, @intCast(sv.viewport.h));
                    const first_row = @divTrunc(sv.viewport.y - oy, ch_i); // 헤더 바로 아래 행
                    const end_row = @divTrunc(vp_bottom - oy, ch_i);
                    var lit_rows = std.StaticBitSet(64).initEmpty();
                    var text_rows = std.StaticBitSet(64).initEmpty();
                    // 카드별로 출력에 실제로 놓인 제목·본문 행(없으면 null).
                    var title_row: [count]?u16 = @splat(null);
                    var body_row: [count]?u16 = @splat(null);
                    for (raster.cells.items) |c| {
                        const bg = c.style.background;
                        const lit = bg == .rgb and bg.rgb.b == 0 and (bg.rgb.r == 200 or bg.rgb.g == 200);
                        if (lit) {
                            try std.testing.expect(@as(i32, c.row) >= first_row); // 헤더를 칠하지 않는다
                            try std.testing.expect(@as(i32, c.row) <= end_row); // 뷰포트 아래로 안 나간다
                            // gutter(스크롤바 자리)를 칠하지 않는다 — 카드 폭은 패널 폭에서 gutter 를 뺀 것 이하다.
                            try std.testing.expect(ox + (@as(i32, c.col) + 1) * @as(i32, @intCast(cw)) <= sv.viewport.x + @as(i32, @intCast(sv.viewport.w - gutter_px)));
                            lit_rows.set(c.row);
                        }
                        switch (c.codepoint) {
                            'Q' => {
                                text_rows.set(c.row);
                                title_row[target] = c.row;
                            },
                            'W' => {
                                text_rows.set(c.row);
                                body_row[target] = c.row;
                            },
                            0x100...0x100 + count - 1 => title_row[c.codepoint - 0x100] = c.row,
                            0x180...0x180 + count - 1 => body_row[c.codepoint - 0x180] = c.row,
                            else => {},
                        }
                    }
                    // 칠한 행 == 그 카드 글자가 놓인 행(둘 다 같은 뷰포트로 잘린다). 걸친 몫이 셀보다 작아 글자가
                    // 하나도 안 남으면 칠한 행도 없다.
                    if (mode == 2) {
                        try std.testing.expectEqual(@as(usize, 0), lit_rows.count()); // 강조 없음
                    } else try std.testing.expect(lit_rows.eql(text_rows));
                    // 뷰포트 안에 origin 이 있는 그 카드의 줄은 **실제로 그려진다** — 바닥에 걸친 반쪽 줄 포함(프레임 clip 이
                    // 픽셀로 자른다). 격자가 그 행을 안 덮으면 글자가 통째로 사라진다.
                    {
                        const card_y: i32 = sv.viewport.y + @as(i32, @intCast(target * card_px)) - @as(i32, @intCast(card_px + shift));
                        var expected: usize = 0;
                        for ([_]i32{ card_y, card_y + ch_i }) |line_y| {
                            if (line_y >= sv.viewport.y and line_y < vp_bottom) expected += 1;
                        }
                        try std.testing.expectEqual(expected, text_rows.count());
                    }
                    // 카드 구분선(1px GPU quad — 셀 scissor 를 안 받는다)은 **두 카드의 글자 줄 사이에, 정확히 하나씩**
                    // 그어진다: 카드 i 의 본문 행과 카드 i+1 의 제목 행이 **둘 다** 출력에 놓였으면 그 사이 픽셀(제목 행 바로 위)에.
                    // 기대 집합은 제품 공식이 아니라 출력 셀에서 구한다. 예전엔 선이 카드 픽셀 바닥이라 걸친 만큼 제목줄을
                    // 가로질렀고(2026-10-06 사용자 지적, 「● Maru」 취소선), 아래 줄이 뷰포트 밖이면 패널 밖·바닥 테두리에 붙었다.
                    var expected_lines: [count]i32 = undefined;
                    var expected_n: usize = 0;
                    for (0..count - 1) |i| {
                        const b = body_row[i] orelse continue;
                        const t = title_row[i + 1] orelse continue;
                        try std.testing.expectEqual(b + 1, t); // 줄이 행에 빈틈없이 놓인다(전제)
                        expected_lines[expected_n] = oy + @as(i32, t) * ch_i - 1;
                        expected_n += 1;
                    }
                    var actual_lines: [count]i32 = undefined;
                    var actual_n: usize = 0;
                    var header_lines: usize = 0;
                    for (raster.gpu_quads.items) |q| {
                        if (q.h != 1) continue;
                        const qy: i32 = @intFromFloat(q.y);
                        if (qy == sv.viewport.y - 1) { // 헤더 구분선 — 위로 지나간 카드의 선이 이 자리에 겹쳐 그어지면 안 된다
                            header_lines += 1;
                            continue;
                        }
                        try std.testing.expect(qy >= sv.viewport.y and qy < vp_bottom); // 뷰포트 안
                        if (actual_n == count) return error.TooManyDividers;
                        actual_lines[actual_n] = qy;
                        actual_n += 1;
                    }
                    try std.testing.expectEqual(@as(usize, 1), header_lines);
                    std.mem.sort(i32, actual_lines[0..actual_n], {}, std.sort.asc(i32));
                    try std.testing.expectEqualSlices(i32, expected_lines[0..expected_n], actual_lines[0..actual_n]);
                    dividers_checked += expected_n;
                    if (text_rows.count() > 0) {
                        if (top_edge) seen_top += 1 else seen_bottom += 1;
                    }
                }
            }
        }
    };
    // 기하 12 가지 × 위 걸침이 글자를 남기는 걸침(0..ch) × 선택/호버/없음 — 대략 12 × 17 × 3.
    try std.testing.expect(seen_top >= 12 * 16 * 3);
    try std.testing.expect(seen_bottom >= 12 * 32 * 3); // 아래 경계 카드는 늘 무언가 보인다
    // 화면마다 카드 사이 선이 여러 개 실제로 있었다(빈 집합이면 위 집합 비교는 공짜다).
    try std.testing.expect(dividers_checked >= 12 * 32 * 2 * 3 * 5);
}
