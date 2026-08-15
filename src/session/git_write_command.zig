//! 소스 컨트롤 **쓰기** 명령의 argv 조립과 안전 술어(docs/editor-surface-dock-write.md §2·§6).
//!
//! 읽기(`git_command.zig`)와 **한 헬퍼를 공유하지 않는다.** 두 종류는 환경과 플래그가 다르고(§1), 조립 함수를
//! 갈라 두어야 "이 플래그가 정말 붙었나"를 테스트가 명령 종류별로 전수로 고정한다. 갈린 축은 셋이다:
//!
//! - **index 잠금**: 읽기는 `GIT_OPTIONAL_LOCKS=0`으로 잠그지 않는다. 쓰기는 **잠가야 한다** — 잠그지 않으면
//!   동시 실행이 index를 깬다. 그래서 이 모듈의 env에는 그 변수가 **없다**.
//! - **hook**: 읽기는 항상 금지한다(남의 저장소 스크립트를 우리가 실행하지 않는다). 쓰기는 **커밋만** 허용한다
//!   — pre-commit hook은 사용자가 기대하는 동작이고, 그걸 막으면 우리 커밋만 검사를 건너뛴다(§3).
//! - **stderr**: 읽기는 화면·로그에 싣지 않고, 쓰기는 **가공해서 보여 준다**(§5). 그건 실행하는 쪽의 계약이라
//!   이 모듈은 argv만 만든다.
//!
//! **이 모듈은 실행하지 않는다.** 순수 조립 + 술어라 테스트가 프로세스 없이 전수로 돈다. 실제 실행·직렬화·
//! 낙관적 반영은 호출자(platform)가 갖는다(§6·§7).
//!
//! **셸을 거치지 않는다.** argv를 그대로 `execve`하므로 따옴표·이스케이프 규칙이 없다 — 경로에 공백·개행·
//! 따옴표가 있어도 한 인자다.

const std = @import("std");

/// 쓰기 명령의 종류. **unborn(첫 커밋 전) 변종이 따로 있다** — HEAD가 없으면 `restore`가 실패하므로 §2가
/// `rm --cached`를 대신 쓰라고 정했다. 어느 쪽인지는 호출자가 head 상태로 고르고, 이 모듈은 고르지 않는다
/// (그 판단에 필요한 상태를 조립기가 들면 순수하지 않다).
pub const Kind = enum {
    /// `add -- <경로>…` — 새 파일·수정·삭제를 한 명령이 덮는다.
    stage,
    /// `restore --staged -- <경로>…`
    unstage,
    /// unborn에서의 언스테이지 — `rm --cached -- <경로>…`
    unstage_unborn,
    /// `add -A --` — 추적되지 않은 파일까지 든다.
    stage_all,
    /// `restore --staged -- .`
    unstage_all,
    /// unborn에서의 모두 언스테이지 — `rm --cached -r -- .`
    unstage_all_unborn,
    /// `commit -F <메시지 파일>` — `-m`이 아니다(§2: 여러 줄·따옴표·비ASCII를 argv에 싣지 않는다).
    commit,

    /// 이 명령이 경로 인자를 받는가. `_all` 변종과 커밋은 받지 않는다 — 경로를 주면 조립을 거부한다
    /// (`add -A -- <경로>`는 "모두"가 아니라 그 경로만 담아 사용자가 누른 것과 다른 일을 한다).
    pub fn takesPaths(self: Kind) bool {
        return switch (self) {
            .stage, .unstage, .unstage_unborn => true,
            .stage_all, .unstage_all, .unstage_all_unborn, .commit => false,
        };
    }

    /// hook을 허용하는가. **커밋만이다**(§3).
    pub fn allowsHooks(self: Kind) bool {
        return self == .commit;
    }
};

/// 경로가 거부되는 이유. **조립 단계에서 막는다** — 여기서 통과시키면 `--` 뒤라도 저장소 밖을 건드린다.
pub const PathError = error{
    /// 빈 경로. `git add -- ""`는 저장소 전체를 의미할 수 있다.
    EmptyPath,
    /// 절대경로. 저장소 루트 밖을 가리킨다.
    AbsolutePath,
    /// `..` 세그먼트. 루트 밖으로 나가는 유일한 상대 경로 형태다.
    ParentSegment,
    /// NUL 바이트. argv는 NUL로 끝나므로 실으면 **뒤가 잘려** 다른 경로가 된다.
    EmbeddedNul,
};

