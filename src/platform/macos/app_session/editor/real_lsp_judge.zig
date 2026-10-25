//! Opt-in real-server judge. This invokes Maru's actual AppSession controllers;
//! it neither implements an LSP client nor supplies fabricated server results.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../app_session.zig");
const ops = @import("mod.zig");
const lsp = @import("lsp.zig");
const completion = @import("completion.zig");
const hover = @import("hover.zig");
const definition = @import("definition.zig");
const pane = @import("../pane.zig");
const save = @import("save/dispatch.zig");
extern "c" fn usleep(usec: c_uint) c_int;

pub const Case = struct {
    nonce: []const u8,
    root: []const u8,
    path: []const u8,
    report_path: []const u8,
    good: []const u8,
    symbol: []const u8,
    completion_name: []const u8,
    hover_offset: usize,
    definition_line: usize,
    literal_offset: usize,
    completion_offset: usize,
    timeout_ms: u64 = 90_000,
};

const Report = struct {
    stage: []const u8 = "ready",
    failure: ?[]const u8 = null,
    hover_displayed: bool = false,
    hover_attempts: usize = 0,
    definition_attempts: usize = 0,
    completion_attempts: usize = 0,
    definition_navigated: bool = false,
    navigation_returned: bool = false,
    diagnostic_raised: bool = false,
    diagnostic_cleared: bool = false,
    completion_applied: bool = false,
    completion_undone: bool = false,
    selected_label: []const u8 = "",
    selected_kind: u8 = 0,
    hover_text: std.ArrayList(u8) = .empty,
    before_completion: []const u8 = "",
    after_completion: []const u8 = "",
    after_undo: []const u8 = "",
    undo_before: usize = 0,
    undo_after: usize = 0,
    bad_version: u64 = 0,
    fixed_version: u64 = 0,
    received_diagnostics: u64 = 0,
    received_completions: u64 = 0,
};

fn content(t: *host.Term) []const u8 {
    return t.rt.editorDocument().opened.?.file.content;
}

fn pump(s: *host.AppSession) void {
    lsp.pump(s);
    save.poll();
    _ = completion.acceptPendingOnTimeout(s);
    _ = usleep(5_000);
}

fn errors(t: *host.Term) usize {
    var count: usize = 0;
    for (t.rt.editor_diagnostics.lsp.items) |d| if (d.severity == .@"error") {
        count += 1;
    };
    return count;
}

fn point(t: *host.Term, at: usize) void {
    t.rt.editor_selection = .{ .anchor_start = at, .anchor_end = at, .focus = at };
}

fn change(s: *host.AppSession, t: *host.Term, start: usize, end: usize, text: []const u8) !void {
    var changes = [_]maru.session.editor.delta.Change{.{ .start = start, .end = end, .text = text }};
    if (!ops.applyEditAsOneWithUndo(s, t, &changes)) return error.EditRejected;
}

const Paint = *const fn (*host.AppSession, *host.Term) anyerror!void;

