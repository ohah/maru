// 이 테스트는 **"번역 대상 레이어에 새 한국어 리터럴이 들어오지 않는다"** 를 강제한다
// (docs/i18n.md §7.2 의 2 차 방어).
//
// **무엇을 증명하나.** 표시 문자열은 `src/i18n.zig` 의 테이블이 소유하고 코드는 키만 든다. 그 규율이
// 지켜지는 한 언어를 바꾸면 화면 전체가 따라오지만, **한 자리라도 리터럴로 새면 그 자리만 한국어로
// 남는다** — 크래시도 경고도 없이. 계약 §7.2 는 1 차 방어(파라미터를 `i18n.Key` 로)를 세울 수 없는
// sink 가 있다고 적었다(`context_menu_items_buf` 처럼 정적·동적이 한 배열에 섞이는 자리). 거기서는
// 이 검사가 유일한 방어다.
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

/// 번역 대상 레이어. 여기 밖(`src/cli`·`src/main.zig`)은 **영어 고정**이라 계약 §7.1 이 다른 규칙을 준다.
const roots = [_][]const u8{ "src/chrome", "src/session", "src/platform/macos", "src/platform/mobile", "src/config" };

const Entry = struct { path: []const u8, count: usize };

/// 파일별 남은 한국어 리터럴 수. **늘면 실패**하고, **줄어도 실패**한다(원장을 함께 줄이라는 뜻).
/// 새 파일이 한글 리터럴을 들고 나타나면 원장에 없으므로 실패한다 — 그것이 이 게이트의 본래 목적이다.
const inventory = [_]Entry{
    .{ .path = "src/chrome/components/archive_detail/build.zig", .count = 3 },
    .{ .path = "src/chrome/components/archive_detail/view.zig", .count = 4 },
    .{ .path = "src/chrome/components/confirm.zig", .count = 3 },
    .{ .path = "src/chrome/components/find.zig", .count = 2 },
    .{ .path = "src/chrome/components/settings.zig", .count = 8 },
    .{ .path = "src/chrome/ui/visual_map.zig", .count = 1 },
    .{ .path = "src/config/loader.zig", .count = 27 },
    .{ .path = "src/config/schema.zig", .count = 28 },
    .{ .path = "src/platform/macos/agent_session_archive_backend.zig", .count = 3 },
    .{ .path = "src/platform/macos/app_pty_metal_smoke.zig", .count = 1 },
    .{ .path = "src/platform/macos/app_session.zig", .count = 16 },
    .{ .path = "src/platform/macos/app_session/debug_fixtures.zig", .count = 3 },
    .{ .path = "src/platform/macos/app_session/settings.zig", .count = 5 },
    .{ .path = "src/platform/macos/app_session/sidebar.zig", .count = 3 },
    .{ .path = "src/platform/macos/app_session/term.zig", .count = 1 },
    .{ .path = "src/platform/macos/chrome/lab.zig", .count = 15 },
    .{ .path = "src/platform/macos/chrome_lab_smoke.zig", .count = 2 },
    .{ .path = "src/platform/macos/control_server.zig", .count = 1 },
    .{ .path = "src/platform/macos/coretext_smoke.zig", .count = 3 },
    .{ .path = "src/platform/macos/glyph_text_smoke.zig", .count = 1 },
    .{ .path = "src/platform/macos/metal_smoke.zig", .count = 1 },
    .{ .path = "src/platform/macos/session_host/pending_event_preparation.zig", .count = 1 },
    .{ .path = "src/platform/macos/session_host/remote_runtime.zig", .count = 2 },
    .{ .path = "src/platform/macos/session_host/remote_screen.zig", .count = 2 },
    .{ .path = "src/platform/macos/session_host/remote_term_backend.zig", .count = 2 },
    .{ .path = "src/platform/macos/session_host/shutdown_n1_baseline.zig", .count = 1 },
    .{ .path = "src/platform/macos/session_host/test_scratch.zig", .count = 2 },
    .{ .path = "src/platform/mobile/mobile_bridge.zig", .count = 3 },
    .{ .path = "src/session/agent_observer.zig", .count = 3 },
    .{ .path = "src/session/agent_selection.zig", .count = 1 },
    .{ .path = "src/session/agent_statusline.zig", .count = 2 },
    .{ .path = "src/session/control_bridge.zig", .count = 1 },
};

fn isHangulLead(b: u8) bool {
    return b == 0xEA or b == 0xEB or b == 0xEC or b == 0xED;
}

/// 한 줄에서 **문자열 리터럴 안의** 한글 존재 여부로 리터럴을 센다. 주석은 문자열 밖의 `//` 부터 자른다.
fn countLine(line: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    var in_str = false;
    var has_hangul = false;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (in_str) {
            if (c == '\\') {
                i += 1;
                continue;
            }
            if (c == '"') {
                in_str = false;
                if (has_hangul) n += 1;
                has_hangul = false;
                continue;
            }
            if (isHangulLead(c)) has_hangul = true;
        } else {
            if (c == '"') {
                in_str = true;
                has_hangul = false;
            } else if (c == '/' and i + 1 < line.len and line[i + 1] == '/') break;
        }
    }
    return n;
}

/// `test` 블록을 뺀 제품 경로만 센다. 첫 `test` 이후를 통째로 자르지 않는다 — 그 뒤에도 제품 코드가
/// 이어지는 파일이 있다(`app_session.zig` 가 그렇다). 중괄호 깊이로 블록 끝을 찾는다.
fn countSource(src: []const u8) usize {
    var total: usize = 0;
    var in_test = false;
    var depth: i32 = 0;
    var it = std.mem.splitScalar(u8, src, '\n');
    while (it.next()) |line| {
        if (!in_test and std.mem.startsWith(u8, line, "test \"")) {
            in_test = true;
            depth = 0;
            for (line) |c| {
                if (c == '{') depth += 1;
                if (c == '}') depth -= 1;
            }
            continue;
        }
        if (in_test) {
            for (line) |c| {
                if (c == '{') depth += 1;
                if (c == '}') depth -= 1;
            }
            if (depth <= 0) in_test = false;
            continue;
        }
        total += countLine(line);
    }
    return total;
}

fn lookup(path: []const u8) ?usize {
    for (inventory) |e| {
        if (std.mem.eql(u8, e.path, path)) return e.count;
    }
    return null;
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
            const found = countSource(source);
            const expected = lookup(path) orelse 0;
            if (found == expected) continue;

            failed = true;
            if (found > expected) {
                std.debug.print(
                    \\
                    \\{s}: 한국어 리터럴 {d} 개 (원장 {d}) — **늘었다**.
                    \\  표시 문자열이면 `src/i18n.zig` 에 키를 만들고 `i18n.t(.key)` 로 쓴다.
                    \\  표시가 아니면(진단·로그·fixture) 그 사실을 코드 주석에 적고 원장을 올린다.
                    \\  단일 출처: docs/i18n.md §7.2.
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
        }
    }

    // 훑을 파일이 없다면 경로가 바뀐 것이다 — 0 을 통과시키면 "규칙이 지켜진다"와 "아무것도 안 봤다"를
    // 구분할 수 없어진다.
    try std.testing.expect(scanned > 0);
    try std.testing.expect(!failed);
}
