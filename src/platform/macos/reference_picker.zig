//! 참조 피커 — **platform 전용 순수 로직**(docs/editor-surface-tooling.md §8.2l · native-editor-ui.md §7.5 「피커는 팔레트를 다시 쓴다」의
//! 세 번째 소비자). UI 상태(open/query/selected)는 chrome 의 `palette.State` 가 들고, 여기엔 그것이 만질 수 없는 것만 있다 —
//! 서버가 준 위치 목록을 **행으로 굳히고**(정렬·중복·상한·미리보기·root 밖) 쿼리로 좁히는 것.
//!
//! **행은 값이다**(§7.5 — 공유 버퍼의 인덱스를 들지 않는다): 경로·미리보기·보조 텍스트는 이 모듈이 할당한 사본이고, 응답 JSON 이나
//! 파일 본문을 빌리지 않는다.
//!
//! **미리보기는 root 안 파일만 읽는다**(§5.2 「표시와 접근을 가른다」 · §8.2 「URI 를 받았다는 이유로 grant 가 확대되지 않는다」) — 파일은
//! `Reader` 가 주고(제품은 디스크·현재 문서, 판정자는 표), root 밖은 제목이 「루트 밖」이며 읽지 않는다. 파일 수·크기 상한을 넘으면 미리보기
//! 없이 경로만.
const std = @import("std");
const symbol_picker = @import("symbol_picker.zig");

/// 서버가 준 위치 하나(경로로 풀린 것). `path` 는 절대 경로.
pub const Loc = struct { path: []const u8, line: u32, character: u32 };

/// 굳힌 행 하나.
pub const Row = struct {
    /// 제목 — 그 줄의 본문(앞 공백 뗌·라벨 폭에 맞춰 뒤를 `…`), 못 읽으면 경로, root 밖이면 `outside_title`.
    title: []u8,
    /// 우측 보조 텍스트 — `상대경로:줄`(현재 파일은 `:줄`), root 밖은 절대 경로 그대로.
    binding: []u8,
    /// 이동 대상(절대 경로 사본).
    path: []u8,
    line: u32,
    character: u32,
    outside: bool,
};

/// 목록 상한(§8.2l) — 넘으면 앞부분만, `truncated` 가 선다.
pub const max_rows: usize = 500;
/// 미리보기를 위해 읽는 **다른** 파일 수 상한과 한 파일의 크기 상한.
pub const max_preview_files: usize = 64;
pub const max_preview_bytes: usize = 4 * 1024 * 1024;
/// 보조 텍스트(`경로:줄`)의 표시 폭 상한 — 넘치면 **앞**을 `…` 로(꼬리가 식별한다: 파일 이름과 줄). 제목 최소 폭.
pub const max_binding_cols: usize = 28;
pub const min_title_cols: usize = 12;

/// 앞을 `…` 로 버리고 꼬리를 남긴다(경로용).
fn fitTail(allocator: std.mem.Allocator, text: []const u8, max_cols: usize) ![]u8 {
    if (max_cols == 0) return allocator.alloc(u8, 0);
    if (symbol_picker.displayCols(text) <= max_cols) return allocator.dupe(u8, text);
    const budget = max_cols - 1;
    var start: usize = text.len;
    var cols: usize = 0;
    while (start > 0) {
        var prev = start - 1;
        while (prev > 0 and (text[prev] & 0xC0) == 0x80) prev -= 1; // UTF-8 이어지는 바이트를 건너 코드포인트 머리로
        const w = symbol_picker.displayCols(text[prev..start]);
        if (cols + w > budget) break;
        cols += w;
        start = prev;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "\u{2026}");
    try out.appendSlice(allocator, text[start..]);
    return out.toOwnedSlice(allocator);
}

