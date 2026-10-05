//! 물어보고 닫기 판정(W6j — `close_asking`): 사용자가 탭을 닫을 때 sidecar 는 강제하지 않고 닫는다 — 떠나기 확인을 건 페이지면 묻고,
//! 아니면 곧바로 닫는다. maru 는 답이 없으면 강제로 닫는다(`destroy_browser`).
//!
//!   close-ask-plain      떠나기 처리기가 없는 페이지·처리기를 걸었지만 사용자 동작이 없는 페이지는 묻지 않고 곧바로 닫힌다
//!   close-ask-stay       클릭으로 건 떠나기 확인 — `before_unload` 가 오고, 머무르기면 닫히지 않고 페이지가 계속 반응한다
//!   close-ask-leave      머무른 뒤 다시 물어 떠나기면 닫힌다
//!   close-ask-hung       처리기가 멈춘 페이지 — 2 초 동안 질문도 닫힘도 없다(maru 의 시한). 강제로 닫아도 CEF 는 처리기가 끝날
//!                        때까지 닫지 않는다(실측 — 전부터). 그동안 sidecar 는 다른 명령을 받고, 끝나면 묻지 않고 닫힌다
//!   close-ask-twice      연달아 두 번 물어도 질문은 하나, 떠나기면 닫힌다
//!   close-ask-unknown    모르는 브라우저는 unknown_browser
const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const BrowserId = protocol.message.BrowserId;
const RequestId = protocol.message.RequestId;

pub const Report = browsers_check.Report;
const size: protocol.message.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
const wait_ms = 15_000;

/// 한 브라우저에 대해 본 것 — 닫힘·떠나기 확인(마지막 요청 번호와 수)·실패.
const Seen = struct {
    closed_ms: i64 = -1,
    dialogs: u32 = 0,
    request: RequestId = 0,
    failure: ?protocol.message.FailureCode = null,
};

/// `ms` 동안 본다 — 닫히면(또는 `stop_on_dialog` 이고 질문이 오면) 멈춘다.
fn watch(host: *Host, id: BrowserId, ms: u32, stop_on_dialog: bool) Seen {
    var seen: Seen = .{};
    const start = os.nowMs();
    const deadline = start + ms;
    while (os.nowMs() < deadline) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return seen) orelse return seen;
        switch (message) {
            .browser_closed => |b| if (b == id) {
                seen.closed_ms = os.nowMs() - start;
                return seen;
            },
            .js_dialog => |d| if (d.browser == id and d.kind == .before_unload) {
                seen.dialogs += 1;
                seen.request = d.request;
                if (stop_on_dialog) return seen;
            },
            .failure => |f| if (f.browser == id) {
                seen.failure = f.code;
            },
            else => {},
        }
    }
    return seen;
}

fn waitTitle(host: *Host, id: BrowserId, text: []const u8) bool {
    const deadline = os.nowMs() + wait_ms;
    while (os.nowMs() < deadline) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return false) orelse return false;
        if (message == .title_changed and message.title_changed.browser == id and std.mem.eql(u8, message.title_changed.text, text)) return true;
    }
    return false;
}

/// 첫 프레임 뒤 약 0.5 초의 입력은 렌더러가 버린다(W4a 실측) — 잠깐 기다렸다 누른다.
fn click(host: *Host, id: BrowserId) !void {
    os.sleepMs(800);
    try host.send(.{ .mouse = .{ .browser = id, .kind = .down, .point = .{ .x = 20, .y = 20 }, .click_count = 1 } });
    try host.send(.{ .mouse = .{ .browser = id, .kind = .up, .point = .{ .x = 20, .y = 20 }, .click_count = 1 } });
}

fn open(host: *Host, id: BrowserId, u: []u8, port: u16, path: []const u8, ready: []const u8) !void {
    try host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = browsers_check.url(u, port, path) } });
    if (!waitTitle(host, id, ready)) return error.PageNotReady;
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } });
}

