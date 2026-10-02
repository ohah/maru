//! 우클릭 메뉴(W6c — D5)의 sidecar 쪽. CEF 의 기본 메뉴는 창 없는 모드에서 뜨지 않고(부모 view 가 없다) 항목도 적다(착수 전
//! 실측 — 링크·이미지 항목이 없다). 그래서 메뉴는 maru 가 macOS 메뉴로 띄우고, sidecar 는
//!
//! - 우클릭한 자리의 정보(링크·이미지·선택한 글·입력 칸·할 수 있는 편집·뒤로/앞으로)와 메뉴 번호를 `context_menu` 로 알리고,
//!   CEF 메뉴 콜백(`run_context_menu`)을 쥔다.
//! - maru 가 고른 것(`context_menu_command`)을 실행한다 — 뒤로~모두 선택은 그 콜백으로(초점이 있는 frame 에 간다 — 우클릭은 그
//!   자리에 초점을 준다, iframe 안 입력 칸도 그 iframe 에 갔다·기본 메뉴 모델에 없는 번호도 실행된다, 실측), 링크 주소·이미지 주소·이미지 복사는 sidecar 가 클립보드에 쓴다(주소는 maru 에 보내지 않는다 —
//!   `data:` 이미지 주소는 frame 상한보다 크고, 이미지 바이트도 그렇다).
//! - CEF 가 메뉴를 거두면(명령을 마쳤거나 페이지 이동·클릭·닫힘 — 실측) `context_menu_closed` 를 메뉴마다 한 번 알린다.
//!
//! 늦게 온 명령(번호가 지금 메뉴와 다르다)과 그 메뉴에서 할 수 없는 명령은 실행하지 않는다 — maru 의 메뉴가 그 자리에서 보인
//! 것만 하게(CEF 도 거둔 메뉴의 콜백은 무시한다 — 실측).

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const browsers = @import("browsers.zig");
const pasteboard = @import("pasteboard.zig");
const registry_mod = @import("registry.zig");

const message = protocol.message;
const Flags = message.ContextMenuFlags;
const Command = message.ContextMenuCommandKind;
const allocator = std.heap.c_allocator;

/// 주소를 담는 상한 — 이보다 긴 주소(거대한 `data:` 이미지)는 「주소 복사」를 내지 않는다. Chrome 은 상한 없이 복사하지만 메뉴를
/// 열 때마다 그만큼 쥐게 된다.
const max_address_bytes = 8 * 1024 * 1024;

/// 브라우저마다 쥔 메뉴 하나(`registry.Entry.context_menu` 가 불투명하게 든다).
const Held = struct {
    menu: u32,
    /// 아직 답하지 않은 CEF 메뉴 콜백(참조 하나를 쥔다). 답하면(`cont`·`cancel`) 놓고 null.
    callback: ?*c.cef_run_context_menu_callback_t,
    flags: Flags,
    link: ?[]u8 = null,
    image: ?[]u8 = null,
};

var image_callback: c.cef_download_image_callback_t = undefined;
/// 마지막 메뉴 번호(1 부터 — 0 은 없다). sidecar 전체에서 오른다 — 브라우저마다면 같은 id 로 다시 만든 브라우저의 첫 메뉴가 닫힌
/// 브라우저의 늦은 명령(같은 번호)을 받는다(W6c① 적대 검증).
var last_menu: u32 = 0;
/// 「이미지 복사」를 고른 때의 클립보드 변경 번호 — 받기를 마쳤을 때 바뀌었으면(그사이 사용자가 다른 것을 복사했다) 쓰지 않는다
/// (W6c① 적대 검증 — 받기는 비동기다).
var image_change_count: ?isize = null;

