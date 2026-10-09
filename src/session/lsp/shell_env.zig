//! 언어 서버 도구 환경 해석기의 순수 계산(계획 docs/plans/workspace-trust.md WT3a — 계약 docs/editor-surface-tooling.md §8.1
//! 「서버 환경은 사용자 셸 환경」). 무엇을 실행하고(셸별 인자·명령·셸에 줄 환경), 돌아온 것을 어떻게 읽고(표식·`env -0`), 서버에
//! 무엇을 넘길지(위생·PATH 정리)를 정한다. 셸을 띄우고 기다리는 일은 플랫폼 층(WT3b)이다.
//!
//! **출력은 파일로 받는다** — 앱이 비공개 디렉터리(0700)에 미리 만든 빈 파일(0600)에 셸이 `>>` 로 덧붙인다. fd 로 받지 않는 것은
//! csh·tcsh 가 시작할 때 3번 이상 fd 를 닫기 때문이고(실측 2026-10-08: `/dev/fd/3` 이 「Bad file descriptor」), 파일을 미리 만드는
//! 것은 zsh `noclobber` 가 없는 파일에는 `>>` 도 막기 때문이다. 그 조합은 zsh·bash·sh·dash·ksh·csh·tcsh 에서 `noclobber` 를 켜도
//! 통과했다. 같은 명령 문법(단순 명령·`;`·`>>`·작은따옴표)이 sh 계열·csh·fish 모두에서 돈다. `/usr/bin/env -0` 은 macOS 12.3 부터다
//! (그 전 `shell_cmds` 의 `env` 는 `-0` 이 없다) — 그 아래에서는 셸을 띄우지 않는다(WT3b).
//!
//! **표식 둘이 다 있어야 성공이다** — 셸 설정이 `exec` 로 다른 프로그램(tmux 등)을 띄우거나 도중에 죽으면 끝 표식이 없다.

const std = @import("std");
const inherited_env = @import("../../inherited_env.zig");

/// 셸을 기다리는 시한(VS Code 와 같은 10 초 — JetBrains 는 20 초). 넘기면 그룹째 끝내고 앱 환경으로 대신한다.
pub const timeout_ms: u64 = 10_000;

/// 셸 설정이 「maru 가 환경을 읽는 중」을 알아보는 표식 변수(VS Code `VSCODE_RESOLVING_ENVIRONMENT`·JetBrains
/// `INTELLIJ_ENVIRONMENT_READER` 와 같은 관례) — 무거운 초기화를 건너뛰게 할 수 있다. 서버에는 넘기지 않는다.
pub const probe_marker = "MARU_RESOLVING_ENVIRONMENT";

/// 셸에 더 줄 변수 — 표식과 oh-my-zsh 자동 업데이트 끄기(JetBrains 와 같다 — 업데이트 프롬프트가 입력을 기다리며 시한까지 간다).
pub const probe_extra = [_][]const u8{ probe_marker ++ "=1", "DISABLE_AUTO_UPDATE=true" };

/// 셸 문법 계열 — 인자가 갈린다(명령은 같다).
pub const Shell = enum {
    /// zsh·bash·sh·dash·ksh 계열 — `-l -i -c`.
    posix,
    /// csh·tcsh — `-l` 은 단독으로만 쓸 수 있어 뺀다(`-i -c`; 로그인 설정 `.login` 은 안 읽는다).
    csh,
    /// fish — `-l -i -c`(sh 계열과 같다 — `config.fish` 의 `if status is-interactive` 블록이 PATH 를 흔히 든다; VS Code 와 같다).
    /// 문법이 달라 따로 둔다(명령은 같다).
    fish,
};

/// 로그인 셸 경로(`getpwuid` 의 `pw_shell`)로 계열을 고른다. 모르는 셸(nushell·xonsh 등)은 `null` — 앱 환경으로 대신한다
/// (명령 문법이 다르다). 로그인 셸 표기의 앞 `-`(`-zsh`)는 떼고 본다.
pub fn shellKind(login_shell: []const u8) ?Shell {
    const slash = std.mem.lastIndexOfScalar(u8, login_shell, '/');
    var base = if (slash) |i| login_shell[i + 1 ..] else login_shell;
    if (base.len > 0 and base[0] == '-') base = base[1..];
    const posix_names = [_][]const u8{ "zsh", "bash", "sh", "dash", "ksh", "mksh", "oksh", "pdksh", "yash" };
    for (posix_names) |n| if (std.mem.eql(u8, base, n)) return .posix;
    if (std.mem.eql(u8, base, "csh") or std.mem.eql(u8, base, "tcsh")) return .csh;
    if (std.mem.eql(u8, base, "fish")) return .fish;
    return null;
}

