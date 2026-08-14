//! 도크 소스 컨트롤 뷰 **변경 사항 탭의 행 모델**(L2 순수, docs/editor-surface-dock.md §3.5.2).
//!
//! git 출력(status + numstat)을 받아 화면에 그릴 행 목록을 만든다. 렌더는 이 결과를 그리기만 한다 — 어느 섹션에
//! 무엇이 몇 개 드는지, 체크박스가 어떤 상태인지, 증감이 얼마인지를 결정하는 곳은 여기 하나다.
//!
//! **2판에서 축이 바뀌었다.** 초판은 "섹션 = 비교 기준"이라 `MM`(일부만 스테이지한) 파일이 두 섹션에 두 번 났다.
//! 2판은 각 행에 체크박스가 붙으므로 **파일 하나 = 행 하나**여야 한다 — 같은 파일이 두 행이면 어느 체크박스가
//! 무엇을 스테이지하는지 말할 수 없다. 그래서 섹션은 **추적 여부**만 가르고, 스테이지 여부는 행의 `stage` 상태다.
//!
//! **할당하지 않는다.** 행은 입력 텍스트를 가리키는 슬라이스와 숫자뿐이고, 호출자가 준 `out` 배열에 채운다.
//! rename 경로 복원만 scratch 버퍼를 쓴다(numstat이 `A => B` 한 필드로 적어 status 경로와 다르기 때문 — git_status 참고).

const std = @import("std");
const git_status = @import("git_status.zig");

/// 섹션 개수 — 접힘·펼침 상태 배열의 길이 계약이다(세션이 같은 크기로 들고 있는다).
pub const section_count = 2;

/// 한 섹션이 기본으로 보여 주는 파일 행 수. 변경이 수백 개인 저장소에서 한 섹션이 화면을 다 먹으면 나머지
/// 섹션이 스크롤 저 아래로 밀려 **있는지조차 모르게** 된다(스크롤이 있어도 마찬가지다 — 첫 화면이 전부다).
/// 이 값을 넘으면 "모두 보기"를 내고, 사용자가 그 섹션만 편다.
pub const default_section_rows: usize = 10;

pub const Section = enum {
    /// git이 아는 파일의 변경. 스테이지됐든 아니든 **한 행**이고, 스테이지 여부는 체크박스가 말한다.
    tracked,
    /// worktree 전용(`?` 레코드). 비교 대상이 없어 증감이 존재하지 않는다.
    untracked,

    /// 섹션 제목. 목업의 문구를 그대로 쓴다.
    pub fn title(self: Section) []const u8 {
        return switch (self) {
            .tracked => "추적됨",
            .untracked => "추적되지 않음",
        };
    }
};

/// 행 체크박스의 상태. **권위는 git index다** — 로컬에 따로 들고 있는 값이 아니라 매번 status에서 유도한다
/// (docs/editor-surface-dock.md §3.5.2). 누르는 순간의 낙관적 반영은 platform이 하고, 목록을 다시 읽으면
/// index가 답을 준다.
pub const Stage = enum {
    /// 스테이지되지 않았다(worktree 축만 변경). 추적되지 않은 파일도 여기다.
    none,
    /// 전부 스테이지됐다(staged 축만 변경).
    full,
    /// 일부만(`MM` — 두 축 모두 변경).
    partial,
    /// **체크박스를 두지 않는다.** 병합 충돌은 스테이지 여부의 문제가 아니라 해결되지 않은 상태이고, 체크박스를
    /// 두면 누르는 순간 `git add`가 돌아 충돌 표시가 든 파일이 "해결됨"으로 커밋된다(§3.5 경계 상태표).
    conflicted,

    /// 이 상태의 행이 스테이지 일괄 동작(섹션 체크박스·모두 스테이지)의 대상인가.
    pub fn stageable(self: Stage) bool {
        return self != .conflicted;
    }
};

