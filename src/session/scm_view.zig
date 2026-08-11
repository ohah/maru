//! 도크 소스 컨트롤 뷰의 **행 모델**(L2 순수, docs/editor-surface-dock.md §3.5).
//!
//! git 출력 세 덩어리(status·staged numstat·worktree numstat)를 받아 화면에 그릴 행 목록을 만든다. 렌더는 이 결과를
//! 글자로 옮기기만 한다 — 어느 섹션에 무엇이 몇 개 드는지, 증감이 얼마인지를 결정하는 곳은 여기 하나다.
//!
//! **할당하지 않는다.** 행은 입력 텍스트를 가리키는 슬라이스와 숫자뿐이고, 호출자가 준 `out` 배열에 채운다.
//! rename 경로 복원만 scratch 버퍼를 쓴다(numstat이 `A => B` 한 필드로 적어 status 경로와 다르기 때문 — git_status 참고).

const std = @import("std");
const git_status = @import("git_status.zig");

/// 섹션 개수 — 접힘·펼침 상태 배열의 길이 계약이다(세션이 같은 크기로 들고 있는다).
pub const section_count = 5;

/// 한 섹션이 기본으로 보여 주는 파일 행 수. 변경이 수백 개인 저장소에서 한 섹션이 화면을 다 먹으면 나머지
/// 섹션이 스크롤 저 아래로 밀려 **있는지조차 모르게** 된다(스크롤이 있어도 마찬가지다 — 첫 화면이 전부다).
/// 이 값을 넘으면 "모두 보기"를 내고, 사용자가 그 섹션만 편다.
pub const default_section_rows: usize = 10;

pub const Section = enum {
    staged,
    unstaged,
    untracked,
    /// 기본 브랜치와 갈린 뒤 이 브랜치의 **커밋들이** 바꾼 것(docs/editor-surface-dock.md §3.5). 위 셋이 "아직 커밋
    /// 안 한 것"이라면 이 섹션은 "이미 커밋한 것"이라 리뷰 단위가 다르다.
    branch,
    /// **에이전트가 마지막 턴에 바꾼 것**(§6.1). git 기준이 아니라 턴 경계 스냅샷 기준이라 위 넷과 축이 다르다 —
    /// 스테이지 여부·커밋 여부와 무관하게 "방금 무슨 일이 있었나"를 답한다.
    turn,

    /// 섹션 제목. 목업의 문구를 그대로 쓴다.
    pub fn title(self: Section) []const u8 {
        return switch (self) {
            .staged => "스테이지된 변경",
            .unstaged => "변경 사항",
            .untracked => "추적되지 않은 파일",
            .branch => "브랜치에 COMMIT 됨",
            .turn => "에이전트가 방금 바꾼 것",
        };
    }
};

pub const FileRow = struct {
    section: Section,
    path: []const u8,
    /// rename/copy의 원래 경로(그 외 null). 목록은 새 경로를 보여 주고 원래 경로는 보조 정보다.
    orig_path: ?[]const u8 = null,
    /// 행 오른쪽 끝 상태 문자.
    letter: u8,
    added: u32 = 0,
    removed: u32 = 0,
    /// numstat이 `-`를 준 파일. 숫자 대신 그 사실을 표시한다 — **0/0으로 거짓 표시하지 않는다.**
    binary: bool = false,
    /// 증감을 못 붙였다(numstat에 없거나 rename 경로 복원 실패). 숫자 자리를 비운다.
    unknown_delta: bool = false,
    /// 병합 충돌 중(해결 전). diff는 `HEAD ↔ 작업트리`로 열어 충돌 표시를 그대로 보여 준다.
    conflicted: bool = false,
    /// 하위 모듈(gitlink). **텍스트 비교가 없다** — 열면 빈 화면이 되므로 호출자가 그 사실을 말한다.
    submodule: bool = false,
};

pub const Row = union(enum) {
    section: struct { section: Section, count: usize },
    file: FileRow,
    /// "모두 보기" 행 — 그 섹션에 **아직 안 보여 준 파일이 몇 개인지** 말한다. 누르면 그 섹션만 전부 편다.
    /// 이 행이 없으면 목록이 조용히 잘려, 사용자는 자기가 바꾼 파일이 없어졌다고 읽는다.
    more: struct { section: Section, hidden: usize },
};

