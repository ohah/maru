//! 에이전트의 파일 올리기(W9c③ `browser.upload`) 확인 모달에 보일 **파일 줄**을 만든다 — L2 순수(파일을 열지 않는다; 앱이 연 파일의
//! 실제 경로·크기·링크 수·앞부분 바이트를 받아 글로 만든다). 확인 모달이 이 업로드의 유일한 관문이라(사용자 결정 2026-10-15 — 앱이 파일을
//! 읽는다) 사용자가 읽는 글이 속지 않아야 한다(docs/plans/web-osr-backend.md 「W9c③ 결정」):
//!
//! - **보이지 않는 글자는 코드로**: 양방향 제어(RLO 로 `invoice‮fdp.exe` 가 `invoiceexe.pdf` 로 읽힌다)·폭 없는 글자·태그 글자는 `⟨U+202E⟩`
//!   처럼 보인다. 제어 문자(C0·DEL·C1)는 L2 가 요청 경로에서, 앱이 실제 경로에서 거절한다 — 여기 오면 같은 코드로 보인다(두 겹).
//! - **홈은 `~`**: 줄이 짧아져 뒤쪽 이름이 덜 밀린다. 경로는 모달이 **줄바꿈**한다(가운데를 줄이면 `.ssh` 가 사라진다 — 계획 공격 B2).
//! - **경로의 공백**: 이름 안의 공백 하나는 그대로(「My Documents」), 공백 여럿은 `⟨U+0020×N⟩`, 이름 앞뒤의 공백과 빈칸처럼 보이는 글자(NBSP·전각
//!   공백 등)는 코드로 — 모달은 공백에서 줄을 나누고 다음 줄 앞의 공백을 버리므로, 공백 덩어리 뒤에 `2. ~/Downloads/cat.jpg` 를 둔 이름이 다른
//!   파일 줄처럼 보였다(적대 리뷰 1 회차).
//! - **표지**: 이름이 `.` 으로 시작하는 폴더·파일을 지나면 「숨은 폴더·파일」, 하드 링크(이름이 둘 이상)면 그 수.
//! - **내용 엿보기**(사용자 결정 Q2): 글 파일이면 보이는 첫 줄(잘라서), 아니면 「바이너리, N 바이트(형식)」. 경로만으로는 `cp ~/.ssh/id_rsa
//!   ~/Downloads/cat.jpg` 를 알아볼 수 없다 — 첫 줄 `-----BEGIN OPENSSH PRIVATE KEY-----` 는 알아본다.
//!
//! 페이지가 정한 글(제목·입력칸 이름·accept)은 싣지 않는다 — 출처만(모달 문장은 앱이 만든다).

const std = @import("std");
const i18n = @import("../i18n.zig");
const width = @import("../width.zig");

/// 앱이 읽는 앞부분의 크기 — 글인가를 가르고 첫 줄을 찾는 데 쓴다.
pub const head_bytes = 4096;
/// 엿본 첫 줄의 표시 폭 상한(칸) — 넘으면 「…」. 모달은 줄을 나누므로 한 파일이 두세 줄을 넘지 않게.
pub const peek_cols = 48;

/// 앞부분으로 가른 내용의 모양.
pub const Kind = enum { png, jpeg, gif, webp, pdf, zip, gzip, macho, elf, sqlite, unknown };

pub const Peek = union(enum) {
    /// 비어 있다.
    empty,
    /// 글 — 보이는 첫 줄(앞부분 안에서 빈 줄을 건너뛴 첫 줄, 원문 바이트 — `head` 를 빌린다). null 이면 앞부분에 보이는 글이 없다.
    text: ?[]const u8,
    binary: Kind,
};

/// 앱이 연 파일 하나 — 모달이 보일 것(경로는 `F_GETPATH` 가 준 실제 경로).
pub const FileInfo = struct {
    path: []const u8,
    size: u64,
    nlink: u64,
    peek: Peek,
};

