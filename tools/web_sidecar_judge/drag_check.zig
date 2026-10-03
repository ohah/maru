//! W6d① 판정 — 밖에서 끌어 놓기(docs/plans/web-osr-backend.md W6). 판정자가 **maru 역할**로 `drag_data`·`drag_target` 을 보내고
//! `/dnd` 페이지가 제목으로 알린 것(받은 파일 이름·크기·내용, 끄는 동안 본 것, 글 칸 값)과 `drag_operation` 을 본다. 끌어 올
//! 파일은 판정 뿌리 아래에 만든다.
//!
//!   drag-file            파일 하나를 받는 칸에 — 끄는 동안 페이지는 파일을 못 본다(0 개), 놓으면 이름·크기·내용을 읽는다,
//!                        받아들이는 동작은 복사(1)
//!   drag-files-folder    파일 둘과 폴더 — 폴더 안 파일 이름과 내용까지 읽힌다(Chrome 과 같다 — 사용자 결정)
//!   drag-text            글 칸에 글 — 두 조각으로 보낸 글이 이어 붙어 들어간다(여러 줄·탭), 끄는 동안 다른 칸에서는 글이 안
//!                        읽힌다(길이 0)
//!   drag-html-url        HTML·주소·글을 함께 — 페이지가 `text/html`·`text/uri-list`·`text/plain` 으로 받는다
//!   drag-pieces-per-enter 조각은 그 enter 에만 — 나가기 없이 enter 가 두 번 오면 앞 enter 의 파일은 뒤 끌기에 섞이지 않는다
//!   drag-leave           들어왔다 나가면 dragleave, 그 뒤 온 놓기는 아무 일도 하지 않는다
//!   drag-no-enter        enter 없이 온 over·놓기는 버린다(조각만 보낸 뒤 놓아도 받지 않는다)
//!   drag-move-effect     페이지가 이동(16)을 고르면 그 동작이 온다
//!   drag-navigate        받지 않는 곳에 파일을 놓으면 그 파일로 이동한다(Chrome 과 같다 — 사용자 결정), 그 file:// 페이지는 옆
//!                        파일을 못 읽는다
//!   drag-javascript      받지 않는 곳에 `javascript:` 주소를 놓아도 실행되지 않는다 — 놓기는 일어났다(동작 복사, 주소가
//!                        `about:blank#blocked`)
//!   drag-renderer-gone   끄는 중 렌더러가 죽어도, 죽은 페이지에 enter·놓기가 와도 host 가 살고, 새 페이지에 다시 끌어 놓을 수
//!                        있다
//!   drag-unknown-browser 없는 브라우저의 끌기는 버리고 host 가 산다, 닫힌 브라우저에 남은 조각도 그렇다

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 29;
const wait_ms = 15_000;
const Point = protocol.message.Point;

const zone: Point = .{ .x = 160, .y = 100 };
const zone_edge: Point = .{ .x = 150, .y = 90 };
const textarea: Point = .{ .x = 160, .y = 250 };
const list: Point = .{ .x = 420, .y = 190 };
const blank: Point = .{ .x = 560, .y = 440 };
/// Finder 가 파일을 끌 때의 허용 동작(복사·링크·일반·이동).
const finder_ops: u32 = 1 | 2 | 4 | 16;

