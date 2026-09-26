//! 웹 알림 중계(W5c — C6), 브라우저 프로세스 쪽. Chromium 은 웹 알림을 OS 로 보내지 않는다 — 페이지는 `onshow` 까지 받지만
//! 화면에 아무것도 뜨지 않는다(W5c 착수 전 실측). 브라우저를 만들 때 DevTools 로 대리 스크립트를 모든 새 문서에 넣게 한다
//! (`Page.addScriptToEvaluateOnNewDocument` — Page 도메인은 위치 보정이 켠다). 대리 스크립트는 helper(렌더러)가 숨겨 둔 네이티브
//! `send`(`renderer.zig`)를 꺼내 지우고 `Notification` 생성자와 `ServiceWorkerRegistration.showNotification` 을 감싼다 — 원래
//! 동작은 그대로 두고, 권한이 있을 때 내용만 CEF 프로세스 메시지(`maru.notify`)로 여기에 보낸다.
//!
//! 렌더러의 말은 믿지 않는다 — 출처는 **이 프로세스가 아는 그 프레임의 주소**로 정하고(CEF 보안 표시 형식 →
//! `scheme://host[:port]`), 그 출처의 알림을 Chromium 이 허용으로 기억할 때만 maru 로 넘긴다. 글은 대화상자 글 규칙으로 다듬고,
//! 브라우저마다 10 초에 5 건까지만 넘긴다. 사용자가 maru 알림을 누르면(`web_notification_click`) 그 프레임에 누르라는 메시지를
//! 보낸다 — 렌더러는 알림을 띄운 **그 문서**(무작위 표식)일 때만 누른다. DevTools Runtime 도메인·바인딩은 쓰지 않는다(적대
//! 검증 — 봇 탐지 신호·실행 컨텍스트 표). 서비스 워커 안에서 띄운 알림·페이지가 닫힌 뒤의 푸시는 덮지 못한다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const dialogs = @import("dialogs.zig");
const renderer = @import("renderer.zig");

const message = protocol.message;
const BrowserId = message.BrowserId;

/// 대리 스크립트 — 큰따옴표·역슬래시 없이 써서 JSON 문자열에 그대로 넣는다(아래 comptime). 페이지가 나중에 바꿔 놓을 수 있는
/// 것 가운데 판정·생성·직렬화·누르기에 쓰는 것(`Notification.permission` 의 원래 getter·`Reflect`·`JSON.stringify`·`String`·
/// `Promise.prototype.then`·`EventTarget.prototype.dispatchEvent`·`Event`)은 먼저 쥐고, 생성 뒤의 처리는 모두 try 안에서 한다
/// — 페이지가 이것들을 바꿔도 원래 동작과 다른 예외가 나지 않고, `permission` 을 `granted` 로 속여도 보내지 않는다(적대
/// 검증). 출처·권한·빈도는 여기서 다시 본다. 누를 수 있게 최근 32 개 알림 객체를 번호로 쥔다. 생성자·`showNotification` 은
/// Proxy 로 감싸 이름·`length`·`prototype` 을 그대로 두고, 처리기 객체는 `Object.prototype` 을 잇지 않는다(페이지가 거기에
/// `get`·`apply` 를 두어도 트랩이 되지 않게). 드러나는 차이: 둘의 `toString()` 이 이름 없는 네이티브 함수 모양이고,
/// `Notification.prototype.constructor` 가 감싼 생성자와 다르며, 잘못 부를 때의 예외 `stack` 에 Proxy 프레임이 보이고,
/// `showNotification` 이 권한이 있을 때 돌려준 Promise 의 `constructor` 를 읽고(then 의 species), 누르기 이벤트는 `isTrusted`
/// 가 false 다.
const proxy_script = "(function(){var send=window." ++ renderer.stash_name ++ ";try{delete window." ++ renderer.stash_name ++ "}catch(e){}" ++
    "var N=window.Notification;if(typeof send!=='function'||typeof N!=='function')return;" ++
    "var R=Reflect.construct,A=Reflect.apply,J=JSON.stringify,S=String,E=Event,T=Promise.prototype.then,D=EventTarget.prototype.dispatchEvent," ++
    "PD=Object.getOwnPropertyDescriptor(N,'permission'),PG=PD&&PD.get,seq=0,live={};" ++
    "function ok(){try{return A(PG,N,[])==='granted'}catch(e){return false}}" ++
    "function relay(t,o,n){try{send(J({n:n,title:S(t),body:S(o&&o.body||'')}))}catch(e){}}" ++
    "var P=new Proxy(N,{__proto__:null,construct:function(t,a,nt){var x=R(t,a,nt===P?N:nt);" ++
    "try{if(ok()){var n=++seq;live[n]=x;delete live[n-32];relay(a[0],a[1],n)}}catch(e){}return x}});" ++
    "window.Notification=P;" ++
    "if(window.ServiceWorkerRegistration){var SP=ServiceWorkerRegistration.prototype;" ++
    "SP.showNotification=new Proxy(SP.showNotification,{__proto__:null,apply:function(f,self,a){var r=A(f,self,a);" ++
    "try{if(ok())A(T,r,[function(){relay(a[0],a[1],0)},function(){}])}catch(e){}return r}})}" ++
    "send(function(n){var x=live[n];if(x)try{A(D,x,[new E('click')])}catch(e){}})})()";

