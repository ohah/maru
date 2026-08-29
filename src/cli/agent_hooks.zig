//! `maru agent-hooks install|uninstall` — **원격 기계에서 그 기계의 provider 설정에 훅을 심는다**
//! ([계획](../../docs/plans/remote-agent-state.md) RA3).
//!
//! **왜 로컬이 원격 파일을 직접 고치지 않나.** 로컬이 `~/.claude/settings.json` 을 ssh 로 읽어 고쳐 쓰면
//! 그 사이에 **그 기계의 claude·codex·maru 가 같은 파일을 쓴다** — 로컬에는 그것을 막을 락이 없다.
//! 그 파일은 사용자의 다른 설정을 함께 담고 있어(claude 는 훅 전용 파일이 아니다) 경합의 대가가
//! «설정이 통째로 날아감» 이다. 그래서 **로직을 원격으로 보낸다**: 그 기계의 `maru` 가 그 기계의 락으로
//! read-modify-write 를 한다. RA4 가 이미 «원격에 maru 가 있다» 를 전제하므로 추가 비용이 없다.
//!
//! **이 파일은 순수하다** — OS 를 안 부른다. 파일 읽기·쓰기·락은 호출자가 한다. 판정(무엇을 심고 뺄지)은
//! `session/agent_hook_install.zig` 가 이미 갖고 있고 여기서는 **인자 해석만** 한다.

const std = @import("std");
const command = @import("../session/agent_hook_command.zig");

pub const Action = enum { install, uninstall };

pub const Mode = union(enum) {
    run: Options,
    help,
    /// 인자가 계약과 다르다. **조용히 기본값으로 돌지 않는다** — 그러면 엉뚱한 provider 파일을 고친다.
    usage_error,
};

pub const Options = struct {
    action: Action,
    provider: command.Provider,
    /// 훅이 이벤트를 적을 디렉터리(**절대 경로**). 상대 경로면 훅이 도는 cwd 에 끌려간다 —
    /// 그 cwd 는 사용자가 `cd` 로 아무 때나 바꾸므로 «어제 로그가 어디 있는지 모르는» 상태가 된다.
    dir: []const u8,
};

/// `agent-hooks` 뒤 인자를 해석한다.
///
/// **모르는 플래그는 오류다.** 조용히 무시하면 오타가 «기본값으로 도는» 상태가 되는데, 이 프로그램은
/// 사용자의 provider 설정을 고치므로 그 «기본값» 이 남의 파일을 건드릴 수 있다.
///
/// **`--scope` 를 요구한다.** 지금 쓰이는 값은 `remote` 뿐이지만 기본값으로 두지 않는다 — 로컬 설치는
/// GUI 가 자기 락으로 하는 **다른 경로**이고, 이 CLI 가 우연히 그 일을 하게 되면 두 설치기가 같은 파일을
/// 두 규칙으로 만진다.
pub fn parseArgs(args: []const []const u8) Mode {
    if (args.len == 0) return .usage_error;
    for (args) |a| if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return .help;

    const action: Action = if (std.mem.eql(u8, args[0], "install"))
        .install
    else if (std.mem.eql(u8, args[0], "uninstall"))
        .uninstall
    else
        return .usage_error;

    var provider: ?command.Provider = null;
    var dir: ?[]const u8 = null;
    var scope_seen = false;

    for (args[1..]) |arg| {
        if (std.mem.startsWith(u8, arg, "--provider=")) {
            const v = arg["--provider=".len..];
            if (std.mem.eql(u8, v, "claude")) {
                provider = .claude;
            } else if (std.mem.eql(u8, v, "codex")) {
                provider = .codex;
            } else return .usage_error;
        } else if (std.mem.startsWith(u8, arg, "--dir=")) {
            dir = arg["--dir=".len..];
        } else if (std.mem.startsWith(u8, arg, "--scope=")) {
            if (!std.mem.eql(u8, arg["--scope=".len..], "remote")) return .usage_error;
            scope_seen = true;
        } else return .usage_error;
    }

    const p = provider orelse return .usage_error;
    if (!scope_seen) return .usage_error;
    const d = dir orelse return .usage_error;
    if (d.len == 0 or d[0] != '/') return .usage_error; // 상대 경로는 cwd 에 끌려간다
    return .{ .run = .{ .action = action, .provider = p, .dir = d } };
}

