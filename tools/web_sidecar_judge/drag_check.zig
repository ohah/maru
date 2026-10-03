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
//!
//! W6d② 끌어내기(페이지가 시작한 끌기 — `drag_out`):
//!   drag-out-start       끌 요소를 누르고 끌면 `drag_out` 이 온다 — 허용 동작(복사·이동), 글, PNG 그림(크기·잡은 자리), 번호
//!   drag-out-into-page   그 끌기를 같은 페이지 목록에 `source` 로 enter·놓기, 끝(이동) — 목록이 글과 **사용자 정의 형식**을 받고 끌 요소는
//!                        dragend 이동, 페이지는 mouseup 을 받지 않는다
//!   drag-out-other-tab   다른 브라우저에 `source` 로 놓기 — 그 탭이 같은 데이터를 받는다
//!   drag-out-cancel      끝(0) — dragend none
//!   drag-out-link        링크 끌기 — 주소·제목(CEF 는 `title` 속성이 아니라 링크 글을 준다)·글(주소), 끝 뒤 aend
//!   drag-out-long-text   모두 선택한 뒤(누르고 쉬었다) 끌면 16 KiB 넘는 글이 조각으로 와 이어 붙는다(UTF-8)
//!   drag-out-answer-gates 답하기 전에는 새 끌기가 시작되지 않는다(Chromium 이 앞 끌기를 붙든다 — maru 는 아무 창도 가져가지 않은 끌기를
//!                        1 초 뒤 취소로 답한다), 답하면(none) 다음 끌기가 되고, 앞 번호의 늦은 끝은 버린다
//!   drag-out-closed      끌기 중 그 브라우저가 닫혀도 host 가 살고 다음 끌기가 된다

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
    /// 페이지 끌기(W6d②) — 마지막 `drag_out` 과 그 번호의 조각.
    out: ?protocol.message.DragOut = null,
    outs: u32 = 0,
    out_text: std.ArrayList(u8) = .empty,
    out_url: std.ArrayList(u8) = .empty,
    out_title: std.ArrayList(u8) = .empty,
    out_png: std.ArrayList(u8) = .empty,
    out_piece_drag: u32 = 0,

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
            .drag_out_data => |v| {
                if (v.drag != self.out_piece_drag) {
                    self.out_piece_drag = v.drag;
                    self.out_text.clearRetainingCapacity();
                    self.out_url.clearRetainingCapacity();
                    self.out_title.clearRetainingCapacity();
                    self.out_png.clearRetainingCapacity();
                }
                const into = switch (v.kind) {
                    .text => &self.out_text,
                    .url => &self.out_url,
                    .url_title => &self.out_title,
                    .image_png => &self.out_png,
                    .html => return,
                };
                into.appendSlice(std.heap.c_allocator, v.bytes) catch {};
            },
            .drag_out => |v| {
                self.out = v;
                self.outs += 1;
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

/// 페이지 안을 누르고 조금씩 끈다(왼쪽 누른 채). `hold` 는 누른 뒤 쉬는 시간(선택한 글은 Blink 의 Mac 글 끌기 지연을 넘겨야 한다).
fn pressDrag(w: *Watch, from: Point, to: Point, hold: u32) !void {
    try w.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .move, .point = from } });
    try w.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .down, .button = .left, .point = from, .modifiers = .{ .left_button = true }, .click_count = 1 } });
    w.pump(hold);
    var i: i32 = 1;
    while (i <= 6) : (i += 1) {
        const p: Point = .{ .x = from.x + @divTrunc((to.x - from.x) * i, 6), .y = from.y + @divTrunc((to.y - from.y) * i, 6) };
        try w.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .move, .point = p, .modifiers = .{ .left_button = true } } });
        w.pump(40);
    }
}

/// 새 `drag_out` 이 올 때까지(최대 `ms`).
fn untilOut(w: *Watch, before: u32, ms: u32) bool {
    return w.until(ms, before, struct {
        fn f(x: *const Watch, b: u32) bool {
            return x.outs > b;
        }
    }.f);
}

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
    const moved = w.untilHas("\"Ldrop\":\"move me|\"", 2_000);
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

    try dragOutChecks(report, &w, &host, port);

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

