// 이 테스트는 **머지 충돌 마커가 커밋되지 않게** 한다.
//
// **무엇을 증명하나.** 추적 대상 소스·문서 어디에도 `<<<<<<< `·`=======`·`>>>>>>> ` 세 줄로 이루어진
// 충돌 마커가 남아 있지 않다.
//
// **왜 게이트가 필요한가 — 실제로 `main` 에 하나가 있었다.** `docs/file-explorer.md` §4 의 트리 계약이
// 충돌 마커째로 커밋돼, 같은 문단이 두 번 나오고 그 사이에 `<<<<<<< HEAD` 이 끼어 있었다. 문서라서
// 컴파일러가 볼 일이 없고, 링크 검사(`check-doc-links`)·config 문서 검사는 마커를 문법으로 보지 않아
// 전부 초록이었다. 그 자리에 무엇이 맞는지는 **두 쪽 중 하나를 고르는 판단**이 필요한데, 아무도 그것을
// 요구받지 않았으므로 그대로 남았다.
//
// 코드였다면 `zig build` 가 즉시 잡는다(`error: expected type expression, found '<<'`). 이 게이트가 실제로
// 지키는 것은 **문서와 스크립트** — 깨져도 조용한 곳이다. 그리고 이 저장소는 이미 그 사고를 한 번 냈다:
// 자동 리베이스가 `scm_dock/view.zig` 에 마커를 남겼는데 `git status` 는 깨끗했고 빌드만 잡았다.
//
// **규칙**: 아래 `roots` 아래의 텍스트 파일에 충돌 마커가 **0개**여야 한다. 하나라도 있으면 경로와 줄
// 번호를 전부 출력하고 실패한다.
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   - **충돌을 잘못 해소한 것**은 못 본다. 마커만 지우고 틀린 쪽을 남겨도 통과한다. 이 게이트가 잡는 것은
//     "해소를 아예 안 한 것"뿐이고, 어느 쪽이 맞는지는 사람이 코드와 대조해야 한다.
//   - 마커를 **본문으로 설명하는 문서**(이 게이트를 설명하는 문서·git 워크플로 안내)는 마크다운 코드
//     펜스(```) 안에 두면 안 잡는다. 재고를 열어 파일째 빼는 대신 그 방법을 쓴다 — 재고를 열면 진짜
//     마커가 그 뒤에 숨는다. 펜스는 `.md` 에서만 본다(코드에서 ``` 는 펜스가 아니다).
//   - `.gitignore` 된 트리는 **제외목록으로만** 피한다. git 을 읽지 않으므로, 목록에 없는 생성물
//     디렉터리가 새로 생기면 그 안까지 훑는다.
const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("posix_walk.zig").posixWalk;

/// **리포지토리 뿌리부터** 훑는다. 처음에는 `src`·`docs`·`tests`·`tools`·`web` 만 보는 허용목록이었는데,
/// 그러면 `.github/workflows/*.yml`·`AGENTS.md`·`CLAUDE.md`·`.mise.toml` 이 통째로 사각지대다 — CI 정의에
/// 마커가 들어가는 것이 문서보다 덜 위험하다고 볼 이유가 없다. 허용목록은 "어디에 마커가 들어올지" 를
/// 미리 안다고 가정하는데, 이 사고의 성질이 바로 **예상 못 한 곳에 남는 것**이다.
const scan_root = ".";

/// 훑지 않을 디렉터리. 생성물·의존성·바이너리 자산이라 마커가 들어갈 수 없고, 훑으면 느리기만 하다.
/// `.claude` 는 **다른 체크아웃**이 들어오는 자리다(에이전트 워크트리). 거기를 훑으면 남의 브랜치 상태를
/// 이 트리의 위반으로 보고한다 — 실제로 범위를 넓히자마자 그것이 났고, 그 오탐이 게이트가 진짜로
/// 돈다는 증거이기도 했다.
const skip_dirs = [_][]const u8{
    ".git",         ".claude", ".zig-cache",   "zig-out",
    "target",       "dist",    "node_modules", ".jj",
    "assets/fonts",
    // **받아 온 의존성 트리**(`zig fetch` 가 푸는 자리). 우리가 쓰지 않으므로 마커가 들어갈 수 없고,
    // grammar 를 늘리자 여기서 읽기 상한(8MB)을 넘겨 게이트가 `StreamTooLong` 으로 죽었다 —
    // tree-sitter 생성 파서는 한 파일이 수 MB다.
    "zig-pkg",
};

/// 훑을 확장자. 바이너리·이미지·골든 fixture 는 뺀다(마커가 들어갈 수 없고, 크기만 크다).
const extensions = [_][]const u8{
    ".zig",  ".md",   ".swift", ".m",    ".h",  ".c",   ".sh",
    ".yml",  ".yaml", ".toml",  ".json", ".ts", ".tsx", ".js",
    ".html", ".css",  ".py",
};

