//! Attach response와 `runtime.metadata` event가 공유하는 runtime metadata wire SSOT.
//!
//! 이 모듈은 envelope를 한 번 parse해 typed owned DTO를 만든다. GUI cache와 external pump는 이 DTO의
//! view를 소비하며 metadata 필드의 type/range/default를 다시 구현하지 않는다.

const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const resize_wire = @import("resize_wire.zig");
const runtime_event_types = @import("runtime_event_types.zig");
const runtime_event_preparation = @import("runtime_event_preparation.zig");
const runtime_event_wire = @import("runtime_event_wire.zig");
const runtime_metadata_types = @import("runtime_metadata_types.zig");

pub const max_metadata_fields: usize = runtime_metadata_types.max_metadata_fields;
pub const max_process_entries: usize = runtime_metadata_types.max_process_entries;
pub const max_process_fields: usize = runtime_metadata_types.max_process_fields;

pub const MetadataSupport = runtime_event_wire.MetadataSupport;

pub const DecodeError = error{
    OutOfMemory,
    Malformed,
    ResourceExhausted,
    CapabilityViolation,
};

pub const EventMaterializationError = DecodeError || error{LocalInvariant};

pub const AttachGenerationSchema = runtime_event_wire.AttachGenerationSchema;
pub const AttachDecodeProfile = runtime_event_wire.AttachDecodeProfile;

pub const MaterializationFootprint = struct {
    backing_bytes: usize,
    resident_bytes: usize,
};

pub const AttachScalars = struct {
    stream_id: u64,
    controller_generation: u64,
    observe: bool,
    input: bool,
    resize: bool,
    controller_busy: bool,
    initial_metadata: InitialMetadataSeed,

    pub fn deinit(self: *AttachScalars) void {
        self.initial_metadata.deinit();
        self.* = undefined;
    }
};

pub const AttachEnvelope = union(enum) {
    wire_error: protocol.ErrorCode,
    accepted: AttachScalars,

    pub fn deinit(self: *AttachEnvelope) void {
        switch (self.*) {
            .accepted => |*accepted| accepted.deinit(),
            .wire_error => {},
        }
        self.* = undefined;
    }
};

pub const SemanticPrompt = runtime_metadata_types.SemanticPrompt;

pub const Process = runtime_metadata_types.ProcessValue;
pub const max_process_name_bytes: usize = runtime_metadata_types.max_process_name_bytes;

pub const OwnedMetadataDto = struct {
    allocator: std.mem.Allocator,
    backing: ?[]u8,
    revision: u64,
    observer_generation: u64,
    title_generation: u32,
    cols: u16,
    rows: u16,
    semantic_state: SemanticPrompt,
    alt_active: bool,
    app_cursor_keys: bool,
    app_keypad: bool,
    kitty_flags: u5,
    alternate_scroll: bool,
    mouse_tracking: bool,
    mouse_tracking_mode: u8,
    bracketed_paste: bool,
    bell_count: u64,
    clipboard_write_seq: u64,
    clipboard_read_seq: u64,
    foreground_available: bool,
    foreground_pgid: ?i32,
    /// PTY 자식 뿌리 pid와 그 소유 host 프로세스 pid(구 host면 0). GUI 상태바가 host-backed 터미널의
    /// 트리와 데몬 자신을 재는 두 뿌리다(docs/status-bar.md §4.1).
    child_pid: i32,
    host_pid: i32,
    cwd_range: Range,
    cwd_host_range: Range,
    title_range: Range,
    ssh_range: ?Range,
    clipboard_target_range: Range,
    processes: [max_process_entries]Process,
    process_count: u8,

    const Range = struct {
        start: usize,
        len: usize,
    };

    pub fn cwd(self: *const OwnedMetadataDto) []const u8 {
        return self.slice(self.cwd_range);
    }

    pub fn cwdHost(self: *const OwnedMetadataDto) []const u8 {
        return self.slice(self.cwd_host_range);
    }

    pub fn windowTitle(self: *const OwnedMetadataDto) []const u8 {
        return self.slice(self.title_range);
    }

    pub fn sshRemoteDest(self: *const OwnedMetadataDto) ?[]const u8 {
        return if (self.ssh_range) |range| self.slice(range) else null;
    }

    pub fn clipboardReadTarget(self: *const OwnedMetadataDto) []const u8 {
        return self.slice(self.clipboard_target_range);
    }

    pub fn foregroundProcesses(self: *const OwnedMetadataDto) []const Process {
        return self.processes[0..self.process_count];
    }

    pub fn deinit(self: *OwnedMetadataDto) void {
        if (self.backing) |backing| self.allocator.free(backing);
        self.backing = null;
        self.process_count = 0;
    }

    pub fn take(self: *OwnedMetadataDto) OwnedMetadataDto {
        const result = self.*;
        self.backing = null;
        self.process_count = 0;
        return result;
    }

    pub fn semanticEql(a: *const OwnedMetadataDto, b: *const OwnedMetadataDto) bool {
        if (a.revision != b.revision or
            a.observer_generation != b.observer_generation or
            a.title_generation != b.title_generation or
            a.cols != b.cols or a.rows != b.rows or
            a.semantic_state != b.semantic_state or
            a.alt_active != b.alt_active or
            a.app_cursor_keys != b.app_cursor_keys or
            a.app_keypad != b.app_keypad or
            a.kitty_flags != b.kitty_flags or
            a.alternate_scroll != b.alternate_scroll or
            a.mouse_tracking != b.mouse_tracking or
            a.mouse_tracking_mode != b.mouse_tracking_mode or
            a.bracketed_paste != b.bracketed_paste or
            a.bell_count != b.bell_count or
            a.clipboard_write_seq != b.clipboard_write_seq or
            a.clipboard_read_seq != b.clipboard_read_seq or
            a.foreground_available != b.foreground_available or
            a.foreground_pgid != b.foreground_pgid or
            a.child_pid != b.child_pid or
            a.host_pid != b.host_pid or
            !std.mem.eql(u8, a.cwd(), b.cwd()) or
            !std.mem.eql(u8, a.cwdHost(), b.cwdHost()) or
            !std.mem.eql(u8, a.windowTitle(), b.windowTitle()) or
            !optionalStringEql(a.sshRemoteDest(), b.sshRemoteDest()) or
            !std.mem.eql(u8, a.clipboardReadTarget(), b.clipboardReadTarget()) or
            a.process_count != b.process_count)
            return false;
        for (a.foregroundProcesses(), b.foregroundProcesses()) |ap, bp| {
            if (ap.pid != bp.pid or !std.mem.eql(u8, ap.slice(), bp.slice())) return false;
        }
        return true;
    }

    fn slice(self: *const OwnedMetadataDto, range: Range) []const u8 {
        if (range.len == 0) return "";
        return self.backing.?[range.start..][0..range.len];
    }
};

pub const InitialMetadataSeed = union(enum) {
    unsupported,
    unavailable,
    current: OwnedMetadataDto,

    pub fn deinit(self: *InitialMetadataSeed) void {
        switch (self.*) {
            .current => |*dto| dto.deinit(),
            else => {},
        }
        self.* = .unavailable;
    }

    pub fn take(self: *InitialMetadataSeed) InitialMetadataSeed {
        const result = self.*;
        self.* = .unavailable;
        return result;
    }
};

/// Allocation-free bridge from the canonical owning attach seed to one classified metadata event.
///
/// The seal is rebound before any DTO backing is borrowed. The event preflight is likewise rebound
/// to its exact raw payload, then every normalized scalar and decoded string/process byte is
/// compared. This is the c3b reducer's initial-baseline equality callback; it does not materialize
/// a second DTO.
pub fn metadataSeedSemanticEqlEvent(
    seed: *const InitialMetadataSeed,
    seal: MetadataSeedSeal,
    event_payload: []const u8,
    event_preflight: runtime_event_wire.EventPreflight,
) bool {
    if (!validateMetadataSeedSeal(seal, seed) or seal.tag != .current) return false;
    const dto = switch (seed.*) {
        .current => |*value| value,
        else => return false,
    };
    return ownedMetadataSemanticEqlEvent(dto, event_payload, event_preflight);
}

pub fn ownedMetadataSemanticEqlEvent(
    dto: *const OwnedMetadataDto,
    event_payload: []const u8,
    event_preflight: runtime_event_wire.EventPreflight,
) bool {
    if (!validateCurrentMetadataStructure(dto)) return false;
    if (!std.mem.eql(
        u8,
        &runtime_event_wire.payloadDigest(event_payload),
        &event_preflight.raw_digest,
    )) return false;
    const event = switch (event_preflight.event) {
        .metadata => |value| value,
        else => return false,
    };
    if (dto.revision != event.revision or
        dto.observer_generation != event.observer_generation or
        dto.title_generation != event.title_generation or
        dto.cols != event.cols or dto.rows != event.rows or
        dto.semantic_state != event.semantic_state or
        dto.alt_active != event.alt_active or
        dto.app_cursor_keys != event.app_cursor_keys or
        dto.app_keypad != event.app_keypad or
        dto.kitty_flags != event.kitty_flags or
        dto.alternate_scroll != event.alternate_scroll or
        dto.mouse_tracking != event.mouse_tracking or
        dto.mouse_tracking_mode != event.mouse_tracking_mode or
        dto.bracketed_paste != event.bracketed_paste or
        dto.bell_count != event.bell_count or
        dto.clipboard_write_seq != event.clipboard_write_seq or
        dto.clipboard_read_seq != event.clipboard_read_seq or
        dto.foreground_available != event.foreground_available or
        dto.foreground_pgid != event.foreground_pgid or
        dto.child_pid != event.child_pid or
        dto.host_pid != event.host_pid or
        dto.process_count != event.process_count or
        !runtime_event_wire.decodedStringSpanEqualsBytes(
            event_payload,
            event.cwd,
            dto.cwd(),
        ) or
        !runtime_event_wire.decodedStringSpanEqualsBytes(
            event_payload,
            event.cwd_host,
            dto.cwdHost(),
        ) or
        !runtime_event_wire.decodedStringSpanEqualsBytes(
            event_payload,
            event.window_title,
            dto.windowTitle(),
        ) or
        !optionalSpanEqualsBytes(
            event_payload,
            event.ssh_remote_dest,
            dto.sshRemoteDest(),
        ) or
        !runtime_event_wire.decodedStringSpanEqualsBytes(
            event_payload,
            event.clipboard_read_target,
            dto.clipboardReadTarget(),
        ))
        return false;
    for (dto.foregroundProcesses(), event.foregroundProcesses()) |owned, borrowed| {
        if (owned.pid != borrowed.pid or
            !runtime_event_wire.decodedStringSpanEqualsBytes(
                event_payload,
                borrowed.name,
                owned.slice(),
            ))
            return false;
    }
    return true;
}

fn optionalSpanEqualsBytes(
    payload: []const u8,
    span: ?runtime_event_wire.StringSpan,
    bytes: ?[]const u8,
) bool {
    if ((span == null) != (bytes == null)) return false;
    if (span) |value|
        return runtime_event_wire.decodedStringSpanEqualsBytes(
            payload,
            value,
            bytes.?,
        );
    return true;
}

pub const MetadataSeedTag = enum { unsupported, unavailable, current };

/// Non-owning, address-bound descriptor/content seal used by the paired external-pump transfer.
/// Range validation always precedes content hashing, so malformed DTO fields are never sliced.
pub const MetadataSeedSeal = struct {
    seed_addr: usize,
    tag: MetadataSeedTag,
    dto_addr: usize,
    allocator_ptr_addr: usize,
    allocator_vtable_addr: usize,
    backing_present: bool,
    backing_addr: usize,
    backing_len: usize,
    revision: u64,
    raw_digest: runtime_event_wire.Digest,
    semantic_digest: runtime_event_wire.Digest,
};

