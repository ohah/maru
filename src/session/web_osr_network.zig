//! Chromium 탭의 네트워크 기록을 maru 가 쥐는 자리(W9d① — docs/plans/web-osr-backend.md 「W9d① 결정」) — L2 순수.
//!
//! 시험이 증명하는 것: 탭마다 요청을 오래된 것부터 버리며(요약 512 KiB·자세한 것 1 MiB, 앱 전체 32 MiB) 쥐고, 리다이렉트는 한 요청의
//! 홉으로, 401 재시도의 두 응답은 뒤의 것으로, sidecar 가 넘긴 요청은 표지로 남긴다. 누가 무엇을 보나 — 읽는 쪽(`Authorizer` — 확인
//! grant 의 grant 번호 — `browser_network` 는 cap 으로 발급하지 않는다)마다 시작점이 있다: 사용자 탭은 그 grant 를 넣은 때부터(「그 전의 N 개는 숨김」), 에이전트가 연
//! 탭은 태어날 때부터(사용자가 첫 읽기 전에 그 탭을 몰면 첫 읽기 때부터 — 콘솔과 같은 풀림), 모르는 쪽은 처음 읽을 때부터. 설정
//! `browser.agent-network-full` 이 꺼져 있으면 읽는 쪽의 grant 호스트로 투영한다(`net_policy` — 덮이지 않는 호스트는 페이지가 고른 칸만,
//! 다른 사이트 iframe 의 요청은 수만, 헤더 값은 허용 목록만, 주소의 사용자 정보는 지운다). 거르기(`url_contains`·`status`)도 투영된 값으로만
//! 한다 — 숨긴 상태 코드를 거르기로 떠보지 못하게.
//! W9d① 적대 리뷰 1 회차: 요청마다 그때 탭의 맨 위 문서 호스트를 적고(`topHostOf`), 사이트에 묶인 grant 로 읽는 쪽에게는 그 grant 가 덮지 않는
//! 사이트에 있을 때의 요청을 숨긴다(F2 — 설정과 무관). 설정이 꺼졌으면 지켜보지 않는 탭과 같은 출처의 서비스 워커 요청은 수만 센다(F4), 덮이지
//! 않는 요청의 리다이렉트 수·홉도 숨긴다(F8). 목록은 `before_req` 커서로 새 요청이 와도 밀리지 않게 넘긴다(F7). 오래된 것은 앞에서 O(1) 로
//! 버린다(`std.Deque` — F10).
//! W9d① 적대 리뷰 2 회차: 사이트에 묶인 읽는 쪽에게 주 프레임 이동은 처음 주소와 홉의 대상이 모두 덮일 때만 보인다(N1 — 덮이지 않는 사이트에서
//! 시작해 덮이는 사이트로 돌아오는 이동의 쿠키가 보였다, 설정과 무관). 설정이 꺼졌으면 서비스 워커 요청은 그 읽는 쪽에게 허락되지 않은 탭이 같은
//! 출처를 보일 때 수만(N6), 덮이지 않는 곳이 보낸 홉은 칸째 없다(N7 — 수도).
//! W9d① 적대 리뷰 3 회차: 덮이는지는 sidecar 가 온 주소에서 읽어 싣는 호스트 칸(요청·홉 — `host`)으로만 가른다 — 주소 글에서 호스트를 다시 읽지
//! 않는다(T1 — 2 KiB 에서 잘린 주소가 긴 사용자 정보 안에서 끊겨 덮이는 사이트로 읽혔다). 자격 증명 헤더(`Cookie`·`Set-Cookie`·`Authorization`)
//! 값과 주소의 사용자 정보는 읽는 쪽이 그 헤더를 보내거나 받은 호스트를 덮는 `browser_storage` grant(`View.cookie_host`)를 쥘 때만 — 설정이
//! 켜져 있어도(D1 — 사용자 결정 2026-10-15). sidecar 가 다시 뜨면(브라우저가 다시 만들어지면) 진행 중이던 요청은 끝난 것으로 치고 번호 표를
//! 비운다(T2 — 새 프로세스는 이동 요청 번호를 같게 다시 쓴다).
//! 브라우저 탭에서 중요한 이유: 요청 헤더에는 그 사이트의 로그인 쿠키·인증 토큰이 그대로 있고, 사용자가 허락 전에 그 탭으로 간 곳의 요청이
//! 허락 뒤의 첫 읽기에 보이면 안 된다.

const std = @import("std");
const ws = @import("web_sidecar/root.zig");
const policy = ws.net_policy;
const net_fields = ws.net_fields;
const msg = ws.message;

pub const Authorizer = u64;

/// 탭 하나의 요약(주소·메서드·상태·시각·크기) 바이트 상한.
pub const max_summary_bytes: usize = 512 * 1024;
/// 탭 하나의 자세한 것(헤더·리다이렉트 홉) 바이트 상한 — 넘으면 오래된 요청의 자세한 것부터 버린다(요약은 남는다).
pub const max_detail_bytes: usize = 1024 * 1024;
/// 앱 전체 상한 — 탭이 32 개면 탭마다의 상한 합(48 MiB)보다 작다.
pub const global_cap_bytes: usize = 32 * 1024 * 1024;
/// 한 탭을 읽는 쪽 수 상한 — 넘으면 가장 오래된 쪽을 잊는다(잊힌 쪽의 다음 읽기는 그때부터 — 더 숨기는 쪽).
pub const max_readers: usize = 16;
/// 한 요청의 리다이렉트 홉 상한(Chromium 은 20 에서 멈춘다).
pub const max_hops: usize = 20;
/// 서비스 워커 요청 하나에 적어 두는, 같은 출처를 보이던 다른 탭 수(넘치면 누구에게나 수만 — N6).
pub const max_sw_tabs: usize = 4;
/// 끝난 요청을 기억해 두는 수(같은 번호 다시 시작 — `Ring.recent_ends`). 다시 시작은 앞 시도의 끝 바로 뒤에 온다(실측 1.4 ms).
pub const recent_end_slots: usize = 16;
/// 목록 한 쪽의 기본·최대 줄 수.
pub const default_page_size: usize = 50;
pub const max_page_size: usize = 200;

/// 요약 한 줄의 고정 몫(글 밖의 칸) — 상한 계산용.
const entry_overhead: usize = 160;
const hop_overhead: usize = 48;

/// 앱 전체 예산(웹 탭들이 함께 쓴다 — `web_osr` 가 하나 쥔다).
pub const Budget = struct {
    bytes: usize = 0,
    cap: usize = global_cap_bytes,
};

pub const State = enum { pending, done, failed, canceled };

/// 헤더 덩어리(소유 바이트 — `NetHeaderBlock` 모양).
pub const Headers = struct {
    count: u8 = 0,
    bytes: []u8 = &.{},
    truncated: bool = false,
    /// sidecar 가 설정이 꺼져 덜어 낸 덩어리다(이름만인 헤더는 빈 값으로 왔다).
    stripped: bool = false,

    fn block(self: Headers) msg.NetHeaderBlock {
        return .{ .count = self.count, .bytes = self.bytes };
    }
};

pub const Hop = struct {
    status: u16,
    url: []u8,
    /// 옮겨 간 주소의 호스트(sidecar 의 칸 — 3 회차 T1). 다음 홉의 헤더를 보낸 곳이다.
    host: []u8,
    hsts: bool,
    url_truncated: bool,
    headers: Headers,
    time_ms: u64,
};

pub const Entry = struct {
    /// 에이전트에게 보이는 번호(`req` — 탭마다 1 부터, 다시 쓰지 않는다). CEF 번호는 2^64 근처라(이동 요청) JSON 수로 쓰지 않는다.
    seq: u64,
    /// CEF 요청 번호(갱신을 찾는 열쇠). 표지는 0.
    request: u64 = 0,
    /// sidecar 가 넘긴 요청 수의 표지면 0 이 아니다(그 밖 칸은 비었다).
    dropped: u32 = 0,
    flags: msg.NetFlags = .{},
    resource_type: u8 = 0,
    method: []u8 = &.{},
    url: []u8 = &.{},
    /// 요청 주소의 호스트(sidecar 가 온 주소에서 읽은 칸 — 3 회차 T1). 덮이는지는 이것으로만 가른다.
    host: []u8 = &.{},
    initiator: []u8 = &.{},
    site: []u8 = &.{},
    /// 요청이 났을 때 탭의 맨 위 문서 호스트(`topHostOf` — F2). 주 프레임 문서 요청은 쓰지 않는다(처음 주소와 홉의 대상으로 가른다 — 2 회차 N1).
    top_host: []u8 = &.{},
    /// 서비스 워커 요청이 났을 때 같은 출처를 보이던 다른 탭들(F4·N6 — 그 탭의 요청일 수 있다). 넘치면 `sw_tabs_overflow`(누구에게나 수만).
    sw_tabs: [max_sw_tabs]u64 = @splat(0),
    sw_tab_count: u8 = 0,
    sw_tabs_overflow: bool = false,
    mime: []u8 = &.{},
    start_ms: u64 = 0,
    end_ms: u64 = 0,
    status: u16 = 0,
    has_response: bool = false,
    response_hsts: bool = false,
    state: State = .pending,
    error_code: i32 = 0,
    received: u64 = 0,
    request_headers: Headers = .{},
    response_headers: Headers = .{},
    hops: std.ArrayList(Hop) = .empty,
    /// 리다이렉트 수와 마지막 홉의 주소(요약 — 자세한 것을 버려도 남는다: 응답을 보낸 곳이 덮이는지 가른다).
    redirects: u8 = 0,
    final_url: []u8 = &.{},
    final_host: []u8 = &.{},
    /// sidecar 가 다시 떠(브라우저가 다시 만들어졌다) 끝을 받지 못한 채 끝난 것으로 친 요청(3 회차 T2 — `Ring.abandonLive`).
    engine_restarted: bool = false,
    /// Chromium 이 이 요청을 같은 CEF 번호로 다시 시작했다(W9d① 적대 리뷰 후 — `Ring.restartEarlier`). 이 기록은 버려진 앞 시도다(취소 −3) —
    /// 받은 응답은 페이지에 가지 않았고, 다음 시도는 새 기록이다.
    restarted: bool = false,
    /// 앱·탭 상한으로 자세한 것(헤더·홉)을 버렸다.
    detail_evicted: bool = false,
    summary_bytes: usize = 0,
    detail_bytes: usize = 0,

    /// 마지막 주소의 호스트(리다이렉트 뒤 — 응답을 보낸 곳).
    fn finalHost(self: *const Entry) []const u8 {
        return if (self.redirects > 0) self.final_host else self.host;
    }

    fn freeDetail(self: *Entry, gpa: std.mem.Allocator) void {
        gpa.free(self.request_headers.bytes);
        gpa.free(self.response_headers.bytes);
        self.request_headers = .{};
        self.response_headers = .{};
        for (self.hops.items) |h| {
            gpa.free(h.url);
            gpa.free(h.host);
            gpa.free(h.headers.bytes);
        }
        self.hops.clearAndFree(gpa);
    }

    fn deinit(self: *Entry, gpa: std.mem.Allocator) void {
        self.freeDetail(gpa);
        gpa.free(self.method);
        gpa.free(self.url);
        gpa.free(self.host);
        gpa.free(self.initiator);
        gpa.free(self.site);
        gpa.free(self.top_host);
        gpa.free(self.mime);
        gpa.free(self.final_url);
        gpa.free(self.final_host);
    }
};

const Reader = struct {
    who: Authorizer,
    /// 이 번호 이상의 요청을 본다.
    start: u64,
    /// 시작점을 첫 읽기 때로 미뤘다(태어날 때의 묶음이 사용자의 몰기로 풀렸다).
    deferred: bool = false,
    /// 마지막으로 쓴 차례(잊을 쪽을 고른다).
    used: u64 = 0,
    /// grant 로 들어온 쪽(`noteReader`) — `syncReaders` 가 grant 가 사라지면 뺀다. 처음 읽을 때 생긴 쪽(모르는 쪽 — 방어)은 아니다.
    granted: bool = false,
};

/// app 이 아는 그 탭의 `browser_network` grant 하나(`syncReaders`).
pub const Desired = struct { who: Authorizer, birth: bool = false };

/// 읽기의 관점 — 설정과 읽는 쪽의 grant 호스트(어느 호스트든 grant 면 탭의 지금 호스트).
pub const View = struct {
    full: bool = true,
    grant_host: []const u8 = "",
    /// 읽는 쪽의 grant 가 `grant_host` 에 묶였다(모달로 받은 grant·좁힌 태어날 때 grant) — 탭의 맨 위 문서가 그 사이트가 아닐 때의 요청은
    /// 숨긴다(F2). 어느 호스트든 grant(에이전트 탭)는 거짓.
    top_bound: bool = false,
    /// 설정이 꺼졌을 때 이 읽는 쪽에게 허락되지 않은 다른 탭이 지금 보이는 출처들(`scheme://host[:port]`) — 그 출처의 서비스 워커 요청은
    /// 수만(F4·N6).
    shared_sw_origins: []const []const u8 = &.{},
    /// 설정이 꺼졌을 때 그런 탭 중 지금 출처를 모르는 것이 있다(주소가 옛 것 — 4 회차 C3) — 서비스 워커 요청은 모두 수만.
    shared_sw_unknown: bool = false,
    /// 이 읽는 쪽이 `browser_network` grant 를 쥔 탭들(읽는 탭은 늘 든 것으로 친다) — 서비스 워커 요청이 날 때 같은 출처를 보이던 탭이 여기
    /// 없으면 수만(N6 — 「허락 없는 탭」 은 이 읽는 쪽에게 허락되지 않은 탭이다).
    reader_tabs: []const u64 = &.{},
    /// 이 읽는 쪽이 이 탭에 쥔 `browser_storage` grant 의 호스트(W9d① 적대 리뷰 3 회차 D1 — 쿠키 권한). 자격 증명 헤더 값과 주소의 사용자 정보는
    /// 그 헤더를 보내거나 받은 호스트를 이것이 덮을 때만 보인다 — 설정이 켜져 있어도(사용자 결정 2026-10-15 「쿠키 권한 있을 때만 보임」), 어느
    /// 호스트든 grant(에이전트 탭)여도. 비면 아무것도.
    cookie_host: []const u8 = "",

    fn readerHas(self: View, tab: u64) bool {
        return std.mem.indexOfScalar(u64, self.reader_tabs, tab) != null;
    }

    /// 그 호스트(sidecar 의 칸)의 응답·헤더를 보여도 되는가 — 설정이 켜졌으면 모두, 꺼졌으면 grant 호스트가 덮을 때만. 빈 호스트(모른다)는 꺼졌을 때
    /// 덮이지 않는다.
    fn covers(self: View, host: []const u8) bool {
        if (self.full) return true;
        return policy.hostCovers(self.grant_host, host);
    }

    fn otherSite(self: View, host: []const u8) bool {
        return !policy.hostCovers(self.grant_host, host);
    }

    /// D1: 그 호스트가 보내거나 받은 자격 증명(쿠키·인증 헤더 값, 주소의 사용자 정보)을 보여도 되는가 — 설정이 켜졌고(꺼졌으면 sidecar 가 늘
    /// 덜어 낸다) 이 읽는 쪽의 쿠키 권한이 그 호스트를 덮을 때만.
    fn credentials(self: View, host: []const u8) bool {
        return self.full and policy.hostCovers(self.cookie_host, host);
    }
};

/// 목록 거르기(`browser.network`). 비어 있으면 거르지 않는다. 투영된 값으로만 본다.
pub const Query = struct {
    page: usize = 0,
    page_size: usize = default_page_size,
    /// 종류 이름(`net_policy.resourceTypeName`) — 비면 모두.
    types: []const []const u8 = &.{},
    method: ?[]const u8 = null,
    /// 상태 정확히, 또는 `status_class`(1..5 — `4xx`).
    status: ?u16 = null,
    status_class: ?u8 = null,
    url_contains: ?[]const u8 = null,
    /// 이 번호보다 오래된 요청만(F7 — 앞 쪽의 마지막 `req`, 결과의 `next_before_req`). 새 요청이 와도 쪽이 밀리지 않는다.
    before_req: ?u64 = null,
    clear: bool = false,
};

/// 요청이 들어올 때 app 이 아는 것(`Ring.begin`).
pub const BeginContext = struct {
    /// 그때 탭의 맨 위 문서 호스트(app 의 주소 — 모르면 빈 글).
    top_host: []const u8 = "",
    /// 서비스 워커 요청이면 같은 출처를 지금 보이는 다른 탭들(F4·N6) — `max_sw_tabs` 를 넘으면 앞의 것과 넘침만 적는다.
    sw_tabs: []const u64 = &.{},
};

