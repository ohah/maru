//! 실제 worker 소유 API를 통하는 판정 경로. 프로브 전용으로 helper를 명시한다.
const std = @import("std");
const editor = @import("maru").session.editor;
const search = editor.search;
const api = @import("search_backend");
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const argv = try init.minimal.args.toSlice(a);
    defer a.free(argv);
    if (argv.len == 4 and std.mem.eql(u8, argv[1], "--audit-ownership")) {
        try @import("ownership.zig").run(a, init.io, argv[2], argv[3]);
        return;
    }
    if (argv.len < 6) return error.Arguments;
    const cancel_ms = try std.fmt.parseInt(i64, argv[4], 10);
    const bytes = try std.fmt.parseInt(usize, argv[5], 10);
    const identity: search.request.Identity = .{ .request = 1, .root = 1, .models = 1 };
    var state: search.request.State = .{ .identity = identity, .limits = .{ .result_bytes = bytes, .event_bytes = 4 * 1024 * 1024 } };
    defer state.deinit(a);
    var models: std.ArrayList(api.model.Captured) = .empty;
    defer {
        for (models.items) |*captured| captured.deinit(a);
        models.deinit(a);
    }
    var execution_ms: i64 = 10_000;
    var mutate = false;
    var stale = false;
    var includes: std.ArrayList([]const u8) = .empty;
    defer includes.deinit(a);
    var excludes: std.ArrayList([]const u8) = .empty;
    defer excludes.deinit(a);
    try excludes.appendSlice(a, &search.query.default_excludes);
    var opts: search.query.Options = .{ .match_case = true };
    var retained: usize = 0;
    var i: usize = 6;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--include") or std.mem.eql(u8, argv[i], "--exclude")) {
            const include = std.mem.eql(u8, argv[i], "--include");
            i += 1;
            if (i >= argv.len) return error.MissingGlob;
            if (include) try includes.append(a, argv[i]) else try excludes.append(a, argv[i]);
            continue;
        }
        if (std.mem.eql(u8, argv[i], "--execution-ms")) {
            i += 1;
            if (i >= argv.len) return error.Arguments;
            execution_ms = try std.fmt.parseInt(i64, argv[i], 10);
            continue;
        }
        if (std.mem.eql(u8, argv[i], "--glob-case")) {
            opts.ignore_glob_case = true;
            continue;
        }
        if (std.mem.eql(u8, argv[i], "--mutate")) {
            mutate = true;
            continue;
        }
        if (std.mem.eql(u8, argv[i], "--stale")) {
            stale = true;
            continue;
        }
        if (std.mem.eql(u8, argv[i], "--regex")) {
            opts.regex = true;
            continue;
        }
        if (std.mem.eql(u8, argv[i], "--fold")) {
            opts.match_case = false;
            continue;
        }
        if (std.mem.eql(u8, argv[i], "--word")) {
            opts.whole_word = true;
            continue;
        }
        if (std.mem.eql(u8, argv[i], "--model") or std.mem.eql(u8, argv[i], "--model-file") or std.mem.eql(u8, argv[i], "--shared")) {
            if (i + 2 >= argv.len) return error.ModelArguments;
            const owned = if (std.mem.eql(u8, argv[i], "--model-file")) try std.Io.Dir.cwd().readFileAlloc(init.io, argv[i + 2], a, .limited(64 * 1024 * 1024)) else null;
            defer if (owned) |bytes_owned| a.free(bytes_owned);
            var file = try editor.edit_doc.EditableFile.init(a, owned orelse argv[i + 2], false);
            defer file.deinit();
            const shared = std.mem.eql(u8, argv[i], "--shared");
            _ = try api.model.captureUnique(a, &state, &models, argv[i + 1], .{ .owner = 1, .slot = if (shared) 0 else models.items.len, .generation = 1 }, 0, &file, &retained, 64 * 1024 * 1024);
            if (mutate) _ = try file.buf.insert(0, "changed-after-capture");
            i += 2;
        } else try state.occupy(a, argv[i]);
    }
    opts.includes = includes.items;
    opts.excludes = excludes.items;
    var backend: api.Backend = .{ .a = a, .io = init.io };
    defer backend.deinit();
    const started = std.Io.Timestamp.now(init.io, .awake);
    const budget: api.Budget = .{ .timing = .{ .execution_ms = execution_ms, .reap_ms = 1000 }, .snapshot_bytes = 64 * 1024 * 1024, .preview_bytes = 256 };
    if (std.mem.eql(u8, argv[1], "@bundle")) {
        try backend.startBundled(argv[2], argv[3], opts, &state, &models, budget);
    } else try backend.start(argv[1], argv[2], argv[3], opts, &state, &models, budget);
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(init.io, &buffer);
    var cancellation_at: ?i64 = null;
    var status: search.request.Status = .running;
    var matches: usize = 0;
    var batches: usize = 0;
    var current = identity;
    while (true) {
        const elapsed = started.untilNow(init.io, .awake).toMilliseconds();
        if (cancel_ms >= 0 and elapsed >= cancel_ms and cancellation_at == null) {
            backend.cancel();
            cancellation_at = elapsed;
        }
        if (stale and elapsed >= 1) current.root = 2;
        if (backend.take(current)) |value| {
            var batch = value;
            defer batch.deinit(a);
            status = batch.status;
            matches = batch.matches;
            if (batch.rows.items.len > 0) batches += 1;
            for (batch.rows.items) |row| {
                try std.json.Stringify.value(row.match, .{}, &out.interface);
                try out.interface.writeAll("\n");
            }
            try out.interface.flush();
        }
        if (backend.done()) {
            // done과 최종 take의 순서가 뒤집혀도 남은 행·terminal 상태를 마지막에 읽는다.
            if (backend.take(current)) |value| {
                var batch = value;
                defer batch.deinit(a);
                status = batch.status;
                matches = batch.matches;
                for (batch.rows.items) |row| {
                    try std.json.Stringify.value(row.match, .{}, &out.interface);
                    try out.interface.writeAll("\n");
                }
            }
            break;
        }
        _ = std.c.poll(@constCast(&[_]std.posix.pollfd{}), 0, 1);
    }
    const elapsed = started.untilNow(init.io, .awake).toMilliseconds();
    const completion = backend.completion() orelse return error.MissingCompletion;
    status = completion.status;
    const failure = completion.failure;
    try std.json.Stringify.value(.{ .status = @tagName(status), .matches = matches, .excluded = completion.excluded, .batches = batches, .stats = backend.stats(), .cancel_latency_ms = if (cancellation_at) |time| elapsed - time else null, .failure = if (failure) |err| @errorName(err) else null }, .{}, &out.interface);
    try out.interface.writeAll("\n");
    try out.interface.flush();
}
