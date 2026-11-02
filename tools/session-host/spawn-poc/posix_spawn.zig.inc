// PoC only: creation and PGID assignment belong to Darwin's spawn operation.
// This deliberately exposes spawn's native failure contract, without synthesizing exit 126.
fn pocSpawnGrouped(
    executable: [:0]const u8,
    argv: [*:null]const ?[*:0]const u8,
    environment: ?[*:null]const ?[*:0]const u8,
    directory_fd: ?c.fd_t,
    input_fd: ?c.fd_t,
    mappings: [4]?c.fd_t,
) Error!c.pid_t {
    var attr: c.posix_spawnattr_t = undefined;
    if (c.posix_spawnattr_init(&attr) != 0) return error.SpawnSetupFailed;
    defer _ = c.posix_spawnattr_destroy(&attr);
    if (c.posix_spawnattr_setpgroup(&attr, 0) != 0 or
        c.posix_spawnattr_setflags(&attr, .{ .SETPGROUP = true, .CLOEXEC_DEFAULT = true }) != 0)
        return error.SpawnSetupFailed;
    var actions: c.posix_spawn_file_actions_t = undefined;
    if (c.posix_spawn_file_actions_init(&actions) != 0) return error.SpawnSetupFailed;
    defer _ = c.posix_spawn_file_actions_destroy(&actions);
    if (directory_fd) |fd| if (c.posix_spawn_file_actions_addfchdir_np(&actions, fd) != 0)
        return error.SpawnSetupFailed;
    // The current fork implementation also resets the shared input description's offset.
    if (input_fd) |fd| if (c.lseek(fd, 0, c.SEEK.SET) < 0) return error.SpawnSetupFailed;
    for (mappings, 0..) |source, target| if (source) |fd| {
        if (c.posix_spawn_file_actions_adddup2(&actions, fd, @intCast(target)) != 0)
            return error.SpawnSetupFailed;
    };
    // dup2 sources must not become extra inherited descriptors under CLOEXEC_DEFAULT.
    for (mappings, 0..) |source, index| if (source) |fd| {
        if (fd < 3 or (fd == 3 and mappings[3] != null)) continue;
        var seen = false;
        for (mappings[0..index]) |previous| if (previous == source) { seen = true; };
        if (!seen and c.posix_spawn_file_actions_addclose(&actions, fd) != 0)
            return error.SpawnSetupFailed;
    };
    var pid: c.pid_t = 0;
    const rc = c.posix_spawn(&pid, executable.ptr, &actions, &attr, argv, environment orelse c.environ);
    if (rc != 0) return error.SpawnFailed;
    return pid;
}
