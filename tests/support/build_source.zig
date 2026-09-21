//! 판정자가 보는 **「빌드 소스」의 정의** — 단일 출처.
//!
//! **왜 있나.** `build.zig` 가 21,352줄이던 시절, 판정자 115자리(81파일)가 그 파일을 **이름으로**
//! 열어 안의 스텝 등록 문자열을 셌다(`count(build, "test \"C3-3b3 …\"")` 같은 형태). 등록 일부를
//! `build/` 아래로 가르자 그중 32개가 `expected 1, found 0` 으로 죽었다. 세는 규칙이 틀린 것이
//! 아니라 **무엇을 읽는가**가 흩어져 있던 것이 원인이고 — 읽는 방식만 8가지였다 —
//! 그래서 그 정의를 이 파일 하나가 소유한다.
//!
//! [docs/project-rules.md](../../docs/project-rules.md) 가 이 형태를 이미 규율로 적어 두었다:
//! *"가시성·이름을 바꾸면 문자열 의존을 먼저 찾는다"*, *"문자열로 구조를 찾지 말고 구조로 찾아라"*.
//! 여기서 「구조」는 **빌드 그래프를 등록하는 소스 전체**이지 `build.zig` 라는 이름이 아니다.
//!
//! **못 찾으면 통과하지 않고 실패한다.** `build/` 가 없거나 `.zig` 가 하나도 없으면 에러다.
//! 조용히 `build.zig` 만 읽고 지나가면 게이트는 초록인데 실제로는 절반만 보는 상태가 되고,
//! 이 저장소는 그 형태를 i18n 스캐너에서 이미 한 번 겪었다(같은 문서의 "조용히 초록" 항목).
//!
//! **다만 그 가드는 지금 도달하지 않는다 — 정직하게 적어 둔다.** `build.zig` 가
//! `@import("build/support.zig")` 로 그 폴더를 직접 물고 있어서, 폴더가 비면 판정자가 아니라
//! **컴파일러가 먼저** 죽는다. 그러니 이 검사는 오늘의 안전망이 아니라 **그 import 관계가
//! 끊어지는 날을 위한 것**이다(등록을 데이터로 읽는 형태로 바뀌면 그날이 온다).
//! 실제 안전망은 다른 쪽에 있고 그것은 확인했다 — `build/` 안의 등록 문자열을 하나 늘리면
//! 판정자가 `expected 3, found 4` 로 죽는다(2026-09-21 뮤테이션 실측).

const std = @import("std");
/// 경로를 항상 `/` 구분으로 받는다 — Windows 에서 제외·비교가 조용히 빗나가는 것을 막는다.
const posixWalk = @import("posix_walk.zig").posixWalk;

/// `build.zig` 하나가 8,782줄이고 `build/` 가 12,743줄이라 넉넉히 잡는다.
const max_bytes = 4 * 1024 * 1024;

/// 빌드 그래프 등록이 사는 곳. `build.zig` 가 `@import` 하는 게이트 파일들이 여기 있다.
const gates_dir = "build";

/// `build.zig` + `build/**.zig` 를 **한 덩어리**로 읽는다.
///
/// 호출자는 예전처럼 `count(build, "…")`·`indexOf` 로 세면 된다 — 등록이 어느 파일에 있든
/// 합계는 같으므로 **판정의 뜻이 바뀌지 않는다**. 파일 사이는 개행으로 잇는다(한 파일 끝과 다음
/// 파일 머리가 붙어 없던 문자열이 생기지 않게).
///
/// 반환한 메모리는 호출자가 `free` 한다.
pub fn read(allocator: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);

    const root = try std.Io.Dir.cwd().readFileAlloc(
        std.testing.io,
        "build.zig",
        allocator,
        .limited(max_bytes),
    );
    defer allocator.free(root);
    try out.appendSlice(allocator, root);

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, gates_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);

    // **이름을 먼저 모아 정렬한다.** walker 순서는 파일시스템이 정하므로, 그대로 이으면 같은
    // 트리에서도 실행마다 다른 바이트열이 나온다. 판정은 순서와 무관하지만(세기·찾기),
    // 실패를 눈으로 쫓을 때 결과가 흔들리면 안 된다.
    var names: std.ArrayList([]u8) = .empty;
    defer {
        for (names.items) |name| allocator.free(name);
        names.deinit(allocator);
    }

    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        try names.append(allocator, try allocator.dupe(u8, entry.path));
    }

    // 조용한 초록을 막는 자리. 여기서 0을 통과시키면 판정자 전부가 `build.zig` 절반만 보게 된다.
    if (names.items.len == 0) return error.BuildGatesMissing;

    std.mem.sort([]u8, names.items, {}, lessThan);
    for (names.items) |name| {
        const text = try dir.readFileAlloc(std.testing.io, name, allocator, .limited(max_bytes));
        defer allocator.free(text);
        try out.append(allocator, '\n');
        try out.appendSlice(allocator, text);
    }

    return out.toOwnedSlice(allocator);
}

/// `read` 와 같은 내용을 **널 종료**로 준다. 토크나이저를 태우는 판정자(`tests/boundary/imports.zig`)가
/// `[:0]u8` 를 요구하기 때문이고, 내용 정의는 위 `read` 하나가 계속 소유한다.
pub fn readZ(allocator: std.mem.Allocator) ![:0]u8 {
    const text = try read(allocator);
    defer allocator.free(text);
    return allocator.dupeZ(u8, text);
}

fn lessThan(_: void, a: []u8, b: []u8) bool {
    return std.mem.lessThan(u8, a, b);
}
