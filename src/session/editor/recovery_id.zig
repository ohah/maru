//! 복구 문서의 영속 신원. 난수 발급과 파일 소유권은 플랫폼 책임이며 이 값이 쓰기 권한은 아니다.
const std = @import("std");

pub const Id = struct {
    bytes: [16]u8,

    pub fn fromBytes(bytes: [16]u8) error{InvalidId}!Id {
        const id: Id = .{ .bytes = bytes };
        if (!id.valid()) return error.InvalidId;
        return id;
    }

    pub fn valid(self: Id) bool {
        return !std.mem.allEqual(u8, &self.bytes, 0);
    }

    /// 같은 값에 여러 파일 이름이 생기지 않도록 길이·소문자 hex를 한 곳에서 고정한다.
    pub fn parse(text: []const u8) error{InvalidId}!Id {
        if (text.len != 32) return error.InvalidId;
        var bytes: [16]u8 = undefined;
        for (&bytes, 0..) |*byte, i| {
            byte.* = (try nibble(text[i * 2])) * 16 + try nibble(text[i * 2 + 1]);
        }
        return fromBytes(bytes);
    }

    pub fn hex(self: Id) [32]u8 {
        const digits = "0123456789abcdef";
        var out: [32]u8 = undefined;
        for (self.bytes, 0..) |byte, i| {
            out[i * 2] = digits[byte >> 4];
            out[i * 2 + 1] = digits[byte & 15];
        }
        return out;
    }

    pub fn eql(self: Id, other: Id) bool {
        return std.mem.eql(u8, &self.bytes, &other.bytes);
    }
};

fn nibble(byte: u8) error{InvalidId}!u8 {
    return switch (byte) {
        '0'...'9' => byte - '0',
        'a'...'f' => byte - 'a' + 10,
        else => error.InvalidId,
    };
}

pub const file_name_len = 2 + 32 + 4;

pub fn fileName(id: Id) error{InvalidId}![file_name_len]u8 {
    if (!id.valid()) return error.InvalidId;
    return "d-".* ++ id.hex() ++ ".bak".*;
}

/// 디렉터리 성분이나 별칭을 허용하지 않는다. 읽기·삭제 caller가 같은 규칙을 사용한다.
pub fn fromFileName(name: []const u8) error{InvalidId}!Id {
    if (name.len != file_name_len or !std.mem.startsWith(u8, name, "d-") or
        !std.mem.endsWith(u8, name, ".bak")) return error.InvalidId;
    return Id.parse(name[2..34]);
}

test "RECID canonical bytes and file names preserve the full identity" {
    const text = "000102030405060708090a0b0c0d0eff";
    const id = try Id.parse(text);
    try std.testing.expectEqualStrings(text, &id.hex());
    const name = try fileName(id);
    try std.testing.expectEqualStrings("d-" ++ text ++ ".bak", &name);
    try std.testing.expect(id.eql(try fromFileName(&name)));
    var other = id;
    other.bytes[15] ^= 1;
    try std.testing.expect(!id.eql(other));
    try std.testing.expect(!std.mem.eql(u8, &name, &(try fileName(other))));
}

test "RECID malformed or zero identity never aliases a valid record" {
    for ([_][]const u8{
        "",                                 "1",                                 "00000000000000000000000000000000",
        "000102030405060708090a0b0c0d0eFF", "000102030405060708090a0b0c0d0efg",  "+00102030405060708090a0b0c0d0eff",
        " 00102030405060708090a0b0c0d0eff", "000102030405060708090a0b0c0d0eff0",
    }) |bad| try std.testing.expectError(error.InvalidId, Id.parse(bad));
    const good = "d-000102030405060708090a0b0c0d0eff.bak";
    for ([_][]const u8{ "../" ++ good, "/" ++ good, good ++ ".tmp", "p-000102030405060708090a0b0c0d0eff.bak" }) |bad|
        try std.testing.expectError(error.InvalidId, fromFileName(bad));
    try std.testing.expectError(error.InvalidId, fileName(.{ .bytes = @splat(0) }));
}
