//! Semantic Chrome draw의 macOS renderer adapter.
//!
//! 각 `chrome.components.*`는 semantic `ChromeDraw`와 rect tree까지만 소유한다. 이 파일은
//! 그 결과를 실제 앱의 CoreText `DrawList`와 Metal background quad로 한 방향 투영한다.
//! 따라서 archive/AppSession 좌표 계산이나 provider 문자열 조립은 여기로 들어올 수 없으며,
//! hit rect와 paint rect의 권위는 계속 component tree 하나다.

const std = @import("std");
const maru = @import("maru");
const chrome = maru.chrome;
const icons = maru.icons; // 등록 chrome 아이콘 이름↔PUA codepoint(생성물)
const renderer = maru.renderer;
const colorUv = renderer.metal_frame.colorUv; // 컬러 글리프 UV sentinel 단일 출처(u0·u1 동일 규약)
const terminal = maru.terminal;
const metal_frame = renderer.metal_frame;
const system_text = @import("system_text.zig");

/// `appendBackgroundQuads`의 `layer` 인자에 쓰는 합성 층 이름. 값의 뜻은 `maru_metal_renderer.m`의
/// **네 패스 배치**가 정하고, 여기서는 그 숫자에 이름을 준다.
///
/// **왜 이름이 필요한가.** 렌더러는 `2`·`0`·`4`만 이름 있는 패스로 나누고 **나머지를 전부 over로
/// 몰아넣는다** — 그래서 `3`도 "동작은 한다"(over에 그려진다). 그 관용이 오타를 침묵시킨다. 실제로
/// 편집기 배경이 `3`으로 실려 자기 본문 글자를 통째로 덮었고, 같은 컴포넌트를 그리는 Chrome Lab은
/// `2`를 쓰고 있었는데 **두 호출처가 갈린 것을 아무것도 강제하지 않았다**(2026-08-13).
/// 한 컴포넌트를 여러 곳에서 내린다면 그 층을 이 이름들로 부르고, 이름이 없으면 새로 만든다.
pub const layers = struct {
    /// 사이드바 밴드 — 셀 패스 뒤(part1 뒤·part2 앞).
    pub const under: u32 = 0;
    /// 모달 등 최상위 — 셀 위.
    pub const over: u32 = 1;
    /// **셀 패스 앞**(유일). 텍스트 **밑에** 깔리는 배경은 전부 여기다 — 도크·탐색기·편집기 본문.
    pub const bottom: u32 = 2;
    /// 사이드바 bg strip 뒤·헤더 글리프 앞. 알림 종 배지처럼 글리프를 덮으면 안 되는 장식만.
    pub const header: u32 = 4;
};

/// 이 층이 **셀·글리프보다 아래**인가. 컴포넌트 배경(자기 글자를 덮으면 안 되는 quad)이 실려도
/// 되는 층인지 묻는 자리다.
///
/// **`under`(0)는 아래가 아니다.** 이름이 그렇게 읽히지만 렌더러는 그것을 part1 셀 **뒤**에 그린다
/// (part2 앞일 뿐이다) — 그래서 part1에 글자를 내는 컴포넌트의 배경을 `under`에 실으면 `3`과 똑같이
/// 글자가 덮인다. 이 함수가 없으면 그 함정을 호출처마다 다시 밟는다.
pub fn isBelowText(l: u32) bool {
    return l == layers.bottom;
}

/// B1 rich Chrome text의 immutable placement artifact. semantic draw의 px origin을 cell
/// DrawList와 함께 보존해, CoreText가 atlas slot을 준비한 뒤에도 final glyph quad가 row/col로
/// 다시 절삭되지 않게 한다. Placement는 row 하나가 아니라 text op의 column span을 들고 있어,
/// 같은 행의 scope tab·side-by-side control이 서로의 fractional origin을 훔치지 않는다.
pub const RichTextArtifact = struct {
    pub const Placement = struct {
        row: u16,
        start_col: u16,
        end_col: u16,
        offset_x_px: f32,
        offset_y_px: f32,
        foreground: u32,
        text_role: chrome.ui.typography.ChromeTextRole,
    };

    placements: []Placement,

    pub fn deinit(self: *RichTextArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.placements);
        self.* = undefined;
    }

    /// Converts an already shaped/rasterized RenderFrame to final pixel glyph placements. The
    /// frame owns atlas slots; this artifact owns only component placement/color, keeping font
    /// work out of the render tick's final assembly phase.
    pub fn appendGpuGlyphs(
        self: RichTextArtifact,
        allocator: std.mem.Allocator,
        frame: renderer.RenderFrame,
        atlas: renderer.GlyphAtlasConfig,
        cell_width_px: u32,
        cell_height_px: u32,
        origin_x_px: u32,
        origin_y_px: u32,
        out: *std.ArrayList(metal_frame.GpuGlyph),
    ) !void {
        if (cell_width_px == 0 or cell_height_px == 0) return;
        const texture = renderer.AtlasTextureSize{ .width_px = atlas.atlas_width_px, .height_px = atlas.atlas_height_px };
        for (frame.glyph_quad_frame.glyphs) |glyph| {
            const placement = placementFor(self.placements, glyph.run.row, glyph.run.col) orelse continue;
            const uv = renderer.glyph_quads.uvRectForSlot(glyph.slot, texture) catch continue;
            try out.append(allocator, .{
                .x = @as(f32, @floatFromInt(origin_x_px)) + @as(f32, @floatFromInt(glyph.run.col)) * @as(f32, @floatFromInt(cell_width_px)) + placement.offset_x_px,
                .y = @as(f32, @floatFromInt(origin_y_px)) + @as(f32, @floatFromInt(glyph.run.row)) * @as(f32, @floatFromInt(cell_height_px)) + placement.offset_y_px,
                .w = @floatFromInt(glyph.slot.width_px),
                .h = @floatFromInt(cell_height_px),
                .atlas_x_px = glyph.slot.x_px,
                .atlas_y_px = glyph.slot.y_px,
                .atlas_width_px = glyph.slot.width_px,
                .atlas_height_px = glyph.slot.height_px,
                // NativeMetalCell reserves u+2 for a CoreText-selected color glyph. The
                // independent pixel pass uses the same fragment shader, so preserve that
                // renderer contract rather than recoloring emoji with the text foreground.
                //
                // **u0과 u1 둘 다** 실어야 한다 — 셰이더가 `uv.x >= 2.0`으로 판정하므로 한쪽만 실으면
                // 정점 보간에서 컬러 분기가 왼쪽 일부에서만 성립해 글리프가 세로 조각으로 잘린다.
                .u0 = colorUv(uv.u0, glyph.run.cache_key.color_glyph_kind),
                .v0 = uv.v0,
                .u1 = colorUv(uv.u1, glyph.run.cache_key.color_glyph_kind),
                .v1 = uv.v1,
                .foreground = placement.foreground,
                .layer = 0,
            });
        }
    }
};

