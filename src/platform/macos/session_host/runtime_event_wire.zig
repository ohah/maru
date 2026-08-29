//! Allocation-free preflight for the five runtime event envelopes.
//!
//! This leaf deliberately knows neither `framing.Frame` nor Client/pump ownership. Callers pass
//! immutable payload bytes plus optional stream/runtime evidence. The returned spans borrow those
//! bytes and are valid only while the payload remains unchanged.

const std = @import("std");
const protocol = @import("protocol.zig");
const resize_wire = @import("resize_wire.zig");
const runtime_metadata_types = @import("runtime_metadata_types.zig");

pub const attach_preflight_scratch_bytes: usize = 8 * 1024;
pub const event_preflight_scratch_bytes: usize = attach_preflight_scratch_bytes;
pub const max_depth: usize = 32;
pub const max_attach_fields: usize = 64;
pub const max_event_fields: usize = 64;
pub const max_metadata_fields: usize = runtime_metadata_types.max_metadata_fields;
pub const max_process_entries: usize = runtime_metadata_types.max_process_entries;
pub const max_process_fields: usize = runtime_metadata_types.max_process_fields;

const Sha256 = std.crypto.hash.sha2.Sha256;
pub const Digest = [Sha256.digest_length]u8;

pub fn payloadDigest(payload: []const u8) Digest {
    return sha(payload);
}

/// Canonical compact commitment to an accepted ingress result. `raw_digest` binds the exact
/// payload while the normalized event projection makes a later parser/result drift observable.
pub fn eventPreflightProjectionDigest(value: EventPreflight) Digest {
    var hasher = Sha256.init(.{});
    hasher.update("runtime-event-preflight-projection.v1");
    hasher.update(&value.raw_digest);
    const tag = @intFromEnum(std.meta.activeTag(value.event));
    hasher.update(std.mem.asBytes(&tag));
    switch (value.event) {
        .revoked => |event| {
            hasher.update(std.mem.asBytes(&event.runtime_id));
            hasher.update(std.mem.asBytes(&event.stream_id));
            hasher.update(std.mem.asBytes(&event.controller_generation));
        },
        .resized => |event| {
            hasher.update(std.mem.asBytes(&event.runtime_id));
            hasher.update(std.mem.asBytes(&event.cols));
            hasher.update(std.mem.asBytes(&event.rows));
            hasher.update(std.mem.asBytes(&event.resize_generation));
        },
        .metadata => |event| {
            hasher.update(&event.semantic_digest);
            const present: u8 = @intFromBool(event.observation_probe_nonce != null);
            hasher.update(&.{present});
            if (event.observation_probe_nonce) |nonce| hasher.update(std.mem.asBytes(&nonce));
        },
        .invalidated, .ended => {},
    }
    var digest: Digest = undefined;
    hasher.final(&digest);
    return digest;
}

/// Exact equality for a stored allocation-free parse result.
///
/// `EventPreflight` contains fixed-capacity process storage whose unused tail is deliberately
/// unspecified. Comparing the struct bytes (or `std.meta.eql` over the whole array) would read
/// that tail and turn a harmless implementation detail into an admission decision. This helper
/// compares every admitted scalar/span and only the initialized process prefix, so Client can
/// seal a preflight beside its payload without reparsing it.
pub fn eventPreflightEql(a: EventPreflight, b: EventPreflight) bool {
    if (!std.mem.eql(u8, &a.raw_digest, &b.raw_digest)) return false;
    if (std.meta.activeTag(a.event) != std.meta.activeTag(b.event)) return false;
    return switch (a.event) {
        .revoked => |value| std.meta.eql(value, b.event.revoked),
        .invalidated => true,
        .resized => |value| std.meta.eql(value, b.event.resized),
        .ended => true,
        .metadata => |value| metadataViewEql(value, b.event.metadata),
    };
}

fn metadataViewEql(a: MetadataView, b: MetadataView) bool {
    if (a.process_count > max_process_entries or b.process_count > max_process_entries)
        return false;
    if (a.revision != b.revision or
        a.observation_probe_nonce != b.observation_probe_nonce or
        !std.meta.eql(a.cwd, b.cwd) or
        !std.meta.eql(a.cwd_host, b.cwd_host) or
        !std.meta.eql(a.window_title, b.window_title) or
        !std.meta.eql(a.ssh_remote_dest, b.ssh_remote_dest) or
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
        !std.meta.eql(a.clipboard_read_target, b.clipboard_read_target) or
        a.observer_generation != b.observer_generation or
        a.title_generation != b.title_generation or
        a.cols != b.cols or
        a.rows != b.rows or
        a.foreground_available != b.foreground_available or
        a.foreground_pgid != b.foreground_pgid or
        a.child_pid != b.child_pid or
        a.host_pid != b.host_pid or
        a.process_count != b.process_count or
        !std.mem.eql(u8, &a.semantic_digest, &b.semantic_digest))
        return false;
    for (a.foregroundProcesses(), b.foregroundProcesses()) |a_process, b_process|
        if (!std.meta.eql(a_process, b_process)) return false;
    return true;
}

/// Digest injection changes only the prefilter. Exact duplicate-key and metadata comparisons must
/// still replay decoded bytes, which makes collision tests non-vacuous.
const DigestOps = struct {
    context: ?*anyopaque = null,
    finish_key: *const fn (?*anyopaque, Digest) Digest = identityDigest,
    finish_semantic: *const fn (?*anyopaque, Digest) Digest = identityDigest,

    pub const production: DigestOps = .{};
};

fn identityDigest(_: ?*anyopaque, digest: Digest) Digest {
    return digest;
}

pub const ExpectedIdentity = struct {
    runtime_id: ?u128 = null,
    stream_id: ?u64 = null,
};

/// Optional observability seam for proving that a product ingress parses an event exactly once.
/// Production callers normally leave this null; the callback sees no payload and cannot affect
/// classification.
pub const ParseObserver = struct {
    context: *anyopaque,
    on_parse: *const fn (*anyopaque) void,
};

pub const ForeignKind = enum {
    runtime,
    stream,
};

pub const StringSpan = struct {
    raw_start: usize,
    raw_end: usize,
    decoded_len: usize,
    digest: Digest,
};

pub const DecodeStringError = error{
    InvalidSpan,
    LengthMismatch,
};

/// Writes one preflight-produced span into caller-owned storage without allocating.
///
/// The destination length must be exactly `span.decoded_len`; a larger buffer is rejected as well
/// as a smaller one so callers cannot accidentally publish an uninitialized suffix. Validation is
/// a first pass and the copy is a second pass, leaving `destination` unchanged on error.
pub fn decodeStringExact(
    payload: []const u8,
    span: StringSpan,
    destination: []u8,
) DecodeStringError!void {
    if (destination.len != span.decoded_len) return error.LengthMismatch;
    if (!validateStringSpan(payload, span)) return error.InvalidSpan;
    if (isSyntheticEmpty(span)) {
        return;
    }

    var iterator = JsonStringIterator.init(payload, span) orelse unreachable;
    for (destination) |*byte| byte.* = iterator.next() orelse unreachable;
}

pub fn validateStringSpan(payload: []const u8, span: StringSpan) bool {
    if (isSyntheticEmpty(span))
        return std.mem.eql(u8, &span.digest, &sha(""));
    var iterator = JsonStringIterator.init(payload, span) orelse return false;
    var hasher = Sha256.init(.{});
    var decoded_len: usize = 0;
    while (iterator.next()) |byte| {
        hasher.update(&.{byte});
        decoded_len = std.math.add(usize, decoded_len, 1) catch return false;
        if (decoded_len > span.decoded_len) return false;
    }
    if (decoded_len != span.decoded_len) return false;
    var digest: Digest = undefined;
    hasher.final(&digest);
    return std.mem.eql(u8, &digest, &span.digest);
}

/// Compares one validated JSON string span with already-decoded owned bytes without allocating.
pub fn decodedStringSpanEqualsBytes(
    payload: []const u8,
    span: StringSpan,
    expected: []const u8,
) bool {
    if (span.decoded_len == 0) return expected.len == 0;
    return spanEquals(payload, span, expected);
}

pub const ProcessView = struct {
    pid: i32,
    name: StringSpan,
};

pub const SemanticPrompt = runtime_metadata_types.SemanticPrompt;

pub const MetadataView = struct {
    revision: u64,
    observation_probe_nonce: ?u64 = null,
    cwd: StringSpan,
    /// Optional same-major authority host for `cwd`. Missing peers normalize to empty.
    cwd_host: StringSpan,
    window_title: StringSpan,
    ssh_remote_dest: ?StringSpan,
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
    clipboard_read_target: StringSpan,
    observer_generation: u64,
    title_generation: u32,
    cols: u16,
    rows: u16,
    foreground_available: bool,
    foreground_pgid: ?i32,
    /// PTY 자식 뿌리 pid와 그것을 소유한 host 프로세스 pid. **구 host면 둘 다 0**이고, 소비자는 그때
    /// 표본을 못 얻는 것으로 다룬다(docs/status-bar.md §4.1). `foreground_*`와 달리 필수 키가 아니다 —
    /// 없으면 `Malformed`가 아니라 0이다(구 host와의 호환 규약, docs/session-host-upgrade.md).
    child_pid: i32,
    host_pid: i32,
    processes: [max_process_entries]ProcessView,
    process_count: u8,
    semantic_digest: Digest,

    pub fn foregroundProcesses(self: *const MetadataView) []const ProcessView {
        return self.processes[0..self.process_count];
    }
};

pub const Revoked = struct {
    runtime_id: u128,
    stream_id: u64,
    controller_generation: u64,
};

pub const Event = union(enum) {
    revoked: Revoked,
    invalidated,
    resized: resize_wire.Event,
    metadata: MetadataView,
    ended,
};

pub const EventPreflight = struct {
    event: Event,
    raw_digest: Digest,
};

pub const Verdict = union(enum) {
    accepted: EventPreflight,
    unknown,
    foreign: ForeignKind,
    malformed,
    resource_exhausted,
};

pub const MetadataSupport = enum {
    unsupported,
    supported,
};

pub const AttachGenerationSchema = enum {
    frozen_controller_only,
    granted_without_generation,
    granted_with_generation,
};

pub const AttachProfile = struct {
    generation_schema: AttachGenerationSchema,
    metadata_support: MetadataSupport,
};

pub const AttachDecodeProfile = AttachProfile;

pub const InitialMetadataView = union(enum) {
    unsupported,
    unavailable,
    current: MetadataView,
};

/// Role/requested-mode policy deliberately stays above this neutral wire result.
pub const AttachScalarsView = struct {
    stream_id: u64,
    controller_generation: u64,
    observe: bool,
    input: bool,
    resize: bool,
    controller_busy: bool,
    initial_metadata: InitialMetadataView,
};

