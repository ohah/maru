//! Pointer-free canonical projection for a prepared runtime decision.
//!
//! This neutral leaf owns the stable raw vocabulary consumed by cleanup seals. Semantic policy
//! remains in runtime_event_prepared_types; every owner and validator compares this one shape.

const std = @import("std");

pub const PreparedEventTag = enum(u8) {
    ignored = 0,
    ended = 1,
    invalidated = 2,
    resize_noop = 3,
    resize_commit = 4,
    metadata_noop = 5,
    metadata_commit = 6,
    revoked = 7,
    failure = 8,
};

pub const EffectTag = enum(u8) {
    none = 0,
    poison = 1,
    revoke_fence = 2,
};

pub const PreparationFailure = enum(u8) {
    out_of_memory = 1,
    local_resource_exhausted = 2,
    protocol_error = 3,
    connection_closed = 4,
};

pub const local_resource_exhausted_reason_raw: u8 = 9;
pub const peer_contract_violation_reason_raw: u8 = 12;

pub const Projection = struct {
    bound_raw: u8 = 0,
    prepared_tag_raw: u8 = 0,
    effect_tag_raw: u8 = 0,
    failure_raw: u8 = 0,
    connection_reason_raw: u8 = 0,
    cols: u16 = 0,
    rows: u16 = 0,
    semantic_generation: u64 = 0,
    observation_probe_nonce: u64 = 0,
};

pub fn canonical(value: Projection, retained_observation: bool) bool {
    if (value.bound_raw == 0) return std.meta.eql(value, Projection{});
    if (value.bound_raw != 1) return false;
    const tag = std.enums.fromInt(PreparedEventTag, value.prepared_tag_raw) orelse return false;
    const effect = std.enums.fromInt(EffectTag, value.effect_tag_raw) orelse return false;
    return switch (tag) {
        .ignored, .ended, .invalidated, .resize_noop => !retained_observation and effect == .none and value.failure_raw == 0 and
            value.connection_reason_raw == 0 and value.cols == 0 and value.rows == 0 and
            value.semantic_generation == 0 and value.observation_probe_nonce == 0,
        .metadata_noop => !retained_observation and effect == .none and value.failure_raw == 0 and
            value.connection_reason_raw == 0 and value.cols == 0 and value.rows == 0 and
            value.semantic_generation == 0,
        .resize_commit => !retained_observation and effect == .none and
            value.failure_raw == 0 and value.connection_reason_raw == 0 and
            value.cols >= 2 and value.rows != 0 and value.semantic_generation != 0 and
            value.observation_probe_nonce == 0,
        .metadata_commit => retained_observation and effect == .none and
            value.failure_raw == 0 and value.connection_reason_raw == 0 and
            value.cols == 0 and value.rows == 0 and value.semantic_generation == 0,
        .revoked => !retained_observation and effect == .revoke_fence and
            value.failure_raw == 0 and value.connection_reason_raw == 0 and
            value.cols == 0 and value.rows == 0 and value.semantic_generation != 0 and
            value.observation_probe_nonce == 0,
        .failure => !retained_observation and value.cols == 0 and value.rows == 0 and value.semantic_generation == 0 and
            value.observation_probe_nonce == 0 and
            switch (std.enums.fromInt(
                PreparationFailure,
                value.failure_raw,
            ) orelse return false) {
                .out_of_memory, .local_resource_exhausted => effect == .poison and
                    value.connection_reason_raw == local_resource_exhausted_reason_raw,
                .protocol_error => effect == .poison and
                    value.connection_reason_raw == peer_contract_violation_reason_raw,
                .connection_closed => effect == .none and value.connection_reason_raw == 0,
            },
    };
}

comptime {
    if (std.meta.fields(Projection).len != 9) @compileError("decision seal projection ABI drift");
}
