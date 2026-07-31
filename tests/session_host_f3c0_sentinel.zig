//! Non-test-runner sentinel for the F3c0 focused gate.
//!
//! Compile-time filtered Zig tests may legally select zero tests. This executable keeps the gate
//! non-empty and checks the public typed admission/codec shape even if a component test is renamed.

const pump = @import("client_external_pump");

pub fn main() !void {
    comptime {
        if (!@hasField(pump.ControlAdmissionSpec, "request"))
            @compileError("F3c0 typed control request field disappeared");
        if (@hasField(pump.ControlAdmissionSpec, "payload"))
            @compileError("F3c0 raw JSON admission capability returned");
    }

    const spec = pump.ControlAdmissionSpec{
        .request = .{ .resize = .{
            .stream_id = 7,
            .cols = 80,
            .rows = 24,
            .client_sequence = 11,
        } },
        .expected_controller_generation = 13,
    };
    if (!spec.request.isCanonical()) return error.TypedContractDrift;
}
