//! 웹 OSR sidecar 제어 채널의 frame 조립·해체(W1a). 방향 확인은 받는 쪽 `stream.zig` 가 한다.

const std = @import("std");
const wire = @import("wire.zig");
const message_mod = @import("message.zig");
const fields = @import("fields.zig");

const Cursor = wire.Cursor;
const ReadCursor = wire.ReadCursor;
const Error = wire.Error;
const magic = wire.magic;
const version = wire.version;
const prefix_len = wire.prefix_len;
const common_len = wire.common_len;
const max_frame_bytes = wire.max_frame_bytes;
const max_url_bytes = wire.max_url_bytes;
const max_text_bytes = wire.max_text_bytes;
const max_ime_text_bytes = wire.max_ime_text_bytes;
const Message = message_mod.Message;
const Tag = message_mod.Tag;
const ViewSize = message_mod.ViewSize;
const RendererGoneReason = message_mod.RendererGoneReason;
const NavActionKind = message_mod.NavActionKind;
const FailureCode = message_mod.FailureCode;
const max_view_extent = fields.max_view_extent;
const writeBrowser = fields.writeBrowser;
const readBrowser = fields.readBrowser;
const writeSize = fields.writeSize;
const readSize = fields.readSize;
const readBool = fields.readBool;
const readHello = fields.readHello;
const writeUrl = fields.writeUrl;
const readUrl = fields.readUrl;
const writeText = fields.writeText;
const readText = fields.readText;
const writeService = fields.writeService;
const readService = fields.readService;
const writeModifiers = fields.writeModifiers;
const readModifiers = fields.readModifiers;
const writeExtent = fields.writeExtent;
const readExtent = fields.readExtent;
const writePoint = fields.writePoint;
const readPoint = fields.readPoint;
const writeRange = fields.writeRange;
const readRange = fields.readRange;
const writeImeText = fields.writeImeText;
const readImeText = fields.readImeText;
const writeRect = fields.writeRect;
const readRect = fields.readRect;
const writeDialogText = fields.writeDialogText;
const readDialogText = fields.readDialogText;
const writePath = fields.writePath;
const readPath = fields.readPath;
const writeRequest = fields.writeRequest;
const readRequest = fields.readRequest;
const writeOrigin = fields.writeOrigin;
const readOrigin = fields.readOrigin;
const JsDialogKind = message_mod.JsDialogKind;
const FileDialogMode = message_mod.FileDialogMode;
const MouseKind = message_mod.MouseKind;
const MouseButton = message_mod.MouseButton;
const KeyKind = message_mod.KeyKind;
const EditCommandKind = message_mod.EditCommandKind;
const WebCursor = message_mod.WebCursor;

/// Caller-owned output 에 frame 을 만든다. 성공 반환값만큼만 pipe 에 써야 한다.
pub fn encode(message: Message, out: []u8) Error!usize {
    var cursor = Cursor.init(out);
    try cursor.skip(prefix_len);
    try cursor.writeBytes(&magic);
    try cursor.writeU16(version);
    try cursor.writeByte(@intFromEnum(message));

    switch (message) {
        .hello, .hello_ack => |value| {
            try cursor.writeU64(value.instance);
            try cursor.writeU64(value.nonce);
        },
        .create_browser => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeSize(&cursor, value.size);
            try cursor.writeByte(@intFromBool(value.hidden));
            try writeUrl(&cursor, value.url);
        },
        .destroy_browser, .close_asking, .browser_created, .browser_closed => |browser| try writeBrowser(&cursor, browser),
        .resize => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeSize(&cursor, value.size);
        },
        .set_hidden, .set_focus => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromBool(value.value));
        },
        .navigate => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeUrl(&cursor, value.url);
        },
        .shutdown => {},
        .frame_channel => |value| {
            try writeService(&cursor, value.service);
            try cursor.writeBytes(&value.token);
        },
        .nav_action => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.action));
        },
        .mouse => |value| {
            if (!fields.validClickCount(value)) return error.InvalidClickCount;
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.kind));
            try cursor.writeByte(@intFromEnum(value.button));
            try writePoint(&cursor, value.point);
            try writeModifiers(&cursor, value.modifiers);
            try cursor.writeByte(value.click_count);
        },
        .wheel => |value| {
            try writeBrowser(&cursor, value.browser);
            try writePoint(&cursor, value.point);
            try writeExtent(&cursor, value.delta_x);
            try writeExtent(&cursor, value.delta_y);
            try writeModifiers(&cursor, value.modifiers);
        },
        .key => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.kind));
            try writeModifiers(&cursor, value.modifiers);
            try cursor.writeByte(value.windows_key_code);
            try cursor.writeByte(value.native_key_code);
            try cursor.writeU16(value.character);
            try cursor.writeU16(value.unmodified_character);
        },
        .ime_set_composition => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeRange(&cursor, value.selection, .selection);
            try writeRange(&cursor, value.replacement, .replacement);
            try writeImeText(&cursor, value.text);
        },
        .ime_commit_text => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeRange(&cursor, value.replacement, .replacement);
            try writeImeText(&cursor, value.text);
        },
        .ime_finish_composing => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromBool(value.value));
        },
        .ime_cancel_composition, .capture_lost => |browser| try writeBrowser(&cursor, browser),
        .edit_command => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.command));
        },
        .cursor_changed => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.cursor));
        },
        .ime_range => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeRect(&cursor, value.bounds);
        },
        .tooltip_changed => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeDialogText(&cursor, value.text);
        },
        .popup_changed => |value| {
            if (!popupConsistent(value)) return error.InvalidPopup;
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromBool(value.visible));
            try writeRect(&cursor, value.bounds);
            try cursor.writeU32(value.first_generation);
        },
        .dialog_reply => |value| {
            try writeRequest(&cursor, value.browser, value.request);
            try cursor.writeByte(@intFromBool(value.accept));
            try cursor.writeByte(@intFromBool(value.suppress));
            try writeDialogText(&cursor, value.text);
        },
        .file_dialog_path => |value| {
            try writeRequest(&cursor, value.browser, value.request);
            try writePath(&cursor, value.path);
        },
        .file_dialog_reply => |value| {
            try writeRequest(&cursor, value.browser, value.request);
            try cursor.writeByte(@intFromBool(value.accept));
        },
        .js_dialog => |value| {
            try writeRequest(&cursor, value.browser, value.request);
            try cursor.writeByte(@intFromEnum(value.kind));
            try cursor.writeByte(@intFromBool(value.offer_suppress));
            try writeOrigin(&cursor, value.origin);
            try writeDialogText(&cursor, value.message);
            try writeDialogText(&cursor, value.default_text);
        },
        .file_dialog => |value| {
            try writeRequest(&cursor, value.browser, value.request);
            try cursor.writeByte(@intFromEnum(value.mode));
            try writeDialogText(&cursor, value.title);
            try writeDialogText(&cursor, value.default_path);
            try writeDialogText(&cursor, value.accept);
        },
        .dialog_closed => |value| try writeRequest(&cursor, value.browser, value.request),
        .permission_request => |value| {
            try writeRequest(&cursor, value.browser, value.request);
            try fields.checkPermissions(value.kinds, value.media, value.remembered);
            try cursor.writeU32(value.kinds);
            try cursor.writeByte(value.media);
            try cursor.writeByte(@intFromBool(value.remembered));
            try writeOrigin(&cursor, value.origin);
        },
        .permission_reply => |value| {
            try writeRequest(&cursor, value.browser, value.request);
            try cursor.writeByte(@intFromEnum(value.result));
        },
        .web_notification => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.notification);
            if (value.origin.len == 0) return error.InvalidNotification;
            try writeOrigin(&cursor, value.origin);
            try writeDialogText(&cursor, value.title);
            try writeDialogText(&cursor, value.body);
        },
        .web_notification_click => |value| {
            try writeBrowser(&cursor, value.browser);
            if (value.notification == 0) return error.InvalidNotification;
            try cursor.writeU32(value.notification);
        },
        .datalist_show => |value| {
            try writeBrowser(&cursor, value.browser);
            if (value.list == 0) return error.InvalidDatalist;
            try cursor.writeU32(value.list);
            try writeRect(&cursor, value.field);
            try fields.checkDatalistItems(value.count, value.items);
            try cursor.writeU16(value.count);
            try cursor.writeU32(@intCast(value.items.len));
            try cursor.writeBytes(value.items);
        },
        .datalist_hide => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.list);
        },
        .datalist_pick => |value| {
            try writeBrowser(&cursor, value.browser);
            if (value.list == 0 or value.index >= message_mod.max_datalist_items) return error.InvalidDatalist;
            try cursor.writeU32(value.list);
            try cursor.writeU16(value.index);
        },
        .download_begin => |value| {
            try fields.checkDownloadBegin(value);
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.download);
            try writeDownloadText(&cursor, value.url);
            try writeDownloadText(&cursor, value.name);
            try writeDownloadText(&cursor, value.mime);
            try cursor.writeU64(@bitCast(value.total));
        },
        .download_update => |value| {
            try fields.checkDownloadUpdate(value);
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.download);
            try cursor.writeByte(@intFromEnum(value.state));
            try cursor.writeU64(@bitCast(value.received));
            try cursor.writeU64(@bitCast(value.total));
            try cursor.writeU16(value.reason);
        },
        .download_decide => |value| {
            try fields.checkDownloadDecide(value);
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.download);
            try writeDownloadText(&cursor, value.path);
        },
        .download_control => |value| {
            try writeBrowser(&cursor, value.browser);
            if (value.download == 0) return error.InvalidDownload;
            try cursor.writeU32(value.download);
            try cursor.writeByte(@intFromEnum(value.action));
        },
        .context_menu => |value| {
            try fields.checkContextMenu(value.menu, value.flags, value.selection);
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.menu);
            try writePoint(&cursor, value.point);
            try cursor.writeU32(@bitCast(value.flags));
            try writeDialogText(&cursor, value.selection);
        },
        .context_menu_closed => |value| {
            if (value.menu == 0) return error.InvalidContextMenu;
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.menu);
        },
        .context_menu_command => |value| {
            if (value.menu == 0) return error.InvalidContextMenu;
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.menu);
            try cursor.writeByte(@intFromEnum(value.command));
        },
        .drag_data => |value| {
            try writeBrowser(&cursor, value.browser);
            try fields.writeDragData(&cursor, value.kind, value.bytes);
        },
        .drag_target => |value| {
            try fields.checkDragTarget(value);
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.kind));
            try writePoint(&cursor, value.point);
            try writeModifiers(&cursor, value.modifiers);
            try cursor.writeU32(value.allowed);
            try cursor.writeU32(value.source);
        },
        .drag_source_end => |value| {
            try fields.checkDragSourceEnd(value);
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.drag);
            try writePoint(&cursor, value.point);
            try cursor.writeU32(value.operation);
        },
        .drag_out_data => |value| try fields.writeDragOutData(&cursor, value),
        .drag_out => |value| {
            try fields.checkDragOut(value);
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.drag);
            try cursor.writeU32(value.allowed);
            try writePoint(&cursor, value.point);
            try writePoint(&cursor, value.hotspot);
            try cursor.writeU32(value.image_width);
            try cursor.writeU32(value.image_height);
            try cursor.writeU32(value.file_size);
        },
        .popup_reserve => |value| try writeBrowser(&cursor, value.browser),
        .popup_created => |value| {
            if (value.opener == value.browser or value.placement == .new_window) return error.InvalidPopupAdopt;
            try writeBrowser(&cursor, value.opener);
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.placement));
            try writeUrl(&cursor, value.url);
        },
        .drag_file_request => |value| {
            if (value.drag == 0) return error.InvalidDrag;
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.drag);
        },
        .drag_file_ready => |value| {
            try fields.checkDragFileReady(value);
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.drag);
            try cursor.writeU32(value.size);
            try cursor.writeByte(@intFromBool(value.ok));
        },
        .drag_operation => |value| {
            try fields.checkDragOperation(value.operation);
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(value.operation);
        },
        .geolocation => |value| {
            try writeRequest(&cursor, value.browser, value.request);
            try fields.checkGeolocation(value);
            try cursor.writeByte(@intFromBool(value.available));
            try fields.writeF64(&cursor, value.latitude);
            try fields.writeF64(&cursor, value.longitude);
            try fields.writeF64(&cursor, value.accuracy);
        },
        .url_changed => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeUrl(&cursor, value.url);
        },
        .open_tab => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.placement));
            try writeUrl(&cursor, value.url);
        },
        .nav_state => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromBool(value.can_go_back));
            try cursor.writeByte(@intFromBool(value.can_go_forward));
            try cursor.writeByte(@intFromBool(value.loading));
        },
        .title_changed => |value| {
            try writeBrowser(&cursor, value.browser);
            try writeText(&cursor, value.text);
        },
        .load_finished => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeU32(@bitCast(value.http_status));
        },
        .renderer_gone => |value| {
            try writeBrowser(&cursor, value.browser);
            try cursor.writeByte(@intFromEnum(value.reason));
        },
        .failure => |value| {
            // 브라우저에 묶이지 않은 실패는 0 을 싣는다 — 여기만 0 을 허용한다.
            try cursor.writeU64(value.browser);
            try cursor.writeByte(@intFromEnum(value.code));
            try writeText(&cursor, value.detail);
        },
    }

    const frame_len = cursor.pos;
    if (frame_len > max_frame_bytes) return error.FrameTooLarge;
    std.mem.writeInt(u32, out[0..prefix_len], @intCast(frame_len - prefix_len), .big);
    return frame_len;
}