const drag_point: Point = .{ .x = 420, .y = 45 };
const link_point: Point = .{ .x = 380, .y = 310 };
const text_point: Point = .{ .x = 60, .y = 342 };

fn dragOutChecks(report: Report, w: *Watch, host: *Host, port: u16) !void {
    var detail: [600]u8 = undefined;

    // 시작.
    try w.load(port);
    var before = w.outs;
    try pressDrag(w, drag_point, .{ .x = 420, .y = 120 }, 0);
    const started = untilOut(w, before, 3_000);
    const out = w.out orelse protocol.message.DragOut{ .browser = 0, .drag = 0, .allowed = 0, .point = .{ .x = 0, .y = 0 } };
    const png_ok = w.out_png.items.len > 8 and std.mem.startsWith(u8, w.out_png.items, "\x89PNG\r\n\x1a\n");
    const image_ok = out.image_width > 0 and out.image_height > 0 and out.hotspot.x <= out.image_width and out.hotspot.y <= out.image_height;
    report(started and out.drag != 0 and out.allowed == (1 | 16) and std.mem.eql(u8, w.out_text.items, "hello-drag") and png_ok and image_ok, "drag-out-start", std.fmt.bufPrint(&detail, "drag_out {} · 번호 {d} · 허용 {d}(17 이어야) · 글 「{s}」 · PNG {d} 바이트 {} · 그림 {d}x{d} 잡은 자리 {d},{d}", .{ started, out.drag, out.allowed, w.out_text.items, w.out_png.items.len, png_ok, out.image_width, out.image_height, out.hotspot.x, out.hotspot.y }) catch "");

    // 같은 페이지 목록에 source 로 — 사용자 정의 형식까지.
    const drag = out.drag;
    try host.send(.{ .drag_target = .{ .browser = browser_id, .kind = .enter, .point = .{ .x = 420, .y = 150 }, .allowed = 1 | 16, .source = drag } });
    w.pump(120);
    try w.target(.over, .{ .x = 420, .y = 190 }, 1 | 16);
    try w.target(.over, .{ .x = 420, .y = 191 }, 1 | 16);
    w.pump(200);
    try w.target(.drop, .{ .x = 420, .y = 191 }, 0);
    try host.send(.{ .drag_source_end = .{ .browser = browser_id, .drag = drag, .point = .{ .x = 420, .y = 191 }, .operation = 16 } });
    const landed = w.untilHas("\"Ldrop\":\"hello-drag|secret-type\"", 3_000);
    const ended = w.untilHas("\"dend\":\"move1\"", 3_000);
    w.pump(300);
    report(landed and ended and !w.has("\"up\""), "drag-out-into-page", std.fmt.bufPrint(&detail, "목록이 글·사용자 정의 형식 {} · dragend 이동 {} · mouseup 없음 {} · {s}", .{ landed, ended, !w.has("\"up\""), w.title() }) catch "");

    // 다른 브라우저에 source 로.
    try w.load(port);
    var other_buf: [256]u8 = undefined;
    const other: u64 = browser_id + 2;
    try host.send(.{ .create_browser = .{ .browser = other, .size = .{ .width = 640, .height = 480, .scale = 1 }, .hidden = false, .url = browsers_check.url(&other_buf, port, "/dnd") } });
    w.pump(2_500);
    before = w.outs;
    try pressDrag(w, drag_point, .{ .x = 420, .y = 120 }, 0);
    const other_started = untilOut(w, before, 3_000);
    const other_drag = if (w.out) |o| o.drag else 0;
    try host.send(.{ .drag_target = .{ .browser = other, .kind = .enter, .point = .{ .x = 420, .y = 150 }, .allowed = 1 | 16, .source = other_drag } });
    w.pump(120);
    inline for (.{ 190, 191 }) |y| {
        try host.send(.{ .drag_target = .{ .browser = other, .kind = .over, .point = .{ .x = 420, .y = y }, .allowed = 1 | 16 } });
        w.pump(150);
    }
    try host.send(.{ .drag_target = .{ .browser = other, .kind = .drop, .point = .{ .x = 420, .y = 191 } } });
    try host.send(.{ .drag_source_end = .{ .browser = browser_id, .drag = other_drag, .point = .{ .x = 0, .y = 0 }, .operation = 16 } });
    const source_ended = w.untilHas("\"dend\":\"move1\"", 3_000);
    // 다른 탭의 제목은 Watch 가 보지 않는다 — 판정자는 그 탭의 목록 값을 직접 묻지 못하니 그 탭을 이 Watch 로 옮겨 본다.
    var other_title: [256]u8 = undefined;
    const other_got = otherTitle(w, other, &other_title, 2_000);
    try host.send(.{ .destroy_browser = other });
    w.pump(500);
    report(other_started and source_ended and std.mem.indexOf(u8, other_got, "\"Ldrop\":\"hello-drag|secret-type\"") != null, "drag-out-other-tab", std.fmt.bufPrint(&detail, "보낸 탭 dragend 이동 {} · 받은 탭 「{s}」", .{ source_ended, other_got }) catch "");

    // 취소.
    try w.load(port);
    before = w.outs;
    try pressDrag(w, drag_point, .{ .x = 420, .y = 120 }, 0);
    const cancel_started = untilOut(w, before, 3_000);
    if (w.out) |o| try host.send(.{ .drag_source_end = .{ .browser = browser_id, .drag = o.drag, .point = .{ .x = 900, .y = 900 }, .operation = 0 } });
    const cancelled = w.untilHas("\"dend\":\"none1\"", 3_000);
    report(cancel_started and cancelled, "drag-out-cancel", std.fmt.bufPrint(&detail, "{s}", .{w.title()}) catch "");

    // 링크.
    try w.load(port);
    before = w.outs;
    try pressDrag(w, link_point, .{ .x = 380, .y = 420 }, 0);
    const link_started = untilOut(w, before, 3_000);
    var want_buf: [256]u8 = undefined;
    const want = browsers_check.url(&want_buf, port, "/title?t=linked");
    const link_ok = std.mem.eql(u8, w.out_url.items, want) and std.mem.eql(u8, w.out_title.items, "a link") and std.mem.eql(u8, w.out_text.items, want);
    if (w.out) |o| try host.send(.{ .drag_source_end = .{ .browser = browser_id, .drag = o.drag, .point = .{ .x = 380, .y = 420 }, .operation = 1 } });
    const link_ended = w.untilHas("\"aend\":\"copy\"", 3_000);
    report(link_started and link_ok and link_ended, "drag-out-link", std.fmt.bufPrint(&detail, "주소 「{s}」 · 제목 「{s}」 · 글 「{s}」 · aend copy {}", .{ w.out_url.items, w.out_title.items, w.out_text.items, link_ended }) catch "");

    // 모두 선택한 긴 글(누르고 쉬었다 끈다).
    try w.load(port);
    try host.send(.{ .edit_command = .{ .browser = browser_id, .command = .select_all } });
    w.pump(400);
    before = w.outs;
    try pressDrag(w, text_point, .{ .x = 60, .y = 440 }, 400);
    const text_started = untilOut(w, before, 3_000);
    const long_ok = w.out_text.items.len > protocol.wire.max_ime_text_bytes and std.unicode.utf8ValidateSlice(w.out_text.items) and std.mem.count(u8, w.out_text.items, "가") == 6000;
    if (w.out) |o| try host.send(.{ .drag_source_end = .{ .browser = browser_id, .drag = o.drag, .point = .{ .x = 60, .y = 440 }, .operation = 0 } });
    w.pump(300);
    report(text_started and long_ok, "drag-out-long-text", std.fmt.bufPrint(&detail, "글 {d} 바이트(16 KiB 넘게) · UTF-8 {} · 「가」 {d} 자(6000 이어야)", .{ w.out_text.items.len, std.unicode.utf8ValidateSlice(w.out_text.items), std.mem.count(u8, w.out_text.items, "가") }) catch "");

    // 답하기 전에는 새 끌기가 시작되지 않는다 — 답하면 된다, 늦은 끝은 버린다.
    try w.load(port);
    before = w.outs;
    try pressDrag(w, drag_point, .{ .x = 420, .y = 120 }, 0);
    _ = untilOut(w, before, 3_000);
    const first = if (w.out) |o| o.drag else 0;
    try w.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .up, .button = .left, .point = .{ .x = 420, .y = 120 }, .click_count = 1 } });
    w.pump(200);
    before = w.outs;
    try pressDrag(w, drag_point, .{ .x = 420, .y = 120 }, 0);
    const held_back = !untilOut(w, before, 1_000);
    try w.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .up, .button = .left, .point = .{ .x = 420, .y = 120 }, .click_count = 1 } });
    try host.send(.{ .drag_source_end = .{ .browser = browser_id, .drag = first, .point = .{ .x = 0, .y = 0 }, .operation = 0 } });
    const first_cancelled = w.untilHas("\"dend\":\"none1\"", 3_000);
    before = w.outs;
    try pressDrag(w, drag_point, .{ .x = 420, .y = 120 }, 0);
    const second_started = untilOut(w, before, 3_000);
    const second = if (w.out) |o| o.drag else 0;
    try host.send(.{ .drag_source_end = .{ .browser = browser_id, .drag = first, .point = .{ .x = 0, .y = 0 }, .operation = 16 } });
    w.pump(300);
    const stale_ignored = !w.has("\"dend\":\"move");
    try host.send(.{ .drag_source_end = .{ .browser = browser_id, .drag = second, .point = .{ .x = 0, .y = 0 }, .operation = 1 } });
    const second_ended = w.untilHas("\"dend\":\"copy2\"", 3_000);
    report(held_back and first_cancelled and second_started and second != first and stale_ignored and second_ended, "drag-out-answer-gates", std.fmt.bufPrint(&detail, "답 전 새 끌기 없음 {} · 답(none) {} · 다음 끌기 {} · 늦은 끝 버림 {} · 뒤 끌기 copy {} · {s}", .{ held_back, first_cancelled, second_started, stale_ignored, second_ended, w.title() }) catch "");

    // 끌기 중 그 브라우저가 닫힌다.
    var closing_buf: [256]u8 = undefined;
    const closing: u64 = browser_id + 3;
    try host.send(.{ .create_browser = .{ .browser = closing, .size = .{ .width = 640, .height = 480, .scale = 1 }, .hidden = false, .url = browsers_check.url(&closing_buf, port, "/dnd") } });
    w.pump(2_500);
    try host.send(.{ .mouse = .{ .browser = closing, .kind = .move, .point = drag_point } });
    try host.send(.{ .mouse = .{ .browser = closing, .kind = .down, .button = .left, .point = drag_point, .modifiers = .{ .left_button = true }, .click_count = 1 } });
    var k: i32 = 1;
    while (k <= 6) : (k += 1) {
        try host.send(.{ .mouse = .{ .browser = closing, .kind = .move, .point = .{ .x = 420, .y = 45 + k * 12 }, .modifiers = .{ .left_button = true } } });
        w.pump(40);
    }
    w.pump(500);
    const closing_drag = if (w.out) |o| (if (o.browser == closing) o.drag else 0) else 0;
    try host.send(.{ .destroy_browser = closing });
    w.pump(800);
    if (closing_drag != 0) try host.send(.{ .drag_source_end = .{ .browser = closing, .drag = closing_drag, .point = .{ .x = 0, .y = 0 }, .operation = 1 } });
    try w.load(port);
    before = w.outs;
    try pressDrag(w, drag_point, .{ .x = 420, .y = 120 }, 0);
    const after_close = untilOut(w, before, 3_000);
    if (w.out) |o| try host.send(.{ .drag_source_end = .{ .browser = browser_id, .drag = o.drag, .point = .{ .x = 0, .y = 0 }, .operation = 0 } });
    w.pump(300);
    report(closing_drag != 0 and after_close, "drag-out-closed", std.fmt.bufPrint(&detail, "닫힌 탭의 끌기 {d} · 그 뒤 끌기 {}", .{ closing_drag, after_close }) catch "");
}

/// 다른 브라우저의 마지막 제목(Watch 는 판정 브라우저 것만 든다 — 그동안 온 메시지에서 찾는다).
fn otherTitle(w: *Watch, other: u64, buf: []u8, ms: u32) []const u8 {
    var len: usize = 0;
    const deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline) {
        const m = (w.host.next(20) catch null) orelse continue;
        switch (m) {
            .title_changed => |v| if (v.browser == other) {
                len = @min(v.text.len, buf.len);
                @memcpy(buf[0..len], v.text[0..len]);
                if (std.mem.indexOf(u8, buf[0..len], "Ldrop") != null) break;
            },
            else => {},
        }
    }
    return buf[0..len];
}
