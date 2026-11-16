//! control_agent_tab_consent — 「이 pane 의 에이전트가 로그인된 탭을 열어도 되나」 거부 기억(L2 순수).
//!
//! **왜 있나(사용자 결정 2026-11-16)**: 에이전트가 `browser.open` 으로 연 탭은 사용자의 Maru Chromium 쿠키 통을 그대로 쓴다(로그인된
//! 사이트에 그대로 로그인돼 있다). 그래서 pane 마다 처음 한 번 확인 모달로 묻는다. 허용은 pane grant(`browser_agent_tabs` — target 이 그
//! pane 자신)로 남고(`control_pane_grant`), 거부는 **여기**에 남는다 — 거부한 pane 은 한동안 다시 묻지 않는다. 기억하지 않으면 거부를 받은
//! 에이전트가 곧 다시 열어 모달을 거듭 띄운다(사용자에게 허용을 조르는 길이 된다).
//!
//! **기간**: `deny_quiet_ms`(10 분). 컨트롤 플레인의 다른 모달에는 거부 기억이 없어(control-plane-security §8.3 — grant 모달은 매번,
//! 업로드는 기억하지 않는다) 기댈 관례가 없었다. 짧으면 한 작업 턴 안의 재시도가 모달을 다시 띄우고, 길면 잘못 누른 거부(모달은 거부에
//! 포커스가 있다 — chrome-strategy §5.4 `guardAsync`)를 풀 길이 기다림뿐이다. 그 사이에서 고른 값이다.
//!
//! **수명**: 메모리만(재시작 = 빈 기억 — grant 저장소와 같은 모델). pane 이 닫히면 `forget`. 시각은 호출자가 주는 모노토닉 ms 다(벽시계를
//! 돌려도 기간이 늘거나 줄지 않게).
//!
//! **L2 순수**: std 만 import 한다. OS·소켓·GUI 0. 인스턴스는 L4(app_host_abi)가 소유한다(메인 스레드 전용).

const std = @import("std");

/// 거부한 pane 을 다시 묻지 않는 기간(ms). 값의 근거는 머리말.
pub const deny_quiet_ms: u64 = 10 * std.time.ms_per_min;

/// 기억하는 pane 수. pane 은 대개 몇 개라 넉넉하다 — 넘치면 가장 먼저 끝나는 기억을 밀어낸다(고정 배열, 할당 없음).
pub const capacity: usize = 64;

const Entry = struct { pane: u64, until_ms: u64 };

pub const DenyMemory = struct {
    entries: [capacity]Entry = undefined,
    len: usize = 0,

    /// 그 pane 이 `now_ms` 에 거부했다 — `now_ms + deny_quiet_ms` 까지 묻지 않는다. 이미 기억 중이면 기간을 새로 시작한다.
    pub fn deny(self: *DenyMemory, pane: u64, now_ms: u64) void {
        const until = now_ms +| deny_quiet_ms;
        for (self.entries[0..self.len]) |*e| if (e.pane == pane) {
            e.until_ms = until;
            return;
        };
        if (self.len < capacity) {
            self.entries[self.len] = .{ .pane = pane, .until_ms = until };
            self.len += 1;
            return;
        }
        // 가득 찼다 — 가장 먼저 끝나는 기억 자리에 둔다(끝난 기억이 있으면 그것이 가장 먼저다).
        var oldest: usize = 0;
        for (self.entries[0..self.len], 0..) |e, i| if (e.until_ms < self.entries[oldest].until_ms) {
            oldest = i;
        };
        self.entries[oldest] = .{ .pane = pane, .until_ms = until };
    }

    /// 그 pane 을 아직 묻지 않는 중이면 남은 ms(> 0), 아니면 null. 끝난 기억은 여기서 치운다.
    pub fn quietRemaining(self: *DenyMemory, pane: u64, now_ms: u64) ?u64 {
        var i: usize = 0;
        while (i < self.len) {
            const e = self.entries[i];
            if (e.until_ms <= now_ms) {
                self.entries[i] = self.entries[self.len - 1];
                self.len -= 1;
                continue;
            }
            if (e.pane == pane) return e.until_ms - now_ms;
            i += 1;
        }
        return null;
    }

    /// pane 이 닫혔다 — 그 기억을 지운다.
    pub fn forget(self: *DenyMemory, pane: u64) void {
        var i: usize = 0;
        while (i < self.len) {
            if (self.entries[i].pane == pane) {
                self.entries[i] = self.entries[self.len - 1];
                self.len -= 1;
            } else i += 1;
        }
    }

    pub fn clear(self: *DenyMemory) void {
        self.len = 0;
    }
};

