//! Chrome semantic draw 어휘 — backend-neutral. 컴포넌트는 ChromeDraw만 뱉고, platform 백엔드가
//! 이걸 그 플랫폼의 셀로 lowering한다(tui→NativeMetalCell, rich→GPU 프리미티브). 좌표는 **픽셀**
//! (rich의 sub-cell 정밀도 대비). 컴포넌트는 NativeMetalCell·Metal·atlas를 모른다.
//! 단일 출처: docs/chrome-strategy.md §5.2, docs/layering-and-portability.md.

const std = @import("std");
const tokens = @import("tokens.zig");
const Rgb = @import("../color.zig").Rgb;
const typography = @import("ui/typography.zig");
const text_layout = @import("text_layout.zig");

/// 픽셀 좌표 한 점.
pub const Px = struct { x: i32, y: i32 };

/// 사방 패딩(px). content rect를 선언적으로 계산하는 EdgeInsets(CSS box model·Flutter EdgeInsets 개념 — chrome 한정,
/// 터미널 셀 grid와 무관). 컴포넌트가 x+gap·w-2gap 같은 좌표 산술 대신 rect.inset(insets)으로 패딩을 둔다.
pub const EdgeInsets = struct { left: u16 = 0, right: u16 = 0, top: u16 = 0, bottom: u16 = 0 };

/// 픽셀 사각형(x,y는 좌상단, w/h는 크기).
pub const Rect = struct {
    x: i32,
    y: i32,
    w: u32,
    h: u32,
    /// 사방 insets만큼 안쪽으로 줄인 content rect(패딩). w/h는 saturating(insets 합이 크면 0).
    pub fn inset(self: Rect, e: EdgeInsets) Rect {
        return .{
            .x = self.x + @as(i32, e.left),
            .y = self.y + @as(i32, e.top),
            .w = self.w -| @as(u32, e.left) -| @as(u32, e.right),
            .h = self.h -| @as(u32, e.top) -| @as(u32, e.bottom),
        };
    }
    /// inset의 대칭 — 사방 insets만큼 바깥으로 키운 rect(배경 박스를 콘텐츠보다 크게: 모달 패딩 등 '역패딩').
    /// x/y는 빼고 w/h는 더한다. x/y는 i32라 콘텐츠가 화면 가장자리 근처면 음수가 될 수 있다(호출자가 배치 보장).
    pub fn outset(self: Rect, e: EdgeInsets) Rect {
        return .{
            .x = self.x - @as(i32, e.left),
            .y = self.y - @as(i32, e.top),
            .w = self.w + @as(u32, e.left) + @as(u32, e.right),
            .h = self.h + @as(u32, e.top) + @as(u32, e.bottom),
        };
    }
};

/// 어느 변을 그릴지(focus 테두리·부분 선). 전부 false면 무동작.
pub const Sides = struct {
    top: bool = false,
    right: bool = false,
    bottom: bool = false,
    left: bool = false,
};

/// 합성 레이어/Z-순서. platform 백엔드가 layer별로 replace()의 슬롯(사이드바·pane chrome·overlay·모달)에
/// 라우팅한다. 같은 layer 안에서는 ops 순서가 Z(뒤가 위).
pub const Layer = enum { sidebar, pane_overlay, modal };

/// 텍스트 한 조각(스타일 변화 단위). 멀티-run은 한 줄 안의 스타일 구간들.
pub const Run = struct { text: []const u8, bold: bool = false };

/// The component may declare a text-content group without taking ownership of native font
/// metrics. Ordinary text keeps `.origin`; the platform text worker resolves measured label
/// groups and registered SVG-only controls from the final logical rect.
pub const TextPlacement = union(enum) {
    origin,
    center_in_rect: Rect,
    icon_in_rect: struct {
        content_rect: Rect,
        icon_codepoint: u21,
        icon_extent_px: u16,
    },
    leading_icon_group: struct {
        content_rect: Rect,
        icon_codepoint: u21,
        icon_extent_px: u16,
        gap_px: u16,
    },
};

