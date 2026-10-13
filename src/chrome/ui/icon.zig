//! 아이콘의 **크기 토큰**(디자인 시스템, docs/chrome-strategy.md §9.7).
//!
//! 이름↔codepoint 대응은 생성물 `src/icons.zig`가, 합성·다운스케일 같은 **렌더 계약**은
//! `renderer/icon_glyph.zig`가 갖는다. 이 파일은 그 사이에 빠져 있던 한 조각 — **"얼마나 크게 그리는가"**를
//! 소유한다.
//!
//! ## 무엇이 언제 정해지는가 (이 축의 전제)
//!
//! coverage 마스터는 **alpha 한 채널**이다(빌드타임에 SVG를 48px로 래스터해 굽는다). 그래서
//!   - *빌드타임에 굳는 것*: 모양·stroke 굵기·여백(viewBox). 런타임에 못 바꾼다 → 변형은 자산을 하나 더 굽고
//!     `icons.Fit` 축으로 고른다.
//!   - *런타임에 정하는 것*: **색**(셰이더가 coverage×전경색 → `ColorRole`로 테마 자동)과 **크기**(정사각 마스터를
//!     슬롯에 area-average 다운스케일).
//! 즉 크기는 런타임 축이다. 이 파일은 **여러 컴포넌트가 공유하는** 값의 단일 출처다 — 예전엔 같은 값이
//! `ui/button`(18/14pt)·`session_dock/types`(18pt 두 번)·`app_session`(셀×1.7)에 흩어져 있었다.
//!
//! **컴포넌트 고유 치수는 여전히 그 컴포넌트가 갖는다**(공유되지 않는 값을 여기로 올리면 이 파일이 남의
//! 레이아웃을 결정하게 된다). 예: Session Dock의 새로고침 버튼 hit target 24pt·그룹 disclosure 20pt
//! (`session_dock/types.zig`). 그 값이 **두 번째 소비처를 얻는 순간** 여기로 올린다 — 그게 18pt가 여기 온 이유다.
//!
//! ## 두 좌표계
//!
//! chrome에는 아이콘을 놓는 자리가 둘이고, 단위가 다르다(하나의 enum으로 묶으면 한쪽에만 있는 값이
//! 다른 쪽에 가짜로 생긴다).
//!   - **UiNode 트리**(session_dock·`ui/button`): 슬롯 한 변을 **logical pt**로 선언한다 → `Size`/`extentPt`.
//!   - **셀 그리드 chrome**(사이드바 헤더·도크 토글): 셀 하나에 앉히되 **셀보다 크게** 굽는다 →
//!     `cell_raster_scale_milli`. 셀 크기로 굽고 GPU에서 늘리면 anti-alias가 번지므로 목표 px로 직접 래스터한다.

const std = @import("std");

/// UiNode 트리에서 아이콘 슬롯 한 변(logical pt). 값이 아니라 **밀도**를 고른다.
pub const Size = enum {
    /// 기본 command·행 아이콘. Session Dock의 action row·헤더 affordance가 이 밀도다.
    default,
    /// 밀집한 utility 자리. 슬롯만 줄고 hit target은 `ButtonSize`가 따로 보장한다.
    compact,

    pub fn extentPt(self: Size) u16 {
        return switch (self) {
            .default => 18,
            .compact => 14,
        };
    }
};

/// 셀 그리드 chrome이 한 셀 아이콘을 굽는 배율(밀리). 1.7×는 헤더 아이콘이 옆 글자보다 또렷하게 보이도록
/// 실측으로 고른 값이다(셀 크기로 굽고 확대하면 partial-alpha가 ~0.69, 목표 px 직접 래스터는 ~0.33 —
/// `coretext_smoke.m` 측정 test). **렌더러는 이 값을 다시 적지 않는다** — Zig 가 그 크기로 구운 글리프의 셀에
/// cell-raster role 을 싣고(`metal_frame.native_cell_role_cell_raster_icon`), `maru_metal_renderer.m` 은 「atlas 크기 ÷
/// 셀 크기」로 quad 를 키운다(텍스처가 quad 에 1:1). `tests/boundary/icon_literals.zig` 가 `.m` 에 사본이 되살아나지 않는지 본다.
pub const cell_raster_scale_milli: u32 = 1700;

