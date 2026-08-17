//! 소스 컨트롤 도크가 세울 **저장소 목록**을 만드는 순수 층(docs/editor-surface-dock.md §3.5.1c).
//!
//! 목록의 단위는 저장소가 아니라 **워크트리**다 — 링크된 워크트리는 자기 루트·index·HEAD를 갖는 독립된
//! 작업 대상이고, 화면에서도 각각 한 줄이다.
//!
//! 이 파일은 git을 부르지 않는다. 호출자가 ⑴ 터미널들이 선 저장소 루트와 ⑵ 각 루트의 워크트리 경로를
//! 이미 구해서 넣고, 여기서는 **순서·중복·상한**만 정한다. 그 셋이 화면에 그대로 보이는 규칙이라
//! 단위 테스트가 닿는 자리에 둔다.

const std = @import("std");
const git_status = @import("git_status.zig");

/// 목록에 세울 항목 하나. 문자열은 호출자 것을 빌린다(할당 없음).
pub const Entry = struct {
    /// 절대 경로. **키다** — 초안·감시·쓰기가 전부 이 값을 쓴다.
    path: []const u8,
    /// 이 항목이 딸린 **주 워크트리 경로**. 워크트리면 자기 경로와 다르다.
    ///
    /// 화면이 "누구의 워크트리인가"를 말할 수 있어야 같은 이름의 워크트리 둘을 구별한다. **우리가 선
    /// 자리가 아니라 git이 말한 주 워크트리**다 — 그러지 않으면 워크트리에 선 터미널에서 신원이 뒤집힌다.
    origin: []const u8,
    /// 주 워크트리(= 저장소 루트 자신)인가. 화면이 아이콘을 가른다.
    primary: bool,
};

pub const Collected = struct {
    entries: []const Entry,
    /// 상한에 걸려 못 담은 것이 있나. **조용히 자르지 않는다** — 화면이 그 사실을 적어야 사용자가
    /// "없다"와 "안 보여 준다"를 구별한다.
    truncated: bool,
};

/// 목록 상한. 넘으면 `truncated`로 말한다.
///
/// 8인 이유: 읽기가 항목마다 한 벌(status·numstat 셋)이고 §6이 그걸 **순차로** 돌리게 하므로, 상한이
/// 곧 첫 화면이 뜨기까지의 시간이다. 실사용에서 동시에 보는 저장소가 여덟을 넘는 일은 드물다.
pub const max_entries: usize = 8;

/// 저장소 루트 하나와 그 워크트리 경로들.
pub const Repo = struct {
    root: []const u8,
    /// `git worktree list`가 준 경로들. 주 워크트리(루트 자신)도 보통 여기 들어 있다 — 중복은 아래가 지운다.
    worktrees: []const []const u8 = &.{},
    /// **주 워크트리 경로**(`git worktree list --porcelain`의 첫 줄 — git이 그렇게 낸다). 비어 있으면
    /// 아직 못 읽은 것이라 `root`를 주 워크트리로 친다.
    ///
    /// 이것이 없으면 판정이 **우리가 어디에 서 있는가**로 흘러간다: 링크된 워크트리에 선 터미널에서는
    /// 그 워크트리가 `root`가 되어 주 워크트리로 그려지고, 진짜 주 워크트리가 딸린 것으로 뒤집힌다
    /// (제품 캡처 2026-08-17).
    main: []const u8 = "",
};

