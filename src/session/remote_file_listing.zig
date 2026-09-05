//! **원격 디렉터리 목록 wire**(RF1 — [계획](../../docs/plans/remote-file-tree.md) §2.2·§3).
//!
//! 원격 헬퍼(`maru-remote-watch` 를 넓힌 것, RF2)가 **내고**, GUI 의 파일 트리 백엔드가 **읽는**
//! 한 벌의 코덱이다. 양끝이 이 모듈 하나를 쓰게 두 방향 API(append·Parser)를 같이 둔다 — 반대편을
//! 손으로 미러하면 RW 가 `version_line` 문자열 대조로 겨우 막고 있는 그 드리프트가 여기서도 생긴다.
//!
//! **왜 셸 출력을 파싱하지 않고 wire 를 새로 정하나** — 실측(계획 §3.2, 2026-09-06)으로 확인했다:
//! 파일 이름에는 공백·작은따옴표·**개행**이 들어올 수 있고, `ls -lai` 도 `find -exec stat` 도 개행
//! 이름을 두 줄로 쪼개 **파싱이 원리적으로 불가능**하다. 그래서 이름을 **길이 접두**로 싣는다 —
//! 경계를 내용이 아니라 수가 정하므로 어떤 바이트가 와도 안 깨진다.
//!
//! ## wire v1 (줄 지향 + 길이 접두 이름)
//!
//! ```text
//! maru-rfls 1\n                    머리 — 판이 다르면 즉시 거부(구 GUI ↔ 신 헬퍼의 조용한 오독 방지)
//! D <dev> <ino>\n                  나열한 디렉터리 **자신**의 신원(root pin 이 쓴다)
//! E <dev> <ino> <k> <len> <이름>\n  항목 — 이름은 len 바이트 그대로(개행 포함 가능), 그 뒤 개행 하나
//! ! <len> <메시지>\n                원격 오류(opendir 실패 등). 이것으로 끝난 목록도 **완결**이다
//! X <count>\n                      꼬리 — 없으면 **잘린 것**이다(전송이 중간에 끊겨도 침묵하지 않게)
//! ```
//!
//! 신원 숫자는 10 진 u64 다. **뜻을 부여하지 않는다** — POSIX 는 `(dev, ino)` 를 싣겠지만 계약은
//! 「같은 기계 안에서 같으면 같다」뿐이다(계획 §2.3 ⑴ — 로컬조차 Windows 는 `FileId` 를 쓴다).
//!
//! `k` 는 [file_tree.Kind](file_tree.zig) 와 1:1 이다: `d`=directory · `f`=file ·
//! `s`=symlink_file(가리키는 곳이 디렉터리가 아니거나 끊김) · `S`=symlink_directory · `o`=other.
//!
//! **여기는 순수 계층이다** — 바이트를 만들고 해석할 뿐, 실행도 전송도 하지 않는다(RW2a 와 같은 규율).

const std = @import("std");
const file_tree = @import("file_tree.zig");
const agent_hook_mode = @import("agent_hook_mode.zig");

pub const wire_version: u32 = 1;
pub const header_line = "maru-rfls 1";

/// 이름 한 개의 상한(바이트). NAME_MAX 는 보통 255 바이트지만 APFS(UTF-8 255 **자**)는 최대
/// 1020 바이트까지 온다 — 넉넉히 덮되 유계로 둔다. 넘는 이름은 **안 싣는다**(잘라 싣으면 그 이름은
/// 존재하지 않는 항목이 된다 — `CwdLabel` 이 경로에 대해 정한 것과 같은 규율).
pub const max_name_bytes: usize = 1024;

/// 원격 오류 메시지 상한. 표시용 한 줄이면 충분하고, 원격이 주는 값이므로 유계여야 한다.
pub const max_error_bytes: usize = 512;

/// 항목 수 상한. 이 위는 「목록」이 아니라 「덤프」다 — 소비처(트리)는 어차피 이만큼을 그리지 못하고,
/// 원격이 악의적으로 수를 불려도 파서가 여기서 멈춘다.
pub const max_entries: usize = 100_000;