/// 완성된 frame 하나를 decode 한다. 반환 slice 는 입력 frame 을 빌리며 별도 allocation 이 없다.
/// 방향은 보지 않는다 — 받는 쪽은 `StreamingDecoder` 로 방향까지 확인한다.
pub fn decodeExact(frame: []const u8) Error!Message {
    if (frame.len < prefix_len) return error.IncompleteFrame;
    const payload_len = std.mem.readInt(u32, frame[0..prefix_len], .big);
    const total_len = std.math.add(usize, prefix_len, payload_len) catch return error.FrameTooLarge;
    if (total_len > max_frame_bytes) return error.FrameTooLarge;
    if (frame.len < total_len) return error.IncompleteFrame;
    if (frame.len != total_len) return error.TrailingBytes;

    var cursor = ReadCursor.init(frame[prefix_len..]);
    if (!std.mem.eql(u8, try cursor.readBytes(magic.len), &magic)) return error.InvalidMagic;
    if (try cursor.readU16() != version) return error.UnsupportedVersion;
    const tag = std.enums.fromInt(Tag, try cursor.readByte()) orelse return error.UnknownTag;

    const message: Message = switch (tag) {
        .hello => .{ .hello = try readHello(&cursor) },
        .hello_ack => .{ .hello_ack = try readHello(&cursor) },
        .create_browser => .{ .create_browser = .{
            .browser = try readBrowser(&cursor),
            .size = try readSize(&cursor),
            .hidden = try readBool(&cursor),
            .url = try readUrl(&cursor),
        } },
        .destroy_browser => .{ .destroy_browser = try readBrowser(&cursor) },
        .close_asking => .{ .close_asking = try readBrowser(&cursor) },
        .browser_created => .{ .browser_created = try readBrowser(&cursor) },
        .browser_closed => .{ .browser_closed = try readBrowser(&cursor) },
        .resize => .{ .resize = .{ .browser = try readBrowser(&cursor), .size = try readSize(&cursor) } },
        .set_hidden => .{ .set_hidden = .{ .browser = try readBrowser(&cursor), .value = try readBool(&cursor) } },
        .set_focus => .{ .set_focus = .{ .browser = try readBrowser(&cursor), .value = try readBool(&cursor) } },
        .navigate => .{ .navigate = .{ .browser = try readBrowser(&cursor), .url = try readUrl(&cursor) } },
        .shutdown => .shutdown,
        .frame_channel => blk: {
            const service = try readService(&cursor);
            var token: [16]u8 = undefined;
            @memcpy(&token, try cursor.readBytes(16));
            break :blk .{ .frame_channel = .{ .service = service, .token = token } };
        },
        .nav_action => .{ .nav_action = .{
            .browser = try readBrowser(&cursor),
            .action = std.enums.fromInt(NavActionKind, try cursor.readByte()) orelse return error.UnknownNavAction,
        } },
        .mouse => blk: {
            const mouse: message_mod.Mouse = .{
                .browser = try readBrowser(&cursor),
                .kind = std.enums.fromInt(MouseKind, try cursor.readByte()) orelse return error.UnknownMouseKind,
                .button = std.enums.fromInt(MouseButton, try cursor.readByte()) orelse return error.UnknownMouseButton,
                .point = try readPoint(&cursor),
                .modifiers = try readModifiers(&cursor),
                .click_count = try cursor.readByte(),
            };
            if (!fields.validClickCount(mouse)) return error.InvalidClickCount;
            break :blk .{ .mouse = mouse };
        },
        .wheel => .{ .wheel = .{
            .browser = try readBrowser(&cursor),
            .point = try readPoint(&cursor),
            .delta_x = try readExtent(&cursor),
            .delta_y = try readExtent(&cursor),
            .modifiers = try readModifiers(&cursor),
        } },
        .key => .{ .key = .{
            .browser = try readBrowser(&cursor),
            .kind = std.enums.fromInt(KeyKind, try cursor.readByte()) orelse return error.UnknownKeyKind,
            .modifiers = try readModifiers(&cursor),
            .windows_key_code = try cursor.readByte(),
            .native_key_code = try cursor.readByte(),
            .character = try cursor.readU16(),
            .unmodified_character = try cursor.readU16(),
        } },
        .ime_set_composition => .{ .ime_set_composition = .{
            .browser = try readBrowser(&cursor),
            .selection = try readRange(&cursor, .selection),
            .replacement = try readRange(&cursor, .replacement),
            .text = try readImeText(&cursor),
        } },
        .ime_commit_text => .{ .ime_commit_text = .{
            .browser = try readBrowser(&cursor),
            .replacement = try readRange(&cursor, .replacement),
            .text = try readImeText(&cursor),
        } },
        .ime_finish_composing => .{ .ime_finish_composing = .{ .browser = try readBrowser(&cursor), .value = try readBool(&cursor) } },
        .ime_cancel_composition => .{ .ime_cancel_composition = try readBrowser(&cursor) },
        .capture_lost => .{ .capture_lost = try readBrowser(&cursor) },
        .edit_command => .{ .edit_command = .{
            .browser = try readBrowser(&cursor),
            .command = std.enums.fromInt(EditCommandKind, try cursor.readByte()) orelse return error.UnknownEditCommand,
        } },
        .cursor_changed => .{ .cursor_changed = .{
            .browser = try readBrowser(&cursor),
            .cursor = std.enums.fromInt(WebCursor, try cursor.readByte()) orelse return error.UnknownCursor,
        } },
        .ime_range => .{ .ime_range = .{ .browser = try readBrowser(&cursor), .bounds = try readRect(&cursor) } },
        .tooltip_changed => .{ .tooltip_changed = .{ .browser = try readBrowser(&cursor), .text = try readDialogText(&cursor) } },
        .popup_changed => blk: {
            const value: message_mod.PopupChanged = .{ .browser = try readBrowser(&cursor), .visible = try readBool(&cursor), .bounds = try readRect(&cursor), .first_generation = try cursor.readU32() };
            if (!popupConsistent(value)) return error.InvalidPopup;
            break :blk .{ .popup_changed = value };
        },
        .dialog_reply => blk: {
            const request = try readRequest(&cursor);
            break :blk .{ .dialog_reply = .{
                .browser = request.browser,
                .request = request.request,
                .accept = try readBool(&cursor),
                .suppress = try readBool(&cursor),
                .text = try readDialogText(&cursor),
            } };
        },
        .file_dialog_path => blk: {
            const request = try readRequest(&cursor);
            break :blk .{ .file_dialog_path = .{ .browser = request.browser, .request = request.request, .path = try readPath(&cursor) } };
        },
        .file_dialog_reply => blk: {
            const request = try readRequest(&cursor);
            break :blk .{ .file_dialog_reply = .{ .browser = request.browser, .request = request.request, .accept = try readBool(&cursor) } };
        },
        .js_dialog => blk: {
            const request = try readRequest(&cursor);
            break :blk .{ .js_dialog = .{
                .browser = request.browser,
                .request = request.request,
                .kind = std.enums.fromInt(JsDialogKind, try cursor.readByte()) orelse return error.UnknownDialogKind,
                .offer_suppress = try readBool(&cursor),
                .origin = try readOrigin(&cursor),
                .message = try readDialogText(&cursor),
                .default_text = try readDialogText(&cursor),
            } };
        },
        .file_dialog => blk: {
            const request = try readRequest(&cursor);
            break :blk .{ .file_dialog = .{
                .browser = request.browser,
                .request = request.request,
                .mode = std.enums.fromInt(FileDialogMode, try cursor.readByte()) orelse return error.UnknownFileDialogMode,
                .title = try readDialogText(&cursor),
                .default_path = try readDialogText(&cursor),
                .accept = try readDialogText(&cursor),
            } };
        },
        .dialog_closed => .{ .dialog_closed = try readRequest(&cursor) },
        .permission_request => blk: {
            const request = try readRequest(&cursor);
            const kinds = try cursor.readU32();
            const media = try cursor.readByte();
            const remembered = try readBool(&cursor);
            try fields.checkPermissions(kinds, media, remembered);
            break :blk .{ .permission_request = .{
                .browser = request.browser,
                .request = request.request,
                .kinds = kinds,
                .media = media,
                .remembered = remembered,
                .origin = try readOrigin(&cursor),
            } };
        },
        .permission_reply => blk: {
            const request = try readRequest(&cursor);
            break :blk .{ .permission_reply = .{
                .browser = request.browser,
                .request = request.request,
                .result = std.enums.fromInt(message_mod.PermissionResult, try cursor.readByte()) orelse return error.UnknownPermissionResult,
            } };
        },
        .web_notification => blk: {
            const browser = try readBrowser(&cursor);
            const notification = try cursor.readU32();
            const origin = try readOrigin(&cursor);
            if (origin.len == 0) return error.InvalidNotification;
            break :blk .{ .web_notification = .{
                .browser = browser,
                .notification = notification,
                .origin = origin,
                .title = try readDialogText(&cursor),
                .body = try readDialogText(&cursor),
            } };
        },
        .datalist_show => blk: {
            const browser = try readBrowser(&cursor);
            const list = try cursor.readU32();
            if (list == 0) return error.InvalidDatalist;
            const field = try readRect(&cursor);
            const count = try cursor.readU16();
            const len = try cursor.readU32();
            if (len > message_mod.max_datalist_bytes) return error.InvalidDatalist;
            const items = try cursor.readBytes(len);
            try fields.checkDatalistItems(count, items);
            break :blk .{ .datalist_show = .{ .browser = browser, .list = list, .field = field, .count = count, .items = items } };
        },
        .datalist_hide => .{ .datalist_hide = .{ .browser = try readBrowser(&cursor), .list = try cursor.readU32() } },
        .datalist_pick => blk: {
            const browser = try readBrowser(&cursor);
            const list = try cursor.readU32();
            const index = try cursor.readU16();
            if (list == 0 or index >= message_mod.max_datalist_items) return error.InvalidDatalist;
            break :blk .{ .datalist_pick = .{ .browser = browser, .list = list, .index = index } };
        },
        .download_begin => blk: {
            const value: message_mod.DownloadBegin = .{
                .browser = try readBrowser(&cursor),
                .download = try cursor.readU32(),
                .url = try readDownloadText(&cursor, message_mod.max_download_url_bytes),
                .name = try readDownloadText(&cursor, message_mod.max_download_name_bytes),
                .mime = try readDownloadText(&cursor, message_mod.max_download_mime_bytes),
                .total = @bitCast(try cursor.readU64()),
            };
            try fields.checkDownloadBegin(value);
            break :blk .{ .download_begin = value };
        },
        .download_update => blk: {
            const value: message_mod.DownloadUpdate = .{
                .browser = try readBrowser(&cursor),
                .download = try cursor.readU32(),
                .state = std.enums.fromInt(message_mod.DownloadState, try cursor.readByte()) orelse return error.InvalidDownload,
                .received = @bitCast(try cursor.readU64()),
                .total = @bitCast(try cursor.readU64()),
                .reason = try cursor.readU16(),
            };
            try fields.checkDownloadUpdate(value);
            break :blk .{ .download_update = value };
        },
        .download_decide => blk: {
            const value: message_mod.DownloadDecide = .{
                .browser = try readBrowser(&cursor),
                .download = try cursor.readU32(),
                .path = try readDownloadText(&cursor, wire.max_text_bytes),
            };
            try fields.checkDownloadDecide(value);
            break :blk .{ .download_decide = value };
        },
        .download_control => blk: {
            const browser = try readBrowser(&cursor);
            const download = try cursor.readU32();
            const action = std.enums.fromInt(message_mod.DownloadAction, try cursor.readByte()) orelse return error.InvalidDownload;
            if (download == 0) return error.InvalidDownload;
            break :blk .{ .download_control = .{ .browser = browser, .download = download, .action = action } };
        },
        .web_notification_click => blk: {
            const browser = try readBrowser(&cursor);
            const notification = try cursor.readU32();
            if (notification == 0) return error.InvalidNotification;
            break :blk .{ .web_notification_click = .{ .browser = browser, .notification = notification } };
        },
        .context_menu => blk: {
            const browser = try readBrowser(&cursor);
            const menu = try cursor.readU32();
            const point = try readPoint(&cursor);
            const flags: message_mod.ContextMenuFlags = @bitCast(try cursor.readU32());
            const selection = try readDialogText(&cursor);
            try fields.checkContextMenu(menu, flags, selection);
            break :blk .{ .context_menu = .{ .browser = browser, .menu = menu, .point = point, .flags = flags, .selection = selection } };
        },
        .context_menu_closed => blk: {
            const browser = try readBrowser(&cursor);
            const menu = try cursor.readU32();
            if (menu == 0) return error.InvalidContextMenu;
            break :blk .{ .context_menu_closed = .{ .browser = browser, .menu = menu } };
        },
        .context_menu_command => blk: {
            const browser = try readBrowser(&cursor);
            const menu = try cursor.readU32();
            if (menu == 0) return error.InvalidContextMenu;
            break :blk .{ .context_menu_command = .{
                .browser = browser,
                .menu = menu,
                .command = std.enums.fromInt(message_mod.ContextMenuCommandKind, try cursor.readByte()) orelse return error.UnknownContextMenuCommand,
            } };
        },
        .drag_data => .{ .drag_data = try fields.readDragData(&cursor, try readBrowser(&cursor)) },
        .drag_target => blk: {
            const value: message_mod.DragTarget = .{
                .browser = try readBrowser(&cursor),
                .kind = std.enums.fromInt(message_mod.DragTargetKind, try cursor.readByte()) orelse return error.UnknownDragKind,
                .point = try readPoint(&cursor),
                .modifiers = try readModifiers(&cursor),
                .allowed = try cursor.readU32(),
                .source = try cursor.readU32(),
            };
            try fields.checkDragTarget(value);
            break :blk .{ .drag_target = value };
        },
        .drag_source_end => blk: {
            const value: message_mod.DragSourceEnd = .{
                .browser = try readBrowser(&cursor),
                .drag = try cursor.readU32(),
                .point = try readPoint(&cursor),
                .operation = try cursor.readU32(),
            };
            try fields.checkDragSourceEnd(value);
            break :blk .{ .drag_source_end = value };
        },
        .drag_out_data => .{ .drag_out_data = try fields.readDragOutData(&cursor) },
        .drag_out => blk: {
            const value: message_mod.DragOut = .{
                .browser = try readBrowser(&cursor),
                .drag = try cursor.readU32(),
                .allowed = try cursor.readU32(),
                .point = try readPoint(&cursor),
                .hotspot = try readPoint(&cursor),
                .image_width = try cursor.readU32(),
                .image_height = try cursor.readU32(),
                .file_size = try cursor.readU32(),
            };
            try fields.checkDragOut(value);
            break :blk .{ .drag_out = value };
        },
        .drag_file_request => blk: {
            const browser = try readBrowser(&cursor);
            const drag = try cursor.readU32();
            if (drag == 0) return error.InvalidDrag;
            break :blk .{ .drag_file_request = .{ .browser = browser, .drag = drag } };
        },
        .drag_file_ready => blk: {
            const value: message_mod.DragFileReady = .{ .browser = try readBrowser(&cursor), .drag = try cursor.readU32(), .size = try cursor.readU32(), .ok = try readBool(&cursor) };
            try fields.checkDragFileReady(value);
            break :blk .{ .drag_file_ready = value };
        },
        .drag_operation => blk: {
            const browser = try readBrowser(&cursor);
            const operation = try cursor.readU32();
            try fields.checkDragOperation(operation);
            break :blk .{ .drag_operation = .{ .browser = browser, .operation = operation } };
        },
        .geolocation => blk: {
            const request = try readRequest(&cursor);
            const value: message_mod.Geolocation = .{
                .browser = request.browser,
                .request = request.request,
                .available = try readBool(&cursor),
                .latitude = try fields.readF64(&cursor),
                .longitude = try fields.readF64(&cursor),
                .accuracy = try fields.readF64(&cursor),
            };
            try fields.checkGeolocation(value);
            break :blk .{ .geolocation = value };
        },
        .url_changed => .{ .url_changed = .{ .browser = try readBrowser(&cursor), .url = try readUrl(&cursor) } },
        .popup_reserve => .{ .popup_reserve = .{ .browser = try readBrowser(&cursor) } },
        .popup_created => blk: {
            const value: message_mod.PopupCreated = .{
                .opener = try readBrowser(&cursor),
                .browser = try readBrowser(&cursor),
                .placement = std.enums.fromInt(message_mod.NewTabPlacement, try cursor.readByte()) orelse return error.UnknownNewTabPlacement,
                .url = try readUrl(&cursor),
            };
            // 이어 받은 팝업은 연 탭 곁의 탭이다 — 새 창 자리는 메뉴의 「새 창에서 링크 열기」에만 있다(W6h①).
            if (value.opener == value.browser or value.placement == .new_window) return error.InvalidPopupAdopt;
            break :blk .{ .popup_created = value };
        },
        .open_tab => .{ .open_tab = .{
            .browser = try readBrowser(&cursor),
            .placement = std.enums.fromInt(message_mod.NewTabPlacement, try cursor.readByte()) orelse return error.UnknownNewTabPlacement,
            .url = try readUrl(&cursor),
        } },
        .nav_state => .{ .nav_state = .{
            .browser = try readBrowser(&cursor),
            .can_go_back = try readBool(&cursor),
            .can_go_forward = try readBool(&cursor),
            .loading = try readBool(&cursor),
        } },
        .title_changed => .{ .title_changed = .{ .browser = try readBrowser(&cursor), .text = try readText(&cursor) } },
        .load_finished => .{ .load_finished = .{
            .browser = try readBrowser(&cursor),
            .http_status = @bitCast(try cursor.readU32()),
        } },
        .renderer_gone => .{ .renderer_gone = .{
            .browser = try readBrowser(&cursor),
            .reason = std.enums.fromInt(RendererGoneReason, try cursor.readByte()) orelse return error.UnknownReason,
        } },
        .failure => .{ .failure = .{
            .browser = try cursor.readU64(),
            .code = std.enums.fromInt(FailureCode, try cursor.readByte()) orelse return error.UnknownFailureCode,
            .detail = try readText(&cursor),
        } },
    };
    if (cursor.pos != cursor.bytes.len) return error.TrailingBytes;
    return message;
}

