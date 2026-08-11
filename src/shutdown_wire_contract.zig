//! 종료 backend와 앱 조합 계층이 함께 쓰는 포인터 없는 wire 권위 값이다.

const std = @import("std");

pub const Digest = [32]u8;
pub const zero_digest = [_]u8{0} ** 32;

pub const ShutdownOperation = enum(u8) { terminate, inventory };
pub const InventoryAttempt = enum(u8) { none, initial, retry };

pub const ShutdownAttemptKey = struct {
    close_request_generation: u64 = 0,
    target_digest: Digest = zero_digest,
    attempt_generation: u64 = 0,
};

pub const ShutdownConnectionReceipt = struct {
    self_addr: u64 = 0,
    pid: u32 = 0,
    reserved_pid: u32 = 0,
    process_nonce: u64 = 0,
    thread_id: u64 = 0,
    authority_addr: u64 = 0,
    attempt_key: ShutdownAttemptKey = .{},
    connection_identity: u64 = 0,
    lease_generation: u64 = 0,
    operation_raw: u8 = @intFromEnum(ShutdownOperation.terminate),
    inventory_attempt_raw: u8 = @intFromEnum(InventoryAttempt.none),
    consumed_raw: u8 = 0,
    reserved: [5]u8 = [_]u8{0} ** 5,
    transcript_digest: Digest = zero_digest,
    seal: Digest = zero_digest,
};

pub const PreConnectionReason = enum(u8) {
    attempt_cap_before_send,
    deadline_before_send,
    profile_incompatible,
};

pub const PostConnectionReason = enum(u8) {
    attempt_cap_after_send,
    deadline_after_send,
    inventory_retry_ambiguous,
    n1_sent_ambiguous,
};

pub const BoundedUnconfirmed = union(enum) {
    pre_connection: struct {
        reason: PreConnectionReason,
        attempt_key: ShutdownAttemptKey,
    },
    post_connection: struct {
        reason: PostConnectionReason,
        attempt_key: ShutdownAttemptKey,
        consumed_connection: Digest,
    },
};

pub const ShutdownAdminOutcome = union(enum) {
    not_sent: ShutdownAttemptKey,
    request_in_flight: ShutdownConnectionReceipt,
    sent_ambiguous: ShutdownConnectionReceipt,
    awaiting_admin_barrier: ShutdownAttemptKey,
    inventory_in_flight: ShutdownConnectionReceipt,
    terminate_confirmed: ShutdownConnectionReceipt,
    absence_confirmed: ShutdownConnectionReceipt,
    bounded_unconfirmed: BoundedUnconfirmed,
};

pub const ShutdownDiagnosticReason = enum(u8) {
    terminate_unconfirmed,
    profile_incompatible,
    deadline_exhausted,
};

pub const ShutdownElapsedBucket = enum(u8) {
    lt100ms,
    lt500ms,
    lt1s,
    lt5s,
    lt15s,
    ge15s,
};

pub const ShutdownDiagnostic = struct {
    reason: ShutdownDiagnosticReason,
    target_ordinal: u16,
    attempt_count: u8,
    elapsed_bucket: ShutdownElapsedBucket,
    app_quit: bool,
};

pub fn bucketShutdownElapsed(now_ns: u64, started_at_ns: u64) ShutdownElapsedBucket {
    const elapsed = if (now_ns < started_at_ns) 0 else now_ns - started_at_ns;
    if (elapsed < 100 * std.time.ns_per_ms) return .lt100ms;
    if (elapsed < 500 * std.time.ns_per_ms) return .lt500ms;
    if (elapsed < std.time.ns_per_s) return .lt1s;
    if (elapsed < 5 * std.time.ns_per_s) return .lt5s;
    if (elapsed < 15 * std.time.ns_per_s) return .lt15s;
    return .ge15s;
}
