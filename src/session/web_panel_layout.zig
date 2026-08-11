//! L2 session core — 웹 패널(WKWebView) rect·surface **생애주기 순수 계산**(OS·platform 무관). Phase 4a
//! (docs/plans/web-panel.md §10 4a·§11): WKWebView·렌더러·Swift를 건드리기 전에 "본문 rect 산출 / backing-px→pt
//! y-flip / surface diff"의 수학을 헤드리스 단위 테스트로 먼저 못박는다. 이 모듈이 그 세 계산의 **단일 출처**다.
//!
//! **좌표계 계약(§3·§11)**: 모든 ABI/backing 좌표는 **backing 픽셀·좌상단 원점**(y가 아래로 증가)이고,
//! WKWebView `frame`은 **포인트·좌하단 원점**(y가 위로 증가)이다. `pxTopLeftToPtBottomLeft`가 그 변환(스케일
//! 나눗셈 + y-flip)의 순수 수학을 소유한다. 생산 적용은 Phase 4c가 이 함수를 ABI로 export하거나 Swift가 이
//! 공식을 미러한다(그때 이 모듈이 단일 출처로 남게 함). y축 뒤집힘 주의 — [[metal-scissor-is-top-left-origin]]의
//! 좌상단/좌하단 혼동을 반복하지 않도록 top-left→bottom-left 뒤집힘을 명시적으로 계산한다.
//!
//! **범위(4a, 순수·헤드리스)**: rect/surface 생애주기 계약의 순수 계산만. WKWebView 부착(4c)·모달 렌더러
//! 분리(4b)·입력/responder(4d)·Swift·실 ABI export·렌더러는 범위 밖.
//!
//! **L2 순수**: std + split_tree(Rect) + control_surface(PanelKind wire enum)만 import한다 —
//! app/pty/platform/renderer/AppKit import 0(tests/boundary/imports.zig가 강제). OS 타입명 0(중립성 가드).

const std = @import("std");
const split_tree = @import("split_tree.zig");
const control_surface = @import("control_surface.zig");

/// 픽셀 사각형(backing px, 좌상단 origin). 레이아웃과 같은 타입을 써 pane rect·본문 rect가 한 좌표계에 산다.
pub const Rect = split_tree.Rect;

/// web 패널 종류(§3 panel_kind) — 단일 출처는 control_surface. diff가 created/reframed/shown 엔트리에 실어
/// Swift가 생성 시 markdown vs browser 설정(trust·config)을 고르게 한다.
pub const PanelKind = control_surface.PanelKind;

// ── ① 본문(content) rect (§5) ────────────────────────────────────────────────────────────────────────────

/// pane rect에서 WKWebView 본문으로 남길 영역을 얻기 위해 빼는 chrome 4방 inset(backing px). top=pane 탭 바
/// 높이(§5), left/right/bottom=divider seam·pane grip 등 Metal 노출로 남길 가장자리(§5 "본문 rect 한정"). 값은
/// L4(app_session)가 paneBarHeightPx·divider 두께에서 계산해 주입하고, 이 모듈은 기하만 한다(정책 분리).
/// layout_math.PaddingPx(window padding)와 필드 구조는 같으나 의미가 달라(chrome 노출 영역) 전용 타입으로 둔다.
pub const ChromeInset = struct { top: u32 = 0, left: u32 = 0, right: u32 = 0, bottom: u32 = 0 };

/// pane rect(backing px·좌상단)에서 chrome inset을 뺀 **본문 rect**(backing px·좌상단). paneTermRect의 inset
/// 기하와 동일하게 좌상으로 top/left만큼 들이고 폭/높이를 (left+right)/(top+bottom)만큼 줄인다. saturate(-|)라
/// inset이 pane보다 커도 언더플로 없이 0에 수렴한다(0-area 본문은 Swift가 숨김으로 다룰 몫 — 4a 범위 밖).
pub fn contentRect(pane_rect: Rect, inset: ChromeInset) Rect {
    return .{
        .x = pane_rect.x +| inset.left,
        .y = pane_rect.y +| inset.top,
        .w = pane_rect.w -| (inset.left +| inset.right),
        .h = pane_rect.h -| (inset.top +| inset.bottom),
    };
}

// ── ② backing px(좌상단) → pt(좌하단) y-flip (§3·§11) ─────────────────────────────────────────────────────

