#ifndef MARU_PLATFORM_MACOS_METAL_RENDERER_H
#define MARU_PLATFORM_MACOS_METAL_RENDERER_H

#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#include <stdbool.h>
#include <stddef.h>
#include "app_host_abi.h"

/* 제품 Metal terminal renderer. 평소엔 visible Metal smoke와 달리 readback/sample 같은 검증
   계측이 없는 lean 런타임 경로다(smoke 저자가 주석에서 예고한 "제품 renderer"). cell/upload
   입력은 app session의 metal-frame ABI(MaruAppHostMetalCell/RasterUpload)를 그대로 받아,
   Swift Metal view가 maru_macos_app_session_metal_frame 결과를 변환 없이 넘긴다. GPU 셰이더는
   maru_metal_shader.h로 smoke와 공유한다.

   예외로 MARU_SCREENSHOT=<path> env가 설정됐을 때만 draw가 한 frame을 오프스크린 텍스처에
   그려 BGRA readback 후 PPM(maru_ppm_writer.h)으로 쓰고 프로세스를 종료한다(시각 회귀를 사람이
   눈으로 확인하는 하니스 — 그동안 smoke에만 있던 screenshot artifact를 제품 renderer로 옮긴 것).
   env가 없으면 이 경로는 전혀 타지 않으므로 lean 런타임은 그대로다. */
typedef struct MaruMetalRenderer MaruMetalRenderer;

/* device + drawable pixel format으로 pipeline과 command queue를 만든다. 실패 시 NULL. */
MaruMetalRenderer *maru_metal_renderer_create(id<MTLDevice> device, MTLPixelFormat pixel_format);

/* AS4-c fixture 전용 다중 frame readback 요청. 일반 `MARU_SCREENSHOT`과 달리 프로세스를
   종료하지 않고, 다음 성공 draw 한 장의 최종 두 레이어 합성 결과만 PPM으로 복사한 뒤 요청을
   소모한다. 호출자는 테스트 artifact의 절대 경로를 이미 allowlist해야 하며, pending 요청이
   있거나 경로가 비어 있으면 false로 fail-closed 한다. 일반 앱은 이 API를 호출하지 않는다. */
bool maru_metal_renderer_request_test_capture(
    MaruMetalRenderer *renderer,
    const char *ppm_path
);

/* raster upload를 GPU atlas texture에 올린다. 텍스처는 처음 호출 때 atlas 크기로 만들고
   이후 누적한다(uploads는 frame마다의 delta다 — 새로 rasterize된 glyph만 온다).
   generation이 바뀐 frame에서만 호출하면 된다. 성공 시 true.

   수명 계약: atlas 크기는 세션 동안 고정이라고 가정한다(app session의 GlyphAtlas는 고정
   크기에서 eviction하지, 키우지 않는다). 만약 크기가 바뀌면 새 빈 텍스처를 만드는데, producer는
   이미 올린 slot을 다시 보내지 않으므로 이전 glyph가 사라진다. 따라서 growable atlas를
   지원하려면 producer가 resize 시 전체 upload를 다시 보내야 한다(현재 경로는 그렇지 않다). */
bool maru_metal_renderer_set_atlas(
    MaruMetalRenderer *renderer,
    uint32_t atlas_width_px,
    uint32_t atlas_height_px,
    const MaruAppHostMetalRasterUpload *uploads,
    size_t upload_count,
    const uint8_t *raster_pixels,
    size_t raster_pixel_count
);

