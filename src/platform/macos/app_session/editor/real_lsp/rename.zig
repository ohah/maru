//! Real SDK rename through F2/Enter and the existing WorkspaceEdit controller.
//! Waiting for an observed response without pumping lets the judge change local
//! state before delivery, without fabricating or modifying server messages.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const ops = @import("../mod.zig");
const lsp = @import("../lsp.zig");
const pane = @import("../../pane.zig");
const definition = @import("../definition.zig");
const single = @import("../real_lsp_judge.zig");
extern "c" fn usleep(usec: c_uint) c_int;

const File = struct { path: []const u8, good: []const u8, renamed: []const u8 = "" };
pub const Case = struct {
    scenario: []const u8,
    language: []const u8,
    nonce: []const u8,
    root: []const u8,
    path: []const u8,
    good: []const u8,
    report_path: []const u8,
    files: []File,
    metadata: File,
    rename_offset: usize,
    new_name: []const u8,
    local: []const u8,
    timeout_ms: u64 = 90_000,
};
const Sample = struct {
    phase: []const u8,
    path: []const u8,
    disk: []u8,
    buffer: ?[]u8,
    version: ?u64,
    undo_len: ?usize,
    dirty: ?bool,
};
const Report = struct {
    stage: []const u8 = "ready",
    failure: ?[]const u8 = null,
    request_ids: [3]u32 = .{ 0, 0, 0 },
    samples: []Sample = &.{},
    applied_files: u64 = 0,
    saved_files: u64 = 0,
    record_files: usize = 0,
    undone_files: u64 = 0,
    stale_refusals: u64 = 0,
    rejected_refusals: u64 = 0,
    baseline_definition: bool = false,
    stale_response_observed: bool = false,
    rejected_response_observed: bool = false,
    closed_missing_at_apply: bool = false,
};
const Paint = *const fn (*host.AppSession, *host.Term) anyerror!void;