/// 저장소들을 목록 항목으로 편다.
///
/// **순서는 들어온 순서**다(사용자가 연 순서 — 터미널 순서). 정렬하면 터미널을 하나 열 때마다 목록이
/// 통째로 재배열되어, 방금 누른 자리에 다른 저장소가 온다.
///
/// **중복은 경로로 지운다.** 워크트리에 선 터미널이 있으면 그 경로가 ⑴ 자기 저장소 루트로 한 번,
/// ⑵ 주 저장소의 워크트리 목록으로 또 한 번 들어온다.
pub fn collect(repos: []const Repo, out: []Entry) Collected {
    var n: usize = 0;
    var truncated = false;
    for (repos) |repo| {
        // 루트 자신이 먼저다 — 워크트리 목록의 순서는 git이 정하고, 화면에서는 "이 저장소" 다음에
        // "그 워크트리들"이 오는 것이 읽기 쉽다. **주/부 판정은 git이 준 주 워크트리 경로로 한다.**
        const main = if (repo.main.len > 0) repo.main else repo.root;
        if (!append(out, &n, .{
            .path = repo.root,
            .origin = main,
            .primary = std.mem.eql(u8, repo.root, main),
        })) {
            truncated = true;
            break;
        }
        for (repo.worktrees) |wt| {
            if (std.mem.eql(u8, wt, repo.root)) continue; // 위에서 이미 넣었다
            if (!append(out, &n, .{
                .path = wt,
                .origin = main,
                .primary = std.mem.eql(u8, wt, main),
            })) {
                truncated = true;
                break;
            }
        }
        if (truncated) break;
    }
    return .{ .entries = out[0..n], .truncated = truncated };
}

/// 이미 있으면 넣지 않고 true(성공)로 친다. 자리가 없으면 false.
fn append(out: []Entry, n: *usize, entry: Entry) bool {
    for (out[0..n.*]) |existing| {
        if (std.mem.eql(u8, existing.path, entry.path)) return true;
    }
    if (n.* == out.len or n.* == max_entries) return false;
    out[n.*] = entry;
    n.* += 1;
    return true;
}

/// **지금 읽고 있는 저장소를 목록 맨 앞에 세운다**(이미 있으면 그대로 둔다). 새 개수를 준다.
///
/// 이 불변식이 깨지면 화면이 조용히 거짓말을 한다: 활성 저장소의 파일 줄은 그 머리 줄 **아래**에만
/// 붙으므로, 목록에 그 저장소가 없으면 **읽어 둔 변경이 통째로 안 보인다**. 터미널이 상한만큼 다른
/// 저장소에 서 있고 활성 저장소가 파일 트리에서 온 경우가 그렇다 — 그래서 자리가 차 있으면
/// **맨 뒤를 밀어낸다**(상한은 지키되 불변식을 먼저 지킨다).
pub fn ensureListed(roots: [][]const u8, count: usize, active: []const u8) usize {
    for (roots[0..count]) |root| {
        if (std.mem.eql(u8, root, active)) return count;
    }
    if (roots.len == 0) return count;
    var i = @min(count, roots.len - 1);
    while (i > 0) : (i -= 1) roots[i] = roots[i - 1];
    roots[0] = active;
    return if (count < roots.len) count + 1 else count;
}

/// 머리 줄 하나가 쓰는 요약. `git status --porcelain=v2 --branch` **하나**에서 전부 나온다 —
/// 그것이 비활성 저장소를 가볍게 읽을 수 있는 근거다(§3.5.1c).
pub const Summary = struct {
    /// 체크아웃된 브랜치의 짧은 이름. 분리 HEAD면 빈 문자열이다.
    branch: []const u8 = "",
    detached: bool = false,
    /// 변경된 파일 수(추적되지 않은 것 포함 — 목록이 세는 것과 같은 집합).
    count: u32 = 0,
    ahead: u32 = 0,
    behind: u32 = 0,
    has_ab: bool = false,
};

/// status 출력을 머리 줄 요약으로 줄인다. **문자열은 입력을 빌린다**(할당 없음).
pub fn summarize(status_text: []const u8) Summary {
    const head = git_status.parseHead(status_text);
    var count: u32 = 0;
    var it = git_status.iterate(status_text);
    while (it.next()) |_| count += 1;
    return .{
        .branch = if (head.detached) "" else (head.branch orelse ""),
        .detached = head.detached,
        .count = count,
        .ahead = head.ahead,
        .behind = head.behind,
        .has_ab = head.has_ab,
    };
}

const testing = std.testing;