/// 앞부분(`head`, 최대 `head_bytes`)과 전체 크기로 내용을 가른다. NUL 이 있거나 UTF-8 이 아니거나(앞부분 끝에서 잘린 글자는 봐준다) 제어
/// 문자가 많으면 바이너리다.
pub fn classify(head: []const u8, size: u64) Peek {
    if (size == 0 or head.len == 0) return .empty;
    if (magic(head)) |k| return .{ .binary = k };
    if (std.mem.indexOfScalar(u8, head, 0) != null) return .{ .binary = .unknown };
    // 앞부분 끝에서 잘린 글자는 빼고 본다(파일이 더 길면).
    var end = head.len;
    if (size > head.len) end = validPrefix(head);
    if (!std.unicode.utf8ValidateSlice(head[0..end])) return .{ .binary = .unknown };
    var controls: usize = 0;
    for (head[0..end]) |b| if ((b < 0x20 and b != '\t' and b != '\n' and b != '\r' and b != 0x0c and b != 0x1b) or b == 0x7f) {
        controls += 1;
    };
    if (controls * 20 > end) return .{ .binary = .unknown };
    return .{ .text = firstLine(head[0..end]) };
}

/// 끝에서 잘린 UTF-8 글자를 뺀 앞부분의 길이(완성된 글자까지).
fn validPrefix(head: []const u8) usize {
    var i: usize = head.len;
    var back: usize = 0;
    while (i > 0 and back < 4) : (back += 1) {
        i -= 1;
        const b = head[i];
        if (b & 0xC0 != 0x80) {
            const need = std.unicode.utf8ByteSequenceLength(b) catch return head.len;
            return if (i + need > head.len) i else head.len;
        }
    }
    return head.len;
}

/// 빈 줄(공백뿐인 줄 포함 — 빈칸처럼 보이는 글자도)을 건너뛴 첫 줄의 보이는 글이 시작하는 곳부터 — 앞에 빈 줄이나 공백을 두어 첫 줄을
/// 감추지 못하게(적대 리뷰 1 회차 — 앞의 공백 48 칸이 엿보기를 다 채웠다). 없으면 null.
fn firstLine(text: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, text, "\r\n");
    while (it.next()) |line| {
        const start = blankPrefix(line);
        if (start < line.len) return line[start..];
    }
    return null;
}

/// 빈칸처럼 보이는(폭은 있는데 글자가 없는) 글자 — 공백·탭·VT·FF 와 NBSP·전각 공백 등. 엿보기에서는 공백으로 다루고, 경로에서는 코드로 보인다.
fn blankLike(c: u21) bool {
    return c == ' ' or c == '\t' or c == 0x0b or c == 0x0c or c == 0x00A0 or c == 0x1680 or (c >= 0x2000 and c <= 0x200A) or c == 0x202F or
        c == 0x205F or c == 0x3000;
}

/// 다음 글자(UTF-8 이 깨졌으면 null — 그 바이트는 글로 친다)와 길이.
fn decodeAt(s: []const u8, i: usize) struct { c: ?u21, len: usize } {
    const len = std.unicode.utf8ByteSequenceLength(s[i]) catch return .{ .c = null, .len = 1 };
    if (i + len > s.len) return .{ .c = null, .len = 1 };
    return .{ .c = std.unicode.utf8Decode(s[i .. i + len]) catch null, .len = len };
}

/// 앞의 빈칸처럼 보이는 글자가 차지하는 바이트 수.
fn blankPrefix(s: []const u8) usize {
    var i: usize = 0;
    while (i < s.len) {
        const d = decodeAt(s, i);
        if (d.c == null or !blankLike(d.c.?)) break;
        i += d.len;
    }
    return i;
}

