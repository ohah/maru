//! 릴리스 워크플로가 **체크아웃 전에 `gh` 를 붙든다**는 계약(§checkout-before-trust)을 텍스트로 지킨다.
//!
//! **왜 텍스트 대조인가.** 이 계약이 지켜지는지는 워크플로를 실제로 돌려야 알 수 있는 종류가 아니다 —
//! 「어느 단계가 어느 단계보다 앞이다」·「Action 이 40 자리 SHA 로 못박혀 있다」·「비밀이 `GITHUB_ENV`
//! 가 아니라 `GITHUB_OUTPUT` 으로 나간다」는 전부 **파일에 적힌 사실**이다. 그리고 그것들이 조용히
//! 무너지는 방식이 바로 「누가 한 줄 옮겼다」라서, 파일을 읽는 판정이 제자리다.
//!
//! **`sh` 스크립트에서 옮겨 왔다**(`tools/test-session-host-release-workflow.sh`, §2m.110). 옮긴 이유는
//! 그 스크립트가 `zig build test` 에 매달려 있어서 **게이트 자신이 POSIX 셸을 요구했기** 때문이다 —
//! Windows 에서 셸이 PATH 에 없으면 계약과 아무 상관 없는 이유로 게이트가 통째로 빨개진다(§2m.109).
//! 재는 것은 한 톨도 안 바꿨다: 아래 판정은 그 스크립트의 `test` 줄과 일대일이다.

const std = @import("std");

const workflow_path = ".github/workflows/release.yml";

/// 이 워크플로가 못박아야 하는 checkout Action 의 커밋. **버전 태그가 아니라 SHA 다** — 태그는
/// 옮겨 달 수 있고, 옮겨 달리면 우리가 검증한 적 없는 코드가 릴리스 파이프라인 안에서 돈다.
const pinned_checkout = "uses: actions/checkout@34e114876b0b11c390a56381ad16ebd13914f8d5";

fn readWorkflow(arena: std.mem.Allocator) ![]const u8 {
    return std.Io.Dir.cwd().readFileAlloc(std.testing.io, workflow_path, arena, .limited(1024 * 1024));
}

/// `needle` 을 **정확히 그 내용인 줄**로 세는 수. 원본 스크립트의 `grep -c '^…$'` 다 —
/// 부분 일치로 세면 들여쓰기가 바뀌어도 통과해 「어느 블록 안이냐」가 흐려진다.
fn countExactLines(text: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trimEnd(u8, line, "\r");
        if (std.mem.eql(u8, trimmed, needle)) n += 1;
    }
    return n;
}

/// `needle` 이 든 **줄의 수**(한 줄에 두 번 나와도 1). 원본의 `grep -c <패턴>` 과 같은 셈이다 —
/// `grep -c` 는 일치 횟수가 아니라 **일치한 줄 수**를 센다.
fn countMatchingLines(text: []const u8, needle: []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, needle) != null) n += 1;
    }
    return n;
}

/// `needle` 이 처음 나오는 줄 번호(1-based). 없으면 `null`.
fn lineOf(text: []const u8, needle: []const u8) ?usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        n += 1;
        if (std.mem.indexOf(u8, line, needle) != null) return n;
    }
    return null;
}

/// `start_line` 이 있는 줄부터 `end_needle` 이 나오는 줄 **직전**까지. 원본의
/// `sed -n '/start/,/end/p' | sed '$d'` 와 같다 — 끝 줄을 빼는 것이 요점이다(그 줄은 다음 단계다).
fn blockUntil(text: []const u8, start_line: []const u8, end_needle: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, text, start_line) orelse return null;
    const rest = text[start..];
    const end_rel = std.mem.indexOf(u8, rest, end_needle) orelse return null;
    // 끝 표식이 든 줄의 머리로 되돌아간다.
    const line_start = if (std.mem.lastIndexOfScalar(u8, rest[0..end_rel], '\n')) |nl| nl + 1 else 0;
    return rest[0..line_start];
}

