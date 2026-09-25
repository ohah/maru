//! JS 대화상자·떠나기 확인·파일 선택(W5a — C6) — CEF 가 묻는 것을 maru 로 보내고 답이 오면 CEF 콜백을 부른다. CEF UI 스레드에서
//! 돈다(CEF 콜백과 `dispatch.zig` 가 모두 여기다).
//!
//! 왜 maru 로 보내는가: 핸들러가 없으면 Chromium 기본 창이 sidecar 프로세스의 창으로 뜨는데, 그 창은 maru 창 **뒤**에 가려
//! 페이지만 멈췄다(W5 착수 전 실측 — docs/plans/web-osr-backend.md C6). maru 는 자기 창에 붙는 네이티브 sheet 로 묻는다.
//!
//! 답을 못 받는 경우는 조용히 옛 동작으로 돌아간다 — 브라우저를 모르거나(닫히는 중) 표가 찼거나 maru 에 보내지 못하면 JS
//! 대화상자는 억제(`alert` 는 바로 돌아오고 `confirm`·`prompt` 는 취소), 떠나기 확인은 떠나기, 파일 선택은 취소다.
//! **maru 가 이동·뒤로·새로고침·파괴를 보내면 그 브라우저의 JS 대화상자를 먼저 취소로 답한다**(`cancelFor`) — 대화상자가
//! 떠 있는 동안 렌더러가 멈춰 있어, 그대로 이동을 넘기면 CEF 는 대화상자도 치우지 않고 옮겨 가지도 않은 채 기다린다(W5a
//! 판정자 실측). Chrome 도 주소를 바꾸면 떠 있는 대화상자를 닫고 옮겨 간다. 페이지 쪽에서 상태가 비워질 때도(CEF
//! `on_reset_dialog_state`) 콜백을 놓는다. 둘 다 maru 에 `dialog_closed` 를 알린다(떠 있는 창을 닫게). 브라우저가 닫히면 남은
//! 요청을 모두 놓는다(maru 는 `browser_closed` 로 안다).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const dialog_table = @import("dialog_table.zig");

const message = protocol.message;
const Message = message.Message;
const BrowserId = message.BrowserId;
const max_text_bytes = protocol.wire.max_text_bytes;

var table: dialog_table.Table = .{};

/// 페이지마다(이동하면 새로) 띄운 JS 대화상자 수와 억제 여부 — 두 번째부터 maru 가 「더 띄우지 못하게」를 보이고, 사용자가
/// 고르면 이동할 때까지 억제한다(Chrome 과 같다 — `while(1) alert()` 가 창을 영영 막지 않게).
/// 수·억제는 **maru 가 시킨 이동**(주소창·뒤로·앞으로·새로고침 — `cancelFor` 가 표시한다)의 새 문서에서만 푼다. 페이지가 스스로
/// 한 이동(`alert(); location.reload()` 되풀이)은 이어 센다 — 안 그러면 억제 선택이 영영 안 나와 창 전체를 막는 sheet 에서 빠져
/// 나갈 길이 없다(적대 검증). 시간 유예로 가르면 사용자가 곧바로 다른 사이트로 옮겨도 억제가 남았다(판정자 실측).
/// `reset_at_ms` 는 maru 가 이동을 시킨 시각 — 그 뒤 `reset_grace_ms` 안의 새 문서에서만 푼다. 새 문서를 부르지 않는 명령(멈춤·
/// 기록 없는 뒤로·해시 이동)이나 머무르기로 끝난 이동이 표시를 남겨 두면, 나중에 페이지가 스스로 새로고침할 때 억제가 풀렸다
/// (적대 검증). 머무르기·멈춤은 표시를 지우고, 남은 표시는 이 시간이 지나면 무효다.
const Page = struct { id: BrowserId, count: u32 = 0, suppressed: bool = false, reset_at_ms: i64 = 0 };
const reset_grace_ms: i64 = 10_000;

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    _ = std.c.clock_gettime(.MONOTONIC, &ts);
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), std.time.ns_per_ms);
}

fn clearReset(id: BrowserId) void {
    for (&pages) |*slot| {
        if (slot.*) |*page| if (page.id == id) {
            page.reset_at_ms = 0;
        };
    }
}
var pages: [dialog_table.capacity]?Page = [_]?Page{null} ** dialog_table.capacity;