/// CEF 가 거둔 메뉴의 콜백 — 거두기 콜백(`on_context_menu_dismissed`)이 끝난 뒤 task 로 놓는다. 그 안에서 마지막 참조를 놓으면
/// host 가 죽었다(W6c① 판정 — SIGBUS, 메뉴가 떠 있는 채 이동. 변이로 가렸다: 그 안에서 `cancel` 만 하고 놓기를 미루면 17 판정
/// 모두 통과, 곧바로 놓으면 죽는다 — CEF 가 거두기를 부른 뒤 콜백 객체를 다시 쓴다). 거둔 메뉴에는 답할 필요도 없어 답하지 않는다.
var to_release: [registry_mod.capacity * 2]?*c.cef_run_context_menu_callback_t = @splat(null);
var release_task: c.cef_task_t = undefined;
var release_posted = false;

pub fn init() void {
    image_callback = object.zeroed(c.cef_download_image_callback_t);
    object.staticRefCounted(&image_callback.base);
    image_callback.on_download_image_finished = &onImageDownloaded;
    release_task = object.zeroed(c.cef_task_t);
    object.staticRefCounted(&release_task.base);
    release_task.execute = &releaseLater;
}

/// 거둔 메뉴의 콜백을 나중에 놓는다(답하지 않는다). 자리가 없으면(브라우저 수의 두 배가 모두 찼다 — 생기지 않는다) 놓지 않고
/// 둔다 — 새는 것이 죽는 것보다 낫다.
fn releaseAfterDismiss(callback: *c.cef_run_context_menu_callback_t) void {
    for (&to_release) |*slot| if (slot.* == null) {
        slot.* = callback;
        // 올리지 못하면(끝내는 중) 다음 거두기가 다시 올린다 — 굳어 버리지 않게.
        if (!release_posted) release_posted = browsers.state.api.post_task(c.TID_UI, &release_task) != 0;
        return;
    };
}

fn releaseLater(_: [*c]c.cef_task_t) callconv(.c) void {
    release_posted = false;
    for (&to_release) |*slot| if (slot.*) |callback| {
        slot.* = null;
        releaseCallback(callback);
    };
}

/// 판정자 전용(`MARU_WEB_TEST_PASTEBOARD`) — 이름이 있으면 사용자 클립보드 대신 그 이름의 클립보드에 쓴다.
fn boardName() ?[]const u8 {
    return if (std.c.getenv("MARU_WEB_TEST_PASTEBOARD")) |name| std.mem.span(name) else null;
}

fn heldOf(entry: *registry_mod.Entry) ?*Held {
    return @ptrCast(@alignCast(entry.context_menu orelse return null));
}

fn entryOf(browser: [*c]c.cef_browser_t) ?*registry_mod.Entry {
    if (browser == null) return null;
    return browsers.state.registry.byCefId(browser.*.get_identifier.?(browser));
}

/// 비어 있지 않은 CEF 문자열인가(놓는다).
fn hasText(value: c.cef_string_userfree_t) bool {
    if (value == null) return false;
    defer browsers.state.api.string_userfree_utf16_free(value);
    return value.*.str != null and value.*.length != 0;
}

/// CEF 문자열 전체를 UTF-8 로 복사한다(호출자 소유). 비었거나 `max` 를 넘으면 null.
fn copyAll(value: c.cef_string_userfree_t, max: usize) ?[]u8 {
    if (value == null) return null;
    defer browsers.state.api.string_userfree_utf16_free(value);
    if (value.*.str == null or value.*.length == 0) return null;
    var utf8 = std.mem.zeroes(c.cef_string_utf8_t);
    _ = browsers.state.api.string_utf16_to_utf8(value.*.str, value.*.length, &utf8);
    defer browsers.state.api.string_utf8_clear(&utf8);
    if (utf8.str == null or utf8.length == 0 or utf8.length > max) return null;
    return allocator.dupe(u8, utf8.str[0..utf8.length]) catch null;
}

