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
const path_shape = @import("../path_shape.zig");
const scm_view = @import("scm_view.zig");
const remote_shell = @import("remote_shell.zig");

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
    /// `fetch --prune` — **우리가 직접 실행하는 유일한 네트워크 명령**이다(§4). 나머지(`push`·`pull`)는
    /// 저장소를 바꾸므로 사용자 터미널에 명령을 넣어 주고 실행은 사용자가 한다.
    ///
    /// 여기 있는 이유는 "쓰기"라서가 아니라 **읽기 명령의 전제를 뒤집기 때문이다**: 읽기는 네트워크를 아예
    /// 막고 credential helper를 빈 값으로 덮는데, fetch가 그러면 인증이 필요한 원격에서 **항상** 실패한다.
    /// 그 예외를 읽기 쪽에 두면 "네트워크 없음"이라는 그 모듈의 계약이 무너진다.
    fetch,

    /// 이 명령이 경로 인자를 받는가. `_all` 변종과 커밋은 받지 않는다 — 경로를 주면 조립을 거부한다
    /// (`add -A -- <경로>`는 "모두"가 아니라 그 경로만 담아 사용자가 누른 것과 다른 일을 한다).
    pub fn takesPaths(self: Kind) bool {
        return switch (self) {
            .stage, .unstage, .unstage_unborn => true,
            .stage_all, .unstage_all, .unstage_all_unborn, .commit, .fetch => false,
        };
    }

    /// hook을 허용하는가. **커밋만이다**(§3). fetch에도 hook이 있지만(`post-fetch`는 없고 `reference-transaction`이
    /// 돈다) 그건 사용자가 기대하는 동작이 아니라 우리가 배경에서 거는 갱신이므로 막는다.
    pub fn allowsHooks(self: Kind) bool {
        return self == .commit;
    }

    /// 네트워크를 쓰는가. **이 한 값이 credential helper와 환경을 가른다**(§4) — 나머지 명령은 helper를 빈
    /// 값으로 덮어 외부 프로그램 실행 경로를 닫지만, fetch는 그러면 인증이 필요한 원격에서 늘 실패한다.
    pub fn usesNetwork(self: Kind) bool {
        return self == .fetch;
    }

    /// `--`를 붙이는가. 경로를 받지 않는 명령 중에서도 `_all` 변종은 붙이고(§2 표의 형태다), 커밋·fetch는
    /// 뒤에 경로 자리가 아예 없어 붙이지 않는다.
    pub fn takesPathSeparator(self: Kind) bool {
        return switch (self) {
            .commit, .fetch => false,
            else => true,
        };
    }
};

/// 원격 실행 대상 · 명령 상한 · argv 길이는 [remote_shell](remote_shell.zig) 이 소유한다.
/// 읽기(`git_command.zig`)와 **전송은 공유하고 조립은 안 한다** — 갈린 축은 env·hook·stderr 이지
/// 「어느 소켓으로 보내나」가 아니다.
pub const Remote = remote_shell.Remote;
pub const max_remote_command_bytes = remote_shell.max_command_bytes;
pub const remote_argv_len = remote_shell.ssh_argv_len;

/// 원격에서 부를 git. 로컬은 절대경로 계약이지만 원격의 설치 위치는 우리가 모른다 — PATH 처방이
/// `remote_shell` 에 있고 그 껍데기가 이 명령을 감싼다.
pub const remote_git_exe = "git";

/// 원격 쓰기 명령. `build` 가 만든 로컬 argv 를 **인용해** 한 문자열로 접고, `ssh` argv 로 감싼다.
///
/// ⚠️ **커밋 메시지는 stdin 으로 간다.** 로컬은 `commit -F <파일>` 인데 그 파일은 **로컬에 있다** —
/// 원격에서 그 경로는 없거나 **남의 파일**이다. 호출자가 `message_file = "-"` 로 `build` 를 부르고
/// (그러면 `commit -F -` 가 나온다) 실행 층이 메시지 바이트를 stdin 으로 흘린다.
///
/// 실측(2026-09-01, harness sshd + ControlMaster): 제목·본문·따옴표·`$(…)`·한글이 **바이트 그대로**
/// 보존되고, `pre-commit` hook 은 git 이 stdin 을 **먼저 다 읽은 뒤** 빈 stdin 으로 받는다 —
/// hook 이 우리 메시지를 먹지 않는다.
///
/// ⚠️ **`argv[0]`(git_exe)은 버린다.** 로컬 절대경로는 원격에서 뜻이 없다 — `remote_git_exe` 로 바꾼다.
pub fn buildRemote(
    local_argv: []const []const u8,
    remote: Remote,
    buf: [][]const u8,
    cmd_buf: []u8,
) ?[]const []const u8 {
    if (local_argv.len < 2) return null; // 최소 `git -C <repo>` 는 있어야 한다
    var n: usize = 0;
    n = remote_shell.appendShPrologue(cmd_buf, n, remote_shell.exec_args_script) orelse return null;
    n = remote_shell.quoteAppend(cmd_buf, n, "env") orelse return null;
    // **env 목록은 명령 종류가 고른다**(fetch 만 갈린다). 로컬 실행 층과 **같은 목록**을 원격에도 싣는다 —
    // 한쪽만 실으면 「로컬에서는 막힌 프롬프트가 원격에서 뜬다」가 된다.
    for (envOverrides(kindOf(local_argv) orelse return null)) |o| {
        if (!remote_shell.tokenIsSafe(o.name) or !remote_shell.tokenIsSafe(o.value)) return null;
        if (n >= cmd_buf.len) return null;
        cmd_buf[n] = ' ';
        n += 1;
        // `K=V` 를 **한 토큰으로** 인용한다 — 셸이 인용을 벗기면 env(1) 가 그대로 한 인자로 받는다.
        var pair_buf: [256]u8 = undefined;
        const pair = std.fmt.bufPrint(&pair_buf, "{s}={s}", .{ o.name, o.value }) catch return null;
        n = remote_shell.quoteAppend(cmd_buf, n, pair) orelse return null;
    }
    if (n >= cmd_buf.len) return null;
    cmd_buf[n] = ' ';
    n += 1;
    n = remote_shell.quoteAppend(cmd_buf, n, remote_git_exe) orelse return null;
    for (local_argv[1..]) |token| {
        if (!remote_shell.tokenIsSafe(token)) return null;
        if (n >= cmd_buf.len) return null;
        cmd_buf[n] = ' ';
        n += 1;
        n = remote_shell.quoteAppend(cmd_buf, n, token) orelse return null;
    }
    return remote_shell.sshArgv(remote, buf, cmd_buf[0..n]);
}