/// 로컬이 ControlMaster 위에서 실행할 **원격 명령 문자열**([계획](../../docs/plans/remote-agent-state.md)
/// RA3 배선). 이 문자열은 원격 셸이 받으므로 인용 규칙이 전부다.
///
/// ⚠️ **디렉터리는 큰따옴표다.** 작은따옴표로 감싸면 `$HOME` 이 확장되지 않아 원격 maru 가 리터럴
/// `$HOME/...` 이라는 이름의 디렉터리를 만든다 — 그리고 증상은 «훅은 깔렸는데 이벤트가 안 온다» 라
/// 어느 쪽이 틀렸는지 화면에 안 나온다(스트리머 쪽에서 같은 실수를 한 번 했다). 인용을 아예 빼면 홈에
/// 공백이 있는 계정에서 인자가 쪼개진다.
///
/// ⚠️ **`maru` 가 PATH 에 없을 수 있다.** ssh 비대화형 셸의 PATH 는 로그인 셸보다 좁다(실측). 그때는
/// `command -v` 가 실패하고 우리는 **표식을 받아** 그 사실을 안다 — 조용히 «설치했다» 로 넘어가지 않는다.
pub fn remoteShellCommand(
    allocator: std.mem.Allocator,
    action: Action,
    provider_tag: []const u8,
    remote_dir_rel: []const u8,
) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "command -v maru >/dev/null 2>&1 || {{ printf '%s\\n' '{s}'; exit 0; }}; " ++
            "maru agent-hooks {s} --provider={s} --scope=remote --dir=\"$HOME/{s}\"",
        .{ no_maru_marker, @tagName(action), provider_tag, remote_dir_rel },
    );
}

/// 원격에 `maru` 가 없을 때 나가는 표식. **`exit 0` 으로 끝낸다** — 셸이 «명령 없음» 으로 주는 127 은
/// 「연결이 끊겼다」와 구분되지 않기 때문이다(스트리머가 종료 코드를 못 믿는 것과 같은 이유).
pub const no_maru_marker = "!maru-not-installed";

/// 훅 파일 락을 기다리는 시간.
///
/// ⚠️ **경합을 실패로 보고하면 안 된다.** 임계구역은 작은 파일 하나를 다시 쓰는 일(수 ms)인데, 경합
/// 하나로 나가면 호출자는 그것을 «설치 못 했다» 로 읽고 **그 목적지의 축을 영영 안 연다**(다시 안
/// 두드리는 것이 폭주 방지 규칙이라 더 그렇다). 실측: 동시 여섯 중 다섯이 그렇게 나갔다.
///
/// ⚠️ **그렇다고 무한히 기다리면 안 된다.** 락을 쥔 쪽이 멎으면 이 프로세스도 함께 멎고, 그것은
/// 「멎은 tmux 가 채널을 죽였다」와 같은 실패다. 그래서 상한을 둔다 — 넘기면 그때는 진짜 실패다.
pub const lock_wait_ms: u64 = 2_000;

/// 원격 설치 한 번에 줄 수 있는 시간.
///
/// ⚠️ **시한이 없으면 축이 영영 안 열리고 자식이 남는다.** 결과 판정은 «자식이 stdout 을 닫았는가»
/// (EOF)로 하는데, 원격이 안 닫으면 그 조건이 영영 안 온다 — 적대적 원격이 아니어도 `ForceCommand`
/// 서버나 멎은 링크면 그렇다. 그러면 그 목적지는 «설치 중» 에 머물러 채널이 안 열리고, `ssh` 자식은
/// 세션이 끝날 때까지 살아 있다.
///
/// 이미 선 ControlMaster 위의 exec 하나 + 작은 JSON 편집이라 정상이면 1 초 안쪽이다. 15 초는 느린
/// 링크까지 넉넉히 덮고, 그것을 넘겼다면 **포기하는 쪽이 옳다**.
pub const install_deadline_ms: u64 = 15_000;

