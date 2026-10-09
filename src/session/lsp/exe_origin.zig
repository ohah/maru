//! 언어 서버 실행 파일의 **출처** — 띄울 경로가 어디서 왔는지(OS 중립 순수 계산). 계획 docs/plans/workspace-trust.md WT5a, 계약
//! docs/editor-surface-tooling.md §8.1 「해결된 executable 표시」.
//!
//! 띄운 경로를 그대로 보이되(shim 뒤의 진짜 바이너리를 `mise which` 등으로 풀지 않는다 — 2026-10-09 사용자 결정, 다른 편집기와 같다),
//! 그 경로가 **누가 버전을 고르는 자리**인지 알린다:
//! - `repo` — 저장소 안의 파일(예: `node_modules/.bin`). 저장소가 그 파일 자체를 정한다.
//! - `shim` — 버전 관리자의 대리(mise·asdf·pyenv·rbenv·nodenv·volta·proto·goenv·aqua 의 shim, rustup 대리). 이 표에 없는 도구의
//!   shim 은 `plain` 이다 — 시트는 경로만 보인다(계획 WT5a 결정 — 늘 보이던 일반 경고를 출처 경고로 바꿨다). 실제 바이너리는 저장소의
//!   버전 파일(`.tool-versions`·`mise.toml`·`rust-toolchain.toml` 등)이 고른다.
//! - `plain` — 그 밖(Homebrew·직접 설치 등).
//!
//! shim 폴더의 자리는 **사용자 셸 환경**의 변수(`MISE_DATA_DIR`·`ASDF_DATA_DIR`·`PYENV_ROOT`·`RBENV_ROOT`·`NODENV_ROOT`·`VOLTA_HOME`·
//! `PROTO_HOME`·`GOENV_ROOT`·`AQUA_ROOT_DIR`)를 따르고, 없으면 각 도구의 기본 자리(mise·aqua 는 `$XDG_DATA_HOME` 아래,
//! 그 밖은 홈 아래)다. rustup 대리(`~/.cargo/bin`·Homebrew rustup 의
//! bin)는 `cargo install` 한 일반 바이너리와 한 폴더에 섞여 있어 이름으로는 못 가른다 — 호출자가 「같은 폴더의 `rustup` 과 같은
//! 파일인가」를 재어 넘긴다(`rustup_proxy`).

const std = @import("std");
const underRoot = @import("../repo_path.zig").underRoot;

pub const Tool = enum {
    mise,
    asdf,
    pyenv,
    rbenv,
    nodenv,
    volta,
    proto,
    goenv,
    aqua,
    rustup,

    pub fn name(self: Tool) []const u8 {
        return @tagName(self);
    }
};

pub const Origin = union(enum) {
    plain,
    repo,
    shim: Tool,
};

/// shim 폴더 하나 — 환경 변수가 있으면 `<값>/<sub>`, 없으면(`xdg_rel` 이 있고 `XDG_DATA_HOME` 이 서 있으면) `<XDG_DATA_HOME>/<xdg_rel>`,
/// 그것도 없으면 `<홈>/<default_rel>`.
const ShimDir = struct { tool: Tool, env: []const u8, sub: []const u8, default_rel: []const u8, xdg_rel: ?[]const u8 = null };

const shim_dirs = [_]ShimDir{
    .{ .tool = .mise, .env = "MISE_DATA_DIR", .sub = "shims", .default_rel = ".local/share/mise/shims", .xdg_rel = "mise/shims" },
    .{ .tool = .asdf, .env = "ASDF_DATA_DIR", .sub = "shims", .default_rel = ".asdf/shims" },
    .{ .tool = .pyenv, .env = "PYENV_ROOT", .sub = "shims", .default_rel = ".pyenv/shims" },
    .{ .tool = .rbenv, .env = "RBENV_ROOT", .sub = "shims", .default_rel = ".rbenv/shims" },
    .{ .tool = .nodenv, .env = "NODENV_ROOT", .sub = "shims", .default_rel = ".nodenv/shims" },
    .{ .tool = .volta, .env = "VOLTA_HOME", .sub = "bin", .default_rel = ".volta/bin" },
    .{ .tool = .proto, .env = "PROTO_HOME", .sub = "shims", .default_rel = ".proto/shims" },
    .{ .tool = .goenv, .env = "GOENV_ROOT", .sub = "shims", .default_rel = ".goenv/shims" },
    .{ .tool = .aqua, .env = "AQUA_ROOT_DIR", .sub = "bin", .default_rel = ".local/share/aquaproj-aqua/bin", .xdg_rel = "aquaproj-aqua/bin" },
};

