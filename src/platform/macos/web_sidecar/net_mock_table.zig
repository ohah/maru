//! 가짜 응답의 표(W9d④ — docs/plans/web-osr-backend.md 「W9d④ 결정·실측」 §8). CEF 를 모른다 — 시각·번호·주소 단위는 호출자가 준다(CEF SDK
//! 없이 기본 test 에서 돈다). 잠금도 없다 — `mocking.zig` 의 뮤텍스 하나 아래에서만 부른다(IO 스레드의 처리기 고르기·처리기와 UI 스레드가 함께 쓴다).
//!
//! - **규칙 묶음(RCU — 막기와 같은 꼴)**: maru 는 한 세대의 규칙을 하나씩(`net_mock_rule` — 규칙 하나가 머리 8 KiB 까지) 보내고 `net_mock_commit`
//!   으로 맺는다. UI 스레드가 규칙마다 패턴을 미리 풀어(`net_block.parse` — KMP 표까지) 준비 칸(`Staging`)에 모으고, 맺음에서 `count` 개가 다
//!   왔으면 새 묶음으로 탭의 포인터만 바꾼다. IO 스레드는 잠금 아래에서 포인터와 `readers` 를 잡고 **잠금 밖에서** 맞춘다. 바뀐 옛 묶음은 은퇴
//!   목록에 두고, 쥔 이(`readers`)가 없으면 **곧** 거둔다(`settle` — 바꾸는 때와 마지막 읽는 이가 놓는 때; 보낼 수가 남았으면 응답 자원만 먼저
//!   놓고 수의 칸은 보내는 task 가 마지막 수를 보낸 뒤 푼다 — v2 검증 R11: 보내는 task 에서만 거두면 요청 없는 바꾸기가 덩어리 상한을 채웠다).
//! - **본문 덩어리(`Blob`)**: 규칙이 본문 번호와 길이를 실어 오면 그 크기로 자리를 잡고(같은 탭·번호면 다시 쓴다 — 바뀌지 않은 규칙을 다시 보내도
//!   본문은 다시 오지 않아도 된다) `net_mock_body` 조각으로 채운다. 참조 셈 — 묶음의 규칙·준비 칸·처리기(그 응답 하나)가 쥐고, 모두 놓으면 푼다
//!   (규칙을 지우거나 바꿔도 이미 시작한 응답은 끝까지 그 덩어리로 — 계획 §7). 조각은 차례대로만 받고(maru 는 차례대로 보낸다), **처리한 바이트**
//!   (`offset + len` — 모르는 덩어리의 조각도)를 조각마다 확인한다(maru 의 창 — 버린 조각도 창에서 빠져야 한다). 계획은 64 KiB 마다였지만 그러면
//!   maru 가 보내다 그만둔 본문(규칙을 지움)의 마지막 64 KiB 미만이 영영 확인되지 않아 창이 줄어든다 — 조각마다면 새는 곳이 없다(frame 22 바이트).
//! - **맞추기**(`decideTab` — 막기 다음, 막기가 이긴다): 종류·패턴·사이트(주 프레임 홉은 그 홉의 호스트, 하위 자원은 페이지 호스트 — 모르면
//!   맞추지 않고 센다)·실행 출처(문서 종류는 묶인 사이트가 그 주소를 덮어야 — §5-2)·D2 예외(주 프레임)·사람의 누름(Q2 — 사용자 탭의 규칙만)·
//!   메서드(패턴이 맞은 뒤에만 읽는다). 추가한 차례의 첫 규칙.
//! - **처리기 풀**(M17 — CEF 는 처리기가 null 이면 진짜 네트워크로 보낸다): 앱 512·탭 128. 고르기 때 자리를 잡고(처리기가 놓일 때 돌려준다) 넘치면
//!   `busy` 를 세고 부른 쪽이 `-12` 로 끝낸다(진짜로 보내지 않는다).
//! - **수**: 규칙마다 원자 u32(포화), 탭마다 문 넘김·줄 수 없음·페이지 모름·서비스 워커 표시. 보내는 task 가 차이만 모은다.
//!
//! 시험이 증명하는 것: 준비와 맺음(빠진 규칙이면 거절·세대가 바뀌면 버림·0 개는 지움), 묶음 바꾸기와 readers·은퇴, 덩어리의 참조(묶음·준비·처리기)와
//! 다시 쓰기, 조각의 차례·확인 간격·모르는 덩어리, 맞추기 표(종류·사이트·페이지 모름·실행 출처·D2·사람·메서드·첫 규칙·preload 빠짐·공유 워커 주 스크립트는 수만), 풀(앱·탭·
//! 돌려줌·잊은 탭), 수의 차이.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const block_table = @import("net_block_table.zig");

const msg = protocol.message;
const nb = protocol.net_block;
const rules = protocol.net_mock_rules;
const net_policy = protocol.net_policy;
const BrowserId = msg.BrowserId;

pub const capacity = @import("registry.zig").capacity;
pub const bump = block_table.bump;
pub const urlHost = block_table.urlHost;

/// 덩어리 합의 방어 상한(maru 가 앱 32 MiB 로 묶는다 — 은퇴 묶음·처리기가 옛 덩어리를 쥐는 동안의 여유까지).
pub const max_blob_bytes_total: usize = 2 * rules.max_app_body_bytes;

// ── 본문 덩어리 ─────────────────────────────────────────────────────────────────────────────────────────

pub const Blob = struct {
    browser: BrowserId,
    id: u32,
    /// 전체 길이(0 이 아니다 — 빈 본문은 덩어리가 없다).
    total: u32,
    /// 받은 앞부분 길이(차례대로만 받는다).
    received: u32 = 0,
    data: []u8,
    refs: u32 = 0,

    pub fn ready(self: *const Blob) bool {
        return self.received == self.total;
    }
};

/// 조각 하나를 받은 결과 — 확인을 보낼지(그 값)·덩어리가 막 다 찼는가.
pub const ChunkResult = struct { ack: ?u32 = null, completed: ?*Blob = null };

// ── 규칙 ────────────────────────────────────────────────────────────────────────────────────────────────

pub const Rule = struct {
    id: u32 = 0,
    types: u32 = 0,
    methods: u8 = 0,
    flags: msg.NetMockRuleFlags = .{},
    site_buf: [msg.max_net_host_bytes]u8 = undefined,
    site_len: u8 = 0,
    exec_buf: [msg.max_net_host_bytes]u8 = undefined,
    exec_len: u8 = 0,
    pattern: nb.Pattern = .{},
    status: u16 = 200,
    body_len: u32 = 0,
    blob: ?*Blob = null,
    /// 응답의 글(이 규칙이 쥔다 — `freeRule` 이 푼다): content_type·Location·머리 덩어리 바이트.
    content_type: []u8 = &.{},
    location: []u8 = &.{},
    headers: []u8 = &.{},
    header_count: u8 = 0,
    hits: std.atomic.Value(u32) = .init(0),
    sw_not_mocked: std.atomic.Value(u32) = .init(0),
    /// 맞았지만 그 가짜가 돌 출처를 이 규칙의 grant 가 덮지 않아 진짜로 보낸 수(v1 SEVERE-1 — `execSiteAllows`).
    frame_not_mocked: std.atomic.Value(u32) = .init(0),
    sent_hits: u32 = 0,
    sent_sw: u32 = 0,
    sent_frame: u32 = 0,

    pub fn site(self: *const Rule) []const u8 {
        return self.site_buf[0..self.site_len];
    }

    pub fn execSite(self: *const Rule) []const u8 {
        return self.exec_buf[0..self.exec_len];
    }

    pub fn headerBlock(self: *const Rule) msg.NetHeaderBlock {
        return .{ .count = self.header_count, .bytes = self.headers };
    }
};

pub const RuleSet = struct {
    browser: BrowserId,
    generation: u32,
    count: u8 = 0,
    rules: [rules.max_rules]Rule = undefined,
    readers: u32 = 0,
    /// 바뀌어 은퇴 목록에 있다(탭의 포인터가 아니다).
    retired: bool = false,
    /// 은퇴한 뒤 readers 가 0 이 되어 응답 자원(글·본문 덩어리의 참조)을 이미 놓았다 — 남은 것은 보낼 수의 칸(번호·수)뿐(`settle`).
    stripped: bool = false,

    pub fn slice(self: *RuleSet) []Rule {
        return self.rules[0..self.count];
    }
};