pub const MetadataSeedSealError = error{Malformed};

/// Address-bound ownership/content seal for a standalone metadata DTO. Unlike
/// `MetadataSeedSeal`, this does not invent a temporary seed union merely to bind the DTO.
pub const OwnedMetadataSeal = struct {
    dto_addr: usize,
    allocator_ptr_addr: usize,
    allocator_vtable_addr: usize,
    backing_present: bool,
    backing_addr: usize,
    backing_len: usize,
    revision: u64,
    raw_digest: runtime_event_wire.Digest,
    semantic_digest: runtime_event_wire.Digest,
};

pub const OwnedMetadataSealError = error{Malformed};

pub fn sealOwnedMetadataDto(
    dto: *const OwnedMetadataDto,
) OwnedMetadataSealError!OwnedMetadataSeal {
    if (!validateCurrentMetadataStructure(dto)) return error.Malformed;
    const backing = dto.backing orelse &.{};
    return .{
        .dto_addr = @intFromPtr(dto),
        .allocator_ptr_addr = @intFromPtr(dto.allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(dto.allocator.vtable),
        .backing_present = dto.backing != null,
        .backing_addr = if (dto.backing) |bytes| @intFromPtr(bytes.ptr) else 0,
        .backing_len = backing.len,
        .revision = dto.revision,
        .raw_digest = runtime_event_wire.payloadDigest(backing),
        .semantic_digest = metadataSemanticDigest(dto, backing),
    };
}

/// Cleanup selection must not read a possibly forged backing. Content hashing is deliberately
/// reserved for `validateOwnedMetadataSeal` after this descriptor-only check succeeds.
pub fn validateOwnedMetadataDescriptor(
    seal: OwnedMetadataSeal,
    dto: *const OwnedMetadataDto,
) bool {
    return seal.dto_addr == @intFromPtr(dto) and
        seal.allocator_ptr_addr == @intFromPtr(dto.allocator.ptr) and
        seal.allocator_vtable_addr == @intFromPtr(dto.allocator.vtable) and
        seal.backing_present == (dto.backing != null) and
        seal.backing_addr == (if (dto.backing) |bytes| @intFromPtr(bytes.ptr) else 0) and
        seal.backing_len == (if (dto.backing) |bytes| bytes.len else 0) and
        seal.revision == dto.revision and
        validateCurrentMetadataStructure(dto);
}

pub fn validateOwnedMetadataSeal(
    seal: OwnedMetadataSeal,
    dto: *const OwnedMetadataDto,
) bool {
    if (!validateOwnedMetadataDescriptor(seal, dto)) return false;
    const actual = sealOwnedMetadataDto(dto) catch return false;
    return std.meta.eql(seal, actual);
}

pub fn sealMetadataSeed(seed: *const InitialMetadataSeed) MetadataSeedSealError!MetadataSeedSeal {
    return switch (seed.*) {
        .unsupported => scalarSeedSeal(seed, .unsupported),
        .unavailable => scalarSeedSeal(seed, .unavailable),
        .current => |*dto| try sealCurrentMetadata(seed, dto),
    };
}

pub fn validateMetadataSeedSeal(
    seal: MetadataSeedSeal,
    seed: *const InitialMetadataSeed,
) bool {
    if (!validateMetadataSeedDescriptor(seal, seed)) return false;
    const current = sealMetadataSeed(seed) catch return false;
    return std.meta.eql(seal, current);
}

/// Descriptor-only ownership check. It never reads backing content and is therefore safe for
/// cleanup selection after a logical seed's pointer or bytes have drifted.
pub fn validateMetadataSeedDescriptor(
    seal: MetadataSeedSeal,
    seed: *const InitialMetadataSeed,
) bool {
    if (seal.seed_addr != @intFromPtr(seed)) return false;
    return switch (seed.*) {
        .unsupported => seal.tag == .unsupported and scalarDescriptorIsCanonical(seal),
        .unavailable => seal.tag == .unavailable and scalarDescriptorIsCanonical(seal),
        .current => |*dto| seal.tag == .current and
            seal.dto_addr == @intFromPtr(dto) and
            seal.allocator_ptr_addr == @intFromPtr(dto.allocator.ptr) and
            seal.allocator_vtable_addr == @intFromPtr(dto.allocator.vtable) and
            seal.backing_present == (dto.backing != null) and
            seal.backing_addr == (if (dto.backing) |bytes| @intFromPtr(bytes.ptr) else 0) and
            seal.backing_len == (if (dto.backing) |bytes| bytes.len else 0) and
            seal.revision == dto.revision and
            validateCurrentMetadataStructure(dto),
    };
}

fn scalarDescriptorIsCanonical(seal: MetadataSeedSeal) bool {
    return seal.dto_addr == 0 and seal.allocator_ptr_addr == 0 and
        seal.allocator_vtable_addr == 0 and !seal.backing_present and
        seal.backing_addr == 0 and seal.backing_len == 0 and seal.revision == 0;
}

fn scalarSeedSeal(
    seed: *const InitialMetadataSeed,
    tag: MetadataSeedTag,
) MetadataSeedSeal {
    const digest = runtime_event_wire.payloadDigest(@tagName(tag));
    return .{
        .seed_addr = @intFromPtr(seed),
        .tag = tag,
        .dto_addr = 0,
        .allocator_ptr_addr = 0,
        .allocator_vtable_addr = 0,
        .backing_present = false,
        .backing_addr = 0,
        .backing_len = 0,
        .revision = 0,
        .raw_digest = digest,
        .semantic_digest = digest,
    };
}

fn sealCurrentMetadata(
    seed: *const InitialMetadataSeed,
    dto: *const OwnedMetadataDto,
) MetadataSeedSealError!MetadataSeedSeal {
    if (!validateCurrentMetadataStructure(dto)) return error.Malformed;
    const backing = dto.backing orelse &.{};
    return .{
        .seed_addr = @intFromPtr(seed),
        .tag = .current,
        .dto_addr = @intFromPtr(dto),
        .allocator_ptr_addr = @intFromPtr(dto.allocator.ptr),
        .allocator_vtable_addr = @intFromPtr(dto.allocator.vtable),
        .backing_present = dto.backing != null,
        .backing_addr = if (dto.backing) |bytes| @intFromPtr(bytes.ptr) else 0,
        .backing_len = backing.len,
        .revision = dto.revision,
        .raw_digest = runtime_event_wire.payloadDigest(backing),
        .semantic_digest = metadataSemanticDigest(dto, backing),
    };
}

fn validateCurrentMetadataStructure(dto: *const OwnedMetadataDto) bool {
    if (dto.revision == 0 or dto.process_count > dto.processes.len) return false;
    const backing_len = if (dto.backing) |backing| backing.len else 0;
    var offset: usize = 0;
    if (!rangeIsCanonical(dto.cwd_range, &offset, backing_len)) return false;
    if (!rangeIsCanonical(dto.cwd_host_range, &offset, backing_len)) return false;
    if (!rangeIsCanonical(dto.title_range, &offset, backing_len)) return false;
    if (dto.ssh_range) |range| {
        if (!rangeIsCanonical(range, &offset, backing_len)) return false;
    }
    if (!rangeIsCanonical(dto.clipboard_target_range, &offset, backing_len)) return false;
    if (offset != backing_len) return false;
    if (dto.backing == null and backing_len != 0) return false;
    if (!dto.foreground_available and
        (dto.foreground_pgid != null or dto.process_count != 0))
        return false;
    for (dto.processes[0..dto.process_count]) |process| {
        if (process.len > process.bytes.len) return false;
    }
    return true;
}

fn rangeIsCanonical(range: OwnedMetadataDto.Range, offset: *usize, backing_len: usize) bool {
    if (range.start != offset.*) return false;
    const end = std.math.add(usize, range.start, range.len) catch return false;
    if (end > backing_len) return false;
    offset.* = end;
    return true;
}

fn metadataSemanticDigest(
    dto: *const OwnedMetadataDto,
    backing: []const u8,
) runtime_event_wire.Digest {
    var hasher = std.crypto.hash.sha2.Sha256.init(.{});
    hasher.update("maru.metadata-seed.v1");
    hashInt(&hasher, u64, dto.revision);
    hashInt(&hasher, u64, dto.observer_generation);
    hashInt(&hasher, u32, dto.title_generation);
    hashInt(&hasher, u16, dto.cols);
    hashInt(&hasher, u16, dto.rows);
    hashInt(&hasher, u8, @intFromEnum(dto.semantic_state));
    hashBool(&hasher, dto.alt_active);
    hashBool(&hasher, dto.app_cursor_keys);
    hashBool(&hasher, dto.app_keypad);
    hashInt(&hasher, u8, dto.kitty_flags);
    hashBool(&hasher, dto.alternate_scroll);
    hashBool(&hasher, dto.mouse_tracking);
    hashInt(&hasher, u8, dto.mouse_tracking_mode);
    hashBool(&hasher, dto.bracketed_paste);
    hashInt(&hasher, u64, dto.bell_count);
    hashInt(&hasher, u64, dto.clipboard_write_seq);
    hashInt(&hasher, u64, dto.clipboard_read_seq);
    hashBool(&hasher, dto.foreground_available);
    hashBool(&hasher, dto.foreground_pgid != null);
    if (dto.foreground_pgid) |pgid| hashInt(&hasher, i32, pgid);
    hashInt(&hasher, i32, dto.child_pid);
    hashInt(&hasher, i32, dto.host_pid);
    hashRange(&hasher, dto.cwd_range, backing);
    hashRange(&hasher, dto.cwd_host_range, backing);
    hashRange(&hasher, dto.title_range, backing);
    hashBool(&hasher, dto.ssh_range != null);
    if (dto.ssh_range) |range| hashRange(&hasher, range, backing);
    hashRange(&hasher, dto.clipboard_target_range, backing);
    hashInt(&hasher, u8, dto.process_count);
    for (dto.processes[0..dto.process_count]) |process| {
        hashInt(&hasher, i32, process.pid);
        hashInt(&hasher, u8, process.len);
        hasher.update(process.bytes[0..process.len]);
    }
    var digest: runtime_event_wire.Digest = undefined;
    hasher.final(&digest);
    return digest;
}

fn hashRange(
    hasher: *std.crypto.hash.sha2.Sha256,
    range: OwnedMetadataDto.Range,
    backing: []const u8,
) void {
    hashInt(hasher, usize, range.len);
    hasher.update(backing[range.start..][0..range.len]);
}

fn hashBool(hasher: *std.crypto.hash.sha2.Sha256, value: bool) void {
    hashInt(hasher, u8, @intFromBool(value));
}

fn hashInt(
    hasher: *std.crypto.hash.sha2.Sha256,
    comptime T: type,
    value: T,
) void {
    var bytes: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &bytes, value, .little);
    hasher.update(&bytes);
}

