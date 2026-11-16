//! control_agent_tab_consent — 「이 pane 의 에이전트가 로그인된 사이트를 쓰는 탭을 열어도 되나」 답의 기억(L2 순수).
//!
//! **왜 있나(사용자 결정 2026-11-16)**: 에이전트가 `browser.open` 으로 연 탭은 사용자의 Maru Chromium 쿠키 통을 그대로 쓴다(로그인된
//! 사이트에 그대로 로그인돼 있다). 그래서 pane 마다 처음 한 번 확인 모달로 묻는다. **허용도 거부도 그 pane 이 사는 동안 남고, 사용자는 Browser
//! Grants 메뉴에서 둘 다 되돌릴 수 있다**(사용자 결정 원문 「팬이 살아있는 동안인데 거부나 허용 해제할 수 있는 UI를 주세요」).
//!
//! - 허용의 **권한**은 pane grant(`browser_agent_tabs` — target 이 그 pane 자신, `control_pane_grant`)가 갖는다. 여기는 그 pane 을 메뉴에 보일
//!   **제목**만 함께 든다.
//! - 거부는 **여기**가 권한이다 — 거부한 pane 은 그 pane 이 사는 동안(또는 사용자가 메뉴에서 지울 때까지) 모달 없이 거절된다. 기억하지 않으면 거부를
//!   받은 에이전트가 곧 다시 열어 모달을 거듭 띄운다(사용자에게 허용을 조르는 길이 된다).
//!
//! **수명**: 메모리만(재시작 = 빈 기억 — grant 저장소와 같은 모델). pane 이 닫히면 `forget`.
//!
//! **제목**: pane 제목은 그 pane 의 프로그램(묻는 에이전트 자신일 수 있다)이 OSC 로 정한다 — 모달과 메뉴가 같은 규칙(`sanitizeTitle`)으로 거른다.
//!
//! **L2 순수**: std 만 import 한다. OS·소켓·GUI 0. 인스턴스는 L4(app_host_abi)가 소유한다(메인 스레드 전용).

const std = @import("std");

/// 기억하는 pane 수. pane 은 대개 몇 개라 넉넉하다 — 넘치면 **허용 항목의 제목**부터 밀어낸다(권한은 grant 저장소에 있다 — 잃는 것은 메뉴의
/// 제목뿐이다). 거부만으로 가득 차면 가장 먼저 기억한 거부를 밀어낸다(그 pane 은 다시 묻는다 — 거부를 잃는 쪽이 허용을 잃는 쪽보다 안전하다).
pub const capacity: usize = 64;
/// 기억하는 제목의 바이트 상한(글자 경계에서 자른다).
pub const max_title_bytes: usize = 96;

