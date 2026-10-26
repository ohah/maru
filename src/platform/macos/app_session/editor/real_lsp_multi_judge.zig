//! Opt-in multi-file SDK judge. All edits, navigation and completion enter the
//! product controllers. A peer edit must refresh an untouched main document.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../app_session.zig");
const ops = @import("mod.zig");
const lsp = @import("lsp.zig");
const completion = @import("completion.zig");
const definition = @import("definition.zig");
const pane = @import("../pane.zig");
const single = @import("real_lsp_judge.zig");
extern "c" fn usleep(usec: c_uint) c_int;

pub const Case = struct {
    scenario: []const u8,
    language: []const u8,
    nonce: []const u8,
    root: []const u8,
    path: []const u8,
    peer_path: []const u8,
    report_path: []const u8,
    good: []const u8,
    peer_good: []const u8,
    peer_bad: []const u8,
    support: []const struct { path: []const u8, good: []const u8 },
    definition_offset: usize,
    definition_line: usize,
    partial: []const u8,
    completion_name: []const u8,
    completion_start: usize,
    completion_offset: usize,
    expected_usage: []const u8,
    import_marker: []const u8,
    timeout_ms: u64 = 90_000,
};

const Report = struct {
    stage: []const u8 = "ready",
    failure: ?[]const u8 = null,
    definition_navigated: bool = false,
    navigation_returned: bool = false,
    dependency_raised: bool = false,
    dependency_cleared: bool = false,
    completion_applied: bool = false,
    completion_undone: bool = false,
    main_unchanged_during_dependency: bool = false,
    peer_unchanged_by_completion: bool = false,
    definition_attempts: usize = 0,
    definition_notices_acknowledged: usize = 0,
    completion_attempts: usize = 0,
    target_path: []const u8 = "",
    target_line: usize = 0,
    main_initial_version: u64 = 0,
    main_dependency_version: u64 = 0,
    peer_bad_version: u64 = 0,
    peer_fixed_version: u64 = 0,
    after_dependency: []const u8 = "",
    before_completion: []const u8 = "",
    after_completion: []const u8 = "",
    after_undo: []const u8 = "",
    peer_after_completion: []const u8 = "",
    selected_label: []const u8 = "",
    selected_kind: u8 = 0,
    additional_before_enter: usize = 0,
    accepted_after_resolve: u64 = 0,
    undo_before: usize = 0,
    undo_after: usize = 0,
    undo_after_undo: usize = 0,
};

const Paint = *const fn (*host.AppSession, *host.Term) anyerror!void;
fn content(t: *host.Term) []const u8 {
    return t.rt.editorDocument().opened.?.file.content;
}
fn version(t: *host.Term) u64 {
    return t.rt.editorDocument().notifications.lsp_version;
}
fn pump(s: *host.AppSession) void {
    lsp.pump(s);
    _ = completion.acceptPendingOnTimeout(s);
    _ = usleep(5_000);
}
fn change(s: *host.AppSession, t: *host.Term, text: []const u8) !void {
    var edits = [_]maru.session.editor.delta.Change{.{ .start = 0, .end = content(t).len, .text = text }};
    if (!ops.applyEditAsOneWithUndo(s, t, &edits)) return error.EditRejected;
}
fn errors(t: *host.Term) usize {
    var n: usize = 0;
    for (t.rt.editor_diagnostics.lsp.items) |d| if (d.severity == .@"error") {
        n += 1;
    };
    return n;
}
fn dependencyError(t: *host.Term, at: usize) bool {
    for (t.rt.editor_diagnostics.lsp.items) |d| {
        if (d.severity == .@"error" and d.start <= at and d.end > at) return true;
    }
    return false;
}
fn sent(s: *host.AppSession, t: *host.Term, timeout: u64) !void {
    const deadline = s.awakeMs() + timeout;
    while (s.awakeMs() < deadline) {
        pump(s);
        if (lsp.readyClientFor(s, t)) |client| {
            if (client.findDoc(t)) |d| if (d.sent_version == version(t)) return;
        }
    }
    return error.DocumentNotSynchronized;
}
fn checkFile(s: *host.AppSession, c: Case, path: []const u8, expected: []const u8) !void {
    if (!std.mem.eql(u8, std.fs.path.dirname(path) orelse "", c.root) or std.mem.eql(u8, path, c.path)) return error.UnownedPeer;
    const bytes = try std.Io.Dir.cwd().readFileAlloc(s.io, path, s.allocator, .limited(1 << 20));
    defer s.allocator.free(bytes);
    if (!std.mem.eql(u8, bytes, expected)) return error.PeerFixtureChanged;
}

