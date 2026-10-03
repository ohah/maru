//! 권한 요청(W5b — C6) — CEF 가 묻는 권한(`on_show_permission_prompt`)과 카메라·마이크·화면(`on_request_media_access_permission`)
//! 을 maru 로 보내고 답이 오면 CEF 콜백을 부른다. CEF UI 스레드에서 돈다. 요청 표·번호·출처 규칙은 JS 대화상자(W5a —
//! `dialogs.zig`)와 같이 쓴다.
//!
//! 왜 maru 로 보내는가: 핸들러가 없으면 Chromium 이 묻지도 답하지도 않아 페이지가 **끝없이 기다린다**(W5b 착수 전 실측 —
//! docs/plans/web-osr-backend.md C6). 허용·차단은 Chromium 이 출처별로 기억한다(사용자 결정 2026-09-25 — 다음 요청은 이 콜백까지
//! 오지 않는다). 묻지 못하면(브라우저가 닫히는 중·표가 참·maru 에 못 보냄) 프롬프트는 IGNORE(기억하지 않는다), 미디어는 거부다.
//! CEF 가 프롬프트를 스스로 닫으면(페이지 이동 — `on_dismiss_permission_prompt`) maru 에 `dialog_closed` 를 알린다.
//!
//! 위치(W5b2): Chromium 의 위치 공급자는 CEF 에서 돌지 않는다(macOS 위치 권한은 프로세스마다 매겨져 Maru 가 받은 허용이
//! sidecar 에 보이지 않는다 — 실측). maru 가 CoreLocation 으로 구한 좌표(`geolocation`)를 그 브라우저에 DevTools
//! `Emulation.setGeolocationOverride` 로 걸고 **나서** 허용으로 답한다 — 덮어쓰기를 다시 걸면 기다리던 위치 요청이 먼저
//! 「위치를 알 수 없음」을 받아서(실측) 허용 뒤에 걸면 그 요청이 실패한다. Chromium 은 허용을 기억해도 위치를 부를 때마다
//! 다시 묻으므로(실측) 기억한 허용이면 `remembered` 를 붙인다 — maru 는 그 표시를 믿지 않고, 자기 sheet 에서 그 탭이 허용받은
//! 출처일 때만 sheet 없이 좌표를 구한다(적대 검증).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const browsers = @import("browsers.zig");
const dialogs = @import("dialogs.zig");
const dialog_table = @import("dialog_table.zig");

const message = protocol.message;
const BrowserId = message.BrowserId;

