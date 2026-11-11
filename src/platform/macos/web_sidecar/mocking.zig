//! 가짜 응답(W9d④ — docs/plans/web-osr-backend.md 「W9d④ 결정·실측」). maru 의 `net_mock_rule`·`net_mock_commit` 으로 탭마다 규칙 묶음
//! (`net_mock_table`)을 두고 `net_mock_body` 로 본문 덩어리를 채운다. IO 스레드의 처리기 고르기(`network.zig`)가 막기 다음에 묻는다:
//!   - **탭 길**(`tabSelect`): 요청 번호·지켜보기·문보다 먼저(번호 0 의 speculation 도 — 실측 M5) 맞추고, 맞으면 **요청마다 하나**의 처리기
//!     (`Slot` — 자원 요청 처리기와 자원 처리기를 한 덩어리로, 참조 셈)를 준다. 맞지 않는 요청은 비용이 없다(M2 — 처리기를 맞을 때만 준다).
//!     자리를 잡을 때 풀(앱 512·탭 128)을 센다 — 넘치면 `-12` 처리기(진짜로 보내지 않는다 — M17: null 은 진짜 네트워크로 간다).
//!   - **서비스 워커 길**(`serviceWorker`): 가짜를 **주지 않는다**(사용자 결정 Q1 — 실측 M12: 서비스 워커의 `cache.add` 가 가짜를 Cache
//!     Storage 에 남겨 규칙을 지운 뒤에도·다른 탭에도 나갔다). 그 출처를 보이는 탭 중 규칙이 맞는 탭에 `sw_not_mocked` 를 센다(엄격을 쓰라).
//!     navigation preload(종류 19·20 — 탭 길로 온다, M26)도 맞추지 않는다(`net_mock_table.decideTab`). 공유 워커 **주 스크립트**(종류 10 — 만든
//!     탭의 탭 길로 온다)도 가짜로 바꾸지 않고 맞은 규칙의 `sw_not_mocked` 로 센다(사용자 결정 A 2026-11-11 — 같은 사이트의 다른 탭이 같은 워커에
//!     붙어 가짜 워커가 이 탭·규칙보다 오래 살았다).
//! 가짜 처리기: `open`(본문이 찼으면 곧, 아니면 붙잡기 — 비동기 `open`, 실측 M29; 10 초 안에 차지 않으면 `-12`) → `get_response_headers`(상태·
//! `Content-Type` 머리(M20 — 200 밖에서 `set_mime_type` 이 버려졌다)·`Cache-Control: no-store`(M21 — bfcache 가 지운 규칙의 가짜 문서를
//! 되살렸다)·`Content-Length`·허용 목록 머리·3xx 의 `Location`; HEAD 면 읽을 길이 0 — M3) → `read`(64 KiB 씩 memcpy — M1). 가짜 요청의 처리기
//! 고르기에는 늘 쿠키 필터를 단다(`can_save_cookie` 0 — 실측 M22: 머리 허용 목록이 이미 `Set-Cookie` 를 거절하지만 두 겹, 기록하지 않는
//! 요청에도).
//!
//! 스레드: 표·덩어리·붙잡은 처리기 목록은 이 파일의 뮤텍스 아래(IO·UI 스레드). 막기의 잠금·네트워크 lock·공용 예외 표의 잠금과 **함께 쥐지
//! 않는다**. CEF 콜백(`cont`)은 잠금 밖에서 부른다. IO 스레드에서는 쓰지도 로그하지도 않는다(W9d① M6) — 수는 원자로 올리고 `network.zig` 의
//! 보내는 task 가 모아 보낸다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const table_mod = @import("net_mock_table.zig");
const nav_exempt = @import("nav_exempt.zig");
const blocking = @import("blocking.zig");
const inbox = @import("inbox.zig");

const msg = protocol.message;
const nb = protocol.net_block;
const rules = protocol.net_mock_rules;
const net_policy = protocol.net_policy;
const BrowserId = msg.BrowserId;
const gpa = std.heap.c_allocator;

comptime {
    // 가짜 본문 창의 comptime 합(`net_fields`)은 이 크기를 전제한다.
    std.debug.assert(inbox.capacity == msg.sidecar_inbox_bytes);
}

var lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;
var table: table_mod.Table = .{};
/// 규칙이 있는 탭이 하나라도 있다 — 처리기 고르기의 가장 흔한 길은 이것만 본다.
var any_rules = std.atomic.Value(bool).init(false);
/// 본문을 기다리며 붙잡은 처리기(잠금 아래 — 참조 하나씩 쥔다).
var held: std.ArrayList(*Slot) = .empty;
var hold_task: c.cef_task_t = undefined;
var hold_posted = false;