pub const BuildError = PathError || error{
    /// 호출자가 준 argv 버퍼가 모자라다. **자르지 않는다** — 자르면 경로 일부만 스테이지된다.
    InsufficientArgvBuffer,
    /// 경로를 받지 않는 종류에 경로가 왔다(또는 그 반대).
    PathsNotAllowed,
    /// `stage`/`unstage`에 경로가 하나도 없다. 빈 경로 목록으로 `add --`를 부르면 아무 일도 안 하지만,
    /// 호출자가 "무언가 했다"고 믿게 되므로 조립에서 막는다.
    NoPaths,
    /// 커밋인데 메시지 파일이 없다(또는 커밋이 아닌데 있다).
    MessageFileMismatch,
};

/// 경로 하나의 안전 술어. §6의 3겹 경계 중 **조립 층**이다(나머지 둘은 호출자의 저장소 루트 확인과 git 자신).
pub fn validatePath(path: []const u8) PathError!void {
    if (path.len == 0) return error.EmptyPath;
    if (path[0] == '/') return error.AbsolutePath;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.EmbeddedNul;

    // `..`는 **세그먼트일 때만** 위험하다. `..foo`나 `foo..bar`는 평범한 이름이므로 문자열 포함 검사로 막으면
    // 멀쩡한 파일을 거부한다.
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return error.ParentSegment;
    }
}

/// repository config가 외부 프로세스를 실행하지 못하게 덮어쓰는 `-c` 쌍. 읽기 쪽과 **같은 목록이되 hook만
/// 갈린다** — 그래서 배열을 복제하지 않고 hook 쌍만 조건부로 붙인다.
const shared_config_overrides = [_][]const u8{
    "-c", "core.pager=cat", //           pager 프로세스 실행 금지
    "-c", "diff.external=", //           external diff 프로그램 금지
    "-c", "credential.helper=", //       자격증명 helper 프로세스 금지
    "-c", "protocol.ext.allow=never", // ext:: 원격 = 임의 명령 실행 벡터
    // 경로를 **있는 그대로** 주고받는다. 기본값(true)이면 비ASCII 경로를 C-quote해서 내주는데, 그 문자열을
    // 다시 git에 넘기면 "그런 파일 없음"이 된다(읽기 쪽과 같은 이유 — 한글 파일명이 전부 안 열렸다).
    "-c", "core.quotePath=false",
};

/// hook을 끄는 쌍. **커밋에는 붙이지 않는다**(§3).
const hooks_off = [_][]const u8{ "-c", "core.hooksPath=/dev/null" };

/// 하위 프로세스에 덮어써서 넘길 환경변수.
///
/// **`GIT_OPTIONAL_LOCKS`가 여기 없는 것이 계약이다.** 읽기는 그것을 `0`으로 두어 index를 안 잠그지만, 쓰기가
/// 안 잠그면 동시 실행이 index를 깬다(§1). 실수로 추가되지 않도록 테스트가 부재를 고정한다.
pub const env_overrides = [_]struct { name: []const u8, value: []const u8 }{
    .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" }, // 프롬프트는 우리 화면에 못 그린다 — 뜨면 영영 안 끝난다
    .{ .name = "GIT_CONFIG_NOSYSTEM", .value = "1" }, // /etc/gitconfig 의 외부 프로그램 설정 배제
    .{ .name = "GIT_PAGER", .value = "cat" },
    .{ .name = "GIT_ASKPASS", .value = "" }, // 자격증명 프롬프트 프로그램 금지
};

/// 고정 인자 수의 상한(경로 제외): exe + `-C` + repo + config 12 + hook 2 + 하위명령 4 + `--`.
pub const fixed_argv_max: usize = 3 + shared_config_overrides.len + hooks_off.len + 4 + 1;