fn runSteps(s: *host.AppSession, t: *host.Term, c: Case, r: *Report, paint: Paint) !void {
    const a = s.allocator;
    var deadline = s.awakeMs() + c.timeout_ms;
    while (lsp.readyClientFor(s, t) == null and s.awakeMs() < deadline) pump(s);
    if (lsp.readyClientFor(s, t) == null) return error.ServerNotReady;

    r.stage = "baseline_diagnostics";
    deadline = s.awakeMs() + c.timeout_ms;
    while ((s.editor_lsp.received_diagnostics == 0 or errors(t) != 0) and s.awakeMs() < deadline) pump(s);
    if (s.editor_lsp.received_diagnostics == 0 or errors(t) != 0) return error.BaselineAnalysisNotReady;

    r.stage = "hover";
    point(t, c.hover_offset);
    deadline = s.awakeMs() + c.timeout_ms;
    var last_hover: u64 = 0;
    while (s.awakeMs() < deadline) {
        if (!s.editor_hover.waiting and s.awakeMs() -| last_hover >= 100) {
            last_hover = s.awakeMs();
            r.hover_attempts += 1;
            hover.hide(s);
            _ = hover.showAtCaret(s);
        }
        pump(s);
        if (!s.editor_hover.waiting and s.chrome_host.hover_box.open) {
            for (hover.lines(s)) |line| {
                try r.hover_text.appendSlice(a, line.text);
                try r.hover_text.append(a, '\n');
            }
            if (std.mem.indexOf(u8, r.hover_text.items, c.symbol) != null) break;
            r.hover_text.clearRetainingCapacity();
        }
    }
    if (std.mem.indexOf(u8, r.hover_text.items, c.symbol) == null) return error.HoverNotDisplayed;
    r.hover_displayed = true;
    hover.hide(s);

    r.stage = "definition";
    point(t, c.hover_offset);
    const moved = s.editor_definition.navigated;
    deadline = s.awakeMs() + c.timeout_ms;
    var last_definition: u64 = 0;
    while (s.editor_definition.navigated == moved and s.awakeMs() < deadline) {
        // A ready initialize response does not mean workspace indexing is done.
        // Retry only this unchanged read in the judge, retaining every raw null
        // response and attempt count. Persistent failure still fails the case.
        if (!s.editor_definition.waiting and s.awakeMs() -| last_definition >= 100) {
            point(t, c.hover_offset);
            last_definition = s.awakeMs();
            r.definition_attempts += 1;
            if (!definition.gotoDefinitionAtCaret(s)) return error.DefinitionNotRequested;
        }
        pump(s);
    }
    if (s.editor_definition.navigated != moved + 1) return error.DefinitionNotNavigated;
    if (pane.activePane(s).activeTerm() != t) return error.DefinitionWrongDocument;
    const at = t.rt.editor_selection.?.focus;
    if (t.rt.editorDocument().opened.?.file.lines.lineAt(at) != c.definition_line) return error.DefinitionWrongLine;
    r.definition_navigated = true;
    if (!ops.navigateBack(s) or t.rt.editor_selection.?.focus != c.hover_offset) return error.NavigationDidNotReturn;
    r.navigation_returned = true;

    r.stage = "diagnostic_raise";
    const before_bad = s.editor_lsp.received_diagnostics;
    try change(s, t, c.literal_offset, c.literal_offset + 2, "\"bad\"");
    r.bad_version = t.rt.editorDocument().notifications.lsp_version;
    try ops.saveDocument(s, t); // rust-analyzer/Metals compile on didSave.
    deadline = s.awakeMs() + c.timeout_ms;
    var raised = false;
    while (s.awakeMs() < deadline) {
        pump(s);
        for (t.rt.editor_diagnostics.lsp.items) |d| {
            if (d.severity == .@"error" and d.start <= c.literal_offset + 4 and d.end > c.literal_offset) raised = true;
        }
        if (raised and s.editor_lsp.received_diagnostics > before_bad) break;
    }
    if (!raised or s.editor_lsp.received_diagnostics <= before_bad) return error.TypeErrorNotPublished;
    r.diagnostic_raised = true;

    r.stage = "diagnostic_clear";
    const before_fix = s.editor_lsp.received_diagnostics;
    try change(s, t, 0, content(t).len, c.good);
    r.fixed_version = t.rt.editorDocument().notifications.lsp_version;
    try ops.saveDocument(s, t);
    deadline = s.awakeMs() + c.timeout_ms;
    while ((errors(t) != 0 or s.editor_lsp.received_diagnostics <= before_fix) and s.awakeMs() < deadline) pump(s);
    if (errors(t) != 0 or s.editor_lsp.received_diagnostics <= before_fix) return error.TypeErrorNotCleared;
    r.diagnostic_cleared = true;

    r.stage = "completion";
    const prefix = c.completion_name[0 .. c.completion_name.len - 1];
    try change(s, t, c.completion_offset, c.completion_offset + c.completion_name.len, prefix);
    point(t, c.completion_offset + prefix.len);
    r.before_completion = try a.dupe(u8, content(t));
    completion.hide(s);
    try paint(s, t);
    const received_before = s.editor_lsp.received_completions;
    deadline = s.awakeMs() + c.timeout_ms;
    var last_completion: u64 = 0;
    var found = false;
    while (s.awakeMs() < deadline) {
        if (!s.editor_completion.waiting and s.awakeMs() -| last_completion >= 100) {
            completion.hide(s);
            last_completion = s.awakeMs();
            r.completion_attempts += 1;
            if (!completion.triggerManual(s)) return error.CompletionNotRequested;
        }
        pump(s);
        if (s.editor_completion.waiting or s.editor_lsp.received_completions <= received_before or s.editor_completion.words_only) continue;
        try paint(s, t);
        if (!completion.refresh(s) or !s.chrome_host.suggest_box.open) continue;
        for (s.editor_completion.order.items, 0..) |index, row| {
            const item = s.editor_completion.items.items[index];
            // Buffer words cannot prove server completion. Some real servers
            // return null while analysis catches up with the unchanged prefix.
            if (item.kind != maru.session.editor.lsp.completion.word_kind and std.mem.eql(u8, item.filter, c.completion_name)) {
                r.selected_label = try a.dupe(u8, item.label);
                r.selected_kind = item.kind;
                s.chrome_host.suggest_box.selected = row;
                found = true;
                break;
            }
        }
        if (found) break;
    }
    if (!found) return error.ExpectedServerCompletionMissing;
    const undo_before = t.rt.editorDocument().history.undo_len;
    r.undo_before = undo_before;
    if (!completion.handleKey(s, .enter, .{})) return error.CompletionEnterNotHandled;
    deadline = s.awakeMs() + c.timeout_ms;
    while (s.editor_completion.active and s.awakeMs() < deadline) pump(s);
    r.after_completion = try a.dupe(u8, content(t));
    if (!std.mem.eql(u8, content(t), c.good)) return error.CompletionAppliedWrongText;
    r.undo_after = t.rt.editorDocument().history.undo_len;
    if (r.undo_after != undo_before + 1) return error.CompletionNotOneUndo;
    r.completion_applied = true;
    if (!ops.undoEdit(s, t) or !std.mem.eql(u8, content(t), r.before_completion)) return error.CompletionUndoWrongText;
    r.after_undo = try a.dupe(u8, content(t));
    r.completion_undone = true;
    r.received_diagnostics = s.editor_lsp.received_diagnostics;
    r.received_completions = s.editor_lsp.received_completions;
    r.stage = "complete";
}