var cookie_filter: c.cef_cookie_access_filter_t = undefined;
var busy_handler: c.cef_resource_handler_t = undefined;
/// 가짜를 줄 수 없을 때(풀이 참) — 기록하지 않는 요청·기록하는 요청(W9d① 콜백 포함).
pub var rrh_busy: c.cef_resource_request_handler_t = undefined;
pub var rrh_busy_recorded: c.cef_resource_request_handler_t = undefined;
var ready = false;

fn doLock() void {
    _ = std.c.pthread_mutex_lock(&lock);
}
fn doUnlock() void {
    _ = std.c.pthread_mutex_unlock(&lock);
}

fn api() *const library.Api {
    return browsers.state.api;
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}

fn units(value: [*c]const c.cef_string_t) []const u16 {
    if (value == null or value.*.str == null) return &.{};
    return @ptrCast(value.*.str[0..value.*.length]);
}

fn writer() *@import("events.zig").Writer {
    return browsers.state.writer;
}

fn logOn() bool {
    return std.c.getenv("MARU_WEB_TEST_MOCK_LOG") != null;
}

pub fn init() void {
    if (ready) return;
    ready = true;
    cookie_filter = object.zeroed(c.cef_cookie_access_filter_t);
    object.staticRefCounted(&cookie_filter.base);
    cookie_filter.can_send_cookie = &canSendCookie;
    cookie_filter.can_save_cookie = &canSaveCookie;
    busy_handler = object.zeroed(c.cef_resource_handler_t);
    object.staticRefCounted(&busy_handler.base);
    busy_handler.open = &busyOpen;
    busy_handler.get_response_headers = &busyHeaders;
    busy_handler.read = &busyRead;
    busy_handler.skip = &busySkip;
    busy_handler.cancel = &busyCancel;
    rrh_busy = object.zeroed(c.cef_resource_request_handler_t);
    object.staticRefCounted(&rrh_busy.base);
    rrh_busy.get_resource_handler = &getBusyHandler;
    rrh_busy_recorded = rrh_busy;
    @import("network.zig").setRecording(&rrh_busy_recorded);
    hold_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&hold_task.base);
    hold_task.execute = &holdTimer;
}

/// 규칙이 있는 탭이 있는가(IO 스레드 — 값싸게).
pub fn anyRules() bool {
    return any_rules.load(.acquire);
}

fn refreshAny() void {
    any_rules.store(table.with_rules > 0, .release);
}

// ── 쿠키 필터(가짜 요청의 처리기 고르기마다) ──────────────────────────────────────────────────────────────

fn canSendCookie(_: [*c]c.cef_cookie_access_filter_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, _: [*c]const c.cef_cookie_t) callconv(.c) c_int {
    object.releaseArg(browser);
    object.releaseArg(frame);
    object.releaseArg(request);
    return 1; // 가짜 요청에 실린 쿠키는 브라우저 밖으로 나가지 않는다(처리기가 어디에도 보내지 않는다 — §13 P1-2)
}

fn canSaveCookie(_: [*c]c.cef_cookie_access_filter_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, response: [*c]c.cef_response_t, _: [*c]const c.cef_cookie_t) callconv(.c) c_int {
    object.releaseArg(browser);
    object.releaseArg(frame);
    object.releaseArg(request);
    object.releaseArg(response);
    return 0; // 실측 M22 — 0 이면 가짜의 `Set-Cookie` 가 저장되지 않는다(머리 허용 목록이 이미 거절한다 — 두 겹)
}

fn getCookieFilter(_: [*c]c.cef_resource_request_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t) callconv(.c) [*c]c.cef_cookie_access_filter_t {
    object.releaseArg(browser);
    object.releaseArg(frame);
    object.releaseArg(request);
    return &cookie_filter;
}

// ── `-12` 처리기(정적) ─────────────────────────────────────────────────────────────────────────────────────

fn getBusyHandler(_: [*c]c.cef_resource_request_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t) callconv(.c) [*c]c.cef_resource_handler_t {
    object.releaseArg(browser);
    object.releaseArg(frame);
    object.releaseArg(request);
    return &busy_handler;
}

fn busyOpen(_: [*c]c.cef_resource_handler_t, request: [*c]c.cef_request_t, handle_request: [*c]c_int, callback: [*c]c.cef_callback_t) callconv(.c) c_int {
    object.releaseArg(request);
    object.releaseArg(callback);
    handle_request.* = 1;
    return 1;
}

fn busyHeaders(_: [*c]c.cef_resource_handler_t, response: [*c]c.cef_response_t, length: [*c]i64, _: [*c]c.cef_string_t) callconv(.c) void {
    defer object.releaseArg(response);
    if (response != null) response.*.set_error.?(response, rules.err_insufficient_resources);
    length.* = 0;
}