/// 포인트 사각형(pt, 좌하단 origin — WKWebView frame 좌표계). 정수 backing px와 달리 분수 pt라 f64.
pub const RectPt = struct { x: f64, y: f64, w: f64, h: f64 };

/// divider hit target처럼 분수 backing-px 경계를 가질 수 있는 사각형. native pass-through는 최종 WebView
/// content rect와 **실제 Zig resize target의 교집합**만 양보해야 하므로 정수 rect로 반올림하지 않는다.
pub const RectF64 = struct { x: f64, y: f64, w: f64, h: f64 };

pub const DividerEdge = enum { left, right, bottom };

/// `content` 가장자리에서 안쪽으로 연속된 `target` 교집합 폭(backing px). target이 content의 교차축 전체를
/// 덮지 않거나 가장자리에 직접 닿지 않으면 0으로 fail-close한다. 이 값만 native hit-test에 내려
/// "WebKit이 양보한 모든 점은 Zig resize target"을 보장한다.
pub fn dividerPassThroughBandPx(content: Rect, target: RectF64, edge: DividerEdge) f64 {
    if (content.w == 0 or content.h == 0 or target.w <= 0 or target.h <= 0) return 0;
    const cx0: f64 = @floatFromInt(content.x);
    const cy0: f64 = @floatFromInt(content.y);
    const cx1 = cx0 + @as(f64, @floatFromInt(content.w));
    const cy1 = cy0 + @as(f64, @floatFromInt(content.h));
    const tx1 = target.x + target.w;
    const ty1 = target.y + target.h;
    return switch (edge) {
        .left => if (target.y <= cy0 and ty1 >= cy1 and target.x <= cx0 and tx1 > cx0)
            @max(0, @min(cx1, tx1) - cx0)
        else
            0,
        .right => if (target.y <= cy0 and ty1 >= cy1 and target.x < cx1 and tx1 >= cx1)
            @max(0, cx1 - @max(cx0, target.x))
        else
            0,
        .bottom => if (target.x <= cx0 and tx1 >= cx1 and target.y < cy1 and ty1 >= cy1)
            @max(0, cy1 - @max(cy0, target.y))
        else
            0,
    };
}

pub const DividerGrabBandsPt = struct {
    left: f64 = 0,
    right: f64 = 0,
    bottom: f64 = 0,
};

/// backing px·좌상단 rect를 pt·좌하단(WKWebView frame) rect로 변환한다(§3·§11). scale = scale_milli/1000
/// (backing px per point). y-flip: 좌상단 px에서 rect의 **아래 가장자리**는 컨테이너 위에서 y+h만큼 내려간
/// 곳이고, 좌하단 pt origin.y는 컨테이너 아래에서 잰 그 거리 = (window_height_px − y − h)/scale이다. x/w/h는
/// 스케일 나눗셈만. `window_height_px`는 WKWebView가 subview로 붙는 **컨테이너 content view의 backing 높이**다
/// (OS 타이틀바 포함 전체 창 높이가 아니라, pane rect가 사는 그 좌표 공간의 높이 — y-flip 기준이 어긋나면
/// 웹 패널이 세로로 밀린다). 전제: scale_milli는 실제 backing scale(>0). 다만 0이 넘어오면 나눗셈이 inf/NaN을
/// 만들고 그 값이 하류의 @intFromFloat(illegal behavior) 등으로 번지므로 `@max(1, scale_milli)`로 clamp해 최소
/// 방어한다(0=garbage-in이라 결과 좌표는 무의미하되 유한·비트랩). Phase 4c가 이 함수를 실제로 호출하기 시작한다.
pub fn pxTopLeftToPtBottomLeft(rect_px: Rect, window_height_px: u32, scale_milli: u32) RectPt {
    const scale = @as(f64, @floatFromInt(@max(@as(u32, 1), scale_milli))) / 1000.0;
    const y_px: f64 = @floatFromInt(rect_px.y);
    const h_px: f64 = @floatFromInt(rect_px.h);
    const win_h_px: f64 = @floatFromInt(window_height_px);
    return .{
        .x = @as(f64, @floatFromInt(rect_px.x)) / scale,
        // y-flip: 좌하단 origin.y = 창 아래에서 rect 아래 가장자리까지 = (창높이 − y − h)를 pt로.
        .y = (win_h_px - y_px - h_px) / scale,
        .w = @as(f64, @floatFromInt(rect_px.w)) / scale,
        .h = h_px / scale,
    };
}

