//! CR6d-v2b Apple Korean IME candidate-window evidence reducer.
//!
//! The WindowServer producer must submit complete bounded snapshots.  Selection lives here so
//! the product producer and the artifact verifier cannot quietly use different heuristics.

const std = @import("std");

pub const max_windows: usize = 256;
pub const required_observations: usize = 5;
pub const max_transcript_bytes: usize = 1024 * 1024;
pub const max_artifact_bytes: usize = 16 * 1024;
pub const digest_hex_bytes: usize = 64;

pub const Rect = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,

    fn valid(self: Rect) bool {
        return std.math.isFinite(self.x) and std.math.isFinite(self.y) and
            std.math.isFinite(self.w) and std.math.isFinite(self.h) and self.w > 0 and self.h > 0 and
            std.math.isFinite(self.x + self.w) and std.math.isFinite(self.y + self.h);
    }

    fn midpoint(self: Rect) struct { x: f64, y: f64 } {
        return .{ .x = self.x + self.w / 2, .y = self.y + self.h / 2 };
    }

    fn contains(self: Rect, point: anytype) bool {
        return point.x >= self.x and point.y >= self.y and
            point.x < self.x + self.w and point.y < self.y + self.h;
    }

    fn containsRect(self: Rect, other: Rect) bool {
        return self.valid() and other.valid() and other.x >= self.x and other.y >= self.y and
            other.x + other.w <= self.x + self.w and other.y + other.h <= self.y + self.h;
    }
};

pub const OwnerIdentity = struct {
    pid: i32,
    bundle_id: []const u8,
    signing_id: []const u8,
    apple_signed: bool,

    fn valid(self: OwnerIdentity) bool {
        return self.pid > 0 and self.bundle_id.len > 0 and self.bundle_id.len <= 255 and
            self.signing_id.len > 0 and self.signing_id.len <= 255 and self.apple_signed;
    }

    fn eql(a: OwnerIdentity, b: OwnerIdentity) bool {
        return a.pid == b.pid and a.apple_signed == b.apple_signed and
            std.mem.eql(u8, a.bundle_id, b.bundle_id) and std.mem.eql(u8, a.signing_id, b.signing_id);
    }
};

pub const Window = struct {
    id: u32,
    owner: OwnerIdentity,
    layer: i32,
    bounds: Rect,
    on_screen: bool,
};

const CounterChanges = struct {
    pty_input_changed: bool,
    pty_open_interval_changed: bool,
    pty_close_interval_changed: bool,
    committed_callbacks_changed: bool,
    screen_generation_changed: bool,
};

// Describe every changed axis, not just the first mismatch. Diagnostics never expose the values
// or affect the strict verdict, and both open and close observations matter equally.
fn counterChanges(before: Counters, opened: Counters, closed: Counters) CounterChanges {
    return .{
        .pty_input_changed = before.pty_input_bytes != opened.pty_input_bytes or before.pty_input_bytes != closed.pty_input_bytes,
        .pty_open_interval_changed = before.pty_input_bytes != opened.pty_input_bytes,
        .pty_close_interval_changed = opened.pty_input_bytes != closed.pty_input_bytes,
        .committed_callbacks_changed = before.committed_text_callbacks != opened.committed_text_callbacks or before.committed_text_callbacks != closed.committed_text_callbacks,
        .screen_generation_changed = before.base_screen_generation != opened.base_screen_generation or before.base_screen_generation != closed.base_screen_generation,
    };
}

pub const Counters = struct {
    pty_input_bytes: u64,
    committed_text_callbacks: u64,
    base_screen_generation: u64,

    fn eql(a: Counters, b: Counters) bool {
        return std.meta.eql(a, b);
    }
};

pub const Triplet = struct {
    before: []const Window,
    opened: []const Window,
    closed: []const Window,
    before_counters: Counters,
    opened_counters: Counters,
    closed_counters: Counters,
};

pub const Candidate = struct {
    window_id: u32,
    owner: OwnerIdentity,
    layer: i32,
    bounds: Rect,
};

pub const Error = error{
    InvalidAppPid,
    InventoryTooLarge,
    DuplicateWindowId,
    CounterMutation,
    CandidateMissing,
    CandidateAmbiguous,
    CandidateOwnerInvalid,
    CandidateNotClosed,
    CandidateIdentityDrift,
    CandidateGeometryDrift,
    InvalidDisplay,
    AnchorOutsideDisplay,
    AnchorDrift,
};

/// Reduces one request/open/Escape-close observation.  Any concurrent new eligible window makes
/// the result ambiguous rather than letting the producer choose the convenient row.
pub fn reduceTriplet(app_pid: i32, triplet: Triplet) Error!Candidate {
    if (app_pid <= 0) return error.InvalidAppPid;
    try validateSnapshot(triplet.before);
    try validateSnapshot(triplet.opened);
    try validateSnapshot(triplet.closed);
    try validateReusedWindowIdentity(triplet.before, triplet.opened);
    try validateReusedWindowIdentity(triplet.before, triplet.closed);

    var selected: ?Window = null;
    for (triplet.opened) |window| {
        if (!window.on_screen or !window.bounds.valid() or window.owner.pid == app_pid or
            containsId(triplet.before, window.id)) continue;
        if (selected != null) return error.CandidateAmbiguous;
        selected = window;
    }
    const candidate = selected orelse return error.CandidateMissing;
    if (!candidate.owner.valid()) return error.CandidateOwnerInvalid;
    if (findById(triplet.closed, candidate.id) != null) return error.CandidateNotClosed;
    for (triplet.closed) |window| {
        if (!window.on_screen or !window.bounds.valid() or window.owner.pid == app_pid or
            containsId(triplet.before, window.id)) continue;
        return error.CandidateNotClosed;
    }
    // Diagnose absent/invalid candidate authority first; counter drift must not hide that the
    // request never produced a candidate. The same conjunction still rejects every mutation.
    if (!Counters.eql(triplet.before_counters, triplet.opened_counters) or
        !Counters.eql(triplet.before_counters, triplet.closed_counters)) return error.CounterMutation;
    return .{
        .window_id = candidate.id,
        .owner = candidate.owner,
        .layer = candidate.layer,
        .bounds = candidate.bounds,
    };
}

