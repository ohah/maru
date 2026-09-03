//! 도크 소스 컨트롤 뷰가 실행할 **git 명령줄을 만드는 순수 모듈**(L4가 그대로 spawn한다).
//!
//! 왜 argv 조립을 L2로 빼는가: 안전 조건이 전부 **인자와 환경변수**에 있기 때문이다(docs/editor-surface-tooling.md §6).
//! 실행 코드와 섞으면 "이 플래그가 정말 붙었나"를 프로세스를 띄우지 않고는 못 본다. 여기 있으면 헤드리스 테스트가
//! 플래그 하나하나를 전수로 고정한다.
//!
//! **읽기 전용 계약**(§6 — 각 항목이 아래 상수 하나와 1:1이다):
//! - 셸·alias를 거치지 않는다. `sh -c`도, `git` alias 확장도 없다 — 호출자는 이 argv를 그대로 `execve`한다.
//!   **예외 하나: 원격(SSH)**. `ssh <dest> <cmd>` 는 원격 로그인 셸에 문자열을 넘기므로 이 조항이 원격에서만
//!   성립하지 않는다. 그 예외는 아래 «원격(SSH) 실행» 절 안으로 좁혀 두었고(인용·검증·덮어쓰기 보존),
//!   계약은 [docs/plans/remote-scm.md](../../docs/plans/remote-scm.md) §2.2 가 소유한다.
//! - repository config가 **외부 프로세스를 실행하지 못하게** 한다: external diff·textconv·pager·hook·credential helper를
//!   전부 빈 값으로 덮어쓴다. 악성 저장소가 `diff.external=curl …`을 넣어 둬도 우리가 실행하지 않는다.
//! - **index를 건드리지 않는다**: `GIT_OPTIONAL_LOCKS=0`. 이게 없으면 `git status`가 index를 refresh하며 `index.lock`을
//!   잡아, 사용자가 같은 저장소에서 돌리는 다른 git이 실패할 수 있다(읽기 화면이 쓰기를 방해하면 안 된다).
//! - **네트워크·프롬프트 없음**: `GIT_TERMINAL_PROMPT=0` + credential helper 제거. status/diff는 원래 로컬이지만,
//!   설정으로 원격을 건드리게 만드는 경로를 명시적으로 닫는다.

const std = @import("std");
const remote_shell = @import("remote_shell.zig");
const git_log = @import("git_log.zig"); // 커밋 목록 `--format`의 단일 출처(파싱과 같은 상수)

/// 뷰가 필요로 하는 읽기 명령. 셋을 합쳐 네 섹션과 행의 증감을 채운다(§3.5).
pub const Kind = enum {
    /// 네 섹션의 상태 문자 + 브랜치/upstream/ahead·behind를 **한 번에**. `--branch` 덕에 rev-list가 따로 필요 없다.
    status,
    /// 파일 탐색기의 **무시된 항목 판정**(`check-ignore -z <경로들>`). 무시된 경로만 NUL 구분으로 돌아온다.
    ///
    /// **왜 `status --ignored` 가 아닌가**: 그건 무시된 트리 *안까지* 열거해 `node_modules` 같은 곳에서
    /// 비용이 폭발한다. 탐색기는 "지금 펼쳐 보이는 항목"만 알면 되므로 질의 범위가 화면에 비례하는 편이
    /// 맞다(사용자 결정 2026-08-18). `.gitignore` 를 우리가 파싱하는 선택지는 부정·중첩·`**` 문법을 다시
    /// 구현해야 하고 git 과 미세하게 어긋날 수 있어 택하지 않았다 — 판정 권위는 git 에 남긴다.
    ///
    /// **`--stdin` 이 아니라 인자로 넘기는 이유**: 이 backend 의 실행 경로(fork+exec+pipe)는 stdout 만
    /// 읽는다. stdin 파이프를 더하는 것은 저수준 변경이라, 같은 정확도를 argv 배치로 얻는다 —
    /// `checkIgnoreBatch` 가 한 번에 넘길 수 있는 개수를 알려 주고 호출자가 그만큼씩 끊는다.
    check_ignore,
    /// **목록 행의 +N -N** (`HEAD ↔ 작업트리`). 2판은 파일 하나가 한 행이고 그 행의 기본 비교가 HEAD 기준이므로
    /// 증감도 같은 범위여야 한다 — index 기준 숫자를 쓰면 화면의 `+3 -1`과 눌러서 열리는 diff의 줄 수가 다르다
    /// (docs/editor-surface-dock.md §3.5.2). **unborn(첫 커밋 전)에서는 실패한다** — HEAD가 없다. 그건 오류가 아니라
    /// 그 상태의 정상이고, 호출자가 `numstat_staged`를 대신 쓴다(그때는 추적된 파일이 전부 index에 새로 올라간 것이다).
    numstat_head,
    /// 스테이지된 변경의 +N -N (`HEAD ↔ index`). unborn 폴백이자, 컨텍스트 메뉴의 스테이지 쪽 비교가 쓴다.
    numstat_staged,
    /// 아직 스테이지되지 않은 변경의 +N -N (`index ↔ worktree`).
    numstat_worktree,
    /// **기본 브랜치 대비 ahead/behind**(`rev-list --count --left-right origin/HEAD...HEAD`).
    ///
    /// **`status --branch`의 `# branch.ab`를 쓰지 않는 이유**(§3.5): 그 값은 `@{u}` 기준인데 PR 브랜치의
    /// upstream은 보통 `origin/<자기 브랜치>`라 **항상 `0 0`**이 나온다(실측 2026-08-18: 이 저장소의 작업
    /// 브랜치에서 `# branch.ab +0 -0`인데 `origin/HEAD` 기준으로는 `0 1`이었다). 리뷰가 알고 싶은 것은
    /// "기본 브랜치 대비 내 브랜치"다.
    ///
    /// **삼점이다.** `A...B`는 양쪽의 공통 조상 이후만 센다 — 두 점(`A..B`)이면 기준이 갈린 뒤 기본
    /// 브랜치에 쌓인 커밋이 behind에 안 잡힌다.
    ///
    /// 출력은 `<behind>\t<ahead>` 한 줄이다(왼쪽 = origin/HEAD에만 있는 것 = 내가 뒤처진 수).
    /// **실패해도 목록은 성립한다** — origin/HEAD가 없거나 unborn이면 호출자가 `@{u}` 값으로 되돌아간다.
    ahead_behind,
    /// 기준으로 **고를 수 있는 이름들**(§3.5). `branches`와 같은 형식이되 원격 추적 ref까지 본다.
    base_candidates,
    /// **기준 브랜치 이름 자체**(`rev-parse --abbrev-ref origin/HEAD` → `origin/main`). §3.5 표의 첫 명령이고,
    /// 네트워크 없이 로컬에서 읽힌다.
    ///
    /// **왜 따로 읽나**: `ahead_behind`의 실패만으로는 "기준이 없다"와 "HEAD가 unborn이다"를 가를 수 없다.
    /// 두 상태의 답이 다르다 — 앞은 사용자가 기준을 골라야 하고, 뒤는 첫 커밋을 하면 저절로 풀린다.
    /// 이 읽기는 unborn 저장소에서도 성공하므로(원격 HEAD는 로컬 HEAD와 무관하다) 그 둘을 가른다.
    default_base,
    /// 턴 스냅샷 ①: 임시 index를 HEAD로 채운다(`read-tree HEAD`). 진짜 index는 안 건드린다 — `GIT_INDEX_FILE`이
    /// 가리키는 파일만 쓴다. 그 파일은 **저장소 밖**에 둔다(안에 두면 그 파일 자체가 diff에 잡힌다).
    snapshot_read_tree,
    /// 턴 스냅샷 ②: 그 임시 index에 작업트리를 반영한다(`add -A`). 작업트리는 안 바뀐다.
    snapshot_add,
    /// 턴 스냅샷 ③: 그 index를 tree 하나로 굳힌다(`write-tree`). 이 tree OID가 "그 턴이 끝난 순간"이다.
    snapshot_write_tree,
    /// 로컬 브랜치 목록(`for-each-ref refs/heads/`). 상태바 브랜치 항목을 눌렀을 때 고를 목록이다.
    ///
    /// **왜 `branch --list`가 아닌가**: `branch`는 pager·색·컬럼을 타는 porcelain이라 출력이 설정과 터미널 폭에
    /// 따라 흔들린다. `for-each-ref`는 plumbing이라 `--format`이 곧 계약이고 정렬도 우리가 정한다.
    ///
    /// **읽기 전용 계약 안이다**: refs를 읽기만 하고 index·작업트리·네트워크를 건드리지 않는다. 이 목록으로
    /// 브랜치를 **바꾸는 일은 우리가 하지 않는다** — 고른 이름을 활성 터미널에 `git switch <name>`으로 넣어
    /// 주고 실행은 사용자 셸이 한다(hook·dirty tree·충돌이 평소처럼 사용자에게 보인다).
    branches,
    /// **저장소 루트**(`rev-parse --show-toplevel`). 로컬은 walk-up 으로 알지만 **원격은 물어봐야 한다** —
    /// 원격 경로를 로컬 파일시스템에 대고 걸을 수 없기 때문이다(RS3 — [계획](../../docs/plans/remote-scm.md)).
    ///
    /// 목록(`status`)은 루트 없이도 `-C <cwd>` 로 돌지만, **작업트리 파일을 읽으려면** 루트가 있어야
    /// 상대경로를 절대경로로 만들 수 있다. 그래서 이 읽기는 원격 diff 가 생기면서 필요해졌다.
    repo_root,
    /// 이 저장소에 등록된 **원격 이름들**(`git remote`). 도크의 `Fetch` 버튼을 켤지 정하는 유일한 사실이다
    /// (§3.5 — "원격 없는 저장소의 Fetch"는 **비활성으로 보여 주고 이유를 말한다"). 없는 것을 눌러 보고
    /// 실패로 배우게 하지 않는다.
    ///
    /// **네트워크를 쓰지 않는다.** `git remote`는 config에 적힌 이름을 읽을 뿐이라 읽기 계약 안이다
    /// (`-v`가 아니므로 URL도 싣지 않는다 — 우리는 존재 여부만 알면 되고, URL에는 `user@host`가 들어간다).
    remotes,
    /// 이 저장소에 딸린 **워크트리 목록**(`worktree list --porcelain`). 도크가 저장소마다 한 줄이 아니라
    /// **워크트리마다 한 줄**을 세우기 때문에 필요하다(§3.5.1c — 사용자가 목표 화면을 제시했다).
    ///
    /// **`--porcelain`이다.** 사람이 읽는 판(`worktree list`)은 열 폭에 맞춰 공백으로 정렬하므로 경로에
    /// 공백이 있으면 파싱이 갈린다. porcelain은 `worktree <경로>` / `HEAD <oid>` / `branch <ref>` 또는
    /// `detached`가 한 줄씩이고 빈 줄로 끊긴다 — 실측 형식(2026-08-16)이 그대로 계약이다.
    ///
    /// 읽기 전용이다: 등록된 목록을 읽기만 하고 만들거나 지우지 않는다.
    worktree_list,
    /// 히스토리 탭의 **커밋 목록**(`git log --format=…`). 형식의 단일 출처는 `session/git_log.zig`이고
    /// 여기서는 그 상수를 그대로 인자로 싣는다 — 두 곳에 적으면 한쪽만 고쳐져 파싱이 조용히 어긋난다.
    ///
    /// **`--no-decorate`가 아니라 `%D`다**: decoration을 형식 안에서 받으면 `log.decorate` 설정과 무관하게
    /// 우리가 정한 자리에 오고, 괄호·색이 붙지 않는다.
    ///
    /// 상한(`-n`)은 호출자가 인자로 준다 — 화면이 "더 보기"로 늘릴 수 있어야 하므로 명령이 그 수를 고정하면 안 된다.
    log,
    /// 커밋 하나가 **바꾼 파일들**(P4b): `git show --format= --raw --numstat <oid>`.
    ///
    /// **`git diff <oid>^ <oid>`가 아니다** — 루트 커밋에는 `^`가 없어 그 명령이 실패한다. `show`는
    /// 루트 커밋도 "전부 새로 생긴 파일"로 낸다.
    ///
    /// **`--first-parent -m`**: 병합 커밋은 기본적으로 아무 파일도 안 낸다(combined diff를 생략한다).
    /// 첫 부모 기준으로 보면 한 줄에 한 상태라 이 목록의 모양과 맞는다(combined diff는 파일마다 상태가
    /// 여럿이다).
    ///
    /// **증감도 같은 프로세스에서 읽는다**(2026-08-27 — 사용자 요청 「라인 몇 개 바뀐지」). 옛 판단은
    /// "numstat은 프로세스를 하나 더 쓴다"였는데, 그 전제가 `--name-status`였다: 그 옵션은 `--numstat`과
    /// 같은 출력 그룹이라 함께 걸면 **뒤에 온 쪽만** 나온다(실측 git 2.50.1). `--raw`는 다른 그룹이라
    /// 둘이 나란히 오므로 프로세스는 그대로 하나다.
    commit_files,
    /// 턴 하나가 바꾼 파일들(P5): `git diff --raw --numstat <treeA> <treeB>`.
    ///
    /// **양쪽 다 tree다** — 그래서 작업트리가 어떻게 바뀌든 그 턴의 목록은 고정된다(§3.5.4가 타임라인을
    /// 두 스냅샷 사이로 잡은 이유). 두 rev는 `arg`에 `<A> <B>`로 붙여 넘긴다.
    turn_name_status,
    /// diff 본문 한쪽(원본)을 통째로: `git show <spec>`. spec은 `blobSpec`이 만든 `HEAD:<경로>` 또는 `:<경로>`다.
    /// **worktree 쪽은 이 경로로 읽지 않는다** — 디스크 파일을 그대로 읽으면 되고, git을 한 번 덜 띄운다.
    show_blob,
};

