//! Owned save image and main-thread completion policy. Native hosts own file
//! identity, path grants, I/O and the proof of commit; L2 owns document CAS.
const std = @import("std");
const registry_mod = @import("document_registry.zig");
const state_mod = @import("document_state.zig");

pub const Result = enum { committed, aborted, uncertain };
/// Borrowed immutable transport for native I/O. The owner keeps Request alive
/// until the worker returns. A lease is compared as a token, never dereferenced
/// here; exporting an image does not authorize a later native commit.
pub const Image = struct {
    lease: registry_mod.Lease,
    epoch: u64,
    sequence: u64,
    bytes: []const u8,
    disk_hash: u64,
    expected_source_hash: u64,

    pub fn validate(self: Image, source_hash: u64) !void {
        if (self.expected_source_hash != source_hash) return error.DiskFingerprintChanged;
        if (state_mod.contentHash(self.bytes) != self.disk_hash) return error.CorruptSaveImage;
    }

    pub fn sameRequest(self: Image, other: Image) bool {
        return std.meta.eql(self.lease, other.lease) and self.epoch == other.epoch and
            self.sequence == other.sequence and self.disk_hash == other.disk_hash;
    }
};

/// A main-thread vote for one final-address native job. The host supplies a
/// non-reused scope and keeps Request plus lifetime/path/permission ownership
/// pinned until the native decision. This transport never queries Registry,
/// carries no borrowed bytes, and does not authorize the generic native API.
pub const CommitApproval = struct {
    owner: ?*CommitApproval = null,
    scope: u64 = 0,
    binding: ?Image = null,
    consumed: bool = false,

    pub fn consume(self: *CommitApproval, scope: u64, image: Image) !void {
        const owner = self.owner orelse return error.ApprovalNotIssued;
        if (owner != self) return error.CopiedCommitApproval;
        if (self.consumed) return error.ApprovalConsumed;
        if (scope == 0 or scope != self.scope) return error.WrongApprovalScope;
        const binding = self.binding orelse return error.ApprovalNotIssued;
        if (!binding.sameRequest(image) or binding.expected_source_hash != image.expected_source_hash) return error.WrongApprovedRequest;
        self.consumed = true;
    }
};
pub const Request = struct {
    allocator: std.mem.Allocator,
    registry: *registry_mod.Registry,
    lease: registry_mod.Lease,
    path: []const u8,
    bytes: []const u8,
    revision: u64,
    body_hash: u64,
    disk_hash: u64,
    expected_disk_hash: u64,
    // Explicit overwrite observes a newer native source without rebasing the
    // document's saved state. Completion still CASes expected_disk_hash.
    overwrite_disk_hash: ?u64 = null,
    epoch: u64,
    sequence: u64,
    acknowledged: bool = false,
    aborted: bool = false,

    /// Host must obtain the observed fingerprint from a fresh, identity-checked
    /// read at the explicit overwrite choice. It remains a native CAS operand,
    /// not permission to bypass identity, path or document lifetime checks.
    pub fn beginOverwrite(allocator: std.mem.Allocator, registry: *registry_mod.Registry, source: registry_mod.Lease, limit_bytes: usize, observed_hash: u64) !Request {
        var request = try begin(allocator, registry, source, limit_bytes);
        request.overwrite_disk_hash = observed_hash;
        return request;
    }

    pub fn expectedSourceHash(self: *const Request) u64 {
        return self.overwrite_disk_hash orelse self.expected_disk_hash;
    }

    /// Pure projection, also usable when checking a completed native outcome.
    /// Main-thread validation is separate because completion may follow a
    /// permission change and must still reconcile the actual native decision.
    pub fn image(self: *const Request) Image {
        return .{ .lease = self.lease, .epoch = self.epoch, .sequence = self.sequence, .bytes = self.bytes, .disk_hash = self.disk_hash, .expected_source_hash = self.expectedSourceHash() };
    }

    pub fn imageForWrite(self: *const Request) !Image {
        try self.validateForWrite();
        return self.image();
    }

    /// Issue at the final main-thread vote, after native binding is fenced.
    /// Failure leaves destination untouched. The native adapter still validates
    /// its own image and root/file identity before consuming this one-use vote.
    pub fn approveCommit(self: *const Request, scope: u64, native_source_hash: u64, destination: *CommitApproval) !void {
        if (destination.owner != null) return error.ApprovalAlreadyIssued;
        if (scope == 0) return error.InvalidApprovalScope;
        const exported = try self.imageForWrite();
        try exported.validate(native_source_hash);
        var binding = exported;
        binding.bytes = &.{};
        destination.* = .{ .owner = destination, .scope = scope, .binding = binding };
    }

    /// A request lease pins the same document even after its last view closes.
    /// The image owns BOM/line-ending-preserving bytes, never a mutable view slice.
    pub fn begin(allocator: std.mem.Allocator, registry: *registry_mod.Registry, source: registry_mod.Lease, limit_bytes: usize) !Request {
        const state = registry.get(source) orelse return error.StaleDocument;
        if (state.remote != null) return error.RemoteDocument;
        const path = state.path orelse return error.NoPath;
        const opened = state.opened orelse return error.NoDocument;
        if (opened.file.read_only) return error.ReadOnly;
        const expected = opened.disk_hash orelse return error.NoDiskFingerprint;
        if (state.persistence.uncertain_sequence != null) return error.SaveUncertain;
        const image_len = std.math.add(usize, opened.file.content.len, if (opened.file.format.has_bom) 3 else 0) catch return error.FileTooLarge;
        if (image_len > limit_bytes) return error.FileTooLarge;
        if (state.persistence.epoch == std.math.maxInt(u64) or state.persistence.issued == std.math.maxInt(u64) or state.persistence.live_save_images == std.math.maxInt(u64)) return error.SaveClockExhausted;
        const owned_path = try allocator.dupe(u8, path);
        errdefer allocator.free(owned_path);
        const bytes = try opened.file.saveBytes(allocator);
        errdefer allocator.free(bytes);
        const lease = try registry.retain(source, .request);
        // All fallible preparation is complete. Failed allocation cannot issue
        // a save sequence or leave a hidden reference holding the document alive.
        state.persistence.issued += 1;
        state.persistence.live_save_images += 1;
        return .{
            .allocator = allocator,
            .registry = registry,
            .lease = lease,
            .path = owned_path,
            .bytes = bytes,
            .revision = opened.file.revision,
            .body_hash = state_mod.contentHash(opened.file.content),
            .disk_hash = state_mod.contentHash(bytes),
            .expected_disk_hash = expected,
            .epoch = state.persistence.epoch,
            .sequence = state.persistence.issued,
        };
    }

    /// Host calls this only after its native commit decision. Uncertain/aborted
    /// outcomes preserve every save axis; uncertainty may be reconciled later.
    pub fn complete(self: *Request, result: Result) !void {
        if (self.acknowledged) return error.AlreadyAcknowledged;
        if (self.aborted) return error.SaveAborted;
        if (result == .aborted) {
            self.aborted = true;
            self.clearOwnedUncertainty();
            return error.SaveNotCommitted;
        }
        // A known native decision ends its own uncertainty even when a newer
        // path/disk observation refuses the ack. Dirty/save axes stay intact.
        if (result == .committed) self.clearOwnedUncertainty();
        const state = try self.lifetime();
        if (state.persistence.uncertain_sequence) |sequence| {
            if (sequence != self.sequence) return error.SaveUncertain;
        }
        if (result == .uncertain) {
            if (self.sequence <= state.persistence.acknowledged) return error.StaleSave;
            state.persistence.uncertain_sequence = self.sequence;
            return error.SaveNotCommitted;
        }
        const opened = try self.target();
        // saved_hash is the captured body, not today's body. A later edit remains
        // dirty, while undo back to the actual persisted content becomes clean.
        opened.saved_hash = self.body_hash;
        opened.disk_hash = self.disk_hash;
        state.persistence.persisted_revision = self.revision;
        state.persistence.acknowledged = self.sequence;
        state.persistence.uncertain_sequence = null;
        self.acknowledged = true;
    }

    /// Revalidate on the main thread immediately before native writing or commit. Completion
    /// checks the same target again, but cannot undo an already committed wrong write.
    pub fn validateForWrite(self: *const Request) !void {
        if (self.acknowledged) return error.AlreadyAcknowledged;
        if (self.aborted) return error.SaveAborted;
        const opened = try self.target();
        if (self.registry.get(self.lease).?.persistence.uncertain_sequence != null) return error.SaveUncertain;
        if (opened.file.read_only) return error.ReadOnly;
    }

    fn target(self: *const Request) !*state_mod.Opened {
        const state = try self.lifetime();
        const opened = &state.opened.?;
        if (self.sequence <= state.persistence.acknowledged) return error.StaleSave;
        if (opened.disk_hash != self.expected_disk_hash) return error.DiskFingerprintChanged;
        if (opened.file.revision < self.revision) return error.StaleDocument;
        return opened;
    }

    fn lifetime(self: *const Request) !*state_mod.State {
        const state = self.registry.get(self.lease) orelse return error.StaleDocument;
        if (state.persistence.epoch != self.epoch) return error.StaleDocument;
        const path = state.path orelse return error.StaleDocument;
        if (state.remote != null or !std.mem.eql(u8, path, self.path)) return error.StaleDocument;
        if (state.opened == null) return error.StaleDocument;
        return state;
    }

    fn clearOwnedUncertainty(self: *const Request) void {
        if (self.registry.get(self.lease)) |state| {
            if (state.persistence.epoch == self.epoch and state.persistence.uncertain_sequence == self.sequence)
                state.persistence.uncertain_sequence = null;
        }
    }

    pub fn deinit(self: *Request) void {
        // Reload creates a new lifetime. An old image cannot release a newer
        // lifetime's protection, even though its registry slot is still alive.
        if (self.registry.get(self.lease)) |state| {
            if (state.persistence.epoch == self.epoch) {
                std.debug.assert(state.persistence.live_save_images > 0);
                state.persistence.live_save_images -= 1;
            }
        }
        self.allocator.free(self.path);
        self.allocator.free(self.bytes);
        _ = self.registry.release(self.lease) catch @panic("save request lease lost");
        self.* = undefined;
    }
};

