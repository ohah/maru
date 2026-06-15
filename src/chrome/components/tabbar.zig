//! Tabbar — pane 탭 바의 컬럼 분할 hit-test. chrome **마우스 hit-test 컴포넌트**(divider/sidebar 동형 — State 없는
//! 순수 함수). 바를 [탭 영역(tab_cols) | "+" zone]으로 나눠 탭 인덱스·✕(닫기)·"+"(새 Term) zone을 판정한다(옛
//! app_dev_session BarMetrics 수학 이전 — 호출처가 `m.tabIndex(...)`를 그대로 쓰도록 Metrics **메서드**로 둔다). 탭
//! 전환/닫기/새 Term/드래그·드롭·제목 glyph·라이브 `*Pane`은 platform이 든다(§6). 활성 탭 강조 **밴드는 platform이
//! 단일 셀로 직접** 그린다(`tabbarHighlightCell`) — 밴드가 한 칸이라 chrome ChromeDraw→cell round-trip이 무의미하기
//! 때문(C3a 리뷰 §3 반영; divider/sidebar의 다중 op view와 달리 tabbar는 hit-test만 chrome). host가 `Metrics`를
//! platform에서 변환 주입하고, 제목/✕/+ glyph·활성 밴드는 platform이 같은 분할로 그려 "보이는 탭/✕/+ == 클릭되는 것".
//! 단일 출처: docs/chrome-strategy.md §5.4, docs/layering-and-portability.md §5(C3b).

const std = @import("std");

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

    /// 바 좌단 기준 col의 픽셀 경계. tab_index 세그먼트는 [col*cw, segEnd*cw).
    fn colPx(self: Metrics, col: u32) f64 {
        return @as(f64, @floatFromInt(self.bar_x)) + @as(f64, @floatFromInt(col)) * @as(f64, @floatFromInt(self.cell_width_px));
    }

    /// tab_index 세그먼트의 끝 컬럼(우경계, tab_cols로 clamp). platform 활성 밴드(start [i*tab_w, +tab_w))와 같은 분할.
    pub fn segEnd(self: Metrics, tab_index: usize) u32 {
        return @min((@as(u32, @intCast(tab_index)) + 1) * self.tab_w, self.tab_cols);
    }

    /// 탭 하나의 **픽셀 경계 단일 소스**(§6) — 현재는 hit-test(tabIndex·inCloseZone)가 이 한 함수를 공유한다.
    /// platform view 그리기(밴드·제목·✕: tabbarHighlightCell·buildPaneTabBarDrawList)는 아직 셀-열을 직접 계산하며,
    /// 다음 단계에서 이 함수를 소비하도록 옮겨 "보이는 탭/✕ == 클릭되는 것"을 완성한다(그 전까진 둘 다 셀-열이라
    /// 우연히 일치). [start_px, end_px)가 탭의 영역(반열림), close_*는 ✕(닫기) zone(우측 2칸 [end-2cell, end)).
    /// tab_w<2면 ✕ 없음(has_close=false). 전부 bar_x 기준 절대 backing px.
    pub const TabSeg = struct {
        start_px: f64,
        end_px: f64,
        close_start_px: f64,
        has_close: bool,
    };

    /// 탭 tab_index의 픽셀 세그먼트. 현재는 **셀-열 정렬**(start=tab_index*tab_w 컬럼, end=segEnd 컬럼의 px) —
    /// 패딩 0이라 시각/동작이 기존 셀-열 hit-test와 동일하다. 둥근 탭(C4b-5)에서 탭 패딩을 더하면 **여기 한 곳만**
    /// 바뀌어 view·hit-test가 동시에 움직인다(§6 seam 해소의 토대). colPx/segEnd를 재사용한다.
    pub fn segOf(self: Metrics, tab_index: usize) TabSeg {
        const start_col = @as(u32, @intCast(tab_index)) * self.tab_w;
        const end_col = self.segEnd(tab_index);
        const has_close = self.tab_w >= 2 and end_col >= 2;
        return .{
            .start_px = self.colPx(start_col),
            .end_px = self.colPx(end_col),
            .close_start_px = if (has_close) self.colPx(end_col - 2) else 0,
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
        var i: usize = 0;
        while (i < term_count) : (i += 1) {
            const seg = self.segOf(i);
            if (seg.end_px <= seg.start_px) break; // overflow(안 보이는) 탭 — 탭 영역 초과, 더 볼 것 없음
            if (x_px < seg.end_px) return i; // 이 탭 우경계 안(좌측 clamp는 탭0.end가 흡수)
            last_visible = i;
        }
        return last_visible; // 모든 보이는 탭 우경계 이상 → 마지막 보이는 탭으로 clamp
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

    /// x_px가 "+" zone([tab_cols, cols)) 안인가. "+" zone이 없으면(좁은 바) false. "+" glyph(col=tab_cols+1)와 같은 영역.
    pub fn inPlusZone(self: Metrics, x_px: f64) bool {
        if (!self.hasPlusZone() or !std.math.isFinite(x_px)) return false;
        return x_px >= self.colPx(self.tab_cols) and x_px < self.colPx(self.cols);
    }
};

// ── 테스트 ──────────────────────────────────────────────────────────────────────

fn testMetrics() Metrics {
    // bar [x=100, w=80], cell 8 → cols=10. 4 탭, tab_cols=8("+" zone [8,10)), tab_w=2(탭 영역 8칸/4).
    return .{ .bar_x = 100, .bar_y = 16, .bar_w = 80, .bar_h = 16, .cell_width_px = 8, .cols = 10, .tab_cols = 8, .tab_w = 2 };
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
    try std.testing.expect(m.inCloseZone(0, 100));
    try std.testing.expect(m.inCloseZone(0, 115));
    try std.testing.expect(!m.inCloseZone(0, 116)); // 탭0 밖
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

test "tabbar segOf: 탭 픽셀 경계 단일 소스 — hit-test와 정합(셀-열 정렬, 패딩 0)" {
    const m = testMetrics();
    // 탭0=[100,116) 탭3=[148,164). 2칸 탭이라 ✕는 [end-2cell, end)=세그먼트 전체.
    const s0 = m.segOf(0);
    try std.testing.expectEqual(@as(f64, 100), s0.start_px);
    try std.testing.expectEqual(@as(f64, 116), s0.end_px);
    try std.testing.expect(s0.has_close);
    try std.testing.expectEqual(@as(f64, 100), s0.close_start_px);
    const s3 = m.segOf(3);
    try std.testing.expectEqual(@as(f64, 148), s3.start_px);
    try std.testing.expectEqual(@as(f64, 164), s3.end_px);
    // tab_w<2면 ✕ 없음(segOf 단일 소스 — inCloseZone과 같은 조건).
    var thin = m;
    thin.tab_w = 1;
    try std.testing.expect(!thin.segOf(0).has_close);
    // hit-test가 segOf 경계와 정합: 탭0 우경계 = 탭1 시작, ✕ zone이 segOf.close와 일치.
    try std.testing.expectEqual(@as(usize, 1), m.tabIndex(4, s0.end_px)); // end_px(반열림)는 다음 탭
    try std.testing.expect(m.inCloseZone(3, s3.close_start_px));
    try std.testing.expect(!m.inCloseZone(3, s3.end_px)); // end는 반열림 밖
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