const Watch = struct {
    host: *Host,
    title_buf: [1024]u8 = undefined,
    title_len: usize = 0,
    url_buf: [1024]u8 = undefined,
    url_len: usize = 0,
    operation: ?u32 = null,
    operations: u32 = 0,
    renderer_gone: u32 = 0,

    fn title(self: *const Watch) []const u8 {
        return self.title_buf[0..self.title_len];
    }
    fn url(self: *const Watch) []const u8 {
        return self.url_buf[0..self.url_len];
    }
    fn step(self: *Watch) void {
        const m = (self.host.next(20) catch null) orelse return;
        switch (m) {
            .title_changed => |v| if (v.browser == browser_id) {
                self.title_len = @min(v.text.len, self.title_buf.len);
                @memcpy(self.title_buf[0..self.title_len], v.text[0..self.title_len]);
            },
            .url_changed => |v| if (v.browser == browser_id) {
                self.url_len = @min(v.url.len, self.url_buf.len);
                @memcpy(self.url_buf[0..self.url_len], v.url[0..self.url_len]);
            },
            .drag_operation => |v| if (v.browser == browser_id) {
                self.operation = v.operation;
                self.operations += 1;
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
    /// 제목(JSON 상태)에 그 조각이 있을 때까지.
    fn untilHas(self: *Watch, needle: []const u8, ms: u32) bool {
        return self.until(ms, needle, struct {
            fn f(w: *const Watch, n: []const u8) bool {
                return std.mem.indexOf(u8, w.title(), n) != null;
            }
        }.f);
    }
    fn has(self: *const Watch, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.title(), needle) != null;
    }
    /// 새로 불러온 `/dnd`(상태 `{"n":1,"ready":1}`)까지.
    fn load(self: *Watch, port: u16) !void {
        var u: [256]u8 = undefined;
        self.title_len = 0;
        try self.host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/dnd") } });
        if (!self.untilHas("{\"n\":1,\"ready\":1}", wait_ms)) return error.DragPageNotReady;
        self.pump(200);
    }
    fn data(self: *Watch, kind: protocol.message.DragDataKind, bytes: []const u8) !void {
        try self.host.send(.{ .drag_data = .{ .browser = browser_id, .kind = kind, .bytes = bytes } });
    }
    fn target(self: *Watch, kind: protocol.message.DragTargetKind, point: Point, allowed: u32) !void {
        const p: Point = if (kind == .leave) .{ .x = 0, .y = 0 } else point;
        const a: u32 = if (kind == .enter or kind == .over) allowed else 0;
        // maru 는 끌기에 버튼 비트를 싣지 않는다(끌기 세션에는 마우스 이벤트가 없다) — 같게 보낸다.
        try self.host.send(.{ .drag_target = .{ .browser = browser_id, .kind = kind, .point = p, .allowed = a } });
        self.pump(120);
    }
    /// enter 뒤 같은 자리 over 두 번 — 새 요소의 첫 over 는 동작 0 이다(착수 전 실측). macOS 는 멈춰 있어도 over 를 보낸다.
    fn enterOver(self: *Watch, point: Point, allowed: u32) !void {
        self.operation = null;
        try self.target(.enter, point, allowed);
        try self.target(.over, point, allowed);
        try self.target(.over, point, allowed);
        self.pump(200);
    }
};

fn writeFile(path: []const u8, body: []const u8) !void {
    var b: [1024]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&b, "{s}", .{path});
    const fd = std.c.open(z.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(c_uint, 0o644));
    if (fd < 0) return error.WriteFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, body.ptr, body.len) != @as(isize, @intCast(body.len))) return error.WriteFailed;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, root: []const u8, port: u16) !void {
    var detail: [600]u8 = undefined;
    // 끌어 올 파일들.
    var dir_buf: [512]u8 = undefined;
    const dir = try std.fmt.bufPrint(&dir_buf, "{s}/drag-files", .{root});
    var dz: [512]u8 = undefined;
    _ = std.c.mkdir((try std.fmt.bufPrintZ(&dz, "{s}", .{dir})).ptr, 0o700);
    var a_buf: [600]u8 = undefined;
    const file_a = try std.fmt.bufPrint(&a_buf, "{s}/a.txt", .{dir});
    try writeFile(file_a, "DRAG-CONTENT-A");
    var b_buf: [600]u8 = undefined;
    const file_b = try std.fmt.bufPrint(&b_buf, "{s}/둘.txt", .{dir});
    try writeFile(file_b, "TWO");
    var folder_buf: [600]u8 = undefined;
    const folder = try std.fmt.bufPrint(&folder_buf, "{s}/folder", .{dir});
    _ = std.c.mkdir((try std.fmt.bufPrintZ(&dz, "{s}", .{folder})).ptr, 0o700);
    var x_buf: [700]u8 = undefined;
    try writeFile(try std.fmt.bufPrint(&x_buf, "{s}/inner.txt", .{folder}), "IN-FOLDER");
    var h_buf: [600]u8 = undefined;
    const page_b = try std.fmt.bufPrint(&h_buf, "{s}/b.html", .{dir});
    var body_buf: [2048]u8 = undefined;
    try writeFile(page_b, try std.fmt.bufPrint(&body_buf, "<title>b</title><script>fetch('file://{s}').then(function(r){{return r.text()}}).then(function(t){{document.title='READ '+t}},function(e){{document.title='DENIED'}})</script>", .{file_a}));

    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    var u: [256]u8 = undefined;
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 640, .height = 480, .scale = 1 }, .hidden = false, .url = browsers_check.url(&u, port, "/dnd") } });
    var w: Watch = .{ .host = &host };
    if (!w.untilHas("{\"n\":1,\"ready\":1}", wait_ms)) return error.DragPageNotReady;
    try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });
    w.pump(200);

    // 파일 하나.
    try w.data(.path, file_a);
    try w.enterOver(zone, finder_ops);
    const saw_during = w.has("\"zover\":\"Files/f0/t0\"");
    const op_copy = w.operation != null and w.operation.? == 1;
    try w.target(.drop, zone, 0);
    const read = w.untilHas("\"zcontent\":\"DRAG-CONTENT-A\"", 4_000);
    report(saw_during and op_copy and w.has("\"zdrop\":\"a.txt:14/types=Files") and read, "drag-file", std.fmt.bufPrint(&detail, "끄는 동안 파일 0 개 {} · 동작 복사 {} · 놓은 뒤 {s}", .{ saw_during, op_copy, w.title() }) catch "");

    // 파일 둘과 폴더.
    try w.load(port);
    try w.data(.path, file_a);
    try w.data(.path, file_b);
    try w.data(.path, folder);
    try w.enterOver(zone, finder_ops);
    try w.target(.drop, zone, 0);
    const listed = w.untilHas("\"zdir\":\"inner.txt\"", 4_000) and w.untilHas("\"zdircontent\":\"IN-FOLDER\"", 4_000);
    report(listed and w.has("a.txt:14,둘.txt:3,folder:"), "drag-files-folder", std.fmt.bufPrint(&detail, "{s}", .{w.title()}) catch "");

    // 글 두 조각 — 먼저 받는 칸 위를 지나며(끄는 동안 글은 안 읽힌다) 글 칸에 놓는다.
    try w.load(port);
    try w.data(.text, "첫 줄\n");
    try w.data(.text, "둘째\t끝");
    try w.enterOver(zone, finder_ops);
    const hidden = w.has("\"zover\":\"text/plain/f0/t0\"");
    try w.target(.over, textarea, finder_ops);
    try w.target(.over, textarea, finder_ops);
    w.pump(200);
    try w.target(.drop, textarea, 0);
    const typed = w.untilHas("\"ta\":\"첫 줄\\n둘째\\t끝\"", 3_000);
    report(hidden and typed, "drag-text", std.fmt.bufPrint(&detail, "끄는 동안 글 안 읽힘 {} · {s}", .{ hidden, w.title() }) catch "");

    // HTML·주소·글을 함께.
    try w.load(port);
    try w.data(.html, "<b>bold</b>");
    try w.data(.url, "https://example.test/x");
    try w.data(.url_title, "제목");
    try w.data(.text, "plain words");
    try w.enterOver(zone, finder_ops);
    try w.target(.drop, zone, 0);
    const rich = w.untilHas("zdrop", 3_000);
    report(rich and w.has("text/html") and w.has("text/uri-list") and w.has("/text=plain words") and w.has("/uri=https://example.test/x") and w.has("<b>bold</b>"), "drag-html-url", std.fmt.bufPrint(&detail, "{s}", .{w.title()}) catch "");

    // 나가기 없이 enter 두 번 — 앞 enter 의 조각은 그 enter 에만.
    try w.load(port);
    try w.data(.path, file_a);
    try w.target(.enter, zone, finder_ops);
    try w.data(.path, file_b);
    try w.enterOver(zone, finder_ops);
    try w.target(.drop, zone, 0);
    const second = w.untilHas("zdrop", 3_000);
    report(second and w.has("\"zdrop\":\"둘.txt:3/types"), "drag-pieces-per-enter", std.fmt.bufPrint(&detail, "뒤 끌기만 {s}", .{w.title()}) catch "");

    // 들어왔다 나간 뒤의 놓기.
    try w.load(port);
    try w.data(.path, file_a);
    try w.enterOver(zone, finder_ops);
    try w.target(.leave, zone, 0);
    const left = w.untilHas("\"zleave\":1", 2_000);
    try w.target(.drop, zone, 0);
    w.pump(800);
    report(left and !w.has("zdrop"), "drag-leave", std.fmt.bufPrint(&detail, "나가기 {} · 그 뒤 놓기 없음 {} · {s}", .{ left, !w.has("zdrop"), w.title() }) catch "");

    // enter 없는 over·놓기.
    try w.load(port);
    try w.data(.path, file_a);
    try w.target(.over, zone, finder_ops);
    try w.target(.drop, zone, 0);
    w.pump(800);
    report(!w.has("zdrop") and !w.has("zover"), "drag-no-enter", std.fmt.bufPrint(&detail, "{s}", .{w.title()}) catch "");

    // 페이지가 이동을 고른다.
    try w.load(port);
    try w.data(.text, "move me");
    try w.enterOver(list, finder_ops);
    const op_move = w.operation != null and w.operation.? == 16;
    try w.target(.drop, list, 0);
    const moved = w.untilHas("\"Ldrop\":\"move me\"", 2_000);
    report(op_move and moved, "drag-move-effect", std.fmt.bufPrint(&detail, "동작 {?d}(16 이어야) · {s}", .{ w.operation, w.title() }) catch "");

    // 받지 않는 곳에 파일 — 그 파일로 이동, 그 페이지는 옆 파일을 못 읽는다.
    try w.load(port);
    try w.data(.path, page_b);
    try w.enterOver(blank, finder_ops);
    try w.target(.drop, blank, 0);
    const went = w.until(4_000, {}, struct {
        fn f(x: *const Watch, _: void) bool {
            return std.mem.startsWith(u8, x.url(), "file://") and std.mem.endsWith(u8, x.url(), "/b.html");
        }
    }.f);
    const denied = w.until(4_000, {}, struct {
        fn f(x: *const Watch, _: void) bool {
            return std.mem.eql(u8, x.title(), "DENIED");
        }
    }.f);
    report(went and denied, "drag-navigate", std.fmt.bufPrint(&detail, "이동 {} 「{s}」 · 옆 파일 {s}", .{ went, w.url(), w.title() }) catch "");

    // 받지 않는 곳에 javascript: 주소.
    try w.load(port);
    try w.data(.url, "javascript:document.title='PWNED'");
    try w.enterOver(blank, finder_ops);
    const js_op = w.operation;
    try w.target(.drop, blank, 0);
    const blocked = w.until(3_000, {}, struct {
        fn f(x: *const Watch, _: void) bool {
            return std.mem.eql(u8, x.url(), "about:blank#blocked");
        }
    }.f);
    w.pump(500);
    // 양성 대조 — 놓기가 실제로 일어났다(동작이 0 이면 CEF 가 놓기를 나가기로 바꿔 아무 일도 없이 통과했을 것이다).
    report(js_op != null and js_op.? != 0 and blocked and !w.has("PWNED"), "drag-javascript", std.fmt.bufPrint(&detail, "동작 {?d} · 주소 「{s}」(about:blank#blocked 여야) · 제목 「{s}」", .{ js_op, w.url(), w.title() }) catch "");

    // 끄는 중 렌더러가 죽는다.
    try w.load(port);
    try w.data(.path, file_a);
    try w.enterOver(zone, finder_ops);
    var kids_buf: [64]c_int = undefined;
    var killed: u32 = 0;
    for (os.children(host.pid, &kids_buf)) |kid| {
        if (os.argsContain(kid, "--type=renderer")) {
            _ = std.c.kill(kid, std.c.SIG.KILL);
            killed += 1;
        }
    }
    const gone = w.until(5_000, {}, struct {
        fn f(x: *const Watch, _: void) bool {
            return x.renderer_gone > 0;
        }
    }.f);
    try w.target(.over, zone, finder_ops);
    try w.target(.drop, zone, 0);
    // 죽은 페이지(다시 불러오기 전)에 새 끌기가 들어와 놓인다.
    try w.data(.path, file_a);
    try w.enterOver(zone, finder_ops);
    try w.target(.drop, zone, 0);
    w.pump(500);
    try w.load(port);
    try w.data(.path, file_a);
    try w.enterOver(zone, finder_ops);
    try w.target(.drop, zone, 0);
    const again = w.untilHas("\"zcontent\":\"DRAG-CONTENT-A\"", 4_000);
    report(killed >= 1 and gone and again, "drag-renderer-gone", std.fmt.bufPrint(&detail, "죽인 렌더러 {d} · renderer_gone {} · 새 페이지에 다시 놓기 {}", .{ killed, gone, again }) catch "");

    // 없는 브라우저·닫힌 브라우저에 남은 조각.
    try host.send(.{ .drag_data = .{ .browser = 999, .kind = .path, .bytes = file_a } });
    try host.send(.{ .drag_target = .{ .browser = 999, .kind = .enter, .point = zone, .allowed = 1 } });
    try host.send(.{ .drag_target = .{ .browser = 999, .kind = .drop, .point = zone } });
    const other: u64 = browser_id + 1;
    try host.send(.{ .create_browser = .{ .browser = other, .size = .{ .width = 320, .height = 240, .scale = 1 }, .hidden = false, .url = browsers_check.url(&u, port, "/dnd") } });
    w.pump(1_500);
    try host.send(.{ .drag_data = .{ .browser = other, .kind = .path, .bytes = file_a } });
    try host.send(.{ .drag_data = .{ .browser = other, .kind = .text, .bytes = "left behind" } });
    try host.send(.{ .destroy_browser = other });
    w.pump(1_000);
    try w.load(port);
    try w.data(.path, file_a);
    try w.enterOver(zone, finder_ops);
    try w.target(.drop, zone, 0);
    const alive = w.untilHas("\"zcontent\":\"DRAG-CONTENT-A\"", 4_000);
    report(alive, "drag-unknown-browser", std.fmt.bufPrint(&detail, "없는 브라우저의 끌기·닫힌 브라우저의 조각 뒤에도 놓기 {}", .{alive}) catch "");
}
