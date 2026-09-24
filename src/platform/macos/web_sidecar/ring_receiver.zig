//! maru 쪽 링 알림 받기(W2, C3). 받는 port 를 무작위 이름으로 열고, 알림마다 **보낸 프로세스를 확인**한다:
//! 커널이 찍은 audit token 의 pid 가 maru 가 띄운 sidecar 이고, 메시지의 토큰이 제어 채널로만 건넨 값과 같아야 한다.
//! 첫 알림의 pid 버전을 기억해 이후는 pid 버전까지 같아야 받는다(pid 재사용 차단).
//!
//! **이름은 비밀이 아니다** — `bootstrap_check_in` 으로 올린 이름은 `launchctl print gui/<uid>` 에 그대로 보인다(실측). 같은
//! 사용자의 어떤 프로세스든 아무 모양의 메시지를 넣을 수 있다고 보고, 모양을 먼저 엄격히 본 뒤 거절하는 메시지는
//! `mach_msg_destroy` 로 **실제 디스크립터대로** 버린다 — port 라고 가정하고 이름을 풀면 OOL 메모리 디스크립터가 든 메시지에서
//! 주소 조각을 port 이름으로 풀고 그 메모리는 새운다(실측 재현).
//! 판정자가 maru 역할로, 앱이(W3c `web_osr.zig`) 쓴다. **어느 링을 보일지(새 링의 첫 프레임까지 옛 링 유지)와 `take` 의
//! `.corrupt` 처리·GPU 소비자 규칙은 여기에 없다** — 앱은 `session/web_osr_view.zig`, 판정자는 자기 `View` 가 든다.

const std = @import("std");
const mach = @import("mach.zig");
const iosurface = @import("iosurface.zig");
const ring_message = @import("ring_message.zig");

pub const Ring = struct {
    browser: u64,
    generation: u32,
    width: u32,
    height: u32,
    scale: f32,
    surfaces: [ring_message.slot_count]iosurface.Ref,
    /// 제어 블록 페이지 주소(mailbox 워드가 맨 앞에 있다). 받는 쪽이 자기 mailbox 타입으로 본다 — 이 파일은 프로토콜
    /// 모듈을 import 하지 않는다(앱 빌드에서는 같은 파일이 두 모듈에 속할 수 없어 이름 import 를 쓸 수 없다, W3c).
    control_address: u64,

    pub fn release(self: Ring) void {
        for (self.surfaces) |surface| iosurface.release(surface);
        _ = mach.mach_vm_deallocate(mach.task(), self.control_address, mach.page_size);
    }
};

pub const Rejection = enum { wrong_pid, wrong_token, wrong_pid_version, malformed };

pub const Received = union(enum) {
    ring: Ring,
    rejected: Rejection,
};

