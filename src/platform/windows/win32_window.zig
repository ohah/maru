//! Win32 창과 메시지 펌프 — W7.1.
//!
//! **이 파일은 "창"만 안다.** 그리는 것도, 키를 해석하는 것도 여기 없다. 창이 하는 일은 셋이다:
//! 창을 만들고, 메시지를 펌프하고, OS 이벤트를 **중립 이벤트**로 바꿔 호출자에게 준다. 그 이벤트를
//! `app/host.zig`의 `resizeActiveSurface`·`closeActiveLivePty` 같은 것에 어떻게 연결할지는 호출자 몫이다 —
//! 그래야 창이 앱 정책을 알지 않는다(macOS에서 `MaruAppHost`가 `AppSession`을 부르는 것과 같은 분담).
//!
//! **호스트에 제2 언어를 두지 않는다**(계약 §2). macOS가 `app_host_abi.zig`라는 이백 개 넘는 `pub export fn`
//! 의 C ABI 경계를 둔 것은 AppKit이 Objective-C/Swift 전용이기 때문인데, Win32에는 그 강제가 없다. 창·입력은
//! 평범한 C API라 Zig에서 직접 부른다. (개수를 숫자로 박지 않는다 — ABI가 늘 때마다 문서가 거짓이 된다.)
//!
//! ## 표시 대상은 **주입받는다** (W7.2가 채울 이음매)
//!
//! 이 창은 스왑체인을 만들지 않는다. `PresentTarget`이 그 자리이고 지금은 비어 있다 — W7.2(D3D11+DXGI)가
//! 채운다. 이렇게 갈라 두는 이유는 **웹뷰 합성 모델이 아직 미결**이기 때문이다(계약 §8):
//!
//! | | DirectComposition | HWND 오버레이 |
//! |---|---|---|
//! | 창 스타일 | `WS_EX_NOREDIRECTIONBITMAP` 필요 | 평범한 HWND |
//! | 스왑체인 | `CreateSwapChainForComposition` | `CreateSwapChainForHwnd` |
//!
//! **그 결정이 닿는 곳은 이 두 지점뿐이다.** 아틀라스·draw-list·입력·IME는 무관하다 — 중립 렌더러엔
//! `present`라는 개념 자체가 없다(`src/renderer/**`에 swapchain이 없다. 거기 나오는 `drawable`은 "이 글리프를
//! 그릴지"라는 무관한 뜻이고, 표시 대상을 가리키지 않는다). 그래서 창이 표시
//! 대상을 **만들지 않고 받는** 모양만 지키면 전환 비용이 두 줄에 머문다. 반대로 "우리가 클라이언트
//! 영역을 소유하고 HWND에 직접 present한다"를 여기 새기면 그때는 비싸진다 — macOS도 터미널이 화면을
//! 독점하지 않고 `CALayer` subview로 합성되는 구조다.

const std = @import("std");
const builtin = @import("builtin");
// **`maru`를 통해 받는다.** 이 파일은 `main.zig`(root 모듈)만 쓰는데, root가 `src/` 아래 파일을 상대
// import하면 그 파일이 `maru` 모듈과 이중 소유가 된다(실측: `file exists in modules 'maru' and 'root'`).
const terminal = @import("maru").terminal;

pub const Error = error{
    RegisterClassFailed,
    ModuleHandleFailed,
    CreateWindowFailed,
    OutOfMemory,
    UnsupportedPlatform,
};

/// 창 생성이 실패했을 때 마지막으로 본 Win32 오류 코드. 진단 전용이다 — 오류 타입에 코드를 실을 수 없어
/// (Zig 오류는 payload가 없다) 여기 남긴다. 다음 실패가 덮어쓴다.
pub var last_create_error: u32 = 0;

