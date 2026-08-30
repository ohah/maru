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
    ///
    /// **단, 단색 채움 셀(`solidCell`)에서는 알파가 그대로 투명도다.** 그 셀은 글리프가 없으므로
    /// "배경 없음" 이라는 뜻이 성립하지 않는다 — 셰이더가 `solid` 로 갈라 본다.
    bg: [4]f32,
    /// 모서리 반지름 px, `[좌상, 우상, 우하, 좌하]`. **단색 채움 셀에서만 읽는다.**
    ///
    /// **왜 필드를 늘렸나.** 편집기 스크롤바가 `radii = {4,4,4,4}` 로 온다(chrome `Op.quad`). 셀
    /// 격자 정렬은 문제가 아니었지만(`rect` 가 이미 임의 픽셀 사각이다) 둥근 모서리는 픽셀 셰이더가
    /// 계산해야 한다. 남는 필드에 얹지 않고 이름 있는 자리를 하나 만든다 — `uv`·`fg` 가 단색 셀에서
    /// 안 쓰인다고 거기 실으면 "이 값이 무엇인가" 가 셀 종류에 따라 갈려 곧 썩는다.
    shape: [4]f32 = .{ 0, 0, 0, 0 },
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Cell) == 80);
        std.debug.assert(@offsetOf(Cell, "rect") == 0);
        std.debug.assert(@offsetOf(Cell, "uv") == 16);
        std.debug.assert(@offsetOf(Cell, "fg") == 32);
        std.debug.assert(@offsetOf(Cell, "bg") == 48);
        std.debug.assert(@offsetOf(Cell, "shape") == 64);
    }
}

/// **글리프 없는 단색 사각** 하나. 행 띠·스크롤바·편집기 배경이 이것이다.
///
/// **쿼드 파이프라인이 따로 필요하지 않다.** `Cell.rect` 는 셀 격자가 아니라 **화면 픽셀 사각**이고
/// (위 필드 doc) 정점 셰이더가 `rect.xy + corner * rect.zw` 로 그대로 편다. 그래서 셀 폭과 무관한
/// 8px 스크롤바도 셀 하나로 그린다 — §2m.7 이 "쿼드가 필요한 것은 셀 격자에 안 맞는 것" 이라고 적었지만
/// 실제로 갈리는 기준은 **격자 정렬이 아니라 둥근 모서리·테두리·그라디언트**다(이 셰이더에 없는 것들).
///
/// `uv` 에 `solid_uv` 를 실어 아틀라스를 안 읽게 한다(픽셀 셰이더의 `solid` 분기).
/// 단색 채움 셀의 UV 표식. **음수여야 한다** — 글리프 UV 는 0..1 이라 겹칠 수 없다.
/// "UV 사각이 한 점" 으로 판정하려다 적대적 검증에서 걸렸다: **잉크 없는 글리프**는 아틀라스 슬롯이
/// 0x0 이라 `uvFromAtlasRect` 가 한 점을 낸다. 그러면 그 글리프 셀이 통째로 배경색으로 칠해진다.
pub const solid_uv: [4]f32 = .{ -1, -1, -1, -1 };

pub fn solidCell(x_px: f32, y_px: f32, w_px: f32, h_px: f32, rgba: [4]f32, corner_radii: [4]f32) Cell {
    return .{
        .rect = .{ x_px, y_px, w_px, h_px },
        .uv = solid_uv,
        .fg = .{ 0, 0, 0, 0 },
        .bg = rgba,
        .shape = corner_radii,
    };
}

