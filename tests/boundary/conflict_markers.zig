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
//   - 마커를 **본문으로 설명하는 문서**가 생기면 오탐이다(이 파일 자신이 그런 예라 스스로를 제외한다).
//     그때는 재고에 넣지 말고 문서 쪽에서 코드 펜스로 감싸는 편이 낫다 — 재고를 열면 진짜 마커가 그
//     뒤에 숨는다.
const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("posix_walk.zig").posixWalk;

/// 훑을 뿌리. 소스와 문서를 함께 본다 — 실제 사고가 문서에서 났다.
const roots = [_][]const u8{ "src", "docs", "tests", "tools", "web" };

/// 훑을 확장자. 바이너리·이미지·골든 fixture 는 뺀다(마커가 들어갈 수 없고, 크기만 크다).
const extensions = [_][]const u8{
    ".zig",  ".md",   ".swift", ".m",    ".h",  ".c",   ".sh",
    ".yml",  ".yaml", ".toml",  ".json", ".ts", ".tsx", ".js",
    ".html", ".css",
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
    var found: usize = 0;
    var open = false;
    var line_no: usize = 0;
    var lines = std.mem.splitScalar(u8, source, '\n');
    while (lines.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.startsWith(u8, line, "<<<<<<< ")) open = true;
        const hit = isMarker(line) or (open and std.mem.eql(u8, line, "======="));
        if (!hit) continue;
        if (std.mem.startsWith(u8, line, ">>>>>>> ")) open = false;
        found += 1;
        if (report.*) std.debug.print("  {s}:{d}: {s}\n", .{ path, line_no, line });
    }
    return found;
}

fn wanted(basename: []const u8) bool {
    for (extensions) |ext| {
        if (std.mem.endsWith(u8, basename, ext)) return true;
    }
    return false;
}

test "머지 충돌 마커가 커밋되지 않았다" {
    const allocator = std.testing.allocator;
    var total: usize = 0;
    var scanned: usize = 0;
    var report = true;

    std.debug.print("\n", .{});
    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(std.testing.io);

        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();
        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!wanted(entry.basename)) continue;

            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, entry.path });
            if (std.mem.eql(u8, path, self_path)) continue;

            const source = dir.readFileAlloc(std.testing.io, entry.path, allocator, .limited(8 * 1024 * 1024)) catch continue;
            defer allocator.free(source);

            scanned += 1;
            total += countMarkers(path, source, &report);
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
