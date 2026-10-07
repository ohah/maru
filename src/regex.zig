//! 터미널 논리 줄과 편집기 문서 전체가 공유하는 PCRE2 컴파일·매치·치환 경계다.
//! 문서 모드는 줄 앵커와 줄바꿈 정책을 명시하며, 평문 검색은 별도 경로를 유지한다.
const std = @import("std");
const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cDefine("PCRE2_STATIC", "1");
    @cInclude("pcre2.h.generic");
});

pub const Error = error{ InvalidPattern, InvalidUtf8, MatchLimit, EngineFailure, OutOfMemory };
pub const Span = struct { start: usize, end: usize };
pub const Newline = enum { lf, anycrlf };

pub const Pattern = struct {
    code: *c.pcre2_code_8,
    data: *c.pcre2_match_data_8,
    context: *c.pcre2_match_context_8,

    pub fn init(pattern: []const u8, match_case: bool) Error!Pattern {
        return initWithMode(pattern, match_case, null, true);
    }

    /// 문서 전체를 같은 subject로 검색하면 문서 앵커와 줄 앵커를 함께 처리할 수 있다.
    pub fn initDocument(pattern: []const u8, match_case: bool, newline: Newline) Error!Pattern {
        return initWithMode(pattern, match_case, newline, true);
    }

    /// 파일 glob은 ripgrep과 동일하게 UTF-8 코드포인트가 아닌 원문 바이트를 판정한다.
    pub fn initBytes(pattern: []const u8, match_case: bool) Error!Pattern {
        return initWithMode(pattern, match_case, null, false);
    }

    fn initWithMode(pattern: []const u8, match_case: bool, newline: ?Newline, utf: bool) Error!Pattern {
        if (!std.unicode.utf8ValidateSlice(pattern)) return error.InvalidUtf8;
        var error_code: c_int = 0;
        var error_offset: usize = 0;
        // 마지막 개행 뒤의 빈 편집기 줄에도 ^가 있어야 하므로 문서 모드는 ALT_CIRCUMFLEX를 켠다.
        const options: u32 = (if (utf) @as(u32, c.PCRE2_UTF | c.PCRE2_UCP) else 0) |
            (if (match_case) @as(u32, 0) else c.PCRE2_CASELESS) |
            (if (newline != null) @as(u32, c.PCRE2_MULTILINE | c.PCRE2_ALT_CIRCUMFLEX) else 0);
        const compile_context = if (newline != null)
            c.pcre2_compile_context_create_8(null) orelse return error.OutOfMemory
        else
            null;
        defer if (compile_context) |context| c.pcre2_compile_context_free_8(context);
        if (compile_context) |context| {
            const value: u32 = switch (newline.?) {
                .lf => c.PCRE2_NEWLINE_LF,
                .anycrlf => c.PCRE2_NEWLINE_ANYCRLF,
            };
            if (c.pcre2_set_newline_8(context, value) != 0) return error.EngineFailure;
        }
        const code = c.pcre2_compile_8(pattern.ptr, pattern.len, options, &error_code, &error_offset, compile_context) orelse return error.InvalidPattern;
        errdefer c.pcre2_code_free_8(code);
        const data = c.pcre2_match_data_create_from_pattern_8(code, null) orelse return error.OutOfMemory;
        errdefer c.pcre2_match_data_free_8(data);
        const context = c.pcre2_match_context_create_8(null) orelse return error.OutOfMemory;
        errdefer c.pcre2_match_context_free_8(context);
        // Bound pathological backtracking for an interactive field. Exceeding the bound is an
        // explicit error, never an apparently successful zero-match result.
        if (c.pcre2_set_match_limit_8(context, 1_000_000) != 0 or
            c.pcre2_set_depth_limit_8(context, 10_000) != 0) return error.EngineFailure;
        return .{ .code = code, .data = data, .context = context };
    }

    pub fn deinit(self: *Pattern) void {
        c.pcre2_match_context_free_8(self.context);
        c.pcre2_match_data_free_8(self.data);
        c.pcre2_code_free_8(self.code);
    }

    pub fn match(self: *Pattern, line: []const u8, from: usize, anchored: bool) Error!?Span {
        // PCRE2 UTF mode rejects malformed document bytes. The editor normally validates on
        // opening; keep this boundary honest if a future edit path admits malformed input.
        if (!std.unicode.utf8ValidateSlice(line)) return error.InvalidUtf8;
        return self.matchValidated(line, from, anchored);
    }

    /// 호출자가 같은 subject의 UTF-8을 한 번 검증한 뒤 매치를 순회한다.
    pub fn matchValidated(self: *Pattern, line: []const u8, from: usize, anchored: bool) Error!?Span {
        return self.matchWithOptions(line, from, if (anchored) c.PCRE2_ANCHORED else 0);
    }

    /// Prefer a consuming alternative when an empty assertion and text match at one byte offset.
    pub fn matchNonEmptyAtStart(self: *Pattern, line: []const u8, from: usize) Error!?Span {
        return self.matchWithOptions(line, from, c.PCRE2_ANCHORED | c.PCRE2_NOTEMPTY_ATSTART);
    }

    fn matchWithOptions(self: *Pattern, line: []const u8, from: usize, options_extra: u32) Error!?Span {
        if (from > line.len) return null;
        const options: u32 = c.PCRE2_NO_UTF_CHECK | options_extra;
        const rc = c.pcre2_match_8(self.code, line.ptr, line.len, from, options, self.data, self.context);
        if (rc == c.PCRE2_ERROR_NOMATCH) return null;
        if (rc == c.PCRE2_ERROR_MATCHLIMIT or rc == c.PCRE2_ERROR_DEPTHLIMIT or rc == c.PCRE2_ERROR_HEAPLIMIT)
            return error.MatchLimit;
        if (rc < 0) return error.EngineFailure;
        const offsets = c.pcre2_get_ovector_pointer_8(self.data);
        // \C can match a single UTF-8 code unit. Editor selections and the next search offset
        // require codepoint boundaries, so reject such spans instead of painting half a glyph.
        if (!utf8Boundary(line, offsets[0]) or !utf8Boundary(line, offsets[1])) return error.EngineFailure;
        return .{ .start = offsets[0], .end = offsets[1] };
    }

    /// Expand PCRE2 replacement references for exactly the span previously found in this line.
    /// Rematching against the whole line preserves lookbehind and named capture context.
    pub fn expand(self: *Pattern, allocator: std.mem.Allocator, line: []const u8, span: Span, replacement: []const u8) Error![]u8 {
        if (!std.unicode.utf8ValidateSlice(line)) return error.InvalidUtf8;
        return self.expandInternal(allocator, line, span, replacement, span.start, true);
    }

    /// \K·\G도 재현하려면 보고된 시작점이 아니라 원래 검색 시작점을 보존해야 한다.
    pub fn expandFrom(self: *Pattern, allocator: std.mem.Allocator, subject: []const u8, span: Span, replacement: []const u8, from: usize) Error![]u8 {
        if (!std.unicode.utf8ValidateSlice(subject)) return error.InvalidUtf8;
        return self.expandFromValidated(allocator, subject, span, replacement, from);
    }

    /// 같은 원문이 순회 도중 바뀌지 않고 UTF-8 검증을 마친 경우에만 사용한다.
    pub fn expandFromValidated(self: *Pattern, allocator: std.mem.Allocator, subject: []const u8, span: Span, replacement: []const u8, from: usize) Error![]u8 {
        return self.expandInternal(allocator, subject, span, replacement, from, false);
    }

    fn expandInternal(self: *Pattern, allocator: std.mem.Allocator, line: []const u8, span: Span, replacement: []const u8, from: usize, anchored: bool) Error![]u8 {
        var found = (try self.matchValidated(line, from, anchored)) orelse return error.EngineFailure;
        var match_from = from;
        var match_anchored = anchored;
        var nonempty_retry = false;
        if (found.end != span.end and found.start == found.end) {
            found = (try self.matchNonEmptyAtStart(line, span.start)) orelse return error.EngineFailure;
            nonempty_retry = true;
            match_from = span.start;
            match_anchored = true;
        }
        if (found.start != span.start or found.end != span.end) return error.EngineFailure;
        // 문서 전체를 받더라도 매치마다 문서 크기의 임시 출력을 할당하지 않는다.
        var capacity = std.math.add(usize, replacement.len, 64) catch return error.OutOfMemory;
        var output = try allocator.alloc(u8, capacity);
        errdefer allocator.free(output);
        const options: u32 = c.PCRE2_NO_UTF_CHECK | (if (match_anchored) @as(u32, c.PCRE2_ANCHORED) else 0) |
            (if (nonempty_retry) @as(u32, c.PCRE2_NOTEMPTY_ATSTART) else 0) |
            c.PCRE2_SUBSTITUTE_MATCHED | c.PCRE2_SUBSTITUTE_REPLACEMENT_ONLY |
            c.PCRE2_SUBSTITUTE_OVERFLOW_LENGTH;
        var rc = c.pcre2_substitute_8(self.code, line.ptr, line.len, match_from, options, self.data, self.context, replacement.ptr, replacement.len, output.ptr, &capacity);
        if (rc == c.PCRE2_ERROR_NOMEMORY) {
            output = try allocator.realloc(output, capacity);
            rc = c.pcre2_substitute_8(self.code, line.ptr, line.len, match_from, options, self.data, self.context, replacement.ptr, replacement.len, output.ptr, &capacity);
        }
        if (rc < 0) return error.EngineFailure;
        return try allocator.realloc(output, capacity);
    }
};

