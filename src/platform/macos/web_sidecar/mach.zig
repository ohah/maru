//! mach 메시지·port·공유 메모리(W2, docs/plans/web-osr-backend.md C3). 크기와 상수는 SDK 헤더에서 잰 값이다
//! (`mach_msg_header_t` 24 · `mach_msg_port_descriptor_t` 12 · `mach_msg_audit_trailer_t` 52 바이트) — 아래 comptime 이 잠근다.

const std = @import("std");

pub const Port = u32;
pub const null_port: Port = 0;

pub const Header = extern struct {
    bits: u32,
    size: u32,
    remote: Port,
    local: Port,
    voucher: Port = 0,
    id: i32,
};

pub const Body = extern struct { descriptor_count: u32 };

/// C 의 비트필드(pad2:16 · disposition:8 · type:8)와 같은 배치(리틀 엔디언).
pub const PortDescriptor = extern struct {
    name: Port,
    pad1: u32 = 0,
    pad2: u16 = 0,
    disposition: u8,
    kind: u8 = 0, // MACH_MSG_PORT_DESCRIPTOR
};

pub const AuditTrailer = extern struct {
    kind: u32,
    size: u32,
    seqno: u32,
    sender: [2]u32,
    audit: [8]u32,
};

pub const msg_send: i32 = 1;
pub const msg_send_timeout: i32 = 0x10;
pub const msg_rcv: i32 = 2;
pub const msg_rcv_timeout: i32 = 0x100;
pub const rcv_trailer_audit: i32 = 0x0300_0000;
pub const rcv_timed_out: i32 = 0x1000_4003;
/// 받는 버퍼보다 큰 메시지 — 커널이 이미 버렸다(MACH_RCV_LARGE 를 안 켰으므로).
pub const rcv_too_large: i32 = 0x1000_4004;
pub const port_descriptor: u8 = 0;
/// 받은 쪽에서 본 보낼 권리(MACH_MSG_TYPE_PORT_SEND — move/copy 로 보낸 것 모두).
pub const received_send_right: u8 = 17;
pub const bits_complex: u32 = 0x8000_0000;
pub const type_move_send: u8 = 17;
pub const type_copy_send: u8 = 19;
pub const right_receive: u32 = 1;

pub fn bits(remote: u32, local: u32) u32 {
    return remote | (local << 8);
}

comptime {
    std.debug.assert(@sizeOf(Header) == 24);
    std.debug.assert(@sizeOf(PortDescriptor) == 12);
    std.debug.assert(@sizeOf(AuditTrailer) == 52);
}

pub extern "c" var bootstrap_port: Port;
pub extern "c" var mach_task_self_: Port;
pub extern "c" fn bootstrap_check_in(bp: Port, name: [*:0]const u8, out: *Port) i32;
pub extern "c" fn bootstrap_look_up(bp: Port, name: [*:0]const u8, out: *Port) i32;
pub extern "c" fn mach_msg(msg: *anyopaque, option: i32, send_size: u32, rcv_size: u32, rcv_name: Port, timeout: u32, notify: Port) i32;
pub extern "c" fn mach_port_deallocate(task: Port, name: Port) i32;
/// 받은 메시지를 **실제 디스크립터대로** 정리한다(port 권리·OOL 메모리). 모양을 믿을 수 없는 메시지는 이것으로만 버린다.
pub extern "c" fn mach_msg_destroy(header: *anyopaque) void;
pub extern "c" fn mach_port_set_attributes(task: Port, name: Port, flavor: i32, info: *const i32, count: u32) i32;
pub const port_limits_info: i32 = 1;
pub const queue_limit_max: i32 = 1024;
pub extern "c" fn mach_port_mod_refs(task: Port, name: Port, right: u32, delta: i32) i32;
pub extern "c" fn mach_vm_allocate(task: Port, address: *u64, size: u64, flags: i32) i32;
pub extern "c" fn mach_vm_deallocate(task: Port, address: u64, size: u64) i32;
pub extern "c" fn mach_make_memory_entry_64(task: Port, size: *u64, offset: u64, permission: i32, handle: *Port, parent: Port) i32;
pub extern "c" fn mach_vm_map(task: Port, address: *u64, size: u64, mask: u64, flags: i32, object: Port, offset: u64, copy: i32, cur: i32, max: i32, inherit: u32) i32;
/// audit token 은 u32 여덟 칸이다 — libbsm 의 `audit_token_to_pid`·`audit_token_to_pidversion` 이 읽는 칸(5·7)을 그대로
/// 읽는다(라이브러리를 붙이지 않으려고). 판정자가 띄운 pid 와 대조해 칸이 맞는지 본다.
pub fn auditPid(token: [8]u32) c_int {
    return @bitCast(token[5]);
}

pub fn auditPidVersion(token: [8]u32) c_int {
    return @bitCast(token[7]);
}

pub const vm_flags_anywhere: i32 = 1;
pub const vm_prot_read_write: i32 = 3;
pub const vm_inherit_none: u32 = 2;
pub const page_size: u64 = 16 * 1024;

pub fn task() Port {
    return mach_task_self_;
}

/// 공유할 한 페이지. `entry` 를 링 알림에 실어 넘기면 받는 쪽이 `mapShared` 로 같은 페이지를 본다.
pub const SharedPage = struct {
    address: u64,
    entry: Port,

    pub fn create() error{MachFailed}!SharedPage {
        var address: u64 = 0;
        if (mach_vm_allocate(task(), &address, page_size, vm_flags_anywhere) != 0) return error.MachFailed;
        var size: u64 = page_size;
        var entry: Port = null_port;
        if (mach_make_memory_entry_64(task(), &size, address, vm_prot_read_write, &entry, null_port) != 0) {
            _ = mach_vm_deallocate(task(), address, page_size);
            return error.MachFailed;
        }
        return .{ .address = address, .entry = entry };
    }

    pub fn destroy(self: SharedPage) void {
        _ = mach_port_deallocate(task(), self.entry);
        _ = mach_vm_deallocate(task(), self.address, page_size);
    }
};

/// 받은 메모리 엔트리를 내 주소 공간에 올린다.
pub fn mapShared(entry: Port) error{MachFailed}!u64 {
    var address: u64 = 0;
    if (mach_vm_map(task(), &address, page_size, 0, vm_flags_anywhere, entry, 0, 0, vm_prot_read_write, vm_prot_read_write, vm_inherit_none) != 0) return error.MachFailed;
    return address;
}

extern "c" fn arc4random_buf(buf: [*]u8, len: usize) void;

/// OS 의 암호학적 난수(C3 — 토큰·받는 port 이름).
pub fn randomBytes(out: []u8) void {
    arc4random_buf(out.ptr, out.len);
}
