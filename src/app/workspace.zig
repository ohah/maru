//! Workspace restore 직렬화(R1, writer). 실행 중이던 창/탭/split/터미널 레이아웃과 각 터미널의 cwd·shell을
//! 다시 열기 위한 **선언적 상태**를 `maru.workspace.v1` 텍스트로 굳힌다 — live PTY/process/grid 내용은 담지
//! 않는다(docs/workspace-restore.md). snapshot/trace와 같은 규칙: 첫 줄 bare 토큰(`schema=` 접두어 없음),
//! 이후 `<kind> <fields>` 라인, 따옴표 문자열은 `\` `"`·개행 escape. 이 파일은 모델(값 타입)과 writer만 둔다 —
//! reader(R2)·라이브 캡처(R3)·복원(R4)은 후속이 같은 모델을 소비/생산한다(snapshot.zig writer-only 선례).
//!
//! 계층: workspace → windows → tabs → (pane split 트리 + panes) → panes → surfaces(Term). 멀티 창은 windows가
//! N개(각 창 = 한 DevSession). split 트리는 preorder TreeNode 리스트로 — full binary tree라 self-delimiting
//! (split은 뒤따르는 두 subtree를 소비, leaf는 종단). 베이스: docs/workspace-restore.md 저장 모델 + 현재
//! cmux 풀 모델(탭→pane→Term)·멀티 창에 맞춰 window-aware로 확장.

const std = @import("std");
const split_tree = @import("split_tree.zig");

pub const header = "maru.workspace.v1";

/// 한 탭의 pane 수 sanity 상한. 손상·변조된 복원 파일이 pane_count를 부풀려도 split 트리 노드 상한
/// (2·pane_count−1)이 거대해져 깊은 재귀로 스택 오버플로가 나지 않게, parseTab이 먼저 이 값으로 가둔다.
/// 실제 레이아웃은 한 자릿수~십수 pane이라 1024는 어떤 현실 레이아웃보다 크다(손상만 거른다). 베이스: 표준이
/// 없어 sane 상한을 우리가 정함 — Ghostty는 바이너리 아카이버라 이 텍스트-깊은중첩 벡터 자체가 없다.
pub const max_panes_per_tab = 1024;

pub const SplitDirection = split_tree.SplitDirection;

/// split 트리 한 노드(preorder). leaf는 pane 섹션 인덱스를 가리키고, split은 방향 + a의 비율(천분율 0..1000)을
/// 들고 뒤따르는 두 subtree(a, b)를 소비한다. ratio는 split_tree의 f32(0.05..0.95)를 *1000 반올림한 정수.
pub const TreeNode = union(enum) {
    leaf: usize,
    split: Split,

    pub const Split = struct {
        direction: SplitDirection,
        ratio_milli: u16,
    };
};

/// 한 터미널(Term)의 복원 가능 선언 상태(app.surface.RestorableSurfaceMetadata의 직렬화 부분집합 — id/
/// process_state 같은 런타임 값은 복원에 불필요하므로 안 담는다). cwd=OSC 7, title=OSC 0/2, command=spawn argv[0].
/// v1 복원이 실제로 소비하는 건 cwd·cols·rows뿐이다. title·command는 캡처·저장만 하고 복원 spawn엔 안 쓴다
/// (기본 셸·"Maru" 제목으로 살린다; 정확한 제목·argv 복원은 후속). command는 argv[0]=셸이라 last_observed_command
/// 자동 재실행 금지 정책과는 별개지만, 그래도 v1에선 복원에 쓰지 않는다.
pub const Surface = struct {
    title: []const u8 = "",
    cwd: []const u8 = "",
    command: []const u8 = "",
    cols: u16 = 0,
    rows: u16 = 0,
};

/// split leaf 한 칸(panel) — 가로 탭으로 여러 Term을 들 수 있다(cmux). active-term = 보이는 Term.
pub const Pane = struct {
    active_term: usize = 0,
    surfaces: []const Surface,
};

/// 한 워크스페이스(사이드바 탭) — pane split 트리 + 그 leaf들이 가리키는 pane 섹션들. active-pane = 포커스 panel.
pub const Tab = struct {
    active_pane: usize = 0,
    title: []const u8 = "",
    tree: []const TreeNode, // preorder; leaf의 pane 인덱스가 panes를 가리킨다
    panes: []const Pane,
};

