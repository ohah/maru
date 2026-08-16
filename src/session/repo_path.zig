//! 저장소 루트 **안쪽**을 가리키는 상대경로인지 판정한다(L2 순수, docs/editor-surface-tooling.md §6).
//!
//! **왜 필요한가**: diff는 남의 코드를 보려고 만든 기능이라 **적대적일 수 있는 저장소를 여는 것이 정상 사용**이다.
//! 저장소에 `key.txt -> ~/.ssh/id_rsa` 같은 심링크나 `../..` 경로가 들어 있어도, 읽은 내용은 신뢰 origin 웹뷰로
//! 들어간다. 가장 강한 방어는 이미 구조에 있고(브리지가 경로 인자를 받지 않는다 — §6), 이 모듈은 **우리 자신의
//! 버그와 이상한 git 출력**에 대한 심층 방어다.
//!
//! 여기서는 문자열만 본다. 심링크는 문자열로 알 수 없으므로 여는 쪽이 component마다 no-follow로 막는다(L4).

const std = @import("std");
const path_shape = @import("../path_shape.zig");

/// 저장소 루트 기준 상대경로로 **안전한가**. 거부 사유는 다섯이다:
/// ⑴ 빈 경로 ⑵ **절대경로**(POSIX `/`·Windows 드라이브 `C:`·UNC — `path_shape.isAbsolute`) ⑶ **역슬래시**
/// ⑷ `..`/`.` 세그먼트(루트 밖·자기 참조) ⑸ NUL(C 문자열 절단으로 다른 파일 지정).
///
/// 빈 세그먼트(`a//b`)도 거부한다 — 정상 git 출력에 없고, 정규화 없이 그대로 이어 붙이는 우리 쪽 규약을 단순하게
/// 유지한다(경로를 "고쳐서" 통과시키지 않는다 — 고치면 무엇을 읽는지가 호출자 눈에 안 보인다).
///
/// **역슬래시를 왜 따로 막는가**: 세그먼트를 `/`로만 쪼개므로 `..\..\secret`은 **세그먼트가 하나**여서 `..`
/// 검사를 그대로 통과한다. POSIX에서는 그것이 `..\..\secret`이라는 이름의 파일이라 무해하지만, Windows에서는
/// 진짜 상위 이동이라 **루트 밖으로 나간다**. git은 출력 경로에 항상 `/`를 쓰므로 정상 입력을 잃지 않는다.
/// (docs/windows-platform.md §5 — 절대경로 판정을 `[0]=='/'`에서 떼어내는 작업의 일부.)
pub fn isSafeRelative(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path_shape.isAbsolute(path)) return false;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return false;

    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (segment.len == 0) return false; // 빈 세그먼트(`a//b`, 끝의 `/`)
        if (std.mem.eql(u8, segment, "..")) return false;
        if (std.mem.eql(u8, segment, ".")) return false;
    }
    return true;
}

const testing = std.testing;

test "정상 상대경로만 통과한다" {
    try testing.expect(isSafeRelative("src/main.zig"));
    try testing.expect(isSafeRelative("a.txt"));
    try testing.expect(isSafeRelative("깊은/경로/한글.md")); // 비ASCII도 정상 경로다
    try testing.expect(isSafeRelative("dot.files/.gitignore")); // 점으로 시작하는 이름은 `.` 세그먼트가 아니다
}

test "루트 밖을 가리키거나 모호한 경로는 거부한다" {
    try testing.expect(!isSafeRelative("")); // 빈 경로
    try testing.expect(!isSafeRelative("/etc/passwd")); // 절대경로
    try testing.expect(!isSafeRelative("../outside.txt")); // 부모로 탈출
    try testing.expect(!isSafeRelative("a/../../b")); // 중간에서 탈출
    try testing.expect(!isSafeRelative("./a.txt")); // 자기 참조 세그먼트
    try testing.expect(!isSafeRelative("a//b")); // 빈 세그먼트
    try testing.expect(!isSafeRelative("a/")); // 끝의 슬래시
    try testing.expect(!isSafeRelative("a\x00b")); // NUL — C 문자열이 여기서 잘려 다른 파일을 가리킨다
}