/// F2: 그 요청이 났을 때 탭의 맨 위 문서 호스트. 주 프레임 문서 요청은 그 주소의 호스트(그 요청이 문서를 바꾼다). 그 밖은 쿠키의 첫 사이트
/// (`site` — 렌더러가 요청마다 정한다: CEF 는 등록 도메인 꼴로 준다)와 app 이 아는 탭의 주소(`app_top`)를 맞춰 본다 — 같은 사이트면 더 좁은
/// app 의 호스트, 다르면 첫 사이트(이동과 엇갈려 app 의 주소가 옛 것이거나 이미 새 것이다 — 요청이 스스로 말한 쪽을 믿는다), 첫 사이트가
/// 비었으면(다른 사이트 iframe 안 — 실측) app 의 호스트. 남는 틈: 같은 등록 도메인의 다른 호스트로 옮기는 순간의 요청(문서에 적었다).
/// 떠난 문서의 iframe 이 보낸 요청(`previous_document` — W9d① 적대 리뷰 5 회차 B1)은 빈 호스트다: 그 iframe 의 `pagehide` 비콘은 새 문서의
/// `url_changed` 뒤에 와서(실측) app 의 호스트가 이미 새 사이트다 — 그 사이트의 것으로 치면 덮이지 않던 은행 페이지의 추적 iframe 요청이
/// 새 사이트에 묶인 읽는 쪽에게 보였다. 앞 문서의 맨 위 호스트는 모르므로 덮지 않는 쪽으로.
pub fn topHostOf(v: msg.NetBegin, app_top: []const u8) []const u8 {
    if (v.flags.main_frame and v.resource_type == 0) return v.host; // sidecar 의 칸(3 회차 T1 — 잘린 주소에서 다시 읽지 않는다)
    if (v.flags.previous_document) return "";
    if (v.site.len == 0) return app_top;
    if (app_top.len != 0 and policy.sameSite(app_top, v.site)) return app_top;
    return v.site;
}

pub const DetailError = error{ UnknownRequest, Evicted, OutOfMemory };

pub const Ring = struct {
    /// 오래된 것부터(번호 차례). 상한에서 앞을 버리는 일이 요청마다 있어 배열을 밀지 않는 deque 다(F10 — 밀면 2700 줄을 요청마다 옮겼다).
    entries: std.Deque(Entry) = .empty,
    /// CEF 요청 번호 → 번호(진행 중인 것만 — 끝나면 뺀다).
    live: std.AutoHashMapUnmanaged(u64, u64) = .empty,
    next_seq: u64 = 1,
    summary_bytes: usize = 0,
    detail_bytes: usize = 0,
    readers: [max_readers]Reader = undefined,
    reader_count: usize = 0,
    reader_clock: u64 = 0,
    /// 태어날 때 묶인 읽는 쪽(에이전트가 연 탭) — 그쪽이 처음 읽기 전에 사용자가 몰면 그 시작점을 첫 읽기로 미룬다.
    birth_who: Authorizer = 0,
    birth_pending: bool = false,
    birth_used: bool = false,
    /// 앱 예산이 모자라 적지 못한 요청 수 — 다음 표지에 싣는다.
    unrecorded: u32 = 0,
    /// 최근에 끝난 요청(CEF 번호 → 기록 번호, 돌려 쓰는 자리) — 같은 번호의 시작이 다시 오면 그 기록을 다시 시작으로 표시한다(W9d① 적대 리뷰 후).
    recent_ends: [recent_end_slots]RecentEnd = @splat(.{}),
    recent_next: usize = 0,

    const RecentEnd = struct { request: u64 = 0, seq: u64 = 0 };

    pub fn deinit(self: *Ring, gpa: std.mem.Allocator, budget: *Budget) void {
        self.wipe(gpa, budget);
        self.entries.deinit(gpa);
        self.live.deinit(gpa);
    }

    /// 지켜보기가 끝났다(마지막 `browser_network` grant 가 사라졌다) — 요청·읽는 쪽을 모두 지운다. 번호는 이어 간다(다시 허락한 뒤의 옛
    /// 번호가 새 요청을 가리키지 않게).
    pub fn wipe(self: *Ring, gpa: std.mem.Allocator, budget: *Budget) void {
        var it = self.entries.iterator();
        while (it.nextPtr()) |e| e.deinit(gpa);
        self.entries.head = 0;
        self.entries.len = 0;
        self.live.clearRetainingCapacity();
        budget.bytes -|= self.summary_bytes + self.detail_bytes;
        self.summary_bytes = 0;
        self.detail_bytes = 0;
        self.reader_count = 0;
        self.birth_who = 0;
        self.birth_pending = false;
        self.unrecorded = 0;
    }

    // ── 읽는 쪽 ──────────────────────────────────────────────────────────────────────────────────────────

    fn findReader(self: *Ring, who: Authorizer) ?*Reader {
        for (self.readers[0..self.reader_count]) |*r| if (r.who == who) return r;
        return null;
    }

    fn addReader(self: *Ring, who: Authorizer, start: u64) *Reader {
        self.reader_clock += 1;
        if (self.reader_count == max_readers) {
            // 가장 오래 쓰지 않은 쪽을 잊는다 — 잊힌 쪽의 다음 읽기는 그때부터(더 숨기는 쪽).
            var victim: usize = 0;
            for (self.readers[0..self.reader_count], 0..) |r, i| if (r.used < self.readers[victim].used) {
                victim = i;
            };
            self.readers[victim] = self.readers[self.reader_count - 1];
            self.reader_count -= 1;
        }
        self.readers[self.reader_count] = .{ .who = who, .start = start, .used = self.reader_clock };
        self.reader_count += 1;
        return &self.readers[self.reader_count - 1];
    }

    /// 그 탭에 `browser_network` grant 가 들어왔다 — 읽는 쪽 `who` 의 시작점을 지금으로(이미 있으면 그대로 — 같은 grant 번호다). 다른
    /// 사이트로 다시 허용한 것은 저장소가 새 번호를 주므로 새 읽는 쪽으로 지금부터 시작한다(W9d① 적대 리뷰 1 회차 F1 — 그 사이트의 허락 전
    /// 요청이 보였다). `at_birth` — 에이전트가 연 탭이라 grant 가 탭과 함께 생겼다: 처음부터 본다.
    pub fn noteReader(self: *Ring, who: Authorizer, at_birth: bool) void {
        if (who == 0) return;
        if (self.findReader(who)) |r| {
            r.granted = true;
            return;
        }
        // 태어날 때의 묶음은 탭마다 한 번 — 철회 뒤 다시 들어온 grant 는 지금부터다(다시 허락은 새 grant 번호지만 방어로).
        const birth = at_birth and !self.birth_used;
        self.addReader(who, if (birth) 0 else self.next_seq).granted = true;
        if (birth) {
            self.birth_used = true;
            self.birth_who = who;
            self.birth_pending = true;
        }
    }

    /// app 이 아는 grant 목록에 맞춘다 — 사라진 grant 의 읽는 쪽은 빼고(철회), 새 grant 는 지금부터(태어날 때의 것이면 처음부터) 넣는다.
    /// 처음 읽을 때 생긴 쪽(grant 없이 읽은 모르는 쪽 — 방어)은 그대로 둔다.
    pub fn syncReaders(self: *Ring, desired: []const Desired) void {
        var i: usize = 0;
        while (i < self.reader_count) {
            const r = self.readers[i];
            const keep = !r.granted or for (desired) |d| {
                if (d.who == r.who) break true;
            } else false;
            if (keep) {
                i += 1;
                continue;
            }
            self.removeReader(r.who);
        }
        for (desired) |d| self.noteReader(d.who, d.birth);
    }

    /// 그 읽는 쪽의 grant 가 사라졌다(철회).
    pub fn removeReader(self: *Ring, who: Authorizer) void {
        for (self.readers[0..self.reader_count], 0..) |r, i| if (r.who == who) {
            self.readers[i] = self.readers[self.reader_count - 1];
            self.reader_count -= 1;
            break;
        };
        if (self.birth_who == who) {
            self.birth_who = 0;
            self.birth_pending = false;
        }
    }

    /// 사용자가 이 탭을 몰았다(누름·키·주소창·뒤로 — 콘솔과 같은 신호). 태어날 때 묶인 쪽이 아직 읽지 않았으면 그 시작점을 첫 읽기로
    /// 미룬다 — 그 탭으로 사용자가 간 곳(은행 등)의 요청이 그 읽기에 보이지 않게.
    pub fn userDrove(self: *Ring) void {
        if (!self.birth_pending) return;
        self.birth_pending = false;
        if (self.findReader(self.birth_who)) |r| r.deferred = true;
    }

    /// 읽기 직전 — 읽는 쪽의 시작점(모르는 쪽은 지금부터, 미룬 쪽은 지금으로 정한다).
    fn startFor(self: *Ring, who: Authorizer) u64 {
        self.reader_clock += 1;
        if (who == self.birth_who) self.birth_pending = false;
        if (who == 0) return self.next_seq;
        const r = self.findReader(who) orelse self.addReader(who, self.next_seq);
        if (r.deferred) {
            r.deferred = false;
            r.start = self.next_seq;
        }
        r.used = self.reader_clock;
        return r.start;
    }

    // ── 기록 ─────────────────────────────────────────────────────────────────────────────────────────────

    fn indexOfSeq(self: *const Ring, seq: u64) ?usize {
        var lo: usize = 0;
        var hi: usize = self.entries.len;
        while (lo < hi) {
            const mid = (lo + hi) / 2;
            const s = self.entries.atPtr(mid).seq;
            if (s == seq) return mid;
            if (s < seq) lo = mid + 1 else hi = mid;
        }
        return null;
    }

    fn liveEntry(self: *Ring, request: u64) ?*Entry {
        const seq = self.live.get(request) orelse return null;
        const i = self.indexOfSeq(seq) orelse return null;
        return self.entries.atPtr(i);
    }

    fn dupeHeaders(gpa: std.mem.Allocator, block: msg.NetHeaderBlock, truncated: bool, stripped: bool) !Headers {
        return .{ .count = block.count, .bytes = try gpa.dupe(u8, block.bytes), .truncated = truncated, .stripped = stripped };
    }

    /// 새 요청. `ctx` 는 그때 app 이 아는 탭의 것(F2·F4). 같은 CEF 번호의 앞 시도가 있으면 먼저 다시 시작으로 끝낸다(`restartEarlier`) — 이
    /// 기록을 적지 못해도(상한) 앞 기록은 끝난다.
    pub fn begin(self: *Ring, gpa: std.mem.Allocator, budget: *Budget, v: msg.NetBegin, ctx: BeginContext) std.mem.Allocator.Error!void {
        self.restartEarlier(v.request, v.time_ms);
        const top = topHostOf(v, ctx.top_host);
        const summary = entry_overhead + v.method.len + v.url.len + v.host.len + v.initiator.len + v.site.len + top.len;
        const detail_len = v.headers.bytes.len;
        // 적지 못한 수가 있으면 그 표지(`flushUnrecorded`)가 이 기록 앞에 들어간다 — 자리도 함께 낸다(5 회차 N4: 표지가 제 자리를 낸 뒤 이 기록을
        // 다시 보지 않고 넣어 탭·앱 상한을 표지 하나만큼 넘었다). 마지막이 표지라 더하기만 해도 넉넉히 잡는다.
        const marker: usize = if (self.unrecorded != 0) entry_overhead else 0;
        if (!self.makeRoom(gpa, budget, summary + marker, detail_len)) {
            self.unrecorded +|= 1;
            return;
        }
        try self.flushUnrecorded(gpa, budget);
        var e: Entry = .{ .seq = self.next_seq, .request = v.request, .flags = v.flags, .resource_type = v.resource_type, .start_ms = v.time_ms, .summary_bytes = summary, .detail_bytes = detail_len };
        errdefer e.deinit(gpa);
        e.method = try gpa.dupe(u8, v.method);
        e.url = try gpa.dupe(u8, v.url);
        e.host = try gpa.dupe(u8, v.host);
        e.initiator = try gpa.dupe(u8, v.initiator);
        e.site = try gpa.dupe(u8, v.site);
        e.top_host = try gpa.dupe(u8, top);
        if (v.flags.service_worker) {
            e.sw_tab_count = @intCast(@min(ctx.sw_tabs.len, max_sw_tabs));
            @memcpy(e.sw_tabs[0..e.sw_tab_count], ctx.sw_tabs[0..e.sw_tab_count]);
            e.sw_tabs_overflow = ctx.sw_tabs.len > max_sw_tabs;
        }
        e.request_headers = try dupeHeaders(gpa, v.headers, v.flags.headers_truncated, v.flags.stripped);
        try self.live.put(gpa, v.request, e.seq);
        errdefer _ = self.live.remove(v.request);
        try self.entries.pushBack(gpa, e);
        self.next_seq += 1;
        self.charge(budget, summary, detail_len);
    }

    pub fn redirect(self: *Ring, gpa: std.mem.Allocator, budget: *Budget, v: msg.NetRedirect) std.mem.Allocator.Error!void {
        const e0 = self.liveEntry(v.request) orelse return;
        if (e0.redirects >= max_hops) return;
        const seq = e0.seq;
        const old_final = e0.final_url.len + e0.final_host.len;
        const new_final = v.url.len + v.host.len;
        const add_summary = new_final -| old_final;
        const add_detail = hop_overhead + v.url.len + v.host.len + v.headers.bytes.len;
        if (!self.makeRoom(gpa, budget, add_summary, if (e0.detail_evicted) 0 else add_detail)) return;
        const e = self.entryBySeq(seq) orelse return; // 자리를 내며 옮겨졌을 수 있다
        const final = try gpa.dupe(u8, v.url);
        errdefer gpa.free(final);
        const final_host = try gpa.dupe(u8, v.host);
        gpa.free(e.final_url);
        gpa.free(e.final_host);
        e.final_url = final;
        e.final_host = final_host;
        e.redirects += 1;
        e.summary_bytes = e.summary_bytes - old_final + new_final;
        self.summary_bytes = self.summary_bytes - old_final + new_final;
        budget.bytes = budget.bytes - old_final + new_final;
        if (e.detail_evicted) return;
        const url = try gpa.dupe(u8, v.url);
        errdefer gpa.free(url);
        const host = try gpa.dupe(u8, v.host);
        errdefer gpa.free(host);
        const headers = try dupeHeaders(gpa, v.headers, v.flags.headers_truncated, v.flags.stripped);
        errdefer gpa.free(headers.bytes);
        try e.hops.append(gpa, .{ .status = v.status, .url = url, .host = host, .hsts = v.flags.hsts, .url_truncated = v.flags.url_truncated, .headers = headers, .time_ms = v.time_ms });
        e.detail_bytes += add_detail;
        self.charge(budget, 0, add_detail);
    }

    /// 응답 머리 — 401 뒤 인증 재시도의 둘째 응답은 첫째를 덮는다.
    pub fn response(self: *Ring, gpa: std.mem.Allocator, budget: *Budget, v: msg.NetResponse) std.mem.Allocator.Error!void {
        const e0 = self.liveEntry(v.request) orelse return;
        const seq = e0.seq;
        const add_summary = v.mime.len;
        const add_detail = if (e0.detail_evicted) 0 else v.headers.bytes.len;
        if (!self.makeRoom(gpa, budget, add_summary, add_detail)) return;
        const e = self.entryBySeq(seq) orelse return;
        const mime = try gpa.dupe(u8, v.mime);
        errdefer gpa.free(mime);
        const old_mime = e.mime.len;
        gpa.free(e.mime);
        e.mime = mime;
        e.summary_bytes = e.summary_bytes - old_mime + mime.len;
        self.summary_bytes = self.summary_bytes - old_mime + mime.len;
        budget.bytes = budget.bytes - old_mime + mime.len;
        e.status = v.status;
        e.has_response = true;
        e.response_hsts = v.flags.hsts;
        if (!e.detail_evicted) {
            const old = e.response_headers.bytes.len;
            const headers = try dupeHeaders(gpa, v.headers, v.flags.headers_truncated, v.flags.stripped);
            gpa.free(e.response_headers.bytes);
            e.response_headers = headers;
            e.detail_bytes = e.detail_bytes - old + headers.bytes.len;
            self.detail_bytes = self.detail_bytes - old + headers.bytes.len;
            budget.bytes = budget.bytes - old + headers.bytes.len;
        }
    }

    pub fn end(self: *Ring, v: msg.NetEnd) void {
        const e = self.liveEntry(v.request) orelse return;
        e.state = switch (v.outcome) {
            .success => .done,
            .canceled => .canceled,
            .failed => .failed,
        };
        e.error_code = v.error_code;
        e.received = v.received;
        e.end_ms = v.time_ms;
        _ = self.live.remove(v.request);
        self.noteEnded(v.request, e.seq);
    }

    /// 끝난 요청을 최근 끝에 적는다(가장 오래된 자리를 덮는다). 한 번호의 자리는 많아야 하나다 — 끝은 진행 중 기록에만 오고, 그 기록을 연
    /// 시작이 앞 시도의 자리를 비웠다(`restartEarlier`).
    fn noteEnded(self: *Ring, request: u64, seq: u64) void {
        self.recent_ends[self.recent_next] = .{ .request = request, .seq = seq };
        self.recent_next = (self.recent_next + 1) % recent_end_slots;
    }

    /// W9d① 적대 리뷰 후 — 같은 번호 다시 시작: Chromium 은 한 요청을 같은 CEF 번호로 다시 시작한다(실측 — StackOverflow 의 Cloudflare 확인
    /// 페이지, 판정 `R9d6-restart-same-id`: 이동의 답에 `Critical-CH` 가 있으면 그 힌트를 실어 같은 이동을 다시 한다). CEF 번호는 한 브라우저
    /// 프로세스 안에서 다른 요청에 다시 주지 않으므로(다시 뜬 프로세스는 `abandonLive` 가 가른다) 같은 번호의 시작은 다시 시작이다. 앞 시도는
    /// 취소(−3 ERR_ABORTED — Chromium 이 버렸다)로 끝내고 `restarted` 를 세운다 — 받은 응답(Cloudflare 의 403)은 그대로 두되 마지막 답이 아님을
    /// 보인다. 두 차례 모두: 앞 시도가 아직 진행 중이면(끝이 넘김 상자에서 버려졌다 등 — 전에는 새 시작을 버려 새 시도의 응답·끝이 앞 기록에
    /// 붙었다) 번호 표에서 빼고 지금 끝낸다. 이미 끝났으면(CEF 154 실측 — 끝(성공)이 먼저 온다) 최근 끝에서 찾아 표시만 고친다.
    fn restartEarlier(self: *Ring, request: u64, at_ms: u64) void {
        const seq = if (self.live.fetchRemove(request)) |kv| kv.value else for (&self.recent_ends) |*r| {
            if (r.request != request) continue;
            const s = r.seq;
            r.* = .{};
            break s;
        } else return;
        const e = self.entryBySeq(seq) orelse return; // 상한으로 이미 버려졌다
        e.state = .canceled;
        e.error_code = -3;
        e.restarted = true;
        if (e.end_ms == 0) e.end_ms = at_ms;
    }

    /// 그 탭의 브라우저가 다시 만들어졌다(sidecar 가 다시 떴다 — W9d① 적대 리뷰 3 회차 T2). 진행 중이던 요청의 끝은 오지 않는다(옛 프로세스와
    /// 함께 사라졌다) — 취소로 끝내고 번호 표를 비운다. 새 프로세스는 이동 요청 번호(2^64-4·-5 …)를 같게 다시 쓴다(실측 — 판정 두 번):
    /// 비우지 않으면 새 요청의 시작은 「이미 있다」 로 버려지고 그 응답·끝이 옛 기록(다른 사이트의 덮인 주소)에 붙었다.
    pub fn abandonLive(self: *Ring) void {
        var it = self.live.valueIterator();
        while (it.next()) |seq| if (self.entryBySeq(seq.*)) |e| {
            e.state = .canceled;
            e.error_code = -3; // net::ERR_ABORTED — 브라우저 프로세스와 함께 끊겼다
            e.engine_restarted = true;
        };
        self.live.clearRetainingCapacity();
        self.recent_ends = @splat(.{}); // 새 프로세스의 같은 번호는 다시 시작이 아니다
    }

    /// sidecar 가 넘긴 요청 수 — 마지막이 표지면 거기에 더한다(쏟아질 때 표지가 요청을 밀어내지 않게).
    pub fn addDropped(self: *Ring, gpa: std.mem.Allocator, budget: *Budget, count: u32) std.mem.Allocator.Error!void {
        if (count == 0) return;
        if (self.entries.backPtr()) |last| {
            if (last.dropped != 0) {
                last.dropped +|= count;
                return;
            }
        }
        if (!self.makeRoom(gpa, budget, entry_overhead, 0)) {
            self.unrecorded +|= count;
            return;
        }
        try self.entries.pushBack(gpa, .{ .seq = self.next_seq, .dropped = count, .summary_bytes = entry_overhead });
        self.next_seq += 1;
        self.charge(budget, entry_overhead, 0);
    }

    fn flushUnrecorded(self: *Ring, gpa: std.mem.Allocator, budget: *Budget) std.mem.Allocator.Error!void {
        if (self.unrecorded == 0) return;
        const n = self.unrecorded;
        self.unrecorded = 0;
        try self.addDropped(gpa, budget, n);
    }

    fn entryBySeq(self: *Ring, seq: u64) ?*Entry {
        const i = self.indexOfSeq(seq) orelse return null;
        return self.entries.atPtr(i);
    }

    fn charge(self: *Ring, budget: *Budget, summary: usize, detail_len: usize) void {
        self.summary_bytes += summary;
        self.detail_bytes += detail_len;
        budget.bytes += summary + detail_len;
    }

    /// 요약 `summary`·자세한 것 `detail` 바이트가 들어갈 자리를 낸다 — 탭 상한은 이 탭의 오래된 것부터, 앱 상한도 이 탭에서만 낸다(다른
    /// 탭의 기록을 이 탭이 지우지 않는다). 먼저 자세한 것(헤더·홉)을 버리고, 그래도 모자라면 요약째 버린다. 자리를 못 내면 거짓.
    fn makeRoom(self: *Ring, gpa: std.mem.Allocator, budget: *Budget, summary: usize, detail_len: usize) bool {
        const total = summary + detail_len;
        var i: usize = 0;
        while ((self.detail_bytes + detail_len > max_detail_bytes or budget.bytes + total > budget.cap) and i < self.entries.len) : (i += 1) {
            const e = self.entries.atPtr(i);
            if (e.detail_bytes == 0) continue;
            self.detail_bytes -= e.detail_bytes;
            budget.bytes -|= e.detail_bytes;
            e.freeDetail(gpa);
            e.detail_bytes = 0;
            e.detail_evicted = true;
        }
        var drop: usize = 0;
        var freed_summary: usize = 0;
        var freed_all: usize = 0;
        while (drop < self.entries.len and (self.summary_bytes - freed_summary + summary > max_summary_bytes or budget.bytes -| freed_all + total > budget.cap)) : (drop += 1) {
            const e = self.entries.atPtr(drop);
            freed_summary += e.summary_bytes;
            freed_all += e.summary_bytes + e.detail_bytes;
        }
        for (0..drop) |_| {
            const e = self.entries.frontPtr().?;
            // 번호 표에서는 이 기록을 가리킬 때만 뺀다(4 회차 C2) — sidecar 가 다시 뜨면 새 프로세스가 같은 CEF 번호를 새 요청에 준다(`abandonLive`):
            // 옛 기록을 버리며 그 번호를 빼면 새 요청의 리다이렉트·응답·끝이 버려졌다.
            if (e.request != 0) if (self.live.get(e.request)) |seq| if (seq == e.seq) {
                _ = self.live.remove(e.request);
            };
            self.summary_bytes -= e.summary_bytes;
            self.detail_bytes -= e.detail_bytes;
            budget.bytes -|= e.summary_bytes + e.detail_bytes;
            e.deinit(gpa);
            _ = self.entries.popFront(); // 앞에서 O(1) — 나머지를 옮기지 않는다
        }
        return budget.bytes + total <= budget.cap and self.summary_bytes + summary <= max_summary_bytes and self.detail_bytes + detail_len <= max_detail_bytes;
    }

    // ── 읽기 ─────────────────────────────────────────────────────────────────────────────────────────────

    /// 이 읽는 쪽에게 보이는가(목록·자세히 공통) — 시작점 뒤이고, 설정이 꺼졌으면 다른 사이트 iframe 의 것이 아니다.
    fn hiddenIframe(view: View, e: *const Entry) bool {
        return !view.full and policy.crossSiteIframe(e.flags, e.resource_type, e.host, e.initiator, e.site);
    }

    /// F2: 그 요청이 났을 때 탭의 맨 위 문서가 읽는 쪽의 grant 가 덮는 사이트였나 — 아니면 숨긴다(설정과 무관: 설정이 가르는 것은 덮이는 페이지가
    /// 보낸 다른 사이트 요청이지, 덮이지 않는 사이트에서의 브라우징이 아니다). 주 프레임 문서 요청은 `navigationCovered`.
    fn topCovered(view: View, e: *const Entry) bool {
        if (!view.top_bound) return true;
        if (e.flags.main_frame and e.resource_type == 0) return navigationCovered(view, e);
        return policy.hostCovers(view.grant_host, e.top_host);
    }

    /// 적대 리뷰 2 회차 N1: 주 프레임 이동은 처음 주소와 홉마다의 대상(마지막 주소 포함)이 모두 덮일 때만 — 덮이지 않는 사이트에서 시작해
    /// 덮이는 사이트로 돌아온 이동(OAuth·결제의 돌아오기, 에이전트가 연 열린 리다이렉트)은 그 사이트에 보낸 쿠키·받은 Set-Cookie 째다. 설정과
    /// 무관하다(설정은 덮이는 페이지가 보낸 다른 사이트 요청을 가른다 — 덮이지 않는 사이트에서 시작한 이동이 아니다). 자세한 것을 버려 가운데
    /// 홉을 모르면 둘 이상의 리다이렉트는 숨긴다.
    fn navigationCovered(view: View, e: *const Entry) bool {
        var hosts: [max_hops + 1][]const u8 = undefined;
        var n: usize = 0;
        if (e.redirects > 0) {
            if (!e.detail_evicted and e.hops.items.len == e.redirects) {
                for (e.hops.items) |h| {
                    hosts[n] = h.host;
                    n += 1;
                }
            } else if (e.redirects > 1) return false;
            hosts[n] = e.final_host;
            n += 1;
        }
        return policy.navigationCovered(view.grant_host, e.host, hosts[0..n]);
    }

    /// F4·N6(설정이 꺼졌을 때): 이 읽는 쪽에게 허락되지 않은 탭이 같은 출처를 보이는 서비스 워커 요청 — 그 탭의 것일 수 있어 수만 센다.
    /// 요청이 날 때 그런 탭이 있었거나(`sw_tabs` — 그 탭의 grant 는 지금 것으로 본다) 지금 있다.
    fn sharedServiceWorker(view: View, e: *const Entry) bool {
        if (view.full or !e.flags.service_worker) return false;
        if (e.sw_tabs_overflow or view.shared_sw_unknown) return true;
        for (e.sw_tabs[0..e.sw_tab_count]) |t| if (!view.readerHas(t)) return true;
        var ob: [msg.max_net_origin_bytes]u8 = undefined;
        const origin = policy.originOf(e.initiator, &ob);
        for (view.shared_sw_origins) |o| if (std.ascii.eqlIgnoreCase(o, if (origin.len > 0) origin else e.initiator)) return true;
        return false;
    }

    /// `browser.network` 의 결과 JSON(`out` 소유). 새것부터, 한 쪽 `page_size` 줄.
    pub fn list(self: *Ring, out: std.mem.Allocator, who: Authorizer, view: View, q: Query) std.mem.Allocator.Error![]u8 {
        const start = self.startFor(who);
        var aw: std.Io.Writer.Allocating = .init(out);
        defer aw.deinit();
        writeList(self, &aw.writer, start, view, q) catch return error.OutOfMemory;
        if (q.clear) {
            if (self.findReader(who)) |r| r.start = self.next_seq;
        }
        return aw.toOwnedSlice();
    }

    /// `browser.networkRequest` 의 결과 JSON(`out` 소유) — 모르는 번호·이 쪽에게 보이지 않는 번호는 `UnknownRequest`, 버려진 번호는 `Evicted`.
    pub fn detail(self: *Ring, out: std.mem.Allocator, who: Authorizer, view: View, seq: u64) DetailError![]u8 {
        const start = self.startFor(who);
        if (seq == 0 or seq >= self.next_seq or seq < start) return error.UnknownRequest;
        const e = self.entryBySeq(seq) orelse return error.Evicted;
        if (e.dropped != 0 or !topCovered(view, e) or hiddenIframe(view, e) or sharedServiceWorker(view, e)) return error.UnknownRequest;
        var aw: std.Io.Writer.Allocating = .init(out);
        defer aw.deinit();
        writeDetail(&aw.writer, e, view) catch return error.OutOfMemory;
        return aw.toOwnedSlice() catch error.OutOfMemory;
    }
};