/// 한 세대의 규칙을 모으는 칸(맺음 전).
pub const Staging = struct {
    generation: u32,
    have: [rules.max_rules]bool = @splat(false),
    rules: [rules.max_rules]Rule = undefined,
};

pub const Tab = struct {
    used: bool = false,
    browser: BrowserId = 0,
    cef_id: c_int = 0,
    set: ?*RuleSet = null,
    staging: ?*Staging = null,
    /// 확정된 맨 위 문서 호스트(비면 모른다).
    top_buf: [msg.max_net_host_bytes]u8 = undefined,
    top_len: u8 = 0,
    /// 가짜 엄격 모드가 묶인 사이트(빈 = 끔) — 엄격의 CDP 는 막기와 나눈다(`blocking.zig`).
    strict_buf: [msg.max_net_host_bytes]u8 = undefined,
    strict_len: u8 = 0,
    /// 마지막으로 맺은(또는 거절한) 세대와 그 적용 여부 — 엄격 CDP 의 답을 그 세대로 다시 알린다(`mocking.strictSettled`).
    generation_sent: u32 = 0,
    last_ok: bool = false,
    /// 쓰는 처리기 수(탭 128).
    handlers: u32 = 0,
    unrecorded: u32 = 0,
    busy: u32 = 0,
    skipped_unknown_page: u32 = 0,
    page_controlled: bool = false,

    pub fn topHost(self: *const Tab) []const u8 {
        return self.top_buf[0..self.top_len];
    }

    pub fn strictSite(self: *const Tab) []const u8 {
        return self.strict_buf[0..self.strict_len];
    }
};

/// 처리기 고르기의 답.
pub const Verdict = union(enum) {
    pass,
    /// 그 규칙으로 가짜를 준다(규칙 포인터는 잡은 묶음 안 — `Acquired` 를 놓기 전까지 쓴다).
    mock: *Rule,
    /// 페이지(맨 위 문서)를 몰라 맞추지 않았다(센다 — 요청은 진짜로 간다).
    unknown_page,
};

/// 처리기 고르기가 잡은 것(잠금 밖에서 쓴다).
pub const Acquired = struct {
    set: *RuleSet,
    top_buf: [msg.max_net_host_bytes]u8 = undefined,
    top_len: u8 = 0,

    pub fn topHost(self: *const Acquired) []const u8 {
        return self.top_buf[0..self.top_len];
    }
};

/// 고르기의 맥락(주 프레임 이동·페이지 호스트·예외) — 메서드는 패턴이 맞은 뒤에만 읽는다(`method_ctx.method()`).
pub const Request = struct {
    url: []const u16,
    resource_type: u8,
    main_nav: bool,
    /// 하위 자원의 페이지 호스트(`net_policy.pageHost` — 주 프레임 홉이면 쓰지 않는다).
    page_host: []const u8 = "",
    /// D2 — 사용자 이동(주 프레임만).
    user_exempt: bool = false,
    /// Q2 — 사람의 누름으로 시작한 이동(주 프레임만 — 사용자 탭의 규칙만 지나간다).
    human_exempt: bool = false,
    /// 요청을 낸 문맥(프레임·워커 — CEF 의 `request_initiator` 출처)의 호스트. 빈 글이면 모른다(문서가 아닌 요청은 실행 사이트에 묶인 규칙에 맞지
    /// 않는다 — v1 SEVERE-1). 문서 종류는 쓰지 않는다(그 주소의 출처로 돈다).
    initiator_host: []const u8 = "",
};

