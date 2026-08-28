//! Current/N-1 MRSH connection의 typed ownership boundary.
//!
//! Adapter가 wire major와 exact screen codec을 1급 값으로 소유하고 HostPool/GUI에는 current DTO만 노출한다.
//! capability-tagged MRSH v1 frozen release는 current record body와 같고 screen header version만 1이므로 명시적으로
//! normalize한다. capability 없는 과거 v1 artifact나 MRSH/screen version 교차는 지원하지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const client_mod = @import("client.zig");
const client_deadline = @import("client_deadline.zig");
const protocol = @import("protocol.zig");
const screen_stream = @import("maru").session.screen_stream;
const compatibility = @import("compatibility.zig");
const client_slot_mod = @import("client_slot.zig");
const generation_transport = @import("generation_transport.zig");
const generation_batch_adapter = @import("generation_batch_adapter.zig");
const generation_contract = @import("generation_attachment_contract.zig");
const connection_lease = @import("connection_lease.zig");
const host_manifest = @import("host_manifest.zig");
const incident_binding_contract = @import("maru").observability.incident_binding_contract;
const incident_publication_contract = @import("maru").observability.incident_publication_contract;
const process_seal_service = @import("process_seal_service.zig");

pub const Kind = enum {
    current,
    previous,
};
pub const ManagedPoisonError = client_slot_mod.ManagedPoisonError;