// ── JSON ───────────────────────────────────────────────────────────────────────────────────────────────

fn stateName(s: State) []const u8 {
    return @tagName(s);
}

fn frameName(f: msg.NetFlags) []const u8 {
    if (f.main_frame) return "main";
    if (f.subframe) return "sub";
    return "none";
}

/// 주소를 보일 꼴로 — 사용자 정보는 이 읽는 쪽의 쿠키 권한이 그 호스트(`host` — sidecar 의 칸)를 덮을 때만(3 회차 D1 — 설정이 켜져 있어도,
/// 꺼졌으면 sidecar 가 이미 지웠다). sidecar 는 잘리는 주소에서 사용자 정보를 빼고 자르므로(codec 이 본다) 남은 `@` 는 권한 안에서 끝난다.
/// `buf` 를 쓸 수 있다.
fn shownUrl(view: View, url: []const u8, host: []const u8, buf: []u8) []const u8 {
    if (view.credentials(host)) return url;
    return policy.stripUserinfo(url, buf);
}

/// 응답 쪽(상태·MIME·크기·응답 헤더)을 보일 수 있는가 — 응답을 보낸 곳(마지막 홉의 호스트)이 덮인다.
fn responseVisible(view: View, e: *const Entry) bool {
    return view.covers(e.finalHost());
}

const Matcher = struct {
    fn matches(e: *const Entry, view: View, q: Query, url_buf: []u8) bool {
        if (q.types.len > 0) {
            const name = policy.resourceTypeName(e.resource_type);
            var any = false;
            for (q.types) |t| if (std.mem.eql(u8, t, name)) {
                any = true;
                break;
            };
            if (!any) return false;
        }
        if (q.method) |m| if (!std.ascii.eqlIgnoreCase(m, e.method)) return false;
        if (q.status != null or q.status_class != null) {
            // 숨긴 상태로는 거르지 않는다 — 거르기로 떠보지 못하게.
            if (!e.has_response or !responseVisible(view, e)) return false;
            if (q.status) |s| if (e.status != s) return false;
            if (q.status_class) |c| if (e.status / 100 != c) return false;
        }
        if (q.url_contains) |needle| {
            const shown = shownUrl(view, e.url, e.host, url_buf);
            if (std.ascii.indexOfIgnoreCase(shown, needle) == null) return false;
        }
        return true;
    }
};

fn writeList(ring: *Ring, w: *std.Io.Writer, start: u64, view: View, q: Query) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    var hidden_before: usize = 0;
    var dropped: u64 = 0;
    var iframes_hidden: usize = 0;
    var other_top_hidden: usize = 0;
    var sw_hidden: usize = 0;
    var url_buf: [msg.max_net_url_bytes]u8 = undefined;
    const page_size = @min(@max(q.page_size, 1), max_page_size);
    const skip = q.page * page_size;
    var matched: usize = 0;
    var written: usize = 0;
    var last_written: u64 = 0;
    try s.beginObject();
    try s.objectField("requests");
    try s.beginArray();
    var i = ring.entries.len;
    while (i > 0) {
        i -= 1;
        const e = ring.entries.atPtr(i);
        if (e.seq < start) {
            if (e.dropped == 0) hidden_before += 1;
            continue;
        }
        if (e.dropped != 0) {
            dropped += e.dropped;
            continue;
        }
        if (!Ring.topCovered(view, e)) {
            other_top_hidden += 1;
            continue;
        }
        if (Ring.hiddenIframe(view, e)) {
            iframes_hidden += 1;
            continue;
        }
        if (Ring.sharedServiceWorker(view, e)) {
            sw_hidden += 1;
            continue;
        }
        if (!Matcher.matches(e, view, q, &url_buf)) continue;
        // 커서는 줄을 고를 때만 — 숨김·버림 수는 쪽마다 같다.
        if (q.before_req) |b| if (e.seq >= b) continue;
        matched += 1;
        if (matched <= skip or written >= page_size) continue;
        written += 1;
        last_written = e.seq;
        try writeSummary(&s, e, view, &url_buf);
    }
    try s.endArray();
    try s.objectField("hidden_before_grant");
    try s.write(hidden_before);
    if (view.top_bound) {
        try s.objectField("hidden_other_site_pages");
        try s.write(other_top_hidden);
    }
    try s.objectField("dropped");
    try s.write(dropped);
    if (!view.full) {
        try s.objectField("cross_site_iframe_hidden");
        try s.write(iframes_hidden);
        try s.objectField("service_worker_shared_hidden");
        try s.write(sw_hidden);
    }
    try s.objectField("full_details");
    try s.write(view.full);
    if (matched > skip + written) {
        try s.objectField("next_page");
        try s.write(q.page + 1);
        // 커서 — 새 요청이 와도 다음 쪽이 밀리지 않는다(F7).
        if (written > 0) {
            try s.objectField("next_before_req");
            try s.write(last_written);
        }
    }
    try s.endObject();
}

