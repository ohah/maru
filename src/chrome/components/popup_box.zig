//! PopupBox — **앵커에 붙는** 떠 있는 상자의 공유 기하 프리미티브(디자인 시스템).
//! `modal_box`가 **중앙** 모달에 하는 일을 앵커 팝업에 한다. 단일 출처: docs/chrome-strategy.md §5.4.
//!
//! **왜 뽑았나**: 우클릭 메뉴·설정 드롭다운·마커 이미지 프리뷰가 전부 "앵커에서 시작해 workspace 안으로
//! 당긴다"는 **같은 계산**을 각자 복사해 갖고 있었다. 세 번째 복사본을 만들려다 정리했다(2026-09-14).
//! 복사본이 늘면 「가장자리에 딱 붙이지 않는다」 같은 규칙이 한 곳에서만 고쳐져 나머지가 조용히 낡는다.
//!
//! 이 모듈은 **자리만** 정한다. 배경·테두리·콘텐츠는 각 컴포넌트가 그린다(`modal_box`가 `frame`/`text`를
//! 함께 주는 것과 다른 점 — 앵커 팝업은 콘텐츠 모양이 제각각이라 공유할 것이 기하뿐이다).

const std = @import("std");
const draw = @import("../draw.zig");
const props = @import("../props.zig");

/// 세로 배치 정책.
pub const Vertical = enum {
    /// 앵커 **위치에서** 시작한다(우클릭 메뉴 — 누른 자리에 좌상단을 둔다). 아래로 넘치면 당긴다.
    ///
    /// ⚠️ **`gap_px` 를 쓰지 않는다**(A40) — 누른 자리가 곧 좌상단이라 띄울 «앵커 두께»가 없다.
    /// 이 값으로 부르면서 `gap_px` 를 주면 조용히 무시된다.
    at_anchor,
    /// 앵커 **아래에** 둔다. 안 들어가면 **위로 뒤집고**, 그것도 안 되면 당긴다(이미지 프리뷰).
    below_flip_up,
    /// 앵커 **아래에** 둔다. 안 들어가면 **당긴다**(뒤집지 않는다 — 설정 드롭다운).
    ///
    /// 드롭다운이 뒤집히지 않는 이유는 **control 과의 관계가 뒤바뀌면 어느 값을 고르는 목록인지
    /// 흐려지기** 때문이다. 목록이 control 위로 올라가면 그 위의 다른 행을 덮어 「저 행의 목록인가」로
    /// 읽힌다. 프리뷰는 앵커가 마커 한 줄이라 그 혼동이 없어 뒤집어도 된다.
    below_clamp,
};

pub const Placement = struct {
    /// 앵커 사각형. 점 앵커(우클릭)면 `w`/`h`가 0이다.
    anchor: draw.Rect,
    vertical: Vertical = .at_anchor,
    /// 앵커와 상자 사이 간격(px). `below_flip_up`에서 마커·control을 가리지 않게 띄운다.
    gap_px: u32 = 0,
    /// 앵커가 workspace **아래**(상태바 등)에 있는가.
    ///
    /// ⚠️ 이 플래그가 있는 이유가 실제 사고다 — 상태바는 창 전폭이고 workspace **밖**에 산다. 왼쪽
    /// 항목(브랜치·경로)은 사이드바 chrome이 아닌데도 x 범위만 보면 사이드바 안으로 판정돼, 좌단을
    /// `workspace.x`로 밀면 누른 자리와 뜬 자리가 화면 절반만큼 떨어진다(사용자 제보). 그 항목 위에는
    /// 덮을 사이드바 chrome이 애초에 없다.
    anchor_below_workspace: bool = false,
};

pub const Result = struct {
    rect: draw.Rect,
    /// 앵커 위로 뒤집혔나(`below_flip_up`에서만 참이 될 수 있다).
    flipped_up: bool = false,
};

