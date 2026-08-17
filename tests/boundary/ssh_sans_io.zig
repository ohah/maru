// **SSH 프로토콜 층(`src/session/ssh/`)이 OS 를 안 부른다**는 계약을 강제한다(docs/ssh-client.md §2).
//
// **왜 이 성질인가.** 모바일 브리지는 계약상 OS 호출이 0 이다(모바일 §3). 그래서 SSH 는 소켓·파일·
// 시계를 모르는 sans-io 로 짜고 L4(host)가 그것을 든다 — 데스크톱과 모바일이 **같은 프로토콜 코드**를
// 쓰는 이유이자, 실서버 없이 바이트 열로 상태 전이를 못박을 수 있는 이유다. 깨지면 모바일 링크
// 오류로 늦게, 그것도 엉뚱한 얼굴로 드러난다.
//
// **왜 여기 있나 — 앞선 판정자가 무력했다.** 처음에는 `src/session/ssh/sans_io_boundary.zig` 가
// `@embedFile` 로 자기 파일 넷을 읽어 금지 문자열을 찾았다. 두 가지가 틀렸다.
//
//   1. **금지 목록이 Zig 0.16 에 없는 이름을 적고 있었다.** `std.net` 은 0.16 에 아예 없고, 이 트리가
//      실제로 쓰는 OS 진입점은 `std.Io.net`·`std.Io.Dir`·`std.Io.File`·`std.c` 다. 실측: 등록된
//      파일에 `std.Io.Dir.cwd().openFile(...)` 을 넣어도 게이트가 통과했다. 바로 옆 `cli_purity.zig`
//      가 이미 맞는 토큰 집합을 알고 있었는데 그것을 안 봤다.
//   2. **목록 방식 자체가 틀렸다.** 금지 목록은 "우리가 지금 아는 나쁜 이름" 만 막는다 — std 가
//      이름을 바꾸거나 새 진입점이 생기면 조용히 뚫린다. 그래서 여기서는 **허용 목록**이다:
//      `std.<X>` 의 `X` 가 아래 `pure_std` 에 없으면 위반이다. 새 이름은 기본이 "막힘" 이고,
//      여는 것은 이 파일을 고치는 **눈에 보이는 행위**가 된다.
//
// **셋째로 등록 강제도 가짜였다.** 그 파일은 `expectEqual(4, sources.len)` 로 "새 파일이 생기면
// 등록해야 한다" 를 강제한다고 적었는데, 그것은 리터럴 배열의 길이를 리터럴과 비교할 뿐 파일
// 시스템을 안 본다. 실측: 소켓 호출이 든 새 파일을 등록 없이 넣어도 통과했다. 여기서는 디렉터리를
// **직접 훑어** 목록 자체를 없앴다 — S3(kex)·S4(cipher) 가 곧 들어올 자리라 이 구멍이 특히 나빴다.
//
// **이 게이트가 막지 못하는 것 — 정직하게.**
//   - 허용된 네임스페이스 **안에서** 순수하지 않은 것을 부르는 것은 못 본다(예: `std.mem` 에는
//     그런 것이 없지만, 나중에 여는 이름에는 있을 수 있다). 여는 줄마다 이유를 적는 것이 방어다.
//   - 이 스캔은 `src/session/ssh/` 안만 본다. 그래서 **바깥 모듈 import 를 같이 막는다** — 안 막으면
//     `@import("../../platform/x.zig")` 한 줄로 계약을 통째로 우회할 수 있다. 다만 형제 파일이
//     늘어나는 것 자체는 막지 않는다(그 파일도 같이 스캔되므로).
//   - 무한 루프·전역 상태 같은 "순수성의 의미" 는 대상이 아니다.
const std = @import("std");
/// 스캐너가 보는 walker 경로를 POSIX 구분자로 정규화한다(정본: tests/support/posix_walk.zig).
const posixWalk = @import("posix_walk.zig").posixWalk;

const ssh_dir = "src/session/ssh";