/// 창이 호출자에게 올리는 **중립 이벤트**. Win32 메시지가 아니라 앱이 이해하는 어휘로 바꿔 준다 —
/// 그래야 `app/host.zig`가 Win32를 몰라도 된다.
pub const WindowEvent = union(enum) {
    /// 클라이언트 영역이 바뀌었다. 픽셀 단위이며, 셀로 바꾸는 것은 호출자(셀 메트릭을 아는 쪽)다.
    resized: struct { width_px: u32, height_px: u32 },
    /// 사용자가 창을 닫으려 한다. **창은 아직 닫지 않는다** — 호출자가 정책(세션 종료 확인 등)을
    /// 처리한 뒤 `requestClose`를 부른다. macOS의 `windowShouldClose` 분담과 같다.
    close_requested,
    /// 그릴 때가 됐다. W7.2가 실제 present를 붙이기 전에는 호출자가 프레임만 조립한다.
    paint,
};

/// 표시 대상 — **W7.2가 채운다.** 지금은 창이 스왑체인을 만들지 않는다는 사실을 타입으로 못 박아 두는
/// 자리다(위 doc 참조). 비어 있어도 이름이 있는 편이, 나중에 "어디에 끼우지"를 찾아 헤매지 않게 한다.
pub const PresentTarget = struct {
    /// D3D11/DXGI가 붙을 자리. W7.2 전에는 아무도 채우지 않는다.
    opaque_handle: ?*anyopaque = null,
};

// ── Win32 선언 (필요한 것만) ──────────────────────────────────────────────────────────────────
const HWND = *anyopaque;
const HINSTANCE = *anyopaque;
const HICON = *anyopaque;
const HCURSOR = *anyopaque;
const HBRUSH = *anyopaque;
const HMENU = *anyopaque;
const LRESULT = isize;
const WPARAM = usize;
const LPARAM = isize;
const UINT = u32;
const DWORD = u32;
const ATOM = u16;

const WNDPROC = *const fn (HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;

comptime {
    // **Win32 구조체는 크기가 계약이다.** `RegisterClassExW`는 `cbSize`로 버전을 판별하고, `WM_NCCREATE`의
    // `lParam`은 우리 선언에 맞춰 읽는다. 필드를 하나 빠뜨리거나 순서를 바꿔도 **컴파일은 되고** 런타임에
    // 조용히 어긋난다 — 특히 `CREATESTRUCTW`는 첫 필드만 읽으므로 뒤쪽이 틀려도 안 드러난다.
    // 공개 헤더가 정한 x64 크기를 여기 못 박는다. comptime이라 **Windows 러너 없이** 모든 타깃에서 돈다.
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(WNDCLASSEXW) == 80);
        std.debug.assert(@sizeOf(CREATESTRUCTW) == 80);
        std.debug.assert(@sizeOf(MSG) == 48);
        std.debug.assert(@sizeOf(RECT) == 16);
        std.debug.assert(@sizeOf(POINT) == 8);
    }
}

const WNDCLASSEXW = extern struct {
    cbSize: UINT,
    style: UINT,
    lpfnWndProc: WNDPROC,
    cbClsExtra: i32,
    cbWndExtra: i32,
    hInstance: HINSTANCE,
    hIcon: ?HICON,
    hCursor: ?HCURSOR,
    hbrBackground: ?HBRUSH,
    lpszMenuName: ?[*:0]const u16,
    lpszClassName: [*:0]const u16,
    hIconSm: ?HICON,
};

const POINT = extern struct { x: i32, y: i32 };
const MSG = extern struct {
    hwnd: ?HWND,
    message: UINT,
    wParam: WPARAM,
    lParam: LPARAM,
    time: DWORD,
    pt: POINT,
};
const RECT = extern struct { left: i32, top: i32, right: i32, bottom: i32 };

