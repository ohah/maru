//! Session Dock measured chrome text adapter.
//!
//! CoreText owns CTLine/CTRun and returns only scalar glyph facts.  This module owns the
//! conversion to renderer-neutral records plus final local pixel positions; it deliberately
//! does not know about AppSession, Metal DTOs, or terminal `ResolvedAppearance`.
//!
//! face는 이 모듈이 고르지 않고 `Face`로 **받는다**(빈 값이면 system UI face). 그래서 도크가 사용자
//! `font.family`를 따라가면서도 이 파일은 config 타입을 여전히 모른다 — 채우는 쪽은 platform
//! (`app_session`)이다. 근거와 폴백 규칙은 docs/font-strategy.md "Chrome 텍스트 face"가 단일 출처다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");
const chrome = maru.chrome;
const icons = maru.icons; // 등록 chrome 아이콘 이름↔PUA codepoint(생성물)
const renderer = maru.renderer;
const colorUv = renderer.metal_frame.colorUv; // 컬러 글리프 UV sentinel 단일 출처(u0·u1 동일 규약)
const bridge = @import("../coretext_smoke_bridge.zig");
const probe = @import("../coretext_probe.zig");
const metal_frame = renderer.metal_frame;
const width = maru.width; // Unicode 셀 폭(EAW) — 한글/CJK/이모지=2칸
const display_width = maru.display_width; // §4.2 표시 폭 — 열을 세는 쪽(content.zig)과 같은 규칙

/// **x 스냅은 두지 않는다**(2026-08-09 실측으로 기각). `x_px`를 셀 배수로 반올림하는 방식은
/// 글자마다 advance가 다를 때(한글 2칸, fallback 폰트) 여러 글자가 같은 칸으로 몰려 문자열이
/// 겹쳐 그려진다 — 실제로 그렇게 깨진 캡처를 확인했다. 올바른 스냅은 x 반올림이 아니라 **셀
/// 인덱스 기반**이어야 하고(각 글자가 몇 번째 칸인지 `text_layout`의 cluster 폭으로 세어야 한다),
/// 그것은 이 모듈이 아니라 그 분절을 아는 쪽의 일이다.
///
/// 폰트 크기를 셀에서 파생하면(`cell_line_height_ratio`) advance가 셀 폭에 충분히 가까워져
/// 실용적으로 정렬이 유지된다는 것을 캡처로 확인했다.
pub const Placement = struct {
    x_px: f32,
    y_px: f32,
    advance_px: f32,
    line_height_px: f32,
    foreground: u32,
    /// 스크롤 목록 소속이면 true. 캐시된 아티팩트를 다른 스크롤 위치에서 다시 쓸 때 backend가 이
    /// placement에만 y delta를 더한다 — 고정 chrome은 스크롤해도 제자리이므로 건드리면 안 된다.
    scroll_clipped: bool = false,
    /// 스크롤 콘텐츠 **위에 뜬** 텍스트(상단 고정 헤더)의 clip 사각형. non-null이면 스크롤 평행이동을
    /// 받지 않으면서 이 rect로 잘린다 — `scroll_clipped`가 뷰포트로 자르되 delta를 더하는 것과 대비된다.
    above_clip: ?chrome.draw.Rect = null,
};

/// An owned, renderer-free description of the semantic text that CoreText must shape.  It can
/// cross to the detached worker because it contains no draw-list borrow, native handle, atlas
/// state, or FontIdentityRegistry reference.
pub const Request = struct {
    fingerprint: u64,
    runs: []Run,
    /// 이 요청 전체가 쓸 face. run이 아니라 요청 단위인 이유는 한 프레임의 모든 chrome 텍스트가 같은
    /// 폰트를 쓰기 때문이다 — run마다 들면 같은 문자열이 run 수만큼 복사될 뿐이고, 브리지의 face 캐시도
    /// run마다 키를 다시 만들게 된다. 빈 슬라이스면 system UI face(레거시 경로).
    /// 소유권은 `Request`에 있다(worker 이송 가능성을 유지하려면 borrow가 아니어야 한다).
    font_family: []u8 = &.{},
    /// 터미널과 같은 `font.fallback` CSV. 이걸 함께 넘기지 않으면 주 폰트에 없는 글리프(한글·이모지)가
    /// 사이드바와 다른 폰트로 떨어져 face를 맞춘 의미가 사라진다.
    font_fallback: []u8 = &.{},

    pub const Run = struct {
        text: []u8,
        role: chrome.ui.typography.ChromeTextRole,
        origin: chrome.draw.Px,
        max_width_px: u32,
        foreground: u32,
        /// 넘칠 때 어느 쪽을 자르는가. 입력 줄은 `.tail`이어야 caret과 방금 친 글자가 남는다 —
        /// 셀 경로가 `overlay_input.inputLineView`(tail 창)로 풀던 규칙을 CoreText truncation이 대신한다.
        anchor: chrome.text_layout.Anchor = .head,
        placement: chrome.draw.TextPlacement = .origin,
        scroll_clipped: bool = false,
        above_clip: ?chrome.draw.Rect = null,
        /// 편집기 폰트 크기(device px, §2.0). null이면 기존 토큰 폰트 크기 그대로다.
        font_px: ?u16 = null,
        /// 편집기 줄 높이(device px, §2.0). `font_px`와 짝이다.
        line_height_px: ?u16 = null,
        /// 편집기 셀 폭(device px, §2.0). 글자 x를 **셀 인덱스**로 놓을 때 쓴다.
        cell_w_px: ?u16 = null,
        /// 같은 op 의 앞 run 에 **이어서** 놓는가(`chrome.draw.Run` 계약). 컴포넌트는 비례 폰트의
        /// advance 를 모르므로 한 줄 안에서 색이 바뀌는 구간을 스스로 이어 붙일 수 없다 — 셀 격자로
        /// 추정해 op 을 나누면 구간 사이가 눈에 띄게 벌어진다. 그 이음은 **측정값을 가진 이쪽**이 한다.
        continues_previous: bool = false,
    };

    pub fn deinit(self: *Request, allocator: std.mem.Allocator) void {
        for (self.runs) |run| allocator.free(run.text);
        allocator.free(self.runs);
        allocator.free(self.font_family);
        allocator.free(self.font_fallback);
        self.* = undefined;
    }
};

/// Scalar CoreText result which deliberately keeps the selected PostScript name as bytes rather
/// than a renderer FontId.  The worker may create this, but the main actor alone resolves it into
/// renderer registry state.
pub const UnresolvedGlyph = struct {
    glyph_id: u32,
    codepoint: u32,
    fallback: bool,
    color_glyph_kind: renderer.ColorGlyphKind,
    x_px: f32,
    advance_px: f32,
    /// ink 가 자기 자리 왼쪽으로 넘치는 px(합자만 양수). `resolve` 가 래스터 슬롯을 넓히고 x 를 당긴다.
    left_overhang_px: f32 = 0,
    font_name: [128]u8,
    point_size: u16,
    line_height_px: f32,
    origin: chrome.draw.Px,
    foreground: u32,
    run_index: u16,
};

pub const UnresolvedArtifact = struct {
    glyphs: []UnresolvedGlyph,
    placements: []chrome.draw.TextPlacement,
    foregrounds: []u32,
    scroll_flags: []bool,
    above_clips: []?chrome.draw.Rect,
    /// run별 셀 폭(device px, §2.0). 최종 x를 셀 인덱스로 놓을 때 쓴다.
    ///
    /// `font_px`·`line_height_px`는 여기 두지 않는다 — 둘은 `shapeUnresolvedRun`이 `Run`에서 직접
    /// 읽어 shaping 시점에 소비하므로, 결과 구조에 다시 실으면 아무도 읽지 않는 필드가 된다.
    cell_widths: []?u16,
    /// run 별 "앞 run 에 이어 붙임" 표시. resolve 가 이 표시를 따라 앞 run 들의 실측 advance 를 누적해
    /// x 를 민다 — 그래야 한 줄 안에서 색만 바뀌는 구간들이 한 문장처럼 붙어 보인다.
    continues: []bool,
    /// run 별 폭 한도(op 예산). **이어 붙이는 run 에는 이 한도가 개별로 걸려 있어 합계가 예산을 넘을 수
    /// 있다** — CoreText truncation 은 run 하나만 보기 때문이다. resolve 가 누적 x 로 그 경계를 다시
    /// 재서 넘는 글리프를 버린다(실측 캡처에서 모델명이 chevron 을 지나 카드 밖까지 뻗었다).
    max_widths: []u32,

    pub fn deinit(self: *UnresolvedArtifact, allocator: std.mem.Allocator) void {
        allocator.free(self.glyphs);
        allocator.free(self.placements);
        allocator.free(self.foregrounds);
        allocator.free(self.scroll_flags);
        allocator.free(self.above_clips);
        allocator.free(self.cell_widths);
        allocator.free(self.continues);
        allocator.free(self.max_widths);
        self.* = undefined;
    }
};

pub const Artifact = struct {
    records: []renderer.ShapedGlyphRecord,
    placements: []Placement,

    pub fn deinit(self: *Artifact, allocator: std.mem.Allocator) void {
        allocator.free(self.records);
        allocator.free(self.placements);
        self.* = undefined;
    }

    /// `clip`이 있으면 각 glyph quad를 그 backing-pixel 사각형과 교차시켜 **부분적으로** 남긴다.
    /// glyph는 atlas texture를 입힌 사각형이므로 잘린 비율만큼 UV를 같이 줄이면 결과가 픽셀 정확하다.
    /// 그래서 component가 "이 줄이 clip 안에 통째로 들어가는가"를 미리 판정할 필요가 없다 — 반쯤
    /// 걸친 카드/그룹의 글자도 잘린 그대로 보인다.
    pub fn appendGpuGlyphs(
        self: Artifact,
        allocator: std.mem.Allocator,
        frame: renderer.RenderFrame,
        atlas: renderer.GlyphAtlasConfig,
        origin_x_px: u32,
        origin_y_px: u32,
        clip: ?metal_frame.ClipPx,
        /// 아티팩트가 셰이핑된 시점의 스크롤 위치와 이번 프레임의 스크롤 위치 차이(px). 스크롤은 순수
        /// 평행이동이므로 이 값만 더하면 같은 셰이핑 결과를 다른 스크롤 위치에 정확히 놓을 수 있다.
        scroll_delta_y_px: f32,
        out: *std.ArrayList(metal_frame.GpuGlyph),
    ) !void {
        const texture = renderer.AtlasTextureSize{ .width_px = atlas.atlas_width_px, .height_px = atlas.atlas_height_px };
        for (frame.glyph_quad_frame.glyphs) |glyph| {
            // Atlas placement may reorder/repack glyph runs.  The synthetic row/column pair is
            // the immutable record identity created in shapeOps; positional zip here would put
            // a later label at an earlier label's pixel origin and visibly stack the dock header.
            const placement_index = @as(usize, glyph.run.row) * 256 + glyph.run.col;
            if (placement_index >= self.placements.len) return error.MeasuredGlyphPlacementMissing;
            const placement = self.placements[placement_index];
            const uv = try renderer.glyph_quads.uvRectForSlot(glyph.slot, texture);
            const scrolled_y = placement.y_px + if (placement.scroll_clipped) scroll_delta_y_px else 0;
            // 뷰포트로 자르는 것은 스크롤 목록뿐이다. 고정 chrome은 그 사각형 밖(위)에 있으므로 같은
            // clip을 적용하면 헤더·scope·검색이 통째로 사라진다.
            // 떠 있는 헤더는 자기 rect로 자른다 — 스크롤 뷰포트로 자르면 밀려 나가는 동안 살아남아
            // 고정 chrome 위로 새고, 안 자르면 그대로 검색창을 덮는다.
            // `clip == null`은 "이 pass는 자르지 않는다"이므로 떠 있는 헤더도 자르지 않는다. Lab 스모크가
            // placement→GPU 좌표 대응을 볼 때 이 pass를 쓴다 — 여기서 헤더만 잘리면 그 대조가 깨진다.
            const glyph_clip = glyphClipFor(placement, clip, origin_x_px, origin_y_px);
            const quad = clipGlyphQuad(.{
                .x = @as(f32, @floatFromInt(origin_x_px)) + placement.x_px,
                .y = @as(f32, @floatFromInt(origin_y_px)) + scrolled_y,
                .w = @floatFromInt(glyph.slot.width_px),
                .h = @floatFromInt(glyph.slot.height_px),
                .atlas_x_px = glyph.slot.x_px,
                .atlas_y_px = glyph.slot.y_px,
                .atlas_width_px = glyph.slot.width_px,
                .atlas_height_px = glyph.slot.height_px,
            }, glyph_clip) orelse continue;
            try out.append(allocator, .{
                .x = quad.x,
                .y = quad.y,
                .w = quad.w,
                .h = quad.h,
                .atlas_x_px = quad.atlas_x_px,
                .atlas_y_px = quad.atlas_y_px,
                .atlas_width_px = quad.atlas_width_px,
                .atlas_height_px = quad.atlas_height_px,
                // 컬러 글리프는 **u0과 u1 둘 다** sentinel(+2.0)을 싣는다(`metal_frame.colorUv`와 같은 규약).
                // 예전에는 u0에만 실었는데, 셰이더가 `uv.x >= 2.0`으로 컬러 분기를 판정하므로 정점 보간에서
                // u가 2.33 → 0.35로 떨어져 **왼쪽 극히 일부만 컬러로 샘플되고 나머지는 일반 분기로 빠졌다**
                // — 이모지가 몇 픽셀 폭 세로 조각으로 그려졌다(Chrome Lab 캡처). 제품은
                // `renormalizeGpuGlyphUvs`가 u1까지 다시 만들어 가려졌고, 그 단계를 안 거치는 Lab에서만
                // 드러났다. 재정규화는 slot에서 UV를 새로 굽고 offset을 다시 더하므로 중복 가산되지 않는다.
                .u0 = colorUv(uv.u0, glyph.run.cache_key.color_glyph_kind),
                .v0 = uv.v0,
                .u1 = colorUv(uv.u1, glyph.run.cache_key.color_glyph_kind),
                .v1 = uv.v1,
                .foreground = placement.foreground,
                .layer = 0,
            });
        }
    }
};

