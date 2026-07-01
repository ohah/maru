#ifndef MARU_PLATFORM_MACOS_APP_HOST_ABI_H
#define MARU_PLATFORM_MACOS_APP_HOST_ABI_H

#include <stdint.h>
#include <stddef.h>

/* 이 header는 실제 앱 동작을 구현하지 않고 Swift/Zig 사이의 약속만 고정한다.
   Swift가 AppKit object나 Swift struct layout을 바로 넘기면 Zig 쪽에서 안전하게
   해석할 수 없으므로, 제품 host가 시작되기 전에 fixed-width C record만 허용한다. */
#define MARU_MACOS_APP_HOST_ABI_VERSION 94u

/* workspace 저장 포맷 헤더(첫 줄). Zig(app.workspace.header)·Swift(저장/로드/적용)가 같은 문자열을 써야
   하므로 ABI 버전과 같은 방식으로 여기서 단일 출처화한다 — Zig 크로스체크 테스트가 동기화를 강제한다. */
#define MARU_WORKSPACE_HEADER "maru.workspace.v1"

/* Status는 "치명적 세션 fault"와 "이 한 event만 거부됨"을 구분한다. Swift host는
   per-event 거부(KeyFailed/ResizeFailed)나 정상 종료(SessionEnded)를 앱 전체를 죽이는
   fault와 다르게 처리해야 한다. */
typedef enum MaruAppHostStatus {
    MaruAppHostStatusOk = 0,
    MaruAppHostStatusNullOut = 1,
    MaruAppHostStatusUnsupportedAbi = 2,
    MaruAppHostStatusInvalidConfig = 3,
    MaruAppHostStatusCreateFailed = 4,
    MaruAppHostStatusTickFailed = 5,
    MaruAppHostStatusCloseFailed = 6,
    MaruAppHostStatusKeyFailed = 7,
    MaruAppHostStatusResizeFailed = 8,
    /* tick이 PTY 세션 종료(shell exit/read_error)를 관측했다. fault가 아니라 정상 종료
       신호이므로 host는 frame loop를 멈추고 우아하게 내려가야 한다. */
    MaruAppHostStatusSessionEnded = 9,
} MaruAppHostStatus;

typedef enum MaruAppHostEventKind {
    MaruAppHostEventNone = 0,
    MaruAppHostEventFrameTick = 1,
    MaruAppHostEventKeyDown = 2,
    MaruAppHostEventResize = 3,
    MaruAppHostEventCloseRequested = 4,
    MaruAppHostEventAppShouldTerminate = 5,
} MaruAppHostEventKind;

typedef enum MaruAppHostKeyCode {
    MaruAppHostKeyCodeUnknown = 0,
    MaruAppHostKeyCodeEnter = 1,
    MaruAppHostKeyCodeEscape = 2,
    MaruAppHostKeyCodeTab = 3,
    MaruAppHostKeyCodeBackspace = 4,
    MaruAppHostKeyCodeArrowUp = 5,
    MaruAppHostKeyCodeArrowDown = 6,
    MaruAppHostKeyCodeArrowLeft = 7,
    MaruAppHostKeyCodeArrowRight = 8,
    /* PC-style 기능키 — Swift normalizedKeyEvent가 NSEvent.keyCode를 이 값으로 매핑한다. */
    MaruAppHostKeyCodeHome = 9,
    MaruAppHostKeyCodeEnd = 10,
    MaruAppHostKeyCodeInsert = 11,
    MaruAppHostKeyCodeDelete = 12,
    MaruAppHostKeyCodePageUp = 13,
    MaruAppHostKeyCodePageDown = 14,
    MaruAppHostKeyCodeF1 = 15,
    MaruAppHostKeyCodeF2 = 16,
    MaruAppHostKeyCodeF3 = 17,
    MaruAppHostKeyCodeF4 = 18,
    MaruAppHostKeyCodeF5 = 19,
    MaruAppHostKeyCodeF6 = 20,
    MaruAppHostKeyCodeF7 = 21,
    MaruAppHostKeyCodeF8 = 22,
    MaruAppHostKeyCodeF9 = 23,
    MaruAppHostKeyCodeF10 = 24,
    MaruAppHostKeyCodeF11 = 25,
    MaruAppHostKeyCodeF12 = 26,
} MaruAppHostKeyCode;

typedef struct MaruAppHostCapabilities {
    uint32_t abi_version;
    uint32_t swift_owns_ns_application;
    uint32_t swift_owns_window_lifecycle;
    uint32_t swift_owns_focus_and_input;
    uint32_t zig_owns_live_pty_sessions;
    uint32_t zig_owns_frame_loop;
    uint32_t objective_c_smokes_remain;
} MaruAppHostCapabilities;

typedef struct MaruAppHostKeyEvent {
    uint32_t codepoint;
    /* codepoint의 unshifted base-layout 값(shift 미반영). kitty keyboard CSI u의 key code는
       명세상 base-layout key여야 하므로, Swift가 characters(byApplyingModifiers:[])로 따로 싣는다.
       char가 아니거나 단일 codepoint가 아니면 0(Zig가 codepoint로 폴백). */
    uint32_t base_codepoint;
    uint32_t key_code;
    uint32_t modifier_shift;
    uint32_t modifier_control;
    uint32_t modifier_option;
    uint32_t modifier_command;
    uint32_t is_repeat;
    /* macOS 물리 키코드(NSEvent.keyCode). Ctrl/Cmd 단축키의 레이아웃 독립 매칭(한글 입력
       모드에서도 Ctrl+B 동작)에 쓴다 — US 배열 변환은 Zig가 소유한다. */
    uint32_t raw_key_code;
} MaruAppHostKeyEvent;

typedef struct MaruAppHostResizeEvent {
    uint32_t width_px;
    uint32_t height_px;
    uint32_t scale_milli;
    uint32_t cols;
    uint32_t rows;
    uint32_t reserved;
} MaruAppHostResizeEvent;

typedef enum MaruAppHostCommandKind {
    MaruAppHostCommandControlledSmoke = 0,
    MaruAppHostCommandInteractiveShell = 1,
} MaruAppHostCommandKind;

typedef struct MaruAppHostSession MaruAppHostSession;

typedef struct MaruAppHostSessionConfig {
    uint32_t abi_version;
    uint32_t cols;
    uint32_t rows;
    uint32_t queue_capacity;
    uint32_t command_kind;
    /* 1이면 chrome 최소화(사이드바·pane 탭 바 없이 터미널 그리드만) — quick terminal minimal 모드.
       0이면 full chrome(메인 창). 세션별로 정한다 — Swift가 quick_terminal.chrome config를 읽어 quick
       세션 생성 시에만 1로 넘긴다(메인 창은 항상 0). */
    uint32_t chrome_minimal;
    /* 1이면 chrome_minimal 세션에서도 탭(워크스페이스·Term) 생성을 허용한다. 0이면 minimal은 단일
       스크래치(⌘T/⌘⇧T 무동작). chrome_minimal=0(full)이면 이 값과 무관하게 탭이 항상 동작한다.
       Swift가 quick_terminal.minimal-tabs config를 읽어 quick 세션에만 넘긴다(메인 창은 0). */
    uint32_t minimal_tabs;
    /* 첫 셸 spawn 크기 결정용 창 backing 픽셀 + scale(천분율). 셋이 다 >0이면 app session이 cell 메트릭으로
       grid를 계산해 PTY를 처음부터 실제 창 크기로 띄운다(80×24 기본 spawn→resize 핸드셰이크/zsh 첫 프롬프트
       PROMPT_EOL_MARK(%) 잔상 제거). 모르면 0 — cols/rows로 폴백. Swift가 창 contentView×backingScale로 채운다. */
    uint32_t width_px;
    uint32_t height_px;
    uint32_t scale_milli;
} MaruAppHostSessionConfig;