/// Captures the semantic pixel origin for each lowerable text row. The actual glyph shape/raster
/// still comes from the shared CoreText+atlas pipeline; this is deliberately placement-only.
pub fn buildRichTextArtifact(
    allocator: std.mem.Allocator,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
    cols: u16,
    rows: u16,
) !RichTextArtifact {
    if (cell_width_px == 0 or cell_height_px == 0 or cols == 0 or rows == 0) return error.NoSpace;
    var out: std.ArrayList(RichTextArtifact.Placement) = .empty;
    errdefer out.deinit(allocator);
    for (ops) |op| switch (op) {
        .text => |text| {
            if (text.origin.x < 0 or text.origin.y < 0) continue;
            const col_px: u32 = @intCast(text.origin.x);
            const row_px: u32 = @intCast(text.origin.y);
            const row: u16 = @intCast(@min(row_px / cell_height_px, rows));
            if (row >= rows or col_px / cell_width_px >= cols) continue;
            const op_start_col: u16 = @intCast(col_px / cell_width_px);
            // 멀티-run 은 한 줄 안의 스타일 구간이므로 **앞 run 끝에서 이어** 놓는다. 이 격자 경로는
            // 실측 advance 대신 열을 세지만, 같은 열에서 다시 시작하면 구간들이 겹쳐 그려진다.
            var start_col = op_start_col;
            for (text.runs) |run| {
                const end_limit = @min(cols, std.math.add(u16, op_start_col, text.max_cols) catch cols);
                if (start_col >= end_limit) break;
                var plan = chrome.text_layout.plan(run.text, start_col, end_limit, text.anchor, if (text.wide_icons) &wideChromeIconGlyph else null);
                while (plan.next()) |_| {}
                const end_col = plan.endCol();
                if (end_col <= start_col) continue;
                try out.append(allocator, .{
                    .row = row,
                    .start_col = start_col,
                    .end_col = end_col,
                    .offset_x_px = @floatFromInt(col_px % cell_width_px),
                    .offset_y_px = @floatFromInt(row_px % cell_height_px),
                    .foreground = packRgb(tk.get(run.role orelse text.role)),
                    .text_role = text.text_role,
                });
                start_col = end_col;
            }
        },
        else => {},
    };
    return .{ .placements = try out.toOwnedSlice(allocator) };
}

/// The final-pixel consumers must resolve placement through this one lookup.  In particular,
/// Chrome Lab uses it to prove its submitted GpuGlyph coordinates still equal the product
/// artifact rather than a fixture-local cell reconstruction.
pub fn placementFor(placements: []const RichTextArtifact.Placement, row: u16, col: u16) ?RichTextArtifact.Placement {
    // DrawList/shape order matches semantic draw order. Reverse lookup gives a later text op
    // precedence when a component deliberately overlays an earlier run in the same cell.
    var i = placements.len;
    while (i > 0) {
        i -= 1;
        const placement = placements[i];
        if (placement.row == row and col >= placement.start_col and col < placement.end_col) return placement;
    }
    return null;
}

/// Cache key for a placement-only artifact. Font rasterization remains owned by the existing
/// shared CoreText/atlas path; this key invalidates the immutable component placement whenever
/// text, semantic color, rect, icon width policy, or grid metrics change.
/// CoreText 셰이핑 결과(글리프 id·advance·선택된 face)는 **위치의 함수가 아니다**. 그래서 스크롤로 목록이
/// 통째로 위아래로 움직인 프레임은 같은 아티팩트를 다시 쓸 수 있어야 한다. `scroll_origin_y_px`(현재
/// 스크롤 영역의 첫 아이템 origin)를 스크롤 소속 op의 y에서 빼서, **평행이동에 불변인** 키를 만든다.
///
/// 이걸 안 하면 스크롤 1px마다 키가 바뀌고, 캐시 miss 프레임은 텍스트를 아예 그리지 않으므로(host의
/// all-or-cell-fallback) 스크롤 내내 글자가 사라진다 — 사용자가 보고한 플리커의 직접 원인이다.
/// 고정 chrome은 스크롤해도 제자리이므로 절대 y를 그대로 섞는다.
pub fn richTextFingerprint(
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
    cols: u16,
    rows: u16,
    scroll_origin_y_px: i32,
) u64 {
    var state: u64 = 0xcbf29ce484222325;
    fingerprintMixValue(&state, cell_width_px);
    fingerprintMixValue(&state, cell_height_px);
    fingerprintMixValue(&state, cols);
    fingerprintMixValue(&state, rows);
    for (ops) |op| switch (op) {
        .text => |text| {
            // Registered SVG/PUA icons are emitted by buildIconTextDrawList, never by the
            // proportional system-text worker. Their spinner phase may change every frame, so
            // including them here would make every detached text result stale before polling.
            if (!system_text.shapesTextOp(text)) continue;
            const op_max_width = system_text.opMaxWidthPx(text, cell_width_px) orelse continue;
            // request는 셰이핑될 run이 하나도 없으면 이 op으로 아무것도 만들지 않는다. 키가 op 수준
            // 값(origin·role·placement)을 먼저 섞어 버리면 그 op의 유무가 키를 바꾸어 두 필터가 다시
            // 갈라진다. 그래서 run 판정을 먼저 한다.
            var shapes_any_run = false;
            for (text.runs) |run| {
                if (system_text.shapesRun(text, run, op_max_width)) {
                    shapes_any_run = true;
                    break;
                }
            }
            if (!shapes_any_run) continue;
            fingerprintMixValue(&state, 0x54);
            fingerprintMixValue(&state, @as(u32, @bitCast(text.origin.x)));
            fingerprintMixValue(&state, @as(u32, @bitCast(scrollRelativeY(text.origin.y, text.scroll_clipped, scroll_origin_y_px))));
            fingerprintMixValue(&state, packRgb(tk.get(text.role)));
            fingerprintMixValue(&state, @intFromEnum(text.text_role));
            fingerprintMixValue(&state, @intFromBool(text.wide_icons));
            fingerprintMixValue(&state, @intFromBool(text.scroll_clipped));
            // 떠 있는 op은 절대 y와 자기 clip으로 그려진다. 둘 다 키에 있어야 밀려 나가는 동안
            // 셰이핑이 옛 자리에 고정되지 않는다.
            //
            // `above_scroll` 자체는 섞지 않는다 — 이 분기가 이미 그 사실을 키에 남기고, 따로 섞으면
            // 어떤 변이로도 관측되지 않는 항이 된다(변이 검증에서 확인).
            if (text.above_scroll) if (text.clip) |clip| {
                fingerprintMixValue(&state, @as(u32, @bitCast(clip.x)));
                fingerprintMixValue(&state, @as(u32, @bitCast(clip.y)));
                fingerprintMixValue(&state, clip.w);
                fingerprintMixValue(&state, clip.h);
            };
            fingerprintMixValue(&state, text.max_width_px orelse 0);
            fingerprintMixTextPlacement(&state, text.placement, text.scroll_clipped, scroll_origin_y_px);
            for (text.runs) |run| {
                // request와 **같은** 필터를 쓴다. 갈라지면 키는 같은데 artifact에는 그 run이 없는 상태가
                // 만들어지고, 키가 스크롤 평행이동에 불변이라 그 artifact가 그 줄이 보여야 할 위치에서
                // 재사용되어 줄이 영구히 빈 채로 남는다.
                if (!system_text.shapesRun(text, run, op_max_width)) continue;
                fingerprintMixValue(&state, run.text.len);
                fingerprintMixValue(&state, @intFromBool(run.bold));
                // run 별 색은 op 의 role 과 별개로 artifact 픽셀을 바꾼다. 섞지 않으면 색만 바뀐 프레임이
                // 옛 artifact 를 그대로 재사용해 위계가 조용히 사라진다.
                fingerprintMixValue(&state, if (run.role) |role| packRgb(tk.get(role)) else 0);
                for (run.text) |byte| fingerprintMixByte(&state, byte);
            }
        },
        else => fingerprintMixValue(&state, 0),
    };
    return state;
}

