//! D3D11 + DXGI 표시 경로 — W7.2a.
//!
//! **이 파일은 "화면에 내보내는 것"만 안다.** 무엇을 그릴지는 여기 없다 — 디바이스를 만들고, 스왑체인을
//! 잡고, 백버퍼를 지우고, present한다. 셀·아틀라스·셰이더는 W7.2b가 이 위에 얹는다. 그렇게 가른 이유는
//! W7.1이 창을 가른 이유와 같다: 실패가 어디서 났는지 한 층씩 확인할 수 있어야 한다.
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
//!
//! ## COM을 Zig로 어떻게 쓰는가 (이 저장소의 첫 COM 소비자)
//!
//! Zig엔 COM 지원이 없다. COM 객체는 **첫 워드가 vtable 포인터인 구조체**이고, vtable은 함수 포인터가
//! **정해진 순서로** 늘어선 것이다. 그 순서가 곧 ABI다 — 슬롯 하나를 빠뜨리면 **컴파일은 되고** 런타임에
//! 엉뚱한 함수를 부른다(그러면 증상이 "왜인지 모르게 죽는다"로만 나타난다).
//!
//! 그래서 두 규칙을 둔다.
//!
//! ⑴ **우리가 부르지 않는 슬롯도 자리를 채운다.** 타입은 `*const anyopaque`로 둬서 실수로 못 부르게 한다.
//! ⑵ **슬롯 번호를 `@offsetOf`로 comptime에 못 박는다.** 위에 슬롯을 하나 끼워 넣으면 그 자리에서 컴파일이
//!    멈춘다. comptime이라 Windows 러너 없이 모든 타깃에서 돈다(W7.1의 구조체 크기 단언과 같은 장치다).

const std = @import("std");
const builtin = @import("builtin");

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

// ── COM 최소 표면 ────────────────────────────────────────────────────────────────────────────

const HRESULT = i32;
const UINT = u32;
const BOOL = i32;

fn failed(hr: HRESULT) bool {
    return hr < 0;
}

const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

/// `IID_IDXGIFactory2` — `{50c83a1c-e072-4c48-87b0-3630fa36a6d0}`.
/// 틀리면 `CreateDXGIFactory1`이 `E_NOINTERFACE`를 돌려주므로 **런타임에 즉시 드러난다**(추측이 아니라
/// 실행으로 확인된다).
const IID_IDXGIFactory2 = GUID{
    .data1 = 0x50c83a1c,
    .data2 = 0xe072,
    .data3 = 0x4c48,
    .data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 },
};

/// `IID_ID3D11Texture2D` — `{6f15aaf2-d208-4e89-9ab4-489535d34f9c}`. 백버퍼를 꺼낼 때 쓴다.
const IID_ID3D11Texture2D = GUID{
    .data1 = 0x6f15aaf2,
    .data2 = 0xd208,
    .data3 = 0x4e89,
    .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

/// 모든 COM 인터페이스의 앞 세 슬롯. 우리가 실제로 부르는 것은 `Release` 하나다.
const IUnknown = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };

    fn release(self: *IUnknown) void {
        _ = self.vtable.Release(self);
    }
};

/// 어떤 COM 포인터든 놓아 준다. `null`이면 아무것도 하지 않는다 — 정리 경로가 부분 실패에도 안전해야 한다.
fn releaseOpt(ptr: anytype) void {
    if (ptr) |p| @as(*IUnknown, @ptrCast(@alignCast(p))).release();
}

const ID3D11Device = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const fn (*ID3D11Device, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        // ID3D11Device
        CreateBuffer: *const anyopaque,
        CreateTexture1D: *const anyopaque,
        CreateTexture2D: *const anyopaque,
        CreateTexture3D: *const anyopaque,
        CreateShaderResourceView: *const anyopaque,
        CreateUnorderedAccessView: *const anyopaque,
        CreateRenderTargetView: *const fn (*ID3D11Device, *anyopaque, ?*const anyopaque, *?*ID3D11RenderTargetView) callconv(.winapi) HRESULT,
    };
};

const ID3D11RenderTargetView = opaque {};

