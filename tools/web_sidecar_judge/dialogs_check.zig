//! W5a 판정 — JS 대화상자·떠나기 확인·파일 선택이 maru 로 와서 maru 의 답으로 끝나는가(docs/plans/web-osr-backend.md C6).
//! 판정자가 maru 역할로 답한다.
//!
//!   dialog-asks          `alert`·`confirm`·`prompt` 가 차례로 `js_dialog` 로 온다(종류·글·기본 글·출처) — 그동안 host 창 0 개
//!                        (Chromium 기본 창이 maru 창 뒤에 숨던 것 — W5 착수 전 실측). 수락과 한글·여러 줄 답이 페이지로 간다
//!   dialog-cancel        취소 답: `confirm` 은 false, `prompt` 는 null
//!   dialog-reset         대화상자가 떠 있을 때 이동하면 그 요청의 `dialog_closed` 가 오고 페이지가 옮겨 간다. 그 뒤에 늦게 온
//!                        답·없는 번호의 답은 조용히 버린다(host 가 계속 명령을 받는다)
//!   before-unload        사용자 동작 뒤 떠나기 확인을 거는 페이지에서 이동하면 `before_unload` 가 온다 — 머무르기면 안 옮겨 가고
//!                        페이지가 계속 응답하며(클릭 수) 다음 이동에 그 요청의 `dialog_closed` 가 오지 않는다(답이 실제로 닿았다),
//!                        다시 이동해 떠나기면 옮겨 간다
//!   dialog-suppress      이동 없이 두 번째 대화상자부터 「더 띄우지 못하게」를 청하고(`offer_suppress`), 그렇게 답하면 나머지는
//!                        maru 에 오지 않은 채 페이지가 끝까지 돈다. 이동하면 억제가 풀린다(`while(1) alert()` 의 탈출구)
//!   dialog-reload-loop   페이지가 스스로 새로고침해도(`alert(); location.reload()`) 수를 이어 세 억제 선택이 온다 — maru 가 시킨
//!                        이동에서만 푼다(창 전체를 막는 sheet 에서 빠져나갈 길)
//!   dialog-origin        출처는 `scheme://host[:port]` 만 — 주소의 사용자 정보(`http://maru@…`)는 빠지고, `data:` 페이지는 빈 출처
//!                        (maru 가 「이 페이지」로 보인다 — 페이지가 고른 글이 출처 자리에 들어가지 않게)
//!   dialog-origin-long   255 바이트 넘는 호스트도 빈 출처(잘린 앞부분이 출처로 가지 않게)
//!   file-open            입력칸을 누르면 `file_dialog`(열기·받을 형식 `image/*,.txt`)가 온다. 경로를 답하면 **샌드박스 렌더러가
//!                        내용을 읽는다**(이름·크기)
//!   file-multiple        여러 개 고르기 — 경로 둘
//!   file-folder          폴더 고르기(`webkitdirectory`)는 `open_folder` 로 온다 — maru 는 폴더 안 파일들로 펼쳐 답한다(폴더 경로
//!                        자체로 답하면 페이지에 아무것도 안 온다 — 실측)
//!   file-cancel          취소하면 페이지는 아무것도 받지 않고, 다시 누르면 선택이 또 온다(멈추지 않는다)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const windows = @import("windows.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const Message = protocol.message.Message;
const BrowserId = protocol.message.BrowserId;
const RequestId = protocol.message.RequestId;

pub const Report = browsers_check.Report;

const id: BrowserId = 5;
const wait_ms = 15_000;
const size: protocol.message.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };

/// 한 알림을 기다린다 — 그 사이 온 다른 알림은 버린다. 받은 알림은 다음 `next` 전까지 유효하다.
fn waitMessage(host: *Host, tag: protocol.message.Tag, timeout_ms: u32) ?Message {
    const deadline = os.nowMs() + timeout_ms;
    while (os.nowMs() < deadline) {
        const left: u32 = @intCast(@max(deadline - os.nowMs(), 1));
        const message = (host.next(left) catch return null) orelse return null;
        if (message == tag) return message;
    }
    return null;
}

