//! W2 판정 — 판정자가 **maru 역할**로 픽셀 링을 받아 docs/plans/web-osr-backend.md 「W2」 완료 판정을 잰다.
//!
//!   ring-announced     링 알림(IOSurface 세 장 + 제어 블록)을 pid·토큰 검증을 거쳐 받고, 고정한 pid 버전이 0 이 아니다
//!   no-tearing         매 프레임 화면 전체를 프레임 번호 색으로 칠하는 페이지에서 한 장의 위·가운데·아래 줄 색이 같다
//!   front-held         maru 가 쥔 장(front)을 한 프레임 넘게 쥐고 있어도 생산자가 덮어쓰지 않는다(실제 maru 는 한 프레임 내내
//!                      그 장을 그린다 — 받자마자 몇 µs 만 읽는 것으로는 덮어쓰기를 못 잡았다, 변이 실측)
//!   frame-rate         초당 새 프레임 수(CEF 약 60 에 가깝다)
//!   hidden-no-frames   숨기면 새 프레임이 멈추고, 다시 보이면 돈다
//!   resize-generation  크기 변경 뒤 새 세대 링(새 크기)으로 넘어가고, 넘어가는 동안 빈 장을 읽지 않는다
//!   rogue-rejected     이름을 아는 제3자 프로세스의 링 알림은 첫 관문(pid)에서 거절된다 — 거절 이유까지 본다(pid 검사를
//!                      빼도 pid 버전 고정이 막아 통과하던 것을 가른다, 변이 실측)
//!   malformed-refused  OOL 메모리 폭탄(32MB × 30)·너무 큰 메시지를 거절로 세고, 가상 메모리가 불지 않는다
//!   flood-survives     maru 가 비우지 못하는 동안 대기열을 가득 채운 상태에서(한 통이라도 막혀야 포화로 친다) 크기를
//!                      바꿔도, 비우기 시작하면 진짜 sidecar 의 새 링이 결국 온다 — host 가 알림 실패를 한 번 이상 겪었어야 한다
//!   flood-static       같은 공격을 **그리기가 멈춘 정적 페이지**에서 — 다음 그리기가 없어도 sidecar 가 쥔 링을 다시 알린다
//!   channel-replaced   받는 port 를 새로 알려 주면(두 번째 `frame_channel`) 정적 페이지의 링이 새 받는 쪽에 다시 온다
//!   channel-closed     받는 권리를 닫으면 bootstrap 이름이 사라진다

const std = @import("std");
const protocol = @import("web_sidecar_protocol");
const ring = @import("web_sidecar_ring");
const os = @import("os.zig");
const Host = @import("host.zig").Host;
const attacks = @import("attacks.zig");

const mach = ring.mach;
const iosurface = ring.iosurface;
const Receiver = ring.ring_receiver.Receiver;
const Ring = ring.ring_receiver.Ring;
const mailbox = protocol.mailbox;

pub const Report = *const fn (ok: bool, name: []const u8, detail: []const u8) void;

const browser_id: u64 = 11;
const black: u32 = 0xFF000000;
const wait_ms = 15_000;

