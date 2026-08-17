//! SSH 와이어 자료형(RFC 4251 §5) — `string`·`name-list`·`mpint` 읽기/쓰기.
//!
//! **네트워크에서 온 바이트를 다룬다.** 여기 있는 모든 읽기는 **경계를 먼저 본다** — 길이
//! 필드를 믿고 슬라이스를 자르면 악의적 서버가 우리를 죽인다(패킷 계층이 상한으로 막는 것과
//! 같은 규율, 계약 §3.3).
//!
//! **`string` 은 NUL 로 끝나지 않는다.** 길이 접두 바이트열이고 **임의 바이트**를 담는다 —
//! 텍스트로 가정하고 자르면 키·서명 같은 이진 값이 깨진다.

const std = @import("std");

pub const Error = error{
    /// 남은 바이트가 선언된 길이보다 짧다.
    Truncated,
    /// 길이가 이 연결에서 받아들일 수 있는 한도를 넘었다.
    TooLarge,
    /// `mpint` 가 최소 길이 규칙(RFC 4251 §5)을 어겼다.
    MalformedMpint,
};

/// 한 필드의 상한. 패킷 상한(256KiB)보다 작아야 의미가 있다 — 필드 하나가 패킷을 다 먹는
/// 경우는 정상 트래픽에 없다.
pub const max_field = 128 * 1024;

/// 바이트를 앞에서부터 읽는다. **모든 읽기가 경계를 본다.**
pub const Reader = struct {
    buf: []const u8,
    pos: usize = 0,

    pub fn init(buf: []const u8) Reader {
        return .{ .buf = buf };
    }

    pub fn rest(self: Reader) []const u8 {
        return self.buf[self.pos..];
    }

    pub fn byte(self: *Reader) Error!u8 {
        if (self.pos + 1 > self.buf.len) return Error.Truncated;
        defer self.pos += 1;
        return self.buf[self.pos];
    }

    pub fn boolean(self: *Reader) Error!bool {
        return (try self.byte()) != 0;
    }

    pub fn u32be(self: *Reader) Error!u32 {
        if (self.pos + 4 > self.buf.len) return Error.Truncated;
        defer self.pos += 4;
        return std.mem.readInt(u32, self.buf[self.pos..][0..4], .big);
    }

    /// 길이 접두 바이트열. **원본을 가리킨다**(복사하지 않는다).
    pub fn string(self: *Reader) Error![]const u8 {
        const n = try self.u32be();
        if (n > max_field) return Error.TooLarge;
        if (self.pos + n > self.buf.len) return Error.Truncated;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }

    /// 고정 길이 바이트열(길이 접두가 없다 — 예: KEXINIT 의 16바이트 cookie).
    pub fn fixed(self: *Reader, n: usize) Error![]const u8 {
        if (self.pos + n > self.buf.len) return Error.Truncated;
        defer self.pos += n;
        return self.buf[self.pos..][0..n];
    }

    /// 쉼표로 나뉜 이름 목록(RFC 4251 §5). **빈 목록은 길이 0 이다** — 쉼표 하나가 아니다.
    pub fn nameList(self: *Reader) Error!NameList {
        return .{ .raw = try self.string() };
    }
};

/// 이름 목록. **쪼개서 담지 않는다** — 원본을 들고 훑기만 한다(할당이 없다).
pub const NameList = struct {
    raw: []const u8,

    pub fn iterator(self: NameList) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, self.raw, ',');
    }

    /// 이 목록에 그 이름이 있나. **부분 일치가 아니다** — `"ssh-ed25519"` 를 찾을 때
    /// `"ssh-ed25519-cert-v01@openssh.com"` 이 걸리면 안 된다.
    pub fn has(self: NameList, name: []const u8) bool {
        if (self.raw.len == 0) return false;
        var it = self.iterator();
        while (it.next()) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }

    /// **우리가 선호하는 순서로** 고른다(RFC 4253 §7.1 은 클라이언트 선호를 따른다).
    /// 서버 목록에 없는 것은 건너뛴다. 하나도 없으면 null.
    pub fn pick(self: NameList, preferred: []const []const u8) ?[]const u8 {
        for (preferred) |p| if (self.has(p)) return p;
        return null;
    }
};

