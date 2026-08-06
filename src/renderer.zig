pub const glyph_pixels = @import("renderer/glyph_pixels.zig"); // 합성 글리프 공유 RGBA8 픽셀 프리미티브(슬롯 검증·clear·setPixel·fillRect·대각선). 중립.
pub const block_glyph = @import("renderer/block_glyph.zig"); // Block Elements(U+2580~259F) 합성 — 폰트 대신 셀에 사각형 coverage(이음매 없는 타일링). 중립.
pub const box_glyph = @import("renderer/box_glyph.zig"); // Box-drawing(U+2500~257F 전체) 합성 — 폰트 대신 셀에 선/면(이음매 없는 연결). 중립.
pub const powerline_glyph = @import("renderer/powerline_glyph.zig"); // Powerline(U+E0B0~E0BF) 합성 — 삼각형·반원 separator를 셀에 꽉 차게. 중립.
pub const braille_glyph = @import("renderer/braille_glyph.zig"); // Braille(U+2800~28FF) 합성 — 2열×4행 8점 비트마스크를 셀 격자에 스냅. 중립.
pub const legacy_mosaic_glyph = @import("renderer/legacy_mosaic_glyph.zig"); // Legacy Computing 블록 모자이크(sextant U+1FB00~·octant U+1CD00~) 합성. 중립.
pub const legacy_wedge_glyph = @import("renderer/legacy_wedge_glyph.zig"); // Legacy Computing edge wedge 삼각형(U+1FB68~1FB6F·bowtie 1FB9A/9B) 합성. 중립.
pub const legacy_smooth_glyph = @import("renderer/legacy_smooth_glyph.zig"); // Legacy Computing smooth mosaic(U+1FB3C~1FB67 대각 폴리곤 44개) 합성. 중립.
pub const legacy_diagonal_glyph = @import("renderer/legacy_diagonal_glyph.zig"); // Legacy Computing 대각선 stroke(U+1FBA0~1FBAE·1FBD0~1FBDF) 합성. 중립.
pub const icon_glyph = @import("renderer/icon_glyph.zig"); // maru chrome 아이콘(빌드타임 SVG→coverage, Plane 15 PUA 0xF0000~) 합성·다운스케일. 중립.
pub const draw_list = @import("renderer/draw_list.zig");
pub const frame_probe = @import("renderer/frame_probe.zig");
pub const font_identity = @import("renderer/font_identity.zig");
pub const glyph_atlas = @import("renderer/glyph_atlas.zig");
pub const glyph_frame = @import("renderer/glyph_frame.zig");
pub const glyph_layout = @import("renderer/glyph_layout.zig");
pub const glyph_quads = @import("renderer/glyph_quads.zig");
pub const glyph_raster = @import("renderer/glyph_raster.zig");
pub const metal_frame = @import("renderer/metal_frame.zig"); // 중립 frame DTO 투영(platform/macos→renderer 이주, §8). 이름만 "Metal" — OS 의존 없음(NativeMetalCell·MetalFrame extern). 백엔드(Metal/WebGPU)가 공유.
pub const shaped_records = @import("renderer/shaped_records.zig");
pub const state = @import("renderer/state.zig");
pub const types = @import("renderer/types.zig");