comptime {
    @setEvalBranchQuota(20_000);
    std.debug.assert(std.mem.indexOfAny(u8, proxy_script, "\"\\\n") == null);
}

var devtools_id: u32 = 20_000;

/// 브라우저를 만들 때 — 새 문서마다 대리 스크립트를 넣게 한다(같은 프로세스의 프레임만 — 다른 사이트의 iframe(OOPIF)은 다른
/// DevTools 대상이라 들어가지 않는다. 렌더러도 거기에는 `send` 를 숨기지 않는다). Page 도메인은 위치 보정
/// (`permissions.installGeolocationShim`)이 먼저 켠다. 브라우저를 만든 뒤 보내므로 첫 문서가 이보다 먼저 커밋되면 그 문서에는
/// 들어가지 않는다(위치 보정과 같은 경쟁 — 판정자의 첫 문서 판정은 매번 이겼다).
pub fn install(browser: [*c]c.cef_browser_t) void {
    const host = browser.*.get_host.?(browser);
    if (host == null) return;
    defer object.release(host);
    var buf: [proxy_script.len + 160]u8 = undefined;
    devtools_id +%= 1;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"Page.addScriptToEvaluateOnNewDocument\",\"params\":{{\"source\":\"{s}\"}}}}", .{ devtools_id, proxy_script }) catch return;
    _ = host.*.send_dev_tools_message.?(host, json.ptr, json.len);
}

/// 글 상한 — maru 가 한 줄 목록·배너로 보인다(프로토콜 상한 4 KiB 보다 짧게).
const max_title_bytes = 256;
const max_body_bytes = 1024;
/// 브라우저마다 이 시간 안에 이만큼만 넘긴다.
const rate_window_ms: i64 = 10_000;
const rate_limit = 5;

const Recent = struct { browser: BrowserId, at: [rate_limit]i64 = [_]i64{0} ** rate_limit };
var recent: [64]?Recent = [_]?Recent{null} ** 64;

/// 넘긴 알림 → (브라우저, 프레임 식별자, 문서 표식, 페이지 번호) — 누를 때 찾는다. 최근 64 개.
const max_frame_id_bytes = 128;
const Shown = struct {
    browser: BrowserId,
    notification: u32,
    frame_buf: [max_frame_id_bytes]u8 = undefined,
    frame_len: usize = 0,
    token_buf: [16]u8 = undefined,
    page: i32,
};
var shown: [64]?Shown = [_]?Shown{null} ** 64;
var shown_next: usize = 0;
var next_notification: u32 = 1;

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// 브라우저가 닫혔다 — 빈도 기록·누를 기록을 놓는다.
pub fn forgetBrowser(id: BrowserId) void {
    for (&recent) |*slot| {
        if (slot.*) |r| if (r.browser == id) {
            slot.* = null;
        };
    }
    for (&shown) |*slot| {
        if (slot.*) |s| if (s.browser == id) {
            slot.* = null;
        };
    }
}