fn shimDir(d: ShimDir, home: []const u8, env: anytype, comptime getenv: fn (@TypeOf(env), []const u8) ?[]const u8, buf: []u8) ?[]const u8 {
    if (getenv(env, d.env)) |v| if (v.len > 0) return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, v, "/"), d.sub }) catch null;
    if (d.xdg_rel) |rel| if (getenv(env, "XDG_DATA_HOME")) |x| if (x.len > 0) return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, x, "/"), rel }) catch null;
    if (home.len == 0) return null;
    return std.fmt.bufPrint(buf, "{s}/{s}", .{ std.mem.trimEnd(u8, home, "/"), d.default_rel }) catch null;
}

/// `path`(띄울 절대 경로 — 심링크를 풀기 **전**: rustup 대리는 풀면 `rustup` 이 된다)의 출처. shim 자리는 `path` 로만 본다.
/// 저장소 안인지는 `roots`(저장소 root 의 보이는 경로·실제 경로 — `/tmp/proj` 와 `/private/tmp/proj` 처럼 표기가 갈린다) 중 하나의
/// 아래에 `path` 나 `real_path`(심링크를 푼 실행 파일 — `~/bin/zls` 가 저장소의 `zig-out/bin/zls` 를 가리킬 때)가 있는지로 본다.
/// `home` 은 사용자 홈, `getenv` 는 사용자 셸 환경 조회, `rustup_proxy` 는 「같은 폴더의 `rustup` 과 같은 파일인가」(호출자가 잰다).
pub fn classify(
    path: []const u8,
    real_path: ?[]const u8,
    roots: []const []const u8,
    home: []const u8,
    env: anytype,
    comptime getenv: fn (@TypeOf(env), []const u8) ?[]const u8,
    rustup_proxy: bool,
) Origin {
    for (roots) |root| {
        if (root.len == 0) continue;
        if (underRoot(path, root)) return .repo;
        if (real_path) |r| if (underRoot(r, root)) return .repo;
    }
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    for (shim_dirs) |d| {
        const dir = shimDir(d, home, env, getenv, &buf) orelse continue;
        if (underRoot(path, dir)) return .{ .shim = d.tool };
    }
    if (rustup_proxy) return .{ .shim = .rustup };
    return .plain;
}

// ══ 테스트 ══ (이름은 `LSPO*` — 편집기 빠른 고리(`test-editor`)의 `"LSP"` 필터가 고른다; 경로 `session.lsp.` 는 소문자라 안 걸린다)════════════════════════════════════════════════════════════════════════════════════════════════
const testing = std.testing;

const TestEnv = struct {
    pairs: []const [2][]const u8,
    fn get(self: TestEnv, name_: []const u8) ?[]const u8 {
        for (self.pairs) |p| if (std.mem.eql(u8, p[0], name_)) return p[1];
        return null;
    }
};

test "LSPO1 실행 파일 출처: 저장소 안·각 도구의 기본 shim 자리·그 밖" {
    const env: TestEnv = .{ .pairs = &.{} };
    const home = "/Users/me";
    const root = "/Users/me/proj";
    try testing.expectEqual(Origin.repo, classify("/Users/me/proj/node_modules/.bin/tsserver", null, &.{root}, home, env, TestEnv.get, false));
    const cases = [_]struct { p: []const u8, t: Tool }{
        .{ .p = "/Users/me/.local/share/mise/shims/rust-analyzer", .t = .mise },
        .{ .p = "/Users/me/.asdf/shims/gopls", .t = .asdf },
        .{ .p = "/Users/me/.pyenv/shims/pyright-langserver", .t = .pyenv },
        .{ .p = "/Users/me/.rbenv/shims/solargraph", .t = .rbenv },
        .{ .p = "/Users/me/.nodenv/shims/typescript-language-server", .t = .nodenv },
        .{ .p = "/Users/me/.volta/bin/typescript-language-server", .t = .volta },
        .{ .p = "/Users/me/.proto/shims/node", .t = .proto },
        .{ .p = "/Users/me/.goenv/shims/gopls", .t = .goenv },
        .{ .p = "/Users/me/.local/share/aquaproj-aqua/bin/gopls", .t = .aqua },
    };
    for (cases) |c| try testing.expectEqual(Origin{ .shim = c.t }, classify(c.p, null, &.{root}, home, env, TestEnv.get, false));
    try testing.expectEqual(Origin.plain, classify("/opt/homebrew/bin/zls", null, &.{root}, home, env, TestEnv.get, false));
    // 성분 경계 — 이름만 비슷한 폴더는 아니다.
    try testing.expectEqual(Origin.plain, classify("/Users/me/.asdf/shimsx/gopls", null, &.{root}, home, env, TestEnv.get, false));
    try testing.expectEqual(Origin.plain, classify("/Users/me/projx/bin/zls", null, &.{root}, home, env, TestEnv.get, false));
    // 저장소 root 의 두 표기 중 하나라도·심링크를 푼 실행 파일이 저장소 안이어도 저장소다.
    try testing.expectEqual(Origin.repo, classify("/tmp/proj/bin/zls", null, &.{ "/private/tmp/proj", "/tmp/proj" }, home, env, TestEnv.get, false));
    try testing.expectEqual(Origin.repo, classify("/Users/me/bin/zls", "/Users/me/proj/zig-out/bin/zls", &.{root}, home, env, TestEnv.get, false));
    try testing.expectEqual(Origin.plain, classify("/Users/me/bin/zls", "/opt/zls", &.{ "", root }, home, env, TestEnv.get, false));
    // 저장소가 이긴다(저장소 안에 shim 폴더가 있어도 저장소가 그 파일을 정한다).
    try testing.expectEqual(Origin.repo, classify("/Users/me/.asdf/shims/gopls", null, &.{"/Users/me/.asdf"}, home, env, TestEnv.get, false));
}

