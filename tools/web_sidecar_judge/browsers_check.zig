//! W1c 판정 — 실제 브라우저를 만들어 docs/plans/web-osr-backend.md 「W1c」 완료 판정을 잰다.
//!
//!   browsers-created   브라우저 셋이 만들어지고 **셋 모두** 자기 페이지 제목을 알린다
//!   routed             한 브라우저에 보낸 이동은 그 브라우저의 알림으로만 돌아온다
//!   hidden-receives    숨긴 브라우저도 명령을 받고 페이지가 돈다 — 페이지가 스스로 `hidden` 이라 보고, 다시 보이면 `visible`
//!   resized            크기 변경이 페이지의 innerWidth 까지 닿는다
//!   destroyed          파괴하면 browser_closed, 그 뒤 명령은 unknown_browser
//!   duplicate-refused  같은 id 로 다시 만들면 duplicate_browser
//!   renderer-sandbox   렌더러를 포함한 helper 전부 샌드박스 안
//!   no-popup           `window.open` 이 창도, 보이지 않는 팝업 브라우저도 만들지 않는다(창 0 개·팝업 페이지 요청 0)
//!                      — 제스처 없는 `window.open` 은 Chromium 팝업 차단기가 먼저 막는다(처리기를 풀어도 통과)
//!   no-popup-js        `javascript:` 이동으로 부른 `window.open`(브라우저가 시작한 이동이라 팝업 차단기를 안 거친다)도
//!                      창 0 개·팝업 페이지 요청 0 — 우리 팝업 처리기가 막는다
//!   no-print           `window.print()` 가 인쇄 창을 띄우지 않고 바로 돌아온다(창 0 개)
//!   no-dialog          `alert`·`confirm`·`prompt` 가 창을 띄우지 않고 바로 돌아온다(confirm 은 false, prompt 는 null)
//!   title-flood        2 초 동안 제목을 약 40 만 번 바꾸는 페이지의 제목 알림이 조절되고(간격 50ms 기준 상한 안),
//!                      마지막 제목은 온다
//!   title-control      제어 문자가 든 제목도 온다(제어 문자는 공백으로) — codec 이 거절해 조용히 사라지지 않는다
//!   nav-actions        뒤로·앞으로가 대상 브라우저를 옮기고, 주소 알림(`url_changed`)·탐색 상태(`nav_state` 의 뒤로 가능)가
//!                      따라온다(W3b — 주소창)
//!   gpu-refused        CPU 경로로 그리게 한 host(`MARU_WEB_TEST_CPU_PAINT`)는 그 브라우저에 `gpu_unavailable` 을 알린다(D9)
//!   relaunch-refused   같은 프로필로 두 번째 host → profile_in_use·exit 16, 첫 host 는 창 0 개로 계속 돈다
//!   profile-private    프로필이 0700 이고 백업 제외 표시가 있다
//!   profile-refused    남이 읽을 수 있는 프로필(0755 · ACL 허용 항목 · 심볼릭 링크)은 쓰지 않고 exit 12
//!   login-persists     재시작 뒤에도 쿠키가 남는다(D6·D7 — mock keychain)
//!   shutdown-closes    shutdown 이 열린 브라우저를 모두 닫고(browser_closed) exit 0

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const windows = @import("windows.zig");
const sandbox = @import("sandbox.zig");
const Host = @import("host.zig").Host;
const http = @import("http.zig");

const Message = protocol.message.Message;
const BrowserId = protocol.message.BrowserId;
const FailureCode = protocol.message.FailureCode;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const wait_ms = 15_000;
const flood_title_limit = 60;
const size: protocol.message.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };

