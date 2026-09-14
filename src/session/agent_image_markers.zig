//! 화면(뷰포트)에서 `[Image #N]` 마커를 **후보로** 긁는다 — 계약은
//! [docs/agent-image-marker-preview.md](../../docs/agent-image-marker-preview.md) §3이 소유한다.
//!
//! **왜 session 층인가**: `[Image #N]`은 provider의 어휘지 터미널의 것이 아니다. 코어는 셀만 주고,
//! 그 글자가 무엇을 뜻하는지는 여기서 안다 — 갤러리 인덱스가 JSONL 어휘를 아는 것과 같은 자리다.
//!
//! **후보일 뿐이다.** 마커에는 SGR이 없어(실측 §10) 사람이 타이핑한 같은 글자와 바이트가 같다.
//! 「진짜인가」는 `agent_image_staging.Staging.lookup`이 기록으로 정한다(§3.1).

const std = @import("std");
const terminal = @import("../terminal.zig");
const types = terminal.types;
const staging = @import("agent_image_staging.zig");

/// 뷰포트에서 찾은 마커 하나 — 화면 좌표가 붙은 `staging.Marker`.
pub const Hit = struct {
    /// 뷰포트 행(0 = 맨 위).
    row: u16,
    /// 마커가 차지하는 셀 범위 [start_col, end_col). **셀 단위다** — 바이트가 아니다.
    start_col: u16,
    end_col: u16,
    n: u32,
};

/// 한 행의 셀을 UTF-8로 풀면서 **바이트 오프셋 → 셀 열** 표를 함께 만든다.
///
/// 표가 필요한 이유: 마커 스캐너는 바이트로 답하는데 화면에 밑줄·프리뷰를 놓으려면 **열**이 필요하고,
/// 한글·이모지가 섞이면 둘이 1:1이 아니다. 여기서 같이 만들지 않으면 호출자가 다시 세야 한다.
const RowText = struct {
    text: std.ArrayList(u8) = .empty,
    /// `text` 의 각 바이트가 어느 셀 열에서 왔는지.
    col_of_byte: std.ArrayList(u16) = .empty,

    fn deinit(self: *RowText, allocator: std.mem.Allocator) void {
        self.text.deinit(allocator);
        self.col_of_byte.deinit(allocator);
        self.* = .{};
    }

    fn build(
        self: *RowText,
        allocator: std.mem.Allocator,
        cells: []const types.Cell,
        graphemes: []const []const u21,
    ) !void {
        self.text.clearRetainingCapacity();
        self.col_of_byte.clearRetainingCapacity();
        var buf: [4]u8 = undefined;
        var col: u16 = 0;
        for (cells) |cell| {
            defer col +|= 1;
            if (cell.continuation) continue;
            const base: u21 = if (cell.codepoint == 0) ' ' else cell.codepoint;
            try self.appendCp(allocator, &buf, base, col);
            // grapheme cluster 본체도 같은 열에 속한다 — 안 넣으면 조합 문자가 빠져 오프셋이 밀린다.
            if (cell.grapheme_id != 0 and cell.grapheme_id <= graphemes.len) {
                for (graphemes[cell.grapheme_id - 1]) |cp| try self.appendCp(allocator, &buf, cp, col);
            }
        }
    }

    fn appendCp(self: *RowText, allocator: std.mem.Allocator, buf: *[4]u8, cp: u21, col: u16) !void {
        const len = std.unicode.utf8Encode(cp, buf) catch return; // 불가 코드포인트는 건너뛴다
        try self.text.appendSlice(allocator, buf[0..len]);
        for (0..len) |_| try self.col_of_byte.append(allocator, col);
    }

    /// 바이트 오프셋이 속한 셀 열. 끝(len)이면 마지막 열 **다음**을 돌려준다.
    fn colAt(self: *const RowText, byte: usize) u16 {
        if (byte < self.col_of_byte.items.len) return self.col_of_byte.items[byte];
        if (self.col_of_byte.items.len == 0) return 0;
        return self.col_of_byte.items[self.col_of_byte.items.len - 1] +| 1;
    }
};

/// 스캔 범위. **전송 전 프리뷰는 커서가 있는 블록만 본다**(§3.1) — 스크롤백에 남은 옛 마커가
/// 입력창 프리뷰를 오염시키지 않게.
pub const Scope = enum {
    /// 뷰포트 전부(전송 후 경로가 쓴다).
    viewport,
    /// 커서가 있는 행부터 화면 끝까지 — 입력창은 화면 하단에 있고 여러 줄일 수 있다.
    cursor_block,
};

