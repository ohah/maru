//! Tabbar — pane 탭 바의 컬럼 분할 hit-test. chrome **마우스 hit-test 컴포넌트**(divider/sidebar 동형 — State 없는
//! 순수 함수). 바를 [탭 영역(tab_cols) | "+" zone]으로 나눠 탭 인덱스·✕(닫기)·"+"(새 Term) zone을 판정한다(옛
//! app_session BarMetrics 수학 이전 — 호출처가 `m.tabIndex(...)`를 그대로 쓰도록 Metrics **메서드**로 둔다). 탭
//! 전환/닫기/새 Term/드래그·드롭·제목 glyph·라이브 `*Pane`은 platform이 든다(§6). 활성 탭 강조 **밴드는 platform이
//! 단일 셀로 직접** 그린다(`tabbarHighlightCell`) — 밴드가 한 칸이라 chrome ChromeDraw→cell round-trip이 무의미하기
//! 때문(C3a 리뷰 §3 반영; divider/sidebar의 다중 op view와 달리 tabbar는 hit-test만 chrome). host가 `Metrics`를
//! platform에서 변환 주입하고, 제목/✕/+ glyph·활성 밴드는 platform이 같은 분할로 그려 "보이는 탭/✕/+ == 클릭되는 것".
//! 단일 출처: docs/chrome-strategy.md §5.4, docs/layering-and-portability.md §5(C3b).

const std = @import("std");

/// 탭 tab_index의 **셀 경계** [start, end) — Metrics(픽셀 메트릭) 없이 순수 컬럼 분할만 계산하는 단일 소스.
/// hit-test(segOf)와 platform view 그리기(buildPaneTabBarDrawList의 제목·✕)가 이 한 함수를 공유해 "보이는 탭/✕ ==
/// 클릭되는 것"을 보장한다(§6). end = min((tab_index+1)*tab_w, tab_cols), end<=start면 overflow(탭 영역 밖, 안 보임).
pub fn segCols(tab_index: usize, tab_w: u32, tab_cols: u32, scroll_cols: u32) struct { start: u32, end: u32 } {
    const abs_start = @as(u32, @intCast(tab_index)) * tab_w;
    // 화면 좌표 = 절대 컬럼 - scroll(보이는 창을 왼쪽으로 민다). 왼쪽 스크롤아웃(abs<scroll)은 0으로 saturate,
    // 우측은 tab_cols clamp. scroll_cols=0이면 기존과 동일(start=abs_start, end=min(abs+tab_w, tab_cols)).
    const start = abs_start -| scroll_cols;
    const end = (abs_start + tab_w) -| scroll_cols;
    return .{ .start = @min(start, tab_cols), .end = @min(end, tab_cols) };
}

