//! 프로젝트 디스크 검색의 argv 준비. shell이나 사용자 rg 설정을 경유하지 않는다.
//! VS Code의 공개 검색 동작을 따르며 구현 표현은 독립 작성한다.
const std = @import("std");

// VS Code 데스크톱 files.exclude + search.exclude의 공개 기본값이다.
pub const default_excludes = [_][]const u8{ "**/.git", "**/.svn", "**/.hg", "**/CVS", "**/.DS_Store", "**/Thumbs.db", "**/node_modules", "**/bower_components", "**/*.code-search" };
pub const fixed_vcs_excludes = [_][]const u8{ "**/.git", "**/.svn", "**/.hg", "**/CVS" };
pub const Options = struct {
    match_case: bool = false,
    whole_word: bool = false,
    regex: bool = false,
    multiline: bool = false,
    ignore_files: bool = true,
    ignore_parent: bool = false,
    ignore_global: bool = false,
    follow_symlinks: bool = true,
    ignore_glob_case: bool = false,
    includes: []const []const u8 = &.{},
    excludes: []const []const u8 = &default_excludes,
};

/// 목록 쉼표와 경로 slash는 같은 glob 범위 규칙을 따른다. 실제 매칭은 ripgrep에 맡긴다.
pub const GlobScope = struct {
    braces: usize = 0,
    in_class: bool = false,
    first_in_class: bool = false,
    negator_allowed: bool = false,
    escaped: bool = false,
    pub fn feed(self: *GlobScope, byte: u8) !bool {
        if (self.in_class) {
            if (self.negator_allowed) {
                self.negator_allowed = false;
                if (byte == '!' or byte == '^') return false;
            }
            if (byte == ']' and !self.first_in_class) self.in_class = false else self.first_in_class = false;
            return false;
        }
        if (self.escaped) {
            self.escaped = false;
            return byte == '/' and self.braces == 0;
        }
        switch (byte) {
            '\\' => {
                self.escaped = true;
                return false;
            },
            '[' => {
                self.in_class = true;
                self.first_in_class = true;
                self.negator_allowed = true;
                return false;
            },
            '{' => {
                self.braces += 1;
                return false;
            },
            '}' => {
                if (self.braces == 0) return error.InvalidInclude;
                self.braces -= 1;
                return false;
            },
            else => return self.braces == 0,
        }
    }
    pub fn finish(self: GlobScope) !void {
        if (self.braces != 0 or self.in_class or self.escaped) return error.InvalidInclude;
    }
};

pub fn splitList(a: std.mem.Allocator, input: []const u8, out: *std.ArrayList([]const u8)) !void {
    var scope: GlobScope = .{};
    var first: usize = 0;
    for (input, 0..) |byte, index| {
        const outside = try scope.feed(byte);
        if (byte == ',' and outside) {
            const value = std.mem.trim(u8, input[first..index], " \t\r\n");
            if (value.len != 0) try out.append(a, value);
            first = index + 1;
        }
    }
    try scope.finish();
    const value = std.mem.trim(u8, input[first..], " \t\r\n");
    if (value.len != 0) try out.append(a, value);
}

pub const Args = struct {
    items: std.ArrayList([]const u8) = .empty,
    pub fn deinit(self: *Args, a: std.mem.Allocator) void {
        for (self.items.items) |item| a.free(item);
        self.items.deinit(a);
        self.* = .{};
    }
    pub fn add(self: *Args, a: std.mem.Allocator, value: []const u8) !void {
        const copy = try a.dupe(u8, value);
        errdefer a.free(copy);
        try self.items.append(a, copy);
    }
};

fn asciiWord(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '_';
}

/// 일반 검색을 정규식으로 전달해야 할 때만 문법 문자를 인용한다.
fn pattern(a: std.mem.Allocator, query: []const u8, opts: Options) ![]u8 {
    var bytes: std.ArrayList(u8) = .empty;
    errdefer bytes.deinit(a);
    for (query) |byte| {
        if (!opts.regex and std.mem.indexOfScalar(u8, "\\.*+?[](){}^$|", byte) != null) try bytes.append(a, '\\');
        try bytes.append(a, byte);
    }
    // 디스크는 JS의 ASCII word 여부로 패턴 양끝에 경계를 더하는 VS Code 정책이다.
    // 열린 모델의 기본 구분자 판정과 다르며 rg -w로 대신하지 않는다.
    const left = opts.whole_word and bytes.items.len != 0 and asciiWord(bytes.items[0]);
    const right = opts.whole_word and bytes.items.len != 0 and asciiWord(bytes.items[bytes.items.len - 1]);
    if (left) try bytes.insertSlice(a, 0, "\\b");
    if (right) try bytes.appendSlice(a, "\\b");
    return bytes.toOwnedSlice(a);
}