/// 셸 경로 뒤, 명령 앞에 둘 인자(`-c` 까지).
pub fn flags(kind: Shell) []const []const u8 {
    return switch (kind) {
        .posix => &.{ "-l", "-i", "-c" },
        .csh => &.{ "-i", "-c" },
        .fish => &.{ "-l", "-i", "-c" },
    };
}

/// 표식에 붙일 일회용 값의 길이(16진 16자 — 호출자가 무작위로 만든다). 환경 값에 같은 문자열이 우연히 있을 수 없게.
pub const nonce_len = 16;

const begin_prefix = "MARU_ENV_BEGIN_";
const end_prefix = "MARU_ENV_END_";

/// 파일 경로를 셸 명령에 작은따옴표로 넣어도 되는가 — 글자·숫자·`/._-` 만. 따옴표·`!`(csh 는 작은따옴표 안에서도 히스토리를
/// 펼친다)·공백·`$` 등은 셸마다 뜻이 갈리므로 받지 않는다(그런 경로면 해석하지 않고 앱 환경으로 대신한다).
pub fn isSafePath(path: []const u8) bool {
    if (path.len == 0 or path[0] != '/') return false;
    for (path) |c| switch (c) {
        'a'...'z', 'A'...'Z', '0'...'9', '/', '.', '_', '-' => {},
        else => return false,
    };
    return true;
}

fn isNonce(nonce: []const u8) bool {
    if (nonce.len != nonce_len) return false;
    for (nonce) |c| switch (c) {
        '0'...'9', 'a'...'f' => {},
        else => return false,
    };
    return true;
}

/// 셸에 줄 명령 — 시작 표식 · `/usr/bin/env -0` · 끝 표식을 `out_path` 에 덧붙인다. 실행 파일은 절대 경로(별칭은 끼지 않는다 —
/// 사용자 설정이 그 경로 이름으로 함수를 정의하면 낄 수 있지만 사용자 자신의 설정이다). `%s` 는 작은따옴표로 감싼다(옛 fish 의 `%`
/// 펼침).
/// 경로나 일회용 값이 안전하지 않으면 `error.Unsafe`.
pub fn command(out_path: []const u8, nonce: []const u8, buf: []u8) error{ Unsafe, NoSpaceLeft }![]const u8 {
    if (!isSafePath(out_path) or !isNonce(nonce)) return error.Unsafe;
    return std.fmt.bufPrint(buf, "/usr/bin/printf '%s' " ++ begin_prefix ++ "{s} >> '{s}'; /usr/bin/env -0 >> '{s}'; /usr/bin/printf '%s' " ++ end_prefix ++ "{s} >> '{s}'", .{ nonce, out_path, out_path, nonce, out_path });
}

/// 터미널에서 띄운 앱이 셸에 넘기는 바탕 — 사용자·셸·로캘(`LANG`·`LC_*`·`__CF_USER_TEXT_ENCODING`)·임시 폴더·에이전트 소켓·launchd
/// 서비스 표시(`XPC_*`)만(그 밖은 로그인 셸 설정이 다시 세운다).
pub const minimal_keys = [_][]const u8{ "HOME", "USER", "LOGNAME", "SHELL", "TMPDIR", "LANG", "__CF_USER_TEXT_ENCODING", "SSH_AUTH_SOCK", "XPC_FLAGS", "XPC_SERVICE_NAME" };
/// 최소 바탕의 PATH — 시스템 경로만. 로그인 셸(macOS `/etc/zprofile`·`/etc/profile` 의 `path_helper`)이 나머지를 다시 세운다.
pub const minimal_path = "PATH=/usr/bin:/bin:/usr/sbin:/sbin";