pub const Picker = struct {
    all: std.ArrayList(Row) = .empty,
    /// 필터를 통과한 행의 `all` 첨자 — 팔레트의 윈도잉은 이 길이를 본다.
    shown: std.ArrayList(usize) = .empty,
    /// 상한을 넘겨 잘렸다.
    truncated: bool = false,
    /// 자르기 전 총 수(프롬프트용).
    total: usize = 0,

    pub fn deinit(self: *Picker, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.all.deinit(allocator);
        self.shown.deinit(allocator);
    }

    pub fn clear(self: *Picker, allocator: std.mem.Allocator) void {
        for (self.all.items) |r| {
            allocator.free(r.title);
            allocator.free(r.binding);
            allocator.free(r.path);
        }
        self.all.clearRetainingCapacity();
        self.shown.clearRetainingCapacity();
        self.truncated = false;
        self.total = 0;
    }

    /// 보이는 행(필터 뒤 첨자 `i`).
    pub fn shownRow(self: *const Picker, i: usize) ?*const Row {
        if (i >= self.shown.items.len) return null;
        return &self.all.items[self.shown.items[i]];
    }

    /// 쿼리로 좁힌다 — 제목·보조 텍스트에 바이트 부분일치 + ASCII 접기(심볼 피커와 같은 것). 빈 쿼리는 전부.
    pub fn applyFilter(self: *Picker, allocator: std.mem.Allocator, query: []const u8) error{OutOfMemory}!void {
        self.shown.clearRetainingCapacity();
        for (self.all.items, 0..) |r, i| {
            if (symbol_picker.containsFoldAscii(r.title, query) or symbol_picker.containsFoldAscii(r.binding, query)) try self.shown.append(allocator, i);
        }
    }
};

pub const Options = struct {
    /// 작업 공간 root(절대, 끝 `/` 없음). root 안 판정은 `underRoot` 와 같은 규칙(경계는 `/`; root `/` 는 전부).
    root: []const u8,
    /// 현재 문서의 절대 경로 — 그 파일이 먼저 서고 보조 텍스트가 `:줄` 이 된다.
    current_path: []const u8,
    /// 현재 문서의 본문(메모리) — 디스크를 안 읽는다.
    current_content: []const u8,
    /// 행이 쓸 수 있는 표시 폭(패널 폭 − 프롬프트 − 스크롤 gutter). 제목과 보조 텍스트가 이 안에서 **겹치지 않게** 나눈다 — 보조 텍스트를 먼저
    /// 재고(꼬리 `…/util.rs:3` 로 `max_binding_cols` 까지) 남는 폭을 제목이 쓴다(최소 `min_title_cols`).
    row_cols: usize,
    /// root 밖 행의 제목.
    outside_title: []const u8,
};

/// root 안인가 — `editor.withinNavRoot` 와 같은 답(그쪽은 `repo_path.underRoot`): root 가 없으면(빈 문자열) 전부 안이다.
fn underRoot(root: []const u8, path: []const u8) bool {
    if (root.len == 0) return true;
    if (std.mem.eql(u8, root, "/")) return path.len > 0 and path[0] == '/';
    if (!std.mem.startsWith(u8, path, root)) return false;
    return path.len == root.len or path[root.len] == '/';
}

fn lessLoc(ctx: []const u8, a: Loc, b: Loc) bool {
    const a_cur = std.mem.eql(u8, a.path, ctx);
    const b_cur = std.mem.eql(u8, b.path, ctx);
    if (a_cur != b_cur) return a_cur; // 현재 파일이 먼저
    switch (std.mem.order(u8, a.path, b.path)) {
        .lt => return true,
        .gt => return false,
        .eq => {},
    }
    if (a.line != b.line) return a.line < b.line;
    return a.character < b.character;
}

/// 본문에서 `line`(0-based) 줄의 텍스트. `cursor` 는 앞선 호출이 남긴 (줄, byte) — 줄이 오름차순이면 이어서 훑는다.
const LineCursor = struct { line: u32 = 0, at: usize = 0 };

