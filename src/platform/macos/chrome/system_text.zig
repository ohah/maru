//! Session Dock measured system-UI text adapter.
//!
//! CoreText owns CTLine/CTRun and returns only scalar glyph facts.  This module owns the
//! conversion to renderer-neutral records plus final local pixel positions; it deliberately
//! does not know about AppSession, Metal DTOs, or terminal `ResolvedAppearance`.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const chrome = maru.chrome;
const renderer = maru.renderer;
const bridge = @import("../coretext_smoke_bridge.zig");
const probe = @import("../coretext_probe.zig");
const metal_frame = renderer.metal_frame;

pub const Placement = struct {
    x_px: f32,
    y_px: f32,
    advance_px: f32,
    line_height_px: f32,
    foreground: u32,
    /// 스크롤 목록 소속이면 true. 캐시된 아티팩트를 다른 스크롤 위치에서 다시 쓸 때 backend가 이
    /// placement에만 y delta를 더한다 — 고정 chrome은 스크롤해도 제자리이므로 건드리면 안 된다.
    scroll_clipped: bool = false,
};

/// An owned, renderer-free description of the semantic text that CoreText must shape.  It can
/// cross to the detached worker because it contains no draw-list borrow, native handle, atlas
/// state, or FontIdentityRegistry reference.
pub const Request = struct {
    fingerprint: u64,
    runs: []Run,

    pub const Run = struct {
        text: []u8,
        role: chrome.ui.typography.ChromeTextRole,
        origin: chrome.draw.Px,
        max_width_px: u32,
        foreground: u32,
        placement: chrome.draw.TextPlacement = .origin,
        scroll_clipped: bool = false,
    };

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        for (self.runs) |run| allocator.free(run.text);
        allocator.free(self.runs);
        self.* = undefined;
    }
};

/// Scalar CoreText result which deliberately keeps the selected PostScript name as bytes rather
/// than a renderer FontId.  The worker may create this, but the main actor alone resolves it into
/// renderer registry state.
pub const UnresolvedGlyph = struct {
    glyph_id: u32,
    codepoint: u32,
    fallback: bool,
    color_glyph_kind: renderer.ColorGlyphKind,
    x_px: f32,
    advance_px: f32,
    font_name: [128]u8,
    point_size: u16,
    line_height_px: f32,
    origin: chrome.draw.Px,
    foreground: u32,
    run_index: u16,
};

pub const UnresolvedArtifact = struct {
    glyphs: []UnresolvedGlyph,
    placements: []chrome.draw.TextPlacement,
    foregrounds: []u32,
    scroll_flags: []bool,

    pub fn deinit(self: *UnresolvedArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        allocator.free(self.placements);
        allocator.free(self.foregrounds);
        allocator.free(self.scroll_flags);
        self.* = undefined;
    }
};

