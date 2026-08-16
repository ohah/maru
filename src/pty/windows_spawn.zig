//! Windows 백엔드의 **순수 조립부** — `CreateProcessW`에 넘길 커맨드라인과 환경 블록의 내용을 만든다.
//!
//! **왜 `windows.zig`와 갈랐나.** 이 파일에는 Win32 심볼이 없다. 그래서 macOS·Linux에서도 컴파일되고
//! `zig build test`가 **모든 타깃에서** 여기 테스트를 돈다. 규칙을 백엔드 파일 안에 두면 Windows에서만
//! 컴파일되어 — Windows CI가 없는 이 저장소에서는 — 아무도 안 도는 코드가 된다. W1.5·W2에서 두 번 밟은
//! 함정(`os_tag`를 comptime 분기로 두어 Windows 갈래가 공허참이 된 것)의 같은 대처다.
//!
//! 계약: [docs/windows-platform.md](../../docs/windows-platform.md) §4.2.

const std = @import("std");

/// 커맨드라인 토큰 하나를 Windows 규칙으로 인용해 `buf`에 붙인다.
///
/// **어떤 규칙인가.** `CreateProcessW`는 커맨드라인을 **하나의 문자열**로 받고, 그것을 argv로 되돌리는 것은
/// 자식의 몫이다. C/C++ 런타임(그리고 그것을 따르는 대부분의 프로그램)이 쓰는 규칙은 공개 문서
/// "Parsing C++ Command-Line Arguments"에 있고, 요지는 백슬래시가 **따옴표 앞에서만** 이스케이프 문자가
/// 된다는 것이다:
///
/// - `2n`개의 백슬래시 + `"` → `n`개의 백슬래시와 **인용 구간 토글**
/// - `2n+1`개의 백슬래시 + `"` → `n`개의 백슬래시와 **리터럴 `"`**
/// - 따옴표가 뒤따르지 않는 백슬래시는 그냥 백슬래시다
///
/// 그래서 역방향으로 조립할 때 백슬래시를 두 배로 늘리는 자리는 **따옴표 바로 앞과 토큰 끝**(닫는 따옴표가
/// 붙으므로)뿐이다. 경로 한가운데의 `C:\Program Files\`는 건드리지 않는다 — 무조건 두 배로 늘리면
/// `C:\\Program Files\\`가 되어 자식이 다른 경로를 본다.
///
/// **인용이 필요 없으면 안 한다.** 공백·탭·따옴표가 없는 토큰은 그대로 붙인다. 빈 토큰만은 `""`가 필요하다
/// (아니면 토큰 자체가 사라진다).
///
/// **cmd.exe는 이 규칙을 쓰지 않는다**(계약 §4.2). cmd는 자기 파서로 `^`·`&`·`|`를 먼저 해석한다. 이 함수는
/// **실행 파일을 직접 띄우는** 자리(= `CreateProcessW`의 lpCommandLine)를 위한 것이고, `cmd /c <문자열>`을
/// 조립하는 자리는 여기 소비자가 아니다 — maru는 셸을 **직접** 띄우지 셸을 통해 명령을 띄우지 않는다.
pub fn appendQuotedArg(allocator: std.mem.Allocator, buf: *std.ArrayList(u8), arg: []const u8) !void {
    if (arg.len != 0 and std.mem.indexOfAny(u8, arg, " \t\n\u{0B}\"") == null) {
        try buf.appendSlice(allocator, arg);
        return;
    }

    try buf.append(allocator, '"');
    var i: usize = 0;
    while (i < arg.len) {
        var backslashes: usize = 0;
        while (i < arg.len and arg[i] == '\\') : (i += 1) backslashes += 1;

        if (i == arg.len) {
            // 토큰 끝 — 곧 닫는 따옴표가 붙으므로 두 배로 늘려 그 따옴표가 이스케이프되지 않게 한다.
            try buf.appendNTimes(allocator, '\\', backslashes * 2);
            break;
        }
        if (arg[i] == '"') {
            // 리터럴 따옴표 — 앞선 백슬래시를 두 배로 늘리고 따옴표 자신도 하나 더 붙여 이스케이프한다.
            try buf.appendNTimes(allocator, '\\', backslashes * 2 + 1);
            try buf.append(allocator, '"');
            i += 1;
            continue;
        }
        // 평범한 문자 앞의 백슬래시는 이스케이프가 아니다 — 그대로 둔다.
        try buf.appendNTimes(allocator, '\\', backslashes);
        try buf.append(allocator, arg[i]);
        i += 1;
    }
    try buf.append(allocator, '"');
}