/// `WM_NCCREATE`/`WM_CREATE`의 `lParam`이 가리키는 것. 우리가 읽는 것은 `lpCreateParams` 하나지만,
/// `extern struct`는 레이아웃이 맞아야 하므로 전부 적는다(x64 기준 필드 순서는 공개 헤더 정의다).
const CREATESTRUCTW = extern struct {
    lpCreateParams: ?*anyopaque,
    hInstance: HINSTANCE,
    hMenu: ?HMENU,
    hwndParent: ?HWND,
    cy: i32,
    cx: i32,
    y: i32,
    x: i32,
    style: DWORD,
    lpszName: ?[*:0]const u16,
    lpszClass: ?[*:0]const u16,
    dwExStyle: DWORD,
};

const WM_DESTROY: UINT = 0x0002;
const WM_NCCREATE: UINT = 0x0081;
const WM_SIZE: UINT = 0x0005;
const WM_CLOSE: UINT = 0x0010;
const WM_QUIT: UINT = 0x0012;
const WM_PAINT: UINT = 0x000F;

const WS_OVERLAPPEDWINDOW: DWORD = 0x00CF0000;
const CW_USEDEFAULT: i32 = @bitCast(@as(u32, 0x80000000));
const SW_SHOW: i32 = 5;
const PM_REMOVE: UINT = 0x0001;
const GWLP_USERDATA: i32 = -21;
const CS_HREDRAW: UINT = 0x0002;
const CS_VREDRAW: UINT = 0x0001;
const IDC_ARROW: usize = 32512;

extern "user32" fn RegisterClassExW(*const WNDCLASSEXW) callconv(.winapi) ATOM;
extern "user32" fn CreateWindowExW(DWORD, ?[*:0]const u16, ?[*:0]const u16, DWORD, i32, i32, i32, i32, ?HWND, ?HMENU, ?HINSTANCE, ?*anyopaque) callconv(.winapi) ?HWND;
extern "user32" fn DefWindowProcW(HWND, UINT, WPARAM, LPARAM) callconv(.winapi) LRESULT;
extern "user32" fn DestroyWindow(HWND) callconv(.winapi) i32;
extern "user32" fn PostQuitMessage(i32) callconv(.winapi) void;
extern "user32" fn PeekMessageW(*MSG, ?HWND, UINT, UINT, UINT) callconv(.winapi) i32;
extern "user32" fn TranslateMessage(*const MSG) callconv(.winapi) i32;
extern "user32" fn DispatchMessageW(*const MSG) callconv(.winapi) LRESULT;
extern "user32" fn ShowWindow(HWND, i32) callconv(.winapi) i32;
extern "user32" fn GetClientRect(HWND, *RECT) callconv(.winapi) i32;
extern "user32" fn LoadCursorW(?HINSTANCE, usize) callconv(.winapi) ?HCURSOR;
extern "user32" fn SetWindowLongPtrW(HWND, i32, isize) callconv(.winapi) isize;
extern "user32" fn GetWindowLongPtrW(HWND, i32) callconv(.winapi) isize;
extern "kernel32" fn GetModuleHandleW(?[*:0]const u16) callconv(.winapi) ?HINSTANCE;
/// **std의 것을 쓴다.** 직접 `extern`으로 선언하면 Zig가 사이에 끼우는 코드가 스레드 오류 값을 덮어
/// 0으로 읽힐 수 있다(실측: 세 호출 지점에서 전부 0이 나왔다). std는 그 규약을 알고 있다.
fn GetLastError() u32 {
    return @intFromEnum(std.os.windows.GetLastError());
}

// 스레드 오류 코드를 **그대로 노출하지 않는다.** 호출 시점의 값이라 중간에 다른 Win32 호출이 하나만 끼어도
// 창 생성과 무관한 값이 나온다 — 진단하려다 오진하게 만드는 API다. 실패 원인은 실패한 그 자리에서 잡아
// `last_create_error`에 남긴다.