pub const FileRow = struct {
    section: Section,
    path: []const u8,
    /// rename/copy의 원래 경로(그 외 null). 목록은 새 경로를 보여 주고 원래 경로는 보조 정보다.
    orig_path: ?[]const u8 = null,
    /// 행 왼쪽 아이콘의 상태 문자. **`HEAD → 작업트리`를 말한다** — 행의 기본 비교와 같은 방향이어야 아이콘과
    /// 열리는 diff가 어긋나지 않는다.
    letter: u8,
    stage: Stage,
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

pub const SectionRow = struct {
    section: Section,
    /// 그 섹션의 **전체** 파일 수(접혀 있어도, 잘려 있어도 전체를 말한다).
    count: usize,
    /// 섹션 체크박스. 스테이지할 수 있는 행이 하나도 없으면(전부 충돌) `null`이고 체크박스를 그리지 않는다.
    stage: ?Stage,
};

pub const Row = union(enum) {
    section: SectionRow,
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
    /// 요약 줄(`+N -N`)이 쓸 합계. **추적된 파일의 것만** 센다 — 추적되지 않은 파일은 비교 대상이 없어 숫자가 없다.
    total_added: u32 = 0,
    total_removed: u32 = 0,
    /// 커밋 버튼을 켤 수 있나 = index에 무언가 올라가 있나. 낙관적으로 추정하지 않고 status가 말한 것만 쓴다
    /// (docs/editor-surface-dock-write.md §7).
    has_staged: bool = false,
};

/// status와 numstat에서 행 목록을 만든다. **개수가 0인 섹션은 헤더도 내지 않는다**(빈 헤더가 컬럼 위쪽을
/// 잡아먹지 않게). `out`이 모자라면 거기서 자른다 — 화면에 안 들어가는 행을 만들 이유가 없다.
pub fn build(
    status_text: []const u8,
    /// `git diff --numstat HEAD`(추적된 파일의 `HEAD ↔ 작업트리` 증감). **행의 기본 비교와 같은 범위여야 한다** —
    /// 숫자가 index 기준인데 행을 누르면 HEAD 기준 diff가 열리면, 화면의 `+3 -1`과 그 안의 줄 수가 다르다.
    /// unborn(첫 커밋 전)은 HEAD가 없어 이 명령이 실패하므로 호출자가 `--cached` 출력을 대신 준다(그 상태에서는
    /// 추적된 파일이 전부 index에 새로 올라간 것이라 같은 값이 나온다).
    numstat: []const u8,
    /// 접힌 섹션(Section 순서). 접혀 있으면 헤더만 내고 파일 행은 만들지 않는다 — **화면에 있는 것과 이 목록이
    /// 같아야** 클릭 좌표가 그린 자리와 어긋나지 않는다.
    collapsed: [section_count]bool,
    /// 그 섹션을 **전부** 보여 줄지(사용자가 "모두 보기"를 누른 상태). 안 눌렀으면 `default_section_rows`까지만.
    expanded: [section_count]bool,
    out: []Row,
    scratch: []u8,
) Model {
    var n: usize = 0;
    var total_added: u32 = 0;
    var total_removed: u32 = 0;
    var has_staged = false;

    inline for (.{ Section.tracked, Section.untracked }) |section| {
        const tally = tallyFor(status_text, section);
        if (tally.count > 0 and n < out.len) {
            out[n] = .{ .section = .{ .section = section, .count = tally.count, .stage = tally.stage } };
            n += 1;
            var it = git_status.iterate(status_text);
            var shown: usize = 0;
            const limit = if (expanded[@intFromEnum(section)]) tally.count else @min(tally.count, default_section_rows);
            // 접힌 섹션은 헤더만 낸다(반복문을 아예 안 돈다 — inline for 안이라 continue를 쓰지 않는다).
            while (!collapsed[@intFromEnum(section)]) {
                if (shown >= limit) break;
                const entry = it.next() orelse break;
                if (n >= out.len) break;
                if (sectionOf(entry) != section) continue;
                var row: FileRow = .{
                    .section = section,
                    .path = entry.path,
                    .orig_path = entry.orig_path,
                    .letter = rowLetter(entry),
                    .stage = stageOf(entry),
                    .conflicted = entry.isConflicted(),
                    .submodule = entry.submodule,
                };
                // 추적되지 않은 파일은 비교 대상이 없어 증감이 존재하지 않는다 — 숫자 자리를 비운다.
                // **충돌도 마찬가지다**: numstat이 같은 경로에 여러 줄(스테이지별)을 내는데 그 첫 줄이 `0 0`이라
                // 그대로 쓰면 "안 바뀐 파일"로 보인다(실측). 하위 모듈은 커밋 포인터라 줄 수가 의미가 없다.
                if (section == .untracked or entry.isConflicted() or entry.submodule) {
                    row.unknown_delta = true;
                } else if (findDelta(numstat, entry.path, scratch)) |d| {
                    row.added = d.added;
                    row.removed = d.removed;
                    row.binary = d.binary;
                } else row.unknown_delta = true;
                out[n] = .{ .file = row };
                n += 1;
                shown += 1;
            }
            // 남은 게 있으면 그 사실을 행으로 말한다(조용히 자르지 않는다).
            if (!collapsed[@intFromEnum(section)] and shown < tally.count and n < out.len) {
                out[n] = .{ .more = .{ .section = section, .hidden = tally.count - shown } };
                n += 1;
            }
        }
        if (section == .tracked) has_staged = tally.staged_any;
    }

    // **합계는 화면에 보이는 행이 아니라 numstat 전체에서 낸다.** 상한(10행)이나 접힘 때문에 `+N -N`이 달라지면
    // 사용자가 커밋 직전에 보는 숫자가 화면 상태에 따라 흔들린다.
    const totals = sumDeltas(numstat);
    total_added = totals.added;
    total_removed = totals.removed;

    return .{
        .head = git_status.parseHead(status_text),
        .rows = out[0..n],
        .empty = n == 0,
        .total_added = total_added,
        .total_removed = total_removed,
        .has_staged = has_staged,
    };
}

const Tally = struct {
    count: usize = 0,
    /// 섹션 체크박스 상태(스테이지 가능한 행이 없으면 null).
    stage: ?Stage = null,
    /// index에 올라간 행이 하나라도 있나(커밋 버튼 활성 판정).
    staged_any: bool = false,
};

/// 섹션 하나의 개수·체크박스·합계를 **한 번의 순회로** 낸다. 셋을 따로 세면 같은 판정을 세 번 적게 되고,
/// 그중 하나만 고쳐지는 어긋남이 생긴다.
fn tallyFor(status_text: []const u8, section: Section) Tally {
    var tally: Tally = .{};
    var stageable: usize = 0;
    var staged_full: usize = 0;
    var it = git_status.iterate(status_text);
    while (it.next()) |entry| {
        if (sectionOf(entry) != section) continue;
        tally.count += 1;
        const stage = stageOf(entry);
        if (!stage.stageable()) continue;
        stageable += 1;
        switch (stage) {
            .full => {
                staged_full += 1;
                tally.staged_any = true;
            },
            .partial => tally.staged_any = true,
            .none, .conflicted => {},
        }
    }
    if (stageable > 0) {
        tally.stage = if (staged_full == stageable) .full else if (tally.staged_any) .partial else .none;
    }
    return tally;
}

/// 합계는 numstat을 그대로 접는다 — status를 다시 훑지 않는다(같은 파일이 numstat에 없을 수 있고, 그때는
/// 숫자가 없는 것이지 0이 아니다).
fn sumDeltas(numstat: []const u8) struct { added: u32, removed: u32 } {
    var added: u32 = 0;
    var removed: u32 = 0;
    var it = git_status.iterateNumstat(numstat);
    while (it.next()) |delta| {
        if (delta.binary) continue; // binary는 줄 수가 없다 — 0으로 세지도 않는다
        added +|= delta.added;
        removed +|= delta.removed;
    }
    return .{ .added = added, .removed = removed };
}

fn sectionOf(entry: git_status.Entry) Section {
    return if (entry.isUntracked()) .untracked else .tracked;
}

/// 행의 체크박스 상태(docs/editor-surface-dock.md §3.5.2 표).
fn stageOf(entry: git_status.Entry) Stage {
    if (entry.isConflicted()) return .conflicted;
    if (entry.isUntracked()) return .none;
    const staged = entry.staged != .unchanged and entry.staged != .untracked;
    const worktree = entry.worktree != .unchanged and entry.worktree != .untracked;
    if (staged and worktree) return .partial;
    if (staged) return .full;
    return .none;
}

/// 행 아이콘의 상태 문자. 행의 기본 비교가 `HEAD ↔ 작업트리`이므로 **HEAD에서 무슨 일이 일어났는지**를 말한다.
fn rowLetter(entry: git_status.Entry) u8 {
    if (entry.isConflicted()) return 'U';
    if (entry.isUntracked()) return 'U';
    if (entry.staged != .unchanged and entry.staged != .untracked) {
        // 스테이지에 새로 올린 뒤 작업트리에서 지운 파일은 HEAD 기준으로는 **없는 파일**이다 — 'A'로 적으면
        // 목록에는 추가로 보이는데 여는 diff는 삭제가 된다.
        if (entry.staged == .added and entry.worktree == .deleted) return 'D';
        return entry.staged.letter();
    }
    return entry.worktree.letter();
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

// **실측 캡처(2026-08-14)** — 저장소를 만들어 스테이지된 rename·부분 스테이지(`MM`)·binary·추적되지 않은 파일을
// 한 번에 만든 뒤 그대로 붙였다. 손으로 지어낸 값을 쓰면 "이 파서가 진짜 git 출력을 읽는가"를 증명하지 못한다.
const fixture_status =
    "# branch.oid c15ed6be460ed3899d32119754499f6d634de6e2\n" ++
    "# branch.head main\n" ++
    "1 MM N... 100644 100644 100644 aeb8f2b 1bbba50 blob.bin\n" ++
    "1 MM N... 100644 100644 100644 9aff573 b840a0d keep.txt\n" ++
    "2 R. N... 100644 100644 100644 de98044 de98044 R100 renamed.txt\tgone.txt\n" ++
    "? untracked.txt\n";
// `git diff --numstat --find-renames --no-ext-diff --no-textconv HEAD --` (실측).
const fixture_numstat = "-\t-\tblob.bin\n2\t0\tkeep.txt\n0\t0\tgone.txt => renamed.txt\n";
// **같은 시점의 `--cached` 출력**(실측). `keep.txt`가 `+2`가 아니라 `+1`이다 — 범위가 다르면 숫자가 다르다는
// 직접 증거이고, 목록이 index 기준 숫자를 쓰면 화면과 열리는 diff가 어긋난다는 뜻이다(§3.5.2).
const fixture_numstat_cached = "-\t-\tblob.bin\n1\t0\tkeep.txt\n0\t0\tgone.txt => renamed.txt\n";

test "2섹션: 파일 하나가 한 행이고 스테이지 여부는 체크박스가 말한다" {
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(fixture_status, fixture_numstat, .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expect(!model.empty);
    try testing.expectEqualStrings("main", model.head.branch.?);

    // 추적됨 3개(blob.bin·keep.txt·renamed.txt) → 헤더 + 파일 3행. **MM 파일이 두 번 나지 않는다**(초판과의 차이).
    try testing.expectEqual(Section.tracked, model.rows[0].section.section);
    try testing.expectEqual(@as(usize, 3), model.rows[0].section.count);
    // 부분 스테이지가 섞여 있으므로 섹션 체크박스는 부분이다.
    try testing.expectEqual(Stage.partial, model.rows[0].section.stage.?);

    try testing.expect(model.rows[1].file.binary); // blob.bin — 0/0이 아니라 binary
    try testing.expectEqual(@as(u8, 'M'), model.rows[1].file.letter);
    try testing.expectEqual(Stage.partial, model.rows[1].file.stage);

    try testing.expectEqualStrings("keep.txt", model.rows[2].file.path);
    try testing.expectEqual(Stage.partial, model.rows[2].file.stage); // MM = 일부만 스테이지
    try testing.expectEqual(@as(u32, 2), model.rows[2].file.added); // HEAD 기준 값이 붙는다(실측)

    // rename은 numstat 경로가 `gone.txt => renamed.txt`라 복원해야 붙는다.
    try testing.expectEqualStrings("renamed.txt", model.rows[3].file.path);
    try testing.expect(!model.rows[3].file.unknown_delta);
    try testing.expectEqualStrings("gone.txt", model.rows[3].file.orig_path.?);

    // 추적되지 않음은 비교 대상이 없어 숫자를 비우고, 체크박스는 비어 있다.
    try testing.expectEqual(Section.untracked, model.rows[4].section.section);
    try testing.expectEqual(Stage.none, model.rows[4].section.stage.?);
    try testing.expect(model.rows[5].file.unknown_delta);
    try testing.expectEqual(@as(u8, 'U'), model.rows[5].file.letter);
    try testing.expectEqual(Stage.none, model.rows[5].file.stage);
    try testing.expectEqual(@as(usize, 6), model.rows.len);

    // 커밋 버튼 판정: index에 올라간 것이 있다.
    try testing.expect(model.has_staged);
    // 합계는 binary를 빼고 센다(줄 수가 없는 파일을 0으로 세지 않는다).
    try testing.expectEqual(@as(u32, 2), model.total_added);
    try testing.expectEqual(@as(u32, 0), model.total_removed);
}

test "증감의 범위가 다르면 숫자가 다르다(실측 두 출력)" {
    // 같은 시점의 `HEAD` 범위와 `--cached` 범위를 나란히 넣으면 `keep.txt`가 `+2`와 `+1`로 갈린다. 목록이
    // index 기준 숫자를 쓰면 화면의 `+N`과 행을 눌러 여는 `HEAD ↔ 작업트리` diff의 줄 수가 어긋난다는 뜻이다.
    // 그래서 폴백은 "출력이 비었나"가 아니라 **unborn인가**로만 갈라야 한다(git.zig buildScmModel).
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const head_range = build(fixture_status, fixture_numstat, .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(@as(u32, 2), head_range.rows[2].file.added);

    var out2: [32]Row = undefined;
    const index_range = build(fixture_status, fixture_numstat_cached, .{false} ** section_count, .{true} ** section_count, &out2, &scratch);
    try testing.expectEqual(@as(u32, 1), index_range.rows[2].file.added);
}

test "합계는 화면에 보이는 행이 아니라 저장소 전체에서 낸다" {
    // 상한(10행)이나 접힘 때문에 `+N -N`이 흔들리면 커밋 직전에 보는 숫자가 화면 상태에 따라 달라진다.
    var out: [64]Row = undefined;
    var scratch: [256]u8 = undefined;
    var status: std.ArrayList(u8) = .empty;
    defer status.deinit(testing.allocator);
    var numstat: std.ArrayList(u8) = .empty;
    defer numstat.deinit(testing.allocator);
    try status.appendSlice(testing.allocator, "# branch.head main\n");
    for (0..25) |i| {
        var line: [64]u8 = undefined;
        try status.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "1 .M N... 1 2 3 a b f{d}.txt\n", .{i}));
        try numstat.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "2\t1\tf{d}.txt\n", .{i}));
    }

    const capped = build(status.items, numstat.items, .{false} ** section_count, .{false} ** section_count, &out, &scratch);
    // 헤더 + 상한만큼의 파일 + "모두 보기" 한 줄.
    try testing.expectEqual(default_section_rows + 2, capped.rows.len);
    try testing.expectEqual(@as(usize, 25), capped.rows[0].section.count); // 개수는 전체를 말한다
    try testing.expectEqual(@as(u32, 50), capped.total_added); // 25개 × +2 — 화면에 10개만 보여도 합계는 전체
    try testing.expectEqual(@as(u32, 25), capped.total_removed);
    const more = capped.rows[capped.rows.len - 1].more;
    try testing.expectEqual(Section.tracked, more.section);
    try testing.expectEqual(@as(usize, 25 - default_section_rows), more.hidden);
    try testing.expect(!capped.has_staged); // 전부 작업트리 변경뿐이라 커밋할 것이 없다

    // 접어도 합계는 그대로다.
    const folded = build(status.items, numstat.items, .{true} ** section_count, .{false} ** section_count, &out, &scratch);
    try testing.expectEqual(@as(u32, 50), folded.total_added);
    try testing.expectEqual(@as(usize, 1), folded.rows.len);
}

