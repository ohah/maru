//! 도크 소스 컨트롤 뷰의 **행 모델**(L2 순수, docs/editor-surface.md §3.5).
//!
//! git 출력 세 덩어리(status·staged numstat·worktree numstat)를 받아 화면에 그릴 행 목록을 만든다. 렌더는 이 결과를
//! 글자로 옮기기만 한다 — 어느 섹션에 무엇이 몇 개 드는지, 증감이 얼마인지를 결정하는 곳은 여기 하나다.
//!
//! **할당하지 않는다.** 행은 입력 텍스트를 가리키는 슬라이스와 숫자뿐이고, 호출자가 준 `out` 배열에 채운다.
//! rename 경로 복원만 scratch 버퍼를 쓴다(numstat이 `A => B` 한 필드로 적어 status 경로와 다르기 때문 — git_status 참고).

const std = @import("std");
const git_status = @import("git_status.zig");

/// 섹션 개수 — 접힘 상태 배열의 길이 계약이다(세션이 같은 크기로 들고 있는다).
pub const section_count = 4;

pub const Section = enum {
    staged,
    unstaged,
    untracked,
    /// 기본 브랜치와 갈린 뒤 이 브랜치의 **커밋들이** 바꾼 것(docs/editor-surface.md §3.5). 위 셋이 "아직 커밋
    /// 안 한 것"이라면 이 섹션은 "이미 커밋한 것"이라 리뷰 단위가 다르다.
    branch,

    /// 섹션 제목. 목업의 문구를 그대로 쓴다.
    pub fn title(self: Section) []const u8 {
        return switch (self) {
            .staged => "스테이지된 변경",
            .unstaged => "변경 사항",
            .untracked => "추적되지 않은 파일",
            .branch => "브랜치에 COMMIT 됨",
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
};

pub const Row = union(enum) {
    section: struct { section: Section, count: usize },
    file: FileRow,
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
    /// 접힌 섹션(Section 순서). 접혀 있으면 헤더만 내고 파일 행은 만들지 않는다 — **화면에 있는 것과 이 목록이
    /// 같아야** 클릭 좌표가 그린 자리와 어긋나지 않는다.
    collapsed: [section_count]bool,
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
            // 접힌 섹션은 헤더만 낸다(반복문을 아예 안 돈다 — inline for 안이라 continue를 쓰지 않는다).
            while (!collapsed[@intFromEnum(section)]) {
                const entry = it.next() orelse break;
                if (n >= out.len) break;
                if (!belongs(entry, section)) continue;
                const change = switch (section) {
                    .staged => entry.staged,
                    // branch는 이 루프에 들어오지 않는다(belongs가 false) — exhaustiveness를 위해 같이 적는다.
                    .unstaged, .untracked, .branch => entry.worktree,
                };
                var row: FileRow = .{
                    .section = section,
                    .path = entry.path,
                    .orig_path = entry.orig_path,
                    .letter = change.letter(),
                };
                // 추적되지 않은 파일은 비교 대상이 없어 증감이 존재하지 않는다 — 숫자 자리를 비운다.
                if (section == .untracked) {
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
            }
        }
    }
    // ── 브랜치에 COMMIT 됨. 위 셋과 입력이 달라(커밋 범위) 같은 루프에 넣지 않는다.
    const branch_count = countNameStatus(branch_name_status);
    if (branch_count > 0 and n < out.len) {
        out[n] = .{ .section = .{ .section = .branch, .count = branch_count } };
        n += 1;
        var it = git_status.iterateNameStatus(branch_name_status);
        while (!collapsed[@intFromEnum(Section.branch)]) {
            const entry = it.next() orelse break;
            if (n >= out.len) break;
            var row: FileRow = .{
                .section = .branch,
                .path = entry.path,
                .orig_path = entry.orig_path,
                .letter = entry.letter,
            };
            if (findDelta(branch_numstat, entry.path, scratch)) |d| {
                row.added = d.added;
                row.removed = d.removed;
                row.binary = d.binary;
            } else row.unknown_delta = true;
            out[n] = .{ .file = row };
            n += 1;
        }
    }
    return .{ .head = git_status.parseHead(status_text), .rows = out[0..n], .empty = n == 0 };
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
        // 브랜치 섹션은 porcelain 상태가 아니라 **커밋 범위**에서 온다 — 이 술어의 대상이 아니다.
        .branch => false,
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
    const model = build(fixture_status, fixture_staged, fixture_worktree, "", "", .{ false, false, false, false }, &out, &scratch);
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
    const model = build("# branch.head main\n? only.txt\n", "", "", "", "", .{ false, false, false, false }, &out, &scratch);
    try testing.expectEqual(@as(usize, 2), model.rows.len); // 추적되지 않은 파일 헤더 + 1행뿐
    try testing.expectEqual(Section.untracked, model.rows[0].section.section);
}

test "변경이 없으면 empty다(빈 안내를 대신 그린다)" {
    var out: [8]Row = undefined;
    var scratch: [64]u8 = undefined;
    const model = build("# branch.head main\n", "", "", "", "", .{ false, false, false, false }, &out, &scratch);
    try testing.expect(model.empty);
    try testing.expectEqual(@as(usize, 0), model.rows.len);
    try testing.expectEqualStrings("main", model.head.branch.?);
}

test "out이 모자라면 거기서 자른다(화면 밖 행을 만들지 않는다)" {
    var out: [2]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(fixture_status, fixture_staged, fixture_worktree, "", "", .{ false, false, false, false }, &out, &scratch);
    try testing.expectEqual(@as(usize, 2), model.rows.len);
    try testing.expectEqual(Section.staged, model.rows[0].section.section);
}

test "numstat에 없는 파일은 숫자를 비운다(0으로 채우지 않는다)" {
    var out: [8]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build("1 .M N... 1 2 3 a b lonely.txt\n", "", "", "", "", .{ false, false, false, false }, &out, &scratch);
    try testing.expect(model.rows[1].file.unknown_delta);
    try testing.expectEqual(@as(u32, 0), model.rows[1].file.added);
}

test "접힌 섹션은 헤더만 내고 개수는 그대로 보여 준다" {
    // 접혀도 개수는 남아야 "몇 개가 숨어 있는지"를 알 수 있다. 파일 행이 없어야 클릭 좌표가 어긋나지 않는다.
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(fixture_status, fixture_staged, fixture_worktree, "", "", .{ true, false, false, false }, &out, &scratch);
    try testing.expectEqual(Section.staged, model.rows[0].section.section);
    try testing.expectEqual(@as(usize, 3), model.rows[0].section.count); // 개수는 접혀도 그대로
    try testing.expectEqual(Section.unstaged, model.rows[1].section.section); // 바로 다음 섹션이 온다
    // 전부 접으면 헤더 3줄만 남는다.
    const all = build(fixture_status, fixture_staged, fixture_worktree, "", "", .{ true, true, true, true }, &out, &scratch);
    try testing.expectEqual(@as(usize, 3), all.rows.len);
    try testing.expect(!all.empty); // 변경이 없는 것과 접은 것은 다르다
}

test "브랜치 섹션은 커밋 범위에서 오고, 기준이 없으면 아예 안 나온다" {
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const name_status = "M\tsrc/main.zig\nA\tdocs/new.md\n";
    const numstat = "4\t2\tsrc/main.zig\n10\t0\tdocs/new.md\n";
    const model = build("# branch.head main\n", "", "", name_status, numstat, .{ false, false, false, false }, &out, &scratch);
    try testing.expectEqual(Section.branch, model.rows[0].section.section);
    try testing.expectEqual(@as(usize, 2), model.rows[0].section.count);
    try testing.expectEqualStrings("src/main.zig", model.rows[1].file.path);
    try testing.expectEqual(@as(u32, 4), model.rows[1].file.added); // 같은 범위의 증감이 붙는다
    try testing.expectEqual(@as(u32, 0), model.rows[2].file.removed);

    // **기준을 못 잡으면 그 섹션만 없다**(오류가 아니다 — origin/HEAD 없는 로컬 저장소).
    const without = build("# branch.head main\n", "", "", "", "", .{ false, false, false, false }, &out, &scratch);
    try testing.expect(without.empty);
}

test "브랜치 섹션도 접힌다(개수는 남는다)" {
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(
        "# branch.head main\n",
        "",
        "",
        "M\ta.txt\nM\tb.txt\n",
        "",
        .{ false, false, false, true },
        &out,
        &scratch,
    );
    try testing.expectEqual(@as(usize, 1), model.rows.len);
    try testing.expectEqual(@as(usize, 2), model.rows[0].section.count);
}
