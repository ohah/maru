//! `git status --porcelain=v2 --branch`와 `git diff --numstat` 출력의 **순수 파서**(L2, I/O 없음).
//!
//! 도크 소스 컨트롤 뷰(docs/editor-surface.md §3.5)가 그리는 네 섹션과 행의 데이터가 전부 여기서 나온다. git 실행은
//! platform adapter가 하고 이 모듈은 **바이트만** 본다 — 그래야 헤드리스로 전수 검증이 되고, 파싱 실수가 프로세스
//! 실행 코드와 섞이지 않는다.
//!
//! **할당하지 않는다.** 결과는 입력 텍스트를 가리키는 슬라이스이고 호출자가 텍스트 수명을 소유한다(agent_observer와
//! 같은 규율). 목록이 커도 파서가 메모리를 늘리지 않으므로 상한은 호출자가 읽어 온 바이트로 이미 정해져 있다.
//!
//! **베이스**: git의 `--porcelain=v2` 포맷(git 공식 문서 `git-status(1)` "Porcelain Format Version 2")과 `--numstat`.
//! v1이 아니라 v2를 쓰는 이유는 ⑴ staged/worktree 상태가 `XY` 두 칸으로 분리돼 섹션을 뭉개지 않아도 되고,
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

    /// "스테이지된 변경" 섹션에 드는가.
    pub fn isStaged(self: Entry) bool {
        return self.staged != .unchanged and self.staged != .untracked;
    }

    /// "변경 사항"(index↔worktree) 섹션에 드는가. **한 파일이 두 섹션에 동시에 들 수 있다**(`MM`) — git이 그렇게
    /// 보고하고, 사용자도 "일부만 스테이지한 파일"을 양쪽에서 봐야 하므로 여기서 하나로 접지 않는다.
    pub fn isUnstaged(self: Entry) bool {
        return self.worktree != .unchanged and self.worktree != .untracked;
    }

    pub fn isUntracked(self: Entry) bool {
        return self.worktree == .untracked;
    }
};

/// `# branch.*` 헤더. upstream이 없으면 `upstream`/`ahead`/`behind`가 비고, 그때는 "브랜치에 COMMIT 됨" 섹션을
/// 계산할 기준이 없다(docs/editor-surface.md §3.5 — 그 섹션만 숨긴다).
pub const Head = struct {
    branch: ?[]const u8 = null,
    upstream: ?[]const u8 = null,
    ahead: u32 = 0,
    behind: u32 = 0,
    /// `# branch.head`가 `(detached)`면 참. 브랜치 이름 자리에 그 문자열이 오므로 별도로 구분한다.
    detached: bool = false,
    has_ab: bool = false,
};

pub fn parseHead(text: []const u8) Head {
    var head: Head = .{};
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, "# branch.")) continue;
        const rest = line["# branch.".len..];
        if (std.mem.startsWith(u8, rest, "head ")) {
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
                    if (!renamed) {
                        const path = lastField(line) orelse continue;
                        return .{ .staged = staged, .worktree = worktree, .path = path };
                    }
                    // `2` 레코드의 마지막 필드는 `<새 경로>\t<원래 경로>`다(경로에 공백이 있어도 탭이 가른다).
                    const field = lastField(line) orelse continue;
                    const tab = std.mem.indexOfScalar(u8, field, '\t') orelse continue;
                    return .{
                        .staged = staged,
                        .worktree = worktree,
                        .path = field[0..tab],
                        .orig_path = field[tab + 1 ..],
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
/// **0/0으로 거짓 표시하지 않는다**(docs/editor-surface.md §3.5).
pub const LineDelta = struct {
    added: u32 = 0,
    removed: u32 = 0,
    binary: bool = false,
    path: []const u8,
};

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
                return .{ .binary = true, .path = path };
            return .{
                .added = std.fmt.parseInt(u32, added, 10) catch continue,
                .removed = std.fmt.parseInt(u32, removed, 10) catch continue,
                .path = path,
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

test "실측 porcelain v2: 네 종류 레코드를 섹션 축으로 가른다" {
    var it = iterate(real_status);

    const added = it.next().?;
    try testing.expectEqualStrings("blob.bin", added.path);
    try testing.expectEqual(Change.added, added.staged);
    try testing.expectEqual(Change.unchanged, added.worktree);
    try testing.expect(added.isStaged() and !added.isUnstaged());

    // `MM` — **양쪽 섹션에 동시에 든다**(일부만 스테이지한 파일). 하나로 접지 않는 것이 계약이다.
    const both = it.next().?;
    try testing.expectEqualStrings("keep.txt", both.path);
    try testing.expect(both.isStaged() and both.isUnstaged());

    const renamed = it.next().?;
    try testing.expectEqualStrings("renamed.txt", renamed.path);
    try testing.expectEqualStrings("gone.txt", renamed.orig_path.?);
    try testing.expectEqual(Change.renamed, renamed.staged);

    const untracked = it.next().?;
    try testing.expectEqualStrings("untracked.txt", untracked.path);
    try testing.expect(untracked.isUntracked() and !untracked.isStaged());

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
