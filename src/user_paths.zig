//! 사용자별 경로가 어디에 사는지 정하는 **순수 정책** — 홈·config·캐시 base. 환경변수를 읽는 것(I/O)은
//! 호출자(`main.zig`·`config/loader.zig`)가 하고 여기는 읽어 온 값으로 판정만 한다.
//! `os_tag`를 **인자로** 받아 두 갈래가 모든 타깃에서 테스트된다(CI에 Windows 러너가 없다).
//!
//! **왜 한곳에 모으는가.** 예전에는 소비자마다 `getenv("HOME")`을 따로 불렀다 — terminfo 캐시·컨트롤 소켓
//! 디렉터리·ssh control path·`install-cli` 위치·`trace anonymize` 매칭 키·config 로더. 여섯이 같은 규칙을
//! 써야 하는데 규칙이 여섯 벌이라, Windows 갈래를 넣으려면 여섯 군데를 따로 고쳐야 했다.
//!
//! ## Windows 레이아웃 결정 (계약 §5.3)
//!
//! **Windows에서는 `%LOCALAPPDATA%\maru\` 아래로 모은다** — config·캐시·런타임 전부. 조사한 선례:
//!
//! | 터미널 | Windows config |
//! |---|---|
//! | Warp | `%LOCALAPPDATA%\warp\Warp\config\` (macOS는 `~/.warp/`, Linux는 XDG — **OS마다 그 OS 관례**) |
//! | Alacritty | `%APPDATA%\alacritty\` **만** — `$HOME/.config`를 아예 안 본다 |
//! | Windows Terminal | `%LOCALAPPDATA%\…\LocalState`(MSIX 강제라 선례로 치지 않는다) |
//! | WezTerm | `$HOME/.config/wezterm` — appdata를 **의도적으로 거부**("same configuration layout on multiple operating systems") |
//!
//! 2:1로 플랫폼 네이티브이고 WezTerm이 소수 입장임을 스스로 밝힌다. 결정적인 것은 **웹뷰**다 — WebView2에는
//! WKWebView의 `nonPersistent()` 같은 인메모리 모드가 없어 user data folder(쿠키·IndexedDb·디스크 캐시)를
//! 항상 디스크에 만들고, Microsoft의 Win32 지침이 *"specify the same folder where all other app data is
//! stored"* 다. 즉 maru의 base가 곧 수백 MB짜리 Chromium 프로필 위치가 된다.
//!
//! Roaming(`%APPDATA%`)은 쓰지 않는다 — Warp도 `settings.toml`을 Local에 둔다(창 크기·경로 등 기계별 값이
//! 섞인다). dotfiles로 설정을 옮기는 사용자는 `$MARU_CONFIG`·`$XDG_CACHE_HOME`이 **모든 OS에서 최우선**이라
//! 예전 자리를 그대로 쓸 수 있다.

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
/// **이 함수는 홈만 정한다.** config·캐시가 어디 사는지는 `defaultConfigPathFor`·`cacheBaseFor`가 따로
/// 정하고, Windows에서는 둘 다 `%LOCALAPPDATA%`로 간다(위 모듈 doc). 홈이 여전히 필요한 자리는 셋이다 —
/// `%LOCALAPPDATA%`가 없는 비정상 환경의 폴백, `install-cli`의 `~/.local/bin`(W10이 자리를 정한다),
/// 그리고 `trace anonymize`의 매칭 키.
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

/// 캐시·기계 로컬 데이터의 base(없으면 null → 호출자가 `<home>/.cache`로 폴백한다).
/// `terminfo_cache.cacheDirZ`·`cli.sessions.controlDir`가 받는 `xdg_cache_home` 자리에 그대로 넣는다 —
/// 순수 경로 함수는 손대지 않고 **base만** OS로 가른다.
///
/// 근거는 모듈 doc의 "Windows 레이아웃 결정"에 있다 — 요약하면 선례가 2:1로 플랫폼 네이티브이고,
/// 결정적인 것은 WebView2가 user data folder를 **디스크에 강제**한다는 점이다(maru의 base가 곧 수백 MB
/// Chromium 프로필 위치가 된다).
///
/// `XDG_CACHE_HOME`은 **모든 OS에서 최우선**이다(git-bash·MSYS 사용자의 탈출구, 그리고 셸 관례).
/// POSIX에서는 폴백이 없어 null을 내고, 호출자가 예전대로 `<home>/.cache`로 간다 — **회귀 0**.
pub fn cacheBaseFor(
    os_tag: std.Target.Os.Tag,
    xdg_cache_home: ?[]const u8,
    localappdata: ?[]const u8,
) ?[]const u8 {
    if (xdg_cache_home) |x| {
        if (x.len > 0) return x; // 셸 `${XDG_CACHE_HOME:-...}`와 같은 판정(빈 값은 미설정)
    }
    if (os_tag == .windows) {
        if (usable(os_tag, localappdata)) |l| return l;
    }
    return null; // 호출자가 `<home>/.cache`로 간다
}

