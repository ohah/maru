#ifndef MARU_PLATFORM_MACOS_APP_HOST_ABI_H
#define MARU_PLATFORM_MACOS_APP_HOST_ABI_H

#include <stdint.h>
#include <stddef.h>
#include "metal_cell_policy.h"
#include "session_host_notification_route.h"

/* 이 header는 실제 앱 동작을 구현하지 않고 Swift/Zig 사이의 약속만 고정한다.
   Swift가 AppKit object나 Swift struct layout을 바로 넘기면 Zig 쪽에서 안전하게
   해석할 수 없으므로, 제품 host가 시작되기 전에 fixed-width C record만 허용한다. */
#define MARU_MACOS_APP_HOST_ABI_VERSION 181u
#define MARU_APP_INSTANCE_LEASE_ACQUIRED 0u
#define MARU_APP_INSTANCE_LEASE_HELD 1u
#define MARU_APP_INSTANCE_LEASE_UNSAFE 2u
#define MARU_APP_INSTANCE_LEASE_IO_FAILURE 3u
#define MARU_APP_INSTANCE_LEASE_INVALID_PATH 4u
#define MARU_SESSION_CONFIG_BOOTSTRAP_READY 0u
#define MARU_SESSION_CONFIG_BOOTSTRAP_NO_LEASE 1u
#define MARU_SESSION_CONFIG_BOOTSTRAP_ALREADY_INITIALIZED 2u
#define MARU_SESSION_CONFIG_BOOTSTRAP_LOAD_FAILURE 3u
#define MARU_SESSION_DEFAULT_FALSE_OBSERVATION_NOT_BOOTSTRAPPED 0u
#define MARU_SESSION_DEFAULT_FALSE_OBSERVATION_MATCHED 1u
#define MARU_SESSION_DEFAULT_FALSE_OBSERVATION_RESOLVED_TRUE 2u
#define MARU_SESSION_DEFAULT_FALSE_OBSERVATION_EXPLICIT_OVERRIDE 3u
#define MARU_SESSION_DEFAULT_FALSE_OBSERVATION_CONFIG_PRESENT 4u
#define MARU_FILE_PANEL_MODE_READ 0u
#define MARU_FILE_PANEL_MODE_SOURCE_EDIT 1u
#define MARU_FILE_PANEL_MODE_RICH 2u
#define MARU_FILE_TREE_ROOT_PICK_NONE 0u
#define MARU_FILE_TREE_ROOT_PICK_REPLACE 1u
#define MARU_FILE_TREE_ROOT_PICK_ADD 2u
#define MARU_MERMAID_PROTOCOL_MAX_SOURCE_BYTES 32768u
#define MARU_MERMAID_PROTOCOL_MAX_SVG_BYTES 524288u
#define MARU_MERMAID_PROTOCOL_MAX_REQUEST_FRAME_BYTES 40960u
#define MARU_MERMAID_PROTOCOL_MAX_RESULT_FRAME_BYTES 525312u
#define MARU_MERMAID_MAX_PENDING_JOBS 32u
#define MARU_MERMAID_MAX_PENDING_SOURCE_BYTES 1048576u
#define MARU_MERMAID_MAX_ACCEPTED_SVG_BYTES 2097152u
#define MARU_MERMAID_MAX_TERMINAL_RESULTS 98u
#define MARU_MERMAID_MAX_COMPLETIONS_PER_TICK 8u
#define MARU_MERMAID_COLD_RESPONSE_DEADLINE_MS 5000u
#define MARU_MERMAID_WARM_RESPONSE_DEADLINE_MS 2000u
#define MARU_MERMAID_REPLY_FALLBACK_GRACE_MS 250u
#define MARU_MERMAID_REPLY_FALLBACK_MS 5250u
#define MARU_MERMAID_TAG_HELLO 0u
#define MARU_MERMAID_TAG_HELLO_ACK 1u
#define MARU_MERMAID_TAG_REQUEST 2u
#define MARU_MERMAID_TAG_RESULT 3u
#define MARU_MERMAID_RESULT_OK 0u
#define MARU_MERMAID_RESULT_RENDER_ERROR 1u
#define MARU_MERMAID_TERMINAL_SUPERSEDED 1u
#define MARU_MERMAID_TERMINAL_DEADLINE 2u
#define MARU_MERMAID_TERMINAL_TRANSIENT_FAILURE 3u
#define MARU_MERMAID_TERMINAL_INTEGRITY_FAILURE 4u
#define MARU_MERMAID_TERMINAL_INVALID_RESULT 5u
#define MARU_MERMAID_TERMINAL_CAPACITY_EXCEEDED 6u
#define MARU_MERMAID_TERMINAL_FAILURE_LATCHED 7u
#define MARU_MERMAID_ACTION_NONE 0u
#define MARU_MERMAID_ACTION_TERMINATE_HELPER 1u
#define MARU_MERMAID_ACTION_START_JOB 2u
#define MARU_WEB_KEY_ROUTE_PASS_THROUGH 0u
#define MARU_WEB_KEY_ROUTE_APP_ACTION 1u
#define MARU_WEB_KEY_ROUTE_CONSUME_UNBOUND 2u
#define MARU_WEB_KEY_ROUTE_WEB_EDITOR 3u
#define MARU_APP_ASSET_ROLE_APP 0u
#define MARU_APP_ASSET_ROLE_RENDER 1u
#define MARU_FILE_TREE_TRASH_KIND_REGULAR 1u
#define MARU_FILE_TREE_TRASH_KIND_DIRECTORY 2u
#define MARU_FILE_TREE_TRASH_KIND_SYMLINK 3u
#define MARU_FILE_TREE_TRASH_KIND_OTHER 4u
#define MARU_FILE_TREE_TRASH_OUTCOME_NOT_MOVED 0u
#define MARU_FILE_TREE_TRASH_OUTCOME_MOVED_VERIFIED 1u
#define MARU_FILE_TREE_TRASH_OUTCOME_MOVED_UNVERIFIED 2u
#define MARU_FILE_TREE_PATH_CAPACITY 4096u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_CARD 1u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_RESUME 2u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REVEAL_LOG 3u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_FOCUS_LIVE 4u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_AGENT_SESSIONS 5u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_DOCK_LAUNCHER 6u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_REFRESH 7u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_EXPANDED_SCROLL_ANCHOR 8u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SCOPE_ROW 9u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_SEARCH 10u
#define MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_EXPANDED_CARD 11u

/* browser.wait의 Zig protocol ↔ Swift polling 숫자 계약. app_host_abi.zig 테스트가 L2 상수와 정합을 고정한다. */
#define MARU_BROWSER_WAIT_DEFAULT_TIMEOUT_MS 25000u
#define MARU_BROWSER_WAIT_MAX_TIMEOUT_MS 25000u
#define MARU_BROWSER_WAIT_POLL_INTERVAL_MS 100u

/* workspace 저장 포맷 헤더(첫 줄). Zig(app.workspace.header)·Swift(저장/로드/적용)가 같은 문자열을 써야
   하므로 ABI 버전과 같은 방식으로 여기서 단일 출처화한다 — Zig 크로스체크 테스트가 동기화를 강제한다. */
#define MARU_WORKSPACE_HEADER "maru.workspace.v1"
#define MARU_WORKSPACE_CHECKPOINT_EFFECT_NONE 0u
#define MARU_WORKSPACE_CHECKPOINT_EFFECT_CAPTURE 1u
#define MARU_WORKSPACE_CHECKPOINT_EFFECT_WRITE 2u
#define MARU_WORKSPACE_CHECKPOINT_EFFECT_CANCEL_QUIT 3u
#define MARU_WORKSPACE_CHECKPOINT_EFFECT_REPLY_AND_DETACH 4u
#define MARU_WORKSPACE_CHECKPOINT_REASON_BACKGROUND 0u
#define MARU_WORKSPACE_CHECKPOINT_REASON_FINAL_QUIT 1u
#define MARU_WORKSPACE_CHECKPOINT_NOTICE_NONE 0u
#define MARU_WORKSPACE_CHECKPOINT_NOTICE_CAPTURE_FAILED 1u
#define MARU_WORKSPACE_CHECKPOINT_NOTICE_WRITE_FAILED 2u
#define MARU_WORKSPACE_CHECKPOINT_PUBLISH_COMMITTED 0u

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
    /* cross-window 이동(M3d-2a) 실패 — 잘못된 워크스페이스 인덱스·dst 용량 확보 실패(OOM)·
       범위 밖 워크스페이스(그룹/pinned는 M3d-2a-ii). 이 한 event만 거부이고 세션은 유지된다(fault 아님).
       app_host_abi.zig Status.move_failed=10과 값이 정합해야 한다(ABI 계약 테스트가 강제). */
    MaruAppHostStatusMoveFailed = 10,
} MaruAppHostStatus;

typedef enum MaruAppHostEventKind {
    MaruAppHostEventNone = 0,
    MaruAppHostEventFrameTick = 1,
    MaruAppHostEventKeyDown = 2,
    MaruAppHostEventResize = 3,
    MaruAppHostEventCloseRequested = 4,
    MaruAppHostEventAppShouldTerminate = 5,
} MaruAppHostEventKind;

typedef struct MaruSessionHostWakeSource {
    int32_t fd;
    uint32_t reserved;
    uint64_t host_id_low;
    uint64_t host_id_high;
    uint64_t connection_generation;
} MaruSessionHostWakeSource;

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
    MaruAppHostCommandQuickInteractiveShell = 2,
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
    /* 저장 workspace를 즉시 적용할 세션이면 첫 default tab/PTY spawn을 보류한다. apply 성공이 첫 surface/frame loop를
       완성한다. 일반 새 Window/quick/smoke는 0. v142. */
    uint32_t defer_initial_surface;
} MaruAppHostSessionConfig;

/* AS4-c fixture가 마지막으로 paint된 capability rectangle만 읽는 fixed-width snapshot.
   present=0이면 나머지 필드는 사용하면 안 된다. 제목, 세션 ID, 경로, 원문, 실행 가능한
   action token은 의도적으로 없다. 좌표는 MaruMetalTerminalView backing pixel 기준이다. */
typedef struct MaruAppHostAgentSessionArchiveSmokeProbe {
    uint64_t request_id;
    /* read-only completed SessionDock tree generation; no source/action payload. v161. */
    uint64_t generation;
    float x_px;
    float y_px;
    float width_px;
    float height_px;
    uint32_t state;
    uint32_t present;
    uint32_t enabled;
} MaruAppHostAgentSessionArchiveSmokeProbe;

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
    /* Phase 4e-5: 이 창에 살아 있는 web Term(브라우저 패널 surface)이 하나라도 있으면 1, 없으면 0. Swift
       drainWebSurfaceTransition 게이트가 이 "생성 신호"(OR webPanels 비어있지 않음)로 env 훅(MARU_WEB_PANEL) 없이
       command로 만든 web surface도 그린다. quit_decision 뒤 4B tail padding 자리라 struct 크기는 176으로 불변(v102). */
    uint32_t web_surfaces_present;
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
       32=자유 배치 파일 도크 토글 semantic role(부분 사각형 아님, PUA 1.7x 확대·titlebar 중앙 정렬).
       renderer는 2~31에서 cell의 한 변/중앙 가는 띠를 칠하고, 32는 glyph 역할로 소비한다. */
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
    /* 이 셀을 자를 사각형의 cell_clips index + 1(0 = 자르지 않음). ABI v169 — 자세한 근거는 아래
       cell_clips 주석. */
    uint16_t clip_index;
    uint16_t _clip_pad;
} MaruAppHostMetalCell;

/* 셀이 clip_index로 가리키는 사각형(backing px, 좌상단 원점 — MTLScissorRect와 같은 규약). */
typedef struct {
    uint32_t x;
    uint32_t y;
    uint32_t w;
    uint32_t h;
} MaruAppHostClipRect;

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
    /* ABI v95: 이 quad를 자를 backing-pixel 뷰포트(좌상단 원점). clip_w==0이면 클리핑 없음(기존 동작).
       rect는 원본 그대로 두고 shader가 모양을 그린 뒤 이 사각형 밖 fragment만 버린다 — CPU가 rect를 먼저
       자르면 잘린 변에 없어야 할 corner radius와 border stroke가 생긴다. 끝에 4필드 추가라 기존 offset 불변. */
    float clip_x;
    float clip_y;
    float clip_w;
    float clip_h;
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

/* B1 rich Chrome text의 최종 glyph quad. terminal cell grid와 별개로 backing-pixel rect를
   전달한다. atlas upload는 기존 raster 채널을 공유한다. layer=0은 terminal physical layer다. */
