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

test {
    @import("std").testing.refAllDecls(@This());
}