/// The five observations share a process/signing identity and geometry, while their transient
/// window IDs must be fresh.  Reusing an old ID would make before/open causality ambiguous.
pub fn validateSeries(candidates: []const Candidate) Error!Candidate {
    if (candidates.len != required_observations) return error.CandidateMissing;
    const first = candidates[0];
    for (candidates, 0..) |candidate, index| {
        if (candidate.window_id == 0 or !candidate.owner.valid()) return error.CandidateOwnerInvalid;
        if (!candidate.bounds.valid()) return error.CandidateGeometryDrift;
        if (!OwnerIdentity.eql(first.owner, candidate.owner)) return error.CandidateIdentityDrift;
        if (candidate.layer != first.layer or !std.meta.eql(candidate.bounds, first.bounds))
            return error.CandidateGeometryDrift;
        for (candidates[0..index]) |prior| if (prior.window_id == candidate.window_id)
            return error.DuplicateWindowId;
    }
    return first;
}

pub const DisplayTranscript = struct {
    id: u32,
    appkit_frame: Rect,
    quartz_bounds: Rect,
};

pub const ConvertedRect = struct { display_id: u32, rect: Rect };

/// Converts an AppKit bottom-left screen rect to Quartz's main-display top-left coordinate space.
pub fn appKitToQuartz(anchor: Rect, displays: []const DisplayTranscript) Error!ConvertedRect {
    if (!anchor.valid()) return error.AnchorOutsideDisplay;
    const point = anchor.midpoint();
    var selected: ?DisplayTranscript = null;
    for (displays, 0..) |display, index| {
        if (display.id == 0 or !display.appkit_frame.valid() or !display.quartz_bounds.valid() or
            display.appkit_frame.w != display.quartz_bounds.w or display.appkit_frame.h != display.quartz_bounds.h)
            return error.InvalidDisplay;
        for (displays[0..index]) |prior| if (prior.id == display.id) return error.InvalidDisplay;
        if (display.appkit_frame.contains(point)) {
            if (selected != null) return error.InvalidDisplay;
            selected = display;
        }
    }
    const display = selected orelse return error.AnchorOutsideDisplay;
    const local_x = anchor.x - display.appkit_frame.x;
    const local_top = display.appkit_frame.y + display.appkit_frame.h - (anchor.y + anchor.h);
    return .{
        .display_id = display.id,
        .rect = .{
            .x = display.quartz_bounds.x + local_x,
            .y = display.quartz_bounds.y + local_top,
            .w = anchor.w,
            .h = anchor.h,
        },
    };
}

fn validateSnapshot(windows: []const Window) Error!void {
    if (windows.len > max_windows) return error.InventoryTooLarge;
    for (windows, 0..) |window, index| {
        if (window.id == 0) return error.DuplicateWindowId;
        for (windows[0..index]) |prior| if (prior.id == window.id) return error.DuplicateWindowId;
    }
}

fn containsId(windows: []const Window, id: u32) bool {
    return findById(windows, id) != null;
}

fn validateReusedWindowIdentity(baseline: []const Window, later: []const Window) Error!void {
    for (later) |window| if (findById(baseline, window.id)) |prior| {
        if (!OwnerIdentity.eql(prior.owner, window.owner)) return error.CandidateIdentityDrift;
    };
}

fn findById(windows: []const Window, id: u32) ?Window {
    for (windows) |window| if (window.id == id) return window;
    return null;
}

const RawSnapshot = struct {
    windows: []const Window,
    counters: Counters,
    anchor_appkit: Rect,
    displays: []const DisplayTranscript,
};

const RawRow = struct {
    before: RawSnapshot,
    opened: RawSnapshot,
    closed: RawSnapshot,
};

const RawTranscript = struct {
    schema: []const u8,
    app_pid: i32,
    source_id: []const u8,
    rows: []const RawRow,
};

const CaptureSelectionTranscript = struct {
    schema: []const u8,
    app_pid: i32,
    before: RawSnapshot,
    opened: RawSnapshot,
};

pub const CaptureSelection = extern struct {
    window_id: u32,
    owner_pid: i32,
    layer: i32,
    x: f64,
    y: f64,
    w: f64,
    h: f64,
};