typedef struct MaruAppHostGpuGlyph {
    float x;
    float y;
    float w;
    float h;
    uint32_t atlas_x_px;
    uint32_t atlas_y_px;
    uint32_t atlas_width_px;
    uint32_t atlas_height_px;
    float u0;
    float v0;
    float u1;
    float v1;
    uint32_t foreground;     /* 0x00RRGGBB */
    uint32_t layer;          /* 0=terminal */
} MaruAppHostGpuGlyph;

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
    /* C4b overlay 셀이 cells에서 시작하는 순수 인덱스. 존재 여부는 마지막 overlay_cells_present가 명시하며,
       렌더러가 over quad(모달 배경)를 텍스트 셀 '앞'에 끼우는 분할점이다. */
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
    /* 사이드바 세로 스크롤량(backing px). renderer가 사이드바 셀(밴드·카드 glyph) py_top에서 빼 카드를 위로 밀고,
       >0이면 사이드바 셀 draw에 [header_h, drawable_h] scissor를 적용해 헤더 위로 샌 카드를 자른다(헤더 glyph는
       터미널 셀 패스라 영향 없음). GPU quad 밴드·tint는 host lowering이 같은 값으로 이미 빼 클립한다(단일 출처).
       0이면 기존 동작(scissor 없음). 끝에 추가해 기존 offset 불변(ABI v86). */
    uint32_t sidebar_scroll_offset_px;
    /* pane divider(reserved 30 세로·31 가로)의 device px 두께 — config split.divider-thickness(pt)를 app_session가
       scale로 환산. renderer가 seam 중앙정렬·셀 clamp로 divider strip을 그린다(커서 강조선 reserved 2~5·GPU quad
       FocusOwner border와 분리). 0=안 그림. 끝에 추가해 기존 offset 불변(ABI v94). */
    uint32_t divider_thickness_px;
    /* 커서 overlay(터미널 블록/bar/underline·오버레이 caret)가 차지하는 cells 길이 —
       cells[cursor_start .. cursor_start + cursor_cells]가 커서다. 렌더러가 이 구간을 본문 draw에서 제외하고
       아래 cursor_fade_milli 불투명도로 별도 pass로 그려 blink를 부드럽게 페이드한다. 0=커서 없음. 끝에 추가(ABI v95). */
    size_t cursor_cells;
    /* 커서 overlay 불투명도 × 1000(0~1000, 1000=완전 표시). blink 페이드 위상 — app이 반주기 끝에서 1000↔0으로 램프
       (cursor.blink-fade-ms). 렌더러가 커서 suffix pass의 fragment opacity로 /1000해 곱한다(premultiplied 출력 전체에
       곱 — 반투명 커서가 아래 본문 셀에 정확히 합성). 0=커서 pass 생략(blink off 위상). 끝에 추가(ABI v95). */
    uint32_t cursor_fade_milli;
    /* ABI v131: overlay 셀이 index 0에서 시작해도 "없음"과 구별하는 명시 gate. modal_cells_start는 순수 index다. */
    uint32_t overlay_cells_present;
    /* 커서 구간의 시작 index(ABI v146). v95는 "커서는 항상 cells suffix"를 암묵 가정했는데, caret 없는 오버레이 셀
       (포커스 테두리·drop 하이라이트·드래그 고스트)이 커서 뒤에 붙는 순간 그 가정이 깨져 커서가 본문과 함께
       불투명하게 그려졌다(=blink 죽음, 포커스 테두리는 상시라 사실상 항상). 시작을 명시로 실어 커서가 버퍼 중간에
       있어도 페이드 pass를 건다 — 렌더러가 본문을 커서 앞/뒤 두 구간으로 나눠 그린다. 끝에 추가해 기존 offset 불변. */
    size_t cursor_start;
    /* B1: final pixel glyph placements for rich Chrome text. NULL/0 keeps old cell-only draw. */
    const MaruAppHostGpuGlyph *gpu_glyphs;
    size_t gpu_glyph_count;
    /* SB1: 창 바닥 상태표시줄이 예약한 높이(backing px). 렌더러는 사이드바 배경 strip을 이만큼 위에서 끝낸다
       — strip은 renderer가 높이를 직접 정하는 승인 예외 표면이라(docs/metal-ui-layout.md §5) Zig가 값을 실어
       주는 것 말고는 바닥을 옮길 방법이 없다. 상태바 자신의 배경·글자는 GpuQuad/GpuGlyph로 온다 — 이 필드는
       renderer가 소유한 표면을 상태바 위에서 끊는 용도다(지금은 strip, S2b에서 사이드바 셀 scissor도 같은 값).
       0=기존 동작(창 바닥까지). 끝에 추가해 기존 offset 불변(ABI v167). */
    uint32_t status_bar_height_px;
    /* ABI v169: 셀이 `clip_index`로 가리키는 사각형 표(backing px, 좌상단). index 1이 cell_clips[0]이고
       0은 "자르지 않음"이다. renderer는 셀을 훑으며 index가 바뀌는 경계에서 draw를 쪼개고 그 사각형으로
       setScissorRect한다.

       **왜 프레임 슬롯이 아니라 셀이 드는가**: v147·v84는 "이 구간을 이 사각형으로 자르라"를 프레임 단위
       슬롯에 담았는데, 그 구간을 producer가 pane 구성에서 계산했다. 도크 목록 pane은 매 프레임 발행되지
       않아서 그 pane이 없는 프레임이 슬롯을 지웠고, 렌더러는 scissor 분기에 **한 번도 진입하지 못했다**.
       셀과 index가 같은 배열에 있으면 그 어긋남이 정의상 불가능하다 — GpuQuad.clip_*가 quad에서 이미
       그렇게 한다. */
    /* 사이드바 셀 scissor 세로 구간 [top, bottom)(backing px). renderer는 **그대로** 쓴다 — 게이트와
       클램프는 Zig(sidebarScissorPx)가 갖는다. bottom <= top이면 scissor 없음. 끝에 추가(ABI v168). */
    uint32_t sidebar_scissor_top_px;
    uint32_t sidebar_scissor_bottom_px;
    /* 셀이 clip_index로 가리키는 사각형 표. index 1이 cell_clips[0]이다(0 = 자르지 않음). 셀 배열과 같은
       프레임에서 함께 만들어져 둘의 수명이 갈라지지 않는다. 끝에 추가(ABI v169). */
    const MaruAppHostClipRect *cell_clips;
    size_t cell_clip_count;
} MaruAppHostMetalFrame;

uint32_t maru_macos_app_host_abi_version(void);
int32_t maru_macos_app_host_capabilities(MaruAppHostCapabilities *out_capabilities);
/* ABI v145: 첫 AppSession/config/workspace/runtime보다 먼저 앱 전역 writer lease를 획득한다.
   path는 workspace.v1.lock UTF-8 bytes다. Zig는 final leaf를 no-follow/0600/current-UID regular로
   검증하고 CLOEXEC flock fd를 process lifetime 동안 보관한다. */
uint32_t maru_macos_app_instance_lease_acquire(const uint8_t *path, size_t path_len);
/* ABI v176: lease가 이미 확보된 process에서 AppKit/첫 AppSession보다 먼저 G1 provenance를 app-global
   scalar snapshot으로 exact once seal한다. release A에서는 config를 쓰거나 기본값을 바꾸지 않는다. */
uint32_t maru_macos_session_config_bootstrap(void);
/* ABI v181: release baseline harness가 bootstrap owner의 실제 typed state를 닫힌 값으로만 읽는다. */
uint32_t maru_macos_session_default_false_observation(void);
/* OS 로케일 식별자(`ko-KR` 류 짧은 ASCII)를 프로세스 전역으로 넘긴다 — Swift 는 읽어서 전달만 하고
   해석하지 않는다(docs/i18n.md §5.1: 판정은 중립 층인 src/i18n.zig 가 소유). 세션을 만들기 전마다 메인
   스레드에서 호출한다(같은 값이면 무해). NULL·빈 값·128 바이트 초과는 무동작이며, 그때 `ui.language = auto`
   는 영어로 떨어진다. */
void maru_macos_app_set_ui_locale(const uint8_t *tag, size_t tag_len);
/* 작업공간 복원이 불완전했음을 알리는 notice 를 띄운다. Swift 는 상태만 알리고 문장은 Zig 가
   고른다(docs/i18n.md §7.2) — 예전에는 Swift 가 한국어 문장을 조립해 show_notice 로 넘겼고,
   그것이 §7.3 이 남겨 둔 마지막 구멍이었다. */
void maru_macos_app_session_notice_workspace_restore_incomplete(MaruAppHostSession *session);
/* 파일 선택 패널 안내 문구를 현재 UI 언어로 돌려준다. Swift 는 UI 문자열을 만들지 않는다
   (docs/i18n.md §7.2) — 종류만 넘기고 문장은 Zig 가 고른다. 반환은 정적 널종단 문자열이라
   host 가 해제하지 않는다. 알 수 없는 종류는 빈 문자열(패널이 안내 없이 뜬다). */
#define MARU_FILE_PICK_MESSAGE_BACKGROUND_PNG 0u
#define MARU_FILE_PICK_MESSAGE_DOCK_FILE 1u
#define MARU_FILE_PICK_MESSAGE_EXPLORER_FOLDER 2u
#define MARU_FILE_PICK_MESSAGE_WORKSPACE_FOLDER 3u
const char *maru_macos_file_pick_message(uint32_t kind);
/* CR0b bootstrap 5: 모든 AppSession teardown 뒤 app-global remote backend/pool/client를 정산한다.
   0=inactive, 1=settled. incident owner shutdown보다 반드시 먼저 호출한다. */
uint32_t maru_macos_remote_backend_settle(void);
/* CR6e-c3c: process-global reconnect owner를 Window 순회 전 timer turn당 정확히 한 번 전진한다. */
uint32_t maru_macos_reconnect_product_tick(void);
/* CR6e-c3c: runtime graph teardown 전에 worker와 CR5/admission authority를 정산한다. */
uint32_t maru_macos_reconnect_product_shutdown(void);
typedef struct MaruReconnectProductSmokeProbe {
    uint32_t coordinator_ready;
    uint32_t worker_state_raw;
    uint32_t active_jobs;
    uint32_t job_receipt_present;
    uint32_t completion_receipt_present;
    uint32_t cr5_job_present;
    uint32_t cr5_preparing;
    uint32_t cr5_state_raw;
    uint32_t runtime_count;
    uint32_t admission_count;
    uint32_t resident_entries;
} MaruReconnectProductSmokeProbe;
int32_t maru_macos_reconnect_product_smoke_probe(MaruReconnectProductSmokeProbe *out_probe);
/* CR0b: all AppSession/backend settlement 뒤 app-global incident writer를 exact once 정산한다.
   0=inactive, 1=joined, 2=detached, 3=degraded. */
uint32_t maru_macos_incident_owner_shutdown(void);
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

/* Borrowed session-host socket identities. Swift may observe readability but must never close fd. */
size_t maru_macos_remote_backend_wake_sources(
    MaruSessionHostWakeSource *out_sources,
    size_t capacity
);
int32_t maru_macos_app_session_key_down(
    MaruAppHostSession *session,
    const MaruAppHostKeyEvent *event,
    MaruAppHostFrameSummary *out_summary
);
/* AS4-c fixture-only detail-worker gate.  The gate has no archive/action mutation
   capability: it can only hold/release a worker before the no-follow source read,
   and report whether that worker has reached the hold point.  v151. */
int32_t maru_macos_app_session_set_agent_session_archive_detail_smoke_gate(
    MaruAppHostSession *session,
    uint32_t blocked
);
uint32_t maru_macos_app_session_agent_session_archive_detail_smoke_gate_reached(
    const MaruAppHostSession *session
);
/* AS4 snapshot-replace fixture-only scan gate. It only blocks/releases a detached scan before
   discovery; normal refresh input remains the sole path that submits the worker. v160. */
int32_t maru_macos_app_session_set_agent_session_archive_smoke_gate(
    MaruAppHostSession *session,
    uint32_t blocked
);
uint32_t maru_macos_app_session_agent_session_archive_smoke_gate_reached(
    const MaruAppHostSession *session
);
/* Read-only evidence for the stale-reveal fixture: this becomes 1 only when an ordinary detail
   action reached the no-follow identity admission and was rejected as stale. v155. */
uint32_t maru_macos_app_session_agent_session_archive_smoke_stale_reveal_count(
    const MaruAppHostSession *session
);
/* Closed-fixture-only evidence that the currently open Claude archive detail retained a
   non-empty parsed model. Returns a boolean only; model/session/path text is never exported. v156. */