/// glyph quad와 그 atlas 슬롯을 함께 자른 결과. **UV는 여기서 계산하지 않는다** — `MetalFrameBuffer.replace`
/// 가 매 프레임 `renormalizeGpuGlyphUvs`로 `atlas_*_px` 슬롯에서 UV를 다시 만들기 때문이다(atlas는 프레임
/// 중간에 다른 pane 때문에 커질 수 있어 슬롯이 권위이고 UV는 파생값이다). 여기서 UV를 좁혀 봐야 그 재계산이
/// 통째로 덮어써 기하만 줄고 텍스처는 원본이 남으므로, 부분적으로 보이는 행이 잘리는 대신 **찌그러진다**.
const ClippedGlyph = struct {
    x: f32,
    y: f32,
    w: f32,
    h: f32,
    atlas_x_px: u32,
    atlas_y_px: u32,
    atlas_width_px: u32,
    atlas_height_px: u32,
};

/// glyph quad ∩ clip. 기하를 자르면서 대응하는 atlas 슬롯 영역도 같은 비율로 좁힌다. 슬롯은 정수 픽셀이라
/// 부분 클립에서 1px 미만의 반올림 오차가 남는다(후속 GPU scissor 이관에서 자르기 자체가 없어지면 사라진다).
fn clipGlyphQuad(quad: ClippedGlyph, clip: ?metal_frame.ClipPx) ?ClippedGlyph {
    const rect = clip orelse return quad;
    if (rect.w == 0 or rect.h == 0) return null;
    if (quad.w <= 0 or quad.h <= 0) return null;
    const clip_left: f32 = @floatFromInt(rect.x);
    const clip_top: f32 = @floatFromInt(rect.y);
    const clip_right = clip_left + @as(f32, @floatFromInt(rect.w));
    const clip_bottom = clip_top + @as(f32, @floatFromInt(rect.h));
    const left = @max(quad.x, clip_left);
    const top = @max(quad.y, clip_top);
    const right = @min(quad.x + quad.w, clip_right);
    const bottom = @min(quad.y + quad.h, clip_bottom);
    if (right <= left or bottom <= top) return null;
    const slot_w: f32 = @floatFromInt(quad.atlas_width_px);
    const slot_h: f32 = @floatFromInt(quad.atlas_height_px);
    // glyph의 픽셀 origin은 fractional이라 두 반올림(잘라낸 양·남은 양)이 각각 올라갈 수 있다. 그대로 두면
    // `cut + kept`가 슬롯을 한 텍셀 넘겨 **이웃 glyph의 텍셀**을 읽는다. 남은 폭/높이는 최소 1을 보장하되
    // 잘라낸 양을 먼저 슬롯 안으로 가둔 뒤 그 나머지로 클램프한다.
    const cut_x = @min(@as(u32, @intFromFloat(@round((left - quad.x) / quad.w * slot_w))), quad.atlas_width_px -| 1);
    const cut_y = @min(@as(u32, @intFromFloat(@round((top - quad.y) / quad.h * slot_h))), quad.atlas_height_px -| 1);
    const kept_w = @max(@as(u32, @intFromFloat(@round((right - left) / quad.w * slot_w))), 1);
    const kept_h = @max(@as(u32, @intFromFloat(@round((bottom - top) / quad.h * slot_h))), 1);
    return .{
        .x = left,
        .y = top,
        .w = right - left,
        .h = bottom - top,
        .atlas_x_px = quad.atlas_x_px + cut_x,
        .atlas_y_px = quad.atlas_y_px + cut_y,
        .atlas_width_px = @min(kept_w, quad.atlas_width_px - cut_x),
        .atlas_height_px = @min(kept_h, quad.atlas_height_px - cut_y),
    };
}

// 코드리뷰 회귀: 이전 구현은 clip한 만큼 UV를 좁혔는데, `MetalFrameBuffer.replace`가 매 프레임
// `renormalizeGpuGlyphUvs`로 `atlas_*_px` 슬롯에서 UV를 다시 만들어 그 값을 통째로 덮어썼다. 기하만 줄고
// 텍스처는 원본이 남아, 부분적으로 보이는 행이 **잘리는 대신 찌그러졌다**. clipGlyphQuad만 단언하는
// 테스트는 이 결함을 못 잡는다 — 파이프라인의 그 다음 단계가 결과를 무효화하기 때문이다. 그래서 여기서는
// 렌더러가 실제로 쓰는 재정규화 함수를 그대로 통과시킨 뒤의 UV가 남은 기하와 맞는지 본다.
test "clipped glyph keeps matching UVs after the renderer renormalizes from the atlas slot" {
    const tex = renderer.AtlasTextureSize{ .width_px = 512, .height_px = 512 };
    const full = ClippedGlyph{ .x = 100, .y = 200, .w = 10, .h = 20, .atlas_x_px = 64, .atlas_y_px = 128, .atlas_width_px = 10, .atlas_height_px = 20 };
    // 위 절반이 잘린 glyph. 남은 기하는 아래 절반이므로 텍스처도 아래 절반이어야 한다.
    const clipped = clipGlyphQuad(full, .{ .x = 0, .y = 210, .w = 1000, .h = 1000 }) orelse return error.TestUnexpectedResult;
    const uv = try renderer.glyph_quads.uvRectForPx(clipped.atlas_x_px, clipped.atlas_y_px, clipped.atlas_width_px, clipped.atlas_height_px, tex);
    const full_uv = try renderer.glyph_quads.uvRectForPx(full.atlas_x_px, full.atlas_y_px, full.atlas_width_px, full.atlas_height_px, tex);
    // v0가 원본과 최종 v1의 정확히 중간으로 내려가야 아래 절반이다. 재정규화가 원본 슬롯을 그대로 쓰면
    // v0는 full_uv.v0에 머물고(= 이번 회귀), 그러면 전체 glyph가 절반 높이에 눌려 그려진다.
    try std.testing.expectApproxEqAbs((full_uv.v0 + full_uv.v1) / 2, uv.v0, 0.0001);
    try std.testing.expectApproxEqAbs(full_uv.v1, uv.v1, 0.0001);
    try std.testing.expectApproxEqAbs(full_uv.u0, uv.u0, 0.0001);
    try std.testing.expectApproxEqAbs(full_uv.u1, uv.u1, 0.0001);
    // 텍스처가 차지하는 세로 비율과 기하가 차지하는 세로 비율이 같아야 찌그러지지 않는다.
    const uv_ratio = (uv.v1 - uv.v0) / (full_uv.v1 - full_uv.v0);
    const geom_ratio = clipped.h / full.h;
    try std.testing.expectApproxEqAbs(geom_ratio, uv_ratio, 0.0001);
}

test "clipGlyphQuad trims the atlas slot with the geometry so UV renormalization stays correct" {
    const full = ClippedGlyph{ .x = 100, .y = 200, .w = 10, .h = 20, .atlas_x_px = 64, .atlas_y_px = 128, .atlas_width_px = 10, .atlas_height_px = 20 };
    // clip 없음 = 원본 그대로.
    try std.testing.expectEqual(full.atlas_height_px, (clipGlyphQuad(full, null) orelse return error.TestUnexpectedResult).atlas_height_px);
    // 위쪽 절반이 잘리면 슬롯의 위쪽 절반도 함께 잘린다 — 그래야 renormalize가 만든 UV가 남은 기하와 맞는다.
    const half = clipGlyphQuad(full, .{ .x = 0, .y = 210, .w = 1000, .h = 1000 }) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(@as(f32, 210), half.y);
    try std.testing.expectEqual(@as(f32, 10), half.h);
    try std.testing.expectEqual(@as(u32, 138), half.atlas_y_px);
    try std.testing.expectEqual(@as(u32, 10), half.atlas_height_px);
    try std.testing.expectEqual(full.atlas_x_px, half.atlas_x_px);
    try std.testing.expectEqual(full.atlas_width_px, half.atlas_width_px);
    // 완전히 밖이면 방출하지 않는다.
    try std.testing.expect(clipGlyphQuad(full, .{ .x = 0, .y = 0, .w = 10, .h = 10 }) == null);
    // 잘린 슬롯이 원본을 넘지 않는다(반올림이 밖으로 새면 다른 glyph의 텍셀을 읽는다). glyph origin은
    // fractional이라 "잘라낸 양"과 "남은 양"의 반올림이 **둘 다** 올라갈 수 있다 — 정수 origin만 보는
    // 단언은 이 침범을 놓친다. 적대적 검증에서 나온 실제 케이스라 sub-pixel origin을 훑는다.
    var offset: f32 = 0;
    while (offset < 1.0) : (offset += 0.1) {
        var fractional = full;
        fractional.y = 200 + offset;
        var clip_top: u32 = 200;
        while (clip_top <= 221) : (clip_top += 1) {
            const cut = clipGlyphQuad(fractional, .{ .x = 0, .y = clip_top, .w = 1000, .h = 1000 }) orelse continue;
            try std.testing.expect(cut.atlas_y_px >= full.atlas_y_px);
            try std.testing.expect(cut.atlas_y_px + cut.atlas_height_px <= full.atlas_y_px + full.atlas_height_px);
            try std.testing.expect(cut.atlas_x_px + cut.atlas_width_px <= full.atlas_x_px + full.atlas_width_px);
            try std.testing.expect(cut.atlas_height_px >= 1);
        }
    }
}

/// Shapes every non-icon Session Dock text op into one immutable artifact. Registered SVG icon
/// ops stay on the legacy synthesized-glyph path until their vector texture migration lands;
/// treating their PUA values as system UI text would silently erase affordances.
pub fn shapeOps(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    face: Face,
    scale_milli: u32,
) !Artifact {
    var request = try prepareRequest(allocator, 0, ops, tk, cell_width_px, face);
    defer request.deinit(allocator);
    var unresolved = try shapeRequest(allocator, &request, scale_milli);
    defer unresolved.deinit(allocator);
    return resolveArtifact(allocator, registry, unresolved);
}