/// 스크롤 목록에 속한 op의 y를 스크롤 기준 상대값으로 바꾼다. 목록 전체가 같은 양만큼 움직이므로 이
/// 값은 스크롤에 불변이고, 아이템이 실제로 교체되면 텍스트 바이트가 달라져 키가 정상적으로 바뀐다.
fn scrollRelativeY(y: i32, scroll_clipped: bool, scroll_origin_y_px: i32) i32 {
    if (!scroll_clipped) return y;
    return y -% scroll_origin_y_px;
}

fn fingerprintMixTextPlacement(state: *u64, placement: chrome.draw.TextPlacement, scroll_clipped: bool, scroll_origin_y_px: i32) void {
    switch (placement) {
        .origin => fingerprintMixValue(state, @as(u8, 0)),
        .center_in_rect => |rect| {
            fingerprintMixValue(state, @as(u8, 1));
            fingerprintMixValue(state, @as(u32, @bitCast(rect.x)));
            fingerprintMixValue(state, @as(u32, @bitCast(scrollRelativeY(rect.y, scroll_clipped, scroll_origin_y_px))));
            fingerprintMixValue(state, rect.w);
            fingerprintMixValue(state, rect.h);
        },
        .icon_in_rect => |icon| {
            fingerprintMixValue(state, @as(u8, 2));
            fingerprintMixValue(state, @as(u32, @bitCast(icon.content_rect.x)));
            fingerprintMixValue(state, @as(u32, @bitCast(scrollRelativeY(icon.content_rect.y, scroll_clipped, scroll_origin_y_px))));
            fingerprintMixValue(state, icon.content_rect.w);
            fingerprintMixValue(state, icon.content_rect.h);
            fingerprintMixValue(state, icon.icon_codepoint);
            fingerprintMixValue(state, icon.icon_extent_px);
        },
        .leading_icon_group => |group| {
            fingerprintMixValue(state, @as(u8, 3));
            fingerprintMixValue(state, @as(u32, @bitCast(group.content_rect.x)));
            fingerprintMixValue(state, @as(u32, @bitCast(scrollRelativeY(group.content_rect.y, scroll_clipped, scroll_origin_y_px))));
            fingerprintMixValue(state, group.content_rect.w);
            fingerprintMixValue(state, group.content_rect.h);
            fingerprintMixValue(state, group.icon_codepoint);
            fingerprintMixValue(state, group.icon_extent_px);
            fingerprintMixValue(state, group.gap_px);
        },
    }
}

fn fingerprintMixValue(state: *u64, value: anytype) void {
    const v: u64 = @intCast(value);
    inline for ([_]u6{ 0, 8, 16, 24, 32, 40, 48, 56 }) |shift| {
        fingerprintMixByte(state, @truncate(v >> shift));
    }
}

fn fingerprintMixByte(state: *u64, byte: u8) void {
    state.* = (state.* ^ byte) *% 0x100000001b3;
}

/// A completed Chrome frame's text ops become **one** CoreText DrawList. `view.zig` already owns
/// clipping/ellipsis; this adapter only places its clusters at the same component-grid origin.
/// Batching prevents a card with three labels from causing three independent CoreText shaping
/// passes on every render tick.
pub fn buildTextDrawList(
    allocator: std.mem.Allocator,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
    cols: u16,
    rows: u16,
) !renderer.DrawList {
    return buildTextDrawListFiltered(allocator, ops, tk, cell_width_px, cell_height_px, cols, rows, null);
}

/// Measured system text owns ordinary labels; this companion list retains only registered
/// Chrome SVG glyphs for the existing synthesized icon path.  Keeping the filter here makes
/// the two paint paths share the same semantic op and avoids duplicate monospaced text.
pub fn buildIconTextDrawList(
    allocator: std.mem.Allocator,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
    cols: u16,
    rows: u16,
) !renderer.DrawList {
    return buildTextDrawListFiltered(allocator, ops, tk, cell_width_px, cell_height_px, cols, rows, true);
}

