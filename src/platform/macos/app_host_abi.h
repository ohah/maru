#ifndef MARU_PLATFORM_MACOS_APP_HOST_ABI_H
#define MARU_PLATFORM_MACOS_APP_HOST_ABI_H

#include <stdint.h>
#include <stddef.h>

/* 이 header는 실제 앱 동작을 구현하지 않고 Swift/Zig 사이의 약속만 고정한다.
   Swift가 AppKit object나 Swift struct layout을 바로 넘기면 Zig 쪽에서 안전하게
   해석할 수 없으므로, 제품 host가 시작되기 전에 fixed-width C record만 허용한다. */
#define MARU_MACOS_APP_HOST_ABI_VERSION 5u

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
    uint32_t reserved;
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
    uint32_t reserved;
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
    uint32_t reserved1;
} MaruAppHostDevFrameSummary;

/* 가장 최근 tick의 RenderFrame을 Metal로 그리기 위한 DTO. cell 하나가 atlas slot 1개와 그
   UV 사각형을 가리킨다. layout은 Zig metal_frame.NativeMetalCell과 1:1로 맞춘다. */
typedef struct MaruAppHostDevMetalCell {
    uint16_t row;
    uint16_t col;
    uint16_t width;
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
    uint64_t generation;
    const MaruAppHostDevMetalCell *cells;
    size_t cell_count;
    const MaruAppHostDevMetalRasterUpload *raster_uploads;
    size_t raster_upload_count;
    const uint8_t *raster_pixels;
    size_t raster_pixel_count;
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
void maru_macos_app_dev_session_destroy(MaruAppHostDevSession *session);
int32_t maru_macos_app_dev_session_metal_frame(
    MaruAppHostDevSession *session,
    MaruAppHostDevMetalFrame *out_frame
);

#endif
