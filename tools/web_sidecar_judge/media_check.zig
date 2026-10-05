//! W6h② 판정 — 동영상·오디오 우클릭 메뉴(docs/plans/web-osr-backend.md W6). 판정자가 **maru 역할**로 `context_menu` 를 받고
//! 고른 것을 `context_menu_command` 로 답한다. 페이지 `/media` 는 0.1 초마다 미디어 상태를 제목으로 알린다(`m a<연속 재생> b<…>
//! f<같은 출처 iframe> x<다른 사이트 iframe> vl<동영상 연속 재생> vc<동영상 제어 기능> d<같은 주소 둘> g<같은 출처 iframe 의 같은 주소 둘>
//! y<다른 사이트 iframe 의 같은 주소 둘>` — iframe 은 `postMessage` 로, 준비 전이면 ` wait`, `?s=1` 에서 자리를 바꾼 뒤면 ` swapped`).
//!
//!   media-audio        오디오 — 미디어·오디오·연속 재생 가능·제어 기능 켜짐·제어 기능 끄기 불가·새 탭·주소 복사 가능. 「연속 재생」을
//!                      고르면 그 오디오가 켜지고, 다음 메뉴는 연속 재생 켜짐으로 오고 다시 고르면 꺼진다
//!   media-iframe       같은 출처 iframe 안 오디오의 「연속 재생」이 그 오디오를 켠다(DevTools 가 같은 프로세스 iframe 을 지난다)
//!   media-cross-site   다른 사이트(`localhost`) iframe 안 오디오의 「연속 재생」이 그 오디오를 켠다(그 frame 의 같은 주소 미디어 —
//!                      사용자 결정 2026-10-05)
//!   media-video        `blob:` 동영상 — 미디어·동영상·제어 기능 끄기 가능, 새 탭·주소 복사는 불가. 「모든 제어 기능 표시」가 제어 기능을 켠다
//!   media-open-copy    오디오의 「새 탭에서 오디오 열기」는 뒤 탭으로 그 주소, 「오디오 주소 복사」는 판정자 전용 클립보드에 그 주소
//!   media-not-allowed  `blob:` 동영상의 「주소 복사」·「새 탭」은 실행하지 않는다(클립보드 그대로·새 탭 없음)
//!   media-long-src     1.5 KB 주소의 같은 주소 오디오 둘 중 우클릭한 것만 켠다(긴 주소도 DevTools 경로로 — W6h② 적대 검증 1 회차)
//!   media-want         메뉴가 떠 있는 동안 페이지가 연속 재생을 켜도 「연속 재생」은 메뉴에 보인 체크(꺼짐)의 반대 — 켜짐으로 둔다(Chrome 과
//!                      같다 — 뒤집으면 꺼졌다, W6h② 적대 검증 2 회차)
//!   media-hash         메뉴가 떠 있는 동안 페이지가 해시를 바꿔도(같은 출처) 「연속 재생」이 그 오디오를 켠다(W6h② 적대 검증 4 회차 — 주소
//!                      전체로 비교하면 아무 일도 없었다)
//!   media-shifted      우클릭 뒤 메뉴가 떠 있는 동안 페이지가 **같은 주소** 두 오디오의 자리를 바꿔도 「연속 재생」은 우클릭한 그 오디오를
//!                      켠다(우클릭 때 찾아 둔다 — 고를 때 찾으면 다른 것을 켠다)
//!   media-error        불러오지 못한 오디오(404)는 연속 재생·새 탭이 꺼진다(Chrome — 오류 상태·저장할 수 없음, W6h② 적대 검증 5 회차)
//!   media-same-src     같은 주소 오디오 둘 중 우클릭한 것만 켠다 — 맨 위 문서와 같은 출처 iframe(DevTools 경로 — 주소로 찾는 보조 경로는 모른다)
//!   media-cross-dup    다른 사이트 iframe 의 같은 주소 둘은 아무것도 켜지 않는다(사용자 결정 — 둘 이상이면 하지 않는다)
//!   media-scrolled     500 px 스크롤한 페이지에서 화면에 보이는 오디오를 우클릭하면 그 오디오를 켠다(같은 주소의 위쪽 오디오가 아니다 —
//!                      CEF 의 view 좌표를 문서 좌표로 바꾼다, W6h② 적대 검증)

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const browsers_check = @import("browsers_check.zig");
const pasteboard = @import("web_sidecar_pasteboard");

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 33;
const wait_ms = 15_000;
const Point = protocol.message.Point;
const Command = protocol.message.ContextMenuCommandKind;
const Flags = protocol.message.ContextMenuFlags;