pub fn run(s: *host.AppSession, t: *host.Term, c: Case, paint: Paint) !void {
    var r: Report = .{};
    defer {
        r.hover_text.deinit(s.allocator);
        if (r.selected_label.len > 0) s.allocator.free(r.selected_label);
        if (r.before_completion.len > 0) s.allocator.free(r.before_completion);
        if (r.after_completion.len > 0) s.allocator.free(r.after_completion);
        if (r.after_undo.len > 0) s.allocator.free(r.after_undo);
    }
    runSteps(s, t, c, &r, paint) catch |err| {
        r.failure = @errorName(err);
        try write(s, c, r);
        return err;
    };
    try write(s, c, r);
}

fn write(s: *host.AppSession, c: Case, r: Report) !void {
    // Embed the exact controller inputs in this test binary. A stale binary
    // cannot claim the newly copied checkout sources merely by reading disk.
    const source_files = .{
        .{ "real_lsp_judge.zig", @embedFile("real_lsp_judge.zig") },
        .{ "mod.zig", @embedFile("mod.zig") },
        .{ "lsp.zig", @embedFile("lsp.zig") },
        .{ "completion.zig", @embedFile("completion.zig") },
        .{ "hover.zig", @embedFile("hover.zig") },
        .{ "definition.zig", @embedFile("definition.zig") },
        .{ "semantic.zig", @embedFile("semantic.zig") },
    };
    var fingerprints: [source_files.len]struct { name: []const u8, sha256: [64]u8 } = undefined;
    inline for (source_files, 0..) |entry, index| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(entry[1], &digest, .{});
        fingerprints[index] = .{ .name = entry[0], .sha256 = std.fmt.bytesToHex(digest, .lower) };
    }
    const bytes = try std.json.Stringify.valueAlloc(s.allocator, .{
        .schema = "maru.lsp-real.product.v1",
        .build_mode = @tagName(@import("builtin").mode),
        .source_fingerprints = fingerprints,
        .stage = r.stage,
        .failure = r.failure,
        .hover_displayed = r.hover_displayed,
        .hover_attempts = r.hover_attempts,
        .definition_attempts = r.definition_attempts,
        .completion_attempts = r.completion_attempts,
        .hover_text = r.hover_text.items,
        .definition_navigated = r.definition_navigated,
        .navigation_returned = r.navigation_returned,
        .diagnostic_raised = r.diagnostic_raised,
        .diagnostic_cleared = r.diagnostic_cleared,
        .completion_applied = r.completion_applied,
        .completion_undone = r.completion_undone,
        .selected_label = r.selected_label,
        .selected_kind = r.selected_kind,
        .before_completion = r.before_completion,
        .after_completion = r.after_completion,
        .after_undo = r.after_undo,
        .undo_before = r.undo_before,
        .undo_after = r.undo_after,
        .bad_version = r.bad_version,
        .fixed_version = r.fixed_version,
        .received_diagnostics = s.editor_lsp.received_diagnostics,
        .received_completions = s.editor_lsp.received_completions,
    }, .{ .whitespace = .indent_2 });
    defer s.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = c.report_path, .data = bytes });
}
