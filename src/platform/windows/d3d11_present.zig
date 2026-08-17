//! D3D11 + DXGI 표시 경로 — W7.2a.
//!
//! **이 파일은 "화면에 내보내는 것"만 안다.** 무엇을 그릴지는 여기 없다 — 디바이스를 만들고, 스왑체인을
//! 잡고, 백버퍼를 지우고, present한다. 셀·아틀라스·셰이더는 `d3d11_cells.zig`가 이 위에 얹는다. 그렇게
//! 가른 이유는 W7.1이 창을 가른 이유와 같다: 실패가 어디서 났는지 한 층씩 확인할 수 있어야 한다.
//!
//! COM 타입·상수는 `d3d11.zig`(바인딩 층)가 소유한다 — 셀 파이프라인도 같은 것을 쓰므로, 여기 두면 그쪽이
//! 표시 경로를 통째로 import해야 하고 그러면 경계가 이름만 남는다.
//!
//! ## 스왑체인은 **HWND**에 붙인다 (W7.2 결정)
//!
//! 계약 §8의 웹뷰 합성 모델(DirectComposition vs HWND 오버레이)은 **아직 미결**이고, 여기서 정하지 않는다.
//! W7.1이 그 결정을 `PresentTarget` 뒤 두 지점(창 스타일·스왑체인 생성)에 가둬 뒀으므로 나중에 갈아타는
//! 비용이 설계대로 싸다. 웹뷰는 W8이고 지금 필요한 것은 터미널이라, 더 단순한 `CreateSwapChainForHwnd`로
//! 간다.
//!
//! **W8이 다시 발견하지 않도록 적어 둔다**: HWND 오버레이로 웹뷰를 붙이면 WebView2가 자식 HWND가 되고,
//! 자식 HWND 영역 위에는 우리 스왑체인이 그릴 수 없다(airspace). 그러면 macOS의 `터미널 < 웹뷰 < 오버레이`
//! z-order가 뒤집혀 모달이 웹뷰 뒤로 숨는다. 그 순서를 지키려면 DirectComposition + WebView2 visual
//! hosting이어야 한다. 즉 **W8의 선택지는 사실상 하나**이고, 그때 이 파일의 스왑체인 생성 한 줄과 창의
//! `dwExStyle` 한 줄이 바뀐다.

const std = @import("std");
const builtin = @import("builtin");
const d3d11 = @import("d3d11.zig");

pub const Error = error{
    UnsupportedPlatform,
    CreateDeviceFailed,
    CreateFactoryFailed,
    CreateSwapChainFailed,
    BackBufferFailed,
    ResizeFailed,
    PresentFailed,
    OutOfMemory,
};

/// 마지막으로 본 `HRESULT`. 진단 전용이다 — Zig 오류엔 payload를 실을 수 없어 여기 남긴다(W7.1의
/// `last_create_error`와 같은 이유·같은 한계: 다음 실패가 덮어쓴다).
pub var last_hresult: i32 = 0;

/// 어느 드라이버로 섰는지. "GPU로 그렸다"와 "소프트웨어로 그렸다"는 성능 판정이 다르므로 숨기지 않는다.
pub const Driver = enum { hardware, warp };