fn writeCommon(s: *std.json.Stringify, e: *const Entry, view: View, url_buf: []u8) !void {
    try s.objectField("req");
    try s.write(e.seq);
    try s.objectField("method");
    try s.write(e.method);
    try s.objectField("url");
    try s.write(shownUrl(view, e.url, e.host, url_buf));
    if (e.flags.url_truncated) {
        try s.objectField("url_truncated");
        try s.write(true);
    }
    try s.objectField("type");
    try s.write(policy.resourceTypeName(e.resource_type));
    try s.objectField("state");
    try s.write(stateName(e.state));
    try s.objectField("start_ms");
    try s.write(e.start_ms);
    if (e.end_ms != 0) {
        try s.objectField("duration_ms");
        try s.write(e.end_ms -| e.start_ms);
    }
    if (view.otherSite(e.host)) {
        try s.objectField("other_site");
        try s.write(true);
    }
    if (e.engine_restarted) {
        try s.objectField("engine_restarted");
        try s.write(true);
    }
    if (e.flags.service_worker) {
        var ob: [msg.max_net_origin_bytes]u8 = undefined;
        var lb: [msg.max_net_origin_bytes + 32]u8 = undefined;
        const origin = policy.originOf(e.initiator, &ob);
        try s.objectField("service_worker");
        try s.write(std.fmt.bufPrint(&lb, "service worker of {s}", .{if (origin.len > 0) origin else e.initiator}) catch "service worker");
    }
    if (view.full and policy.crossSiteIframe(e.flags, e.resource_type, e.host, e.initiator, e.site)) {
        try s.objectField("cross_site_iframe");
        try s.write(true);
    }
}

fn writeSummary(s: *std.json.Stringify, e: *const Entry, view: View, url_buf: []u8) !void {
    try s.beginObject();
    try writeCommon(s, e, view, url_buf);
    if (responseVisible(view, e)) {
        if (e.has_response) {
            try s.objectField("status");
            try s.write(e.status);
            try s.objectField("mime");
            try s.write(e.mime);
        }
        if (e.state != .pending) {
            try s.objectField("size");
            try s.write(e.received);
        }
        if (e.state == .failed or e.state == .canceled) {
            try s.objectField("error_code");
            try s.write(e.error_code);
        }
        // 다시 시작은 서버의 답이 부른다(`Critical-CH`) — 리다이렉트 수처럼 응답을 보여도 될 때만(F8).
        if (e.restarted) {
            try s.objectField("restarted");
            try s.write(true);
        }
    }
    // 리다이렉트 수는 서버가 고른 것이다 — 설정이 꺼졌으면 덮이는 곳이 보낸 홉만 센다(F8·N7).
    const shown_hops = shownHopCount(e, view);
    if (shown_hops > 0) {
        try s.objectField("redirects");
        try s.write(shown_hops);
    }
    try s.endObject();
}

/// 헤더 목록 — 설정이 켜졌으면 그대로, 꺼졌으면 규칙대로(이름만인 것은 `redacted:true`). 자격 증명 헤더(`net_policy.credentialHeader`)는 이 읽는
/// 쪽의 쿠키 권한이 그 헤더를 보내거나 받은 호스트(`host`)를 덮을 때만 값 — 아니면 켜져 있어도 이름만이고 `needs_cookie_permission:true`(3 회차 D1).
/// 주소를 싣는 헤더(`Location`·`Refresh`·`Content-Location`·`Link`·`Referer`)의 값은 그 안 주소의 사용자 정보를 지운다 — 이 읽는 쪽의 쿠키
/// 권한이 **그 주소의 호스트**를 덮을 때만 둔다(4 회차 C1 — 주소 칸 `shownUrl` 과 같은 규칙, 끔이면 늘 지운다).
/// 보이지 않는 곳의 헤더는 이 함수를 부르지 않는다.
fn writeHeaders(s: *std.json.Stringify, h: Headers, view: View, host: []const u8) !void {
    try s.beginArray();
    var it = net_fields.HeaderIterator.init(h.block());
    var ob: [msg.max_net_url_bytes]u8 = undefined;
    var mb: [msg.max_net_headers_bytes]u8 = undefined;
    const full = view.full and !h.stripped;
    const creds = full and view.credentials(host);
    // 주소의 사용자 정보를 둘 수 있는 쿠키 권한 — 끔·덜어 낸 덩어리면 없다(`View.credentials` 와 같은 조건).
    const url_cookie_host = if (full) view.cookie_host else "";
    while (it.next()) |hd| {
        try s.beginObject();
        try s.objectField("name");
        try s.write(hd.name);
        const credential = policy.credentialHeader(hd.name);
        const rule: policy.HeaderRule = if (credential and !creds) .name_only else if (full) .value else policy.headerRule(hd.name);
        switch (rule) {
            .value, .covered_only => {
                try s.objectField("value");
                try s.write(policy.maskHeaderUserinfo(hd.name, hd.value, url_cookie_host, &mb));
            },
            .origin_only => {
                try s.objectField("value");
                try s.write(policy.originOf(hd.value, &ob));
            },
            .name_only => {
                try s.objectField("redacted");
                try s.write(true);
                if (credential and full) {
                    try s.objectField("needs_cookie_permission");
                    try s.write(true);
                }
            },
        }
        try s.endObject();
    }
    try s.endArray();
}

/// 목록에 보일 리다이렉트 수(F8·N7) — 설정이 켜졌으면 전부, 꺼졌으면 덮이는 곳이 보낸 홉만(덮이지 않는 요청은 0). 자세한 것을 버렸으면 처음
/// 홉(그 요청의 주소가 보냈다)만 안다 — 둘째부터는 세지 않는다.
fn shownHopCount(e: *const Entry, view: View) usize {
    if (e.redirects == 0 or !view.covers(e.host)) return 0;
    if (view.full) return e.redirects;
    if (e.detail_evicted or e.hops.items.len != e.redirects) return 1;
    var n: usize = 0;
    var from: []const u8 = e.host;
    for (e.hops.items) |h| {
        n += @intFromBool(view.covers(from));
        from = h.host;
    }
    return n;
}

/// 리다이렉트 홉 배열(`redirects`) — 덮이는 요청의 자세히에만(`writeDetail`). 덮이지 않는 곳이 보낸 홉은 칸째 없다(N7 — 그 서버의 사슬 길이도
/// 보이지 않게, 설정이 켜졌으면 모두 덮인다).
fn writeHops(s: *std.json.Stringify, e: *const Entry, view: View, url_buf: []u8) !void {
    try s.objectField("redirects");
    try s.beginArray();
    var from: []const u8 = e.host;
    for (e.hops.items) |h| {
        if (view.covers(from)) {
            try s.beginObject();
            try s.objectField("status");
            try s.write(h.status);
            try s.objectField("url");
            try s.write(shownUrl(view, h.url, h.host, url_buf));
            if (h.hsts) {
                try s.objectField("hsts");
                try s.write(true);
            }
            try s.objectField("headers");
            try writeHeaders(s, h.headers, view, from); // 그 홉의 응답(Set-Cookie)은 앞 주소가 보냈다
            try s.endObject();
        }
        from = h.host;
    }
    try s.endArray();
}

fn writeDetail(w: *std.Io.Writer, e: *const Entry, view: View) !void {
    var s: std.json.Stringify = .{ .writer = w, .options = .{} };
    var url_buf: [msg.max_net_url_bytes]u8 = undefined;
    try s.beginObject();
    try writeCommon(&s, e, view, &url_buf);
    try s.objectField("initiator");
    try s.write(e.initiator);
    try s.objectField("frame");
    try s.write(frameName(e.flags));
    if (e.end_ms != 0) {
        try s.objectField("end_ms");
        try s.write(e.end_ms);
    }
    const resp_ok = responseVisible(view, e);
    if (resp_ok) {
        if (e.has_response) {
            try s.objectField("status");
            try s.write(e.status);
            try s.objectField("mime");
            try s.write(e.mime);
            if (e.response_hsts) {
                try s.objectField("hsts");
                try s.write(true);
            }
        }
        if (e.state != .pending) {
            try s.objectField("size");
            try s.write(e.received);
        }
        if (e.state == .failed or e.state == .canceled) {
            try s.objectField("error_code");
            try s.write(e.error_code);
        }
        // 다시 시작은 서버의 답이 부른다(`Critical-CH`) — 리다이렉트 수처럼 응답을 보여도 될 때만(F8).
        if (e.restarted) {
            try s.objectField("restarted");
            try s.write(true);
        }
    }
    if (e.detail_evicted) {
        try s.objectField("detail_evicted");
        try s.write(true);
    } else {
        // 리다이렉트 홉 — 그 홉을 보낸 곳(앞 주소)이 덮일 때만 상태·대상·헤더. 덮이지 않는 요청이면 홉 수도 서버가 고른 것이라 칸째 없다(F8).
        if (view.covers(e.host)) try writeHops(&s, e, view, &url_buf);
        // 요청 헤더는 그 요청의 주소가 덮일 때만(다른 사이트에 보낸 쿠키다).
        if (view.covers(e.host)) {
            try s.objectField("request_headers");
            try writeHeaders(&s, e.request_headers, view, e.host);
            if (e.request_headers.truncated) {
                try s.objectField("request_headers_truncated");
                try s.write(true);
            }
        }
        if (resp_ok and e.has_response) {
            try s.objectField("response_headers");
            try writeHeaders(&s, e.response_headers, view, e.finalHost());
            if (e.response_headers.truncated) {
                try s.objectField("response_headers_truncated");
                try s.write(true);
            }
        }
    }
    try s.objectField("body_state");
    try s.write("not_recorded");
    try s.endObject();
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const T = struct {
    ring: Ring = .{},
    budget: Budget = .{},

    fn deinit(self: *T) void {
        self.ring.deinit(testing.allocator, &self.budget);
    }

    /// `host` 를 주지 않으면 주소에서 읽는다(시험의 편의 — sidecar 가 온 주소에서 읽어 싣는 칸을 흉내 낸다. 잘린 주소의 시험은 칸을 직접 준다).
    fn begin(self: *T, request: u64, url: []const u8, opts: struct { flags: msg.NetFlags = .{}, rt: u8 = 13, initiator: []const u8 = "", site: []const u8 = "", headers: msg.NetHeaderBlock = .{}, top: []const u8 = "", sw_tabs: []const u64 = &.{}, host: ?[]const u8 = null }) !void {
        const host = opts.host orelse policy.hostOfUrl(url) orelse "";
        try self.ring.begin(testing.allocator, &self.budget, .{ .browser = 1, .request = request, .flags = opts.flags, .resource_type = opts.rt, .time_ms = 1000 + request, .url = url, .host = host, .initiator = opts.initiator, .site = opts.site, .headers = opts.headers }, .{ .top_host = opts.top, .sw_tabs = opts.sw_tabs });
    }

    /// 리다이렉트 홉 하나(호스트 칸은 주소에서 — `begin` 과 같은 편의).
    fn redirect(self: *T, request: u64, status: u16, url: []const u8, opts: struct { flags: msg.NetHopFlags = .{}, headers: msg.NetHeaderBlock = .{} }) !void {
        try self.ring.redirect(testing.allocator, &self.budget, .{ .browser = 1, .request = request, .status = status, .url = url, .host = policy.hostOfUrl(url) orelse "", .flags = opts.flags, .headers = opts.headers });
    }

    fn respond(self: *T, request: u64, status: u16, headers: msg.NetHeaderBlock) !void {
        try self.ring.response(testing.allocator, &self.budget, .{ .browser = 1, .request = request, .status = status, .mime = "text/html", .headers = headers, .time_ms = 2000 + request });
        self.ring.end(.{ .browser = 1, .request = request, .received = 10, .time_ms = 3000 + request });
    }

    fn listJson(self: *T, who: Authorizer, view: View, q: Query) !std.json.Parsed(std.json.Value) {
        const json = try self.ring.list(testing.allocator, who, view, q);
        defer testing.allocator.free(json);
        return std.json.parseFromSlice(std.json.Value, testing.allocator, json, .{});
    }

    fn reqs(self: *T, who: Authorizer, view: View) ![]u64 {
        const p = try self.listJson(who, view, .{ .page_size = max_page_size });
        defer p.deinit();
        const arr = p.value.object.get("requests").?.array.items;
        const out = try testing.allocator.alloc(u64, arr.len);
        for (arr, 0..) |r, i| out[i] = @intCast(r.object.get("req").?.integer);
        return out;
    }
};

fn expectReqs(t: *T, who: Authorizer, view: View, want: []const u64) !void {
    const got = try t.reqs(who, view);
    defer testing.allocator.free(got);
    try testing.expectEqualSlices(u64, want, got);
}

test "W9d①: 요청은 새것부터, 리다이렉트는 한 요청의 홉, 401 재시도는 뒤의 응답이 이긴다, 끝나면 크기와 걸린 시간" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    try t.begin(11, "https://a.test/", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0 });
    try t.redirect(11, 301, "https://b.test/", .{});
    try t.redirect(11, 307, "https://b.test/x", .{ .flags = .{ .hsts = true } });
    try t.ring.response(testing.allocator, &t.budget, .{ .browser = 1, .request = 11, .status = 401, .mime = "text/plain" });
    try t.ring.response(testing.allocator, &t.budget, .{ .browser = 1, .request = 11, .status = 200, .mime = "text/html" });
    t.ring.end(.{ .browser = 1, .request = 11, .received = 1234, .time_ms = 1050 });
    try t.begin(12, "https://a.test/app.js", .{ .rt = 3 });
    const p = try t.listJson(7, .{}, .{});
    defer p.deinit();
    const arr = p.value.object.get("requests").?.array.items;
    try testing.expectEqual(@as(usize, 2), arr.len);
    try testing.expectEqual(@as(i64, 2), arr[0].object.get("req").?.integer); // 새것부터
    try testing.expectEqualStrings("pending", arr[0].object.get("state").?.string);
    const nav = arr[1].object;
    try testing.expectEqual(@as(i64, 200), nav.get("status").?.integer);
    try testing.expectEqual(@as(i64, 2), nav.get("redirects").?.integer);
    try testing.expectEqual(@as(i64, 1234), nav.get("size").?.integer);
    try testing.expectEqual(@as(i64, 39), nav.get("duration_ms").?.integer);
    try testing.expectEqualStrings("document", nav.get("type").?.string);
    const d = try t.ring.detail(testing.allocator, 7, .{}, 1);
    defer testing.allocator.free(d);
    const dp = try std.json.parseFromSlice(std.json.Value, testing.allocator, d, .{});
    defer dp.deinit();
    const hops = dp.value.object.get("redirects").?.array.items;
    try testing.expectEqual(@as(usize, 2), hops.len);
    try testing.expectEqualStrings("https://b.test/x", hops[1].object.get("url").?.string);
    try testing.expect(hops[1].object.get("hsts").?.bool);
    try testing.expectEqualStrings("not_recorded", dp.value.object.get("body_state").?.string);
}

