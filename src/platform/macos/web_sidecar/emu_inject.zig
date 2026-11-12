//! 밖→안 홉의 문서 요청 하나에 흉내 머리를 직접 넣는다(W9e① — 사용자 결정 2026-11-12 「그 한 요청만 머리를 직접 넣기」, docs/plans/web-osr-backend.md
//! 「W9e① 결정·실측」). 사이트에 묶인 탭이 사이트 밖 문서를 보이는 채 묶인 사이트로 가는 이동을 기다리는 동안(`emu_plan.Tab.hold`) 탭 전체의
//! `Emulation.setUserAgentOverride` 는 커밋까지 미룬다 — 홉에서 걸면 기다리는 동안 그 옛(밖의) 문서가 만든 iframe 문서·form 대상·Worker 스크립트
//! 요청이 허락하지 않은 사이트로 흉내 UA·Accept-Language 를 실었다(집중 검증 1 회차 SEVERE). 대신 그 홉의 **주 프레임 문서 요청**에만 흉내
//! `User-Agent`·client hints(·`Accept-Language`)를 넣는다(값은 `emu_plan.Inject` — 커밋 뒤 Chromium 이 낼 머리와 같은 꼴).
//!
//! - 어느 요청인가: 그 탭(CEF 브라우저 번호)의 주 프레임 문서 요청이고, 주소의 정규 해시가 UI 스레드가 `on_before_browse` 에서 적은 그 홉의 주소와
//!   같을 때만(`net_block_table.canonHash` — 사용자 이동 예외 `nav_exempt` 와 같은 짝짓기). 리다이렉트 홉마다 `on_before_browse` 가 먼저 새 홉을
//!   적는다 — 안→안 홉은 그 주소로 다시 넣고, 안→밖 홉은 UI 스레드가 이미 거뒀다(주소도 다르다).
//! - 넣은 머리는 다음 홉에 남지 않는다: Chromium 이 리다이렉트 홉마다 UA·client hints·Accept-Language 를 다시 셈해 이 처리기 앞에 둔다(실측 CEF 154 —
//!   밖 → 안 302 → 밖의 밖 홉 머리가 넣기 전 그대로 진짜; 판정 `emu-site-bound-hop-headers` 가 지킨다). 그래서 되돌림 기록을 두지 않는다.
//! - `Accept-Language` 는 넣어도 그 요청은 진짜 값으로 나갔다(실측 CEF 154 — 머리 지도에는 흉내 값이 있는데 서버는 진짜를 받았다; `set_header_by_name`
//!   도 같다 — 우리 처리기 뒤에서 다시 정해진다). 그 한 요청의 언어는 늦다(문서화 — 커밋 뒤 요청부터 흉내). 넣기는 남겨 둔다(듣는 CEF 면 맞는다).
//! - 끝: 커밋(`on_load_start`)·끊김·오류 페이지·안→밖 홉·지움·철회·다른 사이트로 바뀐 grant 가 UI 스레드에서 곧 거둔다(그 뒤 요청부터 — 이미 나간
//!   문서 요청은 그때 허락 상태였다).
//!
//! 스레드: `set`·`clear` 는 UI 스레드, `wants`·`beforeLoad` 는 IO 스레드(`network.zig` 의 처리기 고르기와 그 처리기). 표는 이 파일의 뮤텍스 아래.
//! IO 스레드에서는 쓰지도 로그하지도 않는다(W9d① M6). 기다리는 탭이 없으면 원자 하나만 본다.

const std = @import("std");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const emu_plan = @import("emu_plan.zig");
const table_mod = @import("net_block_table.zig");

var lock: std.c.pthread_mutex_t = std.c.PTHREAD_MUTEX_INITIALIZER;

/// 넣기를 기다리는 탭(밖→안 홉 하나 — 그 홉 주소의 정규 해시와 넣을 값).
const Slot = struct { cef_id: c_int, canon: u64, inj: emu_plan.Inject };
var slots: [registry_mod.capacity]?Slot = @splat(null);