/// config 파일의 기본 경로(owned, 없으면 null). `$MARU_CONFIG` 오버라이드는 **호출자가 먼저** 본다.
///
/// POSIX는 예전 그대로 `<home>/.config/maru/config`다. Windows는 `<localappdata>/maru/config`이고,
/// `%LOCALAPPDATA%`가 없는 비정상 환경에서만 POSIX 모양으로 폴백한다(경로가 아예 없는 것보다 낫다).
/// 구분자 정규화는 호출자가 한다(입구 정규화 — 계약 §5).
pub fn defaultConfigPathFor(
    allocator: std.mem.Allocator,
    os_tag: std.Target.Os.Tag,
    home: ?[]const u8,
    localappdata: ?[]const u8,
) std.mem.Allocator.Error!?[]u8 {
    if (os_tag == .windows) {
        if (usable(os_tag, localappdata)) |l|
            return try std.fmt.allocPrint(allocator, "{s}/maru/config", .{trimSep(l)});
    }
    const h = homeDirFor(os_tag, home, localappdata) orelse return null;
    return try std.fmt.allocPrint(allocator, "{s}/.config/maru/config", .{trimSep(h)});
}

/// 후행 구분자 하나를 뗀다(이중 슬래시 방지). 루트(`/`·`C:/`)는 떼면 상대 경로가 되므로 남긴다 —
/// `path_shape.trimTrailingSep`와 같은 규칙이고, 여기서는 그 함수를 그대로 쓴다.
fn trimSep(p: []const u8) []const u8 {
    return @import("path_shape.zig").trimTrailingSep(p);
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

test "cacheBaseFor: XDG가 모든 OS에서 최우선, %LOCALAPPDATA%는 Windows에서만" {
    const win = std.Target.Os.Tag.windows;
    const mac = std.Target.Os.Tag.macos;
    const local = "C:\\Users\\me\\AppData\\Local";

    // Windows 기본 — `<base>/maru/...`가 붙으므로 결과는 `%LOCALAPPDATA%\maru\terminfo` 꼴이 된다.
    try testing.expectEqualStrings(local, cacheBaseFor(win, null, local).?);
    try testing.expectEqualStrings(local, cacheBaseFor(win, "", local).?); // 빈 XDG = 미설정(셸 `:-`와 동일)

    // XDG는 **모든 OS에서** 이긴다 — git-bash·MSYS 사용자의 탈출구다.
    try testing.expectEqualStrings("D:/xdg", cacheBaseFor(win, "D:/xdg", local).?);
    try testing.expectEqualStrings("/tmp/xdg", cacheBaseFor(mac, "/tmp/xdg", null).?);

    // POSIX는 폴백이 없다 → null이면 호출자가 `<home>/.cache`로 간다(예전 동작 그대로, 회귀 0).
    try testing.expect(cacheBaseFor(mac, null, local) == null);
    try testing.expect(cacheBaseFor(.linux, null, "/anything") == null);
    // Windows라도 `%LOCALAPPDATA%`가 쓸 수 없으면 홈 폴백으로 내려간다.
    try testing.expect(cacheBaseFor(win, null, "") == null);
    try testing.expect(cacheBaseFor(win, null, "relative\\path") == null);
}

test "defaultConfigPathFor: Windows는 %LOCALAPPDATA%, POSIX는 회귀 0" {
    const a = std.testing.allocator;
    const win = std.Target.Os.Tag.windows;
    const mac = std.Target.Os.Tag.macos;

    // POSIX — **예전 그대로**여야 한다. 이 줄이 회귀 0의 계약이다.
    for ([_]std.Target.Os.Tag{ mac, .linux }) |os| {
        const p = (try defaultConfigPathFor(a, os, "/Users/me", null)).?;
        defer a.free(p);
        try testing.expectEqualStrings("/Users/me/.config/maru/config", p);
    }
    // POSIX에서 `LOCALAPPDATA`가 우연히 있어도 무시한다.
    {
        const p = (try defaultConfigPathFor(a, mac, "/Users/me", "C:\\x")).?;
        defer a.free(p);
        try testing.expectEqualStrings("/Users/me/.config/maru/config", p);
    }

    // Windows — `%LOCALAPPDATA%\maru\config`.
    {
        const p = (try defaultConfigPathFor(a, win, null, "C:\\Users\\me\\AppData\\Local")).?;
        defer a.free(p);
        try testing.expectEqualStrings("C:\\Users\\me\\AppData\\Local/maru/config", p);
    }
    // 후행 구분자가 이중이 되지 않는다.
    {
        const p = (try defaultConfigPathFor(a, win, null, "C:/Local/")).?;
        defer a.free(p);
        try testing.expectEqualStrings("C:/Local/maru/config", p);
    }
    // Windows인데 `%LOCALAPPDATA%`가 없으면 홈 모양으로 폴백한다 — 경로가 아예 없는 것보다 낫다.
    {
        const p = (try defaultConfigPathFor(a, win, "C:\\Users\\me", null)).?;
        defer a.free(p);
        try testing.expectEqualStrings("C:\\Users\\me/.config/maru/config", p);
    }
    // 둘 다 없으면 null(설정 없이 기본값).
    try testing.expect((try defaultConfigPathFor(a, win, null, null)) == null);
    try testing.expect((try defaultConfigPathFor(a, mac, "", null)) == null);
}