typedef struct MaruAppHostFrameSummary {
    uint32_t abi_version;
    uint32_t terminal_surface;
    uint64_t frame_loop_ticks;
    uint64_t last_tick_index;
    uint64_t output_events;
    uint64_t exit_events;
    uint64_t surface_id;
    uint64_t glyph_count;
    uint64_t draw_cells;
    uint64_t atlas_entries;
    uint64_t key_events;
    uint64_t terminal_input_events;
    uint64_t terminal_input_bytes;
    uint64_t app_key_events;
    uint64_t ignored_key_events;
    uint64_t resize_events;
    uint64_t close_events;
    uint32_t cols;
    uint32_t rows;
    uint32_t process_state;
    uint32_t frame_prepared;
    uint32_t frame_consistent;
    uint32_t glyph_uv_ready;
    uint32_t glyph_raster_ready;
    uint32_t ended;
    /* 이 summary를 만든 lifecycle event(MaruAppHostEventKind). frame_tick / key_down /
       resize / close_requested, 그리고 tick이 종료를 본 경우 app_should_terminate. */
    uint32_t last_event_kind;
    /* 현재 retain된 Metal frame의 generation(u32 truncate). host는 이 값이 그대로면
       maru_macos_app_session_metal_frame 호출을 건너뛰어 idle tick 비용을 줄일 수 있다. */
    uint32_t metal_generation;
    /* Cmd+Q 종료 확인 모달의 결정을 host로 한 번 전달하는 one-shot 신호(0=대기/없음·1=accepted·2=cancelled).
       maru_macos_app_session_request_app_quit으로 모달을 띄운 뒤 confirm 확정/취소가 다음 tick에 이 값에 실리면
       Swift가 NSApp.reply(toApplicationShouldTerminate:)로 종료를 진행/취소한다. */
    uint32_t quit_decision;
} MaruAppHostFrameSummary;

/* 가장 최근 tick의 RenderFrame을 Metal로 그리기 위한 DTO. cell 하나가 atlas slot 1개와 그
   UV 사각형을 가리킨다. layout은 Zig metal_frame.NativeMetalCell과 1:1로 맞춘다. */
typedef struct MaruAppHostMetalCell {
    uint16_t row;
    uint16_t col;
    uint16_t width;
    /* overlay 종류: 0=일반 cell, 2=커서 underline/hollow 하단, 3=커서 bar/hollow 좌측, 4=hollow 상단,
       5=hollow 우측(커서 강조선 — 셀 ~15%). 6=strikethrough·7=2중밑줄 둘째·9=밑줄·10=윗줄(SGR 텍스트 장식선 ~7.5%).
       8=OSC 133 거터(셀 왼쪽 바깥). 30=pane divider 세로선·31=divider 가로선(seam 중앙정렬 config 두께 divider_thickness_px, 커서와 분리).
       renderer는 reserved에서 cell의 한 변/중앙 가는 띠만 칠한다(글리프를 안 가림). */
    uint16_t reserved;
    uint32_t codepoint;
    uint32_t slot_id;
    uint32_t atlas_x_px;
    uint32_t atlas_y_px;
    uint32_t atlas_width_px;
    uint32_t atlas_height_px;
    float u0;
    float v0;
    float u1;
    float v1;
    /* 전경 색(0x00RRGGBB). renderer가 흰색 glyph coverage에 이 색을 곱한다. */
    uint32_t foreground;
    /* 배경 색(0xAARRGGBB). A=0xFF면 cell을 그 색으로 채우고 glyph를 위에 blend한다.
       A=0이면 배경 없음(theme 기본 배경이 비친다). */
    uint32_t background;
    /* 이 cell이 속한 panel(split leaf)의 픽셀 origin. renderer가 origin_x + col*cw, origin_y + row*ch에
       둔다. 단일 panel이면 모든 터미널 cell이 (사이드바 폭, 0). split이 panel별로 다른 origin을 준다.
       사이드바 cell은 자체 위치 로직을 써 이 필드를 무시한다(0). */
    uint32_t origin_x;
    uint32_t origin_y;
} MaruAppHostMetalCell;

/* 한 glyph slot의 raster bytes를 atlas texture에 올리기 위한 업로드 기술자. bytes_offset/
   byte_count는 MaruAppHostMetalFrame.raster_pixels 버퍼 안의 범위다. */
typedef struct MaruAppHostMetalRasterUpload {
    uint32_t slot_id;
    uint32_t atlas_x_px;
    uint32_t atlas_y_px;
    uint32_t atlas_width_px;
    uint32_t atlas_height_px;
    size_t bytes_offset;
    size_t byte_count;
    size_t bytes_per_row;
    size_t non_clear_pixels;
} MaruAppHostMetalRasterUpload;

/* chrome rich 백엔드(C4b)의 GPU 둥근 사각형 프리미티브. Zig metal_frame.GpuQuad와 1:1. 셀 그리드와
   별개 파이프라인으로 SDF anti-aliasing. tui 테마는 빈 배열(NULL/0)이라 렌더 무동작(셀 fill 유지), rich만
   채운다(C4b-2~). 좌표 backing px. */
typedef struct MaruAppHostGpuQuad {
    float x;
    float y;
    float w;
    float h;
    float corner_radii[4];   /* [top-left, top-right, bottom-right, bottom-left], px */
    float border_widths[4];  /* [top, right, bottom, left], px */
    uint32_t fill_color0;    /* 0xAARRGGBB — gradient 시작색 */
    uint32_t fill_color1;    /* gradient 끝색(solid면 무시) */
    uint32_t border_color;   /* 0xAARRGGBB */
    uint32_t gradient_kind;  /* 0=solid, 1=vertical(top→bottom), 2=horizontal(left→right), 3=위 삼각형(말풍선 caret, fill_color0 단색+edge AA; corner/border 무시) */
    uint32_t layer;          /* C4b: 0=under(사이드바 밴드), 1=over(모달 최상위), 2=bottom(탭 밴드 — part1 앞·아래) — draw가 layer로 3패스 분리 */
} MaruAppHostGpuQuad;

/* C4b의 둥근 drop shadow 프리미티브(blur). quad와 같은 별개 파이프라인, rich만 채운다. Zig GpuShadow와 1:1. */
typedef struct MaruAppHostGpuShadow {
    float x;
    float y;
    float w;
    float h;
    float corner_radii[4];   /* [tl, tr, br, bl], px */
    float blur_radius;       /* px (0=블러 없음) */
    uint32_t color;          /* 0xAARRGGBB */
} MaruAppHostGpuShadow;

/* kitty graphics 이미지 placement의 GPU 드로우 프리미티브(K2). Zig metal_frame.GpuImage와 1:1. 셀 그리드와
   별개 파이프라인(textured quad)으로, image_id로 캐시된 텍스처를 dest 사각형에 source UV로 그린다. pass(0/1/2)로
   셀배경/텍스트 전후에 그린다. 좌표는 터미널-로컬 backing px(origin_x/y는 split panel 오프셋). */
typedef struct MaruAppHostGpuImage {
    uint32_t image_id;
    float dest_x;
    float dest_y;
    float dest_w;
    float dest_h;
    uint32_t origin_x;
    uint32_t origin_y;
    float src_u0;
    float src_v0;
    float src_u1;
    float src_v1;
    int32_t z;
    uint32_t pass;           /* 0=below_bg, 1=below_text, 2=above_text(같은 pass 안 z 오름차순) */
} MaruAppHostGpuImage;

/* kitty graphics 이미지 텍스처 업로드 디스크립터(K2). Zig metal_frame.GpuImageUpload와 1:1. generation이 바뀐
   (신규/재transmit) 이미지만 들어온다 — renderer가 image_id로 텍스처를 캐시하고 여기 있는 것만 (재)업로드한다.
   pixels_offset/len은 frame의 image_pixels 연속 버퍼 안 이 이미지 구간(RGBA/RGB)을 가리킨다. */
