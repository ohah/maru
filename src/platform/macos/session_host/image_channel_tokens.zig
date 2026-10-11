//! 이미지 채널 token 표와 채널 자리 확보 — host owner 층의 std-only leaf.
//!
//! 단일 출처는 [Session host 이미지 채널](../../../../docs/session-host-image-channel.md) §3.1 이다. 이미지 채널은 주
//! 연결과 따로 accept 되는 두 번째 연결이라 슬롯 하나를 잠깐 쓴다(입양되면 그 슬롯은 풀린다). 그 자리를 **owner 층
//! 카운터**로 확보한다 — 미사용 token 하나가 자리 하나다. `SlotTable`·`ReactorCore` 에 예약 상태를 두지 않는 이유:
//! 실제 슬롯을 Client 없이 쥐면 `destroyAll` 이 못 돌려줘 업그레이드 handoff 가 거부된다.
//!
//! - token 은 hello 처리 때 자리가 남을 때만 발급한다(`tokenIssuable`).
//! - 이미지 채널이 아닌 hello 는 `handshake 를 마친 다른 연결 수 + 미사용 token 수` 가 슬롯 상한에 닿으면 닫는다
//!   (`helloAdmits`) — handshake 를 마친 연결이 token 의 자리를 먹지 못하게. 보장은 아니다: 집행은 hello 에서만 하므로
//!   아직 hello 를 안 보낸 연결이 마지막 슬롯을 쥐고 있으면 채널 connect 는 거부되고 앱은 「이미지 채널 없음」으로 간다.
//! - 확보는 넷 중 하나로 풀린다: 입양(`take`), 만료(`expire`), 주 연결 종료(`dropFor`, `destroyAll` 포함), abandon(`dropFor`).
//!
//! OS 를 모르는 leaf 라 규칙을 PR CI(check-boundaries)에서 잰다.

const std = @import("std");

/// token 을 발급한 뒤 앱이 채널을 열 때까지 기다리는 시간. 앱의 connect 함수는 이보다 짧은 deadline 으로 `bind_ack`
/// 를 기다리고, 못 받으면 `image_channel.abandon` 으로 먼저 버린다. host 쪽 만료는 abandon 이 오지 않은 경우(앱이
/// 죽었거나 연결이 끊긴 경우)를 위한 바닥이다.
pub const token_ttl_ns: u64 = 10 * std.time.ns_per_s;

/// 미사용 token 최대 개수. 주 연결 하나가 token 하나를 쥐고, token 하나가 자리 하나를 확보하므로 슬롯 상한의 절반을
/// 넘을 수 없다 — 표 크기를 슬롯 상한으로 두면 꽉 찰 일이 없다.
pub fn Table(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Entry = struct {
            token: u128,
            /// 주 연결의 owner 슬롯 번호와 그 연결의 단조 id. 번호는 재사용되므로 id 로 같은 연결인지 확인한다.
            index: usize,
            monotonic_id: u64,
            issued_ns: u64,
        };

        entries: [capacity]Entry = undefined,
        len: usize = 0,

        pub fn count(self: *const Self) usize {
            return self.len;
        }

        /// token 을 표에 넣는다. token 0·이미 있는 token·같은 주 연결의 두 번째 token·표가 꽉 찬 경우는 넣지 않는다.
        pub fn issue(self: *Self, token: u128, index: usize, monotonic_id: u64, now_ns: u64) bool {
            if (token == 0 or monotonic_id == 0 or self.len == capacity) return false;
            for (self.entries[0..self.len]) |entry|
                if (entry.token == token or entry.monotonic_id == monotonic_id) return false;
            self.entries[self.len] = .{ .token = token, .index = index, .monotonic_id = monotonic_id, .issued_ns = now_ns };
            self.len += 1;
            return true;
        }

        /// 입양 때 처음 쓰이는 token 을 표에서 꺼낸다. 두 번째 사용은 null — token 은 한 번만 쓰인다.
        pub fn take(self: *Self, token: u128) ?Entry {
            for (self.entries[0..self.len], 0..) |entry, i| {
                if (entry.token != token) continue;
                self.removeAt(i);
                return entry;
            }
            return null;
        }

        /// 주 연결이 끝났거나(`destroyAll` 포함) 앱이 abandon 했을 때 그 연결의 token 을 버린다. 버린 개수를 돌려준다.
        pub fn dropFor(self: *Self, monotonic_id: u64) usize {
            var dropped: usize = 0;
            var i: usize = 0;
            while (i < self.len) {
                if (self.entries[i].monotonic_id == monotonic_id) {
                    self.removeAt(i);
                    dropped += 1;
                } else i += 1;
            }
            return dropped;
        }

        /// `token_ttl_ns` 를 넘긴 token 을 버린다. 버린 개수를 돌려준다.
        pub fn expire(self: *Self, now_ns: u64) usize {
            var dropped: usize = 0;
            var i: usize = 0;
            while (i < self.len) {
                if (now_ns -| self.entries[i].issued_ns >= token_ttl_ns) {
                    self.removeAt(i);
                    dropped += 1;
                } else i += 1;
            }
            return dropped;
        }

        fn removeAt(self: *Self, i: usize) void {
            self.entries[i] = self.entries[self.len - 1];
            self.len -= 1;
        }
    };
}