/// `command` + `args`를 `CreateProcessW`의 `lpCommandLine` 문자열로 조립한다(0 종단).
///
/// **`command`가 argv\[0\]로도 들어간다.** 우리는 `lpApplicationName`에 실행 파일 경로를 따로 주므로
/// 커맨드라인의 첫 토큰이 실행 파일을 **찾는** 데 쓰이지는 않지만, 자식이 자기 이름으로 읽는 값이라 비워
/// 두면 안 된다(argv\[0\]이 첫 인자로 밀린다).
///
/// **NUL을 거른다.** UTF-16 변환 뒤에는 NUL이 문자열 끝이라, 토큰 안에 NUL이 있으면 커맨드라인이 조용히
/// 잘린다 — 조용한 절단 대신 여기서 실패한다.
pub fn buildCommandLine(
    allocator: std.mem.Allocator,
    command: []const u8,
    args: []const []const u8,
) ![:0]u8 {
    if (std.mem.indexOfScalar(u8, command, 0) != null) return error.InvalidCommand;
    for (args) |a| if (std.mem.indexOfScalar(u8, a, 0) != null) return error.InvalidCommand;

    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(allocator);
    try appendQuotedArg(allocator, &buf, command);
    for (args) |a| {
        try buf.append(allocator, ' ');
        try appendQuotedArg(allocator, &buf, a);
    }
    return try buf.toOwnedSliceSentinel(allocator, 0);
}

/// 환경 항목의 **키**를 낸다. 키가 없으면 null.
///
/// Windows 환경에는 `=C:=C:\work` 같은 항목이 있다 — 드라이브별 현재 디렉터리를 나르는 것으로, 이름이
/// `=`로 시작한다. 그런 항목을 평범하게 파싱하면 키가 빈 문자열이 되어 **모든 특수 항목이 서로 같은 키로
/// 보인다**. 그래서 `=`로 시작하는 항목은 키가 없는 것으로 보고 매칭 대상에서 뺀다(그대로 상속된다).
pub fn envKey(entry: []const u8) ?[]const u8 {
    if (entry.len == 0 or entry[0] == '=') return null;
    const eq = std.mem.indexOfScalarPos(u8, entry, 1, '=') orelse return null;
    return entry[0..eq];
}

/// 이 항목의 키가 `key`인가. **대소문자를 구분하지 않는다** — Windows 환경변수 이름은 대소문자를 가리지
/// 않아(`Path`와 `PATH`가 같은 변수) 구분해서 비교하면 같은 변수가 블록에 두 번 들어간다. 그러면 어느 쪽이
/// 이기는지는 읽는 쪽 구현에 달리므로, 여기서 하나로 합친다.
pub fn envKeyIs(entry: []const u8, key: []const u8) bool {
    const k = envKey(entry) orelse return false;
    return std.ascii.eqlIgnoreCase(k, key);
}

/// 환경 블록에 실을 수 있는 모양인가 — `=`가 하나라도 있어야 한다.
///
/// 실제 프로세스 환경에는 이런 항목이 없지만 `parent_env`·`env`는 호출자가 넘기는 슬라이스이기도 하다.
/// `=` 없는 문자열을 그대로 실으면 `CreateProcessW`가 받는 블록이 형식을 잃는다 — 자식의 환경이 그
/// 지점부터 어떻게 파싱될지는 문서화돼 있지 않다. 조용히 떨구는 편이 안전하다(적대적 검증 fuzz가 찾았다).
///
/// `=C:=C:\work`처럼 **이름이 `=`로 시작하는** Windows 고유 항목은 통과한다 — 그것도 `=`를 갖고 있고,
/// 드라이브별 현재 디렉터리를 나르는 정상 항목이다.
fn isWellFormedEntry(entry: []const u8) bool {
    return std.mem.indexOfScalar(u8, entry, '=') != null;
}