pub const AttachEnvelopeView = union(enum) {
    wire_error: protocol.ErrorCode,
    accepted: AttachScalarsView,
};

pub const AttachPreflight = struct {
    envelope: AttachEnvelopeView,
    raw_digest: Digest,
};

pub const ObservationPreflight = struct {
    initial_metadata: InitialMetadataView,
    raw_digest: Digest,
};

pub const AttachPreflightError = error{
    Malformed,
    ResourceExhausted,
};

pub const ObservationPreflightError = AttachPreflightError;

const ParseError = error{
    Malformed,
    ScratchExhausted,
    DepthExceeded,
    ResourceExhausted,
};

const ResourcePolicy = enum {
    event_drain,
    attach_immediate,
};

const EventName = enum {
    revoked,
    invalidated,
    resized,
    metadata,
    ended,
    unknown,
};

const KeyFingerprint = struct {
    digest: Digest,
    raw_start: usize,
    raw_end: usize,
    decoded_len: usize,
};

const max_key_fields = @max(max_event_fields, max_metadata_fields);

const KeySet = struct {
    entries: [max_key_fields]KeyFingerprint = undefined,
    len: usize = 0,

    fn insert(
        self: *KeySet,
        payload: []const u8,
        key: StringSpan,
        cap: usize,
        digest_ops: DigestOps,
    ) ParseError!bool {
        // Once the scope is full, this key is outside the admitted set. The caller switches the
        // rest of the event to syntax-only drain, so even an exact duplicate here is a resource
        // verdict rather than a semantic duplicate verdict.
        if (self.len == cap) return false;
        const digest = digest_ops.finish_key(digest_ops.context, key.digest);
        for (self.entries[0..self.len]) |old| {
            if (!std.mem.eql(u8, &old.digest, &digest) or old.decoded_len != key.decoded_len)
                continue;
            if (decodedStringSpansEqual(
                payload,
                .{
                    .raw_start = old.raw_start,
                    .raw_end = old.raw_end,
                    .decoded_len = old.decoded_len,
                    .digest = old.digest,
                },
                payload,
                key,
            )) return error.Malformed;
        }
        self.entries[self.len] = .{
            .digest = digest,
            .raw_start = key.raw_start,
            .raw_end = key.raw_end,
            .decoded_len = key.decoded_len,
        };
        self.len += 1;
        return true;
    }
};

const DataFields = struct {
    keys: KeySet = .{},
    count: usize = 0,
    unknown_count: usize = 0,
    runtime_id: ?u128 = null,
    stream_id: ?u64 = null,
    controller_generation: ?u64 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    resize_generation: ?u64 = null,
    reason_takeover: ?bool = null,
    reason_controller: ?bool = null,
};

const MetadataFields = struct {
    keys: KeySet = .{},
    count: usize = 0,
    cwd: ?StringSpan = null,
    cwd_host: ?StringSpan = null,
    window_title: ?StringSpan = null,
    ssh_seen: bool = false,
    ssh_remote_dest: ?StringSpan = null,
    semantic_state: ?SemanticPrompt = null,
    alt_active: ?bool = null,
    app_cursor_keys: ?bool = null,
    app_keypad: bool = false,
    kitty_flags: u5 = 0,
    alternate_scroll: ?bool = null,
    mouse_tracking: bool = false,
    mouse_tracking_mode: ?u8 = null,
    bracketed_paste: bool = false,
    bell_count: u64 = 0,
    clipboard_write_seq: u64 = 0,
    clipboard_read_seq: u64 = 0,
    clipboard_read_target: ?StringSpan = null,
    observer_generation: ?u64 = null,
    title_generation: ?u32 = null,
    cols: ?u16 = null,
    rows: ?u16 = null,
    foreground_available: ?bool = null,
    foreground_pgid_seen: bool = false,
    foreground_pgid: ?i32 = null,
    child_pid: i32 = 0,
    host_pid: i32 = 0,
    processes_seen: bool = false,
    processes: [max_process_entries]ProcessView = undefined,
    process_count: usize = 0,
};

const RootFields = struct {
    keys: KeySet = .{},
    count: usize = 0,
    unknown_count: usize = 0,
    event_name: ?EventName = null,
    data_seen: bool = false,
    data: DataFields = .{},
    revision: ?u64 = null,
    observation_probe_nonce: ?u64 = null,
    metadata_seen: bool = false,
    metadata: MetadataFields = .{},
    resource_seen: bool = false,
};

const GrantedFields = struct {
    keys: KeySet = .{},
    count: usize = 0,
    unknown_count: usize = 0,
    observe: ?bool = null,
    input: ?bool = null,
    resize: ?bool = null,
};

const AttachResultFields = struct {
    keys: KeySet = .{},
    count: usize = 0,
    unknown_count: usize = 0,
    stream_id: ?u64 = null,
    controller_generation_seen: bool = false,
    controller_generation: ?u64 = null,
    granted_seen: bool = false,
    granted: GrantedFields = .{},
    controller_busy: ?bool = null,
    metadata_revision_seen: bool = false,
    metadata_revision: ?u64 = null,
    metadata_seen: bool = false,
    metadata_null: bool = false,
    metadata_object: bool = false,
    metadata: MetadataFields = .{},
};

const AttachRootFields = struct {
    keys: KeySet = .{},
    count: usize = 0,
    unknown_count: usize = 0,
    error_name: ?StringSpan = null,
    stream_id: ?u64 = null,
    result_seen: bool = false,
    result: AttachResultFields = .{},
};

pub fn preflightEvent(payload: []const u8, expected: ExpectedIdentity) Verdict {
    return preflightEventObserved(payload, expected, null);
}

pub fn preflightEventObserved(
    payload: []const u8,
    expected: ExpectedIdentity,
    observer: ?ParseObserver,
) Verdict {
    if (observer) |value| value.on_parse(value.context);
    return preflightEventWithDigestOps(payload, expected, .production);
}