typedef struct MaruAppHostGpuImageUpload {
    uint32_t image_id;
    uint32_t width;
    uint32_t height;
    uint32_t bpp;            /* 3(RGB)/4(RGBA) */
    uint64_t generation;
    size_t pixels_offset;
    size_t pixels_len;
} MaruAppHostGpuImageUpload;

/* 가장 최근 frame의 Metal view. 모든 포인터는 app session이 소유한 retained 배열을 가리키며,
   "다음으로 재투영하는 tick"(새 output 또는 resize가 있는 tick) 또는 destroy까지 유효하다.
   idle tick은 재투영하지 않으므로 포인터가 유지되고 generation도 그대로다. close는 이 배열을
   해제하지 않는다(destroy에서만 해제). caller는 같은 main thread에서 동기적으로 소비해야
   한다. generation은 실제 재투영이 일어난 frame에서만 증가하므로, 값이 바뀌었을 때만 atlas
   재업로드/재드로우하면 된다. */
typedef struct MaruAppHostMetalFrame {
    uint32_t cols;
    uint32_t rows;
    uint32_t atlas_width_px;
    uint32_t atlas_height_px;
    /* 한 terminal cell의 픽셀 크기(정사각 glyph = font_size_px × device_scale). renderer는
       이 값으로 fixed-cell pixel layout을, host는 resize의 cols/rows 계산을 한다. */
    uint32_t cell_width_px;
    uint32_t cell_height_px;
    uint64_t generation;
    const MaruAppHostMetalCell *cells;
    size_t cell_count;
    const MaruAppHostMetalRasterUpload *raster_uploads;
    size_t raster_upload_count;
    const uint8_t *raster_pixels;
    size_t raster_pixel_count;
    /* 터미널 surface를 그릴 사각형의 좌측 픽셀 offset(= 세로 사이드바 폭). renderer가 각 셀을
       origin_x + col*cw에 둔다. 0이면 사이드바 없음(터미널이 창 전체). "surface→rect" 메커니즘의
       첫 적용 — split(panel)도 같은 origin offset을 확장한다. */
    uint32_t terminal_origin_x_px;
    /* 사이드바 영역(x: 0..terminal_origin_x_px, 전체 높이) 배경색(0xAARRGGBB). 0이면 안 그림. */
    uint32_t sidebar_bg;
    /* 사이드바 rect(x: 0..terminal_origin_x_px) 안에 origin 0으로 그릴 셀들 — 탭 엔트리 하이라이트
       밴드와 이후 탭 제목 glyph. terminal cells와 같은 표현이지만 renderer가 origin offset 없이
       (0 + col*cw) 사이드바 strip 안에 그리고, 사이드바 배경 quad 위에 블렌딩한다. NULL/0이면
       사이드바 셀 없음("surface→rect"의 두 번째 surface — split도 rect별 cell 배열로 확장). */
    const MaruAppHostMetalCell *sidebar_cells;
    size_t sidebar_cell_count;
    /* 사이드바 탭 슬롯 한 칸의 픽셀 높이(≈2.5×cell_height). renderer가 사이드바 셀을 cell 높이가 아니라
       이 슬롯 높이로 세로 배치한다(밴드 row i → py=i×slot_h) — 큰 탭 슬롯. 0이면 cell 높이로 폴백. */
    uint32_t sidebar_slot_height_px;
    /* 사이드바 상단 헤더(검색바 + 아이콘) 높이(px). renderer가 사이드바 셀 py_top에 더해 헤더만큼 아래로
       민다(밴드·카드 glyph 공통). 0이면 헤더 없음. MetalFrame(Zig extern)과 같은 위치·타입(ABI 일치). */
    uint32_t sidebar_header_height_px;
    /* chrome rich GPU 프리미티브(C4b). tui 테마는 빈 배열(NULL/0)이라 렌더 무동작(셀 그리드 유지),
       rich 테마만 lowering이 채운다(C4b-2~). NativeMetalCell과 별개 파이프라인으로 SDF AA로 그린다. */
    const MaruAppHostGpuQuad *gpu_quads;
    size_t gpu_quad_count;
    const MaruAppHostGpuShadow *gpu_shadows;
    size_t gpu_shadow_count;
    /* C4b 모달: 모달 셀이 cells에서 시작하는 인덱스(0=모달 없음). 렌더러가 over quad(모달 배경)를 모달
       텍스트 셀 '앞'에 끼우는 분할점. */
    size_t modal_cells_start;
    /* kitty graphics(K2): 이미지 placement 드로우 프리미티브. NULL/0이면 이미지 없음(렌더 무동작). */
    const MaruAppHostGpuImage *gpu_images;
    size_t gpu_image_count;
    /* kitty graphics(K2): 이번 frame에 (재)업로드할 이미지 텍스처 디스크립터(generation 바뀐 것만). */
    const MaruAppHostGpuImageUpload *image_uploads;
    size_t image_upload_count;
    /* 위 image_uploads가 가리키는 픽셀 연속 버퍼(RGBA/RGB). NULL/0이면 업로드 없음. */
    const uint8_t *image_pixels;
    size_t image_pixel_count;
    /* kitty graphics(K4c): 현재 살아있는 이미지 id 집합(활성 surface 저장소 키). renderer가 이 집합에
       없는 캐시 텍스처를 evict해 GPU 메모리를 회수한다(delete/evict/RIS 반영). count==0이면 살아있는
       이미지 없음 → 전부 evict. */
    const uint32_t *live_image_ids;
    size_t live_image_id_count;
    /* 화면 clear color(빈 영역/기본 배경이 비치는 색, 0xAARRGGBB). OSC 11(배경 set)이 있으면 그 색, 없으면
       theme.background. host가 render pass clearColor로 쓴다(셀이 default 배경=A0일 때 드러나는 색). 0이면
       renderer 기본 clear로 폴백. 끝에 추가해 기존 필드 offset 불변(ABI v51). */
    uint32_t terminal_bg;
    /* 상단 타이틀바 띠(신호등·헤더 아이콘 줄)의 픽셀 높이. renderer가 접힘 펼치기 토글(◧) 글리프를 이 띠
       [0, titlebar_strip_px] 안에 세로 중앙 배치해 신호등과 정렬시키는 데만 쓴다(펼침 헤더 아이콘은
       terminal_origin_x_px>0이라 영향 없음). 0이면 기존 0.3ch nudge 폴백. 끝에 추가해 기존 offset 불변(ABI v66). */
    uint32_t titlebar_strip_px;
    /* 창 배경 투명도 × 1000(0~1000, 1000=불투명). renderer가 화면 clear color alpha에 이 값/1000을 곱한다 —
       default 배경(빈 영역·기본 배경 셀 A=0)만 투명해지고 명시적 배경색 셀은 불투명 유지(iTerm2/Ghostty
       background-opacity 모델). host가 opacity<1이면 metal layer/NSWindow도 비불투명으로. float 대신 milli
       정수로 ABI를 정수 유지. 끝에 추가해 기존 offset 불변(ABI v70). */
    uint32_t window_opacity_milli;
    /* C4b 모달 클리핑(인프라): 모달 오버레이 셀을 이 px 사각(backing, 좌상단)으로 클리핑한다 — chrome 컴포넌트가
       draw.Op.clip을 내면 lowering이 채우고, renderer가 모달 셀 draw에 setScissorRect로 적용한다(Metal은 좌하단
       원점이라 y = drawable_h - (y+h) 변환). w==0이면 클리핑 없음(기존 동작). 부분 카드 픽셀 스크롤(알림 패널 등)
       재사용 인프라 — 컴포넌트 적용은 후속. 끝에 4필드 추가해 기존 offset 불변(ABI v84). */
    uint32_t modal_clip_x_px;
    uint32_t modal_clip_y_px;
    uint32_t modal_clip_w_px;
    uint32_t modal_clip_h_px;
    /* 사이드바 세로 스크롤량(backing px). renderer가 사이드바 셀(밴드·카드 glyph) py_top에서 빼 카드를 위로 밀고,
       >0이면 사이드바 셀 draw에 [header_h, drawable_h] scissor를 적용해 헤더 위로 샌 카드를 자른다(헤더 glyph는
       터미널 셀 패스라 영향 없음). GPU quad 밴드·tint는 host lowering이 같은 값으로 이미 빼 클립한다(단일 출처).
       0이면 기존 동작(scissor 없음). 끝에 추가해 기존 offset 불변(ABI v86). */
    uint32_t sidebar_scroll_offset_px;
    /* pane divider(reserved 30 세로·31 가로)의 device px 두께 — config split.divider-thickness(pt)를 app_session가
       scale로 환산. renderer가 seam 중앙정렬·셀 clamp로 divider strip을 그린다(커서·focus 테두리 reserved 2~5의 셀 15%와
       분리). 0=안 그림. 끝에 추가해 기존 offset 불변(ABI v94). */
    uint32_t divider_thickness_px;
} MaruAppHostMetalFrame;

