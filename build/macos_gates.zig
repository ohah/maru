//! Partition the already registered macOS gate graph; never maintain another gate list.
const std = @import("std");
const Step = std.Build.Step;

const Shard = struct { index: usize, count: usize };
const Entry = struct { id: []const u8, group: []const u8, step: *Step };

fn parse(raw: ?[]const u8) ?Shard {
    const s = raw orelse return null;
    const split = std.mem.indexOfScalar(u8, s, '/') orelse @panic("macos-only-shard requires i/n");
    const i = std.fmt.parseInt(usize, s[0..split], 10) catch @panic("invalid macos-only-shard index");
    const n = std.fmt.parseInt(usize, s[split + 1 ..], 10) catch @panic("invalid macos-only-shard count");
    if (n == 0 or i >= n) @panic("macos-only-shard requires 0 <= i < n");
    return .{ .index = i, .count = n };
}

fn add(hash: *std.hash.Wyhash, text: []const u8) void {
    hash.update(text);
    hash.update(&.{0});
}

fn path(hash: *std.hash.Wyhash, p: std.Build.LazyPath) void {
    add(hash, @tagName(p));
    switch (p) {
        .src_path => |v| add(hash, v.sub_path),
        .generated => |v| add(hash, v.sub_path),
        .cwd_relative => |v| add(hash, v),
        .dependency => |v| add(hash, v.sub_path),
        .relative => |v| add(hash, v.sub_path),
    }
}

fn artifact(hash: *std.hash.Wyhash, c: *Step.Compile) void {
    add(hash, c.name);
    if (c.root_module.root_source_file) |p| path(hash, p);
    if (c.root_module.optimize) |opt| add(hash, @tagName(opt));
    for (c.filters) |filter| add(hash, filter);
}

fn fingerprint(b: *std.Build, node: *Step) u64 {
    var hash = std.hash.Wyhash.init(0);
    add(&hash, @tagName(node.tag));
    add(&hash, node.name);
    if (node.cast(Step.Run)) |run| {
        if (run.producer) |c| artifact(&hash, c);
        for (run.argv.items) |arg| {
            add(&hash, @tagName(arg));
            switch (arg) {
                .bytes => |v| {
                    const root = b.root.toString(b.allocator) catch @panic("OOM");
                    const normalized = std.mem.replaceOwned(u8, b.allocator, v, root, "{repo}") catch @panic("OOM");
                    add(&hash, normalized);
                },
                .artifact => |v| artifact(&hash, v.artifact),
                .lazy_path, .decorated_directory => |v| path(&hash, v.lazy_path),
                .file_content => |v| path(&hash, v.lazy_path),
                else => {},
            }
        }
    }
    return hash.final();
}

fn groupName(b: *std.Build, node: *Step) ?[]const u8 {
    var found: ?[]const u8 = null;
    var it = b.top_level_steps.iterator();
    while (it.next()) |pair| {
        const name = pair.key_ptr.*;
        if (std.mem.eql(u8, name, "test") or std.mem.eql(u8, name, "test-macos-only")) continue;
        const top = &pair.value_ptr.*.step;
        // An aggregate parent must not collapse all its children onto one worker.
        const owns = top == node or (top.dependencies.items.len == 1 and top.dependencies.items[0] == node);
        if (owns and (found == null or std.mem.order(u8, name, found.?) == .lt)) found = name;
    }
    return found;
}

fn collectCompiles(b: *std.Build, node: *Step, visited: *std.AutoHashMapUnmanaged(*Step, void), out: *std.ArrayList(*Step)) void {
    const slot = visited.getOrPut(b.allocator, node) catch @panic("OOM");
    if (slot.found_existing) return;
    if (node.tag == .compile) out.append(b.allocator, node) catch @panic("OOM");
    for (node.dependencies.items) |child| collectCompiles(b, child, visited, out);
}