// 프로토콜 값이 CEF 와 같다 — CEF 를 올려 바뀌면 빌드가 멈춘다.
comptime {
    for (std.meta.fields(message.PermissionKind)) |field| {
        const kind: message.PermissionKind = @enumFromInt(field.value);
        const cef_value: u32 = switch (kind) {
            .ar_session => c.CEF_PERMISSION_TYPE_AR_SESSION,
            .camera_pan_tilt_zoom => c.CEF_PERMISSION_TYPE_CAMERA_PAN_TILT_ZOOM,
            .camera => c.CEF_PERMISSION_TYPE_CAMERA_STREAM,
            .captured_surface_control => c.CEF_PERMISSION_TYPE_CAPTURED_SURFACE_CONTROL,
            .clipboard => c.CEF_PERMISSION_TYPE_CLIPBOARD,
            .top_level_storage_access => c.CEF_PERMISSION_TYPE_TOP_LEVEL_STORAGE_ACCESS,
            .disk_quota => c.CEF_PERMISSION_TYPE_DISK_QUOTA,
            .local_fonts => c.CEF_PERMISSION_TYPE_LOCAL_FONTS,
            .geolocation => c.CEF_PERMISSION_TYPE_GEOLOCATION,
            .hand_tracking => c.CEF_PERMISSION_TYPE_HAND_TRACKING,
            .identity_provider => c.CEF_PERMISSION_TYPE_IDENTITY_PROVIDER,
            .idle_detection => c.CEF_PERMISSION_TYPE_IDLE_DETECTION,
            .microphone => c.CEF_PERMISSION_TYPE_MIC_STREAM,
            .midi_sysex => c.CEF_PERMISSION_TYPE_MIDI_SYSEX,
            .multiple_downloads => c.CEF_PERMISSION_TYPE_MULTIPLE_DOWNLOADS,
            .notifications => c.CEF_PERMISSION_TYPE_NOTIFICATIONS,
            .keyboard_lock => c.CEF_PERMISSION_TYPE_KEYBOARD_LOCK,
            .pointer_lock => c.CEF_PERMISSION_TYPE_POINTER_LOCK,
            .protected_media_identifier => c.CEF_PERMISSION_TYPE_PROTECTED_MEDIA_IDENTIFIER,
            .register_protocol_handler => c.CEF_PERMISSION_TYPE_REGISTER_PROTOCOL_HANDLER,
            .storage_access => c.CEF_PERMISSION_TYPE_STORAGE_ACCESS,
            .vr_session => c.CEF_PERMISSION_TYPE_VR_SESSION,
            .web_app_installation => c.CEF_PERMISSION_TYPE_WEB_APP_INSTALLATION,
            .window_management => c.CEF_PERMISSION_TYPE_WINDOW_MANAGEMENT,
            .file_system_access => c.CEF_PERMISSION_TYPE_FILE_SYSTEM_ACCESS,
            .local_network_access => c.CEF_PERMISSION_TYPE_LOCAL_NETWORK_ACCESS_DEPRECATED,
            .local_network => c.CEF_PERMISSION_TYPE_LOCAL_NETWORK,
            .loopback_network => c.CEF_PERMISSION_TYPE_LOOPBACK_NETWORK,
            .sensors => c.CEF_PERMISSION_TYPE_SENSORS,
        };
        std.debug.assert(cef_value == kind.bit());
    }
    std.debug.assert(c.CEF_MEDIA_PERMISSION_DEVICE_AUDIO_CAPTURE == message.MediaPermission.microphone.bit());
    std.debug.assert(c.CEF_MEDIA_PERMISSION_DEVICE_VIDEO_CAPTURE == message.MediaPermission.camera.bit());
    std.debug.assert(c.CEF_MEDIA_PERMISSION_DESKTOP_AUDIO_CAPTURE == message.MediaPermission.screen_audio.bit());
    std.debug.assert(c.CEF_MEDIA_PERMISSION_DESKTOP_VIDEO_CAPTURE == message.MediaPermission.screen.bit());
    std.debug.assert(c.CEF_PERMISSION_RESULT_ACCEPT == @intFromEnum(message.PermissionResult.accept));
    std.debug.assert(c.CEF_PERMISSION_RESULT_DENY == @intFromEnum(message.PermissionResult.deny));
    std.debug.assert(c.CEF_PERMISSION_RESULT_DISMISS == @intFromEnum(message.PermissionResult.dismiss));
    std.debug.assert(c.CEF_PERMISSION_RESULT_IGNORE == @intFromEnum(message.PermissionResult.ignore));
}

/// `on_show_permission_prompt`. 1 을 돌려주면 우리가 답한다(나중에 콜백으로).
pub fn onShowPermissionPrompt(
    _: [*c]c.cef_permission_handler_t,
    browser: [*c]c.cef_browser_t,
    prompt_id: u64,
    requesting_origin: [*c]const c.cef_string_t,
    requested_permissions: u32,
    callback: [*c]c.cef_permission_prompt_callback_t,
) callconv(.c) c_int {
    defer object.releaseArg(browser);
    // 모르는 비트(CEF 를 올려 새로 생긴 종류)는 묻지 않는다 — 사용자가 무엇을 허용하는지 보일 수 없다.
    const kinds = requested_permissions;
    if (kinds == 0 or kinds & ~message.permission_kind_mask != 0) return ignore(callback);
    const id = dialogs.browserId(browser) orelse return ignore(callback);
    const request = dialogs.table.addPermission(id, .prompt, @ptrCast(callback), prompt_id) orelse return ignore(callback);
    dialogs.table.find(id, request, .prompt).?.kinds = kinds;
    var origin_buf: [protocol.fields.max_origin_bytes]u8 = undefined;
    browsers.state.writer.send(.{ .permission_request = .{
        .browser = id,
        .request = request,
        .origin = dialogs.originOf(requesting_origin, &origin_buf),
        .kinds = kinds,
        .remembered = kinds == geolocation_bit and rememberedAllow(requesting_origin),
    } }) catch {
        if (dialogs.table.find(id, request, .prompt)) |entry| _ = dialogs.table.take(entry);
        return ignore(callback);
    };
    return 1;
}