const a_point: Point = .{ .x = 100, .y = 30 };
const f_point: Point = .{ .x = 100, .y = 100 };
const x_point: Point = .{ .x = 100, .y = 180 };
const v_point: Point = .{ .x = 150, .y = 300 };
const d2_point: Point = .{ .x = 480, .y = 310 };
const g2_point: Point = .{ .x = 480, .y = 70 + 60 + 20 };
const y2_point: Point = .{ .x = 150, .y = 420 + 20 };

const Watch = struct {
    host: *Host,
    title_buf: [128]u8 = undefined,
    title_len: usize = 0,
    menu: u32 = 0,
    flags: Flags = .{},
    opened: u32 = 0,
    opened_bg: bool = false,
    opened_url: [256]u8 = undefined,
    opened_len: usize = 0,

    fn title(self: *const Watch) []const u8 {
        return self.title_buf[0..self.title_len];
    }

    fn step(self: *Watch) void {
        const message = (self.host.next(20) catch null) orelse return;
        switch (message) {
            .title_changed => |v| if (v.browser == browser_id) {
                self.title_len = @min(v.text.len, self.title_buf.len);
                @memcpy(self.title_buf[0..self.title_len], v.text[0..self.title_len]);
            },
            .context_menu => |v| if (v.browser == browser_id) {
                self.menu = v.menu;
                self.flags = v.flags;
            },
            .open_tab => |v| if (v.browser == browser_id) {
                self.opened += 1;
                self.opened_bg = v.placement == .background;
                self.opened_len = @min(v.url.len, self.opened_url.len);
                @memcpy(self.opened_url[0..self.opened_len], v.url[0..self.opened_len]);
            },
            else => {},
        }
    }

    fn pump(self: *Watch, ms: u32) void {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) self.step();
    }

    /// 제목에 `part` 가 있고 ` wait` 가 없을 때까지(준비된 페이지).
    fn untilReady(self: *Watch, part: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (std.mem.indexOf(u8, self.title(), part) != null and std.mem.indexOf(u8, self.title(), "wait") == null) return true;
            self.step();
        }
        return false;
    }

    /// 제목에 `part`(예: ` a1`)가 들어올 때까지.
    fn untilPart(self: *Watch, part: []const u8, ms: u32) bool {
        const deadline = os.nowMs() + ms;
        while (os.nowMs() < deadline) {
            if (std.mem.indexOf(u8, self.title(), part) != null) return true;
            self.step();
        }
        return std.mem.indexOf(u8, self.title(), part) != null;
    }

    fn rightClick(self: *Watch, point: Point) !?u32 {
        const before = self.menu;
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .move, .point = point } });
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .down, .button = .right, .point = point, .modifiers = .{ .right_button = true }, .click_count = 1 } });
        try self.host.send(.{ .mouse = .{ .browser = browser_id, .kind = .up, .button = .right, .point = point, .click_count = 1 } });
        const deadline = os.nowMs() + 3_000;
        while (os.nowMs() < deadline and self.menu == before) self.step();
        return if (self.menu != before) self.menu else null;
    }

    fn pick(self: *Watch, menu: ?u32, command: Command) !void {
        const m = menu orelse return;
        try self.host.send(.{ .context_menu_command = .{ .browser = browser_id, .menu = m, .command = command } });
        self.pump(200);
    }

    fn load(self: *Watch, port: u16, shift: bool) !bool {
        var u: [256]u8 = undefined;
        self.title_len = 0;
        try self.host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, if (shift) "/media?s=1" else "/media") } });
        // 동영상 녹화(1.5 초)와 iframe 들이 준비되면 제목에서 `wait` 가 빠진다.
        const deadline = os.nowMs() + wait_ms;
        while (os.nowMs() < deadline) {
            if (std.mem.startsWith(u8, self.title(), "m ") and std.mem.indexOf(u8, self.title(), "wait") == null) return true;
            self.step();
        }
        return false;
    }
};