/// 부모 환경에서 **자식에게 물려주면 거짓이 되는** 항목인가.
///
/// macOS 백엔드(`EnvStorage.appendParentEnv`)와 **같은 정책**이다. 두 백엔드가 각자 구현하는 이유는 주입
/// 메커니즘이 다르기 때문이지(zsh `ZDOTDIR` vs 프로필 스크립트) 정책이 달라서가 아니다 — 목록이 갈리면
/// 같은 오염이 한쪽에서만 막힌다. 바꿀 때 반드시 양쪽을 함께 본다.
fn isDroppedParentEntry(entry: []const u8) bool {
    const drop = [_][]const u8{
        // 아래에서 우리 값으로 다시 넣는다(중복 키를 남기지 않기 위해 부모 것을 먼저 뺀다).
        "TERM",     "COLORTERM",      "TERM_PROGRAM", "TERM_PROGRAM_VERSION",
        // 부모(런처·상위 터미널)의 terminfo DB를 가리키면 우리 TERM을 엉뚱한 곳에서 찾는다.
        "TERMINFO",
        // 런처·CI가 남긴 색 강제 override. maru는 색 capability를 TERM/COLORTERM으로만 알린다.
        "CLICOLOR_FORCE", "FORCE_COLOR",
        // 컨트롤 플레인 self selector — 부모 값을 물려받으면 다른 surface를 자기로 오인한다.
         "MARU_PANE_ID",
        // 바깥 멀티플렉서의 신원. maru가 spawn하는 셸은 그 pane이 **아니다**.
        "TMUX",     "TMUX_PANE",
    };
    for (drop) |key| if (envKeyIs(entry, key)) return true;
    return false;
}

/// 환경 블록의 재료. 순수하게 만들기 위해 **부모 환경도 인자로** 받는다 — 실제 프로세스 환경을 읽는 것은
/// 백엔드의 일이고, 그래야 이 조립 규칙이 모든 타깃에서 테스트된다.
pub const EnvOptions = struct {
    /// 비어 있지 않으면 부모 상속을 **끊고** 이 목록만 쓴다(테스트 경로). 계약의 `SpawnRequest.env`.
    env: []const []const u8 = &.{},
    /// 부모 환경 스냅샷("KEY=VALUE" 목록).
    parent_env: []const []const u8 = &.{},
    /// 사용자 config `env.<KEY>` — 위 결과 **위에** upsert한다.
    env_overrides: []const []const u8 = &.{},
    term: []const u8 = "xterm-256color",
    pane_id: ?u64 = null,
    /// opt-in ssh 라우팅이 켜졌을 때의 maru 실행 파일 경로. macOS와 **같은 정책**을 쓴다(`MARU_BIN` +
    /// `MARU_SSH_INTEGRATION=1` 주입, 부모의 동명 키는 그때 떨군다). Windows에서 이 값을 읽을 통합
    /// 스크립트는 W5, `maru ssh` 자체는 W9라 지금은 무동작이지만, 정책을 한쪽에만 두면 그 슬라이스가
    /// 올 때 조용히 갈린다 — `isDroppedParentEntry`의 doc이 경고하는 바로 그 자리다.
    ssh_integration_bin: ?[]const u8 = null,
};

