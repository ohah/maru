//! 사이트 권한(2026-11-18 — 사람의 「Site Permissions…」 창). Chromium 이 출처마다 기억한 허용·차단을 읽어 maru 로 보내고, 사람이 고른
//! 하나를 기본(묻기)으로 되돌린다. CEF UI 스레드에서 돈다.
//!
//! 어디에 있나(실측 2026-11-18): 프로필 설정 `profile.content_settings.exceptions.<종류>` 의 사전 — 키는 `"<1차 패턴>,<2차 패턴>"`, 값은
//! `{"setting": 1|2, "last_modified": …}`. 권한 프롬프트의 답은 1차가 출처(`https://a.example:443`), 2차가 `*` 다. 사람의 답과 에이전트의
//! 답(`browser.permission`)은 같은 길로 저장돼 가를 칸이 없다 — 그래서 창에 똑같이 보인다. 읽기는 CEF 의 preference manager
//! (`get_preference` — `preferences.zig` 가 쓰는 것), 되돌리기는 `set_content_setting(…, DEFAULT)`(`permissions.restoreOrigin` 이 쓰는 것).
//! 출처 꼴이 아닌 패턴(`[*.]a.example`·`*`)·2차가 `*` 가 아닌 것(저장소 접근의 임베드)·수가 아닌 값은 정확히 지울 수 없어 싣지 않고 센다
//! (`unlisted`).

const std = @import("std");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const protocol = @import("web_sidecar_protocol");
const message = protocol.message;
const Kind = message.SitePermissionKind;

const Entry = struct { kind: Kind, pref: []const u8, cef: c.cef_content_setting_types_t };

/// 종류 → Chromium 의 설정 이름·CEF 형. 이름은 Chromium 의 content settings 등록 이름이다(`profile.content_settings.exceptions.` 뒤).
pub const table = [_]Entry{
    .{ .kind = .notifications, .pref = "notifications", .cef = c.CEF_CONTENT_SETTING_TYPE_NOTIFICATIONS },
    .{ .kind = .geolocation, .pref = "geolocation", .cef = c.CEF_CONTENT_SETTING_TYPE_GEOLOCATION },
    .{ .kind = .camera, .pref = "media_stream_camera", .cef = c.CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_CAMERA },
    .{ .kind = .microphone, .pref = "media_stream_mic", .cef = c.CEF_CONTENT_SETTING_TYPE_MEDIASTREAM_MIC },
    .{ .kind = .midi_sysex, .pref = "midi_sysex", .cef = c.CEF_CONTENT_SETTING_TYPE_MIDI_SYSEX },
    .{ .kind = .local_fonts, .pref = "local_fonts", .cef = c.CEF_CONTENT_SETTING_TYPE_LOCAL_FONTS },
    .{ .kind = .window_management, .pref = "window_placement", .cef = c.CEF_CONTENT_SETTING_TYPE_WINDOW_MANAGEMENT },
    .{ .kind = .clipboard, .pref = "clipboard", .cef = c.CEF_CONTENT_SETTING_TYPE_CLIPBOARD_READ_WRITE },
    .{ .kind = .idle_detection, .pref = "idle_detection", .cef = c.CEF_CONTENT_SETTING_TYPE_IDLE_DETECTION },
    .{ .kind = .sensors, .pref = "sensors", .cef = c.CEF_CONTENT_SETTING_TYPE_SENSORS },
    .{ .kind = .camera_pan_tilt_zoom, .pref = "camera_pan_tilt_zoom", .cef = c.CEF_CONTENT_SETTING_TYPE_CAMERA_PAN_TILT_ZOOM },
    .{ .kind = .automatic_downloads, .pref = "automatic_downloads", .cef = c.CEF_CONTENT_SETTING_TYPE_AUTOMATIC_DOWNLOADS },
    .{ .kind = .storage_access, .pref = "storage_access", .cef = c.CEF_CONTENT_SETTING_TYPE_STORAGE_ACCESS },
    .{ .kind = .ar, .pref = "ar", .cef = c.CEF_CONTENT_SETTING_TYPE_AR },
    .{ .kind = .vr, .pref = "vr", .cef = c.CEF_CONTENT_SETTING_TYPE_VR },
    .{ .kind = .hand_tracking, .pref = "hand_tracking", .cef = c.CEF_CONTENT_SETTING_TYPE_HAND_TRACKING },
    .{ .kind = .keyboard_lock, .pref = "keyboard_lock", .cef = c.CEF_CONTENT_SETTING_TYPE_KEYBOARD_LOCK },
    .{ .kind = .pointer_lock, .pref = "pointer_lock", .cef = c.CEF_CONTENT_SETTING_TYPE_POINTER_LOCK },
};

comptime {
    // 종류마다 한 줄 — 닫힌 enum 이 늘면 표도 늘어야 빌드가 된다.
    for (@import("type_info_fields").fields(Kind)) |f| {
        var found = false;
        for (table) |e| {
            if (@backingInt(e.kind) == f.value) found = true;
        }
        if (!found) @compileError("site_settings.table is missing a kind: " ++ f.name);
    }
}

