//! 도크 소스 컨트롤 뷰 **변경 사항 탭의 행 모델**(L2 순수, docs/editor-surface-dock.md §3.5.2).
//!
//! git 출력(status + numstat)을 받아 화면에 그릴 행 목록을 만든다. 렌더는 이 결과를 그리기만 한다 — 어느 섹션에
//! 무엇이 몇 개 드는지, 행에 어떤 동작이 붙는지, 증감이 얼마인지를 결정하는 곳은 여기 하나다.
//!
//! **섹션은 다시 비교 기준이다**(2026-08-14 사용자 결정 2차). 스테이징을 체크박스가 아니라 **행 호버의 `+`**로
//! 하기로 하면서, "누르면 그 행이 위 그룹으로 올라간다"가 곧 피드백이 된다. 그래서 그룹은 `스테이지된 변경`과
//! `변경 사항` 둘이고, `MM`(일부만 스테이지한) 파일은 **양쪽에 각각** 난다 — 두 행이 서로 다른 것을 가리키므로
//! 애매하지 않다(위 행은 커밋될 것, 아래 행은 아직 아닌 것). 추적되지 않은 파일은 `변경 사항` 안에 `U`로 든다.
//!
//! **할당하지 않는다.** 행은 입력 텍스트를 가리키는 슬라이스와 숫자뿐이고, 호출자가 준 `out` 배열에 채운다.
//! rename 경로 복원만 scratch 버퍼를 쓴다(numstat이 `A => B` 한 필드로 적어 status 경로와 다르기 때문 — git_status 참고).

const std = @import("std");
const i18n = @import("../i18n.zig"); // 표시 문자열 단일 출처
const git_status = @import("git_status.zig");

/// 섹션 개수 — 접힘·펼침 상태 배열의 길이 계약이다(세션이 같은 크기로 들고 있는다).
pub const section_count = 2;

/// 한 섹션이 기본으로 보여 주는 파일 행 수. 변경이 수백 개인 저장소에서 한 섹션이 화면을 다 먹으면 나머지
/// 섹션이 스크롤 저 아래로 밀려 **있는지조차 모르게** 된다(스크롤이 있어도 마찬가지다 — 첫 화면이 전부다).
/// 이 값을 넘으면 "모두 보기"를 내고, 사용자가 그 섹션만 편다.
pub const default_section_rows: usize = 10;

pub const Section = enum {
    /// `HEAD ↔ index` — 지금 커밋하면 들어갈 것. 행 호버의 `−`가 여기서 내린다.
    staged,
    /// `index ↔ 작업트리` + 추적되지 않은 파일. 행 호버의 `+`가 여기서 올린다.
    changes,

    pub fn title(self: Section) []const u8 {
        return switch (self) {
            .staged => i18n.t(.scm_staged),
            .changes => i18n.t(.scm_changes),
        };
    }
};

/// 행 호버에 뜨는 주 동작. **체크박스가 아니다** — 누르면 그 행이 다른 그룹으로 옮겨 가는 것이 피드백이다.
pub const RowAction = enum {
    /// `git add` — `변경 사항`의 행.
    stage,
    /// `git restore --staged` — `스테이지된 변경`의 행.
    unstage,
    /// 동작을 붙이지 않는다. 병합 충돌은 스테이지 여부의 문제가 아니라 **해결되지 않은 상태**이고, 여기에
    /// `+`를 두면 누르는 순간 충돌 표시가 든 파일이 "해결됨"으로 커밋된다(§3.5 경계 상태표).
    none,
};

pub const FileRow = struct {
    section: Section,
    path: []const u8,
    /// rename/copy의 원래 경로(그 외 null). 목록은 새 경로를 보여 주고 원래 경로는 보조 정보다.
    orig_path: ?[]const u8 = null,
    /// 행 오른쪽의 상태 문자. **그 행이 선 섹션의 축**을 말한다(스테이지 행은 index 축, 변경 행은 작업트리 축) —
    /// 같은 파일이 두 행일 때 각 행이 서로 다른 글자를 갖는 것이 정상이다(`AM`처럼).
    letter: u8,
    /// 호버에 뜰 동작.
    action: RowAction,
    added: u32 = 0,
    removed: u32 = 0,
    /// numstat이 `-`를 준 파일. 숫자 대신 그 사실을 표시한다 — **0/0으로 거짓 표시하지 않는다.**
    binary: bool = false,
    /// 증감을 못 붙였다(numstat에 없거나 rename 경로 복원 실패). 숫자 자리를 비운다.
    unknown_delta: bool = false,
    /// 병합 충돌 중(해결 전). diff는 `HEAD ↔ 작업트리`로 열어 충돌 표시를 그대로 보여 준다.
    conflicted: bool = false,
    /// 추적되지 않은 파일(`?`). 비교 대상이 없어 열면 파일 내용을 그대로 보여 준다.
    untracked: bool = false,
    /// 하위 모듈(gitlink). **텍스트 비교가 없다** — 열면 빈 화면이 되므로 호출자가 그 사실을 말한다.
    submodule: bool = false,
};

