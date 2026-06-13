#ifndef MARU_PLATFORM_MACOS_APP_HOST_ABI_H
#define MARU_PLATFORM_MACOS_APP_HOST_ABI_H

#include <stdint.h>
#include <stddef.h>

/* 이 header는 실제 앱 동작을 구현하지 않고 Swift/Zig 사이의 약속만 고정한다.
   Swift가 AppKit object나 Swift struct layout을 바로 넘기면 Zig 쪽에서 안전하게
   해석할 수 없으므로, 제품 host가 시작되기 전에 fixed-width C record만 허용한다. */
#define MARU_MACOS_APP_HOST_ABI_VERSION 32u

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

typedef enum MaruAppHostDevCommandKind {
    MaruAppHostDevCommandControlledSmoke = 0,
    MaruAppHostDevCommandInteractiveShell = 1,
} MaruAppHostDevCommandKind;

typedef struct MaruAppHostDevSession MaruAppHostDevSession;

typedef struct MaruAppHostDevSessionConfig {
    uint32_t abi_version;
    uint32_t cols;
    uint32_t rows;
    uint32_t queue_capacity;
    uint32_t command_kind;
    /* 1이면 chrome 최소화(사이드바·pane 탭 바 없이 터미널 그리드만) — quick terminal minimal 모드.
       0이면 full chrome(메인 창). 세션별로 정한다 — Swift가 quick_terminal.chrome config를 읽어 quick
       세션 생성 시에만 1로 넘긴다(메인 창은 항상 0). */
    uint32_t chrome_minimal;
} MaruAppHostDevSessionConfig;

typedef struct MaruAppHostDevFrameSummary {
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
       maru_macos_app_dev_session_metal_frame 호출을 건너뛰어 idle tick 비용을 줄일 수 있다. */
    uint32_t metal_generation;
} MaruAppHostDevFrameSummary;

/* 가장 최근 tick의 RenderFrame을 Metal로 그리기 위한 DTO. cell 하나가 atlas slot 1개와 그
   UV 사각형을 가리킨다. layout은 Zig metal_frame.NativeMetalCell과 1:1로 맞춘다. */
typedef struct MaruAppHostDevMetalCell {
    uint16_t row;
    uint16_t col;
    uint16_t width;
    /* overlay 종류: 0=일반 cell, 2=커서 underline(하단 바), 3=커서 bar(좌측 세로 바) — DECSCUSR.
       renderer는 2/3에서 cell의 부분 사각형만 칠한다(글리프를 가리지 않음). */
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
} MaruAppHostDevMetalCell;

/* 한 glyph slot의 raster bytes를 atlas texture에 올리기 위한 업로드 기술자. bytes_offset/
   byte_count는 MaruAppHostDevMetalFrame.raster_pixels 버퍼 안의 범위다. */
typedef struct MaruAppHostDevMetalRasterUpload {
    uint32_t slot_id;
    uint32_t atlas_x_px;
    uint32_t atlas_y_px;
    uint32_t atlas_width_px;
    uint32_t atlas_height_px;
    size_t bytes_offset;
    size_t byte_count;
    size_t bytes_per_row;
    size_t non_clear_pixels;
} MaruAppHostDevMetalRasterUpload;

/* 가장 최근 frame의 Metal view. 모든 포인터는 dev session이 소유한 retained 배열을 가리키며,
   "다음으로 재투영하는 tick"(새 output 또는 resize가 있는 tick) 또는 destroy까지 유효하다.
   idle tick은 재투영하지 않으므로 포인터가 유지되고 generation도 그대로다. close는 이 배열을
   해제하지 않는다(destroy에서만 해제). caller는 같은 main thread에서 동기적으로 소비해야
   한다. generation은 실제 재투영이 일어난 frame에서만 증가하므로, 값이 바뀌었을 때만 atlas
   재업로드/재드로우하면 된다. */
typedef struct MaruAppHostDevMetalFrame {
    uint32_t cols;
    uint32_t rows;
    uint32_t atlas_width_px;
    uint32_t atlas_height_px;
    /* 한 terminal cell의 픽셀 크기(정사각 glyph = font_size_px × device_scale). renderer는
       이 값으로 fixed-cell pixel layout을, host는 resize의 cols/rows 계산을 한다. */
    uint32_t cell_width_px;
    uint32_t cell_height_px;
    uint64_t generation;
    const MaruAppHostDevMetalCell *cells;
    size_t cell_count;
    const MaruAppHostDevMetalRasterUpload *raster_uploads;
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
    const MaruAppHostDevMetalCell *sidebar_cells;
    size_t sidebar_cell_count;
    /* 사이드바 탭 슬롯 한 칸의 픽셀 높이(≈2.5×cell_height). renderer가 사이드바 셀을 cell 높이가 아니라
       이 슬롯 높이로 세로 배치한다(밴드 row i → py=i×slot_h) — cmux식 큰 탭 슬롯. 0이면 cell 높이로 폴백. */
    uint32_t sidebar_slot_height_px;
} MaruAppHostDevMetalFrame;

