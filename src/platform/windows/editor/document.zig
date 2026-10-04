//! Windows editor view lease and file opening. Shared body/format/history stay in L2.
const std = @import("std");
const maru = @import("maru");
const ts = @import("syntax");
pub const input = @import("input.zig");
const selection_projection = @import("selection_projection.zig");

pub const OpenFile = struct {
    /// View data borrows the app-lifetime document lease; body ownership stays in L2.
    documents: *maru.session.editor.document_registry.Registry,
    document: maru.session.editor.document_registry.Lease,
    path: []u8,
    text: []u8,
    lines: std.ArrayList([]const u8),
    line_starts: []usize,
    /// null means rebuilding failed: no borrowed body/line cache may be read.
    cached_revision: ?u64 = 0,
    /// 뷰포트 맨 위 줄. 파일마다 따로 산다 — 파일을 오갈 때 자리를 잃으면 안 된다.
    first_line: usize = 0,
    /// 가로 스크롤 위치(열). **계약은 "가로 스크롤이 기본이고 랩은 토글"** 이다
    /// (`native-editor-visual-mapping.md` §…: `editor.wrap` 기본 `false`).
    first_col: u16 = 0,
    /// 문서에서 **가장 긴 줄**의 표시 폭. 중립이 이 값으로 막대 길이를 정하고, 가로 막대를 세울지도
    /// 이것으로 판단한다(`showsHorizontalBar`). 문서 revision마다 다시 센다.
    max_cols: u32 = 0,
    /// **오른쪽 끝** — 직전 프레임에서 중립이 세운 가로 막대의 `max_offset_px` 를 열로 바꾼 값이다.
    /// 여기서 `max_cols - 보이는 열` 로 다시 세지 않는 이유: 본문은 gutter(줄 번호·접기·여백)만큼
    /// 좁아서 그 산수가 **거터 폭만큼 어긋난다** — 실측으로 끝까지 굴려도 마지막 41 열이 안 왔다.
    /// 막대가 없으면(넘치지 않으면) 0 이고, 그때는 굴릴 곳도 없다.
    hmax_col: u16 = 0,
    /// Vertical range comes from the painted frame, including horizontal-bar height.
    vmax_line: usize = 0,
    navigation: maru.session.editor.view_navigation.View = .{},
    selection_paint: selection_projection.Projection = .{},
    navigation_rows: usize = 1,

    /// Syntax remains a view cache, independent of selection/navigation.
    syntax: ?ts.Provider = null,
    syntax_spans: std.ArrayList(ts.Span) = .empty,
    color_spans: std.ArrayList(maru.chrome.components.editor_view.syntax_colors.ByteSpan) = .empty,
    color_lines: std.ArrayList(maru.chrome.components.editor_view.syntax_colors.LineBounds) = .empty,
    colors: maru.chrome.components.editor_view.syntax_colors.Scratch = .{},

    /// A file owns every key, including unsupported edit keys. Returning null
    /// means no clipboard write; it never means the event may reach the shell.
    pub fn applyKey(self: *OpenFile, a: std.mem.Allocator, event: maru.terminal.KeyEvent) !?[]u8 {
        const state = self.documents.get(self.document) orelse return error.StaleDocument;
        const opened = &(state.opened orelse return error.NoDocument);
        switch (input.action(event)) {
            .ignored => {},
            .copy => return try input.copy(a, &opened.file, &self.navigation),
            .move => |command| {
                try self.navigation.move(a, &opened.file, command, event.modifiers.shift);
                const selected = self.navigation.items.items[self.navigation.primary];
                const line = opened.file.lines.lineAt(selected.focus);
                if (line < self.first_line) self.first_line = line;
                if (line -| self.first_line >= self.navigation_rows)
                    self.first_line = line -| (self.navigation_rows -| 1);
            },
        }
        return null;
    }

    /// Sidebar names may be read before painting refreshes the body projection.
    pub fn name(self: *const OpenFile) []const u8 {
        const state = self.documents.get(self.document) orelse return "";
        return std.fs.path.basename(state.path orelse return "");
    }

    /// Refresh before any body consumer. L2 replaces flattened text on edit;
    /// keeping the old slices after allocation failure would expose freed memory.
    /// Each view retries independently and keeps its own scroll position.
    pub fn refresh(self: *OpenFile, allocator: std.mem.Allocator) !void {
        const state = self.documents.get(self.document) orelse {
            self.invalidate(allocator);
            self.path = @constCast(&.{});
            return error.StaleDocument;
        };
        self.path = state.path orelse @constCast(&.{});
        const opened = &(state.opened orelse {
            self.invalidate(allocator);
            return error.NoDocument;
        });
        if (self.cached_revision == opened.file.revision) return;
        self.invalidate(allocator);
        const projection = try Projection.init(allocator, &opened.file);
        self.text = opened.file.content;
        self.lines = projection.lines;
        self.line_starts = projection.starts;
        self.max_cols = projection.widest;
        self.syntax = ts.Provider.init(self.text, syntaxLanguageFor(maru.session.editor.language.grammarForPath(self.path)), 0);
        self.cached_revision = opened.file.revision;
        // A failed rebuild never publishes a revision. A later frame can retry.
    }

    fn invalidate(self: *OpenFile, allocator: std.mem.Allocator) void {
        if (self.syntax) |*p| p.deinit();
        self.syntax = null;
        self.syntax_spans.clearRetainingCapacity();
        self.color_spans.clearRetainingCapacity();
        self.color_lines.clearRetainingCapacity();
        self.colors.deinit(allocator);
        self.colors = .{};
        self.lines.deinit(allocator);
        self.lines = .empty;
        allocator.free(self.line_starts);
        self.line_starts = @constCast(&.{});
        self.text = @constCast(&.{});
        self.max_cols = 0;
        self.hmax_col = 0;
        self.vmax_line = 0;
        self.cached_revision = null;
    }

    pub fn deinit(self: *OpenFile, allocator: std.mem.Allocator) void {
        self.navigation.deinit(allocator);
        self.selection_paint.deinit(allocator);
        if (self.syntax) |*p| p.deinit();
        self.syntax_spans.deinit(allocator);
        self.color_spans.deinit(allocator);
        self.color_lines.deinit(allocator);
        self.colors.deinit(allocator);
        self.lines.deinit(allocator);
        allocator.free(self.line_starts);
        _ = self.documents.release(self.document) catch unreachable;
    }
};