fn pageOf(id: BrowserId) ?*Page {
    for (&pages) |*slot| {
        if (slot.*) |*page| if (page.id == id) return page;
    }
    for (&pages) |*slot| {
        if (slot.* == null) {
            slot.* = .{ .id = id };
            return &slot.*.?;
        }
    }
    return null;
}

fn forgetPage(id: BrowserId) void {
    for (&pages) |*slot| {
        if (slot.*) |page| if (page.id == id) {
            slot.* = null;
        };
    }
}

// CEF 의 파일 선택 방식 값이 우리 enum 과 같다 — CEF 를 올려 바뀌면 빌드가 멈춘다.
comptime {
    std.debug.assert(c.FILE_DIALOG_OPEN == @intFromEnum(message.FileDialogMode.open));
    std.debug.assert(c.FILE_DIALOG_OPEN_MULTIPLE == @intFromEnum(message.FileDialogMode.open_multiple));
    std.debug.assert(c.FILE_DIALOG_OPEN_FOLDER == @intFromEnum(message.FileDialogMode.open_folder));
    std.debug.assert(c.FILE_DIALOG_SAVE == @intFromEnum(message.FileDialogMode.save));
}

fn browserId(browser: [*c]c.cef_browser_t) ?BrowserId {
    if (browser == null) return null;
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return null;
    if (entry.closing) return null;
    return entry.id;
}

/// `on_jsdialog`. 1 을 돌려주면 우리가 답한다(나중에 콜백으로), 0 과 `suppress_message` 는 억제.
pub fn onJsDialog(
    _: [*c]c.cef_jsdialog_handler_t,
    browser: [*c]c.cef_browser_t,
    origin_url: [*c]const c.cef_string_t,
    dialog_type: c.cef_jsdialog_type_t,
    message_text: [*c]const c.cef_string_t,
    default_prompt_text: [*c]const c.cef_string_t,
    callback: [*c]c.cef_jsdialog_callback_t,
    suppress_message: [*c]c_int,
) callconv(.c) c_int {
    defer object.releaseArg(browser);
    const kind: message.JsDialogKind = switch (dialog_type) {
        c.JSDIALOGTYPE_ALERT => .alert,
        c.JSDIALOGTYPE_CONFIRM => .confirm,
        c.JSDIALOGTYPE_PROMPT => .prompt,
        else => .alert,
    };
    if (ask(browser, kind, origin_url, message_text, default_prompt_text, callback)) return 1;
    // 헤더 권장 — 억제가 콜백을 바로 부르는 것보다 낫다(Chromium 이 대화상자 남발을 이것으로 가린다).
    suppress_message.* = 1;
    return 0;
}

/// `on_before_unload_dialog` — 떠나기 확인. 묻지 못하면 떠나기로 답한다(예전 동작 — 페이지가 탭 닫기를 막지 못하게).
pub fn onBeforeUnloadDialog(
    _: [*c]c.cef_jsdialog_handler_t,
    browser: [*c]c.cef_browser_t,
    message_text: [*c]const c.cef_string_t,
    _: c_int,
    callback: [*c]c.cef_jsdialog_callback_t,
) callconv(.c) c_int {
    defer object.releaseArg(browser);
    if (ask(browser, .before_unload, null, message_text, null, callback)) return 1;
    callback.*.cont.?(callback, 1, null);
    object.releaseArg(callback);
    return 1;
}

/// 요청을 표에 적고 maru 에 보낸다. 성공하면 콜백 참조는 표가 쥔다(답·비우기·닫기가 푼다). 실패하면 콜백을 풀지 않고
/// false — 호출자가 옛 동작으로 답하고 푼다(`onJsDialog` 는 0 을 돌려주면 CEF 가 콜백을 쓰지 않으므로 여기서 푼다).
fn ask(
    browser: [*c]c.cef_browser_t,
    kind: message.JsDialogKind,
    origin_url: [*c]const c.cef_string_t,
    message_text: [*c]const c.cef_string_t,
    default_prompt_text: [*c]const c.cef_string_t,
    callback: [*c]c.cef_jsdialog_callback_t,
) bool {
    const id = browserId(browser) orelse return giveUp(kind, callback);
    // 떠나기 확인은 억제하지 않는다(Chrome 과 같다 — 사용자가 떠날지 정해야 한다).
    var offer_suppress = false;
    if (kind != .before_unload) {
        const page = pageOf(id) orelse return giveUp(kind, callback);
        if (page.suppressed) return giveUp(kind, callback);
        page.count +|= 1;
        offer_suppress = page.count >= 2;
    }
    const request = table.add(id, .js, @ptrCast(callback)) orelse return giveUp(kind, callback);
    const api = browsers.state.api;
    var origin_buf: [protocol.fields.max_origin_bytes]u8 = undefined;
    var message_buf: [max_text_bytes]u8 = undefined;
    var default_buf: [max_text_bytes]u8 = undefined;
    const origin = originOf(origin_url, &origin_buf);
    const text = library.readDialogString(api, message_text, &message_buf);
    const default_text = if (kind == .prompt) library.readDialogString(api, default_prompt_text, &default_buf) else "";
    browsers.state.writer.send(.{ .js_dialog = .{
        .browser = id,
        .request = request,
        .kind = kind,
        .origin = origin,
        .message = text,
        .default_text = default_text,
        .offer_suppress = offer_suppress,
    } }) catch {
        if (table.find(id, request, .js)) |entry| _ = table.take(entry);
        return giveUp(kind, callback);
    };
    return true;
}