fn busyRead(_: [*c]c.cef_resource_handler_t, _: ?*anyopaque, _: c_int, bytes_read: [*c]c_int, callback: [*c]c.cef_resource_read_callback_t) callconv(.c) c_int {
    object.releaseArg(callback);
    bytes_read.* = 0;
    return 0;
}

fn busySkip(_: [*c]c.cef_resource_handler_t, _: i64, skipped: [*c]i64, callback: [*c]c.cef_resource_skip_callback_t) callconv(.c) c_int {
    object.releaseArg(callback);
    skipped.* = -2;
    return 0;
}

fn busyCancel(_: [*c]c.cef_resource_handler_t) callconv(.c) void {}

// ── 요청마다의 가짜 처리기(참조 셈) ────────────────────────────────────────────────────────────────────────

/// 가짜 응답 하나 — 자원 요청 처리기(`rrh` — CEF 가 그 홉에 쓴다)와 자원 처리기(`h`)를 한 덩어리로 둔다. 참조는 둘을 합쳐 센다. 잡은 규칙 묶음의
/// `readers` 하나와 처리기 풀의 자리 하나를 쥐고, 마지막 참조가 풀리면 돌려준다(규칙을 지우거나 바꿔도 이 응답은 끝까지 그 덩어리로 — §7).
pub const Slot = struct {
    rrh: c.cef_resource_request_handler_t,
    h: c.cef_resource_handler_t,
    refs: std.atomic.Value(u32),
    cef_id: c_int,
    set: *table_mod.RuleSet,
    rule: *table_mod.Rule,
    head: bool,
    /// 줄 수 없게 됐다(본문 시한) — 머리에서 `-12`.
    failed: bool = false,
    off: usize = 0,
    // 붙잡기(잠금 아래).
    held: bool = false,
    hold_cb: [*c]c.cef_callback_t = null,
    hold_until: i64 = 0,

    pub fn ruleId(self: *const Slot) u32 {
        return self.rule.id;
    }

    /// 이 응답이 주는 본문의 번호(0 = 빈 본문) — 끝의 `net_end.mock_body_id`(maru 의 기록이 실제로 준 본문과 짝짓는다 — v2 R11 곁). 묶음을 쥐므로
    /// 덩어리는 이 응답이 끝날 때까지 산다.
    pub fn bodyId(self: *const Slot) u32 {
        return if (self.rule.blob) |b| b.id else 0;
    }

    /// 가짜가 리다이렉트(3xx + Location)를 준다.
    pub fn redirects(self: *const Slot) bool {
        return self.rule.location.len != 0;
    }

    /// CEF 에 돌려줄 자원 요청 처리기 — `recorded` 면 W9d① 기록 콜백을 단다(문을 지난 요청).
    pub fn handlerFor(self: *Slot, recorded: bool) [*c]c.cef_resource_request_handler_t {
        if (recorded) @import("network.zig").setRecording(&self.rrh);
        return &self.rrh;
    }
};

fn slotOfRrhBase(b: [*c]c.cef_base_ref_counted_t) *Slot {
    const r: *c.cef_resource_request_handler_t = @fieldParentPtr("base", @as(*c.cef_base_ref_counted_t, @ptrCast(b)));
    return @fieldParentPtr("rrh", r);
}

fn slotOfHBase(b: [*c]c.cef_base_ref_counted_t) *Slot {
    const h: *c.cef_resource_handler_t = @fieldParentPtr("base", @as(*c.cef_base_ref_counted_t, @ptrCast(b)));
    return @fieldParentPtr("h", h);
}

fn slotOfH(h: [*c]c.cef_resource_handler_t) *Slot {
    return @fieldParentPtr("h", @as(*c.cef_resource_handler_t, @ptrCast(h)));
}

fn slotOfRrh(r: [*c]c.cef_resource_request_handler_t) *Slot {
    return @fieldParentPtr("rrh", @as(*c.cef_resource_request_handler_t, @ptrCast(r)));
}

fn rrhAddRef(b: [*c]c.cef_base_ref_counted_t) callconv(.c) void {
    _ = slotOfRrhBase(b).refs.fetchAdd(1, .monotonic);
}
fn rrhRelease(b: [*c]c.cef_base_ref_counted_t) callconv(.c) c_int {
    return @intFromBool(releaseSlot(slotOfRrhBase(b)));
}
fn rrhHasOne(b: [*c]c.cef_base_ref_counted_t) callconv(.c) c_int {
    return @intFromBool(slotOfRrhBase(b).refs.load(.acquire) == 1);
}
fn rrhHasAtLeastOne(b: [*c]c.cef_base_ref_counted_t) callconv(.c) c_int {
    return @intFromBool(slotOfRrhBase(b).refs.load(.acquire) >= 1);
}
fn hAddRef(b: [*c]c.cef_base_ref_counted_t) callconv(.c) void {
    _ = slotOfHBase(b).refs.fetchAdd(1, .monotonic);
}
fn hRelease(b: [*c]c.cef_base_ref_counted_t) callconv(.c) c_int {
    return @intFromBool(releaseSlot(slotOfHBase(b)));
}
fn hHasOne(b: [*c]c.cef_base_ref_counted_t) callconv(.c) c_int {
    return @intFromBool(slotOfHBase(b).refs.load(.acquire) == 1);
}
fn hHasAtLeastOne(b: [*c]c.cef_base_ref_counted_t) callconv(.c) c_int {
    return @intFromBool(slotOfHBase(b).refs.load(.acquire) >= 1);
}