/// 한 번에 넘길 경로의 상한. `ARG_MAX`(macOS 기본 1 MiB)에 여유를 크게 두고 **바이트와 개수 둘 다**로 자른다 —
/// 경로 하나가 4 KiB까지 갈 수 있어 개수만으로는 상한이 안 선다.
pub const max_batch_paths: usize = 256;
pub const max_batch_bytes: usize = 64 * 1024;

/// `paths[start..]`에서 한 배치에 넣을 **끝 인덱스**(exclusive)를 돌려준다.
///
/// **경로 하나가 상한보다 커도 그 하나는 넣는다** — 안 넣으면 진행이 멈춰 그 파일을 영영 스테이지할 수 없다.
/// 실제 `ARG_MAX` 초과는 실행이 `E2BIG`로 알려 주고, 그건 §5의 실패 경로로 간다.
pub fn batchEnd(paths: []const []const u8, start: usize) usize {
    if (start >= paths.len) return start;
    var bytes: usize = 0;
    var end = start;
    while (end < paths.len) : (end += 1) {
        const next = bytes + paths[end].len + 1; // +1 = argv 항목의 NUL
        if (end > start and (end - start >= max_batch_paths or next > max_batch_bytes)) break;
        bytes = next;
    }
    return end;
}

/// argv를 `buf`에 채우고 그 슬라이스를 돌려준다. **할당하지 않는다.**
///
/// `git_exe`는 호출자가 **절대 경로로 해석해 둔** 실행 파일이다 — PATH 탐색을 이 모듈이 하지 않는 이유는
/// PATH hijack을 막는 책임이 "무엇을 실행할지 고르는" 쪽(L4)에 있어서다(읽기 쪽과 같은 규율).
///
/// `message_file`은 `commit`에만 준다. §2가 `-m`을 금지한 이유는 여러 줄·따옴표·비ASCII를 argv에 싣지 않기
/// 위해서다(파일은 **저장소 밖**에 만들고 성공·실패와 무관하게 지운다 — 그건 호출자 몫이다).
pub fn build(
    kind: Kind,
    git_exe: []const u8,
    repo: []const u8,
    paths: []const []const u8,
    message_file: ?[]const u8,
    buf: [][]const u8,
) BuildError![]const []const u8 {
    if (kind.takesPaths()) {
        if (paths.len == 0) return error.NoPaths;
    } else if (paths.len != 0) return error.PathsNotAllowed;

    if ((kind == .commit) != (message_file != null)) return error.MessageFileMismatch;

    for (paths) |path| try validatePath(path);

    var n: usize = 0;
    const need = fixed_argv_max + paths.len;
    if (buf.len < need) return error.InsufficientArgvBuffer;

    buf[n] = git_exe;
    n += 1;
    // `-C <repo>`: cwd를 바꾸지 않고 대상 저장소를 지정한다. 프로세스 cwd를 건드리면 다른 스레드에 영향이 간다.
    buf[n] = "-C";
    n += 1;
    buf[n] = repo;
    n += 1;
    for (shared_config_overrides) |override| {
        buf[n] = override;
        n += 1;
    }
    if (!kind.allowsHooks()) {
        for (hooks_off) |override| {
            buf[n] = override;
            n += 1;
        }
    }

    switch (kind) {
        .stage => {
            buf[n] = "add";
            n += 1;
        },
        .stage_all => {
            buf[n] = "add";
            n += 1;
            buf[n] = "-A";
            n += 1;
        },
        .unstage, .unstage_all => {
            buf[n] = "restore";
            n += 1;
            buf[n] = "--staged";
            n += 1;
        },
        .unstage_unborn => {
            buf[n] = "rm";
            n += 1;
            buf[n] = "--cached";
            n += 1;
        },
        .unstage_all_unborn => {
            buf[n] = "rm";
            n += 1;
            buf[n] = "--cached";
            n += 1;
            buf[n] = "-r";
            n += 1;
        },
        .commit => {
            buf[n] = "commit";
            n += 1;
            buf[n] = "-F";
            n += 1;
            buf[n] = message_file.?;
            n += 1;
        },
    }

    // **`--`는 커밋을 뺀 모든 쓰기에 붙는다.** 없으면 `-`로 시작하는 파일 이름이 옵션으로 해석된다(§2).
    // `_all` 변종도 예외가 아니다 — `add -A --`·`restore --staged -- .`가 §2 표의 형태다.
    if (kind != .commit) {
        buf[n] = "--";
        n += 1;
    }

    switch (kind) {
        .stage, .unstage, .unstage_unborn => for (paths) |path| {
            buf[n] = path;
            n += 1;
        },
        // 모두-언스테이지는 `.`이 대상이다. 모두-스테이지는 `-A`가 이미 전체를 뜻하므로 대상을 주지 않는다.
        .unstage_all, .unstage_all_unborn => {
            buf[n] = ".";
            n += 1;
        },
        .stage_all, .commit => {},
    }

    return buf[0..n];
}

