//! 네트워크 기록의 문·표(W9d① — docs/plans/web-osr-backend.md 「W9d① 결정」). CEF 를 모른다 — 시각·번호는 호출자가 준다(그래서 CEF SDK
//! 없이 기본 test 에서 시험이 돈다). 잠금도 없다 — `network.zig` 가 뮤텍스 하나 아래에서만 부른다(IO 스레드와 UI 스레드가 함께 쓴다).
//!
//! 왜 문이 먼저인가: CEF 의 자원 요청 처리기는 브라우저 프로세스의 IO 스레드 하나에서 요청마다 불린다(실측 — UI 스레드가 아니다). 페이지는
//! 초에 수천 요청을 만들 수 있고(실측 5–6 k/s), 요청마다 주소·헤더를 글로 바꾸면 그 스레드가 다른 탭의 요청까지 늦춘다(+17 % CPU, 동기 쓰기는
//! −27 % 처리량). 그래서 **글로 바꾸기 전에** 탭마다(100/s·버스트 500)·전체(2000/s)의 양동이와 동시에 쥔 요청 수(512)를 보고, 넘치면
//! 그 요청은 적지 않고 수만 센다(`dropped` — UI 스레드가 `net_dropped` 로 보낸다). 넘긴 바이트(IO → UI 상자)도 상한이 있다.
//!
//! 시험이 증명하는 것: 양동이(버스트·채움·탭이 다른 탭을 굶기지 않음·전체가 거절하면 탭 몫을 되돌림), 동시 요청 상한(전체 512·탭마다 128 —
//! 끝나지 않는 요청을 쥔 탭 하나가 다른 탭을 굶기지 않는다), 서비스 워커 길의 문(글로 바꾸기 전), 지켜보는 표(브라우저 번호·켬·서비스 워커
//! 출처 맞추기), 요청 표(같은 번호를 다시 쓰지 않음·꽉 차면 거절), 넘김 상자의 상한.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const BrowserId = protocol.message.BrowserId;

/// 탭 하나·전체의 초당 요청 수와 버스트(계획 결정 — W9d-0 M6 실측: 이 문을 두면 쏟아지는 탭이 CPU 를 기준선으로 되돌렸다).
pub const tab_rate: f64 = 100;
pub const tab_burst: f64 = 500;
pub const global_rate: f64 = 2000;
pub const global_burst: f64 = 2000;
/// 동시에 쥐는(시작했고 끝나지 않은) 요청 수 상한.
pub const max_in_flight: usize = 512;
/// 탭 하나가 쥘 수 있는 몫(W9d① 적대 리뷰 1 회차 F9 — 끝나지 않는 요청을 쏟는 탭 하나가 512 를 다 쥐면 다른 지켜보는 탭과 서비스 워커
/// 요청이 아무것도 적히지 않았다). 넷이 모여야 전체가 찬다.
pub const max_in_flight_per_tab: usize = 128;
/// IO → UI 넘김 상자의 상한 — 개수와 바이트. 넘치면 그 기록은 버리고 수를 센다.
pub const max_queue_events: usize = 4096;
pub const max_queue_bytes: usize = 8 * 1024 * 1024;
/// 지켜보는 표의 자리 — sidecar 의 브라우저 상한과 같다.
pub const capacity = @import("registry.zig").capacity;
/// 서비스 워커 요청 하나를 붙이는 탭 수 상한(그 출처를 연 지켜보는 탭들).
pub const max_targets: usize = 8;
/// 출처·호스트 글 상한.
pub const max_origin_bytes = protocol.message.max_net_origin_bytes;

const Bucket = struct {
    tokens: f64,
    at_us: i64 = 0,

    fn take(self: *Bucket, rate: f64, burst: f64, now_us: i64) bool {
        if (self.at_us == 0) self.at_us = now_us;
        if (now_us > self.at_us) {
            self.tokens = @min(burst, self.tokens + @as(f64, @floatFromInt(now_us - self.at_us)) / 1e6 * rate);
            self.at_us = now_us;
        }
        if (self.tokens < 1) return false;
        self.tokens -= 1;
        return true;
    }

    fn refund(self: *Bucket, burst: f64) void {
        self.tokens = @min(burst, self.tokens + 1);
    }
};

