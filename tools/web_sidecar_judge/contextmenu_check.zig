//! W6c① 판정 — 우클릭 메뉴(docs/plans/web-osr-backend.md W6). 판정자가 **maru 역할**로 `context_menu` 를 받고 고른 것을
//! `context_menu_command` 로 답한다. 메뉴를 띄우는 것은 maru(W6c② — NSMenu)라 여기서는 sidecar 의 알림·실행·클립보드만 본다.
//! 클립보드는 판정자 전용 이름의 것을 쓴다(`MARU_WEB_TEST_PASTEBOARD` — 사용자 클립보드를 덮어쓰지 않는다).
//!
//!   cm-page            빈 곳 — 링크·이미지·선택·입력 칸이 아니고, 자리가 우클릭한 곳이고, 뒤로는 못 간다
//!   cm-link            링크 — 링크·선택(링크 글)·복사 가능. 「링크 주소 복사」가 그 주소를 글·URL 형식으로 쓴다
//!   cm-image           다 받은 이미지 — 이미지·픽셀 있음. 「이미지 주소 복사」가 주소를, 「이미지 복사」가 PNG 를 쓴다
//!   cm-image-broken    못 받은 이미지 — 「이미지 복사」는 실행하지 않는다(취소로 바뀐다). 그 이미지는 다시 받으면 성공한다
//!                      (`/flaky.svg`) — 막지 않으면 클립보드에 PNG 가 생긴다
//!   cm-editable        입력 칸 — 입력 칸·붙여넣기·모두 선택 가능, 실행 취소는 아직 못 함. 「모두 선택」 뒤 친 글이 칸을 바꾼다
//!   cm-undo-redo       친 뒤에는 실행 취소가, 취소 뒤에는 다시 실행이 되고 칸이 그대로 돌아온다
//!   cm-frame           iframe 안 입력 칸의 「모두 선택」은 그 iframe 에 간다(CEF 가 대상 frame 을 맞춘다 — 착수 전 실측)
//!   cm-reload          빈 곳의 「새로고침」이 문서를 다시 불러온다(기본 메뉴에 없어 sidecar 가 더한 항목)
//!   cm-back-forward    이동한 뒤에는 뒤로 갈 수 있고 「뒤로」가 앞 주소로, 그 뒤 「앞으로」가 다시 뒤 주소로 간다
//!   cm-prevented       페이지가 `contextmenu` 를 막으면 메뉴가 오지 않는다
//!   cm-held-release    오른쪽을 누른 채 메뉴가 온 뒤 오른쪽 떼기가 먼저 가고 명령이 뒤따라도 명령이 실행된다 — 앱은 메뉴가 먹은 떼기를
//!                      명령보다 먼저 보낸다(W6c② — 떼기가 메뉴를 거두면 명령이 늦은 것으로 버려진다)
//!   cm-stale           닫힌 앞 메뉴의 번호로 온 명령은 실행하지 않는다(새 메뉴가 떠 있다)
//!   cm-not-allowed     그 메뉴에서 할 수 없는 명령(빈 곳의 「링크 주소 복사」·「실행 취소」)은 실행하지 않는다 — 입력 칸에 글을
//!                      친 뒤라 막지 않으면 실행 취소가 칸을 되돌린다
//!   cm-closed-navigate 메뉴가 떠 있는데 이동하면 닫힘이 오고, 그 뒤 그 번호의 명령은 실행하지 않는다
//!   cm-truncate        4 KiB 넘는 선택은 글자 경계에서 잘려 오고 잘렸다고 표시된다
//!   cm-renderer-gone   메뉴가 떠 있는 채 렌더러가 죽으면 그 메뉴의 닫힘이 온다(쥔 채 남지 않는다)
//!   cm-closed-once     메뉴마다 닫힘은 정확히 한 번 왔다
//!   cm-destroy         메뉴가 떠 있는 채 브라우저를 닫아도 host 가 살아 다음 브라우저가 메뉴를 받는다

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const pasteboard = @import("web_sidecar_pasteboard");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 23;
const wait_ms = 15_000;
const Point = protocol.message.Point;
const Flags = protocol.message.ContextMenuFlags;
const Command = protocol.message.ContextMenuCommandKind;

