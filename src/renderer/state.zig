const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const glyph_frame = @import("glyph_frame.zig");
const glyph_layout = @import("glyph_layout.zig");
const glyph_quads = @import("glyph_quads.zig");
const terminal = @import("../terminal.zig");
const types = @import("types.zig");

pub const RendererStateConfig = struct {
    backend: types.Backend = types.initialBackendForMacOS(),
    text: glyph_layout.TextLayoutConfig = .{},
    atlas: glyph_atlas.GlyphAtlasConfig = .{},
};

pub const RendererState = struct {
    backend: types.Backend,
    text_config: glyph_layout.TextLayoutConfig,
    atlas: glyph_atlas.GlyphAtlas,

    pub fn init(allocator: std.mem.Allocator, config: RendererStateConfig) RendererState {
        // RendererState는 frame 사이에 살아남는 renderer 소유 상태다. 특히 GlyphAtlas를
        // 매 frame 새로 만들면 cache hit/miss, upload byte, eviction 진단이 모두
        // 의미 없어지므로 여기서 오래 들고 간다.
        return .{
            .backend = config.backend,
            .text_config = config.text,
            .atlas = glyph_atlas.GlyphAtlas.init(allocator, config.atlas),
        };
    }

    pub fn deinit(self: *RendererState) void {
        self.atlas.deinit();
        self.* = undefined;
    }

    pub fn buildFrame(
        self: *RendererState,
        allocator: std.mem.Allocator,
        snapshot: terminal.RenderSnapshot,
        shaper: anytype,
    ) !types.RenderFrame {
        // 이 함수는 제품 backend가 소비할 한 frame을 준비하는 facade다. app/platform layer는
        // TerminalCore snapshot만 넘기고, font layout과 atlas reuse는 renderer 내부에서
        // 끝난다. 이렇게 해야 Metal backend가 DrawList를 다시 해석하지 않는다.
        var list = try draw_list.buildDrawList(allocator, snapshot);
        errdefer list.deinit(allocator);

        var glyphs = try glyph_layout.buildGlyphRunList(allocator, list, self.text_config, shaper);
        defer glyphs.deinit(allocator);

        var frame = try glyph_frame.prepareGlyphFrame(allocator, glyphs, &self.atlas);
        errdefer frame.deinit(allocator);

        var quad_frame = try glyph_quads.buildGlyphQuadFrame(allocator, frame, .{
            .width_px = self.atlas.config.atlas_width_px,
            .height_px = self.atlas.config.atlas_height_px,
        });
        errdefer quad_frame.deinit(allocator);

        return .{
            .backend = self.backend,
            .draw_list = list,
            .glyph_frame = frame,
            .glyph_quad_frame = quad_frame,
        };
    }
};

pub fn textConfigFromFontSize(font_size: f32, device_scale: u16) glyph_layout.TextLayoutConfig {
    // ResolvedAppearance는 정상 font_size를 보장하고, macOS backing scale은 정상적으로
    // 1~3이다. 그래도 이 함수는 cache key의 마지막 방어선이다. debug assert에만
    // 기대면 ReleaseFast에서 NaN/inf가 @intFromFloat UB로 이어지거나, device_scale=0이
    // atlas key에 들어가 같은 glyph를 잘못된 scale로 캐시할 수 있다. font_size를 [1,512]로
    // 막는 것과 대칭으로 device_scale도 상한을 둬, 손상된 값이 atlas bitmap 크기를 비정상으로
    // 키우지 않게 한다(상한 8은 실무 backing scale 1~3보다 넉넉하다).
    const finite_size = if (std.math.isFinite(font_size)) font_size else 1.0;
    const clamped_size = @max(@as(f32, 1.0), @min(@as(f32, 512.0), finite_size));
    const clamped_scale = std.math.clamp(device_scale, 1, 8);
    return .{
        .font_size_px = @intFromFloat(@round(clamped_size)),
        .device_scale = clamped_scale,
    };
}