/// 주 프레임과 같은 출처인가 — Chrome 은 다른 출처 iframe 의 알림을 막는다(그 iframe 출처가 허용돼 있어도 삽입한 페이지가
/// 그 이름의 알림 시점을 고르지 못하게 — 적대 검증).
fn sameAsTop(browser: [*c]c.cef_browser_t, origin: []const u8) bool {
    const api = browsers.state.api;
    const main = browser.*.get_main_frame.?(browser);
    if (main == null) return false;
    defer object.release(main);
    const url = main.*.get_url.?(main);
    if (url == null) return false;
    defer api.string_userfree_utf16_free(url);
    var top_buf: [protocol.fields.max_origin_bytes]u8 = undefined;
    return std.mem.eql(u8, dialogs.originOf(url, &top_buf), origin);
}

/// 그 출처의 알림을 Chromium 이 허용으로 기억하는가.
fn notificationsAllowed(origin: []const u8) bool {
    const api = browsers.state.api;
    const ctx = api.request_context_get_global_context();
    if (ctx == null) return false;
    // request context 의 참조 카운트는 두 겹 아래에 있다(`preferences.zig` 와 같다).
    defer _ = ctx.*.base.base.release.?(&ctx.*.base.base);
    var url = std.mem.zeroes(c.cef_string_t);
    library.setString(api, &url, origin);
    defer api.string_utf16_clear(&url);
    return ctx.*.get_content_setting.?(ctx, &url, &url, c.CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS) == c.CEF_CONTENT_SETTING_VALUE_ALLOW;
}

fn lastAt(r: Recent) i64 {
    var last: i64 = 0;
    for (r.at) |at| last = @max(last, at);
    return last;
}

/// 빈도 제한 — 창 안의 건수가 상한이면 false.
fn admit(id: BrowserId) bool {
    const now = nowMs();
    var free: ?*?Recent = null;
    for (&recent) |*slot| {
        if (slot.*) |*r| {
            if (r.browser != id) continue;
            for (&r.at) |*at| {
                if (at.* == 0 or now - at.* >= rate_window_ms) {
                    at.* = now;
                    return true;
                }
            }
            return false;
        } else if (free == null) free = slot;
    }
    // 표가 차면 가장 오래 조용했던 브라우저의 기록을 덮는다(새 브라우저가 영영 못 띄우지 않게 — 적대 검증).
    const slot = free orelse blk: {
        var oldest: *?Recent = &recent[0];
        for (&recent) |*candidate| {
            if (lastAt(candidate.*.?) < lastAt(oldest.*.?)) oldest = candidate;
        }
        break :blk oldest;
    };
    slot.* = .{ .browser = id };
    slot.*.?.at[0] = now;
    return true;
}

/// client 의 `on_process_message_received` — 렌더러의 알림(`maru.notify`)만 본다.
pub fn onProcessMessageReceived(_: [*c]c.cef_client_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, source: c.cef_process_id_t, msg: [*c]c.cef_process_message_t) callconv(.c) c_int {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    defer object.releaseArg(msg);
    if (source != c.PID_RENDERER or frame == null or msg == null) return 0;
    const api = browsers.state.api;
    const name = msg.*.get_name.?(msg);
    if (name == null) return 0;
    defer api.string_userfree_utf16_free(name);
    var name_buf: [32]u8 = undefined;
    if (!std.mem.eql(u8, library.readString(api, name, &name_buf), renderer.notify_message)) return 0;
    const id = dialogs.browserId(browser) orelse return 1;
    relay(id, browser, frame, msg);
    return 1;
}

