//! root별 후보 선정 뒤 합집합을 검색한다. 결과·사본·취소는 요청 전체가 소유한다.
const std = @import("std");
const search = @import("maru").session.editor.search;
const process = @import("process.zig");
const model = @import("model.zig");
const path = @import("path.zig");
const Scope = @import("scope.zig").Scope;
pub const Input = struct { path: []const u8, identity: @import("maru").session.file_tree.Identity };
pub fn freeInputs(a: std.mem.Allocator, inputs: []Input) void {
    for (inputs) |input| a.free(input.path);
    a.free(inputs);
}
pub fn copyInputs(a: std.mem.Allocator, inputs: []const Input) ![]Input {
    const copy = try a.alloc(Input, inputs.len);
    var filled: usize = 0;
    errdefer {
        for (copy[0..filled]) |input| a.free(input.path);
        a.free(copy);
    }
    for (inputs, copy) |input, *item| {
        item.* = .{ .path = try a.dupe(u8, input.path), .identity = input.identity };
        filled += 1;
    }
    return copy;
}
const Opened = struct { input: Input, logical: []u8 };
fn relative(root: []const u8, full: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, root, full)) return null;
    if (root.len == 0) return full;
    if (!std.mem.startsWith(u8, full, root) or full.len <= root.len or full[root.len] != '/') return null;
    return full[root.len + 1 ..];
}
const Selection = struct {
    a: std.mem.Allocator,
    candidates: std.StringHashMapUnmanaged(usize) = .{},
    occupied: *const std.StringHashMapUnmanaged(void),
    logical: []const u8,
    root_index: usize,
    target: ?[]const u8 = null,
    control: *process.Control,
    fn accept(self: *@This(), input: []const u8) !void {
        if (self.control.cancelled.load(.acquire)) return error.Cancelled;
        const name = try search.request.relativePath(input);
        if (self.target) |target| if (!std.mem.eql(u8, name, target)) return;
        const full = std.fmt.allocPrint(self.a, "{s}{s}{s}", .{ self.logical, if (self.logical.len == 0) "" else "/", name }) catch return error.SelectionBudget;
        if (self.occupied.contains(full) or self.candidates.contains(full)) {
            self.a.free(full);
            return;
        }
        self.candidates.put(self.a, full, self.root_index) catch return error.SelectionBudget;
    }
};
/// 모든 root를 먼저 검증한다. 뒤 root의 실패를 앞 root의 성공 완료로 숨기지 않는다.
pub fn execute(job: anytype) !void {
    const a = job.a;
    const started = std.Io.Timestamp.now(job.io, .awake);
    const before_hash = if (job.target_path) |target| try @import("verify.zig").disk(a, job.io, job.roots.?[0].path, target, &job.control, job.budget.navigation_bytes, job.roots.?[0].identity) else null;
    var opened: std.ArrayList(Opened) = .empty;
    defer {
        for (opened.items) |item| a.free(item.logical);
        opened.deinit(a);
    }
    for (job.roots.?) |input| {
        if (job.control.cancelled.load(.acquire)) return error.Cancelled;
        // 신원은 모두 확인하되 핸들을 누적하지 않는다. helper 직전에도 같은 신원을 다시 연다.
        var root = try openVerified(a, job.io, input);
        defer root.deinit(a, job.io);
        const logical = if (std.mem.eql(u8, input.path, "/")) try a.dupe(u8, "") else try path.spelling(a, "/", input.path[1..], &job.control);
        errdefer a.free(logical);
        try opened.append(a, .{ .input = input, .logical = logical });
    }
    // 전체 절대 논리 경로에서 저장된 철자를 맞춘다. inode가 같은 별도 링크 이름은 남긴다.
    try path.prepare(a, "/", &job.state, &job.models, &job.control);
    for (opened.items) |item| try validateInput(a, job.io, item.input);
    var scope = try Scope.fromArgs(a, job.args.items.items, job.opts.ignore_glob_case);
    defer scope.deinit(a);
    // 모델은 하나만 캡처했으며, ignore와 별도로 첫 명시적 허용 root에 귀속한다.
    for (job.models.items) |*captured| {
        for (opened.items, 0..) |item, index| {
            const name = relative(item.logical, captured.path) orelse continue;
            if (!try scope.accepts(name)) continue;
            const full = captured.path;
            captured.path = try a.dupe(u8, name);
            defer {
                a.free(captured.path);
                captured.path = full;
            }
            job.root_index = index;
            model.run(a, captured, job.query, job.opts, &job.control, job.budget.snapshot_bytes, job.budget.preview_bytes, job, @TypeOf(job.*).accept) catch |err| {
                if (err == error.Cancelled or err == error.ResultBudget) return err;
                job.exclude();
            };
            break;
        }
    }
    // map·키·재배치까지 전체 후보 기억역을 caller의 고정 byte 예산 안에 둔다.
    const storage = try a.alloc(u8, job.budget.selection_bytes);
    defer a.free(storage);
    var arena = std.heap.FixedBufferAllocator.init(storage);
    var selection: Selection = .{ .a = arena.allocator(), .occupied = &job.state.occupied, .logical = "", .root_index = 0, .control = &job.control, .target = job.target_path };
    var files = try search.query.filesFromSearch(a, &job.args);
    defer files.deinit(a);
    var partial = job.state.excluded > 0;
    for (opened.items, 0..) |*item, index| {
        var root = try openVerified(a, job.io, item.input);
        defer root.deinit(a, job.io);
        selection.logical = item.logical;
        selection.root_index = index;
        const outcome = try process.runDelimited(a, job.io, files.items.items, &job.environment, &root, &job.control, try remaining(job, started), std.fs.max_path_bytes, &selection, Selection.accept, &job.stats, 0);
        if (outcome == .cancelled) return error.Cancelled;
        if (outcome == .partial) partial = true;
    }
    job.selected = &selection.candidates;
    defer job.selected = null;
    // argv는 root마다 작게 나눈다. 선행 root에서 0건인 후보도 두 번 검색하지 않는다.
    for (opened.items, 0..) |*item, index| {
        var root = try openVerified(a, job.io, item.input);
        defer root.deinit(a, job.io);
        job.root_index = index;
        job.logical_root = item.logical;
        var iterator = selection.candidates.iterator();
        var exhausted = false;
        while (!exhausted) {
            if (job.control.cancelled.load(.acquire)) return error.Cancelled;
            var args: search.query.Args = .{};
            defer args.deinit(a);
            for (job.args.items.items[0 .. job.args.items.items.len - 1]) |arg| try args.add(a, arg);
            var bytes: usize = 0;
            while (iterator.next()) |entry| {
                if (entry.value_ptr.* != index) continue;
                const name = relative(item.logical, entry.key_ptr.*) orelse return error.InvalidPath;
                try args.add(a, name);
                bytes += name.len + 1;
                if (bytes >= 16 * 1024) break;
            } else exhausted = true;
            if (bytes == 0) continue;
            job.batch_paths = args.items.items[job.args.items.items.len - 1 ..];
            defer job.batch_paths = null;
            job.summary_seen = false;
            job.disk_matches = 0;
            const outcome = try process.run(a, job.io, args.items.items, &job.environment, &root, &job.control, try remaining(job, started), job.state.limits.event_bytes, job, @TypeOf(job.*).acceptDisk, &job.stats);
            if (outcome == .cancelled) return error.Cancelled;
            if (outcome == .partial) partial = true else if (!job.summary_seen) return error.IncompleteOutput;
        }
    }
    for (opened.items) |item| try validateInput(a, job.io, item.input);
    if (job.target_path) |target| {
        const after_hash = try @import("verify.zig").disk(a, job.io, job.roots.?[0].path, target, &job.control, job.budget.navigation_bytes, job.roots.?[0].identity);
        if (!std.mem.eql(u8, &before_hash.?, &after_hash)) return error.FileChanged;
        job.target_hash = after_hash;
    }
    job.finish(if (partial) .partial else .complete);
}

fn remaining(job: anytype, started: std.Io.Timestamp) !process.Timing {
    const left = job.budget.timing.execution_ms - started.untilNow(job.io, .awake).toMilliseconds();
    if (left <= 0) return error.ExecutionBudget;
    return .{ .execution_ms = left, .reap_ms = job.budget.timing.reap_ms };
}

fn openVerified(a: std.mem.Allocator, io: std.Io, input: Input) !process.Root {
    var root = try process.openRoot(a, io, input.path);
    errdefer root.deinit(a, io);
    const device: std.meta.Int(.unsigned, @bitSizeOf(@TypeOf(root.device))) = @bitCast(root.device);
    if (root.stat.inode != input.identity.inode or @as(u64, device) != input.identity.device or input.identity.kind != 2) return error.RootChanged;
    try process.validateRoot(io, &root);
    return root;
}
fn validateInput(a: std.mem.Allocator, io: std.Io, input: Input) !void {
    var root = try openVerified(a, io, input);
    defer root.deinit(a, io);
}
