//! D3D11/DXGI COM 바인딩 층 — W7.2.
//!
//! **이 파일은 정책을 갖지 않는다.** 타입·상수·vtable 선언만 있다. 무엇을 만들고 어떤 순서로 놓을지는
//! `d3d11_present.zig`(표시 경로)와 `d3d11_cells.zig`(셀 파이프라인)가 정한다. 바인딩을 갈라 둔 이유는
//! 둘이 같은 인터페이스를 쓰기 때문이다 — 한쪽에 두면 다른 쪽이 그 파일을 통째로 import해야 하고, 그러면
//! "표시 경로만 안다"는 경계가 이름만 남는다.
//!
//! ## COM을 Zig로 쓰는 규약 (계약 §2c)
//!
//! Zig엔 COM 지원이 없다. COM 객체는 **첫 워드가 vtable 포인터인 구조체**이고, vtable은 함수 포인터가
//! **정해진 순서로** 늘어선 것이다. 그 순서가 곧 ABI다 — 슬롯 하나를 빠뜨리면 **컴파일은 되고** 런타임에
//! 엉뚱한 함수를 부른다. 그래서 두 규칙을 둔다.
//!
//! ⑴ **우리가 부르지 않는 슬롯도 자리를 채운다.** 타입은 `*const anyopaque`로 둬서 실수로 못 부르게 한다.
//! ⑵ **슬롯 번호를 `@offsetOf`로 comptime에 못 박는다.** 위에 슬롯을 하나 끼워 넣으면 그 자리에서 컴파일이
//!    멈춘다. comptime이라 **Windows 러너 없이 세 타깃 전부**가 이 게이트를 통과해야 한다.
//!
//! 구조체도 같다. 크기만 재면 같은 `UINT` 둘을 맞바꿔도 통과하므로 **오프셋까지** 못 박는다 — `AlphaMode`를
//! 잘못 넣어 `DXGI_ERROR_INVALID_CALL`만 보고 원인을 헤맨 적이 있다(§2c 실측).

const std = @import("std");

pub const HRESULT = i32;
pub const UINT = u32;
pub const BOOL = i32;
pub const HWND = *anyopaque;

pub fn failed(hr: HRESULT) bool {
    return hr < 0;
}

pub const GUID = extern struct {
    data1: u32,
    data2: u16,
    data3: u16,
    data4: [8]u8,
};

/// `IID_IDXGIFactory2` — `{50c83a1c-e072-4c48-87b0-3630fa36a6d0}`. 틀리면 `CreateDXGIFactory1`이
/// `E_NOINTERFACE`를 돌려주므로 **런타임에 즉시 드러난다**.
pub const IID_IDXGIFactory2 = GUID{
    .data1 = 0x50c83a1c,
    .data2 = 0xe072,
    .data3 = 0x4c48,
    .data4 = .{ 0x87, 0xb0, 0x36, 0x30, 0xfa, 0x36, 0xa6, 0xd0 },
};

/// `IID_ID3D11Texture2D` — `{6f15aaf2-d208-4e89-9ab4-489535d34f9c}`. 백버퍼를 꺼낼 때 쓴다.
pub const IID_ID3D11Texture2D = GUID{
    .data1 = 0x6f15aaf2,
    .data2 = 0xd208,
    .data3 = 0x4e89,
    .data4 = .{ 0x9a, 0xb4, 0x48, 0x95, 0x35, 0xd3, 0x4f, 0x9c },
};

/// 모든 COM 인터페이스의 앞 세 슬롯. 우리가 실제로 부르는 것은 `Release` 하나다.
pub const IUnknown = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const fn (*IUnknown) callconv(.winapi) u32,
    };

    pub fn release(self: *IUnknown) void {
        _ = self.vtable.Release(self);
    }
};

/// 어떤 COM 포인터든 놓아 준다. `null`이면 아무것도 하지 않는다 — 정리 경로가 부분 실패에도 안전해야 한다.
pub fn releaseOpt(ptr: anytype) void {
    if (ptr) |p| @as(*IUnknown, @ptrCast(@alignCast(p))).release();
}