fn lineText(content: []const u8, line: u32, cur: *LineCursor) ?[]const u8 {
    if (line < cur.line) cur.* = .{};
    while (cur.line < line) {
        const nl = std.mem.indexOfScalarPos(u8, content, cur.at, '\n') orelse return null;
        cur.at = nl + 1;
        cur.line += 1;
    }
    if (cur.at > content.len) return null;
    const end = std.mem.indexOfScalarPos(u8, content, cur.at, '\n') orelse content.len;
    return content[cur.at..end];
}

/// 위치 목록을 행으로 굳힌다. `reader` 는 `fn read(self, path) ?[]const u8`(root 안 다른 파일의 본문 — 상한 넘는 것은 `null`) 을 가진 것.
/// **입력을 안 바꾼다**(정렬은 사본에서).
pub fn build(allocator: std.mem.Allocator, locs: []const Loc, opts: Options, reader: anytype, out: *Picker) error{OutOfMemory}!void {
    out.clear(allocator);
    const sorted = try allocator.dupe(Loc, locs);
    defer allocator.free(sorted);
    std.mem.sort(Loc, sorted, opts.current_path, lessLoc);

    var files_read: usize = 0;
    var last_path: []const u8 = "";
    var content: ?[]const u8 = null; // 지금 파일의 본문(현재 문서·읽은 것·없음)
    var cur: LineCursor = .{};
    var prev: ?Loc = null;
    var kept: usize = 0;
    for (sorted) |loc| {
        if (prev) |p| if (std.mem.eql(u8, p.path, loc.path) and p.line == loc.line and p.character == loc.character) continue; // 같은 위치는 하나
        prev = loc;
        out.total += 1;
        if (kept >= max_rows) {
            out.truncated = true;
            continue;
        }
        const outside = !underRoot(opts.root, loc.path);
        const is_current = std.mem.eql(u8, loc.path, opts.current_path);
        if (!std.mem.eql(u8, loc.path, last_path)) {
            last_path = loc.path;
            cur = .{};
            content = null;
            if (is_current) {
                content = opts.current_content;
            } else if (!outside and files_read < max_preview_files) {
                files_read += 1;
                content = reader.read(loc.path);
            }
        }
        // 제목은 일단 **자르지 않은** 본문을 들고, 보조 텍스트 폭을 다 안 뒤 아래에서 한 번에 맞춘다.
        const title: []u8 = blk: {
            if (outside) break :blk try allocator.dupe(u8, opts.outside_title);
            if (content) |c| if (lineText(c, loc.line, &cur)) |text| {
                break :blk try allocator.dupe(u8, std.mem.trim(u8, text, " \t\r"));
            };
            break :blk try allocator.dupe(u8, loc.path); // 못 읽었다 — 경로가 제목
        };
        errdefer allocator.free(title);
        const binding_full: []u8 = blk: {
            if (is_current) break :blk try std.fmt.allocPrint(allocator, ":{d}", .{loc.line + 1});
            if (outside) break :blk try allocator.dupe(u8, loc.path);
            const rel = if (opts.root.len == 0) loc.path else if (std.mem.eql(u8, opts.root, "/")) loc.path[1..] else loc.path[@min(opts.root.len + 1, loc.path.len)..];
            break :blk try std.fmt.allocPrint(allocator, "{s}:{d}", .{ rel, loc.line + 1 });
        };
        defer allocator.free(binding_full);
        const binding = try fitTail(allocator, binding_full, max_binding_cols);
        errdefer allocator.free(binding);
        const path = try allocator.dupe(u8, loc.path);
        errdefer allocator.free(path);
        try out.all.append(allocator, .{ .title = title, .binding = binding, .path = path, .line = loc.line, .character = loc.character, .outside = outside });
        kept += 1;
    }
    // 제목 폭 = 행 폭 − 가장 긴 보조 텍스트 − 여백 1 — 팔레트는 제목과 우측 텍스트의 겹침을 안 보므로(§7.5) 여기서 가른다.
    var max_bind: usize = 0;
    for (out.all.items) |r| max_bind = @max(max_bind, symbol_picker.displayCols(r.binding));
    const title_cols = @max(min_title_cols, opts.row_cols -| (max_bind + 1));
    for (out.all.items) |*r| {
        if (symbol_picker.displayCols(r.title) <= title_cols) continue;
        const fitted = try symbol_picker.fitHead(allocator, r.title, title_cols);
        allocator.free(r.title);
        r.title = fitted;
    }
    try out.applyFilter(allocator, "");
}

