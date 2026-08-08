//! Chrome Lab의 실제 macOS Metal capture bridge ABI.
//!
//! Zig 쪽은 Lab tree/lowering과 artifact oracle만 소유한다. 이 작은 ABI leaf만 Cocoa/Metal
//! 객체를 만들고, `maru_metal_renderer_draw`라는 제품 renderer로 전달한다.

const maru = @import("maru");
const renderer = maru.renderer;

pub const NativeResult = extern struct {
    status: c_int,
    renderer_created: u32,
    atlas_ready: u32,
    draw_submitted: u32,
    ppm_written: u32,
    png_written: u32,
};

pub extern fn maru_macos_chrome_lab_smoke_render(
    width_px: u32,
    height_px: u32,
    ppm_path: [*:0]const u8,
    png_path: [*:0]const u8,
    cols: u16,
    rows: u16,
    cell_width_px: u32,
    cell_height_px: u32,
    cells: ?[*]const renderer.metal_frame.NativeMetalCell,
    cell_count: usize,
    atlas_width_px: u32,
    atlas_height_px: u32,
    raster_uploads: ?[*]const renderer.metal_frame.NativeMetalRasterUpload,
    raster_upload_count: usize,
    raster_pixels: ?[*]const u8,
    raster_pixel_count: usize,
    quads: ?[*]const renderer.metal_frame.GpuQuad,
    quad_count: usize,
    shadows: ?[*]const renderer.metal_frame.GpuShadow,
    shadow_count: usize,
    glyphs: ?[*]const renderer.metal_frame.GpuGlyph,
    glyph_count: usize,
    /// SB1 §5.2: 사이드바 배경 strip을 그리게 하는 폭(= terminal origin_x). 0이면 strip 없음(기존 시나리오).
    sidebar_width_px: u32,
    /// SB1 §5.2: 그 strip의 바닥을 끊을 상태바 높이. **이 둘이 있어야 strip 클리핑이 Lab에서 그려진다** —
    /// 그전까지는 `.m`이 두 값을 0으로 박아 두어 §5.2가 자동 가드 없이 남아 있었다.
    status_bar_height_px: u32,
    result: *NativeResult,
) void;
