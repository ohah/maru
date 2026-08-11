//! 원격 runtime close의 pointer-free 스캔·진행 계약이다.
//!
//! backend map과 heap Runtime 권위는 이 파일에 들어오지 않는다. sweep가 callback 전에 복사하는 값만
//! 고정해야 iterator 종료 뒤 relookup이 stale pointer 없이 동작하고, 상위 계층이 이 DTO를 제거 권위로
//! 오해하지 않는다.

const std = @import("std");

pub const CloseScanReceipt = struct {
    handle: u64,
    runtime_generation: u64,
    close_request_generation: u64,
    close_schedule_ticket: u64,
};

pub const ClosingReceipt = struct {
    scan: CloseScanReceipt,
    consumed: bool = false,
};

pub const CloseSweep = union(enum(u8)) {
    inactive,
    active: Active,

    pub const Active = struct {
        max_ticket: u64,
        cursor_after_ticket: u64,
    };
};

pub const CloseTicketIssuer = struct {
    last_issued: u64 = 0,
    terminal: bool = false,

    pub fn canIssue(self: CloseTicketIssuer) bool {
        return !self.terminal and self.last_issued < std.math.maxInt(u64);
    }

    pub fn issue(self: *CloseTicketIssuer) ?u64 {
        if (!self.canIssue()) return null;
        self.last_issued += 1;
        if (self.last_issued == std.math.maxInt(u64)) self.terminal = true;
        return self.last_issued;
    }
};

pub fn validCloseScheduleTicket(ticket: u64) bool {
    return ticket != 0;
}

/// 한 tick에서 frozen max 이하의 다음 ticket을 최대 `out.len`개 오름차순으로 고른다.
/// map iterator 순서에 기대지 않고 callback 전에 receipt 값만 읽으며, 활성 sweep에는 새 ticket을 편입하지 않는다.
pub fn selectCloseSweep(
    sweep: *CloseSweep,
    receipts: []const CloseScanReceipt,
    out: []CloseScanReceipt,
) usize {
    if (out.len == 0) return 0;
    if (sweep.* == .inactive) {
        var max_ticket: u64 = 0;
        for (receipts) |receipt| {
            if (validCloseScheduleTicket(receipt.close_schedule_ticket))
                max_ticket = @max(max_ticket, receipt.close_schedule_ticket);
        }
        if (max_ticket == 0) return 0;
        sweep.* = .{ .active = .{ .max_ticket = max_ticket, .cursor_after_ticket = 0 } };
    }

    const frozen_max = sweep.active.max_ticket;
    var cursor = sweep.active.cursor_after_ticket;
    var selected: usize = 0;
    while (selected < out.len) {
        var next: ?CloseScanReceipt = null;
        for (receipts) |receipt| {
            const ticket = receipt.close_schedule_ticket;
            if (ticket <= cursor or ticket > frozen_max) continue;
            if (next == null or ticket < next.?.close_schedule_ticket) next = receipt;
        }
        const receipt = next orelse break;
        out[selected] = receipt;
        selected += 1;
        cursor = receipt.close_schedule_ticket;
    }

    if (cursor >= frozen_max or selected == 0) {
        sweep.* = .inactive;
    } else {
        sweep.active.cursor_after_ticket = cursor;
    }
    return selected;
}

pub fn sameCloseScanReceipt(a: CloseScanReceipt, b: CloseScanReceipt) bool {
    return std.meta.eql(a, b);
}

pub fn consumeClosingReceipt(receipt: *ClosingReceipt, expected: CloseScanReceipt, backend_present_after: bool) bool {
    if (receipt.consumed or backend_present_after or !sameCloseScanReceipt(receipt.scan, expected)) return false;
    receipt.consumed = true;
    return true;
}

pub fn recursivelyPointerFree(comptime T: type) bool {
    return switch (@typeInfo(T)) {
        .pointer, .error_union, .optional => false,
        .array => |info| recursivelyPointerFree(info.child),
        .@"struct" => |info| blk: {
            inline for (info.fields) |field| {
                if (!recursivelyPointerFree(field.type)) break :blk false;
            }
            break :blk true;
        },
        .@"union" => |info| blk: {
            inline for (info.fields) |field| {
                if (!recursivelyPointerFree(field.type)) break :blk false;
            }
            break :blk true;
        },
        .@"fn" => false,
        else => true,
    };
}
