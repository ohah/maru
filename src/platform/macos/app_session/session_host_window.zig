//! CR5d-2 AppSession coordinator for the backend-owned two-Window transaction.

const std = @import("std");
const app_session_mod = @import("../app_session.zig");
const term_ops = @import("term.zig");
const workspace_ops = @import("workspace.zig");

const AppSession = app_session_mod.AppSession;
const transaction_mod = app_session_mod.session_host.host_reconnect_window_transaction;
const backend_mod = app_session_mod.session_host.remote_term_backend;
const max_bindings = transaction_mod.max_bindings;

const TermLocation = struct {
    session: *AppSession,
    tab_index: usize,
    pane: *app_session_mod.Pane,
    term_index: usize,
};

fn appendSessionDrafts(
    session: *AppSession,
    out: *[max_bindings]backend_mod.WindowBindingDraft,
    count: *usize,
) !void {
    for (session.tabs.items) |tab| for (tab.panes.items) |pane| for (pane.terms.items) |term| {
        if (!term.rt.live_initialized or term.surface.remote == null) continue;
        if (term.rt.handle == 0 or term.surface.id == 0 or count.* == out.len)
            return error.InvalidWindowBinding;
        out[count.*] = .{
            .window_addr = @intFromPtr(session),
            .app_session_generation = session.session_host_window_generation,
            .graph_generation = session.session_host_window_graph_generation,
            .runtime_handle = term.rt.handle,
            .surface_id = term.surface.id,
        };
        count.* += 1;
    };
}

fn collectDrafts(
    first: *AppSession,
    second: *AppSession,
    out: *[max_bindings]backend_mod.WindowBindingDraft,
) ![]const backend_mod.WindowBindingDraft {
    if (first == second) return error.InvalidWindowBinding;
    var count: usize = 0;
    try appendSessionDrafts(first, out, &count);
    try appendSessionDrafts(second, out, &count);
    if (count < 2) return error.InvalidWindowBinding;
    // max 4,096 rows; insertion sort is acceptable for the Window projection and avoids a second
    // allocation before authority prepare. Typical Window sets are single digits.
    var index: usize = 1;
    while (index < count) : (index += 1) {
        const value = out[index];
        var cursor = index;
        while (cursor != 0 and out[cursor - 1].runtime_handle > value.runtime_handle) : (cursor -= 1)
            out[cursor] = out[cursor - 1];
        out[cursor] = value;
    }
    for (out[1..count], 1..) |draft, current| if (out[current - 1].runtime_handle == draft.runtime_handle)
        return error.InvalidWindowBinding;
    return out[0..count];
}

fn locateSurface(first: *AppSession, second: *AppSession, surface_id: u64) ?TermLocation {
    for ([_]*AppSession{ first, second }) |session| {
        for (session.tabs.items, 0..) |tab, tab_index| for (tab.panes.items) |pane| for (pane.terms.items, 0..) |term, term_index| {
            if (term.surface.id == surface_id) return .{
                .session = session,
                .tab_index = tab_index,
                .pane = pane,
                .term_index = term_index,
            };
        };
    }
    return null;
}

fn revokePreparedOrFatal(
    backend: *backend_mod.RemoteTermBackend,
    transaction: *transaction_mod.Transaction,
) void {
    backend.revokeStaleHostReconnectWindowTransaction(transaction) catch
        app_session_mod.session_host.pending_term_close_graph.fatalProofLoss();
}

pub fn prepareClose(
    first: *AppSession,
    second: *AppSession,
    target_surface_id: u64,
    expires_at_ns: u64,
    now_ns: u64,
) !*transaction_mod.Transaction {
    const backend = if (app_session_mod.app_remote_backend) |*value| value else return error.SessionHostUnavailable;
    return prepareCloseWithBackend(first, second, target_surface_id, expires_at_ns, now_ns, backend);
}

pub fn prepareCloseWithBackend(
    first: *AppSession,
    second: *AppSession,
    target_surface_id: u64,
    expires_at_ns: u64,
    now_ns: u64,
    backend: *backend_mod.RemoteTermBackend,
) !*transaction_mod.Transaction {
    const location = locateSurface(first, second, target_surface_id) orelse
        return error.InvalidWindowBinding;
    const target = location.pane.terms.items[location.term_index];
    if (!target.rt.live_initialized or target.surface.remote == null) return error.InvalidWindowBinding;
    var storage: [max_bindings]backend_mod.WindowBindingDraft = undefined;
    const drafts = try collectDrafts(first, second, &storage);
    const prepared = try backend.prepareHostReconnectWindowTransaction(drafts, .{
        .kind_raw = @intFromEnum(transaction_mod.ActionKind.close),
        .target_window_addr = @intFromPtr(location.session),
        .target_runtime_handle = target.rt.handle,
        .target_surface_id = target_surface_id,
        .action_generation = 0,
        .expires_at_ns = expires_at_ns,
    }, now_ns);
    return prepared;
}

pub fn commitClose(
    first: *AppSession,
    second: *AppSession,
    transaction: *transaction_mod.Transaction,
    now_ns: u64,
) !void {
    const backend = if (app_session_mod.app_remote_backend) |*value| value else return error.SessionHostUnavailable;
    return commitCloseWithBackend(first, second, transaction, now_ns, backend);
}

pub fn commitCloseWithBackend(
    first: *AppSession,
    second: *AppSession,
    transaction: *transaction_mod.Transaction,
    now_ns: u64,
    backend: *backend_mod.RemoteTermBackend,
) !void {
    if (transaction.lifecycle_raw != @intFromEnum(transaction_mod.Lifecycle.prepared))
        return error.InvalidWindowBinding;
    const location = locateSurface(first, second, transaction.action.target_surface_id) orelse {
        revokePreparedOrFatal(backend, transaction);
        return error.InvalidWindowBinding;
    };
    const target = location.pane.terms.items[location.term_index];
    if (@intFromPtr(location.session) != transaction.action.target_window_addr or
        target.rt.handle != transaction.action.target_runtime_handle or target.surface.remote == null)
    {
        revokePreparedOrFatal(backend, transaction);
        return error.InvalidWindowBinding;
    }
    var storage: [max_bindings]backend_mod.WindowBindingDraft = undefined;
    const drafts = collectDrafts(first, second, &storage) catch |err| {
        revokePreparedOrFatal(backend, transaction);
        return err;
    };
    backend.commitHostReconnectWindowClose(transaction, drafts, now_ns) catch |err| {
        // The contract consumes an exact-expiry transaction before returning Expired. Every other
        // rejection is pre-commit and must retire the still-prepared gesture exactly once.
        if (err != error.Expired) revokePreparedOrFatal(backend, transaction);
        return err;
    };
    workspace_ops.advanceSessionHostWindowGraph(location.session);
    term_ops.abandonTermAt(location.session, location.tab_index, location.pane, location.term_index, backend);
}