/// SSH 층이 만져도 되는 `std` 네임스페이스. **전부 순수 계산이다** — 소켓·파일·시계·스레드·
/// 프로세스가 없고, 할당은 인자로 받는다(여기 있는 것 중 스스로 할당하는 것은 없다).
///
/// 늘릴 때는 **왜 순수한지**를 같이 적는다. 적을 말이 없으면 그것은 L4 로 가야 할 코드다.
const pure_std = [_]struct { name: []const u8, why: []const u8 }{
    .{ .name = "mem", .why = "바이트 비교·복사·정수 읽기/쓰기. OS 없음." },
    .{ .name = "math", .why = "정수 한계·포화 연산. OS 없음." },
    .{ .name = "fmt", .why = "버퍼에 포맷(`bufPrint`). 출력이 아니라 문자열 조립이다." },
    .{ .name = "crypto", .why = "X25519·Ed25519·ChaCha20-Poly1305·SHA-2. 순수 계산이고 계약 §3 이 이것을 쓴다고 정한다." },
    .{ .name = "Random", .why = "인터페이스 타입. 실제 엔트로피는 호출자가 주입한다(우리가 OS 에서 안 뽑는다)." },
    .{ .name = "testing", .why = "단언 헬퍼. 테스트 블록에서만 쓰이고 OS 를 안 부른다." },
    .{ .name = "base64", .why = "호출자 버퍼에 인코딩. 지문(`SHA256:<base64>`)이 이것으로 만들어지고, 할당도 OS 도 없다." },
    .{ .name = "ascii", .why = "대소문자 변환. known_hosts 호스트명 비교가 대소문자를 안 가려야 한다(OpenSSH 실측)." },
};

/// `@import("std")` 를 이 이름 말고 다른 것에 묶으면 스캔이 통째로 빗나간다(`const s = @import(\"std\");
/// s.Io.Dir...`). 그래서 **묶는 이름을 고정**하고, 다른 이름이면 그 자체를 위반으로 센다.
const std_binding = "std";

/// **둘 다 이 구조체가 소유한다.** 처음에는 `path` 를 훑는 쪽의 임시 버퍼로 빌려 뒀는데, 그
/// 버퍼가 루프 끝에서 해제되어 **위반을 찍는 순간 세그폴트**했다 — 즉 위반이 없을 때만 초록인
/// 판정자였다. 적대적 PoC 를 걸어 보지 않았으면 그대로 머지됐을 것이다.
const Violation = struct {
    path: []u8,
    what: []u8,

    fn deinit(self: Violation, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        allocator.free(self.what);
    }
};

fn addViolation(
    allocator: std.mem.Allocator,
    out: *std.ArrayList(Violation),
    path: []const u8,
    comptime fmt: []const u8,
    args: anytype,
) !void {
    const owned_path = try allocator.dupe(u8, path);
    errdefer allocator.free(owned_path);
    const what = try std.fmt.allocPrint(allocator, fmt, args);
    errdefer allocator.free(what);
    try out.append(allocator, .{ .path = owned_path, .what = what });
}

const Token = struct { tag: std.zig.Token.Tag, text: []const u8 };

fn tokenize(allocator: std.mem.Allocator, text: [:0]const u8) !std.ArrayList(Token) {
    var list: std.ArrayList(Token) = .empty;
    errdefer list.deinit(allocator);
    var tokenizer = std.zig.Tokenizer.init(text);
    while (true) {
        const token = tokenizer.next();
        if (token.tag == .eof) break;
        try list.append(allocator, .{ .tag = token.tag, .text = text[token.loc.start..token.loc.end] });
    }
    return list;
}

fn eq(tokens: []const Token, i: usize, want: []const u8) bool {
    return i < tokens.len and std.mem.eql(u8, tokens[i].text, want);
}

