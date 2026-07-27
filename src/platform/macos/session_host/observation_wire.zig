//! Thin compatibility facade over the runtime metadata wire SSOT.
//!
//! Queue coalescing needs only a revision scalar. It must not carry a second schema/range/default
//! implementation that can accept a value the owning GUI projection later rejects.

const std = @import("std");
const runtime_event_wire = @import("runtime_event_wire.zig");
const runtime_metadata_wire = @import("runtime_metadata_wire.zig");

pub const ValidationError = error{
    OutOfMemory,
    ResourceExhausted,
    CapabilityViolation,
};

pub fn eventRevision(
    allocator: std.mem.Allocator,
    payload: []const u8,
    support: runtime_metadata_wire.MetadataSupport,
) ValidationError!?u64 {
    _ = allocator;
    return switch (runtime_event_wire.preflightEvent(payload, .{})) {
        .accepted => |preflight| switch (preflight.event) {
            .metadata => |metadata| if (support == .unsupported)
                error.CapabilityViolation
            else
                metadata.revision,
            else => null,
        },
        .resource_exhausted => error.ResourceExhausted,
        .malformed, .unknown, .foreign => null,
    };
}

test "observation wire delegates full-u64 schema and capability verdict to common leaf" {
    const allocator = std.testing.allocator;
    const metadata =
        \\{"cwd":"/repo","window_title":"work","ssh_remote_dest":null,"semantic_state":0,"alt_active":false,
        \\"app_cursor_keys":false,"alternate_scroll":true,"observer_generation":18446744073709551615,
        \\"title_generation":1,"cols":80,"rows":24,"bell_count":18446744073709551615,
        \\"clipboard_write_seq":18446744073709551615,"clipboard_read_seq":18446744073709551615,
        \\"foreground_available":false,"foreground_pgid":null,"processes":[]}
    ;
    const event = try std.fmt.allocPrint(
        allocator,
        "{{\"event\":\"runtime.metadata\",\"metadata_revision\":18446744073709551615,\"metadata\":{s}}}",
        .{metadata},
    );
    defer allocator.free(event);
    try std.testing.expectEqual(
        @as(?u64, std.math.maxInt(u64)),
        try eventRevision(allocator, event, .supported),
    );
    try std.testing.expectError(
        error.CapabilityViolation,
        eventRevision(allocator, event, .unsupported),
    );
    const malformed = try std.mem.replaceOwned(
        u8,
        allocator,
        event,
        "\"cols\":80",
        "\"cols\":-1",
    );
    defer allocator.free(malformed);
    try std.testing.expectEqual(
        @as(?u64, null),
        try eventRevision(allocator, malformed, .supported),
    );
}