uint32_t maru_macos_app_host_abi_version(void);
int32_t maru_macos_app_host_capabilities(MaruAppHostCapabilities *out_capabilities);
int32_t maru_macos_app_session_create(
    const MaruAppHostSessionConfig *config,
    MaruAppHostSession **out_session
);
/* Swift host의 앱 전역 frame-loop cadence를 주입해 이 session tick의 ms→tick 환산 기준으로 쓴다.
   여러 session의 config 희망값이 달라도 실제 tick clock은 하나이므로, host가 쓰는 cadence를 매 tick 넘긴다. v93. */
int32_t maru_macos_app_session_tick(
    MaruAppHostSession *session,
    uint32_t frame_loop_rate_hz,
    MaruAppHostFrameSummary *out_summary
);
int32_t maru_macos_app_session_key_down(
    MaruAppHostSession *session,
    const MaruAppHostKeyEvent *event,
    MaruAppHostFrameSummary *out_summary
);
int32_t maru_macos_app_session_resize(
    MaruAppHostSession *session,
    const MaruAppHostResizeEvent *event,
    MaruAppHostFrameSummary *out_summary
);
int32_t maru_macos_app_session_close(
    MaruAppHostSession *session,
    MaruAppHostFrameSummary *out_summary
);
/* 빨간 닫기 버튼/창 단위 닫기 요청(windowShouldClose). 닫힐 창(세션)에 실행 중인 명령이 있으면 Zig가 확인 모달을
   열고 1(deferred)을 돌려준다 — Swift는 false를 반환해 닫기를 보류하고, 모달 확정 시 tick의 session-ended가 실제로
   창을 닫는다. 실행 중 명령이 없으면 0 — Swift가 평소대로 닫는다(windowWillClose → terminate/teardown). */
int32_t maru_macos_app_session_request_window_close(
    MaruAppHostSession *session
);
/* 앱 전체 종료 확인 요청(Cmd+Q/메뉴 "Quit maru"/Dock·로그아웃 → applicationShouldTerminate). 창 닫기와 달리 실행 중
   명령 유무와 무관하게 항상 "maru를 종료할까요?" 확인 모달을 띄운다. Swift는 이 호출 뒤 .terminateLater를 돌려주고,
   모달 확정/취소가 다음 tick FrameSummary.quit_decision(1=accepted·2=cancelled)에 실리면 NSApp.reply로 진행/취소한다. */
void maru_macos_app_session_request_app_quit(
    MaruAppHostSession *session
);
/* 휠 스크롤. Swift는 raw 델타(포인트, 세로 delta_y·가로 delta_x)·정밀 델타 여부(0/1)·마우스 위치(backing px)만
   넘기고, 줄/열 환산과 어느 panel로 보낼지(커서 아래 pane — split의 비활성 panel 위 휠도 그 panel로 라우팅)는
   Zig가 한다. delta_y는 그 panel 터미널 스크롤백, delta_x는 그 pane 탭 바 가로 스크롤(탭이 넘칠 때만). 단일
   panel이면 활성과 같고, 사이드바/밖이면 활성 panel로 fallback. */
int32_t maru_macos_app_session_scroll_wheel(
    MaruAppHostSession *session,
    double delta_y,
    double delta_x,
    int32_t precise,
    double x_px,
    double y_px
);
/* 한 화면씩 스크롤(Shift+PageUp/Down). delta_pages>0=위(과거). 한 화면(rows-1) 계산은 app session이
   권위 있는 rows로 한다. */
int32_t maru_macos_app_session_scroll_page(
    MaruAppHostSession *session,
    int32_t delta_pages
);
/* 창 포커스 변화(OS window key/resign). gained!=0=포커스 얻음. focus reporting(DECSET 1004)이 켜진 surface면
   CSI I(gained)/CSI O(lost)를 PTY로 흘린다(vim FocusGained/Lost). Swift가 windowDidBecomeKey/windowDidResignKey에서 호출. */
int32_t maru_macos_app_session_focus_changed(
    MaruAppHostSession *session,
    int32_t gained
);
/* 이전(dir<0)/다음(dir>0) 프롬프트 블록으로 뷰포트 점프(OSC 133 semantic prompt — Cmd+↑/↓).
   분류·이동은 app session/core가 하고 Swift는 방향만 넘긴다. */
int32_t maru_macos_app_session_jump_prompt(
    MaruAppHostSession *session,
    int32_t dir
);
/* 마우스 선택(셀렉션) 또는 mouse reporting. kind 1=down 2=drag 3=up 4=더블클릭(단어) 5=트리플클릭(논리 줄).
   button 0=left 1=middle 2=right(셀렉션은 left만 의미). mods 비트(xterm): 4=shift 8=meta/alt 16=ctrl.
   mouse tracking(DECSET 1000~1003)이 켜졌고 shift 미포함이면 셀렉션 대신 앱에 SGR/x10 리포트한다 —
   shift+click은 xterm 관례대로 셀렉션 override. 좌표는 backing 픽셀(좌상단 원점), 셀 변환은 Zig가 한다. */
int32_t maru_macos_app_session_mouse(
    MaruAppHostSession *session,
    int32_t kind,
    double x_px,
    double y_px,
    int32_t button,
    int32_t mods
);
/* 버튼 없는 마우스 이동(hover, backing px). Zig가 mouse tracking을 확인해 any-event(DECSET 1003)일 때만
   SGR/x10 motion 리포트한다(아니면 no-op). 같은 셀 반복 이동은 Zig가 스킵한다. mods 비트는 mouse와 동일. */
void maru_macos_app_session_mouse_moved(
    MaruAppHostSession *session,
    double x_px,
    double y_px,
    int32_t mods
);
/* 선택 텍스트 추출(UTF-8). 반환 버퍼는 Zig 소유로 다음 copy_text 또는 destroy까지 유효하다.
   선택이 없으면 *out_ptr=NULL, *out_len=0. Swift가 NSPasteboard에 쓴다(클립보드는 OS 소유). */
/* 클립보드 붙여넣기(UTF-8) — Cmd+V paste와 드래그앤드롭 경로 삽입 공용. 개행 정규화(\n→\r)와 bracketed
   paste(DECSET 2004) 감싸기는 Zig가 한다 — Swift는 NSPasteboard에서 읽은 바이트만 넘긴다.
   escape_each!=0이면 bytes를 NUL('\0') 구분 토큰으로 보고 각 토큰을 셸 이스케이프한 뒤 공백으로 join한다
   (드래그된 파일 경로·URL — 셸이 공백 등 메타문자에서 단어를 쪼개지 않게). 평문·Cmd+V 웹 URL은 0(raw)으로
   넘긴다(이스케이프하면 ?,&,= 등이 깨진다). 이스케이프 메커니즘은 Zig가 단일 출처다(v67). */
