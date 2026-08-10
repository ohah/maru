//! Process-global keyed seal service for session-host ownership registries.
//!
//! ClientSlot's canonical bootstrap is the only production initializer. It publishes the secret
//! ready only after the issuer registries exist, never exposes or resets the raw key, rejects a
//! forked process before secret/registry access, and offers fixed-domain typed derivation only.

const builtin = @import("builtin");
const std = @import("std");
const process_identity = @import("process_identity.zig");

const secret_len = 32;
const capability_domain = "maru.capability.registry-key.v2";

pub const PrepareError = error{
    ProcessDomainMismatch,
    EntropyUnavailable,
    ZeroKey,
    Terminal,
};

pub const ReadyError = error{
    ProcessDomainMismatch,
    NotReady,
    Terminal,
};

pub const PreparedReceipt = struct {
    pid: u32 = 0,
    process_nonce: u64 = 0,
    incarnation: u64 = 0,
    token: u64 = 0,
};

pub const CapabilityKeyInput = struct {
    counter: u64,
    slot_index: u16,
    slot_generation: u64,
};

const State = enum(u8) {
    uninitialized,
    initializing,
    ready,
    terminal,
};

const EntropyMode = union(enum) {
    production,
    zero,
    unavailable,
    scalar_seed: u64,
    scalar_seed_zero_output: u64,
};

const PauseHook = struct {
    reached: std.atomic.Value(bool) = .init(false),
    proceed: std.atomic.Value(bool) = .init(false),
};