/// 참조 하나를 놓는다 — 마지막이면 묶음의 `readers`·풀의 자리를 돌려주고 푼다. 풀었으면 참.
fn releaseSlot(s: *Slot) bool {
    if (s.refs.fetchSub(1, .acq_rel) != 1) return false;
    doLock();
    table.unread(gpa, s.set); // 은퇴 묶음의 마지막 읽는 이면 거둔다(v2 R11)
    table.releaseHandler(s.cef_id);
    doUnlock();
    gpa.destroy(s);
    return true;
}

fn newSlot(cef_id: c_int, a: *const table_mod.Acquired, rule: *table_mod.Rule, head: bool) ?*Slot {
    const s = gpa.create(Slot) catch return null;
    s.* = .{ .rrh = object.zeroed(c.cef_resource_request_handler_t), .h = object.zeroed(c.cef_resource_handler_t), .refs = .init(1), .cef_id = cef_id, .set = a.set, .rule = rule, .head = head };
    s.rrh.base.add_ref = &rrhAddRef;
    s.rrh.base.release = &rrhRelease;
    s.rrh.base.has_one_ref = &rrhHasOne;
    s.rrh.base.has_at_least_one_ref = &rrhHasAtLeastOne;
    s.rrh.get_resource_handler = &slotResourceHandler;
    s.rrh.get_cookie_access_filter = &getCookieFilter;
    s.h.base.add_ref = &hAddRef;
    s.h.base.release = &hRelease;
    s.h.base.has_one_ref = &hHasOne;
    s.h.base.has_at_least_one_ref = &hHasAtLeastOne;
    s.h.open = &hOpen;
    s.h.get_response_headers = &hHeaders;
    s.h.read = &hRead;
    s.h.skip = &hSkip;
    s.h.cancel = &hCancel;
    return s;
}

fn slotResourceHandler(r: [*c]c.cef_resource_request_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t) callconv(.c) [*c]c.cef_resource_handler_t {
    object.releaseArg(browser);
    object.releaseArg(frame);
    object.releaseArg(request);
    const s = slotOfRrh(r);
    _ = s.refs.fetchAdd(1, .monotonic); // 돌려주는 참조는 CEF 의 것
    return &s.h;
}

fn hOpen(h: [*c]c.cef_resource_handler_t, request: [*c]c.cef_request_t, handle_request: [*c]c_int, callback: [*c]c.cef_callback_t) callconv(.c) c_int {
    object.releaseArg(request);
    const s = slotOfH(h);
    doLock();
    const waiting = !s.failed and if (s.rule.blob) |b| !b.ready() else false;
    if (waiting) {
        // 본문이 다 오기 전의 맞음 — 붙잡았다가(비동기 open — 실측 M29) 본문이 차면 잇는다. 콜백의 참조는 우리가 쥔다.
        _ = s.refs.fetchAdd(1, .monotonic);
        s.held = true;
        s.hold_cb = callback;
        s.hold_until = nowMs() + rules.hold_ms;
        held.append(gpa, s) catch {
            s.held = false;
            s.hold_cb = null;
            s.failed = true;
            doUnlock();
            _ = releaseSlot(s);
            object.releaseArg(callback);
            handle_request.* = 1;
            return 1;
        };
        doUnlock();
        postHoldTimer();
        handle_request.* = 0;
        return 1;
    }
    doUnlock();
    object.releaseArg(callback);
    handle_request.* = 1;
    return 1;
}

fn setHeader(map: c.cef_string_multimap_t, name: []const u8, value: []const u8) void {
    var n = std.mem.zeroes(c.cef_string_t);
    var v = std.mem.zeroes(c.cef_string_t);
    library.setString(api(), &n, name);
    library.setString(api(), &v, value);
    defer api().string_utf16_clear(&n);
    defer api().string_utf16_clear(&v);
    _ = api().string_multimap_append(map, &n, &v);
}

