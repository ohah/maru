//! 히스토리 탭이 그릴 **커밋 목록**을 만드는 순수 층(docs/editor-surface-dock.md §3.6).
//!
//! 이 파일은 git을 부르지 않는다. `git log --format`이 낸 바이트를 받아 행으로 쪼갤 뿐이고, 그 형식의
//! **단일 출처가 여기**다(`format_spec`) — 명령을 만드는 쪽과 파싱하는 쪽이 같은 상수를 봐야 한쪽만
//! 고쳐지는 일이 없다.
//!
//! **왜 porcelain(`git log`의 사람용 출력)을 안 쓰는가**: 그 출력은 pager·색·`log.date`·`log.decorate`
//! 같은 저장소 설정을 타서 같은 저장소가 사용자마다 다르게 나온다. `--format`은 우리가 적은 그대로가
//! 계약이고, 필드 구분자를 **본문에 나올 수 없는 제어문자**로 두면 제목·ref에 무엇이 들어와도 갈리지 않는다.

const std = @import("std");

/// 필드 구분자(US, 0x1F)와 레코드 구분자(RS, 0x1E). git이 이 바이트를 커밋 메시지에서 그대로 실어 올
/// 수는 있지만, 우리가 쓰는 필드는 **한 줄짜리**(`%s`·`%an`·`%D`)뿐이라 실무에서 충돌하지 않는다.
/// 그래도 파서는 "필드가 모자라면 그 레코드를 버린다" 규칙으로 fail-close 한다.
pub const field_sep: u8 = 0x1F;
pub const record_sep: u8 = 0x1E;

/// `git log --format=<이것>`. 순서가 곧 아래 파싱 순서다.
///
/// - `%H` 전체 OID(자르는 것은 화면의 몫이다 — 짧은 해시는 저장소마다 길이가 다르다)
/// - `%an` 작성자 이름(committer가 아니라 author — 사용자가 "누가 썼나"로 읽는다)
/// - `%at` author 시각(UNIX 초). **상대 시각은 우리가 계산한다** — `%ar`는 git의 로케일·문구를 타고,
///   같은 화면에서 다른 상대시각 표기(파일 목록 등)와 규칙이 갈린다.
/// - `%D` ref 이름들(`HEAD -> main, origin/main, tag: v1`). `%d`와 달리 괄호·색이 없다.
/// - `%s` 제목 한 줄.
pub const format_spec = "%H\x1f%an\x1f%at\x1f%D\x1f%s\x1e";

/// 커밋 한 줄. **문자열은 입력 버퍼를 빌린다**(할당 없음) — 호출자가 그 바이트를 들고 있는 동안 유효하다.
pub const Commit = struct {
    /// 전체 OID. 화면은 앞 7자를 쓴다(`shortOid`).
    oid: []const u8,
    author: []const u8,
    /// author 시각(UNIX 초). 파싱 실패면 0이고, 그때 화면은 상대시각 자리를 비운다 —
    /// **0을 "1970년"으로 그리지 않는다**(모르는 것을 아는 척하지 않는다).
    timestamp: i64 = 0,
    /// `%D` 원문. 칩으로 쪼개는 것은 `refIterator`가 한다.
    refs: []const u8 = "",
    subject: []const u8 = "",

    /// 화면에 쓸 짧은 해시. **7자 고정**이다 — git의 `core.abbrev` 자동 길이는 저장소 크기를 타서
    /// 같은 목록 안에서도 행마다 길이가 달라질 수 있고, 열 맞춤이 흔들린다.
    pub fn shortOid(self: Commit) []const u8 {
        return if (self.oid.len >= short_oid_len) self.oid[0..short_oid_len] else self.oid;
    }
};

pub const short_oid_len: usize = 7;

