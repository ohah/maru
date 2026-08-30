//! 드롭한 파일 바이트를 maru ssh control socket으로 업로드한다(이미지 드롭 over SSH 3b). **posix
//! fork+pipe**로 ssh 자식 프로세스를 띄운다 — `std.process.Child`(0.16에서 io 기반으로 개편)를 피해
//! io 무관·스레드 안전하게 만든다(백그라운드 스레드에서 호출, 3c). maru `pty/macos.zig`의 fork+exec
//! 저수준 패턴(`std.c.*`)과 동일한 결이다. 순수 로직(파일명 정제·수신 셸 구절·크기 상한)은 cli/ssh.zig가
//! 단일 출처. 설계 근거: docs/ssh-integration.md §4.

const std = @import("std");
// cli/ssh.zig를 직접 import하면 root와 maru 두 모듈에 중복되므로(빌드 에러) maru 모듈을 통해 쓴다.
const ssh = @import("maru").cli.ssh;
const agent_hooks = @import("maru").cli.agent_hooks; // 원격 `maru` 를 찾는 PATH 처방(설치와 같은 값)

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

pub fn spawnAgentEvents(
    allocator: std.mem.Allocator,
    ctl: []const u8,
    dest: []const u8,
    remote_maru: []const u8,
    /// **원격 홈 기준 상대 경로**다(`agent_hook_command.remote_log_dir_rel`). 절대 경로가 아니다 —
    /// 저쪽 홈이 어디인지는 이쪽이 모르고, 안다고 가정하면 틀린다.
    remote_dir_rel: []const u8,
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
    const cmd = try std.fmt.allocPrint(
        allocator,
        "PATH=\"{s}:$PATH\"; exec {s} agent-events --stdio --dir=\"$HOME/{s}\"",
        .{ agent_hooks.remote_path_prefix, remote_maru, remote_dir_rel },
    );
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
