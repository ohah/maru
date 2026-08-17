//! 셀 인스턴스 드로우 — W7.2b.
//!
//! **이 파일은 "셀 하나를 어떻게 화면에 그리는가"만 안다.** 무엇이 셀인지(터미널 화면·사이드바·chrome)는
//! 여기 없다 — 호출자가 `Cell` 배열을 만들어 넘긴다. 표시 대상(디바이스·스왑체인)도 여기서 만들지 않고
//! `d3d11_present.zig`가 만든 것을 받는다.
//!
//! ## 블렌드 규약은 macOS와 같다
//!
//! `renderer/metal_frame.zig`의 `NativeMetalCell`이 이미 정해 뒀다 — 배경 알파가 `0xFF`면 셀을 그 색으로
//! 채우고 글리프를 위에 섞고(`mix(bg, fg, coverage)`), `0`이면 배경 없이 커버리지만 그려 테마 기본 배경
//! (clear color)이 비친다. **그 규약을 여기서 다시 정하지 않는다** — 두 백엔드가 같은 화면을 내야 한다.
//!
//! ## 아틀라스는 RGBA8이고 커버리지는 **알파**에 있다
//!
//! `renderer/glyph_pixels.zig`의 `setPixel`이 픽셀당 4바이트를 쓰고 RGB를 흰색으로 채운다 — 덮임 정도는
//! **알파**다(`setPixelAlpha`가 부분 커버리지를 그렇게 넣는다). 그래서 D3D11 형식은 `R8G8B8A8_UNORM`이고
//! 픽셀 셰이더가 `.a`를 읽는다. 색은 셀이 들고 오므로 아틀라스의 RGB는 쓰지 않는다.
//!
//! 폰트가 아직 없어도(W7.3) box-drawing·block·braille·powerline·mosaic은 `renderer.synthesizeGlyph`가
//! codepoint에서 합성하므로 이 경로가 지금 검증된다 — 그것이 합성 dispatch의 **단일 출처**다.
//!
//! ## 정점 버퍼가 없다
//!
//! 사각형 네 꼭짓점은 `SV_VertexID`에서 만든다(triangle strip 4개). 셀마다 정점을 만들어 올리면 대역폭이
//! 네 배가 되는데, 셀은 전부 축 정렬 사각형이라 그럴 이유가 없다. 슬롯 0에는 **인스턴스 데이터만** 간다.

const std = @import("std");
const builtin = @import("builtin");
const d3d11 = @import("d3d11.zig");

pub const Error = error{
    UnsupportedPlatform,
    CompilerMissing,
    ShaderCompileFailed,
    CreateShaderFailed,
    CreateLayoutFailed,
    CreateBufferFailed,
    CreateAtlasFailed,
    CreateStateFailed,
    MapFailed,
    OutOfMemory,
};

pub var last_hresult: i32 = 0;

/// 셰이더 컴파일이 실패했을 때 컴파일러가 준 메시지. 진단 전용이다 — HLSL 오류를 코드 없이 보면
/// "셰이더가 안 된다"밖에 알 수 없다. 다음 실패가 덮어쓰고, 넘치면 잘린다.
pub var last_shader_error: [512]u8 = undefined;
pub var last_shader_error_len: usize = 0;

pub fn shaderError() []const u8 {
    return last_shader_error[0..last_shader_error_len];
}

/// **실패했으면 코드를 남긴다.** 이걸 거치지 않으면 `last_hresult`가 이전 값(대개 0)으로 남아 진단이
/// "원인이 없다"고 거짓말한다 — 실측으로 겪을 수 있는 함정이라 실패 지점마다 이 함수를 통과시킨다.
fn check(hr: d3d11.HRESULT, err: Error) Error!void {
    if (d3d11.failed(hr)) {
        last_hresult = hr;
        return err;
    }
}

fn recordShaderError(blob: ?*d3d11.ID3DBlob) void {
    last_shader_error_len = 0;
    const b = blob orelse return;
    const msg = b.bytes();
    const n = @min(msg.len, last_shader_error.len);
    @memcpy(last_shader_error[0..n], msg[0..n]);
    last_shader_error_len = n;
}

