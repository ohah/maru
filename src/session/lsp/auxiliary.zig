//! 보조 언어 서버(docs/editor-surface-tooling.md §8.2u — 계획 docs/plans/editor-auxiliary-servers.md)의 순수 부분: 문법 → 보조 서버 **표**와
//! 저장소 설정 **감지**. 주 서버 표(`servers.candidatesFor` — 후보 중 하나)와 달리 보조 서버는 주 서버와 **함께** 뜬다. 진단과 code action 만
//! 맡는다(2026-10-13 사용자 결정).
//!
//! 저장소 설정이 있을 때만 띄운다(사용자 결정) — 문서 폴더에서 저장소 루트까지 그 도구의 설정을 찾는다. 찾기·실행 파일 폴더는 외부
//! 포매터(§8.2t)의 함수를 그대로 쓴다(두 벌이면 한쪽만 낡는다).

const std = @import("std");
const language = @import("../editor/language.zig");
const servers = @import("servers.zig");
const external_format = @import("../editor/external_format.zig");

pub const Tool = enum {
    ruff,

    /// 사람에게 보이는 이름(정보 명령·호버의 진단 줄).
    pub fn displayName(self: Tool) []const u8 {
        return switch (self) {
            .ruff => "ruff",
        };
    }
};

pub const Auxiliary = struct {
    tool: Tool,
    server: servers.Server,
    /// 저장소 안에서 먼저 볼 실행 파일 폴더(문서 폴더에서 루트까지 각 폴더 아래) — 외부 포매터와 같은 자리.
    bin_dirs: []const []const u8,
};

const ruff_args = [_][]const u8{"server"};
const ruff: Auxiliary = .{
    .tool = .ruff,
    .server = .{ .exe = "ruff", .args = &ruff_args, .language_id = "python", .install = "pip install ruff" },
    .bin_dirs = &.{ ".venv/bin", "venv/bin" },
};

/// 문법 → 보조 서버들(주 서버 다음에 붙는다). 없으면 빈 슬라이스.
pub fn forGrammar(g: language.Grammar) []const Auxiliary {
    return switch (g) {
        .python => &[_]Auxiliary{ruff},
        else => &.{},
    };
}

/// 실행 파일 이름 → 그 보조 서버(클라이언트가 든 `server.exe` 에서 되찾는다). 주 서버면 `null`.
pub fn byExe(exe: []const u8) ?Auxiliary {
    inline for (.{ruff}) |a| if (std.mem.eql(u8, a.server.exe, exe)) return a;
    return null;
}

/// 그 도구의 저장소 설정 — 문서 폴더에서 루트까지 가장 가까운 것(절대 경로를 `out` 에). 없으면 `null`(띄우지 않는다).
/// - ruff: `ruff.toml`·`.ruff.toml`(있으면 그것 — ruff 가 설정으로 읽는다), 또는 `pyproject.toml` 의 `[tool.ruff]`·`[tool.ruff.<무엇>]`.
pub fn detect(fs: anytype, tool: Tool, doc_dir: []const u8, root: []const u8, out: *[std.fs.max_path_bytes]u8) ?[]const u8 {
    var dirs = external_format.DirsUp.init(doc_dir, root);
    while (dirs.next()) |dir| switch (tool) {
        .ruff => {
            for ([_][]const u8{ "ruff.toml", ".ruff.toml" }) |name| {
                const p = join(out, dir, name) orelse continue;
                if (fs.exists(p)) return p;
            }
            const pp = join(out, dir, "pyproject.toml") orelse continue;
            if (!fs.exists(pp)) continue;
            const text = fs.read(pp, external_format.max_config_read_bytes) orelse continue;
            defer fs.freeRead(text);
            if (external_format.tomlHasTable(text, "tool.ruff", true)) return pp;
        },
    };
    return null;
}

fn join(buf: []u8, dir: []const u8, name: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, name }) catch null;
}

const testing = std.testing;