int32_t maru_macos_app_session_paste_text(
    MaruAppHostSession *session,
    const uint8_t *bytes,
    size_t len,
    uint32_t escape_each
);
/* 드래그앤드롭한 파일 경로들(NUL 구분). maru ssh 원격이면 control socket으로 업로드 후 원격 절대경로를
   paste하고, 로컬이면 경로를 셸 이스케이프해 paste한다(분기는 Zig). Swift는 fileURL 드롭일 때만 부른다
   (웹 URL·텍스트는 paste_text 유지). (v68) */
int32_t maru_macos_app_session_drop_files(
    MaruAppHostSession *session,
    const uint8_t *bytes,
    size_t len
);
/* 클립보드 이미지(Cmd+V). maru ssh 원격이면 control socket 업로드 후 원격 경로 paste(1 반환),
   로컬/미처리면 0(Swift가 기존 paste 진행). 파일 드롭과 달리 바이트를 직접 받는다. */
int32_t maru_macos_app_session_drop_image(
    MaruAppHostSession *session,
    const uint8_t *bytes,
    size_t len
);
/* chrome Notice 모달(손상 알림 등)을 연다(UTF-8 메시지). 워크스페이스 복원 손상(window_count<0)을 감지하면
   Swift가 부른다. 세션이 메시지를 복사 소유하므로 호출 뒤 버퍼는 해제해도 된다. len==0이면 무동작. (v40) */
int32_t maru_macos_app_session_show_notice(
    MaruAppHostSession *session,
    const uint8_t *bytes,
    size_t len
);
/* Cmd+클릭 위치의 URL(backing px). 단어 경계(soft-wrap 포함)에서 http(s)를 찾아 끝 문장부호를
   다듬은 결과. 버퍼는 Zig 소유(다음 url_at/destroy까지 유효), 없으면 *out_len=0. */
/* IME 키 트랜잭션(v20): keyDown은 begin -> interpretKeyEvents -> end 순서. 입력기 콜백은
   insert(확정 누적)/marked(조합 표시)로 쌓고, 판정(전송/무시/인코딩)은 전부 Zig가 한다. */
int32_t maru_macos_app_session_ime_begin(MaruAppHostSession *session);
int32_t maru_macos_app_session_ime_insert(
    MaruAppHostSession *session,
    const uint8_t *bytes,
    size_t len
);
int32_t maru_macos_app_session_ime_marked(
    MaruAppHostSession *session,
    const uint8_t *bytes,
    size_t len
);
int32_t maru_macos_app_session_ime_end(
    MaruAppHostSession *session,
    const MaruAppHostKeyEvent *event
);
/* IME 후보창 배치용 커서 셀 사각형(backing px, 좌상단 원점). Swift가 화면 좌표로 변환한다. */
int32_t maru_macos_app_session_ime_cursor_rect(
    MaruAppHostSession *session,
    double *out_x,
    double *out_y,
    double *out_w,
    double *out_h
);
/* IME deleteBackward 편집 명령. 한글 마지막 자모 백스페이스(insertText+deleteBackward 상쇄)에 쓴다. */
int32_t maru_macos_app_session_ime_delete_backward(MaruAppHostSession *session);
/* 포커스 변화. 잃으면(0) 조합 중 텍스트를 확정 커밋한다. */
int32_t maru_macos_app_session_set_focus(MaruAppHostSession *session, int32_t focused);
/* 세팅 등 chrome 오버레이/keybind 녹음 열림(1) — Swift performKeyEquivalent가 메뉴바 keyEquivalent를 양보할지 판정
   (1이면 ⌘조합을 keyDown 경로로 보내 모달 입력 차단·chord 녹음이 동작). */
int32_t maru_macos_app_session_any_overlay_open(MaruAppHostSession *session);
/* 진행 중 IME 조합을 확정(커밋)한다. IME 우회 특수키/단축키 직전에 호출. */
int32_t maru_macos_app_session_commit_composition(MaruAppHostSession *session);
/* 마우스 호버 갱신(backing px). *out_cursor_kind에 위치별 커서 종류(0=arrow/사이드바·탭 바, 1=iBeam/터미널,
   2=pointingHand/URL hover, 3=resizeLeftRight/세로 divider, 4=resizeUpDown/가로 divider, 5=openHand/pane grip 호버).
   Swift가 이 값으로
   NSCursor를 세운다. Zig는 부수적으로 사이드바 슬롯·pane 탭 호버·URL 밑줄을 갱신한다. mods는 마우스 수식키 비트
   (xterm 규약: shift=4, alt=8, ctrl=16, cmd=32) — Zig가 config input.url-click-modifier와 비교해 URL 밑줄을 켠다
   (v71: 옛 cmd_held bool 대체). 수식키 불일치면 URL 호버 해제. 창 밖이면 음수 sentinel(-1,-1)로 호버 해제. */
int32_t maru_macos_app_session_hover(
    MaruAppHostSession *session,
    double x_px,
    double y_px,
    int32_t mods,
    int32_t *out_cursor_kind
);
/* (config 수식키)+클릭 위치의 링크. mods(hover와 같은 xterm 비트)가 url-click-modifier와 안 맞으면 *out_len=0
   (일반 클릭으로 처리). 버퍼는 Zig 소유(다음 url_at/destroy까지). *out_kind는 링크 종류(0=url, 1=file_path) —
   *out_len>0일 때만 유효하고, Swift가 1이면 URL(fileURLWithPath:)·아니면 URL(string:)으로 연다(out_kind는 NULL 허용).
   v71: mods 인자 추가(modifier 판정 Zig 단일 출처). v89: out_kind 추가(파일 경로 링크 — docs/link-detection.md). */
int32_t maru_macos_app_session_url_at(
    MaruAppHostSession *session,
    double x_px,
    double y_px,
    int32_t mods,
    const uint8_t **out_ptr,
    size_t *out_len,
    int32_t *out_kind
);
int32_t maru_macos_app_session_copy_text(
    MaruAppHostSession *session,
    const uint8_t **out_ptr,
    size_t *out_len
);
/* OSC 52 클립보드 쓰기 데이터(디코드된 UTF-8). 버퍼는 Zig 소유로 다음 pending_clipboard/destroy까지 유효,
   write는 정책상 기본 allow(terminal-compatibility-policy.md §OSC52). 데이터 없으면 *out_ptr=NULL, *out_len=0.
   Swift가 tick마다 호출해 NSPasteboard에 쓴다. */
int32_t maru_macos_app_session_pending_clipboard(
    MaruAppHostSession *session,
    const uint8_t **out_ptr,
    size_t *out_len
);
/* OSC 9/777·에이전트 완료 데스크톱 알림 데이터(title, body, UTF-8, surface_id, foreground). *has=1이면 알림 있음
   (title은 빈 문자열일 수 있어 len으로 판단), 0이면 없음. *surface_id=발신 Term의 surface.id로, Swift가 알림
   userInfo에 (창 토큰, surface_id)로 실어 클릭 시 발신 터미널로 점프한다(activate_surface). *foreground=앱이 전면일
   때도 배너로 띄울지(1=에이전트 완료 / 0=OSC, 전면이면 목록만) — Swift willPresent가 읽는다. 버퍼는 Zig 소유로 다음
   pending_notification/destroy까지 유효. Swift가 tick마다 호출해 UNUserNotificationCenter로 띄운다(알림은 OS 소유). v76. */
int32_t maru_macos_app_session_pending_notification(
    MaruAppHostSession *session,
    uint32_t *has,
    const uint8_t **title_ptr,
    size_t *title_len,
    const uint8_t **body_ptr,
    size_t *body_len,
    uint64_t *surface_id,
    uint32_t *foreground
);
/* 데스크톱 알림 클릭 → 발신 surface로 활성화. Swift가 알림 userInfo의 (창 토큰, surface_id)에서 토큰으로 올바른
   창/세션을 고른 뒤(창 키 활성화는 Swift), 이 세션에 surface_id를 넘긴다. Zig가 (탭/panel/Term)을 역조회해 그
   자리로 포커스한다(switchTab→focusPaneByPtr→focusTerm). 찾아 활성화했으면 1, 이미 닫혔으면 0(무동작). session
   null=0. take_bell과 같은 u32 반환(found 여부). v76. */
