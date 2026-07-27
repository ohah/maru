//! `runtime.resized` full-state event의 strict decoder.

const std = @import("std");

/// `std.json.Value.integer`와 모든 현재 MRSH JSON adapter가 lossless로 운반하는 counter 상한.
pub const max_counter: u64 = @intCast(std.math.maxInt(i64));

pub const Event = struct {
    runtime_id: u128,
    cols: u16,
    rows: u16,
    resize_generation: u64,
};