/// 상자 크기(px)와 앵커로 자리를 정한다. workspace가 한 셀보다 좁으면 null.
///
/// **가장자리에 딱 붙이지 않는다.** 붙이면 그쪽 테두리가 창 경계와 겹쳐 안 보이고, 반대쪽만 둥근 모서리가
/// 보여 잘린 것처럼 읽힌다(상태바 우측 항목에 앵커한 팝오버에서 실측 — anchor 820 + box 384 > 960이라
/// 우단에 정확히 붙었다). 한 셀이면 테두리가 드러나기에 충분하다. 세로도 같은 이유로 띄운다.
pub fn place(box_w: u32, box_h: u32, pl: Placement, p: props.ChromeProps) ?Result {
    const m = p.metrics;
    const cw = @max(m.cell_width_px, 1);
    const ch = @max(m.cell_height_px, 1);
    const ws = props.workspaceRect(m);
    // ⚠️ **양쪽에서 한 셀씩 뺀다 — 그래서 두 셀이 필요하다**(적대적 A32). 한 셀만 보던 가드로는
    // `ws.w` 가 `cw`~`2*cw` 일 때 `left_bound > right_bound` 로 **경계가 역전**되고, 아래 clamp 가
    // 서로를 밀어내다 마지막에 적용되는 좌/상이 이겨 상자가 **반대쪽으로 넘친다.**
    //
    // **곱하지 않고 뺀다** — `2 * cw` 는 u32 곱이라 손상된 메트릭에서 오버플로로 **패닉**한다
    // (`pxToCell` 이 「거대한 finite 좌표가 trap 하던 것을 막는다」고 세운 규율과 같은 축 · A35).
    if (ws.w < cw or ws.w - cw < cw) return null;
    if (ws.h < ch or ws.h - ch < ch) return null;

    // **네 방향 모두 한 셀 띄운다**(2026-09-14 · 사용자 결정). 처음에는 우·하만 띄웠는데, 그것은
    // `context_menu` 가 제보로 고칠 때의 **실측 사례가 우단이었기** 때문이지 좌·상이 달라서가 아니다.
    // 한쪽만 띄우면 같은 팝업이 어느 가장자리에 닿느냐에 따라 **테가 있다 없다** 해서 더 이상하다.
    // **전부 i64 도메인에서 센다**(적대적 A36~A38). `u32` 를 바로 `i32` 로 캐스팅하던 자리가 여덟 곳
    // 있었고(`ws.x + ws.w` 덧셈까지 포함) 어느 하나라도 손상된 값이 오면 `@intCast` 가 **패닉**한다.
    // `pxToCell` 이 「클램프를 float 도메인에서 먼저 한 뒤 `@intFromFloat`」 하는 것과 같은 수법이다 —
    // 넓은 도메인에서 다 계산하고 **마지막에 한 번만** 좁힌다.
    //
    // ⚠️ A35 판정자(`cell_width_px = maxInt(u32)`)가 통과했던 것은 **위 가드가 먼저 걸렸기 때문**이지
    // 이 아래가 안전해서가 아니었다 — 한 경로를 막고 「막았다」고 읽으면 나머지가 그대로 남는다.
    const R = i64;
    const wsx: R = ws.x;
    const wsw: R = ws.w;
    const wsy: R = ws.y;
    const wsh: R = ws.h;
    const cw_r: R = cw;
    const ch_r: R = ch;

    const right_bound: R = wsx + wsw - cw_r;
    const bottom_bound: R = wsy + wsh - ch_r;
    const top_bound: R = wsy + ch_r;
    // 좌단은 사이드바 오른쪽으로 — 팝업은 터미널 영역 오버레이라 사이드바 chrome 위로 겹치지 않게 한다.
    // 단 앵커가 workspace 아래(상태바)면 그 규칙을 쓰지 않는다(위 `anchor_below_workspace` 주석).
    const left_bound: R = (if (pl.anchor_below_workspace) 0 else wsx) + cw_r;

    const bw: R = box_w;
    const bh: R = box_h;
    const anchor_x: R = pl.anchor.x;
    const anchor_y: R = pl.anchor.y;
    const anchor_h: R = pl.anchor.h;
    const gap: R = pl.gap_px;

    var flipped = false;
    var y: R = switch (pl.vertical) {
        .at_anchor => anchor_y,
        .below_flip_up, .below_clamp => anchor_y + anchor_h + gap,
    };
    if (y + bh > bottom_bound) {
        if (pl.vertical == .below_flip_up) {
            const up = anchor_y - bh - gap;
            if (up >= top_bound) {
                y = up;
                flipped = true;
            } else {
                y = bottom_bound - bh;
            }
        } else {
            y = bottom_bound - bh;
        }
    }
    // **좌·상이 마지막이라 이긴다.** 상자가 workspace 보다 크면 어느 쪽이든 넘치는데, 그때 **시작
    // 모서리를 보이게** 두는 쪽이 낫다 — 목록이라면 첫 항목이, 그림이라면 좌상단이 보인다(A34).
    if (y < top_bound) y = top_bound;

    var x: R = anchor_x;
    if (x + bw > right_bound) x = right_bound - bw;
    if (x < left_bound) x = left_bound;

    // 마지막에 한 번만 좁힌다. 여기까지 온 값은 workspace 안이라 실제로는 포화가 안 걸리지만,
    // **좁히는 자리가 하나**라는 것이 이 함수가 안 터지는 이유다.
    return .{
        .rect = .{ .x = satI32(x), .y = satI32(y), .w = box_w, .h = box_h },
        .flipped_up = flipped,
    };
}