// ── ③ surface diff (§6) ──────────────────────────────────────────────────────────────────────────────────

/// 한 tick의 web surface 배치 항목(§6 "{surface_id, panel_kind, 본문 rect}"). visible=활성 탭이면 true,
/// 같은 pane의 비활성 탭이면 false(§6 "활성만 show, 비활성 hidden으로 상태 유지"). content_rect는 본문 rect.
pub const SurfaceLayout = struct {
    /// 앱 전역 unique·비재사용 surface_id(M0a) — diff의 안정 키. 위치·rect가 아니라 이 id로 매칭한다.
    surface_id: u64,
    /// markdown|browser. surface_id마다 불변(비재사용이라 id↔kind 고정) — diff는 created/reframed/shown에 실어만 준다.
    panel_kind: PanelKind,
    /// 본문 rect(backing px·좌상단, contentRect 출력).
    content_rect: Rect,
    /// 이 tick에 화면에 보여야 하는가(활성 탭). false면 존재하되 hidden(상태 유지).
    visible: bool,
    /// 이 web 본문 rect의 어느 가장자리가 split divider(형제 pane 경계)에 맞닿는가 — 비트마스크(left=1·right=2·bottom=4,
    /// top은 탭 바라 divider 없음). Swift가 WKWebView hitTest에서 그 가장자리 근처 클릭/hover를 **통과**시켜 아래 터미널
    /// 뷰의 divider 드래그·resize 커서가 잡게 한다(작은 시각 gap과 넓은 grab 폭을 분리 — WKWebView가 native라 안 삼키게).
    seam_edges: u8 = 0,
    /// 최종 content rect와 실제 Zig divider hit target의 가장자리별 교집합 폭(logical pt). 0이면 그 edge의
    /// native pass-through를 끈다. 단일 전역 폭을 쓰면 비대칭 padding에서 dead strip이 생기므로 edge별이다.
    divider_grab_bands_pt: DividerGrabBandsPt = .{},
};

/// prev→cur surface 집합의 순수 diff(§6). Swift가 소비할 NSView 연산을 **전이(transition)**로 낸다 — 매 tick
/// 무변경까지 frame/isHidden을 건드리면 WebKit 재레이아웃 폭주(§3)라, 실제 바뀐 것만 싣는다.
///   - created:   cur에만 있음 → WKWebView 생성(+visible면 frame·show).
///   - destroyed: prev에만 있음 → WKWebView 파괴.
///   - reframed:  둘 다 있고 **둘 다 visible**이며 본문 rect 변경 → frame 갱신.
///   - hidden:    visible → not-visible 전이 → isHidden=true.
///   - shown:     not-visible → visible 전이 → isHidden=false + 최신 frame(§6 문서 열거의 대칭 보완).
/// created/reframed/shown은 rect·kind가 필요해 SurfaceLayout을, hidden/destroyed는 surface_id만 싣는다.
/// hidden→hidden(둘 다 비활성)은 rect가 바뀌어도 무동작 — 숨은 뷰에 frame set을 안 해 §3 relayout을 피하고,
/// 최신 rect는 다시 shown될 때 실린다.
pub const SurfaceDiff = struct {
    created: std.ArrayList(SurfaceLayout) = .empty,
    destroyed: std.ArrayList(u64) = .empty,
    reframed: std.ArrayList(SurfaceLayout) = .empty,
    hidden: std.ArrayList(u64) = .empty,
    shown: std.ArrayList(SurfaceLayout) = .empty,

    pub fn deinit(self: *SurfaceDiff, gpa: std.mem.Allocator) void {
        self.created.deinit(gpa);
        self.destroyed.deinit(gpa);
        self.reframed.deinit(gpa);
        self.hidden.deinit(gpa);
        self.shown.deinit(gpa);
    }

    /// 전이가 하나도 없으면 true(무변경 tick — Swift가 아무 NSView 연산도 안 함).
    pub fn isEmpty(self: SurfaceDiff) bool {
        return self.created.items.len == 0 and self.destroyed.items.len == 0 and
            self.reframed.items.len == 0 and self.hidden.items.len == 0 and self.shown.items.len == 0;
    }
};

