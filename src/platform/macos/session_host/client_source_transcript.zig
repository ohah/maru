//! Frozen primitive encoder for session-host source-seal transcripts.
//!
//! This leaf intentionally imports only `std`. Client field order, protocol header meaning, and
//! reducer semantics belong to their owning adapters; this module only fixes byte framing.

const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [Sha256.digest_length]u8;

pub const Error = error{
    ValueTooLarge,
    InvalidDescriptor,
};

pub const Domain = enum {
    client_source_v1,
    event_raw_v1,
    event_semantic_v1,
    resize_semantic_v1,

    fn bytes(self: Domain) []const u8 {
        return switch (self) {
            .client_source_v1 => "maru.session-host.client-source.v1\x00",
            .event_raw_v1 => "maru.session-host.event-raw.v1\x00",
            .event_semantic_v1 => "maru.session-host.event-semantic.v1\x00",
            .resize_semantic_v1 => "maru.session-host.resize-semantic.v1\x00",
        };
    }
};

pub const Writer = struct {
    hasher: Sha256,

    pub fn init(domain: Domain) Writer {
        var hasher = Sha256.init(.{});
        hasher.update(domain.bytes());
        return .{ .hasher = hasher };
    }

    pub fn writeU8(self: *Writer, value: u8) void {
        self.hasher.update(&.{value});
    }

    pub fn writeU16(self: *Writer, value: u16) void {
        self.writeUnsigned(u16, value);
    }

    pub fn writeU32(self: *Writer, value: u32) void {
        self.writeUnsigned(u32, value);
    }

    pub fn writeU64(self: *Writer, value: u64) void {
        self.writeUnsigned(u64, value);
    }

    pub fn writeU128(self: *Writer, value: u128) void {
        self.writeUnsigned(u128, value);
    }

    pub fn writeI32(self: *Writer, value: i32) void {
        self.writeU32(@bitCast(value));
    }

    pub fn writeBool(self: *Writer, value: bool) void {
        self.writeU8(@intFromBool(value));
    }

    pub fn writePresence(self: *Writer, present: bool) void {
        self.writeBool(present);
    }

    pub fn writeTag(self: *Writer, tag: u8) void {
        self.writeU8(tag);
    }

    pub fn writeUsize(self: *Writer, value: usize) Error!void {
        self.writeU64(std.math.cast(u64, value) orelse return error.ValueTooLarge);
    }

    pub fn writeBytes(self: *Writer, bytes: []const u8) Error!void {
        try self.writeUsize(bytes.len);
        self.hasher.update(bytes);
    }

    /// Encodes a canonical `{address,len,capacity}` triple.
    ///
    /// Empty storage has no pointer identity and is always encoded as address zero. Non-empty
    /// storage must have a nonzero address and `len <= capacity`.
    pub fn writeAddressLenCapacity(
        self: *Writer,
        address: usize,
        len: usize,
        capacity: usize,
        element_size: usize,
    ) Error!void {
        if (element_size == 0 or len > capacity or (capacity != 0 and address == 0))
            return error.InvalidDescriptor;
        const byte_capacity = std.math.mul(
            usize,
            capacity,
            element_size,
        ) catch return error.InvalidDescriptor;
        if (capacity != 0)
            _ = std.math.add(usize, address, byte_capacity) catch
                return error.InvalidDescriptor;
        try self.writeUsize(if (capacity == 0) 0 else address);
        try self.writeUsize(len);
        try self.writeUsize(capacity);
    }

    pub fn finish(self: Writer) Digest {
        var copy = self;
        var digest: Digest = undefined;
        copy.hasher.final(&digest);
        return digest;
    }

    fn writeUnsigned(self: *Writer, comptime T: type, value: T) void {
        var encoded: [@sizeOf(T)]u8 = undefined;
        std.mem.writeInt(T, &encoded, value, .little);
        self.hasher.update(&encoded);
    }
};

fn shaDigest(bytes: []const u8) Digest {
    var out: Digest = undefined;
    Sha256.hash(bytes, &out, .{});
    return out;
}