pub const Artifact = struct {
    records: []renderer.ShapedGlyphRecord,
    placements: []Placement,

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
        allocator.free(self.placements);
        self.* = undefined;
    }

    /// `clip`이 있으면 각 glyph quad를 그 backing-pixel 사각형과 교차시켜 **부분적으로** 남긴다.
    /// glyph는 atlas texture를 입힌 사각형이므로 잘린 비율만큼 UV를 같이 줄이면 결과가 픽셀 정확하다.
    /// 그래서 component가 "이 줄이 clip 안에 통째로 들어가는가"를 미리 판정할 필요가 없다 — 반쯤
    /// 걸친 카드/그룹의 글자도 잘린 그대로 보인다.
    pub fn appendGpuGlyphs(
        self: Artifact,
        allocator: std.mem.Allocator,
        frame: renderer.RenderFrame,
        atlas: renderer.GlyphAtlasConfig,
        origin_x_px: u32,
        origin_y_px: u32,
        clip: ?metal_frame.ClipPx,
        /// 아티팩트가 셰이핑된 시점의 스크롤 위치와 이번 프레임의 스크롤 위치 차이(px). 스크롤은 순수
        /// 평행이동이므로 이 값만 더하면 같은 셰이핑 결과를 다른 스크롤 위치에 정확히 놓을 수 있다.
        scroll_delta_y_px: f32,
        out: *std.ArrayList(metal_frame.GpuGlyph),
    ) !void {
        const texture = renderer.AtlasTextureSize{ .width_px = atlas.atlas_width_px, .height_px = atlas.atlas_height_px };
        for (frame.glyph_quad_frame.glyphs) |glyph| {
            // Atlas placement may reorder/repack glyph runs.  The synthetic row/column pair is
            // the immutable record identity created in shapeOps; positional zip here would put
            // a later label at an earlier label's pixel origin and visibly stack the dock header.
            const placement_index = @as(usize, glyph.run.row) * 256 + glyph.run.col;
            if (placement_index >= self.placements.len) return error.MeasuredGlyphPlacementMissing;
            const placement = self.placements[placement_index];
            const uv = try renderer.glyph_quads.uvRectForSlot(glyph.slot, texture);
            const scrolled_y = placement.y_px + if (placement.scroll_clipped) scroll_delta_y_px else 0;
            // 뷰포트로 자르는 것은 스크롤 목록뿐이다. 고정 chrome은 그 사각형 밖(위)에 있으므로 같은
            // clip을 적용하면 헤더·scope·검색이 통째로 사라진다.
            const glyph_clip: ?metal_frame.ClipPx = if (placement.scroll_clipped) clip else null;
            const quad = clipGlyphQuad(.{
                .x = @as(f32, @floatFromInt(origin_x_px)) + placement.x_px,
                .y = @as(f32, @floatFromInt(origin_y_px)) + scrolled_y,
                .w = @floatFromInt(glyph.slot.width_px),
                .h = @floatFromInt(glyph.slot.height_px),
                .u0 = if (glyph.run.cache_key.color_glyph_kind == .color) uv.u0 + 2.0 else uv.u0,
                .v0 = uv.v0,
                .u1 = uv.u1,
                .v1 = uv.v1,
            }, glyph_clip) orelse continue;
            try out.append(allocator, .{
                .x = quad.x,
                .y = quad.y,
                .w = quad.w,
                .h = quad.h,
                .atlas_x_px = glyph.slot.x_px,
                .atlas_y_px = glyph.slot.y_px,
                .atlas_width_px = glyph.slot.width_px,
                .atlas_height_px = glyph.slot.height_px,
                .u0 = quad.u0,
                .v0 = quad.v0,
                .u1 = quad.u1,
                .v1 = quad.v1,
                .foreground = placement.foreground,
                .layer = 0,
            });
        }
    }
};

const ClippedQuad = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    u0: f32,
    v0: f32,
    u1: f32,
    v1: f32,
};

/// glyph quad ∩ clip. 잘린 만큼 UV를 같은 비율로 좁혀 texture가 늘어나지 않게 한다. color glyph의
/// `u0 + 2.0` sentinel은 렌더러가 정수부로 읽으므로 소수부만 보간하고 sentinel은 보존한다.
fn clipGlyphQuad(quad: ClippedQuad, clip: ?metal_frame.ClipPx) ?ClippedQuad {
    const rect = clip orelse return quad;
    if (rect.w == 0 or rect.h == 0) return null;
    if (quad.w <= 0 or quad.h <= 0) return null;
    const clip_left: f32 = @floatFromInt(rect.x);
    const clip_top: f32 = @floatFromInt(rect.y);
    const clip_right = clip_left + @as(f32, @floatFromInt(rect.w));
    const clip_bottom = clip_top + @as(f32, @floatFromInt(rect.h));
    const left = @max(quad.x, clip_left);
    const top = @max(quad.y, clip_top);
    const right = @min(quad.x + quad.w, clip_right);
    const bottom = @min(quad.y + quad.h, clip_bottom);
    if (right <= left or bottom <= top) return null;
    const sentinel: f32 = if (quad.u0 >= 2.0) 2.0 else 0.0;
    const u_start = quad.u0 - sentinel;
    const u_span = quad.u1 - u_start;
    const v_span = quad.v1 - quad.v0;
    const left_ratio = (left - quad.x) / quad.w;
    const right_ratio = (quad.x + quad.w - right) / quad.w;
    const top_ratio = (top - quad.y) / quad.h;
    const bottom_ratio = (quad.y + quad.h - bottom) / quad.h;
    return .{
        .x = left,
        .y = top,
        .w = right - left,
        .h = bottom - top,
        .u0 = u_start + u_span * left_ratio + sentinel,
        .v0 = quad.v0 + v_span * top_ratio,
        .u1 = quad.u1 - u_span * right_ratio,
        .v1 = quad.v1 - v_span * bottom_ratio,
    };
}