const a = std.testing.allocator;

test "Editor save request commit approval rejects revoked permission without publishing a vote" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    var request = try Request.begin(a, &registry, lease, 128);
    defer request.deinit();
    var approval: CommitApproval = .{};
    registry.get(lease).?.opened.?.file.read_only = true;
    try std.testing.expectError(error.ReadOnly, request.approveCommit(7, request.expectedSourceHash(), &approval));
    try std.testing.expect(approval.owner == null and approval.binding == null);
    registry.get(lease).?.opened.?.file.read_only = false;
    try std.testing.expectError(error.InvalidApprovalScope, request.approveCommit(0, request.expectedSourceHash(), &approval));
    try request.approveCommit(7, request.expectedSourceHash(), &approval);
    try std.testing.expectEqual(@as(usize, 0), approval.binding.?.bytes.len);
    try std.testing.expectError(error.ApprovalAlreadyIssued, request.approveCommit(8, request.expectedSourceHash(), &approval));
    try std.testing.expectEqual(@as(u64, 1), registry.get(lease).?.persistence.live_save_images);
    try std.testing.expectEqual(@as(u64, 0), registry.get(lease).?.persistence.acknowledged);
}

test "Editor save request commit approval is final address scoped and consumed once" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    var request = try Request.begin(a, &registry, lease, 128);
    defer request.deinit();
    var approval: CommitApproval = .{};
    try std.testing.expectError(error.ApprovalNotIssued, approval.consume(11, request.image()));
    try request.approveCommit(11, request.expectedSourceHash(), &approval);
    var copied = approval;
    try std.testing.expectError(error.CopiedCommitApproval, copied.consume(11, request.image()));
    try std.testing.expectError(error.WrongApprovalScope, approval.consume(12, request.image()));
    try std.testing.expect(!approval.consumed);
    try approval.consume(11, request.image());
    try std.testing.expectError(error.ApprovalConsumed, approval.consume(11, request.image()));
}

