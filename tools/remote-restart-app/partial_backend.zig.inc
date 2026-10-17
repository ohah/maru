// Source-copy-only receive scheduling. The real daemon owns the partial frame and close reason.
var partial_gui_paused = false;
var partial_gui_resync_sent = false;
var partial_gui_released = false;
var partial_gui_observed_job: u64 = 0;
var partial_gui_gone_observed = false;

// Observe only a validated canonical job; never rewrite rows, cursor, seals, or runtime owners.
fn partialGuiObserveReconnectOrder(backend: *RemoteTermBackend) void {
    const job = backend.host_reconnect_job orelse return;
    if (!job.valid(backend)) return;
    const rows = job.runtimeRowsSlice() orelse return;
    if (partial_gui_observed_job != job.job_generation) {
        for (rows, 0..) |row, index| std.debug.print(
            "PARTIAL_GUI_ROW host={x:0>32} job={d} index={d} handle={d} runtime={x:0>32}\n",
            .{ job.host_id, job.job_generation, index, row.identity.runtime_handle, row.identity.runtime_id },
        );
        partial_gui_observed_job = job.job_generation;
        partial_gui_gone_observed = false;
    }
    if (!partial_gui_gone_observed and job.state_raw == @intFromEnum(HostReconnectJobState.candidate_ended)) {
        const index: usize = job.runtime_cursor.next_index;
        if (index >= rows.len) return;
        const prior = if (index == 0) "none" else @tagName(std.enums.fromInt(
            host_reconnect_runtime_ledger.LocalState, rows[index - 1].local_raw,
        ) orelse return);
        std.debug.print("PARTIAL_GUI_GONE host={x:0>32} job={d} index={d} runtime={x:0>32} prior={s}\n", .{
            job.host_id, job.job_generation, index, rows[index].identity.runtime_id, prior,
        });
        partial_gui_gone_observed = true;
    }
}

fn partialGuiMarker(name: []const u8, write: bool) bool {
    const raw = std.c.getenv("MARU_SESSION_HOST_CR6C_ARTIFACT_ROOT") orelse return false;
    var buf: [4096]u8 = undefined;
    const path = std.fmt.bufPrintZ(&buf, "{s}/{s}", .{ std.mem.span(raw), name }) catch return false;
    if (!write) return std.c.access(path.ptr, std.c.F_OK) == 0;
    const fd = std.c.open(path.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return false;
    _ = std.c.close(fd);
    return true;
}

pub fn partialGuiReceivePaused() bool {
    return partial_gui_paused and !partial_gui_released;
}

pub fn partialGuiBeforeCoordinator(backend: *RemoteTermBackend) bool {
    if (std.c.getenv("MARU_PARTIAL_GUI") == null) return false;
    partialGuiObserveReconnectOrder(backend);
    if (partial_gui_released) return false;
    if (!partial_gui_paused) {
        if (!partialGuiMarker("c3c-disconnect-ready", false)) return false;
        const pool = backend.host_pool orelse return false;
        var entries = backend.runtimes.iterator();
        while (entries.next()) |entry| {
            const adapter = pool.get(entry.value_ptr.host_id) orelse continue;
            var size: c_int = 4096;
            if (std.c.setsockopt(adapter.slot.logicalClient().fd, std.c.SOL.SOCKET, std.c.SO.RCVBUF, &size, @sizeOf(c_int)) != 0)
                return false;
        }
        const target_raw = std.c.getenv("MARU_SESSION_HOST_CR6E_C3C_SIBLING_RUNTIME_ID") orelse return false;
        entries = backend.runtimes.iterator();
        while (entries.next()) |entry| {
            const id = entry.value_ptr.runtime.runtimeIdHex();
            if (!std.mem.eql(u8, &id, std.mem.span(target_raw))) continue;
            entry.value_ptr.runtime.resize(200, 120) catch |err| {
                std.debug.print("PARTIAL_GUI_RESIZE_ERROR {s}\n", .{@errorName(err)});
                return false;
            };
        }
        partial_gui_paused = true;
        _ = partialGuiMarker("partial-paused", true);
    }
    if (!partial_gui_resync_sent and partialGuiMarker("partial-resync", false)) {
        const target_raw = std.c.getenv("MARU_SESSION_HOST_CR6E_C3C_SIBLING_RUNTIME_ID") orelse return true;
        var entries = backend.runtimes.iterator();
        while (entries.next()) |entry| {
            const id = entry.value_ptr.runtime.runtimeIdHex();
            if (!std.mem.eql(u8, &id, std.mem.span(target_raw))) continue;
            entry.value_ptr.runtime.requestResync() catch |err| {
                std.debug.print("PARTIAL_GUI_RESYNC_ERROR {s}\n", .{@errorName(err)});
                _ = partialGuiMarker("partial-resync-error", true);
                return true;
            };
            partial_gui_resync_sent = true;
            _ = partialGuiMarker("partial-resync-sent", true);
            break;
        }
    }
    if (partialGuiMarker("partial-release", false)) {
        partial_gui_released = true;
        return false;
    }
    return true;
}