/// 탭 바 한 줄의 컬럼 분할 메트릭(중립 — host가 platform에서 변환해 주입; bar rect는 plain u32). 바를
/// [탭 영역(tab_cols) | "+" zone(cols-tab_cols)]으로 나눈다. tab_w=탭 하나의 폭(컬럼). 분할 불가(셀·바·탭 0)면 host가
/// null을 줘 이 메트릭이 안 만들어진다(호출자가 탭 처리 건너뜀). platform이 활성 밴드·제목 glyph를 같은 분할로 그린다.
pub const Metrics = struct {
    bar_x: u32,
    bar_y: u32,
    bar_w: u32,
    bar_h: u32,
    cell_width_px: u32,
    cols: u32, // 바 전체 컬럼 수
    tab_cols: u32, // "+" zone을 뗀 탭 영역 컬럼 수(좁은 바면 == cols)
    tab_w: u32, // 탭 하나의 폭(컬럼)
    scroll_cols: u32 = 0, // Step 2: 가로 스크롤 offset(컬럼). segCols/segOf가 화면 좌표를 이만큼 왼쪽으로 민다. 0=기본(barMetrics가 Pane.tab_scroll_cols로 채움).
    has_scroll: bool = false, // Step 2a-2: 탭이 넘쳐 우측 "+" 왼쪽에 ‹›(2칸) 스크롤 버튼 zone이 예약됐는가. barMetrics가 판정(tab_cols는 이미 2칸 축소됨).
    tab_count: u32 = 0, // 상단탭 Warp 폴리시: Term 탭 수(인라인 "+" 위치 계산용 — 마지막 탭 바로 뒤). barMetrics가 채운다.

    /// 바 좌단 기준 col의 픽셀 경계. tab_index 세그먼트는 [col*cw, segEnd*cw).
    fn colPx(self: Metrics, col: u32) f64 {
        return @as(f64, @floatFromInt(self.bar_x)) + @as(f64, @floatFromInt(col)) * @as(f64, @floatFromInt(self.cell_width_px));
    }

    /// tab_index 세그먼트의 끝 컬럼(우경계, tab_cols로 clamp). platform 활성 밴드(start [i*tab_w, +tab_w))와 같은 분할.
    pub fn segEnd(self: Metrics, tab_index: usize) u32 {
        return segCols(tab_index, self.tab_w, self.tab_cols, self.scroll_cols).end;
    }

    /// 탭 하나의 **경계 단일 소스**(§6) — hit-test(tabIndex·inCloseZone)와 platform 활성 밴드(tabbarHighlightCell)가
    /// 이 한 함수를 공유한다. 제목·✕·+ glyph(buildPaneTabBarDrawList)는 아직 셀-열을 직접 계산하며 다음 단계에서
    /// segOf로 옮겨 "보이는 탭/✕ == 클릭되는 것"을 완성한다(그 전까진 둘 다 셀-열이라 우연히 일치). 셀 경계
    /// (start_col/end_col, 반열림)는 셀 밴드·제목 그리기용, 픽셀([start_px, end_px))는 hit-test용. close_*는 ✕(닫기)
    /// zone(우측 2칸). tab_w<2면 ✕ 없음(has_close=false), end_col<=start_col이면 overflow(안 보이는) 탭. bar_x 기준 절대 px.
    pub const TabSeg = struct {
        start_col: u32, // 탭 좌단 컬럼(셀 밴드·제목 그리기용)
        end_col: u32, // 탭 우단 컬럼(반열림, tab_cols clamp). end_col<=start_col이면 overflow(안 보이는) 탭
        start_px: f64,
        end_px: f64,
        close_start_px: f64,
        has_close: bool,
    };

    /// 탭 tab_index의 픽셀 세그먼트. 현재는 **셀-열 정렬**(start=tab_index*tab_w 컬럼, end=segEnd 컬럼의 px) —
    /// 패딩 0이라 시각/동작이 기존 셀-열 hit-test와 동일하다. 둥근 탭(C4b-5)에서 탭 패딩을 더하면 **여기 한 곳만**
    /// 바뀌어 view·hit-test가 동시에 움직인다(§6 seam 해소의 토대). colPx/segEnd를 재사용한다.
    pub fn segOf(self: Metrics, tab_index: usize) TabSeg {
        const sc = segCols(tab_index, self.tab_w, self.tab_cols, self.scroll_cols);
        const start_col = sc.start;
        const end_col = sc.end;
        // ✕는 우측 안쪽 칸(end_col-2)에 그려지고 **좌우 한 칸씩 패딩**을 둔다(buildPaneTabBarDrawList와 같은 규칙).
        // 판정은 **보이는 폭**(end_col-start_col) 기준이어야 한다 — 우단에서 잘린 탭은 nominal tab_w가 커도 실제 폭이
        // 1~3칸이라, tab_w로 판정하면 ✕가 seg_end-2 = **이웃 탭 안**에 그려지고 클릭이 엉뚱한 Term을 닫는다(code-review max).
        // 5칸인 이유: 좌패딩1 + 제목최소1 + ✕좌여백1 + ✕1 + ✕우여백1 — 렌더의 `title_end = seg_end-3`와 정확히 대응한다.
        const visible_cols = if (end_col > start_col) end_col - start_col else 0;
        const has_close = visible_cols >= 5;
        return .{
            .start_col = start_col,
            .end_col = end_col,
            .start_px = self.colPx(start_col),
            .end_px = self.colPx(end_col),
            .close_start_px = if (has_close) self.colPx(end_col - close_button_cols) else 0,
            .has_close = has_close,
        };
    }

    /// x_px가 가리키는 Term 탭 인덱스([0, term_count-1] clamp). **segOf 픽셀 경계 단일 소스**로 판정 — x가 어느 탭
    /// 세그먼트 [start,end)에 드는지 순회한다(좌측 clamp: x<탭0.start면 0, 우측 clamp: x>=마지막.end면 마지막).
    /// "+" zone은 마지막 탭으로 떨어지므로 호출자가 inPlusZone을 **먼저** 검사해야 한다. 셀-열 정렬이라 기존 동작과 동일.
    pub fn tabIndex(self: Metrics, term_count: usize, x_px: f64) usize {
        // tab_cols/tab_w==0 가드: barMetrics가 tab_cols>=1·tab_w>0을 보장하므로 platform 경로엔 dead지만, Metrics가
        // public이라 테스트·미래 호출자가 직접 빌드할 수 있어 segOf의 underflow·0 분할을 막는다(계약 명시).
        if (term_count == 0 or !std.math.isFinite(x_px) or self.tab_cols == 0 or self.tab_w == 0) return 0;
        // **보이는 탭만** 대상(셀-열 정렬 OLD와 동일). term_count가 탭 영역 칸수보다 많으면(좁은 바에서 tab_w가 1로
        // collapse) 탭 영역을 넘는 overflow 탭은 segOf가 0/음수 폭(end_px<=start_px)이 되고 그려지지도 않는다 —
        // 이런 탭을 클릭/드래그 타겟으로 잡지 않도록 순회를 멈추고, x가 모든 보이는 탭 우경계 이상이면 마지막
        // 보이는 탭으로 clamp한다(안 보이는 term_count-1을 반환하지 않게 — 리뷰 #1: dragTabTo 가드 부재 회귀 방지).
        var last_visible: usize = 0;
        var seen_visible = false;
        var i: usize = 0;
        while (i < term_count) : (i += 1) {
            const abs_start = i * self.tab_w;
            // **폭 0 인 탭은 두 종류다.** 왼쪽으로 스크롤아웃된 탭과, 탭 영역을 넘어선 오른쪽 탭. `segOf`는
            // 둘 다 0 폭으로 뭉개므로 여기서 갈라야 한다 — 옛 코드는 첫 번째 0 폭에서 순회를 끊었고, 그래서
            // **한 탭이라도 왼쪽으로 밀리면 어떤 x 를 눌러도 탭 0 이 나왔다**(스크롤 전 첫 탭으로 이동하는
            // 사용자 보고, 2026-08-18). 왼쪽은 건너뛰고, 오른쪽에서만 멈춘다.
            if (abs_start + self.tab_w <= self.scroll_cols) continue; // 왼쪽으로 완전히 밀려남
            if (abs_start -| self.scroll_cols >= self.tab_cols) break; // 탭 영역 오른쪽 밖 — 더 볼 것 없음
            const seg = self.segOf(i);
            if (seg.end_px <= seg.start_px) break; // 보이는 폭이 없다(우단에서 완전히 잘림)
            if (x_px < seg.end_px) return i; // 이 탭 우경계 안(좌측 clamp는 첫 보이는 탭이 흡수)
            last_visible = i;
            seen_visible = true;
        }
        // 모든 보이는 탭 우경계 이상 → 마지막 보이는 탭으로 clamp. 보이는 탭이 하나도 없으면(레이아웃이
        // 무너진 경우) 0 을 준다 — 옛 반환값과 같다.
        return if (seen_visible) last_visible else 0;
    }

    /// x_px가 tab_index 탭의 ✕(닫기) zone인가 — **segOf의 close zone**([close_start_px, end_px), 우측 2칸). 제목
    /// glyph의 ✕ 위치와 같은 단일 소스라 보이는 ✕를 정확히 누른다. 세그먼트가 2칸 미만(tab_w<2)이면 ✕ 없음(false).
    pub fn inCloseZone(self: Metrics, tab_index: usize, x_px: f64) bool {
        if (!std.math.isFinite(x_px)) return false;
        const seg = self.segOf(tab_index);
        if (!seg.has_close) return false;
        return x_px >= seg.close_start_px and x_px < seg.end_px;
    }

    /// 우측 "+"(새 Term) zone이 존재하는가 — 바가 넓어 탭 영역에서 칸을 뗐는가(tab_cols < cols).
    pub fn hasPlusZone(self: Metrics) bool {
        return self.tab_cols < self.cols;
    }

    /// 마지막 보이는 탭의 끝 컬럼(인라인 "+" 위치) — 탭이 바를 안 채우면 그 자리(Warp식 인라인), 꽉 차면 tab_cols로 clamp.
    /// 넘쳐서 has_scroll이면 의미 없음(plusZoneStart가 far-right 분기). tab_count=0이면 0(barMetrics가 항상 채움).
    pub fn tabsEndCol(self: Metrics) u32 {
        return @min(self.tab_count * self.tab_w, self.tab_cols);
    }

    /// "+"(새 Term) 버튼 시작 컬럼 — **상단탭 Warp 폴리시: 인라인**(마지막 탭 바로 뒤). 넘쳐서 ‹›가 있으면(has_scroll)
    /// 옛대로 far-right(tab_cols + ‹·gap·› 3칸 뒤). "+" glyph는 plusZoneStart+1에 그린다(렌더 plus_start와 단일 정합).
    pub fn plusZoneStart(self: Metrics) u32 {
        // 오버플로우면 ‹(2칸)·›(2칸) 뒤, 아니면 인라인.
        return if (self.has_scroll) self.tab_cols + scroll_button_cols * 2 else self.tabsEndCol();
    }

    /// "+" 버튼 클릭 폭(컬럼) — 빈 영역이 통째로 +가 되지 않도록 버튼만. **3칸: 좌여백·glyph·우여백**이라
    /// glyph 가 버튼 한가운데에 놓이고(사용자 요청 2026-08-18 "+ 버튼도 가운데로"), 누를 자리가 한 칸이
    /// 아니라 세 칸이다. 인라인 + 오른쪽 빈 바는 여전히 무동작(사용자 결정 ①).
    pub const plus_button_cols: u32 = 3;

    /// ✕(탭 닫기) 버튼의 클릭 폭(컬럼). **3칸: 좌여백·glyph·우여백**이라 glyph 가 버튼 한가운데에 놓인다 —
    /// `plus_button_cols`·`scroll_button_cols` 와 같은 규칙이다.
    ///
    /// **렌더는 이미 좌우 1칸씩 비우고 있었다**(`buildPaneTabBarDrawList`: 제목은 `seg_end-3`까지, ✕ 는
    /// `seg_end-2`, `seg_end-1` 은 우여백). 어긋난 것은 **클릭 zone** 이었다 — 2칸(`[end_col-2, end_col)`)이라
    /// 버튼 배경이 ✕ 왼쪽 가장자리에 딱 붙어 왼쪽 패딩이 없어 보였다(사용자 보고 2026-08-20). zone 을 3칸으로
    /// 넓히면 glyph 위치와 제목 끝은 그대로 두고 배경만 좌우 대칭이 된다.
    pub const close_button_cols: u32 = 3;

    /// ‹ / › 스크롤 버튼 하나의 클릭 폭(컬럼). **3칸: 좌여백·glyph·우여백**이라 glyph 가 버튼 한가운데에
    /// 놓인다 — `plus_button_cols` 와 같은 규칙이다.
    ///
    /// 이력: 옛값 1칸은 누르기 어려웠고(사용자 보고 2026-08-18 "누르는 위치 너무 협소하고 작음"), 그때
    /// 2칸으로 늘리며 glyph 를 **바깥쪽 칸**에 두어 두 버튼 사이 여백을 만들었다. 그러면 버튼 배경 안에서
    /// glyph 가 한쪽에 붙어 ‹ 는 왼쪽 패딩이, › 는 오른쪽 패딩이 없다(사용자 보고 2026-08-20). 3칸+가운데는
    /// 클릭 영역을 더 넓히면서 그 비대칭을 없앤다.
    pub const scroll_button_cols: u32 = 3;

    /// x_px가 "+" 버튼([plusZoneStart, +plus_button_cols)) 안인가. **인라인이라 cols까지가 아니라 버튼 폭으로 한정** —
    /// 마지막 탭 오른쪽 빈 영역을 클릭해도 새 Term이 안 생긴다(①). "+" glyph(plusZoneStart+1)를 포함하는 영역.
    pub fn inPlusZone(self: Metrics, x_px: f64) bool {
        if (!self.hasPlusZone() or !std.math.isFinite(x_px)) return false;
        const ps = self.plusZoneStart();
        const end = @min(ps + plus_button_cols, self.cols);
        return x_px >= self.colPx(ps) and x_px < self.colPx(end);
    }

    /// ‹ glyph 가 놓이는 컬럼 — 자기 3칸 zone 의 **가운데** 칸. 렌더가 이 값을 그대로 쓴다(§5.4 단일 소스).
    pub fn scrollLeftGlyphCol(self: Metrics) u32 {
        return self.tab_cols + scroll_button_cols / 2;
    }

    /// › glyph 가 놓이는 컬럼 — 자기 3칸 zone 의 **가운데** 칸(‹ zone 다음). 두 버튼 모두 가운데 정렬이라
    /// 배경 안에서 glyph 가 한쪽에 붙지 않는다.
    pub fn scrollRightGlyphCol(self: Metrics) u32 {
        return self.tab_cols + scroll_button_cols + scroll_button_cols / 2;
    }

    /// "+" glyph 가 놓이는 컬럼 — 3칸 버튼의 **가운데** 칸.
    pub fn plusGlyphCol(self: Metrics) u32 {
        return self.plusZoneStart() + plus_button_cols / 2;
    }

    /// x_px가 ‹(왼쪽 스크롤) 버튼([tab_cols, +scroll_button_cols)) 안인가 — has_scroll일 때만.
    pub fn inScrollLeftZone(self: Metrics, x_px: f64) bool {
        if (!self.has_scroll or !std.math.isFinite(x_px)) return false;
        return x_px >= self.colPx(self.tab_cols) and x_px < self.colPx(self.tab_cols + scroll_button_cols);
    }

    /// x_px가 ›(오른쪽 스크롤) 버튼([tab_cols+scroll_button_cols, +scroll_button_cols)) 안인가 — has_scroll일 때만.
    pub fn inScrollRightZone(self: Metrics, x_px: f64) bool {
        if (!self.has_scroll or !std.math.isFinite(x_px)) return false;
        const start = self.tab_cols + scroll_button_cols;
        return x_px >= self.colPx(start) and x_px < self.colPx(start + scroll_button_cols);
    }
};

