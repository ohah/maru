//! Chrome semantic draw 어휘 — backend-neutral. 컴포넌트는 ChromeDraw만 뱉고, platform 백엔드가
//! 이걸 그 플랫폼의 셀로 lowering한다(tui→NativeMetalCell, rich→GPU 프리미티브). 좌표는 **픽셀**
//! (rich의 sub-cell 정밀도 대비). 컴포넌트는 NativeMetalCell·Metal·atlas를 모른다.
//! 단일 출처: docs/chrome-strategy.md §5.2, docs/layering-and-portability.md.

const tokens = @import("tokens.zig");

/// 픽셀 좌표 한 점.
pub const Px = struct { x: i32, y: i32 };

/// 픽셀 사각형(x,y는 좌상단, w/h는 크기).
pub const Rect = struct { x: i32, y: i32, w: u32, h: u32 };

/// 어느 변을 그릴지(focus 테두리·부분 선). 전부 false면 무동작.
pub const Sides = struct {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
};

/// 합성 레이어/Z-순서. platform 백엔드가 layer별로 replace()의 슬롯(사이드바·pane chrome·overlay·모달)에
/// 라우팅한다. 같은 layer 안에서는 ops 순서가 Z(뒤가 위).
pub const Layer = enum { sidebar, pane_chrome_bg, pane_overlay, modal };

/// 텍스트 한 조각(스타일 변화 단위). 멀티-run은 한 줄 안의 스타일 구간들.
pub const Run = struct { text: []const u8, bold: bool = false };

/// 한 그리기 명령(semantic). 색은 값이 아니라 ColorRole — 백엔드가 토큰으로 해석한다.
pub const Op = union(enum) {
    fill: Fill,
    border: Border,
    rule: Rule,
    text: Text,

    /// 사각 영역 채우기(밴드·탭 배경·hover·drop-zone). alpha<0xFF면 반투명 합성.
    pub const Fill = struct { rect: Rect, role: tokens.ColorRole, alpha: u8 = 0xFF };
    /// 사각형의 일부 변에 선(focus 테두리). tui는 reserved-kind 띠, rich는 실제 테두리/radius로 lowering.
    pub const Border = struct { rect: Rect, sides: Sides, role: tokens.ColorRole };
    /// 한 줄(divider). 수평/수직은 from/to로 결정.
    pub const Rule = struct { from: Px, to: Px, role: tokens.ColorRole };
    /// 텍스트(탭 제목·팝업·Notice). origin = 베이스라인이 아니라 좌상단 픽셀.
    pub const Text = struct { origin: Px, runs: []const Run, role: tokens.ColorRole };
};

/// 한 컴포넌트가 한 프레임에 내는 출력 = (레이어, 그 레이어에 그릴 ops). ops 슬라이스 수명은 호출자
/// (host)가 프레임 arena로 소유한다.
pub const ChromeDraw = struct { layer: Layer, ops: []const Op };
