//! W5b 판정 — 페이지의 권한 요청이 maru 로 와서 maru 의 답으로 끝나는가, 답을 Chromium 이 기억하는가(docs/plans/web-osr-backend.md
//! C6). 판정자가 maru 역할로 답한다.
//!
//!   perm-asks          알림 요청이 `permission_request`(알림 비트·출처)로 온다 — 그동안 host 창 0 개. 허용하면 페이지가 `granted`
//!   perm-deny          MIDI sysex 차단 → 페이지가 `NotAllowedError`
//!   perm-dismiss       로컬 글꼴 닫기 → 페이지는 빈 목록을 받고(`queryLocalFonts` 는 거절을 빈 목록으로 준다), 다시 청하면 또
//!                      묻는다(닫기는 기억하지 않는다) — 이번엔 허용해 글꼴이 온다
//!   perm-closed        묻는 동안 maru 가 이동시키면 그 요청의 `dialog_closed` 가 오고, 늦은 답·없는 번호의 답은 조용히 버린다
//!   perm-geolocation   위치는 위치 비트로 온다(좌표는 W5b2 — 여기서는 닫기)
//!   perm-media         카메라: 장치가 있으면 미디어 요청(카메라 비트)이 와서 거부가 닿고, 없으면 요청 전에 `NotFoundError`(이 기계)
//!   perm-display       화면 공유(`getDisplayMedia`)는 미디어 요청(화면 비트)으로 온다 — 거부하면 `NotAllowedError`. 미디어 요청의
//!                      답은 Chromium 이 기억하지 않는다 — 다시 청하면 또 묻는다(W5b 실측). 허용하면 청한 비트를 그대로 돌려준다
//!                      (거부와 다른 결과 — 이 기계는 화면 기록 권한이 없어 `NotReadableError`)
//!   perm-media-left    화면 공유를 묻는 동안 **페이지가 스스로** 떠나면 그 요청의 `dialog_closed` 가 온다(미디어는 CEF 가 닫힘을
//!                      알리지 않아 새 문서에서 치운다) — 닿지 않는 주소로 떠나 이동이 실패해도(`on_load_start` 없이 오류 페이지)
//!   perm-ignore        maru 가 못 물음(IGNORE)으로 답해도 페이지는 prompt 로 남지만, Chromium 은 따로 세어 넷이면 다섯째는 묻지
//!                      않고 거절한다(embargo — 실측. 사용자 닫기는 셋)
//!   perm-remembered    host 를 다시 띄워도(같은 프로필·출처) 허용한 알림·글꼴은 묻지 않고 허용, 차단한 MIDI 는 묻지 않고 거절
//!                      (사용자 결정 2026-09-25 — Chromium 이 출처별로 기억한다)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const windows = @import("windows.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const message = protocol.message;
const BrowserId = message.BrowserId;
const RequestId = message.RequestId;
const PermissionKind = message.PermissionKind;
const MediaPermission = message.MediaPermission;

pub const Report = browsers_check.Report;

const id: BrowserId = 6;
const wait_ms = 15_000;
const size: message.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };

/// 받은 요청(출처는 다음 `next` 에서 무효라 복사해 둔다).
const Asked = struct {
    request: RequestId = 0,
    kinds: u32 = 0,
    media: u8 = 0,
    origin_buf: [protocol.fields.max_origin_bytes]u8 = undefined,
    origin_len: usize = 0,

    fn origin(self: *const Asked) []const u8 {
        return self.origin_buf[0..self.origin_len];
    }
};

/// 한 번 청한 결과 — 요청이 왔으면 `asked`, 요청 없이 페이지가 끝났으면 `title`.
const Outcome = struct {
    asked: ?Asked = null,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,

    fn title(self: *const Outcome) []const u8 {
        return self.title_buf[0..self.title_len];
    }
};

