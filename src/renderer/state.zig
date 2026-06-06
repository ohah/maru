const std = @import("std");
const draw_list = @import("draw_list.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const glyph_frame = @import("glyph_frame.zig");
const glyph_layout = @import("glyph_layout.zig");
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

        return .{
            .backend = self.backend,
            .draw_list = list,
            .glyph_frame = frame,
        };
    }
};

pub fn textConfigFromFontSize(font_size: f32, device_scale: u16) glyph_layout.TextLayoutConfig {
    // ResolvedAppearance가 font_size의 1..512 범위를 보장한다. renderer는 현재 atlas key에
    // 정수 px를 쓰므로 반올림한다. fractional point/px까지 필요해지는 시점에는 이 함수가
    // public 정책 변경 지점이 된다.
    std.debug.assert(font_size >= 1.0 and font_size <= 512.0);
    std.debug.assert(device_scale > 0);
    // assert는 ReleaseFast에서 사라진다. 그 빌드에서도 범위 밖/NaN/inf 입력이 들어와
    // @intFromFloat가 UB(쓰레기 px -> atlas cache key 오염)가 되지 않도록 supported
    // 범위로 clamp한다. resolved(정상) 입력에서는 값이 그대로다.
    const finite_size = if (std.math.isFinite(font_size)) font_size else 1.0;
    const clamped_size = @max(@as(f32, 1.0), @min(@as(f32, 512.0), finite_size));
    return .{
        .font_size_px = @intFromFloat(@round(clamped_size)),
        .device_scale = device_scale,
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
    try std.testing.expect(first.glyph_frame.stats.upload_count > 0);

    // 같은 glyph를 다음 frame에서 다시 그리면 atlas slot을 재사용해야 한다.
    // persistent RendererState가 없으면 이 테스트는 매번 upload_count>0이 된다.
    core.clearDirty();
    try core.write("\rA");
    var second = try state.buildFrame(std.testing.allocator, core.snapshot(), glyph_layout.FakeFontBackend{});
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), second.glyph_frame.stats.glyph_count);
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