/// 다운로드 글(W10a) — `[u32 길이][바이트]`, 모양 검사는 메시지 검사(`fields.checkDownload*`)가 한다. 길이만으로 거절할 수 있으면
/// 본문을 읽기 전에.
fn writeDownloadText(cursor: *wire.Cursor, text: []const u8) Error!void {
    try cursor.writeU32(@intCast(text.len));
    try cursor.writeBytes(text);
}

fn readDownloadText(cursor: *wire.ReadCursor, max: usize) Error![]const u8 {
    const len = try cursor.readU32();
    if (len > max) return error.InvalidDownload;
    return cursor.readBytes(len);
}

// 가장 큰 frame(create_browser + URL 상한)이 frame 상한 안에 든다 — 상수를 바꿔 이 둘이 어긋나면 컴파일이 멈춘다.
comptime {
    const largest = prefix_len + common_len + 8 + 12 + 1 + 4 + max_url_bytes;
    std.debug.assert(largest <= max_frame_bytes);
    std.debug.assert(prefix_len + common_len + 8 + 1 + 4 + max_text_bytes <= max_frame_bytes);
}

const test_size: ViewSize = .{ .width = 760, .height = 486, .scale = 2.0 };

/// 닫힌 팝업은 0 사각형·0 세대, 열린 팝업은 세대 1 이상·크기 0 아님(닫힌 필드).
fn popupConsistent(value: message_mod.PopupChanged) bool {
    if (value.visible) return value.first_generation != 0 and value.bounds.width != 0 and value.bounds.height != 0;
    return value.first_generation == 0 and std.meta.eql(value.bounds, message_mod.Rect{ .x = 0, .y = 0, .width = 0, .height = 0 });
}

fn roundTrip(message: Message) !Message {
    const State = struct {
        var buf: [max_frame_bytes]u8 = undefined;
    };
    const len = try encode(message, &State.buf);
    return decodeExact(State.buf[0..len]);
}

test "hello byte golden is big endian and round trips" {
    var encoded: [64]u8 = undefined;
    const len = try encode(.{ .hello = .{ .instance = 0x0102030405060708, .nonce = 0x1112131415161718 } }, &encoded);
    try std.testing.expectEqualSlices(u8, &.{
        0,  0,  0,  23, 'M', 'W', 'E', 'B', 0,  15, 0, // v15, tag hello
        1,  2,  3,  4,  5,   6,   7,   8,   17, 18, 19,
        20, 21, 22, 23, 24,
    }, encoded[0..len]);
    const decoded = try decodeExact(encoded[0..len]);
    try std.testing.expectEqual(@as(u64, 0x0102030405060708), decoded.hello.instance);
    try std.testing.expectEqual(@as(u64, 0x1112131415161718), decoded.hello.nonce);
}

test "create_browser byte golden lays out id, size, hidden and url in order" {
    var encoded: [128]u8 = undefined;
    const len = try encode(.{ .create_browser = .{ .browser = 7, .size = test_size, .hidden = true, .url = "about:blank" } }, &encoded);
    const body = encoded[prefix_len + common_len .. len];
    try std.testing.expectEqual(@as(u64, 7), std.mem.readInt(u64, body[0..8], .big));
    try std.testing.expectEqual(@as(u32, 760), std.mem.readInt(u32, body[8..12], .big));
    try std.testing.expectEqual(@as(u32, 486), std.mem.readInt(u32, body[12..16], .big));
    try std.testing.expectEqual(@as(u32, 0x40000000), std.mem.readInt(u32, body[16..20], .big)); // 2.0f
    try std.testing.expectEqual(@as(u8, 1), body[20]);
    try std.testing.expectEqual(@as(u32, 11), std.mem.readInt(u32, body[21..25], .big));
    try std.testing.expectEqualStrings("about:blank", body[25..]);
}

test "another version is recognised from the head alone, whatever its tag and body" {
    var encoded: [64]u8 = undefined;
    const len = try encode(.{ .hello_ack = .{ .instance = 0, .nonce = 0 } }, &encoded);
    // 머리의 버전만 다르다 — tag·본문을 보기 전에 버전으로 거절된다(`wire.version` 의 불변식).
    std.mem.writeInt(u16, encoded[prefix_len + magic.len ..][0..2], version + 1, .big);
    try std.testing.expectError(error.UnsupportedVersion, decodeExact(encoded[0..len]));
    // 다음 버전이 모르는 tag·다른 본문 길이를 써도 같다.
    encoded[prefix_len + magic.len + 2] = 0xff;
    try std.testing.expectError(error.UnsupportedVersion, decodeExact(encoded[0..len]));
    var longer: [80]u8 = undefined;
    @memcpy(longer[0..len], encoded[0..len]);
    @memset(longer[len..], 0);
    std.mem.writeInt(u32, longer[0..4], @intCast(longer.len - prefix_len), .big);
    try std.testing.expectError(error.UnsupportedVersion, decodeExact(&longer));
}

test "every message round trips" {
    const created = try roundTrip(.{ .create_browser = .{ .browser = 9, .size = test_size, .hidden = false, .url = "https://example.com/한글" } });
    try std.testing.expectEqual(@as(u64, 9), created.create_browser.browser);
    try std.testing.expectEqual(test_size, created.create_browser.size);
    try std.testing.expect(!created.create_browser.hidden);
    try std.testing.expectEqualStrings("https://example.com/한글", created.create_browser.url);

    try std.testing.expectEqual(@as(u64, 9), (try roundTrip(.{ .destroy_browser = 9 })).destroy_browser);
    try std.testing.expectEqual(@as(u64, 10), (try roundTrip(.{ .close_asking = 10 })).close_asking); // W6j
    const resized = try roundTrip(.{ .resize = .{ .browser = 9, .size = .{ .width = 1, .height = max_view_extent, .scale = 1.0 } } });
    try std.testing.expectEqual(max_view_extent, resized.resize.size.height);
    try std.testing.expect((try roundTrip(.{ .set_hidden = .{ .browser = 9, .value = true } })).set_hidden.value);
    try std.testing.expect(!(try roundTrip(.{ .set_focus = .{ .browser = 9, .value = false } })).set_focus.value);
    try std.testing.expectEqualStrings("file:///tmp/a.html", (try roundTrip(.{ .navigate = .{ .browser = 9, .url = "file:///tmp/a.html" } })).navigate.url);
    try std.testing.expectEqual(Tag.shutdown, std.meta.activeTag(try roundTrip(.shutdown)));

    try std.testing.expectEqual(@as(u64, 3), (try roundTrip(.{ .hello_ack = .{ .instance = 3, .nonce = 4 } })).hello_ack.instance);
    try std.testing.expectEqual(@as(u64, 9), (try roundTrip(.{ .browser_created = 9 })).browser_created);
    try std.testing.expectEqual(@as(u64, 9), (try roundTrip(.{ .browser_closed = 9 })).browser_closed);
    try std.testing.expectEqualStrings("", (try roundTrip(.{ .title_changed = .{ .browser = 9, .text = "" } })).title_changed.text);
    try std.testing.expectEqual(@as(i32, -1), (try roundTrip(.{ .load_finished = .{ .browser = 9, .http_status = -1 } })).load_finished.http_status);
    try std.testing.expectEqual(RendererGoneReason.out_of_memory, (try roundTrip(.{ .renderer_gone = .{ .browser = 9, .reason = .out_of_memory } })).renderer_gone.reason);
    try std.testing.expectEqual(NavActionKind.reload, (try roundTrip(.{ .nav_action = .{ .browser = 9, .action = .reload } })).nav_action.action);
    try std.testing.expectEqualStrings("https://a.example/x", (try roundTrip(.{ .url_changed = .{ .browser = 9, .url = "https://a.example/x" } })).url_changed.url);
    const nav = (try roundTrip(.{ .nav_state = .{ .browser = 9, .can_go_back = true, .can_go_forward = false, .loading = true } })).nav_state;
    try std.testing.expect(nav.can_go_back and !nav.can_go_forward and nav.loading);
    try std.testing.expectEqual(FailureCode.gpu_unavailable, (try roundTrip(.{ .failure = .{ .browser = 9, .code = .gpu_unavailable, .detail = "" } })).failure.code);
    const failure = try roundTrip(.{ .failure = .{ .browser = 0, .code = .profile_in_use, .detail = "프로필 사용 중" } });
    try std.testing.expectEqual(@as(u64, 0), failure.failure.browser);
    try std.testing.expectEqual(FailureCode.profile_in_use, failure.failure.code);
    try std.testing.expectEqualStrings("프로필 사용 중", failure.failure.detail);
}

test "decoder rejects malformed header, trailing bytes and truncation" {
    var encoded: [64]u8 = undefined;
    const len = try encode(.{ .hello = .{ .instance = 1, .nonce = 2 } }, &encoded);

    var bad = encoded;
    bad[4] = 'X';
    try std.testing.expectError(error.InvalidMagic, decodeExact(bad[0..len]));
    bad = encoded;
    std.mem.writeInt(u16, bad[8..10], version + 1, .big);
    try std.testing.expectError(error.UnsupportedVersion, decodeExact(bad[0..len]));
    bad = encoded;
    bad[10] = 62; // 정의되지 않은 tag(sidecar → maru 는 W10a 의 `download_update` 61 까지)
    try std.testing.expectError(error.UnknownTag, decodeExact(bad[0..len]));
    bad[10] = 131; // 둘째 구간(maru → sidecar)도 `download_control` 130 뒤는 비었다
    try std.testing.expectError(error.UnknownTag, decodeExact(bad[0..len]));
    try std.testing.expectError(error.IncompleteFrame, decodeExact(encoded[0 .. len - 1]));
    encoded[len] = 0;
    try std.testing.expectError(error.TrailingBytes, decodeExact(encoded[0 .. len + 1]));
}

