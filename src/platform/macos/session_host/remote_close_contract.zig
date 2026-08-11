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