const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        // ID3D11DeviceChild
        GetDevice: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        // ID3D11DeviceContext — 부르지 않는 슬롯도 **자리를 채운다**(위 규칙 ⑴).
        VSSetConstantBuffers: *const anyopaque,
        PSSetShaderResources: *const anyopaque,
        PSSetShader: *const anyopaque,
        PSSetSamplers: *const anyopaque,
        VSSetShader: *const anyopaque,
        DrawIndexed: *const anyopaque,
        Draw: *const anyopaque,
        Map: *const anyopaque,
        Unmap: *const anyopaque,
        PSSetConstantBuffers: *const anyopaque,
        IASetInputLayout: *const anyopaque,
        IASetVertexBuffers: *const anyopaque,
        IASetIndexBuffer: *const anyopaque,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const anyopaque,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const anyopaque,
        VSSetShaderResources: *const anyopaque,
        VSSetSamplers: *const anyopaque,
        Begin: *const anyopaque,
        End: *const anyopaque,
        GetData: *const anyopaque,
        SetPredication: *const anyopaque,
        GSSetShaderResources: *const anyopaque,
        GSSetSamplers: *const anyopaque,
        OMSetRenderTargets: *const fn (*ID3D11DeviceContext, UINT, ?[*]const ?*ID3D11RenderTargetView, ?*anyopaque) callconv(.winapi) void,
        OMSetRenderTargetsAndUnorderedAccessViews: *const anyopaque,
        OMSetBlendState: *const anyopaque,
        OMSetDepthStencilState: *const anyopaque,
        SOSetTargets: *const anyopaque,
        DrawAuto: *const anyopaque,
        DrawIndexedInstancedIndirect: *const anyopaque,
        DrawInstancedIndirect: *const anyopaque,
        Dispatch: *const anyopaque,
        DispatchIndirect: *const anyopaque,
        RSSetState: *const anyopaque,
        RSSetViewports: *const fn (*ID3D11DeviceContext, UINT, [*]const Viewport) callconv(.winapi) void,
        RSSetScissorRects: *const anyopaque,
        CopySubresourceRegion: *const anyopaque,
        CopyResource: *const anyopaque,
        UpdateSubresource: *const anyopaque,
        CopyStructureCount: *const anyopaque,
        ClearRenderTargetView: *const fn (*ID3D11DeviceContext, *ID3D11RenderTargetView, *const [4]f32) callconv(.winapi) void,
    };
};

const IDXGIFactory2 = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        // IDXGIObject
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIFactory
        EnumAdapters: *const anyopaque,
        MakeWindowAssociation: *const fn (*IDXGIFactory2, *anyopaque, UINT) callconv(.winapi) HRESULT,
        GetWindowAssociation: *const anyopaque,
        CreateSwapChain: *const anyopaque,
        CreateSoftwareAdapter: *const anyopaque,
        // IDXGIFactory1
        EnumAdapters1: *const anyopaque,
        IsCurrent: *const anyopaque,
        // IDXGIFactory2
        IsWindowedStereoEnabled: *const anyopaque,
        CreateSwapChainForHwnd: *const fn (
            *IDXGIFactory2,
            *anyopaque, // ID3D11Device (IUnknown*)
            *anyopaque, // HWND
            *const SwapChainDesc1,
            ?*const anyopaque, // fullscreen desc
            ?*anyopaque, // restrict-to output
            *?*IDXGISwapChain1,
        ) callconv(.winapi) HRESULT,
    };
};

const IDXGISwapChain1 = extern struct {
    vtable: *const VTable,

    const VTable = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        // IDXGIObject
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        GetPrivateData: *const anyopaque,
        GetParent: *const anyopaque,
        // IDXGIDeviceSubObject
        GetDevice: *const anyopaque,
        // IDXGISwapChain
        Present: *const fn (*IDXGISwapChain1, UINT, UINT) callconv(.winapi) HRESULT,
        GetBuffer: *const fn (*IDXGISwapChain1, UINT, *const GUID, *?*anyopaque) callconv(.winapi) HRESULT,
        SetFullscreenState: *const anyopaque,
        GetFullscreenState: *const anyopaque,
        GetDesc: *const anyopaque,
        ResizeBuffers: *const fn (*IDXGISwapChain1, UINT, UINT, UINT, UINT, UINT) callconv(.winapi) HRESULT,
    };
};