/// maru 가 보이는 장. 새 링이 와도 그 링의 첫 프레임을 받기 전까지는 옛 링의 front 를 계속 보인다(C3).
const View = struct {
    shown: ?Ring = null,
    front: mailbox.Slot = mailbox.initial_front,
    pending: ?Ring = null,
    pending_front: mailbox.Slot = mailbox.initial_front,

    frames: u64 = 0,
    torn: u64 = 0,
    blank: u64 = 0,
    /// 크기 변경 중 CEF 가 옛 크기 surface 에 새 레이아웃을 검은 여백과 함께 그린 전환 프레임(실측 — 매번 정확히 한 장,
    /// 위·아래 검정·가운데 파랑). 한 장으로서 일관돼 찢어짐이 아니다 — 따로 세어 드러낸다.
    transition: u64 = 0,
    switched: u32 = 0,
    /// `take` 가 워드를 망가진 것으로 본 수(진짜 sidecar 에서는 0 이어야 한다).
    corrupt: u32 = 0,
    rejected_pid: u32 = 0,
    rejected_other: u32 = 0,

    fn adopt(self: *View, fresh: Ring) void {
        if (self.shown == null) {
            self.shown = fresh;
            self.front = mailbox.initial_front;
            return;
        }
        if (self.pending) |old| old.release();
        self.pending = fresh;
        self.pending_front = mailbox.initial_front;
    }

    /// 새 프레임이 있으면 front 로 삼고 읽어 본다.
    fn poll(self: *View) void {
        if (self.pending) |*pending| {
            switch (mailbox.take(pending.control, pending.generation, self.pending_front)) {
                .frame => |slot| {
                    // 새 링의 첫 프레임 — 이제 넘어간다.
                    self.shown.?.release();
                    self.shown = pending.*;
                    self.front = slot;
                    self.pending = null;
                    self.switched += 1;
                    self.inspect();
                    return;
                },
                .corrupt => self.corrupt += 1,
                else => {},
            }
        }
        const shown = if (self.shown) |*shown| shown else return;
        switch (mailbox.take(shown.control, shown.generation, self.front)) {
            .frame => |slot| {
                self.front = slot;
                self.inspect();
            },
            .corrupt => self.corrupt += 1,
            .none, .stale => {},
        }
    }

    fn inspect(self: *View) void {
        const surface = self.shown.?.surfaces[self.front];
        iosurface.lockRead(surface);
        defer iosurface.unlockRead(surface);
        const w = iosurface.width(surface);
        const h = iosurface.height(surface);
        const x = w / 2;
        const top = iosurface.pixel(surface, x, 2);
        const middle = iosurface.pixel(surface, x, h / 2);
        const bottom = iosurface.pixel(surface, x, h - 3);
        self.frames += 1;
        if (top == 0 or middle == 0 or bottom == 0) self.blank += 1;
        // 크기 변경 전환 프레임은 위·아래가 검정이다(C3) — 따로 센다. 그 밖에는 한 장이 한 색이어야 한다: 페이지가 매
        // 프레임 다른 색으로 칠하므로, 줄마다 색이 다르면 생산자가 쓰는 장을 소비자가 읽은 것이다.
        if (top == black or bottom == black) {
            self.transition += 1;
        } else if (top != middle or middle != bottom) {
            self.torn += 1;
        }
    }

    /// 지금 쥔 front 의 가운데 픽셀.
    fn centerPixel(self: *View) u32 {
        const surface = self.shown.?.surfaces[self.front];
        iosurface.lockRead(surface);
        defer iosurface.unlockRead(surface);
        return iosurface.pixel(surface, iosurface.width(surface) / 2, iosurface.height(surface) / 2);
    }

    fn release(self: *View) void {
        if (self.shown) |shown| shown.release();
        if (self.pending) |pending| pending.release();
    }
};

/// `ms` 동안 링 알림을 받으며 새 프레임을 읽는다.
fn pump(view: *View, receiver: *Receiver, ms: i64, rejected: *u32) void {
    const deadline = os.nowMs() + ms;
    while (os.nowMs() < deadline) {
        while (receiver.receive(0) catch null) |received| switch (received) {
            .ring => |fresh| view.adopt(fresh),
            .rejected => |reason| {
                rejected.* += 1;
                if (reason == .wrong_pid) view.rejected_pid += 1 else view.rejected_other += 1;
            },
        };
        view.poll();
        os.sleepMs(1);
    }
}

fn url(buf: []u8, port: u16, path: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, "http://127.0.0.1:{d}{s}", .{ port, path }) catch unreachable;
}

