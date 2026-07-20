//! L2 session core — 순수 레이아웃 기하(OS·platform 무관). backing 픽셀 ↔ 터미널 grid·셀 hit-test·
//! drop-zone 분할·pt↔px 환산을 모은다. platform/macos/app_session에서 추출했다
//! (docs/app-session-decomposition.md "(b) 순수→session 이식 기여" 분리). terminal.Size·split_tree.Rect·
//! input_math의 placeholder cell 메트릭만 의존하고 platform/pty/renderer/AppKit을 모른다 —
//! tests/boundary/imports.zig가 강제. 순수 함수라 OS·렌더 없이 단위 테스트로 동작을 고정한다(다른 OS
//! 어댑터도 이 grid·hit-test 계산을 그대로 재사용 — 이식 기여).

const std = @import("std");
const terminal = @import("../terminal.zig");
const split_tree = @import("split_tree.zig");
const input_math = @import("input_math.zig"); // placeholder cell 메트릭 단일 출처(휠 환산과 공유)

const SplitRect = split_tree.Rect;

/// 터미널 셀↔컨테이너 가장자리 4방 inset(backing px). 비대칭 window padding을 한 단위로 전달한다 —
/// gridFromBacking이 left+right·top+bottom을 grid에서 빼고, paneTermRect가 좌상으로 left/top만큼 들인다.
pub const PaddingPx = struct { left: u32 = 0, right: u32 = 0, top: u32 = 0, bottom: u32 = 0 };

/// 사각형 안쪽에 4방 padding을 적용한다. terminal grid와 WKWebView frame이 같은 산술을 소비해 두 콘텐츠의
/// 여백이 어긋나지 않게 한다. 과대한 값은 origin/end를 원본 rect 안으로 clamp하고 크기를 0으로 saturate한다.
pub fn insetRect(rect: SplitRect, padding: PaddingPx) SplitRect {
    const right = rect.x +| rect.w;
    const bottom = rect.y +| rect.h;
    const x = @min(rect.x +| padding.left, right);
    const y = @min(rect.y +| padding.top, bottom);
    return .{
        .x = x,
        .y = y,
        .w = (right - x) -| padding.right,
        .h = (bottom - y) -| padding.bottom,
    };
}

/// 드래그한 Term을 다른 pane '본문'에 떨어뜨릴 때의 가장자리 절반(④ split 재배치). left/right=좌우 split,
/// top/bottom=상하 split.
pub const PaneDropZone = enum { left, right, top, bottom };

/// backing 픽셀 크기와 cell 픽셀 크기로 터미널 grid(cols/rows)를 구한다. cell 크기가 0이면
/// placeholder로 대체하고, u16 상한으로 막은 뒤 terminal.clampGridSize로 최소 크기(cols>=2)를
/// 적용한다 — cols>=2 불변식은 TerminalCore가 단일 소유하므로 여기서 직접 하드코딩하지 않는다.
pub fn gridFromBacking(backing_width_px: u32, backing_height_px: u32, cell_width_px: u32, cell_height_px: u32, sidebar_width_px: u32, padding: PaddingPx) terminal.Size {
    const cell_w = if (cell_width_px > 0) cell_width_px else input_math.placeholder_cell_width_px;
    const cell_h = if (cell_height_px > 0) cell_height_px else input_math.placeholder_cell_height_px;
    // 터미널 영역 = drawable − 세로 사이드바 폭 − 좌우 padding(left+right) − 상하 padding(top+bottom).
    // 사이드바/패딩이 drawable보다 큰 비정상 상황은 0으로 saturate(언더플로 방지)해 clampGridSize가 최소 grid로
    // 떨어뜨린다. termRect도 같은 양을 들이므로 spawn grid와 실제 pane grid가 정합한다(PR8 spawn-크기 레이스 회피).
    const term_width = backing_width_px -| sidebar_width_px -| padding.left -| padding.right;
    const term_height = backing_height_px -| padding.top -| padding.bottom;
    const raw_cols = @min(term_width / cell_w, std.math.maxInt(u16));
    const raw_rows = @min(term_height / cell_h, std.math.maxInt(u16));
    return terminal.clampGridSize(.{ .cols = @intCast(raw_cols), .rows = @intCast(raw_rows) });
}