/// 선택한 글을 대화상자 글 규칙으로 `out` 에 읽는다(넘치면 글자 경계에서 자르고 `truncated`).
fn readSelection(value: c.cef_string_userfree_t, out: []u8, truncated: *bool) []const u8 {
    truncated.* = false;
    if (value == null) return out[0..0];
    defer browsers.state.api.string_userfree_utf16_free(value);
    if (value.*.str == null) return out[0..0];
    var utf8 = std.mem.zeroes(c.cef_string_utf8_t);
    _ = browsers.state.api.string_utf16_to_utf8(value.*.str, value.*.length, &utf8);
    defer browsers.state.api.string_utf8_clear(&utf8);
    if (utf8.str == null) return out[0..0];
    const clamped = protocol.text.clampUtf8(utf8.str[0..utf8.length], out.len);
    truncated.* = clamped.len < utf8.length;
    @memcpy(out[0..clamped.len], clamped);
    protocol.text.replaceControlKeepLines(out[0..clamped.len]);
    return out[0..clamped.len];
}

fn enabled(model: [*c]c.cef_menu_model_t, id: c_int) bool {
    return model.*.get_index_of.?(model, id) >= 0 and model.*.is_enabled.?(model, id) != 0;
}

/// CEF 가 메뉴를 띄우려 한다 — maru 에 알리고 콜백을 쥔다(1 — 직접 띄운다).
pub fn onRun(
    _: [*c]c.cef_context_menu_handler_t,
    browser: [*c]c.cef_browser_t,
    frame: [*c]c.cef_frame_t,
    params: [*c]c.cef_context_menu_params_t,
    model: [*c]c.cef_menu_model_t,
    callback: [*c]c.cef_run_context_menu_callback_t,
) callconv(.c) c_int {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    defer object.releaseArg(params);
    defer object.releaseArg(model);
    const entry = entryOf(browser) orelse {
        callback.*.cancel.?(callback);
        object.release(callback);
        return 1;
    };
    // 앞 메뉴가 남았으면 취소로 끝낸다 — CEF 는 메뉴가 떠 있는 동안의 우클릭으로 새 메뉴를 만들지 않고 클릭·이동이 거두므로
    // (W6c① 판정) 생기지 않을 일이다. 방어로 짝을 맞춘다.
    finish(entry, .cancel);

    const type_flags: u32 = @bitCast(params.*.get_type_flags.?(params));
    const edit: u32 = @bitCast(params.*.get_edit_state_flags.?(params));
    // 링크 주소 복사는 거르기 전 주소다(헤더 — 「ONLY for copy link address」, Chrome 과 같다). 링크인지는 걸러진 주소로 본다.
    const link = if (type_flags & c.CM_TYPEFLAG_LINK != 0 and hasText(params.*.get_link_url.?(params)))
        copyAll(params.*.get_unfiltered_link_url.?(params), max_address_bytes)
    else
        null;
    const media_type = params.*.get_media_type.?(params);
    const is_image = media_type == c.CM_MEDIATYPE_IMAGE;
    const image = if (is_image) copyAll(params.*.get_source_url.?(params), max_address_bytes) else null;
    var selection_buf: [protocol.wire.max_text_bytes]u8 = undefined;
    var truncated = false;
    const selection = readSelection(params.*.get_selection_text.?(params), &selection_buf, &truncated);
    const flags: Flags = .{
        .link = link != null,
        .image = image != null,
        .media = media_type != c.CM_MEDIATYPE_NONE and image == null,
        .image_loaded = image != null and params.*.has_image_contents.?(params) != 0,
        .selection = selection.len != 0,
        .selection_truncated = selection.len != 0 and truncated,
        .editable = params.*.is_editable.?(params) != 0,
        .can_undo = edit & c.CM_EDITFLAG_CAN_UNDO != 0,
        .can_redo = edit & c.CM_EDITFLAG_CAN_REDO != 0,
        .can_cut = edit & c.CM_EDITFLAG_CAN_CUT != 0,
        .can_copy = edit & c.CM_EDITFLAG_CAN_COPY != 0,
        .can_paste = edit & c.CM_EDITFLAG_CAN_PASTE != 0,
        .can_select_all = edit & c.CM_EDITFLAG_CAN_SELECT_ALL != 0,
        .can_go_back = enabled(model, c.MENU_ID_BACK),
        .can_go_forward = enabled(model, c.MENU_ID_FORWARD),
    };
    const held = allocator.create(Held) catch {
        if (link) |v| allocator.free(v);
        if (image) |v| allocator.free(v);
        callback.*.cancel.?(callback);
        object.release(callback);
        return 1;
    };
    last_menu +%= 1;
    if (last_menu == 0) last_menu = 1;
    held.* = .{ .menu = last_menu, .callback = callback, .flags = flags, .link = link, .image = image };
    entry.context_menu = held;
    // 알리지 못하면(maru 가 사라졌다) 곧바로 취소로 끝낸다 — 쥔 채 두면 CEF 는 메뉴가 떠 있다고 보고 그 브라우저의 우클릭을 모두
    // 버린다(W6c① 적대 검증).
    browsers.state.writer.send(.{ .context_menu = .{
        .browser = entry.id,
        .menu = held.menu,
        .point = .{ .x = clampExtent(params.*.get_xcoord.?(params)), .y = clampExtent(params.*.get_ycoord.?(params)) },
        .flags = flags,
        .selection = selection,
    } }) catch finish(entry, .cancel);
    return 1;
}