/// 셀 한 변(px)을 위 배율로 키운 래스터 슬롯 크기. u16 슬롯 한계로 clamp한다(폰트를 아주 키운 창).
pub fn cellRasterExtentPx(cell_extent_px: u32) u32 {
    const scaled = @as(u64, cell_extent_px) * cell_raster_scale_milli / 1000;
    return @intCast(@min(scaled, std.math.maxInt(u16)));
}

/// 셀 하나(`cw × ch`)에 위 배율을 선언해 구운 **등록 아이콘의 잉크 박스 한 변**(px) — 정사각 마스터가 놓이는 자리다(SVG
/// viewBox 여백 때문에 실제로 칠해진 픽셀은 그 안쪽이다 — 소비처는 이 값을 상한으로 쓴다).
///
/// 슬롯은 `cellRasterExtentPx(cw) × cellRasterExtentPx(ch)` 지만, 합성 아이콘(`renderer/icon_glyph.fillCoverage`)은 정사각
/// 마스터를 슬롯 안 최대 정사각(`min(w, h)`)으로 **가운데** 둔다. 그래서 셀이 세로로 긴 보통 폰트에서 잉크는 **폭 기준**이고,
/// 잉크 중심은 슬롯 중심이다(정수 내림으로 ±0.5px). 잉크에 무언가를 맞추는 자리(hover pill 높이·히트 사각형 바닥)는 슬롯
/// 높이가 아니라 이 값을 쓴다 — 슬롯 높이로 셈한 자리가 두 번 결함이 됐다(#4410 도크 토글 판 Retina 2px · #4421 헤더 pill
/// 위 4px 잘림). `tests/boundary/icon_literals.zig` 가 슬롯 함수·배율을 쓰는 파일을 전수 허용 목록으로 묶고, app_session 판정자가
/// 실제 `fillCoverage` 가 이 박스 안에만 칠하는지 본다(chrome 은 renderer 를 import 하지 않아 그 판정은 platform 쪽에 있다).
pub fn cellRasterIconInkPx(cell_width_px: u32, cell_height_px: u32) u32 {
    return @min(cellRasterExtentPx(cell_width_px), cellRasterExtentPx(cell_height_px));
}

/// 컴포넌트가 **자기 것으로 선언한** 아이콘 run이 차지하는 셀 수. EAW 파생이 아니라 선언이다 — 등록 아이콘은
/// 셀에 꽉 차게 합성되므로 한 칸에 넣으면 옆 글자와 붙어 보인다(`wide_icons=true`인 run에만 적용되고,
/// 사용자·세션 문자열에 우연히 섞인 PUA는 폭이 1이라 caret·말줄임이 어긋나지 않는다).
pub const chrome_run_span: u2 = 2;

test "icon: 크기 토큰이 밀도 순서를 지킨다" {
    try std.testing.expect(Size.default.extentPt() > Size.compact.extentPt());
}

test "icon: 셀 래스터 배율은 셀보다 크고 u16 슬롯에서 saturate한다" {
    try std.testing.expectEqual(@as(u32, 17), cellRasterExtentPx(10)); // 10px 셀 → 17px 슬롯
    try std.testing.expect(cellRasterExtentPx(20) > 20);
    try std.testing.expectEqual(@as(u32, 0), cellRasterExtentPx(0));
    try std.testing.expectEqual(@as(u32, std.math.maxInt(u16)), cellRasterExtentPx(std.math.maxInt(u32)));
}

test "icon: 잉크 한 변은 슬롯의 짧은 변이다 — 세로로 긴 셀은 폭 기준" {
    try std.testing.expectEqual(@as(u32, 13), cellRasterIconInkPx(8, 18)); // 1x 기본: 슬롯 13 × 30 → 잉크 13
    try std.testing.expectEqual(@as(u32, 28), cellRasterIconInkPx(17, 37)); // Retina: 슬롯 28 × 62 → 잉크 28
    try std.testing.expectEqual(@as(u32, 34), cellRasterIconInkPx(20, 20)); // 정사각 셀은 슬롯 = 잉크
    try std.testing.expectEqual(@as(u32, 17), cellRasterIconInkPx(20, 10)); // 가로로 긴 셀은 높이 기준
    try std.testing.expectEqual(@as(u32, 0), cellRasterIconInkPx(0, 18));
}