// ── 테스트 ──────────────────────────────────────────────────────────────────────
//
// §2 표의 각 행이 테스트 하나와 1:1이다(계획서 P2 요구). 안전 술어는 거부 이유마다 하나씩 둔다.

const testing = std.testing;

fn buildFixture(kind: Kind, paths: []const []const u8, message_file: ?[]const u8, buf: [][]const u8) ![]const []const u8 {
    return build(kind, "/usr/bin/git", "/repo", paths, message_file, buf);
}

fn indexOf(argv: []const []const u8, needle: []const u8) ?usize {
    for (argv, 0..) |a, i| if (std.mem.eql(u8, a, needle)) return i;
    return null;
}

fn has(argv: []const []const u8, needle: []const u8) bool {
    return indexOf(argv, needle) != null;
}

/// `--` 뒤에 오는 인자들(= 경로 자리).
fn afterDashDash(argv: []const []const u8) []const []const u8 {
    const at = indexOf(argv, "--") orelse return &.{};
    return argv[at + 1 ..];
}

test "§2 스테이지: add -- <경로>…" {
    var buf: [64][]const u8 = undefined;
    const argv = try buildFixture(.stage, &.{ "a.zig", "dir/b.zig" }, null, &buf);
    try testing.expect(has(argv, "add"));
    try testing.expectEqualSlices([]const u8, &.{ "a.zig", "dir/b.zig" }, afterDashDash(argv));
}

test "§2 언스테이지: restore --staged -- <경로>…" {
    var buf: [64][]const u8 = undefined;
    const argv = try buildFixture(.unstage, &.{"a.zig"}, null, &buf);
    const restore = indexOf(argv, "restore") orelse return error.MissingSubcommand;
    try testing.expectEqualStrings("--staged", argv[restore + 1]);
    try testing.expectEqualSlices([]const u8, &.{"a.zig"}, afterDashDash(argv));
}

test "§2 unborn 언스테이지: HEAD가 없으면 rm --cached다" {
    // `restore --staged`는 HEAD를 기준으로 index를 되돌리므로 첫 커밋 전에는 실패한다.
    var buf: [64][]const u8 = undefined;
    const argv = try buildFixture(.unstage_unborn, &.{"a.zig"}, null, &buf);
    const rm = indexOf(argv, "rm") orelse return error.MissingSubcommand;
    try testing.expectEqualStrings("--cached", argv[rm + 1]);
    try testing.expect(!has(argv, "restore"));
    try testing.expectEqualSlices([]const u8, &.{"a.zig"}, afterDashDash(argv));
}

test "§2 모두 스테이지: add -A -- (경로 없음, 추적되지 않은 파일까지)" {
    var buf: [64][]const u8 = undefined;
    const argv = try buildFixture(.stage_all, &.{}, null, &buf);
    const add = indexOf(argv, "add") orelse return error.MissingSubcommand;
    try testing.expectEqualStrings("-A", argv[add + 1]);
    // `--`로 끝난다 — 대상을 주지 않는다(`-A`가 이미 전체다).
    try testing.expectEqualStrings("--", argv[argv.len - 1]);
}

test "§2 모두 언스테이지: restore --staged -- . / unborn이면 rm --cached -r -- ." {
    var buf: [64][]const u8 = undefined;
    const argv = try buildFixture(.unstage_all, &.{}, null, &buf);
    try testing.expect(has(argv, "restore"));
    try testing.expectEqualSlices([]const u8, &.{"."}, afterDashDash(argv));

    var unborn_buf: [64][]const u8 = undefined;
    const unborn = try buildFixture(.unstage_all_unborn, &.{}, null, &unborn_buf);
    const rm = indexOf(unborn, "rm") orelse return error.MissingSubcommand;
    try testing.expectEqualStrings("--cached", unborn[rm + 1]);
    try testing.expectEqualStrings("-r", unborn[rm + 2]);
    try testing.expectEqualSlices([]const u8, &.{"."}, afterDashDash(unborn));
}