// ── 테스트 ──────────────────────────────────────────────────────────────────────

fn testMetrics() Metrics {
    // bar [x=100, w=80], cell 8 → cols=10. 4 탭, tab_cols=8, tab_w=2(탭 영역 8칸/4) — 탭이 영역을 꽉 채워(4*2=8=tab_cols)
    // 인라인 "+"가 tab_cols(8)에 떨어진다(옛 far-right와 같은 자리 → 기존 경계 테스트 불변). 인라인이 빈 영역에 떨어지는
    // 케이스(탭<영역)는 아래 별도 테스트가 덮는다.
    return .{ .bar_x = 100, .bar_y = 16, .bar_w = 80, .bar_h = 16, .cell_width_px = 8, .cols = 10, .tab_cols = 8, .tab_w = 2, .tab_count = 4 };
}

test "tabbar hit-test: tabIndex·inCloseZone·hasPlusZone·inPlusZone 경계" {
    const m = testMetrics();
    // 탭 영역 [100, 100+8*8=164) px. tab_w=2칸=16px. 탭0=[100,116) 탭1=[116,132) 탭2=[132,148) 탭3=[148,164).
    try std.testing.expectEqual(@as(usize, 0), m.tabIndex(4, 100));
    try std.testing.expectEqual(@as(usize, 0), m.tabIndex(4, 115));
    try std.testing.expectEqual(@as(usize, 1), m.tabIndex(4, 116));
    try std.testing.expectEqual(@as(usize, 3), m.tabIndex(4, 160));
    try std.testing.expectEqual(@as(usize, 3), m.tabIndex(4, 999)); // 탭 영역 우측 clamp → 마지막
    try std.testing.expectEqual(@as(usize, 0), m.tabIndex(4, 50)); // x < bar_x(100) → 좌측 clamp 0
    try std.testing.expectEqual(@as(usize, 0), m.tabIndex(4, std.math.nan(f64))); // 비유한 → 0
    // 거대 Metrics 직접 빌드(public)에서도 0 가드(tab_cols/tab_w 0).
    var degenerate = m;
    degenerate.tab_cols = 0;
    try std.testing.expectEqual(@as(usize, 0), degenerate.tabIndex(4, 130));
    // ✕ zone: 탭0 segEnd=2 → [colPx(0), colPx(2))=[100,116).
    // **2칸 탭엔 ✕가 없다**(제목 자리를 남겨야 하므로 tab_w>=4에서만) — 좁은 탭에서 close zone은 항상 false.
    try std.testing.expect(!m.inCloseZone(0, 100));
    try std.testing.expect(!m.inCloseZone(0, 115));
    // 넉넉한 폭(보이는 폭 5칸 이상)에서만 ✕가 생긴다: tab_w=5 → 탭0=[100,140), ✕ zone은 우측
    // `close_button_cols`(3)칸 = [colPx(2)=116, 140). glyph 는 그 가운데 칸(col 3)이라 좌우 여백이 대칭이다.
    var wide4 = m;
    wide4.tab_w = 5;
    wide4.tab_cols = 10;
    wide4.tab_count = 2;
    try std.testing.expect(!wide4.inCloseZone(0, 115)); // 제목 영역
    try std.testing.expect(wide4.inCloseZone(0, 116)); // zone 첫 칸(✕ 좌여백)도 누르면 닫힌다
    try std.testing.expect(wide4.inCloseZone(0, 139));
    try std.testing.expect(!wide4.inCloseZone(0, 140)); // 탭0 밖
    // "+" zone [8,10)칸 = [164,180).
    try std.testing.expect(m.hasPlusZone());
    try std.testing.expect(m.inPlusZone(164));
    try std.testing.expect(m.inPlusZone(179));
    try std.testing.expect(!m.inPlusZone(180)); // 밖
    try std.testing.expect(!m.inPlusZone(160)); // 탭 영역
    // 좁은 바(tab_cols==cols)면 "+" 없음.
    var narrow = m;
    narrow.tab_cols = narrow.cols;
    try std.testing.expect(!narrow.hasPlusZone());
    try std.testing.expect(!narrow.inPlusZone(179));
    // tab_w<2면 ✕ zone 없음.
    var thin = m;
    thin.tab_w = 1;
    try std.testing.expect(!thin.inCloseZone(0, 100));
}