fn steps(s: *host.AppSession, main: *host.Term, c: Case, r: *Report, paint: Paint) !void {
    if (!std.mem.eql(u8, c.scenario, "multi-file")) return error.WrongScenario;
    try checkFile(s, c, c.peer_path, c.peer_good);
    for (c.support) |file| try checkFile(s, c, file.path, file.good);
    r.stage = "baseline_diagnostics";
    try sent(s, main, c.timeout_ms);
    var deadline = s.awakeMs() + c.timeout_ms;
    while ((s.editor_lsp.received_diagnostics == 0 or errors(main) != 0) and s.awakeMs() < deadline) pump(s);
    if (s.editor_lsp.received_diagnostics == 0 or errors(main) != 0) return error.BaselineAnalysisNotReady;
    r.main_initial_version = version(main);

    r.stage = "cross_file_definition";
    main.rt.editor_selection = .{ .anchor_start = c.definition_offset, .anchor_end = c.definition_offset, .focus = c.definition_offset };
    const navigated = s.editor_definition.navigated;
    var seen = s.editor_definition.notified_none;
    var last_request: u64 = 0;
    deadline = s.awakeMs() + c.timeout_ms;
    while (s.editor_definition.navigated == navigated and s.awakeMs() < deadline) {
        if (try single.acknowledgeDefinitionMiss(s, &seen)) r.definition_notices_acknowledged += 1;
        if (!s.editor_definition.waiting and s.awakeMs() -| last_request >= 100) {
            last_request = s.awakeMs();
            r.definition_attempts += 1;
            if (!definition.gotoDefinitionAtCaret(s)) return error.DefinitionNotRequested;
        }
        pump(s);
    }
    if (s.editor_definition.navigated != navigated + 1) return error.DefinitionNotNavigated;
    const peer = pane.activePane(s).activeTerm();
    if (peer == main or !std.mem.eql(u8, peer.rt.editorDocument().path orelse "", c.peer_path)) return error.DefinitionWrongDocument;
    r.target_path = try s.allocator.dupe(u8, peer.rt.editorDocument().path.?);
    r.target_line = peer.rt.editorDocument().opened.?.file.lines.lineAt(peer.rt.editor_selection.?.focus);
    if (r.target_line != c.definition_line) return error.DefinitionWrongLine;
    r.definition_navigated = true;
    try sent(s, peer, c.timeout_ms);
    if (!ops.navigateBack(s) or pane.activePane(s).activeTerm() != main or main.rt.editor_selection.?.focus != c.definition_offset) return error.NavigationDidNotReturn;
    r.navigation_returned = true;

    // Keep main unchanged: pulling it by editing/saving it would mask a broken
    // dependency refresh. Only the already-open peer receives changes/saves.
    r.stage = "dependency_raise";
    try ops.navigateTo(s, .{ .path = c.peer_path });
    try change(s, peer, c.peer_bad);
    r.peer_bad_version = version(peer);
    try ops.saveDocument(s, peer);
    if (!ops.navigateBack(s) or pane.activePane(s).activeTerm() != main) return error.NavigationDidNotReturn;
    deadline = s.awakeMs() + c.timeout_ms;
    while (!dependencyError(main, c.definition_offset) and s.awakeMs() < deadline) pump(s);
    if (!dependencyError(main, c.definition_offset)) return error.DependentDiagnosticMissing;
    r.dependency_raised = true;

    r.stage = "dependency_clear";
    try ops.navigateTo(s, .{ .path = c.peer_path });
    try change(s, peer, c.peer_good);
    r.peer_fixed_version = version(peer);
    try ops.saveDocument(s, peer);
    if (!ops.navigateBack(s) or pane.activePane(s).activeTerm() != main) return error.NavigationDidNotReturn;
    deadline = s.awakeMs() + c.timeout_ms;
    while (errors(main) != 0 and s.awakeMs() < deadline) pump(s);
    if (errors(main) != 0) return error.DependentDiagnosticNotCleared;
    r.dependency_cleared = true;
    r.main_dependency_version = version(main);
    r.after_dependency = try s.allocator.dupe(u8, content(main));
    if (version(main) != r.main_initial_version or !std.mem.eql(u8, content(main), c.good)) return error.MainChangedDuringDependency;
    r.main_unchanged_during_dependency = true;

    r.stage = "autoimport";
    try change(s, main, c.partial);
    main.rt.editor_selection = .{ .anchor_start = c.completion_offset, .anchor_end = c.completion_offset, .focus = c.completion_offset };
    r.before_completion = c.partial;
    completion.hide(s);
    try paint(s, main);
    const received = s.editor_lsp.received_completions;
    var last_completion: u64 = 0;
    var found = false;
    deadline = s.awakeMs() + c.timeout_ms;
    while (s.awakeMs() < deadline) {
        if (!s.editor_completion.waiting and s.awakeMs() -| last_completion >= 100) {
            completion.hide(s);
            last_completion = s.awakeMs();
            r.completion_attempts += 1;
            if (!completion.triggerManual(s)) return error.CompletionNotRequested;
        }
        pump(s);
        if (s.editor_completion.waiting or s.editor_lsp.received_completions <= received or s.editor_completion.words_only) continue;
        try paint(s, main);
        if (!completion.refresh(s) or !s.chrome_host.suggest_box.open) continue;
        for (s.editor_completion.order.items, 0..) |index, row| {
            const item = s.editor_completion.items.items[index];
            if (item.kind == maru.session.editor.lsp.completion.word_kind or !std.mem.eql(u8, item.filter, c.completion_name)) continue;
            r.selected_label = try s.allocator.dupe(u8, item.label);
            r.selected_kind = item.kind;
            r.additional_before_enter = item.additional.items.len;
            s.chrome_host.suggest_box.selected = row;
            found = true;
            break;
        }
        if (found) break;
    }
    if (!found) return error.AutoImportCompletionMissing;
    r.undo_before = main.rt.editorDocument().history.undo_len;
    const resolved = s.editor_completion.accepted_after_resolve;
    if (!completion.handleKey(s, .enter, .{})) return error.CompletionEnterNotHandled;
    deadline = s.awakeMs() + c.timeout_ms;
    while (s.editor_completion.active and s.awakeMs() < deadline) pump(s);
    r.accepted_after_resolve = s.editor_completion.accepted_after_resolve - resolved;
    r.after_completion = try s.allocator.dupe(u8, content(main));
    if (std.mem.indexOf(u8, content(main), c.import_marker) == null or std.mem.indexOf(u8, content(main), c.expected_usage) == null) return error.AutoImportNotApplied;
    r.undo_after = main.rt.editorDocument().history.undo_len;
    if (r.undo_after != r.undo_before + 1) return error.CompletionNotOneUndo;
    try sent(s, main, c.timeout_ms);
    r.completion_applied = true;
    if (!ops.undoEdit(s, main) or !std.mem.eql(u8, content(main), c.partial)) return error.CompletionUndoWrongText;
    r.undo_after_undo = main.rt.editorDocument().history.undo_len;
    r.after_undo = try s.allocator.dupe(u8, content(main));
    r.peer_after_completion = try s.allocator.dupe(u8, content(peer));
    if (!std.mem.eql(u8, content(peer), c.peer_good)) return error.CompletionChangedPeer;
    r.peer_unchanged_by_completion = true;
    try sent(s, main, c.timeout_ms);
    r.completion_undone = true;
    r.stage = "complete";
}