/// 환경 블록에 들어갈 "KEY=VALUE" 목록을 만든다. 각 원소와 바깥 슬라이스 모두 호출자 소유다
/// (`freeEnvEntries`로 푼다).
///
/// **`TERMINFO`는 넣지 않는다.** macOS 백엔드는 `xterm-maru`를 캐시에 컴파일하고 그 경로를 심지만,
/// 네이티브 Windows 셸(cmd·PowerShell)은 terminfo를 읽지 않는다(계약 §4.2 — `term`은 WSL·msys로 들어가는
/// 프로그램에만 뜻이 있다). 없는 DB를 가리키느니 안 주는 편이 낫다.
///
/// **`shell_integration_dir`도 여기서 다루지 않는다.** Windows의 주입 메커니즘(PowerShell 프로필 스크립트·
/// cmd `PROMPT`)은 환경변수 하나로 끝나지 않아 별도 슬라이스(W5)가 소유한다.
pub fn buildEnvEntries(allocator: std.mem.Allocator, opts: EnvOptions) ![][]u8 {
    var entries: std.ArrayList([]u8) = .empty;
    errdefer {
        for (entries.items) |owned| allocator.free(owned);
        entries.deinit(allocator);
    }

    if (opts.env.len != 0) {
        // 명시 env: 부모 상속도 maru override도 없이 그대로 쓰되, 내부 selector는 예약 키라 뺀다
        // (아래 tail에서 현재 값만 다시 들어간다).
        for (opts.env) |entry| {
            if (!isWellFormedEntry(entry)) continue;
            if (envKeyIs(entry, "MARU_PANE_ID")) continue;
            if (findEntryIndex(entries.items, entry) != null) continue; // 첫 것이 이긴다(부모 갈래와 같은 규칙)
            try appendOwned(allocator, &entries, try allocator.dupe(u8, entry));
        }
    } else {
        for (opts.parent_env) |entry| {
            if (!isWellFormedEntry(entry)) continue;
            if (isDroppedParentEntry(entry)) continue;
            // 주입할 때만 부모의 동명 키를 떨군다(macOS와 같은 조건). 안 켰으면 부모 값이 그대로 간다 —
            // 그쪽도 같으므로 두 백엔드가 어긋나지 않는다.
            if (opts.ssh_integration_bin != null and
                (envKeyIs(entry, "MARU_BIN") or envKeyIs(entry, "MARU_SSH_INTEGRATION"))) continue;
            // **부모가 같은 키를 두 번 담고 있으면 첫 것만 쓴다.** 실제 프로세스 환경에는 그런 일이 없지만
            // (OS가 사전으로 관리한다) `parent_env`는 호출자가 넘기는 스냅샷이기도 하다. 여기서 걸러야
            // "이 함수가 낸 블록에는 같은 키가 두 번 없다"가 **입력과 무관하게** 성립한다 — Windows는
            // 중복 키가 있을 때 어느 쪽이 이기는지를 문서화하지 않는다. 첫 것이 이기는 규칙은 POSIX
            // 관례이자 macOS 백엔드가 전제하는 것과 같다(적대적 검증 fuzz가 찾았다).
            if (findEntryIndex(entries.items, entry) != null) continue;
            try appendOwned(allocator, &entries, try allocator.dupe(u8, entry));
        }
        try appendOwned(allocator, &entries, try std.fmt.allocPrint(allocator, "TERM={s}", .{opts.term}));
        try appendOwned(allocator, &entries, try allocator.dupe(u8, "COLORTERM=truecolor"));
        // macOS 백엔드와 같은 값이다 — TUI들이 데스크톱 알림을 보낼 터미널을 TERM_PROGRAM 화이트리스트로
        // 고르는데 maru는 그 명단에 없어서다. 근거는 `EnvStorage.appendParentEnv`의 주석이 단일 출처다.
        try appendOwned(allocator, &entries, try allocator.dupe(u8, "TERM_PROGRAM=ghostty"));
        if (opts.ssh_integration_bin) |bin| {
            try appendOwned(allocator, &entries, try std.fmt.allocPrint(allocator, "MARU_BIN={s}", .{bin}));
            try appendOwned(allocator, &entries, try allocator.dupe(u8, "MARU_SSH_INTEGRATION=1"));
        }
    }

    for (opts.env_overrides) |ov| {
        if (envKeyIs(ov, "MARU_PANE_ID")) continue; // 내부 예약 키는 사용자가 덮어쓸 수 없다
        try upsert(allocator, &entries, ov);
    }
    if (opts.pane_id) |id| {
        const value = try std.fmt.allocPrint(allocator, "MARU_PANE_ID={d}", .{id});
        defer allocator.free(value);
        try upsert(allocator, &entries, value);
    }

    return try entries.toOwnedSlice(allocator);
}