test "W9d①: 읽는 쪽마다 시작점 — 사용자 탭은 grant 뒤만(그 전은 숨김 수), 에이전트 탭은 태어날 때부터, 사용자가 첫 읽기 전에 몰면 첫 읽기 때부터, 모르는 쪽은 처음 읽을 때부터" {
    var t: T = .{};
    defer t.deinit();
    // 에이전트가 연 탭 — 태어날 때 grant 7.
    t.ring.noteReader(7, true);
    try t.begin(1, "https://a.test/1", .{});
    try t.begin(2, "https://a.test/2", .{});
    // 다른 pane 이 모달로 허락받았다(grant 8) — 그 뒤의 것만.
    t.ring.noteReader(8, false);
    try t.begin(3, "https://a.test/3", .{});
    try expectReqs(&t, 7, .{}, &.{ 3, 2, 1 });
    try expectReqs(&t, 8, .{}, &.{3});
    {
        const p = try t.listJson(8, .{}, .{});
        defer p.deinit();
        try testing.expectEqual(@as(i64, 2), p.value.object.get("hidden_before_grant").?.integer);
    }
    // 모르는 쪽(9 — grant 를 거치지 않은 읽기, 방어) — 처음 읽을 때부터: 아무것도 없고, 그 뒤의 것은 본다.
    try expectReqs(&t, 9, .{}, &.{});
    try t.begin(4, "https://a.test/4", .{});
    try expectReqs(&t, 9, .{}, &.{4});
    // 0(모름)은 언제나 지금부터.
    try expectReqs(&t, 0, .{}, &.{});

    // 사용자가 첫 읽기 전에 몰았다 — 첫 읽기는 그때부터(사용자가 그 탭으로 간 은행의 요청이 보이지 않는다).
    var u: T = .{};
    defer u.deinit();
    u.ring.noteReader(7, true);
    try u.begin(1, "https://agent.test/", .{});
    u.ring.userDrove();
    try u.begin(2, "https://bank.test/login", .{});
    try expectReqs(&u, 7, .{}, &.{});
    {
        const p = try u.listJson(7, .{}, .{});
        defer p.deinit();
        try testing.expectEqual(@as(i64, 2), p.value.object.get("hidden_before_grant").?.integer);
    }
    try u.begin(3, "https://agent.test/next", .{});
    try expectReqs(&u, 7, .{}, &.{3});
    // 한 번 읽힌 뒤에는 몰아도 그대로다.
    u.ring.userDrove();
    try u.begin(4, "https://x.test/", .{});
    try expectReqs(&u, 7, .{}, &.{ 4, 3 });
    // 사용자가 몰지 않았으면 태어날 때부터 다.
    var a: T = .{};
    defer a.deinit();
    a.ring.noteReader(7, true);
    try a.begin(1, "https://agent.test/", .{});
    try a.begin(2, "https://agent.test/login", .{});
    try expectReqs(&a, 7, .{}, &.{ 2, 1 });
}

test "W9d①: clear 는 그 읽는 쪽만 지금으로 옮긴다, 철회한 쪽은 다시 허락받으면 그때부터, wipe 는 모두 지우고 번호는 이어 간다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, false);
    t.ring.noteReader(8, false);
    try t.begin(1, "https://a.test/1", .{});
    {
        const j = try t.ring.list(testing.allocator, 7, .{}, .{ .clear = true });
        testing.allocator.free(j);
    }
    try expectReqs(&t, 7, .{}, &.{});
    try expectReqs(&t, 8, .{}, &.{1});
    t.ring.removeReader(8);
    try t.begin(2, "https://a.test/2", .{});
    t.ring.noteReader(8, false); // 다시 허락
    try expectReqs(&t, 8, .{}, &.{});
    t.ring.wipe(testing.allocator, &t.budget);
    try testing.expectEqual(@as(usize, 0), t.budget.bytes);
    t.ring.noteReader(7, false);
    try t.begin(3, "https://a.test/3", .{});
    try expectReqs(&t, 7, .{}, &.{3}); // 번호는 3 — 지운 번호를 다시 쓰지 않는다
    try testing.expectError(error.UnknownRequest, t.ring.detail(testing.allocator, 7, .{}, 1)); // 그 쪽에게 시작점 앞
    try testing.expectError(error.UnknownRequest, t.ring.detail(testing.allocator, 7, .{}, 99));
}

test "W9d①: 상한 — 요약이 넘치면 오래된 요청부터 버리고(그 번호는 Evicted), 자세한 것이 넘치면 헤더·홉만 버린다, 앱 예산은 0 으로 돌아온다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    const long = "https://a.test/" ++ "x" ** 1900;
    var n: u64 = 0;
    while (t.ring.summary_bytes + 2100 <= max_summary_bytes) : (n += 1) try t.begin(n + 1, long, .{});
    try t.begin(n + 1, long, .{});
    try t.begin(n + 2, long, .{});
    try testing.expect(t.ring.summary_bytes <= max_summary_bytes);
    try testing.expectError(error.Evicted, t.ring.detail(testing.allocator, 7, .{}, 1));
    // 자세한 것: 8 KiB 헤더를 넘치게.
    var hb: net_fields.HeaderBuilder = .{};
    _ = hb.add("x-big", "v" ** 8000);
    var d: T = .{};
    defer d.deinit();
    d.ring.noteReader(7, true);
    for (1..200) |i| try d.begin(i, "https://a.test/", .{ .headers = hb.block() });
    try testing.expect(d.ring.detail_bytes <= max_detail_bytes);
    const j = try d.ring.detail(testing.allocator, 7, .{}, 1);
    defer testing.allocator.free(j);
    try testing.expect(std.mem.indexOf(u8, j, "\"detail_evicted\":true") != null);
    var sum: usize = 0;
    var it = d.ring.entries.iterator();
    while (it.nextPtr()) |e| sum += e.summary_bytes + e.detail_bytes;
    try testing.expectEqual(sum, d.budget.bytes);
    // 앱 예산 — 다른 탭이 다 쓰면 이 탭은 제 것을 버려 자리를 내고, 낼 것이 없으면 적지 못한 수를 표지로 남긴다.
    var g: T = .{ .budget = .{ .cap = 4096, .bytes = 0 } };
    defer g.deinit();
    g.ring.noteReader(7, true);
    g.budget.bytes = 4096; // 다른 탭이 다 썼다
    try g.begin(1, "https://a.test/", .{});
    try testing.expectEqual(@as(usize, 0), g.ring.entries.len);
    g.budget.bytes = 0;
    try g.begin(2, "https://a.test/2", .{});
    const p = try g.listJson(7, .{}, .{});
    defer p.deinit();
    try testing.expectEqual(@as(i64, 1), p.value.object.get("dropped").?.integer);
}

test "W9d①: syncReaders — 사라진 grant 의 읽는 쪽은 빠지고(다시 들어오면 그때부터), 새 grant 는 지금부터·태어날 때의 것은 처음부터, 읽어서 생긴 모르는 쪽은 남는다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.syncReaders(&.{.{ .who = 7, .birth = true }});
    try t.begin(1, "https://a.test/1", .{});
    try expectReqs(&t, 9, .{}, &.{}); // 처음 읽어 생긴 모르는 쪽
    try t.begin(2, "https://a.test/2", .{});
    t.ring.syncReaders(&.{ .{ .who = 7, .birth = true }, .{ .who = 8 } });
    try t.begin(3, "https://a.test/3", .{});
    try expectReqs(&t, 7, .{}, &.{ 3, 2, 1 });
    try expectReqs(&t, 8, .{}, &.{3});
    try expectReqs(&t, 9, .{}, &.{ 3, 2 });
    t.ring.syncReaders(&.{.{ .who = 8 }}); // 7 철회
    try expectReqs(&t, 9, .{}, &.{ 3, 2 });
    t.ring.syncReaders(&.{ .{ .who = 8 }, .{ .who = 7, .birth = true } }); // 7 이 다시 — 이제 태어날 때가 아니라 지금부터
    try expectReqs(&t, 7, .{}, &.{});
}

test "W9d①: sidecar 가 넘긴 수는 표지로 — 잇단 표지는 합치고, 읽는 쪽의 시작점 뒤 것만 센다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    try t.ring.addDropped(testing.allocator, &t.budget, 3);
    try t.ring.addDropped(testing.allocator, &t.budget, 2);
    try t.begin(1, "https://a.test/", .{});
    t.ring.noteReader(8, false);
    try t.ring.addDropped(testing.allocator, &t.budget, 4);
    const p7 = try t.listJson(7, .{}, .{});
    defer p7.deinit();
    try testing.expectEqual(@as(i64, 9), p7.value.object.get("dropped").?.integer);
    const p8 = try t.listJson(8, .{}, .{});
    defer p8.deinit();
    try testing.expectEqual(@as(i64, 4), p8.value.object.get("dropped").?.integer);
    try testing.expectEqual(@as(i64, 1), p8.value.object.get("hidden_before_grant").?.integer);
}

test "W9d①: 보이는 칸의 판 — 설정 켬·끔 × 덮임·다른 사이트 × 다른 사이트 iframe × 서비스 워커" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    var req_h: net_fields.HeaderBuilder = .{};
    _ = req_h.add("Cookie", "sid=secret");
    _ = req_h.add("Referer", "https://u:p@app.test/path?q=1");
    _ = req_h.add("Accept", "text/html");
    var resp_h: net_fields.HeaderBuilder = .{};
    _ = resp_h.add("Set-Cookie", "sid=new");
    _ = resp_h.add("Content-Type", "text/html");
    // 1: 덮이는 호스트(사용자 정보가 든 주소), 2: 다른 사이트, 3: 다른 사이트 iframe 안의 요청, 4: 서비스 워커, 5: 덮이는 곳에서 다른 사이트로 가는 리다이렉트
    try t.begin(1, "https://user:pw@app.test/a", .{ .flags = .{ .main_frame = true }, .site = "app.test", .initiator = "https://app.test", .headers = req_h.block() });
    try t.respond(1, 200, resp_h.block());
    try t.begin(2, "https://ads.test/pixel", .{ .flags = .{ .main_frame = true }, .site = "app.test", .initiator = "https://app.test", .headers = req_h.block() });
    try t.respond(2, 204, resp_h.block());
    try t.begin(3, "https://widget.test/api", .{ .flags = .{ .subframe = true }, .site = "app.test", .initiator = "https://widget.test", .headers = req_h.block() });
    try t.respond(3, 200, resp_h.block());
    try t.begin(4, "https://app.test/sw-fetch", .{ .flags = .{ .service_worker = true }, .initiator = "https://app.test" });
    try t.respond(4, 200, .{});
    try t.begin(5, "https://app.test/out", .{ .flags = .{ .main_frame = true }, .site = "app.test", .initiator = "https://app.test" });
    try t.redirect(5, 302, "https://sso.test/login?code=1", .{});
    try t.redirect(5, 302, "https://app.test/back", .{});
    try t.respond(5, 200, .{});

    const on: View = .{ .full = true, .grant_host = "app.test", .cookie_host = "app.test" };
    const off: View = .{ .full = false, .grant_host = "app.test" };
    // 켬(이 사이트의 쿠키 권한도 쥔 읽는 쪽 — 3 회차 D1): 다 보인다 — 이 사이트의 쿠키 값·사용자 정보, 다른 사이트의 상태, iframe 의 요청(표시와 함께).
    {
        const p = try t.listJson(7, on, .{});
        defer p.deinit();
        const arr = p.value.object.get("requests").?.array.items;
        try testing.expectEqual(@as(usize, 5), arr.len);
        try testing.expectEqualStrings("https://user:pw@app.test/a", arr[4].object.get("url").?.string);
        try testing.expectEqual(@as(i64, 204), arr[3].object.get("status").?.integer);
        try testing.expect(arr[3].object.get("other_site").?.bool);
        try testing.expect(arr[2].object.get("cross_site_iframe").?.bool);
        try testing.expectEqualStrings("service worker of https://app.test", arr[1].object.get("service_worker").?.string);
        const d = try t.ring.detail(testing.allocator, 7, on, 1);
        defer testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, d, "\"value\":\"sid=secret\"") != null);
        try testing.expect(std.mem.indexOf(u8, d, "\"value\":\"sid=new\"") != null);
        const d2 = try t.ring.detail(testing.allocator, 7, on, 2);
        defer testing.allocator.free(d2);
        try testing.expect(std.mem.indexOf(u8, d2, "sid=secret") == null); // 다른 사이트에 보낸 쿠키는 그 사이트의 쿠키 권한이 있어야(3 회차 D1)
        try testing.expect(std.mem.indexOf(u8, d2, "{\"name\":\"Cookie\",\"redacted\":true,\"needs_cookie_permission\":true}") != null);
        try testing.expect(std.mem.indexOf(u8, d2, "{\"name\":\"Accept\",\"value\":\"text/html\"}") != null); // 그 밖의 헤더는 켬대로
    }
    // 끔: 덮이는 곳은 상태·허용 목록 값, 쿠키는 이름만, Referer 는 출처, 사용자 정보는 지움 — 다른 사이트는 페이지가 고른 칸만,
    // iframe 의 요청은 수만, 리다이렉트는 덮이는 곳이 보낸 홉만.
    {
        const p = try t.listJson(7, off, .{});
        defer p.deinit();
        const o = p.value.object;
        const arr = o.get("requests").?.array.items;
        try testing.expectEqual(@as(usize, 4), arr.len);
        try testing.expectEqual(@as(i64, 1), o.get("cross_site_iframe_hidden").?.integer);
        try testing.expectEqualStrings("https://app.test/a", arr[3].object.get("url").?.string);
        try testing.expectEqual(@as(i64, 200), arr[3].object.get("status").?.integer);
        const ads = arr[2].object;
        try testing.expect(ads.get("other_site").?.bool);
        try testing.expect(ads.get("status") == null and ads.get("size") == null and ads.get("mime") == null);
        try testing.expectEqualStrings("https://ads.test/pixel", ads.get("url").?.string);
        try testing.expectEqual(@as(i64, 5), arr[0].object.get("req").?.integer);
        try testing.expectEqual(@as(i64, 1), arr[0].object.get("redirects").?.integer); // sso.test 가 보낸 홉은 세지 않는다(적대 리뷰 2 회차 N7)
        const d = try t.ring.detail(testing.allocator, 7, off, 1);
        defer testing.allocator.free(d);
        try testing.expect(std.mem.indexOf(u8, d, "secret") == null);
        try testing.expect(std.mem.indexOf(u8, d, "sid=new") == null);
        try testing.expect(std.mem.indexOf(u8, d, "{\"name\":\"Cookie\",\"redacted\":true}") != null);
        try testing.expect(std.mem.indexOf(u8, d, "{\"name\":\"Referer\",\"value\":\"https://app.test\"}") != null);
        try testing.expect(std.mem.indexOf(u8, d, "{\"name\":\"Accept\",\"value\":\"text/html\"}") != null);
        try testing.expect(std.mem.indexOf(u8, d, "user:pw") == null);
        const d2 = try t.ring.detail(testing.allocator, 7, off, 2);
        defer testing.allocator.free(d2);
        try testing.expect(std.mem.indexOf(u8, d2, "request_headers") == null);
        try testing.expect(std.mem.indexOf(u8, d2, "response_headers") == null);
        try testing.expect(std.mem.indexOf(u8, d2, "\"status\"") == null);
        try testing.expectError(error.UnknownRequest, t.ring.detail(testing.allocator, 7, off, 3)); // 수만 — 자세히도 없다
        const d5 = try t.ring.detail(testing.allocator, 7, off, 5);
        defer testing.allocator.free(d5);
        const dp = try std.json.parseFromSlice(std.json.Value, testing.allocator, d5, .{});
        defer dp.deinit();
        const hops = dp.value.object.get("redirects").?.array.items;
        try testing.expectEqual(@as(usize, 1), hops.len); // sso.test 가 보낸 홉은 칸째 없다(적대 리뷰 2 회차 N7)
        try testing.expectEqualStrings("https://sso.test/login?code=1", hops[0].object.get("url").?.string); // app.test 가 보낸 홉
        try testing.expectEqual(@as(i64, 200), dp.value.object.get("status").?.integer); // 마지막 응답은 app.test
    }
    // 거르기는 투영된 값으로 — 끔이면 숨긴 상태로 걸리지 않고, 지운 사용자 정보로도 걸리지 않는다.
    {
        const p = try t.listJson(7, off, .{ .status = 204 });
        defer p.deinit();
        try testing.expectEqual(@as(usize, 0), p.value.object.get("requests").?.array.items.len);
        const p2 = try t.listJson(7, off, .{ .url_contains = "user:pw" });
        defer p2.deinit();
        try testing.expectEqual(@as(usize, 0), p2.value.object.get("requests").?.array.items.len);
        const p3 = try t.listJson(7, on, .{ .status = 204 });
        defer p3.deinit();
        try testing.expectEqual(@as(usize, 1), p3.value.object.get("requests").?.array.items.len);
    }
}

test "W9d①: 쪽 나누기 — 기본 50, 최대 200, next_page, 종류·메서드·상태 범주·주소 거르기" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    for (1..121) |i| {
        var ub: [64]u8 = undefined;
        try t.begin(i, try std.fmt.bufPrint(&ub, "https://a.test/item/{d}", .{i}), .{ .rt = if (i % 2 == 0) 13 else 4 });
        try t.respond(i, if (i % 3 == 0) 404 else 200, .{});
    }
    const first = try t.listJson(7, .{}, .{});
    defer first.deinit();
    try testing.expectEqual(@as(usize, 50), first.value.object.get("requests").?.array.items.len);
    try testing.expectEqual(@as(i64, 1), first.value.object.get("next_page").?.integer);
    const last = try t.listJson(7, .{}, .{ .page = 2 });
    defer last.deinit();
    try testing.expectEqual(@as(usize, 20), last.value.object.get("requests").?.array.items.len);
    try testing.expect(last.value.object.get("next_page") == null);
    const big = try t.listJson(7, .{}, .{ .page_size = 1000 });
    defer big.deinit();
    try testing.expectEqual(@as(usize, 120), big.value.object.get("requests").?.array.items.len);
    const types = [_][]const u8{"xhr"};
    const x = try t.listJson(7, .{}, .{ .types = &types, .status_class = 4, .page_size = 200 });
    defer x.deinit();
    try testing.expectEqual(@as(usize, 20), x.value.object.get("requests").?.array.items.len); // 짝수 중 3 의 배수
    const u = try t.listJson(7, .{}, .{ .url_contains = "ITEM/7", .method = "get" });
    defer u.deinit();
    try testing.expectEqual(@as(usize, 11), u.value.object.get("requests").?.array.items.len); // 7, 70..79
}