pub fn preflightAttachEnvelope(
    payload: []const u8,
    profile: AttachProfile,
) AttachPreflightError!AttachPreflight {
    if (payload.len > protocol.max_control_json) return error.ResourceExhausted;

    var scratch: [attach_preflight_scratch_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = std.json.Scanner.initCompleteInput(fba.allocator(), payload);
    defer scanner.deinit();

    var root: AttachRootFields = .{};
    parseAttachRoot(&scanner, payload, &root) catch |err| return attachParseError(err);
    const end = nextToken(&scanner) catch |err| return attachParseError(err);
    if (end != .end_of_document) return error.Malformed;

    const envelope: AttachEnvelopeView = if (root.error_name) |name| blk: {
        if (root.count != 1 or root.unknown_count != 0) return error.Malformed;
        break :blk .{ .wire_error = attachWireError(payload, name) orelse
            return error.Malformed };
    } else switch (profile.generation_schema) {
        .frozen_controller_only => blk: {
            if (profile.metadata_support != .unsupported or
                root.count != 1 or root.unknown_count != 0 or
                root.result_seen)
                return error.Malformed;
            const stream_id = root.stream_id orelse return error.Malformed;
            if (stream_id == 0) return error.Malformed;
            break :blk .{ .accepted = .{
                .stream_id = stream_id,
                .controller_generation = 0,
                .observe = true,
                .input = true,
                .resize = true,
                .controller_busy = false,
                .initial_metadata = .unsupported,
            } };
        },
        .granted_without_generation,
        .granted_with_generation,
        => blk: {
            if (root.count != 1 or root.unknown_count != 0 or
                root.stream_id != null or !root.result_seen)
                return error.Malformed;
            break :blk .{ .accepted = try finishAttachResult(
                payload,
                &root.result,
                profile,
            ) };
        },
    };
    return .{ .envelope = envelope, .raw_digest = sha(payload) };
}

/// Strict `runtime.observation` response decoder for a metadata-supported connection.
pub fn preflightObservationEnvelope(
    payload: []const u8,
) ObservationPreflightError!ObservationPreflight {
    if (payload.len > protocol.max_control_json) return error.ResourceExhausted;

    var scratch: [attach_preflight_scratch_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = std.json.Scanner.initCompleteInput(fba.allocator(), payload);
    defer scanner.deinit();

    var root: AttachRootFields = .{};
    parseAttachRoot(&scanner, payload, &root) catch |err| return attachParseError(err);
    const end = nextToken(&scanner) catch |err| return attachParseError(err);
    if (end != .end_of_document or root.count != 1 or root.unknown_count != 0 or
        root.error_name != null or root.stream_id != null or !root.result_seen)
        return error.Malformed;
    const result = &root.result;
    if (result.count != 2 or result.unknown_count != 0 or
        result.stream_id != null or result.controller_generation_seen or
        result.granted_seen or result.controller_busy != null)
        return error.Malformed;
    return .{
        .initial_metadata = try finishSupportedMetadata(payload, result),
        .raw_digest = sha(payload),
    };
}

fn preflightEventWithDigestOps(
    payload: []const u8,
    expected: ExpectedIdentity,
    digest_ops: DigestOps,
) Verdict {
    if (payload.len > protocol.max_control_json) return .resource_exhausted;

    var scratch: [event_preflight_scratch_bytes]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = std.json.Scanner.initCompleteInput(fba.allocator(), payload);
    defer scanner.deinit();

    var root: RootFields = .{};
    parseRoot(&scanner, payload, &root, digest_ops) catch return .malformed;
    const end = nextToken(&scanner) catch return .malformed;
    if (end != .end_of_document) return .malformed;

    const name = root.event_name orelse return .malformed;
    if (name == .unknown) return .unknown;
    if (root.resource_seen) return .resource_exhausted;

    const raw_digest = sha(payload);
    const event: Event = switch (name) {
        .revoked => blk: {
            if (root.count != 2 or root.unknown_count != 0 or !root.data_seen or
                root.data.count != 4 or root.data.unknown_count != 0)
                return .malformed;
            const runtime_id = root.data.runtime_id orelse return .malformed;
            const stream_id = root.data.stream_id orelse return .malformed;
            const generation = root.data.controller_generation orelse return .malformed;
            if (runtime_id == 0 or stream_id == 0 or generation == 0 or
                root.data.reason_takeover != true)
                return .malformed;
            if (expected.runtime_id) |want| if (want != runtime_id)
                return .{ .foreign = .runtime };
            if (expected.stream_id) |want| if (want != stream_id)
                return .{ .foreign = .stream };
            break :blk .{ .revoked = .{
                .runtime_id = runtime_id,
                .stream_id = stream_id,
                .controller_generation = generation,
            } };
        },
        .invalidated => blk: {
            if (root.count != 1 or root.unknown_count != 0) return .malformed;
            break :blk .invalidated;
        },
        .resized => blk: {
            if (root.count != 2 or root.unknown_count != 0 or !root.data_seen or
                root.data.count != 5 or root.data.unknown_count != 0)
                return .malformed;
            const runtime_id = root.data.runtime_id orelse return .malformed;
            const cols = root.data.cols orelse return .malformed;
            const rows = root.data.rows orelse return .malformed;
            const generation = root.data.resize_generation orelse return .malformed;
            if (runtime_id == 0 or cols < 2 or rows == 0 or generation == 0 or
                generation > resize_wire.max_counter or
                root.data.reason_controller != true)
                return .malformed;
            if (expected.runtime_id) |want| if (want != runtime_id)
                return .{ .foreign = .runtime };
            break :blk .{ .resized = .{
                .runtime_id = runtime_id,
                .cols = cols,
                .rows = rows,
                .resize_generation = generation,
            } };
        },
        .metadata => blk: {
            const expected_count: usize = if (root.observation_probe_nonce == null) 3 else 4;
            if (root.count != expected_count or root.unknown_count != 0 or root.revision == null or
                !root.metadata_seen)
                return .malformed;
            const view = finishMetadata(
                root.revision.?,
                root.observation_probe_nonce,
                root.metadata,
                payload,
                digest_ops,
            ) orelse
                return .malformed;
            break :blk .{ .metadata = view };
        },
        .ended => blk: {
            if (root.count != 1 or root.unknown_count != 0) return .malformed;
            break :blk .ended;
        },
        .unknown => unreachable,
    };
    return .{ .accepted = .{ .event = event, .raw_digest = raw_digest } };
}

fn attachParseError(err: ParseError) AttachPreflightError {
    return switch (err) {
        error.ResourceExhausted => error.ResourceExhausted,
        error.Malformed, error.ScratchExhausted, error.DepthExceeded => error.Malformed,
    };
}

fn finishAttachResult(
    payload: []const u8,
    result: *const AttachResultFields,
    profile: AttachProfile,
) AttachPreflightError!AttachScalarsView {
    const generation_fields: usize =
        if (profile.generation_schema == .granted_with_generation) 1 else 0;
    const metadata_fields: usize = if (profile.metadata_support == .supported) 2 else 0;
    if (result.count != 3 + generation_fields + metadata_fields or
        result.unknown_count != 0 or !result.granted_seen)
        return error.Malformed;
    const stream_id = result.stream_id orelse return error.Malformed;
    if (stream_id == 0) return error.Malformed;
    const generation: u64 = switch (profile.generation_schema) {
        .frozen_controller_only => unreachable,
        .granted_without_generation => blk: {
            if (result.controller_generation_seen) return error.Malformed;
            break :blk 0;
        },
        .granted_with_generation => blk: {
            if (!result.controller_generation_seen) return error.Malformed;
            break :blk result.controller_generation orelse return error.Malformed;
        },
    };
    const busy = result.controller_busy orelse return error.Malformed;
    if (result.granted.count != 3 or result.granted.unknown_count != 0)
        return error.Malformed;
    const observe = result.granted.observe orelse return error.Malformed;
    const input = result.granted.input orelse return error.Malformed;
    const resize = result.granted.resize orelse return error.Malformed;
    if (!observe or input != resize) return error.Malformed;

    const initial_metadata: InitialMetadataView = switch (profile.metadata_support) {
        .unsupported => blk: {
            if (result.metadata_revision_seen or result.metadata_seen)
                return error.Malformed;
            break :blk .unsupported;
        },
        .supported => try finishSupportedMetadata(payload, result),
    };
    return .{
        .stream_id = stream_id,
        .controller_generation = generation,
        .observe = observe,
        .input = input,
        .resize = resize,
        .controller_busy = busy,
        .initial_metadata = initial_metadata,
    };
}

fn finishSupportedMetadata(
    payload: []const u8,
    result: *const AttachResultFields,
) AttachPreflightError!InitialMetadataView {
    if (!result.metadata_revision_seen or !result.metadata_seen)
        return error.Malformed;
    const revision = result.metadata_revision orelse return error.Malformed;
    if (revision == 0) {
        if (!result.metadata_null or result.metadata_object)
            return error.Malformed;
        return .unavailable;
    }
    if (!result.metadata_object or result.metadata_null) return error.Malformed;
    const metadata = finishMetadata(
        revision,
        null,
        result.metadata,
        payload,
        .production,
    ) orelse return error.Malformed;
    return .{ .current = metadata };
}

fn parseAttachRoot(
    scanner: *std.json.Scanner,
    payload: []const u8,
    root: *AttachRootFields,
) ParseError!void {
    if (try nextToken(scanner) != .object_begin) return error.Malformed;
    while (true) {
        if (try peekType(scanner) == .object_end) {
            _ = try nextToken(scanner);
            return;
        }
        const key = try readString(scanner);
        root.count += 1;
        if (!try root.keys.insert(payload, key, max_attach_fields, .production))
            return error.ResourceExhausted;
        if (spanEquals(payload, key, "error")) {
            if (root.error_name != null) return error.Malformed;
            root.error_name = try readString(scanner);
        } else if (spanEquals(payload, key, "stream_id")) {
            if (root.stream_id != null) return error.Malformed;
            root.stream_id = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "result")) {
            if (root.result_seen) return error.Malformed;
            root.result_seen = true;
            try parseAttachResult(scanner, payload, &root.result);
        } else {
            root.unknown_count += 1;
            try drainValue(scanner, 2);
        }
    }
}

fn parseAttachResult(
    scanner: *std.json.Scanner,
    payload: []const u8,
    result: *AttachResultFields,
) ParseError!void {
    if (try nextToken(scanner) != .object_begin) return error.Malformed;
    while (true) {
        if (try peekType(scanner) == .object_end) {
            _ = try nextToken(scanner);
            return;
        }
        const key = try readString(scanner);
        result.count += 1;
        if (!try result.keys.insert(payload, key, max_attach_fields, .production))
            return error.ResourceExhausted;
        if (spanEquals(payload, key, "stream_id")) {
            if (result.stream_id != null) return error.Malformed;
            result.stream_id = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "controller_generation")) {
            if (result.controller_generation_seen) return error.Malformed;
            result.controller_generation_seen = true;
            result.controller_generation = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "granted")) {
            if (result.granted_seen) return error.Malformed;
            result.granted_seen = true;
            try parseGranted(scanner, payload, &result.granted);
        } else if (spanEquals(payload, key, "controller_busy")) {
            if (result.controller_busy != null) return error.Malformed;
            result.controller_busy = try readBool(scanner);
        } else if (spanEquals(payload, key, "metadata_revision")) {
            if (result.metadata_revision_seen) return error.Malformed;
            result.metadata_revision_seen = true;
            result.metadata_revision = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "metadata")) {
            if (result.metadata_seen) return error.Malformed;
            result.metadata_seen = true;
            switch (try peekType(scanner)) {
                .null => {
                    _ = try nextToken(scanner);
                    result.metadata_null = true;
                },
                .object_begin => {
                    result.metadata_object = true;
                    var resource_seen = false;
                    try parseMetadata(
                        scanner,
                        payload,
                        &result.metadata,
                        &resource_seen,
                        .attach_immediate,
                        .production,
                    );
                },
                else => return error.Malformed,
            }
        } else {
            result.unknown_count += 1;
            try drainValue(scanner, 3);
        }
    }
}

fn parseGranted(
    scanner: *std.json.Scanner,
    payload: []const u8,
    granted: *GrantedFields,
) ParseError!void {
    if (try nextToken(scanner) != .object_begin) return error.Malformed;
    while (true) {
        if (try peekType(scanner) == .object_end) {
            _ = try nextToken(scanner);
            return;
        }
        const key = try readString(scanner);
        granted.count += 1;
        if (!try granted.keys.insert(payload, key, max_attach_fields, .production))
            return error.ResourceExhausted;
        if (spanEquals(payload, key, "observe")) {
            if (granted.observe != null) return error.Malformed;
            granted.observe = try readBool(scanner);
        } else if (spanEquals(payload, key, "input")) {
            if (granted.input != null) return error.Malformed;
            granted.input = try readBool(scanner);
        } else if (spanEquals(payload, key, "resize")) {
            if (granted.resize != null) return error.Malformed;
            granted.resize = try readBool(scanner);
        } else {
            granted.unknown_count += 1;
            try drainValue(scanner, 4);
        }
    }
}

fn attachWireError(payload: []const u8, name: StringSpan) ?protocol.ErrorCode {
    // ErrorCode itself is the closed wire vocabulary. Keeping a second method-local allowlist
    // made valid typed outcomes such as stale_host and payload_too_large unreachable to callers
    // that already map them, while future unknown names still fail because they are not enum
    // fields.
    inline for (@typeInfo(protocol.ErrorCode).@"enum".fields) |field| {
        const code: protocol.ErrorCode = @enumFromInt(field.value);
        if (spanEquals(payload, name, code.wireName())) return code;
    }
    return null;
}

fn parseRoot(
    scanner: *std.json.Scanner,
    payload: []const u8,
    root: *RootFields,
    digest_ops: DigestOps,
) ParseError!void {
    if (try nextToken(scanner) != .object_begin) return error.Malformed;
    while (true) {
        if (try peekType(scanner) == .object_end) {
            _ = try nextToken(scanner);
            return;
        }
        const key = try readString(scanner);
        root.count += 1;
        if (root.resource_seen) {
            try drainValue(scanner, 2);
            continue;
        }
        if (!try root.keys.insert(payload, key, max_event_fields, digest_ops)) {
            root.resource_seen = true;
            try drainValue(scanner, 2);
            continue;
        }
        if (spanEquals(payload, key, "event")) {
            const value = try readString(scanner);
            if (root.event_name != null) return error.Malformed;
            root.event_name = eventName(payload, value);
        } else if (spanEquals(payload, key, "data")) {
            if (root.data_seen) return error.Malformed;
            root.data_seen = true;
            try parseData(scanner, payload, &root.data, &root.resource_seen, digest_ops);
        } else if (spanEquals(payload, key, "metadata_revision")) {
            if (root.revision != null) return error.Malformed;
            root.revision = try readUnsigned(u64, scanner);
            if (root.revision.? == 0) return error.Malformed;
        } else if (spanEquals(payload, key, "observation_probe_nonce")) {
            if (root.observation_probe_nonce != null) return error.Malformed;
            root.observation_probe_nonce = try readUnsigned(u64, scanner);
            if (root.observation_probe_nonce.? == 0) return error.Malformed;
        } else if (spanEquals(payload, key, "metadata")) {
            if (root.metadata_seen) return error.Malformed;
            root.metadata_seen = true;
            try parseMetadata(
                scanner,
                payload,
                &root.metadata,
                &root.resource_seen,
                .event_drain,
                digest_ops,
            );
        } else {
            root.unknown_count += 1;
            try drainValue(scanner, 2);
        }
    }
}

