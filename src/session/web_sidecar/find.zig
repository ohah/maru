//! 페이지 찾기(P0-2)의 짝 맞추기 — sidecar 의 브라우저마다 「지금 찾기 한 판」을 들고, CEF 의 찾기 답(`on_find_result`)이 그 판의 것인지
//! 가린 뒤 maru 에 보낼 답(`find_result`)으로 정리한다. CEF 를 모르는 순수 규칙이라 L2 에 두고 Linux 에서도 시험한다(sidecar 는 CEF 콜백에서
//! 부르기만 한다 — `platform/macos/web_sidecar/find.zig`).
//!
//! **왜 identifier 를 가리나.** CEF 의 답은 maru 의 번호를 모른다 — `identifier` 만 싣는다. 헤더(`cef_find_handler_capi.h`)는 그것을 「지금
//! 찾기의 고유한, 늘어나는 번호」라고만 적는다. 실측(CEF 154.0.23, 판정자 `find-*` 를 만들며 sidecar 에 임시 줄을 달아 쟀다):
//! - 프로세스 전체에서 **늘어나기만 하는** 수다 — 다른 브라우저의 부름도 같은 수를 올린다(둘째 탭의 첫 답이 14 였다).
//! - 우리의 `find` 부름마다 1 씩 오르지만 **그것만이 아니다** — 브라우저를 만들 때도 하나 올랐다(멈춤·닫기·이동·숨김은 올리지 않았다).
//!   그래서 「부른 차례 = identifier」 로 정확히 맞추면 탭을 하나 더 연 뒤의 답을 모두 버렸다(판정자 `find-two-tabs` 가 잡았다).
//! - 이동하면 Chromium 이 같은 identifier 로 새 문서를 다시 찾아 답한다(수가 0 에서 다시 오른다).
//! - 새 찾기 둘을 잇달아 부르면 앞 부름의 답은 오지 않았다(`find-stale`) — 그래도 앞 질의의 늦은 답이 새 질의 자리에 붙으면 오버레이가 옛
//!   글의 수를 말하므로 막는다.
//!
//! 규칙: 우리가 부른 수(`Counter.calls`)와 지금까지 배운 「CEF 가 더 올린 만큼」(`Counter.gap` — 늘기만 한다)으로 지금 부름의 identifier 의
//! **아래 끝**을 정한다. 앞 부름들의 identifier 는 그보다 작다(배운 틈은 그 부름 때의 틈 이상이고 CEF 의 수는 줄지 않는다). 그 아래 끝 이상인 첫
//! 답으로 이 부름의 identifier 를 **배우고**, 그 뒤로는 그 identifier 만 받는다. 남는 틈: 틈을 배우기 전에 브라우저를 만들고(틈 +1), 그 뒤의
//! 부름이 답을 하나도 못 받은 채 다음 부름이 나가고, 그 앞 부름의 늦은 답이 온다 — 셋이 겹쳐야 옛 수가 한 번 붙는다(실측에서 앞 부름의 답은
//! 오지 않았다). identifier 가 int 끝에서 돌면(2^31 번) 답이 버려진다 — 수가 안 보일 뿐이다.

const std = @import("std");
const message = @import("message.zig");

/// maru 에 보낼 답의 몸(브라우저 id 는 부르는 쪽이 붙인다).
pub const Reply = struct {
    request: u32,
    count: u32,
    active: u32,
    final: bool,
};

/// CEF identifier 의 셈 — sidecar 프로세스에 **하나**(모든 브라우저가 함께 올린다, 위 실측).
pub const Counter = struct {
    /// 우리가 `find` 를 부른 수(프로세스 전체).
    calls: i64 = 0,
    /// 배운 틈 — 어느 부름의 identifier 에서 그 부름의 차례를 뺀 값의 가장 큰 것(CEF 가 우리 부름 말고도 올린 만큼). 늘기만 한다.
    gap: i64 = 0,

    /// 다음 부름의 차례와, 그 부름의 identifier 의 아래 끝.
    fn take(self: *Counter) struct { index: i64, floor: i64 } {
        const index = self.calls;
        self.calls += 1;
        return .{ .index = index, .floor = index + self.gap };
    }

    fn learn(self: *Counter, index: i64, identifier: c_int) void {
        const gap = @as(i64, identifier) - index;
        if (gap > self.gap) self.gap = gap;
    }
};

