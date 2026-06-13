//! 스크롤백 Find(⌘F) 상태머신 — 순수 로직(렌더·OS·PTY·검색 알고리즘 무관). open/query/matches/current만
//! 소유한다. 검색 자체는 코어(core.findMatches, 단일 출처)가 하고 DevSession이 그 결과를 이 matches에
//! 채운다(recompute) — command_palette의 PaletteState가 정적 카탈로그를 필터하듯, 여기선 동적 매치 리스트를
//! 들고 네비게이션(current 인덱스)만 옮긴다. DevSession이 현재 매치를 뷰로 스크롤하고 오버레이로 그린다.
//! 베이스: Ghostty 스크롤백 검색의 증분·N/M 네비게이션 모델(같은 1차 레퍼런스). regex/fuzzy는 후속.

const std = @import("std");
const maru = @import("maru");

const Match = maru.terminal.Match;

pub const FindState = struct {
    open: bool = false,
    query: std.ArrayList(u8) = .empty, // 타이핑한 검색어(UTF-8)
    matches: std.ArrayList(Match) = .empty, // 절대-좌표 매치(DevSession.recomputeFind가 코어에서 채움)
    current: usize = 0, // matches 안에서의 현재(네비게이션) 위치

    pub fn deinit(self: *FindState, allocator: std.mem.Allocator) void {
        self.query.deinit(allocator);
        self.matches.deinit(allocator);
    }

    /// 오버레이를 연다 — 검색어를 비우고 매치도 비운다(DevSession이 곧 recompute하지만 빈 쿼리면 매치 0이라 안전).
    pub fn show(self: *FindState) void {
        self.query.clearRetainingCapacity();
        self.matches.clearRetainingCapacity();
        self.current = 0;
        self.open = true;
    }

    pub fn hide(self: *FindState) void {
        self.open = false;
    }

    /// 검색어에 글자(코드포인트) 추가. 재검색은 호출자(DevSession.recomputeFind)가 한다.
    pub fn appendChar(self: *FindState, allocator: std.mem.Allocator, cp: u21) !void {
        var utf8: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &utf8) catch return; // 인코딩 불가 코드포인트는 무시
        try self.query.appendSlice(allocator, utf8[0..n]);
    }

    /// 마지막 코드포인트 1개 삭제(UTF-8 경계 존중). 빈 쿼리면 무동작. 재검색은 호출자가 한다.
    pub fn backspace(self: *FindState) void {
        if (self.query.items.len == 0) return;
        var cut = self.query.items.len - 1;
        while (cut > 0 and (self.query.items[cut] & 0xC0) == 0x80) cut -= 1; // continuation 바이트 건너뜀
        self.query.shrinkRetainingCapacity(cut);
    }

    /// 다음 매치로(wrap). 매치 없으면 무동작.
    pub fn next(self: *FindState) void {
        if (self.matches.items.len == 0) return;
        self.current = (self.current + 1) % self.matches.items.len;
    }

    /// 이전 매치로(wrap). 매치 없으면 무동작.
    pub fn prev(self: *FindState) void {
        if (self.matches.items.len == 0) return;
        self.current = (self.current + self.matches.items.len - 1) % self.matches.items.len;
    }

    /// 현재(네비게이션) 매치(없으면 null). DevSession이 이걸 뷰로 스크롤하고 강조색으로 그린다.
    pub fn currentMatch(self: *const FindState) ?Match {
        if (self.matches.items.len == 0) return null;
        return self.matches.items[self.current];
    }
};

test "FindState: show/hide·appendChar·backspace(UTF-8 경계)" {
    const allocator = std.testing.allocator;
    var f: FindState = .{};
    defer f.deinit(allocator);

    f.show();
    try std.testing.expect(f.open);
    try std.testing.expectEqual(@as(usize, 0), f.query.items.len);

    try f.appendChar(allocator, 'a');
    try f.appendChar(allocator, 'b');
    try f.appendChar(allocator, '한'); // 3바이트
    try std.testing.expectEqual(@as(usize, 5), f.query.items.len);
    f.backspace(); // '한' 한 코드포인트(3바이트) 제거
    try std.testing.expectEqualStrings("ab", f.query.items);
    f.backspace();
    f.backspace();
    f.backspace(); // 빈 쿼리에서 추가 backspace 무동작
    try std.testing.expectEqual(@as(usize, 0), f.query.items.len);

    f.hide();
    try std.testing.expect(!f.open);
}

test "FindState: next/prev wrap·currentMatch" {
    const allocator = std.testing.allocator;
    var f: FindState = .{};
    defer f.deinit(allocator);

    // 매치 없을 때 네비게이션·currentMatch는 안전(무동작/null).
    try std.testing.expect(f.currentMatch() == null);
    f.next();
    f.prev();
    try std.testing.expectEqual(@as(usize, 0), f.current);

    // 매치 3개를 직접 채워(코어 없이 순수 인덱스 동작 검증) wrap을 확인.
    try f.matches.append(allocator, .{ .start = .{ .row = 1, .col = 0 }, .end = .{ .row = 1, .col = 2 } });
    try f.matches.append(allocator, .{ .start = .{ .row = 5, .col = 0 }, .end = .{ .row = 5, .col = 2 } });
    try f.matches.append(allocator, .{ .start = .{ .row = 9, .col = 0 }, .end = .{ .row = 9, .col = 2 } });

    try std.testing.expectEqual(@as(usize, 1), f.currentMatch().?.start.row); // current=0 → 첫 매치(row 1)
    f.next();
    try std.testing.expectEqual(@as(usize, 5), f.currentMatch().?.start.row);
    f.next();
    f.next(); // 2 → wrap → 0
    try std.testing.expectEqual(@as(usize, 0), f.current);
    f.prev(); // 0 → wrap → 2
    try std.testing.expectEqual(@as(usize, 2), f.current);
    try std.testing.expectEqual(@as(usize, 9), f.currentMatch().?.start.row);
}