/// 셸에 줄 환경. **앱을 터미널에서 띄웠으면**(앱 환경에 `SHLVL` 이 있다 — Finder·Dock 은 launchd 환경이라 없다; `open` 은 부른
/// 셸의 환경을 통째로 넘기므로 터미널 실행이다, 실측) 그 환경에는
/// 그 터미널이 서 있던 저장소의 direnv·venv(`VIRTUAL_ENV`·`GOFLAGS`·`.venv/bin` 이 든 PATH)가 섞여 있고, 로그인 셸을 거쳐도 남는다
/// (path_helper 는 기존 PATH 항목을 뒤에 붙이고, direnv 훅은 프롬프트에서만 돈다 — 실측). 그때는 `minimal_keys`·`LC_*` 와
/// `minimal_path` 만 바탕으로 준다(사용자 결정 2026-10-08). 아니면 앱 환경(launchd — `launchctl setenv` 값 포함)에서 터미널 세션
/// 변수만 뺀다. 어느 쪽이든 `probe_extra` 를 붙인다. 항목은 빌린다(`app_env` 와 정적 문자열). 한계: 터미널(또는 `open`)로 띄우면
/// `launchctl setenv` 값이 바탕에서 빠진다 — 같은 사용자라도 띄운 방식에 따라 서버 환경이 갈린다.
pub fn probeEnv(allocator: std.mem.Allocator, app_env: []const []const u8, out: *std.ArrayList([]const u8)) error{OutOfMemory}!void {
    const from_terminal = for (app_env) |entry| {
        if (inherited_env.keyIs(entry, "SHLVL", false)) break true;
    } else false;
    for (app_env) |entry| {
        const k = inherited_env.key(entry) orelse continue;
        if (inherited_env.isTerminalSession(entry, false)) continue;
        if (isProbeExtraKey(entry)) continue;
        if (from_terminal and !isMinimalKey(k)) continue;
        try out.append(allocator, entry);
    }
    if (from_terminal) try out.append(allocator, minimal_path);
    for (probe_extra) |e| try out.append(allocator, e);
}

fn isMinimalKey(k: []const u8) bool {
    if (std.mem.startsWith(u8, k, "LC_")) return true;
    for (minimal_keys) |name| if (std.mem.eql(u8, k, name)) return true;
    return false;
}

fn isProbeExtraKey(entry: []const u8) bool {
    for (probe_extra) |e| if (inherited_env.keyIs(entry, inherited_env.key(e).?, false)) return true;
    return false;
}

/// 셸 상태 변수 — 해석에 쓴 셸의 것이지 사용자 환경이 아니다(서버에 넘기지 않는다). 터미널 세션 변수(`inherited_env`)와 함께 뺀다.
/// 셸에 우리가 준 `DISABLE_AUTO_UPDATE`, maru PTY 가 자식에 넣는 능력 변수 `FORCE_HYPERLINK`(서버는 터미널이 아니다 — `FORCE_COLOR`
/// 와 같은 이유; PTY 는 사용자 값이 이기게 일부러 안 떨궈 공용 목록에는 못 넣는다)도 여기다. `MARU_` 로 시작하는 이름(maru 내부 —
/// 표식·`MARU_ZDOTDIR_PREV`·`MARU_BIN`·`MARU_SSH_INTEGRATION`·`MARU_CONFIG` 등)은 `keep` 이 접두로 뺀다.
pub const shell_state_keys = [_][]const u8{ "PWD", "OLDPWD", "SHLVL", "_", "ZDOTDIR", "DISABLE_AUTO_UPDATE", "FORCE_HYPERLINK" };

/// 서버에 넘길 항목인가(시스템 위생) — 터미널 세션 변수·셸 상태 변수·maru 내부 변수를 뺀다. 비밀 이름 패턴으로 빼지 않는다(계획
/// WT3 「위생」 — 사용자가 일부러 넣은 값이다). `NODE_OPTIONS`·`PYTHONPATH` 같은 런타임 옵션도 그대로다. 사용자 제외 목록은 여기가
/// 아니라 서버에 줄 envp 를 만들 때다(`excludedBy` — 계획 WT5b-1).
pub fn keep(entry: []const u8) bool {
    const k = inherited_env.key(entry) orelse return false;
    if (k.len == 0) return false;
    if (inherited_env.isTerminalSession(entry, false)) return false;
    if (std.mem.startsWith(u8, k, "MARU_")) return false;
    for (shell_state_keys) |name| if (std.mem.eql(u8, k, name)) return false;
    return true;
}

/// 사용자 제외 목록(설정 `lsp.environment-exclude` — 계획 WT5b-1)이 이 이름을 빼는가. 목록은 쉼표로 가른 이름들이고(앞뒤 공백·빈 항목은
/// 무시), **이름 끝의 `*` 만** 접두로 본다(`AWS_*` — 비밀 변수는 묶음으로 온다; 그 밖의 글롭은 없다 — 2026-10-09 사용자 결정). `*`
/// 하나는 모든 이름이다(사용자가 고른 것이다 — 서버는 빈 환경으로 뜬다). 시스템 위생(`keep`)과 달리 걸러 낸 원본은 그대로 두고
/// 서버에 줄 envp 를 만들 때 적용한다 — 목록 상자가 「제외됨」을 보이고, 목록을 바꿔도 셸을 다시 띄우지 않는다.
pub fn excludedBy(name: []const u8, list: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |raw| {
        const p = std.mem.trim(u8, raw, " \t");
        if (p.len == 0) continue;
        if (p[p.len - 1] == '*') {
            if (std.mem.startsWith(u8, name, p[0 .. p.len - 1])) return true;
        } else if (std.mem.eql(u8, name, p)) return true;
    }
    return false;
}