/// 바이트를 뒤에 붙여 나간다. 버퍼가 모자라면 오류다(넘겨 쓰지 않는다).
pub const Writer = struct {
    buf: []u8,
    pos: usize = 0,

    pub const WriteError = error{NoSpace};

    pub fn init(buf: []u8) Writer {
        return .{ .buf = buf };
    }

    pub fn written(self: Writer) []const u8 {
        return self.buf[0..self.pos];
    }

    pub fn byte(self: *Writer, v: u8) WriteError!void {
        if (self.pos + 1 > self.buf.len) return WriteError.NoSpace;
        self.buf[self.pos] = v;
        self.pos += 1;
    }

    pub fn boolean(self: *Writer, v: bool) WriteError!void {
        return self.byte(if (v) 1 else 0);
    }

    pub fn u32be(self: *Writer, v: u32) WriteError!void {
        if (self.pos + 4 > self.buf.len) return WriteError.NoSpace;
        std.mem.writeInt(u32, self.buf[self.pos..][0..4], v, .big);
        self.pos += 4;
    }

    pub fn raw(self: *Writer, bytes: []const u8) WriteError!void {
        if (self.pos + bytes.len > self.buf.len) return WriteError.NoSpace;
        @memcpy(self.buf[self.pos..][0..bytes.len], bytes);
        self.pos += bytes.len;
    }

    pub fn string(self: *Writer, bytes: []const u8) WriteError!void {
        try self.u32be(@intCast(bytes.len));
        try self.raw(bytes);
    }

    /// 이름 목록을 쉼표로 이어 쓴다.
    pub fn nameList(self: *Writer, names: []const []const u8) WriteError!void {
        var n: usize = 0;
        for (names, 0..) |name, i| n += name.len + @intFromBool(i > 0);
        try self.u32be(@intCast(n));
        for (names, 0..) |name, i| {
            if (i > 0) try self.byte(',');
            try self.raw(name);
        }
    }

    /// 다중 정밀 정수(RFC 4251 §5). **부호 있는 2의 보수, big-endian, 최소 길이**다:
    /// 0 은 **빈 문자열**이고, 최상위 비트가 서면 앞에 0 바이트를 하나 붙인다(안 붙이면 음수로
    /// 읽힌다). 이 규칙을 어기면 교환 해시가 서버와 안 맞아 **KEX 가 조용히 실패**한다.
    pub fn mpint(self: *Writer, bytes: []const u8) WriteError!void {
        var i: usize = 0;
        while (i < bytes.len and bytes[i] == 0) i += 1; // 앞의 0 을 버린다
        const v = bytes[i..];
        if (v.len == 0) return self.u32be(0); // 0 은 빈 문자열
        const need_pad = v[0] & 0x80 != 0;
        try self.u32be(@intCast(v.len + @intFromBool(need_pad)));
        if (need_pad) try self.byte(0);
        try self.raw(v);
    }
};

/// `mpint` 를 읽는다. **최소 길이 규칙을 검사한다** — 어긴 값을 받아 주면 같은 수에 두 가지
/// 표현이 생기고, 교환 해시가 그 차이를 그대로 드러낸다.
pub fn readMpint(r: *Reader) Error![]const u8 {
    const v = try r.string();
    if (v.len == 0) return v; // 0
    if (v[0] == 0 and v.len > 1 and v[1] & 0x80 == 0) return Error.MalformedMpint; // 쓸데없는 0
    if (v[0] & 0x80 != 0) return Error.MalformedMpint; // 음수는 우리 쓰임에 없다
    return v;
}

// ── 테스트 ──────────────────────────────────────────────────────────────────

test "string 은 길이 접두이고 이진을 담는다" {
    var out: [64]u8 = undefined;
    var w = Writer.init(&out);
    try w.string(&[_]u8{ 0, 1, 0xFF, 0 }); // NUL 이 섞여도 그대로
    var r = Reader.init(w.written());
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 1, 0xFF, 0 }, try r.string());
}

test "이름 목록은 쉼표로 잇고 빈 목록은 길이 0 이다" {
    var out: [64]u8 = undefined;
    var w = Writer.init(&out);
    try w.nameList(&.{ "a", "bb", "ccc" });
    var r = Reader.init(w.written());
    const list = try r.nameList();
    try std.testing.expectEqualStrings("a,bb,ccc", list.raw);

    var w2 = Writer.init(&out);
    try w2.nameList(&.{});
    var r2 = Reader.init(w2.written());
    const empty = try r2.nameList();
    try std.testing.expectEqual(@as(usize, 0), empty.raw.len);
    try std.testing.expect(!empty.has("a"));
}