/// 한 OS 창 = 한 DevSession. 탭들 + 활성 탭.
pub const Window = struct {
    active_tab: usize = 0,
    tabs: []const Tab,
};

/// 저장 단위(최근 세션 1개). 창 N개.
pub const Workspace = struct {
    windows: []const Window,
};

/// 헤더 + 전체 workspace를 새 문자열로 직렬화한다(호출자 소유). live 캡처(R3)가 모델을 채워 넘기고, reader(R2)가
/// 같은 규칙으로 되읽는다.
pub fn serialize(allocator: std.mem.Allocator, ws: Workspace) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try out.writer.print("{s}\n", .{header});
    for (ws.windows) |win| try writeWindow(&out.writer, win);
    return out.toOwnedSlice();
}

/// 한 창(Window) 블록만 직렬화한다(헤더 없음). 멀티 창 저장(R5)에서 각 DevSession이 자기 창 블록을 내고,
/// Swift가 `maru.workspace.v1` 헤더 하나 아래로 모아 parse 가능한 전체 텍스트를 만든다.
pub fn serializeWindow(allocator: std.mem.Allocator, win: Window) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    try writeWindow(&out.writer, win);
    return out.toOwnedSlice();
}

fn writeWindow(w: *std.Io.Writer, win: Window) !void {
    try w.print("window tabs={d} active-tab={d}\n", .{ win.tabs.len, win.active_tab });
    for (win.tabs) |tab| try writeTab(w, tab);
}

fn writeTab(w: *std.Io.Writer, tab: Tab) !void {
    try w.print("tab panes={d} active-pane={d} title=\"", .{ tab.panes.len, tab.active_pane });
    try writeEscaped(w, tab.title);
    try w.writeAll("\"\n");
    for (tab.tree) |node| try writeTreeNode(w, node);
    for (tab.panes) |pane| try writePane(w, pane);
}

fn writeTreeNode(w: *std.Io.Writer, node: TreeNode) !void {
    switch (node) {
        .leaf => |idx| try w.print("tree-node leaf pane={d}\n", .{idx}),
        .split => |s| try w.print("tree-node split {s} ratio={d}\n", .{ @tagName(s.direction), s.ratio_milli }),
    }
}

fn writePane(w: *std.Io.Writer, pane: Pane) !void {
    try w.print("pane surfaces={d} active-term={d}\n", .{ pane.surfaces.len, pane.active_term });
    for (pane.surfaces) |s| try writeSurface(w, s);
}

fn writeSurface(w: *std.Io.Writer, s: Surface) !void {
    try w.writeAll("surface title=\"");
    try writeEscaped(w, s.title);
    try w.writeAll("\" cwd=\"");
    try writeEscaped(w, s.cwd);
    try w.writeAll("\" command=\"");
    try writeEscaped(w, s.command);
    try w.print("\" cols={d} rows={d}\n", .{ s.cols, s.rows });
}

/// 따옴표 문자열 안의 특수문자 escape(snapshot/trace와 같은 규칙). cwd/title/command에 공백·따옴표·개행이
/// 섞여도 한 줄·한 토큰으로 안전하게 보관된다. reader(R2)가 같은 규칙으로 unescape한다.
fn writeEscaped(w: *std.Io.Writer, s: []const u8) !void {
    for (s) |b| switch (b) {
        '\\' => try w.writeAll("\\\\"),
        '"' => try w.writeAll("\\\""),
        '\n' => try w.writeAll("\\n"),
        '\r' => try w.writeAll("\\r"),
        '\t' => try w.writeAll("\\t"),
        else => try w.writeByte(b),
    };
}

// ── R2: reader/parser ──────────────────────────────────────────────────────────
// maru.workspace.v1 텍스트를 같은 모델로 되읽는다(round-trip). 결과는 arena가 모든 슬라이스·문자열을 소유하므로
// ParsedWorkspace.deinit() 한 번으로 정리한다. split 트리는 writer와 같은 preorder를 재귀로 재구성한다(split는
// 뒤따르는 두 subtree를 소비). 알 수 없는 trailing 라인은 forgiving하게 멈춘다(window 루프가 안 맞으면 종료).

pub const ParseError = error{ BadHeader, BadLine, Truncated } || std.mem.Allocator.Error;

