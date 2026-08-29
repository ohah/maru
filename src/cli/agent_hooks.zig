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