test "clipGlyphQuad trims geometry and UV together and preserves the colour sentinel" {
    const full = ClippedQuad{ .x = 100, .y = 200, .w = 10, .h = 20, .u0 = 0.5, .v0 = 0.25, .u1 = 0.6, .v1 = 0.45 };
    // clip 없음 = 원본 그대로.
    try std.testing.expectEqual(full.w, (clipGlyphQuad(full, null) orelse return error.TestUnexpectedResult).w);
    // 위쪽 절반이 잘리면 높이와 v0가 같은 비율로 움직인다.
    const half = clipGlyphQuad(full, .{ .x = 0, .y = 210, .w = 1000, .h = 1000 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 210), half.y);
    try std.testing.expectEqual(@as(f32, 10), half.h);
    try std.testing.expectApproxEqAbs(@as(f32, 0.35), half.v0, 0.0001);
    try std.testing.expectEqual(full.v1, half.v1);
    // 완전히 밖이면 방출하지 않는다.
    try std.testing.expect(clipGlyphQuad(full, .{ .x = 0, .y = 0, .w = 10, .h = 10 }) == null);
    // color glyph sentinel(+2.0)은 정수부로 살아남고 소수부만 좁아진다.
    const colour = ClippedQuad{ .x = 0, .y = 0, .w = 10, .h = 10, .u0 = 2.5, .v0 = 0, .u1 = 0.6, .v1 = 1 };
    const trimmed = clipGlyphQuad(colour, .{ .x = 5, .y = 0, .w = 100, .h = 100 }) orelse return error.TestUnexpectedResult;
    try std.testing.expect(trimmed.u0 >= 2.0);
    try std.testing.expectApproxEqAbs(@as(f32, 2.55), trimmed.u0, 0.0001);
}

/// Shapes every non-icon Session Dock text op into one immutable artifact. Registered SVG icon
/// ops stay on the legacy synthesized-glyph path until their vector texture migration lands;
/// treating their PUA values as system UI text would silently erase affordances.
pub fn shapeOps(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    scale_milli: u32,
) !Artifact {
    var request = try prepareRequest(allocator, 0, ops, tk, cell_width_px);
    defer request.deinit(allocator);
    var unresolved = try shapeRequest(allocator, &request, scale_milli);
    defer unresolved.deinit(allocator);
    return resolveArtifact(allocator, registry, unresolved);
}

/// Copies only non-icon semantic text out of the frame-local draw list.  This is intentionally
/// cheap enough for the frame path; CoreText shaping is performed only by `shapeRequest`.
pub fn prepareRequest(
    allocator: std.mem.Allocator,
    fingerprint: u64,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
) !Request {
    var runs: std.ArrayList(Request.Run) = .empty;
    errdefer {
        for (runs.items) |run| allocator.free(run.text);
        runs.deinit(allocator);
    }
    for (ops) |op| switch (op) {
        .text => |text| {
            if (text.wide_icons or text.origin.x < 0 or text.origin.y < 0) continue;
            const max_width = text.max_width_px orelse std.math.mul(u32, text.max_cols, cell_width_px) catch continue;
            for (text.runs) |run| {
                // A pure registered SVG placement deliberately has no CoreText source bytes.
                // Keep that semantic run: the detached worker will skip shaping it and resolve
                // the SVG directly from its logical content rect. Ordinary empty text remains
                // inert so an accidental blank label cannot allocate an artifact.
                if ((run.text.len == 0 and text.placement != .icon_in_rect) or max_width == 0) continue;
                try runs.append(allocator, .{
                    .text = try allocator.dupe(u8, run.text),
                    .role = text.text_role,
                    .origin = text.origin,
                    .max_width_px = max_width,
                    .foreground = packRgb(tk.get(text.role)),
                    .placement = text.placement,
                    .scroll_clipped = text.scroll_clipped,
                });
            }
        },
        else => {},
    };
    return .{ .fingerprint = fingerprint, .runs = try runs.toOwnedSlice(allocator) };
}