/// 뷰포트에서 마커를 긁는다. 호출자가 `out`을 소유한다.
///
/// ⚠️ **커서가 화면에 안 보이면 `cursor_block`은 아무것도 내지 않는다.** Codex는 primary 화면이라
/// 위로 스크롤하면 입력창이 화면 밖이고(§3.3 실측), 그때 눌린 마커는 전송 전 경로가 답할 것이 아니다.
pub fn scan(
    allocator: std.mem.Allocator,
    snap: types.RenderSnapshot,
    scope: Scope,
    out: *std.ArrayList(Hit),
) !void {
    const rows = snap.size.rows;
    const cols = snap.size.cols;
    if (rows == 0 or cols == 0) return;
    if (snap.cells.len < @as(usize, rows) * @as(usize, cols)) return; // 방어: 잘린 스냅샷

    var first_row: u16 = 0;
    if (scope == .cursor_block) {
        // 스크롤된 뷰포트면 커서가 보이지 않는다 — 열지 않는다(§3.3).
        if (snap.viewport_scrolled) return;
        if (snap.cursor.row >= rows) return;
        first_row = snap.cursor.row;
    }

    var row_text: RowText = .{};
    defer row_text.deinit(allocator);
    var markers: std.ArrayList(staging.Marker) = .empty;
    defer markers.deinit(allocator);

    var row: u16 = first_row;
    while (row < rows) : (row += 1) {
        const start = @as(usize, row) * @as(usize, cols);
        const line = snap.cells[start .. start + cols];
        try row_text.build(allocator, line, snap.graphemes);
        markers.clearRetainingCapacity();
        try staging.scanLine(row_text.text.items, &markers, allocator);
        for (markers.items) |m| {
            try out.append(allocator, .{
                .row = row,
                .start_col = row_text.colAt(m.start),
                .end_col = row_text.colAt(m.end),
                .n = m.n,
            });
        }
    }
}

/// 긁은 마커의 N만 모은다 — 관찰(`Observation.arm`/`fresh`)과 `Staging.syncVisible`이 먹는 형태.
pub fn numbersOf(allocator: std.mem.Allocator, hits: []const Hit, out: *std.ArrayList(u32)) !void {
    for (hits) |h| try out.append(allocator, h.n);
}

/// 셀 (row, col)을 덮는 마커를 고른다. 없으면 null — 클릭 라우팅이 쓴다.
pub fn hitAt(hits: []const Hit, row: u16, col: u16) ?Hit {
    for (hits) |h| {
        if (h.row != row) continue;
        if (col >= h.start_col and col < h.end_col) return h;
    }
    return null;
}

const testing = std.testing;

/// 테스트용: ASCII 한 줄짜리 스냅샷. 행이 여럿이면 `\n`으로 나눈다.
fn snapshotOf(buf: []types.Cell, text: []const u8, cols: u16, rows: u16) types.RenderSnapshot {
    for (buf) |*c| c.* = .{};
    var row: usize = 0;
    var col: usize = 0;
    for (text) |ch| {
        if (ch == '\n') {
            row += 1;
            col = 0;
            continue;
        }
        if (row >= rows or col >= cols) continue;
        buf[row * cols + col] = .{ .codepoint = ch };
        col += 1;
    }
    return .{ .size = .{ .rows = rows, .cols = cols }, .cells = buf };
}

test "MP1 뷰포트 스캔: 한 행의 마커 둘을 셀 열과 함께 낸다" {
    var cells: [80]types.Cell = undefined;
    const snap = snapshotOf(&cells, "> [Image #1] [Image #2]", 40, 2);
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);
    try scan(testing.allocator, snap, .viewport, &out);
    try testing.expectEqual(@as(usize, 2), out.items.len);
    try testing.expectEqual(@as(u32, 1), out.items[0].n);
    try testing.expectEqual(@as(u16, 2), out.items[0].start_col); // "> " 뒤
    try testing.expectEqual(@as(u16, 12), out.items[0].end_col);
    try testing.expectEqual(@as(u32, 2), out.items[1].n);
    try testing.expectEqual(@as(u16, 13), out.items[1].start_col);
}

