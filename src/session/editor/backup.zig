//! 미저장 편집의 **백업 레코드**(L2) — 계약은
//! [문서 모델](../../../docs/native-editor-document-model.md) §3.10 이 소유한다.
//!
//! **왜 L2 인가.** 「무엇을 적어 두면 되살릴 수 있나」는 정책이고 화면도 OS 도 모른다. 파일을 여는
//! 일은 L4 가 하고(`app_session/editor_backup.zig`), 이 모듈은 **레코드의 모양과 이름·주기 정책**만
//! 안다 — 그래야 화면 없이 검사할 수 있고 이식할 때 따라간다.
//!
//! **포맷은 저장소 관례를 그대로 쓴다**: 첫 줄 bare 헤더 토큰(`schema=` 접두 없음), 그다음 한 줄
//! `key=value`(따옴표 값은 `text_escape` 단일 출처), 빈 줄 하나, 그 뒤가 **원문 바이트 그대로**다
//! (`maru.workspace.v1`·`maru.trace.v1` 와 같은 규칙 — 새 escape 규칙을 만들지 않는다).
//! 본문을 escape 하지 않는 이유: 문서는 8 MiB 까지 오고 escape 하면 사본이 한 벌 더 생긴다.

const std = @import("std");
const file_panel_bridge = @import("../file_panel_bridge.zig");
const writeEscaped = @import("../../text_escape.zig").writeEscaped;
const unescapeAlloc = @import("../../text_escape.zig").unescapeAlloc;

pub const header = "maru.editor-backup.v1";

/// 편집이 멎은 뒤 이만큼 지나면 쓴다(§3.10 「편집 후 debounce」). **workspace checkpoint 의
/// 500 ms 보다 길다** — 그쪽은 탭 배치라 한 줄이고 이쪽은 문서 전체 사본이다.
pub const debounce_ns: u64 = 2 * std.time.ns_per_s;

/// 이보다 큰 문서는 **백업하지 않는다**(§3.10 「임계를 넘으면 중단하고 상태바로 알린다」).
/// **새 숫자를 만들지 않았다** — 저장 상한(`file_panel_bridge.max_file_bytes`)이 곧 「되쓸 수 있는
/// 크기」라, 그보다 큰 문서의 편집은 백업이 있어도 원본에 쓸 수 없다(`error.TooLarge`).
pub const pause_bytes: usize = file_panel_bridge.max_file_bytes;

/// 읽을 때 받아 줄 레코드 최대 길이. 본문 상한 + 머리말 여유. 손상·변조 파일이 메모리를 불리지
/// 못하게 **읽는 쪽이** 먼저 가둔다.
pub const max_record_bytes: usize = pause_bytes + 64 * 1024;

pub const Kind = enum { path, untitled, remote };

/// 백업이 가리키는 문서의 **신원**. 세 갈래인 이유는 편집기에 문서가 세 종류이기 때문이다 —
/// 경로가 있는 문서 · 이름 없는 문서(§3.11) · 저쪽에 저장한 문서(§3.11 의 원격 신원).
pub const Doc = union(Kind) {
    path: Path,
    /// 이름 없는 문서의 **번호**(`untitled-N` 의 N). 복원이 이 번호를 되살리고 발급기를 그 위로
    /// 올린다(`untitled.Counter.observe`) — 안 올리면 새 문서가 같은 이름이 된다.
    untitled: u32,
    remote: Remote,

    pub const Path = struct {
        path: []const u8,
        /// **마지막으로 본 디스크 내용의 지문**(`app_session/editor.zig` 의 `contentHash` — Wyhash-64).
        /// 이것이 레코드에 실려야 복원이 「그 사이 남이 고쳤나」를 물을 수 있다. 메모리에만 있는
        /// `Opened.disk_hash` 를 그대로 싣는 것이고, 새 축을 만들지 않는다(§3.10).
        disk_hash: ?u64 = null,
    };

    pub const Remote = struct {
        dest: []const u8,
        path: []const u8,
    };
};

/// 파일 이름 최대 길이 — 가장 긴 갈래는 `p-` + hex 16 + `.bak`.
pub const max_file_name_len: usize = 2 + 16 + 4;