test "prepareRequest keeps a Korean button label and an icon-in-rect on the measured path" {
    const allocator = std.testing.allocator;
    const icon_runs = [_]chrome.draw.Run{.{ .text = "\u{F000C}" }};
    const label_runs = [_]chrome.draw.Run{.{ .text = "터미널에서 이어하기" }};
    const utility_runs = [_]chrome.draw.Run{.{ .text = "" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{
            .origin = .{ .x = 24, .y = 8 },
            .runs = &icon_runs,
            .role = .surface_fg,
            .text_role = .button_label,
            .max_cols = 2,
            .wide_icons = true,
        } },
        .{ .text = .{
            .origin = .{ .x = 48, .y = 8 },
            .runs = &label_runs,
            .role = .surface_fg,
            .text_role = .button_label,
            .max_cols = 18,
        } },
        .{ .text = .{
            .origin = .{ .x = 80, .y = 8 },
            .runs = &utility_runs,
            .role = .surface_fg,
            .text_role = .control,
            .max_cols = 1,
            .max_width_px = 20,
            .placement = .{ .icon_in_rect = .{
                .content_rect = .{ .x = 80, .y = 8, .w = 20, .h = 20 },
                .icon_codepoint = 0xF0021,
                .icon_extent_px = 18,
            } },
        } },
    };
    const tk = chrome.Tokens.rich(.{
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var request = try prepareRequest(allocator, 17, &ops, &tk, 8);
    defer request.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), request.runs.len);
    try std.testing.expectEqualStrings("터미널에서 이어하기", request.runs[0].text);
    try std.testing.expectEqual(chrome.ui.typography.ChromeTextRole.button_label, request.runs[0].role);
    try std.testing.expectEqual(@as(u32, 18 * 8), request.runs[0].max_width_px);
    try std.testing.expectEqual(@as(usize, 0), request.runs[1].text.len);
    try std.testing.expectEqual(@as(u21, 0xF0021), request.runs[1].placement.icon_in_rect.icon_codepoint);
}

/// Calls CoreText without touching the renderer.  `Request` owns every input byte, so this is
/// safe to run in a detached worker under CoreText's documented thread-safety contract.
pub fn shapeRequest(allocator: std.mem.Allocator, request: *const Request, scale_milli: u32) !UnresolvedArtifact {
    var glyphs: std.ArrayList(UnresolvedGlyph) = .empty;
    errdefer glyphs.deinit(allocator);
    const placements = try allocator.alloc(chrome.draw.TextPlacement, request.runs.len);
    errdefer allocator.free(placements);
    const foregrounds = try allocator.alloc(u32, request.runs.len);
    errdefer allocator.free(foregrounds);
    const scroll_flags = try allocator.alloc(bool, request.runs.len);
    errdefer allocator.free(scroll_flags);
    for (request.runs, 0..) |run, index| {
        if (index > std.math.maxInt(u16)) return error.TooManySystemTextRuns;
        placements[index] = run.placement;
        foregrounds[index] = run.foreground;
        scroll_flags[index] = run.scroll_clipped;
        if (run.placement == .icon_in_rect) continue;
        const shaped = shapeUnresolvedRun(allocator, run, scale_milli) catch |err| switch (run.placement) {
            // A centred Button is all-or-nothing: publishing only its background or a lone
            // icon would make an enabled command look corrupt while hiding the failed label.
            .origin => continue,
            else => return err,
        };
        defer allocator.free(shaped);
        if (shaped.len == 0) switch (run.placement) {
            .origin => continue,
            else => return error.EmptyMeasuredButtonLabel,
        };
        for (shaped) |glyph| {
            var owned = glyph;
            owned.run_index = @intCast(index);
            try glyphs.append(allocator, owned);
        }
    }
    return .{ .glyphs = try glyphs.toOwnedSlice(allocator), .placements = placements, .foregrounds = foregrounds, .scroll_flags = scroll_flags };
}