pub const Receiver = struct {
    port: mach.Port,
    service: [64:0]u8,
    service_len: usize,
    token: [16]u8,
    /// 띄운 sidecar 의 pid — spawn 뒤에 채운다.
    expected_pid: c_int = 0,
    pinned_pid_version: ?c_int = null,

    pub fn open() error{MachFailed}!Receiver {
        var receiver: Receiver = .{ .port = mach.null_port, .service = undefined, .service_len = 0, .token = undefined };
        mach.randomBytes(&receiver.token);
        var suffix: [8]u8 = undefined;
        mach.randomBytes(&suffix);
        const name = std.fmt.bufPrintZ(&receiver.service, "dev.maru.web.{d}.{x}", .{ std.c.getpid(), std.mem.readInt(u64, &suffix, .little) }) catch return error.MachFailed;
        receiver.service_len = name.len;
        if (mach.bootstrap_check_in(mach.bootstrap_port, name, &receiver.port) != 0) return error.MachFailed;
        // 누가 넘치게 넣어도 진짜 sidecar 의 알림이 설 자리가 있게 대기열을 최대로 늘린다(기본 5).
        const limit: i32 = mach.queue_limit_max;
        _ = mach.mach_port_set_attributes(mach.task(), receiver.port, mach.port_limits_info, &limit, 1);
        return receiver;
    }

    pub fn serviceName(self: *const Receiver) []const u8 {
        return self.service[0..self.service_len];
    }

    /// 받는 권리를 닫는다 — 이름도 bootstrap 에서 사라진다(실측).
    pub fn close(self: *Receiver) void {
        _ = mach.mach_port_mod_refs(mach.task(), self.port, mach.right_receive, -1);
        self.port = mach.null_port;
    }

    /// 알림 하나를 기다린다. `timeout_ms` 안에 없으면 null.
    pub fn receive(self: *Receiver, timeout_ms: u32) error{MachFailed}!?Received {
        var incoming: ring_message.Received = undefined;
        const rc = mach.mach_msg(&incoming, mach.msg_rcv | mach.msg_rcv_timeout | mach.rcv_trailer_audit, 0, @sizeOf(ring_message.Received), self.port, timeout_ms, mach.null_port);
        if (rc == mach.rcv_timed_out) return null;
        // 너무 큰 메시지·머리 오류는 커널이 이미 버렸다. 디스크립터를 옮기다 실패한 메시지는 옮겨진 권리가 내 것이라 버린다.
        if (rc == mach.rcv_too_large or rc == mach.rcv_header_error) return .{ .rejected = .malformed };
        if (rc == mach.rcv_body_error) {
            mach.mach_msg_destroy(&incoming.message.header);
            return .{ .rejected = .malformed };
        }
        if (rc != 0) return error.MachFailed;
        const message = &incoming.message;
        // 트레일러는 메시지 끝(header.size)에 붙는다 — 모양이 맞을 때만 우리 구조체의 트레일러 자리와 같다.
        const verdict = self.check(message, incoming.trailer);
        if (verdict) |rejection| {
            mach.mach_msg_destroy(&message.header);
            return .{ .rejected = rejection };
        }
        return .{ .ring = adopt(message) catch {
            mach.mach_msg_destroy(&message.header);
            return .{ .rejected = .malformed };
        } };
    }

    fn check(self: *Receiver, message: *const ring_message.Message, trailer: mach.AuditTrailer) ?Rejection {
        if (!wellFormed(message)) return .malformed;
        // audit 트레일러가 아니면 pid 칸이 없다(0 으로 읽혀 pid 고정이 무력해진다).
        if (trailer.kind != mach.trailer_format_0 or trailer.size < @sizeOf(mach.AuditTrailer)) return .malformed;
        const audit = trailer.audit;
        if (mach.auditPid(audit) != self.expected_pid) return .wrong_pid;
        const expected = ring_message.tokenWords(self.token);
        if (!std.mem.eql(u32, &expected, &message.payload.token)) return .wrong_token;
        const version = mach.auditPidVersion(audit);
        // 실제 프로세스의 pid 버전은 0 이 아니다 — 0 이면 칸을 잘못 읽는 것이니 고정하지 않고 거절한다.
        if (version == 0) return .wrong_pid_version;
        if (self.pinned_pid_version) |pinned| {
            if (pinned != version) return .wrong_pid_version;
        } else self.pinned_pid_version = version;
        return null;
    }
};

/// 모양: id·complex·크기가 정확하고, 네 칸이 모두 **보낼 권리 port** 여야 한다(OOL 메모리 등 다른 디스크립터 거절). 머리에
/// 답장 port·voucher 가 없어야 한다 — 받아들인 메시지는 디스크립터만 풀므로, 답장 권리가 실려 오면 알림마다 이름 하나가
/// 샌다(적대 검증).
fn wellFormed(message: *const ring_message.Message) bool {
    if (message.header.id != ring_message.message_id) return false;
    if (message.header.bits & mach.bits_complex == 0) return false;
    if (message.header.bits & ~(mach.bits_complex | mach.bits_local_mask) != 0) return false;
    if (message.header.remote != mach.null_port or message.header.voucher != mach.null_port) return false;
    if (message.header.size != @sizeOf(ring_message.Message)) return false;
    if (message.body.descriptor_count != ring_message.slot_count + 1) return false;
    for (message.ports) |descriptor| {
        if (descriptor.kind != mach.port_descriptor or descriptor.disposition != mach.received_send_right) return false;
    }
    return true;
}

/// 알린 크기가 실제 surface 와 같아야 한다 — 크기를 속이면 maru 가 surface 밖을 읽는다.
const max_ring_extent: u32 = 16 * 1024 * 8;