fn keyHash(parts: []const []const u8) u64 {
    var h = std.hash.Wyhash.init(0);
    for (parts, 0..) |p, i| {
        if (i != 0) h.update(&.{0}); // 경계를 섞지 않는다 — ("ab","c") 와 ("a","bc") 는 다른 문서다
        h.update(p);
    }
    return h.final();
}

/// 이 문서의 백업 파일 이름. **한 문서에 하나**다(§3.10) — 같은 신원이면 같은 이름으로 덮어쓴다.
///
/// 이름이 해시인 이유: 경로가 그대로 파일 이름이 될 수 없다(`/`·길이). 해시 충돌은 레코드에 실린
/// 신원을 **읽는 쪽이 다시 확인**하므로 잘못된 문서를 되살리지 않는다.
pub fn fileName(buf: *[max_file_name_len]u8, doc: Doc) []const u8 {
    return switch (doc) {
        .path => |p| std.fmt.bufPrint(buf, "p-{x:0>16}.bak", .{keyHash(&.{p.path})}) catch unreachable,
        .untitled => |n| std.fmt.bufPrint(buf, "u-{x}.bak", .{n}) catch unreachable,
        .remote => |r| std.fmt.bufPrint(buf, "r-{x:0>16}.bak", .{keyHash(&.{ r.dest, r.path })}) catch unreachable,
    };
}

/// 레코드를 한 벌로 만든다(호출자 소유). 본문은 **그대로** 실린다.
pub fn encode(allocator: std.mem.Allocator, doc: Doc, content: []const u8) std.mem.Allocator.Error![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    const w = &out.writer;
    write(w, doc, content) catch return error.OutOfMemory; // allocating writer — 유일한 실패는 OOM
    return out.toOwnedSlice();
}

fn write(w: *std.Io.Writer, doc: Doc, content: []const u8) !void {
    try w.writeAll(header);
    try w.writeAll("\ndoc kind=");
    try w.writeAll(@tagName(doc));
    try w.print(" bytes={d}", .{content.len});
    switch (doc) {
        .path => |p| {
            if (p.disk_hash) |h| try w.print(" disk-hash={x:0>16}", .{h});
            try w.writeAll(" path=\"");
            try writeEscaped(w, p.path);
            try w.writeAll("\"");
        },
        .untitled => |n| try w.print(" number={d}", .{n}),
        .remote => |r| {
            try w.writeAll(" dest=\"");
            try writeEscaped(w, r.dest);
            try w.writeAll("\" path=\"");
            try writeEscaped(w, r.path);
            try w.writeAll("\"");
        },
    }
    try w.writeAll("\n\n");
    try w.writeAll(content);
}

pub const ParseError = error{ BadHeader, BadRecord, TooLarge, OutOfMemory };

/// 읽어 낸 레코드. 문자열은 **이 구조가 소유**하고(escape 를 풀어야 하므로), 본문은 입력 안을
/// 가리킨다(사본을 만들지 않는다 — 8 MiB 가 한 벌 더 생기지 않게).
pub const Parsed = struct {
    doc: Doc,
    content: []const u8,

    pub fn deinit(self: *Parsed, allocator: std.mem.Allocator) void {
        switch (self.doc) {
            .path => |p| allocator.free(p.path),
            .untitled => {},
            .remote => |r| {
                allocator.free(r.dest);
                allocator.free(r.path);
            },
        }
        self.* = undefined;
    }
};

