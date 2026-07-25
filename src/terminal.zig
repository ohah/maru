pub const core = @import("terminal/core.zig");
pub const input = @import("terminal/input.zig");
pub const types = @import("terminal/types.zig");
pub const png = @import("terminal/png.zig"); // PNG 디코드(kitty f=100·window.background-image F2-1)
pub const preedit = @import("terminal/preedit.zig"); // local/host-backed 공통 client-local IME marked-text 합성
pub const selection = @import("terminal/selection.zig"); // 링크 자동 감지 분류(LinkScopes/LinkKind — docs/link-detection.md)

/// OSC 52 클립보드 쓰기 디코드 상한(바이트). platform이 거부 notice 문구에 쓴다(단일 출처 — osc.zig).
pub const clipboard_max_bytes = @import("terminal/osc.zig").max_clipboard_bytes;
/// 붙여넣기 인코딩의 **순수** 변형(bracketed 여부만 값으로 받는다). app이 `core_mutex` 아래에서 그 bool만 읽고
/// 인코딩(할당 + payload 복사)은 락 밖에서 하도록 노출한다 — 멀티MB paste를 코어 뮤텍스 안에서 인코딩하면
/// 그 pane의 PTY reader가 그동안 막힌다(app_session.submitPaste 주석). 코어 상태를 안 만지므로 파사드 안전.
pub const encodePasteWith = @import("terminal/input_report.zig").encodePasteWith;
pub const pasteNeedsConfirmationWith = @import("terminal/input_report.zig").pasteNeedsConfirmationWith;
// Unicode 셀 폭(EAW)은 순수·레이어 무관이라 top-level 중립 유틸(src/width.zig)로 옮겼다 — terminal·platform·
// chrome이 모두 쓴다(색=color.zig와 같은 선례). 여기선 호환 re-export만 한다(terminal.width/cellWidth 그대로).
pub const width = @import("width.zig");

pub const Cell = types.Cell;
pub const isTextTrimBlank = types.isTextTrimBlank;
pub const textTrimmedLen = types.textTrimmedLen;
pub const Color = types.Color;
pub const Cursor = types.Cursor;
pub const CursorShape = types.CursorShape;
/// 마우스 트래킹 모드(DECSET 1000/1002/1003). host-backed 세션에서 관측이 이 모드를 실어 보내고 platform이
/// 클릭(`!= .none`)·motion(`== .any`) 게이트를 각각 판정한다 — bool로 뭉개면 1003을 가를 수 없다.
pub const MouseTracking = core.MouseTracking;
pub const SelectionPoint = types.SelectionPoint;
pub const SelectionSpan = types.SelectionSpan;
// 링크 자동 감지(URL·파일 경로) 타입 — platform(app_session)이 config 범위를 scopes로 빌드해 core로 넘긴다.
pub const LinkKind = selection.LinkKind;
pub const LinkScopes = selection.LinkScopes;
// 원격(host-backed) 세션에서 host가 계산해 client에 실어 보내는 뷰포트 링크 — scope는 client가 자기 config로
// 거르는 근거다(docs/link-detection.md §원격(host-backed) 세션).
pub const LinkScope = selection.LinkScope;
pub const ViewportLink = selection.ViewportLink;
pub const ExtractedLink = selection.ExtractedLink;
pub const link_scopes_none = selection.link_scopes_none;
pub const link_scopes_web = selection.link_scopes_web;
pub const link_scopes_full = selection.link_scopes_full;
pub const Match = types.Match;
pub const DirtyRegion = types.DirtyRegion;
pub const Key = input.Key;
pub const KeyEvent = input.KeyEvent;
pub const ModifierSet = input.ModifierSet;
pub const RenderSnapshot = types.RenderSnapshot;
pub const KittyPlacement = types.KittyPlacement;
pub const KittyImageView = types.KittyImageView;
pub const PlacementGeometry = types.PlacementGeometry;
pub const PreeditOverlay = preedit.Overlay;
pub const RowCodepoints = types.RowCodepoints;
pub const SemanticPrompt = types.SemanticPrompt;
pub const RowPrompt = types.RowPrompt;
pub const Rgb = types.Rgb;
pub const Size = types.Size;
pub const Style = types.Style;
pub const TerminalCore = core.TerminalCore;
pub const clampGridSize = core.clampGridSize;
pub const cellWidth = width.cellWidth;

test {
    // Aggregate this layer's child-file tests into the build. refAllDecls is
    // shallow and does not recurse through the maru barrel, so without this
    // block the unit tests in terminal/* never compile into `zig build test`.
    @import("std").testing.refAllDecls(@This());
}
