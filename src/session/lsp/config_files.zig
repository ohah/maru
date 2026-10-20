//! 언어 서버가 **읽는 자리의 설정 파일**(계획 docs/plans/workspace-trust.md WT5b-3 — 계약 docs/editor-surface-tooling.md §8.1 「config
//! discovery 결과…를 노출」). LSP 에는 서버가 「이 파일을 읽었다」를 알리는 표준이 없어(2026-10-11 사용자 결정 — 서버별 내장 표로 직접
//! 찾는다) 서버마다 읽는 파일 이름과 찾는 방식을 표로 두고, 그 자리에 **있는** 파일을 보인다 — 「서버가 실제로 읽었다」가 아니라 「이 서버가
//! 읽는 자리에 있는 설정」이다. 순수 계산이다 — 파일이 있는지는 호출자가 묻는다(`describe` 의 `exists`).
const std = @import("std");
const servers = @import("servers.zig");
const language = @import("../editor/language.zig");

/// 찾는 방식 — `nearest` 는 문서의 폴더에서 저장소 루트까지 위로 올라가며 **가장 가까운** 것(clangd 의 `.clangd`·TS 의 `tsconfig.json` 처럼
/// 문서마다 다른 설정), `root` 는 저장소 루트의 것만.
pub const Scope = enum { nearest, root };

pub const Spec = struct { name: []const u8, scope: Scope };