/// Only offsets and borrowed line slices belong to the view. L2 owns the body.
const Projection = struct {
    lines: std.ArrayList([]const u8),
    starts: []usize,
    widest: u32,

    fn init(allocator: std.mem.Allocator, file: *const maru.session.editor.edit_doc.EditableFile) !Projection {
        const index = file.lines.lines;
        var lines = try std.ArrayList([]const u8).initCapacity(allocator, index.len);
        errdefer lines.deinit(allocator);
        const starts = try allocator.alloc(usize, index.len);
        errdefer allocator.free(starts);
        var widest: u32 = 0;
        for (index, starts) |line, *start| {
            const content = file.content[line.start..line.contentEnd()];
            lines.appendAssumeCapacity(content);
            start.* = line.start;
            const limit = maru.chrome.components.editor_view.frame.default_max_columns;
            if (widest < limit) widest = @max(widest, @min(limit, maru.chrome.components.overlay_input.displayCols(content)));
        }
        return .{ .lines = lines, .starts = starts, .widest = widest };
    }
};

/// Attach another independently cached view to the same L2 document.
/// The caller's lease is unchanged on success and on every allocation failure.
pub fn attach(documents: *maru.session.editor.document_registry.Registry, source: maru.session.editor.document_registry.Lease, allocator: std.mem.Allocator) !OpenFile {
    const lease = try documents.retain(source, .view);
    var file: OpenFile = .{
        .documents = documents,
        .document = lease,
        .path = @constCast(&.{}),
        .text = @constCast(&.{}),
        .lines = .empty,
        .line_starts = @constCast(&.{}),
        .cached_revision = null,
    };
    errdefer file.deinit(allocator);
    try file.refresh(allocator);
    return file;
}

