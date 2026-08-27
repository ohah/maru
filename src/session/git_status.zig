//! `git status --porcelain=v2 --branch`와 `git diff --numstat` 출력의 **순수 파서**(L2, I/O 없음).
//!
//! 도크 소스 컨트롤 뷰(docs/editor-surface-dock.md §3.5)가 그리는 섹션과 행의 데이터가 전부 여기서 나온다. git 실행은
//! platform adapter가 하고 이 모듈은 **바이트만** 본다 — 그래야 헤드리스로 전수 검증이 되고, 파싱 실수가 프로세스
//! 실행 코드와 섞이지 않는다.
//!
//! **할당하지 않는다.** 결과는 입력 텍스트를 가리키는 슬라이스이고 호출자가 텍스트 수명을 소유한다(agent_observer와
//! 같은 규율). 목록이 커도 파서가 메모리를 늘리지 않으므로 상한은 호출자가 읽어 온 바이트로 이미 정해져 있다.
//!
//! **베이스**: git의 `--porcelain=v2` 포맷(git 공식 문서 `git-status(1)` "Porcelain Format Version 2")과 `--numstat`.
//! v1이 아니라 v2를 쓰는 이유는 ⑴ staged/worktree 상태가 `XY` 두 칸으로 분리돼 **두 축을 뭉개지 않아도 되고**
//!    (2판의 두 그룹이 바로 그 두 축이다 — 하나로 접힌 v1으로는 '일부만 스테이지'를 말할 수 없다),
//! ⑵ rename의 원래 경로가 같은 줄에 오며, ⑶ `--branch`가 ahead/behind를 함께 준다(별도 rev-list 호출이 필요 없다).

const std = @import("std");

/// 한 축(staged 또는 worktree)의 변경 종류. porcelain v2의 `XY` 한 글자를 그대로 옮긴다.
pub const Change = enum {
    unchanged,
    modified,
    added,
    deleted,
    renamed,
    copied,
    type_changed,
    /// 병합 충돌(`u` 레코드). staged/worktree로 나뉘지 않아 양쪽에 같은 값이 들어간다.
    unmerged,
    /// 추적되지 않은 파일(`?` 레코드). worktree 축에만 온다.
    untracked,

    fn fromCode(c: u8) Change {
        return switch (c) {
            'M' => .modified,
            'A' => .added,
            'D' => .deleted,
            'R' => .renamed,
            'C' => .copied,
            'T' => .type_changed,
            else => .unchanged,
        };
    }

    /// 사용자에게 보이는 한 글자. 목록 행 오른쪽 끝에 그대로 쓴다.
    pub fn letter(self: Change) u8 {
        return switch (self) {
            .unchanged => ' ',
            .modified => 'M',
            .added => 'A',
            .deleted => 'D',
            .renamed => 'R',
            .copied => 'C',
            .type_changed => 'T',
            .unmerged => 'U',
            .untracked => 'U',
        };
    }
};

pub const Entry = struct {
    staged: Change,
    worktree: Change,
    path: []const u8,
    /// rename/copy의 원래 경로(그 외 null).
    orig_path: ?[]const u8 = null,
    /// 하위 모듈(gitlink, mode 160000)인가. porcelain v2의 `<sub>` 필드가 `S`로 시작하면 참이다.
    /// **텍스트 비교 대상이 아니다** — 커밋 포인터라 blob이 없고, 작업트리 쪽은 디렉터리다(실측).
    submodule: bool = false,

    /// 병합 충돌 중인가(`u` 레코드). 해결 전에는 index에 stage 0이 없어 `:<경로>` 읽기가 실패한다(실측).
    pub fn isConflicted(self: Entry) bool {
        return self.staged == .unmerged or self.worktree == .unmerged;
    }

    // **`isStaged`/`isUnstaged`는 2판에서 삭제했다**(2026-08-14). 그 둘은 "행이 어느 섹션에 드는가"를 답하던
    // 술어이고, 그 판정은 이제 `scm_view.belongs` 하나가 소유한다(docs/editor-surface-dock.md §3.5.2).
    // 남겨 두면 "스테이지됨"의 정의가 둘이 되고, 한쪽만 고쳐지는 순간 목록과 행 동작이 다른 말을 한다.

    pub fn isUntracked(self: Entry) bool {
        return self.worktree == .untracked;
    }
};

/// `# branch.*` 헤더. upstream이 없으면 `upstream`/`ahead`/`behind`가 비고, 그때는 브랜치 줄이 ahead/behind 자리를
/// 비운다(docs/editor-surface-dock.md §3.5 — 오류가 아니다).
pub const Head = struct {
    branch: ?[]const u8 = null,
    upstream: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    /// `# branch.head`가 `(detached)`면 참. 브랜치 이름 자리에 그 문자열이 오므로 별도로 구분한다.
    detached: bool = false,
    has_ab: bool = false,
    /// 첫 커밋 전(`# branch.oid (initial)`). **HEAD가 없다** — 그래서 `git diff … HEAD`류가 exit 128로 실패한다.
    /// 그건 오류가 아니라 그 상태의 정상이고, 호출자는 이 값을 보고 index 기준 명령으로 갈아탄다
    /// (docs/editor-surface-dock.md §3.5.2). **"명령이 빈 출력을 냈다"로 대신 판정하면 안 된다** — 평범한
    /// 저장소에서 그 명령이 실패해도 같은 빈 값이 되어, 다른 범위의 숫자를 HEAD 범위인 척 보여 준다.
    unborn: bool = false,
};

/// 기본 브랜치 대비 ahead/behind(§3.5). `status --branch`의 `# branch.ab`와 **다른 사실**이다 — 그쪽은
/// `@{u}` 기준이라 PR 브랜치에서 늘 `0 0`이다.
pub const AheadBehind = struct { ahead: u32, behind: u32 };

