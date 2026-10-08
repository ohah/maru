//! 다운로드 판정(W10a): sidecar 는 다운로드마다 `download_begin` 을 보내고 maru 의 `download_decide` 까지 기다린다 — 경로는 maru 만
//! 정한다. 판정자가 maru 자리에서 경로를 정한다(판정 뿌리 아래 `dl-out`).
//!
//!   dl-attach      첨부(`Content-Disposition`) — 제안 이름·MIME·크기가 오고, 엉뚱한 브라우저의 결정은 버린다(받아들이면 취소가
//!                  온다 — 결정 전에도 진행 갱신은 온다, 실측). 정한 경로로 받아
//!                  완료(받은 양 = 크기), 내용이 같고 격리 표지(`com.apple.quarantine`)가 붙는다
//!   dl-name-tidy   서버가 준 이름의 제어 문자·`/` 는 이름에 남지 않는다(비지 않는다) — Chromium 이 먼저 `_` 로 바꾼다(실측
//!                  `a_b_c_.._d.txt`), sidecar 의 다듬기는 그다음 방어라 이 판정으로는 갈리지 않는다
//!   dl-decline     빈 경로로 결정하면 `canceled` 가 오고 파일이 생기지 않으며 그 뒤 갱신이 없다
//!   dl-data-url    5000 바이트 data: 주소 — 주소는 2048 바이트 안으로 줄여 begin 이 온다(코덱에 막혀 붙들리지 않는다)
//!   dl-progress    느린 다운로드(초당 10 조각)의 진행 갱신은 초당 4 번을 넘지 않고 받은 양이 는다. 엉뚱한 브라우저의 취소는 버린다.
//!                  Chromium 스스로도 갱신을 모아 보낸다(실측 1.5 초에 4 번) — sidecar 의 250 ms 간격은 그보다 잦은 갱신의 방어다
//!   dl-cancel      받는 중 취소하면 `canceled` 가 오고 덜 받은 파일이 지워진다
//!   dl-closed      받는 중 브라우저를 닫으면 `browser_closed` 가 온다(CEF 는 알림 없이 멈춘다 — 실측)
//!   dl-multiple    사용자 동작 없는 둘째 자동 다운로드는 「여러 파일 받기」 권한을 묻고, 허용하면 begin 이 온다
//!   dl-page-started 새 문서 표지(`page_started`)는 페이지를 불러오거나 다른 문서로 갈 때 오고, pushState·다운로드가 된 이동에는
//!                  오지 않는다(maru 가 「이 문서의 사용자 동작」을 가르는 표지 — 적대 리뷰 2 회차)
//!   dl-same-file   maru 처럼 경로를 O_EXCL 로 미리 만들어 주면 Chromium 은 받는 동안 그 파일(같은 inode)에 쓴다 — maru 는 만든
//!                  파일의 dev·ino 로만 지우므로 덜 받은 파일을 놓치지 않는다. 미리 만든 파일은 취소해도 Chromium 이 **남기고**(maru 가
//!                  지운다), 완료 때는 **다른 inode** 로 바꿔 놓는다(maru 는 경로로 옮긴다) — 2 회차 실측, 보고 줄에 남긴다
//!   dl-ask-wait    결정을 10 초 미뤄도(W10b 「매번 묻기」의 저장 창이 떠 있는 동안) 다운로드는 이어지고, 그동안 host 가 연 파일 중
//!                  다운로드 임시 파일(`.crdownload`·`Unconfirmed`)이 없는지와 받아 둔 양을 보고 줄에 남긴다(W10b 설계 공격 M1 실측)
//!   dl-late-decide 결정을 2 초 늦게 보내도(보류 뒤 받기·TCC 질문) 받기를 이어 가고, 받는 동안·취소 뒤의 그 경로 파일을 보고 줄에
//!                  남긴다(늦은 결정이면 Chromium 이 자기 임시 파일에서 옮겨 와 inode 가 바뀌는지 — 3 회차 실측)
const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const http = @import("http.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");

const message_mod = protocol.message;
const BrowserId = message_mod.BrowserId;

pub const Report = browsers_check.Report;
const size: message_mod.ViewSize = .{ .width = 640, .height = 400, .scale = 2 };
const wait_ms = 15_000;