const testing = std.testing;

const MapReader = struct {
    files: []const struct { path: []const u8, text: ?[]const u8 },
    reads: usize = 0,
    pub fn read(self: *MapReader, path: []const u8) ?[]const u8 {
        self.reads += 1;
        for (self.files) |f| if (std.mem.eql(u8, f.path, path)) return f.text;
        return null;
    }
};

test "RFP1 행 굳히기 — 현재 파일 먼저·경로·줄·열 순, 같은 위치 하나, 미리보기(현재는 메모리·다른 파일은 reader), root 밖은 제목 「루트 밖」에 읽지 않음, 못 읽으면 경로 (§8.2l)" {
    const a = testing.allocator;
    var reader = MapReader{
        .files = &.{
            .{ .path = "/w/src/util.rs", .text = "use crate::Point;\n\npub fn sum(p: &Point) -> i32 {\n    p.x + p.y\n}\n" },
            .{ .path = "/w/src/big.rs", .text = null }, // 상한을 넘겼다고 치자
        },
    };
    const locs = [_]Loc{
        .{ .path = "/w/src/util.rs", .line = 2, .character = 15 },
        .{ .path = "/other/x.rs", .line = 0, .character = 0 }, // root 밖
        .{ .path = "/w/src/main.rs", .line = 8, .character = 12 },
        .{ .path = "/w/src/util.rs", .line = 0, .character = 11 },
        .{ .path = "/w/src/main.rs", .line = 2, .character = 11 },
        .{ .path = "/w/src/main.rs", .line = 2, .character = 11 }, // 중복
        .{ .path = "/w/src/big.rs", .line = 1, .character = 0 },
    };
    var p: Picker = .{};
    defer p.deinit(a);
    try build(a, &locs, .{ .root = "/w", .current_path = "/w/src/main.rs", .current_content = "mod util;\n\npub struct Point {\n    pub x: i32,\n}\n\nfn main() {\n    let p =\n    Point { x: 1 };\n", .row_cols = 56, .outside_title = "루트 밖" }, &reader, &p);
    try testing.expectEqual(@as(usize, 6), p.all.items.len);
    try testing.expectEqual(@as(usize, 6), p.total);
    try testing.expect(!p.truncated);
    // 순서: main.rs(현재) 2·8 → /other/x.rs → big.rs → util.rs 0·2  (경로 사전순: /other < /w/src/big < /w/src/util)
    try testing.expectEqualStrings(":3", p.all.items[0].binding);
    try testing.expectEqualStrings("pub struct Point {", p.all.items[0].title);
    try testing.expectEqualStrings(":9", p.all.items[1].binding);
    try testing.expectEqualStrings("Point { x: 1 };", p.all.items[1].title);
    try testing.expect(p.all.items[2].outside);
    try testing.expectEqualStrings("루트 밖", p.all.items[2].title);
    try testing.expectEqualStrings("/other/x.rs", p.all.items[2].binding);
    try testing.expectEqualStrings("src/big.rs:2", p.all.items[3].binding);
    try testing.expectEqualStrings("/w/src/big.rs", p.all.items[3].title); // 못 읽었다 — 경로
    try testing.expectEqualStrings("src/util.rs:1", p.all.items[4].binding);
    try testing.expectEqualStrings("use crate::Point;", p.all.items[4].title);
    try testing.expectEqualStrings("src/util.rs:3", p.all.items[5].binding);
    try testing.expectEqualStrings("pub fn sum(p: &Point) -> i32 {", p.all.items[5].title);
    try testing.expectEqual(@as(usize, 2), reader.reads); // util·big 한 번씩 — 현재 문서·root 밖은 안 읽는다
    try testing.expectEqual(@as(usize, 6), p.shown.items.len);
    // 필터 — 제목 또는 보조 텍스트, ASCII 접기.
    try p.applyFilter(a, "UTIL");
    try testing.expectEqual(@as(usize, 2), p.shown.items.len);
    try testing.expectEqual(@as(u32, 0), p.shownRow(0).?.line);
    try p.applyFilter(a, "struct");
    try testing.expectEqual(@as(usize, 1), p.shown.items.len);
    try p.applyFilter(a, "zzz");
    try testing.expectEqual(@as(usize, 0), p.shown.items.len);
    try testing.expect(p.shownRow(0) == null);
}

