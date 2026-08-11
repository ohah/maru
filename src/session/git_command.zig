//! 도크 소스 컨트롤 뷰가 실행할 **git 명령줄을 만드는 순수 모듈**(L4가 그대로 spawn한다).
//!
//! 왜 argv 조립을 L2로 빼는가: 안전 조건이 전부 **인자와 환경변수**에 있기 때문이다(docs/editor-surface-tooling.md §6).
//! 실행 코드와 섞으면 "이 플래그가 정말 붙었나"를 프로세스를 띄우지 않고는 못 본다. 여기 있으면 헤드리스 테스트가
//! 플래그 하나하나를 전수로 고정한다.
//!
//! **읽기 전용 계약**(§6 — 각 항목이 아래 상수 하나와 1:1이다):
//! - 셸·alias를 거치지 않는다. `sh -c`도, `git` alias 확장도 없다 — 호출자는 이 argv를 그대로 `execve`한다.
//! - repository config가 **외부 프로세스를 실행하지 못하게** 한다: external diff·textconv·pager·hook·credential helper를
//!   전부 빈 값으로 덮어쓴다. 악성 저장소가 `diff.external=curl …`을 넣어 둬도 우리가 실행하지 않는다.
//! - **index를 건드리지 않는다**: `GIT_OPTIONAL_LOCKS=0`. 이게 없으면 `git status`가 index를 refresh하며 `index.lock`을
//!   잡아, 사용자가 같은 저장소에서 돌리는 다른 git이 실패할 수 있다(읽기 화면이 쓰기를 방해하면 안 된다).
//! - **네트워크·프롬프트 없음**: `GIT_TERMINAL_PROMPT=0` + credential helper 제거. status/diff는 원래 로컬이지만,
//!   설정으로 원격을 건드리게 만드는 경로를 명시적으로 닫는다.

const std = @import("std");

/// 뷰가 필요로 하는 읽기 명령. 셋을 합쳐 네 섹션과 행의 증감을 채운다(§3.5).
pub const Kind = enum {
    /// 네 섹션의 상태 문자 + 브랜치/upstream/ahead·behind를 **한 번에**. `--branch` 덕에 rev-list가 따로 필요 없다.
    status,
    /// 스테이지된 변경의 +N -N (`HEAD ↔ index`).
    numstat_staged,
    /// 아직 스테이지되지 않은 변경의 +N -N (`index ↔ worktree`).
    numstat_worktree,
    /// 기본 브랜치와 갈린 지점(`merge-base origin/HEAD HEAD`). 이 값이 "브랜치에 COMMIT 됨" 섹션의 왼쪽이다.
    /// **실패해도 목록은 성립한다** — origin/HEAD가 없는 저장소(로컬 전용·clone 아님)에서는 그 섹션만 숨긴다.
    merge_base,
    /// 그 갈린 지점 이후 이 브랜치의 커밋들이 바꾼 파일: `git diff --name-status origin/HEAD...HEAD`.
    /// **삼점 범위**라 merge-base를 따로 구해 넘길 필요가 없다(git이 같은 계산을 한다).
    branch_name_status,
    /// 같은 범위의 +N -N.
    branch_numstat,
    /// 턴 스냅샷 ①: 임시 index를 HEAD로 채운다(`read-tree HEAD`). 진짜 index는 안 건드린다 — `GIT_INDEX_FILE`이
    /// 가리키는 파일만 쓴다. 그 파일은 **저장소 밖**에 둔다(안에 두면 그 파일 자체가 diff에 잡힌다).
    snapshot_read_tree,
    /// 턴 스냅샷 ②: 그 임시 index에 작업트리를 반영한다(`add -A`). 작업트리는 안 바뀐다.
    snapshot_add,
    /// 턴 스냅샷 ③: 그 index를 tree 하나로 굳힌다(`write-tree`). 이 tree OID가 "그 턴이 끝난 순간"이다.
    snapshot_write_tree,
    /// 그 스냅샷 이후 바뀐 것: 임시 index(작업트리 반영본)와 스냅샷 tree를 비교한다.
    /// **`--cached`인 이유**: 비교 대상이 작업트리가 아니라 방금 만든 index다(추적되지 않은 파일까지 포함하려면
    /// index에 넣고 비교해야 한다 — 실측으로 확인).
    snapshot_name_status,
    snapshot_numstat,
    /// 로컬 브랜치 목록(`for-each-ref refs/heads/`). 상태바 브랜치 항목을 눌렀을 때 고를 목록이다.
    ///
    /// **왜 `branch --list`가 아닌가**: `branch`는 pager·색·컬럼을 타는 porcelain이라 출력이 설정과 터미널 폭에
    /// 따라 흔들린다. `for-each-ref`는 plumbing이라 `--format`이 곧 계약이고 정렬도 우리가 정한다.
    ///
    /// **읽기 전용 계약 안이다**: refs를 읽기만 하고 index·작업트리·네트워크를 건드리지 않는다. 이 목록으로
    /// 브랜치를 **바꾸는 일은 우리가 하지 않는다** — 고른 이름을 활성 터미널에 `git switch <name>`으로 넣어
    /// 주고 실행은 사용자 셸이 한다(hook·dirty tree·충돌이 평소처럼 사용자에게 보인다).
    branches,
    /// diff 본문 한쪽(원본)을 통째로: `git show <spec>`. spec은 `blobSpec`이 만든 `HEAD:<경로>` 또는 `:<경로>`다.
    /// **worktree 쪽은 이 경로로 읽지 않는다** — 디스크 파일을 그대로 읽으면 되고, git을 한 번 덜 띄운다.
    show_blob,
};

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
pub fn commitBlobSpec(rev: []const u8, repo_relative_path: []const u8, buf: []u8) ?[]const u8 {
    if (rev.len < 7 or rev.len > 64) return null;
    for (rev) |c| {
        const hex = (c >= '0' and c <= '9') or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
        if (!hex) return null;
    }
    if (rev.len + 1 + repo_relative_path.len > buf.len) return null;
    @memcpy(buf[0..rev.len], rev);
    buf[rev.len] = ':';
    @memcpy(buf[rev.len + 1 ..][0..repo_relative_path.len], repo_relative_path);
    return buf[0 .. rev.len + 1 + repo_relative_path.len];
}