fn waitTitle(host: *Host, text: []const u8, timeout_ms: u32) bool {
    const deadline = os.nowMs() + timeout_ms;
    while (os.nowMs() < deadline) {
        const left: u32 = @intCast(@max(deadline - os.nowMs(), 1));
        const message = (host.next(left) catch return false) orelse return false;
        if (message == .title_changed and message.title_changed.browser == id) {
            if (std.mem.eql(u8, message.title_changed.text, text)) return true;
            if (std.c.getenv("MARU_JUDGE_TRACE") != null) std.debug.print("  title: {s}\n", .{message.title_changed.text});
        } else if (std.c.getenv("MARU_JUDGE_TRACE") != null and message != .nav_state and message != .cursor_changed) {
            std.debug.print("  other: {s}\n", .{@tagName(message)});
        }
    }
    return false;
}

/// 기다리는 동안 실패(`failure`)가 오면 true — 늦은 답이 채널을 닫거나 실패를 내지 않는지 본다.
fn anyFailure(host: *Host, timeout_ms: u32) bool {
    const deadline = os.nowMs() + timeout_ms;
    while (os.nowMs() < deadline) {
        const left: u32 = @intCast(@max(deadline - os.nowMs(), 1));
        // 시한 초과는 `error.Timeout` 이다(null 이 아니다) — 조용했다는 뜻이다.
        const message = (host.next(left) catch |err| return err != error.Timeout) orelse return false;
        if (message == .failure) {
            std.debug.print("  failure: browser={d} code={s} {s}\n", .{ message.failure.browser, @tagName(message.failure.code), message.failure.detail });
            return true;
        }
    }
    return false;
}

const Asked = struct {
    request: RequestId = 0,
    ok: bool = false,
};

/// `js_dialog` 하나를 기다려 종류·글·기본 글·출처를 맞춰 본다.
fn expectDialog(host: *Host, kind: protocol.message.JsDialogKind, text: ?[]const u8, default_text: []const u8, origin: []const u8) Asked {
    const message = waitMessage(host, .js_dialog, wait_ms) orelse return .{};
    const d = message.js_dialog;
    const ok = d.browser == id and d.kind == kind and (text == null or std.mem.eql(u8, d.message, text.?)) and
        std.mem.eql(u8, d.default_text, default_text) and std.mem.eql(u8, d.origin, origin);
    if (!ok) std.debug.print("  js_dialog 가 다르다: kind={s} message=[{s}] default=[{s}] origin=[{s}]\n", .{ @tagName(d.kind), d.message, d.default_text, d.origin });
    return .{ .request = d.request, .ok = ok };
}

/// 다음 판정 전에 가라앉힌다 — 중립 페이지로 옮기고 그 사이 오는 대화상자는 모두 답한다(스스로 새로고침하던 페이지가 이동과
/// 겹쳐 대화상자를 하나 더 보낼 수 있다).
fn settle(host: *Host, u: []u8, port: u16, title: []const u8) !void {
    var path_buf: [64]u8 = undefined;
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(u, port, std.fmt.bufPrint(&path_buf, "/title?t={s}", .{title}) catch unreachable) } });
    const deadline = os.nowMs() + wait_ms;
    while (os.nowMs() < deadline) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return) orelse return;
        switch (message) {
            .js_dialog => |value| try reply(host, value.request, true, ""),
            .title_changed => |value| if (value.browser == id and std.mem.eql(u8, value.text, title)) return,
            else => {},
        }
    }
}

fn reply(host: *Host, request: RequestId, accept: bool, text: []const u8) !void {
    try host.send(.{ .dialog_reply = .{ .browser = id, .request = request, .accept = accept, .text = text } });
}

const FileAsked = struct {
    request: RequestId = 0,
    mode: ?protocol.message.FileDialogMode = null,
    accept_ok: bool = false,
};

fn expectFileDialog(host: *Host, accept: []const u8) FileAsked {
    const message = waitMessage(host, .file_dialog, wait_ms) orelse return .{};
    const d = message.file_dialog;
    return .{ .request = d.request, .mode = d.mode, .accept_ok = d.browser == id and std.mem.eql(u8, d.accept, accept) };
}

/// 첫 프레임 뒤 약 0.5 초의 입력은 렌더러가 버린다(W4a 실측) — 준비 알림 뒤 잠깐 기다렸다 누른다.
fn click(host: *Host, x: i32, y: i32) !void {
    os.sleepMs(800);
    try host.send(.{ .mouse = .{ .browser = id, .kind = .down, .point = .{ .x = x, .y = y }, .click_count = 1 } });
    try host.send(.{ .mouse = .{ .browser = id, .kind = .up, .point = .{ .x = x, .y = y }, .click_count = 1 } });
}