const Service = struct {
    state: std.atomic.Value(u8) = .init(@intFromEnum(State.uninitialized)),
    owner_pid: u32 = 0,
    owner_nonce: u64 = 0,
    incarnation: u64 = 0,
    receipt_token: u64 = 0,
    secret: [secret_len]u8 = [_]u8{0} ** secret_len,
    pause_hook: if (builtin.is_test) ?*PauseHook else void = if (builtin.is_test) null else {},

    fn loadState(self: *const Service, comptime order: std.builtin.AtomicOrder) State {
        return @enumFromInt(self.state.load(order));
    }

    fn publishTerminal(self: *Service) void {
        self.state.store(@intFromEnum(State.terminal), .release);
    }

    fn secureEntropy(destination: []u8) PrepareError!void {
        switch (builtin.os.tag) {
            .macos => std.c.arc4random_buf(destination.ptr, destination.len),
            .linux => {
                var offset: usize = 0;
                while (offset < destination.len) {
                    const rc = std.c.getrandom(destination[offset..].ptr, destination.len - offset, 0);
                    if (rc < 0) {
                        if (std.posix.errno(rc) == .INTR) continue;
                        return error.EntropyUnavailable;
                    }
                    if (rc == 0) return error.EntropyUnavailable;
                    offset += @intCast(rc);
                }
            },
            else => return error.EntropyUnavailable,
        }
    }

    fn fillEntropy(self: *Service, mode: EntropyMode) PrepareError!void {
        switch (mode) {
            .production => try secureEntropy(&self.secret),
            .zero => @memset(&self.secret, 0),
            .unavailable => return error.EntropyUnavailable,
            .scalar_seed, .scalar_seed_zero_output => |seed_value| {
                if (seed_value == 0) return error.ZeroKey;
                var hasher = std.crypto.hash.Blake3.init(.{});
                hasher.update("maru.process-seal.test-seed.v1");
                var seed: [8]u8 = undefined;
                std.mem.writeInt(u64, &seed, seed_value, .little);
                hasher.update(&seed);
                hasher.final(&self.secret);
                if (mode == .scalar_seed_zero_output) @memset(&self.secret, 0);
            },
        }
    }

    fn prepareWithEntropy(
        self: *Service,
        pid: u32,
        process_nonce: u64,
        mode: EntropyMode,
    ) PrepareError!PreparedReceipt {
        if (pid == 0 or process_nonce == 0 or currentProcessId() != pid)
            return error.ProcessDomainMismatch;

        const observed = self.loadState(.acquire);
        if (observed == .terminal) return error.Terminal;
        if (observed != .uninitialized) return error.ProcessDomainMismatch;
        if (self.state.cmpxchgStrong(
            @intFromEnum(State.uninitialized),
            @intFromEnum(State.initializing),
            .acq_rel,
            .acquire,
        )) |_| return error.ProcessDomainMismatch;

        self.owner_pid = pid;
        self.owner_nonce = process_nonce;
        self.incarnation = 1;
        self.fillEntropy(mode) catch |err| {
            self.publishTerminal();
            return err;
        };
        var any: u8 = 0;
        for (self.secret) |byte| any |= byte;
        if (any == 0) {
            self.publishTerminal();
            return error.ZeroKey;
        }
        if (builtin.is_test) {
            if (self.pause_hook) |hook| {
                hook.reached.store(true, .release);
                while (!hook.proceed.load(.acquire)) std.atomic.spinLoopHint();
            }
        }

        var hasher = std.crypto.hash.Blake3.init(.{ .key = self.secret });
        hasher.update("maru.process-seal.prepared-receipt.v1");
        var material: [20]u8 = undefined;
        std.mem.writeInt(u32, material[0..4], pid, .little);
        std.mem.writeInt(u64, material[4..12], process_nonce, .little);
        std.mem.writeInt(u64, material[12..20], self.incarnation, .little);
        hasher.update(&material);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        self.receipt_token = std.mem.readInt(u64, digest[0..8], .little);
        if (self.receipt_token == 0) {
            self.publishTerminal();
            return error.ZeroKey;
        }
        return .{
            .pid = pid,
            .process_nonce = process_nonce,
            .incarnation = self.incarnation,
            .token = self.receipt_token,
        };
    }

    fn fatalInvalidReceipt() noreturn {
        switch (builtin.os.tag) {
            .macos, .linux => std.c._exit(70),
            else => @trap(),
        }
    }

    fn commitReady(self: *Service, receipt: PreparedReceipt) void {
        if (self.loadState(.acquire) != .initializing or receipt.pid != self.owner_pid or
            receipt.process_nonce != self.owner_nonce or receipt.incarnation != self.incarnation or
            receipt.token == 0 or receipt.token != self.receipt_token)
            fatalInvalidReceipt();
        self.receipt_token = 0;
        self.state.store(@intFromEnum(State.ready), .release);
    }

    fn validateReady(self: *const Service, pid: u32, process_nonce: u64) ReadyError!void {
        // This PID check intentionally precedes every inherited secret or lock access.
        if (pid == 0 or process_nonce == 0 or currentProcessId() != pid)
            return error.ProcessDomainMismatch;
        switch (self.loadState(.acquire)) {
            .uninitialized, .initializing => return error.NotReady,
            .terminal => return error.Terminal,
            .ready => {},
        }
        if (self.owner_pid != pid or self.owner_nonce != process_nonce)
            return error.ProcessDomainMismatch;
    }

    fn capabilityRegistryKey(
        self: *const Service,
        pid: u32,
        process_nonce: u64,
        input: CapabilityKeyInput,
    ) ReadyError!u64 {
        try self.validateReady(pid, process_nonce);
        var hasher = std.crypto.hash.Blake3.init(.{ .key = self.secret });
        hasher.update(capability_domain);
        var transcript: [18]u8 = undefined;
        std.mem.writeInt(u64, transcript[0..8], input.counter, .little);
        std.mem.writeInt(u16, transcript[8..10], input.slot_index, .little);
        std.mem.writeInt(u64, transcript[10..18], input.slot_generation, .little);
        hasher.update(&transcript);
        var digest: [32]u8 = undefined;
        hasher.final(&digest);
        const key = std.mem.readInt(u64, digest[0..8], .little);
        if (key == 0) fatalInvalidReceipt();
        return key;
    }
};

var process_service: Service = .{};

pub fn currentProcessId() u32 {
    return process_identity.currentProcessId();
}

pub fn generateProcessNonce() PrepareError!u64 {
    var bytes: [8]u8 = undefined;
    try Service.secureEntropy(&bytes);
    const nonce = std.mem.readInt(u64, &bytes, .little);
    if (nonce == 0) return error.ZeroKey;
    return nonce;
}