/// Decode the complete attach response exactly once. Role/request policy is intentionally left to
/// `remote_attachment`; this neutral leaf owns only the sealed wire schema and metadata seed.
pub fn decodeAttachEnvelope(
    allocator: std.mem.Allocator,
    payload: []const u8,
    profile: AttachDecodeProfile,
) DecodeError!AttachEnvelope {
    const preflight = runtime_event_wire.preflightAttachEnvelope(payload, profile) catch |err|
        return switch (err) {
            error.Malformed => error.Malformed,
            error.ResourceExhausted => error.ResourceExhausted,
        };
    return switch (preflight.envelope) {
        .wire_error => |code| .{ .wire_error = code },
        .accepted => |accepted| .{ .accepted = .{
            .stream_id = accepted.stream_id,
            .controller_generation = accepted.controller_generation,
            .observe = accepted.observe,
            .input = accepted.input,
            .resize = accepted.resize,
            .controller_busy = accepted.controller_busy,
            .initial_metadata = switch (accepted.initial_metadata) {
                .unsupported => .unsupported,
                .unavailable => .unavailable,
                .current => |metadata| .{
                    .current = try materializePreflight(
                        allocator,
                        payload,
                        metadata,
                        preflight.raw_digest,
                    ),
                },
            },
        } },
    };
}

pub fn decodeMetadataEvent(
    allocator: std.mem.Allocator,
    payload: []const u8,
    support: MetadataSupport,
) DecodeError!InitialMetadataSeed {
    if (support == .unsupported) return error.CapabilityViolation;
    return switch (runtime_event_wire.preflightEvent(payload, .{})) {
        .accepted => |preflight| switch (preflight.event) {
            .metadata => |metadata| .{
                .current = try materializePreflight(
                    allocator,
                    payload,
                    metadata,
                    preflight.raw_digest,
                ),
            },
            else => error.Malformed,
        },
        .resource_exhausted => error.ResourceExhausted,
        .malformed, .unknown, .foreign => error.Malformed,
    };
}

/// Test-only owning fixture factory. Product callers must enter through attach/event classifiers.
pub fn testingCurrentSeed(
    allocator: std.mem.Allocator,
) DecodeError!InitialMetadataSeed {
    if (!builtin.is_test) @compileError("testingCurrentSeed is test-only");
    return decodeMetadataEvent(
        allocator,
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":\"host\",\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":7,\"processes\":[{\"pid\":7,\"name\":\"zsh\"}]}}",
        .supported,
    );
}

pub fn decodeObservationEnvelope(
    allocator: std.mem.Allocator,
    payload: []const u8,
) DecodeError!InitialMetadataSeed {
    const preflight = runtime_event_wire.preflightObservationEnvelope(payload) catch |err|
        return switch (err) {
            error.Malformed => error.Malformed,
            error.ResourceExhausted => error.ResourceExhausted,
        };
    return switch (preflight.initial_metadata) {
        .unsupported => error.Malformed,
        .unavailable => .unavailable,
        .current => |metadata| .{
            .current = try materializePreflight(
                allocator,
                payload,
                metadata,
                preflight.raw_digest,
            ),
        },
    };
}

/// Materializes an allocation-free event preflight into the single owning DTO used by GUI and
/// external adoption. There is exactly one heap allocation, sized to the five retained strings;
/// process names stay in the fixed zero-tailed array.
fn materializePreflight(
    allocator: std.mem.Allocator,
    payload: []const u8,
    metadata: runtime_event_wire.MetadataView,
    source_digest: runtime_event_wire.Digest,
) DecodeError!OwnedMetadataDto {
    const actual_digest = runtime_event_wire.payloadDigest(payload);
    if (!std.mem.eql(u8, &actual_digest, &source_digest)) return error.Malformed;
    var backing_len: usize = 0;
    backing_len = std.math.add(usize, backing_len, metadata.cwd.decoded_len) catch
        return error.ResourceExhausted;
    backing_len = std.math.add(usize, backing_len, metadata.cwd_host.decoded_len) catch
        return error.ResourceExhausted;
    backing_len = std.math.add(usize, backing_len, metadata.window_title.decoded_len) catch
        return error.ResourceExhausted;
    if (metadata.ssh_remote_dest) |ssh| {
        backing_len = std.math.add(usize, backing_len, ssh.decoded_len) catch
            return error.ResourceExhausted;
    }
    backing_len = std.math.add(
        usize,
        backing_len,
        metadata.clipboard_read_target.decoded_len,
    ) catch return error.ResourceExhausted;
    if (backing_len > protocol.max_control_json) return error.ResourceExhausted;

    const backing = if (backing_len == 0) null else try allocator.alloc(u8, backing_len);
    errdefer if (backing) |bytes| allocator.free(bytes);

    var processes = [_]Process{.{}} ** max_process_entries;
    for (metadata.foregroundProcesses(), 0..) |process, index| {
        if (process.name.decoded_len > processes[index].bytes.len) return error.ResourceExhausted;
        processes[index].pid = process.pid;
        processes[index].len = @intCast(process.name.decoded_len);
        runtime_event_wire.decodeStringExact(
            payload,
            process.name,
            processes[index].bytes[0..process.name.decoded_len],
        ) catch return error.Malformed;
    }

    var dto: OwnedMetadataDto = .{
        .allocator = allocator,
        .backing = backing,
        .revision = metadata.revision,
        .observer_generation = metadata.observer_generation,
        .title_generation = metadata.title_generation,
        .cols = metadata.cols,
        .rows = metadata.rows,
        .semantic_state = metadata.semantic_state,
        .alt_active = metadata.alt_active,
        .app_cursor_keys = metadata.app_cursor_keys,
        .app_keypad = metadata.app_keypad,
        .kitty_flags = metadata.kitty_flags,
        .alternate_scroll = metadata.alternate_scroll,
        .mouse_tracking = metadata.mouse_tracking,
        .mouse_tracking_mode = metadata.mouse_tracking_mode,
        .bracketed_paste = metadata.bracketed_paste,
        .bell_count = metadata.bell_count,
        .clipboard_write_seq = metadata.clipboard_write_seq,
        .clipboard_read_seq = metadata.clipboard_read_seq,
        .foreground_available = metadata.foreground_available,
        .foreground_pgid = metadata.foreground_pgid,
        .child_pid = metadata.child_pid,
        .host_pid = metadata.host_pid,
        .cwd_range = undefined,
        .cwd_host_range = undefined,
        .title_range = undefined,
        .ssh_range = null,
        .clipboard_target_range = undefined,
        .processes = processes,
        .process_count = metadata.process_count,
    };

    var offset: usize = 0;
    dto.cwd_range = try copySpan(backing, &offset, payload, metadata.cwd);
    dto.cwd_host_range = try copySpan(backing, &offset, payload, metadata.cwd_host);
    dto.title_range = try copySpan(backing, &offset, payload, metadata.window_title);
    if (metadata.ssh_remote_dest) |ssh| dto.ssh_range = try copySpan(backing, &offset, payload, ssh);
    dto.clipboard_target_range = try copySpan(
        backing,
        &offset,
        payload,
        metadata.clipboard_read_target,
    );

    if (!dto.foreground_available) {
        dto.foreground_pgid = null;
        dto.process_count = 0;
    }
    return dto;
}

pub fn preflightEventMaterialization(
    payload: []const u8,
    preflight: runtime_event_wire.EventPreflight,
) DecodeError!MaterializationFootprint {
    const actual_digest = runtime_event_wire.payloadDigest(payload);
    if (!std.mem.eql(u8, &actual_digest, &preflight.raw_digest))
        return error.Malformed;
    const metadata = switch (preflight.event) {
        .metadata => |metadata| metadata,
        else => return error.Malformed,
    };
    if (metadata.process_count > max_process_entries)
        return error.ResourceExhausted;
    var backing_bytes: usize = 0;
    const fixed = [_]runtime_event_wire.StringSpan{
        metadata.cwd,
        metadata.cwd_host,
        metadata.window_title,
        metadata.clipboard_read_target,
    };
    for (fixed) |span| {
        if (!runtime_event_wire.validateStringSpan(payload, span))
            return error.Malformed;
        backing_bytes = std.math.add(
            usize,
            backing_bytes,
            span.decoded_len,
        ) catch return error.ResourceExhausted;
    }
    if (metadata.ssh_remote_dest) |span| {
        if (!runtime_event_wire.validateStringSpan(payload, span))
            return error.Malformed;
        backing_bytes = std.math.add(
            usize,
            backing_bytes,
            span.decoded_len,
        ) catch return error.ResourceExhausted;
    }
    for (metadata.foregroundProcesses()) |process| {
        if (process.name.decoded_len > max_process_name_bytes)
            return error.ResourceExhausted;
        if (!runtime_event_wire.validateStringSpan(payload, process.name))
            return error.Malformed;
    }
    if (backing_bytes > protocol.max_control_json)
        return error.ResourceExhausted;
    const resident_bytes = std.math.add(
        usize,
        @sizeOf(OwnedMetadataDto),
        backing_bytes,
    ) catch return error.ResourceExhausted;
    return .{
        .backing_bytes = backing_bytes,
        .resident_bytes = resident_bytes,
    };
}

/// Re-runs the lexical event parser before allocating so callers cannot combine an authentic
/// payload digest with caller-forged scalar fields in a constructible `EventPreflight`.
pub fn materializeExactEventMetadata(
    allocator: std.mem.Allocator,
    payload: []const u8,
    expected_identity: runtime_event_wire.ExpectedIdentity,
    expected_preflight: runtime_event_wire.EventPreflight,
) DecodeError!OwnedMetadataDto {
    const actual = switch (runtime_event_wire.preflightEvent(
        payload,
        expected_identity,
    )) {
        .accepted => |accepted| accepted,
        else => return error.Malformed,
    };
    if (!runtime_event_wire.eventPreflightEql(actual, expected_preflight))
        return error.Malformed;
    _ = try preflightEventMaterialization(payload, actual);
    const metadata = switch (actual.event) {
        .metadata => |metadata| metadata,
        else => return error.Malformed,
    };
    return materializePreflight(
        allocator,
        payload,
        metadata,
        actual.raw_digest,
    );
}

/// Product classification owns metadata immediately inside this module. General runtime event
/// consumers cannot feed a constructible `ValidatedMetadataView` to an owning decoder. The narrow
/// external-adoption entrypoint above re-runs the lexical parser and requires exact preflight
/// equality; this classifier remains the only public owning entrypoint that applies live runtime
/// authority and capability policy.
pub const ClassifiedOwnedEvent = union(enum) {
    revoked: u64,
    invalidated,
    resized: resize_wire.Event,
    metadata: OwnedMetadataDto,
    ended,
};

pub const OwnedEventClassification = union(enum) {
    accepted: ClassifiedOwnedEvent,
    violation: runtime_event_types.Violation,
};

pub fn classifyAndMaterializeEvent(
    allocator: std.mem.Allocator,
    identity: runtime_event_types.EventIdentity,
    authority: runtime_event_types.EventAuthorityView,
    preflight: runtime_event_types.EventPreflightView,
    frame: runtime_event_types.EventFrameView,
) EventMaterializationError!OwnedEventClassification {
    const classification = runtime_event_types.classifyEventView(
        identity,
        authority,
        preflight,
        frame,
    );
    return materializeClassifiedEvent(allocator, classification, frame.payload);
}

fn materializeClassifiedEvent(
    allocator: std.mem.Allocator,
    classification: runtime_event_types.Classification,
    payload: []const u8,
) EventMaterializationError!OwnedEventClassification {
    const recipe = runtime_event_preparation.buildEventPreparationRecipe(
        classification,
        payload,
    ) catch return error.LocalInvariant;
    return switch (recipe) {
        .violation => |value| .{ .violation = value },
        .accepted => |accepted| .{ .accepted = switch (accepted) {
            .revoked => |value| .{ .revoked = value },
            .invalidated => .invalidated,
            .resized => |value| .{ .resized = value },
            .metadata => |metadata| .{
                .metadata = try materializePreparedEventMetadata(
                    allocator,
                    payload,
                    classification,
                    metadata,
                ),
            },
            .ended => .ended,
        } },
    };
}