comptime {
    // **슬롯 번호가 계약이다**(위 규칙 ⑵). 포인터 하나가 8바이트이므로 슬롯 n의 오프셋은 8n이다.
    // 위쪽에 슬롯을 끼워 넣거나 빠뜨리면 여기서 컴파일이 멈춘다 — 런타임에 엉뚱한 함수를 부르는 대신.
    if (@sizeOf(usize) == 8) {
        const slot = struct {
            fn at(comptime T: type, comptime name: []const u8) usize {
                return @offsetOf(T, name) / 8;
            }
        };
        std.debug.assert(slot.at(ID3D11Device.VTable, "QueryInterface") == 0);
        std.debug.assert(slot.at(ID3D11Device.VTable, "CreateRenderTargetView") == 9);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "OMSetRenderTargets") == 33);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "RSSetViewports") == 44);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "ClearRenderTargetView") == 50);
        std.debug.assert(slot.at(IDXGIFactory2.VTable, "CreateSwapChainForHwnd") == 15);
        std.debug.assert(slot.at(IDXGISwapChain1.VTable, "Present") == 8);
        std.debug.assert(slot.at(IDXGISwapChain1.VTable, "GetBuffer") == 9);
        std.debug.assert(slot.at(IDXGISwapChain1.VTable, "ResizeBuffers") == 13);
    }
}

// ── DXGI/D3D11 값 타입 ───────────────────────────────────────────────────────────────────────

const SampleDesc = extern struct { count: UINT, quality: UINT };

const SwapChainDesc1 = extern struct {
    width: UINT,
    height: UINT,
    format: UINT,
    stereo: BOOL,
    sample_desc: SampleDesc,
    buffer_usage: UINT,
    buffer_count: UINT,
    scaling: UINT,
    swap_effect: UINT,
    alpha_mode: UINT,
    flags: UINT,
};

const Viewport = extern struct {
    top_left_x: f32,
    top_left_y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(SwapChainDesc1) == 48);
        std.debug.assert(@sizeOf(Viewport) == 24);

        // **크기만으로는 부족하다.** 같은 `UINT` 두 필드를 맞바꿔도 크기는 48 그대로라 통과하고, 런타임에
        // `DXGI_ERROR_INVALID_CALL`로만 드러난다 — `AlphaMode`로 이미 그 증상을 겪었다. 그래서 오프셋을
        // 못 박는다. 위쪽 필드를 하나 끼워 넣으면 여기서 컴파일이 멈춘다.
        std.debug.assert(@offsetOf(SwapChainDesc1, "width") == 0);
        std.debug.assert(@offsetOf(SwapChainDesc1, "height") == 4);
        std.debug.assert(@offsetOf(SwapChainDesc1, "format") == 8);
        std.debug.assert(@offsetOf(SwapChainDesc1, "stereo") == 12);
        std.debug.assert(@offsetOf(SwapChainDesc1, "sample_desc") == 16);
        std.debug.assert(@offsetOf(SwapChainDesc1, "buffer_usage") == 24);
        std.debug.assert(@offsetOf(SwapChainDesc1, "buffer_count") == 28);
        std.debug.assert(@offsetOf(SwapChainDesc1, "scaling") == 32);
        std.debug.assert(@offsetOf(SwapChainDesc1, "swap_effect") == 36);
        std.debug.assert(@offsetOf(SwapChainDesc1, "alpha_mode") == 40);
        std.debug.assert(@offsetOf(SwapChainDesc1, "flags") == 44);
    }
}

/// `DXGI_FORMAT_B8G8R8A8_UNORM`. BGRA를 쓴다 — Windows 합성기의 기본 형식이라 present 경로에 변환이
/// 끼지 않고, `NativeMetalCell`의 색이 이미 `0xAARRGGBB`(=BGRA 바이트 순서)라 W7.2b가 그대로 쓴다.
const format_b8g8r8a8_unorm: UINT = 87;
const usage_render_target_output: UINT = 0x20;
/// `DXGI_SWAP_EFFECT_FLIP_DISCARD`. 플립 모델이라야 합성기가 복사 없이 표시하고, 나중에
/// DirectComposition으로 갈아탈 때도 같은 모델이다.
const swap_effect_flip_discard: UINT = 4;
const scaling_stretch: UINT = 0;
/// `DXGI_ALPHA_MODE_UNSPECIFIED`. **HWND 스왑체인은 이것이어야 한다** — `IGNORE`(1)는 합성(composition)
/// 스왑체인용이고, HWND에 주면 `CreateSwapChainForHwnd`가 `DXGI_ERROR_INVALID_CALL`(0x887A0001)로 거절한다
/// (실측). DirectComposition으로 갈아탈 때 함께 바뀌는 값이다.
const alpha_mode_unspecified: UINT = 0;

