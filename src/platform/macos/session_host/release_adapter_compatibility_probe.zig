//! Canonical compatibility probe wire shared by candidate authoring and current-manifest verification.

const std = @import("std");
const manifest = @import("release_manifest");

pub const max_probe_bytes: usize = 512;
pub const Error = error{InvalidProbe};
const Wire = struct { mrsh_major: u64, screen_codec: u64, handoff_reader_min: u64, handoff_reader_max: u64, app_host_abi: u64 };

pub fn parse(bytes_with_newline: []const u8) Error!manifest.Compatibility {
    const bytes = if (std.mem.endsWith(u8, bytes_with_newline, "\n")) bytes_with_newline[0 .. bytes_with_newline.len - 1] else bytes_with_newline;
    if (bytes.len == 0 or bytes.len > max_probe_bytes or std.mem.indexOfScalar(u8, bytes, '\r') != null) return error.InvalidProbe;
    var arena_storage: [2048]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&arena_storage);
    var parsed = std.json.parseFromSlice(Wire, fba.allocator(), bytes, .{ .duplicate_field_behavior = .@"error", .ignore_unknown_fields = false }) catch return error.InvalidProbe;
    defer parsed.deinit();
    const value = parsed.value;
    if (value.mrsh_major == 0 or value.screen_codec == 0 or value.handoff_reader_min == 0 or value.handoff_reader_min > value.handoff_reader_max or value.app_host_abi == 0) return error.InvalidProbe;
    var canonical_storage: [max_probe_bytes]u8 = undefined;
    const canonical = std.fmt.bufPrint(&canonical_storage, "{{\"mrsh_major\":{d},\"screen_codec\":{d},\"handoff_reader_min\":{d},\"handoff_reader_max\":{d},\"app_host_abi\":{d}}}", .{ value.mrsh_major, value.screen_codec, value.handoff_reader_min, value.handoff_reader_max, value.app_host_abi }) catch return error.InvalidProbe;
    if (!std.mem.eql(u8, bytes, canonical)) return error.InvalidProbe;
    return .{ .mrsh_major = value.mrsh_major, .screen_codec = value.screen_codec, .handoff_reader_min = value.handoff_reader_min, .handoff_reader_max = value.handoff_reader_max, .app_host_abi = value.app_host_abi };
}
