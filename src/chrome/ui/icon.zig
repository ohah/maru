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
//! 즉 크기는 런타임 축이고, 이 파일이 그 값의 단일 출처다. 예전엔 같은 값이 `ui/button`(18/14pt)·
//! `session_dock/types`(18pt 두 번)·`app_session`(셀×1.7)에 흩어져 있었다.
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
/// `coretext_smoke.m` 측정 test). **`maru_metal_renderer.m`의 quad 확대가 같은 값을 미러**하므로
/// `tests/boundary/icon_literals.zig`가 둘이 어긋나지 않는지 본다(어긋나면 텍스처와 quad 크기가 달라 흐려진다).
pub const cell_raster_scale_milli: u32 = 1700;

/// 셀 한 변(px)을 위 배율로 키운 래스터 슬롯 크기. u16 슬롯 한계로 clamp한다(폰트를 아주 키운 창).
pub fn cellRasterExtentPx(cell_extent_px: u32) u32 {
    const scaled = @as(u64, cell_extent_px) * cell_raster_scale_milli / 1000;
    return @intCast(@min(scaled, std.math.maxInt(u16)));
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
