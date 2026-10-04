//! App-owned directory subscriptions and one bounded native read slot. Values
//! identify views; no pointer into the app's moving file array survives a tick.
const std = @import("std");
const maru = @import("maru");
const hosting = @import("file_host.zig");
const document = @import("document.zig");
const watching = @import("directory_watch.zig");
const reading = @import("file_read_worker.zig");
const Lease = maru.session.editor.document_registry.Lease;

pub const Coordinator = struct {
    const Binding = struct {
        document: Lease,
        watch: ?watching.Lease = null,
        pending: bool = true,
        retry_at: i128 = 0,
        paused: bool = false,
        conflict_hash: ?u64 = null,
        notice: ?anyerror = null,
    };
    pub const Event = struct { document: Lease, problem: anyerror };
    pub const Choice = enum { compare, reload };
    pub const Request = struct { document: Lease, choice: Choice, retry_at: i128 = 0 };
    pub const Completion = struct {
        request: Request,
        result: reading.Result,

        pub fn deinit(self: *Completion) void {
            self.result.deinit();
        }
    };
    allocator: std.mem.Allocator,
    groups: watching.Groups,
    reader: reading.Reader = .{},
    bindings: std.ArrayList(Binding) = .empty,
    active: ?Lease = null,
    requested: ?Request = null,
    active_choice: ?Request = null,
    completed: ?Completion = null,
    cursor: usize = 0,
    address: ?*Coordinator = null,
    hold_notices: bool = false,
    admission_retry_at: i128 = 0,
    pub const retry_ns = 200 * std.time.ns_per_ms;

    pub fn init(a: std.mem.Allocator) Coordinator {
        return .{ .allocator = a, .groups = .{ .allocator = a } };
    }

    fn check(self: *Coordinator) !void {
        if (self.address) |original| if (original != self) return error.CopiedExternalCoordinator;
        self.address = self;
    }

    fn same(a: Lease, b: Lease) bool {
        return a.owner == b.owner and a.id == b.id and a.kind == b.kind and std.meta.eql(a.document, b.document);
    }

    fn viewIndex(views: []document.OpenFile, lease: Lease) ?usize {
        for (views, 0..) |view, i| if (same(view.document, lease)) return i;
        return null;
    }

    /// Choices request a new image; the conflict notification grants no write
    /// authority and carries no cached body. One reader still bounds all I/O.
    pub fn requestChoice(self: *Coordinator, target: Lease, choice: Choice) !void {
        try self.check();
        if (self.requested != null or self.active_choice != null or self.completed != null) return error.ReadBusy;
        self.requested = .{ .document = target, .choice = choice };
    }

    /// Ownership moves to the host, which revalidates acceptsRead immediately
    /// before applying the reload or copying the current buffer for comparison.
    pub fn takeChoice(self: *Coordinator) !?Completion {
        try self.check();
        const result = self.completed;
        self.completed = null;
        return result;
    }

    /// Admission happens once per new view. A failed watch stays explicitly
    /// paused until that view closes; it never silently becomes polling I/O.
    pub fn tick(self: *Coordinator, book: *hosting.Book, io: std.Io, views: []document.OpenFile, now_ns: i128) !?Event {
        try self.check();
        var admission_problem: ?anyerror = null;
        if (self.requested) |request| if (viewIndex(views, request.document) == null) {
            self.requested = null;
        };
        if (self.completed) |*completion| if (viewIndex(views, completion.request.document) == null) {
            completion.deinit();
            self.completed = null;
        };
        var i = self.bindings.items.len;
        while (i != 0) {
            i -= 1;
            const binding = self.bindings.items[i];
            if (viewIndex(views, binding.document) != null) continue;
            if (binding.watch) |lease| try self.groups.release(lease);
            _ = self.bindings.orderedRemove(i);
        }
        for (views) |view| {
            if (now_ns < self.admission_retry_at) break;
            const state = book.registry.get(view.document) orelse continue;
            if (state.opened == null or state.opened.?.file.read_only) continue;
            var found = false;
            for (self.bindings.items) |binding| if (same(binding.document, view.document)) {
                found = true;
                break;
            };
            if (found) continue;
            self.bindings.ensureUnusedCapacity(self.allocator, 1) catch |err| {
                self.admission_retry_at = now_ns +| retry_ns;
                admission_problem = err;
                break;
            };
            var binding: Binding = .{ .document = view.document };
            binding.watch = book.subscribeWatch(io, &self.groups, view.document) catch |err| blk: {
                if (err == error.SaveBusy) continue;
                if (err == error.OutOfMemory) {
                    self.admission_retry_at = now_ns +| retry_ns;
                    admission_problem = err;
                    break;
                }
                binding.paused = true;
                binding.notice = err;
                break :blk null;
            };
            self.bindings.appendAssumeCapacity(binding);
        }
        if (self.groups.poll(now_ns)) |notice| {
            for (self.bindings.items) |*binding| if (binding.watch) |lease| {
                if (!try self.groups.receives(lease, notice.group)) continue;
                if (notice.problem) |problem| {
                    if (!binding.paused) binding.notice = problem;
                    binding.paused = true;
                } else if (!binding.paused) binding.pending = true;
            };
        }
        if (try self.reader.takeResult()) |value| result_block: {
            var result = value;
            var moved = false;
            defer if (!moved) result.deinit();
            const target = self.active orelse return error.MissingExternalReadOwner;
            self.active = null;
            if (self.active_choice) |request| {
                self.active_choice = null;
                if (viewIndex(views, target) == null) break :result_block;
                if (!(book.acceptsRead(&self.reader, result, target) catch false)) {
                    var retry = request;
                    retry.retry_at = now_ns +| retry_ns;
                    self.requested = retry;
                    break :result_block;
                }
                if (result == .failure and result.failure.problem == error.SourceBusy) {
                    var retry = request;
                    retry.retry_at = now_ns +| retry_ns;
                    self.requested = retry;
                    break :result_block;
                }
                self.completed = .{ .request = request, .result = result };
                moved = true;
                break :result_block;
            }
            if (viewIndex(views, target)) |vi| {
                for (self.bindings.items) |*binding| {
                    if (!same(binding.document, target)) continue;
                    if (binding.paused) break;
                    const accepted = book.acceptsRead(&self.reader, result, target) catch false;
                    if (!accepted) {
                        binding.pending = true;
                        binding.retry_at = now_ns +| retry_ns;
                        break;
                    }
                    switch (result) {
                        .failure => |failure| {
                            if (failure.problem == error.SourceBusy) {
                                binding.pending = true;
                                binding.retry_at = now_ns +| retry_ns;
                            } else {
                                binding.paused = true;
                                binding.notice = failure.problem;
                            }
                        },
                        .image => |image| {
                            const state = book.registry.get(target).?;
                            // Notifications and operation IDs are hints only.
                            // Only the current raw fingerprint folds self-writes.
                            if (state.opened.?.disk_hash == image.raw_hash) break;
                            if (state.opened.?.isDirty()) {
                                if (binding.conflict_hash != image.raw_hash) binding.notice = error.DirtyDocument;
                                binding.conflict_hash = image.raw_hash;
                            } else {
                                _ = views[vi].acceptExternal(self.allocator, views, image.bytes, now_ns) catch |err| blk: {
                                    binding.pending = err == error.OutOfMemory or err == error.SaveBusy;
                                    binding.retry_at = now_ns +| retry_ns;
                                    if (!binding.pending) binding.paused = true;
                                    binding.notice = err;
                                    break :blk false;
                                };
                            }
                        },
                    }
                    break;
                }
            }
        }
        if (self.active == null and self.completed == null) {
            if (self.requested) |*request| {
                if (now_ns >= request.retry_at) {
                    if (book.submitRead(&self.reader, request.document)) |_| {
                        self.active = request.document;
                        self.active_choice = request.*;
                        self.requested = null;
                    } else |err| {
                        request.retry_at = now_ns +| retry_ns;
                        if (err != error.SaveBusy and err != error.ReadBusy and err != error.OutOfMemory) {
                            self.requested = null;
                            return err;
                        }
                    }
                }
            }
        }
        if (self.active == null and self.requested == null and self.completed == null and self.bindings.items.len != 0) {
            const count = self.bindings.items.len;
            for (0..count) |offset| {
                const bi = (self.cursor + offset) % count;
                const binding = &self.bindings.items[bi];
                if (binding.paused or !binding.pending or now_ns < binding.retry_at) continue;
                _ = book.submitRead(&self.reader, binding.document) catch |err| {
                    binding.retry_at = now_ns +| retry_ns;
                    if (err != error.SaveBusy and err != error.ReadBusy and err != error.OutOfMemory) {
                        binding.paused = true;
                        binding.notice = err;
                    }
                    continue;
                };
                binding.pending = false;
                self.active = binding.document;
                self.cursor = (bi + 1) % count;
                break;
            }
        }
        if (self.hold_notices) return null;
        for (self.bindings.items) |*binding| if (binding.notice) |problem| {
            binding.notice = null;
            return .{ .document = binding.document, .problem = problem };
        };
        if (admission_problem) |problem| return problem;
        return null;
    }

    pub fn deinit(self: *Coordinator, io: std.Io) !void {
        try self.check();
        try self.reader.deinit(io);
        if (self.completed) |*completion| completion.deinit();
        self.completed = null;
        self.requested = null;
        self.active_choice = null;
        try self.groups.deinit();
        self.bindings.deinit(self.allocator);
        self.bindings = .empty;
        self.active = null;
    }
};