test "status 하나로 머리 줄이 필요한 것을 다 얻는다" {
    // 이것이 비활성 저장소를 가볍게 읽는 근거다 — numstat 셋·merge-base·branch 범위는 펼쳤을 때만 쓴다.
    const text =
        \\# branch.oid abc123
        \\# branch.head feature/x
        \\# branch.upstream origin/feature/x
        \\# branch.ab +2 -1
        \\1 .M N... 100644 100644 100644 aaa bbb one.txt
        \\1 A. N... 000000 100644 100644 000000 ccc two.txt
        \\? three.txt
        \\
    ;
    const got = summarize(text);
    try testing.expectEqualStrings("feature/x", got.branch);
    try testing.expect(!got.detached);
    try testing.expectEqual(@as(u32, 3), got.count); // 추적되지 않은 것도 목록이 세는 집합에 든다
    try testing.expectEqual(@as(u32, 2), got.ahead);
    try testing.expectEqual(@as(u32, 1), got.behind);
    try testing.expect(got.has_ab);
}

test "분리 HEAD는 브랜치가 아니라 그 사실로 말한다" {
    // 브랜치 이름 자리에 `(detached)`가 오므로 그것을 이름으로 그리면 화면이 거짓말을 한다.
    const got = summarize("# branch.oid abc\n# branch.head (detached)\n");
    try testing.expectEqualStrings("", got.branch);
    try testing.expect(got.detached);
    try testing.expectEqual(@as(u32, 0), got.count);
}

test "변경이 없으면 0이다(못 읽은 것과는 호출자가 구별한다)" {
    const got = summarize("# branch.head main\n");
    try testing.expectEqual(@as(u32, 0), got.count);
    try testing.expectEqualStrings("main", got.branch);
}

test "저장소 다음에 그 워크트리들이 온다(주 워크트리는 한 번만)" {
    const repos = [_]Repo{.{
        .root = "/repo",
        .worktrees = &.{ "/repo", "/wt-a", "/wt-b" }, // git은 주 워크트리도 함께 준다
    }};
    var buf: [8]Entry = undefined;
    const got = collect(&repos, &buf);
    try testing.expectEqual(@as(usize, 3), got.entries.len);
    try testing.expectEqualStrings("/repo", got.entries[0].path);
    try testing.expect(got.entries[0].primary);
    try testing.expectEqualStrings("/wt-a", got.entries[1].path);
    try testing.expect(!got.entries[1].primary);
    try testing.expectEqualStrings("/repo", got.entries[1].origin); // 누구의 워크트리인지 남는다
    try testing.expect(!got.truncated);
}

test "워크트리에 선 터미널이 있어도 두 줄이 되지 않는다" {
    // 그 경로는 자기 저장소 루트로 한 번, 주 저장소의 워크트리 목록으로 또 한 번 들어온다.
    const repos = [_]Repo{
        .{ .root = "/repo", .worktrees = &.{ "/repo", "/wt-a" } },
        .{ .root = "/wt-a", .worktrees = &.{ "/repo", "/wt-a" } },
    };
    var buf: [8]Entry = undefined;
    const got = collect(&repos, &buf);
    try testing.expectEqual(@as(usize, 2), got.entries.len);
    try testing.expectEqualStrings("/repo", got.entries[0].path);
    try testing.expectEqualStrings("/wt-a", got.entries[1].path);
    // **먼저 들어온 쪽의 신원을 지킨다** — 나중 것으로 덮으면 목록이 터미널 순서에 따라 흔들린다.
    try testing.expect(!got.entries[1].primary);
}

test "순서는 들어온 순서다(정렬하지 않는다)" {
    // 정렬하면 터미널을 하나 열 때마다 목록이 재배열되어, 방금 누른 자리에 다른 저장소가 온다.
    const repos = [_]Repo{
        .{ .root = "/z-repo" },
        .{ .root = "/a-repo" },
    };
    var buf: [8]Entry = undefined;
    const got = collect(&repos, &buf);
    try testing.expectEqualStrings("/z-repo", got.entries[0].path);
    try testing.expectEqualStrings("/a-repo", got.entries[1].path);
}

