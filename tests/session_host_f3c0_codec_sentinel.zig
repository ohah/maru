//! Executable sentinel proving the focused codec component selected real typed behavior.

const std = @import("std");
const codec = @import("control_response_wire");

pub fn main() !void {
    const key = codec.ControlExpectation{ .resync = .{
        .owner_incarnation = 1,
        .origin = .client,
        .recovery_epoch = 2,
    } };
    try codec.decodeResyncResponse(
        std.heap.page_allocator,
        "{\"result\":{\"resync\":true}}",
        key,
    );
    if (codec.decodeResyncResponse(
        std.heap.page_allocator,
        "{\"result\":{\"resync\":true}}",
        .{ .resize = .{ .client_sequence = 1 } },
    )) |_| return error.WrongKindAccepted else |err| if (err != error.Malformed) return err;
}