fn magic(head: []const u8) ?Kind {
    const Sig = struct { at: usize, bytes: []const u8, kind: Kind };
    const sigs = [_]Sig{
        .{ .at = 0, .bytes = "\x89PNG\r\n\x1a\n", .kind = .png },
        .{ .at = 0, .bytes = "\xff\xd8\xff", .kind = .jpeg },
        .{ .at = 0, .bytes = "GIF8", .kind = .gif },
        .{ .at = 8, .bytes = "WEBP", .kind = .webp },
        .{ .at = 0, .bytes = "%PDF-", .kind = .pdf },
        .{ .at = 0, .bytes = "PK\x03\x04", .kind = .zip },
        .{ .at = 0, .bytes = "\x1f\x8b", .kind = .gzip },
        .{ .at = 0, .bytes = "\xfe\xed\xfa\xce", .kind = .macho },
        .{ .at = 0, .bytes = "\xfe\xed\xfa\xcf", .kind = .macho },
        .{ .at = 0, .bytes = "\xce\xfa\xed\xfe", .kind = .macho },
        .{ .at = 0, .bytes = "\xcf\xfa\xed\xfe", .kind = .macho },
        .{ .at = 0, .bytes = "\xca\xfe\xba\xbe", .kind = .macho },
        .{ .at = 0, .bytes = "\x7fELF", .kind = .elf },
        .{ .at = 0, .bytes = "SQLite format 3\x00", .kind = .sqlite },
    };
    for (sigs) |sig| {
        if (head.len >= sig.at + sig.bytes.len and std.mem.eql(u8, head[sig.at .. sig.at + sig.bytes.len], sig.bytes)) {
            if (sig.kind == .webp and !std.mem.startsWith(u8, head, "RIFF")) continue;
            return sig.kind;
        }
    }
    return null;
}

/// 형식 이름 — 고유 명사라 옮기지 않는다(모르면 i18n 의 「알 수 없는 형식」).
fn kindName(k: Kind) []const u8 {
    return switch (k) {
        .png => "PNG",
        .jpeg => "JPEG",
        .gif => "GIF",
        .webp => "WebP",
        .pdf => "PDF",
        .zip => "ZIP",
        .gzip => "gzip",
        .macho => "Mach-O",
        .elf => "ELF",
        .sqlite => "SQLite",
        .unknown => i18n.t(.upload_kind_unknown),
    };
}

/// 화면에서 보이지 않거나 글의 방향·모양을 바꾸는 글자 — 코드(`⟨U+XXXX⟩`)로 보인다. 제어 문자도 여기서 코드가 된다(앞에서 거절되지만
/// 두 겹으로).
pub fn invisible(c: u21) bool {
    return c < 0x20 or (c >= 0x7f and c <= 0x9f) or c == 0x00AD or c == 0x034F or c == 0x061C or c == 0x115F or c == 0x1160 or
        c == 0x17B4 or c == 0x17B5 or (c >= 0x180B and c <= 0x180F) or (c >= 0x200B and c <= 0x200F) or (c >= 0x2028 and c <= 0x202E) or
        (c >= 0x2060 and c <= 0x206F) or c == 0x3164 or (c >= 0xFE00 and c <= 0xFE0F) or c == 0xFEFF or c == 0xFFA0 or
        (c >= 0xFFF0 and c <= 0xFFFB) or (c >= 0x1D173 and c <= 0x1D17A) or (c >= 0xE0000 and c <= 0xE0FFF);
}

/// 공백을 어떻게 보이나 — 경로(`path`: 이름 안의 공백 하나만 그대로, 나머지는 코드), 엿보기(`peek`: 빈칸 덩어리를 공백 하나로).
const Spaces = enum { path, peek };

