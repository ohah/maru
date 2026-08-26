// 이 테스트는 **`src/cli`의 순수/impure 경계**를 강제한다(docs/project-structure.md `src/cli/`).
//
// **무엇을 증명하나.** `cli/`의 제품 코드는 파싱·wire·렌더 같은 순수 로직만 갖고, 소켓·프로세스·파일시스템
// syscall은 명시된 예외 파일에만 있다. 그 순수성이 파서·`buildRequestBytes`·`renderResponse`·
// `*StreamValidator`를 **살아 있는 앱 없이** 단위 테스트로 못박을 수 있는 이유다 — 터미널에서 중요한 건
// 이 조각들이 컨트롤 플레인 wire의 검증 경계이고(§9.5·§9.6), 그것을 소켓 없이 확인할 수 없게 되는 순간
// 회귀가 GUI 손 테스트로만 잡히기 때문이다.
//
// **왜 게이트가 필요한가 — 이 규칙은 실제로 주석에만 있었다.** `cli/browser.zig`는 파일 머리에 "L2 순수:
// std + control_plane(1a)만. 소켓/OS 0"을, `cli/sessions.zig`는 "파싱·요청 조립·응답 포맷 같은 테스트 가능한
// 로직은 여기"를 적어 두었다. 그런데 2026-08-16 전수 조사 결과 `tests/boundary/imports.zig`가 강제하는
// 레이어는 chrome·session·terminal·pty·renderer·plugin·session_host뿐이고 **`src/cli` 규칙은 0개**였다.
// 즉 그 계약은 컴파일러도 CI도 본 적이 없다.
//
// 그 상태에서 소켓 접착을 `main.zig`에서 `cli/`로 옮기며 "예외는 두 파일뿐"이라고 문서에 적었는데, 그것도
// 문서상의 약속일 뿐이었다. `docs/facade-contracts.md`는 **"import boundary는 테스트로 확인한다. 단순히
// '조심한다'는 규칙만으로 경계를 지켰다고 보지 않는다"**고 정하고, 바로 옆 `cwd_axis.zig`가 같은 실패를
// 이미 기록해 두었다 — 규칙이 주석에만 있던 동안 소비자 여섯이 갈렸다. 같은 결의 소스 스캔으로 닫는다.
//
// **규칙**: `src/cli/**`의 파일에서 top-level `test` 블록을 제외한 영역의 impure 토큰 수가 아래 재고와
// 정확히 같아야 한다. 재고에 없는 파일은 **0**이다(새 파일이 생기면 자동으로 이 규칙을 받는다).
//
// **0건 규칙을 전역으로 세울 수 없는 이유**는 두 가지이고 재고가 그 둘을 구분한다.
//   - `control_client.zig`·`browser/run.zig`·`control_relay.zig`: **의도된 예외**. 이 파일들의
//     존재 이유가 접착이다.
//   - `ssh.zig`: **테스트 전용 헬퍼**. `spawnShell`/`drainShell`과 그 호출자(`expectNotifyLifecycle`이
//     신호 수명을, `runSessionLoop`이 재접속 루프를 실제 `/bin/sh`로 실측한다)가 top-level `fn`이라
//     `test` 블록 마스크에 걸리지 않는다. 제품 경로는 순수하다.
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   - 예외 파일 **안에서** impure가 늘어나는 것은 못 본다. 개수를 고정하면 정상적인 리팩터마다 재고가
//     흔들려 규칙이 소음이 되므로, 두 예외 파일은 개수를 세지 않고 `.exempt`로 둔다.
//   - `@import("std").c`처럼 별칭을 거쳐 부르면 토큰이 달라져 안 잡힌다(2026-08-16 기준 이 트리에 없다).
//   - 테스트 헬퍼를 **파일 앞쪽**에 두면 `test` 마스크 뒤가 아니라서 위반으로 잡힌다. 그건 오탐이 아니라
//     "제품 코드와 테스트 코드를 섞지 말라"는 신호로 읽는 편이 낫다.
//   - 순수성의 **의미**까지는 못 본다. 무한 루프나 전역 상태는 이 스캔의 대상이 아니다.
const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("posix_walk.zig").posixWalk;