/// 사이드바를 이미 뺀 sub-사각형(panel leaf rect)의 픽셀 폭/높이로 grid를 구한다. `gridFromBacking`과
/// 같은 cell/clamp 규칙이되 사이드바를 빼지 않는다(rect가 이미 터미널 영역 내부) — split된 panel을 자기
/// leaf rect grid로 resize할 때 쓴다. 단일 leaf(rect.w = backing − sidebar)면 gridFromBacking과 동일.
pub fn gridFromRectPx(cell_width_px: u32, cell_height_px: u32, w_px: u32, h_px: u32) terminal.Size {
    const cell_w = if (cell_width_px > 0) cell_width_px else input_math.placeholder_cell_width_px;
    const cell_h = if (cell_height_px > 0) cell_height_px else input_math.placeholder_cell_height_px;
    const raw_cols = @min(w_px / cell_w, std.math.maxInt(u16));
    const raw_rows = @min(h_px / cell_h, std.math.maxInt(u16));
    return terminal.clampGridSize(.{ .cols = @intCast(raw_cols), .rows = @intCast(raw_rows) });
}

/// 논리 pt → backing 정수 px(분수 scale milli, ×scale_milli/1000). sidebar 폭·window padding 4방 같은 정수
/// pt 환산의 단일 출처다(letter-spacing의 f32 경로는 분수 정밀이 필요해 applyFontSpacing이 별도로 처리한다).
pub fn ptToPx(pt: u32, scale_milli: u32) u32 {
    const scaled = @as(u64, pt) * @as(u64, scale_milli) / 1000;
    return @intCast(@min(scaled, std.math.maxInt(u32)));
}

/// 점(backing px)이 사각형 안인가([x, x+w) × [y, y+h) 반열린). 탭 바 클릭 hit-test에 쓴다. 비유한은 false.
pub fn pointInRect(x_px: f64, y_px: f64, rect: SplitRect) bool {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    return x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(rect.w)) and
        y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(rect.h));
}

/// rect를 zone 방향 절반으로 자른다(④b 하이라이트가 그 절반을 칠한다). left/right=좌우, top/bottom=상하.
pub fn halfRect(rect: SplitRect, zone: PaneDropZone) SplitRect {
    return switch (zone) {
        .left => .{ .x = rect.x, .y = rect.y, .w = rect.w / 2, .h = rect.h },
        .right => .{ .x = rect.x + rect.w / 2, .y = rect.y, .w = rect.w - rect.w / 2, .h = rect.h },
        .top => .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h / 2 },
        .bottom => .{ .x = rect.x, .y = rect.y + rect.h / 2, .w = rect.w, .h = rect.h - rect.h / 2 },
    };
}

/// 점이 rect 안 어느 drop zone인지 — rect를 중앙에서 X자로 4등분해 가장 가까운 가장자리를 고른다(좌/우/상/하).
/// rect 밖·0 크기·비유한이면 null. 렌더 drop-zone 하이라이트(④b)와 공유할 순수 함수라 OS 무관 단위 테스트.
pub fn paneDropZone(rect: SplitRect, x_px: f64, y_px: f64) ?PaneDropZone {
    if (rect.w == 0 or rect.h == 0 or !pointInRect(x_px, y_px, rect)) return null;
    const fx = (x_px - @as(f64, @floatFromInt(rect.x))) / @as(f64, @floatFromInt(rect.w)); // [0,1)
    const fy = (y_px - @as(f64, @floatFromInt(rect.y))) / @as(f64, @floatFromInt(rect.h));
    const dx = @min(fx, 1 - fx); // 좌/우 가장자리까지의 거리(작을수록 가깝다)
    const dy = @min(fy, 1 - fy); // 상/하 가장자리까지의 거리
    if (dx <= dy) return if (fx < 0.5) .left else .right;
    return if (fy < 0.5) .top else .bottom;
}

