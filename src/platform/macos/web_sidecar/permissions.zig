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
//!
//! W9e①(사용자 결정 Q2 2026-10-22): 위치 덮어쓰기는 탭에 한 칸이다(`geo_slot.zig`). 에이전트가 위치를 흉내 낸 탭(`emulation.zig` 가 `agentSet`)
//! 에서는 maru 의 좌표·「없음」 을 걸지 않고(새 문서의 되돌림도), 그 탭의 **위치만** 묻는 프롬프트에는 maru 에 묻지 않고 허용으로 답한다 —
//! 좌표는 에이전트 것이라 진짜 위치는 나가지 않는다. Chromium 이 그 허용을 출처에 저장하므로 그때 설정이 기본이었으면 출처를 적어 두고 흉내가
//! 끝나면(지움·철회·사이트 떠남·탭 닫힘) 기본으로 되돌린다. 다른 권한이 섞인 프롬프트는 그대로 maru 에 묻는다(`geo_slot.promptAutoAllowable`).
//! 실측(CEF 154, W9e① 변이 J4·J9): 그 허용은 content setting 에 ALLOW 로 읽히지만 페이지 권한에는 쓰이지 않았다(`permissions.query` 는 `prompt`,
//! 다음 요청은 다시 묻는다, SIGKILL 뒤의 새 sidecar 는 ASK 로 읽었다) — 되돌림은 그 값을 원래대로 둘 뿐이라 페이지로는 보이지 않는다. 남긴
//! 까닭: 호출 하나라 해가 없고, 남은 ALLOW 는 사용자 탭의 같은 출처 요청에 `remembered` 를 세우며, 저장된 허용을 쓰는 Chromium 이 오면 에이전트가
//! 받은 허용이 사용자 탭에 남는다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const browsers = @import("browsers.zig");
const dialogs = @import("dialogs.zig");
const dialog_table = @import("dialog_table.zig");
const library = @import("library.zig");
const geo_slot = @import("geo_slot.zig"); // W9e①: 위치 한 칸(W5b2 와 에이전트 흉내 — 사용자 결정 Q2)

const message = protocol.message;
const BrowserId = message.BrowserId;