pub fn freeEnvEntries(allocator: std.mem.Allocator, entries: [][]u8) void {
    for (entries) |owned| allocator.free(owned);
    allocator.free(entries);
}

/// append 실패(OOM)면 방금 만든 문자열을 푼다 — errdefer가 `entries.items`만 보므로 인자 안에서 만든
/// 할당은 새 버린다. macOS 백엔드의 `appendOwnedEnv`와 같은 관용구다.
fn appendOwned(allocator: std.mem.Allocator, entries: *std.ArrayList([]u8), owned: []u8) !void {
    entries.append(allocator, owned) catch |err| {
        allocator.free(owned);
        return err;
    };
}

/// 같은 키가 있으면 **그 자리에서** 교체하고 없으면 끝에 붙인다. 자리를 지키는 이유는 순서가 뜻을 갖는
/// 항목(`PATH`)의 위치를 흔들지 않기 위해서다. 키가 없는 항목(`=C:=…`, `=` 없는 쓰레기)은 무시한다.
/// `candidate`와 **같은 키**를 가진 항목의 자리. 키가 없는 항목(`=C:=…`)은 늘 null이라 그런 특수 항목은
/// 서로 겹치지 않고 그대로 통과한다.
fn findEntryIndex(entries: []const []u8, candidate: []const u8) ?usize {
    const key = envKey(candidate) orelse return null;
    for (entries, 0..) |entry, i| {
        if (envKeyIs(entry, key)) return i;
    }
    return null;
}

fn upsert(allocator: std.mem.Allocator, entries: *std.ArrayList([]u8), override: []const u8) !void {
    const key = envKey(override) orelse return;
    const owned = try allocator.dupe(u8, override);
    for (entries.items, 0..) |entry, i| {
        if (envKeyIs(entry, key)) {
            allocator.free(entry);
            entries.items[i] = owned;
            return;
        }
    }
    entries.append(allocator, owned) catch |err| {
        allocator.free(owned);
        return err;
    };
}

// ── 테스트 ────────────────────────────────────────────────────────────────────────────────────
// 전부 순수라 **모든 타깃에서** 돈다(이 파일에 Win32 심볼이 없는 이유).

test "appendQuotedArg: 인용이 필요 없으면 하지 않는다" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "cmd.exe", "C:\\Windows\\System32\\cmd.exe", "-NoLogo", "a\\b\\c" }) |arg| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try appendQuotedArg(a, &buf, arg);
        try std.testing.expectEqualStrings(arg, buf.items);
    }
}

test "appendQuotedArg: 공백·따옴표·빈 토큰만 인용한다" {
    const a = std.testing.allocator;
    const cases = [_]struct { in: []const u8, out: []const u8 }{
        .{ .in = "", .out = "\"\"" }, // 빈 토큰 — 인용 안 하면 토큰 자체가 사라진다
        .{ .in = "C:\\Program Files\\PowerShell\\7\\pwsh.exe", .out = "\"C:\\Program Files\\PowerShell\\7\\pwsh.exe\"" },
        .{ .in = "a b", .out = "\"a b\"" },
        .{ .in = "a\tb", .out = "\"a\tb\"" },
        .{ .in = "say \"hi\"", .out = "\"say \\\"hi\\\"\"" },
        // 토큰 끝의 백슬래시만 두 배가 된다 — 닫는 따옴표를 이스케이프하지 않게.
        .{ .in = "a b\\", .out = "\"a b\\\\\"" },
        .{ .in = "a b\\\\", .out = "\"a b\\\\\\\\\"" },
        // 따옴표 **앞의** 백슬래시도 두 배 + 1. 한가운데(`x\y`)는 그대로다.
        .{ .in = "x\\y \\\"z", .out = "\"x\\y \\\\\\\"z\"" },
    };
    for (cases) |c| {
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(a);
        try appendQuotedArg(a, &buf, c.in);
        try std.testing.expectEqualStrings(c.out, buf.items);
    }
}