/// 워크트리 하나. 문자열은 전부 `text`를 빌린다(할당 없음).
pub const Worktree = struct {
    /// 절대 경로. 이것이 도크 목록의 **키**다(저장소 루트와 같은 축 — 워크트리는 자기 루트를 갖는다).
    path: []const u8,
    /// 체크아웃된 브랜치의 짧은 이름. 분리 HEAD면 빈 문자열이고 `head` 앞자리가 그 자리를 대신한다.
    branch: []const u8 = "",
    /// HEAD OID(짧게 자르지 않는다 — 자르는 것은 화면의 몫이다). 아직 커밋이 없으면 빈 문자열.
    head: []const u8 = "",
    /// 분리 HEAD인가. **`branch.len == 0`으로 대신 판정하지 않는다** — unborn(커밋 전)도 브랜치가 비는데
    /// 그건 분리가 아니다(화면 문구가 달라야 한다).
    detached: bool = false,
    /// git이 "정리해도 된다"고 표시한 워크트리 — **디렉터리가 사라졌다**. 화면은 이 줄을 세우지 않는다:
    /// 그 자리에 커밋 상자를 달아도 커밋할 대상이 없고, 읽기는 실패만 되풀이한다.
    prunable: bool = false,
};

/// `worktree list --porcelain` 출력을 쪼갠다. **할당하지 않는다** — `out`을 채우고 개수를 돌려준다.
///
/// 형식(실측 2026-08-16): 항목마다 `worktree <경로>` 줄로 시작하고, `HEAD <oid>`·`branch <ref>` 또는
/// `detached`가 뒤따르며 **빈 줄로 끊긴다**. 마지막 항목 뒤에도 빈 줄이 있을 수 있다.
///
/// **모르는 줄은 건너뛴다**(`bare`·`locked`·`prunable` 등 git이 더할 수 있다) — 그것들 때문에 항목 전체를
/// 버리면 사용자의 워크트리가 목록에서 통째로 사라진다.
pub fn collectWorktrees(text: []const u8, out: []Worktree) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (line.len == 0) continue;
        if (std.mem.startsWith(u8, line, "worktree ")) {
            if (n == out.len) break; // 더 담을 자리가 없다 — 호출자가 `count == out.len`으로 안다
            out[n] = .{ .path = line["worktree ".len..] };
            n += 1;
            continue;
        }
        if (n == 0) continue; // `worktree` 줄 없이 온 속성은 주인이 없다
        const item = &out[n - 1];
        if (std.mem.startsWith(u8, line, "HEAD ")) {
            item.head = line["HEAD ".len..];
        } else if (std.mem.startsWith(u8, line, "branch ")) {
            const ref = line["branch ".len..];
            // `refs/heads/<이름>` → 짧은 이름. 접두가 없으면 그대로 둔다(추측하지 않는다).
            item.branch = if (std.mem.startsWith(u8, ref, "refs/heads/")) ref["refs/heads/".len..] else ref;
        } else if (std.mem.eql(u8, line, "detached")) {
            item.detached = true;
        } else if (std.mem.eql(u8, line, "prunable") or std.mem.startsWith(u8, line, "prunable ")) {
            // 형식이 둘이다: 사유가 붙는 `prunable <reason>`과 사유 없는 줄. 둘 다 같은 사실이다.
            item.prunable = true;
        }
    }
    return n;
}

test "worktree list --porcelain을 항목으로 쪼갠다(실측 형식)" {
    const text =
        \\worktree /repo
        \\HEAD 423e22f89fd4c3e0c9e8b96a6134225f4d45cd24
        \\branch refs/heads/feat/scm-repo-list
        \\
        \\worktree /tmp/wt
        \\HEAD 423e22f89fd4c3e0c9e8b96a6134225f4d45cd24
        \\detached
        \\
    ;
    var out: [4]Worktree = undefined;
    const n = collectWorktrees(text, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("/repo", out[0].path);
    try std.testing.expectEqualStrings("feat/scm-repo-list", out[0].branch); // refs/heads/ 접두를 뗀다
    try std.testing.expect(!out[0].detached);
    try std.testing.expectEqualStrings("/tmp/wt", out[1].path);
    try std.testing.expectEqualStrings("", out[1].branch);
    try std.testing.expect(out[1].detached);
    try std.testing.expectEqualStrings("423e22f89fd4c3e0c9e8b96a6134225f4d45cd24", out[1].head);
}

test "경로에 공백이 있어도 갈리지 않는다(사람이 읽는 판을 안 쓰는 이유)" {
    const text = "worktree /Users/a b/c d\nHEAD abc\nbranch refs/heads/main\n";
    var out: [2]Worktree = undefined;
    try std.testing.expectEqual(@as(usize, 1), collectWorktrees(text, &out));
    try std.testing.expectEqualStrings("/Users/a b/c d", out[0].path);
}

test "모르는 줄이 있어도 그 항목을 버리지 않는다" {
    // git이 `bare`·`locked`·`prunable`을 더할 수 있다. 그것 때문에 사용자의 워크트리가 목록에서
    // 사라지면 화면이 사실보다 적게 말한다.
    const text = "worktree /repo\nHEAD abc\nbranch refs/heads/main\nlocked\nprunable gitdir file removed\n";
    var out: [2]Worktree = undefined;
    try std.testing.expectEqual(@as(usize, 1), collectWorktrees(text, &out));
    try std.testing.expectEqualStrings("main", out[0].branch);
}

test "버퍼가 차면 거기서 멈춘다(조용히 자르지 않는다 — 호출자가 셀 수 있다)" {
    const text = "worktree /a\nworktree /b\nworktree /c\n";
    var out: [2]Worktree = undefined;
    try std.testing.expectEqual(@as(usize, 2), collectWorktrees(text, &out));
    try std.testing.expectEqualStrings("/b", out[1].path);
}

test "주인 없는 속성 줄은 무시한다(출력이 잘려서 시작한 경우)" {
    var out: [2]Worktree = undefined;
    try std.testing.expectEqual(@as(usize, 0), collectWorktrees("HEAD abc\nbranch refs/heads/x\n", &out));
}

/// `for-each-ref` 출력을 브랜치 이름 슬라이스로 쪼갠다. **할당하지 않는다** — `out`을 채우고 개수를 돌려주며,
/// 각 슬라이스는 `text`를 빌린다(호출자가 text를 살려 둬야 한다).
///
/// 빈 줄과 `\r`은 버린다(CRLF 저장소·마지막 개행). `out`이 차면 거기서 멈춘다 — 조용히 자르는 게 아니라
/// 호출자가 `count == out.len`으로 "더 있다"를 알 수 있다.
pub fn collectBranches(text: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        if (n == out.len) break;
        const line = if (raw.len > 0 and raw[raw.len - 1] == '\r') raw[0 .. raw.len - 1] else raw;
        if (line.len == 0) continue;
        out[n] = line;
        n += 1;
    }
    return n;
}

/// 브랜치 전환 **명령 문자열**을 만든다(터미널에 넣어 줄 텍스트). 우리가 실행하지 않는다.
///
/// **개행을 붙이지 않는다.** 붙이면 그 순간 실행돼 dirty tree·hook 결과를 사용자가 보기 전에 일이 벌어진다.
/// 엔터는 사용자가 친다 — 그래서 이 함수의 계약에 "개행 없음"이 포함된다.
///
/// 이름에 공백·따옴표 같은 셸 메타문자가 있으면 **null**을 돌려준다. git이 허용하는 refname에는 공백이
/// 없지만, 목록이 손상됐을 때 우리가 셸에 이상한 것을 넣지 않도록 입구에서 막는다.
pub fn branchSwitchCommand(name: []const u8, buf: []u8) ?[]const u8 {
    if (name.len == 0) return null;
    for (name) |c| {
        if (c <= 0x20 or c == 0x7f) return null; // 제어문자·공백
        switch (c) {
            '\'', '"', '\\', '$', '`', ';', '&', '|', '<', '>', '(', ')', '{', '}', '*', '?', '[', ']', '!', '#', '~' => return null,
            else => {},
        }
    }
    return std.fmt.bufPrint(buf, "git switch {s}", .{name}) catch null;
}

/// `git show`에 넘길 blob 지정자를 `buf`에 만든다. 할당하지 않는다.
///
/// **인자 주입이 불가능한 형태**다: 결과는 항상 `HEAD:` 또는 `:`로 시작하므로 경로가 `-`로 시작해도 옵션으로
/// 해석되지 않는다. 경로는 **저장소 루트 기준 상대경로**여야 한다(git의 `<rev>:<path>` 규약).
pub fn blobSpec(side: BlobSide, repo_relative_path: []const u8, buf: []u8) ?[]const u8 {
    const prefix = switch (side) {
        .head => "HEAD:",
        .index => ":",
    };
    if (prefix.len + repo_relative_path.len > buf.len) return null; // 자른 경로로 다른 파일을 읽지 않는다
    @memcpy(buf[0..prefix.len], prefix);
    @memcpy(buf[prefix.len..][0..repo_relative_path.len], repo_relative_path);
    return buf[0 .. prefix.len + repo_relative_path.len];
}

pub const BlobSide = enum {
    /// 마지막 커밋의 내용(`HEAD ↔ index` 비교의 왼쪽).
    head,
    /// index(스테이지 영역)의 내용. `index ↔ worktree` 비교의 왼쪽이자 `HEAD ↔ index`의 오른쪽이다.
    index,
};

/// 임의 커밋의 blob 지정자(`<hex>:<path>`). "브랜치에 COMMIT 됨"의 왼쪽(merge-base)을 읽을 때 쓴다.
///
/// **rev는 hex 해시만 받는다.** 사용자가 고른 문자열이 아니라 우리가 `merge-base`에서 받은 값이고, 여기서 형태를
/// 강제하면 그 값이 어떤 경로로 오염돼도 `--upload-pack=…` 같은 인자로 해석될 수 없다(길이·문자 둘 다 본다).
/// 이 문자열을 **rev 자리에 그대로 넘겨도 되는가**. hex OID만 통과한다 — `--upload-pack=…` 같은 값이
/// rev 자리에 오면 git 인자가 되어 우리가 닫아 둔 경로(외부 프로세스)를 다시 연다(§6 심층 방어).
///
/// 판정을 한 자리에 둔다: blob spec 둘과 커밋 파일 목록 읽기가 같은 술어를 쓴다.
pub fn isHexRev(rev: []const u8) bool {
    if (rev.len < 7 or rev.len > 64) return false;
    for (rev) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!hex) return false;
    }
    return true;
}