/// i64 → i32 포화 캐스팅. `place` 가 넓은 도메인에서 계산한 값을 **한 곳에서만** 좁힌다.
fn satI32(v: i64) i32 {
    return @intCast(std.math.clamp(v, std.math.minInt(i32), std.math.maxInt(i32)));
}

const testing = std.testing;

fn metricsOf(w: u32, h: u32) props.ChromeProps {
    return .{ .metrics = .{
        .cell_width_px = 8,
        .cell_height_px = 16,
        .sidebar_width_px = 0,
        .backing_width_px = w,
        .backing_height_px = h,
        .workspace_present = true,
        .workspace_x_px = 0,
        .workspace_y_px = 0,
        .workspace_width_px = w,
        .workspace_height_px = h,
    } };
}

test "CSP1 popup_box: 우단에 딱 붙이지 않는다 — 한 셀을 띄운다" {
    const p = metricsOf(960, 600);
    const r = place(384, 100, .{ .anchor = .{ .x = 820, .y = 100, .w = 0, .h = 0 } }, p) orelse
        return error.TestUnexpectedResult;
    try testing.expect(r.rect.x + 384 <= 960 - 8);
}

test "CSP1 popup_box: 좌단을 사이드바 오른쪽으로 민다" {
    var p = metricsOf(1000, 600);
    p.metrics.sidebar_width_px = 200;
    p.metrics.workspace_x_px = 200;
    p.metrics.workspace_width_px = 800;
    const r = place(400, 100, .{ .anchor = .{ .x = 10, .y = 50, .w = 0, .h = 0 } }, p) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 200 + 8), r.rect.x); // 사이드바 오른쪽 + edge_gap(한 셀)
}

test "CSP1 popup_box: 상태바 앵커는 사이드바로 밀지 않는다 — 누른 자리에 뜬다" {
    var p = metricsOf(1000, 600);
    p.metrics.sidebar_width_px = 200;
    p.metrics.workspace_x_px = 200;
    p.metrics.workspace_width_px = 800;
    p.metrics.workspace_height_px = 560; // 상태바가 아래 40px
    const r = place(300, 100, .{
        .anchor = .{ .x = 16, .y = 580, .w = 0, .h = 0 },
        .anchor_below_workspace = true,
    }, p) orelse return error.TestUnexpectedResult;
    try testing.expect(r.rect.x < 200); // 사이드바 오른쪽으로 안 밀렸다
    try testing.expectEqual(@as(i32, 16), r.rect.x); // 누른 자리 그대로 — clamp 가 안 걸린다
}

test "CSP1 popup_box: below_flip_up 은 아래가 모자라면 위로 뒤집는다" {
    const p = metricsOf(1000, 600);
    const r = place(200, 200, .{
        .anchor = .{ .x = 100, .y = 540, .w = 80, .h = 16 },
        .vertical = .below_flip_up,
        .gap_px = 2,
    }, p) orelse return error.TestUnexpectedResult;
    try testing.expect(r.flipped_up);
    try testing.expect(r.rect.y + 200 <= 540);
}

test "CSP1 popup_box: at_anchor 는 뒤집지 않고 당긴다(우클릭 메뉴)" {
    const p = metricsOf(1000, 600);
    const r = place(200, 200, .{ .anchor = .{ .x = 100, .y = 540, .w = 0, .h = 0 } }, p) orelse
        return error.TestUnexpectedResult;
    try testing.expect(!r.flipped_up);
    try testing.expectEqual(@as(i32, 600 - 16 - 200), r.rect.y);
}

test "CSP1 popup_box: 위로도 아래로도 안 들어가면 당기고 마커를 안 덮는다는 보장은 없다" {
    const p = metricsOf(1000, 300);
    const r = place(200, 250, .{
        .anchor = .{ .x = 100, .y = 200, .w = 80, .h = 16 },
        .vertical = .below_flip_up,
    }, p) orelse return error.TestUnexpectedResult;
    try testing.expect(!r.flipped_up); // 위로 뒤집으면 top_bound 를 넘는다 → 당기기
    try testing.expect(r.rect.y >= 0);
}

test "CSP1 popup_box: workspace 가 한 셀보다 좁으면 null" {
    const p = metricsOf(4, 4);
    try testing.expect(place(10, 10, .{ .anchor = .{ .x = 0, .y = 0, .w = 0, .h = 0 } }, p) == null);
}

