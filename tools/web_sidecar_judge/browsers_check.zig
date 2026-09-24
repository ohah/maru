//! W1c 판정 — 실제 브라우저를 만들어 docs/plans/web-osr-backend.md 「W1c」 완료 판정을 잰다.
//!
//!   browsers-created   브라우저 셋이 만들어지고 각자 자기 페이지 제목을 알린다
//!   routed             한 브라우저에 보낸 이동은 그 브라우저의 알림으로만 돌아온다
//!   hidden-receives    숨긴 브라우저도 명령을 받고 페이지가 돈다
//!   resized            크기 변경이 페이지의 innerWidth 까지 닿는다
//!   destroyed          파괴하면 browser_closed, 그 뒤 명령은 unknown_browser
//!   duplicate-refused  같은 id 로 다시 만들면 duplicate_browser
//!   renderer-sandbox   렌더러를 포함한 helper 전부 샌드박스 안
//!   no-popup           `window.open` 이 창도, 보이지 않는 팝업 브라우저도 만들지 않는다(창 0 개·팝업 페이지 요청 0)
//!                      한계: 제스처 없는 `window.open` 은 Chromium 팝업 차단기가 먼저 막아 우리 처리기(`on_before_popup`)에
//!                      닿지 않는다(변이 실측 — 처리기를 풀어도 통과) — 처리기 판정은 입력이 생기는 W4 에서 한다.
//!   relaunch-refused   같은 프로필로 두 번째 host → profile_in_use·exit 16, 첫 host 는 창 0 개로 계속 돈다
//!   profile-private    프로필이 0700 이고 백업 제외 표시가 있다
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
const size: protocol.message.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };

const Want = union(enum) {
    title: struct { browser: BrowserId, text: []const u8 },
    created: BrowserId,
    closed: BrowserId,
    failure: struct { browser: BrowserId, code: FailureCode },
};

/// 기대한 알림이 올 때까지 읽는다. 기다리는 동안 **다른 브라우저**에서 같은 제목이 오면 잘못 간 것으로 센다.
fn waitFor(host: *Host, want: Want, misrouted: *usize) bool {
    const deadline = os.nowMs() + wait_ms;
    while (os.nowMs() < deadline) {
        const left: u32 = @intCast(@max(deadline - os.nowMs(), 1));
        const message = (host.next(left) catch return false) orelse return false;
        switch (want) {
            .title => |w| if (message == .title_changed) {
                const got = message.title_changed;
                if (std.mem.eql(u8, got.text, w.text)) {
                    if (got.browser == w.browser) return true;
                    misrouted.* += 1;
                }
            },
            .created => |id| if (message == .browser_created and message.browser_created == id) return true,
            .closed => |id| if (message == .browser_closed and message.browser_closed == id) return true,
            .failure => |w| if (message == .failure and message.failure.browser == w.browser and message.failure.code == w.code) return true,
        }
    }
    return false;
}

fn url(buf: []u8, port: u16, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path }) catch unreachable;
}

fn handshake(host: *Host) !void {
    try host.send(.{ .hello = .{ .instance = 1, .nonce = os.random64() } });
    const reply = (try host.next(wait_ms)) orelse return error.ClosedBeforeAck;
    if (reply != .hello_ack) return error.NoAck;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_dir: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
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
    const created = waitFor(&host, .{ .created = 3 }, &misrouted);
    const titled = waitFor(&host, .{ .title = .{ .browser = 3, .text = "w=640" } }, &misrouted);
    report(created and titled, "browsers-created", std.fmt.bufPrint(&detail_buf, "셋째 생성 {} · 첫 제목(w=640) {}", .{ created, titled }) catch "");

    // 둘째에만 이동을 보낸다.
    try host.send(.{ .navigate = .{ .browser = 2, .url = url(&u, port, "/title?t=two-moved") } });
    const moved = waitFor(&host, .{ .title = .{ .browser = 2, .text = "two-moved" } }, &misrouted);
    report(moved and misrouted == 0, "routed", std.fmt.bufPrint(&detail_buf, "둘째만 이동 · 잘못 간 제목 {d}", .{misrouted}) catch "");

    // 숨긴 뒤에도 명령을 받는다.
    try host.send(.{ .set_hidden = .{ .browser = 1, .value = true } });
    try host.send(.{ .navigate = .{ .browser = 1, .url = url(&u, port, "/title?t=hidden-ok") } });
    report(waitFor(&host, .{ .title = .{ .browser = 1, .text = "hidden-ok" } }, &misrouted), "hidden-receives", "숨긴 첫째가 이동을 받아 제목을 알림");

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