/// 셀 hit-test 결과 — (row,col)은 grid 안 클램프된 셀, term_*_px는 그 pane 본문 좌상단 기준 backing 픽셀
/// (SGR-Pixels(1016) mouse 리포트용 — 셀과 같은 origin·음수 0 clamp).
pub const CellHit = struct { row: u16, col: u16, term_x_px: u16, term_y_px: u16 };

/// backing 픽셀 (x,y)를 pane 본문 rect(origin·크기) 기준 (row,col) 셀로 변환한다(grid 안 clamp). cell 크기 0이면
/// placeholder. 핵심: 클램프를 float 도메인에서 먼저 한 뒤 @intFromFloat 한다 — 거대한 finite 좌표(손상/악성
/// 입력)가 i64 변환에서 trap(앱 패닉)하던 것을 막는다. 비유한값은 null, panel 왼쪽/위 바깥(음수) 좌표는 0 clamp.
/// cols/rows는 활성 surface의 `core.size`(>=2 보장), rect는 paneTermRect(window padding·사이드바 origin 포함).
pub fn pxToCell(cell_width_px: u32, cell_height_px: u32, cols: u16, rows: u16, rect: SplitRect, x_px: f64, y_px: f64) ?CellHit {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    const cw: f64 = @floatFromInt(if (cell_width_px > 0) cell_width_px else input_math.placeholder_cell_width_px);
    const ch: f64 = @floatFromInt(if (cell_height_px > 0) cell_height_px else input_math.placeholder_cell_height_px);
    const max_col: f64 = @floatFromInt(cols - 1);
    const max_row: f64 = @floatFromInt(rows - 1);
    // panel은 자기 rect의 origin에서 그려지므로 스크린 좌표에서 그 origin을 빼야 panel의 열/행이 된다(안 빼면
    // 선택/클릭이 origin만큼 어긋남). panel 왼쪽/위 바깥(음수)은 0 clamp라 (0,0) 모서리에 붙는다.
    const term_x = x_px - @as(f64, @floatFromInt(rect.x));
    const term_y = y_px - @as(f64, @floatFromInt(rect.y));
    const col_f = std.math.clamp(@max(term_x, 0) / cw, 0, max_col);
    const row_f = std.math.clamp(@max(term_y, 0) / ch, 0, max_row);
    // SGR-Pixels(1016)용 픽셀: 셀과 같은 origin·0 clamp로 터미널 영역 backing px를 구한다. 영역 폭/높이-1로
    // clamp하고 u16 상한(65535)으로 saturate해 @intFromFloat가 안전하다.
    const max_x: f64 = @min(@max(@as(f64, @floatFromInt(cols)) * cw - 1, 0), 65535);
    const max_y: f64 = @min(@max(@as(f64, @floatFromInt(rows)) * ch - 1, 0), 65535);
    const px_x = std.math.clamp(@max(term_x, 0), 0, max_x);
    const px_y = std.math.clamp(@max(term_y, 0), 0, max_y);
    return .{
        .row = @intFromFloat(row_f),
        .col = @intFromFloat(col_f),
        .term_x_px = @intFromFloat(px_x),
        .term_y_px = @intFromFloat(px_y),
    };
}