/// 파일을 읽어 편집기가 쓸 재료로 만든다. **여는 규칙은 중립이 소유한다**
/// (`file_panel_bridge.openKindForPath`) — 확장자 표를 여기서 다시 적으면 macOS 와 갈린다.
///
/// 지금은 `.text` 만 연다. `.markdown`·`.html` 등의 본문은 계약상 WebView 이고 Windows 에서는
/// WebView2(W8.6)라 아직 없다 — **조용히 텍스트로 열지 않는다.** 그러면 마크다운이 렌더된 줄
/// 알았는데 소스가 뜨는 것을 사용자가 겪는다.
/// 왜 안 열렸는가. **뭉개면 안 된다** — "이 확장자는 아직 못 연다"(계약)와 "읽다가 실패했다"(결함)와
/// "너무 커서 못 읽는다"(상한)는 서로 다른 사실인데, 하나로 접으면 큰 파일을 못 여는 회귀가
/// "원래 안 여는 종류" 로 보인다. §2m.57 이 `scan_timeout`·`no_history` 로 같은 교훈을 남겼다.
pub const OpenOutcome = union(enum) {
    opened: OpenFile,
    /// 이진 파일 등 — 외부 앱의 것이다(중립 `openKindForPath` 가 `null` 을 낸다).
    unsupported,
    /// `.md`·`.html`·이미지 … 본문이 WebView 라 Windows 는 W8.6 이 선행이다.
    needs_web_panel,
    /// 읽기 실패 — 권한·삭제됨·**4 MiB 상한 초과**.
    read_failed,
    out_of_memory,

    /// Static localized text survives allocator failure and does not borrow a tree row.
    pub fn noticeKey(self: std.meta.Tag(OpenOutcome)) ?maru.i18n.Key {
        return switch (self) {
            .opened => null,
            .unsupported => .win_file_open_unsupported,
            .needs_web_panel => .win_file_open_web,
            .read_failed => .win_file_open_read,
            .out_of_memory => .win_file_open_memory,
        };
    }

    pub fn name(self: std.meta.Tag(OpenOutcome)) []const u8 {
        return switch (self) {
            .opened => "opened",
            .unsupported => "unsupported",
            .needs_web_panel => "needs_web_panel",
            .read_failed => "read_failed",
            .out_of_memory => "out_of_memory",
        };
    }
};

pub fn openFileFor(
    documents: *maru.session.editor.document_registry.Registry,
    allocator: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
) OpenOutcome {
    const kind = maru.session.file_panel_bridge.openKindForPath(path) orelse return .unsupported;
    if (kind != .text) return .needs_web_panel;

    const bytes = std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(4 << 20)) catch |err|
        return if (err == error.OutOfMemory) .out_of_memory else .read_failed;
    defer allocator.free(bytes);
    var prepared: maru.session.editor.document_state.State = .{};
    defer prepared.clear(allocator);
    const editable = maru.session.editor.edit_doc.EditableFile.init(allocator, bytes, true) catch |err|
        return if (err == error.OutOfMemory) .out_of_memory else .unsupported;
    prepared.opened = .{
        .file = editable,
        .saved_hash = maru.session.editor.document_state.contentHash(editable.content),
        .disk_hash = maru.session.editor.document_state.contentHash(bytes),
    };
    prepared.path = allocator.dupe(u8, path) catch return .out_of_memory;
    const text = prepared.opened.?.file.content;
    const owned_path = prepared.path.?;
    var transferred = false;
    var projection = Projection.init(allocator, &prepared.opened.?.file) catch return .out_of_memory;
    defer if (!transferred) {
        projection.lines.deinit(allocator);
        allocator.free(projection.starts);
    };
    // **구문 파서를 여기서 한 번 세운다.** 문서가 안 바뀌므로(읽기 전용) 다시 팔 일이 없다 —
    // macOS 의 예산·재개 장치(§2.1a)가 필요한 것은 편집이 있을 때다. 문법이 번들에 없으면 `null`
    // 이고 그때는 무색이다(계약 §5 — 결함이 아니다).
    //
    // **문법 표를 여기서 다시 적지 않는다** — `grammarForPath` 가 단일 출처다.
    const grammar = maru.session.editor.language.grammarForPath(path);
    var provider = ts.Provider.init(text, syntaxLanguageFor(grammar), 0);
    defer if (!transferred) if (provider) |*p| p.deinit();

    const lease = documents.create(&prepared, allocator) catch return .out_of_memory;
    transferred = true;
    return .{ .opened = .{
        .documents = documents,
        .document = lease,
        .path = owned_path,
        .text = text,
        .lines = projection.lines,
        .line_starts = projection.starts,
        .max_cols = projection.widest,
        .syntax = provider,
    } };
}