pub const HostAdapter = struct {
    slot: client_slot_mod.ClientSlot,
    kind: Kind,
    shutdown_manifest: ShutdownManifest = .{},

    pub const testing_api = if (@import("builtin").is_test) struct {
        pub const DeinitTrace = struct {
            host_ids: [8]u128 = [_]u128{0} ** 8,
            len: usize = 0,
        };
        var armed: ?*DeinitTrace = null;

        pub fn arm(trace: *DeinitTrace) void {
            std.debug.assert(armed == null and trace.len == 0);
            armed = trace;
        }

        pub fn disarm() void {
            armed = null;
        }

        fn record(host_id: u128) void {
            const trace = armed orelse return;
            if (trace.len == trace.host_ids.len) @panic("HostAdapter deinit trace overflow");
            trace.host_ids[trace.len] = host_id;
            trace.len += 1;
        }
    } else struct {};

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

        pub fn publishReplacementForCr3c(
            adapter: *HostAdapter,
            cleanup: *const client_slot_mod.PreparedRetirementCleanup,
            source: *client_mod.Client,
            out: *client_slot_mod.PreparedClientReplacement,
        ) !void {
            try adapter.prepareClientReplacement(cleanup, source, out);
            var prepared = true;
            defer if (prepared) adapter.abortClientReplacement(out) catch
                @panic("CR3c test replacement abort failed");
            adapter.publishClientReplacementNoFail(out);
            prepared = false;
        }

        pub fn reclaimAllRetiredForCr3c(adapter: *HostAdapter) !void {
            while (adapter.slot.retiredClientCount() != 0) {
                var retired: client_slot_mod.PreparedRetiredClientReclaim = .{};
                try adapter.prepareRetiredClientReclaim(&retired);
                adapter.commitRetiredClientReclaimAtTickEndNoFail(&retired);
            }
        }
    } else struct {};

    pub fn initializeProcessRuntime() client_slot_mod.ClientSlot.ProcessRuntimeInitError!void {
        try client_slot_mod.ClientSlot.initializeProcessRuntime();
    }

    pub fn publicationProcessIdentity() ?client_slot_mod.PublicationProcessIdentity {
        return client_slot_mod.ClientSlot.publicationProcessIdentity();
    }

    pub fn connectionGeneration(self: *const HostAdapter) u64 {
        return self.slot.connectionGeneration();
    }

    pub const WakeSource = struct {
        fd: std.c.fd_t,
        host_id: u128,
        connection_generation: u64,
    };

    /// Borrowed descriptor identity for the AppKit run-loop read source. The source observes only
    /// readability and never closes the fd; ClientSlot remains the sole transport owner.
    pub fn wakeSource(self: *const HostAdapter) ?WakeSource {
        const client = self.slot.logicalClientConst();
        if (client.fd < 0 or client.io_mode != .blocking) return null;
        const generation = self.slot.connectionGeneration();
        if (client.host_id == 0 or generation == 0) return null;
        return .{
            .fd = client.fd,
            .host_id = client.host_id,
            .connection_generation = generation,
        };
    }

    /// The adapter owns the final ClientSlot address but never stores publisher/runtime pointers.
    pub fn prepareManagedPoisonRequest(
        self: *HostAdapter,
        timestamp_ns: i128,
        request: incident_publication_contract.ManagedPoisonRequest,
        out: *incident_publication_contract.PreparedManagedPoison,
    ) ManagedPoisonError!void {
        return client_slot_mod.prepareManagedPoisonRequest(&self.slot, timestamp_ns, request, out);
    }

    pub fn managedPoisonQuery(
        self: *HostAdapter,
        prepared: *const incident_publication_contract.PreparedManagedPoison,
    ) ManagedPoisonError!client_slot_mod.IncidentOperationQuery {
        return client_slot_mod.managedPoisonQuery(&self.slot, prepared);
    }

    pub fn consumeManagedPoison(
        self: *HostAdapter,
        prepared: *incident_publication_contract.PreparedManagedPoison,
    ) ManagedPoisonError!void {
        return client_slot_mod.consumeManagedPoison(&self.slot, prepared);
    }

    pub fn managedPoisonWillPublishFirst(
        self: *HostAdapter,
        prepared: *const incident_publication_contract.PreparedManagedPoison,
    ) ManagedPoisonError!bool {
        return client_slot_mod.managedPoisonWillPublishFirst(&self.slot, prepared);
    }

    pub fn terminalizeManagedPoisonNoFail(
        self: *HostAdapter,
        prepared: *const incident_publication_contract.PreparedManagedPoison,
        result: incident_publication_contract.IncidentCommitResult,
    ) ?std.c.fd_t {
        return client_slot_mod.terminalizeManagedPoisonNoFail(&self.slot, prepared, result);
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

    pub fn prepareRetirementCleanup(
        self: *HostAdapter,
        permit: *client_slot_mod.PreparedAdmissionClose,
        placeholder_generation: u64,
        out: *client_slot_mod.PreparedRetirementCleanup,
    ) client_slot_mod.ClientSlot.RetirementCleanupError!void {
        return self.slot.prepareRetirementCleanup(permit, placeholder_generation, out);
    }

    pub fn preflightRetirementCleanupBeforeAdmissionClose(
        self: *HostAdapter,
        permit: *const client_slot_mod.PreparedAdmissionClose,
        cleanup: *const client_slot_mod.PreparedRetirementCleanup,
        placeholder_generation: u64,
    ) client_slot_mod.ClientSlot.RetirementCleanupError!void {
        return self.slot.preflightRetirementCleanupBeforeAdmissionClose(
            permit,
            cleanup,
            placeholder_generation,
        );
    }

    pub fn preflightRetirementDetachBeforeAdmissionClose(
        self: *HostAdapter,
        permit: *const client_slot_mod.PreparedAdmissionClose,
        expected_connection_generation: u64,
        placeholder_generation: u64,
    ) client_slot_mod.ClientSlot.RetirementDetachError!void {
        return self.slot.preflightRetirementDetachBeforeAdmissionClose(
            permit,
            expected_connection_generation,
            placeholder_generation,
        );
    }

    pub fn preflightRetirementCleanup(
        self: *HostAdapter,
        permit: *client_slot_mod.PreparedAdmissionClose,
        cleanup: *client_slot_mod.PreparedRetirementCleanup,
        placeholder_generation: u64,
    ) client_slot_mod.ClientSlot.RetirementCleanupError!void {
        return self.slot.preflightRetirementCleanup(permit, cleanup, placeholder_generation);
    }

    pub fn preflightRetirementDetach(
        self: *HostAdapter,
        permit: *client_slot_mod.PreparedAdmissionClose,
        expected_connection_generation: u64,
        placeholder_generation: u64,
    ) client_slot_mod.ClientSlot.RetirementDetachError!void {
        return self.slot.preflightRetirementDetach(
            permit,
            expected_connection_generation,
            placeholder_generation,
        );
    }

    pub fn commitRetirementCleanupNoFail(
        self: *HostAdapter,
        permit: *client_slot_mod.PreparedAdmissionClose,
        cleanup: *client_slot_mod.PreparedRetirementCleanup,
        placeholder_generation: u64,
    ) void {
        self.slot.commitRetirementCleanupNoFail(permit, cleanup, placeholder_generation);
    }

    pub fn commitRetirementDetachNoFail(
        self: *HostAdapter,
        permit: *client_slot_mod.PreparedAdmissionClose,
        expected_connection_generation: u64,
        placeholder_generation: u64,
    ) void {
        self.slot.commitRetirementDetachNoFail(
            permit,
            expected_connection_generation,
            placeholder_generation,
        );
    }

    pub fn abortRetirementCleanup(
        self: *HostAdapter,
        cleanup: *client_slot_mod.PreparedRetirementCleanup,
    ) client_slot_mod.ClientSlot.RetirementCleanupError!void {
        return self.slot.abortRetirementCleanup(cleanup);
    }

    pub fn finishRetirementCleanup(
        self: *HostAdapter,
        cleanup: *client_slot_mod.PreparedRetirementCleanup,
    ) client_slot_mod.ClientSlot.RetirementCleanupError!void {
        return self.slot.finishRetirementCleanup(cleanup);
    }

    pub fn prepareClientReplacement(
        self: *HostAdapter,
        cleanup: *const client_slot_mod.PreparedRetirementCleanup,
        source: *client_mod.Client,
        out: *client_slot_mod.PreparedClientReplacement,
    ) client_slot_mod.ClientSlot.ClientReplacementError!void {
        const profile = compatibility.profileForMajor(source.wire_major) orelse
            return error.InvalidOwner;
        const kind: Kind = switch (profile.kind) {
            .current => .current,
            .previous => .previous,
        };
        if (kind != self.kind or source.screen_codec_version != profile.screen_codec_version)
            return error.InvalidOwner;
        return self.slot.prepareClientReplacement(cleanup, source, out);
    }

    pub fn reserveClientReplacementNode(
        self: *HostAdapter,
        cleanup: *const client_slot_mod.PreparedRetirementCleanup,
        source: *const client_mod.Client,
        out: *client_slot_mod.PreparedClientReplacement,
    ) client_slot_mod.ClientSlot.ClientReplacementError!void {
        const profile = compatibility.profileForMajor(source.wire_major) orelse
            return error.InvalidOwner;
        const kind: Kind = switch (profile.kind) {
            .current => .current,
            .previous => .previous,
        };
        if (kind != self.kind or source.screen_codec_version != profile.screen_codec_version)
            return error.InvalidOwner;
        return self.slot.reserveClientReplacementNode(cleanup, source, out);
    }

    pub fn preflightReservedClientReplacementNode(
        self: *HostAdapter,
        cleanup: *const client_slot_mod.PreparedRetirementCleanup,
        source: *const client_mod.Client,
        reserved: *const client_slot_mod.PreparedClientReplacement,
    ) client_slot_mod.ClientSlot.ClientReplacementError!void {
        return self.slot.preflightReservedClientReplacementNode(cleanup, source, reserved);
    }

    pub fn abortReservedClientReplacementNode(
        self: *HostAdapter,
        cleanup: *const client_slot_mod.PreparedRetirementCleanup,
        source: *const client_mod.Client,
        reserved: *client_slot_mod.PreparedClientReplacement,
    ) client_slot_mod.ClientSlot.ClientReplacementError!void {
        return self.slot.abortReservedClientReplacementNode(cleanup, source, reserved);
    }

    pub fn publishReservedClientReplacementAfterRetirementNoFail(
        self: *HostAdapter,
        cleanup: *const client_slot_mod.PreparedRetirementCleanup,
        source: *client_mod.Client,
        reserved: *client_slot_mod.PreparedClientReplacement,
    ) void {
        self.slot.publishReservedClientReplacementAfterRetirementNoFail(
            cleanup,
            source,
            reserved,
        );
    }

    pub fn abortClientReplacement(
        self: *HostAdapter,
        prepared: *client_slot_mod.PreparedClientReplacement,
    ) client_slot_mod.ClientSlot.ClientReplacementError!void {
        return self.slot.abortClientReplacement(prepared);
    }

    pub fn publishClientReplacementNoFail(
        self: *HostAdapter,
        prepared: *client_slot_mod.PreparedClientReplacement,
    ) void {
        self.slot.publishClientReplacementNoFail(prepared);
    }

    pub fn preflightClientReplacement(
        self: *HostAdapter,
        prepared: *const client_slot_mod.PreparedClientReplacement,
    ) client_slot_mod.ClientSlot.ClientReplacementError!void {
        return self.slot.preflightClientReplacement(prepared);
    }

    pub fn preflightPublishedClientReplacement(
        self: *HostAdapter,
        published: *const client_slot_mod.PreparedClientReplacement,
    ) client_slot_mod.ClientSlot.ClientReplacementError!void {
        return self.slot.preflightPublishedClientReplacement(published);
    }

    pub fn preflightAttachmentConnectionFailedClosed(
        self: *const HostAdapter,
        reason: @import("client_poison.zig").ConnectionReason,
    ) error{ MovedOrCopied, InvalidTerminalConnection }!void {
        return self.slot.preflightAttachmentConnectionFailedClosed(reason);
    }

    pub fn failCloseAttachmentConnection(
        self: *HostAdapter,
        reason: @import("client_poison.zig").ConnectionReason,
    ) error{ MovedOrCopied, InvalidTerminalConnection }!@import("client_poison.zig").ConnectionReason {
        return self.slot.failCloseAttachmentConnection(reason);
    }

    pub fn preflightAttachmentConnectionUsable(
        self: *const HostAdapter,
    ) error{ MovedOrCopied, InvalidUsableConnection }!void {
        return self.slot.preflightAttachmentConnectionUsable();
    }

    pub fn prepareRetiredClientReclaim(
        self: *HostAdapter,
        out: *client_slot_mod.PreparedRetiredClientReclaim,
    ) client_slot_mod.ClientSlot.RetiredClientReclaimError!void {
        return self.slot.prepareRetiredClientReclaim(out);
    }

    pub fn commitRetiredClientReclaimAtTickEndNoFail(
        self: *HostAdapter,
        prepared: *client_slot_mod.PreparedRetiredClientReclaim,
    ) void {
        self.slot.commitRetiredClientReclaimNoFail(prepared);
    }

    pub fn preflightRetiredClientReclaim(
        self: *HostAdapter,
        prepared: *const client_slot_mod.PreparedRetiredClientReclaim,
    ) client_slot_mod.ClientSlot.RetiredClientReclaimError!void {
        return self.slot.preflightRetiredClientReclaim(prepared);
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

    pub fn initManagedInPlace(
        out: *HostAdapter,
        node_allocator: std.mem.Allocator,
        source: *client_mod.Client,
        permit: *incident_binding_contract.PreparedHostPublication,
    ) InitError!void {
        if (!validPreparedHostPublication(permit, permit.pool_addr, @intFromPtr(out)) or
            permit.host_id != source.host_id)
            return error.InvalidDestination;
        const profile = compatibility.profileForMajor(source.wire_major) orelse return error.UnsupportedProtocol;
        const kind: Kind = switch (profile.kind) {
            .current => .current,
            .previous => .previous,
        };
        if (source.screen_codec_version != profile.screen_codec_version) return error.UnsupportedProtocol;
        var publication: incident_binding_contract.IncidentBindingPublication = .{};
        try client_slot_mod.ClientSlot.initManagedInPlace(
            &out.slot,
            node_allocator,
            source,
            permit.host_id,
            permit.adapter_generation,
            switch (kind) {
                .current => .current,
                .previous => .previous,
            },
            &publication,
        );
        out.kind = kind;
        out.shutdown_manifest = .{};
        if (!incident_binding_contract.validPublicationShape(publication))
            @panic("managed Client incident publication missing");
        permit.lifecycle_raw = @intFromEnum(incident_binding_contract.PublicationLifecycle.bound);
        permit.seal = process_seal_service.preparedHostPublicationSeal(permit.pid, permit.process_nonce, .{
            .self_addr = permit.self_addr,
            .pool_addr = permit.pool_addr,
            .host_id = permit.host_id,
            .adapter_addr = permit.adapter_addr,
            .adapter_generation = permit.adapter_generation,
            .owned_raw = permit.owned_raw,
            .lifecycle_raw = permit.lifecycle_raw,
        }) catch @panic("managed Client binding permit proof loss");
    }

    pub fn sealPreparedHostPublication(permit: *incident_binding_contract.PreparedHostPublication) !void {
        const client_slot_identity = client_slot_mod.ClientSlot.publicationProcessIdentity() orelse
            return error.ProcessSealUnavailable;
        const pid = client_slot_identity.pid;
        permit.pid = client_slot_identity.pid;
        permit.process_nonce = client_slot_identity.process_nonce;
        permit.lifecycle_raw = @intFromEnum(incident_binding_contract.PublicationLifecycle.prepared);
        permit.seal = try process_seal_service.preparedHostPublicationSeal(pid, permit.process_nonce, .{
            .self_addr = permit.self_addr,
            .pool_addr = permit.pool_addr,
            .host_id = permit.host_id,
            .adapter_addr = permit.adapter_addr,
            .adapter_generation = permit.adapter_generation,
            .owned_raw = permit.owned_raw,
            .lifecycle_raw = permit.lifecycle_raw,
        });
    }

    pub fn validPreparedHostPublication(
        permit: *const incident_binding_contract.PreparedHostPublication,
        pool_addr: usize,
        adapter_addr: usize,
    ) bool {
        if (!incident_binding_contract.validPreparedShape(permit.*, @intFromPtr(permit)) or
            permit.pool_addr != pool_addr or permit.adapter_addr != adapter_addr)
            return false;
        const expected = process_seal_service.preparedHostPublicationSeal(permit.pid, permit.process_nonce, .{
            .self_addr = permit.self_addr,
            .pool_addr = permit.pool_addr,
            .host_id = permit.host_id,
            .adapter_addr = permit.adapter_addr,
            .adapter_generation = permit.adapter_generation,
            .owned_raw = permit.owned_raw,
            .lifecycle_raw = permit.lifecycle_raw,
        }) catch return false;
        return std.mem.eql(u8, &expected, &permit.seal);
    }

    pub fn hostPublicationPrepared(permit: *const incident_binding_contract.PreparedHostPublication) bool {
        return permit.lifecycle_raw == @intFromEnum(incident_binding_contract.PublicationLifecycle.prepared);
    }

    pub fn hostPublicationBound(permit: *const incident_binding_contract.PreparedHostPublication) bool {
        return permit.lifecycle_raw == @intFromEnum(incident_binding_contract.PublicationLifecycle.bound);
    }

    pub fn incidentBindingPublication(self: *const HostAdapter) incident_binding_contract.IncidentBindingPublication {
        const binding = self.slot.logicalClientConst().incident_binding;
        if (!incident_binding_contract.validBindingShape(binding)) return .{};
        const expected = process_seal_service.incidentBindingSeal(self.slot.pid, self.slot.process_nonce, .{
            .client_addr = binding.client_addr,
            .host_id = binding.host_id,
            .host_adapter_generation = binding.host_adapter_generation,
            .connection_generation = binding.connection_generation,
            .wire_major = binding.wire_major,
            .host_class_raw = binding.host_class_raw,
        }) catch return .{};
        if (!std.mem.eql(u8, &expected, &binding.seal)) return .{};
        return .{ .client_addr = binding.client_addr, .binding_seal = binding.seal };
    }

    pub fn hostAdapterGeneration(self: *const HostAdapter) u64 {
        return self.slot.logicalClientConst().incident_binding.host_adapter_generation;
    }

    pub fn incidentBindingMatchesPermit(
        self: *const HostAdapter,
        permit: *const incident_binding_contract.PreparedHostPublication,
    ) bool {
        const client = self.slot.logicalClientConst();
        const binding = client.incident_binding;
        return binding.client_addr == @intFromPtr(client) and binding.host_id == permit.host_id and
            binding.host_adapter_generation == permit.adapter_generation and
            binding.connection_generation == self.slot.connectionGeneration() and
            binding.wire_major == client.wire_major and
            binding.host_class_raw == @intFromEnum(switch (self.kind) {
                .current => incident_binding_contract.HostClass.current,
                .previous => incident_binding_contract.HostClass.previous,
            }) and incident_binding_contract.validPublicationShape(self.incidentBindingPublication());
    }

    pub fn consumePreparedHostPublicationNoFail(permit: *incident_binding_contract.PreparedHostPublication) void {
        permit.lifecycle_raw = @intFromEnum(incident_binding_contract.PublicationLifecycle.consumed);
        permit.seal = process_seal_service.preparedHostPublicationSeal(permit.pid, permit.process_nonce, .{
            .self_addr = permit.self_addr,
            .pool_addr = permit.pool_addr,
            .host_id = permit.host_id,
            .adapter_addr = permit.adapter_addr,
            .adapter_generation = permit.adapter_generation,
            .owned_raw = permit.owned_raw,
            .lifecycle_raw = permit.lifecycle_raw,
        }) catch @panic("managed host publication consume proof loss");
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
        const host_id = self.hostId();
        const outcome = self.slot.tryDeinit();
        const final_outcome = if (outcome == .terminal_handoff)
            self.slot.tryDeinitWithTerminalCleanup()
        else
            outcome;
        if (final_outcome != .cleaned)
            @panic("session-host HostAdapter teardown invariant violated");
        if (@import("builtin").is_test) testing_api.record(host_id);
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
            .controller_transfer = client.attachment_capabilities.negotiated_controller_transfer,
            .screen_viewport_scrolled = client.screen_viewport_scrolled_v1,
            .async_scroll_to_bottom = client.async_scroll_to_bottom_v1,
            .notification_stream_auth = client.notification_stream_auth_v1,
            .notification_delivery = client.notification_delivery_v1,
            .runtime_clipboard = client.runtime_clipboard_v1,
            .runtime_core_command = client.runtime_core_command_v1,
            .runtime_link_at = client.runtime_link_at_v1,
            .runtime_selected_text = client.runtime_selected_text_v1,
            .runtime_selection_state = client.runtime_selection_state_v1,
        };
    }

    pub fn supportsRuntimeInventory(self: *const HostAdapter) bool {
        return self.slot.logicalClientConst().runtime_inventory_v1;
    }

    pub fn supportsClearScreen(self: *const HostAdapter) bool {
        return self.slot.logicalClientConst().runtime_clear_screen_v1;
    }

    /// host.info/runtime.list/host.upgrade.*처럼 screen codec과 독립된 control RPC.
    pub fn call(self: *HostAdapter, method: []const u8, params_json: ?[]const u8) client_mod.ClientError![]u8 {
        return self.slot.callCurrent(self.slot.connectionGeneration(), method, params_json);
    }

    /// UI recovery action의 fresh evidence RPC. Caller가 발급한 하나의 absolute deadline을 그대로
    /// ClientSlot까지 전달하며 이 facade 안에서 phase별 timeout을 다시 만들지 않는다.
    pub fn callUntil(
        self: *HostAdapter,
        method: []const u8,
        params_json: ?[]const u8,
        deadline: client_deadline.AbsoluteDeadline,
    ) client_mod.DeadlineClientError![]u8 {
        return self.slot.callCurrentUntil(self.slot.connectionGeneration(), method, params_json, deadline);
    }

    /// generation runtime 생성은 고정된 wire method만 노출해 호출자가 raw Client를 빌리지 않게 한다.
    pub fn spawnRuntime(self: *HostAdapter, params_json: []const u8) client_mod.ClientError![]u8 {
        return self.slot.callCurrent(self.slot.connectionGeneration(), "runtime.spawn_full", params_json);
    }

    /// generation RPC가 새 request를 쓰기 전에 현재 readable RX를 canonical queue로 옮긴다.
    pub fn ingestRuntimeReadableEvidence(self: *HostAdapter) client_mod.ClientError!void {
        return self.slot.ingestCurrentReadableEvidence(self.slot.connectionGeneration());
    }

    pub fn hasBufferedRuntimeWork(self: *HostAdapter, stream_id: u64) client_mod.ClientError!bool {
        return self.slot.currentHasBufferedRuntimeWork(self.slot.connectionGeneration(), stream_id);
    }

    pub fn hasAnyBufferedRuntimeWork(self: *HostAdapter) client_mod.ClientError!bool {
        return self.slot.currentHasAnyBufferedRuntimeWork(self.slot.connectionGeneration());
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

    pub fn preflightAttachmentDrop(
        self: *HostAdapter,
        binding: *generation_contract.PreparedAttachmentBinding,
        reservation: client_slot_mod.AttachmentBindingReservation,
        lease: *connection_lease.ConnectionLease,
    ) client_slot_mod.BindingError!void {
        return self.slot.preflightAttachmentDrop(binding, reservation, lease);
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

test "CR3b R2c HostAdapter facade는 incompatible replacement를 mutation 없이 거부한다" {
    try HostAdapter.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC3B2C3,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: HostAdapter = undefined;
    try HostAdapter.initInPlace(&adapter, allocator, &source);
    defer adapter.deinit();

    var admission: client_slot_mod.PreparedAdmissionClose = .{};
    var cleanup: client_slot_mod.PreparedRetirementCleanup = .{};
    try client_slot_mod.testing.prepareDetachedCleanupForReplacementForTest(
        &adapter.slot,
        &admission,
        &cleanup,
    );

    var incompatible: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC3B2C3,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version + 1,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    const incompatible_before = incompatible;
    const slot_before = adapter.slot;
    var rejected: client_slot_mod.PreparedClientReplacement = .{};
    try std.testing.expectError(
        error.InvalidOwner,
        adapter.prepareClientReplacement(&cleanup, &incompatible, &rejected),
    );
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&incompatible_before), std.mem.asBytes(&incompatible)));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&slot_before), std.mem.asBytes(&adapter.slot)));
    try std.testing.expectEqual(client_slot_mod.PreparedClientReplacement{}, rejected);

    var missing_fd: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC3B2C3,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    const missing_fd_before = missing_fd;
    const slot_before_missing_fd = adapter.slot;
    var missing_fd_rejected: client_slot_mod.PreparedClientReplacement = .{};
    try std.testing.expectError(
        error.InvalidOwner,
        adapter.prepareClientReplacement(&cleanup, &missing_fd, &missing_fd_rejected),
    );
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&missing_fd_before), std.mem.asBytes(&missing_fd)));
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&slot_before_missing_fd), std.mem.asBytes(&adapter.slot)));
    try std.testing.expectEqual(client_slot_mod.PreparedClientReplacement{}, missing_fd_rejected);

    var compatible_pair: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &compatible_pair),
    );
    defer _ = std.c.close(compatible_pair[1]);
    var compatible: client_mod.Client = .{
        .allocator = allocator,
        .fd = compatible_pair[0],
        .host_id = 0xC3B2C3,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var compatible_owns_fd = true;
    defer if (compatible_owns_fd) {
        _ = std.c.close(compatible_pair[0]);
    };
    var prepared: client_slot_mod.PreparedClientReplacement = .{};
    try adapter.prepareClientReplacement(&cleanup, &compatible, &prepared);
    compatible_owns_fd = false;
    var prepared_live = true;
    defer if (prepared_live) {
        adapter.abortClientReplacement(&prepared) catch
            @panic("CR3b R2c HostAdapter replacement fallback failed");
    };
    try adapter.abortClientReplacement(&prepared);
    prepared_live = false;
}