test "LSPO2 실행 파일 출처: 사용자 셸 환경의 자리 변수를 따른다 — 있으면 기본 자리는 shim 이 아니다" {
    const env: TestEnv = .{ .pairs = &.{ .{ "MISE_DATA_DIR", "/opt/mise/" }, .{ "VOLTA_HOME", "/v" } } };
    const home = "/Users/me";
    try testing.expectEqual(Origin{ .shim = .mise }, classify("/opt/mise/shims/zls", null, &.{}, home, env, TestEnv.get, false));
    try testing.expectEqual(Origin.plain, classify("/Users/me/.local/share/mise/shims/zls", null, &.{}, home, env, TestEnv.get, false));
    try testing.expectEqual(Origin{ .shim = .volta }, classify("/v/bin/tsserver", null, &.{}, home, env, TestEnv.get, false));
    // 빈 값은 없는 것과 같다(기본 자리).
    const empty: TestEnv = .{ .pairs = &.{.{ "ASDF_DATA_DIR", "" }} };
    try testing.expectEqual(Origin{ .shim = .asdf }, classify("/Users/me/.asdf/shims/gopls", null, &.{}, home, empty, TestEnv.get, false));
}

test "LSPO3 실행 파일 출처: rustup 대리는 호출자가 잰 것으로만 — 같은 폴더의 일반 바이너리는 그 밖" {
    const env: TestEnv = .{ .pairs = &.{} };
    try testing.expectEqual(Origin{ .shim = .rustup }, classify("/Users/me/.cargo/bin/rust-analyzer", null, &.{}, "/Users/me", env, TestEnv.get, true));
    try testing.expectEqual(Origin.plain, classify("/Users/me/.cargo/bin/taplo", null, &.{}, "/Users/me", env, TestEnv.get, false));
}

test "LSPO4 실행 파일 출처: mise·aqua 의 기본 자리는 XDG_DATA_HOME 을 따른다 — MISE_DATA_DIR 이 이긴다" {
    const home = "/Users/me";
    const xdg: TestEnv = .{ .pairs = &.{.{ "XDG_DATA_HOME", "/x/data/" }} };
    try testing.expectEqual(Origin{ .shim = .mise }, classify("/x/data/mise/shims/zls", null, &.{}, home, xdg, TestEnv.get, false));
    try testing.expectEqual(Origin.plain, classify("/Users/me/.local/share/mise/shims/zls", null, &.{}, home, xdg, TestEnv.get, false));
    try testing.expectEqual(Origin{ .shim = .aqua }, classify("/x/data/aquaproj-aqua/bin/gopls", null, &.{}, home, xdg, TestEnv.get, false));
    // XDG 는 mise·aqua 만 — asdf 는 그대로 홈 아래.
    try testing.expectEqual(Origin{ .shim = .asdf }, classify("/Users/me/.asdf/shims/gopls", null, &.{}, home, xdg, TestEnv.get, false));
    const both: TestEnv = .{ .pairs = &.{ .{ "XDG_DATA_HOME", "/x/data" }, .{ "MISE_DATA_DIR", "/m" } } };
    try testing.expectEqual(Origin{ .shim = .mise }, classify("/m/shims/zls", null, &.{}, home, both, TestEnv.get, false));
    try testing.expectEqual(Origin.plain, classify("/x/data/mise/shims/zls", null, &.{}, home, both, TestEnv.get, false));
}