/// `git rev-list --count --left-right origin/HEAD...HEAD`의 한 줄을 읽는다.
///
/// 출력은 `<왼쪽>\t<오른쪽>`이고 **왼쪽이 behind**다(기준에만 있는 커밋 = 내가 못 받은 것), 오른쪽이 ahead다
/// (내게만 있는 커밋 = 아직 안 보낸 것). 형식이 어긋나면 **null**이다 — 0으로 뭉개면 "차이 없음"이라는
/// 틀린 진술이 되고, null이면 호출자가 `@{u}` 값으로 되돌아간다.
///
/// 구분자는 탭이지만 공백도 받는다(git 버전·설정에 따라 흔들릴 여지를 남긴다 — 숫자 둘이 순서대로 오는
/// 것이 계약이다).
pub fn parseAheadBehind(text: []const u8) ?AheadBehind {
    const line = std.mem.trim(u8, text, " \t\r\n");
    if (line.len == 0) return null;
    var it = std.mem.tokenizeAny(u8, line, " \t");
    const left = it.next() orelse return null;
    const right = it.next() orelse return null;
    if (it.next() != null) return null; // 셋 이상이면 우리가 아는 형식이 아니다
    const behind = std.fmt.parseInt(u32, left, 10) catch return null;
    const ahead = std.fmt.parseInt(u32, right, 10) catch return null;
    return .{ .ahead = ahead, .behind = behind };
}

pub fn parseHead(text: []const u8) Head {
    var head: Head = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        // **첫 레코드에서 멈춘다.** porcelain v2는 헤더(`#`)를 전부 앞에 낸다(실측·형식 규약). 끝까지 훑으면
        // 이 함수가 status 전체 크기에 비례하는데, 목록·히트테스트·스크롤 상한이 **매 프레임 각각** 부르므로
        // 변경이 수천 개인 저장소에서 프레임마다 수 MB를 다시 읽게 된다. 빈 줄은 마지막 개행이라 건너뛴다.
        if (line.len == 0) continue;
        if (line[0] != '#') break;
        if (!std.mem.startsWith(u8, line, "# branch.")) continue;
        const rest = line["# branch.".len..];
        if (std.mem.startsWith(u8, rest, "oid ")) {
            // 첫 커밋 전에는 git이 해시 자리에 `(initial)`을 적는다(실측).
            head.unborn = std.mem.eql(u8, rest["oid ".len..], "(initial)");
        } else if (std.mem.startsWith(u8, rest, "head ")) {
            const value = rest["head ".len..];
            if (std.mem.eql(u8, value, "(detached)")) {
                head.detached = true;
            } else if (value.len > 0) head.branch = value;
        } else if (std.mem.startsWith(u8, rest, "upstream ")) {
            const value = rest["upstream ".len..];
            if (value.len > 0) head.upstream = value;
        } else if (std.mem.startsWith(u8, rest, "ab ")) {
            // `+N -M` — git이 항상 부호를 붙여 준다. 형식이 어긋나면 조용히 0으로 둔다(표시가 틀리느니 안 뜬다).
            var parts = std.mem.splitScalar(u8, rest["ab ".len..], ' ');
            const ahead = parts.next() orelse continue;
            const behind = parts.next() orelse continue;
            if (ahead.len < 2 or behind.len < 2 or ahead[0] != '+' or behind[0] != '-') continue;
            head.ahead = std.fmt.parseInt(u32, ahead[1..], 10) catch continue;
            head.behind = std.fmt.parseInt(u32, behind[1..], 10) catch continue;
            head.has_ab = true;
        }
    }
    return head;
}

/// 상태 레코드 이터레이터. 헤더(`#`)는 건너뛰고 `1`/`2`/`u`/`?` 레코드만 낸다.
pub const Iterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *Iterator) ?Entry {
        while (self.lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len < 2) continue;
            switch (line[0]) {
                '?' => {
                    if (line[1] != ' ' or line.len < 3) continue; // 경로가 빈 줄은 레코드로 치지 않는다
                    return .{ .staged = .unchanged, .worktree = .untracked, .path = line[2..] };
                },
                '!' => continue, // ignored — 목록에 넣지 않는다
                'u' => {
                    const path = lastField(line) orelse continue;
                    return .{ .staged = .unmerged, .worktree = .unmerged, .path = path };
                },
                '1', '2' => {
                    const renamed = line[0] == '2';
                    if (line.len < 4 or line[1] != ' ') continue;
                    const xy = line[2..4];
                    const staged = Change.fromCode(xy[0]);
                    const worktree = Change.fromCode(xy[1]);
                    // `<sub>` 필드(XY 다음): `N...`=일반, `S`로 시작하면 하위 모듈이다. 텍스트 비교 대상이 아니므로
                    // 여기서 표시해 둔다(모르면 blob을 읽으려다 실패하고 "표시할 수 없음"만 남는다 — 실측).
                    const submodule = line.len > 5 and line[5] == 'S';
                    if (!renamed) {
                        const path = lastField(line) orelse continue;
                        return .{ .staged = staged, .worktree = worktree, .path = path, .submodule = submodule };
                    }
                    // `2` 레코드의 마지막 필드는 `<새 경로>\t<원래 경로>`다(경로에 공백이 있어도 탭이 가른다).
                    const field = lastField(line) orelse continue;
                    const tab = std.mem.indexOfScalar(u8, field, '\t') orelse continue;
                    return .{
                        .staged = staged,
                        .worktree = worktree,
                        .path = field[0..tab],
                        .orig_path = field[tab + 1 ..],
                        .submodule = submodule,
                    };
                },
                else => continue,
            }
        }
        return null;
    }
};

/// 공백으로 나뉜 마지막 필드(=경로). porcelain v2는 경로 앞 필드 수가 레코드 종류마다 고정이라, 경로에 공백이 있어도
/// **마지막 필드부터 거꾸로** 잡으면 안 된다 — 대신 고정 필드 수만큼 건너뛴 나머지 전부를 경로로 본다.
fn lastField(line: []const u8) ?[]const u8 {
    const fields: usize = switch (line[0]) {
        '1' => 8, // <1> <XY> <sub> <mH> <mI> <mW> <hH> <hI> <path>
        '2' => 9, // + <X><score>
        'u' => 10, // <u> <XY> <sub> <m1> <m2> <m3> <mW> <h1> <h2> <h3> <path>
        else => return null,
    };
    var index: usize = 0;
    var seen: usize = 0;
    while (index < line.len and seen < fields) : (index += 1) {
        if (line[index] == ' ') {
            seen += 1;
            while (index + 1 < line.len and line[index + 1] == ' ') index += 1;
        }
    }
    if (seen < fields or index >= line.len) return null;
    return line[index..];
}