uint32_t maru_macos_app_session_activate_surface(MaruAppHostSession *session, uint64_t surface_id);
/* G12 BEL: 활성 세션에 pending 벨이 있으면 1(코어 플래그 비움), 없으면 0. Swift가 tick마다 호출해 시스템 벨
   (NSSound.beep)을 울린다(벨은 OS 소유). */
uint32_t maru_macos_app_session_take_bell(MaruAppHostSession *session);
/* Dock 배지 1회성 신호(config bell.dock-badge). BEL이 창 포커스 없을 때 울리면 1, 아니면 0. Swift가 매 tick 호출해
   1이면 NSApp.dockTile.badgeLabel을 ●로 세운다(포커스 복귀 시 Swift가 지움). take_bell과 같은 1회성. session null=0. v76. */
uint32_t maru_macos_app_session_take_bell_badge(MaruAppHostSession *session);
/* 세팅 GUI에서 데스크톱 알림 토글(notifications.agent-complete/osc)을 켠 경우 macOS 알림 권한 요청을 Swift에 맡기는
   1회성 신호. pending이면 1(플래그 비움), 없으면 0. Swift가 tick마다 호출해 1이면 UNUserNotificationCenter 권한 요청을
   시도한다. session null=0. v92. */
uint32_t maru_macos_app_session_take_notification_authorization_request(MaruAppHostSession *session);
/* macOS 시스템 외관(NSAppearance)이 다크(is_dark!=0)/라이트(0)인지 Swift가 알려준다(생성 직후·외관 변경마다). config
   theme.follow-system이 켜져 있으면 Zig가 theme.preset-light/dark 색으로 라이브 교체(꺼져 있으면 무시). session null=무동작. v77. */
int32_t maru_macos_app_session_set_system_appearance(MaruAppHostSession *session, int32_t is_dark);
/* 창 뒤(데스크톱) 배경 블러의 유효 반경(px) — config window.blur, 단 window.opacity>=1이면 0(불투명 창=블러 안 보임).
   블러는 GPU가 아니라 OS 창 속성이라(Metal은 backdrop을 못 읽음) host가 이 값을 OS API에 싣는다: macOS=CGSSetWindow-
   BackgroundBlurRadius(Ghostty·Terminal.app과 동일 비공개 CGS), Win=DwmSetWindowAttribute·Linux=컴포지터 속성(추후).
   게이트 정책은 Zig 단일 출처. 라이브 read(reload 갱신). session null=0(블러 끔). v79. */
uint32_t maru_macos_app_session_window_blur_radius(MaruAppHostSession *session);
/* macOS app host frame-loop cadence(config render.frame-rate). Swift가 NSTimer 간격을 정할 때 읽는 config 희망값이다.
   실제 tick 시간 환산은 maru_macos_app_session_tick의 frame_loop_rate_hz 인자로 받은 host 전역 cadence를 쓴다.
   session null=기본 60Hz. v91/v93. */
uint32_t maru_macos_app_session_frame_rate_hz(MaruAppHostSession *session);
/* 타이핑(글자 입력) 중 마우스 숨김 1회성 신호(config input.mouse-hide-while-typing). pending이면 1(플래그 비움),
   없으면 0. Swift가 tick마다 호출해 1이면 NSCursor.setHiddenUntilMouseMoves(true)(다음 마우스 이동에서 자동 복원). v72. */
uint32_t maru_macos_app_session_take_mouse_hide(MaruAppHostSession *session);
/* macOS Option을 Meta(Alt)로 쓰는지(config input.option-as-meta). 1=meta(현행 — Option+키 ESC-prefix),
   0=조합(입력기에 맡겨 특수문자 조합). Swift keyDown이 호출해 Option-단독 키를 입력기 경로(0)/meta 인코딩(1)으로
   가른다. 1회성 신호가 아니라 라이브 config read(reload로 갱신). session null=1(meta 폴백). v73. */
uint32_t maru_macos_app_session_option_as_meta(MaruAppHostSession *session);
/* 단축키 힌트 홀드 상태머신(keyhint_hold.zig)에 이벤트를 흘리고 Action을 돌려준다. 반환(0=none·1=arm_timer·2=cancel·
   3=show·4=hide): Swift가 1=OS 타이머 시작·2/4=타이머 무효화·3/4=markMetalNeedsRedraw로 매핑(visible 토글은 머신 소유).
   gesture 정책=Zig·OS clock만 Swift. mods_bits=현재 눌린 modifier 비트(shift=1·control=2·option=4·command=8). session
   null=0(none). **루트커즈**: 옛 set_key_hints 경로는 타이머 만료 때 Swift가 NSEvent.modifierFlags(2번째 출처)를 재읽기해
   stale/빈 값이면 미표시였다 — 이제 머신이 flagsChanged 단일 출처로 판정, 만료는 글로벌을 안 읽는다(armed=유지됨). v88. */
int32_t maru_macos_app_session_key_hint_on_flags(MaruAppHostSession *session, uint32_t mods_bits);
/* 타이머 만료 → 머신. armed면 show(글로벌 재읽기 없음). session null=0(none). v88. */
int32_t maru_macos_app_session_key_hint_on_timer(MaruAppHostSession *session);
/* keyDown(실제 단축키)·포커스 상실 → 머신 취소(표시 중이면 hide). session null=0(none). v88. */
int32_t maru_macos_app_session_key_hint_cancel(MaruAppHostSession *session);
/* 단축키 힌트 config — out_enabled(1/0)·out_delay_ms·out_modifier(0=command·1=control·2=option)에 채운다. Swift 홀드
   감지가 읽어 동작 결정(gesture 정책=Zig·타이머 clock=Swift). 라이브 read. out 포인터 null이면 건너뜀. session null=null_out. v87. */
int32_t maru_macos_app_session_key_hints_config(MaruAppHostSession *session, uint32_t *out_enabled, uint32_t *out_delay_ms, uint32_t *out_modifier);
/* OS 클립보드 1회성 동작(input.right-click=paste·menu). 0=무동작, 1=copy, 2=paste. Zig가 우클릭/터미널 메뉴에서
   세우고 Swift가 매 tick 호출해 1=copySelectionToPasteboard·2=pastePasteboardText. take_bell과 같은 1회성(drain하면
   비움). session null=0. v74. */
uint32_t maru_macos_app_session_take_clipboard_action(MaruAppHostSession *session);
/* OSC 52 읽기(`?` 쿼리)가 대기 중이고 osc52.read=allow면 1(Swift가 시스템 클립보드를 읽어 provide_clipboard_read로
   돌려줘야 함), 아니면 0. 정책 게이트가 여기다(deny면 클립보드 안 읽음 — 탈취 방지). pending 1회성 소비. session null=0. v75. */
uint32_t maru_macos_app_session_take_clipboard_read_request(MaruAppHostSession *session);
/* take_clipboard_read_request가 1을 준 뒤 Swift가 읽은 시스템 클립보드 바이트를 넘긴다 — Zig가 base64 OSC 52 응답을
   요청 surface PTY로 비차단 전송한다(ESC ] 52 ; <Pc> ; <base64> ST). bytes/len 0이면 빈 클립보드 응답. v75. */
int32_t maru_macos_app_session_provide_clipboard_read(MaruAppHostSession *session, const uint8_t *bytes, size_t len);
/* 세팅 window.background-image 행 활성으로 파일 선택창 요청이 대기 중이면 1(플래그 비움), 없으면 0. Swift가 tick마다
   호출해 1이면 NSOpenPanel(PNG)을 열어 고른 경로를 provide_picked_file로 되돌린다. take_bell과 같은 1회성. session null=0. v81. */
