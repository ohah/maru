#ifndef MARU_PLATFORM_MACOS_METAL_RENDERER_H
#define MARU_PLATFORM_MACOS_METAL_RENDERER_H

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdbool.h>
#include <stddef.h>
#include "app_host_abi.h"

/* 제품 Metal terminal renderer. visible Metal smoke와 달리 readback/screenshot/sample 같은
   검증 계측이 없는 lean 런타임 경로다(smoke 저자가 주석에서 예고한 "제품 renderer"). cell/
   upload 입력은 dev session의 metal-frame ABI(MaruAppHostDevMetalCell/RasterUpload)를 그대로
   받아, Swift Metal view가 maru_macos_app_dev_session_metal_frame 결과를 변환 없이 넘긴다.
   GPU 셰이더는 maru_metal_shader.h로 smoke와 공유한다. */
typedef struct MaruMetalRenderer MaruMetalRenderer;

/* device + drawable pixel format으로 pipeline과 command queue를 만든다. 실패 시 NULL. */
MaruMetalRenderer *maru_metal_renderer_create(id<MTLDevice> device, MTLPixelFormat pixel_format);

/* raster upload를 GPU atlas texture에 올린다. 텍스처는 처음 호출 때 atlas 크기로 만들고
   이후 누적한다(uploads는 frame마다의 delta다 — 새로 rasterize된 glyph만 온다).
   generation이 바뀐 frame에서만 호출하면 된다. 성공 시 true.

   수명 계약: atlas 크기는 세션 동안 고정이라고 가정한다(dev session의 GlyphAtlas는 고정
   크기에서 eviction하지, 키우지 않는다). 만약 크기가 바뀌면 새 빈 텍스처를 만드는데, producer는
   이미 올린 slot을 다시 보내지 않으므로 이전 glyph가 사라진다. 따라서 growable atlas를
   지원하려면 producer가 resize 시 전체 upload를 다시 보내야 한다(현재 경로는 그렇지 않다). */
bool maru_metal_renderer_set_atlas(
    MaruMetalRenderer *renderer,
    uint32_t atlas_width_px,
    uint32_t atlas_height_px,
    const MaruAppHostDevMetalRasterUpload *uploads,
    size_t upload_count,
    const uint8_t *raster_pixels,
    size_t raster_pixel_count
);

/* 현재 atlas로 cell quad들을 layer의 다음 drawable에 그리고 present한다. 성공 시 true. */
bool maru_metal_renderer_draw(
    MaruMetalRenderer *renderer,
    CAMetalLayer *layer,
    uint16_t cols,
    uint16_t rows,
    const MaruAppHostDevMetalCell *cells,
    size_t cell_count
);

void maru_metal_renderer_destroy(MaruMetalRenderer *renderer);

#endif