/// 클라이언트 픽셀 크기를 셀 크기로 바꾸는 **순수** 변환. 창이 셀 메트릭을 소유하지 않으므로 인자로 받는다.
///
/// 0으로 나누지 않고(메트릭이 0이면 null), 최소 1×1을 보장한다 — `terminal.Size`가 0을 받으면 화면 저장이
/// 빈 grid가 되고 그 뒤 인덱싱이 전부 가드에 걸린다(`screen.zig`). 창을 아주 작게 끌면 실제로 0이 나온다.
///
/// 위쪽도 막는다. `terminal.Size`는 `u16`인데 몫은 `u32`라, 메트릭이 병적으로 작으면(1px 같은 값) `@intCast`가
/// 그대로 패닉한다 — 아래를 막고 위를 안 막을 이유가 없다.
pub fn cellsForClient(width_px: u32, height_px: u32, cell_w: u32, cell_h: u32) ?terminal.Size {
    if (cell_w == 0 or cell_h == 0) return null;
    return .{
        .cols = clampToCells(width_px / cell_w),
        .rows = clampToCells(height_px / cell_h),
    };
}

fn clampToCells(n: u32) u16 {
    return @intCast(std.math.clamp(n, 1, std.math.maxInt(u16)));
}

/// 창이 올린 이벤트를 모아 두는 큐. **순수하다** — Win32를 모른다. 창에서 떼어 둔 이유는 하나다:
/// "`poll` 바깥에서 도착한 이벤트를 잃지 않는다"는 규칙을 Windows 러너 없이 검증하기 위해서다.
///
/// Win32 메시지에는 두 종류가 있다. `PostMessage` 계열은 큐에 쌓여 `PeekMessageW`가 꺼내지만,
/// `SendMessage` 계열은 **큐를 거치지 않고** `WndProc`을 곧장 부른다. `ShowWindow`·`SetWindowPos`·
/// `DestroyWindow`가 그렇게 `WM_SIZE`를 보낸다 — 즉 우리가 `poll` 안에 있지 않을 때도 이벤트가 들어온다.
/// 그래서 `poll` 진입에서 통째로 비우면 그 이벤트가 사라진다. 실측으로 겪었다: `show()`가 만든 `WM_SIZE`가
/// 첫 `poll`에 지워져 스모크가 `resized_events=0`을 냈다.
///
/// 그래서 **버퍼를 둘 두고 맞바꾼다.** 넘긴 쪽(`outgoing`)에는 다음 `swap`까지 아무도 쓰지 않으므로,
/// 호출자가 슬라이스를 순회하는 도중 `WndProc`이 이벤트를 더 올려도(순회 중 `requestClose`를 부르면
/// `DestroyWindow`가 `WM_SIZE`를 동기 전송한다) 그 슬라이스가 재할당으로 무효화되지 않는다. 한 버퍼를
/// 빌려주면 그 use-after-free를 API가 초대하게 된다.
pub const EventQueue = struct {
    /// `WndProc`이 채우는 쪽. `poll` 안이든 밖이든 새 이벤트는 전부 여기로 간다.
    incoming: std.ArrayList(WindowEvent) = .empty,
    /// 지난 `swap`이 호출자에게 넘긴 쪽. 호출자가 들고 있는 동안 아무도 건드리지 않는다.
    outgoing: std.ArrayList(WindowEvent) = .empty,
    /// 적재가 실패해도 창은 살아 있어야 한다 — 그 사실을 잃지 않게 세어 둔다.
    dropped: usize = 0,

    pub fn deinit(self: *EventQueue, allocator: std.mem.Allocator) void {
        self.incoming.deinit(allocator);
        self.outgoing.deinit(allocator);
    }

    pub fn push(self: *EventQueue, allocator: std.mem.Allocator, ev: WindowEvent) void {
        self.incoming.append(allocator, ev) catch {
            self.dropped += 1;
        };
    }

    /// 쌓인 것을 호출자 몫으로 넘긴다(borrow — 다음 `swap`까지 유효하다).
    pub fn swap(self: *EventQueue) []const WindowEvent {
        std.mem.swap(std.ArrayList(WindowEvent), &self.incoming, &self.outgoing);
        self.incoming.clearRetainingCapacity();
        return self.outgoing.items;
    }
};