test "tabbar 인라인 +: 탭이 영역을 안 채우면 마지막 탭 바로 뒤에 + (빈 영역은 무동작), 넘치면 far-right" {
    // 탭 2개만(tab_w=2 → tabsEnd=4 < tab_cols=8). 인라인 + = col 4부터. 빈 영역 [6,8)·far-right [8,10)은 +가 아니다.
    var m = testMetrics();
    m.tab_count = 2;
    try std.testing.expectEqual(@as(u32, 4), m.tabsEndCol()); // 마지막 탭(탭1) 끝 = 2*2
    try std.testing.expectEqual(@as(u32, 4), m.plusZoneStart()); // 인라인(far-right tab_cols=8 아님)
    // + 버튼 = 3칸 [4,7) = colPx [132,156). glyph 는 **가운데 칸**(5 = 140px)이라 좌우 여백이 같다.
    try std.testing.expect(m.inPlusZone(132)); // + 좌단
    try std.testing.expectEqual(@as(u32, 5), m.plusGlyphCol()); // 가운데 칸
    try std.testing.expect(m.inPlusZone(140)); // glyph
    try std.testing.expect(m.inPlusZone(155)); // + 우단 직전
    try std.testing.expect(!m.inPlusZone(156)); // + 버튼 밖(빈 영역 시작) — 새 Term 안 만듦(①)
    try std.testing.expect(!m.inPlusZone(170)); // 옛 far-right 자리도 이제 +가 아니다
    // 넘쳐서 has_scroll이면 far-right 유지(인라인 아님): plusZoneStart = tab_cols(6) + ‹›(3+3) = 12.
    var ov = testMetrics();
    ov.has_scroll = true;
    ov.tab_cols = 6;
    ov.tab_count = 8; // 넘침
    try std.testing.expectEqual(@as(u32, 12), ov.plusZoneStart()); // ‹(3칸)·›(3칸) 뒤 far-right
    try std.testing.expect(!ov.inPlusZone(160)); // ‹› 영역은 + 아님
}