test "개수가 0인 섹션은 헤더도 내지 않는다" {
    var out: [16]Row = undefined;
    var scratch: [64]u8 = undefined;
    const model = build("# branch.head main\n? only.txt\n", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(@as(usize, 2), model.rows.len); // 추적되지 않음 헤더 + 1행뿐
    try testing.expectEqual(Section.untracked, model.rows[0].section.section);
}

test "변경이 없으면 empty다(빈 안내를 대신 그린다)" {
    var out: [8]Row = undefined;
    var scratch: [64]u8 = undefined;
    const model = build("# branch.head main\n", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expect(model.empty);
    try testing.expectEqual(@as(usize, 0), model.rows.len);
    try testing.expectEqualStrings("main", model.head.branch.?);
}

test "out이 모자라면 거기서 자른다(화면 밖 행을 만들지 않는다)" {
    var out: [2]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(fixture_status, fixture_numstat, .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(@as(usize, 2), model.rows.len);
    try testing.expectEqual(Section.tracked, model.rows[0].section.section);
}

test "numstat에 없는 파일은 숫자를 비운다(0으로 채우지 않는다)" {
    var out: [8]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build("1 .M N... 1 2 3 a b lonely.txt\n", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expect(model.rows[1].file.unknown_delta);
    try testing.expectEqual(@as(u32, 0), model.rows[1].file.added);
}

test "접힌 섹션은 헤더만 내고 개수·체크박스는 그대로 보여 준다" {
    var collapsed = [_]bool{false} ** section_count;
    collapsed[@intFromEnum(Section.tracked)] = true;
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(fixture_status, fixture_numstat, collapsed, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(Section.tracked, model.rows[0].section.section);
    try testing.expectEqual(@as(usize, 3), model.rows[0].section.count); // 개수는 접혀도 그대로
    try testing.expectEqual(Stage.partial, model.rows[0].section.stage.?); // 체크박스도 그대로(눌러서 일괄 스테이지)
    try testing.expectEqual(Section.untracked, model.rows[1].section.section); // 바로 다음 섹션이 온다

    // 전부 접으면 헤더 두 줄만 남는다.
    const all = build(fixture_status, fixture_numstat, .{true} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(@as(usize, 2), all.rows.len);
    try testing.expect(!all.empty); // 변경이 없는 것과 접은 것은 다르다
}

test "충돌은 체크박스가 없고, 하위 모듈은 숫자를 비운다" {
    var out: [16]Row = undefined;
    var scratch: [256]u8 = undefined;
    // 실측: 충돌 파일은 numstat이 같은 경로에 두 줄을 내고 첫 줄이 `0 0`이다.
    const status = "# branch.head main\n" ++
        "u UU N... 100644 100644 100644 100644 aaa bbb ccc f.txt\n" ++
        "1 AM S.M. 000000 160000 160000 000 0b4 vendor\n";
    const numstat = "0\t0\tf.txt\n4\t0\tf.txt\n1\t0\tvendor\n";
    const model = build(status, numstat, .{false} ** section_count, .{true} ** section_count, &out, &scratch);

    var saw_conflict = false;
    var saw_submodule = false;
    for (model.rows) |row| switch (row) {
        .file => |f| {
            if (f.conflicted) {
                saw_conflict = true;
                try testing.expectEqual(Section.tracked, f.section); // 2섹션 모델에서는 한 행이다
                try testing.expectEqual(Stage.conflicted, f.stage); // 체크박스를 그리지 않는다
                try testing.expect(!f.stage.stageable()); // 일괄 스테이지 대상도 아니다
                try testing.expect(f.unknown_delta); // `+0 -0`을 쓰지 않는다
                try testing.expectEqual(@as(u8, 'U'), f.letter);
            }
            if (f.submodule) {
                saw_submodule = true;
                try testing.expect(f.unknown_delta);
            }
        },
        .section, .more => {},
    };
    try testing.expect(saw_conflict);
    try testing.expect(saw_submodule);
}

test "섹션 체크박스: 전부 스테이지면 full, 하나도 없으면 none, 충돌뿐이면 아예 없다" {
    var out: [16]Row = undefined;
    var scratch: [256]u8 = undefined;

    const all_staged = "# branch.head main\n1 M. N... 1 2 3 a b x.txt\n1 A. N... 1 2 3 a b y.txt\n";
    const full = build(all_staged, "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(Stage.full, full.rows[0].section.stage.?);
    try testing.expect(full.has_staged);

    const none_staged = "# branch.head main\n1 .M N... 1 2 3 a b x.txt\n";
    const none = build(none_staged, "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(Stage.none, none.rows[0].section.stage.?);
    try testing.expect(!none.has_staged);

    // 스테이지할 수 있는 행이 하나도 없으면 섹션 체크박스를 그리지 않는다(눌러도 아무 일 없는 컨트롤을 두지 않는다).
    const only_conflict = "# branch.head main\nu UU N... 1 1 1 1 a b c f.txt\n";
    const conflict = build(only_conflict, "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expect(conflict.rows[0].section.stage == null);
    try testing.expect(!conflict.has_staged);
}

test "스테이지 후 지운 파일은 HEAD 기준으로 삭제다" {
    // `AD` — index에는 새로 올렸는데 작업트리에서 지웠다. 행의 기본 비교가 HEAD↔작업트리이므로 'A'로 적으면
    // 목록은 추가로 보이는데 여는 diff는 삭제가 된다.
    var out: [8]Row = undefined;
    var scratch: [64]u8 = undefined;
    const model = build("# branch.head main\n1 AD N... 1 2 3 a b gone.txt\n", "", .{false} ** section_count, .{true} ** section_count, &out, &scratch);
    try testing.expectEqual(@as(u8, 'D'), model.rows[1].file.letter);
    try testing.expectEqual(Stage.partial, model.rows[1].file.stage);
}