fn clampExtent(value: c_int) i32 {
    return std.math.clamp(value, -message.max_pointer_extent, message.max_pointer_extent);
}

/// CEF 가 메뉴를 거뒀다(명령을 마쳤거나 페이지 이동·클릭·닫힘 — 실측). 그 콜백에는 답하지 않는다(`releaseAfterDismiss`).
pub fn onDismissed(_: [*c]c.cef_context_menu_handler_t, browser: [*c]c.cef_browser_t, frame: [*c]c.cef_frame_t) callconv(.c) void {
    defer object.releaseArg(browser);
    defer object.releaseArg(frame);
    const entry = entryOf(browser) orelse return;
    finish(entry, .dismissed);
}

const Ending = enum {
    /// CEF 가 거두지 않았다 — 취소로 답한다.
    cancel,
    /// CEF 가 이미 거뒀다 — 답하지 않고 나중에 놓는다.
    dismissed,
};

/// 쥔 메뉴를 끝내고 닫힘을 알린다(메뉴마다 한 번 — 쥔 것이 없으면 아무것도 안 한다).
pub fn finish(entry: *registry_mod.Entry, ending: Ending) void {
    const held = heldOf(entry) orelse return;
    entry.context_menu = null;
    end(held, ending);
    browsers.state.writer.send(.{ .context_menu_closed = .{ .browser = entry.id, .menu = held.menu } }) catch {};
    free(held);
}

/// 닫히는 브라우저 — 알릴 곳이 곧 사라지므로 닫힘은 보내지 않고 놓기만 한다(`browser_closed` 가 뒤따른다). CEF 는 닫기 전에 메뉴를
/// 거둔다(실측) — 여기 남은 것은 거두기가 오지 않은 경우뿐이라 답하지 않는다.
pub fn drop(entry: *registry_mod.Entry) void {
    const held = heldOf(entry) orelse return;
    entry.context_menu = null;
    end(held, .dismissed);
    free(held);
}

fn end(held: *Held, ending: Ending) void {
    const callback = held.callback orelse return;
    held.callback = null;
    switch (ending) {
        .cancel => {
            callback.*.cancel.?(callback);
            releaseCallback(callback);
        },
        .dismissed => releaseAfterDismiss(callback),
    }
}

fn free(held: *Held) void {
    if (held.link) |v| allocator.free(v);
    if (held.image) |v| allocator.free(v);
    allocator.destroy(held);
}

/// 고른 것으로 콜백에 답한다(CEF 명령이면 `cont`, 아니면 `cancel`). CEF 는 답 안에서 곧바로 메뉴를 거둔다(실측) — 그때는
/// `held.callback` 이 이미 null 이라 거두기가 다시 답하지 않고, `held` 는 거두기가 놓는다(이 뒤로 `held` 를 쓰지 않는다).
fn answer(held: *Held, id: ?c_int) void {
    const callback = held.callback orelse return;
    held.callback = null;
    if (id) |value| callback.*.cont.?(callback, value, 0) else callback.*.cancel.?(callback);
    releaseCallback(callback);
}

