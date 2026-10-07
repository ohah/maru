//! owner가 잡은 rope 스냅샷만 읽는다. registry·Term·가변 본문은 worker에 넘기지 않는다.
const std = @import("std");
const editor = @import("maru").session.editor;
const search = editor.search;
pub const Captured = struct {
    path: []u8,
    source: search.request.Source,
    snapshot: editor.buffer.Snapshot,
    pub fn deinit(self: *Captured, a: std.mem.Allocator) void {
        a.free(self.path);
        self.snapshot.deinit();
    }
};
/// 경로 필터·문서 신원은 owner가 검사한 값이다. occupy가 성공한 뒤 capture 실패도 점유를 유지한다.
pub fn capture(a: std.mem.Allocator, state: *search.request.State, path: []const u8, document: search.request.DocumentIdentity, composition: u64, file: *const editor.edit_doc.EditableFile) !Captured {
    try state.occupy(a, path);
    const owned = try a.dupe(u8, try search.request.relativePath(path));
    return .{ .path = owned, .source = .{ .model = .{ .document = document, .revision = file.revision, .composition = composition } }, .snapshot = file.snapshot() };
}

/// 공유 view는 같은 문서 신원으로 한 번만 잡는다. 동일 경로의 독립 문서는 합치지 않는다.
pub fn captureUnique(a: std.mem.Allocator, state: *search.request.State, models: *std.ArrayList(Captured), path: []const u8, document: search.request.DocumentIdentity, composition: u64, file: *const editor.edit_doc.EditableFile, retained_bytes: *usize, snapshot_budget: usize) !bool {
    try state.occupy(a, path);
    for (models.items) |existing| if (std.meta.eql(existing.source.model.document, document)) return false;
    const size = file.buf.byteLen();
    if (size > snapshot_budget -| retained_bytes.*) {
        state.excluded += 1;
        return false;
    }
    var captured = capture(a, state, path, document, composition, file) catch |err| {
        state.excluded += 1;
        return err;
    };
    errdefer captured.deinit(a);
    models.append(a, captured) catch |err| {
        state.excluded += 1;
        return err;
    };
    retained_bytes.* += size;
    return true;
}

fn point(content: []const u8, from: usize, to: usize, current: *search.event.Position, control: anytype) !void {
    for (content[from..to], 0..) |byte, i| {
        if (i & 0x3fff == 0 and control.cancelled.load(.acquire)) return error.Cancelled;
        if (byte == '\n') {
            current.line = try std.math.add(u32, current.line, 1);
            current.byte = 0;
        } else current.byte = try std.math.add(u32, current.byte, 1);
    }
}
/// 제한은 호출자가 실측한 실행 예산이다. snapshot byte 상한과 미리보기 상한을 구분한다.
pub fn run(a: std.mem.Allocator, captured: *const Captured, query: []const u8, opts: search.query.Options, control: anytype, snapshot_bytes: usize, preview_bytes: usize, context: anytype, callback: anytype) !void {
    const size = captured.snapshot.byteLen();
    if (size > snapshot_bytes) return error.SnapshotBudget;
    if (query.len == 0 or !std.unicode.utf8ValidateSlice(query)) return error.InvalidQuery;
    const content = try a.alloc(u8, size);
    defer a.free(content);
    // 메인 스레드 복사 없이 worker에서 분할하며 각 복사 사이에 취소를 확인한다.
    var copied: usize = 0;
    while (copied < size) {
        if (control.cancelled.load(.acquire)) return error.Cancelled;
        const end = @min(copied + 512 * 1024, size);
        const chunk = try captured.snapshot.copyRange(a, copied, end);
        defer a.free(chunk);
        @memcpy(content[copied..end], chunk);
        copied = end;
    }
    var regex: ?editor.find.regex.Pattern = if (opts.regex) try editor.find.regex.Pattern.initDocument(query, opts.match_case, .anycrlf) else null;
    defer if (regex) |*pattern| pattern.deinit();
    var from: usize = 0;
    var positioned: usize = 0;
    var position: search.event.Position = .{ .line = 0, .byte = 0 };
    while (from <= content.len) {
        if (control.cancelled.load(.acquire)) return error.Cancelled;
        const span = if (regex) |*pattern| blk: {
            const found = (try pattern.matchValidated(content, from, false)) orelse break;
            from = if (found.end == content.len) content.len + 1 else if (found.end > found.start) found.end else found.end + (std.unicode.utf8ByteSequenceLength(content[found.end]) catch return error.InvalidUtf8);
            if (opts.whole_word and !editor.find.isWholeWord(content, found.start, found.end)) continue;
            break :blk found;
        } else blk: {
            if (from >= content.len) break;
            const found = (try editor.find.nextLiteralBatch(content, query, .{ .match_case = opts.match_case, .whole_word = opts.whole_word }, &from, 64 * 1024, &control.cancelled)) orelse continue;
            break :blk found;
        };
        try point(content, positioned, span.start, &position, control);
        const start = position;
        try point(content, span.start, span.end, &position, control);
        positioned = span.end;
        const end = position;
        // 미리보기는 매치 시작부터 제한한다. 검색 subject를 자르지 않으며 좌표는 원문 축이다.
        var preview_end = @min(span.start +| preview_bytes, content.len);
        while (preview_end > span.start and preview_end < content.len and content[preview_end] & 0xc0 == 0x80) preview_end -= 1;
        var match = try makeMatch(a, captured.path, content[span.start..preview_end], start, end);
        match.text_truncated = preview_end < content.len;
        var transferred = false;
        defer if (!transferred) match.deinit(a);
        transferred = try callback(context, captured.source, match);
    }
}

fn makeMatch(a: std.mem.Allocator, name: []const u8, preview: []const u8, start: search.event.Position, end: search.event.Position) !search.event.Match {
    const path = try a.dupe(u8, name);
    errdefer a.free(path);
    const text = try a.dupe(u8, preview);
    errdefer a.free(text);
    const ranges = try a.alloc(search.event.Range, 1);
    ranges[0] = .{ .start = start, .end = end };
    return .{ .path = path, .text = text, .ranges = ranges, .text_start = start };
}