// 이 가드는 `/`로만 세그먼트를 쪼갠다. 그래서 예전에는 **역슬래시가 통째로 한 세그먼트 안에 숨어** `..` 검사를
// 그대로 지나갔다 — POSIX에서는 그런 이름의 파일일 뿐이라 무해했지만 Windows에서는 진짜 상위 이동이라
// **루트 밖으로 나간다.** 절대경로 판정도 `[0]=='/'`라 드라이브 절대·UNC를 상대로 통과시켰다.
// (docs/windows-platform.md §5)
test "Windows 경로 모양도 거부한다 — 역슬래시 탈출과 드라이브·UNC 절대" {
    // 역슬래시 탈출: `/`로 쪼개면 세그먼트가 하나라 옛 `..` 검사를 통과했다.
    try testing.expect(!isSafeRelative("..\\..\\secret"));
    try testing.expect(!isSafeRelative("a\\..\\..\\b"));
    try testing.expect(!isSafeRelative("a\\b")); // 정상 git 출력은 항상 `/`라 잃는 입력이 없다

    // 드라이브 절대(두 구분자 모두)와 드라이브 상대.
    try testing.expect(!isSafeRelative("C:\\Windows\\System32"));
    try testing.expect(!isSafeRelative("C:/Windows/System32"));
    try testing.expect(!isSafeRelative("C:relative"));

    // UNC.
    try testing.expect(!isSafeRelative("\\\\server\\share"));
    try testing.expect(!isSafeRelative("//server/share"));

    // 드라이브 문자처럼 **생겼을 뿐인** 이름은 계속 통과한다(정상 파일을 막지 않는다).
    try testing.expect(isSafeRelative("C/main.zig"));
    try testing.expect(isSafeRelative("src/c.zig"));
}

test "`..`를 포함하는 **이름**은 통과한다(세그먼트만 본다)" {
    // `..hidden`은 부모가 아니라 그냥 파일 이름이다 — 이름 안의 점을 이유로 막으면 정상 파일을 못 연다.
    try testing.expect(isSafeRelative("..hidden"));
    try testing.expect(isSafeRelative("a/..b/c"));
}

/// 화면에 보일 경로. `root` 아래면 **그 아래만** 남기고, 아니면 받은 것을 그대로 돌려준다.
///
/// **왜 필요한가.** 헤더 밴드는 한 줄이라 폭이 좁고, 넘치면 앞을 생략한다(`appendEllipsizedTitle`의
/// `.head`). 절대경로를 그대로 주면 그 좁은 폭이 `/Users/이름/Documents/...`에 쓰이고, 정작 사용자가
/// 알고 싶은 저장소 안 위치가 밀려 나간다. 루트 기준으로 자르면 같은 폭에 의미 있는 구간이 들어온다
/// (VSCode가 workspace 상대로 보이는 것과 같은 이유).
///
/// **경계를 문자로 확인한다.** 단순 접두 비교는 `/a/proj`가 `/a/project/x`에 걸린다 — 두 경로는 아무
/// 관계가 없는데 `/x`만 남아 **엉뚱한 위치를 보여준다.**
///
/// 할당하지 않는다(입력의 부분 슬라이스다).
pub fn displayRelative(path: []const u8, root: []const u8) []const u8 {
    if (root.len == 0 or path.len == 0) return path;
    // 루트의 끝 구분자는 무시한다(`/a/b`와 `/a/b/`가 같은 뜻이다).
    var r = root;
    while (r.len > 1 and r[r.len - 1] == '/') r = r[0 .. r.len - 1];
    if (path.len < r.len or !std.mem.eql(u8, path[0..r.len], r)) return path;
    if (path.len == r.len) return std.fs.path.basename(path); // 루트 자신이면 이름만
    if (path[r.len] != '/') return path; // 경계가 아니다 — `/a/proj` vs `/a/project`
    var rest = path[r.len + 1 ..];
    while (rest.len > 0 and rest[0] == '/') rest = rest[1..]; // `//` 방어
    return if (rest.len == 0) std.fs.path.basename(path) else rest;
}

