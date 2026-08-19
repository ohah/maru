//! **중립 층으로 가는 경로는 native 구분자로 이으면 안 된다** (docs/windows-platform.md §5 규칙 1).
//!
//! `std.fs.path.join` 은 호스트 native 구분자를 넣는다. Windows 에서 그것을 중립 층에 흘리면 한 문자열
//! 안에 `/` 와 `\` 가 섞이고, `pathWithin` 의 경계 판정은 `/` 만 세므로 **조용한 오답**이 난다.
//! 실측(docs/windows-platform.md §2m.5): 폴더 이름을 바꾸면 열려 있던 탭의 새 경로가
//! `D:/proj\lib/main.zig` 가 되고, 중립 층이 그것을 "프로젝트 루트 밖" 으로 답한다.
//!
//! **이 게이트가 있는 이유는 그 결함이 macOS·Linux CI 에 안 보이기 때문이다.** 같은 코드가 POSIX 에서는
//! `/` 를 내므로 되돌려도 초록이다 — 이 저장소에는 Windows 러너가 없다(방침). §2m.4 의 표가 그것을
//! "규칙은 CI 가 지키고 배선은 못 지킨다" 로 적었는데, **소스 스캔은 배선을 CI 로 끌어오는 유일한 길**이다.
//! 그래서 이 파일은 동작이 아니라 **소스**를 본다.
const std = @import("std");

const max_source_bytes = 8 * 1024 * 1024;

/// 스캔 대상 — **이 파일들이 만드는 경로는 전부 중립 층으로 간다.**
///
/// 목록을 넓힐 때는 "그 파일이 만든 경로가 중립 층 판정(`pathWithin`·`relativeUnderRoot`·트리 행)에
/// 닿는가" 를 근거로 한다. OS API 에만 넘기는 경로는 native 여도 맞으므로(오히려 `cmd.exe` 는 native 를
/// 요구한다 — §4.2) 무턱대고 넓히면 틀린 규칙이 된다.
const neutral_bound_sources = [_][]const u8{
    // 파일 트리의 이름 바꾸기·만들기가 여기서 경로를 조립하고, 그 값이 그대로 remap 과 트리 행으로 간다.
    "src/platform/macos/app_session/file_panel.zig",
};

fn countOccurrences(haystack: []const u8, needle: []const u8) usize {
    var count: usize = 0;
    var offset: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, offset, needle)) |found| {
        count += 1;
        offset = found + needle.len;
    }
    return count;
}

test "중립 층으로 가는 경로를 native 구분자로 잇지 않는다" {
    const allocator = std.testing.allocator;
    for (neutral_bound_sources) |path| {
        const source = std.Io.Dir.cwd().readFileAlloc(
            std.testing.io,
            path,
            allocator,
            .limited(max_source_bytes),
        ) catch |err| {
            // 파일이 옮겨졌는데 게이트가 조용히 통과하면 안 된다 — 못 읽으면 실패다.
            std.debug.print("경계 스캔이 {s} 를 못 읽었다: {s}\n", .{ path, @errorName(err) });
            return err;
        };
        defer allocator.free(source);
        const found = countOccurrences(source, "std.fs.path.join");
        if (found != 0) {
            std.debug.print(
                "{s}: `std.fs.path.join` {d} 곳 — 중립 층 경로는 `path_shape.joinNeutral` 로 잇는다\n",
                .{ path, found },
            );
        }
        try std.testing.expectEqual(@as(usize, 0), found);
    }
}

// **대조군이 없으면 이 게이트는 공허하다.** 위 검사는 "0 이면 통과" 라 스캐너가 아무것도 안 읽어도
// 초록이다(경로 오타·파일 이동으로 실제로 그렇게 된다 — 이 저장소가 여러 번 밟았다). 그래서 같은
// 스캐너로 **반드시 있어야 하는 것**을 함께 확인한다: 고친 자리가 실제로 `joinNeutral` 을 부르는가.
test "대조군: 스캐너가 실제로 소스를 읽고 있다" {
    const allocator = std.testing.allocator;
    const path = "src/platform/macos/app_session/file_panel.zig";
    const source = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(max_source_bytes));
    defer allocator.free(source);
    try std.testing.expect(source.len > 1000);
    try std.testing.expect(countOccurrences(source, "path_shape.joinNeutral") >= 1);
}

// **아직 안 고친 자리를 원장으로 남긴다** — 목록에서 빠진 것과 "알면서 남긴 것" 이 구별돼야 한다.
//
// `agent_session_archive_backend.zig` 와 `agent_session_archive_scope_backend.zig` 가 같은 방식으로
// `~/.claude/projects`·`~/.codex/sessions` 경로를 잇고, 그 값이 에이전트 도크의 목록으로 간다. 같은 결함
// 이지만 그 표면은 **W8.5b** 슬라이스 몫이라 여기서 건드리지 않았다(docs/plans/windows-platform.md).
// 그 슬라이스가 오면 위 `neutral_bound_sources` 에 두 파일을 더하고 `joinNeutral` 로 바꾼다.
//
// 이 주석이 곧 원장이다 — 지우려면 그 두 파일을 목록에 넣은 뒤에 지운다.