const geolocation_bit = message.PermissionKind.geolocation.bit();

/// 그 출처의 위치를 Chromium 이 허용으로 기억하는가(W5b2).
fn rememberedAllow(origin: [*c]const c.cef_string_t) bool {
    if (origin == null) return false;
    const ctx = browsers.state.api.request_context_get_global_context();
    if (ctx == null) return false;
    // request context 의 참조 카운트는 두 겹 아래(preference manager → base)에 있다(`preferences.zig` 와 같다).
    defer _ = ctx.*.base.base.release.?(&ctx.*.base.base);
    return ctx.*.get_content_setting.?(ctx, origin, origin, c.CEF_CONTENT_SETTING_TYPE_GEOLOCATION) == c.CEF_CONTENT_SETTING_VALUE_ALLOW;
}

/// maru 가 구한 좌표(W5b2) — 그 위치 요청의 브라우저에 덮어쓰기를 건다. 위치 요청이 아니거나 짝이 없으면 버린다.
pub fn geolocation(value: message.Geolocation) void {
    const entry = dialogs.table.find(value.browser, value.request, .prompt) orelse return;
    if (entry.kinds & geolocation_bit == 0) return;
    const registered = browsers.state.registry.byId(value.browser) orelse return;
    const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(registered.handle));
    // 걸지 못했으면 표시하지 않는다 — 허용할 때 「없음」을 건다(전에 걸린 옛 좌표가 나가거나 페이지가 끝없이 기다리지 않게 —
    // 적대 검증).
    entry.geo_set = applyOverride(value.browser, browser, if (value.available) value else null) or applyOverride(value.browser, browser, null);
}

/// 브라우저마다 마지막으로 건 덮어쓰기. 같은 값이면 다시 걸지 않는다 — 다시 걸면 그 탭의 기다리던 위치 요청(돌고 있는
/// `watchPosition` 포함)이 먼저 오류를 받는다(실측 — 2 차 적대 검증: 1 분 안의 같은 좌표를 되쓰는 경우).
const Applied = struct { browser: BrowserId, available: bool, latitude: f64, longitude: f64, accuracy: f64 };
var applied: [dialog_table.capacity]?Applied = [_]?Applied{null} ** dialog_table.capacity;

fn appliedSlot(id: BrowserId) ?*?Applied {
    var free: ?*?Applied = null;
    for (&applied) |*slot| {
        if (slot.*) |a| {
            if (a.browser == id) return slot;
        } else if (free == null) free = slot;
    }
    return free;
}

fn applyOverride(id: BrowserId, browser: [*c]c.cef_browser_t, position: ?message.Geolocation) bool {
    const next: Applied = if (position) |p|
        .{ .browser = id, .available = true, .latitude = p.latitude, .longitude = p.longitude, .accuracy = p.accuracy }
    else
        .{ .browser = id, .available = false, .latitude = 0, .longitude = 0, .accuracy = 0 };
    const slot = appliedSlot(id);
    if (slot) |s| if (s.*) |prev| if (std.meta.eql(prev, next)) return true;
    if (!overrideGeolocation(browser, position)) return false;
    if (slot) |s| s.* = next;
    return true;
}