/// 브라우저 하나의 찾기 상태. 0 값이 「찾기 없음」이다.
pub const Session = struct {
    /// maru 가 매긴 지금 찾기의 번호(0 = 찾기 없음 — 멈췄거나 한 번도 안 했다).
    request: u32 = 0,
    /// 이 브라우저의 마지막 부름의 차례(프로세스 전체 셈) — 아직 부르지 않았으면 null(그때는 어떤 답도 받지 않는다).
    index: ?i64 = null,
    /// 그 부름의 identifier 의 아래 끝(`Counter.take`).
    floor: i64 = 0,
    /// 배운 그 부름의 identifier(첫 답에서) — 그 뒤로는 이것만 받는다.
    identifier: ?c_int = null,
    /// 마지막으로 보낸 답 — 같은 답의 되풀이는 보내지 않는다(Chromium 은 같은 수를 여러 번 알린다).
    last: ?Reply = null,

    /// 찾기 하나를 부르기 직전에. `request` 는 0 이 아니다(wire 가 이미 막았다).
    pub fn begin(self: *Session, counter: *Counter, request: u32) void {
        const slot = counter.take();
        self.index = slot.index;
        self.floor = slot.floor;
        self.identifier = null;
        self.request = request;
        self.last = null;
    }

    /// 찾기를 멈췄다 — 그 뒤의 답은 모두 버린다. 셈은 그대로다(CEF 의 수도 멈춤에 돌아가지 않는다).
    pub fn stop(self: *Session) void {
        self.request = 0;
        self.last = null;
    }

    /// CEF 의 답 하나 — 지금 부름의 것이면 보낼 답, 아니면(앞 부름의 늦은 답·멈춘 뒤·찾기 없음·같은 답 되풀이) null.
    /// 값은 wire 의 닫힌 칸을 지키게 정리한다: 음수는 0, 차례가 수를 넘으면 수로, 일치가 없으면 차례 0.
    pub fn accept(self: *Session, counter: *Counter, identifier: c_int, count: c_int, active: c_int, final: bool) ?Reply {
        const index = self.index orelse return null;
        if (self.request == 0) return null;
        if (self.identifier) |known| {
            if (identifier != known) return null;
        } else {
            if (identifier < self.floor) return null; // 앞 부름의 것
            self.identifier = identifier;
            counter.learn(index, identifier);
        }
        const total: u32 = if (count > 0) @intCast(count) else 0;
        var at: u32 = if (active > 0) @intCast(active) else 0;
        if (at > total) at = total;
        const reply: Reply = .{ .request = self.request, .count = total, .active = at, .final = final };
        if (self.last) |last| if (std.meta.eql(last, reply)) return null;
        self.last = reply;
        return reply;
    }
};

/// maru 에 보낼 frame 의 값.
pub fn resultMessage(browser: message.BrowserId, reply: Reply) message.FindResult {
    return .{ .browser = browser, .request = reply.request, .count = reply.count, .active = reply.active, .final = reply.final };
}

// 이 시험은 찾기 답이 **지금 질의의 것만** maru 에 가는지를 증명한다 — 앞 질의의 늦은 답이 새 질의 자리에 붙으면 오버레이가 사용자가 친 적
// 없는 글의 수를 말한다(터미널의 찾기 오버레이와 같은 자리라 그 수를 믿는다).

test "P0-2 find: 지금 부름의 답만 받는다 — 앞 부름의 늦은 답·멈춘 뒤·찾기 없음은 버린다" {
    var counter: Counter = .{};
    var s: Session = .{};
    try std.testing.expect(s.accept(&counter, 0, 3, 1, true) == null); // 찾기 없음(0 이라도)
    s.begin(&counter, 7); // CEF identifier 0(실측 — 첫 부름)
    s.begin(&counter, 8); // 글을 바꿨다 — 앞 부름(0)의 답은 이제 남의 것
    try std.testing.expect(s.accept(&counter, 0, 5, 2, true) == null);
    const got = s.accept(&counter, 1, 4, 1, false) orelse return error.TestExpectedReply;
    try std.testing.expectEqual(Reply{ .request = 8, .count = 4, .active = 1, .final = false }, got);
    try std.testing.expect(s.accept(&counter, 0, 5, 2, true) == null); // 배운 뒤에도
    s.stop();
    try std.testing.expect(s.accept(&counter, 1, 4, 1, true) == null);
    s.begin(&counter, 9); // 멈춘 뒤 다시 — 셈은 이어진다
    try std.testing.expect(s.accept(&counter, 1, 4, 1, true) == null);
    try std.testing.expect(s.accept(&counter, 2, 4, 1, true) != null);
}

