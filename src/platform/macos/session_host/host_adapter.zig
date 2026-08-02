//! Current/N-1 MRSH connection의 typed ownership boundary.
//!
//! Adapter가 wire major와 exact screen codec을 1급 값으로 소유하고 HostPool/GUI에는 current DTO만 노출한다.
//! capability-tagged MRSH v1 frozen release는 current record body와 같고 screen header version만 1이므로 명시적으로
//! normalize한다. capability 없는 과거 v1 artifact나 MRSH/screen version 교차는 지원하지 않는다.

const std = @import("std");
const client_mod = @import("client.zig");
const protocol = @import("protocol.zig");
const screen_stream = @import("screen_stream.zig");
const compatibility = @import("compatibility.zig");
const client_slot_mod = @import("client_slot.zig");
const generation_transport = @import("generation_transport.zig");
const generation_contract = @import("generation_attachment_contract.zig");
const connection_lease = @import("connection_lease.zig");

pub const Kind = enum {
    current,
    previous,
};

pub const HostAdapter = struct {
    slot: client_slot_mod.ClientSlot,
    kind: Kind,

    pub const InitError = client_slot_mod.InitError || error{UnsupportedProtocol};

    pub fn initInPlace(
        out: *HostAdapter,
        node_allocator: std.mem.Allocator,
        source: *client_mod.Client,
    ) InitError!void {
        const out_start = @intFromPtr(out);
        const source_start = @intFromPtr(source);
        const out_end = std.math.add(usize, out_start, @sizeOf(HostAdapter)) catch
            return error.InvalidDestination;
        const source_end = std.math.add(usize, source_start, @sizeOf(client_mod.Client)) catch
            return error.InvalidDestination;
        if (out_start < source_end and source_start < out_end)
            return error.InvalidDestination;
        const profile = compatibility.profileForMajor(source.wire_major) orelse return error.UnsupportedProtocol;
        const kind: Kind = switch (profile.kind) {
            .current => .current,
            .previous => .previous,
        };
        if (source.screen_codec_version != profile.screen_codec_version) return error.UnsupportedProtocol;
        try client_slot_mod.ClientSlot.initInPlace(
            &out.slot,
            node_allocator,
            source,
            source.host_id,
        );
        out.kind = kind;
    }

    pub fn deinit(self: *HostAdapter) void {
        self.slot.deinit();
        self.kind = undefined;
    }

    pub fn hostId(self: *const HostAdapter) u128 {
        return self.slot.logicalClientConst().host_id;
    }

    pub fn wireMajor(self: *const HostAdapter) u16 {
        return self.slot.logicalClientConst().wire_major;
    }

    pub fn supportsRuntimeInventory(self: *const HostAdapter) bool {
        return self.slot.logicalClientConst().runtime_inventory_v1;
    }

    /// host.info/runtime.list/host.upgrade.*처럼 screen codec과 독립된 control RPC.
    pub fn call(self: *HostAdapter, method: []const u8, params_json: ?[]const u8) client_mod.ClientError![]u8 {
        return self.slot.logicalClient().call(method, params_json);
    }

    /// Client 내부의 selected wire major와 bounded screen reader가 current logical DTO로 normalize한다.
    pub fn logicalClient(self: *HostAdapter) *client_mod.Client {
        return self.slot.logicalClient();
    }

    pub fn mintGenerationTransport(
        self: *HostAdapter,
        out: *generation_transport.GenerationTransport,
        owner_addr: usize,
        owner_size: usize,
        reservation: client_slot_mod.AttachmentBindingReservation,
    ) (generation_transport.Error || client_slot_mod.BindingError)!void {
        return generation_transport.mintInPlace(out, &self.slot, owner_addr, owner_size, reservation);
    }

    pub fn responseOwnerSeal(
        self: *HostAdapter,
        reservation: client_slot_mod.AttachmentBindingReservation,
    ) client_slot_mod.BindingError!*generation_contract.ExecutedResponseOwnerSeal {
        return self.slot.responseOwnerSeal(reservation);
    }

    pub fn reserveAttachmentBinding(
        self: *HostAdapter,
        binding_out: *generation_contract.PreparedAttachmentBinding,
        lease_out: *connection_lease.ConnectionLease,
        runtime_id: u128,
        role: generation_contract.AttachmentRole,
    ) client_slot_mod.BindingError!client_slot_mod.AttachmentBindingReservation {
        return self.slot.reserveAttachmentBinding(
            binding_out,
            lease_out,
            runtime_id,
            role,
        );
    }

    pub fn abortAttachmentBinding(
        self: *HostAdapter,
        binding: *generation_contract.PreparedAttachmentBinding,
        reservation: client_slot_mod.AttachmentBindingReservation,
    ) client_slot_mod.BindingError!void {
        return self.slot.abortAttachmentBinding(binding, reservation);
    }

    pub fn abortExecutedAttachmentBinding(
        self: *HostAdapter,
        binding: *generation_contract.PreparedAttachmentBinding,
        reservation: client_slot_mod.AttachmentBindingReservation,
        executed: generation_contract.ExecutedCallReceipt,
    ) client_slot_mod.BindingError!void {
        return self.slot.abortExecutedAttachmentBinding(binding, reservation, executed);
    }

    pub fn commitAttachmentBinding(
        self: *HostAdapter,
        binding: *generation_contract.PreparedAttachmentBinding,
        reservation: client_slot_mod.AttachmentBindingReservation,
        accepted: generation_contract.CorrelatedExecutedCall,
        stream_id: u64,
        lease_out: *connection_lease.ConnectionLease,
    ) client_slot_mod.BindingError!void {
        return self.slot.commitAttachmentBinding(
            binding,
            reservation,
            accepted,
            stream_id,
            lease_out,
        );
    }

    pub fn beginAttachmentDrop(
        self: *HostAdapter,
        binding: *generation_contract.PreparedAttachmentBinding,
        reservation: client_slot_mod.AttachmentBindingReservation,
        lease: *connection_lease.ConnectionLease,
    ) client_slot_mod.BindingError!void {
        return self.slot.beginAttachmentDrop(binding, reservation, lease);
    }

    pub fn finishActiveAttachmentDrop(
        self: *HostAdapter,
        binding: *generation_contract.PreparedAttachmentBinding,
        reservation: client_slot_mod.AttachmentBindingReservation,
        lease: *connection_lease.ConnectionLease,
    ) void {
        return self.slot.finishActiveAttachmentDrop(binding, reservation, lease);
    }
};