/// 항목(`KEY=VALUE`)의 이름 — 목록 상자·제외 판정이 쓴다. `sanitize` 를 지난 항목은 늘 이름이 있다.
pub fn entryName(entry: []const u8) []const u8 {
    return inherited_env.key(entry) orelse entry;
}

/// PATH 정리 — 절대 경로 항목만(빈 항목 `::` 와 상대 경로는 현재 폴더 — 서버의 cwd 는 저장소다 — 를 뜻하므로 버린다), 중복은 처음
/// 것만. `out` 은 `path.len` 이상.
pub fn cleanPath(path: []const u8, out: []u8) []const u8 {
    std.debug.assert(out.len >= path.len);
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, path, ':');
    while (it.next()) |part| {
        if (part.len == 0 or part[0] != '/') continue;
        if (containsEntry(out[0..n], part)) continue;
        if (n > 0) {
            out[n] = ':';
            n += 1;
        }
        @memcpy(out[n..][0..part.len], part);
        n += part.len;
    }
    return out[0..n];
}

fn containsEntry(joined: []const u8, part: []const u8) bool {
    var it = std.mem.splitScalar(u8, joined, ':');
    while (it.next()) |e| if (std.mem.eql(u8, e, part)) return true;
    return false;
}

/// 해석한 환경 — 서버에 넘길 항목(소유, `KEY=VALUE\0`)과 그중 PATH(정리한 값, 없으면 `null`).
pub const Resolved = struct {
    entries: [][:0]u8,
    path: ?[]const u8,

    pub fn deinit(self: *Resolved, allocator: std.mem.Allocator) void {
        for (self.entries) |e| allocator.free(e);
        allocator.free(self.entries);
        self.* = undefined;
    }
};

/// 셸이 파일에 남긴 것을 읽는다 — 시작 표식으로 시작하고 끝 표식으로 끝나야 하며(아니면 `error.Malformed` — 설정 파일이 `exec` 로
/// 다른 프로그램을 띄웠거나 도중에 죽었다), 그 사이는 `env -0` 출력(항목마다 NUL 로 끝난다)이다. **셸에 준 표식 변수가 그 안에
/// 있어야 한다** — 명령이 `;` 로 이어져 `env -0` 이 실패해도 표식 둘은 찍히므로, 그것 없이는 빈 출력을 「빈 환경」으로 받는다.
/// 항목은 `sanitize` 가 거른다(대체 경로 — 셸을 못 읽었다·스위치 끔 — 도 같은 함수다).
pub fn resolve(allocator: std.mem.Allocator, data: []const u8, nonce: []const u8) error{ Malformed, OutOfMemory }!Resolved {
    if (!isNonce(nonce)) return error.Malformed;
    var begin_buf: [begin_prefix.len + nonce_len]u8 = undefined;
    var end_buf: [end_prefix.len + nonce_len]u8 = undefined;
    const begin = std.fmt.bufPrint(&begin_buf, begin_prefix ++ "{s}", .{nonce}) catch unreachable;
    const end = std.fmt.bufPrint(&end_buf, end_prefix ++ "{s}", .{nonce}) catch unreachable;
    if (data.len < begin.len + end.len or !std.mem.startsWith(u8, data, begin) or !std.mem.endsWith(u8, data, end)) return error.Malformed;
    const body = data[begin.len .. data.len - end.len];
    if (body.len > 0 and body[body.len - 1] != 0) return error.Malformed; // 마지막 항목이 NUL 로 안 끝났다 — 잘렸다

    var entries: std.ArrayList([]const u8) = .empty;
    defer entries.deinit(allocator);
    var saw_probe = false;
    var it = std.mem.splitScalar(u8, body, 0);
    while (it.next()) |entry| {
        if (std.mem.eql(u8, entry, probe_extra[0])) saw_probe = true;
        try entries.append(allocator, entry);
    }
    if (!saw_probe) return error.Malformed;
    return sanitize(allocator, entries.items);
}