fn materializePreparedEventMetadata(
    allocator: std.mem.Allocator,
    payload: []const u8,
    classification: runtime_event_types.Classification,
    recipe: runtime_event_preparation.MetadataPreparationRecipe,
) EventMaterializationError!OwnedMetadataDto {
    const backing_len: usize = recipe.backing_bytes;
    const backing = if (backing_len == 0) null else try allocator.alloc(u8, backing_len);
    errdefer if (backing) |bytes| allocator.free(bytes);

    var empty_backing: [0]u8 = .{};
    const destination = backing orelse empty_backing[0..];
    var processes = [_]Process{.{}} ** max_process_entries;
    const projection = runtime_event_preparation.fillMetadataRecipe(
        &recipe,
        classification,
        payload,
        destination,
        &processes,
    ) catch return error.LocalInvariant;

    return .{
        .allocator = allocator,
        .backing = backing,
        .revision = recipe.revision,
        .observer_generation = recipe.observer_generation,
        .title_generation = recipe.title_generation,
        .cols = recipe.cols,
        .rows = recipe.rows,
        .semantic_state = @enumFromInt(recipe.semantic_state_raw),
        .alt_active = recipe.alt_active_raw == 1,
        .app_cursor_keys = recipe.app_cursor_keys_raw == 1,
        .app_keypad = recipe.app_keypad_raw == 1,
        .kitty_flags = @intCast(recipe.kitty_flags_raw),
        .alternate_scroll = recipe.alternate_scroll_raw == 1,
        .mouse_tracking = recipe.mouse_tracking_raw == 1,
        .mouse_tracking_mode = recipe.mouse_tracking_mode,
        .bracketed_paste = recipe.bracketed_paste_raw == 1,
        .bell_count = recipe.bell_count,
        .clipboard_write_seq = recipe.clipboard_write_seq,
        .clipboard_read_seq = recipe.clipboard_read_seq,
        .foreground_available = recipe.foreground_available_raw == 1,
        .foreground_pgid = if (recipe.foreground_pgid_present_raw == 1)
            recipe.foreground_pgid
        else
            null,
        .child_pid = recipe.child_pid,
        .host_pid = recipe.host_pid,
        .cwd_range = ownedRange(projection.cwd),
        .cwd_host_range = ownedRange(projection.cwd_host),
        .title_range = ownedRange(projection.window_title),
        .ssh_range = if (projection.ssh_remote_dest_present_raw == 1)
            ownedRange(projection.ssh_remote_dest)
        else
            null,
        .clipboard_target_range = ownedRange(projection.clipboard_read_target),
        .processes = processes,
        .process_count = projection.process_count,
    };
}

fn ownedRange(range: runtime_event_preparation.FilledRange) OwnedMetadataDto.Range {
    return .{ .start = range.start, .len = range.len };
}

fn copySpan(
    backing: ?[]u8,
    offset: *usize,
    payload: []const u8,
    span: runtime_event_wire.StringSpan,
) DecodeError!OwnedMetadataDto.Range {
    const result: OwnedMetadataDto.Range = .{ .start = offset.*, .len = span.decoded_len };
    if (span.decoded_len > 0) {
        runtime_event_wire.decodeStringExact(
            payload,
            span,
            backing.?[offset.*..][0..span.decoded_len],
        ) catch return error.Malformed;
        offset.* += span.decoded_len;
    }
    return result;
}

fn optionalStringEql(a: ?[]const u8, b: ?[]const u8) bool {
    if (a == null or b == null) return a == null and b == null;
    return std.mem.eql(u8, a.?, b.?);
}

fn testMetadataEvent(
    allocator: std.mem.Allocator,
    foreground_available: bool,
    processes: []const u8,
    extra_metadata: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":{},\"foreground_pgid\":7,\"processes\":[{s}]{s}}}}}",
        .{ foreground_available, processes, extra_metadata },
    );
}

test "runtime metadata wire owns current metadata event projection" {
    const allocator = std.testing.allocator;
    var seed = try decodeMetadataEvent(
        allocator,
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":7,\"processes\":[{\"pid\":7,\"name\":\"zsh\"}]}}",
        .supported,
    );
    defer seed.deinit();
    const dto = &seed.current;
    try std.testing.expectEqual(@as(u64, 2), dto.revision);
    try std.testing.expectEqualStrings("/repo", dto.cwd());
    try std.testing.expectEqualStrings("zsh", dto.foregroundProcesses()[0].slice());
    for (dto.foregroundProcesses()[0].bytes[3..]) |byte| try std.testing.expectEqual(@as(u8, 0), byte);
}

test "metadata wire: child_pid/host_pid는 실려 오면 그대로, 구 host면 0이다" {
    // 이 테스트가 증명하는 것: 상태바 리소스 항목이 host-backed 터미널을 재는 **유일한 뿌리**가 이 두
    // 스칼라다(docs/status-bar.md §4.1). 값이 흐르지 않으면 그 탭이 조용히 `—`로 남고, 반대로 이 키를
    // 필수로 만들면 **구 host의 관측 전체가 Malformed**가 되어 터미널이 아예 안 뜬다 — 둘 다 화면에서만
    // 드러나는 종류라 wire 층에서 못박는다(docs/session-host-upgrade.md §3 "관측 metadata에 스칼라를 더할 때").
    const allocator = std.testing.allocator;

    const with_pids =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"/repo","window_title":"w","ssh_remote_dest":null,
        \\"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,
        \\"foreground_available":false,"foreground_pgid":null,"child_pid":4242,"host_pid":99,"processes":[]}}
    ;
    var decoded = try decodeMetadataEvent(allocator, with_pids, .supported);
    defer decoded.deinit();
    try std.testing.expectEqual(@as(i32, 4242), decoded.current.child_pid);
    try std.testing.expectEqual(@as(i32, 99), decoded.current.host_pid);

    // 구 host: 키 자체가 없다. `Malformed`가 아니라 0이어야 한다 — 0은 "모른다"이고 소비자는 그때
    // 표본을 못 얻는 것으로 다룬다(0을 그리면 "0바이트를 쓰는 중"이라는 거짓말이 된다).
    const legacy =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"/repo","window_title":"w","ssh_remote_dest":null,
        \\"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,
        \\"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var old = try decodeMetadataEvent(allocator, legacy, .supported);
    defer old.deinit();
    try std.testing.expectEqual(@as(i32, 0), old.current.child_pid);
    try std.testing.expectEqual(@as(i32, 0), old.current.host_pid);

    // pid는 **foreground 가용성과 무관**하다 — foreground 조회가 실패해도 PTY 뿌리는 그대로 있다.
    // 위 두 payload가 모두 `foreground_available:false`인데 첫 번째가 pid를 살려 낸 것이 그 증거다.
    try std.testing.expect(!decoded.current.foreground_available);
}

test "runtime metadata seal inventory covers every OwnedMetadataDto field" {
    // The three seal functions (descriptor, structure, semantic digest) enumerate these fields by
    // hand. A new field — especially a second heap slice — would otherwise slip past the seal and
    // desynchronise the exact-once cleanup mirror without any compile error. This list is the
    // reminder: extend the seal, then extend this list.
    const expected = [_][]const u8{
        "allocator",           "backing",
        "revision",            "observer_generation",
        "title_generation",    "cols",
        "rows",                "semantic_state",
        "alt_active",          "app_cursor_keys",
        "app_keypad",          "kitty_flags",
        "alternate_scroll",    "mouse_tracking",
        "mouse_tracking_mode", "bracketed_paste",
        "bell_count",          "clipboard_write_seq",
        "clipboard_read_seq",  "foreground_available",
        "foreground_pgid",     "child_pid",
        "host_pid",            "cwd_range",
        "cwd_host_range",      "title_range",
        "ssh_range",           "clipboard_target_range",
        "processes",           "process_count",
    };
    const fields = @typeInfo(OwnedMetadataDto).@"struct".fields;
    try std.testing.expectEqual(expected.len, fields.len);
    inline for (fields, expected) |field, name|
        try std.testing.expectEqualStrings(name, field.name);
}

test "K1 cwd authority is optional strict and owned beside cwd" {
    const allocator = std.testing.allocator;
    const with_authority =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","cwd_host":"devbox","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":2,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var current = try decodeMetadataEvent(allocator, with_authority, .supported);
    defer current.deinit();
    try std.testing.expectEqualStrings("/repo", current.current.cwd());
    try std.testing.expectEqualStrings("devbox", current.current.cwdHost());

    const legacy =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":2,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var old = try decodeMetadataEvent(allocator, legacy, .supported);
    defer old.deinit();
    try std.testing.expectEqualStrings("", old.current.cwdHost());

    const wrong_type =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","cwd_host":7,"window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":2,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    try std.testing.expectError(error.Malformed, decodeMetadataEvent(allocator, wrong_type, .supported));

    const duplicate =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","cwd_host":"a","cwd_host":"b","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":2,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    try std.testing.expectError(error.Malformed, decodeMetadataEvent(allocator, duplicate, .supported));

    const authority_without_cwd =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"","cwd_host":"devbox","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":2,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    try std.testing.expectError(error.Malformed, decodeMetadataEvent(allocator, authority_without_cwd, .supported));
}

test "external metadata footprint charges cwd authority bytes" {
    const payload =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo","cwd_host":"devbox","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":2,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    const preflight = switch (runtime_event_wire.preflightEvent(
        payload,
        .{ .stream_id = 1 },
    )) {
        .accepted => |accepted| accepted,
        else => return error.TestUnexpectedResult,
    };
    const footprint = try preflightEventMaterialization(payload, preflight);
    try std.testing.expectEqual(@as(usize, 5 + 6 + 4), footprint.backing_bytes);
    try std.testing.expectEqual(
        @sizeOf(OwnedMetadataDto) + footprint.backing_bytes,
        footprint.resident_bytes,
    );
}

test "runtime metadata transfer seal binds address descriptor raw bytes scalars and processes" {
    const allocator = std.testing.allocator;
    var seed = try decodeMetadataEvent(
        allocator,
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":7,\"processes\":[{\"pid\":7,\"name\":\"zsh\"}]}}",
        .supported,
    );
    defer seed.deinit();
    const seal = try sealMetadataSeed(&seed);
    try std.testing.expect(validateMetadataSeedSeal(seal, &seed));

    seed.current.backing.?[0] = 'X';
    try std.testing.expect(!validateMetadataSeedSeal(seal, &seed));
    seed.current.backing.?[0] = '/';
    seed.current.cols += 1;
    try std.testing.expect(!validateMetadataSeedSeal(seal, &seed));
    seed.current.cols -= 1;
    seed.current.processes[0].bytes[0] = 'Z';
    try std.testing.expect(!validateMetadataSeedSeal(seal, &seed));
    seed.current.processes[0].bytes[0] = 'z';
    try std.testing.expect(validateMetadataSeedSeal(seal, &seed));

    var copied = seed;
    try std.testing.expect(!validateMetadataSeedSeal(seal, &copied));
    copied = .unavailable; // the original seed remains the sole owner.
    seed.current.revision = 0;
    try std.testing.expectError(error.Malformed, sealMetadataSeed(&seed));
    seed.current.revision = 2;
}

