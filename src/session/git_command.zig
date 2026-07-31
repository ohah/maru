//! 도크 소스 컨트롤 뷰가 실행할 **git 명령줄을 만드는 순수 모듈**(L4가 그대로 spawn한다).
//!
//! 왜 argv 조립을 L2로 빼는가: 안전 조건이 전부 **인자와 환경변수**에 있기 때문이다(docs/editor-surface.md §6).
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
    /// diff 본문 한쪽(원본)을 통째로: `git show <spec>`. spec은 `blobSpec`이 만든 `HEAD:<경로>` 또는 `:<경로>`다.
    /// **worktree 쪽은 이 경로로 읽지 않는다** — 디스크 파일을 그대로 읽으면 되고, git을 한 번 덜 띄운다.
    show_blob,
};

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

/// 어떤 kind든 이만큼이면 담긴다(테스트가 상한을 고정한다).
pub const max_argv = 20;

/// repository config가 외부 프로세스를 실행하지 못하게 덮어쓰는 `-c` 쌍. **빈 값 = 비활성**이 git의 규약이다.
const config_overrides = [_][]const u8{
    "-c", "core.pager=cat", //            pager 프로세스 실행·페이지네이션 금지
    "-c", "core.hooksPath=/dev/null", //  훅 실행 금지(저장소가 심어 둔 스크립트)
    "-c", "diff.external=", //            external diff 프로그램 금지
    "-c", "credential.helper=", //        자격증명 helper 프로세스 금지
    "-c", "protocol.ext.allow=never", //  ext:: 원격 = 임의 명령 실행 벡터
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