pub fn prepare(pid: u32, process_nonce: u64) PrepareError!PreparedReceipt {
    return process_service.prepareWithEntropy(pid, process_nonce, .production);
}

pub fn commitReady(receipt: PreparedReceipt) void {
    process_service.commitReady(receipt);
}

pub fn validateReady(pid: u32, process_nonce: u64) ReadyError!void {
    return process_service.validateReady(pid, process_nonce);
}

pub fn capabilityRegistryKey(
    pid: u32,
    process_nonce: u64,
    input: CapabilityKeyInput,
) ReadyError!u64 {
    return process_service.capabilityRegistryKey(pid, process_nonce, input);
}

test "C3-3b2a process seal publishes ready last and derives domain key" {
    var service: Service = .{};
    const pid = currentProcessId();
    const receipt = try service.prepareWithEntropy(pid, 71, .production);
    try std.testing.expectError(error.NotReady, service.validateReady(pid, 71));
    service.commitReady(receipt);
    try service.validateReady(pid, 71);
    const first = try service.capabilityRegistryKey(pid, 71, .{
        .counter = 1,
        .slot_index = 2,
        .slot_generation = 3,
    });
    const replay = try service.capabilityRegistryKey(pid, 71, .{
        .counter = 1,
        .slot_index = 2,
        .slot_generation = 3,
    });
    try std.testing.expect(first != 0);
    try std.testing.expectEqual(first, replay);
    try std.testing.expectError(error.ProcessDomainMismatch, service.validateReady(pid, 72));
}

test "C3-3b2a process seal zero and entropy failure become terminal" {
    const pid = currentProcessId();
    var zero_service: Service = .{};
    try std.testing.expectError(error.ZeroKey, zero_service.prepareWithEntropy(pid, 81, .zero));
    try std.testing.expectError(error.Terminal, zero_service.prepareWithEntropy(pid, 81, .production));
    try std.testing.expectError(error.Terminal, zero_service.validateReady(pid, 81));

    var unavailable_service: Service = .{};
    try std.testing.expectError(
        error.EntropyUnavailable,
        unavailable_service.prepareWithEntropy(pid, 82, .unavailable),
    );
    try std.testing.expectError(error.Terminal, unavailable_service.validateReady(pid, 82));
}

test "C3-3b2a process seal deterministic seed rejects zero input and output" {
    const pid = currentProcessId();
    var zero_input: Service = .{};
    try std.testing.expectError(
        error.ZeroKey,
        zero_input.prepareWithEntropy(pid, 83, .{ .scalar_seed = 0 }),
    );
    try std.testing.expectError(error.Terminal, zero_input.validateReady(pid, 83));

    var zero_output: Service = .{};
    try std.testing.expectError(
        error.ZeroKey,
        zero_output.prepareWithEntropy(pid, 84, .{ .scalar_seed_zero_output = 1 }),
    );
    try std.testing.expectError(error.Terminal, zero_output.validateReady(pid, 84));

    var first: Service = .{};
    var second: Service = .{};
    const first_receipt = try first.prepareWithEntropy(pid, 85, .{ .scalar_seed = 9 });
    const second_receipt = try second.prepareWithEntropy(pid, 85, .{ .scalar_seed = 9 });
    first.commitReady(first_receipt);
    second.commitReady(second_receipt);
    const input: CapabilityKeyInput = .{ .counter = 1, .slot_index = 1, .slot_generation = 1 };
    try std.testing.expectEqual(
        try first.capabilityRegistryKey(pid, 85, input),
        try second.capabilityRegistryKey(pid, 85, input),
    );
}

test "C3-3b2a process seal concurrent first prepare has one unpublished winner" {
    const Context = struct {
        service: Service = .{},
        pid: u32,
        receipt: PreparedReceipt = .{},
        winners: std.atomic.Value(u8) = .init(0),

        fn run(self: *@This()) void {
            const receipt = self.service.prepareWithEntropy(
                self.pid,
                86,
                .{ .scalar_seed = 11 },
            ) catch return;
            self.receipt = receipt;
            _ = self.winners.fetchAdd(1, .acq_rel);
        }
    };
    var context: Context = .{ .pid = currentProcessId() };
    var threads: [8]std.Thread = undefined;
    for (&threads) |*thread| thread.* = try std.Thread.spawn(.{}, Context.run, .{&context});
    for (&threads) |thread| thread.join();
    try std.testing.expectEqual(@as(u8, 1), context.winners.load(.acquire));
    try std.testing.expectError(error.NotReady, context.service.validateReady(context.pid, 86));
    context.service.commitReady(context.receipt);
    try context.service.validateReady(context.pid, 86);
}