test "이름 찾기는 부분 일치가 아니다" {
    // `ssh-ed25519` 를 찾는데 인증서 계열이 걸리면 **다른 알고리즘으로 검증하게 된다**.
    const list = NameList{ .raw = "ssh-ed25519-cert-v01@openssh.com,rsa-sha2-256" };
    try std.testing.expect(!list.has("ssh-ed25519"));
    try std.testing.expect(list.has("rsa-sha2-256"));
}

test "고르기는 우리 선호 순서를 따른다" {
    // 서버가 어떤 순서로 적었든 **클라이언트 선호**가 이긴다(RFC 4253 §7.1).
    const list = NameList{ .raw = "aes128-ctr,chacha20-poly1305@openssh.com" };
    try std.testing.expectEqualStrings(
        "chacha20-poly1305@openssh.com",
        list.pick(&.{ "chacha20-poly1305@openssh.com", "aes128-ctr" }).?,
    );
    try std.testing.expectEqual(@as(?[]const u8, null), list.pick(&.{"none"}));
}

test "mpint 은 0 을 빈 문자열로, 최상위 비트에 0 을 덧댄다" {
    var out: [64]u8 = undefined;

    var w0 = Writer.init(&out);
    try w0.mpint(&[_]u8{ 0, 0 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 0 }, w0.written());

    // 0x80 으로 시작하면 앞에 0 을 붙인다 — 안 붙이면 음수로 읽힌다.
    var w1 = Writer.init(&out);
    try w1.mpint(&[_]u8{ 0x80, 0x01 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 3, 0, 0x80, 0x01 }, w1.written());

    // 0x7F 로 시작하면 안 붙인다.
    var w2 = Writer.init(&out);
    try w2.mpint(&[_]u8{ 0x7F, 0x01 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 2, 0x7F, 0x01 }, w2.written());

    // 앞의 0 은 버린다(최소 길이).
    var w3 = Writer.init(&out);
    try w3.mpint(&[_]u8{ 0, 0, 0x09 });
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0, 0, 1, 0x09 }, w3.written());
}

test "mpint 읽기는 최소 길이를 어긴 값을 거절한다" {
    // 같은 수에 두 표현이 생기면 교환 해시가 그 차이를 드러낸다.
    var bad = [_]u8{ 0, 0, 0, 2, 0, 0x01 }; // 쓸데없는 0
    var r = Reader.init(&bad);
    try std.testing.expectError(Error.MalformedMpint, readMpint(&r));

    var neg = [_]u8{ 0, 0, 0, 1, 0x80 }; // 음수
    var r2 = Reader.init(&neg);
    try std.testing.expectError(Error.MalformedMpint, readMpint(&r2));

    var ok = [_]u8{ 0, 0, 0, 2, 0, 0x80 }; // 0x80 앞의 0 은 정당하다
    var r3 = Reader.init(&ok);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 0x80 }, try readMpint(&r3));
}

test "읽기는 언제나 경계를 본다" {
    // **네트워크에서 온 바이트다** — 길이를 믿고 자르면 죽는다.
    var truncated = [_]u8{ 0, 0, 0, 8, 1, 2 }; // 8 바이트라고 하고 2 만 왔다
    var r = Reader.init(&truncated);
    try std.testing.expectError(Error.Truncated, r.string());

    var huge = [_]u8{ 0xFF, 0xFF, 0xFF, 0xFF };
    var r2 = Reader.init(&huge);
    try std.testing.expectError(Error.TooLarge, r2.string());

    var empty: [0]u8 = undefined;
    var r3 = Reader.init(&empty);
    try std.testing.expectError(Error.Truncated, r3.byte());
    try std.testing.expectError(Error.Truncated, r3.u32be());
}

test "쓰기는 버퍼를 넘지 않는다" {
    var small: [4]u8 = undefined;
    var w = Writer.init(&small);
    try std.testing.expectError(Writer.WriteError.NoSpace, w.string("hello"));
}