pub const Want = union(enum) {
    title: struct { browser: BrowserId, text: []const u8 },
    url_suffix: struct { browser: BrowserId, suffix: []const u8 },
    can_go_back: struct { browser: BrowserId, value: bool },
    created: BrowserId,
    closed: BrowserId,
    failure: struct { browser: BrowserId, code: FailureCode },
    cursor: struct { browser: BrowserId, cursor: protocol.message.WebCursor },
    /// 비지 않은 IME 조합 사각형.
    ime_range: BrowserId,
};

/// 기대한 제목이 **모두** 올 때까지 읽는다(도착 순서는 상관없다). 온 수를 돌려준다.
fn waitTitles(host: *Host, wants: []const Want, misrouted: *usize) usize {
    var got: [8]bool = @splat(false);
    var count: usize = 0;
    const deadline = os.nowMs() + wait_ms;
    while (count < wants.len and os.nowMs() < deadline) {
        const left: u32 = @intCast(@max(deadline - os.nowMs(), 1));
        const message = (host.next(left) catch break) orelse break;
        if (message != .title_changed) continue;
        for (wants, 0..) |want, i| {
            if (got[i] or !std.mem.eql(u8, message.title_changed.text, want.title.text)) continue;
            if (message.title_changed.browser == want.title.browser) {
                got[i] = true;
                count += 1;
            } else misrouted.* += 1;
        }
    }
    return count;
}

const Match = enum { hit, misrouted, none };

/// 알림 하나가 기대와 맞는가. **다른 브라우저**에서 같은 제목이 오면 잘못 간 것이다.
fn matches(want: Want, message: Message) Match {
    switch (want) {
        .title => |w| if (message == .title_changed) {
            const got = message.title_changed;
            if (std.mem.eql(u8, got.text, w.text)) return if (got.browser == w.browser) .hit else .misrouted;
        },
        .url_suffix => |w| if (message == .url_changed and message.url_changed.browser == w.browser and std.mem.endsWith(u8, message.url_changed.url, w.suffix)) return .hit,
        .can_go_back => |w| if (message == .nav_state and message.nav_state.browser == w.browser and !message.nav_state.loading and message.nav_state.can_go_back == w.value) return .hit,
        .created => |id| if (message == .browser_created and message.browser_created == id) return .hit,
        .closed => |id| if (message == .browser_closed and message.browser_closed == id) return .hit,
        .failure => |w| if (message == .failure and message.failure.browser == w.browser and message.failure.code == w.code) return .hit,
        .cursor => |w| if (message == .cursor_changed and message.cursor_changed.browser == w.browser and message.cursor_changed.cursor == w.cursor) return .hit,
        .ime_range => |id| if (message == .ime_range and message.ime_range.browser == id and message.ime_range.bounds.width > 0 and message.ime_range.bounds.height > 0) return .hit,
    }
    return .none;
}

/// 기대한 알림이 올 때까지 읽는다(그 사이 다른 알림은 버린다).
/// 알림 하나가 기대와 맞는가(`misrouted` 는 다른 브라우저에서 같은 제목이 오면 는다).
pub fn matchOne(want: Want, message: Message, misrouted: *usize) bool {
    return switch (matches(want, message)) {
        .hit => true,
        .misrouted => blk: {
            misrouted.* += 1;
            break :blk false;
        },
        .none => false,
    };
}

fn waitFor(host: *Host, want: Want, misrouted: *usize) bool {
    return waitAll(host, &.{want}, misrouted);
}

/// 기대한 알림이 **모두** 올 때까지 읽는다(도착 순서는 상관없다) — 제목은 조절(50ms)로 늦게 올 수 있어, 한 알림을
/// 기다리며 다른 알림을 버리면 이미 지나간 것을 놓친다.
fn waitAll(host: *Host, wants: []const Want, misrouted: *usize) bool {
    var got: [8]bool = @splat(false);
    var count: usize = 0;
    const deadline = os.nowMs() + wait_ms;
    while (count < wants.len and os.nowMs() < deadline) {
        const left: u32 = @intCast(@max(deadline - os.nowMs(), 1));
        const message = (host.next(left) catch return false) orelse return false;
        for (wants, 0..) |want, i| {
            if (got[i]) continue;
            switch (matches(want, message)) {
                .hit => {
                    got[i] = true;
                    count += 1;
                },
                .misrouted => misrouted.* += 1,
                .none => {},
            }
        }
    }
    return count == wants.len;
}