test "Windows file open outcomes have distinct localized notices" {
    const tags = [_]std.meta.Tag(OpenOutcome){ .unsupported, .needs_web_panel, .read_failed, .out_of_memory };
    try std.testing.expect(OpenOutcome.noticeKey(.opened) == null);
    for (tags, 0..) |tag, i| {
        const key = OpenOutcome.noticeKey(tag).?;
        for ([_]maru.i18n.Lang{ .en, .ko }) |lang| {
            const text = maru.i18n.tIn(lang, key);
            try std.testing.expect(text.len > 0);
            for (tags[0..i]) |other|
                try std.testing.expect(!std.mem.eql(u8, text, maru.i18n.tIn(lang, OpenOutcome.noticeKey(other).?)));
        }
    }
}

fn testOpenAllocation(allocator: std.mem.Allocator, path: []const u8) !void {
    var documents: maru.session.editor.document_registry.Registry = .{ .allocator = allocator };
    defer documents.deinit() catch unreachable;
    switch (openFileFor(&documents, allocator, std.testing.io, path)) {
        .opened => |value| {
            var file = value;
            defer file.deinit(allocator);
            try std.testing.expectEqual(@as(usize, 3), file.lines.items.len);
        },
        .out_of_memory => return error.OutOfMemory,
        else => return error.TestUnexpectedResult,
    }
}

test "Windows file open releases every failed allocation prefix" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sample.txt", .data = "alpha\nbeta\n" });
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root[0..len], "sample.txt" });
    defer std.testing.allocator.free(path);
    try std.testing.checkAllAllocationFailures(std.testing.allocator, testOpenAllocation, .{path});
}

test "Windows file open distinguishes web binary missing and over-limit files" {
    var documents: maru.session.editor.document_registry.Registry = .{ .allocator = std.testing.allocator };
    defer documents.deinit() catch unreachable;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const big = try std.testing.allocator.alloc(u8, (4 << 20) + 1);
    defer std.testing.allocator.free(big);
    @memset(big, 'x');
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "large.txt", .data = big });
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    const path = try std.fs.path.join(std.testing.allocator, &.{ root[0..len], "large.txt" });
    defer std.testing.allocator.free(path);
    try std.testing.expectEqual(std.meta.Tag(OpenOutcome).read_failed, std.meta.activeTag(openFileFor(&documents, std.testing.allocator, std.testing.io, path)));
    const missing = try std.fs.path.join(std.testing.allocator, &.{ root[0..len], "missing.txt" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectEqual(std.meta.Tag(OpenOutcome).read_failed, std.meta.activeTag(openFileFor(&documents, std.testing.allocator, std.testing.io, missing)));
    try std.testing.expectEqual(std.meta.Tag(OpenOutcome).needs_web_panel, std.meta.activeTag(openFileFor(&documents, std.testing.allocator, std.testing.io, "missing.md")));
    try std.testing.expectEqual(std.meta.Tag(OpenOutcome).unsupported, std.meta.activeTag(openFileFor(&documents, std.testing.allocator, std.testing.io, "missing.exe")));
}

// Exercise the real Windows open path: document ownership and view offsets must
// agree before editing is enabled, including lines after a capped wide line.
test "Windows file open registry owns BOM CRLF and complete line starts" {
    const a = std.testing.allocator;
    var documents: maru.session.editor.document_registry.Registry = .{ .allocator = a };
    defer documents.deinit() catch unreachable;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    try bytes.appendSlice(a, maru.session.editor.document.utf8_bom);
    try bytes.appendNTimes(a, 'x', maru.chrome.components.editor_view.frame.default_max_columns + 5);
    try bytes.appendSlice(a, "\r\n한글\nend");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "sample.txt", .data = bytes.items });
    var root: [std.fs.max_path_bytes]u8 = undefined;
    const len = try tmp.dir.realPath(std.testing.io, &root);
    const path = try std.fs.path.join(a, &.{ root[0..len], "sample.txt" });
    defer a.free(path);
    var file = switch (openFileFor(&documents, a, std.testing.io, path)) {
        .opened => |value| value,
        else => return error.TestUnexpectedResult,
    };
    var released = false;
    defer if (!released) file.deinit(a);
    const lease = file.document;
    const state = documents.get(lease).?;
    try std.testing.expect(file.text.ptr == state.opened.?.file.content.ptr);
    try std.testing.expect(file.path.ptr == state.path.?.ptr);
    try std.testing.expect(state.opened.?.file.read_only);
    try std.testing.expect(state.opened.?.file.format.has_bom);
    try std.testing.expect(state.opened.?.file.format.mixed_endings);
    try std.testing.expect(!state.opened.?.isDirty());
    try std.testing.expectEqualStrings("한글", file.lines.items[1]);
    for (state.opened.?.file.lines.lines, file.line_starts, file.lines.items) |line, start, content| {
        try std.testing.expectEqual(line.start, start);
        try std.testing.expectEqualStrings(file.text[line.start..line.contentEnd()], content);
    }
    file.deinit(a);
    released = true;
    try std.testing.expect(documents.get(lease) == null);
}

