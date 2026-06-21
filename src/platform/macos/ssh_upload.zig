//! 드롭한 파일 바이트를 maru ssh control socket으로 업로드한다(이미지 드롭 over SSH 3b). **posix
//! fork+pipe**로 ssh 자식 프로세스를 띄운다 — `std.process.Child`(0.16에서 io 기반으로 개편)를 피해
//! io 무관·스레드 안전하게 만든다(백그라운드 스레드에서 호출, 3c). maru `pty/macos.zig`의 fork+exec
//! 저수준 패턴(`std.c.*`)과 동일한 결이다. 순수 로직(파일명 정제·수신 셸 구절·크기 상한)은 cli/ssh.zig가
//! 단일 출처. 설계 근거: docs/ssh-integration.md §4.

const std = @import("std");
// cli/ssh.zig를 직접 import하면 root와 maru 두 모듈에 중복되므로(빌드 에러) maru 모듈을 통해 쓴다.
const ssh = @import("maru").cli.ssh;

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