/// Resolves a completed worker DTO on the main actor.  This bounded conversion is the sole
/// owner of FontIdentityRegistry and intentionally contains no CoreText call.
pub fn resolveArtifact(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    unresolved: UnresolvedArtifact,
) !Artifact {
    var advances = try allocator.alloc(f32, unresolved.placements.len);
    defer allocator.free(advances);
    @memset(advances, 0);
    var line_heights = try allocator.alloc(f32, unresolved.placements.len);
    defer allocator.free(line_heights);
    @memset(line_heights, 0);
    var shaped = try allocator.alloc(bool, unresolved.placements.len);
    defer allocator.free(shaped);
    @memset(shaped, false);
    for (unresolved.glyphs) |glyph| {
        const run_index: usize = glyph.run_index;
        if (run_index >= advances.len) return error.InvalidSystemTextRunIndex;
        advances[run_index] = @max(advances[run_index], glyph.x_px + glyph.advance_px);
        line_heights[run_index] = @max(line_heights[run_index], glyph.line_height_px);
        shaped[run_index] = true;
    }
    var icon_count: usize = 0;
    for (unresolved.placements, shaped) |placement, has_glyph| switch (placement) {
        .icon_in_rect => icon_count += 1,
        .leading_icon_group => {
            if (has_glyph) icon_count += 1;
        },
        else => {},
    };
    const total_count = std.math.add(usize, unresolved.glyphs.len, icon_count) catch return error.TooManySystemTextGlyphs;
    const records = try allocator.alloc(renderer.ShapedGlyphRecord, total_count);
    errdefer allocator.free(records);
    const placements = try allocator.alloc(Placement, total_count);
    var record_index: usize = 0;
    for (unresolved.glyphs) |glyph| {
        const run_index: usize = glyph.run_index;
        const layout = unresolved.placements[run_index];
        const label_origin = labelOrigin(layout, glyph.origin, advances[run_index], glyph.line_height_px);
        const record = &records[record_index];
        const placement = &placements[record_index];
        const name = probe.cStringField(&glyph.font_name);
        const font_id = try registry.intern(.{ .postscript_name = name });
        const advance = @max(glyph.advance_px, 1.0);
        record.* = .{
            .row = @intCast(record_index / 256),
            .col = @intCast(record_index % 256),
            .cell_width = 1,
            .codepoint = @intCast(@min(glyph.codepoint, std.math.maxInt(u21))),
            .font_id = font_id,
            .glyph_id = glyph.glyph_id,
            .fallback = glyph.fallback,
            .color_glyph_kind = glyph.color_glyph_kind,
            .raster_font_size_milli = @intCast(@as(u32, glyph.point_size) * 1000),
            .raster_width_px = @intFromFloat(@ceil(advance)),
            .raster_height_px = @intFromFloat(@ceil(glyph.line_height_px)),
        };
        placement.* = .{
            .x_px = label_origin.x_px + glyph.x_px,
            .y_px = label_origin.y_px,
            .advance_px = advance,
            .line_height_px = glyph.line_height_px,
            .foreground = glyph.foreground,
            .scroll_clipped = unresolved.scroll_flags[run_index],
        };
        record_index += 1;
    }
    for (unresolved.placements, shaped, advances, line_heights, unresolved.foregrounds, unresolved.scroll_flags) |layout, has_glyph, advance, line_height, foreground, scroll_clipped| switch (layout) {
        .icon_in_rect => |icon| {
            if (!renderer.icon_glyph.isRegisteredIcon(icon.icon_codepoint)) return error.UnregisteredChromeIcon;
            records[record_index] = .{ .row = @intCast(record_index / 256), .col = @intCast(record_index % 256), .cell_width = 1, .codepoint = icon.icon_codepoint, .font_id = 0, .glyph_id = 0, .color_glyph_kind = .monochrome, .raster_width_px = icon.icon_extent_px, .raster_height_px = icon.icon_extent_px };
            placements[record_index] = .{ .x_px = @as(f32, @floatFromInt(icon.content_rect.x)) + (@as(f32, @floatFromInt(icon.content_rect.w)) - @as(f32, @floatFromInt(icon.icon_extent_px))) / 2, .y_px = @as(f32, @floatFromInt(icon.content_rect.y)) + (@as(f32, @floatFromInt(icon.content_rect.h)) - @as(f32, @floatFromInt(icon.icon_extent_px))) / 2, .advance_px = @floatFromInt(icon.icon_extent_px), .line_height_px = @floatFromInt(icon.icon_extent_px), .foreground = foreground, .scroll_clipped = scroll_clipped };
            record_index += 1;
        },
        .leading_icon_group => |group| {
            if (!has_glyph) continue;
            if (!renderer.icon_glyph.isRegisteredIcon(group.icon_codepoint)) return error.UnregisteredChromeIcon;
            const group_width = @as(f32, @floatFromInt(group.icon_extent_px + group.gap_px)) + advance;
            const x = @as(f32, @floatFromInt(group.content_rect.x)) + (@as(f32, @floatFromInt(group.content_rect.w)) - group_width) / 2;
            const y = @as(f32, @floatFromInt(group.content_rect.y)) + (@as(f32, @floatFromInt(group.content_rect.h)) - @as(f32, @floatFromInt(group.icon_extent_px))) / 2;
            records[record_index] = .{
                .row = @intCast(record_index / 256),
                .col = @intCast(record_index % 256),
                .cell_width = 1,
                .codepoint = group.icon_codepoint,
                // Registered SVG coverage is selected by codepoint.  No platform font or
                // CoreText call is needed for this record, and the renderer's glyph_id=0
                // synthetic gate prevents it from sharing a font glyph atlas slot.
                .font_id = 0,
                .glyph_id = 0,
                .color_glyph_kind = .monochrome,
                .raster_width_px = group.icon_extent_px,
                .raster_height_px = group.icon_extent_px,
            };
            placements[record_index] = .{
                .x_px = x,
                .y_px = y,
                .advance_px = @floatFromInt(group.icon_extent_px),
                .line_height_px = if (line_height > 0) line_height else @floatFromInt(group.icon_extent_px),
                .foreground = foreground,
                .scroll_clipped = scroll_clipped,
            };
            record_index += 1;
        },
        else => {},
    };
    if (record_index != total_count) return error.InvalidSystemTextArtifact;
    return .{ .records = records, .placements = placements };
}

