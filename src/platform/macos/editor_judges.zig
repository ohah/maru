//! **편집기 판정자만 모으는 진입점** — `zig build test-editor`가 이 파일을 뿌리로 삼는다.
//!
//! `zig build test`는 3,995개를 전부 돌려 20~30분이 걸리는데 그 대부분은 소켓·프로세스·타임아웃을
//! 실제로 쓰는 `session_host` 계열이다. 편집기를 고치는 동안 매번 그것을 기다리면 적대적 검증이
//! 사실상 막힌다 — 뮤턴트 하나 판정에 20분이 들었다(2026-08-25).
//!
//! **`app_session.zig`에 필터를 걸어서는 안 됐다.** `const editor_ops = @import(...)`는 참조되지
//! 않으면 분석되지 않고, 그러면 그 파일의 판정자가 **애초에 바이너리에 없다.** 실제로 `EDIT6`
//! 필터가 0개를 고르고도 `exit=0`으로 통과했다 — **거짓 초록**이다. 그래서 필터가 아니라
//! **import로** 끌어온다: 여기 적힌 파일의 판정자는 반드시 컴파일된다.
//!
//! **`test`를 대신하지 않는다.** 합류 전에는 `mise run check`가 전부 돈다.
//!
//! **구문 트리 판정자(`TS*`)는 여기 없다.** `src/syntax/`는 별도 모듈이라 이 파일의 모듈 경로
//! 밖이고(`error: import of file outside module path`), 설령 모듈 이름으로 들여와도 `zig test`는
//! **루트 모듈의 test만** 싣는다 — `LANG`이 그렇게 0개를 돌았다. `build.zig`가 그 모듈을 뿌리로
//! 하는 실행을 따로 걸어 `test-editor`에 매단다.

const std = @import("std");

test "LOOP1 빠른 고리가 편집기 영역 모듈을 통째로 고른다 — 「있는데 안 도는」 판정자를 막는다" {
    // **이 세션에서 세 번 물린 자리다.** 판정자가 있는데 `test-editor` 필터가 그 이름을 안 골라
    // **0번 돌았고**, 그동안 변이는 「생존」으로 보였다 — `BAND*`(모듈째 빠짐)·`CRUMB1`·
    // `repo_path` 여섯이 그랬다. 실측으로 편집기 영역 판정자 **224개**가 그 상태였다.
    //
    // 이름 접두는 사람이 붙이는 것이라 빠뜨릴 수 있으므로, 필터가 **모듈 경로**를 고르게 바꿨다.
    // 이 판정자는 그 줄들이 사라지지 않는지 지킨다 — 없으면 다시 조용히 안 돈다.
    // (`build.zig` 본문을 모듈로 박아 읽는다. `docs/configuration.md` 를 그렇게 읽는 판정자가
    //  이미 있고, 같은 수법이다.)
    // **이 판정자만은 이름 접두(`LOOP`)로 골라진다.** 모듈 필터가 지워지면 이 파일의 판정자가
    // 통째로 안 도는데, 그때 **경보도 함께 꺼지면** 게이트가 자기 자신을 못 지킨다 — 실제로 처음엔
    // 그렇게 만들었고, 일부러 지워 보는 실험에서 드러났다.
    const build_src = @embedFile("build_zig_src");
    const required = [_][]const u8{
        "\"app_session.editor.\"", // editor.zig — 347
        "\"app_session.editor_diff.\"", // editor_diff.zig — 100
        "\"session.editor.\"", // selection.zig·motion.zig 등 L2 순수 모듈
        "\"platform.cell_text.\"", // 밴드 라벨·마디 열 범위
        "\"session.repo_path.\"", // breadcrumb 경로 규칙
    };
    // **`.filters` 목록 안에서만 찾는다.** 첫 판은 파일 전체를 훑었는데, 내가 build.zig 에 적은
    // **주석**이 같은 문자열을 품고 있어 필터에서 지워도 통과했다 — 일부러 지워 보는 실험이
    // 그것을 잡았다(게이트도 게이트로 재야 한다).
    for (required) |needle| {
        var rest: []const u8 = build_src;
        var found = false;
        while (std.mem.indexOf(u8, rest, ".filters = &.{")) |at| {
            const open = at + ".filters = &.{".len;
            const close = std.mem.indexOfScalarPos(u8, rest, open, '}') orelse break;
            if (std.mem.indexOf(u8, rest[open..close], needle) != null) found = true;
            rest = rest[close..];
        }
        if (!found) {
            std.debug.print("\n[고리] `build.zig` 의 필터 목록에서 {s} 가 사라졌다 — 그 모듈 판정자가 0번 돈다\n", .{needle});
            return error.FastLoopFilterLostModule;
        }
    }
}

test {
    _ = @import("app_session/editor.zig");
    _ = @import("app_session/editor_syntax.zig");
    _ = @import("app_session/editor_diff.zig");
    _ = @import("symbol_picker.zig");
}
