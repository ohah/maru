// Source-copy-only transport fault and scheduling barrier. No product receipt is fabricated.
var remote_ended_disconnected = false;
var remote_ended_released = false;
var remote_ended_last_state: []const u8 = "";

fn remoteEndedMarkerPath(name: []const u8, buf: []u8) ?[:0]u8 {
    const root = std.c.getenv("MARU_REMOTE_RESTART_OUTPUT") orelse return null;
    return std.fmt.bufPrintZ(buf, "{s}/{s}", .{ std.mem.span(root), name }) catch null;
}
fn remoteEndedMarkerExists(name: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const path = remoteEndedMarkerPath(name, &buf) orelse return false;
    return std.c.access(path.ptr, std.c.F_OK) == 0;
}
fn remoteEndedMarkerWrite(name: []const u8) void {
    var buf: [4096]u8 = undefined;
    const path = remoteEndedMarkerPath(name, &buf) orelse return;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return;
    defer _ = std.c.close(fd);
    _ = std.c.write(fd, "ready\n", 6);
}
export fn maru_remote_ended_disconnect() callconv(.c) i32 {
    if (std.c.getenv("MARU_REMOTE_ENDED_FAULT") == null) return -1;
    if (remote_ended_disconnected) return 1;
    const self = remote_restart_session orelse return -2;
    const backend = if (app_session_mod.app_remote_backend) |*value| value else return -3;
    const pool = if (app_session_mod.app_remote_host_pool) |*value| value else return -4;
    const handle = pane_ops.activePane(self).activeTerm().rt.handle;
    const host_id = backend.runtimeHostId(handle) orelse return -5;
    const runtime_id = backend.runtimeIdFor(handle) orelse return -8;
    const adapter = pool.get(host_id) orelse return -6;
    // The real reader observes EOF and emits the normal reconnect admission.
    if (std.c.shutdown(adapter.slot.logicalClient().fd, std.c.SHUT.RDWR) != 0) return -7;
    remote_ended_disconnected = true;
    std.debug.print("REMOTE_ENDED_DISCONNECTED host={x:0>32} runtime={s}\n", .{ host_id, runtime_id });
    return 1;
}
pub fn remoteEndedBeforeCoordinator(backend: anytype) bool {
    if (std.c.getenv("MARU_REMOTE_ENDED_FAULT") == null or !remote_ended_disconnected) return false;
    const state = @import("../session_host/remote_term_backend.zig").remoteEndedFaultState(backend) orelse return false;
    if (!std.mem.eql(u8, state, remote_ended_last_state)) {
        std.debug.print("REMOTE_ENDED_JOB host={x:0>32} state={s}\n", .{ backend.host_reconnect_job.?.host_id, state });
        remote_ended_last_state = state;
    }
    if (!remote_ended_released and std.mem.eql(u8, state, "replacement_published")) {
        remoteEndedMarkerWrite("candidate-ready");
        if (!remoteEndedMarkerExists("continue")) return true;
        remote_ended_released = true;
    }
    return false;
}