const ResolvedOrigin = struct { x_px: f32, y_px: f32 };

fn labelOrigin(layout: chrome.draw.TextPlacement, fallback: chrome.draw.Px, advance: f32, line_height: f32) ResolvedOrigin {
    return switch (layout) {
        .origin => .{ .x_px = @floatFromInt(fallback.x), .y_px = @floatFromInt(fallback.y) },
        .center_in_rect => |rect| .{
            .x_px = @as(f32, @floatFromInt(rect.x)) + (@as(f32, @floatFromInt(rect.w)) - advance) / 2,
            .y_px = @as(f32, @floatFromInt(rect.y)) + (@as(f32, @floatFromInt(rect.h)) - line_height) / 2,
        },
        .icon_in_rect => unreachable,
        .leading_icon_group => |group| .{
            .x_px = @as(f32, @floatFromInt(group.content_rect.x)) + (@as(f32, @floatFromInt(group.content_rect.w)) - (@as(f32, @floatFromInt(group.icon_extent_px + group.gap_px)) + advance)) / 2 + @as(f32, @floatFromInt(group.icon_extent_px + group.gap_px)),
            .y_px = @as(f32, @floatFromInt(group.content_rect.y)) + (@as(f32, @floatFromInt(group.content_rect.h)) - line_height) / 2,
        },
    };
}