pub const Model = struct {
    head: git_status.Head,
    rows: []const Row,
    /// 변경이 하나도 없다(섹션 헤더도 안 낸다 — 빈 안내를 대신 그린다).
    empty: bool,
};

/// 세 출력에서 행 목록을 만든다. **개수가 0인 섹션은 헤더도 내지 않는다**(빈 헤더가 컬럼 위쪽을 잡아먹지 않게).
/// `out`이 모자라면 거기서 자른다 — 화면에 안 들어가는 행을 만들 이유가 없다.
pub fn build(
    status_text: []const u8,
    staged_numstat: []const u8,
    worktree_numstat: []const u8,
    /// `git diff --name-status origin/HEAD...HEAD` 출력. **빈 문자열이면 그 섹션을 아예 내지 않는다** —
    /// 기준(origin/HEAD)을 못 잡는 저장소에서는 오류가 아니라 "그 섹션이 없는 것"이다(§3.5).
    branch_name_status: []const u8,
    branch_numstat: []const u8,
    /// 마지막 턴 스냅샷 이후 바뀐 것(§6.1). 스냅샷이 없으면 빈 문자열이고 그 섹션은 안 나온다.
    turn_name_status: []const u8,
    turn_numstat: []const u8,
    /// 접힌 섹션(Section 순서). 접혀 있으면 헤더만 내고 파일 행은 만들지 않는다 — **화면에 있는 것과 이 목록이
    /// 같아야** 클릭 좌표가 그린 자리와 어긋나지 않는다.
    collapsed: [section_count]bool,
    /// 그 섹션을 **전부** 보여 줄지(사용자가 "모두 보기"를 누른 상태). 안 눌렀으면 `default_section_rows`까지만.
    expanded: [section_count]bool,
    out: []Row,
    scratch: []u8,
) Model {
    var n: usize = 0;
    inline for (.{ Section.staged, Section.unstaged, Section.untracked }) |section| {
        const count = countFor(status_text, section);
        if (count > 0 and n < out.len) {
            out[n] = .{ .section = .{ .section = section, .count = count } };
            n += 1;
            var it = git_status.iterate(status_text);
            var shown: usize = 0;
            const limit = if (expanded[@intFromEnum(section)]) count else @min(count, default_section_rows);
            // 접힌 섹션은 헤더만 낸다(반복문을 아예 안 돈다 — inline for 안이라 continue를 쓰지 않는다).
            while (!collapsed[@intFromEnum(section)]) {
                if (shown >= limit) break;
                const entry = it.next() orelse break;
                if (n >= out.len) break;
                if (!belongs(entry, section)) continue;
                const change = switch (section) {
                    .staged => entry.staged,
                    // branch는 이 루프에 들어오지 않는다(belongs가 false) — exhaustiveness를 위해 같이 적는다.
                    .unstaged, .untracked, .branch, .turn => entry.worktree,
                };
                var row: FileRow = .{
                    .section = section,
                    .path = entry.path,
                    .orig_path = entry.orig_path,
                    .letter = change.letter(),
                    .conflicted = entry.isConflicted(),
                    .submodule = entry.submodule,
                };
                // 추적되지 않은 파일은 비교 대상이 없어 증감이 존재하지 않는다 — 숫자 자리를 비운다.
                // **충돌도 마찬가지다**: numstat이 같은 경로에 여러 줄(스테이지별)을 내는데 그 첫 줄이 `0 0`이라
                // 그대로 쓰면 "안 바뀐 파일"로 보인다(실측). 하위 모듈은 커밋 포인터라 줄 수가 의미가 없다.
                if (section == .untracked or entry.isConflicted() or entry.submodule) {
                    row.unknown_delta = true;
                } else {
                    const numstat = if (section == .staged) staged_numstat else worktree_numstat;
                    if (findDelta(numstat, entry.path, scratch)) |d| {
                        row.added = d.added;
                        row.removed = d.removed;
                        row.binary = d.binary;
                    } else row.unknown_delta = true;
                }
                out[n] = .{ .file = row };
                n += 1;
                shown += 1;
            }
            // 남은 게 있으면 그 사실을 행으로 말한다(조용히 자르지 않는다).
            if (!collapsed[@intFromEnum(section)] and shown < count and n < out.len) {
                out[n] = .{ .more = .{ .section = section, .hidden = count - shown } };
                n += 1;
            }
        }
    }
    // ── 브랜치에 COMMIT 됨 / 에이전트가 방금 바꾼 것. 둘 다 `--name-status` 범위라 같은 규칙을 공유한다
    // (섹션마다 코드를 따로 두면 접힘·상한·rename 처리가 갈린다).
    n = appendRangeSection(.branch, branch_name_status, branch_numstat, collapsed, expanded, out, scratch, n);
    n = appendRangeSection(.turn, turn_name_status, turn_numstat, collapsed, expanded, out, scratch, n);
    return .{ .head = git_status.parseHead(status_text), .rows = out[0..n], .empty = n == 0 };
}