test "renderer state builds glyph frame and reuses atlas across frames" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 3, .rows = 1 });
    defer core.deinit();

    var state = RendererState.init(std.testing.allocator, .{});
    defer state.deinit();

    // 첫 frame은 atlas가 비어 있으므로 A와 space가 upload 후보가 된다.
    core.clearDirty();
    try core.write("A");
    var first = try state.buildFrame(std.testing.allocator, core.snapshot(), glyph_layout.FakeFontBackend{});
    defer first.deinit(std.testing.allocator);

    try std.testing.expectEqual(types.Backend.metal, first.backend);
    try std.testing.expectEqual(@as(usize, 3), first.draw_list.cells.len);
    try std.testing.expectEqual(@as(usize, 3), first.glyph_frame.stats.glyph_count);
    try std.testing.expect(first.glyph_quad_frame.stats.ready());
    try std.testing.expect(first.glyph_frame.stats.upload_count > 0);

    // 같은 glyph를 다음 frame에서 다시 그리면 atlas slot을 재사용해야 한다.
    // persistent RendererState가 없으면 이 테스트는 매번 upload_count>0이 된다.
    core.clearDirty();
    try core.write("\rA");
    var second = try state.buildFrame(std.testing.allocator, core.snapshot(), glyph_layout.FakeFontBackend{});
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), second.glyph_frame.stats.glyph_count);
    try std.testing.expectEqual(second.glyph_frame.stats.glyph_count, second.glyph_quad_frame.stats.glyph_count);
    try std.testing.expect(second.glyph_quad_frame.stats.ready());
    try std.testing.expectEqual(@as(usize, 0), second.glyph_frame.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 3), second.glyph_frame.stats.reused_count);
    try std.testing.expect(state.atlas.stats.hits > 0);
}

test "text config converts resolved font size into cache key units" {
    // config resolver는 f32 size를 다루지만 glyph atlas key는 현재 u16 px를 쓴다.
    // 이 변환이 여러 smoke마다 흩어지면 16.6 같은 값에서 서로 다른 cache key가 생긴다.
    const text = textConfigFromFontSize(16.6, 2);
    try std.testing.expectEqual(@as(u16, 17), text.font_size_px);
    try std.testing.expectEqual(@as(u16, 2), text.device_scale);
}

test "text config clamps invalid cache key inputs before renderer state uses them" {
    // 이 테스트는 ReleaseFast에서 사라지는 assert가 아니라 실제 정규화 계약을 고정한다.
    // font size와 device scale은 glyph atlas key 일부라, 비정상 값이 그대로 들어가면 같은
    // glyph가 서로 다른/불가능한 scale로 캐시되어 renderer 진단이 틀어진다.
    const nan_size = textConfigFromFontSize(std.math.nan(f32), 0);
    try std.testing.expectEqual(@as(u16, 1), nan_size.font_size_px);
    try std.testing.expectEqual(@as(u16, 1), nan_size.device_scale);

    const non_finite_size = textConfigFromFontSize(std.math.inf(f32), 0);
    try std.testing.expectEqual(@as(u16, 1), non_finite_size.font_size_px);
    try std.testing.expectEqual(@as(u16, 1), non_finite_size.device_scale);

    const below_range = textConfigFromFontSize(-10.0, 0);
    try std.testing.expectEqual(@as(u16, 1), below_range.font_size_px);
    try std.testing.expectEqual(@as(u16, 1), below_range.device_scale);

    const above_range = textConfigFromFontSize(900.0, 3);
    try std.testing.expectEqual(@as(u16, 512), above_range.font_size_px);
    try std.testing.expectEqual(@as(u16, 3), above_range.device_scale);

    // device_scale도 font_size처럼 상한으로 막는다. 손상된 큰 backing scale이 그대로
    // atlas key에 들어가면 glyph bitmap 크기가 비정상으로 커진다.
    const scale_above_range = textConfigFromFontSize(14.0, 99);
    try std.testing.expectEqual(@as(u16, 14), scale_above_range.font_size_px);
    try std.testing.expectEqual(@as(u16, 8), scale_above_range.device_scale);
}