/// 이 text op이 measured 셰이핑 대상인지. **셰이핑 키(`richTextFingerprint`)와 request가 반드시 같은
/// 답을 써야 한다.** 두 필터가 갈라지면 "키는 같은데 artifact에는 그 run이 없는" 상태가 만들어지고,
/// 키가 스크롤 평행이동에 불변이므로 그 artifact가 그 줄이 보여야 할 위치에서 재사용되어 줄이 영구히 빈 채로
/// 남는다(음수 origin 드롭이 실제로 그 결함을 냈다). 그래서 판정을 여기 한 곳에 둔다.
/// glyph 하나를 자를 사각형. 세 갈래가 한 자리에 있어야 어느 것이 이기는지 헷갈리지 않는다.
///
/// - `viewport == null`: 이 pass는 자르지 않는다(Lab의 placement 대조용 무클립 pass).
/// - 떠 있는 헤더: **자기 clip**으로 자른다. 이 rect는 컴포넌트 좌표라 glyph 위치와 **같은 pane 원점**을
///   더해야 한다 — 안 더하면 도크가 화면 오른쪽에 있을 때 clip이 왼쪽 끝에 남아 헤더 글자가 통째로
///   사라진다. Lab은 원점이 (0,0)이라 이 결함을 못 본다(제품 스모크 캡처로 발견).
/// - 스크롤 목록: 뷰포트로 자른다. 고정 chrome은 그 사각형 밖(위)이라 자르지 않는다.
fn glyphClipFor(
    placement: Placement,
    viewport: ?metal_frame.ClipPx,
    origin_x_px: u32,
    origin_y_px: u32,
) ?metal_frame.ClipPx {
    if (viewport == null) return null;
    if (placement.above_clip) |above| return .{
        .x = @intCast(@max(@as(i64, origin_x_px) + above.x, 0)),
        .y = @intCast(@max(@as(i64, origin_y_px) + above.y, 0)),
        .w = above.w,
        .h = above.h,
    };
    return if (placement.scroll_clipped) viewport else null;
}

test "a floating head clips to its own rect moved by the pane origin, not the scroll viewport" {
    const viewport = metal_frame.ClipPx{ .x = 1290, .y = 300, .w = 600, .h = 400 };
    const head = Placement{
        .x_px = 0,
        .y_px = 0,
        .advance_px = 10,
        .line_height_px = 20,
        .foreground = 0,
        .above_clip = .{ .x = 20, .y = 10, .w = 100, .h = 30 },
    };

    // pane 원점을 더하지 않으면 도크가 오른쪽에 있을 때 clip이 화면 왼쪽에 남아 헤더가 사라진다.
    const clipped = glyphClipFor(head, viewport, 1290, 40).?;
    try std.testing.expectEqual(@as(u32, 1310), clipped.x);
    try std.testing.expectEqual(@as(u32, 50), clipped.y);
    try std.testing.expectEqual(@as(u32, 100), clipped.w);
    try std.testing.expectEqual(@as(u32, 30), clipped.h);

    // 목록은 뷰포트로 자른다 — 그쪽은 이미 backing 좌표라 원점을 더하지 않는다.
    const listed = Placement{ .x_px = 0, .y_px = 0, .advance_px = 10, .line_height_px = 20, .foreground = 0, .scroll_clipped = true };
    try std.testing.expectEqual(viewport, glyphClipFor(listed, viewport, 1290, 40).?);

    // 고정 chrome은 자르지 않는다. 뷰포트를 적용하면 헤더·scope·검색이 통째로 사라진다.
    const fixed = Placement{ .x_px = 0, .y_px = 0, .advance_px = 10, .line_height_px = 20, .foreground = 0 };
    try std.testing.expect(glyphClipFor(fixed, viewport, 1290, 40) == null);

    // 무클립 pass에서는 떠 있는 헤더도 자르지 않는다(placement 대조가 클립과 직교해야 한다).
    try std.testing.expect(glyphClipFor(head, null, 1290, 40) == null);
}

pub fn shapesTextOp(text: chrome.draw.Op.Text) bool {
    // 등록 SVG/PUA 아이콘은 icon draw list가 그린다 — spinner phase가 매 프레임 바뀌므로 셰이핑 키에
    // 넣으면 모든 결과가 도착 전에 stale이 된다.
    return !text.wide_icons;
}

/// op 안의 한 run이 셰이핑 대상인지. op 단위 판정과 같은 이유로 단일 출처다.
pub fn shapesRun(text: chrome.draw.Op.Text, run: chrome.draw.Run, max_width_px: u32) bool {
    if (max_width_px == 0) return false;
    // 순수 등록 SVG placement는 CoreText source bytes가 없다. 그 semantic run은 유지한다(worker가
    // 셰이핑을 건너뛰고 논리 rect에서 SVG를 직접 해석한다). 그 밖의 빈 텍스트는 inert다.
    return run.text.len != 0 or text.placement == .icon_in_rect;
}

/// `max_cols`/`max_width_px`에서 이 op의 픽셀 폭 예산을 푼다. 키와 request가 같은 값을 봐야 하므로
/// 이것도 단일 출처다.
pub fn opMaxWidthPx(text: chrome.draw.Op.Text, cell_width_px: u32) ?u32 {
    return text.max_width_px orelse (std.math.mul(u32, text.max_cols, cell_width_px) catch null);
}

/// 이 요청이 쓸 face. platform이 resolved appearance에서 채운다 — chrome 컴포넌트는 여전히 face를 모르고
/// role만 고른다(`chrome/ui/typography.zig` 헤더 계약). 기본값(빈 family)은 system UI face라, resolved
/// appearance가 없는 호출자(Chrome Lab·단위 테스트)가 예전 동작을 그대로 얻는다.
/// 단일 출처: docs/font-strategy.md "Chrome 텍스트 face".
pub const Face = struct {
    family: []const u8 = &.{},
    fallback: []const u8 = &.{},
};

/// Copies only non-icon semantic text out of the frame-local draw list.  This is intentionally
/// cheap enough for the frame path; CoreText shaping is performed only by `shapeRequest`.
pub fn prepareRequest(
    allocator: std.mem.Allocator,
    fingerprint: u64,
    ops: []const chrome.draw.Op,
    tk: *const chrome.Tokens,
    cell_width_px: u32,
    face: Face,
) !Request {
    var runs: std.ArrayList(Request.Run) = .empty;
    errdefer {
        for (runs.items) |run| allocator.free(run.text);
        runs.deinit(allocator);
    }
    for (ops) |op| switch (op) {
        .text => |text| {
            // 좌표(특히 음수 origin)는 여기서 거르지 않는다. 좌표는 shaping 입력이 아니라 placement
            // 계산에만 쓰이고, 화면 밖 여부는 backend의 뷰포트 클립이 판단한다. 거르면 셰이핑 키와 집합이
            // 갈라져 캐시가 그 줄을 영구히 잃는다(`shapesTextOp` 주석).
            if (!shapesTextOp(text)) continue;
            const max_width = opMaxWidthPx(text, cell_width_px) orelse continue;
            var first_run = true;
            for (text.runs) |run| {
                if (!shapesRun(text, run, max_width)) continue;
                try runs.append(allocator, .{
                    .text = try allocator.dupe(u8, run.text),
                    .role = text.text_role,
                    .origin = text.origin,
                    .max_width_px = max_width,
                    // run 이 자기 role 을 들면 그 구간만 다른 색이다(한 줄 안의 위계). 없으면 op 색.
                    .foreground = packRgb(tk.get(run.role orelse text.role)),
                    // **한 op 의 두 번째 run 부터**는 앞 run 끝에 이어 붙인다. 셰이핑에서 걸러진 run 은
                    // 여기 오지 않으므로, 이 표시는 실제로 발행되는 run 들의 순서를 따른다.
                    .continues_previous = !first_run,
                    .anchor = text.anchor,
                    .placement = text.placement,
                    .font_px = text.font_px,
                    .line_height_px = text.line_height_px,
                    .cell_w_px = text.cell_w_px,
                    .scroll_clipped = text.scroll_clipped,
                    .above_clip = if (text.above_scroll) text.clip else null,
                });
                first_run = false;
            }
        },
        else => {},
    };
    const family = try allocator.dupe(u8, face.family);
    errdefer allocator.free(family);
    const fallback = try allocator.dupe(u8, face.fallback);
    errdefer allocator.free(fallback);
    return .{
        .fingerprint = fingerprint,
        .runs = try runs.toOwnedSlice(allocator),
        .font_family = family,
        .font_fallback = fallback,
    };
}

test "prepareRequest keeps a Korean button label and an icon-in-rect on the measured path" {
    const allocator = std.testing.allocator;
    const icon_runs = [_]chrome.draw.Run{.{ .text = icons.utf8(.recent) }};
    const label_runs = [_]chrome.draw.Run{.{ .text = "터미널에서 이어하기" }};
    const utility_runs = [_]chrome.draw.Run{.{ .text = "" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{
            .origin = .{ .x = 24, .y = 8 },
            .runs = &icon_runs,
            .role = .surface_fg,
            .text_role = .button_label,
            .max_cols = 2,
            .wide_icons = true,
        } },
        .{ .text = .{
            .origin = .{ .x = 48, .y = 8 },
            .runs = &label_runs,
            .role = .surface_fg,
            .text_role = .button_label,
            .max_cols = 18,
        } },
        .{ .text = .{
            .origin = .{ .x = 80, .y = 8 },
            .runs = &utility_runs,
            .role = .surface_fg,
            .text_role = .control,
            .max_cols = 1,
            .max_width_px = 20,
            .placement = .{ .icon_in_rect = .{
                .content_rect = .{ .x = 80, .y = 8, .w = 20, .h = 20 },
                .icon_codepoint = icons.codepointFit(.reset, .tight),
                .icon_extent_px = 18,
            } },
        } },
    };
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var request = try prepareRequest(allocator, 17, &ops, &tk, 8, .{});
    defer request.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), request.runs.len);
    try std.testing.expectEqualStrings("터미널에서 이어하기", request.runs[0].text);
    try std.testing.expectEqual(chrome.ui.typography.ChromeTextRole.button_label, request.runs[0].role);
    try std.testing.expectEqual(@as(u32, 18 * 8), request.runs[0].max_width_px);
    try std.testing.expectEqual(@as(usize, 0), request.runs[1].text.len);
    try std.testing.expectEqual(icons.codepointFit(.reset, .tight), request.runs[1].placement.icon_in_rect.icon_codepoint);
}

// 코드리뷰 회귀: 셰이핑 키가 스크롤 평행이동에 불변이 되면서, 같은 키가 "그 줄이 화면 위로 나가 있던
// 프레임"과 "그 줄이 보이는 프레임" 양쪽을 가리킬 수 있게 됐다. 그런데 request는 음수 origin을 버리고
// 있었으므로, 전자에서 만든 artifact에는 그 run이 없고 후자에서 그 artifact가 재사용되며 그 줄이 영구히
// 빈 채로 남았다(확장 카드를 위로 밀었다 되돌리면 제목과 첫 turn이 사라진다). 좌표는 shaping 입력이
// 아니므로 음수여도 셰이핑해야 하고, 화면 밖 여부는 backend의 뷰포트 클립이 판단한다.
test "prepareRequest keeps runs scrolled above the pane so a translated cache stays complete" {
    const allocator = std.testing.allocator;
    const above_runs = [_]chrome.draw.Run{.{ .text = "scrolled-above" }};
    const visible_runs = [_]chrome.draw.Run{.{ .text = "visible" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 20, .y = -48 }, .runs = &above_runs, .role = .surface_fg, .text_role = .card_heading, .max_cols = 20, .scroll_clipped = true } },
        .{ .text = .{ .origin = .{ .x = 20, .y = 120 }, .runs = &visible_runs, .role = .surface_fg, .text_role = .body, .max_cols = 20, .scroll_clipped = true } },
    };
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var request = try prepareRequest(allocator, 5, &ops, &tk, 8, .{});
    defer request.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), request.runs.len);
    try std.testing.expectEqualStrings("scrolled-above", request.runs[0].text);
    try std.testing.expectEqual(@as(i32, -48), request.runs[0].origin.y);
}

// 이 테스트가 증명하는 것: face 바이트를 `Request`가 **소유**한다.
//
// 왜 터미널에서 중요한가 — `Request`는 detached worker로 건널 수 있다는 전제로 설계돼 있고(위 타입
// 주석), 지금도 셰이핑은 호출자의 `ResolvedAppearance`가 config arena에 살아 있는지와 무관하게
// 끝나야 한다. face만 borrow로 두면 config 재로드가 arena를 갈아끼운 프레임에서 해제된 문자열로
// CTFont를 만들게 된다. 소유 여부는 "원본을 덮어써도 request가 그대로인가"로만 증명할 수 있다.
test "prepareRequest owns the face bytes instead of borrowing the caller's appearance" {
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "owned" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg, .text_role = .body, .max_cols = 20 } },
    };
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var family_buf = "JetBrains Mono".*;
    var fallback_buf = "Jetendard".*;
    var request = try prepareRequest(allocator, 7, &ops, &tk, 8, .{ .family = &family_buf, .fallback = &fallback_buf });
    defer request.deinit(allocator);
    @memset(&family_buf, 'x');
    @memset(&fallback_buf, 'x');
    try std.testing.expectEqualStrings("JetBrains Mono", request.font_family);
    try std.testing.expectEqualStrings("Jetendard", request.font_fallback);
}

