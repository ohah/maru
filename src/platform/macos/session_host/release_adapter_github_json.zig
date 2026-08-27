//! Shared bounded JSON envelope for GitHub REST responses consumed by the release adapter.
//!
//! Endpoint-specific modules own semantic fields. This module owns the common byte cap, scalar
//! cap, and exactly-one-complete-root rule so those security limits cannot drift by endpoint.

const std = @import("std");
const release_manifest = @import("release_manifest");

pub const max_response_bytes: usize = 64 * 1024;

pub const Error = error{
    ResponseTooLarge,
    InvalidJson,
};

pub fn validateCompleteResponse(bytes: []const u8) Error!void {
    if (bytes.len > max_response_bytes) return error.ResponseTooLarge;

    var scratch: [max_response_bytes]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&scratch);
    var scanner = std.json.Scanner.initCompleteInput(fixed.allocator(), bytes);
    defer scanner.deinit();
    while (true) {
        const token = scanner.nextAllocMax(
            fixed.allocator(),
            .alloc_if_needed,
            release_manifest.max_scalar_string_bytes,
        ) catch return error.InvalidJson;
        if (token == .end_of_document) {
            // The scanner reports a complete first root before guaranteeing that the input slice
            // ends there. Binding its cursor to the final byte rejects a second root and garbage.
            if (scanner.cursor != bytes.len) return error.InvalidJson;
            return;
        }
    }
}