pub fn commitBlobSpec(rev: []const u8, repo_relative_path: []const u8, buf: []u8) ?[]const u8 {
    if (!isHexRev(rev)) return null;
    if (rev.len + 1 + repo_relative_path.len > buf.len) return null;
    @memcpy(buf[0..rev.len], rev);
    buf[rev.len] = ':';
    @memcpy(buf[rev.len + 1 ..][0..repo_relative_path.len], repo_relative_path);
    return buf[0 .. rev.len + 1 + repo_relative_path.len];
}

/// `<rev>^:<경로>` — 그 커밋의 **부모** 쪽 blob(P4b). 루트 커밋에서는 git이 실패하고, 그게 곧
/// "왼쪽이 없다"이다(호출자가 그 실패를 정상으로 읽는다).
pub fn commitParentBlobSpec(rev: []const u8, repo_relative_path: []const u8, buf: []u8) ?[]const u8 {
    if (!isHexRev(rev)) return null; // 임의 문자열을 rev로 넘기지 않는다(인자 주입 차단)
    if (rev.len + 2 + repo_relative_path.len > buf.len) return null;
    @memcpy(buf[0..rev.len], rev);
    buf[rev.len] = '^';
    buf[rev.len + 1] = ':';
    @memcpy(buf[rev.len + 2 ..][0..repo_relative_path.len], repo_relative_path);
    return buf[0 .. rev.len + 2 + repo_relative_path.len];
}

/// 비교의 **기준**(base) — 기본값은 `origin/HEAD`가 가리키는 기본 브랜치다(docs/editor-surface-dock.md §3.5).
/// 이 값 하나가 ahead/behind·merge-base·브랜치 범위 diff 셋 모두의 왼쪽이다: 셋이 서로 다른 기준을 쓰면
/// 화면의 `↑N`과 그 아래 "브랜치에 COMMIT 됨" 목록이 **다른 질문의 답**이 된다.
pub const default_base_ref = "origin/HEAD";

/// 같은 기준의 삼점 범위. `A...B`는 공통 조상 이후만 센다 — 두 점이면 기준에 새로 쌓인 커밋이 behind에서 빠진다.
pub const default_base_range = default_base_ref ++ "...HEAD";

/// git의 refname 상한이 아니라 **우리가 argv에 싣는 상한**이다. 이보다 긴 이름은 받지 않는다.
pub const max_base_ref_len = 255;
pub const max_base_range_len = max_base_ref_len + "...HEAD".len;

/// 이 문자열을 **기준 자리에 그대로 넘겨도 되는가**(`isHexRev`와 같은 규율의 술어다).
///
/// 기준은 `isHexRev`가 받는 값과 달리 **사용자가 고른 이름**이라 형태를 우리가 강제해야 한다:
/// - `-`로 시작하면 git이 rev가 아니라 **옵션**으로 읽는다(`--upload-pack=…` — 우리가 닫아 둔 경로가 열린다).
/// - `..`가 들어가면 우리가 붙이는 `...HEAD`와 합쳐져 **다른 범위**가 된다(기준 하나가 두 점 범위로 둔갑한다).
/// - 그 밖의 글자는 허용 목록으로 막는다. `^`·`~`·`:`·`@{`는 전부 rev 문법이라 이름이 식으로 바뀐다.
///
/// 허용을 좁게 잡은 대가로 `@{u}` 같은 정당한 식도 못 쓰지만, 기준 목록은 우리가 읽은 ref 이름에서 오므로
/// 그 손해가 없다(고르는 쪽이 식을 타이핑하지 않는다).
pub fn isSafeBaseRef(ref: []const u8) bool {
    if (ref.len == 0 or ref.len > max_base_ref_len) return false;
    if (ref[0] == '-' or ref[0] == '/' or ref[0] == '.') return false;
    if (ref[ref.len - 1] == '/' or ref[ref.len - 1] == '.') return false;
    if (std.mem.indexOf(u8, ref, "..") != null) return false;
    if (std.mem.indexOf(u8, ref, "//") != null) return false;
    for (ref) |c| {
        const ok = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            c == '_' or c == '-' or c == '.' or c == '/' or c == '+';
        if (!ok) return false;
    }
    return true;
}

/// `<기준>...HEAD`. 기준이 위 술어를 통과하지 못하면 null이고, 그때 호출자는 기본값으로 돌아간다 —
/// **거절이 곧 기본값이 아니다**: 되돌리는 판단은 호출자가 하고, 여기서는 "이 이름은 못 싣는다"만 말한다.
pub fn baseRange(base: []const u8, buf: *[max_base_range_len]u8) ?[]const u8 {
    if (!isSafeBaseRef(base)) return null;
    @memcpy(buf[0..base.len], base);
    const tail = "...HEAD";
    @memcpy(buf[base.len..][0..tail.len], tail);
    return buf[0 .. base.len + tail.len];
}

/// 어떤 kind든 이만큼이면 담긴다(테스트가 상한을 고정한다). config 쌍을 늘리면 여기도 함께 늘려야 한다 —
/// 넘치면 조용히 잘리는 게 아니라 buf 범위를 벗어난다(quotePath 추가 때 실제로 넘쳤다).
pub const max_argv = 32; // 기본 3 + `--no-optional-locks` + config 덮어쓰기 14 + kind별 최대 10 + 여유

/// repository config가 외부 프로세스를 실행하지 못하게 덮어쓰는 `-c` 쌍. **빈 값 = 비활성**이 git의 규약이다.
const config_overrides = [_][]const u8{
    // ⚠️ **읽기가 index 를 다시 쓰지 않게 한다**(적대적 검증 2026-09-03 2 회차 — 실측).
    //
    // **읽기가 `.git` 을 건드려 감시자를 깨운다.** 그러면 그 깨움이 읽기를 부르고, 그 읽기가 또
    // 깨워서 **자기 자신을 부른다.** 원격 감시(RW3)에서 눈에 보였다: 파일 두 개를 고쳤는데 원격 git
    // 명령이 **54 개**(≈5~6 사이클) 돌았고, 고친 뒤엔 **9 개**(정확히 한 사이클)다.
    //
    // **어느 파일이 그 이벤트를 내는지도 실측으로 갈랐다**(2026-09-04). 이벤트가 실어 오는 «이름»을
    // 찍는 진단 감시자를 제품과 같은 마스크로 띄우고, 갓 더럽힌 저장소에서:
    //   일반 status              → `.git/index.lock` CREATE·MODIFY·MOVED_FROM, 이어서 `.git/index` MOVED_TO
    //   --no-optional-locks      → 없음
    //   진짜 파일 변경(대조군)    → 작업트리 파일 MODIFY 하나
    //
    // 즉 잠금 파일과 index 재기록은 **따로가 아니라 한 동작**이다 — git 은 `index.lock` 에 쓴 뒤 그것을
    // `index` 위로 rename 한다(원자적 쓰기). 원시 이벤트 4 개가 read 배치 2 번으로 묶여 앞서 «깨움 2»
    // 로 보였던 것이다.
    //
    // 대가도 쟀다: `core.untrackedCache` 는 **기본이 꺼짐**이라 이 플래그가 잃을 캐시가 없고, 억지로
    // 켜 두고 5 만 파일(추적 2 만·미추적 3 만)에서 재도 일반 0.11~0.13 s vs 플래그 0.08~0.12 s 로
    // 불리하지 않으며 출력은 동일하다.
    //
    // 즉 이 플래그는 **우리가 만든 소음만** 없애고 진짜 변경은 그대로 통과시킨다. git 이 이 용도로
    // 둔 옵션이다(잠금이 필요한 «선택» 작업 — index 새로 쓰기 — 을 건너뛴다).
    "--no-optional-locks",
    "-c", "core.pager=cat", //            pager 프로세스 실행·페이지네이션 금지
    "-c", "core.hooksPath=/dev/null", //  훅 실행 금지(저장소가 심어 둔 스크립트)
    "-c", "diff.external=", //            external diff 프로그램 금지
    "-c", "credential.helper=", //        자격증명 helper 프로세스 금지
    "-c", "protocol.ext.allow=never", //  ext:: 원격 = 임의 명령 실행 벡터
    // 경로를 **있는 그대로** 받는다. 기본값(true)이면 비ASCII 경로를 `"\355\225\234..."`처럼 C-quote해서 내주는데,
    // 그 문자열을 다시 git에 넘기거나 open(2)에 쓰면 "그런 파일 없음"이 된다 — 한글·일본어 파일명이 전부 안 열렸다.
    "-c", "core.quotePath=false",
    // **비교 알고리즘을 못 박는다.** `--numstat`이 주는 `+N -N`은 사용자의 `diff.algorithm` 설정을 따르는데,
    // 본문(네이티브 differ)은 Myers 최소 편집이라 설정이 `histogram`이면 두 숫자가 갈린다 — 실측으로
    // 같은 입력에서 기본 `+250 -190` 대 histogram `+1756 -1696`(7배)이 나왔다. 목록과 본문이 같은 판정을
    // 쓰게 하려면 여기서 정해야 한다(docs/native-editor-ui.md §7).
    "-c", "diff.algorithm=myers",
};

/// 하위 프로세스에 **덮어써서** 넘길 환경변수. 상속만 하면 사용자 환경의 GIT_* 가 계약을 깬다.
pub const env_overrides = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "GIT_OPTIONAL_LOCKS", .value = "0" }, // index.lock을 잡지 않는다(읽기가 쓰기를 방해하지 않게)
    .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" }, // 어떤 경우에도 입력을 기다리지 않는다
    .{ .name = "GIT_CONFIG_NOSYSTEM", .value = "1" }, // /etc/gitconfig 의 외부 프로그램 설정 배제
    .{ .name = "GIT_PAGER", .value = "cat" },
    .{ .name = "GIT_ASKPASS", .value = "" },
    .{ .name = "GIT_LFS_SKIP_SMUDGE", .value = "1" }, // smudge 필터 프로세스 금지
};

/// `git_exe`와 `repo`를 받아 argv를 `buf`에 채우고 그 슬라이스를 돌려준다. 할당하지 않는다.
/// `git_exe`는 호출자가 **절대 경로로 해석해 둔** 실행 파일이다 — PATH 탐색을 이 모듈이 하지 않는 이유는
/// PATH hijack을 막는 책임이 "무엇을 실행할지 고르는" 쪽(L4)에 있어서다(§6).
/// `check-ignore` 한 번에 넘길 수 있는 경로 개수. `build` 가 만드는 고정 접두(exe·-C·repo·config
/// 덮어쓰기·서브커맨드·-z)를 뺀 나머지다. 호출자는 이 크기로 끊어 여러 번 부른다.
pub const check_ignore_batch: usize = blk: {
    var buf: [max_argv][]const u8 = undefined;
    const prefix = build(.check_ignore, "git", "/", null, &buf);
    break :blk max_argv - prefix.len;
};

/// `check-ignore` argv — 고정 접두 뒤에 경로들을 붙인다. `paths.len` 은 `check_ignore_batch` 이하여야
/// 한다(넘으면 잘라 낸다 — argv 를 넘겨 exec 이 실패하는 것보다 덜 그린 편이 낫다).
pub fn buildCheckIgnore(git_exe: []const u8, repo: []const u8, paths: []const []const u8, buf: *[max_argv][]const u8) []const []const u8 {
    const prefix = build(.check_ignore, git_exe, repo, null, buf);
    var n = prefix.len;
    for (paths[0..@min(paths.len, check_ignore_batch)]) |path| {
        buf[n] = path;
        n += 1;
    }
    return buf[0..n];
}

// ── 원격(SSH) 실행 ────────────────────────────────────────────────────────────
//
// RS1 — [계획](../../docs/plans/remote-scm.md). 활성 pane 이 원격이면 도크는 **그 원격 저장소**를 본다.
// 그러려면 같은 argv 를 원격에서 돌려야 하는데, `ssh <dest> <command>` 는 **원격 로그인 셸**에 문자열
// 하나를 넘긴다 — 이 모듈 머리의 「셸을 거치지 않는다」 조항이 원격에서만 성립하지 않는다.
//
// 그래서 예외를 **이 절 안으로 좁힌다**: 인용·검증·덮어쓰기 보존을 여기 순수 함수가 전부 지고, L4 는
// 결과 argv 를 그대로 exec 한다. 안전 조건이 실행 코드에 흩어지지 않아야 헤드리스로 전수 고정된다.