/// 답을 받을 수 없을 때. `onBeforeUnloadDialog` 는 스스로 답하고 풀므로 여기서는 JS 대화상자의 콜백만 푼다.
fn giveUp(kind: message.JsDialogKind, callback: [*c]c.cef_jsdialog_callback_t) bool {
    if (kind != .before_unload) object.releaseArg(callback);
    return false;
}

/// 제목에 쓸 출처 — CEF 의 보안 표시 형식(`cef_format_url_for_security_display` — 사용자 정보·경로를 떼고 IDN 은 안전할 때만
/// 유니코드로)을 `scheme://host[:port]` 규칙(`fields.checkOrigin`)으로 한 번 더 거른다. 못 지나면 빈 글 — maru 는 「이 페이지」
/// 로 보인다(`data:`·`about:srcdoc` 처럼 페이지가 글을 고를 수 있는 출처가 제목에 들어가지 않게 — 적대 검증).
fn originOf(origin_url: [*c]const c.cef_string_t, out: []u8) []const u8 {
    if (origin_url == null) return "";
    const api = browsers.state.api;
    const formatted = api.format_url_for_security_display(origin_url);
    if (formatted == null) return "";
    defer api.string_userfree_utf16_free(formatted);
    // 끝을 잘라 읽으면 긴 호스트(`accounts.google.com.<패딩>.evil.com`)의 뒤가 잘린 채 규칙을 지난다(적대 검증) — 넉넉히 읽고
    // 상한을 넘으면 출처를 싣지 않는다.
    var wide: [max_text_bytes]u8 = undefined;
    const text = library.readString(api, formatted, &wide);
    // 비표준 scheme 은 경로가 남을 수 있다 — `scheme://host[:port]` 뒤는 뗀다.
    var end = text.len;
    if (std.mem.indexOf(u8, text, "://")) |sep| {
        if (std.mem.indexOfScalarPos(u8, text, sep + 3, '/')) |slash| end = slash;
    }
    const origin = text[0..end];
    if (origin.len > out.len) return "";
    protocol.fields.checkOrigin(origin) catch return "";
    @memcpy(out[0..origin.len], origin);
    return out[0..origin.len];
}

/// `on_reset_dialog_state` — 페이지가 이동했다. 그 브라우저의 JS 요청은 더 답을 받지 않는다.
pub fn onResetDialogState(_: [*c]c.cef_jsdialog_handler_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null) return;
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return;
    while (table.takeFor(entry.id, .js)) |pending| {
        const callback: [*c]c.cef_jsdialog_callback_t = @ptrCast(@alignCast(pending.callback));
        object.release(callback);
        browsers.state.writer.send(.{ .dialog_closed = .{ .browser = pending.browser, .request = pending.request } }) catch {};
    }
}

/// maru 가 그 브라우저를 옮기려 한다 — 떠 있는 JS 대화상자를 취소로 답하고 알린다(떠나기 확인이면 머무르기 — 이 이동이 다시
/// 떠나기 확인을 부른다). 파일 선택은 이동과 무관하게 남긴다(페이지가 바뀌면 CEF 가 답을 버린다).
pub fn cancelFor(id: BrowserId) void {
    // 이 이동의 새 문서에서 대화상자 수·억제를 푼다(`onLoadStart`).
    for (&pages) |*slot| {
        if (slot.*) |*page| if (page.id == id) {
            page.reset_at_ms = nowMs();
        };
    }
    while (table.takeFor(id, .js)) |pending| {
        const callback: [*c]c.cef_jsdialog_callback_t = @ptrCast(@alignCast(pending.callback));
        callback.*.cont.?(callback, 0, null);
        object.release(callback);
        browsers.state.writer.send(.{ .dialog_closed = .{ .browser = pending.browser, .request = pending.request } }) catch {};
    }
}