/// 셀 하나가 GPU로 가는 모양. **`NativeMetalCell`을 그대로 쓰지 않는 이유**는 그것이 아틀라스 좌표를
/// 픽셀로 들고 있어서다(`atlas_x_px` 등) — GPU는 0~1 UV를 원하므로 변환이 어딘가에서 일어나야 하고, 그
/// 변환은 아틀라스 크기를 아는 쪽(여기)이 한다. 색도 `0xAARRGGBB` 정수에서 여기서 한 번 푼다.
///
/// 64바이트. 필드 순서가 곧 입력 레이아웃이라 아래 `input_elements`와 함께 움직여야 한다.
pub const Cell = extern struct {
    /// 화면 픽셀 사각형 — `{x, y, width, height}`. 좌상단 기준.
    rect: [4]f32,
    /// 아틀라스 UV — `{u0, v0, u1, v1}`. 글리프가 없는 셀은 커버리지 0인 자리를 가리킨다.
    uv: [4]f32,
    /// 전경색 RGBA(0~1).
    fg: [4]f32,
    /// 배경색 RGBA(0~1). **알파가 판정이다** — 0이면 배경 없음(clear color가 비친다), 1이면 채운다.
    bg: [4]f32,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Cell) == 64);
        std.debug.assert(@offsetOf(Cell, "rect") == 0);
        std.debug.assert(@offsetOf(Cell, "uv") == 16);
        std.debug.assert(@offsetOf(Cell, "fg") == 32);
        std.debug.assert(@offsetOf(Cell, "bg") == 48);
    }
}

/// 프레임 상수. **16바이트 배수여야 한다** — D3D11 상수 버퍼의 규약이라 `_pad`가 장식이 아니다.
const FrameConstants = extern struct {
    viewport_px: [2]f32,
    _pad: [2]f32 = .{ 0, 0 },
};

comptime {
    std.debug.assert(@sizeOf(FrameConstants) % 16 == 0);
}

/// `0xAARRGGBB` → RGBA(0~1). 셀 색이 그 표현이라(`NativeMetalCell.foreground`·`background`) 여기서 푼다.
///
/// 순수라서 **모든 타깃에서** 테스트가 돈다.
pub fn colorFromArgb(argb: u32) [4]f32 {
    const a: f32 = @floatFromInt((argb >> 24) & 0xFF);
    const r: f32 = @floatFromInt((argb >> 16) & 0xFF);
    const g: f32 = @floatFromInt((argb >> 8) & 0xFF);
    const b: f32 = @floatFromInt(argb & 0xFF);
    return .{ r / 255.0, g / 255.0, b / 255.0, a / 255.0 };
}

/// 아틀라스 픽셀 사각형을 UV로 바꾸는 **순수** 변환. `NativeMetalCell`이 아틀라스 좌표를 픽셀로 들고
/// 오므로 이 변환이 필요하다.
///
/// 아틀라스 크기가 0이면 **모두 0을 준다** — 0으로 나누지 않고, 그 UV는 커버리지 0 자리를 가리키므로
/// 글리프가 안 그려질 뿐 화면이 깨지지 않는다.
///
/// **텍셀 경계를 그대로 준다(반 텍셀 안쪽으로 밀지 않는다).** 지금은 셀을 아틀라스 글리프와 **1:1 크기**로
/// 그리므로 프래그먼트 중심이 텍셀 중심에 떨어지고 POINT 샘플링이 정확히 맞는다. 확대·축소해 그리게 되면
/// (DPI 배율 등) 가장자리에서 옆 슬롯을 반 텍셀 끌어올 수 있으니 그때 반 텍셀 inset이 필요하다 — 지금
/// 넣으면 검증할 대조군이 없어 미룬다.
pub fn uvFromAtlasRect(x_px: u32, y_px: u32, w_px: u32, h_px: u32, atlas_w: u32, atlas_h: u32) [4]f32 {
    if (atlas_w == 0 or atlas_h == 0) return .{ 0, 0, 0, 0 };
    const aw: f32 = @floatFromInt(atlas_w);
    const ah: f32 = @floatFromInt(atlas_h);
    const x: f32 = @floatFromInt(x_px);
    const y: f32 = @floatFromInt(y_px);
    const w: f32 = @floatFromInt(w_px);
    const h: f32 = @floatFromInt(h_px);
    return .{ x / aw, y / ah, (x + w) / aw, (y + h) / ah };
}

// ── HLSL ─────────────────────────────────────────────────────────────────────────────────────