fn testPrepared(a: std.mem.Allocator) !maru.session.editor.document_state.State {
    var state: maru.session.editor.document_state.State = .{};
    errdefer state.clear(a);
    const file = try maru.session.editor.edit_doc.EditableFile.init(a, "alpha\r\n한글\nend", false);
    state.opened = .{ .file = file, .saved_hash = maru.session.editor.document_state.contentHash(file.content) };
    state.path = try a.dupe(u8, "sample.txt");
    return state;
}

fn testReplace(state: *maru.session.editor.document_state.State, bytes: []const u8) !void {
    const editor = maru.session.editor;
    var items = [_]editor.selection.Selection{editor.selection.Selection.at(0)};
    var selections = editor.selection.Selections.init(&items, 0);
    var inverse = try state.opened.?.file.apply(.{ .changes = &.{.{ .start = 0, .end = state.opened.?.file.content.len, .text = bytes }} }, &selections);
    inverse.deinit();
}

test "Windows file open refresh reflects edited UTF8 and exact CRLF offsets" {
    const a = std.testing.allocator;
    var registry: maru.session.editor.document_registry.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var state = try testPrepared(a);
    defer state.clear(a);
    const lease = try registry.create(&state, a);
    defer _ = registry.release(lease) catch unreachable;
    var view = try attach(&registry, lease, a);
    defer view.deinit(a);
    view.first_line = 1;
    view.first_col = 3;
    try testReplace(registry.get(lease).?, "새줄\r\nchanged\n");
    try view.refresh(a);
    try std.testing.expectEqual(@as(?u64, 1), view.cached_revision);
    try std.testing.expectEqualStrings("새줄", view.lines.items[0]);
    try std.testing.expectEqualStrings("changed", view.lines.items[1]);
    try std.testing.expectEqualSlices(usize, &.{ 0, 8, 16 }, view.line_starts);
    try std.testing.expectEqual(@as(u32, 7), view.max_cols);
    try std.testing.expectEqual(@as(usize, 1), view.first_line);
    try std.testing.expectEqual(@as(u16, 3), view.first_col);
    try std.testing.expect(view.text.ptr == registry.get(lease).?.opened.?.file.content.ptr);
    try std.testing.expect(registry.get(lease).?.opened.?.isDirty());
}

test "Windows file open unchanged revision refresh allocates nothing" {
    const a = std.testing.allocator;
    var registry: maru.session.editor.document_registry.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var state = try testPrepared(a);
    defer state.clear(a);
    const lease = try registry.create(&state, a);
    defer _ = registry.release(lease) catch unreachable;
    var view = try attach(&registry, lease, a);
    defer view.deinit(a);
    const lines = view.lines.items.ptr;
    const starts = view.line_starts.ptr;
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try view.refresh(failing.allocator());
    try std.testing.expectEqual(lines, view.lines.items.ptr);
    try std.testing.expectEqual(starts, view.line_starts.ptr);
    try std.testing.expect(!failing.has_induced_failure);
}

