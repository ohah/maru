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

/* 현재 atlas로 cell quad들을 layer의 다음 drawable에 그리고 present한다. cell_width_px/
   cell_height_px(고정 cell 픽셀 크기)와 layer.drawableSize로 픽셀 정확 배치를 한다(좌상단
   기준, grid를 창에 맞춰 늘이지 않는다). 성공 시 true. */
bool maru_metal_renderer_draw(
    MaruMetalRenderer *renderer,
    CAMetalLayer *layer,
    uint16_t cols,
    uint16_t rows,
    uint32_t cell_width_px,
    uint32_t cell_height_px,
    const MaruAppHostDevMetalCell *cells,
    size_t cell_count,
    /* 터미널 surface를 그릴 사각형의 좌측 픽셀 offset(= 세로 사이드바 폭). 각 셀이 origin_x + col*cw에
       놓인다. 0이면 사이드바 없음. "surface→rect" 메커니즘 — split도 같은 origin 방식을 확장한다. */
    uint32_t terminal_origin_x_px,
    /* 사이드바 영역(x: 0..origin_x, 전체 높이) 배경색(0xAARRGGBB). 0이면 안 그림. */
    uint32_t sidebar_bg,
    /* 사이드바 rect(x: 0..origin_x) 안에 origin 0으로 그릴 셀들 — 탭 엔트리 하이라이트/제목. 터미널
       셀과 같은 표현이지만 origin offset 없이 0 + col*cw에 놓이고, 사이드바 배경 quad 위에 그려진다.
       NULL이거나 origin_x==0이면 그리지 않는다. */
    const MaruAppHostDevMetalCell *sidebar_cells,
    size_t sidebar_cell_count,
    /* 사이드바 탭 슬롯 한 칸의 픽셀 높이(≈2.5×cell_height). 사이드바 셀을 cell 높이가 아니라 이 슬롯
       높이로 세로 배치한다(셀 row → py=row×slot_h, 높이 slot_h). 0이면 cell 높이로 폴백. */
    uint32_t sidebar_slot_height_px,
    /* chrome rich GPU quad 프리미티브(C4b — 둥근 사각형: per-corner radius+border+gradient, SDF AA).
       NULL/0이면 안 그림(tui 테마는 셀 fill 유지). 셀 패스 아래(배경 레이어)에 별개 파이프라인으로 그린다. */
    const MaruAppHostDevGpuQuad *gpu_quads,
    size_t gpu_quad_count,
    /* C4b 모달: 모달(overlay) 셀이 cells에서 시작하는 인덱스(0=모달 없음). over quad(모달 배경)를 모달
       텍스트 셀 '앞'에 끼우는 분할점. */
    size_t modal_cells_start,
    /* C4b: chrome 그림자(GpuShadow). NULL/0이면 안 그림. quad·셀보다 아래(맨 처음) 그린다. */
    const MaruAppHostDevGpuShadow *gpu_shadows,
    size_t gpu_shadow_count,
    /* kitty graphics(K2): 이미지 placement 드로우 프리미티브(textured quad). NULL/0이면 안 그림. pass<2
       (텍스트 뒤)는 셀 패스 전에, pass==2(텍스트 앞)는 셀 패스 후에 그린다. 각 이미지를 자기 텍스처로 그린다. */
    const MaruAppHostDevGpuImage *gpu_images,
    size_t gpu_image_count,
    /* kitty graphics(K2): 이번 frame에 (재)업로드할 이미지 텍스처 디스크립터(generation 바뀐 것만). renderer가
       image_id별 텍스처를 만들어 캐시한다. NULL/0이면 업로드 없음(기존 캐시 재사용). */
    const MaruAppHostDevGpuImageUpload *image_uploads,
    size_t image_upload_count,
    /* 위 image_uploads가 가리키는 픽셀 연속 버퍼(RGBA bpp=4 / RGB bpp=3 — RGB는 RGBA로 확장 업로드). */
    const uint8_t *image_pixels,
    size_t image_pixel_count,
    /* kitty graphics(K4c): 현재 살아있는 이미지 id 집합. 이 집합에 없는 캐시 텍스처를 evict한다(GPU 메모리
       회수 — delete/evict/RIS 반영). count==0이면 살아있는 이미지 없음 → 전부 evict. */
    const uint32_t *live_image_ids,
    size_t live_image_id_count
);

void maru_metal_renderer_destroy(MaruMetalRenderer *renderer);

#endif