// ── W9d① 적대 리뷰 1 회차 재현(리뷰가 남긴 R9d1-L* 를 붙여 실패를 본 뒤 고쳤다 — obs 였던 것은 정한 동작을 단언한다) ──────────────────────

test "W9d① 적대 리뷰 1 회차 재현 L1: 쪽을 읽는 사이 새 요청이 와도 before_req 커서로 넘긴 다음 쪽은 앞 쪽과 겹치지 않는다(page 번호는 밀린다)" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    for (1..61) |i| try t.begin(i, "https://a.test/x", .{});
    var seen = std.AutoHashMap(u64, void).init(testing.allocator);
    defer seen.deinit();
    var cursor: u64 = 0;
    {
        const p = try t.listJson(7, .{}, .{ .page = 0, .page_size = 50 });
        defer p.deinit();
        for (p.value.object.get("requests").?.array.items) |r| try seen.put(@intCast(r.object.get("req").?.integer), {});
        try testing.expectEqual(@as(i64, 1), p.value.object.get("next_page").?.integer);
        cursor = @intCast(p.value.object.get("next_before_req").?.integer);
        try testing.expectEqual(@as(u64, 11), cursor); // 60..11 을 보였다
    }
    // 에이전트가 앞 쪽을 읽는 사이 폴링 페이지가 열 개를 더 보냈다
    for (61..71) |i| try t.begin(i, "https://a.test/poll", .{});
    var dup: usize = 0;
    var got: usize = 0;
    {
        const p = try t.listJson(7, .{}, .{ .before_req = cursor, .page_size = 50 });
        defer p.deinit();
        for (p.value.object.get("requests").?.array.items) |r| {
            got += 1;
            if (seen.contains(@intCast(r.object.get("req").?.integer))) dup += 1;
        }
        try testing.expect(p.value.object.get("next_before_req") == null); // 끝까지 읽었다
        try testing.expect(p.value.object.get("next_page") == null);
        try testing.expectEqual(@as(i64, 0), p.value.object.get("hidden_before_grant").?.integer); // 수는 커서와 무관
    }
    try testing.expectEqual(@as(usize, 10), got); // 10..1
    try testing.expectEqual(@as(usize, 0), dup);
    // page 번호로 읽으면 여전히 밀린다(호환으로 남긴다 — 문서가 커서를 권한다).
    const p1 = try t.listJson(7, .{}, .{ .page = 1, .page_size = 50 });
    defer p1.deinit();
    try testing.expectEqual(@as(usize, 20), p1.value.object.get("requests").?.array.items.len);
}

test "W9d① 적대 리뷰 1 회차 재현 L2: 설정이 꺼졌으면 덮이지 않는 요청의 리다이렉트 수(서버가 고른 것)를 목록에도 자세히의 홉 표지로도 보이지 않는다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    try t.begin(1, "https://other.test/a", .{ .flags = .{ .main_frame = true }, .site = "app.test", .initiator = "https://app.test" });
    try t.redirect(1, 302, "https://other.test/login", .{});
    try t.redirect(1, 302, "https://other.test/denied", .{});
    try t.respond(1, 200, .{});
    const off: View = .{ .full = false, .grant_host = "app.test" };
    const p = try t.listJson(7, off, .{});
    defer p.deinit();
    const row = p.value.object.get("requests").?.array.items[0].object;
    try testing.expect(row.get("redirects") == null);
    const d = try t.ring.detail(testing.allocator, 7, off, 1);
    defer testing.allocator.free(d);
    try testing.expect(std.mem.indexOf(u8, d, "\"redirects\"") == null);
    try testing.expect(std.mem.indexOf(u8, d, "other_site\":true}") == null); // 홉 표지 없음(요청 자체의 other_site 만)
    // 켜져 있으면 그대로 둘.
    const on = try t.listJson(7, .{ .full = true, .grant_host = "app.test" }, .{});
    defer on.deinit();
    try testing.expectEqual(@as(i64, 2), on.value.object.get("requests").?.array.items[0].object.get("redirects").?.integer);
}

test "W9d① 적대 리뷰 1 회차 재현 L3: 상한에 닿은 탭에서 오래된 요청을 버려도 남은 요청은 제자리다(배열을 밀지 않는다 — deque)" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    var i: u64 = 1;
    while (t.ring.summary_bytes + 300 < max_summary_bytes) : (i += 1) try t.begin(i, "https://a.test/api/poll?x=1", .{});
    // 상한에 닿을 때까지 몇 번 더 — 그 뒤로는 begin 마다 앞의 것을 버린다.
    for (0..50) |_| {
        try t.begin(i, "https://a.test/api/poll?x=1", .{});
        i += 1;
    }
    const n_at_cap = t.ring.entries.len;
    const newest = t.ring.entries.backPtr().?;
    const newest_seq = newest.seq;
    var k: u64 = 0;
    while (k < 2_000) : (k += 1) try t.begin(i + k, "https://a.test/api/poll?x=1", .{});
    try testing.expectEqual(n_at_cap, t.ring.entries.len); // 상한에서 하나 넣고 하나 버린다
    // 앞을 2000 번 버린 뒤에도 그 요청은 같은 자리에 있다 — 앞에서 밀었으면 자리가 옮겨졌다.
    try testing.expectEqual(newest, t.ring.entryBySeq(newest_seq).?);
}

test "W9d① 적대 리뷰 1 회차 F2: 맨 위 문서 호스트 — 주 프레임 문서는 그 주소, 그 밖은 첫 사이트와 app 의 주소를 맞춰 본다" {
    const nav: msg.NetBegin = .{ .browser = 1, .request = 1, .flags = .{ .main_frame = true, .navigation = true }, .resource_type = 0, .url = "https://bank.test/login", .site = "bank.test", .host = "bank.test" };
    try testing.expectEqualStrings("bank.test", topHostOf(nav, "a.test")); // 이동 요청은 그것이 여는 문서(sidecar 의 호스트 칸 — 3 회차 T1)
    // 잘린 주소 글은 호스트를 속일 수 있다 — 칸이 이긴다(3 회차 T1).
    const cut: msg.NetBegin = .{ .browser = 1, .request = 4, .flags = .{ .main_frame = true, .navigation = true, .url_truncated = true }, .resource_type = 0, .url = "https://yyyy.a.test", .site = "bank.test", .host = "bank.test" };
    try testing.expectEqualStrings("bank.test", topHostOf(cut, "a.test"));
    const sub: msg.NetBegin = .{ .browser = 1, .request = 2, .flags = .{ .main_frame = true }, .resource_type = 13, .url = "https://api.bank.test/x", .site = "bank.test" };
    try testing.expectEqualStrings("www.bank.test", topHostOf(sub, "www.bank.test")); // 같은 사이트 — 더 좁은 app 의 호스트
    try testing.expectEqualStrings("bank.test", topHostOf(sub, "a.test")); // 엇갈림 — 요청이 말한 사이트
    try testing.expectEqualStrings("bank.test", topHostOf(sub, "")); // app 이 아직 모른다
    const iframe: msg.NetBegin = .{ .browser = 1, .request = 3, .flags = .{ .subframe = true }, .resource_type = 13, .url = "https://ads.test/p", .site = "" };
    try testing.expectEqualStrings("a.test", topHostOf(iframe, "a.test")); // 다른 사이트 iframe 안 — 첫 사이트가 비어 온다
}

test "W9d① 적대 리뷰 1 회차 F2: 사이트에 묶인 읽는 쪽은 탭이 그 사이트가 아닐 때의 요청을 못 본다(설정과 무관 — 수만), 어느 호스트든 읽는 쪽은 다 본다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    var bank_h: net_fields.HeaderBuilder = .{};
    _ = bank_h.add("Cookie", "bank=SECRET1");
    try t.begin(1, "https://a.test/", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "a.test", .top = "" });
    try t.begin(2, "https://a.test/api", .{ .flags = .{ .main_frame = true }, .site = "a.test", .top = "a.test" });
    // 사용자가 그 탭으로 은행에 갔다 — 이동과 그 문서의 요청(그 문서 안의 a.test 이미지도 은행 문서에서 났다).
    try t.begin(3, "https://bank.test/login", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "bank.test", .top = "a.test", .headers = bank_h.block() });
    try t.begin(4, "https://bank.test/api", .{ .flags = .{ .main_frame = true }, .site = "bank.test", .top = "bank.test", .headers = bank_h.block() });
    try t.begin(5, "https://a.test/pixel.png", .{ .flags = .{ .main_frame = true }, .rt = 4, .site = "bank.test", .top = "bank.test" });
    // a.test 로 돌아왔다.
    try t.begin(6, "https://a.test/back", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "a.test", .top = "bank.test" });
    try t.begin(7, "https://bank.test/widget.js", .{ .flags = .{ .main_frame = true }, .rt = 3, .site = "a.test", .top = "a.test" }); // a.test 문서가 보낸 다른 사이트 요청
    // a.test 에서 시작했지만 은행으로 리다이렉트된 이동 — 그 문서는 은행이다.
    try t.begin(8, "https://a.test/sso", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "a.test", .top = "a.test" });
    try t.redirect(8, 302, "https://bank.test/sso", .{});
    for ([_]bool{ true, false }) |full| {
        const bound: View = .{ .full = full, .grant_host = "a.test", .top_bound = true };
        try expectReqs(&t, 7, bound, &.{ 7, 6, 2, 1 });
        const p = try t.listJson(7, bound, .{});
        defer p.deinit();
        try testing.expectEqual(@as(i64, 4), p.value.object.get("hidden_other_site_pages").?.integer);
        for ([_]u64{ 3, 4, 5, 8 }) |req| try testing.expectError(error.UnknownRequest, t.ring.detail(testing.allocator, 7, bound, req));
    }
    // 어느 호스트든(에이전트 탭의 태어날 때 grant) — 다 보이고 그 수 칸도 없다.
    try expectReqs(&t, 7, .{ .full = true }, &.{ 8, 7, 6, 5, 4, 3, 2, 1 });
    const any = try t.listJson(7, .{ .full = true }, .{});
    defer any.deinit();
    try testing.expect(any.value.object.get("hidden_other_site_pages") == null);
    // 은행에 묶인 읽는 쪽에게는 거꾸로 — a.test 에서 시작한 이동(8)은 은행으로 끝나도 아니다(적대 리뷰 2 회차 N1 — a.test 에 보낸 쿠키다).
    try expectReqs(&t, 7, .{ .full = true, .grant_host = "bank.test", .top_bound = true }, &.{ 5, 4, 3 });
}

test "W9d① 적대 리뷰 1 회차 F4·2 회차 N6: 설정이 꺼졌으면 이 읽는 쪽에게 허락되지 않은 탭과 같은 출처의 서비스 워커 요청은 수만 — 그때 있었거나 지금 있으면, 켜져 있으면 다 보인다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    const sw: msg.NetFlags = .{ .service_worker = true };
    // 1 이 날 때 탭 92 가 같은 출처를 보였다. 2 는 그런 탭이 없었다. 9 는 다섯 탭이 보였다(넘침 — 누구에게나 수만).
    try t.begin(1, "https://mail.test/inbox", .{ .flags = sw, .initiator = "https://mail.test", .site = "mail.test", .top = "mail.test", .sw_tabs = &.{92} });
    try t.begin(2, "https://mail.test/api", .{ .flags = sw, .initiator = "https://mail.test", .site = "mail.test", .top = "mail.test" });
    try t.begin(3, "https://mail.test/app.js", .{ .flags = .{ .main_frame = true }, .rt = 3, .initiator = "https://mail.test", .site = "mail.test", .top = "mail.test" });
    try t.begin(4, "https://mail.test/many", .{ .flags = sw, .initiator = "https://mail.test", .site = "mail.test", .top = "mail.test", .sw_tabs = &.{ 92, 93, 94, 95, 96 } });
    const on: View = .{ .full = true, .grant_host = "mail.test" };
    try expectReqs(&t, 7, on, &.{ 4, 3, 2, 1 }); // 사용자 결정 — 다 보인다
    const off: View = .{ .full = false, .grant_host = "mail.test", .reader_tabs = &.{91} };
    try expectReqs(&t, 7, off, &.{ 3, 2 }); // 1 은 그때 이 읽는 쪽의 것이 아닌 탭이 같은 출처였다
    // 92 가 다른 읽는 쪽(다른 pane)에게만 허락됐어도 이 읽는 쪽에게는 허락되지 않은 탭이다(N6). 이 읽는 쪽이 92 도 쥐면 보인다.
    const off_both: View = .{ .full = false, .grant_host = "mail.test", .reader_tabs = &.{ 91, 92 } };
    try expectReqs(&t, 7, off_both, &.{ 3, 2, 1 });
    const now_shared = [_][]const u8{"https://MAIL.test"};
    const off_now: View = .{ .full = false, .grant_host = "mail.test", .reader_tabs = &.{ 91, 92 }, .shared_sw_origins = &now_shared };
    try expectReqs(&t, 7, off_now, &.{3}); // 지금 그런 탭이 있다 — 서비스 워커 요청은 모두 수만
    const p = try t.listJson(7, off_now, .{});
    defer p.deinit();
    try testing.expectEqual(@as(i64, 3), p.value.object.get("service_worker_shared_hidden").?.integer);
    try testing.expectError(error.UnknownRequest, t.ring.detail(testing.allocator, 7, off_now, 2));
    try testing.expectError(error.UnknownRequest, t.ring.detail(testing.allocator, 7, off_both, 4));
    const d = try t.ring.detail(testing.allocator, 7, on, 1);
    testing.allocator.free(d);
}

// ── W9d① 적대 리뷰 2 회차 재현(리뷰가 남긴 R9d2-L1 — 붙여 실패를 본 뒤 고쳤다) ──

test "W9d① 적대 리뷰 2 회차 재현 L1: 덮이지 않는 사이트(은행)가 시작한 이동이 덮이는 사이트로 리다이렉트돼 돌아와도 은행의 Cookie·Set-Cookie 는 보이지 않는다 — 숨김 수로만(설정과 무관)" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, false); // 사용자 탭, a.test 에 모달 grant(첫 읽기 = grant 뒤)
    var bank_req: net_fields.HeaderBuilder = .{};
    _ = bank_req.add("Cookie", "bank=SECRET1");
    var bank_302: net_fields.HeaderBuilder = .{};
    _ = bank_302.add("Set-Cookie", "bank_sid=NEWSECRET; HttpOnly");
    _ = bank_302.add("Location", "https://a.test/callback?code=abc");
    // 사용자가 a.test 에서 은행으로(OAuth·결제) — 그 이동과 은행 페이지의 요청은 숨는다(F2).
    try t.begin(1, "https://bank.test/authorize?client=a.test", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .initiator = "https://a.test", .site = "bank.test", .top = "a.test", .headers = bank_req.block() });
    try t.begin(2, "https://bank.test/api/session", .{ .flags = .{ .main_frame = true }, .site = "bank.test", .top = "bank.test", .headers = bank_req.block() });
    // 은행 페이지에서 로그인 — 은행 페이지가 POST 하고, 은행이 302 로 a.test 의 callback 에 돌려보낸다.
    try t.begin(3, "https://bank.test/login?user=alice", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .initiator = "https://bank.test", .site = "bank.test", .top = "bank.test", .headers = bank_req.block() });
    try t.redirect(3, 302, "https://a.test/callback?code=abc", .{ .headers = bank_302.block() });
    try t.respond(3, 200, .{});
    // 에이전트(제어 grant — 사이트에 묶이지 않는다)가 은행의 열린 리다이렉트로 곧장 옮긴다 — 브라우저가 시작한 이동이라 initiator 는 「null」.
    try t.begin(4, "https://bank.test/sso?return=https://a.test/cb", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .initiator = "null", .site = "bank.test", .top = "a.test", .headers = bank_req.block() });
    try t.redirect(4, 302, "https://a.test/cb", .{ .headers = bank_302.block() });
    try t.respond(4, 200, .{});
    // a.test 에서 시작해 은행을 거쳐 a.test 로 돌아온 이동 — 은행이 보낸 홉의 Set-Cookie 다(덮이지 않는 곳을 지났다).
    try t.begin(5, "https://a.test/login", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .initiator = "https://a.test", .site = "a.test", .top = "a.test" });
    try t.redirect(5, 302, "https://bank.test/auth", .{});
    try t.redirect(5, 302, "https://a.test/cb2", .{ .headers = bank_302.block() });
    try t.respond(5, 200, .{});
    // 덮이는 사이트 안에서만 오간 이동은 그대로 보인다.
    try t.begin(6, "https://a.test/home", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "a.test", .top = "a.test" });
    try t.redirect(6, 302, "https://www.a.test/home", .{});
    try t.respond(6, 200, .{});
    for ([_]bool{ true, false }) |full| {
        const bound: View = .{ .full = full, .grant_host = "a.test", .top_bound = true };
        try expectReqs(&t, 7, bound, &.{6});
        const p = try t.listJson(7, bound, .{});
        defer p.deinit();
        try testing.expectEqual(@as(i64, 5), p.value.object.get("hidden_other_site_pages").?.integer);
        for ([_]u64{ 1, 2, 3, 4, 5 }) |req| try testing.expectError(error.UnknownRequest, t.ring.detail(testing.allocator, 7, bound, req));
    }
    // 어느 호스트든 읽는 쪽(에이전트 탭의 태어날 때 grant)은 여전히 다 본다(사용자 결정 「다 보여 줌」).
    try expectReqs(&t, 7, .{ .full = true }, &.{ 6, 5, 4, 3, 2, 1 });
    // 자세한 것을 버려 가운데 홉을 모르면: 리다이렉트 하나(처음 주소·마지막 주소만 있다)는 둘로 가르고, 둘 이상이면 숨긴다.
    t.ring.entryBySeq(6).?.detail_evicted = true;
    t.ring.entryBySeq(5).?.detail_evicted = true;
    t.ring.entryBySeq(5).?.freeDetail(testing.allocator);
    const bound: View = .{ .full = true, .grant_host = "a.test", .top_bound = true };
    try expectReqs(&t, 7, bound, &.{6});
}

