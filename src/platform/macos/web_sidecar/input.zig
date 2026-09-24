//! 입력 명령 수행(W4 — C5) — maru 가 라우팅을 마친 마우스·휠·키·IME·편집 명령을 CEF 호출로 옮긴다. CEF UI 스레드에서
//! 돈다(`dispatch.zig` 가 부른다).
//!
//! 닫히는 중이거나 없는 브라우저의 입력은 **조용히 버린다** — maru 는 파괴를 보낸 뒤에도 그 tick 의 입력을 보낼 수 있다
//! (정상 경합). 실패로 알리면 마우스 이동마다 실패가 쏟아진다.
//!
//! 페이지가 원하는 커서(`on_cursor_change`)와 IME 조합 사각형(`on_ime_composition_range_changed`)을 maru 로 보내는
//! 것도 여기다. 둘 다 브라우저마다 마지막 값을 기억해 같으면 다시 안 보낸다 — maru 도 브라우저마다 마지막 커서를 기억해야
//! 한다(포인터가 나갔다 다시 들어와도 같은 커서는 안 온다). 조합이 끝났다는 알림은 없다 — maru 는 자기가 조합을 보내는
//! 동안에만 사각형을 쓴다.

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const c = @import("cef.zig").c;
const object = @import("object.zig");
const library = @import("library.zig");
const browsers = @import("browsers.zig");
const registry_mod = @import("registry.zig");
const input_map = @import("input_map.zig");

const message = protocol.message;
const Message = message.Message;
const Modifiers = message.Modifiers;
const WebCursor = message.WebCursor;
const flags = input_map.flags;

// `input_map` 이 옮겨 적은 비트가 이 CEF 헤더의 값과 같다 — CEF 를 올려 바뀌면 빌드가 멈춘다.
comptime {
    const f = input_map.event_flag;
    std.debug.assert(f.caps_lock_on == c.EVENTFLAG_CAPS_LOCK_ON);
    std.debug.assert(f.shift_down == c.EVENTFLAG_SHIFT_DOWN);
    std.debug.assert(f.control_down == c.EVENTFLAG_CONTROL_DOWN);
    std.debug.assert(f.alt_down == c.EVENTFLAG_ALT_DOWN);
    std.debug.assert(f.left_mouse_button == c.EVENTFLAG_LEFT_MOUSE_BUTTON);
    std.debug.assert(f.middle_mouse_button == c.EVENTFLAG_MIDDLE_MOUSE_BUTTON);
    std.debug.assert(f.right_mouse_button == c.EVENTFLAG_RIGHT_MOUSE_BUTTON);
    std.debug.assert(f.command_down == c.EVENTFLAG_COMMAND_DOWN);
    std.debug.assert(f.is_repeat == c.EVENTFLAG_IS_REPEAT);
    std.debug.assert(f.precision_scrolling_delta == c.EVENTFLAG_PRECISION_SCROLLING_DELTA);
    std.debug.assert(f.is_key_pad == c.EVENTFLAG_IS_KEY_PAD);
    std.debug.assert(f.is_left == c.EVENTFLAG_IS_LEFT);
    std.debug.assert(f.is_right == c.EVENTFLAG_IS_RIGHT);
}

