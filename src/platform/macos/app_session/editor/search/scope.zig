//! 열린 문서에는 디스크 ignore를 적용하지 않는다. 명시적 glob과 고정 VCS 제외만 검사한다.
const std = @import("std");
const editor = @import("maru").session.editor;
const regex = editor.find.regex;
const Rule = struct { pattern: regex.Pattern, descendants: bool };
pub const Scope = struct {
    includes: std.ArrayList(Rule) = .empty,
    excludes: std.ArrayList(Rule) = .empty,
    pub fn deinit(self: *Scope, a: std.mem.Allocator) void {
        for (self.includes.items) |*rule| rule.pattern.deinit();
        for (self.excludes.items) |*rule| rule.pattern.deinit();
        self.includes.deinit(a);
        self.excludes.deinit(a);
    }
    /// 두 엔진이 같은 argv glob을 소비한다. traversal용 wildcard prefix도 결과 판정에 반영한다.
    pub fn fromArgs(a: std.mem.Allocator, args: []const []const u8, ignore_glob_case: bool) !Scope {
        var scope: Scope = .{};
        errdefer scope.deinit(a);
        var i: usize = 1;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--regexp") or std.mem.eql(u8, args[i], "--")) break;
            if (!std.mem.eql(u8, args[i], "--glob")) continue;
            i += 1;
            if (i >= args.len) return error.InvalidGlob;
            const glob = args[i];
            if (glob.len == 0) return error.InvalidGlob;
            const exclude = glob[0] == '!';
            try append(a, if (exclude) &scope.excludes else &scope.includes, if (exclude) glob[1..] else glob, exclude, ignore_glob_case);
        }
        return scope;
    }
    pub fn accepts(self: *Scope, path: []const u8) !bool {
        if (path.len == 0 or std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, 0) != null or !std.unicode.utf8ValidateSlice(path)) return false;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, "..")) return false;
            for ([_][]const u8{ ".git", ".svn", ".hg", "CVS" }) |vcs| if (std.mem.eql(u8, part, vcs)) return false;
        }
        for (self.excludes.items) |*rule| if (try matches(rule, path)) return false;
        if (self.includes.items.len == 0) return true;
        for (self.includes.items) |*rule| if (try matches(rule, path)) return true;
        return false;
    }
};
fn matches(rule: *Rule, path: []const u8) !bool {
    if (try rule.pattern.matchValidated(path, 0, false) != null) return true;
    if (rule.descendants) for (path, 0..) |byte, i| {
        if (byte == '/' and try rule.pattern.matchValidated(path[0..i], 0, false) != null) return true;
    };
    return false;
}
fn append(a: std.mem.Allocator, out: *std.ArrayList(Rule), glob: []const u8, descendants: bool, ignore_case: bool) !void {
    const converted = try translate(a, glob);
    defer a.free(converted);
    var pattern = try regex.Pattern.initBytes(converted, !ignore_case);
    errdefer pattern.deinit();
    try out.append(a, .{ .pattern = pattern, .descendants = descendants });
}
fn translate(a: std.mem.Allocator, input: []const u8) ![]u8 {
    if (input.len == 0 or std.mem.indexOfScalar(u8, input, 0) != null) return error.InvalidGlob;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, "(?s)\\A");
    // anchorGlob이 고정하지 않는 slash 없는 ** 패턴은 어느 깊이의 파일명에도 적용된다.
    if (std.mem.startsWith(u8, input, "**") and std.mem.indexOfScalar(u8, input, '/') == null) try out.appendSlice(a, "(?:.*/)?");
    var i: usize = if (input[0] == '/') 1 else 0;
    var branches: std.ArrayList(usize) = .empty;
    defer branches.deinit(a);
    while (i < input.len) : (i += 1) {
        const byte = input[i];
        switch (byte) {
            '*' => {
                if (i + 1 < input.len and input[i + 1] == '*') {
                    const component_start = i == 0 or input[i - 1] == '/' or input[i - 1] == '{' or input[i - 1] == ',';
                    i += 1;
                    if (component_start and i + 1 < input.len and input[i + 1] == '/') {
                        i += 1;
                        try out.appendSlice(a, "(?:.*/)?");
                    } else if (component_start and (i + 1 == input.len or input[i + 1] == '}' or input[i + 1] == ',')) try out.appendSlice(a, ".*") else try out.appendSlice(a, "[^/]*");
                } else try out.appendSlice(a, "[^/]*");
            },
            '?' => try out.appendSlice(a, "[^/]"),
            '{' => {
                try out.appendSlice(a, "(?:");
                try branches.append(a, out.items.len);
            },
            '}' => {
                if (branches.items.len == 0) return error.InvalidGlob;
                if (out.items.len == branches.items[branches.items.len - 1]) try out.appendSlice(a, "(?!)");
                _ = branches.pop();
                try out.append(a, ')');
            },
            ',' => {
                if (branches.items.len > 0) {
                    const last = branches.items.len - 1;
                    // glob의 빈 대안은 빈 문자열 매치가 아니라 무시되는 선택지다.
                    if (out.items.len == branches.items[last]) try out.appendSlice(a, "(?!)");
                    try out.append(a, '|');
                    branches.items[last] = out.items.len;
                } else try out.append(a, byte);
            },
            '[' => {
                try out.append(a, '[');
                i += 1;
                if (i >= input.len) return error.InvalidGlob;
                if (input[i] == '!') {
                    try out.append(a, '^');
                    i += 1;
                }
                const first = i;
                while (i < input.len and (input[i] != ']' or i == first)) : (i += 1) {
                    // 클래스 안의 역슬래시는 literal이며 다음 문자를 소비하지 않는다.
                    if (input[i] == '\\') try out.append(a, '\\');
                    try out.append(a, input[i]);
                }
                if (i >= input.len) return error.InvalidGlob;
                try out.append(a, ']');
            },
            '\\' => {
                i += 1;
                if (i >= input.len) return error.InvalidGlob;
                if (std.mem.indexOfScalar(u8, ".+()^$|[]{}*?\\", input[i]) != null) try out.append(a, '\\');
                try out.append(a, input[i]);
            },
            else => {
                if (std.mem.indexOfScalar(u8, ".+()^$|]", byte) != null) try out.append(a, '\\');
                try out.append(a, byte);
            },
        }
    }
    if (branches.items.len != 0) return error.InvalidGlob;
    try out.appendSlice(a, "\\z");
    return out.toOwnedSlice(a);
}
