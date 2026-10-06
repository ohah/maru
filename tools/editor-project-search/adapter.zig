//! 실제 번들 helper→argv→JSON/분할 parser를 실행하는 개발용 제품 프로토콜 판정 경로다.
//! run의 출력 수집 한도는 이 도구의 한도이며 앱 worker/취소/결과 예산을 대신하지 않는다.
const std = @import("std");
const search = @import("project_search");
pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const argv = try init.minimal.args.toSlice(a);
    defer a.free(argv);
    if (argv.len < 5) return error.ExpectedHelperRootQueryMode;
    var opts: search.query.Options = .{};
    const mode = argv[4];
    if (std.mem.startsWith(u8, mode, "regex")) opts.regex = true;
    if (std.mem.indexOf(u8, mode, "word") != null) opts.whole_word = true;
    opts.match_case = !std.mem.endsWith(u8, mode, "fold");
    var valid = false;
    for ([_][]const u8{ "literal", "literal-fold", "word", "word-fold", "regex", "regex-fold", "regex-word", "regex-word-fold" }) |allowed| {
        if (std.mem.eql(u8, mode, allowed)) valid = true;
    }
    if (!valid) return error.InvalidMode;
    if (!std.fs.path.isAbsolute(argv[2])) return error.InvalidRoot;
    var includes: std.ArrayList([]const u8) = .empty;
    defer includes.deinit(a);
    var excludes: std.ArrayList([]const u8) = .empty;
    try excludes.appendSlice(a, &search.query.default_excludes);
    defer excludes.deinit(a);
    var i: usize = 5;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--multiline")) {
            opts.multiline = true;
        } else if (std.mem.eql(u8, argv[i], "--ignore-glob-case")) {
            opts.ignore_glob_case = true;
        } else if (std.mem.eql(u8, argv[i], "--no-ignore")) {
            opts.ignore_files = false;
        } else if (std.mem.eql(u8, argv[i], "--include") or std.mem.eql(u8, argv[i], "--exclude")) {
            const include = std.mem.eql(u8, argv[i], "--include");
            i += 1;
            if (i >= argv.len) return error.MissingGlob;
            if (include) try includes.append(a, argv[i]) else try excludes.append(a, argv[i]);
        } else return error.InvalidOption;
    }
    opts.includes = includes.items;
    opts.excludes = excludes.items;
    var args = try search.query.build(a, argv[1], argv[3], opts);
    defer args.deinit(a);
    const result = try std.process.run(a, init.io, .{ .argv = args.items.items, .cwd = .{ .path = argv[2] }, .stdout_limit = .limited(64 * 1024 * 1024), .stderr_limit = .limited(64 * 1024) });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    const exit: u8 = switch (result.term) {
        .exited => |code| code,
        else => return error.HelperTerminated,
    };
    if (exit != 0 and exit != 1) return error.SearchFailed;
    var buffer: [4096]u8 = undefined;
    var output = std.Io.File.stdout().writer(init.io, &buffer);
    const Sink = struct {
        allocator: std.mem.Allocator,
        writer: *std.Io.Writer,
        matches: usize = 0,
        fn accept(self: *@This(), json: []const u8) !void {
            var event = try search.event.parse(self.allocator, json);
            switch (event) {
                .match => |*match| {
                    defer match.deinit(self.allocator);
                    try std.json.Stringify.value(match.*, .{}, self.writer);
                    try self.writer.writeAll("\n");
                    self.matches += match.ranges.len;
                },
                .other => {},
            }
        }
    };
    var sink: Sink = .{ .allocator = a, .writer = &output.interface };
    var stream: search.stream.Stream = .{ .max_event_bytes = 64 * 1024 * 1024 };
    defer stream.deinit(a);
    // 실제 임의 조각을 parser에 전달한다. UTF-8 글자/JSON token 중간도 잘린다.
    var from: usize = 0;
    while (from < result.stdout.len) {
        const end = @min(from + 37, result.stdout.len);
        try stream.consume(a, result.stdout[from..end], &sink, Sink.accept);
        from = end;
    }
    try stream.finish();
    try output.interface.print("{{\"matches\":{d},\"exit\":{d}}}\n", .{ sink.matches, exit });
    try output.interface.flush();
}
