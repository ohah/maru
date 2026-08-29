//! InputOwner — terminal input을 local PTY와 session-host transport에 같은 형태로 전달하는 중립 facade.
//!
//! CR2c는 입력 의미나 queue 소유권을 바꾸지 않는다. 이 값은 opaque runtime handle과 backend별 함수표를
//! 결속해 caller가 local/remote 구현을 분기하지 않게 하는 구조 seam만 만든다. ordered record,
//! epoch/sequence, paused paste storage는 CR2d에서 이 facade 뒤로 이동한다.

const std = @import("std");
const core_command = @import("../session/core_command.zig");

pub const RuntimeHandle = u64;

/// AppKit callback에서 blocking write를 피해야 하는 완성된 byte batch의 출처다. CR2d2의 key/control은
/// public batch admission이 아니므로 아래 enum을 넓히지 않고 별도 QueueRecordKind에서만 합친다.
pub const InputBatchKind = enum(u8) {
    paste = 1,
    ime_commit = 2,
    osc52_response = 3,
};

pub const InputBatch = struct {
    kind: InputBatchKind,
    first: []const u8,
    second: []const u8 = &.{},
    normalize_first_newlines: bool = false,
};

/// local은 기존 Window queue가 ownership을 유지하고, remote만 stable backend queue가 전체 batch를 인수한다.
pub const BatchAdmission = enum(u8) {
    caller_owned,
    backend_owned,
};

/// Stable remote input owner가 byte/control을 한 epoch 안에서 관측하는 closed 순서 역할이다.
/// paste-family public admission 종류와 key/control transport 역할을 섞지 않기 위해 InputBatchKind와 분리한다.
pub const QueueRecordKind = enum(u8) {
    paste = 1,
    ime_commit = 2,
    osc52_response = 3,
    key_bytes = 4,
    scroll_to_bottom = 5,
    core_command = 6,
    observation_probe = 7,

    pub fn fromBatch(kind: InputBatchKind) QueueRecordKind {
        return switch (kind) {
            .paste => .paste,
            .ime_commit => .ime_commit,
            .osc52_response => .osc52_response,
        };
    }

    pub fn isControl(self: QueueRecordKind) bool {
        return self == .scroll_to_bottom or self == .core_command or self == .observation_probe;
    }
};

pub const QueueRecord = struct {
    kind: QueueRecordKind,
    epoch: u64,
    sequence: u64,
    /// byte record는 exclusive byte end, control record는 그 명령의 byte barrier다.
    end_offset: usize,
};

/// RemoteRuntime final owner에 inline으로 놓이는 stable ordered transcript. byte/control backing은 기존
/// `direct_input`/`pending_controls`가 소유하고 이 값은 typed boundary와 checked epoch/sequence만 소유한다.
pub const StableQueueState = struct {
    epoch: u64 = 1,
    next_sequence: u64 = 0,
    records: std.ArrayListUnmanaged(QueueRecord) = .empty,

    pub fn deinit(self: *StableQueueState, allocator: std.mem.Allocator) void {
        self.records.deinit(allocator);
        self.* = .{};
    }
};

pub const VTable = struct {
    write: *const fn (ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!void,
    write_nonblocking: *const fn (ctx: *anyopaque, handle: RuntimeHandle, bytes: []const u8) anyerror!usize,
    enqueue_core_command: *const fn (ctx: *anyopaque, handle: RuntimeHandle, command: core_command.CoreCommand, io: std.Io) anyerror!void,
    enqueue_batch: *const fn (ctx: *anyopaque, handle: RuntimeHandle, batch: InputBatch) anyerror!BatchAdmission,
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

    pub fn enqueueBatch(self: InputOwner, batch: InputBatch) anyerror!BatchAdmission {
        return self.vtable.enqueue_batch(self.ctx, self.handle, batch);
    }
};

const Fixture = struct {
    last_handle: RuntimeHandle = 0,
    bytes: []const u8 = "",
    command: ?core_command.CoreCommand = null,
    accepted: usize = 0,
    failure: ?anyerror = null,
    batch_admission: BatchAdmission = .caller_owned,
    batch_kind: ?InputBatchKind = null,

    const vtable = VTable{
        .write = write,
        .write_nonblocking = writeNonBlocking,
        .enqueue_core_command = enqueueCoreCommand,
        .enqueue_batch = enqueueBatch,
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

    fn enqueueBatch(ctx: *anyopaque, handle: RuntimeHandle, batch: InputBatch) anyerror!BatchAdmission {
        const self: *Fixture = @ptrCast(@alignCast(ctx));
        if (self.failure) |err| return err;
        self.last_handle = handle;
        self.batch_kind = batch.kind;
        return self.batch_admission;
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

test "CR2d1 InputOwner batch는 closed kind와 backend ownership 결과를 그대로 전달한다" {
    var fixture = Fixture{ .batch_admission = .backend_owned };
    const owner = fixture.owner(0xD101);
    try std.testing.expectEqual(
        BatchAdmission.backend_owned,
        try owner.enqueueBatch(.{ .kind = .ime_commit, .first = "commit", .second = "replay" }),
    );
    try std.testing.expectEqual(@as(u64, 0xD101), fixture.last_handle);
    try std.testing.expectEqual(InputBatchKind.ime_commit, fixture.batch_kind.?);
    try std.testing.expectEqual(@as(u8, 1), @intFromEnum(InputBatchKind.paste));
    try std.testing.expectEqual(@as(u8, 2), @intFromEnum(InputBatchKind.ime_commit));
    try std.testing.expectEqual(@as(u8, 3), @intFromEnum(InputBatchKind.osc52_response));
}

test "CR2d1 InputOwner batch 오류는 caller ownership 결과로 laundering하지 않는다" {
    var fixture = Fixture{ .failure = error.OutOfMemory };
    const owner = fixture.owner(0xD102);
    try std.testing.expectError(
        error.OutOfMemory,
        owner.enqueueBatch(.{ .kind = .paste, .first = "owned-by-caller" }),
    );
    try std.testing.expectEqual(@as(u64, 0), fixture.last_handle);
}
