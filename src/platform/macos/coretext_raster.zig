const std = @import("std");
const maru = @import("maru");
const config = maru.config;
const renderer = maru.renderer;
const diag_gate = @import("diag.zig");

// 렌더링/메트릭 진단 logger. ad-hoc getenv+fprintf를 ObjC hot path에 두는 대신, slot 결정이
// 일어나는 Zig 렌더 계층에서 std.log scoped logger로 찍는다. MARU_DEBUG 게이트는 diag.zig가
// 단일 출처로 소유한다(env 이름·read-once 캐시 공유).
const diag = std.log.scoped(.font_metrics);

pub const NativeGlyphRasterResult = extern struct {
    status: c_int,
    non_clear_pixels: u32,
};

// rasterize_glyph bridge가 status 7로 닫는 경우는 CoreText가 glyph를 실제로 그렸지만
// non-clear pixel이 하나도 없는 zero-ink glyph다(coretext_smoke.m). 다른 non-zero status는
// glyph 자체를 만들 수 없었던 실패다.
const native_status_ok: c_int = 0;
const native_status_zero_ink: c_int = 7;

pub const RasterizeGlyphFn = *const fn (
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    requested_font_size: f64,
    font_postscript_name: [*]const u8,
    font_postscript_name_len: usize,
    codepoint: u32,
    glyph_id: u32,
    width_px: usize,
    height_px: usize,
    bytes_per_row: usize,
    pixels: [*]u8,
    pixel_capacity: usize,
    result: *NativeGlyphRasterResult,
) callconv(.c) void;