/// 글을 보이는 글자로 쓴다 — `invisible` 은 `⟨U+XXXX⟩`, 깨진 바이트는 `⟨0xNN⟩`. 쓴 칸 수(EAW)를 돌려준다. `max_cols` 를 넘으면 그 앞에서
/// 멈추고 「…」 를 붙인다(null 이면 끝까지).
fn writeVisible(w: *std.Io.Writer, s: []const u8, max_cols: ?usize, spaces: Spaces) std.Io.Writer.Error!void {
    var cols: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        // 빈칸처럼 보이는 글자 — 줄바꿈이 공백에서 끊기고 다음 줄 앞의 공백은 버려지므로 덩어리·이름 끝의 공백은 눈에 보이게(경로), 엿보기는 하나로.
        if (decodeAt(s, i).c) |c0| if ((blankLike(c0) and c0 != '\t') or (c0 == '\t' and spaces == .peek)) {
            var j = i;
            var run: usize = 0;
            var only_spaces = true;
            while (j < s.len) {
                const d = decodeAt(s, j);
                const c = d.c orelse break;
                if (!blankLike(c) or (c == '\t' and spaces == .path)) break;
                if (c != ' ') only_spaces = false;
                run += 1;
                j += d.len;
            }
            var piece_buf: [32]u8 = undefined;
            const piece: []const u8 = switch (spaces) {
                .peek => if (j >= s.len) "" else " ", // 끝의 공백은 버린다
                .path => blk: {
                    const at_edge = i == 0 or s[i - 1] == '/' or j >= s.len or s[j] == '/';
                    if (only_spaces and run == 1 and !at_edge) break :blk " ";
                    if (only_spaces and run > 1) break :blk std.fmt.bufPrint(&piece_buf, "⟨U+0020×{d}⟩", .{run}) catch unreachable;
                    // 빈칸처럼 보이는 다른 글자가 섞였거나 이름 끝의 공백 하나 — 글자마다 코드로.
                    var k = i;
                    while (k < j) {
                        const d = decodeAt(s, k);
                        var code_buf: [16]u8 = undefined;
                        const code = std.fmt.bufPrint(&code_buf, "⟨U+{X:0>4}⟩", .{d.c.?}) catch unreachable;
                        if (max_cols) |m| if (cols + 8 > m) {
                            try w.writeAll("…");
                            return;
                        };
                        try w.writeAll(code);
                        cols += 8;
                        k += d.len;
                    }
                    break :blk "";
                },
            };
            const piece_cols = std.unicode.utf8CountCodepoints(piece) catch piece.len;
            if (max_cols) |m| if (cols + piece_cols > m) {
                try w.writeAll("…");
                return;
            };
            try w.writeAll(piece);
            cols += piece_cols;
            i = j;
            continue;
        };
        // 첫 바이트가 글자의 시작이 아니면(0x80–0xBF·0xF8 이상) 깨진 바이트다 — 길이 1 로 읽으면 그 바이트가 글자로 새었다.
        const lead = std.unicode.utf8ByteSequenceLength(s[i]) catch null;
        const len: usize = lead orelse 1;
        const code: ?u21 = if (lead != null and i + len <= s.len) std.unicode.utf8Decode(s[i .. i + len]) catch null else null;
        var piece_buf: [16]u8 = undefined;
        const piece: []const u8, const step: usize, const piece_cols: usize = if (code) |c| blk: {
            if (invisible(c)) {
                const p = std.fmt.bufPrint(&piece_buf, "⟨U+{X:0>4}⟩", .{c}) catch unreachable;
                break :blk .{ p, len, 8 + @as(usize, if (c > 0xFFFF) 1 else 0) };
            }
            break :blk .{ s[i .. i + len], len, width.cellWidth(c) };
        } else blk: {
            const p = std.fmt.bufPrint(&piece_buf, "⟨0x{X:0>2}⟩", .{s[i]}) catch unreachable;
            break :blk .{ p, 1, 6 };
        };
        if (max_cols) |m| if (cols + piece_cols > m) {
            try w.writeAll("…");
            return;
        };
        try w.writeAll(piece);
        cols += piece_cols;
        i += step;
    }
}

/// 경로를 홈은 `~` 로, 보이지 않는 글자는 코드로 쓴다. `home` 이 비었거나 경로가 그 아래가 아니면 그대로.
pub fn writePath(w: *std.Io.Writer, path: []const u8, home: []const u8) std.Io.Writer.Error!void {
    var rest = path;
    if (home.len > 1 and std.mem.startsWith(u8, path, home) and path.len > home.len and path[home.len] == '/') {
        try w.writeAll("~");
        rest = path[home.len..];
    }
    try writeVisible(w, rest, null, .path);
}

/// 경로의 어느 이름이 `.` 으로 시작하는가(`.ssh`·`.env` — 숨은 폴더·파일을 지난다).
pub fn hasDotComponent(path: []const u8) bool {
    var it = std.mem.tokenizeScalar(u8, path, '/');
    while (it.next()) |part| if (part.len > 0 and part[0] == '.') return true;
    return false;
}

/// 바이트 수를 세 자리마다 쉼표로(`5,368,709,120`).
fn writeGrouped(w: *std.Io.Writer, n: u64) std.Io.Writer.Error!void {
    var digits: [24]u8 = undefined;
    const raw = std.fmt.bufPrint(&digits, "{d}", .{n}) catch unreachable;
    for (raw, 0..) |d, i| {
        if (i > 0 and (raw.len - i) % 3 == 0) try w.writeByte(',');
        try w.writeByte(d);
    }
}