pub const Table = struct {
    tabs: [capacity]Tab = @splat(.{}),
    with_rules: usize = 0,
    retired: std.ArrayList(*RuleSet) = .empty,
    blobs: std.ArrayList(*Blob) = .empty,
    blob_bytes: usize = 0,
    /// 앱 전체의 처리기 수(512).
    handlers: u32 = 0,

    pub fn find(self: *Table, browser: BrowserId) ?*Tab {
        for (&self.tabs) |*t| if (t.used and t.browser == browser) return t;
        return null;
    }

    pub fn findCef(self: *Table, cef_id: c_int) ?*Tab {
        for (&self.tabs) |*t| if (t.used and t.cef_id == cef_id) return t;
        return null;
    }

    pub fn ensure(self: *Table, browser: BrowserId, cef_id: c_int) ?*Tab {
        if (self.findCef(cef_id)) |t| {
            if (browser != 0) t.browser = browser;
            return t;
        }
        for (&self.tabs) |*t| if (!t.used) {
            t.* = .{ .used = true, .browser = browser, .cef_id = cef_id };
            return t;
        };
        return null;
    }

    // ── 덩어리 ──

    fn findBlob(self: *Table, browser: BrowserId, id: u32) ?*Blob {
        for (self.blobs.items) |b| if (b.browser == browser and b.id == id) return b;
        return null;
    }

    /// 규칙이 실어 온 본문 번호의 덩어리(없으면 만든다) — 참조 하나를 더해 돌려준다. 길이가 다르거나 자리가 없으면 null(그 세대는 맺지 못한다).
    fn refBlob(self: *Table, gpa: std.mem.Allocator, browser: BrowserId, id: u32, total: u32) error{OutOfMemory}!?*Blob {
        if (self.findBlob(browser, id)) |b| {
            if (b.total != total) return null;
            b.refs += 1;
            return b;
        }
        if (self.blob_bytes + total > max_blob_bytes_total) return null;
        const b = try gpa.create(Blob);
        errdefer gpa.destroy(b);
        b.* = .{ .browser = browser, .id = id, .total = total, .data = try gpa.alloc(u8, total), .refs = 1 };
        errdefer gpa.free(b.data);
        try self.blobs.append(gpa, b);
        self.blob_bytes += total;
        return b;
    }

    /// 덩어리의 참조 하나를 놓는다(0 이면 푼다).
    pub fn unrefBlob(self: *Table, gpa: std.mem.Allocator, b: *Blob) void {
        b.refs -= 1;
        if (b.refs != 0) return;
        for (self.blobs.items, 0..) |x, i| if (x == b) {
            _ = self.blobs.swapRemove(i);
            break;
        };
        self.blob_bytes -= b.total;
        gpa.free(b.data);
        gpa.destroy(b);
    }

    /// 처리기가 덩어리를 쥔다.
    pub fn holdBlob(_: *Table, b: *Blob) void {
        b.refs += 1;
    }

    /// `net_mock_body` 조각 — 차례대로만 받는다. 처리한 바이트(`offset + len`)를 **조각마다 늘** 확인한다 — 버린 조각(모르는 덩어리·차례 밖·이미
    /// 다 찬 덩어리·길이가 다름)도(maru 의 창에서 빠져야 한다 — 확인이 오지 않는 조각은 창을 영영 줄인다).
    pub fn chunk(self: *Table, v: msg.NetMockBody) ChunkResult {
        const processed: u32 = v.offset + @as(u32, @intCast(v.bytes.len));
        var out: ChunkResult = .{ .ack = processed };
        const b = self.findBlob(v.browser, v.body_id) orelse return out;
        if (v.total != b.total) return out;
        if (v.offset == b.received and !b.ready()) {
            @memcpy(b.data[v.offset..][0..v.bytes.len], v.bytes);
            b.received = processed;
            if (b.ready()) out.completed = b;
        }
        return out;
    }

    // ── 규칙의 준비와 맺음(UI 스레드) ──

    /// `net_mock_rule` 하나를 준비 칸에 넣는다(다른 세대의 칸은 버린다). 풀리지 않는 패턴·덩어리 자리 없음이면 그 자리를 비워 둔다(맺음이 거절한다).
    pub fn stage(self: *Table, gpa: std.mem.Allocator, t: *Tab, v: msg.NetMockRule) error{OutOfMemory}!void {
        if (t.staging) |st| if (st.generation != v.generation) {
            self.dropStaging(gpa, t);
        };
        if (t.staging == null) {
            const st = try gpa.create(Staging);
            st.* = .{ .generation = v.generation };
            t.staging = st;
        }
        const st = t.staging.?;
        if (st.have[v.index]) {
            self.freeRule(gpa, &st.rules[v.index]);
            st.have[v.index] = false;
        }
        const p = switch (nb.parse(v.pattern)) {
            .ok => |p| p,
            .err => return,
        };
        var r: Rule = .{ .id = v.id, .types = v.types, .methods = v.methods, .flags = v.flags, .pattern = p, .status = v.status, .body_len = v.body_len };
        @memcpy(r.site_buf[0..v.site.len], v.site);
        r.site_len = @intCast(v.site.len);
        @memcpy(r.exec_buf[0..v.exec_site.len], v.exec_site);
        r.exec_len = @intCast(v.exec_site.len);
        r.content_type = try gpa.dupe(u8, v.content_type);
        errdefer gpa.free(r.content_type);
        r.location = try gpa.dupe(u8, v.location);
        errdefer gpa.free(r.location);
        r.headers = try gpa.dupe(u8, v.headers.bytes);
        errdefer gpa.free(r.headers);
        r.header_count = v.headers.count;
        if (v.body_id != 0) {
            r.blob = (try self.refBlob(gpa, v.browser, v.body_id, v.body_len)) orelse {
                gpa.free(r.content_type);
                gpa.free(r.location);
                gpa.free(r.headers);
                return;
            };
        }
        st.rules[v.index] = r;
        st.have[v.index] = true;
    }

    /// `net_mock_commit` — 그 세대의 규칙이 `count` 개 다 있으면 새 묶음으로 바꾸고 참(0 개면 지운다). 아니면 칸을 버리고 거짓(묶음은 그대로).
    /// 엄격 사이트는 맺을 때만 바꾼다.
    pub fn commit(self: *Table, gpa: std.mem.Allocator, t: *Tab, v: msg.NetMockCommit) error{OutOfMemory}!bool {
        var set: ?*RuleSet = null;
        if (v.count != 0) {
            const st = t.staging orelse return false;
            const complete = st.generation == v.generation and for (0..rules.max_rules) |i| {
                if (st.have[i] != (i < v.count)) break false;
            } else true;
            if (!complete) {
                self.dropStaging(gpa, t);
                return false;
            }
            const s = try gpa.create(RuleSet);
            s.* = .{ .browser = t.browser, .generation = v.generation, .count = v.count };
            @memcpy(s.rules[0..v.count], st.rules[0..v.count]);
            gpa.destroy(st);
            t.staging = null;
            set = s;
        } else self.dropStaging(gpa, t);
        try self.swap(gpa, t, set);
        const n = @min(v.strict_site.len, t.strict_buf.len);
        @memcpy(t.strict_buf[0..n], v.strict_site[0..n]);
        t.strict_len = @intCast(n);
        return true;
    }

    fn dropStaging(self: *Table, gpa: std.mem.Allocator, t: *Tab) void {
        const st = t.staging orelse return;
        for (0..rules.max_rules) |i| if (st.have[i]) self.freeRule(gpa, &st.rules[i]);
        gpa.destroy(st);
        t.staging = null;
    }

    fn freeRule(self: *Table, gpa: std.mem.Allocator, r: *Rule) void {
        gpa.free(r.content_type);
        gpa.free(r.location);
        gpa.free(r.headers);
        if (r.blob) |b| self.unrefBlob(gpa, b);
        r.blob = null;
    }

    fn freeSet(self: *Table, gpa: std.mem.Allocator, set: *RuleSet) void {
        if (!set.stripped) for (set.slice()) |*r| self.freeRule(gpa, r);
        gpa.destroy(set);
    }

    fn swap(self: *Table, gpa: std.mem.Allocator, t: *Tab, set: ?*RuleSet) error{OutOfMemory}!void {
        if (t.set) |old| {
            try self.retired.append(gpa, old);
            old.retired = true;
            self.with_rules -= 1;
            t.set = null;
            self.settle(gpa, old);
        }
        t.set = set;
        if (set != null) self.with_rules += 1;
    }

    /// 은퇴 묶음을 쥔 이가 없으면 곧 거둔다(W9d④ v2 검증 R11 SEVERE: 거두기가 보내는 task 의 `reap` 뿐이었고 그것은 네트워크 일이 있을 때만 돌아,
    /// 요청 없이 규칙을 128 번 바꾸면 은퇴 묶음이 쥔 본문 덩어리가 `max_blob_bytes_total` 을 채워 맺음이 모두 실패하고 옛 응답이 계속 나갔다).
    /// 쥔 이(`readers` — 처리기 고르기·진행 중 응답)가 있으면 그대로 둔다(RCU — 마지막 `unread` 가 다시 부른다). 보낼 수가 남았으면 응답 자원만
    /// 놓고(`stripped` — 수의 칸은 다음 `reap` 이 보낸 뒤 푼다), 없으면 묶음째 푼다. 잠금 아래에서만.
    fn settle(self: *Table, gpa: std.mem.Allocator, set: *RuleSet) void {
        if (!set.retired or set.readers != 0) return;
        if (!pendingDelta(set)) {
            for (self.retired.items, 0..) |x, i| if (x == set) {
                _ = self.retired.swapRemove(i);
                break;
            };
            self.freeSet(gpa, set);
            return;
        }
        if (set.stripped) return;
        for (set.slice()) |*r| self.freeRule(gpa, r);
        set.stripped = true;
    }

    /// 잡은 묶음의 `readers` 하나를 놓는다(처리기 고르기·처리기) — 은퇴 묶음의 마지막이면 거둔다(`settle`). 잠금 아래에서만.
    pub fn unread(self: *Table, gpa: std.mem.Allocator, set: *RuleSet) void {
        set.readers -= 1;
        if (set.retired) self.settle(gpa, set);
    }

    /// 지켜보기가 꺼졌다·브라우저가 닫힌다 — 규칙·준비·엄격을 버린다(`forget` 이면 탭 자리도).
    pub fn dropAll(self: *Table, gpa: std.mem.Allocator, t: *Tab, forget: bool) error{OutOfMemory}!void {
        self.dropStaging(gpa, t);
        try self.swap(gpa, t, null);
        t.strict_len = 0;
        if (forget) t.* = .{};
    }

    // ── IO 스레드: 처리기 고르기 ──

    /// 그 탭의 묶음을 잡는다(`readers`) — 없으면 null.
    pub fn acquire(self: *Table, cef_id: c_int) ?Acquired {
        const t = self.findCef(cef_id) orelse return null;
        const set = t.set orelse return null;
        set.readers += 1;
        var a: Acquired = .{ .set = set };
        @memcpy(a.top_buf[0..t.top_len], t.top_buf[0..t.top_len]);
        a.top_len = t.top_len;
        return a;
    }

    /// 잡은 묶음을 놓고 모르는 페이지를 센다.
    pub fn release(self: *Table, gpa: std.mem.Allocator, cef_id: c_int, a: *const Acquired, verdict: Verdict) void {
        self.unread(gpa, a.set);
        if (verdict == .unknown_page) if (self.findCef(cef_id)) |t| {
            t.skipped_unknown_page +|= 1;
        };
    }

    /// 처리기 자리를 잡는다(앱 512·탭 128). 넘치면 거짓(그 탭의 `busy` 를 센다 — 부른 쪽이 `-12` 로 끝낸다).
    pub fn reserveHandler(self: *Table, cef_id: c_int) bool {
        const t = self.findCef(cef_id) orelse return false;
        if (self.handlers >= rules.max_handlers_app or t.handlers >= rules.max_handlers_tab) {
            t.busy +|= 1;
            return false;
        }
        self.handlers += 1;
        t.handlers += 1;
        return true;
    }

    /// 처리기가 놓였다 — 자리를 돌려준다(탭이 이미 잊혔으면 앱 몫만).
    pub fn releaseHandler(self: *Table, cef_id: c_int) void {
        self.handlers -|= 1;
        if (self.findCef(cef_id)) |t| t.handlers -|= 1;
    }

    pub fn noteBusy(self: *Table, cef_id: c_int) void {
        if (self.findCef(cef_id)) |t| t.busy +|= 1;
    }

    pub fn noteUnrecorded(self: *Table, cef_id: c_int) void {
        if (self.findCef(cef_id)) |t| t.unrecorded +|= 1;
    }

    // ── UI 스레드 ──

    pub fn committed(self: *Table, browser: BrowserId, cef_id: c_int, host: []const u8) void {
        const t = self.ensure(browser, cef_id) orelse return;
        const n = @min(host.len, t.top_buf.len);
        @memcpy(t.top_buf[0..n], host[0..n]);
        t.top_len = @intCast(n);
    }

    // ── 보내는 task ──

    pub fn takeHits(self: *Table, browser: BrowserId) ?msg.NetMockHits {
        var out: msg.NetMockHits = .{ .browser = browser };
        if (self.find(browser)) |t| {
            if (t.set) |set| collect(set, &out);
            out.unrecorded = t.unrecorded;
            out.busy = t.busy;
            out.skipped_unknown_page = t.skipped_unknown_page;
            out.page_controlled = t.page_controlled;
            t.unrecorded = 0;
            t.busy = 0;
            t.skipped_unknown_page = 0;
            t.page_controlled = false;
        }
        for (self.retired.items) |set| if (set.browser == browser) collect(set, &out);
        const any = out.count > 0 or out.unrecorded > 0 or out.busy > 0 or out.skipped_unknown_page > 0 or out.page_controlled;
        return if (any) out else null;
    }

    pub fn browsersWithHits(self: *Table, out: []BrowserId) []BrowserId {
        var n: usize = 0;
        for (&self.tabs) |*t| {
            if (!t.used or t.browser == 0) continue;
            const has = t.unrecorded > 0 or t.busy > 0 or t.skipped_unknown_page > 0 or t.page_controlled or (if (t.set) |s| pendingDelta(s) else false);
            if (has) add(out, &n, t.browser);
        }
        for (self.retired.items) |set| if (pendingDelta(set)) add(out, &n, set.browser);
        return out[0..n];
    }

    /// readers 0 이고 보낼 수가 남지 않은 은퇴 묶음을 푼다(수를 보낸 뒤 — 보낼 수가 없는 묶음은 이미 `settle` 이 풀었다).
    pub fn reap(self: *Table, gpa: std.mem.Allocator) void {
        var i: usize = 0;
        while (i < self.retired.items.len) {
            const set = self.retired.items[i];
            if (set.readers == 0 and !pendingDelta(set)) {
                _ = self.retired.swapRemove(i);
                self.freeSet(gpa, set);
            } else {
                self.settle(gpa, set); // 쥔 이가 없으면 응답 자원만 먼저 놓는다(수의 칸은 다음 보내기 뒤)
                i += 1;
            }
        }
    }

    pub fn deinit(self: *Table, gpa: std.mem.Allocator) void {
        for (&self.tabs) |*t| if (t.used) {
            self.dropStaging(gpa, t);
            if (t.set) |s| self.freeSet(gpa, s);
            t.set = null;
        };
        for (self.retired.items) |s| self.freeSet(gpa, s);
        self.retired.deinit(gpa);
        // 처리기가 쥐던 덩어리(시험에서는 남지 않아야 한다).
        for (self.blobs.items) |b| {
            gpa.free(b.data);
            gpa.destroy(b);
        }
        self.blobs.deinit(gpa);
    }
};