/// 원격 실행 대상. 전송 규율(`ssh -S …`)은 [remote_shell](remote_shell.zig) 이 소유한다.
pub const Remote = remote_shell.Remote;

/// 원격 명령 문자열 상한. `check-ignore` 처럼 경로가 여럿 붙는 kind 가 가장 길고, 경로마다 인용이
/// 붙으므로 로컬 argv 보다 커진다. 넘으면 **자르지 않고 명령을 만들지 않는다** — 잘린 셸 명령은
/// 「덜 실행되는 것」이 아니라 **다른 명령**이다.
pub const max_remote_command_bytes = remote_shell.max_command_bytes;

/// 원격 argv 는 항상 이 길이·이 모양이다 — 토큰 여덟 개다:
/// `/usr/bin/env ssh -o BatchMode=yes -S <ctl> <dest> <cmd>`.
///
/// **`env` 를 앞에 두는 이유**: 실행 층은 `execve(argv[0])` 라 argv[0] 이 **절대경로**여야 하는데
/// (`git_backend.spawnCapture`), `ssh` 의 설치 위치는 시스템마다 다르다(`/usr/bin` · brew). `env(1)` 가
/// PATH 에서 찾게 한다 — `ssh_upload.zig` 가 같은 이유로 같은 모양을 쓴다.
///
/// `BatchMode=yes` 는 이 모듈의 「프롬프트 없음」 조항을 전송 층까지 잇는다 — 소켓이 사라진 순간
/// 비밀번호를 묻는 대신 실패해야 한다.
pub const remote_argv_len = remote_shell.ssh_argv_len;

/// 원격 명령의 셸 규율은 [remote_shell](remote_shell.zig) 이 소유한다 — PATH 처방과 `sh` 껍데기가
/// 왜 그 형태인지(csh·fish 실측 포함) 그쪽 머리말에 있다. 여기서 다시 정의하지 않는다: 같은 처방을
/// 세 곳에 적어 두었다가 **세 곳이 나란히 틀렸다.**
const remote_path_script = remote_shell.exec_args_script;

/// 원격에서 부를 git. **PATH 로 찾는다** — 로컬은 절대경로 계약이지만(§6 PATH hijack) 원격의 설치
/// 위치는 우리가 모른다(계약 §2.2 ⑷). 그 대신 원격 명령의 모든 토큰은 우리가 만든 것이고 사용자 입력이
/// 토큰 자리에 들어가지 않는다.
pub const remote_git_exe = "git";

/// 원격 명령에 실을 수 있는 토큰인가. 제어문자가 하나라도 있으면 **거부**한다.
///
/// 인용만으로도 셸에는 안전하지만, 그런 값이 왔다는 것 자체가 관측(OSC 7 경로·dest)이 오염됐다는
/// 뜻이다 — 그때 할 일은 「안전하게 실행」이 아니라 실행하지 않는 것이다.
pub const remoteTokenIsSafe = remote_shell.tokenIsSafe;

const quoteAppend = remote_shell.quoteAppend;

/// 로컬 argv 를 **원격에서 같은 뜻이 되는 한 줄**로 인용해 `cmd_buf` 에 쓰고, 그것을 실어 나를 `ssh`
/// argv 를 `buf` 에 채운다. 할당하지 않는다.
///
/// **`local_argv[0]`(로컬 git 절대경로)은 버린다** — 원격에서는 `remote_git_exe` 다. 나머지 토큰
/// (`-C <repo>` · config 덮어쓰기 · 서브커맨드 · 인자)은 **하나도 빠짐없이** 그대로 실린다: 로컬에서 닫아
/// 둔 구멍(pager·hook·external diff·credential helper)이 원격에서 열리면 안 된다.
///
/// **env 도 함께 싣는다**(`env K=V … git …`). 원격 셸은 우리 프로세스의 env 를 물려받지 않으므로,
/// 여기서 안 실으면 `GIT_OPTIONAL_LOCKS=0` 같은 조항이 원격에서만 조용히 사라진다.
///
/// null 인 경우는 셋뿐이고 전부 **실행하지 않는 편이 옳은** 상태다: 토큰에 제어문자가 있다 · `dest` 나
/// `control_path` 가 모양을 못 갖췄다 · 명령이 `cmd_buf` 를 넘는다.
pub fn buildRemote(
    local_argv: []const []const u8,
    remote: Remote,
    buf: *[max_argv][]const u8,
    cmd_buf: []u8,
) ?[]const []const u8 {
    if (local_argv.len < 2) return null; // 최소 `git -C <repo>` 는 있어야 한다
    // dest·control socket 검증은 `remoteArgv` 가 진다(두 빌더가 같은 판정을 공유한다).

    var n: usize = 0;
    // **POSIX sh 를 한 겹 씌운다**(근거는 `remote_path_script` 주석) — 로그인 셸은 인용된 토큰만 본다.
    n = remote_shell.appendShPrologue(cmd_buf, n, remote_path_script) orelse return null;
    n = quoteAppend(cmd_buf, n, "env") orelse return null;
    for (env_overrides) |override| {
        if (!remoteTokenIsSafe(override.name) or !remoteTokenIsSafe(override.value)) return null;
        // `K=V` 를 **한 토큰으로** 인용한다 — 셸이 인용을 벗기면 env(1) 가 그대로 한 인자로 받는다.
        if (n >= cmd_buf.len) return null;
        cmd_buf[n] = ' ';
        n += 1;
        if (n >= cmd_buf.len) return null;
        cmd_buf[n] = '\'';
        n += 1;
        for (override.name) |c| {
            if (n >= cmd_buf.len) return null;
            cmd_buf[n] = c;
            n += 1;
        }
        if (n >= cmd_buf.len) return null;
        cmd_buf[n] = '=';
        n += 1;
        for (override.value) |c| {
            if (c == '\'') return null; // env 값에 작은따옴표는 이 저장소에 없다 — 생기면 그때 인용을 늘린다
            if (n >= cmd_buf.len) return null;
            cmd_buf[n] = c;
            n += 1;
        }
        if (n >= cmd_buf.len) return null;
        cmd_buf[n] = '\'';
        n += 1;
    }
    if (n >= cmd_buf.len) return null;
    cmd_buf[n] = ' ';
    n += 1;
    n = quoteAppend(cmd_buf, n, remote_git_exe) orelse return null;
    for (local_argv[1..]) |token| {
        if (!remoteTokenIsSafe(token)) return null;
        if (n >= cmd_buf.len) return null;
        cmd_buf[n] = ' ';
        n += 1;
        n = quoteAppend(cmd_buf, n, token) orelse return null;
    }

    return remoteArgv(remote, buf, cmd_buf[0..n]);
}

/// 이미 만들어 둔 **원격 명령 한 줄**을 실어 나를 `ssh` argv. `buildRemote` 와 `buildRemoteFileRead` 가
/// 이 자리를 공유한다 — 전송 옵션(`BatchMode`·`-S`)이 두 벌이 되면 한쪽만 고쳐져 새 연결이 열린다.
fn remoteArgv(remote: Remote, buf: *[max_argv][]const u8, command: []const u8) ?[]const []const u8 {
    return remote_shell.sshArgv(remote, buf, command);
}

/// 원격 파일 읽기의 상한(바이트). **원격에서 자른다** — 로컬은 받은 뒤 `max_output_bytes` 로 자르지만,
/// 원격은 그 전에 바이트가 **링크를 다 건너온다.** 느린 ssh 에서 큰 파일 하나가 세션을 멎게 하는 것이
/// 그 차이다(§4 드롭 업로드가 16 MiB 상한을 둔 것과 같은 이유).
///
/// diff 뷰어가 실제로 그리는 크기보다 넉넉하되 유계다. 잘렸는지는 **호출자가 길이로 판정한다**(로컬의
/// `truncated` 와 같은 규율).
pub const max_remote_file_bytes: usize = 4 << 20;

/// 원격의 **작업트리 파일 한 개**를 읽는 명령(RS3 — [계획](../../docs/plans/remote-scm.md)).
///
/// **git 으로는 못 읽는다.** `git show :<path>` 는 index 이고 `HEAD:<path>` 는 커밋이다 — 작업트리의
/// 지금 내용을 내는 git 명령이 없다. 그래서 이 한 자리에서만 git 이 아닌 명령을 원격에 보낸다.
///
/// `head -c <N> -- '<abs>'`: `--` 로 옵션 해석을 끊고, 경로는 `buildRemote` 와 **같은 인용 규칙**을 쓴다.
/// 절대경로만 받는다 — 상대경로는 원격 로그인 셸의 cwd(홈)에 걸려 **다른 파일**을 읽는다.
pub fn buildRemoteFileRead(
    abs_path: []const u8,
    remote: Remote,
    buf: *[max_argv][]const u8,
    cmd_buf: []u8,
) ?[]const []const u8 {
    if (abs_path.len == 0 or abs_path[0] != '/') return null;
    if (!remoteTokenIsSafe(abs_path)) return null;
    var n: usize = 0;
    // 위와 같은 껍데기 — `head` 는 보통 `/usr/bin` 에 있지만 규율을 두 갈래로 두지 않는다.
    n = remote_shell.appendShPrologue(cmd_buf, n, remote_path_script) orelse return null;
    n = quoteAppend(cmd_buf, n, "head") orelse return null;
    if (n >= cmd_buf.len) return null;
    cmd_buf[n] = ' ';
    n += 1;
    n = quoteAppend(cmd_buf, n, "-c") orelse return null;
    if (n >= cmd_buf.len) return null;
    cmd_buf[n] = ' ';
    n += 1;
    var size_buf: [24]u8 = undefined;
    const size = std.fmt.bufPrint(&size_buf, "{d}", .{max_remote_file_bytes}) catch return null;
    n = quoteAppend(cmd_buf, n, size) orelse return null;
    if (n >= cmd_buf.len) return null;
    cmd_buf[n] = ' ';
    n += 1;
    n = quoteAppend(cmd_buf, n, "--") orelse return null;
    if (n >= cmd_buf.len) return null;
    cmd_buf[n] = ' ';
    n += 1;
    n = quoteAppend(cmd_buf, n, abs_path) orelse return null;
    return remoteArgv(remote, buf, cmd_buf[0..n]);
}