pub const CoreTextGlyphRasterizer = struct {
    pub const name = "coretext_glyph_rasterizer";

    appearance: config.ResolvedAppearance,
    font_registry: *const renderer.FontIdentityRegistry,
    rasterize_glyph: RasterizeGlyphFn,
    // backing(Retina) scale을 천분율로 보관한다(예: 1500 = 1.5×). glyph를 정수 배율로 반올림하지
    // 않고 분수 scale 그대로의 device 픽셀 크기로 그려, 분수 Retina에서도 slot을 또렷하게 채운다.
    scale_milli: u32 = 1000,

    pub fn rasterize(
        self: CoreTextGlyphRasterizer,
        request: renderer.GlyphRasterRequest,
    ) renderer.GlyphRasterError!renderer.GlyphRasterResult {
        // renderer의 GlyphRasterFrame은 native CoreText 타입을 알면 안 된다. 이 wrapper가
        // FontId -> PostScript name 조회와 C ABI 호출을 맡아, 이후 제품 renderer도 같은
        // GlyphRasterRequest 계약만 소비하게 만든다.
        if (request.pixels.len == 0) return error.RasterizerFailed;
        // 합성 대상(box·block·Powerline·Braille·Legacy Computing 모자이크/wedge/삼각형/대각선)은 폰트 글리프
        // 대신 코드포인트로 직접 그린다 — 슬롯이 cell 크기라 셀에 꽉 차 이음매 없이 타일링/연결(폰트 글리프는
        // 셀에 안 맞아 gap·흐림·끊김). 합성 dispatch 단일 출처 renderer.synthesizeGlyph를 폰트 경로 전에 호출.
        if (renderer.synthesizeGlyph(
            request.run.codepoint,
            request.slot.width_px,
            request.slot.height_px,
            request.bytes_per_row,
            request.pixels,
        )) |non_clear| {
            return .{ .non_clear_pixels = non_clear };
        }
        const font_identity = self.font_registry.get(request.run.font_id) orelse
            return error.RasterizerFailed;

        var native: NativeGlyphRasterResult = .{
            .status = -1,
            .non_clear_pixels = 0,
        };
        self.rasterize_glyph(
            self.appearance.font.family.ptr,
            self.appearance.font.family.len,
            // **규칙은 중립이 소유한다**(`renderer.glyphFontSizePt`) — Windows 가 같은 것을 쓴다.
            // 한 줄짜리라 각자 적으면 눈에 안 띄게 갈린다.
            renderer.deviceFontSizeFromMilli(
                renderer.glyphFontSizePt(self.appearance.font.size, request.run.cache_key.raster_font_size_milli),
                self.scale_milli,
            ),
            font_identity.postscript_name.ptr,
            font_identity.postscript_name.len,
            request.run.codepoint,
            request.run.glyph_id,
            request.slot.width_px,
            request.slot.height_px,
            request.bytes_per_row,
            request.pixels.ptr,
            request.pixels.len,
            &native,
        );

        // MARU_DEBUG 진단: cell 메트릭(cache_key)과 atlas slot 크기를 함께 찍는다. 둘이 어긋나면
        // (slot != cell × span) glyph가 cell보다 넓거나 좁은 slot에 그려져 간격이 틀어진다 —
        // "m i s e" 간격 버그를 이 비교로 잡았다.
        if (diag_gate.maruDebugEnabled()) {
            diag.info(
                "cp={d} scale_milli={d} span={d} cell={d}x{d} slot={d}x{d} ink_px={d} status={d}",
                .{
                    request.run.codepoint, self.scale_milli,
                    request.run.cache_key.cell_width, // span(EAW): wide=2. slot 폭이 cell×span이 아니면 잘림/간격 버그.
                    request.run.cache_key.cell_width_px,
                    request.run.cache_key.cell_height_px,
                    request.slot.width_px,
                    request.slot.height_px,
                    native.non_clear_pixels,
                    native.status,
                },
            );
        }

        // CoreText가 glyph를 그렸지만 잉크가 없는 경우(공백/combining mark/치환된 비가시
        // glyph)는 실패가 아니다. renderer 계약은 이것을 non_clear_pixels=0인 정상 결과로
        // 보고 GlyphRasterFrame의 zero_ink_uploads로 회계한다. 실패 매핑 정책을 가진 이
        // 제품 후보 경계가 native zero-ink status를 성공으로 닫아, zero-ink가 rasterizer
        // 실패로 잘못 집계되지 않게 한다.
        if (native.status == native_status_zero_ink) return .{ .non_clear_pixels = 0 };

        // 그 밖의 non-zero status는 CoreText가 glyph를 실제 bitmap으로 만들 수 없었던
        // 실패다. renderer는 한 glyph 실패를 frame abort가 아니라 skip으로 기록하므로
        // 여기서는 공통 RasterizerFailed로만 되돌린다.
        if (native.status != native_status_ok) return error.RasterizerFailed;

        return .{ .non_clear_pixels = native.non_clear_pixels };
    }
};

const TestBridgeCapture = struct {
    call_count: usize = 0,
    font_postscript_name: []const u8 = "",
    requested_font_size: f64 = 0,
    glyph_id: u32 = 0,
    width_px: usize = 0,
    height_px: usize = 0,
    bytes_per_row: usize = 0,
    pixel_capacity: usize = 0,
};

var test_bridge_capture: TestBridgeCapture = .{};
var test_bridge_status: c_int = 0;
var test_bridge_non_clear_pixels: u32 = 7;

fn resetTestBridge(status: c_int, non_clear_pixels: u32) void {
    test_bridge_capture = .{};
    test_bridge_status = status;
    test_bridge_non_clear_pixels = non_clear_pixels;
}

fn captureRasterizeGlyph(
    _: [*]const u8,
    _: usize,
    requested_font_size: f64,
    font_postscript_name: [*]const u8,
    font_postscript_name_len: usize,
    _: u32,
    glyph_id: u32,
    width_px: usize,
    height_px: usize,
    bytes_per_row: usize,
    pixels: [*]u8,
    pixel_capacity: usize,
    result: *NativeGlyphRasterResult,
) callconv(.c) void {
    test_bridge_capture = .{
        .call_count = test_bridge_capture.call_count + 1,
        .font_postscript_name = font_postscript_name[0..font_postscript_name_len],
        .requested_font_size = requested_font_size,
        .glyph_id = glyph_id,
        .width_px = width_px,
        .height_px = height_px,
        .bytes_per_row = bytes_per_row,
        .pixel_capacity = pixel_capacity,
    };
    if (pixel_capacity > 0) pixels[0] = 0xff;
    result.* = .{
        .status = test_bridge_status,
        .non_clear_pixels = test_bridge_non_clear_pixels,
    };
}