uint32_t maru_macos_app_session_agent_session_archive_smoke_claude_model_present(
    const MaruAppHostSession *session
);
/* Closed-fixture-only ownership observers. They expose neither archive content nor mutation:
   the AppKit archive smoke compares these values before card activation and while detail is
   loading/ready to prove the disclosure did not create a Term or change active focus. v159. */
uint64_t maru_macos_app_session_agent_session_archive_smoke_active_surface_id(
    const MaruAppHostSession *session
);
uint32_t maru_macos_app_session_agent_session_archive_smoke_term_count(
    const MaruAppHostSession *session
);
/* Closed-fixture-only divider observer for the CIM2 AppKit E2E. It exposes the published grab
   band of the first divider, the current split ratio in per-mille, and this drag's instrumentation
   (absorbed moves vs applied resizes). No split pointer or tree structure crosses the ABI. v163. */
typedef struct MaruAppHostDividerSmokeProbe {
    int32_t x_px;
    int32_t y_px;
    uint32_t width_px;
    uint32_t height_px;
    uint32_t ratio_milli;
    uint32_t present;
    uint32_t capture_active;
    uint64_t move_events;
    uint64_t resize_applications;
    uint32_t padding_left_px;
    uint32_t padding_right_px;
    uint32_t web_covered_dividers;
    uint32_t scrollbar_present;
    int32_t scrollbar_thumb_x_px;
    int32_t scrollbar_thumb_y_px;
    uint32_t scrollbar_thumb_w_px;
    uint32_t scrollbar_thumb_h_px;
    uint32_t scrollbar_capture_active;
    uint64_t scrollbar_offset_px;
    uint64_t scrollbar_move_events;
    uint64_t scrollbar_scroll_applications;
    /* CIM4b: 활성 pane 탭 바의 발행 세그먼트 기하와 provisional preview 관측치(보이는 첫 탭 vs model 첫 탭).
       끝에 덧붙여 기존 필드 offset은 불변이지만 레코드가 커지므로 ABI 버전을 올린다(v166) — Swift가 이
       구조체를 자기 스택에 잡고 Zig가 채우는 out-param이라, 버전이 그대로면 낡은 Swift가 새 Zig와 짝지어져도
       가드를 통과해 호출자 스택을 넘어 쓴다. */
    uint32_t tab_bar_present;
    uint32_t tab_count;
    int32_t tab_first_x_px;
    uint32_t tab_slot_w_px;
    int32_t tab_bar_y_px;
    uint32_t tab_drag_active;
    uint64_t tab_visible_first_id;
    uint64_t tab_model_first_id;
} MaruAppHostDividerSmokeProbe;
int32_t maru_macos_app_session_divider_smoke_probe(
    MaruAppHostSession *session,
    MaruAppHostDividerSmokeProbe *out_probe
);

/* target은 MARU_AGENT_SESSION_ARCHIVE_SMOKE_TARGET_* 중 하나여야 한다. 읽기 전용이며
   paint/publish된 rect만 반환한다. v152. */
