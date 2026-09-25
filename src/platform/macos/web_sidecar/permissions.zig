//! 권한 요청(W5b — C6) — CEF 가 묻는 권한(`on_show_permission_prompt`)과 카메라·마이크·화면(`on_request_media_access_permission`)
//! 을 maru 로 보내고 답이 오면 CEF 콜백을 부른다. CEF UI 스레드에서 돈다. 요청 표·번호·출처 규칙은 JS 대화상자(W5a —
//! `dialogs.zig`)와 같이 쓴다.
//!
//! 왜 maru 로 보내는가: 핸들러가 없으면 Chromium 이 묻지도 답하지도 않아 페이지가 **끝없이 기다린다**(W5b 착수 전 실측 —
//! docs/plans/web-osr-backend.md C6). 허용·차단은 Chromium 이 출처별로 기억한다(사용자 결정 2026-09-25 — 다음 요청은 이 콜백까지
//! 오지 않는다). 묻지 못하면(브라우저가 닫히는 중·표가 참·maru 에 못 보냄) 프롬프트는 IGNORE(기억하지 않는다), 미디어는 거부다.
//! CEF 가 프롬프트를 스스로 닫으면(페이지 이동 — `on_dismiss_permission_prompt`) maru 에 `dialog_closed` 를 알린다.

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
    var origin_buf: [protocol.fields.max_origin_bytes]u8 = undefined;
    browsers.state.writer.send(.{ .permission_request = .{
        .browser = id,
        .request = request,
        .origin = dialogs.originOf(requesting_origin, &origin_buf),
        .kinds = kinds,
    } }) catch {
        if (dialogs.table.find(id, request, .prompt)) |entry| _ = dialogs.table.take(entry);
        return ignore(callback);
    };
    return 1;
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