test "RFP2 상한 — 미리보기 파일 수 상한(64) 뒤엔 읽지 않고 제목이 경로; 행 상한(500)을 넘으면 앞부분만 서고 truncated·total 이 선다; 긴 줄은 `…` (§8.2l)" {
    const a = testing.allocator;
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |n| a.free(n);
        names.deinit(a);
    }
    const Counting = struct {
        reads: usize = 0,
        pub fn read(self: *@This(), _: []const u8) ?[]const u8 {
            self.reads += 1;
            return "0123456789012345678901234567890123456789ABCDEFGHIJ\n1\n2\n3\n4\n5\n6\n7\n";
        }
    };
    // ⑴ 파일 70개 × 4줄 = 280 위치 — 파일 수 상한만 넘긴다.
    {
        var locs: std.ArrayList(Loc) = .empty;
        defer locs.deinit(a);
        var f: usize = 0;
        while (f < 70) : (f += 1) {
            const name = try std.fmt.allocPrint(a, "/w/f{d:0>3}.c", .{f});
            try names.append(a, name);
            var l: u32 = 0;
            while (l < 4) : (l += 1) try locs.append(a, .{ .path = name, .line = l, .character = 0 });
        }
        var reader: Counting = .{};
        var p: Picker = .{};
        defer p.deinit(a);
        try build(a, locs.items, .{ .root = "/w", .current_path = "/w/none.c", .current_content = "", .row_cols = 30, .outside_title = "out" }, &reader, &p);
        try testing.expectEqual(@as(usize, 280), p.all.items.len);
        try testing.expect(!p.truncated);
        try testing.expectEqual(max_preview_files, reader.reads);
        try testing.expectEqualStrings("01234567890123456789…", p.all.items[0].title); // 행 30 − (가장 긴 보조 `f069.c:4` 8 + 1) = 21칸: 20 + …
        try testing.expectEqualStrings("f000.c:1", p.all.items[0].binding);
        try testing.expectEqualStrings("/w/f064.c", p.all.items[64 * 4].title); // 65번째 파일부터는 안 읽어 제목이 경로
    }
    // ⑵ 한 파일 600줄 — 행 상한: 500 만 서고 total 600 · truncated. 읽기는 한 번.
    {
        var locs: std.ArrayList(Loc) = .empty;
        defer locs.deinit(a);
        var l: u32 = 0;
        while (l < 600) : (l += 1) try locs.append(a, .{ .path = "/w/big.c", .line = l, .character = 0 });
        var reader: Counting = .{};
        var p: Picker = .{};
        defer p.deinit(a);
        try build(a, locs.items, .{ .root = "/w", .current_path = "/w/none.c", .current_content = "", .row_cols = 30, .outside_title = "out" }, &reader, &p);
        try testing.expectEqual(max_rows, p.all.items.len);
        try testing.expectEqual(@as(usize, 600), p.total);
        try testing.expect(p.truncated);
        try testing.expectEqual(@as(usize, 1), reader.reads);
        try testing.expectEqual(@as(u32, 499), p.all.items[499].line);
    }
}