fn relay(id: BrowserId, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, msg: [*c]c.cef_process_message_t) void {
    const api = browsers.state.api;
    // 출처는 이 프로세스가 아는 그 프레임의 주소로 — 렌더러가 주는 값이 아니다.
    const url = frame.*.get_url.?(frame);
    if (url == null) return;
    defer api.string_userfree_utf16_free(url);
    var origin_buf: [protocol.fields.max_origin_bytes]u8 = undefined;
    const origin = dialogs.originOf(url, &origin_buf);
    if (origin.len == 0 or !sameAsTop(browser, origin) or !notificationsAllowed(origin)) return;
    const list = msg.*.get_argument_list.?(msg);
    if (list == null) return;
    defer object.release(list);
    const payload_str = list.*.get_string.?(list, 0);
    if (payload_str == null) return;
    defer api.string_userfree_utf16_free(payload_str);
    const token_str = list.*.get_string.?(list, 1);
    if (token_str == null) return;
    defer api.string_userfree_utf16_free(token_str);
    var token_buf: [32]u8 = undefined;
    const token = library.readString(api, token_str, &token_buf);
    if (token.len != 16) return;
    _ = std.fmt.parseInt(u64, token, 16) catch return;
    var payload_buf: [8 * 1024 * 3]u8 = undefined;
    const payload = library.readString(api, payload_str, &payload_buf);
    if (payload.len >= payload_buf.len) return;
    const parsed = std.json.parseFromSlice(std.json.Value, std.heap.c_allocator, payload, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const title = parsed.value.object.get("title") orelse return;
    const body = parsed.value.object.get("body") orelse std.json.Value{ .string = "" };
    const page = parsed.value.object.get("n") orelse std.json.Value{ .integer = 0 };
    if (title != .string or body != .string or page != .integer) return;
    if (page.integer < 0 or page.integer > std.math.maxInt(i32)) return;
    if (!admit(id)) return;
    var title_out: [max_title_bytes]u8 = undefined;
    var body_out: [max_body_bytes]u8 = undefined;
    const notification = next_notification;
    next_notification +%= 1;
    if (next_notification == 0) next_notification = 1;
    // 누를 수 있게 적는다(서비스 워커 등록의 알림은 번호 0 — 누를 객체가 없다).
    if (page.integer > 0) {
        var entry: Shown = .{ .browser = id, .notification = notification, .page = @intCast(page.integer) };
        const frame_id = frame.*.get_identifier.?(frame);
        if (frame_id != null) {
            defer api.string_userfree_utf16_free(frame_id);
            const text = library.readString(api, frame_id, &entry.frame_buf);
            entry.frame_len = if (text.len < entry.frame_buf.len) text.len else 0;
        }
        @memcpy(&entry.token_buf, token[0..16]);
        if (entry.frame_len > 0) {
            shown[shown_next] = entry;
            shown_next = (shown_next + 1) % shown.len;
        }
    }
    browsers.state.writer.send(.{ .web_notification = .{
        .browser = id,
        .notification = if (page.integer > 0) notification else 0,
        .origin = origin,
        .title = clean(title.string, &title_out),
        .body = clean(body.string, &body_out),
    } }) catch {};
}

/// 사용자가 maru 알림을 눌렀다 — 그 프레임에 누르라고 보낸다(렌더러가 문서 표식을 맞춰 본다).
pub fn click(value: message.WebNotificationClick) void {
    // 한 번만 누른다(Chrome 도 누른 알림은 닫힌다) — 같은 알림을 다시 눌러도 `onclick` 이 두 번 불리지 않게.
    const entry = for (&shown) |*slot| {
        if (slot.*) |s| if (s.browser == value.browser and s.notification == value.notification) {
            slot.* = null;
            break s;
        };
    } else return;
    const registered = browsers.state.registry.byId(value.browser) orelse return;
    const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(registered.handle));
    const api = browsers.state.api;
    var frame_id = std.mem.zeroes(c.cef_string_t);
    library.setString(api, &frame_id, entry.frame_buf[0..entry.frame_len]);
    defer api.string_utf16_clear(&frame_id);
    const frame = browser.*.get_frame_by_identifier.?(browser, &frame_id);
    if (frame == null) return;
    defer object.release(frame);
    var name = std.mem.zeroes(c.cef_string_t);
    library.setString(api, &name, renderer.click_message);
    defer api.string_utf16_clear(&name);
    const msg = api.process_message_create(&name) orelse return;
    const list = msg.*.get_argument_list.?(msg);
    if (list == null) {
        object.release(msg);
        return;
    }
    defer object.release(list);
    _ = list.*.set_int.?(list, 0, entry.page);
    var token = std.mem.zeroes(c.cef_string_t);
    library.setString(api, &token, &entry.token_buf);
    defer api.string_utf16_clear(&token);
    _ = list.*.set_string.?(list, 1, &token);
    // 넘긴 메시지의 참조는 CEF 로 옮겨 간다.
    frame.*.send_process_message.?(frame, c.PID_RENDERER, msg);
}

/// 글자 경계에서 자르고 줄바꿈·탭 밖의 제어 문자는 공백으로(대화상자 글 규칙).
fn clean(text: []const u8, out: []u8) []const u8 {
    const clamped = protocol.text.clampUtf8(text, out.len);
    @memcpy(out[0..clamped.len], clamped);
    protocol.text.replaceControlKeepLines(out[0..clamped.len]);
    return out[0..clamped.len];
}