fn rectEql(a: Rect, b: Rect) bool {
    return a.x == b.x and a.y == b.y and a.w == b.w and a.h == b.h;
}

fn findById(list: []const SurfaceLayout, id: u64) ?SurfaceLayout {
    for (list) |s| {
        if (s.surface_id == id) return s;
    }
    return null;
}

/// prev·cur(둘 다 web surface 집합)에서 §6 전이 diff를 만든다. surface_id로 매칭(위치·rect 아님). caller가
/// `deinit`. 웹 surface 수는 작아 O(prev×cur) 선형 탐색으로 충분(해시 불요).
pub fn surfaceDiff(
    gpa: std.mem.Allocator,
    prev: []const SurfaceLayout,
    cur: []const SurfaceLayout,
) std.mem.Allocator.Error!SurfaceDiff {
    var diff: SurfaceDiff = .{};
    errdefer diff.deinit(gpa);

    // cur 패스: created / (present-in-both) 전이(shown·hidden·reframed·무동작).
    for (cur) |c| {
        const p = findById(prev, c.surface_id) orelse {
            try diff.created.append(gpa, c);
            continue;
        };
        if (!p.visible and c.visible) {
            try diff.shown.append(gpa, c); // 숨김 → 보임: 최신 frame과 함께 unhide.
        } else if (p.visible and !c.visible) {
            try diff.hidden.append(gpa, c.surface_id); // 보임 → 숨김.
        } else if (p.visible and c.visible) {
            // 둘 다 보임 + rect 또는 seam_edges 변경(seam 변화는 거의 rect 변화 동반이나 방어적으로 함께 비교 — Swift가
            // frame·seamEdges를 reframe에서 갱신하므로 seam-only 변화도 놓치지 않는다).
            if (!rectEql(p.content_rect, c.content_rect) or p.seam_edges != c.seam_edges or
                !std.meta.eql(p.divider_grab_bands_pt, c.divider_grab_bands_pt)) try diff.reframed.append(gpa, c);
        }
        // hidden→hidden: 무동작(숨은 뷰에 frame set 안 함 — §3). rect는 다음 shown에서 실림.
    }

    // prev 패스: cur에 없어진 surface = destroyed.
    for (prev) |p| {
        if (findById(cur, p.surface_id) == null) try diff.destroyed.append(gpa, p.surface_id);
    }

    return diff;
}

// ══ 테스트(헤드리스, Linux CI 포함 — 순수 로직·소켓/OS 0) ═══════════════════════════════════════════════════
const testing = std.testing;

// ── ① 본문 rect ──
test "contentRect: pane rect에서 top(탭 바)만 빼면 본문이 그만큼 아래로 좁아진다" {
    const pane: Rect = .{ .x = 100, .y = 0, .w = 400, .h = 300 };
    // 탭 바 높이 24만 top으로 뺀다(divider seam 없음).
    try testing.expectEqual(Rect{ .x = 100, .y = 24, .w = 400, .h = 276 }, contentRect(pane, .{ .top = 24 }));
}

test "contentRect: 4방 inset(탭 바 top + divider seam left/right/bottom)이 origin·크기에 정확히 반영" {
    const pane: Rect = .{ .x = 100, .y = 50, .w = 400, .h = 300 };
    // top=24(탭 바), left=2·right=2(세로 seam 양옆), bottom=2(가로 seam 아래).
    const got = contentRect(pane, .{ .top = 24, .left = 2, .right = 2, .bottom = 2 });
    try testing.expectEqual(Rect{ .x = 102, .y = 74, .w = 396, .h = 274 }, got);
}

test "contentRect: zero inset은 항등(본문 = pane 전체)" {
    const pane: Rect = .{ .x = 10, .y = 20, .w = 30, .h = 40 };
    try testing.expectEqual(pane, contentRect(pane, .{}));
}