uint32_t maru_macos_app_host_abi_version(void);
int32_t maru_macos_app_host_capabilities(MaruAppHostCapabilities *out_capabilities);
int32_t maru_macos_app_dev_session_create(
    const MaruAppHostDevSessionConfig *config,
    MaruAppHostDevSession **out_session
);
int32_t maru_macos_app_dev_session_tick(
    MaruAppHostDevSession *session,
    MaruAppHostDevFrameSummary *out_summary
);
int32_t maru_macos_app_dev_session_key_down(
    MaruAppHostDevSession *session,
    const MaruAppHostKeyEvent *event,
    MaruAppHostDevFrameSummary *out_summary
);
int32_t maru_macos_app_dev_session_resize(
    MaruAppHostDevSession *session,
    const MaruAppHostResizeEvent *event,
    MaruAppHostDevFrameSummary *out_summary
);
int32_t maru_macos_app_dev_session_close(
    MaruAppHostDevSession *session,
    MaruAppHostDevFrameSummary *out_summary
);
/* 휠 스크롤. Swift는 raw 델타(포인트)·정밀 델타 여부(0/1)·마우스 위치(backing px)만 넘기고, 줄 수 환산과
   어느 panel로 보낼지(커서 아래 pane — split의 비활성 panel 위 휠을 그 panel로 라우팅)는 Zig가 한다. 단일
   panel이면 활성과 같고, 사이드바/밖이면 활성 panel로 fallback. */
int32_t maru_macos_app_dev_session_scroll_wheel(
    MaruAppHostDevSession *session,
    double delta_y,
    int32_t precise,
    double x_px,
    double y_px
);
/* 한 화면씩 스크롤(Shift+PageUp/Down). delta_pages>0=위(과거). 한 화면(rows-1) 계산은 dev session이
   권위 있는 rows로 한다. */
int32_t maru_macos_app_dev_session_scroll_page(
    MaruAppHostDevSession *session,
    int32_t delta_pages
);
/* 이전(dir<0)/다음(dir>0) 프롬프트 블록으로 뷰포트 점프(OSC 133 semantic prompt — Cmd+↑/↓).
   분류·이동은 dev session/core가 하고 Swift는 방향만 넘긴다. */
int32_t maru_macos_app_dev_session_jump_prompt(
    MaruAppHostDevSession *session,
    int32_t dir
);
/* 마우스 선택. kind 1=down(시작) 2=drag(확장) 3=up(확정 — 드래그 선택에서 이동 없으면 클릭으로
   보고 해제) 4=더블클릭(단어 선택, soft-wrap 경계 너머까지 확장) 5=트리플클릭(논리 줄 선택).
   좌표는 backing 픽셀(좌상단 원점) — 셀 변환은 Zig가 cell 메트릭으로 한다. */
int32_t maru_macos_app_dev_session_mouse(
    MaruAppHostDevSession *session,
    int32_t kind,
    double x_px,
    double y_px
);
/* 선택 텍스트 추출(UTF-8). 반환 버퍼는 Zig 소유로 다음 copy_text 또는 destroy까지 유효하다.
   선택이 없으면 *out_ptr=NULL, *out_len=0. Swift가 NSPasteboard에 쓴다(클립보드는 OS 소유). */
/* 클립보드 붙여넣기(UTF-8). 개행 정규화(\n→\r)와 bracketed paste(DECSET 2004) 감싸기는 Zig가
   한다 — Swift는 NSPasteboard에서 읽은 바이트만 넘긴다. */
int32_t maru_macos_app_dev_session_paste_text(
    MaruAppHostDevSession *session,
    const uint8_t *bytes,
    size_t len
);
/* Cmd+클릭 위치의 URL(backing px). 단어 경계(soft-wrap 포함)에서 http(s)를 찾아 끝 문장부호를
   다듬은 결과. 버퍼는 Zig 소유(다음 url_at/destroy까지 유효), 없으면 *out_len=0. */
/* IME 키 트랜잭션(v20): keyDown은 begin -> interpretKeyEvents -> end 순서. 입력기 콜백은
   insert(확정 누적)/marked(조합 표시)로 쌓고, 판정(전송/무시/인코딩)은 전부 Zig가 한다. */