pub fn iterate(text: []const u8) Iterator {
    return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
}

/// `git diff --numstat` 한 줄. binary는 git이 `-\t-\t<경로>`로 주므로 숫자 대신 그 사실을 싣는다 —
/// **0/0으로 거짓 표시하지 않는다**(docs/editor-surface-dock.md §3.5).
pub const LineDelta = struct {
    added: u32 = 0,
    removed: u32 = 0,
    binary: bool = false,
    /// numstat이 rename을 `A => B` 또는 `pre/{A => B}/post` **한 필드**로 적었는가. 그러면 `path`는 status의 경로와
    /// 글자 그대로 다르므로 그대로 대조하면 안 된다 — `newPath(buf)`로 새 경로를 복원해 맞춘다.
    rename: bool = false,
    path: []const u8,

    /// rename 표기를 푼 **새 경로**를 `buf`에 쓰고 그 슬라이스를 돌려준다(그 외에는 `path` 그대로).
    /// 버퍼가 모자라면 null — 호출자는 그 행의 증감을 비워 두고 표시만 건너뛴다(틀린 숫자를 붙이지 않는다).
    ///
    /// 형식(실측): `gone.txt => renamed.txt`, `{old => src}/deep.txt`. 뒤쪽 형태는 공통 prefix/suffix를 묶어 주는
    /// git의 축약이라 **문자열 치환이 아니라 구간 조립**이 필요하다.
    pub fn newPath(self: LineDelta, buf: []u8) ?[]const u8 {
        if (!self.rename) return self.path;
        const arrow = std.mem.indexOf(u8, self.path, " => ") orelse return self.path;
        if (std.mem.lastIndexOfScalar(u8, self.path[0..arrow], '{')) |open| {
            const close = std.mem.indexOfScalarPos(u8, self.path, arrow, '}') orelse return null;
            const prefix = self.path[0..open];
            const new_mid = self.path[arrow + 4 .. close];
            const suffix = self.path[close + 1 ..];
            const total = prefix.len + new_mid.len + suffix.len;
            if (total > buf.len) return null;
            @memcpy(buf[0..prefix.len], prefix);
            @memcpy(buf[prefix.len..][0..new_mid.len], new_mid);
            @memcpy(buf[prefix.len + new_mid.len ..][0..suffix.len], suffix);
            return buf[0..total];
        }
        return self.path[arrow + 4 ..];
    }
};

fn isRenamePath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, " => ") != null;
}

pub const NumstatIterator = struct {
    lines: std.mem.SplitIterator(u8, .scalar),

    pub fn next(self: *NumstatIterator) ?LineDelta {
        while (self.lines.next()) |raw| {
            const line = std.mem.trimEnd(u8, raw, "\r");
            if (line.len == 0) continue;
            const t1 = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const t2 = std.mem.indexOfScalarPos(u8, line, t1 + 1, '\t') orelse continue;
            const added = line[0..t1];
            const removed = line[t1 + 1 .. t2];
            const path = line[t2 + 1 ..];
            if (path.len == 0) continue;
            if (std.mem.eql(u8, added, "-") and std.mem.eql(u8, removed, "-"))
                return .{ .binary = true, .path = path, .rename = isRenamePath(path) };
            return .{
                .added = std.fmt.parseInt(u32, added, 10) catch continue,
                .removed = std.fmt.parseInt(u32, removed, 10) catch continue,
                .path = path,
                .rename = isRenamePath(path),
            };
        }
        return null;
    }
};

/// `check-ignore --stdin -z` 출력에서 **무시된 경로**를 하나씩 꺼낸다. 출력은 입력 순서대로, 무시된
/// 것만, NUL 로 끝나는 경로들이다(`-v` 없이 쓰므로 부가 정보가 없다). 빈 조각은 건너뛴다 — 마지막
/// NUL 뒤의 빈 꼬리가 항목으로 세지 않도록.
pub fn iterateIgnored(text: []const u8) IgnoredIterator {
    return .{ .rest = text };
}

pub const IgnoredIterator = struct {
    rest: []const u8,

    pub fn next(self: *IgnoredIterator) ?[]const u8 {
        while (self.rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, 0) orelse self.rest.len;
            const item = self.rest[0..end];
            self.rest = if (end < self.rest.len) self.rest[end + 1 ..] else self.rest[end..];
            if (item.len > 0) return item;
        }
        return null;
    }
};

pub fn iterateNumstat(text: []const u8) NumstatIterator {
    return .{ .lines = std.mem.splitScalar(u8, text, '\n') };
}

const testing = std.testing;

// 아래 fixture는 실제 git 저장소에서 그대로 캡처했다(2026-07-31, git 포맷 v2). 손으로 지어낸 문자열이 아니라
// 실행 결과라, 필드 수·탭 위치·부호 같은 세부가 추측이 아니다.
const real_status =
    "# branch.oid 995e1488bb2e47bf5c7a44f26c20981f616698a7\n" ++
    "# branch.head main\n" ++
    "1 A. N... 000000 100644 100644 0000000000000000000000000000000000000000 88768efdf77ec78c9a995f94881793be6a41752b blob.bin\n" ++
    "1 MM N... 100644 100644 100644 422c2b7ab3b3c668038da977e4e93a5fc623169c 7be73ce3c1b1cdaea86e8168dfee8575175953bf keep.txt\n" ++
    "2 R. N... 100644 100644 100644 587be6b4c3f93f93c489c0111bba5596147a26cb 587be6b4c3f93f93c489c0111bba5596147a26cb R100 renamed.txt\tgone.txt\n" ++
    "? untracked.txt\n";