/// 창 하나에 붙은 D3D11 표시 경로. **소유 관계가 곧 정리 순서다** — 백버퍼 뷰가 스왑체인보다 먼저 죽어야
/// `ResizeBuffers`가 성공한다(살아 있는 참조가 있으면 실패한다). 그래서 `rtv`를 따로 놓았다 놓아 준다.
///
/// **한 스레드에서만 쓴다.** `ID3D11DeviceContext`(immediate context)는 스레드 안전하지 않다 — D3D11의
/// 계약이 그렇다. 창의 메시지 펌프가 도는 스레드에서 `resize`·`clearAndPresent`를 부르므로 지금은 자연히
/// 지켜지지만, 렌더를 별도 스레드로 뺄 생각이 생기면 여기가 먼저 걸린다(디바이스는 스레드 안전하고
/// 컨텍스트만 아니다 — 그때는 deferred context나 컨텍스트 소유 스레드 고정 중 하나를 정해야 한다).
pub const Present = struct {
    device: *d3d11.ID3D11Device,
    context: *d3d11.ID3D11DeviceContext,
    swapchain: *d3d11.IDXGISwapChain1,
    /// 현재 백버퍼의 렌더 타깃 뷰. 리사이즈마다 버리고 다시 만든다.
    rtv: ?*d3d11.ID3D11RenderTargetView = null,
    width_px: u32,
    height_px: u32,
    driver: Driver,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, hwnd: *anyopaque, width_px: u32, height_px: u32) Error!*Present {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

        var device: ?*d3d11.ID3D11Device = null;
        var context: ?*d3d11.ID3D11DeviceContext = null;
        const levels = [_]d3d11.UINT{d3d11.feature_level_11_0};
        // **하드웨어 먼저, 안 되면 WARP.** 계획 문서가 GPU 없는 러너에서도 렌더 스모크를 돌릴 근거로
        // WARP를 들었으므로, 코드가 그 갈래를 실제로 갖는다.
        var driver: Driver = .hardware;
        const driver_types = [_]d3d11.UINT{ d3d11.driver_type_hardware, d3d11.driver_type_warp };
        for (driver_types, 0..) |driver_type, i| {
            const hr = d3d11.D3D11CreateDevice(
                null,
                driver_type,
                null,
                0,
                &levels,
                levels.len,
                d3d11.d3d11_sdk_version,
                &device,
                null,
                &context,
            );
            if (!d3d11.failed(hr)) {
                driver = if (driver_type == d3d11.driver_type_warp) .warp else .hardware;
                break;
            }
            last_hresult = hr;
            // **후보 개수에서 유도한다.** `i == 1`처럼 박아 두면 후보를 하나 늘리는 순간 조용히 틀린다.
            if (i == driver_types.len - 1) return error.CreateDeviceFailed;
        }
        errdefer d3d11.releaseOpt(device);
        errdefer d3d11.releaseOpt(context);

        var factory_raw: ?*anyopaque = null;
        {
            const hr = d3d11.CreateDXGIFactory1(&d3d11.IID_IDXGIFactory2, &factory_raw);
            if (d3d11.failed(hr)) {
                last_hresult = hr;
                return error.CreateFactoryFailed;
            }
        }
        const factory: *d3d11.IDXGIFactory2 = @ptrCast(@alignCast(factory_raw.?));
        // 팩토리는 스왑체인을 만들고 나면 필요 없다 — 스왑체인이 자기 부모를 참조한다.
        defer d3d11.releaseOpt(factory_raw);

        // 0×0 스왑체인은 만들 수 없다. 최소화된 창에서 생성될 수 있으므로 1로 올린다(창이 커지면
        // `resize`가 실제 크기로 맞춘다).
        const w = @max(@as(u32, 1), width_px);
        const h = @max(@as(u32, 1), height_px);
        const desc = d3d11.SwapChainDesc1{
            .width = w,
            .height = h,
            .format = d3d11.format_b8g8r8a8_unorm,
            .stereo = 0,
            .sample_desc = .{ .count = 1, .quality = 0 },
            .buffer_usage = d3d11.usage_render_target_output,
            // 플립 모델은 최소 2다. 3으로 올리면 지연이 늘고, 2가 프레임 페이싱의 기본이다.
            .buffer_count = 2,
            .scaling = d3d11.scaling_stretch,
            .swap_effect = d3d11.swap_effect_flip_discard,
            .alpha_mode = d3d11.alpha_mode_unspecified,
            .flags = 0,
        };

        var swapchain: ?*d3d11.IDXGISwapChain1 = null;
        {
            const hr = factory.vtable.CreateSwapChainForHwnd(
                factory,
                @ptrCast(device.?),
                hwnd,
                &desc,
                null,
                null,
                &swapchain,
            );
            if (d3d11.failed(hr)) {
                last_hresult = hr;
                return error.CreateSwapChainFailed;
            }
        }
        errdefer d3d11.releaseOpt(swapchain);

        // **Alt+Enter를 DXGI에서 빼앗아 온다.** 스왑체인을 만든 **뒤에** 불러야 그 창의 연결이 잡힌다.
        // 실패해도 창은 산다(전체화면 토글이 남을 뿐) — 그래서 오류로 올리지 않고 코드만 남긴다.
        {
            const hr = factory.vtable.MakeWindowAssociation(factory, hwnd, d3d11.dxgi_mwa_no_alt_enter);
            if (d3d11.failed(hr)) last_hresult = hr;
        }

        const self = allocator.create(Present) catch return error.OutOfMemory;
        errdefer allocator.destroy(self);
        self.* = .{
            .device = device.?,
            .context = context.?,
            .swapchain = swapchain.?,
            .width_px = w,
            .height_px = h,
            .driver = driver,
            .allocator = allocator,
        };
        try self.acquireBackBuffer();
        return self;
    }

    pub fn destroy(self: *Present) void {
        d3d11.releaseOpt(self.rtv);
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.swapchain)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.context)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.device)));
        self.allocator.destroy(self);
    }

    /// 백버퍼를 꺼내 렌더 타깃 뷰를 만든다. 생성 직후와 리사이즈 직후에 부른다.
    fn acquireBackBuffer(self: *Present) Error!void {
        var back: ?*anyopaque = null;
        const hr = self.swapchain.vtable.GetBuffer(self.swapchain, 0, &d3d11.IID_ID3D11Texture2D, &back);
        if (d3d11.failed(hr)) {
            last_hresult = hr;
            return error.BackBufferFailed;
        }
        // **텍스처는 뷰를 만든 즉시 놓아 준다.** 뷰가 자원을 참조하므로 우리가 계속 들고 있을 이유가 없고,
        // 들고 있으면 다음 `ResizeBuffers`가 "참조가 남았다"로 실패한다.
        defer d3d11.releaseOpt(back);

        var rtv: ?*d3d11.ID3D11RenderTargetView = null;
        const hr2 = self.device.vtable.CreateRenderTargetView(self.device, back.?, null, &rtv);
        if (d3d11.failed(hr2)) {
            last_hresult = hr2;
            return error.BackBufferFailed;
        }
        self.rtv = rtv;
    }

    /// 창 크기가 바뀌었을 때. **뷰를 먼저 놓고** 버퍼를 다시 잡는다 — 살아 있는 참조가 있으면
    /// `ResizeBuffers`가 실패한다(DXGI의 규약이다).
    pub fn resize(self: *Present, width_px: u32, height_px: u32) Error!void {
        const w = @max(@as(u32, 1), width_px);
        const h = @max(@as(u32, 1), height_px);
        if (w == self.width_px and h == self.height_px and self.rtv != null) return;

        d3d11.releaseOpt(self.rtv);
        self.rtv = null;

        const hr = self.swapchain.vtable.ResizeBuffers(self.swapchain, 0, w, h, 0, 0);
        if (d3d11.failed(hr)) {
            last_hresult = hr;
            return error.ResizeFailed;
        }
        self.width_px = w;
        self.height_px = h;
        try self.acquireBackBuffer();
    }

    /// 백버퍼를 렌더 타깃으로 걸고 한 색으로 지운다. **present는 하지 않는다** — 그 사이에 셀을 그리는
    /// 호출자(`d3d11_cells.zig`)가 있기 때문이다. 그리지 않는 호출자는 곧바로 `present`를 부르면 된다.
    ///
    /// `rgba`는 스왑체인 형식이 `_UNORM`이라 셰이더 없이 그 바이트가 곧 화면 색이다.
    pub fn beginFrame(self: *Present, rgba: [4]f32) Error!void {
        const rtv = self.rtv orelse return error.BackBufferFailed;

        var targets = [_]?*d3d11.ID3D11RenderTargetView{rtv};
        self.context.vtable.OMSetRenderTargets(self.context, 1, &targets, null);

        const viewports = [_]d3d11.Viewport{.{
            .top_left_x = 0,
            .top_left_y = 0,
            .width = @floatFromInt(self.width_px),
            .height = @floatFromInt(self.height_px),
            .min_depth = 0,
            .max_depth = 1,
        }};
        self.context.vtable.RSSetViewports(self.context, 1, &viewports);

        self.context.vtable.ClearRenderTargetView(self.context, rtv, &rgba);
    }

    pub fn present(self: *Present, vsync: bool) Error!void {
        const hr = self.swapchain.vtable.Present(self.swapchain, if (vsync) 1 else 0, 0);
        if (d3d11.failed(hr)) {
            last_hresult = hr;
            return error.PresentFailed;
        }
    }

    /// 지우고 곧바로 내보낸다. 그릴 것이 없는 호출자(W7.2a 스모크)를 위한 편의다.
    pub fn clearAndPresent(self: *Present, rgba: [4]f32, vsync: bool) Error!void {
        try self.beginFrame(rgba);
        try self.present(vsync);
    }
};