fn buildTextDrawListFiltered(
    allocator: std.mem.Allocator,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    cell_height_px: u32,
    cols: u16,
    rows: u16,
    only_wide_icons: ?bool,
) !renderer.DrawList {
    var cells: std.ArrayList(renderer.DrawCell) = .empty;
    errdefer cells.deinit(allocator);
    var pool: std.ArrayList(u32) = .empty;
    errdefer pool.deinit(allocator);

    if (cell_width_px == 0 or cell_height_px == 0 or cols == 0 or rows == 0) return error.NoSpace;
    for (ops) |op| switch (op) {
        .text => |text| {
            if (only_wide_icons) |expected| if (text.wide_icons != expected) continue;
            if (text.origin.x < 0 or text.origin.y < 0) continue;
            const col: u16 = @intCast(@min(@as(u32, @intCast(text.origin.x)) / cell_width_px, cols));
            const row: u16 = @intCast(@min(@as(u32, @intCast(text.origin.y)) / cell_height_px, rows));
            if (col >= cols or row >= rows) continue;
            // 여기도 멀티-run 은 이어 놓는다(위 placement 경로와 같은 규칙) — 그리고 run 이 자기 role 을
            // 들면 그 구간만 다른 색이다. 두 경로가 갈리면 같은 draw 가 셀/측정에서 다르게 보인다.
            var run_col = col;
            for (text.runs) |run| {
                const end_limit = @min(cols, std.math.add(u16, col, text.max_cols) catch cols);
                if (run_col >= end_limit) break;
                const style: terminal.Style = .{ .foreground = .{ .rgb = tk.get(run.role orelse text.role) } };
                var plan = chrome.text_layout.plan(run.text, run_col, end_limit, text.anchor, if (text.wide_icons) &wideChromeIconGlyph else null);
                while (plan.next()) |item| switch (item) {
                    .ellipsis => |ellipsis_col| try cells.append(allocator, .{ .row = row, .col = ellipsis_col, .codepoint = chrome.text_layout.ellipsis_glyph, .width = 1, .style = style }),
                    .cluster => |cluster| try appendCluster(allocator, &cells, &pool, run.text, cluster, row, style),
                };
                run_col = plan.endCol();
            }
        },
        else => {},
    };
    const owned_pool = try pool.toOwnedSlice(allocator);
    errdefer allocator.free(owned_pool);
    return .{
        .size = .{ .cols = cols, .rows = rows },
        .cursor = .{ .row = 0, .col = 0, .visible = false },
        .dirty = .{ .start_row = 0, .end_row = rows - 1 },
        .cells = try cells.toOwnedSlice(allocator),
        .grapheme_pool = owned_pool,
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// The semantic draw explicitly opts in only component-owned SVG glyphs. Keeping this predicate
/// in the platform lowerer preserves the Chrome→renderer boundary while making measurement and
/// DrawCell width agree with the component's text plan.
fn wideChromeIconGlyph(codepoint: u21) bool {
    return renderer.icon_glyph.isRegisteredIcon(codepoint);
}

/// Chrome card는 terminal glyph보다 먼저 그리는 layer 2에 둔다. layer 0은 renderer의 draw
/// order상 terminal text 뒤라 써서는 안 된다. 이 규칙을 adapter에 고정해 카드 배경이 CoreText
/// 글자를 덮는 회귀를 막는다.
pub fn appendBackgroundQuads(
    allocator: std.mem.Allocator,
    draws: []const chrome.ChromeDraw,
    tk: *const chrome.Tokens,
    origin_x_px: u32,
    origin_y_px: u32,
    out: *std.ArrayList(metal_frame.GpuQuad),
    layer: u32,
) void {
    appendBackgroundQuadsWithTerminalOpacity(allocator, draws, tk, origin_x_px, origin_y_px, out, layer, 255);
}

/// 위와 같되 **`terminal_bg` 역할 quad의 알파에만** 창 투명도를 곱한다.
///
/// **왜 그 역할만인가.** 렌더러 규약이 그렇다 — `window.opacity`는 터미널 레이어 **clear color의
/// alpha에만** 곱하고(`maru_metal_renderer.m`), 배경색이 명시된 셀은 건드리지 않는다. 그러니
/// "터미널의 바탕"을 칠하는 quad는 같은 규칙을 따라야 하고, 도크·사이드바 표면(`surface_bg`)이나
/// 스크롤바는 따르면 안 된다(반투명해지면 안 보인다).
///
/// **완전히 같아지지는 않는다.** 이 quad는 이미 opacity가 걸린 clear 위에 premultiplied-over로
/// 겹치므로 유효 알파가 `op·(2−op)`가 되어 터미널(단일 op 레이어)보다 조금 더 불투명하다. 활성 탭
/// cutout이 같은 한계를 갖고 있고(`app_session.zig`의 그 주석), 픽셀-정확은 아래 레이어를 도려내야
/// 하는 systemic 변경이라 함께 보류한다. 불투명 solid보다 이쪽이 터미널에 훨씬 가깝다.
pub fn appendBackgroundQuadsWithTerminalOpacity(
    allocator: std.mem.Allocator,
    draws: []const chrome.ChromeDraw,
    tk: *const chrome.Tokens,
    origin_x_px: u32,
    origin_y_px: u32,
    out: *std.ArrayList(metal_frame.GpuQuad),
    /// 이 draws가 놓일 합성 층(SV6a). 기본 2(bottom — 셀·텍스트 **아래**)는 도크·탐색기 배경처럼
    /// 텍스트 밑에 깔리는 것들의 자리다.
    ///
    /// **호출처가 정해야 하는 이유**: 같은 함수를 타면서도 원하는 층이 갈린다. 사이드바·오버레이
    /// 스크롤바는 각각 렌더러 소유 배경 strip과 모달 배경 quad **위**에 와야 해서 over(3)가 필요하고,
    /// 그것을 여기서 2로 고정하는 바람에 소비처가 뒤에서 `q.layer = 3`으로 되돌리고 있었다 — 같은
    /// 역할이 두 층에 흩어진 원인이다(docs/scroll-area.md "판단(2026-08-09)").
    layer: u32,
    /// `terminal_bg` quad에 곱할 알파(255 = 그대로). 호출자가 `windowOpacityByte`를 넘긴다.
    terminal_bg_alpha: u8,
) void {
    for (draws) |draws_for_layer| for (draws_for_layer.ops) |op| switch (op) {
        .quad => |quad| {
            // 면적 0 clip은 "한 픽셀도 안 보인다"는 뜻인데, shader 규약은 `clip.z == 0`을 **"클립 없음"**으로
            // 읽는다(maru_metal_shader.h). 그대로 내리면 정반대로 자르지 않은 quad가 되므로 여기서 버린다.
            // 상류 `ui.paint`도 같은 판정을 하지만, component가 직접 낸 장식 quad는 그 경로를 지나지 않는다 —
            // 규약을 아는 유일한 자리인 이 lowerer가 마지막 관문이다.
            if (quad.clip) |clip| if (clip.w == 0 or clip.h == 0) continue;
            // `ChromeDraw.Quad.alpha` is semantic paint data, not a Lab-only decoration.
            // Preserve it in the renderer's ARGB colors so loading skeletons and later hover
            // transitions keep the same token-relative contrast on the actual Metal host.
            // 터미널 바탕을 칠하는 quad만 창 투명도를 함께 건다(위 doc — 렌더러 규약과 같은 축).
            const fill_alpha: u8 = if (quad.fill_role == .terminal_bg)
                @intCast((@as(u16, quad.alpha) * @as(u16, terminal_bg_alpha)) / 255)
            else
                quad.alpha;
            const fill = packRgba(tk.get(quad.fill_role), fill_alpha);
            // **색 없는 테두리는 폭도 0이다.** 여기서 null 역할을 RGBA 0으로 packing하는데 폭을 그대로
            // 넘기면, 셰이더가 그 띠를 투명하게 칠해 **그 자리가 뚫려 뒤가 비친다**. 버튼 배경이 아래
            // 표면과 같은 색이면 안 보이다가, 그 위에 호버 밴드처럼 다른 색이 깔리는 순간 어두운 링으로
            // 드러난다(소스 컨트롤 도크 호버 캡처로 실측 — 컴포넌트는 `ghost`가 "테두리 없음"이라고
            // 선언했는데 화면에는 링이 있었다).
            //
            // 컴포넌트마다 폭을 0으로 맞추게 하면 한 곳만 빠뜨려도 같은 링이 돌아온다. **모순된 조합을
            // 여기서 한 번 정규화한다** — 색이 없으면 그릴 테두리가 없다는 뜻이고, 그 해석은 하나뿐이다.
            const border = if (quad.border_role) |role| packRgba(tk.get(role), quad.alpha) else 0;
            const border_widths: [4]u16 = if (quad.border_role == null) .{ 0, 0, 0, 0 } else quad.border_widths;
            out.append(allocator, .{
                // Component draw coordinates are local to the dock content. Text receives the
                // same offset through its PaneFrame destination; quads need it explicitly
                // because GpuQuad is already in renderer backing coordinates.
                .x = @as(f32, @floatFromInt(quad.rect.x)) + @as(f32, @floatFromInt(origin_x_px)),
                .y = @as(f32, @floatFromInt(quad.rect.y)) + @as(f32, @floatFromInt(origin_y_px)),
                .w = @floatFromInt(quad.rect.w),
                .h = @floatFromInt(quad.rect.h),
                .corner_radii = .{
                    @floatFromInt(quad.corner_radii[0]),
                    @floatFromInt(quad.corner_radii[1]),
                    @floatFromInt(quad.corner_radii[2]),
                    @floatFromInt(quad.corner_radii[3]),
                },
                .border_widths = .{
                    @floatFromInt(border_widths[0]),
                    @floatFromInt(border_widths[1]),
                    @floatFromInt(border_widths[2]),
                    @floatFromInt(border_widths[3]),
                },
                .fill_color0 = fill,
                .fill_color1 = fill,
                .border_color = border,
                .gradient_kind = 0,
                .layer = layer,
                // 클리핑은 shader가 한다 — rect를 미리 자르면 잘린 변에 없어야 할 corner radius와 border
                // stroke가 생긴다. 여기서는 component가 실어 보낸 뷰포트를 backing 좌표로 옮기기만 한다.
                .clip_x = if (quad.clip) |c| @as(f32, @floatFromInt(c.x)) + @as(f32, @floatFromInt(origin_x_px)) else 0,
                .clip_y = if (quad.clip) |c| @as(f32, @floatFromInt(c.y)) + @as(f32, @floatFromInt(origin_y_px)) else 0,
                .clip_w = if (quad.clip) |c| @floatFromInt(c.w) else 0,
                .clip_h = if (quad.clip) |c| @floatFromInt(c.h) else 0,
            }) catch {};
        },
        else => {},
    };
}

fn appendCluster(
    allocator: std.mem.Allocator,
    cells: *std.ArrayList(renderer.DrawCell),
    pool: *std.ArrayList(u32),
    source: []const u8,
    cluster: chrome.text_layout.Cluster,
    row: u16,
    style: terminal.Style,
) !void {
    const base = chrome.text_layout.decodeCodepoint(source, cluster.start);
    const offset: u32 = @intCast(pool.items.len);
    var index = cluster.start + base.advance;
    const max_extra = @as(usize, std.math.maxInt(u16));
    while (index < cluster.end and index < source.len and pool.items.len - offset < max_extra) {
        const extra = chrome.text_layout.decodeCodepoint(source, index);
        try pool.append(allocator, @as(u32, extra.cp));
        index += extra.advance;
    }
    try cells.append(allocator, .{
        .row = row,
        .col = cluster.col,
        .codepoint = base.cp,
        .grapheme_offset = offset,
        .grapheme_count = @intCast(pool.items.len - offset),
        .width = @intCast(@min(cluster.cols, 2)),
        .style = style,
    });
}

fn packRgba(rgb: maru.color.Rgb, alpha: u8) u32 {
    return (@as(u32, alpha) << 24) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

fn packRgb(rgb: maru.color.Rgb) u32 {
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

// 이 테스트가 증명하는 것: **"텍스트 아래"인 층은 `bottom` 하나뿐**이라는 것.
//
// 왜 터미널/편집기에서 중요한가 — 컴포넌트 배경은 자기 글자를 덮으면 안 되는데, 렌더러는 이름 없는
// 값을 전부 over로 몰아넣어 잘못된 층도 조용히 "동작"한다. 실제로 편집기 배경이 `3`으로 실려 본문이
// 통째로 안 보였다. 특히 `under`(0)는 이름 때문에 안전해 보이지만 렌더러가 part1 셀 **뒤**에 그리므로
// 같은 사고가 난다 — 그 함정을 여기 고정해 두지 않으면 다음 호출처가 다시 밟는다.
test "텍스트 아래 층은 bottom 하나뿐이다 — under는 이름과 달리 셀 뒤에 그려진다" {
    try std.testing.expect(isBelowText(layers.bottom));
    try std.testing.expect(!isBelowText(layers.under)); // 함정: 이름이 "아래"지만 part1 셀 뒤다
    try std.testing.expect(!isBelowText(layers.over));
    try std.testing.expect(!isBelowText(layers.header));
    // 이름 없는 값(예전 편집기 배경이 실렸던 `3`)도 아래가 아니다 — 렌더러는 이것을 over로 몰아넣는다.
    try std.testing.expect(!isBelowText(3));
}

test "Chrome draw lowering preserves an NFD cluster and paints cards behind text" {
    const tk = chrome.tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .terminal_background = .{ .r = 22, .g = 23, .b = 24 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const ops_text = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 2, .y = 3 }, .runs = &.{.{ .text = "e\u{301}" }}, .role = .surface_fg } }};
    var text = try buildTextDrawList(std.testing.allocator, &ops_text, &tk, 1, 1, 20, 10);
    defer text.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), text.cells.len);
    try std.testing.expectEqual(@as(usize, 1), text.grapheme_pool.len);
    try std.testing.expectEqual(@as(u16, 2), text.cells[0].col);
    try std.testing.expectEqual(@as(u16, 3), text.cells[0].row);
    var quads: std.ArrayList(metal_frame.GpuQuad) = .empty;
    defer quads.deinit(std.testing.allocator);
    const ops = [_]chrome.draw.Op{.{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 }, .fill_role = .surface_bg, .alpha = 0x7f } }};
    appendBackgroundQuads(std.testing.allocator, &.{.{ .layer = .sidebar, .ops = &ops }}, &tk, 11, 13, &quads, 2);
    try std.testing.expectEqual(@as(usize, 1), quads.items.len);
    try std.testing.expectEqual(@as(u32, 2), quads.items[0].layer);
    try std.testing.expectEqual(@as(f32, 11), quads.items[0].x);
    try std.testing.expectEqual(@as(f32, 13), quads.items[0].y);
    try std.testing.expectEqual(@as(u32, 0x7f040506), quads.items[0].fill_color0);
}

