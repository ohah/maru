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

/// 실행 파일 이름(`servers.Server.exe`) → 그 서버가 읽는 설정. 서버는 언제나 이름표(`servers`)에서 온다(`MARU_LSP_SERVER_OVERRIDE` 도 경로만
/// 바꾸고 이름은 그대로다) — 이름표의 모든 서버가 이 표에 있는 것은 LSC1 이 문다(적대적 검증 4회차 — 빠지면 「찾지 못함」이 거짓이 된다). 표
/// 밖 이름은 빈 슬라이스.
pub fn specsFor(exe: []const u8) []const Spec {
    const table = [_]struct { []const u8, []const Spec }{
        .{ "zls", &zls },
        .{ "clangd", &clangd },
        .{ "tsgo", &ts },
        .{ "typescript-language-server", &ts },
        .{ "tsc", &ts },
        .{ "rust-analyzer", &rust },
        .{ "pyright-langserver", &pyright },
        .{ "gopls", &gopls },
    };
    for (table) |row| if (std.mem.eql(u8, row[0], exe)) return row[1];
    return &.{};
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

test "LSC1 서버별 설정 표 — 서버 이름표(`servers`)의 **모든** 서버가 읽는 파일을 갖고, 표에 없는 이름은 찾지 않는다; TS 후보 셋은 같은 표 (계획 workspace-trust WT5b-3)" {
    // 서버 이름표를 훑는다(손으로 적은 목록이 아니다) — 서버를 더하면서 이 표를 빠뜨리면 정보 명령이 「찾지 못함」이라 거짓말한다.
    for (std.enums.values(language.Grammar)) |g| for (servers.candidatesFor(g)) |server| {
        try testing.expect(specsFor(server.exe).len > 0);
    };
    try testing.expectEqual(specsFor("tsgo").ptr, specsFor("tsc").ptr);
    try testing.expectEqual(@as(usize, 0), specsFor("my-custom-server").len);
    try testing.expectEqualStrings("build.zig", specsFor("zls")[0].name);
    for (specsFor("zls")) |s| try testing.expect(!std.mem.eql(u8, s.name, "zls.json")); // 사용자 설정 폴더의 것이다 — 저장소 자리가 아니다
}

test "LSC2 찾기 — 「가장 가까운」은 문서 폴더에서 루트까지 올라가 첫 것, 「루트」는 루트의 것만; 루트 기준 상대 경로를 쉼표로 잇고, 없으면 빈 조각, 루트 밖 문서·모자란 버퍼 (계획 workspace-trust WT5b-3)" {
    var out: [256]u8 = undefined;
    // clangd — 문서는 src/sub 이고 `.clangd` 는 src 에, `compile_commands.json` 은 루트에.
    const f1 = Fake{ .files = &.{ "/r/src/.clangd", "/r/compile_commands.json", "/r/src/sub/x.c" } };
    try testing.expectEqualStrings("src/.clangd, compile_commands.json", describe(specsFor("clangd"), "/r", "/r/src/sub", f1, Fake.has, &out));
    // 더 가까운 것이 이긴다 — 하나만.
    const f2 = Fake{ .files = &.{ "/r/tsconfig.json", "/r/web/tsconfig.json" } };
    try testing.expectEqualStrings("web/tsconfig.json", describe(specsFor("tsgo"), "/r/", "/r/web/src", f2, Fake.has, &out));
    // 루트 위의 것은 안 본다(저장소 밖의 설정은 저장소 신뢰와 무관하다).
    const f3 = Fake{ .files = &.{"/tsconfig.json"} };
    try testing.expectEqualStrings("", describe(specsFor("tsgo"), "/r", "/r/web", f3, Fake.has, &out));
    // 「루트」 표는 문서 폴더의 것을 안 본다.
    const f4 = Fake{ .files = &.{ "/r/pkg/pyproject.toml", "/r/pyrightconfig.json" } };
    try testing.expectEqualStrings("pyrightconfig.json", describe(specsFor("pyright-langserver"), "/r", "/r/pkg", f4, Fake.has, &out));
    // zls — 문서를 품는 가장 가까운 `build.zig` 와 그 옆의 `zls.build.json`.
    const f5 = Fake{ .files = &.{ "/r/build.zig", "/r/pkg/build.zig", "/r/pkg/zls.build.json", "/r/zls.json" } };
    try testing.expectEqualStrings("pkg/build.zig, pkg/zls.build.json", describe(specsFor("zls"), "/r", "/r/pkg/src", f5, Fake.has, &out));
    // 루트 밖 문서는 루트에서 시작한다(`/rx` 는 `/r` 아래가 아니다).
    const f6 = Fake{ .files = &.{ "/rx/tsconfig.json", "/r/tsconfig.json" } };
    try testing.expectEqualStrings("tsconfig.json", describe(specsFor("tsgo"), "/r", "/rx", f6, Fake.has, &out));
    // 모자란 버퍼 — 들어가는 것까지.
    var small: [12]u8 = undefined;
    try testing.expectEqualStrings("build.zig", describe(specsFor("zls"), "/r", null, f5, Fake.has, &small));
}