extern "c" fn getxattr(path: [*:0]const u8, name: [*:0]const u8, value: ?*anyopaque, size: usize, position: u32, options: c_int) isize;

/// 브라우저마다 받은 `page_started` 수(판정의 번호는 128 아래).
var page_starts = [_]u32{0} ** 128;

fn countPageStart(message: protocol.message.Message) void {
    if (message == .page_started and message.page_started < page_starts.len) page_starts[message.page_started] += 1;
}

extern "c" fn fstat(fd: c_int, buf: *std.c.Stat) c_int;

/// maru 처럼 받을 자리를 O_EXCL 로 미리 만들고 그 inode 를 돌려준다.
fn precreate(path: [:0]const u8) ?u64 {
    const fd = std.c.open(path, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o644));
    if (fd < 0) return null;
    defer _ = std.c.close(fd);
    var st: std.c.Stat = undefined;
    if (fstat(fd, &st) != 0) return null;
    return @intCast(st.ino);
}

fn inodeOf(path: [:0]const u8) ?u64 {
    var st: std.c.Stat = undefined;
    if (std.c.fstatat(-2, path, &st, std.c.AT.SYMLINK_NOFOLLOW) != 0) return null;
    return @intCast(st.ino);
}

const Begin = struct {
    download: u32 = 0,
    name_buf: [256]u8 = undefined,
    name_len: usize = 0,
    mime_buf: [128]u8 = undefined,
    mime_len: usize = 0,
    url_len: usize = 0,
    total: i64 = -2,

    fn name(self: *const Begin) []const u8 {
        return self.name_buf[0..self.name_len];
    }
    fn mime(self: *const Begin) []const u8 {
        return self.mime_buf[0..self.mime_len];
    }
};

fn waitTitle(host: *Host, id: BrowserId, text: []const u8) bool {
    const deadline = os.nowMs() + wait_ms;
    while (os.nowMs() < deadline) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return false) orelse return false;
        countPageStart(message);
        if (message == .title_changed and message.title_changed.browser == id and std.mem.eql(u8, message.title_changed.text, text)) return true;
    }
    return false;
}

/// 그 브라우저의 다음 `download_begin` — `ms` 안에 없으면 null.
fn waitBegin(host: *Host, id: BrowserId, ms: u32) ?Begin {
    const deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return null) orelse return null;
        countPageStart(message);
        if (message == .download_begin and message.download_begin.browser == id) {
            const v = message.download_begin;
            var b: Begin = .{ .download = v.download, .total = v.total, .url_len = v.url.len };
            b.name_len = @min(v.name.len, b.name_buf.len);
            @memcpy(b.name_buf[0..b.name_len], v.name[0..b.name_len]);
            b.mime_len = @min(v.mime.len, b.mime_buf.len);
            @memcpy(b.mime_buf[0..b.mime_len], v.mime[0..b.mime_len]);
            return b;
        }
    }
    return null;
}

/// 한 다운로드의 진행을 본 것.
const Seen = struct {
    updates: u32 = 0,
    in_progress: u32 = 0,
    last: ?message_mod.DownloadState = null,
    received: i64 = 0,
    total: i64 = -1,
    first_ms: i64 = -1,
    last_ms: i64 = -1,
    browser_closed: bool = false,
};

/// `ms` 동안 그 다운로드의 갱신을 센다 — `stop` 이 참이면 끝 상태에서, `min_received` 가 0 보다 크면 그만큼 받으면 멈춘다.
fn watch(host: *Host, id: BrowserId, download: u32, ms: u32, stop: bool, min_received: i64) Seen {
    var seen: Seen = .{};
    const deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline) {
        const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch return seen) orelse return seen;
        countPageStart(message);
        switch (message) {
            .download_update => |u| if (u.browser == id and u.download == download) {
                const now = os.nowMs();
                if (seen.first_ms < 0) seen.first_ms = now;
                seen.last_ms = now;
                seen.updates += 1;
                if (u.state == .in_progress) seen.in_progress += 1;
                seen.last = u.state;
                seen.received = u.received;
                seen.total = u.total;
                if (u.state == .browser_closed) seen.browser_closed = true;
                const terminal = u.state != .in_progress and u.state != .interrupted;
                if (stop and terminal) return seen;
                if (min_received > 0 and u.received >= min_received) return seen;
            },
            else => {},
        }
    }
    return seen;
}

