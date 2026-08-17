//! 홈 디렉터리를 정하는 **순수 정책**. 환경변수를 읽는 것(I/O)은 `main.zig`가 하고, 여기는 읽어 온 값으로
//! 판정만 한다 — `cli/ssh.zig`·`cli/sessions.zig`가 경로 계산을 순수하게 두는 것과 같은 형태다.
//!
//! **왜 따로 두는가.** `main.zig`가 네 자리에서 `$HOME`을 요구한다(terminfo 캐시·컨트롤 소켓 디렉터리·
//! ssh control path·install 위치). 그 넷이 같은 규칙을 써야 하는데 각자 `getenv("HOME")`을 부르고 있어,
//! Windows 폴백을 넣으려면 네 군데를 따로 고쳐야 했다 — 그러면 규칙이 갈린다.

const std = @import("std");

/// 홈 디렉터리(없으면 null). `home`·`userprofile`은 호출자가 `getenv`로 읽어 넘긴 값이다.
///
/// **⑴ 빈 문자열·상대 경로를 거른다.** `getenv`는 `HOME=`(빈 값)에도 non-null을 준다. 그걸 그대로 쓰면
/// `cacheDirZ`가 `/.cache/maru/terminfo`라는 **드라이브 루트의 엉뚱한 경로**를 만들고 exit 0으로 끝난다
/// (실측: PowerShell에서 `$env:HOME = ""` 뒤 `maru terminfo --path`). 안내하고 멈추는 것보다 나쁘다 —
/// 조용히 틀린 답이기 때문이다. `resolveClickedPath`가 `~/` 확장에서 같은 함정을 같은 방법(절대 경로
/// 검사)으로 이미 막고 있다.
///
/// **⑵ Windows에서는 `%USERPROFILE%`로 폴백한다.** Windows는 `HOME`을 주지 않는다(실측: cmd.exe·
/// PowerShell 둘 다 없음, `USERPROFILE=C:\Users\<user>`는 항상 있음). 그래서 `maru terminfo`가 늘 실패했다.
/// git-bash에서만 되던 이유는 MSYS가 `HOME`을 넣어 주고 네이티브 프로세스를 띄울 때 Win32 형태
/// (`C:\Users\<user>`)로 변환해 주기 때문이다 — 그래서 이 폴백은 **git-bash와 같은 경로로 수렴한다**.
///
/// **`%LOCALAPPDATA%`를 쓰지 않는 이유.** Windows 관례로는 캐시가 거기 가는 것이 맞지만, `cacheDirZ`의
/// 계약이 *"셸 `${XDG_CACHE_HOME:-$HOME/.cache}`와 반드시 같은 경로로 resolve"* 이고 그 셸 명령이 실제로
/// `tic`을 돌려 캐시를 만든다. Zig가 `%LOCALAPPDATA%`를 쓰고 셸이 `$HOME/.cache`를 쓰면 **둘이 갈려 계약이
/// 깨진다.** 같은 규칙을 `cli.sessions.controlDir`와 서버측 `control_socket.controlDirPath`도 공유하므로
/// 셋 + 셸 명령을 한꺼번에 옮겨야 하고, 그러면 git-bash 사용자의 경로가 이사한다. 관례를 따르려면 그것을
/// 별도 슬라이스로 하는 편이 맞다(계약 §8 "홈·캐시 위치").
///
/// `os_tag`가 **인자**인 이유는 다른 OS-인지 술어들과 같다 — CI에 Windows 러너가 없으므로 컴파일 타임
/// 분기였다면 Windows 단언이 공허참이 된다(`path_shape.isDetectableAbsoluteFor` 선례).
pub fn homeDirFor(
    os_tag: std.Target.Os.Tag,
    home: ?[]const u8,
    userprofile: ?[]const u8,
) ?[]const u8 {
    if (usable(os_tag, home)) |h| return h;
    if (os_tag == .windows) {
        if (usable(os_tag, userprofile)) |u| return u;
    }
    return null;
}

/// 값이 홈으로 쓸 만한가 — 있고, 비어 있지 않고, **그 OS 기준 절대 경로**여야 한다.
fn usable(os_tag: std.Target.Os.Tag, value: ?[]const u8) ?[]const u8 {
    const v = value orelse return null;
    if (v.len == 0) return null;
    const absolute = if (os_tag == .windows)
        std.fs.path.isAbsoluteWindows(v)
    else
        std.fs.path.isAbsolutePosix(v);
    return if (absolute) v else null;
}

const testing = std.testing;

test "homeDirFor: 빈 HOME·상대 경로는 홈이 아니다 (조용히 틀린 경로 차단)" {
    const win = std.Target.Os.Tag.windows;
    const mac = std.Target.Os.Tag.macos;

    // 빈 문자열 — `getenv`가 non-null을 주는 함정. 이것을 통과시키면 `/.cache/maru/terminfo`가 된다.
    try testing.expect(homeDirFor(mac, "", null) == null);
    try testing.expect(homeDirFor(win, "", null) == null);
    // 상대 경로도 홈이 아니다.
    try testing.expect(homeDirFor(mac, "relative/path", null) == null);
    try testing.expect(homeDirFor(win, "relative\\path", null) == null);
    // 정상값은 그대로.
    try testing.expectEqualStrings("/Users/me", homeDirFor(mac, "/Users/me", null).?);
    try testing.expectEqualStrings("C:\\Users\\me", homeDirFor(win, "C:\\Users\\me", null).?);
}

test "homeDirFor: USERPROFILE 폴백은 Windows에서만" {
    const win = std.Target.Os.Tag.windows;
    const mac = std.Target.Os.Tag.macos;

    // Windows: HOME이 없으면 USERPROFILE.
    try testing.expectEqualStrings("C:\\Users\\me", homeDirFor(win, null, "C:\\Users\\me").?);
    // Windows: HOME이 **비어 있어도** 폴백한다 — 실제 실패 모양이 이것이다.
    try testing.expectEqualStrings("C:\\Users\\me", homeDirFor(win, "", "C:\\Users\\me").?);
    // HOME이 쓸 만하면 그것이 이긴다(git-bash가 넣어 주는 값 — 폴백과 같은 곳으로 수렴한다).
    try testing.expectEqualStrings("C:\\Users\\gb", homeDirFor(win, "C:\\Users\\gb", "C:\\Users\\me").?);

    // **POSIX에서는 폴백하지 않는다.** 거기서 `USERPROFILE`은 maru가 정의한 적 없는 이름이고, 우연히
    // 설정돼 있으면 사용자가 의도하지 않은 위치에 캐시를 만든다.
    try testing.expect(homeDirFor(mac, null, "/Users/me") == null);
    try testing.expect(homeDirFor(.linux, null, "/home/me") == null);

    // 둘 다 못 쓰면 null — 호출자가 안내하고 멈춘다.
    try testing.expect(homeDirFor(win, null, null) == null);
    try testing.expect(homeDirFor(win, "", "") == null);
}