/// 원격 기계 이름(ssh 목적지)의 상한 — [`CwdLabel.max_host`](agent_hook_mode.zig) 가 SSOT 다.
/// 같은 값을 손으로 적으면 RS6 이 잡은 그 드리프트(상한 두 벌)가 여기서 재발한다.
pub const max_host_bytes: usize = agent_hook_mode.CwdLabel.max_host;

/// wire 의 종류 글자 ↔ 트리 모델의 [Kind](file_tree.zig). 여기서만 오간다 — 소비처가 글자를 직접
/// 보면 새 종류가 생길 때 한쪽만 고쳐진다.
pub fn kindToLetter(kind: file_tree.Kind) u8 {
    return switch (kind) {
        .directory => 'd',
        .file => 'f',
        .symlink_file => 's',
        .symlink_directory => 'S',
        .other => 'o',
    };
}

pub fn kindFromLetter(letter: u8) ?file_tree.Kind {
    return switch (letter) {
        'd' => .directory,
        'f' => .file,
        's' => .symlink_file,
        'S' => .symlink_directory,
        'o' => .other,
        else => null,
    };
}

pub const DirIdentity = struct { dev: u64, ino: u64 };

pub const Entry = struct {
    dev: u64,
    ino: u64,
    kind: file_tree.Kind,
    /// 입력 버퍼를 **빌려** 가리킨다 — 파서에 준 바이트가 살아 있는 동안만 유효하다.
    name: []const u8,
};

// ── 인코더 — 헬퍼(원격)와 테스트가 쓴다 ─────────────────────────────────────────────────────────
//
// `remote_shell.quoteAppend` 와 같은 버퍼-append 꼴이다: 할당이 없어 헬퍼 바이너리(작아야 한다 —
// ReleaseSmall)가 그대로 쓸 수 있고, 넘치면 null 로 실패해 **잘린 레코드를 절대 만들지 않는다**.

fn appendBytes(out: []u8, at: usize, bytes: []const u8) ?usize {
    if (at > out.len or out.len - at < bytes.len) return null;
    @memcpy(out[at..][0..bytes.len], bytes);
    return at + bytes.len;
}

fn appendDecimal(out: []u8, at: usize, value: u64) ?usize {
    var buf: [20]u8 = undefined; // u64 최대 20 자리
    const s = std.fmt.bufPrint(&buf, "{d}", .{value}) catch unreachable;
    return appendBytes(out, at, s);
}

