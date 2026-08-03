//! macOS CoreText smoke native bridge의 단일 extern 선언 출처.
//!
//! `maru_macos_coretext_shape_draw_list`와 `maru_macos_coretext_smoke_rasterize_glyph`는
//! CoreText smoke와 Metal smoke 실행 파일이 모두 호출한다. 두 실행 파일이 같은 ABI
//! 시그니처를 각자 손으로 다시 선언하면, 한쪽만 파라미터를 바꿔도 컴파일은 통과하고
//! native 호출이 인자 밀림으로 조용히 깨진다. 그래서 두 bridge 시그니처를 여기 한 곳에서만
//! 선언하고, 양쪽 smoke가 이 선언을 공유한다.
//!
//! 선언만 두고 호출하지 않는 단위 테스트 빌드(`test-macos-*-smoke`)는 `.m`을 링크하지
//! 않는다. extern 선언은 참조되지 않으면 링크 의존성을 만들지 않으므로, 이 모듈을 import해도
//! native 없는 계약 테스트는 그대로 빌드된다.

const std = @import("std");
const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");

/// 모노스페이스 cell 메트릭(device 픽셀). native maru_macos_coretext_font_cell_metrics와 layout
/// 일치. status 0이면 성공.
pub const CellMetricsResult = extern struct {
    status: c_int = -1,
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    ascent_px: u32 = 0,
    descent_px: u32 = 0,
};

pub extern fn maru_macos_coretext_font_cell_metrics(
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    font_size_px: f64,
    result: *CellMetricsResult,
) void;

/// Chrome Lab 전용 번들 TTF 등록·검증 seam. 일반 앱은 Info.plist의
/// ATSApplicationFontsPath가 등록을 소유하므로 이 함수는 test executable에서만 호출한다.
/// 0=해당 asset을 등록한 뒤 requested family를 CoreText가 실제로 선택할 수 있음.
/// 성공하면 `postscript_name_out`에 실제 선택된 face의 PostScript 이름을 NUL 종료로 돌려준다.
pub extern fn maru_macos_coretext_lab_register_font(
    font_path: [*]const u8,
    font_path_len: usize,
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    postscript_name_out: [*]u8,
    postscript_name_out_len: usize,
) c_int;

pub extern fn maru_macos_coretext_shape_draw_list(
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    requested_font_size: f64,
    fallback_families: [*]const u8, // 폴백 폰트 CSV(F1-2 — ObjC가 cascade list로 박음)
    fallback_families_len: usize,
    bold_family: [*]const u8, // bold 글자용 폰트 패밀리(F2-3 — 빈 len 0=주 family bold variant)
    bold_family_len: usize,
    italic_family: [*]const u8, // italic 글자용 폰트 패밀리(F2-3)
    italic_family_len: usize,
    cells: [*]const coretext_shaper.NativeDrawCell,
    cell_count: usize,
    grapheme_pool: [*]const u32, // grapheme cluster 본체 풀(NativeDrawCell.grapheme_offset/count가 가리킴)
    grapheme_pool_len: usize,
    result: *coretext_shaper.NativeDrawListShapeResult,
    glyph_records: [*]coretext_shaper.NativeDrawGlyphRecord,
    glyph_record_capacity: usize,
) void;

/// Rich Chrome 한 줄의 system UI CoreText shape 결과. 이 ABI는 CTLine/CTRun을 platform
/// 경계 안에 가두고, Zig에는 glyph id·selected face·final advance만 전달한다.
pub const NativeChromeTextShapeResult = extern struct {
    status: c_int = -1,
    primary_font_found: u32 = 0,
    glyph_record_count: u32 = 0,
    glyph_record_overflow: u32 = 0,
};

pub const NativeChromeTextGlyphRecord = extern struct {
    glyph_id: u32 = 0,
    codepoint: u32 = 0,
    fallback: u32 = 0,
    color_glyph_kind: u32 = 0,
    x_px: f32 = 0,
    advance_px: f32 = 0,
    font_name: [128]u8 = [_]u8{0} ** 128,
};

pub extern fn maru_macos_coretext_shape_chrome_text(
    utf8: [*]const u8,
    utf8_len: usize,
    font_size_px: f64,
    weight: u32,
    max_width_px: f64,
    result: *NativeChromeTextShapeResult,
    glyph_records: [*]NativeChromeTextGlyphRecord,
    glyph_record_capacity: usize,
) void;

pub extern fn maru_macos_coretext_smoke_rasterize_glyph(
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
    result: *coretext_raster.NativeGlyphRasterResult,
) void;

test "CellMetricsResult matches the native C ABI layout" {
    // coretext_smoke.m의 MaruCoreTextCellMetrics(int32 status + uint32 4개 = 20B)와 layout이
    // 어긋나면 app session(app_session.zig)이 cell 메트릭을 엉뚱한 offset에서 읽어 atlas
    // slot과 화면 cell 크기가 조용히 깨진다. native struct가 단일 출처이고, 한쪽을 바꾸면 다른
    // 쪽도 함께 바꿔야 한다 — NativeGlyphRasterResult ABI 가드(coretext_raster.zig)처럼 크기를
    // 컴파일 타임 계약으로 고정해 드리프트를 빌드에서 잡는다.
    try std.testing.expectEqual(@as(usize, 20), @sizeOf(CellMetricsResult));
    // status(int32)와 width/height/ascent/descent(uint32)는 모두 4바이트라 @sizeOf만으로는 필드
    // reorder(예: status↔cell_width_px — 에러코드와 픽셀 폭이 뒤바뀌어도 크기는 같다)를 못 잡는다.
    // #540의 CommandEntry @offsetOf 가드와 동형으로 각 필드 offset도 native struct 순서에 고정한다.
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(CellMetricsResult, "status"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(CellMetricsResult, "cell_width_px"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(CellMetricsResult, "cell_height_px"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(CellMetricsResult, "ascent_px"));
    try std.testing.expectEqual(@as(usize, 16), @offsetOf(CellMetricsResult, "descent_px"));
}