/// `on_load_start` — 주 프레임에 새 문서가 오면 대화상자 수와 억제를 푼다(Chrome 과 같다 — 억제는 그 페이지에만). 대화상자를
/// 하나 닫을 때마다 CEF 가 `on_reset_dialog_state` 를 부르므로 거기서는 풀지 않는다(판정자 실측 — 둘째 대화상자가 억제 선택
/// 없이 왔다).
pub fn onLoadStart(_: [*c]c.cef_load_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t, _: c.cef_transition_type_t) callconv(.c) void {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    if (frame == null or frame.*.is_main.?(frame) == 0) return;
    const id = browserId(browser) orelse return;
    for (&pages) |*slot| {
        if (slot.*) |*page| if (page.id == id and page.reset_at_ms != 0 and nowMs() - page.reset_at_ms <= reset_grace_ms) {
            page.* = .{ .id = id };
        };
    }
}

/// 렌더러가 죽었다 — 그 페이지의 JS 대화상자는 답할 곳이 없다(CEF 가 상태 비우기를 부르지 않을 수 있다 — 적대 검증). 콜백을
/// 놓고 maru 에 알린다(떠 있는 sheet 를 닫게).
pub fn rendererGone(id: BrowserId) void {
    while (table.takeFor(id, .js)) |pending| {
        object.release(@as([*c]c.cef_jsdialog_callback_t, @ptrCast(@alignCast(pending.callback))));
        browsers.state.writer.send(.{ .dialog_closed = .{ .browser = pending.browser, .request = pending.request } }) catch {};
    }
}

/// maru 가 보낸 명령이 새 문서를 부르지 않는다(멈춤) — `cancelFor` 가 세운 표시를 지운다.
pub fn keepSuppression(id: BrowserId) void {
    clearReset(id);
}

pub fn onDialogClosed(_: [*c]c.cef_jsdialog_handler_t, browser: [*c]c.cef_browser_t) callconv(.c) void {
    object.releaseArg(browser);
}

/// `on_file_dialog`. 1 을 돌려주면 우리가 답한다. 묻지 못하면 취소한다(Chromium 기본 열기 창은 화면 가운데에 따로 뜬다 —
/// 실측 — 그래서 기본 동작으로 돌리지 않는다).
pub fn onFileDialog(
    _: [*c]c.cef_dialog_handler_t,
    browser: [*c]c.cef_browser_t,
    mode: c.cef_file_dialog_mode_t,
    title: [*c]const c.cef_string_t,
    default_file_path: [*c]const c.cef_string_t,
    accept_filters: c.cef_string_list_t,
    _: c.cef_string_list_t,
    _: c.cef_string_list_t,
    callback: [*c]c.cef_file_dialog_callback_t,
) callconv(.c) c_int {
    defer object.releaseArg(browser);
    const file_mode = std.enums.fromInt(message.FileDialogMode, mode) orelse return cancelFile(callback);
    const id = browserId(browser) orelse return cancelFile(callback);
    const request = table.add(id, .file, @ptrCast(callback)) orelse return cancelFile(callback);
    const api = browsers.state.api;
    var title_buf: [max_text_bytes]u8 = undefined;
    var path_buf: [max_text_bytes]u8 = undefined;
    var accept_buf: [max_text_bytes]u8 = undefined;
    browsers.state.writer.send(.{ .file_dialog = .{
        .browser = id,
        .request = request,
        .mode = file_mode,
        .title = library.readString(api, title, &title_buf),
        .default_path = library.readString(api, default_file_path, &path_buf),
        .accept = joinAccept(accept_filters, &accept_buf),
    } }) catch {
        if (table.find(id, request, .file)) |entry| _ = table.take(entry);
        return cancelFile(callback);
    };
    return 1;
}

fn cancelFile(callback: [*c]c.cef_file_dialog_callback_t) c_int {
    callback.*.cancel.?(callback);
    object.releaseArg(callback);
    return 1;
}