/// 설치 출력으로 받아 줄 최대 바이트. 넘으면 «우리 줄이 아니다» 로 접는다 — MOTD 가 이만큼 긴 서버는
/// 없고, 있다면 그것은 우리가 아는 서버가 아니다.
pub const install_output_max: usize = 64 * 1024;

/// 원격이 돌려준 한 줄을 읽는다. **`changed` 까지 본다** — 로컬이 «설치가 끝났다» 를 그것으로 판정한다.
pub const Outcome = union(enum) {
    ok: struct { changed: bool },
    /// 원격에 `maru` 가 없다.
    no_maru,
    /// 우리 줄이 아니다(MOTD·rc 잡음, 또는 `ForceCommand` 가 갈아치운 결과).
    unknown,
};

pub fn parseOutcome(out: []const u8) Outcome {
    var lines = std.mem.splitScalar(u8, out, '\n');
    var result: Outcome = .unknown;
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        // **상한 안에서 찾는다**(첫 줄로 판정하지 않는다) — 정상 서버도 MOTD·rc 잡음을 앞에 붙인다.
        if (std.mem.eql(u8, line, no_maru_marker)) return .no_maru;
        if (!std.mem.startsWith(u8, line, "{\"maru-agent-hooks\":1")) continue;
        result = .{ .ok = .{ .changed = std.mem.indexOf(u8, line, "\"changed\":true") != null } };
    }
    return result;
}

pub const usage =
    \\usage: maru agent-hooks install|uninstall --provider=claude|codex --scope=remote --dir=<absolute path>
    \\
    \\Installs (or removes) maru's agent hooks in this machine's provider config.
    \\Run this on the machine where the agent runs; maru on the other side reads the
    \\events over its existing ssh connection.
    \\
;

const testing = std.testing;

test "parseArgs: 계약대로 온 인자만 돈다" {
    const m = parseArgs(&.{ "install", "--provider=claude", "--scope=remote", "--dir=/home/u/.cache/x" });
    try testing.expect(m == .run);
    try testing.expectEqual(Action.install, m.run.action);
    try testing.expectEqual(command.Provider.claude, m.run.provider);
    try testing.expectEqualStrings("/home/u/.cache/x", m.run.dir);

    const u = parseArgs(&.{ "uninstall", "--provider=codex", "--scope=remote", "--dir=/tmp/x" });
    try testing.expectEqual(Action.uninstall, u.run.action);
    try testing.expectEqual(command.Provider.codex, u.run.provider);

    try testing.expect(parseArgs(&.{"--help"}) == .help);
}

test "parseArgs: 빠뜨린 것과 모르는 것은 오류다 — 기본값으로 돌면 남의 파일을 고친다" {
    try testing.expect(parseArgs(&.{}) == .usage_error);
    try testing.expect(parseArgs(&.{"install"}) == .usage_error); // provider·scope·dir 없음
    try testing.expect(parseArgs(&.{ "install", "--provider=claude", "--dir=/x" }) == .usage_error); // scope 없음
    try testing.expect(parseArgs(&.{ "install", "--scope=remote", "--dir=/x" }) == .usage_error); // provider 없음
    try testing.expect(parseArgs(&.{ "install", "--provider=claude", "--scope=remote" }) == .usage_error); // dir 없음
    try testing.expect(parseArgs(&.{ "install", "--provider=gpt", "--scope=remote", "--dir=/x" }) == .usage_error);
    try testing.expect(parseArgs(&.{ "install", "--provider=claude", "--scope=local", "--dir=/x" }) == .usage_error);
    try testing.expect(parseArgs(&.{ "start", "--provider=claude", "--scope=remote", "--dir=/x" }) == .usage_error);
    try testing.expect(parseArgs(&.{ "install", "--provider=claude", "--scope=remote", "--dir=/x", "--force" }) == .usage_error);
}

