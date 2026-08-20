// 이 테스트는 **"번역 대상 레이어에 새 한국어 리터럴이 들어오지 않는다"** 를 강제한다
// (docs/i18n.md §7.2 의 2 차 방어).
//
// **무엇을 증명하나.** 표시 문자열은 `src/i18n.zig` 의 테이블이 소유하고 코드는 키만 든다. 그 규율이
// 지켜지는 한 언어를 바꾸면 화면 전체가 따라오지만, **한 자리라도 리터럴로 새면 그 자리만 한국어로
// 남는다** — 크래시도 경고도 없이. 계약 §7.2 는 1 차 방어(파라미터를 `i18n.Key` 로)를 세울 수 없는
// sink 가 있다고 적었다(`context_menu_items_buf` 처럼 정적·동적이 한 배열에 섞이는 자리). 거기서는
// 이 검사가 유일한 방어다.
//
// **원장을 올릴 때는 그것이 표시 문자열이 아님을 확인한다.** 이 게이트가 처음 잡은 둘이 그 예다:
// SCM 히스토리 탭의 상대 시각·안내 9 건은 **표시 문자열이라 키로 옮겼고**(원장 0 유지),
// CoreText 스모크의 9 건은 **디버그 출력 2 + 스모크 fixture 7**(탭 제목·기본 텍스트)이라 원장을 올렸다.
// 늘었다는 사실만으로 자동 반영하면 게이트가 아무것도 안 지킨다 — 매번 그 자리를 열어 봐야 한다.
//
// **왜 개수 원장인가.** 남은 152 건은 대부분 **표시 문자열이 아니다** — config 파싱 진단(55),
// Chrome Lab 개발 도구(15), 계약 §6.2 위반이라 I2 가 먼저 드는 자리(정렬 공백·아이콘 결합), trace
// 로그. 그것들을 0 으로 만드는 것은 이 계약의 일이 아니므로 **현재 수를 고정**하고 **늘면 실패**시킨다.
// 줄이는 것은 언제나 환영이고, 그때는 원장을 함께 줄이라고 안내한다.
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   - **줄어든 것은 못 막는다.** 원장보다 적으면 실패하지 않고 "원장을 줄여라"만 말한다(그 편이
//     리팩터를 막지 않는다). 대신 그 안내를 놓치면 원장이 헐거워지므로, 줄었을 때도 실패시킨다.
//   - **한글이 아닌 표시 문자열은 못 본다.** 영어로 박은 리터럴은 이 검사를 통과한다 — 그것은
//     1 차 방어(타입)와 리뷰의 몫이다.
//   - **주석·`test` 블록은 제외**하므로 그 안의 한글은 세지 않는다. 제품 경로만 본다.
//   - 문자열 안의 `//` 를 주석으로 오인하지 않도록 따옴표 상태를 추적하지만, 여러 줄 문자열
//     (`\\`)은 줄 단위로 본다 — 그 안의 한글은 세지 않는다(현재 트리에 표시용은 없다).
const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("posix_walk.zig").posixWalk;

/// 번역 대상 레이어 — 여기서는 표시 문자열이 **키로** 가야 한다(§7.2).
const roots = [_][]const u8{ "src/chrome", "src/session", "src/platform/macos", "src/platform/mobile", "src/config" };

/// **영어 고정 표면**(계약 §7.1) — CLI 는 스크립트가 파싱하고 이슈에 붙여 넣는 출력이라 언어를 고르지
/// 않는다. 그래서 여기서는 키가 아니라 **영어 문장**이 정답이고, 한국어 리터럴은 곧 위반이다.
///
/// 원장은 **거의 비어 있다** — I5 가 CLI 137 건을 영어로 옮겼다. 남은 항목이 0 이 되면 원장에서 빼고,
/// 그러면 그 파일은 "한국어 0" 이 기본값이 되어 한 건만 들어와도 실패한다.
const english_only_roots = [_][]const u8{"src/cli"};
const english_only_files = [_][]const u8{"src/main.zig"};

const Entry = struct { path: []const u8, count: usize };

/// 파일별 남은 한국어 리터럴 수. **늘면 실패**하고, **줄어도 실패**한다(원장을 함께 줄이라는 뜻).
/// 새 파일이 한글 리터럴을 들고 나타나면 원장에 없으므로 실패한다 — 그것이 이 게이트의 본래 목적이다.
const inventory = [_]Entry{
    // ── 영어 고정 표면(§7.1) ──
    // **토크나이저로 바꾸자 드러난 것들.** 줄 단위 스캐너는 멀티라인 문자열(`\\`)을 못 봤다.
    //   · `cli/browser.zig`(20) 와 `main.zig`(1) 은 **0 이 되어 원장에서 빠졌다.** 둘 다 §7.1 이 영어로
    //     고정한 표면인데 한국어였다 — 계약이 금지한 것이 코드에 있었고, 이 원장이 그것을 "알려진 위반"
    //     으로 세고 있었다. `maru browser --help` 본문과 Windows 스모크 usage 한 줄을 영어로 옮겼다.
    //     CLI 출력을 영어로 두는 이유는 §7.1 이 적은 대로 **스크립트가 파싱하기 때문**이다.
    // `cli/browser/run.zig`(41) 도 **0 이 되어 빠졌다**. `cli/ssh.zig` 에 남은 하나는
    // `@compileError` 라 개발자 메시지이고 §7.1 대상이 아니다 — 그 사실을 그 자리 주석이 든다.
    .{ .path = "src/cli/ssh.zig", .count = 1 },

    // ── 번역 대상 레이어(§7.2) ──
    // **표시 문자열이 아닌 것들** — 토크나이저 전환으로 드러났고, 각각 성격을 확인해 등재했다.
    //   · `shell_integration.zig` 48 — maru 가 쓰는 **셸 스크립트 본문·주석**이다. 사용자가 파일을
    //     열면 보지만 앱 UI 가 아니고, `agent_statusline` 의 설치 마커처럼 **파일 포맷의 일부**다.
    //   · `agent_statusline.zig` 5 — **셸 훅 스크립트 본문 3줄 + settings.json 에 쓰는 설치 마커 2개**다.
    //     바로 위 `shell_integration` 과 같은 성격(파일 포맷의 일부)이지 doc 주석이 아니다 — 새 스캐너는
    //     doc 주석을 애초에 토큰으로 세지 않으므로 그 근거는 성립할 수 없었다.
    //   · `remote_runtime.zig` 3 — 진단 문자열.
    .{ .path = "src/platform/macos/shell_integration.zig", .count = 48 },
    .{ .path = "src/chrome/components/confirm.zig", .count = 3 },
    .{ .path = "src/chrome/components/settings.zig", .count = 8 },
    .{ .path = "src/chrome/ui/visual_map.zig", .count = 1 },
    .{ .path = "src/config/loader.zig", .count = 25 },
    .{ .path = "src/config/schema.zig", .count = 28 },
    .{ .path = "src/platform/macos/agent_session_archive_backend.zig", .count = 3 },
    .{ .path = "src/platform/macos/app_pty_metal_smoke.zig", .count = 1 },
    .{ .path = "src/platform/macos/app_session.zig", .count = 16 },
    .{ .path = "src/platform/macos/app_session/debug_fixtures.zig", .count = 3 },
    .{ .path = "src/platform/macos/app_session/settings.zig", .count = 1 },
    .{ .path = "src/platform/macos/app_session/sidebar.zig", .count = 3 },
    .{ .path = "src/platform/macos/app_session/term.zig", .count = 1 },
    .{ .path = "src/platform/macos/chrome/lab.zig", .count = 15 },
    .{ .path = "src/platform/macos/chrome_lab_smoke.zig", .count = 2 },
    .{ .path = "src/platform/macos/control_server.zig", .count = 1 },
    .{ .path = "src/platform/macos/coretext_smoke.zig", .count = 9 },
    .{ .path = "src/platform/macos/glyph_text_smoke.zig", .count = 1 },
    .{ .path = "src/platform/macos/metal_smoke.zig", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_preparation.zig", .count = 1 },
    .{ .path = "src/platform/macos/session_host/remote_runtime.zig", .count = 3 },
    .{ .path = "src/platform/macos/session_host/remote_screen.zig", .count = 2 },
    .{ .path = "src/platform/macos/session_host/remote_term_backend.zig", .count = 2 },
    .{ .path = "src/platform/macos/session_host/shutdown_n1_baseline.zig", .count = 1 },
    .{ .path = "src/platform/macos/session_host/test_scratch.zig", .count = 2 },
    // 데모 바이트를 없애며 0 이 됐다(그 안의 한국어가 마지막 리터럴이었다 — 화면 문구는
    // 이미 전부 `i18n` 키다). **원장은 늘 실측으로 내린다**: 남겨 두면 새 리터럴 셋이
    // 들어와도 게이트가 조용하다.
    .{ .path = "src/platform/mobile/mobile_bridge.zig", .count = 0 },
    .{ .path = "src/session/agent_observer.zig", .count = 3 },
    .{ .path = "src/session/agent_selection.zig", .count = 1 },
    .{ .path = "src/session/agent_statusline.zig", .count = 5 },
    .{ .path = "src/session/control_bridge.zig", .count = 1 },
};

fn isHangulLead(b: u8) bool {
    return b == 0xEA or b == 0xEB or b == 0xEC or b == 0xED;
}

fn hasHangul(bytes: []const u8) bool {
    for (bytes) |b| if (isHangulLead(b)) return true;
    return false;
}

/// 제품 경로(= top-level `test` 블록 **밖**)의 한국어 문자열 리터럴 수.
///
/// **토크나이저로 센다.** 예전에는 줄 단위로 `{`/`}` 를 세어 test 블록 끝을 찾았는데, 그 방식은
/// **문자열·주석 안의 중괄호까지 세어** 한 번 어긋나면 그 파일의 나머지 전부를 test 로 오인한다.
/// 실측에서 19 개 파일이 그렇게 막혀 있었고, 그중 `app_host_abi.zig` 는 198 행에서 멈춰 브라우저
/// 권한 **동의문 3 건**(로그인 쿠키 접근을 묻는 문장)이 게이트를 그냥 통과했다.
///
/// 옆의 `cli_purity.zig` 가 같은 문제를 이미 토크나이저로 풀었다 — 그 방식을 그대로 쓴다.
/// 파싱 오류가 있는 파일은 **실패**시킨다(조용히 0 을 세면 그 파일이 영원히 감시 밖이 된다).
fn countSource(allocator: std.mem.Allocator, source: [:0]const u8) !usize {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);
    if (tree.errors.len != 0) return error.SourceHasParseErrors;

    var in_test = try allocator.alloc(bool, tree.tokens.len);
    defer allocator.free(in_test);
    @memset(in_test, false);

    // **모든 `test` 블록**의 토큰을 마스킹한다. 깊이로 top-level 만 고르지 않는 이유: Zig 에서 `test` 는
    // top-level 이거나 struct 멤버뿐이고 **둘 다 테스트 코드**다. 깊이 추적은 `.{` 같은 토큰 때문에
    // 어긋나기 쉬운데, 한 번 어긋나면 test 이름 문자열까지 제품 코드로 세어 게이트가 거짓 경보를 낸다.
    const tags = tree.tokens.items(.tag);
    var token: std.zig.Ast.TokenIndex = 0;
    while (token < tree.tokens.len) {
        if (tags[token] == .keyword_test) {
            var cursor = token;
            var body_depth: usize = 0;
            var body_started = false;
            while (cursor < tree.tokens.len) : (cursor += 1) {
                in_test[cursor] = true;
                switch (tags[cursor]) {
                    .l_brace => {
                        body_started = true;
                        body_depth += 1;
                    },
                    .r_brace => {
                        if (!body_started or body_depth == 0) return error.SourceHasParseErrors;
                        body_depth -= 1;
                        if (body_depth == 0) break;
                    },
                    else => {},
                }
            }
            if (!body_started or body_depth != 0 or cursor == tree.tokens.len) return error.SourceHasParseErrors;
            token = cursor + 1;
            continue;
        }
        token += 1;
    }

    // 문자열 리터럴 토큰만 센다 — 주석은 애초에 토큰이 아니고, 멀티라인(`\\`)도 여기서 잡힌다.
    var total: usize = 0;
    for (tree.tokens.items(.tag), 0..) |tag, i| {
        if (in_test[i]) continue;
        switch (tag) {
            .string_literal, .multiline_string_literal_line => {
                if (hasHangul(tree.tokenSlice(@intCast(i)))) total += 1;
            },
            else => {},
        }
    }
    return total;
}

fn lookup(path: []const u8) ?usize {
    for (inventory) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.count;
    }
    return null;
}

