//! 사이드바 카드 글자의 **세로 자리**를 정하는 인코더/디코더 한 쌍.
//!
//! `buildSidebarDrawList` 는 셀 격자로 글자를 낸다 — 행 번호가 하나뿐인데 사이드바는 **슬롯(카드)
//! 안에서 몇 번째 줄인가**를 함께 알아야 한다. 그래서 그 셋을 한 `u16` 에 접어 실어 보내고
//! (`encode`), 그리는 쪽이 풀어서 픽셀 y 를 만든다(`fillOriginY`).
//!
//! ## 왜 한 파일에 함께 두는가
//!
//! **접는 규칙과 푸는 규칙이 갈리면 글자가 엉뚱한 슬롯·줄에 그려진다.** 이 저장소가 그 위험을 이미
//! 적어 뒀다 — 인코딩 테스트의 주석:
//!
//! > 인코딩만 바꾸고 디코더를 안 고치면 카드 glyph 가 엉뚱한 슬롯/줄에 그려진다.
//!
//! 그런데 실제로는 인코더가 `platform/macos/coretext_frame_builder.zig` 에, 디코더가
//! `platform/macos/app_session/sidebar.zig` 에 **떨어져** 있었고, 둘 다 macOS 파일이라 Windows 가
//! 쓸 수 없었다. 여기로 옮겨 **한 자리**로 만든다.
//!
//! ## 왜 최상위인가
//!
//! 디코더는 `chrome.components.sidebar`(행 모델·메트릭)와 `renderer.metal_frame`(셀)을 **둘 다**
//! 본다. 경계 규칙상 그 둘은 서로를 import 할 수 없으므로 이 변환은 어느 쪽에도 못 산다 —
//! `scm_items.zig`(session↔chrome)·`text_shaper.zig` 와 같은 자리, 같은 이유다.

const std = @import("std");

const sidebar = @import("chrome/components/sidebar.zig");
const metal_frame = @import("renderer/metal_frame.zig");

/// 슬롯 하나가 쓰는 행 번호 대역. 한 슬롯에 `line_count`(≤7)·`line_index`(≤3) 를 함께 접어야 해서
/// 32 다 — `line_count*4 + line_index` 가 32 미만이면 충돌이 없다.
pub const line_base: u16 = 32;

/// `(슬롯, 줄 번호, 그 카드의 줄 수)` → 셀 행 번호.
///
/// **줄 수를 함께 싣는 이유**: 카드 높이가 줄 수에서 나오므로(`sidebar.cardHeight`), 푸는 쪽이
/// "이 줄이 몇 줄짜리 블록의 몇 번째인가" 를 알아야 블록을 세로 중앙에 놓을 수 있다.
pub fn encode(slot: usize, line_index: u16, line_count: u16) u16 {
    return @as(u16, @intCast(slot)) *| line_base +| line_count *| 4 +| line_index;
}

/// 인코딩된 행에서 슬롯·줄 수·줄 번호를 되돌린다.
pub fn decode(row: u16) struct { slot: usize, line_count: u16, line_index: u16 } {
    const rem = row % line_base;
    return .{ .slot = row / line_base, .line_count = rem / 4, .line_index = rem % 4 };
}

/// 사이드바 글자 셀의 `origin_y` 를 **content 상대 픽셀**로 채운다.
///
/// **`rowTop` 과 같은 기준에서 시작한다** — 목록 위 여백(`content_pad_v`)부터 누적한다. 0 부터
/// 누적하면 글자만 여백 위로 올라가 **밴드가 글자보다 한 줄 아래로 밀린다**(사용자 제보). 밴드·
/// 글자·클릭 셋이 같은 기준을 써야 "보이는 곳 = 눌리는 곳" 이 성립한다.
///
/// **밴드/배경 셀(`slot_id == 0`)은 손대지 않는다** — 그쪽은 행 번호가 인코딩이 아니라 실제 행
/// 인덱스이고 기하도 따로다.
pub fn fillOriginY(
    allocator: std.mem.Allocator,
    cells: []metal_frame.NativeMetalCell,
    rows: []const sidebar.Row,
    m: sidebar.Metrics,
) void {
    const ch = m.line_h;
    if (cells.len == 0 or ch == 0) return;
    var content_tops: std.ArrayList(u32) = .empty;
    defer content_tops.deinit(allocator);
    var acc: u32 = m.content_pad_v;
    for (rows) |row| {
        content_tops.append(allocator, acc) catch return; // OOM 이면 이 프레임은 건너뛴다
        acc +|= sidebar.rowHeight(row, m);
    }
    for (cells) |*c| {
        if (c.slot_id == 0) continue;
        const d = decode(c.row);
        if (d.slot >= content_tops.items.len) continue; // 매핑 밖(비정상)이면 건너뜀
        const row_h = sidebar.rowHeight(rows[d.slot], m);
        // 블록을 그 행 높이 안에서 세로 중앙에 둔다. `header_row_h = 0` 으로 만든 메트릭을 쓰는 것은
        // 블록 높이가 헤더 높이와 무관하기 때문이다.
        const block_h = sidebar.blockHeight(d.line_count, .init(ch, 0));
        const block_off: u32 = (row_h -| block_h) / 2;
        c.origin_y = content_tops.items[d.slot] +| block_off +| @as(u32, d.line_index) *| m.line_step;
    }
}