test "실측 porcelain v2: 네 종류 레코드를 두 축으로 가른다" {
    var it = iterate(real_status);

    const added = it.next().?;
    try testing.expectEqualStrings("blob.bin", added.path);
    try testing.expectEqual(Change.added, added.staged);
    try testing.expectEqual(Change.unchanged, added.worktree);
    // 두 축을 **따로** 낸다는 것이 이 파서의 계약이다 — 어느 섹션에 드는지는 상위(scm_view)가 정한다.

    // `MM` — 두 축이 **동시에** 변경이다(일부만 스테이지한 파일). 2판은 이걸 두 그룹에 각각 한 행씩 그린다.
    const both = it.next().?;
    try testing.expectEqualStrings("keep.txt", both.path);
    try testing.expectEqual(Change.modified, both.staged);
    try testing.expectEqual(Change.modified, both.worktree);

    const renamed = it.next().?;
    try testing.expectEqualStrings("renamed.txt", renamed.path);
    try testing.expectEqualStrings("gone.txt", renamed.orig_path.?);
    try testing.expectEqual(Change.renamed, renamed.staged);

    const untracked = it.next().?;
    try testing.expectEqualStrings("untracked.txt", untracked.path);
    try testing.expect(untracked.isUntracked());
    try testing.expectEqual(Change.unchanged, untracked.staged);

    try testing.expect(it.next() == null);
}

test "경로에 공백이 있어도 필드 수로 잘라 낸다" {
    // 마지막 공백부터 거꾸로 자르면 여기서 깨진다 — porcelain v2는 경로를 인용하지 않는다(-z 없이도 그렇다).
    const text = "1 .M N... 100644 100644 100644 aaa bbb my dir/file name.txt\n";
    var it = iterate(text);
    const e = it.next().?;
    try testing.expectEqualStrings("my dir/file name.txt", e.path);
    try testing.expectEqual(Change.modified, e.worktree);
    try testing.expectEqual(Change.unchanged, e.staged);
}

test "branch 헤더: upstream이 없으면 ahead/behind도 없다" {
    const head = parseHead(real_status);
    try testing.expectEqualStrings("main", head.branch.?);
    try testing.expect(head.upstream == null);
    try testing.expect(!head.has_ab); // 기준이 없으니 '브랜치에 COMMIT 됨' 섹션을 숨긴다

    const with_upstream = parseHead(
        "# branch.head feature/x\n# branch.upstream origin/main\n# branch.ab +3 -1\n",
    );
    try testing.expectEqualStrings("feature/x", with_upstream.branch.?);
    try testing.expectEqualStrings("origin/main", with_upstream.upstream.?);
    try testing.expect(with_upstream.has_ab);
    try testing.expectEqual(@as(u32, 3), with_upstream.ahead);
    try testing.expectEqual(@as(u32, 1), with_upstream.behind);

    const detached = parseHead("# branch.head (detached)\n");
    try testing.expect(detached.detached and detached.branch == null);
}

test "numstat rename: status 경로와 맞추려면 새 경로를 복원해야 한다" {
    // 실측: `--find-renames`가 켜지면 numstat 경로가 status의 경로와 **글자 그대로 다르다**. 그대로 대조하면
    // rename된 파일의 +N -N이 영영 안 붙는다.
    var buf: [256]u8 = undefined;
    var it = iterateNumstat("0\t0\tgone.txt => renamed.txt\n0\t0\t{old => src}/deep.txt\n3\t1\tplain.txt\n");

    const simple = it.next().?;
    try testing.expect(simple.rename);
    try testing.expectEqualStrings("renamed.txt", simple.newPath(&buf).?);

    // 축약형은 공통 prefix/suffix를 묶으므로 구간 조립이 필요하다(문자열 치환으로는 안 된다).
    const compact = it.next().?;
    try testing.expect(compact.rename);
    try testing.expectEqualStrings("src/deep.txt", compact.newPath(&buf).?);

    const plain = it.next().?;
    try testing.expect(!plain.rename);
    try testing.expectEqualStrings("plain.txt", plain.newPath(&buf).?);

    // 버퍼가 모자라면 null — 틀린 경로에 숫자를 붙이느니 그 행의 증감을 비운다.
    var tiny: [4]u8 = undefined;
    var one = iterateNumstat("0\t0\t{old => src}/deep.txt\n");
    try testing.expect(one.next().?.newPath(&tiny) == null);
}

test "numstat: 숫자와 binary를 구분한다" {
    var it = iterateNumstat("11\t11\tsrc/a.ts\n-\t-\tassets/logo.png\n6\t2\tmy dir/b.zig\n");
    const a = it.next().?;
    try testing.expectEqual(@as(u32, 11), a.added);
    try testing.expectEqual(@as(u32, 11), a.removed);
    try testing.expect(!a.binary);

    const bin = it.next().?;
    try testing.expect(bin.binary);
    try testing.expectEqualStrings("assets/logo.png", bin.path);
    try testing.expectEqual(@as(u32, 0), bin.added); // 0/0으로 **표시하지 않는다** — binary 플래그가 권위다

    const spaced = it.next().?;
    try testing.expectEqualStrings("my dir/b.zig", spaced.path);
    try testing.expectEqual(@as(u32, 6), spaced.added);
    try testing.expect(it.next() == null);
}

test "손상 입력은 조용히 건너뛴다(부분 표시가 잘못된 표시보다 낫다)" {
    var it = iterate("garbage\n1 too short\n? \n! ignored.txt\n1 .M N... 1 2 3 a b ok.txt\n");
    const e = it.next().?;
    try testing.expectEqualStrings("ok.txt", e.path); // `?` 뒤 빈 경로·`!`·짧은 줄은 전부 건너뛴다
    try testing.expect(it.next() == null);

    var n = iterateNumstat("nope\n1\tx\ty\n3\t4\tgood.txt\n");
    try testing.expectEqualStrings("good.txt", n.next().?.path);
    try testing.expect(n.next() == null);
}