uint32_t maru_macos_app_session_take_file_pick_request(MaruAppHostSession *session);
/* take_file_pick_request가 1을 준 뒤 Swift가 NSOpenPanel에서 고른 파일의 절대경로를 넘긴다 — Zig가 window.background-image에
   setText + 라이브 반영 + dirty(영속). bytes/len 0(취소 등)이면 무동작. 지우기는 행 Backspace가 담당. v81. */
int32_t maru_macos_app_session_provide_picked_file(MaruAppHostSession *session, const uint8_t *bytes, size_t len);
/* HSV picker `i`(스포이드)로 화면 색 추출 요청이 대기 중이면 1(플래그 비움), 없으면 0. Swift가 tick마다 호출해 1이면
   NSColorSampler(OS 화면 색 추출기)를 열고 고른 색을 provide_sampled_color로 되돌린다. take_bell과 같은 1회성. session null=0. v83. */
uint32_t maru_macos_app_session_take_color_sample_request(MaruAppHostSession *session);
/* take_color_sample_request가 1을 준 뒤 Swift NSColorSampler 콜백이 고른 화면 픽셀 RGB(각 0~255, u8로 truncate)를
   넘긴다(비동기) — Zig가 picker 선택값(pick h/s/v)에 반영한다. picker가 닫혔으면 무시. v83. */
int32_t maru_macos_app_session_provide_sampled_color(MaruAppHostSession *session, uint32_t r, uint32_t g, uint32_t b);
/* view options(⚙) 사이드바 토글(show-branch/show-folder)이 바뀌어 config 반영이 필요하면 1(플래그 비움),
   없으면 0. Swift가 tick마다 호출해 1이면 serialize_sidebar_config 텍스트를 config 경로에 atomic write한다. */
uint32_t maru_macos_app_session_take_sidebar_config_dirty(MaruAppHostSession *session);
/* (x,y backing px)가 사이드바 헤더의 빈 영역(아이콘·검색 아님)이면 1 — Swift가 1이면 창 이동(performDrag)·더블클릭
   확대(zoom)를 한다(네이티브 타이틀바 대체; MaruMetalTerminalView.mouseDownCanMoveWindow=false라 콘텐츠 자동
   드래그 없음). 사이드바 접힘/헤더 없음이면 0. */
uint32_t maru_macos_app_session_is_window_drag_region(MaruAppHostSession *session, double x_px, double y_px);
/* OSC 7로 셸이 보고한 현재 작업 디렉터리(percent-decode된 경로, UTF-8). 버퍼는 Zig(core) 소유로
   다음 OSC 7/RIS/destroy까지 유효, 없으면 *out_ptr=NULL, *out_len=0. Swift가 창 제목에 쓴다. */
int32_t maru_macos_app_session_cwd(
    MaruAppHostSession *session,
    const uint8_t **out_ptr,
    size_t *out_len
);
/* config 파일 경로(Open Config 메뉴). MARU_CONFIG override 또는 $HOME/.config/maru/config — 규칙은 Zig
   loader가 단일 출처. 버퍼는 Zig 소유로 destroy까지 유효, 없으면 *out_ptr=NULL, *out_len=0. Swift가 파일을
   (없으면 생성) 기본 편집기로 연다(파일 열기는 OS 동작). */
int32_t maru_macos_app_session_config_path(
    MaruAppHostSession *session,
    const uint8_t **out_ptr,
    size_t *out_len
);
/* Reload Config 메뉴 — config 파일을 재로드해 재시작 없이 반영(폰트·여백·테마·palette·scrollback·bell·page-keys).
   파싱은 forgiving, 로드 실패면 무동작(기존 config 유지)이라 항상 Status.ok. 규칙은 Zig loader가 단일 출처. */
int32_t maru_macos_app_session_reload_config(MaruAppHostSession *session);
/* Reset to Defaults 메뉴 — 확인 모달을 연다(커맨드 팝업 "Reset All Settings to Defaults"와 같은 경로). 확정 시 모든
   config를 내장 기본값으로 되돌리고 config 파일을 기본 상태로 덮어쓴다(파괴적이라 무확인 즉시 실행 안 함). 항상 Status.ok. */
int32_t maru_macos_app_session_reset_defaults(MaruAppHostSession *session);
/* Reset 메뉴(⌘⇧R) — 활성 터미널의 잔류 입력 모드(focus 1004·mouse·kitty keyboard)만 끈다. ssh 너머 TUI가
   SIGKILL로 죽어 정리 못 한 모드가 raw 셸 입력을 오염(포커스마다 CSI I·비프)시키는 증상의 수동 회복.
   화면·스크롤백 보존(fullReset과 다름). 항상 ok. */
int32_t maru_macos_app_session_reset_input_modes(MaruAppHostSession *session);
/* 창 제목 문자열(OSC 0/2 제목 우선, 없으면 OSC 7 cwd basename; UTF-8). 우선순위는 core가 정한다.
   버퍼는 Zig(core) 소유로 다음 OSC 0/2/7·RIS·destroy까지 유효, 없으면 *out_len=0(Swift가 앱 이름
   폴백). Swift가 window.title에 쓴다. */
int32_t maru_macos_app_session_window_title(
    MaruAppHostSession *session,
    const uint8_t **out_ptr,
    size_t *out_len
);

/* 이 창(세션)의 workspace restore 블록(헤더 없는 "window ..." 라인; UTF-8). Swift가 멀티 창 저장에서
   maru.workspace.v1 헤더 하나 아래로 각 세션 블록을 모은다. 버퍼는 Zig 소유로 다음 호출/destroy까지 유효,
   캡처/직렬화 실패·빈 경우 *out_len=0(Swift가 그 창을 건너뜀). 정상 종료(applicationWillTerminate) 시 저장. */
int32_t maru_macos_app_session_serialize_workspace(
    MaruAppHostSession *session,
    const uint8_t **out_ptr,
    size_t *out_len
);

/* 현재 sidebar 토글(show-branch/show-folder)을 반영한 갱신 config 텍스트(UTF-8)를 직렬화한다 — Swift가
   maru_macos_app_session_config_path 경로에 atomic write한다(앱 view options 토글 → config 파일 양방향).
   원본 config를 부분 갱신하므로 주석·미파싱 키를 보존한다. 버퍼는 Zig 소유로 다음 호출/destroy까지 유효,
   직렬화 실패·빈 경우 *out_len=0(Swift가 write를 건너뜀). */
int32_t maru_macos_app_session_serialize_sidebar_config(
    MaruAppHostSession *session,
    const uint8_t **out_ptr,
    size_t *out_len
);

/* 저장된 workspace 텍스트(헤더 + N개 창; UTF-8)의 창 개수를 센다(Swift가 창마다 NSWindow 생성). 헤더·포맷
   검증도 겸한다: parse 실패(헤더 불일치·손상)면 -1(Swift가 복원 건너뜀), 0이면 빈 workspace. 포맷 파싱은 Zig
   단일 권위 — Swift는 'window ' 경계를 직접 나누지 않는다. */
int64_t maru_macos_app_session_workspace_window_count(
    MaruAppHostSession *session,
    const uint8_t *text_ptr,
    size_t text_len
);

/* 시작 시 저장된 workspace 텍스트(헤더 + N개 창; UTF-8)에서 window_index번째 창을 parse해 이 세션에 복원
   적용한다. Swift는 전체 텍스트와 인덱스만 넘긴다(창 경계 분할은 Zig가 소유 — 파싱 권위 단일화). 0=ok,
   parse 실패·인덱스 범위 밖=invalid_config, apply 실패=create_failed. best-effort라 실패해도 기본 단일 탭. */
int32_t maru_macos_app_session_apply_workspace_window(
    MaruAppHostSession *session,
    const uint8_t *text_ptr,
    size_t text_len,
    size_t window_index
);