pub const SectionRow = struct {
    section: Section,
    /// 그 섹션의 **전체** 파일 수(접혀 있어도, 잘려 있어도 전체를 말한다).
    count: usize,
    /// 섹션 헤더 호버에 뜰 일괄 동작(`모두 스테이지`/`모두 언스테이지`). 대상이 하나도 없으면(전부 충돌) `.none`.
    action: RowAction,
};

/// 목록이 **불완전하다**는 사실을 말하는 행. 누를 수 없다(컨트롤이 아니라 상태 진술이다).
pub const Notice = enum {
    /// git 출력이 백엔드 상한에 걸려 잘렸다 — 뒤쪽 파일은 아예 오지 않았거나 증감이 없다.
    /// **"변경이 없다"와 구별돼야 한다**: 같은 빈 화면이지만 원인이 정반대다.
    output_truncated,

    pub fn text(self: Notice) []const u8 {
        return switch (self) {
            .output_truncated => i18n.t(.scm_output_truncated),
        };
    }
};

pub const Row = union(enum) {
    section: SectionRow,
    file: FileRow,
    /// "모두 보기" 행 — 그 섹션에 **아직 안 보여 준 파일이 몇 개인지** 말한다. 누르면 그 섹션만 전부 편다.
    /// 이 행이 없으면 목록이 조용히 잘려, 사용자는 자기가 바꾼 파일이 없어졌다고 읽는다.
    more: struct { section: Section, hidden: usize },
    notice: Notice,
};

pub const Model = struct {
    head: git_status.Head,
    rows: []const Row,
    /// 변경이 하나도 없다(섹션 헤더도 안 낸다 — 빈 안내를 대신 그린다).
    empty: bool,
    /// 요약 줄이 쓸 합계. **`HEAD ↔ 작업트리` 한 범위에서** 낸다 — 두 섹션의 numstat을 더하면 `MM` 파일이
    /// 두 번 세어져 실제보다 부풀어 오른다.
    total_added: u32 = 0,
    total_removed: u32 = 0,
    /// 커밋 버튼을 켤 수 있나 = index에 무언가 올라가 있나. 낙관적으로 추정하지 않고 status가 말한 것만 쓴다
    /// (docs/editor-surface-dock-write.md §7).
    has_staged: bool = false,
};