test "§2 커밋: commit -F <파일> — -m을 쓰지 않는다" {
    // 여러 줄·따옴표·비ASCII 메시지를 argv에 싣지 않기 위해서다.
    var buf: [64][]const u8 = undefined;
    const argv = try buildFixture(.commit, &.{}, "/tmp/msg", &buf);
    const commit = indexOf(argv, "commit") orelse return error.MissingSubcommand;
    try testing.expectEqualStrings("-F", argv[commit + 1]);
    try testing.expectEqualStrings("/tmp/msg", argv[commit + 2]);
    try testing.expect(!has(argv, "-m"));
    // 커밋에는 경로가 없으므로 `--`도 붙이지 않는다.
    try testing.expect(!has(argv, "--"));
}

test "`--`가 없으면 `-`로 시작하는 파일이 옵션이 된다 — 모든 경로 명령에 붙는다" {
    var buf: [64][]const u8 = undefined;
    for ([_]Kind{ .stage, .unstage, .unstage_unborn }) |kind| {
        const argv = try buildFixture(kind, &.{"-rf"}, null, &buf);
        const at = indexOf(argv, "--") orelse return error.MissingSeparator;
        // `-rf`가 `--` **뒤**에 있어야 파일 이름으로 해석된다.
        try testing.expect(indexOf(argv, "-rf").? > at);
    }
}

test "안전 술어: 절대경로·`..` 세그먼트·빈 경로·NUL을 조립에서 거부한다" {
    try testing.expectError(error.AbsolutePath, validatePath("/etc/passwd"));
    try testing.expectError(error.ParentSegment, validatePath("../outside"));
    try testing.expectError(error.ParentSegment, validatePath("src/../../outside"));
    try testing.expectError(error.EmptyPath, validatePath(""));
    try testing.expectError(error.EmbeddedNul, validatePath("a\x00b"));

    // 조립도 같은 이유로 거부한다 — 술어만 통과시키고 조립이 넘기면 의미가 없다.
    var buf: [64][]const u8 = undefined;
    try testing.expectError(error.ParentSegment, buildFixture(.stage, &.{ "ok.zig", "../escape" }, null, &buf));
}

test "안전 술어: `..`를 **세그먼트로만** 본다(멀쩡한 이름을 거부하지 않는다)" {
    // 문자열 포함 검사로 막으면 이 이름들이 전부 거부된다.
    try validatePath("..hidden");
    try validatePath("a..b.zig");
    try validatePath("dir/..leading/file");
    try validatePath("release-1..2.txt");
}

test "안전 술어: 공백·비ASCII·개행·`-` 시작 경로는 **통과한다**(셸을 안 거치므로 한 인자다)" {
    try validatePath("한글 파일 이름.txt");
    try validatePath("with space.zig");
    try validatePath("-leading-dash");
    try validatePath("weird\nname");
    try validatePath("emoji-🌱.md");
}

test "종류와 인자가 어긋나면 거부한다(빈 목록·모두-변종에 경로·커밋 메시지 짝)" {
    var buf: [64][]const u8 = undefined;
    // 빈 목록으로 `add --`를 부르면 아무 일도 안 하는데 호출자는 "했다"고 믿는다.
    try testing.expectError(error.NoPaths, buildFixture(.stage, &.{}, null, &buf));
    // `add -A -- <경로>`는 "모두"가 아니라 그 경로만 담는다 — 사용자가 누른 것과 다른 일이다.
    try testing.expectError(error.PathsNotAllowed, buildFixture(.stage_all, &.{"a.zig"}, null, &buf));
    try testing.expectError(error.MessageFileMismatch, buildFixture(.commit, &.{}, null, &buf));
    try testing.expectError(error.MessageFileMismatch, buildFixture(.stage, &.{"a.zig"}, "/tmp/msg", &buf));
}