/// 기다리는 탭의 수(IO 스레드의 빠른 길 — 0 이면 처리기 고르기가 뮤텍스를 잡지 않는다).
var live = std.atomic.Value(u32).init(0);

/// 넣기만 하는 처리기 — 지켜보기·막기·가짜가 처리기를 주지 않는 요청에 쓴다(그 셋의 처리기는 `network.onBeforeResourceLoad` 에서 `beforeLoad` 를
/// 부른다).
pub var rrh: c.cef_resource_request_handler_t = undefined;
var ready = false;

fn api() *const library.Api {
    return browsers.state.api;
}

fn doLock() void {
    _ = std.c.pthread_mutex_lock(&lock);
}

fn doUnlock() void {
    _ = std.c.pthread_mutex_unlock(&lock);
}

/// 처리기 구조체를 채운다(UI 스레드 — `network.init`).
pub fn init() void {
    if (ready) return;
    ready = true;
    rrh = object.zeroed(c.cef_resource_request_handler_t);
    object.staticRefCounted(&rrh.base);
    rrh.on_before_resource_load = &onBeforeResourceLoad;
}

fn recount() void {
    var n: u32 = 0;
    for (slots) |s| if (s != null) {
        n += 1;
    };
    live.store(n, .release);
}

// ── UI 스레드 ───────────────────────────────────────────────────────────────────────────────────────────

/// 그 탭의 밖→안 홉(주소의 정규 해시 `canon`)에 넣을 머리 — 홉·`emulation` 이 바꿀 때마다 부른다.
pub fn set(cef_id: c_int, canon: u64, inj: *const emu_plan.Inject) void {
    doLock();
    defer doUnlock();
    var free: ?*?Slot = null;
    for (&slots) |*s| {
        if (s.*) |*v| if (v.cef_id == cef_id) {
            v.canon = canon;
            v.inj = inj.*;
            return;
        };
        if (s.* == null and free == null) free = s;
    }
    const at = free orelse return; // 탭 수는 등록부의 상한과 같다 — 오지 않는다
    at.* = .{ .cef_id = cef_id, .canon = canon, .inj = inj.* };
    recount();
}

/// 그 탭에 넣지 않는다(기다림이 끝났다·흉내가 비었다·다른 사이트·탭이 닫혔다).
pub fn clear(cef_id: c_int) void {
    if (live.load(.acquire) == 0) return; // UI 스레드만 쓴다 — 0 이면 지울 것이 없다
    doLock();
    defer doUnlock();
    for (&slots) |*s| if (s.*) |v| if (v.cef_id == cef_id) {
        s.* = null;
    };
    recount();
}

// ── IO 스레드 ───────────────────────────────────────────────────────────────────────────────────────────

fn units(value: [*c]const c.cef_string_t) []const u16 {
    if (value == null or value.*.str == null) return &.{};
    return @ptrCast(value.*.str[0..value.*.length]);
}

/// 처리기 고르기(`network.resourceRequestHandler`) — 이 요청이 기다리는 탭의 주 프레임 이동인가(주소 짝은 `beforeLoad` 가 본다).
pub fn wants(browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, is_navigation: c_int) bool {
    if (live.load(.acquire) == 0 or browser == null or request == null) return false;
    if (is_navigation == 0 or frame == null or frame.*.is_main.?(frame) == 0) return false;
    const cef_id = browser.*.get_identifier.?(browser);
    doLock();
    defer doUnlock();
    for (slots) |s| if (s) |v| if (v.cef_id == cef_id) return true;
    return false;
}

fn onBeforeResourceLoad(_: [*c]c.cef_resource_request_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, request: [*c]c.cef_request_t, callback: [*c]c.cef_callback_t) callconv(.c) c.cef_return_value_t {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    defer object.releaseArg(request);
    defer object.releaseArg(callback);
    beforeLoad(browser, request);
    return c.RV_CONTINUE;
}