test "leading icon group resolves measured label and SVG to one final-pixel artifact" {
    const allocator = std.testing.allocator;
    var font_name = [_]u8{0} ** 128;
    @memcpy(font_name[0..6], "System");
    const glyphs = try allocator.dupe(UnresolvedGlyph, &.{.{
        .glyph_id = 12,
        .codepoint = 'A',
        .fallback = false,
        .color_glyph_kind = .monochrome,
        .x_px = 0,
        .advance_px = 30,
        .font_name = font_name,
        .point_size = 14,
        .line_height_px = 20,
        .origin = .{ .x = 0, .y = 0 },
        .foreground = 0xAABBCC,
        .run_index = 0,
    }});
    const layouts = try allocator.dupe(chrome.draw.TextPlacement, &.{.{ .leading_icon_group = .{
        .content_rect = .{ .x = 20, .y = 10, .w = 100, .h = 30 },
        .icon_codepoint = 0xF000C,
        .icon_extent_px = 20,
        .gap_px = 10,
    } }});
    const foregrounds = try allocator.dupe(u32, &.{0xAABBCC});
    var unresolved = UnresolvedArtifact{ .glyphs = glyphs, .placements = layouts, .foregrounds = foregrounds, .scroll_flags = try allocator.dupe(bool, &.{false}) };
    defer unresolved.deinit(allocator);
    var registry = renderer.FontIdentityRegistry.init(allocator);
    defer registry.deinit();
    var artifact = try resolveArtifact(allocator, &registry, unresolved);
    defer artifact.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), artifact.records.len);
    try std.testing.expectEqual(@as(f32, 70), artifact.placements[0].x_px);
    try std.testing.expectEqual(@as(f32, 15), artifact.placements[0].y_px);
    try std.testing.expectEqual(@as(u21, 0xF000C), artifact.records[1].codepoint);
    try std.testing.expectEqual(@as(u32, 0), artifact.records[1].glyph_id);
    try std.testing.expectEqual(@as(f32, 40), artifact.placements[1].x_px);
    try std.testing.expectEqual(@as(f32, 15), artifact.placements[1].y_px);
}

test "icon in rect resolves a registered SVG without a CoreText glyph" {
    const allocator = std.testing.allocator;
    const glyphs = try allocator.alloc(UnresolvedGlyph, 0);
    const layouts = try allocator.dupe(chrome.draw.TextPlacement, &.{.{ .icon_in_rect = .{
        .content_rect = .{ .x = 100, .y = 40, .w = 20, .h = 20 },
        .icon_codepoint = 0xF0021,
        .icon_extent_px = 18,
    } }});
    const foregrounds = try allocator.dupe(u32, &.{0x123456});
    var unresolved = UnresolvedArtifact{ .glyphs = glyphs, .placements = layouts, .foregrounds = foregrounds, .scroll_flags = try allocator.dupe(bool, &.{false}) };
    defer unresolved.deinit(allocator);
    var registry = renderer.FontIdentityRegistry.init(allocator);
    defer registry.deinit();
    var artifact = try resolveArtifact(allocator, &registry, unresolved);
    defer artifact.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), artifact.records.len);
    try std.testing.expectEqual(@as(u21, 0xF0021), artifact.records[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0), artifact.records[0].glyph_id);
    try std.testing.expectEqual(@as(f32, 101), artifact.placements[0].x_px);
    try std.testing.expectEqual(@as(f32, 41), artifact.placements[0].y_px);
    try std.testing.expectEqual(@as(u32, 0x123456), artifact.placements[0].foreground);
}