/// root 상대 glob은 고정하고 **로 시작한 패턴은 하위 깊이를 보존한다.
fn addGlob(args: *Args, a: std.mem.Allocator, glob: []const u8, exclude: bool) !void {
    const anchored = std.mem.startsWith(u8, glob, "**") or std.mem.startsWith(u8, glob, "/");
    const value = try std.fmt.allocPrint(a, "{s}{s}{s}", .{ if (exclude) "!" else "", if (anchored) "" else "/", glob });
    defer a.free(value);
    try args.add(a, "--glob");
    try args.add(a, value);
}

fn addInclude(args: *Args, a: std.mem.Allocator, glob: []const u8) !void {
    if (glob.len == 0 or glob[0] == '!' or std.mem.indexOfScalar(u8, glob, 0) != null) return error.InvalidInclude;
    if (std.mem.startsWith(u8, glob, "**")) return addGlob(args, a, glob, false);
    // 경로의 부모도 허용해야 traverser가 그 아래를 볼 수 있다. brace/class 안 slash는 분해하지 않는다.
    var scope: GlobScope = .{};
    for (glob, 0..) |byte, index| {
        const escaped = scope.escaped;
        if (try scope.feed(byte) and byte == '/' and index != 0) {
            const end = index - @intFromBool(escaped);
            if (end != 0) try addGlob(args, a, glob[0..end], false);
        }
    }
    try scope.finish();
    try addGlob(args, a, glob, false);
    const descendants = try std.fmt.allocPrint(a, "{s}{s}**", .{ glob, if (std.mem.endsWith(u8, glob, "/")) "" else "/" });
    defer a.free(descendants);
    try addGlob(args, a, descendants, false);
}

fn isMultiline(query: []const u8, regex: bool) bool {
    var escaped = false;
    for (query) |byte| {
        if (byte == '\n') return true;
        if (regex and escaped) {
            escaped = false;
            if (byte == 'n' or byte == 'r' or byte == 'W') return true;
        } else if (regex and byte == '\\') escaped = true;
    }
    return false;
}

pub fn build(a: std.mem.Allocator, exe: []const u8, query: []const u8, opts: Options) !Args {
    if (!std.fs.path.isAbsolute(exe) or std.mem.indexOfScalar(u8, exe, 0) != null) return error.UntrustedExecutable;
    if (query.len == 0) return error.EmptyQuery;
    if (std.mem.indexOfScalar(u8, query, 0) != null) return error.InvalidQuery;
    if (!std.unicode.utf8ValidateSlice(query)) return error.InvalidUtf8;
    var args: Args = .{};
    errdefer args.deinit(a);
    for ([_][]const u8{ exe, "--hidden", "--no-require-git", "--no-config", "--json", "--crlf", if (opts.match_case) "--case-sensitive" else "--ignore-case" }) |arg| try args.add(a, arg);
    if (opts.ignore_glob_case) {
        try args.add(a, "--glob-case-insensitive");
        try args.add(a, "--ignore-file-case-insensitive");
    }
    if (!opts.ignore_files) try args.add(a, "--no-ignore");
    if (!opts.ignore_parent) try args.add(a, "--no-ignore-parent");
    if (!opts.ignore_global) try args.add(a, "--no-ignore-global");
    if (opts.follow_symlinks) try args.add(a, "--follow");
    for (opts.includes) |glob| try addInclude(&args, a, glob);
    for (opts.excludes) |glob| {
        if (glob.len == 0 or std.mem.indexOfScalar(u8, glob, 0) != null) return error.InvalidExclude;
        try addGlob(&args, a, glob, true);
    }
    // 사용자 include·exclude·ignore 해제보다 항상 마지막에 VCS 내부 제외를 적용한다.
    for (fixed_vcs_excludes) |glob| try addGlob(&args, a, glob, true);
    const multiline = opts.multiline or isMultiline(query, opts.regex);
    if (multiline) try args.add(a, "--multiline");
    if (opts.regex or opts.whole_word or multiline) {
        try args.add(a, "--engine=auto");
        const prepared = try pattern(a, query, opts);
        defer a.free(prepared);
        try args.add(a, "--regexp");
        try args.add(a, prepared);
    } else {
        try args.add(a, "--fixed-strings");
        try args.add(a, "--regexp");
        try args.add(a, query);
    }
    try args.add(a, "--");
    try args.add(a, ".");
    return args;
}

