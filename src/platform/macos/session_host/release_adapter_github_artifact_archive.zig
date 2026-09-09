//! Strict single-entry GitHub Actions artifact ZIP decoder shared by release evidence consumers.

const std = @import("std");

pub const archive_cap: usize = 64 * 1024;
const max_compression_ratio: usize = 64;

pub fn extractAlloc(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    expected_name: []const u8,
    plain_cap: usize,
) ![]u8 {
    if (!validName(expected_name) or plain_cap == 0 or plain_cap > archive_cap or bytes.len > archive_cap)
        return error.InvalidArchive;
    const entry = try parse(bytes, expected_name, plain_cap);
    const plain = try allocator.alloc(u8, entry.uncompressed_size);
    errdefer allocator.free(plain);
    switch (entry.method) {
        0 => @memcpy(plain, entry.compressed),
        8 => {
            var input: std.Io.Reader = .fixed(entry.compressed);
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var decompressor = std.compress.flate.Decompress.init(&input, .raw, &window);
            decompressor.reader.readSliceAll(plain) catch return error.InvalidArchive;
            var extra: [1]u8 = undefined;
            if ((decompressor.reader.readSliceShort(&extra) catch return error.InvalidArchive) != 0 or input.bufferedLen() != 0)
                return error.InvalidArchive;
        },
        else => unreachable,
    }
    if (std.hash.Crc32.hash(plain) != entry.crc32) return error.InvalidArchive;
    return plain;
}

const Entry = struct {
    method: u16,
    crc32: u32,
    uncompressed_size: usize,
    compressed: []const u8,
};

fn parse(bytes: []const u8, expected_name: []const u8, plain_cap: usize) !Entry {
    const eocd_size = 22;
    const central_size = 46;
    const local_size = 30;
    if (bytes.len < eocd_size + central_size + local_size + expected_name.len or bytes.len > archive_cap)
        return error.InvalidArchive;
    const eocd_at = bytes.len - eocd_size;
    if (!std.mem.eql(u8, bytes[eocd_at..][0..4], "PK\x05\x06") or read16(bytes, eocd_at + 4) != 0 or
        read16(bytes, eocd_at + 6) != 0 or read16(bytes, eocd_at + 8) != 1 or read16(bytes, eocd_at + 10) != 1 or
        read16(bytes, eocd_at + 20) != 0) return error.InvalidArchive;
    const cd_bytes = read32(bytes, eocd_at + 12);
    const cd_at = read32(bytes, eocd_at + 16);
    if (cd_at > eocd_at or cd_bytes != eocd_at - cd_at or cd_bytes < central_size or
        !std.mem.eql(u8, bytes[cd_at..][0..4], "PK\x01\x02")) return error.InvalidArchive;

    const version_made = read16(bytes, cd_at + 4);
    const version_needed = read16(bytes, cd_at + 6);
    const flags = read16(bytes, cd_at + 8);
    const method = read16(bytes, cd_at + 10);
    const crc32 = read32(bytes, cd_at + 16);
    const compressed_size = read32(bytes, cd_at + 20);
    const uncompressed_size = read32(bytes, cd_at + 24);
    const name_len = read16(bytes, cd_at + 28);
    const extra_len = read16(bytes, cd_at + 30);
    const comment_len = read16(bytes, cd_at + 32);
    const disk = read16(bytes, cd_at + 34);
    const external_attributes = read32(bytes, cd_at + 38);
    const local_at = read32(bytes, cd_at + 42);
    const descriptor = flags & 0x0008 != 0;
    if (version_needed > 45 or flags & ~@as(u16, 0x0808) != 0 or flags & 1 != 0 or (method != 0 and method != 8) or
        compressed_size == 0 or uncompressed_size == 0 or uncompressed_size > plain_cap or
        (method == 0 and compressed_size != uncompressed_size) or compressed_size > archive_cap or
        uncompressed_size > @as(u64, compressed_size) * max_compression_ratio or name_len != expected_name.len or
        extra_len != 0 or comment_len != 0 or disk != 0 or local_at != 0 or
        cd_at + central_size + name_len != eocd_at or !std.mem.eql(u8, bytes[cd_at + central_size ..][0..name_len], expected_name))
        return error.InvalidArchive;
    const unix_mode: u16 = @truncate(external_attributes >> 16);
    if (version_made >> 8 != 3 or unix_mode & 0o170000 != 0o100000) return error.InvalidArchive;

    if (!std.mem.eql(u8, bytes[0..4], "PK\x03\x04") or read16(bytes, 4) != version_needed or
        read16(bytes, 6) != flags or read16(bytes, 8) != method or read16(bytes, 10) != read16(bytes, cd_at + 12) or
        read16(bytes, 12) != read16(bytes, cd_at + 14) or read16(bytes, 26) != name_len or read16(bytes, 28) != 0 or
        !std.mem.eql(u8, bytes[local_size..][0..name_len], expected_name)) return error.InvalidArchive;
    if (!descriptor and (read32(bytes, 14) != crc32 or read32(bytes, 18) != compressed_size or read32(bytes, 22) != uncompressed_size))
        return error.InvalidArchive;
    if (descriptor and (read32(bytes, 14) != 0 or read32(bytes, 18) != 0 or read32(bytes, 22) != 0))
        return error.InvalidArchive;
    const data_at = local_size + name_len;
    const data_end = std.math.add(usize, data_at, compressed_size) catch return error.InvalidArchive;
    if (descriptor) {
        if (data_end + 16 != cd_at or !std.mem.eql(u8, bytes[data_end..][0..4], "PK\x07\x08") or
            read32(bytes, data_end + 4) != crc32 or read32(bytes, data_end + 8) != compressed_size or
            read32(bytes, data_end + 12) != uncompressed_size) return error.InvalidArchive;
    } else if (data_end != cd_at) return error.InvalidArchive;
    return .{ .method = method, .crc32 = crc32, .uncompressed_size = uncompressed_size, .compressed = bytes[data_at..data_end] };
}

fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > std.fs.max_name_bytes or std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
    for (name) |byte| if (byte < 0x20 or byte == 0x7f or byte == '/' or byte == '\\' or byte == 0) return false;
    return true;
}

fn read16(bytes: []const u8, at: usize) u16 {
    return std.mem.readInt(u16, bytes[at..][0..2], .little);
}

fn read32(bytes: []const u8, at: usize) u32 {
    return std.mem.readInt(u32, bytes[at..][0..4], .little);
}