/// 창 하나. **이벤트를 모아 두고 호출자가 가져간다** — 콜백으로 앱 코드를 부르지 않는다. Win32 `WndProc`은
/// OS가 재진입시켜 부르는데(모달 resize 루프 등) 그 안에서 앱 정책을 돌리면 재진입이 앱까지 번진다.
pub const Window = struct {
    hwnd: HWND,
    present: PresentTarget = .{},
    /// `WndProc`이 채우고 `poll`이 넘긴다. 창 하나당 하나라 락이 필요 없다(같은 스레드에서만 돈다).
    ///
    /// **창이 여럿이면 폴링 규약이 하나 더 필요하다.** `poll`의 `PeekMessageW(hwnd=null)`은 이 **스레드의**
    /// 메시지를 전부 꺼내 각자의 `WndProc`으로 보낸다 — 즉 창 A의 `poll`이 창 B의 큐를 채운다. 동작은
    /// 맞지만 B를 아무도 `poll`하지 않으면 B의 이벤트가 무한히 쌓인다. 창이 여러 개가 되는 시점(W8)에
    /// 펌프를 창 밖으로 빼거나 모든 창을 매 프레임 `poll`하는 규약을 정한다. 지금은 창이 하나다.
    events: EventQueue = .{},
    allocator: std.mem.Allocator,
    quit_requested: bool = false,

    const class_name = std.unicode.utf8ToUtf16LeStringLiteral("MaruWindowClass");

    /// `window_width`·`window_height`는 **창 외곽**(프레임 포함) 픽셀이다 — `CreateWindowExW`의 규약이
    /// 그렇다. 클라이언트는 그보다 작다(실측: 960×600 → 944×561). 셀 격자로 크기를 정하려면
    /// (`cols * cell_w` 를 클라이언트로 만들려면) `AdjustWindowRectEx`로 프레임을 더해 넘겨야 하는데,
    /// 그 계산은 셀 메트릭을 아는 쪽 몫이라 여기 두지 않는다 — W7.3(DirectWrite)이 그 값을 갖는다.
    /// 지금은 그 호출자가 없으므로 정책을 발명하지 않고 규약만 이름과 문서로 못 박는다.
    pub fn create(allocator: std.mem.Allocator, title_utf16: [*:0]const u16, window_width: i32, window_height: i32) Error!*Window {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        const hinstance = GetModuleHandleW(null) orelse {
            last_create_error = GetLastError();
            return error.ModuleHandleFailed;
        };

        const wc = WNDCLASSEXW{
            .cbSize = @sizeOf(WNDCLASSEXW),
            // 폭·높이가 바뀌면 전체를 다시 그린다 — 셀 격자라 부분 무효화가 오히려 복잡하다.
            .style = CS_HREDRAW | CS_VREDRAW,
            .lpfnWndProc = wndProc,
            .cbClsExtra = 0,
            .cbWndExtra = 0,
            .hInstance = hinstance,
            .hIcon = null,
            .hCursor = LoadCursorW(null, IDC_ARROW),
            // **배경 브러시를 주지 않는다.** 주면 OS가 먼저 칠하고 우리가 덮어 깜빡인다(W7.2가 매 프레임
            // 전체를 그린다). 대신 첫 프레임 전까지는 칠해지지 않은 채로 둔다.
            .hbrBackground = null,
            .lpszMenuName = null,
            .lpszClassName = class_name,
            .hIconSm = null,
        };
        // 같은 클래스를 두 번 등록하면 실패하지만(ERROR_CLASS_ALREADY_EXISTS) 그건 정상 재진입이다 —
        // 창을 여러 개 만들 때 첫 번째만 성공한다. 그래서 실패를 곧바로 오류로 보지 않고 창 생성으로 판정한다.
        if (RegisterClassExW(&wc) == 0) {
            // 이미 등록됐으면(ERROR_CLASS_ALREADY_EXISTS = 1410) 정상 재진입이다 — 창을 여러 개 만들 때
            // 두 번째부터가 그렇다. 그 밖이면 진짜 실패이므로 코드를 남기고 멈춘다.
            const err = GetLastError();
            if (err != 1410) {
                last_create_error = err;
                return error.RegisterClassFailed;
            }
        }

        const self = allocator.create(Window) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{ .hwnd = undefined, .allocator = allocator };

        const hwnd = CreateWindowExW(
            0,
            class_name,
            title_utf16,
            WS_OVERLAPPEDWINDOW,
            CW_USEDEFAULT,
            CW_USEDEFAULT,
            window_width,
            window_height,
            null,
            null,
            hinstance,
            // **여기서 넘긴다.** `CreateWindowExW`는 반환하기 **전에** `WM_NCCREATE`·`WM_CREATE`(그리고
            // 경우에 따라 `WM_SIZE`)를 동기로 보낸다. 반환 뒤에 `GWLP_USERDATA`를 붙이면 그 구간의
            // `WndProc`이 창을 못 찾아 이벤트가 `dropped`에도 안 잡히고 사라진다 — 계약이 생성 구간에서만
            // 조용히 깨진다. `lpParam`으로 넘겨 `WM_NCCREATE`에서 붙이는 것이 Win32 표준 관용구다.
            self,
        ) orelse {
            last_create_error = GetLastError();
            return error.CreateWindowFailed;
        };
        // `WM_NCCREATE`가 이미 붙였다. 그래도 여기서 한 번 더 쓰는 것은 방어가 아니라 **불변식 고정**이다 —
        // `WM_NCCREATE`를 못 받는 경로가 생기더라도 반환 시점엔 반드시 붙어 있다.
        _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(self)));
        self.hwnd = hwnd;
        return self;
    }

    pub fn destroy(self: *Window) void {
        _ = DestroyWindow(self.hwnd);
        self.events.deinit(self.allocator);
        self.allocator.destroy(self);
    }

    pub fn show(self: *Window) void {
        _ = ShowWindow(self.hwnd, SW_SHOW);
    }

    /// 실제로 창을 닫는다. `close_requested`를 받은 호출자가 정책을 마친 뒤 부른다.
    pub fn requestClose(self: *Window) void {
        _ = DestroyWindow(self.hwnd);
    }

    /// 현재 클라이언트 영역(픽셀). **`null`은 "물어보지 못했다"만 뜻한다** — 최소화된 창의 0×0은 0×0으로
    /// 돌려준다. 둘을 `null` 하나로 뭉치면 호출자가 "최소화됐다"와 "질의가 실패했다"를 구분할 수 없는데,
    /// W7.2는 그 둘에 다르게 굴어야 한다(전자는 present를 거르고, 후자는 이전 크기를 유지한다).
    pub fn clientSize(self: *const Window) ?struct { width_px: u32, height_px: u32 } {
        var r: RECT = undefined;
        if (GetClientRect(self.hwnd, &r) == 0) return null;
        return .{
            .width_px = @intCast(@max(0, r.right - r.left)),
            .height_px = @intCast(@max(0, r.bottom - r.top)),
        };
    }

    /// 밀린 메시지를 전부 처리하고 그동안 쌓인 중립 이벤트를 돌려준다(호출자 소유가 아니라 borrow —
    /// 다음 `poll`이 비운다). **막지 않는다** — 프레임 루프가 자기 페이스로 돈다.
    pub fn poll(self: *Window) []const WindowEvent {
        // **펌프가 먼저, 넘기는 것은 나중.** 이 `poll` 전에 `show()`·`SetWindowPos`가 동기 전송한 메시지의
        // 이벤트가 이미 큐에 들어와 있고, 펌프가 올린 것과 함께 한 번에 나가야 한다(`EventQueue` doc 참조).
        var msg: MSG = undefined;
        while (PeekMessageW(&msg, null, 0, 0, PM_REMOVE) != 0) {
            if (msg.message == WM_QUIT) {
                self.quit_requested = true;
                break;
            }
            _ = TranslateMessage(&msg);
            _ = DispatchMessageW(&msg);
        }
        return self.events.swap();
    }

    fn push(self: *Window, ev: WindowEvent) void {
        self.events.push(self.allocator, ev);
    }
};