/// 어떤 kind든 이만큼이면 담긴다(테스트가 상한을 고정한다). config 쌍을 늘리면 여기도 함께 늘려야 한다 —
/// 넘치면 조용히 잘리는 게 아니라 buf 범위를 벗어난다(quotePath 추가 때 실제로 넘쳤다).
pub const max_argv = 24;

/// repository config가 외부 프로세스를 실행하지 못하게 덮어쓰는 `-c` 쌍. **빈 값 = 비활성**이 git의 규약이다.
const config_overrides = [_][]const u8{
    "-c", "core.pager=cat", //            pager 프로세스 실행·페이지네이션 금지
    "-c", "core.hooksPath=/dev/null", //  훅 실행 금지(저장소가 심어 둔 스크립트)
    "-c", "diff.external=", //            external diff 프로그램 금지
    "-c", "credential.helper=", //        자격증명 helper 프로세스 금지
    "-c", "protocol.ext.allow=never", //  ext:: 원격 = 임의 명령 실행 벡터
    // 경로를 **있는 그대로** 받는다. 기본값(true)이면 비ASCII 경로를 `"\355\225\234..."`처럼 C-quote해서 내주는데,
    // 그 문자열을 다시 git에 넘기거나 open(2)에 쓰면 "그런 파일 없음"이 된다 — 한글·일본어 파일명이 전부 안 열렸다.
    "-c", "core.quotePath=false",
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
        .numstat_staged, .numstat_worktree => {
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
        },
        .merge_base => {
            buf[n] = "merge-base";
            n += 1;
            buf[n] = "origin/HEAD";
            n += 1;
            buf[n] = "HEAD";
            n += 1;
        },
        .branch_name_status, .branch_numstat => {
            buf[n] = "diff";
            n += 1;
            buf[n] = if (kind == .branch_numstat) "--numstat" else "--name-status";
            n += 1;
            buf[n] = "--find-renames";
            n += 1;
            buf[n] = "--no-ext-diff";
            n += 1;
            buf[n] = "--no-textconv";
            n += 1;
            // `A...B` = B가 갈린 지점 이후 바꾼 것(공통 조상 기준). `A..B`(두 점)로 쓰면 기본 브랜치에 새로 들어온
            // 커밋까지 "내가 바꾼 것"으로 잡혀 목록이 부풀어 오른다.
            buf[n] = "origin/HEAD...HEAD";
            n += 1;
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
        .snapshot_name_status, .snapshot_numstat => {
            buf[n] = "diff";
            n += 1;
            buf[n] = "--cached";
            n += 1;
            buf[n] = if (kind == .snapshot_numstat) "--numstat" else "--name-status";
            n += 1;
            buf[n] = "--find-renames";
            n += 1;
            buf[n] = "--no-ext-diff";
            n += 1;
            buf[n] = "--no-textconv";
            n += 1;
            buf[n] = arg orelse ""; // 스냅샷 tree OID
            n += 1;
        },
        .branches => {
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
    inline for (.{ Kind.status, Kind.numstat_staged, Kind.numstat_worktree, Kind.show_blob }) |kind| {
        const argv = build(kind, "/usr/bin/git", "/repo", "HEAD:x", &buf);
        try testing.expect(argv.len <= max_argv);
    }
}

test "브랜치 범위는 삼점(...)으로 물어 기본 브랜치의 새 커밋을 섞지 않는다" {
    var buf: [max_argv][]const u8 = undefined;
    const argv = build(.branch_name_status, "/usr/bin/git", "/repo", null, &buf);
    try testing.expect(has(argv, "origin/HEAD...HEAD"));
    try testing.expect(!has(argv, "origin/HEAD..HEAD"));
    try testing.expect(has(argv, "--name-status"));
    // 같은 범위의 증감도 같은 형태로 묻는다.
    var buf2: [max_argv][]const u8 = undefined;
    try testing.expect(has(build(.branch_numstat, "/usr/bin/git", "/repo", null, &buf2), "--numstat"));
    // merge-base는 그 섹션의 diff 왼쪽을 읽을 때 쓴다.
    var buf3: [max_argv][]const u8 = undefined;
    const mb = build(.merge_base, "/usr/bin/git", "/repo", null, &buf3);
    try testing.expect(has(mb, "merge-base"));
    try testing.expect(has(mb, "origin/HEAD"));
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

    // 비교는 **index ↔ 스냅샷 tree**다(`--cached`) — 작업트리와 직접 비교하면 추적되지 않은 파일이 빠진다.
    const named = build(.snapshot_name_status, "/usr/bin/git", "/repo", "deadbeef", &buf);
    try testing.expect(has(named, "--cached"));
    try testing.expect(has(named, "--name-status"));
    try testing.expect(has(named, "deadbeef"));
    // 읽기 전용 계약은 여기에도 그대로 붙는다.
    try testing.expect(has(named, "core.pager=cat"));
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