test "runtime metadata transfer seal keeps unsupported unavailable and null backing distinct" {
    var unsupported: InitialMetadataSeed = .unsupported;
    var unavailable: InitialMetadataSeed = .unavailable;
    const unsupported_seal = try sealMetadataSeed(&unsupported);
    const unavailable_seal = try sealMetadataSeed(&unavailable);
    try std.testing.expectEqual(MetadataSeedTag.unsupported, unsupported_seal.tag);
    try std.testing.expectEqual(MetadataSeedTag.unavailable, unavailable_seal.tag);
    try std.testing.expect(!std.meta.eql(unsupported_seal, unavailable_seal));
    try std.testing.expect(validateMetadataSeedSeal(unsupported_seal, &unsupported));
    try std.testing.expect(validateMetadataSeedSeal(unavailable_seal, &unavailable));
}

test "runtime metadata wire decodes attach error and accepted envelope exactly once" {
    const allocator = std.testing.allocator;
    var wire_error = try decodeAttachEnvelope(
        allocator,
        "{\"error\":\"runtime_not_found\"}",
        .{
            .generation_schema = .granted_with_generation,
            .metadata_support = .supported,
        },
    );
    defer wire_error.deinit();
    try std.testing.expectEqual(protocol.ErrorCode.runtime_not_found, wire_error.wire_error);

    var unsupported = try decodeAttachEnvelope(
        allocator,
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true}}",
        .{
            .generation_schema = .granted_with_generation,
            .metadata_support = .unsupported,
        },
    );
    defer unsupported.deinit();
    try std.testing.expectEqual(InitialMetadataSeed.unsupported, unsupported.accepted.initial_metadata);

    var unavailable = try decodeAttachEnvelope(
        allocator,
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true,\"metadata_revision\":0,\"metadata\":null}}",
        .{
            .generation_schema = .granted_with_generation,
            .metadata_support = .supported,
        },
    );
    defer unavailable.deinit();
    try std.testing.expectEqual(InitialMetadataSeed.unavailable, unavailable.accepted.initial_metadata);
    try std.testing.expectError(
        error.Malformed,
        decodeAttachEnvelope(
            allocator,
            "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true,\"metadata_revision\":0,\"metadata\":null},\"error\":\"internal\"}",
            .{
                .generation_schema = .granted_with_generation,
                .metadata_support = .supported,
            },
        ),
    );

    const current_payload =
        \\{"result":{"stream_id":7,"controller_generation":3,
        \\"granted":{"observe":true,"input":false,"resize":false},"controller_busy":true,
        \\"metadata_revision":4,"metadata":{"cwd":"\/repo","window_title":"work",
        \\"ssh_remote_dest":null,"semantic_state":0,"alt_active":false,
        \\"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,
        \\"title_generation":2,"cols":80,"rows":24,"foreground_available":true,
        \\"foreground_pgid":7,"processes":[{"pid":7,"name":"z\u0073h"}]}}}
    ;
    const current_profile: AttachDecodeProfile = .{
        .generation_schema = .granted_with_generation,
        .metadata_support = .supported,
    };
    var failing = std.testing.FailingAllocator.init(allocator, .{ .fail_index = 0 });
    try std.testing.expectError(
        error.OutOfMemory,
        decodeAttachEnvelope(failing.allocator(), current_payload, current_profile),
    );
    try std.testing.expect(failing.has_induced_failure);

    var counting = std.testing.FailingAllocator.init(allocator, .{});
    var current = try decodeAttachEnvelope(counting.allocator(), current_payload, current_profile);
    defer current.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
    try std.testing.expectEqualStrings("/repo", current.accepted.initial_metadata.current.cwd());
    try std.testing.expectEqualStrings(
        "zsh",
        current.accepted.initial_metadata.current.foregroundProcesses()[0].slice(),
    );

    var malformed_allocator = std.testing.FailingAllocator.init(
        allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.Malformed,
        decodeAttachEnvelope(
            malformed_allocator.allocator(),
            "{\"result\":{\"future\":{\"nested\":true}}}",
            current_profile,
        ),
    );
    try std.testing.expect(!malformed_allocator.has_induced_failure);
}

test "runtime metadata wire rejects profile mismatch and process resource overflow" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.CapabilityViolation,
        decodeMetadataEvent(
            allocator,
            "{\"event\":\"runtime.metadata\"}",
            .unsupported,
        ),
    );

    var process_list: std.Io.Writer.Allocating = .init(allocator);
    defer process_list.deinit();
    for (0..max_process_entries + 1) |index| {
        if (index != 0) try process_list.writer.writeByte(',');
        try process_list.writer.print("{{\"pid\":{d},\"name\":\"p\"}}", .{index});
    }
    const too_many = try testMetadataEvent(allocator, true, process_list.written(), "");
    defer allocator.free(too_many);
    try std.testing.expectError(
        error.ResourceExhausted,
        decodeMetadataEvent(allocator, too_many, .supported),
    );
}

test "runtime metadata wire validates unavailable foreground process schema before canonicalizing" {
    const allocator = std.testing.allocator;
    const long_name = [_]u8{'x'} ** 129;
    const process = try std.fmt.allocPrint(
        allocator,
        "{{\"pid\":7,\"name\":\"{s}\"}}",
        .{&long_name},
    );
    defer allocator.free(process);
    const payload = try testMetadataEvent(allocator, false, process, "");
    defer allocator.free(payload);
    try std.testing.expectError(
        error.ResourceExhausted,
        decodeMetadataEvent(allocator, payload, .supported),
    );

    const nested_unknown = try testMetadataEvent(
        allocator,
        false,
        "{\"pid\":7,\"name\":\"zsh\"}",
        ",\"future\":{\"nested\":true}",
    );
    defer allocator.free(nested_unknown);
    try std.testing.expectError(
        error.Malformed,
        decodeMetadataEvent(allocator, nested_unknown, .supported),
    );
}

test "runtime metadata wire accepts full u64 counters and rejects optional wrong types" {
    const allocator = std.testing.allocator;
    const full = try testMetadataEvent(
        allocator,
        true,
        "{\"pid\":7,\"name\":\"zsh\"}",
        ",\"bell_count\":18446744073709551615,\"clipboard_write_seq\":18446744073709551615,\"clipboard_read_seq\":18446744073709551615",
    );
    defer allocator.free(full);
    var seed = try decodeMetadataEvent(allocator, full, .supported);
    defer seed.deinit();
    try std.testing.expectEqual(std.math.maxInt(u64), seed.current.bell_count);
    try std.testing.expectEqual(std.math.maxInt(u64), seed.current.clipboard_write_seq);
    try std.testing.expectEqual(std.math.maxInt(u64), seed.current.clipboard_read_seq);

    const wrong_optional = try testMetadataEvent(
        allocator,
        true,
        "{\"pid\":7,\"name\":\"zsh\"}",
        ",\"app_keypad\":\"false\"",
    );
    defer allocator.free(wrong_optional);
    try std.testing.expectError(
        error.Malformed,
        decodeMetadataEvent(allocator, wrong_optional, .supported),
    );
}

test "runtime metadata wire preserves mouse mode and applies legacy optional fallbacks" {
    const allocator = std.testing.allocator;
    const parse_mode = struct {
        fn run(a: std.mem.Allocator, extra: []const u8) !u8 {
            const json = try std.fmt.allocPrint(
                a,
                \\{{"event":"runtime.metadata","metadata_revision":2,"metadata":{{"cwd":"/r","window_title":"w","ssh_remote_dest":null,
                \\"semantic_state":3,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"mouse_tracking":true,{s}
                \\"observer_generation":1,"title_generation":1,"cols":80,"rows":24,"foreground_available":false,"foreground_pgid":null,"processes":[]}}}}
            ,
                .{extra},
            );
            defer a.free(json);
            var decoded = try decodeMetadataEvent(a, json, .supported);
            defer decoded.deinit();
            return decoded.current.mouse_tracking_mode;
        }
    }.run;
    try std.testing.expectEqual(
        @as(u8, 4),
        try parse_mode(allocator, "\"mouse_tracking_mode\":4,"),
    );
    try std.testing.expectEqual(
        @as(u8, 2),
        try parse_mode(allocator, "\"mouse_tracking_mode\":2,"),
    );
    // A legacy host with only the boolean maps true to normal rather than inventing any-motion.
    try std.testing.expectEqual(@as(u8, 2), try parse_mode(allocator, ""));

    const legacy =
        \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"/legacy","window_title":"w","ssh_remote_dest":null,
        \\"semantic_state":0,"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":1,"title_generation":1,"cols":80,"rows":24,
        \\"foreground_available":false,"foreground_pgid":null,"processes":[]}}
    ;
    var decoded = try decodeMetadataEvent(allocator, legacy, .supported);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("/legacy", decoded.current.cwd());
    try std.testing.expect(!decoded.current.mouse_tracking);
    try std.testing.expect(!decoded.current.bracketed_paste);
    try std.testing.expect(!decoded.current.app_keypad);
    try std.testing.expectEqual(@as(u5, 0), decoded.current.kitty_flags);
}

test "event preflight materialization decodes escapes with one exact owning allocation" {
    const payload =
        \\{"event":"runtime.metadata","metadata_revision":9,"metadata":{"cwd":"\/repo\u002Fsrc",
        \\"window_title":"한글\nwork","ssh_remote_dest":"host\u003A22","semantic_state":0,
        \\"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,
        \\"observer_generation":4,"title_generation":2,"cols":80,"rows":24,
        \\"foreground_available":true,"foreground_pgid":7,
        \\"processes":[{"pid":7,"name":"z\u0073h"}]}}
    ;
    const accepted = switch (runtime_event_wire.preflightEvent(payload, .{})) {
        .accepted => |accepted| accepted,
        else => return error.TestUnexpectedResult,
    };
    const metadata = switch (accepted.event) {
        .metadata => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const source_digest = runtime_event_wire.payloadDigest(payload);
    const footprint = try preflightEventMaterialization(payload, accepted);
    try std.testing.expectEqual(
        @sizeOf(OwnedMetadataDto) + footprint.backing_bytes,
        footprint.resident_bytes,
    );

    var failing = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.OutOfMemory,
        materializePreflight(
            failing.allocator(),
            payload,
            metadata,
            source_digest,
        ),
    );
    try std.testing.expect(failing.has_induced_failure);

    var counting = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var dto = try materializePreflight(
        counting.allocator(),
        payload,
        metadata,
        source_digest,
    );
    defer dto.deinit();
    try std.testing.expectEqual(@as(usize, 1), counting.allocations);
    try std.testing.expectEqual(@as(u64, 9), dto.revision);
    try std.testing.expectEqualStrings("/repo/src", dto.cwd());
    try std.testing.expectEqualStrings("한글\nwork", dto.windowTitle());
    try std.testing.expectEqualStrings("host:22", dto.sshRemoteDest().?);
    try std.testing.expectEqualStrings("", dto.clipboardReadTarget());
    try std.testing.expectEqual(@as(u8, 1), dto.process_count);
    try std.testing.expectEqualStrings("zsh", dto.processes[0].slice());
    try std.testing.expect(std.mem.allEqual(u8, dto.processes[0].bytes[3..], 0));

    var public_dto = try materializeExactEventMetadata(
        std.testing.allocator,
        payload,
        .{},
        accepted,
    );
    defer public_dto.deinit();
    try std.testing.expect(OwnedMetadataDto.semanticEql(&dto, &public_dto));
    var stale = accepted;
    stale.raw_digest[0] ^= 1;
    try std.testing.expectError(
        error.Malformed,
        preflightEventMaterialization(payload, stale),
    );

    var mutated = payload.*;
    mutated[
        std.mem.indexOf(u8, &mutated, "\"metadata_revision\":9").? +
            "\"metadata_revision\":".len
    ] = '8';
    var source_seal_allocator = std.testing.FailingAllocator.init(
        std.testing.allocator,
        .{ .fail_index = 0 },
    );
    try std.testing.expectError(
        error.Malformed,
        materializePreflight(
            source_seal_allocator.allocator(),
            &mutated,
            metadata,
            source_digest,
        ),
    );
    try std.testing.expect(!source_seal_allocator.has_induced_failure);
}