test "CSP1 popup_box: below_clamp 는 아래가 모자라도 뒤집지 않고 당긴다(드롭다운)" {
    const p = metricsOf(1000, 600);
    const r = place(200, 200, .{
        .anchor = .{ .x = 100, .y = 540, .w = 80, .h = 16 },
        .vertical = .below_clamp,
    }, p) orelse return error.TestUnexpectedResult;
    try testing.expect(!r.flipped_up); // 같은 자리에서 below_flip_up 은 뒤집는다
    try testing.expectEqual(@as(i32, 600 - 16 - 200), r.rect.y);
}

test "CSP1 popup_box: 네 방향 모두 한 셀을 띄운다 — 가장자리마다 테가 있다 없다 하지 않는다" {
    const p = metricsOf(1000, 600); // cw=8 · ch=16
    // 좌·상으로 밀어붙이는 앵커.
    const tl = place(100, 100, .{ .anchor = .{ .x = -50, .y = -50, .w = 0, .h = 0 } }, p) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 8), tl.rect.x);
    try testing.expectEqual(@as(i32, 16), tl.rect.y);
    // 우·하로 밀어붙이는 앵커.
    const br = place(100, 100, .{ .anchor = .{ .x = 990, .y = 590, .w = 0, .h = 0 } }, p) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 1000 - 8 - 100), br.rect.x);
    try testing.expectEqual(@as(i32, 600 - 16 - 100), br.rect.y);
}

test "CSP1 popup_box: workspace 가 두 셀보다 좁으면 null — 양쪽 gap 이 경계를 뒤집는다(A32)" {
    // cw=8·ch=16 이므로 가로 16·세로 32 미만은 자리를 못 만든다.
    try testing.expect(place(10, 10, .{ .anchor = .{ .x = 0, .y = 0, .w = 0, .h = 0 } }, metricsOf(12, 600)) == null);
    try testing.expect(place(10, 10, .{ .anchor = .{ .x = 0, .y = 0, .w = 0, .h = 0 } }, metricsOf(1000, 20)) == null);
    // 딱 두 셀이면 자리가 0 이지만 경계는 안 뒤집힌다 — 열린다.
    try testing.expect(place(1, 1, .{ .anchor = .{ .x = 0, .y = 0, .w = 0, .h = 0 } }, metricsOf(16, 32)) != null);
}

test "CSP1 popup_box: 상자가 workspace 보다 크면 좌·상이 이긴다 — 시작 모서리를 보인다(A34)" {
    const p = metricsOf(1000, 600);
    const r = place(2000, 1000, .{ .anchor = .{ .x = 500, .y = 300, .w = 0, .h = 0 } }, p) orelse
        return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 8), r.rect.x); // left_bound
    try testing.expectEqual(@as(i32, 16), r.rect.y); // top_bound
}

test "CSP1 popup_box: 손상된 메트릭에 안 터진다 — 곱하지 않고 뺀다(A35)" {
    var p = metricsOf(1000, 600);
    p.metrics.cell_width_px = std.math.maxInt(u32);
    p.metrics.cell_height_px = std.math.maxInt(u32);
    // 예전 가드(`2 * cw`)는 여기서 u32 곱 오버플로로 죽었다. 지금은 조용히 null 이다.
    try testing.expect(place(10, 10, .{ .anchor = .{ .x = 0, .y = 0, .w = 0, .h = 0 } }, p) == null);
}

test "CSP1 popup_box: 극단값에 안 터진다 — 상자·앵커·간격 전부(A36~A38)" {
    const p = metricsOf(1000, 600);
    // 상자가 u32 최대.
    const huge_box = place(std.math.maxInt(u32), std.math.maxInt(u32), .{
        .anchor = .{ .x = 100, .y = 100, .w = 0, .h = 0 },
    }, p) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(i32, 8), huge_box.rect.x); // 좌·상이 이긴다(A34)
    try testing.expectEqual(@as(i32, 16), huge_box.rect.y);

    // 앵커 높이·간격이 u32 최대.
    const huge_anchor = place(100, 100, .{
        .anchor = .{ .x = 0, .y = 0, .w = 0, .h = std.math.maxInt(u32) },
        .vertical = .below_clamp,
        .gap_px = std.math.maxInt(u32),
    }, p) orelse return error.TestUnexpectedResult;
    try testing.expect(huge_anchor.rect.y <= 600);

    // workspace 원점이 u32 최대 근처.
    var far = metricsOf(1000, 600);
    far.metrics.workspace_x_px = std.math.maxInt(u32) - 10;
    far.metrics.workspace_y_px = std.math.maxInt(u32) - 10;
    _ = place(100, 100, .{ .anchor = .{ .x = 0, .y = 0, .w = 0, .h = 0 } }, far);
}