/// 결과 제목(`<action>:…`, 준비 알림 말고)을 기다린다. 그 사이 온 권한 요청은 `asked` 에 적고 멈춘다.
fn waitResult(host: *Host, action: []const u8, stop_on_request: bool, out: *Outcome) void {
    var ready_buf: [64]u8 = undefined;
    const ready = std.fmt.bufPrint(&ready_buf, "{s}:ready", .{action}) catch unreachable;
    const deadline = os.nowMs() + wait_ms;
    while (os.nowMs() < deadline) {
        const next = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return) orelse return;
        switch (next) {
            .permission_request => |value| if (value.browser == id) {
                var asked: Asked = .{ .request = value.request, .kinds = value.kinds, .media = value.media, .origin_len = value.origin.len };
                @memcpy(asked.origin_buf[0..value.origin.len], value.origin);
                out.asked = asked;
                if (stop_on_request) return;
            },
            .title_changed => |value| if (value.browser == id and std.mem.startsWith(u8, value.text, action) and
                value.text.len > action.len and value.text[action.len] == ':' and !std.mem.eql(u8, value.text, ready))
            {
                const len = @min(value.text.len, out.title_buf.len);
                @memcpy(out.title_buf[0..len], value.text[0..len]);
                out.title_len = len;
                return;
            },
            else => {},
        }
    }
}

fn waitTitle(host: *Host, text: []const u8) bool {
    const deadline = os.nowMs() + wait_ms;
    while (os.nowMs() < deadline) {
        const next = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return false) orelse return false;
        if (next == .title_changed and next.title_changed.browser == id and std.mem.eql(u8, next.title_changed.text, text)) return true;
    }
    return false;
}

/// `/perm?a=<action>` 을 열고 눌러 청한다. 요청이 오면 거기서 멈춘다(답은 호출자가).
fn ask(host: *Host, u: []u8, port: u16, action: []const u8) !Outcome {
    var path_buf: [64]u8 = undefined;
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(u, port, std.fmt.bufPrint(&path_buf, "/perm?a={s}", .{action}) catch unreachable) } });
    var ready_buf: [64]u8 = undefined;
    if (!waitTitle(host, std.fmt.bufPrint(&ready_buf, "{s}:ready", .{action}) catch unreachable)) return error.PageNotReady;
    // 첫 프레임 뒤 약 0.5 초의 입력은 렌더러가 버린다(W4a 실측).
    os.sleepMs(800);
    try host.send(.{ .mouse = .{ .browser = id, .kind = .down, .point = .{ .x = 100, .y = 100 }, .click_count = 1 } });
    try host.send(.{ .mouse = .{ .browser = id, .kind = .up, .point = .{ .x = 100, .y = 100 }, .click_count = 1 } });
    var outcome: Outcome = .{};
    waitResult(host, action, true, &outcome);
    return outcome;
}

/// 답하고 페이지의 결과 제목을 돌려준다.
fn answer(host: *Host, action: []const u8, request: RequestId, result: message.PermissionResult) !Outcome {
    try host.send(.{ .permission_reply = .{ .browser = id, .request = request, .result = result } });
    var outcome: Outcome = .{};
    waitResult(host, action, false, &outcome);
    return outcome;
}

fn endsWith(outcome: *const Outcome, suffix: []const u8) bool {
    return std.mem.endsWith(u8, outcome.title(), suffix);
}

/// 허용된 글꼴 목록이 왔다(`fonts:ok<1 이상>`).
fn fontsListed(outcome: *const Outcome) bool {
    const t = outcome.title();
    return std.mem.startsWith(u8, t, "fonts:ok") and t.len > "fonts:ok".len and !std.mem.eql(u8, t, "fonts:ok0");
}

/// 요청 없이 끝났는가(기억한 답).
fn silent(outcome: *const Outcome) bool {
    return outcome.asked == null;
}

/// 그 요청의 `dialog_closed` 가 오는가.
fn waitClosed(host: *Host, request: RequestId) bool {
    if (request == 0) return false;
    const deadline = os.nowMs() + wait_ms;
    while (os.nowMs() < deadline) {
        const next = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return false) orelse return false;
        if (next == .dialog_closed and next.dialog_closed.browser == id and next.dialog_closed.request == request) return true;
    }
    return false;
}

