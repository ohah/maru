//! Test-only neutral oracle for the two issuer-exhaustion rows shared by the ClientSlot
//! product fixture and the aggregate B3 execution table.

pub const Scenario = enum { clean, cleanup_drift };
pub const PublicError = enum { identity_exhausted, protocol_error };

pub const Observation = struct {
    scenario: Scenario,
    request_prepared_only: bool,
    storage_settled: bool,
    authority_terminal: bool,
    connection_local_invariant: bool,
    public_error: PublicError,
    first_poison_local_invariant: bool,
    response_pristine: bool,
    request_free_exact_once: bool,
    payload_never_observed: bool,
    final_zero: bool,
};

pub fn expected(scenario: Scenario) Observation {
    return .{
        .scenario = scenario,
        .request_prepared_only = true,
        .storage_settled = true,
        .authority_terminal = true,
        .connection_local_invariant = true,
        .public_error = switch (scenario) {
            .clean => .identity_exhausted,
            .cleanup_drift => .protocol_error,
        },
        .first_poison_local_invariant = true,
        .response_pristine = true,
        .request_free_exact_once = true,
        .payload_never_observed = true,
        .final_zero = true,
    };
}

test "B3 issuer oracle is closed" {
    const std = @import("std");
    try std.testing.expect(expected(.clean).public_error == .identity_exhausted);
    try std.testing.expect(expected(.cleanup_drift).public_error == .protocol_error);
}