fn testRun(font_id: renderer.FontId, glyph_id: renderer.GlyphId) renderer.GlyphRun {
    const key = renderer.GlyphCacheKey{
        .font_id = font_id,
        .glyph_id = glyph_id,
        .font_size_px = 14,
        .device_scale = 1,
    };
    return .{
        .row = 0,
        .col = 0,
        .cell_width = 1,
        .codepoint = 'A',
        .font_id = font_id,
        .glyph_id = glyph_id,
        .cache_key = key,
    };
}

fn testSlot(key: renderer.GlyphCacheKey) renderer.AtlasSlot {
    return .{
        .id = 1,
        .key = key,
        .x_px = 0,
        .y_px = 0,
        .width_px = 2,
        .height_px = 2,
        .upload_bytes = 16,
        .generation = 0,
    };
}

test "CoreText rasterizer calls native bridge with registry font identity" {
    // 이 테스트는 실제 CoreText를 부르지 않고 제품 후보 경계의 핵심 계약만 고정한다.
    // glyph_id는 font face 안에서만 의미가 있으므로, FontId로 저장한 PostScript name이
    // native bridge까지 그대로 넘어가야 wrong-glyph를 막을 수 있다.
    resetTestBridge(0, 3);
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const font_id = try registry.intern(.{ .postscript_name = "Menlo-Regular" });
    const run = testRun(font_id, 42);
    const slot = testSlot(run.cache_key);
    var pixels = [_]u8{0} ** 16;

    const rasterizer = CoreTextGlyphRasterizer{
        .appearance = try config.resolveAppearance(.{}),
        .font_registry = &registry,
        .rasterize_glyph = captureRasterizeGlyph,
    };
    const result = try rasterizer.rasterize(.{
        .run = run,
        .slot = slot,
        .pixels = &pixels,
        .bytes_per_row = 8,
    });

    try std.testing.expectEqual(@as(usize, 1), test_bridge_capture.call_count);
    try std.testing.expectEqualStrings("Menlo-Regular", test_bridge_capture.font_postscript_name);
    try std.testing.expectEqual(@as(f64, 14), test_bridge_capture.requested_font_size);
    try std.testing.expectEqual(@as(u32, 42), test_bridge_capture.glyph_id);
    try std.testing.expectEqual(@as(usize, 2), test_bridge_capture.width_px);
    try std.testing.expectEqual(@as(usize, 2), test_bridge_capture.height_px);
    try std.testing.expectEqual(@as(usize, 8), test_bridge_capture.bytes_per_row);
    try std.testing.expectEqual(@as(usize, 16), test_bridge_capture.pixel_capacity);
    try std.testing.expectEqual(@as(usize, 3), result.non_clear_pixels);
    try std.testing.expectEqual(@as(u8, 0xff), pixels[0]);
}

test "CoreText rasterizer honors a rich text role size override" {
    resetTestBridge(0, 1);
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const font_id = try registry.intern(.{ .postscript_name = "Menlo-Regular" });
    var run = testRun(font_id, 42);
    run.cache_key.raster_font_size_milli = 18_000;
    const slot = testSlot(run.cache_key);
    var pixels = [_]u8{0} ** 16;
    const rasterizer = CoreTextGlyphRasterizer{
        .appearance = try config.resolveAppearance(.{}),
        .font_registry = &registry,
        .rasterize_glyph = captureRasterizeGlyph,
        .scale_milli = 2000,
    };
    _ = try rasterizer.rasterize(.{ .run = run, .slot = slot, .pixels = &pixels, .bytes_per_row = 8 });
    try std.testing.expectEqual(@as(f64, 36), test_bridge_capture.requested_font_size);
}

