//! helper(렌더러 프로세스)의 CEF app — 웹 알림 중계의 렌더러 쪽(W5c — C6). Chromium 은 웹 알림을 OS 로 보내지 않는다(실측).
//!
//! 새 문서의 주 세계가 생길 때(`on_context_created`) 네이티브 함수 `send` 를 전역 `stash_name` 에 숨겨(열거되지 않게) 둔다 —
//! 대리 스크립트가 돌 문서(주 프레임까지 이 프로세스로 이어지는 http(s)·불투명하지 않은 출처의 문서)에만(`relayable`).
//! 대리 스크립트는 sidecar 가 DevTools `Page.addScriptToEvaluateOnNewDocument` 로 넣는다(`notifications.zig`) — secure context
//! 에만 있는 `Notification`·`ServiceWorkerRegistration` 은 컨텍스트가 생길 때가 아니라 그 뒤에 설치되므로(실측 — 여기와 그
//! microtask·`on_load_start` 에서는 `undefined`) 이 처리기 안에서는 감쌀 수 없다. 대리 스크립트는 페이지 스크립트보다 먼저
//! `send` 를 꺼내 지우고, 알림 내용은 `send(json)` 으로, 「누르기」 함수는 `send(function)` 으로 한 번 넘긴다.
//!
//! 알림 내용은 CEF 프로세스 메시지(`maru.notify`)로 브라우저 프로세스에 보낸다. 출처 판정·권한 확인·빈도 제한은 브라우저 쪽이
//! **그 프레임의 주소**로 한다 — 렌더러의 말은 믿지 않는다(대리 스크립트가 돌지 못한 문서 — 브라우저를 만든 뒤 등록이 닿기
//! 전에 커밋한 첫 문서 — 에서 페이지가 `send` 를 직접 불러도 그 페이지 자신의 출처·권한으로 판정된다). 문서마다 무작위 표식을 붙여, 알림을 누를 때 그 문서가 아직 그 프레임에 있을
//! 때만 누른다(이동한 뒤의 옛 알림이 새 문서의 알림을 누르지 않게). DevTools Runtime 도메인·바인딩은 쓰지 않는다(적대
//! 검증 — 봇 탐지 신호·실행 컨텍스트 표).

const std = @import("std");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");

pub const notify_message = "maru.notify";
pub const click_message = "maru.notify.click";

/// `send` 를 숨겨 두는 전역 이름 — 대리 스크립트가 꺼내 지운다(`notifications.zig` 와 같은 값).
pub const stash_name = "__maruNotifySend";

/// 한 번에 받는 글 상한(UTF-16 단위)과 문서마다 1 초에 받는 호출 수 — 넘으면 브라우저 프로세스로 보내지 않는다(IPC 폭탄 —
/// 적대 검증).
const max_payload_units = 8 * 1024;
const calls_per_second = 10;

var api_ref: ?*const library.Api = null;
var app: c.cef_app_t = undefined;
var render_handler: c.cef_render_process_handler_t = undefined;
var send_handler: c.cef_v8_handler_t = undefined;
var ready = false;

/// 문서(주 세계 컨텍스트)마다 — 프레임 식별자의 해시, 무작위 표식, 컨텍스트와 누르기 함수(참조를 쥔다), 빈도 제한.
const Document = struct {
    frame: u64,
    token: u64,
    context: [*c]c.cef_v8_context_t,
    /// 대리 스크립트가 넘기기 전에는 null.
    click: [*c]c.cef_v8_value_t = null,
    window_start_ms: i64 = 0,
    window_calls: u32 = 0,
};
var documents: [128]?Document = [_]?Document{null} ** 128;

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

pub fn get(api: *const library.Api) *c.cef_app_t {
    if (!ready) {
        ready = true;
        api_ref = api;
        app = object.zeroed(c.cef_app_t);
        object.staticRefCounted(&app.base);
        app.get_render_process_handler = &getRenderProcessHandler;
        render_handler = object.zeroed(c.cef_render_process_handler_t);
        object.staticRefCounted(&render_handler.base);
        render_handler.on_context_created = &onContextCreated;
        render_handler.on_context_released = &onContextReleased;
        render_handler.on_process_message_received = &onProcessMessageReceived;
        send_handler = object.zeroed(c.cef_v8_handler_t);
        object.staticRefCounted(&send_handler.base);
        send_handler.execute = &execute;
    }
    return &app;
}

