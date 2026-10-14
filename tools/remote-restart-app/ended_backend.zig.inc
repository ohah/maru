// App-copy-only read projection; job state and seals are never rewritten by the harness.
pub fn remoteEndedFaultState(backend: *RemoteTermBackend) ?[]const u8 {
    const job = backend.host_reconnect_job orelse return null;
    if (!job.valid(backend)) return null;
    if (job.terminal_summary) |summary| {
        std.debug.print("REMOTE_ENDED_TERMINAL host={x:0>32} total={d} published_old={d} published_new={d} frozen={d} ended={d} retry_reserved={d}\n", .{
            job.host_id, summary.total, summary.published_old, summary.published_new,
            summary.frozen_unavailable, summary.ended, summary.retry_reserved,
        });
    }
    return @tagName(std.enums.fromInt(HostReconnectJobState, job.state_raw) orelse return null);
}