test "단색 셀: 아틀라스를 안 읽는 모양이다" {
    const c = solidCell(3, 5, 8, 40, colorFromArgb(0xFF3A5FCD), .{ 4, 4, 4, 4 });
    // **음수 UV 여야 셰이더가 `solid` 로 판정한다.** 한 점 UV 로는 안 된다 — 잉크 없는 글리프가
    // 같은 모양을 내기 때문이다(그 상수의 doc).
    try testing.expect(c.uv[0] < 0);
    // 잉크 없는 글리프가 내는 모양(한 점, 음수 아님)과 **겹치지 않는다**.
    const zero_ink = uvFromAtlasRect(7, 11, 0, 0, 512, 512);
    try testing.expectEqual(zero_ink[0], zero_ink[2]);
    try testing.expect(zero_ink[0] >= 0);
    try testing.expect(c.uv[0] != zero_ink[0]);
    // **셀 격자와 무관한 크기가 그대로 실린다** — 8px 스크롤바가 9px 셀 격자에 안 맞아도 된다.
    try testing.expectEqual(@as(f32, 8), c.rect[2]);
    try testing.expectEqual(@as(f32, 40), c.rect[3]);
    try testing.expectEqual(@as(f32, 1), c.bg[3]);
    try testing.expectEqual(@as(f32, 4), c.shape[0]);
    // **반투명도 실린다** — 스크롤바가 alpha 102 로 온다.
    const t = solidCell(0, 0, 8, 8, colorFromArgb(0x663A5FCD), .{ 0, 0, 0, 0 });
    try testing.expect(t.bg[3] > 0.3 and t.bg[3] < 0.5);
}

/// GPU 로 올라가는 셀 배열의 **지문**. 같은 값이면 같은 그림이다 — `draw` 가 받는 것이 이 배열
/// 전부이므로, 지문이 같으면 화면이 같다는 것이 **정의상** 성립한다.
///
/// **왜 필요한가.** 스모크에는 픽셀 읽기 경로가 없어서 "고치기 전과 그림이 같은가" 를 눈으로만
/// 볼 수 있었다. 리팩터가 조용히 한 셀을 옮겨도 스크린샷 두 장을 나란히 놓고 사람이 알아채야 한다.
/// 지문이 있으면 그 판정이 **숫자 한 줄**이 된다.
///
/// `Cell` 은 `[4]f32` 넷뿐인 extern struct 라 패딩이 없다(위 `@sizeOf` 어설션이 못 박는다) —
/// 그래서 바이트를 그대로 해시해도 미정의 값이 안 섞인다.
pub fn cellsDigest(cells: []const Cell) u64 {
    return std.hash.Wyhash.hash(0, std.mem.sliceAsBytes(cells));
}