/// 지켜보는 탭 하나(UI 스레드가 쓰고 IO 스레드가 읽는다 — 뮤텍스 아래).
pub const Watch = struct {
    browser: BrowserId = 0,
    cef_id: c_int = 0,
    on: bool = false,
    full: bool = true,
    host_count: u8 = 0,
    hosts: [protocol.message.max_net_watch_hosts][253]u8 = undefined,
    host_lens: [protocol.message.max_net_watch_hosts]u8 = @splat(0),
    /// 주 프레임 문서의 출처(`scheme://host[:port]`) — 서비스 워커 요청을 붙일 탭을 고른다(UI 스레드의 주소 바뀜에서).
    top_origin: [max_origin_bytes]u8 = undefined,
    top_len: usize = 0,
    bucket: Bucket = .{ .tokens = tab_burst },
    /// 이 탭 몫으로 쥔 요청 수(`max_in_flight_per_tab`).
    in_flight: u16 = 0,
    /// 문에서 넘긴 수(UI 스레드가 `net_dropped` 로 보내고 비운다).
    dropped: u32 = 0,

    pub fn host(self: *const Watch, i: usize) []const u8 {
        return self.hosts[i][0..self.host_lens[i]];
    }

    pub fn topOrigin(self: *const Watch) []const u8 {
        return self.top_origin[0..self.top_len];
    }
};

/// 시작한 요청 하나(번호 — 리다이렉트·인증 재시도에도 같다).
pub const Track = struct {
    request: u64 = 0,
    /// 이 요청을 몫으로 센 탭(문을 지날 때의 탭 — 서비스 워커 요청은 첫 대상). 끝나면 그 탭의 몫을 돌려준다.
    owner: BrowserId = 0,
    targets: [max_targets]BrowserId = @splat(0),
    target_count: u8 = 0,
    service_worker: bool = false,
    /// `net_begin` 을 보냈다(`on_before_resource_load` — 그 전에 끝나면 아무것도 보내지 않는다).
    begun: bool = false,
    /// 문을 지날 때 받은 것(IO 스레드의 `get_resource_request_handler` 에만 있다) — begin 에 싣는다.
    initiator: [max_origin_bytes]u8 = undefined,
    initiator_len: usize = 0,
    navigation: bool = false,

    pub fn initiatorSlice(self: *const Track) []const u8 {
        return self.initiator[0..self.initiator_len];
    }

    pub fn targetSlice(self: *const Track) []const BrowserId {
        return self.targets[0..self.target_count];
    }
};

