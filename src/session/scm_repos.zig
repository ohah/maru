//! 소스 컨트롤 도크가 세울 **저장소 목록**을 만드는 순수 층(docs/editor-surface-dock.md §3.5.1c).
//!
//! 목록의 단위는 저장소가 아니라 **워크트리**다 — 링크된 워크트리는 자기 루트·index·HEAD를 갖는 독립된
//! 작업 대상이고, 화면에서도 각각 한 줄이다.
//!
//! 이 파일은 git을 부르지 않는다. 호출자가 ⑴ 터미널들이 선 저장소 루트와 ⑵ 각 루트의 워크트리 경로를
//! 이미 구해서 넣고, 여기서는 **순서·중복·상한**만 정한다. 그 셋이 화면에 그대로 보이는 규칙이라
//! 단위 테스트가 닿는 자리에 둔다.

const std = @import("std");

/// 목록에 세울 항목 하나. 문자열은 호출자 것을 빌린다(할당 없음).
pub const Entry = struct {
    /// 절대 경로. **키다** — 초안·감시·쓰기가 전부 이 값을 쓴다.
    path: []const u8,
    /// 이 항목을 낳은 저장소의 주 루트. 워크트리면 자기 경로와 다르다.
    ///
    /// 화면이 "누구의 워크트리인가"를 말할 수 있어야 같은 이름의 워크트리 둘을 구별한다.
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
        // "그 워크트리들"이 오는 것이 읽기 쉽다.
        if (!append(out, &n, .{ .path = repo.root, .origin = repo.root, .primary = true })) {
            truncated = true;
            break;
        }
        for (repo.worktrees) |wt| {
            if (std.mem.eql(u8, wt, repo.root)) continue; // 주 워크트리는 위에서 이미 넣었다
            if (!append(out, &n, .{ .path = wt, .origin = repo.root, .primary = false })) {
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

const testing = std.testing;

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