/* Phase 4b(b2): 두 **물리** 레이어에 그린다 — terminal_layer(맨 아래: 셀·사이드바·chrome·kitty)와
   overlay_layer(맨 위: 모달 그림자·배경·텍스트·caret, 투명 clear). command buffer를 **drawable 획득 전에**
   잡고(큐 고갈 시 잡힌 drawable 없음 = 누수 0), 잡은 drawable을 각자 그린 뒤 **한 command buffer에 present +
   단일 commit**해 모달 열림/닫힘 전이 프레임이 원자적으로 표시된다(caret은 두 레이어 중 has_modal 분기로
   정확히 한 곳에만 → 항상 1개). drawable_size는 terminal_layer가 authoritative다.
   **오버레이는 조건부 present**: 그릴 내용(모달·그림자)이 있거나 직전 present가 content였는데 이번엔 비었을 때
   (clear 전이 — 닫힌 모달 잔상 제거)만 overlay drawable을 잡아 present하고, 빈→빈이면 건너뛴다(매 프레임 이중
   present 방지 — CAMetalLayer가 마지막 present한 투명 clear 유지). 그때 overlay_layer.drawableSize를 여기서
   terminal에 맞춘다. overlay_layer가 nil이어도 터미널만 그려 present한다(안전 폴백).
   cell_width_px/cell_height_px(고정 cell 픽셀 크기)와 terminal_layer.drawableSize로 픽셀 정확 배치를 한다
   (좌상단 기준, grid를 창에 맞춰 늘이지 않는다). **반환값**: 정상 present면 true. present가 필요한데 오버레이
   drawable을 pool starvation으로 못 잡아 드롭했으면 **false**(호출자는 다음 tick에 재시도해야 한다 — 정적
   모달·닫힘 clear 유실 방지; MaruAppHost.drawMetalFrame이 metalNeedsRedraw로 재시도). MARU_SCREENSHOT
   모드는 두 pass를 한 오프스크린 텍스처에 합성(터미널 Clear → 오버레이 Load)해 실제 2레이어 합성과 같은 최종
   픽셀을 한 장으로 캡처한다(획득/인코딩 실패는 retry 없이 exit(1) fail-fast). */