test "writer matches the frozen byte transcript" {
    var writer = Writer.init(.client_source_v1);
    writer.writeU8(0x7f);
    writer.writeU16(0x1234);
    writer.writeU32(0x89abcdef);
    writer.writeU64(0x0123456789abcdef);
    writer.writeU128(0x00112233445566778899aabbccddeeff);
    writer.writeI32(-2);
    writer.writeBool(true);
    writer.writePresence(false);
    writer.writeTag(3);
    try writer.writeBytes("ab");
    try writer.writeAddressLenCapacity(0x1234, 2, 5, 1);
    try writer.writeAddressLenCapacity(0x9999, 0, 0, 1);

    const expected =
        "maru.session-host.client-source.v1\x00" ++
        "\x7f" ++
        "\x34\x12" ++
        "\xef\xcd\xab\x89" ++
        "\xef\xcd\xab\x89\x67\x45\x23\x01" ++
        "\xff\xee\xdd\xcc\xbb\xaa\x99\x88\x77\x66\x55\x44\x33\x22\x11\x00" ++
        "\xfe\xff\xff\xff" ++
        "\x01\x00\x03" ++
        "\x02\x00\x00\x00\x00\x00\x00\x00ab" ++
        "\x34\x12\x00\x00\x00\x00\x00\x00" ++
        "\x02\x00\x00\x00\x00\x00\x00\x00" ++
        "\x05\x00\x00\x00\x00\x00\x00\x00" ++
        "\x00\x00\x00\x00\x00\x00\x00\x00" ** 3;
    const frozen_digest =
        "\x10\x3e\x81\x21\x94\x20\x4b\xbe\xfb\xa2\x47\x92\xc8\xa9\xae\xb9" ++
        "\x99\x70\x6e\xa7\x4b\x74\x26\x61\x1f\x58\x26\x1e\xf6\x41\x21\x74";
    try std.testing.expectEqualSlices(u8, frozen_digest, &writer.finish());
    try std.testing.expectEqualSlices(u8, frozen_digest, &shaDigest(expected));
}

test "framing keeps boundaries presence and domains distinct" {
    var left = Writer.init(.client_source_v1);
    try left.writeBytes("ab");
    try left.writeBytes("c");
    var right = Writer.init(.client_source_v1);
    try right.writeBytes("a");
    try right.writeBytes("bc");
    try std.testing.expect(!std.mem.eql(u8, &left.finish(), &right.finish()));

    var absent = Writer.init(.client_source_v1);
    absent.writePresence(false);
    var empty = Writer.init(.client_source_v1);
    empty.writePresence(true);
    try empty.writeBytes("");
    try std.testing.expect(!std.mem.eql(u8, &absent.finish(), &empty.finish()));

    var empty_array = Writer.init(.client_source_v1);
    try empty_array.writeUsize(0);
    var one_empty_item = Writer.init(.client_source_v1);
    try one_empty_item.writeUsize(1);
    try one_empty_item.writeBytes("");
    try std.testing.expect(!std.mem.eql(
        u8,
        &empty_array.finish(),
        &one_empty_item.finish(),
    ));

    var source = Writer.init(.client_source_v1);
    try source.writeBytes("same");
    var event = Writer.init(.event_raw_v1);
    try event.writeBytes("same");
    try std.testing.expect(!std.mem.eql(u8, &source.finish(), &event.finish()));
}

