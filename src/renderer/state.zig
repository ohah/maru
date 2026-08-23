const std = @import("std");
const draw_list = @import("draw_list.zig");
const font_identity = @import("font_identity.zig");
const glyph_atlas = @import("glyph_atlas.zig");
const glyph_frame = @import("glyph_frame.zig");
const glyph_layout = @import("glyph_layout.zig");
const glyph_quads = @import("glyph_quads.zig");
const glyph_raster = @import("glyph_raster.zig");
const shaped_records = @import("shaped_records.zig");
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
    // glyph atlas의 cache key는 face 정체성을 `FontId`로 담는다(같은 glyph id라도 face가 다르면 다른 모양).
    // 그런데 `FontId`는 registry에 face가 **처음 등장한 순서**로 매기는 지역 순번이라, registry가 frame·pane마다
    // 새로 만들어지면 같은 순번이 frame마다 다른 face를 가리킨다. atlas는 frame 사이에 살아남으므로, 그러면
    // 어제 emoji face용으로 구운 slot을 오늘 한글 face가 같은 (FontId,glyph_id)로 HIT해 엉뚱한 글리프(예: 조합 중
    // '놔'에 번개)가 그려진다. 그래서 이 registry를 **atlas와 같은 수명**으로 여기 두어, 같은 PostScript name이 앱
    // 수명 내내 같은 `FontId`를 받게 한다(원 설계 의도 — renderer/README.md). 모든 shape/rasterize가 렌더 스레드
    // 단일 실행(docs/io-render-threading.md §3 — shaping은 락 밖 단일 렌더 스레드)이라 락은 불필요하다.
    font_registry: font_identity.FontIdentityRegistry,

    pub fn init(allocator: std.mem.Allocator, config: RendererStateConfig) RendererState {
        // RendererState는 frame 사이에 살아남는 renderer 소유 상태다. 특히 GlyphAtlas를
        // 매 frame 새로 만들면 cache hit/miss, upload byte, eviction 진단이 모두
        // 의미 없어지므로 여기서 오래 들고 간다. font_registry도 같은 이유로 여기서 오래 들고 가
        // atlas cache key의 FontId를 frame 간 안정시킨다(위 필드 주석).
        return .{
            .backend = config.backend,
            .text_config = config.text,
            .atlas = glyph_atlas.GlyphAtlas.init(allocator, config.atlas),
            .font_registry = font_identity.FontIdentityRegistry.init(allocator),
        };
    }

    pub fn deinit(self: *RendererState) void {
        self.atlas.deinit();
        self.font_registry.deinit();
        self.* = undefined;
    }

    pub fn buildFrame(
        self: *RendererState,
        allocator: std.mem.Allocator,
        snapshot: terminal.RenderSnapshot,
        shaper: anytype,
    ) !types.RenderFrame {
        return self.buildFrameWithRasterizer(allocator, snapshot, shaper, glyph_raster.FakeGlyphRasterizer{});
    }

    pub fn buildFrameWithRasterizer(
        self: *RendererState,
        allocator: std.mem.Allocator,
        snapshot: terminal.RenderSnapshot,
        shaper: anytype,
        rasterizer: anytype,
    ) !types.RenderFrame {
        // 이 함수는 제품 backend가 소비할 한 frame을 준비하는 facade다. app/platform layer는
        // TerminalCore snapshot만 넘기고, font layout과 atlas reuse는 renderer 내부에서
        // 끝난다. 이렇게 해야 Metal backend가 DrawList를 다시 해석하지 않는다.
        var list = try draw_list.buildDrawList(allocator, snapshot);
        errdefer list.deinit(allocator);
        return self.buildFrameFromDrawListWithRasterizer(allocator, list, shaper, rasterizer);
    }

    /// 이미 만든 DrawList로 frame을 준비한다(shaping + atlas/raster — 코어 snapshot 무관).
    /// I/O–렌더 스레딩 분리(docs/io-render-threading.md): app/platform이 코어 락 안에서
    /// snapshot→buildDrawList(코어→DrawList 복사)까지 끝낸 뒤, **락 밖**에서 이걸 불러 shaping을
    /// 코어와 분리한다(shaping은 DrawList 복사본만 보므로 리더의 core.write와 무관). 성공 시 반환
    /// frame이 list를 소유하고, 실패 시 caller가 여전히 list를 소유한다(caller errdefer).
    pub fn buildFrameFromDrawList(
        self: *RendererState,
        allocator: std.mem.Allocator,
        list: draw_list.DrawList,
        shaper: anytype,
    ) !types.RenderFrame {
        return self.buildFrameFromDrawListWithRasterizer(allocator, list, shaper, glyph_raster.FakeGlyphRasterizer{});
    }

    pub fn buildFrameFromDrawListWithRasterizer(
        self: *RendererState,
        allocator: std.mem.Allocator,
        list: draw_list.DrawList,
        shaper: anytype,
        rasterizer: anytype,
    ) !types.RenderFrame {
        var glyphs = try glyph_layout.buildGlyphRunList(allocator, list, self.text_config, shaper);
        defer glyphs.deinit(allocator);
        return self.buildFrameFromGlyphRunListWithRasterizer(allocator, list, glyphs, rasterizer);
    }

    pub fn buildFrameFromGlyphRunList(
        self: *RendererState,
        allocator: std.mem.Allocator,
        list: draw_list.DrawList,
        glyphs: glyph_layout.GlyphRunList,
    ) !types.RenderFrame {
        return self.buildFrameFromGlyphRunListWithRasterizer(allocator, list, glyphs, glyph_raster.FakeGlyphRasterizer{});
    }

    pub fn buildFrameFromGlyphRunListWithRasterizer(
        self: *RendererState,
        allocator: std.mem.Allocator,
        list: draw_list.DrawList,
        glyphs: glyph_layout.GlyphRunList,
        rasterizer: anytype,
    ) !types.RenderFrame {
        // 실제 CoreText shaper는 cell마다 `shape(cell)`을 호출하는 fake backend 계약에
        // 맞지 않는다. CoreText는 DrawList 전체를 보고 이미 shaped glyph run을 만든 뒤
        // 여기로 들어와야 한다. 이 함수는 그 다음 단계인 atlas/UV/raster 준비만 맡는다.
        //
        // ownership 규칙은 의도적으로 명확히 둔다. 성공하면 반환된 RenderFrame이 `list`를
        // 소유하고 deinit한다. 실패하면 caller가 여전히 `list`를 소유하므로 caller의
        // errdefer가 정리해야 한다. 이렇게 해야 CoreText shaper 실패와 frame 준비 실패를
        // 같은 DrawList artifact로 디버깅할 수 있다.
        // frame 소유권을 buildQuadRasterFromGlyphFrame으로 넘긴다 — 성공 시 RenderFrame이, 실패 시 그 함수의
        // errdefer가 frame을 정리한다. 여기서 errdefer frame.deinit을 또 두면 실패 경로에서 double-free다.
        const frame = try glyph_frame.prepareGlyphFrame(allocator, glyphs, &self.atlas);
        return self.buildQuadRasterFromGlyphFrame(allocator, list, frame, rasterizer);
    }

    /// 여러 페인(GlyphRunList)을 **한 atlas 세대로** 배치한다. 멀티 페인이 atlas를 공유할 때 어떤 페인이
    /// 소진을 일으켜도 전 페인이 한 세대로 (재)배치+(재)업로드되어 cross-pane 깨짐을 차단한다(glyph_frame
    /// 의 prepareMultiPaneGlyphFrame 참조). 반환 GlyphFrame 슬라이스는 owned — caller가 각 frame.deinit +
    /// 슬라이스 free. shaping(GlyphRunList 생성)은 호출 전에 끝내고, 배치 후 per-pane quad/raster는
    /// buildQuadRasterFromGlyphFrame으로 잇는다(shape/place/finalize 분리).
    pub fn placeMultiPane(
        self: *RendererState,
        allocator: std.mem.Allocator,
        lists: []const glyph_layout.GlyphRunList,
    ) ![]glyph_frame.GlyphFrame {
        return glyph_frame.prepareMultiPaneGlyphFrame(allocator, lists, &self.atlas);
    }

    /// 이미 배치된 GlyphFrame(place 결과)으로 quad/raster를 만들고 RenderFrame을 조립한다. atlas 크기는
    /// place 시점 이후 grow됐을 수 있으므로 **현재 atlas dims**를 쓴다(멀티 페인 통합 후 단일 세대라
    /// 빌드 dims==최종 dims로 수렴; renormalizeGlyphCellUvs가 안전망). ownership: 성공 시 RenderFrame이
    /// frame과 list를 소유한다. 실패 시 frame은 여기서 정리하고, list는 caller가 소유한다(caller errdefer).
    pub fn buildQuadRasterFromGlyphFrame(
        self: *RendererState,
        allocator: std.mem.Allocator,
        list: draw_list.DrawList,
        frame: glyph_frame.GlyphFrame,
        rasterizer: anytype,
    ) !types.RenderFrame {
        var owned_frame = frame;
        errdefer owned_frame.deinit(allocator);

        var quad_frame = try glyph_quads.buildGlyphQuadFrame(allocator, owned_frame, .{
            .width_px = self.atlas.config.atlas_width_px,
            .height_px = self.atlas.config.atlas_height_px,
        });
        errdefer quad_frame.deinit(allocator);

        var raster_frame = try glyph_raster.buildGlyphRasterFrame(allocator, owned_frame, .{
            .texture_size = .{
                .width_px = self.atlas.config.atlas_width_px,
                .height_px = self.atlas.config.atlas_height_px,
            },
        }, rasterizer);
        errdefer raster_frame.deinit(allocator);

        return .{
            .backend = self.backend,
            .draw_list = list,
            .glyph_frame = owned_frame,
            .glyph_quad_frame = quad_frame,
            .glyph_raster_frame = raster_frame,
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

/// backing scale을 천분율(scale_milli, 예: 2000 = 2.0×)에서 정수 device_scale[1,8]로 반올림한다.
/// 정수 device_scale는 atlas 정사각 fallback(메트릭 없는 테스트/fake backend 경로)과 cache key의
/// 거친 식별자로만 쓰인다. 실제 화면 경로는 cell_width_px/cell_height_px(분수 scale에서 나온 실제
/// 픽셀 크기)로 정밀 식별하므로 반올림 손실이 렌더에 영향을 주지 않는다. scale_milli는 C ABI
/// 경계의 u32라 범위를 보장하지 않으므로 +500 반올림을 u64로 계산해 overflow하지 않는다.
pub fn deviceScaleFromMilli(scale_milli: u32) u16 {
    return @intCast(std.math.clamp((@as(u64, scale_milli) + 500) / 1000, 1, 8));
}

/// 논리 font size와 backing scale(천분율)에서 device 픽셀 font size를 구한다. 정수 배율로
/// 반올림하지 않고 분수 scale을 그대로 곱해, 분수 Retina(1.5×/2.5×)에서도 glyph가 실제 해상도로
/// rasterize되고 cell 메트릭이 drawable과 어긋나지 않게 한다. font_size는 [1,512], scale_milli는
/// [250,8000](0.25×~8×)로 막아 손상된 값에서도 곱이 overflow하지 않게 한다.
/// 글리프 하나가 쓸 **논리 pt** 크기. `raster_font_size_milli` 가 0 이면 기본(터미널) 크기다.
///
/// **규칙을 여기 둔다** — measured 크롬 텍스트가 role 마다 크기를 싣고 그것을 푸는 쪽이 플랫폼
/// 래스터라이저인데(그 필드 doc), macOS 와 Windows 가 각자 적으면 같은 도크가 두 플랫폼에서 다른
/// 글자 크기로 구워진다. 한 줄짜리 규칙이라 더 그렇다 — 눈에 안 띄게 갈린다.
pub fn glyphFontSizePt(default_pt: f32, raster_font_size_milli: u16) f32 {
    if (raster_font_size_milli == 0) return default_pt;
    return @as(f32, @floatFromInt(raster_font_size_milli)) / 1000.0;
}

test "글리프 폰트 크기: 0 은 기본, 그 외는 밀리를 pt 로" {
    try std.testing.expectEqual(@as(f32, 13.0), glyphFontSizePt(13.0, 0));
    try std.testing.expectEqual(@as(f32, 18.0), glyphFontSizePt(13.0, 18_000));
    try std.testing.expectEqual(@as(f32, 11.5), glyphFontSizePt(13.0, 11_500));
}

pub fn deviceFontSizeFromMilli(font_size: f32, scale_milli: u32) f64 {
    const finite_size: f64 = if (std.math.isFinite(font_size)) @floatCast(font_size) else 1.0;
    const clamped_size = @max(@as(f64, 1.0), @min(@as(f64, 512.0), finite_size));
    const clamped_milli = std.math.clamp(scale_milli, 250, 8000);
    return clamped_size * @as(f64, @floatFromInt(clamped_milli)) / 1000.0;
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
    try std.testing.expect(first.glyph_raster_frame.stats.ready());
    try std.testing.expect(first.glyph_frame.stats.upload_count > 0);
    try std.testing.expectEqual(first.glyph_frame.stats.upload_count, first.glyph_raster_frame.stats.upload_count);

    // 같은 glyph를 다음 frame에서 다시 그리면 atlas slot을 재사용해야 한다.
    // persistent RendererState가 없으면 이 테스트는 매번 upload_count>0이 된다.
    core.clearDirty();
    try core.write("\rA");
    var second = try state.buildFrame(std.testing.allocator, core.snapshot(), glyph_layout.FakeFontBackend{});
    defer second.deinit(std.testing.allocator);

    try std.testing.expectEqual(@as(usize, 3), second.glyph_frame.stats.glyph_count);
    try std.testing.expectEqual(second.glyph_frame.stats.glyph_count, second.glyph_quad_frame.stats.glyph_count);
    try std.testing.expect(second.glyph_quad_frame.stats.ready());
    try std.testing.expect(second.glyph_raster_frame.stats.ready());
    try std.testing.expectEqual(@as(usize, 0), second.glyph_frame.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 0), second.glyph_raster_frame.stats.upload_count);
    try std.testing.expectEqual(@as(usize, 3), second.glyph_frame.stats.reused_count);
    try std.testing.expect(state.atlas.stats.hits > 0);
}

test "renderer state builds a frame from already-shaped product glyph runs" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 6, .rows = 2 });
    defer core.deinit();

    // CoreText 제품 shaper는 DrawList 전체를 보고 shaped record를 만든 뒤 renderer에
    // 넘긴다. 이 테스트는 그 다음 단계가 per-cell fake shaper 없이도 같은 RenderFrame
    // 준비 경로를 쓰고, surface metadata와 overlay를 잃지 않는지 고정한다.
    core.clearDirty();
    try core.write("A한");
    core.screen.cells[0].style.underline = true;

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    var list_owned_by_test = true;
    errdefer if (list_owned_by_test) list.deinit(std.testing.allocator);
    const expected_size = list.size;
    const expected_overlay_count = list.overlays.len;

    const records = [_]shaped_records.ShapedGlyphRecord{
        .{ .row = 0, .col = 0, .cell_width = 1, .codepoint = 'A', .font_id = 1, .glyph_id = 10, .style = list.cells[0].style },
        .{ .row = 0, .col = 1, .cell_width = 2, .codepoint = '한', .font_id = 2, .glyph_id = 20, .fallback = true },
        .{ .row = 0, .col = 3, .cell_width = 1, .codepoint = ' ', .font_id = 1, .glyph_id = 30, .drawable = false },
    };

    var shaped = try shaped_records.buildGlyphRunListFromShapedRecordsWithSurface(
        std.testing.allocator,
        &records,
        .{ .font_size_px = 15, .device_scale = 2 },
        .{
            .size = list.size,
            .cursor = list.cursor,
            .dirty = list.dirty,
            .overlays = list.overlays,
        },
    );
    defer shaped.deinit(std.testing.allocator);

    var state = RendererState.init(std.testing.allocator, .{});
    defer state.deinit();

    var frame = try state.buildFrameFromGlyphRunList(std.testing.allocator, list, shaped.runs);
    list_owned_by_test = false;
    defer frame.deinit(std.testing.allocator);

    try std.testing.expect(frame.glyphFrameConsistent());
    try std.testing.expect(frame.glyph_quad_frame.stats.ready());
    try std.testing.expect(frame.glyph_raster_frame.stats.ready());
    try std.testing.expectEqual(expected_size, frame.draw_list.size);
    try std.testing.expectEqual(@as(usize, 2), frame.glyph_frame.stats.glyph_count);
    try std.testing.expectEqual(@as(usize, 1), frame.glyph_frame.stats.fallback_count);
    try std.testing.expectEqual(@as(usize, 1), shaped.skipped_count);
    try std.testing.expectEqual(expected_overlay_count, frame.glyph_frame.overlays.len);
    try std.testing.expect(frame.glyph_frame.glyphs[0].run.style.underline);
    try std.testing.expect(frame.glyph_frame.glyphs[0].run.cache_key.style.bold == false);
    try std.testing.expectEqual(@as(u16, 15), frame.glyph_frame.glyphs[0].run.cache_key.font_size_px);
    try std.testing.expectEqual(@as(u16, 2), frame.glyph_frame.glyphs[0].run.cache_key.device_scale);
}