test "CoreText rasterizer fails closed when font identity is missing" {
    // registry miss는 "그릴 수 없는 glyph"가 아니라 shaper/rasterizer 배선 오류다. 그래도
    // renderer 계약상 한 glyph 실패는 RasterizerFailed로 닫아 GlyphRasterFrame이 skip으로
    // 기록하게 한다. bridge가 호출되지 않는지도 함께 고정한다.
    resetTestBridge(0, 3);
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const run = testRun(99, 42);
    const slot = testSlot(run.cache_key);
    var pixels = [_]u8{0} ** 16;

    const rasterizer = CoreTextGlyphRasterizer{
        .appearance = try config.resolveAppearance(.{}),
        .font_registry = &registry,
        .rasterize_glyph = captureRasterizeGlyph,
    };

    try std.testing.expectError(error.RasterizerFailed, rasterizer.rasterize(.{
        .run = run,
        .slot = slot,
        .pixels = &pixels,
        .bytes_per_row = 8,
    }));
    try std.testing.expectEqual(@as(usize, 0), test_bridge_capture.call_count);
}

test "NativeGlyphRasterResult matches the native C ABI size" {
    // coretext_smoke.m의 MaruCoreTextGlyphRasterResult와 layout이 어긋나면 status/pixel을
    // 엉뚱한 offset에서 읽어 모든 raster 결과가 조용히 깨진다. DrawList ABI 구조체처럼
    // 크기를 컴파일 타임 계약으로 고정해 드리프트를 빌드에서 잡는다.
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(NativeGlyphRasterResult));
}

test "CoreText rasterizer maps native zero-ink to a successful zero-ink upload" {
    // drawable glyph가 잉크 없이 그려지는 경우(combining mark, 치환된 비가시 glyph)는
    // renderer 계약상 실패가 아니라 non_clear_pixels=0인 정상 결과다. 경계가 native
    // status 7을 RasterizerFailed로 닫으면 zero_ink_uploads가 rasterizer 실패로 잘못
    // 집계되어 GlyphRasterFrame.ready()가 거짓이 된다.
    resetTestBridge(7, 0);
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const font_id = try registry.intern(.{ .postscript_name = "Menlo-Regular" });
    const run = testRun(font_id, 42);
    const slot = testSlot(run.cache_key);
    var pixels = [_]u8{0} ** 16;

    const rasterizer = CoreTextGlyphRasterizer{
        .appearance = try config.resolveAppearance(.{}),
        .font_registry = &registry,
        .rasterize_glyph = captureRasterizeGlyph,
    };
    const result = try rasterizer.rasterize(.{
        .run = run,
        .slot = slot,
        .pixels = &pixels,
        .bytes_per_row = 8,
    });

    try std.testing.expectEqual(@as(usize, 0), result.non_clear_pixels);
    try std.testing.expectEqual(@as(usize, 1), test_bridge_capture.call_count);
}

test "CoreText rasterizer maps native failure to renderer raster skip error" {
    // native status code를 renderer 밖으로 새게 하면 backend마다 실패 분류가 달라진다.
    // 지금 경계는 native 세부 원인을 smoke summary에 남기기보다, renderer가 이해하는
    // RasterizerFailed 하나로 닫아 공통 skip accounting을 유지한다.
    resetTestBridge(8, 0);
    var registry = renderer.FontIdentityRegistry.init(std.testing.allocator);
    defer registry.deinit();
    const font_id = try registry.intern(.{ .postscript_name = "Menlo-Regular" });
    const run = testRun(font_id, 42);
    const slot = testSlot(run.cache_key);
    var pixels = [_]u8{0} ** 16;

    const rasterizer = CoreTextGlyphRasterizer{
        .appearance = try config.resolveAppearance(.{}),
        .font_registry = &registry,
        .rasterize_glyph = captureRasterizeGlyph,
    };

    try std.testing.expectError(error.RasterizerFailed, rasterizer.rasterize(.{
        .run = run,
        .slot = slot,
        .pixels = &pixels,
        .bytes_per_row = 8,
    }));
    try std.testing.expectEqual(@as(usize, 1), test_bridge_capture.call_count);
}