test "sealed owning metadata seed compares with an exact event view without allocation" {
    const payload =
        \\{"event":"runtime.metadata","metadata_revision":9,"metadata":{"cwd":"\/repo\u002Fsrc",
        \\"window_title":"한글\nwork","ssh_remote_dest":"host\u003A22","semantic_state":0,
        \\"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,
        \\"observer_generation":4,"title_generation":2,"cols":80,"rows":24,
        \\"foreground_available":true,"foreground_pgid":7,
        \\"processes":[{"pid":7,"name":"z\u0073h"}]}}
    ;
    var seed = try decodeMetadataEvent(std.testing.allocator, payload, .supported);
    defer seed.deinit();
    const seal = try sealMetadataSeed(&seed);
    const preflight = switch (runtime_event_wire.preflightEvent(payload, .{})) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const view = switch (preflight.event) {
        .metadata => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(seed.current.revision, view.revision);
    try std.testing.expect(runtime_event_wire.decodedStringSpanEqualsBytes(
        payload,
        view.cwd,
        seed.current.cwd(),
    ));
    try std.testing.expect(runtime_event_wire.decodedStringSpanEqualsBytes(
        payload,
        view.window_title,
        seed.current.windowTitle(),
    ));
    try std.testing.expect(optionalSpanEqualsBytes(
        payload,
        view.ssh_remote_dest,
        seed.current.sshRemoteDest(),
    ));
    try std.testing.expect(runtime_event_wire.decodedStringSpanEqualsBytes(
        payload,
        view.clipboard_read_target,
        seed.current.clipboardReadTarget(),
    ));
    try std.testing.expect(metadataSeedSemanticEqlEvent(
        &seed,
        seal,
        payload,
        preflight,
    ));

    const different =
        \\{"event":"runtime.metadata","metadata_revision":9,"metadata":{"cwd":"/different",
        \\"window_title":"한글\nwork","ssh_remote_dest":"host:22","semantic_state":0,
        \\"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,
        \\"observer_generation":4,"title_generation":2,"cols":80,"rows":24,
        \\"foreground_available":true,"foreground_pgid":7,
        \\"processes":[{"pid":7,"name":"zsh"}]}}
    ;
    const different_preflight = switch (runtime_event_wire.preflightEvent(
        different,
        .{},
    )) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(!metadataSeedSemanticEqlEvent(
        &seed,
        seal,
        different,
        different_preflight,
    ));

    var stale = payload.*;
    stale[std.mem.indexOf(u8, &stale, "repo").?] = 'x';
    try std.testing.expect(!metadataSeedSemanticEqlEvent(
        &seed,
        seal,
        &stale,
        preflight,
    ));
}

test "owned metadata semantic equality ignores poisoned process tail only" {
    const payload =
        \\{"event":"runtime.metadata","metadata_revision":2,"metadata":{"cwd":"/repo",
        \\"window_title":"work","ssh_remote_dest":null,"semantic_state":0,
        \\"alt_active":false,"app_cursor_keys":false,"alternate_scroll":true,
        \\"observer_generation":1,"title_generation":2,"cols":80,"rows":24,
        \\"foreground_available":true,"foreground_pgid":7,
        \\"processes":[{"pid":7,"name":"zsh"}]}}
    ;
    var a = try decodeMetadataEvent(std.testing.allocator, payload, .supported);
    defer a.deinit();
    var b = try decodeMetadataEvent(std.testing.allocator, payload, .supported);
    defer b.deinit();
    b.current.processes[0].bytes[3] = 0xa5;
    b.current.processes[0].bytes[127] = 0x5a;
    try std.testing.expect(a.current.semanticEql(&b.current));
    b.current.processes[0].bytes[1] = 'X';
    try std.testing.expect(!a.current.semanticEql(&b.current));
}

const c3b2b2_identity: runtime_event_types.EventIdentity = .{
    .runtime_id = 0xaa,
    .stream_id = 7,
};
const c3b2b2_controller: runtime_event_types.EventAuthorityView = .{
    .role = .controller,
    .generation = .{ .tracked = 3 },
};
const c3b2b2_metadata_payload =
    \\{"event":"runtime.metadata","metadata_revision":9,"metadata":{"cwd":"/repo/src",
    \\"window_title":"work","ssh_remote_dest":"host:22","semantic_state":2,
    \\"alt_active":true,"app_cursor_keys":true,"app_keypad":true,"kitty_flags":3,
    \\"alternate_scroll":false,"mouse_tracking":true,"mouse_tracking_mode":2,
    \\"bracketed_paste":true,"bell_count":4,"clipboard_write_seq":5,
    \\"clipboard_read_seq":6,"clipboard_read_target":"c",
    \\"observer_generation":7,"title_generation":8,"cols":120,"rows":40,
    \\"foreground_available":true,"foreground_pgid":77,
    \\"processes":[{"pid":77,"name":"codex"}]}}
;
const c3b2b2_empty_metadata_payload =
    \\{"event":"runtime.metadata","metadata_revision":1,"metadata":{"cwd":"",
    \\"window_title":"","ssh_remote_dest":null,"semantic_state":0,
    \\"alt_active":false,"app_cursor_keys":false,"app_keypad":false,"kitty_flags":0,
    \\"alternate_scroll":true,"mouse_tracking":false,"mouse_tracking_mode":0,
    \\"bracketed_paste":false,"bell_count":0,"clipboard_write_seq":0,
    \\"clipboard_read_seq":0,"clipboard_read_target":"",
    \\"observer_generation":1,"title_generation":1,"cols":80,"rows":24,
    \\"foreground_available":false,"foreground_pgid":null,"processes":[]}}
;

fn c3b2b2Frame(payload: []const u8) runtime_event_types.EventFrameView {
    return .{
        .major = protocol.version_major,
        .kind = .event,
        .stream_id = c3b2b2_identity.stream_id,
        .request_id = 0,
        .flags = 0,
        .payload_len = @intCast(payload.len),
        .payload = payload,
    };
}

fn c3b2b2Preflight(payload: []const u8) runtime_event_types.EventPreflightView {
    return .{
        .expected_major = protocol.version_major,
        .metadata_support = .supported,
        .verdict = runtime_event_wire.preflightEvent(payload, .{}),
    };
}

fn c3b2b2Materialize(
    allocator: std.mem.Allocator,
    payload: []const u8,
) EventMaterializationError!OwnedEventClassification {
    return classifyAndMaterializeEvent(
        allocator,
        c3b2b2_identity,
        c3b2b2_controller,
        c3b2b2Preflight(payload),
        c3b2b2Frame(payload),
    );
}

const C3b2b2CountingAllocator = struct {
    parent: std.mem.Allocator,
    allocation_calls: usize = 0,
    free_calls: usize = 0,
    fail_next: bool = false,
    mutate_payload: ?[]u8 = null,
    mutate_index: usize = 0,

    fn allocator(self: *@This()) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn alloc(
        context: *anyopaque,
        len: usize,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.allocation_calls += 1;
        if (self.mutate_payload) |payload| payload[self.mutate_index] ^= 1;
        if (self.fail_next) {
            self.fail_next = false;
            return null;
        }
        return self.parent.vtable.alloc(self.parent.ptr, len, alignment, return_address);
    }

    fn resize(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) bool {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.resize(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn remap(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        new_len: usize,
        return_address: usize,
    ) ?[*]u8 {
        const self: *@This() = @ptrCast(@alignCast(context));
        return self.parent.vtable.remap(
            self.parent.ptr,
            memory,
            alignment,
            new_len,
            return_address,
        );
    }

    fn free(
        context: *anyopaque,
        memory: []u8,
        alignment: std.mem.Alignment,
        return_address: usize,
    ) void {
        const self: *@This() = @ptrCast(@alignCast(context));
        self.free_calls += 1;
        self.parent.vtable.free(self.parent.ptr, memory, alignment, return_address);
    }
};

fn c3b2b2DeinitClassification(value: *OwnedEventClassification) void {
    switch (value.*) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*dto| dto.deinit(),
            else => {},
        },
        .violation => {},
    }
}

fn c3b2b2ExpectForwardedViolation(
    counter: *C3b2b2CountingAllocator,
    expected: runtime_event_types.Violation,
) !void {
    var result = try materializeClassifiedEvent(
        counter.allocator(),
        .{ .violation = expected },
        "violation payload is never reparsed",
    );
    defer c3b2b2DeinitClassification(&result);
    switch (result) {
        .violation => |actual| try std.testing.expect(std.meta.eql(expected, actual)),
        .accepted => return error.TestUnexpectedResult,
    }
}

fn c3b2b2ReplaceFirst(
    allocator: std.mem.Allocator,
    source: []const u8,
    needle: []const u8,
    replacement: []const u8,
) ![]u8 {
    const index = std.mem.indexOf(u8, source, needle) orelse
        return error.TestUnexpectedResult;
    const result = try allocator.alloc(u8, source.len - needle.len + replacement.len);
    @memcpy(result[0..index], source[0..index]);
    @memcpy(result[index..][0..replacement.len], replacement);
    @memcpy(result[index + replacement.len ..], source[index + needle.len ..]);
    return result;
}

const C3b2b2MetadataMutation = enum {
    revision,
    observer_generation,
    title_generation,
    cols,
    rows,
    semantic_state,
    alt_active,
    app_cursor_keys,
    app_keypad,
    kitty_flags,
    alternate_scroll,
    mouse_tracking,
    mouse_tracking_mode,
    bracketed_paste,
    bell_count,
    clipboard_write_seq,
    clipboard_read_seq,
    foreground_pgid,
    cwd,
    window_title,
    ssh_value,
    ssh_presence,
    clipboard_target,
    process_pid,
    process_name,
    process_count,
    foreground_presence,
};

test "C3-3b2b2 compatibility keeps non-metadata accepted and violation allocation-free" {
    const payloads = [_][]const u8{
        "{\"event\":\"snapshot.invalidated\"}",
        "{\"event\":\"runtime.ended\"}",
        "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":120,\"rows\":40,\"resize_generation\":9,\"reason\":\"controller\"}}",
        "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
        "{\"event\":\"future.event\"}",
    };
    var counter: C3b2b2CountingAllocator = .{ .parent = std.testing.allocator };
    for (payloads, 0..) |payload, index| {
        var result = try c3b2b2Materialize(counter.allocator(), payload);
        defer c3b2b2DeinitClassification(&result);
        switch (index) {
            0 => switch (result) {
                .accepted => |accepted| switch (accepted) {
                    .invalidated => {},
                    else => return error.TestUnexpectedResult,
                },
                .violation => return error.TestUnexpectedResult,
            },
            1 => switch (result) {
                .accepted => |accepted| switch (accepted) {
                    .ended => {},
                    else => return error.TestUnexpectedResult,
                },
                .violation => return error.TestUnexpectedResult,
            },
            2 => switch (result) {
                .accepted => |accepted| switch (accepted) {
                    .resized => |resized| {
                        try std.testing.expectEqual(@as(u128, 0xaa), resized.runtime_id);
                        try std.testing.expectEqual(@as(u16, 120), resized.cols);
                        try std.testing.expectEqual(@as(u16, 40), resized.rows);
                        try std.testing.expectEqual(@as(u64, 9), resized.resize_generation);
                    },
                    else => return error.TestUnexpectedResult,
                },
                .violation => return error.TestUnexpectedResult,
            },
            3 => switch (result) {
                .accepted => |accepted| switch (accepted) {
                    .revoked => |generation| try std.testing.expectEqual(@as(u64, 4), generation),
                    else => return error.TestUnexpectedResult,
                },
                .violation => return error.TestUnexpectedResult,
            },
            4 => switch (result) {
                .violation => |violation| switch (violation) {
                    .unknown_event => {},
                    else => return error.TestUnexpectedResult,
                },
                .accepted => return error.TestUnexpectedResult,
            },
            else => unreachable,
        }
    }

    inline for (std.meta.fields(runtime_event_types.FrameViolation)) |field| {
        try c3b2b2ExpectForwardedViolation(
            &counter,
            .{ .frame = @enumFromInt(field.value) },
        );
    }
    inline for (std.meta.fields(runtime_event_types.IdentityViolation)) |field| {
        try c3b2b2ExpectForwardedViolation(
            &counter,
            .{ .identity = @enumFromInt(field.value) },
        );
    }
    inline for (std.meta.fields(runtime_event_types.AuthorityViolation)) |field| {
        try c3b2b2ExpectForwardedViolation(
            &counter,
            .{ .authority = @enumFromInt(field.value) },
        );
    }
    inline for (std.meta.fields(runtime_event_types.CapabilityViolation)) |field| {
        try c3b2b2ExpectForwardedViolation(
            &counter,
            .{ .capability = @enumFromInt(field.value) },
        );
    }
    inline for (std.meta.fields(runtime_event_wire.ForeignKind)) |field| {
        try c3b2b2ExpectForwardedViolation(
            &counter,
            .{ .foreign = @enumFromInt(field.value) },
        );
    }
    try c3b2b2ExpectForwardedViolation(&counter, .stale_preflight);
    try c3b2b2ExpectForwardedViolation(&counter, .unknown_event);
    try c3b2b2ExpectForwardedViolation(&counter, .malformed);
    try c3b2b2ExpectForwardedViolation(&counter, .resource_exhausted);
    try std.testing.expectEqual(@as(usize, 0), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.free_calls);
}

test "C3-3b2b2 compatibility preserves zero or one allocation and metadata semantics" {
    const recipeFor = struct {
        fn build(payload: []const u8) !runtime_event_preparation.MetadataPreparationRecipe {
            const classification = runtime_event_types.classifyEventView(
                c3b2b2_identity,
                c3b2b2_controller,
                c3b2b2Preflight(payload),
                c3b2b2Frame(payload),
            );
            const event_recipe = try runtime_event_preparation.buildEventPreparationRecipe(
                classification,
                payload,
            );
            return switch (event_recipe) {
                .accepted => |accepted| switch (accepted) {
                    .metadata => |metadata| metadata,
                    else => error.TestUnexpectedResult,
                },
                .violation => error.TestUnexpectedResult,
            };
        }
    }.build;
    var counter: C3b2b2CountingAllocator = .{ .parent = std.testing.allocator };
    var empty = try c3b2b2Materialize(counter.allocator(), c3b2b2_empty_metadata_payload);
    defer c3b2b2DeinitClassification(&empty);
    try std.testing.expectEqual(@as(usize, 0), counter.allocation_calls);
    const empty_dto = switch (empty) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*dto| dto,
            else => return error.TestUnexpectedResult,
        },
        .violation => return error.TestUnexpectedResult,
    };
    try std.testing.expect(empty_dto.backing == null);
    try std.testing.expectEqual(@as(u64, 1), empty_dto.revision);
    try std.testing.expectEqual(@as(u64, 1), empty_dto.observer_generation);
    try std.testing.expectEqual(@as(u32, 1), empty_dto.title_generation);
    try std.testing.expectEqual(@as(u16, 80), empty_dto.cols);
    try std.testing.expectEqual(@as(u16, 24), empty_dto.rows);
    try std.testing.expectEqual(SemanticPrompt.unknown, empty_dto.semantic_state);
    try std.testing.expect(!empty_dto.alt_active);
    try std.testing.expect(!empty_dto.app_cursor_keys);
    try std.testing.expect(!empty_dto.app_keypad);
    try std.testing.expectEqual(@as(u5, 0), empty_dto.kitty_flags);
    try std.testing.expect(empty_dto.alternate_scroll);
    try std.testing.expect(!empty_dto.mouse_tracking);
    try std.testing.expectEqual(@as(u8, 0), empty_dto.mouse_tracking_mode);
    try std.testing.expect(!empty_dto.bracketed_paste);
    try std.testing.expectEqual(@as(u64, 0), empty_dto.bell_count);
    try std.testing.expectEqual(@as(u64, 0), empty_dto.clipboard_write_seq);
    try std.testing.expectEqual(@as(u64, 0), empty_dto.clipboard_read_seq);
    try std.testing.expect(!empty_dto.foreground_available);
    try std.testing.expectEqual(@as(?i32, null), empty_dto.foreground_pgid);
    try std.testing.expectEqualStrings("", empty_dto.cwd());
    try std.testing.expectEqualStrings("", empty_dto.windowTitle());
    try std.testing.expect(empty_dto.sshRemoteDest() == null);
    try std.testing.expectEqualStrings("", empty_dto.clipboardReadTarget());
    try std.testing.expectEqual(@as(u8, 0), empty_dto.process_count);
    try std.testing.expectEqual(@as(usize, 0), empty_dto.foregroundProcesses().len);

    var populated = try c3b2b2Materialize(counter.allocator(), c3b2b2_metadata_payload);
    try std.testing.expectEqual(@as(usize, 1), counter.allocation_calls);
    const dto = switch (populated) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*value| value,
            else => return error.TestUnexpectedResult,
        },
        .violation => return error.TestUnexpectedResult,
    };
    try std.testing.expect(dto.backing != null);
    try std.testing.expectEqual(@as(u64, 9), dto.revision);
    try std.testing.expectEqual(@as(u64, 7), dto.observer_generation);
    try std.testing.expectEqual(@as(u32, 8), dto.title_generation);
    try std.testing.expectEqual(@as(u16, 120), dto.cols);
    try std.testing.expectEqual(@as(u16, 40), dto.rows);
    try std.testing.expectEqual(SemanticPrompt.input, dto.semantic_state);
    try std.testing.expect(dto.alt_active);
    try std.testing.expect(dto.app_cursor_keys);
    try std.testing.expect(dto.app_keypad);
    try std.testing.expectEqual(@as(u5, 3), dto.kitty_flags);
    try std.testing.expect(!dto.alternate_scroll);
    try std.testing.expect(dto.mouse_tracking);
    try std.testing.expectEqual(@as(u8, 2), dto.mouse_tracking_mode);
    try std.testing.expect(dto.bracketed_paste);
    try std.testing.expectEqual(@as(u64, 4), dto.bell_count);
    try std.testing.expectEqual(@as(u64, 5), dto.clipboard_write_seq);
    try std.testing.expectEqual(@as(u64, 6), dto.clipboard_read_seq);
    try std.testing.expect(dto.foreground_available);
    try std.testing.expectEqual(@as(?i32, 77), dto.foreground_pgid);
    try std.testing.expectEqualStrings("/repo/src", dto.cwd());
    try std.testing.expectEqualStrings("work", dto.windowTitle());
    try std.testing.expectEqualStrings("host:22", dto.sshRemoteDest().?);
    try std.testing.expectEqualStrings("c", dto.clipboardReadTarget());
    try std.testing.expectEqual(@as(u8, 1), dto.process_count);
    try std.testing.expectEqual(@as(i32, 77), dto.processes[0].pid);
    try std.testing.expectEqualStrings("codex", dto.processes[0].slice());

    var transferred = dto.take();
    c3b2b2DeinitClassification(&populated);
    try std.testing.expectEqual(@as(usize, 0), counter.free_calls);
    transferred.deinit();
    try std.testing.expectEqual(@as(usize, 1), counter.free_calls);
    transferred.deinit();
    try std.testing.expectEqual(@as(usize, 1), counter.free_calls);

    const baseline_recipe = try recipeFor(c3b2b2_metadata_payload);
    var baseline = try c3b2b2Materialize(std.testing.allocator, c3b2b2_metadata_payload);
    defer c3b2b2DeinitClassification(&baseline);
    const baseline_dto = switch (baseline) {
        .accepted => |*accepted| switch (accepted.*) {
            .metadata => |*value| value,
            else => return error.TestUnexpectedResult,
        },
        .violation => return error.TestUnexpectedResult,
    };
    const mutations = .{
        .{ C3b2b2MetadataMutation.revision, "\"metadata_revision\":9", "\"metadata_revision\":8" },
        .{ C3b2b2MetadataMutation.observer_generation, "\"observer_generation\":7", "\"observer_generation\":6" },
        .{ C3b2b2MetadataMutation.title_generation, "\"title_generation\":8", "\"title_generation\":7" },
        .{ C3b2b2MetadataMutation.cols, "\"cols\":120", "\"cols\":121" },
        .{ C3b2b2MetadataMutation.rows, "\"rows\":40", "\"rows\":41" },
        .{ C3b2b2MetadataMutation.semantic_state, "\"semantic_state\":2", "\"semantic_state\":1" },
        .{ C3b2b2MetadataMutation.alt_active, "\"alt_active\":true", "\"alt_active\":false" },
        .{ C3b2b2MetadataMutation.app_cursor_keys, "\"app_cursor_keys\":true", "\"app_cursor_keys\":false" },
        .{ C3b2b2MetadataMutation.app_keypad, "\"app_keypad\":true", "\"app_keypad\":false" },
        .{ C3b2b2MetadataMutation.kitty_flags, "\"kitty_flags\":3", "\"kitty_flags\":4" },
        .{ C3b2b2MetadataMutation.alternate_scroll, "\"alternate_scroll\":false", "\"alternate_scroll\":true" },
        .{ C3b2b2MetadataMutation.mouse_tracking, "\"mouse_tracking\":true", "\"mouse_tracking\":false" },
        .{ C3b2b2MetadataMutation.mouse_tracking_mode, "\"mouse_tracking_mode\":2", "\"mouse_tracking_mode\":3" },
        .{ C3b2b2MetadataMutation.bracketed_paste, "\"bracketed_paste\":true", "\"bracketed_paste\":false" },
        .{ C3b2b2MetadataMutation.bell_count, "\"bell_count\":4", "\"bell_count\":14" },
        .{ C3b2b2MetadataMutation.clipboard_write_seq, "\"clipboard_write_seq\":5", "\"clipboard_write_seq\":15" },
        .{ C3b2b2MetadataMutation.clipboard_read_seq, "\"clipboard_read_seq\":6", "\"clipboard_read_seq\":16" },
        .{ C3b2b2MetadataMutation.foreground_pgid, "\"foreground_pgid\":77", "\"foreground_pgid\":78" },
        .{ C3b2b2MetadataMutation.cwd, "\"cwd\":\"/repo/src\"", "\"cwd\":\"/repo/bin\"" },
        .{ C3b2b2MetadataMutation.window_title, "\"window_title\":\"work\"", "\"window_title\":\"task\"" },
        .{ C3b2b2MetadataMutation.ssh_value, "\"ssh_remote_dest\":\"host:22\"", "\"ssh_remote_dest\":\"host:23\"" },
        .{ C3b2b2MetadataMutation.ssh_presence, "\"ssh_remote_dest\":\"host:22\"", "\"ssh_remote_dest\":null" },
        .{ C3b2b2MetadataMutation.clipboard_target, "\"clipboard_read_target\":\"c\"", "\"clipboard_read_target\":\"d\"" },
        .{ C3b2b2MetadataMutation.process_pid, "{\"pid\":77,\"name\":\"codex\"}", "{\"pid\":78,\"name\":\"codex\"}" },
        .{ C3b2b2MetadataMutation.process_name, "\"name\":\"codex\"", "\"name\":\"codec\"" },
        .{ C3b2b2MetadataMutation.process_count, "\"processes\":[{\"pid\":77,\"name\":\"codex\"}]", "\"processes\":[{\"pid\":77,\"name\":\"codex\"},{\"pid\":78,\"name\":\"zsh\"}]" },
        // Availability semantically canonicalizes supplied pgid/process values into one closed family.
        .{ C3b2b2MetadataMutation.foreground_presence, "\"foreground_available\":true", "\"foreground_available\":false" },
    };
    inline for (mutations) |mutation| {
        const variant_payload = try c3b2b2ReplaceFirst(
            std.testing.allocator,
            c3b2b2_metadata_payload,
            mutation[1],
            mutation[2],
        );
        defer std.testing.allocator.free(variant_payload);
        const variant_recipe = try recipeFor(variant_payload);
        var variant = try c3b2b2Materialize(std.testing.allocator, variant_payload);
        defer c3b2b2DeinitClassification(&variant);
        const variant_dto = switch (variant) {
            .accepted => |*accepted| switch (accepted.*) {
                .metadata => |*value| value,
                else => return error.TestUnexpectedResult,
            },
            .violation => return error.TestUnexpectedResult,
        };
        try std.testing.expect(!std.meta.eql(baseline_recipe, variant_recipe));
        try std.testing.expect(!baseline_dto.semanticEql(variant_dto));
        switch (mutation[0]) {
            .revision => {
                try std.testing.expectEqual(@as(u64, 8), variant_recipe.revision);
                try std.testing.expectEqual(@as(u64, 8), variant_dto.revision);
            },
            .observer_generation => {
                try std.testing.expectEqual(@as(u64, 6), variant_recipe.observer_generation);
                try std.testing.expectEqual(@as(u64, 6), variant_dto.observer_generation);
            },
            .title_generation => {
                try std.testing.expectEqual(@as(u32, 7), variant_recipe.title_generation);
                try std.testing.expectEqual(@as(u32, 7), variant_dto.title_generation);
            },
            .cols => {
                try std.testing.expectEqual(@as(u16, 121), variant_recipe.cols);
                try std.testing.expectEqual(@as(u16, 121), variant_dto.cols);
            },
            .rows => {
                try std.testing.expectEqual(@as(u16, 41), variant_recipe.rows);
                try std.testing.expectEqual(@as(u16, 41), variant_dto.rows);
            },
            .semantic_state => {
                try std.testing.expectEqual(@as(u8, 1), variant_recipe.semantic_state_raw);
                try std.testing.expectEqual(SemanticPrompt.prompt, variant_dto.semantic_state);
            },
            .alt_active => {
                try std.testing.expectEqual(@as(u8, 0), variant_recipe.alt_active_raw);
                try std.testing.expect(!variant_dto.alt_active);
            },
            .app_cursor_keys => {
                try std.testing.expectEqual(@as(u8, 0), variant_recipe.app_cursor_keys_raw);
                try std.testing.expect(!variant_dto.app_cursor_keys);
            },
            .app_keypad => {
                try std.testing.expectEqual(@as(u8, 0), variant_recipe.app_keypad_raw);
                try std.testing.expect(!variant_dto.app_keypad);
            },
            .kitty_flags => {
                try std.testing.expectEqual(@as(u8, 4), variant_recipe.kitty_flags_raw);
                try std.testing.expectEqual(@as(u5, 4), variant_dto.kitty_flags);
            },
            .alternate_scroll => {
                try std.testing.expectEqual(@as(u8, 1), variant_recipe.alternate_scroll_raw);
                try std.testing.expect(variant_dto.alternate_scroll);
            },
            .mouse_tracking => {
                try std.testing.expectEqual(@as(u8, 0), variant_recipe.mouse_tracking_raw);
                try std.testing.expect(!variant_dto.mouse_tracking);
            },
            .mouse_tracking_mode => {
                try std.testing.expectEqual(@as(u8, 3), variant_recipe.mouse_tracking_mode);
                try std.testing.expectEqual(@as(u8, 3), variant_dto.mouse_tracking_mode);
            },
            .bracketed_paste => {
                try std.testing.expectEqual(@as(u8, 0), variant_recipe.bracketed_paste_raw);
                try std.testing.expect(!variant_dto.bracketed_paste);
            },
            .bell_count => {
                try std.testing.expectEqual(@as(u64, 14), variant_recipe.bell_count);
                try std.testing.expectEqual(@as(u64, 14), variant_dto.bell_count);
            },
            .clipboard_write_seq => {
                try std.testing.expectEqual(@as(u64, 15), variant_recipe.clipboard_write_seq);
                try std.testing.expectEqual(@as(u64, 15), variant_dto.clipboard_write_seq);
            },
            .clipboard_read_seq => {
                try std.testing.expectEqual(@as(u64, 16), variant_recipe.clipboard_read_seq);
                try std.testing.expectEqual(@as(u64, 16), variant_dto.clipboard_read_seq);
            },
            .foreground_pgid => {
                try std.testing.expectEqual(@as(i32, 78), variant_recipe.foreground_pgid);
                try std.testing.expectEqual(@as(?i32, 78), variant_dto.foreground_pgid);
            },
            .cwd => {
                try std.testing.expect(!std.mem.eql(u8, &baseline_recipe.cwd.digest, &variant_recipe.cwd.digest));
                try std.testing.expectEqualStrings("/repo/bin", variant_dto.cwd());
            },
            .window_title => {
                try std.testing.expect(!std.mem.eql(u8, &baseline_recipe.window_title.digest, &variant_recipe.window_title.digest));
                try std.testing.expectEqualStrings("task", variant_dto.windowTitle());
            },
            .ssh_value => {
                try std.testing.expect(!std.mem.eql(u8, &baseline_recipe.ssh_remote_dest.digest, &variant_recipe.ssh_remote_dest.digest));
                try std.testing.expectEqualStrings("host:23", variant_dto.sshRemoteDest().?);
            },
            .ssh_presence => {
                try std.testing.expectEqual(@as(u8, 0), variant_recipe.ssh_remote_dest_present_raw);
                try std.testing.expect(variant_dto.sshRemoteDest() == null);
            },
            .clipboard_target => {
                try std.testing.expect(!std.mem.eql(u8, &baseline_recipe.clipboard_read_target.digest, &variant_recipe.clipboard_read_target.digest));
                try std.testing.expectEqualStrings("d", variant_dto.clipboardReadTarget());
            },
            .process_pid => {
                try std.testing.expectEqual(@as(i32, 78), variant_recipe.processes[0].pid);
                try std.testing.expectEqual(@as(i32, 78), variant_dto.processes[0].pid);
            },
            .process_name => {
                try std.testing.expect(!std.mem.eql(u8, &baseline_recipe.processes[0].name_digest, &variant_recipe.processes[0].name_digest));
                try std.testing.expectEqualStrings("codec", variant_dto.processes[0].slice());
            },
            .process_count => {
                try std.testing.expectEqual(@as(u8, 2), variant_recipe.process_count);
                try std.testing.expectEqual(@as(u8, 2), variant_dto.process_count);
                try std.testing.expectEqual(@as(i32, 78), variant_dto.processes[1].pid);
                try std.testing.expectEqualStrings("zsh", variant_dto.processes[1].slice());
            },
            .foreground_presence => {
                try std.testing.expectEqual(@as(u8, 0), variant_recipe.foreground_available_raw);
                try std.testing.expectEqual(@as(u8, 0), variant_recipe.foreground_pgid_present_raw);
                try std.testing.expectEqual(@as(u8, 0), variant_recipe.process_count);
                try std.testing.expect(!variant_dto.foreground_available);
                try std.testing.expectEqual(@as(?i32, null), variant_dto.foreground_pgid);
                try std.testing.expectEqual(@as(u8, 0), variant_dto.process_count);
            },
        }
    }
}