test "상한을 넘으면 자르되 **그 사실을 말한다**" {
    var roots: [10][]const u8 = undefined;
    var repos: [10]Repo = undefined;
    inline for (0..10) |i| {
        roots[i] = std.fmt.comptimePrint("/repo-{d}", .{i});
        repos[i] = .{ .root = roots[i] };
    }
    var buf: [16]Entry = undefined;
    const got = collect(&repos, &buf);
    try testing.expectEqual(max_entries, got.entries.len);
    try testing.expect(got.truncated); // 조용히 자르면 사용자는 없는 저장소를 없다고 믿는다
}

test "빈 입력은 빈 목록이다(자르지 않았다고 말한다)" {
    var buf: [4]Entry = undefined;
    const got = collect(&.{}, &buf);
    try testing.expectEqual(@as(usize, 0), got.entries.len);
    try testing.expect(!got.truncated);
}

test "활성 저장소는 이미 있으면 자리를 지킨다(목록이 재배열되지 않는다)" {
    var roots = [_][]const u8{ "/a", "/b", "/c" };
    const slice: [][]const u8 = roots[0..];
    try testing.expectEqual(@as(usize, 3), ensureListed(slice, 3, "/b"));
    try testing.expectEqualStrings("/a", roots[0]); // 앞으로 끌어오면 누를 자리가 프레임마다 움직인다
}

test "활성 저장소가 없으면 맨 앞에 선다" {
    var roots: [4][]const u8 = undefined;
    roots[0] = "/a";
    roots[1] = "/b";
    const slice: [][]const u8 = roots[0..];
    try testing.expectEqual(@as(usize, 3), ensureListed(slice, 2, "/z"));
    try testing.expectEqualStrings("/z", roots[0]);
    try testing.expectEqualStrings("/a", roots[1]);
    try testing.expectEqualStrings("/b", roots[2]);
}

test "자리가 차 있어도 활성 저장소는 들어간다(맨 뒤를 밀어낸다)" {
    // 건너뛰면 **읽어 둔 변경이 통째로 안 보인다** — 파일 줄은 그 머리 줄 아래에만 붙기 때문이다.
    var roots = [_][]const u8{ "/a", "/b", "/c" };
    const slice: [][]const u8 = roots[0..];
    try testing.expectEqual(@as(usize, 3), ensureListed(slice, 3, "/z"));
    try testing.expectEqualStrings("/z", roots[0]);
    try testing.expectEqualStrings("/a", roots[1]);
    try testing.expectEqualStrings("/b", roots[2]); // "/c"가 밀려났다(상한은 지킨다)
}

test "링크된 워크트리에 서 있어도 주 워크트리는 git이 말한 그것이다" {
    // 우리가 어디에 서 있는가로 판정하면 **아이콘과 신원이 뒤집힌다**: 워크트리에 선 터미널에서는
    // 그 워크트리가 루트가 되기 때문이다(제품 캡처 2026-08-17에서 실제로 그랬다).
    const repos = [_]Repo{.{
        .root = "/wt-a", // 우리가 선 자리
        .worktrees = &.{ "/repo", "/wt-a" },
        .main = "/repo", // git이 첫 줄로 말한 주 워크트리
    }};
    var buf: [8]Entry = undefined;
    const got = collect(&repos, &buf);
    try testing.expectEqual(@as(usize, 2), got.entries.len);
    try testing.expectEqualStrings("/wt-a", got.entries[0].path);
    try testing.expect(!got.entries[0].primary); // 우리가 선 자리라고 주 워크트리가 되지 않는다
    try testing.expectEqualStrings("/repo", got.entries[1].path);
    try testing.expect(got.entries[1].primary);
    try testing.expectEqualStrings("/repo", got.entries[0].origin); // 누구의 워크트리인가도 그 값이다
}