test "Editor save request commit approval binds full lifetime request and native source" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    var request = try Request.beginOverwrite(a, &registry, lease, 128, state_mod.contentHash("outside"));
    defer request.deinit();
    var approval: CommitApproval = .{};
    try request.approveCommit(19, request.expectedSourceHash(), &approval);
    const image = request.image();
    var foreign: registry_mod.Registry = .{ .allocator = a };
    for (0..8) |index| {
        var other = image;
        switch (index) {
            0 => other.epoch ^= 1,
            1 => other.sequence ^= 1,
            2 => other.disk_hash ^= 1,
            3 => other.lease.document.generation ^= 1,
            4 => other.lease.kind = .read,
            5 => other.lease.owner = &foreign,
            6 => other.lease.id ^= 1,
            7 => other.expected_source_hash ^= 1,
            else => unreachable,
        }
        try std.testing.expectError(error.WrongApprovedRequest, approval.consume(19, other));
        try std.testing.expect(!approval.consumed);
    }
    try approval.consume(19, image);
}

test "Editor save request commit approval validates source checksum and changed target before issuing" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    var request = try Request.begin(a, &registry, lease, 128);
    defer request.deinit();
    const state = registry.get(lease).?;
    var approval: CommitApproval = .{};
    try std.testing.expectError(error.DiskFingerprintChanged, request.approveCommit(23, request.expectedSourceHash() ^ 1, &approval));
    const bytes = @constCast(request.bytes);
    const original = bytes[0];
    bytes[0] ^= 1;
    try std.testing.expectError(error.CorruptSaveImage, request.approveCommit(23, request.expectedSourceHash(), &approval));
    bytes[0] = original;
    state.persistence.epoch += 1;
    try std.testing.expectError(error.StaleDocument, request.approveCommit(23, request.expectedSourceHash(), &approval));
    state.persistence.epoch -= 1;
    state.persistence.uncertain_sequence = request.sequence;
    try std.testing.expectError(error.SaveUncertain, request.approveCommit(23, request.expectedSourceHash(), &approval));
    state.persistence.uncertain_sequence = null;
    try std.testing.expect(approval.owner == null and approval.binding == null);
    try request.approveCommit(23, request.expectedSourceHash(), &approval);
}