pub const AtlasTextureSize = glyph_quads.AtlasTextureSize;
pub const AtlasInvalidation = glyph_atlas.AtlasInvalidation;
pub const AtlasInvalidationReason = glyph_atlas.AtlasInvalidationReason;
pub const AtlasLookup = glyph_atlas.AtlasLookup;
pub const AtlasSlot = glyph_atlas.AtlasSlot;
pub const AtlasSlotId = glyph_atlas.AtlasSlotId;
pub const AtlasStats = glyph_atlas.AtlasStats;
pub const Backend = types.Backend;
pub const ColorGlyphKind = glyph_layout.ColorGlyphKind;
pub const CursorOverlay = draw_list.CursorOverlay;
pub const DrawCell = draw_list.DrawCell;
pub const DrawList = draw_list.DrawList;
pub const DrawOverlay = draw_list.DrawOverlay;
pub const FakeFontBackend = glyph_layout.FakeFontBackend;
pub const FakeGlyphRasterizer = glyph_raster.FakeGlyphRasterizer;
pub const GlyphAtlas = glyph_atlas.GlyphAtlas;
pub const GlyphAtlasConfig = glyph_atlas.GlyphAtlasConfig;
pub const FontIdentity = font_identity.FontIdentity;
pub const FontIdentityError = font_identity.FontIdentityError;
pub const FontIdentityKey = font_identity.FontIdentityKey;
pub const FontIdentityRegistry = font_identity.FontIdentityRegistry;
pub const FontId = glyph_layout.FontId;
pub const GlyphFrame = glyph_frame.GlyphFrame;
pub const GlyphQuadError = glyph_quads.GlyphQuadError;
pub const GlyphFrameStats = glyph_frame.GlyphFrameStats;
pub const GlyphQuad = glyph_quads.GlyphQuad;
pub const GlyphQuadFrame = glyph_quads.GlyphQuadFrame;
pub const GlyphQuadFrameStats = glyph_quads.GlyphQuadFrameStats;
pub const GlyphUvRect = glyph_quads.GlyphUvRect;
pub const GlyphRasterError = glyph_raster.GlyphRasterError;
pub const GlyphRasterFrame = glyph_raster.GlyphRasterFrame;
pub const GlyphRasterFrameConfig = glyph_raster.GlyphRasterFrameConfig;
pub const GlyphRasterFrameStats = glyph_raster.GlyphRasterFrameStats;
pub const GlyphRasterRequest = glyph_raster.GlyphRasterRequest;
pub const GlyphRasterResult = glyph_raster.GlyphRasterResult;
pub const GlyphRasterSkip = glyph_raster.GlyphRasterSkip;
pub const GlyphRasterSkipReason = glyph_raster.GlyphRasterSkipReason;
pub const GlyphRasterUpload = glyph_raster.GlyphRasterUpload;
pub const GlyphCacheKey = glyph_layout.GlyphCacheKey;
pub const GlyphId = glyph_layout.GlyphId;
pub const GlyphRun = glyph_layout.GlyphRun;
pub const GlyphRunList = glyph_layout.GlyphRunList;
pub const GlyphUpload = glyph_frame.GlyphUpload;
pub const RasterStyleFlags = glyph_layout.RasterStyleFlags;
pub const RenderFrame = types.RenderFrame;
pub const RenderFrameStats = frame_probe.RenderFrameStats;
pub const RendererState = state.RendererState;
pub const RendererStateConfig = state.RendererStateConfig;
pub const renderFrameStats = frame_probe.renderFrameStats;
pub const writeRenderFrameStats = frame_probe.writeRenderFrameStats;
pub const ShapeResult = glyph_layout.ShapeResult;
pub const ShapedGlyphRecord = shaped_records.ShapedGlyphRecord;
pub const ShapedGlyphRunList = shaped_records.ShapedGlyphRunList;
pub const ShapedGlyphSurface = shaped_records.ShapedGlyphSurface;
pub const TextLayoutConfig = glyph_layout.TextLayoutConfig;
pub const LineOverlay = draw_list.LineOverlay;
pub const LineKind = draw_list.LineKind;
pub const buildDrawList = draw_list.buildDrawList;
pub const buildDrawListWithUnfocused = draw_list.buildDrawListWithUnfocused; // 포커스 잃은 커서(hollow/hidden) 반영(F1-4b-2)
pub const CursorUnfocused = draw_list.CursorUnfocused;
pub const buildGlyphQuadFrame = glyph_quads.buildGlyphQuadFrame;
pub const buildGlyphRasterFrame = glyph_raster.buildGlyphRasterFrame;
pub const buildGlyphRunList = glyph_layout.buildGlyphRunList;
pub const buildGlyphRunListFromShapedRecords = shaped_records.buildGlyphRunListFromShapedRecords;
pub const buildGlyphRunListFromShapedRecordsWithSurface = shaped_records.buildGlyphRunListFromShapedRecordsWithSurface;
pub const initialBackendForMacOS = types.initialBackendForMacOS;
pub const prepareGlyphFrame = glyph_frame.prepareGlyphFrame;
pub const textConfigFromFontSize = state.textConfigFromFontSize;
pub const deviceScaleFromMilli = state.deviceScaleFromMilli;
pub const deviceFontSizeFromMilli = state.deviceFontSizeFromMilli;
pub const uvRectForSlot = glyph_quads.uvRectForSlot;

