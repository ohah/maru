//! Bounded annotated-tag chain resolver for release provenance.
//!
//! The caller supplies the visited-object backing, so this component enforces that bound without
//! inventing the product's maximum traversal depth. Parsed REST responses remain a separate leaf;
//! this owner only proves cycle-free convergence on the manifest's exact source commit.

const std = @import("std");
const git = @import("release_adapter_github_git");
const identity = @import("release_adapter_identity");

pub const Sha = [40]u8;

pub const Error = error{
    InvalidPolicy,
    InvalidOwner,
    BackingInUse,
    InvalidState,
    IdentityMismatch,
    Cycle,
    DepthExceeded,
    Terminal,
};

pub const Backing = struct {
    owner_addr: usize,
    resolver_addr: usize,
    rows: []Sha,

    /// Binds caller-sized storage to this final Backing address before a Resolver may borrow it.
    pub fn init(self: *Backing, rows: []Sha) Error!void {
        if (rows.len != 0 and rangesOverlap(Backing, self, Sha, rows))
            return error.InvalidPolicy;
        self.* = .{
            .owner_addr = @intFromPtr(self),
            .resolver_addr = 0,
            .rows = rows,
        };
    }

    fn bind(self: *Backing, resolver_addr: usize) Error!void {
        try self.requireOwner();
        if (self.resolver_addr != 0) return error.BackingInUse;
        self.resolver_addr = resolver_addr;
    }

    fn requireBound(self: *const Backing, resolver_addr: usize) Error!void {
        try self.requireOwner();
        if (self.resolver_addr != resolver_addr) return error.InvalidOwner;
    }

    fn requireOwner(self: *const Backing) Error!void {
        if (self.owner_addr != @intFromPtr(self)) return error.InvalidOwner;
    }
};

const Phase = enum {
    awaiting_ref,
    awaiting_tag,
    complete,
    failed,
};

pub const NextTag = struct {
    object_sha: Sha,

    pub fn objectSha(self: *const NextTag) []const u8 {
        return &self.object_sha;
    }
};

pub const Result = struct {
    commit_sha: Sha,

    pub fn commitSha(self: *const Result) []const u8 {
        return &self.commit_sha;
    }
};

pub const Resolver = struct {
    owner_addr: usize,
    expected_commit: Sha,
    backing: *Backing,
    backing_rows_addr: usize,
    backing_rows_len: usize,
    visited_count: usize,
    current_tag: Sha,
    phase: Phase,

    /// Initializes at the final address. The backing length is the caller-owned depth policy and
    /// must remain alive and exclusively owned until the resolver reaches a terminal state.
    pub fn init(self: *Resolver, expected_commit: []const u8, backing: *Backing) Error!void {
        if (!identity.lowerHex(expected_commit, 40))
            return error.InvalidPolicy;
        try backing.requireOwner();
        if (rangesOverlapObjects(Resolver, self, Backing, backing) or
            (backing.rows.len != 0 and rangesOverlap(Resolver, self, Sha, backing.rows)))
            return error.InvalidPolicy;
        if (backing.resolver_addr != 0) return error.BackingInUse;

        var commit: Sha = undefined;
        @memcpy(&commit, expected_commit);
        try backing.bind(@intFromPtr(self));
        self.* = .{
            .owner_addr = @intFromPtr(self),
            .expected_commit = commit,
            .backing = backing,
            .backing_rows_addr = @intFromPtr(backing.rows.ptr),
            .backing_rows_len = backing.rows.len,
            .visited_count = 0,
            .current_tag = undefined,
            .phase = .awaiting_ref,
        };
    }

    pub fn acceptRef(
        self: *Resolver,
        observation: git.RefObservation,
        expected_tag: []const u8,
    ) Error!void {
        try self.requireOwner();
        if (self.phase == .failed) return error.Terminal;
        if (self.phase != .awaiting_ref) return self.reject(error.InvalidState);
        if (!identity.canonicalTag(expected_tag) or
            !std.mem.eql(u8, observation.tag, expected_tag))
            return self.reject(error.IdentityMismatch);
        try self.acceptTarget(observation.target);
    }

    pub fn acceptTag(self: *Resolver, observation: git.TagObservation) Error!void {
        try self.requireOwner();
        if (self.phase == .failed) return error.Terminal;
        if (self.phase != .awaiting_tag) return self.reject(error.InvalidState);
        if (!identity.lowerHex(observation.object_sha, 40) or
            !std.mem.eql(u8, observation.object_sha, &self.current_tag))
            return self.reject(error.IdentityMismatch);
        try self.acceptTarget(observation.target);
    }

    pub fn nextTag(self: *const Resolver) Error!NextTag {
        try self.requireOwner();
        return switch (self.phase) {
            .awaiting_tag => .{ .object_sha = self.current_tag },
            .failed => error.Terminal,
            else => error.InvalidState,
        };
    }

    pub fn result(self: *const Resolver) Error!Result {
        try self.requireOwner();
        return switch (self.phase) {
            .complete => .{ .commit_sha = self.expected_commit },
            .failed => error.Terminal,
            else => error.InvalidState,
        };
    }

    fn acceptTarget(self: *Resolver, target: git.Object) Error!void {
        if (!identity.lowerHex(target.sha, 40)) return self.reject(error.IdentityMismatch);
        switch (target.kind) {
            .commit => {
                if (!std.mem.eql(u8, target.sha, &self.expected_commit))
                    return self.reject(error.IdentityMismatch);
                self.phase = .complete;
            },
            .tag => {
                var sha: Sha = undefined;
                @memcpy(&sha, target.sha);
                for (self.backing.rows[0..self.visited_count]) |seen| {
                    if (std.mem.eql(u8, &seen, &sha)) return self.reject(error.Cycle);
                }
                if (self.visited_count == self.backing.rows.len)
                    return self.reject(error.DepthExceeded);
                self.backing.rows[self.visited_count] = sha;
                self.visited_count += 1;
                self.current_tag = sha;
                self.phase = .awaiting_tag;
            },
        }
    }

    fn requireOwner(self: *const Resolver) Error!void {
        if (self.owner_addr != @intFromPtr(self)) return error.InvalidOwner;
        try self.backing.requireBound(@intFromPtr(self));
        if (@intFromPtr(self.backing.rows.ptr) != self.backing_rows_addr or
            self.backing.rows.len != self.backing_rows_len or
            self.visited_count > self.backing_rows_len)
            return error.InvalidOwner;
    }

    fn reject(self: *Resolver, err: Error) Error {
        self.phase = .failed;
        return err;
    }
};

fn rangesOverlap(
    comptime Owner: type,
    owner: *Owner,
    comptime Item: type,
    items: []Item,
) bool {
    const owner_start = @intFromPtr(owner);
    const owner_end = std.math.add(usize, owner_start, @sizeOf(Owner)) catch return true;
    const items_start = @intFromPtr(items.ptr);
    const items_bytes = std.math.mul(usize, items.len, @sizeOf(Item)) catch return true;
    const items_end = std.math.add(usize, items_start, items_bytes) catch return true;
    return owner_start < items_end and items_start < owner_end;
}

fn rangesOverlapObjects(
    comptime A: type,
    a: *A,
    comptime B: type,
    b: *B,
) bool {
    return rangesOverlap(A, a, u8, @as([*]u8, @ptrCast(b))[0..@sizeOf(B)]);
}