/// 판정 시작 전 새 브라우저를 만든다.
fn start(host_path: [:0]const u8, profile_arg: [:0]const u8, u: []u8, port: u16) !Host {
    var host = try Host.spawn(host_path, profile_arg);
    errdefer host.send(.shutdown) catch {};
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = browsers_check.url(u, port, "/title?t=perm-start") } });
    if (!waitTitle(&host, "perm-start")) return error.PageNotReady;
    try host.send(.{ .set_focus = .{ .browser = id, .value = true } });
    return host;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail_buf: [400]u8 = undefined;
    var u: [256]u8 = undefined;
    var origin_buf: [64]u8 = undefined;
    const origin = std.fmt.bufPrint(&origin_buf, "http://127.0.0.1:{d}", .{port}) catch unreachable;

    var host = try start(host_path, profile_arg, &u, port);

    // ── 알림 허용 ──
    const notif = try ask(&host, &u, port, "notif");
    const notif_asked = notif.asked orelse Asked{};
    const windows_while_asking = windows.ownedBy(host.pid);
    const notif_shape = notif_asked.kinds == PermissionKind.notifications.bit() and notif_asked.media == 0 and std.mem.eql(u8, notif_asked.origin(), origin);
    const granted = if (notif.asked != null) try answer(&host, "notif", notif_asked.request, .accept) else Outcome{};
    report(notif_shape and windows_while_asking == 0 and endsWith(&granted, ":granted"), "perm-asks", std.fmt.bufPrint(&detail_buf, "알림 요청(비트 0x{x} · 출처 {s}) 모양 {} · 묻는 동안 host 창 {d} 개 · 허용 → {s}", .{ notif_asked.kinds, notif_asked.origin(), notif_shape, windows_while_asking, granted.title() }) catch "");

    // ── MIDI 차단 ──
    const midi = try ask(&host, &u, port, "midi");
    const midi_asked = midi.asked orelse Asked{};
    const denied = if (midi.asked != null) try answer(&host, "midi", midi_asked.request, .deny) else Outcome{};
    report(midi_asked.kinds == PermissionKind.midi_sysex.bit() and endsWith(&denied, ":err-NotAllowedError"), "perm-deny", std.fmt.bufPrint(&detail_buf, "MIDI sysex 요청(비트 0x{x}) · 차단 → {s}", .{ midi_asked.kinds, denied.title() }) catch "");

    // ── 글꼴 닫기 → 다시 묻는다 ──
    const fonts = try ask(&host, &u, port, "fonts");
    const fonts_asked = fonts.asked orelse Asked{};
    const dismissed = if (fonts.asked != null) try answer(&host, "fonts", fonts_asked.request, .dismiss) else Outcome{};
    const fonts_again = try ask(&host, &u, port, "fonts");
    const fonts_again_asked = fonts_again.asked orelse Asked{};
    const fonts_ok = if (fonts_again.asked != null) try answer(&host, "fonts", fonts_again_asked.request, .accept) else Outcome{};
    report(fonts_asked.kinds == PermissionKind.local_fonts.bit() and endsWith(&dismissed, ":ok0") and fonts_again.asked != null and fontsListed(&fonts_ok), "perm-dismiss", std.fmt.bufPrint(&detail_buf, "로컬 글꼴(비트 0x{x}) 닫기 → {s} · 다시 청하면 또 묻는다 {} · 허용 → {s}", .{ fonts_asked.kinds, dismissed.title(), fonts_again.asked != null, fonts_ok.title() }) catch "");

    // ── 묻는 동안 이동 ──
    const screens = try ask(&host, &u, port, "screens");
    const screens_asked = screens.asked orelse Asked{};
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/title?t=perm-moved") } });
    var closed_request: RequestId = 0;
    var moved = false;
    const move_deadline = os.nowMs() + wait_ms;
    while ((closed_request == 0 or !moved) and os.nowMs() < move_deadline) {
        const next = (host.next(@intCast(@max(move_deadline - os.nowMs(), 1))) catch break) orelse break;
        switch (next) {
            .dialog_closed => |value| if (value.browser == id) {
                closed_request = value.request;
            },
            .title_changed => |value| if (value.browser == id and std.mem.eql(u8, value.text, "perm-moved")) {
                moved = true;
            },
            else => {},
        }
    }
    // 늦은 답·없는 번호의 답은 버린다(채널이 닫히거나 실패가 나지 않는다).
    try host.send(.{ .permission_reply = .{ .browser = id, .request = screens_asked.request, .result = .accept } });
    try host.send(.{ .permission_reply = .{ .browser = id, .request = 999_999, .result = .accept } });
    try host.send(.{ .navigate = .{ .browser = id, .url = browsers_check.url(&u, port, "/title?t=perm-alive") } });
    const alive = waitTitle(&host, "perm-alive");
    report(screens_asked.kinds == PermissionKind.window_management.bit() and closed_request == screens_asked.request and closed_request != 0 and moved and alive, "perm-closed", std.fmt.bufPrint(&detail_buf, "창 관리 요청 {d}(비트 0x{x}) 중 이동 → dialog_closed {d} · 옮겨 감 {} · 늦은 답 뒤 계속 명령 받음 {}", .{ screens_asked.request, screens_asked.kinds, closed_request, moved, alive }) catch "");

    // ── 위치(비트만) ──
    const geo = try ask(&host, &u, port, "geo");
    const geo_asked = geo.asked orelse Asked{};
    const geo_done = if (geo.asked != null) try answer(&host, "geo", geo_asked.request, .dismiss) else Outcome{};
    report(geo_asked.kinds == PermissionKind.geolocation.bit() and endsWith(&geo_done, ":geo-err1"), "perm-geolocation", std.fmt.bufPrint(&detail_buf, "위치 요청(비트 0x{x}) · 닫기 → {s}", .{ geo_asked.kinds, geo_done.title() }) catch "");

    // ── 카메라 ──
    const cam = try ask(&host, &u, port, "cam");
    if (cam.asked) |asked| {
        const cam_done = try answer(&host, "cam", asked.request, .deny);
        report(asked.media == MediaPermission.camera.bit() and asked.kinds == 0 and endsWith(&cam_done, ":err-NotAllowedError"), "perm-media", std.fmt.bufPrint(&detail_buf, "카메라 미디어 요청(비트 0x{x}) · 거부 → {s}", .{ asked.media, cam_done.title() }) catch "");
    } else {
        report(endsWith(&cam, ":err-NotFoundError"), "perm-media", std.fmt.bufPrint(&detail_buf, "이 기계에 카메라가 없다 — 요청 전에 {s}", .{cam.title()}) catch "");
    }

    // ── 화면 공유 ──
    const display = try ask(&host, &u, port, "display");
    const display_asked = display.asked orelse Asked{};
    const display_done = if (display.asked != null) try answer(&host, "display", display_asked.request, .deny) else Outcome{};
    // 미디어 요청의 답은 Chromium 이 기억하지 않는다 — 다시 청하면 또 묻는다(프롬프트와 다르다).
    const display_again = try ask(&host, &u, port, "display");
    const display_again_done = if (display_again.asked) |again| try answer(&host, "display", again.request, .dismiss) else Outcome{};
    const display_accept = try ask(&host, &u, port, "display");
    const display_accepted = if (display_accept.asked) |again| try answer(&host, "display", again.request, .accept) else Outcome{};
    const accept_differs = display_accept.asked != null and display_accepted.title_len > 0 and !endsWith(&display_accepted, ":err-NotAllowedError");
    report(display_asked.media & MediaPermission.screen.bit() != 0 and display_asked.kinds == 0 and endsWith(&display_done, ":err-NotAllowedError") and display_again.asked != null and endsWith(&display_again_done, ":err-NotAllowedError") and accept_differs, "perm-display", std.fmt.bufPrint(&detail_buf, "화면 공유 미디어 요청(비트 0x{x}) · 거부 → {s} · 기억하지 않아 다시 묻는다 {} · 닫기 → {s} · 허용 → {s}", .{ display_asked.media, display_done.title(), display_again.asked != null, display_again_done.title(), display_accepted.title() }) catch "");

    // ── 묻는 동안 페이지가 스스로 떠남(미디어) ──
    const leaving = try ask(&host, &u, port, "displayleave");
    const leaving_asked = leaving.asked orelse Asked{};
    var left_closed: RequestId = 0;
    var left = false;
    const left_deadline = os.nowMs() + wait_ms;
    while ((left_closed == 0 or !left) and os.nowMs() < left_deadline) {
        const next = (host.next(@intCast(@max(left_deadline - os.nowMs(), 1))) catch break) orelse break;
        switch (next) {
            .dialog_closed => |value| if (value.browser == id) {
                left_closed = value.request;
            },
            .title_changed => |value| if (value.browser == id and std.mem.eql(u8, value.text, "perm-left")) {
                left = true;
            },
            else => {},
        }
    }
    // 실패한 이동(닿지 않는 주소)은 `on_load_start` 없이 오류 페이지로 바뀐다 — 그래도 요청은 닫힌다(`on_load_error`).
    const failing = try ask(&host, &u, port, "displayfail");
    const failing_asked = failing.asked orelse Asked{};
    const fail_closed = waitClosed(&host, failing_asked.request);
    report(leaving_asked.media != 0 and left_closed == leaving_asked.request and left_closed != 0 and left and failing_asked.media != 0 and fail_closed, "perm-media-left", std.fmt.bufPrint(&detail_buf, "화면 공유 요청 {d} 중 페이지가 스스로 떠남 → dialog_closed {d} · 옮겨 감 {} · 닿지 않는 주소로 떠나도 닫힘 {}", .{ leaving_asked.request, left_closed, left, fail_closed }) catch "");

    // ── 못 물음(IGNORE) 되풀이 ── Chromium 은 따로 센다: 넷이면 다섯째는 묻지 않고 거절한다(embargo — 실측을 판정으로 남긴다.
    // CEF 를 올려 바뀌면 maru 가 자동으로 보내는 IGNORE 의 대가가 달라진다).
    var ignored: usize = 0;
    var ignore_prompt = true;
    while (ignored < 4) : (ignored += 1) {
        const idle = try ask(&host, &u, port, "idle");
        const asked = idle.asked orelse break;
        const done = try answer(&host, "idle", asked.request, .ignore);
        if (!endsWith(&done, ":prompt")) ignore_prompt = false;
    }
    const embargoed = try ask(&host, &u, port, "idle");
    report(ignored == 4 and ignore_prompt and silent(&embargoed) and endsWith(&embargoed, ":denied"), "perm-ignore", std.fmt.bufPrint(&detail_buf, "유휴 감지 못 물음 {d} 번(페이지는 prompt 로 남음 {}) → 다섯째는 묻지 않고 {s}", .{ ignored, ignore_prompt, embargoed.title() }) catch "");

    // ── 다시 띄워도 기억한다 ──
    try host.send(.shutdown);
    _ = host.wait(wait_ms);
    host = try start(host_path, profile_arg, &u, port);
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    const notif_kept = try ask(&host, &u, port, "notif");
    const midi_kept = try ask(&host, &u, port, "midi");
    const fonts_kept = try ask(&host, &u, port, "fonts");
    report(silent(&notif_kept) and endsWith(&notif_kept, ":granted") and silent(&midi_kept) and endsWith(&midi_kept, ":err-NotAllowedError") and silent(&fonts_kept) and fontsListed(&fonts_kept), "perm-remembered", std.fmt.bufPrint(&detail_buf, "다시 띄운 host 에서 묻지 않고: 알림 {s}({}) · MIDI {s}({}) · 글꼴 {s}({})", .{ notif_kept.title(), silent(&notif_kept), midi_kept.title(), silent(&midi_kept), fonts_kept.title(), silent(&fonts_kept) }) catch "");
}