test "MP1 뷰포트 스캔: cursor_block 은 커서 행 위를 안 본다 — 스크롤백의 옛 마커를 배제한다(§3.1)" {
    var cells: [80]types.Cell = undefined;
    var snap = snapshotOf(&cells, "[Image #9]\n[Image #1]", 40, 2);
    snap.cursor = .{ .row = 1, .col = 0 };
    var all: std.ArrayList(Hit) = .empty;
    defer all.deinit(testing.allocator);
    try scan(testing.allocator, snap, .viewport, &all);
    try testing.expectEqual(@as(usize, 2), all.items.len);

    var block: std.ArrayList(Hit) = .empty;
    defer block.deinit(testing.allocator);
    try scan(testing.allocator, snap, .cursor_block, &block);
    try testing.expectEqual(@as(usize, 1), block.items.len);
    try testing.expectEqual(@as(u32, 1), block.items[0].n); // 커서 행의 것만
}

test "MP1 뷰포트 스캔: 스크롤된 화면에서 cursor_block 은 아무것도 안 낸다 (§3.3 Codex primary)" {
    var cells: [80]types.Cell = undefined;
    var snap = snapshotOf(&cells, "[Image #1]", 40, 2);
    snap.viewport_scrolled = true;
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);
    try scan(testing.allocator, snap, .cursor_block, &out);
    try testing.expectEqual(@as(usize, 0), out.items.len);
    // 전송 후 경로(viewport)는 그대로 본다 — 그 마커는 인덱스가 답한다.
    var vp: std.ArrayList(Hit) = .empty;
    defer vp.deinit(testing.allocator);
    try scan(testing.allocator, snap, .viewport, &vp);
    try testing.expectEqual(@as(usize, 1), vp.items.len);
}

test "MP1 뷰포트 스캔: 한글이 앞에 있어도 열이 밀리지 않는다 — 바이트가 아니라 셀이다" {
    var cells: [120]types.Cell = undefined;
    for (&cells) |*c| c.* = .{};
    const cols: u16 = 40;
    // "가나 [Image #7]" — 한글 둘은 각 width 2(continuation 셀 포함).
    const prefix = [_]u21{ '가', '나' };
    var col: usize = 0;
    for (prefix) |cp| {
        cells[col] = .{ .codepoint = cp, .width = 2 };
        cells[col + 1] = .{ .codepoint = 0, .width = 1, .continuation = true };
        col += 2;
    }
    cells[col] = .{ .codepoint = ' ' };
    col += 1;
    const marker = "[Image #7]";
    const marker_start = col;
    for (marker) |ch| {
        cells[col] = .{ .codepoint = ch };
        col += 1;
    }
    const snap: types.RenderSnapshot = .{ .size = .{ .rows = 1, .cols = cols }, .cells = cells[0..cols] };
    var out: std.ArrayList(Hit) = .empty;
    defer out.deinit(testing.allocator);
    try scan(testing.allocator, snap, .viewport, &out);
    try testing.expectEqual(@as(usize, 1), out.items.len);
    try testing.expectEqual(@as(u16, @intCast(marker_start)), out.items[0].start_col);
    try testing.expectEqual(@as(u16, @intCast(marker_start + marker.len)), out.items[0].end_col);
}

test "MP1 hitAt: 마커가 덮는 셀만 고른다" {
    const hits = [_]Hit{.{ .row = 3, .start_col = 2, .end_col = 12, .n = 1 }};
    try testing.expect(hitAt(&hits, 3, 2) != null);
    try testing.expect(hitAt(&hits, 3, 11) != null);
    try testing.expect(hitAt(&hits, 3, 12) == null); // 끝은 배타
    try testing.expect(hitAt(&hits, 4, 5) == null);
}

test "MP1 numbersOf: 관찰과 syncVisible 이 먹는 형태로 N 만 낸다" {
    const hits = [_]Hit{
        .{ .row = 1, .start_col = 0, .end_col = 10, .n = 1 },
        .{ .row = 1, .start_col = 11, .end_col = 21, .n = 3 },
    };
    var ns: std.ArrayList(u32) = .empty;
    defer ns.deinit(testing.allocator);
    try numbersOf(testing.allocator, &hits, &ns);
    try testing.expectEqualSlices(u32, &.{ 1, 3 }, ns.items);
}