test "parseArgs: 상대 경로와 빈 경로는 거절한다 — cwd 에 끌려가면 로그가 어디 있는지 모른다" {
    try testing.expect(parseArgs(&.{ "install", "--provider=claude", "--scope=remote", "--dir=" }) == .usage_error);
    try testing.expect(parseArgs(&.{ "install", "--provider=claude", "--scope=remote", "--dir=rel/path" }) == .usage_error);
    try testing.expect(parseArgs(&.{ "install", "--provider=claude", "--scope=remote", "--dir=./x" }) == .usage_error);
}

test "remoteShellCommand: 홈을 원격 셸이 펴게 두고, maru 가 없으면 표식으로 말한다" {
    const a = testing.allocator;
    const cmd = try remoteShellCommand(a, .install, "claude", ".cache/maru/remote-agent-events");
    defer a.free(cmd);

    // 큰따옴표여야 `$HOME` 이 펴진다. 작은따옴표면 리터럴 디렉터리가 생긴다.
    try testing.expect(std.mem.indexOf(u8, cmd, "--dir=\"$HOME/.cache/maru/remote-agent-events\"") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "--dir='") == null);
    try testing.expect(std.mem.indexOf(u8, cmd, "--scope=remote") != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "agent-hooks install") != null);
    // maru 가 없을 때는 **표식을 내고 0 으로 끝난다** — 127 은 연결 끊김과 구분되지 않는다.
    try testing.expect(std.mem.indexOf(u8, cmd, no_maru_marker) != null);
    try testing.expect(std.mem.indexOf(u8, cmd, "exit 0") != null);

    const rm = try remoteShellCommand(a, .uninstall, "codex", "x/y");
    defer a.free(rm);
    try testing.expect(std.mem.indexOf(u8, rm, "agent-hooks uninstall --provider=codex") != null);
}

test "parseOutcome: 잡음 뒤에 온 우리 줄을 찾고, 없으면 모른다고 말한다" {
    try testing.expect(parseOutcome("") == .unknown);
    try testing.expect(parseOutcome("Welcome to Ubuntu\nLast login: ...\n") == .unknown);
    try testing.expect(parseOutcome("motd\n" ++ no_maru_marker ++ "\n") == .no_maru);

    const ok = parseOutcome("motd 한 줄\n{\"maru-agent-hooks\":1,\"provider\":\"claude\",\"action\":\"install\",\"changed\":true}\n");
    try testing.expect(ok == .ok);
    try testing.expect(ok.ok.changed);

    const same = parseOutcome("{\"maru-agent-hooks\":1,\"provider\":\"claude\",\"action\":\"install\",\"changed\":false}\n");
    try testing.expect(same == .ok);
    try testing.expect(!same.ok.changed);
}

test "락 대기 상한은 임계구역보다 훨씬 크고, 무한하지 않다" {
    // 임계구역은 작은 파일 재작성 하나다 — 밀리초 단위. 2 초는 그 수백 배다.
    try testing.expect(lock_wait_ms >= 1_000);
    // 그리고 유한하다 — 락을 쥔 쪽이 멎어도 이 프로세스는 빠져나온다.
    try testing.expect(lock_wait_ms <= 10_000);
}

test "설치 시한은 유한하고, 락 대기보다 넉넉하다" {
    // 락 대기는 설치 안에서 일어난다 — 시한이 그보다 짧으면 정상 경합에서도 못 끝낸다.
    try testing.expect(install_deadline_ms > lock_wait_ms);
    try testing.expect(install_deadline_ms <= 60_000); // 유한하다
}