/// 서버에 넘길 환경을 만든다 — 항목은 `keep` 으로 거르고, 같은 키가 두 번이면 처음 것만(서버가 어느 쪽을 볼지 갈리지 않게), PATH 는
/// `cleanPath` 로 정리하며 정리해서 비면 넘기지 않는다(빈 PATH 는 현재 폴더 — 서버의 cwd 인 저장소 — 를 찾는다; macOS 실측). 빈
/// PATH 도 「처음 것」이다 — 뒤의 PATH 가 그 자리를 차지하지 않는다. **해석 결과와 대체 경로(앱 환경 — 셸을 못 읽었다·지원 안 하는
/// 셸·스위치 끔)가 함께 쓴다** — 대체 경로에서도 터미널 세션 변수와 상대 PATH 항목이 서버로 가지 않게. bash 만 펼치는 PATH 의
/// `~/bin` 같은 항목은 상대 경로로 보고 버린다(한계 — 계획 WT3a).
pub fn sanitize(allocator: std.mem.Allocator, env: []const []const u8) error{OutOfMemory}!Resolved {
    var list: std.ArrayList([:0]u8) = .empty;
    errdefer {
        for (list.items) |e| allocator.free(e);
        list.deinit(allocator);
    }
    var path_index: ?usize = null;
    var seen_path = false;
    for (env) |entry| {
        if (!keep(entry)) continue;
        const k = inherited_env.key(entry).?;
        if (std.mem.eql(u8, k, "PATH")) {
            if (seen_path) continue;
            seen_path = true;
            const value = entry["PATH=".len..];
            const scratch = try allocator.alloc(u8, value.len);
            defer allocator.free(scratch);
            const cleaned = cleanPath(value, scratch);
            if (cleaned.len == 0) continue; // 빈 PATH 는 넘기지 않는다
            const owned = try std.fmt.allocPrintSentinel(allocator, "PATH={s}", .{cleaned}, 0);
            errdefer allocator.free(owned);
            path_index = list.items.len;
            try list.append(allocator, owned);
            continue;
        }
        const dup = for (list.items) |e| {
            if (std.mem.eql(u8, inherited_env.key(e).?, k)) break true;
        } else false;
        if (dup) continue;
        const owned = try allocator.dupeZ(u8, entry);
        errdefer allocator.free(owned);
        try list.append(allocator, owned);
    }
    const entries = try list.toOwnedSlice(allocator);
    return .{ .entries = entries, .path = if (path_index) |i| entries[i]["PATH=".len..] else null };
}

// ── 판정 ────────────────────────────────────────────────────────────────────────

const testing = std.testing;
const nonce_a = "0123456789abcdef";

test "shell_env: 셸 계열 — sh 계열·csh·fish 를 가르고 경로·로그인 표기(-zsh)를 받으며, 모르는 셸(nushell)은 null; 계열별 인자" {
    try testing.expectEqual(Shell.posix, shellKind("/bin/zsh").?);
    try testing.expectEqual(Shell.posix, shellKind("/opt/homebrew/bin/bash").?);
    try testing.expectEqual(Shell.posix, shellKind("-zsh").?);
    try testing.expectEqual(Shell.posix, shellKind("/bin/dash").?);
    try testing.expectEqual(Shell.posix, shellKind("/bin/ksh").?);
    try testing.expectEqual(Shell.csh, shellKind("/bin/tcsh").?);
    try testing.expectEqual(Shell.csh, shellKind("/bin/csh").?);
    try testing.expectEqual(Shell.fish, shellKind("/opt/homebrew/bin/fish").?);
    try testing.expect(shellKind("/opt/homebrew/bin/nu") == null);
    try testing.expect(shellKind("/usr/bin/xonsh") == null);
    try testing.expect(shellKind("") == null);
    try testing.expect(shellKind("/bin/zsh5") == null); // 이름이 정확히 같아야 한다
    const posix = flags(.posix);
    try testing.expectEqual(@as(usize, 3), posix.len);
    try testing.expectEqualStrings("-l", posix[0]);
    try testing.expectEqualStrings("-i", posix[1]);
    try testing.expectEqualStrings("-c", posix[2]);
    const csh = flags(.csh);
    try testing.expectEqual(@as(usize, 2), csh.len); // -l 은 단독으로만 — 빠진다
    try testing.expectEqualStrings("-i", csh[0]);
    const fish = flags(.fish);
    try testing.expectEqualStrings("-l", fish[0]);
    try testing.expectEqual(@as(usize, 3), fish.len);
    try testing.expectEqualStrings("-i", fish[1]); // 대화형 설정(`if status is-interactive`)도 읽는다
}