/// 조립한 커맨드라인을 **CRT 규칙으로 다시 파싱**해 원래 토큰이 나오는지 본다. 손으로 고른 기대문자열은
/// 내가 규칙을 잘못 이해했으면 기대값도 같이 틀리지만, 왕복은 그 실수를 잡는다.
fn parseCommandLine(allocator: std.mem.Allocator, line: []const u8, out: *std.ArrayList([]u8)) !void {
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
        if (i >= line.len) break;
        var token: std.ArrayList(u8) = .empty;
        errdefer token.deinit(allocator);
        var in_quotes = false;
        while (i < line.len) {
            if (line[i] == '\\') {
                var n: usize = 0;
                while (i < line.len and line[i] == '\\') : (i += 1) n += 1;
                if (i < line.len and line[i] == '"') {
                    try token.appendNTimes(allocator, '\\', n / 2);
                    if (n % 2 == 1) {
                        try token.append(allocator, '"');
                        i += 1;
                    } else {
                        in_quotes = !in_quotes;
                        i += 1;
                    }
                } else {
                    try token.appendNTimes(allocator, '\\', n);
                }
                continue;
            }
            if (line[i] == '"') {
                in_quotes = !in_quotes;
                i += 1;
                continue;
            }
            if (!in_quotes and (line[i] == ' ' or line[i] == '\t')) break;
            try token.append(allocator, line[i]);
            i += 1;
        }
        try out.append(allocator, try token.toOwnedSlice(allocator));
    }
}

test "buildCommandLine: 조립한 뒤 다시 파싱하면 원래 토큰이 나온다" {
    const a = std.testing.allocator;
    const cases = [_][]const []const u8{
        &.{"C:\\Windows\\System32\\cmd.exe"},
        &.{ "C:\\Program Files\\PowerShell\\7\\pwsh.exe", "-NoLogo", "-NoProfile" },
        &.{ "sh", "-c", "echo \"hi there\"" },
        &.{ "x", "", "a\\", "a\\\\b", "\"", "\\\"", "a b\\", " leading", "trailing " },
        &.{ "C:\\경로\\셸.exe", "인자 하나" },
    };
    for (cases) |tokens| {
        const line = try buildCommandLine(a, tokens[0], tokens[1..]);
        defer a.free(line);

        var parsed: std.ArrayList([]u8) = .empty;
        defer {
            for (parsed.items) |t| a.free(t);
            parsed.deinit(a);
        }
        try parseCommandLine(a, line, &parsed);
        try std.testing.expectEqual(tokens.len, parsed.items.len);
        for (tokens, parsed.items) |want, got| try std.testing.expectEqualStrings(want, got);
    }
}

test "buildCommandLine: 토큰 안의 NUL은 조용히 자르지 않고 실패한다" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.InvalidCommand, buildCommandLine(a, "a\x00b", &.{}));
    try std.testing.expectError(error.InvalidCommand, buildCommandLine(a, "ok", &.{"a\x00b"}));
}

test "envKey: '='로 시작하는 Windows 드라이브 항목은 키가 없다" {
    try std.testing.expectEqualStrings("PATH", envKey("PATH=C:\\x").?);
    try std.testing.expectEqualStrings("A", envKey("A=").?);
    try std.testing.expect(envKey("=C:=C:\\work") == null); // 있으면 '='가 모든 특수 항목과 겹친다
    try std.testing.expect(envKey("=") == null);
    try std.testing.expect(envKey("noequals") == null);
    try std.testing.expect(envKey("") == null);
}

test "buildEnvEntries: 부모를 물려받되 오염 항목은 떨구고 우리 값을 넣는다" {
    const a = std.testing.allocator;
    const parent = [_][]const u8{
        "PATH=C:\\Windows",     "TERM=dumb",          "COLORTERM=8bit",  "TERMINFO=C:\\other",
        "TERM_PROGRAM=WezTerm", "FORCE_COLOR=1",      "MARU_PANE_ID=99", "TMUX=/tmp/x,1,0",
        "TMUX_PANE=%3",         "HOME=C:\\Users\\me",
        "=C:=C:\\work", // 드라이브별 cwd — 그대로 상속돼야 한다
    };
    const entries = try buildEnvEntries(a, .{ .parent_env = &parent, .term = "xterm-256color" });
    defer freeEnvEntries(a, entries);

    try expectEnv(entries, "PATH", "C:\\Windows");
    try expectEnv(entries, "HOME", "C:\\Users\\me");
    try expectEnv(entries, "TERM", "xterm-256color");
    try expectEnv(entries, "COLORTERM", "truecolor");
    try expectEnv(entries, "TERM_PROGRAM", "ghostty");
    for ([_][]const u8{ "TERMINFO", "FORCE_COLOR", "MARU_PANE_ID", "TMUX", "TMUX_PANE" }) |key|
        try std.testing.expect(findEnv(entries, key) == null);
    try std.testing.expect(hasExact(entries, "=C:=C:\\work"));
}