/// impure 판정 토큰. 셋 다 "OS에 직접 말한다"는 뜻이고, 순수 CLI 로직이라면 나올 이유가 없다.
/// `std.Io.Writer`는 **일부러 뺐다** — 렌더러가 출력을 쓰는 정상 경로라 넣으면 순수 파일 전부가 걸린다.
const impure_tokens = [_][]const u8{
    "std.c.", // 소켓·프로세스·signal syscall
    "std.posix", // POSIX 상수/errno
    "std.Io.Dir", // 디렉터리 순회·열기
    "std.Io.File", // 파일 생성·읽기·쓰기
};

const Expectation = union(enum) {
    /// 제품 경로가 순수해야 하는 파일. test 블록 밖 impure 토큰이 정확히 이 개수여야 한다.
    exact: usize,
    /// 존재 이유가 접착인 파일. 개수를 세지 않는다(위 "막지 못하는 것" 참조).
    exempt,
};

const Entry = struct {
    /// `src/cli/` 기준 상대 경로(POSIX 구분자).
    path: []const u8,
    expect: Expectation,
    /// 재고에 오른 이유. 비워 두지 않는다 — 다음 사람이 이 줄을 지워도 되는지 판단할 근거다.
    why: []const u8,
};

const inventory = [_]Entry{
    .{
        .path = "control_client.zig",
        .expect = .exempt,
        .why = "cli/의 의도된 impure 예외 — 컨트롤 소켓 발견·connect·auth·왕복이 이 파일의 존재 이유다.",
    },
    .{
        .path = "control_relay.zig",
        .expect = .exempt,
        .why = "cli/의 의도된 impure 예외 — `maru control --stdio` 는 **중계 그 자체**라 poll/read/write 가 존재 이유다(S10c). 순수 절반(인자 판정·읽기 결과 분류·끝 문구)은 같은 파일 안에 있고 테스트가 그것만 따로 잰다.",
    },
    .{
        .path = "browser/run.zig",
        .expect = .exempt,
        .why = "cli/의 의도된 impure 예외 — browser.zig(순수)의 짝으로 응답 수신 read/close와 --out 원자 공개를 갖는다.",
    },
    .{
        .path = "incidents_run.zig",
        .expect = .exempt,
        .why = "cli/의 의도된 impure 예외 — incidents.zig(순수)의 짝으로 incident 디렉터리 열거와 봉투 읽기를 갖는다(browser.zig ↔ browser/run.zig와 같은 분할). 파싱·포맷은 순수 절반이 갖고 여긴 디스크 접착만 남는다.",
    },
    .{
        .path = "ssh.zig",
        .expect = .{ .exact = 36 },
        .why = "테스트 전용 fork/pipe 헬퍼(spawnShell·drainShell과 그 호출자 expectNotifyLifecycle·runSessionLoop)가 top-level fn이라 test 마스크에 안 걸린다. 제품 경로는 순수하다. 20→24는 재접속 루프를 실제 /bin/sh로 돌리는 하네스가 붙은 몫이고, fork 절차 자체는 spawnShell 하나로 합쳐 뒀다(따로 들면 33이었다). 24→36은 셸이 신호를 받고도 안 죽어 waitpid가 영영 안 끝나던 hang(2026-08-26 실측: 멈춘 test 바이너리 5개, 고아 스핀 셸 26개)을 닫은 몫이다 — restoreDefaultSignals(+5, exec 직전 disposition 복원)·waitpidWithin(+5, WNOHANG 폴링 데드라인)·reapRunaway(+4, 데드라인 초과 자식 수거)에서 늘고 무한 waitpid 두 자리가 사라져 -2 다.",
    },
};

fn expectationFor(rel: []const u8) Expectation {
    for (inventory) |entry| {
        if (std.mem.eql(u8, entry.path, rel)) return entry.expect;
    }
    return .{ .exact = 0 };
}