/// 파일 후보에도 본문 검색과 같은 root 상대 glob·ignore argv를 쓴다.
pub fn buildFiles(a: std.mem.Allocator, exe: []const u8, opts: Options) !Args {
    var search_args = try build(a, exe, "candidate", opts);
    defer search_args.deinit(a);
    return filesFromSearch(a, &search_args);
}

/// 이미 소유한 glob argv에서 후보 열거 옵션만 분리한다.
pub fn filesFromSearch(a: std.mem.Allocator, search_args: *const Args) !Args {
    var args: Args = .{};
    errdefer args.deinit(a);
    var i: usize = 0;
    while (i < search_args.items.items.len - 4) : (i += 1) {
        const arg = search_args.items.items[i];
        if (std.mem.eql(u8, arg, "--glob")) {
            try args.add(a, arg);
            i += 1;
            try args.add(a, search_args.items.items[i]);
            continue;
        }
        if (std.mem.eql(u8, arg, "--json") or std.mem.eql(u8, arg, "--fixed-strings") or std.mem.eql(u8, arg, "--engine=auto") or std.mem.eql(u8, arg, "--multiline") or std.mem.eql(u8, arg, "--crlf")) continue;
        try args.add(a, arg);
    }
    try args.add(a, "--files");
    try args.add(a, "--null");
    try args.add(a, "--");
    try args.add(a, ".");
    return args;
}

test "PSQ1 argv owns query and does not execute query flags" {
    const a = std.testing.allocator;
    var args = try build(a, "/bundle/rg", "--", .{});
    defer args.deinit(a);
    try std.testing.expectEqualStrings("--regexp", args.items.items[args.items.items.len - 4]);
    try std.testing.expectEqualStrings("--", args.items.items[args.items.items.len - 3]);
    try std.testing.expectError(error.UntrustedExecutable, build(a, "rg", "foo", .{}));
    try std.testing.expectError(error.EmptyQuery, build(a, "/bundle/rg", "", .{}));
    try std.testing.expectError(error.InvalidQuery, build(a, "/bundle/rg", "foo\x00bar", .{}));
    try std.testing.expectError(error.UntrustedExecutable, build(a, "/bundle/rg\x00other", "foo", .{}));
}

test "PSQ2 word patterns preserve disk search policy" {
    const a = std.testing.allocator;
    for ([_]struct { query: []const u8, wanted: []const u8, regex: bool }{
        .{ .query = "foo", .wanted = "\\bfoo\\b", .regex = false },
        .{ .query = "foo.bar", .wanted = "\\bfoo\\.bar\\b", .regex = false },
        .{ .query = "^foo$", .wanted = "^foo$", .regex = true },
        .{ .query = "foo|bar", .wanted = "\\bfoo|bar\\b", .regex = true },
        .{ .query = "é", .wanted = "é", .regex = false },
    }) |case| {
        const found = try pattern(a, case.query, .{ .whole_word = true, .regex = case.regex });
        defer a.free(found);
        try std.testing.expectEqualStrings(case.wanted, found);
    }
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var args = try build(alloc, "/bundle/rg", "foo.bar", .{ .whole_word = true, .includes = &.{"*.zig"}, .excludes = &.{"build/**"} });
            defer args.deinit(alloc);
        }
    }.run, .{});
}

test "PSQ3 후보 argv는 glob 값과 ignore 순서를 보존하고 패턴을 실행하지 않는다" {
    const a = std.testing.allocator;
    var args = try buildFiles(a, "/bundle/rg", .{ .regex = true, .includes = &.{"--regexp"}, .excludes = &.{"**/*.tmp"} });
    defer args.deinit(a);
    try std.testing.expectEqualStrings("--files", args.items.items[args.items.items.len - 4]);
    try std.testing.expectEqualStrings("--null", args.items.items[args.items.items.len - 3]);
    for (args.items.items, 0..) |arg, index| {
        try std.testing.expect(!std.mem.eql(u8, arg, "--json") and !std.mem.eql(u8, arg, "--regexp"));
        if (std.mem.eql(u8, arg, "--glob")) try std.testing.expect(index + 1 < args.items.items.len);
    }
    try std.testing.checkAllAllocationFailures(a, struct {
        fn run(alloc: std.mem.Allocator) !void {
            var owned = try buildFiles(alloc, "/bundle/rg", .{ .includes = &.{"src/**"} });
            defer owned.deinit(alloc);
        }
    }.run, .{});
}