/// cp가 합성 글리프(폰트 대신 rasterizer가 코드포인트로 직접 그리는)인지 — 모든 합성 모듈 술어의 합집합.
/// **합성 여부의 단일 Zig 출처**: 네이티브 셰이퍼의 drawable 판정과 cache_key glyph_id=0 정규화가 이걸 쓴다.
/// platform/macos/coretext_smoke.m의 `maru_is_synthesized_glyph`(C 게이트)는 이 집합을 미러해야 한다(언어가
/// 달라 컴파일 차원 공유는 못 하므로 같은 집합을 유지 — 어긋나면 그 코드포인트가 blank로 빠진다). 아이콘은
/// **등록된 것만**(`isRegisteredIcon`, 범위 전체 `isIcon` 아님): Nerd Fonts v3가 MDI를 Plane-15 PUA(U+F0001~)로
/// 옮겨 겹치므로, 미등록 in-range를 합성으로 가로채면 그 글리프가 blank가 됐다 → 미등록은 폰트로 폴백한다.
/// C 게이트는 같은 등록 집합을 생성 헤더(`icon_codepoints.h` — svg_to_coverage.py)에서 받아 항상 일치한다.
pub fn isSynthesizedCodepoint(cp: u32) bool {
    return block_glyph.isBlockElement(cp) or
        box_glyph.isBoxDrawing(cp) or
        powerline_glyph.isPowerline(cp) or
        braille_glyph.isBraille(cp) or
        legacy_mosaic_glyph.isLegacyMosaic(cp) or
        legacy_wedge_glyph.isLegacyWedge(cp) or
        legacy_wedge_glyph.isCornerTriangle(cp) or
        legacy_smooth_glyph.isSmoothMosaic(cp) or
        legacy_diagonal_glyph.isLegacyDiagonal(cp) or
        icon_glyph.isRegisteredIcon(cp);
}