/// 셀 셰이더. **런타임에 컴파일한다**(`d3d11.loadD3DCompile`) — 빌드가 Windows SDK(`fxc`)를 전제하지
/// 않게 하기 위해서다. 비용은 시작할 때 한 번이다.
///
/// 정점은 `SV_VertexID`에서 만든다: `vid & 1`이 x, `vid >> 1`이 y라 0..3이 (0,0)·(1,0)·(0,1)·(1,1)이 되고
/// triangle strip 두 장이 사각형을 덮는다. 첫 삼각형이 NDC에서 시계 방향이라 기본 컬링(뒷면 제거)에
/// 걸리지 않는다 — 그래서 rasterizer state를 따로 만들지 않는다.
const hlsl_source =
    \\cbuffer Frame : register(b0) {
    \\    float2 viewport_px;
    \\    float2 pad_;
    \\};
    \\
    \\Texture2D<float4> atlas : register(t0);
    \\SamplerState samp : register(s0);
    \\
    \\struct VSIn {
    \\    float4 rect : TEXCOORD0;
    \\    float4 uv   : TEXCOORD1;
    \\    float4 fg   : TEXCOORD2;
    \\    float4 bg   : TEXCOORD3;
    \\    uint   vid  : SV_VertexID;
    \\};
    \\
    \\struct VSOut {
    \\    float4 pos : SV_Position;
    \\    float2 uv  : TEXCOORD0;
    \\    float4 fg  : TEXCOORD1;
    \\    float4 bg  : TEXCOORD2;
    \\};
    \\
    \\VSOut vs_main(VSIn i) {
    \\    float2 corner = float2((float)(i.vid & 1), (float)(i.vid >> 1));
    \\    float2 p = i.rect.xy + corner * i.rect.zw;
    \\    VSOut o;
    \\    o.pos = float4(p.x / viewport_px.x * 2.0 - 1.0,
    \\                   1.0 - p.y / viewport_px.y * 2.0,
    \\                   0.0, 1.0);
    \\    o.uv = lerp(i.uv.xy, i.uv.zw, corner);
    \\    o.fg = i.fg;
    \\    o.bg = i.bg;
    \\    return o;
    \\}
    \\
    \\float4 ps_main(VSOut i) : SV_Target {
    \\    // 커버리지는 알파에 있다 — RGB(흰색)는 쓰지 않는다. 색은 셀이 들고 온다.
    \\    float cov = atlas.Sample(samp, i.uv).a;
    \\    if (i.bg.a < 0.5) {
    \\        return float4(i.fg.rgb, cov * i.fg.a);
    \\    }
    \\    return float4(lerp(i.bg.rgb, i.fg.rgb, cov), 1.0);
    \\}
;

/// 입력 레이아웃. **전부 per-instance다** — 정점 버퍼가 없고 슬롯 0에 `Cell` 배열만 간다.
/// 오프셋이 `Cell`의 필드 순서와 같아야 하며, 위 comptime 단언이 그것을 지킨다.
const input_elements = [_]d3d11.InputElementDesc{
    .{ .semantic_name = "TEXCOORD", .semantic_index = 0, .format = d3d11.format_r32g32b32a32_float, .input_slot = 0, .aligned_byte_offset = 0, .input_slot_class = d3d11.input_per_instance_data, .instance_data_step_rate = 1 },
    .{ .semantic_name = "TEXCOORD", .semantic_index = 1, .format = d3d11.format_r32g32b32a32_float, .input_slot = 0, .aligned_byte_offset = 16, .input_slot_class = d3d11.input_per_instance_data, .instance_data_step_rate = 1 },
    .{ .semantic_name = "TEXCOORD", .semantic_index = 2, .format = d3d11.format_r32g32b32a32_float, .input_slot = 0, .aligned_byte_offset = 32, .input_slot_class = d3d11.input_per_instance_data, .instance_data_step_rate = 1 },
    .{ .semantic_name = "TEXCOORD", .semantic_index = 3, .format = d3d11.format_r32g32b32a32_float, .input_slot = 0, .aligned_byte_offset = 48, .input_slot_class = d3d11.input_per_instance_data, .instance_data_step_rate = 1 },
};

