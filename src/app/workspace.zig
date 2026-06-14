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