fn add(o: []BrowserId, len: *usize, b: BrowserId) void {
    for (o[0..len.*]) |x| if (x == b) return;
    if (len.* == o.len) return;
    o[len.*] = b;
    len.* += 1;
}

fn pendingDelta(set: *RuleSet) bool {
    for (set.slice()) |*r| if (r.hits.load(.monotonic) != r.sent_hits or r.sw_not_mocked.load(.monotonic) != r.sent_sw or r.frame_not_mocked.load(.monotonic) != r.sent_frame) return true;
    return false;
}

fn collect(set: *RuleSet, out: *msg.NetMockHits) void {
    for (set.slice()) |*r| {
        const h = r.hits.load(.monotonic);
        const s = r.sw_not_mocked.load(.monotonic);
        const f = r.frame_not_mocked.load(.monotonic);
        const dh = h -% r.sent_hits;
        const ds = s -% r.sent_sw;
        const df = f -% r.sent_frame;
        r.sent_hits = h;
        r.sent_sw = s;
        r.sent_frame = f;
        if (dh == 0 and ds == 0 and df == 0) continue;
        const slot = for (out.entries[0..out.count]) |*e| {
            if (e.rule_id == r.id) break e;
        } else blk: {
            if (out.count == out.entries.len) return;
            out.entries[out.count] = .{ .rule_id = r.id };
            out.count += 1;
            break :blk &out.entries[out.count - 1];
        };
        slot.hits +|= dh;
        slot.sw_not_mocked +|= ds;
        slot.frame_not_mocked +|= df;
    }
}

// ── 맞추기(잠금 밖 — 잡은 묶음으로) ──────────────────────────────────────────────────────────────────

/// 탭 길 요청의 답(막기 다음 — 막기가 맞았으면 부르지 않는다). 주 프레임 홉은 그 홉의 호스트를, 하위 자원은 페이지 호스트를 규칙 사이트가 덮어야
/// 한다(모르면 `unknown_page`). 실행 사이트에 묶인 규칙은 그 가짜가 돌 출처 — 문서 종류는 그 주소, 그 밖은 요청을 낸 문맥(initiator) — 의 호스트를
/// 덮어야 한다(§5-2·v1 SEVERE-1: 아니면 진짜, 그 규칙의 `frame_not_mocked` 를 올리고 다음 규칙을 본다). D2 사용자 이동의 주 문서는 맞지 않고, 사람의
/// 누름의 주 문서는 사용자 탭의 규칙(`human_nav_real`)에 맞지 않는다. navigation preload(19·20)는 맞추지 않는다(M26). 공유 워커 주 스크립트(10)는
/// 맞아도 가짜가 아니다(결정 A — 그 규칙의 `sw_not_mocked` 를 올린다). 메서드는 패턴이 맞은 뒤에만 `method_ctx.method()` 로 읽는다. 맞으면 그
/// 규칙의 맞음 수를 올린다.
pub fn decideTab(a: *const Acquired, req: Request, method_ctx: anytype) Verdict {
    if (req.resource_type == 19 or req.resource_type == 20) return .pass;
    if (req.main_nav and req.user_exempt) return .pass;
    const parts = nb.splitUrl(u16, req.url) orelse return .pass;
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    const url_host = urlHost(u16, req.url, &hb);
    var unknown = false;
    var method: ?[]const u8 = null;
    for (a.set.slice()) |*r| {
        if (!nb.typeMatches(r.types, req.resource_type)) continue;
        if (!nb.matchParts(u16, &r.pattern, parts)) continue;
        if (req.main_nav) {
            if (req.human_exempt and r.flags.human_nav_real) continue;
            if (!net_policy.hostCovers(r.site(), url_host)) continue;
        } else {
            if (req.page_host.len == 0) {
                unknown = true;
                continue;
            }
            if (!net_policy.hostCovers(r.site(), req.page_host)) continue;
        }
        if (r.methods != 0) {
            if (method == null) method = method_ctx.method();
            if (!rules.methodMatches(r.methods, method.?)) continue;
        }
        if (!rules.execSiteAllows(req.resource_type, r.execSite(), url_host, req.initiator_host)) {
            // 그 밖은 다 맞았다. 허락 밖 사이트의 프레임·워커가 낸 요청이거나 다른 사이트 문서다 — 이 규칙의 grant 는 그곳에서 코드를 돌릴 권한이
            // 없다(사용자 결정 2026-11-11). 진짜로 보내고 센다.
            bump(&r.frame_not_mocked);
            continue;
        }
        // 공유 워커 주 스크립트는 가짜로 바꾸지 않는다(사용자 결정 A 2026-11-11 — 같은 사이트의 다른 탭이 같은 워커에 붙어 가짜가 이 탭·규칙보다
        // 오래 산다). 맞은 규칙은 서비스 워커 길처럼 `sw_not_mocked` 로 센다 — 진짜 스크립트가 간다.
        if (req.resource_type == rules.shared_worker_type) {
            bump(&r.sw_not_mocked);
            return .pass;
        }
        bump(&r.hits);
        return .{ .mock = r };
    }
    return if (unknown) .unknown_page else .pass;
}

