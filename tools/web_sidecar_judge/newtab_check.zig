//! W6e 판정 — 페이지가 여는 새 탭(docs/plans/web-osr-backend.md W6). 판정자가 **maru 역할**로 `open_tab` 을 받는다. 탭을 만드는
//! 것은 maru 라 여기서는 sidecar 가 무엇을 언제 보내는지만 본다. 페이지는 `/newtab`.
//!
//!   newtab-blank          `target=_blank` 링크 클릭 → 앞 탭 하나, 그 주소. 지금 탭은 그대로
//!   newtab-cmd            ⌘ 클릭 → 뒤 탭(지금 탭이 이동하지 않는다 — W6e 전에는 같은 탭에서 이동했다)
//!   newtab-middle         가운데 클릭 → 뒤 탭
//!   newtab-cmd-shift      ⌘⇧ 클릭 → 앞 탭, ⇧ 클릭(Chrome 은 새 창) → 앞 탭
//!   newtab-window-open    `window.open` → 앞 탭, 크기를 준 `window.open`(팝업 창) → 앞 탭
//!   newtab-one-per-input  한 번 클릭에 `window.open` 10 번 → 탭 하나(첫 주소). 다음 클릭은 다시 하나
//!   newtab-key            포커스된 `_blank` 링크에서 Enter → 앞 탭(키 누름도 사용자 입력이다)
//!   newtab-late           클릭 2.5 초 뒤의 `window.open`(활성화 안) → 앞 탭 하나
//!   newtab-credit         0.4 초마다 `window.open` 하는 페이지 — 누른 때 하나, 그 뒤 포인터 이동·떼기·키 떼기·글자·Esc 로는 더 없고, 키
//!                         누름 하나에 하나 더(사용자 입력은 누름과 Esc 아닌 키 누름뿐 — Chrome 의 활성화와 같다)
//!   newtab-refused        빈 `window.open()`·`javascript:`·`data:` 링크 → 탭 없음
//!   newtab-no-gesture     입력 없이 페이지가 연 것(`window.open`·만든 ⌘ 클릭·`click()`) → 탭 없음, 지금 탭도 그대로
//!   newtab-handled-drop   페이지가 받은 놓기(이동 없음) 뒤 페이지가 만든 ⌘ 클릭 → 지금 탭은 이동하지 않고 그 링크의 새 탭 하나(놓기도
//!                         Chromium 의 사용자 활성화다 — Chrome 과 같다). 놓기 뒤 지금 탭에서 여는 것은 놓은 그 주소의 이동뿐이다
//!   newtab-drop-window    놓은 링크와 같은 주소의 ⌘ 클릭도 놓기 2.5 초 뒤면 새 탭(놓기 이동은 놓은 뒤 2 초만)
//!   newtab-menu           링크 우클릭 메뉴가 `link_openable` 이고 「새 탭에서 링크 열기」 → 뒤 탭. `mailto:` 링크는 열 수 없다
//!   newtab-menu-window-image  링크 메뉴의 「새 창에서 링크 열기」 → `new_window` 자리로 그 링크(W6h①). http 이미지 메뉴는 `image_openable`
//!                         이고 「새 탭에서 이미지 열기」 → 뒤 탭으로 그 이미지 주소. `data:` 이미지는 열 수 없고 명령을 보내도 탭 없음
//!   newtab-no-window      그동안 host 창 0 개, 팝업 주소 요청 0(보이지 않는 팝업 브라우저도 만들지 않았다)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");
const windows = @import("windows.zig");
const http = @import("http.zig");

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 27;
const wait_ms = 15_000;
const Point = protocol.message.Point;
const Modifiers = protocol.message.Modifiers;
const Placement = protocol.message.NewTabPlacement;