test "closed fields fail closed on decode" {
    var buf: [128]u8 = undefined;
    const body = prefix_len + common_len;

    var len = try encode(.{ .set_hidden = .{ .browser = 1, .value = true } }, &buf);
    buf[body + 8] = 2;
    try std.testing.expectError(error.InvalidBool, decodeExact(buf[0..len]));

    len = try encode(.{ .destroy_browser = 1 }, &buf);
    std.mem.writeInt(u64, buf[body..][0..8], 0, .big);
    try std.testing.expectError(error.InvalidBrowserId, decodeExact(buf[0..len]));

    len = try encode(.{ .renderer_gone = .{ .browser = 1, .reason = .crashed } }, &buf);
    buf[body + 8] = 200;
    try std.testing.expectError(error.UnknownReason, decodeExact(buf[0..len]));

    len = try encode(.{ .failure = .{ .browser = 0, .code = .cef_initialize_failed, .detail = "" } }, &buf);
    buf[body + 8] = 200;
    try std.testing.expectError(error.UnknownFailureCode, decodeExact(buf[0..len]));

    len = try encode(.{ .title_changed = .{ .browser = 1, .text = "ab" } }, &buf);
    buf[len - 1] = 0xFF;
    try std.testing.expectError(error.InvalidUtf8, decodeExact(buf[0..len]));

    len = try encode(.{ .nav_action = .{ .browser = 1, .action = .stop } }, &buf);
    buf[body + 8] = 4;
    try std.testing.expectError(error.UnknownNavAction, decodeExact(buf[0..len]));

    len = try encode(.{ .nav_state = .{ .browser = 1, .can_go_back = false, .can_go_forward = false, .loading = false } }, &buf);
    for (0..3) |i| {
        var bad = buf;
        bad[body + 8 + i] = 2;
        try std.testing.expectError(error.InvalidBool, decodeExact(bad[0..len]));
    }

    // 주소 알림도 빈 URL·제어 문자를 거절한다(주소창에 그대로 그린다).
    try std.testing.expectError(error.EmptyUrl, encode(.{ .url_changed = .{ .browser = 1, .url = "" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .url_changed = .{ .browser = 1, .url = "https://x/\x1b[2J" } }, &buf));
}

test "view size bounds and NaN scale are rejected both ways" {
    var buf: [128]u8 = undefined;
    const bad_sizes = [_]ViewSize{
        .{ .width = 0, .height = 10, .scale = 1 },
        .{ .width = 10, .height = max_view_extent + 1, .scale = 1 },
        .{ .width = 10, .height = 10, .scale = 0.25 },
        .{ .width = 10, .height = 10, .scale = 9 },
        .{ .width = 10, .height = 10, .scale = std.math.nan(f32) },
    };
    for (bad_sizes) |size| {
        try std.testing.expectError(error.InvalidViewSize, encode(.{ .resize = .{ .browser = 1, .size = size } }, &buf));
    }
    const len = try encode(.{ .resize = .{ .browser = 1, .size = test_size } }, &buf);
    std.mem.writeInt(u32, buf[prefix_len + common_len + 16 ..][0..4], @bitCast(std.math.nan(f32)), .big);
    try std.testing.expectError(error.InvalidViewSize, decodeExact(buf[0..len]));
}

test "url and text caps reject cap plus one, empty url and zero browser on encode" {
    var buf: [max_frame_bytes + 64]u8 = undefined;
    const long_url = [_]u8{'a'} ** (max_url_bytes + 1);
    const long_text = [_]u8{'a'} ** (max_text_bytes + 1);
    try std.testing.expectError(error.UrlTooLarge, encode(.{ .navigate = .{ .browser = 1, .url = &long_url } }, &buf));
    try std.testing.expectError(error.EmptyUrl, encode(.{ .navigate = .{ .browser = 1, .url = "" } }, &buf));
    try std.testing.expectError(error.TextTooLarge, encode(.{ .title_changed = .{ .browser = 1, .text = &long_text } }, &buf));
    try std.testing.expectError(error.InvalidBrowserId, encode(.{ .browser_created = 0 }, &buf));
    // 상한 그대로는 들어간다.
    _ = try encode(.{ .create_browser = .{ .browser = 1, .size = test_size, .hidden = false, .url = long_url[0..max_url_bytes] } }, &buf);
    _ = try encode(.{ .title_changed = .{ .browser = 1, .text = long_text[0..max_text_bytes] } }, &buf);
}

/// encode 가 거절하는 모양(상한 +1·빈 URL·남는 바이트)은 encode 로 못 만든다 — 공격하는 쪽처럼 손으로 짓는다.
fn handFrame(out: []u8, tag: Tag, body: []const u8) []const u8 {
    std.mem.writeInt(u32, out[0..prefix_len], @intCast(common_len + body.len), .big);
    @memcpy(out[prefix_len..][0..magic.len], &magic);
    std.mem.writeInt(u16, out[prefix_len + magic.len ..][0..2], version, .big);
    out[prefix_len + magic.len + 2] = @intFromEnum(tag);
    @memcpy(out[prefix_len + common_len ..][0..body.len], body);
    return out[0 .. prefix_len + common_len + body.len];
}

test "decode rejects shapes encode refuses to build" {
    var frame: [max_frame_bytes]u8 = undefined;
    var body: [max_frame_bytes]u8 = undefined;
    std.mem.writeInt(u64, body[0..8], 1, .big);

    // 선언 길이 안에 필드보다 한 바이트가 더 있다(frame 바깥이 아니라 payload 안쪽).
    body[8] = 0xAA;
    try std.testing.expectError(error.TrailingBytes, decodeExact(handFrame(&frame, .destroy_browser, body[0..9])));

    // 길이 0 인 URL.
    std.mem.writeInt(u32, body[8..12], 0, .big);
    try std.testing.expectError(error.EmptyUrl, decodeExact(handFrame(&frame, .navigate, body[0..12])));

    // 글 상한 +1 — sidecar 가 `clampUtf8` 을 건너뛰고 보낸 제목.
    std.mem.writeInt(u32, body[8..12], max_text_bytes + 1, .big);
    @memset(body[12..][0 .. max_text_bytes + 1], 'a');
    try std.testing.expectError(error.TextTooLarge, decodeExact(handFrame(&frame, .title_changed, body[0 .. 12 + max_text_bytes + 1])));

    // URL 상한 +1 은 frame 상한 안에 들어가므로 URL 검사에서 걸려야 한다.
    std.mem.writeInt(u32, body[8..12], max_url_bytes + 1, .big);
    @memset(body[12..][0 .. max_url_bytes + 1], 'a');
    try std.testing.expectError(error.UrlTooLarge, decodeExact(handFrame(&frame, .navigate, body[0 .. 12 + max_url_bytes + 1])));
}

test "every single-byte corruption of a valid frame decodes or errors without crashing" {
    var encoded: [256]u8 = undefined;
    const len = try encode(.{ .create_browser = .{ .browser = 42, .size = test_size, .hidden = true, .url = "https://maru.dev/" } }, &encoded);
    var corrupted: [256]u8 = undefined;
    for (0..len) |i| {
        for ([_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFF }) |value| {
            @memcpy(corrupted[0..len], encoded[0..len]);
            corrupted[i] = value;
            if (decodeExact(corrupted[0..len])) |message| {
                // 풀렸다면 닫힌 필드는 여전히 유효해야 한다.
                if (message == .create_browser) try std.testing.expect(message.create_browser.browser != 0);
            } else |_| {}
        }
    }
}

test "url and text exactly at the cap decode, one byte of invalid UTF-8 or a control character does not" {
    var frame: [max_frame_bytes]u8 = undefined;
    var body: [max_frame_bytes]u8 = undefined;
    std.mem.writeInt(u64, body[0..8], 1, .big);

    std.mem.writeInt(u32, body[8..12], max_url_bytes, .big);
    @memset(body[12..][0..max_url_bytes], 'a');
    try std.testing.expectEqual(@as(usize, max_url_bytes), (try decodeExact(handFrame(&frame, .navigate, body[0 .. 12 + max_url_bytes]))).navigate.url.len);

    std.mem.writeInt(u32, body[8..12], max_text_bytes, .big);
    @memset(body[12..][0..max_text_bytes], 'a');
    try std.testing.expectEqual(@as(usize, max_text_bytes), (try decodeExact(handFrame(&frame, .title_changed, body[0 .. 12 + max_text_bytes]))).title_changed.text.len);

    std.mem.writeInt(u32, body[8..12], 2, .big);
    body[12] = 'a';
    body[13] = 0xFF;
    try std.testing.expectError(error.InvalidUtf8, decodeExact(handFrame(&frame, .navigate, body[0..14])));
    body[13] = 0x1b;
    try std.testing.expectError(error.ControlCharacter, decodeExact(handFrame(&frame, .navigate, body[0..14])));
    try std.testing.expectError(error.ControlCharacter, decodeExact(handFrame(&frame, .title_changed, body[0..14])));
    body[13] = 0x7f;
    try std.testing.expectError(error.ControlCharacter, decodeExact(handFrame(&frame, .title_changed, body[0..14])));
}

test "encode refuses invalid UTF-8 and control characters in url and text" {
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidUtf8, encode(.{ .navigate = .{ .browser = 1, .url = "a\xFF" } }, &buf));
    try std.testing.expectError(error.InvalidUtf8, encode(.{ .title_changed = .{ .browser = 1, .text = "a\xFF" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .navigate = .{ .browser = 1, .url = "http://x/\n" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .title_changed = .{ .browser = 1, .text = "\x1b]0;pwn\x07" } }, &buf));
}

test "view size edges: width at the cap and scale exactly 0.5 and 8.0 are accepted, just outside is not" {
    var buf: [128]u8 = undefined;
    for ([_]ViewSize{
        .{ .width = max_view_extent, .height = 1, .scale = 1 },
        .{ .width = 1, .height = 1, .scale = 0.5 },
        .{ .width = 1, .height = 1, .scale = 8.0 },
    }) |size| {
        const len = try encode(.{ .resize = .{ .browser = 1, .size = size } }, &buf);
        try std.testing.expectEqual(size, (try decodeExact(buf[0..len])).resize.size);
    }
    for ([_]ViewSize{
        .{ .width = max_view_extent + 1, .height = 1, .scale = 1 },
        .{ .width = 1, .height = 1, .scale = 0.49 },
        .{ .width = 1, .height = 1, .scale = 8.01 },
    }) |size| try std.testing.expectError(error.InvalidViewSize, encode(.{ .resize = .{ .browser = 1, .size = size } }, &buf));
}

test "a frame shorter than the length prefix is incomplete, not an out-of-bounds read" {
    try std.testing.expectError(error.IncompleteFrame, decodeExact(&[_]u8{ 0, 0, 0 }));
    try std.testing.expectError(error.IncompleteFrame, decodeExact(&[_]u8{}));
}

test "frame_channel carries the service name and the 128-bit token, and refuses odd names" {
    const token = [_]u8{ 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16 };
    const got = try roundTrip(.{ .frame_channel = .{ .service = "dev.maru.web.123.abcdef", .token = token } });
    try std.testing.expectEqualStrings("dev.maru.web.123.abcdef", got.frame_channel.service);
    try std.testing.expectEqualSlices(u8, &token, &got.frame_channel.token);

    var buf: [256]u8 = undefined;
    const long = [_]u8{'a'} ** 128;
    for ([_][]const u8{ "", "has space", "탭\t", &long }) |bad| {
        try std.testing.expectError(error.InvalidServiceName, encode(.{ .frame_channel = .{ .service = bad, .token = token } }, &buf));
    }
    // 손으로 지은 frame 의 이름에 제어 문자가 섞이면 decode 도 거절한다.
    var frame: [256]u8 = undefined;
    const body = [_]u8{ 3, 'a', 0x01, 'b' } ++ [_]u8{0} ** 16;
    try std.testing.expectError(error.InvalidServiceName, decodeExact(handFrame(&frame, .frame_channel, &body)));
}

// ── 입력(W4) ─────────────────────────────────────────────────────────────────────────────────────────────

comptime {
    // 가장 큰 입력 frame(IME 조합 + IME 글 상한)도 frame 상한 안에 든다.
    std.debug.assert(prefix_len + common_len + 8 + 8 + 8 + 4 + max_ime_text_bytes <= max_frame_bytes);
}

test "input messages round trip" {
    const drag: message_mod.Mouse = .{ .browser = 7, .kind = .move, .point = .{ .x = -40, .y = 900 }, .modifiers = .{ .left_button = true, .shift = true } };
    const moved = (try roundTrip(.{ .mouse = drag })).mouse;
    try std.testing.expectEqual(drag, moved);
    const click: message_mod.Mouse = .{ .browser = 7, .kind = .down, .button = .right, .point = .{ .x = 10, .y = 20 }, .click_count = 2 };
    try std.testing.expectEqual(click, (try roundTrip(.{ .mouse = click })).mouse);

    const wheel: message_mod.Wheel = .{ .browser = 7, .point = .{ .x = 1, .y = 2 }, .delta_x = -3, .delta_y = 120, .modifiers = .{ .precise_scroll = true } };
    try std.testing.expectEqual(wheel, (try roundTrip(.{ .wheel = wheel })).wheel);

    // Ctrl+E: 제어 문자와 원 글자를 함께 싣는다.
    const key: message_mod.Key = .{ .browser = 7, .kind = .raw_down, .modifiers = .{ .control = true }, .windows_key_code = 'E', .native_key_code = 14, .character = 0x05, .unmodified_character = 'e' };
    try std.testing.expectEqual(key, (try roundTrip(.{ .key = key })).key);

    const composing = (try roundTrip(.{ .ime_set_composition = .{ .browser = 7, .text = "안", .selection = .{ .start = 1, .end = 1 } } })).ime_set_composition;
    try std.testing.expectEqualStrings("안", composing.text);
    try std.testing.expectEqual(@as(u32, 1), composing.selection.end);
    try std.testing.expect(composing.replacement.isNone());
    const committed = (try roundTrip(.{ .ime_commit_text = .{ .browser = 7, .text = "", .replacement = .{ .start = 0, .end = 2 } } })).ime_commit_text;
    try std.testing.expectEqualStrings("", committed.text);
    try std.testing.expectEqual(@as(u32, 2), committed.replacement.end);
    try std.testing.expect((try roundTrip(.{ .ime_finish_composing = .{ .browser = 7, .value = true } })).ime_finish_composing.value);
    try std.testing.expectEqual(@as(u64, 7), (try roundTrip(.{ .ime_cancel_composition = 7 })).ime_cancel_composition);
    try std.testing.expectEqual(@as(u64, 7), (try roundTrip(.{ .capture_lost = 7 })).capture_lost);
    try std.testing.expectEqual(EditCommandKind.select_all, (try roundTrip(.{ .edit_command = .{ .browser = 7, .command = .select_all } })).edit_command.command);

    try std.testing.expectEqual(WebCursor.ibeam, (try roundTrip(.{ .cursor_changed = .{ .browser = 7, .cursor = .ibeam } })).cursor_changed.cursor);
    const range: message_mod.ImeRange = .{ .browser = 7, .bounds = .{ .x = -2, .y = 30, .width = 16, .height = 18 } };
    try std.testing.expectEqual(range, (try roundTrip(.{ .ime_range = range })).ime_range);
}

test "tooltip_changed round-trips multi-line and empty text, flows to maru, and refuses control characters" {
    var buf: [256]u8 = undefined;
    const multi = (try roundTrip(.{ .tooltip_changed = .{ .browser = 7, .text = "A tip\nsecond\tline" } })).tooltip_changed;
    try std.testing.expectEqual(@as(message_mod.BrowserId, 7), multi.browser);
    try std.testing.expectEqualStrings("A tip\nsecond\tline", multi.text);
    try std.testing.expectEqualStrings("", (try roundTrip(.{ .tooltip_changed = .{ .browser = 7, .text = "" } })).tooltip_changed.text);
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.tooltip_changed.direction());
    // sidecar 는 제어 문자를 공백으로 바꿔 보낸다(`readDialogString`) — 그래도 섞이면 encode 가 거절한다.
    try std.testing.expectError(error.ControlCharacter, encode(.{ .tooltip_changed = .{ .browser = 7, .text = "a\x1bb" } }, &buf));
}

test "drag messages round trip, flow the right way, and refuse empty pieces, bad paths, unused operation bits, a leave with a point and two accepted operations" {
    var buf: [256]u8 = undefined;
    const path = (try roundTrip(.{ .drag_data = .{ .browser = 7, .kind = .path, .bytes = "/Users/me/사진 1.png" } })).drag_data;
    try std.testing.expectEqual(message_mod.DragDataKind.path, path.kind);
    try std.testing.expectEqualStrings("/Users/me/사진 1.png", path.bytes);
    try std.testing.expectEqualStrings("첫\n둘\t셋", (try roundTrip(.{ .drag_data = .{ .browser = 7, .kind = .html, .bytes = "첫\n둘\t셋" } })).drag_data.bytes);
    try std.testing.expectEqualStrings("제목", (try roundTrip(.{ .drag_data = .{ .browser = 7, .kind = .url_title, .bytes = "제목" } })).drag_data.bytes);
    const enter: message_mod.DragTarget = .{ .browser = 7, .kind = .enter, .point = .{ .x = 40, .y = -2 }, .modifiers = .{ .alt = true }, .allowed = message_mod.drag_operation_mask };
    try std.testing.expectEqual(enter, (try roundTrip(.{ .drag_target = enter })).drag_target);
    try std.testing.expectEqual(@as(u32, 1), (try roundTrip(.{ .drag_operation = .{ .browser = 7, .operation = 1 } })).drag_operation.operation);
    try std.testing.expectEqual(@as(u32, 0), (try roundTrip(.{ .drag_operation = .{ .browser = 7, .operation = 0 } })).drag_operation.operation);
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.drag_data.direction());
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.drag_target.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.drag_operation.direction());

    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_data = .{ .browser = 7, .kind = .text, .bytes = "" } }, &buf));
    try std.testing.expectError(error.InvalidPath, encode(.{ .drag_data = .{ .browser = 7, .kind = .path, .bytes = "relative/a" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .drag_data = .{ .browser = 7, .kind = .path, .bytes = "/a\nb" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .drag_data = .{ .browser = 7, .kind = .text, .bytes = "a\x1bb" } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_target = .{ .browser = 7, .kind = .over, .allowed = 64 } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_target = .{ .browser = 7, .kind = .leave, .point = .{ .x = 1, .y = 0 } } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_target = .{ .browser = 7, .kind = .leave, .allowed = 1 } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_target = .{ .browser = 7, .kind = .drop, .allowed = 1 } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_operation = .{ .browser = 7, .operation = 1 | 16 } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_operation = .{ .browser = 7, .operation = 64 } }, &buf));
    // 조각 상한: 글은 IME 글 상한, 주소는 URL 상한.
    var big: [max_frame_bytes]u8 = undefined;
    const long = [_]u8{'a'} ** (max_ime_text_bytes + 1);
    _ = try encode(.{ .drag_data = .{ .browser = 7, .kind = .text, .bytes = long[0..max_ime_text_bytes] } }, &big);
    try std.testing.expectError(error.TextTooLarge, encode(.{ .drag_data = .{ .browser = 7, .kind = .text, .bytes = &long } }, &big));
    const long_url = ("https://a.b/" ++ [_]u8{'x'} ** (max_url_bytes - 12)).*;
    _ = try encode(.{ .drag_data = .{ .browser = 7, .kind = .url, .bytes = &long_url } }, &big);
    // decode 도 같은 규칙: 알 수 없는 종류 바이트.
    const len = try encode(.{ .drag_target = .{ .browser = 7, .kind = .over, .point = .{ .x = 1, .y = 1 }, .allowed = 1 } }, &buf);
    const body = len - (8 + 1 + 8 + 2 + 4 + 4);
    buf[body + 8] = 9;
    try std.testing.expectError(error.UnknownDragKind, decodeExact(buf[0..len]));
}

test "drag-out messages round trip, flow the right way, and refuse drag 0, unused bits, a source outside enter, an image hotspot without an image and two operations" {
    var buf: [256]u8 = undefined;
    const out: message_mod.DragOut = .{ .browser = 7, .drag = 3, .allowed = 1 | 16, .point = .{ .x = 40, .y = -2 }, .hotspot = .{ .x = 60, .y = 25 }, .image_width = 120, .image_height = 50 };
    try std.testing.expectEqual(out, (try roundTrip(.{ .drag_out = out })).drag_out);
    const piece = (try roundTrip(.{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .image_png, .bytes = "\x89PNG\r\n\x1a\n\x00" } })).drag_out_data;
    try std.testing.expectEqualStrings("\x89PNG\r\n\x1a\n\x00", piece.bytes); // 그림은 바이트 그대로(제어·NUL 포함)
    try std.testing.expectEqualStrings("첫\n둘", (try roundTrip(.{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .text, .bytes = "첫\n둘" } })).drag_out_data.bytes);
    // W6d③: 파일 이름은 대화상자 글 규칙(제어 문자 거절), 파일 내용은 바이트 그대로.
    try std.testing.expectEqualStrings("고양이.png", (try roundTrip(.{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .file_name, .bytes = "고양이.png" } })).drag_out_data.bytes);
    try std.testing.expectEqualStrings("\x00\x01\xff", (try roundTrip(.{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .file_contents, .bytes = "\x00\x01\xff" } })).drag_out_data.bytes);
    try std.testing.expectError(error.ControlCharacter, encode(.{ .drag_out_data = .{ .browser = 7, .drag = 3, .kind = .file_name, .bytes = "a\x1b.png" } }, &buf));
    // 파일 내용은 청할 때만 — 청하기와 끝, 크기 상한·실패면 0.
    try std.testing.expectEqual(@as(u32, 9), (try roundTrip(.{ .drag_file_request = .{ .browser = 7, .drag = 9 } })).drag_file_request.drag);
    const ready: message_mod.DragFileReady = .{ .browser = 7, .drag = 9, .size = 122, .ok = true };
    try std.testing.expectEqual(ready, (try roundTrip(.{ .drag_file_ready = ready })).drag_file_ready);
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.drag_file_request.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.drag_file_ready.direction());
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_file_request = .{ .browser = 7, .drag = 0 } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_file_ready = .{ .browser = 7, .drag = 9, .size = 3, .ok = false } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_file_ready = .{ .browser = 7, .drag = 9, .size = message_mod.max_drag_file_bytes + 1, .ok = true } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_out = .{ .browser = 7, .drag = 1, .allowed = 1, .point = .{ .x = 0, .y = 0 }, .file_size = message_mod.max_drag_file_bytes + 1 } }, &buf));
    const end: message_mod.DragSourceEnd = .{ .browser = 7, .drag = 3, .point = .{ .x = -1, .y = 900 }, .operation = 16 };
    try std.testing.expectEqual(end, (try roundTrip(.{ .drag_source_end = end })).drag_source_end);
    const enter: message_mod.DragTarget = .{ .browser = 7, .kind = .enter, .point = .{ .x = 1, .y = 2 }, .allowed = 1, .source = 3 };
    try std.testing.expectEqual(enter, (try roundTrip(.{ .drag_target = enter })).drag_target);
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.drag_out.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.drag_out_data.direction());
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.drag_source_end.direction());

    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_out = .{ .browser = 7, .drag = 0, .allowed = 1, .point = .{ .x = 0, .y = 0 } } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_out = .{ .browser = 7, .drag = 1, .allowed = 64, .point = .{ .x = 0, .y = 0 } } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_out = .{ .browser = 7, .drag = 1, .allowed = 1, .point = .{ .x = 0, .y = 0 }, .hotspot = .{ .x = 1, .y = 0 } } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_out = .{ .browser = 7, .drag = 1, .allowed = 1, .point = .{ .x = 0, .y = 0 }, .image_width = 4 } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_out_data = .{ .browser = 7, .drag = 0, .kind = .text, .bytes = "a" } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_out_data = .{ .browser = 7, .drag = 1, .kind = .image_png, .bytes = "" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .drag_out_data = .{ .browser = 7, .drag = 1, .kind = .text, .bytes = "a\x1b" } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_source_end = .{ .browser = 7, .drag = 0, .point = .{ .x = 0, .y = 0 }, .operation = 0 } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_source_end = .{ .browser = 7, .drag = 1, .point = .{ .x = 0, .y = 0 }, .operation = 3 } }, &buf));
    try std.testing.expectError(error.InvalidDrag, encode(.{ .drag_target = .{ .browser = 7, .kind = .over, .source = 3 } }, &buf));
    var big: [max_frame_bytes]u8 = undefined;
    const long = [_]u8{0} ** (max_ime_text_bytes + 1);
    _ = try encode(.{ .drag_out_data = .{ .browser = 7, .drag = 1, .kind = .image_png, .bytes = long[0..max_ime_text_bytes] } }, &big);
    try std.testing.expectError(error.TextTooLarge, encode(.{ .drag_out_data = .{ .browser = 7, .drag = 1, .kind = .image_png, .bytes = &long } }, &big));
}