const link_point: Point = .{ .x = 60, .y = 30 };
const image_point: Point = .{ .x = 60, .y = 100 };
const broken_point: Point = .{ .x = 190, .y = 100 };
const input_point: Point = .{ .x = 60, .y = 225 };
const frame_point: Point = .{ .x = 340, .y = 245 };
const prevented_point: Point = .{ .x = 380, .y = 170 };
const long_point: Point = .{ .x = 520, .y = 60 };
const blank_point: Point = .{ .x = 560, .y = 440 };

/// maru 역할의 관찰 — 마지막 메뉴, 닫힘 수(번호마다), 제목, 주소.
const Watch = struct {
    host: *Host,
    shown: u32 = 0,
    menu: u32 = 0,
    point: Point = .{ .x = 0, .y = 0 },
    flags: Flags = .{},
    selection_buf: [protocol.wire.max_text_bytes]u8 = undefined,
    selection_len: usize = 0,
    /// 번호마다 받은 닫힘 수(번호는 작다 — 한 브라우저가 판정에서 여는 메뉴 수).
    closed: [64]u8 = @splat(0),
    closed_overflow: bool = false,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    url_buf: [512]u8 = undefined,
    url_len: usize = 0,
    browser_closed: bool = false,
    renderer_gone: u32 = 0,

    fn selection(self: *const Watch) []const u8 {
        return self.selection_buf[0..self.selection_len];
    }

    fn title(self: *const Watch) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn url(self: *const Watch) []const u8 {
        return self.url_buf[0..self.url_len];
    }

    fn closedCount(self: *const Watch, menu: u32) u8 {
        return if (menu < self.closed.len) self.closed[menu] else 0;
    }

    fn step(self: *Watch) void {
        const message = (self.host.next(20) catch null) orelse return;
        switch (message) {
            .context_menu => |v| if (v.browser == browser_id) {
                self.shown += 1;
                self.menu = v.menu;
                self.point = v.point;
                self.flags = v.flags;
                self.selection_len = @min(v.selection.len, self.selection_buf.len);
                @memcpy(self.selection_buf[0..self.selection_len], v.selection[0..self.selection_len]);
            },
            .context_menu_closed => |v| if (v.browser == browser_id) {
                if (v.menu < self.closed.len) self.closed[v.menu] +|= 1 else self.closed_overflow = true;
            },
            .title_changed => |v| if (v.browser == browser_id) {
                self.title_len = @min(v.text.len, self.title_buf.len);
                @memcpy(self.title_buf[0..self.title_len], v.text[0..self.title_len]);
            },
            .url_changed => |v| if (v.browser == browser_id) {
                self.url_len = @min(v.url.len, self.url_buf.len);
                @memcpy(self.url_buf[0..self.url_len], v.url[0..self.url_len]);
            },
            .browser_closed => |id| if (id == browser_id) {
                self.browser_closed = true;
            },
            .renderer_gone => |v| if (v.browser == browser_id) {
                self.renderer_gone += 1;
            },
            else => {},
        }
    }

    fn pump(self: *Watch, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) self.step();
    }

    fn until(self: *Watch, ms: u32, arg: anytype, comptime done: fn (*const Watch, @TypeOf(arg)) bool) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (done(self, arg)) return true;
            self.step();
        }
        return done(self, arg);
    }

    fn untilTitle(self: *Watch, want: []const u8, ms: u32) bool {
        return self.until(ms, want, struct {
            fn f(w: *const Watch, t: []const u8) bool {
                return std.mem.eql(u8, w.title(), t);
            }
        }.f);
    }

    fn untilClosed(self: *Watch, menu: u32, ms: u32) bool {
        return self.until(ms, menu, struct {
            fn f(w: *const Watch, m: u32) bool {
                return w.closedCount(m) > 0;
            }
        }.f);
    }

    /// 그 자리를 우클릭하고 새 메뉴가 올 때까지(최대 `ms`). 왔으면 그 번호.
    fn rightClick(self: *Watch, point: Point, ms: u32) !?u32 {
        const before = self.shown;
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .move, .point = point } });
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .down, .button = .right, .point = point, .click_count = 1 } });
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .up, .button = .right, .point = point, .click_count = 1 } });
        const got = self.until(ms, before, struct {
            fn f(w: *const Watch, b: u32) bool {
                return w.shown > b;
            }
        }.f);
        return if (got) self.menu else null;
    }

    fn command(self: *Watch, menu: u32, kind: Command) !void {
        try self.host.send(.{ .context_menu_command = .{ .browser = browser_id, .menu = menu, .command = kind } });
    }

    fn click(self: *Watch, point: Point, count: u8) !void {
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .move, .point = point } });
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .down, .button = .left, .point = point, .click_count = count } });
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .up, .button = .left, .point = point, .click_count = count } });
    }

    /// 글자 키 하나(raw_down → char → up — maru 가 수식자 없는 글자를 보내는 순서).
    fn typeChar(self: *Watch, ch: u8) !void {
        const key: protocol.message.Key = .{ .browser = browser_id, .kind = .raw_down, .windows_key_code = std.ascii.toUpper(ch), .native_key_code = 0, .character = ch, .unmodified_character = ch };
        try self.host.send(.{ .key = key });
        var char = key;
        char.kind = .char;
        try self.host.send(.{ .key = char });
        var up = key;
        up.kind = .up;
        try self.host.send(.{ .key = up });
    }
};