/// Selects the one transient window before ScreenCaptureKit sees an ID. Swift submits complete
/// inventories and therefore cannot quietly grow a second candidate heuristic.
pub fn selectCaptureCandidate(
    allocator: std.mem.Allocator,
    bytes: []const u8,
) !CaptureSelection {
    if (bytes.len == 0 or bytes.len > max_transcript_bytes) return error.InventoryTooLarge;
    var parsed = std.json.parseFromSlice(CaptureSelectionTranscript, allocator, bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidTranscript;
    defer parsed.deinit();
    const raw = parsed.value;
    if (!std.mem.eql(u8, raw.schema, "maru.session-host-cr6d-ime-candidate-selection.v1"))
        return error.InvalidTranscript;
    // The retryable absence verdict must never conceal an input or screen mutation. The final
    // five-row publisher still proves the full before/open/close counter conjunction later.
    if (!Counters.eql(raw.before.counters, raw.opened.counters)) return error.CounterMutation;
    const candidate = try reduceTriplet(raw.app_pid, .{
        .before = raw.before.windows,
        .opened = raw.opened.windows,
        // Selection happens while the window is open. Closure and counter immutability are
        // deliberately re-proved by the final five-row publisher.
        .closed = raw.before.windows,
        .before_counters = raw.before.counters,
        .opened_counters = raw.opened.counters,
        .closed_counters = raw.before.counters,
    });
    return .{
        .window_id = candidate.window_id,
        .owner_pid = candidate.owner.pid,
        .layer = candidate.layer,
        .x = candidate.bounds.x,
        .y = candidate.bounds.y,
        .w = candidate.bounds.w,
        .h = candidate.bounds.h,
    };
}

const ArtifactRow = struct {
    window_id: u32,
    owner_pid: i32,
    bundle_id: []const u8,
    signing_id: []const u8,
    apple_signed: bool,
    layer: i32,
    bounds: Rect,
    counters: Counters,
    display_id: u32,
    anchor_quartz: Rect,
};

const Artifact = struct {
    schema: []const u8 = "maru.session-host-cr6d-ime-candidate-observation.v1",
    source_id: []const u8,
    rows: []const ArtifactRow,
};

const PixelEvidence = struct {
    schema: []const u8,
    runtime_id: []const u8,
    surface_id: u64,
    frame_generation: u64,
    first_rect: Rect,
    window_id: u32,
    owner_pid: i32,
    bundle_id: []const u8,
    signing_id: []const u8,
    apple_signed: bool,
    layer: i32,
    bounds: Rect,
    pixel_width: usize,
    pixel_height: usize,
    capture_sha256: []const u8,
    capture_complete: bool,
    input_source_restored: bool,
    first_responder_restored: bool,
    restore_record_absent: bool,
};

const PixelArtifact = struct {
    schema: []const u8 = "maru.session-host-cr6d-ime-candidate-pixel.v1",
    runtime_id: []const u8,
    surface_id: u64,
    frame_generation: u64,
    first_rect: Rect,
    window_id: u32,
    owner_pid: i32,
    bundle_id: []const u8,
    signing_id: []const u8,
    apple_signed: bool,
    layer: i32,
    bounds: Rect,
    display_id: u32,
    anchor_quartz: Rect,
    pixel_width: usize,
    pixel_height: usize,
    capture_sha256: []const u8,
    capture_complete: bool,
    input_source_restored: bool,
    first_responder_restored: bool,
    restore_record_absent: bool,
};

fn validLowerHex(bytes: []const u8) bool {
    if (bytes.len == 0) return false;
    for (bytes) |byte| if (!((byte >= '0' and byte <= '9') or (byte >= 'a' and byte <= 'f')))
        return false;
    return true;
}

fn publishCanonicalBytes(
    allocator: std.mem.Allocator,
    output_path: [:0]const u8,
    value: anytype,
) !void {
    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    try json.write(value);
    try output.writer.writeByte('\n');
    if (output.written().len > max_artifact_bytes) return error.ArtifactTooLarge;
    const temporary = try std.fmt.allocPrintSentinel(allocator, "{s}.tmp.{d}", .{ output_path, std.c.getpid() }, 0);
    defer allocator.free(temporary);
    const fd = std.c.open(temporary.ptr, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .CLOEXEC = true, .NOFOLLOW = true }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.ArtifactCreateFailed;
    defer _ = std.c.unlink(temporary.ptr);
    var open = true;
    defer if (open) {
        _ = std.c.close(fd);
    };
    var offset: usize = 0;
    while (offset < output.written().len) {
        const amount = std.c.write(fd, output.written()[offset..].ptr, output.written().len - offset);
        if (amount < 0 and std.posix.errno(amount) == .INTR) continue;
        if (amount <= 0) return error.ArtifactWriteFailed;
        offset += @intCast(amount);
    }
    if (std.c.fsync(fd) != 0 or std.c.close(fd) != 0) return error.ArtifactWriteFailed;
    open = false;
    if (std.c.link(temporary.ptr, output_path.ptr) != 0) return error.ArtifactPublishFailed;
}

pub fn publishPixelObservation(
    allocator: std.mem.Allocator,
    transcript_bytes: []const u8,
    evidence_bytes: []const u8,
    output_path: [:0]const u8,
) !void {
    if (transcript_bytes.len == 0 or transcript_bytes.len > max_transcript_bytes or
        evidence_bytes.len == 0 or evidence_bytes.len > max_artifact_bytes) return error.InventoryTooLarge;
    var transcript = std.json.parseFromSlice(RawTranscript, allocator, transcript_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidTranscript;
    defer transcript.deinit();
    var parsed_evidence = std.json.parseFromSlice(PixelEvidence, allocator, evidence_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidTranscript;
    defer parsed_evidence.deinit();
    const raw = transcript.value;
    const evidence = parsed_evidence.value;
    if (!std.mem.eql(u8, raw.schema, "maru.session-host-cr6d-ime-candidate-transcript.v1") or
        raw.rows.len != required_observations or
        raw.source_id.len == 0 or raw.source_id.len > 255 or
        !std.mem.eql(u8, evidence.schema, "maru.session-host-cr6d-ime-candidate-pixel-evidence.v1") or
        evidence.runtime_id.len != 32 or !validLowerHex(evidence.runtime_id) or
        evidence.surface_id == 0 or evidence.frame_generation == 0 or !evidence.first_rect.valid() or
        evidence.capture_sha256.len != digest_hex_bytes or !validLowerHex(evidence.capture_sha256) or
        evidence.pixel_width == 0 or evidence.pixel_height == 0 or !evidence.capture_complete or
        !evidence.input_source_restored or !evidence.first_responder_restored or !evidence.restore_record_absent)
        return error.InvalidTranscript;
    var candidates: [required_observations]Candidate = undefined;
    var anchor: ?ConvertedRect = null;
    for (raw.rows, 0..) |row, index| {
        candidates[index] = try reduceTriplet(raw.app_pid, .{
            .before = row.before.windows,
            .opened = row.opened.windows,
            .closed = row.closed.windows,
            .before_counters = row.before.counters,
            .opened_counters = row.opened.counters,
            .closed_counters = row.closed.counters,
        });
        const before_anchor = try appKitToQuartz(row.before.anchor_appkit, row.before.displays);
        const converted = try appKitToQuartz(row.opened.anchor_appkit, row.opened.displays);
        const closed_anchor = try appKitToQuartz(row.closed.anchor_appkit, row.closed.displays);
        // A stacked monitor can share the caret's x band. Bind the entire OS window to the
        // display that owns the caret before accepting its repeated placement as IME evidence.
        var caret_display_bounds: ?Rect = null;
        for (row.opened.displays) |display| {
            if (display.id == converted.display_id) {
                caret_display_bounds = display.quartz_bounds;
                break;
            }
        }
        if (!(caret_display_bounds orelse return error.InvalidDisplay).containsRect(candidates[index].bounds))
            return error.CandidateGeometryDrift;
        if (!std.meta.eql(before_anchor, converted) or !std.meta.eql(before_anchor, closed_anchor) or
            !std.meta.eql(row.opened.anchor_appkit, evidence.first_rect)) return error.AnchorDrift;
        if (anchor) |prior| {
            if (!std.meta.eql(prior, converted)) return error.AnchorDrift;
        } else anchor = converted;
    }
    const candidate = try validateSeries(&candidates);
    const converted = anchor orelse return error.AnchorDrift;
    if (candidate.window_id != evidence.window_id or candidate.owner.pid != evidence.owner_pid or
        candidate.layer != evidence.layer or !std.meta.eql(candidate.bounds, evidence.bounds) or
        !std.mem.eql(u8, candidate.owner.bundle_id, evidence.bundle_id) or
        !std.mem.eql(u8, candidate.owner.signing_id, evidence.signing_id) or
        candidate.owner.apple_signed != evidence.apple_signed) return error.CandidateIdentityDrift;
    // No guessed distance threshold: the caret midpoint must share the candidate's horizontal
    // band, while the candidate may be below it or flip above it at a display edge.
    const caret = converted.rect.midpoint();
    const horizontal = caret.x >= candidate.bounds.x and caret.x < candidate.bounds.x + candidate.bounds.w;
    const below = candidate.bounds.y >= converted.rect.y + converted.rect.h;
    const above = candidate.bounds.y + candidate.bounds.h <= converted.rect.y;
    if (!horizontal or (!below and !above)) return error.CandidateGeometryDrift;
    try publishCanonicalBytes(allocator, output_path, PixelArtifact{
        .runtime_id = evidence.runtime_id,
        .surface_id = evidence.surface_id,
        .frame_generation = evidence.frame_generation,
        .first_rect = evidence.first_rect,
        .window_id = evidence.window_id,
        .owner_pid = evidence.owner_pid,
        .bundle_id = evidence.bundle_id,
        .signing_id = evidence.signing_id,
        .apple_signed = evidence.apple_signed,
        .layer = evidence.layer,
        .bounds = evidence.bounds,
        .display_id = converted.display_id,
        .anchor_quartz = converted.rect,
        .pixel_width = evidence.pixel_width,
        .pixel_height = evidence.pixel_height,
        .capture_sha256 = evidence.capture_sha256,
        .capture_complete = evidence.capture_complete,
        .input_source_restored = evidence.input_source_restored,
        .first_responder_restored = evidence.first_responder_restored,
        .restore_record_absent = evidence.restore_record_absent,
    });
}

/// Swift lends the complete in-memory transcript once.  Parsing, candidate selection, series
/// authority and absent-target publication stay in Zig so the producer cannot grow a second
/// heuristic or leave another application's window inventory on disk.
pub fn publishObservation(
    allocator: std.mem.Allocator,
    transcript_bytes: []const u8,
    output_path: [:0]const u8,
) !void {
    if (transcript_bytes.len == 0 or transcript_bytes.len > max_transcript_bytes)
        return error.InventoryTooLarge;
    if (output_path.len == 0 or output_path.len >= std.fs.max_path_bytes)
        return error.InvalidOutput;
    var parsed = std.json.parseFromSlice(RawTranscript, allocator, transcript_bytes, .{
        .allocate = .alloc_always,
        .ignore_unknown_fields = false,
        .duplicate_field_behavior = .@"error",
    }) catch return error.InvalidTranscript;
    defer parsed.deinit();
    const raw = parsed.value;
    if (!std.mem.eql(u8, raw.schema, "maru.session-host-cr6d-ime-candidate-transcript.v1") or
        raw.source_id.len == 0 or raw.source_id.len > 255 or
        raw.rows.len != required_observations) return error.InvalidTranscript;

    var candidates: [required_observations]Candidate = undefined;
    var rows: [required_observations]ArtifactRow = undefined;
    var series_anchor: ?ConvertedRect = null;
    for (raw.rows, 0..) |row, index| {
        const candidate = reduceTriplet(raw.app_pid, .{
            .before = row.before.windows,
            .opened = row.opened.windows,
            .closed = row.closed.windows,
            .before_counters = row.before.counters,
            .opened_counters = row.opened.counters,
            .closed_counters = row.closed.counters,
        }) catch |err| {
            const changes = counterChanges(row.before.counters, row.opened.counters, row.closed.counters);
            if (changes.pty_input_changed or changes.committed_callbacks_changed or changes.screen_generation_changed) {
                std.debug.print("session_host_ime_candidate_counter_mutation row={d} pty_input_changed={} committed_callbacks_changed={} screen_generation_changed={} pty_open_interval_changed={} pty_close_interval_changed={}\n", .{
                    index,                             changes.pty_input_changed,          changes.committed_callbacks_changed, changes.screen_generation_changed,
                    changes.pty_open_interval_changed, changes.pty_close_interval_changed,
                });
            }
            return err;
        };
        candidates[index] = candidate;
        const before_anchor = try appKitToQuartz(row.before.anchor_appkit, row.before.displays);
        const opened_anchor = try appKitToQuartz(row.opened.anchor_appkit, row.opened.displays);
        const closed_anchor = try appKitToQuartz(row.closed.anchor_appkit, row.closed.displays);
        if (!std.meta.eql(before_anchor, opened_anchor) or !std.meta.eql(before_anchor, closed_anchor))
            return error.AnchorDrift;
        if (series_anchor) |prior| {
            if (!std.meta.eql(prior, before_anchor)) return error.AnchorDrift;
        } else series_anchor = before_anchor;
        rows[index] = .{
            .window_id = candidate.window_id,
            .owner_pid = candidate.owner.pid,
            .bundle_id = candidate.owner.bundle_id,
            .signing_id = candidate.owner.signing_id,
            .apple_signed = candidate.owner.apple_signed,
            .layer = candidate.layer,
            .bounds = candidate.bounds,
            .counters = row.before.counters,
            .display_id = before_anchor.display_id,
            .anchor_quartz = before_anchor.rect,
        };
    }
    _ = try validateSeries(&candidates);

    var output: std.Io.Writer.Allocating = .init(allocator);
    defer output.deinit();
    var json: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
    try json.write(Artifact{ .source_id = raw.source_id, .rows = &rows });
    try output.writer.writeByte('\n');
    if (output.written().len > max_artifact_bytes) return error.ArtifactTooLarge;

    const temporary = try std.fmt.allocPrintSentinel(allocator, "{s}.tmp.{d}", .{ output_path, std.c.getpid() }, 0);
    defer allocator.free(temporary);
    const fd = std.c.open(temporary.ptr, .{
        .ACCMODE = .WRONLY,
        .CREAT = true,
        .EXCL = true,
        .CLOEXEC = true,
        .NOFOLLOW = true,
    }, @as(std.c.mode_t, 0o600));
    if (fd < 0) return error.ArtifactCreateFailed;
    defer _ = std.c.unlink(temporary.ptr);
    var open = true;
    defer if (open) {
        _ = std.c.close(fd);
    };
    var offset: usize = 0;
    while (offset < output.written().len) {
        const amount = std.c.write(fd, output.written()[offset..].ptr, output.written().len - offset);
        if (amount < 0 and std.posix.errno(amount) == .INTR) continue;
        if (amount <= 0) return error.ArtifactWriteFailed;
        offset += @intCast(amount);
    }
    if (std.c.fsync(fd) != 0 or std.c.close(fd) != 0) return error.ArtifactWriteFailed;
    open = false;
    if (std.c.link(temporary.ptr, output_path.ptr) != 0) return error.ArtifactPublishFailed;
}

const apple_owner: OwnerIdentity = .{
    .pid = 42,
    .bundle_id = "com.apple.inputmethod.Korean",
    .signing_id = "com.apple.inputmethod.Korean",
    .apple_signed = true,
};
const stable: Window = .{ .id = 1, .owner = .{ .pid = 7, .bundle_id = "com.apple.WindowServer", .signing_id = "com.apple.WindowServer", .apple_signed = true }, .layer = 0, .bounds = .{ .x = 0, .y = 0, .w = 800, .h = 600 }, .on_screen = true };
const candidate_fixture: Window = .{ .id = 100, .owner = apple_owner, .layer = 101, .bounds = .{ .x = 200, .y = 300, .w = 180, .h = 120 }, .on_screen = true };
const counters: Counters = .{ .pty_input_bytes = 9, .committed_text_callbacks = 2, .base_screen_generation = 4 };

fn validTriplet() Triplet {
    return .{
        .before = &.{stable},
        .opened = &.{ stable, candidate_fixture },
        .closed = &.{stable},
        .before_counters = counters,
        .opened_counters = counters,
        .closed_counters = counters,
    };
}

test "v2b0 reducer accepts one Apple-signed transient window from complete snapshots" {
    const got = try reduceTriplet(999, validTriplet());
    try std.testing.expectEqual(candidate_fixture.id, got.window_id);
    try std.testing.expect(OwnerIdentity.eql(apple_owner, got.owner));
}

test "v2b0 reducer rejects cap plus one and duplicate inventory" {
    var too_many: [max_windows + 1]Window = undefined;
    for (&too_many, 0..) |*window, index| {
        window.* = stable;
        window.id = @intCast(index + 1);
    }
    var triplet = validTriplet();
    triplet.before = &too_many;
    try std.testing.expectError(error.InventoryTooLarge, reduceTriplet(999, triplet));

    triplet = validTriplet();
    triplet.opened = &.{ stable, stable };
    try std.testing.expectError(error.DuplicateWindowId, reduceTriplet(999, triplet));
}

test "v2b0 reducer rejects producer prefilter ambiguity and invalid owner" {
    var sibling = candidate_fixture;
    sibling.id = 101;
    var triplet = validTriplet();
    triplet.opened = &.{ stable, candidate_fixture, sibling };
    try std.testing.expectError(error.CandidateAmbiguous, reduceTriplet(999, triplet));

    var unsigned = candidate_fixture;
    unsigned.owner.apple_signed = false;
    triplet = validTriplet();
    triplet.opened = &.{ stable, unsigned };
    try std.testing.expectError(error.CandidateOwnerInvalid, reduceTriplet(999, triplet));
}

test "v2b0 reducer rejects missing close and screen mutation" {
    var missing = validTriplet();
    missing.opened = &.{stable};
    missing.opened_counters.pty_input_bytes += 1;
    try std.testing.expectError(error.CandidateMissing, reduceTriplet(999, missing));
    var triplet = validTriplet();
    triplet.closed = &.{ stable, candidate_fixture };
    try std.testing.expectError(error.CandidateNotClosed, reduceTriplet(999, triplet));

    triplet = validTriplet();
    triplet.opened_counters.base_screen_generation += 1;
    try std.testing.expectError(error.CounterMutation, reduceTriplet(999, triplet));
    var changes = counterChanges(triplet.before_counters, triplet.opened_counters, triplet.closed_counters);
    try std.testing.expect(changes.screen_generation_changed);
    try std.testing.expect(!changes.pty_input_changed and !changes.committed_callbacks_changed);
    triplet.closed_counters.pty_input_bytes += 1;
    triplet.opened_counters.committed_text_callbacks += 1;
    changes = counterChanges(triplet.before_counters, triplet.opened_counters, triplet.closed_counters);
    try std.testing.expect(changes.pty_input_changed and changes.committed_callbacks_changed and changes.screen_generation_changed);
    triplet = validTriplet();
    changes = counterChanges(triplet.before_counters, triplet.opened_counters, triplet.closed_counters);
    try std.testing.expect(!changes.pty_input_changed and !changes.committed_callbacks_changed and !changes.screen_generation_changed);
    triplet.closed_counters.pty_input_bytes += 1;
    changes = counterChanges(triplet.before_counters, triplet.opened_counters, triplet.closed_counters);
    try std.testing.expect(!changes.pty_open_interval_changed and changes.pty_close_interval_changed);
    triplet.opened_counters.pty_input_bytes = triplet.closed_counters.pty_input_bytes;
    changes = counterChanges(triplet.before_counters, triplet.opened_counters, triplet.closed_counters);
    try std.testing.expect(changes.pty_open_interval_changed and !changes.pty_close_interval_changed);
    triplet.closed_counters.pty_input_bytes += 1;
    changes = counterChanges(triplet.before_counters, triplet.opened_counters, triplet.closed_counters);
    try std.testing.expect(changes.pty_open_interval_changed and changes.pty_close_interval_changed);
}

test "v2b0 reducer rejects invalid app identity residual new windows and id reuse" {
    try std.testing.expectError(error.InvalidAppPid, reduceTriplet(0, validTriplet()));

    var residual = candidate_fixture;
    residual.id = 101;
    var triplet = validTriplet();
    triplet.closed = &.{ stable, residual };
    try std.testing.expectError(error.CandidateNotClosed, reduceTriplet(999, triplet));

    var reused = stable;
    reused.owner.pid += 1;
    triplet = validTriplet();
    triplet.opened = &.{ reused, candidate_fixture };
    try std.testing.expectError(error.CandidateIdentityDrift, reduceTriplet(999, triplet));
}

test "v2b0 series rejects identity geometry and window id replay" {
    var values: [required_observations]Candidate = undefined;
    for (&values, 0..) |*value, index| {
        value.* = .{ .window_id = @intCast(100 + index), .owner = apple_owner, .layer = candidate_fixture.layer, .bounds = candidate_fixture.bounds };
    }
    _ = try validateSeries(&values);

    values[4].owner.pid += 1;
    try std.testing.expectError(error.CandidateIdentityDrift, validateSeries(&values));
    values[4].owner = apple_owner;
    values[4].bounds.x += 1;
    try std.testing.expectError(error.CandidateGeometryDrift, validateSeries(&values));
    values[4].bounds = candidate_fixture.bounds;
    values[4].window_id = values[0].window_id;
    try std.testing.expectError(error.DuplicateWindowId, validateSeries(&values));
    values[4].window_id = 104;
    values[4].owner.apple_signed = false;
    try std.testing.expectError(error.CandidateOwnerInvalid, validateSeries(&values));
}

test "v2b0 coordinate converter handles main and left display point spaces" {
    const displays = [_]DisplayTranscript{
        .{ .id = 1, .appkit_frame = .{ .x = 0, .y = 0, .w = 1440, .h = 900 }, .quartz_bounds = .{ .x = 0, .y = 0, .w = 1440, .h = 900 } },
        .{ .id = 2, .appkit_frame = .{ .x = -1280, .y = 0, .w = 1280, .h = 800 }, .quartz_bounds = .{ .x = -1280, .y = 100, .w = 1280, .h = 800 } },
    };
    const main = try appKitToQuartz(.{ .x = 100, .y = 700, .w = 10, .h = 20 }, &displays);
    try std.testing.expectEqual(@as(u32, 1), main.display_id);
    try std.testing.expectEqual(Rect{ .x = 100, .y = 180, .w = 10, .h = 20 }, main.rect);
    const left = try appKitToQuartz(.{ .x = -1200, .y = 100, .w = 8, .h = 18 }, &displays);
    try std.testing.expectEqual(@as(u32, 2), left.display_id);
    try std.testing.expectEqual(Rect{ .x = -1200, .y = 782, .w = 8, .h = 18 }, left.rect);
}

test "v2b0 coordinate converter handles display above and rejects overlap" {
    const above = DisplayTranscript{ .id = 3, .appkit_frame = .{ .x = 0, .y = 900, .w = 1200, .h = 800 }, .quartz_bounds = .{ .x = 0, .y = -800, .w = 1200, .h = 800 } };
    const got = try appKitToQuartz(.{ .x = 50, .y = 1600, .w = 10, .h = 20 }, &.{above});
    try std.testing.expectEqual(Rect{ .x = 50, .y = -720, .w = 10, .h = 20 }, got.rect);
    try std.testing.expectError(error.InvalidDisplay, appKitToQuartz(.{ .x = 10, .y = 910, .w = 1, .h = 1 }, &.{ above, above }));
    var duplicate_id = above;
    duplicate_id.appkit_frame.x = 2000;
    duplicate_id.quartz_bounds.x = 2000;
    try std.testing.expectError(error.InvalidDisplay, appKitToQuartz(.{ .x = 10, .y = 910, .w = 1, .h = 1 }, &.{ above, duplicate_id }));
    try std.testing.expectError(error.AnchorOutsideDisplay, appKitToQuartz(.{ .x = std.math.floatMax(f64), .y = 0, .w = std.math.floatMax(f64), .h = 1 }, &.{above}));
}

test "v2b0b publisher reduces five complete triplets and refuses overwrite" {
    const testing = std.testing;
    const displays = [_]DisplayTranscript{.{
        .id = 1,
        .appkit_frame = .{ .x = 0, .y = 0, .w = 1440, .h = 900 },
        .quartz_bounds = .{ .x = 0, .y = 0, .w = 1440, .h = 900 },
    }};
    const anchor: Rect = .{ .x = 100, .y = 700, .w = 10, .h = 20 };
    var candidate_windows: [required_observations][2]Window = undefined;
    var raw_rows: [required_observations]RawRow = undefined;
    for (&raw_rows, 0..) |*row, index| {
        candidate_windows[index] = .{ stable, candidate_fixture };
        candidate_windows[index][1].id = @intCast(100 + index);
        row.* = .{
            .before = .{ .windows = &.{stable}, .counters = counters, .anchor_appkit = anchor, .displays = &displays },
            .opened = .{ .windows = &candidate_windows[index], .counters = counters, .anchor_appkit = anchor, .displays = &displays },
            .closed = .{ .windows = &.{stable}, .counters = counters, .anchor_appkit = anchor, .displays = &displays },
        };
    }
    var transcript: std.Io.Writer.Allocating = .init(testing.allocator);
    defer transcript.deinit();
    var json: std.json.Stringify = .{ .writer = &transcript.writer, .options = .{} };
    try json.write(RawTranscript{
        .schema = "maru.session-host-cr6d-ime-candidate-transcript.v1",
        .app_pid = 999,
        .source_id = "com.apple.inputmethod.Korean.2SetKorean",
        .rows = &raw_rows,
    });

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(testing.io, &root_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/observation.json", .{root_buf[0..root_len]});
    const collision_name = try std.fmt.allocPrint(testing.allocator, "collision.json.tmp.{d}", .{std.c.getpid()});
    defer testing.allocator.free(collision_name);
    try tmp.dir.writeFile(testing.io, .{ .sub_path = collision_name, .data = "foreign temporary" });
    var collision_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const collision_path = try std.fmt.bufPrintZ(&collision_path_buf, "{s}/collision.json", .{root_buf[0..root_len]});
    try testing.expectError(error.ArtifactCreateFailed, publishObservation(testing.allocator, transcript.written(), collision_path));
    const preserved = try tmp.dir.readFileAlloc(testing.io, collision_name, testing.allocator, .limited(64));
    defer testing.allocator.free(preserved);
    try testing.expectEqualStrings("foreign temporary", preserved);
    try publishObservation(testing.allocator, transcript.written(), path);
    const artifact = try tmp.dir.readFileAlloc(testing.io, "observation.json", testing.allocator, .limited(max_artifact_bytes));
    defer testing.allocator.free(artifact);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, artifact, "maru.session-host-cr6d-ime-candidate-observation.v1"));
    try testing.expectEqual(required_observations, std.mem.count(u8, artifact, "\"window_id\""));
    try testing.expectError(error.ArtifactPublishFailed, publishObservation(testing.allocator, transcript.written(), path));

    raw_rows[4].opened.anchor_appkit.x += 1;
    var drifted: std.Io.Writer.Allocating = .init(testing.allocator);
    defer drifted.deinit();
    var drifted_json: std.json.Stringify = .{ .writer = &drifted.writer, .options = .{} };
    try drifted_json.write(RawTranscript{
        .schema = "maru.session-host-cr6d-ime-candidate-transcript.v1",
        .app_pid = 999,
        .source_id = "com.apple.inputmethod.Korean.2SetKorean",
        .rows = &raw_rows,
    });
    var drift_path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const drift_path = try std.fmt.bufPrintZ(&drift_path_buf, "{s}/drift.json", .{root_buf[0..root_len]});
    try testing.expectError(error.AnchorDrift, publishObservation(testing.allocator, drifted.written(), drift_path));
}

test "v2b0b publisher rejects unknown schema and transcript cap before publication" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/absent.json", .{root_buf[0..root_len]});
    try std.testing.expectError(
        error.InvalidTranscript,
        publishObservation(std.testing.allocator, "{\"schema\":\"wrong\"}", path),
    );
    const too_large = try std.testing.allocator.alloc(u8, max_transcript_bytes + 1);
    defer std.testing.allocator.free(too_large);
    @memset(too_large, 'x');
    try std.testing.expectError(
        error.InventoryTooLarge,
        publishObservation(std.testing.allocator, too_large, path),
    );
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "absent.json", .{}));
}