pub fn build(kind: Kind, git_exe: []const u8, repo: []const u8, arg: ?[]const u8, buf: *[max_argv][]const u8) []const []const u8 {
    var n: usize = 0;
    buf[n] = git_exe;
    n += 1;
    // `-C <repo>`: cwd를 바꾸지 않고 대상 저장소를 지정한다. 프로세스 cwd를 건드리면 다른 스레드에 영향이 간다.
    buf[n] = "-C";
    n += 1;
    buf[n] = repo;
    n += 1;
    for (config_overrides) |override| {
        buf[n] = override;
        n += 1;
    }
    switch (kind) {
        .worktree_list => {
            buf[n] = "worktree";
            n += 1;
            buf[n] = "list";
            n += 1;
            buf[n] = "--porcelain";
            n += 1;
        },
        .check_ignore => {
            buf[n] = "check-ignore";
            n += 1;
            // `-z`: 출력이 NUL 구분 — 경로에 개행이 들어갈 수 있다.
            buf[n] = "-z";
            n += 1;
            // 경로는 `buildCheckIgnore` 가 이어 붙인다(이 자리는 고정 접두만 만든다).
        },
        .status => {
            buf[n] = "status";
            n += 1;
            buf[n] = "--porcelain=v2";
            n += 1;
            buf[n] = "--branch";
            n += 1;
            buf[n] = "--untracked-files=all";
            n += 1;
            buf[n] = "--renames";
            n += 1;
        },
        .numstat_head, .numstat_staged, .numstat_worktree => {
            buf[n] = "diff";
            n += 1;
            buf[n] = "--numstat";
            n += 1;
            buf[n] = "--find-renames";
            n += 1;
            // textconv/external diff는 config 덮어쓰기와 **중복으로** 끈다 — 플래그가 명령 단위 권위라 더 강하다.
            buf[n] = "--no-ext-diff";
            n += 1;
            buf[n] = "--no-textconv";
            n += 1;
            if (kind == .numstat_staged) {
                buf[n] = "--cached";
                n += 1;
            }
            if (kind == .numstat_head) {
                buf[n] = "HEAD";
                n += 1;
                // **`--`가 반드시 붙는다**(2026-08-14 실측). 저장소에 `HEAD`라는 이름의 **파일**이 있으면 git이
                // `fatal: ambiguous argument 'HEAD': both revision and filename`으로 exit 128을 낸다 — 목록 전체가
                // 증감을 잃는다. `--`는 "앞은 rev, 뒤는 경로"를 못박으므로 그 저장소에서도 정상 출력이 나온다
                // (실측: 같은 저장소에서 `--` 없이 128, 붙이면 `1\t0\tx.txt`).
                buf[n] = "--";
                n += 1;
            }
        },
        .snapshot_read_tree => {
            buf[n] = "read-tree";
            n += 1;
            buf[n] = "HEAD";
            n += 1;
        },
        .snapshot_add => {
            buf[n] = "add";
            n += 1;
            buf[n] = "-A";
            n += 1;
        },
        .snapshot_write_tree => {
            buf[n] = "write-tree";
            n += 1;
        },
        .repo_root => {
            buf[n] = "rev-parse";
            n += 1;
            buf[n] = "--show-toplevel";
            n += 1;
        },
        .remotes => {
            buf[n] = "remote";
            n += 1;
        },
        .default_base => {
            buf[n] = "rev-parse";
            n += 1;
            // `--abbrev-ref`: `refs/remotes/origin/main`이 아니라 `origin/main`으로 받는다 — 그 형태가
            // 그대로 다음 명령의 기준 자리에 들어간다(형태를 두 번 바꾸지 않는다).
            buf[n] = "--abbrev-ref";
            n += 1;
            buf[n] = default_base_ref;
            n += 1;
        },
        .ahead_behind => {
            buf[n] = "rev-list";
            n += 1;
            buf[n] = "--count";
            n += 1;
            buf[n] = "--left-right";
            n += 1;
            // `A...B` = B가 갈린 지점 이후 바꾼 것(공통 조상 기준). `A..B`(두 점)로 쓰면 기본 브랜치에 새로
            // 들어온 커밋까지 "내가 바꾼 것"으로 잡혀 숫자가 부풀어 오른다.
            //
            // `arg`는 **이미 만들어진 삼점 범위**다(`baseRange`) — 여기서 이어 붙이면 버퍼가 필요하고,
            // 그 버퍼의 수명이 argv보다 짧으면 조용히 쓰레기를 싣는다.
            buf[n] = arg orelse default_base_range;
            n += 1;
        },
        .branches, .base_candidates => {
            buf[n] = "for-each-ref";
            n += 1;
            // 최근에 쓴 브랜치가 위로 — 브랜치가 많은 저장소에서 찾는 수고를 줄인다.
            buf[n] = "--sort=-committerdate";
            n += 1;
            // 이름만. refname:short는 `refs/heads/` 접두를 뗀 값이다.
            buf[n] = "--format=%(refname:short)";
            n += 1;
            // 상한을 둔다 — 브랜치 수백 개인 저장소에서 목록이 화면을 넘고 파싱 버퍼도 커진다.
            buf[n] = "--count=200";
            n += 1;
            buf[n] = "refs/heads/";
            n += 1;
            // **기준 후보에는 원격 추적 ref도 넣는다**(§3.5). `origin/HEAD`가 없는 저장소의 대표가
            // `clone --single-branch`인데, 그 저장소에서 사용자가 고르고 싶은 기준은 보통 `origin/main`이다 —
            // 로컬 브랜치만 보여 주면 정작 필요한 이름이 목록에 없다.
            // 브랜치 **전환** 목록은 그대로 로컬만 본다: 원격 추적 ref로 checkout하면 detached HEAD가 된다.
            if (kind == .base_candidates) {
                buf[n] = "refs/remotes/";
                n += 1;
            }
        },
        .log => {
            buf[n] = "log";
            n += 1;
            // **형식은 `git_log`가 소유한다**(파싱과 같은 상수). 여기서 문자열을 다시 적으면 한쪽만
            // 고쳐져 필드가 밀린다.
            buf[n] = "--format=" ++ git_log.format_spec;
            n += 1;
            // 병합 커밋도 **한 줄**이다(`--no-merges`를 쓰지 않는다) — 히스토리에서 병합을 지우면
            // "이 브랜치가 언제 합쳐졌나"가 사라진다. 부모가 여럿이어도 우리가 그리는 것은 그 커밋 자신이다.
            //
            // `-n <상한>`은 호출자가 준다: 화면이 "더 보기"로 늘릴 수 있어야 하므로 명령이 고정하지 않는다.
            buf[n] = "-n";
            n += 1;
            buf[n] = arg orelse "200";
            n += 1;
        },
        .commit_files => {
            buf[n] = "show";
            n += 1;
            buf[n] = "--format="; // 커밋 헤더는 목록이 이미 갖고 있다 — 파일 줄만 받는다
            n += 1;
            // **`--raw`이고 `--name-status`가 아니다**: 증감을 함께 받으려면 `--numstat`을 걸어야 하는데
            // 그 둘은 같은 출력 그룹이라 **뒤에 온 쪽만** 나온다(실측 git 2.50.1). `--raw`는 다른 그룹이라
            // numstat과 나란히 오고, 상태 문자는 그 줄의 마지막 필드에 그대로 있다.
            buf[n] = "--raw";
            n += 1;
            buf[n] = "--numstat";
            n += 1;
            buf[n] = "--find-renames";
            n += 1;
            buf[n] = "--first-parent";
            n += 1;
            buf[n] = "-m";
            n += 1;
            buf[n] = "--no-ext-diff";
            n += 1;
            buf[n] = "--no-textconv";
            n += 1;
            buf[n] = arg orelse "HEAD";
            n += 1;
        },
        .turn_name_status => {
            buf[n] = "diff";
            n += 1;
            // 커밋 파일 목록과 **같은 형식**이다(위 `commit_files` 주석) — 두 탭이 같은 파서·같은 화면
            // 모양을 쓰므로 출력이 갈리면 한쪽에만 증감이 선다.
            buf[n] = "--raw";
            n += 1;
            buf[n] = "--numstat";
            n += 1;
            buf[n] = "--find-renames";
            n += 1;
            buf[n] = "--no-ext-diff";
            n += 1;
            buf[n] = "--no-textconv";
            n += 1;
            // 두 tree는 **각각의 인자**여야 한다(`A..B`는 커밋 범위 문법이라 tree에는 쓰지 않는다).
            // 호출자가 `<A> <B>`로 붙여 주고 여기서 공백에서 쪼갠다 — 이 층은 할당하지 않으므로 슬라이스만 나눈다.
            const pair = arg orelse "";
            const sep = std.mem.indexOfScalar(u8, pair, ' ') orelse pair.len;
            buf[n] = pair[0..sep];
            n += 1;
            buf[n] = if (sep < pair.len) pair[sep + 1 ..] else "";
            n += 1;
        },
        .show_blob => {
            buf[n] = "show";
            n += 1;
            // textconv는 config로도 끄지만 플래그가 명령 단위 권위라 함께 건다(numstat과 같은 규율).
            buf[n] = "--no-textconv";
            n += 1;
            buf[n] = arg orelse "";
            n += 1;
        },
    }
    return buf[0..n];
}

const testing = std.testing;

fn has(argv: []const []const u8, needle: []const u8) bool {
    for (argv) |a| if (std.mem.eql(u8, a, needle)) return true;
    return false;
}

test "경로를 C-quote하지 않게 강제한다(비ASCII 파일명)" {
    // 기본값이면 `한글.txt`가 `"\355\225\234\352\270\200.txt"`로 나와 blobSpec·open(2) 양쪽에서 실패한다.
    var buf: [max_argv][]const u8 = undefined;
    inline for (.{ Kind.status, Kind.numstat_staged, Kind.show_blob }) |kind| {
        try testing.expect(has(build(kind, "/usr/bin/git", "/repo", "HEAD:x", &buf), "core.quotePath=false"));
    }
}

test "숫자를 내는 diff는 알고리즘을 못 박는다 — 사용자 설정이 목록과 본문을 갈라놓는다" {
    // `--numstat`의 `+N -N`은 `diff.algorithm`을 따른다. 본문은 네이티브 Myers라, 사용자가
    // `histogram`을 켜 두면 같은 파일에 목록은 `+1756 -1696`, 본문은 `+250 -190`을 말한다(실측).
    // **둘 중 하나를 고쳐야 한다면 목록이다** — 본문 계산은 우리 것이고 설정을 따를 이유가 없다.
    var buf: [max_argv][]const u8 = undefined;
    inline for (.{ Kind.numstat_staged, Kind.numstat_worktree }) |kind| {
        const argv = build(kind, "/usr/bin/git", "/repo", "deadbeef", &buf);
        try testing.expect(has(argv, "diff.algorithm=myers"));
    }
}

test "status 한 번으로 섹션·브랜치·ahead/behind를 모두 요청한다" {
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.status, "/usr/bin/git", "/repo", null, &buf);
    try testing.expectEqualStrings("/usr/bin/git", argv[0]);
    try testing.expectEqualStrings("-C", argv[1]);
    try testing.expectEqualStrings("/repo", argv[2]);
    try testing.expect(has(argv, "--porcelain=v2"));
    try testing.expect(has(argv, "--branch")); // 이게 있어야 rev-list 별도 호출이 없다
    try testing.expect(has(argv, "--untracked-files=all"));
    try testing.expect(has(argv, "--renames"));
}

test "numstat은 staged/worktree를 --cached로만 가른다" {
    var buf: [max_argv][]const u8 = undefined;
    const staged = build(.numstat_staged, "/usr/bin/git", "/repo", null, &buf);
    try testing.expect(has(staged, "--numstat") and has(staged, "--cached"));

    var buf2: [max_argv][]const u8 = undefined;
    const worktree = build(.numstat_worktree, "/usr/bin/git", "/repo", null, &buf2);
    try testing.expect(has(worktree, "--numstat") and !has(worktree, "--cached"));
    try testing.expect(has(worktree, "--find-renames"));
}

test "numstat_head는 HEAD 뒤에 `--`를 붙인다(HEAD라는 이름의 파일이 있는 저장소)" {
    // 실측(2026-08-14): `HEAD`라는 **파일**이 있는 저장소에서 `git diff --numstat HEAD`는
    // `fatal: ambiguous argument 'HEAD': both revision and filename`으로 exit 128을 낸다 — 목록 전체가 증감을
    // 잃는다. `--`를 붙이면 같은 저장소에서 정상 출력이 나온다. 순서도 계약이다: rev가 `--`보다 **앞**이다.
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.numstat_head, "/usr/bin/git", "/repo", null, &buf);
    try testing.expect(has(argv, "--numstat") and !has(argv, "--cached"));
    var head_at: ?usize = null;
    var dashdash_at: ?usize = null;
    for (argv, 0..) |a, i| {
        if (std.mem.eql(u8, a, "HEAD")) head_at = i;
        if (std.mem.eql(u8, a, "--")) dashdash_at = i;
    }
    try testing.expect(head_at != null and dashdash_at != null);
    try testing.expect(head_at.? < dashdash_at.?);
    try testing.expectEqual(argv.len - 1, dashdash_at.?); // `--`가 마지막이라 경로 인자가 붙지 않는다
}

test "모든 명령이 외부 프로세스 실행 경로를 닫는다" {
    // 악성 저장소가 config에 심어 둔 프로그램을 우리가 대신 실행해 주면 안 된다(§6). kind마다 전수 확인한다.
    inline for (.{ Kind.status, Kind.numstat_staged, Kind.numstat_worktree }) |kind| {
        var buf: [max_argv][]const u8 = undefined;
        const argv = build(kind, "/usr/bin/git", "/repo", null, &buf);
        try testing.expect(has(argv, "core.pager=cat"));
        try testing.expect(has(argv, "core.hooksPath=/dev/null"));
        try testing.expect(has(argv, "diff.external="));
        try testing.expect(has(argv, "credential.helper="));
        try testing.expect(has(argv, "protocol.ext.allow=never"));
        // 셸을 거치지 않는다 — argv[0]은 우리가 받은 실행 파일 그대로다.
        try testing.expectEqualStrings("/usr/bin/git", argv[0]);
        for (argv) |a| try testing.expect(!std.mem.eql(u8, a, "-c\u{0020}sh"));
        try testing.expect(argv.len <= max_argv);
    }

    var buf: [max_argv][]const u8 = undefined;
    inline for (.{ Kind.numstat_staged, Kind.numstat_worktree }) |kind| {
        const argv = build(kind, "/usr/bin/git", "/repo", null, &buf);
        try testing.expect(has(argv, "--no-ext-diff") and has(argv, "--no-textconv"));
    }
}

