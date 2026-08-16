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

/// 컴포넌트는 native 폰트 메트릭을 소유하지 않은 채로 텍스트 내용 묶음을 선언할 수 있다. 평범한
/// 텍스트는 `.origin`을 유지하고, 측정된 label 묶음과 등록 SVG 전용 컨트롤은 platform text worker가
/// 최종 논리 rect에서 해석한다.
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
    /// 이 오버레이의 셀을 px 사각(backing, 좌상단)으로 클리핑한다 — lowering이 OverlayRaster.clip_rect로 모으면
    /// replace가 그 셀들에 `clip_index`를 달고 renderer가 해당 draw run에 setScissorRect로 적용한다(ABI v169).
    /// 한 오버레이에 최대 1개(여러 개면 마지막이 이김). 그리지 않으니 bounding-box·셀에는 영향 없다.
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
        /// semantic typography를 renderer 산출물까지 실어 보낸다. 지금의 셀 lowerer는 legacy 기본값을
        /// 유지하고, 측정 기반 Chrome 경로가 색/bold/원본 텍스트에서 추측하는 대신 이 값을 쓴다.
        text_role: typography.ChromeTextRole = .body,
        /// 컴포넌트가 소유하는 가용 폭과 넘침 기준점이다. legacy 셀 lowering은 여전히 여기서 격자
        /// 계획을 유도하고, 측정 기반 rich 텍스트는 손대지 않은 원본을 받아 같은 제약을 device 픽셀로
        /// 쓴다. 이 값을 semantic op에 두어야 두 경로가 제목/검색 잘라내기 정책을 각자 또 만들지 않는다.
        max_cols: u16 = std.math.maxInt(u16),
        anchor: text_layout.Anchor = .head,
        /// **이 폰트 크기로 그린다**(편집기 전용 — docs/native-editor-layering.md §2.0).
        ///
        /// `typography` 토큰의 point size는 chrome 고정값(pt)이라 편집기 폰트를 키워도 그대로다.
        /// 그러면 셀만 커지고 글자는 안 커지는 화면이 된다(실측으로 확인한 결함). 이 값이 있으면
        /// 그것을 쓰고, 없으면(도크·탭 등) 기존 토큰 경로 그대로다.
        ///
        /// **단위는 device 픽셀**이며 백엔드는 여기에 backing scale을 다시 곱하지 않는다 — 호출자가
        /// 이미 반영해 넘긴다. **셀 높이에서 역산하지 않는 이유**: line height와 폰트 크기의 비율은
        /// 폰트마다 달라 역산이 근사가 된다. 제품은 사용자 `font.size`를 이미 알고 있으므로 그 값을
        /// 그대로 주면 되고, 역산이 필요한 쪽(Lab 같은 합성 픽스처)이 스스로 계산해 넘긴다.
        font_px: ?u16 = null,
        /// 이 줄의 높이(device px, 편집기 전용). `font_px`와 **짝**이며 둘 다 있거나 둘 다 없다.
        ///
        /// 없으면 `typography` 토큰의 line height가 쓰이는데, 그것은 chrome 고정값이라 편집기 폰트를
        /// 키우면 **글자가 줄 상자보다 커져 래스터가 잘린다**(`raster_height_px`가 이 값에서 나온다).
        /// 세로 정렬 기준이기도 하므로 폰트와 함께 커져야 한다.
        line_height_px: ?u16 = null,
        /// 셀 폭(device px, 편집기 전용). 있으면 백엔드가 글자 x를 **폰트 advance가 아니라 셀
        /// 인덱스**로 놓는다 — 글자마다 셀 폭(EAW)을 누적해 몇 번째 칸인지 센다. 등폭 폰트도
        /// advance가 셀 폭과 미세하게 달라(7.8px vs 8px) 그대로 두면 두 번째 글자부터 격자를
        /// 벗어난다. `font_px`·`line_height_px`와 함께 온다.
        cell_w_px: ?u16 = null,
        wide_icons: bool = false,
        /// worker가 아이콘+label 묶음을 가운데 정렬할 때는 픽셀 제약이 필요하다. `max_cols`는 legacy
        /// 격자 폴백으로 남고, rich 전용 action은 가용 폭을 terminal 셀 단위로 내림하지 않고 최종
        /// content rect를 그대로 보존할 수 있다.
        max_width_px: ?u32 = null,
        placement: TextPlacement = .origin,
        /// 이 op이 컴포넌트의 **스크롤 영역**에 속하는지. 스크롤 뷰포트 사각형 자체는 backend가 프레임마다
        /// 알고 있으므로 여기 싣지 않는다 — 그러면 스크롤할 때마다 semantic op이 달라져 shaping 캐시가
        /// 통째로 무효화된다. 소속은 스크롤해도 바뀌지 않는 사실이라 캐시 키에 안전하게 들어간다.
        /// backend는 이 표시가 있는 glyph만 뷰포트로 잘라, 반쯤 걸친 행도 픽셀 단위로 정확히 보인다.
        scroll_clipped: bool = false,
        /// 이 텍스트가 스크롤 콘텐츠 **위에 떠 있는지**(상단 고정 헤더). `scroll_clipped`와 배타적이다:
        /// 스크롤 평행이동을 받지 않으므로 y가 절대값이고(캐시 키에 그대로 들어간다), 그러면서도
        /// 스크롤 뷰포트 밖으로 새면 안 되므로 잘리기는 한다 — 그 사각형은 아래 `clip`으로 싣는다.
        /// 이 op의 y는 이미 키에 있으므로 rect를 함께 실어도 캐시가 더 무효화되지 않는다.
        ///
        /// 이 값이 필요한 이유는 quad와 text가 **서로 다른 레이어**이기 때문이다. 나중에 그린 헤더
        /// 배경 quad가 앞서 그린 카드 글자를 덮지 못하므로, 헤더 밑을 지나는 글자는 backend가 잘라
        /// 없애야 한다(그 반대편이 이 플래그다 — 헤더 자신은 그 밴드 안에서 살아남는다).
        above_scroll: bool = false,
        /// 이 텍스트를 자를 뷰포트(published tree의 `effective_clip`을 그대로 전달한 값).
        ///
        /// measured(픽셀) 경로는 이 값을 쓰지 않는다 — `scroll_clipped`와 backend가 아는 뷰포트로
        /// glyph마다 부분 잘림을 하며(`chrome/system_text.zig`의 `appendGpuGlyphs`), 여기 rect를 실으면
        /// 스크롤 1px마다 shaping 캐시 키가 바뀐다. **셀 격자로 lowering하는 경로**(`metal_lowering`의
        /// `placeText` — 모달)는 그 배선이 없으므로 이 rect로 자르되, 셀 단위라 부분 잘림이 불가능해
        /// origin이 밖이면 통째로 버린다.
        ///
        /// `above_scroll`인 op만은 예외로 measured 경로도 이 rect를 쓴다(위 설명 참조).
        ///
        /// Chrome Lab은 **measured 경로**다(제품 도크와 같은 `shapeOps`+`appendGpuGlyphs`를 탄다).
        /// 예전 Lab 전용 셀 lowerer 시절의 서술이 여기 남아 있었는데, 그 상태로는 이 rect를 통째로
        /// 비워도 Lab 캡처가 픽셀 하나 바뀌지 않는다(2026-08-06 확인). 도크 텍스트의 잘림을 보는 것은
        /// `scroll_clipped`와 골든이다.
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
