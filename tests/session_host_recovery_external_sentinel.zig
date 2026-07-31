//! External-pump sentinel for the pre-token resync admission boundary.

const pump = @import("client_external_pump");

pub fn main() !void {
    const spec = pump.ControlAdmissionSpec{
        .request = .{ .resync = .{
            .stream_id = 7,
            .recovery_authority = .{
                .owner_incarnation = 3,
                .origin = .client,
                .recovery_epoch = 5,
            },
        } },
        .expected_controller_generation = 11,
    };
    if (!spec.request.isCanonical()) return error.PreTokenAuthorityDrift;
}