/// 이름을 아는 제3자 역할 — `maru-web-judge --rogue <이름> <토큰 hex 32 자>`. fork 만 한 자식에서는 CoreFoundation·IOSurface 를
/// 못 쓰므로(macOS 가 막는다 — 첫 실행에서 제3자가 아무것도 못 보냈다) 판정자 자신을 exec 해 띄운다. pid 가 다르니
/// 토큰을 알아도 거절돼야 한다. 토큰을 모르는 경우와 아는 경우를 차례로 보낸다.
pub fn rogueMain(service: []const u8, real_token_hex: []const u8) u8 {
    var real_token: [16]u8 = undefined;
    _ = std.fmt.hexToBytes(&real_token, real_token_hex) catch return 2;
    var wrong_token: [16]u8 = undefined;
    mach.randomBytes(&wrong_token);
    for ([_][16]u8{ wrong_token, real_token }) |token| {
        const channel = ring.ring_producer.Channel.connect(service, token) catch return 3;
        var producer: ring.ring_producer.Producer = .{ .browser = browser_id, .scale = 2 };
        const fake = iosurface.create(64, 64) catch return 4;
        const painted = producer.paint(&channel, fake, 0) catch return 5;
        if (painted != .delivered) return 5;
    }
    return 0;
}

/// `maru-web-judge --attack <종류> <이름>` 을 띄우고 끝날 때까지 받는 쪽을 계속 비운다(maru 처럼).
fn runAttack(self_path: [*:0]const u8, kind: [*:0]const u8, service: []const u8, view: *View, receiver: *Receiver, rejected: *u32, drain: bool) bool {
    var service_z: [128:0]u8 = undefined;
    const s = std.fmt.bufPrintZ(&service_z, "{s}", .{service}) catch return false;
    const pid = os.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ self_path, "--attack", kind, s };
        const envp = [_:null]?[*:0]const u8{};
        _ = std.c.execve(self_path, &argv, &envp);
        std.c._exit(127);
    }
    var status: c_int = 0;
    while (std.c.waitpid(pid, &status, 1) == 0) {
        if (drain) pump(view, receiver, 20, rejected) else os.sleepMs(20);
    }
    if (drain) pump(view, receiver, 500, rejected);
    return (@as(u32, @bitCast(status)) >> 8) & 0xff == 0;
}

fn spawnRogue(self_path: [*:0]const u8, service: []const u8, token: [16]u8) c_int {
    var service_z: [128:0]u8 = undefined;
    const s = std.fmt.bufPrintZ(&service_z, "{s}", .{service}) catch return -1;
    var hex_z: [33:0]u8 = undefined;
    const h = std.fmt.bufPrintZ(&hex_z, "{x}", .{&token}) catch return -1;
    const pid = os.fork();
    if (pid == 0) {
        const argv = [_:null]?[*:0]const u8{ self_path, "--rogue", s, h };
        const envp = [_:null]?[*:0]const u8{};
        _ = std.c.execve(self_path, &argv, &envp);
        std.c._exit(127);
    }
    return pid;
}

/// host 로그에서 `needle` 이 나온 줄 수.
fn countLines(path: [:0]const u8, needle: []const u8) usize {
    const fd = std.c.open(path, .{ .ACCMODE = .RDONLY });
    if (fd < 0) return 0;
    defer _ = std.c.close(fd);
    var buf: [256 * 1024]u8 = undefined;
    var len: usize = 0;
    while (len < buf.len) {
        const n = std.c.read(fd, buf[len..].ptr, buf.len - len);
        if (n <= 0) break;
        len += @intCast(n);
    }
    return std.mem.count(u8, buf[0..len], needle);
}

const waiting_line = "is waiting — the frame channel did not take it";

