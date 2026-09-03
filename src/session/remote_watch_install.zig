//! **원격 감시자 설치 계약**(RW2a — [계획](../../docs/plans/remote-watch.md) §4).
//!
//! `maru ssh` 가 terminfo 를 심는 것과 **같은 3 박자**다: 있으면 끝 · 못 하면 실패 · maru 전용
//! 디렉터리에만 쓴다(`cli/ssh.zig` 의 `remote_install`). 다른 점은 페이로드가 텍스트가 아니라
//! **작은 정적 바이너리**라는 것뿐이라, 아키텍처 판별이 하나 더 붙는다.
//!
//! **여기는 순수 계층이다** — 명령을 만들고 출력을 해석할 뿐 실행하지 않는다. 실행은 L4 가 control
//! socket 위에서 한다(RW2b·RW3).

const std = @import("std");

/// 원격에 심는 자리. **maru 전용 디렉터리다** — `~/.zshrc` 같은 사용자 파일은 안 건드린다
/// ([ssh-integration.md §9.5](../../docs/ssh-integration.md)).
pub const remote_dir = "$HOME/.cache/maru";

/// 감시자가 `--version` 으로 내는 줄. **이 문자열이 곧 「우리 것이고 이 판이다」** 다.
/// `tools/remote-watch/main.zig` 의 `version_line` 과 같아야 한다 — 경계 test 가 그것을 센다.
pub const version_line = "maru-remote-watch 1";

/// 원격에 놓일 파일 이름. **판을 이름에 박는다** — 안 그러면 옛 판이 깔린 원격에서 새 maru 가
/// 「이미 있다」로 읽고 조용히 옛 감시자를 쓴다.
pub const remote_binary = "maru-remote-watch-1";

/// ⑴ **이미 있고 «돌아가는가»**. 파일 존재만 보면 아키텍처가 틀린 바이너리나 잘린 파일을 「설치됨」
/// 으로 읽는다 — 그러면 감시가 조용히 안 된다. **실행해 보는 것**이 그 둘을 함께 가른다.
///
/// 성공(exit 0)이면 설치를 건너뛴다. 그러면 200 KB 를 매번 실어 보내지 않는다.
pub const check_script = remote_dir ++ "/" ++ remote_binary ++ " --version 2>/dev/null";

/// ⑵ **stdin 으로 온 바이트를 심는다.** `remote_install` 과 같은 자리에서 같은 이유로 실패한다.
///
/// - `mkdir -p` 가 실패하면 그대로 죽는다(홈이 읽기 전용인 원격 등) — 호출자는 현행 동작을 유지한다.
/// - **임시 이름에 받고 `mv` 로 바꾼다.** 중간에 채널이 끊기면 반쪽 파일이 남는데, 그것을 최종
///   이름으로 두면 다음 실행이 「있다」로 읽고 **깨진 것을 돌린다.**
/// - `chmod 755` 는 `mv` **전에** 한다 — 최종 이름이 보이는 순간 이미 실행 가능해야 경쟁이 없다.
pub const install_script =
    "d=\"" ++ remote_dir ++ "\"; " ++
    "mkdir -p \"$d\" || exit 1; " ++
    "cat > \"$d/" ++ remote_binary ++ ".tmp\" || exit 1; " ++
    "chmod 755 \"$d/" ++ remote_binary ++ ".tmp\" || exit 1; " ++
    "mv -f \"$d/" ++ remote_binary ++ ".tmp\" \"$d/" ++ remote_binary ++ "\" || exit 1";

/// 우리가 실어 보낼 수 있는 원격. **모르면 없다** — 추측해서 엉뚱한 바이너리를 심으면 그 원격은
/// 「설치는 됐는데 안 도는」 상태가 되고, 그 편이 안 하느니만 못하다.
pub const Variant = enum {
    linux_x86_64,
    linux_aarch64,
    macos_x86_64,
    macos_aarch64,

    pub fn assetName(self: Variant) []const u8 {
        return switch (self) {
            .linux_x86_64 => "linux-x86_64",
            .linux_aarch64 => "linux-aarch64",
            .macos_x86_64 => "macos-x86_64",
            .macos_aarch64 => "macos-aarch64",
        };
    }
};