test "shell_env: 명령 — 절대 경로 실행 파일로 표식·env -0·표식을 작은따옴표 경로에 >> 로 덧붙이고, 안전하지 않은 경로·일회용 값은 거절한다" {
    var buf: [512]u8 = undefined;
    const cmd = try command("/var/folders/ab/T/maru-env.x1/out", nonce_a, &buf);
    try testing.expectEqualStrings(
        "/usr/bin/printf '%s' MARU_ENV_BEGIN_0123456789abcdef >> '/var/folders/ab/T/maru-env.x1/out'; " ++
            "/usr/bin/env -0 >> '/var/folders/ab/T/maru-env.x1/out'; " ++
            "/usr/bin/printf '%s' MARU_ENV_END_0123456789abcdef >> '/var/folders/ab/T/maru-env.x1/out'",
        cmd,
    );
    for ([_][]const u8{ "/tmp/a b/out", "/tmp/it's", "/tmp/a!b", "/tmp/$HOME", "/tmp/a\"b", "/tmp/a`b", "/tmp/a\\b", "relative/out", "", "/tmp/a\nb" }) |bad|
        try testing.expectError(error.Unsafe, command(bad, nonce_a, &buf));
    try testing.expectError(error.Unsafe, command("/tmp/out", "0123456789ABCDEF", &buf)); // 대문자 16진은 아니다
    try testing.expectError(error.Unsafe, command("/tmp/out", "short", &buf));
    try testing.expectError(error.Unsafe, command("/tmp/out", "0123456789abcde;", &buf));
    var tiny: [16]u8 = undefined;
    try testing.expectError(error.NoSpaceLeft, command("/tmp/out", nonce_a, &tiny));
}

test "shell_env: 셸에 줄 환경(Finder·Dock 으로 띄운 앱 — SHLVL 없음) — 터미널 세션 변수·이미 있던 표식·자동 업데이트 키는 빼고, 나머지는 그대로 두며 표식·DISABLE_AUTO_UPDATE 를 붙인다" {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);
    const app = [_][]const u8{ "PATH=/usr/bin:/bin", "TERM=xterm-maru", "TMUX=/tmp/x,1,0", "MARU_PANE_ID=3", "HOME=/Users/u", "MARU_RESOLVING_ENVIRONMENT=0", "DISABLE_AUTO_UPDATE=false", "NOEQ", "LANG=ko_KR.UTF-8" };
    try probeEnv(testing.allocator, &app, &out);
    const want = [_][]const u8{ "PATH=/usr/bin:/bin", "HOME=/Users/u", "LANG=ko_KR.UTF-8", "MARU_RESOLVING_ENVIRONMENT=1", "DISABLE_AUTO_UPDATE=true" };
    try testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, got| try testing.expectEqualStrings(w, got);
}

test "shell_env: 셸에 줄 환경(터미널에서 띄운 앱 — SHLVL 있음) — 그 터미널 저장소의 direnv·venv 와 PATH 는 버리고 사용자·로캘·임시 폴더·에이전트 소켓만 바탕으로, PATH 는 시스템 경로만 (사용자 결정 2026-10-08)" {
    var out: std.ArrayList([]const u8) = .empty;
    defer out.deinit(testing.allocator);
    const app = [_][]const u8{
        "SHLVL=2",                                "PATH=/other/repo/.venv/bin:/other/repo/node_modules/.bin:/usr/bin",
        "VIRTUAL_ENV=/other/repo/.venv",          "DIRENV_DIFF=eJx",
        "GOFLAGS=-mod=vendor",                    "HOME=/Users/u",
        "USER=u",                                 "LOGNAME=u",
        "LANG=ko_KR.UTF-8",                       "LC_ALL=ko_KR.UTF-8",
        "TMPDIR=/var/folders/x/T/",               "SSH_AUTH_SOCK=/private/tmp/launchd/x",
        "__CF_USER_TEXT_ENCODING=0x1F5:0x3:0x33", "XPC_FLAGS=0x0",
        "XPC_SERVICE_NAME=0",                     "TERM=xterm-maru",
        "MARU_PANE_ID=4",                         "DISABLE_AUTO_UPDATE=false",
        "SHELL=/bin/zsh",                         "OLLAMA_MAX_LOADED_MODELS=2",
    };
    try probeEnv(testing.allocator, &app, &out);
    const want = [_][]const u8{
        "HOME=/Users/u",                "USER=u",                   "LOGNAME=u",                            "LANG=ko_KR.UTF-8",
        "LC_ALL=ko_KR.UTF-8",           "TMPDIR=/var/folders/x/T/", "SSH_AUTH_SOCK=/private/tmp/launchd/x", "__CF_USER_TEXT_ENCODING=0x1F5:0x3:0x33",
        "XPC_FLAGS=0x0",                "XPC_SERVICE_NAME=0",       "SHELL=/bin/zsh",                       minimal_path,
        "MARU_RESOLVING_ENVIRONMENT=1", "DISABLE_AUTO_UPDATE=true",
    };
    try testing.expectEqual(want.len, out.items.len);
    for (want, out.items) |w, got| try testing.expectEqualStrings(w, got);
}