/// status와 numstat에서 행 목록을 만든다. **개수가 0인 섹션은 헤더도 내지 않는다**(빈 헤더가 컬럼 위쪽을
/// 잡아먹지 않게). `out`이 모자라면 마지막 줄로 "더 있다"를 말한다.
pub fn build(
    status_text: []const u8,
    /// `git diff --numstat --cached` — **스테이지된 변경** 행의 증감(`HEAD ↔ index`).
    numstat_staged: []const u8,
    /// `git diff --numstat` — **변경 사항** 행의 증감(`index ↔ 작업트리`).
    numstat_worktree: []const u8,
    /// `git diff --numstat HEAD --` — **요약 줄 합계**만 여기서 낸다. 위 둘을 더하면 `MM` 파일이 두 번 세어진다.
    /// unborn(첫 커밋 전)은 HEAD가 없어 이 명령이 실패하므로 호출자가 `--cached` 출력을 대신 준다.
    numstat_total: []const u8,
    /// 접힌 섹션(Section 순서). 접혀 있으면 헤더만 내고 파일 행은 만들지 않는다 — **화면에 있는 것과 이 목록이
    /// 같아야** 클릭 좌표가 그린 자리와 어긋나지 않는다.
    collapsed: [section_count]bool,
    /// 그 섹션을 **전부** 보여 줄지(사용자가 "모두 보기"를 누른 상태). 안 눌렀으면 `default_section_rows`까지만.
    expanded: [section_count]bool,
    /// git 출력이 상한에 걸려 잘렸나(백엔드가 알려 준다). **모델이 받아서 행으로 만든다** — 플래그만 세워 두면
    /// 아무도 안 읽어서 화면은 "변경이 없다"와 같은 모습이 된다(적대적 검증 2026-08-14에서 실제로 그랬다).
    output_truncated: bool,
    out: []Row,
    scratch: []u8,
) Model {
    var n: usize = 0;
    var has_staged = false;
    // 버퍼에 못 담은 파일 수와, 잘림이 **시작된** 섹션. 마지막 한 줄을 이 사실에 내주기 위해 센다.
    var dropped: usize = 0;
    var dropped_section: ?Section = null;

    inline for (.{ Section.staged, Section.changes }) |section| {
        const count = countFor(status_text, section);
        if (section == .staged) has_staged = count > 0;
        // **헤더조차 못 넣은 섹션이 있다**(앞 섹션이 버퍼를 다 썼다). 이게 조용한 잘림의 실제 모양이다.
        if (count > 0 and n >= out.len) {
            dropped += count;
            if (dropped_section == null) dropped_section = section;
        }
        if (count > 0 and n < out.len) {
            out[n] = .{ .section = .{ .section = section, .count = count, .action = sectionAction(status_text, section) } };
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
                var row: FileRow = .{
                    .section = section,
                    .path = entry.path,
                    .orig_path = entry.orig_path,
                    .letter = rowLetter(entry, section),
                    .action = rowAction(entry, section),
                    .conflicted = entry.isConflicted(),
                    .untracked = entry.isUntracked(),
                    .submodule = entry.submodule,
                };
                // 추적되지 않은 파일은 비교 대상이 없어 증감이 존재하지 않는다 — 숫자 자리를 비운다.
                // **충돌도 마찬가지다**: numstat이 같은 경로에 여러 줄(스테이지별)을 내는데 그 첫 줄이 `0 0`이라
                // 그대로 쓰면 "안 바뀐 파일"로 보인다(실측). 하위 모듈은 커밋 포인터라 줄 수가 의미가 없다.
                if (entry.isUntracked() or entry.isConflicted() or entry.submodule) {
                    row.unknown_delta = true;
                } else {
                    // **섹션마다 다른 numstat을 본다** — 행이 선 그룹이 곧 비교 기준이라, 숫자도 그 범위여야 한다.
                    const numstat = if (section == .staged) numstat_staged else numstat_worktree;
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
            if (!collapsed[@intFromEnum(section)] and shown < count) {
                if (n < out.len) {
                    out[n] = .{ .more = .{ .section = section, .hidden = count - shown } };
                    n += 1;
                } else {
                    dropped += count - shown;
                    if (dropped_section == null) dropped_section = section;
                }
            }
        }
    }

    // **버퍼 상한에 걸렸으면 마지막 한 줄로 그 사실을 말한다.** 조용히 끝내면 변경이 수백 개인 저장소에서
    // 사용자는 자기가 바꾼 파일이 없어졌다고 읽는다 — 파일(또는 헤더) 한 줄을 잃는 편이 "없다"고 거짓말하는
    // 것보다 낫다. 자리를 내주는 그 행도 숨은 수에 함께 센다.
    if (dropped > 0 and n > 0) {
        const extra: usize = switch (out[n - 1]) {
            .file => 1, // 그 파일 행을 자리로 내준다
            .section => 0, // 헤더만 있던 섹션 — 그 파일들은 이미 dropped에 들어 있다
            .more => |m| m.hidden, // 이미 세고 있던 수를 흡수한다
            .notice => 0, // 잘림 알림은 아래에서 마지막에 얹는다
        };
        out[n - 1] = .{ .more = .{ .section = dropped_section.?, .hidden = dropped + extra } };
    }

    // **잘림은 마지막 줄을 이긴다.** 둘 다 "전부가 아니다"를 말하지만, 출력 잘림은 데이터 자체가 없다는 뜻이라
    // 숨은 개수보다 먼저 알아야 한다(그 개수마저 못 믿는 상태다).
    if (output_truncated) {
        if (n < out.len) {
            out[n] = .{ .notice = .output_truncated };
            n += 1;
        } else if (n > 0) out[n - 1] = .{ .notice = .output_truncated };
    }

    const totals = sumDeltas(numstat_total);
    return .{
        .head = git_status.parseHead(status_text),
        .rows = out[0..n],
        .empty = n == 0,
        .total_added = totals.added,
        .total_removed = totals.removed,
        .has_staged = has_staged,
    };
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

/// 그 항목이 이 섹션에 드는가. **한 파일이 두 섹션에 동시에 들 수 있다**(`MM`) — git이 그렇게 보고하고,
/// 사용자도 "일부만 스테이지한 파일"을 양쪽에서 봐야 한다(위 행은 커밋될 것, 아래 행은 아직 아닌 것).
fn belongs(entry: git_status.Entry, section: Section) bool {
    if (entry.isConflicted()) return section == .changes; // 충돌은 스테이지된 것이 아니라 해결 안 된 상태다
    return switch (section) {
        .staged => entry.staged != .unchanged and entry.staged != .untracked,
        // 추적되지 않은 파일도 여기 든다(VS Code와 같은 묶음 — 별도 그룹을 만들지 않는다).
        .changes => entry.worktree != .unchanged,
    };
}

/// 탭 이름 옆에 붙는 **전체 변경 파일 수**(`변경 사항 (N)`). 두 섹션의 파일을 더한다 — `MM` 파일은
/// 양쪽에 한 줄씩 서므로 두 번 세어지고, 그것이 목록에 실제로 나는 줄 수와 같다(섹션 배지의 합).
///
/// **모델을 만들지 않는다.** 이 수를 알려고 `build`를 부르면 행마다 numstat 전체를 훑는 비용
/// (`findDelta`)까지 함께 내는데, 그 숫자는 이 답에 쓰이지 않는다 — 285파일·"모두 보기" 상태에서
/// 실측 378µs 대 여기 몇 µs다(2026-08-20). 히스토리·에이전트 탭은 이 수만 필요하므로 그 차이가
/// 매 프레임 그대로 낭비가 된다.
///
/// **접기·펼치기·잘림과 무관하다** — `status` 전체를 세므로 화면에 몇 줄이 났는지와 상관없이 같은
/// 답을 낸다(섹션 헤더의 `count`가 그런 것과 같은 이유).
pub fn changedFileCount(status_text: []const u8) u32 {
    // **한 번만 훑는다.** 섹션마다 `countFor`를 부르면 같은 출력을 두 번 파싱한다 — 답은 같지만
    // 이 함수가 매 프레임 도는 자리에 있어 그 두 배가 그대로 비용이다.
    var it = git_status.iterate(status_text);
    var total: usize = 0;
    while (it.next()) |entry| {
        // 판정은 `belongs` 하나가 소유한다(섹션 배지·행 배치와 같은 술어) — 여기서 다시 쓰면 탭의
        // 숫자와 목록의 줄 수가 갈린다.
        inline for (.{ Section.staged, Section.changes }) |section| {
            if (belongs(entry, section)) total += 1;
        }
    }
    return std.math.cast(u32, total) orelse std.math.maxInt(u32);
}

fn countFor(status_text: []const u8, section: Section) usize {
    var it = git_status.iterate(status_text);
    var count: usize = 0;
    while (it.next()) |entry| {
        if (belongs(entry, section)) count += 1;
    }
    return count;
}

/// 섹션 헤더의 일괄 동작. 그 섹션에 **동작을 붙일 수 있는 행이 하나도 없으면**(전부 충돌) `.none`이다 —
/// 눌러도 아무 일 없는 컨트롤을 두지 않는다.
fn sectionAction(status_text: []const u8, section: Section) RowAction {
    var it = git_status.iterate(status_text);
    while (it.next()) |entry| {
        if (!belongs(entry, section)) continue;
        const action = rowAction(entry, section);
        if (action != .none) return action;
    }
    return .none;
}

fn rowAction(entry: git_status.Entry, section: Section) RowAction {
    if (entry.isConflicted()) return .none;
    return switch (section) {
        .staged => .unstage,
        .changes => .stage,
    };
}

/// 행 오른쪽의 상태 문자. **그 행이 선 섹션의 축**을 쓴다 — 같은 파일이 두 행일 때 각각 다른 글자가 나오는 것이
/// 정상이다(`AM`이면 위 행은 `A`, 아래 행은 `M`).
fn rowLetter(entry: git_status.Entry, section: Section) u8 {
    if (entry.isConflicted()) return 'U';
    return switch (section) {
        .staged => entry.staged.letter(),
        .changes => entry.worktree.letter(),
    };
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
// `git diff --numstat --cached` (실측) — 스테이지된 변경 행의 증감.
const fixture_staged = "-\t-\tblob.bin\n1\t0\tkeep.txt\n0\t0\tgone.txt => renamed.txt\n";
// `git diff --numstat` (실측) — 변경 사항 행의 증감. 셋 다 **같은 저장소·같은 시점**에서 받았다
// (2026-08-14 — 적대적 검증에서 손으로 지어낸 fixture가 한 번 걸렸기에, 세 출력의 출처를 여기 못박는다).
const fixture_worktree = "-\t-\tblob.bin\n1\t0\tkeep.txt\n";
// `git diff --numstat … HEAD --` (실측) — 요약 합계만 여기서 낸다.
const fixture_total = "-\t-\tblob.bin\n2\t0\tkeep.txt\n0\t0\tgone.txt => renamed.txt\n";

fn buildFixture(out: []Row, scratch: []u8) Model {
    return build(fixture_status, fixture_staged, fixture_worktree, fixture_total, .{false} ** section_count, .{true} ** section_count, false, out, scratch);
}

test "탭의 파일 수는 목록이 세운 섹션 배지의 합과 같다 — 합치는 방식이 둘이어도 답은 하나다" {
    // `changedFileCount`(status 한 번 순회)와 목록이 만든 섹션 헤더의 `count` 합은 **같은 사실**이다.
    // 전자는 히스토리·에이전트 탭이(모델 없이), 후자는 변경 사항 탭이(이미 만든 모델에서) 쓴다.
    // 두 경로가 갈리면 탭의 숫자와 목록의 줄 수가 다른 말을 하므로 여기서 못 박는다.
    //
    // 표본은 **경계 상태를 전부 담는다** — `MM`(양쪽에 한 줄씩), 스테이지만, 작업트리만, 추적되지 않음,
    // 충돌(스테이지된 것이 아니라 `변경 사항`에 든다), 하위 모듈.
    const status =
        "# branch.head main\n" ++
        "1 MM N... 100644 100644 100644 aaa bbb both.txt\n" ++
        "1 M. N... 100644 100644 100644 aaa bbb staged.txt\n" ++
        "1 .M N... 100644 100644 100644 aaa bbb work.txt\n" ++
        "? untracked.txt\n" ++
        "u UU N... 100644 100644 100644 100644 aaa bbb ccc conflict.txt\n" ++
        "1 .M S..U 160000 160000 160000 aaa bbb sub\n";
    var rows: [64]Row = undefined;
    var scratch: [1024]u8 = undefined;
    // 접힘·펼침 어느 상태에서도 같아야 한다 — 화면에 몇 줄이 났는지와 무관한 값이기 때문이다.
    for ([_][section_count]bool{ .{ false, false }, .{ true, true } }) |collapsed| {
        for ([_][section_count]bool{ .{ false, false }, .{ true, true } }) |expanded| {
            const model = build(status, "", "", "", collapsed, expanded, false, &rows, &scratch);
            var badge_total: u32 = 0;
            for (model.rows) |row| switch (row) {
                .section => |section| badge_total += @intCast(section.count),
                else => {},
            };
            try std.testing.expectEqual(badge_total, changedFileCount(status));
        }
    }
    // `MM`이 두 번 세어지는 것이 계약이다(두 섹션에 각각 한 줄로 서므로) — 6줄 입력에 7이 나온다.
    try std.testing.expectEqual(@as(u32, 7), changedFileCount(status));
}

test "섹션은 비교 기준이고 MM 파일은 양쪽에 각각 난다" {
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = buildFixture(&out, &scratch);
    try testing.expect(!model.empty);
    try testing.expectEqualStrings("main", model.head.branch.?);

    // 스테이지된 변경 3개(blob.bin·keep.txt·renamed.txt) — 헤더 동작은 `−`(언스테이지)다.
    try testing.expectEqual(Section.staged, model.rows[0].section.section);
    try testing.expectEqual(@as(usize, 3), model.rows[0].section.count);
    try testing.expectEqual(RowAction.unstage, model.rows[0].section.action);
    try testing.expect(model.rows[1].file.binary); // blob.bin — 0/0이 아니라 binary
    try testing.expectEqual(RowAction.unstage, model.rows[1].file.action);
    try testing.expectEqual(@as(u32, 1), model.rows[2].file.added); // keep.txt: index 기준(실측 --cached)
    try testing.expectEqualStrings("renamed.txt", model.rows[3].file.path);
    try testing.expectEqualStrings("gone.txt", model.rows[3].file.orig_path.?);

    // 변경 사항 3개(blob.bin·keep.txt·untracked.txt) — **같은 파일이 위에도 있다**(MM).
    try testing.expectEqual(Section.changes, model.rows[4].section.section);
    try testing.expectEqual(@as(usize, 3), model.rows[4].section.count);
    try testing.expectEqual(RowAction.stage, model.rows[4].section.action);
    try testing.expectEqualStrings("blob.bin", model.rows[5].file.path);
    try testing.expectEqual(RowAction.stage, model.rows[5].file.action);
    try testing.expectEqual(@as(u32, 1), model.rows[6].file.added); // keep.txt: 작업트리 기준(실측)

    // 추적되지 않은 파일은 별도 그룹이 아니라 변경 사항 안에 `U`로 든다(VS Code와 같은 묶음).
    try testing.expectEqualStrings("untracked.txt", model.rows[7].file.path);
    try testing.expectEqual(@as(u8, 'U'), model.rows[7].file.letter);
    try testing.expect(model.rows[7].file.untracked);
    try testing.expect(model.rows[7].file.unknown_delta); // 비교 대상이 없어 숫자가 없다
    try testing.expectEqual(@as(usize, 8), model.rows.len);

    try testing.expect(model.has_staged);
    // 합계는 **한 범위**에서 낸다 — 두 numstat을 더하면 keep.txt가 1+1=2로 두 번 세어져 실제(2)와 우연히
    // 같아 보이지만, 스테이지·작업트리 변경이 다른 줄이면 곧바로 어긋난다.
    try testing.expectEqual(@as(u32, 2), model.total_added);
    try testing.expectEqual(@as(u32, 0), model.total_removed);
}

test "행의 상태 문자는 그 행이 선 섹션의 축을 말한다" {
    // `AM` — index에는 새 파일, 작업트리에는 그 뒤 수정. 위 행은 `A`, 아래 행은 `M`이어야 한다.
    var out: [8]Row = undefined;
    var scratch: [64]u8 = undefined;
    const model = build("# branch.head main\n1 AM N... 1 2 3 a b f.txt\n", "", "", "", .{false} ** section_count, .{true} ** section_count, false, &out, &scratch);
    try testing.expectEqual(@as(u8, 'A'), model.rows[1].file.letter);
    try testing.expectEqual(Section.staged, model.rows[1].file.section);
    try testing.expectEqual(@as(u8, 'M'), model.rows[3].file.letter);
    try testing.expectEqual(Section.changes, model.rows[3].file.section);
}

test "충돌에는 동작을 붙이지 않고 변경 사항에만 든다" {
    // 충돌은 스테이지 여부의 문제가 아니라 해결되지 않은 상태다. `+`를 두면 누르는 순간 충돌 표시가 든 파일이
    // "해결됨"으로 커밋된다.
    var out: [16]Row = undefined;
    var scratch: [256]u8 = undefined;
    const status = "# branch.head main\nu UU N... 100644 100644 100644 100644 aaa bbb ccc f.txt\n";
    const model = build(status, "", "0\t0\tf.txt\n", "", .{false} ** section_count, .{true} ** section_count, false, &out, &scratch);
    try testing.expectEqual(Section.changes, model.rows[0].section.section); // 스테이지 그룹에는 안 든다
    try testing.expectEqual(RowAction.none, model.rows[0].section.action); // 일괄 동작도 없다
    try testing.expect(model.rows[1].file.conflicted);
    try testing.expectEqual(RowAction.none, model.rows[1].file.action);
    try testing.expect(model.rows[1].file.unknown_delta); // `+0 -0`을 쓰지 않는다
    try testing.expectEqual(@as(u8, 'U'), model.rows[1].file.letter);
}

test "하위 모듈은 숫자를 비운다(커밋 포인터라 줄 수가 의미 없다)" {
    var out: [16]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build("# branch.head main\n1 AM S.M. 000000 160000 160000 000 0b4 vendor\n", "1\t0\tvendor\n", "1\t0\tvendor\n", "", .{false} ** section_count, .{true} ** section_count, false, &out, &scratch);
    var saw = false;
    for (model.rows) |row| switch (row) {
        .file => |f| if (f.submodule) {
            saw = true;
            try testing.expect(f.unknown_delta);
        },
        .section, .more, .notice => {},
    };
    try testing.expect(saw);
}

test "출력이 잘리면 그 사실을 행으로 말한다(빈 화면과 구별한다)" {
    // 백엔드가 상한에 걸려 출력을 자르면 뒤쪽 파일은 아예 오지 않는다. 플래그만 세워 두면 화면은 "변경이 없다"와
    // 똑같이 보이는데 원인은 정반대다 — 적대적 검증에서 `Result.truncated`에 **소비자가 하나도 없다**는 것이 드러나
    // 이 행을 만들었다.
    var out: [16]Row = undefined;
    var scratch: [64]u8 = undefined;
    const model = build("# branch.head main\n1 .M N... 1 2 3 a b a.txt\n", "", "1\t0\ta.txt\n", "1\t0\ta.txt\n", .{false} ** section_count, .{true} ** section_count, true, &out, &scratch);
    try testing.expectEqual(Notice.output_truncated, model.rows[model.rows.len - 1].notice);
    try testing.expect(model.rows[0] == .section); // 앞선 목록은 그대로 남는다(있는 것까지는 보여 준다)

    const clean = build("# branch.head main\n1 .M N... 1 2 3 a b a.txt\n", "", "1\t0\ta.txt\n", "1\t0\ta.txt\n", .{false} ** section_count, .{true} ** section_count, false, &out, &scratch);
    for (clean.rows) |row| try testing.expect(row != .notice);
}

test "개수가 0인 섹션은 헤더도 내지 않는다" {
    var out: [16]Row = undefined;
    var scratch: [64]u8 = undefined;
    const model = build("# branch.head main\n? only.txt\n", "", "", "", .{false} ** section_count, .{true} ** section_count, false, &out, &scratch);
    try testing.expectEqual(@as(usize, 2), model.rows.len); // 변경 사항 헤더 + 1행뿐
    try testing.expectEqual(Section.changes, model.rows[0].section.section);
    try testing.expect(!model.has_staged); // 커밋할 것이 없다
}

test "변경이 없으면 empty다(빈 안내를 대신 그린다)" {
    var out: [8]Row = undefined;
    var scratch: [64]u8 = undefined;
    const model = build("# branch.head main\n", "", "", "", .{false} ** section_count, .{true} ** section_count, false, &out, &scratch);
    try testing.expect(model.empty);
    try testing.expectEqual(@as(usize, 0), model.rows.len);
    try testing.expectEqualStrings("main", model.head.branch.?);
}

test "out이 모자라면 마지막 줄로 '더 있다'를 말한다(조용히 자르지 않는다)" {
    var out: [2]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = buildFixture(&out, &scratch);
    try testing.expectEqual(@as(usize, 2), model.rows.len);
    try testing.expectEqual(Section.staged, model.rows[0].section.section);
    // 스테이지 3 + 변경 3 = 6개 가운데 화면에 남은 파일 행이 0개다(자리를 내준 한 줄까지 센다).
    try testing.expectEqual(@as(usize, 6), model.rows[1].more.hidden);

    // 자리가 충분하면 이 행이 아예 안 나온다(눌러도 아무 일 없는 컨트롤을 두지 않는다).
    var full: [16]Row = undefined;
    const complete = buildFixture(&full, &scratch);
    for (complete.rows) |row| try testing.expect(row != .more);
}

test "numstat에 없는 파일은 숫자를 비운다(0으로 채우지 않는다)" {
    var out: [8]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build("1 .M N... 1 2 3 a b lonely.txt\n", "", "", "", .{false} ** section_count, .{true} ** section_count, false, &out, &scratch);
    try testing.expect(model.rows[1].file.unknown_delta);
    try testing.expectEqual(@as(u32, 0), model.rows[1].file.added);
}

test "접힌 섹션은 헤더만 내고 개수·일괄 동작은 그대로 보여 준다" {
    var collapsed = [_]bool{false} ** section_count;
    collapsed[@intFromEnum(Section.staged)] = true;
    var out: [32]Row = undefined;
    var scratch: [256]u8 = undefined;
    const model = build(fixture_status, fixture_staged, fixture_worktree, fixture_total, collapsed, .{true} ** section_count, false, &out, &scratch);
    try testing.expectEqual(Section.staged, model.rows[0].section.section);
    try testing.expectEqual(@as(usize, 3), model.rows[0].section.count); // 개수는 접혀도 그대로
    try testing.expectEqual(RowAction.unstage, model.rows[0].section.action); // 접어도 일괄 동작은 남는다
    try testing.expectEqual(Section.changes, model.rows[1].section.section); // 바로 다음 섹션이 온다

    const all = build(fixture_status, fixture_staged, fixture_worktree, fixture_total, .{true} ** section_count, .{true} ** section_count, false, &out, &scratch);
    try testing.expectEqual(@as(usize, 2), all.rows.len);
    try testing.expect(!all.empty); // 변경이 없는 것과 접은 것은 다르다
}

test "섹션은 기본 상한까지만 보여 주고 남은 개수를 말한다" {
    var status: std.ArrayList(u8) = .empty;
    defer status.deinit(testing.allocator);
    try status.appendSlice(testing.allocator, "# branch.head main\n");
    for (0..25) |i| {
        var line: [64]u8 = undefined;
        try status.appendSlice(testing.allocator, try std.fmt.bufPrint(&line, "1 .M N... 1 2 3 a b f{d}.txt\n", .{i}));
    }
    var out: [64]Row = undefined;
    var scratch: [256]u8 = undefined;
    const capped = build(status.items, "", "", "", .{false} ** section_count, .{false} ** section_count, false, &out, &scratch);
    try testing.expectEqual(default_section_rows + 2, capped.rows.len); // 헤더 + 10행 + "모두 보기"
    try testing.expectEqual(@as(usize, 25), capped.rows[0].section.count);
    try testing.expectEqual(@as(usize, 25 - default_section_rows), capped.rows[capped.rows.len - 1].more.hidden);
}

test "무작위 status 입력에도 불변식이 깨지지 않는다" {
    // 적대적 검증 7회차: 손으로 고른 경계만 보면 "내가 생각한 입력"만 검증한다. 결정적 LCG로 상태 코드·경로·
    // 버퍼 크기를 섞어 돌리며 **모델이 스스로 지켜야 하는 것**만 단언한다 — 넘치지 않는가, 헤더 없는 파일 행이
    // 나오지 않는가, 개수가 실제 행보다 작지 않은가.
    var seed: u64 = 0x9E3779B97F4A7C15;
    const codes = [_][]const u8{ "M.", ".M", "MM", "A.", "AD", "R.", "D.", ".D", "??", "UU" };
    var iter: usize = 0;
    while (iter < 200) : (iter += 1) {
        var status: std.ArrayList(u8) = .empty;
        defer status.deinit(testing.allocator);
        try status.appendSlice(testing.allocator, "# branch.oid abc\n# branch.head main\n");
        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const file_count = (seed >> 33) % 40;
        for (0..file_count) |i| {
            seed = seed *% 6364136223846793005 +% 1442695040888963407;
            const code = codes[(seed >> 33) % codes.len];
            var line: [96]u8 = undefined;
            const text = if (std.mem.eql(u8, code, "??"))
                try std.fmt.bufPrint(&line, "? f{d}.txt\n", .{i})
            else if (std.mem.eql(u8, code, "UU"))
                try std.fmt.bufPrint(&line, "u UU N... 1 1 1 1 a b c f{d}.txt\n", .{i})
            else if (code[0] == 'R')
                try std.fmt.bufPrint(&line, "2 {s} N... 1 2 3 a b R100 f{d}.txt\told{d}.txt\n", .{ code, i, i })
            else
                try std.fmt.bufPrint(&line, "1 {s} N... 1 2 3 a b f{d}.txt\n", .{ code, i });
            try status.appendSlice(testing.allocator, text);
        }

        seed = seed *% 6364136223846793005 +% 1442695040888963407;
        const cap = 1 + (seed >> 33) % 48;
        var out: [64]Row = undefined;
        var scratch: [256]u8 = undefined;
        const collapsed: [section_count]bool = .{ (seed >> 3) & 1 == 0, (seed >> 4) & 1 == 0 };
        const expanded: [section_count]bool = .{ (seed >> 5) & 1 == 0, (seed >> 6) & 1 == 0 };
        const model = build(status.items, "", "", "", collapsed, expanded, (seed >> 7) & 1 == 0, out[0..cap], &scratch);

        try testing.expect(model.rows.len <= cap); // 버퍼를 넘겨 쓰지 않는다
        var seen_section: ?Section = null;
        var counts: [section_count]usize = .{ 0, 0 };
        for (model.rows) |row| switch (row) {
            .section => |sec| {
                seen_section = sec.section;
                counts[@intFromEnum(sec.section)] = sec.count;
            },
            // **파일 행은 항상 자기 섹션 헤더 뒤에 온다.** 헤더가 잘려 나갔는데 파일만 남으면 화면에서 그 행이
            // 어느 그룹인지 알 수 없다.
            .file => |f| try testing.expectEqual(seen_section.?, f.section),
            .more => |m| try testing.expect(m.hidden > 0), // "0개 더"는 눌러도 아무 일 없는 컨트롤이다
            .notice => {},
        };
        // 섹션 헤더가 말한 개수는 그 섹션의 실제 항목 수와 같아야 한다(화면에 몇 개를 그렸는지와 무관하게).
        inline for (.{ Section.staged, Section.changes }) |section| {
            if (counts[@intFromEnum(section)] > 0)
                try testing.expectEqual(countFor(status.items, section), counts[@intFromEnum(section)]);
        }
    }
}