/// `uname -sm` 출력을 변종으로 옮긴다. 모르면 `null` — 호출자는 **설치를 안 하고** 현행 동작을 둔다.
///
/// ⚠️ **FreeBSD 는 `null` 이다.** kqueue 는 거기서도 돌지만 우리가 만드는 것은 Mach-O(macOS) 라
/// 안 돈다. 「kqueue 를 쓰니 같은 것」으로 묶으면 그 원격에 **안 도는 바이너리**를 심게 된다.
pub fn variantFromUname(uname_sm: []const u8) ?Variant {
    const trimmed = std.mem.trim(u8, uname_sm, " \t\r\n");
    var it = std.mem.tokenizeAny(u8, trimmed, " \t");
    const os = it.next() orelse return null;
    const arch = it.next() orelse return null;
    if (it.next() != null) return null; // `uname -sm` 은 토큰 둘이다 — 더 오면 우리가 모르는 형식이다

    if (std.mem.eql(u8, os, "Linux")) {
        if (std.mem.eql(u8, arch, "x86_64")) return .linux_x86_64;
        if (std.mem.eql(u8, arch, "aarch64") or std.mem.eql(u8, arch, "arm64")) return .linux_aarch64;
        return null;
    }
    if (std.mem.eql(u8, os, "Darwin")) {
        if (std.mem.eql(u8, arch, "x86_64")) return .macos_x86_64;
        if (std.mem.eql(u8, arch, "arm64") or std.mem.eql(u8, arch, "aarch64")) return .macos_aarch64;
        return null;
    }
    return null;
}

/// `--version` 출력이 **우리 것이고 이 판인가**. 앞뒤 공백만 털고 정확히 대조한다 — 부분 일치로
/// 보면 판이 올라간 원격을 「같다」로 읽는다.
pub fn versionMatches(stdout: []const u8) bool {
    return std.mem.eql(u8, std.mem.trim(u8, stdout, " \t\r\n"), version_line);
}

const testing = std.testing;

test "uname -sm 을 변종으로 옮긴다 — 모르면 null 이다" {
    try testing.expectEqual(Variant.linux_x86_64, variantFromUname("Linux x86_64").?);
    try testing.expectEqual(Variant.linux_aarch64, variantFromUname("Linux aarch64").?);
    try testing.expectEqual(Variant.macos_aarch64, variantFromUname("Darwin arm64\n").?);
    try testing.expectEqual(Variant.macos_x86_64, variantFromUname("  Darwin x86_64  ").?);
    // **FreeBSD 는 kqueue 를 쓰지만 우리 바이너리는 Mach-O 다** — 묶으면 안 도는 것을 심는다.
    try testing.expect(variantFromUname("FreeBSD amd64") == null);
    try testing.expect(variantFromUname("Linux riscv64") == null);
    try testing.expect(variantFromUname("Linux") == null);
    try testing.expect(variantFromUname("") == null);
    // 토큰이 셋이면 우리가 아는 형식이 아니다 — 추측하지 않는다.
    try testing.expect(variantFromUname("Linux x86_64 extra") == null);
}

test "판 대조는 정확 일치다 — 부분 일치면 옛 판을 «같다»로 읽는다" {
    try testing.expect(versionMatches("maru-remote-watch 1\n"));
    try testing.expect(versionMatches("  maru-remote-watch 1  "));
    try testing.expect(!versionMatches("maru-remote-watch 12"));
    try testing.expect(!versionMatches("maru-remote-watch 2"));
    try testing.expect(!versionMatches(""));
    try testing.expect(!versionMatches("bash: maru-remote-watch: not found"));
}

test "설치 스크립트는 임시 이름에 받고 옮긴다 — 반쪽 파일을 최종 이름에 두지 않는다" {
    // 채널이 중간에 끊기면 반쪽이 남는데, 그것이 최종 이름이면 다음 실행이 **깨진 것을 돌린다.**
    try testing.expect(std.mem.indexOf(u8, install_script, ".tmp\"") != null);
    try testing.expect(std.mem.indexOf(u8, install_script, "mv -f") != null);
    // `chmod` 는 `mv` **앞**이어야 한다 — 최종 이름이 보이는 순간 이미 실행 가능해야 한다.
    const chmod_at = std.mem.indexOf(u8, install_script, "chmod").?;
    const mv_at = std.mem.indexOf(u8, install_script, "mv -f").?;
    try testing.expect(chmod_at < mv_at);
    // 실패하면 **그대로 죽는다** — 조용히 이어 가면 반쪽 상태가 남는다.
    try testing.expectEqual(@as(usize, 4), std.mem.count(u8, install_script, "|| exit 1"));
    // 사용자 파일은 안 건드린다.
    try testing.expect(std.mem.indexOf(u8, install_script, ".zshrc") == null);
    try testing.expect(std.mem.startsWith(u8, remote_dir, "$HOME/.cache/maru"));
}