fn parseData(
    scanner: *std.json.Scanner,
    payload: []const u8,
    data: *DataFields,
    resource_seen: *bool,
    digest_ops: DigestOps,
) ParseError!void {
    if (try nextToken(scanner) != .object_begin) return error.Malformed;
    while (true) {
        if (try peekType(scanner) == .object_end) {
            _ = try nextToken(scanner);
            return;
        }
        const key = try readString(scanner);
        data.count += 1;
        if (resource_seen.*) {
            try drainValue(scanner, 3);
            continue;
        }
        if (!try data.keys.insert(payload, key, max_event_fields, digest_ops)) {
            resource_seen.* = true;
            try drainValue(scanner, 3);
            continue;
        }
        if (spanEquals(payload, key, "runtime_id")) {
            if (data.runtime_id != null) return error.Malformed;
            data.runtime_id = parseHex128(payload, try readString(scanner)) orelse
                return error.Malformed;
        } else if (spanEquals(payload, key, "stream_id")) {
            if (data.stream_id != null) return error.Malformed;
            data.stream_id = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "controller_generation")) {
            if (data.controller_generation != null) return error.Malformed;
            data.controller_generation = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "cols")) {
            if (data.cols != null) return error.Malformed;
            data.cols = try readUnsigned(u16, scanner);
        } else if (spanEquals(payload, key, "rows")) {
            if (data.rows != null) return error.Malformed;
            data.rows = try readUnsigned(u16, scanner);
        } else if (spanEquals(payload, key, "resize_generation")) {
            if (data.resize_generation != null) return error.Malformed;
            data.resize_generation = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "reason")) {
            if (data.reason_takeover != null or data.reason_controller != null)
                return error.Malformed;
            const value = try readString(scanner);
            data.reason_takeover = spanEquals(payload, value, "takeover");
            data.reason_controller = spanEquals(payload, value, "controller");
        } else {
            data.unknown_count += 1;
            try drainValue(scanner, 3);
        }
    }
}

fn parseMetadata(
    scanner: *std.json.Scanner,
    payload: []const u8,
    metadata: *MetadataFields,
    resource_seen: *bool,
    resource_policy: ResourcePolicy,
    digest_ops: DigestOps,
) ParseError!void {
    if (try nextToken(scanner) != .object_begin) return error.Malformed;
    while (true) {
        if (try peekType(scanner) == .object_end) {
            _ = try nextToken(scanner);
            return;
        }
        const key = try readString(scanner);
        metadata.count += 1;
        if (resource_seen.*) {
            try drainValue(scanner, 3);
            continue;
        }
        if (!try metadata.keys.insert(payload, key, max_metadata_fields, digest_ops)) {
            if (resource_policy == .attach_immediate) return error.ResourceExhausted;
            resource_seen.* = true;
            try drainValue(scanner, 3);
            continue;
        }
        if (spanEquals(payload, key, "cwd")) {
            if (metadata.cwd != null) return error.Malformed;
            metadata.cwd = try readString(scanner);
        } else if (spanEquals(payload, key, "cwd_host")) {
            if (metadata.cwd_host != null) return error.Malformed;
            metadata.cwd_host = try readString(scanner);
        } else if (spanEquals(payload, key, "window_title")) {
            if (metadata.window_title != null) return error.Malformed;
            metadata.window_title = try readString(scanner);
        } else if (spanEquals(payload, key, "ssh_remote_dest")) {
            if (metadata.ssh_seen) return error.Malformed;
            metadata.ssh_seen = true;
            metadata.ssh_remote_dest = try readOptionalString(scanner);
        } else if (spanEquals(payload, key, "semantic_state")) {
            if (metadata.semantic_state != null) return error.Malformed;
            const raw = try readUnsigned(u8, scanner);
            metadata.semantic_state = if (raw <= @intFromEnum(SemanticPrompt.command))
                @enumFromInt(raw)
            else
                .unknown;
        } else if (spanEquals(payload, key, "alt_active")) {
            if (metadata.alt_active != null) return error.Malformed;
            metadata.alt_active = try readBool(scanner);
        } else if (spanEquals(payload, key, "app_cursor_keys")) {
            if (metadata.app_cursor_keys != null) return error.Malformed;
            metadata.app_cursor_keys = try readBool(scanner);
        } else if (spanEquals(payload, key, "app_keypad")) {
            metadata.app_keypad = try readBool(scanner);
        } else if (spanEquals(payload, key, "kitty_flags")) {
            metadata.kitty_flags = try readUnsigned(u5, scanner);
        } else if (spanEquals(payload, key, "alternate_scroll")) {
            if (metadata.alternate_scroll != null) return error.Malformed;
            metadata.alternate_scroll = try readBool(scanner);
        } else if (spanEquals(payload, key, "mouse_tracking")) {
            metadata.mouse_tracking = try readBool(scanner);
        } else if (spanEquals(payload, key, "mouse_tracking_mode")) {
            const mode = try readUnsigned(u8, scanner);
            if (mode > 4) return error.Malformed;
            metadata.mouse_tracking_mode = mode;
        } else if (spanEquals(payload, key, "bracketed_paste")) {
            metadata.bracketed_paste = try readBool(scanner);
        } else if (spanEquals(payload, key, "bell_count")) {
            metadata.bell_count = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "clipboard_write_seq")) {
            metadata.clipboard_write_seq = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "clipboard_read_seq")) {
            metadata.clipboard_read_seq = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "clipboard_read_target")) {
            metadata.clipboard_read_target = try readString(scanner);
        } else if (spanEquals(payload, key, "observer_generation")) {
            if (metadata.observer_generation != null) return error.Malformed;
            metadata.observer_generation = try readUnsigned(u64, scanner);
        } else if (spanEquals(payload, key, "title_generation")) {
            if (metadata.title_generation != null) return error.Malformed;
            metadata.title_generation = try readUnsigned(u32, scanner);
        } else if (spanEquals(payload, key, "cols")) {
            if (metadata.cols != null) return error.Malformed;
            metadata.cols = try readUnsigned(u16, scanner);
        } else if (spanEquals(payload, key, "rows")) {
            if (metadata.rows != null) return error.Malformed;
            metadata.rows = try readUnsigned(u16, scanner);
        } else if (spanEquals(payload, key, "foreground_available")) {
            if (metadata.foreground_available != null) return error.Malformed;
            metadata.foreground_available = try readBool(scanner);
        } else if (spanEquals(payload, key, "foreground_pgid")) {
            if (metadata.foreground_pgid_seen) return error.Malformed;
            metadata.foreground_pgid_seen = true;
            metadata.foreground_pgid = try readOptionalI32(scanner);
        } else if (spanEquals(payload, key, "child_pid")) {
            // 선택 키다 — 중복 검사(`_seen`)를 두지 않는 것은 `app_keypad`·`bell_count`와 같은 부류라서다
            // (필수 3인방만 `_seen`으로 누락을 잡는다). 마지막 값이 이긴다.
            metadata.child_pid = try readSigned(i32, scanner);
        } else if (spanEquals(payload, key, "host_pid")) {
            metadata.host_pid = try readSigned(i32, scanner);
        } else if (spanEquals(payload, key, "processes")) {
            if (metadata.processes_seen) return error.Malformed;
            metadata.processes_seen = true;
            try parseProcesses(
                scanner,
                payload,
                metadata,
                resource_seen,
                resource_policy,
                digest_ops,
            );
        } else {
            try drainUnknownScalar(scanner);
        }
    }
}

fn parseProcesses(
    scanner: *std.json.Scanner,
    payload: []const u8,
    metadata: *MetadataFields,
    resource_seen: *bool,
    resource_policy: ResourcePolicy,
    digest_ops: DigestOps,
) ParseError!void {
    if (try nextToken(scanner) != .array_begin) return error.Malformed;
    while (true) {
        if (try peekType(scanner) == .array_end) {
            _ = try nextToken(scanner);
            return;
        }
        if (resource_seen.*) {
            try drainValue(scanner, 4);
            continue;
        }
        if (metadata.process_count == max_process_entries) {
            if (resource_policy == .attach_immediate) return error.ResourceExhausted;
            resource_seen.* = true;
            try drainValue(scanner, 4);
            continue;
        }
        if (try parseProcess(
            scanner,
            payload,
            resource_seen,
            resource_policy,
            digest_ops,
        )) |process| {
            metadata.processes[metadata.process_count] = process;
            metadata.process_count += 1;
        }
    }
}

fn parseProcess(
    scanner: *std.json.Scanner,
    payload: []const u8,
    resource_seen: *bool,
    resource_policy: ResourcePolicy,
    digest_ops: DigestOps,
) ParseError!?ProcessView {
    if (try nextToken(scanner) != .object_begin) return error.Malformed;
    var keys: KeySet = .{};
    var count: usize = 0;
    var pid: ?i32 = null;
    var name: ?StringSpan = null;
    while (true) {
        if (try peekType(scanner) == .object_end) {
            _ = try nextToken(scanner);
            break;
        }
        const key = try readString(scanner);
        count += 1;
        if (resource_seen.*) {
            try drainValue(scanner, 5);
            continue;
        }
        if (count > max_process_fields) {
            if (resource_policy == .attach_immediate) return error.ResourceExhausted;
            resource_seen.* = true;
            try drainValue(scanner, 5);
            continue;
        }
        if (!try keys.insert(payload, key, max_process_fields, digest_ops)) {
            resource_seen.* = true;
            try drainValue(scanner, 5);
            continue;
        }
        if (spanEquals(payload, key, "pid")) {
            if (pid != null) return error.Malformed;
            pid = try readSigned(i32, scanner);
        } else if (spanEquals(payload, key, "name")) {
            if (name != null) return error.Malformed;
            const value = try readString(scanner);
            if (value.decoded_len > 128) {
                if (resource_policy == .attach_immediate) return error.ResourceExhausted;
                resource_seen.* = true;
            }
            name = value;
        } else {
            try drainUnknownScalar(scanner);
        }
    }
    if (resource_seen.*) return null;
    return .{
        .pid = pid orelse return error.Malformed,
        .name = name orelse return error.Malformed,
    };
}

