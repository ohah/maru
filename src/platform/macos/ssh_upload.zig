//! 드롭한 파일 바이트를 maru ssh control socket으로 업로드한다(이미지 드롭 over SSH 3b). **posix
//! fork+pipe**로 ssh 자식 프로세스를 띄운다 — `std.process.Child`(0.16에서 io 기반으로 개편)를 피해
//! io 무관·스레드 안전하게 만든다(백그라운드 스레드에서 호출, 3c). maru `pty/macos.zig`의 fork+exec
//! 저수준 패턴(`std.c.*`)과 동일한 결이다. 순수 로직(파일명 정제·수신 셸 구절·크기 상한)은 cli/ssh.zig가
//! 단일 출처. 설계 근거: docs/ssh-integration.md §4.

const std = @import("std");
// cli/ssh.zig를 직접 import하면 root와 maru 두 모듈에 중복되므로(빌드 에러) maru 모듈을 통해 쓴다.
const ssh = @import("maru").cli.ssh;
const remote_shell = @import("maru").session.remote_shell;
const git_command = @import("maru").session.git_command; // 굳히기 목록의 단일 출처(RW7)
const watch_install = @import("maru").session.remote_watch_install; // 원격 감시자 설치 계약(RW2a) — 경로 상수의 단일 출처 // 원격 셸 규율(PATH 처방 · `sh` 껍데기)

/// 스트리머가 원격에서 도는 **스크립트**(상수). `$1`=원격 maru 경로, `$2`=상대 디렉터리.
///
/// ⚠️ **PATH 를 앞에 붙인다 — 설치 명령과 같은 이유다.** `ssh host cmd` 의 PATH 는 흔히
/// `/usr/bin:/bin:/usr/sbin:/sbin` 뿐이라 `~/.local/bin` 이나 Homebrew 의 `maru` 를 못 찾는다.
/// 설치만 고치고 여기를 안 고치면 **설치는 되는데 스트리머가 안 뜨는** 상태가 된다 — 그러면 훅은
/// 쌓이는데 이벤트가 하나도 안 나오고, 증상은 「배지가 안 선다」로 앞의 실패와 구분되지 않는다.
///
/// ⚠️ **디렉터리는 큰따옴표다.** 작은따옴표로 감싸면 `$HOME` 이 확장되지 않아 원격 maru 가 리터럴
/// `$HOME/...` 이라는 이름의 디렉터리를 열려다 실패하고, 증상은 «hello 가 안 온다» 하나뿐이라 원인이
/// 화면에 안 나온다(실측). 인용을 아예 빼면 홈에 공백이 있는 계정에서 인자가 쪼개진다.
///
/// 이 문자열 전체는 [remote_shell](../../session/remote_shell.zig) 이 `sh -c` 껍데기 안에 넣는다 —
/// 로그인 셸이 POSIX 셸이 아닐 수 있기 때문이다(csh 실측은 그쪽 머리말).
const stream_script = remote_shell.path_assign ++
    "exec \"$1\" agent-events --stdio --dir=\"$HOME/$2\"";

/// 이어읽기 커서를 함께 넘기는 갈래([계획](../../../docs/plans/remote-agent-state.md) RA5-a).
///
/// **커서는 `"$3"` 으로 간다** — `remote_shell` 이 작은따옴표로 감싸므로 값이 셸에 해석되지 않고
/// `tokenIsSafe` 가 제어 문자를 막는다. 선을 타고 온 값이어도 인용 규칙이 그대로 지켜진다.
const stream_resume_script = remote_shell.path_assign ++
    "exec \"$1\" agent-events --stdio --dir=\"$HOME/$2\" --resume=\"$3\"";

pub const UploadError = error{
    PipeFailed, // pipe(2) 실패
    ForkFailed, // fork(2) 실패
    UploadFailed, // ssh 자식이 비정상 종료(exit != 0) 또는 출력 읽기 실패
    EmptyResponse, // 원격이 경로를 돌려주지 않음
};