test "Editor save request commit approval transport retains no borrowed byte image" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    var request = try Request.begin(a, &registry, lease, 128);
    var request_owned = true;
    defer if (request_owned) request.deinit();
    var native_image = request.image();
    const bytes = try a.dupe(u8, native_image.bytes);
    defer a.free(bytes);
    native_image.bytes = bytes;
    var approval: CommitApproval = .{};
    try request.approveCommit(29, request.expectedSourceHash(), &approval);
    try std.testing.expectEqual(@as(usize, 0), approval.binding.?.bytes.len);
    request.deinit();
    request_owned = false;
    // Metadata consumption does not inspect the released Request/Registry.
    // No native commit is attempted: hosts must retain their live authority.
    try approval.consume(29, native_image);
    try std.testing.expectEqual(@as(u64, 0), registry.get(lease).?.persistence.acknowledged);
}

test "Editor save request image transport validates bytes and native source without registry access" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    var request = try Request.beginOverwrite(a, &registry, lease, 128, state_mod.contentHash("outside"));
    defer request.deinit();
    const image = try request.imageForWrite();
    try image.validate(state_mod.contentHash("outside"));
    try std.testing.expectError(error.DiskFingerprintChanged, image.validate(state_mod.contentHash("base")));
    var corrupted = image;
    corrupted.disk_hash ^= 1;
    try std.testing.expectError(error.CorruptSaveImage, corrupted.validate(image.expected_source_hash));
    // The exported transport keeps its captured values when the live document
    // changes. Validation of live authority stays explicitly on the main thread.
    registry.get(lease).?.opened.?.file.read_only = true;
    try std.testing.expectError(error.ReadOnly, request.imageForWrite());
    try image.validate(image.expected_source_hash);
    try std.testing.expect(image.sameRequest(request.image()));
}