test "셀 지문: 한 값만 달라도 갈린다" {
    var a = [_]Cell{
        .{ .rect = .{ 0, 0, 8, 16 }, .uv = .{ 0, 0, 1, 1 }, .fg = .{ 1, 1, 1, 1 }, .bg = .{ 0, 0, 0, 1 } },
        .{ .rect = .{ 8, 0, 8, 16 }, .uv = .{ 0, 0, 1, 1 }, .fg = .{ 1, 1, 1, 1 }, .bg = .{ 0, 0, 0, 1 } },
    };
    var b = a;
    try std.testing.expectEqual(cellsDigest(&a), cellsDigest(&b));
    // 한 셀을 1px 옮긴다 — 눈으로는 못 보는 차이다.
    b[1].rect[0] = 9;
    try std.testing.expect(cellsDigest(&a) != cellsDigest(&b));
    // 순서만 바꿔도 갈린다. 그리는 순서가 겹침을 정하므로 같은 집합이어도 같은 그림이 아니다.
    var c = [_]Cell{ a[1], a[0] };
    try std.testing.expect(cellsDigest(&a) != cellsDigest(&c));
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
    \\    float4 shape: TEXCOORD4;
    \\    uint   vid  : SV_VertexID;
    \\};
    \\
    \\struct VSOut {
    \\    float4 pos : SV_Position;
    \\    float2 uv  : TEXCOORD0;
    \\    float4 fg  : TEXCOORD1;
    \\    float4 bg  : TEXCOORD2;
    \\    // **글리프가 없는 셀인가**(단색 채움). VS 에서 판정한다 — 픽셀 셰이더에는 보간된 한 점만
    \\    // 오므로 UV 사각이 한 점인지 거기서는 못 본다.
    \\    float  solid : TEXCOORD3;
    \\    // 둥근 모서리를 픽셀에서 재려면 사각을 알아야 한다: 중심(xy)과 반쪽 크기(zw), 화면 px.
    \\    float4 box   : TEXCOORD4;
    \\    float4 shape : TEXCOORD5;
    \\    float2 frag  : TEXCOORD6;
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
    \\    // **음수 UV 가 단색 채움의 신호다.** "UV 사각이 한 점" 으로 판정하려다 적대적 검증에서
    \\    // 걸렸다 — 잉크 없는 글리프는 아틀라스 슬롯이 0x0 이라 `uvFromAtlasRect` 가 한 점을 낸다
    \\    // (`renderer_glyph_zero_ink_count` 가 그런 글리프를 세고 있다). 글리프 UV 는 0..1 이라
    \\    // 음수를 낼 수 없으므로 이 신호는 절대 겹치지 않는다.
    \\    o.solid = (i.uv.x < 0.0) ? 1.0 : 0.0;
    \\    o.box = float4(i.rect.xy + i.rect.zw * 0.5, i.rect.zw * 0.5);
    \\    o.shape = i.shape;
    \\    o.frag = p;
    \\    return o;
    \\}
    \\
    \\float4 ps_main(VSOut i) : SV_Target {
    \\    // 커버리지는 알파에 있다 — RGB(흰색)는 쓰지 않는다. 색은 셀이 들고 온다.
    \\    //
    \\    // **단색 채움 셀이 먼저다.** 글리프가 없으므로 아틀라스를 안 읽는다 — 호출부가 주는
    \\    // uv = {0,0,0,0} 을 그대로 샘플하면 아틀라스 (0,0) 에 놓인 **첫 글리프**의 좌상단 픽셀
    \\    // 알파가 섞여 든다(`glyph_atlas` 의 next_x_px = 0). 지금까지 안 보인 것은 잉크가 그
    \\    // 모서리에 잘 안 닿기 때문이고 **계약이 아니라 운**이었다.
    \\    //
    \\    // **알파를 그대로 쓴다.** 아래 글리프 갈래는 `bg.a < 0.5` 를 "배경 없음" 으로 읽는데,
    \\    // 단색 채움에는 그 뜻이 없다 — 편집기 스크롤바가 alpha 102(40%)로 오고, 그 규칙을
    \\    // 태우면 **막대가 통째로 안 보인다**(실측으로 그렇게 될 뻔했다).
    \\    if (i.solid > 0.5) {
    \\        // 둥근 모서리: 사각 SDF 로 재고 1px 로 부드럽게 자른다. 반지름 0 이면 직사각형이다.
    \\        float2 q = abs(i.frag - i.box.xy) - i.box.zw;
    \\        float2 s = sign(i.frag - i.box.xy);
    \\        // 모서리별 반지름: [좌상, 우상, 우하, 좌하] 중 이 픽셀이 속한 사분면의 것.
    \\        float r = (s.y < 0.0) ? ((s.x < 0.0) ? i.shape.x : i.shape.y)
    \\                              : ((s.x < 0.0) ? i.shape.w : i.shape.z);
    \\        r = min(r, min(i.box.z, i.box.w));
    \\        float2 qr = q + r;
    \\        float dist = min(max(qr.x, qr.y), 0.0) + length(max(qr, 0.0)) - r;
    \\        float a = saturate(0.5 - dist);
    \\        return float4(i.bg.rgb, i.bg.a * a);
    \\    }
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
    .{ .semantic_name = "TEXCOORD", .semantic_index = 4, .format = d3d11.format_r32g32b32a32_float, .input_slot = 0, .aligned_byte_offset = 64, .input_slot_class = d3d11.input_per_instance_data, .instance_data_step_rate = 1 },
};

