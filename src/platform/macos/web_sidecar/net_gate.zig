//! 네트워크 기록의 문·표(W9d① — docs/plans/web-osr-backend.md 「W9d① 결정」). CEF 를 모른다 — 시각·번호는 호출자가 준다(그래서 CEF SDK
//! 없이 기본 test 에서 시험이 돈다). 잠금도 없다 — `network.zig` 가 뮤텍스 하나 아래에서만 부른다(IO 스레드와 UI 스레드가 함께 쓴다).
//!
//! 왜 문이 먼저인가: CEF 의 자원 요청 처리기는 브라우저 프로세스의 IO 스레드 하나에서 요청마다 불린다(실측 — UI 스레드가 아니다). 페이지는
//! 초에 수천 요청을 만들 수 있고(실측 5–6 k/s), 요청마다 주소·헤더를 글로 바꾸면 그 스레드가 다른 탭의 요청까지 늦춘다(+17 % CPU, 동기 쓰기는
//! −27 % 처리량). 그래서 **글로 바꾸기 전에** 탭마다(100/s·버스트 500)·전체(2000/s)의 양동이와 동시에 쥔 요청 수(512)를 보고, 넘치면
//! 그 요청은 적지 않고 수만 센다(`dropped` — UI 스레드가 `net_dropped` 로 보낸다). 넘긴 바이트(IO → UI 상자)도 상한이 있다.
//!
//! 시험이 증명하는 것: 양동이(버스트·채움·탭이 다른 탭을 굶기지 않음·전체가 거절하면 탭 몫을 되돌림), 동시 요청 상한(전체 512·탭마다 128 —
//! 끝나지 않는 요청을 쥔 탭 하나가 다른 탭을 굶기지 않는다), 서비스 워커 길의 문(지켜보는 출처만 양동이를 쓰고, 그 거절은 붙일 탭들의
//! 넘긴 수로, 거절한 요청의 몫은 되돌린다), 지켜보는 표(브라우저 번호·켬·서비스 워커 출처 맞추기·켤 때마다 새 세대), 요청 표(같은 번호를
//! 다시 쓰지 않음·꽉 차면 거절·껐다 켠 뒤 끝나는 옛 요청은 새 몫을 건드리지 않음), 넘김 상자의 상한, 덮기(어느 호스트든과 묶인 호스트의
//! 합 — 빈 목록은 아무것도 덮지 않는다)와 덜어 내기의 결정(적을 때의 것과 보낼 때의 것 중 더 덜어 내는 쪽 — W9d① 적대 리뷰 3 회차).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");

const BrowserId = protocol.message.BrowserId;
const net_policy = protocol.net_policy;

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
    /// 어느 호스트든 grant 가 있다(`net_watch.any_host` — 에이전트 탭: 요청의 첫 사이트로 덮는다). 묶인 `hosts` 와 합친다(W9d① 적대 리뷰 3 회차
    /// P1a — 전에는 둘을 함께 말할 수 없어 다른 pane 의 묶인 grant 가 있으면 에이전트 제 사이트의 값까지 덜어 냈다).
    any_host: bool = false,
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
    /// 켤 때마다 새 값(W9d① 적대 리뷰 2 회차 N4) — 요청이 이 값을 쥐고, 껐다 켠 뒤 끝나는 옛 요청은 새 지켜보기의 몫을 돌려받지 않는다.
    generation: u32 = 0,

    pub fn host(self: *const Watch, i: usize) []const u8 {
        return self.hosts[i][0..self.host_lens[i]];
    }

    pub fn topOrigin(self: *const Watch) []const u8 {
        return self.top_origin[0..self.top_len];
    }

    /// 그 요청(호스트 `host` — sidecar 가 온 주소에서 읽었다, 첫 사이트 `site`)의 값을 덜지 않고 보내도 되는 호스트인가(설정이 꺼졌을 때). 어느
    /// 호스트든 grant 면 첫 사이트와 같은 사이트, 묶인 호스트면 그 호스트와 하위 도메인 — 둘 중 하나면 덮인다. 둘 다 없으면(빈 목록·어느
    /// 호스트든 아님) 아무것도 덮지 않는다(W9d① 적대 리뷰 3 회차 — 전에는 빈 목록이 「어느 사이트든」 이라 빈 사이트로 좁힌 grant 에 `invalid`
    /// 를 실었다). 빈 호스트(모른다)는 덮이지 않는다.
    pub fn covers(self: *const Watch, req_host: []const u8, site: []const u8) bool {
        if (req_host.len == 0) return false;
        if (self.any_host and site.len != 0 and net_policy.sameSite(site, req_host)) return true;
        for (0..self.host_count) |i| if (net_policy.hostCovers(self.host(i), req_host)) return true;
        return false;
    }

    /// 보낼 때 이 탭에 덜어 낼 것(W9d① 적대 리뷰 3 회차 P1c) — 적을 때 찍어 둔 결정(`full_then`·`covered_then`)과 지금의 지켜보기 중 더 덜어
    /// 내는 쪽. 꺼진 동안 적었다가 켠 뒤 보내는 기록은 덜어 낸 그대로다(전에는 보낼 때의 설정만 봐서 그대로 나갔다).
    pub fn decide(self: *const Watch, full_then: bool, covered_then: bool, req_host: []const u8, site: []const u8) Decision {
        return .{ .full = full_then and self.full, .covered = covered_then and self.covers(req_host, site) };
    }
};