test "shell_env: 위생 — 터미널 세션 변수·셸 상태 변수는 빼고, 런타임 옵션·비밀처럼 보이는 이름·빈 값은 그대로다" {
    for ([_][]const u8{ "TERM=xterm", "COLORTERM=truecolor", "TERM_PROGRAM=maru", "TMUX_PANE=%1", "MARU_PANE_ID=1", "PWD=/x", "OLDPWD=/y", "SHLVL=2", "_=/usr/bin/env", "ZDOTDIR=/z", "MARU_ZDOTDIR_PREV=/z", "MARU_BIN=/m", "MARU_SSH_INTEGRATION=1", "MARU_RESOLVING_ENVIRONMENT=1", "DISABLE_AUTO_UPDATE=true", "MARU_CONFIG=/c", "MARU_DEBUG=1", "FORCE_HYPERLINK=1", "=C:=C:\\w", "NOEQ" }) |e|
        try testing.expect(!keep(e));
    for ([_][]const u8{ "PATH=/bin", "NODE_OPTIONS=--max-old-space-size=4096", "PYTHONPATH=/p", "GITHUB_TOKEN=x", "AWS_SECRET_ACCESS_KEY=y", "RUSTUP_HOME=/r", "EMPTY=", "TERMINAL_EMULATOR=x", "LC_MARU_PANE=x", "TMPDIR=/t", "SSH_AUTH_SOCK=/s", "__CF_USER_TEXT_ENCODING=0x1F5:0x3:0x33" }) |e|
        try testing.expect(keep(e));
}

test "LSPX1 환경 제외 목록 — 쉼표로 가른 정확한 이름과 끝 `*` 접두, 공백·빈 항목은 무시, 그 밖의 글롭은 글자 그대로 (계획 workspace-trust WT5b-1)" {
    const list = " GITHUB_TOKEN , AWS_*,,\tNPM_TOKEN\t, A*B";
    for ([_][]const u8{ "GITHUB_TOKEN", "AWS_SECRET_ACCESS_KEY", "AWS_", "NPM_TOKEN" }) |n| try testing.expect(excludedBy(n, list));
    // 이름이 정확히 같아야 한다(접두는 끝 `*` 일 때만) · 가운데 `*` 는 글롭이 아니다.
    for ([_][]const u8{ "GITHUB_TOKENS", "XGITHUB_TOKEN", "AWS", "aws_x", "AXB", "A*BC", "PATH", "" }) |n| try testing.expect(!excludedBy(n, list));
    try testing.expect(excludedBy("A*B", list));
    try testing.expect(!excludedBy("PATH", ""));
    try testing.expect(!excludedBy("PATH", " , ,"));
    try testing.expect(excludedBy("PATH", "*")); // `*` 하나는 모든 이름이다
    try testing.expectEqualStrings("GITHUB_TOKEN", entryName("GITHUB_TOKEN=a=b"));
}

test "shell_env: PATH 정리 — 절대 경로만, 빈 항목·상대 경로(현재 폴더)는 버리고 중복은 처음 것만" {
    var buf: [256]u8 = undefined;
    try testing.expectEqualStrings("/a/bin:/usr/bin:/bin", cleanPath("/a/bin::.:/usr/bin:node_modules/.bin:/bin:/usr/bin:", &buf));
    try testing.expectEqualStrings("", cleanPath("", &buf));
    try testing.expectEqualStrings("", cleanPath(":::.", &buf));
    try testing.expectEqualStrings("/x", cleanPath("/x", &buf));
}