/// 파일 하나의 모달 줄 둘 — `N. 경로 [표지…]` 와 `   엿보기`. 글은 `gpa` 소유(부른 쪽이 놓는다).
pub fn fileLines(gpa: std.mem.Allocator, index: usize, f: FileInfo, home: []const u8) ![2][]u8 {
    var a: std.Io.Writer.Allocating = .init(gpa);
    defer a.deinit();
    (blk: {
        a.writer.print("{d}. ", .{index + 1}) catch |e| break :blk e;
        writePath(&a.writer, f.path, home) catch |e| break :blk e;
        if (hasDotComponent(f.path)) {
            a.writer.writeAll(" ") catch |e| break :blk e;
            a.writer.writeAll(i18n.t(.upload_mark_dot)) catch |e| break :blk e;
        }
        if (f.nlink > 1) {
            var tmp: [96]u8 = undefined;
            a.writer.writeAll(" ") catch |e| break :blk e;
            a.writer.writeAll(i18n.format(&tmp, i18n.t(.upload_mark_links), &.{.{ .d = @intCast(@min(f.nlink, std.math.maxInt(i64))) }})) catch |e| break :blk e;
        }
    }) catch return error.OutOfMemory;
    const first = try a.toOwnedSlice();
    errdefer gpa.free(first);

    var size_w: std.Io.Writer.Allocating = .init(gpa);
    defer size_w.deinit();
    writeGrouped(&size_w.writer, f.size) catch return error.OutOfMemory;
    var b: std.Io.Writer.Allocating = .init(gpa);
    defer b.deinit();
    (blk: {
        b.writer.writeAll("   ") catch |e| break :blk e;
        switch (f.peek) {
            .empty => b.writer.writeAll(i18n.t(.upload_peek_empty)) catch |e| break :blk e,
            .binary => |k| {
                var tmp: [256]u8 = undefined;
                b.writer.writeAll(i18n.format(&tmp, i18n.t(.upload_peek_binary), &.{ .{ .s = size_w.written() }, .{ .s = kindName(k) } })) catch |e| break :blk e;
            },
            .text => |line| if (line) |l| {
                var shown: std.Io.Writer.Allocating = .init(gpa);
                defer shown.deinit();
                shown.writer.writeAll("“") catch |e| break :blk e;
                writeVisible(&shown.writer, l, peek_cols, .peek) catch |e| break :blk e;
                shown.writer.writeAll("”") catch |e| break :blk e;
                var tmp: [512]u8 = undefined;
                b.writer.writeAll(i18n.format(&tmp, i18n.t(.upload_peek_text), &.{ .{ .s = size_w.written() }, .{ .s = shown.written() } })) catch |e| break :blk e;
            } else {
                var tmp: [256]u8 = undefined;
                b.writer.writeAll(i18n.format(&tmp, i18n.t(.upload_peek_blank), &.{.{ .s = size_w.written() }})) catch |e| break :blk e;
            },
        }
    }) catch return error.OutOfMemory;
    return .{ first, try b.toOwnedSlice() };
}

// ── 시험 ──────────────────────────────────────────────────────────────────────────────────────────────────
// 모달 글이 사용자를 속이지 않는지 본다 — 사용자가 「이 파일, 이 사이트」 에 동의하는 유일한 자리다(계획 공격 A2·B1). 실제 경로는 앱이
// 준 것 그대로(F_GETPATH), 여기서는 글만 만든다.

const testing = std.testing;

fn lines(f: FileInfo, home: []const u8) ![2][]u8 {
    return fileLines(testing.allocator, 0, f, home);
}

fn freeLines(l: [2][]u8) void {
    testing.allocator.free(l[0]);
    testing.allocator.free(l[1]);
}

