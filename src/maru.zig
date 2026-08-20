pub const app = @import("app.zig");
pub const chrome = @import("chrome.zig");
pub const user_paths = @import("user_paths.zig"); // 사용자별 경로 정책(홈·config·캐시 base) — OS를 인자로 받는 순수 판정
pub const cli = @import("cli.zig");
pub const color = @import("color.zig");
pub const config = @import("config.zig");
pub const observability = @import("observability.zig");
pub const plugin = @import("plugin.zig");
pub const pty = @import("pty.zig");
pub const win32_process = @import("platform/windows/win32_process.zig"); // Windows 캡처 러너. **배럴에 거는 이유는 모듈 경로다** — 이것을 쓰는 `git_backend.zig` 가 모듈 루트가 `platform/macos` 안인 아티팩트에서도 컴파일되는데, 상대 경로로 가져오면 그때 모듈 밖이 되어 깨진다(실측: macOS CI)
pub const redact = @import("redact.zig"); // 민감정보 redaction 단일 출처(코드) — env·argv·fixture 공용 중립 leaf
pub const renderer = @import("renderer.zig");
pub const session = @import("session.zig");
pub const terminal = @import("terminal.zig");
pub const terminfo_cache = @import("terminfo_cache.zig"); // maru 자체 terminfo 로컬 캐시 단일 출처(pty 자동 컴파일 + cli 서브커맨드 공용)
pub const width = @import("width.zig"); // Unicode 셀 폭(EAW) — 레이어 무관 중립 유틸(terminal·chrome·platform 공용)
pub const grapheme = @import("grapheme.zig"); // UAX#29 grapheme cluster 분절 — 레이어 무관 중립 유틸(terminal·chrome 공용, width.zig와 동격)
pub const path_shape = @import("path_shape.zig"); // 경로 모양(절대·루트·구분자) 판정 — L1 링크 감지와 L2 경로 가드가 공유하는 중립 유틸
pub const os_env = @import("os_env.zig"); // 환경변수를 UTF-8 로 읽는다 — Windows 의 ANSI `getenv` 를 피한다
pub const hazard = @import("hazard.zig"); // §3.8 적대적 입력 판정 — 순수 유니코드(width.zig와 동격, chrome도 쓴다)
pub const display_width = @import("display_width.zig"); // §4.2 편집기 표시 폭 — 열 계산(L3)과 셀 배치(L4)의 단일 출처
pub const icons = @import("icons.zig"); // 등록 chrome 아이콘의 semantic 이름↔PUA codepoint(생성물) — 레이어 무관 중립 leaf(chrome·renderer·platform 공용)
pub const i18n = @import("i18n.zig"); // UI 표시 문자열의 언어별 테이블·조회·보간 — 레이어 무관 중립 leaf(docs/i18n.md 계약, chrome·session·config·platform 공용)

test {
    @import("std").testing.refAllDecls(@This());
}

// `config.theme.WindowsShell`(사용자가 고르는 값)과 `pty.types.WindowsShellKind`(티어를 고르는 스위치)는
// **같은 집합이어야 하는데 일부러 다른 모듈에 있다** — 중립 pty 레이어가 config를 import하지 않게 하려는
// 것이다(값 전달은 호출자 몫). 대가는 조용히 갈릴 수 있다는 것이라, 둘을 함께 보는 유일한 자리인 여기서
// 못 박는다. 한쪽에만 변형을 추가하면 이 테스트가 깨진다.
test "WindowsShell(config)과 WindowsShellKind(pty)는 같은 변형 집합이다" {
    const std = @import("std");
    const a = @typeInfo(config.theme.WindowsShell).@"enum".fields;
    const b = @typeInfo(pty.types.WindowsShellKind).@"enum".fields;
    try std.testing.expectEqual(a.len, b.len);
    inline for (a, b) |fa, fb| try std.testing.expectEqualStrings(fa.name, fb.name);
}

/// 사용자가 고른 `config.theme.WindowsShell`을 중립 pty의 `WindowsShellKind`로 옮긴다. 두 타입이 함께
/// 보이는 자리가 여기뿐이라(위 테스트의 근거와 같다) 변환도 여기 둔다 — 진입점마다 `switch`를 복사하면
/// 변형이 늘 때 한 곳만 고쳐진다.
///
/// **`@enumFromInt`로 적지 않는다.** 위 테스트가 이름과 순서를 못 박지만, 그것이 깨졌을 때
/// `@enumFromInt`는 **조용히 다른 셸을 띄운다**. 명시 `switch`는 변형이 늘면 컴파일이 멈춘다.
pub fn windowsShellKindOf(shell: config.theme.WindowsShell) pty.WindowsShellKind {
    return switch (shell) {
        .pwsh => .pwsh,
        .powershell => .powershell,
        .cmd => .cmd,
    };
}

test "windowsShellKindOf: 모든 변형이 같은 이름으로 옮겨진다" {
    const std = @import("std");
    inline for (@typeInfo(config.theme.WindowsShell).@"enum".fields) |f| {
        const got = windowsShellKindOf(@field(config.theme.WindowsShell, f.name));
        try std.testing.expectEqualStrings(f.name, @tagName(got));
    }
}