comptime {
    // **두 곳이 서로를 검증하게 한다.** `Cell`을 재배치하면 위 오프셋 단언이 잡지만, 여기 리터럴 오프셋만
    // 잘못 고치면 아무것도 안 잡고 런타임에 색과 좌표가 뒤섞인다(오류가 아니라 잘못된 그림이 나온다).
    // 필드 이름과 슬롯 순서를 여기서 묶어 둔다.
    const bound = [_][]const u8{ "rect", "uv", "fg", "bg", "shape" };
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

    /// 아틀라스를 **비워 둔 채로** 만든다. 실제 앱 경로(W7.2c-2)는 프레임마다 새 글리프만 부분 업로드하므로
    /// 처음부터 픽셀을 갖고 있지 않다 — `create`에 전체 픽셀을 요구하면 호출자가 CPU 사본을 계속 들어야 한다.
    pub fn createEmptyAtlas(
        allocator: std.mem.Allocator,
        device: *d3d11.ID3D11Device,
        context: *d3d11.ID3D11DeviceContext,
        atlas_w: u32,
        atlas_h: u32,
    ) Error!*CellPipeline {
        return createInner(allocator, device, context, atlas_w, atlas_h, null);
    }

    /// `atlas_pixels`는 **RGBA8**이고 길이가 `atlas_w * atlas_h * 4`여야 한다(커버리지는 알파).
    pub fn create(
        allocator: std.mem.Allocator,
        device: *d3d11.ID3D11Device,
        context: *d3d11.ID3D11DeviceContext,
        atlas_w: u32,
        atlas_h: u32,
        atlas_pixels: []const u8,
    ) Error!*CellPipeline {
        std.debug.assert(atlas_pixels.len == @as(usize, atlas_w) * atlas_h * 4);
        return createInner(allocator, device, context, atlas_w, atlas_h, atlas_pixels);
    }

    fn createInner(
        allocator: std.mem.Allocator,
        device: *d3d11.ID3D11Device,
        context: *d3d11.ID3D11DeviceContext,
        atlas_w: u32,
        atlas_h: u32,
        atlas_pixels: ?[]const u8,
    ) Error!*CellPipeline {
        if (builtin.os.tag != .windows) return error.UnsupportedPlatform;

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
            // 초기 픽셀이 없으면 **비워 둔 채로** 만든다 — 실제 앱 경로는 프레임마다 부분 업로드한다.
            if (atlas_pixels) |px| {
                const init = d3d11.SubresourceData{
                    .sys_mem = px.ptr,
                    // RGBA8이라 한 줄이 폭×4바이트다 — `glyph_pixels`의 `bytes_per_row`와 같은 값이어야 한다.
                    .sys_mem_pitch = atlas_w * 4,
                    .sys_mem_slice_pitch = 0,
                };
                try check(device.vtable.CreateTexture2D(device, &desc, &init, &atlas), error.CreateAtlasFailed);
            } else {
                try check(device.vtable.CreateTexture2D(device, &desc, null, &atlas), error.CreateAtlasFailed);
            }
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

    /// 아틀라스의 **한 사각형만** 갱신한다. 프레임마다 새 글리프 몇 개만 바뀌므로 전체를 다시 올리지 않는다.
    ///
    /// `pixels`는 RGBA8이고 `bytes_per_row` 간격이며, 그 사각형 크기만큼을 담아야 한다. 텍스처 밖을
    /// 가리키면 **그리지 않고 알린다** — `UpdateSubresource`는 범위를 검사하지 않아 넘치면 조용히 다른
    /// 자리를 덮는다(아틀라스에서는 그것이 "글자가 다른 글자로 나온다"로 보인다).
    pub fn uploadAtlasRegion(
        self: *CellPipeline,
        x_px: u32,
        y_px: u32,
        w_px: u32,
        h_px: u32,
        pixels: []const u8,
        bytes_per_row: usize,
    ) Error!void {
        if (w_px == 0 or h_px == 0) return;
        if (x_px + w_px > self.atlas_w or y_px + h_px > self.atlas_h) return error.CreateAtlasFailed;
        if (bytes_per_row < @as(usize, w_px) * 4) return error.CreateAtlasFailed;
        if (pixels.len < bytes_per_row * (h_px - 1) + @as(usize, w_px) * 4) return error.CreateAtlasFailed;

        const box = d3d11.Box{ .left = x_px, .top = y_px, .right = x_px + w_px, .bottom = y_px + h_px };
        self.context.vtable.UpdateSubresource(
            self.context,
            @ptrCast(self.atlas),
            0,
            &box,
            pixels.ptr,
            @intCast(bytes_per_row),
            0,
        );
    }

    /// 아틀라스가 커졌을 때 텍스처를 **다시 만든다**(빈 상태로).
    ///
    /// 이전 글리프가 사라지는 것이 맞다 — 중립 아틀라스가 텍스처를 키울 때는 `atlas_full`로 **전체를
    /// 무효화하고 (0,0)부터 재배치**하므로(`renderer/glyph_atlas.zig`), 그 프레임의 글리프가 전부 새
    /// 업로드로 다시 온다. 즉 오래된 UV가 남아 엉뚱한 픽셀을 샘플하는 일이 없다.
    ///
    /// **이 경로는 아직 실측으로 밟아 보지 못했다** — 1024×1024를 채울 만큼 고유 글리프가 나오는 상황을
    /// 스모크로 만들지 못했다(계약 §2g "한계").
    pub fn resizeAtlas(self: *CellPipeline, atlas_w: u32, atlas_h: u32) Error!void {
        if (atlas_w == self.atlas_w and atlas_h == self.atlas_h) return;
        if (atlas_w == 0 or atlas_h == 0) return error.CreateAtlasFailed;

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
        var tex: ?*d3d11.ID3D11Texture2D = null;
        try check(self.device.vtable.CreateTexture2D(self.device, &desc, null, &tex), error.CreateAtlasFailed);
        errdefer d3d11.releaseOpt(tex);

        var srv: ?*d3d11.ID3D11ShaderResourceView = null;
        try check(self.device.vtable.CreateShaderResourceView(self.device, @ptrCast(tex.?), null, &srv), error.CreateAtlasFailed);

        // **새 것이 다 서고 나서** 옛 것을 놓는다 — 중간에 실패해도 파이프라인이 유효한 아틀라스를 갖는다.
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.atlas_srv)));
        d3d11.releaseOpt(@as(?*anyopaque, @ptrCast(self.atlas)));
        self.atlas = tex.?;
        self.atlas_srv = srv.?;
        self.atlas_w = atlas_w;
        self.atlas_h = atlas_h;
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