test "gridFromBacking divides backing pixels by cell size with placeholder + clamps" {
    // 960×600 backing at 8×18 cell -> 120×33 (이전엔 Swift가 placeholder 12×24로 80×25를 잡아
    // 창과 grid가 어긋났다). 이제 app session이 실제 메트릭으로 직접 계산한다.
    try std.testing.expectEqual(terminal.Size{ .cols = 120, .rows = 33 }, gridFromBacking(960, 600, 8, 18, 0, .{}));
    // cell 크기 0(메트릭 없음, 이론상) -> placeholder 12×24.
    try std.testing.expectEqual(terminal.Size{ .cols = 80, .rows = 25 }, gridFromBacking(960, 600, 0, 0, 0, .{}));
    // floor 동작 + 최소 1×1.
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 1 }, gridFromBacking(25, 16, 10, 16, 0, .{}));
    // cols는 최소 2(TerminalCore가 wide glyph continuation 때문에 요구). 1픽셀/100px cell이라도 2칸.
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 1 }, gridFromBacking(1, 1, 100, 100, 0, .{}));
    // 세로 사이드바 폭만큼 터미널 cols가 줄어든다: 960px − 160px 사이드바 = 800px / 8 = 100 cols(vs 120).
    try std.testing.expectEqual(terminal.Size{ .cols = 100, .rows = 33 }, gridFromBacking(960, 600, 8, 18, 160, .{}));
    // 사이드바가 drawable보다 넓은 비정상도 언더플로 없이 최소 grid로 떨어진다(saturate).
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 33 }, gridFromBacking(960, 600, 8, 18, 2000, .{}));
    // window padding(대칭 8/4): 좌우 합 16px·상하 합 8px를 grid에서 뺀다. cols: (960−16)/8=118, rows: (600−8)/18=32.
    try std.testing.expectEqual(terminal.Size{ .cols = 118, .rows = 32 }, gridFromBacking(960, 600, 8, 18, 0, .{ .left = 8, .right = 8, .top = 4, .bottom = 4 }));
    // 사이드바 + padding 동시: cols (960−160−16)/8=98, rows (600−8)/18=32.
    try std.testing.expectEqual(terminal.Size{ .cols = 98, .rows = 32 }, gridFromBacking(960, 600, 8, 18, 160, .{ .left = 8, .right = 8, .top = 4, .bottom = 4 }));
    // 비대칭 padding: left=10·right=20(합 30)·top=4·bottom=8(합 12). cols (960−30)/8=116, rows (600−12)/18=32.
    try std.testing.expectEqual(terminal.Size{ .cols = 116, .rows = 32 }, gridFromBacking(960, 600, 8, 18, 0, .{ .left = 10, .right = 20, .top = 4, .bottom = 8 }));
    // 비정상 큰 padding도 언더플로 없이 최소 grid로 saturate.
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 1 }, gridFromBacking(960, 600, 8, 18, 0, .{ .left = 10000, .right = 10000, .top = 10000, .bottom = 10000 }));
}

test "ptToPx uses a wide intermediate and saturates damaged persisted values" {
    try std.testing.expectEqual(@as(u32, 600), ptToPx(300, 2000));
    try std.testing.expectEqual(std.math.maxInt(u32), ptToPx(std.math.maxInt(u32), 1000));
    try std.testing.expectEqual(std.math.maxInt(u32), ptToPx(std.math.maxInt(u32), std.math.maxInt(u32)));
}

test "pointInRect uses half-open bounds (탭 바·divider·pane hit-test 공유)" {
    const bar: SplitRect = .{ .x = 180, .y = 0, .w = 240, .h = 12 }; // 우경계 = 180+240 = 420
    try std.testing.expect(pointInRect(180, 0, bar)); // 좌상단 포함
    try std.testing.expect(pointInRect(419, 11, bar)); // 우하 안쪽
    try std.testing.expect(!pointInRect(420, 0, bar)); // x = x+w 제외
    try std.testing.expect(!pointInRect(180, 12, bar)); // y = y+h 제외
    try std.testing.expect(!pointInRect(179, 0, bar)); // 좌측 밖
    try std.testing.expect(!pointInRect(std.math.nan(f64), 0, bar)); // 비유한
}

test "insetRect applies asymmetric content padding and clamps an oversized inset inside the source" {
    const rect: SplitRect = .{ .x = 100, .y = 50, .w = 400, .h = 300 };
    try std.testing.expectEqual(
        SplitRect{ .x = 108, .y = 54, .w = 376, .h = 288 },
        insetRect(rect, .{ .left = 8, .right = 16, .top = 4, .bottom = 8 }),
    );

    const clamped = insetRect(rect, .{ .left = 1000, .right = 2000, .top = 3000, .bottom = 4000 });
    try std.testing.expectEqual(rect.x + rect.w, clamped.x);
    try std.testing.expectEqual(rect.y + rect.h, clamped.y);
    try std.testing.expectEqual(@as(u32, 0), clamped.w);
    try std.testing.expectEqual(@as(u32, 0), clamped.h);
}