/// top-level `test` 블록의 토큰을 가리는 마스크. `imports.zig`의 `topLevelTestTokenMask`와 같은 규율이다 —
/// 테스트는 동작을 실측하느라 일부러 impure를 쓰므로 그것까지 세면 재고가 테스트 변경마다 흔들린다.
fn topLevelTestTokenMask(allocator: std.mem.Allocator, tree: *const std.zig.Ast) ![]bool {
    if (tree.errors.len != 0) return error.TestUnexpectedResult;
    const excluded = try allocator.alloc(bool, tree.tokens.len);
    errdefer allocator.free(excluded);
    @memset(excluded, false);

    var lexical_depth: usize = 0;
    var token: std.zig.Ast.TokenIndex = 0;
    while (token < tree.tokens.len) {
        const part = tree.tokenSlice(token);
        if (lexical_depth == 0 and std.mem.eql(u8, part, "test")) {
            var cursor = token;
            var body_depth: usize = 0;
            var body_started = false;
            while (cursor < tree.tokens.len) : (cursor += 1) {
                excluded[cursor] = true;
                const body_part = tree.tokenSlice(cursor);
                if (std.mem.eql(u8, body_part, "{")) {
                    body_started = true;
                    body_depth += 1;
                } else if (std.mem.eql(u8, body_part, "}")) {
                    if (!body_started or body_depth == 0) return error.TestUnexpectedResult;
                    body_depth -= 1;
                    if (body_depth == 0) break;
                }
            }
            if (!body_started or body_depth != 0 or cursor == tree.tokens.len)
                return error.TestUnexpectedResult;
            token = cursor + 1;
            continue;
        }
        if (std.mem.eql(u8, part, "{")) {
            lexical_depth += 1;
        } else if (std.mem.eql(u8, part, "}")) {
            if (lexical_depth == 0) return error.TestUnexpectedResult;
            lexical_depth -= 1;
        }
        token += 1;
    }
    if (lexical_depth != 0) return error.TestUnexpectedResult;
    return excluded;
}

/// test 블록 밖에서 impure 토큰이 몇 번 나오는지 센다.
///
/// 토큰 하나씩 보지 않고 **줄 단위**로 세는 이유: `std.c.read`는 Ast에서 `std`·`.`·`c`·`.`·`read` 다섯
/// 토큰이라 토큰 비교로는 접두 매칭을 재구현해야 한다. test 블록의 줄 범위만 마스크에서 얻고 그 밖의
/// 줄에서 부분 문자열을 세면 같은 답을 훨씬 단순하게 얻는다.
fn countImpureOutsideTests(allocator: std.mem.Allocator, source: [:0]const u8) !usize {
    var tree = try std.zig.Ast.parse(allocator, source, .zig);
    defer tree.deinit(allocator);

    const excluded = try topLevelTestTokenMask(allocator, &tree);
    defer allocator.free(excluded);

    // 마스크된 토큰이 차지하는 바이트 구간을 모아 둔다.
    var masked = try allocator.alloc(bool, source.len);
    defer allocator.free(masked);
    @memset(masked, false);
    for (excluded, 0..) |is_test, i| {
        if (!is_test) continue;
        const span = tree.tokenSlice(@intCast(i));
        const start = tree.tokenStart(@intCast(i));
        const end = @min(start + span.len, source.len);
        @memset(masked[start..end], true);
    }
    // 토큰 사이 공백/주석도 test 블록 안이면 함께 가린다(첫 토큰~마지막 토큰 구간을 통째로).
    var first: ?usize = null;
    var last: usize = 0;
    for (excluded, 0..) |is_test, i| {
        if (!is_test) continue;
        const start = tree.tokenStart(@intCast(i));
        if (first == null) first = start;
        last = @max(last, start);
        // 연속 구간 판정을 위해 매 토큰마다 그 앞 토큰과의 사이를 가린다.
        if (i > 0 and excluded[i - 1]) {
            const prev_start = tree.tokenStart(@intCast(i - 1));
            @memset(masked[prev_start..start], true);
        }
    }

    var count: usize = 0;
    for (impure_tokens) |needle| {
        var idx: usize = 0;
        while (std.mem.indexOfPos(u8, source, idx, needle)) |at| {
            idx = at + needle.len;
            if (masked[at]) continue; // test 블록 안 — 세지 않는다
            count += 1;
        }
    }
    return count;
}

fn readSource(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    return std.Io.Dir.cwd().readFileAllocOptions(
        std.testing.io,
        path,
        allocator,
        .limited(4 * 1024 * 1024),
        .of(u8),
        0,
    );
}