/// **헤더 아래로 잘라 낸다** — 목록 셀이 헤더 위로 삐져나온 부분을 버린다(픽셀 단위).
///
/// 헤더를 맨 나중에 그리는 것만으로는 안 덮인다: 글리프 셀은 배경이 투명해서 **글자끼리 포개진다**
/// (실측 캡처: 굴린 사이드바에서 `session 3` 이 `Search` 위에 겹쳐 보였다). macOS 렌더러는 같은
/// 자리를 `[header_h, drawable_h]` scissor 로 자르는데, Windows 셀에는 clip 필드가 없다 — 그래서
/// **낼 때 자른다**.
///
/// 반쯤 걸친 셀은 **지우지 않고 자른다**: 위 절반이 사라지고 아래 절반이 남는다. UV 도 같은 비율로
/// 밀어야 글자가 늘어나 보이지 않는다(`v0` 를 자른 만큼 내린다).
/// **위아래로 잘라 낸다** — `clipCellTop` 의 짝이고 규칙은 같다(반쯤 걸치면 자르고 UV 를 같은 비율로
/// 민다, 통째로 밖이면 버린다).
///
/// 도크 트리가 이것을 쓴다: 그 목록은 위로는 **뷰 바**, 아래로는 **상태바** 자리로 새고 있었다
/// (실측 2026-08-30: 트리 y 가 76 인데 글자가 62 까지 올라갔다 — 위 153 셀·아래 16 셀).
pub fn clipCellVertical(c: Cell, min_y: f32, max_y: f32) ?Cell {
    const top = clipCellTop(c, min_y) orelse return null;
    const h = top.rect[3];
    if (h <= 0) return null;
    const bottom = top.rect[1] + h;
    if (bottom <= max_y) return top;
    if (top.rect[1] >= max_y) return null; // 통째로 아래 — 버린다
    const dy = bottom - max_y;
    var out = top;
    out.rect[3] = h - dy;
    // 아래를 자를 때는 `v1` 을 같은 비율만큼 올린다(위를 자를 때 `v0` 를 내리는 것의 짝).
    const v0 = top.uv[1];
    const v1 = top.uv[3];
    out.uv[3] = v1 - (v1 - v0) * (dy / h);
    return out;
}