pub fn run(report: Report, self_path: [*:0]const u8, host_path: [:0]const u8, profile_arg: [:0]const u8, log_path: [:0]const u8, port: u16) !void {
    var detail: [256]u8 = undefined;
    var u: [256]u8 = undefined;

    var receiver = try Receiver.open();
    var host = try Host.spawnLogged(host_path, profile_arg, log_path);
    receiver.expected_pid = host.pid;
    try host.send(.{ .hello = .{ .instance = 3, .nonce = os.random64() } });
    _ = (try host.next(wait_ms)) orelse return error.NoAck;
    try host.send(.{ .frame_channel = .{ .service = receiver.serviceName(), .token = receiver.token } });
    try host.send(.{ .create_browser = .{ .browser = browser_id, .size = .{ .width = 760, .height = 486, .scale = 2 }, .hidden = false, .url = url(&u, port, "/tear") } });

    var view: View = .{};
    defer view.release();
    var rejected: u32 = 0;
    const announced_deadline = os.nowMs() + wait_ms;
    while (view.shown == null and os.nowMs() < announced_deadline) pump(&view, &receiver, 100, &rejected);
    const first = view.shown;
    const pinned = receiver.pinned_pid_version orelse 0;
    report(first != null and first.?.width == 1520 and first.?.height == 972 and rejected == 0 and pinned != 0, "ring-announced", std.fmt.bufPrint(&detail, "세대 {d} · {d}x{d} · 거절 {d} · 고정한 pid 버전 {d}", .{ if (first) |r| r.generation else 0, if (first) |r| r.width else 0, if (first) |r| r.height else 0, rejected, pinned }) catch "");
    if (first == null) return error.NoRing;

    // 첫 로드가 끝나 페이지가 돌 때까지 조금 기다린 뒤 5 초를 잰다.
    pump(&view, &receiver, 1500, &rejected);
    view.frames = 0;
    view.torn = 0;
    view.blank = 0;
    view.transition = 0;
    pump(&view, &receiver, 5000, &rejected);
    const measured = view.frames;
    report(view.torn == 0 and view.blank == 0 and view.transition == 0 and view.corrupt == 0 and measured > 0, "no-tearing", std.fmt.bufPrint(&detail, "읽은 장 {d} · 찢어진 장 {d} · 빈 장 {d} · 전환 프레임 {d} · 망가진 워드 {d}", .{ measured, view.torn, view.blank, view.transition, view.corrupt }) catch "");
    // 쥔 장이 그대로인가 — 새 프레임을 받은 직후 25ms(한 프레임 넘게) 새로 받지 않고 쥔 채 앞뒤로 읽는다.
    var held: u32 = 0;
    var overwritten: u32 = 0;
    while (held < 40) : (held += 1) {
        const before_frames = view.frames;
        const frame_deadline = os.nowMs() + 2000;
        while (view.frames == before_frames and os.nowMs() < frame_deadline) pump(&view, &receiver, 1, &rejected);
        const first_look = view.centerPixel();
        os.sleepMs(25);
        if (view.centerPixel() != first_look) overwritten += 1;
    }
    report(overwritten == 0, "front-held", std.fmt.bufPrint(&detail, "25ms 씩 {d} 번 쥐었다 · 그사이 바뀐 장 {d}", .{ held, overwritten }) catch "");
    report(measured >= 5 * 45, "frame-rate", std.fmt.bufPrint(&detail, "초당 새 프레임 {d}", .{measured / 5}) catch "");

    // 숨기면 멈추고 다시 보이면 돈다.
    try host.send(.{ .set_hidden = .{ .browser = browser_id, .value = true } });
    pump(&view, &receiver, 500, &rejected);
    view.frames = 0;
    pump(&view, &receiver, 2000, &rejected);
    const hidden_frames = view.frames;
    try host.send(.{ .set_hidden = .{ .browser = browser_id, .value = false } });
    pump(&view, &receiver, 500, &rejected);
    view.frames = 0;
    pump(&view, &receiver, 2000, &rejected);
    const shown_frames = view.frames;
    report(hidden_frames <= 2 and shown_frames >= 2 * 45, "hidden-no-frames", std.fmt.bufPrint(&detail, "숨김 2 초 {d} 장 · 다시 보임 2 초 {d} 장", .{ hidden_frames, shown_frames }) catch "");

    // 크기 변경 → 새 세대.
    const before = view.switched;
    view.blank = 0;
    view.torn = 0;
    view.transition = 0;
    try host.send(.{ .resize = .{ .browser = browser_id, .size = .{ .width = 500, .height = 300, .scale = 2 } } });
    const switch_deadline = os.nowMs() + wait_ms;
    while (view.switched == before and os.nowMs() < switch_deadline) pump(&view, &receiver, 50, &rejected);
    pump(&view, &receiver, 1000, &rejected);
    const now_shown = view.shown.?;
    report(view.switched == before + 1 and now_shown.width == 1000 and now_shown.height == 600 and now_shown.generation == first.?.generation + 1 and view.blank == 0 and view.torn == 0, "resize-generation", std.fmt.bufPrint(&detail, "세대 {d} → {d} · {d}x{d} · 넘어가는 동안 빈 장 {d} · 찢어진 장 {d} · 전환 프레임 {d}", .{ first.?.generation, now_shown.generation, now_shown.width, now_shown.height, view.blank, view.torn, view.transition }) catch "");

    // 제3자.
    const rejected_before = rejected;
    const pid_rejections_before = view.rejected_pid;
    const rogue_pid = spawnRogue(self_path, receiver.serviceName(), receiver.token);
    var status: c_int = 0;
    _ = std.c.waitpid(rogue_pid, &status, 0);
    const rogue_sent = (@as(u32, @bitCast(status)) >> 8) & 0xff == 0;
    const generation_before = view.shown.?.generation;
    pump(&view, &receiver, 1000, &rejected);
    const rogue_rejected = rejected - rejected_before;
    const rogue_pid_rejections = view.rejected_pid - pid_rejections_before;
    const adopted_rogue = view.shown.?.generation != generation_before or view.pending != null;
    report(rogue_sent and rogue_rejected == 2 and rogue_pid_rejections == 2 and !adopted_rogue, "rogue-rejected", std.fmt.bufPrint(&detail, "제3자가 보냄 {} · 거절 {d}(그중 pid 로 {d} — 토큰 모름·토큰 앎 둘 다) · 받아들임 {}", .{ rogue_sent, rogue_rejected, rogue_pid_rejections, adopted_rogue }) catch "");

    // 모양을 비튼 메시지.
    const vsize_before = attacks.virtualSize();
    var attack_mark = rejected;
    const ool_sent = runAttack(self_path, "ool", receiver.serviceName(), &view, &receiver, &rejected, true);
    const ool_rejected = rejected - attack_mark;
    const vsize_growth = attacks.virtualSize() -| vsize_before;
    attack_mark = rejected;
    const big_sent = runAttack(self_path, "big", receiver.serviceName(), &view, &receiver, &rejected, true);
    const big_rejected = rejected - attack_mark;
    report(ool_sent and ool_rejected == attacks.ool_messages and big_sent and big_rejected == 1 and vsize_growth < 256 * 1024 * 1024, "malformed-refused", std.fmt.bufPrint(&detail, "OOL 32MB × {d} 거절 {d} · 가상 메모리 증가 {d}MB · 큰 메시지 거절 {d}", .{ attacks.ool_messages, ool_rejected, vsize_growth / (1024 * 1024), big_rejected }) catch "");

    // 넘치게 넣은 뒤에도 진짜 알림을 받는다.
    attack_mark = rejected;
    // maru 가 바쁜 동안(비우지 않는다) 대기열을 채우고, 찬 채로 크기를 바꾼 뒤 잠시 두었다가 비우기 시작한다.
    const flooded = runAttack(self_path, "flood", receiver.serviceName(), &view, &receiver, &rejected, false);
    const switched_before = view.switched;
    try host.send(.{ .resize = .{ .browser = browser_id, .size = .{ .width = 800, .height = 500, .scale = 2 } } });
    os.sleepMs(500);
    const flood_deadline = os.nowMs() + wait_ms;
    while (view.switched == switched_before and os.nowMs() < flood_deadline) pump(&view, &receiver, 50, &rejected);
    const flood_rejected = rejected - attack_mark;
    const waited = countLines(log_path, waiting_line);
    report(flooded and flood_rejected > 0 and waited >= 1 and view.switched == switched_before + 1 and view.shown.?.width == 1600, "flood-survives", std.fmt.bufPrint(&detail, "포화 {} · 넘친 메시지 거절 {d} · host 알림 대기 {d} 번 · 그 뒤 새 링 {d}x{d}", .{ flooded, flood_rejected, waited, view.shown.?.width, view.shown.?.height }) catch "");

    // 정적 페이지 — 크기를 바꾼 뒤 CEF 가 한두 번 그리고 멈춘다. 그 그리기가 모두 막혀도 링이 와야 한다.
    try host.send(.{ .navigate = .{ .browser = browser_id, .url = url(&u, port, "/static") } });
    pump(&view, &receiver, 1500, &rejected);
    const static_frames_before = view.frames;
    pump(&view, &receiver, 1000, &rejected);
    const static_idle = view.frames - static_frames_before;
    const waited_before = countLines(log_path, waiting_line);
    const static_flooded = runAttack(self_path, "flood", receiver.serviceName(), &view, &receiver, &rejected, false);
    const static_switched_before = view.switched;
    try host.send(.{ .resize = .{ .browser = browser_id, .size = .{ .width = 640, .height = 400, .scale = 2 } } });
    os.sleepMs(1000);
    const static_deadline = os.nowMs() + wait_ms;
    while (view.switched == static_switched_before and os.nowMs() < static_deadline) pump(&view, &receiver, 50, &rejected);
    const static_waited = countLines(log_path, waiting_line) - waited_before;
    report(static_idle <= 2 and static_flooded and static_waited >= 1 and view.switched == static_switched_before + 1 and view.shown.?.width == 1280, "flood-static", std.fmt.bufPrint(&detail, "멈춘 페이지(1 초 {d} 장) · 포화 {} · host 알림 대기 {d} 번 · 그 뒤 새 링 {d}x{d}", .{ static_idle, static_flooded, static_waited, view.shown.?.width, view.shown.?.height }) catch "");

    // 받는 쪽을 바꾼다 — 정적 페이지라 그리기 없이 지금 링이 새 받는 쪽으로 와야 한다.
    var second = try Receiver.open();
    defer second.close();
    second.expected_pid = host.pid;
    try host.send(.{ .frame_channel = .{ .service = second.serviceName(), .token = second.token } });
    var second_ring: ?Ring = null;
    var second_rejected: u32 = 0;
    const second_deadline = os.nowMs() + wait_ms;
    while (second_ring == null and os.nowMs() < second_deadline) {
        if (second.receive(100) catch null) |received| switch (received) {
            .ring => |fresh| second_ring = fresh,
            .rejected => second_rejected += 1,
        };
    }
    const shown_generation = view.shown.?.generation;
    report(second_ring != null and second_ring.?.generation == shown_generation and second_ring.?.width == 1280 and second_rejected == 0, "channel-replaced", std.fmt.bufPrint(&detail, "새 받는 쪽이 받은 링: 세대 {d}(보이던 세대 {d}) · {d}x{d} · 거절 {d}", .{ if (second_ring) |r| r.generation else 0, shown_generation, if (second_ring) |r| r.width else 0, if (second_ring) |r| r.height else 0, second_rejected }) catch "");
    if (second_ring) |r| r.release();

    try host.send(.shutdown);
    while (host.next(wait_ms) catch null) |_| {}
    _ = host.wait(wait_ms);

    var name_buf: [128:0]u8 = undefined;
    const name = std.fmt.bufPrintZ(&name_buf, "{s}", .{receiver.serviceName()}) catch unreachable;
    receiver.close();
    var probe: mach.Port = mach.null_port;
    const lookup = mach.bootstrap_look_up(mach.bootstrap_port, name, &probe);
    report(lookup != 0, "channel-closed", std.fmt.bufPrint(&detail, "받는 권리를 닫은 뒤 look_up → {d}", .{lookup}) catch "");
}