test "context menu messages round trip, flow both ways, and refuse menu 0, reserved bits, unpaired bits and a selection flag that disagrees with the text" {
    const shown: message_mod.ContextMenu = .{ .browser = 7, .menu = 3, .point = .{ .x = 40, .y = -2 }, .flags = .{ .selection = true, .selection_truncated = true, .editable = true, .can_paste = true, .can_go_back = true }, .selection = "첫\n둘\t셋" };
    const back = (try roundTrip(.{ .context_menu = shown })).context_menu;
    try std.testing.expectEqual(shown.menu, back.menu);
    try std.testing.expectEqual(shown.point, back.point);
    try std.testing.expectEqual(shown.flags, back.flags);
    try std.testing.expectEqualStrings(shown.selection, back.selection);
    try std.testing.expectEqual(message_mod.ContextMenuCommandKind.paste_and_match_style, (try roundTrip(.{ .context_menu_command = .{ .browser = 7, .menu = 3, .command = .paste_and_match_style } })).context_menu_command.command);
    try std.testing.expectEqual(@as(u32, 3), (try roundTrip(.{ .context_menu_closed = .{ .browser = 7, .menu = 3 } })).context_menu_closed.menu);
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.context_menu.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.context_menu_closed.direction());
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.context_menu_command.direction());
    var buf: [256]u8 = undefined;
    var bad = shown;
    bad.menu = 0;
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu = bad }, &buf));
    bad = shown;
    bad.flags.link = false;
    bad.flags.link_openable = true;
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu = bad }, &buf));
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu = .{ .browser = 7, .menu = 1, .point = .{ .x = 0, .y = 0 }, .flags = .{ .image_loaded = true } } }, &buf));
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu = .{ .browser = 7, .menu = 1, .point = .{ .x = 0, .y = 0 }, .flags = .{ .selection_truncated = true } } }, &buf));
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu = .{ .browser = 7, .menu = 1, .point = .{ .x = 0, .y = 0 }, .flags = .{ .selection = true } } }, &buf));
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu = .{ .browser = 7, .menu = 1, .point = .{ .x = 0, .y = 0 }, .flags = .{}, .selection = "x" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .context_menu = .{ .browser = 7, .menu = 1, .point = .{ .x = 0, .y = 0 }, .flags = .{ .selection = true }, .selection = "a\x1bb" } }, &buf));
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu_closed = .{ .browser = 7, .menu = 0 } }, &buf));
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu_command = .{ .browser = 7, .menu = 0, .command = .cancel } }, &buf));
    // 손으로 만든 frame — 모르는 명령, 쓰지 않는 비트(디코더도 거절한다).
    const command_len = try encode(.{ .context_menu_command = .{ .browser = 7, .menu = 3, .command = .copy_image } }, &buf);
    buf[command_len - 1] = 21;
    try std.testing.expectError(error.UnknownContextMenuCommand, decodeExact(buf[0..command_len]));
    const menu_len = try encode(.{ .context_menu = .{ .browser = 7, .menu = 3, .point = .{ .x = 0, .y = 0 }, .flags = .{} } }, &buf);
    buf[menu_len - 6] = 0x80; // flags(u32, 빅엔디언) 15 번 `link_openable` 만 — 링크가 아닌데 열 수 있다(뒤는 글 길이 u32)
    try std.testing.expectError(error.InvalidContextMenu, decodeExact(buf[0..menu_len]));
    buf[menu_len - 6] = 0;
    buf[menu_len - 7] = 0x01; // 16 번 `image_openable` 만 — 이미지가 아닌데 열 수 있다(W6h①)
    try std.testing.expectError(error.InvalidContextMenu, decodeExact(buf[0..menu_len]));
    buf[menu_len - 7] = 0;
    buf[menu_len - 8] = 0x02; // 쓰지 않는 25 번(W6h② 가 17~24 번을 썼다)
    try std.testing.expectError(error.InvalidContextMenu, decodeExact(buf[0..menu_len]));
    buf[menu_len - 8] = 0;
    // W6h②: 미디어 표지 — 미디어가 아닌데 동영상, 동영상이자 오디오, 동영상·오디오 없이 연속 재생은 거절한다.
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu = .{ .browser = 7, .menu = 1, .point = .{ .x = 0, .y = 0 }, .flags = .{ .media_video = true } } }, &buf));
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu = .{ .browser = 7, .menu = 1, .point = .{ .x = 0, .y = 0 }, .flags = .{ .media = true, .media_video = true, .media_audio = true } } }, &buf));
    try std.testing.expectError(error.InvalidContextMenu, encode(.{ .context_menu = .{ .browser = 7, .menu = 1, .point = .{ .x = 0, .y = 0 }, .flags = .{ .media = true, .media_can_loop = true } } }, &buf));
    const media_menu = (try roundTrip(.{ .context_menu = .{ .browser = 7, .menu = 5, .point = .{ .x = 0, .y = 0 }, .flags = .{ .media = true, .media_audio = true, .media_loop = true, .media_can_loop = true, .media_controls = true, .media_openable = true, .media_copyable = true } } })).context_menu;
    try std.testing.expect(media_menu.flags.media_audio and media_menu.flags.media_loop and media_menu.flags.media_copyable and !media_menu.flags.media_video);
    try std.testing.expectEqual(message_mod.ContextMenuCommandKind.copy_media_address, (try roundTrip(.{ .context_menu_command = .{ .browser = 7, .menu = 5, .command = .copy_media_address } })).context_menu_command.command);
    _ = try decodeExact(buf[0..menu_len]);
    const image_menu = (try roundTrip(.{ .context_menu = .{ .browser = 7, .menu = 4, .point = .{ .x = 0, .y = 0 }, .flags = .{ .image = true, .image_openable = true } } })).context_menu;
    try std.testing.expect(image_menu.flags.image_openable);
    try std.testing.expectEqual(message_mod.ContextMenuCommandKind.open_image_new_tab, (try roundTrip(.{ .context_menu_command = .{ .browser = 7, .menu = 4, .command = .open_image_new_tab } })).context_menu_command.command);
}

test "open_tab round-trips with its placement, flows to maru, and refuses an empty url, a control character or an unknown placement" {
    const value: message_mod.OpenTab = .{ .browser = 7, .placement = .background, .url = "https://a.example/새?q=1" };
    const back = (try roundTrip(.{ .open_tab = value })).open_tab;
    try std.testing.expectEqual(value.browser, back.browser);
    try std.testing.expectEqual(value.placement, back.placement);
    try std.testing.expectEqualStrings(value.url, back.url);
    try std.testing.expectEqual(message_mod.NewTabPlacement.foreground, (try roundTrip(.{ .open_tab = .{ .browser = 7, .placement = .foreground, .url = "http://b/" } })).open_tab.placement);
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.open_tab.direction());
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.EmptyUrl, encode(.{ .open_tab = .{ .browser = 7, .placement = .foreground, .url = "" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .open_tab = .{ .browser = 7, .placement = .foreground, .url = "https://x/\x1b[2J" } }, &buf));
    const len = try encode(.{ .open_tab = .{ .browser = 7, .placement = .foreground, .url = "http://b/" } }, &buf);
    buf[prefix_len + common_len + 8] = 3; // browser 뒤 자리 바이트
    try std.testing.expectError(error.UnknownNewTabPlacement, decodeExact(buf[0..len]));
    try std.testing.expectEqual(message_mod.NewTabPlacement.new_window, (try roundTrip(.{ .open_tab = .{ .browser = 7, .placement = .new_window, .url = "http://b/" } })).open_tab.placement);
}

test "popup_reserve and popup_created round-trip, flow the right way, and refuse a zero id, a popup that is its own opener or an unknown placement" {
    try std.testing.expectEqual(@as(u64, 9), (try roundTrip(.{ .popup_reserve = .{ .browser = 9 } })).popup_reserve.browser);
    const created: message_mod.PopupCreated = .{ .opener = 3, .browser = 9, .placement = .background, .url = "https://a.example/login" };
    const back = (try roundTrip(.{ .popup_created = created })).popup_created;
    try std.testing.expectEqual(created.opener, back.opener);
    try std.testing.expectEqual(created.browser, back.browser);
    try std.testing.expectEqual(created.placement, back.placement);
    try std.testing.expectEqualStrings(created.url, back.url);
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.popup_reserve.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.popup_created.direction());
    var buf: [256]u8 = undefined;
    try std.testing.expectError(error.InvalidBrowserId, encode(.{ .popup_reserve = .{ .browser = 0 } }, &buf));
    try std.testing.expectError(error.InvalidPopupAdopt, encode(.{ .popup_created = .{ .opener = 9, .browser = 9, .placement = .foreground, .url = "about:blank" } }, &buf));
    try std.testing.expectError(error.EmptyUrl, encode(.{ .popup_created = .{ .opener = 3, .browser = 9, .placement = .foreground, .url = "" } }, &buf));
    try std.testing.expectError(error.InvalidPopupAdopt, encode(.{ .popup_created = .{ .opener = 3, .browser = 9, .placement = .new_window, .url = "about:blank" } }, &buf));
    var len = try encode(.{ .popup_created = .{ .opener = 3, .browser = 9, .placement = .foreground, .url = "about:blank" } }, &buf);
    buf[prefix_len + common_len + 16] = 3; // 두 번호 뒤 자리 바이트
    try std.testing.expectError(error.UnknownNewTabPlacement, decodeExact(buf[0..len]));
    buf[prefix_len + common_len + 16] = 2; // 새 창 자리 — 이어 받은 팝업은 새 창이 아니다(W6h①)
    try std.testing.expectError(error.InvalidPopupAdopt, decodeExact(buf[0..len]));
    // 손으로 만든 frame — 같은 번호.
    len = try encode(.{ .popup_created = .{ .opener = 3, .browser = 9, .placement = .foreground, .url = "about:blank" } }, &buf);
    std.mem.writeInt(u64, buf[prefix_len + common_len + 8 ..][0..8], 3, .big);
    try std.testing.expectError(error.InvalidPopupAdopt, decodeExact(buf[0..len]));
}