test "Chrome draw lowering widens only explicitly owned registered SVG icons" {
    const tk = chrome.tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .terminal_background = .{ .r = 22, .g = 23, .b = 24 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const runs = [_]chrome.draw.Run{.{ .text = icons.utf8(.recent) }};
    const wide_ops = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg, .wide_icons = true } }};
    var wide = try buildTextDrawList(std.testing.allocator, &wide_ops, &tk, 8, 16, 4, 1);
    defer wide.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), wide.cells.len);
    try std.testing.expectEqual(@as(u2, 2), wide.cells[0].width);

    const plain_ops = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg } }};
    var plain = try buildTextDrawList(std.testing.allocator, &plain_ops, &tk, 8, 16, 4, 1);
    defer plain.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), plain.cells.len);
    try std.testing.expectEqual(@as(u2, 1), plain.cells[0].width);
}

test "icon-only lowering excludes ordinary Session Dock text" {
    const tk = chrome.tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .terminal_background = .{ .r = 22, .g = 23, .b = 24 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &.{.{ .text = "ordinary" }}, .role = .surface_fg } },
        .{ .text = .{ .origin = .{ .x = 8, .y = 0 }, .runs = &.{.{ .text = icons.utf8(.recent) }}, .role = .surface_fg, .wide_icons = true } },
    };
    var list = try buildIconTextDrawList(std.testing.allocator, &ops, &tk, 8, 16, 20, 1);
    defer list.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), list.cells.len);
    try std.testing.expectEqual(icons.codepoint(.recent), list.cells[0].codepoint);
}