/// 출력 전체를 훑는 반복자. **레코드 구분자로 끊는다** — 제목에 개행이 없더라도 ref 목록이 길어지면
/// 줄바꿈이 섞일 수 있어 줄 단위 파싱은 취약하다.
pub const Iterator = struct {
    rest: []const u8,

    pub fn next(self: *Iterator) ?Commit {
        while (true) {
            if (self.rest.len == 0) return null;
            const end = std.mem.indexOfScalar(u8, self.rest, record_sep) orelse self.rest.len;
            const record = self.rest[0..end];
            self.rest = if (end == self.rest.len) self.rest[end..] else self.rest[end + 1 ..];
            // 레코드 사이의 개행은 git이 넣는 구분자다(`--format`은 레코드마다 줄을 바꾼다).
            const trimmed = std.mem.trim(u8, record, "\r\n");
            if (trimmed.len == 0) continue;
            if (parse(trimmed)) |commit| return commit;
            // 필드가 모자라면 **그 줄만 버린다.** 통째로 멈추면 뒤에 있는 멀쩡한 커밋까지 사라진다.
        }
    }
};

pub fn iterate(text: []const u8) Iterator {
    return .{ .rest = text };
}

/// 레코드 하나를 커밋으로. 필드가 모자라면 null(그 줄을 버린다).
fn parse(record: []const u8) ?Commit {
    var it = std.mem.splitScalar(u8, record, field_sep);
    const oid = it.next() orelse return null;
    const author = it.next() orelse return null;
    const at = it.next() orelse return null;
    const decoration = it.next() orelse return null;
    // 제목은 **남은 전부**다 — 제목에 구분자가 들어와도 앞 네 필드는 이미 안전하게 떨어졌다.
    const subject = it.rest();
    if (oid.len == 0) return null; // OID 없는 줄은 커밋이 아니다
    return .{
        .oid = oid,
        .author = author,
        .timestamp = std.fmt.parseInt(i64, at, 10) catch 0,
        .refs = decoration,
        .subject = subject,
    };
}

/// ref 칩 하나. `%D`는 `HEAD -> main, origin/main, tag: v1.2` 꼴이다.
pub const Ref = struct {
    /// 화면에 그릴 이름(`main`·`origin/main`·`v1.2`).
    name: []const u8,
    kind: Kind,

    pub const Kind = enum {
        /// 지금 체크아웃된 브랜치(`HEAD -> main`의 오른쪽). 화면이 이것만 다르게 칠한다.
        head,
        /// 로컬·원격 브랜치.
        branch,
        /// `tag: ` 접두가 붙은 것.
        tag,
        /// 분리 HEAD 자신(`HEAD`).
        detached_head,
    };
};

/// `%D` 한 줄을 칩으로 쪼갠다. **할당하지 않는다**(입력을 빌린다).
pub const RefIterator = struct {
    rest: []const u8,

    pub fn next(self: *RefIterator) ?Ref {
        while (self.rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, ',') orelse self.rest.len;
            const raw = std.mem.trim(u8, self.rest[0..end], " ");
            self.rest = if (end == self.rest.len) self.rest[end..] else self.rest[end + 1 ..];
            if (raw.len == 0) continue;
            if (std.mem.startsWith(u8, raw, "tag: ")) {
                return .{ .name = raw["tag: ".len..], .kind = .tag };
            }
            // `HEAD -> main`: 체크아웃된 브랜치다. 화살표 왼쪽(`HEAD`)은 그 브랜치의 별명이라 칩을 둘 내면
            // 같은 것이 두 번 보인다.
            if (std.mem.indexOf(u8, raw, "-> ")) |arrow| {
                const name = std.mem.trim(u8, raw[arrow + "-> ".len ..], " ");
                if (name.len > 0) return .{ .name = name, .kind = .head };
                continue;
            }
            if (std.mem.eql(u8, raw, "HEAD")) return .{ .name = raw, .kind = .detached_head };
            return .{ .name = raw, .kind = .branch };
        }
        return null;
    }
};

pub fn refs(decoration: []const u8) RefIterator {
    return .{ .rest = decoration };
}

const testing = std.testing;