pub fn appendHeader(out: []u8, at: usize) ?usize {
    var n = appendBytes(out, at, header_line) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

pub fn appendDirIdentity(out: []u8, at: usize, identity: DirIdentity) ?usize {
    var n = appendBytes(out, at, "D ") orelse return null;
    n = appendDecimal(out, n, identity.dev) orelse return null;
    n = appendBytes(out, n, " ") orelse return null;
    n = appendDecimal(out, n, identity.ino) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

/// 이름이 상한을 넘거나 비면 null — **안 싣는다.** 호출자(헬퍼)는 그 항목을 건너뛰고 개수에서 뺀다.
pub fn appendEntry(out: []u8, at: usize, entry: Entry) ?usize {
    if (entry.name.len == 0 or entry.name.len > max_name_bytes) return null;
    var n = appendBytes(out, at, "E ") orelse return null;
    n = appendDecimal(out, n, entry.dev) orelse return null;
    n = appendBytes(out, n, " ") orelse return null;
    n = appendDecimal(out, n, entry.ino) orelse return null;
    n = appendBytes(out, n, " ") orelse return null;
    n = appendBytes(out, n, &.{kindToLetter(entry.kind)}) orelse return null;
    n = appendBytes(out, n, " ") orelse return null;
    n = appendDecimal(out, n, entry.name.len) orelse return null;
    n = appendBytes(out, n, " ") orelse return null;
    n = appendBytes(out, n, entry.name) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

pub fn appendRemoteError(out: []u8, at: usize, message: []const u8) ?usize {
    // ⚠️ 자름은 바이트 경계다 — errno 문자열(ASCII)을 전제한다(적대적 검증 2 회차). UTF-8 메시지를
    // 싣게 되면 글자 경계로 물려야 한다(truncateToBoundary 선례) — 그때 이 줄이 그 자리다.
    const clamped = message[0..@min(message.len, max_error_bytes)];
    var n = appendBytes(out, at, "! ") orelse return null;
    n = appendDecimal(out, n, clamped.len) orelse return null;
    n = appendBytes(out, n, " ") orelse return null;
    n = appendBytes(out, n, clamped) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

pub fn appendFooter(out: []u8, at: usize, count: u64) ?usize {
    var n = appendBytes(out, at, "X ") orelse return null;
    n = appendDecimal(out, n, count) orelse return null;
    n = appendBytes(out, n, "\n") orelse return null;
    return n;
}

// ── 파서 — GUI 백엔드가 쓴다 ────────────────────────────────────────────────────────────────────

pub const ParseError = error{
    /// 머리가 없거나 판이 다르다 — 구 GUI ↔ 신 헬퍼(또는 그 반대)의 조용한 오독을 여기서 끊는다.
    UnsupportedVersion,
    /// 레코드 형태가 계약과 다르다.
    Malformed,
    /// 이름 길이가 상한을 넘는다고 주장한다 — 원격이 주는 값이므로 믿지 않는다.
    NameTooLong,
    /// 항목 수가 상한을 넘는다.
    TooManyEntries,
    /// 꼬리의 count 가 실제 항목 수와 다르다 — 중간 유실을 잡는다.
    CountMismatch,
    /// 이름이 항목일 수 없다 — `/`·NUL 이 들었거나 `.`·`..` 다. 정상 readdir 은 이런 이름을 **낼 수
    /// 없으므로**, 왔다는 것 자체가 저쪽이 오염됐다는 뜻이다(적대적 검증 1 회차 — 이 wire 는 신뢰
    /// 경계를 건너오고, 소비처는 root 와 이름을 이어 경로를 만든다. 여기서 안 거르면 `..` 이름 하나가
    /// **root 밖**을 가리킨다).
    UnsafeName,
    /// 꼬리(또는 오류 레코드) 뒤에 바이트가 더 있다 — 응답 두 개가 섞였다는 뜻이다.
    TrailingData,
};

pub const Event = union(enum) {
    dir: DirIdentity,
    entry: Entry,
    /// 원격이 보고한 실패(표시용 텍스트). 이것으로 끝난 목록도 **완결된 답**이다(§2.5 — 「못 읽는다」
    /// 는 「비었다」와 다르고, 그 사실이 화면까지 가야 한다).
    remote_error: []const u8,
};

/// 스트리밍이 아니라 **완결된 바이트**를 받는 파서다 — 전송(L4)이 상한까지 읽어 통째로 준다.
/// `next()` 를 끝까지 돌린 뒤 `complete()` 가 참일 때만 결과를 믿는다: 꼬리를 못 봤으면 **잘린
/// 것**이고, 잘린 목록을 그대로 그리면 「지워진 것처럼 보이는」 항목이 생긴다.
pub const Parser = struct {
    rest: []const u8,
    saw_header: bool = false,
    saw_dir: bool = false,
    entries_seen: u64 = 0,
    /// 꼬리(`X`) 또는 오류(`!`)를 봤다 — 이 뒤에 오는 바이트는 전부 `TrailingData` 다.
    terminated: bool = false,

    pub fn init(bytes: []const u8) Parser {
        return .{ .rest = bytes };
    }

    /// 완결됐는가. `!`(원격 실패)도 완결이다 — 침묵과 실패를 가르는 것이 이 wire 의 존재 이유다.
    pub fn complete(self: *const Parser) bool {
        return self.terminated and self.rest.len == 0;
    }

    pub fn next(self: *Parser) ParseError!?Event {
        if (self.rest.len == 0) return null;
        if (self.terminated) return ParseError.TrailingData;

        if (!self.saw_header) {
            const line = self.takeLine() orelse return ParseError.UnsupportedVersion;
            // 버전 불일치와 「우리 wire 가 아님」을 같은 오류로 낸다 — 소비처의 처방이 같다(재협상이
            // 아니라 거부. RS 원격이 hello 판 불일치에 하는 그것이다).
            if (!std.mem.eql(u8, line, header_line)) return ParseError.UnsupportedVersion;
            self.saw_header = true;
            return self.next();
        }

        const tag = self.rest[0];
        switch (tag) {
            'D' => {
                const line = self.takeLine() orelse return ParseError.Malformed;
                if (self.saw_dir) return ParseError.Malformed; // 디렉터리 신원은 하나뿐이다
                var it = std.mem.splitScalar(u8, line, ' ');
                if (!std.mem.eql(u8, it.next() orelse return ParseError.Malformed, "D")) return ParseError.Malformed;
                const dev = parseU64(it.next()) orelse return ParseError.Malformed;
                const ino = parseU64(it.next()) orelse return ParseError.Malformed;
                if (it.next() != null) return ParseError.Malformed;
                self.saw_dir = true;
                return .{ .dir = .{ .dev = dev, .ino = ino } };
            },
            'E' => {
                // 머리 부분(`E dev ino k len `)만 줄로 읽을 수 없다 — **이름에 개행이 들어올 수 있어서**
                // 길이를 먼저 읽고 그만큼을 바이트로 뗀다. 이 순서가 이 wire 의 요점이다.
                if (!self.saw_dir) return ParseError.Malformed;
                var head = self.rest[1..];
                if (head.len == 0 or head[0] != ' ') return ParseError.Malformed;
                head = head[1..];
                const dev = self.takeDecimalFrom(&head) orelse return ParseError.Malformed;
                const ino = self.takeDecimalFrom(&head) orelse return ParseError.Malformed;
                if (head.len < 2 or head[1] != ' ') return ParseError.Malformed;
                const kind = kindFromLetter(head[0]) orelse return ParseError.Malformed;
                head = head[2..];
                const len = self.takeDecimalFrom(&head) orelse return ParseError.Malformed;
                if (len == 0 or len > max_name_bytes) return ParseError.NameTooLong;
                if (head.len < len + 1) return ParseError.Malformed; // 이름 + 뒤따르는 개행
                const name = head[0..@intCast(len)];
                if (head[@intCast(len)] != '\n') return ParseError.Malformed;
                if (!nameIsSafe(name)) return ParseError.UnsafeName;
                self.rest = head[@intCast(len + 1)..];
                self.entries_seen += 1;
                if (self.entries_seen > max_entries) return ParseError.TooManyEntries;
                return .{ .entry = .{ .dev = dev, .ino = ino, .kind = kind, .name = name } };
            },
            '!' => {
                var head = self.rest[1..];
                if (head.len == 0 or head[0] != ' ') return ParseError.Malformed;
                head = head[1..];
                const len = self.takeDecimalFrom(&head) orelse return ParseError.Malformed;
                if (len > max_error_bytes) return ParseError.Malformed;
                if (head.len < len + 1) return ParseError.Malformed;
                const msg = head[0..@intCast(len)];
                if (head[@intCast(len)] != '\n') return ParseError.Malformed;
                self.rest = head[@intCast(len + 1)..];
                self.terminated = true;
                return .{ .remote_error = msg };
            },
            'X' => {
                const line = self.takeLine() orelse return ParseError.Malformed;
                var it = std.mem.splitScalar(u8, line, ' ');
                if (!std.mem.eql(u8, it.next() orelse return ParseError.Malformed, "X")) return ParseError.Malformed;
                const count = parseU64(it.next()) orelse return ParseError.Malformed;
                if (it.next() != null) return ParseError.Malformed;
                // 신원(`D`) 없는 완결은 없다(적대적 검증 1 회차) — 빈 목록도 root pin 은 신원이 필요하고,
                // 신원을 생략한 헬퍼를 완결로 받으면 그 생략이 영영 안 드러난다.
                if (!self.saw_dir) return ParseError.Malformed;
                if (count != self.entries_seen) return ParseError.CountMismatch;
                self.terminated = true;
                return self.next(); // 꼬리는 이벤트가 아니다 — 남은 바이트가 있으면 TrailingData 로 드러난다
            },
            else => return ParseError.Malformed,
        }
    }

    fn takeLine(self: *Parser) ?[]const u8 {
        const nl = std.mem.indexOfScalar(u8, self.rest, '\n') orelse return null;
        const line = self.rest[0..nl];
        self.rest = self.rest[nl + 1 ..];
        return line;
    }

    /// `head` 앞의 10 진수 하나를 읽고 **뒤따르는 공백 하나**까지 소비한다.
    fn takeDecimalFrom(self: *Parser, head: *[]const u8) ?u64 {
        _ = self;
        var i: usize = 0;
        while (i < head.len and head.*[i] >= '0' and head.*[i] <= '9') i += 1;
        if (i == 0 or i > 20) return null;
        const value = std.fmt.parseInt(u64, head.*[0..i], 10) catch return null;
        if (i >= head.len or head.*[i] != ' ') return null;
        head.* = head.*[i + 1 ..];
        return value;
    }

    fn nameIsSafe(name: []const u8) bool {
        if (std.mem.eql(u8, name, ".") or std.mem.eql(u8, name, "..")) return false;
        for (name) |c| if (c == '/' or c == 0) return false;
        return true;
    }

    fn parseU64(maybe: ?[]const u8) ?u64 {
        const s = maybe orelse return null;
        if (s.len == 0 or s.len > 20) return null;
        for (s) |c| if (c < '0' or c > '9') return null;
        return std.fmt.parseInt(u64, s, 10) catch null;
    }
};

// ── `(host, path)` root 키 — 트리 root 의 신원(계획 §2.1) ──────────────────────────────────────

/// 트리 root 가 **어느 기계의 어느 경로**인가. 로컬은 `host = ""` 다.
///
/// 경로만으로는 키가 아니다 — 같은 철자가 두 기계에서 다른 폴더다(remote-scm §2.1·RS6 이 저장소와
/// 훅 cwd 에 세운 그 규칙). 이 타입이 RF3 에서 root 저장·영속(`dock-tree-roots`)의 단위가 된다.
pub const RootKey = struct {
    host: []const u8,
    path: []const u8,

    pub fn isRemote(self: RootKey) bool {
        return self.host.len > 0;
    }

    pub fn eql(self: RootKey, other: RootKey) bool {
        return std.mem.eql(u8, self.host, other.host) and std.mem.eql(u8, self.path, other.path);
    }
};

/// 원격 root 로 **받아들일 수 있는가.** 로컬 root 의 검증(realpath·capability)은 기존 파이프라인
/// 몫이고, 여기는 원격 축만 본다:
///
/// - 경로는 **절대**여야 한다 — 상대경로는 원격 로그인 셸의 cwd(홈)에 걸려 다른 폴더가 된다
///   (`git_command.buildRemoteFileRead` 가 같은 이유로 절대만 받는다).
/// - **제어문자를 거부**한다(경로·host 둘 다). 인용으로도 안전하지만, 그런 값이 왔다는 것 자체가
///   관측이 오염됐다는 뜻이다(remote-scm 계약 §2.2 ⑵ 와 같은 규율).
/// - host 는 비면 안 되고(`""` 는 로컬의 표기다) 상한(`max_host_bytes`) 안이어야 한다.
pub fn remoteRootIsValid(key: RootKey) bool {
    if (key.host.len == 0 or key.host.len > max_host_bytes) return false;
    if (key.path.len == 0 or key.path.len > std.fs.max_path_bytes) return false;
    if (key.path[0] != '/') return false;
    // 꼬리 `/` 를 거부한다(적대적 검증 3 회차) — `/srv/app` 과 `/srv/app/` 이 서로 다른 키가 되면
    // 같은 폴더가 트리에 두 root 로 선다. 정규화는 RF3 의 원격 realpath 몫이고, 여기서는 같은 값의
    // 두 철자를 **안 받는** 것까지만 한다. root `/` 하나는 예외다.
    if (key.path.len > 1 and key.path[key.path.len - 1] == '/') return false;
    for (key.path) |c| if (c < 0x20 or c == 0x7f) return false;
    for (key.host) |c| if (c <= 0x20 or c == 0x7f) return false; // 공백도 목적지에는 없다
    return true;
}

// ── 판정자 ──────────────────────────────────────────────────────────────────────────────────────

const testing = std.testing;

test "왕복: 함정 이름(공백·개행·따옴표·한글)이 그대로 돌아온다" {
    // 이 wire 의 존재 이유다 — 실측(계획 §3.2)에서 `ls`/`find` 는 개행 이름에서 원리적으로 깨졌다.
    var buf: [4096]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendDirIdentity(&buf, n, .{ .dev = 7, .ino = 42 }).?;
    const names = [_][]const u8{ "has space.txt", "nl\nname.txt", "quote'name.txt", "한글 이름.md" };
    const kinds = [_]file_tree.Kind{ .file, .file, .symlink_file, .directory };
    for (names, kinds, 0..) |name, kind, i| {
        n = appendEntry(&buf, n, .{ .dev = 7, .ino = 100 + i, .kind = kind, .name = name }).?;
    }
    n = appendFooter(&buf, n, names.len).?;

    var p = Parser.init(buf[0..n]);
    const dir = (try p.next()).?;
    try testing.expectEqual(@as(u64, 7), dir.dir.dev);
    try testing.expectEqual(@as(u64, 42), dir.dir.ino);
    for (names, kinds, 0..) |name, kind, i| {
        const ev = (try p.next()).?;
        try testing.expectEqualStrings(name, ev.entry.name);
        try testing.expectEqual(kind, ev.entry.kind);
        try testing.expectEqual(@as(u64, 100 + i), ev.entry.ino);
    }
    try testing.expectEqual(@as(?Event, null), try p.next());
    try testing.expect(p.complete());
}

test "꼬리가 없으면 완결이 아니다 — 잘린 목록을 그대로 그리면 항목이 «지워진 것처럼» 보인다" {
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendDirIdentity(&buf, n, .{ .dev = 1, .ino = 2 }).?;
    n = appendEntry(&buf, n, .{ .dev = 1, .ino = 3, .kind = .file, .name = "a" }).?;
    // 꼬리를 일부러 뺀다(전송이 상한에서 끊긴 모양).
    var p = Parser.init(buf[0..n]);
    _ = (try p.next()).?;
    _ = (try p.next()).?;
    try testing.expectEqual(@as(?Event, null), try p.next());
    try testing.expect(!p.complete());

    // 이름 **한가운데**서 끊겨도 오류이지 조용한 절단이 아니다.
    var p2 = Parser.init(buf[0 .. n - 1]);
    _ = (try p2.next()).?;
    try testing.expectError(ParseError.Malformed, p2.next());
}

test "판이 다르면 즉시 거부한다 — 구 GUI 와 신 헬퍼의 조용한 오독을 끊는다" {
    var p = Parser.init("maru-rfls 2\nX 0\n");
    try testing.expectError(ParseError.UnsupportedVersion, p.next());
    var p2 = Parser.init("change\n"); // RW 의 감시 스트림이 섞여 들어온 모양
    try testing.expectError(ParseError.UnsupportedVersion, p2.next());
}

test "꼬리의 count 가 실제와 다르면 CountMismatch — 중간 유실을 잡는다" {
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendDirIdentity(&buf, n, .{ .dev = 1, .ino = 2 }).?;
    n = appendEntry(&buf, n, .{ .dev = 1, .ino = 3, .kind = .file, .name = "a" }).?;
    n = appendFooter(&buf, n, 2).?; // 실제로는 1 개
    var p = Parser.init(buf[0..n]);
    _ = (try p.next()).?;
    _ = (try p.next()).?;
    try testing.expectError(ParseError.CountMismatch, p.next());
}

test "원격 오류도 완결된 답이다 — 침묵과 실패를 가른다 (§2.5)" {
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendRemoteError(&buf, n, "opendir: Permission denied").?;
    var p = Parser.init(buf[0..n]);
    const ev = (try p.next()).?;
    try testing.expectEqualStrings("opendir: Permission denied", ev.remote_error);
    try testing.expectEqual(@as(?Event, null), try p.next());
    try testing.expect(p.complete());
}

test "꼬리 뒤의 바이트는 TrailingData — 응답 두 개가 섞이면 두 번째를 첫 번째로 읽지 않는다" {
    var buf: [1024]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendDirIdentity(&buf, n, .{ .dev = 1, .ino = 2 }).?;
    n = appendFooter(&buf, n, 0).?;
    n = appendBytes(&buf, n, "E 1 9 f 1 b\n").?;
    var p = Parser.init(buf[0..n]);
    _ = (try p.next()).?;
    try testing.expectError(ParseError.TrailingData, p.next());
    try testing.expect(!p.complete());
}

test "이름 상한: 경계는 담고 넘치면 양끝 다 거부한다" {
    var name_buf: [max_name_bytes + 1]u8 = undefined;
    @memset(&name_buf, 'x');
    var buf: [8192]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendDirIdentity(&buf, n, .{ .dev = 1, .ino = 2 }).?;
    // 정확히 상한 — 담긴다.
    n = appendEntry(&buf, n, .{ .dev = 1, .ino = 3, .kind = .file, .name = name_buf[0..max_name_bytes] }).?;
    // 상한 + 1 — 인코더가 거부한다(잘라 싣지 않는다).
    try testing.expectEqual(@as(?usize, null), appendEntry(&buf, n, .{ .dev = 1, .ino = 4, .kind = .file, .name = &name_buf }));
    n = appendFooter(&buf, n, 1).?;
    var p = Parser.init(buf[0..n]);
    _ = (try p.next()).?;
    const ev = (try p.next()).?;
    try testing.expectEqual(max_name_bytes, ev.entry.name.len);
    try testing.expectEqual(@as(?Event, null), try p.next());
    try testing.expect(p.complete());

    // 파서 쪽: 원격이 상한 넘는 길이를 **주장**하면 믿지 않는다.
    var p2 = Parser.init("maru-rfls 1\nD 1 2\nE 1 3 f 2000 x\n");
    _ = (try p2.next()).?;
    try testing.expectError(ParseError.NameTooLong, p2.next());
}

test "쓰레기 입력은 오류이지 크래시가 아니다" {
    const cases = [_][]const u8{
        "maru-rfls 1\nD 1 2\nE -1 3 f 1 a\n", // 음수
        "maru-rfls 1\nD 1 2\nE 1 3 z 1 a\n", // 모르는 종류
        "maru-rfls 1\nD 1 2\nD 3 4\n", // 디렉터리 신원 두 번
        "maru-rfls 1\nE 1 3 f 1 a\n", // 신원 없이 항목부터
        "maru-rfls 1\nD 1 2\nQ\n", // 모르는 태그
        "maru-rfls 1\nD 1 2 9\n", // 필드 수 초과
        "maru-rfls 1\nD 99999999999999999999999 2\n", // u64 초과 자리수
    };
    for (cases) |bytes| {
        var p = Parser.init(bytes);
        var failed = false;
        while (p.next() catch |err| blk: {
            try testing.expect(err != ParseError.UnsupportedVersion); // 머리는 전부 정상인 케이스들이다
            failed = true;
            break :blk null;
        }) |_| {}
        try testing.expect(failed);
    }
}

test "경로 탈출 이름은 UnsafeName — wire 는 신뢰 경계를 건너온다" {
    // 정상 readdir 은 `/`·NUL·`.`·`..` 를 이름으로 **낼 수 없다.** 왔다는 것 자체가 저쪽이 오염됐다는
    // 뜻이고, 소비처는 root 와 이름을 이어 경로를 만드므로 여기서 안 거르면 `..` 하나가 root 밖을
    // 가리킨다(§9.4 「경로는 두 기계 사이에서 키가 아니다」의 트리판).
    const bad_names = [_][]const u8{ "..", ".", "a/b", "..\x2fetc", "nul\x00name" };
    for (bad_names) |bad| {
        var buf: [1024]u8 = undefined;
        var n = appendHeader(&buf, 0).?;
        n = appendDirIdentity(&buf, n, .{ .dev = 1, .ino = 2 }).?;
        // 인코더 검증을 우회해 원격 오염을 흉내 낸다 — 레코드를 손으로 만든다.
        n = appendBytes(&buf, n, "E 1 3 f ").?;
        n = appendDecimal(&buf, n, bad.len).?;
        n = appendBytes(&buf, n, " ").?;
        n = appendBytes(&buf, n, bad).?;
        n = appendBytes(&buf, n, "\n").?;
        var p = Parser.init(buf[0..n]);
        _ = (try p.next()).?;
        try testing.expectError(ParseError.UnsafeName, p.next());
    }
}

test "신원 없는 완결은 없다 — 빈 목록도 D 가 있어야 꼬리를 받는다" {
    var p = Parser.init("maru-rfls 1\nX 0\n");
    try testing.expectError(ParseError.Malformed, p.next());

    var buf: [256]u8 = undefined;
    var n = appendHeader(&buf, 0).?;
    n = appendDirIdentity(&buf, n, .{ .dev = 1, .ino = 2 }).?;
    n = appendFooter(&buf, n, 0).?;
    var p2 = Parser.init(buf[0..n]);
    _ = (try p2.next()).?; // D
    try testing.expectEqual(@as(?Event, null), try p2.next());
    try testing.expect(p2.complete()); // 빈 목록 자체는 완결이다
}

test "RootKey: 경로는 두 기계 사이에서 키가 아니다" {
    const local: RootKey = .{ .host = "", .path = "/srv/app" };
    const remote: RootKey = .{ .host = "me@box", .path = "/srv/app" };
    const other: RootKey = .{ .host = "me@other", .path = "/srv/app" };
    try testing.expect(!local.isRemote());
    try testing.expect(remote.isRemote());
    try testing.expect(!remote.eql(local)); // 같은 철자, 다른 기계
    try testing.expect(!remote.eql(other));
    try testing.expect(remote.eql(.{ .host = "me@box", .path = "/srv/app" }));
}

test "remoteRootIsValid: 절대경로만, 제어문자 없이, host 는 비지 않게" {
    try testing.expect(remoteRootIsValid(.{ .host = "me@box", .path = "/srv/app proj" })); // 공백 경로는 정당하다
    try testing.expect(!remoteRootIsValid(.{ .host = "", .path = "/srv/app" })); // "" 는 로컬의 표기다
    try testing.expect(!remoteRootIsValid(.{ .host = "me@box", .path = "relative" }));
    try testing.expect(!remoteRootIsValid(.{ .host = "me@box", .path = "/a\nb" })); // 제어문자
    try testing.expect(!remoteRootIsValid(.{ .host = "me box", .path = "/a" })); // host 의 공백
    try testing.expect(!remoteRootIsValid(.{ .host = "me@box", .path = "/srv/app/" })); // 꼬리 / — 같은 폴더 두 키
    try testing.expect(remoteRootIsValid(.{ .host = "me@box", .path = "/" })); // root 하나는 예외다
    var long_host: [max_host_bytes + 1]u8 = undefined;
    @memset(&long_host, 'h');
    try testing.expect(!remoteRootIsValid(.{ .host = &long_host, .path = "/a" }));
}