pub fn parse(allocator: std.mem.Allocator, bytes: []const u8) ParseError!Parsed {
    if (bytes.len > max_record_bytes) return error.TooLarge;
    var rest = bytes;
    const first_nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.BadHeader;
    if (!std.mem.eql(u8, rest[0..first_nl], header)) return error.BadHeader;
    rest = rest[first_nl + 1 ..];
    const second_nl = std.mem.indexOfScalar(u8, rest, '\n') orelse return error.BadRecord;
    const line = rest[0..second_nl];
    rest = rest[second_nl + 1 ..];
    // 빈 줄 하나가 머리말과 본문을 가른다 — 없으면 손상이다(본문 시작을 추측하지 않는다).
    if (rest.len == 0 or rest[0] != '\n') return error.BadRecord;
    const body = rest[1..];

    if (!std.mem.startsWith(u8, line, "doc ")) return error.BadRecord;
    var fields = Fields{ .rest = line["doc ".len..] };
    var kind: ?Kind = null;
    var declared_bytes: ?usize = null;
    var disk_hash: ?u64 = null;
    var number: ?u32 = null;
    var path_raw: ?[]const u8 = null;
    var dest_raw: ?[]const u8 = null;
    while (try fields.next()) |f| {
        if (std.mem.eql(u8, f.key, "kind")) {
            kind = std.meta.stringToEnum(Kind, f.value) orelse return error.BadRecord;
        } else if (std.mem.eql(u8, f.key, "bytes")) {
            declared_bytes = std.fmt.parseInt(usize, f.value, 10) catch return error.BadRecord;
        } else if (std.mem.eql(u8, f.key, "disk-hash")) {
            disk_hash = std.fmt.parseInt(u64, f.value, 16) catch return error.BadRecord;
        } else if (std.mem.eql(u8, f.key, "number")) {
            number = std.fmt.parseInt(u32, f.value, 10) catch return error.BadRecord;
        } else if (std.mem.eql(u8, f.key, "path")) {
            path_raw = f.value;
        } else if (std.mem.eql(u8, f.key, "dest")) {
            dest_raw = f.value;
        }
        // 모르는 키는 **버린다**(옛 판이 새 키를 만나도 열린다 — workspace 리더와 같은 관대함).
    }
    // **길이가 맞아야 받는다.** 잘린 파일(쓰는 중에 죽었다)을 통째로 되살리면 문서가 조용히
    // 잘린다 — 그것이 백업이 막으려던 손실이다.
    const declared = declared_bytes orelse return error.BadRecord;
    if (declared != body.len) return error.BadRecord;

    return switch (kind orelse return error.BadRecord) {
        .path => blk: {
            const raw = path_raw orelse return error.BadRecord;
            const path = try unescapeAlloc(allocator, raw);
            errdefer allocator.free(path);
            if (path.len == 0) return error.BadRecord;
            break :blk .{ .doc = .{ .path = .{ .path = path, .disk_hash = disk_hash } }, .content = body };
        },
        .untitled => .{ .doc = .{ .untitled = number orelse return error.BadRecord }, .content = body },
        .remote => blk: {
            const draw = dest_raw orelse return error.BadRecord;
            const praw = path_raw orelse return error.BadRecord;
            const dest = try unescapeAlloc(allocator, draw);
            errdefer allocator.free(dest);
            const path = try unescapeAlloc(allocator, praw);
            errdefer allocator.free(path);
            if (dest.len == 0 or path.len == 0) return error.BadRecord;
            break :blk .{ .doc = .{ .remote = .{ .dest = dest, .path = path } }, .content = body };
        },
    };
}

/// `key=value` 와 `key="escaped value"` 를 훑는다. **따옴표 안의 공백은 경계가 아니다** —
/// 경로에 공백이 있으면 그 규칙이 없으면 값이 끊긴다.
const Fields = struct {
    rest: []const u8,

    const Field = struct { key: []const u8, value: []const u8 };

    fn next(self: *Fields) ParseError!?Field {
        while (self.rest.len != 0 and self.rest[0] == ' ') self.rest = self.rest[1..];
        if (self.rest.len == 0) return null;
        const eq = std.mem.indexOfScalar(u8, self.rest, '=') orelse return error.BadRecord;
        const key = self.rest[0..eq];
        if (key.len == 0) return error.BadRecord;
        var value_start = eq + 1;
        if (value_start < self.rest.len and self.rest[value_start] == '"') {
            value_start += 1;
            var i = value_start;
            while (i < self.rest.len) : (i += 1) {
                if (self.rest[i] == '\\') {
                    i += 1; // escape 된 문자는 닫는 따옴표로 보지 않는다
                    continue;
                }
                if (self.rest[i] == '"') break;
            }
            if (i >= self.rest.len) return error.BadRecord; // 안 닫힌 따옴표
            const value = self.rest[value_start..i];
            self.rest = self.rest[@min(i + 1, self.rest.len)..];
            return .{ .key = key, .value = value };
        }
        const end = std.mem.indexOfScalarPos(u8, self.rest, value_start, ' ') orelse self.rest.len;
        const value = self.rest[value_start..end];
        self.rest = self.rest[end..];
        return .{ .key = key, .value = value };
    }
};