test "C3-3b2b2 compatibility reports OOM only at the owning allocation" {
    var counter: C3b2b2CountingAllocator = .{
        .parent = std.testing.allocator,
        .fail_next = true,
    };
    try std.testing.expectError(
        error.OutOfMemory,
        c3b2b2Materialize(counter.allocator(), c3b2b2_metadata_payload),
    );
    try std.testing.expectEqual(@as(usize, 1), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.free_calls);
}

test "C3-3b2b2 compatibility rejects allocator callback scalar and string drift locally" {
    var payload = c3b2b2_metadata_payload.*;
    const revision = std.mem.indexOf(u8, &payload, "metadata_revision\":9").? +
        "metadata_revision\":".len;
    var counter: C3b2b2CountingAllocator = .{
        .parent = std.testing.allocator,
        .mutate_payload = &payload,
        .mutate_index = revision,
    };
    try std.testing.expectError(
        error.LocalInvariant,
        c3b2b2Materialize(counter.allocator(), &payload),
    );
    try std.testing.expectEqual(@as(usize, 1), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 1), counter.free_calls);

    var string_payload = c3b2b2_metadata_payload.*;
    const cwd_byte = std.mem.indexOf(u8, &string_payload, "/repo/src").? + 1;
    var string_counter: C3b2b2CountingAllocator = .{
        .parent = std.testing.allocator,
        .mutate_payload = &string_payload,
        .mutate_index = cwd_byte,
    };
    try std.testing.expectError(
        error.LocalInvariant,
        c3b2b2Materialize(string_counter.allocator(), &string_payload),
    );
    try std.testing.expectEqual(@as(usize, 1), string_counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 1), string_counter.free_calls);
}

