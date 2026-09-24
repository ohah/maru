//! W2 적대 판정용 공격 메시지(제3자 역할 — `maru-web-judge --attack <종류> <이름>`). 받는 port 의 이름은 비밀이 아니다
//! (`launchctl print gui/<uid>` 에 보인다 — 실측) — 같은 사용자의 아무 프로세스나 아무 모양의 메시지를 넣을 수 있다고 본다.
//!
//!   ool    32MB OOL 메모리 디스크립터가 든 메시지 30 통 — 받는 쪽이 port 라고 가정하면 주소 조각을 port 이름으로 풀고 메모리를 샌다
//!   big    받는 버퍼보다 큰 인라인 메시지 — 받는 쪽은 거절로 세고 계속 받아야 한다
//!   flood  짧은 메시지 2,000 통을 기다리지 않고 넣는다 — 받는 쪽이 바빠 못 비우는 동안 대기열을 가득 채운다(막힌 통이
//!          없으면 exit 6 — 포화하지 않았다)

const std = @import("std");
const ring = @import("web_sidecar_ring");

const mach = ring.mach;
const ring_message = ring.ring_message;

pub const ool_messages = 30;
pub const ool_bytes = 32 * 1024 * 1024;
pub const flood_messages = 2000;

const OolMessage = extern struct {
    header: mach.Header,
    body: mach.Body,
    // C 는 pack(4) 라 포인터가 4 바이트 경계에 온다 — 두 칸으로 나눠 배치를 맞춘다.
    address_lo: u32,
    address_hi: u32,
    deallocate: u8 = 0,
    copy: u8 = 1, // MACH_MSG_VIRTUAL_COPY
    pad1: u8 = 0,
    kind: u8 = 1, // MACH_MSG_OOL_DESCRIPTOR
    size: u32,
};

const BigMessage = extern struct {
    header: mach.Header,
    filler: [64 * 1024]u8,
};

const SmallMessage = extern struct {
    header: mach.Header,
};

comptime {
    std.debug.assert(@sizeOf(OolMessage) == 24 + 4 + 16);
}

fn lookUp(service: []const u8) ?mach.Port {
    var name: [128:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&name, "{s}", .{service}) catch return null;
    var port: mach.Port = mach.null_port;
    if (mach.bootstrap_look_up(mach.bootstrap_port, z, &port) != 0) return null;
    return port;
}

fn send(message: anytype, size: u32) i32 {
    return mach.mach_msg(message, mach.msg_send | mach.msg_send_timeout, size, 0, mach.null_port, 200, mach.null_port);
}

pub fn main(kind: []const u8, service: []const u8) u8 {
    const port = lookUp(service) orelse return 3;
    const header: mach.Header = .{ .bits = mach.bits(mach.type_copy_send, 0), .size = 0, .remote = port, .local = mach.null_port, .id = ring_message.message_id };
    if (std.mem.eql(u8, kind, "ool")) {
        const buffer = std.heap.page_allocator.alloc(u8, ool_bytes) catch return 4;
        @memset(buffer, 0x5A);
        const address = @intFromPtr(buffer.ptr);
        var sent: u32 = 0;
        for (0..ool_messages) |_| {
            var message: OolMessage = .{
                .header = header,
                .body = .{ .descriptor_count = 1 },
                .address_lo = @truncate(address),
                .address_hi = @truncate(address >> 32),
                .size = ool_bytes,
            };
            message.header.bits |= mach.bits_complex;
            message.header.size = @sizeOf(OolMessage);
            if (send(&message, @sizeOf(OolMessage)) == 0) sent += 1;
        }
        return if (sent == ool_messages) 0 else 5;
    }
    if (std.mem.eql(u8, kind, "big")) {
        const message = std.heap.page_allocator.create(BigMessage) catch return 4;
        message.* = .{ .header = header, .filler = @splat(0x42) };
        message.header.size = @sizeOf(BigMessage);
        return if (send(message, @sizeOf(BigMessage)) == 0) 0 else 5;
    }
    if (std.mem.eql(u8, kind, "flood")) {
        var sent: u32 = 0;
        for (0..flood_messages) |_| {
            var message: SmallMessage = .{ .header = header };
            message.header.size = @sizeOf(SmallMessage);
            // 기다리지 않는다 — 대기열이 차면 그 자리에서 실패하고 다음 통으로 넘어간다.
            if (mach.mach_msg(&message, mach.msg_send | mach.msg_send_timeout, @sizeOf(SmallMessage), 0, mach.null_port, 0, mach.null_port) == 0) sent += 1;
        }
        // 대기열이 **실제로 찼는지** 종료 코드로 알린다 — 한 통이라도 한도에 막혀야 포화다(막힌 적이 없으면 재시도 경로를
        // 안 탄 것이라 판정이 빈 검사가 된다).
        std.debug.print("flood: {d}/{d} 통 넣음\n", .{ sent, flood_messages });
        return if (sent > 0 and sent < flood_messages) 0 else 6;
    }
    return 2;
}

extern "c" fn task_info(task: mach.Port, flavor: i32, info: *anyopaque, count: *u32) i32;

/// 이 프로세스의 가상 주소 공간 크기 — OOL 메모리가 새면 는다(메모리를 건드리지 않아 물리 사용량으로는 안 보인다).
pub fn virtualSize() u64 {
    var info: [93]u32 = undefined;
    var count: u32 = info.len;
    if (task_info(mach.task(), 22, &info, &count) != 0) return 0;
    return @as(u64, info[1]) << 32 | info[0];
}