test "릴리스 워크플로: 신뢰 획득 단계가 체크아웃보다 **앞**이다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try readWorkflow(arena_state.allocator());

    // 단계가 하나뿐이어야 한다 — 둘이면 어느 쪽이 앞인지 아래 순서 판정이 답을 못 낸다.
    try std.testing.expectEqual(@as(usize, 1), countExactLines(text, "    environment: release"));
    try std.testing.expectEqual(@as(usize, 1), countExactLines(text, "    runs-on: macos-15"));
    try std.testing.expectEqual(@as(usize, 1), countExactLines(text, "      - name: Capture trusted GitHub CLI before checkout"));
    try std.testing.expectEqual(@as(usize, 1), countExactLines(text, "        id: trusted-gh"));
    try std.testing.expectEqual(@as(usize, 1), countMatchingLines(text, pinned_checkout));
    try std.testing.expectEqual(@as(usize, 1), countMatchingLines(text, "command -v gh"));

    // **이 한 줄이 이 파일의 요점이다.** 체크아웃 뒤에 `gh` 를 찾으면 그 PATH 는 방금 받아 온
    // 저장소가 건드릴 수 있는 것이라, 무엇을 붙들었는지 우리가 말할 수 없게 된다.
    const capture_line = lineOf(text, "      - name: Capture trusted GitHub CLI before checkout").?;
    const checkout_line = lineOf(text, pinned_checkout).?;
    try std.testing.expect(capture_line < checkout_line);
}

test "릴리스 워크플로: 붙든 `gh` 를 실제로 검증하고 그 결과가 output 으로만 나간다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try readWorkflow(arena_state.allocator());

    const block = blockUntil(
        text,
        "      - name: Capture trusted GitHub CLI before checkout",
        "      - uses: actions/checkout@",
    ) orelse return error.CaptureBlockMissing;

    try std.testing.expectEqual(@as(usize, 1), countMatchingLines(block, "command -v gh"));
    // 절대 경로로 펴서 심볼릭 링크를 지난다.
    try std.testing.expectEqual(@as(usize, 1), countMatchingLines(block, "/usr/bin/realpath"));
    // 정규 파일인가 · 해시가 무엇인가 — 「무엇을 붙들었나」를 기록으로 남기는 두 줄.
    try std.testing.expectEqual(@as(usize, 1), countMatchingLines(block, "/usr/bin/stat -f '%HT'"));
    try std.testing.expectEqual(@as(usize, 1), countMatchingLines(block, "/usr/bin/shasum -a 256"));

    // 경로에 개행·CR 이 든 경우를 거른다. 원본은 이것을 `\$canonical.*\\n.*\$canonical.*\\r` 로
    // 재는데, 한 줄 안에서 **그 순서로** 넷이 나오는지를 본 것이다.
    //
    // **개수까지 본다(`= 1`).** 처음에는 「있기만 하면」으로 옮겼는데, 원본은 `grep -c … = 1` 이라
    // 그 가드가 **둘로 늘어도** 빨개진다. 적대적 검증 1 회차가 그 차이를 잡았다.
    try std.testing.expectEqual(@as(usize, 1), countOrderedOnOneLine(block, &.{ "$canonical", "\\n", "$canonical", "\\r" }));

    // **`GITHUB_ENV` 가 아니라 `GITHUB_OUTPUT` 이다.** env 로 내보내면 그 값이 뒤따르는 모든 단계의
    // 환경에 남는다 — 이 워크플로가 굳이 output 두 줄로 가르는 이유다.
    try std.testing.expectEqual(@as(usize, 1), countMatchingLines(block, "path=%s\\n"));
    try std.testing.expectEqual(@as(usize, 1), countMatchingLines(block, "sha256=%s\\n"));
    try std.testing.expectEqual(@as(usize, 2), countMatchingLines(block, "GITHUB_OUTPUT"));
    try std.testing.expectEqual(@as(usize, 0), countMatchingLines(block, "GITHUB_ENV"));
}

/// 한 줄 안에 `parts` 가 **그 순서대로** 모두 나오는 줄의 **수**. 원본의 `grep -c <순서 정규식>` 이다.
fn countOrderedOnOneLine(text: []const u8, parts: []const []const u8) usize {
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    line: while (it.next()) |line| {
        var at: usize = 0;
        for (parts) |p| {
            const found = std.mem.indexOfPos(u8, line, at, p) orelse continue :line;
            at = found + p.len;
        }
        n += 1;
    }
    return n;
}

