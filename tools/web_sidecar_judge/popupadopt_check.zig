//! W6f① 판정 — 페이지가 연 팝업을 이어 받기(docs/plans/web-osr-backend.md W6). 판정자가 **maru 역할**로 번호를 맡기고
//! (`popup_reserve`) `popup_created`·팝업 브라우저의 알림을 받는다. 탭을 붙이는 것은 maru(W6f②)라 여기서는 sidecar 가 팝업을 맡긴
//! 번호로 등록하고 원래 페이지와 이어 두는지만 본다. 페이지는 `/pa`.
//!
//!   adopt-created       맡긴 번호가 있으면 `window.open` 이 그 번호의 `popup_created`(연 탭·앞·주소)가 되고 `open_tab` 은 없다
//!   adopt-opener        팝업이 `window.opener.postMessage` 로 원래 페이지에 닿고, 팝업 브라우저의 제목이 그 번호로 온다
//!   adopt-named         같은 이름으로 두 번 열면 팝업은 하나(두 번째는 같은 창 — 페이지가 `a === b`)
//!   adopt-close         원래 페이지의 `w.close()` → 그 번호의 `browser_closed`, 원래 페이지는 `closed` 를 본다
//!   adopt-destroy       maru 가 닫으면(`destroy_browser` — 붙일 수 없을 때) 원래 페이지는 `closed` 를 본다
//!   adopt-blank         빈 팝업(`window.open('')`)도 이어 받고(`about:blank`) 원래 페이지가 그 문서에 쓴다
//!   adopt-one-per-input 한 번 클릭에 `window.open` 10 번 — 맡긴 번호가 남아도 팝업 하나
//!   adopt-nested        팝업 안의 클릭으로 연 팝업도 이어 받는다(연 탭은 그 팝업 번호)
//!   adopt-fallback      맡긴 번호가 없으면 주소만(`open_tab` — W6e), 이미 쓰는 번호를 맡겨도 쓰지 않는다
//!   adopt-no-window     그동안 host 창 0 개

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");
const windows = @import("windows.zig");

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 29;
const wait_ms = 15_000;
const Point = protocol.message.Point;

const op_point: Point = .{ .x = 60, .y = 25 };
const nm_point: Point = .{ .x = 200, .y = 25 };
const cl_point: Point = .{ .x = 340, .y = 25 };
const bw_point: Point = .{ .x = 480, .y = 25 };
const m10_point: Point = .{ .x = 60, .y = 75 };
const blank_point: Point = .{ .x = 520, .y = 360 };

const Created = struct { opener: u64, browser: u64, placement: protocol.message.NewTabPlacement, url: [256]u8 = undefined, url_len: usize = 0 };