/// 입력 tag 면 수행하고 true.
pub fn handle(msg: Message) bool {
    switch (msg) {
        .mouse => |value| if (hostOf(value.browser)) |host| {
            defer object.release(host);
            mouse(host, value);
        },
        .wheel => |value| if (hostOf(value.browser)) |host| {
            defer object.release(host);
            var event = mouseEvent(value.point, value.modifiers);
            host.*.send_mouse_wheel_event.?(host, &event, value.delta_x, value.delta_y);
        },
        .key => |value| if (hostOf(value.browser)) |host| {
            defer object.release(host);
            var event = object.zeroed(c.cef_key_event_t);
            event.type = switch (value.kind) {
                .raw_down => c.KEYEVENT_RAWKEYDOWN,
                .down => c.KEYEVENT_KEYDOWN,
                .up => c.KEYEVENT_KEYUP,
                .char => c.KEYEVENT_CHAR,
            };
            event.modifiers = flags(value.modifiers);
            event.windows_key_code = value.windows_key_code;
            event.native_key_code = value.native_key_code;
            event.character = value.character;
            event.unmodified_character = value.unmodified_character;
            host.*.send_key_event.?(host, &event);
        },
        .ime_set_composition => |value| if (hostOf(value.browser)) |host| {
            defer object.release(host);
            var text = std.mem.zeroes(c.cef_string_t);
            library.setString(browsers.state.api, &text, value.text);
            defer browsers.state.api.string_utf16_clear(&text);
            // 조합 글 전체에 얇은 밑줄 하나 — 없으면 조합 중인 글이 확정된 글과 구별되지 않는다.
            var underline = object.zeroed(c.cef_composition_underline_t);
            underline.range = .{ .from = 0, .to = @intCast(text.length) };
            underline.color = 0xFF000000;
            underline.background_color = 0;
            const replacement = range(value.replacement);
            const selection = range(value.selection);
            host.*.ime_set_composition.?(host, &text, if (text.length > 0) 1 else 0, &underline, &replacement, &selection);
        },
        .ime_commit_text => |value| if (hostOf(value.browser)) |host| {
            defer object.release(host);
            var text = std.mem.zeroes(c.cef_string_t);
            library.setString(browsers.state.api, &text, value.text);
            defer browsers.state.api.string_utf16_clear(&text);
            const replacement = range(value.replacement);
            host.*.ime_commit_text.?(host, &text, &replacement, 0);
        },
        .ime_finish_composing => |value| if (hostOf(value.browser)) |host| {
            defer object.release(host);
            host.*.ime_finish_composing_text.?(host, @intFromBool(value.value));
        },
        .ime_cancel_composition => |browser| if (hostOf(browser)) |host| {
            defer object.release(host);
            host.*.ime_cancel_composition.?(host);
        },
        .capture_lost => |browser| if (hostOf(browser)) |host| {
            defer object.release(host);
            host.*.send_capture_lost_event.?(host);
        },
        .edit_command => |value| if (liveEntry(value.browser)) |entry| {
            const browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
            const frame = browser.*.get_focused_frame.?(browser) orelse browser.*.get_main_frame.?(browser);
            if (frame == null) return true;
            defer object.release(frame);
            switch (value.command) {
                .undo => frame.*.undo.?(frame),
                .redo => frame.*.redo.?(frame),
                .cut => frame.*.cut.?(frame),
                .copy => frame.*.copy.?(frame),
                .paste => frame.*.paste.?(frame),
                .paste_and_match_style => frame.*.paste_and_match_style.?(frame),
                .delete => frame.*.del.?(frame),
                .select_all => frame.*.select_all.?(frame),
            }
        },
        else => return false,
    }
    return true;
}

fn mouse(host: [*c]c.cef_browser_host_t, value: message.Mouse) void {
    var event = mouseEvent(value.point, value.modifiers);
    switch (value.kind) {
        .move => host.*.send_mouse_move_event.?(host, &event, 0),
        .leave => host.*.send_mouse_move_event.?(host, &event, 1),
        .down, .up => {
            const button: c.cef_mouse_button_type_t = switch (value.button) {
                .left => c.MBT_LEFT,
                .middle => c.MBT_MIDDLE,
                .right => c.MBT_RIGHT,
            };
            host.*.send_mouse_click_event.?(host, &event, button, @intFromBool(value.kind == .up), value.click_count);
        },
    }
}

fn mouseEvent(point: message.Point, modifiers: Modifiers) c.cef_mouse_event_t {
    return .{ .x = point.x, .y = point.y, .modifiers = flags(modifiers) };
}

fn range(value: message.TextRange) c.cef_range_t {
    return .{ .from = value.start, .to = value.end };
}

