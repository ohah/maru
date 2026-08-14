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
            if (line.len < 3) continue;

            // `R100\told\tnew` / `M\tpath`. 상태 뒤 숫자(유사도)는 무시한다 — 표시에 쓰지 않는다.
            const first_tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            const letter = line[0];
            const rest = line[first_tab + 1 ..];
            if (letter == 'R' or letter == 'C') {
                const sep = std.mem.indexOfScalar(u8, rest, '\t') orelse continue;
                // 옛 경로가 비어 있으면 그 줄은 못 믿는다(잘린 출력).
                if (sep == 0 or sep + 1 >= rest.len) continue;
                return .{ .letter = letter, .path = rest[sep + 1 ..], .orig_path = rest[0..sep] };
            }
            if (rest.len == 0) continue;
            return .{ .letter = letter, .path = rest };
        }
        return null;
    }
};

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
