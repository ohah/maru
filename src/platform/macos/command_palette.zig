//! 커맨드 팝업(Cmd+Shift+P) 상태머신 — 순수 로직(렌더·OS·PTY 무관). 카탈로그(command_catalog.entries)를
//! 쿼리로 필터하고 선택을 옮기며, 선택된 항목의 Action을 돌려준다. DevSession이 이 상태를 들고(2b) 모달 키를
//! 라우팅하고 오버레이로 그린다 — 여기선 상태 전이만 소유한다(단일 출처·헤드리스 테스트). 렌더는 Zig draw-list로
//! (네이티브 뷰 아님 — UI 렌더 전략). 필터는 title의 대소문자 무시 부분일치(fuzzy는 후속).

const std = @import("std");
const maru = @import("maru");
const command_catalog = @import("command_catalog.zig");

const Action = maru.config.Action;

/// ASCII 대소문자 무시 부분일치 — needle이 비면 true(전체 통과). title은 영문이라 ASCII fold로 충분.
fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (needle.len > haystack.len) return false;
    const last = haystack.len - needle.len;
    var i: usize = 0;
    while (i <= last) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) {
            if (std.ascii.toLower(haystack[i + j]) != std.ascii.toLower(needle[j])) break;
        } else return true;
    }
    return false;
}

pub const PaletteState = struct {
    open: bool = false,
    query: std.ArrayList(u8) = .empty, // 타이핑한 필터(UTF-8)
    filtered: std.ArrayList(usize) = .empty, // 통과한 command_catalog.entries 인덱스(표시 순서)
    selected: usize = 0, // filtered 안에서의 선택 위치

    pub fn deinit(self: *PaletteState, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.filtered.deinit(allocator);
    }

    /// 팝업을 연다 — 쿼리 비우고 전체를 필터(=전부)로, 선택 맨 위. OOM이면 에러(호출자가 무시하고 안 열어도 됨).
    pub fn show(self: *PaletteState, allocator: std.mem.Allocator) !void {
        self.query.clearRetainingCapacity();
        self.open = true;
        try self.recompute(allocator);
    }

    pub fn hide(self: *PaletteState) void {
        self.open = false;
    }

    /// 필터에 글자(코드포인트) 추가 → 재필터. 쿼리가 바뀌면 선택은 맨 위로(흔한 팝업 동작).
    pub fn appendChar(self: *PaletteState, allocator: std.mem.Allocator, cp: u21) !void {
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch return; // 인코딩 불가 코드포인트는 무시
        try self.query.appendSlice(allocator, utf8[0..n]);
        try self.recompute(allocator);
    }

    /// 마지막 코드포인트 1개 삭제(UTF-8 경계 존중) → 재필터. 빈 쿼리면 무동작.
    pub fn backspace(self: *PaletteState, allocator: std.mem.Allocator) !void {
        if (self.query.items.len == 0) return;
        var cut = self.query.items.len - 1;
        while (cut > 0 and (self.query.items[cut] & 0xC0) == 0x80) cut -= 1; // continuation 바이트 건너뜀
        self.query.shrinkRetainingCapacity(cut);
        try self.recompute(allocator);
    }

    /// 선택을 delta만큼 이동(클램프, wrap 없음). 필터가 비면 무동작.
    pub fn moveSelection(self: *PaletteState, delta: i32) void {
        if (self.filtered.items.len == 0) return;
        const max = self.filtered.items.len - 1;
        const cur: i64 = @intCast(self.selected);
        const next = std.math.clamp(cur + delta, 0, @as(i64, @intCast(max)));
        self.selected = @intCast(next);
    }

    /// 현재 선택된 항목의 Action(없으면 null). DevSession이 이걸 받아 dispatch + hide 한다.
    pub fn selectedAction(self: *const PaletteState) ?Action {
        if (self.filtered.items.len == 0) return null;
        return command_catalog.entries[self.filtered.items[self.selected]].action;
    }

    /// 현재 쿼리로 filtered를 다시 만든다(title 대소문자 무시 부분일치). 선택은 맨 위로 리셋.
    fn recompute(self: *PaletteState, allocator: std.mem.Allocator) !void {
        self.filtered.clearRetainingCapacity();
        for (command_catalog.entries, 0..) |entry, i| {
            if (containsIgnoreCase(entry.title, self.query.items)) try self.filtered.append(allocator, i);
        }
        self.selected = 0;
    }
};

test "containsIgnoreCase: 빈 needle 통과·대소문자 무시·부분일치" {
    try std.testing.expect(containsIgnoreCase("Split Right", ""));
    try std.testing.expect(containsIgnoreCase("Split Right", "spl"));
    try std.testing.expect(containsIgnoreCase("Split Right", "RIGHT"));
    try std.testing.expect(containsIgnoreCase("Split Right", "it R"));
    try std.testing.expect(!containsIgnoreCase("Split Right", "zzz"));
    try std.testing.expect(!containsIgnoreCase("ab", "abc")); // needle이 더 길면 false
}

test "PaletteState: show/필터/선택 이동/selectedAction" {
    const allocator = std.testing.allocator;
    var p: PaletteState = .{};
    defer p.deinit(allocator);

    try p.show(allocator);
    try std.testing.expect(p.open);
    try std.testing.expectEqual(command_catalog.entries.len, p.filtered.items.len); // 빈 쿼리=전부
    try std.testing.expectEqual(@as(usize, 0), p.selected);

    // "split" → Split Right / Split Down 2개.
    for ("split") |c| try p.appendChar(allocator, c);
    try std.testing.expectEqual(@as(usize, 2), p.filtered.items.len);
    try std.testing.expect(p.selectedAction().? == .split_horizontal); // 첫 항목 = Split Right

    // 대문자 섞어도(대소문자 무시) 같은 결과.
    try p.backspace(allocator); // "spli"
    try std.testing.expect(p.filtered.items.len >= 2);

    // 선택 이동(클램프).
    p.moveSelection(1);
    try std.testing.expect(p.selectedAction().? == .split_vertical); // 둘째 = Split Down
    p.moveSelection(5); // 끝에서 더 가도 클램프
    try std.testing.expectEqual(p.filtered.items.len - 1, p.selected);
    p.moveSelection(-100); // 앞으로도 클램프
    try std.testing.expectEqual(@as(usize, 0), p.selected);
}

test "PaletteState: 매칭 없으면 selectedAction null·이동 무동작" {
    const allocator = std.testing.allocator;
    var p: PaletteState = .{};
    defer p.deinit(allocator);
    try p.show(allocator);
    for ("zzzznope") |c| try p.appendChar(allocator, c);
    try std.testing.expectEqual(@as(usize, 0), p.filtered.items.len);
    try std.testing.expect(p.selectedAction() == null);
    p.moveSelection(1); // 무동작(크래시 없음)
    try std.testing.expectEqual(@as(usize, 0), p.selected);
}

test "PaletteState: backspace로 필터 넓어지고 hide로 닫힌다" {
    const allocator = std.testing.allocator;
    var p: PaletteState = .{};
    defer p.deinit(allocator);
    try p.show(allocator);
    for ("split") |c| try p.appendChar(allocator, c);
    const narrowed = p.filtered.items.len;
    // 전부 지우면 다시 전체.
    var k: usize = 0;
    while (k < 5) : (k += 1) try p.backspace(allocator);
    try std.testing.expect(p.filtered.items.len > narrowed);
    try std.testing.expectEqual(command_catalog.entries.len, p.filtered.items.len);
    p.hide();
    try std.testing.expect(!p.open);
}
