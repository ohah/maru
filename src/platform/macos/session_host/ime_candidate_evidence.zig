//! CR6d-v2b Apple Korean IME candidate-window evidence reducer.
//!
//! The WindowServer producer must submit complete bounded snapshots.  Selection lives here so
//! the product producer and the artifact verifier cannot quietly use different heuristics.

const std = @import("std");

pub const max_windows: usize = 256;
pub const required_observations: usize = 5;
pub const max_transcript_bytes: usize = 1024 * 1024;
pub const max_artifact_bytes: usize = 16 * 1024;

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
    if (!Counters.eql(triplet.before_counters, triplet.opened_counters) or
        !Counters.eql(triplet.before_counters, triplet.closed_counters)) return error.CounterMutation;

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
        const candidate = try reduceTriplet(raw.app_pid, .{
            .before = row.before.windows,
            .opened = row.opened.windows,
            .closed = row.closed.windows,
            .before_counters = row.before.counters,
            .opened_counters = row.opened.counters,
            .closed_counters = row.closed.counters,
        });
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
    var triplet = validTriplet();
    triplet.closed = &.{ stable, candidate_fixture };
    try std.testing.expectError(error.CandidateNotClosed, reduceTriplet(999, triplet));

    triplet = validTriplet();
    triplet.opened_counters.base_screen_generation += 1;
    try std.testing.expectError(error.CounterMutation, reduceTriplet(999, triplet));
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