test "릴리스 워크플로: 모든 Action 이 40 자리 SHA 로 못박혀 있다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try readWorkflow(arena_state.allocator());

    var it = std.mem.splitScalar(u8, text, '\n');
    var seen: usize = 0;
    lines: while (it.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        const uses_at = std.mem.indexOf(u8, line, "uses:") orelse continue;
        // `uses:` 앞은 공백과 목록 표식(`-`)만이어야 한다 — 주석이나 문장 속 `uses:` 는 대상이 아니다.
        //
        // **라벨이 필요하다.** 라벨 없는 `continue` 는 이 `for` 를 잇지 바깥 줄 루프를 안 잇는다 —
        // 그러면 걸러야 할 줄이 그대로 아래로 내려간다(처음 그렇게 적었다가 스스로 잡았다).
        for (line[0..uses_at]) |c| if (c != ' ' and c != '\t' and c != '-') continue :lines;
        var rest = std.mem.trimStart(u8, line[uses_at + "uses:".len ..], " \t");
        // 뒤 주석(`# v4`)을 자른다.
        if (std.mem.indexOfAny(u8, rest, " \t#")) |cut| rest = rest[0..cut];
        if (rest.len == 0) continue;
        seen += 1;

        // **`@` 는 정확히 하나여야 한다.** 원본 정규식이 `^[^@[:space:]]+@…$` 라 이름 쪽에 `@` 를 못
        // 넣는다. 처음에는 `lastIndexOf` 로 잘랐는데 그러면 `evil@thing@<40자리>` 가 **통과한다** —
        // 핀 검사에서 그것이 새면 검사가 있으나 마나다(적대적 검증 1 회차).
        const at = std.mem.indexOfScalar(u8, rest, '@') orelse {
            std.debug.print("unpinned Action (no @): {s}\n", .{rest});
            return error.UnpinnedAction;
        };
        const sha = rest[at + 1 ..];
        if (std.mem.indexOfScalar(u8, sha, '@') != null) {
            std.debug.print("unpinned Action (more than one @): {s}\n", .{rest});
            return error.UnpinnedAction;
        }
        if (sha.len != 40) {
            std.debug.print("unpinned Action (not a 40-hex SHA): {s}\n", .{rest});
            return error.UnpinnedAction;
        }
        for (sha) |c| if (!std.ascii.isHex(c) or std.ascii.isUpper(c)) {
            std.debug.print("unpinned Action (not lowercase hex): {s}\n", .{rest});
            return error.UnpinnedAction;
        };
    }
    // **하나도 못 찾았으면 판정이 빈 것이다.** 형식이 바뀌어 파서가 헛돌면 위 루프는 조용히 통과한다.
    try std.testing.expect(seen > 0);
}

test "릴리스 워크플로: 태그 push 로만 켜진다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const text = try readWorkflow(arena_state.allocator());

    // **트리거를 통째로 고정한다.** 「`workflow_dispatch` 를 하나 더했다」가 이 파이프라인에서는
    // 「아무 브랜치에서나 릴리스를 쏠 수 있다」와 같은 말이다.
    // **줄바꿈을 찾는 바늘에 넣지 않는다.** `"on:\n"` 으로 찾으면 CRLF 작업 트리에서 아예 못 찾는다
    // (실측: `TriggerBlockMissing`). 줄 머리를 먼저 찾고 거기서부터 자른다.
    const on_at = std.mem.indexOf(u8, text, "\non:") orelse return error.TriggerBlockMissing;
    const block = blockUntil(text[on_at + 1 ..], "on:", "permissions:") orelse return error.TriggerBlockMissing;
    // **끝 공백을 턴다.** 원본은 `$(...)` 로 받았고 그것이 끝 개행을 지운다 — 그래서 `permissions:`
    // 앞의 빈 줄이 비교에 안 들어갔다. 안 털면 그 빈 줄 하나 때문에 옮긴 판정이 원본과 달라진다.
    //
    // **CR 도 턴다.** `core.autocrlf=true` 로 받은 작업 트리에서는 이 파일이 CRLF 다 — 그러면 통짜
    // 비교가 계약과 아무 상관 없는 이유로 깨진다(원본 스크립트도 같은 약점이었다). 이 판정이 재는
    // 것은 **트리거의 내용**이지 그 파일의 줄바꿈이 아니다.
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(std.testing.allocator);
    for (std.mem.trimEnd(u8, block, "\r\n")) |c| if (c != '\r') try buf.append(std.testing.allocator, c);
    const want = "on:\n  push:\n    tags: [\"v*\"]";
    try std.testing.expectEqualStrings(want, buf.items);
}