test "C3-3b2a process seal publication pause exposes only not ready" {
    const Context = struct {
        service: Service = .{},
        hook: PauseHook = .{},
        receipt: PreparedReceipt = .{},
        failed: std.atomic.Value(bool) = .init(false),

        fn run(self: *@This()) void {
            self.receipt = self.service.prepareWithEntropy(
                currentProcessId(),
                87,
                .{ .scalar_seed = 13 },
            ) catch {
                self.failed.store(true, .release);
                return;
            };
        }
    };
    var context: Context = .{};
    context.service.pause_hook = &context.hook;
    const thread = try std.Thread.spawn(.{}, Context.run, .{&context});
    while (!context.hook.reached.load(.acquire)) std.atomic.spinLoopHint();
    try std.testing.expectError(
        error.NotReady,
        context.service.validateReady(currentProcessId(), 87),
    );
    context.hook.proceed.store(true, .release);
    thread.join();
    try std.testing.expect(!context.failed.load(.acquire));
    context.service.commitReady(context.receipt);
    try context.service.validateReady(currentProcessId(), 87);
}

test "C3-3b2a process seal rejects process domain before secret use" {
    var service: Service = .{};
    const pid = currentProcessId();
    try std.testing.expectError(
        error.ProcessDomainMismatch,
        service.prepareWithEntropy(if (pid == std.math.maxInt(u32)) pid - 1 else pid + 1, 91, .production),
    );
    try std.testing.expectEqual(State.uninitialized, service.loadState(.acquire));
}

test "C3-3b2a process seal invalid receipt and replay use fixed fatal exit" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var case_id: u8 = 0;
    while (case_id < 5) : (case_id += 1) {
        const child = std.c.fork();
        if (child < 0) return error.TestUnexpectedResult;
        if (child == 0) {
            var service: Service = .{};
            const receipt = service.prepareWithEntropy(
                currentProcessId(),
                101,
                .{ .scalar_seed = 19 },
            ) catch std.c._exit(125);
            if (case_id == 4) {
                service.commitReady(receipt);
                service.commitReady(receipt);
            }
            var invalid = receipt;
            switch (case_id) {
                0 => invalid.pid +%= 1,
                1 => invalid.process_nonce +%= 1,
                2 => invalid.incarnation +%= 1,
                3 => invalid.token +%= 1,
                else => unreachable,
            }
            service.commitReady(invalid);
            std.c._exit(124);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        const unsigned_status: u32 = @bitCast(status);
        try std.testing.expect(std.c.W.IFEXITED(unsigned_status));
        try std.testing.expectEqual(@as(u8, 70), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned_status))));
    }
}

test "C3-3b2a process seal fork child rejects inherited ready state before key" {
    if (builtin.os.tag != .macos and builtin.os.tag != .linux) return error.SkipZigTest;
    var service: Service = .{};
    const pid = currentProcessId();
    const receipt = try service.prepareWithEntropy(pid, 102, .{ .scalar_seed = 23 });
    service.commitReady(receipt);
    const child = std.c.fork();
    if (child < 0) return error.TestUnexpectedResult;
    if (child == 0) {
        service.validateReady(currentProcessId(), 102) catch |err| switch (err) {
            error.ProcessDomainMismatch => std.c._exit(0),
            else => std.c._exit(123),
        };
        std.c._exit(122);
    }
    var status: c_int = 0;
    try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
    const unsigned_status: u32 = @bitCast(status);
    try std.testing.expect(std.c.W.IFEXITED(unsigned_status));
    try std.testing.expectEqual(@as(u8, 0), @as(u8, @intCast(std.c.W.EXITSTATUS(unsigned_status))));
}