int32_t maru_macos_app_dev_session_ime_begin(MaruAppHostDevSession *session);
int32_t maru_macos_app_dev_session_ime_insert(
    MaruAppHostDevSession *session,
    const uint8_t *bytes,
    size_t len
);
int32_t maru_macos_app_dev_session_ime_marked(
    MaruAppHostDevSession *session,
    const uint8_t *bytes,
    size_t len
);
int32_t maru_macos_app_dev_session_ime_end(
    MaruAppHostDevSession *session,
    const MaruAppHostKeyEvent *event
);
/* IME 후보창 배치용 커서 셀 사각형(backing px, 좌상단 원점). Swift가 화면 좌표로 변환한다. */
int32_t maru_macos_app_dev_session_ime_cursor_rect(
    MaruAppHostDevSession *session,
    double *out_x,
    double *out_y,
    double *out_w,
    double *out_h
);
/* IME deleteBackward 편집 명령. 한글 마지막 자모 백스페이스(insertText+deleteBackward 상쇄)에 쓴다. */
int32_t maru_macos_app_dev_session_ime_delete_backward(MaruAppHostDevSession *session);
/* 포커스 변화. 잃으면(0) 조합 중 텍스트를 확정 커밋한다. */
int32_t maru_macos_app_dev_session_set_focus(MaruAppHostDevSession *session, int32_t focused);
/* 진행 중 IME 조합을 확정(커밋)한다. IME 우회 특수키/단축키 직전에 호출. */
int32_t maru_macos_app_dev_session_commit_composition(MaruAppHostDevSession *session);
/* 마우스 호버 갱신(backing px). *out_cursor_kind에 위치별 커서 종류(0=arrow/사이드바·탭 바, 1=iBeam/터미널,
   2=pointingHand/Cmd+hover URL, 3=resizeLeftRight/세로 divider, 4=resizeUpDown/가로 divider). Swift가 이 값으로
   NSCursor를 세운다. Zig는 부수적으로 사이드바 슬롯·pane 탭 호버·URL 밑줄을 갱신한다. cmd_held=0이면 URL 호버
   해제. 창 밖이면 음수 sentinel(-1,-1)로 호버 해제. */
int32_t maru_macos_app_dev_session_hover(
    MaruAppHostDevSession *session,
    double x_px,
    double y_px,
    int32_t cmd_held,
    int32_t *out_cursor_kind
);
int32_t maru_macos_app_dev_session_url_at(
    MaruAppHostDevSession *session,
    double x_px,
    double y_px,
    const uint8_t **out_ptr,
    size_t *out_len
);
int32_t maru_macos_app_dev_session_copy_text(
    MaruAppHostDevSession *session,
    const uint8_t **out_ptr,
    size_t *out_len
);
/* OSC 7로 셸이 보고한 현재 작업 디렉터리(percent-decode된 경로, UTF-8). 버퍼는 Zig(core) 소유로
   다음 OSC 7/RIS/destroy까지 유효, 없으면 *out_ptr=NULL/*out_len=0. Swift가 창 제목에 쓴다. */
int32_t maru_macos_app_dev_session_cwd(
    MaruAppHostDevSession *session,
    const uint8_t **out_ptr,
    size_t *out_len
);
/* 창 제목 문자열(OSC 0/2 제목 우선, 없으면 OSC 7 cwd basename; UTF-8). 우선순위는 core가 정한다.
   버퍼는 Zig(core) 소유로 다음 OSC 0/2/7·RIS·destroy까지 유효, 없으면 *out_len=0(Swift가 앱 이름
   폴백). Swift가 window.title에 쓴다. */
int32_t maru_macos_app_dev_session_window_title(
    MaruAppHostDevSession *session,
    const uint8_t **out_ptr,
    size_t *out_len
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
   등록한다. 배열은 dev session 소유로 destroy까지 유효. 비어 있으면 out_hotkeys=NULL·out_count=0. */
int32_t maru_macos_app_dev_session_global_hotkeys(
    MaruAppHostDevSession *session,
    const MaruAppHostGlobalHotkey **out_hotkeys,
    size_t *out_count
);

/* quick terminal(전역 토글 오버레이 패널) 표시 옵션. config에서 파싱되어 세션 동안 불변. Swift가 패널
   크기·화면·자동 숨김에 쓴다. screen: 0=main(주 디스플레이), 1=mouse(마우스가 있는 화면). */
typedef struct MaruAppHostQuickTerminalConfig {
    uint32_t height_milli; /* 가장자리에 수직인 '두께' 비율 × 1000 (top/bottom=높이, left/right=폭) */
    uint32_t auto_hide;    /* 0/1 — 포커스 잃으면 자동 숨김 */
    uint32_t screen;       /* MaruAppHostQuickTerminalScreen */
    uint32_t position;     /* MaruAppHostQuickTerminalPosition */
    uint32_t chrome;       /* MaruAppHostQuickTerminalChrome — Swift가 quick 세션 생성 시 chrome_minimal로 넘긴다 */
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

int32_t maru_macos_app_dev_session_quick_terminal_config(
    MaruAppHostDevSession *session,
    MaruAppHostQuickTerminalConfig *out_config
);
void maru_macos_app_dev_session_destroy(MaruAppHostDevSession *session);
int32_t maru_macos_app_dev_session_metal_frame(
    MaruAppHostDevSession *session,
    MaruAppHostDevMetalFrame *out_frame
);

#endif
