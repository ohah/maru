//! 실제 파일 찾기 함수를 그대로 호출하는 비교 도구다. UI·워커·ignore 구현의 측정은 아니다.
const std = @import("std");
const find = @import("maru").session.editor.find;
const document = @import("maru").session.editor.document;
const line_index = @import("maru").session.editor.line_index;

pub fn main(init: std.process.Init) !void {
    const a = init.gpa;
    const args = try init.minimal.args.toSlice(a);
    defer a.free(args);
    if (args.len < 4 or args.len > 6) return error.ExpectedFileListQueryMode;
    var emit_ranges = false;
    var raw_bytes = false;
    for (args[4..]) |arg| {
        if (std.mem.eql(u8, arg, "--ranges")) emit_ranges = true else if (std.mem.eql(u8, arg, "--raw-bytes")) raw_bytes = true else return error.InvalidOutputOption;
    }
    const byte_candidate = std.mem.eql(u8, args[3], "byte-candidate");
    if (byte_candidate) {
        if (args[2].len == 0) return error.EmptyLiteralQuery;
        _ = try std.unicode.Utf8View.init(args[2]);
        for (args[2]) |byte| if (byte == '\n' or byte == '\r') return error.NotSingleLineLiteral;
    }
    const options: find.Options = if (std.mem.eql(u8, args[3], "literal") or byte_candidate)
        .{ .match_case = true }
    else if (std.mem.eql(u8, args[3], "regex"))
        .{ .regex = true, .match_case = true }
    else if (std.mem.eql(u8, args[3], "word"))
        .{ .whole_word = true, .match_case = true }
    else if (std.mem.eql(u8, args[3], "literal-fold"))
        .{}
    else
        return error.InvalidMode;
    // 실험 파일을 읽는 한도다. 제품의 파일 크기 정책을 이 값으로 정하지 않는다.
    const paths = try std.Io.Dir.cwd().readFileAlloc(init.io, args[1], a, .limited(64 * 1024 * 1024));
    defer a.free(paths);
    var lines: std.ArrayList([]const u8) = .empty;
    defer lines.deinit(a);
    var matches: std.ArrayList(find.Match) = .empty;
    defer matches.deinit(a);
    var files: usize = 0;
    var bytes: usize = 0;
    var count: usize = 0;
    var first: ?find.Match = null;
    var first_ns: ?i96 = null;
    var buffer: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writer(init.io, &buffer);
    var paths_iter = std.mem.splitScalar(u8, paths, 0);
    const start = std.Io.Clock.awake.now(init.io);
    while (paths_iter.next()) |path| {
        if (path.len == 0) continue;
        const text = try std.Io.Dir.cwd().readFileAlloc(init.io, path, a, .limited(64 * 1024 * 1024));
        defer a.free(text);
        files += 1;
        bytes += text.len;
        lines.clearRetainingCapacity();
        // 제품과 같은 BOM·줄 경계를 사용한다. 두 후보가 같은 전처리 오류를 공유하면 대조도 통과한다.
        // 깨진 byte를 직접 넣는 검사는 명시적으로 분리하며 제품의 파일 열기 성공으로 세지 않는다.
        const content = if (raw_bytes) text else (try document.open(text, true)).content;
        var document_lines = try line_index.build(a, content);
        defer document_lines.deinit();
        for (document_lines.lines) |line| try lines.append(a, content[line.start..line.contentEnd()]);
        if (byte_candidate) {
            // 유효한 UTF-8·대소문자 구분만 비교한다. Unicode 접기·정규식 동등성은 주장하지 않는다.
            matches.clearRetainingCapacity();
            for (lines.items, 0..) |line, line_number| {
                var from: usize = 0;
                while (std.mem.indexOfPos(u8, line, from, args[2])) |offset| {
                    try matches.append(a, .{ .line = @intCast(line_number), .start = @intCast(offset), .len = @intCast(args[2].len) });
                    from = offset + args[2].len;
                }
            }
        } else {
            try find.findMatches(a, lines.items, args[2], options, &matches);
        }
        if (emit_ranges) {
            // 전체 범위 대조용 출력이다. 기본 성능 측정에는 이 직렬화 비용을 넣지 않는다.
            try writer.interface.print("{{\"file_index\":{d},\"ranges\":[", .{files - 1});
            for (matches.items, 0..) |match, index| {
                if (index != 0) try writer.interface.writeAll(",");
                try writer.interface.print("[{d},{d},{d}]", .{ match.line, match.start, match.len });
            }
            try writer.interface.writeAll("]}\n");
        }
        count += matches.items.len;
        if (first == null and matches.items.len > 0) {
            first = matches.items[0];
            first_ns = std.Io.Clock.awake.now(init.io).nanoseconds - start.nanoseconds;
            // 호스트가 첫 결과를 실제로 받을 수 있는 시점을 측정한다. 본문은 내보내지 않는다.
            std.debug.print("{{\"event\":\"first-match\"}}\n", .{});
        }
    }
    const elapsed = std.Io.Clock.awake.now(init.io).nanoseconds - start.nanoseconds;
    try writer.interface.print("{{\"files\":{d},\"bytes\":{d},\"matches\":{d},\"elapsed_ns\":{d},\"first\":", .{ files, bytes, count, elapsed });
    if (first) |match| {
        try writer.interface.print("{{\"line\":{d},\"start\":{d},\"len\":{d}}}", .{ match.line, match.start, match.len });
    } else {
        try writer.interface.writeAll("null");
    }
    try writer.interface.print(",\"first_match_ns\":{?d},\"optimize\":\"{s}\"}}\n", .{ first_ns, @tagName(@import("builtin").mode) });
    try writer.interface.flush();
}