test "renderer state leaves draw list ownership with caller when shaped frame preparation fails" {
    var core = try terminal.TerminalCore.init(std.testing.allocator, .{ .cols = 1, .rows = 1 });
    defer core.deinit();

    // buildFrameFromGlyphRunList는 성공하면 DrawList를 RenderFrame으로 이동시키지만,
    // 실패하면 caller가 같은 DrawList artifact를 정리하거나 기록할 수 있어야 한다.
    // texture 크기 0은 quad 단계에서 deterministic하게 실패하므로 이 ownership 경계를
    // GPU 없이 검증하기 좋다.
    core.clearDirty();
    try core.write("A");

    var list = try draw_list.buildDrawList(std.testing.allocator, core.snapshot());
    defer list.deinit(std.testing.allocator);

    var glyphs = try glyph_layout.buildGlyphRunList(std.testing.allocator, list, .{}, glyph_layout.FakeFontBackend{});
    defer glyphs.deinit(std.testing.allocator);

    var state = RendererState.init(std.testing.allocator, .{
        .atlas = .{ .atlas_width_px = 0, .atlas_height_px = 0 },
    });
    defer state.deinit();

    try std.testing.expectError(
        error.InvalidAtlasTextureSize,
        state.buildFrameFromGlyphRunList(std.testing.allocator, list, glyphs),
    );
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

test "deviceScaleFromMilli rounds and clamps without overflow" {
    try std.testing.expectEqual(@as(u16, 1), deviceScaleFromMilli(1000));
    try std.testing.expectEqual(@as(u16, 2), deviceScaleFromMilli(2000));
    try std.testing.expectEqual(@as(u16, 2), deviceScaleFromMilli(1500));
    try std.testing.expectEqual(@as(u16, 1), deviceScaleFromMilli(0));
    try std.testing.expectEqual(@as(u16, 8), deviceScaleFromMilli(8000));
    // C ABI boundary value with no range guarantee must clamp, not overflow on +500.
    try std.testing.expectEqual(@as(u16, 8), deviceScaleFromMilli(std.math.maxInt(u32)));
}

test "deviceFontSizeFromMilli keeps fractional scale instead of rounding to an integer" {
    // 14pt at exact 2x -> 28 device px.
    try std.testing.expectEqual(@as(f64, 28.0), deviceFontSizeFromMilli(14.0, 2000));
    // 14pt at 1.5x -> 21 device px (NOT 14*2=28 from an integer round).
    try std.testing.expectEqual(@as(f64, 21.0), deviceFontSizeFromMilli(14.0, 1500));
    // 14pt at 2.5x -> 35 device px.
    try std.testing.expectEqual(@as(f64, 35.0), deviceFontSizeFromMilli(14.0, 2500));
    // Hostile huge scale clamps (8x) instead of overflowing.
    try std.testing.expectEqual(@as(f64, 14.0 * 8.0), deviceFontSizeFromMilli(14.0, std.math.maxInt(u32)));
}