// macOS 백엔드(`EnvStorage`)와 **같은 정책**임을 못박는다. 한쪽에만 두면 그 기능이 오는 슬라이스에서
// 조용히 갈린다 — 켜면 주입하고 부모의 stale 값을 떨구고, 안 켜면 둘 다 안 한다.
// 적대적 검증 fuzz가 찾았다. 실제 프로세스 환경에는 대소문자만 다른 중복 키가 없지만 `parent_env`는
// 호출자가 넘기는 스냅샷이기도 하고, Windows는 중복 키의 승자를 문서화하지 않는다 — **입력과 무관하게**
// 같은 키가 한 번만 나가야 한다.
test "buildEnvEntries: 부모에 중복 키가 있어도 하나만 나간다(첫 것이 이긴다)" {
    const a = std.testing.allocator;
    const parent = [_][]const u8{ "A=1", "a=2", "PATH=p", "Path=q", "=C:=C:\\w", "=D:=D:\\x" };
    const entries = try buildEnvEntries(a, .{ .parent_env = &parent });
    defer freeEnvEntries(a, entries);

    try std.testing.expectEqual(@as(usize, 1), countEnv(entries, "A"));
    try expectEnv(entries, "A", "1"); // 첫 것이 이긴다(POSIX 관례·macOS 전제와 같다)
    try std.testing.expectEqual(@as(usize, 1), countEnv(entries, "PATH"));
    try expectEnv(entries, "PATH", "p");
    // 키가 없는 특수 항목(`=C:=…`)은 서로 겹치지 않으므로 **둘 다** 남아야 한다.
    try std.testing.expect(hasExact(entries, "=C:=C:\\w"));
    try std.testing.expect(hasExact(entries, "=D:=D:\\x"));
}

test "buildEnvEntries: ssh 라우팅은 켰을 때만 주입하고 그때만 부모 값을 떨군다" {
    const a = std.testing.allocator;
    const parent = [_][]const u8{ "PATH=C:\\Windows", "MARU_BIN=C:\\old\\maru.exe", "MARU_SSH_INTEGRATION=1" };

    {
        const entries = try buildEnvEntries(a, .{ .parent_env = &parent, .ssh_integration_bin = "C:\\new\\maru.exe" });
        defer freeEnvEntries(a, entries);
        try expectEnv(entries, "MARU_BIN", "C:\\new\\maru.exe"); // 낡은 경로가 이기면 옛 바이너리로 라우팅된다
        try expectEnv(entries, "MARU_SSH_INTEGRATION", "1");
        try std.testing.expectEqual(@as(usize, 1), countEnv(entries, "MARU_BIN"));
    }
    // 안 켰으면 주입하지 않는다. 부모 값은 그대로 간다 — macOS도 같아서 두 백엔드가 어긋나지 않는다.
    {
        const entries = try buildEnvEntries(a, .{ .parent_env = &parent });
        defer freeEnvEntries(a, entries);
        try expectEnv(entries, "MARU_BIN", "C:\\old\\maru.exe");
        try std.testing.expectEqual(@as(usize, 1), countEnv(entries, "MARU_BIN"));
    }
}