/// 원장과 어긋나면 **무엇을 어떻게 고칠지** 말하고 false 를 돌려준다. 두 축(§7.2 번역 대상 ·
/// §7.1 영어 고정)이 같은 규칙을 쓰도록 한 자리에 둔다.
fn reportIfDrifted(path: []const u8, found: usize) bool {
    const expected = lookup(path) orelse 0;
    if (found == expected) return true;

    if (found > expected) {
        std.debug.print(
            \\
            \\{s}: 한국어 리터럴 {d} 개 (원장 {d}) — **늘었다**.
            \\  번역 대상 레이어면(§7.2) `src/i18n.zig` 에 키를 만들고 `i18n.t(.key)` 로 쓴다.
            \\  영어 고정 표면이면(§7.1 — `src/cli`·`src/main.zig`) 그냥 **영어로 적는다**.
            \\  표시가 아니면(진단·로그·fixture) 그 사실을 코드 주석에 적고 원장을 올린다.
            \\  단일 출처: docs/i18n.md §7.
            \\
        , .{ path, found, expected });
    } else {
        std.debug.print(
            \\
            \\{s}: 한국어 리터럴 {d} 개 (원장 {d}) — **줄었다**. 원장을 이 값으로 낮춰라.
            \\  줄어든 것을 통과시키면 원장이 헐거워져 나중에 새 리터럴이 그 여유에 숨는다.
            \\
        , .{ path, found, expected });
    }
    return false;
}