test "Editor save request image transport binds full lease lifetime sequence and checksum" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    var request = try Request.begin(a, &registry, lease, 128);
    defer request.deinit();
    const image = try request.imageForWrite();
    try std.testing.expect(image.sameRequest(image));
    var other = image;
    other.epoch ^= 1;
    try std.testing.expect(!image.sameRequest(other));
    other = image;
    other.sequence ^= 1;
    try std.testing.expect(!image.sameRequest(other));
    other = image;
    other.disk_hash ^= 1;
    try std.testing.expect(!image.sameRequest(other));
    other = image;
    other.lease.id ^= 1;
    try std.testing.expect(!image.sameRequest(other));
    other = image;
    other.lease.document.generation ^= 1;
    try std.testing.expect(!image.sameRequest(other));
    other = image;
    other.lease.kind = .read;
    try std.testing.expect(!image.sameRequest(other));
    var foreign: registry_mod.Registry = .{ .allocator = a };
    other = image;
    other.lease.owner = &foreign;
    try std.testing.expect(!image.sameRequest(other));
}
test "Editor save request keeps each overlapping image owned through terminal acknowledgment" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    var first = try Request.begin(a, &registry, lease, 128);
    var first_owned = true;
    defer if (first_owned) first.deinit();
    var second = try Request.begin(a, &registry, lease, 128);
    var second_owned = true;
    defer if (second_owned) second.deinit();
    try std.testing.expectEqual(@as(u64, 2), state.persistence.live_save_images);
    try second.complete(.committed);
    try std.testing.expectEqual(@as(u64, 2), state.persistence.live_save_images);
    second.deinit();
    second_owned = false;
    try std.testing.expectEqual(@as(u64, 1), state.persistence.live_save_images);
    try std.testing.expectError(error.StaleSave, first.complete(.committed));
    first.deinit();
    first_owned = false;
    try std.testing.expectEqual(@as(u64, 0), state.persistence.live_save_images);
}

test "Editor save request old lifetime image cannot release replacement lifetime protection" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    var old = try Request.begin(a, &registry, lease, 128);
    var old_owned = true;
    defer if (old_owned) old.deinit();
    state.clearOpened(a);
    try std.testing.expectEqual(@as(u64, 0), state.persistence.live_save_images);
    const file = try @import("edit_doc.zig").EditableFile.init(a, "new", false);
    state.opened = .{ .file = file, .saved_hash = state_mod.contentHash(file.content), .disk_hash = state_mod.contentHash("new") };
    var current = try Request.begin(a, &registry, lease, 128);
    var current_owned = true;
    defer if (current_owned) current.deinit();
    old.deinit();
    old_owned = false;
    try std.testing.expectEqual(@as(u64, 1), state.persistence.live_save_images);
    current.deinit();
    current_owned = false;
    try std.testing.expectEqual(@as(u64, 0), state.persistence.live_save_images);
}

test "Editor save request refuses image counter exhaustion without issuing authority" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    state.persistence.live_save_images = std.math.maxInt(u64);
    try expectBeginError(error.SaveClockExhausted, &registry, lease, 128);
    try std.testing.expectEqual(@as(u64, 0), state.persistence.issued);
    try std.testing.expectEqual(std.math.maxInt(u64), state.persistence.live_save_images);
}