test "buildEnvEntries: 사용자 override는 대소문자를 넘어 upsert하고 중복 키를 남기지 않는다" {
    const a = std.testing.allocator;
    const parent = [_][]const u8{ "Path=C:\\Windows", "KEEP=1" };
    const overrides = [_][]const u8{ "PATH=C:\\mine", "NEW=2" };
    const entries = try buildEnvEntries(a, .{ .parent_env = &parent, .env_overrides = &overrides });
    defer freeEnvEntries(a, entries);

    // 대소문자만 다른 키가 두 번 들어가면 어느 쪽이 이기는지가 읽는 쪽 구현에 달린다 — 하나여야 한다.
    try std.testing.expectEqual(@as(usize, 1), countEnv(entries, "PATH"));
    try expectEnv(entries, "PATH", "C:\\mine");
    try expectEnv(entries, "KEEP", "1");
    try expectEnv(entries, "NEW", "2");
}

test "buildEnvEntries: MARU_PANE_ID는 사용자가 덮어쓸 수 없는 내부 selector다" {
    const a = std.testing.allocator;
    const parent = [_][]const u8{"MARU_PANE_ID=1"};
    const overrides = [_][]const u8{"MARU_PANE_ID=2"};

    {
        const entries = try buildEnvEntries(a, .{ .parent_env = &parent, .env_overrides = &overrides, .pane_id = 7 });
        defer freeEnvEntries(a, entries);
        try std.testing.expectEqual(@as(usize, 1), countEnv(entries, "MARU_PANE_ID"));
        try expectEnv(entries, "MARU_PANE_ID", "7");
    }
    // pane_id가 없으면 selector 자체가 없어야 한다(persistent child 등) — 부모 값이 새면 안 된다.
    {
        const entries = try buildEnvEntries(a, .{ .parent_env = &parent, .env_overrides = &overrides });
        defer freeEnvEntries(a, entries);
        try std.testing.expect(findEnv(entries, "MARU_PANE_ID") == null);
    }
}

test "buildEnvEntries: 명시 env는 부모 상속과 maru override를 끊는다" {
    const a = std.testing.allocator;
    const parent = [_][]const u8{"PATH=C:\\Windows"};
    const env = [_][]const u8{ "ONLY=1", "MARU_PANE_ID=99" };
    const entries = try buildEnvEntries(a, .{ .env = &env, .parent_env = &parent, .pane_id = 3 });
    defer freeEnvEntries(a, entries);

    try std.testing.expectEqual(@as(usize, 2), entries.len); // ONLY + MARU_PANE_ID(우리 값)
    try expectEnv(entries, "ONLY", "1");
    try expectEnv(entries, "MARU_PANE_ID", "3");
    try std.testing.expect(findEnv(entries, "PATH") == null);
    try std.testing.expect(findEnv(entries, "TERM") == null);
}

test "buildEnvEntries: 할당 실패에서 새지 않는다" {
    const parent = [_][]const u8{ "PATH=C:\\Windows", "A=1", "B=2" };
    const overrides = [_][]const u8{ "A=x", "C=3" };
    var idx: usize = 0;
    while (idx < 24) : (idx += 1) {
        var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = idx });
        const a = failing.allocator();
        if (buildEnvEntries(a, .{ .parent_env = &parent, .env_overrides = &overrides, .pane_id = 1 })) |entries| {
            freeEnvEntries(a, entries);
        } else |err| try std.testing.expectEqual(error.OutOfMemory, err);
        try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes);
    }
}

fn findEnv(entries: []const []u8, key: []const u8) ?[]const u8 {
    for (entries) |entry| if (envKeyIs(entry, key)) return entry[key.len + 1 ..];
    return null;
}

fn countEnv(entries: []const []u8, key: []const u8) usize {
    var n: usize = 0;
    for (entries) |entry| if (envKeyIs(entry, key)) {
        n += 1;
    };
    return n;
}

fn hasExact(entries: []const []u8, want: []const u8) bool {
    for (entries) |entry| if (std.mem.eql(u8, entry, want)) return true;
    return false;
}

fn expectEnv(entries: []const []u8, key: []const u8, want: []const u8) !void {
    const got = findEnv(entries, key) orelse {
        std.debug.print("환경에 {s}가 없다\n", .{key});
        return error.TestExpectedEqual;
    };
    try std.testing.expectEqualStrings(want, got);
}