test "shell_env: 결과 읽기 — 표식 둘 사이의 env -0 을 거르고 PATH 를 정리하며 같은 키는 처음 것만; 표식이 없거나 잘렸으면 Malformed" {
    const data = "MARU_ENV_BEGIN_" ++ nonce_a ++
        "PATH=/opt/homebrew/bin::.:/usr/bin\x00TERM=xterm\x00HOME=/Users/u\x00MULTI=a\nb\x00SECRET=s\x00HOME=/dup\x00SHLVL=2\x00" ++
        "MARU_RESOLVING_ENVIRONMENT=1\x00DISABLE_AUTO_UPDATE=true\x00" ++
        "MARU_ENV_END_" ++ nonce_a;
    var r = try resolve(testing.allocator, data, nonce_a);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 4), r.entries.len); // 사용자 제외는 여기가 아니다 — `SECRET` 도 남는다(envp 를 만들 때 거른다)
    try testing.expectEqualStrings("PATH=/opt/homebrew/bin:/usr/bin", r.entries[0]);
    try testing.expectEqualStrings("HOME=/Users/u", r.entries[1]);
    try testing.expectEqualStrings("MULTI=a\nb", r.entries[2]); // 값 속 개행 — env -0 이라 갈리지 않는다
    try testing.expectEqualStrings("SECRET=s", r.entries[3]);
    try testing.expectEqualStrings("/opt/homebrew/bin:/usr/bin", r.path.?);
    // 셸에 준 것뿐인 환경도 성공이다(PATH 없음). PATH 가 정리해서 비면 넘기지 않는다 — 빈 PATH 는 현재 폴더(저장소)를 찾는다.
    var empty = try resolve(testing.allocator, "MARU_ENV_BEGIN_" ++ nonce_a ++ "MARU_RESOLVING_ENVIRONMENT=1\x00PATH=.:bin::\x00" ++ "MARU_ENV_END_" ++ nonce_a, nonce_a);
    defer empty.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 0), empty.entries.len);
    try testing.expect(empty.path == null);
    const bad = [_][]const u8{
        "", // 아무것도 안 썼다(셸이 시작 전에 죽었다)
        "MARU_ENV_BEGIN_" ++ nonce_a ++ "MARU_ENV_END_" ++ nonce_a, // `env -0` 이 실패했다(`;` 라 표식은 둘 다 찍힌다)
        "MARU_ENV_BEGIN_" ++ nonce_a ++ "PATH=/bin\x00HOME=/h\x00" ++ "MARU_ENV_END_" ++ nonce_a, // 셸에 준 표식 변수가 없다
        "MARU_ENV_BEGIN_" ++ nonce_a ++ "PATH=/bin\x00", // 끝 표식이 없다(설정 파일이 exec)
        "PATH=/bin\x00MARU_ENV_END_" ++ nonce_a, // 시작 표식이 없다
        "MARU_ENV_BEGIN_" ++ nonce_a ++ "MARU_RESOLVING_ENVIRONMENT=1\x00PATH=/bin" ++ "MARU_ENV_END_" ++ nonce_a, // 마지막 항목이 NUL 로 안 끝났다
        "MARU_ENV_BEGIN_fedcba9876543210PATH=/bin\x00MARU_ENV_END_fedcba9876543210", // 다른 실행의 표식
        "junk" ++ "MARU_ENV_BEGIN_" ++ nonce_a ++ "MARU_ENV_END_" ++ nonce_a, // 앞에 다른 것이 섞였다
        // 끝 표식 없이 긴 출력 — 마지막 항목(끝 표식 길이와 같다)을 잘라 내도 NUL 로 끝나 그럴듯해 보인다.
        "MARU_ENV_BEGIN_" ++ nonce_a ++ "MARU_RESOLVING_ENVIRONMENT=1\x00A=1\x00" ++ "X=" ++ "y" ** 26 ++ "\x00",
    };
    for (bad) |b| try testing.expectError(error.Malformed, resolve(testing.allocator, b, nonce_a));
    try testing.expectError(error.Malformed, resolve(testing.allocator, data, "nothex"));
}

test "shell_env: 대체 경로(셸을 못 읽었다·스위치 끔)도 같은 위생 — 앱 환경의 터미널 변수·내부 변수·상대 PATH 항목이 서버로 가지 않고, 첫 PATH 가 정리해서 비면 뒤의 PATH 가 그 자리를 차지하지 않는다" {
    const app = [_][]const u8{ "TERM=xterm-maru", "TMUX=/tmp/x,1,0", "MARU_PANE_ID=4", "PATH=.:node_modules/.bin:/usr/bin::/usr/bin", "HOME=/h", "HOME=/dup" };
    var r = try sanitize(testing.allocator, &app);
    defer r.deinit(testing.allocator);
    try testing.expectEqual(@as(usize, 2), r.entries.len);
    try testing.expectEqualStrings("PATH=/usr/bin", r.entries[0]);
    try testing.expectEqualStrings("HOME=/h", r.entries[1]);
    try testing.expectEqualStrings("/usr/bin", r.path.?);
    const two = [_][]const u8{ "PATH=.:", "PATH=/x/bin", "LANG=C" };
    var r2 = try sanitize(testing.allocator, &two);
    defer r2.deinit(testing.allocator);
    try testing.expect(r2.path == null);
    try testing.expectEqual(@as(usize, 1), r2.entries.len);
    try testing.expectEqualStrings("LANG=C", r2.entries[0]);
}

test "shell_env: 결과 읽기는 메모리가 모자라도 새지 않는다" {
    const data = "MARU_ENV_BEGIN_" ++ nonce_a ++ "PATH=/a::/b\x00HOME=/h\x00LANG=x\x00MARU_RESOLVING_ENVIRONMENT=1\x00" ++ "MARU_ENV_END_" ++ nonce_a;
    try testing.checkAllAllocationFailures(testing.allocator, struct {
        fn f(a: std.mem.Allocator) !void {
            var r = try resolve(a, data, nonce_a);
            r.deinit(a);
        }
    }.f, .{});
}