// zls 는 문서를 품는 **가장 가까운** `build.zig` 를 찾아 빌드 설정을 얻으려고 **실행한다**(빌드 러너) — 신뢰 시트가 보이는 까닭이다. 프로젝트
// 설정은 그 옆의 `zls.build.json` 이다(zls 소스 `BuildAssociatedConfig.zig`·`DocumentStore.zig`). `zls.json` 은 사용자 설정 폴더(저장소 밖)에
// 있어 여기 없다 — 처음 표에 루트의 `zls.json` 을 넣었다가 틀린 자리라 뺐다(적대적 검증 2회차).
const zls = [_]Spec{
    .{ .name = "build.zig", .scope = .nearest },
    .{ .name = "build.zig.zon", .scope = .nearest },
    .{ .name = "zls.build.json", .scope = .nearest },
};
const clangd = [_]Spec{
    .{ .name = ".clangd", .scope = .nearest },
    .{ .name = "compile_commands.json", .scope = .nearest },
    .{ .name = "compile_flags.txt", .scope = .nearest },
};
const ts = [_]Spec{
    .{ .name = "tsconfig.json", .scope = .nearest },
    .{ .name = "jsconfig.json", .scope = .nearest },
};
const rust = [_]Spec{
    .{ .name = "rust-analyzer.toml", .scope = .nearest },
    // `Cargo.toml` 의 빌드 스크립트(`build.rs`)·절차 매크로를 서버가 돌린다.
    .{ .name = "Cargo.toml", .scope = .nearest },
    .{ .name = "rust-toolchain.toml", .scope = .root },
    .{ .name = "rust-toolchain", .scope = .root },
};
const pyright = [_]Spec{
    .{ .name = "pyrightconfig.json", .scope = .root },
    .{ .name = "pyproject.toml", .scope = .root },
};
const gopls = [_]Spec{
    .{ .name = "go.work", .scope = .nearest },
    .{ .name = "go.mod", .scope = .nearest },
};
// ── 언어 서버 후보 확대 LS1(계획 editor-lsp-servers-expand) — 각 서버의 공개 문서·소스로 정했다(2026-10-20). 이름이 패턴인 것(csharp-ls 의
// `*.sln`·`*.csproj`)과 동작을 확인하지 못한 것(bash-language-server 가 stdin 으로 넘기는 shellcheck 의 `.shellcheckrc` 탐색)은 싣지 않는다.
// sourcekit-lsp — SwiftPM 이 `Package.swift` 를 **빌드한다**; `.bsp` 의 빌드 서버도 띄운다. 프로젝트 설정은 루트의 `.sourcekit-lsp/config.json`.
const sourcekit = [_]Spec{
    .{ .name = "Package.swift", .scope = .nearest },
    .{ .name = ".sourcekit-lsp/config.json", .scope = .root },
    .{ .name = "buildServer.json", .scope = .root },
    .{ .name = "compile_commands.json", .scope = .root },
};
// Dart — `analysis_options.yaml` 은 패키지에서 위로 찾는다(analyzer 플러그인을 선언하면 그 코드를 돌린다). `pubspec.yaml` 이 패키지 루트다.
const dart = [_]Spec{
    .{ .name = "analysis_options.yaml", .scope = .nearest },
    .{ .name = "pubspec.yaml", .scope = .nearest },
};
// csharp-ls — 솔루션·프로젝트 파일(이름이 패턴이라 이 표엔 없다 — MSBuild 가 평가한다)과 그것이 읽는 `.editorconfig`.
const csharp = [_]Spec{
    .{ .name = ".editorconfig", .scope = .nearest },
};
// Metals — 빌드 도구를 **띄운다**(sbt·mill·Gradle·Maven). 빌드 파일과 포매터·JVM 설정은 루트의 것.
const metals = [_]Spec{
    .{ .name = "build.sbt", .scope = .root },
    .{ .name = "build.mill", .scope = .root },
    .{ .name = "build.sc", .scope = .root },
    .{ .name = "pom.xml", .scope = .root },
    .{ .name = "build.gradle", .scope = .root },
    .{ .name = "build.gradle.kts", .scope = .root },
    .{ .name = ".scalafmt.conf", .scope = .root },
    .{ .name = ".jvmopts", .scope = .root },
};
// jdtls — Gradle 빌드 스크립트를 **실행하고** Maven pom 을 평가한다. 맨 위의 빌드 파일을 쓴다.
const jdtls = [_]Spec{
    .{ .name = "pom.xml", .scope = .root },
    .{ .name = "build.gradle", .scope = .root },
    .{ .name = "build.gradle.kts", .scope = .root },
    .{ .name = "settings.gradle", .scope = .root },
    .{ .name = "settings.gradle.kts", .scope = .root },
    .{ .name = ".classpath", .scope = .root },
    .{ .name = ".project", .scope = .root },
};
// kotlin-language-server — `gradlew`·`mvn`·classpath 스크립트를 **실행해** classpath 를 얻는다.
const kotlin = [_]Spec{
    .{ .name = "build.gradle.kts", .scope = .nearest },
    .{ .name = "build.gradle", .scope = .nearest },
    .{ .name = "pom.xml", .scope = .nearest },
    .{ .name = "kls-classpath", .scope = .root },
};
// intelephense — 클라이언트가 설정을 주지 않으면(maru 는 `workspace/configuration` 을 거절한다) 루트의 이 파일을 읽는다.
const intelephense = [_]Spec{
    .{ .name = "intelephense.config.json", .scope = .root },
};
// LuaLS — `.luarc.json(c)` 는 루트의 것, 포맷은 `.editorconfig`(문서에서 위로).
const lua = [_]Spec{
    .{ .name = ".luarc.json", .scope = .root },
    .{ .name = ".luarc.jsonc", .scope = .root },
    .{ .name = ".editorconfig", .scope = .nearest },
};
// bash-language-server — 포맷(shfmt)이 문서마다 `.editorconfig` 를 읽는다.
const bash = [_]Spec{
    .{ .name = ".editorconfig", .scope = .nearest },
};
// taplo — 작업 루트(그 위는 이 표가 보지 않는다 — 저장소 밖)의 설정.
const taplo = [_]Spec{
    .{ .name = ".taplo.toml", .scope = .root },
    .{ .name = "taplo.toml", .scope = .root },
};
// 저장소의 설정 파일을 **읽지 않는** 서버 — 설정은 클라이언트가 보내는 것(그리고 문서 안 `$schema`)뿐이다. 정보 명령은 「찾지 못함」이 아니라
// 그렇다고 말한다(`reads_none`).
const reads_none = [_]Spec{};