fn find(s: *host.AppSession, path: []const u8) ?*host.Term {
    for (s.tabs.items) |tab| for (tab.panes.items) |p| for (p.terms.items) |t| {
        if (t.kind == .editor and std.mem.eql(u8, t.rt.editorDocument().path orelse "", path)) return t;
    };
    return null;
}
fn body(t: *host.Term) []const u8 {
    return t.rt.editorDocument().opened.?.file.content;
}
fn pump(s: *host.AppSession) void {
    lsp.pump(s);
    _ = usleep(5_000);
}
fn sent(s: *host.AppSession, t: *host.Term, timeout: u64) !void {
    const deadline = s.awakeMs() + timeout;
    while (s.awakeMs() < deadline) {
        pump(s);
        if (lsp.readyClientFor(s, t)) |client| {
            if (client.findDoc(t)) |d| if (d.sent_version == t.rt.editorDocument().notifications.lsp_version) return;
        }
    }
    return error.DocumentNotSynchronized;
}
fn change(s: *host.AppSession, t: *host.Term, text: []const u8) !void {
    var edits = [_]maru.session.editor.delta.Change{.{ .start = 0, .end = body(t).len, .text = text }};
    if (!ops.applyEditAsOneWithUndo(s, t, &edits)) return error.EditRejected;
}
fn observe(s: *host.AppSession, c: Case, phase: []const u8, r: *Report, slots: []Sample) !void {
    for (c.files) |f| {
        const disk = try std.Io.Dir.cwd().readFileAlloc(s.io, f.path, s.allocator, .limited(1 << 20));
        errdefer s.allocator.free(disk);
        const t = find(s, f.path);
        const buffer = if (t) |term| try s.allocator.dupe(u8, body(term)) else null;
        const len = r.samples.len;
        if (len >= slots.len) return error.SampleCapacity;
        slots[len] = .{ .phase = phase, .path = f.path, .disk = disk, .buffer = buffer, .version = if (t) |term| term.rt.editorDocument().notifications.lsp_version else null, .undo_len = if (t) |term| term.rt.editorDocument().history.undo_len else null, .dirty = if (t) |term| ops.isDirty(term) else null };
        r.samples = slots[0 .. len + 1];
    }
}
fn request(s: *host.AppSession, main: *host.Term, c: Case, paint: Paint) !u32 {
    if (pane.activePane(s).activeTerm() != main) return error.WrongActiveDocument;
    main.rt.editor_selection = .{ .anchor_start = c.rename_offset, .anchor_end = c.rename_offset, .focus = c.rename_offset };
    _ = try s.handleKeyEvent(.{ .key = .{ .function = 2 } });
    if (s.rename == null or s.rename.? != .symbol) return error.RenameDidNotOpen;
    try paint(s, main);
    while (s.rename_input.text.items.len > 0) _ = try s.handleKeyEvent(.{ .key = .backspace });
    for (c.new_name) |ch| _ = try s.handleKeyEvent(.{ .key = .{ .char = ch } });
    _ = try s.handleKeyEvent(.{ .key = .enter });
    if (!s.editor_rename.waiting or s.rename != null) return error.RenameDidNotSend;
    return maru.session.editor.lsp.rpc.rename_id_base + s.editor_rename.waiting_seq;
}
fn settled(s: *host.AppSession, timeout: u64) !void {
    const deadline = s.awakeMs() + timeout;
    while (s.editor_rename.waiting and s.awakeMs() < deadline) pump(s);
    if (s.editor_rename.waiting) return error.RenameTimedOut;
}
fn dismiss(s: *host.AppSession) !void {
    // Only called after this judge has verified its own rename outcome.
    if (s.chrome_host.notice.open) _ = try s.handleKeyEvent(.{ .key = .escape });
}
fn responseObserved(s: *host.AppSession, c: Case, id: u32) !void {
    const path = try std.fs.path.join(s.allocator, &.{ c.root, "wire.ndjson" });
    defer s.allocator.free(path);
    const deadline = s.awakeMs() + c.timeout_ms;
    while (s.awakeMs() < deadline) {
        const wire = try std.Io.Dir.cwd().readFileAlloc(s.io, path, s.allocator, .limited(16 << 20));
        defer s.allocator.free(wire);
        var lines = std.mem.splitScalar(u8, wire, '\n');
        while (lines.next()) |line| {
            var parsed = std.json.parseFromSlice(std.json.Value, s.allocator, line, .{}) catch continue;
            defer parsed.deinit();
            const v = parsed.value;
            if (v != .object) continue;
            const dir = v.object.get("direction") orelse continue;
            const m = v.object.get("message") orelse continue;
            if (dir != .string or !std.mem.eql(u8, dir.string, "server") or m != .object or m.object.contains("method")) continue;
            const mid = m.object.get("id") orelse continue;
            if (mid != .integer or mid.integer != id) continue;
            const result = m.object.get("result") orelse return error.RealRenameServerError;
            if (result != .object or m.object.contains("error")) return error.RealRenameServerError;
            return;
        }
        // Deliberately no lsp.pump: the actual response waits for local invalidation.
        _ = usleep(5_000);
    }
    return error.RealRenameResponseMissing;
}
fn readyForRename(s: *host.AppSession, main: *host.Term, peer: *host.Term, c: Case) !void {
    main.rt.editor_selection = .{ .anchor_start = c.rename_offset, .anchor_end = c.rename_offset, .focus = c.rename_offset };
    // A received empty diagnostic can precede SDK indexing. Prove this exact
    // symbol resolves before attempting a mutating request; retry only the read.
    const navigated = s.editor_definition.navigated;
    var seen = s.editor_definition.notified_none;
    var last_request: u64 = 0;
    const ready_deadline = s.awakeMs() + c.timeout_ms;
    while (s.editor_definition.navigated == navigated and s.awakeMs() < ready_deadline) {
        _ = try single.acknowledgeDefinitionMiss(s, &seen);
        if (!s.editor_definition.waiting and s.awakeMs() -| last_request >= 100) {
            last_request = s.awakeMs();
            if (!definition.gotoDefinitionAtCaret(s)) return error.DefinitionNotRequested;
        }
        pump(s);
    }
    if (s.editor_definition.navigated == navigated or pane.activePane(s).activeTerm() != peer) return error.RenameAnalysisNotReady;
    if (!ops.navigateBack(s) or pane.activePane(s).activeTerm() != main) return error.RenameAnalysisDidNotReturn;
}
fn steps(s: *host.AppSession, main: *host.Term, c: Case, r: *Report, slots: []Sample, paint: Paint) !void {
    if (!std.mem.eql(u8, c.scenario, "rename") or c.files.len != 3 or !std.mem.eql(u8, c.path, c.files[0].path)) return error.InvalidRenameCase;
    for (c.files, 0..) |f, i| {
        if (!std.mem.eql(u8, std.fs.path.dirname(f.path) orelse "", c.root)) return error.UnownedRenameFile;
        for (c.files[0..i]) |previous| if (std.mem.eql(u8, previous.path, f.path)) return error.DuplicateRenameFile;
        const bytes = try std.Io.Dir.cwd().readFileAlloc(s.io, f.path, s.allocator, .limited(1 << 20));
        defer s.allocator.free(bytes);
        if (!std.mem.eql(u8, bytes, f.good)) return error.RenameFixtureChanged;
    }
    r.stage = "baseline";
    try sent(s, main, c.timeout_ms);
    const deadline = s.awakeMs() + c.timeout_ms;
    while ((s.editor_lsp.received_diagnostics == 0 or !lsp.renameSupportedFor(s, main)) and s.awakeMs() < deadline) pump(s);
    if (!lsp.renameSupportedFor(s, main)) return error.RenameUnsupported;
    // A newly opened fixture has no caret until user navigation seeds it.
    main.rt.editor_selection = .{ .anchor_start = c.rename_offset, .anchor_end = c.rename_offset, .focus = c.rename_offset };
    try ops.navigateTo(s, .{ .path = c.files[1].path });
    const peer = pane.activePane(s).activeTerm();
    try sent(s, peer, c.timeout_ms);
    if (!ops.navigateBack(s) or pane.activePane(s).activeTerm() != main or find(s, c.files[2].path) != null) return error.InvalidOpenClosedFixture;
    try readyForRename(s, main, peer, c);
    r.baseline_definition = true;
    try observe(s, c, "before", r, slots);
    r.stage = "rename_apply";
    const applied_before = s.editor_workspace_edit.applied_files;
    const saved_before = s.editor_workspace_edit.saved_files;
    const done_before = s.editor_rename.notified_done;
    r.request_ids[0] = try request(s, main, c, paint);
    try settled(s, c.timeout_ms);
    if (s.editor_rename.notified_done != done_before + 1) return error.RenameNotApplied;
    r.applied_files = s.editor_workspace_edit.applied_files - applied_before;
    r.saved_files = s.editor_workspace_edit.saved_files - saved_before;
    r.record_files = if (s.editor_workspace_edit.last) |record| record.files.len else 0;
    if (r.applied_files != 3 or r.saved_files != 3 or r.record_files != 3) return error.RenameFileAccounting;
    try sent(s, main, c.timeout_ms);
    try sent(s, peer, c.timeout_ms);
    try observe(s, c, "applied", r, slots);
    try dismiss(s);
    r.stage = "rename_undo";
    const undone_before = s.editor_workspace_edit.undone_files;
    s.dispatchAppAction(.undo_workspace_edit);
    r.undone_files = s.editor_workspace_edit.undone_files - undone_before;
    if (r.undone_files != 3) return error.RenameUndoMissing;
    const applied_after_undo = s.editor_workspace_edit.applied_files;
    try observe(s, c, "undone", r, slots);
    try dismiss(s);
    try sent(s, main, c.timeout_ms);
    try sent(s, peer, c.timeout_ms);
    try readyForRename(s, main, peer, c);
    r.stage = "stale_response";
    const stale_before = s.editor_workspace_edit.refused_stale;
    r.request_ids[1] = try request(s, main, c, paint);
    try responseObserved(s, c, r.request_ids[1]);
    r.stale_response_observed = true;
    try change(s, main, c.local);
    try settled(s, c.timeout_ms);
    r.stale_refusals = s.editor_workspace_edit.refused_stale - stale_before;
    if (r.stale_refusals != 1 or s.editor_workspace_edit.applied_files != applied_after_undo) return error.StaleResponseApplied;
    try observe(s, c, "stale", r, slots);
    try dismiss(s);
    try change(s, main, c.good);
    try ops.saveDocument(s, main);
    try sent(s, main, c.timeout_ms);
    try readyForRename(s, main, peer, c);
    r.stage = "missing_closed_file";
    const rejected_before = s.editor_workspace_edit.refused_rejected;
    r.request_ids[2] = try request(s, main, c, paint);
    try responseObserved(s, c, r.request_ids[2]);
    r.rejected_response_observed = true;
    try std.Io.Dir.cwd().deleteFile(s.io, c.files[2].path);
    // Restore even if the product rejects unexpectedly; only this nonce-owned
    // fixture is removed, after the actual server returned its full edit.
    defer std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = c.files[2].path, .data = c.files[2].good }) catch {};
    r.closed_missing_at_apply = true;
    try settled(s, c.timeout_ms);
    r.rejected_refusals = s.editor_workspace_edit.refused_rejected - rejected_before;
    if (r.rejected_refusals != 1 or s.editor_workspace_edit.applied_files != applied_after_undo) return error.RejectedResponseApplied;
    try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = c.files[2].path, .data = c.files[2].good });
    try observe(s, c, "rejected", r, slots);
    r.stage = "complete";
}
pub fn run(s: *host.AppSession, main: *host.Term, c: Case, paint: Paint) !void {
    const slots = try s.allocator.alloc(Sample, 15);
    defer s.allocator.free(slots);
    var r: Report = .{};
    defer for (r.samples) |sample| {
        s.allocator.free(sample.disk);
        if (sample.buffer) |buffer| s.allocator.free(buffer);
    };
    steps(s, main, c, &r, slots, paint) catch |err| {
        r.failure = @errorName(err);
        try write(s, c, r);
        return err;
    };
    try write(s, c, r);
}
fn write(s: *host.AppSession, c: Case, r: Report) !void {
    const files = .{
        .{ "rename_judge.zig", @embedFile("rename.zig") },
        .{ "real_lsp_judge.zig", @embedFile("../real_lsp_judge.zig") },
        .{ "mod.zig", @embedFile("../mod.zig") },
        .{ "lsp.zig", @embedFile("../lsp.zig") },
        .{ "completion.zig", @embedFile("../completion.zig") },
        .{ "hover.zig", @embedFile("../hover.zig") },
        .{ "definition.zig", @embedFile("../definition.zig") },
        .{ "semantic.zig", @embedFile("../semantic.zig") },
        .{ "rename.zig", @embedFile("../rename.zig") },
        .{ "workspace_edit.zig", @embedFile("../workspace_edit.zig") },
    };
    var fingerprints: [files.len]struct { name: []const u8, sha256: [64]u8 } = undefined;
    inline for (files, 0..) |file, i| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file[1], &digest, .{});
        fingerprints[i] = .{ .name = file[0], .sha256 = std.fmt.bytesToHex(digest, .lower) };
    }
    const bytes = try std.json.Stringify.valueAlloc(s.allocator, .{ .schema = "maru.lsp-real.product.v1", .scenario = "rename", .language = c.language, .build_mode = @tagName(@import("builtin").mode), .source_fingerprints = fingerprints, .stage = r.stage, .failure = r.failure, .result = r }, .{ .whitespace = .indent_2 });
    defer s.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = c.report_path, .data = bytes });
}