const FakeFs = struct {
    files: []const struct { path: []const u8, text: []const u8 = "" },

    fn find(self: FakeFs, p: []const u8) ?usize {
        for (self.files, 0..) |f, i| if (std.mem.eql(u8, f.path, p)) return i;
        return null;
    }
    pub fn exists(self: FakeFs, p: []const u8) bool {
        return self.find(p) != null;
    }
    pub fn read(self: FakeFs, p: []const u8, limit: usize) ?[]const u8 {
        const i = self.find(p) orelse return null;
        if (self.files[i].text.len > limit) return null;
        return self.files[i].text;
    }
    pub fn freeRead(_: FakeFs, _: []const u8) void {}
};

test "AUX1 보조 서버 표 — Python 에 ruff server, 그 밖의 문법은 없음, exe 로 되찾기 (tooling §8.2u)" {
    const py = forGrammar(.python);
    try testing.expectEqual(@as(usize, 1), py.len);
    try testing.expectEqual(Tool.ruff, py[0].tool);
    try testing.expectEqualStrings("ruff", py[0].server.exe);
    try testing.expectEqualStrings("server", py[0].server.args[0]);
    try testing.expectEqualStrings("python", py[0].server.language_id);
    for ([_]language.Grammar{ .zig, .rust, .go, .c, .json, .markdown, .none }) |g| try testing.expectEqual(@as(usize, 0), forGrammar(g).len);
    try testing.expectEqual(Tool.ruff, byExe("ruff").?.tool);
    try testing.expect(byExe("pyright-langserver") == null);
    // 주 서버 표와 이름이 겹치면 `(root, exe)` 열쇠가 두 역할을 한 클라이언트로 합친다.
    for (std.enums.values(language.Grammar)) |g| for (servers.candidatesFor(g)) |s| try testing.expect(byExe(s.exe) == null);
}

test "AUX2 ruff 감지 — 가장 가까운 ruff.toml·.ruff.toml·pyproject [tool.ruff…], 다른 표만 있으면 아님, 루트 밖은 안 봄 (tooling §8.2u)" {
    var out: [std.fs.max_path_bytes]u8 = undefined;
    // ① 문서 폴더의 ruff.toml 이 루트의 pyproject 보다 가깝다.
    const fs1: FakeFs = .{ .files = &.{
        .{ .path = "/r/pyproject.toml", .text = "[tool.ruff]\nline-length = 100\n" },
        .{ .path = "/r/pkg/ruff.toml", .text = "" },
    } };
    try testing.expectEqualStrings("/r/pkg/ruff.toml", detect(fs1, .ruff, "/r/pkg/sub", "/r", &out).?);
    try testing.expectEqualStrings("/r/pyproject.toml", detect(fs1, .ruff, "/r/other", "/r", &out).?);
    // ② 아래 표(`[tool.ruff.lint]`)만 있어도 ruff 설정이다.
    const fs2: FakeFs = .{ .files = &.{.{ .path = "/r/pyproject.toml", .text = "[project]\nname='x'\n\n[tool.ruff.lint]\nselect = [\"F\"]\n" }} };
    try testing.expectEqualStrings("/r/pyproject.toml", detect(fs2, .ruff, "/r", "/r", &out).?);
    // ③ 다른 도구의 표만(`[tool.black]`·이름이 앞만 같은 `[tool.ruffle]`) — 아니다.
    const fs3: FakeFs = .{ .files = &.{.{ .path = "/r/pyproject.toml", .text = "[tool.black]\n[tool.ruffle]\n" }} };
    try testing.expect(detect(fs3, .ruff, "/r/a", "/r", &out) == null);
    // ④ `.ruff.toml` 도 설정이다.
    const fs4: FakeFs = .{ .files = &.{.{ .path = "/r/.ruff.toml" }} };
    try testing.expectEqualStrings("/r/.ruff.toml", detect(fs4, .ruff, "/r/a", "/r", &out).?);
    // ⑤ 루트 밖(상위 폴더)의 설정은 안 본다.
    const fs5: FakeFs = .{ .files = &.{.{ .path = "/ruff.toml" }} };
    try testing.expect(detect(fs5, .ruff, "/r/a", "/r", &out) == null);
}