fn getRenderProcessHandler(_: [*c]c.cef_app_t) callconv(.c) [*c]c.cef_render_process_handler_t {
    return &render_handler;
}

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

/// 프레임 식별자(UTF-16)의 해시 — 문서 표의 키.
pub fn frameKey(frame: [*c]c.cef_frame_t) u64 {
    const api = api_ref.?;
    const id = frame.*.get_identifier.?(frame);
    if (id == null) return 0;
    defer api.string_userfree_utf16_free(id);
    var hash: u64 = 0xcbf29ce484222325;
    const units = id.*.str[0..id.*.length];
    for (units) |unit| {
        hash ^= unit;
        hash *%= 0x100000001b3;
    }
    return hash;
}

fn documentOf(frame: u64) ?*Document {
    for (&documents) |*slot| {
        if (slot.*) |*doc| if (doc.frame == frame) return doc;
    }
    return null;
}

fn setString(value: *c.cef_string_t, text: []const u8) void {
    library.setString(api_ref.?, value, text);
}

/// 새 문서의 주 세계 — 대리 스크립트가 돌 문서면 표에 올리고 `send` 를 숨겨 둔다. 표가 차면 그 문서는 중계하지 않는다(닫혀
/// 실패). 대리 스크립트는 브라우저의 DevTools(주 프레임의 대상)가 넣으므로 **주 프레임까지 이 프로세스로 이어지는 프레임**의
/// http(s) 문서에만 돈다 — 다른 사이트의 iframe(OOPIF)과 그 안의 프레임·`about:blank`·불투명 출처(sandbox) 문서에는 숨기지
/// 않는다. 숨기면 꺼내 지울 스크립트가 없어 페이지에 그대로 보인다(적대 검증 — 탐지 신호).
fn onContextCreated(_: [*c]c.cef_render_process_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, context: [*c]c.cef_v8_context_t) callconv(.c) void {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    const key = frameKey(frame);
    // 같은 프레임의 옛 문서 — 풀고 새로 쓴다.
    if (documentOf(key)) |old| releaseDocument(old);
    // 표에 올리지 않으면 인자 참조를 푼다 — exit 뒤에(아래 defer 들보다 먼저 걸어 둔다).
    var kept = false;
    defer if (!kept) object.releaseArg(context);
    if (context.*.enter.?(context) == 0) return;
    defer _ = context.*.exit.?(context);
    const global = context.*.get_global.?(context);
    if (global == null) return;
    defer object.release(global);
    if (!relayable(frame, global)) return;
    const slot = for (&documents) |*slot| {
        if (slot.* == null) break slot;
    } else return;
    kept = true;
    var token: u64 = 0;
    arc4random_buf(@ptrCast(&token), @sizeOf(u64));
    slot.* = .{ .frame = key, .token = token | 1, .context = context };
    const api = api_ref.?;
    var name = std.mem.zeroes(c.cef_string_t);
    setString(&name, stash_name);
    defer api.string_utf16_clear(&name);
    const send_fn = api.v8_value_create_function(&name, &send_handler);
    if (send_fn == null) return;
    // 넘긴 값의 참조는 CEF 로 옮겨 간다. 지울 수 있게(대리 스크립트가 `delete`) DONTDELETE 는 주지 않는다.
    _ = global.*.set_value_bykey.?(global, &name, send_fn, c.V8_PROPERTY_ATTRIBUTE_DONTENUM);
}