int32_t maru_macos_app_session_agent_session_archive_smoke_probe(
    const MaruAppHostSession *session,
    uint32_t target,
    MaruAppHostAgentSessionArchiveSmokeProbe *out_probe
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
/* host의 종료 승인 직전 protected-file 재검사에서 Quit을 취소할 때 이미 수락한 앱 전역 lifecycle latch를 되돌린다.
   앱이 계속 실행된 뒤 명시 close/다음 Quit이 stale detach/end-all 의미를 쓰지 않게 한다. v141. */
void maru_macos_app_session_cancel_app_quit(
    MaruAppHostSession *session
);
/* 현재 세션에 종료 전에 해소해야 할 dirty/pending/source-edit 파일 도크 entry가 있으면 1, 아니면 0.
   Cmd+Q는 모든 일반 창과 quick session을 요청 시점·확정 시점에 순회해 다른 창의 미저장 버퍼도 보호한다. v126. */
uint32_t maru_macos_app_session_has_protected_file_panels(
    MaruAppHostSession *session
);
/* 호스트가 매 tick 주입하는 "이 세션이 앱의 마지막(유일) 일반 창인가"(1=마지막·0=아님). Zig 리프는 형제 NSWindow를
   모르므로 Swift가 windows.count로 알려준다. 마지막 창일 때 ⌘W/사이드바·탭바 ✕로 세션을 닫으면 requestClose가 창
   하나 닫기 대신 Cmd+Q와 동일한 "maru를 종료할까요?" 종료 확인을 띄운다(마지막 창 닫기=앱 종료). quick·멀티 창의
   비-마지막 창은 0. */
void maru_macos_app_session_set_last_window(
    MaruAppHostSession *session,
    uint32_t is_last
);
/* CR6a-2 app-global Recovered Sessions projection을 렌더할 유일한 일반 primary Window identity. */
void maru_macos_app_session_set_primary_window(
    MaruAppHostSession *session,
    uint32_t is_primary
);
/* CR6a-2 launch-before-terminal secure discovery/ephemeral inventory/projection coordinator.
   result: 0 skipped, 1 published, 2 unavailable. */
uint32_t maru_macos_app_session_prepare_recovered_sessions(
    MaruAppHostSession *session,
    const uint8_t *text,
    size_t text_len,
    uint32_t has_workspace
);
/* recovery preflight 뒤 저장 Workspace가 없을 때 default shell surface를 명시적으로 완성한다. */
int32_t maru_macos_app_session_finish_deferred_initial_surface(
    MaruAppHostSession *session
);
/* CR6c actual-AppKit recovery smoke의 read-only row/상태 projection. action identity 없음. */
typedef struct MaruAppHostRecoveredSessionSmokeProbe {
    uint32_t row_present;
    int32_t row_x_px;
    int32_t row_y_px;
    uint32_t row_width_px;
    uint32_t row_height_px;
    uint32_t recovered_count;
    uint32_t tab_count;
    uint32_t surface_initialized;
    uint32_t active_remote;
    uint32_t marker_present;
    uint32_t async_wake_marker_present;
    uint32_t c3c_historical_count;
    uint32_t c3c_disconnect_after_count;
    uint32_t c3c_input_count;
    uint32_t c3c_sibling_live;
    uint32_t c3c_sibling_controller;
    uint32_t cols;
    uint32_t rows;
    uint32_t keep_alive_enabled;
    uint32_t discovered_candidates;
    uint32_t ready_adapters;
    uint32_t inventory_runtimes;
    uint32_t configured_keep_alive;
    uint32_t live_session_count;
    uint32_t target_activation_dispatched;
} MaruAppHostRecoveredSessionSmokeProbe;
int32_t maru_macos_app_session_recovered_session_smoke_probe(
    MaruAppHostSession *session,
    MaruAppHostRecoveredSessionSmokeProbe *out_probe
);
/* CR6d actual-AppKit smoke의 exact recovered-runtime read-only screen counters. */
typedef struct MaruAppHostSessionHostInputSmokeProbe {
    uint32_t active_remote;
    uint32_t historical_count;
    uint32_t ime_count;
    uint32_t clipboard_count;
} MaruAppHostSessionHostInputSmokeProbe;
int32_t maru_macos_app_session_input_smoke_probe(
    MaruAppHostSession *session,
    MaruAppHostSessionHostInputSmokeProbe *out_probe
);
/* cross-window workspace 이동(M3d-2a) 결과 — status(ok/move_failed/null_out) + 소스 창이 비어 닫아야 하는지
   (§8A.2) + 이동한 surface 수(§8A.3). Swift(M3d-2b)가 source_window_closed=1이면 NSWindow를 닫는다(판정은 Zig,
   close는 platform). app_host_abi.zig MoveResult와 layout이 정합해야 한다(ABI 계약 테스트가 @sizeOf/@offsetOf로 강제). */
typedef struct MaruAppHostMoveResult {
    int32_t status;
    uint32_t source_window_closed;
    uint32_t moved_count;
} MaruAppHostMoveResult;
/* M3d-2a-i cross-window workspace 이동(docs/window-surface-mobility.md §8A.8) — src 세션의 src_index 워크스페이스를
   dst 세션으로 옮긴다(registry/routing 무변경 → surface 재시작 없음). *out.source_window_closed=1이면 src 창이 비어
   Swift가 닫아야 한다. src/dst/out NULL이면 NullOut, 잘못된 인덱스·OOM·범위 밖(그룹/pinned) 워크스페이스면 MoveFailed
   (세션 유지). */
int32_t maru_macos_app_session_move_workspace_to(
    MaruAppHostSession *src,
    MaruAppHostSession *dst,
    size_t src_index,
    MaruAppHostMoveResult *out
);
/* M3d-2a-i 전체 window merge(§1·§4) — src 세션의 **모든** 워크스페이스를 dst로 옮기고 src를 비운다
   (source_window_closed 항상 1). surface 무재시작. src/dst/out NULL이면 NullOut, src 워크스페이스 중 하나라도
   범위 밖(그룹/pinned)이거나 OOM이면 MoveFailed(source 불변). */
int32_t maru_macos_app_session_merge_window(
    MaruAppHostSession *src,
    MaruAppHostSession *dst,
    MaruAppHostMoveResult *out
);
/* M3d-2b 단일 카드 이동 배선 — src 세션의 **활성** 워크스페이스(탭) 인덱스. Swift 메뉴 "Move Workspace to Window"가
   이 인덱스를 move_workspace_to(src, dst, src_index)의 src_index로 써서 활성 카드 하나만 옮긴다(merge_window은 전체라
   불요). read-only(take_bell류 u32 — 값이지 상태 코드 아님). session NULL·surface 미초기화·탭 전무면 sentinel(UINT32_MAX)
   → Swift가 무동작. app_host_abi.zig maru_macos_app_session_active_workspace_index와 시그니처가 정합해야 한다(swift-check). */
uint32_t maru_macos_app_session_active_workspace_index(MaruAppHostSession *session);
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
   button 0=left 1=middle 2=right(셀렉션은 left만 의미). mods 비트(xterm): 4=shift 8=meta/alt 16=ctrl 32=command.
   command(32)는 xterm 표준 밖이다 — 사이드바 그룹 드래그의 "Cmd=중첩/없으면 형제" 판정에 쓰고, 터미널
   마우스 리포트로 갈 때는 Zig가 그 비트를 마스킹해 뺀다(SGR motion 비트 32와 충돌해 cb=button+mods+motion이
   오염된다). Swift 쪽 modsBits가 같은 넷을 세운다.
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
/* 드래그앤드롭 지점(backing px)의 pane/Term으로 포커스를 옮긴다 — 드롭이 활성 pane이 아니라 **떨어뜨린 pane**으로
   들어가게 하는 라우팅. Swift handleDrop이 내용 삽입(드래그 경로는 paste_text 또는 drop_files) **전에** 부른다.
   pane rect는 탭 바를 포함하고, Term 탭 위 드롭이면 그 Term까지 활성으로 만든다.
   반환은 **3-상태**이고 호스트는 반드시 구분해야 한다:
     1  = routed(그 pane/Term으로 포커스 이동 — 뒤이은 삽입이 거기로 간다)
     0  = not_applicable(사이드바·pane 밖 — 호스트는 기존대로 활성 pane에 삽입)
    -1  = refused(**삽입 금지** — chrome 오버레이/모달이 열렸거나 대상이 web pane이라 붙일 PTY가 없다)
   거부를 0으로 접으면 호스트가 활성 pane에 삽입해 막으려던 오삽입이 그대로 일어난다. (v115) */
int32_t maru_macos_app_session_route_drop(
    MaruAppHostSession *session,
    double x_px,
    double y_px
);
/* 드래그앤드롭한 파일 경로들(NUL 구분). maru ssh 원격이면 control socket으로 업로드 후 원격 절대경로를
   paste하고, 로컬이면 경로를 셸 이스케이프해 paste한다(분기는 Zig). Swift는 fileURL 드롭일 때만 부른다
   (웹 URL·텍스트는 paste_text 유지). (v68) */
int32_t maru_macos_app_session_drop_files(
    MaruAppHostSession *session,
    const uint8_t *bytes,
    size_t len
);
/* 클립보드 이미지(Cmd+V). Swift가 먼저 만든 임시 PNG 경로와 같은 PNG 바이트를 넘긴다.
   host-backed이면 1(비동기 freshness 판정이 경로 paste 또는 원격 upload를 소유),
   in-process 로컬이면 0(Swift가 temp_path를 기존 paste 경로로 보냄). */
int32_t maru_macos_app_session_drop_image(
    MaruAppHostSession *session,
    const uint8_t *temp_path,
    size_t temp_path_len,
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

/* 이 chord 를 편집기 컨텍스트가 소유하는가 — 1이면 Swift performKeyEquivalent 가 메뉴바
   keyEquivalent 를 양보하고 키를 keyDown 으로 보낸다(docs/key-input-and-shortcuts.md
   「메뉴 keyEquivalent 층」). 부작용 없음. */
int32_t maru_macos_app_session_editor_owns_chord(MaruAppHostSession *session,
                                                 const MaruAppHostKeyEvent *event);

/* 활성 Term 이 터미널인가 — 1이면 Swift 의 터미널 전용 선-가로채기(프롬프트 점프·페이지 스크롤)가
   돈다. 편집기·웹 Term 에서는 0이라 그 키가 편집기까지 흐른다. fail-open(세션 없으면 1). */
int32_t maru_macos_app_session_active_term_is_terminal(MaruAppHostSession *session);
/* WKWebView typed key route: 0=pass-through, 1=app-action, 2=consume-unbound, 3=web-editor. side-effect와 PTY
   write 없이 같은 Zig resolver의 provenance를 반환한다. unknown은 Swift가 consume하고 null/event 변환 실패는
   pass-through다. v132가 옛 v100 Bool app-action 조회를 대체한다. */
uint32_t maru_macos_app_session_web_key_route(MaruAppHostSession *session, uint64_t surface_id, const MaruAppHostKeyEvent *event);
/* route가 app-action일 때 같은 Zig resolver를 다시 평가해 현재 Action만 terminal copy/paste·scroll·macro 전처리와
   PTY write 없이 직접 dispatch한다. route 뒤 상태가 달라졌으면 실행하지 않고 0. 성공=1. v132. */
uint32_t maru_macos_app_session_dispatch_web_app_action(MaruAppHostSession *session, uint64_t surface_id, const MaruAppHostKeyEvent *event);
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
/* (v147) 터미널에서 클릭한 웹 링크(http/https)를 config input.link-open-target(auto|in-app|system)대로 연다.
   1 = Zig가 인앱 browser 패널로 열기로 하고 pending action을 세웠다(Swift는 다음 tick take_external_link_action으로
   drain — 새로 만든 browser Term의 WKWebView가 surface 전이 batch로 준비된 뒤 navigate된다). 클릭을 소비하고 끝.
   0 = 시스템 기본 브라우저로 열어야 한다(호출자가 NSWorkspace.open). url_at의 *out_kind==0(url)일 때만 부른다. */
uint32_t maru_macos_app_session_open_terminal_web_link(
    MaruAppHostSession *session,
    const uint8_t *url,
    size_t url_len
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
/* OSC 9/777 데스크톱 알림 데이터(title, body, UTF-8, surface_id, foreground). *has=1이면 알림 있음
   (title은 빈 문자열일 수 있어 len으로 판단), 0이면 없음. *surface_id=발신 Term의 surface.id로, Swift가 알림
   userInfo에 (창 토큰, surface_id)로 실어 클릭 시 발신 터미널로 점프한다(activate_surface). *foreground=앱이 전면일
   때도 배너로 띄울지(1=background surface / 0=현재 보고 있는 surface, 전면이면 목록만) — Swift willPresent가 읽는다. 버퍼는 Zig 소유로 다음
   pending_notification/destroy까지 유효. route_present=1이면 hid/rid/eid가 host stable event identity이고, 0이면
   나머지 route out은 모두 0이다. Swift가 tick마다 호출해 UNUserNotificationCenter로 띄운다(알림은 OS 소유). v174. */
int32_t maru_macos_app_session_pending_notification(
    MaruAppHostSession *session,
    uint32_t *has,
    const uint8_t **title_ptr,
    size_t *title_len,
    const uint8_t **body_ptr,
    size_t *body_len,
    uint64_t *surface_id,
    uint32_t *foreground,
    uint32_t *route_present_out,
    uint64_t *host_id_hi_out,
    uint64_t *host_id_lo_out,
    uint64_t *runtime_id_hi_out,
    uint64_t *runtime_id_lo_out,
    uint64_t *event_id_out
);
/* 데스크톱 알림 클릭 → 발신 surface로 활성화. Swift가 알림 userInfo의 (창 토큰, surface_id)에서 토큰으로 올바른
   창/세션을 고른 뒤(창 키 활성화는 Swift), 이 세션에 surface_id를 넘긴다. Zig가 (탭/panel/Term)을 역조회해 그
   자리로 포커스한다(switchTab→focusPaneByPtr→focusTerm). 찾아 활성화했으면 1, 이미 닫혔으면 0(무동작). session
   null=0. take_bell과 같은 u32 반환(found 여부). v76. */
uint32_t maru_macos_app_session_activate_surface(MaruAppHostSession *session, uint64_t surface_id);
/* Stable host notification click. Probe each live normal Window with action=0 without mutation; an
   exact single match is activated with action=1. With zero matches, only the primary Window may use
   action=2, which consumes the current Recovered Sessions row via
   fresh host.info/runtime.get validation. Returns 0 for probe/activate no-match, 1 for exact
   match/activation/adoption, and 2 for invalid, stale, duplicate, or failed routes. No failure
   spawns a fallback shell. v175. */
uint32_t maru_macos_app_session_activate_notification_runtime(
    MaruAppHostSession *session,
    uint64_t host_id_hi,
    uint64_t host_id_lo,
    uint64_t runtime_id_hi,
    uint64_t runtime_id_lo,
    uint32_t action
);
/* G12 BEL: 활성 세션에 pending 벨이 있으면 1(코어 플래그 비움), 없으면 0. Swift가 tick마다 호출해 시스템 벨
   (NSSound.beep)을 울린다(벨은 OS 소유). */
uint32_t maru_macos_app_session_take_bell(MaruAppHostSession *session);
/* Dock 배지 1회성 신호(config bell.dock-badge). BEL이 창 포커스 없을 때 울리면 1, 아니면 0. Swift가 매 tick 호출해
   1이면 NSApp.dockTile.badgeLabel을 ●로 세운다(포커스 복귀 시 Swift가 지움). take_bell과 같은 1회성. session null=0. v76. */
uint32_t maru_macos_app_session_take_bell_badge(MaruAppHostSession *session);
/* 세팅 GUI에서 데스크톱 알림 토글(notifications.osc)을 켠 경우 macOS 알림 권한 요청을 Swift에 맡기는
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
/* open_file_panel(Cmd+O/팔릿/메뉴)이 요청한 Markdown/HTML NSOpenPanel one-shot. v121. */
uint32_t maru_macos_app_session_take_file_panel_pick_request(MaruAppHostSession *session);
/* Explorer root directory picker one-shot. 0=none, 1=replace roots, 2=add root. cancel은 len=0 provide. v137. */
uint32_t maru_macos_app_session_take_file_tree_root_pick_request(MaruAppHostSession *session);
int32_t maru_macos_app_session_provide_file_tree_root_pick(MaruAppHostSession *session, const uint8_t *bytes, size_t len);
/* 절대경로를 현재 창 도크에 연다. 반환 0=지원하지 않는 확장자(외부 열기 유지), 1=열림/기존 탭 활성화,
   2=지원 확장자지만 경로·파일·용량/할당 실패. 종류·regular-file·중복 정책은 Zig 단일 출처. v121. */
uint32_t maru_macos_app_session_open_file_panel_path(MaruAppHostSession *session, const uint8_t *bytes, size_t len);
/* surface가 도크 entry면 path와 kind를 반환한다(0=도크 아님, 1=markdown/text=신뢰 config, 2=html). path는 Zig
   소유이며 호출 중 복사해서 쓴다. Swift create 전이가 HTML loadFileURL 핀 경로를 얻는 용도. v121.
   text와 markdown은 같은 신뢰 config(1)를 쓰고, 소스 전용 CM6 선택은 file_panel_language의 lang 토큰이 맡는다. */
uint32_t maru_macos_app_session_file_panel_entry(
    MaruAppHostSession *session,
    uint64_t surface_id,
    const uint8_t **out_path,
    size_t *out_len
);
/* text kind surface의 CM6 하이라이트 언어 wire 이름(예: "json", "python")을 반환한다. 1=text(out에 토큰),
   0=markdown/html이거나 도크 아님(out 비움 → shell URL에 lang 힌트를 붙이지 않는다). 토큰은 static borrow. */
uint32_t maru_macos_app_session_file_panel_language(
    MaruAppHostSession *session,
    uint64_t surface_id,
    const uint8_t **out_ptr,
    size_t *out_len
);
/* 현재 터미널 색상 테마에서 파생한 syntax 하이라이트 색을 `--maru-syntax-*` CSS 변수로 설정하는 JS 스니펫을
   out에 쓴다(§2.3). 신뢰 shell webview 로드 후·테마 변경 시 evaluateJavaScript로 실행한다. 반환=바이트 수(0=실패). */
size_t maru_macos_app_session_syntax_style_js(
    MaruAppHostSession *session,
    uint8_t *out,
    size_t out_cap
);
/* svg surface면 "svg"를 out에 쓰고 1 반환(Swift가 shell URL에 ?kind=svg 추가 → read 프리뷰+xml 소스). 그 외 0. */
uint32_t maru_macos_app_session_file_panel_shell_kind(
    MaruAppHostSession *session,
    uint64_t surface_id,
    const uint8_t **out_ptr,
    size_t *out_len
);
/* 도크 entry의 mode(0=read, 1=source-edit, 2=rich). 도크가 아니면 -1. v132. */
int32_t maru_macos_app_session_file_panel_mode(MaruAppHostSession *session, uint64_t surface_id);

/* 파일 패널 mode를 설정한다(헤더 mode 선택기 클릭과 같은 경로). 1=적용, 0=없는 surface/불허 mode. v149. */
uint32_t maru_macos_app_session_set_file_panel_mode(MaruAppHostSession *session, uint64_t surface_id, uint32_t raw_mode);
/* explicit file WKWebView primary-down을 Zig FocusOwner/DockPanel group에 반영한다. 1=승인, 0=stale/아님. v124. */
uint32_t maru_macos_app_session_focus_file_panel_surface(MaruAppHostSession *session, uint64_t surface_id);
uint32_t maru_macos_app_session_complete_pending_dock_focus(MaruAppHostSession *session, uint64_t surface_id);
uint64_t maru_macos_app_session_pending_dock_focus_surface(MaruAppHostSession *session);
/* Zig FocusOwner가 승인한 dock_surface만 반환한다. 그 외=0. v131. */
uint64_t maru_macos_app_session_focused_dock_surface(MaruAppHostSession *session);
/* Markdown isolated bridge 또는 로컬 HTML의 사용자 링크 활성화를 source surface에 고정해 처리한다.
   force_system!=0이면 config보다 우선해 시스템 브라우저를 쓴다. 1=수락, 0=invalid/stale/busy. v125. */
uint32_t maru_macos_app_session_open_file_panel_link(
    MaruAppHostSession *session,
    uint64_t surface_id,
    const uint8_t *url,
    size_t url_len,
    uint32_t force_system
);
/* 설정에 따라 결정된 외부 링크 action one-shot. 반환 URL 길이(0=없음/인자·cap 오류), kind 1=in-app browser,
   2=system browser. in-app이면 surface_id는 이미 생성한 browser Term id, system이면 0. v125. */
size_t maru_macos_app_session_take_external_link_action(
    MaruAppHostSession *session,
    uint8_t *url_out,
    size_t url_cap,
    uint64_t *surface_id_out,
    uint32_t *kind_out
);
/* terminal/browser firstResponder가 입력 축을 되찾았음을 Zig focus owner에 반영한다. v126. */
void maru_macos_app_session_focus_workspace_input(MaruAppHostSession *session);
uint32_t maru_macos_app_session_take_workspace_focus_action(MaruAppHostSession *session);
/* Zig file-tree FocusOwner가 요청한 Metal firstResponder pull과 Esc dock surface restore. v127. */
uint32_t maru_macos_app_session_take_file_tree_focus_action(MaruAppHostSession *session);
uint64_t maru_macos_app_session_take_file_tree_restore_surface_action(MaruAppHostSession *session);
/* 마지막 apply_workspace_window가 조용히 버린 항목 수(손상 파일 패널 entry + 비워진 dock 그룹 + 접근 불가
   explorer root)를 1회 drain한다. 0이 아니면 복원 모델이 저장 파일을 표현하지 못하므로 호출자가 이번 실행의
   checkpoint를 막아 마지막 완전본을 보존한다. v144. */
uint32_t maru_macos_app_session_take_workspace_restore_dropped(MaruAppHostSession *session);
/* GPU 헤더 토글이 바꾼 mode를 1회 drain한다. 반환 -1=없음, 0=read, 1=source-edit, 2=rich. v132. */
int32_t maru_macos_app_session_take_file_panel_mode_action(MaruAppHostSession *session, uint64_t *surface_id_out);

/// 파일 본문 우클릭 메뉴에서 web이 실행할 항목을 drain한다(0=없음·1=copy·2=cut·3=paste·4=selectAll).
uint32_t maru_macos_app_session_take_file_menu_action(MaruAppHostSession *session, uint64_t *surface_id_out);
/* PendingDockFocus의 native firstResponder action을 mode refresh와 독립적으로 drain한다. 0=없음. v131. */
uint64_t maru_macos_app_session_take_pending_dock_focus_action(MaruAppHostSession *session);
/* source editor 이탈 전에 이전 surface의 dirty snapshot을 강제 요청한다. 0=없음, 그 외=surface id. v122. */
uint64_t maru_macos_app_session_take_file_panel_dirty_sync_action(MaruAppHostSession *session);
uint64_t maru_macos_app_session_take_file_panel_dirty_sync_action_v2(MaruAppHostSession *session, uint64_t *request_id_out);
void maru_macos_app_session_fail_file_panel_dirty_sync(MaruAppHostSession *session, uint64_t surface_id, uint64_t request_id);
/* dirty 파일 닫기의 request-scoped 저장/unlock one-shot과 완료·실패 ack. Zig가 request/revision/dirty/conflict를 재검증한다. v126. */
uint64_t maru_macos_app_session_take_file_panel_save_close_action(MaruAppHostSession *session, uint64_t *request_id_out);
void maru_macos_app_session_complete_file_panel_save_close(MaruAppHostSession *session, uint64_t surface_id, uint64_t request_id, uint64_t revision, uint32_t success);
uint64_t maru_macos_app_session_take_file_panel_close_unlock_action(MaruAppHostSession *session, uint64_t *request_id_out);
void maru_macos_app_session_fail_file_panel_close_unlock(MaruAppHostSession *session, uint64_t surface_id, uint64_t request_id);
/* FP7 project tree: FSEvents root lifecycle/event + clean file reload/external open one-shots. v123.
   path outputs return required length without consuming when out==NULL or cap is short. */
uint32_t maru_macos_app_session_take_file_tree_watch_reset(MaruAppHostSession *session);
size_t maru_macos_app_session_take_file_tree_watch_root(MaruAppHostSession *session, uint8_t *out, size_t cap);
/* ABI v173: 접근성 서술자. Zig 는 **뜻**만 싣고(role/state/집합 위치), NSAccessibility 어휘로의 번역과
   좌표계 뒤집기는 Swift 어댑터가 소유한다(docs/chrome-interaction-migration.md §3).

   레코드는 발행 시점에 굳힌 스냅숏에서 온다 — 발행된 tree 를 직접 읽으면 라벨이 해제된 메모리다.
   라벨·값은 별도 함수로 복사해 간다(포인터를 struct 에 담으면 수명이 받는 쪽에서 불분명해진다). */
enum {
    MARU_APP_HOST_A11Y_ROLE_BUTTON = 0,
    MARU_APP_HOST_A11Y_ROLE_TREE_ITEM = 1,
    MARU_APP_HOST_A11Y_ROLE_LIST_ITEM = 2,
    MARU_APP_HOST_A11Y_ROLE_TAB = 3,
    MARU_APP_HOST_A11Y_ROLE_SCROLL_VIEW = 4,
    MARU_APP_HOST_A11Y_ROLE_TEXT = 5,
    MARU_APP_HOST_A11Y_ROLE_GROUP = 6,
};
enum {
    MARU_APP_HOST_A11Y_FLAG_ENABLED = 1u << 0,
    MARU_APP_HOST_A11Y_FLAG_SELECTED = 1u << 1,
    MARU_APP_HOST_A11Y_FLAG_FOCUSABLE = 1u << 2,
    /* 이 줄에 펼침이라는 개념이 있나. 없으면 아래 EXPANDED 는 뜻이 없다 — 스크린 리더가
       "접힘"으로 읽지 않게 둘을 가른다. */
    MARU_APP_HOST_A11Y_FLAG_EXPANDABLE = 1u << 3,
    MARU_APP_HOST_A11Y_FLAG_EXPANDED = 1u << 4,
};
typedef struct {
    /* 창 좌표(backing px, 좌상단 원점). AppKit 좌하단 원점으로의 뒤집기는 Swift 가 한다. */
    float x;
    float y;
    float width;
    float height;
    uint32_t role;
    uint32_t flags;
    uint32_t level;
    uint32_t position_in_set;
    uint32_t set_size;
    uint64_t action_id;
    uint32_t label_offset;
    uint32_t label_len;
    uint32_t value_offset;
    uint32_t value_len;
} MaruAppHostAccessibilityElement;

uint32_t maru_macos_app_session_accessibility_count(MaruAppHostSession *session);
int32_t maru_macos_app_session_accessibility_element(MaruAppHostSession *session, uint32_t index, MaruAppHostAccessibilityElement *out_element);
size_t maru_macos_app_session_accessibility_label(MaruAppHostSession *session, uint32_t index, uint8_t *out, size_t capacity);
size_t maru_macos_app_session_accessibility_value(MaruAppHostSession *session, uint32_t index, uint8_t *out, size_t capacity);

void maru_macos_app_session_file_tree_changed(MaruAppHostSession *session, const uint8_t *bytes, size_t len);
uint64_t maru_macos_app_session_take_file_tree_reload_action(MaruAppHostSession *session, uint32_t *conflict_out);
size_t maru_macos_app_session_take_file_tree_external_open(MaruAppHostSession *session, uint8_t *out, size_t cap);
/* v129: descriptor-relative staging이 끝난 URL을 AppKit의 복구 가능한 Trash API로 넘긴다. short/null
   buffer는 required length만 반환하고 one-shot을 소비하지 않는다. completion은 not-moved,
   moved-verified, moved-unverified를 구분하며 마지막 상태는 optional destination path를 함께 보낸다. */
size_t maru_macos_app_session_take_file_tree_trash_action(MaruAppHostSession *session, uint8_t *out, size_t cap, uint64_t *request_id_out, uint64_t *device_out, uint64_t *inode_out, uint32_t *kind_out);
void maru_macos_app_session_complete_file_tree_trash(MaruAppHostSession *session, uint64_t request_id, uint32_t outcome, const uint8_t *recovery_path, size_t recovery_path_len);
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
   캡처/직렬화 실패·빈 경우 *out_len=0(Swift가 그 창을 건너뜀). 정상 종료(applicationWillTerminate) 시 저장.
   is_active(!=0)=이 창이 저장 시점 key 창(window.isKeyWindow) → active-window=1 옵션-키를 내고 재시작 복원이
   그 창을 다시 focus한다(M3e). false면 키 생략(옛 파일과 flat 동일 — 하위호환).
   has_frame(!=0)=window.frame(전역 스크린 좌표 점)을 저장 → win-x/y/w/h 옵션-키를 내고 재시작 복원이 그 위치·
   크기·모니터로 setFrame한다(M3f). 0이면 키 생략(옛 파일 flat 동일 → cascade). frame_x/y는 음수 가능(보조 모니터). */
int32_t maru_macos_app_session_serialize_workspace(
    MaruAppHostSession *session,
    const uint8_t **out_ptr,
    size_t *out_len,
    uint32_t is_active,
    uint32_t has_frame,
    int32_t frame_x,
    int32_t frame_y,
    int32_t frame_w,
    int32_t frame_h
);
/* 앱 전역 checkpoint 연속 실패를 이 창의 비모달 status bar에 투영한다. 0=clear, 1=capture, 2=write. */
void maru_macos_app_session_set_workspace_checkpoint_failure(MaruAppHostSession *session, uint32_t failure);
void maru_macos_app_session_enable_workspace_checkpoint_mutations(MaruAppHostSession *session);
void maru_macos_app_session_disable_workspace_checkpoint_mutations(MaruAppHostSession *session);
/* accepted quit이 명시적 destructive "Quit and End All Sessions"인지 반환한다. */
uint32_t maru_macos_app_quit_end_all(void);

/* P4 C3 app-global checkpoint coordinator effect. generation은 capture부터 background write completion까지
   같은 immutable snapshot을 식별한다. notice는 같은 연속 실패 epoch의 첫 실패에만 nonzero다. */
typedef struct MaruWorkspaceCheckpointEffect {
    uint64_t generation;
    uint32_t kind;
    uint32_t reason;
    uint32_t notice;
} MaruWorkspaceCheckpointEffect;

/* Restore/default construction 뒤 main thread에서 한 번 arm한다. 초기 저장본이 없으면 initial_dirty=1로
   baseline checkpoint를 예약한다. 모든 coordinator 호출은 AppKit main thread 소유다. */
int32_t maru_macos_workspace_checkpoint_arm(uint32_t initial_dirty);
void maru_macos_workspace_checkpoint_mark_cross_window_commit(void);
void maru_macos_workspace_checkpoint_mark_window_inventory(void);
void maru_macos_workspace_checkpoint_mark_window_frame(void);
void maru_macos_workspace_checkpoint_mark_active_window(void);
int32_t maru_macos_workspace_checkpoint_tick(uint64_t now_ns, MaruWorkspaceCheckpointEffect *out_effect);
int32_t maru_macos_workspace_checkpoint_quit_requested(uint64_t now_ns, MaruWorkspaceCheckpointEffect *out_effect);
int32_t maru_macos_workspace_checkpoint_capture_completed(
    uint64_t generation,
    uint32_t succeeded,
    uint64_t now_ns,
    MaruWorkspaceCheckpointEffect *out_effect
);
int32_t maru_macos_workspace_checkpoint_write_completed(
    uint64_t generation,
    uint32_t succeeded,
    uint64_t now_ns,
    MaruWorkspaceCheckpointEffect *out_effect
);

/* C2 secure atomic publisher. parent_path는 canonical workspace.v1의 parent UTF-8 bytes이며 leaf 선택권은
   caller에게 주지 않는다. background serial queue에서 호출할 수 있고 반환은 WorkspaceCheckpointFile.Result 값이다. */
uint32_t maru_macos_workspace_checkpoint_publish(
    const uint8_t *parent_path,
    size_t parent_path_len,
    const uint8_t *snapshot,
    size_t snapshot_len
);
/* C4 final Quit publisher. preserve_previous!=0이면 기존 complete manifest를 secure create-once .bak으로
   보존하는 데 성공한 뒤에만 새 snapshot을 게시한다. */
uint32_t maru_macos_workspace_checkpoint_publish_final(
    const uint8_t *parent_path,
    size_t parent_path_len,
    const uint8_t *snapshot,
    size_t snapshot_len,
    uint32_t preserve_previous
);

/* 저장된 workspace 텍스트(헤더 + N개 창; UTF-8)에서 활성(key) 창의 인덱스를 준다(M3e). Swift가 복원 loop 뒤
   이 인덱스의 창을 makeKeyAndOrderFront해 재시작 후 활성 창을 되살린다. active-window=1 마커가 있는 첫 창의
   인덱스, 없으면(옛 파일·무마커·parse 실패) -1 → Swift 무동작(현행 동작 유지). 포맷 파싱은 Zig 단일 권위. */
int64_t maru_macos_app_session_workspace_active_window(
    MaruAppHostSession *session,
    const uint8_t *text_ptr,
    size_t text_len
);

/* 저장된 workspace 텍스트에서 window_index 창의 픽셀(점) frame(전역 스크린 좌표)을 out_x/y/w/h로 준다(M3f).
   Swift 복원 loop가 창마다 이 값을 받아 clamp 후 setFrame해 재시작 후 위치·크기·모니터를 되살린다. 반환:
   1=frame 있음(out_* 채움), 0=없음(옛 파일·부분 필드 → Swift가 현행 기본 cascade 유지), -1=parse 실패·null 인자.
   frame x/y는 음수 가능(보조 모니터). 포맷 파싱은 Zig 단일 권위 — workspace_active_window와 동형의 read-only getter. */
int32_t maru_macos_app_session_workspace_window_frame(
    MaruAppHostSession *session,
    const uint8_t *text_ptr,
    size_t text_len,
    size_t window_index,
    int32_t *out_x,
    int32_t *out_y,
    int32_t *out_w,
    int32_t *out_h
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

/* 저장된 workspace 텍스트(헤더 + N개 창; UTF-8)의 창 개수를 센다(Swift가 창마다 NSWindow 생성). 헤더·포맷과
   manifest-wide runtime binding semantic validation을 함께 수행한다. parse/semantic 실패(중복 owner 포함)면
   -1(Swift가 restore/checkpoint publish 건너뜀), 0이면 빈 workspace. Swift는 window 경계나 binding을 직접
   해석하지 않는다. session=NULL도 허용하며 첫 PTY 전 launch preflight와 write 전 checkpoint preflight에 쓴다. */
int64_t maru_macos_app_session_workspace_window_count(
    MaruAppHostSession *session,
    const uint8_t *text_ptr,
    size_t text_len
);

/* 시작 시 저장된 workspace 텍스트(헤더 + N개 창; UTF-8)에서 window_index번째 창을 parse해 이 세션에 복원
   적용한다. Swift는 전체 텍스트와 인덱스만 넘긴다(창 경계 분할은 Zig가 소유 — 파싱 권위 단일화). 0=ok,
   parse 실패·인덱스 범위 밖=invalid_config, apply 실패=create_failed. 일반 live 세션은 실패 시 기존 모델을
   보존하고 v142 deferred restore 세션은 빈 상태를 보존한다. host가 fallback/teardown을 결정한다. */
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

/* 폰트 크기(⌘+/−·config)가 바뀌어 열린 파일 패널 webview의 크기 재적용이 필요하면 1(플래그 비움), 없으면 0.
   Swift가 tick마다 호출해 1이면 편집기 폰트 pt를 재주입하고 프리뷰 iframe·HTML/PDF에 현재 줌 배율을 적용한다.
   take_command_catalog_dirty와 같은 1회성 신호. session null=0. v140. */
uint32_t maru_macos_app_session_take_file_panel_zoom_dirty(MaruAppHostSession *session);

/* 파일 패널 webview 줌 배율을 milli(1000=1.0)로 반환한다 — 현재 폰트 크기 / base_font_size(⌘0 기준). 프리뷰
   iframe CSS zoom·HTML/PDF pageZoom이 이 값을 쓴다. base 비정상이면 1000, 극단 배율은 [100,10000] 클램프. session null=1000. v140. */
uint32_t maru_macos_app_session_file_panel_zoom_milli(MaruAppHostSession *session);

/* quick terminal(전역 토글 오버레이 패널) 표시 옵션. 세션의 현재 config를 읽는 라이브 스냅샷(세션-불변 아님 —
   Swift가 매 토글마다 다시 읽어 설정 변경 반영). Swift가 auto_hide·화면 모드·chrome 재생성 판정에 쓴다. 패널
   사각형은 quick_terminal_frames가 따로 계산. screen: 0=main(주 디스플레이), 1=mouse(마우스가 있는 화면). */
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

/* quick 패널의 보임/숨김 사각형(macOS 좌표: 원점 좌하단, y 위로 증가). Swift가 대상 화면 visibleFrame을
   넘겨 세션의 현재 config로 계산해 받는다. quick_terminal_config와 달리 매 호출 라이브라 설정 변경이 다음
   토글에서 바로 반영된다. is_centered=1이면 center(보임=숨김, 슬라이드 대신 알파 페이드). */
typedef struct MaruAppHostQuickTerminalFrames {
    double shown_x;
    double shown_y;
    double shown_w;
    double shown_h;
    double hidden_x;
    double hidden_y;
    double hidden_w;
    double hidden_h;
    uint32_t is_centered;
    uint32_t _reserved;
} MaruAppHostQuickTerminalFrames;

int32_t maru_macos_app_session_quick_terminal_frames(
    MaruAppHostSession *session,
    double vf_x, double vf_y, double vf_w, double vf_h,
    MaruAppHostQuickTerminalFrames *out_frames
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

/* ── Phase 4e-3: 웹 Term(WKWebView) surface 전이 batch ─────────────────────────────────────────
   활성 워크스페이스 탭의 pane 트리를 walk해 **web Term마다** WKWebView 하나를 관리한다(§6 "web surface는 Term").
   Zig가 4a 순수 계산(contentRect·pxTopLeftToPtBottomLeft·surfaceDiff)으로 직전 tick 집합과 diff해 **batch 전이**를
   계산·보관하고(count), Swift는 각 전이를 op만 기계적으로 적용한다: webPanels[surface_id] dict의 WKWebView를 생성
   (z-order 중간=터미널<웹뷰들<오버레이 삽입)·파괴·reframe·hide·show한다. 각 웹뷰는 **자기 pane 본문 rect에 고정**
   (frame=pt·좌하단·컨테이너 좌표) — 4c의 활성 pane 추종을 완전 제거한다. 같은 pane의 활성 Term만 show·비활성 탭은
   hidden(상태 유지), 비활성 워크스페이스 탭의 web Term은 destroy. 콘텐츠·브리지·보안(Phase 5)은 범위 밖.
   docs/web-panel.md §2·§6·§10 4e-3·§14. */
typedef enum MaruAppHostWebSurfaceOp {
    MaruAppHostWebSurfaceOpNone = 0,    /* 무동작(범위 초과 at 조회 폴백) */
    MaruAppHostWebSurfaceOpCreate = 1,  /* WKWebView 생성 + frame + z-order 중간 삽입(visible=1이면 show, 0이면 hidden; frame_pt 유효) */
    MaruAppHostWebSurfaceOpDestroy = 2, /* WKWebView 파괴(surface_id만 유효) */
    MaruAppHostWebSurfaceOpReframe = 3, /* frame 갱신(frame_pt 유효) */
    MaruAppHostWebSurfaceOpHide = 4,    /* isHidden=true(surface_id만 유효 — 같은 pane 비활성 탭 web Term) */
    MaruAppHostWebSurfaceOpShow = 5,    /* isHidden=false + 최신 frame(frame_pt 유효) */
} MaruAppHostWebSurfaceOp;

/* batch 한 항목의 웹 surface 전이. frame_pt_*는 pt·좌하단(컨테이너 content view 좌표) — WKWebView.frame에 그대로 쓴다.
   visible: create 시 1=즉시 show, 0=hidden 생성(같은 pane 비활성 탭). show/reframe=함의상 1, hide/destroy엔 무의미.
   panel_kind: 0=markdown, 1=browser(생성 시 Phase 5 trust/config 선택용). */
typedef struct MaruAppHostWebSurfaceTransition {
    uint32_t op;         /* MaruAppHostWebSurfaceOp */
    uint32_t visible;    /* create: 1=show, 0=hidden 생성 */
    uint64_t surface_id; /* 앱 전역 unique·비재사용(§3) — 전이 매칭 안정 키 */
    uint32_t panel_kind; /* 0=markdown, 1=browser */
    uint32_t seam_edges; /* divider 맞닿는 가장자리 비트마스크: left=1, right=2, bottom=4 (hitTest 통과용) */
    double divider_grab_left_pt;   /* 최종 frame left와 실제 Zig resize target의 교집합 폭(pt) */
    double divider_grab_right_pt;  /* 최종 frame right와 실제 Zig resize target의 교집합 폭(pt) */
    double divider_grab_bottom_pt; /* 최종 frame bottom과 실제 Zig resize target의 교집합 폭(pt) */
    double frame_pt_x;
    double frame_pt_y;
    double frame_pt_w;
    double frame_pt_h;
} MaruAppHostWebSurfaceTransition;

/* 이번 tick의 웹 surface 전이 batch 개수. Zig가 활성 워크스페이스 탭 pane 트리를 walk해 web Term 집합을 diff한 batch를
   계산·보관하고 개수를 돌려준다. Swift는 metal_frame 직후(같은 tick·같은 스레드) 정확히 한 번 호출한다(prev 전진). session NULL=0. */
uint32_t maru_macos_app_session_web_surface_transitions_count(MaruAppHostSession *session);

/* index번째 전이를 out에 채운다(위 count 이후, 같은 tick·스레드). session/out이 NULL이면 NullOut, 범위 밖이면 op=None으로 Ok. */
int32_t maru_macos_app_session_web_surface_transition_at(
    MaruAppHostSession *session,
    uint32_t index,
    MaruAppHostWebSurfaceTransition *out
);

/* Phase 7e-1a: browser(비신뢰) 웹 패널의 WKWebView nav 상태(현재 url·canGoBack·canGoForward)를 per-surface로 저장한다.
   Swift KVO(MaruWebPanelView)가 url/canGoBack/canGoForward 변화를 관측해 dirty면 tick drain에서 호출한다 — 관측·
   marshaling은 Swift(L4 어댑터), 저장·정책은 Zig. can_go_back/forward는 0/1, url_ptr NULL이면 빈 url. session NULL=NullOut.
   소비(주소창 렌더)는 7e-1b. v104. */
int32_t maru_macos_app_session_set_web_nav_state(
    MaruAppHostSession *session,
    uint64_t surface_id,
    int32_t can_go_back,
    int32_t can_go_forward,
    const uint8_t *url_ptr,
    size_t url_len
);

/* surface_id에 저장된 nav url을 out에 복사하고 그 길이를 돌려준다(스모크가 KVO → set_web_nav_state → 저장 → getter
   왕복을 값으로 검증). 엔트리 없으면 0(빈 url 저장도 0), session/out이 NULL이면 -1, out_cap 부족이면 -2. v104. */
int64_t maru_macos_app_session_web_nav_url_at(
    MaruAppHostSession *session,
    uint64_t surface_id,
    uint8_t *out_ptr,
    size_t out_cap
);

/* Phase 7e-2b: 주소창 편집 신호 drain(tick마다). (1) focus-pull: 편집 진입 시 "포커스를 터미널 뷰로"(1=있음, keyDown이
   Zig로 흐르게). (2) navigate: Enter 시 로드 요청 — url을 out에, surface_id를 out-ptr에, url 길이 반환(없으면 -1) →
   BrowserControl.navigate. (3) focus-restore: commit/cancel 후 웹뷰로 포커스 복원 대상 surface_id(out-ptr, 1=있음). */
/* §8 슬라이스 ②: 웹 탭 페이지 찾기(⌘F). (1) take: 1회성 질의를 걷어 간다 — query를 out에, 길이·surface_id·backwards를
   out-ptr에 싣고 seq 반환(0=없음) → BrowserControl.find. (2) provide: WKWebView.find completion 결과(찾음 여부)를 seq와
   함께 되돌린다(늦은 회신은 Zig가 버린다). */
uint64_t maru_macos_app_session_take_web_find_query(
    MaruAppHostSession *session,
    uint8_t *query_out,
    size_t query_cap,
    size_t *query_len_out,
    uint64_t *surface_id_out,
    uint32_t *backwards_out
);
void maru_macos_app_session_provide_web_find_result(MaruAppHostSession *session, uint64_t seq, uint32_t found);
void maru_macos_app_session_web_find_undeliverable(MaruAppHostSession *session, uint64_t seq);

uint32_t maru_macos_app_session_take_web_addr_focus_pull(MaruAppHostSession *session);
int64_t maru_macos_app_session_take_web_addr_navigate(
    MaruAppHostSession *session,
    uint8_t *url_out,
    size_t url_cap,
    uint64_t *surface_id_out
);
int32_t maru_macos_app_session_take_web_addr_focus_restore(MaruAppHostSession *session, uint64_t *surface_id_out);

/* Phase 7e-3: 주소창 nav 버튼(back/forward/reload) 클릭 신호 drain(tick마다). 밴드 좌측 버튼 존 클릭이 활성 버튼일 때
   세워진 1회성 pending을 뺀다. 반환: action code(-1=없음, 0=back·1=forward·2=reload), surface_id는 out-ptr →
   BrowserControl.goBack/goForward/reload. session/out NULL이면 -1. v106. */
int32_t maru_macos_app_session_take_web_nav_action(MaruAppHostSession *session, uint64_t *surface_id_out);

/* Phase 7e-4: 주소창 nav 버튼 키보드 단축키(browser 웹 패널 포커스 한정 Cmd+←/→/R). Swift performKeyEquivalent가
   panelKind==browser일 때 code(0=back·1=forward·2=reload)로 마샬링해 부른다. Zig가 setBrowserNavAction(클릭 ①b와
   공유하는 활성 판정)으로 pending을 세우고, 같은 tick의 take_web_nav_action drain이 BrowserControl을 실행한다(클릭
   경로 재사용). 반환: 1=전달, 0=session NULL/알 수 없는 code. v107. */
int32_t maru_macos_app_session_browser_nav(MaruAppHostSession *session, uint64_t surface_id, uint32_t code);

/* Phase 7e-4 후속: 활성 pane의 활성 term이 browser web이면 그 surface_id, 아니면 0(browser 아님/session NULL). Swift
   performKeyEquivalent가 browser nav 단축키(⌘←/→/R)를 이 값 == 이 패널 surface_id일 때만 처리해, WKWebView 키보드
   포커스 유무와 무관하게 "지금 활성 탭이 browser면" 동작하게 게이트한다. 0은 유효 surface_id 아님(sentinel). v108. */
uint64_t maru_macos_app_session_active_web_surface_id(MaruAppHostSession *session);

/* Phase 4g-0: 활성 pane 활성 term이 web(browser·markdown 무관)이면 surface_id, 아니면 0. focus-sync 불변식(§4.1)
   Direction 1이 "활성=web이면 그 webview 포커스, 아니면 터미널 뷰"를 정하는 데 쓴다(activeWebSurfaceId는 browser
   전용이라 markdown 활성 시 0). 0=유효 surface_id 아님(sentinel). v112. */
uint64_t maru_macos_app_session_active_web_surface_id_any_kind(MaruAppHostSession *session);

/* Phase 4g-1 후속(14차 리뷰 [0][3]): 입력이 터미널 뷰→Zig 경로로 가야 하는가(모달[notice 제외]·주소창 편집·rename·
   사이드바 검색 중 하나라도면 1). focus-sync 불변식(reconcileWebFocus) override 단일 출처 — 1이면 웹뷰가 아니라
   터미널 뷰가 firstResponder여야. addr_edit_surface를 대체(그건 rename·사이드바 검색을 빠뜨림). v114. */
uint32_t maru_macos_app_session_terminal_owns_input(MaruAppHostSession *session);

/* Phase 7f-0: 새 창/팝업 adopt — Swift WKUIDelegate.createWebViewWith가 WebKit config로 만든 WKWebView를 붙일
   browser web Term을 활성 pane에 새 탭으로 만들고 surface_id를 반환한다(Swift-first 동기 생성). Swift는 이 id로
   pre-created webview를 webPanels에 키잉하고, drain은 존재 시 중복 WKWebView 생성을 스킵한다(7f-1). 반환:
   새 surface_id(>=1), 또는 0(session NULL·생성 실패 sentinel). v109. */
uint64_t maru_macos_app_session_create_adopted_web_term(MaruAppHostSession *session);

/* 4e-4(web-panel §10): 이 세션 트리에 그 web surface_id가 있으면 1, 없으면 0. drainWebSurfaceTransition이 원본 창의
   web surface destroy 전이에서 다른 창 세션들에 물어 이동(다른 창 live)↔닫힘(부재)을 구분한다 — live면 WKWebView를
   파괴 않고 재부모화 대상으로 살려두고 browser.closed를 억제한다. additive export(버전 불변). */
uint32_t maru_macos_app_session_has_web_surface(MaruAppHostSession *session, uint64_t surface_id);

/* maru-app:// asset resolve(5c-2b): WKURLSchemeHandler(5c-2c)가 요청 경로를 안전한 절대 경로로 resolve한다.
   정책(경로 샌드박스·realpath symlink 탈출 방어)은 Zig 소유, Swift는 반환 경로를 읽어 CSP와 함께 서빙만 한다.
   반환: >=0 = out에 쓴 canonical 절대 경로 길이. 음수 = 에러(-1 Reject, -2 NotFound, -3 OutsideRoot, -4 NULL). */
int64_t maru_macos_app_resolve_app_asset(
    uint32_t role,
    const uint8_t *root_ptr,
    size_t root_len,
    const uint8_t *req_ptr,
    size_t req_len,
    uint8_t *out_ptr,
    size_t out_cap
);

/* role(0=app, 1=render)별 maru-app:// CSP. cap 부족=-1, NULL=-2, role 거부=-3. v132. */
int64_t maru_macos_app_csp_header(uint32_t role, uint8_t *out_ptr, size_t out_cap);
/* exact URL origin을 asset role(0=app, 1=render)로 변환. 거부/NULL=-1. v132. */
int maru_macos_app_asset_role_for_origin(
    const uint8_t *scheme_ptr,
    size_t scheme_len,
    const uint8_t *host_ptr,
    size_t host_len,
    int has_explicit_port
);
int maru_macos_app_origin_allowed(
    const uint8_t *scheme_ptr,
    size_t scheme_len,
    const uint8_t *host_ptr,
    size_t host_len,
    int has_explicit_port,
    uint32_t role
);

/* Phase 7f-2: 새 창/팝업(WKUIDelegate.createWebViewWith) 대상 URL 정책 게이트. Swift가 navigationAction.request.url을
   넘기면 Zig app_scheme.popupTargetAllowed(허용 = about·http·https·빈만, javascript·file·data·blob·maru-app 거부)로
   판정한다. 반환: 1=허용, 0=거부, -1=url_ptr NULL. 세션리스 순수 정책. v111. */
int maru_macos_app_popup_target_allowed(const uint8_t *url_ptr, size_t url_len);

/* 신뢰 웹 브리지(window.maru.*) 요청 디스패치(5b). Swift가 isolated world 핸들러서 isMainFrame + securityOrigin
   (maru-app://app) 검증 후 요청 JSON을 넘기면 응답 JSON을 out에 쓴다. 반환: >=0=응답 길이, -1=용량부족, -2=NULL, -3=OOM. */
int64_t maru_macos_app_bridge_dispatch(
    const uint8_t *req_ptr,
    size_t req_len,
    uint8_t *out_ptr,
    size_t out_cap
);

/* 파일 패널용 session-scoped bridge. surface_id가 핀한 markdown entry에
   file.beginDocument{document_id}/read{editor_epoch}/readAsset, pathless file.write{editor_epoch,content},
   request-scoped file.setDirty{dirty,editor_epoch,revision,request_id},
   file.resolveExternalChange{editor_epoch,success}, file.openLink{href,forceSystem}를 제공한다. read 계열은
   out=NULL,out_cap=0 size query 뒤 exact buffer로 재호출한다.
   mutation 계열은 side effect 중복을 막기 위해 충분한 고정 buffer로 한 번만 호출한다. 기존 hello도 처리한다.
   음수: -2=NULL/잘못된 query, -3=OOM. v122/v125/v126/v135. */
int64_t maru_macos_app_session_bridge_dispatch(
    MaruAppHostSession *session,
    uint64_t surface_id,
    const uint8_t *req_ptr,
    size_t req_len,
    uint8_t *out_ptr,
    size_t out_cap
);

/* 현재 markdown WebContent document가 종료됐음을 Zig 수명 정책에 전달한다. exact current panel 검증은 Swift,
   dirty/recovery latch와 stale document 차단은 Zig가 소유한다. 0=stale/부재, 1=safe reload, 2=recovery latch. v135. */
uint32_t maru_macos_app_session_file_panel_document_terminated(
    MaruAppHostSession *session,
    uint64_t surface_id
);

/* 검증과 no-follow open을 한 Zig operation으로 묶어 같은 fd bytes만 반환한다. 반환은 byte 수, 실패는 음수. */
int64_t maru_macos_app_read_app_asset(
    uint32_t role,
    const uint8_t *root_ptr,
    size_t root_len,
    const uint8_t *request_path_ptr,
    size_t request_path_len,
    uint8_t *out_ptr,
    size_t out_cap
);

/* ── FP10c1 Mermaid helper codec/coordinator ───────────────────────────────────────────────
   wire layout과 queue/failure 정책은 Zig session 모듈이 단독 소유한다. Swift parent/helper는 이 DTO의
   fixed-width identity와 opaque body bytes만 운반하며 frame header/endianness를 직접 해석하지 않는다. */

typedef struct MaruMermaidRendererCapability {
    uint64_t editor_epoch;
    uint64_t document_revision;
    uint64_t projection_generation;
    uint64_t widget_id;
    uint64_t widget_generation;
    uint64_t renderer_instance;
} MaruMermaidRendererCapability;

typedef struct MaruMermaidJobCapability {
    uint64_t helper_instance;
    uint64_t job_id;
    MaruMermaidRendererCapability renderer;
    uint64_t fence_id;
    uint8_t source_hash[32];
} MaruMermaidJobCapability;

typedef struct MaruMermaidRgb {
    uint8_t r;
    uint8_t g;
    uint8_t b;
} MaruMermaidRgb;

// v3: 터미널 파생 mermaid 팔레트(mermaid_protocol.Palette 미러). helper가 themeVariables 구성에 쓴다.
typedef struct MaruMermaidPalette {
    MaruMermaidRgb background;
    MaruMermaidRgb primary;
    MaruMermaidRgb primary_border;
    MaruMermaidRgb primary_text;
    MaruMermaidRgb line;
    MaruMermaidRgb text;
    MaruMermaidRgb secondary;
    MaruMermaidRgb tertiary;
} MaruMermaidPalette;

typedef struct MaruMermaidDecodedFrame {
    uint32_t tag;
    uint32_t status;
    uint64_t helper_instance;
    uint64_t nonce;
    MaruMermaidJobCapability capability;
    const uint8_t *body_ptr;
    size_t body_len;
    MaruMermaidPalette palette;
} MaruMermaidDecodedFrame;

typedef struct MaruMermaidCoordinatorAction {
    uint32_t kind;
    uint32_t spawn_helper;
    uint64_t deadline_ms;
    uint64_t hello_nonce;
    MaruMermaidJobCapability capability;
    const uint8_t *request_frame_ptr;
    size_t request_frame_len;
} MaruMermaidCoordinatorAction;

typedef struct MaruMermaidCoordinatorSnapshot {
    size_t pending_jobs;
    size_t pending_source_bytes;
    size_t accepted_results;
    size_t accepted_svg_bytes;
    size_t terminal_results;
    uint64_t helper_instance;
    uint64_t helper_starts;
    uint64_t deadline_expirations;
    uint64_t admission_copies;
    uint32_t in_flight;
    uint32_t disabled;
    uint32_t action_handoff_pending;
    uint32_t termination_in_progress;
} MaruMermaidCoordinatorSnapshot;

typedef struct MaruMermaidAcceptedResult {
    uint64_t window_id;
    MaruMermaidJobCapability capability;
    size_t svg_len;
} MaruMermaidAcceptedResult;

typedef struct MaruMermaidTerminalResult {
    uint64_t window_id;
    uint64_t job_id;
    MaruMermaidRendererCapability renderer;
    uint32_t reason;
} MaruMermaidTerminalResult;

typedef struct MaruMermaidDecoder MaruMermaidDecoder;

MaruMermaidDecoder *maru_mermaid_protocol_decoder_create(void);
void maru_mermaid_protocol_decoder_destroy(MaruMermaidDecoder *decoder);
int32_t maru_mermaid_protocol_decoder_feed(MaruMermaidDecoder *decoder, const uint8_t *bytes, size_t len);
/* 1=frame, 0=incomplete, 음수=malformed/invalid pointer. body_ptr는 다음 feed/next 전까지만 유효하다. */
int32_t maru_mermaid_protocol_decoder_next(MaruMermaidDecoder *decoder, MaruMermaidDecodedFrame *out_frame);
int32_t maru_mermaid_protocol_decoder_finish(MaruMermaidDecoder *decoder);
uint32_t maru_mermaid_protocol_matches_hello_ack(const MaruMermaidDecodedFrame *frame, uint64_t helper_instance, uint64_t nonce);

/* 반환: 쓴 길이, -1=invalid, -2=output too small. */
int64_t maru_mermaid_protocol_encode_hello(uint32_t ack, uint64_t helper_instance, uint64_t nonce, uint8_t *out, size_t out_cap);
int64_t maru_mermaid_protocol_encode_request(const MaruMermaidJobCapability *capability, const uint8_t *source, size_t source_len, const MaruMermaidPalette *palette, uint8_t *out, size_t out_cap);
int64_t maru_mermaid_protocol_encode_result(const MaruMermaidJobCapability *capability, uint32_t status, const uint8_t *body, size_t body_len, uint8_t *out, size_t out_cap);

/* 앱 전역 AppRuntime.mermaid_queue에 job을 제출한다. 0=accepted, 음수=closed validation/cap 거부. */
int32_t maru_macos_mermaid_admit(uint64_t window_id, const MaruMermaidRendererCapability *renderer, uint64_t fence_id, const uint8_t *source, size_t source_len);
/* 1=action, 0=none, -1=invalid out. request frame은 opaque이며 exact handoff ack 전까지 불변이다. */
int32_t maru_macos_mermaid_drain_action(uint64_t now_ms, MaruMermaidCoordinatorAction *out_action);
/* executor가 request frame을 owned storage로 복사한 exact ack. 1=current lease, 0=stale. */
uint32_t maru_macos_mermaid_complete_action_handoff(uint64_t helper_instance, uint64_t job_id);
/* decoded Result만 수용한다. 1=accepted, 2=render error, 0=stale, 음수=invalid/failure. */
int32_t maru_macos_mermaid_complete_decoded(const MaruMermaidDecodedFrame *frame, uint64_t arrival_ms);
/* transient는 integrity=0, bundle/signature/protocol/Hello mismatch는 integrity=1. 1=현재 helper 처리, 0=stale. */
uint32_t maru_macos_mermaid_report_failure(uint64_t helper_instance, uint64_t now_ms, uint32_t integrity);
uint32_t maru_macos_mermaid_expire_deadline(uint64_t now_ms);
uint32_t maru_macos_mermaid_complete_termination(uint64_t helper_instance);
/* physical adapter가 quiesce된 app 종료에서 queue/latch/lease를 최종 회수한다. */
void maru_macos_mermaid_shutdown(void);
void maru_macos_mermaid_snapshot(MaruMermaidCoordinatorSnapshot *out_snapshot);
/* allocation-free frame-tick gate와 exact renderer lifetime revoke. */
uint32_t maru_macos_mermaid_has_work(void);
void maru_macos_mermaid_revoke_renderer(uint64_t window_id, const MaruMermaidRendererCapability *renderer);
void maru_macos_mermaid_revoke_job(uint64_t window_id, uint64_t job_id, const MaruMermaidRendererCapability *renderer);
/* accepted SVG 한 건을 caller buffer로 one-shot 이동한다. 1=result, 0=none, -1=invalid, -2=buffer too small. */
int32_t maru_macos_mermaid_take_accepted(MaruMermaidAcceptedResult *out_result, uint8_t *out_svg, size_t out_cap);
/* coalesce/failure가 회수한 exact Promise terminal. reason은 닫힌 Zig enum. 1=result, 0=none, -1=invalid. */
int32_t maru_macos_mermaid_take_terminal(MaruMermaidTerminalResult *out_result);

/* ── 세션 컨트롤 플레인 라이브 서버(Track C A2b) ──────────────────────────────────────────────
   앱 인스턴스 전역 컨트롤 소켓 + accept 스레드 + 메인 marshal. Swift는 (1) 시작 시 start를 한 번,
   (2) 매 frame tick에 drain을 살아있는 세션 목록과 함께, (3) 종료 시 stop을 부른다. 소켓/스레드/
   collector/dispatch/auth는 전부 Zig가 소유한다(Swift는 열거만 — docs/control-plane.md §2·§5). */

/* 한 세션(창)에 대한 collector 참조 — Swift가 창마다 채운다(§2 열거). window_id=위치 메타(Swift의
   창 토큰), window_kind: 0=일반 창, 1=quick terminal. app_session이 NULL이면 그 항목은 건너뛴다. */
typedef struct MaruControlSessionRef {
    MaruAppHostSession *app_session;
    uint64_t window_id;
    uint32_t window_kind;
    uint32_t reserved; /* 8바이트 정렬 패딩(향후 확장) */
} MaruControlSessionRef;

/* 컨트롤 소켓을 bind하고 accept 스레드를 띄운다(앱 인스턴스 전역, 결정론 경로 <cache>/maru/control).
   0=ok(또는 이미 시작됨), 비-0=실패(소켓 bind 불가 등 — 컨트롤 플레인만 꺼지고 앱은 계속). idempotent. */
int32_t maru_macos_control_server_start(void);

/* 값싼 per-tick 게이트: 대기 중인 컨트롤 요청이 하나라도 있으면 1, 없으면 0. Swift가 매 tick drain 전에
   이걸 봐 pending이 없으면 refs 배열(힙 할당+창별 copy)을 아예 짓지 않고 early return한다(렌더 핫패스 0-할당).
   서버 미시작이면 0. drain과 동일 no-handle(앱-전역 서버). 짧은 큐 락만 잡는다. take_* predicate와 같은 u32(1/0). */
uint32_t maru_macos_control_server_has_pending(void);

/* 대기 중인 컨트롤 요청을 메인에서 처리한다(매 frame tick). refs=살아있는 세션 목록(창마다 하나 +
   quick). 요청마다 실 collector(refs 순회)로 스냅샷을 만들고 auth(metadata:self)·dispatch해 응답한다.
   서버 미시작이면 무동작. per-tick 처리량은 Zig가 제한한다(§5). refs가 NULL이면 count=0으로 취급. */
void maru_macos_control_server_drain(const MaruControlSessionRef *refs, size_t count);

/* accept 스레드를 멈추고 join한 뒤 소켓을 닫는다(앱 종료 시). idempotent(미시작이면 무동작). */
void maru_macos_control_server_stop(void);

/* 5e-2b: 매 frame tick 호출 — (1) hung browser op timeout reap, (2) browser op 큐에서 하나 pop. 반환 1=op 있음·0=없음.
   op 있으면 Swift가 out_surface_id의 webView를 찾아 BrowserControl에서 실행한다. op_kind:
   0=navigate·1=getUrl·2=executeScript·4=getCookies·5=screenshot·6=setCookie·7=deleteCookie·
   8=getLocalStorage·9=setLocalStorage·10=removeLocalStorage·11=clearStorage·12=click·13=type·14=scroll·15=wait.
   완료 시 complete_browser_op(out_async_id, ...)로 되돌린다. out_arg_ptr는 **이 호출 중에만** 유효(Swift가 즉시 복사).
   서버 미시작이면 0. 메인 스레드에서만. */
uint32_t maru_macos_control_take_browser_op(uint64_t *out_async_id, uint64_t *out_surface_id, uint8_t *out_op_kind,
                                            const uint8_t **out_arg_ptr, size_t *out_arg_len);

/* 5e-2b: BrowserControl async 완료 콜백이 호출 — async_id 요청을 결과로 응답한다. status:
   0=success·1=failed·2=timeout·3=invalid_params·4=process_exited·5=unauthorized. result는 method별
   (getUrl=url·executeScript=반환값 문자열·getCookies=쿠키 JSON 배열·navigate/wait=무시; error면 message).
   미지/timeout된 async_id는 무시(늦은 콜백). 메인 스레드에서만(WKWebView 콜백이 메인). */
void maru_macos_control_complete_browser_op(uint64_t async_id, uint32_t status, const uint8_t *result, size_t result_len);

/* 5f-5b: executeScript 성공 JSON은 Swift registry가 immutable Data로 소유하고 Zig가 bounded pull한다.
   copy는 0..dst_cap bytes, EOF=0, 오류=-1. release는 1=released, 2=already absent, 0=failure이며
   1/2 뒤에는 Data가 반드시 없어야 한다. release 0이면 함수도 0을 반환하고, Swift가 직접 release한 뒤 일반
   complete_browser_op을 호출할 때까지 Zig가 execution 예약을 유지한다.
   이 함수가 1을 반환하면 transfer_id를 인수했거나 inline release까지 마쳤다. progressive 결과는 이후 pump terminal에서
   release하며, 0이면 Swift가 직접 release하고 일반 실패 완료를 보내야 한다. 메인 스레드에서만 호출한다. */
typedef int64_t (*MaruBrowserResultCopyFn)(void *context, uint64_t transfer_id, uint64_t offset,
                                           uint8_t *dst, size_t dst_cap);
typedef uint32_t (*MaruBrowserResultReleaseFn)(void *context, uint64_t transfer_id);
uint32_t maru_macos_control_complete_browser_result(uint64_t async_id, uint64_t transfer_id, size_t total_len,
                                                     void *context, MaruBrowserResultCopyFn copy_result,
                                                     MaruBrowserResultReleaseFn release_result);
uint32_t maru_macos_control_complete_browser_screenshot_result(uint64_t async_id, uint64_t transfer_id, size_t total_len,
                                                                void *context, MaruBrowserResultCopyFn copy_result,
                                                                MaruBrowserResultReleaseFn release_result);
/* 앱 전체 frame tick당 executeScript/screenshot progressive 청크 또는 terminal 최대 하나를 처리한다. */
uint32_t maru_macos_control_pump_browser_result(void);
/* Registry per-entry cap보다 큰 strict JSON Data는 Swift가 먼저 폐기한 뒤 길이만 전달한다. Zig가 재인가하고
   request의 max_result_bytes를 사용해 result-too-large terminal을 만든다. 메인 스레드 전용. */
void maru_macos_control_complete_browser_result_too_large(uint64_t async_id, size_t observed_len);

void maru_macos_control_complete_browser_script_error(uint64_t async_id, const uint8_t *error_json_ptr, size_t error_json_len);

/* browser.wait polling이 다음 DOM 평가 전에 요청 생존 여부를 확인한다. revoke/close/reap/완료 후 0.
   서버 미시작이면 0. 메인 스레드에서만. */
uint32_t maru_macos_control_browser_wait_is_active(uint64_t async_id);

/* off-main executeScript syntax validation 뒤 page 실행 직전에 running+pending+인가를 재확인한다.
   revoke/expiry/timeout/server stop 뒤 0. 메인 스레드에서만. */
uint32_t maru_macos_control_browser_execution_may_start(uint64_t async_id);

/* 5e-2b-2(테스트 전용): env MARU_TEST_BROWSER_CAP이 설정됐을 때만 surface_id에 묶인 browser cap을 라이브 store에
   발급하고 nonce(raw 32B)를 out_nonce로 넘긴다. 반환 1=발급·0=env 미설정/용량 부족/실패. macos smoke가 소켓
   browser.navigate(이 nonce)→실 WKWebView 이동을 자동 증명하는 용도. 프로덕션 무영향(env 미설정=무동작). 메인 스레드만. */
uint32_t maru_macos_control_test_issue_browser_cap(uint64_t surface_id, uint8_t *out_nonce, size_t out_nonce_cap);

/* 5e-2b-2(테스트 전용): 라이브 컨트롤 서버가 바인딩한 유닉스 소켓 경로를 out에 복사하고 길이를 반환한다(0=미시작/용량
   부족). smoke의 인-프로세스 소켓 클라이언트가 자기 앱 소켓에 connect하는 데 쓴다(경로는 비밀 아님). NUL 미포함 길이. */
size_t maru_macos_control_socket_path(uint8_t *out, size_t out_cap);

/* 5f-0b-3c: WKWebView url KVO(메인 스레드)에서 호출 — 그 web surface의 browser.navigated 이벤트를 구독자에게 push한다.
   구독자 없으면 무비용 조기 반환(match-first). 서버 미시작이면 무동작. url은 이 호출 중만 유효(내부서 프레임에 복사). 메인 스레드만. */
void maru_macos_control_push_browser_navigated(uint64_t surface_id, const uint8_t *url_ptr, size_t url_len);

/* 5f-3a: isLoading KVO → browser.loadState(loading!=0 → loading, else idle). 메인 스레드만. */
void maru_macos_control_push_browser_load_state(uint64_t surface_id, uint8_t loading);

/* 5f-3b: WKUIDelegate JS 다이얼로그 → browser.dialog(kind: 0=alert·1=confirm·2=prompt, message). 메인 스레드만. */
void maru_macos_control_push_browser_dialog(uint64_t surface_id, uint8_t kind, const uint8_t *message_ptr, size_t message_len);

/* 5f-3c: webViewWebContentProcessDidTerminate → browser.crashed. 메인 스레드만. */
void maru_macos_control_push_browser_crashed(uint64_t surface_id);

/* 5f-3d: web surface 소멸 직전 → browser.closed 이벤트 push 후 그 surface 구독 정리. 메인 스레드만. */
void maru_macos_control_push_browser_closed(uint64_t surface_id);

// grant UX(revoke, §9.2): 부여한 모든 pane-bound browser grant를 취소하고 취소 수를 반환한다(메뉴 "Revoke All").
uint32_t maru_macos_control_revoke_all_browser_grants(void);

// grant UX(per-grant revoke, §9.2): "Browser Grants" 서브메뉴 동적 생성용. count로 항목 수를, grant_at으로 각 grant의
// (pane, target, scope[wire u8: 0=browser·1=browser_storage])를 읽고, revoke_browser_grant로 하나만 취소한다(값 기반·멱등).
uint32_t maru_macos_control_browser_grant_count(void);
uint32_t maru_macos_control_browser_grant_at(uint32_t index, uint64_t *out_pane, uint64_t *out_target, uint8_t *out_scope);
uint32_t maru_macos_control_revoke_browser_grant(uint64_t pane, uint64_t target, uint8_t scope);

#endif