/// 조립된 argv 에서 명령 종류를 되읽는다. **env 목록을 고르는 데만 쓴다** — 호출자가 kind 를 따로
/// 넘기면 「argv 는 fetch 인데 env 는 index」가 조용히 생긴다(그 둘이 갈리는 것이 §4 의 전부다).
fn kindOf(local_argv: []const []const u8) ?Kind {
    for (local_argv) |token| {
        if (std.mem.eql(u8, token, "fetch")) return .fetch;
        if (std.mem.eql(u8, token, "commit")) return .commit;
    }
    return .stage; // 나머지는 env 가 같다(`env_overrides`)
}

/// 경로가 거부되는 이유. **조립 단계에서 막는다** — 여기서 통과시키면 `--` 뒤라도 저장소 밖을 건드린다.
pub const PathError = error{
    /// 빈 경로. `git add -- ""`는 저장소 전체를 의미할 수 있다.
    EmptyPath,
    /// 절대경로. 저장소 루트 밖을 가리킨다. POSIX(`/x`)뿐 아니라 드라이브(`C:x`)·UNC도 포함한다
    /// (`path_shape.isAbsolute` — 가드는 자기 호스트가 모르는 모양도 막아야 한다).
    AbsolutePath,
    /// 역슬래시. Windows에서 진짜 구분자라 `..\..\x`가 아래 `..` 검사를 통과한 채 루트 밖으로 나간다.
    /// git 출력은 항상 `/`를 쓰므로 정상 입력을 잃지 않는다.
    BackslashSeparator,
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
///
/// 읽기 쪽 쌍둥이인 `repo_path.isSafeRelative`와 **같은 정책이어야 한다** — 한쪽만 고치면 "읽기는 엄격한데
/// 쓰기는 느슨한" 비대칭이 남고, 여기 통과한 경로는 `git add`/`git restore`/`git rm --cached`의 argv에 실린다.
/// 그래서 절대경로 판정을 `path[0]=='/'`에서 `path_shape.isAbsolute`로 넓히고 역슬래시를 함께 막는다:
/// 세그먼트를 `/`로만 쪼개므로 `..\..\secret`은 **세그먼트가 하나**여서 아래 `..` 검사를 그대로 통과하고,
/// Windows에서는 그것이 진짜 상위 이동이다(docs/windows-platform.md §5). git은 출력 경로에 항상 `/`를
/// 쓰므로 정상 입력을 잃지 않는다.
pub fn validatePath(path: []const u8) PathError!void {
    if (path.len == 0) return error.EmptyPath;
    if (path_shape.isAbsolute(path)) return error.AbsolutePath;
    if (std.mem.indexOfScalar(u8, path, '\\') != null) return error.BackslashSeparator;
    if (std.mem.indexOfScalar(u8, path, 0) != null) return error.EmbeddedNul;

    // `..`는 **세그먼트일 때만** 위험하다. `..foo`나 `foo..bar`는 평범한 이름이므로 문자열 포함 검사로 막으면
    // 멀쩡한 파일을 거부한다.
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        if (std.mem.eql(u8, segment, "..")) return error.ParentSegment;
    }
}

/// repository config가 외부 프로세스를 실행하지 못하게 덮어쓰는 `-c` 쌍. 읽기 쪽과 **같은 목록이되 hook과
/// 자격증명만 갈린다** — 그래서 배열을 복제하지 않고 그 둘만 조건부로 붙인다.
const shared_config_overrides = [_][]const u8{
    "-c", "core.pager=cat", //           pager 프로세스 실행 금지
    "-c", "diff.external=", //           external diff 프로그램 금지
    "-c", "protocol.ext.allow=never", // ext:: 원격 = 임의 명령 실행 벡터
    // 경로를 **있는 그대로** 주고받는다. 기본값(true)이면 비ASCII 경로를 C-quote해서 내주는데, 그 문자열을
    // 다시 git에 넘기면 "그런 파일 없음"이 된다(읽기 쪽과 같은 이유 — 한글 파일명이 전부 안 열렸다).
    "-c", "core.quotePath=false",
};

/// hook을 끄는 쌍. **커밋에는 붙이지 않는다**(§3).
const hooks_off = [_][]const u8{ "-c", "core.hooksPath=/dev/null" };