/// `--name-status` 출력 하나를 섹션으로 만든다(브랜치·턴이 공유 — 입력만 다르고 규칙은 같다).
fn appendRangeSection(
    section: Section,
    name_status: []const u8,
    numstat: []const u8,
    collapsed: [section_count]bool,
    expanded: [section_count]bool,
    out: []Row,
    scratch: []u8,
    start: usize,
) usize {
    var n = start;
    const count = countNameStatus(name_status);
    if (count == 0 or n >= out.len) return n;
    out[n] = .{ .section = .{ .section = section, .count = count } };
    n += 1;
    var it = git_status.iterateNameStatus(name_status);
    var shown: usize = 0;
    const limit = if (expanded[@intFromEnum(section)]) count else @min(count, default_section_rows);
    while (!collapsed[@intFromEnum(section)]) {
        if (shown >= limit) break;
        const entry = it.next() orelse break;
        if (n >= out.len) break;
        var row: FileRow = .{
            .section = section,
            .path = entry.path,
            .orig_path = entry.orig_path,
            .letter = entry.letter,
        };
        if (findDelta(numstat, entry.path, scratch)) |d| {
            row.added = d.added;
            row.removed = d.removed;
            row.binary = d.binary;
        } else row.unknown_delta = true;
        out[n] = .{ .file = row };
        n += 1;
        shown += 1;
    }
    if (!collapsed[@intFromEnum(section)] and shown < count and n < out.len) {
        out[n] = .{ .more = .{ .section = section, .hidden = count - shown } };
        n += 1;
    }
    return n;
}

fn countNameStatus(text: []const u8) usize {
    var it = git_status.iterateNameStatus(text);
    var count: usize = 0;
    while (it.next()) |_| count += 1;
    return count;
}

fn belongs(entry: git_status.Entry, section: Section) bool {
    return switch (section) {
        .staged => entry.isStaged(),
        .unstaged => entry.isUnstaged(),
        .untracked => entry.isUntracked(),
        // 브랜치·턴 섹션은 porcelain 상태가 아니라 **범위**에서 온다 — 이 술어의 대상이 아니다.
        .branch, .turn => false,
    };
}

fn countFor(status_text: []const u8, section: Section) usize {
    var it = git_status.iterate(status_text);
    var count: usize = 0;
    while (it.next()) |entry| {
        if (belongs(entry, section)) count += 1;
    }
    return count;
}

/// numstat에서 그 경로의 증감을 찾는다. rename은 numstat 경로가 status 경로와 달라(`A => B`) 복원해 대조한다.
fn findDelta(numstat: []const u8, path: []const u8, scratch: []u8) ?git_status.LineDelta {
    var it = git_status.iterateNumstat(numstat);
    while (it.next()) |delta| {
        const candidate = delta.newPath(scratch) orelse continue; // 버퍼 부족 → 그 행만 건너뛴다
        if (std.mem.eql(u8, candidate, path)) return delta;
    }
    return null;
}

const testing = std.testing;

// git_status와 같은 실측 캡처를 쓴다(같은 저장소·같은 실행).
const fixture_status =
    "# branch.oid 995e148\n" ++
    "# branch.head main\n" ++
    "1 A. N... 000000 100644 100644 0 88768ef blob.bin\n" ++
    "1 MM N... 100644 100644 100644 422c2b7 7be73ce keep.txt\n" ++
    "2 R. N... 100644 100644 100644 587be6b 587be6b R100 renamed.txt\tgone.txt\n" ++
    "? untracked.txt\n";
const fixture_staged = "-\t-\tblob.bin\n2\t1\tkeep.txt\n0\t0\tgone.txt => renamed.txt\n";
const fixture_worktree = "1\t0\tkeep.txt\n";