const driver_type_hardware: UINT = 1;
/// `D3D_DRIVER_TYPE_WARP` — 소프트웨어 래스터라이저. GPU가 없거나 드라이버가 D3D11을 못 주는 환경에서
/// 쓴다. 계획 문서가 "Windows는 WARP가 있어 GPU 없는 러너에서도 렌더 스모크를 돌릴 여지가 있다"고 적어
/// 둔 것이 이 값이다(`docs/plans/windows-platform.md` 검증 절) — 그 여지를 코드가 실제로 열어 둔다.
const driver_type_warp: UINT = 5;

/// `DXGI_MWA_NO_ALT_ENTER`. **터미널에는 필수다.** 스왑체인을 만들면 DXGI가 그 창의 Alt+Enter를 후킹해
/// 독점 전체화면을 토글하는데, Alt+Enter는 앱 키바인딩이라 그대로 두면 W7.4의 입력이 그 키를 영영 못 받고
/// 사용자는 의도치 않은 모드 전환을 본다.
const dxgi_mwa_no_alt_enter: UINT = 1 << 1;
/// `D3D11_SDK_VERSION`. 헤더가 정한 상수다.
const d3d11_sdk_version: UINT = 7;
const feature_level_11_0: UINT = 0xb000;

extern "d3d11" fn D3D11CreateDevice(
    adapter: ?*anyopaque,
    driver_type: UINT,
    software: ?*anyopaque,
    flags: UINT,
    feature_levels: ?[*]const UINT,
    feature_level_count: UINT,
    sdk_version: UINT,
    device: *?*ID3D11Device,
    feature_level_out: ?*UINT,
    context: *?*ID3D11DeviceContext,
) callconv(.winapi) HRESULT;

