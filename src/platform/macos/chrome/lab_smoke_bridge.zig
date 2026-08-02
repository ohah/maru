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
    quads: ?[*]const renderer.metal_frame.GpuQuad,
    quad_count: usize,
    shadows: ?[*]const renderer.metal_frame.GpuShadow,
    shadow_count: usize,
    result: *NativeResult,
) void;