test "rich text artifact preserves fractional pixel origin instead of coercing it to a cell row" {
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .terminal_background = .{ .r = 22, .g = 23, .b = 24 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const runs = [_]chrome.draw.Run{.{ .text = "가" }};
    const ops = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 19, .y = 33 }, .runs = &runs, .role = .accent_bar } }};
    var artifact = try buildRichTextArtifact(std.testing.allocator, &ops, &tk, 8, 16, 20, 10);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), artifact.placements.len);
    try std.testing.expectEqual(@as(u16, 2), artifact.placements[0].row);
    try std.testing.expectEqual(@as(u16, 2), artifact.placements[0].start_col);
    try std.testing.expectEqual(@as(u16, 4), artifact.placements[0].end_col);
    try std.testing.expectEqual(@as(f32, 3), artifact.placements[0].offset_x_px);
    try std.testing.expectEqual(@as(f32, 1), artifact.placements[0].offset_y_px);
    try std.testing.expectEqual(@as(u32, 0x00191A1B), artifact.placements[0].foreground);
}

test "rich text artifact keeps side-by-side origins independent on one cell row" {
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .terminal_background = .{ .r = 22, .g = 23, .b = 24 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const left_runs = [_]chrome.draw.Run{.{ .text = "A" }};
    const right_runs = [_]chrome.draw.Run{.{ .text = "B" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 1, .y = 17 }, .runs = &left_runs, .role = .surface_fg } },
        .{ .text = .{ .origin = .{ .x = 18, .y = 19 }, .runs = &right_runs, .role = .accent_bar } },
    };
    var artifact = try buildRichTextArtifact(std.testing.allocator, &ops, &tk, 8, 16, 20, 10);
    defer artifact.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), artifact.placements.len);
    try std.testing.expectEqual(@as(f32, 1), placementFor(artifact.placements, 1, 0).?.offset_x_px);
    try std.testing.expectEqual(@as(f32, 2), placementFor(artifact.placements, 1, 2).?.offset_x_px);
    try std.testing.expectEqual(@as(f32, 3), placementFor(artifact.placements, 1, 2).?.offset_y_px);
}

test "rich text fingerprint changes for placement semantic color and typography inputs" {
    var tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .terminal_background = .{ .r = 22, .g = 23, .b = 24 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const runs = [_]chrome.draw.Run{.{ .text = "가A" }};
    var ops = [_]chrome.draw.Op{.{ .text = .{ .origin = .{ .x = 5, .y = 7 }, .runs = &runs, .role = .accent_bar } }};
    const base = richTextFingerprint(&ops, &tk, 8, 16, 20, 10, 0);
    try std.testing.expect(base != richTextFingerprint(&ops, &tk, 9, 16, 20, 10, 0));
    tk.palette.set(.accent_bar, .{ .r = 99, .g = 26, .b = 27 });
    try std.testing.expect(base != richTextFingerprint(&ops, &tk, 8, 16, 20, 10, 0));
    tk.palette.set(.accent_bar, .{ .r = 25, .g = 26, .b = 27 });
    ops[0].text.text_role = .card_heading;
    try std.testing.expect(base != richTextFingerprint(&ops, &tk, 8, 16, 20, 10, 0));
}

// 사용자 보고 회귀: 목록을 스크롤하거나 새로 고치면 도크 글자가 사라졌다 나타났다 했다. 원인은 이 키가
// 텍스트의 **절대 픽셀 y**를 물고 있었던 것이다. 스크롤은 1px 단위라 매 프레임 키가 바뀌고, 캐시가
// 빗나간 프레임에는 host가 measured 텍스트를 통째로 안 그린다(all-or-cell-fallback). 스크롤이 이어지는
// 동안 늦게 도착한 worker 결과도 계속 stale이라, 멈출 때까지 글자가 돌아오지 않는다.
//
// CoreText 셰이핑 결과는 위치의 함수가 아니므로, 스크롤로 목록이 통째로 움직인 프레임은 **같은 키**여야
// 한다. 고정 chrome은 스크롤해도 제자리이므로 절대 y를 유지해야 하고, 아이템이 실제로 교체되면 텍스트가
// 달라져 키가 정상적으로 바뀌어야 한다.
test "rich text fingerprint is invariant to pure scroll translation" {
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    const header_runs = [_]chrome.draw.Run{.{ .text = "Agent 세션 기록" }};
    const card_runs = [_]chrome.draw.Run{.{ .text = "카드 제목" }};
    const other_runs = [_]chrome.draw.Run{.{ .text = "다른 카드" }};
    // 고정 chrome 하나 + 스크롤 목록 하나. 스크롤은 목록 op의 y와 scroll origin을 같은 양만큼 옮긴다.
    const rested = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 20, .y = 30 }, .runs = &header_runs, .role = .surface_fg, .text_role = .dock_heading } },
        .{ .text = .{ .origin = .{ .x = 20, .y = 300 }, .runs = &card_runs, .role = .surface_fg, .text_role = .card_heading, .scroll_clipped = true } },
    };
    const scrolled = [_]chrome.draw.Op{
        rested[0],
        .{ .text = .{ .origin = .{ .x = 20, .y = 259 }, .runs = &card_runs, .role = .surface_fg, .text_role = .card_heading, .scroll_clipped = true } },
    };
    const base = richTextFingerprint(&rested, &tk, 8, 16, 20, 10, 0);
    try std.testing.expectEqual(base, richTextFingerprint(&scrolled, &tk, 8, 16, 20, 10, -41));

    // 고정 chrome이 움직였다면 그건 스크롤이 아니라 레이아웃 변화다 — 키가 바뀌어야 한다.
    const moved_chrome = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 20, .y = 31 }, .runs = &header_runs, .role = .surface_fg, .text_role = .dock_heading } },
        scrolled[1],
    };
    try std.testing.expect(base != richTextFingerprint(&moved_chrome, &tk, 8, 16, 20, 10, -41));

    // 가상화로 카드가 교체되면 텍스트가 달라지므로 키도 달라져야 한다(캐시 재사용 금지).
    const replaced = [_]chrome.draw.Op{
        rested[0],
        .{ .text = .{ .origin = .{ .x = 20, .y = 259 }, .runs = &other_runs, .role = .surface_fg, .text_role = .card_heading, .scroll_clipped = true } },
    };
    try std.testing.expect(base != richTextFingerprint(&replaced, &tk, 8, 16, 20, 10, -41));

    // 같은 y라도 스크롤 소속이 다르면 다른 op이다(평행이동 대상이 달라진다).
    const not_scrolled = [_]chrome.draw.Op{
        rested[0],
        .{ .text = .{ .origin = .{ .x = 20, .y = 300 }, .runs = &card_runs, .role = .surface_fg, .text_role = .card_heading } },
    };
    try std.testing.expect(base != richTextFingerprint(&not_scrolled, &tk, 8, 16, 20, 10, 0));
}