pub const ID3D11RenderTargetView = opaque {};
pub const ID3D11Buffer = opaque {};
pub const ID3D11Texture2D = opaque {};
pub const ID3D11ShaderResourceView = opaque {};
pub const ID3D11SamplerState = opaque {};
pub const ID3D11BlendState = opaque {};
pub const ID3D11InputLayout = opaque {};
pub const ID3D11VertexShader = opaque {};
pub const ID3D11PixelShader = opaque {};

pub const ID3D11Device = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        // ID3D11Device
        CreateBuffer: *const fn (*ID3D11Device, *const BufferDesc, ?*const SubresourceData, *?*ID3D11Buffer) callconv(.winapi) HRESULT,
        CreateTexture1D: *const anyopaque,
        CreateTexture2D: *const fn (*ID3D11Device, *const Texture2DDesc, ?*const SubresourceData, *?*ID3D11Texture2D) callconv(.winapi) HRESULT,
        CreateTexture3D: *const anyopaque,
        CreateShaderResourceView: *const fn (*ID3D11Device, *anyopaque, ?*const anyopaque, *?*ID3D11ShaderResourceView) callconv(.winapi) HRESULT,
        CreateUnorderedAccessView: *const anyopaque,
        CreateRenderTargetView: *const fn (*ID3D11Device, *anyopaque, ?*const anyopaque, *?*ID3D11RenderTargetView) callconv(.winapi) HRESULT,
        CreateDepthStencilView: *const anyopaque,
        CreateInputLayout: *const fn (*ID3D11Device, [*]const InputElementDesc, UINT, *const anyopaque, usize, *?*ID3D11InputLayout) callconv(.winapi) HRESULT,
        CreateVertexShader: *const fn (*ID3D11Device, *const anyopaque, usize, ?*anyopaque, *?*ID3D11VertexShader) callconv(.winapi) HRESULT,
        CreateGeometryShader: *const anyopaque,
        CreateGeometryShaderWithStreamOutput: *const anyopaque,
        CreatePixelShader: *const fn (*ID3D11Device, *const anyopaque, usize, ?*anyopaque, *?*ID3D11PixelShader) callconv(.winapi) HRESULT,
        CreateHullShader: *const anyopaque,
        CreateDomainShader: *const anyopaque,
        CreateComputeShader: *const anyopaque,
        CreateClassLinkage: *const anyopaque,
        CreateBlendState: *const fn (*ID3D11Device, *const BlendDesc, *?*ID3D11BlendState) callconv(.winapi) HRESULT,
        CreateDepthStencilState: *const anyopaque,
        CreateRasterizerState: *const anyopaque,
        CreateSamplerState: *const fn (*ID3D11Device, *const SamplerDesc, *?*ID3D11SamplerState) callconv(.winapi) HRESULT,
    };
};