pub const State = struct {
    watches: [capacity]Watch = @splat(.{}),
    /// 켜진 지켜보기 수 — 0 이면 처리기가 아무것도 보지 않고 곧 null 을 돌려준다(가장 흔한 길).
    watching: usize = 0,
    global: Bucket = .{ .tokens = global_burst },
    /// 서비스 워커 길의 문 — 붙일 탭을 고르려면 initiator 를 글로 바꿔야 해서, 그 **앞에** 이 양동이를 본다(되돌리지 않는다).
    sw_path: Bucket = .{ .tokens = global_burst },
    tracks: [max_in_flight]Track = @splat(.{}),
    in_flight: usize = 0,
    queue_events: usize = 0,
    queue_bytes: usize = 0,

    // ── 지켜보는 표(UI 스레드) ───────────────────────────────────────────────────────────────────────────

    pub fn watchOf(self: *State, browser: BrowserId) ?*Watch {
        for (&self.watches) |*w| if (w.browser == browser and w.on) return w;
        return null;
    }

    pub fn watchByCef(self: *State, cef_id: c_int) ?*Watch {
        if (self.watching == 0) return null;
        for (&self.watches) |*w| if (w.on and w.cef_id == cef_id) return w;
        return null;
    }

    /// `net_watch` 를 적용한다. 켬이면 자리를 잡거나(새 브라우저) 고치고, 끔이면 자리를 비운다. 자리가 없으면 거짓.
    pub fn setWatch(self: *State, browser: BrowserId, cef_id: c_int, on: bool, full: bool, hosts: []const []const u8) bool {
        var slot: ?*Watch = null;
        for (&self.watches) |*w| if (w.browser == browser and w.on) {
            slot = w;
            break;
        };
        if (!on) {
            if (slot) |w| {
                w.* = .{};
                self.watching -= 1;
            }
            return true;
        }
        if (slot == null) {
            for (&self.watches) |*w| if (!w.on) {
                w.* = .{ .browser = browser, .cef_id = cef_id, .on = true };
                self.watching += 1;
                slot = w;
                break;
            };
        }
        const w = slot orelse return false;
        w.cef_id = cef_id;
        w.full = full;
        w.host_count = 0;
        for (hosts) |h| {
            if (w.host_count == w.hosts.len or h.len > 253) continue;
            @memcpy(w.hosts[w.host_count][0..h.len], h);
            w.host_lens[w.host_count] = @intCast(h.len);
            w.host_count += 1;
        }
        return true;
    }

    /// 브라우저가 닫혔다 — 지켜보기도 끝난다.
    pub fn forget(self: *State, browser: BrowserId) void {
        _ = self.setWatch(browser, 0, false, false, &.{});
    }

    /// 그 탭의 주 프레임 문서 출처(주소가 바뀔 때).
    pub fn setTopOrigin(self: *State, browser: BrowserId, origin: []const u8) void {
        const w = self.watchOf(browser) orelse return;
        const n = @min(origin.len, w.top_origin.len);
        @memcpy(w.top_origin[0..n], origin[0..n]);
        w.top_len = n;
    }

    /// 서비스 워커 요청의 출처를 연 지켜보는 탭들(넘치면 앞의 `max_targets` 개). 없으면 0.
    pub fn serviceWorkerTargets(self: *State, initiator: []const u8, out: *[max_targets]BrowserId) usize {
        var n: usize = 0;
        if (initiator.len == 0) return 0;
        for (&self.watches) |*w| {
            if (!w.on or n == out.len) continue;
            if (std.ascii.eqlIgnoreCase(w.topOrigin(), initiator)) {
                out[n] = w.browser;
                n += 1;
            }
        }
        return n;
    }

    /// 지켜보는 탭 중 그 출처를 연 것이 있는가 — 서비스 워커 요청을 값싸게 거른다(없으면 글로 바꾸지도 않는다 — 부른 쪽이 출처만 바꿨다).
    pub fn anyTopOrigin(self: *State, initiator: []const u8) bool {
        var out: [max_targets]BrowserId = undefined;
        return self.serviceWorkerTargets(initiator, &out) != 0;
    }

    // ── 문(IO 스레드) ───────────────────────────────────────────────────────────────────────────────────────

    /// 새 요청을 받을 수 있는가 — 동시 요청 수(전체·이 탭의 몫), 탭 양동이, 그다음 전체 양동이. 넘치면 그 탭의 넘긴 수를 센다.
    pub fn admit(self: *State, w: *Watch, now_us: i64) bool {
        if (self.in_flight >= max_in_flight or w.in_flight >= max_in_flight_per_tab) {
            w.dropped +|= 1;
            return false;
        }
        if (!w.bucket.take(tab_rate, tab_burst, now_us)) {
            w.dropped +|= 1;
            return false;
        }
        if (!self.global.take(global_rate, global_burst, now_us)) {
            w.bucket.refund(tab_burst); // 전체가 거절했다 — 탭의 몫은 쓰지 않은 것이다
            w.dropped +|= 1;
            return false;
        }
        return true;
    }

    /// 서비스 워커 길의 문(IO 스레드) — initiator 를 글로 바꾸기 **전에** 본다(적대 리뷰 1 회차 곁가지: 바꾼 뒤에 문을 봤다). 동시 요청이
    /// 다 찼거나 이 길의 양동이가 비면 거짓 — 붙일 탭을 아직 모르니 넘긴 수는 세지 않는다.
    pub fn admitServiceWorkerPath(self: *State, now_us: i64) bool {
        if (self.in_flight >= max_in_flight) return false;
        return self.sw_path.take(global_rate, global_burst, now_us);
    }

    /// 요청 표에 자리를 잡는다(이미 있으면 그것 — 리다이렉트의 다음 홉은 문을 다시 지나지 않는다). `owner` 의 몫으로 센다. 꽉 찼으면 null.
    pub fn track(self: *State, request: u64, owner: *Watch) ?*Track {
        if (self.find(request)) |t| return t;
        if (self.in_flight >= max_in_flight or owner.in_flight >= max_in_flight_per_tab) return null;
        for (&self.tracks) |*t| if (t.request == 0) {
            t.* = .{ .request = request, .owner = owner.browser };
            self.in_flight += 1;
            owner.in_flight += 1;
            return t;
        };
        return null;
    }

    pub fn find(self: *State, request: u64) ?*Track {
        if (request == 0 or self.in_flight == 0) return null;
        for (&self.tracks) |*t| if (t.request == request) return t;
        return null;
    }

    /// 요청이 끝났다 — 자리를 비우고 그 탭의 몫을 돌려준다(그사이 지켜보기가 꺼졌다 다시 켜졌으면 0 아래로 가지 않는다).
    pub fn untrack(self: *State, t: *Track) void {
        if (t.request == 0) return;
        if (self.watchOf(t.owner)) |w| w.in_flight -|= 1;
        t.* = .{};
        self.in_flight -= 1;
    }

    /// 넘김 상자에 `bytes` 를 넣을 수 있는가 — 넣으면 센다.
    pub fn reserveQueue(self: *State, bytes: usize) bool {
        if (self.queue_events >= max_queue_events or self.queue_bytes + bytes > max_queue_bytes) return false;
        self.queue_events += 1;
        self.queue_bytes += bytes;
        return true;
    }

    pub fn releaseQueue(self: *State, bytes: usize) void {
        self.queue_events -|= 1;
        self.queue_bytes -|= bytes;
    }
};

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "W9d①: 탭 양동이 — 버스트 500 뒤로는 초당 100, 넘긴 수를 센다, 다른 탭은 제 몫이 있다" {
    var s: State = .{};
    try testing.expect(s.setWatch(1, 11, true, true, &.{"a.test"}));
    try testing.expect(s.setWatch(2, 12, true, true, &.{}));
    const w1 = s.watchByCef(11).?;
    const w2 = s.watchByCef(12).?;
    var ok: usize = 0;
    for (0..600) |_| {
        if (s.admit(w1, 1_000_000)) ok += 1;
    }
    try testing.expectEqual(@as(usize, 500), ok);
    try testing.expectEqual(@as(u32, 100), w1.dropped);
    try testing.expect(s.admit(w2, 1_000_000)); // 다른 탭은 굶지 않는다
    // 1 초 뒤 100 개가 다시 찬다.
    ok = 0;
    for (0..200) |_| {
        if (s.admit(w1, 2_000_000)) ok += 1;
    }
    try testing.expectEqual(@as(usize, 100), ok);
}