test "CR3b R3 HostAdapter facade는 tick-end에서 oldest retired Client를 회수한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    try HostAdapter.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    const host_id: u128 = 0xC3B3003;
    var initial_pair: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &initial_pair),
    );
    defer _ = std.c.close(initial_pair[1]);
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = initial_pair[0],
        .host_id = host_id,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var adapter: HostAdapter = undefined;
    try HostAdapter.initInPlace(&adapter, allocator, &source);
    var adapter_live = true;
    defer if (adapter_live) {
        while (adapter.slot.retiredClientCount() != 0) {
            var cleanup: client_slot_mod.PreparedRetiredClientReclaim = .{};
            adapter.prepareRetiredClientReclaim(&cleanup) catch
                @panic("CR3b R3 HostAdapter fixture reclaim failed");
            adapter.commitRetiredClientReclaimAtTickEndNoFail(&cleanup);
        }
        adapter.deinit();
    };

    var replacement_pair: [2]std.c.fd_t = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &replacement_pair),
    );
    defer _ = std.c.close(replacement_pair[1]);
    var replacement: client_mod.Client = .{
        .allocator = allocator,
        .fd = replacement_pair[0],
        .host_id = host_id,
        .wire_major = protocol.version_major,
        .screen_codec_version = screen_stream.codec_version,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    try client_slot_mod.testing.publishReplacementForGenerationForTest(
        &adapter.slot,
        1,
        2,
        &replacement,
    );
    try std.testing.expectEqual(@as(usize, 1), adapter.slot.retiredClientCount());

    var reclaim: client_slot_mod.PreparedRetiredClientReclaim = .{};
    try adapter.prepareRetiredClientReclaim(&reclaim);
    try adapter.preflightRetiredClientReclaim(&reclaim);
    adapter.commitRetiredClientReclaimAtTickEndNoFail(&reclaim);
    try std.testing.expectEqual(@as(usize, 0), adapter.slot.retiredClientCount());
    try std.testing.expectEqual(@as(u64, 2), adapter.connectionGeneration());

    adapter.deinit();
    adapter_live = false;
}