fn releaseCallback(callback: *c.cef_run_context_menu_callback_t) void {
    object.release(@as([*c]c.cef_run_context_menu_callback_t, callback));
}

fn cefId(command: Command) ?c_int {
    return switch (command) {
        .back => c.MENU_ID_BACK,
        .forward => c.MENU_ID_FORWARD,
        .reload => c.MENU_ID_RELOAD,
        .undo => c.MENU_ID_UNDO,
        .redo => c.MENU_ID_REDO,
        .cut => c.MENU_ID_CUT,
        .copy => c.MENU_ID_COPY,
        .paste => c.MENU_ID_PASTE,
        .paste_and_match_style => c.MENU_ID_PASTE_MATCH_STYLE,
        .select_all => c.MENU_ID_SELECT_ALL,
        .cancel, .copy_link_address, .copy_image_address, .copy_image => null,
    };
}

/// maru 가 고른 것. 지금 메뉴의 번호가 아니면(늦게 왔다) 아무것도 하지 않는다 — 그 메뉴는 이미 끝났다(닫힘을 알렸다).
pub fn onCommand(value: message.ContextMenuCommand) void {
    const entry = browsers.state.registry.byId(value.browser) orelse return;
    const held = heldOf(entry) orelse return;
    if (held.menu != value.menu or held.callback == null) return;
    const command = if (message.contextMenuAllows(held.flags, value.command)) value.command else .cancel;
    // 허용 규칙이 대상이 있음을 보장하지만 꺼내기는 확인하며 한다(ReleaseFast 에서 null 을 꺼내면 정의되지 않은 동작이다).
    switch (command) {
        .copy_link_address => if (held.link) |link| {
            _ = pasteboard.writeText(boardName(), link, true);
        },
        .copy_image_address => if (held.image) |image| {
            _ = pasteboard.writeText(boardName(), image, false);
        },
        .copy_image => if (held.image) |image| {
            image_change_count = pasteboard.changeCount(boardName());
            downloadImage(entry, image);
        },
        else => {},
    }
    // CEF 가 곧 거둔다(`on_context_menu_dismissed` — 실측: 답하면 바로 온다) — 닫힘은 그때 알린다.
    answer(held, cefId(command));
}

/// 이미지를 브라우저의 네트워크로 받는다(쿠키·캐시 그대로 — `download_image`). 받으면 PNG 로 클립보드에 쓴다.
fn downloadImage(entry: *registry_mod.Entry, url: []const u8) void {
    const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
    const host = browser.*.get_host.?(browser);
    if (host == null) return;
    defer object.release(host);
    var address = std.mem.zeroes(c.cef_string_t);
    @import("library.zig").setString(browsers.state.api, &address, url);
    defer browsers.state.api.string_utf16_clear(&address);
    host.*.download_image.?(host, &address, 0, 0, 0, &image_callback);
}

fn onImageDownloaded(_: [*c]c.cef_download_image_callback_t, _: [*c]const c.cef_string_t, status: c_int, image: [*c]c.cef_image_t) callconv(.c) void {
    if (image == null) return std.debug.print("maru-web-host: copy image: download failed (status {d})\n", .{status});
    defer object.releaseArg(image);
    var width: c_int = 0;
    var height: c_int = 0;
    const png = image.*.get_as_png.?(image, 1.0, 1, &width, &height);
    if (png == null) return std.debug.print("maru-web-host: copy image: no PNG representation\n", .{});
    defer object.release(png);
    const size = png.*.get_size.?(png);
    const bytes = allocator.alloc(u8, size) catch return;
    defer allocator.free(bytes);
    const read = png.*.get_data.?(png, bytes.ptr, size, 0);
    const expected = image_change_count orelse return;
    image_change_count = null;
    if (pasteboard.changeCount(boardName()) != expected) return; // 그사이 다른 것이 복사됐다
    if (!pasteboard.writePng(boardName(), bytes[0..read])) std.debug.print("maru-web-host: copy image: pasteboard refused\n", .{});
}
