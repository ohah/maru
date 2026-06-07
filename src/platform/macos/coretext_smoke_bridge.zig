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

const coretext_raster = @import("coretext_raster.zig");
const coretext_shaper = @import("coretext_shaper.zig");

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