// 이 테스트가 증명하는 것: chrome 텍스트가 **요청한 family로** 셰이핑되고, family를 안 주면 예전처럼
// system UI face로 셰이핑된다.
//
// 왜 터미널에서 중요한가 — 도크와 사이드바가 한 화면에 보이므로 face가 갈리면 사용자가 고른 폰트를
// 앱이 절반만 따르게 된다(docs/font-strategy.md "Chrome 텍스트 face"). 판정을 PostScript 이름으로 두는
// 이유는 그것이 실제로 래스터에 쓰일 face의 identity이기 때문이다 — 요청만 흘려보내고 CoreText가
// 다른 face를 돌려주는 회귀는 요청 문자열로는 잡히지 않는다. Menlo를 쓰는 것은 macOS 기본 설치라
// 번들 폰트 등록 여부에 흔들리지 않기 때문이다.
test "chrome text shapes with the requested family and keeps the system face when none is given" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "Session" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg, .text_role = .body, .max_cols = 40 } },
    };
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });

    var system_request = try prepareRequest(allocator, 1, &ops, &tk, 8, .{});
    defer system_request.deinit(allocator);
    var system_artifact = try shapeRequest(allocator, &system_request, 1000);
    defer system_artifact.deinit(allocator);

    var menlo_request = try prepareRequest(allocator, 2, &ops, &tk, 8, .{ .family = "Menlo" });
    defer menlo_request.deinit(allocator);
    var menlo_artifact = try shapeRequest(allocator, &menlo_request, 1000);
    defer menlo_artifact.deinit(allocator);

    try std.testing.expect(system_artifact.glyphs.len > 0);
    try std.testing.expect(menlo_artifact.glyphs.len > 0);
    const menlo_name = std.mem.sliceTo(&menlo_artifact.glyphs[0].font_name, 0);
    const system_name = std.mem.sliceTo(&system_artifact.glyphs[0].font_name, 0);
    try std.testing.expect(std.mem.startsWith(u8, menlo_name, "Menlo"));
    try std.testing.expect(!std.mem.startsWith(u8, system_name, "Menlo"));
}

// 이 테스트가 증명하는 것: `.tail` 앵커가 넘칠 때 **앞을** 잘라 문자열 끝을 남긴다.
//
// 왜 터미널에서 중요한가 — 입력 줄(사이드바 검색)은 caret과 방금 친 글자가 문자열 끝에 있다. 기본 `.head`
// 처럼 뒤를 자르면 지금 입력하는 자리가 화면 밖으로 나가 타이핑이 보이지 않는다. 셀 경로는 이것을
// `overlay_input.inputLineView`(tail 창 + 선두 `…`)로 풀었고, measured 경로는 CoreText truncation에 맡긴다
// (docs/file-explorer.md §3.5). 판정을 codepoint로 두는 이유는 "잘렸다"가 아니라 **어느 쪽이 잘렸는지**가
// 계약이기 때문이다 — 두 앵커가 같은 결과를 내면 이 이관이 무의미해진다.
test "tail anchor truncates the head so the caret end survives" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const long = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaZ";
    const runs = [_]chrome.draw.Run{.{ .text = long }};
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });

    const Shape = struct {
        fn run(alloc: std.mem.Allocator, tokens: *const chrome.Tokens, text_runs: []const chrome.draw.Run, anchor: chrome.text_layout.Anchor) !UnresolvedArtifact {
            const ops = [_]chrome.draw.Op{.{
                .text = .{
                    .origin = .{ .x = 0, .y = 0 },
                    .runs = text_runs,
                    .role = .surface_fg,
                    .text_role = .control,
                    .max_width_px = 60, // 원문보다 훨씬 좁다 → 반드시 잘린다
                    .anchor = anchor,
                },
            }};
            var request = try prepareRequest(alloc, 1, &ops, tokens, 8, .{});
            defer request.deinit(alloc);
            return shapeRequest(alloc, &request, 1000);
        }
    };

    var head = try Shape.run(allocator, &tk, &runs, .head);
    defer head.deinit(allocator);
    var tail = try Shape.run(allocator, &tk, &runs, .tail);
    defer tail.deinit(allocator);
    try std.testing.expect(head.glyphs.len > 0 and tail.glyphs.len > 0);

    // 판정은 **끝 글자가 살아남는가**로 한다. 브리지는 codepoint를 원본 문자열의 `string_index`에서 읽으므로
    // `…` 토큰 glyph가 원본 문자로 보고될 수 있다 — 즉 "앞에 …가 붙었나"는 이 ABI로 신뢰할 수 없다. 반면
    // 계약의 본질은 "caret이 있는 끝이 남는가"이고, 그건 마지막 glyph로 정확히 판정된다.
    try std.testing.expectEqual(@as(u32, 'Z'), tail.glyphs[tail.glyphs.len - 1].codepoint);
    // head 앵커는 반대로 끝을 버린다 — 두 앵커가 같은 결과를 내면 이 이관이 무의미하므로 함께 고정한다.
    try std.testing.expect(head.glyphs[head.glyphs.len - 1].codepoint != 'Z');
}

// 이 테스트가 증명하는 것: 설치되지 않은 family를 요청해도 프레임이 죽지 않고 system face로 물러난다.
//
// 왜 터미널에서 중요한가 — `font.family`는 사용자가 직접 타이핑할 수 있는 값이라(세팅의 "직접 입력…")
// 오타가 정상 입력이다. 그때 도크 텍스트가 통째로 사라지면 사용자는 원인을 폰트 이름과 연결하지
// 못한다. CoreText가 없는 폰트에 대체 face를 조용히 돌려주는 성질이 있으므로, 폴백이 실제로 요청한
// 그 폰트가 **아님**도 함께 고정한다.
test "an unknown chrome family falls back to the system face instead of blanking the dock" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "Session" }};
    const ops = [_]chrome.draw.Op{
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &runs, .role = .surface_fg, .text_role = .body, .max_cols = 40 } },
    };
    const tk = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 20, .g = 20, .b = 20 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 80, .g = 80, .b = 80 },
        .search_match = .{ .r = 1, .g = 2, .b = 3 },
        .search_match_current = .{ .r = 4, .g = 5, .b = 6 },
        .selection = .{ .r = 7, .g = 8, .b = 9 },
        .cursor = .{ .r = 10, .g = 11, .b = 12 },
        .terminal_background = .{ .r = 10, .g = 11, .b = 12 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 13, .g = 14, .b = 15 },
    });
    var request = try prepareRequest(allocator, 3, &ops, &tk, 8, .{ .family = "MaruNoSuchFamily12345" });
    defer request.deinit(allocator);
    var artifact = try shapeRequest(allocator, &request, 1000);
    defer artifact.deinit(allocator);
    try std.testing.expect(artifact.glyphs.len > 0);
    const name = std.mem.sliceTo(&artifact.glyphs[0].font_name, 0);
    try std.testing.expect(!std.mem.startsWith(u8, name, "MaruNoSuchFamily"));
}

/// Calls CoreText without touching the renderer.  `Request` owns every input byte, so this is
/// safe to run in a detached worker under CoreText's documented thread-safety contract.
pub fn shapeRequest(allocator: std.mem.Allocator, request: *const Request, scale_milli: u32) !UnresolvedArtifact {
    var glyphs: std.ArrayList(UnresolvedGlyph) = .empty;
    errdefer glyphs.deinit(allocator);
    const placements = try allocator.alloc(chrome.draw.TextPlacement, request.runs.len);
    errdefer allocator.free(placements);
    const foregrounds = try allocator.alloc(u32, request.runs.len);
    errdefer allocator.free(foregrounds);
    const scroll_flags = try allocator.alloc(bool, request.runs.len);
    errdefer allocator.free(scroll_flags);
    const above_clips = try allocator.alloc(?chrome.draw.Rect, request.runs.len);
    errdefer allocator.free(above_clips);
    const cell_widths = try allocator.alloc(?u16, request.runs.len);
    errdefer allocator.free(cell_widths);
    const continues = try allocator.alloc(bool, request.runs.len);
    errdefer allocator.free(continues);
    const max_widths = try allocator.alloc(u32, request.runs.len);
    errdefer allocator.free(max_widths);
    for (request.runs, 0..) |run, index| {
        if (index > std.math.maxInt(u16)) return error.TooManySystemTextRuns;
        placements[index] = run.placement;
        foregrounds[index] = run.foreground;
        scroll_flags[index] = run.scroll_clipped;
        above_clips[index] = run.above_clip;
        cell_widths[index] = run.cell_w_px;
        continues[index] = run.continues_previous;
        max_widths[index] = run.max_width_px;
        if (run.placement == .icon_in_rect) continue;
        const shaped = shapeUnresolvedRun(allocator, run, .{ .family = request.font_family, .fallback = request.font_fallback }, scale_milli) catch |err| switch (run.placement) {
            // A centred Button is all-or-nothing: publishing only its background or a lone
            // icon would make an enabled command look corrupt while hiding the failed label.
            .origin => continue,
            else => return err,
        };
        defer allocator.free(shaped);
        if (shaped.len == 0) switch (run.placement) {
            .origin => continue,
            else => return error.EmptyMeasuredButtonLabel,
        };
        for (shaped) |glyph| {
            var owned = glyph;
            owned.run_index = @intCast(index);
            try glyphs.append(allocator, owned);
        }
    }
    return .{ .glyphs = try glyphs.toOwnedSlice(allocator), .placements = placements, .foregrounds = foregrounds, .scroll_flags = scroll_flags, .above_clips = above_clips, .cell_widths = cell_widths, .continues = continues, .max_widths = max_widths };
}

