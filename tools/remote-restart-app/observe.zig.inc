// Source-copy-only observer: never writes product state or substitutes a reader.
var remote_restart_session: ?*AppSession = null;
pub fn remoteRestartObserve(self: *AppSession) void {
    if (std.c.getenv("MARU_REMOTE_RESTART_PHASE") == null) return;
    if (self.dock_initialized) remote_restart_session = self;
}
export fn maru_remote_restart_ready() callconv(.c) i32 {
    const self = remote_restart_session orelse return 0;
    const term = pane_ops.activePane(self).activeTerm();
    const channel = term.agent_remote_channel orelse {
        if (term.rt.ended_placeholder) std.debug.print("REMOTE_RESTART_ENDED attach={s} error={s} outcome={s} host_site={s} host_reason={s}\n", .{
            AppSession.attach_fail_site, AppSession.attach_fail_raw, AppSession.attach_fail_outcome,
            AppSession.restore_host_site, AppSession.restore_host_reason,
        });
        return 0;
    };
    if (!channel.isOpen() or self.remote_nonce_matched == 0) return 0;
    std.debug.print("REMOTE_RESTART state={s} notice={s} matched={d} nonce={s} surface={d}\n", .{
        @tagName(term.agent_state), @tagName(term.hook.notice.kind), self.remote_nonce_matched,
        term.agent_remote_nonce[0..term.agent_remote_nonce_len], term.surfaceId(),
    });
    return if (term.agent_state == .idle) 1 else 2;
}