extern "dxgi" fn CreateDXGIFactory1(riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;

// ── 표시 경로 ────────────────────────────────────────────────────────────────────────────────

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
    device: *ID3D11Device,
    context: *ID3D11DeviceContext,
    swapchain: *IDXGISwapChain1,
    /// 현재 백버퍼의 렌더 타깃 뷰. 리사이즈마다 버리고 다시 만든다.
    rtv: ?*ID3D11RenderTargetView = null,
    width_px: u32,
    height_px: u32,
    driver: Driver,
    allocator: std.mem.Allocator,

    pub fn create(allocator: std.mem.Allocator, hwnd: *anyopaque, width_px: u32, height_px: u32) Error!*Present {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

        var device: ?*ID3D11Device = null;
        var context: ?*ID3D11DeviceContext = null;
        const levels = [_]UINT{feature_level_11_0};
        // **하드웨어 먼저, 안 되면 WARP.** 계획 문서가 GPU 없는 러너에서도 렌더 스모크를 돌릴 근거로
        // WARP를 들었으므로, 코드가 그 갈래를 실제로 갖는다. 어느 쪽으로 섰는지는 `driver` 에 남겨
        // 호출자가 보고할 수 있게 한다 — "GPU로 그렸다"와 "소프트웨어로 그렸다"는 성능 판정이 다르다.
        var driver: Driver = .hardware;
        const driver_types = [_]UINT{ driver_type_hardware, driver_type_warp };
        for (driver_types, 0..) |driver_type, i| {
            const hr = D3D11CreateDevice(
                null,
                driver_type,
                null,
                0,
                &levels,
                levels.len,
                d3d11_sdk_version,
                &device,
                null,
                &context,
            );
            if (!failed(hr)) {
                driver = if (driver_type == driver_type_warp) .warp else .hardware;
                break;
            }
            last_hresult = hr;
            // **후보 개수에서 유도한다.** `i == 1`처럼 박아 두면 후보를 하나 늘리는 순간 조용히 틀린다.
            if (i == driver_types.len - 1) return error.CreateDeviceFailed;
        }
        errdefer releaseOpt(device);
        errdefer releaseOpt(context);

        var factory_raw: ?*anyopaque = null;
        {
            const hr = CreateDXGIFactory1(&IID_IDXGIFactory2, &factory_raw);
            if (failed(hr)) {
                last_hresult = hr;
                return error.CreateFactoryFailed;
            }
        }
        const factory: *IDXGIFactory2 = @ptrCast(@alignCast(factory_raw.?));
        // 팩토리는 스왑체인을 만들고 나면 필요 없다 — 스왑체인이 자기 부모를 참조한다.
        defer releaseOpt(factory_raw);

        // 0×0 스왑체인은 만들 수 없다. 최소화된 창에서 생성될 수 있으므로 1로 올린다(창이 커지면
        // `resize`가 실제 크기로 맞춘다).
        const w = @max(@as(u32, 1), width_px);
        const h = @max(@as(u32, 1), height_px);
        const desc = SwapChainDesc1{
            .width = w,
            .height = h,
            .format = format_b8g8r8a8_unorm,
            .stereo = 0,
            .sample_desc = .{ .count = 1, .quality = 0 },
            .buffer_usage = usage_render_target_output,
            // 플립 모델은 최소 2다. 3으로 올리면 지연이 늘고, 2가 프레임 페이싱의 기본이다.
            .buffer_count = 2,
            .scaling = scaling_stretch,
            .swap_effect = swap_effect_flip_discard,
            .alpha_mode = alpha_mode_unspecified,
            .flags = 0,
        };

        var swapchain: ?*IDXGISwapChain1 = null;
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
            if (failed(hr)) {
                last_hresult = hr;
                return error.CreateSwapChainFailed;
            }
        }
        errdefer releaseOpt(swapchain);

        // **Alt+Enter를 DXGI에서 빼앗아 온다.** 스왑체인을 만든 **뒤에** 불러야 그 창의 연결이 잡힌다.
        // 실패해도 창은 산다(전체화면 토글이 남을 뿐) — 그래서 오류로 올리지 않고 코드만 남긴다.
        {
            const hr = factory.vtable.MakeWindowAssociation(factory, hwnd, dxgi_mwa_no_alt_enter);
            if (failed(hr)) last_hresult = hr;
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
        releaseOpt(self.rtv);
        releaseOpt(@as(?*anyopaque, @ptrCast(self.swapchain)));
        releaseOpt(@as(?*anyopaque, @ptrCast(self.context)));
        releaseOpt(@as(?*anyopaque, @ptrCast(self.device)));
        self.allocator.destroy(self);
    }

    /// 백버퍼를 꺼내 렌더 타깃 뷰를 만든다. 생성 직후와 리사이즈 직후에 부른다.
    fn acquireBackBuffer(self: *Present) Error!void {
        var back: ?*anyopaque = null;
        const hr = self.swapchain.vtable.GetBuffer(self.swapchain, 0, &IID_ID3D11Texture2D, &back);
        if (failed(hr)) {
            last_hresult = hr;
            return error.BackBufferFailed;
        }
        // **텍스처는 뷰를 만든 즉시 놓아 준다.** 뷰가 자원을 참조하므로 우리가 계속 들고 있을 이유가 없고,
        // 들고 있으면 다음 `ResizeBuffers`가 "참조가 남았다"로 실패한다.
        defer releaseOpt(back);

        var rtv: ?*ID3D11RenderTargetView = null;
        const hr2 = self.device.vtable.CreateRenderTargetView(self.device, back.?, null, &rtv);
        if (failed(hr2)) {
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

        releaseOpt(self.rtv);
        self.rtv = null;

        const hr = self.swapchain.vtable.ResizeBuffers(self.swapchain, 0, w, h, 0, 0);
        if (failed(hr)) {
            last_hresult = hr;
            return error.ResizeFailed;
        }
        self.width_px = w;
        self.height_px = h;
        try self.acquireBackBuffer();
    }

    /// 백버퍼를 한 색으로 지우고 내보낸다. W7.2b가 이 사이에 셀 드로우를 끼운다.
    ///
    /// `rgba`는 **선형이 아니라 그대로** 쓰는 값이다(스왑체인 형식이 `_UNORM`이므로 셰이더 없이 그 바이트가
    /// 곧 화면 색이다). 색 관리는 이 슬라이스의 범위가 아니다.
    pub fn clearAndPresent(self: *Present, rgba: [4]f32, vsync: bool) Error!void {
        const rtv = self.rtv orelse return error.BackBufferFailed;

        var targets = [_]?*ID3D11RenderTargetView{rtv};
        self.context.vtable.OMSetRenderTargets(self.context, 1, &targets, null);

        const viewports = [_]Viewport{.{
            .top_left_x = 0,
            .top_left_y = 0,
            .width = @floatFromInt(self.width_px),
            .height = @floatFromInt(self.height_px),
            .min_depth = 0,
            .max_depth = 1,
        }};
        self.context.vtable.RSSetViewports(self.context, 1, &viewports);

        self.context.vtable.ClearRenderTargetView(self.context, rtv, &rgba);

        const hr = self.swapchain.vtable.Present(self.swapchain, if (vsync) 1 else 0, 0);
        if (failed(hr)) {
            last_hresult = hr;
            return error.PresentFailed;
        }
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