comptime {
    // **두 곳이 서로를 검증하게 한다.** `Cell`을 재배치하면 위 오프셋 단언이 잡지만, 여기 리터럴 오프셋만
    // 잘못 고치면 아무것도 안 잡고 런타임에 색과 좌표가 뒤섞인다(오류가 아니라 잘못된 그림이 나온다).
    // 필드 이름과 슬롯 순서를 여기서 묶어 둔다.
    const bound = [_][]const u8{ "rect", "uv", "fg", "bg" };
    std.debug.assert(input_elements.len == bound.len);
    for (input_elements, bound) |elem, name| {
        std.debug.assert(elem.aligned_byte_offset == @offsetOf(Cell, name));
        // 넷 다 `[4]f32`이므로 형식도 하나여야 한다 — 하나만 바꾸면 스트라이드가 어긋난다.
        std.debug.assert(elem.format == d3d11.format_r32g32b32a32_float);
        std.debug.assert(elem.input_slot_class == d3d11.input_per_instance_data);
    }
}

// ── 파이프라인 ───────────────────────────────────────────────────────────────────────────────

/// 셀을 그리는 데 필요한 GPU 자원 묶음. 디바이스는 **빌려 쓴다**(소유하지 않는다) — 표시 경로가 주인이다.
pub const CellPipeline = struct {
    device: *d3d11.ID3D11Device,
    context: *d3d11.ID3D11DeviceContext,
    vs: *d3d11.ID3D11VertexShader,
    ps: *d3d11.ID3D11PixelShader,
    layout: *d3d11.ID3D11InputLayout,
    constants: *d3d11.ID3D11Buffer,
    sampler: *d3d11.ID3D11SamplerState,
    blend: *d3d11.ID3D11BlendState,
    atlas: *d3d11.ID3D11Texture2D,
    atlas_srv: *d3d11.ID3D11ShaderResourceView,
    atlas_w: u32,
    atlas_h: u32,
    /// 인스턴스 버퍼. 프레임마다 `MAP_WRITE_DISCARD`로 다시 채운다. 셀 수가 늘면 다시 만든다.
    instances: ?*d3d11.ID3D11Buffer = null,
    instance_capacity: u32 = 0,
    allocator: std.mem.Allocator,

    /// `atlas_pixels`는 **RGBA8**이고 길이가 `atlas_w * atlas_h * 4`여야 한다(커버리지는 알파).
    pub fn create(
        allocator: std.mem.Allocator,
        device: *d3d11.ID3D11Device,
        context: *d3d11.ID3D11DeviceContext,
        atlas_w: u32,
        atlas_h: u32,
        atlas_pixels: []const u8,
    ) Error!*CellPipeline {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
        std.debug.assert(atlas_pixels.len == @as(usize, atlas_w) * atlas_h * 4);

        const compile = d3d11.loadD3DCompile() orelse return error.CompilerMissing;

        var vs_code: ?*d3d11.ID3DBlob = null;
        var ps_code: ?*d3d11.ID3DBlob = null;
        var errors: ?*d3d11.ID3DBlob = null;
        {
            const hr = compile(hlsl_source.ptr, hlsl_source.len, "maru_cells.hlsl", null, null, "vs_main", "vs_5_0", 0, 0, &vs_code, &errors);
            if (d3d11.failed(hr)) {
                last_hresult = hr;
                recordShaderError(errors);
                d3d11.releaseOpt(errors);
                return error.ShaderCompileFailed;
            }
            d3d11.releaseOpt(errors);
            errors = null;
        }
        defer d3d11.releaseOpt(vs_code);
        {
            const hr = compile(hlsl_source.ptr, hlsl_source.len, "maru_cells.hlsl", null, null, "ps_main", "ps_5_0", 0, 0, &ps_code, &errors);
            if (d3d11.failed(hr)) {
                last_hresult = hr;
                recordShaderError(errors);
                d3d11.releaseOpt(errors);
                return error.ShaderCompileFailed;
            }
            d3d11.releaseOpt(errors);
        }
        defer d3d11.releaseOpt(ps_code);

        const vs_bytes = vs_code.?.bytes();
        const ps_bytes = ps_code.?.bytes();

        var vs: ?*d3d11.ID3D11VertexShader = null;
        try check(device.vtable.CreateVertexShader(device, vs_bytes.ptr, vs_bytes.len, null, &vs), error.CreateShaderFailed);
        errdefer d3d11.releaseOpt(vs);

        var ps: ?*d3d11.ID3D11PixelShader = null;
        try check(device.vtable.CreatePixelShader(device, ps_bytes.ptr, ps_bytes.len, null, &ps), error.CreateShaderFailed);
        errdefer d3d11.releaseOpt(ps);

        // 입력 레이아웃은 **정점 셰이더 바이트코드로 검증된다** — 시맨틱이 안 맞으면 여기서 실패한다.
        var layout: ?*d3d11.ID3D11InputLayout = null;
        try check(device.vtable.CreateInputLayout(device, &input_elements, input_elements.len, vs_bytes.ptr, vs_bytes.len, &layout), error.CreateLayoutFailed);
        errdefer d3d11.releaseOpt(layout);

        var constants: ?*d3d11.ID3D11Buffer = null;
        {
            const desc = d3d11.BufferDesc{
                .byte_width = @sizeOf(FrameConstants),
                .usage = d3d11.usage_dynamic,
                .bind_flags = d3d11.bind_constant_buffer,
                .cpu_access_flags = d3d11.cpu_access_write,
                .misc_flags = 0,
                .structure_byte_stride = 0,
            };
            try check(device.vtable.CreateBuffer(device, &desc, null, &constants), error.CreateBufferFailed);
        }
        errdefer d3d11.releaseOpt(constants);

        var sampler: ?*d3d11.ID3D11SamplerState = null;
        {
            // **POINT 샘플링이다.** 글리프 커버리지는 셀 격자에 픽셀 정확히 놓이므로 선형 보간은 흐릿하게만
            // 만든다(macOS도 같은 이유로 확대하지 않는다). CLAMP는 아틀라스 가장자리에서 이웃 글리프를
            // 끌어오지 않게 한다.
            const desc = d3d11.SamplerDesc{
                .filter = d3d11.filter_min_mag_mip_point,
                .address_u = d3d11.texture_address_clamp,
                .address_v = d3d11.texture_address_clamp,
                .address_w = d3d11.texture_address_clamp,
                .mip_lod_bias = 0,
                .max_anisotropy = 1,
                .comparison_func = d3d11.comparison_never,
                .border_color = .{ 0, 0, 0, 0 },
                .min_lod = 0,
                .max_lod = 0,
            };
            try check(device.vtable.CreateSamplerState(device, &desc, &sampler), error.CreateStateFailed);
        }
        errdefer d3d11.releaseOpt(sampler);

        var blend: ?*d3d11.ID3D11BlendState = null;
        {
            // 배경 없는 셀은 커버리지를 알파로 실어 보내므로 straight-alpha 블렌드가 필요하다.
            // 배경 있는 셀은 알파 1이라 그대로 덮는다 — 같은 상태로 둘 다 맞는다.
            var desc = std.mem.zeroes(d3d11.BlendDesc);
            desc.render_target[0] = .{
                .blend_enable = 1,
                .src_blend = d3d11.blend_src_alpha,
                .dest_blend = d3d11.blend_inv_src_alpha,
                .blend_op = d3d11.blend_op_add,
                .src_blend_alpha = d3d11.blend_one,
                .dest_blend_alpha = d3d11.blend_inv_src_alpha,
                .blend_op_alpha = d3d11.blend_op_add,
                .render_target_write_mask = d3d11.color_write_enable_all,
            };
            try check(device.vtable.CreateBlendState(device, &desc, &blend), error.CreateStateFailed);
        }
        errdefer d3d11.releaseOpt(blend);

        var atlas: ?*d3d11.ID3D11Texture2D = null;
        {
            const desc = d3d11.Texture2DDesc{
                .width = atlas_w,
                .height = atlas_h,
                .mip_levels = 1,
                .array_size = 1,
                .format = d3d11.format_r8g8b8a8_unorm,
                .sample_desc = .{ .count = 1, .quality = 0 },
                .usage = d3d11.usage_default,
                .bind_flags = d3d11.bind_shader_resource,
                .cpu_access_flags = 0,
                .misc_flags = 0,
            };
            const init = d3d11.SubresourceData{
                .sys_mem = atlas_pixels.ptr,
                // RGBA8이라 한 줄이 폭×4바이트다 — `glyph_pixels`의 `bytes_per_row`와 같은 값이어야 한다.
                .sys_mem_pitch = atlas_w * 4,
                .sys_mem_slice_pitch = 0,
            };
            try check(device.vtable.CreateTexture2D(device, &desc, &init, &atlas), error.CreateAtlasFailed);
        }
        errdefer d3d11.releaseOpt(atlas);

        var srv: ?*d3d11.ID3D11ShaderResourceView = null;
        try check(device.vtable.CreateShaderResourceView(device, @ptrCast(atlas.?), null, &srv), error.CreateAtlasFailed);
        errdefer d3d11.releaseOpt(srv);

        const self = allocator.create(CellPipeline) catch return error.OutOfMemory;
        self.* = .{
            .device = device,
            .context = context,
            .vs = vs.?,
            .ps = ps.?,
            .layout = layout.?,
            .constants = constants.?,
            .sampler = sampler.?,
            .blend = blend.?,
            .atlas = atlas.?,
            .atlas_srv = srv.?,
            .atlas_w = atlas_w,
            .atlas_h = atlas_h,
            .allocator = allocator,
        };
        return self;
    }

    pub fn destroy(self: *CellPipeline) void {
        d3d11.releaseOpt(self.instances);
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.atlas_srv)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.atlas)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.blend)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.sampler)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.constants)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.layout)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.ps)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.vs)));
        // 디바이스·컨텍스트는 **빌린 것이라 놓지 않는다** — 표시 경로가 주인이다.
        self.allocator.destroy(self);
    }

    /// 인스턴스 버퍼가 `count`개를 담을 수 있게 한다. 모자라면 다시 만든다 — 줄어들 때는 그대로 둔다
    /// (창을 줄였다 키우는 것만으로 매번 버퍼를 다시 만들 이유가 없다).
    fn ensureCapacity(self: *CellPipeline, count: u32) Error!void {
        if (self.instances != null and self.instance_capacity >= count) return;
        // 1.5배로 키운다 — 창을 조금씩 늘릴 때마다 다시 만들지 않게.
        const want = @max(count, self.instance_capacity + self.instance_capacity / 2);
        const desc = d3d11.BufferDesc{
            .byte_width = want * @sizeOf(Cell),
            .usage = d3d11.usage_dynamic,
            .bind_flags = d3d11.bind_vertex_buffer,
            .cpu_access_flags = d3d11.cpu_access_write,
            .misc_flags = 0,
            .structure_byte_stride = 0,
        };
        var buf: ?*d3d11.ID3D11Buffer = null;
        try check(self.device.vtable.CreateBuffer(self.device, &desc, null, &buf), error.CreateBufferFailed);
        d3d11.releaseOpt(self.instances);
        self.instances = buf;
        self.instance_capacity = want;
    }

    /// 셀들을 그린다. 호출자가 `Present.beginFrame`으로 렌더 타깃을 걸어 둔 뒤에 부르고, 그 뒤에
    /// `Present.present`를 부른다. 셀이 없으면 아무것도 하지 않는다.
    ///
    /// `viewport_w`·`viewport_h`는 **걸어 둔 렌더 타깃의 크기와 같아야 한다** — 픽셀 좌표를 NDC로 바꾸는
    /// 분모라서, 어긋나면 격자가 조용히 늘어나거나 잘린다(오류가 아니라 잘못된 그림이 나온다). 표시 경로가
    /// 그 값을 갖고 있으므로 호출자는 `present.width_px`·`present.height_px`를 그대로 넘긴다.
    ///
    /// **파이프라인 상태를 되돌리지 않는다.** 셰이더·블렌드·입력 레이아웃이 걸린 채로 끝난다. 지금은
    /// 파이프라인이 하나뿐이라 문제가 없고, 둘이 되는 시점(chrome quad·kitty 이미지)에는 각자가 자기
    /// 상태를 걸어야 한다 — macOS 렌더러도 pass마다 그렇게 한다.
    pub fn draw(self: *CellPipeline, cells: []const Cell, viewport_w: u32, viewport_h: u32) Error!void {
        if (cells.len == 0) return;
        if (viewport_w == 0 or viewport_h == 0) return;
        const count: u32 = @intCast(cells.len);
        try self.ensureCapacity(count);

        // 인스턴스 업로드. DISCARD라 GPU가 이전 내용을 쓰는 중이어도 기다리지 않는다.
        {
            var mapped: d3d11.MappedSubresource = undefined;
            const hr = self.context.vtable.Map(self.context, @ptrCast(self.instances.?), 0, d3d11.map_write_discard, 0, &mapped);
            if (d3d11.failed(hr)) {
                last_hresult = hr;
                return error.MapFailed;
            }
            const dst: [*]Cell = @ptrCast(@alignCast(mapped.data.?));
            @memcpy(dst[0..cells.len], cells);
            self.context.vtable.Unmap(self.context, @ptrCast(self.instances.?), 0);
        }

        // 프레임 상수.
        {
            var mapped: d3d11.MappedSubresource = undefined;
            const hr = self.context.vtable.Map(self.context, @ptrCast(self.constants), 0, d3d11.map_write_discard, 0, &mapped);
            if (d3d11.failed(hr)) {
                last_hresult = hr;
                return error.MapFailed;
            }
            const dst: *FrameConstants = @ptrCast(@alignCast(mapped.data.?));
            dst.* = .{ .viewport_px = .{ @floatFromInt(viewport_w), @floatFromInt(viewport_h) } };
            self.context.vtable.Unmap(self.context, @ptrCast(self.constants), 0);
        }

        const strides = [_]d3d11.UINT{@sizeOf(Cell)};
        const offsets = [_]d3d11.UINT{0};
        const buffers = [_]?*d3d11.ID3D11Buffer{self.instances.?};
        self.context.vtable.IASetInputLayout(self.context, self.layout);
        self.context.vtable.IASetVertexBuffers(self.context, 0, 1, &buffers, &strides, &offsets);
        self.context.vtable.IASetPrimitiveTopology(self.context, d3d11.primitive_topology_trianglestrip);

        const cbs = [_]?*d3d11.ID3D11Buffer{self.constants};
        self.context.vtable.VSSetShader(self.context, self.vs, null, 0);
        self.context.vtable.VSSetConstantBuffers(self.context, 0, 1, &cbs);

        const srvs = [_]?*d3d11.ID3D11ShaderResourceView{self.atlas_srv};
        const samplers = [_]?*d3d11.ID3D11SamplerState{self.sampler};
        self.context.vtable.PSSetShader(self.context, self.ps, null, 0);
        self.context.vtable.PSSetShaderResources(self.context, 0, 1, &srvs);
        self.context.vtable.PSSetSamplers(self.context, 0, 1, &samplers);

        self.context.vtable.OMSetBlendState(self.context, self.blend, null, 0xFFFFFFFF);

        // 정점 4개(strip) × 인스턴스 `count`개.
        self.context.vtable.DrawInstanced(self.context, 4, count, 0, 0);
    }
};