test "CR0b ClientSlot binding은 final Client 주소를 map publication보다 먼저 봉인한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    var pool_owns_adapter = false;
    errdefer if (!pool_owns_adapter) allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC0B,
        .wire_major = protocol.version_major,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    const host_id = source.host_id;
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(host_id, adapter, &permit);
    try std.testing.expect(pool.get(host_id) == null);
    try HostAdapter.initManagedInPlace(adapter, allocator, &source, &permit);
    const publication = adapter.incidentBindingPublication();
    try std.testing.expect(incident_binding_contract.validPublicationShape(publication));
    try std.testing.expectEqual(@intFromPtr(adapter.slot.logicalClientConst()), publication.client_addr);
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns_adapter = true;
    try std.testing.expect(pool.get(host_id) == adapter);
    try std.testing.expectEqual(
        @intFromEnum(incident_binding_contract.PublicationLifecycle.consumed),
        permit.lifecycle_raw,
    );
}

test "CR0b HostPool publication은 active reservation과 copied permit을 거부한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const first = try allocator.create(HostAdapter);
    defer allocator.destroy(first);
    const second = try allocator.create(HostAdapter);
    defer allocator.destroy(second);
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(0xC1, first, &permit);
    var other: incident_binding_contract.PreparedHostPublication = .{};
    try std.testing.expectError(error.PublicationBusy, pool.prepareOwnedPublication(0xC2, second, &other));
    const copied = permit;
    try std.testing.expect(!HostAdapter.validPreparedHostPublication(&copied, @intFromPtr(&pool), @intFromPtr(first)));
    pool.abortOwnedPublication(first, &permit);
    try std.testing.expectEqual(incident_binding_contract.PreparedHostPublication{}, permit);
}