fn hHeaders(h: [*c]c.cef_resource_handler_t, response: [*c]c.cef_response_t, length: [*c]i64, _: [*c]c.cef_string_t) callconv(.c) void {
    defer object.releaseArg(response);
    const s = slotOfH(h);
    length.* = 0;
    if (response == null) return;
    if (s.failed) {
        response.*.set_error.?(response, rules.err_insufficient_resources);
        return;
    }
    const r = s.rule;
    response.*.set_status.?(response, r.status);
    // mime·charset 도 맞춰 둔다(200 이면 쓰인다) — 그러나 200 밖에서는 버려지므로(M20) 머리로도 싣는다.
    const essence_len = rules.parseContentType(r.content_type) orelse r.content_type.len;
    var mb: [msg.max_net_mock_content_type_bytes]u8 = undefined;
    const essence = std.ascii.lowerString(&mb, r.content_type[0..essence_len]);
    var m = std.mem.zeroes(c.cef_string_t);
    library.setString(api(), &m, essence);
    response.*.set_mime_type.?(response, &m);
    api().string_utf16_clear(&m);
    if (std.ascii.findIgnoreCase(r.content_type, "charset=")) |at| {
        var cs_text: []const u8 = r.content_type[at + 8 ..];
        if (std.mem.indexOfScalar(u8, cs_text, ';')) |semi| cs_text = cs_text[0..semi];
        cs_text = std.mem.trim(u8, cs_text, " \t\"");
        var cs = std.mem.zeroes(c.cef_string_t);
        library.setString(api(), &cs, cs_text);
        response.*.set_charset.?(response, &cs);
        api().string_utf16_clear(&cs);
    }
    const map = api().string_multimap_alloc();
    if (map != null) {
        defer api().string_multimap_free(map);
        setHeader(map, "Content-Type", r.content_type);
        setHeader(map, "Cache-Control", "no-store");
        var lb: [16]u8 = undefined;
        setHeader(map, "Content-Length", std.fmt.bufPrint(&lb, "{d}", .{r.body_len}) catch "0");
        if (r.location.len != 0) setHeader(map, "Location", r.location);
        var it = protocol.net_fields.HeaderIterator.init(r.headerBlock());
        while (it.next()) |hdr| setHeader(map, hdr.name, hdr.value);
        // 판정자 전용 훅(`MARU_WEB_TEST_MOCK_INJECT_SET_COOKIE`): 머리 허용 목록이 `Set-Cookie` 를 wire 에서 거절하므로 둘째 겹(쿠키 필터)을 재려면
        // 여기서 넣는다 — 제품 사용자가 켤 이유는 없다(켜도 필터가 저장을 막는다).
        if (std.c.getenv("MARU_WEB_TEST_MOCK_INJECT_SET_COOKIE") != null) setHeader(map, "Set-Cookie", "mkinj=1; Path=/");
        response.*.set_header_map.?(response, map);
    }
    // HEAD 는 본문을 싣지 않는다(실측 M3 — CEF 는 가짜의 HEAD 에도 본문을 실었다). `Content-Length` 머리는 그대로(본문 길이).
    length.* = if (s.head) 0 else r.body_len;
}

fn hRead(h: [*c]c.cef_resource_handler_t, data_out: ?*anyopaque, bytes_to_read: c_int, bytes_read: [*c]c_int, callback: [*c]c.cef_resource_read_callback_t) callconv(.c) c_int {
    object.releaseArg(callback);
    const s = slotOfH(h);
    const total: usize = if (s.head or s.failed) 0 else s.rule.body_len;
    bytes_read.* = 0;
    if (s.off >= total or bytes_to_read <= 0) return 0;
    const blob = s.rule.blob orelse return 0;
    const n = @min(@as(usize, @intCast(bytes_to_read)), total - s.off);
    @memcpy(@as([*]u8, @ptrCast(data_out))[0..n], blob.data[s.off..][0..n]);
    s.off += n;
    bytes_read.* = @intCast(n);
    return 1;
}

fn hSkip(h: [*c]c.cef_resource_handler_t, bytes_to_skip: i64, skipped: [*c]i64, callback: [*c]c.cef_resource_skip_callback_t) callconv(.c) c_int {
    object.releaseArg(callback);
    const s = slotOfH(h);
    const total: usize = if (s.head or s.failed) 0 else s.rule.body_len;
    const n = @min(@as(usize, @intCast(@max(bytes_to_skip, 0))), total - @min(s.off, total));
    s.off += n;
    skipped.* = @intCast(n);
    return 1;
}

fn hCancel(h: [*c]c.cef_resource_handler_t) callconv(.c) void {
    const s = slotOfH(h);
    doLock();
    var cb: [*c]c.cef_callback_t = null;
    if (s.held) {
        removeHeld(s);
        cb = s.hold_cb;
        s.hold_cb = null;
    }
    doUnlock();
    if (cb != null) {
        object.release(cb);
        _ = releaseSlot(s);
    }
}

/// 붙잡은 목록에서 뺀다(잠금 아래).
fn removeHeld(s: *Slot) void {
    s.held = false;
    for (held.items, 0..) |x, i| if (x == s) {
        _ = held.swapRemove(i);
        return;
    };
}

