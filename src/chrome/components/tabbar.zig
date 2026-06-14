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

    /// x_px가 가리키는 Term 탭 인덱스([0, term_count-1] clamp). x를 탭 영역으로 clamp한다("+" zone은 마지막 탭으로
    /// 떨어지므로 호출자가 inPlusZone을 **먼저** 검사해야 한다). float clamp 후 cast라 거대 좌표도 trap 없음.
    pub fn tabIndex(self: Metrics, term_count: usize, x_px: f64) usize {
        if (term_count == 0 or !std.math.isFinite(x_px) or self.tab_cols == 0 or self.tab_w == 0) return 0;
        const cw: f64 = @floatFromInt(self.cell_width_px);
        const max_col: f64 = @floatFromInt(self.tab_cols - 1);
        const rel = std.math.clamp((x_px - @as(f64, @floatFromInt(self.bar_x))) / cw, 0, max_col);
        const col: u32 = @intFromFloat(rel);
        return @min(col / self.tab_w, term_count - 1);
    }

    /// x_px가 tab_index 탭의 ✕(닫기) zone인가 — 세그먼트 우측 2칸([segEnd-2, segEnd)). 제목 glyph의 ✕ 위치(col=segEnd-2)와
    /// 정렬해 보이는 ✕를 정확히 누른다. 세그먼트가 2칸 미만(tab_w<2)이면 ✕ 없음(false).
    pub fn inCloseZone(self: Metrics, tab_index: usize, x_px: f64) bool {
        if (self.tab_w < 2 or !std.math.isFinite(x_px)) return false;
        const seg_end = self.segEnd(tab_index);
        if (seg_end < 2) return false;
        return x_px >= self.colPx(seg_end - 2) and x_px < self.colPx(seg_end);
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
    try std.testing.expectEqual(@as(usize, 0), m.tabIndex(4, std.math.nan(f64))); // 비유한 → 0
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