pub const ID3D11DeviceContext = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        // IUnknown
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        // ID3D11DeviceChild
        GetDevice: *const anyopaque,
        GetPrivateData: *const anyopaque,
        SetPrivateData: *const anyopaque,
        SetPrivateDataInterface: *const anyopaque,
        // ID3D11DeviceContext — 부르지 않는 슬롯도 **자리를 채운다**(규칙 ⑴).
        VSSetConstantBuffers: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11Buffer) callconv(.winapi) void,
        PSSetShaderResources: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11ShaderResourceView) callconv(.winapi) void,
        PSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11PixelShader, ?*const anyopaque, UINT) callconv(.winapi) void,
        PSSetSamplers: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11SamplerState) callconv(.winapi) void,
        VSSetShader: *const fn (*ID3D11DeviceContext, ?*ID3D11VertexShader, ?*const anyopaque, UINT) callconv(.winapi) void,
        DrawIndexed: *const anyopaque,
        Draw: *const anyopaque,
        Map: *const fn (*ID3D11DeviceContext, *anyopaque, UINT, UINT, UINT, *MappedSubresource) callconv(.winapi) HRESULT,
        Unmap: *const fn (*ID3D11DeviceContext, *anyopaque, UINT) callconv(.winapi) void,
        PSSetConstantBuffers: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11Buffer) callconv(.winapi) void,
        IASetInputLayout: *const fn (*ID3D11DeviceContext, ?*ID3D11InputLayout) callconv(.winapi) void,
        IASetVertexBuffers: *const fn (*ID3D11DeviceContext, UINT, UINT, [*]const ?*ID3D11Buffer, [*]const UINT, [*]const UINT) callconv(.winapi) void,
        IASetIndexBuffer: *const anyopaque,
        DrawIndexedInstanced: *const anyopaque,
        DrawInstanced: *const fn (*ID3D11DeviceContext, UINT, UINT, UINT, UINT) callconv(.winapi) void,
        GSSetConstantBuffers: *const anyopaque,
        GSSetShader: *const anyopaque,
        IASetPrimitiveTopology: *const fn (*ID3D11DeviceContext, UINT) callconv(.winapi) void,
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
        OMSetBlendState: *const fn (*ID3D11DeviceContext, ?*ID3D11BlendState, ?*const [4]f32, UINT) callconv(.winapi) void,
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

pub const IDXGIFactory2 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
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
        MakeWindowAssociation: *const fn (*IDXGIFactory2, HWND, UINT) callconv(.winapi) HRESULT,
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
            HWND,
            *const SwapChainDesc1,
            ?*const anyopaque, // fullscreen desc
            ?*anyopaque, // restrict-to output
            *?*IDXGISwapChain1,
        ) callconv(.winapi) HRESULT,
    };
};

pub const IDXGISwapChain1 = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
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

/// 컴파일된 셰이더 바이트코드를 담는 COM 버퍼. `D3DCompile`이 코드와 오류 메시지를 각각 이걸로 준다.
pub const ID3DBlob = extern struct {
    vtable: *const VTable,

    pub const VTable = extern struct {
        QueryInterface: *const anyopaque,
        AddRef: *const anyopaque,
        Release: *const anyopaque,
        GetBufferPointer: *const fn (*ID3DBlob) callconv(.winapi) [*]u8,
        GetBufferSize: *const fn (*ID3DBlob) callconv(.winapi) usize,
    };

    pub fn bytes(self: *ID3DBlob) []const u8 {
        return self.vtable.GetBufferPointer(self)[0..self.vtable.GetBufferSize(self)];
    }
};

comptime {
    // **슬롯 번호가 계약이다**(규칙 ⑵). 포인터 하나가 8바이트이므로 슬롯 n의 오프셋은 8n이다.
    if (@sizeOf(usize) == 8) {
        const slot = struct {
            fn at(comptime T: type, comptime name: []const u8) usize {
                return @offsetOf(T, name) / 8;
            }
        };
        // ID3D11Device
        std.debug.assert(slot.at(ID3D11Device.VTable, "CreateBuffer") == 3);
        std.debug.assert(slot.at(ID3D11Device.VTable, "CreateTexture2D") == 5);
        std.debug.assert(slot.at(ID3D11Device.VTable, "CreateShaderResourceView") == 7);
        std.debug.assert(slot.at(ID3D11Device.VTable, "CreateRenderTargetView") == 9);
        std.debug.assert(slot.at(ID3D11Device.VTable, "CreateInputLayout") == 11);
        std.debug.assert(slot.at(ID3D11Device.VTable, "CreateVertexShader") == 12);
        std.debug.assert(slot.at(ID3D11Device.VTable, "CreatePixelShader") == 15);
        std.debug.assert(slot.at(ID3D11Device.VTable, "CreateBlendState") == 20);
        std.debug.assert(slot.at(ID3D11Device.VTable, "CreateSamplerState") == 23);
        // ID3D11DeviceContext
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "VSSetConstantBuffers") == 7);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "PSSetShaderResources") == 8);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "PSSetShader") == 9);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "PSSetSamplers") == 10);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "VSSetShader") == 11);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "Map") == 14);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "Unmap") == 15);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "PSSetConstantBuffers") == 16);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "IASetInputLayout") == 17);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "IASetVertexBuffers") == 18);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "DrawInstanced") == 21);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "IASetPrimitiveTopology") == 24);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "OMSetRenderTargets") == 33);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "OMSetBlendState") == 35);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "RSSetViewports") == 44);
        std.debug.assert(slot.at(ID3D11DeviceContext.VTable, "ClearRenderTargetView") == 50);
        // DXGI
        std.debug.assert(slot.at(IDXGIFactory2.VTable, "MakeWindowAssociation") == 8);
        std.debug.assert(slot.at(IDXGIFactory2.VTable, "CreateSwapChainForHwnd") == 15);
        std.debug.assert(slot.at(IDXGISwapChain1.VTable, "Present") == 8);
        std.debug.assert(slot.at(IDXGISwapChain1.VTable, "GetBuffer") == 9);
        std.debug.assert(slot.at(IDXGISwapChain1.VTable, "ResizeBuffers") == 13);
        // ID3DBlob
        std.debug.assert(slot.at(ID3DBlob.VTable, "GetBufferPointer") == 3);
        std.debug.assert(slot.at(ID3DBlob.VTable, "GetBufferSize") == 4);
    }
}

