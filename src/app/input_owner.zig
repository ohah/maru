//! InputOwner — terminal input을 local PTY와 session-host transport에 같은 형태로 전달하는 중립 facade.
//!
//! CR2c는 입력 의미나 queue 소유권을 바꾸지 않는다. 이 값은 opaque runtime handle과 backend별 함수표를
//! 결속해 caller가 local/remote 구현을 분기하지 않게 하는 구조 seam만 만든다. ordered record,
//! epoch/sequence, paused paste storage는 CR2d에서 이 facade 뒤로 이동한다.

const std = @import("std");
const core_command = @import("../session/core_command.zig");

pub const RuntimeHandle = u64;

pub const VTable = struct {
    write: *const fn (ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void,
    write_nonblocking: *const fn (ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize,
    enqueue_core_command: *const fn (ctx: *anyopaque, handle: RuntimeHandle, command: core_command.CoreCommand, io: std.Io) anyerror!void,
};

pub const InputOwner = struct {
    ctx: *anyopaque,
    handle: RuntimeHandle,
    vtable: *const VTable,

    pub fn write(self: InputOwner, bytes: []const u8) anyerror!void {
        return self.vtable.write(self.ctx, self.handle, bytes);
    }

    pub fn writeNonBlocking(self: InputOwner, bytes: []const u8) anyerror!usize {
        return self.vtable.write_nonblocking(self.ctx, self.handle, bytes);
    }

    pub fn enqueueCoreCommand(self: InputOwner, command: core_command.CoreCommand, io: std.Io) anyerror!void {
        return self.vtable.enqueue_core_command(self.ctx, self.handle, command, io);
    }
};

const Fixture = struct {
    last_handle: RuntimeHandle = 0,
    bytes: []const u8 = "",
    command: ?core_command.CoreCommand = null,
    accepted: usize = 0,
    failure: ?anyerror = null,

    const vtable = VTable{
        .write = write,
        .write_nonblocking = writeNonBlocking,
        .enqueue_core_command = enqueueCoreCommand,
    };

    fn owner(self: *Fixture, handle: RuntimeHandle) InputOwner {
        return .{ .ctx = self, .handle = handle, .vtable = &vtable };
    }

    fn write(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (self.failure) |err| return err;
        self.last_handle = handle;
        self.bytes = bytes;
    }

    fn writeNonBlocking(ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (self.failure) |err| return err;
        self.last_handle = handle;
        self.bytes = bytes;
        return @min(self.accepted, bytes.len);
    }

    fn enqueueCoreCommand(ctx: *anyopaque, handle: RuntimeHandle, command: core_command.CoreCommand, io: std.Io) anyerror!void {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        _ = io;
        if (self.failure) |err| return err;
        self.last_handle = handle;
        self.command = command;
    }
};

test "CR2c InputOwner facade는 blocking input과 opaque handle을 그대로 전달한다" {
    var fixture = Fixture{};
    const owner = fixture.owner(0xA101);
    try owner.write("local-or-remote");
    try std.testing.expectEqual(@as(u64, 0xA101), fixture.last_handle);
    try std.testing.expectEqualStrings("local-or-remote", fixture.bytes);
}

test "CR2c InputOwner facade는 nonblocking partial progress와 오류를 바꾸지 않는다" {
    var fixture = Fixture{ .accepted = 3 };
    const owner = fixture.owner(0xA102);
    try std.testing.expectEqual(@as(usize, 3), try owner.writeNonBlocking("abcdef"));
    fixture.failure = error.WouldBlock;
    try std.testing.expectError(error.WouldBlock, owner.writeNonBlocking("retry"));
}

test "CR2c InputOwner facade는 core command를 같은 owner에 ordered dispatch한다" {
    var fixture = Fixture{};
    const owner = fixture.owner(0xA103);
    try owner.enqueueCoreCommand(.scroll_to_bottom, std.testing.io);
    try std.testing.expectEqual(@as(u64, 0xA103), fixture.last_handle);
    try std.testing.expectEqual(core_command.CoreCommand.scroll_to_bottom, fixture.command.?);
}