fn finishMetadata(
    revision: u64,
    observation_probe_nonce: ?u64,
    fields: MetadataFields,
    payload: []const u8,
    digest_ops: DigestOps,
) ?MetadataView {
    if (!fields.ssh_seen or !fields.foreground_pgid_seen or !fields.processes_seen) return null;
    if (fields.cwd_host) |authority|
        if ((fields.cwd orelse return null).decoded_len == 0 and authority.decoded_len != 0)
            return null;
    const foreground = fields.foreground_available orelse return null;
    var view: MetadataView = .{
        .revision = revision,
        .observation_probe_nonce = observation_probe_nonce,
        .cwd = fields.cwd orelse return null,
        .cwd_host = fields.cwd_host orelse emptyStringSpan(),
        .window_title = fields.window_title orelse return null,
        .ssh_remote_dest = fields.ssh_remote_dest,
        .semantic_state = fields.semantic_state orelse return null,
        .alt_active = fields.alt_active orelse return null,
        .app_cursor_keys = fields.app_cursor_keys orelse return null,
        .app_keypad = fields.app_keypad,
        .kitty_flags = fields.kitty_flags,
        .alternate_scroll = fields.alternate_scroll orelse return null,
        .mouse_tracking = fields.mouse_tracking,
        .mouse_tracking_mode = fields.mouse_tracking_mode orelse
            if (fields.mouse_tracking) 2 else 0,
        .bracketed_paste = fields.bracketed_paste,
        .bell_count = fields.bell_count,
        .clipboard_write_seq = fields.clipboard_write_seq,
        .clipboard_read_seq = fields.clipboard_read_seq,
        .clipboard_read_target = fields.clipboard_read_target orelse emptyStringSpan(),
        .observer_generation = fields.observer_generation orelse return null,
        .title_generation = fields.title_generation orelse return null,
        .cols = fields.cols orelse return null,
        .rows = fields.rows orelse return null,
        .foreground_available = foreground,
        .foreground_pgid = if (foreground) fields.foreground_pgid else null,
        // pid 둘은 foreground 가용성과 **무관하다** — foreground 조회가 실패해도 PTY 뿌리는 그대로 있다.
        .child_pid = fields.child_pid,
        .host_pid = fields.host_pid,
        .processes = fields.processes,
        .process_count = if (foreground) @intCast(fields.process_count) else 0,
        .semantic_digest = undefined,
    };
    view.semantic_digest = digest_ops.finish_semantic(
        digest_ops.context,
        metadataDigest(&view, payload),
    );
    return view;
}

fn metadataDigest(view: *const MetadataView, payload: []const u8) Digest {
    var hasher = Sha256.init(.{});
    hashU64(&hasher, view.revision);
    hashSpan(&hasher, view.cwd);
    hashSpan(&hasher, view.cwd_host);
    hashSpan(&hasher, view.window_title);
    hashBool(&hasher, view.ssh_remote_dest != null);
    if (view.ssh_remote_dest) |value| hashSpan(&hasher, value);
    hashU64(&hasher, @intFromEnum(view.semantic_state));
    hashBool(&hasher, view.alt_active);
    hashBool(&hasher, view.app_cursor_keys);
    hashBool(&hasher, view.app_keypad);
    hashU64(&hasher, view.kitty_flags);
    hashBool(&hasher, view.alternate_scroll);
    hashBool(&hasher, view.mouse_tracking);
    hashU64(&hasher, view.mouse_tracking_mode);
    hashBool(&hasher, view.bracketed_paste);
    hashU64(&hasher, view.bell_count);
    hashU64(&hasher, view.clipboard_write_seq);
    hashU64(&hasher, view.clipboard_read_seq);
    hashSpan(&hasher, view.clipboard_read_target);
    hashU64(&hasher, view.observer_generation);
    hashU64(&hasher, view.title_generation);
    hashU64(&hasher, view.cols);
    hashU64(&hasher, view.rows);
    hashBool(&hasher, view.foreground_available);
    hashBool(&hasher, view.foreground_pgid != null);
    if (view.foreground_pgid) |pid| hashI64(&hasher, pid);
    hashI64(&hasher, view.child_pid);
    hashI64(&hasher, view.host_pid);
    hashU64(&hasher, view.process_count);
    for (view.foregroundProcesses()) |process| {
        hashI64(&hasher, process.pid);
        hashSpan(&hasher, process.name);
    }
    _ = payload;
    var out: Digest = undefined;
    hasher.final(&out);
    return out;
}

fn hashSpan(hasher: *Sha256, span: StringSpan) void {
    hashU64(hasher, span.decoded_len);
    hasher.update(&span.digest);
}

fn hashBool(hasher: *Sha256, value: bool) void {
    hasher.update(&.{@intFromBool(value)});
}

fn hashU64(hasher: *Sha256, value: u64) void {
    var bytes: [8]u8 = undefined;
    std.mem.writeInt(u64, &bytes, value, .big);
    hasher.update(&bytes);
}

fn hashI64(hasher: *Sha256, value: i64) void {
    hashU64(hasher, @bitCast(value));
}

pub fn metadataSemanticEqlExact(
    a_payload: []const u8,
    a: *const MetadataView,
    b_payload: []const u8,
    b: *const MetadataView,
) bool {
    if (a.revision != b.revision or
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
        a.observer_generation != b.observer_generation or
        a.title_generation != b.title_generation or
        a.cols != b.cols or a.rows != b.rows or
        a.foreground_available != b.foreground_available or
        a.foreground_pgid != b.foreground_pgid or
        a.child_pid != b.child_pid or
        a.host_pid != b.host_pid or
        a.process_count != b.process_count or
        !decodedStringSpansEqual(a_payload, a.cwd, b_payload, b.cwd) or
        !decodedStringSpansEqual(a_payload, a.cwd_host, b_payload, b.cwd_host) or
        !decodedStringSpansEqual(a_payload, a.window_title, b_payload, b.window_title) or
        !optionalSpanEql(a_payload, a.ssh_remote_dest, b_payload, b.ssh_remote_dest) or
        !decodedStringSpansEqual(
            a_payload,
            a.clipboard_read_target,
            b_payload,
            b.clipboard_read_target,
        ))
        return false;
    for (a.foregroundProcesses(), b.foregroundProcesses()) |ap, bp| {
        if (ap.pid != bp.pid or
            !decodedStringSpansEqual(a_payload, ap.name, b_payload, bp.name))
            return false;
    }
    return true;
}

fn optionalSpanEql(
    a_payload: []const u8,
    a: ?StringSpan,
    b_payload: []const u8,
    b: ?StringSpan,
) bool {
    if (a == null or b == null) return a == null and b == null;
    return decodedStringSpansEqual(a_payload, a.?, b_payload, b.?);
}

fn emptyStringSpan() StringSpan {
    return .{ .raw_start = 0, .raw_end = 0, .decoded_len = 0, .digest = sha("") };
}

fn isSyntheticEmpty(span: StringSpan) bool {
    return span.raw_start == 0 and span.raw_end == 0 and span.decoded_len == 0;
}

fn eventName(payload: []const u8, span: StringSpan) EventName {
    if (spanEquals(payload, span, "controller.revoked")) return .revoked;
    if (spanEquals(payload, span, "snapshot.invalidated")) return .invalidated;
    if (spanEquals(payload, span, "runtime.resized")) return .resized;
    if (spanEquals(payload, span, "runtime.metadata")) return .metadata;
    if (spanEquals(payload, span, "runtime.ended")) return .ended;
    return .unknown;
}

fn readOptionalString(scanner: *std.json.Scanner) ParseError!?StringSpan {
    if (try peekType(scanner) == .null) {
        _ = try nextToken(scanner);
        return null;
    }
    return try readString(scanner);
}

fn readOptionalI32(scanner: *std.json.Scanner) ParseError!?i32 {
    if (try peekType(scanner) == .null) {
        _ = try nextToken(scanner);
        return null;
    }
    return try readSigned(i32, scanner);
}

fn readBool(scanner: *std.json.Scanner) ParseError!bool {
    return switch (try nextToken(scanner)) {
        .true => true,
        .false => false,
        else => error.Malformed,
    };
}

fn readUnsigned(comptime T: type, scanner: *std.json.Scanner) ParseError!T {
    var buf: [64]u8 = undefined;
    const text = try readNumberInto(scanner, &buf);
    return std.fmt.parseInt(T, text, 10) catch error.Malformed;
}

fn readSigned(comptime T: type, scanner: *std.json.Scanner) ParseError!T {
    var buf: [64]u8 = undefined;
    const text = try readNumberInto(scanner, &buf);
    return std.fmt.parseInt(T, text, 10) catch error.Malformed;
}

fn readNumberInto(scanner: *std.json.Scanner, buf: []u8) ParseError![]const u8 {
    var len: usize = 0;
    while (true) {
        switch (try nextToken(scanner)) {
            .partial_number => |part| {
                if (part.len > buf.len - len) return error.Malformed;
                @memcpy(buf[len..][0..part.len], part);
                len += part.len;
            },
            .number => |part| {
                if (part.len > buf.len - len) return error.Malformed;
                @memcpy(buf[len..][0..part.len], part);
                len += part.len;
                return buf[0..len];
            },
            else => return error.Malformed,
        }
    }
}

fn readString(scanner: *std.json.Scanner) ParseError!StringSpan {
    if (try peekType(scanner) != .string) return error.Malformed;
    const raw_start = scanner.cursor;
    var hasher = Sha256.init(.{});
    var decoded_len: usize = 0;
    while (true) {
        switch (try nextToken(scanner)) {
            .partial_string => |part| {
                hasher.update(part);
                decoded_len = std.math.add(usize, decoded_len, part.len) catch
                    return error.Malformed;
            },
            .partial_string_escaped_1 => |part| {
                hasher.update(&part);
                decoded_len = std.math.add(usize, decoded_len, 1) catch
                    return error.Malformed;
            },
            .partial_string_escaped_2 => |part| {
                hasher.update(&part);
                decoded_len = std.math.add(usize, decoded_len, 2) catch
                    return error.Malformed;
            },
            .partial_string_escaped_3 => |part| {
                hasher.update(&part);
                decoded_len = std.math.add(usize, decoded_len, 3) catch
                    return error.Malformed;
            },
            .partial_string_escaped_4 => |part| {
                hasher.update(&part);
                decoded_len = std.math.add(usize, decoded_len, 4) catch
                    return error.Malformed;
            },
            .string => |part| {
                hasher.update(part);
                decoded_len = std.math.add(usize, decoded_len, part.len) catch
                    return error.Malformed;
                var digest: Digest = undefined;
                hasher.final(&digest);
                return .{
                    .raw_start = raw_start,
                    .raw_end = scanner.cursor,
                    .decoded_len = decoded_len,
                    .digest = digest,
                };
            },
            else => return error.Malformed,
        }
    }
}

fn drainUnknownScalar(scanner: *std.json.Scanner) ParseError!void {
    switch (try peekType(scanner)) {
        .string => _ = try readString(scanner),
        .number => try drainNumber(scanner),
        .true, .false, .null => _ = try nextToken(scanner),
        else => return error.Malformed,
    }
}

fn drainValue(scanner: *std.json.Scanner, depth: usize) ParseError!void {
    if (depth > max_depth) return error.DepthExceeded;
    switch (try peekType(scanner)) {
        .string => _ = try readString(scanner),
        .number => try drainNumber(scanner),
        .true, .false, .null => _ = try nextToken(scanner),
        .object_begin => {
            _ = try nextToken(scanner);
            while (try peekType(scanner) != .object_end) {
                _ = try readString(scanner);
                try drainValue(scanner, depth + 1);
            }
            _ = try nextToken(scanner);
        },
        .array_begin => {
            _ = try nextToken(scanner);
            while (try peekType(scanner) != .array_end)
                try drainValue(scanner, depth + 1);
            _ = try nextToken(scanner);
        },
        else => return error.Malformed,
    }
}