fn adopt(message: *const ring_message.Message) error{Malformed}!Ring {
    var surfaces: [ring_message.slot_count]iosurface.Ref = undefined;
    var found: usize = 0;
    errdefer for (surfaces[0..found]) |surface| iosurface.release(surface);
    for (0..ring_message.slot_count) |i| {
        surfaces[i] = iosurface.fromMachPort(message.ports[i].name) orelse return error.Malformed;
        found += 1;
    }
    if (!surfacesFit(&surfaces, message.payload)) return error.Malformed;
    const payload = message.payload;
    const address = mach.mapShared(message.ports[ring_message.slot_count].name) catch return error.Malformed;
    // surface 와 페이지를 손에 넣었으니 받은 권리는 푼다(모양을 확인해 네 칸이 모두 port 다).
    dropPorts(message);
    return .{
        .browser = payload.browser(),
        .generation = payload.generation,
        .width = payload.width,
        .height = payload.height,
        .scale = @bitCast(payload.scale_bits),
        .surfaces = surfaces,
        .control_address = address,
    };
}

/// 알린 크기가 범위 안이고 세 장 모두 그 크기의 BGRA 링 모양인가(`iosurface.fitsRing`).
fn surfacesFit(surfaces: []const iosurface.Ref, payload: ring_message.Payload) bool {
    if (payload.width == 0 or payload.height == 0 or payload.width > max_ring_extent or payload.height > max_ring_extent) return false;
    for (surfaces) |surface| {
        if (!iosurface.fitsRing(surface, payload.width, payload.height)) return false;
    }
    return true;
}

fn dropPorts(message: *const ring_message.Message) void {
    const count = @min(message.body.descriptor_count, ring_message.slot_count + 1);
    for (message.ports[0..count]) |descriptor| {
        if (descriptor.name != mach.null_port) _ = mach.mach_port_deallocate(mach.task(), descriptor.name);
    }
}

// ── 시험: 검사만 — mach 호출 없이 가짜 audit token 으로 ─────────────────────────────────────────────

fn testMessage(token: [16]u8) ring_message.Message {
    var message = std.mem.zeroes(ring_message.Message);
    message.header.id = ring_message.message_id;
    message.header.bits = mach.bits_complex;
    message.header.size = @sizeOf(ring_message.Message);
    message.body.descriptor_count = ring_message.slot_count + 1;
    for (&message.ports) |*descriptor| descriptor.* = .{ .name = 0x1103, .disposition = mach.received_send_right };
    message.payload.token = ring_message.tokenWords(token);
    return message;
}

fn testAudit(pid: c_int, version: c_int) mach.AuditTrailer {
    var audit = [_]u32{0} ** 8;
    audit[5] = @bitCast(pid);
    audit[7] = @bitCast(version);
    return .{ .kind = mach.trailer_format_0, .size = @sizeOf(mach.AuditTrailer), .seqno = 0, .sender = .{ 0, 0 }, .audit = audit };
}

fn testReceiver(pid: c_int) Receiver {
    return .{ .port = mach.null_port, .service = undefined, .service_len = 0, .token = [_]u8{7} ** 16, .expected_pid = pid };
}

test "the spawned sidecar with the right token is accepted, and its pid version is pinned" {
    var receiver = testReceiver(500);
    const message = testMessage(receiver.token);
    try std.testing.expectEqual(@as(?Rejection, null), receiver.check(&message, testAudit(500, 41)));
    try std.testing.expectEqual(@as(?c_int, 41), receiver.pinned_pid_version);
    try std.testing.expectEqual(@as(?Rejection, null), receiver.check(&message, testAudit(500, 41)));
}

test "another pid is refused even with the right token" {
    var receiver = testReceiver(500);
    const message = testMessage(receiver.token);
    try std.testing.expectEqual(@as(?Rejection, .wrong_pid), receiver.check(&message, testAudit(501, 41)));
}

test "the right pid with a wrong token is refused — a process that reused the pid does not know the token" {
    var receiver = testReceiver(500);
    const message = testMessage([_]u8{8} ** 16);
    try std.testing.expectEqual(@as(?Rejection, .wrong_token), receiver.check(&message, testAudit(500, 41)));
    try std.testing.expectEqual(@as(?c_int, null), receiver.pinned_pid_version);
}

test "after the first message a different pid version is refused" {
    var receiver = testReceiver(500);
    const message = testMessage(receiver.token);
    _ = receiver.check(&message, testAudit(500, 41));
    try std.testing.expectEqual(@as(?Rejection, .wrong_pid_version), receiver.check(&message, testAudit(500, 42)));
}