/// fetch에만 붙는 **멈춤 방지** 쌍. 원격이 연결은 됐는데 데이터가 안 오면 그 프로세스는 영영 안 끝나고,
/// 화면은 `가져오는 중…`에 고착돼 다시 누를 수도 없다(슬롯이 하나다). 20초 동안 1 KiB/s에도 못 미치면
/// 접는다 — **닿지 않는 호스트**는 이 값이 못 막고 OS의 TCP 타임아웃이 정한다(SSH 쪽은 `ConnectTimeout`이
/// 그 자리를 맡는다).
const fetch_stall_guards = [_][]const u8{
    "-c", "http.lowSpeedLimit=1024",
    "-c", "http.lowSpeedTime=20",
};

/// 자격증명 helper를 끄는 쌍. **fetch에는 붙이지 않는다**(§4) — 붙이면 인증이 필요한 원격에서 항상 실패한다.
/// 나머지 명령은 네트워크를 쓰지 않으므로 helper가 뜰 이유가 없고, 그건 곧 "config가 지정한 프로그램을 우리가
/// 실행하는" 경로라 닫아 둔다.
const credential_off = [_][]const u8{ "-c", "credential.helper=" };

pub const EnvOverride = struct { name: []const u8, value: []const u8 };

/// 하위 프로세스에 덮어써서 넘길 환경변수 — **네트워크를 쓰지 않는 명령**의 것.
///
/// **`GIT_OPTIONAL_LOCKS`가 여기 없는 것이 계약이다.** 읽기는 그것을 `0`으로 두어 index를 안 잠그지만, 쓰기가
/// 안 잠그면 동시 실행이 index를 깬다(§1). 실수로 추가되지 않도록 테스트가 부재를 고정한다.
pub const env_overrides = [_]EnvOverride{
    .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" }, // 프롬프트는 우리 화면에 못 그린다 — 뜨면 영영 안 끝난다
    .{ .name = "GIT_CONFIG_NOSYSTEM", .value = "1" }, // /etc/gitconfig 의 외부 프로그램 설정 배제
    .{ .name = "GIT_PAGER", .value = "cat" },
    .{ .name = "GIT_ASKPASS", .value = "" }, // 자격증명 프롬프트 프로그램 금지
};

/// fetch의 환경. 두 곳이 갈린다(§4).
///
/// - **`GIT_CONFIG_NOSYSTEM`이 없다.** macOS의 `credential.helper=osxkeychain`은 **시스템 config**가 준다
///   (실측 2026-08-18: `git config --show-origin --get credential.helper` →
///   `file:/Applications/Xcode.app/Contents/Developer/usr/share/git-core/gitconfig`). 그것을 배제하면 helper가
///   사라져 HTTPS 원격 fetch가 **항상** 인증 실패로 끝난다 — §4가 지키라고 한 바로 그 경로다. 시스템 config가
///   pager·external diff를 지정할 위험은 남지만, 위 `-c`가 config보다 **뒤에 이겨서** 그 축은 그대로 닫힌다.
/// - **`GIT_SSH_COMMAND`가 있다.** SSH 원격에서 `ssh-askpass`가 뜨는 상황은 우리 프로세스 밖이라 통제할 수
///   없다. `BatchMode=yes`로 **묻지 않고 실패**하게 한다(§4).
///
/// `GIT_ASKPASS`는 그대로 빈 값이다 — 빈 값이면 git이 터미널 프롬프트로 내려가고, 그건 `GIT_TERMINAL_PROMPT=0`이
/// 막는다. 즉 **우리가 자격증명을 묻는 창을 만들지 않는다**(§4)가 두 겹으로 성립한다.
pub const fetch_env_overrides = [_]EnvOverride{
    .{ .name = "GIT_TERMINAL_PROMPT", .value = "0" },
    // **비우는 것이 아니라 `0`으로 덮는다.** 목록에서 빼면 사용자 환경의 `GIT_CONFIG_NOSYSTEM=1`이 그대로
    // 상속돼(우리 프로세스는 상속 후 덮어쓰는 규율이다) 시스템 config가 배제되고, 그러면 macOS의
    // keychain helper가 사라져 위 예외가 무의미해진다. git은 이 값을 boolean으로 읽으므로 `0`이 곧 "쓴다"다.
    .{ .name = "GIT_CONFIG_NOSYSTEM", .value = "0" },
    .{ .name = "GIT_PAGER", .value = "cat" },
    .{ .name = "GIT_ASKPASS", .value = "" },
    // `ConnectTimeout`은 **닿지 않는 호스트**를 막는다(BatchMode는 묻는 것만 막는다) — 없으면 OS의 TCP
    // 타임아웃까지 슬롯이 잡혀 있고, 그 동안 화면은 `가져오는 중…`에 고착된다.
    .{ .name = "GIT_SSH_COMMAND", .value = "ssh -o BatchMode=yes -o ConnectTimeout=10" },
};

/// 그 명령이 쓸 환경 목록. 호출자(platform)는 이 함수만 부르고 어느 배열인지 고르지 않는다 — 고르게 두면
/// "fetch인데 읽기 환경으로 돌았다" 같은 어긋남이 실행 쪽에서 조용히 생긴다.
pub fn envOverrides(kind: Kind) []const EnvOverride {
    return if (kind.usesNetwork()) &fetch_env_overrides else &env_overrides;
}