/// 주 프레임에 새 문서가 온다 — 좌표가 걸려 있으면 「없음」으로 되돌린다(다른 출처로 옮겨 간 뒤 옛 좌표가 남지 않게 — 방어. 새
/// 문서의 요청은 아직 없어 오류가 가지 않는다).
pub fn resetOverride(id: BrowserId) void {
    const slot = appliedSlot(id) orelse return;
    const prev = slot.* orelse return;
    if (!prev.available) return;
    const registered = browsers.state.registry.byId(id) orelse return;
    _ = applyOverride(id, @ptrCast(@alignCast(registered.handle)), null);
}

/// 위치 보정 스크립트(W5b2 — 사용자 결정 2026-09-26). 덮어쓰기는 걸 때 한 번만 새 좌표로 전해져, 같은 문서의 다음
/// `getCurrentPosition`(`maximumAge` 0 — 기본값)은 새 좌표를 기다리다 시한까지(시한이 없으면 끝없이) 멈췄다 — 이때 Chromium 은
/// 다시 묻지도 않는다(실측). `maximumAge` 가 있으면 Blink 가 받아 둔 좌표를 곧바로 준다(실측) — 그 문서의 좌표는 어차피 하나로
/// 고정이라(갱신하지 않는다 — 사용자 결정) 결과는 같다. 페이지가 `maximumAge` 를 주지 않으면 60 초를 채운다. 작은따옴표만 써서
/// JSON 문자열에 그대로 넣는다(아래 comptime 이 지킨다).
const geolocation_shim = "(function(){try{var g=navigator.geolocation;if(!g||g.__maruGeo)return;var f=g.getCurrentPosition;" ++
    "Object.defineProperty(g,'__maruGeo',{value:1});g.getCurrentPosition=function(s,e,o){var p={};if(o)for(var k in o)p[k]=o[k];" ++
    "if(!(p.maximumAge>0))p.maximumAge=60000;return f.call(g,s,e,p)}}catch(x){}})()";

comptime {
    @setEvalBranchQuota(10_000);
    std.debug.assert(std.mem.indexOfAny(u8, geolocation_shim, "\"\\\n") == null);
}

/// 새 문서마다 보정 스크립트를 넣게 한다(브라우저를 만들 때 — iframe 을 포함한 모든 프레임). Page 도메인을 먼저 켜야 등록이
/// 먹는다 — 켜지 않으면 새 문서·iframe 에 들어가지 않았다(판정자 `geo-unavailable` 의 iframe — 실측).
pub fn installGeolocationShim(browser: [*c]c.cef_browser_t) void {
    const host = browser.*.get_host.?(browser);
    if (host == null) return;
    defer object.release(host);
    devtools_id +%= 1;
    var buf: [64]u8 = undefined;
    const enable = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"Page.enable\",\"params\":{{}}}}", .{devtools_id}) catch return;
    _ = host.*.send_dev_tools_message.?(host, enable.ptr, enable.len);
    sendDevTools(browser, "Page.addScriptToEvaluateOnNewDocument", "source");
}

/// 지금 문서에도 넣는다(위치를 허용할 때 — 등록보다 먼저 시작한 첫 문서를 놓치지 않게).
fn evaluateGeolocationShim(browser: [*c]c.cef_browser_t) void {
    sendDevTools(browser, "Runtime.evaluate", "expression");
}

fn sendDevTools(browser: [*c]c.cef_browser_t, method: []const u8, param: []const u8) void {
    const host = browser.*.get_host.?(browser);
    if (host == null) return;
    defer object.release(host);
    devtools_id +%= 1;
    var buf: [1024]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"{s}\",\"params\":{{\"{s}\":\"{s}\"}}}}", .{ devtools_id, method, param, geolocation_shim }) catch return;
    _ = host.*.send_dev_tools_message.?(host, json.ptr, json.len);
}

