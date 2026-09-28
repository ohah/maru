//! PCRE2-backed, single-logical-line editor search. The compiled pattern and limits live here;
//! the ordinary find path remains independent so its literal Unicode matching does not drift.
const std = @import("std");
const c = @cImport({
    @cDefine("PCRE2_CODE_UNIT_WIDTH", "8");
    @cDefine("PCRE2_STATIC", "1");
    @cInclude("pcre2.h.generic");
});

pub const Error = error{ InvalidPattern, InvalidUtf8, MatchLimit, EngineFailure, OutOfMemory };
pub const Span = struct { start: usize, end: usize };

pub const Pattern = struct {
    code: *c.pcre2_code_8,
    data: *c.pcre2_match_data_8,
    context: *c.pcre2_match_context_8,

    pub fn init(pattern: []const u8, match_case: bool) Error!Pattern {
        if (!std.unicode.utf8ValidateSlice(pattern)) return error.InvalidUtf8;
        var error_code: c_int = 0;
        var error_offset: usize = 0;
        const options: u32 = c.PCRE2_UTF | c.PCRE2_UCP | (if (match_case) @as(u32, 0) else c.PCRE2_CASELESS);
        const code = c.pcre2_compile_8(pattern.ptr, pattern.len, options, &error_code, &error_offset, null) orelse return error.InvalidPattern;
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

    /// Caller has validated this logical line once before iterating its matches.
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
        var found = (try self.match(line, span.start, true)) orelse return error.EngineFailure;
        var nonempty_retry = false;
        if (found.end != span.end and found.start == found.end) {
            found = (try self.matchNonEmptyAtStart(line, span.start)) orelse return error.EngineFailure;
            nonempty_retry = true;
        }
        if (found.start != span.start or found.end != span.end) return error.EngineFailure;
        var capacity = replacement.len + line.len + 64;
        var output = try allocator.alloc(u8, capacity);
        errdefer allocator.free(output);
        const options: u32 = c.PCRE2_ANCHORED | c.PCRE2_NO_UTF_CHECK |
            (if (nonempty_retry) @as(u32, c.PCRE2_NOTEMPTY_ATSTART) else 0) |
            c.PCRE2_SUBSTITUTE_MATCHED | c.PCRE2_SUBSTITUTE_REPLACEMENT_ONLY |
            c.PCRE2_SUBSTITUTE_OVERFLOW_LENGTH;
        var rc = c.pcre2_substitute_8(self.code, line.ptr, line.len, span.start, options, self.data, self.context, replacement.ptr, replacement.len, output.ptr, &capacity);
        if (rc == c.PCRE2_ERROR_NOMEMORY) {
            output = try allocator.realloc(output, capacity);
            rc = c.pcre2_substitute_8(self.code, line.ptr, line.len, span.start, options, self.data, self.context, replacement.ptr, replacement.len, output.ptr, &capacity);
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