test "CR0b HostPool publication은 abort 뒤 generation과 capacity를 재사용한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    defer allocator.destroy(adapter);
    var first: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(0xC3, adapter, &first);
    const generation = first.adapter_generation;
    pool.abortOwnedPublication(adapter, &first);
    var second: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(0xC3, adapter, &second);
    try std.testing.expectEqual(generation, second.adapter_generation);
    pool.abortOwnedPublication(adapter, &second);
}

test "CR0b HostPool publication은 capacity OOM 뒤 reservation과 permit을 pristine으로 되돌린다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    var pool = Pool.init(failing.allocator());
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    defer allocator.destroy(adapter);
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try std.testing.expectError(error.OutOfMemory, pool.prepareOwnedPublication(0xC30, adapter, &permit));
    try std.testing.expectEqual(incident_binding_contract.PreparedHostPublication{}, permit);
    try std.testing.expect(pool.get(0xC30) == null);
    try std.testing.expect(pool.adapterGeneration(0xC30) == null);

    failing.fail_index = std.math.maxInt(usize);
    try pool.prepareOwnedPublication(0xC30, adapter, &permit);
    try std.testing.expectEqual(@as(u64, 2), permit.adapter_generation);
    pool.abortOwnedPublication(adapter, &permit);
}

test "CR0b HostPool publication은 permit과 pool·adapter의 정확·부분 겹침을 거부한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    defer allocator.destroy(adapter);

    const pool_bytes = std.mem.asBytes(&pool);
    const pool_permit: *incident_binding_contract.PreparedHostPublication = @ptrCast(@alignCast(pool_bytes.ptr));
    try std.testing.expectError(error.InvalidDestination, pool.prepareOwnedPublication(0xC31, adapter, pool_permit));

    const adapter_bytes = std.mem.asBytes(adapter);
    const adapter_permit: *incident_binding_contract.PreparedHostPublication = @ptrCast(@alignCast(adapter_bytes.ptr + @alignOf(incident_binding_contract.PreparedHostPublication)));
    try std.testing.expectError(error.InvalidDestination, pool.prepareOwnedPublication(0xC31, adapter, adapter_permit));
}