/// 이미 읽어둔 파일 바이트를 업로드하고 **원격 절대경로**를 반환한다(호출자 소유). `ssh -S <ctl> <dest>
/// <uploadShellCommand>`를 자식 프로세스로 띄워 bytes를 stdin으로 흘리고, 원격이 stdout으로 돌려준
/// 절대경로를 받는다(원격 $HOME을 로컬이 모르므로 원격이 알려준다). `remote_name`은 호출자가
/// sanitizeDropFilename으로 정제해 넘긴다(셸 안전).
///
/// 파이프 데드락 회피: uploadShellCommand의 `cat`이 stdin을 다 받은 뒤에야 경로를 printf하므로, stdin을
/// 전부 쓰고 닫은 다음 stdout을 읽으면 write↔read가 동시에 블록될 일이 없다.
pub fn uploadBytes(
    allocator: std.mem.Allocator,
    ctl: []const u8,
    dest: []const u8,
    remote_name: []const u8,
    bytes: []const u8,
) ![]u8 {
    const cmd = try ssh.uploadShellCommand(allocator, remote_name);
    defer allocator.free(cmd);

    // null-term C argv: env ssh -S <ctl> <dest> <cmd>. 0.16 std엔 execvp(PATH 검색)가 없어 /usr/bin/env를
    // execve해 env(1)가 PATH에서 ssh를 찾게 한다(현재 env 상속 — SSH_AUTH_SOCK·ControlMaster 등; maru
    // wrapper도 env로 ssh를 실행해 일관). 문자열은 fork/exec까지 유효해야 하므로 dupeZ로 보관한다.
    const c_env0 = try allocator.dupeZ(u8, "env"); // execve argv[0](프로그램 이름)
    defer allocator.free(c_env0);
    const c_ssh = try allocator.dupeZ(u8, "ssh");
    defer allocator.free(c_ssh);
    const c_flag = try allocator.dupeZ(u8, "-S");
    defer allocator.free(c_flag);
    const c_ctl = try allocator.dupeZ(u8, ctl);
    defer allocator.free(c_ctl);
    const c_dest = try allocator.dupeZ(u8, dest);
    defer allocator.free(c_dest);
    const c_cmd = try allocator.dupeZ(u8, cmd);
    defer allocator.free(c_cmd);
    const argv = [_:null]?[*:0]const u8{ c_env0.ptr, c_ssh.ptr, c_flag.ptr, c_ctl.ptr, c_dest.ptr, c_cmd.ptr };

    // stdin/stdout 파이프(부모↔자식). [0]=read, [1]=write.
    var in_pipe: [2]c_int = undefined;
    if (std.c.pipe(&in_pipe) != 0) return UploadError.PipeFailed;
    var out_pipe: [2]c_int = undefined;
    if (std.c.pipe(&out_pipe) != 0) return UploadError.PipeFailed;

    const pid = std.c.fork();
    if (pid < 0) {
        for ([_]c_int{ in_pipe[0], in_pipe[1], out_pipe[0], out_pipe[1] }) |fd| _ = std.c.close(fd);
        return UploadError.ForkFailed;
    }
    if (pid == 0) {
        // child: stdin←in_pipe[0], stdout←out_pipe[1]. dup2/close/execvp만(async-signal-safe).
        _ = std.c.dup2(in_pipe[0], 0);
        _ = std.c.dup2(out_pipe[1], 1);
        _ = std.c.close(in_pipe[0]);
        _ = std.c.close(in_pipe[1]);
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        _ = std.c.execve("/usr/bin/env", &argv, @ptrCast(std.c.environ)); // env가 PATH에서 ssh를 찾는다
        std.c._exit(127); // execve 실패(/usr/bin/env 없음 등)
    }

    // parent: 안 쓰는 끝을 닫고, stdin으로 bytes를 흘린 뒤(원격 cat이 받음) 닫고, stdout에서 경로를 읽는다.
    _ = std.c.close(in_pipe[0]);
    _ = std.c.close(out_pipe[1]);

    writeAllFd(in_pipe[1], bytes);
    _ = std.c.close(in_pipe[1]); // EOF → 원격 cat 종료 → printf로 경로 출력

    const remote = readAllFd(allocator, out_pipe[0]) catch {
        _ = std.c.close(out_pipe[0]);
        _ = reapPid(pid);
        return UploadError.UploadFailed;
    };
    defer allocator.free(remote);
    _ = std.c.close(out_pipe[0]);

    if (reapPid(pid) != 0) return UploadError.UploadFailed;

    const trimmed = std.mem.trim(u8, remote, " \t\r\n");
    if (trimmed.len == 0) return UploadError.EmptyResponse;
    return allocator.dupe(u8, trimmed); // remote는 defer로 해제, trim 결과만 복사
}