/// cp가 합성 대상이면 슬롯에 coverage를 채우고 **non_clear 픽셀 수**를, 아니면 null을 돌려준다 — 합성 dispatch의
/// **단일 출처**. rasterizer는 폰트 경로 전에 이걸 한 번 호출한다(`synthesizeGlyph(...) orelse <폰트 경로>`).
/// 각 모듈 fillCoverage는 시그니처가 같아 분기만 다르다. 슬롯이 cell 크기라 합성은 셀에 꽉 차 이음매 없이
/// 타일링/연결된다(폰트 글리프는 셀에 안 맞아 gap·흐림·끊김). isSynthesizedCodepoint와 같은 모듈 집합을 덮는다.
pub fn synthesizeGlyph(cp: u32, width_px: u32, height_px: u32, bytes_per_row: usize, pixels: []u8) ?u32 {
    if (block_glyph.isBlockElement(cp)) // U+2580~259F eighth/half/full/quadrant·shade
        return block_glyph.fillCoverage(cp, width_px, height_px, bytes_per_row, pixels);
    if (box_glyph.isBoxDrawing(cp)) // U+2500~257F 직선·모서리·T·사거리·둥근·이중선·대각선·반선
        return box_glyph.fillCoverage(cp, width_px, height_px, bytes_per_row, pixels);
    if (powerline_glyph.isPowerline(cp)) // U+E0B0~E0BF 삼각형·반원·thin + extra 사다리꼴 E0D2/E0D4
        return powerline_glyph.fillCoverage(cp, width_px, height_px, bytes_per_row, pixels);
    if (braille_glyph.isBraille(cp)) // U+2800~28FF 2×4 점 비트마스크
        return braille_glyph.fillCoverage(cp, width_px, height_px, bytes_per_row, pixels);
    if (legacy_mosaic_glyph.isLegacyMosaic(cp)) // sextant 2×3·octant 2×4 블록 모자이크
        return legacy_mosaic_glyph.fillCoverage(cp, width_px, height_px, bytes_per_row, pixels);
    if (legacy_wedge_glyph.isLegacyWedge(cp) or legacy_wedge_glyph.isCornerTriangle(cp)) // edge wedge·bowtie·corner 삼각형
        return legacy_wedge_glyph.fillCoverage(cp, width_px, height_px, bytes_per_row, pixels);
    if (legacy_smooth_glyph.isSmoothMosaic(cp)) // U+1FB3C~1FB67 대각 폴리곤
        return legacy_smooth_glyph.fillCoverage(cp, width_px, height_px, bytes_per_row, pixels);
    if (legacy_diagonal_glyph.isLegacyDiagonal(cp)) // 대각선 stroke·hatch
        return legacy_diagonal_glyph.fillCoverage(cp, width_px, height_px, bytes_per_row, pixels);
    // maru chrome 아이콘(등록된 cp만 — 미등록 in-range는 폰트 폴백, Nerd Fonts v3 MDI 겹침). fillCoverage가 미등록이면
    // null을 돌려줘 이 함수의 "합성 아님" 반환과 일치한다 — coverageFor를 한 번만 스캔(isRegisteredIcon 사전 게이트 제거).
    return icon_glyph.fillCoverage(cp, width_px, height_px, bytes_per_row, pixels);
}

test "isSynthesizedCodepoint: 각 합성 범위 대표 + 비합성 대조" {
    const std = @import("std");
    const icons = @import("icons.zig");
    // 각 모듈 범위에서 하나씩(C 게이트 maru_is_synthesized_glyph와 같은 집합이어야 한다).
    for ([_]u32{
        0x2588, // block █
        0x2592, // shade ▒
        0x2500, // box ─
        0xE0B0, // powerline
        0x2800, 0x28FF, // braille
        0x1FB00, 0x1FB3B, // sextant
        0x1CD00, 0x1CDE5, // octant
        0x1FB3C, 0x1FB67, // smooth mosaic
        0x1FB68, 0x1FB6F, 0x1FB9A, 0x1FB9B, // wedge·bowtie
        0x25E2, 0x1FB9C, // corner 삼각형·음영
        0x1FB98,                      0x1FBA0,                       0x1FBAE,                  0x1FBD0, 0x1FBDF, // 대각 hatch·stroke
        // 등록 maru 아이콘(git_branch·octocat·folder) — 합성. 이름 registry(src/icons.zig)에서 가져와
        // 자산이 재배치돼도 이 회귀 테스트가 실제 등록 cp를 본다.
        icons.codepoint(.git_branch), icons.codepoint(.mark_github), icons.codepoint(.folder),
    }) |cp| {
        try std.testing.expect(isSynthesizedCodepoint(cp));
    }
    // 비합성 대조(폰트 폴백): 일반 글자·범위 사이 갭. (0x257F=box·0x1FBA0=diagonal은 합성이라 제외)
    for ([_]u32{
        'A',
        0x24FF, // box 직전
        0x25A0, // block(…259F) 직후 ■
        0x27FF, // braille 직전
        0x2A00, // braille 직후
        0x1CCFF, // octant 직전
        0x1FB96, // wedge(…6F)와 hatch(98) 사이 갭
        0x1FBE0, // diagonal cell(…DF) 직후
        // **미등록** maru PUA 범위(Nerd Fonts v3 MDI 등) — 합성 아님(폰트로 폴백). 등록-전용 게이트 회귀.
        0xF0050,
        0xF00FF,
    }) |cp| {
        try std.testing.expect(!isSynthesizedCodepoint(cp));
    }
}

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in renderer/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