test "섹션·개수·증감이 실측 출력에서 그대로 나온다" {
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(fixture_status, fixture_staged, fixture_worktree, "", "", "", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expect(!model.empty);
    try testing.expectEqualStrings("main", model.head.branch.?);

    // 스테이지된 변경 3개(blob.bin·keep.txt·renamed.txt) → 헤더 + 파일 3행
    try testing.expectEqual(Section.staged, model.rows[0].section.section);
    try testing.expectEqual(@as(usize, 3), model.rows[0].section.count);
    try testing.expect(model.rows[1].file.binary); // blob.bin — 0/0이 아니라 binary
    try testing.expectEqual(@as(u8, 'A'), model.rows[1].file.letter);
    try testing.expectEqual(@as(u32, 2), model.rows[2].file.added); // keep.txt
    // rename은 numstat 경로가 `gone.txt => renamed.txt`라 복원해야 붙는다.
    try testing.expectEqualStrings("renamed.txt", model.rows[3].file.path);
    try testing.expect(!model.rows[3].file.unknown_delta);
    try testing.expectEqualStrings("gone.txt", model.rows[3].file.orig_path.?);

    // 변경 사항(index↔worktree)에는 keep.txt만 — **같은 파일이 두 섹션에 든다**(MM).
    try testing.expectEqual(Section.unstaged, model.rows[4].section.section);
    try testing.expectEqual(@as(usize, 1), model.rows[4].section.count);
    try testing.expectEqualStrings("keep.txt", model.rows[5].file.path);
    try testing.expectEqual(@as(u32, 1), model.rows[5].file.added);

    // 추적되지 않은 파일은 비교 대상이 없어 숫자를 비운다.
    try testing.expectEqual(Section.untracked, model.rows[6].section.section);
    try testing.expect(model.rows[7].file.unknown_delta);
    try testing.expectEqual(@as(u8, 'U'), model.rows[7].file.letter);
    try testing.expectEqual(@as(usize, 8), model.rows.len);
}

test "개수가 0인 섹션은 헤더도 내지 않는다" {
    var out: [16]Row = undefined;
    var scratch: [64]u8 = undefined;
    const model = build("# branch.head main\n? only.txt\n", "", "", "", "", "", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(@as(usize, 2), model.rows.len); // 추적되지 않은 파일 헤더 + 1행뿐
    try testing.expectEqual(Section.untracked, model.rows[0].section.section);
}

test "변경이 없으면 empty다(빈 안내를 대신 그린다)" {
    var out: [8]Row = undefined;
    var scratch: [64]u8 = undefined;
    const model = build("# branch.head main\n", "", "", "", "", "", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expect(model.empty);
    try testing.expectEqual(@as(usize, 0), model.rows.len);
    try testing.expectEqualStrings("main", model.head.branch.?);
}

test "out이 모자라면 거기서 자른다(화면 밖 행을 만들지 않는다)" {
    var out: [2]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(fixture_status, fixture_staged, fixture_worktree, "", "", "", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(@as(usize, 2), model.rows.len);
    try testing.expectEqual(Section.staged, model.rows[0].section.section);
}

test "numstat에 없는 파일은 숫자를 비운다(0으로 채우지 않는다)" {
    var out: [8]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build("1 .M N... 1 2 3 a b lonely.txt\n", "", "", "", "", "", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expect(model.rows[1].file.unknown_delta);
    try testing.expectEqual(@as(u32, 0), model.rows[1].file.added);
}

test "접힌 섹션은 헤더만 내고 개수는 그대로 보여 준다" {
    var staged_collapsed = [_]bool{false} ** section_count;
    staged_collapsed[@intFromEnum(Section.staged)] = true;
    // 접혀도 개수는 남아야 "몇 개가 숨어 있는지"를 알 수 있다. 파일 행이 없어야 클릭 좌표가 어긋나지 않는다.
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(fixture_status, fixture_staged, fixture_worktree, "", "", "", "", staged_collapsed, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(Section.staged, model.rows[0].section.section);
    try testing.expectEqual(@as(usize, 3), model.rows[0].section.count); // 개수는 접혀도 그대로
    try testing.expectEqual(Section.unstaged, model.rows[1].section.section); // 바로 다음 섹션이 온다
    // 전부 접으면 헤더 3줄만 남는다.
    const all = build(fixture_status, fixture_staged, fixture_worktree, "", "", "", "", .{true} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(@as(usize, 3), all.rows.len);
    try testing.expect(!all.empty); // 변경이 없는 것과 접은 것은 다르다
}

test "브랜치 섹션은 커밋 범위에서 오고, 기준이 없으면 아예 안 나온다" {
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const name_status = "M\tsrc/main.zig\nA\tdocs/new.md\n";
    const numstat = "4\t2\tsrc/main.zig\n10\t0\tdocs/new.md\n";
    const model = build("# branch.head main\n", "", "", name_status, numstat, "", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(Section.branch, model.rows[0].section.section);
    try testing.expectEqual(@as(usize, 2), model.rows[0].section.count);
    try testing.expectEqualStrings("src/main.zig", model.rows[1].file.path);
    try testing.expectEqual(@as(u32, 4), model.rows[1].file.added); // 같은 범위의 증감이 붙는다
    try testing.expectEqual(@as(u32, 0), model.rows[2].file.removed);

    // **기준을 못 잡으면 그 섹션만 없다**(오류가 아니다 — origin/HEAD 없는 로컬 저장소).
    const without = build("# branch.head main\n", "", "", "", "", "", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expect(without.empty);
}

test "브랜치 섹션도 접힌다(개수는 남는다)" {
    var branch_collapsed = [_]bool{false} ** section_count;
    branch_collapsed[@intFromEnum(Section.branch)] = true;
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(
        "# branch.head main\n",
        "",
        "",
        "M\ta.txt\nM\tb.txt\n",
        "",
        "",
        "",
        branch_collapsed,
        .{true} ** section_count,
        &out,
        &scratch,
    );
    try testing.expectEqual(@as(usize, 1), model.rows.len);
    try testing.expectEqual(@as(usize, 2), model.rows[0].section.count);
}

test "충돌·하위 모듈은 숫자를 비운다(거짓 0으로 안 바뀐 것처럼 보이지 않게)" {
    var out: [16]Row = undefined;
    var scratch: [256]u8 = undefined;
    // 실측: 충돌 파일은 numstat이 같은 경로에 두 줄을 내고 첫 줄이 `0 0`이다.
    const status = "# branch.head main\n" ++
        "u UU N... 100644 100644 100644 100644 aaa bbb ccc f.txt\n" ++
        "1 AM S.M. 000000 160000 160000 000 0b4 vendor\n";
    const numstat = "0\t0\tf.txt\n4\t0\tf.txt\n1\t0\tvendor\n";
    const model = build(status, numstat, numstat, "", "", "", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);

    // 충돌은 **변경 사항 섹션에만** 든다(스테이지된 변경에 같은 파일이 또 뜨면 MM과 구분이 안 된다).
    var conflicted_sections: [2]bool = .{ false, false };
    for (model.rows) |row| switch (row) {
        .file => |f| if (f.conflicted) {
            if (f.section == .staged) conflicted_sections[0] = true;
            if (f.section == .unstaged) conflicted_sections[1] = true;
            try testing.expect(f.unknown_delta); // `+0 -0`을 쓰지 않는다
            try testing.expectEqual(@as(u8, 'U'), f.letter);
        },
        .section, .more => {},
    };
    try testing.expect(!conflicted_sections[0]);
    try testing.expect(conflicted_sections[1]);

    // 하위 모듈은 스테이지 쪽 A로 잡히고 숫자를 안 붙인다.
    var found_submodule = false;
    for (model.rows) |row| switch (row) {
        .file => |f| if (f.submodule) {
            found_submodule = true;
            try testing.expect(f.unknown_delta);
        },
        .section, .more => {},
    };
    try testing.expect(found_submodule);
}

test "섹션은 기본 상한까지만 보여 주고 남은 개수를 말한다" {
    // 변경이 수백 개면 한 섹션이 첫 화면을 다 먹어 나머지 섹션이 있는지도 모르게 된다. 그래서 상한을 두되
    // **잘렸다는 사실을 행으로 말한다** — 조용히 자르면 사용자는 자기 파일이 없어졌다고 읽는다.
    var status: std.ArrayList(u8) = .empty;
    defer status.deinit(testing.allocator);
    try status.appendSlice(testing.allocator, "# branch.head main\n");
    for (0..25) |i| {
        var line: [64]u8 = undefined;
        try status.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "1 .M N... 1 2 3 a b f{d}.txt\n", .{i}));
    }

    var out: [64]Row = undefined;
    var scratch: [256]u8 = undefined;
    const capped = build(status.items, "", "", "", "", "", "", .{false} ** section_count, .{false} ** section_count, &out, &scratch);
    // 헤더 + 상한만큼의 파일 + "모두 보기" 한 줄.
    try testing.expectEqual(default_section_rows + 2, capped.rows.len);
    try testing.expectEqual(@as(usize, 25), capped.rows[0].section.count); // 개수는 전체를 말한다
    const more = capped.rows[capped.rows.len - 1].more;
    try testing.expectEqual(Section.unstaged, more.section);
    try testing.expectEqual(@as(usize, 25 - default_section_rows), more.hidden);

    // "모두 보기"를 누른 뒤에는 전부 나오고 그 행은 사라진다.
    var expanded = [_]bool{false} ** section_count;
    expanded[@intFromEnum(Section.unstaged)] = true;
    const full = build(status.items, "", "", "", "", "", "", .{false} ** section_count, expanded, &out, &scratch);
    try testing.expectEqual(@as(usize, 26), full.rows.len); // 헤더 + 25
    for (full.rows[1..]) |row| try testing.expect(row == .file);
}

test "상한 안이면 '모두 보기'를 내지 않는다(누를 게 없는 행을 만들지 않는다)" {
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(fixture_status, fixture_staged, fixture_worktree, "", "", "", "", .{false} ** section_count, .{false} ** section_count, &out, &scratch);
    for (model.rows) |row| try testing.expect(row != .more);
}

test "턴 섹션은 스냅샷 범위에서 오고, 스냅샷이 없으면 안 나온다" {
    // 이 섹션은 git 기준이 아니라 **턴 경계 스냅샷** 기준이라(§6.1) 다른 넷과 축이 다르다 — 스테이지·커밋 여부와
    // 무관하게 "방금 무슨 일이 있었나"를 답한다.
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const turn_status = "M\tsrc/main.zig\nA\tnotes.md\n";
    const turn_numstat = "7\t2\tsrc/main.zig\n3\t0\tnotes.md\n";
    const model = build(
        "# branch.head main\n",
        "",
        "",
        "",
        "",
        turn_status,
        turn_numstat,
        .{false} ** section_count,
        .{true} ** section_count,
        &out,
        &scratch,
    );
    try testing.expectEqual(Section.turn, model.rows[0].section.section);
    try testing.expectEqual(@as(usize, 2), model.rows[0].section.count);
    try testing.expectEqualStrings("src/main.zig", model.rows[1].file.path);
    try testing.expectEqual(@as(u32, 7), model.rows[1].file.added);

    // 스냅샷이 없으면(턴이 아직 안 끝났거나 저장소가 바뀌었으면) 그 섹션 자체가 없다 — 빈 헤더를 남기지 않는다.
    const without = build(
        "# branch.head main\n",
        "",
        "",
        "",
        "",
        "",
        "",
        .{false} ** section_count,
        .{true} ** section_count,
        &out,
        &scratch,
    );
    try testing.expect(without.empty);
}

test "턴 섹션도 다른 섹션과 같은 규칙을 쓴다(접힘·상한·rename)" {
    var out: [64]Row = undefined;
    var scratch: [256]u8 = undefined;
    var status: std.ArrayList(u8) = .empty;
    defer status.deinit(testing.allocator);
    for (0..15) |i| {
        var line: [64]u8 = undefined;
        try status.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "M\tf{d}.txt\n", .{i}));
    }

    // 상한을 넘으면 "모두 보기"가 나온다(브랜치·상태 섹션과 같은 코드를 공유하므로 규칙이 갈리지 않는다).
    const capped = build("# branch.head main\n", "", "", "", "", status.items, "", .{false} ** section_count, .{false} ** section_count, &out, &scratch);
    try testing.expectEqual(default_section_rows + 2, capped.rows.len);
    try testing.expectEqual(Section.turn, capped.rows[capped.rows.len - 1].more.section);

    // rename의 옛 경로도 그대로 실린다.
    const renamed = build("# branch.head main\n", "", "", "", "", "R100\told.txt\tnew.txt\n", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqualStrings("new.txt", renamed.rows[1].file.path);
    try testing.expectEqualStrings("old.txt", renamed.rows[1].file.orig_path.?);
}