/// Resolves a completed worker DTO on the main actor.  This bounded conversion is the sole
/// owner of FontIdentityRegistry and intentionally contains no CoreText call.
pub fn resolveArtifact(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    unresolved: UnresolvedArtifact,
) !Artifact {
    var advances = try allocator.alloc(f32, unresolved.placements.len);
    defer allocator.free(advances);
    @memset(advances, 0);
    var line_heights = try allocator.alloc(f32, unresolved.placements.len);
    defer allocator.free(line_heights);
    @memset(line_heights, 0);
    var shaped = try allocator.alloc(bool, unresolved.placements.len);
    defer allocator.free(shaped);
    @memset(shaped, false);
    for (unresolved.glyphs) |glyph| {
        const run_index: usize = glyph.run_index;
        if (run_index >= advances.len) return error.InvalidSystemTextRunIndex;
        advances[run_index] = @max(advances[run_index], glyph.x_px + glyph.advance_px);
        line_heights[run_index] = @max(line_heights[run_index], glyph.line_height_px);
        shaped[run_index] = true;
    }
    var icon_count: usize = 0;
    for (unresolved.placements, shaped) |placement, has_glyph| switch (placement) {
        .icon_in_rect => icon_count += 1,
        .leading_icon_group => {
            if (has_glyph) icon_count += 1;
        },
        else => {},
    };
    const total_count = std.math.add(usize, unresolved.glyphs.len, icon_count) catch return error.TooManySystemTextGlyphs;
    const records = try allocator.alloc(renderer.ShapedGlyphRecord, total_count);
    errdefer allocator.free(records);
    const placements = try allocator.alloc(Placement, total_count);
    // 아래에는 아직 error return이 남아 있다(등록되지 않은 아이콘·불변식 위반·registry.intern OOM).
    // records만 errdefer로 회수하면 그 경로마다 placement 배열이 프레임 단위로 샌다.
    errdefer allocator.free(placements);
    var record_index: usize = 0;
    // **셀 격자 run은 x를 advance가 아니라 셀 인덱스로 놓는다**(§2.0).
    //
    // CoreText가 준 `x_px`는 폰트 advance를 누적한 값이라, advance가 셀 폭과 미세하게만 달라도
    // (등폭 폰트도 7.8px vs 셀 8px 같은 차이가 난다) 두 번째 글자부터 격자를 벗어난다. 그래서
    // 글자마다 **셀 폭(EAW)을 누적해** 몇 번째 칸인지 직접 센다 — 한글·CJK·이모지는 두 칸,
    // 결합 문자는 0칸이라 앞 글자와 같은 칸에 놓인다.
    //
    // x를 셀 배수로 **반올림**하는 방식은 기각했다. 글자마다 advance가 다르면 여러 글자가 같은
    // 칸으로 몰려 문자열이 겹쳐 그려진다(실제로 그렇게 깨진 캡처를 봤다). 인덱스를 세는 것과
    // 좌표를 반올림하는 것은 다르다.
    //
    // glyph는 run 안에서 논리 순서로 오므로 run이 바뀔 때만 카운터를 리셋한다. 리거처로 codepoint와
    // glyph가 1:1이 아니면 근사가 되지만, 코드 편집기 폰트에서 리거처는 통상 꺼 둔다.
    // **이어 붙이는 run 의 x 오프셋**을 먼저 만든다(`chrome.draw.Run` 계약). 컴포넌트는 비례 폰트의
    // advance 를 모르므로 한 줄 안에서 색이 바뀌는 구간을 이어 놓을 수 없고, 셀 격자로 추정해 op 을
    // 나누면 구간 사이가 벌어진다. 실측 advance 를 가진 이 자리에서 잇는다 — 앞 run 이 셰이핑되지
    // 않았으면(빈 문자열·필터) 그 폭은 0 이라 자연히 건너뛴다.
    const carry = try allocator.alloc(f32, unresolved.placements.len);
    defer allocator.free(carry);
    for (carry, 0..) |*value, index| {
        value.* = if (index > 0 and unresolved.continues[index]) carry[index - 1] + advances[index - 1] else 0;
    }
    var grid_run: ?u16 = null;
    var grid_cell: u32 = 0;
    var dropped: usize = 0;
    for (unresolved.glyphs) |glyph| {
        const run_index: usize = glyph.run_index;
        const layout = unresolved.placements[run_index];
        var label_origin = labelOrigin(layout, glyph.origin, advances[run_index], glyph.line_height_px);
        label_origin.x_px += carry[run_index];
        // **이어 붙인 만큼 예산도 줄어든다.** CoreText truncation 은 run 하나만 보고 자르므로, 각 run 이
        // op 전체 폭을 자기 한도로 받으면 이어 붙인 합계가 그 폭을 넘는다(캡처에서 모델명이 chevron 을
        // 지나 카드 밖까지 뻗었다). 누적 x 를 아는 이 자리에서 경계를 다시 재고, 넘는 글리프는 버린다 —
        // 잘리는 편이 옆 요소를 덮는 것보다 낫다.
        if (carry[run_index] > 0) {
            const budget: f32 = @floatFromInt(unresolved.max_widths[run_index]);
            if (carry[run_index] + glyph.x_px + glyph.advance_px > budget) {
                dropped += 1;
                continue;
            }
        }
        const grid_x: ?f32 = if (unresolved.cell_widths[run_index]) |cw| blk: {
            if (grid_run == null or grid_run.? != glyph.run_index) {
                grid_run = glyph.run_index;
                grid_cell = 0;
            }
            const x = @as(f32, @floatFromInt(grid_cell)) * @as(f32, @floatFromInt(cw));
            const cp: u21 = @intCast(@min(glyph.codepoint, std.math.maxInt(u21)));
            // **열을 세는 쪽과 같은 규칙을 써야 한다**(§4.2). `width.cellWidth`만 쓰면 컬러 이모지
            // (❤️·국기)와 동그란 번호가 1칸으로 전진해, `content.zig`가 2칸으로 센 열과 갈려 뒤
            // 글자가 밀린다 — 실제로 그렇게 어긋난 캡처를 봤다. `display_width`가 두 경로의 단일
            // 출처이고, 그 모듈의 교차 검증 테스트가 둘이 같은 답을 내는지 묶어 둔다.
            grid_cell += display_width.glyphCells(cp, glyph.color_glyph_kind == .color);
            break :blk x;
        } else null;
        const record = &records[record_index];
        const placement = &placements[record_index];
        const name = probe.cStringField(&glyph.font_name);
        const font_id = try registry.intern(.{ .postscript_name = name });
        const advance = @max(glyph.advance_px, 1.0);
        // **합자는 자기 자리보다 왼쪽에서 시작한다.** 폰트가 둘째 글리프에 두 글자를 합친 모양을 놓고 그
        // ink 를 advance 왼쪽 밖으로 빼기 때문이다(첫 글리프는 빈 자리). 슬롯을 advance 폭으로만 잡으면
        // 넘친 부분이 **잘려** `//` 가 `/` 하나로 보인다(#2123 — 편집기 본문에서 사용자가 본 그림).
        //
        // 터미널 셀 경로는 같은 사실을 `left_overhang_cells` 로 받아 칸 수를 늘려 해결했다. chrome 텍스트는
        // 셀이 없으므로 px 로 받아 **슬롯을 넓히고 그린 자리를 그만큼 왼쪽으로 당긴다** — 래스터가 왼쪽으로
        // 넘치는 글리프를 슬롯 오른쪽에 붙여 그리므로(coretext_smoke.m), 넓힌 슬롯 안에 ink 가 온전히 들어온다.
        //
        // **전진 칸 수는 건드리지 않는다.** CoreText 가 합자에도 글자마다 글리프를 하나씩 주므로(빈 글리프 +
        // 합자 글리프) 격자는 이미 맞다 — 여기서 칸을 더 세면 뒤 글자가 오히려 밀린다.
        const overhang = @max(glyph.left_overhang_px, 0.0);
        record.* = .{
            .row = @intCast(record_index / 256),
            .col = @intCast(record_index % 256),
            .cell_width = 1,
            .codepoint = @intCast(@min(glyph.codepoint, std.math.maxInt(u21))),
            .font_id = font_id,
            .glyph_id = glyph.glyph_id,
            .fallback = glyph.fallback,
            .color_glyph_kind = glyph.color_glyph_kind,
            .raster_font_size_milli = @intCast(@as(u32, glyph.point_size) * 1000),
            .raster_width_px = @intFromFloat(@ceil(advance + overhang)),
            .raster_height_px = @intFromFloat(@ceil(glyph.line_height_px)),
        };
        placement.* = .{
            .x_px = label_origin.x_px + (grid_x orelse glyph.x_px) - overhang,
            .y_px = label_origin.y_px,
            .advance_px = advance,
            .line_height_px = glyph.line_height_px,
            .foreground = glyph.foreground,
            .scroll_clipped = unresolved.scroll_flags[run_index],
            .above_clip = unresolved.above_clips[run_index],
        };
        record_index += 1;
    }
    for (unresolved.placements, shaped, advances, line_heights, unresolved.foregrounds, unresolved.scroll_flags, unresolved.above_clips) |layout, has_glyph, advance, line_height, foreground, scroll_clipped, above_clip| switch (layout) {
        .icon_in_rect => |icon| {
            if (!renderer.icon_glyph.isRegisteredIcon(icon.icon_codepoint)) return error.UnregisteredChromeIcon;
            records[record_index] = .{ .row = @intCast(record_index / 256), .col = @intCast(record_index % 256), .cell_width = 1, .codepoint = icon.icon_codepoint, .font_id = 0, .glyph_id = 0, .color_glyph_kind = .monochrome, .raster_width_px = icon.icon_extent_px, .raster_height_px = icon.icon_extent_px };
            placements[record_index] = .{ .x_px = @as(f32, @floatFromInt(icon.content_rect.x)) + (@as(f32, @floatFromInt(icon.content_rect.w)) - @as(f32, @floatFromInt(icon.icon_extent_px))) / 2, .y_px = @as(f32, @floatFromInt(icon.content_rect.y)) + (@as(f32, @floatFromInt(icon.content_rect.h)) - @as(f32, @floatFromInt(icon.icon_extent_px))) / 2, .advance_px = @floatFromInt(icon.icon_extent_px), .line_height_px = @floatFromInt(icon.icon_extent_px), .foreground = foreground, .scroll_clipped = scroll_clipped, .above_clip = above_clip };
            record_index += 1;
        },
        .leading_icon_group => |group| {
            if (!has_glyph) continue;
            if (!renderer.icon_glyph.isRegisteredIcon(group.icon_codepoint)) return error.UnregisteredChromeIcon;
            const group_width = @as(f32, @floatFromInt(group.icon_extent_px + group.gap_px)) + advance;
            const x = @as(f32, @floatFromInt(group.content_rect.x)) + (@as(f32, @floatFromInt(group.content_rect.w)) - group_width) / 2;
            const y = @as(f32, @floatFromInt(group.content_rect.y)) + (@as(f32, @floatFromInt(group.content_rect.h)) - @as(f32, @floatFromInt(group.icon_extent_px))) / 2;
            records[record_index] = .{
                .row = @intCast(record_index / 256),
                .col = @intCast(record_index % 256),
                .cell_width = 1,
                .codepoint = group.icon_codepoint,
                // Registered SVG coverage is selected by codepoint.  No platform font or
                // CoreText call is needed for this record, and the renderer's glyph_id=0
                // synthetic gate prevents it from sharing a font glyph atlas slot.
                .font_id = 0,
                .glyph_id = 0,
                .color_glyph_kind = .monochrome,
                .raster_width_px = group.icon_extent_px,
                .raster_height_px = group.icon_extent_px,
            };
            placements[record_index] = .{
                .x_px = x,
                .y_px = y,
                .advance_px = @floatFromInt(group.icon_extent_px),
                .line_height_px = if (line_height > 0) line_height else @floatFromInt(group.icon_extent_px),
                .foreground = foreground,
                .scroll_clipped = scroll_clipped,
                .above_clip = above_clip,
            };
            record_index += 1;
        },
        else => {},
    };
    // 예산을 넘겨 버린 글리프 수만큼 배열이 짧아진다. 그 몫을 빼고도 개수가 안 맞으면 불변식 위반이다.
    if (record_index + dropped != total_count) return error.InvalidSystemTextArtifact;
    if (dropped > 0) {
        // 뒤쪽 미초기화 슬롯을 그대로 두면 렌더가 쓰레기 글리프를 그린다. 실제 개수로 줄여 소유권을
        // 그대로 유지한다(`Artifact.deinit` 이 두 배열을 각각 해제하므로 재할당은 하지 않는다).
        const shrunk_records = try allocator.realloc(records, record_index);
        const shrunk_placements = try allocator.realloc(placements, record_index);
        return .{ .records = shrunk_records, .placements = shrunk_placements };
    }
    return .{ .records = records, .placements = placements };
}

const ResolvedOrigin = struct { x_px: f32, y_px: f32 };

fn labelOrigin(layout: chrome.draw.TextPlacement, fallback: chrome.draw.Px, advance: f32, line_height: f32) ResolvedOrigin {
    return switch (layout) {
        .origin => .{ .x_px = @floatFromInt(fallback.x), .y_px = @floatFromInt(fallback.y) },
        .center_in_rect => |rect| .{
            .x_px = @as(f32, @floatFromInt(rect.x)) + (@as(f32, @floatFromInt(rect.w)) - advance) / 2,
            .y_px = @as(f32, @floatFromInt(rect.y)) + (@as(f32, @floatFromInt(rect.h)) - line_height) / 2,
        },
        .icon_in_rect => unreachable,
        .leading_icon_group => |group| .{
            .x_px = @as(f32, @floatFromInt(group.content_rect.x)) + (@as(f32, @floatFromInt(group.content_rect.w)) - (@as(f32, @floatFromInt(group.icon_extent_px + group.gap_px)) + advance)) / 2 + @as(f32, @floatFromInt(group.icon_extent_px + group.gap_px)),
            .y_px = @as(f32, @floatFromInt(group.content_rect.y)) + (@as(f32, @floatFromInt(group.content_rect.h)) - line_height) / 2,
        },
    };
}

