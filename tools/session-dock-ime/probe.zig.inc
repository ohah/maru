// Read-only witnesses appended to a private source copy; never a distributed ABI/input path.
var dock_ime_observed_session: ?*AppSession = null;
pub fn observeSessionDockIME(self: *AppSession) void {
    if (std.c.getenv("MARU_SESSION_DOCK_IME") != null and self.dock_initialized)
        dock_ime_observed_session = self;
}
fn dockIMEHash(bytes: []const u8) u64 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &digest, .{});
    return std.mem.readInt(u64, digest[0..8], .little);
}
fn dockIMEBaseGeneration(self: *AppSession) u64 {
    const term = pane_ops.activePane(self).activeTerm();
    if (term.surface.remote != null) {
        const backend = if (app_session_mod.app_remote_backend) |*value| value else return std.math.maxInt(u64);
        return backend.screenGenerationFor(term.rt.handle) orelse std.math.maxInt(u64);
    }
    term.surface.lockCore(self.io);
    defer term.surface.unlockCore(self.io);
    return term.surface.core.observerGeneration();
}
export fn maru_session_dock_ime_witness(field: u32) u64 {
    const self = dock_ime_observed_session orelse return 0;
    return switch (field) {
        0 => 1,
        1 => @intFromBool(self.agent_session_archive_search_active),
        2 => @intFromBool(self.agent_session_dock_key_focus),
        3 => @intFromBool(self.inputFocus() == .agent_session_search),
        4 => self.agent_session_archive_search.query.items.len,
        5 => dockIMEHash(self.agent_session_archive_search.query.items),
        6 => self.agent_session_archive_search.preedit.items.len,
        7 => dockIMEHash(self.agent_session_archive_search.preedit.items),
        8 => self.agent_session_archive_filtered_indices.items.len,
        9 => self.total_terminal_input_bytes,
        10 => if (self.app_window.active()) |term| term.id else 0,
        11 => dockIMEBaseGeneration(self),
        else => 0,
    };
}