/// parse 결과 — arena가 workspace의 모든 할당(슬라이스·escape 해제 문자열)을 소유한다. deinit으로 한 번에 해제.
pub const ParsedWorkspace = struct {
    arena: std.heap.ArenaAllocator,
    workspace: Workspace,

    pub fn deinit(self: *ParsedWorkspace) void {
        self.arena.deinit();
    }
};

pub fn parse(allocator: std.mem.Allocator, text: []const u8) ParseError!ParsedWorkspace {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const a = arena.allocator();

    var lines = LineIter{ .text = text };
    const head = lines.next() orelse return error.Truncated;
    if (!std.mem.eql(u8, head, header)) return error.BadHeader;

    var windows: std.ArrayList(Window) = .empty;
    while (lines.peek()) |line| {
        if (!std.mem.startsWith(u8, line, "window ")) break; // 알 수 없는 trailing → forgiving 종료
        try windows.append(a, try parseWindow(a, &lines));
    }
    return .{ .arena = arena, .workspace = .{ .windows = try windows.toOwnedSlice(a) } };
}

fn parseWindow(a: std.mem.Allocator, lines: *LineIter) ParseError!Window {
    var r = FieldReader{ .line = lines.next() orelse return error.Truncated };
    if (!std.mem.eql(u8, try r.word(), "window")) return error.BadLine;
    try r.key("tabs=");
    const tab_count = try r.uint(usize);
    try r.key("active-tab=");
    const active_tab = try r.uint(usize);

    var tabs: std.ArrayList(Tab) = .empty;
    var i: usize = 0;
    while (i < tab_count) : (i += 1) try tabs.append(a, try parseTab(a, lines));
    return .{ .active_tab = active_tab, .tabs = try tabs.toOwnedSlice(a) };
}

fn parseTab(a: std.mem.Allocator, lines: *LineIter) ParseError!Tab {
    var r = FieldReader{ .line = lines.next() orelse return error.Truncated };
    if (!std.mem.eql(u8, try r.word(), "tab")) return error.BadLine;
    try r.key("panes=");
    const pane_count = try r.uint(usize);
    try r.key("active-pane=");
    const active_pane = try r.uint(usize);
    try r.key("title=");
    const title = try r.quoted(a);

    // 손상/변조 파일 방어(R6 graceful). 0개 탭은 빌드 단계에서 무효이고, 부풀린 pane_count는 아래 트리 노드
    // 상한을 거대화해 깊은 재귀를 부르므로 sane 상한으로 먼저 가둔다 — 위반 시 BadLine→그 창은 기본 창으로.
    if (pane_count == 0 or pane_count > max_panes_per_tab) return error.BadLine;

    var tree: std.ArrayList(TreeNode) = .empty;
    // 구조 불변식: pane P개 탭의 split 트리는 leaf P + split (P−1) = 정확히 2P−1 노드다. 그보다 많이 읽히면
    // (손상·순환) BadLine으로 멈춰 크래시 대신 graceful 폴백한다. pane_count가 가둬졌으니 재귀 깊이도 ≤2P−1.
    try parseTree(a, lines, &tree, 2 * pane_count - 1); // 탭의 트리 하나(self-delimiting preorder)

    var panes: std.ArrayList(Pane) = .empty;
    var i: usize = 0;
    while (i < pane_count) : (i += 1) try panes.append(a, try parsePane(a, lines));
    return .{ .active_pane = active_pane, .title = title, .tree = try tree.toOwnedSlice(a), .panes = try panes.toOwnedSlice(a) };
}

/// 한 subtree를 preorder로 읽어 out에 append(self-delimiting). split는 뒤따르는 두 subtree(a,b)를 재귀로 소비.
/// max_nodes = 2·pane_count−1(구조 불변식): 이미 그만큼 읽었으면 더 읽지 않고 BadLine — 노드 수·재귀 깊이를 함께 가둔다.
fn parseTree(a: std.mem.Allocator, lines: *LineIter, out: *std.ArrayList(TreeNode), max_nodes: usize) ParseError!void {
    if (out.items.len >= max_nodes) return error.BadLine; // 트리 노드 수 > 2·pane−1 — 손상/순환(스택 오버플로 방지)
    var r = FieldReader{ .line = lines.next() orelse return error.Truncated };
    if (!std.mem.eql(u8, try r.word(), "tree-node")) return error.BadLine;
    const kind = try r.word();
    if (std.mem.eql(u8, kind, "leaf")) {
        try r.key("pane=");
        try out.append(a, .{ .leaf = try r.uint(usize) });
    } else if (std.mem.eql(u8, kind, "split")) {
        const dir_word = try r.word();
        const dir: SplitDirection = if (std.mem.eql(u8, dir_word, "horizontal"))
            .horizontal
        else if (std.mem.eql(u8, dir_word, "vertical"))
            .vertical
        else
            return error.BadLine;
        try r.key("ratio=");
        const ratio = try r.uint(u16);
        try out.append(a, .{ .split = .{ .direction = dir, .ratio_milli = ratio } });
        try parseTree(a, lines, out, max_nodes); // a
        try parseTree(a, lines, out, max_nodes); // b
    } else return error.BadLine;
}