test "루트 아래면 그 아래만 남는다" {
    try std.testing.expectEqualStrings(
        "src/session/editor/diff.zig",
        displayRelative("/Users/u/work/maru/src/session/editor/diff.zig", "/Users/u/work/maru"),
    );
    // 끝 구분자가 있어도 같다.
    try std.testing.expectEqualStrings(
        "a.zig",
        displayRelative("/repo/a.zig", "/repo/"),
    );
}

test "루트 밖이면 그대로 둔다 — 특히 접두만 같은 경로" {
    // **이것이 이 함수의 존재 이유 절반이다.** 접두 비교만 하면 `/a/project/x`가 `/a/proj` 아래로
    // 보여 `ect/x`가 남는다 — 아무 관계 없는 두 경로인데 화면은 그럴듯한 위치를 말한다.
    try std.testing.expectEqualStrings("/a/project/x", displayRelative("/a/project/x", "/a/proj"));
    try std.testing.expectEqualStrings("/other/x", displayRelative("/other/x", "/repo"));
}

test "루트가 없거나 경로가 루트 자신이면" {
    try std.testing.expectEqualStrings("/a/b", displayRelative("/a/b", ""));
    try std.testing.expectEqualStrings("repo", displayRelative("/x/repo", "/x/repo"));
    try std.testing.expectEqualStrings("repo", displayRelative("/x/repo/", "/x/repo"));
    try std.testing.expectEqualStrings("", displayRelative("", "/x"));
}

/// 헤더 breadcrumb를 어느 루트 기준으로 보일지 고른다(순수). 빈 문자열이면 자르지 않는다.
///
/// **비교가 먼저다.** 비교는 자기가 읽은 저장소를 아는데, 활성 저장소는 그 사이 다른 곳으로 옮겨 갈 수
/// 있다 — 그때 활성 기준으로 자르면 **같은 화면이 창 상태에 따라 다른 경로**를 말한다.
///
/// **탐색기 루트는 하나일 때만 쓴다.** 여럿이면 어느 기준인지 모호하고, 잘못 고르면 화면이 **다른
/// 저장소의 위치**를 말한다 — 그것은 자르지 않는 것보다 나쁘다(긴 절대경로는 불편할 뿐 틀리지 않는다).
pub fn breadcrumbRoot(
    diff_repo: []const u8,
    git_repo: []const u8,
    tree_root_count: usize,
    tree_root_first: []const u8,
) []const u8 {
    if (diff_repo.len > 0) return diff_repo;
    if (git_repo.len > 0) return git_repo;
    if (tree_root_count == 1 and tree_root_first.len > 0) return tree_root_first;
    return "";
}

test "루트 선택: 비교 > 활성 저장소 > 탐색기 루트 하나" {
    try std.testing.expectEqualStrings("/diff", breadcrumbRoot("/diff", "/git", 1, "/tree"));
    try std.testing.expectEqualStrings("/git", breadcrumbRoot("", "/git", 1, "/tree"));
    try std.testing.expectEqualStrings("/tree", breadcrumbRoot("", "", 1, "/tree"));
}

test "탐색기 루트가 여럿이면 자르지 않는다 — 다른 저장소의 위치를 말하게 된다" {
    // 잘못 고르면 화면이 그럴듯하지만 **틀린** 위치를 말한다. 자르지 않으면 길 뿐 틀리지 않는다.
    try std.testing.expectEqualStrings("", breadcrumbRoot("", "", 2, "/tree-a"));
    try std.testing.expectEqualStrings("", breadcrumbRoot("", "", 0, ""));
}