const Watch = struct {
    host: *Host,
    created: [16]Created = undefined,
    created_len: usize = 0,
    open_tabs: u32 = 0,
    closed: [16]u64 = undefined,
    closed_len: usize = 0,
    title_buf: [1024]u8 = undefined,
    title_len: usize = 0,
    /// 팝업 브라우저들의 마지막 제목(번호별 — 넷까지).
    popup_titles: [4]struct { id: u64 = 0, buf: [128]u8 = undefined, len: usize = 0 } = .{ .{}, .{}, .{}, .{} },

    fn title(self: *const Watch) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    fn popupTitle(self: *const Watch, id: u64) []const u8 {
        for (&self.popup_titles) |*t| if (t.id == id) return t.buf[0..t.len];
        return "";
    }
    fn wasClosed(self: *const Watch, id: u64) bool {
        for (self.closed[0..self.closed_len]) |c| if (c == id) return true;
        return false;
    }

    fn step(self: *Watch) void {
        const m = (self.host.next(20) catch null) orelse return;
        switch (m) {
            .popup_created => |v| if (self.created_len < self.created.len) {
                var c: Created = .{ .opener = v.opener, .browser = v.browser, .placement = v.placement };
                c.url_len = @min(v.url.len, c.url.len);
                @memcpy(c.url[0..c.url_len], v.url[0..c.url_len]);
                self.created[self.created_len] = c;
                self.created_len += 1;
            },
            .open_tab => |v| if (v.browser == browser_id) {
                self.open_tabs += 1;
            },
            .browser_closed => |id| if (self.closed_len < self.closed.len) {
                self.closed[self.closed_len] = id;
                self.closed_len += 1;
            },
            .title_changed => |v| if (v.browser == browser_id) {
                self.title_len = @min(v.text.len, self.title_buf.len);
                @memcpy(self.title_buf[0..self.title_len], v.text[0..self.title_len]);
            } else {
                for (&self.popup_titles) |*t| if (t.id == v.browser or t.id == 0) {
                    t.id = v.browser;
                    t.len = @min(v.text.len, t.buf.len);
                    @memcpy(t.buf[0..t.len], v.text[0..t.len]);
                    break;
                };
            },
            else => {},
        }
    }
    fn pump(self: *Watch, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) self.step();
    }
    fn untilTitleHas(self: *Watch, needle: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (std.mem.indexOf(u8, self.title(), needle) != null) return true;
            self.step();
        }
        return std.mem.indexOf(u8, self.title(), needle) != null;
    }
    fn click(self: *Watch, browser: u64, point: Point) !void {
        try self.host.send(.{ .mouse = .{ .browser = browser, .kind = .move, .point = point } });
        try self.host.send(.{ .mouse = .{ .browser = browser, .kind = .down, .button = .left, .point = point, .modifiers = .{ .left_button = true }, .click_count = 1 } });
        try self.host.send(.{ .mouse = .{ .browser = browser, .kind = .up, .button = .left, .point = point, .click_count = 1 } });
    }
    fn reserve(self: *Watch, id: u64) !void {
        try self.host.send(.{ .popup_reserve = .{ .browser = id } });
    }
    fn last(self: *const Watch) ?*const Created {
        return if (self.created_len == 0) null else &self.created[self.created_len - 1];
    }
};

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail: [400]u8 = undefined;
    var u: [256]u8 = undefined;

    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 640, .height = 400, .scale = 1 }, .hidden = false, .url = browsers_check.url(&u, port, "/pa") } });
    var w: Watch = .{ .host = &host };
    if (!w.untilTitleHas("pa ready", wait_ms)) return error.AdoptPageNotReady;
    try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });
    w.pump(300);
    try w.click(browser_id, blank_point); // 새로 뜬 브라우저는 첫 입력을 잃을 수 있다(W7b)
    w.pump(300);

    // 번호를 맡기고 연다.
    try w.reserve(601);
    try w.reserve(602);
    w.pump(100);
    try w.click(browser_id, op_point);
    const got_msg = w.untilTitleHas("msg=from-popup", 4_000);
    w.pump(500);
    const first = w.last();
    var want: [256]u8 = undefined;
    const want_url = browsers_check.url(&want, port, "/pa-popup");
    const created_ok = w.created_len == 1 and first != null and first.?.opener == browser_id and first.?.browser == 601 and first.?.placement == .foreground and
        std.mem.eql(u8, first.?.url[0..first.?.url_len], want_url) and w.open_tabs == 0;
    report(created_ok, "adopt-created", std.fmt.bufPrint(&detail, "popup_created {d} 개 · 번호 {d} · 연 탭 {d} · open_tab {d}", .{ w.created_len, if (first) |f| f.browser else 0, if (first) |f| f.opener else 0, w.open_tabs }) catch "");
    const popup_title = w.popupTitle(601);
    report(got_msg and std.mem.eql(u8, popup_title, "pa-popup opener=true"), "adopt-opener", std.fmt.bufPrint(&detail, "원래 페이지 「{s}」 · 팝업 제목 「{s}」", .{ w.title(), popup_title }) catch "");

    // 같은 이름 둘 — 하나만.
    const before_named = w.created_len;
    try w.click(browser_id, nm_point);
    const named_done = w.untilTitleHas("same=", 4_000);
    w.pump(300);
    report(named_done and w.created_len == before_named + 1 and std.mem.indexOf(u8, w.title(), "same=true") != null, "adopt-named", std.fmt.bufPrint(&detail, "팝업 {d} 개 · 「{s}」", .{ w.created_len - before_named, w.title() }) catch "");

    // 원래 페이지가 닫는다.
    try w.click(browser_id, cl_point);
    const close_done = w.untilTitleHas("afterclose=", 4_000);
    w.pump(300);
    report(close_done and w.wasClosed(601) and std.mem.indexOf(u8, w.title(), "afterclose=true") != null, "adopt-close", std.fmt.bufPrint(&detail, "601 닫힘 알림 {} · 「{s}」", .{ w.wasClosed(601), w.title() }) catch "");

    // maru 가 닫는다(이름 창의 팝업).
    const named_id: u64 = if (w.created_len > before_named) w.created[before_named].browser else 0;
    if (named_id != 0) try host.send(.{ .destroy_browser = named_id });
    const named_closed = blk: {
        const deadline = os.nowMs() + 3_000;
        while (os.nowMs() < deadline and !w.wasClosed(named_id)) w.step();
        break :blk w.wasClosed(named_id);
    };
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = "javascript:void(document.title+=' nmclosed='+window.nm.closed)" } });
    const destroy_seen = w.untilTitleHas("nmclosed=true", 3_000);
    report(named_id != 0 and named_closed and destroy_seen, "adopt-destroy", std.fmt.bufPrint(&detail, "번호 {d} · 닫힘 알림 {} · 페이지가 본 닫힘 {}", .{ named_id, named_closed, destroy_seen }) catch "");

    // 빈 팝업.
    try w.reserve(603);
    w.pump(100);
    const before_blank = w.created_len;
    try w.click(browser_id, bw_point);
    const written = w.untilTitleHas("wtitle=written", 4_000);
    w.pump(300);
    const blank = if (w.created_len > before_blank) &w.created[before_blank] else null;
    report(written and blank != null and std.mem.eql(u8, blank.?.url[0..blank.?.url_len], "about:blank"), "adopt-blank", std.fmt.bufPrint(&detail, "팝업 {d} · 주소 「{s}」 · 「{s}」", .{ w.created_len - before_blank, if (blank) |b| b.url[0..b.url_len] else "", w.title() }) catch "");

    // 한 클릭에 10 번.
    try w.reserve(604);
    try w.reserve(605);
    w.pump(100);
    const before_many = w.created_len;
    const tabs_before_many = w.open_tabs;
    try w.click(browser_id, m10_point);
    w.pump(1_500);
    report(w.created_len == before_many + 1 and w.open_tabs == tabs_before_many, "adopt-one-per-input", std.fmt.bufPrint(&detail, "팝업 {d} · open_tab {d}", .{ w.created_len - before_many, w.open_tabs - tabs_before_many }) catch "");

    // 팝업 안에서 — 그 팝업(맨 마지막)에 누르면 또 연다.
    const parent: u64 = if (w.created_len > before_many) w.created[before_many].browser else 0;
    try w.reserve(606);
    w.pump(500);
    const before_nested = w.created_len;
    if (parent != 0) try w.click(parent, .{ .x = 100, .y = 100 });
    const nested_got = blk: {
        const deadline = os.nowMs() + 3_000;
        while (os.nowMs() < deadline and w.created_len == before_nested) w.step();
        break :blk w.created_len > before_nested;
    };
    const nested = if (nested_got) &w.created[before_nested] else null;
    report(parent != 0 and nested != null and nested.?.opener == parent, "adopt-nested", std.fmt.bufPrint(&detail, "부모 {d} · 새 팝업 {} · 연 탭 {d}", .{ parent, nested_got, if (nested) |n| n.opener else 0 }) catch "");

    // 번호가 없다 — 남은 것(605)을 이름 없는 창으로 다 쓴 뒤, 쓰는 번호(browser_id)를 맡겨도 쓰지 않는다.
    try w.click(browser_id, m10_point);
    w.pump(1_200);
    try w.reserve(browser_id);
    w.pump(100);
    const before_fallback = w.created_len;
    const tabs_before_fallback = w.open_tabs;
    try w.click(browser_id, m10_point);
    w.pump(1_200);
    report(w.created_len == before_fallback and w.open_tabs == tabs_before_fallback + 1, "adopt-fallback", std.fmt.bufPrint(&detail, "팝업 {d} · open_tab {d}", .{ w.created_len - before_fallback, w.open_tabs - tabs_before_fallback }) catch "");

    report(windows.ownedBy(host.pid) == 0, "adopt-no-window", std.fmt.bufPrint(&detail, "host 창 {d}", .{windows.ownedBy(host.pid)}) catch "");
}