const ab_point: Point = .{ .x = 60, .y = 25 };
const pl_point: Point = .{ .x = 200, .y = 25 };
const ml_point: Point = .{ .x = 340, .y = 25 };
const w1_point: Point = .{ .x = 60, .y = 75 };
const wf_point: Point = .{ .x = 200, .y = 75 };
const m10_point: Point = .{ .x = 340, .y = 75 };
const bl_point: Point = .{ .x = 60, .y = 125 };
const js_point: Point = .{ .x = 200, .y = 125 };
const dl_point: Point = .{ .x = 340, .y = 125 };
const late_point: Point = .{ .x = 60, .y = 175 };
const img_point: Point = .{ .x = 200, .y = 175 };
const data_img_point: Point = .{ .x = 340, .y = 175 };
const rep_point: Point = .{ .x = 480, .y = 175 };
const dz_point: Point = .{ .x = 480, .y = 100 };
const dz2_point: Point = .{ .x = 595, .y = 100 };
const blank_point: Point = .{ .x = 520, .y = 360 };

const Opened = struct { placement: Placement, url: [256]u8 = undefined, url_len: usize = 0 };

/// maru 역할의 관찰 — 온 새 탭들, 이 탭의 주소 변경 수·제목, 메뉴.
const Watch = struct {
    host: *Host,
    opened: [32]Opened = undefined,
    opened_len: usize = 0,
    url_changes: u32 = 0,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    menu: u32 = 0,
    flags: protocol.message.ContextMenuFlags = .{},
    menu_closed: u32 = 0,

    fn title(self: *const Watch) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn step(self: *Watch) void {
        const message = (self.host.next(20) catch null) orelse return;
        switch (message) {
            .open_tab => |v| if (v.browser == browser_id and self.opened_len < self.opened.len) {
                var o: Opened = .{ .placement = v.placement };
                o.url_len = @min(v.url.len, o.url.len);
                @memcpy(o.url[0..o.url_len], v.url[0..o.url_len]);
                self.opened[self.opened_len] = o;
                self.opened_len += 1;
            },
            .url_changed => |v| if (v.browser == browser_id) {
                self.url_changes += 1;
            },
            .title_changed => |v| if (v.browser == browser_id) {
                self.title_len = @min(v.text.len, self.title_buf.len);
                @memcpy(self.title_buf[0..self.title_len], v.text[0..self.title_len]);
            },
            .context_menu => |v| if (v.browser == browser_id) {
                self.menu = v.menu;
                self.flags = v.flags;
            },
            .context_menu_closed => |v| if (v.browser == browser_id) {
                self.menu_closed = v.menu;
            },
            else => {},
        }
    }

    fn pump(self: *Watch, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) self.step();
    }

    fn untilTitle(self: *Watch, want: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (std.mem.eql(u8, self.title(), want)) return true;
            self.step();
        }
        return std.mem.eql(u8, self.title(), want);
    }

    /// 누르고 뗀 뒤 `ms` 동안 받는다. 그 사이 온 새 탭 수.
    fn click(self: *Watch, point: Point, button: protocol.message.MouseButton, mods: Modifiers, ms: u32) !usize {
        const before = self.opened_len;
        var held = mods;
        switch (button) {
            .left => held.left_button = true,
            .middle => held.middle_button = true,
            .right => held.right_button = true,
        }
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .move, .point = point, .modifiers = mods } });
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .down, .button = button, .point = point, .modifiers = held, .click_count = 1 } });
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .up, .button = button, .point = point, .modifiers = mods, .click_count = 1 } });
        self.pump(ms);
        return self.opened_len - before;
    }

    fn last(self: *const Watch) ?*const Opened {
        return if (self.opened_len == 0) null else &self.opened[self.opened_len - 1];
    }

    /// 마지막 새 탭이 그 자리·주소(경로)인가.
    fn lastIs(self: *const Watch, placement: Placement, port: u16, path: []const u8) bool {
        const o = self.last() orelse return false;
        var u: [256]u8 = undefined;
        return o.placement == placement and std.mem.eql(u8, o.url[0..o.url_len], browsers_check.url(&u, port, path));
    }

    fn lastUrl(self: *const Watch) []const u8 {
        const o = self.last() orelse return "";
        return o.url[0..o.url_len];
    }
};