bool maru_metal_renderer_draw(
    MaruMetalRenderer *renderer,
    CAMetalLayer *terminal_layer,
    CAMetalLayer *overlay_layer,
    uint16_t cols,
    uint16_t rows,
    uint32_t cell_width_px,
    uint32_t cell_height_px,
    const MaruAppHostMetalCell *cells,
    size_t cell_count,
    /* 터미널 surface를 그릴 사각형의 좌측 픽셀 offset(= 세로 사이드바 폭). 각 셀이 origin_x + col*cw에
       놓인다. 0이면 사이드바 없음. "surface→rect" 메커니즘 — split도 같은 origin 방식을 확장한다. */
    uint32_t terminal_origin_x_px,
    /* 사이드바 영역(x: 0..origin_x, 전체 높이) 배경색(0xAARRGGBB). 0이면 안 그림. */
    uint32_t sidebar_bg,
    /* 사이드바 rect(x: 0..origin_x) 안에 origin 0으로 그릴 셀들 — 탭 엔트리 하이라이트/제목. 터미널
       셀과 같은 표현이지만 origin offset 없이 0 + col*cw에 놓이고, 사이드바 배경 quad 위에 그려진다.
       NULL이거나 origin_x==0이면 그리지 않는다. */
    const MaruAppHostMetalCell *sidebar_cells,
    size_t sidebar_cell_count,
    /* 사이드바 탭 슬롯 한 칸의 픽셀 높이(≈2.5×cell_height). 사이드바 셀을 cell 높이가 아니라 이 슬롯
       높이로 세로 배치한다(셀 row → py=row×slot_h, 높이 slot_h). 0이면 cell 높이로 폴백. */
    uint32_t sidebar_slot_height_px,
    /* 사이드바 상단 헤더(검색바 + 아이콘) 높이(px). 사이드바 셀 py_top에 더해 헤더만큼 아래로 민다. 0이면 없음. */
    uint32_t sidebar_header_height_px,
    /* chrome rich GPU quad 프리미티브(C4b — 둥근 사각형: per-corner radius+border+gradient, SDF AA).
       NULL/0이면 안 그림(tui 테마는 셀 fill 유지). 셀 패스 아래(배경 레이어)에 별개 파이프라인으로 그린다. */
    const MaruAppHostGpuQuad *gpu_quads,
    size_t gpu_quad_count,
    /* C4b overlay 셀이 cells에서 시작하는 순수 인덱스. 존재 여부는 마지막 overlay_cells_present가 명시하며,
       over quad(모달 배경)를 텍스트 셀 '앞'에 끼우는 분할점이다. */
    size_t modal_cells_start,
    /* C4b 모달 클리핑(px, 좌상단, w==0=없음). 모달 셀 draw에 setScissorRect로 적용한다 — MTLScissorRect도
       좌상단 원점이라 y를 뒤집지 않고 drawable 안으로 clamp만 한다. 부분 카드 픽셀 스크롤(알림 패널 등) 인프라. */
    uint32_t modal_clip_x_px,
    uint32_t modal_clip_y_px,
    uint32_t modal_clip_w_px,
    uint32_t modal_clip_h_px,
    /* C4b: chrome 그림자(GpuShadow). NULL/0이면 안 그림. quad·셀보다 아래(맨 처음) 그린다. */
    const MaruAppHostGpuShadow *gpu_shadows,
    size_t gpu_shadow_count,
    /* kitty graphics(K2): 이미지 placement 드로우 프리미티브(textured quad). NULL/0이면 안 그림. pass<2
       (텍스트 뒤)는 셀 패스 전에, pass==2(텍스트 앞)는 셀 패스 후에 그린다. 각 이미지를 자기 텍스처로 그린다. */
    const MaruAppHostGpuImage *gpu_images,
    size_t gpu_image_count,
    /* kitty graphics(K2): 이번 frame에 (재)업로드할 이미지 텍스처 디스크립터(generation 바뀐 것만). renderer가
       image_id별 텍스처를 만들어 캐시한다. NULL/0이면 업로드 없음(기존 캐시 재사용). */
    const MaruAppHostGpuImageUpload *image_uploads,
    size_t image_upload_count,
    /* 위 image_uploads가 가리키는 픽셀 연속 버퍼(RGBA bpp=4 / RGB bpp=3 — RGB는 RGBA로 확장 업로드). */
    const uint8_t *image_pixels,
    size_t image_pixel_count,
    /* kitty graphics(K4c): 현재 살아있는 이미지 id 집합. 이 집합에 없는 캐시 텍스처를 evict한다(GPU 메모리
       회수 — delete/evict/RIS 반영). count==0이면 살아있는 이미지 없음 → 전부 evict. */
    const uint32_t *live_image_ids,
    size_t live_image_id_count,
    /* 화면 clear color(0xAARRGGBB) — render pass clearColor. OSC 11(배경 set) 있으면 그 색, 없으면
       theme.background. 0이면 기존 기본 clear(어두운 남색)로 폴백. 빈 영역/기본 배경(A0) 셀이 비치는 색. */
    uint32_t terminal_bg,
    /* 상단 타이틀바 띠(신호등·헤더 아이콘 줄) 높이(px). 접힘 펼치기 토글(◧) 글리프를 이 띠 [0, strip] 안에
       세로 중앙 배치해 신호등과 정렬시키는 데만 쓴다. terminal_origin_x_px>0(펼침)이면 무관(헤더 아이콘은
       기존 0.3ch nudge). 0이면 띠 없음(0.3ch nudge 폴백). */
    uint32_t titlebar_strip_px,
    /* 창 배경 투명도 × 1000(0~1000, 1000=불투명). 화면 clear color alpha에 이 값/1000을 곱한다 — default 배경
       (빈 영역/기본 배경 A0 셀)만 투명, 명시적 배경색 셀은 불투명 유지. layer/창 비불투명은 host(Swift)가 별도로. */
    uint32_t window_opacity_milli,
    /* 사이드바 세로 스크롤량(backing px). 사이드바 셀(밴드·카드 glyph) py_top에서 빼 카드를 위로 밀고, >0이면 사이드바
       셀 draw에 [sidebar_header_height_px, drawable_h] scissor를 적용해 헤더 위로 샌 카드를 자른다(헤더 glyph는 터미널
       셀 패스라 무관). 0이면 기존 동작(scissor 없음). 끝에 추가해 기존 인자 순서 불변(ABI v86). */
    uint32_t sidebar_scroll_offset_px,
    /* pane divider(reserved 30 세로·31 가로)의 device px 두께 — config split.divider-thickness(pt)를 app_session가
       scale로 환산해 넘긴다. renderer가 seam 중앙정렬·셀 clamp로 divider strip을 그린다. 커서 강조선
       (reserved 2~5, 셀 15%)·GPU quad FocusOwner border와 분리돼 divider만 이 값으로 두께가 정해진다. 0=안 그림. 끝에 추가해 인자 순서 불변(ABI v94). */
    uint32_t divider_thickness_px,
    /* 커서 blink 페이드(ABI v95): 커서 overlay가 차지하는 cells 길이와 그 불투명도×1000. 렌더러가 본문 셀 draw에서
       이 구간을 제외하고, cursor_fade_milli>0이면 별도 pass로 opacity=cursor_fade_milli/1000에 그린다(셀 fragment의
       opacity uniform). 끝에 2인자 추가해 인자 순서 불변. 구간의 시작은 아래 cursor_start(v146). */
    size_t cursor_cells,
    uint32_t cursor_fade_milli,
    /* ABI v131: modal_cells_start=0에서도 overlay 존재를 표현하는 명시 gate. */
    uint32_t overlay_cells_present,
    /* 커서 구간의 시작 index — cells[cursor_start, cursor_start+cursor_cells). v95는 "커서는 항상 버퍼 suffix"를
       암묵 가정했지만, caret 없는 오버레이 셀(포커스 테두리·drop 하이라이트·드래그 고스트)이 커서 뒤에 붙으면
       그 가정이 깨져 커서가 본문과 함께 불투명하게 그려졌다(=blink 죽음). 시작을 명시로 받아 커서가 버퍼 중간에
       있어도 본문을 [.., cursor_start)와 [cursor_start+cursor_cells, ..) 두 구간으로 나눠 그린다(ABI v146). */
    size_t cursor_start,
    /* B1 rich Chrome text: pre-shaped/pre-rasterized atlas glyphs at final backing-pixel rects.
       NULL/0 preserves the existing terminal cell path. */
    const MaruAppHostGpuGlyph *gpu_glyphs,
    size_t gpu_glyph_count,
    /* SB1: 창 바닥 상태표시줄이 예약한 높이(backing px). 사이드바 배경 strip을 이만큼 위에서 끝낸다.
       0=기존 동작(창 바닥까지). 끝에 추가해 인자 순서 불변(ABI v167). */
    uint32_t status_bar_height_px,
    /* SV2a(ABI v147): 셀 격자 본문 중 **한 구간**을 px 사각으로 자른다(좌상단, len==0=없음). 렌더러는
       본문 draw를 이 구간 앞/가운데/뒤로 나누고 가운데만 setScissorRect로 그린다. 파일 탐색기의 부분
       행 픽셀 스크롤이 첫 소비자다. index는 cells 기준(cursor_start와 같은 도메인). */
    uint32_t pane_clip_cells_start,
    uint32_t pane_clip_cells_len,
    uint32_t pane_clip_x_px,
    uint32_t pane_clip_y_px,
    uint32_t pane_clip_w_px,
    uint32_t pane_clip_h_px,
    /* 사이드바 셀 scissor 세로 구간 [top, bottom)(backing px). 그대로 적용한다 — 게이트·클램프는
       호출자가 이미 했다. bottom <= top이면 scissor 없음. 끝에 추가해 인자 순서 불변(ABI v168). */
    uint32_t sidebar_scissor_top_px,
    uint32_t sidebar_scissor_bottom_px
);

void maru_metal_renderer_destroy(MaruMetalRenderer *renderer);

#endif