fn open(host: *Host, id: BrowserId, u: []u8, port: u16, path: []const u8) !void {
    try host.send(.{ .create_browser = .{ .browser = id, .size = size, .hidden = false, .url = browsers_check.url(u, port, path) } });
    if (!waitTitle(host, id, "dlp-ready")) return error.PageNotReady;
}

fn exists(path: [:0]const u8) bool {
    return std.c.access(path, 0) == 0;
}

fn sameContent(path: [:0]const u8, want: []const u8) bool {
    const fd = std.c.open(path, .{});
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    return n == @as(isize, @intCast(want.len)) and std.mem.eql(u8, buf[0..want.len], want);
}

/// 받은 파일의 앞 4 KiB 가 모두 `byte` 인가(느린·큰 다운로드의 내용).
fn sameContentPrefix(path: [:0]const u8, byte: u8) bool {
    const fd = std.c.open(path, .{});
    if (fd < 0) return false;
    defer _ = std.c.close(fd);
    var buf: [4096]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    if (n <= 0) return false;
    for (buf[0..@intCast(n)]) |b| if (b != byte) return false;
    return true;
}

fn quarantined(path: [:0]const u8) bool {
    return getxattr(path, "com.apple.quarantine", null, 0, 0, 0) > 0;
}

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, out_root: []const u8, port: u16) !void {
    var detail_buf: [400]u8 = undefined;
    var u: [256]u8 = undefined;
    var dir_buf: [1024]u8 = undefined;
    const dir = try std.fmt.bufPrintZ(&dir_buf, "{s}/dl-out", .{out_root});
    _ = std.c.mkdir(dir, 0o700);
    var host = try Host.spawn(host_path, profile_arg);
    defer {
        host.send(.shutdown) catch {};
        os.sleepMs(500);
    }
    try browsers_check.handshake(&host);

    // ── 첨부: 결정 → 완료 ──
    check: {
        var path_buf: [1100]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/report.txt", .{dir});
        try open(&host, 61, &u, port, "/dlp?a=attach");
        const begin = waitBegin(&host, 61, 5000) orelse {
            report(false, "dl-attach", "download_begin 이 오지 않았다");
            break :check;
        };
        // 엉뚱한 브라우저의 결정(빈 경로 = 취소)은 버린다 — 받아들이면 이 다운로드가 취소된다.
        try host.send(.{ .download_decide = .{ .browser = 999, .download = begin.download, .path = "" } });
        const stray = watch(&host, 61, begin.download, 700, true, 0);
        try host.send(.{ .download_decide = .{ .browser = 61, .download = begin.download, .path = path } });
        const done = watch(&host, 61, begin.download, 10_000, true, 0);
        const content = sameContent(path, http.download_body);
        const quarantine = quarantined(path);
        report(std.mem.eql(u8, begin.name(), "report.txt") and std.mem.startsWith(u8, begin.mime(), "text/plain") and begin.total == http.download_body.len and
            (stray.last == null or stray.last == .in_progress) and done.last == .complete and done.received == http.download_body.len and content and quarantine, "dl-attach", std.fmt.bufPrint(&detail_buf, "이름 {s} · MIME {s} · 크기 {d} · 엉뚱한 브라우저 결정 뒤 {s} · 끝 {s}({d}/{d}) · 내용 같음 {} · 격리 표지 {}", .{
            begin.name(),  begin.mime(), begin.total,
            if (stray.last) |s| @tagName(s) else "갱신 없음",
            if (done.last) |s| @tagName(s) else "없음",
            done.received, done.total,   content,
            quarantine,
        }) catch "");
    }

    // ── 이름 다듬기·받지 않기 ──
    check: {
        try open(&host, 62, &u, port, "/dlp?a=ctl");
        const begin = waitBegin(&host, 62, 5000) orelse {
            report(false, "dl-name-tidy", "download_begin 이 오지 않았다");
            break :check;
        };
        var clean = begin.name_len > 0 and std.mem.indexOfScalar(u8, begin.name(), '/') == null;
        for (begin.name()) |byte| {
            if (byte < 0x20 or byte == 0x7f) clean = false;
        }
        report(clean, "dl-name-tidy", std.fmt.bufPrint(&detail_buf, "이름 {s}", .{begin.name()}) catch "");

        try host.send(.{ .download_decide = .{ .browser = 62, .download = begin.download, .path = "" } });
        const declined = watch(&host, 62, begin.download, 3000, true, 0);
        const after = watch(&host, 62, begin.download, 1000, false, 0);
        var listing_buf: [1100]u8 = undefined;
        const listing = try std.fmt.bufPrintZ(&listing_buf, "{s}/{s}", .{ dir, begin.name() });
        const created = exists(listing);
        report(declined.last == .canceled and after.updates == 0 and !created, "dl-decline", std.fmt.bufPrint(&detail_buf, "끝 {s} · 그 뒤 1 초 갱신 {d} · 파일 생김 {}", .{ if (declined.last) |s| @tagName(s) else "없음", after.updates, created }) catch "");
    }

    // ── 긴 data: 주소 ──
    {
        try open(&host, 63, &u, port, "/dlp?a=data");
        const begin = waitBegin(&host, 63, 5000);
        if (begin) |b| try host.send(.{ .download_decide = .{ .browser = 63, .download = b.download, .path = "" } });
        const ok = if (begin) |b| b.url_len > 0 and b.url_len <= message_mod.max_download_url_bytes and std.mem.eql(u8, b.name(), "big.txt") else false;
        report(ok, "dl-data-url", if (begin) |b| std.fmt.bufPrint(&detail_buf, "주소 {d} 바이트 · 이름 {s}", .{ b.url_len, b.name() }) catch "" else "download_begin 이 오지 않았다");
    }

    // ── 느린 다운로드: 진행 갱신 → 엉뚱한 취소 → 취소 ──
    check: {
        var path_buf: [1100]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/slow-cancel.bin", .{dir});
        try open(&host, 64, &u, port, "/dlp?a=slow");
        const begin = waitBegin(&host, 64, 5000) orelse {
            report(false, "dl-progress", "download_begin 이 오지 않았다");
            break :check;
        };
        try host.send(.{ .download_decide = .{ .browser = 64, .download = begin.download, .path = path } });
        const progress = watch(&host, 64, begin.download, 2000, true, 0);
        try host.send(.{ .download_control = .{ .browser = 999, .download = begin.download, .action = .cancel } });
        const stray = watch(&host, 64, begin.download, 800, true, 0);
        const span_ms = progress.last_ms - progress.first_ms;
        // 2 초 동안 초당 4 번이면 8~9 번 — 넉넉히 12 번까지. 서버는 초당 10 조각을 보낸다.
        report(progress.in_progress >= 3 and progress.in_progress <= 12 and progress.received > 0 and progress.received < http.slow_bytes and
            stray.last == .in_progress, "dl-progress", std.fmt.bufPrint(&detail_buf, "2 초 동안 진행 갱신 {d} 번({d} ms 사이) · 받은 양 {d}/{d} · 엉뚱한 브라우저 취소 뒤 {s}", .{
            progress.in_progress, span_ms, progress.received, http.slow_bytes,
            if (stray.last) |s| @tagName(s) else "갱신 없음",
        }) catch "");

        const growing = exists(path);
        try host.send(.{ .download_control = .{ .browser = 64, .download = begin.download, .action = .cancel } });
        const canceled = watch(&host, 64, begin.download, 3000, true, 0);
        os.sleepMs(300);
        const left = exists(path);
        report(growing and canceled.last == .canceled and !left, "dl-cancel", std.fmt.bufPrint(&detail_buf, "받는 동안 파일 있음 {} · 취소 뒤 {s} · 남은 파일 {}", .{ growing, if (canceled.last) |s| @tagName(s) else "없음", left }) catch "");
    }

    // ── 받는 중 브라우저 닫기 ──
    check: {
        var path_buf: [1100]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/slow-close.bin", .{dir});
        try open(&host, 65, &u, port, "/dlp?a=slow");
        const begin = waitBegin(&host, 65, 5000) orelse {
            report(false, "dl-closed", "download_begin 이 오지 않았다");
            break :check;
        };
        try host.send(.{ .download_decide = .{ .browser = 65, .download = begin.download, .path = path } });
        const started = watch(&host, 65, begin.download, 3000, false, 1);
        try host.send(.{ .destroy_browser = 65 });
        const closed = watch(&host, 65, begin.download, 5000, true, 0);
        report(started.received > 0 and closed.browser_closed, "dl-closed", std.fmt.bufPrint(&detail_buf, "닫기 전 받은 양 {d} · 닫은 뒤 {s}", .{ started.received, if (closed.last) |s| @tagName(s) else "갱신 없음" }) catch "");
    }

    // ── 둘째 자동 다운로드 ──
    {
        try open(&host, 66, &u, port, "/dlp?a=two");
        const first = waitBegin(&host, 66, 5000);
        if (first) |b| try host.send(.{ .download_decide = .{ .browser = 66, .download = b.download, .path = "" } });
        var asked = false;
        var second: ?Begin = null;
        const deadline = os.nowMs() + 6000;
        while (os.nowMs() < deadline and second == null) {
            const message = (host.next(@intCast(@max(deadline - os.nowMs(), 1))) catch break) orelse break;
            countPageStart(message);
            switch (message) {
                .permission_request => |p| if (p.browser == 66 and p.kinds & message_mod.PermissionKind.multiple_downloads.bit() != 0) {
                    asked = true;
                    try host.send(.{ .permission_reply = .{ .browser = 66, .request = p.request, .result = .accept } });
                },
                .download_begin => |v| if (v.browser == 66) {
                    second = .{ .download = v.download };
                },
                else => {},
            }
        }
        if (second) |b| try host.send(.{ .download_decide = .{ .browser = 66, .download = b.download, .path = "" } });
        report(first != null and asked and second != null, "dl-multiple", std.fmt.bufPrint(&detail_buf, "첫 begin {} · 여러 파일 받기 질문 {} · 허용 뒤 둘째 begin {}", .{ first != null, asked, second != null }) catch "");
    }

    // ── 새 문서 표지 ──
    check: {
        try open(&host, 69, &u, port, "/dlp?a=push");
        const at_ready = page_starts[69];
        const begin = waitBegin(&host, 69, 5000) orelse {
            report(false, "dl-page-started", "download_begin 이 오지 않았다");
            break :check;
        };
        try host.send(.{ .download_decide = .{ .browser = 69, .download = begin.download, .path = "" } });
        _ = watch(&host, 69, begin.download, 3000, true, 0);
        const after_download = page_starts[69];
        try host.send(.{ .navigate = .{ .browser = 69, .url = browsers_check.url(&u, port, "/title?t=dl-next") } });
        const moved = waitTitle(&host, 69, "dl-next");
        const after_nav = page_starts[69];
        report(at_ready >= 1 and after_download == at_ready and moved and after_nav > after_download, "dl-page-started", std.fmt.bufPrint(&detail_buf, "불러옴 {d} · pushState·다운로드 뒤 {d} · 다른 문서로 간 뒤 {d}", .{ at_ready, after_download, after_nav }) catch "");
        try host.send(.{ .destroy_browser = 69 });
    }

    // ── 미리 만든 파일에 그대로 받는가 ──
    check: {
        var slow_buf: [1100]u8 = undefined;
        const slow_path = try std.fmt.bufPrintZ(&slow_buf, "{s}/same-slow.bin.maru-part", .{dir});
        const slow_ino = precreate(slow_path) orelse {
            report(false, "dl-same-file", "미리 만들지 못했다");
            break :check;
        };
        try open(&host, 67, &u, port, "/dlp?a=slow");
        const slow = waitBegin(&host, 67, 5000) orelse {
            report(false, "dl-same-file", "느린 다운로드의 download_begin 이 오지 않았다");
            break :check;
        };
        try host.send(.{ .download_decide = .{ .browser = 67, .download = slow.download, .path = slow_path } });
        const started = watch(&host, 67, slow.download, 4000, false, 200_000);
        const during = inodeOf(slow_path);
        try host.send(.{ .download_control = .{ .browser = 67, .download = slow.download, .action = .cancel } });
        _ = watch(&host, 67, slow.download, 3000, true, 0);
        os.sleepMs(300);
        const after_cancel = inodeOf(slow_path);

        var done_buf: [1100]u8 = undefined;
        const done_path = try std.fmt.bufPrintZ(&done_buf, "{s}/same-done.txt.maru-part", .{dir});
        const done_ino = precreate(done_path) orelse {
            report(false, "dl-same-file", "미리 만들지 못했다");
            break :check;
        };
        try open(&host, 68, &u, port, "/dlp?a=attach");
        const attach = waitBegin(&host, 68, 5000) orelse {
            report(false, "dl-same-file", "첨부의 download_begin 이 오지 않았다");
            break :check;
        };
        try host.send(.{ .download_decide = .{ .browser = 68, .download = attach.download, .path = done_path } });
        const finished = watch(&host, 68, attach.download, 10_000, true, 0);
        const after_done = inodeOf(done_path);
        const content = sameContent(done_path, http.download_body);
        report(started.received > 0 and during != null and during.? == slow_ino and finished.last == .complete and after_done != null and content, "dl-same-file", std.fmt.bufPrint(&detail_buf, "받는 중({d} 바이트) 같은 파일 {} · 취소 뒤 남음 {} · 완료 뒤 같은 파일 {} · 내용 같음 {}", .{
            started.received, during != null and during.? == slow_ino, after_cancel != null, after_done != null and after_done.? == done_ino, content,
        }) catch "");
    }

    // ── 늦은 결정 ──
    check: {
        var late_buf: [1100]u8 = undefined;
        const late_path = try std.fmt.bufPrintZ(&late_buf, "{s}/late.bin.maru-part", .{dir});
        try open(&host, 70, &u, port, "/dlp?a=slow");
        const late = waitBegin(&host, 70, 5000) orelse {
            report(false, "dl-late-decide", "download_begin 이 오지 않았다");
            break :check;
        };
        const before = watch(&host, 70, late.download, 2000, false, 0); // 결정 전 2 초 — Chromium 이 어디에 받아 두나
        const late_ino = precreate(late_path) orelse {
            report(false, "dl-late-decide", "미리 만들지 못했다");
            break :check;
        };
        try host.send(.{ .download_decide = .{ .browser = 70, .download = late.download, .path = late_path } });
        const progressed = watch(&host, 70, late.download, 4000, false, before.received + 200_000);
        const during = inodeOf(late_path);
        try host.send(.{ .download_control = .{ .browser = 70, .download = late.download, .action = .cancel } });
        const canceled = watch(&host, 70, late.download, 3000, true, 0);
        os.sleepMs(300);
        const after_cancel = inodeOf(late_path);
        // maru 의 가정 — 늦게 결정해도 그 파일(같은 inode)에 이어 쓰고 취소 뒤에도 남는다(maru 가 dev·ino 로 확인해 지운다).
        report(progressed.received > before.received and canceled.last == .canceled and during != null and during.? == late_ino and after_cancel != null and after_cancel.? == late_ino, "dl-late-decide", std.fmt.bufPrint(&detail_buf, "결정 전 2 초 받은 양 {d} · 결정 뒤 {d} · 받는 중 같은 파일 {} · 취소 뒤 남음 {}(같은 파일 {})", .{
            before.received, progressed.received, during != null and during.? == late_ino, after_cancel != null, after_cancel != null and after_cancel.? == late_ino,
        }) catch "");
    }

    // ── 오래 미룬 결정(W10b 묻기) ──
    check: {
        try open(&host, 71, &u, port, "/dlp?a=huge");
        const wait = waitBegin(&host, 71, 5000) orelse {
            report(false, "dl-ask-wait", "download_begin 이 오지 않았다");
            break :check;
        };
        const held = watch(&host, 71, wait.download, 10_000, false, 0);
        var lsof_buf: [1100]u8 = undefined;
        const lsof_path = try std.fmt.bufPrintZ(&lsof_buf, "{s}/lsof.txt", .{dir});
        var cmd_buf: [1300]u8 = undefined;
        const cmd = try std.fmt.bufPrintZ(&cmd_buf, "/usr/sbin/lsof -p {d} > '{s}' 2>/dev/null", .{ host.pid, lsof_path });
        _ = os.run(&.{ "/bin/sh", "-c", cmd.ptr });
        // 메모리(RSS)와 판정 뿌리 아래 1 MiB 넘는 새 파일 — 받아 둔 데이터가 어디에 있나.
        var rss_cmd_buf: [1400]u8 = undefined;
        const rss_cmd = try std.fmt.bufPrintZ(&rss_cmd_buf, "(ps -o rss= -p {d}; for c in $(pgrep -P {d}); do ps -o rss=,command= -p $c | cut -c1-90; done; find '{s}' /private/var/folders -newer '{s}' -size +1M -type f 2>/dev/null | head -5) >> '{s}'", .{ host.pid, host.pid, out_root, lsof_path, lsof_path });
        _ = os.run(&.{ "/bin/sh", "-c", rss_cmd.ptr });
        var temp_files: u32 = 0;
        var temp_name_buf: [200]u8 = undefined;
        var temp_name: []const u8 = "";
        {
            const fd = std.c.open(lsof_path, .{});
            if (fd >= 0) {
                defer _ = std.c.close(fd);
                var text: [65536]u8 = undefined;
                const n = std.c.read(fd, &text, text.len);
                if (n > 0) {
                    var lines = std.mem.splitScalar(u8, text[0..@intCast(n)], '\n');
                    while (lines.next()) |line| {
                        if (std.mem.indexOf(u8, line, "crdownload") != null or std.mem.indexOf(u8, line, "Unconfirmed") != null or std.mem.indexOf(u8, line, "/Downloads/") != null) {
                            temp_files += 1;
                            const tail = line[@max(line.len, 80) - 80 ..];
                            const k = @min(tail.len, temp_name_buf.len);
                            @memcpy(temp_name_buf[0..k], tail[0..k]);
                            temp_name = temp_name_buf[0..k];
                        }
                    }
                }
            }
        }
        // 받아 둔 곳 — 프로필(`<뿌리>/s`) 안 `download-staging` 의 항목 수(Chromium 의 숨은 임시 파일).
        var staged_buf: [1100]u8 = undefined;
        const staged_path = try std.fmt.bufPrintZ(&staged_buf, "{s}/staged.txt", .{dir});
        var ls_buf: [2400]u8 = undefined;
        const ls_cmd = try std.fmt.bufPrintZ(&ls_buf, "ls -A '{s}/s/download-staging' > '{s}' 2>/dev/null", .{ out_root, staged_path });
        _ = os.run(&.{ "/bin/sh", "-c", ls_cmd.ptr });
        var staged: usize = 0;
        {
            const fd = std.c.open(staged_path, .{});
            if (fd >= 0) {
                defer _ = std.c.close(fd);
                var text: [4096]u8 = undefined;
                const n = std.c.read(fd, &text, text.len);
                if (n > 0) staged = std.mem.count(u8, text[0..@intCast(n)], "\n");
            }
        }
        var path_buf: [1100]u8 = undefined;
        const path = try std.fmt.bufPrintZ(&path_buf, "{s}/ask-wait.bin", .{dir});
        try host.send(.{ .download_decide = .{ .browser = 71, .download = wait.download, .path = path } });
        const finished = watch(&host, 71, wait.download, 15_000, true, 0);
        // 결정 전에 받아 둔 것은 프로필 안에 있어야 한다(사용자의 ~/Downloads 가 아니라 — `preferences.zig`).
        report(finished.last == .complete and finished.received == http.huge_bytes and staged >= 1 and sameContentPrefix(path, 's'), "dl-ask-wait", std.fmt.bufPrint(&detail_buf, "결정 전 10 초 받은 양 {d}/{d}(갱신 {d}) · 프로필 download-staging 항목 {d} · host 가 연 다운로드 임시 파일 {d}({s}) · 결정 뒤 {s} {d}", .{
            held.received,     http.huge_bytes, held.updates, staged, temp_files, temp_name,
            if (finished.last) |st| @tagName(st) else "없음",
            finished.received,
        }) catch "");
    }
}