/// **토큰을 앞뒤로 볼 수 있어야 한다.** 처음에는 직전 두 개만 들고 훑었는데, 그러면 `std` 를
/// **거치지 않는** 두 우회가 그대로 통과한다(실측했다):
///
///   - `@import("std").Io.Dir.cwd()` — 묶지 않고 바로 체이닝. `std.` 라는 토큰 열이 없다.
///   - `const S = std; S.Io.Dir.cwd()` — 이미 묶인 `std` 를 다른 이름에 한 번 더 묶는다.
///
/// 그래서 규칙을 **두 방향으로 닫는다**: (1) `@import("std")` 는 `const std = @import("std");`
/// 형태로만 쓸 수 있고, (2) 식별자 `std` 는 **언제나 바로 뒤에 `.` 가 와야 한다**. 값으로 넘기든
/// 별칭에 묶든 그 순간 걸린다.
fn scan(
    allocator: std.mem.Allocator,
    text: [:0]const u8,
    path: []const u8,
    out: *std.ArrayList(Violation),
) !void {
    var tokens = try tokenize(allocator, text);
    defer tokens.deinit(allocator);
    const t = tokens.items;

    for (t, 0..) |token, i| {
        // `@cImport` 는 C 헤더를 끌어온다 — 이 층에 있으면 안 된다(platform 전용).
        if (token.tag == .builtin and std.mem.eql(u8, token.text, "@cImport")) {
            try addViolation(allocator, out, path, "@cImport", .{});
            continue;
        }

        if (token.tag == .builtin and std.mem.eql(u8, token.text, "@import") and
            eq(t, i + 1, "(") and i + 2 < t.len and t[i + 2].tag == .string_literal)
        {
            const quoted = t[i + 2].text;
            if (std.mem.eql(u8, quoted, "\"std\"")) {
                // (1) `@import("std")` 의 유일한 합법 형태.
                const bound_properly = i >= 2 and eq(t, i - 1, "=") and eq(t, i - 2, std_binding);
                if (!bound_properly) {
                    try addViolation(allocator, out, path, "@import(\"std\") 를 `const {s} = …;` 밖에서 쓴다", .{std_binding});
                }
            } else {
                // (3) **형제 파일만 import 한다.** 이 스캔은 `src/session/ssh/` 안만 보므로, 바깥
                // 모듈을 끌어오면 그 모듈이 무엇을 하든 검사 밖이다 — 즉 한 줄로 계약을 우회할 수
                // 있다. 경로 구분자(`/`)나 상위(`..`)가 있으면 바깥이다.
                const name = std.mem.trim(u8, quoted, "\"");
                if (std.mem.indexOfScalar(u8, name, '/') != null or std.mem.startsWith(u8, name, "..")) {
                    try addViolation(allocator, out, path, "형제 파일이 아닌 `{s}` 를 import 한다(검사 밖이 된다)", .{name});
                }
            }
            continue;
        }

        if (token.tag != .identifier or !std.mem.eql(u8, token.text, std_binding)) continue;
        // 다른 것의 멤버 이름이 `std` 인 경우(`foo.std`)는 우리 얘기가 아니다.
        if (i > 0 and eq(t, i - 1, ".")) continue;
        // 묶는 자리(`std = @import("std")`)는 통과시킨다 — 위 (1) 이 그 형태를 이미 잰다.
        if (eq(t, i + 1, "=")) continue;

        // (2) `std` 뒤에는 반드시 `.` 가 온다. 아니면 통째로 넘기거나 별칭에 묶은 것이다.
        if (!eq(t, i + 1, ".") or i + 2 >= t.len or t[i + 2].tag != .identifier) {
            try addViolation(allocator, out, path, "`{s}` 를 네임스페이스 접근 없이 쓴다(별칭·값 전달)", .{std_binding});
            continue;
        }

        const member = t[i + 2].text;
        var allowed = false;
        for (pure_std) |p| {
            if (std.mem.eql(u8, member, p.name)) allowed = true;
        }
        if (!allowed) try addViolation(allocator, out, path, "std.{s}", .{member});
    }
}

/// 토크나이저가 NUL 종단 소스를 요구한다(정본과 같은 방식: tests/boundary/imports.zig `readZigFileZ`).
fn readZ(allocator: std.mem.Allocator, path: []const u8) ![:0]u8 {
    const text = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, path, allocator, .limited(1 << 22));
    defer allocator.free(text);
    return allocator.dupeZ(u8, text);
}