/// 원격 이벤트 스트리머를 띄운다([계획](../../../docs/plans/remote-agent-state.md) RA5).
///
/// `uploadBytes` 와 **같은 방식**(fork + `/usr/bin/env ssh -S <ctl> <dest> <cmd>`)이지만 수명이 다르다 —
/// 업로드는 한 번 쓰고 EOF 를 기다리는 단발이고, 이쪽은 **계속 읽는 장수명 자식**이다. 그래서 fd 와 pid 를
/// 돌려주고 호출자가 읽기·수확을 맡는다.
///
/// **host 당 하나만 띄운다**(계약 §11.6 — `MaxSessions` 기본 10 에 다중화도 포함된다). pane 마다 띄우면
/// 같은 호스트 pane 다섯이 상한이 된다.
/// 감시자 스트림. `Stream` 과 달리 **stdin 쓰기 끝을 부모가 든다** — 그 fd 를 닫는 것이 조용한
/// 자식에게 보내는 유일한 정상 종료 신호다.
pub const WatchStream = struct {
    pid: std.c.pid_t,
    /// 자식 stdout(논블로킹). 호출자가 읽고 **닫는다**.
    out_fd: c_int,
    /// 자식 stdin 의 **쓰기 끝**. 아무것도 쓰지 않는다 — 이 fd 의 존재 자체가 「부모가 살아 있다」다.
    in_fd: c_int,
};

/// `exec <감시자> <루트>`.
///
/// ⚠️ **감시자 경로를 인자로 넘기지 않는다.** 그 경로에는 `$HOME` 이 들어 있는데, `wrapAlloc` 이
/// 인용한 인자 안에서는 **확장되지 않는다** — 원격이 리터럴 `$HOME/...` 을 열려다 실패하고 증상은
/// 「감시가 그냥 안 된다」뿐이다(에이전트 스트리머가 같은 함정에 한 번 빠졌다). 그래서 스크립트가
/// 직접 적고, 그 문자열은 **설치 계약의 상수**를 그대로 이어 붙여 단일 출처를 지킨다.
/// ⚠️ **PATH 처방을 지난다**(RW7a). 감시자 자체는 절대 경로로 부르므로 예전에는 PATH 가 필요 없었는데,
/// 폴링 갈래(RW7b)가 저쪽에서 `git` 을 찾아야 한다 — 비대화형 ssh 의 PATH 는 `/usr/bin:/bin:…` 뿐이라
/// Homebrew git·`$HOME/.local/bin` 이 안 보인다. 셸 대입은 `exec` 한 자식에게 그대로 전달된다(실측).
///
/// 인자가 여럿이라 `"$1"` 이 아니라 `"$@"` 다 — 루트 뒤에 **굳히기까지 끝난 git 앞머리**가 붙는다.
const watch_script = remote_shell.path_assign ++ "exec \"" ++ watch_install.remote_dir ++ "/" ++ watch_install.remote_binary ++ "\" \"$@\"";

