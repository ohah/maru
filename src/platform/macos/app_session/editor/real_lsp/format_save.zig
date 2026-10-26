//! Actual Cmd+S, formatting, asynchronous save and Undo through AppSession.
//! Held real responses exercise stale and timeout paths without changing bytes.
const std = @import("std");
const maru = @import("maru");
const host = @import("../../../app_session.zig");
const ops = @import("../mod.zig");
const lsp = @import("../lsp.zig");
const fmt = @import("../format.zig");
const save = @import("../save/dispatch.zig");
const definition = @import("../definition.zig");
const single = @import("../real_lsp_judge.zig");
extern "c" fn usleep(usec: c_uint) c_int;

pub const Case = struct {
    scenario: []const u8,
    language: []const u8,
    nonce: []const u8,
    root: []const u8,
    path: []const u8,
    good: []const u8,
    report_path: []const u8,
    before_save: []const u8,
    formatted: []const u8,
    local: []const u8,
    timeout_source: []const u8,
    disabled_source: []const u8,
    definition_offset: usize,
    metadata: struct { path: []const u8, good: []const u8 },
    timeout_ms: u64 = 90_000,
};
const Sample = struct { phase: []const u8, buffer: []u8, disk: []u8, version: u64, undo_len: usize, dirty: bool };
const Report = struct {
    stage: []const u8 = "ready",
    failure: ?[]const u8 = null,
    request_ids: [3]u32 = .{ 0, 0, 0 },
    samples: []Sample = &.{},
    applied: u64 = 0,
    stale: u64 = 0,
    timeouts: u64 = 0,
    format_requests: u64 = 0,
    saves: u64 = 0,
    duplicate_commands_suppressed: bool = false,
    stale_response_observed: bool = false,
    timeout_response_observed: bool = false,
    disabled_no_request: bool = false,
    timeout_ms: u64 = fmt.save_format_timeout_ms,
    timeout_deadline_ms: u64 = 0,
    timeout_response_seen_ms: u64 = 0,
    timeout_hold_end_ms: u64 = 0,
};
const Paint = *const fn (*host.AppSession, *host.Term) anyerror!void;
fn body(t: *host.Term) []const u8 {
    return t.rt.editorDocument().opened.?.file.content;
}
fn pump(s: *host.AppSession) void {
    lsp.pump(s);
    save.poll();
    _ = usleep(5_000);
}
fn sent(s: *host.AppSession, t: *host.Term, timeout: u64) !void {
    const end = s.awakeMs() + timeout;
    while (s.awakeMs() < end) {
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
fn capture(s: *host.AppSession, t: *host.Term, c: Case, phase: []const u8, r: *Report, slots: []Sample) !void {
    const len = r.samples.len;
    if (len >= slots.len) return error.SampleCapacity;
    const disk = try std.Io.Dir.cwd().readFileAlloc(s.io, c.path, s.allocator, .limited(1 << 20));
    errdefer s.allocator.free(disk);
    const text = try s.allocator.dupe(u8, body(t));
    slots[len] = .{ .phase = phase, .buffer = text, .disk = disk, .version = t.rt.editorDocument().notifications.lsp_version, .undo_len = t.rt.editorDocument().history.undo_len, .dirty = ops.isDirty(t) };
    r.samples = slots[0 .. len + 1];
}
fn ready(s: *host.AppSession, t: *host.Term, c: Case) !void {
    t.rt.editor_selection = .{ .anchor_start = c.definition_offset, .anchor_end = c.definition_offset, .focus = c.definition_offset };
    const previous = s.editor_definition.navigated;
    var seen = s.editor_definition.notified_none;
    var last_request: u64 = 0;
    const end = s.awakeMs() + c.timeout_ms;
    while (s.editor_definition.navigated == previous and s.awakeMs() < end) {
        _ = try single.acknowledgeDefinitionMiss(s, &seen);
        if (!s.editor_definition.waiting and s.awakeMs() -| last_request >= 100) {
            last_request = s.awakeMs();
            if (!definition.gotoDefinitionAtCaret(s)) return error.DefinitionNotRequested;
        }
        pump(s);
    }
    if (s.editor_definition.navigated == previous) return error.FormatAnalysisNotReady;
}
fn request(s: *host.AppSession, t: *host.Term, paint: Paint) !u32 {
    _ = try s.handleKeyEvent(.{ .key = .{ .char = 's' }, .modifiers = .{ .command = true } });
    if (!s.editor_format.waiting or !s.editor_format.then_save or s.editor_format.external_id != 0) return error.SaveDidNotWaitForLsp;
    try paint(s, t);
    return maru.session.editor.lsp.rpc.formatting_id_base + s.editor_format.waiting_seq;
}
fn settled(s: *host.AppSession, t: *host.Term, timeout: u64) !void {
    const end = s.awakeMs() + timeout;
    while ((s.editor_format.waiting or save.requestCount() != 0) and s.awakeMs() < end) pump(s);
    if (s.editor_format.waiting or save.requestCount() != 0) return error.SaveDidNotSettle;
    // The final worker completion can mark didSave after the LSP flush in pump.
    try sent(s, t, timeout);
}
fn responseObserved(s: *host.AppSession, c: Case, id: u32) !void {
    const path = try std.fs.path.join(s.allocator, &.{ c.root, "wire.ndjson" });
    defer s.allocator.free(path);
    const end = s.awakeMs() + c.timeout_ms;
    while (s.awakeMs() < end) {
        const wire = try std.Io.Dir.cwd().readFileAlloc(s.io, path, s.allocator, .limited(16 << 20));
        defer s.allocator.free(wire);
        var lines = std.mem.splitScalar(u8, wire, '\n');
        while (lines.next()) |line| {
            var p = std.json.parseFromSlice(std.json.Value, s.allocator, line, .{}) catch continue;
            defer p.deinit();
            const v = p.value;
            if (v != .object) continue;
            const dir = v.object.get("direction") orelse continue;
            const m = v.object.get("message") orelse continue;
            if (dir != .string or !std.mem.eql(u8, dir.string, "server") or m != .object or m.object.contains("method")) continue;
            const mid = m.object.get("id") orelse continue;
            if (mid != .integer or mid.integer != id) continue;
            const result = m.object.get("result") orelse return error.RealFormattingServerError;
            if (m.object.contains("error") or result != .array or result.array.items.len == 0) return error.RealFormattingServerError;
            return;
        }
        // The actual SDK response waits in the transport until local invalidation.
        _ = usleep(5_000);
    }
    return error.RealFormattingResponseMissing;
}
fn dismiss(s: *host.AppSession) !void {
    // Called only after verifying this judge's own stale/timeout outcome.
    if (s.chrome_host.notice.open) _ = try s.handleKeyEvent(.{ .key = .escape });
}
fn steps(s: *host.AppSession, t: *host.Term, c: Case, r: *Report, slots: []Sample, paint: Paint) !void {
    if (!std.mem.eql(u8, c.scenario, "format-save") or (!std.mem.eql(u8, c.language, "rust") and !std.mem.eql(u8, c.language, "go"))) return error.InvalidFormatSaveCase;
    const language = maru.config.theme.formatterLanguageIndex(c.language) orelse return error.UnsupportedFormatterLanguage;
    s.loaded_config.config.editor.formatter[language] = .{ .choice = .lsp };
    s.loaded_config.config.editor.format_on_save = true;
    s.loaded_config.config.editor.code_actions_on_save = "";
    const applied0 = s.editor_format.applied;
    const stale0 = s.editor_format.stale;
    const timeouts0 = s.editor_format.save_timeouts;
    const requests0 = s.editor_lsp.sent_formattings;
    const saves0 = s.editor_lsp.sent_saves;
    r.stage = "baseline";
    try sent(s, t, c.timeout_ms);
    try capture(s, t, c, "before", r, slots);
    try change(s, t, c.before_save);
    try ready(s, t, c);
    try capture(s, t, c, "dirty", r, slots);
    r.stage = "normal_save";
    r.request_ids[0] = try request(s, t, paint);
    try capture(s, t, c, "waiting_normal", r, slots);
    // Same-document saves and explicit format must not steal the pending save.
    _ = try s.handleKeyEvent(.{ .key = .{ .char = 's' }, .modifiers = .{ .command = true } });
    _ = try s.handleKeyEvent(.{ .key = .{ .char = 'F' }, .modifiers = .{ .option = true, .shift = true } });
    if (s.editor_lsp.sent_formattings != requests0 + 1 or !s.editor_format.then_save) return error.PendingSaveWasReplaced;
    r.duplicate_commands_suppressed = true;
    try settled(s, t, c.timeout_ms);
    if (s.editor_format.applied != applied0 + 1 or s.editor_format.save_timeouts != timeouts0) return error.NormalFormatSaveFailed;
    try capture(s, t, c, "saved_normal", r, slots);
    r.stage = "undo";
    s.dispatchAppAction(.editor_undo);
    try sent(s, t, c.timeout_ms);
    try capture(s, t, c, "undone", r, slots);
    r.stage = "stale_save";
    try ready(s, t, c);
    r.request_ids[1] = try request(s, t, paint);
    try capture(s, t, c, "waiting_stale", r, slots);
    try responseObserved(s, c, r.request_ids[1]);
    if (s.awakeMs() >= s.editor_format.save_deadline_ms) return error.StaleResponseExceededSaveDeadline;
    r.stale_response_observed = true;
    try change(s, t, c.local);
    try settled(s, t, c.timeout_ms);
    if (s.editor_format.stale != stale0 + 1 or s.editor_format.applied != applied0 + 1 or s.editor_format.save_timeouts != timeouts0) return error.StaleFormatSaveFailed;
    try capture(s, t, c, "saved_stale", r, slots);
    try dismiss(s);
    r.stage = "timeout_save";
    try change(s, t, c.timeout_source);
    try ready(s, t, c);
    r.request_ids[2] = try request(s, t, paint);
    r.timeout_deadline_ms = s.editor_format.save_deadline_ms;
    try capture(s, t, c, "waiting_timeout", r, slots);
    try responseObserved(s, c, r.request_ids[2]);
    r.timeout_response_seen_ms = s.awakeMs();
    if (r.timeout_response_seen_ms >= r.timeout_deadline_ms) return error.TimeoutResponseAlreadyLate;
    r.timeout_response_observed = true;
    while (s.awakeMs() < r.timeout_deadline_ms) _ = usleep(5_000);
    r.timeout_hold_end_ms = s.awakeMs();
    try settled(s, t, c.timeout_ms);
    if (s.editor_format.save_timeouts != timeouts0 + 1 or s.editor_format.applied != applied0 + 1) return error.TimeoutFormatWasApplied;
    try capture(s, t, c, "saved_timeout", r, slots);
    try dismiss(s);
    r.stage = "disabled_save";
    s.loaded_config.config.editor.format_on_save = false;
    try change(s, t, c.disabled_source);
    _ = try s.handleKeyEvent(.{ .key = .{ .char = 's' }, .modifiers = .{ .command = true } });
    try settled(s, t, c.timeout_ms);
    if (s.editor_lsp.sent_formattings != requests0 + 3) return error.DisabledSaveRequestedFormat;
    r.disabled_no_request = true;
    try capture(s, t, c, "saved_disabled", r, slots);
    r.applied = s.editor_format.applied - applied0;
    r.stale = s.editor_format.stale - stale0;
    r.timeouts = s.editor_format.save_timeouts - timeouts0;
    r.format_requests = s.editor_lsp.sent_formattings - requests0;
    r.saves = s.editor_lsp.sent_saves - saves0;
    if (r.saves != 4) return error.SaveNotificationsMissing;
    r.stage = "complete";
}
pub fn run(s: *host.AppSession, t: *host.Term, c: Case, paint: Paint) !void {
    const slots = try s.allocator.alloc(Sample, 10);
    defer s.allocator.free(slots);
    var r: Report = .{};
    defer for (r.samples) |sample| {
        s.allocator.free(sample.disk);
        s.allocator.free(sample.buffer);
    };
    steps(s, t, c, &r, slots, paint) catch |err| {
        r.failure = @errorName(err);
        try write(s, c, r);
        return err;
    };
    try write(s, c, r);
}
fn write(s: *host.AppSession, c: Case, r: Report) !void {
    const files = .{
        .{ "format_save_judge.zig", @embedFile("format_save.zig") },
        .{ "real_lsp_judge.zig", @embedFile("../real_lsp_judge.zig") },
        .{ "mod.zig", @embedFile("../mod.zig") },
        .{ "lsp.zig", @embedFile("../lsp.zig") },
        .{ "completion.zig", @embedFile("../completion.zig") },
        .{ "hover.zig", @embedFile("../hover.zig") },
        .{ "definition.zig", @embedFile("../definition.zig") },
        .{ "semantic.zig", @embedFile("../semantic.zig") },
        .{ "format.zig", @embedFile("../format.zig") },
        .{ "save_dispatch.zig", @embedFile("../save/dispatch.zig") },
        .{ "local_save.zig", @embedFile("../local_save.zig") },
    };
    var fingerprints: [files.len]struct { name: []const u8, sha256: [64]u8 } = undefined;
    inline for (files, 0..) |file, i| {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(file[1], &digest, .{});
        fingerprints[i] = .{ .name = file[0], .sha256 = std.fmt.bytesToHex(digest, .lower) };
    }
    const bytes = try std.json.Stringify.valueAlloc(s.allocator, .{ .schema = "maru.lsp-real.product.v1", .scenario = "format-save", .language = c.language, .build_mode = @tagName(@import("builtin").mode), .source_fingerprints = fingerprints, .stage = r.stage, .failure = r.failure, .result = r }, .{ .whitespace = .indent_2 });
    defer s.allocator.free(bytes);
    try std.Io.Dir.cwd().writeFile(s.io, .{ .sub_path = c.report_path, .data = bytes });
}
