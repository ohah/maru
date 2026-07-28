//! Domain-separated, fixed-width transcript helper for process-local external owner seals.
//!
//! These digests are not wire or persistence formats. Callers still compare every semantic scalar
//! before accepting a digest so an injected collision cannot turn a forged cleanup descriptor into
//! allocator authority.

const std = @import("std");

pub const Digest = [32]u8;

pub const Writer = struct {
    hasher: std.crypto.hash.Blake3,

    pub fn init(domain: []const u8) Writer {
        var writer = Writer{ .hasher = std.crypto.hash.Blake3.init(.{}) };
        writer.writeUsize(domain.len);
        writer.hasher.update(domain);
        return writer;
    }

    pub fn writeBool(self: *Writer, value: bool) void {
        self.writeU8(@intFromBool(value));
    }

    pub fn writeU8(self: *Writer, value: u8) void {
        self.hasher.update(&.{value});
    }

    pub fn writeU16(self: *Writer, value: u16) void {
        var bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &bytes, value, .little);
        self.hasher.update(&bytes);
    }

    pub fn writeU64(self: *Writer, value: u64) void {
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, value, .little);
        self.hasher.update(&bytes);
    }

    pub fn writeUsize(self: *Writer, value: usize) void {
        if (@bitSizeOf(usize) == 64) {
            self.writeU64(@intCast(value));
        } else {
            var bytes: [4]u8 = undefined;
            std.mem.writeInt(u32, &bytes, @intCast(value), .little);
            self.hasher.update(&bytes);
        }
    }

    pub fn finish(self: *Writer) Digest {
        var digest: Digest = undefined;
        self.hasher.final(&digest);
        return digest;
    }
};

test "owner seal transcript is domain separated and fixed-width stable" {
    var a = Writer.init("screen.v1");
    a.writeU64(7);
    a.writeBool(true);
    var b = Writer.init("screen.v1");
    b.writeU64(7);
    b.writeBool(true);
    var other_domain = Writer.init("metadata.v1");
    other_domain.writeU64(7);
    other_domain.writeBool(true);
    const a_digest = a.finish();
    const b_digest = b.finish();
    const other_digest = other_domain.finish();
    try std.testing.expectEqualSlices(u8, &a_digest, &b_digest);
    try std.testing.expect(!std.mem.eql(u8, &a_digest, &other_digest));
}