/// 고정 인자 수의 상한(경로 제외). 가장 긴 형태가 `rm --cached -r -- .`(하위명령 3 + `--` + 대상 1)이라
/// 그 넷을 잡고 `--` 하나를 더한다. **정확히 이 값으로 조립되는지 테스트가 고정한다** — config를 하나
/// 늘리면 배열 길이가 따라오지만, 하위명령이 길어지면 여기 숫자를 손으로 고쳐야 한다.
/// **fetch도 이 안이다**: `credential.helper=`를 안 붙이는 대신 멈춤 방지 둘이 붙어(`-c` 넷) 같은 자리를
/// 쓰고, 하위명령은 `fetch --prune` 둘이라 `rm --cached -r -- .`보다 짧다.
pub const fixed_argv_max: usize = 3 + shared_config_overrides.len + hooks_off.len + credential_off.len + 4 + 1;

/// 한 번에 넘길 경로의 상한. `ARG_MAX`(macOS 기본 1 MiB)에 여유를 크게 두고 **바이트와 개수 둘 다**로 자른다 —
/// 경로 하나가 4 KiB까지 갈 수 있어 개수만으로는 상한이 안 선다.
pub const max_batch_paths: usize = 256;
pub const max_batch_bytes: usize = 64 * 1024;

/// 원격 배치의 **끝 인덱스**. `batchEnd` 와 갈린 이유는 상한이 다르기 때문이다(RS4a 6회차):
///
/// - 로컬은 `ARG_MAX`(64 KiB)로 자른다 — argv 를 그대로 `execve` 하므로 인용이 없다.
/// - 원격은 그 argv 를 **인용해 한 문자열로** 접어 8 KiB 버퍼(`max_remote_command_bytes`)에 담는다.
///   작은따옴표 하나가 `'\''` 4 바이트가 되므로 최악은 **4 배**다.
///
/// 두 상한을 같다고 두면 흔한 경로 길이(60 B)에서도 256 개가 원격 버퍼를 넘겨 `buildRemote` 가 null 을
/// 내고, 화면에는 「git 실패」만 뜬 채 **일부 파일이 조용히 안 스테이지된다.** 그래서 여기서 미리 자른다.
///
/// ⚠️ **오늘 이 함수를 부르는 제품 경로는 없다** — 행 하나가 경로 하나를 보내고(`submitRowWrite`),
/// `_all` 변종은 경로를 안 보낸다. 즉 이것은 **함정을 미리 막아 둔 것**이지 지금 나는 버그가 아니다.
/// 그래도 두는 이유: 배치를 처음 쓰는 호출자는 `batchEnd` 를 부를 것이고, 그 순간 원격에서만 조용히
/// 깨진다 — 그리고 그 깨짐은 **원격을 쓰는 사용자에게만** 보인다.
///
/// **경로 하나가 상한보다 커도 그 하나는 넣는다** — 안 넣으면 진행이 멈춰 그 파일을 영영 못 보낸다.
/// 그때는 `buildRemote` 가 null 로 알려 주고 그것은 §5 의 실패 경로다(조용히 빠지는 것과 다르다).
pub fn remoteBatchEnd(paths: []const []const u8, start: usize) usize {
    if (start >= paths.len) return start;
    // 껍데기(`'sh' '-c' '<스크립트>' 'sh' `) + env + `-c` 덮어쓰기 + 하위명령에 넉넉한 자리를 남긴다.
    const reserve: usize = 2 * 1024;
    const budget = if (max_remote_command_bytes > reserve) max_remote_command_bytes - reserve else 0;
    var bytes: usize = 0;
    var end = start;
    while (end < paths.len) : (end += 1) {
        const next = bytes + paths[end].len * 4 + 3; // 최악 인용(×4) + `''` + 구분 공백
        if (end > start and (end - start >= max_batch_paths or next > budget)) break;
        bytes = next;
    }
    return end;
}

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
    if (kind.usesNetwork()) {
        for (fetch_stall_guards) |override| {
            buf[n] = override;
            n += 1;
        }
    } else {
        for (credential_off) |override| {
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
        // **`--prune`이 붙는다**(§4). 안 붙이면 원격에서 지워진 브랜치의 remote-tracking ref가 영영 남고,
        // 그 ref는 화면의 ahead/behind와 히스토리 칩에 계속 뜬다 — 사라진 브랜치를 "있다"고 말하게 된다.
        .fetch => {
            buf[n] = "fetch";
            n += 1;
            buf[n] = "--prune";
            n += 1;
        },
    }

    // **`--`는 커밋·fetch를 뺀 모든 쓰기에 붙는다.** 없으면 `-`로 시작하는 파일 이름이 옵션으로 해석된다(§2).
    // `_all` 변종도 예외가 아니다 — `add -A --`·`restore --staged -- .`가 §2 표의 형태다. 커밋과 fetch는
    // 뒤에 경로 자리가 아예 없어 붙일 대상이 없다(fetch에 `--`를 붙이면 refspec 자리가 열린다).
    if (kind.takesPathSeparator()) {
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
        .stage_all, .commit, .fetch => {},
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

// 이 술어는 읽기 쪽 쌍둥이(`repo_path.isSafeRelative`)와 **같은 정책이어야 한다.** 한때 읽기만 Windows 모양을
// 막고 쓰기는 옛 `path[0]=='/'`에 머물러, `git add --` argv를 지키는 층이 Windows에서 무력화돼 있었다
// (docs/windows-platform.md §5). 여기 통과한 경로는 곧바로 argv에 실린다.
test "안전 술어: Windows 경로 모양도 거부한다 — 읽기 쪽 가드와 같은 정책" {
    // 역슬래시 탈출: `/`로 쪼개면 세그먼트가 하나라 `..` 검사를 통과했다.
    try testing.expectError(error.BackslashSeparator, validatePath("..\\..\\secret"));
    try testing.expectError(error.BackslashSeparator, validatePath("a\\..\\..\\b"));
    try testing.expectError(error.BackslashSeparator, validatePath("a\\b"));

    // 드라이브 절대·드라이브 상대·UNC — 옛 판정은 전부 상대로 통과시켰다.
    try testing.expectError(error.AbsolutePath, validatePath("C:/Windows/System32"));
    try testing.expectError(error.AbsolutePath, validatePath("C:relative"));
    try testing.expectError(error.AbsolutePath, validatePath("//server/share"));
    try testing.expectError(error.AbsolutePath, validatePath("1:/x")); // 드라이브 문자는 A–Z가 아니어도 된다

    // 조립까지 막힌다.
    var buf: [64][]const u8 = undefined;
    try testing.expectError(error.BackslashSeparator, buildFixture(.stage, &.{ "ok.zig", "..\\escape" }, null, &buf));

    // 드라이브 문자처럼 **생겼을 뿐인** 정상 경로는 계속 통과한다.
    try validatePath("C/main.zig");
    try validatePath("src/c.zig");
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

    for ([_]Kind{ .stage, .unstage, .unstage_unborn, .stage_all, .unstage_all, .unstage_all_unborn, .fetch }) |kind| {
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

test "§4 fetch: `fetch --prune`이고 경로 자리가 없다" {
    var buf: [64][]const u8 = undefined;
    const argv = try buildFixture(.fetch, &.{}, null, &buf);
    try testing.expect(has(argv, "fetch"));
    // **`--prune`**: 없으면 원격에서 지워진 브랜치의 remote-tracking ref가 남아 화면이 없는 브랜치를 말한다.
    try testing.expect(has(argv, "--prune"));
    // `--`를 붙이면 refspec 자리가 열린다 — fetch는 뒤에 아무것도 오지 않는다.
    try testing.expect(!has(argv, "--"));
    try testing.expectEqualStrings("--prune", argv[argv.len - 1]);
    // 경로를 주면 거부한다(§2 규율 — "모두"가 아닌 다른 일을 하게 된다).
    var p_buf: [64][]const u8 = undefined;
    try testing.expectError(error.PathsNotAllowed, buildFixture(.fetch, &.{"a.zig"}, null, &p_buf));
    // 메시지 파일도 커밋 전용이다.
    var m_buf: [64][]const u8 = undefined;
    try testing.expectError(error.MessageFileMismatch, buildFixture(.fetch, &.{}, "/tmp/msg", &m_buf));
}

test "§4 fetch만 credential helper를 살려 둔다(나머지는 끈다)" {
    // 끄면 인증이 필요한 원격에서 **항상** 실패한다 — §4가 이 예외를 명시한다.
    var f_buf: [64][]const u8 = undefined;
    const fetch_argv = try buildFixture(.fetch, &.{}, null, &f_buf);
    try testing.expect(!has(fetch_argv, "credential.helper="));
    // 나머지 축(pager·external diff·ext 원격)은 fetch에서도 그대로 닫혀 있다.
    try testing.expect(has(fetch_argv, "core.pager=cat"));
    try testing.expect(has(fetch_argv, "diff.external="));
    try testing.expect(has(fetch_argv, "protocol.ext.allow=never"));
    // 멈춤 방지 — 연결은 됐는데 데이터가 안 오는 원격에서 슬롯이 영영 잡히지 않게.
    try testing.expect(has(fetch_argv, "http.lowSpeedLimit=1024"));
    try testing.expect(has(fetch_argv, "http.lowSpeedTime=20"));
    // 그 둘은 **fetch에만** 붙는다(네트워크를 안 쓰는 명령에 http 설정을 얹을 이유가 없다).
    var s_buf: [64][]const u8 = undefined;
    const stage_argv = try buildFixture(.stage, &.{"a.zig"}, null, &s_buf);
    try testing.expect(!has(stage_argv, "http.lowSpeedLimit=1024"));
    // 어느 형태든 버퍼 상한 안이다.
    try testing.expect(fetch_argv.len <= fixed_argv_max);

    for ([_]Kind{ .stage, .unstage, .stage_all, .commit }) |kind| {
        var k_buf: [64][]const u8 = undefined;
        const paths: []const []const u8 = if (kind.takesPaths()) &.{"a.zig"} else &.{};
        const message: ?[]const u8 = if (kind == .commit) "/tmp/msg" else null;
        const argv = try buildFixture(kind, paths, message, &k_buf);
        try testing.expect(has(argv, "credential.helper="));
    }
}

test "§4 fetch 환경: 시스템 config를 배제하지 않고 ssh는 BatchMode로 묻지 않는다" {
    const fetch_env = envOverrides(.fetch);
    // **`GIT_CONFIG_NOSYSTEM`을 `0`으로 덮는다.** macOS의 `credential.helper=osxkeychain`이 시스템 config에서
    // 오므로(실측 2026-08-18) 배제하면 HTTPS 원격이 늘 인증 실패로 끝난다.
    // **없는 것이 아니라 `0`이다** — 목록에서 빼면 사용자 환경의 `=1`이 상속돼 같은 사고가 난다.
    var seen_nosystem = false;
    for (fetch_env) |e| if (std.mem.eql(u8, e.name, "GIT_CONFIG_NOSYSTEM")) {
        try testing.expectEqualStrings("0", e.value);
        seen_nosystem = true;
    };
    try testing.expect(seen_nosystem);
    // 네트워크를 안 쓰는 쪽은 여전히 배제한다(그쪽은 helper가 필요 없다).
    var seen_off = false;
    for (env_overrides) |e| if (std.mem.eql(u8, e.name, "GIT_CONFIG_NOSYSTEM")) {
        try testing.expectEqualStrings("1", e.value);
        seen_off = true;
    };
    try testing.expect(seen_off);

    var seen_ssh = false;
    var seen_prompt = false;
    var seen_askpass = false;
    for (fetch_env) |e| {
        if (std.mem.eql(u8, e.name, "GIT_SSH_COMMAND")) {
            // 묻지 않고 실패한다 — `ssh-askpass`는 우리 프로세스 밖이라 통제할 수 없다.
            try testing.expect(std.mem.indexOf(u8, e.value, "BatchMode=yes") != null);
            // 닿지 않는 호스트도 접는다 — BatchMode는 "묻지 않는다"일 뿐 "기다리지 않는다"가 아니다.
            try testing.expect(std.mem.indexOf(u8, e.value, "ConnectTimeout=") != null);
            seen_ssh = true;
        }
        if (std.mem.eql(u8, e.name, "GIT_TERMINAL_PROMPT")) {
            try testing.expectEqualStrings("0", e.value);
            seen_prompt = true;
        }
        // 빈 값이면 git이 터미널 프롬프트로 내려가고 그건 위 변수가 막는다 — 자격증명 창을 우리가 안 만든다.
        if (std.mem.eql(u8, e.name, "GIT_ASKPASS")) {
            try testing.expectEqualStrings("", e.value);
            seen_askpass = true;
        }
    }
    try testing.expect(seen_ssh and seen_prompt and seen_askpass);

    // 명령 종류가 목록을 고른다 — 고르는 곳이 둘이면 "fetch인데 읽기 환경으로 돌았다"가 조용히 생긴다.
    for ([_]Kind{ .stage, .unstage, .stage_all, .commit }) |kind| {
        try testing.expectEqual(@as(usize, env_overrides.len), envOverrides(kind).len);
    }
    try testing.expectEqual(@as(usize, fetch_env_overrides.len), envOverrides(.fetch).len);
}

test "저장소는 -C로 준다(프로세스 cwd를 건드리지 않는다)" {
    var buf: [64][]const u8 = undefined;
    const argv = try buildFixture(.stage, &.{"a.zig"}, null, &buf);
    try testing.expectEqualStrings("/usr/bin/git", argv[0]);
    try testing.expectEqualStrings("-C", argv[1]);
    try testing.expectEqualStrings("/repo", argv[2]);
}

test "고정 인자 상한이 가장 긴 형태를 정확히 담는다" {
    // `fixed_argv_max`가 모자라면 `_all` 변종이 조립 단계에서 죽고, 넉넉하면 그 사실을 아무도 모른 채
    // 상한이 낡는다. 가장 긴 형태를 **딱 그 크기 버퍼**로 조립해 둘 다 막는다.
    var exact: [fixed_argv_max][]const u8 = undefined;
    const argv = try buildFixture(.unstage_all_unborn, &.{}, null, &exact);
    try testing.expectEqual(fixed_argv_max, argv.len);
    try testing.expectEqualStrings(".", argv[argv.len - 1]);
    try testing.expectEqualStrings("--", argv[argv.len - 2]);
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

// ── 행·섹션이 무슨 명령을 원하는가 ──────────────────────────────────────────────────────────
//
// **`unborn` 특례가 둘 다에 있다.** 첫 커밋 전에는 `HEAD` 가 없어 `restore --staged` 가 못 돈다 —
// `rm --cached` 여야 한다. 이 판정을 호출자가 각자 적으면 한쪽만 그 특례를 갖고, 증상은 **첫 커밋
// 전 저장소에서만** 언스테이지가 안 되는 것이라 눈에 잘 안 띈다. macOS 와 Windows 가 같은 화면을
// 쓰므로 여기 한 곳에 둔다.

/// 파일 행 하나가 원하는 명령. **`null` 은 "아무 일도 없다"** 이지 오류가 아니다 — 충돌 행은 모델이
/// 이미 `.none` 으로 판정해 둔다(`git add` 가 충돌을 "해결됨" 으로 표시하므로 그 행에 동작을 붙이면
/// 사용자가 의도하지 않은 해결이 일어난다).
pub fn kindForRow(action: scm_view.RowAction, unborn: bool) ?Kind {
    return switch (action) {
        .stage => .stage,
        .unstage => if (unborn) .unstage_unborn else .unstage,
        .none => null,
    };
}

/// 섹션 머리 줄의 일괄 명령. `_all` 변종은 경로를 받지 않는다 — **화면에 안 보이는 파일까지 든다**
/// 는 뜻이고, 그것이 "모두" 다.
pub fn kindForSection(section: scm_view.Section, unborn: bool) Kind {
    return switch (section) {
        .staged => if (unborn) .unstage_all_unborn else .unstage_all,
        .changes => .stage_all,
    };
}

test "행: 스테이지·언스테이지·충돌" {
    try testing.expectEqual(Kind.stage, kindForRow(.stage, false).?);
    try testing.expectEqual(Kind.unstage, kindForRow(.unstage, false).?);
    // **첫 커밋 전에는 `restore --staged` 가 못 돈다** — `HEAD` 가 없다.
    try testing.expectEqual(Kind.unstage_unborn, kindForRow(.unstage, true).?);
    // 스테이지는 unborn 에서도 같다(`add` 는 HEAD 를 안 본다).
    try testing.expectEqual(Kind.stage, kindForRow(.stage, true).?);
    // 충돌 행은 아무 일도 없다.
    try testing.expectEqual(@as(?Kind, null), kindForRow(.none, false));
    try testing.expectEqual(@as(?Kind, null), kindForRow(.none, true));
}

test "섹션: 일괄 명령도 unborn 특례를 탄다" {
    try testing.expectEqual(Kind.stage_all, kindForSection(.changes, false));
    try testing.expectEqual(Kind.stage_all, kindForSection(.changes, true));
    try testing.expectEqual(Kind.unstage_all, kindForSection(.staged, false));
    try testing.expectEqual(Kind.unstage_all_unborn, kindForSection(.staged, true));
}

test "이 넷은 경로를 안 받는다 — 조립이 거부한다" {
    // `kindForSection` 이 내는 것과 `takesPaths` 가 서로 어긋나면 조립이 실패한다. 그 짝을 고정한다.
    try testing.expect(!kindForSection(.changes, false).takesPaths());
    try testing.expect(!kindForSection(.staged, false).takesPaths());
    try testing.expect(!kindForSection(.staged, true).takesPaths());
    // 행 명령은 반대로 **받아야** 한다.
    try testing.expect(kindForRow(.stage, false).?.takesPaths());
    try testing.expect(kindForRow(.unstage, true).?.takesPaths());
}

// ── RS4a 적대적 검증 ────────────────────────────────────────────────────────────────────────
//
// 원격 쓰기는 **남의 기계의 index 를 바꾼다.** 읽기가 틀리면 잘못 보여 주고 끝이지만 이쪽은 되돌릴 것이
// 남는다. 그래서 「로컬에서 닫아 둔 것이 원격에서도 닫혀 있는가」를 전수로 짚는다.

test "원격 쓰기: 로컬이 닫아 둔 구멍이 원격에서도 닫혀 있다 (RS4a 1회차)" {
    var argv: [fixed_argv_max + max_batch_paths][]const u8 = undefined;
    var rbuf: [remote_argv_len][]const u8 = undefined;
    var cmd: [max_remote_command_bytes]u8 = undefined;
    const local = try build(.stage, "/usr/bin/git", "/srv/app", &.{"a.txt"}, null, &argv);
    const remote = buildRemote(local, .{ .dest = "u@h", .control_path = "/tmp/c" }, &rbuf, &cmd).?;
    const line = remote[remote.len - 1];

    // ⑴ **`-c` 덮어쓰기가 하나도 빠지지 않는다.** 하나라도 빠지면 그 구멍이 원격에서만 열린다
    //    (예: `core.hooksPath` 가 빠지면 남의 저장소 훅을 우리가 실행한다).
    for (local[1..]) |token| {
        var quoted_buf: [512]u8 = undefined;
        const n = quoteAppendForTest(&quoted_buf, 0, token) orelse return error.Unexpected;
        try std.testing.expect(std.mem.indexOf(u8, line, quoted_buf[0..n]) != null);
    }
    // ⑵ **env 도 같은 목록이다.** 로컬 실행 층이 덮어쓰는 것과 원격이 다르면, 로컬에서 막힌 프롬프트가
    //    원격에서 뜬다 — 그러면 그 명령은 영영 안 끝난다.
    for (envOverrides(.stage)) |o| {
        var pair_buf: [256]u8 = undefined;
        const pair = try std.fmt.bufPrint(&pair_buf, "'{s}={s}'", .{ o.name, o.value });
        try std.testing.expect(std.mem.indexOf(u8, line, pair) != null);
    }
    // ⑶ **`GIT_OPTIONAL_LOCKS` 는 원격에도 없다** — 쓰기는 index 를 잠가야 한다(§1).
    try std.testing.expect(std.mem.indexOf(u8, line, "GIT_OPTIONAL_LOCKS") == null);
    // ⑷ **로컬 git 절대경로는 원격에 안 간다** — 그 경로는 남의 기계에서 뜻이 없다.
    try std.testing.expect(std.mem.indexOf(u8, line, "/usr/bin/git") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "'git'") != null);
    // ⑸ 로그인 셸에는 인용된 토큰만 간다(csh/tcsh 실측 — `remote_shell` 머리말).
    try std.testing.expect(std.mem.startsWith(u8, line, "'sh' '-c' '"));
}

test "원격 쓰기: fetch 는 fetch env 로만 조립된다 (RS4a 2회차)" {
    var argv: [fixed_argv_max + max_batch_paths][]const u8 = undefined;
    var rbuf: [remote_argv_len][]const u8 = undefined;
    var cmd: [max_remote_command_bytes]u8 = undefined;
    const local = try build(.fetch, "/usr/bin/git", "/srv/app", &.{}, null, &argv);
    const remote = buildRemote(local, .{ .dest = "u@h", .control_path = "/tmp/c" }, &rbuf, &cmd).?;
    const line = remote[remote.len - 1];
    // **argv 는 fetch 인데 env 는 index** 가 되면 안 된다 — 그 둘이 갈리는 것이 §4 의 전부다.
    // `kindOf` 가 argv 에서 되읽으므로 호출자가 kind 를 잘못 넘길 자리가 없다.
    try std.testing.expect(std.mem.indexOf(u8, line, "'GIT_CONFIG_NOSYSTEM=0'") != null); // fetch 판
    try std.testing.expect(std.mem.indexOf(u8, line, "'GIT_CONFIG_NOSYSTEM=1'") == null); // index 판이 아니다
    try std.testing.expect(std.mem.indexOf(u8, line, "GIT_SSH_COMMAND") != null);

    const local_stage = try build(.stage, "/usr/bin/git", "/srv/app", &.{"a.txt"}, null, &argv);
    const stage = buildRemote(local_stage, .{ .dest = "u@h", .control_path = "/tmp/c" }, &rbuf, &cmd).?;
    const sline = stage[stage.len - 1];
    try std.testing.expect(std.mem.indexOf(u8, sline, "'GIT_CONFIG_NOSYSTEM=1'") != null);
    try std.testing.expect(std.mem.indexOf(u8, sline, "GIT_SSH_COMMAND") == null);
}

test "원격 쓰기: 셸 메타문자가 든 경로도 한 인자로 도착한다 (RS4a 3회차)" {
    var argv: [fixed_argv_max + max_batch_paths][]const u8 = undefined;
    var rbuf: [remote_argv_len][]const u8 = undefined;
    var cmd: [max_remote_command_bytes]u8 = undefined;
    const nasty = "it's a; $(touch /tmp/pwned) `id` *.txt";
    const local = try build(.stage, "/usr/bin/git", "/srv/app", &.{nasty}, null, &argv);
    const remote = buildRemote(local, .{ .dest = "u@h", .control_path = "/tmp/c" }, &rbuf, &cmd).?;
    const line = remote[remote.len - 1];

    // 인용 밖에 위험한 문자가 하나도 없다 — 이 문자열은 **남의 셸**이 파싱한다.
    var in_quote = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (!in_quote and c == '\\') {
            try std.testing.expect(i + 1 < line.len);
            i += 1;
            continue;
        }
        if (c == '\'') {
            in_quote = !in_quote;
            continue;
        }
        if (in_quote) continue;
        try std.testing.expect(c == ' ');
    }
    try std.testing.expect(!in_quote);
    // 제어문자가 든 경로는 **명령 자체를 만들지 않는다**.
    const ctrl = try build(.stage, "/usr/bin/git", "/srv/app", &.{"a\nb.txt"}, null, &argv);
    try std.testing.expect(buildRemote(ctrl, .{ .dest = "u@h", .control_path = "/tmp/c" }, &rbuf, &cmd) == null);
}

/// 판정자가 인용 결과를 대조하려고 쓴다 — 제품과 **같은 함수**를 지난다(두 벌이면 판정이 무의미하다).
fn quoteAppendForTest(out: []u8, at: usize, token: []const u8) ?usize {
    return remote_shell.quoteAppend(out, at, token);
}

test "원격 쓰기: 로컬 배치가 원격 명령 버퍼를 넘긴다 (RS4a 6회차)" {
    // **로컬 배치 상한과 원격 명령 상한은 서로 모른다.** 로컬은 `ARG_MAX`(64 KiB)로 자르는데 원격은
    // 인용이 붙어 최대 4 배로 부푼 문자열을 8 KiB 버퍼에 담는다. 그 차이만큼 **조용히 못 보낸다.**
    var argv: [fixed_argv_max + max_batch_paths][]const u8 = undefined;
    var rbuf: [remote_argv_len][]const u8 = undefined;
    var cmd: [max_remote_command_bytes]u8 = undefined;

    var paths_buf: [max_batch_paths][]const u8 = undefined;
    const one = "src/platform/macos/app_session/some_reasonably_long_name.zig"; // 60 B — 흔한 길이다
    for (&paths_buf) |*p| p.* = one;

    // ⚠️ 오늘 배치를 쓰는 제품 경로는 없다 — 이 판정자는 **첫 호출자가 밟을 함정**을 고정한다.
    // 로컬 배치는 이 전부를 **한 번에** 보내라고 말한다(60 B × 256 ≈ 15.6 KB < 64 KiB).
    try std.testing.expectEqual(max_batch_paths, batchEnd(&paths_buf, 0));
    const local = try build(.stage, "/usr/bin/git", "/srv/app", &paths_buf, null, &argv);

    // 그런데 원격은 **만들지 못한다** — 이것이 이 판정자가 잡는 사실이다.
    const overflow = buildRemote(local, .{ .dest = "u@h", .control_path = "/tmp/c" }, &rbuf, &cmd);
    try std.testing.expect(overflow == null);

    // 그래서 **원격 배치는 따로 센다.** 그 상한으로 자르면 반드시 만들어진다.
    var start: usize = 0;
    var rounds: usize = 0;
    while (start < paths_buf.len) : (rounds += 1) {
        const end = remoteBatchEnd(&paths_buf, start);
        try std.testing.expect(end > start); // 진행이 멈추면 그 파일을 영영 못 스테이지한다
        const chunk = try build(.stage, "/usr/bin/git", "/srv/app", paths_buf[start..end], null, &argv);
        try std.testing.expect(buildRemote(chunk, .{ .dest = "u@h", .control_path = "/tmp/c" }, &rbuf, &cmd) != null);
        start = end;
    }
    try std.testing.expect(rounds > 1); // 실제로 쪼개졌다(안 쪼개졌으면 이 판정자는 아무것도 안 본다)
}

test "원격 배치: 한 경로가 상한보다 커도 그 하나는 넣는다 (RS4a 6회차)" {
    // 안 넣으면 진행이 멈춰 그 파일을 **영영** 스테이지할 수 없다. 실제 초과는 `buildRemote` 가
    // null 로 알려 주고, 그것은 §5 의 실패 경로다 — 조용히 빠지는 것과 다르다.
    const huge = "'" ** 4096; // 인용이 4 배로 부푸는 최악
    const paths = [_][]const u8{ huge, "a.txt" };
    try std.testing.expectEqual(@as(usize, 1), remoteBatchEnd(&paths, 0));
    try std.testing.expectEqual(@as(usize, 2), remoteBatchEnd(&paths, 1));
}