test "CR0b HostPool publication은 managed permit과 source의 정확·부분 겹침을 거부한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    defer allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC33,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    defer source.deinit();
    const source_before = source;
    const source_bytes = std.mem.asBytes(&source);
    const source_exact_permit: *incident_binding_contract.PreparedHostPublication = @ptrCast(@alignCast(source_bytes.ptr));
    try std.testing.expectError(
        error.InvalidDestination,
        pool.prepareManagedOwnedPublication(source.host_id, adapter, &source, source_exact_permit),
    );
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&source_before), std.mem.asBytes(&source)));
    const source_permit: *incident_binding_contract.PreparedHostPublication = @ptrCast(@alignCast(source_bytes.ptr + @alignOf(incident_binding_contract.PreparedHostPublication)));
    try std.testing.expectError(
        error.InvalidDestination,
        pool.prepareManagedOwnedPublication(source.host_id, adapter, &source, source_permit),
    );
    try std.testing.expect(std.mem.eql(u8, std.mem.asBytes(&source_before), std.mem.asBytes(&source)));
    try std.testing.expect(pool.get(source.host_id) == null);

    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareManagedOwnedPublication(source.host_id, adapter, &source, &permit);
    pool.abortOwnedPublication(adapter, &permit);
}

test "CR0b HostPool publication은 초기화 뒤 복사된 pool 주소를 owner로 인정하지 않는다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    defer allocator.destroy(adapter);
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(0xC32, adapter, &permit);
    pool.abortOwnedPublication(adapter, &permit);

    var copied = pool;
    var copied_permit: incident_binding_contract.PreparedHostPublication = .{};
    try std.testing.expectError(error.InvalidOwner, copied.prepareOwnedPublication(0xC32, adapter, &copied_permit));
    try std.testing.expectEqual(incident_binding_contract.PreparedHostPublication{}, copied_permit);
    try std.testing.expect(pool.get(0xC32) == null);
}