pub fn url(buf: []u8, port: u16, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path }) catch unreachable;
}

pub fn handshake(host: *Host) !void {
    try host.send(.{ .hello = .{ .instance = 1, .nonce = os.random64() } });
    const reply = (try host.next(wait_ms)) orelse return error.ClosedBeforeAck;
    if (reply != .hello_ack) return error.NoAck;
}

/// 이 프로필로 host 를 띄우면 쓰지 않고 exit 12(bad_arguments)로 끝나는가.
fn refuses(host_path: [:0]const u8, dir: [:0]const u8) bool {
    var arg_buf: [1100]u8 = undefined;
    const arg = std.fmt.bufPrintZ(&arg_buf, "--profile-dir={s}", .{dir}) catch return false;
    var host = Host.spawn(host_path, arg) catch return false;
    handshake(&host) catch return false;
    var failed = false;
    while (host.next(wait_ms) catch null) |message| {
        if (message == .failure and message.failure.code == .cef_initialize_failed) failed = true;
    }
    const code = host.wait(wait_ms);
    return failed and code != null and code.? == 12;
}

fn profileRefusals(report: Report, host_path: [:0]const u8, root: []const u8) void {
    var detail_buf: [256]u8 = undefined;
    var open_buf: [1024]u8 = undefined;
    var acl_buf: [1024]u8 = undefined;
    var link_buf: [1024]u8 = undefined;
    const open_dir = std.fmt.bufPrintZ(&open_buf, "{s}/refuse-0755", .{root}) catch return;
    const acl_dir = std.fmt.bufPrintZ(&acl_buf, "{s}/refuse-acl", .{root}) catch return;
    const link_dir = std.fmt.bufPrintZ(&link_buf, "{s}/refuse-link", .{root}) catch return;
    _ = std.c.mkdir(open_dir, 0o755);
    _ = std.c.chmod(open_dir, 0o755);
    _ = std.c.mkdir(acl_dir, 0o700);
    const acl_set = os.run(&.{ "/bin/chmod", "+a", "everyone allow list,search,read", acl_dir });
    const link_set = std.c.symlink(acl_dir, link_dir) == 0;
    const open_refused = refuses(host_path, open_dir);
    const acl_refused = refuses(host_path, acl_dir);
    const link_refused = refuses(host_path, link_dir);
    // 링크가 가리키는 곳은 ACL 로 거절되는 자리다 — 링크만 따로 재려고 가리킬 곳을 0700 깨끗한 디렉터리로 바꾼다.
    _ = os.run(&.{ "/bin/chmod", "-N", acl_dir });
    const link_only_refused = refuses(host_path, link_dir);
    report(open_refused and acl_set and acl_refused and link_set and link_refused and link_only_refused, "profile-refused", std.fmt.bufPrint(&detail_buf, "0755 {} · ACL 허용(설정 {}) {} · 심볼릭 링크(설정 {}) {} · 깨끗한 곳을 가리키는 링크 {}", .{ open_refused, acl_set, acl_refused, link_set, link_refused, link_only_refused }) catch "");
}