/// `git diff --name-status` 한 줄: 상태 문자 + 경로(rename이면 옛 경로와 새 경로 둘).
///
/// **왜 별도 파서인가**: porcelain v2(`iterate`)는 작업트리·index 상태를 말하고, 이건 **커밋 범위**가 바꾼 것을
/// 말한다("브랜치에 COMMIT 됨" 섹션 — docs/editor-surface-dock.md §3.5). 같은 파일이 두 곳에 다른 상태로 나올 수 있어
/// 하나의 파서로 뭉개면 안 된다.
pub const NameStatusEntry = struct {
    /// `M`·`A`·`D`·`R`(rename)·`C`(copy) 등 git이 준 첫 글자.
    letter: u8,
    /// 지금 경로(rename이면 새 경로).
    path: []const u8,
    /// rename/copy의 옛 경로(그 외 null).
    orig_path: ?[]const u8 = null,
};

pub fn iterateNameStatus(text: []const u8) NameStatusIterator {
    return .{ .rest = text };
}

pub const NameStatusIterator = struct {
    rest: []const u8,

    pub fn next(self: *NameStatusIterator) ?NameStatusEntry {
        while (self.rest.len > 0) {
            const end = std.mem.indexOfScalar(u8, self.rest, '\n') orelse self.rest.len;
            const line = self.rest[0..end];
            self.rest = if (end < self.rest.len) self.rest[end + 1 ..] else "";
            if (parseNameStatusLine(line)) |entry| return entry;
        }
        return null;
    }
};

/// `M\tpath` · `R100\told\tnew` 한 줄. **`--raw` 줄도 받는다**(`:100644 100644 aaa bbb M\tpath`) —
/// 상태 문자 앞의 mode/blob 필드는 공백으로 갈리므로 첫 탭 **앞의 마지막 공백** 뒤부터가 곧
/// name-status 줄이다. 두 형식이 한 함수에서 나와야 파싱 규칙이 갈리지 않는다.
fn parseNameStatusLine(raw_line: []const u8) ?NameStatusEntry {
    var line = std.mem.trimEnd(u8, raw_line, "\r");
    if (line.len < 3) return null;
    const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    if (line[0] == ':') {
        // `--raw`: 상태 문자는 첫 탭 앞의 마지막 공백 뒤에 있다. 없으면 못 믿는 줄이다(잘린 출력).
        const space = std.mem.lastIndexOfScalar(u8, line[0..first_tab], ' ') orelse return null;
        line = line[space + 1 ..];
        if (line.len < 3) return null;
    }
    // `R100\told\tnew` / `M\tpath`. 상태 뒤 숫자(유사도)는 무시한다 — 표시에 쓰지 않는다.
    const tab = std.mem.indexOfScalar(u8, line, '\t') orelse return null;
    const letter = line[0];
    // 상태 자리에 글자가 아닌 것이 오면 그 줄은 name-status가 아니다 — numstat 줄(`12\t3\tpath`)이
    // 그대로 여기 오면 `letter = '1'`, `path = "3\tpath"` 같은 **없는 파일**이 목록에 선다.
    if (!std.ascii.isAlphabetic(letter)) return null;
    const rest = line[tab + 1 ..];
    if (letter == 'R' or letter == 'C') {
        const sep = std.mem.indexOfScalar(u8, rest, '\t') orelse return null;
        // 옛 경로가 비어 있으면 그 줄은 못 믿는다(잘린 출력).
        if (sep == 0 or sep + 1 >= rest.len) return null;
        return .{ .letter = letter, .path = rest[sep + 1 ..], .orig_path = rest[0..sep] };
    }
    if (rest.len == 0) return null;
    return .{ .letter = letter, .path = rest };
}

/// 그 줄이 `--numstat` 한 줄인가(`12\t3\tpath` · `-\t-\tpath`). 상태 줄과 **같은 출력에 섞여 오므로**
/// 종류 판정이 파싱보다 먼저다.
fn isNumstatLine(raw_line: []const u8) bool {
    const line = std.mem.trimEnd(u8, raw_line, "\r");
    if (line.len == 0 or line[0] == ':') return false;
    const t1 = std.mem.indexOfScalar(u8, line, '\t') orelse return false;
    const t2 = std.mem.indexOfScalarPos(u8, line, t1 + 1, '\t') orelse return false;
    return isCountField(line[0..t1]) and isCountField(line[t1 + 1 .. t2]) and t2 + 1 < line.len;
}