fn entryOf(kind: Kind) Entry {
    for (table) |e| if (e.kind == kind) return e;
    unreachable;
}

/// `site_permissions`: 지울 것이 있으면 먼저 지우고, 목록을 보낸다(늘 하나).
pub fn apply(value: message.SitePermissions) void {
    const api = browsers.state.api;
    const context = api.request_context_get_global_context();
    var list: message.SitePermissionsList = .{ .request = value.request, .total = 0, .unlisted = 0 };
    if (context == null) return send(&list);
    // request context 의 참조 카운트는 두 겹 아래(preference manager → base)에 있다(`preferences.zig` 와 같다).
    defer _ = context.*.base.base.release.?(&context.*.base.base);
    if (value.reset_kind != 0) if (std.enums.fromInt(Kind, value.reset_kind)) |kind| {
        var url = std.mem.zeroes(c.cef_string_t);
        library.setString(api, &url, value.reset_origin);
        defer api.string_utf16_clear(&url);
        context.*.set_content_setting.?(context, &url, &url, entryOf(kind).cef, c.CEF_CONTENT_SETTING_VALUE_DEFAULT);
    };
    // 출처 글은 frame 을 보낼 때까지 살아 있어야 한다 — 행마다 칸 하나.
    var origins: [message.max_site_permission_entries][protocol.fields.max_origin_bytes]u8 = undefined;
    const manager: *c.cef_preference_manager_t = &context.*.base;
    for (table) |e| collect(api, manager, e.kind, e.pref, &list, &origins);
    send(&list);
}

fn send(list: *const message.SitePermissionsList) void {
    browsers.state.writer.send(.{ .site_permissions_list = list.* }) catch {};
}

fn collect(api: *const library.Api, manager: *c.cef_preference_manager_t, kind: Kind, pref: []const u8, list: *message.SitePermissionsList, origins: *[message.max_site_permission_entries][protocol.fields.max_origin_bytes]u8) void {
    var name_buf: [96]u8 = undefined;
    const full = std.fmt.bufPrint(&name_buf, "profile.content_settings.exceptions.{s}", .{pref}) catch return;
    var name = std.mem.zeroes(c.cef_string_t);
    library.setString(api, &name, full);
    defer api.string_utf16_clear(&name);
    if (manager.has_preference.?(manager, &name) == 0) return;
    const value = manager.get_preference.?(manager, &name);
    if (value == null) return;
    defer object.release(value);
    if (value.*.get_type.?(value) != c.VTYPE_DICTIONARY) return;
    const dict = value.*.get_dictionary.?(value);
    if (dict == null) return;
    defer object.release(dict);
    const keys = api.string_list_alloc();
    if (keys == null) return;
    defer api.string_list_free(keys);
    if (dict.*.get_keys.?(dict, keys) == 0) return;
    const n = api.string_list_size(keys);
    for (0..n) |i| {
        var key = std.mem.zeroes(c.cef_string_t);
        if (api.string_list_value(keys, i, &key) == 0) continue;
        defer api.string_utf16_clear(&key);
        const setting = settingOf(dict, &key) orelse {
            list.unlisted +|= 1;
            continue;
        };
        var raw_buf: [protocol.fields.max_origin_bytes * 2 + 8]u8 = undefined;
        const raw = library.readString(api, &key, &raw_buf);
        const origin = originOfPattern(raw) orelse {
            list.unlisted +|= 1;
            continue;
        };
        list.total +|= 1;
        if (list.count >= message.max_site_permission_entries) continue;
        const slot = &origins[list.count];
        @memcpy(slot[0..origin.len], origin);
        list.entries[list.count] = .{ .kind = kind, .setting = setting, .origin = slot[0..origin.len] };
        list.count += 1;
    }
}

/// 그 키의 값 `{"setting": 1|2, …}` 의 결정. 수가 아니거나 허용·차단이 아니면 null.
fn settingOf(dict: *c.cef_dictionary_value_t, key: *const c.cef_string_t) ?message.SitePermissionSetting {
    if (dict.*.get_type.?(dict, key) != c.VTYPE_DICTIONARY) return null;
    const inner = dict.*.get_dictionary.?(dict, key);
    if (inner == null) return null;
    defer object.release(inner);
    var setting_key = std.mem.zeroes(c.cef_string_t);
    const api = browsers.state.api;
    library.setString(api, &setting_key, "setting");
    defer api.string_utf16_clear(&setting_key);
    if (inner.*.get_type.?(inner, &setting_key) != c.VTYPE_INT) return null;
    const v = inner.*.get_int.?(inner, &setting_key);
    if (v < 0 or v > 255) return null;
    return std.enums.fromInt(message.SitePermissionSetting, @as(u8, @intCast(v)));
}

const originOfPattern = @import("site_pattern.zig").originOfPattern;