pub const Stream = struct {
    pid: std.c.pid_t,
    /// 자식 stdout. 호출자가 읽고 **닫는다**.
    out_fd: c_int,
};

/// 원격에서 **한 번 도는 명령**을 띄운다([계획](../../../docs/plans/remote-agent-state.md) RA3 배선).
///
/// 스트리머(`spawnAgentEvents`)와 같은 모양이지만 수명이 다르다 — 이쪽은 곧 끝나고 그 **stdout 한 줄이
/// 결과**다. 그런데도 `uploadBytes` 처럼 동기로 기다리지 않는다: 이 함수는 tick 스레드에서 불리고,
/// ssh 왕복은 수백 ms 에서 몇 초다. 그동안 UI 가 멈추면 그것이 곧 «maru 가 원격에 붙을 때 뻗는다» 다.
/// 그래서 fd 를 돌려주고 **호출자가 논블로킹으로 훑는다**(스트리머와 같은 규율).
pub fn spawnRemoteCommand(
    allocator: std.mem.Allocator,
    ctl: []const u8,
    dest: []const u8,
    shell_command: []const u8,
) !Stream {
    const c_env0 = try allocator.dupeZ(u8, "env");
    defer allocator.free(c_env0);
    const c_ssh = try allocator.dupeZ(u8, "ssh");
    defer allocator.free(c_ssh);
    const c_flag = try allocator.dupeZ(u8, "-S");
    defer allocator.free(c_flag);
    const c_ctl = try allocator.dupeZ(u8, ctl);
    defer allocator.free(c_ctl);
    const c_dest = try allocator.dupeZ(u8, dest);
    defer allocator.free(c_dest);
    const c_cmd = try allocator.dupeZ(u8, shell_command);
    defer allocator.free(c_cmd);
    const argv = [_:null]?[*:0]const u8{ c_env0.ptr, c_ssh.ptr, c_flag.ptr, c_ctl.ptr, c_dest.ptr, c_cmd.ptr };

    var out_pipe: [2]c_int = undefined;
    if (std.c.pipe(&out_pipe) != 0) return UploadError.PipeFailed;

    const pid = std.c.fork();
    if (pid < 0) {
        for ([_]c_int{ out_pipe[0], out_pipe[1] }) |fd| _ = std.c.close(fd);
        return UploadError.ForkFailed;
    }
    if (pid == 0) {
        // **stdin 을 /dev/null 로 막는다** — 이 명령은 입력을 안 읽고, 열어 두면 부모가 죽었을 때
        // 그 fd 가 남아 자식이 안 끝난다(스트리머와 같은 이유).
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.close(devnull);
        }
        _ = std.c.dup2(out_pipe[1], 1);
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        _ = std.c.execve("/usr/bin/env", &argv, @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    _ = std.c.close(out_pipe[1]);
    return .{ .pid = pid, .out_fd = out_pipe[0] };
}

/// 이어읽기 커서를 **셸 문자열에 넣어도 되는가**. 통과 조건은 «셸이 특별하게 볼 글자가 하나도 없다» 다.
///
/// 파서(`agent_events.parseResumeEntry`)가 이미 이름을 토큰 클래스로 걸렀지만, 여기서 **다시** 본다 —
/// 그쪽은 「이 값이 우리 로그를 가리키나」를 묻고 이쪽은 「이 값을 셸에 줘도 되나」를 묻는다. 두 질문이
/// 같은 답을 낸다고 가정하면, 한쪽 규칙이 느슨해지는 날 다른 쪽이 조용히 뚫린다.
/// `--resume` 문자열 상한. **호출자가 이 값에 맞춰 커서 개수를 묶는다**(`RemoteAgentHost.cursor_max`
/// 옆의 comptime 검사) — 넘으면 이어읽기를 조용히 포기하므로, 그 조용함을 컴파일 시점으로 옮긴다.
pub const resume_spec_max: usize = 4096;

fn resumeIsShellSafe(spec: []const u8) bool {
    if (spec.len == 0) return true;
    if (spec.len > resume_spec_max) return false; // 상한이 없으면 명령줄이 무한히 길어진다
    for (spec) |c| switch (c) {
        'a'...'z', '0'...'9', '_', ':', ',' => {},
        else => return false,
    };
    return true;
}

pub fn spawnAgentEvents(
    allocator: std.mem.Allocator,
    ctl: []const u8,
    dest: []const u8,
    remote_maru: []const u8,
    /// **원격 홈 기준 상대 경로**다(`agent_hook_command.remote_log_dir_rel`). 절대 경로가 아니다 —
    /// 저쪽 홈이 어디인지는 이쪽이 모르고, 안다고 가정하면 틀린다.
    remote_dir_rel: []const u8,
    /// 이어읽기 커서(`<이름>:<offset>` 을 `,` 로 이은 것, RA5-a). 비면 안 붙인다 = 처음부터.
    ///
    /// ⚠️ **이 값은 선을 타고 온 것에서 나왔다.** 아래 인용 주석이 「우리 상수 하나라서 안전하다」고
    /// 적어 둔 전제가 여기서 깨지므로, **조립 직전에 다시 검증한다**(`resumeIsShellSafe`). 통과 못 하면
    /// 이어읽기를 포기하고 처음부터 읽는다 — 알림이 한 번 재생되는 것이 셸에 남의 문자열을 넣는 것보다
    /// 훨씬 싸다.
    resume_spec: []const u8,
) !Stream {
    // `<maru> agent-events --stdio --dir="$HOME/<rel>"`.
    //
    // ⚠️ **작은따옴표가 아니라 큰따옴표다.** 처음엔 경로를 작은따옴표로 감싼 채 `$HOME/...` 을 넣었는데,
    // 작은따옴표 안에서는 `$HOME` 이 **확장되지 않는다** — 원격 maru 가 리터럴 `$HOME/...` 이라는 디렉터리를
    // 열려다 실패하고, 증상은 «hello 가 안 온다» 하나뿐이라 원인이 화면에 안 나온다(실측으로 확인했다).
    // 인용을 아예 빼면 홈에 공백이 있는 계정에서 인자가 쪼개진다. 그래서 큰따옴표다.
    //
    // 큰따옴표 안에 들어가는 값이 **우리 상수 하나**라는 점이 이 인용을 안전하게 만든다 — 사용자 입력이
    // 여기 들어오게 되면 그때는 인용이 아니라 검증이 필요하다.
    // ⚠️ **PATH 를 앞에 붙인다 — 설치 명령과 같은 이유다.** `ssh host cmd` 의 PATH 는 흔히
    // `/usr/bin:/bin:/usr/sbin:/sbin` 뿐이라 `~/.local/bin` 이나 Homebrew 의 `maru` 를 못 찾는다.
    // 설치만 고치고 여기를 안 고치면 **설치는 되는데 스트리머가 안 뜨는** 상태가 된다 — 그러면 훅은
    // 쌓이는데 이벤트가 하나도 안 나오고, 증상은 「배지가 안 선다」로 앞의 실패와 구분되지 않는다.
    // 덮지 않고 앞에 붙이므로 사용자가 PATH 로 고른 `maru` 가 있으면 그쪽이 이긴다.
    const safe_resume: []const u8 = if (resumeIsShellSafe(resume_spec)) resume_spec else "";
    // **이어읽기가 있을 때만 그 스크립트를 쓴다.** `--resume` 은 새 플래그라, 원격 maru 가 옛것이면
    // 모르는 플래그로 보고 usage_error 로 나간다 — 첫 기동까지 그것을 요구하면 **원격을 안 올린
    // 사용자는 배지를 통째로 잃는다**. 첫 기동은 늘 커서가 비므로 옛 스크립트를 타고, 재접속(새 동작)
    // 에서만 새 플래그를 쓴다. 원격이 옛것이면 그 재접속만 실패해 백오프 뒤 notice 로 드러난다.
    const cmd = if (safe_resume.len == 0)
        try remote_shell.wrapAlloc(allocator, stream_script, &.{ remote_maru, remote_dir_rel })
    else
        try remote_shell.wrapAlloc(allocator, stream_resume_script, &.{ remote_maru, remote_dir_rel, safe_resume });
    defer allocator.free(cmd);

    const c_env0 = try allocator.dupeZ(u8, "env");
    defer allocator.free(c_env0);
    const c_ssh = try allocator.dupeZ(u8, "ssh");
    defer allocator.free(c_ssh);
    const c_flag = try allocator.dupeZ(u8, "-S");
    defer allocator.free(c_flag);
    const c_ctl = try allocator.dupeZ(u8, ctl);
    defer allocator.free(c_ctl);
    const c_dest = try allocator.dupeZ(u8, dest);
    defer allocator.free(c_dest);
    const c_cmd = try allocator.dupeZ(u8, cmd);
    defer allocator.free(c_cmd);
    const argv = [_:null]?[*:0]const u8{ c_env0.ptr, c_ssh.ptr, c_flag.ptr, c_ctl.ptr, c_dest.ptr, c_cmd.ptr };

    var out_pipe: [2]c_int = undefined;
    if (std.c.pipe(&out_pipe) != 0) return UploadError.PipeFailed;

    const pid = std.c.fork();
    if (pid < 0) {
        for ([_]c_int{ out_pipe[0], out_pipe[1] }) |fd| _ = std.c.close(fd);
        return UploadError.ForkFailed;
    }
    if (pid == 0) {
        // child: stdout→pipe. **stdin 은 /dev/null 로 막는다** — 스트리머는 입력을 안 읽고, 열어 두면
        // 부모가 죽었을 때 그 fd 가 남아 자식이 영영 안 끝난다.
        const devnull = std.c.open("/dev/null", .{ .ACCMODE = .RDONLY }, @as(std.c.mode_t, 0));
        if (devnull >= 0) {
            _ = std.c.dup2(devnull, 0);
            _ = std.c.close(devnull);
        }
        _ = std.c.dup2(out_pipe[1], 1);
        _ = std.c.close(out_pipe[0]);
        _ = std.c.close(out_pipe[1]);
        _ = std.c.execve("/usr/bin/env", &argv, @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    _ = std.c.close(out_pipe[1]);
    return .{ .pid = pid, .out_fd = out_pipe[0] };
}

/// **조용한 감시자를 위한 스트림**(RW3 — [계획](../../../docs/plans/remote-watch.md)).
///
/// `spawnAgentEvents` 와 fork·pipe·execve 모양이 같지만 **stdin 이 다르다.** 그쪽은 `/dev/null` 로
/// 막는데, 근거는 「스트리머는 입력을 안 읽고, 열어 두면 부모가 죽었을 때 자식이 영영 안 끝난다」다.
/// 감시자에는 그 논리가 **거꾸로** 적용된다:
///
/// - 감시자는 **설계상 조용하다**(바뀔 때만 출력). 그래서 부모가 죽어도 **EPIPE 를 못 받는다** —
///   실측에서 조용한 원격 프로세스는 ssh 가 SIGKILL 돼도 살아남았다(계획 §5).
/// - 그래서 stdin 을 **파이프**로 준다. 부모가 죽거나 닫으면 자식은 **EOF** 를 받고 스스로 끝낸다.
///
/// 즉 `/dev/null` 은 「쓰는 자식」의 고아 방지책이고, **파이프는 「조용한 자식」의 고아 방지책**이다.
pub fn spawnRemoteWatch(
    allocator: std.mem.Allocator,
    ctl: []const u8,
    dest: []const u8,
    /// 감시할 저장소 루트(원격 절대 경로).
    root: []const u8,
) !WatchStream {
    // 루트 뒤에 **git 앞머리**를 실어 보낸다(RW7b). 감시자가 폴링할 때 그대로 쓴다 — 굳히기 목록을
    // 두 벌로 두면 감시자만 문이 열린 채 돈다(단일 출처는 `git_command.config_overrides`).
    var args: [git_command.config_overrides.len + 2][]const u8 = undefined;
    args[0] = root;
    args[1] = "git";
    for (git_command.config_overrides, 0..) |token, i| args[i + 2] = token;
    const cmd = try remote_shell.wrapAlloc(allocator, watch_script, &args);
    defer allocator.free(cmd);

    const c_env0 = try allocator.dupeZ(u8, "env");
    defer allocator.free(c_env0);
    const c_ssh = try allocator.dupeZ(u8, "ssh");
    defer allocator.free(c_ssh);
    const c_flag = try allocator.dupeZ(u8, "-S");
    defer allocator.free(c_flag);
    const c_ctl = try allocator.dupeZ(u8, ctl);
    defer allocator.free(c_ctl);
    const c_dest = try allocator.dupeZ(u8, dest);
    defer allocator.free(c_dest);
    const c_cmd = try allocator.dupeZ(u8, cmd);
    defer allocator.free(c_cmd);
    const argv = [_:null]?[*:0]const u8{ c_env0.ptr, c_ssh.ptr, c_flag.ptr, c_ctl.ptr, c_dest.ptr, c_cmd.ptr };

    var out_pipe: [2]c_int = undefined;
    if (std.c.pipe(&out_pipe) != 0) return UploadError.PipeFailed;
    var in_pipe: [2]c_int = undefined;
    if (std.c.pipe(&in_pipe) != 0) {
        for ([_]c_int{ out_pipe[0], out_pipe[1] }) |fd| _ = std.c.close(fd);
        return UploadError.PipeFailed;
    }

    const pid = std.c.fork();
    if (pid < 0) {
        for ([_]c_int{ out_pipe[0], out_pipe[1], in_pipe[0], in_pipe[1] }) |fd| _ = std.c.close(fd);
        return UploadError.ForkFailed;
    }
    if (pid == 0) {
        _ = std.c.dup2(in_pipe[0], 0); // **파이프다** — 부모가 닫으면 감시자가 EOF 로 끝난다
        _ = std.c.dup2(out_pipe[1], 1);
        for ([_]c_int{ in_pipe[0], in_pipe[1], out_pipe[0], out_pipe[1] }) |fd| _ = std.c.close(fd);
        _ = std.c.execve("/usr/bin/env", &argv, @ptrCast(std.c.environ));
        std.c._exit(127);
    }
    _ = std.c.close(out_pipe[1]);
    _ = std.c.close(in_pipe[0]);
    // **읽기가 UI 를 안 멈춘다** — 틱이 드레인하므로 논블로킹이어야 한다(에이전트 채널과 같은 규율).
    const fl = std.c.fcntl(out_pipe[0], std.c.F.GETFL, @as(c_int, 0));
    if (fl >= 0) _ = std.c.fcntl(out_pipe[0], std.c.F.SETFL, fl | @as(c_int, @bitCast(std.posix.O{ .NONBLOCK = true })));
    return .{ .pid = pid, .out_fd = out_pipe[0], .in_fd = in_pipe[1] };
}

/// 감시자를 끝내고 **왜 끝났는지 돌려준다**(RW5). stdin 을 먼저 닫는다 — 그것이 감시자가 기다리는
/// 정상 종료 신호다(EOF). `SIGTERM` 은 그래도 안 끝날 때의 보루다: 조용한 자식이라 EPIPE 로는 안 죽는다.
///
/// ⚠️ **종료 코드를 버리지 않는다.** 감시자는 「한도를 넘었다」(`exit_watch_limit`)와 「못 돈다」
/// (`exit_unsupported`)를 코드로 말하는데, 그것을 안 보면 호출자는 **영원히 다시 띄운다** — 실측:
/// 즉시 실패하는 감시자에 30 초 동안 **7 번** 기동했다(백오프 주기 5 초 × 무한).
///
/// 반환은 `reapPid` 규약을 따른다: 정상 종료면 그 코드, 신호로 죽었으면 `-1`. 우리가 `SIGTERM` 을
/// 보낸 뒤라 **정상 정리에서는 보통 `-1`** 이다 — 호출자는 그 값을 「이유 없음」으로 읽어야 한다.
pub fn stopRemoteWatch(stream: WatchStream) c_int {
    if (stream.in_fd >= 0) _ = std.c.close(stream.in_fd); // ① EOF — 스스로 끝내게 한다
    if (stream.out_fd >= 0) _ = std.c.close(stream.out_fd);
    // ⚠️ `kill(0, …)` 은 프로세스 그룹 전체다 — pid 를 반드시 검사한다(에이전트 스트림과 같은 이유).
    if (stream.pid <= 0) return -1;
    _ = std.c.kill(stream.pid, std.c.SIG.TERM); // ② 보루
    return reapPid(stream.pid);
}

/// 스트리머를 끝낸다. **fd 를 먼저 닫는다** — 자식은 stdout 이 끊기면 다음 write 에서 EPIPE 로 죽는다.
/// 그래도 안 죽으면 `SIGTERM` 을 보낸다(무한 루프이므로 스스로는 안 끝난다).
pub fn stopAgentEvents(stream: Stream) void {
    if (stream.out_fd >= 0) _ = std.c.close(stream.out_fd);
    // ⚠️ **pid 를 검사하고 신호한다.** `kill(0, …)` 은 «호출자의 프로세스 그룹 **전체**» 이고 `kill(-1, …)`
    // 은 «보낼 수 있는 모든 프로세스» 다. 즉 pid 가 0/음수로 들어오면 이 한 줄이 GUI 자신과 그 아래 모든
    // 터미널 자식을 죽인다 — fork 실패 경로나 테스트가 만든 가짜 Stream 하나면 닿는 자리라 상한을 둔다.
    if (stream.pid <= 0) return;
    _ = std.c.kill(stream.pid, std.c.SIG.TERM);
    _ = reapPid(stream.pid);
}

/// fd에 data를 전부 쓴다(부분 write 루프). child가 죽어 write가 실패하면(EPIPE 등) 중단한다 — 실패는
/// exit code로 판정하므로 여기선 조용히 멈춘다.
fn writeAllFd(fd: c_int, data: []const u8) void {
    var off: usize = 0;
    while (off < data.len) {
        const n = std.c.write(fd, data.ptr + off, data.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

/// fd에서 EOF까지 읽어 돌려준다(호출자 소유). 원격 경로는 짧으므로 방어 상한(64KB)을 둔다.
fn readAllFd(allocator: std.mem.Allocator, fd: c_int) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var tmp: [4096]u8 = undefined;
    while (true) {
        const n = std.c.read(fd, &tmp, tmp.len);
        if (n < 0) return error.ReadFailed;
        if (n == 0) break; // EOF
        try buf.appendSlice(allocator, tmp[0..@intCast(n)]);
        if (buf.items.len > 64 * 1024) break;
    }
    return buf.toOwnedSlice(allocator);
}

/// 자식을 reap하고 exit code를 돌려준다(정상 종료가 아니면 -1).
fn reapPid(pid: std.c.pid_t) c_int {
    var status: c_int = 0;
    _ = std.c.waitpid(pid, &status, 0);
    const us: u32 = @bitCast(status); // W 매크로는 u32를 받는다(waitpid status는 c_int)
    if (std.c.W.IFEXITED(us)) return @intCast(std.c.W.EXITSTATUS(us));
    return -1;
}