const testing = std.testing;

/// 되읽어 같은 것이 나오는지 한 자리에서 본다 — 갈래마다 검사를 복제하면 한쪽만 고쳐진다.
///
/// **레코드 버퍼를 함께 들고 있어야 한다** — `Parsed.content` 는 입력 안을 가리키므로(사본을 만들지
/// 않는다) 버퍼를 먼저 놓으면 본문이 해제된 메모리다. 초안의 헬퍼가 바로 그렇게 해서 세그폴트가
/// 났다(2026-09-22 실측) — 그 함정은 이 타입으로 한 번만 짓고 검사마다 되풀이하지 않는다.
const RoundTrip = struct {
    bytes: []u8,
    parsed: Parsed,

    fn deinit(self: *RoundTrip) void {
        self.parsed.deinit(testing.allocator);
        testing.allocator.free(self.bytes);
    }
};

fn roundTrip(doc: Doc, content: []const u8) !RoundTrip {
    const bytes = try encode(testing.allocator, doc, content);
    errdefer testing.allocator.free(bytes);
    return .{ .bytes = bytes, .parsed = try parse(testing.allocator, bytes) };
}

test "UB1 세 갈래가 왕복한다 — 신원과 본문이 그대로다" {
    {
        var rt = try roundTrip(.{ .path = .{ .path = "/tmp/a b\"c.zig", .disk_hash = 0xdead_beef_0123_4567 } }, "hello\n");
        defer rt.deinit();
        const got = rt.parsed;
        try testing.expectEqualStrings("/tmp/a b\"c.zig", got.doc.path.path);
        try testing.expectEqual(@as(?u64, 0xdead_beef_0123_4567), got.doc.path.disk_hash);
        try testing.expectEqualStrings("hello\n", got.content);
    }
    {
        // 이름 없는 문서는 디스크를 본 적이 없다 — 지문 칸이 **아예 없다**(없는 비교를 만들지 않는다).
        var rt = try roundTrip(.{ .untitled = 7 }, "draft");
        defer rt.deinit();
        const got = rt.parsed;
        try testing.expectEqual(@as(u32, 7), got.doc.untitled);
        try testing.expectEqualStrings("draft", got.content);
    }
    {
        var rt = try roundTrip(.{ .remote = .{ .dest = "me@host", .path = "/srv/x.md" } }, "");
        defer rt.deinit();
        const got = rt.parsed;
        try testing.expectEqualStrings("me@host", got.doc.remote.dest);
        try testing.expectEqualStrings("/srv/x.md", got.doc.remote.path);
        try testing.expectEqualStrings("", got.content);
    }
}

test "UB2 본문은 escape 하지 않으므로 개행·따옴표·NUL 이 그대로 온다" {
    const content = "a\nb\"c\\d\x00e\r\n";
    var rt = try roundTrip(.{ .untitled = 1 }, content);
    defer rt.deinit();
    try testing.expectEqualStrings(content, rt.parsed.content);
}

test "UB3 선언한 길이와 본문 길이가 다르면 거절한다 — 쓰는 중에 죽은 파일을 통째로 되살리지 않는다" {
    const bytes = try encode(testing.allocator, .{ .untitled = 2 }, "0123456789");
    defer testing.allocator.free(bytes);
    // 마지막 바이트가 끊긴 파일(쓰다가 죽었다).
    try testing.expectError(error.BadRecord, parse(testing.allocator, bytes[0 .. bytes.len - 1]));
    // 본문이 더 길어도 거절이다(머리말만 믿고 뒤를 무시하면 남은 바이트가 조용히 사라진다).
    const longer = try std.mem.concat(testing.allocator, u8, &.{ bytes, "x" });
    defer testing.allocator.free(longer);
    try testing.expectError(error.BadRecord, parse(testing.allocator, longer));
}

test "UB4 헤더가 다르면 읽지 않는다" {
    try testing.expectError(error.BadHeader, parse(testing.allocator, "maru.editor-backup.v2\ndoc kind=untitled bytes=0 number=1\n\n"));
    try testing.expectError(error.BadHeader, parse(testing.allocator, "not a backup"));
}