const testing = std.testing;

test "인코딩 값이 고정이다 — 디코더와 한 쌍이다" {
    // 이 표가 바뀌면 `decode` 도 함께 바뀌어야 한다. 둘이 한 파일에 있는 이유가 이것이다.
    const cases = [_]struct { slot: usize, idx: u16, count: u16, row: u16 }{
        .{ .slot = 0, .idx = 0, .count = 1, .row = 4 }, // 1줄 중앙
        .{ .slot = 0, .idx = 0, .count = 3, .row = 12 }, // 3줄 위(이름)
        .{ .slot = 0, .idx = 2, .count = 3, .row = 14 }, // 3줄 아래(경로)
        .{ .slot = 0, .idx = 0, .count = 4, .row = 16 },
        .{ .slot = 0, .idx = 3, .count = 4, .row = 19 },
        .{ .slot = 1, .idx = 0, .count = 1, .row = 36 },
        .{ .slot = 2, .idx = 2, .count = 3, .row = 78 },
        .{ .slot = 2, .idx = 3, .count = 4, .row = 83 },
    };
    for (cases) |c| {
        try testing.expectEqual(c.row, encode(c.slot, c.idx, c.count));
        const d = decode(c.row);
        try testing.expectEqual(c.slot, d.slot);
        try testing.expectEqual(c.idx, d.line_index);
        try testing.expectEqual(c.count, d.line_count);
    }
}

test "왕복: 어떤 (슬롯, 줄 수, 줄 번호) 도 그대로 돌아온다" {
    var slot: usize = 0;
    while (slot < 40) : (slot += 1) {
        var count: u16 = 1;
        while (count <= 4) : (count += 1) {
            var idx: u16 = 0;
            while (idx < count) : (idx += 1) {
                const d = decode(encode(slot, idx, count));
                try testing.expectEqual(slot, d.slot);
                try testing.expectEqual(count, d.line_count);
                try testing.expectEqual(idx, d.line_index);
            }
        }
    }
}

fn testCell(row: u16, slot_id: u32) metal_frame.NativeMetalCell {
    return .{
        .row = row,
        .col = 0,
        .width = 1,
        .codepoint = 'x',
        .slot_id = slot_id,
        .atlas_x_px = 0,
        .atlas_y_px = 0,
        .atlas_width_px = 0,
        .atlas_height_px = 0,
        .u0 = 0,
        .v0 = 0,
        .u1 = 0,
        .v1 = 0,
        .foreground = 0,
        .background = 0,
    };
}

test "첫 줄이 목록 위 여백에서 시작한다 — 밴드와 같은 기준" {
    const m = sidebar.Metrics.init(20, 20);
    const rows = [_]sidebar.Row{.{ .card = .{ .tab = 0, .label = "a", .active = true, .lines = 1 } }};
    var cells = [_]metal_frame.NativeMetalCell{testCell(encode(0, 0, 1), 7)};
    fillOriginY(testing.allocator, &cells, &rows, m);
    // 1줄 카드: content_pad_v + (카드 높이 − 한 줄) / 2
    const want = m.content_pad_v + (sidebar.cardHeight(1, m) - m.line_h) / 2;
    try testing.expectEqual(want, cells[0].origin_y);
}

test "여러 줄은 line_step 만큼 내려간다" {
    const m = sidebar.Metrics.init(20, 20);
    const rows = [_]sidebar.Row{.{ .card = .{ .tab = 0, .label = "a", .active = true, .lines = 3 } }};
    var cells = [_]metal_frame.NativeMetalCell{
        testCell(encode(0, 0, 3), 7),
        testCell(encode(0, 2, 3), 7),
    };
    fillOriginY(testing.allocator, &cells, &rows, m);
    try testing.expectEqual(cells[0].origin_y + 2 * m.line_step, cells[1].origin_y);
}

test "밴드 셀(slot_id == 0)은 안 건드린다 — 기하가 다르다" {
    const m = sidebar.Metrics.init(20, 20);
    const rows = [_]sidebar.Row{.{ .card = .{ .tab = 0, .label = "a", .active = true, .lines = 1 } }};
    var cells = [_]metal_frame.NativeMetalCell{testCell(0, 0)};
    cells[0].origin_y = 12345;
    fillOriginY(testing.allocator, &cells, &rows, m);
    try testing.expectEqual(@as(u32, 12345), cells[0].origin_y);
}

test "매핑 밖 슬롯은 건너뛴다 — 방어" {
    const m = sidebar.Metrics.init(20, 20);
    const rows = [_]sidebar.Row{.{ .card = .{ .tab = 0, .label = "a", .active = true, .lines = 1 } }};
    var cells = [_]metal_frame.NativeMetalCell{testCell(encode(9, 0, 1), 7)};
    cells[0].origin_y = 999;
    fillOriginY(testing.allocator, &cells, &rows, m);
    try testing.expectEqual(@as(u32, 999), cells[0].origin_y);
}