fn reply(host: *Host, id: BrowserId, request: RequestId, accept: bool) !void {
    try host.send(.{ .dialog_reply = .{ .browser = id, .request = request, .accept = accept, .text = "" } });
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail_buf: [320]u8 = undefined;
    var u: [256]u8 = undefined;
    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        os.sleepMs(500);
    }
    try browsers_check.handshake(&host);

    // ── 묻지 않는 페이지 ──
    {
        try open(&host, 41, &u, port, "/title?t=plain", "plain");
        try click(&host, 41);
        try host.send(.{ .close_asking = 41 });
        const plain = watch(&host, 41, 3000, false);
        try open(&host, 42, &u, port, "/unload", "unload-ready"); // 걸지 않았다(클릭 없음)
        try host.send(.{ .close_asking = 42 });
        const idle = watch(&host, 42, 3000, false);
        report(plain.closed_ms >= 0 and plain.dialogs == 0 and idle.closed_ms >= 0 and idle.dialogs == 0, "close-ask-plain", std.fmt.bufPrint(&detail_buf, "처리기 없음: 닫힘 {d} ms·질문 {d} · 사용자 동작 없음: 닫힘 {d} ms·질문 {d}", .{ plain.closed_ms, plain.dialogs, idle.closed_ms, idle.dialogs }) catch "");
    }

    // ── 머무르기 → 떠나기 ──
    {
        try open(&host, 43, &u, port, "/unload", "unload-ready");
        try click(&host, 43);
        const armed = waitTitle(&host, 43, "unload-armed-1");
        try host.send(.{ .close_asking = 43 });
        const asked = watch(&host, 43, 5000, true);
        var stayed: Seen = .{};
        var responsive = false;
        if (asked.request != 0) {
            try reply(&host, 43, asked.request, false);
            stayed = watch(&host, 43, 2000, false);
            try click(&host, 43);
            responsive = waitTitle(&host, 43, "unload-armed-2");
        }
        report(armed and asked.dialogs == 1 and asked.closed_ms < 0 and stayed.closed_ms < 0 and stayed.dialogs == 0 and responsive, "close-ask-stay", std.fmt.bufPrint(&detail_buf, "걸림 {} · 물으면 before_unload {d} · 머무르기 뒤 2 초 닫힘 {d} ms·다시 질문 {d} · 페이지가 반응 {}", .{ armed, asked.dialogs, stayed.closed_ms, stayed.dialogs, responsive }) catch "");

        try host.send(.{ .close_asking = 43 });
        const again = watch(&host, 43, 5000, true);
        var left: Seen = .{};
        if (again.request != 0) {
            try reply(&host, 43, again.request, true);
            left = watch(&host, 43, 3000, false);
        }
        report(again.dialogs == 1 and left.closed_ms >= 0, "close-ask-leave", std.fmt.bufPrint(&detail_buf, "다시 물으면 before_unload {d} · 떠나기면 닫힘 {d} ms", .{ again.dialogs, left.closed_ms }) catch "");
    }

    // ── 처리기가 멈춘 페이지 ──
    {
        try open(&host, 44, &u, port, "/unload-hang", "hang-ready");
        try click(&host, 44);
        const armed = waitTitle(&host, 44, "hang-armed");
        try host.send(.{ .close_asking = 44 });
        const quiet = watch(&host, 44, 2000, false);
        // 강제로 닫아도 CEF 는 멈춘 처리기가 끝날 때까지 닫지 않는다(실측 — 이 PR 전의 강제 닫기도 같다). maru 는 탭을 먼저 없앤다 —
        // sidecar 는 그동안 다른 명령을 받고, 처리기가 끝나면 닫힌다(늦은 질문은 닫히는 중이라 묻지 않고 떠나기).
        const forced_at = os.nowMs();
        try host.send(.{ .destroy_browser = 44 });
        open(&host, 45, &u, port, "/title?t=after-hang", "after-hang") catch {};
        const responsive_ms = os.nowMs() - forced_at;
        const forced = watch(&host, 44, 25_000, false);
        const closed_after = if (forced.closed_ms >= 0) os.nowMs() - forced_at else -1;
        report(armed and quiet.closed_ms < 0 and quiet.dialogs == 0 and responsive_ms < 10_000 and closed_after >= 0 and forced.dialogs == 0, "close-ask-hung", std.fmt.bufPrint(&detail_buf, "걸림 {} · 물은 뒤 2 초 닫힘 {d} ms·질문 {d} · 강제로 닫은 뒤 새 브라우저 {d} ms · 처리기가 끝나 닫힘 {d} ms(질문 {d})", .{ armed, quiet.closed_ms, quiet.dialogs, responsive_ms, closed_after, forced.dialogs }) catch "");
        try host.send(.{ .destroy_browser = 45 });
        _ = watch(&host, 45, 3000, false);
    }

    // ── 두 번 연달아 ──
    {
        try open(&host, 46, &u, port, "/unload", "unload-ready");
        try click(&host, 46);
        _ = waitTitle(&host, 46, "unload-armed-1");
        try host.send(.{ .close_asking = 46 });
        try host.send(.{ .close_asking = 46 });
        const asked = watch(&host, 46, 2000, false);
        var left: Seen = .{};
        if (asked.request != 0) {
            try reply(&host, 46, asked.request, true);
            left = watch(&host, 46, 3000, false);
        }
        report(asked.dialogs >= 1 and left.closed_ms >= 0, "close-ask-twice", std.fmt.bufPrint(&detail_buf, "질문 {d} 개(마지막 요청 {d}) · 떠나기면 닫힘 {d} ms", .{ asked.dialogs, asked.request, left.closed_ms }) catch "");
    }

    // ── 모르는 브라우저 ──
    {
        try host.send(.{ .close_asking = 999 });
        const unknown = watch(&host, 999, 2000, false);
        report(unknown.failure == .unknown_browser, "close-ask-unknown", if (unknown.failure) |f| @tagName(f) else "실패 없음");
    }
}