/// 링크된 워크트리의 `.git` **파일** 내용에서 실제 git 디렉터리를 푼다.
///
/// **왜 필요한가.** 워크트리에서는 `.git`이 디렉터리가 아니라 `gitdir: <경로>` 한 줄이 든 파일이고,
/// index·HEAD는 그 경로(`<주 저장소>/.git/worktrees/<이름>/`) 아래에 산다. 그래서 `.git`을 감시하면
/// **아무 일도 안 일어난다** — `git add`는 그 파일을 건드리지 않는다(실측: mtime 불변).
///
/// 형식은 git이 문서화한 대로다: `gitdir: ` 접두 + 경로 + 개행. 경로는 절대일 수도 상대(워크트리
/// 디렉터리 기준)일 수도 있어 호출자가 `worktree_dir`을 준다.
///
/// 반환은 `buf`의 앞부분이다. 형식이 아니면 null — **추측하지 않는다**(엉뚱한 디렉터리를 감시하면
/// 갱신이 안 되는 것을 넘어 남의 저장소 변화에 반응한다).
pub fn gitDirFromDotGitFile(content: []const u8, worktree_dir: []const u8, buf: []u8) ?[]const u8 {
    const prefix = "gitdir:";
    if (!std.mem.startsWith(u8, content, prefix)) return null;
    var value = content[prefix.len..];
    // 첫 줄만 쓴다(뒤에 무엇이 오든 경로는 한 줄이다).
    if (std.mem.indexOfAny(u8, value, "\r\n")) |end| value = value[0..end];
    value = std.mem.trim(u8, value, " \t");
    if (value.len == 0) return null;

    if (std.fs.path.isAbsolute(value)) {
        if (value.len > buf.len) return null;
        @memcpy(buf[0..value.len], value);
        return buf[0..value.len];
    }
    // 상대 경로는 **워크트리 디렉터리 기준**이다. 합쳐서 돌려주되 정규화(`..` 접기)는 하지 않는다 —
    // 감시 대상은 커널이 여는 경로이고, 커널이 그 해석을 한다.
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ worktree_dir, value }) catch null;
}

test "워크트리 `.git` 파일에서 실제 git 디렉터리를 푼다" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    // 실측 형식(2026-08-16, git worktree add): 접두 + 절대경로 + 개행.
    try std.testing.expectEqualStrings(
        "/repo/.git/worktrees/wt",
        gitDirFromDotGitFile("gitdir: /repo/.git/worktrees/wt\n", "/wt", &buf).?,
    );
    // 공백이 없는 판·CRLF·뒤에 다른 줄이 붙은 판도 같은 답이어야 한다.
    try std.testing.expectEqualStrings("/a/b", gitDirFromDotGitFile("gitdir:/a/b", "/wt", &buf).?);
    try std.testing.expectEqualStrings("/a/b", gitDirFromDotGitFile("gitdir: /a/b\r\n", "/wt", &buf).?);
    try std.testing.expectEqualStrings("/a/b", gitDirFromDotGitFile("gitdir: /a/b\nextra\n", "/wt", &buf).?);
}

test "상대 경로는 워크트리 디렉터리 기준이다" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expectEqualStrings(
        "/wt/../.git/worktrees/wt",
        gitDirFromDotGitFile("gitdir: ../.git/worktrees/wt\n", "/wt", &buf).?,
    );
}

test "형식이 아니면 추측하지 않는다(엉뚱한 디렉터리를 감시하지 않는다)" {
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    try std.testing.expect(gitDirFromDotGitFile("", "/wt", &buf) == null);
    try std.testing.expect(gitDirFromDotGitFile("ref: refs/heads/main\n", "/wt", &buf) == null); // HEAD 파일을 잘못 읽은 경우
    try std.testing.expect(gitDirFromDotGitFile("gitdir:\n", "/wt", &buf) == null); // 값이 비었다
    try std.testing.expect(gitDirFromDotGitFile("gitdir:   \n", "/wt", &buf) == null);
}