test "contentRect: inset이 pane보다 크면 언더플로 없이 0으로 saturate" {
    const pane: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 50 };
    // top·bottom 합(60+60)이 h(50)보다, left·right 합(200+200)이 w(100)보다 크다 → w/h=0.
    const got = contentRect(pane, .{ .top = 60, .bottom = 60, .left = 200, .right = 200 });
    try testing.expectEqual(@as(u32, 0), got.w);
    try testing.expectEqual(@as(u32, 0), got.h);
    // origin은 x+left·y+top로 전진(saturate 대상 아님).
    try testing.expectEqual(@as(u32, 200), got.x);
    try testing.expectEqual(@as(u32, 60), got.y);
}

// ── ② px(좌상단) → pt(좌하단) y-flip ──
test "pxToPt: 1x 스케일 top-left rect는 창 상단(pt y가 창 높이 근처)으로 뒤집힌다" {
    // 창 1000px 높이, 1x. 좌상단 (0,0) 100×50 rect.
    const got = pxTopLeftToPtBottomLeft(.{ .x = 0, .y = 0, .w = 100, .h = 50 }, 1000, 1000);
    try testing.expectApproxEqAbs(@as(f64, 0), got.x, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 950), got.y, 1e-9); // (1000 − 0 − 50)/1
    try testing.expectApproxEqAbs(@as(f64, 100), got.w, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 50), got.h, 1e-9);
}

test "pxToPt: 좌상단 px의 '맨 아래 스트립'은 pt origin.y=0(창 바닥)으로 간다" {
    // 좌상단에서 y=950,h=50 (창 맨 아래 50px) → 좌하단 pt origin.y=0.
    const got = pxTopLeftToPtBottomLeft(.{ .x = 0, .y = 950, .w = 1000, .h = 50 }, 1000, 1000);
    try testing.expectApproxEqAbs(@as(f64, 0), got.y, 1e-9); // (1000 − 950 − 50)/1
}

test "pxToPt: 창 전체 높이 rect는 origin.y=0(위·아래 가장자리 정렬)" {
    const got = pxTopLeftToPtBottomLeft(.{ .x = 0, .y = 0, .w = 800, .h = 600 }, 600, 1000);
    try testing.expectApproxEqAbs(@as(f64, 0), got.y, 1e-9);
    try testing.expectApproxEqAbs(@as(f64, 600), got.h, 1e-9);
}

test "pxToPt: 2x retina 스케일은 px를 절반 pt로 나누고 y-flip한다" {
    // 창 2000px(=1000pt) 높이, 2x. rect px (200,100,400,200).
    const got = pxTopLeftToPtBottomLeft(.{ .x = 200, .y = 100, .w = 400, .h = 200 }, 2000, 2000);
    try testing.expectApproxEqAbs(@as(f64, 100), got.x, 1e-9); // 200/2
    try testing.expectApproxEqAbs(@as(f64, 850), got.y, 1e-9); // (2000 − 100 − 200)/2
    try testing.expectApproxEqAbs(@as(f64, 200), got.w, 1e-9); // 400/2
    try testing.expectApproxEqAbs(@as(f64, 100), got.h, 1e-9); // 200/2
}

test "pxToPt: 3x 스케일 분수 pt(정수로 안 나눠떨어지는 경계)" {
    // 창 900px(=300pt) 높이, 3x. rect px (30,60,90,30).
    const got = pxTopLeftToPtBottomLeft(.{ .x = 30, .y = 60, .w = 90, .h = 30 }, 900, 3000);
    try testing.expectApproxEqAbs(@as(f64, 10), got.x, 1e-9); // 30/3
    try testing.expectApproxEqAbs(@as(f64, 270), got.y, 1e-9); // (900 − 60 − 30)/3 = 810/3
    try testing.expectApproxEqAbs(@as(f64, 30), got.w, 1e-9); // 90/3
    try testing.expectApproxEqAbs(@as(f64, 10), got.h, 1e-9); // 30/3
}

test "pxToPt: scale_milli==0은 clamp(@max 1)로 유한 좌표(inf/NaN 방지)" {
    // 0 스케일은 계약 위반(garbage-in)이지만 나눗셈이 inf/NaN을 내면 하류 @intFromFloat이 illegal이 된다.
    // @max(1,0)=1 → scale=0.001로 clamp되어 결과는 (무의미하나) 유한해야 한다.
    const got = pxTopLeftToPtBottomLeft(.{ .x = 10, .y = 20, .w = 30, .h = 40 }, 1000, 0);
    try testing.expect(std.math.isFinite(got.x));
    try testing.expect(std.math.isFinite(got.y));
    try testing.expect(std.math.isFinite(got.w));
    try testing.expect(std.math.isFinite(got.h));
}