test "clipCellVertical: 아래를 자르면 v1 이 같은 비율로 올라간다" {
    const c: Cell = .{
        .rect = .{ 10, 100, 8, 20 },
        .uv = .{ 0.0, 0.0, 1.0, 1.0 },
        .fg = .{ 1, 1, 1, 1 },
        .bg = .{ 0, 0, 0, 0 },
    };
    // 온전히 안 — 그대로.
    try std.testing.expect(clipCellVertical(c, 90, 130).?.rect[3] == 20);
    // 아래 5px 을 깎는다 — 높이 15, `v1` 은 0.75.
    const cut = clipCellVertical(c, 90, 115).?;
    try std.testing.expectEqual(@as(f32, 100), cut.rect[1]);
    try std.testing.expectEqual(@as(f32, 15), cut.rect[3]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), cut.uv[3], 0.0001);
    try std.testing.expectEqual(@as(f32, 0.0), cut.uv[1]);
    // 위아래를 함께 — 105..115 만 남는다(높이 10, v 는 0.25~0.75).
    const both = clipCellVertical(c, 105, 115).?;
    try std.testing.expectEqual(@as(f32, 10), both.rect[3]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), both.uv[1], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 0.75), both.uv[3], 0.0001);
    // 통째로 밖이면 버린다.
    try std.testing.expect(clipCellVertical(c, 121, 200) == null);
    try std.testing.expect(clipCellVertical(c, 0, 100) == null);
}

pub fn clipCellTop(c: Cell, min_y: f32) ?Cell {
    const y = c.rect[1];
    const h = c.rect[3];
    if (y >= min_y) return c; // 온전히 아래 — 그대로
    if (h <= 0 or y + h <= min_y) return null; // 통째로 헤더 위 — 버린다
    const dy = min_y - y;
    var out = c;
    out.rect[1] = min_y;
    out.rect[3] = h - dy;
    // 아틀라스 UV 는 세로로 선형이다 — 자른 비율만큼 `v0` 를 내린다.
    const v0 = c.uv[1];
    const v1 = c.uv[3];
    out.uv[1] = v0 + (v1 - v0) * (dy / h);
    return out;
}

test "clipCellTop: 위를 자르면 UV 도 같은 비율로 내려간다" {
    // 자른 만큼 `v0` 를 안 내리면 같은 글리프가 **줄어든 높이에 통째로** 그려져 세로로 눌린다 —
    // 개수·자리 판정으로는 안 보이는 성질이라 여기서 값으로 고정한다.
    const c: Cell = .{
        .rect = .{ 10, 100, 8, 20 },
        .uv = .{ 0.0, 0.0, 1.0, 1.0 },
        .fg = .{ 1, 1, 1, 1 },
        .bg = .{ 0, 0, 0, 0 },
    };
    // 온전히 아래 — 그대로 돌려준다.
    try std.testing.expect(clipCellTop(c, 100).?.rect[1] == 100);
    try std.testing.expect(clipCellTop(c, 90).?.uv[1] == 0.0);
    // 반쯤 걸쳤다 — 위 5px 을 깎고 UV 는 1/4 만큼 내린다.
    const cut = clipCellTop(c, 105).?;
    try std.testing.expectEqual(@as(f32, 105), cut.rect[1]);
    try std.testing.expectEqual(@as(f32, 15), cut.rect[3]);
    try std.testing.expectApproxEqAbs(@as(f32, 0.25), cut.uv[1], 0.0001);
    try std.testing.expectEqual(@as(f32, 1.0), cut.uv[3]); // 아래 끝은 그대로
    // 통째로 위 — 버린다.
    try std.testing.expect(clipCellTop(c, 121) == null);
    try std.testing.expect(clipCellTop(c, 120) == null);
    // 높이 0 은 버린다(0 으로 나누지 않는다).
    const zero: Cell = .{ .rect = .{ 0, 0, 0, 0 }, .uv = .{ 0, 0, 1, 1 }, .fg = .{ 1, 1, 1, 1 }, .bg = .{ 0, 0, 0, 0 } };
    try std.testing.expect(clipCellTop(zero, 1) == null);
}

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