/// D9 — CPU 경로로 그리게 한 host 는 그 브라우저에 `gpu_unavailable` 을 알린다. 따로 띄운다(판정자 전용 훅이 켜진 host).
fn gpuRefusal(report: Report, host_path: [:0]const u8, root: []const u8, port: u16) void {
    var detail_buf: [256]u8 = undefined;
    var arg_buf: [1100]u8 = undefined;
    const arg = std.fmt.bufPrintZ(&arg_buf, "--profile-dir={s}/gpu", .{root}) catch return;
    var host = Host.spawnWith(host_path, arg, null, &.{"MARU_WEB_TEST_CPU_PAINT=1"}) catch return report(false, "gpu-refused", "spawn");
    handshake(&host) catch return report(false, "gpu-refused", "handshake");
    var u: [256]u8 = undefined;
    host.send(.{ .create_browser = .{ .browser = 7, .size = size, .hidden = false, .url = url(&u, port, "/title?t=cpu") } }) catch return report(false, "gpu-refused", "send");
    var misrouted: usize = 0;
    const refused = waitFor(&host, .{ .failure = .{ .browser = 7, .code = .gpu_unavailable } }, &misrouted);
    host.send(.shutdown) catch {};
    while (host.next(wait_ms) catch null) |_| {}
    const code = host.wait(wait_ms);
    report(refused and code != null and code.? == 0, "gpu-refused", std.fmt.bufPrint(&detail_buf, "CPU 경로 → gpu_unavailable {} · exit {?d}", .{ refused, code }) catch "");
}