const testing = std.testing;

test "colorFromArgb: 채널이 섞이지 않는다" {
    const c = colorFromArgb(0x80336699);
    try testing.expectApproxEqAbs(@as(f32, 0x33) / 255.0, c[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0x66) / 255.0, c[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0x99) / 255.0, c[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 0x80) / 255.0, c[3], 1e-6);

    // 배경 알파 0은 "배경 없음"이라는 **판정값**이다 — 1로 접으면 clear color가 영영 안 비친다.
    try testing.expectEqual(@as(f32, 0), colorFromArgb(0x00123456)[3]);
}

test "uvFromAtlasRect: 픽셀 사각형이 0~1 UV로 간다" {
    // 256×128 아틀라스의 (16,32)에서 8×16 글리프.
    const uv = uvFromAtlasRect(16, 32, 8, 16, 256, 128);
    try testing.expectApproxEqAbs(@as(f32, 16.0 / 256.0), uv[0], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 32.0 / 128.0), uv[1], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 24.0 / 256.0), uv[2], 1e-6);
    try testing.expectApproxEqAbs(@as(f32, 48.0 / 128.0), uv[3], 1e-6);

    // 좌상단 글리프는 0에서 시작한다.
    const first = uvFromAtlasRect(0, 0, 8, 16, 256, 128);
    try testing.expectEqual(@as(f32, 0), first[0]);
    try testing.expectEqual(@as(f32, 0), first[1]);

    // **0으로 나누지 않는다.** 아틀라스가 아직 없을 때(크기 0) 호출될 수 있다.
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &uvFromAtlasRect(0, 0, 8, 16, 0, 128));
    try testing.expectEqualSlices(f32, &.{ 0, 0, 0, 0 }, &uvFromAtlasRect(0, 0, 8, 16, 256, 0));
}