/// 한 그리기 명령(semantic). 색은 값이 아니라 ColorRole — 백엔드가 토큰으로 해석한다.
pub const Op = union(enum) {
    fill: Fill,
    border: Border,
    rule: Rule,
    text: Text,
    quad: Quad,
    swatch: Swatch,
    /// 모달 오버레이를 이 px 사각(backing, 좌상단)으로 클리핑한다 — lowering이 OverlayRaster.clip_rect로 모아
    /// MetalFrame.modal_clip으로 흘리고 renderer가 모달 셀 draw에 setScissorRect로 적용한다. 한 오버레이에 최대
    /// 1개(여러 개면 마지막이 이김). 그리지 않으니 bounding-box·셀에는 영향 없다. 부분 카드 픽셀 스크롤(알림 패널
    /// 등) 재사용 인프라 — 컴포넌트 적용은 후속.
    clip: Rect,

    /// 사각 영역 채우기(밴드·탭 배경·hover·drop-zone). alpha<0xFF면 반투명 합성.
    pub const Fill = struct { rect: Rect, role: tokens.ColorRole, alpha: u8 = 0xFF };
    /// **literal RGB** 색 견본(color picker 스와치). 다른 op은 색을 ColorRole(테마 토큰)로 두지만, 스와치는 "이
    /// 색이 무엇인지"를 그대로 보여주는 값 미리보기라 role이 아니라 원색을 싣는다(의도적 예외 — config-gui §6.2 결정).
    /// 백엔드가 셀 bg/quad에 이 RGB를 그대로 칠한다. corner_radii(Quad와 동형)가 0이면 셀 bg(tui), >0이면 둥근
    /// GPU quad(rich) — 컴포넌트가 props.shape에서 읽어 채운다(tui=0 직각, rich>0 둥근 칩, C4b 분기 동형).
    pub const Swatch = struct { rect: Rect, rgb: Rgb, corner_radii: [4]u16 = .{ 0, 0, 0, 0 } };
    /// 사각형의 일부 변에 선(focus 테두리). tui는 reserved-kind 띠, rich는 실제 테두리/radius로 lowering.
    pub const Border = struct { rect: Rect, sides: Sides, role: tokens.ColorRole };
    /// 한 줄(divider). 수평/수직은 from/to로 결정.
    pub const Rule = struct { from: Px, to: Px, role: tokens.ColorRole };
    /// 텍스트(탭 제목·팝업·Notice). origin = 베이스라인이 아니라 좌상단 픽셀.
    /// `wide_icons`는 이 컴포넌트가 직접 소유한 등록 Chrome SVG glyph만 2셀로 측정·lower하라는
    /// 명시적 opt-in이다. 사용자/세션 텍스트는 false를 유지해 우연한 PUA가 레이아웃을 바꾸지 않는다.
    pub const Text = struct {
        origin: Px,
        runs: []const Run,
        role: tokens.ColorRole,
        /// Semantic typography is carried to the renderer artifact.  The current cell lowerer
        /// keeps its legacy default; the measured Chrome path consumes this instead of guessing
        /// from color/bold/source text.
        text_role: typography.ChromeTextRole = .body,
        /// The component-owned available width and overflow anchor.  Legacy cell lowering still
        /// derives its grid plan here, while measured rich text receives the untouched source and
        /// uses the same constraint in device pixels.  Keeping this on the semantic op prevents
        /// either path from inventing a second title/search truncation policy.
        max_cols: u16 = std.math.maxInt(u16),
        anchor: text_layout.Anchor = .head,
        wide_icons: bool = false,
        /// Pixel constraint is needed when the worker centres an icon+label group.  `max_cols`
        /// remains the legacy grid fallback; a rich-only action can preserve the final content
        /// rect instead of rounding its available width down to terminal cells.
        max_width_px: ?u32 = null,
        placement: TextPlacement = .origin,
        /// 이 op이 컴포넌트의 **스크롤 영역**에 속하는지. 스크롤 뷰포트 사각형 자체는 backend가 프레임마다
        /// 알고 있으므로 여기 싣지 않는다 — 그러면 스크롤할 때마다 semantic op이 달라져 shaping 캐시가
        /// 통째로 무효화된다. 소속은 스크롤해도 바뀌지 않는 사실이라 캐시 키에 안전하게 들어간다.
        /// backend는 이 표시가 있는 glyph만 뷰포트로 잘라, 반쯤 걸친 행도 픽셀 단위로 정확히 보인다.
        scroll_clipped: bool = false,
        /// 이 텍스트를 자를 뷰포트(published tree의 `effective_clip`을 그대로 전달한 값).
        ///
        /// measured(픽셀) 경로는 이 값을 쓰지 않는다 — `scroll_clipped`와 backend가 아는 뷰포트로 자르며,
        /// 여기 rect를 실으면 스크롤 1px마다 shaping 캐시 키가 바뀐다. **셀 격자로 lowering하는 경로**
        /// (Chrome Lab·모달)는 그 배선이 없으므로 이 rect로 자른다. 두 경로가 같은 clip을 못 보면 같은
        /// 행의 배경 quad는 잘리는데 글자만 남는 어긋난 그림이 나온다.
        clip: ?Rect = null,
    };

    /// C4b rich 박스 — 둥근 모서리·변별 테두리·solid/gradient 채움. tui 백엔드는 corner/border가 0이면
    /// Fill처럼 셀로 lowering하고, rich 백엔드는 GPU quad 프리미티브로 lowering한다. 모양 파라미터는
    /// 컴포넌트가 tokens.space에서 읽어 채운다(tui=0 → 직각, rich>0 → 둥근) — 컴포넌트 코드는 tui/rich
    /// 분기 없이 같다(C4a 색 분리와 동형). corner_radii=[tl,tr,br,bl], border_widths=[top,right,bottom,left](px).
    pub const Quad = struct {
        rect: Rect,
        fill_role: tokens.ColorRole,
        corner_radii: [4]u16 = .{ 0, 0, 0, 0 },
        border_widths: [4]u16 = .{ 0, 0, 0, 0 },
        border_role: ?tokens.ColorRole = null,
        fill_role_end: ?tokens.ColorRole = null, // gradient 끝 색(null=solid)
        gradient: GradientKind = .solid,
        alpha: u8 = 0xFF,
        /// 이 quad를 잘라야 할 뷰포트(published tree의 `effective_clip`을 **그대로** 전달한 값).
        /// 컴포넌트는 교차를 계산하지 않는다 — 자르는 일은 backend 몫이고, 그래야 잘린 변의 radius/border
        /// 보정 같은 세부를 컴포넌트마다 반복하지 않는다. `null`이면 클리핑 없음.
        ///
        /// 텍스트(`Text.scroll_clipped`)가 rect가 아니라 소속 bool을 싣는 것과 대비된다: 텍스트는 shaping
        /// 결과를 캐시하므로 rect를 실으면 스크롤 1px마다 캐시 키가 바뀐다. quad는 매 프레임 새로 만들어
        /// 캐시가 없으므로 rect를 직접 실는 쪽이 단순하다.
        clip: ?Rect = null,
    };
    pub const GradientKind = enum(u8) { solid = 0, vertical = 1, horizontal = 2 };
};

/// 한 컴포넌트가 한 프레임에 내는 출력 = (레이어, 그 레이어에 그릴 ops). ops 슬라이스 수명은 호출자
/// (host)가 프레임 arena로 소유한다.
pub const ChromeDraw = struct { layer: Layer, ops: []const Op };