// ── W9d① 적대 리뷰 3 회차 재현(리뷰가 남긴 R9d3-L1 — 붙여 실패를 본 뒤 고쳤다) ──

test "W9d① 적대 리뷰 3 회차 재현 L1: 긴 사용자 정보 안에서 잘린 주 프레임 주소는 덮이는 사이트로 치지 않는다 — 덮이는지는 sidecar 가 온 주소에서 읽은 호스트 칸(은행)으로만 가른다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, false); // 사용자 탭, a.test 에 묶인 모달 grant
    var bank_req: net_fields.HeaderBuilder = .{};
    _ = bank_req.add("Cookie", "bank_sid=HTTPONLY-SECRET");
    var bank_resp: net_fields.HeaderBuilder = .{};
    _ = bank_resp.add("Set-Cookie", "bank_sid=NEW-SECRET; HttpOnly");
    // `https://yyy…y.a.test<…>@bank.test/` 의 앞 2 KiB 는 `.a.test` 에서 끝난다 — 그 글만 읽으면 a.test 의 하위 도메인이다. 고친 sidecar 는 사용자
    // 정보를 빼고 자르지만, 글이 그렇게 생겼어도 maru 는 글에서 호스트를 읽지 않는다: 호스트 칸(bank.test)이 가른다.
    const pad = "y" ** (msg.max_net_url_bytes - "https://".len - ".a.test".len);
    const truncated = "https://" ++ pad ++ ".a.test";
    try testing.expectEqual(msg.max_net_url_bytes, truncated.len);
    try testing.expect(policy.hostCovers("a.test", policy.hostOfUrl(truncated).?)); // 잘린 글이 속이던 꼴
    try t.begin(1, truncated, .{ .flags = .{ .main_frame = true, .navigation = true, .url_truncated = true }, .rt = 0, .initiator = "null", .site = "bank.test", .top = "a.test", .host = "bank.test", .headers = bank_req.block() });
    try t.respond(1, 200, bank_resp.block());
    const bound: View = .{ .full = true, .grant_host = "a.test", .top_bound = true };
    try testing.expectError(error.UnknownRequest, t.ring.detail(testing.allocator, 7, bound, 1));
    const p = try t.listJson(7, bound, .{});
    defer p.deinit();
    try testing.expectEqual(@as(usize, 0), p.value.object.get("requests").?.array.items.len);
    try testing.expectEqual(@as(i64, 1), p.value.object.get("hidden_other_site_pages").?.integer);
    // 호스트 칸이 비면(sidecar 가 못 읽었다) 덮이지 않는다 — 어느 쪽으로도 넓히지 않는다.
    try t.begin(2, "https://a.test/x", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "a.test", .host = "" });
    try testing.expectError(error.UnknownRequest, t.ring.detail(testing.allocator, 7, bound, 2));
}

// ── W9d① 적대 리뷰 3 회차 ──

fn detailJson(t: *T, who: Authorizer, view: View, req: u64) !std.json.Parsed(std.json.Value) {
    const d = try t.ring.detail(testing.allocator, who, view, req);
    defer testing.allocator.free(d);
    return std.json.parseFromSlice(std.json.Value, testing.allocator, d, .{});
}

/// 헤더 배열에서 이름이 `name` 인 것.
fn headerOf(arr: []const std.json.Value, name: []const u8) ?std.json.ObjectMap {
    for (arr) |h| if (std.ascii.eqlIgnoreCase(h.object.get("name").?.string, name)) return h.object;
    return null;
}

test "W9d① 적대 리뷰 3 회차 D1: 자격 증명 헤더 값과 주소의 사용자 정보는 그 헤더를 보내거나 받은 호스트를 덮는 쿠키 권한이 있을 때만 — 설정이 켜져 있어도, 어느 호스트든 grant 여도" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true); // 에이전트가 연 탭(어느 호스트든 grant)
    var req_h: net_fields.HeaderBuilder = .{};
    _ = req_h.add("Cookie", "bank_sid=SECRET");
    _ = req_h.add("Authorization", "Bearer TOKEN");
    _ = req_h.add("Accept", "*/*");
    var hop_h: net_fields.HeaderBuilder = .{};
    _ = hop_h.add("Set-Cookie", "sso=HOPSECRET");
    _ = hop_h.add("Location", "https://bank.test/home");
    var resp_h: net_fields.HeaderBuilder = .{};
    _ = resp_h.add("Set-Cookie", "bank_sid=NEW");
    _ = resp_h.add("Content-Type", "text/html");
    // bank.test 로 가는 이동(사용자 정보까지) — 처음 응답(홉)은 sso.test 가, 마지막 응답은 bank.test 가 보냈다.
    try t.begin(1, "https://alice:pw@bank.test/start", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "bank.test", .headers = req_h.block() });
    try t.redirect(1, 302, "https://sso.test/login", .{ .headers = hop_h.block() });
    try t.redirect(1, 302, "https://bank.test/home", .{});
    try t.respond(1, 200, resp_h.block());
    const Case = struct { cookie_host: []const u8, req_creds: bool, final_creds: bool };
    for ([_]Case{
        .{ .cookie_host = "", .req_creds = false, .final_creds = false }, // 쿠키 권한 없음 — 이름만
        .{ .cookie_host = "bank.test", .req_creds = true, .final_creds = true }, // 은행이 받고 보낸 것
        .{ .cookie_host = "sso.test", .req_creds = false, .final_creds = false }, // 홉 0 의 응답도 bank.test(앞 주소)가 보냈다 — sso 의 권한으로는 아무것도
        .{ .cookie_host = "test", .req_creds = true, .final_creds = true }, // 상위 도메인 grant 는 모두 덮는다
    }) |c| {
        const view: View = .{ .full = true, .cookie_host = c.cookie_host };
        const p = try detailJson(&t, 7, view, 1);
        defer p.deinit();
        const o = p.value.object;
        const rq = o.get("request_headers").?.array.items;
        const cookie = headerOf(rq, "Cookie").?;
        try testing.expectEqual(c.req_creds, cookie.get("value") != null);
        try testing.expectEqual(!c.req_creds, cookie.get("needs_cookie_permission") != null);
        try testing.expectEqual(c.req_creds, headerOf(rq, "Authorization").?.get("value") != null);
        try testing.expectEqualStrings("*/*", headerOf(rq, "Accept").?.get("value").?.string); // 그 밖의 헤더는 설정대로(켬 — 값)
        const hops = o.get("redirects").?.array.items;
        // 홉 0 의 응답(Set-Cookie: sso=…)은 bank.test(앞 주소)가 보냈다.
        try testing.expectEqual(c.req_creds, headerOf(hops[0].object.get("headers").?.array.items, "Set-Cookie").?.get("value") != null);
        try testing.expectEqualStrings("https://bank.test/home", headerOf(hops[0].object.get("headers").?.array.items, "Location").?.get("value").?.string);
        try testing.expectEqual(c.final_creds, headerOf(o.get("response_headers").?.array.items, "Set-Cookie").?.get("value") != null);
        try testing.expectEqualStrings(if (c.req_creds) "https://alice:pw@bank.test/start" else "https://bank.test/start", o.get("url").?.string);
    }
    // 목록의 주소·거르기도 같은 투영 — 사용자 정보로 떠보지 못한다.
    {
        const p = try t.listJson(7, .{ .full = true }, .{ .url_contains = "alice" });
        defer p.deinit();
        try testing.expectEqual(@as(usize, 0), p.value.object.get("requests").?.array.items.len);
        const q = try t.listJson(7, .{ .full = true, .cookie_host = "bank.test" }, .{ .url_contains = "alice" });
        defer q.deinit();
        try testing.expectEqual(@as(usize, 1), q.value.object.get("requests").?.array.items.len);
    }
    // 설정이 꺼졌으면 쿠키 권한이 있어도 이름만(sidecar 가 덜어 냈다 — 끔 쪽의 규칙), 권한 없음 표시는 붙이지 않는다(까닭이 설정이다).
    {
        const p = try detailJson(&t, 7, .{ .full = false, .grant_host = "bank.test", .cookie_host = "bank.test" }, 1);
        defer p.deinit();
        const cookie = headerOf(p.value.object.get("request_headers").?.array.items, "Cookie").?;
        try testing.expect(cookie.get("value") == null and cookie.get("needs_cookie_permission") == null);
        try testing.expectEqualStrings("https://bank.test/start", p.value.object.get("url").?.string);
    }
}

test "W9d① 적대 리뷰 3 회차 T2: 브라우저가 다시 만들어지면 진행 중이던 요청은 취소로 끝내고 번호 표를 비운다 — 새 프로세스가 같은 번호를 다시 써도 옛 기록에 붙지 않는다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, false);
    try t.begin(5, "https://a.test/longpoll", .{ .top = "a.test" });
    try t.begin(6, "https://a.test/done", .{ .top = "a.test" });
    try t.respond(6, 200, .{});
    t.ring.abandonLive();
    var bank: net_fields.HeaderBuilder = .{};
    _ = bank.add("Set-Cookie", "bank_sid=NEWSECRET");
    try t.begin(5, "https://bank.test/", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0 });
    try t.respond(5, 200, bank.block());
    const view: View = .{ .full = true, .grant_host = "a.test", .top_bound = true };
    const p = try detailJson(&t, 7, view, 1);
    defer p.deinit();
    const o = p.value.object;
    try testing.expectEqualStrings("canceled", o.get("state").?.string);
    try testing.expect(o.get("engine_restarted").?.bool);
    try testing.expectEqual(@as(i64, -3), o.get("error_code").?.integer);
    try testing.expect(o.get("response_headers") == null); // 은행의 응답이 붙지 않았다
    const done = try detailJson(&t, 7, view, 2);
    defer done.deinit();
    try testing.expectEqualStrings("done", done.value.object.get("state").?.string); // 끝난 요청은 그대로
    try testing.expectEqual(@as(usize, 3), t.ring.entries.len); // 새 요청은 제 기록(#3)으로
}

// ── W9d① 적대 리뷰 4 회차 재현(리뷰 후보 C1·C2 — 코드 읽기에서 나온 것을 붙여 실패를 본 뒤 고친다) ──

test "W9d① 적대 리뷰 4 회차 재현 C1: 주소를 싣는 헤더(Location·Refresh·Content-Location·Link)의 사용자 정보는 그 주소의 호스트를 덮는 쿠키 권한이 있을 때만 — 설정 켬은 maru 가, 끔은 sidecar(stripHeaders)가 지운다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true); // 에이전트가 연 탭(어느 호스트든 grant)
    var hop_h: net_fields.HeaderBuilder = .{};
    _ = hop_h.add("Location", "https://u:p@b.test/next");
    _ = hop_h.add("Refresh", "0; url=https://u:p@b.test/r");
    _ = hop_h.add("Content-Location", "https://u:p@b.test/c");
    _ = hop_h.add("Link", "<https://u:p@b.test/l>; rel=preload");
    try t.begin(1, "https://a.test/start", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "a.test" });
    try t.redirect(1, 302, "https://u:p@b.test/next", .{ .headers = hop_h.block() });
    try t.respond(1, 200, .{});
    const Case = struct { cookie_host: []const u8, shown: bool };
    for ([_]Case{
        .{ .cookie_host = "", .shown = false }, // 쿠키 권한 없음
        .{ .cookie_host = "a.test", .shown = false }, // 홉을 보낸 곳(a.test)의 권한 — 주소의 호스트(b.test)가 아니다
        .{ .cookie_host = "b.test", .shown = true }, // 그 주소의 호스트를 덮는다
    }) |c| {
        const p = try detailJson(&t, 7, .{ .full = true, .cookie_host = c.cookie_host }, 1);
        defer p.deinit();
        const hops = p.value.object.get("redirects").?.array.items;
        try testing.expectEqual(@as(usize, 1), hops.len);
        try testing.expectEqualStrings(if (c.shown) "https://u:p@b.test/next" else "https://b.test/next", hops[0].object.get("url").?.string); // 홉 주소 칸은 3 회차부터 이미 이렇다
        for ([_][]const u8{ "Location", "Refresh", "Content-Location", "Link" }) |name| {
            const v = headerOf(hops[0].object.get("headers").?.array.items, name).?.get("value").?.string;
            try testing.expectEqual(c.shown, std.mem.indexOf(u8, v, "u:p@") != null);
            try testing.expect(std.mem.indexOf(u8, v, "b.test/") != null); // 사용자 정보만 지운다 — 주소는 남는다
        }
    }
    // 켠 동안 적고(덜어 내지 않은 덩어리) 끈 뒤 읽으면 — 쿠키 권한이 있어도 지운다(끔에서는 자격 증명이 보이지 않는다 — D1·C1).
    {
        const p = try detailJson(&t, 7, .{ .full = false, .grant_host = "a.test", .cookie_host = "b.test" }, 1);
        defer p.deinit();
        const hops = p.value.object.get("redirects").?.array.items;
        const v = headerOf(hops[0].object.get("headers").?.array.items, "Location").?.get("value").?.string;
        try testing.expectEqualStrings("https://b.test/next", v);
    }
}

test "W9d① 적대 리뷰 4 회차 재현 C1(끔): 설정이 꺼졌으면 sidecar 가 보내기 전에 덜어 낸다 — 덮이는 호스트의 응답이어도 Location 의 사용자 정보는 브라우저 프로세스를 나가지 않는다" {
    var hop_h: net_fields.HeaderBuilder = .{};
    _ = hop_h.add("Location", "https://u:p@b.test/next");
    var off: net_fields.HeaderBuilder = .{};
    policy.stripHeaders(hop_h.block(), true, &off);
    var it = net_fields.HeaderIterator.init(off.block());
    const loc = it.next().?;
    try testing.expectEqualStrings("Location", loc.name);
    try testing.expectEqualStrings("https://b.test/next", loc.value);
}

test "W9d① 적대 리뷰 4 회차 재현 C2: 오래된 기록을 버릴 때 번호 표에서는 그 기록을 가리키는 것만 뺀다 — sidecar 가 다시 떠 같은 CEF 번호를 새 요청에 줘도 새 요청의 응답·끝이 붙는다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    // 옛 프로세스의 이동 요청(번호 5) — 진행 중에 sidecar 가 죽었다(취소로 끝난다).
    const long = "https://a.test/" ++ "x" ** 1900;
    try t.begin(5, long ++ "?old", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0 });
    t.ring.abandonLive();
    // 새 프로세스가 같은 번호 5 를 새 이동에 준다.
    try t.begin(5, "https://a.test/new", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0 });
    // 그 이동이 끝나기 전에 다른 요청이 쌓여 상한이 옛 기록(#1)을 버린다 — 새 기록(#2)은 남는다.
    var n: u64 = 100;
    while (t.ring.entryBySeq(1) != null) : (n += 1) try t.begin(n, long, .{});
    try testing.expect(t.ring.entryBySeq(2) != null);
    try t.respond(5, 200, .{});
    const e = t.ring.entryBySeq(2).?;
    try testing.expectEqual(@as(u16, 200), e.status);
    try testing.expectEqual(State.done, e.state);
}