fn parsePane(a: std.mem.Allocator, lines: *LineIter) ParseError!Pane {
    var r = FieldReader{ .line = lines.next() orelse return error.Truncated };
    if (!std.mem.eql(u8, try r.word(), "pane")) return error.BadLine;
    try r.key("surfaces=");
    const surface_count = try r.uint(usize);
    try r.key("active-term=");
    const active_term = try r.uint(usize);

    var surfaces: std.ArrayList(Surface) = .empty;
    var i: usize = 0;
    while (i < surface_count) : (i += 1) try surfaces.append(a, try parseSurface(a, lines));
    return .{ .active_term = active_term, .surfaces = try surfaces.toOwnedSlice(a) };
}

fn parseSurface(a: std.mem.Allocator, lines: *LineIter) ParseError!Surface {
    var r = FieldReader{ .line = lines.next() orelse return error.Truncated };
    if (!std.mem.eql(u8, try r.word(), "surface")) return error.BadLine;
    try r.key("title=");
    const title = try r.quoted(a);
    try r.key("cwd=");
    const cwd = try r.quoted(a);
    try r.key("command=");
    const command = try r.quoted(a);
    try r.key("cols=");
    const cols = try r.uint(u16);
    try r.key("rows=");
    const rows = try r.uint(u16);
    return .{ .title = title, .cwd = cwd, .command = command, .cols = cols, .rows = rows };
}

/// 텍스트를 개행 단위 라인으로 나눈다(마지막 개행 뒤 빈 줄은 내지 않는다). peek은 소비 없이 다음 라인을 본다.
const LineIter = struct {
    text: []const u8,
    i: usize = 0,

    fn next(self: *LineIter) ?[]const u8 {
        if (self.i >= self.text.len) return null;
        const start = self.i;
        const nl = std.mem.indexOfScalarPos(u8, self.text, self.i, '\n') orelse self.text.len;
        self.i = if (nl < self.text.len) nl + 1 else self.text.len;
        return self.text[start..nl];
    }

    fn peek(self: *const LineIter) ?[]const u8 {
        var copy = self.*;
        return copy.next();
    }
};

/// 한 라인을 `<kind> key=val ...` 토큰으로 순차 파싱한다(앞에서부터 소비 — 따옴표 값이 다른 key 토큰을 흉내내도
/// 안전하게 sequential read). word=공백까지 한 토큰, key=`name` 정확 매치, uint=숫자, quoted=`"..."` escape 해제.
const FieldReader = struct {
    line: []const u8,
    i: usize = 0,

    fn skipSpaces(self: *FieldReader) void {
        while (self.i < self.line.len and self.line[self.i] == ' ') self.i += 1;
    }

    fn word(self: *FieldReader) ParseError![]const u8 {
        self.skipSpaces();
        const start = self.i;
        while (self.i < self.line.len and self.line[self.i] != ' ') self.i += 1;
        if (self.i == start) return error.BadLine;
        return self.line[start..self.i];
    }

    fn key(self: *FieldReader, name: []const u8) ParseError!void {
        self.skipSpaces();
        if (!std.mem.startsWith(u8, self.line[self.i..], name)) return error.BadLine;
        self.i += name.len;
    }

    fn uint(self: *FieldReader, comptime T: type) ParseError!T {
        const start = self.i;
        while (self.i < self.line.len and self.line[self.i] >= '0' and self.line[self.i] <= '9') self.i += 1;
        if (self.i == start) return error.BadLine;
        return std.fmt.parseInt(T, self.line[start..self.i], 10) catch error.BadLine;
    }

    /// `"` 부터 닫는 unescaped `"` 까지를 escape 해제해 arena에 dup(writer.writeEscaped의 역연산).
    fn quoted(self: *FieldReader, a: std.mem.Allocator) ParseError![]const u8 {
        if (self.i >= self.line.len or self.line[self.i] != '"') return error.BadLine;
        self.i += 1;
        var out: std.ArrayList(u8) = .empty;
        while (self.i < self.line.len) {
            const c = self.line[self.i];
            if (c == '"') {
                self.i += 1;
                return out.toOwnedSlice(a);
            }
            if (c == '\\') {
                self.i += 1;
                if (self.i >= self.line.len) return error.BadLine;
                const mapped: u8 = switch (self.line[self.i]) {
                    '\\' => '\\',
                    '"' => '"',
                    'n' => '\n',
                    'r' => '\r',
                    't' => '\t',
                    else => return error.BadLine,
                };
                try out.append(a, mapped);
                self.i += 1;
            } else {
                try out.append(a, c);
                self.i += 1;
            }
        }
        return error.BadLine; // 닫는 따옴표 없음
    }
};

