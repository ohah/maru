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

pub extern fn maru_macos_coretext_shape_draw_list(
    requested_font_family: [*]const u8,
    requested_font_family_len: usize,
    requested_font_size: f64,
    cells: [*]const coretext_shaper.NativeDrawCell,
    cell_count: usize,
    result: *coretext_shaper.NativeDrawListShapeResult,
    glyph_records: [*]coretext_shaper.NativeDrawGlyphRecord,
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