// ── 값 타입 ──────────────────────────────────────────────────────────────────────────────────

pub const SampleDesc = extern struct { count: UINT, quality: UINT };

pub const SwapChainDesc1 = extern struct {
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

pub const Viewport = extern struct {
    top_left_x: f32,
    top_left_y: f32,
    width: f32,
    height: f32,
    min_depth: f32,
    max_depth: f32,
};

pub const BufferDesc = extern struct {
    byte_width: UINT,
    usage: UINT,
    bind_flags: UINT,
    cpu_access_flags: UINT,
    misc_flags: UINT,
    structure_byte_stride: UINT,
};

pub const SubresourceData = extern struct {
    sys_mem: *const anyopaque,
    sys_mem_pitch: UINT,
    sys_mem_slice_pitch: UINT,
};

pub const Texture2DDesc = extern struct {
    width: UINT,
    height: UINT,
    mip_levels: UINT,
    array_size: UINT,
    format: UINT,
    sample_desc: SampleDesc,
    usage: UINT,
    bind_flags: UINT,
    cpu_access_flags: UINT,
    misc_flags: UINT,
};

pub const InputElementDesc = extern struct {
    semantic_name: [*:0]const u8,
    semantic_index: UINT,
    format: UINT,
    input_slot: UINT,
    aligned_byte_offset: UINT,
    input_slot_class: UINT,
    instance_data_step_rate: UINT,
};

pub const MappedSubresource = extern struct {
    data: ?*anyopaque,
    row_pitch: UINT,
    depth_pitch: UINT,
};

pub const SamplerDesc = extern struct {
    filter: UINT,
    address_u: UINT,
    address_v: UINT,
    address_w: UINT,
    mip_lod_bias: f32,
    max_anisotropy: UINT,
    comparison_func: UINT,
    border_color: [4]f32,
    min_lod: f32,
    max_lod: f32,
};

pub const RenderTargetBlendDesc = extern struct {
    blend_enable: BOOL,
    src_blend: UINT,
    dest_blend: UINT,
    blend_op: UINT,
    src_blend_alpha: UINT,
    dest_blend_alpha: UINT,
    blend_op_alpha: UINT,
    render_target_write_mask: u8,
};

pub const BlendDesc = extern struct {
    alpha_to_coverage_enable: BOOL,
    independent_blend_enable: BOOL,
    render_target: [8]RenderTargetBlendDesc,
};

comptime {
    if (@sizeOf(usize) == 8) {
        // **크기만으로는 부족하다.** 같은 `UINT` 두 필드를 맞바꿔도 크기가 그대로라 통과하고, 런타임에
        // `INVALID_CALL`로만 드러난다 — `AlphaMode`로 이미 그 증상을 겪었다. 오프셋까지 못 박는다.
        std.debug.assert(@sizeOf(SwapChainDesc1) == 48);
        std.debug.assert(@offsetOf(SwapChainDesc1, "sample_desc") == 16);
        std.debug.assert(@offsetOf(SwapChainDesc1, "swap_effect") == 36);
        std.debug.assert(@offsetOf(SwapChainDesc1, "alpha_mode") == 40);
        std.debug.assert(@offsetOf(SwapChainDesc1, "flags") == 44);

        std.debug.assert(@sizeOf(Viewport) == 24);
        std.debug.assert(@sizeOf(BufferDesc) == 24);
        std.debug.assert(@sizeOf(SubresourceData) == 16);
        std.debug.assert(@sizeOf(Texture2DDesc) == 44);
        std.debug.assert(@offsetOf(Texture2DDesc, "sample_desc") == 20);
        std.debug.assert(@offsetOf(Texture2DDesc, "usage") == 28);
        std.debug.assert(@sizeOf(InputElementDesc) == 32);
        std.debug.assert(@offsetOf(InputElementDesc, "aligned_byte_offset") == 20);
        std.debug.assert(@sizeOf(MappedSubresource) == 16);
        std.debug.assert(@sizeOf(SamplerDesc) == 52);
        std.debug.assert(@offsetOf(SamplerDesc, "border_color") == 28);
        // 각 RT 항목은 7×UINT + u8 = 29바이트인데 4바이트 정렬로 32가 된다. 8개 배열이라 8 + 256 = 264.
        std.debug.assert(@sizeOf(RenderTargetBlendDesc) == 32);
        std.debug.assert(@sizeOf(BlendDesc) == 264);
        std.debug.assert(@offsetOf(BlendDesc, "render_target") == 8);
    }
}

// ── 상수 ─────────────────────────────────────────────────────────────────────────────────────

/// `DXGI_FORMAT_B8G8R8A8_UNORM`. 합성기 기본 형식이라 present에 변환이 끼지 않고, `NativeMetalCell`의
/// 색이 이미 `0xAARRGGBB`(= BGRA 바이트 순서)다.
pub const format_b8g8r8a8_unorm: UINT = 87;
/// `DXGI_FORMAT_R8G8B8A8_UNORM`. 글리프 아틀라스가 이 형식이다 — `renderer/glyph_pixels.zig`가 픽셀당
/// **4바이트**를 쓰고 커버리지를 **알파**에 담는다(RGB는 흰색 `0xFFFFFFFF`). 색은 셀이 들고 오므로
/// 아틀라스는 덮임 정도만 안다. 처음에 `R8_UNORM`으로 잡았다가 실제 픽셀 계약을 읽고 고쳤다.
pub const format_r8g8b8a8_unorm: UINT = 28;
pub const format_r32g32_float: UINT = 16;
pub const format_r32g32b32a32_float: UINT = 2;
pub const format_r32_uint: UINT = 42;

pub const usage_render_target_output: UINT = 0x20;
/// `DXGI_SWAP_EFFECT_FLIP_DISCARD`. 플립 모델이라야 합성기가 복사 없이 표시하고, DirectComposition으로
/// 갈아탈 때도 같은 모델이다.
pub const swap_effect_flip_discard: UINT = 4;
pub const scaling_stretch: UINT = 0;
/// `DXGI_ALPHA_MODE_UNSPECIFIED`. **HWND 스왑체인은 이것이어야 한다** — `IGNORE`(1)는 합성 스왑체인용이고,
/// HWND에 주면 `CreateSwapChainForHwnd`가 `DXGI_ERROR_INVALID_CALL`(0x887A0001)로 거절한다(실측).
pub const alpha_mode_unspecified: UINT = 0;
/// `DXGI_MWA_NO_ALT_ENTER`. **터미널에는 필수다** — 안 걸면 DXGI가 창의 Alt+Enter를 후킹해 독점 전체화면을
/// 토글하고, 앱 키바인딩인 Alt+Enter가 입력에 영영 닿지 않는다.
pub const dxgi_mwa_no_alt_enter: UINT = 1 << 1;

pub const driver_type_hardware: UINT = 1;
/// `D3D_DRIVER_TYPE_WARP` — 소프트웨어 래스터라이저. 계획 문서가 "GPU 없는 러너에서도 렌더 스모크를 돌릴
/// 여지"로 적어 둔 갈래다.
pub const driver_type_warp: UINT = 5;
pub const d3d11_sdk_version: UINT = 7;
pub const feature_level_11_0: UINT = 0xb000;

pub const usage_default: UINT = 0;
pub const usage_dynamic: UINT = 2;
pub const bind_vertex_buffer: UINT = 0x1;
pub const bind_constant_buffer: UINT = 0x4;
pub const bind_shader_resource: UINT = 0x8;
pub const cpu_access_write: UINT = 0x10000;
pub const map_write_discard: UINT = 4;

pub const input_per_vertex_data: UINT = 0;
pub const input_per_instance_data: UINT = 1;
pub const primitive_topology_trianglestrip: UINT = 5;

pub const filter_min_mag_mip_point: UINT = 0;
pub const texture_address_clamp: UINT = 3;
pub const comparison_never: UINT = 1;

pub const blend_src_alpha: UINT = 5;
pub const blend_inv_src_alpha: UINT = 6;
pub const blend_one: UINT = 2;
pub const blend_op_add: UINT = 1;
pub const color_write_enable_all: u8 = 0x0F;

pub extern "d3d11" fn D3D11CreateDevice(
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

pub extern "dxgi" fn CreateDXGIFactory1(riid: *const GUID, out: *?*anyopaque) callconv(.winapi) HRESULT;

// ── 셰이더 컴파일러 (동적 로딩) ──────────────────────────────────────────────────────────────

extern "kernel32" fn LoadLibraryA(name: [*:0]const u8) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetProcAddress(module: *anyopaque, name: [*:0]const u8) callconv(.winapi) ?*anyopaque;

const D3DCompileFn = *const fn (
    src: [*]const u8,
    src_len: usize,
    source_name: ?[*:0]const u8,
    defines: ?*const anyopaque,
    include: ?*anyopaque,
    entry: [*:0]const u8,
    target: [*:0]const u8,
    flags1: UINT,
    flags2: UINT,
    code: *?*ID3DBlob,
    errors: *?*ID3DBlob,
) callconv(.winapi) HRESULT;

/// `D3DCompile`을 **동적으로** 찾는다. import 라이브러리로 링크하지 않는 이유가 둘이다:
///
/// ⑴ **빌드가 Windows SDK를 전제하지 않는다.** 이 저장소는 mise가 준 Zig 하나로 빌드되는데, `d3dcompiler`
///    import 라이브러리를 링크에 넣으면 그 전제가 깨진다. 사전 컴파일(`fxc`)도 같은 이유로 안 쓴다.
/// ⑵ **없을 때 사람이 읽을 수 있게 실패한다.** 정적 링크면 DLL이 없는 순간 프로세스가 로더 단계에서 죽어
///    (`STATUS_DLL_NOT_FOUND`) 아무 메시지도 못 남긴다. 여기서는 `null`을 돌려주고 호출자가 설명한다.
///
/// `d3dcompiler_47.dll`은 Windows 8.1부터 **OS 구성요소**라 Windows 10/11에서는 사실상 항상 있다
/// (실측: `System32`에 10.0.19041.3636). 그래도 없을 수 있는 것처럼 다룬다.
pub fn loadD3DCompile() ?D3DCompileFn {
    const module = LoadLibraryA("d3dcompiler_47.dll") orelse return null;
    const proc = GetProcAddress(module, "D3DCompile") orelse return null;
    return @ptrCast(@alignCast(proc));
}