// 한 줄 안에서 색만 바뀌는 구간(`chrome.draw.Run`)이 **실측 advance 로 이어지는지**. 컴포넌트는 비례
// 폰트의 advance 를 모르므로 스스로 잇지 못하고, 셀 격자로 추정해 op 을 나누면 구간 사이가 벌어진다
// (세션 카드 메타 줄에서 실제로 그렇게 벌어진 캡처를 봤다). 그 이음이 이 자리의 책임이다.
// [#2123] 편집기 본문에서 `//` 가 `/` 하나로 보였다. 원인은 합자 글리프의 ink 가 자기 자리보다 **왼쪽에서
// 시작**하는데(폰트가 두 글자를 합친 모양을 둘째 글리프에 놓는다) 래스터 슬롯을 advance 폭으로만 잡아
// 넘친 부분이 잘린 것이다. 슬롯을 넓히고 그린 자리를 당기는 계약을 여기서 못 박는다 — 값이 없는(0) 글리프는
// 예전과 **한 픽셀도 다르지 않아야** 한다(합자가 아닌 모든 글자가 그 경우다).
test "합자처럼 왼쪽으로 넘치는 글리프는 슬롯이 넓어지고 그 만큼 왼쪽에서 그려진다" {
    const allocator = std.testing.allocator;
    var font_name = [_]u8{0} ** 128;
    @memcpy(font_name[0..6], "System");
    const make = struct {
        fn glyph(x_px: f32, advance: f32, overhang: f32, name: [128]u8) UnresolvedGlyph {
            return .{
                .glyph_id = 12,
                .codepoint = '/',
                .fallback = false,
                .color_glyph_kind = .monochrome,
                .x_px = x_px,
                .advance_px = advance,
                .left_overhang_px = overhang,
                .font_name = name,
                .point_size = 14,
                .line_height_px = 20,
                .origin = .{ .x = 100, .y = 40 },
                .foreground = 0xAABBCC,
                .run_index = 0,
            };
        }
    };
    // 두 글리프 모두 advance 8: 앞은 넘침 없음(보통 글자), 뒤는 왼쪽으로 6px 넘침(합자).
    const glyphs = try allocator.dupe(UnresolvedGlyph, &.{
        make.glyph(0, 8, 0, font_name),
        make.glyph(8, 8, 6, font_name),
    });
    var unresolved = UnresolvedArtifact{
        .glyphs = glyphs,
        .placements = try allocator.dupe(chrome.draw.TextPlacement, &.{ .origin, .origin }),
        .foregrounds = try allocator.dupe(u32, &.{ 0xAABBCC, 0xAABBCC }),
        .scroll_flags = try allocator.dupe(bool, &.{ false, false }),
        .above_clips = try allocator.dupe(?chrome.draw.Rect, &.{ null, null }),
        .cell_widths = try allocator.dupe(?u16, &.{ null, null }),
        .continues = try allocator.dupe(bool, &.{ false, false }),
        .max_widths = try allocator.dupe(u32, &.{ 10_000, 10_000 }),
    };
    defer unresolved.deinit(allocator);
    var registry = renderer.FontIdentityRegistry.init(allocator);
    defer registry.deinit();
    var artifact = try resolveArtifact(allocator, &registry, unresolved);
    defer artifact.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 2), artifact.placements.len);
    // 넘침이 없는 글리프: 슬롯도 자리도 예전 그대로다(이 수정이 일반 글자를 건드리지 않는다는 증거).
    try std.testing.expectEqual(@as(f32, 100), artifact.placements[0].x_px);
    try std.testing.expectEqual(@as(u16, 8), artifact.records[0].raster_width_px);
    // 합자: 슬롯이 넘침만큼 넓어지고(8 → 14) 그린 자리는 그만큼 왼쪽으로 간다(108 → 102).
    // 슬롯만 넓히고 자리를 안 당기면 ink 가 여전히 오른쪽 밖으로 나가고, 자리만 당기면 글자가 왼쪽으로 밀린다.
    try std.testing.expectEqual(@as(u16, 14), artifact.records[1].raster_width_px);
    try std.testing.expectEqual(@as(f32, 102), artifact.placements[1].x_px);
    // **전진(advance)은 그대로다.** 격자는 글리프 수로 이미 맞으므로 여기서 폭을 늘리면 뒤 글자가 밀린다.
    try std.testing.expectEqual(@as(f32, 8), artifact.placements[1].advance_px);
}

test "이어 붙이는 run 은 앞 run 의 실측 advance 만큼 밀린다(같은 origin 에서 겹치지 않는다)" {
    const allocator = std.testing.allocator;
    var font_name = [_]u8{0} ** 128;
    @memcpy(font_name[0..6], "System");
    const glyph = struct {
        // 글리프의 색은 **그 run 의 색**이다(`shapeUnresolvedRun` 이 `run.foreground` 를 싣는다) —
        // fixture 도 그 경로대로 run 마다 다른 색을 준다.
        fn make(x_px: f32, advance: f32, run_index: u16, foreground: u32, name: [128]u8) UnresolvedGlyph {
            return .{
                .glyph_id = 12,
                .codepoint = 'A',
                .fallback = false,
                .color_glyph_kind = .monochrome,
                .x_px = x_px,
                .advance_px = advance,
                .font_name = name,
                .point_size = 14,
                .line_height_px = 20,
                .origin = .{ .x = 100, .y = 40 },
                .foreground = foreground,
                .run_index = run_index,
            };
        }
    };
    // run0: 폭 30(=0+30). run1: 이어 붙임. run2: 이어 붙임 → run0+run1 만큼 밀린다.
    const glyphs = try allocator.dupe(UnresolvedGlyph, &.{
        glyph.make(0, 30, 0, 0xAABBCC, font_name),
        glyph.make(0, 11, 1, 0x112233, font_name),
        glyph.make(0, 7, 2, 0x445566, font_name),
    });
    const layouts = try allocator.dupe(chrome.draw.TextPlacement, &.{ .origin, .origin, .origin });
    var unresolved = UnresolvedArtifact{
        .glyphs = glyphs,
        .placements = layouts,
        .foregrounds = try allocator.dupe(u32, &.{ 0xAABBCC, 0x112233, 0x445566 }),
        .scroll_flags = try allocator.dupe(bool, &.{ false, false, false }),
        .above_clips = try allocator.dupe(?chrome.draw.Rect, &.{ null, null, null }),
        .cell_widths = try allocator.dupe(?u16, &.{ null, null, null }),
        .continues = try allocator.dupe(bool, &.{ false, true, true }),
        .max_widths = try allocator.dupe(u32, &.{ 10_000, 10_000, 10_000 }),
    };
    defer unresolved.deinit(allocator);
    var registry = renderer.FontIdentityRegistry.init(allocator);
    defer registry.deinit();
    var artifact = try resolveArtifact(allocator, &registry, unresolved);
    defer artifact.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 3), artifact.placements.len);
    try std.testing.expectEqual(@as(f32, 100), artifact.placements[0].x_px);
    try std.testing.expectEqual(@as(f32, 130), artifact.placements[1].x_px); // 100 + run0(30)
    try std.testing.expectEqual(@as(f32, 141), artifact.placements[2].x_px); // 100 + 30 + run1(11)
    // 색은 run 마다 그대로 실린다 — 이어 붙였다고 앞 run 색으로 합쳐지지 않는다.
    try std.testing.expectEqual(@as(u32, 0x112233), artifact.placements[1].foreground);
}

// 이어 붙인 run 은 **예산도 함께 줄어든다**. CoreText truncation 은 run 하나만 보고 자르므로, 각 run 이
// op 전체 폭을 자기 한도로 받으면 합계가 그 폭을 넘는다 — 실제로 세션 카드 메타 줄의 모델명이 chevron 을
// 지나 카드 밖까지 뻗은 캡처를 봤다. 넘는 글리프는 버려야 옆 요소를 덮지 않는다.
test "이어 붙인 run 이 폭 예산을 넘으면 그 글리프는 버려진다" {
    const allocator = std.testing.allocator;
    var font_name = [_]u8{0} ** 128;
    @memcpy(font_name[0..6], "System");
    const make = struct {
        fn glyph(x_px: f32, advance: f32, run_index: u16, name: [128]u8) UnresolvedGlyph {
            return .{
                .glyph_id = 12,
                .codepoint = 'A',
                .fallback = false,
                .color_glyph_kind = .monochrome,
                .x_px = x_px,
                .advance_px = advance,
                .font_name = name,
                .point_size = 14,
                .line_height_px = 20,
                .origin = .{ .x = 0, .y = 0 },
                .foreground = 0xAABBCC,
                .run_index = run_index,
            };
        }
    };
    // 예산 50. run0 이 40 을 쓰고, 이어 붙인 run1 의 두 번째 글리프가 40+10+10=60 으로 넘는다.
    const glyphs = try allocator.dupe(UnresolvedGlyph, &.{
        make.glyph(0, 40, 0, font_name),
        make.glyph(0, 10, 1, font_name),
        make.glyph(10, 10, 1, font_name),
    });
    const layouts = try allocator.dupe(chrome.draw.TextPlacement, &.{ .origin, .origin });
    var unresolved = UnresolvedArtifact{
        .glyphs = glyphs,
        .placements = layouts,
        .foregrounds = try allocator.dupe(u32, &.{ 0xAABBCC, 0xAABBCC }),
        .scroll_flags = try allocator.dupe(bool, &.{ false, false }),
        .above_clips = try allocator.dupe(?chrome.draw.Rect, &.{ null, null }),
        .cell_widths = try allocator.dupe(?u16, &.{ null, null }),
        .continues = try allocator.dupe(bool, &.{ false, true }),
        .max_widths = try allocator.dupe(u32, &.{ 50, 50 }),
    };
    defer unresolved.deinit(allocator);
    var registry = renderer.FontIdentityRegistry.init(allocator);
    defer registry.deinit();
    var artifact = try resolveArtifact(allocator, &registry, unresolved);
    defer artifact.deinit(allocator);

    // 세 글리프 중 예산 안에 드는 둘만 남는다.
    try std.testing.expectEqual(@as(usize, 2), artifact.placements.len);
    try std.testing.expectEqual(@as(f32, 0), artifact.placements[0].x_px);
    try std.testing.expectEqual(@as(f32, 40), artifact.placements[1].x_px);
}

test "leading icon group resolves measured label and SVG to one final-pixel artifact" {
    const allocator = std.testing.allocator;
    var font_name = [_]u8{0} ** 128;
    @memcpy(font_name[0..6], "System");
    const glyphs = try allocator.dupe(UnresolvedGlyph, &.{.{
        .glyph_id = 12,
        .codepoint = 'A',
        .fallback = false,
        .color_glyph_kind = .monochrome,
        .x_px = 0,
        .advance_px = 30,
        .font_name = font_name,
        .point_size = 14,
        .line_height_px = 20,
        .origin = .{ .x = 0, .y = 0 },
        .foreground = 0xAABBCC,
        .run_index = 0,
    }});
    const layouts = try allocator.dupe(chrome.draw.TextPlacement, &.{.{ .leading_icon_group = .{
        .content_rect = .{ .x = 20, .y = 10, .w = 100, .h = 30 },
        .icon_codepoint = icons.codepoint(.recent),
        .icon_extent_px = 20,
        .gap_px = 10,
    } }});
    const foregrounds = try allocator.dupe(u32, &.{0xAABBCC});
    var unresolved = UnresolvedArtifact{ .glyphs = glyphs, .placements = layouts, .foregrounds = foregrounds, .scroll_flags = try allocator.dupe(bool, &.{false}), .above_clips = try allocator.dupe(?chrome.draw.Rect, &.{null}), .cell_widths = try allocator.dupe(?u16, &.{null}), .continues = try allocator.dupe(bool, &.{false}), .max_widths = try allocator.dupe(u32, &.{10_000}) };
    defer unresolved.deinit(allocator);
    var registry = renderer.FontIdentityRegistry.init(allocator);
    defer registry.deinit();
    var artifact = try resolveArtifact(allocator, &registry, unresolved);
    defer artifact.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 2), artifact.records.len);
    try std.testing.expectEqual(@as(f32, 70), artifact.placements[0].x_px);
    try std.testing.expectEqual(@as(f32, 15), artifact.placements[0].y_px);
    try std.testing.expectEqual(icons.codepoint(.recent), artifact.records[1].codepoint);
    try std.testing.expectEqual(@as(u32, 0), artifact.records[1].glyph_id);
    try std.testing.expectEqual(@as(f32, 40), artifact.placements[1].x_px);
    try std.testing.expectEqual(@as(f32, 15), artifact.placements[1].y_px);
}

test "icon in rect resolves a registered SVG without a CoreText glyph" {
    const allocator = std.testing.allocator;
    const glyphs = try allocator.alloc(UnresolvedGlyph, 0);
    const layouts = try allocator.dupe(chrome.draw.TextPlacement, &.{.{ .icon_in_rect = .{
        .content_rect = .{ .x = 100, .y = 40, .w = 20, .h = 20 },
        .icon_codepoint = icons.codepointFit(.reset, .tight),
        .icon_extent_px = 18,
    } }});
    const foregrounds = try allocator.dupe(u32, &.{0x123456});
    var unresolved = UnresolvedArtifact{ .glyphs = glyphs, .placements = layouts, .foregrounds = foregrounds, .scroll_flags = try allocator.dupe(bool, &.{false}), .above_clips = try allocator.dupe(?chrome.draw.Rect, &.{null}), .cell_widths = try allocator.dupe(?u16, &.{null}), .continues = try allocator.dupe(bool, &.{false}), .max_widths = try allocator.dupe(u32, &.{10_000}) };
    defer unresolved.deinit(allocator);
    var registry = renderer.FontIdentityRegistry.init(allocator);
    defer registry.deinit();
    var artifact = try resolveArtifact(allocator, &registry, unresolved);
    defer artifact.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), artifact.records.len);
    try std.testing.expectEqual(icons.codepointFit(.reset, .tight), artifact.records[0].codepoint);
    try std.testing.expectEqual(@as(u32, 0), artifact.records[0].glyph_id);
    try std.testing.expectEqual(@as(f32, 101), artifact.placements[0].x_px);
    try std.testing.expectEqual(@as(f32, 41), artifact.placements[0].y_px);
    try std.testing.expectEqual(@as(u32, 0x123456), artifact.placements[0].foreground);
}