test "divider pass-through band is only the contiguous content-edge intersection with the Zig target" {
    const content: Rect = .{ .x = 108, .y = 54, .w = 376, .h = 288 };
    const full_height_target = RectF64{ .x = 100, .y = 50, .w = 20, .h = 300 };
    try testing.expectApproxEqAbs(@as(f64, 12), dividerPassThroughBandPx(content, full_height_target, .left), 1e-9);

    const right_target = RectF64{ .x = 476, .y = 50, .w = 24, .h = 300 };
    try testing.expectApproxEqAbs(@as(f64, 8), dividerPassThroughBandPx(content, right_target, .right), 1e-9);

    const bottom_target = RectF64{ .x = 100, .y = 330, .w = 400, .h = 20 };
    try testing.expectApproxEqAbs(@as(f64, 12), dividerPassThroughBandPx(content, bottom_target, .bottom), 1e-9);

    // 교차축 일부만 덮거나 content edge에서 떨어진 target은 uniform native band로 표현하면 dead strip을
    // 만들므로 0으로 fail-close한다.
    try testing.expectEqual(@as(f64, 0), dividerPassThroughBandPx(content, .{ .x = 100, .y = 60, .w = 20, .h = 100 }, .left));
    try testing.expectEqual(@as(f64, 0), dividerPassThroughBandPx(content, .{ .x = 90, .y = 50, .w = 10, .h = 300 }, .left));
}

test "divider pass-through remains a subset of the target across scale and padding cases" {
    const cases = [_]struct { scale_milli: u32, padding_px: u32 }{
        .{ .scale_milli = 1000, .padding_px = 0 },
        .{ .scale_milli = 1500, .padding_px = 6 },
        .{ .scale_milli = 2000, .padding_px = 40 }, // grab target보다 큰 padding → band 0
    };
    for (cases) |case| {
        const target_width_px = 10.0 * @as(f64, @floatFromInt(case.scale_milli)) / 1000.0;
        const content = Rect{ .x = 100 + case.padding_px, .y = 20, .w = 200, .h = 100 };
        const target = RectF64{ .x = 100, .y = 20, .w = target_width_px, .h = 100 };
        const band = dividerPassThroughBandPx(content, target, .left);
        try testing.expect(band >= 0 and band <= target_width_px);
        if (band > 0) {
            const native_pass_point = @as(f64, @floatFromInt(content.x)) + band / 2;
            try testing.expect(native_pass_point >= target.x and native_pass_point < target.x + target.w);
        }
    }
}

// ── ③ surface diff ──
fn layout(sid: u64, rect: Rect, visible: bool) SurfaceLayout {
    return .{ .surface_id = sid, .panel_kind = .markdown, .content_rect = rect, .visible = visible };
}

test "surfaceDiff: 생성만 — 빈 prev에서 새 surface는 created(rect·kind 실림)" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const cur = [_]SurfaceLayout{layout(1, r, true)};
    var d = try surfaceDiff(testing.allocator, &.{}, &cur);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), d.created.items.len);
    try testing.expectEqual(@as(u64, 1), d.created.items[0].surface_id);
    try testing.expect(rectEql(r, d.created.items[0].content_rect));
    try testing.expectEqual(@as(usize, 0), d.destroyed.items.len);
    try testing.expectEqual(@as(usize, 0), d.reframed.items.len);
    try testing.expectEqual(@as(usize, 0), d.hidden.items.len);
    try testing.expectEqual(@as(usize, 0), d.shown.items.len);
}

test "surfaceDiff: 파괴만 — cur에 없어진 surface는 destroyed(surface_id)" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const prev = [_]SurfaceLayout{layout(7, r, true)};
    var d = try surfaceDiff(testing.allocator, &prev, &.{});
    defer d.deinit(testing.allocator);
    try testing.expectEqualSlices(u64, &.{7}, d.destroyed.items);
    try testing.expect(d.created.items.len == 0 and d.reframed.items.len == 0);
}