/// 서비스 워커 길(가짜를 주지 않는다 — 사용자 결정 Q1): 그 탭이 쥔, 이 주소에 맞고 사이트가 그 탭의 맨 위 호스트를 덮는 첫 규칙(종류가 xhr·
/// 기타 — 서비스 워커가 대신 낸 요청의 종류로는 가를 수 없어 종류는 보지 않는다).
pub fn serviceWorkerRule(set: *RuleSet, parts: nb.UrlParts(u16), top_host: []const u8) ?*Rule {
    if (top_host.len == 0) return null;
    for (set.slice()) |*r| {
        if (!nb.matchParts(u16, &r.pattern, parts)) continue;
        if (!net_policy.hostCovers(r.site(), top_host)) continue;
        return r;
    }
    return null;
}

// ── 시험 ────────────────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

fn u16s(comptime s: []const u8) [s.len]u16 {
    var out: [s.len]u16 = undefined;
    for (s, 0..) |ch, i| out[i] = ch;
    return out;
}

const NoMethod = struct {
    pub fn method(_: NoMethod) []const u8 {
        @panic("method read before a pattern matched");
    }
};

const Method = struct {
    m: []const u8,
    reads: *u32,
    pub fn method(self: Method) []const u8 {
        self.reads.* += 1;
        return self.m;
    }
};

fn ruleMsg(gen: u32, index: u8, id: u32, pattern: []const u8, opts: struct { types: u32 = 0, methods: u8 = 0, site: []const u8 = "a.test", exec: []const u8 = "", human: bool = false, body_id: u32 = 0, body_len: u32 = 0 }) msg.NetMockRule {
    return .{ .browser = 7, .generation = gen, .index = index, .id = id, .types = opts.types, .methods = opts.methods, .flags = .{ .exec_site_bound = opts.exec.len != 0, .human_nav_real = opts.human }, .site = opts.site, .exec_site = opts.exec, .pattern = pattern, .body_id = opts.body_id, .body_len = opts.body_len, .content_type = "text/plain" };
}

fn installRules(t: *Table, gen: u32, list: []const msg.NetMockRule) !*Tab {
    const tab = t.ensure(7, 70).?;
    for (list) |r| try t.stage(testing.allocator, tab, r);
    try testing.expect(try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = gen, .count = @intCast(list.len) }));
    return tab;
}

test "W9d④: 준비와 맺음 — 규칙이 다 오면 바꾸고, 빠지면 거절(묶음은 그대로), 다른 세대의 칸은 버리고, 0 개는 지우고, 엄격 사이트는 맺을 때" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try installRules(&t, 1, &.{ ruleMsg(1, 0, 1, "https://a.test/x", .{}), ruleMsg(1, 1, 2, "https://a.test/y", .{}) });
    try testing.expectEqual(@as(u8, 2), tab.set.?.count);
    try testing.expectEqual(@as(usize, 1), t.with_rules);
    // 세대 2 — 둘째 규칙이 빠졌다.
    try t.stage(testing.allocator, tab, ruleMsg(2, 0, 3, "https://a.test/z", .{}));
    try testing.expect(!try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = 2, .count = 2 }));
    try testing.expectEqual(@as(u32, 1), tab.set.?.generation); // 그대로
    try testing.expect(tab.staging == null);
    // 세대 3 의 규칙이 오다가 세대 4 가 오면 3 의 칸은 버린다.
    try t.stage(testing.allocator, tab, ruleMsg(3, 0, 4, "https://a.test/w", .{}));
    try t.stage(testing.allocator, tab, ruleMsg(4, 0, 5, "https://a.test/v", .{}));
    try testing.expect(!try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = 3, .count = 1 }));
    // 0 개 — 지우고 엄격만.
    try testing.expect(try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = 5, .strict_site = "a.test" }));
    try testing.expect(tab.set == null);
    try testing.expectEqualStrings("a.test", tab.strictSite());
    try testing.expectEqual(@as(usize, 0), t.with_rules);
    t.reap(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.retired.items.len);
}

test "W9d④: 덩어리 — 규칙·준비·처리기가 쥐고 모두 놓으면 푼다, 같은 번호는 다시 쓴다(본문을 다시 받지 않는다), 길이가 다르면 맺지 못한다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try installRules(&t, 1, &.{ruleMsg(1, 0, 1, "https://a.test/x", .{ .body_id = 9, .body_len = 4 })});
    const blob = tab.set.?.rules[0].blob.?;
    try testing.expectEqual(@as(u32, 1), blob.refs);
    _ = t.chunk(.{ .browser = 7, .body_id = 9, .offset = 0, .total = 4, .bytes = "abcd" });
    try testing.expect(blob.ready());
    // 같은 규칙을 다시 보낸 새 세대 — 같은 덩어리를 쓴다(다 찬 채로).
    _ = try installRules(&t, 2, &.{ruleMsg(2, 0, 1, "https://a.test/x", .{ .body_id = 9, .body_len = 4 })});
    try testing.expect(tab.set.?.rules[0].blob.? == blob and blob.ready());
    try testing.expectEqual(@as(u32, 1), blob.refs); // 새 묶음만 — 쥔 이 없는 은퇴 묶음은 바꿀 때 곧 거둔다(v2 R11)
    t.holdBlob(blob); // 처리기 하나가 쥔다
    _ = try installRules(&t, 3, &.{});
    t.reap(testing.allocator);
    try testing.expectEqual(@as(u32, 1), blob.refs); // 처리기만
    try testing.expectEqual(@as(usize, 1), t.blobs.items.len);
    t.unrefBlob(testing.allocator, blob);
    try testing.expectEqual(@as(usize, 0), t.blobs.items.len);
    try testing.expectEqual(@as(usize, 0), t.blob_bytes);
    // 같은 번호인데 길이가 다르다 — 자리를 비워 맺지 못한다.
    try t.stage(testing.allocator, tab, ruleMsg(4, 0, 1, "https://a.test/x", .{ .body_id = 11, .body_len = 4 }));
    try t.stage(testing.allocator, tab, ruleMsg(4, 1, 2, "https://a.test/y", .{ .body_id = 11, .body_len = 5 }));
    try testing.expect(!try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = 4, .count = 2 }));
    try testing.expectEqual(@as(usize, 0), t.blobs.items.len); // 버린 칸의 덩어리도 풀었다
}

test "W9d④: 조각 — 차례대로만 받고, 처리한 바이트를 조각마다 늘 확인한다(중복·다 찬 덩어리·모르는 덩어리·길이 다른 조각은 버리되 확인)" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const total: u32 = 100 * 1024;
    const tab = try installRules(&t, 1, &.{ruleMsg(1, 0, 1, "https://a.test/x", .{ .body_id = 3, .body_len = total })});
    const data = try testing.allocator.alloc(u8, total);
    defer testing.allocator.free(data);
    for (data, 0..) |*b, i| b.* = @truncate(i);
    var acks: [8]u32 = undefined;
    var n_acks: usize = 0;
    var completed = false;
    var off: u32 = 0;
    while (off < total) {
        const k: u32 = @min(16 * 1024, total - off);
        const r = t.chunk(.{ .browser = 7, .body_id = 3, .offset = off, .total = total, .bytes = data[off..][0..k] });
        if (r.ack) |a| {
            acks[n_acks] = a;
            n_acks += 1;
        }
        if (r.completed != null) completed = true;
        off += k;
    }
    try testing.expect(completed);
    try testing.expectEqualSlices(u32, &.{ 16 * 1024, 32 * 1024, 48 * 1024, 64 * 1024, 80 * 1024, 96 * 1024, total }, acks[0..n_acks]);
    try testing.expectEqualSlices(u8, data, tab.set.?.rules[0].blob.?.data);
    // 다 찬 덩어리에 다시 온 조각 — 버리되(본문은 그대로) 확인한다.
    const dup = t.chunk(.{ .browser = 7, .body_id = 3, .offset = 0, .total = total, .bytes = "x" });
    try testing.expect(dup.ack.? == 1 and dup.completed == null);
    try testing.expectEqual(@as(u8, 0), tab.set.?.rules[0].blob.?.data[0]);
    // 모르는 덩어리 — 처리한 바이트를 곧 확인.
    try testing.expectEqual(@as(?u32, 20), t.chunk(.{ .browser = 7, .body_id = 99, .offset = 10, .total = 30, .bytes = "0123456789" }).ack);
    // 길이가 다른 조각 — 버리고 확인.
    try testing.expectEqual(@as(?u32, 5), t.chunk(.{ .browser = 7, .body_id = 3, .offset = 0, .total = 5, .bytes = "abcde" }).ack);
}