fn isPage(flags: Flags) bool {
    return !flags.link and !flags.image and !flags.selection and !flags.editable;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail: [400]u8 = undefined;
    var u: [256]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const board = std.fmt.bufPrint(&name_buf, "maru-web-judge-{d}", .{std.c.getpid()}) catch unreachable;
    var env_buf: [128]u8 = undefined;
    const env = std.fmt.bufPrintZ(&env_buf, "MARU_WEB_TEST_PASTEBOARD={s}", .{board}) catch unreachable;
    defer pasteboard.dispose(board);

    var host = try Host.spawnWith(host_path, profile_arg, null, &.{env.ptr});
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 640, .height = 480, .scale = 1 }, .hidden = false, .url = browsers_check.url(&u, port, "/cm") } });
    var w: Watch = .{ .host = &host };
    if (!w.untilTitle("cm 1", wait_ms)) return error.MenuPageNotReady;
    try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });
    w.pump(300);

    // 빈 곳.
    const page_menu = (try w.rightClick(blank_point, 3_000)) orelse 0;
    const page_ok = page_menu != 0 and isPage(w.flags) and w.point.x == blank_point.x and w.point.y == blank_point.y and !w.flags.can_go_back;
    report(page_ok, "cm-page", std.fmt.bufPrint(&detail, "메뉴 {d} · 페이지 {} · 자리 {d},{d} · 뒤로 {}", .{ page_menu, isPage(w.flags), w.point.x, w.point.y, w.flags.can_go_back }) catch "");
    if (page_menu != 0) try w.command(page_menu, .cancel);
    _ = w.untilClosed(page_menu, 2_000);

    // 링크 — 주소 복사.
    const link_menu = (try w.rightClick(link_point, 3_000)) orelse 0;
    const link_flags = w.flags;
    const link_text_ok = std.mem.eql(u8, w.selection(), "a link here");
    if (link_menu != 0) try w.command(link_menu, .copy_link_address);
    _ = w.untilClosed(link_menu, 2_000);
    var read_buf: [256]u8 = undefined;
    const want_link = browsers_check.url(&u, port, "/cm-target?x=1");
    const copied_text = pasteboard.readText(board, pasteboard.string_type, &read_buf) orelse "";
    const text_ok = std.mem.eql(u8, copied_text, want_link);
    const copied_url = pasteboard.readText(board, pasteboard.url_type, &read_buf) orelse "";
    const url_ok = std.mem.eql(u8, copied_url, want_link);
    report(link_menu != 0 and link_flags.link and link_flags.selection and link_flags.can_copy and !link_flags.image and link_text_ok and text_ok and url_ok, "cm-link", std.fmt.bufPrint(&detail, "링크 {} · 선택 「{s}」 · 복사 가능 {} · 클립보드 글 {} · URL 형식 {}", .{ link_flags.link, w.selection(), link_flags.can_copy, text_ok, url_ok }) catch "");

    // 다 받은 이미지 — 주소 복사, 그다음 이미지 복사.
    const image_menu = (try w.rightClick(image_point, 3_000)) orelse 0;
    const image_flags = w.flags;
    if (image_menu != 0) try w.command(image_menu, .copy_image_address);
    _ = w.untilClosed(image_menu, 2_000);
    var long_read: [512]u8 = undefined;
    const address = pasteboard.readText(board, pasteboard.string_type, &long_read) orelse "";
    const address_ok = std.mem.startsWith(u8, address, "data:image/svg+xml,");
    const image_menu2 = (try w.rightClick(image_point, 3_000)) orelse 0;
    if (image_menu2 != 0) try w.command(image_menu2, .copy_image);
    _ = w.untilClosed(image_menu2, 2_000);
    var png_len: usize = 0;
    const png_deadline = os.nowMs() + 4_000;
    while (os.nowMs() < png_deadline) : (w.pump(50)) {
        png_len = pasteboard.dataLength(board, pasteboard.png_type);
        if (png_len > 0) break;
    }
    report(image_menu != 0 and image_flags.image and image_flags.image_loaded and !image_flags.link and address_ok and png_len > 0, "cm-image", std.fmt.bufPrint(&detail, "이미지 {} · 픽셀 {} · 주소 복사 {} · PNG {d} 바이트", .{ image_flags.image, image_flags.image_loaded, address_ok, png_len }) catch "");

    // 못 받은 이미지 — 이미지 복사는 취소로 바뀐다(클립보드를 비워 두고 본다).
    _ = pasteboard.writeText(board, "untouched", false);
    const broken_menu = (try w.rightClick(broken_point, 3_000)) orelse 0;
    const broken_flags = w.flags;
    if (broken_menu != 0) try w.command(broken_menu, .copy_image);
    const broken_closed = w.untilClosed(broken_menu, 2_000);
    w.pump(1_000);
    const untouched = std.mem.eql(u8, pasteboard.readText(board, pasteboard.string_type, &read_buf) orelse "", "untouched") and pasteboard.dataLength(board, pasteboard.png_type) == 0;
    report(broken_menu != 0 and broken_flags.image and !broken_flags.image_loaded and broken_closed and untouched, "cm-image-broken", std.fmt.bufPrint(&detail, "이미지 {} · 픽셀 {}(없어야) · 닫힘 {} · 클립보드 그대로 {}", .{ broken_flags.image, broken_flags.image_loaded, broken_closed, untouched }) catch "");

    // 입력 칸 — 모두 선택 뒤 친 글.
    try w.click(input_point, 1);
    w.pump(200);
    const input_menu = (try w.rightClick(input_point, 3_000)) orelse 0;
    const input_flags = w.flags;
    if (input_menu != 0) try w.command(input_menu, .select_all);
    _ = w.untilClosed(input_menu, 2_000);
    try w.typeChar('q');
    const replaced = w.untilTitle("val:q", 3_000);
    report(input_menu != 0 and input_flags.editable and input_flags.can_paste and input_flags.can_select_all and !input_flags.can_undo and replaced, "cm-editable", std.fmt.bufPrint(&detail, "입력 칸 {} · 붙여넣기 {} · 모두 선택 {} · 실행 취소 {}(아직 없어야) · 모두 선택 뒤 q → 「{s}」", .{ input_flags.editable, input_flags.can_paste, input_flags.can_select_all, input_flags.can_undo, w.title() }) catch "");

    // 실행 취소·다시 실행.
    const undo_menu = (try w.rightClick(input_point, 3_000)) orelse 0;
    const can_undo = w.flags.can_undo;
    if (undo_menu != 0) try w.command(undo_menu, .undo);
    const undone = w.untilTitle("val:some input text", 3_000);
    const redo_menu = (try w.rightClick(input_point, 3_000)) orelse 0;
    const can_redo = w.flags.can_redo;
    if (redo_menu != 0) try w.command(redo_menu, .redo);
    const redone = w.untilTitle("val:q", 3_000);
    report(can_undo and undone and can_redo and redone, "cm-undo-redo", std.fmt.bufPrint(&detail, "실행 취소 가능 {} → 돌아옴 {} · 다시 실행 가능 {} → 다시 q {}", .{ can_undo, undone, can_redo, redone }) catch "");

    // iframe 안 입력 칸.
    try w.click(frame_point, 1);
    w.pump(200);
    const frame_menu = (try w.rightClick(frame_point, 3_000)) orelse 0;
    if (frame_menu != 0) try w.command(frame_menu, .select_all);
    _ = w.untilClosed(frame_menu, 2_000);
    try w.typeChar('w');
    const frame_ok = w.untilTitle("frame:w", 3_000);
    report(frame_menu != 0 and frame_ok, "cm-frame", std.fmt.bufPrint(&detail, "iframe 메뉴 {d} · 모두 선택 뒤 w → 「{s}」", .{ frame_menu, w.title() }) catch "");

    // 막힌 자리.
    const before_prevented = w.shown;
    const prevented_menu = try w.rightClick(prevented_point, 1_500);
    const prevented_seen = w.untilTitle("prevented", 1_000);
    report(prevented_menu == null and w.shown == before_prevented and prevented_seen, "cm-prevented", std.fmt.bufPrint(&detail, "페이지가 막음(제목 「prevented」 {}) · 메뉴 {d} → {d}(그대로여야)", .{ prevented_seen, before_prevented, w.shown }) catch "");

    // 늦은 명령 — 앞 메뉴를 닫고 새 메뉴를 연 뒤 앞 번호로 새로고침. (메뉴가 떠 있는 동안의 우클릭은 CEF 가 새 메뉴를 만들지 않는다
    // — 판정 중 실측. 앱에서는 macOS 메뉴가 떠 있어 페이지를 우클릭할 수 없다.)
    const stale_a = (try w.rightClick(blank_point, 3_000)) orelse 0;
    if (stale_a != 0) try w.command(stale_a, .cancel);
    const a_closed = w.untilClosed(stale_a, 2_000);
    const stale_b = (try w.rightClick(blank_point, 3_000)) orelse 0;
    try w.command(stale_a, .reload);
    w.pump(1_500);
    const not_reloaded = std.mem.eql(u8, w.title(), "prevented");
    if (stale_b != 0) try w.command(stale_b, .cancel);
    _ = w.untilClosed(stale_b, 2_000);
    report(stale_a != 0 and stale_b != 0 and stale_a != stale_b and a_closed and not_reloaded, "cm-stale", std.fmt.bufPrint(&detail, "메뉴 {d} → {d} · 앞 메뉴 닫힘 {} · 앞 번호의 새로고침 뒤 제목 「{s}」(그대로여야)", .{ stale_a, stale_b, a_closed, w.title() }) catch "");

    // 할 수 없는 명령 — 빈 곳의 링크 주소 복사·실행 취소. 입력 칸에 글을 친 뒤라 막지 않으면 실행 취소가 칸을 되돌린다.
    try w.click(input_point, 1);
    try w.typeChar('u');
    const typed = w.untilTitle("val:qu", 3_000);
    _ = pasteboard.writeText(board, "untouched", false);
    const deny_a = (try w.rightClick(blank_point, 3_000)) orelse 0;
    if (deny_a != 0) try w.command(deny_a, .copy_link_address);
    const deny_a_closed = w.untilClosed(deny_a, 2_000);
    const deny_b = (try w.rightClick(blank_point, 3_000)) orelse 0;
    if (deny_b != 0) try w.command(deny_b, .undo);
    const deny_b_closed = w.untilClosed(deny_b, 2_000);
    w.pump(500);
    const board_same = std.mem.eql(u8, pasteboard.readText(board, pasteboard.string_type, &read_buf) orelse "", "untouched");
    report(typed and deny_a != 0 and deny_b != 0 and deny_a_closed and deny_b_closed and board_same and std.mem.eql(u8, w.title(), "val:qu"), "cm-not-allowed", std.fmt.bufPrint(&detail, "칸에 u 를 침 {} · 빈 곳의 링크 주소 복사 → 닫힘 {} · 클립보드 그대로 {} · 실행 취소 → 닫힘 {} · 제목 「{s}」(val:qu 여야)", .{ typed, deny_a_closed, board_same, deny_b_closed, w.title() }) catch "");

    // 새로고침(기본 메뉴에 없어 sidecar 가 더한 항목). 제목은 문서를 불러온 횟수다.
    const reload_menu = (try w.rightClick(blank_point, 3_000)) orelse 0;
    const reload_flags = w.flags;
    if (reload_menu != 0) try w.command(reload_menu, .reload);
    const reloaded = w.untilTitle("cm 2", 4_000);
    report(reload_menu != 0 and isPage(reload_flags) and reloaded, "cm-reload", std.fmt.bufPrint(&detail, "새로고침 → 제목 「{s}」(cm 2 여야)", .{w.title()}) catch "");

    // 이동하면 닫힘, 그 번호의 명령은 실행하지 않는다.
    const nav_menu = (try w.rightClick(blank_point, 3_000)) orelse 0;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/cm?second") } });
    const nav_closed = w.untilClosed(nav_menu, 4_000);
    _ = w.untilTitle("cm 3", 4_000);
    try w.command(nav_menu, .reload);
    w.pump(1_500);
    const nav_ignored = std.mem.eql(u8, w.title(), "cm 3");
    report(nav_menu != 0 and nav_closed and nav_ignored, "cm-closed-navigate", std.fmt.bufPrint(&detail, "이동 → 닫힘 {} · 그 번호의 새로고침 뒤 제목 「{s}」(cm 3 이어야)", .{ nav_closed, w.title() }) catch "");

    // 뒤로.
    const back_menu = (try w.rightClick(blank_point, 3_000)) orelse 0;
    const can_back = w.flags.can_go_back;
    if (back_menu != 0) try w.command(back_menu, .back);
    const went_back = w.until(4_000, {}, struct {
        fn f(x: *const Watch, _: void) bool {
            return std.mem.endsWith(u8, x.url(), "/cm");
        }
    }.f);
    w.pump(800); // 뒤로는 bfcache 에서 돌아올 수 있다 — 스크립트가 다시 돌지 않으니 제목을 기다리지 않는다
    const forward_menu = (try w.rightClick(blank_point, 3_000)) orelse 0;
    const can_forward = w.flags.can_go_forward;
    if (forward_menu != 0) try w.command(forward_menu, .forward);
    const went_forward = w.until(4_000, {}, struct {
        fn f(x: *const Watch, _: void) bool {
            return std.mem.endsWith(u8, x.url(), "/cm?second");
        }
    }.f);
    w.pump(800);
    report(back_menu != 0 and can_back and went_back and forward_menu != 0 and can_forward and went_forward, "cm-back-forward", std.fmt.bufPrint(&detail, "뒤로 가능 {} → 뒤로 {} · 앞으로 가능 {} → 앞으로 「{s}」", .{ can_back, went_back, can_forward, w.url() }) catch "");

    // 누른 채 온 메뉴 — 오른쪽 떼기를 먼저 보내고 명령(새로고침)을 뒤에. 떼기가 메뉴를 거두면 명령은 실행되지 않는다.
    const held_before = w.shown;
    const title_before_len = w.title_len;
    var title_before: [128]u8 = undefined;
    @memcpy(title_before[0..title_before_len], w.title_buf[0..title_before_len]);
    try host.send(.{ .mouse = .{ .browser = browser_id, .kind = .move, .point = blank_point } });
    try host.send(.{ .mouse = .{ .browser = browser_id, .kind = .down, .button = .right, .point = blank_point, .click_count = 1 } });
    const held_shown = w.until(3_000, held_before, struct {
        fn f(x: *const Watch, b: u32) bool {
            return x.shown > b;
        }
    }.f);
    const held_menu = w.menu;
    try host.send(.{ .mouse = .{ .browser = browser_id, .kind = .up, .button = .right, .point = blank_point, .click_count = 1 } });
    try w.command(held_menu, .reload);
    const reloaded_after_release = w.until(4_000, title_before[0..title_before_len], struct {
        fn f(x: *const Watch, before: []const u8) bool {
            return std.mem.startsWith(u8, x.title(), "cm ") and !std.mem.eql(u8, x.title(), before);
        }
    }.f);
    report(held_shown and reloaded_after_release and w.untilClosed(held_menu, 2_000), "cm-held-release", std.fmt.bufPrint(&detail, "누른 채 메뉴 {} · 떼기 뒤 새로고침 → 제목 「{s}」 → 「{s}」(바뀌어야) · 닫힘", .{ held_shown, title_before[0..title_before_len], w.title() }) catch "");

    // 4 KiB 넘는 선택.
    try w.click(long_point, 3);
    w.pump(300);
    const long_menu = (try w.rightClick(long_point, 3_000)) orelse 0;
    const long_flags = w.flags;
    const long_len = w.selection().len;
    const long_ok = long_flags.selection and long_flags.selection_truncated and long_len <= protocol.wire.max_text_bytes and long_len > 4000 and std.unicode.utf8ValidateSlice(w.selection());
    if (long_menu != 0) try w.command(long_menu, .cancel);
    _ = w.untilClosed(long_menu, 2_000);
    report(long_menu != 0 and long_ok, "cm-truncate", std.fmt.bufPrint(&detail, "선택 {} · 잘림 {} · {d} 바이트(4096 이하·4000 넘게) · UTF-8 {}", .{ long_flags.selection, long_flags.selection_truncated, long_len, std.unicode.utf8ValidateSlice(w.selection()) }) catch "");

    // 메뉴가 떠 있는 채 렌더러가 죽는다.
    const gone_menu = (try w.rightClick(blank_point, 3_000)) orelse 0;
    var kids_buf: [64]c_int = undefined;
    var killed: u32 = 0;
    for (os.children(host.pid, &kids_buf)) |kid| {
        if (os.argsContain(kid, "--type=renderer")) {
            _ = std.c.kill(kid, std.c.SIG.KILL);
            killed += 1;
        }
    }
    const gone_closed = w.untilClosed(gone_menu, 5_000);
    w.pump(300);
    report(gone_menu != 0 and killed >= 1 and w.renderer_gone >= 1 and gone_closed, "cm-renderer-gone", std.fmt.bufPrint(&detail, "메뉴 {d} · 죽인 렌더러 {d} · renderer_gone {d} · 그 메뉴의 닫힘 {}", .{ gone_menu, killed, w.renderer_gone, gone_closed }) catch "");

    // 메뉴마다 닫힘은 한 번.
    var once = !w.closed_overflow;
    var bad_menu: u32 = 0;
    var m: u32 = 1;
    while (m <= w.menu and m < w.closed.len) : (m += 1) {
        if (w.closed[m] != 1) {
            once = false;
            bad_menu = m;
        }
    }
    report(once and w.menu > 10, "cm-closed-once", std.fmt.bufPrint(&detail, "메뉴 1~{d} 의 닫힘이 모두 한 번 {} (어긋난 번호 {d}·그 수 {d})", .{ w.menu, once, bad_menu, w.closedCount(bad_menu) }) catch "");

    // 메뉴가 떠 있는 채 닫는다 — host 가 살아 다음 브라우저가 메뉴를 받는다.
    _ = try w.rightClick(blank_point, 3_000);
    try host.send(.{ .destroy_browser = browser_id });
    const destroyed = w.until(5_000, {}, struct {
        fn f(x: *const Watch, _: void) bool {
            return x.browser_closed;
        }
    }.f);
    w.browser_closed = false;
    w.title_len = 0;
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 640, .height = 480, .scale = 1 }, .hidden = false, .url = browsers_check.url(&u, port, "/cm?third") } });
    // 새 브라우저는 새 탭 세션이라 불러온 횟수가 1 부터다.
    _ = w.untilTitle("cm 1", wait_ms);
    const again = (try w.rightClick(blank_point, 3_000)) orelse 0;
    if (again != 0) try w.command(again, .cancel);
    _ = w.untilClosed(again, 2_000);
    report(destroyed and again != 0 and host.clean, "cm-destroy", std.fmt.bufPrint(&detail, "떠 있는 채 닫음 → browser_closed {} · 다시 만든 브라우저의 메뉴 {d} · host 메시지 모두 해석 {}", .{ destroyed, again, host.clean }) catch "");
}