/// 브라우저가 닫혔다 — 기록을 지운다.
pub fn forgetBrowser(id: BrowserId) void {
    for (&applied) |*slot| {
        if (slot.*) |a| if (a.browser == id) {
            slot.* = null;
        };
    }
}

var devtools_id: u32 = 0;

/// DevTools `Emulation.setGeolocationOverride` — 좌표가 없으면 빈 덮어쓰기(페이지는 「위치를 알 수 없음」 — 실측). 보냈으면 true.
/// 숫자는 정밀도를 고정한다(위·경도 7 자리 ≈ 1 cm, 정확도 3 자리) — `{d}` 는 지수 없이 전부 써서 아주 작은 값이 버퍼를 넘겼다
/// (적대 검증).
fn overrideGeolocation(browser: [*c]c.cef_browser_t, position: ?message.Geolocation) bool {
    const host = browser.*.get_host.?(browser);
    if (host == null) return false;
    defer object.release(host);
    devtools_id +%= 1;
    var buf: [256]u8 = undefined;
    const json = if (position) |p|
        std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"Emulation.setGeolocationOverride\",\"params\":{{\"latitude\":{d:.7},\"longitude\":{d:.7},\"accuracy\":{d:.3}}}}}", .{ devtools_id, p.latitude, p.longitude, p.accuracy }) catch return false
    else
        std.fmt.bufPrint(&buf, "{{\"id\":{d},\"method\":\"Emulation.setGeolocationOverride\",\"params\":{{}}}}", .{devtools_id}) catch return false;
    return host.*.send_dev_tools_message.?(host, json.ptr, json.len) != 0;
}

/// 묻지 못한 프롬프트 — IGNORE 로 답한다(차단·닫기와 달리 기억하지 않는다).
fn ignore(callback: [*c]c.cef_permission_prompt_callback_t) c_int {
    callback.*.cont.?(callback, c.CEF_PERMISSION_RESULT_IGNORE);
    object.releaseArg(callback);
    return 1;
}

/// CEF 가 프롬프트를 닫았다(페이지 이동·탭 닫기, 또는 우리가 답한 뒤). 아직 표에 있으면 답할 곳이 없다 — 놓고 maru 에 알린다.
pub fn onDismissPermissionPrompt(
    _: [*c]c.cef_permission_handler_t,
    browser: [*c]c.cef_browser_t,
    prompt_id: u64,
    _: c.cef_permission_request_result_t,
) callconv(.c) void {
    defer object.releaseArg(browser);
    const id = dialogs.browserId(browser) orelse return;
    const entry = dialogs.table.findPrompt(id, prompt_id) orelse return;
    const pending = dialogs.table.take(entry);
    release(pending);
    browsers.state.writer.send(.{ .dialog_closed = .{ .browser = pending.browser, .request = pending.request } }) catch {};
}

/// `on_request_media_access_permission` — 카메라·마이크·화면. 1 을 돌려주면 우리가 답한다.
pub fn onRequestMediaAccessPermission(
    _: [*c]c.cef_permission_handler_t,
    browser: [*c]c.cef_browser_t,
    frame: [*c]c.cef_frame_t,
    requesting_origin: [*c]const c.cef_string_t,
    requested_permissions: u32,
    callback: [*c]c.cef_media_access_callback_t,
) callconv(.c) c_int {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    const media = requested_permissions;
    if (media == 0 or media & ~@as(u32, message.permission_media_mask) != 0) return denyMedia(callback);
    const id = dialogs.browserId(browser) orelse return denyMedia(callback);
    const request = dialogs.table.addPermission(id, .media, @ptrCast(callback), media) orelse return denyMedia(callback);
    var origin_buf: [protocol.fields.max_origin_bytes]u8 = undefined;
    browsers.state.writer.send(.{ .permission_request = .{
        .browser = id,
        .request = request,
        .origin = dialogs.originOf(requesting_origin, &origin_buf),
        .media = @intCast(media),
    } }) catch {
        if (dialogs.table.find(id, request, .media)) |entry| _ = dialogs.table.take(entry);
        return denyMedia(callback);
    };
    return 1;
}

