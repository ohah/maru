// App-copy-only read projection; job state and seals are never rewritten by the harness.
pub fn remoteEndedFaultState(backend: *RemoteTermBackend) ?[]const u8 {
    const job = backend.host_reconnect_job orelse return null;
    if (!job.valid(backend)) return null;
    return @tagName(std.enums.fromInt(HostReconnectJobState, job.state_raw) orelse return null);
}