test "환경 덮어쓰기가 lock·프롬프트·필터 프로세스를 막는다" {
    // 상속만 하면 사용자 환경의 GIT_* 가 계약을 깬다 — 이름이 바뀌면 이 테스트가 먼저 깨진다.
    var seen_locks = false;
    var seen_prompt = false;
    var seen_smudge = false;
    for (env_overrides) |e| {
        if (std.mem.eql(u8, e.name, "GIT_OPTIONAL_LOCKS")) {
            try testing.expectEqualStrings("0", e.value);
            seen_locks = true;
        }
        if (std.mem.eql(u8, e.name, "GIT_TERMINAL_PROMPT")) {
            try testing.expectEqualStrings("0", e.value);
            seen_prompt = true;
        }
        if (std.mem.eql(u8, e.name, "GIT_LFS_SKIP_SMUDGE")) seen_smudge = true;
    }
    try testing.expect(seen_locks and seen_prompt and seen_smudge);
}

test "show_blob은 옵션으로 해석될 수 없는 spec만 넘기고 textconv를 끈다" {
    // 경로가 `-`로 시작해도 spec은 `HEAD:`/`:`로 시작하므로 git이 옵션으로 읽지 않는다 — 인자 주입 차단.
    var spec_buf: [256]u8 = undefined;
    const head = blobSpec(.head, "-rf/evil.txt", &spec_buf).?;
    try testing.expectEqualStrings("HEAD:-rf/evil.txt", head);
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.show_blob, "/usr/bin/git", "/repo", head, &buf);
    try testing.expectEqualStrings("show", argv[argv.len - 3]);
    try testing.expectEqualStrings("--no-textconv", argv[argv.len - 2]);
    try testing.expectEqualStrings("HEAD:-rf/evil.txt", argv[argv.len - 1]);
    // 읽기 전용 계약은 kind와 무관하게 붙는다.
    try testing.expect(has(argv, "core.pager=cat"));
    try testing.expect(has(argv, "diff.external="));

    var index_buf: [256]u8 = undefined;
    try testing.expectEqualStrings(":src/main.zig", blobSpec(.index, "src/main.zig", &index_buf).?);
}

test "spec 버퍼가 모자라면 자르지 않고 실패한다(다른 파일을 읽지 않게)" {
    var tiny: [8]u8 = undefined;
    try testing.expect(blobSpec(.head, "very/long/path.txt", &tiny) == null);
}

test "argv 상한이 모든 kind를 담는다(넘치면 범위를 벗어난다)" {
    // config 쌍이 늘 때마다 조용히 깨지지 않게, 가장 긴 조합을 실제로 만들어 본다.
    var buf: [max_argv][]const u8 = undefined;
    // **`commit_files`가 지금 가장 길다**(P4c에서 `--raw --numstat` 둘이 되며 한 칸 늘었다). 그것을 빼면
    // 이 테스트는 상한이 실제로 모자란 순간을 못 본다.
    inline for (.{ Kind.status, Kind.numstat_staged, Kind.numstat_worktree, Kind.show_blob, Kind.commit_files, Kind.turn_name_status }) |kind| {
        const argv = build(kind, "/usr/bin/git", "/repo", "HEAD:x", &buf);
        try testing.expect(argv.len <= max_argv);
    }
}

test "브랜치 범위는 삼점(...)으로 물어 기본 브랜치의 새 커밋을 섞지 않는다" {
    // 이 규율의 소비자는 이제 `ahead_behind` **하나**다(브랜치 범위 파일 목록 둘은 2026-08-27 에 걷혔다 —
    // 화면이 2026-08-14 에 사라졌는데 배관만 남아 있었다). 규율 자체는 그대로 지켜야 한다: 두 점으로 물으면
    // 기본 브랜치에 새로 들어온 커밋까지 `↑N` 에 잡혀 "내가 안 보낸 커밋"이 부풀어 오른다.
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.ahead_behind, "/usr/bin/git", "/repo", null, &buf);
    try testing.expect(has(argv, "origin/HEAD...HEAD"));
    try testing.expect(!has(argv, "origin/HEAD..HEAD"));
}

test "commitBlobSpec은 hex 해시만 받는다(임의 문자열을 인자로 넘기지 않는다)" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "650a0bbef96a1dd562e0d39f262260ae002c1545:src/main.zig",
        commitBlobSpec("650a0bbef96a1dd562e0d39f262260ae002c1545", "src/main.zig", &buf).?,
    );
    try testing.expect(commitBlobSpec("--upload-pack=x", "a", &buf) == null); // 옵션처럼 생긴 값
    try testing.expect(commitBlobSpec("origin/HEAD", "a", &buf) == null); // ref 이름도 안 받는다
    try testing.expect(commitBlobSpec("abc", "a", &buf) == null); // 너무 짧다
    var tiny: [8]u8 = undefined;
    try testing.expect(commitBlobSpec("650a0bbef96a1dd5", "very/long.txt", &tiny) == null); // 자르지 않는다
}

test "턴 스냅샷은 임시 index로만 돌고 작업트리를 건드리지 않는다" {
    // `add -A`가 진짜 index에 닿으면 사용자의 스테이지 상태를 우리가 바꾸는 것이다 — 환경변수로 격리하는 것이
    // 이 기능의 안전 근거이고, argv에는 그 사실이 안 보이므로(환경은 L4가 건다) 여기서는 **명령 모양**만 고정한다.
    var buf: [max_argv][]const u8 = undefined;
    try testing.expect(has(build(.snapshot_read_tree, "/usr/bin/git", "/repo", null, &buf), "read-tree"));
    try testing.expect(has(build(.snapshot_add, "/usr/bin/git", "/repo", null, &buf), "-A"));
    try testing.expect(has(build(.snapshot_write_tree, "/usr/bin/git", "/repo", null, &buf), "write-tree"));
}

test "ahead/behind는 기본 브랜치 기준 삼점 rev-list다 (`@{u}`가 아니다)" {
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.ahead_behind, "/usr/bin/git", "/repo", null, &buf);

    try testing.expect(has(argv, "rev-list"));
    try testing.expect(has(argv, "--count"));
    try testing.expect(has(argv, "--left-right"));
    // **삼점이어야 한다.** 두 점이면 기준이 갈린 뒤 기본 브랜치에 쌓인 커밋이 behind에 안 잡힌다.
    try testing.expect(has(argv, "origin/HEAD...HEAD"));
    try testing.expect(!has(argv, "origin/HEAD..HEAD"));
    // 읽기 전용 계약(외부 프로세스 차단)은 여기에도 붙는다.
    try testing.expect(has(argv, "core.pager=cat"));
    try testing.expect(argv.len <= max_argv);
}

test "기준 읽기: 이름을 `origin/main` 형태로 받는다(refs/ 접두어가 아니라)" {
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.default_base, "/usr/bin/git", "/repo", null, &buf);

    try testing.expect(has(argv, "rev-parse"));
    // `--abbrev-ref`가 없으면 `refs/remotes/origin/main`이 나오고, 그 문자열을 다음 명령의 기준 자리에
    // 그대로 넣으면 형태가 두 가지가 된다(같은 기준이 화면에서 다르게 보인다).
    try testing.expect(has(argv, "--abbrev-ref"));
    try testing.expect(has(argv, "origin/HEAD"));
    try testing.expect(!has(argv, "origin/HEAD...HEAD")); // 범위가 아니라 이름 하나를 묻는다
    try testing.expect(has(argv, "core.pager=cat")); // 읽기 전용 계약
    try testing.expect(argv.len <= max_argv);
}

test "기준을 넘기면 세 명령이 **같은** 기준을 쓴다" {
    // 이 셋이 갈리면 화면의 `↑N`과 그 아래 "브랜치에 COMMIT 됨" 목록이 서로 다른 질문의 답이 된다(§3.5).
    var buf: [max_argv][]const u8 = undefined;
    var range_buf: [max_base_range_len]u8 = undefined;
    const range = baseRange("origin/release", &range_buf).?;
    try testing.expectEqualStrings("origin/release...HEAD", range);

    try testing.expect(has(build(.ahead_behind, "/usr/bin/git", "/repo", range, &buf), "origin/release...HEAD"));

    // 안 넘기면 기본값이다 — 기준을 고른 적 없는 저장소가 지금과 똑같이 돈다.
    try testing.expect(has(build(.ahead_behind, "/usr/bin/git", "/repo", null, &buf), "origin/HEAD...HEAD"));
}

test "isSafeBaseRef: 기준 자리에 넣어도 되는 이름만 통과한다" {
    try testing.expect(isSafeBaseRef("origin/main"));
    try testing.expect(isSafeBaseRef("main"));
    try testing.expect(isSafeBaseRef("release-1.2.x"));
    try testing.expect(isSafeBaseRef("feature/a_b+c"));

    // 옵션 주입: git이 rev가 아니라 인자로 읽는다 — 우리가 닫아 둔 외부 프로세스 경로가 다시 열린다.
    try testing.expect(!isSafeBaseRef("--upload-pack=touch /tmp/x"));
    try testing.expect(!isSafeBaseRef("-main"));
    // `..`: 우리가 붙이는 `...HEAD`와 합쳐져 **다른 범위**가 된다.
    try testing.expect(!isSafeBaseRef("a..b"));
    try testing.expect(!isSafeBaseRef("origin/main..."));
    // rev 문법 글자들 — 이름이 식으로 바뀐다.
    try testing.expect(!isSafeBaseRef("HEAD^"));
    try testing.expect(!isSafeBaseRef("HEAD~3"));
    try testing.expect(!isSafeBaseRef("main:file"));
    try testing.expect(!isSafeBaseRef("@{u}"));
    try testing.expect(!isSafeBaseRef("main branch")); // 공백
    try testing.expect(!isSafeBaseRef("main\n"));
    try testing.expect(!isSafeBaseRef(""));

    // 길이 상한 — argv에 싣는 값이라 우리가 정한다.
    var long: [max_base_ref_len + 1]u8 = @splat('a');
    try testing.expect(!isSafeBaseRef(&long));
    try testing.expect(isSafeBaseRef(long[0..max_base_ref_len]));
}

test "baseRange: 거절은 null이지 기본값이 아니다" {
    var buf: [max_base_range_len]u8 = undefined;
    // 되돌리는 판단은 호출자가 한다 — 여기서 조용히 `origin/HEAD`로 바꾸면 사용자가 고른 기준이
    // 무시된 채 **다른 저장소의 답**이 화면에 뜬다(그것이 이 값을 고르게 한 이유였다).
    try testing.expect(baseRange("--upload-pack=x", &buf) == null);
    try testing.expect(baseRange("", &buf) == null);
    try testing.expectEqualStrings("main...HEAD", baseRange("main", &buf).?);
}

test "원격 목록은 이름만 읽는다 — `-v`가 없어야 URL이 안 실린다" {
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.remotes, "/usr/bin/git", "/repo", null, &buf);

    try testing.expect(has(argv, "remote"));
    // **`-v`/`--verbose`가 붙으면 URL이 온다** — `user@host`가 든 문자열을 우리가 들 이유가 없다.
    try testing.expect(!has(argv, "-v"));
    try testing.expect(!has(argv, "--verbose"));
    // 원격을 **바꾸는** 하위명령이 섞이면 안 된다(읽기 계약).
    for ([_][]const u8{ "add", "remove", "rm", "rename", "set-url", "update", "prune" }) |verb| {
        try testing.expect(!has(argv, verb));
    }
    // 읽기 전용 계약(외부 프로세스 차단)은 여기에도 붙는다.
    try testing.expect(has(argv, "core.pager=cat"));
    try testing.expect(has(argv, "credential.helper=")); // 네트워크를 안 쓰므로 helper를 열 이유가 없다
    try testing.expect(argv.len <= max_argv);
}