/// `0xAARRGGBB`를 D3D11이 받는 0~1 부동소수 넷으로 바꾸는 **순수** 변환. 테마 배경색이 그 표현이라
/// (`metal_frame.zig`의 `terminal_bg`와 같은 표현) 여기서 한 번만 푼다.
///
/// **알파를 실어 보내지만 지금은 화면에 안 먹는다.** HWND 스왑체인의 `AlphaMode`가 `UNSPECIFIED`라
/// 합성기가 알파를 무시하고 창은 불투명하다. macOS의 `window_opacity_milli`에 해당하는 창 투명도는
/// Windows에서 스왑체인이 아니라 **합성 모델**이 정한다(DirectComposition 또는 레이어드 윈도) — 계약 §8의
/// 웹뷰 합성 결정과 같은 자리에서 함께 열린다. 그래도 알파를 0으로 접지 않는 이유는, 그때 이 함수를
/// 고치지 않아도 되게 하기 위해서다.
///
/// 순수라서 **모든 타깃에서** 테스트가 돈다 — Windows 러너 없이 이 규칙이 지켜진다.
pub fn clearColorFromArgb(argb: u32) [4]f32 {
    const a: f32 = @floatFromInt((argb >> 24) & 0xFF);
    const r: f32 = @floatFromInt((argb >> 16) & 0xFF);
    const g: f32 = @floatFromInt((argb >> 8) & 0xFF);
    const b: f32 = @floatFromInt(argb & 0xFF);
    return .{ r / 255.0, g / 255.0, b / 255.0, a / 255.0 };
}

const testing = std.testing;

test "clearColorFromArgb: ARGB 바이트가 RGBA 순서로 풀린다" {
    // 불투명 검정·흰색.
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 1 }, &clearColorFromArgb(0xFF000000));
    try testing.expectEqualSlices(f32, &.{ 1, 1, 1, 1 }, &clearColorFromArgb(0xFFFFFFFF));

    // 채널이 **섞이지 않는지**가 요점이다 — R/G/B가 서로 다른 값이라야 순서 오류가 드러난다.
    const c = clearColorFromArgb(0x80336699);
    try testing.expectApproxEqAbs(@as(f32, 0x33) / 255.0, c[0], 1e-6); // R
    try testing.expectApproxEqAbs(@as(f32, 0x66) / 255.0, c[1], 1e-6); // G
    try testing.expectApproxEqAbs(@as(f32, 0x99) / 255.0, c[2], 1e-6); // B
    try testing.expectApproxEqAbs(@as(f32, 0x80) / 255.0, c[3], 1e-6); // A

    // alpha 0은 0이어야 한다 — 1로 접으면 투명 배경 정책(창 불투명도)이 조용히 깨진다.
    try testing.expectEqual(@as(f32, 0), clearColorFromArgb(0x00FFFFFF)[3]);
}