pub fn run(s: *host.AppSession, main: *host.Term, c: Case, paint: Paint) !void {
    var r: Report = .{};
    defer {
        inline for (.{ "target_path", "after_dependency", "after_completion", "after_undo", "peer_after_completion", "selected_label" }) |name| {
            const value = @field(r, name);
            if (value.len > 0) s.allocator.free(value);
        }
    }
    steps(s, main, c, &r, paint) catch |err| {
        r.failure = @errorName(err);
        try write(s, c, r);
        return err;
    };
    try write(s, c, r);
}

fn write(s: *host.AppSession, c: Case, r: Report) !void {
    const files = .{
        .{ "real_lsp_multi_judge.zig", @embedFile("real_lsp_multi_judge.zig") },
        .{ "real_lsp_judge.zig", @embedFile("real_lsp_judge.zig") },
        .{ "mod.zig", @embedFile("mod.zig") },
        .{ "lsp.zig", @embedFile("lsp.zig") },
        .{ "completion.zig", @embedFile("completion.zig") },
        .{ "hover.zig", @embedFile("hover.zig") },
        .{ "definition.zig", @embedFile("definition.zig") },
        .{ "semantic.zig", @embedFile("semantic.zig") },
    };
    var fingerprints: [files.len]struct { name: []const u8, sha256: [64]u8 } = undefined;
    inline for (files, 0..) |file, i| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file[1], &digest, .{});
        fingerprints[i] = .{ .name = file[0], .sha256 = std.fmt.bytesToHex(digest, .lower) };
    }
    const bytes = try std.json.Stringify.valueAlloc(s.allocator, .{
        .schema = "maru.lsp-real.product.v1",
        .scenario = "multi-file",
        .language = c.language,
        .build_mode = @tagName(@import("builtin").mode),
        .source_fingerprints = fingerprints,
        .stage = r.stage,
        .failure = r.failure,
        .result = r,
    }, .{ .whitespace = .indent_2 });
    defer s.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = c.report_path, .data = bytes });
}