// ── W9d① 적대 리뷰 5 회차 재현 ──

test "W9d① 적대 리뷰 5 회차 재현 B2(켬): 쿠키 권한이 없는 읽는 쪽에게 탭으로 감춘 Location 의 사용자 정보(`/<탭>/u:p@b.test`)가 보인다 — 홉 주소 칸은 지웠는데" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    var hop_h: net_fields.HeaderBuilder = .{};
    _ = hop_h.add("Location", "/\t/u:p@b.test/next");
    try t.begin(1, "https://a.test/start", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "a.test" });
    try t.redirect(1, 302, "https://u:p@b.test/next", .{ .headers = hop_h.block() });
    try t.respond(1, 200, .{});
    const p = try detailJson(&t, 7, .{ .full = true }, 1);
    defer p.deinit();
    const hops = p.value.object.get("redirects").?.array.items;
    try testing.expectEqualStrings("https://b.test/next", hops[0].object.get("url").?.string); // 주소 칸은 지웠다(대조)
    const v = headerOf(hops[0].object.get("headers").?.array.items, "Location").?.get("value").?.string;
    try testing.expect(std.mem.indexOf(u8, v, "u:p@") == null);
}

test "W9d① 적대 리뷰 5 회차 재현 N4: 적지 못한 수의 표지가 새 기록 앞에 들어가도 앱 상한을 넘지 않는다 — 표지의 자리도 함께 낸다" {
    var g: T = .{ .budget = .{ .cap = 4096, .bytes = 0 } };
    defer g.deinit();
    g.ring.noteReader(7, true);
    const url = "https://a.test/x";
    const summary = entry_overhead + "GET".len + url.len + "a.test".len;
    try g.begin(1, url, .{}); // 표지가 아닌 기록 하나
    g.ring.unrecorded = 2; // 앞서 앱 예산이 모자라 적지 못한 둘
    const others = g.budget.cap - summary - g.budget.bytes; // 다른 탭들이 이 기록 하나 몫만 남기고 썼다
    g.budget.bytes += others;
    try g.begin(2, "https://a.test/y", .{}); // 같은 길이
    try testing.expect(g.budget.bytes <= g.budget.cap); // 고치기 전: 표지 하나(160 B)만큼 넘었다
    const p = try g.listJson(7, .{}, .{});
    defer p.deinit();
    try testing.expectEqual(@as(i64, 2), p.value.object.get("dropped").?.integer);
    const arr = p.value.object.get("requests").?.array.items;
    try testing.expectEqual(@as(usize, 1), arr.len); // 새 기록은 들어갔다(오래된 것을 버려 자리를 냈다)
    try testing.expectEqualStrings("https://a.test/y", arr[0].object.get("url").?.string);
    g.budget.bytes -= others;
}

// ── W9d① 변이 생존(5 회차 뒤 기능 전체 변이) ──

test "W9d① 변이 생존 L03: 설정이 꺼진 동안 sidecar 가 덜어 낸 덩어리는 켠 뒤 읽어도 이름만이다 — 빈 값을 그 헤더의 값으로 보이지 않는다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    // 꺼진 동안 적은 요청 — sidecar 가 허용 목록 밖 값과 쿠키 값을 비워 보냈다(`stripped`).
    var req_h: net_fields.HeaderBuilder = .{};
    _ = req_h.add("Cookie", "");
    _ = req_h.add("X-Trace", "");
    _ = req_h.add("Accept", "*/*");
    try t.begin(1, "https://a.test/api", .{ .flags = .{ .stripped = true }, .site = "a.test", .headers = req_h.block() });
    try t.respond(1, 200, .{});
    // 켠 뒤, 쿠키 권한까지 쥔 읽는 쪽 — 그래도 덜어 낸 값은 없는 값이다.
    const p = try detailJson(&t, 7, .{ .full = true, .cookie_host = "a.test" }, 1);
    defer p.deinit();
    const hs = p.value.object.get("request_headers").?.array.items;
    for ([_][]const u8{ "Cookie", "X-Trace" }) |n| {
        const h = headerOf(hs, n).?;
        try testing.expect(h.get("value") == null);
        try testing.expect(h.get("redacted").?.bool);
    }
    try testing.expectEqualStrings("*/*", headerOf(hs, "Accept").?.get("value").?.string); // 허용 목록 값은 남았다
}

test "W9d① 변이 생존 L05: 설정이 꺼졌을 때 덮이지 않는 요청은 리다이렉트 수를 보이지 않는다 — 덮이는 곳을 지나는 사슬이어도, 자세한 것을 버렸어도" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    const off: View = .{ .full = false, .grant_host = "a.test" };
    // 덮이지 않는 곳(other.test)의 요청이 덮이는 곳(a.test)으로, 거기서 다시 한 번 옮긴다 — 둘째 홉은 덮이는 곳이 보냈다.
    try t.begin(1, "https://other.test/go", .{ .site = "a.test" });
    try t.redirect(1, 302, "https://a.test/mid", .{});
    try t.redirect(1, 302, "https://a.test/end", .{});
    try t.respond(1, 200, .{});
    {
        const p = try t.listJson(7, off, .{});
        defer p.deinit();
        try testing.expect(p.value.object.get("requests").?.array.items[0].object.get("redirects") == null);
    }
    // 자세한 것을 버렸다(홉을 모른다) — 그래도 칸째 없다.
    t.ring.entries.atPtr(0).freeDetail(testing.allocator);
    t.budget.bytes -= t.ring.entries.atPtr(0).detail_bytes;
    t.ring.detail_bytes -= t.ring.entries.atPtr(0).detail_bytes;
    t.ring.entries.atPtr(0).detail_bytes = 0;
    t.ring.entries.atPtr(0).detail_evicted = true;
    const p = try t.listJson(7, off, .{});
    defer p.deinit();
    try testing.expect(p.value.object.get("requests").?.array.items[0].object.get("redirects") == null);
}

// ── W9d① 적대 리뷰 후 — 같은 번호 다시 시작(W9d② 측정이 찾았다: StackOverflow 의 Cloudflare 확인 페이지에서 한 CEF 번호의 시작이 두 번 왔다) ──

/// 목록의 한 줄(번호로).
fn rowOf(p: std.json.Parsed(std.json.Value), req: i64) ?std.json.ObjectMap {
    for (p.value.object.get("requests").?.array.items) |r| if (r.object.get("req").?.integer == req) return r.object;
    return null;
}

test "W9d① 적대 리뷰 후 재현 R1: 끝이 오기 전에 같은 CEF 번호의 시작이 다시 오면 앞 기록은 다시 시작으로 끝나고(취소 −3·restarted) 새 시도는 제 기록이다 — 새 시도의 응답·끝이 앞 기록에 붙지 않는다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    const nav: msg.NetFlags = .{ .main_frame = true, .navigation = true };
    try t.begin(9, "https://so.test/q", .{ .flags = nav, .rt = 0, .site = "so.test" });
    try t.ring.response(testing.allocator, &t.budget, .{ .browser = 1, .request = 9, .status = 403, .mime = "text/html" });
    // 앞 시도의 끝은 오지 않았다(넘김 상자가 넘쳐 버렸다 등) — Chromium 이 같은 번호로 다시 시작한다(힌트·쿠키를 실어).
    var again: net_fields.HeaderBuilder = .{};
    _ = again.add("Cookie", "__cf_bm=x");
    try t.ring.begin(testing.allocator, &t.budget, .{ .browser = 1, .request = 9, .flags = nav, .resource_type = 0, .time_ms = 1500, .url = "https://so.test/q?again", .host = "so.test", .site = "so.test", .headers = again.block() }, .{});
    try t.respond(9, 200, .{});
    try testing.expectEqual(@as(u64, 1500), t.ring.entryBySeq(1).?.end_ms); // 다시 시작을 안 때에 끝났다
    try testing.expectEqual(@as(usize, 2), t.ring.entries.len);
    try testing.expectEqual(@as(u32, 0), t.ring.live.count()); // 진행 중으로 남은 것이 없다
    const p = try t.listJson(7, .{}, .{});
    defer p.deinit();
    const old = rowOf(p, 1).?;
    try testing.expectEqualStrings("canceled", old.get("state").?.string);
    try testing.expect(old.get("restarted") != null and old.get("restarted").?.bool);
    try testing.expectEqual(@as(i64, -3), old.get("error_code").?.integer);
    try testing.expectEqual(@as(i64, 403), old.get("status").?.integer); // 앞 시도의 응답은 그대로
    const new = rowOf(p, 2).?;
    try testing.expectEqualStrings("done", new.get("state").?.string);
    try testing.expectEqual(@as(i64, 200), new.get("status").?.integer);
    try testing.expectEqualStrings("https://so.test/q?again", new.get("url").?.string);
    try testing.expect(new.get("restarted") == null);
    const d = try detailJson(&t, 7, .{ .cookie_host = "so.test" }, 2);
    defer d.deinit();
    try testing.expectEqualStrings("__cf_bm=x", headerOf(d.value.object.get("request_headers").?.array.items, "Cookie").?.get("value").?.string);
}

test "W9d① 적대 리뷰 후 재현 R2: 실측 차례(CEF 154 — 앞 시도가 성공으로 끝난 뒤 같은 번호로 다시 시작) — 앞 기록은 다시 시작으로 표시하고 새 기록을 연다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    const nav: msg.NetFlags = .{ .main_frame = true, .navigation = true };
    // 판정 R9d6-restart-same-id 가 본 차례: 시작·응답 403·끝(성공)·시작·응답 200·끝(성공).
    try t.begin(9, "https://so.test/q", .{ .flags = nav, .rt = 0, .site = "so.test" });
    try t.respond(9, 403, .{});
    try t.begin(3, "https://so.test/other.js", .{ .site = "so.test" }); // 사이에 다른 요청이 와도
    try t.begin(9, "https://so.test/q", .{ .flags = nav, .rt = 0, .site = "so.test" });
    try t.respond(9, 200, .{});
    const p = try t.listJson(7, .{}, .{});
    defer p.deinit();
    const old = rowOf(p, 1).?;
    try testing.expectEqualStrings("canceled", old.get("state").?.string);
    try testing.expect(old.get("restarted") != null and old.get("restarted").?.bool);
    try testing.expectEqual(@as(i64, -3), old.get("error_code").?.integer);
    try testing.expectEqual(@as(i64, 403), old.get("status").?.integer);
    const new = rowOf(p, 3).?;
    try testing.expectEqualStrings("done", new.get("state").?.string);
    try testing.expectEqual(@as(i64, 200), new.get("status").?.integer);
    try testing.expect(new.get("restarted") == null);
    try testing.expect(rowOf(p, 2).?.get("restarted") == null);
    try testing.expectEqual(@as(u64, 3009), t.ring.entryBySeq(1).?.end_ms); // 끝은 실제로 온 때 그대로
    // 자세히에도.
    const d = try detailJson(&t, 7, .{}, 1);
    defer d.deinit();
    try testing.expect(d.value.object.get("restarted").?.bool);
    // 설정이 꺼졌고 덮이지 않는 사이트면 다시 시작도 보이지 않는다(서버의 답이 부른 것 — 상태·리다이렉트 수와 같다, F8).
    const off: View = .{ .full = false, .grant_host = "other.test" };
    const po = try t.listJson(7, off, .{});
    defer po.deinit();
    try testing.expect(rowOf(po, 1).?.get("restarted") == null and rowOf(po, 1).?.get("status") == null);
    const dof = try detailJson(&t, 7, off, 1);
    defer dof.deinit();
    try testing.expect(dof.value.object.get("restarted") == null);
    // 덮이면 꺼져 있어도 보인다.
    const cov = try detailJson(&t, 7, .{ .full = false, .grant_host = "so.test" }, 1);
    defer cov.deinit();
    try testing.expect(cov.value.object.get("restarted").?.bool);
}

test "W9d① 적대 리뷰 후 R3: 다시 시작 표시의 경계 — 엔진이 다시 떠 같은 번호를 새 요청에 주면 다시 시작이 아니다, 거듭된 다시 시작은 늘 바로 앞 시도를 끝낸다, wipe 뒤도 아니다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    try t.begin(5, "https://a.test/x", .{ .site = "a.test" });
    try t.respond(5, 200, .{});
    t.ring.abandonLive(); // sidecar 가 다시 떴다 — 새 프로세스가 번호 5 를 다시 쓴다
    try t.begin(5, "https://a.test/y", .{ .site = "a.test" });
    try testing.expectEqual(State.done, t.ring.entryBySeq(1).?.state);
    try testing.expect(!t.ring.entryBySeq(1).?.restarted);
    // 끝난 뒤 다시 시작이 세 번 거듭된다(#2 → #3 → #4) — 늘 바로 앞 시도만.
    try t.respond(5, 200, .{});
    try t.begin(5, "https://a.test/y", .{ .site = "a.test" });
    try testing.expect(t.ring.entryBySeq(2).?.restarted);
    try t.respond(5, 200, .{});
    try t.begin(5, "https://a.test/y", .{ .site = "a.test" });
    try testing.expect(t.ring.entryBySeq(3).?.restarted);
    try testing.expectEqual(State.pending, t.ring.entryBySeq(4).?.state);
    try testing.expect(!t.ring.entryBySeq(1).?.restarted);
    // 끝 전에 또 — #4 가 끝난다.
    try t.begin(5, "https://a.test/y", .{ .site = "a.test" });
    try testing.expect(t.ring.entryBySeq(4).?.restarted);
    try testing.expectEqual(State.canceled, t.ring.entryBySeq(4).?.state);
    try testing.expectEqual(State.pending, t.ring.entryBySeq(5).?.state);
    try testing.expectEqual(@as(u32, 1), t.ring.live.count());
    // 다른 번호가 끝나도(최근 끝 16 자리를 돌려 쓴다) 이 번호의 표시는 섞이지 않는다.
    for (100..120) |n| {
        try t.begin(n, "https://a.test/r", .{ .site = "a.test" });
        try t.respond(n, 200, .{});
    }
    try testing.expect(!t.ring.entryBySeq(6).?.restarted);
    // 두 요청이 엇갈려 끝나고 엇갈려 다시 시작한다 — 둘 다 제 앞 시도를 끝낸다.
    try t.begin(201, "https://a.test/p", .{ .site = "a.test" });
    try t.begin(202, "https://a.test/q", .{ .site = "a.test" });
    try t.respond(201, 200, .{});
    try t.respond(202, 200, .{});
    const s201 = t.ring.next_seq - 2;
    try t.begin(201, "https://a.test/p", .{ .site = "a.test" });
    try t.begin(202, "https://a.test/q", .{ .site = "a.test" });
    try testing.expect(t.ring.entryBySeq(s201).?.restarted and t.ring.entryBySeq(s201 + 1).?.restarted);
    // wipe 뒤에도 다시 시작으로 치지 않는다(최근 끝의 옛 자리는 가리킬 기록이 없다 — 번호는 이어 간다).
    try t.respond(5, 200, .{});
    t.ring.wipe(testing.allocator, &t.budget);
    t.ring.noteReader(8, false);
    try t.begin(5, "https://a.test/z", .{ .site = "a.test" });
    try testing.expectEqual(@as(usize, 1), t.ring.entries.len);
    try testing.expect(!t.ring.entries.atPtr(0).restarted);
}

test "W9d① 적대 리뷰 후 R4: 다시 시작한 시도를 상한으로 적지 못해도 번호 표에 남는 것이 없다 — 새 시도의 응답·끝은 버려지고 적지 못한 수로 센다" {
    var t: T = .{};
    defer t.deinit();
    t.ring.noteReader(7, true);
    try t.begin(9, "https://so.test/q", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "so.test" });
    // 다른 탭들이 앱 예산을 다 썼다 — 이 탭은 제 기록을 다 버려도 새 기록 하나를 적지 못한다(자리를 못 내면 제 기록은 이미 버렸다).
    t.budget.bytes += global_cap_bytes;
    try t.begin(9, "https://so.test/q", .{ .flags = .{ .main_frame = true, .navigation = true }, .rt = 0, .site = "so.test" });
    try t.respond(9, 200, .{});
    t.budget.bytes -= global_cap_bytes;
    try testing.expectEqual(@as(u32, 0), t.ring.live.count());
    try testing.expectEqual(@as(usize, 0), t.ring.entries.len);
    try testing.expectEqual(@as(u32, 1), t.ring.unrecorded);
    try testing.expectEqual(@as(usize, 0), t.budget.bytes);
}