/// 받을 형식 목록을 쉼표로 잇는다. 하나라도 싣지 못하면(쉼표가 든 항목·상한 초과·읽기 실패) 빈 글 — 뒤쪽을 버리면 제한이
/// 오히려 **엄격해진다**(maru 는 받은 형식만 고르게 한다 — 적대 검증). 빈 글이면 제한하지 않는다.
fn joinAccept(list: c.cef_string_list_t, out: []u8) []const u8 {
    if (list == null) return out[0..0];
    const api = browsers.state.api;
    var len: usize = 0;
    const count = api.string_list_size(list);
    for (0..count) |i| {
        var value = std.mem.zeroes(c.cef_string_t);
        if (api.string_list_value(list, i, &value) == 0) return out[0..0];
        defer api.string_utf16_clear(&value);
        var one_buf: [256]u8 = undefined;
        const one = library.readString(api, &value, &one_buf);
        if (one.len == 0) continue;
        if (one.len >= one_buf.len or std.mem.indexOfScalar(u8, one, ',') != null) return out[0..0];
        const need = one.len + @intFromBool(len > 0);
        if (len + need > out.len) return out[0..0];
        if (len > 0) {
            out[len] = ',';
            len += 1;
        }
        @memcpy(out[len..][0..one.len], one);
        len += one.len;
    }
    return out[0..len];
}

/// maru 의 답(대화상자·파일 선택 tag 면 수행하고 true). 짝이 없는 답(비운 뒤 늦게 온 답·다른 브라우저 번호)은 버린다.
pub fn handle(msg: Message) bool {
    switch (msg) {
        .dialog_reply => |value| {
            const entry = table.find(value.browser, value.request, .js) orelse return true;
            const pending = table.take(entry);
            if (value.suppress) if (pageOf(value.browser)) |page| {
                page.suppressed = true;
            };
            // 떠나기 확인에 머무르기 — 이동이 취소됐다. 그 이동이 남긴 「새 문서에서 풀기」 표시를 지운다.
            if (!value.accept) clearReset(value.browser);
            const callback: [*c]c.cef_jsdialog_callback_t = @ptrCast(@alignCast(pending.callback));
            var text = std.mem.zeroes(c.cef_string_t);
            library.setString(browsers.state.api, &text, value.text);
            defer browsers.state.api.string_utf16_clear(&text);
            callback.*.cont.?(callback, @intFromBool(value.accept), &text);
            object.release(callback);
        },
        .file_dialog_path => |value| {
            const entry = table.find(value.browser, value.request, .file) orelse return true;
            if (entry.path_count >= dialog_table.max_paths) return true;
            const api = browsers.state.api;
            if (entry.paths == null) entry.paths = @ptrCast(api.string_list_alloc() orelse return true);
            var path = std.mem.zeroes(c.cef_string_t);
            library.setString(api, &path, value.path);
            defer api.string_utf16_clear(&path);
            api.string_list_append(@ptrCast(entry.paths), &path);
            entry.path_count += 1;
        },
        .file_dialog_reply => |value| {
            const entry = table.find(value.browser, value.request, .file) orelse return true;
            const pending = table.take(entry);
            const callback: [*c]c.cef_file_dialog_callback_t = @ptrCast(@alignCast(pending.callback));
            // 경로 없는 수락은 취소와 같다(CEF 헤더 — 빈 목록은 cancel 로 본다).
            if (value.accept and pending.path_count > 0) {
                callback.*.cont.?(callback, @ptrCast(pending.paths));
            } else {
                callback.*.cancel.?(callback);
            }
            freePaths(pending);
            object.release(callback);
        },
        else => return false,
    }
    return true;
}

fn freePaths(entry: dialog_table.Entry) void {
    if (entry.paths) |paths| browsers.state.api.string_list_free(@ptrCast(paths));
}

/// 브라우저가 닫혔다 — 남은 요청을 모두 놓는다(답하지 않는다 — 콜백이 가리키는 페이지가 없다).
pub fn dropBrowser(id: BrowserId) void {
    while (table.takeFor(id, null)) |pending| release(pending);
    forgetPage(id);
}

/// 종료 — 모든 요청을 놓는다.
pub fn dropAll() void {
    while (table.takeAny()) |pending| release(pending);
}

fn release(pending: dialog_table.Entry) void {
    switch (pending.kind) {
        .js => object.release(@as([*c]c.cef_jsdialog_callback_t, @ptrCast(@alignCast(pending.callback)))),
        .file => {
            freePaths(pending);
            object.release(@as([*c]c.cef_file_dialog_callback_t, @ptrCast(@alignCast(pending.callback))));
        },
    }
}