test "SSH 프로토콜 층은 OS 를 안 부른다 (sans-io)" {
    const allocator = std.testing.allocator;
    var violations: std.ArrayList(Violation) = .empty;
    defer {
        for (violations.items) |v| v.deinit(allocator);
        violations.deinit(allocator);
    }

    var dir = try std.Io.Dir.cwd().openDir(std.testing.io, ssh_dir, .{ .iterate = true });
    defer dir.close(std.testing.io);
    var walker = try posixWalk(dir, allocator);
    defer walker.deinit();

    // **디렉터리를 직접 훑는다** — 등록 목록이 없으므로 새 파일이 자동으로 이 규칙을 받는다.
    var files: usize = 0;
    while (try walker.next(std.testing.io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".zig")) continue;
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ssh_dir, entry.path });
        defer allocator.free(path);
        const text = try readZ(allocator, path);
        defer allocator.free(text);
        try scan(allocator, text, path, &violations);
        files += 1;
    }

    for (violations.items) |v| {
        std.debug.print(
            "sans-io 위반: {s} — {s}. SSH 층은 바이트만 다룬다(계약 §2).\n",
            .{ v.path, v.what },
        );
    }
    if (violations.items.len != 0) {
        // **허용 목록과 그 이유를 같이 보여 준다.** 실패를 보는 사람이 다음에 할 일은 "이것도
        // 순수한가" 를 판단하는 것이고, 그 판단 기준이 여기 있다 — 이유를 적어만 두고 아무 데도
        // 안 쓰면 그것은 아무도 안 읽는 데이터가 된다.
        std.debug.print("\n소켓·파일·시계는 L4(host)가 든다. 지금 허용된 것은 이것뿐이다:\n", .{});
        for (pure_std) |p| std.debug.print("  std.{s} — {s}\n", .{ p.name, p.why });
        std.debug.print(
            "정말 필요하면 tests/boundary/ssh_sans_io.zig 의 `pure_std` 에 **왜 순수한지와 함께** 올린다.\n",
            .{},
        );
    }
    try std.testing.expectEqual(@as(usize, 0), violations.items.len);
    // 스캔이 0개 파일을 보고 "위반 0" 이라고 하는 거짓 초록을 막는다(경로 오타·파일 이동).
    // **살아 있는 가드다**: `ssh_dir` 을 zig 파일이 없는 실재 디렉터리로 돌리면 여기서 실패하고,
    // 이 줄을 지우면 같은 상황이 통째로 초록이 된다(둘 다 실측했다). 경로가 아예 없는 경우는
    // 위 `openDir` 이 잡지만, **있는데 비어 있는 경우**는 이 줄만 잡는다.
    try std.testing.expect(files >= 4);
}

// ── 판정자가 힘이 있는지 ────────────────────────────────────────────────────
//
// **판정자는 스스로를 증명해야 한다.** 앞선 판정자가 무력했던 것이 바로 이 검사가 없어서다 —
// 통과하는 것만 보고 "지켜진다" 고 읽었다. 아래는 잡아야 할 것과 잡으면 안 되는 것을 둘 다 건다.

fn countViolations(comptime src: [:0]const u8) !usize {
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Violation) = .empty;
    defer {
        for (out.items) |v| v.deinit(allocator);
        out.deinit(allocator);
    }
    try scan(allocator, src, "<inline>", &out);
    return out.items.len;
}

test "위반 기록은 경로를 빌려 쓰지 않는다" {
    // **이것이 없어서 판정자가 위반을 찍는 순간 죽었다.** 훑는 쪽은 경로를 `allocPrint` 로 만들고
    // 루프 끝에서 해제한다 — 기록이 그 포인터를 빌리면 보고할 때 이미 없는 메모리다. 즉
    // **위반이 0 일 때만 초록인 판정자**였고, 통과하는 것만 봤으면 그대로 머지됐을 것이다.
    const allocator = std.testing.allocator;
    var out: std.ArrayList(Violation) = .empty;
    defer {
        for (out.items) |v| v.deinit(allocator);
        out.deinit(allocator);
    }

    const borrowed = try allocator.dupe(u8, "src/session/ssh/scratch.zig");
    try scan(allocator, "_ = std.posix.write(fd, buf);", borrowed, &out);
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    // 같은 내용이되 **다른 메모리**여야 한다.
    try std.testing.expectEqualStrings(borrowed, out.items[0].path);
    try std.testing.expect(out.items[0].path.ptr != borrowed.ptr);
    allocator.free(borrowed); // 훑는 루프가 하는 일 — 이 뒤로도 기록은 읽을 수 있어야 한다.
    try std.testing.expectEqualStrings("src/session/ssh/scratch.zig", out.items[0].path);
    try std.testing.expectEqualStrings("std.posix", out.items[0].what);
}