/// 이 파일 자신은 마커를 **본문으로 설명**하므로 제외한다. 다른 예외는 두지 않는다.
const self_path = "tests/boundary/conflict_markers.zig";

fn isMarker(line: []const u8) bool {
    // `<<<<<<< ` 와 `>>>>>>> ` 는 뒤에 브랜치 이름이 붙고, `=======` 는 그 줄 전체다. 앞 셋만 보면
    // 마크다운 제목 밑줄(`=======`)을 마커로 오인하므로, 그 줄은 **정확히 일치**할 때만 센다.
    if (std.mem.startsWith(u8, line, "<<<<<<< ")) return true;
    if (std.mem.startsWith(u8, line, ">>>>>>> ")) return true;
    return false;
}

/// `=======` 단독 줄은 마크다운 제목 밑줄과 구분되지 않는다. 그래서 **`<<<<<<< ` 를 본 뒤에만** 센다 —
/// 마커는 셋이 한 덩어리로만 나오기 때문이다. 이 규칙이 없으면 setext 제목을 쓰는 문서가 전부 걸린다.
fn countMarkers(path: []const u8, source: []const u8, report: *bool) usize {
    // 마크다운에서만 코드 펜스를 존중한다 — 이 게이트를 설명하는 문서가 예시로 마커를 담을 수 있어야
    // 하기 때문이다(그 처방을 머리 주석에 적어 놓고 구현이 없으면, 그 말을 믿은 사람이 그대로 막힌다).
    // 펜스 토글은 `tests/doc_links/links.zig` 가 다섯 자리에서 쓰는 것과 같은 규칙이다.
    const markdown = std.mem.endsWith(u8, path, ".md");
    var in_fence = false;

    var found: usize = 0;
    var open = false;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (markdown) {
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```")) {
                in_fence = !in_fence;
                continue;
            }
            if (in_fence) continue;
        }
        if (std.mem.startsWith(u8, line, "<<<<<<< ")) open = true;
        const hit = isMarker(line) or (open and std.mem.eql(u8, line, "======="));
        if (!hit) continue;
        if (std.mem.startsWith(u8, line, ">>>>>>> ")) open = false;
        found += 1;
        if (report.*) std.debug.print("  {s}:{d}: {s}\n", .{ path, line_no, line });
    }
    return found;
}

/// 제외 디렉터리 아래인가.
///
/// **접두어가 아니라 경로 세그먼트로 본다.** 접두어만 보면 최상위(`node_modules/…`)만 걸러지고
/// **중첩된 것**(`web/node_modules/…`)이 통과한다 — 그 아래에는 8 MiB를 넘는 번들이 있어 읽기 상한에
/// 걸리고, 게이트가 위반이 아니라 **환경 때문에** 죽는다(실측 2026-08-19: `web/node_modules`가 설치된
/// 작업 트리에서 `StreamTooLong`. CI는 그 디렉터리가 없어 초록이었다).
///
/// 세그먼트 비교라 `web/dist`·`crates/target` 같은 중첩 생성물도 함께 걸러진다 — 그 셋 다 "우리가 쓴
/// 소스가 아닌 곳"이라는 같은 이유로 목록에 있다.
fn skipped(path: []const u8) bool {
    // **여러 세그먼트로 된 항목**(`assets/fonts`)은 접두어로 본다 — 세그먼트 비교로는 안 걸린다.
    for (skip_dirs) |dir| {
        if (std.mem.indexOfScalar(u8, dir, '/') == null) continue;
        if (std.mem.startsWith(u8, path, dir) and
            (path.len == dir.len or path[dir.len] == '/')) return true;
    }
    var it = std.mem.splitScalar(u8, path, '/');
    while (it.next()) |segment| {
        for (skip_dirs) |dir| {
            if (std.mem.eql(u8, segment, dir)) return true;
        }
    }
    return false;
}

fn wanted(basename: []const u8) bool {
    for (extensions) |ext| {
        if (std.mem.endsWith(u8, basename, ext)) return true;
    }
    return false;
}

test "제외 목록은 **중첩된** 생성물 디렉터리도 거른다" {
    // 접두어만 보던 판은 최상위 `node_modules/`만 걸렀다 — `web/node_modules/` 아래 8 MiB 번들에서
    // 읽기 상한에 걸려, 게이트가 위반이 아니라 **환경 때문에** 죽었다(실측 2026-08-19).
    try std.testing.expect(skipped("node_modules/pkg/index.js"));
    try std.testing.expect(skipped("web/node_modules/typescript/lib/typescript.js"));
    try std.testing.expect(skipped("web/dist/app.js"));
    try std.testing.expect(skipped("crates/target/debug/build.rs"));
    try std.testing.expect(skipped("assets/fonts/a.md")); // 두 세그먼트 항목은 접두어로 걸린다

    // **우리 소스는 계속 훑는다** — 이름이 비슷하다고 거르면 그쪽 마커를 못 잡는다.
    try std.testing.expect(!skipped("src/session/git_command.zig"));
    try std.testing.expect(!skipped("web/src/main.ts"));
    try std.testing.expect(!skipped("docs/node_modules_notes.md")); // 세그먼트가 아니라 이름의 일부다
    try std.testing.expect(!skipped("assets/icons/plus.svg"));
}

test "머지 충돌 마커가 커밋되지 않았다" {
    const allocator = std.testing.allocator;
    var total: usize = 0;
    var scanned: usize = 0;
    var report = true;

    std.debug.print("\n", .{});
    {
        var dir = try std.Io.Dir.cwd().openDir(std.testing.io, scan_root, .{ .iterate = true });
        defer dir.close(std.testing.io);

        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!wanted(entry.basename)) continue;
            if (skipped(entry.path)) continue;
            if (std.mem.eql(u8, entry.path, self_path)) continue;

            // 읽기 실패를 삼키지 않는다. 삼키면 "못 읽어서 위반이 없다"가 "위반이 없다"와 구별되지
            // 않고, 그 상태로 초록이 된다 — 이 게이트가 막으려는 것이 바로 그런 조용함이다.
            const source = try dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(8 * 1024 * 1024));
            defer allocator.free(source);

            scanned += 1;
            total += countMarkers(entry.path, source, &report);
        }
    }

    // 훑은 파일이 0 이면 스캐너가 눈이 먼 것이다 — 그 상태도 "마커 0" 으로 통과하므로 따로 막는다.
    try std.testing.expect(scanned > 0);
    if (total != 0) std.debug.print("충돌 마커 {d}줄 — 위 자리에서 어느 쪽이 맞는지 코드와 대조해 고른다.\n", .{total});
    try std.testing.expectEqual(@as(usize, 0), total);
}

// 스캐너가 **정말로 구분하는지**를 스캐너 자신으로 확인한다. 위 테스트는 위반이 없을 때 통과하는데,
// 판정이 늘 거짓이어도 똑같이 통과하기 때문이다.
test "스캐너는 마커를 잡고, 마크다운 제목 밑줄은 안 잡는다" {
    var report = false;

    // setext 제목 밑줄은 `=======` 단독 줄이다 — 마커로 세면 문서 전체가 걸린다.
    try std.testing.expectEqual(@as(usize, 0), countMarkers("t.md", "제목\n=======\n본문\n", &report));

    // 세 줄이 한 덩어리로 나오면 셋 다 잡는다.
    const conflicted =
        "앞\n" ++
        "<<<<<<< HEAD\n" ++
        "이쪽\n" ++
        "=======\n" ++
        "저쪽\n" ++
        ">>>>>>> feature-branch\n" ++
        "뒤\n";
    try std.testing.expectEqual(@as(usize, 3), countMarkers("t.md", conflicted, &report));

    // 닫힌 뒤의 `=======` 는 다시 제목 밑줄로 본다 — 열림 상태를 안 닫으면 그 뒤가 전부 오탐이 된다.
    try std.testing.expectEqual(@as(usize, 3), countMarkers("t.md", conflicted ++ "제목\n=======\n", &report));
}

// 머리 주석이 처방한 것이 **정말로 되는지** 본다. 처방만 적고 구현이 없으면, 그 말을 믿고 펜스로 감싼
// 사람이 그대로 막히고 결국 "열지 말라"고 경고한 재고로 밀려난다 — 실제로 그 상태였다.
test "마크다운 코드 펜스 안의 마커는 예시로 본다 — 코드에서는 아니다" {
    var report = false;

    const doc =
        "이 게이트를 설명하는 문서다.\n" ++
        "\n" ++
        "```text\n" ++
        "<<<<<<< HEAD\n" ++
        "이쪽\n" ++
        "=======\n" ++
        "저쪽\n" ++
        ">>>>>>> other\n" ++
        "```\n" ++
        "여기까지.\n";
    try std.testing.expectEqual(@as(usize, 0), countMarkers("docs/example.md", doc, &report));

    // 펜스 **밖**의 진짜 마커는 같은 문서에서도 잡는다 — 안 그러면 문서 하나로 게이트를 통째로 끌 수 있다.
    try std.testing.expectEqual(@as(usize, 1), countMarkers("docs/example.md", doc ++ "<<<<<<< HEAD\n", &report));

    // 코드에서 ``` 는 펜스가 아니다. `.zig` 문자열에 그런 줄이 있어도 그 뒤를 눈감으면 안 된다.
    const code = "const s =\n    \\\\```\n;\n<<<<<<< HEAD\n";
    try std.testing.expectEqual(@as(usize, 1), countMarkers("src/x.zig", code, &report));
}