fn writeFile(path: [:0]const u8, bytes: []const u8) !void {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .TRUNC = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return error.CreateFailed;
    defer _ = std.c.close(fd);
    if (std.c.write(fd, bytes.ptr, bytes.len) != @as(isize, @intCast(bytes.len))) return error.WriteFailed;
}

/// 파일 선택 한 번 — 입력칸을 누르고 `file_dialog` 를 받아 경로들로 답한다(`paths` 가 비면 취소).
fn pick(host: *Host, accept: []const u8, paths: []const []const u8) !FileAsked {
    try click(host, 50, 50);
    const asked = expectFileDialog(host, accept);
    if (asked.request == 0) return asked;
    for (paths) |path| try host.send(.{ .file_dialog_path = .{ .browser = id, .request = asked.request, .path = path } });
    try host.send(.{ .file_dialog_reply = .{ .browser = id, .request = asked.request, .accept = paths.len > 0 } });
    return asked;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, scratch: []const u8, port: u16) !void {
    var detail_buf: [320]u8 = undefined;
    var u: [256]u8 = undefined;
    var origin_buf: [64]u8 = undefined;
    const origin = std.fmt.bufPrint(&origin_buf, "http://127.0.0.1:{d}", .{port}) catch unreachable;

    var host = try Host.spawn(host_path, profile_arg);
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = browsers_check.url(&u, port, "/title?t=dialogs-start") } });
    if (!waitTitle(&host, "dialogs-start", wait_ms)) return error.PageNotReady;
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } });

    // ── JS 대화상자: 수락 ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/dialog") } });
    const alerted = expectDialog(&host, .alert, "a", "", origin);
    os.sleepMs(1000);
    const windows_while_asking = windows.ownedBy(host.pid);
    try reply(&host, alerted.request, true, "");
    const confirmed = expectDialog(&host, .confirm, "b", "", origin);
    try reply(&host, confirmed.request, true, "");
    const prompted = expectDialog(&host, .prompt, "c", "d", origin);
    try reply(&host, prompted.request, true, "한글\n답");
    // 제목은 한 줄이라 줄바꿈이 공백으로 온다(title-control 과 같은 규칙).
    const answered = waitTitle(&host, "dialog-true-한글 답", wait_ms);
    report(alerted.ok and confirmed.ok and prompted.ok and answered and windows_while_asking == 0, "dialog-asks", std.fmt.bufPrint(&detail_buf, "alert {} · confirm {} · prompt(기본 d) {} · 답 → dialog-true-한글 답 {} · 묻는 동안 host 창 {d} 개", .{ alerted.ok, confirmed.ok, prompted.ok, answered, windows_while_asking }) catch "");

    // ── 취소 ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/dialog") } });
    const alerted2 = expectDialog(&host, .alert, "a", "", origin);
    try reply(&host, alerted2.request, true, "");
    const confirmed2 = expectDialog(&host, .confirm, "b", "", origin);
    try reply(&host, confirmed2.request, false, "");
    const prompted2 = expectDialog(&host, .prompt, "c", "d", origin);
    try reply(&host, prompted2.request, false, "무시될 글");
    report(waitTitle(&host, "dialog-false-null", wait_ms), "dialog-cancel", "confirm 거짓 · prompt 취소(친 글은 버린다) → dialog-false-null");

    // ── 떠 있을 때 이동 ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/dialog-hold") } });
    const held = expectDialog(&host, .alert, "hold", "", origin);
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/title?t=after-reset") } });
    var closed_request: RequestId = 0;
    var moved = false;
    const reset_deadline = os.nowMs() + wait_ms;
    while ((closed_request == 0 or !moved) and os.nowMs() < reset_deadline) {
        const message = (host.next(@intCast(@max(reset_deadline - os.nowMs(), 1))) catch break) orelse break;
        switch (message) {
            .dialog_closed => |value| if (value.browser == id) {
                closed_request = value.request;
            },
            .title_changed => |value| if (value.browser == id and std.mem.eql(u8, value.text, "after-reset")) {
                moved = true;
            },
            else => {},
        }
    }
    // 늦은 답(이미 닫힌 번호)과 없는 번호의 답·경로는 버린다.
    try reply(&host, held.request, true, "");
    try reply(&host, 999_999, true, "");
    try host.send(.{ .file_dialog_path = .{ .browser = id, .request = 999_999, .path = "/tmp/none" } });
    try host.send(.{ .file_dialog_reply = .{ .browser = id, .request = 999_999, .accept = true } });
    const failed = anyFailure(&host, 1000);
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/title?t=still-alive") } });
    const alive = waitTitle(&host, "still-alive", wait_ms);
    report(held.ok and closed_request == held.request and moved and !failed and alive, "dialog-reset", std.fmt.bufPrint(&detail_buf, "떠 있는 alert(요청 {d}) 중 이동 → dialog_closed(요청 {d}) · 옮겨 감 {} · 늦은 답·없는 번호 뒤 실패 {} · 계속 명령 받음 {}", .{ held.request, closed_request, moved, failed, alive }) catch "");

    // ── 떠나기 확인 ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/unload") } });
    if (!waitTitle(&host, "unload-ready", wait_ms)) return error.PageNotReady;
    try click(&host, 20, 20);
    const armed = waitTitle(&host, "unload-armed-1", wait_ms);
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/title?t=left") } });
    // 떠나기 확인 문구는 CEF 가 정한 영어 한 줄이다(페이지 글이 아니다 — 위장 방지) — 종류만 본다.
    const stay = expectDialog(&host, .before_unload, null, "", "");
    if (stay.request == 0) {
        std.debug.print("  armed={} · 확인 없이 떠났나 {}\n", .{ armed, waitTitle(&host, "left", 3000) });
        return error.NoBeforeUnload;
    }
    try reply(&host, stay.request, false, "");
    // 머무르기가 실제로 닿았다 — 페이지가 멈추지 않고 다음 클릭을 받는다(답이 버려졌다면 페이지는 확인에 멈춰 있다).
    try click(&host, 20, 20);
    const responsive = waitTitle(&host, "unload-armed-2", wait_ms);
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/title?t=left") } });
    // 다음 이동에서 옛 요청이 치워지면(`dialog_closed`) 머무르기 답이 닿지 않았다는 뜻이다.
    var leave_request: RequestId = 0;
    var stale_closed = false;
    const leave_deadline = os.nowMs() + wait_ms;
    while (leave_request == 0 and os.nowMs() < leave_deadline) {
        const message = (host.next(@intCast(@max(leave_deadline - os.nowMs(), 1))) catch break) orelse break;
        switch (message) {
            .dialog_closed => |value| if (value.request == stay.request) {
                stale_closed = true;
            },
            .js_dialog => |value| if (value.kind == .before_unload) {
                leave_request = value.request;
            },
            else => {},
        }
    }
    if (leave_request != 0) try reply(&host, leave_request, true, "");
    const left = waitTitle(&host, "left", wait_ms);
    report(armed and responsive and !stale_closed and leave_request != 0 and left, "before-unload", std.fmt.bufPrint(&detail_buf, "클릭 뒤 떠나기 확인 걸림 {} · 머무르기 뒤 페이지가 응답 {} · 옛 요청이 치워짐 {} · 다시 이동 → before_unload {} · 떠나기면 옮겨 감 {}", .{ armed, responsive, stale_closed, leave_request != 0, left }) catch "");

    // ── 억제 ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/dialog-loop") } });
    const first = waitMessage(&host, .js_dialog, wait_ms);
    const first_request = if (first) |m| m.js_dialog.request else 0;
    const first_plain = first != null and !first.?.js_dialog.offer_suppress;
    if (first_request != 0) try reply(&host, first_request, true, "");
    const second = waitMessage(&host, .js_dialog, wait_ms);
    const second_request = if (second) |m| m.js_dialog.request else 0;
    const second_offers = second != null and second.?.js_dialog.offer_suppress;
    if (second_request != 0) try host.send(.{ .dialog_reply = .{ .browser = id, .request = second_request, .accept = true, .suppress = true } });
    // 나머지 셋은 maru 에 오지 않고 페이지가 끝까지 돈다.
    var extra: usize = 0;
    var loop_done = false;
    const loop_deadline = os.nowMs() + wait_ms;
    while (!loop_done and os.nowMs() < loop_deadline) {
        const message = (host.next(@intCast(@max(loop_deadline - os.nowMs(), 1))) catch break) orelse break;
        switch (message) {
            .js_dialog => |value| {
                extra += 1;
                try reply(&host, value.request, true, "");
            },
            .title_changed => |value| if (value.browser == id and std.mem.eql(u8, value.text, "loop-done")) {
                loop_done = true;
            },
            else => {},
        }
    }
    // 이동하면 억제가 풀린다.
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/dialog-hold") } });
    const after_nav = expectDialog(&host, .alert, "hold", "", origin);
    if (after_nav.request != 0) try reply(&host, after_nav.request, true, "");
    report(first_plain and second_offers and extra == 0 and loop_done and after_nav.ok, "dialog-suppress", std.fmt.bufPrint(&detail_buf, "첫째는 억제 선택 없음 {} · 둘째부터 청함 {} · 억제 뒤 maru 에 온 대화상자 {d} · 페이지 끝까지 {} · 이동하면 다시 묻는다 {}", .{ first_plain, second_offers, extra, loop_done, after_nav.ok }) catch "");

    // ── 스스로 새로고침해도 수를 이어 센다 ──
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/dialog-reload") } });
    const reload_first = waitMessage(&host, .js_dialog, wait_ms);
    const reload_first_plain = reload_first != null and !reload_first.?.js_dialog.offer_suppress;
    if (reload_first) |m| try reply(&host, m.js_dialog.request, true, "");
    const reload_second = waitMessage(&host, .js_dialog, wait_ms);
    const reload_second_offers = reload_second != null and reload_second.?.js_dialog.offer_suppress;
    if (reload_second) |m| try host.send(.{ .dialog_reply = .{ .browser = id, .request = m.js_dialog.request, .accept = true, .suppress = true } });
    // 억제 뒤로는 새로고침이 되풀이돼도 maru 에 오지 않고 페이지가 끝난다(`reload-done`).
    var reload_more: usize = 0;
    var reload_done = false;
    const reload_deadline = os.nowMs() + wait_ms;
    while (!reload_done and os.nowMs() < reload_deadline) {
        const message = (host.next(@intCast(@max(reload_deadline - os.nowMs(), 1))) catch break) orelse break;
        switch (message) {
            .js_dialog => |value| {
                reload_more += 1;
                try reply(&host, value.request, true, "");
            },
            .title_changed => |value| if (value.browser == id and std.mem.eql(u8, value.text, "reload-done")) {
                reload_done = true;
            },
            else => {},
        }
    }
    report(reload_first_plain and reload_second_offers and reload_more == 0 and reload_done, "dialog-reload-loop", std.fmt.bufPrint(&detail_buf, "첫째 억제 선택 없음 {} · 스스로 새로고침한 뒤 억제 선택 {} · 억제 뒤 더 옴 {d} · 페이지 끝까지 {}", .{ reload_first_plain, reload_second_offers, reload_more, reload_done }) catch "");

    try settle(&host, &u, port, "settled-reload");

    // ── 출처 ──
    var user_url_buf: [128]u8 = undefined;
    const user_url = std.fmt.bufPrint(&user_url_buf, "http://maru@127.0.0.1:{d}/dialog-hold", .{port}) catch unreachable;
    try host.send(.{ .navigate = .{ .browser = id, .url = user_url } });
    const with_user = expectDialog(&host, .alert, "hold", "", origin);
    if (with_user.request != 0) try reply(&host, with_user.request, true, "");
    try host.send(.{ .navigate = .{ .browser = id, .url = "data:text/html,<script>alert('from-data')</script>" } });
    const from_data = expectDialog(&host, .alert, "from-data", "", "");
    if (from_data.request != 0) try reply(&host, from_data.request, true, "");
    report(with_user.ok and from_data.ok, "dialog-origin", std.fmt.bufPrint(&detail_buf, "http://maru@127.0.0.1 → 출처 {s} {} · data: 페이지 → 빈 출처 {}", .{ origin, with_user.ok, from_data.ok }) catch "");

    // ── 파일 선택 ──
    var a_buf: [1024]u8 = undefined;
    var b_buf: [1024]u8 = undefined;
    var dir_buf: [1024]u8 = undefined;
    const a = try std.fmt.bufPrintZ(&a_buf, "{s}/pick-a.txt", .{scratch});
    const b = try std.fmt.bufPrintZ(&b_buf, "{s}/pick-b.txt", .{scratch});
    const dir = try std.fmt.bufPrintZ(&dir_buf, "{s}/pick-dir", .{scratch});
    try writeFile(a, "maru reads this through the sandbox" ** 10);
    try writeFile(b, "second");
    _ = std.c.mkdir(dir, 0o755);
    var inner_buf: [1100]u8 = undefined;
    try writeFile(try std.fmt.bufPrintZ(&inner_buf, "{s}/one.txt", .{dir}), "1");
    try writeFile(try std.fmt.bufPrintZ(&inner_buf, "{s}/two.txt", .{dir}), "22");

    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/file") } });
    if (!waitTitle(&host, "file-ready", wait_ms)) return error.PageNotReady;
    const single = try pick(&host, "image/*,.txt", &.{a});
    const read_single = waitTitle(&host, "file-1-pick-a.txt-350", wait_ms);
    report(single.mode == .open and single.accept_ok and read_single, "file-open", std.fmt.bufPrint(&detail_buf, "file_dialog 열기 {} · 받을 형식 image/*,.txt {} · 렌더러가 읽음 file-1-pick-a.txt-350 {}", .{ single.mode == .open, single.accept_ok, read_single }) catch "");

    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/files") } });
    if (!waitTitle(&host, "file-ready", wait_ms)) return error.PageNotReady;
    const multiple = try pick(&host, "", &.{ a, b });
    report(multiple.mode == .open_multiple and waitTitle(&host, "file-2-pick-a.txt,pick-b.txt-356", wait_ms), "file-multiple", "여러 개 → 경로 둘 → file-2-pick-a.txt,pick-b.txt-356");

    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/folder") } });
    if (!waitTitle(&host, "file-ready", wait_ms)) return error.PageNotReady;
    var one_buf: [1100]u8 = undefined;
    var two_buf: [1100]u8 = undefined;
    const one_path = try std.fmt.bufPrint(&one_buf, "{s}/one.txt", .{dir});
    const two_path = try std.fmt.bufPrint(&two_buf, "{s}/two.txt", .{dir});
    // 폴더 경로 자체로 답하면 페이지에 아무것도 안 온다(CEF 154 실측 — Chrome 의 폴더 업로드 확인 화면이 창 없는 CEF 에 없어
    // 멈추는 것으로 본다). maru 는 고른 폴더 안의 파일들로 펼쳐 답한다 — 페이지의 `webkitRelativePath` 는 빈다(후속).
    const folder = try pick(&host, "", &.{ one_path, two_path });
    const folder_read = waitTitle(&host, "file-2-one.txt,two.txt-3", wait_ms);
    report(folder.mode == .open_folder and folder_read, "file-folder", std.fmt.bufPrint(&detail_buf, "webkitdirectory → open_folder {} · 폴더 안 파일 둘로 답 → file-2-one.txt,two.txt-3 {}", .{ folder.mode == .open_folder, folder_read }) catch "");

    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/file") } });
    if (!waitTitle(&host, "file-ready", wait_ms)) return error.PageNotReady;
    // 취소 — 페이지는 아무것도 받지 않고(CEF 154 는 `cancel` 이벤트를 쏘지 않았다 — 실측), 다시 누르면 선택이 또 온다(멈추지 않는다).
    const cancelled = try pick(&host, "image/*,.txt", &.{});
    const quiet = !waitTitle(&host, "file-1-pick-a.txt-350", 1000);
    const again = try pick(&host, "image/*,.txt", &.{a});
    const read_again = waitTitle(&host, "file-1-pick-a.txt-350", wait_ms);
    report(cancelled.request != 0 and quiet and again.request != 0 and read_again, "file-cancel", std.fmt.bufPrint(&detail_buf, "취소 답 → 페이지에 파일 없음 {} · 다시 누르면 선택이 또 옴 {} · 이번엔 읽음 {}", .{ quiet, again.request != 0, read_again }) catch "");

    // ── 긴 호스트 출처 — 맨 끝(이 페이지 뒤의 이동이 가끔 늦다 — 다른 판정에 번지지 않게) ──
    // 255 바이트를 넘는 호스트(`*.localhost` 는 127.0.0.1 로 풀린다) — 잘린 앞부분이 출처로 가면 안 된다(빈 출처).
    const label = "a" ** 60;
    var long_url_buf: [512]u8 = undefined;
    const long_url = std.fmt.bufPrint(&long_url_buf, "http://" ++ label ++ "." ++ label ++ "." ++ label ++ "." ++ label ++ ".localhost:{d}/dialog-hold", .{port}) catch unreachable;
    try host.send(.{ .navigate = .{ .browser = id, .url = long_url } });
    const long_host = expectDialog(&host, .alert, "hold", "", "");
    if (long_host.request != 0) try reply(&host, long_host.request, true, "");
    report(long_host.ok, "dialog-origin-long", "255 바이트 넘는 호스트 → 빈 출처(자른 앞부분이 아니라 — maru 는 「이 페이지」로 보인다)");

    try host.send(.shutdown);
    _ = host.wait(wait_ms);
}