fn utf8Boundary(line: []const u8, offset: usize) bool {
    return offset <= line.len and (offset == 0 or offset == line.len or line[offset] & 0xc0 != 0x80);
}

test "PCRE2 replacement uses named and numbered captures" {
    var pattern = try Pattern.init("(?<name>foo)-(\\d+)", true);
    defer pattern.deinit();
    const line = "x foo-42 y";
    const span = (try pattern.match(line, 0, false)).?;
    const output = try pattern.expand(std.testing.allocator, line, span, "${name}:$2:$$");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("foo:42:$", output);
}

test "PCRE2 replacement can expand consuming alternative after empty assertion" {
    var pattern = try Pattern.init("^|(?<word>foo)", true);
    defer pattern.deinit();
    const line = "foo";
    const span = (try pattern.matchNonEmptyAtStart(line, 0)).?;
    const output = try pattern.expand(std.testing.allocator, line, span, "${word}!");
    defer std.testing.allocator.free(output);
    try std.testing.expectEqualStrings("foo!", output);
}

test "PCRE2 byte-unit pattern cannot produce a partial UTF-8 editor selection" {
    var pattern = try Pattern.init("\\C", true);
    defer pattern.deinit();
    try std.testing.expectError(error.EngineFailure, pattern.match("한", 0, false));
}