test "W9d④: 맞추기 — 종류·사이트(하위 자원은 페이지·주 프레임은 홉 호스트)·페이지 모름·실행 출처·D2·사람(사용자 탭 규칙만)·메서드(패턴 뒤에만 읽는다)·첫 규칙·preload 빠짐" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    _ = try installRules(&t, 1, &.{
        ruleMsg(1, 0, 1, "https://a.test/api/*", .{ .types = 1 << 13, .methods = rules.methodBit("POST").? }),
        ruleMsg(1, 1, 2, "https://a.test/api/*", .{}),
        ruleMsg(1, 2, 3, "https://b.test/*", .{ .exec = "a.test", .human = true }),
        ruleMsg(1, 3, 4, "https://a.test/doc", .{ .human = true }),
    });
    var a = t.acquire(70).?;
    const api = u16s("https://a.test/api/x");
    var reads: u32 = 0;
    try testing.expectEqual(@as(u32, 1), (decideTab(&a, .{ .url = &api, .resource_type = 13, .main_nav = false, .page_host = "a.test" }, Method{ .m = "POST", .reads = &reads })).mock.id);
    try testing.expectEqual(@as(u32, 2), (decideTab(&a, .{ .url = &api, .resource_type = 13, .main_nav = false, .page_host = "a.test" }, Method{ .m = "GET", .reads = &reads })).mock.id); // 메서드가 다르면 다음 규칙
    try testing.expectEqual(@as(u32, 2), reads);
    try testing.expectEqual(@as(u32, 2), (decideTab(&a, .{ .url = &api, .resource_type = 3, .main_nav = false, .page_host = "app.a.test" }, NoMethod{})).mock.id); // 종류가 다르면 메서드를 읽지 않는다
    try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &api, .resource_type = 3, .main_nav = false, .page_host = "c.test" }, NoMethod{})); // 다른 사이트에서는 잠든다
    try testing.expectEqual(Verdict.unknown_page, decideTab(&a, .{ .url = &api, .resource_type = 3, .main_nav = false, .page_host = "" }, NoMethod{}));
    try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &api, .resource_type = 19, .main_nav = true }, NoMethod{})); // navigation preload
    // 실행 출처 — 묶인 사이트 a.test 가 b.test 문서를 덮지 않는다(iframe·주 프레임). 문서가 아니면 요청을 낸 문맥의 출처로 돈다: a.test 문맥이
    // 부른 b.test 스크립트는 가짜, b.test iframe(허락 밖)이 부른 것·문맥을 모르는 것은 진짜(v1 SEVERE-1) — 그 규칙의 frame_not_mocked 를 센다.
    const b = u16s("https://b.test/frame");
    try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &b, .resource_type = 1, .main_nav = false, .page_host = "a.test", .initiator_host = "a.test" }, NoMethod{}));
    try testing.expectEqual(@as(u32, 3), (decideTab(&a, .{ .url = &b, .resource_type = 3, .main_nav = false, .page_host = "a.test", .initiator_host = "app.a.test" }, NoMethod{})).mock.id);
    try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &b, .resource_type = 3, .main_nav = false, .page_host = "a.test", .initiator_host = "b.test" }, NoMethod{}));
    try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &b, .resource_type = 3, .main_nav = false, .page_host = "a.test" }, NoMethod{}));
    try testing.expectEqual(@as(u32, 3), a.set.rules[2].frame_not_mocked.load(.monotonic)); // iframe 문서 하나 + 허락 밖 문맥 둘
    // 주 프레임 홉 — 규칙 사이트가 그 홉의 호스트를 덮어야. D2 는 지나가고, 사람의 누름은 사용자 탭 규칙만 지나간다.
    const doc = u16s("https://a.test/doc");
    try testing.expectEqual(@as(u32, 4), (decideTab(&a, .{ .url = &doc, .resource_type = 0, .main_nav = true }, NoMethod{})).mock.id);
    try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &doc, .resource_type = 0, .main_nav = true, .user_exempt = true }, NoMethod{}));
    try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &doc, .resource_type = 0, .main_nav = true, .human_exempt = true }, NoMethod{}));
    try testing.expectEqual(@as(u32, 4), (decideTab(&a, .{ .url = &doc, .resource_type = 2, .main_nav = false, .page_host = "a.test", .human_exempt = true }, NoMethod{})).mock.id); // 하위 자원은 그대로
    t.release(testing.allocator, 70, &a, .unknown_page);
    try testing.expectEqual(@as(u32, 1), t.findCef(70).?.skipped_unknown_page);
    try testing.expectEqual(@as(u32, 1), t.findCef(70).?.set.?.rules[0].hits.load(.monotonic));
}

test "W9d④: 사람의 누름은 에이전트 탭 규칙(human_nav_real 거짓)에는 듣지 않는다 — UD2: 사용자가 그 탭을 몰아도 규칙은 남는다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    _ = try installRules(&t, 1, &.{ruleMsg(1, 0, 1, "https://a.test/doc", .{})});
    var a = t.acquire(70).?;
    const doc = u16s("https://a.test/doc");
    try testing.expectEqual(@as(u32, 1), (decideTab(&a, .{ .url = &doc, .resource_type = 0, .main_nav = true, .human_exempt = true }, NoMethod{})).mock.id);
    t.release(testing.allocator, 70, &a, .pass);
}

test "W9d④: 처리기 풀 — 탭 128·앱 512, 넘치면 busy 를 센다, 돌려주면 다시, 잊은 탭의 처리기는 앱 몫만 돌려준다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    for (0..5) |i| _ = t.ensure(@intCast(i + 1), @intCast(10 + i));
    for (0..rules.max_handlers_tab) |_| try testing.expect(t.reserveHandler(10));
    try testing.expect(!t.reserveHandler(10));
    try testing.expectEqual(@as(u32, 1), t.findCef(10).?.busy);
    t.releaseHandler(10);
    try testing.expect(t.reserveHandler(10));
    for (1..4) |k| for (0..rules.max_handlers_tab) |_| try testing.expect(t.reserveHandler(@intCast(10 + k)));
    try testing.expectEqual(rules.max_handlers_app, t.handlers);
    try testing.expect(!t.reserveHandler(14)); // 앱이 찼다
    try t.dropAll(testing.allocator, t.findCef(10).?, true);
    t.releaseHandler(10);
    try testing.expectEqual(rules.max_handlers_app - 1, t.handlers);
    try testing.expect(t.reserveHandler(14));
}

test "W9d④: 수의 차이 — 규칙마다 맞음·서비스 워커, 탭의 문 넘김·줄 수 없음·페이지 모름·서비스 워커 표시, 은퇴 묶음의 마지막 수, 보낸 뒤는 없다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try installRules(&t, 1, &.{ruleMsg(1, 0, 3, "https://a.test/*", .{})});
    tab.set.?.rules[0].hits.store(5, .monotonic);
    _ = try installRules(&t, 2, &.{ruleMsg(2, 0, 3, "https://a.test/*", .{})});
    tab.set.?.rules[0].sw_not_mocked.store(2, .monotonic);
    t.noteUnrecorded(70);
    t.noteBusy(70);
    tab.page_controlled = true;
    var buf: [8]BrowserId = undefined;
    try testing.expectEqual(@as(usize, 1), t.browsersWithHits(&buf).len);
    const h = t.takeHits(7).?;
    try testing.expectEqual(@as(u8, 1), h.count);
    try testing.expect(h.entries[0].hits == 5 and h.entries[0].sw_not_mocked == 2);
    try testing.expect(h.unrecorded == 1 and h.busy == 1 and h.page_controlled);
    try protocol.net_fields.checkMockHits(h);
    try testing.expectEqual(@as(usize, 0), t.browsersWithHits(&buf).len);
    t.reap(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.retired.items.len);
}