/* 전역(OS) 단축키 한 개의 등록 기술자. Swift가 Carbon RegisterEventHotKey(carbon_modifiers,
   virtual_key_code, ...)로 등록하고, 눌리면 action을 수행한다. action: 0=toggle_window(창 토글),
   1=show_window(항상 앞으로). 가상 키코드로 매핑되는 chord만 목록에 담긴다(나머지는 제외). */
typedef struct MaruAppHostGlobalHotkey {
    uint32_t virtual_key_code; /* macOS 가상 키코드(kVK_*) — RegisterEventHotKey inHotKeyCode */
    uint32_t carbon_modifiers; /* Carbon modifier mask(cmdKey 등) — RegisterEventHotKey inHotKeyModifiers */
    uint32_t action;           /* MaruAppHostGlobalAction */
} MaruAppHostGlobalHotkey;

/* 전역 단축키 action 종류(MaruAppHostGlobalHotkey.action). config GlobalAction과 같은 순서. */
typedef enum MaruAppHostGlobalAction {
    MaruAppHostGlobalActionToggleWindow = 0,        /* 숨김/비활성이면 보이고 앞으로, 활성+보임이면 숨김 */
    MaruAppHostGlobalActionShowWindow = 1,          /* 항상 보이고 앞으로(숨기지 않음) */
    MaruAppHostGlobalActionToggleQuickTerminal = 2, /* quick terminal(별도 세션 오버레이 패널) 토글 */
} MaruAppHostGlobalAction;

/* 전역 단축키 등록 기술자 목록. config에서 한 번 만들어 세션 동안 불변이라 Swift가 시작 시 한 번 읽어
   등록한다. 배열은 app session 소유로 destroy까지 유효. 비어 있으면 out_hotkeys=NULL·out_count=0. */
int32_t maru_macos_app_session_global_hotkeys(
    MaruAppHostSession *session,
    const MaruAppHostGlobalHotkey **out_hotkeys,
    size_t *out_count
);

/* 전역(OS) 단축키가 라이브로 바뀌어(세팅 GUI 녹음/해제·reload·reset) OS 재등록이 필요하면 1(플래그 비움), 없으면 0.
   Swift가 tick마다 호출해 1이면 unregisterGlobalHotkeys 후 registerGlobalHotkeys로 새 global_hotkeys를 OS에 다시
   등록한다. take_bell과 같은 1회성 신호(drain하면 비워진다). session null=0. v82. */
uint32_t maru_macos_app_session_take_global_hotkeys_dirty(MaruAppHostSession *session);

/* 커맨드 카탈로그가 런타임에 재빌드돼(keybind rebind/unbind·reload·reset → rebuildCommandCatalog) 메뉴바 재빌드가
   필요하면 1(플래그 비움), 없으면 0. Swift가 tick마다 호출해 1이면 buildMainMenu로 NSMenu keyEquivalent를 새
   카탈로그로 다시 깐다(reset은 확인 모달-확정 후 tick에서 갱신 — 동기 호출 아님). take_*_dirty류 1회성. session null=0. v85. */
uint32_t maru_macos_app_session_take_command_catalog_dirty(MaruAppHostSession *session);

/* quick terminal(전역 토글 오버레이 패널) 표시 옵션. config에서 파싱되어 세션 동안 불변. Swift가 패널
   크기·화면·자동 숨김에 쓴다. screen: 0=main(주 디스플레이), 1=mouse(마우스가 있는 화면). */
typedef struct MaruAppHostQuickTerminalConfig {
    uint32_t height_milli; /* 가장자리에 수직인 '두께' 비율 × 1000 (top/bottom=높이, left/right=폭) */
    uint32_t auto_hide;    /* 0/1 — 포커스 잃으면 자동 숨김 */
    uint32_t screen;       /* MaruAppHostQuickTerminalScreen */
    uint32_t position;     /* MaruAppHostQuickTerminalPosition */
    uint32_t chrome;       /* MaruAppHostQuickTerminalChrome — Swift가 quick 세션 생성 시 chrome_minimal로 넘긴다 */
    uint32_t minimal_tabs; /* 0/1 — minimal에서 탭 허용. Swift가 quick 세션 생성 시 minimal_tabs로 넘긴다 */
    uint32_t width_milli;  /* center 가로 비율 × 1000. 0이면 미설정 → Swift가 height로 폴백(정사각). center 외 무시 */
} MaruAppHostQuickTerminalConfig;

typedef enum MaruAppHostQuickTerminalScreen {
    MaruAppHostQuickTerminalScreenMain = 0,  /* 주 디스플레이 */
    MaruAppHostQuickTerminalScreenMouse = 1, /* 마우스 포인터가 있는 화면 */
} MaruAppHostQuickTerminalScreen;

typedef enum MaruAppHostQuickTerminalPosition {
    MaruAppHostQuickTerminalPositionTop = 0,    /* 상단 가장자리(전폭) */
    MaruAppHostQuickTerminalPositionBottom = 1, /* 하단 가장자리(전폭) */
    MaruAppHostQuickTerminalPositionLeft = 2,   /* 좌측 가장자리(전고) */
    MaruAppHostQuickTerminalPositionRight = 3,  /* 우측 가장자리(전고) */
    MaruAppHostQuickTerminalPositionCenter = 4, /* 화면 중앙(width·height 둘 다 비율) — 슬라이드 없이 페이드 */
} MaruAppHostQuickTerminalPosition;

typedef enum MaruAppHostQuickTerminalChrome {
    MaruAppHostQuickTerminalChromeFull = 0,    /* 메인 창처럼 사이드바·탭 바를 다 보임 */
    MaruAppHostQuickTerminalChromeMinimal = 1, /* 사이드바·탭 바 없이 터미널 그리드만 */
} MaruAppHostQuickTerminalChrome;

int32_t maru_macos_app_session_quick_terminal_config(
    MaruAppHostSession *session,
    MaruAppHostQuickTerminalConfig *out_config
);

/* 커맨드 카탈로그 한 항목 — 메뉴바·커맨드 팝업이 그릴 액션. 모든 문자열은 app session 소유(destroy까지
   유효). action_key는 선택 시 run_action으로 되돌려보내는 식별자, title은 표시명, key_display는 현재
   바인딩(없으면 ""). 배열은 config/액션에서 한 번 만들어 세션 동안 불변. */
typedef struct MaruAppHostCommand {
    const char* action_key;
    const char* title;
    const char* key_display;    /* 팝업 표시용 사람-읽는 chord("⌘T"), 없으면 "" */
    const char* key_equivalent; /* NSMenuItem.keyEquivalent 문자열(소문자 글자/화살표 unichar), 없으면 "" */
    uint32_t key_modifiers;     /* 비트마스크 shift=1, control=2, option=4, command=8 → NSEvent.ModifierFlags */
} MaruAppHostCommand;

/* 커맨드 카탈로그 목록. config/액션에서 한 번 만들어 세션 동안 불변이라 Swift가 시작 시 한 번 읽는다.
   배열·문자열 전부 app session 소유(destroy까지 유효). 비어 있으면 out_commands=NULL/out_count=0. */
int32_t maru_macos_app_session_command_catalog(
    MaruAppHostSession *session,
    const MaruAppHostCommand **out_commands,
    size_t *out_count
);
/* 메뉴/팝업이 고른 액션 한 개를 실행한다 — action_key 바이트(카탈로그가 준 식별자)를 받아 Zig가
   parseAction → dispatch. 모르는 키면 InvalidConfig(무동작). 키→실행 결정은 Zig 소유(Swift는 문자열만 왕복). */
int32_t maru_macos_app_session_run_action(
    MaruAppHostSession *session,
    const uint8_t *bytes,
    size_t len
);
void maru_macos_app_session_destroy(MaruAppHostSession *session);
int32_t maru_macos_app_session_metal_frame(
    MaruAppHostSession *session,
    MaruAppHostMetalFrame *out_frame
);

#endif