test "popup_changed round-trips, flows to maru, a hidden popup carries an all-zero rect and generation, a shown one a generation" {
    const shown: message_mod.PopupChanged = .{ .browser = 7, .visible = true, .bounds = .{ .x = 10, .y = 40, .width = 200, .height = 134 }, .first_generation = 3 };
    try std.testing.expectEqual(shown, (try roundTrip(.{ .popup_changed = shown })).popup_changed);
    const hidden: message_mod.PopupChanged = .{ .browser = 7, .visible = false };
    try std.testing.expectEqual(hidden, (try roundTrip(.{ .popup_changed = hidden })).popup_changed);
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.popup_changed.direction());

    // 닫힌 팝업에 사각형이 실리면 보내지도 받지도 않는다(닫힌 필드).
    var buf: [128]u8 = undefined;
    try std.testing.expectError(error.InvalidPopup, encode(.{ .popup_changed = .{ .browser = 7, .visible = false, .bounds = .{ .x = 0, .y = 0, .width = 1, .height = 0 } } }, &buf));
    try std.testing.expectError(error.InvalidPopup, encode(.{ .popup_changed = .{ .browser = 7, .visible = false, .first_generation = 1 } }, &buf));
    try std.testing.expectError(error.InvalidPopup, encode(.{ .popup_changed = .{ .browser = 7, .visible = true, .bounds = shown.bounds } }, &buf));
    try std.testing.expectError(error.InvalidPopup, encode(.{ .popup_changed = .{ .browser = 7, .visible = true, .bounds = .{ .x = 10, .y = 40, .width = 0, .height = 134 }, .first_generation = 1 } }, &buf));
    const len = try encode(.{ .popup_changed = shown }, &buf);
    // 보임 바이트(브라우저 8 바이트 뒤)를 0 으로 — 사각형은 그대로인 닫힌 팝업이 된다.
    buf[prefix_len + common_len + 8] = 0;
    try std.testing.expectError(error.InvalidPopup, decodeExact(buf[0..len]));
}

test "input directions: commands go to the sidecar, cursor and ime range come back" {
    inline for (.{ Tag.mouse, Tag.wheel, Tag.key, Tag.ime_set_composition, Tag.ime_commit_text, Tag.ime_finish_composing, Tag.ime_cancel_composition, Tag.edit_command, Tag.capture_lost }) |tag|
        try std.testing.expectEqual(message_mod.Direction.to_sidecar, tag.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.cursor_changed.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.ime_range.direction());
}

test "input closed fields fail closed both ways" {
    var buf: [256]u8 = undefined;
    const body = prefix_len + common_len;
    const extent = message_mod.max_pointer_extent;

    // 정의되지 않은 수식자 비트.
    var bad_modifiers: message_mod.Modifiers = .{};
    bad_modifiers._reserved = 1;
    try std.testing.expectError(error.InvalidModifiers, encode(.{ .wheel = .{ .browser = 1, .point = .{ .x = 0, .y = 0 }, .delta_x = 0, .delta_y = 0, .modifiers = bad_modifiers } }, &buf));
    var len = try encode(.{ .key = .{ .browser = 1, .kind = .up } }, &buf);
    buf[body + 8 + 1] = 0x80; // 수식자 u16 의 높은 바이트 — 예약 비트
    try std.testing.expectError(error.InvalidModifiers, decodeExact(buf[0..len]));

    // 좌표·스크롤 양 상한(절댓값) — 경계는 받고 하나 넘으면 거절.
    _ = try encode(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = -extent, .y = extent } } }, &buf);
    try std.testing.expectError(error.InvalidCoordinate, encode(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = extent + 1, .y = 0 } } }, &buf));
    try std.testing.expectError(error.InvalidCoordinate, encode(.{ .wheel = .{ .browser = 1, .point = .{ .x = 0, .y = 0 }, .delta_x = 0, .delta_y = -extent - 1 } }, &buf));
    len = try encode(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = 0, .y = 0 } } }, &buf);
    std.mem.writeInt(i32, buf[body + 10 ..][0..4], std.math.minInt(i32), .big); // @abs 넘침 없이 거절
    try std.testing.expectError(error.InvalidCoordinate, decodeExact(buf[0..len]));

    // 클릭 수: down·up 은 1 이상(네 번 이상도 — macOS clickCount 그대로), move·leave 는 0.
    try std.testing.expectError(error.InvalidClickCount, encode(.{ .mouse = .{ .browser = 1, .kind = .down, .point = .{ .x = 0, .y = 0 } } }, &buf));
    try std.testing.expectError(error.InvalidClickCount, encode(.{ .mouse = .{ .browser = 1, .kind = .leave, .point = .{ .x = 0, .y = 0 }, .click_count = 1 } }, &buf));
    _ = try encode(.{ .mouse = .{ .browser = 1, .kind = .down, .point = .{ .x = 0, .y = 0 }, .click_count = 4 } }, &buf);
    len = try encode(.{ .mouse = .{ .browser = 1, .kind = .up, .point = .{ .x = 0, .y = 0 }, .click_count = 3 } }, &buf);
    buf[len - 1] = 0;
    try std.testing.expectError(error.InvalidClickCount, decodeExact(buf[0..len]));
    len = try encode(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = 0, .y = 0 } } }, &buf);
    buf[len - 1] = 1;
    try std.testing.expectError(error.InvalidClickCount, decodeExact(buf[0..len]));

    // 닫힌 enum.
    len = try encode(.{ .mouse = .{ .browser = 1, .kind = .move, .point = .{ .x = 0, .y = 0 } } }, &buf);
    var bad = buf;
    bad[body + 8] = 4;
    try std.testing.expectError(error.UnknownMouseKind, decodeExact(bad[0..len]));
    bad = buf;
    bad[body + 9] = 3;
    try std.testing.expectError(error.UnknownMouseButton, decodeExact(bad[0..len]));
    len = try encode(.{ .key = .{ .browser = 1, .kind = .char } }, &buf);
    buf[body + 8] = 4;
    try std.testing.expectError(error.UnknownKeyKind, decodeExact(buf[0..len]));
    len = try encode(.{ .edit_command = .{ .browser = 1, .command = .undo } }, &buf);
    buf[body + 8] = 8;
    try std.testing.expectError(error.UnknownEditCommand, decodeExact(buf[0..len]));
    len = try encode(.{ .cursor_changed = .{ .browser = 1, .cursor = .arrow } }, &buf);
    buf[body + 8] = 17;
    try std.testing.expectError(error.UnknownCursor, decodeExact(buf[0..len]));

    // 범위: 거꾸로·상한 밖은 거절, 「없음」은 받는다.
    try std.testing.expectError(error.InvalidRange, encode(.{ .ime_commit_text = .{ .browser = 1, .text = "a", .replacement = .{ .start = 2, .end = 1 } } }, &buf));
    try std.testing.expectError(error.InvalidRange, encode(.{ .ime_set_composition = .{ .browser = 1, .text = "a", .selection = .{ .start = 0, .end = max_ime_text_bytes + 1 } } }, &buf));
    // 바꿀 범위는 입력칸 전체 글 안의 위치라 글 상한과 무관하다(5000 자 입력칸 끝) — 반쪽 「없음」은 거절.
    _ = try encode(.{ .ime_commit_text = .{ .browser = 1, .text = "a", .replacement = .{ .start = 5000, .end = 5000 } } }, &buf);
    _ = try encode(.{ .ime_set_composition = .{ .browser = 1, .text = "a", .replacement = .{ .start = 70_000, .end = 70_002 } } }, &buf);
    try std.testing.expectError(error.InvalidRange, encode(.{ .ime_commit_text = .{ .browser = 1, .text = "a", .replacement = .{ .start = 3, .end = std.math.maxInt(u32) } } }, &buf));
    len = try encode(.{ .ime_set_composition = .{ .browser = 1, .text = "a" } }, &buf);
    std.mem.writeInt(u32, buf[body + 8 ..][0..4], 5, .big); // 「없음」의 한쪽만 바꿔 start 5 > end maxInt 아님 → 상한 밖
    try std.testing.expectError(error.InvalidRange, decodeExact(buf[0..len]));

    // IME 글: 탭·줄바꿈(받아쓰기)은 받고 다른 제어 문자는 거절한다. 상한은 제목보다 크다.
    try std.testing.expectError(error.ControlCharacter, encode(.{ .ime_commit_text = .{ .browser = 1, .text = "a\x1b" } }, &buf));
    try std.testing.expectEqualStrings("줄\n바꿈\t탭\r", (try roundTrip(.{ .ime_commit_text = .{ .browser = 1, .text = "줄\n바꿈\t탭\r" } })).ime_commit_text.text);
    const long_ime = [_]u8{'a'} ** (max_ime_text_bytes + 1);
    _ = try roundTrip(.{ .ime_commit_text = .{ .browser = 1, .text = long_ime[0..max_ime_text_bytes] } });
    var big: [max_frame_bytes]u8 = undefined;
    try std.testing.expectError(error.TextTooLarge, encode(.{ .ime_commit_text = .{ .browser = 1, .text = &long_ime } }, &big));

    // 사각형 크기 상한.
    try std.testing.expectError(error.InvalidCoordinate, encode(.{ .ime_range = .{ .browser = 1, .bounds = .{ .x = 0, .y = 0, .width = @as(u32, @intCast(extent)) + 1, .height = 1 } } }, &buf));
}

test "every single-byte corruption of input frames decodes to valid fields or errors" {
    // 입력·대화상자 tag 모두(방향 둘) — 새 tag 를 더하면 여기에도 넣는다.
    const samples = [_]Message{
        .{ .mouse = .{ .browser = 3, .kind = .down, .button = .middle, .point = .{ .x = 5, .y = -6 }, .modifiers = .{ .command = true }, .click_count = 1 } },
        .{ .wheel = .{ .browser = 3, .point = .{ .x = 5, .y = 6 }, .delta_x = 7, .delta_y = -8 } },
        .{ .key = .{ .browser = 3, .kind = .char, .character = 'a', .unmodified_character = 'a' } },
        .{ .ime_set_composition = .{ .browser = 3, .text = "아", .selection = .{ .start = 0, .end = 1 } } },
        .{ .ime_commit_text = .{ .browser = 3, .text = "안\n", .replacement = .{ .start = 2, .end = 4 } } },
        .{ .ime_finish_composing = .{ .browser = 3, .value = true } },
        .{ .ime_cancel_composition = 3 },
        .{ .edit_command = .{ .browser = 3, .command = .paste } },
        .{ .capture_lost = 3 },
        .{ .cursor_changed = .{ .browser = 3, .cursor = .none } },
        .{ .ime_range = .{ .browser = 3, .bounds = .{ .x = 1, .y = 2, .width = 3, .height = 4 } } },
        // W5a 대화상자·파일 선택.
        .{ .js_dialog = .{ .browser = 3, .request = 2, .kind = .prompt, .origin = "https://a.b", .message = "줄\n둘", .default_text = "기본" } },
        .{ .file_dialog = .{ .browser = 3, .request = 2, .mode = .open_multiple, .title = "t", .default_path = "/a", .accept = ".png" } },
        .{ .dialog_closed = .{ .browser = 3, .request = 2 } },
        .{ .dialog_reply = .{ .browser = 3, .request = 2, .accept = true, .text = "답\t" } },
        .{ .file_dialog_path = .{ .browser = 3, .request = 2, .path = "/tmp/사진.png" } },
        .{ .file_dialog_reply = .{ .browser = 3, .request = 2, .accept = true } },
        // W5b 권한.
        .{ .permission_request = .{ .browser = 3, .request = 2, .origin = "https://a.b", .kinds = 0x8100 } },
        .{ .permission_request = .{ .browser = 3, .request = 2, .origin = "", .media = 0b11 } },
        .{ .permission_reply = .{ .browser = 3, .request = 2, .result = .dismiss } },
        // W5c 알림.
        .{ .web_notification = .{ .browser = 3, .notification = 2, .origin = "https://a.b", .title = "제목", .body = "본문\n둘" } },
        .{ .web_notification_click = .{ .browser = 3, .notification = 2 } },
        // W5b2 위치.
        .{ .permission_request = .{ .browser = 3, .request = 2, .origin = "", .kinds = 0x100, .remembered = true } },
        .{ .geolocation = .{ .browser = 3, .request = 2, .available = true, .latitude = 37.5, .longitude = 127, .accuracy = 30 } },
        // W6a 팝업.
        .{ .popup_changed = .{ .browser = 3, .visible = true, .bounds = .{ .x = 10, .y = 40, .width = 200, .height = 134 }, .first_generation = 2 } },
        .{ .popup_changed = .{ .browser = 3, .visible = false } },
        .{ .tooltip_changed = .{ .browser = 3, .text = "first line\nsecond line" } },
        .{ .tooltip_changed = .{ .browser = 3, .text = "" } },
        // W6c 우클릭 메뉴.
        .{ .context_menu = .{ .browser = 3, .menu = 2, .point = .{ .x = 5, .y = -6 }, .flags = .{ .link = true, .selection = true, .can_copy = true }, .selection = "글" } },
        .{ .context_menu = .{ .browser = 3, .menu = 2, .point = .{ .x = 5, .y = 6 }, .flags = .{ .image = true, .image_loaded = true } } },
        .{ .context_menu_closed = .{ .browser = 3, .menu = 2 } },
        .{ .context_menu_command = .{ .browser = 3, .menu = 2, .command = .copy_image } },
        // W6d① 끌어 놓기.
        .{ .drag_data = .{ .browser = 3, .kind = .path, .bytes = "/tmp/사진.png" } },
        .{ .drag_data = .{ .browser = 3, .kind = .text, .bytes = "줄\n둘" } },
        .{ .drag_data = .{ .browser = 3, .kind = .url, .bytes = "https://a.b/c" } },
        .{ .drag_target = .{ .browser = 3, .kind = .enter, .point = .{ .x = 5, .y = -6 }, .modifiers = .{ .left_button = true }, .allowed = 0b10111 } },
        .{ .drag_target = .{ .browser = 3, .kind = .leave } },
        .{ .drag_target = .{ .browser = 3, .kind = .drop, .point = .{ .x = 5, .y = 6 } } },
        .{ .drag_operation = .{ .browser = 3, .operation = 16 } },
        // W6d② 끌어내기.
        .{ .drag_target = .{ .browser = 3, .kind = .enter, .point = .{ .x = 5, .y = 6 }, .allowed = 1, .source = 4 } },
        .{ .drag_source_end = .{ .browser = 3, .drag = 4, .point = .{ .x = -5, .y = 6 }, .operation = 16 } },
        .{ .drag_out_data = .{ .browser = 3, .drag = 4, .kind = .text, .bytes = "끌기\n" } },
        .{ .drag_out_data = .{ .browser = 3, .drag = 4, .kind = .image_png, .bytes = "\x89PNG\x00\x01" } },
        .{ .drag_out_data = .{ .browser = 3, .drag = 4, .kind = .file_name, .bytes = "고양이.png" } },
        .{ .drag_out_data = .{ .browser = 3, .drag = 4, .kind = .file_contents, .bytes = "\x00\x89PNG\r\n" } },
        .{ .drag_out = .{ .browser = 3, .drag = 4, .allowed = 17, .point = .{ .x = 5, .y = 6 }, .hotspot = .{ .x = 2, .y = 3 }, .image_width = 10, .image_height = 8, .file_size = 122 } },
        // W6d③ 파일 내용 청하기.
        .{ .drag_file_request = .{ .browser = 3, .drag = 4 } },
        .{ .drag_file_ready = .{ .browser = 3, .drag = 4, .size = 122, .ok = true } },
        // W6e 새 탭.
        .{ .open_tab = .{ .browser = 3, .placement = .background, .url = "https://a.example/x" } },
        // W6f 팝업 이어 받기.
        .{ .popup_reserve = .{ .browser = 9 } },
        .{ .popup_created = .{ .opener = 3, .browser = 9, .placement = .foreground, .url = "about:blank" } },
        // W6m① 제안 목록.
        .{ .datalist_show = .{ .browser = 3, .list = 2, .field = .{ .x = 0, .y = 40, .width = 300, .height = 40 }, .count = 2, .items = "\x00\x05apple\x00\x00\x00\x06banana\x00\x0cyellow fruit" } },
        .{ .datalist_hide = .{ .browser = 3, .list = 2 } },
        .{ .datalist_hide = .{ .browser = 3, .list = 0 } },
        .{ .datalist_pick = .{ .browser = 3, .list = 2, .index = 1 } },
        // W10a 다운로드.
        .{ .download_begin = .{ .browser = 3, .download = 5, .url = "https://a.example/f.zip", .name = "보고서.zip", .mime = "application/zip", .total = 1234 } },
        .{ .download_begin = .{ .browser = 3, .download = 5, .url = "", .name = "x", .mime = "", .total = -1 } },
        .{ .download_update = .{ .browser = 3, .download = 5, .state = .interrupted, .received = 99, .total = -1, .reason = 38 } },
        .{ .download_decide = .{ .browser = 3, .download = 5, .path = "/Users/a/Downloads/f.zip.maru-part" } },
        .{ .download_decide = .{ .browser = 3, .download = 5, .path = "" } },
        .{ .download_control = .{ .browser = 3, .download = 5, .action = .resume_download } },
    };
    var encoded: [256]u8 = undefined;
    var corrupted: [256]u8 = undefined;
    for (samples) |sample| {
        const len = try encode(sample, &encoded);
        for (0..len) |i| for ([_]u8{ 0x00, 0x01, 0x7F, 0x80, 0xFF }) |value| {
            @memcpy(corrupted[0..len], encoded[0..len]);
            corrupted[i] = value;
            const message = decodeExact(corrupted[0..len]) catch continue;
            // 풀렸다면 다시 만들 수 있어야 한다 — encode 와 decode 가 같은 규칙을 지난다.
            var again: [256]u8 = undefined;
            _ = try encode(message, &again);
        };
    }
}