/// 실행 파일 이름(`servers.Server.exe`) → 그 서버가 읽는 설정. 서버는 언제나 이름표(`servers`)에서 온다(`MARU_LSP_SERVER_OVERRIDE` 도 경로만
/// 바꾸고 이름은 그대로다) — 이름표의 모든 서버가 이 표에 있는 것은 LSC1 이 문다(적대적 검증 4회차 — 빠지면 「찾지 못함」이 거짓이 된다). 표
/// 밖 이름은 `null`, 저장소 설정을 읽지 않는 서버는 빈 슬라이스다(둘은 다르다 — 정보 명령이 가른다).
pub fn specsFor(exe: []const u8) ?[]const Spec {
    const table = [_]struct { []const u8, []const Spec }{
        .{ "zls", &zls },
        .{ "clangd", &clangd },
        .{ "tsgo", &ts },
        .{ "typescript-language-server", &ts },
        .{ "tsc", &ts },
        .{ "rust-analyzer", &rust },
        .{ "pyright-langserver", &pyright },
        .{ "gopls", &gopls },
        .{ "sourcekit-lsp", &sourcekit },
        .{ "dart", &dart },
        .{ "csharp-ls", &csharp },
        .{ "metals", &metals },
        .{ "jdtls", &jdtls },
        .{ "kotlin-language-server", &kotlin },
        .{ "intelephense", &intelephense },
        .{ "lua-language-server", &lua },
        .{ "bash-language-server", &bash },
        .{ "taplo", &taplo },
        .{ "yaml-language-server", &reads_none },
        .{ "docker-langserver", &reads_none },
        .{ "vscode-json-language-server", &reads_none },
        .{ "vscode-css-language-server", &reads_none },
        .{ "vscode-html-language-server", &reads_none },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], exe)) return row[1];
    return null;
}

/// 그 서버가 읽는 자리에 있는 설정 파일을 **저장소 루트 기준 상대 경로**로 `", "` 로 이어 `out` 에 쓴다(없으면 빈 조각). `doc_dir` 은 문서의
/// 폴더(없으면 루트) — 루트 밖이면 루트로 본다(문서가 저장소 밖일 수는 없다 — 서버는 저장소 루트에서만 뜬다; 방어가 아니라 `nearest` 의 걸음을
/// 루트에서 멈추게 하는 조건이다). `out` 이 모자라면 들어가는 것까지(뒤는 버린다 — 표시는 한 줄이다).
pub fn describe(specs: []const Spec, root: []const u8, doc_dir: ?[]const u8, ctx: anytype, comptime exists: fn (@TypeOf(ctx), []const u8) bool, out: []u8) []const u8 {
    const r = trimSlash(root);
    const start = if (doc_dir) |d| (if (under(trimSlash(d), r)) trimSlash(d) else r) else r;
    var n: usize = 0;
    var path_buf: [std.fs.max_path_bytes]u8 = undefined;
    for (specs) |spec| {
        var dir: []const u8 = if (spec.scope == .root) r else start;
        while (true) {
            const full = std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ dir, spec.name }) catch break;
            if (exists(ctx, full)) {
                const rel = if (full.len > r.len + 1) full[r.len + 1 ..] else spec.name;
                const sep: []const u8 = if (n == 0) "" else ", ";
                if (n + sep.len + rel.len > out.len) return out[0..n];
                @memcpy(out[n..][0..sep.len], sep);
                @memcpy(out[n + sep.len ..][0..rel.len], rel);
                n += sep.len + rel.len;
                break;
            }
            if (dir.len <= r.len) break; // 루트까지 봤다
            dir = std.fs.path.dirname(dir) orelse break;
        }
    }
    return out[0..n];
}

fn trimSlash(p: []const u8) []const u8 {
    return if (p.len > 1) std.mem.trimEnd(u8, p, "/") else p;
}