test "v2b1 capture selection is reducer-owned and rejects ambiguous inventories" {
    const snapshot = RawSnapshot{
        .windows = &.{stable},
        .counters = counters,
        .anchor_appkit = .{ .x = 245, .y = 700, .w = 10, .h = 20 },
        .displays = &.{.{
            .id = 1,
            .appkit_frame = .{ .x = 0, .y = 0, .w = 1440, .h = 900 },
            .quartz_bounds = .{ .x = 0, .y = 0, .w = 1440, .h = 900 },
        }},
    };
    var opened = snapshot;
    opened.windows = &.{ stable, candidate_fixture };
    var bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer bytes.deinit();
    var json: std.json.Stringify = .{ .writer = &bytes.writer, .options = .{} };
    try json.write(CaptureSelectionTranscript{
        .schema = "maru.session-host-cr6d-ime-candidate-selection.v1",
        .app_pid = 999,
        .before = snapshot,
        .opened = opened,
    });
    const selected = try selectCaptureCandidate(std.testing.allocator, bytes.written());
    try std.testing.expectEqual(candidate_fixture.id, selected.window_id);
    try std.testing.expectEqual(candidate_fixture.owner.pid, selected.owner_pid);

    // A missing OS window is the only observation that may be sampled again. Even when no
    // window has appeared yet, screen/input mutation must not be hidden behind that absence.
    opened.windows = &.{stable};
    bytes.clearRetainingCapacity();
    json = .{ .writer = &bytes.writer, .options = .{} };
    try json.write(CaptureSelectionTranscript{
        .schema = "maru.session-host-cr6d-ime-candidate-selection.v1",
        .app_pid = 999,
        .before = snapshot,
        .opened = opened,
    });
    try std.testing.expectError(error.CandidateMissing, selectCaptureCandidate(std.testing.allocator, bytes.written()));
    opened.counters.pty_input_bytes += 1;
    bytes.clearRetainingCapacity();
    json = .{ .writer = &bytes.writer, .options = .{} };
    try json.write(CaptureSelectionTranscript{
        .schema = "maru.session-host-cr6d-ime-candidate-selection.v1",
        .app_pid = 999,
        .before = snapshot,
        .opened = opened,
    });
    try std.testing.expectError(error.CounterMutation, selectCaptureCandidate(std.testing.allocator, bytes.written()));
    opened.counters = snapshot.counters;

    var sibling = candidate_fixture;
    sibling.id += 1;
    opened.windows = &.{ stable, candidate_fixture, sibling };
    bytes.clearRetainingCapacity();
    json = .{ .writer = &bytes.writer, .options = .{} };
    try json.write(CaptureSelectionTranscript{
        .schema = "maru.session-host-cr6d-ime-candidate-selection.v1",
        .app_pid = 999,
        .before = snapshot,
        .opened = opened,
    });
    try std.testing.expectError(error.CandidateAmbiguous, selectCaptureCandidate(std.testing.allocator, bytes.written()));
}