test "tabbar segOf: 탭 픽셀 경계 단일 소스 — hit-test와 정합(셀-열 정렬, 패딩 0)" {
    const m = testMetrics();
    // 탭0=[100,116) 탭3=[148,164). **2칸 탭엔 ✕가 없다** — ✕는 좌우 한 칸씩 패딩을 두고 제목 자리를 최소 1칸
    // 남겨야 하므로 tab_w>=4에서만 존재한다(렌더 buildPaneTabBarDrawList와 같은 조건).
    const s0 = m.segOf(0);
    try std.testing.expectEqual(@as(u32, 0), s0.start_col); // 셀 경계(view 밴드·제목용)
    try std.testing.expectEqual(@as(u32, 2), s0.end_col);
    try std.testing.expectEqual(@as(f64, 100), s0.start_px);
    try std.testing.expectEqual(@as(f64, 116), s0.end_px);
    try std.testing.expect(!s0.has_close); // 2칸 = ✕ 접힘

    // 폭이 넉넉하면(보이는 폭 5칸) ✕가 생기고 zone은 우측 2칸 = [end-2cell, end).
    var wide = m;
    wide.tab_w = 5;
    wide.tab_cols = 10;
    wide.tab_count = 2;
    const w0 = wide.segOf(0);
    try std.testing.expect(w0.has_close);
    try std.testing.expectEqual(wide.colPx(w0.end_col - Metrics.close_button_cols), w0.close_start_px);
    const s3 = m.segOf(3);
    try std.testing.expectEqual(@as(f64, 148), s3.start_px);
    try std.testing.expectEqual(@as(f64, 164), s3.end_px);
    // tab_w<2면 ✕ 없음(segOf 단일 소스 — inCloseZone과 같은 조건).
    var thin = m;
    thin.tab_w = 1;
    try std.testing.expect(!thin.segOf(0).has_close);
    // hit-test가 segOf 경계와 정합: 탭0 우경계 = 탭1 시작, ✕ zone이 segOf.close와 일치.
    try std.testing.expectEqual(@as(usize, 1), m.tabIndex(4, s0.end_px)); // end_px(반열림)는 다음 탭
    // 2칸 탭(testMetrics)은 ✕가 없으므로 close zone도 없다 — 넉넉한 폭(wide)에서 정합을 확인한다.
    try std.testing.expect(!m.inCloseZone(3, s3.start_px));
    const w1 = wide.segOf(1);
    try std.testing.expect(wide.inCloseZone(1, w1.close_start_px));
    try std.testing.expect(!wide.inCloseZone(1, w1.end_px)); // end는 반열림 밖
}