test "브랜치 목록은 plumbing으로만 읽고 쓰기 동사를 쓰지 않는다" {
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.branches, "/usr/bin/git", "/repo", null, &buf);

    try testing.expect(has(argv, "for-each-ref"));
    try testing.expect(has(argv, "--format=%(refname:short)")); // 출력 형태가 곧 계약이다
    try testing.expect(has(argv, "refs/heads/")); // 원격 ref는 목록에 넣지 않는다
    try testing.expect(has(argv, "--count=200")); // 상한 — 브랜치 수백 개에서 화면·버퍼가 터지지 않게

    // **쓰기 동사가 섞이면 안 된다.** 이 목록으로 브랜치를 바꾸는 일은 우리가 하지 않는다(터미널에 명령을 넣어 준다).
    for ([_][]const u8{ "switch", "checkout", "branch", "reset", "commit", "push" }) |verb| {
        try testing.expect(!has(argv, verb));
    }
}

test "브랜치 목록 파싱: 빈 줄·CR을 버리고 버퍼가 차면 멈춘다" {
    var out: [3][]const u8 = undefined;

    const n = collectBranches("main\nfeat/a\r\n\nfix/b\n", &out);
    try testing.expectEqual(@as(usize, 3), n);
    try testing.expectEqualStrings("main", out[0]);
    try testing.expectEqualStrings("feat/a", out[1]); // CR 제거
    try testing.expectEqualStrings("fix/b", out[2]); // 빈 줄은 건너뜀

    // 버퍼가 차면 멈춘다 — count == out.len이 "더 있다"의 신호다.
    var small: [2][]const u8 = undefined;
    try testing.expectEqual(@as(usize, 2), collectBranches("a\nb\nc\n", &small));

    // 빈 입력은 0.
    try testing.expectEqual(@as(usize, 0), collectBranches("", &out));
    try testing.expectEqual(@as(usize, 0), collectBranches("\n\n", &out));
}

test "브랜치 전환 명령: 개행 없이 만들고 수상한 이름은 거절한다" {
    var buf: [128]u8 = undefined;

    const cmd = branchSwitchCommand("feat/status-bar", &buf).?;
    try testing.expectEqualStrings("git switch feat/status-bar", cmd);
    // **개행이 없어야 한다** — 붙으면 사용자가 보기 전에 실행된다.
    try testing.expect(std.mem.indexOfScalar(u8, cmd, '\n') == null);

    // 셸 메타문자·공백·제어문자는 거절(손상된 목록이 셸에 흘러들지 않게).
    try testing.expect(branchSwitchCommand("a b", &buf) == null);
    try testing.expect(branchSwitchCommand("a;x", &buf) == null);
    try testing.expect(branchSwitchCommand("a$(x)", &buf) == null);
    try testing.expect(branchSwitchCommand("a\nb", &buf) == null);
    try testing.expect(branchSwitchCommand("", &buf) == null);

    // 버퍼가 모자라면 null(조용히 자르지 않는다).
    var tiny: [8]u8 = undefined;
    try testing.expect(branchSwitchCommand("feat/very-long-name", &tiny) == null);
}

test "디렉터리가 사라진 워크트리는 prunable로 표시된다" {
    // 그 줄을 그대로 세우면 **커밋 상자가 달린 빈 줄**이 되고 읽기는 실패만 되풀이한다.
    const text =
        \\worktree /repo
        \\HEAD abc
        \\branch refs/heads/main
        \\
        \\worktree /gone
        \\HEAD abc
        \\branch refs/heads/wt
        \\prunable gitdir file points to non-existent location
        \\
    ;
    var out: [4]Worktree = undefined;
    const n = collectWorktrees(text, &out);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expect(!out[0].prunable);
    try std.testing.expect(out[1].prunable);
}

test "log: 형식은 git_log가 소유하고 상한은 호출자가 준다" {
    // 형식 문자열을 여기 다시 적으면 파싱과 한쪽만 고쳐져 필드가 밀린다 — 그래서 **상수를 그대로** 싣는다.
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.log, "/usr/bin/git", "/repo", "50", &buf);
    var saw_log = false;
    var saw_format = false;
    var limit: ?[]const u8 = null;
    for (argv, 0..) |a, index| {
        if (std.mem.eql(u8, a, "log")) saw_log = true;
        if (std.mem.startsWith(u8, a, "--format=")) {
            saw_format = true;
            try std.testing.expectEqualStrings(git_log.format_spec, a["--format=".len..]);
        }
        if (std.mem.eql(u8, a, "-n") and index + 1 < argv.len) limit = argv[index + 1];
    }
    try std.testing.expect(saw_log and saw_format);
    try std.testing.expectEqualStrings("50", limit orelse "");
    // **병합을 지우지 않는다** — `--no-merges`가 있으면 "언제 합쳐졌나"가 목록에서 사라진다.
    for (argv) |a| try std.testing.expect(!std.mem.eql(u8, a, "--no-merges"));
    // 읽기 전용 계약: 셸을 거치지 않고 첫 인자는 우리가 해석한 실행 파일이다.
    try std.testing.expectEqualStrings("/usr/bin/git", argv[0]);
}

test "log: 상한을 안 주면 기본값이 붙는다(무제한으로 새지 않게)" {
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.log, "/usr/bin/git", "/repo", null, &buf);
    var limit: ?[]const u8 = null;
    for (argv, 0..) |a, index| {
        if (std.mem.eql(u8, a, "-n") and index + 1 < argv.len) limit = argv[index + 1];
    }
    try std.testing.expectEqualStrings("200", limit orelse "");
}

test "commit_files: 루트·병합에서도 파일이 나오게 만든다" {
    // `diff <oid>^ <oid>`는 루트 커밋에서 실패하고, `show`는 병합에서 기본적으로 아무 파일도 안 낸다 —
    // 그래서 `show` + `--first-parent -m`이다.
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.commit_files, "/usr/bin/git", "/repo", "abc1234", &buf);
    var saw_show = false;
    var saw_raw = false;
    var saw_numstat = false;
    var saw_first_parent = false;
    var saw_m = false;
    var saw_rev = false;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "show")) saw_show = true;
        if (std.mem.eql(u8, a, "--raw")) saw_raw = true;
        if (std.mem.eql(u8, a, "--numstat")) saw_numstat = true;
        if (std.mem.eql(u8, a, "--first-parent")) saw_first_parent = true;
        if (std.mem.eql(u8, a, "-m")) saw_m = true;
        if (std.mem.eql(u8, a, "abc1234")) saw_rev = true;
        // 외부 프로그램을 부르는 길은 여기서도 닫는다.
        try testing.expect(!std.mem.eql(u8, a, "--ext-diff"));
        // **`--name-status`가 있으면 안 된다**(P4c): 그 옵션은 `--numstat`과 같은 출력 그룹이라 함께 걸면
        // 뒤에 온 쪽만 나온다(실측 git 2.50.1) — 증감이 통째로 사라지고 그 사실이 조용하다.
        try testing.expect(!std.mem.eql(u8, a, "--name-status"));
    }
    try testing.expect(saw_show and saw_raw and saw_numstat and saw_first_parent and saw_m and saw_rev);
    // 커밋 헤더는 목록이 이미 갖고 있다 — 파일 줄만 받는다.
    var saw_empty_format = false;
    for (argv) |a| if (std.mem.eql(u8, a, "--format=")) {
        saw_empty_format = true;
    };
    try testing.expect(saw_empty_format);
}

test "commitParentBlobSpec은 `^`를 붙이되 hex만 받는다" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings(
        "650a0bbef96a1dd562e0d39f262260ae002c1545^:src/main.zig",
        commitParentBlobSpec("650a0bbef96a1dd562e0d39f262260ae002c1545", "src/main.zig", &buf).?,
    );
    // 임의 문자열은 거부한다 — rev 자리에 인자를 주입하는 길을 막는다.
    try testing.expect(commitParentBlobSpec("--upload-pack=x", "a", &buf) == null);
    try testing.expect(commitParentBlobSpec("abc", "a", &buf) == null); // 너무 짧다
}

test "isHexRev: rev 자리에 넣어도 되는 것만 통과한다" {
    try testing.expect(isHexRev("650a0bbef96a1dd562e0d39f262260ae002c1545"));
    try testing.expect(!isHexRev("--upload-pack=evil"));
    try testing.expect(!isHexRev("HEAD"));
    try testing.expect(!isHexRev("abc")); // 너무 짧다
    try testing.expect(!isHexRev("650a0bb-x"));
}

test "turn_name_status: 두 tree를 각각의 인자로 넘긴다" {
    // `A..B`는 커밋 범위 문법이라 tree에는 쓰지 않는다 — 둘을 각각 넘겨야 git이 tree 비교로 읽는다.
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.turn_name_status, "/usr/bin/git", "/repo", "aaaa111 bbbb222", &buf);
    try testing.expectEqualStrings("aaaa111", argv[argv.len - 2]);
    try testing.expectEqualStrings("bbbb222", argv[argv.len - 1]);
    var saw_raw = false;
    var saw_numstat = false;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "--raw")) saw_raw = true;
        if (std.mem.eql(u8, a, "--numstat")) saw_numstat = true;
        try testing.expect(!std.mem.eql(u8, a, "--cached")); // 작업트리·index가 아니라 tree 둘이다
        // 커밋 파일 목록과 **같은 이유**로 금지한다(위 테스트 주석).
        try testing.expect(!std.mem.eql(u8, a, "--name-status"));
    }
    try testing.expect(saw_raw and saw_numstat);
}

// `check-ignore` 는 경로를 **인자로** 받는다(이 backend 의 실행 경로가 stdout 만 읽으므로 `--stdin` 을
// 쓰지 않는다 — 위 `check_ignore` 주석). 그래서 한 번에 넘길 수 있는 개수가 argv 한도에 묶이고, 그
// 개수를 상수로 노출해 호출자가 끊어 부른다. 여기서 고정하는 것은 ⑴ 접두가 그대로이고 ⑵ 경로가 그 뒤에
// 순서대로 붙으며 ⑶ 배치 크기를 넘겨도 argv 를 넘지 않는다는 것이다.
test "check-ignore argv: 고정 접두 뒤에 경로가 붙고 배치 한도를 넘지 않는다" {
    var buf: [max_argv][]const u8 = undefined;
    const paths = [_][]const u8{ "node_modules", "src/main.zig", "build/out" };
    const argv = buildCheckIgnore("git", "/repo", &paths, &buf);

    try std.testing.expectEqualStrings("git", argv[0]);
    try std.testing.expectEqualStrings("-C", argv[1]);
    try std.testing.expectEqualStrings("/repo", argv[2]);
    // 서브커맨드와 -z 가 접두 끝에 있고, 그 뒤가 경로다.
    try std.testing.expectEqualStrings("check-ignore", argv[argv.len - 5]);
    try std.testing.expectEqualStrings("-z", argv[argv.len - 4]);
    try std.testing.expectEqualStrings("node_modules", argv[argv.len - 3]);
    try std.testing.expectEqualStrings("src/main.zig", argv[argv.len - 2]);
    try std.testing.expectEqualStrings("build/out", argv[argv.len - 1]);

    // 배치 한도를 넘겨 주면 잘라 낸다 — argv 를 넘겨 exec 이 실패하는 것보다 덜 그린 편이 낫다.
    var many: [max_argv * 2][]const u8 = undefined;
    for (&many) |*m| m.* = "x";
    const clamped = buildCheckIgnore("git", "/repo", &many, &buf);
    try std.testing.expect(clamped.len <= max_argv);
    try std.testing.expectEqual(check_ignore_batch, clamped.len - (clamped.len - check_ignore_batch));
    try std.testing.expect(check_ignore_batch > 0);
}

// ── 원격 argv (RS1) ───────────────────────────────────────────────────────────
//
// 이 저장소가 **원격 셸에 명령 문자열을 만들어 보내는 첫 자리**다(계획 §4). 그래서 인용·검증·덮어쓰기
// 보존을 전수로 짚는다 — 배선(RS2~RS4)은 여기서 만든 argv 를 나르기만 한다.