fn liveEntry(browser: message.BrowserId) ?*registry_mod.Entry {
    const entry = browsers.state.registry.byId(browser) orelse return null;
    if (entry.closing or browsers.state.shutting_down) return null;
    return entry;
}

fn hostOf(browser: message.BrowserId) ?[*c]c.cef_browser_host_t {
    const entry = liveEntry(browser) orelse return null;
    const cef_browser: [*c]c.cef_browser_t = @ptrCast(@alignCast(entry.handle));
    const host = cef_browser.*.get_host.?(cef_browser);
    return if (host == null) null else host;
}

/// CEF 커서 종류 → maru 가 보일 수 있는 것. 나머지(대각선 크기 조절·패닝·확대 등)는 화살표.
pub fn cursorOf(kind: c.cef_cursor_type_t) WebCursor {
    return switch (kind) {
        c.CT_HAND => .hand,
        c.CT_IBEAM => .ibeam,
        c.CT_VERTICALTEXT => .vertical_ibeam,
        c.CT_CROSS, c.CT_CELL => .crosshair,
        c.CT_EASTRESIZE, c.CT_WESTRESIZE, c.CT_EASTWESTRESIZE, c.CT_COLUMNRESIZE => .resize_ew,
        c.CT_NORTHRESIZE, c.CT_SOUTHRESIZE, c.CT_NORTHSOUTHRESIZE, c.CT_ROWRESIZE => .resize_ns,
        c.CT_GRAB, c.CT_MOVE => .grab,
        c.CT_GRABBING => .grabbing,
        c.CT_NOTALLOWED, c.CT_NODROP, c.CT_DND_NONE => .not_allowed,
        c.CT_COPY, c.CT_DND_COPY => .copy,
        c.CT_ALIAS, c.CT_DND_LINK => .alias,
        c.CT_CONTEXTMENU => .context_menu,
        c.CT_WAIT => .wait,
        c.CT_PROGRESS => .progress,
        c.CT_HELP => .help,
        c.CT_NONE => .none,
        else => .arrow,
    };
}

pub fn onCursorChange(_: [*c]c.cef_display_handler_t, browser: [*c]c.cef_browser_t, _: c.cef_cursor_handle_t, kind: c.cef_cursor_type_t, _: [*c]const c.cef_cursor_info_t) callconv(.c) c_int {
    defer object.releaseArg(browser);
    if (browser == null) return 1;
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return 1;
    const cursor = cursorOf(kind);
    // 같은 커서는 다시 안 보낸다 — 마우스가 움직일 때마다 온다.
    if (entry.cursor == cursor) return 1;
    entry.cursor = cursor;
    browsers.state.writer.send(.{ .cursor_changed = .{ .browser = entry.id, .cursor = cursor } }) catch {};
    // 처리했다 — sidecar 는 창이 없으니 CEF 가 NSCursor 를 건드릴 이유가 없다.
    return 1;
}

pub fn onImeCompositionRangeChanged(_: [*c]c.cef_render_handler_t, browser: [*c]c.cef_browser_t, _: [*c]const c.cef_range_t, count: usize, bounds: [*c]const c.cef_rect_t) callconv(.c) void {
    defer object.releaseArg(browser);
    if (browser == null or count == 0 or bounds == null) return;
    const entry = browsers.state.registry.byCefId(browser.*.get_identifier.?(browser)) orelse return;
    const union_rect = input_map.unionOf(c.cef_rect_t, bounds[0..@min(count, input_map.max_bounds)]) orelse return;
    // 같은 사각형은 다시 안 보낸다 — 조합 중 페이지가 입력칸을 매 프레임 움직여도 바뀐 것만 간다(적대 검증).
    if (entry.ime_bounds) |last| if (std.meta.eql(last, union_rect)) return;
    entry.ime_bounds = union_rect;
    browsers.state.writer.send(.{ .ime_range = .{ .browser = entry.id, .bounds = union_rect } }) catch {};
}