// 프로토콜 값이 CEF 와 같다 — CEF 를 올려 바뀌면 빌드가 멈춘다.
comptime {
    for (@import("type_info_fields").fields(message.PermissionKind)) |field| {
        const kind: message.PermissionKind = @fromBackingInt(@intCast(field.value));
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
    std.debug.assert(c.CEF_PERMISSION_RESULT_ACCEPT == @backingInt(message.PermissionResult.accept));
    std.debug.assert(c.CEF_PERMISSION_RESULT_DENY == @backingInt(message.PermissionResult.deny));
    std.debug.assert(c.CEF_PERMISSION_RESULT_DISMISS == @backingInt(message.PermissionResult.dismiss));
    std.debug.assert(c.CEF_PERMISSION_RESULT_IGNORE == @backingInt(message.PermissionResult.ignore));
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
    // W9e① Q2: 에이전트가 위치를 흉내 낸 탭의 위치만 묻는 프롬프트 — 묻지 않고 허용(에이전트 좌표만 나간다).
    if (geo_slot.promptAutoAllowable(kinds) and autoAllow(id, browser, requesting_origin)) {
        callback.*.cont.?(callback, c.CEF_PERMISSION_RESULT_ACCEPT);
        object.releaseArg(callback);
        return 1;
    }
    const request = dialogs.table.addPermission(id, .prompt, @ptrCast(callback), prompt_id) orelse return ignore(callback);
    dialogs.table.find(id, request, .prompt).?.kinds = kinds;
    // W9e①: 사용자가 이 위치 요청을 허용하면 그 출처의 저장된 허용은 사용자의 것이다 — 대신 허용 표에서 뺀다(되돌림이 지우지 않게).
    if (kinds & geolocation_bit != 0) {
        var raw_buf: [512]u8 = undefined;
        var nb: [geo_slot.max_origin_bytes]u8 = undefined;
        if (normalizeOrigin(library.readString(browsers.state.api, requesting_origin, &raw_buf), &nb)) |o| dialogs.table.find(id, request, .prompt).?.origin_hash = std.hash.Wyhash.hash(0, o);
    }
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
    return storedSetting(origin) == c.CEF_CONTENT_SETTING_VALUE_ALLOW;
}

/// 그 출처의 위치 설정(Chromium 이 저장한 것). 묻지 못하면 기본이 아닌 값(되돌림 표에 적지 않게 — 사용자가 고른 것을 지우지 않는다).
fn storedSetting(origin: [*c]const c.cef_string_t) c.cef_content_setting_values_t {
    if (origin == null) return c.CEF_CONTENT_SETTING_VALUE_ALLOW;
    const ctx = browsers.state.api.request_context_get_global_context();
    if (ctx == null) return c.CEF_CONTENT_SETTING_VALUE_ALLOW;
    // request context 의 참조 카운트는 두 겹 아래(preference manager → base)에 있다(`preferences.zig` 와 같다).
    defer _ = ctx.*.base.base.release.?(&ctx.*.base.base);
    return ctx.*.get_content_setting.?(ctx, origin, origin, c.CEF_CONTENT_SETTING_TYPE_GEOLOCATION);
}

/// 그 출처의 위치 설정을 기본으로 되돌린다(W9e① — 대신 허용한 것). 그 출처를 보이는 페이지의 권한도 함께 사라진다(W5b 실측 — 끝난 흉내라
/// 맞다).
pub fn restoreOrigin(origin: []const u8) void {
    const ctx = browsers.state.api.request_context_get_global_context();
    if (ctx == null) return;
    defer _ = ctx.*.base.base.release.?(&ctx.*.base.base);
    var url = std.mem.zeroes(c.cef_string_t);
    library.setString(browsers.state.api, &url, origin);
    defer browsers.state.api.string_utf16_clear(&url);
    // 그 사이 사용자가 그 출처를 거절했으면(다른 탭의 maru 모달) 그 고름은 둔다 — 대신 허용이 남긴 허용만 지운다.
    const now = ctx.*.get_content_setting.?(ctx, &url, &url, c.CEF_CONTENT_SETTING_TYPE_GEOLOCATION);
    const reset = now != c.CEF_CONTENT_SETTING_VALUE_BLOCK;
    if (reset) ctx.*.set_content_setting.?(ctx, &url, &url, c.CEF_CONTENT_SETTING_TYPE_GEOLOCATION, c.CEF_CONTENT_SETTING_VALUE_DEFAULT);
    if (std.c.getenv("MARU_WEB_TEST_EMU_LOG") != null) std.debug.print("emu: geo restore {s} stored={d} reset={}\n", .{ origin, now, reset });
}

/// W9e① Q2: 에이전트 위치가 걸린 탭이면 그 출처를 (기본이었으면) 적고 허용으로 답할 준비를 한다(보정 스크립트도 지금 문서에). 아니면 거짓
/// (maru 에 묻는다).
fn autoAllow(id: BrowserId, browser: [*c]c.cef_browser_t, requesting_origin: [*c]const c.cef_string_t) bool {
    const slot = slotOf(id) orelse return false;
    if (!slot.agent) return false;
    var raw_buf: [512]u8 = undefined;
    const raw = library.readString(browsers.state.api, requesting_origin, &raw_buf);
    var ob: [geo_slot.max_origin_bytes]u8 = undefined;
    const origin = normalizeOrigin(raw, &ob) orelse return false; // 적을 수 없는 출처는 묻는다(되돌리지 못할 허용을 남기지 않는다)
    // 「기본」 은 사용자가 고른 값이 없다는 뜻 — Chromium 은 위치의 기본을 ASK 로 돌려준다(판정자 실측 — DEFAULT 가 아니었다). 허용·거절이
    // 저장돼 있으면 적지 않는다(사용자가 고른 것을 되돌리지 않는다).
    const stored = storedSetting(requesting_origin);
    const was_default = stored != c.CEF_CONTENT_SETTING_VALUE_ALLOW and stored != c.CEF_CONTENT_SETTING_VALUE_BLOCK;
    if (slot.record(origin, was_default)) |evicted| restoreOrigin(evicted.slice());
    evaluateGeolocationShim(browser);
    if (std.c.getenv("MARU_WEB_TEST_EMU_LOG") != null) std.debug.print("emu: geo auto-allow b={d} {s} stored={d} default={}\n", .{ id, origin, stored, was_default });
    @import("emulation.zig").autoAllowedChanged(id);
    return true;
}

/// `https://a.test:8443/` 꼴 → `https://a.test:8443`(http(s) 출처만 — `emu_fields.geoOriginOk`).
fn normalizeOrigin(raw: []const u8, out: []u8) ?[]const u8 {
    const sep = std.mem.indexOf(u8, raw, "://") orelse return null;
    var end = raw.len;
    if (std.mem.indexOfScalarPos(u8, raw, sep + 3, '/')) |slash| end = slash;
    const origin = raw[0..end];
    if (origin.len > out.len or !protocol.emu_fields.geoOriginOk(origin)) return null;
    @memcpy(out[0..origin.len], origin);
    return out[0..origin.len];
}

/// maru 가 구한 좌표(W5b2) — 그 위치 요청의 브라우저에 덮어쓰기를 건다. 위치 요청이 아니거나 짝이 없으면 버린다.
pub fn geolocation(value: message.Geolocation) void {
    const entry = dialogs.table.find(value.browser, value.request, .prompt) orelse return;
    if (entry.kinds & geolocation_bit == 0) return;
    const registered = browsers.state.registry.byId(value.browser) orelse return;
    const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(registered.handle));
    // W9e①: 에이전트 위치가 걸린 탭 — maru 의 좌표를 걸지 않는다(에이전트 좌표를 덮었다 — 실측 E14). 걸린 것으로 쳐 허용 때 「없음」 도 걸지 않는다.
    if (slotOf(value.browser)) |slot| if (!slot.maruMay()) {
        entry.geo_set = true;
        return;
    };
    // 걸지 못했으면 표시하지 않는다 — 허용할 때 「없음」을 건다(전에 걸린 옛 좌표가 나가거나 페이지가 끝없이 기다리지 않게 —
    // 적대 검증).
    entry.geo_set = applyOverride(value.browser, browser, if (value.available) value else null) or applyOverride(value.browser, browser, null);
}

