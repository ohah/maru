//! Product composition for P5d against the CLI held inside one private read-only candidate DMG.

const std = @import("std");
const dmg = @import("release_adapter_dmg_authority");
const apple_product = @import("release_adapter_apple_product");
const apple_transport = @import("release_adapter_apple_transport");
const gate_mod = @import("release_adapter_p5d_candidate_gate");

pub const Inputs = struct {
    candidate_dmg: [:0]const u8,
    private_dmg_work: [:0]const u8,
    expected_dmg: dmg.ExpectedDmg,
    expected_version: []const u8,
    gate: gate_mod.Inputs,
    budget_ns: i128,
};

/// On success `result` owns the exact published leaf until R3 consumes it and calls `finish`.
/// On cleanup failure it retains the only retry authority and the caller must call `cleanup`.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    inputs: Inputs,
    capture: []u8,
    apple_storage: *apple_transport.Storage,
    result: *gate_mod.Gate,
) !apple_product.Observed {
    try result.init(allocator, io, inputs.gate, capture);
    return dmg.observeWithMountedGate(
        allocator,
        io,
        result,
        inputs.candidate_dmg,
        inputs.private_dmg_work,
        inputs.expected_dmg,
        inputs.expected_version,
        apple_storage,
        inputs.budget_ns,
    );
}