fn create(registry: *registry_mod.Registry, bytes: []const u8) !registry_mod.Lease {
    var state: state_mod.State = .{};
    defer state.clear(a);
    const file = try @import("edit_doc.zig").EditableFile.init(a, bytes, false);
    state.opened = .{ .file = file, .saved_hash = state_mod.contentHash(file.content), .disk_hash = state_mod.contentHash(bytes) };
    state.path = try a.dupe(u8, "document.txt");
    return registry.create(&state, a);
}
fn expectBeginError(expected: anyerror, registry: *registry_mod.Registry, lease: registry_mod.Lease, limit: usize) !void {
    if (Request.begin(a, registry, lease, limit)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqual(expected, err);
}
fn edit(state: *state_mod.State, bytes: []const u8) !void {
    var selections: @import("selection.zig").Selections = .{ .items = &.{}, .primary = 0 };
    const changes = [_]@import("delta.zig").Change{.{ .start = 0, .end = state.opened.?.file.content.len, .text = bytes }};
    var inverse = try state.opened.?.file.apply(.{ .changes = &changes }, &selections);
    inverse.deinit();
}

test "Editor save request explicit overwrite observes native source without rebasing saved state" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    try edit(state, "mine");
    const observed = state_mod.contentHash("outside");
    var request = try Request.beginOverwrite(a, &registry, lease, 128, observed);
    defer request.deinit();
    try std.testing.expectEqual(observed, request.expectedSourceHash());
    try std.testing.expectEqual(state_mod.contentHash("base"), request.expected_disk_hash);
    try std.testing.expectEqual(@as(?u64, state_mod.contentHash("base")), state.opened.?.disk_hash);
    try std.testing.expectEqual(state_mod.contentHash("base"), state.opened.?.saved_hash);
    try request.validateForWrite();
    try edit(state, "later");
    try request.complete(.committed);
    try std.testing.expectEqualStrings("later", state.opened.?.file.content);
    try std.testing.expectEqual(state_mod.contentHash("mine"), state.opened.?.saved_hash);
    try std.testing.expectEqual(@as(?u64, state_mod.contentHash("mine")), state.opened.?.disk_hash);
    try std.testing.expect(state.opened.?.isDirty());
}

test "Editor save request explicit overwrite preserves CAS and aborted saved axes" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    try edit(state, "mine");
    var request = try Request.beginOverwrite(a, &registry, lease, 128, state_mod.contentHash("outside"));
    defer request.deinit();
    state.opened.?.disk_hash = state_mod.contentHash("new observation");
    try std.testing.expectError(error.DiskFingerprintChanged, request.validateForWrite());
    state.opened.?.disk_hash = request.expected_disk_hash;
    try std.testing.expectError(error.SaveNotCommitted, request.complete(.aborted));
    try std.testing.expectEqual(state_mod.contentHash("base"), state.opened.?.saved_hash);
    try std.testing.expectEqual(@as(?u64, state_mod.contentHash("base")), state.opened.?.disk_hash);
    try std.testing.expect(state.opened.?.isDirty());
}

test "Editor save request keeps later edits dirty and distinguishes raw BOM bytes" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "\xef\xbb\xbforiginal\r\n");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    try edit(state, "first\r\n");
    var request = try Request.begin(a, &registry, lease, 128);
    defer request.deinit();
    try edit(state, "later\n");
    try std.testing.expectEqualStrings("\xef\xbb\xbffirst\r\n", request.bytes);
    try request.complete(.committed);
    try std.testing.expect(state.opened.?.isDirty());
    try std.testing.expectEqual(@as(?u64, 1), state.persistence.persisted_revision);
    try std.testing.expectEqual(state_mod.contentHash("first\r\n"), state.opened.?.saved_hash);
    try std.testing.expectEqual(@as(?u64, state_mod.contentHash("\xef\xbb\xbffirst\r\n")), state.opened.?.disk_hash);
    try edit(state, "first\r\n");
    try std.testing.expect(!state.opened.?.isDirty());
    try std.testing.expectError(error.AlreadyAcknowledged, request.complete(.committed));
}

test "Editor save request refuses uncertain and aborted outcomes without changing axes" {
    for ([_]Result{ .uncertain, .aborted }) |result| {
        var registry: registry_mod.Registry = .{ .allocator = a };
        defer registry.deinit() catch unreachable;
        const lease = try create(&registry, "base");
        defer _ = registry.release(lease) catch unreachable;
        const state = registry.get(lease).?;
        try edit(state, "mine");
        var request = try Request.begin(a, &registry, lease, 128);
        defer request.deinit();
        try std.testing.expectError(error.SaveNotCommitted, request.complete(result));
        try std.testing.expect(state.opened.?.isDirty());
        try std.testing.expect(state.persistence.persisted_revision == null);
        try std.testing.expectEqual(@as(u64, 0), state.persistence.acknowledged);
        try std.testing.expectEqual(state_mod.contentHash("base"), state.opened.?.saved_hash);
        try std.testing.expectEqual(@as(?u64, state_mod.contentHash("base")), state.opened.?.disk_hash);
        if (result == .uncertain) {
            try request.complete(.committed);
            try std.testing.expect(!state.opened.?.isDirty());
        } else {
            try std.testing.expectError(error.SaveAborted, request.complete(.committed));
            try std.testing.expect(state.opened.?.isDirty());
        }
    }
}