/// 대리 스크립트가 돌 문서인가 — 부모를 따라 주 프레임까지 이 프로세스에서 이어지고(CEF 는 부모가 다른 프로세스면 null 을
/// 준다 — 그 사이에 OOPIF 가 끼면 끊긴다), 주소가 http(s) 이고, 출처가 불투명하지 않다(전역 `origin` — 페이지 스크립트가 돌기
/// 전이라 바꿔 놓을 수 없다. 스크립트를 컴파일하지 않고 네이티브 getter 를 읽는다).
fn relayable(frame: [*c]c.cef_frame_t, global: [*c]c.cef_v8_value_t) bool {
    const api = api_ref.?;
    if (frame.*.is_main.?(frame) == 0) {
        var current = frame.*.get_parent.?(frame);
        while (true) {
            if (current == null) return false;
            if (current.*.is_main.?(current) != 0) {
                object.release(current);
                break;
            }
            const next = current.*.get_parent.?(current);
            object.release(current);
            current = next;
        }
    }
    const url = frame.*.get_url.?(frame);
    if (url == null) return false;
    defer api.string_userfree_utf16_free(url);
    var url_buf: [16]u8 = undefined;
    if (!isHttp(library.readString(api, url, &url_buf))) return false;
    var key = std.mem.zeroes(c.cef_string_t);
    setString(&key, "origin");
    defer api.string_utf16_clear(&key);
    const value = global.*.get_value_bykey.?(global, &key);
    if (value == null) return false;
    defer object.release(value);
    if (value.*.is_string.?(value) == 0) return false;
    const origin = value.*.get_string_value.?(value);
    if (origin == null) return false;
    defer api.string_userfree_utf16_free(origin);
    var origin_buf: [16]u8 = undefined;
    return isHttp(library.readString(api, origin, &origin_buf));
}

fn isHttp(text: []const u8) bool {
    return std.mem.startsWith(u8, text, "https://") or std.mem.startsWith(u8, text, "http://");
}

/// 지금 컨텍스트가 그 문서의 것인가(같은 프레임의 다른 세계·옛 문서가 아닌지). `is_same` 이 넘긴 참조를 가져가므로 하나 더 잡아 넘긴다.
fn isDocumentContext(doc: *const Document, context: [*c]c.cef_v8_context_t) bool {
    addRef(context);
    return doc.context.*.is_same.?(doc.context, context) != 0;
}

fn addRef(ptr: anytype) void {
    ptr.*.base.add_ref.?(&ptr.*.base);
}

fn onContextReleased(_: [*c]c.cef_render_process_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, context: [*c]c.cef_v8_context_t) callconv(.c) void {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    const key = frameKey(frame);
    const doc = documentOf(key) orelse {
        object.releaseArg(context);
        return;
    };
    // `is_same` 가 넘긴 컨텍스트의 참조를 가져간다 — 따로 풀지 않는다.
    if (doc.context.*.is_same.?(doc.context, context) != 0) releaseDocument(doc);
}

fn releaseDocument(doc: *Document) void {
    if (doc.click != null) object.release(doc.click);
    object.release(doc.context);
    for (&documents) |*slot| {
        if (slot.*) |*d| if (d == doc) {
            slot.* = null;
            return;
        };
    }
}