test "CR0b HostPool publication은 bound permit을 exact once commit한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    var pool_owns_adapter = false;
    errdefer if (!pool_owns_adapter) allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC4,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, adapter, &permit);
    try HostAdapter.initManagedInPlace(adapter, allocator, &source, &permit);
    try std.testing.expect(HostAdapter.hostPublicationBound(&permit));
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns_adapter = true;
}

test "CR0b ClientSlot binding은 N-1 class와 wire major를 봉인한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    var pool_owns_adapter = false;
    errdefer if (!pool_owns_adapter) allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC5,
        .wire_major = protocol.version_major - 1,
        .screen_codec_version = screen_stream.codec_version - 1,
        .parser = @import("framing.zig").FrameParser.initForMajor(allocator, protocol.version_major - 1),
    };
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, adapter, &permit);
    try HostAdapter.initManagedInPlace(adapter, allocator, &source, &permit);
    const binding = adapter.slot.logicalClientConst().incident_binding;
    try std.testing.expectEqual(@intFromEnum(incident_binding_contract.HostClass.previous), binding.host_class_raw);
    try std.testing.expectEqual(protocol.version_major - 1, binding.wire_major);
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns_adapter = true;
}

test "CR0b HostPool publication은 prepare 동안 row와 generation을 게시하지 않는다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    defer allocator.destroy(adapter);
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(0xC6, adapter, &permit);
    try std.testing.expect(pool.get(0xC6) == null);
    try std.testing.expect(pool.adapterGeneration(0xC6) == null);
    try std.testing.expectEqual(@as(u64, 2), permit.adapter_generation);
    pool.abortOwnedPublication(adapter, &permit);
}

test "CR0b HostPool publication은 active reservation 동안 legacy add와 remove를 Busy로 닫는다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const reserved = try allocator.create(HostAdapter);
    defer allocator.destroy(reserved);
    const foreign = try allocator.create(HostAdapter);
    defer allocator.destroy(foreign);
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(0xC7, reserved, &permit);
    try std.testing.expectError(error.PublicationBusy, pool.addOwned(0xC8, foreign));
    try std.testing.expectError(error.PublicationBusy, pool.addBorrowed(0xC8, foreign));
    try std.testing.expectError(error.PublicationBusy, pool.remove(0xC7));
    pool.abortOwnedPublication(reserved, &permit);
}