/// 붙잡은 처리기들을 잇는다(잠금 밖 — CEF 가 그 자리에서 우리 콜백을 부를 수 있다).
fn resumeHeld(list: []const *Slot, cbs: []const [*c]c.cef_callback_t) void {
    for (list, cbs) |s, cb| {
        cb.*.cont.?(cb);
        object.release(cb);
        _ = releaseSlot(s);
    }
}

fn postHoldTimer() void {
    doLock();
    const already = hold_posted;
    hold_posted = true;
    doUnlock();
    if (already) return;
    if (api().post_delayed_task(c.TID_UI, &hold_task, 1000) == 0) {
        doLock();
        hold_posted = false;
        doUnlock();
    }
}

/// UI 스레드 — 시한이 지난 붙잡은 처리기를 `-12` 로 끝낸다(진짜로 보내지 않는다 — `busy` 를 센다). 남은 것이 있으면 다시 건다.
fn holdTimer(_: [*c]c.cef_task_t) callconv(.c) void {
    doLock();
    hold_posted = false;
    const before = held.items.len;
    doUnlock();
    resumeMatching(.{ .expired = nowMs() });
    doLock();
    const left = held.items.len;
    doUnlock();
    if (left < before) @import("network.zig").postFlushPublic();
    if (left > 0) postHoldTimer();
}

// ── IO 스레드: 탭 길 ───────────────────────────────────────────────────────────────────────────────────────

/// 탭 길의 답.
pub const Pick = union(enum) {
    none,
    /// 가짜 처리기(참조 하나 — CEF 에 돌려주면 CEF 의 것).
    slot: *Slot,
    /// 맞았지만 줄 수 없다(풀이 참) — `-12`.
    busy,
};

const MethodCtx = struct {
    request: [*c]c.cef_request_t,
    buf: *[msg.max_net_method_bytes]u8,
    pub fn method(self: MethodCtx) []const u8 {
        const m = self.request.*.get_method.?(self.request);
        if (m == null) return "GET";
        defer api().string_userfree_utf16_free(m);
        return library.readPrefix(api(), m, self.buf.len, self.buf).text;
    }
};

/// 탭 길의 답(막기가 맞지 않은 요청 — 막기가 이긴다). `exempt` — 공용 예외 표의 답(D2·Q2). `initiator` — CEF 의 `request_initiator`(요청을 낸
/// 프레임·워커의 출처 — 프레임 주소는 IO 스레드에서 비거나 낡았다, `network.zig` M4): 실행 사이트에 묶인 규칙은 문서가 아닌 요청을 그 출처의
/// 호스트를 grant 가 덮을 때만 바꾼다(v1 SEVERE-1). 없거나 읽지 못하면 모르는 문맥(진짜).
pub fn tabSelect(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, is_navigation: c_int, initiator: [*c]const c.cef_string_t, exempt: nav_exempt.Exempt) Pick {
    if (!anyRules()) return .none;
    const cef_id = browser.*.get_identifier.?(browser);
    const main_nav = is_navigation != 0 and frame != null and frame.*.is_main.?(frame) != 0;
    const raw = request.*.get_url.?(request);
    defer if (raw != null) api().string_userfree_utf16_free(raw);
    const url = units(raw);
    if (url.len == 0) return .none;
    var rt: u8 = @intCast(@min(@as(c_uint, @intCast(request.*.get_resource_type.?(request))), msg.max_net_resource_type));
    if (rt == 18) rt = 6; // `network.zig` 와 같은 바꾸기
    doLock();
    var a = table.acquire(cef_id) orelse {
        doUnlock();
        return .none;
    };
    doUnlock();
    var sb: [msg.max_net_host_bytes]u8 = undefined;
    const site = if (main_nav) "" else blk: {
        const fp = request.*.get_first_party_for_cookies.?(request);
        defer if (fp != null) api().string_userfree_utf16_free(fp);
        break :blk table_mod.urlHost(u16, units(fp), &sb);
    };
    const page = if (main_nav) "" else net_policy.pageHost(site, a.topHost());
    // 요청을 낸 문맥의 호스트(하위 자원만 — 주 프레임 이동은 문서라 주소로 가른다). 온 글에서 읽는다(소문자 — http(s) 가 아니거나 `null`(불투명
    // 출처)·ASCII 밖·호스트 규칙 밖이면 빈 글 = 모른다).
    var ihb: [msg.max_net_host_bytes]u8 = undefined;
    const initiator_host: []const u8 = if (main_nav) "" else net_policy.hostOfUrl16(units(initiator), &ihb);
    var mbuf: [msg.max_net_method_bytes]u8 = undefined;
    const verdict = table_mod.decideTab(&a, .{ .url = url, .resource_type = rt, .main_nav = main_nav, .page_host = page, .user_exempt = exempt.user, .human_exempt = exempt.human, .initiator_host = initiator_host }, MethodCtx{ .request = request, .buf = &mbuf });
    switch (verdict) {
        .mock => |rule| {
            const head = std.mem.eql(u8, (MethodCtx{ .request = request, .buf = &mbuf }).method(), "HEAD");
            doLock();
            const room = table.reserveHandler(cef_id);
            if (!room) {
                table.unread(gpa, a.set);
                doUnlock();
                return .busy;
            }
            doUnlock();
            // 잡은 `readers` 와 풀 자리는 처리기에 옮겨 간다(처리기가 풀릴 때 돌려준다).
            const s = newSlot(cef_id, &a, rule, head) orelse {
                doLock();
                table.unread(gpa, a.set);
                table.releaseHandler(cef_id);
                table.noteBusy(cef_id);
                doUnlock();
                return .busy;
            };
            return .{ .slot = s };
        },
        else => {
            doLock();
            table.release(gpa, cef_id, &a, verdict);
            doUnlock();
            return .none;
        },
    }
}