test "W9c③ 표시: 홈은 ~, 양방향·폭 없는 글자·태그는 코드로, 깨진 바이트도 코드로 — 경로는 줄이지 않는다" {
    const prev = i18n.lang();
    defer i18n.setLang(prev);
    i18n.setLang(.en);
    const l = try lines(.{ .path = "/Users/me/Downloads/invoice\u{202e}fdp.exe", .size = 3, .nlink = 1, .peek = .{ .binary = .unknown } }, "/Users/me");
    defer freeLines(l);
    try testing.expectEqualStrings("1. ~/Downloads/invoice⟨U+202E⟩fdp.exe", l[0]);
    const zw = try lines(.{ .path = "/a/b\u{200b}c\u{feff}\u{e0041}\u{2066}", .size = 3, .nlink = 1, .peek = .{ .binary = .unknown } }, "/Users/me");
    defer freeLines(zw);
    try testing.expectEqualStrings("1. /a/b⟨U+200B⟩c⟨U+FEFF⟩⟨U+E0041⟩⟨U+2066⟩", zw[0]);
    const bad = try lines(.{ .path = "/a/\xffb\nc", .size = 3, .nlink = 1, .peek = .{ .binary = .unknown } }, "");
    defer freeLines(bad);
    try testing.expectEqualStrings("1. /a/⟨0xFF⟩b⟨U+000A⟩c", bad[0]);
    // 홈과 이름 앞부분만 같은 형제(/Users/meow)는 ~ 가 아니다.
    const sib = try lines(.{ .path = "/Users/meow/x", .size = 1, .nlink = 1, .peek = .empty }, "/Users/me");
    defer freeLines(sib);
    try testing.expectEqualStrings("1. /Users/meow/x", sib[0]);
    // NFD 한글은 그대로(페이지가 받는 이름 그대로 — 실측 k7).
    const nfd = try lines(.{ .path = "/t/\u{1112}\u{1161}\u{11ab}.txt", .size = 1, .nlink = 1, .peek = .empty }, "");
    defer freeLines(nfd);
    try testing.expectEqualStrings("1. /t/\u{1112}\u{1161}\u{11ab}.txt", nfd[0]);
}

test "W9c③ 표시: 숨은 폴더·파일과 하드 링크는 표지가 붙는다 — 한국어 표에도 있다" {
    const prev = i18n.lang();
    defer i18n.setLang(prev);
    i18n.setLang(.en);
    const dot = try lines(.{ .path = "/Users/me/.ssh/id_rsa", .size = 1, .nlink = 1, .peek = .empty }, "/Users/me");
    defer freeLines(dot);
    try testing.expectEqualStrings("1. ~/.ssh/id_rsa [hidden folder or file]", dot[0]);
    const hl = try lines(.{ .path = "/Users/me/Downloads/cat.jpg", .size = 1, .nlink = 3, .peek = .empty }, "/Users/me");
    defer freeLines(hl);
    try testing.expectEqualStrings("1. ~/Downloads/cat.jpg [hard link: 3 names]", hl[0]);
    const both = try lines(.{ .path = "/x/.env", .size = 1, .nlink = 2, .peek = .empty }, "");
    defer freeLines(both);
    try testing.expectEqualStrings("1. /x/.env [hidden folder or file] [hard link: 2 names]", both[0]);
    try testing.expect(!hasDotComponent("/a/b.c/d"));
    try testing.expect(hasDotComponent("/a/.b/c"));
    i18n.setLang(.ko);
    const ko = try fileLines(testing.allocator, 2, .{ .path = "/x/.env", .size = 1, .nlink = 2, .peek = .empty }, "");
    defer freeLines(ko);
    try testing.expectEqualStrings("3. /x/.env [숨은 폴더·파일] [하드 링크: 이름 2 개]", ko[0]);
    try testing.expectEqualStrings("   빈 파일(0 바이트)", ko[1]);
}