/// `src/cli` 아래를 **재귀로** 훑는다. `browser/run.zig`가 하위 폴더에 있으므로 비재귀면 규칙에 구멍이 난다
/// (cwd_axis.zig가 비재귀라 남긴 한계를 여기서는 처음부터 닫는다). 구분자 정규화는 정본 posixWalk가 한다.
fn collectCliFiles(allocator: std.mem.Allocator, out: *std.ArrayList([]u8)) !void {
    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, "src/cli", .{ .iterate = true });
    defer dir.close(std.testing.io);

    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        try out.append(allocator, try allocator.dupe(u8, entry.path));
    }
}

test "cli/ 제품 코드는 순수하고, impure 예외는 재고에 적힌 파일뿐이다" {
    const allocator = std.testing.allocator;

    var files: std.ArrayList([]u8) = .empty;
    defer {
        for (files.items) |f| allocator.free(f);
        files.deinit(allocator);
    }
    try collectCliFiles(allocator, &files);

    // 스캐너가 아무 파일도 못 찾으면 규칙이 공허하게 통과한다 — 그 상태를 실패로 만든다.
    try std.testing.expect(files.items.len >= 8);

    var violations: usize = 0;
    for (files.items) |rel| {
        const full = try std.fmt.allocPrint(allocator, "src/cli/{s}", .{rel});
        defer allocator.free(full);
        const source = try readSource(allocator, full);
        defer allocator.free(source);

        const found = try countImpureOutsideTests(allocator, source);
        switch (expectationFor(rel)) {
            .exempt => {
                // 예외 파일이 순수해졌다면 재고에서 빼야 한다 — 그것도 드리프트다.
                if (found == 0) {
                    std.debug.print("cli purity: {s}가 더는 impure하지 않다 — 재고에서 빼라\n", .{rel});
                    violations += 1;
                }
            },
            .exact => |want| {
                if (found != want) {
                    std.debug.print(
                        "cli purity: {s} impure 토큰 {d}개 (재고 {d}개)\n",
                        .{ rel, found, want },
                    );
                    violations += 1;
                }
            },
        }
    }
    try std.testing.expectEqual(@as(usize, 0), violations);
}

test "재고의 모든 항목은 실재하는 파일이고 사유가 비어 있지 않다" {
    const allocator = std.testing.allocator;
    for (inventory) |entry| {
        // 사유 없는 예외는 다음 사람이 지워도 되는지 판단할 수 없다.
        try std.testing.expect(entry.why.len > 0);

        const full = try std.fmt.allocPrint(allocator, "src/cli/{s}", .{entry.path});
        defer allocator.free(full);
        _ = std.Io.Dir.cwd().statFile(std.testing.io, full, .{}) catch |err| {
            std.debug.print("cli purity: 재고에 있는 {s}가 없다 ({any})\n", .{ entry.path, err });
            return error.TestUnexpectedResult;
        };
    }
}

test "스캐너 자체: test 블록 안의 impure는 세지 않고 밖의 것만 센다" {
    const allocator = std.testing.allocator;

    // 제품 영역 1개 + test 블록 안 2개 → 1이어야 한다.
    const mixed =
        \\const std = @import("std");
        \\pub fn open() void {
        \\    _ = std.Io.Dir.cwd();
        \\}
        \\test "안쪽" {
        \\    _ = std.c.close(0);
        \\    _ = std.posix.STDOUT_FILENO;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 1), try countImpureOutsideTests(allocator, mixed));

    // 순수 파일은 0.
    const pure =
        \\const std = @import("std");
        \\pub fn parse(s: []const u8) usize {
        \\    return s.len;
        \\}
        \\test "쓰기는 순수 취급" {
        \\    var w: std.Io.Writer = undefined;
        \\    _ = w;
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 0), try countImpureOutsideTests(allocator, pure));

    // top-level fn 안의 impure는 test 블록이 아니므로 센다 — ssh.zig의 헬퍼가 재고에 오른 이유가 이것이다.
    const helper_outside =
        \\const std = @import("std");
        \\fn helper() void {
        \\    _ = std.c.fork();
        \\}
        \\test "블록" {
        \\    helper();
        \\}
    ;
    try std.testing.expectEqual(@as(usize, 1), try countImpureOutsideTests(allocator, helper_outside));
}