pub fn run(report: Report, host_path: [:0]const u8, profile_arg: [:0]const u8, port: u16) !void {
    var detail: [400]u8 = undefined;
    var u: [256]u8 = undefined;
    var name_buf: [64]u8 = undefined;
    const board = std.fmt.bufPrint(&name_buf, "maru-web-judge-media-{d}", .{std.c.getpid()}) catch unreachable;
    var env_buf: [128]u8 = undefined;
    const env = std.fmt.bufPrintZ(&env_buf, "MARU_WEB_TEST_PASTEBOARD={s}", .{board}) catch unreachable;
    defer pasteboard.dispose(board);

    var host = try Host.spawnWith(host_path, profile_arg, null, &.{env.ptr});
    defer {
        host.send(.shutdown) catch {};
        _ = host.wait(wait_ms);
    }
    try browsers_check.handshake(&host);
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 640, .height = 480, .scale = 1 }, .hidden = false, .url = browsers_check.url(&u, port, "/title?t=media-start") } });
    var w: Watch = .{ .host = &host };
    w.pump(1_500);
    if (!try w.load(port, false)) return error.MediaPageNotReady;
    try host.send(.{ .set_focus = .{ .browser = browser_id, .value = true } });
    w.pump(300);

    // 오디오 — 표지, 켬, 다시 켜진 상태로 와 끔.
    const a1 = try w.rightClick(a_point);
    const af = w.flags;
    const audio_flags = af.media and af.media_audio and !af.media_video and af.media_can_loop and !af.media_loop and af.media_controls and
        !af.media_can_toggle_controls and af.media_openable and af.media_copyable;
    try w.pick(a1, .media_loop);
    const on = w.untilPart(" a1 ", 3_000);
    const a2 = try w.rightClick(a_point);
    const second_flags_loop = w.flags.media_loop;
    try w.pick(a2, .media_loop);
    const off = w.untilPart(" a0 ", 3_000);
    report(a1 != null and audio_flags and on and second_flags_loop and off, "media-audio", std.fmt.bufPrint(&detail, "메뉴 {any} · 표지 {} · 켬 {} · 다음 메뉴가 켜짐으로 {} · 끔 {} · 제목 「{s}」", .{ a1, audio_flags, on, second_flags_loop, off, w.title() }) catch "");

    // 같은 출처 iframe, 다른 사이트 iframe.
    const f1 = try w.rightClick(f_point);
    const f_media = w.flags.media_audio and w.flags.media_can_loop;
    try w.pick(f1, .media_loop);
    const f_on = w.untilPart(" f1 ", 3_000);
    report(f1 != null and f_media and f_on, "media-iframe", std.fmt.bufPrint(&detail, "메뉴 {any} · 오디오 {} · 켬 {} · 제목 「{s}」", .{ f1, f_media, f_on, w.title() }) catch "");
    const x1 = try w.rightClick(x_point);
    const x_media = w.flags.media_audio and w.flags.media_can_loop;
    try w.pick(x1, .media_loop);
    const x_on = w.untilPart(" x1 ", 3_000);
    report(x1 != null and x_media and x_on, "media-cross-site", std.fmt.bufPrint(&detail, "메뉴 {any} · 오디오 {} · 켬 {} · 제목 「{s}」", .{ x1, x_media, x_on, w.title() }) catch "");

    // `blob:` 동영상 — 제어 기능, 그리고 할 수 없는 명령.
    const v1 = try w.rightClick(v_point);
    const vf = w.flags;
    const video_flags = vf.media and vf.media_video and !vf.media_audio and vf.media_can_toggle_controls and !vf.media_controls and
        !vf.media_openable and !vf.media_copyable;
    try w.pick(v1, .media_controls);
    const vc_on = w.untilPart(" vc1", 3_000);
    report(v1 != null and video_flags and vc_on, "media-video", std.fmt.bufPrint(&detail, "메뉴 {any} · 표지 {} · 제어 기능 켬 {} · 제목 「{s}」", .{ v1, video_flags, vc_on, w.title() }) catch "");
    _ = pasteboard.writeText(board, "untouched", false);
    const opened_before = w.opened;
    const v2 = try w.rightClick(v_point);
    try w.pick(v2, .copy_media_address);
    const v3 = try w.rightClick(v_point);
    try w.pick(v3, .open_media_new_tab);
    w.pump(500);
    var read_buf: [512]u8 = undefined;
    const untouched = std.mem.eql(u8, pasteboard.readText(board, pasteboard.string_type, &read_buf) orelse "", "untouched");
    report(v2 != null and v3 != null and untouched and w.opened == opened_before, "media-not-allowed", std.fmt.bufPrint(&detail, "클립보드 그대로 {} · 새 탭 {d}", .{ untouched, w.opened - opened_before }) catch "");

    // 오디오 — 새 탭(뒤)·주소 복사.
    var want_buf: [128]u8 = undefined;
    const want = browsers_check.url(&want_buf, port, "/dl/tone.wav?a");
    const o1 = try w.rightClick(a_point);
    try w.pick(o1, .open_media_new_tab);
    w.pump(500);
    const opened_ok = w.opened == opened_before + 1 and w.opened_bg and std.mem.eql(u8, w.opened_url[0..w.opened_len], want);
    const o2 = try w.rightClick(a_point);
    try w.pick(o2, .copy_media_address);
    w.pump(500);
    const copied = pasteboard.readText(board, pasteboard.string_type, &read_buf) orelse "";
    const copied_ok = std.mem.eql(u8, copied, want);
    report(opened_ok and copied_ok, "media-open-copy", std.fmt.bufPrint(&detail, "새 탭 뒤 {} 「{s}」 · 복사 「{s}」", .{ opened_ok, w.opened_url[0..w.opened_len], copied }) catch "");

    // 같은 주소 둘 — 아래 것(d2)과 같은 출처 iframe 의 아래 것(g 의 둘째)만.
    const dd = try w.rightClick(d2_point);
    try w.pick(dd, .media_loop);
    const d_ok = w.untilPart(" d01 ", 3_000);
    const gg = try w.rightClick(g2_point);
    try w.pick(gg, .media_loop);
    const g_ok = w.untilPart(" g01 ", 3_000);
    report(dd != null and gg != null and d_ok and g_ok, "media-same-src", std.fmt.bufPrint(&detail, "맨 위 아래 것만 {} · iframe 아래 것만 {} · 제목 「{s}」", .{ d_ok, g_ok, w.title() }) catch "");
    // 다른 사이트 iframe 의 같은 주소 둘 — 보조 경로는 아무것도 하지 않는다.
    const yy = try w.rightClick(y2_point);
    const y_media = w.flags.media_audio and w.flags.media_can_loop; // 고를 수 있어야 「그대로」가 뜻이 있다
    try w.pick(yy, .media_loop);
    w.pump(1_500);
    const y_none = std.mem.indexOf(u8, w.title(), " y00") != null;
    report(yy != null and y_media and y_none, "media-cross-dup", std.fmt.bufPrint(&detail, "메뉴 {any} · 오디오 {} · 둘 다 그대로 {} · 제목 「{s}」", .{ yy, y_media, y_none, w.title() }) catch "");

    // 스크롤한 페이지 — 화면 (100,45) 에 보이는 것은 문서 545 의 아래 오디오다.
    w.title_len = 0;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/media-scroll") } });
    const scrolled = w.untilPart("s y500 s00", wait_ms);
    const sc = try w.rightClick(.{ .x = 100, .y = 45 });
    try w.pick(sc, .media_loop);
    const low_only = w.untilPart(" s01", 3_000);
    report(scrolled and sc != null and low_only, "media-scrolled", std.fmt.bufPrint(&detail, "스크롤 {} · 메뉴 {any} · 보이는 아래 오디오만 {} · 제목 「{s}」", .{ scrolled, sc, low_only, w.title() }) catch "");

    // 긴 주소 — 아래 것만.
    w.title_len = 0;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/media-long") } });
    const long_ready = w.untilReady("l 00", wait_ms);
    const lg = try w.rightClick(.{ .x = 100, .y = 100 });
    try w.pick(lg, .media_loop);
    const long_ok = w.untilPart("l 01", 3_000);
    report(long_ready and lg != null and long_ok, "media-long-src", std.fmt.bufPrint(&detail, "준비 {} · 메뉴 {any} · 아래 것만 {} · 제목 「{s}」", .{ long_ready, lg, long_ok, w.title() }) catch "");

    // 메뉴가 떠 있는 동안 페이지가 스스로 켠다 — 고른 뒤에도 켜짐.
    w.title_len = 0;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/media-want") } });
    const want_ready = w.untilReady("w 0", wait_ms);
    const wm = try w.rightClick(.{ .x = 100, .y = 30 });
    const shown_off = !w.flags.media_loop;
    const page_on = w.untilPart("w 1", 2_000);
    try w.pick(wm, .media_loop);
    w.pump(800);
    const still_on = std.mem.indexOf(u8, w.title(), "w 1") != null;
    report(want_ready and wm != null and shown_off and page_on and still_on, "media-want", std.fmt.bufPrint(&detail, "메뉴는 꺼짐 {} · 페이지가 켬 {} · 고른 뒤 켜짐 그대로 {} · 제목 「{s}」", .{ shown_off, page_on, still_on, w.title() }) catch "");

    // 메뉴가 떠 있는 동안 해시가 바뀐다 — 그래도 켠다.
    w.title_len = 0;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/media-hash") } });
    const hash_ready = w.untilReady("h 0", wait_ms);
    const hm = try w.rightClick(.{ .x = 100, .y = 30 });
    const hashed = w.untilPart(" hashed", 2_000);
    try w.pick(hm, .media_loop);
    const hash_on = w.untilPart("h 1", 3_000);
    report(hash_ready and hm != null and hashed and hash_on, "media-hash", std.fmt.bufPrint(&detail, "해시 바뀜 {} · 켬 {} · 제목 「{s}」", .{ hashed, hash_on, w.title() }) catch "");

    // 우클릭 뒤 자리가 바뀐다 — 다시 불러와 a 를 우클릭하면 페이지가 0.2 초 뒤 a·b 의 자리를 바꾼다. 0.8 초 뒤 고른다.
    if (!try w.load(port, true)) return error.MediaPageNotReady;
    w.pump(300);
    const s1 = try w.rightClick(.{ .x = 480, .y = 250 }); // d1
    w.pump(800);
    const swapped = w.untilPart(" swapped", 2_000);
    try w.pick(s1, .media_loop);
    const right_one = w.untilPart(" d10 ", 3_000);
    report(s1 != null and swapped and right_one, "media-shifted", std.fmt.bufPrint(&detail, "자리 바뀜 {} · 우클릭한 오디오(같은 주소 둘 중)만 켬 {} · 제목 「{s}」", .{ swapped, right_one, w.title() }) catch "");

    // 오류 상태 — 연속 재생·새 탭 꺼짐.
    w.title_len = 0;
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = browsers_check.url(&u, port, "/media-err") } });
    const errored = w.untilPart("e error", wait_ms);
    const em = try w.rightClick(.{ .x = 100, .y = 30 });
    const ef = w.flags;
    const err_off = ef.media_audio and !ef.media_can_loop and !ef.media_openable;
    if (em) |m| try w.pick(m, .cancel);
    report(errored and em != null and err_off, "media-error", std.fmt.bufPrint(&detail, "오류 {} · 메뉴 {any} · 오디오 {} · 연속 재생 가능 {} · 새 탭 가능 {}", .{ errored, em, ef.media_audio, ef.media_can_loop, ef.media_openable }) catch "");
}