test "W9c③ 엿보기: 글은 빈 줄을 건너뛴 첫 줄(잘라서·코드로), 바이너리는 형식과 바이트 수, 비면 빈 파일" {
    const prev = i18n.lang();
    defer i18n.setLang(prev);
    i18n.setLang(.en);
    const key = "\n\n-----BEGIN OPENSSH PRIVATE KEY-----\nb3BlbnNzaC1rZXktdjEAAAAA\n";
    const k = try lines(.{ .path = "/d/cat.jpg", .size = key.len, .nlink = 1, .peek = classify(key, key.len) }, "");
    defer freeLines(k);
    try testing.expectEqualStrings("   text, 63 bytes — first line: “-----BEGIN OPENSSH PRIVATE KEY-----”", k[1]);
    // 긴 줄은 48 칸에서 「…」, 줄 안의 ESC·RLO 는 코드로, 탭은 공백으로.
    const long = "a\x1bb\u{202e}c\td" ++ "x" ** 80;
    const lg = try lines(.{ .path = "/d/a", .size = long.len, .nlink = 1, .peek = classify(long, long.len) }, "");
    defer freeLines(lg);
    try testing.expect(std.mem.indexOf(u8, lg[1], "“a⟨U+001B⟩b⟨U+202E⟩c d") != null);
    try testing.expect(std.mem.endsWith(u8, lg[1], "…”"));
    const png = "\x89PNG\r\n\x1a\n\x00\x00";
    const p = try lines(.{ .path = "/d/a.png", .size = 5_368_709_120, .nlink = 1, .peek = classify(png, 5_368_709_120) }, "");
    defer freeLines(p);
    try testing.expectEqualStrings("   binary, 5,368,709,120 bytes (PNG)", p[1]);
    const bin = "ab\x00cd";
    const b = try lines(.{ .path = "/d/b", .size = 5, .nlink = 1, .peek = classify(bin, 5) }, "");
    defer freeLines(b);
    try testing.expectEqualStrings("   binary, 5 bytes (unknown format)", b[1]);
    const e = try lines(.{ .path = "/d/e", .size = 0, .nlink = 1, .peek = classify("", 0) }, "");
    defer freeLines(e);
    try testing.expectEqualStrings("   empty file (0 bytes)", e[1]);
    const blank = try lines(.{ .path = "/d/w", .size = 4, .nlink = 1, .peek = classify("\n \n\t", 4) }, "");
    defer freeLines(blank);
    try testing.expectEqualStrings("   text, 4 bytes — no visible text at the start", blank[1]);
}

test "W9c③ 엿보기 가르기: 앞부분 끝에서 잘린 UTF-8 글자는 봐주고(파일이 더 길 때만), 깨진 UTF-8·제어 문자가 많으면 바이너리, 매직은 먼저" {
    const ko = "가나다";
    // 앞부분이 「다」 의 중간에서 끝났다 — 파일이 더 길면 글이다.
    try testing.expect(classify(ko[0..7], 100) == .text);
    // 파일이 거기서 끝나면 깨진 글이다.
    try testing.expect(classify(ko[0..7], 7) == .binary);
    try testing.expect(classify("\xff\xfe\xfd", 3) == .binary);
    var ctl: [40]u8 = undefined;
    @memset(&ctl, 0x01);
    try testing.expect(classify(&ctl, 40) == .binary);
    try testing.expectEqual(Kind.pdf, classify("%PDF-1.7\n", 100).binary);
    try testing.expectEqual(Kind.webp, classify("RIFF\x00\x00\x00\x00WEBPVP8 ", 100).binary);
    try testing.expect(classify("xxxx\x00\x00\x00\x00WEBP", 100).binary == .unknown); // RIFF 없는 WEBP 글자
    try testing.expectEqual(Kind.sqlite, classify("SQLite format 3\x00", 100).binary);
    try testing.expectEqualStrings("hello", classify("hello\r\nworld", 12).text.?);
}

test "W9c③ 적대 리뷰 1 회차 재현 R7: 경로의 공백 여럿·이름 앞뒤 공백·빈칸처럼 보이는 글자는 코드로 — 모달이 공백 덩어리에서 줄을 나눠 「2. ~/…」 같은 가짜 줄을 만들지 못한다" {
    const prev = i18n.lang();
    defer i18n.setLang(prev);
    i18n.setLang(.en);
    const fake = try lines(.{ .path = "/Users/me/Downloads/x" ++ " " ** 40 ++ "2. ~/Downloads/cat.jpg", .size = 1, .nlink = 1, .peek = .empty }, "/Users/me");
    defer freeLines(fake);
    try testing.expectEqualStrings("1. ~/Downloads/x⟨U+0020×40⟩2. ~/Downloads/cat.jpg", fake[0]);
    try testing.expect(std.mem.indexOf(u8, fake[0], "  ") == null);
    // 이름 앞뒤의 공백 하나도 — 보이지 않는다.
    const edge = try lines(.{ .path = "/a/ b/c ", .size = 1, .nlink = 1, .peek = .empty }, "");
    defer freeLines(edge);
    try testing.expectEqualStrings("1. /a/⟨U+0020⟩b/c⟨U+0020⟩", edge[0]);
    // 이름 안의 공백 하나는 그대로(흔한 이름 — 「My Documents」).
    const plain = try lines(.{ .path = "/a/My Documents/b c.txt", .size = 1, .nlink = 1, .peek = .empty }, "");
    defer freeLines(plain);
    try testing.expectEqualStrings("1. /a/My Documents/b c.txt", plain[0]);
    // 빈칸처럼 보이는 글자(전각 공백·NBSP·좁은 공백)는 코드로.
    const wide = try lines(.{ .path = "/a/x\u{3000}\u{00a0}\u{2009}y", .size = 1, .nlink = 1, .peek = .empty }, "");
    defer freeLines(wide);
    try testing.expectEqualStrings("1. /a/x⟨U+3000⟩⟨U+00A0⟩⟨U+2009⟩y", wide[0]);
}