test "형식 그대로의 출력을 커밋 행으로 쪼갠다(실측 형식)" {
    const text = "abc123def456\x1f홍길동\x1f1755400000\x1fHEAD -> main, origin/main\x1f첫 커밋\x1e" ++
        "0102030405\x1fJane\x1f1755300000\x1f\x1ffix: 두 번째\x1e";
    var it = iterate(text);
    const first = it.next() orelse return error.MissingCommit;
    try testing.expectEqualStrings("abc123def456", first.oid);
    try testing.expectEqualStrings("abc123d", first.shortOid()); // **7자 고정**(core.abbrev를 따르지 않는다)
    try testing.expectEqualStrings("홍길동", first.author);
    try testing.expectEqual(@as(i64, 1755400000), first.timestamp);
    try testing.expectEqualStrings("첫 커밋", first.subject);

    const second = it.next() orelse return error.MissingCommit;
    try testing.expectEqualStrings("Jane", second.author);
    try testing.expectEqualStrings("", second.refs); // ref가 없는 커밋이 대부분이다
    try testing.expectEqualStrings("fix: 두 번째", second.subject);
    try testing.expect(it.next() == null);
}

test "제목에 구분자가 들어와도 앞 필드는 안 갈린다" {
    // 제목은 **남은 전부**라 그 안에 무엇이 있든 앞 네 필드의 경계는 이미 정해졌다.
    const text = "aaa\x1fBob\x1f1\x1f\x1f제목에 \x1f 가 있다\x1e";
    var it = iterate(text);
    const commit = it.next() orelse return error.MissingCommit;
    try testing.expectEqualStrings("Bob", commit.author);
    try testing.expectEqualStrings("제목에 \x1f 가 있다", commit.subject);
}

test "필드가 모자란 줄은 **그 줄만** 버린다" {
    // 통째로 멈추면 뒤에 있는 멀쩡한 커밋까지 사라진다 — 목록이 조용히 짧아지는 쪽이 더 나쁘다.
    const text = "깨진 줄\x1e" ++ "bbb\x1fAmy\x1f7\x1f\x1f정상\x1e";
    var it = iterate(text);
    const commit = it.next() orelse return error.MissingCommit;
    try testing.expectEqualStrings("bbb", commit.oid);
    try testing.expectEqualStrings("정상", commit.subject);
    try testing.expect(it.next() == null);
}

test "시각을 못 읽으면 0이다(1970년으로 그리지 않게 호출자가 구별한다)" {
    const text = "ccc\x1fAmy\x1f(없음)\x1f\x1f제목\x1e";
    var it = iterate(text);
    const commit = it.next() orelse return error.MissingCommit;
    try testing.expectEqual(@as(i64, 0), commit.timestamp);
}

test "ref 칩: 체크아웃된 브랜치·원격·태그를 가른다" {
    var it = refs("HEAD -> main, origin/main, tag: v1.2");
    const head = it.next() orelse return error.MissingRef;
    try testing.expectEqualStrings("main", head.name);
    try testing.expectEqual(Ref.Kind.head, head.kind); // `HEAD`와 `main`을 **칩 둘로 내지 않는다**
    const remote = it.next() orelse return error.MissingRef;
    try testing.expectEqualStrings("origin/main", remote.name);
    try testing.expectEqual(Ref.Kind.branch, remote.kind);
    const tag = it.next() orelse return error.MissingRef;
    try testing.expectEqualStrings("v1.2", tag.name);
    try testing.expectEqual(Ref.Kind.tag, tag.kind);
    try testing.expect(it.next() == null);
}

test "분리 HEAD는 그 사실로 칩을 낸다" {
    // `HEAD -> ` 가 아니라 `HEAD` 하나다 — 브랜치 이름이 아니므로 화면 문구가 달라야 한다.
    var it = refs("HEAD, tag: v9");
    const head = it.next() orelse return error.MissingRef;
    try testing.expectEqualStrings("HEAD", head.name);
    try testing.expectEqual(Ref.Kind.detached_head, head.kind);
    const tag = it.next() orelse return error.MissingRef;
    try testing.expectEqual(Ref.Kind.tag, tag.kind);
}

test "빈 decoration은 칩이 없다" {
    var it = refs("");
    try testing.expect(it.next() == null);
    var spaces = refs("   ");
    try testing.expect(spaces.next() == null);
}

test "unborn 저장소는 빈 출력이다(오류가 아니다)" {
    // 첫 커밋 전에는 `git log`가 실패한다 — 호출자가 그것을 "커밋 없음"으로 읽고, 파서는 빈 입력에
    // 대해 조용히 빈 목록을 준다.
    var it = iterate("");
    try testing.expect(it.next() == null);
}