/// 브라우저마다 마지막으로 건 덮어쓰기. 같은 값이면 다시 걸지 않는다 — 다시 걸면 그 탭의 기다리던 위치 요청(돌고 있는
/// `watchPosition` 포함)이 먼저 오류를 받는다(실측 — 2 차 적대 검증: 1 분 안의 같은 좌표를 되쓰는 경우).
/// W9e①: 탭마다 한 칸(`geo_slot` — 걸어 둔 값·에이전트 표시·대신 허용한 출처). 브라우저 수만큼(registry 와 같은 상한 — 대화상자 표 상한보다
/// 크다). 칸이 없으면(브라우저가 너무 많다) 걸기만 하고 기억하지 않는다(옛 동작).
var slots: [registry_capacity]?geo_slot.Slot = @splat(null);
const registry_capacity = @import("registry.zig").capacity;

fn slotOf(id: BrowserId) ?*geo_slot.Slot {
    for (&slots) |*s| if (s.*) |*v| if (v.browser == id) return v;
    return null;
}

fn slotEnsure(id: BrowserId) ?*geo_slot.Slot {
    if (slotOf(id)) |s| return s;
    for (&slots) |*s| if (s.* == null) {
        s.* = .{ .browser = id };
        return &s.*.?;
    };
    return null;
}

fn applyOverride(id: BrowserId, browser: [*c]c.cef_browser_t, position: ?message.Geolocation) bool {
    const next: geo_slot.Applied = if (position) |p| .{ .available = true, .latitude = p.latitude, .longitude = p.longitude, .accuracy = p.accuracy } else .{};
    const slot = slotEnsure(id);
    if (slot) |s| if (!s.needs(next)) return true;
    if (!overrideGeolocation(browser, position)) return false;
    if (slot) |s| s.applied = next;
    return true;
}

/// 주 프레임에 새 문서가 온다 — 좌표가 걸려 있으면 「없음」으로 되돌린다(다른 출처로 옮겨 간 뒤 옛 좌표가 남지 않게 — 방어. 새
/// 문서의 요청은 아직 없어 오류가 가지 않는다). W9e①: 에이전트 위치는 이동해도 남는다(그 탭의 흉내 — 사용자 탭의 사이트 밖은 `emulation.zig`
/// 가 지운다).
pub fn resetOverride(id: BrowserId) void {
    const slot = slotOf(id) orelse return;
    if (!slot.maruMay()) return;
    const prev = slot.applied orelse return;
    if (!prev.available) return;
    const registered = browsers.state.registry.byId(id) orelse return;
    _ = applyOverride(id, @ptrCast(@alignCast(registered.handle)), null);
}

