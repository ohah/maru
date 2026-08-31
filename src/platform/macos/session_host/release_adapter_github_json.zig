//! Shared bounded JSON envelope for GitHub REST responses consumed by the release adapter.
//!
//! Endpoint-specific modules own semantic fields. This module owns the common byte cap, scalar
//! cap, and exactly-one-complete-root rule so those security limits cannot drift by endpoint.

const std = @import("std");
const release_manifest = @import("release_manifest");

pub const max_response_bytes: usize = 64 * 1024;
pub const max_scalar_string_bytes = release_manifest.max_scalar_string_bytes;

pub const Error = error{
    ResponseTooLarge,
    InvalidJson,
};

pub fn validateCompleteResponse(bytes: []const u8) Error!void {
    if (bytes.len > max_response_bytes) return error.ResponseTooLarge;

    // Scanner uses bounded storage only for its nesting bit stack. Scalar contents are counted
    // directly below and are never copied into this allocator.
    var scratch: [max_response_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), bytes);
    defer scanner.deinit();
    var scalar_len: usize = 0;
    while (true) {
        const token = scanner.next() catch return error.InvalidJson;
        switch (token) {
            .partial_number, .partial_string => |slice| try addScalarBytes(&scalar_len, slice.len),
            .partial_string_escaped_1 => |value| try addScalarBytes(&scalar_len, value.len),
            .partial_string_escaped_2 => |value| try addScalarBytes(&scalar_len, value.len),
            .partial_string_escaped_3 => |value| try addScalarBytes(&scalar_len, value.len),
            .partial_string_escaped_4 => |value| try addScalarBytes(&scalar_len, value.len),
            .number, .string => |slice| {
                try addScalarBytes(&scalar_len, slice.len);
                scalar_len = 0;
            },
            .end_of_document => {
                // The scanner reports a complete first root before guaranteeing that the input
                // slice ends there. Binding its cursor to the final byte rejects trailing roots.
                if (scanner.cursor != bytes.len) return error.InvalidJson;
                return;
            },
            else => {},
        }
    }
}

fn addScalarBytes(current: *usize, additional: usize) Error!void {
    if (additional > max_scalar_string_bytes - current.*) return error.InvalidJson;
    current.* += additional;
}