fn drainNumber(scanner: *std.json.Scanner) ParseError!void {
    while (true) {
        switch (try nextToken(scanner)) {
            .partial_number => {},
            .number => return,
            else => return error.Malformed,
        }
    }
}

fn peekType(scanner: *std.json.Scanner) ParseError!std.json.TokenType {
    return scanner.peekNextTokenType() catch error.Malformed;
}

fn nextToken(scanner: *std.json.Scanner) ParseError!std.json.Token {
    const token = scanner.next() catch |err| switch (err) {
        error.OutOfMemory => return error.ScratchExhausted,
        else => return error.Malformed,
    };
    if (scanner.stackHeight() > max_depth) return error.DepthExceeded;
    return token;
}

fn parseHex128(payload: []const u8, span: StringSpan) ?u128 {
    if (span.decoded_len != 32) return null;
    var iterator = JsonStringIterator.init(payload, span) orelse return null;
    var value: u128 = 0;
    var count: usize = 0;
    while (iterator.next()) |byte| {
        const digit: u8 = switch (byte) {
            '0'...'9' => byte - '0',
            'a'...'f' => byte - 'a' + 10,
            else => return null,
        };
        value = (value << 4) | digit;
        count += 1;
    }
    return if (count == 32) value else null;
}

fn spanEquals(payload: []const u8, span: StringSpan, literal: []const u8) bool {
    if (span.decoded_len != literal.len) return false;
    var iterator = JsonStringIterator.init(payload, span) orelse return false;
    for (literal) |want| if (iterator.next() != want) return false;
    return iterator.next() == null;
}

fn decodedStringSpansEqual(
    a_payload: []const u8,
    a: StringSpan,
    b_payload: []const u8,
    b: StringSpan,
) bool {
    if (a.decoded_len != b.decoded_len) return false;
    if (a.decoded_len == 0) return true;
    var ai = JsonStringIterator.init(a_payload, a) orelse return false;
    var bi = JsonStringIterator.init(b_payload, b) orelse return false;
    while (true) {
        const av = ai.next();
        const bv = bi.next();
        if (av != bv) return false;
        if (av == null) return true;
    }
}

const JsonStringIterator = struct {
    bytes: []const u8,
    index: usize,
    end: usize,
    pending: [4]u8 = undefined,
    pending_index: u3 = 0,
    pending_len: u3 = 0,

    fn init(payload: []const u8, span: StringSpan) ?JsonStringIterator {
        if (span.raw_end > payload.len or span.raw_start >= span.raw_end or
            payload[span.raw_start] != '"' or payload[span.raw_end - 1] != '"')
            return null;
        return .{
            .bytes = payload,
            .index = span.raw_start + 1,
            .end = span.raw_end - 1,
        };
    }

    fn next(self: *JsonStringIterator) ?u8 {
        if (self.pending_index < self.pending_len) {
            const byte = self.pending[self.pending_index];
            self.pending_index += 1;
            return byte;
        }
        if (self.index >= self.end) return null;
        const byte = self.bytes[self.index];
        self.index += 1;
        if (byte != '\\') return byte;
        if (self.index >= self.end) return null;
        const escaped = self.bytes[self.index];
        self.index += 1;
        return switch (escaped) {
            '"', '\\', '/' => escaped,
            'b' => 0x08,
            'f' => 0x0c,
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            'u' => self.nextUnicode(),
            else => null,
        };
    }

    fn nextUnicode(self: *JsonStringIterator) ?u8 {
        const first = self.readHex4() orelse return null;
        var codepoint: u21 = first;
        if (first >= 0xd800 and first <= 0xdbff) {
            if (self.index + 2 > self.end or self.bytes[self.index] != '\\' or
                self.bytes[self.index + 1] != 'u')
                return null;
            self.index += 2;
            const second = self.readHex4() orelse return null;
            if (second < 0xdc00 or second > 0xdfff) return null;
            codepoint = 0x10000 +
                (@as(u21, first - 0xd800) << 10) +
                @as(u21, second - 0xdc00);
        }
        const len = std.unicode.utf8Encode(codepoint, &self.pending) catch return null;
        self.pending_len = @intCast(len);
        self.pending_index = 1;
        return self.pending[0];
    }

    fn readHex4(self: *JsonStringIterator) ?u16 {
        if (self.index + 4 > self.end) return null;
        var value: u16 = 0;
        for (self.bytes[self.index..][0..4]) |byte| {
            const digit: u16 = switch (byte) {
                '0'...'9' => byte - '0',
                'a'...'f' => byte - 'a' + 10,
                'A'...'F' => byte - 'A' + 10,
                else => return null,
            };
            value = (value << 4) | digit;
        }
        self.index += 4;
        return value;
    }
};

fn sha(bytes: []const u8) Digest {
    var digest: Digest = undefined;
    Sha256.hash(bytes, &digest, .{});
    return digest;
}

test "metadata view field inventory forces every manual semantic mapping to be reviewed" {
    const expected = [_][]const u8{
        "revision",
        "observation_probe_nonce",
        "cwd",
        "cwd_host",
        "window_title",
        "ssh_remote_dest",
        "semantic_state",
        "alt_active",
        "app_cursor_keys",
        "app_keypad",
        "kitty_flags",
        "alternate_scroll",
        "mouse_tracking",
        "mouse_tracking_mode",
        "bracketed_paste",
        "bell_count",
        "clipboard_write_seq",
        "clipboard_read_seq",
        "clipboard_read_target",
        "observer_generation",
        "title_generation",
        "cols",
        "rows",
        "foreground_available",
        "foreground_pgid",
        "child_pid",
        "host_pid",
        "processes",
        "process_count",
        "semantic_digest",
    };
    const fields = @typeInfo(MetadataView).@"struct".fields;
    try std.testing.expectEqual(expected.len, fields.len);
    inline for (expected, fields) |expected_name, field|
        try std.testing.expectEqualStrings(expected_name, field.name);
}

test "observation preflight accepts exact supported unavailable and current envelopes" {
    const unavailable = try preflightObservationEnvelope(
        "{\"result\":{\"metadata_revision\":0,\"metadata\":null}}",
    );
    try std.testing.expect(unavailable.initial_metadata == .unavailable);

    const current =
        "{\"result\":{\"metadata_revision\":5,\"metadata\":{\"cwd\":\"/r\\u0065po\"," ++
        "\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0," ++
        "\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true," ++
        "\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24," ++
        "\"foreground_available\":true,\"foreground_pgid\":7," ++
        "\"processes\":[{\"pid\":7,\"name\":\"zsh\"}]}}}";
    const preflight = try preflightObservationEnvelope(current);
    const metadata = switch (preflight.initial_metadata) {
        .current => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 5), metadata.revision);
    var cwd: [5]u8 = undefined;
    try decodeStringExact(current, metadata.cwd, &cwd);
    try std.testing.expectEqualStrings("/repo", &cwd);

    inline for (&.{
        "{\"metadata_revision\":1,\"metadata\":{}}",
        "{\"result\":{\"metadata_revision\":1}}",
        "{\"result\":{\"metadata_revision\":0,\"metadata\":{}}}",
        "{\"result\":{\"metadata_revision\":1,\"metadata\":null}}",
        "{\"result\":{\"metadata_revision\":0,\"metadata\":null,\"extra\":1}}",
        "{\"error\":\"runtime_not_found\"}",
        "{\"result\":{\"metadata_revision\":0,\"metadata\":null},\"extra\":1}",
    }) |malformed| try std.testing.expectError(
        error.Malformed,
        preflightObservationEnvelope(malformed),
    );
}

test "observation preflight rejects decoded duplicate keys and reports resource caps immediately" {
    const duplicate =
        "{\"result\":{\"metadata_revision\":1,\"metadata_\\u0072evision\":1," ++
        "\"metadata\":null}}";
    try std.testing.expectError(
        error.Malformed,
        preflightObservationEnvelope(duplicate),
    );

    var fields: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fields.deinit();
    try fields.writer.writeAll(
        "{\"result\":{\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\"," ++
            "\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0," ++
            "\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true," ++
            "\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24," ++
            "\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]",
    );
    for (0..max_metadata_fields - 14) |index|
        try fields.writer.print(",\"x{d}\":{d}", .{ index, index });
    try fields.writer.writeAll(",\"overflow\"");
    try std.testing.expectError(
        error.ResourceExhausted,
        preflightObservationEnvelope(fields.written()),
    );

    const over_cap = try std.testing.allocator.alloc(u8, protocol.max_control_json + 1);
    defer std.testing.allocator.free(over_cap);
    @memset(over_cap, 'x');
    try std.testing.expectError(
        error.ResourceExhausted,
        preflightObservationEnvelope(over_cap),
    );
}

test "attach preflight accepts exact wire errors and frozen controller envelopes" {
    const frozen: AttachProfile = .{
        .generation_schema = .frozen_controller_only,
        .metadata_support = .unsupported,
    };
    const wire_error = try preflightAttachEnvelope(
        "{\"err\\u006fr\":\"runtime_not_found\"}",
        frozen,
    );
    try std.testing.expectEqual(protocol.ErrorCode.runtime_not_found, switch (wire_error.envelope) {
        .wire_error => |code| code,
        else => return error.TestUnexpectedResult,
    });
    inline for (@typeInfo(protocol.ErrorCode).@"enum".fields) |field| {
        const code: protocol.ErrorCode = @enumFromInt(field.value);
        const payload = try std.fmt.allocPrint(
            std.testing.allocator,
            "{{\"error\":\"{s}\"}}",
            .{code.wireName()},
        );
        defer std.testing.allocator.free(payload);
        const decoded = try preflightAttachEnvelope(payload, frozen);
        try std.testing.expectEqual(code, switch (decoded.envelope) {
            .wire_error => |value| value,
            else => return error.TestUnexpectedResult,
        });
    }
    try std.testing.expectError(
        error.Malformed,
        preflightAttachEnvelope("{\"error\":\"future_error\"}", frozen),
    );
    try std.testing.expectError(
        error.Malformed,
        preflightAttachEnvelope(
            "{\"error\":\"runtime_not_found\",\"result\":{}}",
            frozen,
        ),
    );

    const accepted = try preflightAttachEnvelope("{\"stream_id\":7}", frozen);
    const scalars = switch (accepted.envelope) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 7), scalars.stream_id);
    try std.testing.expectEqual(@as(u64, 0), scalars.controller_generation);
    try std.testing.expect(scalars.observe and scalars.input and scalars.resize);
    try std.testing.expect(!scalars.controller_busy);
    try std.testing.expect(scalars.initial_metadata == .unsupported);

    try std.testing.expectError(
        error.Malformed,
        preflightAttachEnvelope(
            "{\"stream_id\":7}",
            .{
                .generation_schema = .frozen_controller_only,
                .metadata_support = .supported,
            },
        ),
    );
}