// paneDropZone이 rect를 X자 4등분해 가장 가까운 가장자리를 고르는지(④ split 재배치 drop-zone). 순수 함수.
test "paneDropZone classifies a point into the nearest edge half" {
    const r: SplitRect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expectEqual(PaneDropZone.left, paneDropZone(r, 10, 50).?); // 좌측 가장자리 근처
    try std.testing.expectEqual(PaneDropZone.right, paneDropZone(r, 90, 50).?); // 우측
    try std.testing.expectEqual(PaneDropZone.top, paneDropZone(r, 50, 10).?); // 상단
    try std.testing.expectEqual(PaneDropZone.bottom, paneDropZone(r, 50, 90).?); // 하단
    try std.testing.expectEqual(PaneDropZone.left, paneDropZone(r, 25, 50).?); // 중앙 좌측(dx<dy)
    // rect 밖·0 크기·비유한이면 null.
    try std.testing.expect(paneDropZone(r, 150, 50) == null);
    try std.testing.expect(paneDropZone(.{ .x = 0, .y = 0, .w = 0, .h = 100 }, 0, 50) == null);
    try std.testing.expect(paneDropZone(r, std.math.nan(f64), 50) == null);
}

// halfRect가 rect를 zone 방향 절반으로 자르는지(④b 하이라이트). 순수.
test "halfRect splits a rect by zone" {
    const r: SplitRect = .{ .x = 10, .y = 20, .w = 100, .h = 80 };
    try std.testing.expectEqual(SplitRect{ .x = 10, .y = 20, .w = 50, .h = 80 }, halfRect(r, .left));
    try std.testing.expectEqual(SplitRect{ .x = 60, .y = 20, .w = 50, .h = 80 }, halfRect(r, .right));
    try std.testing.expectEqual(SplitRect{ .x = 10, .y = 20, .w = 100, .h = 40 }, halfRect(r, .top));
    try std.testing.expectEqual(SplitRect{ .x = 10, .y = 60, .w = 100, .h = 40 }, halfRect(r, .bottom));
}

test "pxToCell maps backing px to clamped cell with rect origin offset" {
    const r: SplitRect = .{ .x = 0, .y = 0, .w = 640, .h = 432 };
    try std.testing.expectEqual(@as(u16, 2), pxToCell(8, 18, 80, 24, r, 16, 0).?.col); // x=16/8=2
    try std.testing.expectEqual(@as(u16, 1), pxToCell(8, 18, 80, 24, r, 0, 18).?.row); // y=18/18=1
    // rect origin offset(상하 split의 아래 panel): origin (0,16) → y에서 16 뺀 뒤 행.
    const r2: SplitRect = .{ .x = 0, .y = 16, .w = 640, .h = 432 };
    try std.testing.expectEqual(@as(u16, 0), pxToCell(8, 18, 80, 24, r2, 16, 16).?.row); // y=16-16=0
    // grid 안 clamp: 영역 밖 큰 좌표는 cols-1.
    try std.testing.expectEqual(@as(u16, 79), pxToCell(8, 18, 80, 24, r, 100000, 0).?.col);
    // panel 위쪽 바깥(음수)은 0 clamp.
    try std.testing.expectEqual(@as(u16, 0), pxToCell(8, 18, 80, 24, r2, 0, 0).?.row); // y=0-16<0 → 0
    // cell 0이면 placeholder(12×24): x=12 → col 1.
    try std.testing.expectEqual(@as(u16, 1), pxToCell(0, 0, 80, 24, r, 12, 0).?.col);
    // 비유한은 null(i64 trap 방지).
    try std.testing.expect(pxToCell(8, 18, 80, 24, r, std.math.nan(f64), 0) == null);
}