test "UB5 모르는 키는 버리고 나머지를 읽는다" {
    var got = try parse(testing.allocator, header ++ "\ndoc kind=untitled bytes=2 number=3 future=xyz\n\nhi");
    defer got.deinit(testing.allocator);
    try testing.expectEqual(@as(u32, 3), got.doc.untitled);
    try testing.expectEqualStrings("hi", got.content);
}

test "UB6 이름은 신원마다 하나 — 같은 신원은 같고, 경계는 섞이지 않는다" {
    var a: [max_file_name_len]u8 = undefined;
    var b: [max_file_name_len]u8 = undefined;
    try testing.expectEqualStrings(
        fileName(&a, .{ .path = .{ .path = "/x/y" } }),
        fileName(&b, .{ .path = .{ .path = "/x/y", .disk_hash = 9 } }), // 지문은 신원이 아니다
    );
    try testing.expect(!std.mem.eql(u8, fileName(&a, .{ .path = .{ .path = "/x/y" } }), fileName(&b, .{ .path = .{ .path = "/x/z" } })));
    // ("ab","c") 와 ("a","bc") 는 다른 문서다 — 이어 붙이기만 하면 같은 이름이 된다.
    try testing.expect(!std.mem.eql(
        u8,
        fileName(&a, .{ .remote = .{ .dest = "ab", .path = "c" } }),
        fileName(&b, .{ .remote = .{ .dest = "a", .path = "bc" } }),
    ));
    // 갈래가 다르면 이름도 다르다(같은 디렉터리에 함께 산다).
    try testing.expect(fileName(&a, .{ .untitled = 1 })[0] == 'u');
    try testing.expect(fileName(&a, .{ .path = .{ .path = "/1" } })[0] == 'p');
    try testing.expect(fileName(&a, .{ .remote = .{ .dest = "h", .path = "/1" } })[0] == 'r');
}

test "UB7 따옴표 안의 공백은 값의 경계가 아니다" {
    var rt = try roundTrip(.{ .path = .{ .path = "/a b/c d.txt" } }, "x");
    defer rt.deinit();
    try testing.expectEqualStrings("/a b/c d.txt", rt.parsed.doc.path.path);
}

test "UB8 중단 임계는 저장 상한과 같은 값이다 — 새 숫자를 만들지 않았다" {
    try testing.expectEqual(file_panel_bridge.max_file_bytes, pause_bytes);
    try testing.expect(max_record_bytes > pause_bytes);
}

test "UB9 상한을 넘는 레코드는 읽지 않는다" {
    const big = try testing.allocator.alloc(u8, max_record_bytes + 1);
    defer testing.allocator.free(big);
    @memset(big, 'a');
    try testing.expectError(error.TooLarge, parse(testing.allocator, big));
}

test "UB10 적대적 머리말 — 안 닫힌 따옴표·`=` 없는 토큰·빈 줄 없음은 거절한다" {
    try testing.expectError(error.BadRecord, parse(testing.allocator, header ++ "\ndoc kind=path bytes=0 path=\"/x\n\n"));
    try testing.expectError(error.BadRecord, parse(testing.allocator, header ++ "\ndoc kind=path bytes=0 garbage\n\n"));
    try testing.expectError(error.BadRecord, parse(testing.allocator, header ++ "\ndoc kind=untitled bytes=0 number=1\nbody"));
    try testing.expectError(error.BadRecord, parse(testing.allocator, header ++ "\nwindow kind=untitled bytes=0 number=1\n\n"));
    // 갈래가 요구하는 칸이 없으면 거절이다(추측하지 않는다).
    try testing.expectError(error.BadRecord, parse(testing.allocator, header ++ "\ndoc kind=untitled bytes=0\n\n"));
    try testing.expectError(error.BadRecord, parse(testing.allocator, header ++ "\ndoc kind=path bytes=0\n\n"));
    try testing.expectError(error.BadRecord, parse(testing.allocator, header ++ "\ndoc kind=remote bytes=0 path=\"/x\"\n\n"));
    // 빈 경로는 신원이 아니다.
    try testing.expectError(error.BadRecord, parse(testing.allocator, header ++ "\ndoc kind=path bytes=0 path=\"\"\n\n"));
}