test "tabbar tabIndex: overflow(term>탭칸) — 안 보이는 탭을 hit하지 않고 마지막 보이는 탭으로 clamp" {
    // tab_w=1, tab_cols=8, term=10 → 탭0~7만 보임(영역 [100, colPx(8)=164)), 탭8·9는 영역 초과(안 보임).
    // 좁은 바에서 paneTabWidth가 tab_w를 1로 collapse하는 실제 상황. 각 탭i=[100+i*8, 100+(i+1)*8).
    var m = testMetrics();
    m.tab_w = 1;
    try std.testing.expectEqual(@as(usize, 7), m.tabIndex(10, 999)); // 우측 밖 → 마지막 보이는(7), term-1(9) 아님
    try std.testing.expectEqual(@as(usize, 7), m.tabIndex(10, 164)); // 탭 영역 우경계(+ zone 시작) → 7, 안 보이는 8/9 아님
    try std.testing.expectEqual(@as(usize, 0), m.tabIndex(10, 100)); // 탭0 좌단
    try std.testing.expectEqual(@as(usize, 5), m.tabIndex(10, 145)); // 탭5=[140,148)
    // overflow가 없으면(term=4 <= 보이는 탭 수) 기존대로 마지막 보이는 탭(3)으로 clamp.
    try std.testing.expectEqual(@as(usize, 3), m.tabIndex(4, 999));
}