pub fn emptyDrawList(allocator: std.mem.Allocator, glyph_count: usize) !renderer.DrawList {
    const rows: u16 = @intCast(@max(@as(usize, 1), (glyph_count + 255) / 256));
    return .{
        .size = .{ .cols = 256, .rows = rows },
        .cursor = .{ .visible = false },
        .dirty = .{ .start_row = 0, .end_row = rows - 1 },
        .cells = try allocator.alloc(renderer.DrawCell, 0),
        .grapheme_pool = try allocator.alloc(u32, 0),
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

fn weight(role: chrome.ui.typography.ChromeTextRole) u32 {
    return switch (chrome.ui.typography.token(role).weight) {
        .regular => 0,
        .medium, .semibold => 1,
    };
}

fn packRgb(rgb: maru.color.Rgb) u32 {
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

/// Shapes exactly one semantic run.  `origin` is the component's final local line-box origin;
/// the native bridge supplies proportional advances and actual fallback face identity.
pub fn shapeRun(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    text: []const u8,
    role: chrome.ui.typography.ChromeTextRole,
    origin: chrome.draw.Px,
    max_width_px: u32,
    foreground: u32,
    scale_milli: u32,
) !Artifact {
    const owned = try allocator.dupe(u8, text);
    var request = Request{ .fingerprint = 0, .runs = &.{.{ .text = owned, .role = role, .origin = origin, .max_width_px = max_width_px, .foreground = foreground }} };
    defer request.deinit(allocator);
    var unresolved = try shapeRequest(allocator, &request, scale_milli);
    defer unresolved.deinit(allocator);
    return resolveArtifact(allocator, registry, unresolved);
}

fn shapeUnresolvedRun(allocator: std.mem.Allocator, run: Request.Run, scale_milli: u32) ![]UnresolvedGlyph {
    // The boundary/portable test targets link this module without the macOS CoreText object
    // file. Keep the product-only bridge unreachable there instead of leaving an undefined
    // native symbol merely because a detached-worker test imports its type.
    if (builtin.os.tag != .macos) return error.UnsupportedSystemText;
    const point_size = chrome.ui.typography.token(run.role).point_size;
    const scaled_size = @as(f64, @floatFromInt(point_size)) * @as(f64, @floatFromInt(scale_milli)) / 1000.0;
    var native: bridge.NativeChromeTextShapeResult = .{};
    const capacity = @max(@as(usize, 16), run.text.len * 2);
    var glyphs = try allocator.alloc(bridge.NativeChromeTextGlyphRecord, capacity);
    defer allocator.free(glyphs);
    bridge.maru_macos_coretext_shape_chrome_text(run.text.ptr, run.text.len, scaled_size, weight(run.role), @floatFromInt(run.max_width_px), &native, glyphs.ptr, glyphs.len);
    if (native.status != 0 or native.glyph_record_overflow != 0) return error.CoreTextChromeTextShapeFailed;
    const count = @min(@as(usize, native.glyph_record_count), glyphs.len);
    const out = try allocator.alloc(UnresolvedGlyph, count);
    for (glyphs[0..count], out) |native_glyph, *glyph| {
        glyph.* = .{
            .glyph_id = native_glyph.glyph_id,
            .codepoint = native_glyph.codepoint,
            .fallback = native_glyph.fallback != 0,
            .color_glyph_kind = if (native_glyph.color_glyph_kind != 0) .color else .monochrome,
            .x_px = native_glyph.x_px,
            .advance_px = native_glyph.advance_px,
            .font_name = native_glyph.font_name,
            .point_size = point_size,
            .line_height_px = @floatFromInt(chrome.ui.typography.lineHeightPx(run.role, scale_milli)),
            .origin = run.origin,
            .foreground = run.foreground,
            .run_index = 0,
        };
    }
    return out;
}

test "owned request shapes proportional text before renderer registry resolution" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "Agent 세션 기록" }};
    const ops = [_]chrome.draw.Op{.{ .text = .{
        .origin = .{ .x = 12, .y = 8 },
        .runs = &runs,
        .role = .surface_fg,
        .text_role = .dock_heading,
        .max_cols = 40,
    } }};
    const tokens = chrome.Tokens.rich(.{
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 10, .g = 10, .b = 10 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 50, .g = 50, .b = 50 },
        .search_match = .{ .r = 20, .g = 120, .b = 255 },
        .search_match_current = .{ .r = 255, .g = 180, .b = 20 },
        .selection = .{ .r = 60, .g = 80, .b = 120 },
        .cursor = .{ .r = 255, .g = 255, .b = 255 },
        .accent = .{ .r = 20, .g = 120, .b = 255 },
    });
    var request = try prepareRequest(allocator, 44, &ops, &tokens, 16);
    defer request.deinit(allocator);
    var artifact = try shapeRequest(allocator, &request, 2000);
    defer artifact.deinit(allocator);
    try std.testing.expect(artifact.glyphs.len > 0);
}
