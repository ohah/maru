//! 사이트 권한 판정(2026-11-18 — 사람의 「Site Permissions…」 창). Chromium 이 기억한 허용·차단이 `site_permissions_list` 로 읽히고,
//! `site_permissions` 의 지우기로 기본(묻기)에 돌아가는가. 판정자가 maru 역할로 권한에 답한다(`permissions_check` 의 길).
//!
//!   site-perms-empty   새 프로필 — 목록이 비고(행 0·`total` 0) 요청 번호가 그대로 돌아온다
//!   site-perms-list    알림 허용·MIDI 차단 뒤 목록에 (출처, notifications, 허용)·(출처, midi_sysex, 차단)이 있다, 닫기(글꼴)는 없다
//!   site-perms-reset   알림을 지우면 목록에서 빠지고(MIDI 는 남는다) 다시 청하면 **다시 묻는다** · MIDI 를 지우면 그것도 다시 묻는다
//!   site-perms-bad     모르는 출처·이미 기본인 것을 지워도 목록이 온다(채널이 닫히지 않는다)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");
const perm = @import("permissions_check.zig");

const message = protocol.message;
pub const Report = browsers_check.Report;

const wait_ms = 10_000;

const Listed = struct {
    ok: bool = false,
    request: u32 = 0,
    total: u32 = 0,
    count: usize = 0,
    notif: ?message.SitePermissionSetting = null,
    midi: ?message.SitePermissionSetting = null,
    fonts: ?message.SitePermissionSetting = null,
};

/// 묻고(지울 것이 있으면 함께) 그 번호의 목록을 기다린다. 우리 출처의 행만 본다.
fn query(host: *Host, request: u32, reset: ?message.SitePermissionKind, reset_origin: []const u8, origin: []const u8) !Listed {
    try host.send(.{ .site_permissions = .{ .request = request, .reset_kind = if (reset) |k| @backingInt(k) else 0, .reset_origin = if (reset != null) reset_origin else "" } });
    const deadline = os.nowMs() + wait_ms;
    while (os.nowMs() < deadline) {
        const next = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return .{}) orelse return .{};
        if (next != .site_permissions_list) continue;
        const v = next.site_permissions_list;
        if (v.request != request) continue;
        var out: Listed = .{ .ok = true, .request = v.request, .total = v.total, .count = v.count };
        for (v.slice()) |e| {
            if (!std.mem.eql(u8, e.origin, origin)) continue;
            switch (e.kind) {
                .notifications => out.notif = e.setting,
                .midi_sysex => out.midi = e.setting,
                .local_fonts => out.fonts = e.setting,
                else => {},
            }
        }
        return out;
    }
    return .{};
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail_buf: [400]u8 = undefined;
    var u: [256]u8 = undefined;
    var origin_buf: [64]u8 = undefined;
    const origin = std.fmt.bufPrint(&origin_buf, "http://127.0.0.1:{d}", .{port}) catch unreachable;
    var host = try perm.start(host_path, profile_arg, &u, port);
    defer host.send(.shutdown) catch {};

    const empty = try query(&host, 1, null, "", origin);
    report(empty.ok and empty.request == 1 and empty.count == 0 and empty.total == 0, "site-perms-empty", std.fmt.bufPrint(&detail_buf, "새 프로필 목록 — 답 {} · 행 {d} · total {d}", .{ empty.ok, empty.count, empty.total }) catch "");

    const notif = try perm.ask(&host, &u, port, "notif");
    if (notif.asked) |a| _ = try perm.answer(&host, "notif", a.request, .accept);
    const midi = try perm.ask(&host, &u, port, "midi");
    if (midi.asked) |a| _ = try perm.answer(&host, "midi", a.request, .deny);
    const fonts = try perm.ask(&host, &u, port, "fonts");
    if (fonts.asked) |a| _ = try perm.answer(&host, "fonts", a.request, .dismiss);
    const listed = try query(&host, 2, null, "", origin);
    report(listed.ok and listed.notif == .allow and listed.midi == .block and listed.fonts == null, "site-perms-list", std.fmt.bufPrint(&detail_buf, "알림 허용·MIDI 차단·글꼴 닫기 뒤 — 알림 {?} · MIDI {?} · 글꼴 {?} · 행 {d}", .{ listed.notif, listed.midi, listed.fonts, listed.count }) catch "");

    const after_reset = try query(&host, 3, .notifications, origin, origin);
    const again = try perm.ask(&host, &u, port, "notif");
    const asked_again = again.asked != null;
    if (again.asked) |a| _ = try perm.answer(&host, "notif", a.request, .dismiss);
    const midi_reset = try query(&host, 4, .midi_sysex, origin, origin);
    const midi_again = try perm.ask(&host, &u, port, "midi");
    const midi_asked_again = midi_again.asked != null;
    if (midi_again.asked) |a| _ = try perm.answer(&host, "midi", a.request, .dismiss);
    report(after_reset.ok and after_reset.notif == null and after_reset.midi == .block and asked_again and midi_reset.ok and midi_reset.midi == null and midi_asked_again, "site-perms-reset", std.fmt.bufPrint(&detail_buf, "알림 지움 → 알림 {?} · MIDI {?} · 다시 청하면 묻는다 {} · MIDI 지움 → {?} · 다시 묻는다 {}", .{ after_reset.notif, after_reset.midi, asked_again, midi_reset.midi, midi_asked_again }) catch "");

    const unknown = try query(&host, 5, .geolocation, "https://never.example", origin);
    const default_again = try query(&host, 6, .notifications, origin, origin);
    report(unknown.ok and default_again.ok, "site-perms-bad", std.fmt.bufPrint(&detail_buf, "모르는 출처 지움 → 답 {} · 이미 기본인 것 지움 → 답 {}", .{ unknown.ok, default_again.ok }) catch "");
}