test "attach preflight seals generation schema and unsupported metadata absence" {
    const profile: AttachProfile = .{
        .generation_schema = .granted_without_generation,
        .metadata_support = .unsupported,
    };
    const payload =
        "{\"result\":{\"stream_id\":7,\"granted\":{\"observe\":true,\"input\":false," ++
        "\"resize\":false},\"controller_busy\":true}}";
    const preflight = try preflightAttachEnvelope(payload, profile);
    const scalars = switch (preflight.envelope) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 0), scalars.controller_generation);
    try std.testing.expect(scalars.observe and !scalars.input and !scalars.resize);
    try std.testing.expect(scalars.controller_busy);
    try std.testing.expect(scalars.initial_metadata == .unsupported);

    const with_generation =
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{" ++
        "\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true}}";
    try std.testing.expectError(
        error.Malformed,
        preflightAttachEnvelope(with_generation, profile),
    );
    const with_metadata =
        "{\"result\":{\"stream_id\":7,\"granted\":{\"observe\":true,\"input\":false," ++
        "\"resize\":false},\"controller_busy\":true,\"metadata_revision\":0," ++
        "\"metadata\":null}}";
    try std.testing.expectError(error.Malformed, preflightAttachEnvelope(with_metadata, profile));
}

test "attach preflight distinguishes supported unavailable and current metadata" {
    const profile: AttachProfile = .{
        .generation_schema = .granted_with_generation,
        .metadata_support = .supported,
    };
    const unavailable =
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{" ++
        "\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true," ++
        "\"metadata_revision\":0,\"metadata\":null}}";
    const unavailable_preflight = try preflightAttachEnvelope(unavailable, profile);
    const unavailable_scalars = switch (unavailable_preflight.envelope) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(unavailable_scalars.initial_metadata == .unavailable);
    const neutral_zero_generation =
        "{\"result\":{\"stream_id\":7,\"controller_generation\":0,\"granted\":{" ++
        "\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false," ++
        "\"metadata_revision\":0,\"metadata\":null}}";
    const neutral_preflight = try preflightAttachEnvelope(neutral_zero_generation, profile);
    try std.testing.expectEqual(@as(u64, 0), switch (neutral_preflight.envelope) {
        .accepted => |value| value.controller_generation,
        else => return error.TestUnexpectedResult,
    });

    const current =
        "{\"result\":{\"stream_id\":8,\"controller_generation\":4,\"granted\":{" ++
        "\"observe\":true,\"input\":true,\"resize\":true},\"controller_busy\":false," ++
        "\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/r\\u0065po\"," ++
        "\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0," ++
        "\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true," ++
        "\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24," ++
        "\"foreground_available\":true,\"foreground_pgid\":7," ++
        "\"processes\":[{\"pid\":7,\"name\":\"zsh\"}]}}}";
    const current_preflight = try preflightAttachEnvelope(current, profile);
    const current_scalars = switch (current_preflight.envelope) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 8), current_scalars.stream_id);
    try std.testing.expectEqual(@as(u64, 4), current_scalars.controller_generation);
    const metadata = switch (current_scalars.initial_metadata) {
        .current => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(u64, 2), metadata.revision);
    var cwd: [5]u8 = undefined;
    try decodeStringExact(current, metadata.cwd, &cwd);
    try std.testing.expectEqualStrings("/repo", &cwd);

    inline for (&.{
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{" ++
            "\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true," ++
            "\"metadata_revision\":0}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{" ++
            "\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true," ++
            "\"metadata_revision\":1,\"metadata\":null}}",
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{" ++
            "\"observe\":true,\"input\":true,\"resize\":false},\"controller_busy\":false," ++
            "\"metadata_revision\":0,\"metadata\":null}}",
    }) |malformed| try std.testing.expectError(
        error.Malformed,
        preflightAttachEnvelope(malformed, profile),
    );
}

test "attach preflight reports metadata and process caps immediately as resource exhausted" {
    const profile: AttachProfile = .{
        .generation_schema = .granted_with_generation,
        .metadata_support = .supported,
    };
    var fields: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer fields.deinit();
    try fields.writer.writeAll(
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{" ++
            "\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true," ++
            "\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\"," ++
            "\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0," ++
            "\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true," ++
            "\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24," ++
            "\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]",
    );
    for (0..max_metadata_fields - 14) |index|
        try fields.writer.print(",\"x{d}\":{d}", .{ index, index });
    // The 65th key is enough to commit the attach resource verdict; its value/tail need not parse.
    try fields.writer.writeAll(",\"overflow\"");
    try std.testing.expectError(
        error.ResourceExhausted,
        preflightAttachEnvelope(fields.written(), profile),
    );

    var processes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer processes.deinit();
    try processes.writer.writeAll(
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{" ++
            "\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true," ++
            "\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\"," ++
            "\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0," ++
            "\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true," ++
            "\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24," ++
            "\"foreground_available\":true,\"foreground_pgid\":7,\"processes\":[",
    );
    for (0..max_process_entries) |index| {
        if (index != 0) try processes.writer.writeByte(',');
        try processes.writer.print("{{\"pid\":{d},\"name\":\"p\"}}", .{index});
    }
    try processes.writer.writeAll(",{");
    try std.testing.expectError(
        error.ResourceExhausted,
        preflightAttachEnvelope(processes.written(), profile),
    );

    const process_fields =
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{" ++
        "\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true," ++
        "\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\"," ++
        "\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false," ++
        "\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1," ++
        "\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":true," ++
        "\"foreground_pgid\":7,\"processes\":[{\"pid\":7,\"name\":\"zsh\",\"a\":0," ++
        "\"b\":0,\"c\":0,\"d\":0,\"e\":0,\"f\":0,\"overflow\"";
    try std.testing.expectError(
        error.ResourceExhausted,
        preflightAttachEnvelope(process_fields, profile),
    );

    const long_process_name =
        "{\"result\":{\"stream_id\":7,\"controller_generation\":3,\"granted\":{" ++
        "\"observe\":true,\"input\":false,\"resize\":false},\"controller_busy\":true," ++
        "\"metadata_revision\":2,\"metadata\":{\"cwd\":\"/repo\",\"window_title\":\"work\"," ++
        "\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false," ++
        "\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1," ++
        "\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":true," ++
        "\"foreground_pgid\":7,\"processes\":[{\"pid\":7,\"name\":\"" ++
        ("x" ** 129) ++ "\"}]}}}";
    try std.testing.expectError(
        error.ResourceExhausted,
        preflightAttachEnvelope(long_process_name, profile),
    );

    const over_cap = try std.testing.allocator.alloc(u8, protocol.max_control_json + 1);
    defer std.testing.allocator.free(over_cap);
    @memset(over_cap, 'x');
    try std.testing.expectError(
        error.ResourceExhausted,
        preflightAttachEnvelope(over_cap, profile),
    );
}

test "common five events classify unknown foreign and malformed without heap allocation" {
    const cases = .{
        .{
            "{\"event\":\"snapshot.invalidated\"}",
            EventName.invalidated,
        },
        .{
            "{\"event\":\"runtime.ended\"}",
            EventName.ended,
        },
        .{
            "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"cols\":120,\"rows\":40,\"resize_generation\":9,\"reason\":\"controller\"}}",
            EventName.resized,
        },
        .{
            "{\"event\":\"controller.revoked\",\"data\":{\"runtime_id\":\"000000000000000000000000000000aa\",\"stream_id\":7,\"controller_generation\":4,\"reason\":\"takeover\"}}",
            EventName.revoked,
        },
    };
    inline for (cases) |case| {
        const verdict = preflightEvent(case[0], .{});
        const accepted = switch (verdict) {
            .accepted => |value| value,
            else => return error.TestUnexpectedResult,
        };
        try std.testing.expectEqual(case[1], @as(EventName, switch (accepted.event) {
            .invalidated => .invalidated,
            .ended => .ended,
            .resized => .resized,
            .revoked => .revoked,
            .metadata => .metadata,
        }));
    }
    try std.testing.expect(preflightEvent("{\"event\":\"future.required\"}", .{}) == .unknown);
    try std.testing.expect(preflightEvent(
        cases[2][0],
        .{ .runtime_id = 0xbb },
    ) == .foreign);
    const foreign_stream = preflightEvent(
        cases[3][0],
        .{ .runtime_id = 0xaa, .stream_id = 8 },
    );
    try std.testing.expectEqual(ForeignKind.stream, switch (foreign_stream) {
        .foreign => |kind| kind,
        else => return error.TestUnexpectedResult,
    });
    try std.testing.expect(preflightEvent(
        "{\"event\":\"runtime.ended\",\"extra\":1}",
        .{},
    ) == .malformed);
    try std.testing.expect(preflightEvent(
        "{\"event\":\"runtime.resized\",\"data\":{\"runtime_id\":" ++
            "\"000000000000000000000000000000aa\",\"cols\":120,\"rows\":40," ++
            "\"resize_generation\":9223372036854775808,\"reason\":\"controller\"}}",
        .{},
    ) == .malformed);
}

test "metadata accepts escapes and scalar unknowns and rejects nested unknowns" {
    const valid =
        "{\"event\":\"runtime.metad\\u0061ta\",\"metadata_revision\":2,\"metadata\":{" ++
        "\"cwd\":\"/r\\u0065po\",\"window_title\":\"work\",\"ssh_remote_dest\":null," ++
        "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
        "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2," ++
        "\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":7," ++
        "\"processes\":[{\"pid\":7,\"name\":\"z\\u0073h\",\"future\":true}]," ++
        "\"future_scalar\":\"ok\"}}";
    const accepted = switch (preflightEvent(valid, .{})) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const metadata = switch (accepted.event) {
        .metadata => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expect(spanEquals(valid, metadata.cwd, "/repo"));
    try std.testing.expect(spanEquals(valid, metadata.foregroundProcesses()[0].name, "zsh"));
    var decoded_cwd: [5]u8 = undefined;
    try decodeStringExact(valid, metadata.cwd, &decoded_cwd);
    try std.testing.expectEqualStrings("/repo", &decoded_cwd);
    var oversized = [_]u8{0xa5} ** 6;
    try std.testing.expectError(
        error.LengthMismatch,
        decodeStringExact(valid, metadata.cwd, &oversized),
    );
    try std.testing.expectEqualSlices(u8, &([_]u8{0xa5} ** 6), &oversized);
    var forged = metadata.cwd;
    forged.digest = [_]u8{0} ** Sha256.digest_length;
    var unchanged = [_]u8{0x5a} ** 5;
    try std.testing.expectError(error.InvalidSpan, decodeStringExact(valid, forged, &unchanged));
    try std.testing.expectEqualSlices(u8, &([_]u8{0x5a} ** 5), &unchanged);
    try decodeStringExact(valid, metadata.clipboard_read_target, &.{});

    const nested = std.mem.replaceOwned(
        u8,
        std.testing.allocator,
        valid,
        "\"future_scalar\":\"ok\"",
        "\"future_scalar\":{}",
    ) catch return error.OutOfMemory;
    defer std.testing.allocator.free(nested);
    try std.testing.expect(preflightEvent(nested, .{}) == .malformed);
}

test "P4 metadata event binds one nonzero observation probe nonce" {
    const payload =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"observation_probe_nonce\":48879,\"metadata\":{" ++
        "\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null," ++
        "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
        "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2," ++
        "\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null," ++
        "\"processes\":[]}}";
    const accepted = switch (preflightEvent(payload, .{})) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqual(@as(?u64, 48879), accepted.event.metadata.observation_probe_nonce);
    try std.testing.expect(preflightEvent(
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"observation_probe_nonce\":0,\"metadata\":{}}",
        .{},
    ) == .malformed);
}

test "decoded duplicate keys use exact fallback under an injected key digest collision" {
    const Collision = struct {
        fn finish(_: ?*anyopaque, _: Digest) Digest {
            return [_]u8{0} ** Sha256.digest_length;
        }
    };
    const ops: DigestOps = .{ .finish_key = Collision.finish };
    const distinct =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{" ++
        "\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null," ++
        "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
        "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2," ++
        "\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null," ++
        "\"processes\":[],\"different\":1}}";
    try std.testing.expect(preflightEventWithDigestOps(distinct, .{}, ops) == .accepted);

    const duplicate =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{" ++
        "\"cwd\":\"/repo\",\"c\\u0077d\":\"/other\",\"window_title\":\"work\"," ++
        "\"ssh_remote_dest\":null,\"semantic_state\":0,\"alt_active\":false," ++
        "\"app_cursor_keys\":false,\"alternate_scroll\":true,\"observer_generation\":1," ++
        "\"title_generation\":2,\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
        "\"foreground_pgid\":null,\"processes\":[]}}";
    try std.testing.expect(preflightEventWithDigestOps(duplicate, .{}, ops) == .malformed);
}

test "resource caps drain remaining syntax and malformed syntax still wins" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.writeAll(
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{" ++
            "\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null," ++
            "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
            "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2," ++
            "\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null," ++
            "\"processes\":[]",
    );
    for (0..max_metadata_fields) |index|
        try out.writer.print(",\"x{d}\":{d}", .{ index, index });
    try out.writer.writeAll("}}");
    const resource = try std.testing.allocator.dupe(u8, out.written());
    defer std.testing.allocator.free(resource);
    try std.testing.expect(preflightEvent(resource, .{}) == .resource_exhausted);

    resource[resource.len - 1] = ']';
    try std.testing.expect(preflightEvent(resource, .{}) == .malformed);
}

test "resource drain accepts depth 32 rejects 33 and invalid UTF-8 is malformed" {
    const makeDepthPayload = struct {
        fn call(allocator: std.mem.Allocator, nested_arrays: usize) ![]u8 {
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            try out.writer.writeAll(
                "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{" ++
                    "\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null," ++
                    "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
                    "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2," ++
                    "\"cols\":80,\"rows\":24,\"foreground_available\":false," ++
                    "\"foreground_pgid\":null,\"processes\":[]",
            );
            for (0..max_metadata_fields - 14) |index|
                try out.writer.print(",\"x{d}\":{d}", .{ index, index });
            try out.writer.writeAll(",\"overflow\":");
            for (0..nested_arrays) |_| try out.writer.writeByte('[');
            try out.writer.writeByte('0');
            for (0..nested_arrays) |_| try out.writer.writeByte(']');
            try out.writer.writeAll("}}");
            return allocator.dupe(u8, out.written());
        }
    }.call;

    const depth32 = try makeDepthPayload(std.testing.allocator, max_depth - 3);
    defer std.testing.allocator.free(depth32);
    try std.testing.expect(preflightEvent(depth32, .{}) == .resource_exhausted);
    const depth33 = try makeDepthPayload(std.testing.allocator, max_depth - 2);
    defer std.testing.allocator.free(depth33);
    try std.testing.expect(preflightEvent(depth33, .{}) == .malformed);

    var invalid_utf8 = "{\"event\":\"runtime.ended\"}".*;
    invalid_utf8[10] = 0xff;
    try std.testing.expect(preflightEvent(&invalid_utf8, .{}) == .malformed);
}

test "fields beyond an admitted cap are syntax-only and cannot become semantic duplicate errors" {
    var out: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer out.deinit();
    try out.writer.writeAll(
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{" ++
            "\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null," ++
            "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
            "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2," ++
            "\"cols\":80,\"rows\":24,\"foreground_available\":false,\"foreground_pgid\":null," ++
            "\"processes\":[]",
    );
    // The metadata object has 14 admitted fields above. Fill it to exactly 64.
    for (0..max_metadata_fields - 14) |index|
        try out.writer.print(",\"x{d}\":{d}", .{ index, index });
    // This exact duplicate is field 65, so it is outside the admitted semantic set.
    try out.writer.writeAll(",\"cwd\":{},\"cols\":\"not-semantically-checked\"}}");
    try std.testing.expect(preflightEvent(out.written(), .{}) == .resource_exhausted);

    const process_overflow =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{" ++
        "\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null," ++
        "\"semantic_state\":0,\"alt_active\":false,\"app_cursor_keys\":false," ++
        "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2," ++
        "\"cols\":80,\"rows\":24,\"foreground_available\":true,\"foreground_pgid\":7," ++
        "\"processes\":[{\"pid\":7,\"a\":0,\"b\":0,\"c\":0,\"d\":0,\"e\":0,\"f\":0," ++
        "\"g\":0,\"name\":{}}],\"bell_count\":\"also-not-semantically-checked\"}}";
    try std.testing.expect(preflightEvent(process_overflow, .{}) == .resource_exhausted);
}

test "control-cap strings and strings larger than scratch stream without allocation" {
    const prefix =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{" ++
        "\"cwd\":\"";
    const suffix =
        "\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0," ++
        "\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true," ++
        "\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24," ++
        "\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    const fill_len = protocol.max_control_json - prefix.len - suffix.len;
    const exact = try std.testing.allocator.alloc(u8, protocol.max_control_json);
    defer std.testing.allocator.free(exact);
    @memcpy(exact[0..prefix.len], prefix);
    @memset(exact[prefix.len..][0..fill_len], 'a');
    @memcpy(exact[prefix.len + fill_len ..], suffix);
    try std.testing.expect(preflightEvent(exact, .{}) == .accepted);

    const over = try std.testing.allocator.alloc(u8, protocol.max_control_json + 1);
    defer std.testing.allocator.free(over);
    @memcpy(over[0..exact.len], exact);
    over[exact.len] = ' ';
    try std.testing.expect(preflightEvent(over, .{}) == .resource_exhausted);

    const escape_count = 2048;
    const escaped_len = prefix.len + escape_count * 6 + suffix.len;
    try std.testing.expect(escaped_len > event_preflight_scratch_bytes);
    const escaped = try std.testing.allocator.alloc(u8, escaped_len);
    defer std.testing.allocator.free(escaped);
    @memcpy(escaped[0..prefix.len], prefix);
    var offset = prefix.len;
    for (0..escape_count) |_| {
        @memcpy(escaped[offset..][0..6], "\\u0061");
        offset += 6;
    }
    @memcpy(escaped[offset..], suffix);
    try std.testing.expect(preflightEvent(escaped, .{}) == .accepted);
}

test "semantic digest collision still requires exact replay equality" {
    const Collision = struct {
        fn finish(_: ?*anyopaque, _: Digest) Digest {
            return [_]u8{0x5a} ** Sha256.digest_length;
        }
    };
    const ops: DigestOps = .{ .finish_semantic = Collision.finish };
    const prefix =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{" ++
        "\"cwd\":\"";
    const suffix =
        "\",\"window_title\":\"work\",\"ssh_remote_dest\":null,\"semantic_state\":0," ++
        "\"alt_active\":false,\"app_cursor_keys\":false,\"alternate_scroll\":true," ++
        "\"observer_generation\":1,\"title_generation\":2,\"cols\":80,\"rows\":24," ++
        "\"foreground_available\":false,\"foreground_pgid\":null,\"processes\":[]}}";
    const a_payload = prefix ++ "/one" ++ suffix;
    const b_payload = prefix ++ "/two" ++ suffix;
    const a_preflight = switch (preflightEventWithDigestOps(a_payload, .{}, ops)) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const a = switch (a_preflight.event) {
        .metadata => |value| value,
        else => unreachable,
    };
    const b_preflight = switch (preflightEventWithDigestOps(b_payload, .{}, ops)) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const b = switch (b_preflight.event) {
        .metadata => |value| value,
        else => unreachable,
    };
    try std.testing.expectEqualSlices(u8, &a.semantic_digest, &b.semantic_digest);
    try std.testing.expect(!metadataSemanticEqlExact(a_payload, &a, b_payload, &b));
}

test "metadata semantic equality compares normalized values rather than raw optional syntax" {
    const prefix =
        "{\"event\":\"runtime.metadata\",\"metadata_revision\":2,\"metadata\":{" ++
        "\"cwd\":\"/repo\",\"window_title\":\"work\",\"ssh_remote_dest\":null," ++
        "\"semantic_state\":255,\"alt_active\":false,\"app_cursor_keys\":false," ++
        "\"alternate_scroll\":true,\"observer_generation\":1,\"title_generation\":2," ++
        "\"cols\":80,\"rows\":24,\"foreground_available\":false,";
    const a_payload = prefix ++
        "\"foreground_pgid\":7,\"processes\":[{\"pid\":7,\"name\":\"zsh\"}]}}";
    const b_payload = prefix ++
        "\"app_keypad\":false,\"kitty_flags\":0,\"mouse_tracking\":false," ++
        "\"mouse_tracking_mode\":0,\"bracketed_paste\":false,\"bell_count\":0," ++
        "\"clipboard_write_seq\":0,\"clipboard_read_seq\":0,\"clipboard_read_target\":\"\"," ++
        "\"foreground_pgid\":null,\"processes\":[]}}";
    const a_preflight = switch (preflightEvent(a_payload, .{})) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const b_preflight = switch (preflightEvent(b_payload, .{})) {
        .accepted => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const a = switch (a_preflight.event) {
        .metadata => |value| value,
        else => return error.TestUnexpectedResult,
    };
    const b = switch (b_preflight.event) {
        .metadata => |value| value,
        else => return error.TestUnexpectedResult,
    };
    try std.testing.expectEqualSlices(u8, &a.semantic_digest, &b.semantic_digest);
    try std.testing.expect(metadataSemanticEqlExact(a_payload, &a, b_payload, &b));
}