fn denyMedia(callback: [*c]c.cef_media_access_callback_t) c_int {
    callback.*.cont.?(callback, c.CEF_MEDIA_PERMISSION_NONE);
    object.releaseArg(callback);
    return 1;
}

/// maru 의 답. 짝이 없는 답(닫힌 뒤 늦게 온 답·다른 브라우저 번호)은 버린다.
pub fn reply(value: message.PermissionReply) void {
    if (dialogs.table.find(value.browser, value.request, .prompt)) |entry| {
        // 좌표 없이 위치를 허용하면 페이지가 시간 초과까지 기다린다(공급자가 돌지 않는다) — 「없음」을 걸어 곧바로 끝나게 한다.
        if (value.result == .accept and entry.kinds & geolocation_bit != 0) {
            if (browsers.state.registry.byId(value.browser)) |registered| {
                const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(registered.handle));
                if (!entry.geo_set) _ = applyOverride(value.browser, browser, null);
                evaluateGeolocationShim(browser);
            }
        }
        const pending = dialogs.table.take(entry);
        const callback: [*c]c.cef_permission_prompt_callback_t = @ptrCast(@alignCast(pending.callback));
        callback.*.cont.?(callback, @intFromEnum(value.result));
        object.release(callback);
    } else if (dialogs.table.find(value.browser, value.request, .media)) |entry| {
        const pending = dialogs.table.take(entry);
        const callback: [*c]c.cef_media_access_callback_t = @ptrCast(@alignCast(pending.callback));
        callback.*.cont.?(callback, if (value.result == .accept) @intCast(pending.extra) else c.CEF_MEDIA_PERMISSION_NONE);
        object.release(callback);
    }
}

/// maru 가 그 브라우저를 옮기거나 닫으려 한다 / 주 프레임에 새 문서가 온다(`dialogs.onLoadStart`)·이동이 실패했다
/// (`dialogs.onLoadError`) / 렌더러가 죽었다 — 기다리는 미디어 요청은 거부로 답하고 알린다(미디어는 CEF 가 닫힘을 알리지 않는다.
/// 프롬프트는 CEF 가 이동과 함께 스스로 닫는다 — `onDismissPermissionPrompt`).
pub fn cancelMedia(id: BrowserId) void {
    while (dialogs.table.takeFor(id, .media)) |pending| {
        const callback: [*c]c.cef_media_access_callback_t = @ptrCast(@alignCast(pending.callback));
        callback.*.cont.?(callback, c.CEF_MEDIA_PERMISSION_NONE);
        object.release(callback);
        browsers.state.writer.send(.{ .dialog_closed = .{ .browser = pending.browser, .request = pending.request } }) catch {};
    }
}

/// 렌더러가 죽었다 — 프롬프트도 닫힘 알림이 안 올 수 있다. 기억하지 않는 IGNORE 로 답하고 알린다.
pub fn rendererGone(id: BrowserId) void {
    cancelMedia(id);
    while (dialogs.table.takeFor(id, .prompt)) |pending| {
        const callback: [*c]c.cef_permission_prompt_callback_t = @ptrCast(@alignCast(pending.callback));
        callback.*.cont.?(callback, c.CEF_PERMISSION_RESULT_IGNORE);
        object.release(callback);
        browsers.state.writer.send(.{ .dialog_closed = .{ .browser = pending.browser, .request = pending.request } }) catch {};
    }
}

/// 답하지 않고 놓는다(브라우저가 닫혔거나 종료 — `dialogs.release` 가 부른다).
pub fn release(pending: dialog_table.Entry) void {
    switch (pending.kind) {
        .prompt => object.release(@as([*c]c.cef_permission_prompt_callback_t, @ptrCast(@alignCast(pending.callback)))),
        .media => object.release(@as([*c]c.cef_media_access_callback_t, @ptrCast(@alignCast(pending.callback)))),
        .js, .file => unreachable,
    }
}
