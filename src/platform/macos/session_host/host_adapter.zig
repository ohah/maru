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
const generation_batch_adapter = @import("generation_batch_adapter.zig");
const generation_contract = @import("generation_attachment_contract.zig");
const connection_lease = @import("connection_lease.zig");
const host_manifest = @import("host_manifest.zig");

pub const Kind = enum {
    current,
    previous,
};

pub const HostAdapter = struct {
    slot: client_slot_mod.ClientSlot,
    kind: Kind,
    shutdown_manifest: ShutdownManifest = .{},

    pub const ShutdownManifest = struct {
        host_id: u128 = 0,
        build_id: [host_manifest.max_build_id_bytes]u8 = [_]u8{0} ** host_manifest.max_build_id_bytes,
        build_id_len: u8 = 0,
        protocol_major: u16 = 0,
        screen_codec_version: u16 = 0,
        upgrade_epoch: u64 = 0,
        lifecycle: host_manifest.Lifecycle = .ready,
        endpoint: [host_manifest.max_endpoint_bytes]u8 = [_]u8{0} ** host_manifest.max_endpoint_bytes,
        endpoint_len: u8 = 0,

        pub fn descriptor(self: *const ShutdownManifest) ?host_manifest.Descriptor {
            if (self.host_id == 0 or self.build_id_len == 0 or self.endpoint_len == 0) return null;
            return .{
                .host_id = self.host_id,
                .build_id = self.build_id[0..self.build_id_len],
                .protocol_major = self.protocol_major,
                .screen_codec_version = self.screen_codec_version,
                .upgrade_epoch = self.upgrade_epoch,
                .lifecycle = self.lifecycle,
                .endpoint = self.endpoint[0..self.endpoint_len],
            };
        }
    };

    pub const InitError = client_slot_mod.InitError || error{UnsupportedProtocol};

    pub const testing = if (@import("builtin").is_test) struct {
        /// 제품 facade가 닫힌 operation으로 전환된 뒤에도 기존 failure fixture가 Client 상태를 주입할 때만 쓴다.
        pub fn rawClient(adapter: *HostAdapter) *client_mod.Client {
            return adapter.slot.logicalClient();
        }
    } else struct {};

    pub fn initializeProcessRuntime() client_slot_mod.ClientSlot.ProcessRuntimeInitError!void {
        try client_slot_mod.ClientSlot.initializeProcessRuntime();
    }

    pub fn connectionGeneration(self: *const HostAdapter) u64 {
        return self.slot.connectionGeneration();
    }

    /// reconnect 준비는 Client를 꺼내지 않고 exact current generation의 신규 admission만 봉인한다.
    pub fn prepareAdmissionClose(
        self: *HostAdapter,
        expected_generation: u64,
        out: *client_slot_mod.PreparedAdmissionClose,
    ) client_slot_mod.ClientSlot.AdmissionCloseError!void {
        return self.slot.prepareAdmissionClose(expected_generation, out);
    }

    /// 준비된 권위만 신규 호출을 닫을 수 있으며 current pointer와 Client bytes는 이 단계에서 바꾸지 않는다.
    pub fn commitAdmissionClose(
        self: *HostAdapter,
        permit: *client_slot_mod.PreparedAdmissionClose,
    ) client_slot_mod.ClientSlot.AdmissionCloseError!void {
        return self.slot.commitAdmissionClose(permit);
    }

    /// R2 publication 전 실패만 같은 generation을 다시 열며 permit replay는 허용하지 않는다.
    pub fn cancelAdmissionClose(
        self: *HostAdapter,
        permit: *client_slot_mod.PreparedAdmissionClose,
    ) client_slot_mod.ClientSlot.AdmissionCloseError!void {
        return self.slot.cancelAdmissionClose(permit);
    }

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
        out.shutdown_manifest = .{};
    }

    /// GUI hello만으로는 endpoint provenance를 복원할 수 없으므로 discovery가 검증한 exact manifest를 adapter의
    /// 고정 길이 저장소에 복사한다. 종료 attempt는 이후 disk discovery를 반복하지 않고 이 snapshot만 소비한다.
    pub fn bindShutdownManifest(self: *HostAdapter, descriptor: host_manifest.Descriptor) error{InvalidManifest}!void {
        if (descriptor.host_id != self.hostId() or descriptor.protocol_major != self.wireMajor() or
            descriptor.build_id.len == 0 or descriptor.build_id.len > host_manifest.max_build_id_bytes or
            descriptor.endpoint.len == 0 or descriptor.endpoint.len > host_manifest.max_endpoint_bytes)
            return error.InvalidManifest;
        var snapshot: ShutdownManifest = .{
            .host_id = descriptor.host_id,
            .build_id_len = @intCast(descriptor.build_id.len),
            .protocol_major = descriptor.protocol_major,
            .screen_codec_version = descriptor.screen_codec_version,
            .upgrade_epoch = descriptor.upgrade_epoch,
            .lifecycle = descriptor.lifecycle,
            .endpoint_len = @intCast(descriptor.endpoint.len),
        };
        @memcpy(snapshot.build_id[0..descriptor.build_id.len], descriptor.build_id);
        @memcpy(snapshot.endpoint[0..descriptor.endpoint.len], descriptor.endpoint);
        self.shutdown_manifest = snapshot;
    }

    pub fn shutdownManifest(self: *const HostAdapter) ?host_manifest.Descriptor {
        if (!self.slot.valid()) @panic("copied HostAdapter shutdown manifest access");
        return self.shutdown_manifest.descriptor();
    }

    pub fn deinit(self: *HostAdapter) void {
        const outcome = self.slot.tryDeinit();
        const final_outcome = if (outcome == .terminal_handoff)
            self.slot.tryDeinitWithTerminalCleanup()
        else
            outcome;
        if (final_outcome != .cleaned)
            @panic("session-host HostAdapter teardown invariant violated");
        self.shutdown_manifest = .{};
        self.kind = undefined;
    }

    pub fn hostId(self: *const HostAdapter) u128 {
        return self.slot.logicalClientConst().host_id;
    }

    pub fn wireMajor(self: *const HostAdapter) u16 {
        return self.slot.logicalClientConst().wire_major;
    }

    /// runtime attach decode도 generation transport와 같은 pointer-free capability projection을 사용한다.
    pub fn generationCapabilities(self: *const HostAdapter) generation_contract.GenerationCapabilities {
        const client = self.slot.logicalClientConst();
        const profile = client.compatibility_profile orelse
            @panic("generation adapter lost its compatibility profile");
        return .{
            .wire_major = client.wire_major,
            .screen_codec_version = client.screen_codec_version,
            .attach_schema = switch (profile.attach_schema) {
                .frozen_controller_only => .frozen_controller_only,
                .granted_roles => .granted_roles,
            },
            .metadata_support = switch (client.metadata_support) {
                .unsupported => .unsupported,
                .supported => .supported,
            },
            .peer_attach_generation = client.attachment_capabilities.peer_attach_generation,
            .screen_viewport_scrolled = client.screen_viewport_scrolled_v1,
            .async_scroll_to_bottom = client.async_scroll_to_bottom_v1,
            .notification_stream_auth = client.notification_stream_auth_v1,
            .runtime_clipboard = client.runtime_clipboard_v1,
            .runtime_core_command = client.runtime_core_command_v1,
            .runtime_link_at = client.runtime_link_at_v1,
            .runtime_selected_text = client.runtime_selected_text_v1,
        };
    }

    pub fn supportsRuntimeInventory(self: *const HostAdapter) bool {
        return self.slot.logicalClientConst().runtime_inventory_v1;
    }

    /// host.info/runtime.list/host.upgrade.*처럼 screen codec과 독립된 control RPC.
    pub fn call(self: *HostAdapter, method: []const u8, params_json: ?[]const u8) client_mod.ClientError![]u8 {
        return self.slot.callCurrent(self.slot.connectionGeneration(), method, params_json);
    }

    /// generation runtime 생성은 고정된 wire method만 노출해 호출자가 raw Client를 빌리지 않게 한다.
    pub fn spawnRuntime(self: *HostAdapter, params_json: []const u8) client_mod.ClientError![]u8 {
        return self.slot.callCurrent(self.slot.connectionGeneration(), "runtime.spawn_full", params_json);
    }

    /// generation RPC가 새 request를 쓰기 전에 현재 readable RX를 canonical queue로 옮긴다.
    pub fn ingestRuntimeReadableEvidence(self: *HostAdapter) client_mod.ClientError!void {
        return self.slot.ingestCurrentReadableEvidence(self.slot.connectionGeneration());
    }

    pub fn canTerminalizeSharedConnectionNoDestroy(self: *HostAdapter) bool {
        return self.slot.currentCanTerminalizeNoDestroy(self.slot.connectionGeneration());
    }

    pub fn terminalizeSharedConnectionNoDestroy(self: *HostAdapter) bool {
        return self.slot.terminalizeCurrentNoDestroy(self.slot.connectionGeneration());
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

    pub fn mintGenerationBatchAdapter(
        self: *HostAdapter,
        out: *generation_batch_adapter.GenerationBatchAdapter,
        owner_addr: usize,
        owner_size: usize,
        stream_id: u64,
    ) generation_batch_adapter.Error!void {
        return generation_batch_adapter.GenerationBatchAdapter.initPreparedInPlace(
            out,
            &self.slot,
            owner_addr,
            owner_size,
            stream_id,
        );
    }

    /// attach wire 전에 batch storage를 final-address로 예약한다. stream 결속은 accepted response 뒤 별도 suffix가 한다.
    pub fn reserveGenerationBatchAdapter(
        self: *HostAdapter,
        out: *generation_batch_adapter.GenerationBatchAdapter,
        owner_addr: usize,
        owner_size: usize,
    ) generation_batch_adapter.Error!void {
        return generation_batch_adapter.GenerationBatchAdapter.initReservedInPlace(
            out,
            &self.slot,
            owner_addr,
            owner_size,
        );
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
    const expected_fields = [_][]const u8{ "slot", "kind", "shutdown_manifest" };
    const fields = @typeInfo(HostAdapter).@"struct".fields;
    if (fields.len != expected_fields.len)
        @compileError("HostAdapter ownership inventory changed; update CR3a SSOT first");
    for (fields, expected_fields) |field, expected|
        if (!std.mem.eql(u8, field.name, expected))
            @compileError("HostAdapter raw Client owner or unreviewed field escaped the CR3a slot");
}

test "host adapter classifies current and N-1 without exposing N-1 as a current screen client" {
    try HostAdapter.initializeProcessRuntime();
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
    try std.testing.expect(HostAdapter.testing.rawClient(&current) == current.slot.logicalClientConst());

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
    try std.testing.expect(HostAdapter.testing.rawClient(&previous) == previous.slot.logicalClientConst());
}

test "host adapter validation failure preserves Client ownership and destination publication" {
    try HostAdapter.initializeProcessRuntime();
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
    try HostAdapter.initializeProcessRuntime();
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
    try HostAdapter.initializeProcessRuntime();
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

    const Entry = enum { host_id, wire_major, inventory, shutdown_manifest, logical_client, call, deinit };
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
                .shutdown_manifest => _ = local.shutdownManifest(),
                .logical_client => _ = HostAdapter.testing.rawClient(&local),
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

test "CR3b R1 HostAdapter admission close는 호출을 막고 cancel 뒤 같은 generation을 다시 연다" {
    try HostAdapter.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC3B106,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: HostAdapter = undefined;
    try HostAdapter.initInPlace(&adapter, allocator, &source);
    defer adapter.deinit();

    const generation = adapter.connectionGeneration();
    var permit: client_slot_mod.PreparedAdmissionClose = .{};
    try adapter.prepareAdmissionClose(generation, &permit);
    try adapter.commitAdmissionClose(&permit);
    try std.testing.expectError(error.AdminBusy, adapter.call("host.info", null));
    try adapter.cancelAdmissionClose(&permit);
    // fd=-1 fixture가 wire 진입까지 갔다는 WriteFailed가 admission 재개 증거다.
    try std.testing.expectError(error.WriteFailed, adapter.call("host.info", null));
}

test "C3-3b6 HostAdapter는 종료 manifest를 고정 길이 값으로 복사해 원본 수명과 분리한다" {
    try HostAdapter.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC3B6,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: HostAdapter = undefined;
    try HostAdapter.initInPlace(&adapter, allocator, &source);
    defer adapter.deinit();
    var endpoint = "/tmp/maru-c3b6.sock".*;
    var build_id = "sha256:c3b6".*;
    try adapter.bindShutdownManifest(.{
        .host_id = 0xC3B6,
        .build_id = &build_id,
        .protocol_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .upgrade_epoch = 7,
        .lifecycle = .ready,
        .endpoint = &endpoint,
    });
    @memset(&endpoint, 'x');
    @memset(&build_id, 'y');
    const bound = adapter.shutdownManifest() orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("/tmp/maru-c3b6.sock", bound.endpoint);
    try std.testing.expectEqualStrings("sha256:c3b6", bound.build_id);
    try std.testing.expectEqual(@as(u64, 7), bound.upgrade_epoch);
}

test "C3-3b6 HostAdapter는 다른 host manifest를 종료 target으로 결속하지 않는다" {
    try HostAdapter.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC3B6,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: HostAdapter = undefined;
    try HostAdapter.initInPlace(&adapter, allocator, &source);
    defer adapter.deinit();
    try std.testing.expectError(error.InvalidManifest, adapter.bindShutdownManifest(.{
        .host_id = 0xBAD,
        .build_id = "sha256:bad",
        .protocol_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .upgrade_epoch = 1,
        .lifecycle = .ready,
        .endpoint = "/tmp/bad.sock",
    }));
    try std.testing.expect(adapter.shutdownManifest() == null);
}
