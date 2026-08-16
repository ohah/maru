pub const app = @import("app.zig");
pub const chrome = @import("chrome.zig");
pub const cli = @import("cli.zig");
pub const color = @import("color.zig");
pub const config = @import("config.zig");
pub const observability = @import("observability.zig");
pub const plugin = @import("plugin.zig");
pub const pty = @import("pty.zig");
pub const redact = @import("redact.zig"); // 민감정보 redaction 단일 출처(코드) — env·argv·fixture 공용 중립 leaf
pub const renderer = @import("renderer.zig");
pub const session = @import("session.zig");
pub const terminal = @import("terminal.zig");
pub const terminfo_cache = @import("terminfo_cache.zig"); // maru 자체 terminfo 로컬 캐시 단일 출처(pty 자동 컴파일 + cli 서브커맨드 공용)
pub const width = @import("width.zig"); // Unicode 셀 폭(EAW) — 레이어 무관 중립 유틸(terminal·chrome·platform 공용)
pub const grapheme = @import("grapheme.zig"); // UAX#29 grapheme cluster 분절 — 레이어 무관 중립 유틸(terminal·chrome 공용, width.zig와 동격)
pub const path_shape = @import("path_shape.zig"); // 경로 모양(절대·루트·구분자) 판정 — L1 링크 감지와 L2 경로 가드가 공유하는 중립 유틸
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