/// 이미지 채널이 아닌 hello 를 받아도 되는가. `others_handshaken` 은 hello 를 보낸 연결 자신을 뺀 수다. 자신까지 넣어
/// 슬롯 상한을 넘으면 미사용 token 이 확보한 자리를 이 연결이 먹는다.
pub fn helloAdmits(others_handshaken: usize, unused_tokens: usize, slot_cap: usize) bool {
    return others_handshaken + unused_tokens + 1 <= slot_cap;
}

/// 이 hello 에 token 을 발급해도 되는가 — 자신과, 앞으로 올 채널 연결의 자리가 함께 남아야 한다.
pub fn tokenIssuable(others_handshaken: usize, unused_tokens: usize, slot_cap: usize) bool {
    return others_handshaken + unused_tokens + 2 <= slot_cap;
}

const testing = std.testing;

test "image channel tokens: token 은 한 번만 쓰이고 주 연결마다 하나다" {
    var table: Table(4) = .{};
    try testing.expect(table.issue(11, 0, 100, 0));
    try testing.expect(!table.issue(11, 1, 101, 0)); // 같은 token
    try testing.expect(!table.issue(12, 0, 100, 0)); // 같은 주 연결
    try testing.expect(!table.issue(0, 1, 101, 0)); // 0 은 token 이 아니다
    try testing.expect(!table.issue(13, 1, 0, 0)); // id 0 은 연결이 아니다
    try testing.expectEqual(@as(usize, 1), table.count());

    const entry = table.take(11) orelse return error.TestUnexpectedResult;
    try testing.expectEqual(@as(usize, 0), entry.index);
    try testing.expectEqual(@as(u64, 100), entry.monotonic_id);
    try testing.expectEqual(@as(?Table(4).Entry, null), table.take(11));
    try testing.expectEqual(@as(usize, 0), table.count());

    // 표가 꽉 차면 더 넣지 않는다.
    for (0..4) |i| try testing.expect(table.issue(20 + i, i, 200 + i, 0));
    try testing.expect(!table.issue(99, 9, 999, 0));
}

test "image channel tokens: 주 연결 종료와 만료가 확보를 푼다" {
    var table: Table(4) = .{};
    try testing.expect(table.issue(1, 0, 100, 0));
    try testing.expect(table.issue(2, 1, 101, 5 * std.time.ns_per_s));
    try testing.expectEqual(@as(usize, 1), table.dropFor(100));
    try testing.expectEqual(@as(usize, 0), table.dropFor(100));
    try testing.expectEqual(@as(?Table(4).Entry, null), table.take(1));

    // 만료는 발급 시각 기준이다 — 경계 바로 앞은 남고 경계에서 버린다.
    try testing.expectEqual(@as(usize, 0), table.expire(5 * std.time.ns_per_s + token_ttl_ns - 1));
    try testing.expectEqual(@as(usize, 1), table.expire(5 * std.time.ns_per_s + token_ttl_ns));
    try testing.expectEqual(@as(usize, 0), table.count());
}

test "image channel tokens: 슬롯 경계에서 token 이 안 나가고 남은 자리를 다른 hello 가 못 먹는다" {
    const cap: usize = 32;
    // 다른 연결 30 + 자신 = 31, 채널 자리까지 32 — 발급할 수 있다.
    try testing.expect(tokenIssuable(30, 0, cap));
    // 다른 연결 31 이면 채널 자리가 없다 — 발급하지 않는다.
    try testing.expect(!tokenIssuable(31, 0, cap));
    // 미사용 token 도 자리를 센다.
    try testing.expect(!tokenIssuable(29, 2, cap));
    try testing.expect(tokenIssuable(28, 2, cap));

    // token 하나가 자리 하나를 쥔 채 30 개가 붙어 있으면, 새 hello 하나는 받을 수 있지만(31 + token 1 = 32)
    try testing.expect(helloAdmits(30, 1, cap));
    // 31 개가 붙어 있으면 그 hello 가 token 의 자리를 먹으므로 받지 않는다.
    try testing.expect(!helloAdmits(31, 1, cap));
    // token 이 없으면 마지막 자리까지 받는다.
    try testing.expect(helloAdmits(31, 0, cap));
    try testing.expect(!helloAdmits(32, 0, cap));
}