test "원격 argv: 로컬이 닫아 둔 구멍이 원격에서도 닫혀 있다" {
    var buf: [max_argv][]const u8 = undefined;
    var local_buf: [max_argv][]const u8 = undefined;
    var cmd: [max_remote_command_bytes]u8 = undefined;
    const local = build(.status, "/opt/homebrew/bin/git", "/srv/app", null, &local_buf);
    const argv = buildRemote(local, .{ .dest = "user@build-box", .control_path = "/Users/me/.cache/maru/ctl-ab" }, &buf, &cmd) orelse
        return error.RemoteArgvRefused;

    try std.testing.expectEqual(remote_argv_len, argv.len);
    // argv[0] 은 **절대경로**여야 한다 — 실행 층이 `execve(argv[0])` 이다(PATH 검색은 env(1) 몫).
    try std.testing.expectEqualStrings("/usr/bin/env", argv[0]);
    try std.testing.expect(std.fs.path.isAbsolute(argv[0]));
    try std.testing.expectEqualStrings("ssh", argv[1]);
    try std.testing.expectEqualStrings("-o", argv[2]);
    try std.testing.expectEqualStrings("BatchMode=yes", argv[3]); // 소켓이 없으면 묻지 말고 실패한다
    try std.testing.expectEqualStrings("-S", argv[4]);
    try std.testing.expectEqualStrings("/Users/me/.cache/maru/ctl-ab", argv[5]);
    try std.testing.expectEqualStrings("user@build-box", argv[6]);

    const line = argv[7];
    // 로컬 절대경로 git 은 버리고 원격은 PATH 로 찾는다(계약 §2.2 ⑷).
    try std.testing.expect(std.mem.indexOf(u8, line, "/opt/homebrew/bin/git") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "'git'") != null);
    // **config 덮어쓰기가 하나도 빠지면 안 된다** — 빠진 하나가 곧 원격에서만 열리는 구멍이다.
    for (config_overrides) |override| {
        var quoted: [128]u8 = undefined;
        const q = std.fmt.bufPrint(&quoted, "'{s}'", .{override}) catch return error.Unexpected;
        try std.testing.expect(std.mem.indexOf(u8, line, q) != null);
    }
    // env 도 같은 이유로 전수로 본다(원격 셸은 우리 env 를 물려받지 않는다).
    for (env_overrides) |override| {
        var quoted: [128]u8 = undefined;
        const q = std.fmt.bufPrint(&quoted, "'{s}={s}'", .{ override.name, override.value }) catch return error.Unexpected;
        try std.testing.expect(std.mem.indexOf(u8, line, q) != null);
    }
    // **PATH 접두가 맨 앞에 온다**(RS4 §6.5). 없으면 Homebrew·`~/.local/bin` 에 깐 git 이 있는 원격에서
    // 명령이 통째로 실패한다 — argv 판정자는 문자열만 보므로 **여기서 세지 않으면 아무도 안 본다.**
    var prologue_buf: [512]u8 = undefined;
    const prologue = std.fmt.bufPrint(&prologue_buf, "'sh' '-c' '{s}' 'sh' ", .{remote_path_script}) catch return error.Unexpected;
    // **로그인 셸은 인용된 토큰만 본다.** 대입문을 그대로 넘기면 csh/tcsh 에서 조용히 안 먹고,
    // fish 에서는 `"$PATH"` 가 공백으로 이어져 `/usr/bin` 이 사라진다.
    try std.testing.expect(std.mem.startsWith(u8, line, prologue));
    // 스크립트 **안**에서는 `$PATH` 가 펼쳐져야 하므로 인용하지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, remote_path_script, ":$PATH\"") != null);
    // 실제 토큰은 `"$@"` 로 받는다 — 스크립트에 다시 넣으면 인용이 겹쳐 버퍼가 터진다.
    try std.testing.expect(std.mem.endsWith(u8, remote_path_script, "exec \"$@\""));
    try std.testing.expect(std.mem.startsWith(u8, line[prologue.len..], "'env' "));
    try std.testing.expect(std.mem.indexOf(u8, line, "'-C' '/srv/app'") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "'status'") != null);
}

test "원격 argv: 셸 메타문자가 든 경로도 한 인자로 도착한다" {
    var buf: [max_argv][]const u8 = undefined;
    var local_buf: [max_argv][]const u8 = undefined;
    var cmd: [max_remote_command_bytes]u8 = undefined;
    // 공백·`;`·`$( )`·백틱·와일드카드·작은따옴표가 전부 든 경로. 작은따옴표 안에서는 어떤 확장도
    // 일어나지 않으므로, 유일하게 다뤄야 하는 것이 그 따옴표 자신이다.
    const nasty = "/srv/it's here; rm -rf $(echo x) `id` *";
    const local = build(.status, "/usr/bin/git", nasty, null, &local_buf);
    const argv = buildRemote(local, .{ .dest = "user@host", .control_path = "/tmp/ctl" }, &buf, &cmd) orelse
        return error.RemoteArgvRefused;
    const line = argv[7];

    // `'` 는 `'\''` 로 닫았다 다시 연다 — 그 밖의 문자는 손대지 않는다.
    try std.testing.expect(std.mem.indexOf(u8, line, "'/srv/it'\\''s here; rm -rf $(echo x) `id` *'") != null);
    // 인용을 벗어난 곳에 위험한 문자가 남아 있지 않은지 **직접 센다**: 명령 전체에서 작은따옴표 밖의
    // 문자는 우리가 넣은 공백뿐이어야 한다.
    //
    // **셸 규칙 그대로 읽는다**: 인용 밖의 `\\` 는 다음 한 글자를 리터럴로 만든다 — `'\\''` 가 정확히
    // 그 셋(닫기 · 이스케이프된 따옴표 · 열기)이라, 그 백슬래시를 모르면 검사기가 자기 인용 규약을
    // 오해한다(적대적 검증 1 회차에서 이 검사기가 먼저 틀렸다).
    // 껍데기까지 포함해 **전부 인용 안**이어야 한다 — 그것이 이 형태를 고른 이유다.
    var prologue_buf: [512]u8 = undefined;
    const prologue = std.fmt.bufPrint(&prologue_buf, "'sh' '-c' '{s}' 'sh' ", .{remote_path_script}) catch return error.Unexpected;
    try std.testing.expect(std.mem.startsWith(u8, line, prologue));
    const body = line;
    var in_quote = false;
    var i: usize = 0;
    while (i < body.len) {
        const c = body[i];
        if (!in_quote and c == '\\') {
            try std.testing.expect(i + 1 < body.len); // 끊긴 이스케이프는 셸이 다음 줄을 기다린다
            i += 2; // 이스케이프된 한 글자는 리터럴이다
            continue;
        }
        if (c == '\'') {
            in_quote = !in_quote;
            i += 1;
            continue;
        }
        if (!in_quote) try std.testing.expectEqual(@as(u8, ' '), c);
        i += 1;
    }
    try std.testing.expect(!in_quote); // 따옴표가 짝을 이룬다
}

test "원격 argv: 못 믿을 입력이면 명령을 만들지 않는다" {
    var buf: [max_argv][]const u8 = undefined;
    var local_buf: [max_argv][]const u8 = undefined;
    var cmd: [max_remote_command_bytes]u8 = undefined;
    const ok_remote: Remote = .{ .dest = "user@host", .control_path = "/tmp/ctl" };

    // ⑴ 경로에 제어문자(개행) — 인용해도 실행하지 않는다. 관측이 오염됐다는 뜻이다.
    const local_nl = build(.status, "git", "/srv/a\nb", null, &local_buf);
    try std.testing.expect(buildRemote(local_nl, ok_remote, &buf, &cmd) == null);

    // ⑵ dest 가 `-` 로 시작하면 ssh 가 옵션으로 읽는다.
    const local = build(.status, "git", "/srv/app", null, &local_buf);
    try std.testing.expect(buildRemote(local, .{ .dest = "-oProxyCommand=id", .control_path = "/tmp/ctl" }, &buf, &cmd) == null);
    try std.testing.expect(buildRemote(local, .{ .dest = "", .control_path = "/tmp/ctl" }, &buf, &cmd) == null);
    try std.testing.expect(buildRemote(local, .{ .dest = "user@ho\x01st", .control_path = "/tmp/ctl" }, &buf, &cmd) == null);

    // ⑶ control socket 은 우리가 만든 절대경로다 — 상대경로·빈 값·제어문자는 거부.
    try std.testing.expect(buildRemote(local, .{ .dest = "user@host", .control_path = "ctl" }, &buf, &cmd) == null);
    try std.testing.expect(buildRemote(local, .{ .dest = "user@host", .control_path = "" }, &buf, &cmd) == null);
    try std.testing.expect(buildRemote(local, .{ .dest = "user@host", .control_path = "/tmp/c\ttl" }, &buf, &cmd) == null);

    // ⑷ 버퍼가 모자라면 **자르지 않는다** — 잘린 셸 명령은 덜 실행되는 것이 아니라 다른 명령이다.
    var tiny: [16]u8 = undefined;
    try std.testing.expect(buildRemote(local, ok_remote, &buf, &tiny) == null);
}

test "원격 파일 읽기: 원격에서 자르고, 절대경로만 받는다 (RS3)" {
    var buf: [max_argv][]const u8 = undefined;
    var cmd: [max_remote_command_bytes]u8 = undefined;
    const remote: Remote = .{ .dest = "user@host", .control_path = "/tmp/ctl" };

    const argv = buildRemoteFileRead("/srv/app/src/it's here.zig", remote, &buf, &cmd) orelse
        return error.RemoteArgvRefused;
    // 전송 옵션은 `buildRemote` 와 **같은 자리**에서 온다(두 벌이면 한쪽만 고쳐져 새 연결이 열린다).
    try std.testing.expectEqual(remote_argv_len, argv.len);
    try std.testing.expectEqualStrings("/usr/bin/env", argv[0]);
    try std.testing.expectEqualStrings("BatchMode=yes", argv[3]);
    try std.testing.expectEqualStrings("/tmp/ctl", argv[5]);

    const line = argv[7];
    // **원격에서 자른다** — 로컬은 받은 뒤 자르지만 원격은 그 전에 링크를 다 건너온다.
    var size_buf: [24]u8 = undefined;
    const size = try std.fmt.bufPrint(&size_buf, "'{d}'", .{max_remote_file_bytes});
    try std.testing.expect(std.mem.indexOf(u8, line, size) != null);
    var fr_prologue_buf: [512]u8 = undefined;
    const fr_prologue = std.fmt.bufPrint(&fr_prologue_buf, "'sh' '-c' '{s}' 'sh' ", .{remote_path_script}) catch return error.Unexpected;
    try std.testing.expect(std.mem.startsWith(u8, line, fr_prologue)); // 같은 껍데기를 쓴다(규율을 두 갈래로 두지 않는다)
    try std.testing.expect(std.mem.startsWith(u8, line[fr_prologue.len..], "'head' '-c' "));
    // `--` 로 옵션 해석을 끊고, 경로는 같은 인용 규칙을 쓴다(작은따옴표 안은 확장이 없다).
    try std.testing.expect(std.mem.indexOf(u8, line, "'--' '/srv/app/src/it'\\''s here.zig'") != null);

    // 상대경로는 **원격 로그인 셸의 cwd(홈)** 에 걸려 다른 파일을 읽는다 — 만들지 않는다.
    try std.testing.expect(buildRemoteFileRead("src/main.zig", remote, &buf, &cmd) == null);
    try std.testing.expect(buildRemoteFileRead("", remote, &buf, &cmd) == null);
    // 제어문자는 `buildRemote` 와 같은 이유로 거부한다(관측이 오염됐다는 뜻이다).
    try std.testing.expect(buildRemoteFileRead("/srv/a\nb", remote, &buf, &cmd) == null);
    // dest·socket 검증도 같은 자리를 지난다.
    try std.testing.expect(buildRemoteFileRead("/srv/app", .{ .dest = "-oProxyCommand=id", .control_path = "/tmp/ctl" }, &buf, &cmd) == null);
    try std.testing.expect(buildRemoteFileRead("/srv/app", .{ .dest = "user@host", .control_path = "ctl" }, &buf, &cmd) == null);
}