test "P0-2 find: 브라우저를 만들어 CEF 가 수를 더 올려도 다음 답을 받고, 그 틈을 배워 다음 부름의 앞 답을 거른다" {
    var counter: Counter = .{};
    var a: Session = .{};
    var b: Session = .{};
    a.begin(&counter, 1); // identifier 0
    try std.testing.expect(a.accept(&counter, 0, 7, 1, true) != null);
    // 여기서 브라우저 b 를 만들었다 — CEF 의 수가 하나 더 올랐다(실측). b 의 첫 부름은 차례 1 인데 identifier 는 2.
    b.begin(&counter, 2);
    try std.testing.expect(b.accept(&counter, 2, 1, 1, true) != null);
    try std.testing.expectEqual(@as(i64, 1), counter.gap);
    // a 의 다음 부름(차례 2) — identifier 3. 차례대로만 맞추면 버렸을 답이다.
    a.begin(&counter, 3);
    try std.testing.expect(a.accept(&counter, 2, 7, 2, true) == null); // 아래 끝(2 + 1 = 3) 밑 — b 의 것·옛 것
    try std.testing.expect(a.accept(&counter, 3, 7, 2, true) != null);
    try std.testing.expect(a.accept(&counter, 4, 7, 3, true) == null); // 배운 뒤 다른 identifier
}

test "P0-2 find: 이동한 뒤 Chromium 이 같은 identifier 로 새 문서를 다시 찾은 답도 받는다(수가 0 에서 다시)" {
    var counter: Counter = .{};
    var s: Session = .{};
    s.begin(&counter, 4);
    try std.testing.expect(s.accept(&counter, 0, 7, 2, true) != null);
    try std.testing.expectEqual(Reply{ .request = 4, .count = 0, .active = 0, .final = false }, s.accept(&counter, 0, 0, 0, false).?);
    try std.testing.expectEqual(Reply{ .request = 4, .count = 7, .active = 1, .final = true }, s.accept(&counter, 0, 7, 1, true).?);
}

test "P0-2 find: 값은 닫힌 칸으로 정리한다 — 음수·차례가 수를 넘음·일치 없음" {
    var counter: Counter = .{};
    var s: Session = .{};
    s.begin(&counter, 1);
    try std.testing.expectEqual(Reply{ .request = 1, .count = 0, .active = 0, .final = false }, s.accept(&counter, 0, -1, -1, false).?);
    try std.testing.expectEqual(Reply{ .request = 1, .count = 3, .active = 0, .final = false }, s.accept(&counter, 0, 3, 0, false).?);
    try std.testing.expectEqual(Reply{ .request = 1, .count = 3, .active = 3, .final = false }, s.accept(&counter, 0, 3, 9, false).?);
    try std.testing.expectEqual(Reply{ .request = 1, .count = 0, .active = 0, .final = true }, s.accept(&counter, 0, 0, 2, true).?);
}

test "P0-2 find: 같은 답의 되풀이는 한 번만 — 끝 표시가 바뀌면 다시 보낸다, 새 부름은 처음부터" {
    var counter: Counter = .{};
    var s: Session = .{};
    s.begin(&counter, 4);
    try std.testing.expect(s.accept(&counter, 0, 2, 1, false) != null);
    try std.testing.expect(s.accept(&counter, 0, 2, 1, false) == null);
    try std.testing.expect(s.accept(&counter, 0, 2, 1, true) != null);
    try std.testing.expect(s.accept(&counter, 0, 2, 1, true) == null);
    s.begin(&counter, 4); // 같은 번호의 다음 부름 — 같은 답이어도 새 부름의 첫 답이다
    try std.testing.expect(s.accept(&counter, 1, 2, 1, true) != null);
}

test "P0-2 find: 보낼 frame 값은 wire 의 닫힌 칸을 지난다" {
    const codec = @import("codec.zig");
    var buf: [128]u8 = undefined;
    var counter: Counter = .{};
    var s: Session = .{};
    s.begin(&counter, 3);
    for ([_][3]c_int{ .{ -5, -5, 0 }, .{ 0, 7, 1 }, .{ 2, 5, 0 }, .{ std.math.maxInt(c_int), 1, 1 } }) |v| {
        if (s.accept(&counter, 0, v[0], v[1], v[2] != 0)) |reply| {
            _ = try codec.encode(.{ .find_result = resultMessage(5, reply) }, &buf);
        }
    }
}