test "surfaceDiff: 숨김만 — visible→not-visible 전이는 hidden(surface_id)" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const prev = [_]SurfaceLayout{layout(3, r, true)};
    const cur = [_]SurfaceLayout{layout(3, r, false)};
    var d = try surfaceDiff(testing.allocator, &prev, &cur);
    defer d.deinit(testing.allocator);
    try testing.expectEqualSlices(u64, &.{3}, d.hidden.items);
    try testing.expect(d.created.items.len == 0 and d.destroyed.items.len == 0 and d.reframed.items.len == 0 and d.shown.items.len == 0);
}

test "surfaceDiff: 보임 전이 — not-visible→visible은 shown(최신 rect 실림)" {
    const r0: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const r1: Rect = .{ .x = 0, .y = 0, .w = 120, .h = 100 }; // 숨은 동안 rect도 바뀜
    const prev = [_]SurfaceLayout{layout(5, r0, false)};
    const cur = [_]SurfaceLayout{layout(5, r1, true)};
    var d = try surfaceDiff(testing.allocator, &prev, &cur);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), d.shown.items.len);
    try testing.expectEqual(@as(u64, 5), d.shown.items[0].surface_id);
    try testing.expect(rectEql(r1, d.shown.items[0].content_rect)); // shown은 최신 frame을 실어야 함
    try testing.expect(d.reframed.items.len == 0); // reframe 아님(전이는 shown)
}

test "surfaceDiff: reframe — 둘 다 visible이고 rect만 바뀌면 reframed(최신 rect)" {
    const r0: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const r1: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    const prev = [_]SurfaceLayout{layout(9, r0, true)};
    const cur = [_]SurfaceLayout{layout(9, r1, true)};
    var d = try surfaceDiff(testing.allocator, &prev, &cur);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), d.reframed.items.len);
    try testing.expect(rectEql(r1, d.reframed.items[0].content_rect));
    try testing.expect(d.created.items.len == 0 and d.hidden.items.len == 0 and d.shown.items.len == 0);
}

test "surfaceDiff: 무변경 — 둘 다 visible·같은 rect면 전이 0(무동작 tick)" {
    const r: Rect = .{ .x = 1, .y = 2, .w = 3, .h = 4 };
    const prev = [_]SurfaceLayout{layout(1, r, true)};
    const cur = [_]SurfaceLayout{layout(1, r, true)};
    var d = try surfaceDiff(testing.allocator, &prev, &cur);
    defer d.deinit(testing.allocator);
    try testing.expect(d.isEmpty());
}

test "surfaceDiff: hidden→hidden은 rect가 바뀌어도 무동작(§3 숨은 뷰 relayout 회피)" {
    const r0: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const r1: Rect = .{ .x = 0, .y = 0, .w = 999, .h = 100 };
    const prev = [_]SurfaceLayout{layout(2, r0, false)};
    const cur = [_]SurfaceLayout{layout(2, r1, false)};
    var d = try surfaceDiff(testing.allocator, &prev, &cur);
    defer d.deinit(testing.allocator);
    try testing.expect(d.isEmpty()); // reframe도 hidden도 아님 — 숨은 채 rect만 대기
}

test "surfaceDiff: divider grab band-only visible change reframes; hidden latest is emitted on shown" {
    const r: Rect = .{ .x = 1, .y = 2, .w = 300, .h = 200 };
    const prev_visible = [_]SurfaceLayout{.{ .surface_id = 11, .panel_kind = .markdown, .content_rect = r, .visible = true, .seam_edges = 2, .divider_grab_bands_pt = .{ .right = 10 } }};
    const cur_visible = [_]SurfaceLayout{.{ .surface_id = 11, .panel_kind = .markdown, .content_rect = r, .visible = true, .seam_edges = 2 }};
    var changed = try surfaceDiff(testing.allocator, &prev_visible, &cur_visible);
    defer changed.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), changed.reframed.items.len);
    try testing.expectEqual(@as(f64, 0), changed.reframed.items[0].divider_grab_bands_pt.right);

    const prev_hidden = [_]SurfaceLayout{.{ .surface_id = 12, .panel_kind = .markdown, .content_rect = r, .visible = false, .seam_edges = 2 }};
    const cur_hidden = [_]SurfaceLayout{.{ .surface_id = 12, .panel_kind = .markdown, .content_rect = r, .visible = false, .seam_edges = 2, .divider_grab_bands_pt = .{ .right = 10 } }};
    var hidden = try surfaceDiff(testing.allocator, &prev_hidden, &cur_hidden);
    defer hidden.deinit(testing.allocator);
    try testing.expect(hidden.isEmpty());

    const shown = [_]SurfaceLayout{.{ .surface_id = 12, .panel_kind = .markdown, .content_rect = r, .visible = true, .seam_edges = 2, .divider_grab_bands_pt = .{ .right = 10 } }};
    var show_diff = try surfaceDiff(testing.allocator, &cur_hidden, &shown);
    defer show_diff.deinit(testing.allocator);
    try testing.expectEqual(@as(f64, 10), show_diff.shown.items[0].divider_grab_bands_pt.right);
}