// 스크롤된 탭 바에서 **보이는 탭을 눌렀는데 다른 Term 이 열리던 버그**(2026-08-18 사용자 보고: "스크롤
// 마지막 꺼 눌렀을 때 스크롤되기 전 서페이스로 이동"). 원인은 `tabIndex` 가 폭 0 인 첫 탭에서 순회를
// 끊은 것이고, 왼쪽으로 스크롤아웃된 탭이 정확히 폭 0 이라 **한 탭만 밀려도 항상 탭 0** 이 나왔다.
test "tabbar: 왼쪽으로 스크롤아웃된 탭이 있어도 보이는 탭을 정확히 집는다" {
    var m = testMetrics();
    m.tab_w = 2; // 탭 하나가 2칸(16px), 바는 [100, 180), tab_cols=8
    m.tab_cols = 8;
    m.scroll_cols = 4; // 탭 0·1 이 왼쪽으로 완전히 밀려났다

    // 화면 첫 자리(=절대 탭2)를 누르면 2 여야 한다. 옛 코드는 탭0 에서 break 해 0 을 돌려줬다.
    try std.testing.expectEqual(@as(usize, 2), m.tabIndex(8, 100));
    try std.testing.expectEqual(@as(usize, 2), m.tabIndex(8, 115));
    // 그 다음 자리는 탭3.
    try std.testing.expectEqual(@as(usize, 3), m.tabIndex(8, 120));
    // 오른쪽 끝을 넘겨 누르면 마지막 **보이는** 탭으로 clamp 된다(탭 영역 8칸 = 절대 [4,12) → 탭 2..5).
    try std.testing.expectEqual(@as(usize, 5), m.tabIndex(8, 999));
    // ✕ zone 도 같은 세그먼트를 쓰므로 함께 따라온다.
    try std.testing.expect(!m.inCloseZone(0, 100)); // 밀려난 탭은 닫기 영역이 없다
}

