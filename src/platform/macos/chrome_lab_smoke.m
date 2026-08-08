#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/QuartzCore.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>
#include "maru_metal_renderer.h"

typedef struct {
    int32_t status;
    uint32_t renderer_created;
    uint32_t atlas_ready;
    uint32_t draw_submitted;
    uint32_t ppm_written;
    uint32_t png_written;
} MaruChromeLabSmokeResult;

/* The production renderer writes the PPM from its private BGRA readback texture. `sips` only
   repackages that deterministic RGB artifact for GitHub's inline PNG rendering; it never sees a
   window drawable or a separate fake render path. */
static BOOL maru_chrome_lab_convert_ppm_to_png(const char *ppm_path, const char *png_path) {
    if (ppm_path == NULL || png_path == NULL || ppm_path[0] == '\0' || png_path[0] == '\0') {
        return NO;
    }
    NSString *ppm = [NSString stringWithUTF8String:ppm_path];
    NSString *png = [NSString stringWithUTF8String:png_path];
    if (ppm == nil || png == nil) {
        return NO;
    }
    NSTask *task = [[NSTask alloc] init];
    task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/sips"];
    task.arguments = @[ @"-s", @"format", @"png", ppm, @"--out", png ];
    NSError *launch_error = nil;
    if (![task launchAndReturnError:&launch_error]) {
        return NO;
    }
    [task waitUntilExit];
    if (task.terminationStatus != 0) {
        return NO;
    }
    NSDictionary<NSFileAttributeKey, id> *attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:png error:nil];
    return [attributes fileSize] > 0;
}

void maru_macos_chrome_lab_smoke_render(
    uint32_t width_px,
    uint32_t height_px,
    const char *ppm_path,
    const char *png_path,
    uint16_t cols,
    uint16_t rows,
    uint32_t cell_width_px,
    uint32_t cell_height_px,
    const MaruAppHostMetalCell *cells,
    size_t cell_count,
    uint32_t atlas_width_px,
    uint32_t atlas_height_px,
    const MaruAppHostMetalRasterUpload *raster_uploads,
    size_t raster_upload_count,
    const uint8_t *raster_pixels,
    size_t raster_pixel_count,
    const MaruAppHostGpuQuad *quads,
    size_t quad_count,
    const MaruAppHostGpuShadow *shadows,
    size_t shadow_count,
    const MaruAppHostGpuGlyph *glyphs,
    size_t glyph_count,
    /* SB1 §5.2: 0이 아니면 사이드바 배경 strip을 그리고 그 바닥을 상태바 높이만큼 끊는다.
       기존 시나리오는 둘 다 0을 넘겨 캡처가 바이트 동일하다. */
    uint32_t sidebar_width_px,
    uint32_t sidebar_bg, /* Zig(토큰)가 준다 — `.m`은 색을 지어내지 않는다 */
    uint32_t status_bar_height_px,
    MaruChromeLabSmokeResult *result
) {
    if (result == NULL) {
        return;
    }
    memset(result, 0, sizeof(*result));
    result->status = -1;
    if (width_px == 0 || height_px == 0 || cols == 0 || rows == 0 ||
        cell_width_px == 0 || cell_height_px == 0 || atlas_width_px == 0 || atlas_height_px == 0 ||
        ppm_path == NULL || png_path == NULL) {
        return;
    }

    /* This bridge owns no NSWindow. The production screenshot pass renders to a private Metal
       texture, so a fixture-only CAMetalLayer supplies only device/pixel-format/drawable-size. */
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (device == nil) {
        return;
    }
    CAMetalLayer *terminal_layer = [CAMetalLayer layer];
    terminal_layer.device = device;
    terminal_layer.pixelFormat = MTLPixelFormatBGRA8Unorm;
    terminal_layer.drawableSize = CGSizeMake((CGFloat)width_px, (CGFloat)height_px);

    /* The renderer's public screenshot hook is intentionally process-scoped. Each Lab scenario
       runs in its own process, so these test-only values cannot leak into a normal app launch or
       overwrite a preceding scenario's capture. */
    if (setenv("MARU_SCREENSHOT", ppm_path, 1) != 0 ||
        setenv("MARU_SCREENSHOT_KEEP_PROCESS", "maru-test-only-v1", 1) != 0) {
        return;
    }

    MaruMetalRenderer *renderer = maru_metal_renderer_create(device, terminal_layer.pixelFormat);
    if (renderer == NULL) {
        return;
    }
    result->renderer_created = 1;
    if (!maru_metal_renderer_set_atlas(
            renderer,
            atlas_width_px,
            atlas_height_px,
            raster_uploads,
            raster_upload_count,
            raster_pixels,
            raster_pixel_count)) {
        maru_metal_renderer_destroy(renderer);
        return;
    }
    result->atlas_ready = 1;

    const BOOL drew = maru_metal_renderer_draw(
        renderer,
        terminal_layer,
        nil,
        cols,
        rows,
        cell_width_px,
        cell_height_px,
        cells,
        cell_count,
        sidebar_width_px, // terminal_origin_x_px — >0이어야 `.m`이 사이드바 strip을 그린다
        sidebar_bg, // 토큰에서 온 strip 색 — alpha 0이면 strip을 안 그린다(기존 시나리오)
        NULL,
        0,
        0,
        0,
        quads,
        quad_count,
        0, // modal_cells_start — lab은 모달을 안 띄운다
        shadows,
        shadow_count,
        NULL,
        0,
        NULL,
        0,
        NULL,
        0,
        NULL,
        0,
        0xFF141414u,
        0,
        1000,
        0,
        0,
        0,
        0,
        0,
        0,
        glyphs,
        glyph_count,
        status_bar_height_px, // SB1 §5.2: strip 바닥을 여기서 끊는다(0이면 창 바닥까지 = 기존 동작)
        0, 0, // 사이드바 셀 scissor — lab은 사이드바 셀을 안 그린다(bottom <= top → scissor 없음, v168)
        NULL, 0 // 셀 clip 표 — lab은 어떤 셀도 자르지 않는다(모든 clip_index=0, v169)
    );
    result->draw_submitted = drew ? 1 : 0;
    maru_metal_renderer_destroy(renderer);
    if (!drew) {
        return;
    }

    NSDictionary<NSFileAttributeKey, id> *ppm_attributes =
        [[NSFileManager defaultManager] attributesOfItemAtPath:[NSString stringWithUTF8String:ppm_path]
                                                        error:nil];
    result->ppm_written = [ppm_attributes fileSize] > 0 ? 1 : 0;
    if (result->ppm_written == 0 || !maru_chrome_lab_convert_ppm_to_png(ppm_path, png_path)) {
        return;
    }
    result->png_written = 1;
    result->status = 0;
}