/// 남은 ms 를 사람이 읽는 「분」 으로(올림, 최소 1) — 거부 글이 「about N minutes」 로 말한다.
pub fn minutesCeil(remaining_ms: u64) u64 {
    return @max(1, (remaining_ms + std.time.ms_per_min - 1) / std.time.ms_per_min);
}

// ══ 시험 — 이 기억이 무엇을 지키는가: 거부한 pane 은 기간 동안 모달 없이 거절되고, 기간이 끝나거나 pane 이 닫히면 다시 묻는다.
// 다른 pane 의 거부는 이 pane 을 막지 않는다(사용자 결정 「pane 마다」). ══
const testing = std.testing;

test "거부한 pane 은 기간 동안 남은 시간을 돌려주고, 기간이 끝나면 다시 묻는다(null)" {
    var m: DenyMemory = .{};
    try testing.expect(m.quietRemaining(5, 1000) == null);
    m.deny(5, 1000);
    try testing.expectEqual(@as(?u64, deny_quiet_ms), m.quietRemaining(5, 1000));
    try testing.expectEqual(@as(?u64, 1), m.quietRemaining(5, 1000 + deny_quiet_ms - 1));
    try testing.expect(m.quietRemaining(5, 1000 + deny_quiet_ms) == null); // 끝나는 순간부터 다시 묻는다
    try testing.expectEqual(@as(usize, 0), m.len); // 끝난 기억은 치웠다
}

test "다른 pane 의 거부는 이 pane 을 막지 않는다, 다시 거부하면 기간이 새로 시작한다" {
    var m: DenyMemory = .{};
    m.deny(5, 0);
    try testing.expect(m.quietRemaining(6, 10) == null);
    m.deny(5, 60_000);
    try testing.expectEqual(@as(?u64, deny_quiet_ms), m.quietRemaining(5, 60_000));
    try testing.expectEqual(@as(usize, 1), m.len); // 같은 pane 은 한 자리
}

test "pane 이 닫히면 잊는다 — 다른 pane 의 기억은 남는다" {
    var m: DenyMemory = .{};
    m.deny(5, 0);
    m.deny(6, 0);
    m.deny(7, 0);
    m.forget(6);
    try testing.expect(m.quietRemaining(6, 1) == null);
    try testing.expect(m.quietRemaining(5, 1) != null);
    try testing.expect(m.quietRemaining(7, 1) != null);
}

test "가득 차면 가장 먼저 끝나는 기억을 밀어내고, 새 거부는 늘 남는다" {
    var m: DenyMemory = .{};
    for (0..capacity) |i| m.deny(100 + i, 1000 + i); // 100 이 가장 먼저 끝난다
    m.deny(999, 5000);
    try testing.expectEqual(capacity, m.len);
    try testing.expect(m.quietRemaining(999, 5000) != null);
    try testing.expect(m.quietRemaining(100, 1000) == null); // 밀려났다
    try testing.expect(m.quietRemaining(101, 1001) != null);
}

test "0 시각과 아주 큰 시각에서도 넘치지 않는다" {
    var m: DenyMemory = .{};
    m.deny(1, 0);
    try testing.expectEqual(@as(?u64, deny_quiet_ms), m.quietRemaining(1, 0));
    m.deny(2, std.math.maxInt(u64) - 5);
    try testing.expectEqual(@as(?u64, 5), m.quietRemaining(2, std.math.maxInt(u64) - 10 + 5));
}

test "분 올림 — 남은 시간이 조금이라도 있으면 1 분 이상으로 말한다" {
    try testing.expectEqual(@as(u64, 1), minutesCeil(1));
    try testing.expectEqual(@as(u64, 1), minutesCeil(std.time.ms_per_min));
    try testing.expectEqual(@as(u64, 2), minutesCeil(std.time.ms_per_min + 1));
    try testing.expectEqual(@as(u64, 10), minutesCeil(deny_quiet_ms));
}
