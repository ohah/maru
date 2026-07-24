//! 여러 U단계가 함께 소비하는 live-upgrade 제품 cap과 pause budget SSOT.

const std = @import("std");

pub const max_target_path_bytes: usize = 1024;
pub const max_build_id_bytes: usize = 128;
pub const max_runtime_count: usize = 256;
pub const max_completed_history: usize = 256;
pub const max_running_record_completed: usize = max_completed_history - 1;
pub const max_attempt_record_bytes: usize = 512 * 1024;
pub const max_staged_image_bytes: u64 = 512 * 1024 * 1024;
/// 8 GiB는 codec 방어 cap이고 product pause 중 durable two-copy commit은 이 현실적 I/O cap을 쓴다.
pub const max_handoff_commit_bytes: usize = 64 * 1024 * 1024;
pub const pause_budget_ms: u64 = 5_000;
pub const pause_budget_ns: i128 = pause_budget_ms * std.time.ns_per_ms;