// ── 대화상자·파일 선택(W5a) ───────────────────────────────────────────────────────────────────────────────

test "dialog messages round trip — multi-line text, Korean, empty origin" {
    const asked = (try roundTrip(.{ .js_dialog = .{
        .browser = 7,
        .request = 3,
        .kind = .prompt,
        .origin = "https://example.com",
        .message = "첫 줄\n둘째 줄\t탭",
        .default_text = "기본값",
    } })).js_dialog;
    try std.testing.expectEqual(JsDialogKind.prompt, asked.kind);
    try std.testing.expectEqual(@as(u32, 3), asked.request);
    try std.testing.expectEqualStrings("https://example.com", asked.origin);
    try std.testing.expectEqualStrings("첫 줄\n둘째 줄\t탭", asked.message);
    try std.testing.expectEqualStrings("기본값", asked.default_text);
    const opaque_origin = (try roundTrip(.{ .js_dialog = .{ .browser = 7, .request = 1, .kind = .alert, .origin = "", .message = "" } })).js_dialog;
    try std.testing.expectEqualStrings("", opaque_origin.origin);

    const file = (try roundTrip(.{ .file_dialog = .{ .browser = 7, .request = 4, .mode = .open_multiple, .accept = "image/*,.png" } })).file_dialog;
    try std.testing.expectEqual(FileDialogMode.open_multiple, file.mode);
    try std.testing.expectEqualStrings("image/*,.png", file.accept);
    try std.testing.expectEqual(message_mod.Request{ .browser = 7, .request = 4 }, (try roundTrip(.{ .dialog_closed = .{ .browser = 7, .request = 4 } })).dialog_closed);

    const reply = (try roundTrip(.{ .dialog_reply = .{ .browser = 7, .request = 3, .accept = true, .text = "한글\n입력", .suppress = true } })).dialog_reply;
    try std.testing.expect(reply.accept and reply.suppress);
    try std.testing.expectEqualStrings("한글\n입력", reply.text);
    // (roundTrip 이 돌려준 글은 공용 버퍼를 빌린다 — 다음 roundTrip 전에 본다.)
    try std.testing.expect((try roundTrip(.{ .js_dialog = .{ .browser = 7, .request = 1, .kind = .alert, .origin = "", .message = "", .offer_suppress = true } })).js_dialog.offer_suppress);
    try std.testing.expectEqualStrings("/Users/me/사진 1.png", (try roundTrip(.{ .file_dialog_path = .{ .browser = 7, .request = 4, .path = "/Users/me/사진 1.png" } })).file_dialog_path.path);
    try std.testing.expect(!(try roundTrip(.{ .file_dialog_reply = .{ .browser = 7, .request = 4, .accept = false } })).file_dialog_reply.accept);
}

test "dialog directions: requests come to maru, answers go to the sidecar" {
    inline for (.{ Tag.dialog_reply, Tag.file_dialog_path, Tag.file_dialog_reply }) |tag|
        try std.testing.expectEqual(message_mod.Direction.to_sidecar, tag.direction());
    inline for (.{ Tag.js_dialog, Tag.file_dialog, Tag.dialog_closed }) |tag|
        try std.testing.expectEqual(message_mod.Direction.to_maru, tag.direction());
}

test "dialog closed fields fail closed both ways" {
    var buf: [256]u8 = undefined;
    const body = prefix_len + common_len;
    // 요청 번호 0.
    try std.testing.expectError(error.InvalidRequestId, encode(.{ .dialog_closed = .{ .browser = 1, .request = 0 } }, &buf));
    var len = try encode(.{ .dialog_closed = .{ .browser = 1, .request = 1 } }, &buf);
    std.mem.writeInt(u32, buf[body + 8 ..][0..4], 0, .big);
    try std.testing.expectError(error.InvalidRequestId, decodeExact(buf[0..len]));
    // 모르는 종류·방식.
    len = try encode(.{ .js_dialog = .{ .browser = 1, .request = 1, .kind = .alert, .origin = "", .message = "" } }, &buf);
    buf[body + 12] = 4;
    try std.testing.expectError(error.UnknownDialogKind, decodeExact(buf[0..len]));
    buf[body + 12] = 0;
    buf[body + 13] = 2; // offer_suppress 는 bool
    try std.testing.expectError(error.InvalidBool, decodeExact(buf[0..len]));
    len = try encode(.{ .file_dialog = .{ .browser = 1, .request = 1, .mode = .save } }, &buf);
    buf[body + 12] = 4;
    try std.testing.expectError(error.UnknownFileDialogMode, decodeExact(buf[0..len]));
    // 대화상자 글: 줄바꿈·탭은 받고 ESC·NUL·DEL 은 거절(페이지가 통제하는 글 — 주입).
    for ([_][]const u8{ "\x1b]0;pwn\x07", "a\x00b", "a\x7fb" }) |bad| {
        try std.testing.expectError(error.ControlCharacter, encode(.{ .js_dialog = .{ .browser = 1, .request = 1, .kind = .alert, .origin = "", .message = bad } }, &buf));
        try std.testing.expectError(error.ControlCharacter, encode(.{ .dialog_reply = .{ .browser = 1, .request = 1, .accept = true, .text = bad } }, &buf));
    }
    // 출처: `scheme://host[:port]` 만 — 경로·사용자 정보·불투명 출처·공백·제어 문자는 위장 자리다.
    for ([_][]const u8{ "https://x/\n", "https://a.b/path", "https://www.apple.com@evil.test", "maru", "data:text/html,hi", "https://a b", "HTTPS://a.b", "https://", "https://a.b:", "https://a.b:123456", "://a.b", "https://evil\u{202E}moc.elgoog", "https://apple.com\u{2044}login", "https://a\u{2028}b", "https://a\u{200B}b", "https://a\u{0085}b" }) |bad| {
        try std.testing.expectError(error.InvalidOrigin, encode(.{ .js_dialog = .{ .browser = 1, .request = 1, .kind = .alert, .origin = bad, .message = "" } }, &buf));
    }
    for ([_][]const u8{ "https://example.com", "http://127.0.0.1:8080", "http://[::1]:3000", "https://한국.kr", "chrome-extension://abc" }) |good| {
        _ = try encode(.{ .js_dialog = .{ .browser = 1, .request = 1, .kind = .alert, .origin = good, .message = "" } }, &buf);
    }
    // 경로: 절대 경로만, 제어 문자 없이.
    for ([_][]const u8{ "", "relative/a.png", "/a\nb" }) |bad| {
        const got = encode(.{ .file_dialog_path = .{ .browser = 1, .request = 1, .path = bad } }, &buf);
        try std.testing.expect(got == error.InvalidPath or got == error.ControlCharacter);
    }
    // 글 상한(4 KiB) — 경계는 받고 하나 넘으면 거절. 출처도 같은 상한이다(URL 상한 32 KiB 가 아니라).
    var big: [max_text_bytes + 1]u8 = undefined;
    @memset(&big, 'a');
    var large: [max_frame_bytes]u8 = undefined;
    _ = try encode(.{ .js_dialog = .{ .browser = 1, .request = 1, .kind = .alert, .origin = "", .message = big[0..max_text_bytes] } }, &large);
    try std.testing.expectError(error.TextTooLarge, encode(.{ .js_dialog = .{ .browser = 1, .request = 1, .kind = .alert, .origin = "", .message = &big } }, &large));
    var long_origin: [fields.max_origin_bytes + 1]u8 = undefined;
    @memset(&long_origin, 'a');
    @memcpy(long_origin[0..8], "https://");
    try std.testing.expectError(error.InvalidOrigin, encode(.{ .js_dialog = .{ .browser = 1, .request = 1, .kind = .alert, .origin = &long_origin, .message = "" } }, &large));
    _ = try encode(.{ .js_dialog = .{ .browser = 1, .request = 1, .kind = .alert, .origin = long_origin[0..fields.max_origin_bytes], .message = "" } }, &large);
}

// ── 권한(W5b) ────────────────────────────────────────────────────────────────────────────────────────────

test "permission messages round trip and go the right way" {
    const asked = (try roundTrip(.{ .permission_request = .{
        .browser = 7,
        .request = 3,
        .origin = "https://meet.example",
        .kinds = message_mod.PermissionKind.notifications.bit() | message_mod.PermissionKind.geolocation.bit(),
    } })).permission_request;
    try std.testing.expectEqual(@as(u32, 0x8100), asked.kinds);
    try std.testing.expectEqual(@as(u8, 0), asked.media);
    try std.testing.expectEqualStrings("https://meet.example", asked.origin);
    const media = (try roundTrip(.{ .permission_request = .{ .browser = 7, .request = 4, .origin = "", .media = message_mod.MediaPermission.camera.bit() | message_mod.MediaPermission.microphone.bit() } })).permission_request;
    try std.testing.expectEqual(@as(u8, 0b11), media.media);
    try std.testing.expectEqual(@as(u32, 0), media.kinds);
    inline for (.{ message_mod.PermissionResult.accept, .deny, .dismiss, .ignore }) |result| {
        try std.testing.expectEqual(result, (try roundTrip(.{ .permission_reply = .{ .browser = 7, .request = 3, .result = result } })).permission_reply.result);
    }
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.permission_request.direction());
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.permission_reply.direction());
}

test "permission fields fail closed both ways" {
    var buf: [512]u8 = undefined;
    const body = prefix_len + common_len;
    // 정의되지 않은 비트·둘 다 빈 요청·둘 다 찬 요청.
    for ([_][2]u32{ .{ 1 << 29, 0 }, .{ 1 << 31, 0 }, .{ 0, 0b1_0000 }, .{ 0, 0 }, .{ 1, 1 } }) |bad| {
        try std.testing.expectError(error.InvalidPermissions, encode(.{ .permission_request = .{ .browser = 1, .request = 1, .origin = "", .kinds = bad[0], .media = @intCast(bad[1]) } }, &buf));
    }
    var len = try encode(.{ .permission_request = .{ .browser = 1, .request = 1, .origin = "", .kinds = 1 } }, &buf);
    // kinds 의 윗 비트를 켜면 거절.
    buf[body + 12] = 0x20;
    try std.testing.expectError(error.InvalidPermissions, decodeExact(buf[0..len]));
    buf[body + 12] = 0;
    // media 도 싣으면(둘 다) 거절.
    buf[body + 16] = 1;
    try std.testing.expectError(error.InvalidPermissions, decodeExact(buf[0..len]));
    buf[body + 16] = 0;
    // 기억된 허용 표시는 위치만 청한 요청에만(W5b2) — 다른 종류에 붙이면 거절.
    buf[body + 17] = 1;
    try std.testing.expectError(error.InvalidPermissions, decodeExact(buf[0..len]));
    buf[body + 17] = 0;
    try std.testing.expectError(error.InvalidPermissions, encode(.{ .permission_request = .{ .browser = 1, .request = 1, .origin = "", .kinds = 0x8100, .remembered = true } }, &buf));
    try std.testing.expectError(error.InvalidPermissions, encode(.{ .permission_request = .{ .browser = 1, .request = 1, .origin = "", .media = 2, .remembered = true } }, &buf));
    // 출처는 대화상자와 같은 규칙.
    try std.testing.expectError(error.InvalidOrigin, encode(.{ .permission_request = .{ .browser = 1, .request = 1, .origin = "https://apple.com@evil.test", .kinds = 1 } }, &buf));
    // 요청 번호 0·모르는 답.
    try std.testing.expectError(error.InvalidRequestId, encode(.{ .permission_reply = .{ .browser = 1, .request = 0, .result = .accept } }, &buf));
    len = try encode(.{ .permission_reply = .{ .browser = 1, .request = 1, .result = .deny } }, &buf);
    buf[body + 12] = 4;
    try std.testing.expectError(error.UnknownPermissionResult, decodeExact(buf[0..len]));
}