test "Editor save request rejects an old callback even when both saved images match" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "same");
    defer _ = registry.release(lease) catch unreachable;
    var first = try Request.begin(a, &registry, lease, 128);
    defer first.deinit();
    var second = try Request.begin(a, &registry, lease, 128);
    defer second.deinit();
    try second.complete(.committed);
    try std.testing.expectError(error.StaleSave, first.complete(.committed));
    try std.testing.expectEqual(second.sequence, registry.get(lease).?.persistence.acknowledged);
}

test "Editor save request refuses changed disk fingerprint and renamed document" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    var request = try Request.begin(a, &registry, lease, 128);
    defer request.deinit();
    state.opened.?.disk_hash = state_mod.contentHash("outside");
    try std.testing.expectError(error.DiskFingerprintChanged, request.complete(.committed));
    try std.testing.expectEqual(state_mod.contentHash("base"), state.opened.?.saved_hash);
    state.opened.?.disk_hash = request.expected_disk_hash;
    state.path.?[0] = 'x';
    try std.testing.expectError(error.StaleDocument, request.complete(.committed));
    try std.testing.expectEqualStrings("document.txt", request.path);
}

test "Editor save request rejects a replaced opened lifetime with the same path and bytes" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "same");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    var request = try Request.begin(a, &registry, lease, 128);
    defer request.deinit();
    state.clearOpened(a);
    state.opened = .{ .file = try @import("edit_doc.zig").EditableFile.init(a, "same", false), .saved_hash = state_mod.contentHash("same"), .disk_hash = state_mod.contentHash("same") };
    try std.testing.expectError(error.StaleDocument, request.complete(.committed));
    try std.testing.expect(state.persistence.persisted_revision == null);
}

test "Editor save request retains a document after its last view closes" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    var request = try Request.begin(a, &registry, lease, 128);
    try std.testing.expect(!try registry.release(lease));
    try std.testing.expectEqual(@as(?usize, 0), registry.viewCount(request.lease));
    try request.complete(.committed);
    request.deinit();
    try std.testing.expect(registry.get(lease) == null);
}

fn allocationFailures(allocator: std.mem.Allocator) !void {
    var registry: registry_mod.Registry = .{ .allocator = allocator };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    var request = Request.begin(allocator, &registry, lease, 128) catch |err| {
        try std.testing.expectEqual(@as(u64, 0), registry.get(lease).?.persistence.issued);
        try std.testing.expectEqual(@as(u64, 0), registry.get(lease).?.persistence.live_save_images);
        return err;
    };
    defer request.deinit();
    try request.complete(.committed);
}
test "Editor save request unwinds every failed allocation without issuing authority" {
    try std.testing.checkAllAllocationFailures(a, allocationFailures, .{});
}

test "Editor save request refuses readonly remote missing fingerprints and exhausted clocks" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    try expectBeginError(error.FileTooLarge, &registry, lease, 3);
    try std.testing.expectEqual(@as(u64, 0), state.persistence.issued);
    state.opened.?.file.read_only = true;
    try expectBeginError(error.ReadOnly, &registry, lease, 128);
    state.opened.?.file.read_only = false;
    state.opened.?.disk_hash = null;
    try expectBeginError(error.NoDiskFingerprint, &registry, lease, 128);
    state.opened.?.disk_hash = state_mod.contentHash("base");
    state.persistence.issued = std.math.maxInt(u64);
    try expectBeginError(error.SaveClockExhausted, &registry, lease, 128);
    state.persistence.issued = 0;
    state.persistence.epoch = std.math.maxInt(u64);
    try expectBeginError(error.SaveClockExhausted, &registry, lease, 128);
    state.persistence.epoch = 0;
    state.remote = .{ .dest = try a.dupe(u8, "host"), .path = try a.dupe(u8, "/remote/file") };
    try expectBeginError(error.RemoteDocument, &registry, lease, 128);
}