test "판정자는 Zig 0.16 의 진짜 OS 진입점을 잡는다" {
    // 앞선 판정자는 이 넷을 **하나도** 못 잡았다(실측). 목록이 아니라 허용 방식이라 이름이
    // 바뀌어도 계속 잡힌다.
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\const f = try std.Io.Dir.cwd().openFile("/etc/hosts", .{});
    ));
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\const s = try std.Io.net.Stream.connect(io, addr);
    ));
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\const fd = std.c.socket(2, 1, 0);
    ));
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\_ = std.posix.write(fd, buf);
    ));
    // 예전 목록에 있던 이름들도 물론 잡는다.
    try std.testing.expectEqual(@as(usize, 4), try countViolations(
        \\_ = std.fs; _ = std.time; _ = std.Thread; _ = std.process;
    ));
    // C 헤더 끌어오기.
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\const c = @cImport(@cInclude("sys/socket.h"));
    ));
}

test "판정자는 std 를 거치지 않는 우회 셋을 잡는다" {
    // 아래 셋은 전부 `std.<금지이름>` 이라는 **토큰 열이 없어서** 앞선 판정자를 그냥 빠져나갔다
    // (셋 다 실측으로 통과하는 것을 봤다 — 바로 옆 cli_purity.zig 도 이 구멍을 한계로 적어 뒀다).

    // (a) 다른 이름에 묶기.
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\const s = @import("std");
    ));
    // (b) 묶지 않고 바로 체이닝 — `std.` 가 아예 안 나온다.
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\const f = try @import("std").Io.Dir.cwd().openFile("/etc/hosts", .{});
    ));
    // (c) 이미 묶인 std 를 한 번 더 별칭에 묶기.
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\const S = std;
    ));
    // (d) std 를 값으로 넘기기(받는 쪽에서 무엇이든 할 수 있다).
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\pub fn f() void { helper(std); }
    ));

    // 합법 형태는 통과한다.
    try std.testing.expectEqual(@as(usize, 0), try countViolations(
        \\const std = @import("std");
    ));
    // 형제 파일을 다른 이름에 묶는 것은 정상이다.
    try std.testing.expectEqual(@as(usize, 0), try countViolations(
        \\const wire = @import("wire.zig");
    ));
    // **바깥 모듈은 막는다** — 안 막으면 한 줄로 이 스캔 밖으로 나갈 수 있다.
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\const host = @import("../../platform/macos/sock.zig");
    ));
    try std.testing.expectEqual(@as(usize, 1), try countViolations(
        \\const cfg = @import("../config.zig");
    ));
    // 멤버 이름이 우연히 `std` 인 것은 우리 얘기가 아니다.
    try std.testing.expectEqual(@as(usize, 0), try countViolations(
        \\const x = opts.std;
    ));
}

test "판정자는 순수한 것과 주석·문자열을 오탐하지 않는다" {
    try std.testing.expectEqual(@as(usize, 0), try countViolations(
        \\const n = std.mem.readInt(u32, buf[0..4], .big);
        \\var prng = std.Random.DefaultPrng.init(1);
        \\const k = std.crypto.dh.X25519.scalarmult(a, b);
        \\const s = try std.fmt.bufPrint(&out, "{s}", .{name});
        \\try std.testing.expectEqual(@as(usize, 1), n);
        \\const m = std.math.maxInt(usize);
    ));
    // 주석·doc 주석·문자열 안의 언급은 위반이 아니다 — 계약을 설명하는 자리가 그런 곳이다.
    try std.testing.expectEqual(@as(usize, 0), try countViolations(
        \\// 데스크톱은 std.posix 로, 모바일은 host 소켓으로 붙는다(둘 다 L4).
        \\/// std.Io.Dir 는 여기 없다.
        \\const msg = "std.net 은 L4 의 것이다";
    ));
    // 이름이 비슷한 우리 식별자는 안 걸린다.
    try std.testing.expectEqual(@as(usize, 0), try countViolations(
        \\const stdish = 1; const x = peer.fs; const y = self.time;
    ));
}