test "Windows file open refresh failure invalidates old borrows and permits retry" {
    const a = std.testing.allocator;
    for (0..2) |fail_index| {
        var registry: maru.session.editor.document_registry.Registry = .{ .allocator = a };
        defer registry.deinit() catch unreachable;
        var state = try testPrepared(a);
        defer state.clear(a);
        const lease = try registry.create(&state, a);
        defer _ = registry.release(lease) catch unreachable;
        var view = try attach(&registry, lease, a);
        defer view.deinit(a);
        view.first_line = 2;
        try testReplace(registry.get(lease).?, "replacement\nsecond");
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = fail_index });
        try std.testing.expectError(error.OutOfMemory, view.refresh(failing.allocator()));
        try std.testing.expect(view.cached_revision == null);
        try std.testing.expectEqual(@as(usize, 0), view.text.len);
        try std.testing.expectEqual(@as(usize, 0), view.lines.items.len);
        try std.testing.expectEqual(@as(usize, 0), view.line_starts.len);
        try std.testing.expect(view.syntax == null);
        try std.testing.expectEqual(@as(u32, 0), view.max_cols);
        try view.refresh(a);
        try std.testing.expectEqualStrings("replacement", view.lines.items[0]);
        try std.testing.expectEqual(@as(usize, 2), view.first_line);
        try std.testing.expectEqual(@as(?u64, 1), view.cached_revision);
    }
}

test "Windows file open attached views refresh independently and preserve document lifetime" {
    const a = std.testing.allocator;
    var registry: maru.session.editor.document_registry.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var state = try testPrepared(a);
    defer state.clear(a);
    const lease = try registry.create(&state, a);
    var source_released = false;
    defer if (!source_released) {
        _ = registry.release(lease) catch unreachable;
    };
    var left = try attach(&registry, lease, a);
    defer left.deinit(a);
    var right = try attach(&registry, lease, a);
    defer right.deinit(a);
    left.first_line = 1;
    right.first_line = 2;
    try std.testing.expectEqual(@as(?usize, 3), registry.viewCount(lease));
    try testReplace(registry.get(lease).?, "both views\nsee this");
    try left.refresh(a);
    // The other view must refresh before reading; a lease is not a text snapshot.
    try std.testing.expectEqual(@as(?u64, 0), right.cached_revision);
    try right.refresh(a);
    try std.testing.expect(left.text.ptr == right.text.ptr);
    try std.testing.expect(left.lines.items.ptr != right.lines.items.ptr);
    try std.testing.expectEqualStrings("see this", right.lines.items[1]);
    try std.testing.expectEqual(@as(usize, 1), left.first_line);
    try std.testing.expectEqual(@as(usize, 2), right.first_line);
    try std.testing.expect(!try registry.release(lease));
    source_released = true;
    try std.testing.expectEqual(@as(?usize, 2), registry.viewCount(left.document));
    try left.refresh(a);
}

fn testAttachAllocations(a: std.mem.Allocator, registry: *maru.session.editor.document_registry.Registry, lease: maru.session.editor.document_registry.Lease) !void {
    const before = registry.viewCount(lease);
    var view = attach(registry, lease, a) catch |err| {
        try std.testing.expectEqual(before, registry.viewCount(lease));
        return err;
    };
    view.deinit(a);
    try std.testing.expectEqual(before, registry.viewCount(lease));
}

test "Windows file open attaching releases every failed projection allocation prefix" {
    const a = std.testing.allocator;
    var registry: maru.session.editor.document_registry.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var state = try testPrepared(a);
    defer state.clear(a);
    const lease = try registry.create(&state, a);
    defer _ = registry.release(lease) catch unreachable;
    try std.testing.checkAllAllocationFailures(a, testAttachAllocations, .{ &registry, lease });
}

test "Windows file open refresh replaces native syntax and clears stale spans" {
    const a = std.testing.allocator;
    var registry: maru.session.editor.document_registry.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var state = try testPrepared(a);
    defer state.clear(a);
    const new_path = try a.dupe(u8, "sample.zig");
    a.free(state.path.?);
    state.path = new_path;
    try testReplace(&state, "const old = 1;\n");
    const lease = try registry.create(&state, a);
    defer _ = registry.release(lease) catch unreachable;
    var view = try attach(&registry, lease, a);
    defer view.deinit(a);
    if (view.syntax == null) return error.SkipZigTest;
    view.syntax.?.spansForRange(a, view.text, .{ .start = 0, .end = @intCast(view.text.len) }, &view.syntax_spans);
    try std.testing.expect(view.syntax_spans.items.len > 0);
    try testReplace(registry.get(lease).?, "// entirely a comment\n");
    try view.refresh(a);
    try std.testing.expectEqual(@as(usize, 0), view.syntax_spans.items.len);
    try std.testing.expect(view.syntax != null);
    view.syntax.?.spansForRange(a, view.text, .{ .start = 0, .end = @intCast(view.text.len) }, &view.syntax_spans);
    try std.testing.expect(view.syntax_spans.items.len > 0);
    var comments: usize = 0;
    for (view.syntax_spans.items) |span| {
        // Zig's bundled query also captures @spell inside comments.
        try std.testing.expect(std.mem.startsWith(u8, span.capture, "comment") or std.mem.eql(u8, span.capture, "spell"));
        if (std.mem.eql(u8, span.capture, "comment")) comments += 1;
    }
    try std.testing.expect(comments > 0);
}