pub fn run(report: Report, host_path: [:0]const u8, profile_dir: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    profileRefusals(report, host_path, std.fs.path.dirname(profile_dir) orelse "/tmp");
    gpuRefusal(report, host_path, std.fs.path.dirname(profile_dir) orelse "/tmp", port);

    var detail_buf: [256]u8 = undefined;
    var u: [256]u8 = undefined;
    const nonce = os.random64() & 0xffffff;

    var host = try Host.spawn(host_path, profile_arg);
    try handshake(&host);
    var misrouted: usize = 0;

    // 셋을 만든다.
    try host.send(.{ .create_browser = .{ .browser = 1, .size = size, .hidden = false, .url = url(&u, port, "/title?t=one") } });
    try host.send(.{ .create_browser = .{ .browser = 2, .size = size, .hidden = false, .url = url(&u, port, "/title?t=two") } });
    try host.send(.{ .create_browser = .{ .browser = 3, .size = size, .hidden = false, .url = url(&u, port, "/size") } });
    // 생성 알림은 제목보다 먼저 온다(create 가 동기로 답한다) — 셋째 생성까지 읽은 뒤 제목 셋을 모은다.
    const created = waitFor(&host, .{ .created = 3 }, &misrouted);
    const titled = waitTitles(&host, &.{
        .{ .title = .{ .browser = 1, .text = "one" } },
        .{ .title = .{ .browser = 2, .text = "two" } },
        .{ .title = .{ .browser = 3, .text = "w=640" } },
    }, &misrouted);
    report(created and titled == 3, "browsers-created", std.fmt.bufPrint(&detail_buf, "셋째 생성 {} · 자기 제목 {d}/3", .{ created, titled }) catch "");

    // 둘째에만 이동을 보낸다.
    try host.send(.{ .navigate = .{ .browser = 2, .url = url(&u, port, "/title?t=two-moved") } });
    const moved = waitFor(&host, .{ .title = .{ .browser = 2, .text = "two-moved" } }, &misrouted);
    report(moved and misrouted == 0, "routed", std.fmt.bufPrint(&detail_buf, "둘째만 이동 · 잘못 간 제목 {d}", .{misrouted}) catch "");

    // 숨긴 뒤에도 명령을 받는다.
    try host.send(.{ .set_hidden = .{ .browser = 1, .value = true } });
    try host.send(.{ .navigate = .{ .browser = 1, .url = url(&u, port, "/vis") } });
    const saw_hidden = waitFor(&host, .{ .title = .{ .browser = 1, .text = "vis=hidden" } }, &misrouted);
    try host.send(.{ .set_hidden = .{ .browser = 1, .value = false } });
    const saw_visible = waitFor(&host, .{ .title = .{ .browser = 1, .text = "vis=visible" } }, &misrouted);
    report(saw_hidden and saw_visible, "hidden-receives", std.fmt.bufPrint(&detail_buf, "숨긴 첫째가 이동을 받아 vis=hidden {} · 다시 보이면 vis=visible {}", .{ saw_hidden, saw_visible }) catch "");

    // 크기 변경이 페이지까지 닿는다.
    const resize_started = os.nowMs();
    try host.send(.{ .resize = .{ .browser = 3, .size = .{ .width = 500, .height = 300, .scale = 2 } } });
    const resized = waitFor(&host, .{ .title = .{ .browser = 3, .text = "w=500" } }, &misrouted);
    const resize_ms = os.nowMs() - resize_started;
    report(resized, "resized", std.fmt.bufPrint(&detail_buf, "innerWidth 640 → 500 · {d} ms", .{resize_ms}) catch "");

    // 파괴와 그 뒤 명령.
    try host.send(.{ .destroy_browser = 2 });
    const closed = waitFor(&host, .{ .closed = 2 }, &misrouted);
    try host.send(.{ .navigate = .{ .browser = 2, .url = url(&u, port, "/title?t=ghost") } });
    const unknown = waitFor(&host, .{ .failure = .{ .browser = 2, .code = .unknown_browser } }, &misrouted);
    report(closed and unknown, "destroyed", "browser_closed(2) → 이후 명령 unknown_browser");

    try host.send(.{ .create_browser = .{ .browser = 1, .size = size, .hidden = false, .url = url(&u, port, "/title?t=dup") } });
    report(waitFor(&host, .{ .failure = .{ .browser = 1, .code = .duplicate_browser } }, &misrouted), "duplicate-refused", "같은 id 재생성");

    // 렌더러까지 샌드박스 안(GPU·네트워크·저장소 + 렌더러 하나 이상).
    const state = sandbox.settle(host.pid, 4, wait_ms);
    report(state.all(4), "renderer-sandbox", std.fmt.bufPrint(&detail_buf, "helper {d} 개 · 샌드박스 {d} · 이름 일치 {d}", .{ state.total, state.sandboxed, state.named }) catch "");

    // window.open 이 창을 만들지 않는다.
    try host.send(.{ .navigate = .{ .browser = 3, .url = url(&u, port, "/popup") } });
    const tried = waitFor(&host, .{ .title = .{ .browser = 3, .text = "popup-tried" } }, &misrouted);
    os.sleepMs(1500);
    const popup_windows = windows.ownedBy(host.pid);
    const popup_loads = http.opened_requests.load(.monotonic);
    report(tried and popup_windows == 0 and popup_loads == 0, "no-popup", std.fmt.bufPrint(&detail_buf, "window.open 뒤 host 창 {d} 개 · 팝업 페이지 요청 {d}", .{ popup_windows, popup_loads }) catch "");

    var js_buf: [256]u8 = undefined;
    const js = std.fmt.bufPrint(&js_buf, "javascript:void(window.open('http://127.0.0.1:{d}/title?t=opened','_blank'),document.title='popup-js')", .{port}) catch unreachable;
    try host.send(.{ .navigate = .{ .browser = 3, .url = js } });
    const js_tried = waitFor(&host, .{ .title = .{ .browser = 3, .text = "popup-js" } }, &misrouted);
    os.sleepMs(1500);
    const js_windows = windows.ownedBy(host.pid);
    const js_loads = http.opened_requests.load(.monotonic);
    report(js_tried and js_windows == 0 and js_loads == 0, "no-popup-js", std.fmt.bufPrint(&detail_buf, "javascript: 이동의 window.open 뒤 host 창 {d} 개 · 팝업 페이지 요청 {d}", .{ js_windows, js_loads }) catch "");

    try host.send(.{ .navigate = .{ .browser = 3, .url = url(&u, port, "/print") } });
    const printed = waitFor(&host, .{ .title = .{ .browser = 3, .text = "print-tried" } }, &misrouted);
    os.sleepMs(1500);
    const print_windows = windows.ownedBy(host.pid);
    report(printed and print_windows == 0, "no-print", std.fmt.bufPrint(&detail_buf, "window.print() 가 돌아옴 {} · host 창 {d} 개", .{ printed, print_windows }) catch "");

    try host.send(.{ .navigate = .{ .browser = 3, .url = url(&u, port, "/dialog") } });
    const dialogs = waitFor(&host, .{ .title = .{ .browser = 3, .text = "dialog-false-null" } }, &misrouted);
    os.sleepMs(1500);
    const dialog_windows = windows.ownedBy(host.pid);
    report(dialogs and dialog_windows == 0, "no-dialog", std.fmt.bufPrint(&detail_buf, "alert·confirm·prompt 가 억제되어 돌아옴(dialog-false-null) {} · host 창 {d} 개", .{ dialogs, dialog_windows }) catch "");

    try host.send(.{ .navigate = .{ .browser = 3, .url = url(&u, port, "/ctl") } });
    report(waitFor(&host, .{ .title = .{ .browser = 3, .text = "a b c" } }, &misrouted), "title-control", "제목 a<BEL>b<DEL>c → \"a b c\"");

    try host.send(.{ .navigate = .{ .browser = 1, .url = url(&u, port, "/flood") } });
    var flood_titles: usize = 0;
    var flood_done = false;
    const flood_deadline = os.nowMs() + wait_ms;
    while (!flood_done and os.nowMs() < flood_deadline) {
        const message = (host.next(@intCast(@max(flood_deadline - os.nowMs(), 1))) catch break) orelse break;
        if (message != .title_changed or message.title_changed.browser != 1) continue;
        flood_titles += 1;
        flood_done = std.mem.eql(u8, message.title_changed.text, "flood-done");
    }
    // 2 초 ÷ 50ms = 40 + 첫 제목·마지막 제목·타이머 흔들림 몫.
    report(flood_done and flood_titles <= flood_title_limit, "title-flood", std.fmt.bufPrint(&detail_buf, "제목 알림 {d} 개(상한 {d}) · flood-done 도착 {}", .{ flood_titles, flood_title_limit, flood_done }) catch "");

    // 뒤로·앞으로(W3b). 셋째 브라우저로 두 페이지를 차례로 연 뒤 뒤로·앞으로 옮긴다.
    try host.send(.{ .navigate = .{ .browser = 3, .url = url(&u, port, "/title?t=nav-a") } });
    const nav_a = waitAll(&host, &.{
        .{ .url_suffix = .{ .browser = 3, .suffix = "t=nav-a" } },
        .{ .title = .{ .browser = 3, .text = "nav-a" } },
    }, &misrouted);
    try host.send(.{ .navigate = .{ .browser = 3, .url = url(&u, port, "/title?t=nav-b") } });
    const nav_b = waitAll(&host, &.{
        .{ .title = .{ .browser = 3, .text = "nav-b" } },
        .{ .can_go_back = .{ .browser = 3, .value = true } },
    }, &misrouted);
    try host.send(.{ .nav_action = .{ .browser = 3, .action = .back } });
    const went_back = waitAll(&host, &.{
        .{ .url_suffix = .{ .browser = 3, .suffix = "t=nav-a" } },
        .{ .title = .{ .browser = 3, .text = "nav-a" } },
    }, &misrouted);
    try host.send(.{ .nav_action = .{ .browser = 3, .action = .forward } });
    const went_forward = waitFor(&host, .{ .url_suffix = .{ .browser = 3, .suffix = "t=nav-b" } }, &misrouted);
    report(nav_a and nav_b and went_back and went_forward and misrouted == 0, "nav-actions", std.fmt.bufPrint(&detail_buf, "주소 알림 {} · 뒤로 가능 {} · 뒤로 {} · 앞으로 {} · 잘못 간 알림 {d}", .{ nav_a, nav_b, went_back, went_forward, misrouted }) catch "");

    // 같은 프로필로 두 번째 host.
    var second = try Host.spawn(host_path, profile_arg);
    try second.send(.{ .hello = .{ .instance = 2, .nonce = os.random64() } });
    var second_failure: ?FailureCode = null;
    while (second.next(wait_ms) catch null) |message| {
        if (message == .failure) second_failure = message.failure.code;
    }
    const second_code = second.wait(wait_ms);
    os.sleepMs(1500);
    const relaunch_windows = windows.ownedBy(host.pid);
    try host.send(.{ .navigate = .{ .browser = 1, .url = url(&u, port, "/title?t=still-alive") } });
    const alive = waitFor(&host, .{ .title = .{ .browser = 1, .text = "still-alive" } }, &misrouted);
    report(second_failure == .profile_in_use and second_code != null and second_code.? == 16 and relaunch_windows == 0 and alive, "relaunch-refused", std.fmt.bufPrint(&detail_buf, "두 번째 {s} · exit {?d} · 첫 host 창 {d} 개 · 첫 host 계속 응답 {}", .{ if (second_failure) |code| @tagName(code) else "알림 없음", second_code, relaunch_windows, alive }) catch "");

    // 프로필: 0700 과 백업 제외.
    var st: std.c.Stat = undefined;
    const fd = std.c.open(profile_dir, .{ .ACCMODE = .RDONLY, .DIRECTORY = true });
    const private = fd >= 0 and std.c.fstat(fd, &st) == 0 and st.mode & 0o777 == 0o700;
    if (fd >= 0) _ = std.c.close(fd);
    const excluded = os.excludedFromBackup(profile_dir);
    report(private and excluded, "profile-private", std.fmt.bufPrint(&detail_buf, "0700 {} · 백업 제외 {}", .{ private, excluded }) catch "");

    // 쿠키를 심고 끈다.
    var cookie_path: [64]u8 = undefined;
    try host.send(.{ .create_browser = .{ .browser = 4, .size = size, .hidden = false, .url = url(&u, port, std.fmt.bufPrint(&cookie_path, "/cookie?v={d}", .{nonce}) catch unreachable) } });
    const fresh = waitFor(&host, .{ .title = .{ .browser = 4, .text = "cookie=[]" } }, &misrouted);

    try host.send(.shutdown);
    var closed_count: usize = 0;
    var clean_tail = true;
    while (host.next(wait_ms) catch blk: {
        clean_tail = false;
        break :blk null;
    }) |message| {
        if (message == .browser_closed) closed_count += 1;
    }
    const code = host.wait(wait_ms);
    report(closed_count == 3 and clean_tail and host.clean and code != null and code.? == 0, "shutdown-closes", std.fmt.bufPrint(&detail_buf, "열린 셋 모두 browser_closed {d} · exit {?d}", .{ closed_count, code }) catch "");

    // 다시 띄워 쿠키가 남았는지.
    var again = try Host.spawn(host_path, profile_arg);
    try handshake(&again);
    try again.send(.{ .create_browser = .{ .browser = 5, .size = size, .hidden = false, .url = url(&u, port, "/cookie?v=0") } });
    var expected_buf: [64]u8 = undefined;
    const expected = std.fmt.bufPrint(&expected_buf, "cookie=[maru_judge={d}]", .{nonce}) catch unreachable;
    const persisted = waitFor(&again, .{ .title = .{ .browser = 5, .text = expected } }, &misrouted);
    report(fresh and persisted, "login-persists", std.fmt.bufPrint(&detail_buf, "첫 실행 빈 쿠키 {} · 재시작 뒤 {s} {}", .{ fresh, expected, persisted }) catch "");
    try again.send(.shutdown);
    while (again.next(wait_ms) catch null) |_| {}
    _ = again.wait(wait_ms);
}