// ── 웹 알림(W5c) ──────────────────────────────────────────────────────────────────────────────────────────

test "web notifications round trip, go the right way, and fail closed" {
    const shown = (try roundTrip(.{ .web_notification = .{ .browser = 7, .notification = 3, .origin = "https://chat.example", .title = "새 메시지", .body = "안녕\n하세요" } })).web_notification;
    try std.testing.expectEqual(@as(u32, 3), shown.notification);
    try std.testing.expectEqualStrings("https://chat.example", shown.origin);
    try std.testing.expectEqualStrings("새 메시지", shown.title);
    try std.testing.expectEqualStrings("안녕\n하세요", shown.body);
    try std.testing.expectEqual(@as(u32, 3), (try roundTrip(.{ .web_notification_click = .{ .browser = 7, .notification = 3 } })).web_notification_click.notification);
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.web_notification.direction());
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.web_notification_click.direction());
    var buf: [512]u8 = undefined;
    // 출처 없는 알림·위장 출처·제어 문자·누를 수 없는 번호로 누르기는 거절.
    try std.testing.expectError(error.InvalidNotification, encode(.{ .web_notification = .{ .browser = 1, .notification = 1, .origin = "", .title = "t" } }, &buf));
    try std.testing.expectError(error.InvalidOrigin, encode(.{ .web_notification = .{ .browser = 1, .notification = 1, .origin = "https://apple.com@evil.test", .title = "t" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .web_notification = .{ .browser = 1, .notification = 1, .origin = "https://a.b", .title = "\x1b]0;x\x07" } }, &buf));
    try std.testing.expectError(error.InvalidNotification, encode(.{ .web_notification_click = .{ .browser = 1, .notification = 0 } }, &buf));
    const len = try encode(.{ .web_notification_click = .{ .browser = 1, .notification = 5 } }, &buf);
    std.mem.writeInt(u32, buf[len - 4 ..][0..4], 0, .big);
    try std.testing.expectError(error.InvalidNotification, decodeExact(buf[0..len]));
}

// ── 위치(W5b2) ────────────────────────────────────────────────────────────────────────────────────────────

test "geolocation round trips and its numbers fail closed" {
    const remembered = (try roundTrip(.{ .permission_request = .{ .browser = 7, .request = 3, .origin = "https://maps.example", .kinds = message_mod.PermissionKind.geolocation.bit(), .remembered = true } })).permission_request;
    try std.testing.expect(remembered.remembered);
    const at = (try roundTrip(.{ .geolocation = .{ .browser = 7, .request = 3, .available = true, .latitude = -33.8688, .longitude = 151.2093, .accuracy = 12.5 } })).geolocation;
    try std.testing.expect(at.available and at.latitude == -33.8688 and at.longitude == 151.2093 and at.accuracy == 12.5);
    try std.testing.expect(!(try roundTrip(.{ .geolocation = .{ .browser = 7, .request = 3, .available = false } })).geolocation.available);
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.geolocation.direction());
    var buf: [256]u8 = undefined;
    const nan = std.math.nan(f64);
    const inf = std.math.inf(f64);
    for ([_][3]f64{ .{ 91, 0, 10 }, .{ -90.5, 0, 10 }, .{ 0, 180.1, 10 }, .{ 0, -181, 10 }, .{ 0, 0, 0 }, .{ 0, 0, -1 }, .{ 0, 0, 2e7 }, .{ nan, 0, 10 }, .{ 0, inf, 10 }, .{ 0, 0, nan } }) |bad| {
        try std.testing.expectError(error.InvalidGeolocation, encode(.{ .geolocation = .{ .browser = 1, .request = 1, .available = true, .latitude = bad[0], .longitude = bad[1], .accuracy = bad[2] } }, &buf));
    }
    // 없음이면 좌표는 모두 0.
    try std.testing.expectError(error.InvalidGeolocation, encode(.{ .geolocation = .{ .browser = 1, .request = 1, .available = false, .latitude = 1 } }, &buf));
    // 받는 쪽도 같은 규칙 — 위도 자리를 NaN 으로 바꾸면 거절.
    const len = try encode(.{ .geolocation = .{ .browser = 1, .request = 1, .available = true, .latitude = 1, .longitude = 2, .accuracy = 3 } }, &buf);
    const body = prefix_len + common_len;
    std.mem.writeInt(u64, buf[body + 13 ..][0..8], @bitCast(nan), .big);
    try std.testing.expectError(error.InvalidGeolocation, decodeExact(buf[0..len]));
    buf[body + 12] = 2; // available 은 bool
    try std.testing.expectError(error.InvalidBool, decodeExact(buf[0..len]));
}

comptime {
    // 가장 큰 대화상자 frame(글 셋 상한)도 frame 상한 안에 든다.
    std.debug.assert(prefix_len + common_len + 8 + 4 + 2 + 3 * (4 + max_text_bytes) <= max_frame_bytes);
}

// ── 제안 목록(W6m①) ───────────────────────────────────────────────────────────────────────────────────────

comptime {
    // 가장 큰 제안 목록 frame 도 frame 상한 안에 든다.
    std.debug.assert(prefix_len + common_len + 8 + 4 + 16 + 2 + 4 + message_mod.max_datalist_bytes <= max_frame_bytes);
}

test "datalist messages round trip — Korean, empty label, the builder's blob" {
    var blob: [256]u8 = undefined;
    var builder: fields.DatalistBuilder = .{ .buf = &blob };
    try std.testing.expect(builder.add("apple", "apple")); // 값과 같은 레이블은 비운다
    try std.testing.expect(builder.add("사과", "빨간 과일"));
    try std.testing.expect(builder.add("", "빈 값은 건너뛴다")); // 빈 값 — 쌓지 않지만 다음 항목은 받는다
    try std.testing.expectEqual(@as(u16, 2), builder.count);
    const shown = (try roundTrip(.{ .datalist_show = .{ .browser = 7, .list = 3, .field = .{ .x = -2, .y = 40, .width = 300, .height = 40 }, .count = builder.count, .items = builder.items() } })).datalist_show;
    try std.testing.expectEqual(@as(u32, 3), shown.list);
    try std.testing.expectEqual(@as(i32, -2), shown.field.x);
    var it: fields.DatalistItems = .{ .bytes = shown.items };
    const first = (try it.next()).?;
    try std.testing.expectEqualStrings("apple", first.value);
    try std.testing.expectEqualStrings("", first.label);
    const second = (try it.next()).?;
    try std.testing.expectEqualStrings("사과", second.value);
    try std.testing.expectEqualStrings("빨간 과일", second.label);
    try std.testing.expect((try it.next()) == null);
    try std.testing.expectEqual(@as(u32, 3), (try roundTrip(.{ .datalist_hide = .{ .browser = 7, .list = 3 } })).datalist_hide.list);
    const pick = (try roundTrip(.{ .datalist_pick = .{ .browser = 7, .list = 3, .index = 1 } })).datalist_pick;
    try std.testing.expectEqual(@as(u16, 1), pick.index);
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.datalist_show.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.datalist_hide.direction());
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.datalist_pick.direction());
}

test "datalist closed fields fail closed" {
    var buf: [max_frame_bytes]u8 = undefined;
    const one = "\x00\x01a\x00\x00";
    const field: message_mod.Rect = .{ .x = 0, .y = 0, .width = 10, .height = 10 };
    // 목록 번호 0 · 항목 0 개 · 개수와 덩어리가 어긋남 · 남는 바이트 · 빈 값 · 값과 같은 레이블 · 제어 문자 · 잘린 UTF-8.
    try std.testing.expectError(error.InvalidDatalist, encode(.{ .datalist_show = .{ .browser = 1, .list = 0, .field = field, .count = 1, .items = one } }, &buf));
    try std.testing.expectError(error.InvalidDatalist, encode(.{ .datalist_show = .{ .browser = 1, .list = 1, .field = field, .count = 0, .items = "" } }, &buf));
    try std.testing.expectError(error.InvalidDatalist, encode(.{ .datalist_show = .{ .browser = 1, .list = 1, .field = field, .count = 2, .items = one } }, &buf));
    try std.testing.expectError(error.InvalidLength, encode(.{ .datalist_show = .{ .browser = 1, .list = 1, .field = field, .count = 1, .items = one ++ "\x00" } }, &buf));
    try std.testing.expectError(error.InvalidDatalist, encode(.{ .datalist_show = .{ .browser = 1, .list = 1, .field = field, .count = 1, .items = "\x00\x00\x00\x00" } }, &buf));
    try std.testing.expectError(error.InvalidDatalist, encode(.{ .datalist_show = .{ .browser = 1, .list = 1, .field = field, .count = 1, .items = "\x00\x01a\x00\x01a" } }, &buf));
    try std.testing.expectError(error.ControlCharacter, encode(.{ .datalist_show = .{ .browser = 1, .list = 1, .field = field, .count = 1, .items = "\x00\x02a\x1b\x00\x00" } }, &buf));
    try std.testing.expectError(error.InvalidUtf8, encode(.{ .datalist_show = .{ .browser = 1, .list = 1, .field = field, .count = 1, .items = "\x00\x01\xea\x00\x00" } }, &buf));
    // 고른 번호는 상한 밖이면 안 된다, 목록 번호 0 도.
    try std.testing.expectError(error.InvalidDatalist, encode(.{ .datalist_pick = .{ .browser = 1, .list = 1, .index = message_mod.max_datalist_items } }, &buf));
    try std.testing.expectError(error.InvalidDatalist, encode(.{ .datalist_pick = .{ .browser = 1, .list = 0, .index = 0 } }, &buf));
    // 상한: 항목 수 · 글 하나의 길이.
    var many: [message_mod.max_datalist_bytes]u8 = undefined;
    var builder: fields.DatalistBuilder = .{ .buf = &many };
    var n: u32 = 0;
    while (n < message_mod.max_datalist_items + 10) : (n += 1) _ = builder.add("x", "");
    try std.testing.expectEqual(message_mod.max_datalist_items, builder.count);
    try std.testing.expect(!builder.add("y", ""));
    // 긴 글은 글자 경계에서 자르고(건너뛰지 않는다 — 번호가 어긋나지 않게), 제어 문자는 공백, 다듬어 값과 같아진 레이블은 비운다.
    const long = "가" ** (message_mod.max_datalist_text_bytes / 3 + 1);
    var room: [2 * message_mod.max_datalist_text_bytes + 8]u8 = undefined;
    var clamp: fields.DatalistBuilder = .{ .buf = &room };
    try std.testing.expect(clamp.add(long, "a\x01b"));
    try std.testing.expect(clamp.add("a\x07", "a "));
    try std.testing.expectEqual(@as(u16, 2), clamp.count);
    var it: fields.DatalistItems = .{ .bytes = clamp.items() };
    const cut = (try it.next()).?;
    try std.testing.expect(cut.value.len <= message_mod.max_datalist_text_bytes and cut.value.len % 3 == 0);
    try std.testing.expectEqualStrings("a b", cut.label);
    try std.testing.expectEqualStrings("", (try it.next()).?.label);
    try fields.checkDatalistItems(clamp.count, clamp.items());
    // 덩어리 바이트 상한 — 버퍼가 차면 false.
    var tiny: [8]u8 = undefined;
    var full: fields.DatalistBuilder = .{ .buf = &tiny };
    try std.testing.expect(full.add("ab", ""));
    try std.testing.expect(!full.add("cd", ""));
}

// ── 다운로드(W10a) ─────────────────────────────────────────────────────────────────────────────────────────

comptime {
    // 가장 큰 다운로드 frame(주소·이름·MIME 상한)도 frame 상한 안에 든다.
    std.debug.assert(prefix_len + common_len + 8 + 4 + 3 * 4 + message_mod.max_download_url_bytes + message_mod.max_download_name_bytes + message_mod.max_download_mime_bytes + 8 <= max_frame_bytes);
}

test "download messages round trip, flow the right way, and fail closed (W10a)" {
    const begin = (try roundTrip(.{ .download_begin = .{ .browser = 7, .download = 3, .url = "https://a/새.zip", .name = "새 파일.zip", .mime = "application/zip", .total = -1 } })).download_begin;
    try std.testing.expectEqualStrings("새 파일.zip", begin.name);
    try std.testing.expectEqual(@as(i64, -1), begin.total);
    const update = (try roundTrip(.{ .download_update = .{ .browser = 7, .download = 3, .state = .browser_closed, .received = 5, .total = 4, .reason = 0 } })).download_update;
    try std.testing.expectEqual(message_mod.DownloadState.browser_closed, update.state);
    try std.testing.expectEqual(@as(i64, 5), update.received); // 크기보다 많이 받아도 된다(서버가 길이를 거짓으로)
    try std.testing.expectEqualStrings("", (try roundTrip(.{ .download_decide = .{ .browser = 7, .download = 3, .path = "" } })).download_decide.path);
    try std.testing.expectEqual(message_mod.DownloadAction.cancel, (try roundTrip(.{ .download_control = .{ .browser = 7, .download = 3, .action = .cancel } })).download_control.action);
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.download_begin.direction());
    try std.testing.expectEqual(message_mod.Direction.to_maru, Tag.download_update.direction());
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.download_decide.direction());
    try std.testing.expectEqual(message_mod.Direction.to_sidecar, Tag.download_control.direction());

    var buf: [max_frame_bytes]u8 = undefined;
    const ok: message_mod.DownloadBegin = .{ .browser = 1, .download = 1, .url = "", .name = "a", .mime = "", .total = 0 };
    var bad = ok;
    bad.download = 0;
    try std.testing.expectError(error.InvalidDownload, encode(.{ .download_begin = bad }, &buf));
    for ([_][]const u8{ "", ".", "..", "a/b" }) |name| {
        bad = ok;
        bad.name = name;
        try std.testing.expectError(error.InvalidDownload, encode(.{ .download_begin = bad }, &buf));
    }
    bad = ok;
    bad.name = "a\x0d";
    try std.testing.expectError(error.ControlCharacter, encode(.{ .download_begin = bad }, &buf));
    bad = ok;
    bad.total = -2;
    try std.testing.expectError(error.InvalidDownload, encode(.{ .download_begin = bad }, &buf));
    bad = ok;
    bad.name = "a" ** (message_mod.max_download_name_bytes + 1);
    try std.testing.expectError(error.InvalidDownload, encode(.{ .download_begin = bad }, &buf));
    try std.testing.expectError(error.InvalidDownload, encode(.{ .download_update = .{ .browser = 1, .download = 1, .state = .complete, .received = -1, .total = 0, .reason = 0 } }, &buf));
    try std.testing.expectError(error.InvalidPath, encode(.{ .download_decide = .{ .browser = 1, .download = 1, .path = "relative" } }, &buf));
    try std.testing.expectError(error.InvalidDownload, encode(.{ .download_control = .{ .browser = 1, .download = 0, .action = .cancel } }, &buf));
    // 모르는 상태·동작은 decode 가 거절한다.
    const len = try encode(.{ .download_update = .{ .browser = 1, .download = 1, .state = .complete, .received = 0, .total = 0, .reason = 0 } }, &buf);
    buf[prefix_len + common_len + 8 + 4] = 9;
    try std.testing.expectError(error.InvalidDownload, decodeExact(buf[0..len]));
}