fn isCountField(field: []const u8) bool {
    if (field.len == 0) return false;
    if (std.mem.eql(u8, field, "-")) return true; // 이진 파일
    for (field) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

/// 펼친 커밋·턴의 파일 한 줄 — **상태 문자와 증감이 함께** 온다(P4b).
///
/// **베이스**: `git show --format= --raw --numstat <oid>`(실측 git 2.50.1). `--name-status`와
/// `--numstat`은 같은 출력 그룹이라 **뒤에 온 쪽만** 나오지만(실측), `--raw`는 다른 그룹이라 numstat과
/// 나란히 온다 — 그래서 프로세스를 하나 더 쓰지 않고 증감을 얻는다.
pub const CommitFileEntry = struct {
    letter: u8,
    path: []const u8,
    orig_path: ?[]const u8 = null,
    added: u32 = 0,
    removed: u32 = 0,
    binary: bool = false,
    /// 증감을 **실제로 읽었나**. false면 화면은 그 자리를 비운다 — 0/0으로 그리면 "안 바뀐 파일"이라는
    /// 거짓 진술이 된다(변경 사항 탭의 `unknown_delta`와 같은 규율).
    has_delta: bool = false,
};

/// 상태 줄과 numstat 줄을 **자리로 짝짓는다**. git은 두 형식을 같은 diff queue에서 같은 순서로 내므로
/// (실측) i번째끼리 맞는다. 상태 줄만 있는 출력(`--name-status`만 부른 옛 경로)도 그대로 흐른다 —
/// 그때는 증감만 빈다.
///
/// **짝을 미리 세지 않는다.** 이 이터레이터는 **매 프레임 여러 번** 돌고(행 수 세기·그리기·클릭 해석),
/// 커밋 하나가 파일 수천 개를 바꿀 수 있다 — 개수를 세려면 그때마다 원문을 통째로 한 번 더 훑어야 한다.
/// 대신 **꺼내면서 대조한다**: 경로가 어긋나거나 짝이 모자라는 순간 그 뒤로는 숫자를 안 붙인다(아래
/// `next`). 잘린 출력은 **끝에서** 잘리므로 앞의 짝은 그대로 정확하고, 어긋난 지점부터만 자리가 빈다.
pub fn iterateCommitFiles(text: []const u8) CommitFileIterator {
    return .{ .status_rest = text, .delta_rest = text, .paired = true };
}

pub const CommitFileIterator = struct {
    status_rest: []const u8,
    delta_rest: []const u8,
    paired: bool,

    pub fn next(self: *CommitFileIterator) ?CommitFileEntry {
        const status = self.nextStatus() orelse return null;
        var entry: CommitFileEntry = .{ .letter = status.letter, .path = status.path, .orig_path = status.orig_path };
        if (!self.paired) return entry;
        const delta = self.nextDelta() orelse {
            // 짝이 모자라면 **여기서 짝짓기를 그만둔다** — 뒤의 줄들이 한 칸씩 밀려 남의 숫자를 단다.
            self.paired = false;
            return entry;
        };
        // rename은 numstat 경로가 `old => new`로 축약되어 status 경로와 글자 그대로 다르다 — 그 대조는
        // 버퍼가 필요하므로(`newPath`) 여기서는 자리만 믿는다. 그 외에는 경로가 같아야 하고, 다르면
        // 두 목록이 어긋났다는 뜻이라 그때부터 숫자를 붙이지 않는다.
        if (!delta.rename and !std.mem.eql(u8, delta.path, status.path)) {
            self.paired = false;
            return entry;
        }
        entry.added = delta.added;
        entry.removed = delta.removed;
        entry.binary = delta.binary;
        entry.has_delta = true;
        return entry;
    }

    fn nextStatus(self: *CommitFileIterator) ?NameStatusEntry {
        while (self.status_rest.len > 0) {
            const line = takeLine(&self.status_rest);
            if (isNumstatLine(line)) continue;
            if (parseNameStatusLine(line)) |entry| return entry;
        }
        return null;
    }

    fn nextDelta(self: *CommitFileIterator) ?LineDelta {
        while (self.delta_rest.len > 0) {
            const line = takeLine(&self.delta_rest);
            if (!isNumstatLine(line)) continue;
            var one = iterateNumstat(line);
            if (one.next()) |delta| return delta;
        }
        return null;
    }
};

fn takeLine(rest: *[]const u8) []const u8 {
    const end = std.mem.indexOfScalar(u8, rest.*, '\n') orelse rest.*.len;
    const line = rest.*[0..end];
    rest.* = if (end < rest.*.len) rest.*[end + 1 ..] else "";
    return line;
}

test "name-status: 상태 문자와 경로, rename의 옛 경로를 낸다" {
    var it = iterateNameStatus("M\tsrc/main.zig\nA\tnew.txt\nD\tgone.txt\nR100\told.txt\tnew.txt\n");
    const first = it.next().?;
    try std.testing.expectEqual(@as(u8, 'M'), first.letter);
    try std.testing.expectEqualStrings("src/main.zig", first.path);
    try std.testing.expectEqualStrings("new.txt", it.next().?.path);
    try std.testing.expectEqual(@as(u8, 'D'), it.next().?.letter);
    const renamed = it.next().?;
    try std.testing.expectEqualStrings("new.txt", renamed.path);
    try std.testing.expectEqualStrings("old.txt", renamed.orig_path.?);
    try std.testing.expect(it.next() == null);
}

test "name-status: 잘린 줄은 건너뛴다(엉뚱한 경로를 만들지 않는다)" {
    // rename인데 새 경로가 없는 줄, 탭이 없는 줄, 너무 짧은 줄.
    var it = iterateNameStatus("R100\tonly-old\nM\nX\nM\tok.txt\n");
    try std.testing.expectEqualStrings("ok.txt", it.next().?.path);
    try std.testing.expect(it.next() == null);
}

// 아래 두 fixture 는 실제 저장소에서 그대로 캡처했다(2026-08-27, git 2.50.1) — 손으로 지어낸 문자열이
// 아니라 `git show --format= --raw --numstat --find-renames --first-parent -m <oid>` 의 출력이다.
const real_commit_files =
    ":100644 100644 efb30dbc 49ac6ee0 M\tdocs/plans/windows-platform.md\n" ++
    ":100644 100644 b3718734 6592e53b M\tdocs/windows-platform.md\n" ++
    ":100644 100644 3475532b d832b8b6 M\tsrc/main.zig\n" ++
    ":100644 100644 09727edc 48d6c7fc M\tsrc/platform/windows/win32_agent_surface.zig\n" ++
    "1\t1\tdocs/plans/windows-platform.md\n" ++
    "46\t0\tdocs/windows-platform.md\n" ++
    "84\t1\tsrc/main.zig\n" ++
    "4\t0\tsrc/platform/windows/win32_agent_surface.zig\n";

const real_commit_rename =
    ":100644 100644 87bfddd 87bfddd R100\ta.txt\trenamed.txt\n" ++
    "0\t0\ta.txt => renamed.txt\n";

test "커밋 파일 목록: raw 줄의 상태와 numstat 줄의 증감이 한 항목으로 온다" {
    var it = iterateCommitFiles(real_commit_files);
    const first = it.next().?;
    try testing.expectEqual(@as(u8, 'M'), first.letter);
    try testing.expectEqualStrings("docs/plans/windows-platform.md", first.path);
    try testing.expect(first.has_delta);
    try testing.expectEqual(@as(u32, 1), first.added);
    try testing.expectEqual(@as(u32, 1), first.removed);

    const second = it.next().?;
    try testing.expectEqualStrings("docs/windows-platform.md", second.path);
    try testing.expectEqual(@as(u32, 46), second.added);
    try testing.expectEqual(@as(u32, 0), second.removed);

    _ = it.next().?; // src/main.zig
    const last = it.next().?;
    try testing.expectEqualStrings("src/platform/windows/win32_agent_surface.zig", last.path);
    try testing.expectEqual(@as(u32, 4), last.added);
    try testing.expect(it.next() == null);
}

test "커밋 파일 목록: numstat 줄이 파일 항목으로 새지 않는다" {
    // 이 회귀가 나면 목록이 **정확히 두 배**가 되고, 없는 파일(`3\tpath`)이 줄로 선다.
    var it = iterateCommitFiles(real_commit_files);
    var count: usize = 0;
    while (it.next()) |entry| : (count += 1) {
        try testing.expect(std.ascii.isAlphabetic(entry.letter));
        try testing.expect(std.mem.indexOfScalar(u8, entry.path, '\t') == null);
    }
    try testing.expectEqual(@as(usize, 4), count);
}

test "커밋 파일 목록: rename은 자리로 짝짓는다(numstat 경로가 축약된다)" {
    var it = iterateCommitFiles(real_commit_rename);
    const renamed = it.next().?;
    try testing.expectEqual(@as(u8, 'R'), renamed.letter);
    try testing.expectEqualStrings("renamed.txt", renamed.path);
    try testing.expectEqualStrings("a.txt", renamed.orig_path.?);
    // 내용이 안 바뀐 rename 이라 0/0 이지만 **읽은 0** 이다 — 자리를 비우는 «못 읽었다» 와 다르다.
    try testing.expect(renamed.has_delta);
    try testing.expect(it.next() == null);
}

test "커밋 파일 목록: 이진 파일은 숫자 대신 그 사실을 싣는다" {
    var it = iterateCommitFiles(
        ":000000 100644 0000000 aaaaaaa A\tassets/logo.png\n" ++
            "-\t-\tassets/logo.png\n",
    );
    const bin = it.next().?;
    try testing.expect(bin.binary);
    try testing.expect(bin.has_delta);
    try testing.expectEqual(@as(u32, 0), bin.added);
}

test "커밋 파일 목록: 짝이 모자라면 그 뒤로 숫자를 안 붙인다(남의 숫자를 달지 않는다)" {
    // 출력이 상한에서 잘리면 numstat 블록이 짧게 온다. 잘림은 **끝에서** 일어나므로 앞의 짝은 정확하고,
    // 모자란 지점부터 자리가 빈다 — 그 뒤로 한 칸씩 밀어 남의 숫자를 다는 것이 이 테스트가 막는 결함이다.
    var it = iterateCommitFiles(
        ":100644 100644 aaa bbb M\ta.txt\n" ++
            ":100644 100644 ccc ddd M\tb.txt\n" ++
            "1\t2\ta.txt\n",
    );
    const a = it.next().?;
    try testing.expectEqualStrings("a.txt", a.path);
    try testing.expect(a.has_delta);
    try testing.expectEqual(@as(u32, 1), a.added);
    const b = it.next().?;
    try testing.expectEqualStrings("b.txt", b.path);
    try testing.expect(!b.has_delta);
    try testing.expect(it.next() == null);
}

test "커밋 파일 목록: 두 블록이 어긋나면 그 지점부터 숫자를 버린다" {
    // 경로가 안 맞는다 = 두 목록이 다른 것을 세고 있다. 그때부터는 **자리를 믿을 근거가 없다**.
    var it = iterateCommitFiles(
        ":100644 100644 aaa bbb M\ta.txt\n" ++
            ":100644 100644 ccc ddd M\tb.txt\n" ++
            "1\t2\tsomewhere-else.txt\n" ++
            "3\t4\tb.txt\n",
    );
    const a = it.next().?;
    try testing.expect(!a.has_delta); // 첫 대조부터 어긋났다
    const b = it.next().?;
    try testing.expect(!b.has_delta); // 한 번 어긋나면 뒤도 안 믿는다
}

test "커밋 파일 목록: 두 블록의 순서가 뒤집혀도 같은 답이 나온다" {
    // git 의 출력 순서는 **우리 계약이 아니다**(diff 형식 그룹의 내부 순서다). 이 이터레이터가 줄을
    // 종류로 갈라 각각 훑는 것은 그 순서에 기대지 않기 위해서다 — 그 방어가 실제로 서 있는지 본다.
    var it = iterateCommitFiles(
        "1\t1\ta.txt\n" ++
            "46\t0\tb.txt\n" ++
            ":100644 100644 aaa bbb M\ta.txt\n" ++
            ":100644 100644 ccc ddd M\tb.txt\n",
    );
    const a = it.next().?;
    try testing.expectEqualStrings("a.txt", a.path);
    try testing.expectEqual(@as(u32, 1), a.added);
    const b = it.next().?;
    try testing.expectEqualStrings("b.txt", b.path);
    try testing.expectEqual(@as(u32, 46), b.added);
    try testing.expect(it.next() == null);
}

test "커밋 파일 목록: 공백·이스케이프가 든 경로도 두 블록이 같은 글자로 온다(실측)" {
    // 실측(2026-08-27): `core.quotePath=false` 라도 탭이 든 이름은 **양쪽 다** 같은 꼴로 quote 된다
    // (`"tab\there.txt"`). 그래서 경로 대조가 성립한다 — 한쪽만 quote 되면 그 줄의 증감이 조용히 빈다.
    var it = iterateCommitFiles(
        ":100644 100644 587be6b 2795c87 M\tsp ace/b b.txt\n" ++
            ":000000 100644 0000000 72e24ec A\t\"tab\\there.txt\"\n" ++
            "2\t1\tsp ace/b b.txt\n" ++
            "1\t0\t\"tab\\there.txt\"\n",
    );
    const spaced = it.next().?;
    try testing.expectEqualStrings("sp ace/b b.txt", spaced.path);
    try testing.expect(spaced.has_delta);
    try testing.expectEqual(@as(u32, 2), spaced.added);
    const quoted = it.next().?;
    try testing.expectEqualStrings("\"tab\\there.txt\"", quoted.path);
    try testing.expect(quoted.has_delta);
    try testing.expect(it.next() == null);
}

test "커밋 파일 목록: name-status 만 온 출력도 그대로 흐른다" {
    // 옛 형식(또는 numstat 이 빠진 출력)에서 목록이 사라지면 안 된다 — 증감만 비운다.
    var it = iterateCommitFiles("M\tsrc/main.zig\nA\tnew.txt\n");
    const first = it.next().?;
    try testing.expectEqualStrings("src/main.zig", first.path);
    try testing.expect(!first.has_delta);
    try testing.expectEqualStrings("new.txt", it.next().?.path);
    try testing.expect(it.next() == null);
}

test "충돌은 두 축 모두 unmerged로 오고, 하위 모듈은 표시된다(실측 출력)" {
    // 실제 `git merge` 충돌과 `git submodule add`에서 뜬 출력을 그대로 쓴다.
    const conflict_line = "u UU N... 100644 100644 100644 100644 c0d0fb4 f563088 19ec3b0 f.txt\n";
    var it = iterate(conflict_line);
    const conflicted = it.next().?;
    try std.testing.expect(conflicted.isConflicted());
    // 충돌은 스테이지 여부의 문제가 아니라 **해결되지 않은 상태**라 두 축 모두 `unmerged`로 온다.
    try std.testing.expectEqual(Change.unmerged, conflicted.staged);
    try std.testing.expectEqual(Change.unmerged, conflicted.worktree);
    try std.testing.expect(!conflicted.isUntracked());

    const submodule_line = "1 AM S.M. 000000 160000 160000 0000000 0b4a6aa vendor\n";
    var sub_it = iterate(submodule_line);
    const sub = sub_it.next().?;
    try std.testing.expect(sub.submodule);
    try std.testing.expectEqualStrings("vendor", sub.path);

    // 일반 파일은 하위 모듈로 오인되지 않는다.
    var plain_it = iterate("1 .M N... 100644 100644 100644 aaa bbb src/main.zig\n");
    try std.testing.expect(!plain_it.next().?.submodule);
}

test "unborn 저장소도 브랜치 이름을 읽는다(oid가 (initial))" {
    // 첫 커밋 전 저장소의 실제 출력. 여기서 막히면 새 저장소에서 헤더가 비어 보인다.
    const head = parseHead("# branch.oid (initial)\n# branch.head main\n? a.txt\n");
    try std.testing.expectEqualStrings("main", head.branch.?);
    try std.testing.expect(!head.has_ab); // upstream이 없으니 ahead/behind도 없다
    // **unborn을 값으로 말한다**: 이 상태에서는 `git diff … HEAD`가 실패하므로(실측 exit 128) 목록이 증감을
    // index 기준 명령에서 얻어야 한다. "출력이 비었다"로 그 판단을 대신하면 평범한 저장소의 실패까지 같은
    // 폴백을 타서, 다른 범위의 숫자를 HEAD 범위인 척 보여 준다.
    try std.testing.expect(head.unborn);
    // 커밋이 하나라도 있으면 그 자리에 해시가 온다 — 폴백을 타면 안 된다.
    try std.testing.expect(!parseHead("# branch.oid 995e148\n# branch.head main\n").unborn);
}

// `check-ignore --stdin -z` 는 무시된 경로만, 입력 순서대로, NUL 로 끝나 돌아온다. 경로에 공백·개행이
// 있어도 갈리지 않는 것이 `-z` 를 쓰는 이유다.
test "기본 브랜치 대비 ahead/behind: 왼쪽이 behind, 오른쪽이 ahead다" {
    // 실측 형식(2026-08-18): `git rev-list --count --left-right origin/HEAD...HEAD` → "0\t1"
    // (이 저장소의 작업 브랜치가 main보다 1 앞섰을 때). 두 값을 뒤집으면 화면이 "받을 것이 있다"를
    // "보낼 것이 있다"로 말한다 — 색까지 갈리므로 조용히 틀리지 않는다.
    const got = parseAheadBehind("0\t1\n") orelse return error.MissingAheadBehind;
    try testing.expectEqual(@as(u32, 1), got.ahead);
    try testing.expectEqual(@as(u32, 0), got.behind);

    const both = parseAheadBehind("3\t7") orelse return error.MissingAheadBehind;
    try testing.expectEqual(@as(u32, 7), both.ahead);
    try testing.expectEqual(@as(u32, 3), both.behind);

    // 공백 구분도 받는다(형식이 흔들려도 숫자 둘이 순서대로 오는 것이 계약이다).
    const spaced = parseAheadBehind("2 5\n") orelse return error.MissingAheadBehind;
    try testing.expectEqual(@as(u32, 5), spaced.ahead);
    try testing.expectEqual(@as(u32, 2), spaced.behind);

    // **어긋나면 null이다** — 0으로 뭉개면 "차이 없음"이라는 틀린 진술이 된다(호출자는 그때 `@{u}`로 돌아간다).
    try testing.expect(parseAheadBehind("") == null);
    try testing.expect(parseAheadBehind("\n") == null);
    try testing.expect(parseAheadBehind("0") == null); // 한 값만
    try testing.expect(parseAheadBehind("0\t1\t2") == null); // 셋
    try testing.expect(parseAheadBehind("a\tb") == null);
    try testing.expect(parseAheadBehind("-1\t2") == null); // 음수는 이 명령의 출력이 아니다
    try testing.expect(parseAheadBehind("fatal: ambiguous argument") == null);
}

test "check-ignore -z 출력에서 무시된 경로만 꺼낸다(공백·개행 포함 경로 보존)" {
    var it = iterateIgnored("node_modules\x00build/out put\x00weird\nname.log\x00");
    try std.testing.expectEqualStrings("node_modules", it.next().?);
    try std.testing.expectEqualStrings("build/out put", it.next().?);
    try std.testing.expectEqualStrings("weird\nname.log", it.next().?);
    try std.testing.expect(it.next() == null);

    // 빈 출력(무시된 것 없음)과 꼬리 NUL 만 있는 출력 모두 항목이 없다.
    var empty = iterateIgnored("");
    try std.testing.expect(empty.next() == null);
    var tail = iterateIgnored("\x00\x00");
    try std.testing.expect(tail.next() == null);
}