// 적대적 검증에서 나온 구조적 취약점: 셰이핑 키와 request가 **각자의 필터**를 갖고 있었다. 음수 origin
// 드롭이 그 갈라짐의 한 사례였고(키는 그 run을 세는데 request는 버려서, 스크롤 불변 키가 그 artifact를
// 그 줄이 보여야 할 위치에 재사용 → 영구 빈 줄), 같은 형태가 `max_width == 0`과 빈 run에도 남아 있었다.
// 이제 둘 다 `system_text`의 판정을 쓰므로, 셰이핑되지 않는 op은 키에도 흔적을 남기지 않아야 한다.
// 고정 헤더는 스크롤 평행이동의 **예외**다. 목록은 offset이 변해도 셰이핑을 재사용해야 하지만,
// 헤더는 밀려 나가는 동안 자기 y와 clip이 실제로 달라진다. 이 사실이 키에 없으면 옛 자리에 고정된
// 채로 재사용되고, Lab 골든은 이것을 못 본다(그 경로는 delta가 늘 0이라 캐시 재사용이 없다).
test "rich text fingerprint pins a floating sticky head instead of translating it" {
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    const head_runs = [_]chrome.draw.Run{.{ .text = "sample-workspace" }};
    const card_runs = [_]chrome.draw.Run{.{ .text = "카드 제목" }};
    const head = chrome.draw.Op{ .text = .{
        .origin = .{ .x = 20, .y = 200 },
        .runs = &head_runs,
        .role = .surface_fg,
        .text_role = .group_heading,
        .above_scroll = true,
        .clip = .{ .x = 0, .y = 200, .w = 400, .h = 40 },
    } };
    const rested = [_]chrome.draw.Op{
        head,
        .{ .text = .{ .origin = .{ .x = 20, .y = 300 }, .runs = &card_runs, .role = .surface_fg, .text_role = .card_heading, .scroll_clipped = true } },
    };
    // 목록만 41px 올라간 프레임. 헤더는 상단에 고정돼 그대로다.
    const scrolled = [_]chrome.draw.Op{
        head,
        .{ .text = .{ .origin = .{ .x = 20, .y = 259 }, .runs = &card_runs, .role = .surface_fg, .text_role = .card_heading, .scroll_clipped = true } },
    };
    const base = richTextFingerprint(&rested, &tk, 8, 16, 20, 10, 0);
    try std.testing.expectEqual(base, richTextFingerprint(&scrolled, &tk, 8, 16, 20, 10, -41));

    // 헤더가 밀려 나가기 시작하면 y가 실제로 바뀐다 — 목록이 같은 양만큼 움직였어도 키가 달라야 한다.
    // `scrollRelativeY`가 이 op에도 적용되면 이 두 키가 같아져 헤더가 옛 자리에 얼어붙는다.
    var pushed_head = head;
    pushed_head.text.origin.y = 200 - 41;
    const pushed = [_]chrome.draw.Op{ pushed_head, scrolled[1] };
    try std.testing.expect(base != richTextFingerprint(&pushed, &tk, 8, 16, 20, 10, -41));

    // clip만 줄어드는 구간(밀려 나가며 위가 잘린다)도 다시 셰이핑해야 한다.
    var clipped_head = head;
    clipped_head.text.clip = .{ .x = 0, .y = 200, .w = 400, .h = 20 };
    const clipped = [_]chrome.draw.Op{ clipped_head, scrolled[1] };
    try std.testing.expect(base != richTextFingerprint(&clipped, &tk, 8, 16, 20, 10, -41));
}

test "rich text fingerprint and the shaping request share one filter" {
    const allocator = std.testing.allocator;
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    const real_runs = [_]chrome.draw.Run{.{ .text = "카드 제목" }};
    const empty_runs = [_]chrome.draw.Run{.{ .text = "" }};
    const baseline = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 20, .y = 300 }, .runs = &real_runs, .role = .surface_fg, .text_role = .card_heading, .max_cols = 20, .scroll_clipped = true } },
    };
    // 셰이핑 대상이 아닌 op 둘을 덧붙인다: 폭 예산 0, 그리고 icon placement가 아닌 빈 run.
    const with_inert = [_]chrome.draw.Op{
        baseline[0],
        .{ .text = .{ .origin = .{ .x = 20, .y = 340 }, .runs = &real_runs, .role = .surface_fg, .text_role = .body, .max_cols = 0, .max_width_px = 0, .scroll_clipped = true } },
        .{ .text = .{ .origin = .{ .x = 20, .y = 360 }, .runs = &empty_runs, .role = .surface_fg, .text_role = .body, .max_cols = 20, .scroll_clipped = true } },
    };
    // 키가 같아야 한다 — 그 op들은 artifact에 아무것도 만들지 않기 때문이다.
    try std.testing.expectEqual(
        richTextFingerprint(&baseline, &tk, 8, 16, 20, 10, 0),
        richTextFingerprint(&with_inert, &tk, 8, 16, 20, 10, 0),
    );
    // 그리고 request도 같은 개수를 만들어야 한다(= 같은 필터).
    var base_request = try system_text.prepareRequest(allocator, 1, &baseline, &tk, 8, .{});
    defer base_request.deinit(allocator);
    var inert_request = try system_text.prepareRequest(allocator, 1, &with_inert, &tk, 8, .{});
    defer inert_request.deinit(allocator);
    try std.testing.expectEqual(base_request.runs.len, inert_request.runs.len);
    try std.testing.expectEqual(@as(usize, 1), inert_request.runs.len);
}

test "rich text fingerprint ignores animated wide icon-only ops" {
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .terminal_background = .{ .r = 22, .g = 23, .b = 24 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    const text_runs = [_]chrome.draw.Run{.{ .text = "Stable label" }};
    const spinner_a = [_]chrome.draw.Run{.{ .text = icons.utf8(.gear) }};
    const spinner_b = [_]chrome.draw.Run{.{ .text = icons.utf8(.plus) }};
    const baseline = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 5, .y = 7 }, .runs = &text_runs, .role = .accent_bar } },
        .{ .text = .{ .origin = .{ .x = 30, .y = 7 }, .runs = &spinner_a, .role = .accent_bar, .wide_icons = true } },
    };
    const next = [_]chrome.draw.Op{
        baseline[0],
        .{ .text = .{ .origin = .{ .x = 30, .y = 7 }, .runs = &spinner_b, .role = .accent_bar, .wide_icons = true } },
    };
    try std.testing.expectEqual(richTextFingerprint(&baseline, &tk, 8, 16, 20, 10, 0), richTextFingerprint(&next, &tk, 8, 16, 20, 10, 0));
}

