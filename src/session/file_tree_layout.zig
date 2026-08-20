//! L2 session core — 파일 트리의 **픽셀 스크롤 ↔ 행 인덱스** 산술. 순수 함수라 OS·렌더 없이 돈다.
//!
//! 이 파일이 생긴 이유는 **같은 산술이 두 군데에 따로 있었기 때문**이다. 그리기는 "어느 행부터 몇 개를,
//! 얼마나 위로 밀어서" 를 계산하고, 포인터 히트테스트는 "이 y 는 몇 번째 행인가" 를 계산했다. 둘은 서로의
//! 짝이라 **반드시 같은 답**이어야 하는데, 각자 `offset / row_h` 를 다시 쓰고 있었다. 어긋나면 크래시가
//! 아니라 **누른 행과 강조되는 행이 달라진다** — 조용히 틀리는 쪽이다.
//!
//! 옛 코드의 주석도 그것을 알고 있었다: *"창의 첫 행이 위로 밀려 있어도 같은 식이 그 행을 준다 — 렌더가
//! origin 을 그만큼 올리는 것과 짝이다."* 짝이라는 것을 **주석이 아니라 테스트로** 못 박는 것이 이 파일이다.
//!
//! Windows 의 chrome 낮추기도 같은 계산이 필요하다(docs/windows-platform.md §2m.4). 여기 두면 그쪽이
//! 사본을 만들지 않는다 — `layout_math.zig` 가 grid hit-test 로 이미 낸 선례와 같은 결이다.
const std = @import("std");

/// 한 프레임에 그릴 행 창.
pub const DrawWindow = struct {
    /// 첫 행의 인덱스.
    start: usize,
    /// 그릴 행 수. 뷰포트를 덮고도 남지 않게 잘려 있다.
    count: u16,
    /// 첫 행이 뷰포트 위로 밀려 나간 픽셀. 렌더는 원점을 이만큼 **올려** 그린다.
    origin_shift_px: u32,
};

/// 뷰포트를 덮는 최소 행 창을 준다.
///
/// **올림이어야 한다.** 첫 행이 `shift` 만큼 위로 밀린 상태에서 내림으로 세면 뷰포트 바닥에 배경이 한 줄
/// 남는다 — 스크롤 중에 깜박이는 띠로 보인다.
pub fn drawWindow(row_h_px: u32, scroll_px: u32, viewport_h_px: u32, row_count: usize) DrawWindow {
    if (row_h_px == 0) return .{ .start = 0, .count = 0, .origin_shift_px = 0 };
    const start: usize = scroll_px / row_h_px;
    const shift = scroll_px % row_h_px;
    const needed: usize = (@as(usize, viewport_h_px) + shift + row_h_px - 1) / row_h_px;
    const remaining = row_count -| start;
    return .{
        .start = start,
        .count = @intCast(@min(@min(needed, remaining), @as(usize, std.math.maxInt(u16)))),
        .origin_shift_px = shift,
    };
}

/// 뷰포트 안의 y(뷰포트 좌상단 기준)가 몇 번째 행인가. 행이 없으면 `null`.
///
/// **뷰포트 좌표를 content 좌표로 올린 뒤** 나눈다. 첫 행이 부분만 보여도 같은 식이 그 행을 준다 —
/// `drawWindow` 가 원점을 `origin_shift_px` 만큼 올려 그리는 것과 짝이다.
pub fn rowAtLocalY(row_h_px: u32, scroll_px: u32, local_y_px: f64, row_count: usize) ?usize {
    if (row_h_px == 0) return null;
    if (local_y_px < 0) return null;
    const content_y = @as(f64, @floatFromInt(scroll_px)) + local_y_px;
    // 아주 큰 y 가 들어와도 `@intFromFloat` 가 정의되지 않는 값으로 가지 않게 먼저 막는다. 포인터
    // 좌표는 창 크기에 갇혀 있지만, 이 함수는 순수라 호출자를 믿지 않는다.
    const max_content = @as(f64, @floatFromInt(row_count)) * @as(f64, @floatFromInt(row_h_px));
    if (content_y >= max_content) return null;
    const index: usize = @intFromFloat(content_y / @as(f64, @floatFromInt(row_h_px)));
    return if (index < row_count) index else null;
}

// ── 테스트 ────────────────────────────────────────────────────────────────────────────────────
// 전부 순수라 **모든 타깃에서** 돈다 — Windows 러너가 없어도 CI 가 이 짝을 지킨다.

const testing = std.testing;

test "drawWindow: 뷰포트를 덮되 남기지 않는다" {
    // 딱 떨어지는 경우 — 20px 뷰포트, 10px 행이면 두 줄.
    try testing.expectEqual(DrawWindow{ .start = 0, .count = 2, .origin_shift_px = 0 }, drawWindow(10, 0, 20, 100));
    // 반 칸 밀리면 세 줄이 필요하다(위 반 칸 + 두 줄 + 아래 반 칸). 내림이면 바닥에 배경이 남는다.
    try testing.expectEqual(DrawWindow{ .start = 0, .count = 3, .origin_shift_px = 5 }, drawWindow(10, 5, 20, 100));
    // 스크롤이 정확히 한 행이면 start 가 1 이고 밀림은 없다.
    try testing.expectEqual(DrawWindow{ .start = 1, .count = 2, .origin_shift_px = 0 }, drawWindow(10, 10, 20, 100));
    // 남은 행이 모자라면 거기서 멈춘다.
    try testing.expectEqual(DrawWindow{ .start = 8, .count = 2, .origin_shift_px = 0 }, drawWindow(10, 80, 20, 10));
    // 끝을 넘어선 스크롤은 아무것도 안 그린다(음수로 감기지 않는다).
    try testing.expectEqual(@as(u16, 0), drawWindow(10, 500, 20, 10).count);
    // 행 높이 0 — 폰트가 아직 없을 때. 0 으로 나누지 않는다.
    try testing.expectEqual(DrawWindow{ .start = 0, .count = 0, .origin_shift_px = 0 }, drawWindow(0, 0, 20, 10));
    // 뷰포트 0 — 도크가 접혔다. 밀림이 있으면 그 부분 행 하나는 여전히 후보다.
    try testing.expectEqual(@as(u16, 0), drawWindow(10, 0, 0, 10).count);
}