test "W9d①: 전체 양동이 2000 — 넘으면 탭의 몫은 되돌리고 넘긴 수를 센다, 동시 요청 512 를 넘으면 문이 닫힌다" {
    var s: State = .{};
    for (0..5) |i| try testing.expect(s.setWatch(@intCast(i + 1), @intCast(i + 10), true, true, &.{}));
    var ok: usize = 0;
    for (0..5) |i| {
        const w = s.watchByCef(@intCast(i + 10)).?;
        for (0..500) |_| {
            if (s.admit(w, 5_000_000)) ok += 1;
        }
    }
    try testing.expectEqual(@as(usize, 2000), ok);
    const last = s.watchByCef(14).?;
    try testing.expectEqual(@as(u32, 500), last.dropped);
    try testing.expect(last.bucket.tokens >= 499); // 전체가 거절한 몫은 탭에 되돌렸다
    // 동시 요청.
    var t: State = .{};
    try testing.expect(t.setWatch(1, 11, true, true, &.{}));
    // 탭 넷이 몫(128)씩 쥐면 전체(512)가 찬다.
    for (0..4) |i| try testing.expect(t.setWatch(@intCast(i + 1), @intCast(i + 11), true, true, &.{}));
    for (1..max_in_flight + 1) |r| try testing.expect(t.track(r, t.watchByCef(@intCast(11 + (r - 1) / max_in_flight_per_tab)).?) != null);
    const w1 = t.watchByCef(11).?;
    try testing.expect(t.track(max_in_flight + 5, w1) == null);
    try testing.expect(!t.admit(w1, 1));
    try testing.expect(t.track(3, w1) != null); // 이미 있는 번호는 그 자리(리다이렉트의 다음 홉)
    t.untrack(t.find(3).?);
    try testing.expect(t.track(max_in_flight + 5, w1) != null);
    try testing.expect(t.find(3) == null);
}

test "W9d①: 지켜보는 표 — 끄면 비우고(처리기는 곧 null), 켬은 호스트를 고치고, 서비스 워커 요청은 그 출처를 연 탭들에 붙는다" {
    var s: State = .{};
    try testing.expect(s.watchByCef(11) == null);
    try testing.expect(s.setWatch(1, 11, true, false, &.{ "a.test", "b.test" }));
    try testing.expect(s.setWatch(1, 11, true, true, &.{"c.test"}));
    try testing.expectEqual(@as(usize, 1), s.watching);
    const w = s.watchByCef(11).?;
    try testing.expect(w.full and w.host_count == 1);
    try testing.expectEqualStrings("c.test", w.host(0));
    try testing.expect(s.setWatch(2, 12, true, true, &.{}));
    try testing.expect(s.setWatch(3, 13, true, true, &.{}));
    s.setTopOrigin(1, "https://app.test");
    s.setTopOrigin(2, "https://APP.test");
    s.setTopOrigin(3, "https://other.test");
    s.setTopOrigin(9, "https://app.test"); // 지켜보지 않는 탭 — 무시
    var out: [max_targets]BrowserId = undefined;
    try testing.expectEqual(@as(usize, 2), s.serviceWorkerTargets("https://app.test", &out));
    try testing.expect(out[0] == 1 and out[1] == 2);
    try testing.expect(!s.anyTopOrigin("https://nobody.test"));
    s.forget(1);
    try testing.expect(s.watchByCef(11) == null);
    try testing.expectEqual(@as(usize, 2), s.watching);
    try testing.expect(s.setWatch(1, 0, false, false, &.{})); // 이미 꺼진 것을 끄기
    // 자리가 다 차면 켜지 못한다.
    var full: State = .{};
    for (0..capacity) |i| try testing.expect(full.setWatch(@intCast(i + 1), @intCast(i), true, true, &.{}));
    try testing.expect(!full.setWatch(999, 999, true, true, &.{}));
}