test "C3-3b2b2 compatibility separates peer violation from forged local provenance" {
    var counter: C3b2b2CountingAllocator = .{ .parent = std.testing.allocator };
    const malformed = "{\"event\":\"runtime.metadata\",\"metadata\":";
    var peer = try classifyAndMaterializeEvent(
        counter.allocator(),
        c3b2b2_identity,
        c3b2b2_controller,
        .{
            .expected_major = protocol.version_major,
            .metadata_support = .supported,
            .verdict = .malformed,
        },
        c3b2b2Frame(malformed),
    );
    defer c3b2b2DeinitClassification(&peer);
    switch (peer) {
        .violation => |violation| try std.testing.expectEqual(
            .malformed,
            std.meta.activeTag(violation),
        ),
        .accepted => return error.TestUnexpectedResult,
    }

    var forged = c3b2b2Preflight(c3b2b2_metadata_payload);
    switch (forged.verdict) {
        .accepted => |*accepted| switch (accepted.event) {
            .metadata => |*value| value.revision += 1,
            else => return error.TestUnexpectedResult,
        },
        else => return error.TestUnexpectedResult,
    }
    try std.testing.expectError(
        error.LocalInvariant,
        classifyAndMaterializeEvent(
            counter.allocator(),
            c3b2b2_identity,
            c3b2b2_controller,
            forged,
            c3b2b2Frame(c3b2b2_metadata_payload),
        ),
    );
    try std.testing.expectEqual(@as(usize, 0), counter.allocation_calls);
    try std.testing.expectEqual(@as(usize, 0), counter.free_calls);
}