test "RFP4 폭 나눔 — 보조 텍스트는 28칸 꼬리(앞 `…`)까지, 제목은 남는 폭(최소 12); 긴 보조 텍스트가 있으면 모든 행의 제목이 같이 줄어 겹치지 않는다 (§8.2l · §7.5 「라벨은 host 가 잘라서 넘긴다」)" {
    const a = testing.allocator;
    const Reader = struct {
        pub fn read(_: *@This(), _: []const u8) ?[]const u8 {
            return "abcdefghijklmnopqrstuvwxyz0123456789ABCDEFGHIJ\n";
        }
    };
    var r: Reader = .{};
    var p: Picker = .{};
    defer p.deinit(a);
    const locs = [_]Loc{
        .{ .path = "/w/a.c", .line = 0, .character = 0 },
        .{ .path = "/w/very/deep/directory/structure/that/goes/on/and/on/file_with_long_name.c", .line = 0, .character = 0 },
    };
    try build(a, &locs, .{ .root = "/w", .current_path = "/w/none.c", .current_content = "", .row_cols = 56, .outside_title = "out" }, &r, &p);
    // 긴 경로는 꼬리 28칸: `…` + 27.
    try testing.expectEqualStrings("…/on/file_with_long_name.c:1", p.all.items[1].binding);
    try testing.expectEqual(@as(usize, 28), symbol_picker.displayCols(p.all.items[1].binding));
    // 제목은 56 − (28 + 1) = 27칸 — 짧은 보조 텍스트의 행(`a.c:1`)도 같이 줄어든다(겹침은 행마다가 아니라 열로 잰다).
    try testing.expectEqual(@as(usize, 27), symbol_picker.displayCols(p.all.items[0].title));
    try testing.expectEqualStrings("abcdefghijklmnopqrstuvwxyz…", p.all.items[0].title);
    // 행 폭이 아주 좁아도 제목 최소 12칸은 지킨다(그때는 겹침을 감수한다 — 화면 clamp).
    var q: Picker = .{};
    defer q.deinit(a);
    try build(a, &locs, .{ .root = "/w", .current_path = "/w/none.c", .current_content = "", .row_cols = 20, .outside_title = "out" }, &r, &q);
    try testing.expectEqual(@as(usize, 12), symbol_picker.displayCols(q.all.items[0].title));
}

test "RFP3 root 가 `/` 면 모든 절대 경로가 안이고 보조 텍스트는 앞 `/` 를 뗀다; root 가 접두사만 같은 경로는 밖 (§8.2l · CRUMB4 와 같은 규칙)" {
    const a = testing.allocator;
    const Empty = struct {
        pub fn read(_: *@This(), _: []const u8) ?[]const u8 {
            return null;
        }
    };
    var r: Empty = .{};
    var p: Picker = .{};
    defer p.deinit(a);
    const locs = [_]Loc{ .{ .path = "/tmp/a.c", .line = 0, .character = 0 }, .{ .path = "/w2/b.c", .line = 1, .character = 0 } };
    try build(a, &locs, .{ .root = "/", .current_path = "/x.c", .current_content = "", .row_cols = 24, .outside_title = "out" }, &r, &p);
    try testing.expect(!p.all.items[0].outside and !p.all.items[1].outside);
    try testing.expectEqualStrings("tmp/a.c:1", p.all.items[0].binding);
    var q: Picker = .{};
    defer q.deinit(a);
    try build(a, &locs, .{ .root = "/w", .current_path = "/x.c", .current_content = "", .row_cols = 24, .outside_title = "out" }, &r, &q);
    try testing.expect(q.all.items[0].outside and q.all.items[1].outside); // /tmp 도 /w2 도 /w 밖
    var e: Picker = .{};
    defer e.deinit(a);
    try build(a, &locs, .{ .root = "", .current_path = "/x.c", .current_content = "", .row_cols = 24, .outside_title = "out" }, &r, &e);
    try testing.expect(!e.all.items[0].outside); // root 가 없으면 전부 안(`withinNavRoot` 와 같은 답)
    try testing.expectEqualStrings("/tmp/a.c:1", e.all.items[0].binding);
}