test "W9d①: 넘김 상자 — 개수·바이트 상한, 꺼낸 만큼 돌려준다" {
    var s: State = .{};
    try testing.expect(s.reserveQueue(max_queue_bytes));
    try testing.expect(!s.reserveQueue(1));
    s.releaseQueue(max_queue_bytes);
    for (0..max_queue_events) |_| try testing.expect(s.reserveQueue(1));
    try testing.expect(!s.reserveQueue(1));
    s.releaseQueue(1);
    try testing.expect(s.reserveQueue(1));
}

// ── W9d① 적대 리뷰 1 회차 재현(리뷰가 남긴 R9d1-G1 — 붙여 실패를 본 뒤 고쳤다) ──

test "W9d① 적대 리뷰 1 회차 재현 G1: 한 탭이 끝나지 않는 요청을 쏟아도 그 탭은 128 까지만 쥔다 — 다른 지켜보는 탭과 서비스 워커 요청은 계속 적힌다" {
    var s: State = .{};
    try testing.expect(s.setWatch(1, 11, true, true, &.{}));
    try testing.expect(s.setWatch(2, 12, true, true, &.{}));
    const hostile = s.watchByCef(11).?;
    // 적대 페이지가 끝나지 않는 요청을 연다(예: CEF 154 가 끝내지 않는 401 + WWW-Authenticate 하위 자원, 답하지 않는 서버). 채움 시간이 있어
    // 몇 초에 걸쳐 문을 지난다 — 그 탭의 몫에서 멈춘다.
    var now: i64 = 1_000_000;
    var r: u64 = 1;
    for (0..10_000) |_| {
        if (s.admit(hostile, now)) {
            _ = s.track(r, hostile).?;
            r += 1;
        }
        now += 10_000;
    }
    try testing.expectEqual(max_in_flight_per_tab, s.in_flight);
    try testing.expectEqual(@as(u16, max_in_flight_per_tab), hostile.in_flight);
    const victim = s.watchByCef(12).?;
    try testing.expect(s.admit(victim, now + 60 * 1_000_000)); // 1 분 뒤 다른 탭의 첫 요청
    _ = s.track(r, victim).?;
    try testing.expect(s.admitServiceWorkerPath(now + 60 * 1_000_000)); // 서비스 워커 길도 열려 있다
    // 끝나면 그 탭의 몫이 돌아온다 — 지켜보기를 껐다 켠 뒤에 끝난 옛 요청은 0 아래로 내리지 않는다.
    s.untrack(s.find(1).?);
    try testing.expectEqual(@as(u16, max_in_flight_per_tab - 1), hostile.in_flight);
    try testing.expect(s.setWatch(1, 11, false, false, &.{}));
    try testing.expect(s.setWatch(1, 11, true, true, &.{}));
    const again = s.watchByCef(11).?;
    s.untrack(s.find(2).?);
    try testing.expectEqual(@as(u16, 0), again.in_flight);
}

test "W9d① 적대 리뷰 1 회차 곁가지: 서비스 워커 길의 문은 initiator 를 글로 바꾸기 전에 — 버스트 뒤로는 초당 2000, 동시 요청이 차면 닫힌다" {
    var s: State = .{};
    var ok: usize = 0;
    for (0..2500) |_| {
        if (s.admitServiceWorkerPath(1_000_000)) ok += 1;
    }
    try testing.expectEqual(@as(usize, @intFromFloat(global_burst)), ok);
    try testing.expect(s.admitServiceWorkerPath(1_001_000)); // 1 ms 뒤 두 개가 찬다
    s.in_flight = max_in_flight;
    try testing.expect(!s.admitServiceWorkerPath(5_000_000));
}