// SV6a — 층은 **호출처가 정한다.** 예전에는 이 함수가 layer 2를 고정 출력해, over가 필요한 소비처
// (사이드바·오버레이 스크롤바)가 뒤에서 `q.layer = 3`으로 되돌렸다. 그 되돌리기가 "같은 역할이 두 층에
// 흩어진" 증상이었고, 되돌리기를 빠뜨리면 막대가 화면에서 통째로 사라졌다(SV4a·SV5b에서 실제로 그랬다).
test "appendBackgroundQuads puts every quad on the caller's layer" {
    const Rgb = maru.color.Rgb;
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 4 }, .fill_role = .surface_bg, .corner_radii = .{ 0, 0, 0, 0 }, .border_widths = .{ 0, 0, 0, 0 } } },
        .{ .quad = .{ .rect = .{ .x = 0, .y = 4, .w = 10, .h = 4 }, .fill_role = .muted_fg, .corner_radii = .{ 2, 2, 2, 2 }, .border_widths = .{ 0, 0, 0, 0 } } },
    };

    // 기본 층(2 = bottom, 셀·텍스트 아래) — 도크·탐색기 배경이 쓰는 자리다.
    var bottom: std.ArrayList(metal_frame.GpuQuad) = .empty;
    defer bottom.deinit(std.testing.allocator);
    appendBackgroundQuads(std.testing.allocator, &.{.{ .layer = .sidebar, .ops = &ops }}, &tk, 0, 0, &bottom, 2);
    try std.testing.expect(bottom.items.len >= 2);
    for (bottom.items) |q| try std.testing.expectEqual(@as(u32, 2), q.layer);

    // over(3) — 렌더러 소유 표면·모달 배경 **위**에 와야 하는 스크롤바가 쓰는 자리다. 같은 ops를
    // 넣어도 층만 갈린다(호출처가 정한다는 것이 이 슬라이스의 계약이다).
    var over: std.ArrayList(metal_frame.GpuQuad) = .empty;
    defer over.deinit(std.testing.allocator);
    appendBackgroundQuads(std.testing.allocator, &.{.{ .layer = .sidebar, .ops = &ops }}, &tk, 0, 0, &over, 3);
    try std.testing.expectEqual(bottom.items.len, over.items.len);
    for (over.items) |q| try std.testing.expectEqual(@as(u32, 3), q.layer);

    // 층 말고는 아무것도 안 달라진다 — 되돌리기를 없애면서 기하·색이 바뀌면 안 된다.
    for (bottom.items, over.items) |b, o| {
        try std.testing.expectEqual(b.x, o.x);
        try std.testing.expectEqual(b.y, o.y);
        try std.testing.expectEqual(b.w, o.w);
        try std.testing.expectEqual(b.h, o.h);
        try std.testing.expectEqual(b.fill_color0, o.fill_color0);
    }
}

test "appendBackgroundQuads drops an empty clip instead of inverting it into no clip" {
    // 회귀(사용자 보고): 스크롤로 뷰포트를 완전히 벗어난 카드 배경이 고정 header/scope 위에 그려졌다.
    // shader 규약은 `clip.z == 0`을 **클립 없음**으로 읽으므로(maru_metal_shader.h), 면적 0 clip을 그대로
    // 내리면 "아무것도 안 보인다"가 "전부 보인다"로 뒤집힌다.
    const Rgb = maru.color.Rgb;
    const tk = chrome.Tokens{ .palette = std.EnumArray(chrome.tokens.ColorRole, Rgb).initFill(.{ .r = 0, .g = 0, .b = 0 }) };
    const ops = [_]chrome.draw.Op{
        .{ .quad = .{ .rect = .{ .x = 0, .y = -400, .w = 10, .h = 4 }, .fill_role = .surface_bg, .clip = .{ .x = 0, .y = 0, .w = 10, .h = 0 } } },
        .{ .quad = .{ .rect = .{ .x = 0, .y = -400, .w = 10, .h = 4 }, .fill_role = .surface_bg, .clip = .{ .x = 0, .y = 0, .w = 0, .h = 4 } } },
        // clip이 아예 없는 quad는 "안 자른다"는 뜻이므로 그대로 남는다 — 고정 chrome이 이 경우다.
        .{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 4 }, .fill_role = .surface_bg } },
        // 면적이 남아 있는 clip도 물론 남는다.
        .{ .quad = .{ .rect = .{ .x = 0, .y = 0, .w = 10, .h = 4 }, .fill_role = .surface_bg, .clip = .{ .x = 0, .y = 0, .w = 10, .h = 2 } } },
    };

    var quads: std.ArrayList(metal_frame.GpuQuad) = .empty;
    defer quads.deinit(std.testing.allocator);
    appendBackgroundQuads(std.testing.allocator, &.{.{ .layer = .sidebar, .ops = &ops }}, &tk, 0, 0, &quads, 2);
    try std.testing.expectEqual(@as(usize, 2), quads.items.len);
    for (quads.items) |q| try std.testing.expectEqual(@as(f32, 0), q.y);
}

test "색 없는 테두리는 폭이 0으로 정규화된다(투명한 띠가 배경을 뚫지 않는다)" {
    // `border_role = null` + `border_widths > 0`은 **모순된 조합**이다. 그대로 내려보내면 셰이더가 그 띠를
    // RGBA 0으로 칠해 그 자리가 뚫리고, 아래 표면이 비친다 — 컴포넌트는 "테두리 없음"을 선언했는데
    // 화면에는 링이 생긴다(소스 컨트롤 도크 호버에서 실측). 여기서 한 번 정규화해 그 종류를 없앤다.
    const allocator = std.testing.allocator;
    const tk = chrome.tokens.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 1, .g = 2, .b = 3 },
        .sidebar_background = .{ .r = 4, .g = 5, .b = 6 },
        .sidebar_foreground = .{ .r = 7, .g = 8, .b = 9 },
        .sidebar_active = .{ .r = 10, .g = 11, .b = 12 },
        .search_match = .{ .r = 13, .g = 14, .b = 15 },
        .search_match_current = .{ .r = 16, .g = 17, .b = 18 },
        .selection = .{ .r = 19, .g = 20, .b = 21 },
        .cursor = .{ .r = 22, .g = 23, .b = 24 },
        .terminal_background = .{ .r = 22, .g = 23, .b = 24 },
        .accent = .{ .r = 25, .g = 26, .b = 27 },
    });
    var quads: std.ArrayList(metal_frame.GpuQuad) = .empty;
    defer quads.deinit(allocator);

    const draws = chrome.draw.ChromeDraw{
        .layer = .sidebar,
        .ops = &.{
            .{
                .quad = .{
                    .rect = .{ .x = 0, .y = 0, .w = 20, .h = 20 },
                    .fill_role = .surface_bg,
                    // 색은 없는데 폭은 있다 — `ghost` 버튼이 실제로 이 조합을 냈다.
                    .border_role = null,
                    .border_widths = .{ 1, 1, 1, 1 },
                },
            },
        },
    };
    appendBackgroundQuads(allocator, &.{draws}, &tk, 0, 0, &quads, 0);
    try std.testing.expectEqual(@as(usize, 1), quads.items.len);
    try std.testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &quads.items[0].border_widths);
}