// ‹ / › 버튼은 **각 2칸**이다(옛 1칸은 누르기 어려웠다 — 사용자 보고 2026-08-18). glyph 는 자기 버튼의
// 바깥쪽 칸에 놓여 둘 사이에 여백이 생기고, "+" 는 3칸 버튼의 가운데 칸이다.
test "tabbar: ‹›·+ 는 각 3칸 버튼이고 glyph 는 모두 가운데 칸" {
    var m = testMetrics();
    m.has_scroll = true;
    m.cols = 14; // ‹[4,7) ›[7,10) plus[10,13) 을 담을 폭
    m.tab_cols = 4; // colPx: 4=132,5=140,6=148,7=156,8=164,9=172,10=180,11=188,12=196,13=204.
    try std.testing.expect(m.inScrollLeftZone(132));
    try std.testing.expect(m.inScrollLeftZone(155));
    try std.testing.expect(!m.inScrollLeftZone(156)); // 여기부터 ›
    try std.testing.expect(m.inScrollRightZone(156));
    try std.testing.expect(m.inScrollRightZone(179));
    try std.testing.expect(!m.inScrollRightZone(180)); // 여기부터 +
    // **glyph 는 셋 다 자기 3칸 버튼의 가운데 칸**이라 버튼 배경 안에서 한쪽에 붙지 않는다
    // (옛 2칸·바깥쪽 배치는 ‹ 의 왼쪽 패딩이, › 의 오른쪽 패딩이 0 이었다 — 사용자 보고 2026-08-20).
    try std.testing.expectEqual(@as(u32, 5), m.scrollLeftGlyphCol()); // ‹[4,7) 의 가운데
    try std.testing.expectEqual(@as(u32, 8), m.scrollRightGlyphCol()); // ›[7,10) 의 가운데
    try std.testing.expectEqual(@as(u32, 10), m.plusZoneStart());
    try std.testing.expectEqual(@as(u32, 11), m.plusGlyphCol()); // +[10,13) 의 가운데
    try std.testing.expect(m.inPlusZone(180));
    try std.testing.expect(m.inPlusZone(203));
    try std.testing.expect(!m.inPlusZone(140)); // ‹ 위치는 plus 아님
    // has_scroll=false면 ‹› 없음(scroll zone false), plus는 tab_cols(8)부터 3칸.
    const no = testMetrics();
    try std.testing.expect(!no.inScrollLeftZone(150));
    try std.testing.expect(no.inPlusZone(165)); // plus_start=8 → [colPx(8), colPx(10)=cols clamp)
}