pub fn emptyDrawList(allocator: std.mem.Allocator, glyph_count: usize) !renderer.DrawList {
    const rows: u16 = @intCast(@max(@as(usize, 1), (glyph_count + 255) / 256));
    return .{
        .size = .{ .cols = 256, .rows = rows },
        .cursor = .{ .visible = false },
        .dirty = .{ .start_row = 0, .end_row = rows - 1 },
        .cells = try allocator.alloc(renderer.DrawCell, 0),
        .grapheme_pool = try allocator.alloc(u32, 0),
        .overlays = try allocator.alloc(renderer.DrawOverlay, 0),
    };
}

/// 타이포그래피 role → **이음매 굵기**. `weight()` 의 0/1 은 CoreText 브리지 전용 기호값이라
/// 서로 바꿔 쓰면 안 된다 — 이름이 비슷해 실제로 섞였고, 이제 타입이 다르므로 안 섞인다.
fn seamWeight(role: chrome.ui.typography.ChromeTextRole) maru.text_shaper.Weight {
    return switch (chrome.ui.typography.token(role).weight) {
        .regular => .regular,
        .medium => .medium,
        .semibold => .semibold,
    };
}

/// **CoreText 브리지 전용 기호값**(0 = regular, 1 = bold trait). 이름이 짧아 이음매 쪽과 헷갈리기
/// 쉬우니 위 `cssWeight` 와 나란히 둔다.
fn weight(role: chrome.ui.typography.ChromeTextRole) u32 {
    return switch (chrome.ui.typography.token(role).weight) {
        .regular => 0,
        .medium, .semibold => 1,
    };
}

fn packRgb(rgb: maru.color.Rgb) u32 {
    return (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

/// Shapes exactly one semantic run.  `origin` is the component's final local line-box origin;
/// the native bridge supplies proportional advances and actual fallback face identity.
pub fn shapeRun(
    allocator: std.mem.Allocator,
    registry: *renderer.FontIdentityRegistry,
    text: []const u8,
    role: chrome.ui.typography.ChromeTextRole,
    origin: chrome.draw.Px,
    max_width_px: u32,
    foreground: u32,
    face: Face,
    scale_milli: u32,
) !Artifact {
    const owned = try allocator.dupe(u8, text);
    const family = try allocator.dupe(u8, face.family);
    const fallback = try allocator.dupe(u8, face.fallback);
    var request = Request{
        .fingerprint = 0,
        .runs = &.{.{ .text = owned, .role = role, .origin = origin, .max_width_px = max_width_px, .foreground = foreground }},
        .font_family = family,
        .font_fallback = fallback,
    };
    defer request.deinit(allocator);
    var unresolved = try shapeRequest(allocator, &request, scale_milli);
    defer unresolved.deinit(allocator);
    return resolveArtifact(allocator, registry, unresolved);
}

fn shapeUnresolvedRun(allocator: std.mem.Allocator, run: Request.Run, face: Face, scale_milli: u32) ![]UnresolvedGlyph {
    // The boundary/portable test targets link this module without the macOS CoreText object
    // file. Keep the product-only bridge unreachable there instead of leaving an undefined
    // native symbol merely because a detached-worker test imports its type.
    // **Windows 는 이음매(`maru.text_shaper`)로 간다.** 그 이음매가 `switch (builtin.os.tag)` 로
    // 백엔드를 고르므로 이 파일은 Windows 코드를 안 본다 — 이 파일은 모듈 루트가 `platform/macos` 안인
    // 아티팩트에서도 컴파일되어 `../../windows/…` 를 상대 경로로 못 탄다(§2m.11).
    if (builtin.os.tag != .macos and !maru.text_shaper.available) return error.UnsupportedSystemText;
    // **셀 격자면 폰트 크기가 셀에서 나온다.** 토큰(pt)은 chrome 고정값이라 편집기 폰트를 키워도
    // 그대로여서, 셀만 커지고 글자는 안 커지는 화면이 된다(실측으로 확인한 결함).
    //
    // 셀 높이를 쓰는 이유: 폰트 크기는 관례적으로 em 높이이고 줄 높이가 그것에 비례한다. 폭에서
    // 역산하면 폰트마다 다른 advance/em 비율을 알아야 한다. `cell_line_height_ratio`는 터미널이
    // 쓰는 것과 같은 계열의 값이며, 미세한 차이는 아래 셀 스냅이 흡수한다.
    // **셀 높이에서 뽑은 크기는 이미 device 픽셀이라 scale을 다시 곱하지 않는다.**
    // 토큰 point size는 논리 pt라 backing scale을 곱해야 하지만, 셀은 호출자가 이미 device px로
    // 준다(제품에서는 `refreshCellMetrics`가 그렇게 만든다). 둘을 같은 식에 넣으면 Retina에서
    // 편집기 폰트만 2배 더 커진다 — Lab이 1× 고정이라 캡처로는 드러나지 않는 종류의 결함이다.
    // **토큰 경로는 원래 식을 그대로 둔다.** `point_size`는 glyph에 실려 `raster_font_size_milli`가
    // 되므로 그 의미(논리 pt)를 바꾸면 도크·탭의 래스터 크기가 달라진다 — Lab이 1× 고정이라
    // 골든으로는 드러나지 않고 Retina에서만 2배가 되는 종류의 회귀다.
    // **셋은 한 묶음이다.** 한쪽만 오면 폰트는 셀을 따라 커지는데 줄 상자는 토큰 고정이라(또는 그 반대)
    // 글자가 잘리거나 여백이 어긋난다. 호출자가 실수하면 여기서 멈춘다.
    //
    // `cell_w_px`도 같이 잰다. 앞서 이 assert는 앞의 둘만 봤는데, **빠진 하나가 하필 배치 의미를 가르는
    // 필드**였다 — 없으면 백엔드가 글자 x를 폰트 advance로 놓아(measured) 격자를 벗어난다. 등폭이어도
    // advance 7.8px vs 셀 8px이라 두 번째 글자부터 어긋나고, 이 결함은 **컴파일도 테스트도 통과하고
    // 화면에서만** 드러난다(실측 이력: 계산 x=224인데 화면 x=167 — 캡처가 잡았다).
    //
    // 골든은 이 부류를 못 막는다. 회귀는 잡지만 **첫 구현은 그 상태로 비준**한다 —
    // `editor-font-large.ppm`이 이 스택에서 다섯 번 갱신됐고, 글리프가 안 커지던 동안에도 통과했다.
    //
    // **이 방어의 사정거리를 정확히 알고 쓴다.** `std.debug.assert`는 Debug·ReleaseSafe에서는 멈추지만
    // **ReleaseFast에서는 사라진다** — 배포 DMG가 그것이다(`.mise.toml`의 `macos-dmg -Doptimize=ReleaseFast`).
    // 즉 테스트·Lab·ReleaseSafe 게이트가 잡아 주는 것이고, 제품 바이너리는 이 검사를 받지 않는다.
    std.debug.assert((run.font_px == null) == (run.line_height_px == null));
    std.debug.assert((run.font_px == null) == (run.cell_w_px == null));
    const token_pt = chrome.ui.typography.token(run.role).point_size;
    const point_size: u16 = if (run.font_px) |px| @max(1, px) else token_pt;
    // 셀 경로의 크기는 **이미 device 픽셀**이라 backing scale을 다시 곱하지 않는다(호출자가 반영해
    // 넘긴다). 토큰은 논리 pt라 곱해야 한다.
    const scaled_size: f64 = if (run.font_px) |px|
        @max(1.0, @as(f64, @floatFromInt(px)))
    else
        @as(f64, @floatFromInt(token_pt)) * @as(f64, @floatFromInt(scale_milli)) / 1000.0;
    var native: bridge.NativeChromeTextShapeResult = .{};
    const capacity = @max(@as(usize, 16), run.text.len * 2);

    // **여기서 갈라진다.** 위에서 정한 크기·줄 높이·색은 그대로 쓰고 글리프를 만드는 일만 플랫폼이
    // 한다. 아래 CoreText 경로와 **같은 `UnresolvedGlyph`** 로 접히므로 두 플랫폼이 같은 화면을 낸다.
    if (comptime builtin.os.tag != .macos) {
        return shapeViaSeam(allocator, run, face, scaled_size, point_size, capacity);
    }

    var glyphs = try allocator.alloc(bridge.NativeChromeTextGlyphRecord, capacity);
    defer allocator.free(glyphs);
    bridge.maru_macos_coretext_shape_chrome_text(
        run.text.ptr,
        run.text.len,
        face.family.ptr,
        face.family.len,
        face.fallback.ptr,
        face.fallback.len,
        scaled_size,
        weight(run.role),
        @floatFromInt(run.max_width_px),
        @intFromBool(run.anchor == .tail),
        &native,
        glyphs.ptr,
        glyphs.len,
    );
    if (native.status != 0 or native.glyph_record_overflow != 0) return error.CoreTextChromeTextShapeFailed;
    const count = @min(@as(usize, native.glyph_record_count), glyphs.len);
    const out = try allocator.alloc(UnresolvedGlyph, count);
    for (glyphs[0..count], out) |native_glyph, *glyph| {
        glyph.* = .{
            .glyph_id = native_glyph.glyph_id,
            .codepoint = native_glyph.codepoint,
            .fallback = native_glyph.fallback != 0,
            .color_glyph_kind = if (native_glyph.color_glyph_kind != 0) .color else .monochrome,
            .x_px = native_glyph.x_px,
            .advance_px = native_glyph.advance_px,
            .left_overhang_px = native_glyph.left_overhang_px,
            .font_name = native_glyph.font_name,
            .point_size = point_size,
            // 편집기 줄 높이는 셀에서 오고(호출자가 device px로 준다), 아니면 토큰 line height다.
            // 이 값이 래스터 높이와 세로 정렬 기준이라 폰트와 함께 커져야 글자가 안 잘린다.
            .line_height_px = if (run.line_height_px) |lh|
                @floatFromInt(lh)
            else
                @floatFromInt(chrome.ui.typography.lineHeightPx(run.role, scale_milli)),
            .origin = run.origin,
            .foreground = run.foreground,
            .run_index = 0,
        };
    }
    return out;
}

/// `shapeUnresolvedRun` 의 비-macOS 갈래. **크기·줄 높이·색은 부르는 쪽이 이미 정했다** — 여기서는
/// 글리프만 만들어 중립 `UnresolvedGlyph` 로 옮긴다.
///
/// macOS 가 `CTLine` 하나로 하는 일을 플랫폼 이음매가 한다. 폴백 목록·번들 폰트 컬렉션·말줄임은
/// 그쪽이 소유한다(docs/windows-platform.md §2m.13·§2m.18).
fn shapeViaSeam(
    allocator: std.mem.Allocator,
    run: Request.Run,
    face: Face,
    scaled_size: f64,
    point_size: u16,
    capacity: usize,
) ![]UnresolvedGlyph {
    const records = try allocator.alloc(maru.text_shaper.GlyphRecord, capacity);
    defer allocator.free(records);

    const count = maru.text_shaper.shape(allocator, .{
        .text = run.text,
        .family = face.family,
        .fallback_csv = face.fallback,
        .size_px = @floatCast(scaled_size),
        // **이음매의 weight 는 CSS 축(100~900)이다** — `weight()` 가 내는 0/1 은 CoreText 브리지의
        // 기호값이라 여기 넣으면 안 된다. DirectWrite 는 0 을 거절하고, 그 실패가
        // `CoreTextChromeTextShapeFailed` 로 접혀 **그 run 만 조용히 사라진다**(실측: 요약 숫자와
        // 파일 행의 디렉터리 꼬리가 안 나왔다).
        .weight = seamWeight(run.role),
        .max_width_px = @floatFromInt(run.max_width_px),
        .anchor_tail = run.anchor == .tail,
    }, records) catch return error.CoreTextChromeTextShapeFailed;

    const out = try allocator.alloc(UnresolvedGlyph, count);
    for (records[0..count], out) |rec, *glyph| {
        glyph.* = .{
            .glyph_id = rec.glyph_id,
            .codepoint = rec.codepoint,
            .fallback = rec.fallback,
            .color_glyph_kind = if (rec.color) .color else .monochrome,
            .x_px = rec.x_px,
            .advance_px = rec.advance_px,
            .left_overhang_px = rec.left_overhang_px,
            .font_name = rec.font_name,
            .point_size = point_size,
            .line_height_px = if (run.line_height_px) |lh|
                @floatFromInt(lh)
            else
                @floatFromInt(chrome.ui.typography.lineHeightPx(run.role, 1000)),
            .origin = run.origin,
            .foreground = run.foreground,
            .run_index = 0,
        };
    }
    return out;
}

test "[실측] Windows: 같은 공개 경로가 이음매를 거쳐 글리프를 낸다" {
    // **이 슬라이스의 진짜 판정이다.** 이음매와 브리지를 각각 테스트하는 것으로는 둘이
    // 이어졌는지를 모른다 — macOS 가 쓰는 것과 **같은** `prepareRequest`→`shapeRequest` 를 타서
    // 글리프가 나오는지를 본다.
    if (@import("builtin").os.tag != .windows) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "Agent 세션 기록" }};
    const ops = [_]chrome.draw.Op{.{ .text = .{
        .origin = .{ .x = 12, .y = 8 },
        .runs = &runs,
        .role = .surface_fg,
        .text_role = .dock_heading,
        .max_cols = 40,
    } }};
    const tokens = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 },
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 10, .g = 10, .b = 10 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 50, .g = 50, .b = 50 },
        .search_match = .{ .r = 20, .g = 120, .b = 255 },
        .search_match_current = .{ .r = 255, .g = 180, .b = 20 },
        .selection = .{ .r = 60, .g = 80, .b = 120 },
        .cursor = .{ .r = 255, .g = 255, .b = 255 },
        .terminal_background = .{ .r = 255, .g = 255, .b = 255 },
        .accent = .{ .r = 20, .g = 120, .b = 255 },
    });
    var request = try prepareRequest(allocator, 44, &ops, &tokens, 16, .{});
    defer request.deinit(allocator);
    var artifact = try shapeRequest(allocator, &request, 1000);
    defer artifact.deinit(allocator);

    // 문자 수만큼은 나와야 한다 — 0 이 아니라는 것만 보면 한 글자만 나와도 통과한다.
    try std.testing.expect(artifact.glyphs.len >= 10);
    var advance_sum: f32 = 0;
    var fallback_count: usize = 0;
    for (artifact.glyphs) |g| {
        advance_sum += g.advance_px;
        if (g.fallback) fallback_count += 1;
    }
    // **x 가 오른쪽으로 간다.** 모두 0 이면 레이아웃이 없는 것이라 화면에 겹쳐 찍힌다.
    try std.testing.expect(artifact.glyphs[artifact.glyphs.len - 1].x_px > artifact.glyphs[0].x_px);
    try std.testing.expect(advance_sum > 0);
    std.debug.print(
        "[실측] Windows chrome 셰이핑: 글리프 {d} · 폭 합 {d:.1}px · 폴백 {d} · 폰트 {s}\n",
        .{ artifact.glyphs.len, advance_sum, fallback_count, std.mem.sliceTo(&artifact.glyphs[0].font_name, 0) },
    );
}