test "W9d④: 서비스 워커 길의 규칙 — 패턴과 그 탭의 맨 위 호스트(규칙 사이트가 덮어야), 맨 위를 모르면 없음" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try installRules(&t, 1, &.{ruleMsg(1, 0, 3, "https://a.test/api/*", .{ .types = 1 << 13 })});
    const url = u16s("https://a.test/api/x");
    const parts = nb.splitUrl(u16, &url).?;
    try testing.expectEqual(@as(u32, 3), serviceWorkerRule(tab.set.?, parts, "app.a.test").?.id);
    try testing.expect(serviceWorkerRule(tab.set.?, parts, "b.test") == null);
    try testing.expect(serviceWorkerRule(tab.set.?, parts, "") == null);
}

test "W9d④ 변이: 덩어리 합의 방어 상한, 다 차지 않은 덩어리에 길이가 다른·앞선 조각은 받지 않는다, count 넘는 준비 칸·0 개 맺음의 남은 칸, 지켜보기 끔은 엄격도 버린다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try installRules(&t, 1, &.{ruleMsg(1, 0, 1, "https://a.test/x", .{ .body_id = 5, .body_len = 8 })});
    const blob = tab.set.?.rules[0].blob.?;
    // 길이가 다른 조각 — 다 차지 않은 덩어리에도 쓰지 않는다(확인은 한다).
    try testing.expectEqual(@as(?u32, 4), t.chunk(.{ .browser = 7, .body_id = 5, .offset = 0, .total = 4, .bytes = "zzzz" }).ack);
    try testing.expectEqual(@as(u32, 0), blob.received);
    _ = t.chunk(.{ .browser = 7, .body_id = 5, .offset = 0, .total = 8, .bytes = "abcd" });
    // 앞선 조각이 다시 왔다 — 받은 길이는 줄지 않고 바이트도 그대로.
    _ = t.chunk(.{ .browser = 7, .body_id = 5, .offset = 0, .total = 8, .bytes = "XY" });
    try testing.expectEqual(@as(u32, 4), blob.received);
    try testing.expectEqualStrings("abcd", blob.data[0..4]);
    // 덩어리 합이 방어 상한을 넘으면 그 세대는 맺지 못한다.
    const saved = t.blob_bytes;
    t.blob_bytes = max_blob_bytes_total - 3;
    try t.stage(testing.allocator, tab, ruleMsg(2, 0, 2, "https://a.test/y", .{ .body_id = 6, .body_len = 4 }));
    try testing.expect(!try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = 2, .count = 1 }));
    t.blob_bytes = saved;
    // count 보다 많은 준비 칸 — 맺지 않는다(남는 칸이 새지 않게).
    try t.stage(testing.allocator, tab, ruleMsg(3, 0, 3, "https://a.test/a", .{}));
    try t.stage(testing.allocator, tab, ruleMsg(3, 1, 4, "https://a.test/b", .{}));
    try testing.expect(!try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = 3, .count = 1 }));
    try testing.expectEqual(@as(u32, 1), tab.set.?.generation);
    // 0 개 맺음은 다른 세대의 남은 칸(과 그 덩어리)도 버린다.
    try t.stage(testing.allocator, tab, ruleMsg(4, 0, 5, "https://a.test/c", .{ .body_id = 7, .body_len = 2 }));
    try testing.expect(try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = 5, .count = 0, .strict_site = "a.test" }));
    try testing.expect(tab.staging == null);
    t.reap(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.blobs.items.len);
    // 지켜보기 끔(dropAll) — 엄격 사이트도 버린다.
    try testing.expectEqualStrings("a.test", tab.strictSite());
    try t.dropAll(testing.allocator, tab, false);
    try testing.expectEqualStrings("", tab.strictSite());
}

test "W9d④ 변이: preload 둘(19·20) 다 빠짐, 주 프레임 홉은 규칙 사이트가 그 호스트를 덮어야, 차이 없는 규칙은 수에 싣지 않는다(빈 항목은 wire 가 거절)" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try installRules(&t, 1, &.{ ruleMsg(1, 0, 1, "https://c.test/*", .{}), ruleMsg(1, 1, 2, "https://a.test/*", .{}) });
    var a = t.acquire(70).?;
    const c = u16s("https://c.test/doc");
    try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &c, .resource_type = 0, .main_nav = true }, NoMethod{})); // 규칙 사이트 a.test 가 c.test 를 덮지 않는다
    const p = u16s("https://a.test/doc");
    for ([_]u8{ 19, 20 }) |rt| try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &p, .resource_type = rt, .main_nav = true }, NoMethod{}));
    try testing.expectEqual(@as(u32, 2), (decideTab(&a, .{ .url = &p, .resource_type = 0, .main_nav = true }, NoMethod{})).mock.id);
    t.release(testing.allocator, 70, &a, .pass);
    const h = t.takeHits(7).?;
    try testing.expectEqual(@as(u8, 1), h.count);
    try testing.expectEqual(@as(u32, 2), h.entries[0].rule_id);
    try protocol.net_fields.checkMockHits(h);
    _ = tab;
}

test "W9d④ 결정 A: 공유 워커 주 스크립트(10)는 종류 없는 규칙에 맞아도 가짜가 아니다 — 그 규칙의 sw_not_mocked 를 올리고(맞음 수는 그대로) 뒤 규칙으로 넘어가지 않는다, 같은 주소의 페이지 요청·전용 워커(9)는 가짜" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    _ = try installRules(&t, 1, &.{ ruleMsg(1, 0, 1, "https://a.test/w/*", .{}), ruleMsg(1, 1, 2, "https://a.test/*", .{}) });
    var a = t.acquire(70).?;
    const w = u16s("https://a.test/w/shw.js");
    try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &w, .resource_type = rules.shared_worker_type, .main_nav = false, .page_host = "a.test" }, NoMethod{}));
    try testing.expectEqual(Verdict.unknown_page, decideTab(&a, .{ .url = &w, .resource_type = rules.shared_worker_type, .main_nav = false, .page_host = "" }, NoMethod{}));
    try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &w, .resource_type = rules.shared_worker_type, .main_nav = false, .page_host = "c.test" }, NoMethod{})); // 잠든 규칙은 세지 않는다
    for ([_]u8{ 2, 9, 13 }) |rt| try testing.expectEqual(@as(u32, 1), (decideTab(&a, .{ .url = &w, .resource_type = rt, .main_nav = false, .page_host = "a.test" }, NoMethod{})).mock.id);
    t.release(testing.allocator, 70, &a, .pass);
    const r0 = &t.findCef(70).?.set.?.rules[0];
    try testing.expectEqual(@as(u32, 1), r0.sw_not_mocked.load(.monotonic));
    try testing.expectEqual(@as(u32, 3), r0.hits.load(.monotonic));
    try testing.expectEqual(@as(u32, 0), t.findCef(70).?.set.?.rules[1].sw_not_mocked.load(.monotonic));
    const h = t.takeHits(7).?;
    try testing.expect(h.count == 1 and h.entries[0].rule_id == 1 and h.entries[0].sw_not_mocked == 1 and h.entries[0].hits == 3);
    try protocol.net_fields.checkMockHits(h);
}