/// 링크 주소 하나를 그 자리에 끌어 놓는다(enter → over 둘 → drop). 페이지가 받으면 제목이 `title` 이 된다.
fn dropLink(w: *Watch, point: Point, url: []const u8, title: []const u8, ms: u32) !bool {
    try w.host.send(.{ .drag_data = .{ .browser = browser_id, .kind = .url, .bytes = url } });
    try w.host.send(.{ .drag_target = .{ .browser = browser_id, .kind = .enter, .point = point, .allowed = 1 } });
    w.pump(120);
    try w.host.send(.{ .drag_target = .{ .browser = browser_id, .kind = .over, .point = point, .allowed = 1 } });
    w.pump(120);
    try w.host.send(.{ .drag_target = .{ .browser = browser_id, .kind = .over, .point = point, .allowed = 1 } });
    w.pump(200);
    try w.host.send(.{ .drag_target = .{ .browser = browser_id, .kind = .drop, .point = point } });
    return w.untilTitle(title, ms);
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail: [400]u8 = undefined;
    var u: [256]u8 = undefined;

    const loads_before = http.newtab_requests.load(.monotonic);
    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 640, .height = 400, .scale = 1 }, .hidden = false, .url = browsers_check.url(&u, port, "/newtab") } });
    var w: Watch = .{ .host = &host };
    if (!w.untilTitle("nt-ready", wait_ms)) return error.NewTabPageNotReady;
    try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });
    w.pump(300);
    // 새로 뜬 브라우저는 첫 입력을 잃을 수 있다(W7b) — 빈 곳을 한 번 누른다(탭은 열리지 않는다).
    _ = try w.click(blank_point, .left, .{}, 300);
    const settled_changes = w.url_changes;

    const blank = try w.click(ab_point, .left, .{}, 800);
    report(blank == 1 and w.lastIs(.foreground, port, "/title?t=nt-ab") and w.url_changes == settled_changes, "newtab-blank", std.fmt.bufPrint(&detail, "새 탭 {d} · 「{s}」 · 지금 탭 이동 {d}", .{ blank, w.lastUrl(), w.url_changes - settled_changes }) catch "");

    const cmd = try w.click(pl_point, .left, .{ .command = true }, 800);
    report(cmd == 1 and w.lastIs(.background, port, "/title?t=nt-pl") and w.url_changes == settled_changes, "newtab-cmd", std.fmt.bufPrint(&detail, "새 탭 {d} · 뒤 {} · 지금 탭 이동 {d}", .{ cmd, w.lastIs(.background, port, "/title?t=nt-pl"), w.url_changes - settled_changes }) catch "");

    const middle = try w.click(pl_point, .middle, .{}, 800);
    report(middle == 1 and w.lastIs(.background, port, "/title?t=nt-pl"), "newtab-middle", std.fmt.bufPrint(&detail, "새 탭 {d} · 뒤 {}", .{ middle, w.lastIs(.background, port, "/title?t=nt-pl") }) catch "");

    const cmd_shift = try w.click(pl_point, .left, .{ .command = true, .shift = true }, 800);
    const cmd_shift_ok = cmd_shift == 1 and w.lastIs(.foreground, port, "/title?t=nt-pl");
    const shift = try w.click(ab_point, .left, .{ .shift = true }, 800);
    const shift_ok = shift == 1 and w.lastIs(.foreground, port, "/title?t=nt-ab");
    report(cmd_shift_ok and shift_ok and w.url_changes == settled_changes, "newtab-cmd-shift", std.fmt.bufPrint(&detail, "⌘⇧ {d} 앞 {} · ⇧ {d} 앞 {}", .{ cmd_shift, cmd_shift_ok, shift, shift_ok }) catch "");

    const open = try w.click(w1_point, .left, .{}, 800);
    const open_ok = open == 1 and w.lastIs(.foreground, port, "/title?t=nt-w1");
    const featured = try w.click(wf_point, .left, .{}, 800);
    const featured_ok = featured == 1 and w.lastIs(.foreground, port, "/title?t=nt-wf");
    report(open_ok and featured_ok, "newtab-window-open", std.fmt.bufPrint(&detail, "window.open {d} 앞 {} · 팝업 창 {d} 앞 {}", .{ open, open_ok, featured, featured_ok }) catch "");

    const many = try w.click(m10_point, .left, .{}, 1_200);
    const many_ok = many == 1 and w.lastIs(.foreground, port, "/title?t=nt-m0");
    const again = try w.click(w1_point, .left, .{}, 800);
    report(many_ok and again == 1, "newtab-one-per-input", std.fmt.bufPrint(&detail, "10 번 연 클릭에 새 탭 {d}(첫 주소 {}) · 다음 클릭 {d}", .{ many, many_ok, again }) catch "");

    // 포커스를 링크에 둔다(페이지가 `#ab` 에 focus — 제목 `nt-focused`). Enter 는 키 누름이다.
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/newtab-focus") } });
    const focused = w.untilTitle("nt-focused", wait_ms);
    w.pump(300);
    const before_key = w.opened_len;
    const enter: protocol.message.Key = .{ .browser = browser_id, .kind = .raw_down, .windows_key_code = 0x0d, .native_key_code = 0x24, .character = '\r', .unmodified_character = '\r' };
    try host.send(.{ .key = enter });
    var enter_char = enter;
    enter_char.kind = .char;
    try host.send(.{ .key = enter_char });
    var enter_up = enter;
    enter_up.kind = .up;
    try host.send(.{ .key = enter_up });
    w.pump(800);
    const keyed = w.opened_len - before_key;
    report(focused and keyed == 1 and w.lastIs(.foreground, port, "/title?t=nt-ab"), "newtab-key", std.fmt.bufPrint(&detail, "포커스 {} · Enter 에 새 탭 {d} · 「{s}」", .{ focused, keyed, w.lastUrl() }) catch "");

    const late_now = try w.click(late_point, .left, .{}, 300);
    const before_late = w.opened_len;
    w.pump(3_200);
    const late = w.opened_len - before_late;
    report(late_now == 0 and late == 1 and w.lastIs(.foreground, port, "/title?t=nt-late"), "newtab-late", std.fmt.bufPrint(&detail, "누른 때 {d} · 2.5 초 뒤 {d} · 「{s}」", .{ late_now, late, w.lastUrl() }) catch "");

    // 되풀이해 여는 페이지 — 누름 하나에 하나. 그 뒤 활성화가 아닌 입력(이동·떼기·키 떼기·글자·Esc)은 장을 주지 않는다.
    const rep_now = try w.click(rep_point, .left, .{}, 600);
    const before_noise = w.opened_len;
    var mv: i32 = 0;
    while (mv < 5) : (mv += 1) try host.send(.{ .mouse = .{ .browser = browser_id, .kind = .move, .point = .{ .x = blank_point.x - 10 * mv, .y = blank_point.y } } });
    try host.send(.{ .mouse = .{ .browser = browser_id, .kind = .up, .button = .left, .point = blank_point, .click_count = 1 } });
    const letter: protocol.message.Key = .{ .browser = browser_id, .kind = .up, .windows_key_code = 'A', .native_key_code = 0, .character = 'a', .unmodified_character = 'a' };
    try host.send(.{ .key = letter });
    var letter_char = letter;
    letter_char.kind = .char;
    try host.send(.{ .key = letter_char });
    // maru 처럼 macOS 키 코드만 싣는다(Windows 코드 0 — 제품 경로, W6f② 적대 검증 4 차).
    const esc: protocol.message.Key = .{ .browser = browser_id, .kind = .raw_down, .windows_key_code = 0, .native_key_code = 0x35, .character = 0x1b, .unmodified_character = 0x1b };
    try host.send(.{ .key = esc });
    var esc_up = esc;
    esc_up.kind = .up;
    try host.send(.{ .key = esc_up });
    w.pump(1_300);
    const noise = w.opened_len - before_noise;
    var key_down = letter;
    key_down.kind = .raw_down;
    try host.send(.{ .key = key_down });
    try host.send(.{ .key = letter });
    w.pump(700);
    const keyed_again = w.opened_len - before_noise - noise;
    report(rep_now == 1 and noise == 0 and keyed_again == 1, "newtab-credit", std.fmt.bufPrint(&detail, "누른 때 {d} · 이동·떼기·키 떼기·글자·Esc 뒤 {d} · 키 누름 뒤 {d}", .{ rep_now, noise, keyed_again }) catch "");
    w.pump(2_500); // 되풀이가 끝나게(4.8 초)

    const refused_blank = try w.click(bl_point, .left, .{}, 800);
    const refused_js = try w.click(js_point, .left, .{}, 800);
    const refused_data = try w.click(dl_point, .left, .{}, 800);
    report(refused_blank == 0 and refused_js == 0 and refused_data == 0, "newtab-refused", std.fmt.bufPrint(&detail, "빈 팝업 {d} · javascript: {d} · data: {d}", .{ refused_blank, refused_js, refused_data }) catch "");

    // 입력 없이 — 페이지가 불러온 뒤 스스로 연다(제목 `nt-auto-done`). 장은 먼저 쥐여 둔다(빈 곳 누름) — 제스처 검사만 막게.
    _ = try w.click(blank_point, .left, .{}, 300);
    // 지금 탭의 주소 변경은 이 이동 하나여야 한다 — 만든 ⌘ 클릭이 지금 탭을 옮기면(같은 탭 이동으로 두면) 하나 더 온다.
    const auto_changes = w.url_changes;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/newtab-auto") } });
    const before_auto = w.opened_len;
    const auto_done = w.untilTitle("nt-auto-done", wait_ms);
    w.pump(1_500);
    const stayed = std.mem.eql(u8, w.title(), "nt-auto-done") and w.url_changes - auto_changes == 1;
    report(auto_done and w.opened_len == before_auto and stayed, "newtab-no-gesture", std.fmt.bufPrint(&detail, "끝 {} · 새 탭 {d} · 주소 변경 {d}(이동 하나여야) · 제목 「{s}」", .{ auto_done, w.opened_len - before_auto, w.url_changes - auto_changes, w.title() }) catch "");

    // 메뉴 — 다시 불러온 페이지에서(입력 없이 연 시도들이 남긴 것이 없게).
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/newtab") } });
    _ = w.untilTitle("nt-ready", wait_ms);
    w.pump(300);

    // 페이지가 받은 놓기 — 이동이 없다. 놓은 것은 다른 주소의 링크다. 그 뒤 페이지가 만든 `#pl` ⌘ 클릭은 놓은 주소가 아니라 지금 탭을
    // 옮기지 않고 새 탭이 된다. 장은 먼저 쥐여 둔다(빈 곳 누름).
    _ = try w.click(blank_point, .left, .{}, 300);
    const drop_changes = w.url_changes;
    const drop_opened = w.opened_len;
    const dropped = try dropLink(&w, dz_point, browsers_check.url(&u, port, "/title?t=nt-dz"), "nt-dropped", 3_000);
    w.pump(1_000);
    report(dropped and w.url_changes == drop_changes and w.opened_len == drop_opened + 1 and w.lastIs(.foreground, port, "/title?t=nt-pl"), "newtab-handled-drop", std.fmt.bufPrint(&detail, "놓기 받음 {} · 지금 탭 이동 {d} · 새 탭 {d}", .{ dropped, w.url_changes - drop_changes, w.opened_len - drop_opened }) catch "");
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/newtab") } });
    _ = w.untilTitle("nt-ready", wait_ms);
    w.pump(300);

    // 놓은 링크와 같은 주소여도 2.5 초 뒤면 놓기 이동이 아니다 — 새 탭(활성화는 5 초라 제스처는 있다).
    _ = try w.click(blank_point, .left, .{}, 300);
    const late_changes = w.url_changes;
    const late_opened = w.opened_len;
    const late_dropped = try dropLink(&w, dz2_point, browsers_check.url(&u, port, "/title?t=nt-pl"), "nt-dropped-late", 5_000);
    w.pump(1_000);
    report(late_dropped and w.url_changes == late_changes and w.opened_len == late_opened + 1 and w.lastIs(.foreground, port, "/title?t=nt-pl"), "newtab-drop-window", std.fmt.bufPrint(&detail, "놓기 받음 {} · 지금 탭 이동 {d} · 새 탭 {d}", .{ late_dropped, w.url_changes - late_changes, w.opened_len - late_opened }) catch "");
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/newtab") } });
    _ = w.untilTitle("nt-ready", wait_ms);
    w.pump(300);
    const link_menu_before = w.menu;
    _ = try w.click(pl_point, .right, .{}, 800);
    const link_menu = if (w.menu != link_menu_before) w.menu else 0;
    const link_openable = w.flags.link and w.flags.link_openable;
    const before_menu = w.opened_len;
    if (link_menu != 0) try host.send(.{ .context_menu_command = .{ .browser = browser_id, .menu = link_menu, .command = .open_link_new_tab } });
    w.pump(800);
    const menu_opened = w.opened_len - before_menu;
    const menu_ok = menu_opened == 1 and w.lastIs(.background, port, "/title?t=nt-pl");
    const mail_before = w.menu;
    _ = try w.click(ml_point, .right, .{}, 800);
    const mail_menu = if (w.menu != mail_before) w.menu else 0;
    const mail_flags = w.flags;
    const before_mail = w.opened_len;
    if (mail_menu != 0) try host.send(.{ .context_menu_command = .{ .browser = browser_id, .menu = mail_menu, .command = .open_link_new_tab } });
    w.pump(800);
    const mail_ok = mail_menu != 0 and mail_flags.link and !mail_flags.link_openable and w.opened_len == before_mail;
    report(link_menu != 0 and link_openable and menu_ok and mail_ok, "newtab-menu", std.fmt.bufPrint(&detail, "링크 메뉴 {d} 열 수 있음 {} · 새 탭 {d} 뒤 {} · mailto: 열 수 있음 {} 새 탭 {d}", .{ link_menu, link_openable, menu_opened, menu_ok, mail_flags.link_openable, w.opened_len - before_mail }) catch "");

    // W6h①: 새 창에서 링크 열기·새 탭에서 이미지 열기.
    const win_before = w.menu;
    _ = try w.click(pl_point, .right, .{}, 800);
    const win_menu = if (w.menu != win_before) w.menu else 0;
    const before_win = w.opened_len;
    if (win_menu != 0) try host.send(.{ .context_menu_command = .{ .browser = browser_id, .menu = win_menu, .command = .open_link_new_window } });
    w.pump(800);
    const win_ok = w.opened_len == before_win + 1 and w.lastIs(.new_window, port, "/title?t=nt-pl");
    const img_before = w.menu;
    _ = try w.click(img_point, .right, .{}, 800);
    const img_menu = if (w.menu != img_before) w.menu else 0;
    const img_flags = w.flags;
    const before_img = w.opened_len;
    if (img_menu != 0) try host.send(.{ .context_menu_command = .{ .browser = browser_id, .menu = img_menu, .command = .open_image_new_tab } });
    w.pump(800);
    const img_ok = img_flags.image and img_flags.image_openable and w.opened_len == before_img + 1 and w.lastIs(.background, port, "/img/png/nt-image.png");
    const data_before = w.menu;
    _ = try w.click(data_img_point, .right, .{}, 800);
    const data_menu = if (w.menu != data_before) w.menu else 0;
    const data_flags = w.flags;
    const before_data = w.opened_len;
    if (data_menu != 0) try host.send(.{ .context_menu_command = .{ .browser = browser_id, .menu = data_menu, .command = .open_image_new_tab } });
    w.pump(800);
    const data_ok = data_menu != 0 and data_flags.image and !data_flags.image_openable and w.opened_len == before_data;
    report(win_menu != 0 and win_ok and img_menu != 0 and img_ok and data_ok, "newtab-menu-window-image", std.fmt.bufPrint(&detail, "새 창 메뉴 {d} 새 창 자리로 그 링크 {} · 이미지 메뉴 {d} 열 수 있음 {} 뒤 탭 {} · data: 열 수 있음 {} 새 탭 {d}", .{ win_menu, win_ok, img_menu, img_flags.image_openable, img_ok, data_flags.image_openable, w.opened_len - before_data }) catch "");

    const host_windows = windows.ownedBy(host.pid);
    const loads = http.newtab_requests.load(.monotonic) - loads_before;
    report(host_windows == 0 and loads == 0, "newtab-no-window", std.fmt.bufPrint(&detail, "host 창 {d} · 새 탭 주소 요청 {d}", .{ host_windows, loads }) catch "");
}