test "surfaceDiff: 빈 집합 → 빈 집합은 완전 무동작" {
    var d = try surfaceDiff(testing.allocator, &.{}, &.{});
    defer d.deinit(testing.allocator);
    try testing.expect(d.isEmpty());
}

test "surfaceDiff: surface_id 안정성 — 같은 id는 위치/rect가 달라도 reframe(파괴+생성 아님)" {
    // prev·cur 모두 id=42지만 rect 완전 다름 → destroyed+created가 아니라 reframed 하나여야 한다.
    const prev = [_]SurfaceLayout{layout(42, .{ .x = 0, .y = 0, .w = 100, .h = 100 }, true)};
    const cur = [_]SurfaceLayout{layout(42, .{ .x = 500, .y = 500, .w = 50, .h = 50 }, true)};
    var d = try surfaceDiff(testing.allocator, &prev, &cur);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 1), d.reframed.items.len);
    try testing.expect(d.created.items.len == 0 and d.destroyed.items.len == 0);
}

test "surfaceDiff: surface_id 안정성 — 다른 id는 같은 자리라도 파괴+생성" {
    // 같은 rect·visible이지만 id가 다르면 별개 surface → prev의 1은 destroyed, cur의 2는 created.
    const r: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const prev = [_]SurfaceLayout{layout(1, r, true)};
    const cur = [_]SurfaceLayout{layout(2, r, true)};
    var d = try surfaceDiff(testing.allocator, &prev, &cur);
    defer d.deinit(testing.allocator);
    try testing.expectEqualSlices(u64, &.{1}, d.destroyed.items);
    try testing.expectEqual(@as(usize, 1), d.created.items.len);
    try testing.expectEqual(@as(u64, 2), d.created.items[0].surface_id);
    try testing.expect(d.reframed.items.len == 0);
}

test "surfaceDiff: 혼합 — created·destroyed·hidden·reframed가 한 tick에 함께" {
    const ra: Rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    const rb: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 100 };
    // prev: 1(visible)·2(visible)·3(visible). cur: 1(rect 바뀜=reframe)·2(hidden)·4(new). 3은 사라짐(destroy).
    const prev = [_]SurfaceLayout{ layout(1, ra, true), layout(2, ra, true), layout(3, ra, true) };
    const cur = [_]SurfaceLayout{ layout(1, rb, true), layout(2, ra, false), layout(4, ra, true) };
    var d = try surfaceDiff(testing.allocator, &prev, &cur);
    defer d.deinit(testing.allocator);
    try testing.expectEqualSlices(u64, &.{3}, d.destroyed.items);
    try testing.expectEqualSlices(u64, &.{2}, d.hidden.items);
    try testing.expectEqual(@as(usize, 1), d.reframed.items.len);
    try testing.expectEqual(@as(u64, 1), d.reframed.items[0].surface_id);
    try testing.expectEqual(@as(usize, 1), d.created.items.len);
    try testing.expectEqual(@as(u64, 4), d.created.items[0].surface_id);
    try testing.expectEqual(@as(usize, 0), d.shown.items.len);
}

test "surfaceDiff: panel_kind가 created 엔트리에 보존된다(browser vs markdown)" {
    const r: Rect = .{ .x = 0, .y = 0, .w = 10, .h = 10 };
    const cur = [_]SurfaceLayout{.{ .surface_id = 1, .panel_kind = .browser, .content_rect = r, .visible = true }};
    var d = try surfaceDiff(testing.allocator, &.{}, &cur);
    defer d.deinit(testing.allocator);
    try testing.expectEqual(PanelKind.browser, d.created.items[0].panel_kind);
}