test "workspace serialize: 단일 창/탭/pane/surface" {
    const surfaces = [_]Surface{
        .{ .title = "dev shell", .cwd = "/home/user/proj", .command = "/bin/zsh", .cols = 80, .rows = 24 },
    };
    const panes = [_]Pane{.{ .active_term = 0, .surfaces = &surfaces }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tabs = [_]Tab{.{ .active_pane = 0, .title = "work", .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .active_tab = 0, .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "maru.workspace.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "window tabs=1 active-tab=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tab panes=1 active-pane=0 title=\"work\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node leaf pane=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pane surfaces=1 active-term=0\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "surface title=\"dev shell\" cwd=\"/home/user/proj\" command=\"/bin/zsh\" cols=80 rows=24\n") != null);
}

test "workspace serialize: split 트리(중첩) + 멀티 pane" {
    // split horizontal { split vertical { leaf0, leaf1 }, leaf2 } — preorder 5노드, 3 panes.
    const s0 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 24 }};
    const s1 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const s2 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const panes = [_]Pane{
        .{ .surfaces = &s0 },
        .{ .surfaces = &s1 },
        .{ .surfaces = &s2 },
    };
    const tree = [_]TreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .split = .{ .direction = .vertical, .ratio_milli = 300 } },
        .{ .leaf = 0 },
        .{ .leaf = 1 },
        .{ .leaf = 2 },
    };
    const tabs = [_]Tab{.{ .active_pane = 2, .title = "split", .tree = &tree, .panes = &panes }};
    const windows = [_]Window{.{ .tabs = &tabs }};

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "tab panes=3 active-pane=2 title=\"split\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node split horizontal ratio=500\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node split vertical ratio=300\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node leaf pane=2\n") != null);
}

test "workspace serialize: 멀티 창 + cwd/title escape" {
    // 따옴표·공백·개행이 섞인 cwd/title이 한 줄·한 토큰으로 escape돼야 한다.
    const s = [_]Surface{.{ .title = "a \"b\"", .cwd = "/tmp/x y\n", .command = "/bin/zsh", .cols = 10, .rows = 5 }};
    const panes = [_]Pane{.{ .surfaces = &s }};
    const tree = [_]TreeNode{.{ .leaf = 0 }};
    const tab = Tab{ .tree = &tree, .panes = &panes };
    const tabs0 = [_]Tab{tab};
    const tabs1 = [_]Tab{tab};
    const windows = [_]Window{ .{ .tabs = &tabs0 }, .{ .tabs = &tabs1 } };

    const text = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text);

    // window 라인이 두 번(멀티 창).
    var it = std.mem.splitScalar(u8, text, '\n');
    var window_lines: usize = 0;
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "window ")) window_lines += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), window_lines);
    try std.testing.expect(std.mem.indexOf(u8, text, "surface title=\"a \\\"b\\\"\" cwd=\"/tmp/x y\\n\" command=\"/bin/zsh\" cols=10 rows=5\n") != null);
}