comptime {
    const expected_fields = [_][]const u8{ "slot", "kind" };
    const fields = @typeInfo(HostAdapter).@"struct".fields;
    if (fields.len != expected_fields.len)
        @compileError("HostAdapter ownership inventory changed; update CR3a SSOT first");
    for (fields, expected_fields) |field, expected|
        if (!std.mem.eql(u8, field.name, expected))
            @compileError("HostAdapter raw Client owner or unreviewed field escaped the CR3a slot");
}

test "host adapter classifies current and N-1 without exposing N-1 as a current screen client" {
    const allocator = std.testing.allocator;
    var current_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xAA,
        .wire_major = protocol.version_major,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var current: HostAdapter = undefined;
    try HostAdapter.initInPlace(&current, allocator, &current_client);
    defer current.deinit();
    try std.testing.expectEqual(Kind.current, current.kind);
    try std.testing.expectEqual(@as(u128, 0xAA), current.hostId());
    try std.testing.expect(current.logicalClient() == current.slot.logicalClientConst());

    var previous_client: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xBB,
        .wire_major = protocol.version_major - 1,
        .screen_codec_version = screen_stream.codec_version - 1,
        .parser = @import("framing.zig").FrameParser.initForMajor(
            allocator,
            protocol.version_major - 1,
        ),
    };
    var previous: HostAdapter = undefined;
    try HostAdapter.initInPlace(&previous, allocator, &previous_client);
    defer previous.deinit();
    try std.testing.expectEqual(Kind.previous, previous.kind);
    try std.testing.expectEqual(protocol.version_major - 1, previous.wireMajor());
    try std.testing.expect(previous.logicalClient() == previous.slot.logicalClientConst());
}

test "host adapter validation failure preserves Client ownership and destination publication" {
    const allocator = std.testing.allocator;
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xDD,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version + 1,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    defer source.deinit();
    var out_bytes: [@sizeOf(HostAdapter)]u8 align(@alignOf(HostAdapter)) = [_]u8{0xA5} ** @sizeOf(HostAdapter);
    const before = out_bytes;
    const out: *HostAdapter = @ptrCast(&out_bytes);
    try std.testing.expectError(error.UnsupportedProtocol, HostAdapter.initInPlace(out, allocator, &source));
    try std.testing.expectEqualSlices(u8, &before, &out_bytes);
    try std.testing.expect(source.canMoveToGenerationNode());
}

test "copied host adapter rejects access before reading a freed generation node" {
    const allocator = std.testing.allocator;
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xEE,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var original: HostAdapter = undefined;
    try HostAdapter.initInPlace(&original, allocator, &source);
    const copied = original;
    original.deinit();
    // `valid` short-circuits on the copied slot's self-address before dereferencing `current`,
    // which now points at freed storage.
    try std.testing.expect(!copied.slot.valid());
}

test "all copied host adapter public entrypoints fail-stop before freed-node access" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xEF,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var original: HostAdapter = undefined;
    try HostAdapter.initInPlace(&original, allocator, &source);
    const copied = original;
    original.deinit();

    const Entry = enum { host_id, wire_major, inventory, logical_client, call, deinit };
    for (std.enums.values(Entry)) |entry| {
        const child = std.c.fork();
        try std.testing.expect(child >= 0);
        if (child == 0) {
            const devnull = std.c.open("/dev/null", .{ .ACCMODE = .WRONLY });
            if (devnull >= 0) {
                _ = std.c.dup2(devnull, 2);
                _ = std.c.close(devnull);
            }
            var local = copied;
            switch (entry) {
                .host_id => _ = local.hostId(),
                .wire_major => _ = local.wireMajor(),
                .inventory => _ = local.supportsRuntimeInventory(),
                .logical_client => _ = local.logicalClient(),
                .call => _ = local.call("host.info", null) catch {},
                .deinit => local.deinit(),
            }
            std.c._exit(0);
        }
        var status: c_int = 0;
        try std.testing.expectEqual(child, std.c.waitpid(child, &status, 0));
        // Darwin encodes the terminating signal in the low seven bits.  `@panic` terminates with
        // SIGABRT (6); pinning that signal distinguishes the intended fail-stop from a UAF SIGSEGV.
        try std.testing.expectEqual(@as(c_int, 6), status & 0x7f);
    }
}