test "Windows file open refresh after document clearing exposes no old borrows" {
    const a = std.testing.allocator;
    var registry: maru.session.editor.document_registry.Registry = .{ .allocator = a };
    defer registry.deinit() catch unreachable;
    var state = try testPrepared(a);
    defer state.clear(a);
    const lease = try registry.create(&state, a);
    defer _ = registry.release(lease) catch unreachable;
    var view = try attach(&registry, lease, a);
    defer view.deinit(a);
    registry.get(lease).?.clear(a);
    try std.testing.expectError(error.NoDocument, view.refresh(a));
    try std.testing.expect(view.cached_revision == null);
    try std.testing.expectEqual(@as(usize, 0), view.text.len);
    try std.testing.expectEqual(@as(usize, 0), view.lines.items.len);
    try std.testing.expectEqual(@as(usize, 0), view.path.len);
    try std.testing.expectEqualStrings("", view.name());
}

/// `session` 의 문법 이름을 `syntax` 의 것으로 옮긴다. **두 열거가 같은 축이고**(그 파일 doc:
/// *"값을 늘릴 때 두 곳이 갈리지 않게 호출자가 옮긴다"*), 이름이 1:1 이라 comptime 에 유도한다 —
/// 손으로 쓴 switch 는 한쪽에 문법이 늘 때 조용히 `.other` 로 떨어진다.
fn syntaxLanguageFor(g: maru.session.editor.language.Grammar) ts.Language {
    // **두 열거는 같은 축이고 이름이 1:1 이다**(`tree_sitter.zig` 의 doc: *"이 모듈은 maru 를 못
    // 들여오므로 필요한 것만 다시 적는다 — 값을 늘릴 때 두 곳이 갈리지 않게 **호출자가 옮긴다**"*).
    // macOS 도 같은 자리를 갖는다(`app_session/editor/syntax.zig` 의 `syntaxLanguage`) — 두 모듈을
    // 다 보는 공용 자리가 없어서다(§2m.112 의 «배선» 절).
    //
    // **드리프트를 컴파일 오류로 만든다.** 손으로 쓴 갈래는 문법이 늘 때 조용히 `.other` 로
    // 떨어지고 그 증상은 「그 언어만 무색」이라 눈에 잘 안 띈다. 아래 검사가 이름을 대조한다 —
    // 반사(`@field`)를 안 쓰는 이유는 그것이 이 파일에 생기면 경계 원장 등록이 필요해지고, 그
    // 갱신 도구가 이 호스트에서 안 돌기 때문이다(§2m.109).
    comptime {
        @setEvalBranchQuota(20_000);
        for (@typeInfo(maru.session.editor.language.Grammar).@"enum".fields) |gf| {
            if (std.mem.eql(u8, gf.name, "none")) continue;
            var found = false;
            for (@typeInfo(ts.Language).@"enum".fields) |lf| {
                if (std.mem.eql(u8, gf.name, lf.name)) found = true;
            }
            if (!found) @compileError("Grammar and syntax.Language names drifted: " ++ gf.name);
        }
    }
    return switch (g) {
        .zig => .zig,
        .json => .json,
        .markdown => .markdown,
        .javascript => .javascript,
        .typescript => .typescript,
        .tsx => .tsx,
        .c => .c,
        .cpp => .cpp,
        .python => .python,
        .go => .go,
        .rust => .rust,
        .java => .java,
        .ruby => .ruby,
        .php => .php,
        .kotlin => .kotlin,
        .bash => .bash,
        .css => .css,
        .html => .html,
        .none => .other,
    };
}