/// 요청이 나가기 전(IO 스레드 — 홉마다): 그 탭이 기다리는 홉의 주 프레임 문서 요청이면 머리를 넣는다. 인자의 참조는 부른 쪽이 놓는다.
pub fn beforeLoad(browser: [*c]c.cef_browser_t, request: [*c]c.cef_request_t) void {
    if (live.load(.acquire) == 0 or browser == null or request == null) return;
    if (request.*.get_resource_type.?(request) != c.RT_MAIN_FRAME) return; // iframe·Worker·하위 자원은 넣지 않는다
    const cef_id = browser.*.get_identifier.?(browser);
    const raw = request.*.get_url.?(request);
    defer if (raw != null) api().string_userfree_utf16_free(raw);
    const canon = table_mod.canonHash(u16, units(raw));
    doLock();
    defer doUnlock();
    for (&slots) |*s| if (s.*) |*v| if (v.cef_id == cef_id and v.canon == canon) return inject(request, &v.inj);
}

fn appendText(map: c.cef_string_multimap_t, name: []const u8, value: []const u8) void {
    var n = std.mem.zeroes(c.cef_string_t);
    var v = std.mem.zeroes(c.cef_string_t);
    library.setString(api(), &n, name);
    library.setString(api(), &v, value);
    defer api().string_utf16_clear(&n);
    defer api().string_utf16_clear(&v);
    _ = api().string_multimap_append(map, &n, &v);
}

/// 머리를 넣는다(잠금 아래) — 머리 지도를 새로 짜서 한 번에 바꾼다(`Inject.action` — 지킴·바꿈·뺌; UA·언어는 없으면 더한다).
fn inject(request: [*c]c.cef_request_t, inj: *const emu_plan.Inject) void {
    const a = api();
    const map = a.string_multimap_alloc();
    if (map == null) return;
    defer a.string_multimap_free(map);
    const out = a.string_multimap_alloc();
    if (out == null) return;
    defer a.string_multimap_free(out);
    request.*.get_header_map.?(request, map);
    var seen_ua = false;
    var seen_al = false;
    const n = a.string_multimap_size(map);
    var i: usize = 0;
    while (i < n) : (i += 1) {
        var k = std.mem.zeroes(c.cef_string_t);
        var v = std.mem.zeroes(c.cef_string_t);
        _ = a.string_multimap_key(map, i, &k);
        _ = a.string_multimap_value(map, i, &v);
        defer a.string_utf16_clear(&k);
        defer a.string_utf16_clear(&v);
        // 이름은 ASCII 로만 견준다(모르는 꼴의 이름은 그대로 둔다).
        var nb: [64]u8 = undefined;
        const name = asciiName(units(&k), &nb) orelse {
            _ = a.string_multimap_append(out, &k, &v);
            continue;
        };
        if (std.ascii.eqlIgnoreCase(name, "user-agent")) seen_ua = true;
        if (std.ascii.eqlIgnoreCase(name, "accept-language")) seen_al = true;
        switch (inj.action(name)) {
            .keep => {
                _ = a.string_multimap_append(out, &k, &v);
            },
            .drop => {},
            .set => |value| appendText(out, name, value),
        }
    }
    if (!seen_ua) if (inj.userAgent()) |ua| appendText(out, "User-Agent", ua);
    if (!seen_al) if (inj.acceptLanguage()) |al| appendText(out, "Accept-Language", al);
    request.*.set_header_map.?(request, out);
}

fn asciiName(u: []const u16, out: []u8) ?[]const u8 {
    if (u.len > out.len) return null;
    for (u, 0..) |x, i| {
        if (x < 0x21 or x > 0x7e) return null;
        out[i] = @intCast(x);
    }
    return out[0..u.len];
}