test "rowAtLocalY: 부분 행과 경계" {
    try testing.expectEqual(@as(?usize, 0), rowAtLocalY(10, 0, 0, 100));
    try testing.expectEqual(@as(?usize, 0), rowAtLocalY(10, 0, 9.9, 100));
    try testing.expectEqual(@as(?usize, 1), rowAtLocalY(10, 0, 10, 100));
    // 반 칸 밀린 상태: 뷰포트 y=0 은 **0 번 행의 아랫부분**이다.
    try testing.expectEqual(@as(?usize, 0), rowAtLocalY(10, 5, 0, 100));
    try testing.expectEqual(@as(?usize, 1), rowAtLocalY(10, 5, 5, 100));
    // 행 수를 넘어서면 null — 빈 바닥을 눌러도 마지막 행이 잡히면 안 된다.
    try testing.expectEqual(@as(?usize, null), rowAtLocalY(10, 0, 1000, 10));
    try testing.expectEqual(@as(?usize, null), rowAtLocalY(10, 0, -1, 10));
    try testing.expectEqual(@as(?usize, null), rowAtLocalY(0, 0, 5, 10));
    // 행이 하나도 없으면 어느 좌표도 행이 아니다.
    try testing.expectEqual(@as(?usize, null), rowAtLocalY(10, 0, 0, 0));
}

// **이 파일의 존재 이유가 이 테스트다.** 두 함수가 짝이 아니게 되는 순간 누른 행과 강조되는 행이
// 갈린다. 그리기가 "이 행은 여기 있다" 고 말한 자리를 히트테스트에 그대로 물어, 같은 인덱스가
// 나오는지를 조합을 넓게 훑어 확인한다.
test "drawWindow 와 rowAtLocalY 는 짝이다 — 그린 자리를 누르면 그 행이 나온다" {
    const row_hs = [_]u32{ 1, 7, 10, 17, 33 };
    const scrolls = [_]u32{ 0, 1, 5, 9, 10, 33, 100, 997 };
    const viewports = [_]u32{ 0, 1, 20, 100, 640 };
    const counts = [_]usize{ 0, 1, 3, 50, 4096 };

    for (row_hs) |row_h| for (scrolls) |scroll| for (viewports) |viewport| for (counts) |row_count| {
        const w = drawWindow(row_h, scroll, viewport, row_count);
        var k: usize = 0;
        while (k < w.count) : (k += 1) {
            const index = w.start + k;
            // 렌더가 이 행을 놓는 자리: 창 원점을 shift 만큼 올린 뒤 k 칸 아래.
            const top_px = @as(f64, @floatFromInt(k * row_h)) - @as(f64, @floatFromInt(w.origin_shift_px));
            // 그 행의 **안쪽** 세 지점을 눌러 본다(위 끝·가운데·아래 끝 직전).
            const probes = [_]f64{ top_px, top_px + @as(f64, @floatFromInt(row_h)) / 2.0, top_px + @as(f64, @floatFromInt(row_h)) - 0.001 };
            for (probes) |y| {
                // 뷰포트 밖(위로 밀려 나간 부분)은 포인터가 닿을 수 없으므로 건너뛴다.
                if (y < 0) continue;
                if (y >= @as(f64, @floatFromInt(viewport))) continue;
                const hit = rowAtLocalY(row_h, scroll, y, row_count);
                try testing.expectEqual(@as(?usize, index), hit);
            }
        }
    };
}

// **대조군** — 위 테스트가 공허하지 않은지 본다. 조합을 훑어도 검사가 한 번도 안 돌면 초록이다
// (`count` 가 늘 0 이거나 probe 가 전부 뷰포트 밖이면 그렇게 된다). 실제로 몇 번이나 비교했는지 센다.
test "대조군: 짝 테스트가 실제로 비교를 수행한다" {
    var compared: usize = 0;
    const row_hs = [_]u32{ 1, 7, 10, 17, 33 };
    const scrolls = [_]u32{ 0, 1, 5, 9, 10, 33, 100, 997 };
    const viewports = [_]u32{ 0, 1, 20, 100, 640 };
    const counts = [_]usize{ 0, 1, 3, 50, 4096 };
    for (row_hs) |row_h| for (scrolls) |scroll| for (viewports) |viewport| for (counts) |row_count| {
        const w = drawWindow(row_h, scroll, viewport, row_count);
        var k: usize = 0;
        while (k < w.count) : (k += 1) {
            const top_px = @as(f64, @floatFromInt(k * row_h)) - @as(f64, @floatFromInt(w.origin_shift_px));
            const probes = [_]f64{ top_px, top_px + @as(f64, @floatFromInt(row_h)) / 2.0, top_px + @as(f64, @floatFromInt(row_h)) - 0.001 };
            for (probes) |y| {
                if (y < 0 or y >= @as(f64, @floatFromInt(viewport))) continue;
                compared += 1;
            }
        }
    };
    // 실측 3,000 이상. 하한을 크게 잡아 "조합을 지웠는데도 초록" 을 막는다.
    try testing.expect(compared > 3000);
}