test "workspace round-trip: serialize → parse → 다시 serialize 동일(중첩 split·멀티 창·escape)" {
    // 복잡한 모델(멀티 창, 중첩 split, escape 필요한 cwd/title)을 직렬화한 뒤 되읽고 다시 직렬화하면 동일해야 한다.
    const s0 = [_]Surface{ .{ .title = "a \"b\"", .cwd = "/tmp/x y", .command = "/bin/zsh", .cols = 40, .rows = 24 }, .{ .cwd = "/var\nlog", .command = "/bin/bash", .cols = 40, .rows = 24 } };
    const s1 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const s2 = [_]Surface{.{ .command = "/bin/zsh", .cols = 40, .rows = 12 }};
    const panes0 = [_]Pane{ .{ .active_term = 1, .surfaces = &s0 }, .{ .surfaces = &s1 }, .{ .surfaces = &s2 } };
    const tree0 = [_]TreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .split = .{ .direction = .vertical, .ratio_milli = 300 } },
        .{ .leaf = 0 },
        .{ .leaf = 1 },
        .{ .leaf = 2 },
    };
    const tabs0 = [_]Tab{.{ .active_pane = 2, .title = "split", .tree = &tree0, .panes = &panes0 }};

    const sA = [_]Surface{.{ .title = "w2", .cwd = "/home", .command = "/bin/zsh", .cols = 100, .rows = 30 }};
    const panes1 = [_]Pane{.{ .surfaces = &sA }};
    const tree1 = [_]TreeNode{.{ .leaf = 0 }};
    const tabs1 = [_]Tab{.{ .title = "single", .tree = &tree1, .panes = &panes1 }};

    const windows = [_]Window{ .{ .active_tab = 0, .tabs = &tabs0 }, .{ .active_tab = 0, .tabs = &tabs1 } };

    const text1 = try serialize(std.testing.allocator, .{ .windows = &windows });
    defer std.testing.allocator.free(text1);

    var parsed = try parse(std.testing.allocator, text1);
    defer parsed.deinit();

    const text2 = try serialize(std.testing.allocator, parsed.workspace);
    defer std.testing.allocator.free(text2);

    try std.testing.expectEqualStrings(text1, text2); // writer↔reader 고정점
}

test "workspace parse: 구조·escape 해제·forgiving" {
    const text =
        "maru.workspace.v1\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=2 active-pane=1 title=\"my tab\"\n" ++
        "tree-node split vertical ratio=250\n" ++
        "tree-node leaf pane=0\n" ++
        "tree-node leaf pane=1\n" ++
        "pane surfaces=1 active-term=0\n" ++
        "surface title=\"top\" cwd=\"/a b\\\"c\" command=\"/bin/zsh\" cols=80 rows=24\n" ++
        "pane surfaces=1 active-term=0\n" ++
        "surface title=\"\" cwd=\"\" command=\"/bin/bash\" cols=80 rows=10\n" ++
        "trailing-garbage that should be ignored\n";

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    const ws = parsed.workspace;

    try std.testing.expectEqual(@as(usize, 1), ws.windows.len);
    const tab = ws.windows[0].tabs[0];
    try std.testing.expectEqual(@as(usize, 1), tab.active_pane);
    try std.testing.expectEqualStrings("my tab", tab.title);
    // 트리: split(vertical, 250) { leaf0, leaf1 } — preorder 3노드.
    try std.testing.expectEqual(@as(usize, 3), tab.tree.len);
    try std.testing.expect(tab.tree[0].split.direction == .vertical);
    try std.testing.expectEqual(@as(u16, 250), tab.tree[0].split.ratio_milli);
    try std.testing.expectEqual(@as(usize, 1), tab.tree[2].leaf);
    // surface[0] cwd escape 해제: `/a b"c`.
    try std.testing.expectEqual(@as(usize, 2), tab.panes.len);
    try std.testing.expectEqualStrings("/a b\"c", tab.panes[0].surfaces[0].cwd);
    try std.testing.expectEqual(@as(u16, 80), tab.panes[0].surfaces[0].cols);
    try std.testing.expectEqualStrings("/bin/bash", tab.panes[1].surfaces[0].command);
}

test "workspace parse: 잘못된 헤더는 에러" {
    try std.testing.expectError(error.BadHeader, parse(std.testing.allocator, "not.a.workspace\nwindow tabs=0 active-tab=0\n"));
}