test "번역 대상 레이어의 한국어 리터럴은 원장보다 늘지 않는다" {
    const allocator = std.testing.allocator;
    var failed = false;
    var scanned: usize = 0;

    for (roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(std.testing.io);

        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();

        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, entry.path });
            if (std.mem.endsWith(u8, path, "i18n.zig")) continue;

            const source = try dir.readFileAllocOptions(
                std.testing.io,
                entry.path,
                allocator,
                .limited(8 * 1024 * 1024),
                .of(u8),
                0,
            );
            defer allocator.free(source);

            scanned += 1;
            if (!reportIfDrifted(path, try countSource(allocator, source))) failed = true;
        }
    }

    // 영어 고정 표면(§7.1)도 같은 원장으로 본다 — 규칙은 다르지만(키가 아니라 영어) **한국어가 늘면
    // 안 된다**는 점이 같고, 한 자리에서 세는 편이 원장을 나누는 것보다 어긋날 여지가 적다.
    for (english_only_roots) |root| {
        var dir = std.Io.Dir.cwd().openDir(std.testing.io, root, .{ .iterate = true }) catch continue;
        defer dir.close(std.testing.io);

        var walker = try posixWalk(dir, allocator);
        defer walker.deinit();

        while (try walker.next(std.testing.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;

            var path_buf: [512]u8 = undefined;
            const path = try std.fmt.bufPrint(&path_buf, "{s}/{s}", .{ root, entry.path });
            const source = try dir.readFileAllocOptions(std.testing.io, entry.path, allocator, .limited(8 * 1024 * 1024), .of(u8), 0);
            defer allocator.free(source);

            scanned += 1;
            if (!reportIfDrifted(path, try countSource(allocator, source))) failed = true;
        }
    }
    for (english_only_files) |path| {
        const source = std.Io.Dir.cwd().readFileAllocOptions(std.testing.io, path, allocator, .limited(8 * 1024 * 1024), .of(u8), 0) catch continue;
        defer allocator.free(source);
        scanned += 1;
        if (!reportIfDrifted(path, try countSource(allocator, source))) failed = true;
    }

    // 훑을 파일이 없다면 경로가 바뀐 것이다 — 0 을 통과시키면 "규칙이 지켜진다"와 "아무것도 안 봤다"를
    // 구분할 수 없어진다.
    try std.testing.expect(scanned > 0);
    try std.testing.expect(!failed);
}