pub const Entry = struct {
    pane: u64,
    denied: bool,
    title_buf: [max_title_bytes]u8 = undefined,
    title_len: u8 = 0,
    /// 기억한 차례(밀어낼 때 가장 오래된 것을 고른다).
    seq: u64 = 0,

    pub fn title(self: *const Entry) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

pub const PaneMemory = struct {
    entries: [capacity]Entry = undefined,
    len: usize = 0,
    next_seq: u64 = 1,

    fn find(self: *PaneMemory, pane: u64) ?*Entry {
        for (self.entries[0..self.len]) |*e| if (e.pane == pane) return e;
        return null;
    }

    /// 그 pane 의 답을 기억한다(이미 있으면 바꾼다). 제목은 `sanitizeTitle` 로 거른다.
    pub fn remember(self: *PaneMemory, pane: u64, denied: bool, raw_title: []const u8) void {
        const slot = self.find(pane) orelse blk: {
            if (self.len < capacity) {
                self.len += 1;
                break :blk &self.entries[self.len - 1];
            }
            break :blk &self.entries[self.victim()];
        };
        slot.* = .{ .pane = pane, .denied = denied, .seq = self.next_seq };
        self.next_seq += 1;
        var tmp: [max_title_bytes]u8 = undefined;
        const clean = sanitizeTitle(&tmp, raw_title); // 앞 공백을 떼면 tmp 의 가운데부터일 수 있다 — 앞으로 옮겨 담는다
        @memcpy(slot.title_buf[0..clean.len], clean);
        slot.title_len = @intCast(clean.len);
    }

    /// 가득 찼을 때 밀어낼 자리 — 가장 오래된 허용 항목, 없으면 가장 오래된 거부.
    fn victim(self: *const PaneMemory) usize {
        var best: ?usize = null;
        for (self.entries[0..self.len], 0..) |e, i| if (!e.denied) {
            if (best == null or e.seq < self.entries[best.?].seq) best = i;
        };
        if (best) |b| return b;
        var oldest: usize = 0;
        for (self.entries[0..self.len], 0..) |e, i| if (e.seq < self.entries[oldest].seq) {
            oldest = i;
        };
        return oldest;
    }

    /// 그 pane 이 거부했는가(사는 동안·메뉴에서 지울 때까지).
    pub fn isDenied(self: *const PaneMemory, pane: u64) bool {
        for (self.entries[0..self.len]) |e| if (e.pane == pane) return e.denied;
        return false;
    }

    /// 그 pane 의 기억한 제목(없으면 null).
    pub fn titleOf(self: *const PaneMemory, pane: u64) ?[]const u8 {
        for (self.entries[0..self.len]) |*e| if (e.pane == pane) return e.title();
        return null;
    }

    /// 그 pane 의 거부를 지운다(메뉴 — 다음 open 은 다시 묻는다). 거부가 아니면(허용 항목·없음) 아무것도 안 하고 거짓.
    pub fn clearDenied(self: *PaneMemory, pane: u64) bool {
        for (self.entries[0..self.len], 0..) |e, i| if (e.pane == pane and e.denied) {
            self.removeAt(i);
            return true;
        };
        return false;
    }

    /// 거부한 pane 수와 i 번째 거부(기억한 차례 — 메뉴가 열 때마다 새로 읽는다).
    pub fn deniedCount(self: *const PaneMemory) usize {
        var n: usize = 0;
        for (self.entries[0..self.len]) |e| n += @intFromBool(e.denied);
        return n;
    }

    pub fn deniedAt(self: *const PaneMemory, index: usize) ?*const Entry {
        var n: usize = 0;
        for (self.entries[0..self.len]) |*e| if (e.denied) {
            if (n == index) return e;
            n += 1;
        };
        return null;
    }

    /// pane 이 닫혔거나 그 허용을 거뒀다 — 그 pane 의 기억(허용 제목·거부)을 지운다.
    pub fn forget(self: *PaneMemory, pane: u64) void {
        var i: usize = 0;
        while (i < self.len) {
            if (self.entries[i].pane == pane) self.removeAt(i) else i += 1;
        }
    }

    /// 거부를 모두 지운다(메뉴 「Revoke All」 — 허용 grant 와 함께 모두 처음으로).
    pub fn clearAllDenied(self: *PaneMemory) void {
        var i: usize = 0;
        while (i < self.len) {
            if (self.entries[i].denied) self.removeAt(i) else i += 1;
        }
    }

    pub fn clear(self: *PaneMemory) void {
        self.len = 0;
    }

    /// 차례(seq)를 지키며 뺀다 — 메뉴의 줄 순서가 지울 때마다 섞이지 않게.
    fn removeAt(self: *PaneMemory, i: usize) void {
        std.mem.copyForwards(Entry, self.entries[i .. self.len - 1], self.entries[i + 1 .. self.len]);
        self.len -= 1;
    }
};

/// pane 제목을 모달·메뉴에 실을 수 있게 거른다 — 문장을 흔들 수 있는 글자를 공백으로: C0·C1 제어 글자(줄바꿈 — 줄을 바꾼다)와 **양방향·폭 0 서식
/// 글자**(U+061C·U+200B–U+200F·U+202A–U+202E·U+2060–U+2064·U+2066–U+2069·U+FEFF — RLO 하나면 뒤따르는 「… Allow?」 까지 거꾸로 그려져 사용자가 읽는
/// 질문이 바뀐다; 적대 리뷰 R15). UTF-8 이 아니면 「?」. `out` 이 차면 글자 경계에서 멈춘다. 앞뒤 공백은 뗀다.
pub fn sanitizeTitle(out: []u8, title: []const u8) []const u8 {
    const view = std.unicode.Utf8View.init(title) catch return copyLiteral(out, "?");
    var it = view.iterator();
    var n: usize = 0;
    while (it.nextCodepointSlice()) |bytes| {
        const cp = std.unicode.utf8Decode(bytes) catch return copyLiteral(out, "?");
        const unsafe = cp < 0x20 or (cp >= 0x7F and cp <= 0x9F) or cp == 0x061C or (cp >= 0x200B and cp <= 0x200F) or
            (cp >= 0x202A and cp <= 0x202E) or (cp >= 0x2060 and cp <= 0x2064) or (cp >= 0x2066 and cp <= 0x2069) or cp == 0xFEFF;
        const piece: []const u8 = if (unsafe) " " else bytes;
        if (n + piece.len > out.len) break;
        @memcpy(out[n..][0..piece.len], piece);
        n += piece.len;
    }
    return std.mem.trim(u8, out[0..n], " ");
}

fn copyLiteral(out: []u8, s: []const u8) []const u8 {
    const n = @min(out.len, s.len);
    @memcpy(out[0..n], s[0..n]);
    return out[0..n];
}

// ══ 시험 — 이 기억이 무엇을 지키는가: 거부한 pane 은 그 pane 이 사는 동안 모달 없이 거절되고, 사용자가 메뉴에서 그 거부를 지우거나 pane 이 닫히면
// 다시 묻는다. 다른 pane 의 답은 이 pane 에 번지지 않는다(사용자 결정 「pane 마다」). 메뉴에 보일 제목은 모달과 같은 규칙으로 거른다. ══
const testing = std.testing;

test "거부는 pane 이 사는 동안 남는다 — 시간이 흘러도, 다른 pane 의 거부·허용과 섞이지 않고" {
    var m: PaneMemory = .{};
    try testing.expect(!m.isDenied(5));
    m.remember(5, true, "claude");
    m.remember(6, false, "codex");
    try testing.expect(m.isDenied(5));
    try testing.expect(!m.isDenied(6)); // 허용 항목은 거부가 아니다
    try testing.expect(!m.isDenied(7));
    try testing.expectEqualStrings("claude", m.titleOf(5).?);
    try testing.expectEqualStrings("codex", m.titleOf(6).?);
    try testing.expectEqual(@as(usize, 1), m.deniedCount());
    try testing.expectEqual(@as(u64, 5), m.deniedAt(0).?.pane);
    try testing.expect(m.deniedAt(1) == null);
}

test "메뉴에서 거부를 지우면 다시 묻는다 — 허용 항목은 그 길로 지워지지 않는다" {
    var m: PaneMemory = .{};
    m.remember(5, true, "a");
    m.remember(6, false, "b");
    try testing.expect(!m.clearDenied(6)); // 허용은 거부 지우기로 사라지지 않는다(그 철회는 grant 줄이 한다)
    try testing.expect(m.titleOf(6) != null);
    try testing.expect(m.clearDenied(5));
    try testing.expect(!m.isDenied(5));
    try testing.expect(!m.clearDenied(5)); // 멱등
    try testing.expectEqual(@as(usize, 0), m.deniedCount());
}

test "답을 바꾸면(거부 → 허용, 허용 → 거부) 한 자리에서 바뀐다; Revoke All 은 거부만 모두 지운다" {
    var m: PaneMemory = .{};
    m.remember(5, true, "a");
    m.remember(5, false, "a2");
    try testing.expect(!m.isDenied(5));
    try testing.expectEqualStrings("a2", m.titleOf(5).?);
    try testing.expectEqual(@as(usize, 1), m.len);
    m.remember(6, true, "b");
    m.remember(7, true, "c");
    m.clearAllDenied();
    try testing.expectEqual(@as(usize, 0), m.deniedCount());
    try testing.expect(m.titleOf(5) != null);
}

test "pane 이 닫히면 잊는다 — 다른 pane 의 기억은 남고 줄 순서는 그대로다" {
    var m: PaneMemory = .{};
    m.remember(5, true, "a");
    m.remember(6, true, "b");
    m.remember(7, true, "c");
    m.forget(6);
    try testing.expect(!m.isDenied(6));
    try testing.expectEqual(@as(u64, 5), m.deniedAt(0).?.pane);
    try testing.expectEqual(@as(u64, 7), m.deniedAt(1).?.pane);
}

test "가득 차면 허용 제목부터 밀어내고, 거부뿐이면 가장 오래된 거부를 — 새 답은 늘 남는다" {
    var m: PaneMemory = .{};
    m.remember(1, false, "allow");
    for (0..capacity - 1) |i| m.remember(100 + i, true, "deny");
    m.remember(999, true, "new");
    try testing.expect(m.titleOf(1) == null); // 허용 제목이 먼저 밀렸다
    try testing.expect(m.isDenied(100) and m.isDenied(999));
    m.remember(1000, true, "newer");
    try testing.expect(!m.isDenied(100)); // 거부뿐 — 가장 오래된 거부
    try testing.expect(m.isDenied(1000) and m.isDenied(101));
}

test "제목은 제어·양방향·폭 0 글자를 공백으로, 깨진 UTF-8 은 「?」, 상한에서 글자 경계로 자른다" {
    var buf: [max_title_bytes]u8 = undefined;
    const t = sanitizeTitle(&buf, "\nsafe\u{202E}?wollA \u{2066}x\u{2069}\u{200D}\u{FEFF}\u{061C}y\u{0085}z\x1b ");
    for ([_][]const u8{ "\n", "\u{202E}", "\u{2066}", "\u{2069}", "\u{200D}", "\u{FEFF}", "\u{061C}", "\u{0085}", "\x1b" }) |bad| try testing.expect(std.mem.indexOf(u8, t, bad) == null);
    try testing.expect(std.mem.startsWith(u8, t, "safe") and std.mem.indexOf(u8, t, "y") != null);
    try testing.expectEqualStrings("?", sanitizeTitle(&buf, "a\xffb"));
    var small: [5]u8 = undefined;
    const cut = sanitizeTitle(&small, "가나다");
    try testing.expectEqualStrings("가", cut); // 6 바이트가 5 에 안 들어간다 — 글자 경계
    var m: PaneMemory = .{};
    m.remember(5, true, "x\u{202E}y");
    try testing.expectEqualStrings("x y", m.titleOf(5).?);
    m.remember(6, true, "\n\n  lead");
    try testing.expectEqualStrings("lead", m.titleOf(6).?); // 앞 공백을 뗀 제목이 제자리에 담긴다
}