fn assertNoTests(b: *std.Build, node: *Step, visited: *std.AutoHashMapUnmanaged(*Step, void)) void {
    const slot = visited.getOrPut(b.allocator, node) catch @panic("OOM");
    if (slot.found_existing) return;
    if (node.cast(Step.Run)) |run| if (run.producer) |c| {
        if (c.kind == .@"test") std.debug.panic("macOS compile warmup depends on test execution: {s}", .{node.name});
    };
    for (node.dependencies.items) |child| assertNoTests(b, child, visited);
}

pub fn register(b: *std.Build, root: *Step) void {
    const shard = parse(b.option([]const u8, "macos-only-shard", "Select one complete macOS gate graph partition, i/n"));
    var entries: std.ArrayList(Entry) = .empty;
    var unique: std.AutoHashMapUnmanaged(*Step, void) = .empty;
    for (root.dependencies.items) |node| {
        const slot = unique.getOrPut(b.allocator, node) catch @panic("OOM");
        if (slot.found_existing) continue; // The scheduler also executes a shared node only once.
        const fp = fingerprint(b, node);
        const group = groupName(b, node) orelse b.fmt("{s}-{x:0>16}", .{ node.name, fp });
        const prefix = b.fmt("{s}#{x:0>16}", .{ group, fp });
        var occurrence: usize = 0;
        for (entries.items) |old| if (std.mem.startsWith(u8, old.id, prefix)) {
            occurrence += 1;
        };
        // Identical commands with different environments are still separate roots.
        const id = b.fmt("{s}/{d}", .{ prefix, occurrence });
        entries.append(b.allocator, .{ .id = id, .group = group, .step = node }) catch @panic("OOM");
    }
    std.mem.sort(Entry, entries.items, {}, struct {
        fn less(_: void, a: Entry, c: Entry) bool {
            return std.mem.order(u8, a.id, c.id) == .lt;
        }
    }.less);

    var all: std.ArrayList([]const u8) = .empty;
    var selected: std.ArrayList([]const u8) = .empty;
    var compiles: std.ArrayList(*Step) = .empty;
    var visited: std.AutoHashMapUnmanaged(*Step, void) = .empty;
    if (shard != null) root.dependencies.clearRetainingCapacity();
    for (entries.items) |entry| {
        all.append(b.allocator, entry.id) catch @panic("OOM");
        if (shard) |s| if (std.hash.Wyhash.hash(0, entry.group) % s.count != s.index) continue;
        selected.append(b.allocator, entry.id) catch @panic("OOM");
        if (shard != null) root.dependOn(entry.step);
        collectCompiles(b, entry.step, &visited, &compiles);
    }
    if (shard != null and selected.items.len == 0) @panic("macos-only-shard selects no gates");
    const warm = b.step("compile-macos-only", "Compile selected macOS gate artifacts without running their tests");
    var safe: std.AutoHashMapUnmanaged(*Step, void) = .empty;
    for (compiles.items) |node| {
        warm.dependOn(node);
    }
    assertNoTests(b, warm, &safe);
    const manifest = std.json.Stringify.valueAlloc(b.allocator, .{
        .schema = @as(u32, 1),
        .shard = if (shard) |s| @as(?usize, s.index) else null,
        .count = if (shard) |s| s.count else @as(usize, 1),
        .catalog = all.items,
        .selected = selected.items,
        .compile_artifacts = compiles.items.len,
        .warm_test_runs = @as(usize, 0),
    }, .{ .whitespace = .indent_2 }) catch @panic("OOM");
    const files = b.addWriteFiles();
    const report = b.addInstallFile(files.add("macos-only-manifest.json", manifest), "macos-only-manifest.json");
    b.step("plan-macos-only", "Write the actual macOS gate partition manifest without compiling tests").dependOn(&report.step);
    root.dependOn(&report.step);
    warm.dependOn(&report.step);
    if (shard) |s| std.debug.print("macos-only shard {d}/{d}: {d} of {d} roots; {d} compile artifacts\n", .{ s.index, s.count, selected.items.len, all.items.len, compiles.items.len });
}