/// 대리 스크립트의 `send(json)` — 그 문서의 표식을 붙여 브라우저 프로세스로 보낸다. `send(function)` 은 누르기 함수.
fn execute(
    _: [*c]c.cef_v8_handler_t,
    _: [*c]const c.cef_string_t,
    this: [*c]c.cef_v8_value_t,
    count: usize,
    arguments: [*c]const [*c]c.cef_v8_value_t,
    retval: [*c][*c]c.cef_v8_value_t,
    _: [*c]c.cef_string_t,
) callconv(.c) c_int {
    object.releaseArg(this);
    _ = retval;
    // 인자마다 참조가 하나씩 넘어온다 — 쥐는 누르기 함수 밖은 다 쓰고 푼다.
    var kept: ?usize = null;
    defer for (0..count) |i| {
        if (kept != i) object.releaseArg(arguments[i]);
    };
    if (count != 1 or arguments[0] == null) return 1;
    const arg = arguments[0];
    const api = api_ref.?;
    const context = api.v8_context_get_current_context();
    if (context == null) return 1;
    defer object.release(context);
    const frame = context.*.get_frame.?(context);
    if (frame == null) return 1;
    defer object.release(frame);
    const doc = documentOf(frameKey(frame)) orelse return 1;
    if (!isDocumentContext(doc, context)) return 1;
    // 「누르기」 함수 — 문서마다 처음 한 번만(대리 스크립트가 페이지 스크립트보다 먼저 넘긴다).
    if (arg.*.is_function.?(arg) != 0) {
        if (doc.click == null) {
            doc.click = arg;
            kept = 0;
        }
        return 1;
    }
    if (arg.*.is_string.?(arg) == 0) return 1;
    const now = nowMs();
    if (now - doc.window_start_ms >= 1000) {
        doc.window_start_ms = now;
        doc.window_calls = 0;
    }
    if (doc.window_calls >= calls_per_second) return 1;
    doc.window_calls += 1;
    const payload = arg.*.get_string_value.?(arg);
    if (payload == null) return 1;
    defer api.string_userfree_utf16_free(payload);
    if (payload.*.length > max_payload_units) return 1;
    var name = std.mem.zeroes(c.cef_string_t);
    setString(&name, notify_message);
    defer api.string_utf16_clear(&name);
    const message = api.process_message_create(&name) orelse return 1;
    const list = message.*.get_argument_list.?(message);
    if (list == null) {
        object.release(message);
        return 1;
    }
    defer object.release(list);
    _ = list.*.set_string.?(list, 0, payload);
    var token_buf: [16]u8 = undefined;
    var token = std.mem.zeroes(c.cef_string_t);
    setString(&token, std.fmt.bufPrint(&token_buf, "{x:0>16}", .{doc.token}) catch unreachable);
    defer api.string_utf16_clear(&token);
    _ = list.*.set_string.?(list, 1, &token);
    // 넘긴 메시지의 참조는 CEF 로 옮겨 간다.
    frame.*.send_process_message.?(frame, c.PID_BROWSER, message);
    return 1;
}

/// 브라우저 프로세스가 누르라고 했다 — 그 프레임의 **그 문서**(표식이 같을 때)의 알림만 누른다.
fn onProcessMessageReceived(_: [*c]c.cef_render_process_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, source: c.cef_process_id_t, message: [*c]c.cef_process_message_t) callconv(.c) c_int {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    defer object.releaseArg(message);
    if (source != c.PID_BROWSER or frame == null or frame.*.is_valid.?(frame) == 0) return 0;
    const api = api_ref.?;
    const name = message.*.get_name.?(message);
    if (name == null) return 0;
    defer api.string_userfree_utf16_free(name);
    var name_buf: [32]u8 = undefined;
    if (!std.mem.eql(u8, library.readString(api, name, &name_buf), click_message)) return 0;
    const list = message.*.get_argument_list.?(message);
    if (list == null) return 1;
    defer object.release(list);
    const n = list.*.get_int.?(list, 0);
    const token_text = list.*.get_string.?(list, 1);
    if (token_text == null) return 1;
    defer api.string_userfree_utf16_free(token_text);
    var token_buf: [32]u8 = undefined;
    const token = std.fmt.parseInt(u64, library.readString(api, token_text, &token_buf), 16) catch return 1;
    const doc = documentOf(frameKey(frame)) orelse return 1;
    if (doc.token != token or n <= 0 or doc.click == null) return 1;
    // 누르기는 페이지 코드를 곧바로 돌린다 — 그 안에서 프레임이 떨어져 나가면(`frameElement.remove()`) 문서가 풀리고 표의
    // 칸이 다른 문서로 채워질 수 있다. 컨텍스트와 함수를 따로 잡고, 부른 뒤에는 `doc` 를 다시 보지 않는다(적대 검증 — UAF).
    const context = doc.context;
    const click = doc.click;
    addRef(context);
    defer object.release(context);
    addRef(click);
    defer object.release(click);
    // 손으로 enter/exit 하지 않는다 — 그 안에서 컨텍스트가 풀리면 exit 가 실패해 스택에 남는다(적대 검증). CEF 가 들어갔다
    // 나온다. 넘기는 컨텍스트의 참조는 CEF 로 옮겨 가므로 하나 더 잡아 넘긴다.
    const arg = api.v8_value_create_int(n) orelse return 1;
    const args = [_][*c]c.cef_v8_value_t{arg};
    addRef(context);
    const result = click.*.execute_function_with_context.?(click, context, null, 1, &args);
    if (result != null) object.release(result);
    return 1;
}
