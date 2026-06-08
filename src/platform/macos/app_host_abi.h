#ifndef MARU_PLATFORM_MACOS_APP_HOST_ABI_H
#define MARU_PLATFORM_MACOS_APP_HOST_ABI_H

#include <stdint.h>

/* 이 header는 실제 앱 동작을 구현하지 않고 Swift/Zig 사이의 약속만 고정한다.
   Swift가 AppKit object나 Swift struct layout을 바로 넘기면 Zig 쪽에서 안전하게
   해석할 수 없으므로, 제품 host가 시작되기 전에 fixed-width C record만 허용한다. */
#define MARU_MACOS_APP_HOST_ABI_VERSION 1u

typedef enum MaruAppHostStatus {
    MaruAppHostStatusOk = 0,
    MaruAppHostStatusNullOut = 1,
    MaruAppHostStatusUnsupportedAbi = 2,
} MaruAppHostStatus;

typedef enum MaruAppHostEventKind {
    MaruAppHostEventNone = 0,
    MaruAppHostEventFrameTick = 1,
    MaruAppHostEventKeyDown = 2,
    MaruAppHostEventResize = 3,
    MaruAppHostEventCloseRequested = 4,
    MaruAppHostEventAppShouldTerminate = 5,
} MaruAppHostEventKind;

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

uint32_t maru_macos_app_host_abi_version(void);
int32_t maru_macos_app_host_capabilities(MaruAppHostCapabilities *out_capabilities);

#endif