/// 보낼 때의 덜어 내기 — `full` 거짓이면 덜어 낸다(`covered` 는 덮이는 호스트의 허용 목록 값을 남길지).
pub const Decision = struct { full: bool, covered: bool };

/// 적을 때 붙일 탭마다 찍은 결정(비트 i = 대상 i — `max_targets` 가 8 이라 한 바이트).
pub const Stamp = struct { full: u8 = 0, covered: u8 = 0 };

comptime {
    std.debug.assert(max_targets <= 8);
}

/// 시작한 요청 하나(번호 — 리다이렉트·인증 재시도에도 같다).
pub const Track = struct {
    request: u64 = 0,
    /// 이 요청을 몫으로 센 탭(문을 지날 때의 탭 — 서비스 워커 요청은 첫 대상). 끝나면 그 탭의 몫을 돌려준다.
    owner: BrowserId = 0,
    /// 몫으로 셀 때 그 탭 지켜보기의 세대(`Watch.generation`) — 같을 때만 돌려준다.
    owner_generation: u32 = 0,
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

/// `State.admitServiceWorker` 의 답 — 그 출처를 연 지켜보는 탭 수와 문을 지났는가.
pub const ServiceWorkerAdmit = struct { targets: usize, admitted: bool };

/// `State.startServiceWorker` 의 답 — 붙일 탭 수와 잡은 자리(못 잡았으면 null).
pub const ServiceWorkerStart = struct { targets: usize, track: ?*Track };

pub const State = struct {
    watches: [capacity]Watch = @splat(.{}),
    /// 켜진 지켜보기 수 — 0 이면 처리기가 아무것도 보지 않고 곧 null 을 돌려준다(가장 흔한 길).
    watching: usize = 0,
    global: Bucket = .{ .tokens = global_burst },
    /// 서비스 워커 길의 문 — 지켜보는 출처의 요청만 이 양동이를 쓴다(적대 리뷰 2 회차 N5 — 출처를 맞추기 전에 쓰면 지켜보지 않는 출처의
    /// 서비스 워커가 쏟는 요청이 지켜보는 탭의 것을 세지도 않고 막았다). 출처는 앞부분만(상한 있는) 글로 바꿔 맞춘다.
    sw_path: Bucket = .{ .tokens = global_burst },
    /// 지켜보기를 켤 때마다 오른다(`Watch.generation`).
    next_generation: u32 = 0,
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
    pub fn setWatch(self: *State, browser: BrowserId, cef_id: c_int, on: bool, full: bool, any_host: bool, hosts: []const []const u8) bool {
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
                self.next_generation +%= 1;
                w.* = .{ .browser = browser, .cef_id = cef_id, .on = true, .generation = self.next_generation };
                self.watching += 1;
                slot = w;
                break;
            };
        }
        const w = slot orelse return false;
        w.cef_id = cef_id;
        w.full = full;
        w.any_host = any_host;
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
        _ = self.setWatch(browser, 0, false, false, false, &.{});
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

    /// 서비스 워커 길의 양동이와 동시 요청 수 — `admitServiceWorker` 가 출처를 맞춘 뒤에만 부른다.
    pub fn admitServiceWorkerPath(self: *State, now_us: i64) bool {
        if (self.in_flight >= max_in_flight) return false;
        return self.sw_path.take(global_rate, global_burst, now_us);
    }

    /// 서비스 워커 요청(브라우저가 없는 요청)의 문(IO 스레드) — `initiator` 는 앞부분만 바꾼 출처. 그 출처를 연 지켜보는 탭을 `out` 에 채우고
    /// (`targets`), 없으면 양동이를 쓰지 않는다(적대 리뷰 2 회차 N5). 있으면 이 길의 양동이·동시 요청 수, 그다음 첫 대상 탭의 문(`admit`)을
    /// 본다 — 거절하면 붙일 탭들 모두의 넘긴 수로 센다(`admitted` 거짓).
    pub fn admitServiceWorker(self: *State, initiator: []const u8, now_us: i64, out: *[max_targets]BrowserId) ServiceWorkerAdmit {
        const n = self.serviceWorkerTargets(initiator, out);
        if (n == 0) return .{ .targets = 0, .admitted = false };
        const first = self.watchOf(out[0]) orelse return .{ .targets = 0, .admitted = false };
        if (!self.admitServiceWorkerPath(now_us)) {
            self.countServiceWorkerDrop(out[0..n], null);
            return .{ .targets = n, .admitted = false };
        }
        if (!self.admit(first, now_us)) {
            self.sw_path.refund(global_burst); // 거절한 요청은 이 길의 몫을 쓰지 않았다(W9d① 적대 리뷰 3 회차 S1)
            self.countServiceWorkerDrop(out[0..n], first); // 첫 탭은 `admit` 이 셌다
            return .{ .targets = n, .admitted = false };
        }
        return .{ .targets = n, .admitted = true };
    }

    /// 탭의 요청 하나를 문에 넣고 요청 표에 잡는다(IO 스레드 — `admit` 다음 `track`). 표가 거절하면(같은 잠금 안이라 `admit` 이 지난 뒤에는 오지
    /// 않는 길이다 — 방어) 쓴 몫(탭·전체 양동이)을 되돌리고 넘긴 수를 센다(W9d① 적대 리뷰 3 회차 S1). 잡았으면 대상은 그 탭 하나.
    pub fn startTab(self: *State, w: *Watch, request: u64, now_us: i64) ?*Track {
        if (!self.admit(w, now_us)) return null;
        const t = self.track(request, w) orelse {
            w.bucket.refund(tab_burst);
            self.global.refund(global_burst);
            w.dropped +|= 1;
            return null;
        };
        t.targets[0] = w.browser;
        t.target_count = 1;
        return t;
    }

    /// 서비스 워커 요청(브라우저가 없는 요청)을 문에 넣고 요청 표에 잡는다 — `admitServiceWorker` 다음 첫 대상 탭의 몫으로 `track`. 표가
    /// 거절하면 쓴 몫(이 길·첫 탭·전체)을 모두 되돌리고 붙일 탭마다 넘긴 수를 센다(S1 — 전에는 첫 탭만 셌고 몫은 그대로 썼다).
    pub fn startServiceWorker(self: *State, initiator: []const u8, request: u64, now_us: i64, out: *[max_targets]BrowserId) ServiceWorkerStart {
        const a = self.admitServiceWorker(initiator, now_us, out);
        if (!a.admitted) return .{ .targets = a.targets, .track = null };
        const first = self.watchOf(out[0]).?; // `admitServiceWorker` 가 방금 찾았다(같은 잠금)
        const t = self.track(request, first) orelse {
            self.sw_path.refund(global_burst);
            first.bucket.refund(tab_burst);
            self.global.refund(global_burst);
            self.countServiceWorkerDrop(out[0..a.targets], null);
            return .{ .targets = a.targets, .track = null };
        };
        @memcpy(t.targets[0..a.targets], out[0..a.targets]);
        t.target_count = @intCast(a.targets);
        t.service_worker = true;
        return .{ .targets = a.targets, .track = t };
    }

    /// 적을 때 붙일 탭마다의 덜어 내기 결정을 찍는다(W9d① 적대 리뷰 3 회차 P1c — 꺼진 동안 적은 것은 켠 뒤 보내도 덜어 낸다). 그사이 지켜보기가
    /// 끝난 탭은 덜어 내는 쪽으로 찍는다(보낼 때 어차피 보내지 않는다).
    pub fn stamp(self: *State, targets: []const BrowserId, host: []const u8, site: []const u8) Stamp {
        var out: Stamp = .{};
        for (targets, 0..) |b, i| {
            const w = self.watchOf(b) orelse continue;
            const bit: u8 = @as(u8, 1) << @intCast(i);
            if (w.full) out.full |= bit;
            if (w.covers(host, site)) out.covered |= bit;
        }
        return out;
    }

    /// 넘긴 서비스 워커 요청을 붙일 탭마다 하나씩 센다(`admit` 이 이미 센 첫 탭은 빼고).
    fn countServiceWorkerDrop(self: *State, targets: []const BrowserId, counted: ?*Watch) void {
        for (targets) |b| {
            const w = self.watchOf(b) orelse continue;
            if (counted == w) continue;
            w.dropped +|= 1;
        }
    }

    /// 요청 표에 자리를 잡는다(이미 있으면 그것 — 리다이렉트의 다음 홉은 문을 다시 지나지 않는다). `owner` 의 몫으로 센다. 꽉 찼으면 null.
    pub fn track(self: *State, request: u64, owner: *Watch) ?*Track {
        if (self.find(request)) |t| return t;
        if (self.in_flight >= max_in_flight or owner.in_flight >= max_in_flight_per_tab) return null;
        for (&self.tracks) |*t| if (t.request == 0) {
            t.* = .{ .request = request, .owner = owner.browser, .owner_generation = owner.generation };
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

    /// 요청이 끝났다 — 자리를 비우고 그 탭의 몫을 돌려준다. 그사이 지켜보기가 꺼졌다 다시 켜졌으면(세대가 다르다) 새 몫은 건드리지 않는다
    /// (적대 리뷰 2 회차 N4 — 옛 요청이 끝나며 새 몫을 깎아 탭이 128 을 넘겨 쥐었다).
    pub fn untrack(self: *State, t: *Track) void {
        if (t.request == 0) return;
        if (self.watchOf(t.owner)) |w| if (w.generation == t.owner_generation) {
            w.in_flight -|= 1;
        };
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

// ── 떠난 문서의 iframe(W9d① 적대 리뷰 5 회차 B1) ─────────────────────────────────────────────────────────────

/// 브라우저 하나가 기억하는 iframe 수 — 넘으면 가장 먼저 적은 것부터 잊는다(잊힌 iframe 의 요청은 표시 없이 간다 — 떠난 문서의 비콘은
/// 새 문서가 iframe 을 64 개 열기 전, 떠나는 그 순간에 온다).
pub const max_doc_frames: usize = 64;

/// 하위 프레임마다 그 프레임이 문서를 연 때의 주 문서 세대(UI 스레드만 — `on_load_start`·보내는 task). 왜: 떠난 문서의 다른 사이트 iframe 이
/// `pagehide` 에 보낸 비콘·keepalive fetch 는 새 문서의 `page_started`·`url_changed` 뒤에 maru 에 온다(실측 — 판정
/// `R9d5-f2-old-iframe-beacon-after-nav`). 첫 사이트가 비어 오므로 maru 는 탭의 지금(새) 주소로 맨 위 문서를 정했고, 덮이지 않던 은행 페이지의
/// 추적 iframe 요청이 새 사이트에 묶인 읽는 쪽에게 보였다. IO 스레드의 프레임 주소는 비거나 낡아(M4) 번호로 가른다. 세대는 보낼 때 비교한다 —
/// 보낸 순서가 maru 가 받는 순서이므로, 새 문서의 `page_started` 뒤에 보내는 앞 문서 iframe 의 요청은 늘 표시가 선다(IO 스레드에서 비교하면
/// 그 요청을 받은 때와 `on_load_start` 의 앞뒤를 알 수 없다). 모르는 프레임(아직 문서를 열지 않은 새 iframe 의 문서 요청)은 표시하지 않는다.
/// 주 프레임은 가르지 않는다 — 같은 사이트 이동은 같은 프레임 번호를 다시 쓰고, 주 프레임 요청은 첫 사이트가 비어 오지 않는다.
pub const DocFrames = struct {
    /// 주 프레임의 지금 문서 세대 — 새 문서(`on_load_start`·오류 페이지)마다 올린다.
    generation: u32 = 0,
    ids: [max_doc_frames]u64 = @splat(0),
    gens: [max_doc_frames]u32 = @splat(0),
    len: usize = 0,
    /// 다음에 덮어쓸 자리(가득 차면 가장 먼저 적은 것).
    next: usize = 0,

    /// 주 프레임에 새 문서가 시작됐다.
    pub fn mainDocument(self: *DocFrames) void {
        self.generation +%= 1;
    }

    /// 하위 프레임 `frame`(프레임 번호의 해시 — 0 은 모른다)이 지금 세대에서 문서를 열었다.
    pub fn subframeDocument(self: *DocFrames, frame: u64) void {
        if (frame == 0) return;
        for (self.ids[0..self.len], 0..) |id, i| if (id == frame) {
            self.gens[i] = self.generation;
            return;
        };
        self.ids[self.next] = frame;
        self.gens[self.next] = self.generation;
        self.next = (self.next + 1) % max_doc_frames;
        if (self.len < max_doc_frames) self.len += 1;
    }

    /// 그 하위 프레임이 앞 문서의 것인가(모르면 거짓).
    pub fn previous(self: *const DocFrames, frame: u64) bool {
        if (frame == 0) return false;
        for (self.ids[0..self.len], 0..) |id, i| if (id == frame) return self.gens[i] != self.generation;
        return false;
    }
};

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "W9d①: 탭 양동이 — 버스트 500 뒤로는 초당 100, 넘긴 수를 센다, 다른 탭은 제 몫이 있다" {
    var s: State = .{};
    try testing.expect(s.setWatch(1, 11, true, true, false, &.{"a.test"}));
    try testing.expect(s.setWatch(2, 12, true, true, false, &.{}));
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
    for (0..5) |i| try testing.expect(s.setWatch(@intCast(i + 1), @intCast(i + 10), true, true, false, &.{}));
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
    try testing.expect(t.setWatch(1, 11, true, true, false, &.{}));
    // 탭 넷이 몫(128)씩 쥐면 전체(512)가 찬다.
    for (0..4) |i| try testing.expect(t.setWatch(@intCast(i + 1), @intCast(i + 11), true, true, false, &.{}));
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
    try testing.expect(s.setWatch(1, 11, true, false, false, &.{ "a.test", "b.test" }));
    try testing.expect(s.setWatch(1, 11, true, true, false, &.{"c.test"}));
    try testing.expectEqual(@as(usize, 1), s.watching);
    const w = s.watchByCef(11).?;
    try testing.expect(w.full and w.host_count == 1);
    try testing.expectEqualStrings("c.test", w.host(0));
    try testing.expect(s.setWatch(2, 12, true, true, false, &.{}));
    try testing.expect(s.setWatch(3, 13, true, true, false, &.{}));
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
    try testing.expect(s.setWatch(1, 0, false, false, false, &.{})); // 이미 꺼진 것을 끄기
    // 자리가 다 차면 켜지 못한다.
    var full: State = .{};
    for (0..capacity) |i| try testing.expect(full.setWatch(@intCast(i + 1), @intCast(i), true, true, false, &.{}));
    try testing.expect(!full.setWatch(999, 999, true, true, false, &.{}));
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
    try testing.expect(s.setWatch(1, 11, true, true, false, &.{}));
    try testing.expect(s.setWatch(2, 12, true, true, false, &.{}));
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
    try testing.expect(s.setWatch(1, 11, false, false, false, &.{}));
    try testing.expect(s.setWatch(1, 11, true, true, false, &.{}));
    const again = s.watchByCef(11).?;
    s.untrack(s.find(2).?);
    try testing.expectEqual(@as(u16, 0), again.in_flight);
}

test "W9d① 적대 리뷰 1 회차 곁가지: 서비스 워커 길의 양동이 — 버스트 뒤로는 초당 2000, 동시 요청이 차면 닫힌다(2 회차 N5 부터는 출처를 맞춘 뒤에만 본다)" {
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

// ── W9d① 적대 리뷰 2 회차 재현(리뷰가 남긴 R9d2-G1·G2 — 붙여 실패를 본 뒤 고쳤다. G2 는 출처를 받는 새 문으로 옮겼다) ──

test "W9d① 적대 리뷰 2 회차 재현 G1: 탭의 지켜보기를 껐다 켠 뒤 옛 요청이 끝나도 새 지켜보기의 몫을 깎지 않는다 — 탭은 128 을 넘겨 쥐지 못한다" {
    var s: State = .{};
    try testing.expect(s.setWatch(1, 11, true, true, false, &.{}));
    var r: u64 = 1;
    var now: i64 = 1_000_000;
    // 첫 지켜보기 아래 끝나지 않는 요청 128.
    while (s.watchByCef(11).?.in_flight < max_in_flight_per_tab) : (now += 10_000) {
        if (s.admit(s.watchByCef(11).?, now)) {
            _ = s.track(r, s.watchByCef(11).?).?;
            r += 1;
        }
    }
    const old_last = r - 1;
    // 사용자가 마지막 grant 를 철회하고 다시 허락한다(net_watch 끔 → 켬). 옛 요청은 아직 열려 있다.
    try testing.expect(s.setWatch(1, 11, false, false, false, &.{}));
    try testing.expect(s.setWatch(1, 11, true, true, false, &.{}));
    // 새 요청이 새 몫을 채운다.
    while (s.watchByCef(11).?.in_flight < max_in_flight_per_tab) : (now += 10_000) {
        if (s.admit(s.watchByCef(11).?, now)) {
            _ = s.track(r, s.watchByCef(11).?).?;
            r += 1;
        }
    }
    // 옛 요청이 늦게 끝난다 — 새 몫은 그대로다.
    var q: u64 = 1;
    while (q <= old_last) : (q += 1) s.untrack(s.find(q).?);
    const w = s.watchByCef(11).?;
    var held: usize = 0;
    for (s.tracks) |t| held += @intFromBool(t.request != 0 and t.owner == 1);
    try testing.expectEqual(held, @as(usize, w.in_flight));
    try testing.expectEqual(max_in_flight_per_tab, held);
    try testing.expect(!s.admit(w, now + 60 * 1_000_000)); // 그 탭은 여전히 꽉 찼다
    // 새 요청이 끝나면 새 몫이 돌아온다.
    s.untrack(s.find(old_last + 1).?);
    try testing.expectEqual(@as(u16, max_in_flight_per_tab - 1), w.in_flight);
}

test "W9d① 적대 리뷰 2 회차 재현 G2: 지켜보지 않는 출처의 서비스 워커가 쏟아도 이 길의 양동이를 쓰지 않는다 — 지켜보는 출처의 요청은 지나고, 지켜보는 출처의 거절은 붙일 탭마다 넘긴 수로" {
    var s: State = .{};
    try testing.expect(s.setWatch(1, 11, true, true, false, &.{}));
    try testing.expect(s.setWatch(2, 12, true, true, false, &.{}));
    s.setTopOrigin(1, "https://mail.test");
    s.setTopOrigin(2, "https://mail.test");
    var out: [max_targets]BrowserId = undefined;
    // grant 없는 다른 탭의 서비스 워커가 많이 보낸다 — 출처가 맞지 않으니 양동이를 쓰지 않고 세지도 않는다.
    for (0..2500) |_| {
        const a = s.admitServiceWorker("https://other.test", 1_000_000, &out);
        try testing.expect(a.targets == 0 and !a.admitted);
    }
    try testing.expectEqual(global_burst, s.sw_path.tokens);
    // 같은 밀리초의 지켜보는 출처 요청은 지난다(두 탭에 붙는다).
    const ok = s.admitServiceWorker("https://mail.test", 1_000_000, &out);
    try testing.expect(ok.admitted and ok.targets == 2);
    // 지켜보는 출처가 이 길의 양동이를 비우면 거절은 두 탭 모두의 넘긴 수다.
    s.sw_path.tokens = 0;
    const refused = s.admitServiceWorker("https://mail.test", 1_000_000, &out);
    try testing.expect(!refused.admitted and refused.targets == 2);
    try testing.expectEqual(@as(u32, 1), s.watchByCef(11).?.dropped);
    try testing.expectEqual(@as(u32, 1), s.watchByCef(12).?.dropped);
    // 첫 대상 탭의 양동이가 거절해도 두 탭 모두 하나씩(첫 탭은 `admit` 이 센 것 하나).
    s.sw_path.tokens = global_burst;
    s.watchByCef(11).?.bucket.tokens = 0;
    const refused2 = s.admitServiceWorker("https://mail.test", 1_000_000, &out);
    try testing.expect(!refused2.admitted);
    try testing.expectEqual(@as(u32, 2), s.watchByCef(11).?.dropped);
    try testing.expectEqual(@as(u32, 2), s.watchByCef(12).?.dropped);
}

// ── W9d① 적대 리뷰 3 회차 ──

test "W9d① 적대 리뷰 3 회차: 덮기 — 빈 목록은 아무것도 덮지 않고, 어느 호스트든(첫 사이트로)과 묶인 호스트는 합치며(P1a), 넷을 넘는 호스트는 싣지 않아 덮지 않는다(넓히지 않는다)" {
    var s: State = .{};
    // 빈 사이트로 좁힌 grant(about:blank 에서 몰았다) — 묶였는데 호스트가 없다: 어떤 요청의 값도 덜지 않고 보내지 않는다.
    try testing.expect(s.setWatch(1, 11, true, false, false, &.{}));
    const none = s.watchByCef(11).?;
    for ([_][2][]const u8{ .{ "a.test", "a.test" }, .{ "x.invalid", "x.invalid" }, .{ "bank.test", "bank.test" }, .{ "a.test", "" } }) |c| try testing.expect(!none.covers(c[0], c[1]));
    // 어느 호스트든(에이전트 탭)과 다른 pane 의 묶인 grant 가 함께 — 에이전트 제 사이트도, 묶인 사이트도 덮는다(전에는 묶인 것만 실려 에이전트 몫을 덜었다).
    try testing.expect(s.setWatch(2, 12, true, false, true, &.{"shop.test"}));
    const both = s.watchByCef(12).?;
    try testing.expect(both.covers("agent.test", "agent.test"));
    try testing.expect(both.covers("api.agent.test", "agent.test"));
    try testing.expect(both.covers("shop.test", "agent.test")); // 묶인 호스트는 첫 사이트와 무관
    try testing.expect(!both.covers("bank.test", "agent.test")); // 다른 사이트에 보낸 요청
    try testing.expect(!both.covers("bank.test", "")); // 첫 사이트가 빈 요청(다른 사이트 iframe 안)은 어느 호스트든으로 덮지 않는다
    try testing.expect(!both.covers("", "agent.test")); // 호스트를 모른다(온 주소에서 못 읽었다)
    // 넷을 넘는 호스트 — 다섯째는 싣지 않는다(덮이지 않는 것으로: 덜어 내는 쪽).
    try testing.expect(s.setWatch(3, 13, true, false, false, &.{ "a.test", "b.test", "c.test", "d.test", "e.test" }));
    const many = s.watchByCef(13).?;
    try testing.expectEqual(@as(u8, 4), many.host_count);
    try testing.expect(many.covers("d.test", "") and !many.covers("e.test", "e.test"));
}

test "W9d① 적대 리뷰 3 회차 P1c: 덜어 내기는 적을 때 찍는다 — 꺼진 동안 적은 기록은 켠 뒤 보내도 덜어 내고, 켜진 동안 적었어도 보낼 때 꺼졌거나 덮이지 않으면 덜어 낸다" {
    var s: State = .{};
    try testing.expect(s.setWatch(1, 11, true, false, false, &.{"a.test"}));
    try testing.expect(s.setWatch(2, 12, true, true, false, &.{"a.test"}));
    const targets = [_]BrowserId{ 1, 2, 9 }; // 9 는 지켜보지 않는다 — 덜어 내는 쪽으로
    const st = s.stamp(&targets, "a.test", "a.test");
    try testing.expectEqual(@as(u8, 0b010), st.full);
    try testing.expectEqual(@as(u8, 0b011), st.covered);
    // 사용자가 설정을 켠다(net_watch full) — 넘김 상자에 남은 기록은 찍은 대로.
    try testing.expect(s.setWatch(1, 11, true, true, false, &.{"a.test"}));
    const w1 = s.watchOf(1).?;
    const d1 = w1.decide(st.full & 1 != 0, st.covered & 1 != 0, "a.test", "a.test");
    try testing.expect(!d1.full and d1.covered);
    // 켜진 동안 적었는데 보내기 전에 꺼졌다 — 지금의 것이 더 덜어 낸다.
    try testing.expect(s.setWatch(2, 12, true, false, false, &.{}));
    const d2 = s.watchOf(2).?.decide(st.full & 2 != 0, st.covered & 2 != 0, "a.test", "a.test");
    try testing.expect(!d2.full and !d2.covered);
    // 켜진 동안 적고 켜진 채 보낸다 — 그대로.
    try testing.expect(s.setWatch(3, 13, true, true, true, &.{}));
    const st3 = s.stamp(&.{3}, "agent.test", "agent.test");
    const d3 = s.watchOf(3).?.decide(st3.full & 1 != 0, st3.covered & 1 != 0, "agent.test", "agent.test");
    try testing.expect(d3.full and d3.covered);
}

test "W9d① 적대 리뷰 3 회차 S1: 거절한 요청은 몫을 쓰지 않는다 — 첫 탭의 문이 거절하면 서비스 워커 길의 몫을, 요청 표가 거절하면 쓴 몫을 모두 되돌리고 붙일 탭마다 센다" {
    var s: State = .{};
    try testing.expect(s.setWatch(1, 11, true, true, false, &.{}));
    try testing.expect(s.setWatch(2, 12, true, true, false, &.{}));
    s.setTopOrigin(1, "https://mail.test");
    s.setTopOrigin(2, "https://mail.test");
    var out: [max_targets]BrowserId = undefined;
    s.watchByCef(11).?.bucket.tokens = 0; // 첫 대상 탭의 양동이가 비었다
    const before = s.sw_path.tokens;
    const refused = s.startServiceWorker("https://mail.test", 7, 1_000_000, &out);
    try testing.expect(refused.track == null and refused.targets == 2);
    try testing.expectEqual(before, s.sw_path.tokens); // 이 길의 몫은 되돌렸다
    try testing.expectEqual(@as(u32, 1), s.watchByCef(11).?.dropped);
    try testing.expectEqual(@as(u32, 1), s.watchByCef(12).?.dropped);
    // 잡으면 두 탭에 붙는다.
    s.watchByCef(11).?.bucket.tokens = tab_burst;
    const ok = s.startServiceWorker("https://mail.test", 8, 1_000_000, &out);
    try testing.expect(ok.track != null and ok.track.?.target_count == 2 and ok.track.?.service_worker);
    // 요청 표가 거절하는 길(같은 잠금 안에서는 오지 않는다 — 방어를 본다): 자리를 다 채우고 셈만 비운다.
    var t: State = .{};
    try testing.expect(t.setWatch(1, 11, true, true, false, &.{}));
    try testing.expect(t.setWatch(2, 12, true, true, false, &.{}));
    t.setTopOrigin(1, "https://mail.test");
    t.setTopOrigin(2, "https://mail.test");
    for (&t.tracks, 1..) |*slot, r| slot.* = .{ .request = r, .owner = 99 };
    const w1 = t.watchByCef(11).?;
    const tab_before = w1.bucket.tokens;
    const global_before = t.global.tokens;
    const sw_before = t.sw_path.tokens;
    try testing.expect(t.startTab(w1, 10_000, 1_000_000) == null);
    try testing.expectEqual(tab_before, w1.bucket.tokens);
    try testing.expectEqual(global_before, t.global.tokens);
    try testing.expectEqual(@as(u32, 1), w1.dropped);
    const r2 = t.startServiceWorker("https://mail.test", 10_001, 1_000_000, &out);
    try testing.expect(r2.track == null and r2.targets == 2);
    try testing.expectEqual(sw_before, t.sw_path.tokens);
    try testing.expectEqual(tab_before, w1.bucket.tokens);
    try testing.expectEqual(global_before, t.global.tokens);
    try testing.expectEqual(@as(u32, 2), w1.dropped);
    try testing.expectEqual(@as(u32, 1), t.watchByCef(12).?.dropped);
}

test "W9d① 적대 리뷰 5 회차 B1: 떠난 문서의 iframe — 프레임이 문서를 연 세대가 지금 주 문서보다 앞이면 앞 문서의 것, 모르는 프레임·지금 문서의 프레임은 아니다, 64 개를 넘으면 먼저 적은 것부터 잊는다" {
    var d: DocFrames = .{};
    d.mainDocument(); // 은행 페이지
    d.subframeDocument(0xA1); // 그 안의 추적 iframe
    try testing.expect(!d.previous(0xA1)); // 지금 문서의 iframe
    d.mainDocument(); // 새 문서 — 은행을 떠났다
    try testing.expect(d.previous(0xA1)); // 떠난 문서의 iframe 이 보낸 비콘
    try testing.expect(!d.previous(0xB2)); // 모르는 프레임(새 문서의 iframe 이 문서를 열기 전 — 그 문서 요청)
    try testing.expect(!d.previous(0)); // 번호를 모른다
    d.subframeDocument(0xB2);
    try testing.expect(!d.previous(0xB2));
    d.subframeDocument(0); // 번호 없는 프레임은 적지 않는다
    try testing.expectEqual(@as(usize, 2), d.len);
    // 같은 프레임이 다시 문서를 열면 그 세대로 고친다(자리를 늘리지 않는다).
    d.subframeDocument(0xA1);
    try testing.expect(!d.previous(0xA1));
    try testing.expectEqual(@as(usize, 2), d.len);
    // 가득 차면 가장 먼저 적은 것(0xA1)부터 잊는다 — 잊힌 프레임은 모르는 프레임이다.
    d.mainDocument();
    for (0..max_doc_frames - 2) |i| d.subframeDocument(0x1000 + i); // 남은 자리를 다 채운다
    try testing.expect(d.previous(0xA1) and d.previous(0xB2)); // 아직 기억한다(앞 세대)
    d.subframeDocument(0x9999);
    try testing.expectEqual(max_doc_frames, d.len);
    try testing.expect(!d.previous(0xA1)); // 잊었다
    try testing.expect(d.previous(0xB2));
    try testing.expect(!d.previous(0x9999));
}

test "W9d① 적대 리뷰 후 — 같은 번호 다시 시작: 진행 중인 번호가 다시 와도 자리는 하나(두 번 세지 않는다), 끝나면 한 번만 돌려주고, 끝난 뒤 같은 번호로 다시 시작하면 문을 새로 지나 새 자리다" {
    var s: State = .{};
    try testing.expect(s.setWatch(1, 11, true, true, false, &.{}));
    const w = s.watchByCef(11).?;
    const id: u64 = 18446744073709551571; // StackOverflow 실측의 주 프레임 번호
    const t = s.startTab(w, id, 1_000_000).?;
    t.begun = true;
    // 끝 전에 같은 번호가 처리기 고르기에 다시 와도(`network.zig` 는 `find` 로 보고 문을 지나지 않는다) 표는 같은 자리를 준다.
    try testing.expect(s.find(id) == t);
    try testing.expect(s.track(id, w) == t);
    try testing.expectEqual(@as(usize, 1), s.in_flight);
    try testing.expectEqual(@as(u16, 1), w.in_flight);
    // 앞 시도가 끝난다(CEF 154 실측 차례 — 끝이 먼저 온다): 한 번만 돌려준다.
    s.untrack(s.find(id).?);
    try testing.expectEqual(@as(usize, 0), s.in_flight);
    try testing.expectEqual(@as(u16, 0), w.in_flight);
    try testing.expect(s.find(id) == null);
    // 같은 번호로 다시 시작 — 문을 새로 지나(양동이 하나) 새 자리, 아직 시작을 보내지 않았다.
    const tokens = w.bucket.tokens;
    const again = s.startTab(w, id, 1_000_000).?;
    try testing.expect(!again.begun);
    try testing.expectEqual(tokens - 1, w.bucket.tokens);
    try testing.expectEqual(@as(usize, 1), s.in_flight);
    try testing.expectEqual(@as(u16, 1), w.in_flight);
    s.untrack(again);
    try testing.expectEqual(@as(usize, 0), s.in_flight);
    try testing.expectEqual(@as(u16, 0), w.in_flight);
    var held: usize = 0;
    for (s.tracks) |tr| held += @intFromBool(tr.request != 0);
    try testing.expectEqual(@as(usize, 0), held);
}