/// W9e①: 에이전트 위치를 건다(좌표 또는 「없음」). 보냈으면(같은 값이라 보내지 않았어도) 참.
pub fn agentGeolocation(id: BrowserId, browser: [*c]c.cef_browser_t, unavailable: bool, latitude: f64, longitude: f64, accuracy: f64) bool {
    const slot = slotEnsure(id) orelse return false;
    const next = geo_slot.agentSet(slot, unavailable, latitude, longitude, accuracy) orelse return true;
    const pos: ?message.Geolocation = if (next.available) .{ .browser = id, .request = 0, .available = true, .latitude = next.latitude, .longitude = next.longitude, .accuracy = next.accuracy } else null;
    if (!overrideGeolocation(browser, pos)) {
        // 걸지 못했다 — 에이전트 칸을 세우지 않는다(세우면 W5b2 가 건 진짜 좌표가 남은 채 묻지 않고 허용했다 — 적대 리뷰).
        slot.agent = false;
        return false;
    }
    slot.applied = next;
    return true;
}

/// W9e①: 에이전트 위치가 끝났다 — 「없음」 으로 돌리고(W5b2 의 처음 상태 — 사용자가 다시 허용하면 그때 maru 가 건다) 대신 허용한 출처를
/// 기본으로 되돌린다. `browser` 가 없으면(닫혔다) 되돌림만.
pub fn agentEnd(id: BrowserId, browser: ?[*c]c.cef_browser_t) void {
    const slot = slotOf(id) orelse return;
    if (geo_slot.agentClear(slot)) |next| {
        if (browser) |b| if (overrideGeolocation(b, null)) {
            slot.applied = next;
        };
    }
    restoreAll(slot);
}

fn restoreAll(slot: *geo_slot.Slot) void {
    var taken: [geo_slot.max_origins]geo_slot.Origin = undefined;
    const list = slot.takeOrigins(&taken);
    for (list) |*o| restoreOrigin(o.slice());
    if (list.len > 0) @import("emulation.zig").autoAllowedChanged(slot.browser);
}

/// W9e①: 사용자가 maru 의 모달로 그 출처의 위치를 허용했다 — 어느 탭의 대신 허용 표에서도 뺀다(그 저장된 허용은 이제 사용자의 것이다).
fn forgetAutoOrigin(hash: u64) void {
    for (&slots) |*s| if (s.*) |*v| {
        if (v.removeHash(hash)) @import("emulation.zig").autoAllowedChanged(v.browser);
    };
}

/// W9e①: 이 탭에서 대신 허용한 출처(`emulation_state` 가 싣는다 — maru 가 sidecar 재시작 때 되돌리려고 기억한다).
pub fn autoAllowed(id: BrowserId, out: *[geo_slot.max_origins][]const u8) [][]const u8 {
    const slot = slotOf(id) orelse return out[0..0];
    return slot.originSlices(out);
}

/// W9e①: 에이전트 위치가 걸려 있는가.
pub fn agentActive(id: BrowserId) bool {
    const slot = slotOf(id) orelse return false;
    return slot.agent;
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
    for (&slots) |*s| if (s.*) |*v| if (v.browser == id) {
        // W9e①: 대신 허용한 위치 출처는 탭과 함께 기본으로 되돌린다(Chromium 이 출처에 저장했다).
        restoreAll(v);
        s.* = null;
    };
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
                // W9e①: 에이전트 위치가 걸린 탭(섞인 프롬프트를 사용자가 허용했다)에는 「없음」 을 걸지 않는다 — 에이전트 좌표를 지운다(E14).
                const maru_may = if (slotOf(value.browser)) |slot| slot.maruMay() else true;
                if (!entry.geo_set and maru_may) _ = applyOverride(value.browser, browser, null);
                evaluateGeolocationShim(browser);
            }
        }
        if (value.result == .accept and entry.kinds & geolocation_bit != 0 and entry.origin_hash != 0) forgetAutoOrigin(entry.origin_hash);
        const pending = dialogs.table.take(entry);
        const callback: [*c]c.cef_permission_prompt_callback_t = @ptrCast(@alignCast(pending.callback));
        callback.*.cont.?(callback, @backingInt(value.result));
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