/// 문을 지나지 못해(또는 번호 0·지켜보지 않음) 기록 없이 가짜를 줬다.
pub fn noteUnrecorded(cef_id: c_int) void {
    doLock();
    table.noteUnrecorded(cef_id);
    doUnlock();
}

// ── IO 스레드: 서비스 워커 길 ──────────────────────────────────────────────────────────────────────────────

/// 서비스 워커 길(공유 context 처리기 — 브라우저가 없는 요청): 가짜를 주지 않고, 그 출처를 보이는 탭 중 맞는 규칙을 쥔 탭에 `sw_not_mocked` 를
/// 센다. 셌으면 참(보내는 task 를 깨운다).
pub fn serviceWorker(request: [*c]c.cef_request_t, origin: []const u8) bool {
    if (!anyRules() or origin.len == 0) return false;
    const raw = request.*.get_url.?(request);
    defer if (raw != null) api().string_userfree_utf16_free(raw);
    const url = units(raw);
    const parts = nb.splitUrl(u16, url) orelse return false;
    const membership = blocking.membershipFor(origin);
    var counted = false;
    doLock();
    defer doUnlock();
    for (membership.slice()) |mem| {
        if (!mem.shows) continue;
        const t = table.findCef(mem.cef_id) orelse continue;
        const set = t.set orelse continue;
        const rule = table_mod.serviceWorkerRule(set, parts, t.topHost()) orelse continue;
        table_mod.bump(&rule.sw_not_mocked);
        t.page_controlled = true;
        counted = true;
    }
    return counted;
}

// ── UI 스레드: maru 의 명령 ─────────────────────────────────────────────────────────────────────────────

/// `net_mock_rule` — 그 세대의 준비 칸에 넣는다(지켜보는 탭만 — 아니면 맺음이 거절한다).
pub fn applyRule(v: msg.NetMockRule) void {
    init();
    const entry = browsers.state.registry.byId(v.browser) orelse return;
    if (!@import("network.zig").watching(v.browser)) return;
    doLock();
    defer doUnlock();
    const t = table.ensure(v.browser, entry.cef_id) orelse return;
    table.stage(gpa, t, v) catch {};
}

/// `net_mock_body` — 덩어리를 채운다. 확인(`net_mock_ack`)을 보내고, 막 다 찼으면 붙잡은 처리기를 모두 잇는다.
pub fn applyBody(v: msg.NetMockBody) void {
    init();
    doLock();
    const r = table.chunk(v);
    doUnlock();
    if (r.ack) |received| writer().send(.{ .net_mock_ack = .{ .browser = v.browser, .body_id = v.body_id, .received = received } }) catch {};
    if (r.completed) |blob| resumeMatching(.{ .blob = blob });
}

/// 붙잡은 처리기 중 고르는 것을 모두 잇는다 — 잠금 아래에서 64 개씩 꺼내 잠금 밖에서 잇는다(탭 128 이 한 번에 찰 수 있다). `fail` 이면 `-12` 로.
const Which = union(enum) { blob: *table_mod.Blob, cef_id: c_int, expired: i64 };

fn resumeMatching(which: Which) void {
    while (true) {
        var list: [64]*Slot = undefined;
        var cbs: [64][*c]c.cef_callback_t = undefined;
        var n: usize = 0;
        doLock();
        var i: usize = 0;
        while (i < held.items.len and n < list.len) {
            const s = held.items[i];
            const hit = switch (which) {
                .blob => |b| s.rule.blob == b,
                .cef_id => |id| s.cef_id == id,
                .expired => |now| now >= s.hold_until,
            };
            if (hit) {
                if (which != .blob) s.failed = true;
                if (which == .expired) table.noteBusy(s.cef_id);
                s.held = false;
                _ = held.swapRemove(i);
                list[n] = s;
                cbs[n] = s.hold_cb;
                s.hold_cb = null;
                n += 1;
            } else i += 1;
        }
        doUnlock();
        resumeHeld(list[0..n], cbs[0..n]);
        if (n < list.len) return;
    }
}

