// PoC only: one parent owns group creation; the child cannot exec before release.
fn pocForkGrouped() Error!c.pid_t {
    var gate: [2]c.fd_t = undefined;
    if (!openPipe(&gate)) return error.PipeFailed;
    const pid = c.fork();
    if (pid < 0) {
        closePipe(&gate);
        return error.SpawnFailed;
    }
    if (pid == 0) {
        _ = c.close(gate[1]);
        var token: [1]u8 = undefined;
        while (true) {
            const n = c.read(gate[0], &token, 1);
            if (n < 0 and posix.errno(n) == .INTR) continue;
            if (n != 1 or token[0] != 1) c._exit(126);
            break;
        }
        _ = c.close(gate[0]);
        return 0;
    }
    _ = c.close(gate[0]);
    defer _ = c.close(gate[1]);
    errdefer {
        terminateGroup(pid);
        _ = reapChild(pid, null);
    }
    if (!establishProcessGroup(pid)) return error.ProcessGroupFailed;
    const token = [_]u8{1};
    while (true) {
        const n = c.write(gate[1], &token, 1);
        if (n < 0 and posix.errno(n) == .INTR) continue;
        if (n != 1) return error.SpawnSetupFailed;
        break;
    }
    return pid;
}