test "W9c③ 적대 리뷰 1 회차 재현 R8: 엿보기는 첫 줄 앞의 공백(빈칸처럼 보이는 글자 포함)을 건너뛰고 공백 덩어리를 하나로 — 48 칸을 빈칸으로 채워 내용을 숨기지 못한다" {
    const prev = i18n.lang();
    defer i18n.setLang(prev);
    i18n.setLang(.en);
    const key = " " ** 60 ++ "-----BEGIN OPENSSH PRIVATE KEY-----\n";
    const k = try lines(.{ .path = "/d/cat.jpg", .size = key.len, .nlink = 1, .peek = classify(key, key.len) }, "");
    defer freeLines(k);
    try testing.expect(std.mem.indexOf(u8, k[1], "“-----BEGIN OPENSSH PRIVATE KEY-----”") != null);
    const wide = "\u{3000}" ** 20 ++ "\t\u{00a0}-----BEGIN OPENSSH PRIVATE KEY-----\n";
    const w = try lines(.{ .path = "/d/cat.jpg", .size = wide.len, .nlink = 1, .peek = classify(wide, wide.len) }, "");
    defer freeLines(w);
    try testing.expect(std.mem.indexOf(u8, w[1], "“-----BEGIN OPENSSH PRIVATE KEY-----”") != null);
    // 줄 안의 공백 덩어리는 하나로 — 뒤의 글이 48 칸 밖으로 밀리지 않는다.
    const mid = "abc" ++ " " ** 60 ++ "SECRET\n";
    const m = try lines(.{ .path = "/d/a", .size = mid.len, .nlink = 1, .peek = classify(mid, mid.len) }, "");
    defer freeLines(m);
    try testing.expect(std.mem.indexOf(u8, m[1], "“abc SECRET”") != null);
    // 빈칸처럼 보이는 글자뿐인 줄은 빈 줄이다 — 다음 줄을 보인다, 없으면 「보이는 글이 없음」.
    const blank_wide = "\u{3000}\u{00a0}\n\u{2003}\n";
    const bw = try lines(.{ .path = "/d/b", .size = blank_wide.len, .nlink = 1, .peek = classify(blank_wide, blank_wide.len) }, "");
    defer freeLines(bw);
    try testing.expect(std.mem.indexOf(u8, bw[1], "no visible text at the start") != null);
}

// W9c③ 적대 리뷰 5 회차 변이 DSPnul: 시험의 NUL 은 매직 뒤(WEBP·SQLite)에만 있어, NUL 검사를 지운 변이가 살아남았다 — 글이 대부분인 앞부분에 NUL
// 하나가 섞이면 제어 문자 비율(1/20)로는 글로 남는다. NUL 이 있으면 글 파일이 아니다(엿보기 줄을 만들지 않는다 — 「바이너리, N 바이트」).
test "W9c③ 적대 리뷰 5 회차 변이 DSPnul: 글이 대부분이어도 앞부분에 NUL 이 하나 있으면 바이너리다" {
    const head = "Quarterly report: all numbers are final and approved\x00 by the board of directors.\n";
    try testing.expect(classify(head, 1000) == .binary);
    try testing.expect(classify(head, 1000).binary == .unknown);
}