test "workspace parse: 손상 트리는 구조 불변식으로 graceful 차단(크래시 대신 BadLine)" {
    // 탭은 panes=2(트리 노드 최대 2·2−1=3)인데 split가 과하게 중첩돼 4번째 노드를 요구 → BadLine으로 멈춘다
    // (깊은 재귀 스택 오버플로 방지). 복원 측은 이 에러로 그 창을 기본 창으로 떨군다.
    const deep =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=2 active-pane=0 title=\"\"\n" ++
        "tree-node split horizontal ratio=500\n" ++
        "tree-node split horizontal ratio=500\n" ++
        "tree-node leaf pane=0\n" ++
        "tree-node leaf pane=1\n" ++
        "tree-node leaf pane=0\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, deep));

    // 부풀린 pane_count는 트리 노드 상한(2·pane−1)을 거대화하므로 sane 상한(max_panes_per_tab)에서 먼저 막는다.
    const huge =
        header ++ "\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=999999 active-pane=0 title=\"\"\n" ++
        "tree-node leaf pane=0\n";
    try std.testing.expectError(error.BadLine, parse(std.testing.allocator, huge));
}

test "workspace serializeWindow: 헤더 없는 블록을 모아 전체로 parse(R5 집계)" {
    // 두 창을 각각 serializeWindow(헤더 없음)로 내고 헤더 하나 아래로 모으면, parse가 전체 workspace로 읽는다.
    const s0 = [_]Surface{.{ .cwd = "/a", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const p0 = [_]Pane{.{ .surfaces = &s0 }};
    const t0 = [_]TreeNode{.{ .leaf = 0 }};
    const win0 = Window{ .tabs = &[_]Tab{.{ .tree = &t0, .panes = &p0 }} };

    const s1 = [_]Surface{.{ .cwd = "/b", .command = "/bin/bash", .cols = 100, .rows = 30 }};
    const p1 = [_]Pane{.{ .surfaces = &s1 }};
    const t1 = [_]TreeNode{.{ .leaf = 0 }};
    const win1 = Window{ .tabs = &[_]Tab{.{ .tree = &t1, .panes = &p1 }} };

    const b0 = try serializeWindow(std.testing.allocator, win0);
    defer std.testing.allocator.free(b0);
    const b1 = try serializeWindow(std.testing.allocator, win1);
    defer std.testing.allocator.free(b1);
    try std.testing.expect(std.mem.startsWith(u8, b0, "window ")); // 헤더 없음

    const text = try std.fmt.allocPrint(std.testing.allocator, "{s}\n{s}{s}", .{ header, b0, b1 });
    defer std.testing.allocator.free(text);

    var parsed = try parse(std.testing.allocator, text);
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 2), parsed.workspace.windows.len);
    try std.testing.expectEqualStrings("/a", parsed.workspace.windows[0].tabs[0].panes[0].surfaces[0].cwd);
    try std.testing.expectEqualStrings("/b", parsed.workspace.windows[1].tabs[0].panes[0].surfaces[0].cwd);
}

test "workspace serialize: 선언적 — env/fd/pid/last-observed 필드 없음(민감 데이터 미저장 정책)" {
    // 모델이 PTY 핸들·env·last_observed_command 필드를 안 가져, 저장 텍스트에 그런 라인이 절대 안 샌다
    // (docs/workspace-restore.md: live process 저장 금지, env는 allowlist 전까지 비움, last command 자동실행 금지).
    // 이 가드는 누가 나중에 그런 필드를 추가하면 깨져서 정책 위반을 컴파일·테스트 단계에서 잡는다.
    const s = [_]Surface{.{ .title = "api", .cwd = "/home/user/.secret-proj", .command = "/bin/zsh", .cols = 80, .rows = 24 }};
    const p = [_]Pane{.{ .surfaces = &s }};
    const t = [_]TreeNode{.{ .leaf = 0 }};
    const w = [_]Window{.{ .tabs = &[_]Tab{.{ .tree = &t, .panes = &p }} }};
    const text = try serialize(std.testing.allocator, .{ .windows = &w });
    defer std.testing.allocator.free(text);

    try std.testing.expect(std.mem.indexOf(u8, text, "env=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "fd=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "pid=") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "last-observed") == null);
    // cwd는 경로라 정상 저장된다(redaction 대상은 env이지 path가 아님 — workspace-restore.md).
    try std.testing.expect(std.mem.indexOf(u8, text, "cwd=\"/home/user/.secret-proj\"") != null);
}