fn windowFrom(hwnd: HWND) ?*Window {
    const raw = GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (raw == 0) return null;
    return @ptrFromInt(@as(usize, @bitCast(raw)));
}

fn wndProc(hwnd: HWND, msg: UINT, wparam: WPARAM, lparam: LPARAM) callconv(.winapi) LRESULT {
    // **가장 먼저 창을 붙인다.** 이 뒤에 오는 생성 구간 메시지(`WM_CREATE`·`WM_SIZE`)가 창을 찾을 수
    // 있어야 한다. `DefWindowProcW`에 넘기는 것을 잊으면 창 생성이 통째로 실패한다.
    if (msg == WM_NCCREATE) {
        const cs: *const CREATESTRUCTW = @ptrFromInt(@as(usize, @bitCast(lparam)));
        if (cs.lpCreateParams) |p| _ = SetWindowLongPtrW(hwnd, GWLP_USERDATA, @bitCast(@intFromPtr(p)));
        return DefWindowProcW(hwnd, msg, wparam, lparam);
    }
    const self = windowFrom(hwnd);
    switch (msg) {
        WM_SIZE => {
            if (self) |w| {
                // lParam 하위/상위 16비트가 클라이언트 폭·높이다. 최소화하면 0이 오므로 그대로 싣고
                // 셀 변환에서 거른다(`cellsForClient`가 최소 1×1을 보장한다).
                const raw: u32 = @bitCast(@as(i32, @truncate(lparam)));
                w.push(.{ .resized = .{ .width_px = raw & 0xFFFF, .height_px = (raw >> 16) & 0xFFFF } });
            }
            return 0;
        },
        WM_PAINT => {
            // **여기서 그리지 않는다.** `BeginPaint`/`EndPaint`도 하지 않는다 — W7.2가 스왑체인으로 present
            // 하면 GDI 페인트 사이클과 섞이면 안 된다. 무효 영역만 지우는 것은 `DefWindowProcW`에 맡긴다.
            if (self) |w| w.push(.paint);
            return DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        WM_CLOSE => {
            // **창을 닫지 않는다.** 호출자가 정책을 처리하고 `requestClose`를 부른다.
            if (self) |w| w.push(.close_requested);
            return 0;
        },
        WM_DESTROY => {
            PostQuitMessage(0);
            return 0;
        },
        else => return DefWindowProcW(hwnd, msg, wparam, lparam),
    }
}

const testing = std.testing;

// 순수 변환은 **모든 타깃에서** 돈다 — Windows 러너가 없어도 이 규칙이 지켜진다.
test "cellsForClient: 0 메트릭은 null, 아주 작은 창도 최소 1x1" {
    try testing.expect(cellsForClient(800, 600, 0, 16) == null);
    try testing.expect(cellsForClient(800, 600, 8, 0) == null);

    const normal = cellsForClient(800, 600, 8, 16).?;
    try testing.expectEqual(@as(u16, 100), normal.cols);
    try testing.expectEqual(@as(u16, 37), normal.rows);

    // 창을 셀 하나보다 작게 끌면 0이 나온다 — 그대로 넘기면 빈 grid가 된다.
    const tiny = cellsForClient(3, 3, 8, 16).?;
    try testing.expectEqual(@as(u16, 1), tiny.cols);
    try testing.expectEqual(@as(u16, 1), tiny.rows);

    // 최소화(0×0)도 같은 규칙으로 접힌다.
    const minimized = cellsForClient(0, 0, 8, 16).?;
    try testing.expectEqual(@as(u16, 1), minimized.cols);
    try testing.expectEqual(@as(u16, 1), minimized.rows);

    // 병적으로 작은 메트릭이면 몫이 u16을 넘는다 — 잘라 담지 않으면 `@intCast`가 패닉한다.
    const huge = cellsForClient(200_000, 200_000, 1, 1).?;
    try testing.expectEqual(@as(u16, 65535), huge.cols);
    try testing.expectEqual(@as(u16, 65535), huge.rows);
}

test "EventQueue: poll 바깥에서 도착한 이벤트를 잃지 않는다" {
    const a = testing.allocator;
    var q = EventQueue{};
    defer q.deinit(a);

    // `show()` 안에서 `WM_SIZE`가 동기 전송돼 들어온 상황 — 아직 아무도 `poll`을 부르지 않았다.
    q.push(a, .{ .resized = .{ .width_px = 944, .height_px = 561 } });
    // 이어서 `poll`의 펌프가 `WM_PAINT`를 올린다. 둘은 **한 번에** 나가야 한다.
    q.push(a, .paint);
    const first = q.swap();
    try testing.expectEqual(@as(usize, 2), first.len);
    try testing.expect(first[0] == .resized);
    try testing.expectEqual(@as(u32, 944), first[0].resized.width_px);
    try testing.expect(first[1] == .paint);

    // 두 `poll` 사이에 또 하나가 동기 전송으로 들어온다. `poll` 진입에서 통째로 비우던 옛 방식이면
    // 이게 사라진다 — 이 단언이 그 회귀를 잡는다.
    q.push(a, .close_requested);
    const second = q.swap();
    try testing.expectEqual(@as(usize, 1), second.len);
    try testing.expect(second[0] == .close_requested);

    // 아무것도 안 오면 빈다 — 맞바꾸기가 이벤트를 무한히 쌓아 두지 않는다.
    try testing.expectEqual(@as(usize, 0), q.swap().len);
}

test "EventQueue: 호출자가 순회하는 슬라이스는 새 이벤트에 무효화되지 않는다" {
    const a = testing.allocator;
    var q = EventQueue{};
    defer q.deinit(a);

    q.push(a, .{ .resized = .{ .width_px = 944, .height_px = 561 } });
    const borrowed = q.swap();

    // 호출자가 `borrowed`를 순회하는 도중 `requestClose`를 부르면 `DestroyWindow`가 `WM_SIZE`를 동기
    // 전송한다 — 그 push가 재할당을 일으켜도 `borrowed`는 살아 있어야 한다. 한 버퍼를 빌려주던 방식이면
    // 여기서 use-after-free가 난다. 재할당을 확실히 일으키도록 넉넉히 밀어 넣는다.
    for (0..256) |_| q.push(a, .paint);

    // **값이 아니라 구조를 단언한다.** 해제된 메모리를 읽어 값이 살아 있는지 보는 식이면 할당자가
    // 재사용하지 않는 한 옛 설계에서도 통과해 공허참이 된다. 생산자 버퍼가 빌려준 버퍼와 **다른 것**이라는
    // 사실 자체를 본다 — 한 버퍼를 빌려주던 방식이면 두 포인터가 같아 여기서 걸린다.
    try testing.expect(q.incoming.items.ptr != borrowed.ptr);
    try testing.expectEqual(@as(usize, 1), borrowed.len);
    try testing.expect(borrowed[0] == .resized);
    try testing.expectEqual(@as(u32, 561), borrowed[0].resized.height_px);

    // 다음 `swap`은 그 사이 쌓인 것만 넘긴다.
    try testing.expectEqual(@as(usize, 256), q.swap().len);
}

test "EventQueue: 적재에 실패해도 창은 살고 그 수가 남는다" {
    var q = EventQueue{};
    q.push(testing.failing_allocator, .paint);
    try testing.expectEqual(@as(usize, 1), q.dropped);
    try testing.expectEqual(@as(usize, 0), q.incoming.items.len);
}