/// `dir` 가 `root` 자신이거나 그 아래인가(경로 성분 경계에서).
fn under(dir: []const u8, root: []const u8) bool {
    if (std.mem.eql(u8, dir, root)) return true;
    return dir.len > root.len and std.mem.startsWith(u8, dir, root) and dir[root.len] == '/';
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;

const Fake = struct {
    files: []const []const u8,
    fn has(self: Fake, path: []const u8) bool {
        for (self.files) |f| if (std.mem.eql(u8, f, path)) return true;
        return false;
    }
};

test "LSC1 서버별 설정 표 — 서버 이름표(`servers`)의 **모든** 서버가 표에 올라 있고(읽는 파일, 또는 「읽지 않음」), 표에 없는 이름은 `null`; TS 후보 셋은 같은 표; 저장소 설정을 읽지 않는 서버는 LS1 의 다섯뿐 (계획 workspace-trust WT5b-3·editor-lsp-servers-expand)" {
    // 서버 이름표를 훑는다(손으로 적은 목록이 아니다) — 서버를 더하면서 이 표를 빠뜨리면 정보 명령이 「찾지 못함」이라 거짓말한다.
    const none_ok = [_][]const u8{ "yaml-language-server", "docker-langserver", "vscode-json-language-server", "vscode-css-language-server", "vscode-html-language-server" };
    for (std.enums.values(language.Grammar)) |g| for (servers.candidatesFor(g)) |server| {
        const specs = specsFor(server.exe) orelse return error.ServerMissingFromTable;
        const reads_nothing = for (none_ok) |n| {
            if (std.mem.eql(u8, n, server.exe)) break true;
        } else false;
        try testing.expectEqual(reads_nothing, specs.len == 0); // 「읽지 않음」은 확인한 다섯만 — 빈 표로 빠뜨림을 덮지 못한다
    };
    try testing.expectEqual(specsFor("tsgo").?.ptr, specsFor("tsc").?.ptr);
    try testing.expect(specsFor("my-custom-server") == null);
    try testing.expectEqualStrings("build.zig", specsFor("zls").?[0].name);
    for (specsFor("zls").?) |s| try testing.expect(!std.mem.eql(u8, s.name, "zls.json")); // 사용자 설정 폴더의 것이다 — 저장소 자리가 아니다
    try testing.expectEqualStrings("Package.swift", specsFor("sourcekit-lsp").?[0].name); // SwiftPM 이 빌드하는 바로 그 파일
}

test "LSC2 찾기 — 「가장 가까운」은 문서 폴더에서 루트까지 올라가 첫 것, 「루트」는 루트의 것만; 루트 기준 상대 경로를 쉼표로 잇고, 없으면 빈 조각, 루트 밖 문서·모자란 버퍼 (계획 workspace-trust WT5b-3)" {
    var out: [256]u8 = undefined;
    // clangd — 문서는 src/sub 이고 `.clangd` 는 src 에, `compile_commands.json` 은 루트에.
    const f1 = Fake{ .files = &.{ "/r/src/.clangd", "/r/compile_commands.json", "/r/src/sub/x.c" } };
    try testing.expectEqualStrings("src/.clangd, compile_commands.json", describe(specsFor("clangd").?, "/r", "/r/src/sub", f1, Fake.has, &out));
    // 더 가까운 것이 이긴다 — 하나만.
    const f2 = Fake{ .files = &.{ "/r/tsconfig.json", "/r/web/tsconfig.json" } };
    try testing.expectEqualStrings("web/tsconfig.json", describe(specsFor("tsgo").?, "/r/", "/r/web/src", f2, Fake.has, &out));
    // 루트 위의 것은 안 본다(저장소 밖의 설정은 저장소 신뢰와 무관하다).
    const f3 = Fake{ .files = &.{"/tsconfig.json"} };
    try testing.expectEqualStrings("", describe(specsFor("tsgo").?, "/r", "/r/web", f3, Fake.has, &out));
    // 「루트」 표는 문서 폴더의 것을 안 본다.
    const f4 = Fake{ .files = &.{ "/r/pkg/pyproject.toml", "/r/pyrightconfig.json" } };
    try testing.expectEqualStrings("pyrightconfig.json", describe(specsFor("pyright-langserver").?, "/r", "/r/pkg", f4, Fake.has, &out));
    // zls — 문서를 품는 가장 가까운 `build.zig` 와 그 옆의 `zls.build.json`.
    const f5 = Fake{ .files = &.{ "/r/build.zig", "/r/pkg/build.zig", "/r/pkg/zls.build.json", "/r/zls.json" } };
    try testing.expectEqualStrings("pkg/build.zig, pkg/zls.build.json", describe(specsFor("zls").?, "/r", "/r/pkg/src", f5, Fake.has, &out));
    // 루트 밖 문서는 루트에서 시작한다(`/rx` 는 `/r` 아래가 아니다).
    const f6 = Fake{ .files = &.{ "/rx/tsconfig.json", "/r/tsconfig.json" } };
    try testing.expectEqualStrings("tsconfig.json", describe(specsFor("tsgo").?, "/r", "/rx", f6, Fake.has, &out));
    // 모자란 버퍼 — 들어가는 것까지.
    var small: [12]u8 = undefined;
    try testing.expectEqualStrings("build.zig", describe(specsFor("zls").?, "/r", null, f5, Fake.has, &small));
}