/// `net_mock_commit` — 그 세대를 맺고 가짜 엄격을 맞춘다. 답은 `net_mock_state`(엄격 CDP 를 기다리면 그 답이 온 뒤 같은 세대로 다시).
pub fn applyCommit(v: msg.NetMockCommit) void {
    init();
    const entry = browsers.state.registry.byId(v.browser) orelse {
        writer().send(.{ .net_mock_state = .{ .browser = v.browser, .generation = v.generation, .ok = false } }) catch {};
        return;
    };
    const watching = @import("network.zig").watching(v.browser);
    var ok = false;
    doLock();
    if (table.ensure(v.browser, entry.cef_id)) |t| {
        if (watching) {
            ok = table.commit(gpa, t, v) catch false;
        } else table.dropAll(gpa, t, false) catch {};
        t.generation_sent = v.generation;
        t.last_ok = ok;
    }
    refreshAny();
    const strict_site = if (table.findCef(entry.cef_id)) |t| t.strictSite() else "";
    var site_buf: [msg.max_net_host_bytes]u8 = undefined;
    @memcpy(site_buf[0..strict_site.len], strict_site);
    doUnlock();
    const st = blocking.setMockStrict(entry, if (ok) site_buf[0..strict_site.len] else "");
    if (logOn()) std.debug.print("mock: commit b={d} gen={d} count={d} ok={} strict={s}\n", .{ v.browser, v.generation, v.count, ok, if (st) |x| @tagName(x) else "waiting" });
    writer().send(.{ .net_mock_state = .{ .browser = v.browser, .generation = v.generation, .ok = ok, .strict = if (ok) (st orelse .off) else .off } }) catch {};
}

/// 엄격 CDP 의 답이 다 왔다(`blocking.zig`) — 가짜 엄격이 있는 탭이면 지금 세대로 상태를 다시 알린다.
pub fn strictSettled(browser: BrowserId, state: msg.NetStrictState) void {
    doLock();
    const t = table.find(browser);
    const send = if (t) |x| x.strict_len != 0 and x.last_ok else false;
    const gen = if (t) |x| x.generation_sent else 0;
    doUnlock();
    if (send) writer().send(.{ .net_mock_state = .{ .browser = browser, .generation = gen, .ok = true, .strict = state } }) catch {};
}

/// 지켜보기가 꺼졌다 — 그 탭의 규칙·준비·엄격을 버리고 붙잡은 처리기를 `-12` 로 끝낸다(계획 §8).
pub fn watchOff(browser: BrowserId) void {
    init();
    const entry = browsers.state.registry.byId(browser) orelse return;
    dropTab(entry.cef_id, false);
}

/// 브라우저가 닫힌다 — 표·붙잡은 처리기에서 뺀다.
pub fn browserClosed(cef_id: c_int) void {
    init();
    dropTab(cef_id, true);
}

fn dropTab(cef_id: c_int, forget: bool) void {
    doLock();
    if (table.findCef(cef_id)) |t| table.dropAll(gpa, t, forget) catch {};
    refreshAny();
    doUnlock();
    resumeMatching(.{ .cef_id = cef_id });
}

/// 주 프레임 주소가 바뀌었다(확정) — 맨 위 호스트(규칙의 사이트 묶기).
pub fn addressChanged(browser: [*c]c.cef_browser_t, url: [*c]const c.cef_string_t) void {
    if (browser == null) return;
    const cef_id = browser.*.get_identifier.?(browser);
    const entry = browsers.state.registry.byCefId(cef_id);
    var hb: [msg.max_net_host_bytes]u8 = undefined;
    const host = table_mod.urlHost(u16, units(url), &hb);
    doLock();
    table.committed(if (entry) |e| e.id else 0, cef_id, host);
    doUnlock();
}

// ── 보내는 task(`network.zig` 의 flush — UI 스레드) ────────────────────────────────────────────────────────

/// 모은 수의 차이를 보내고 다 쓴 은퇴 묶음을 푼다.
pub fn flushHits() void {
    var hits: [table_mod.capacity * 2]msg.NetMockHits = undefined;
    var n: usize = 0;
    doLock();
    var ids: [table_mod.capacity * 2]BrowserId = undefined;
    for (table.browsersWithHits(&ids)) |b| {
        if (table.takeHits(b)) |h| {
            hits[n] = h;
            n += 1;
        }
    }
    table.reap(gpa);
    doUnlock();
    for (hits[0..n]) |h| writer().send(.{ .net_mock_hits = h }) catch {};
}