test "W9d④ 변이: 잡은 은퇴 묶음은 놓기 전에 풀지 않는다, 은퇴 묶음에만 남은 수도 보낼 탭으로 센다, 같은 차례에 다시 온 규칙은 앞의 것을 푼다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const tab = try installRules(&t, 1, &.{ruleMsg(1, 0, 1, "https://a.test/*", .{ .body_id = 4, .body_len = 2 })});
    var a = t.acquire(70).?;
    tab.set.?.rules[0].hits.store(3, .monotonic);
    _ = try installRules(&t, 2, &.{});
    var buf: [8]BrowserId = undefined;
    try testing.expectEqual(@as(usize, 1), t.browsersWithHits(&buf).len); // 은퇴 묶음의 마지막 수
    _ = t.takeHits(7).?;
    t.reap(testing.allocator);
    try testing.expectEqual(@as(usize, 1), t.retired.items.len); // IO 스레드가 아직 쥐었다
    t.release(testing.allocator, 70, &a, .pass);
    t.reap(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.retired.items.len);
    // 같은 세대·같은 차례로 다시 온 규칙 — 앞의 칸(글·덩어리 참조)을 푼다(새지 않는다).
    try t.stage(testing.allocator, tab, ruleMsg(3, 0, 2, "https://a.test/x", .{ .body_id = 8, .body_len = 2 }));
    try t.stage(testing.allocator, tab, ruleMsg(3, 0, 2, "https://a.test/x", .{ .body_id = 9, .body_len = 2 }));
    try testing.expect(try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = 3, .count = 1 }));
    try testing.expectEqual(@as(usize, 1), t.blobs.items.len);
}

test "W9d④ v2 R11: 요청 없이 512 KiB 본문 규칙을 160 번 바꿔도(보내는 task 의 reap 없이) 맺음은 모두 되고 덩어리 합은 산 것만 — 쥔 이가 있는 은퇴 묶음은 놓을 때까지 덩어리를 지키고, 보낼 수가 남은 은퇴 묶음은 덩어리만 먼저 놓는다" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    const big = rules.max_body_bytes;
    const tab = t.ensure(7, 70).?;
    var gen: u32 = 0;
    var id: u32 = 100;
    while (gen < 160) {
        gen += 1;
        id += 1;
        try t.stage(testing.allocator, tab, ruleMsg(gen, 0, 1, "https://a.test/x", .{ .body_id = id, .body_len = big }));
        testing.expect(try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = gen, .count = 1 })) catch |e| {
            std.debug.print("commit {d} failed: blob_bytes {d} retired {d}\n", .{ gen, t.blob_bytes, t.retired.items.len });
            return e;
        };
        try testing.expect(t.blob_bytes == big and t.retired.items.len == 0);
    }
    try testing.expectEqual(id, tab.set.?.rules[0].blob.?.id);
    // 처리기 고르기가 묶음을 쥔 채 바뀐다 — 그 묶음의 덩어리는 놓을 때까지 산다(RCU — 진행 중 응답이 읽는다).
    var a = t.acquire(70).?;
    const held_blob = a.set.rules[0].blob.?;
    _ = t.chunk(.{ .browser = 7, .body_id = held_blob.id, .offset = 0, .total = big, .bytes = "q" });
    gen += 1;
    try t.stage(testing.allocator, tab, ruleMsg(gen, 0, 1, "https://a.test/x", .{ .body_id = 999, .body_len = 4 }));
    try testing.expect(try t.commit(testing.allocator, tab, .{ .browser = 7, .generation = gen, .count = 1 }));
    try testing.expectEqual(@as(usize, 1), t.retired.items.len);
    try testing.expect(!a.set.stripped and a.set.rules[0].blob.? == held_blob and held_blob.data[0] == 'q');
    try testing.expectEqual(big + 4, t.blob_bytes);
    a.set.rules[0].hits.store(2, .monotonic); // 놓기 전의 맞음 — 보낼 수가 남는다
    t.release(testing.allocator, 70, &a, .pass);
    // 마지막 읽는 이가 놓았다 — 보낼 수가 남아 묶음은 남되 덩어리는 놓았다.
    try testing.expectEqual(@as(usize, 1), t.retired.items.len);
    try testing.expect(t.retired.items[0].stripped);
    try testing.expectEqual(@as(usize, 4), t.blob_bytes);
    const h = t.takeHits(7).?;
    try testing.expect(h.count == 1 and h.entries[0].hits == 2);
    t.reap(testing.allocator);
    try testing.expectEqual(@as(usize, 0), t.retired.items.len);
    // 닫힌 탭(잊기)도 쥔 이가 없으면 곧 거둔다.
    try t.dropAll(testing.allocator, tab, true);
    try testing.expect(t.retired.items.len == 0 and t.blob_bytes == 0 and t.blobs.items.len == 0);
}

test "W9d④ v1 SEVERE-1(사용자 결정 2026-11-11 「허락 밖 iframe 요청은 모두 진짜」): 사이트에 묶인 규칙은 허락 밖 사이트의 프레임·워커가 낸 요청에 어떤 종류도 맞지 않고(주소가 grant 사이트 안이어도) frame_not_mocked 로 센다, 같은 사이트 프레임·어느 호스트든 grant 는 그대로" {
    var t: Table = .{};
    defer t.deinit(testing.allocator);
    _ = try installRules(&t, 1, &.{
        ruleMsg(1, 0, 1, "https://*.a.test/m/*", .{ .site = "a.test", .exec = "a.test", .human = true }), // 사용자 탭(사이트 grant)
        ruleMsg(1, 1, 2, "https://x.test/m/*", .{ .site = "a.test", .exec = "a.test", .human = true }), // grant 밖 주소의 자원(같은 사이트 문맥이면 가짜)
        ruleMsg(1, 2, 3, "https://agent.a.test/m/*", .{ .site = "a.test" }), // 어느 호스트든 grant(에이전트 탭)
    });
    var a = t.acquire(70).?;
    const own = u16s("https://app.a.test/m/x.js");
    const other = u16s("https://x.test/m/y.js");
    // 스크립트·스타일·이미지·전용 워커·fetch(xhr)·기타 — 다른 사이트 iframe(x.test) 문맥이면 진짜.
    for ([_]u8{ 2, 3, 5, 9, 13, 16 }) |rt| {
        try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &own, .resource_type = rt, .main_nav = false, .page_host = "a.test", .initiator_host = "x.test" }, NoMethod{}));
        try testing.expectEqual(Verdict.pass, decideTab(&a, .{ .url = &other, .resource_type = rt, .main_nav = false, .page_host = "a.test", .initiator_host = "x.test" }, NoMethod{}));
        // 같은 사이트 프레임(하위 도메인 포함) — 가짜(대조).
        try testing.expectEqual(@as(u32, 1), (decideTab(&a, .{ .url = &own, .resource_type = rt, .main_nav = false, .page_host = "a.test", .initiator_host = "frame.a.test" }, NoMethod{})).mock.id);
        try testing.expectEqual(@as(u32, 2), (decideTab(&a, .{ .url = &other, .resource_type = rt, .main_nav = false, .page_host = "a.test", .initiator_host = "a.test" }, NoMethod{})).mock.id);
    }
    try testing.expectEqual(@as(u32, 6), a.set.rules[0].frame_not_mocked.load(.monotonic));
    try testing.expectEqual(@as(u32, 6), a.set.rules[1].frame_not_mocked.load(.monotonic));
    try testing.expectEqual(@as(u32, 6), a.set.rules[0].hits.load(.monotonic));
    // 어느 호스트든 grant 의 규칙은 문맥을 묻지 않는다(에이전트 탭 — 그 탭에서는 이미 어느 사이트로든 옮겨 스크립트를 돌린다). 앞 규칙이 진짜로 넘기면
    // 다음 규칙을 본다.
    const ag = u16s("https://agent.a.test/m/z.js");
    try testing.expectEqual(@as(u32, 3), (decideTab(&a, .{ .url = &ag, .resource_type = 3, .main_nav = false, .page_host = "a.test", .initiator_host = "x.test" }, NoMethod{})).mock.id);
    try testing.expectEqual(@as(u32, 7), a.set.rules[0].frame_not_mocked.load(.monotonic));
    t.release(testing.allocator, 70, &a, .pass);
    const h = t.takeHits(7).?;
    try protocol.net_fields.checkMockHits(h);
    var got: [3]u32 = @splat(0);
    for (h.entries[0..h.count]) |e| if (e.rule_id <= 3) {
        got[e.rule_id - 1] = e.frame_not_mocked;
    };
    try testing.expectEqualSlices(u32, &.{ 7, 6, 0 }, &got);
}