test "all domain bytes are exact NUL terminated and pairwise distinct" {
    const domains = [_]Domain{
        .client_source_v1,
        .event_raw_v1,
        .event_semantic_v1,
        .resize_semantic_v1,
    };
    const expected = [_][]const u8{
        "maru.session-host.client-source.v1\x00",
        "maru.session-host.event-raw.v1\x00",
        "maru.session-host.event-semantic.v1\x00",
        "maru.session-host.resize-semantic.v1\x00",
    };
    const frozen_digests = [_][]const u8{
        "\x97\x24\xbf\x65\xf4\x9d\x08\xd2\x8f\x4d\x52\xf2\xc8\x35\xa2\x4e" ++
            "\xd1\x0a\x0e\xad\x5d\x65\x3b\x71\x71\x98\x0c\x21\xf7\x57\x10\x4b",
        "\x66\xb5\x78\x36\x42\xde\x5b\xc9\xb0\xb2\x77\xb8\xdb\x18\x3d\x13" ++
            "\x9a\x78\x85\xf9\x38\xf7\x9e\x90\xb3\xd8\x76\xef\x5e\x54\xcc\xc2",
        "\x1e\x56\x65\x60\x46\x76\xe5\xa1\x66\x7e\xe9\x5a\x2c\xfb\x14\x36" ++
            "\x3b\xef\x49\x91\x67\x0a\x1e\x14\xb3\xe6\xa2\xe7\x5b\x14\x12\x46",
        "\xf7\xce\x48\x58\xb3\xd6\x56\xec\x07\x2d\x91\xf5\x03\x83\x0c\xda" ++
            "\x33\x2a\xaf\x1a\x5d\xa7\x7b\x6b\x34\xa2\x6f\xc4\x62\xe9\xad\xba",
    };
    try std.testing.expectEqual(std.meta.fields(Domain).len, domains.len);
    for (domains, expected, frozen_digests) |domain, bytes, frozen| {
        try std.testing.expectEqualStrings(bytes, domain.bytes());
        try std.testing.expectEqual(@as(u8, 0), bytes[bytes.len - 1]);
        try std.testing.expectEqualSlices(u8, frozen, &Writer.init(domain).finish());
        try std.testing.expectEqualSlices(u8, frozen, &shaDigest(bytes));
    }
    for (domains, 0..) |left, left_index| {
        for (domains[left_index + 1 ..]) |right| {
            try std.testing.expect(!std.mem.eql(
                u8,
                &Writer.init(left).finish(),
                &Writer.init(right).finish(),
            ));
        }
    }
}

test "finish is repeatable and writer copies fork without shared state" {
    var writer = Writer.init(.client_source_v1);
    writer.writeU8(1);
    try std.testing.expectEqualSlices(u8, &writer.finish(), &writer.finish());

    var fork = writer;
    writer.writeU8(2);
    fork.writeU8(3);
    try std.testing.expect(!std.mem.eql(u8, &writer.finish(), &fork.finish()));
}

test "descriptor rejects impossible shape and canonicalizes empty address" {
    var invalid_len = Writer.init(.client_source_v1);
    try std.testing.expectError(
        error.InvalidDescriptor,
        invalid_len.writeAddressLenCapacity(1, 2, 1, 1),
    );
    var null_nonempty = Writer.init(.client_source_v1);
    try std.testing.expectError(
        error.InvalidDescriptor,
        null_nonempty.writeAddressLenCapacity(0, 0, 1, 1),
    );
    var zero_element = Writer.init(.client_source_v1);
    try std.testing.expectError(
        error.InvalidDescriptor,
        zero_element.writeAddressLenCapacity(1, 0, 1, 0),
    );
    var byte_count_overflow = Writer.init(.client_source_v1);
    try std.testing.expectError(
        error.InvalidDescriptor,
        byte_count_overflow.writeAddressLenCapacity(
            1,
            0,
            std.math.maxInt(usize),
            2,
        ),
    );
    var end_overflow = Writer.init(.client_source_v1);
    try std.testing.expectError(
        error.InvalidDescriptor,
        end_overflow.writeAddressLenCapacity(std.math.maxInt(usize), 1, 1, 1),
    );

    var a = Writer.init(.client_source_v1);
    try a.writeAddressLenCapacity(1, 0, 0, 1);
    var b = Writer.init(.client_source_v1);
    try b.writeAddressLenCapacity(std.math.maxInt(usize), 0, 0, 1);
    try std.testing.expectEqualSlices(u8, &a.finish(), &b.finish());

    var len_capacity = Writer.init(.client_source_v1);
    try len_capacity.writeAddressLenCapacity(1, 1, 2, 1);
    var capacity_len = Writer.init(.client_source_v1);
    try capacity_len.writeAddressLenCapacity(1, 2, 2, 1);
    try std.testing.expect(!std.mem.eql(
        u8,
        &len_capacity.finish(),
        &capacity_len.finish(),
    ));
}