test "CR0b HostPool publication은 commit 뒤 다음 adapter generation만 발급한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const first = try allocator.create(HostAdapter);
    var first_owned = false;
    errdefer if (!first_owned) allocator.destroy(first);
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xC9,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var first_permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, first, &first_permit);
    const first_generation = first_permit.adapter_generation;
    try HostAdapter.initManagedInPlace(first, allocator, &source, &first_permit);
    pool.commitOwnedPublication(first, &first_permit);
    first_owned = true;

    const second = try allocator.create(HostAdapter);
    defer allocator.destroy(second);
    var second_permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(0xCA, second, &second_permit);
    try std.testing.expectEqual(first_generation + 1, second_permit.adapter_generation);
    pool.abortOwnedPublication(second, &second_permit);
}

test "CR0b HostPool publication은 non-pristine permit을 reservation 전에 거부한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    defer allocator.destroy(adapter);
    var occupied: incident_binding_contract.PreparedHostPublication = .{ .host_id = 1 };
    const before = occupied;
    try std.testing.expectError(error.InvalidDestination, pool.prepareOwnedPublication(0xCB, adapter, &occupied));
    try std.testing.expectEqual(before, occupied);
    var pristine: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(0xCB, adapter, &pristine);
    pool.abortOwnedPublication(adapter, &pristine);
}

test "CR0b ClientSlot binding은 current class와 exact connection generation을 봉인한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    var pool_owns_adapter = false;
    errdefer if (!pool_owns_adapter) allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xCC,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, adapter, &permit);
    try HostAdapter.initManagedInPlace(adapter, allocator, &source, &permit);
    const binding = adapter.slot.logicalClientConst().incident_binding;
    try std.testing.expectEqual(@intFromEnum(incident_binding_contract.HostClass.current), binding.host_class_raw);
    try std.testing.expectEqual(adapter.connectionGeneration(), binding.connection_generation);
    try std.testing.expectEqual(permit.adapter_generation, binding.host_adapter_generation);
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns_adapter = true;
}

test "CR0b ClientSlot binding은 non-pristine publication destination을 source 이동 전에 거부한다" {
    try HostAdapter.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xCD,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    defer source.deinit();
    var slot: client_slot_mod.ClientSlot = undefined;
    var publication: incident_binding_contract.IncidentBindingPublication = .{ .client_addr = 1 };
    const before = publication;
    try std.testing.expectError(error.InvalidDestination, client_slot_mod.ClientSlot.initManagedInPlace(
        &slot,
        allocator,
        &source,
        source.host_id,
        2,
        .current,
        &publication,
    ));
    try std.testing.expectEqual(before, publication);
    try std.testing.expect(source.canMoveToGenerationNode());
}

test "CR0b ClientSlot binding은 zero adapter generation을 source 이동 전에 거부한다" {
    try HostAdapter.initializeProcessRuntime();
    const allocator = std.testing.allocator;
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xCE,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    defer source.deinit();
    var slot: client_slot_mod.ClientSlot = undefined;
    var publication: incident_binding_contract.IncidentBindingPublication = .{};
    try std.testing.expectError(error.InvalidDestination, client_slot_mod.ClientSlot.initManagedInPlace(
        &slot,
        allocator,
        &source,
        source.host_id,
        0,
        .current,
        &publication,
    ));
    try std.testing.expectEqual(incident_binding_contract.IncidentBindingPublication{}, publication);
    try std.testing.expect(source.canMoveToGenerationNode());
}

test "CR0b ClientSlot binding은 permit과 다른 host identity를 source 이동 전에 거부한다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    defer allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xCF,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    defer source.deinit();
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(0xD0, adapter, &permit);
    try std.testing.expectError(error.InvalidDestination, HostAdapter.initManagedInPlace(adapter, allocator, &source, &permit));
    try std.testing.expect(source.canMoveToGenerationNode());
    pool.abortOwnedPublication(adapter, &permit);
}

test "CR0b ClientSlot binding은 scalar splice를 valid publication으로 인정하지 않는다" {
    try HostAdapter.initializeProcessRuntime();
    const Pool = @import("host_pool.zig").HostPool(HostAdapter);
    const allocator = std.testing.allocator;
    var pool = Pool.init(allocator);
    defer pool.deinit();
    const adapter = try allocator.create(HostAdapter);
    var pool_owns_adapter = false;
    errdefer if (!pool_owns_adapter) allocator.destroy(adapter);
    var source: client_mod.Client = .{
        .allocator = allocator,
        .fd = -1,
        .host_id = 0xD1,
        .parser = @import("framing.zig").FrameParser.init(allocator),
    };
    var permit: incident_binding_contract.PreparedHostPublication = .{};
    try pool.prepareOwnedPublication(source.host_id, adapter, &permit);
    try HostAdapter.initManagedInPlace(adapter, allocator, &source, &permit);
    adapter.slot.logicalClient().incident_binding.connection_generation +%= 1;
    try std.testing.expectEqual(incident_binding_contract.IncidentBindingPublication{}, adapter.incidentBindingPublication());
    adapter.slot.logicalClient().incident_binding.connection_generation -%= 1;
    pool.commitOwnedPublication(adapter, &permit);
    pool_owns_adapter = true;
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