test "Editor save request revalidates authority before writing and never revives a terminal request" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    var request = try Request.begin(a, &registry, lease, 128);
    defer request.deinit();
    try request.validateForWrite();
    state.opened.?.file.read_only = true;
    try std.testing.expectError(error.ReadOnly, request.validateForWrite());
    state.opened.?.file.read_only = false;
    state.opened.?.disk_hash = state_mod.contentHash("changed");
    try std.testing.expectError(error.DiskFingerprintChanged, request.validateForWrite());
    state.opened.?.disk_hash = request.expected_disk_hash;
    try std.testing.expectError(error.SaveNotCommitted, request.complete(.aborted));
    try std.testing.expectError(error.SaveAborted, request.validateForWrite());
    var next = try Request.begin(a, &registry, lease, 128);
    defer next.deinit();
    try next.complete(.committed);
    try std.testing.expectError(error.AlreadyAcknowledged, next.validateForWrite());
}

test "Editor save request uncertainty blocks new and pending writes until its own outcome resolves" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "same");
    defer _ = registry.release(lease) catch unreachable;
    var first = try Request.begin(a, &registry, lease, 128);
    defer first.deinit();
    var pending = try Request.begin(a, &registry, lease, 128);
    defer pending.deinit();
    try std.testing.expectError(error.SaveNotCommitted, first.complete(.uncertain));
    try expectBeginError(error.SaveUncertain, &registry, lease, 128);
    try std.testing.expectError(error.SaveUncertain, first.validateForWrite());
    try std.testing.expectError(error.SaveUncertain, pending.validateForWrite());
    try std.testing.expectError(error.SaveUncertain, pending.complete(.committed));
    try std.testing.expectEqual(@as(?u64, first.sequence), registry.get(lease).?.persistence.uncertain_sequence);
    try std.testing.expectError(error.SaveNotCommitted, first.complete(.aborted));
    try pending.validateForWrite();
    var next = try Request.begin(a, &registry, lease, 128);
    defer next.deinit();
    try next.complete(.committed);
    try std.testing.expect(registry.get(lease).?.persistence.uncertain_sequence == null);
    var abandoned = try Request.begin(a, &registry, lease, 128);
    try std.testing.expectError(error.SaveNotCommitted, abandoned.complete(.uncertain));
    abandoned.deinit();
    // Dropping an unconfirmed request is not native rollback proof.
    try expectBeginError(error.SaveUncertain, &registry, lease, 128);
}

test "Editor save request known outcome releases its uncertainty when newer disk CAS refuses ack" {
    var registry: registry_mod.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    const lease = try create(&registry, "base");
    defer _ = registry.release(lease) catch unreachable;
    const state = registry.get(lease).?;
    try edit(state, "mine");
    var request = try Request.begin(a, &registry, lease, 128);
    defer request.deinit();
    state.opened.?.disk_hash = state_mod.contentHash("outside");
    try std.testing.expectError(error.SaveNotCommitted, request.complete(.uncertain));
    try expectBeginError(error.SaveUncertain, &registry, lease, 128);
    try std.testing.expectError(error.DiskFingerprintChanged, request.complete(.committed));
    try std.testing.expect(state.persistence.uncertain_sequence == null);
    try std.testing.expect(state.persistence.persisted_revision == null);
    try std.testing.expect(state.opened.?.isDirty());
    try std.testing.expectEqual(state_mod.contentHash("base"), state.opened.?.saved_hash);
    try std.testing.expectEqual(@as(?u64, state_mod.contentHash("outside")), state.opened.?.disk_hash);
    var next = try Request.begin(a, &registry, lease, 128);
    defer next.deinit();
    try std.testing.expectError(error.SaveNotCommitted, next.complete(.uncertain));
    state.path.?[0] = 'x';
    try std.testing.expectError(error.StaleDocument, next.complete(.committed));
    try std.testing.expect(state.persistence.uncertain_sequence == null);
}