test "owned request shapes proportional text before renderer registry resolution" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const runs = [_]chrome.draw.Run{.{ .text = "Agent 세션 기록" }};
    const ops = [_]chrome.draw.Op{.{ .text = .{
        .origin = .{ .x = 12, .y = 8 },
        .runs = &runs,
        .role = .surface_fg,
        .text_role = .dock_heading,
        .max_cols = 40,
    } }};
    const tokens = chrome.Tokens.rich(.{
        .diff_added = .{ .r = 64, .g = 160, .b = 64 }, // 픽스처: 비교 밴드 입력(§7)
        .diff_removed = .{ .r = 176, .g = 64, .b = 64 },
        .foreground = .{ .r = 240, .g = 240, .b = 240 },
        .sidebar_background = .{ .r = 10, .g = 10, .b = 10 },
        .sidebar_foreground = .{ .r = 220, .g = 220, .b = 220 },
        .sidebar_active = .{ .r = 50, .g = 50, .b = 50 },
        .search_match = .{ .r = 20, .g = 120, .b = 255 },
        .search_match_current = .{ .r = 255, .g = 180, .b = 20 },
        .selection = .{ .r = 60, .g = 80, .b = 120 },
        .cursor = .{ .r = 255, .g = 255, .b = 255 },
        .terminal_background = .{ .r = 255, .g = 255, .b = 255 }, // 픽스처: 터미널 배경 입력(§4.1b terminal_bg)
        .accent = .{ .r = 20, .g = 120, .b = 255 },
    });
    var request = try prepareRequest(allocator, 44, &ops, &tokens, 16, .{});
    defer request.deinit(allocator);
    var artifact = try shapeRequest(allocator, &request, 2000);
    defer artifact.deinit(allocator);
    try std.testing.expect(artifact.glyphs.len > 0);
}

// 이 테스트가 증명하는 것: chrome 텍스트 셰이핑이 run마다 face를 새로 만들지 않는다.
//
// 왜 터미널에서 중요한가 — 세션 도크의 텍스트는 캐시가 miss한 프레임에서 **렌더 tick 안에서 동기로**
// 셰이핑된다(`AppSession.shapeAgentSessionDockRichText`). 그 비용이 프레임 예산 안에 있는 유일한 이유가
// 브리지의 face 재사용이다. 예전처럼 run마다 `CTFontCreateUIFontForLanguage` +
// `CTFontCreateCopyWithSymbolicTraits`를 다시 부르면 같은 프레임이 3배 이상 비싸지고, 그 상태로는 스크롤
// 중 매 프레임 셰이핑을 감당할 수 없어 결국 글자가 사라지는 옛 비동기 구조로 되돌아가게 된다.
//
// wall-clock 비율은 fresh process에서도 CoreText/scheduler 변동 때문에 같은 코드가 1.0~2.7배로 흔들렸다.
// 따라서 이 테스트는 product C cache branch의 hidden monotonic counter를 warm 호출 전후로 읽는다.
// warm 뒤 모든 run이 hit이고 miss가 0이라는 사실이 face 재사용을 직접 증명한다.
test "chrome text shaping reuses one face across roles instead of rebuilding it per run" {
    if (std.c.getenv("MARU_APP_HOST_FRESH_PROCESS_TESTS_AGGREGATE_SKIP") != null)
        return error.SkipZigTest;
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const roles = [_]chrome.ui.typography.ChromeTextRole{
        .dock_heading, .supporting, .control, .group_heading, .card_heading, .body, .metadata, .overline, .button_label,
    };

    // 두 요청은 텍스트·길이·run 수가 완전히 같고 role만 다르다. 따라서 차이는 face 생성 비용뿐이다.
    const Shape = struct {
        const run_count = 55;
        const sample_count = 21;
        const Sample = struct {
            median_ns: u64,
            hits: u64,
            misses: u64,
        };

        fn sample(gpa: std.mem.Allocator, clock_io: std.Io, varied_roles: bool, role_table: []const chrome.ui.typography.ChromeTextRole, scale_milli: u32) !Sample {
            const runs = try gpa.alloc(Request.Run, run_count);
            for (runs, 0..) |*run, index| run.* = .{
                .text = try gpa.dupe(u8, "세션 기록 도크 스크롤 측정"),
                .role = if (varied_roles) role_table[index % role_table.len] else .card_heading,
                .origin = .{ .x = 0, .y = 0 },
                // truncation 경로는 이 테스트의 대상이 아니므로 타지 않게 한다.
                .max_width_px = 1_000_000,
                .foreground = 0xffffff,
            };
            var request = Request{ .fingerprint = 0, .runs = runs };
            defer request.deinit(gpa);

            // face 캐시를 채우는 첫 호출은 정상 상태 비용이 아니다.
            var warm = try shapeRequest(gpa, &request, scale_milli);
            warm.deinit(gpa);

            var hits_before: u64 = 0;
            var misses_before: u64 = 0;
            bridge.maru_macos_coretext_chrome_font_cache_stats_for_test(&hits_before, &misses_before);

            var samples: [sample_count]u64 = undefined;
            for (&samples) |*elapsed_ns| {
                const start = std.Io.Clock.awake.now(clock_io).nanoseconds;
                var artifact = try shapeRequest(gpa, &request, scale_milli);
                elapsed_ns.* = @intCast(std.Io.Clock.awake.now(clock_io).nanoseconds - start);
                artifact.deinit(gpa);
            }
            var hits_after: u64 = 0;
            var misses_after: u64 = 0;
            bridge.maru_macos_coretext_chrome_font_cache_stats_for_test(&hits_after, &misses_after);
            std.mem.sort(u64, &samples, {}, std.sort.asc(u64));
            return .{
                .median_ns = samples[samples.len / 2],
                .hits = hits_after - hits_before,
                .misses = misses_after - misses_before,
            };
        }
    };

    const expected_hits = Shape.run_count * Shape.sample_count;
    const same_role = try Shape.sample(allocator, io, false, &roles, 2000);
    try std.testing.expectEqual(@as(u64, expected_hits), same_role.hits);
    try std.testing.expectEqual(@as(u64, 0), same_role.misses);

    const varied_role = try Shape.sample(allocator, io, true, &roles, 2000);
    try std.testing.expectEqual(@as(u64, expected_hits), varied_role.hits);
    try std.testing.expectEqual(@as(u64, 0), varied_role.misses);

    // 상한만 두고 축출을 안 하면 캐시는 `Cmd`+`+`/`-` 몇 번에 가득 찬다(dock scale이 폰트 크기를 따라가므로
    // 크기마다 role 9개가 새 항목이다). 그 뒤로는 매 run이 폰트를 다시 만드는 옛 경로로 **조용히** 되돌아가고
    // 그 상태가 영구히 남는다. 위 ratio는 이걸 못 잡는다 — 캐시가 막히면 두 측정이 **함께** 느려져 비율이
    // 그대로이기 때문이다. 그래서 용량을 넘길 만큼 여러 scale을 흘려보낸 뒤 같은 측정을 다시 한다.
    // 축출이 있으면 첫 iteration이 그 scale의 face를 다시 채워 이후가 hit이므로 median이 유지된다.
    var overflow_scale: u32 = 1100;
    while (overflow_scale <= 1900) : (overflow_scale += 100) {
        const overflow_sample = try Shape.sample(allocator, io, true, &roles, overflow_scale);
        try std.testing.expectEqual(@as(u64, expected_hits), overflow_sample.hits);
        try std.testing.expectEqual(@as(u64, 0), overflow_sample.misses);
    }
    // 측정 scale은 **한 번도 캐시된 적 없는** 값이어야 한다. 이미 들어갔던 scale로 재면 축출이 없어도
    // 초기 항목이 살아남아 hit이 나므로 판별이 안 된다(실제로 그렇게 통과했다).
    const after_overflow = try Shape.sample(allocator, io, true, &roles, 2100);
    try std.testing.expectEqual(@as(u64, expected_hits), after_overflow.hits);
    try std.testing.expectEqual(@as(u64, 0), after_overflow.misses);

    // timing은 판정에 쓰지 않지만 0이 아니어야 실제 product shape 호출이 수행된 것이다.
    try std.testing.expect(same_role.median_ns > 0);
    try std.testing.expect(varied_role.median_ns > 0);
    try std.testing.expect(after_overflow.median_ns > 0);
}

test "role 마다 이음매 굵기가 있다 — 표가 늘면 여기서 걸린다" {
    // 진짜 방어는 타입이다(`Weight` enum — 기호값 0 은 컴파일이 안 된다). 이 테스트가 보는 것은
    // **표가 늘어났을 때 여기가 같이 늘었는가** 하나뿐이다.
    for (std.enums.values(chrome.ui.typography.ChromeTextRole)) |role| {
        const want: maru.text_shaper.Weight = switch (chrome.ui.typography.token(role).weight) {
            .regular => .regular,
            .medium => .medium,
            .semibold => .semibold,
        };
        try std.testing.expectEqual(want, seamWeight(role));
    }
}