test "a message that is not a ring announcement is malformed" {
    var receiver = testReceiver(500);
    var message = testMessage(receiver.token);
    message.header.id = 1;
    try std.testing.expectEqual(@as(?Rejection, .malformed), receiver.check(&message, testAudit(500, 41)));
    message = testMessage(receiver.token);
    message.body.descriptor_count = 2;
    try std.testing.expectEqual(@as(?Rejection, .malformed), receiver.check(&message, testAudit(500, 41)));
}

test "an out-of-line memory descriptor, a receive right or a wrong size is malformed, not a port to release" {
    var receiver = testReceiver(500);
    const good = testMessage(receiver.token);
    var message = good;
    message.ports[1].kind = 1; // MACH_MSG_OOL_DESCRIPTOR — 이 칸의 name 은 주소 조각이다(실측)
    try std.testing.expectEqual(@as(?Rejection, .malformed), receiver.check(&message, testAudit(500, 41)));
    message = good;
    message.ports[3].disposition = 16; // MACH_MSG_TYPE_PORT_RECEIVE
    try std.testing.expectEqual(@as(?Rejection, .malformed), receiver.check(&message, testAudit(500, 41)));
    message = good;
    message.header.size -= 4;
    try std.testing.expectEqual(@as(?Rejection, .malformed), receiver.check(&message, testAudit(500, 41)));
    // 모양이 틀리면 pid 버전도 고정되지 않는다.
    try std.testing.expectEqual(@as(?c_int, null), receiver.pinned_pid_version);
}

test "a reply port, a voucher, a non-audit trailer or pid version 0 is refused before anything is pinned" {
    var receiver = testReceiver(500);
    const good = testMessage(receiver.token);
    var message = good;
    message.header.bits |= mach.type_make_send_once; // 답장 port 처분(remote 칸)
    try std.testing.expectEqual(@as(?Rejection, .malformed), receiver.check(&message, testAudit(500, 41)));
    message = good;
    message.header.remote = 0x2203;
    try std.testing.expectEqual(@as(?Rejection, .malformed), receiver.check(&message, testAudit(500, 41)));
    message = good;
    message.header.voucher = 0x2303;
    try std.testing.expectEqual(@as(?Rejection, .malformed), receiver.check(&message, testAudit(500, 41)));
    var short = testAudit(500, 41);
    short.size = 20; // seqno 트레일러 — audit 칸이 없다
    try std.testing.expectEqual(@as(?Rejection, .malformed), receiver.check(&good, short));
    try std.testing.expectEqual(@as(?Rejection, .wrong_pid_version), receiver.check(&good, testAudit(500, 0)));
    try std.testing.expectEqual(@as(?c_int, null), receiver.pinned_pid_version);
}

test "surfaces must be the announced size in BGRA with 4-byte elements — a disguised 1-byte surface is refused" {
    const payload: ring_message.Payload = .{ .token = .{ 0, 0, 0, 0 }, .browser_lo = 1, .browser_hi = 0, .generation = 1, .width = 256, .height = 16, .scale_bits = 0 };
    const good = try iosurface.create(256, 16);
    defer iosurface.release(good);
    try std.testing.expect(surfacesFit(&.{ good, good, good }, payload));
    // 폭·높이는 맞지만 요소 1 바이트(8 비트 흑백) — 적대 검증의 넘침 재현 모양.
    const narrow = try iosurface.createWith(256, 16, 1, 0x4C303038); // 'L008'
    defer iosurface.release(narrow);
    try std.testing.expect(!surfacesFit(&.{ good, narrow, good }, payload));
    // 요소 4 바이트라 줄·할당 크기는 맞지만 형식이 다르다(RGBA) — 형식 검사만이 거른다.
    const rgba = try iosurface.createWith(256, 16, 4, 0x52474241);
    defer iosurface.release(rgba);
    try std.testing.expect(!surfacesFit(&.{ rgba, good, good }, payload));
    const small = try iosurface.create(255, 16);
    defer iosurface.release(small);
    try std.testing.expect(!surfacesFit(&.{ good, good, small }, payload));
    var zero = payload;
    zero.height = 0;
    try std.testing.expect(!surfacesFit(&.{ good, good, good }, zero));
}