test "버퍼가 모자라면 실패한다 — **자르지 않는다**" {
    // 자르면 경로 일부만 스테이지되고, 호출자는 전부 됐다고 믿는다.
    var small: [8][]const u8 = undefined;
    try testing.expectError(error.InsufficientArgvBuffer, buildFixture(.stage, &.{"a.zig"}, null, &small));
}

test "§1 환경: 쓰기에는 GIT_OPTIONAL_LOCKS가 **없다**(index를 잠가야 한다)" {
    // 읽기는 이 변수를 0으로 두어 index를 안 잠근다. 쓰기가 그러면 동시 실행이 index를 깬다.
    for (env_overrides) |e| {
        try testing.expect(!std.mem.eql(u8, e.name, "GIT_OPTIONAL_LOCKS"));
    }
    var seen_prompt = false;
    for (env_overrides) |e| {
        if (std.mem.eql(u8, e.name, "GIT_TERMINAL_PROMPT")) {
            try testing.expectEqualStrings("0", e.value);
            seen_prompt = true;
        }
    }
    try testing.expect(seen_prompt); // 프롬프트가 뜨면 그 명령은 영영 안 끝난다
}

test "§3 hook: 커밋만 허용하고 나머지 쓰기는 막는다" {
    var buf: [64][]const u8 = undefined;

    const commit = try buildFixture(.commit, &.{}, "/tmp/msg", &buf);
    try testing.expect(!has(commit, "core.hooksPath=/dev/null"));

    for ([_]Kind{ .stage, .unstage, .unstage_unborn, .stage_all, .unstage_all, .unstage_all_unborn }) |kind| {
        var k_buf: [64][]const u8 = undefined;
        const paths: []const []const u8 = if (kind.takesPaths()) &.{"a.zig"} else &.{};
        const argv = try buildFixture(kind, paths, null, &k_buf);
        try testing.expect(has(argv, "core.hooksPath=/dev/null"));
    }
}

test "외부 프로세스 차단은 읽기와 같다(pager·external diff·credential·ext 원격·quotePath)" {
    var buf: [64][]const u8 = undefined;
    const argv = try buildFixture(.stage, &.{"a.zig"}, null, &buf);
    try testing.expect(has(argv, "core.pager=cat"));
    try testing.expect(has(argv, "diff.external="));
    try testing.expect(has(argv, "credential.helper="));
    try testing.expect(has(argv, "protocol.ext.allow=never"));
    try testing.expect(has(argv, "core.quotePath=false"));
}

test "저장소는 -C로 준다(프로세스 cwd를 건드리지 않는다)" {
    var buf: [64][]const u8 = undefined;
    const argv = try buildFixture(.stage, &.{"a.zig"}, null, &buf);
    try testing.expectEqualStrings("/usr/bin/git", argv[0]);
    try testing.expectEqualStrings("-C", argv[1]);
    try testing.expectEqualStrings("/repo", argv[2]);
}

test "배치: 개수와 바이트 **둘 다**로 자르고, 큰 경로 하나는 혼자라도 넣는다" {
    // 개수만으로 자르면 경로가 길 때 ARG_MAX를 넘고, 바이트만으로 자르면 짧은 경로 수만 개에서 argv가 는다.
    var many: [max_batch_paths + 10][]const u8 = undefined;
    for (&many) |*p| p.* = "a.zig";
    try testing.expectEqual(max_batch_paths, batchEnd(&many, 0));

    // 상한을 넘기는 경로 하나 — 안 넣으면 그 파일을 영영 스테이지할 수 없다.
    const huge = "x" ** (max_batch_bytes + 1);
    const one = [_][]const u8{huge};
    try testing.expectEqual(@as(usize, 1), batchEnd(&one, 0));

    // 이어 부르면 진행한다(무한 루프가 되지 않는다).
    const two = [_][]const u8{ huge, huge };
    const first = batchEnd(&two, 0);
    try testing.expectEqual(@as(usize, 1), first);
    try testing.expectEqual(@as(usize, 2), batchEnd(&two, first));
    try testing.expectEqual(@as(usize, 2), batchEnd(&two, 2)); // 끝에서 부르면 그대로
}