test "v2b1 pixel publisher binds five-row authority capture and cleanup" {
    const display = [_]DisplayTranscript{
        .{
            .id = 1,
            .appkit_frame = .{ .x = 0, .y = 0, .w = 1440, .h = 900 },
            .quartz_bounds = .{ .x = 0, .y = 0, .w = 1440, .h = 900 },
        },
        .{
            .id = 2,
            .appkit_frame = .{ .x = 0, .y = -900, .w = 1440, .h = 900 },
            .quartz_bounds = .{ .x = 0, .y = 900, .w = 1440, .h = 900 },
        },
    };
    const anchor: Rect = .{ .x = 245, .y = 700, .w = 10, .h = 20 };
    var windows: [required_observations][2]Window = undefined;
    var rows: [required_observations]RawRow = undefined;
    for (&rows, 0..) |*row, index| {
        windows[index] = .{ stable, candidate_fixture };
        windows[index][1].id = @intCast(100 + index);
        row.* = .{
            .before = .{ .windows = &.{stable}, .counters = counters, .anchor_appkit = anchor, .displays = &display },
            .opened = .{ .windows = &windows[index], .counters = counters, .anchor_appkit = anchor, .displays = &display },
            .closed = .{ .windows = &.{stable}, .counters = counters, .anchor_appkit = anchor, .displays = &display },
        };
    }
    var transcript: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer transcript.deinit();
    var transcript_json: std.json.Stringify = .{ .writer = &transcript.writer, .options = .{} };
    try transcript_json.write(RawTranscript{
        .schema = "maru.session-host-cr6d-ime-candidate-transcript.v1",
        .app_pid = 999,
        .source_id = "com.apple.inputmethod.Korean.2SetKorean",
        .rows = &rows,
    });
    const evidence = PixelEvidence{
        .schema = "maru.session-host-cr6d-ime-candidate-pixel-evidence.v1",
        .runtime_id = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
        .surface_id = 7,
        .frame_generation = 9,
        .first_rect = anchor,
        .window_id = candidate_fixture.id,
        .owner_pid = apple_owner.pid,
        .bundle_id = apple_owner.bundle_id,
        .signing_id = apple_owner.signing_id,
        .apple_signed = true,
        .layer = candidate_fixture.layer,
        .bounds = candidate_fixture.bounds,
        .pixel_width = 180,
        .pixel_height = 120,
        .capture_sha256 = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        .capture_complete = true,
        .input_source_restored = true,
        .first_responder_restored = true,
        .restore_record_absent = true,
    };
    var evidence_bytes: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer evidence_bytes.deinit();
    var evidence_json: std.json.Stringify = .{ .writer = &evidence_bytes.writer, .options = .{} };
    try evidence_json.write(evidence);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrintZ(&path_buf, "{s}/pixel.json", .{root_buf[0..root_len]});
    try publishPixelObservation(std.testing.allocator, transcript.written(), evidence_bytes.written(), path);
    const artifact = try tmp.dir.readFileAlloc(std.testing.io, "pixel.json", std.testing.allocator, .limited(max_artifact_bytes));
    defer std.testing.allocator.free(artifact);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, artifact, "maru.session-host-cr6d-ime-candidate-pixel.v1"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, artifact, evidence.capture_sha256));

    // A digest of a real window is insufficient when the caret moved during the five cycles.
    var drifted = anchor;
    drifted.x += 1;
    rows[2].closed.anchor_appkit = drifted;
    transcript.clearRetainingCapacity();
    transcript_json = .{ .writer = &transcript.writer, .options = .{} };
    try transcript_json.write(RawTranscript{
        .schema = "maru.session-host-cr6d-ime-candidate-transcript.v1",
        .app_pid = 999,
        .source_id = "com.apple.inputmethod.Korean.2SetKorean",
        .rows = &rows,
    });
    const drift_path = try std.fmt.bufPrintZ(&path_buf, "{s}/drift.json", .{root_buf[0..root_len]});
    try std.testing.expectError(error.AnchorDrift, publishPixelObservation(
        std.testing.allocator,
        transcript.written(),
        evidence_bytes.written(),
        drift_path,
    ));

    rows[2].closed.anchor_appkit = anchor;
    transcript.clearRetainingCapacity();
    transcript_json = .{ .writer = &transcript.writer, .options = .{} };
    try transcript_json.write(RawTranscript{
        .schema = "maru.session-host-cr6d-ime-candidate-transcript.v1",
        .app_pid = 999,
        .source_id = "com.apple.inputmethod.Korean.2SetKorean",
        .rows = &rows,
    });
    var wrong_rect = evidence;
    wrong_rect.first_rect = drifted;
    evidence_bytes.clearRetainingCapacity();
    evidence_json = .{ .writer = &evidence_bytes.writer, .options = .{} };
    try evidence_json.write(wrong_rect);
    const wrong_rect_path = try std.fmt.bufPrintZ(&path_buf, "{s}/wrong-rect.json", .{root_buf[0..root_len]});
    try std.testing.expectError(error.AnchorDrift, publishPixelObservation(
        std.testing.allocator,
        transcript.written(),
        evidence_bytes.written(),
        wrong_rect_path,
    ));

    // An exact display edge is valid. A vertically stacked monitor has the same x band, but
    // neither a crossing nor a wholly different-display window may borrow caret authority.
    for ([_]struct { y: f64, valid: bool }{
        .{ .y = 780, .valid = true },
        .{ .y = 850, .valid = false },
        .{ .y = 1100, .valid = false },
    }, 0..) |placement, index| {
        for (&windows) |*pair| pair[1].bounds.y = placement.y;
        transcript.clearRetainingCapacity();
        transcript_json = .{ .writer = &transcript.writer, .options = .{} };
        try transcript_json.write(RawTranscript{
            .schema = "maru.session-host-cr6d-ime-candidate-transcript.v1",
            .app_pid = 999,
            .source_id = "com.apple.inputmethod.Korean.2SetKorean",
            .rows = &rows,
        });
        var off_display = evidence;
        off_display.bounds.y = placement.y;
        evidence_bytes.clearRetainingCapacity();
        evidence_json = .{ .writer = &evidence_bytes.writer, .options = .{} };
        try evidence_json.write(off_display);
        const off_display_path = try std.fmt.bufPrintZ(&path_buf, "{s}/off-display-{d}.json", .{ root_buf[0..root_len], index });
        if (placement.valid) {
            try publishPixelObservation(std.testing.allocator, transcript.written(), evidence_bytes.written(), off_display_path);
        } else {
            try std.testing.expectError(error.CandidateGeometryDrift, publishPixelObservation(
                std.testing.allocator,
                transcript.written(),
                evidence_bytes.written(),
                off_display_path,
            ));
        }
    }
}
