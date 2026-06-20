const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const app = maru.app;
const chrome = maru.chrome;
const config_mod = maru.config;
const renderer = maru.renderer;
const terminal = maru.terminal;

// L2 session core(src/session)로 추출한 순수 입력/재정렬 수학. 내부 호출처는 bare 이름을 유지하도록 file-scope
// alias로 재노출한다(docs/layering-and-portability.md §3 — 2차 추출 슬라이스 1). 정의·테스트는 session/input_math.zig.
// (maru.session을 별칭으로 잡지 않는다 — 테스트들이 'session'을 지역 변수로 쓴다.)
const input_math = maru.session.input_math;
const adjustActiveForMove = input_math.adjustActiveForMove;
const rotateMove = input_math.rotateMove;
const reselectAfterClose = input_math.reselectAfterClose;
const clampMoveToGroup = input_math.clampMoveToGroup;
const wheelDeltaToLines = input_math.wheelDeltaToLines;
const pageScrollDelta = input_math.pageScrollDelta;
// IME 순수 판정도 session core로 추출(src/session/ime.zig). bare 호출(imeEnd) 유지용 alias.
const imeDecide = maru.session.ime.decide;
const coretext_bridge = @import("coretext_smoke_bridge.zig");
const coretext_frame_builder = @import("coretext_frame_builder.zig");
const agent_session = @import("agent_session.zig"); // L4 — 에이전트 세션 트랜스크립트 파일 찾기 + tail read
const metal_frame = renderer.metal_frame; // §8: metal_frame이 renderer로 이주 — maru.renderer barrel 경유(중립 frame DTO)
const shell_integration = @import("shell_integration.zig");
const global_hotkey = @import("global_hotkey.zig");
const command_catalog = @import("command_catalog.zig");
const command_palette = @import("command_palette.zig");
// find 오버레이는 chrome 컴포넌트(maru.chrome.components.find)로 이주(C1a). UI 상태(query/current/count)는
// chrome_host.find가, 매치 리스트(terminal.Match)는 session(find_matches)이 소유한다 — chrome은 terminal 무참조.

// SplitTree를 leaf = `*Pane`으로 인스턴스화한다(트리는 panel 단위). app 레이어는 generic만 노출하고 Pane은
// 이 platform 모듈이 정의하므로, 트리가 panel을 leaf로 들면서도 app→platform 의존이 생기지 않는다. 탭→pane
// 모델: 한 leaf(Pane)가 여러 Term(터미널)을 가로 탭으로 들고, 화면엔 활성 Term의 surface를 그린다.
const PaneTree = app.SplitTree(*Pane);

// Metal DTO·view·owned 버퍼는 순수 모듈 metal_frame이 소유한다. ABI 표면으로 re-export만 한다.
pub const MetalCell = metal_frame.NativeMetalCell;
pub const MetalRasterUpload = metal_frame.NativeMetalRasterUpload;
pub const MetalFrame = metal_frame.MetalFrame;
pub const MetalGpuQuad = metal_frame.GpuQuad;
pub const MetalGpuShadow = metal_frame.GpuShadow;
pub const MetalGpuImage = metal_frame.GpuImage;
pub const MetalGpuImageUpload = metal_frame.GpuImageUpload;

pub const abi_version: u32 = 62; // 62: MetalFrame.sidebar_header_height_px(사이드바 상단 헤더 — 검색바·view options·새 워크스페이스 아이콘 — 높이; 렌더러가 사이드바 셀 밴드·카드 glyph를 이만큼 아래로 민다). 61: serialize_sidebar_config(view options 사이드바 토글 show-branch/show-folder → config 파일 부분 갱신 저장, 주석 보존; 앱↔config 양방향). 60: reset_input_modes(Reset 메뉴 ⌘⇧R — ssh 비정상 종료 후 잔류 입력 모드 focus 1004·mouse·kitty keyboard만 끄는 비파괴 리셋; 셸 통합 precmd 자동 리셋의 수동 백업 경로). 59: mouse_moved(버튼 없는 hover 이동 → mouse reporting; DECSET 1003 any-event일 때만 Zig가 SGR/x10 motion 리포트, click/wheel과 같은 reportMouse 경로). 58: send_text 제거 — 드래그 삽입을 paste 경로(pasteText→encodePaste; DECSET 2004 켜졌을 때만 bracketed)로 되돌림. Ghostty도 드래그를 completeClipboardPaste로 보내 TUI가 2004를 켜면 bracketed paste라 경로를 한-덩어리([Image])로 인식한다 — v57에서 직접 입력으로 바꾼 게 Ghostty와 어긋나 그 인식이 깨졌던 것을 정정. 57: send_text 도입(드래그 직접 입력 — v58에서 되돌림). 56: reload_config/reset_defaults(Reload Config·Reset to Defaults 메뉴 — 재시작 없이 config 파일 재로드, 런타임 줌·여백을 처음 설정으로 복원). 55: SessionConfig.width_px/height_px/scale_milli(셸을 처음부터 실제 창 크기로 spawn — 80×24→resize 핸드셰이크/zsh PROMPT_EOL_MARK % 잔상 제거). 54: config_path(Open Config 메뉴 — config 파일 경로 노출, Swift가 열기). 53: take_bell(G12 BEL → 시스템 벨 NSSound.beep). 52: pending_notification(OSC 9/777 데스크톱 알림 drain — VT 갭 G2e platform wiring). 51: MetalFrame.terminal_bg(OSC 11 배경 set → 화면 clear color — VT 갭 G2d). 50: pending_clipboard(OSC 52 클립보드 쓰기 drain — VT 갭 G2b platform wiring). 49: MetalFrame.live_image_ids(kitty graphics K4c 텍스처 eviction). 48: MetalFrame.gpu_images/image_uploads/image_pixels(kitty graphics K2 이미지 렌더 채널). 47: KeyEvent.base_codepoint(kitty CSI u base-layout key). 46: mouse.button/mods(mouse reporting — 8b). 45: focus_changed(DECSET 1004 focus reporting → CSI I/O). 44: scroll_wheel.delta_x(트랙패드 가로 → 탭 바 스크롤). 43: MetalFrame.modal_cells_start(모달 over quad 경계 — C4b 모달). 42: GpuQuad.layer. 41: gpu_quads/gpu_shadows. 40: show_notice
pub const default_queue_capacity: u32 = 16;

/// 전역(OS) 단축키 한 개의 OS 등록 기술자(C ABI). Swift가 `maru_macos_app_session_global_hotkeys`로
/// 받아 Carbon `RegisterEventHotKey(carbon_modifiers, virtual_key_code)`로 등록하고, 눌리면 action을
/// 수행한다. action은 `config.GlobalAction`의 `@intFromEnum`(0=toggle_window, 1=show_window)이다.
/// 매핑 가능한 chord만 담긴다(global_hotkey.descriptorFor가 null이면 그 바인딩은 제외). 순수 POD.
pub const GlobalHotkey = extern struct {
    virtual_key_code: u32,
    carbon_modifiers: u32,
    action: u32,
};

/// quick terminal 표시 옵션(C ABI). Swift가 `maru_macos_app_session_quick_terminal_config`로 받아
/// 패널 크기·화면·자동 숨김에 쓴다. height_milli = 화면 높이 대비 비율×1000(예: 450=45%). auto_hide
/// 0/1. screen = `config.QuickTerminalScreen`의 `@intFromEnum`(0=main, 1=mouse). 순수 POD.
pub const QuickTerminalConfig = extern struct {
    height_milli: u32,
    auto_hide: u32,
    screen: u32,
    position: u32, // config.QuickTerminalPosition의 @intFromEnum(0=top, 1=bottom, 2=left, 3=right, 4=center)
    chrome: u32, // config.QuickTerminalChrome의 @intFromEnum(0=full, 1=minimal). Swift가 quick 세션 생성 시 chrome_minimal로 넘긴다.
    minimal_tabs: u32, // 0/1 — minimal에서 탭 허용 여부. Swift가 quick 세션 생성 시 SessionConfig.minimal_tabs로 넘긴다.
    width_milli: u32, // center 가로 비율 × 1000. 0이면 미설정 → Swift가 height로 폴백(정사각). center 외 위치는 무시.
};

/// 커맨드 카탈로그 한 항목(C ABI) — 메뉴바·커맨드 팝업이 그릴 액션. 모든 문자열은 app session 소유(arena,
/// destroy까지 유효). `action_key`는 Swift가 선택 시 `run_action`으로 되돌려보내는 식별자(= parseAction 문자열),
/// `title`은 표시명, `key_display`는 현재 바인딩(없으면 빈 문자열). global_hotkeys처럼 세션 동안 불변·한 번 빌드.
pub const CommandEntry = extern struct {
    action_key: [*:0]const u8,
    title: [*:0]const u8,
    key_display: [*:0]const u8, // 팝업/표시용 사람-읽는 chord("⌘T"), 없으면 ""
    key_equivalent: [*:0]const u8, // NSMenuItem.keyEquivalent 문자열(소문자 글자/화살표 unichar), 없으면 ""
    key_modifiers: u32, // command_catalog.mod_* 비트마스크(shift=1,control=2,option=4,command=8). Swift가 NSEvent flags로 매핑.
};

/// 마우스 호버 위치에 따라 Swift가 세울 커서 종류(`maru_macos_app_session_hover`의 out 값). Zig가 위치를
/// 판정(터미널/divider/사이드바/탭 바/URL)하고 Swift가 NSCursor로 매핑한다 — 전부 I-beam이던 걸 영역별로 바꾼다.
pub const CursorKind = enum(i32) {
    default = 0, // arrow — 사이드바·pane 탭 바 등 chrome(텍스트 입력/리사이즈 아님)
    text = 1, // iBeam — 터미널 영역(pane 안, 바 아래)
    link = 2, // pointingHand — Cmd+hover URL
    resize_h = 3, // resizeLeftRight ↔ — 세로 divider(좌우 split, 좌우로 끈다)
    resize_v = 4, // resizeUpDown ↕ — 가로 divider(상하 split, 위아래로 끈다)
};

// cell 메트릭이 아직 없을 때(이론상 init 전) grid 계산에 쓰는 placeholder cell 픽셀 크기.
// 실제로는 init이 refreshCellMetrics를 부르므로 resize 시점엔 항상 실제 메트릭이 있다.
const placeholder_cell_width_px: u32 = 12;
const placeholder_cell_height_px = input_math.placeholder_cell_height_px; // session core 단일 출처(휠 환산과 공유)

// 세로 탭 사이드바의 기본 논리 폭(pt). backing 픽셀 폭은 scale을 곱해 구한다(refreshCellMetrics에서).
// 터미널 surface는 이 폭만큼 오른쪽으로 그려지고, 왼쪽 strip이 사이드바다("surface→rect" 첫 적용). 사용자가
// 우측 경계를 드래그해 바꾸면 `AppSession.sidebar_width_pt`(현재 폭, pt)가 [min,max]로 갱신된다 — pt로 들어
// DPI 변경(refreshCellMetrics)에도 살아남는다.
const default_sidebar_width_pt: u32 = 180;
const sidebar_min_pt: u32 = 120; // 너무 좁으면 제목/✕가 안 보임
const sidebar_max_pt: u32 = 480; // 너무 넓으면 터미널이 좁아짐

// 사이드바 탭 슬롯 한 칸의 높이를 cell 높이의 몇 배로 할지(천분율). 4600 = 4.6× — 최대 4줄 카드(이름·브랜치·
// 경로·상태, 각 1×cell = 4×cell)를 위아래 여백 두고 담을 큰 슬롯. 1~3줄 탭도 같은 슬롯에 블록 세로 중앙(빈 줄
// 없음). 에이전트 상태줄(4번째)을 추가하며 3.8×→4.6×로 키웠다. refreshCellMetrics가 cell_height_px × 이
// 비율로 backing 픽셀 슬롯 높이를 구한다.
const sidebar_slot_height_ratio_milli: u32 = 4600;
// 사이드바 상단 헤더(검색바 + view options·새 워크스페이스 아이콘) 높이 = cell 높이 × 2.0(검색 1줄 + 상하 패딩).
// 0이면 헤더 없음(하위호환). slot_height와 같은 단일 출처(cell 메트릭)에서 파생한다.
const sidebar_header_height_ratio_milli: u32 = 3000;

// 런타임 폰트 크기 조절(⌘+/⌘-/⌘0). step = ⌘+/⌘- 한 번에 1pt(Ghostty 기본과 동일). 클램프 범위는 보수적으로
// [6, 72]pt — appearance resolver는 [1,512]를 허용하지만 6pt 미만은 글자가 안 읽히고 72pt 초과는 grid가
// 1~2칸으로 무너져 런타임 단축키 UX로는 부적절하다(config 파일로는 그 밖 값도 가능, 단축키만 이 범위).
// ⌘+/⌘- 증분(step)은 config `font.size-step`(appearance.font.size_step, 기본 1pt)이 정한다.
const font_size_min: f32 = 6.0;
const font_size_max: f32 = 72.0;

// 스크롤바 thumb 폭(굵기). cell_width의 비율, 최소 px 보장. hover/드래그면 +emphasize_px로 살짝 굵게(affordance).
const scrollbar_bar_mul: f32 = 0.5; // cell_width 대비 폭 비율(굵게 — 잡기/보기 쉽게)
const scrollbar_bar_min_px: f32 = 7.0; // 작은 폰트에서도 최소 두께
const scrollbar_bar_emphasize_px: f32 = 2.0; // hover/드래그 시 추가 폭
// fade(자동 흐려짐) — 스크롤(view_offset 변화) 후 visible_ticks 동안 full, 이어 fade_ticks 동안 idle(faint)로
// 흐려진다(30Hz tick). 숨기지 않고 faint로만 남겨(위치·잡을 곳을 잃지 않게) macOS overlay 관례를 따른다.
const scrollbar_visible_ticks: u32 = 50; // ~1.7s full 유지
const scrollbar_fade_ticks: u32 = 14; // ~0.45s 동안 full→faint
const scrollbar_alpha_full: u8 = 0xFF; // 활성/hover/드래그
const scrollbar_alpha_idle: u8 = 0x4D; // idle(faint) — ~30%

// 커서 깜빡임 반주기(30Hz tick 단위). 15틱 = 500ms — 일반 터미널 관례(on 500ms / off 500ms). 틱이 고정 30Hz라
// 정확히 500ms다. ms 기반 위상·config 노출·deadline 스케줄러는 문서화된 시간-모델 후속(docs/layering §5).
const blink_interval_ticks: u32 = 15;
const agent_poll_interval_ticks: u32 = 15; // ≈0.5s@30Hz — 포그라운드 프로세스(에이전트) polling 주기.
// 에이전트 마지막 답변 미리보기를 담는 Term inline 버퍼 크기(바이트). 한 줄 미리보기라 충분하고, 사이드바가
// 카드 폭으로 다시 말줄임하므로 여기선 넉넉히만 잡는다(UTF-8 경계로 잘려 들어옴).
const agent_answer_max: usize = 192;
// synchronized output(DECSET 2026) ESU-유실 복구 deadline. 30틱 = 1초(고정 30Hz). BSU(2026h) 후 ESU(2026l)가
// 영영 안 오면(앱 크래시·SSH 끊김·버그) frame 투영이 무한정 막혀 화면이 freeze되므로, 이 한도를 넘는 hold는
// sync를 강제 해제하고 투영한다. 베이스: ESU-유실 안전장치(Ghostty termio sync_reset_ms=1000·xterm.js
// SYNCHRONIZED_OUTPUT_TIMEOUT_MS=1000과 같은 1초 timeout) — 정상 ESU 흐름엔 영향 없다.
const sync_timeout_ticks: u32 = 30;

// 복원(R4)에서 모델 surface의 저장된 cols/rows를 spawn 초기 grid로 쓴다(0이면 terminal.Size.default 기본).
// 실제 grid는 복원 직후 resize/레이아웃이 창·split에 맞게 보정하므로, 이 초기값은 spawn winsize일 뿐이다.
fn restoreSurfaceSize(sm: app.workspace.Surface) terminal.Size {
    return terminal.clampGridSize(.{
        .cols = if (sm.cols > 0) sm.cols else terminal.Size.default.cols,
        .rows = if (sm.rows > 0) sm.rows else terminal.Size.default.rows,
    });
}

// 복원 시 저장된 cwd를 spawn에 쓸지 결정한다(R6 "없는 cwd graceful"). 존재하는 절대-경로 디렉터리일 때만 그
// cwd를, 아니면(빈값·상대경로·없음·파일·권한 없음) null을 돌려준다 — null이면 기본 cwd로 spawn해 surface를 잃지
// 않는다. cwd 자식 chdir 실패는 _exit(126)이라(pty/macos childExec), 미리 확인 안 하면 복원된 셸이 즉시 죽어
// 다음 tick에 reap된다. workspace-restore.md "실패 처리": 한 surface가 어긋나도 나머지(와 그 surface)를 살린다.
fn usableRestoreCwd(cwd: []const u8) ?[]const u8 {
    // 잘 형성된 **절대 경로**만 spawn cwd로 넘긴다(빈값·상대경로·과도 길이는 거른다 — 상대경로를 넘기면 자식이
    // 앱 cwd 기준으로 chdir해 예측 불가). 존재·디렉터리 여부는 더 이상 여기서 추측하지 않는다: childExec가 chdir
    // 실패 시 $HOME으로 graceful 폴백하므로(없는 cwd·TOCTOU·파일 경로를 단일 권위로 처리), 여기선 형식만 본다.
    // 이전의 후행-슬래시 access 존재 검사는 검사~spawn 사이 dir이 사라지는 TOCTOU에 취약한 밴드라 제거했다.
    if (cwd.len == 0 or cwd.len >= std.fs.max_path_bytes or !std.fs.path.isAbsolute(cwd)) return null;
    return cwd;
}

fn isHexStr(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return s.len > 0;
}

/// `.git/HEAD` 내용에서 브랜치명을 뽑는 순수 파서(입력 슬라이스 참조 반환 — 할당 없음). `ref: refs/heads/<branch>`면
/// branch, detached(raw SHA ≥7 hex)면 짧게 7자, 그 외(빈 ref·쓰레기)면 null. readGitBranch가 fs 읽은 뒤 호출·dupe.
fn parseGitHead(content: []const u8) ?[]const u8 {
    const trimmed = std.mem.trim(u8, content, &std.ascii.whitespace);
    const ref_prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, trimmed, ref_prefix)) {
        const branch = trimmed[ref_prefix.len..];
        return if (branch.len == 0) null else branch;
    }
    return if (isHexStr(trimmed) and trimmed.len >= 7) trimmed[0..7] else null;
}

/// cwd(OSC 7 보고)에서 부모로 올라가며 `<dir>/.git/HEAD`를 찾아 git 브랜치명을 도출한다(owned 슬라이스, 호출자 해제).
/// `ref: refs/heads/<branch>`면 그 branch, detached(raw SHA)면 짧게 7자. 못 찾으면 null(브랜치 표시 없음).
/// 절대 경로만, walk-up은 루트까지(깊이 128 가드). 베이스: git이 cwd부터 부모로 .git을 찾는 방식. worktree(.git가
/// gitdir: 파일)는 best-effort 미지원(.git/HEAD 못 읽으면 null) — 후속. fs 읽기는 cwd 변경 시에만(termGitBranch 캐시).
fn readGitBranch(io: std.Io, allocator: std.mem.Allocator, cwd: []const u8) ?[]const u8 {
    if (cwd.len == 0 or cwd.len >= std.fs.max_path_bytes or !std.fs.path.isAbsolute(cwd)) return null;
    var dir: []const u8 = cwd;
    var depth: usize = 0;
    while (depth < 128) : (depth += 1) {
        var buf: [std.fs.max_path_bytes]u8 = undefined;
        const head_path = std.fmt.bufPrint(&buf, "{s}/.git/HEAD", .{dir}) catch return null;
        if (std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(4096))) |data| {
            defer allocator.free(data);
            // .git/HEAD가 있으니 이미 repo 안 — 파싱 결과가 null이어도 더 올라가지 않는다.
            return if (parseGitHead(data)) |b| (allocator.dupe(u8, b) catch null) else null;
        } else |_| {}
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (parent.len >= dir.len) return null; // 진전 없음(루트 도달)
        dir = parent;
    }
    return null;
}

/// 사이드바 경로줄(2줄 카드 아래줄)용 cwd 문자열(owned). $HOME 접두는 "~"로 축약한다(예: /Users/x/p → ~/p).
/// cwd가 비면 "". 파생값(영속 안 함) — 매 프레임 빌드라 owned 슬라이스를 호출부가 바로 해제한다.
fn sidebarCwdPath(allocator: std.mem.Allocator, term: *Term) ![]const u8 {
    const cwd = term.surface.core.currentCwd();
    if (cwd.len == 0) return allocator.dupe(u8, "");
    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    // $HOME 정확 경계(home 자체 또는 home/ 하위)일 때만 "~"로 — "/Users/xyz"가 "/Users/x"로 잘못 잡히지 않게.
    if (home.len > 0 and std.mem.startsWith(u8, cwd, home) and (cwd.len == home.len or cwd[home.len] == '/'))
        return std.fmt.allocPrint(allocator, "~{s}", .{cwd[home.len..]});
    return allocator.dupe(u8, cwd);
}

/// 터미널 셀↔컨테이너 가장자리 4방 inset(backing px). 비대칭 window padding을 한 단위로 전달한다 —
/// gridFromBacking이 left+right·top+bottom을 grid에서 빼고, paneTermRect가 좌상으로 left/top만큼 들인다.
const PaddingPx = struct { left: u32 = 0, right: u32 = 0, top: u32 = 0, bottom: u32 = 0 };

/// backing 픽셀 크기와 cell 픽셀 크기로 터미널 grid(cols/rows)를 구한다. cell 크기가 0이면
/// placeholder로 대체하고, u16 상한으로 막은 뒤 terminal.clampGridSize로 최소 크기(cols>=2)를
/// 적용한다 — cols>=2 불변식은 TerminalCore가 단일 소유하므로 여기서 직접 하드코딩하지 않는다.
fn gridFromBacking(backing_width_px: u32, backing_height_px: u32, cell_width_px: u32, cell_height_px: u32, sidebar_width_px: u32, padding: PaddingPx) terminal.Size {
    const cell_w = if (cell_width_px > 0) cell_width_px else placeholder_cell_width_px;
    const cell_h = if (cell_height_px > 0) cell_height_px else placeholder_cell_height_px;
    // 터미널 영역 = drawable − 세로 사이드바 폭 − 좌우 padding(left+right) − 상하 padding(top+bottom).
    // 사이드바/패딩이 drawable보다 큰 비정상 상황은 0으로 saturate(언더플로 방지)해 clampGridSize가 최소 grid로
    // 떨어뜨린다. termRect도 같은 양을 들이므로 spawn grid와 실제 pane grid가 정합한다(PR8 spawn-크기 레이스 회피).
    const term_width = backing_width_px -| sidebar_width_px -| padding.left -| padding.right;
    const term_height = backing_height_px -| padding.top -| padding.bottom;
    const raw_cols = @min(term_width / cell_w, std.math.maxInt(u16));
    const raw_rows = @min(term_height / cell_h, std.math.maxInt(u16));
    return terminal.clampGridSize(.{ .cols = @intCast(raw_cols), .rows = @intCast(raw_rows) });
}

/// 사이드바를 이미 뺀 sub-사각형(panel leaf rect)의 픽셀 폭/높이로 grid를 구한다. `gridFromBacking`과
/// 같은 cell/clamp 규칙이되 사이드바를 빼지 않는다(rect가 이미 터미널 영역 내부) — split된 panel을 자기
/// leaf rect grid로 resize할 때 쓴다. 단일 leaf(rect.w = backing − sidebar)면 gridFromBacking과 동일.
fn gridFromRectPx(cell_width_px: u32, cell_height_px: u32, w_px: u32, h_px: u32) terminal.Size {
    const cell_w = if (cell_width_px > 0) cell_width_px else placeholder_cell_width_px;
    const cell_h = if (cell_height_px > 0) cell_height_px else placeholder_cell_height_px;
    const raw_cols = @min(w_px / cell_w, std.math.maxInt(u16));
    const raw_rows = @min(h_px / cell_h, std.math.maxInt(u16));
    return terminal.clampGridSize(.{ .cols = @intCast(raw_cols), .rows = @intCast(raw_rows) });
}

/// 논리 pt → backing 정수 px(분수 scale milli, ×scale_milli/1000). sidebar 폭·window padding 4방 같은 정수
/// pt 환산의 단일 출처다(letter-spacing의 f32 경로는 분수 정밀이 필요해 applyFontSpacing이 별도로 처리한다).
fn ptToPx(pt: u32, scale_milli: u32) u32 {
    return pt * scale_milli / 1000;
}

/// font.line-height(배수)·font.letter-spacing(논리 pt)을 base cell px에 적용한다(refreshCellMetrics의 단일
/// 적용점이 호출하는 순수 helper — OS·CoreText 없이 곱/가산 산술을 단위 테스트로 못박는다). line-height는
/// cell_height_px에 곱하고, letter-spacing은 논리 pt를 backing px(× scale_milli/1000, padding px 환산과 동형)로
/// 바꿔 cell_width_px에 가산한다(음수 가능 → 최소 1px로 saturate해 0폭 grid를 막는다). 두 px가 grid·atlas·
/// hit-test의 진실 소스라, 여기 한 곳만 바꾸면 나머지가 자동 정합한다. 기본값(1.0/0.0)이면 입력 그대로 통과.
fn applyFontSpacing(
    base_width_px: u32,
    base_height_px: u32,
    line_height: f32,
    letter_spacing_pt: f32,
    scale_milli: u32,
) struct { width_px: u32, height_px: u32 } {
    const height_px: u32 = @intFromFloat(@round(@as(f32, @floatFromInt(base_height_px)) * line_height));
    // 논리 pt → backing px(분수 scale 그대로). padding px 환산(× scale_milli / 1000)과 같은 방식.
    const spacing_px: f32 = letter_spacing_pt * @as(f32, @floatFromInt(scale_milli)) / 1000.0;
    // i64로 가산해(음수 spacing) 1px 미만이면 1로 saturate — 0폭이면 grid가 div-by-cell에서 폭주한다.
    const width_i: i64 = @as(i64, base_width_px) + @as(i64, @intFromFloat(@round(spacing_px)));
    const width_px: u32 = @intCast(@max(@as(i64, 1), width_i));
    return .{ .width_px = width_px, .height_px = height_px };
}

/// color.Rgb를 불투명(A=0xFF) 0xAARRGGBB로 packing한다(사이드바 strip/활성 밴드 셀 배경 색용). 셀
/// 배경은 A=0xFF여야 셰이더가 그 색으로 칠한다(A=0이면 "배경 없음").
/// rgb + alpha를 GpuQuad/cell 색 워드(0xAARRGGBB)로 패킹. 색 패킹의 단일 출처 — packOpaqueRgb·스크롤바 fade가 공유.
fn packRgbAlpha(rgb: maru.color.Rgb, alpha: u8) u32 {
    return (@as(u32, alpha) << 24) | (@as(u32, rgb.r) << 16) | (@as(u32, rgb.g) << 8) | rgb.b;
}

fn packOpaqueRgb(rgb: maru.color.Rgb) u32 {
    return packRgbAlpha(rgb, 0xFF);
}

/// 활성 탭 하이라이트 밴드 셀 1개를 만든다(못 만들면 null). 사이드바 폭을 cell 폭으로 floor해 칸 수
/// (sidebar_cols)를 구하고 — 밴드가 origin_x를 넘어 터미널 영역을 침범하지 않게 floor한다(우측에 한 칸
/// 미만 여백이 살짝 inset처럼 남는다) — 그 폭만큼 한 칸(col 0, width=sidebar_cols)으로 사이드바를 채우는
/// sentinel-UV(-1) 배경 셀을 active_row에 둔다. u16 width 상한도 같이 막는다. 순수 함수라 OS와 무관하게
/// 단위 테스트한다(rebuildSidebar가 호출). 사이드바가 꺼졌거나(폭 0) cell 폭 미상이면 null.
fn sidebarBandCell(sidebar_width_px: u32, cell_width_px: u32, active_row: u16, active_bg: u32) ?metal_frame.NativeMetalCell {
    if (sidebar_width_px == 0 or cell_width_px == 0) return null;
    const cols_u32 = @min(sidebar_width_px / cell_width_px, @as(u32, std.math.maxInt(u16)));
    const sidebar_cols: u16 = @intCast(cols_u32);
    if (sidebar_cols == 0) return null;
    return .{
        .row = active_row,
        .col = 0,
        .width = sidebar_cols,
        .codepoint = ' ',
        .slot_id = 0,
        .atlas_x_px = 0,
        .atlas_y_px = 0,
        .atlas_width_px = 0,
        .atlas_height_px = 0,
        .u0 = -1.0,
        .v0 = -1.0,
        .u1 = -1.0,
        .v1 = -1.0,
        .foreground = 0,
        .background = active_bg,
    };
}

/// sentinel-UV(아틀라스 없음 — u/v=-1로 셰이더가 글리프 샘플 대신 배경만 칠함) chrome 셀 1개. pane 탭 바
/// 배경·활성 탭 하이라이트가 공유하는 보일러플레이트(16개 필드)를 한 곳에 모은다. origin_x + col*cw,
/// origin_y(row 0)에 width칸을 bg로 채운다. 순수 함수.
fn sentinelBgCell(col: u16, width: u16, bg: u32, origin_x: u32, origin_y: u32) metal_frame.NativeMetalCell {
    return .{
        .row = 0,
        .col = col,
        .width = width,
        .codepoint = ' ',
        .slot_id = 0,
        .atlas_x_px = 0,
        .atlas_y_px = 0,
        .atlas_width_px = 0,
        .atlas_height_px = 0,
        .u0 = -1.0,
        .v0 = -1.0,
        .u1 = -1.0,
        .v1 = -1.0,
        .foreground = 0,
        .background = bg,
        .origin_x = origin_x,
        .origin_y = origin_y,
    };
}

/// pane 탭 바 배경 셀 1개(sentinel-UV, 배경만). bar rect 좌상단 origin에서 폭(cols)만큼 채운다 — 터미널 셀
/// 스트림에 넣으면 maru_fill_cell_quad가 origin_x + col*cw, origin_y + row*ch(row 0)에 그려 바를 칠한다. 폭이
/// term 폭과 같은 cols(floor)라 아래 터미널과 가로 정렬된다. 셀 폭/바 폭·높이 0이면 null. 순수 함수.
fn paneBarBgCell(bar: app.SplitRect, cell_width_px: u32, bg: u32) ?metal_frame.NativeMetalCell {
    if (cell_width_px == 0 or bar.w == 0 or bar.h == 0) return null;
    const cols_u32 = @min(bar.w / cell_width_px, @as(u32, std.math.maxInt(u16)));
    if (cols_u32 == 0) return null;
    return sentinelBgCell(0, @intCast(cols_u32), bg, bar.x, bar.y);
}

// putUtf8/appendPaletteRow(레거시 팝업 텍스트 레이아웃)는 제거했다 — 팝업이 chrome 컴포넌트로 이주(C1b)해
// rasterizeOverlayCells의 placeText(EAW-폭)를 find와 공유한다. 코드포인트당 1칸 깔던 putUtf8이 한글을 자르던 원인.

/// 점(backing px)이 사각형 안인가([x, x+w) × [y, y+h) 반열린). 탭 바 클릭 hit-test에 쓴다. 비유한은 false.
fn pointInRect(x_px: f64, y_px: f64, rect: app.SplitRect) bool {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return false;
    const x0: f64 = @floatFromInt(rect.x);
    const y0: f64 = @floatFromInt(rect.y);
    return x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(rect.w)) and
        y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(rect.h));
}

/// 드래그한 Term을 다른 pane '본문'에 떨어뜨릴 때의 가장자리 절반(④ split 재배치). left/right=좌우 split,
/// top/bottom=상하 split.
const PaneDropZone = enum { left, right, top, bottom };

/// 탭 드래그 중 드롭 타겟(④b 하이라이트·④ 커밋 공유 판정). `pane`은 마우스가 올라간 대상 pane, `zone`이 null이면
/// 그 pane 탭 바(드롭 시 Term 이동, PR-E2), set이면 본문 절반(그 방향으로 새 split, ④).
const DropTarget = struct { pane: *Pane, zone: ?PaneDropZone };

/// rect를 zone 방향 절반으로 자른다(④b 하이라이트가 그 절반을 칠한다). left/right=좌우, top/bottom=상하.
fn halfRect(rect: app.SplitRect, zone: PaneDropZone) app.SplitRect {
    return switch (zone) {
        .left => .{ .x = rect.x, .y = rect.y, .w = rect.w / 2, .h = rect.h },
        .right => .{ .x = rect.x + rect.w / 2, .y = rect.y, .w = rect.w - rect.w / 2, .h = rect.h },
        .top => .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = rect.h / 2 },
        .bottom => .{ .x = rect.x, .y = rect.y + rect.h / 2, .w = rect.w, .h = rect.h - rect.h / 2 },
    };
}

/// 0xAARRGGBB 색을 alpha로 **premultiply**한다(rgb를 alpha/255로 곱하고 alpha를 A로). 렌더러가 premultiplied-
/// alpha over로 블렌딩하므로(maru_metal_shader), 반투명 하이라이트는 이렇게 미리 곱해 넘겨야 색이 안 뜬다. 순수.
fn premultipliedRgba(rgb: u32, alpha: u8) u32 {
    const a: u32 = alpha;
    const r = (((rgb >> 16) & 0xFF) * a) / 255;
    const g = (((rgb >> 8) & 0xFF) * a) / 255;
    const b = ((rgb & 0xFF) * a) / 255;
    return (a << 24) | (r << 16) | (g << 8) | b;
}

/// per-tab 배경색(우클릭 "배경: …") tint 세기 — rich gpu_quad·tui 밴드 두 경로 단일 출처. 0xB0 ≈ 69%
/// (0x66 ≈ 40%에서 올림 — 옅어서 안 보인다는 라이브 요청). 0=투명, 0xFF=완전 불투명.
const tab_bg_tint_alpha: u8 = 0xB0;

/// base(0xAARRGGBB)의 RGB를 tint_rgb(0xRRGGBB) 쪽으로 alpha/255만큼 lerp한다(base의 알파 보존). 사이드바 밴드에
/// per-tab 배경 tint를 섞어, tui 기본 테마의 불투명 활성/호버 밴드가 tint quad를 덮어도 활성 슬롯에서 색이 보이게 한다.
fn blendRgb(base: u32, tint_rgb: u32, alpha: u8) u32 {
    const a: u32 = alpha;
    const inv: u32 = 255 - a;
    const r = ((((base >> 16) & 0xFF) * inv) + (((tint_rgb >> 16) & 0xFF) * a)) / 255;
    const g = ((((base >> 8) & 0xFF) * inv) + (((tint_rgb >> 8) & 0xFF) * a)) / 255;
    const b = (((base & 0xFF) * inv) + ((tint_rgb & 0xFF) * a)) / 255;
    return (base & 0xFF00_0000) | (r << 16) | (g << 8) | b;
}

/// 탭/워크스페이스 라벨 "{n} {title}"(n=1-based 번호). 사이드바 워크스페이스·pane Term 탭이 공유해 번호 prefix
/// 형식이 일관된다(둘 다 1부터). 호출자가 반환 버퍼를 free한다. allocPrint 래퍼.
fn tabNumberLabel(allocator: std.mem.Allocator, index: usize, title: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{d} {s}", .{ index + 1, title });
}

/// Term(가로 탭) 표시 라벨 — 사용자 rename(surface.custom_name)이 있으면 그것, 없으면 자동 제목.
/// 자동 제목은 **라이브 OSC 0/2 창 제목**(없으면 cwd basename)을 반영해 사이드바·탭바가 현재 실행 중인 프로그램
/// (Claude Code 등 OSC 제목을 설정하는 TUI)의 제목을 실시간 보인다. 단 그 값(`core.windowTitle()` 반환 슬라이스 =
/// core.title/cwd)은 reader 스레드가 OSC 0/2/7로 free+realloc하므로 렌더 스레드가 직접 읽으면 use-after-free다 —
/// `syncAutoTitles`가 매 tick core_mutex 하에 owned 복사본(`term.auto_title`)으로 캐시하고, termLabel은 그 캐시만
/// 읽는다(io-render-threading PR3). 캐시가 비면(첫 sync 전·빈 제목) 정적 `surface.title`로 폴백. 베이스: Ghostty 탭
/// 제목도 OSC 제목 우선·없으면 cwd basename(동작 비교).
/// 사이드바 워크스페이스 라벨·pane 탭바가 공유하는 단일 해석(app.pickLabel). 반환은 borrowed(custom_name=세션 소유,
/// auto_title=메인 스레드 소유 캐시, surface.title=정적) — 모두 reader 스레드가 안 건드려 렌더 중 안정. 호출자가 즉시 복사.
fn termLabel(term: *const Term) []const u8 {
    const auto = if (term.auto_title.items.len > 0) term.auto_title.items else term.surface.title;
    return app.pickLabel(term.surface.custom_name, auto);
}

/// 워크스페이스(사이드바 탭) 표시 라벨 — 탭 custom_name 우선, 없으면 활성 Term 라벨로 폴백(워크스페이스는 자동
/// 제목 출처가 없어 활성 Term을 대표로 빌린다 — 기존 동작과 동일하되 사용자 rename이 우선한다).
fn workspaceLabel(tab: *Tab) []const u8 {
    return app.pickLabel(tab.custom_name, termLabel(tab.activeTerm()));
}

/// 점이 rect 안 어느 drop zone인지 — rect를 중앙에서 X자로 4등분해 가장 가까운 가장자리를 고른다(좌/우/상/하).
/// rect 밖·0 크기·비유한이면 null. 렌더 drop-zone 하이라이트(후속 ④b)와 공유할 순수 함수라 OS 무관 단위 테스트.
fn paneDropZone(rect: app.SplitRect, x_px: f64, y_px: f64) ?PaneDropZone {
    if (rect.w == 0 or rect.h == 0 or !pointInRect(x_px, y_px, rect)) return null;
    const fx = (x_px - @as(f64, @floatFromInt(rect.x))) / @as(f64, @floatFromInt(rect.w)); // [0,1)
    const fy = (y_px - @as(f64, @floatFromInt(rect.y))) / @as(f64, @floatFromInt(rect.h));
    const dx = @min(fx, 1 - fx); // 좌/우 가장자리까지의 거리(작을수록 가깝다)
    const dy = @min(fy, 1 - fy); // 상/하 가장자리까지의 거리
    if (dx <= dy) return if (fx < 0.5) .left else .right;
    return if (fy < 0.5) .top else .bottom;
}

/// pane 탭 바 컬럼 분할 메트릭(중립 `tabbar.Metrics`)을 만든다(옛 BarMetrics.init). 렌더(buildPaneTabBarDrawList·활성
/// 밴드)와 hit-test(chrome `tabbar.tabIndex/inCloseZone/inPlusZone`)가 같은 메트릭을 공유해 "보이는 탭/✕/+ == 클릭되는
/// 것". coretext의 paneTabAreaCols/paneTabWidth(렌더가 쓰는 같은 공식)로 바를 [탭 영역 | "+" zone]으로 나눈다. cell·바·
/// 탭 폭이 0이면(초소형 바) null을 줘 호출자가 탭 처리를 건너뛴다. hit-test 수학은 chrome tabbar로 이전(C3b) — platform은
/// 메트릭 빌드 + 활성 밴드 단일 셀(tabbarHighlightCell)만(밴드가 한 칸이라 chrome view→cell round-trip이 무의미; 리뷰 §3).
fn barMetrics(bar: app.SplitRect, cell_width_px: u32, term_count: usize, tab_width_fixed: u16, scroll_cols: u32) ?chrome.components.tabbar.Metrics {
    if (cell_width_px == 0 or bar.w == 0 or term_count == 0) return null;
    const cols = @min(bar.w / cell_width_px, @as(u32, std.math.maxInt(u16)));
    if (cols == 0) return null;
    // 탭 레이아웃 단일 소스(§6) — buildPaneTabBarDrawList(렌더)와 같은 tabLayout이라 보이는 탭/‹›/+ == 클릭.
    // scroll_cols는 tabLayout이 [0,max] clamp한 eff_scroll로 정규화(#1: stale 방지). hit-test·렌더가 같은 eff를 쓴다.
    const layout = coretext_frame_builder.tabLayout(@intCast(cols), term_count, tab_width_fixed, scroll_cols);
    if (layout.tab_w == 0) return null;
    return .{ .bar_x = bar.x, .bar_y = bar.y, .bar_w = bar.w, .bar_h = bar.h, .cell_width_px = cell_width_px, .cols = cols, .tab_cols = layout.tab_cols, .tab_w = layout.tab_w, .scroll_cols = layout.eff_scroll, .has_scroll = layout.has_scroll };
}

/// 활성 Term 탭 세그먼트를 강조 배경 셀로 칠한다(옛 BarMetrics.highlightCell). chrome tabbar hit-test와 **같은
/// tabbar.segOf 셀 경계**(start_col/end_col)라 활성 밴드가 제목 glyph·클릭·✕와 정확히 정렬된다(§6 단일 소스).
/// overflow(탭 영역 밖, end_col<=start_col)면 null.
fn tabbarHighlightCell(m: chrome.components.tabbar.Metrics, tab_index: usize, bg: u32) ?metal_frame.NativeMetalCell {
    const seg = m.segOf(tab_index);
    if (seg.end_col <= seg.start_col) return null; // overflow(탭 영역 밖, 안 보이는) 탭
    return sentinelBgCell(@intCast(seg.start_col), @intCast(seg.end_col - seg.start_col), bg, m.bar_x, m.bar_y);
}

/// 스크린 점(backing px)을 담는 panel(없으면 null). split 탭에서 마우스 클릭이 어느 panel에 떨어졌는지
/// hit-test한다 — 각 leaf rect는 [x, x+w) × [y, y+h) 반열린 구간으로 본다(경계는 다음 panel에). 비유한
/// 좌표는 null. 순수 함수라 OS 무관 단위 테스트한다(레이아웃 rect만 입력).
fn paneAtPoint(leaf_rects: []const PaneTree.LeafRect, x_px: f64, y_px: f64) ?*Pane {
    if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
    for (leaf_rects) |lr| {
        const x0: f64 = @floatFromInt(lr.rect.x);
        const y0: f64 = @floatFromInt(lr.rect.y);
        if (x_px >= x0 and x_px < x0 + @as(f64, @floatFromInt(lr.rect.w)) and
            y_px >= y0 and y_px < y0 + @as(f64, @floatFromInt(lr.rect.h)))
        {
            return lr.leaf;
        }
    }
    return null;
}

/// 키보드 pane 이동 방향(좌/우/상/하). split 탭에서 활성 panel 기준 인접 panel을 고른다.
const FocusDirection = enum { left, right, up, down };

/// 활성 panel(active_pane)에서 direction 방향으로 가장 가까운 인접 panel(없으면 null). 각 panel rect의
/// '중심'을 비교해 — 방향 반평면 안(left면 중심 x가 더 작음 등)인 후보 중, 주축 거리(이동 방향) + 부축
/// 어긋남×2(정렬 페널티)가 최소인 것을 고른다. 좌우 split이면 상/하는 후보가 없어 null(이동 안 함), 격자
/// 배치면 같은 행/열의 정렬된 panel을 우선한다. 순수 함수라 OS 무관 단위 테스트한다(레이아웃 rect만 입력).
fn paneInDirection(leaf_rects: []const PaneTree.LeafRect, active_pane: *Pane, dir: FocusDirection) ?*Pane {
    var active_rect: ?app.SplitRect = null;
    for (leaf_rects) |lr| {
        if (lr.leaf == active_pane) {
            active_rect = lr.rect;
            break;
        }
    }
    const ar = active_rect orelse return null;
    const acx = @as(f64, @floatFromInt(ar.x)) + @as(f64, @floatFromInt(ar.w)) / 2.0;
    const acy = @as(f64, @floatFromInt(ar.y)) + @as(f64, @floatFromInt(ar.h)) / 2.0;
    var best: ?*Pane = null;
    var best_score: f64 = std.math.inf(f64);
    for (leaf_rects) |lr| {
        if (lr.leaf == active_pane) continue;
        const cx = @as(f64, @floatFromInt(lr.rect.x)) + @as(f64, @floatFromInt(lr.rect.w)) / 2.0;
        const cy = @as(f64, @floatFromInt(lr.rect.y)) + @as(f64, @floatFromInt(lr.rect.h)) / 2.0;
        const dx = cx - acx;
        const dy = cy - acy;
        const in_dir = switch (dir) {
            .left => dx < 0,
            .right => dx > 0,
            .up => dy < 0,
            .down => dy > 0,
        };
        if (!in_dir) continue;
        const primary: f64 = switch (dir) {
            .left, .right => @abs(dx),
            .up, .down => @abs(dy),
        };
        const secondary: f64 = switch (dir) {
            .left, .right => @abs(dy),
            .up, .down => @abs(dx),
        };
        const score = primary + 2.0 * secondary; // 부축 정렬(같은 행/열)을 우대
        if (score < best_score) {
            best_score = score;
            best = lr.leaf;
        }
    }
    return best;
}

// adjustActiveForMove·rotateMove·reselectAfterClose·wheelDeltaToLines는 session core로 추출됐다 — 위 file-scope
// alias(input_math.*)로 bare 이름 그대로 호출한다. 정의·단위 테스트는 src/session/input_math.zig.

// 화면 상태 진단 logger. MARU_DEBUG일 때 frame build마다 TerminalCore의 cell 격자(cursor 위치 +
// 줄별 텍스트/배경)를 찍어, "개행 안 되고 덮어씀" 같은 cursor/scroll 동작을 데이터로 확인한다.
// MARU_DEBUG 게이트는 diag.zig가 단일 출처로 소유한다.
const screen_diag = std.log.scoped(.screen);
// 셸 의미 이벤트(OSC 133/7) 진단 logger. MARU_DEBUG일 때 frame마다 core가 기록한 명령 경계
// 이벤트를 구조화 한 줄씩 찍는다 — 같은 도메인 데이터를 테스트·후속 trace writer도 이 자리에서
// drain한다(관측 가능성 원칙). 게이트는 diag.zig 단일 출처.
const shell_diag = std.log.scoped(.shell);
const diag_gate = @import("diag.zig");

// app_host_abi.zig가 이 파일을 import하므로 EventKind는 여기서 정의하고 거기서 re-export한다
// (순환 import 회피). FrameSummary.last_event_kind가 이 값을 그대로 싣는다.
pub const EventKind = enum(u32) {
    none = 0,
    frame_tick = 1,
    key_down = 2,
    resize = 3,
    close_requested = 4,
    app_should_terminate = 5,
};

pub const CommandKind = enum(u32) {
    controlled_smoke = 0,
    interactive_shell = 1,
};

pub const SessionConfig = extern struct {
    abi_version: u32,
    cols: u32,
    rows: u32,
    queue_capacity: u32,
    command_kind: u32,
    // 1이면 chrome 최소화(사이드바·pane 탭 바 없이 터미널만) — quick terminal minimal 모드용. 0=full(메인 창).
    // Swift가 세션 생성 시 세션별로 정한다.
    chrome_minimal: u32 = 0,
    // 1이면 chrome_minimal 세션에서도 탭(워크스페이스·Term) 생성을 허용한다. 0이면 minimal은 단일 스크래치
    // (⌘T/⌘⇧T 무동작). chrome_minimal=0(full)이면 이 값과 무관하게 탭이 항상 동작한다. Swift가 quick 세션에만 정한다.
    minimal_tabs: u32 = 0,
    // 첫 셸 spawn 크기 결정용 창 backing 픽셀 + scale(둘 다 >0이면 init이 cell 메트릭으로 grid를 계산해 PTY를
    // **처음부터 실제 창 크기로** 띄운다 — 80×24 기본 spawn 후 resize하는 핸드셰이크/레이스를 없애 zsh의 첫 프롬프트
    // PROMPT_EOL_MARK(%) 잔상을 막는다). 0이면(헤드리스 테스트 등) cols/rows로 폴백. Swift가 창에서 채운다.
    width_px: u32 = 0,
    height_px: u32 = 0,
    scale_milli: u32 = 0,
};

pub const FrameSummary = extern struct {
    abi_version: u32 = abi_version,
    terminal_surface: u32 = 0,
    frame_loop_ticks: u64 = 0,
    last_tick_index: u64 = 0,
    output_events: u64 = 0,
    exit_events: u64 = 0,
    surface_id: u64 = 0,
    glyph_count: u64 = 0,
    draw_cells: u64 = 0,
    atlas_entries: u64 = 0,
    key_events: u64 = 0,
    terminal_input_events: u64 = 0,
    terminal_input_bytes: u64 = 0,
    app_key_events: u64 = 0,
    ignored_key_events: u64 = 0,
    resize_events: u64 = 0,
    close_events: u64 = 0,
    cols: u32 = 0,
    rows: u32 = 0,
    process_state: u32 = 0,
    frame_prepared: u32 = 0,
    frame_consistent: u32 = 0,
    glyph_uv_ready: u32 = 0,
    glyph_raster_ready: u32 = 0,
    ended: u32 = 0,
    last_event_kind: u32 = @intFromEnum(EventKind.none),
    // 현재 retain된 Metal frame의 generation(u64를 u32로 truncate). host는 이 값이 그대로면
    // metalFrame() ABI를 부르지 않고 draw를 건너뛸 수 있다(idle tick 비용 절감). u32 wrap은
    // 사실상 발생하지 않고, 충돌해도 redraw 한 번 누락/추가일 뿐이라 무해하다.
    metal_generation: u32 = 0,
};

const NormalizedConfig = struct {
    size: terminal.Size,
    queue_capacity: usize,
    command_kind: CommandKind,
    chrome_minimal: bool,
    minimal_tabs: bool,
    // 첫 spawn 크기 결정용 창 backing 픽셀 + scale(0이면 size로 폴백). init이 cell 메트릭으로 grid 계산.
    width_px: u32,
    height_px: u32,
    scale_milli: u32,
};

/// 한 터미널의 런타임 단위: surface(그리드/스크롤백) + 그 surface에 붙은 live PTY 셸 + 그 PTY를 drain하는
/// pump. `LivePtySession`의 reader thread가 `&live_pty.reader`를 잡으므로 이 묶음은 한번 만들면 이동하면
/// 안 된다 — heap-pin(`*Term`)이라 ArrayList realloc·트리 회전·탭 재정렬에도 본체(reader가 잡는
/// `&live_pty.reader`, SplitTree leaf가 잡는 `&surface`)가 안 움직인다. pump는 안정 `*queue`만 들어 이동
/// 제약이 없다. 탭→pane 모델에서 한 Pane(split leaf)이 이 Term을 가로 탭으로 여러 개 들 수 있다(⌘T로 추가).
const Term = struct {
    surface: app.Surface = undefined,
    live_pty: app.LivePtySession = undefined,
    pump: app.RuntimeEventPump = undefined,
    live_initialized: bool = false,
    // 이 Term의 PTY가 종료(exit/read_error) 관측 후 finishAfterTermination까지 끝났는가. tick drain이 Term별로
    // 한 번만 finish하도록, 세션 종료(모든 Term terminated) 판정에 쓴다.
    terminated: bool = false,
    // git 브랜치 표시 캐시(owned). cwd(OSC 7)에서 .git/HEAD를 walk-up해 도출한 브랜치명과, 그걸 계산한 cwd.
    // termGitBranch가 cwd가 바뀔 때만 재계산(매 프레임 fs 읽기 회피). destroyTerm이 해제. 영속 안 함(파생값 — restore가 재도출).
    git_branch: ?[]const u8 = null,
    git_branch_cwd: ?[]const u8 = null,
    // 이 Term의 포그라운드 프로세스가 어떤 에이전트 CLI인지(none/claude/codex). pollAgentKinds가 ≈0.5s마다
    // tcgetpgrp+proc_name으로 갱신. 사이드바 라벨에 에이전트 심볼로 표시. 파생값(영속 안 함).
    agent_kind: AgentKind = .none,
    // 에이전트 세션 진행 상태(unknown/running/idle) — pollAgentState가 세션 JSONL tail로 판정(agent_kind가 none이
    // 아닐 때만 의미). 사이드바 상태줄·아이콘 펄스에 쓴다. 파생값(영속 안 함). agent_session_mtime=찾은 세션 파일의
    // 마지막 mtime(나노초) — 안 바뀌면 tail 재파싱 skip. agent_answer_buf/_len=idle일 때 마지막 답변 첫 줄(inline
    // 버퍼라 alloc 없음 — 사이드바 폭으로 다시 말줄임). 모두 derived: destroyTerm이 따로 해제할 owned 포인터 없음.
    agent_state: agent_session.State = .unknown,
    agent_session_mtime: i128 = 0,
    agent_answer_buf: [agent_answer_max]u8 = undefined,
    agent_answer_len: usize = 0,
    // 사이드바·탭 라벨용 자동 제목 캐시(owned). syncAutoTitles가 매 tick core_mutex 하에 core.windowTitle()
    // (OSC 0/2 제목 > cwd basename)을 복사해 채운다 — 렌더 스레드(termLabel)가 reader 스레드의 core.title/cwd
    // free(OSC 0/2/7)와 경합하지 않게(io-render-threading PR3). 파생값(영속 안 함). destroyTerm이 해제.
    auto_title: std.ArrayListUnmanaged(u8) = .empty,
};

/// Term 포그라운드에서 도는 에이전트 CLI 종류. 사이드바에 심볼로 표시(claude=✳, codex=✻).
const AgentKind = enum(u8) { none = 0, claude, codex };

/// 에이전트 완료 알림 한 건(owned). title=워크스페이스 이름, body=마지막 답변 일부. agent_notifications 큐에
/// 쌓였다가 pendingNotification()이 드레인하며 둘 다 해제한다.
const AgentNotification = struct { title: []u8, body: []u8 };

/// 동시에 쌓일 수 있는 완료 알림 상한(폭주 가드). 보통 한 tick에 0~1건이라 넉넉하다 — 넘으면 가장 오래된 걸 버린다.
const agent_notification_cap: usize = 16;

/// 에이전트 아이콘 코드포인트(없으면 0) — 사이드바 카드에서 이름줄과 분리해 슬롯 세로 중앙에 독립 배치한다
/// (buildSidebarDrawList의 agents). 0=아이콘 없음. 브랜드 마크의 전용 유니코드가 없어 근사 글리프: claude=✳
/// (U+2733, Anthropic 선버스트), codex=✻(U+273B, OpenAI 블로썸/6잎 꽃 모티프). 포그라운드인 동안만 표시.
fn agentSymbolCodepoint(kind: AgentKind) u21 {
    return switch (kind) {
        .none => 0,
        .claude => 0x2733,
        .codex => 0x273B,
    };
}

/// 아이콘 펄스 off 위상에서 쓰는 어두운 색. 브랜드색을 배경 쪽으로 낮춘다(고정 비율). 깜빡임이 아니라 밝기 변조라
/// 글자가 사라지지 않고 부드럽게 맥동한다(접근성 — 급격한 on/off 회피). 비율 45%는 full-color와 충분히 구분되되
/// 너무 어둡지 않은 값으로 택했다.
fn dimRgb(c: maru.color.Rgb) maru.color.Rgb {
    return .{
        .r = @intCast(@as(u16, c.r) * 45 / 100),
        .g = @intCast(@as(u16, c.g) * 45 / 100),
        .b = @intCast(@as(u16, c.b) * 45 / 100),
    };
}

/// haystack이 prefix로 시작하는가(대소문자 무시). 프로세스명 분류용 — 부분일치(claudia·mycodex 오탐)를 피하면서
/// 변종("claude-code"·"codex-cli")은 잡는다.
fn startsWithCi(haystack: []const u8, prefix: []const u8) bool {
    return haystack.len >= prefix.len and std.ascii.eqlIgnoreCase(haystack[0..prefix.len], prefix);
}

/// 포그라운드 프로세스 이름을 에이전트 종류로 분류한다(대소문자 무시 prefix 일치). claude/codex가 node 등 인터프리터
/// 이름으로 뜨거나(v1 한계 — 네이티브/래퍼 바이너리명이 claude/codex일 때 동작) 파이프라인 비-리더 단계면 감지 못 함.
fn classifyAgent(name: ?[]const u8) AgentKind {
    const n = name orelse return .none;
    if (startsWithCi(n, "claude")) return .claude;
    if (startsWithCi(n, "codex")) return .codex;
    return .none;
}

/// 한 panel(split leaf = 화면의 한 분할 영역). 탭 모델로 **여러 Term(터미널)을 가로 탭으로** 담는 컨테이너다
/// — `⌘T`가 활성 Pane에 Term을 추가하고, Pane 상단 탭 바가 각 Term을 탭으로 보여준다(PR-C+). 지금(PR-A)은
/// Pane당 Term 1개로 시작해 동작이 기존과 같다. SplitTree leaf는 이 Pane의 '활성 Term의 surface'를 가리킨다
/// (활성 Term이 바뀌면 leaf surface를 그 Term으로 갱신 — PR-B). heap-pin(`*Pane`)이라 ArrayList realloc·트리
/// 회전에도 본체가 안 움직인다(Term이 `&surface`/`&reader`를 거는 주소 안정).
const Pane = struct {
    // 이 panel의 Term들(가로 탭, heap-pin `*Term`). 항상 ≥1. `⌘T`가 늘리고 `⌘W`/✕가 줄인다(마지막이면 Pane
    // collapse). tree leaf는 active_term의 surface를 가리킨다.
    terms: std.ArrayList(*Term) = .empty,
    // 이 panel에서 포커스된(보이는) Term 인덱스 — surface/PTY/pump 접근과 tree leaf가 이 Term을 본다.
    active_term: usize = 0,
    // Step 2: 가로 탭 스크롤 offset(컬럼). 탭이 바 폭을 넘으면 ‹›버튼/트랙패드가 이 값을 움직여 보이는 탭 창을
    // 좌우로 민다(per-pane 독립). 0=맨 왼쪽(기본). barMetrics→Metrics.scroll_cols로 전달돼 segOf가 화면 좌표를 민다.
    tab_scroll_cols: u32 = 0,
    // 스크롤바 fade 타이머(per-pane — 각 pane이 독립적으로 흐려진다). updateScrollbarFade가 이 pane 활성 Term의
    // view_offset 변화(스크롤)를 감지해 0(full)으로 리셋하고, idle하면 늘려 appendScrollbar가 alpha를 흐린다.
    // 활성 pane은 hover/드래그면 0으로 핀(세션 상태). last_view_offset은 변화 감지용 직전 값.
    scrollbar_idle_ticks: u32 = 0,
    scrollbar_last_view_offset: usize = 0,
    // 사용자 지정 이름(rename). Pane은 자동 제목 출처가 없어 custom_name 하나뿐(null=없음). 탭바 좌측 라벨
    // 세그먼트로 표시(PR2). owned 문자열이라 destroyPane/deinit teardown에서 해제한다. 단일 출처:
    // docs/workspace-restore.md "사용자 지정 이름(custom_name)과 자동 제목".
    custom_name: ?[]const u8 = null,

    /// 활성 Term(보이는 터미널). 입력/커서/렌더가 이 Term의 surface를 쓴다. Pane은 항상 Term ≥1.
    fn activeTerm(self: *Pane) *Term {
        return self.terms.items[self.active_term];
    }
};

const Tab = struct {
    // 이 워크스페이스(사이드바 탭)의 panel들(heap-pin `*Pane`). split이 늘린다. tree의 leaf가 각 Pane의
    // 활성 Term `&surface`를 가리킨다.
    panes: std.ArrayList(*Pane) = .empty,
    // 포커스된 panel 인덱스 — 입력/커서/탭 대표 surface가 이 panel(의 활성 Term)을 본다. pane 포커스 이동이 바꾼다.
    active_pane: usize = 0,
    // 이 탭의 SplitTree 루트(split 모델). 단일 leaf(= 활성 Pane의 활성 Term surface)면 panel 1개 = 풀 탭 영역.
    // split이 leaf를 split 노드로 바꿔 여러 panel이 된다.
    tree: PaneTree.Node = undefined,
    // 워크스페이스(사이드바 탭)의 사용자 지정 이름(rename). 자동 제목 출처가 없어 custom_name 하나뿐(null=없음).
    // 없으면 사이드바 라벨은 활성 Term 라벨로 폴백한다(app.pickLabel). owned 문자열이라 destroyTabStandalone/deinit
    // teardown에서 해제한다.
    custom_name: ?[]const u8 = null,
    // 위치 고정(우클릭 메뉴 Pin) — true면 드래그 재정렬에서 안 움직이고(moveTab no-op), 사이드바에 고정 표시. workspace.v1 영속.
    pinned: bool = false,
    // 사이드바 카드 배경 tint(0xRRGGBB, 0=없음/기본 테마색). 우클릭 메뉴 프리셋. workspace.v1 영속.
    background_color: u32 = 0,

    /// 포커스된 panel. pane 내부(Term/surface) 접근에 쓴다. 탭은 항상 panel ≥1.
    fn activePane(self: *Tab) *Pane {
        return self.panes.items[self.active_pane];
    }

    /// 포커스된 panel의 활성 Term(= 화면에 보이는 터미널). surface/PTY/pump 접근의 최종 단계.
    fn activeTerm(self: *Tab) *Term {
        return self.activePane().activeTerm();
    }
};

/// 호버 중인 per-pane 탭 참조(어느 Pane의 몇 번째 Term 탭). 호버 ✕ 닫기 대상·렌더에 쓴다. Pane은 heap-pin
/// 이라 포인터가 안정이고, 닫기 등으로 Pane이 사라지면 호출자가 hovered_tab을 null로 비운다.
const TabRef = struct { pane: *Pane, tab: usize };
const ScrollRef = struct { pane: *Pane, right: bool }; // #5b: 호버 중인 가로 스크롤 버튼(어느 pane의 ‹=false/›=true)

/// 인라인 rename 중인 대상(어느 계층의 어느 라이브 객체). 커밋 시 그 객체의 custom_name을 쓴다. 모두 heap-pin
/// 포인터(*Tab/*Pane/*Term)라 ArrayList realloc·트리 회전에도 안정 — 단 그 객체가 teardown(close/exit/reap)으로
/// 사라지면 호출자가 rename을 취소(null)해야 한다(stale 포인터 방지, invalidateForFreedPane·destroyTerm 경로).
const RenameTarget = union(enum) {
    workspace: *Tab,
    pane: *Pane,
    term: *Term,
};

/// 워크스페이스 배경 tint 프리셋(0=없음, 그 외 0xRRGGBB) — 컨텍스트 메뉴 "배경: …" 항목 순서·tab_bg_labels와 1:1.
/// 베이스/결정: 색 팔레트는 단일 표준이 없어 maru가 택한 기본 셋이다 — 앰버(#DDA15E)는 maru accent(마루=나무 마루),
/// 나머지는 서로·앰버와 명확히 구분되는 중간 채도 색조(파랑/초록/빨강/보라)로 골라 여러 워크스페이스를 한눈에 가르게 했다.
/// 0(없음)에 순수 검정 프리셋이 없으므로 "0=tint 없음"과 충돌하지 않는다. 적용 알파(≈40%, 0x66)는 카드 위 글자 가독성 기준.
const tab_bg_presets = [_]u32{ 0, 0xDDA15E, 0x4A7BC4, 0x5BA85B, 0xC4544A, 0x9B6BC4 };
const tab_bg_labels = [_][]const u8{ "배경: 없음", "배경: 앰버", "배경: 파랑", "배경: 초록", "배경: 빨강", "배경: 보라" };
const ctx_menu_pin: usize = 1; // 메뉴 항목 인덱스: 0=Rename, 1=Pin/Unpin, ctx_menu_bg_first..=배경(buildContextMenuItems 순서와 단일 출처).
const ctx_menu_bg_first: usize = 2;

fn tabRefEql(a: ?TabRef, b: ?TabRef) bool {
    if (a == null and b == null) return true;
    if (a == null or b == null) return false;
    return a.?.pane == b.?.pane and a.?.tab == b.?.tab;
}

pub const AppSession = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    // 탭들. 각 Tab은 heap-pin(`*Tab`)이라 ArrayList가 realloc해도 본체(live_pty reader·surface)는
    // 안 움직인다. 현재는 init이 1개만 만들고, create/switch(후속)에서 늘어난다.
    tabs: std.ArrayList(*Tab) = .empty,
    // app_window.tabs(`[]*Surface`)가 가리킬 surface 포인터 배열 — tabs와 1:1로, 각 탭의 대표(활성 panel)
    // surface 안정 주소를 모은다. tabs 변경(생성/닫기/이동)·활성 panel 변경 때 갱신하고 app_window.tabs를
    // 여기로 재바인딩한다. 단일 panel(지금)이면 panes[0].surface.
    surface_ptrs: std.ArrayList(*app.Surface) = .empty,
    // surface_id·pty_id 발급(탭마다 유일). runtime이 두 id로 라우팅하므로 재사용하지 않는다.
    next_id: u64 = 1,
    // 새 탭(Cmd+T)이 첫 탭과 같은 종류의 셸을 띄우도록 spawn 파라미터를 보관한다. zdotdir(ZDOTDIR
    // 셸 통합 디렉터리)는 새 탭 spawn에도 필요하므로 init 끝에 free하지 않고 여기에 들고 deinit에서 푼다.
    // term은 loaded_config.config.term(arena 소유)에서 매번 읽는다.
    new_tab_config: NormalizedConfig = undefined,
    new_tab_zdotdir: ?[]const u8 = null,
    // opt-in ssh 라우팅(`shell-integration.ssh`)이 켜졌을 때 현재 maru 실행 파일 경로(owned). 새 탭 spawn에도
    // 필요하므로 init 끝에 free하지 않고 보관하다 deinit에서 푼다. 꺼졌거나 경로 해석 실패면 null(주입 안 함).
    new_tab_ssh_bin: ?[]const u8 = null,
    app_window: app.AppWindow = undefined,
    runtime: app.SurfaceRuntime = undefined,
    renderer_state: renderer.RendererState = undefined,
    frame_loop: app.AppFrameLoop = undefined,
    // 제품 app shell은 fake font backend가 아니라 실제 CoreText로 glyph frame을 만든다.
    // appearance(폰트/색)는 init에서 한 번 resolve해 매 tick의 CoreTextFrameBuilder에 쓴다. 런타임 폰트
    // 크기(⌘+/−)는 appearance.font.size를 직접 바꾼다(모든 consumer가 이걸 읽음).
    appearance: config_mod.ResolvedAppearance = undefined,
    // config가 정한 기본 폰트 크기(pt). ⌘0(reset_font_size)이 여기로 되돌린다 — appearance.font.size는
    // 런타임에 바뀌므로 원래 값을 따로 보관한다. init에서 resolve된 appearance.font.size로 채운다.
    base_font_size: f32 = 0,
    // 프로그램 처음 실행 시점(init)에 resolve한 appearance. "Reset to Defaults"(resetToInitial)의 단일 출처다 —
    // 런타임 줌(⌘+/−)·여백 변경을 init 시점 값으로 되돌린다. init에서만 채우고 이후 절대 안 바꾼다(reloadConfig가
    // 파일 새 값으로 appearance를 갈아도 이건 그대로라, reset 기준이 "프로그램 처음"으로 불변).
    initial_appearance: config_mod.ResolvedAppearance = undefined,
    // serializeWorkspaceWindow가 돌려주는 workspace 텍스트의 소유 버퍼(다음 호출/deinit까지 유효 — cwd ABI와 같은
    // 소유 규칙). Swift가 멀티 창 저장에서 세션마다 한 번 읽는다.
    workspace_buffer: ?[]u8 = null,
    // serializeSidebarConfig가 돌려주는 갱신된 config 텍스트의 소유 버퍼(다음 호출/deinit까지 유효 —
    // workspace_buffer 패턴). Swift가 받아 config 경로에 atomic write한다(앱→config 양방향 동기).
    sidebar_config_buffer: ?[]u8 = null,
    // 시작 시 로드한 raw config(~/.config/maru/config). arena가 font.family 문자열을 소유하고,
    // resolve된 appearance.font.family가 그 슬라이스를 빌리므로 세션 동안 살아 있어야 한다.
    loaded_config: config_mod.ParsedConfig = undefined,
    // loaded_config가 실제로 초기화됐는지. init 초반(live/surface 생성)이 실패하면 deinit이 아직
    // undefined인 arena를 free하지 않도록, 다른 자원과 같은 *_initialized 가드 패턴을 쓴다.
    config_loaded: bool = false,
    // config의 전역(OS) 단축키를 OS 등록용 기술자(가상 키코드 + Carbon modifier + action)로 변환해 담는다.
    // init에서 loaded_config.global_bindings를 global_hotkey.descriptorFor로 매핑(매핑 불가 chord는 제외).
    // Swift가 `maru_macos_app_session_global_hotkeys`로 읽어 RegisterEventHotKey로 등록한다(a2). owned.
    global_hotkeys: std.ArrayList(GlobalHotkey) = .empty,
    // 커맨드 카탈로그(메뉴바·커맨드 팝업이 그릴 액션 목록). init에서 한 번 빌드(세션 동안 불변). Swift가
    // `maru_macos_app_session_command_catalog`로 읽는다. owned — command_key_displays가 각 항목의 바인딩
    // 표시 문자열(널 종단)을 소유하고, command_entries의 key_display가 그걸 가리킨다(action_key/title은 정적 리터럴).
    command_entries: std.ArrayList(CommandEntry) = .empty,
    command_key_displays: std.ArrayList([:0]u8) = .empty,
    command_key_equivalents: std.ArrayList([:0]u8) = .empty,
    // 커맨드 팝업(Cmd+Shift+P)의 필터된 카탈로그 인덱스(표시 순서). UI 상태(open/query/preedit/selected)는 chrome
    // 컴포넌트(chrome_host.palette)가 든다 — C1b에서 chrome으로 이주했다(find와 같은 경로: placeText·IME·caret 공유).
    // command_palette.filter가 쿼리로 채우고(recomputePalette), buildChromeOverlayFrame이 이 인덱스로 Row를 만들어
    // 컴포넌트 view에 주입한다(카탈로그는 platform 소유라 neutral chrome에 못 넘긴다 — 필터된 행만 넘긴다).
    palette_filtered: std.ArrayList(usize) = .empty,
    // 스크롤백 Find(⌘F)의 매치 리스트(절대 좌표). UI 상태(검색어/현재/카운트)는 chrome_host.find가 들고, 매치
    // 리스트만 session이 소유한다 — terminal.Match라 chrome으로 못 옮긴다(중립 경계). 검색은 코어(findMatches)가
    // 채우고(recomputeFind), tick이 뷰포트로 클립해 하이라이트한다. 현재 매치 인덱스는 chrome_host.find.current.
    find_matches: std.ArrayList(terminal.Match) = .empty,
    // tick마다 활성 surface의 매치를 뷰포트 span으로 클립해 담는 재사용 버퍼(cell_colors.search_matches로 넘긴다).
    // 매 frame 새로 채우되 capacity는 재사용한다 — 스크롤·출력에 따라 뷰 안 매치가 바뀌므로 캐시하지 않는다.
    find_view_spans: std.ArrayList(terminal.SelectionSpan) = .empty,
    // I/O–렌더 스레딩 분리(docs/io-render-threading.md): 렌더 CellColors.palette가 코어의
    // palette_override 포인터를 직접 들면, PR3에서 리더 스레드의 OSC 4 변경과 data race가 난다.
    // 그래서 매 tick paletteOverride()를 이 소유 버퍼로 복사하고 CellColors.palette가 여기를
    // 가리키게 한다(코어 alias 제거). 활성 1개 + split 비활성 pane용 리스트(루프 전 capacity 예약해
    // appendAssumeCapacity로 realloc 없이 → items 포인터 안정).
    active_palette_copy: [256]?terminal.Rgb = .{null} ** 256,
    pane_palette_copies: std.ArrayList([256]?terminal.Rgb) = .empty,
    // ⌘G/⌘⇧G로 Find 오버레이가 **닫힌 채** 매치를 네비게이션 중인지. true면 오버레이가 닫혀 있어도 매치
    // 하이라이트(현재 매치만)와 출력 시 재검색을 유지한다(findNavigate가 켠다). 오버레이 열기(toggleFind)나
    // 터미널 타이핑(.terminal_input)이 끄면 하이라이트가 사라진다(검색 종료 신호).
    find_nav: bool = false,
    // chrome 호스트(플랫폼 중립 L3 — src/chrome). 현재 C0/Notice 모달만 소유한다(손상 알림 등). 열려 있으면
    // handleKeyEvent가 키를 chrome으로 라우팅하고, tick이 buildNoticeFrame을 최상위 오버레이로 그린다. tokens·
    // props는 매 frame AppSession이 빌드해 넘긴다(chrome은 config/terminal을 모름). 단일 출처: docs/chrome-strategy.md.
    chrome_host: chrome.ChromeHost = .{},
    // Notice 메시지의 세션 소유 백킹. notice.State.message는 slice라, ABI 호출자(Swift)의 transient 버퍼를
    // 그대로 가리키면 dangling이 된다 → showNotice가 여기로 복사하고 State.message가 이걸 가리킨다. 알림 문구라
    // 512B면 충분(초과분은 잘라 표시).
    notice_message_buf: [512]u8 = undefined,
    // 마우스 이동마다 도는 hover hit-test(updateHoveredTab·dividerAtPoint)용 재사용 scratch 버퍼. 매 이동
    // 마다 leaf rect/divider seg 레이아웃을 새 ArrayList에 할당·해제하던 churn을 없앤다 — 레이아웃은 매번
    // 다시 계산하므로(작은 트리라 cheap) 결과는 항상 최신이라 stale 캐시 위험이 없고, 버퍼 capacity만 재사용한다.
    // hover/divider hit-test는 메인 스레드에서 순차 실행되고 서로 다른 버퍼라 aliasing이 없다(reentrancy 없음).
    hover_leaf_scratch: std.ArrayList(PaneTree.LeafRect) = .empty,
    // appendPaneScrollbars가 매 프레임 모든 pane 우측에 스크롤바를 그릴 때 쓰는 leaf rect 재사용 버퍼
    // (hover_leaf_scratch와 별개 — frame build와 hover hit-test가 서로 안 클로버하게). capacity만 재사용.
    scrollbar_leaf_scratch: std.ArrayList(PaneTree.LeafRect) = .empty,
    hover_divider_scratch: std.ArrayList(PaneTree.DividerSeg) = .empty,
    // dividerAtPoint가 app DividerSeg를 neutral chrome `divider.Seg`로 변환해 담는 병렬 scratch(hover_divider_scratch와
    // index 일치) — `divider.hitTest`가 이걸로 판정한다(C2 마우스 hit-test 컴포넌트).
    divider_seg_scratch: std.ArrayList(chrome.components.divider.Seg) = .empty,
    // input.page-keys=scroll이면 메인 화면에서 PageUp/Down이 Maru 스크롤백을 스크롤한다. 기본
    // (false=passthrough)은 xterm/Ghostty처럼 \e[5~/\e[6~를 PTY로 보낸다.
    page_keys_scroll: bool = false,
    /// BEL 시스템 소리 여부(config bell.audible 캐시). takeBell이 음소거 게이트로 읽는다. 기본 true.
    audible_bell: bool = true,
    // 한 cell의 device 픽셀 크기(advance 폭 × line-height). 실제 CoreText 메트릭에서 뽑아
    // shaper(atlas slot 크기)·rasterizer·renderer fixed-cell layout·host resize가 모두 같은 값을
    // 쓰게 한다. 메트릭 조회 전/실패 시 font_size_px × device_scale 정사각으로 대체한다.
    cell_width_px: u32 = 0,
    cell_height_px: u32 = 0,
    // chrome 최소화 세션인가(quick terminal minimal). true면 paneBarHeightPx가 0(탭 바 끔)이고 refreshCellMetrics가
    // 사이드바 폭을 0으로 강제 — 터미널 그리드만 그린다. 사이드바 폭 0이면 사이드바 가장자리 hit-test(xOnSidebarEdge)도
    // false라 드래그 리사이즈 자체가 시작 못 한다(setSidebarWidthPx 별도 게이트 불요). normalizeConfig가
    // SessionConfig.chrome_minimal에서 채운다. 메인 창은 false(full chrome).
    chrome_minimal: bool = false,
    // minimal 세션에서 탭(워크스페이스·Term) 생성을 허용하는가. false(기본)면 chrome_minimal일 때 dispatchAppAction이
    // new_tab/new_term을 무동작으로 막는다(사이드바·탭 바가 없어 안 보이는 탭 생성 차단). true면 허용(파워유저).
    // chrome_minimal=false면 tabsBlocked()가 항상 false라 full 모드 탭은 이 값과 무관하게 동작한다.
    minimal_tabs: bool = false,
    // 세로 사이드바의 현재 논리 폭(pt). 사용자가 우측 경계를 드래그하면 [sidebar_min_pt, sidebar_max_pt]로
    // 갱신된다. backing 픽셀 폭은 scale을 곱해 구하므로 pt로 들면 DPI가 바뀌어도(refreshCellMetrics) 유지된다.
    sidebar_width_pt: u32 = default_sidebar_width_pt,
    // 세로 사이드바의 backing 픽셀 폭(= sidebar_width_pt × scale). refreshCellMetrics가 갱신한다.
    // gridFromBacking이 이만큼 터미널 폭에서 빼고, metalFrame()이 렌더러에 origin offset으로 넘긴다.
    sidebar_width_px: u32 = 0,
    // 터미널 셀↔컨테이너 가장자리 4방 inset(backing px, = appearance.window_padding_{top,right,bottom,left} × scale).
    // refreshCellMetrics가 갱신한다. paneTermRect가 좌상으로 left/top만큼 들이고 폭/높이를 (left+right)/(top+bottom)
    // 만큼 줄이며, gridFromBacking이 grid에서 같은 합을 뺀다 — 렌더 origin·마우스 hit-test·IME가 termRect 단일
    // 출처를 공유하므로 자동으로 정합한다. 비대칭(좌우·상하 다른 값) 지원.
    window_padding_px: PaddingPx = .{},
    // 사이드바 우측 경계 드래그로 폭을 조절하는 중인가. down이 경계 밴드에서 시작하면 true, drag(2)가
    // setSidebarWidthPx로 live 갱신, up(3)이 끝낸다(divider 드래그와 같은 패턴).
    sidebar_resize_active: bool = false,
    // 마지막 resize의 backing(drawable) 픽셀 크기. split된 panel의 leaf rect 계산(터미널 영역 = backing −
    // 사이드바)에 쓴다. 첫 resize 전엔 0 — 그땐 단일 leaf라 rect.w/h가 0이어도 활성 frame은 origin에 그려져
    // 무해하다(split은 창이 떠 backing이 잡힌 뒤에야 가능). resize가 갱신한다.
    backing_width_px: u32 = 0,
    backing_height_px: u32 = 0,
    // 활성 panel의 픽셀 rect(좌표 변환의 origin). 단일 panel이면 터미널 영역 전체(x = 사이드바 폭, y = 0)라
    // 기존과 동일하지만, split이면 활성 panel이 서브-rect에 있으므로 pxToCell/imeCursorRect가 사이드바 폭이
    // 아니라 이 rect의 origin을 기준으로 셀↔픽셀을 변환해야 마우스/커서/IME가 활성 panel에 맞는다. 레이아웃·
    // 포커스·리사이즈가 바뀔 때 recomputeActivePaneRect가 갱신한다. (w/h는 캐시만 — 현재 clamp는 surface grid로.)
    active_pane_rect: app.SplitRect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    // 사이드바 탭 슬롯 한 칸의 backing 픽셀 높이(= cell_height_px × 2.5). refreshCellMetrics가 갱신.
    // metalFrame()이 렌더러에 넘겨 사이드바 셀을 cell 높이가 아니라 이 슬롯 높이로 세로 배치한다.
    sidebar_slot_height_px: u32 = 0,
    // 사이드바 상단 헤더(검색바 + 아이콘 2개) 높이(px) = cell_height × header_ratio. 0이면 헤더 없음. 밴드·카드·
    // hit-test가 이만큼 아래로 시프트되고, .m이 사이드바 셀 py_top에 더한다(chrome props.sidebar_header_height_px로 전달).
    sidebar_header_height_px: u32 = 0,
    // backing(Retina) scale을 천분율로 보관한다(예: 2000 = 2.0×, 1500 = 1.5×). 정수 배율로
    // 반올림하지 않고 분수 그대로 들고 있어, glyph rasterize 크기와 cell 메트릭을 분수 Retina
    // 해상도에 정확히 맞춘다. resize 이벤트의 scale_milli에서 갱신한다.
    scale_milli: u32 = 1000,
    // 마지막으로 적용한 grid 크기. 같은 size+scale resize 중복을 여기서 건너뛴다(Swift가 아니라).
    last_resize_size: ?terminal.Size = null,
    surface_initialized: bool = false,
    runtime_initialized: bool = false,
    renderer_initialized: bool = false,
    termination_finished: bool = false,
    total_output_events: u64 = 0,
    total_exit_events: u64 = 0,
    total_key_events: u64 = 0,
    total_terminal_input_events: u64 = 0,
    total_terminal_input_bytes: u64 = 0,
    total_app_key_events: u64 = 0,
    total_ignored_key_events: u64 = 0,
    total_resize_events: u64 = 0,
    total_close_events: u64 = 0,
    ended_seen: bool = false,
    last_summary: FrameSummary = .{},
    // 가장 최근 RenderFrame의 Metal 투영을 retain하는 owned 버퍼. metalFrame()이 이걸 가리키는
    // view를 돌려준다. metal_dirty가 true일 때만(첫 frame, 새 output, resize) 재투영한다.
    metal_buffer: metal_frame.MetalFrameBuffer = .{},
    metal_dirty: bool = true,
    // 세로 사이드바에 그릴 탭 엔트리 셀(owned). rebuildSidebar가 탭 추가/전환/cell 메트릭 변경 때 다시
    // 채우고, metalFrame()이 이걸 가리키는 view를 사이드바 셀(origin 0 렌더)로 넘긴다. PR3b-1은 활성
    // 탭 하이라이트 밴드만 담고, PR3b-2가 탭 번호·제목 glyph를 더한다. 비싸지 않아(탭 수만큼) 변경
    // 이벤트마다 통째로 다시 만든다.
    sidebar_cells: std.ArrayList(metal_frame.NativeMetalCell) = .empty,
    // C4b: chrome rich GPU quad 프리미티브(둥근 박스) — sidebar/모달/divider lowering이 모은다. tui/빈이면
    // 길이 0(렌더 무동작). renderFrame이 replace로 metal_buffer에 넘겨 dupe 소유시킨다(self는 ArrayList 재사용).
    gpu_quads: std.ArrayList(metal_frame.GpuQuad) = .empty,
    // C4b 모달: chrome 그림자(GpuShadow) — 모달 배경 blur. per-frame(모달만, renderFrame이 매 프레임 clear).
    gpu_shadows: std.ArrayList(metal_frame.GpuShadow) = .empty,
    // kitty graphics(K2d): image_id → 렌더러가 마지막으로 업로드한 generation. planImageUploads가 매 frame
    // 비교해 바뀐 것만 업로드 채널에 싣는다(이미지당 개별 텍스처·upload-once). Swift 렌더러 텍스처 캐시의
    // Zig측 미러 — 둘이 desync하면(렌더러 재생성 등) 그 이미지는 다음 transmit까지 안 그려질 뿐이다.
    kitty_uploaded: std.AutoHashMapUnmanaged(u32, u64) = .{},
    // 마우스가 호버 중인 사이드바 탭 슬롯 인덱스(없으면 null). hoverCursor이 사이드바 영역에서 갱신하고,
    // rebuildSidebar가 이 슬롯에 호버 하이라이트 밴드를 그린다(활성 슬롯과 다를 때만). 후속 호버 X
    // 닫기 아이콘의 대상 슬롯도 이 값이다.
    hovered_slot: ?usize = null,
    // 마우스가 호버 중인 per-pane 탭(없으면 null). hoverCursor이 어느 pane의 탭 바 위면 (그 pane, 탭 index)으로
    // 갱신하고, 탭 바 렌더가 이 탭에 호버 ✕(닫기 아이콘)를 그린다. mouse down이 이 탭의 ✕ zone이면 그 Term을
    // 닫는다(사이드바 hovered_slot의 per-pane Term 버전). pane은 heap-pin이라 frame 사이 포인터가 안정.
    hovered_tab: ?TabRef = null,
    hovered_scroll: ?ScrollRef = null, // #5b: 호버 중인 ‹/› 스크롤 버튼 — 렌더가 밝게 칠해 클릭 가능 표시
    // 인라인 rename 상태(없으면 null=비활성). 활성이면 키/IME가 rename_input으로 라우팅되고(모달), 렌더가 대상
    // 슬롯/탭/라벨에 편집 텍스트+caret을 그린다. rename_input은 find/palette와 같은 OverlayInput(IME preedit·EAW·
    // UTF-8 경계 공유). 대상 객체가 teardown되면 invalidate가 null로 비운다(stale 포인터 방지).
    rename: ?RenameTarget = null,
    rename_input: chrome.components.overlay_input.OverlayInput = .{},
    /// 사이드바 헤더 검색바 입력(query+preedit, IME·EAW 폭). rename_input과 같은 OverlayInput 모델이지만 모달이
    /// 아니라 사이드바 상주 — sidebar_search_active일 때 키/IME가 여기로 라우팅되고, 카드 목록을 이름·브랜치·폴더로
    /// 필터링한다(visible_slots). Esc로 종료, Enter로 첫 매칭 세션 이동. P3.
    sidebar_search_input: chrome.components.overlay_input.OverlayInput = .{},
    sidebar_search_active: bool = false,
    /// 검색 필터로 좁힌 표시 카드 → 원본 tab 인덱스(표시 슬롯 순서). 검색 비활성/빈 검색어면 전체(0..tabs.len).
    /// rebuildSidebar가 recomputeVisibleTabs로 채우고, sidebarTabs/buildSidebarTitleFrame이 순회, slotAt/click/hover가
    /// 표시 슬롯→원본 탭 역매핑(visibleTab)에 쓴다(P3 필터). 슬롯↔탭 단일 출처(인덱스 어긋남 방지).
    sidebar_visible_tabs: std.ArrayList(usize) = .empty,
    // 우클릭 컨텍스트 메뉴의 대상(어느 워크스페이스/pane/Term을 우클릭했나). 메뉴 상태(open·anchor·selected)는
    // chrome_host.context_menu(중립)에, 라이브 포인터 대상은 여기에 둔다(rename과 같은 분리). 메뉴 "Rename" 선택
    // 시 이 대상으로 startRename. 대상 teardown 시 null로 비운다(stale 포인터 방지, rename과 같은 funnel).
    context_menu_target: ?RenameTarget = null,
    // 컨텍스트 메뉴 항목(동적, 대상 타입·pin 상태에 따라). show가 buildContextMenuItems로 채우고 itemAt/draws/accept가
    // contextMenuItems로 같은 리스트를 본다(보이는 항목 == 클릭/실행되는 항목). 라벨은 정적 리터럴이라 소유 불요.
    // 크기 = 최대 항목 수(Rename + Pin + 배경 프리셋)로 정확히 잡아 buf 오버플로를 컴파일 타임에 막는다.
    context_menu_items_buf: [ctx_menu_bg_first + tab_bg_labels.len][]const u8 = undefined,
    context_menu_items_len: usize = 0,
    // 사이드바 탭 드래그 재정렬 상태. down이 사이드바 슬롯(✕ 아님)에서 시작하면 active=true가 되고,
    // 이후 drag(kind 2)는 타겟 슬롯으로 live 재정렬(moveTab), up(kind 3)이 끝낸다. index는 드래그 중인
    // 탭의 현재 인덱스(이동을 따라간다). 드래그 중엔 다른 down/이벤트가 아니라 drag/up만 캡처한다.
    sidebar_drag_active: bool = false,
    sidebar_drag_index: usize = 0,
    // per-pane Term 탭 드래그 재정렬 상태(PR-E). down이 탭(✕ 아님)에서 시작하면 active=true가 되고, drag(kind 2)
    // 가 같은 pane 바 안에서 타겟 탭으로 live 재정렬(pane.terms rotateMove), up(kind 3)이 끝낸다. drag_pane은
    // 소스 pane(heap-pin이라 드래그 동안 안정), drag_index는 드래그 탭의 현재 인덱스(이동을 따라간다).
    tab_drag_active: bool = false,
    tab_drag_pane: ?*Pane = null,
    tab_drag_index: usize = 0,
    // 탭 드래그 중 현재 드롭 타겟(④b 하이라이트). zone null = 다른 pane 탭 바(이동), zone set = pane 본문 절반
    // (그 방향 split). drag(2)가 computeDropTarget로 갱신, 렌더가 그 zone을 반투명으로 칠한다. up/취소면 null.
    tab_drop_target: ?DropTarget = null,
    // 탭 드래그 중 마우스 위치(backing px) — 커서를 따라다니는 floating 탭 미리보기를 그 자리에 그린다.
    // drag(2)가 갱신한다(tab_drag_active일 때만 유효).
    tab_drag_x: f64 = 0,
    tab_drag_y: f64 = 0,
    // panel 사이 divider 드래그 리사이즈 상태(PR6). down이 divider 밴드에서 시작하면 그 split 노드를 잡고,
    // drag(kind 2)가 마우스 위치를 bounds 안 ratio로 매핑해 split.ratio를 바꿔 live 재배치, up(kind 3)이 끝낸다.
    // split은 활성 탭 트리의 heap 노드(`*PaneTree.Split`) — 구조가 바뀌면(collapse/close) stale 방지로 null 비운다.
    divider_drag: ?*PaneTree.Split = null,
    // 드래그 중 divider의 neutral seg(chrome `divider.dragRatio`용 — orientation·bounds). divider_drag != null일 때만
    // 유효. 옛 divider_drag_dir/bounds를 대체(dir·bounds가 Seg에 다 들어 있다 — 중립 단일 출처).
    divider_drag_seg: chrome.components.divider.Seg = .{ .orientation = .vertical_line, .bounds = .{ .x = 0, .y = 0, .w = 0, .h = 0 }, .pos = 0 },
    // 트랙패드 정밀 스크롤의 1줄 미만 잔여 델타(줄 단위). scrollWheel이 누적/소비한다.
    wheel_accum: f64 = 0,
    // 트랙패드 가로 스와이프의 1셀 미만 잔여 델타(열 단위) — 탭 바 가로 스크롤용(#2b). wheel_accum의 가로 짝.
    tab_wheel_accum: f64 = 0,
    // copyText()가 돌려준 추출 텍스트의 소유 버퍼(다음 copyText/destroy까지 유효 — ABI 수명 계약).
    copy_buffer: []u8 = &.{},
    // pendingClipboard()가 돌려준 OSC 52 클립보드 데이터의 소유 버퍼(다음 pendingClipboard/destroy까지 유효).
    clipboard_out_buffer: []u8 = &.{},
    // pendingNotification()이 돌려준 OSC 9/777 알림 title/body의 소유 버퍼(다음 pendingNotification/destroy까지 유효).
    notification_title_out: []u8 = &.{},
    notification_body_out: []u8 = &.{},
    // 에이전트 세션 완료(running→idle) 알림 큐(owned title/body). pendingNotification()이 OSC 9/777보다 먼저
    // 드레인해 Swift 알림으로 띄운다. running→idle 전환은 한 번만 일어나 자연 디바운스되고, 비활성 탭/창에서
    // 끝났을 때만 enqueue된다(docs/agent-session.md "알림"). 한 tick에 여러 탭 완료를 안 잃게 큐(상한 가드).
    agent_notifications: std.ArrayList(AgentNotification) = .empty,
    // 창이 키(포커스) 상태인지. focusChanged가 갱신. "활성 탭 AND 포커스 창"이면 사용자가 보고 있으므로 알림을
    // 띄우지 않는다(그 외 — 비활성 탭이거나 창이 백그라운드 — 는 띄운다).
    window_focused: bool = true,
    // urlAt()이 돌려준 URL의 소유 버퍼(다음 urlAt/destroy까지 유효).
    url_buffer: []u8 = &.{},
    // configPath()가 한 번 계산해 캐시하는 config 파일 경로(소유, destroy까지 유효). 경로 규칙(MARU_CONFIG
    // override·$HOME/.config/maru/config)은 Zig loader(defaultConfigPath)가 단일 출처 — Swift는 Open Config
    // 메뉴에서 이 경로를 받아 파일을 열기만 한다(파일 열기는 OS 동작이라 platform 소유).
    config_path_buffer: ?[]const u8 = null,
    // Cmd+hover 중인 URL 시작 셀의 절대 좌표(밑줄 렌더용). 뷰포트가 아니라 절대 좌표라 스크롤/출력
    // 으로 내용이 움직여도 따라간다(매 frame hoverLinkSpan이 현재 뷰포트로 클립).
    hover_url_anchor: ?terminal.SelectionPoint = null,
    // 현재 선택이 down(1) 드래그로 시작했는지. 더블/트리플클릭(4/5) 선택은 직후의 up(3)이
    // "이동 없는 클릭 -> 해제" 판정을 타면 안 되므로 이 플래그로 구분한다.
    mouse_drag_selecting: bool = false,
    // 드래그 자동 스크롤 방향(+1=위/과거, -1=아래, 0=없음). 드래그 좌표가 grid 위/아래 밖으로
    // 나가면 세워지고, 30Hz tick마다 한 줄 스크롤하며 선택을 가장자리 행으로 확장한다.
    drag_autoscroll: i8 = 0,
    // 스크롤바 thumb 드래그 중일 때, 잡은 지점의 thumb_top 기준 y 오프셋(px). null=드래그 안 함.
    // down(1)이 스크롤바 영역을 hit하면 세워지고, drag(2)가 마우스 y를 view_offset으로 매핑, up(3)이 푼다.
    scrollbar_drag_grab: ?f32 = null,
    // 마우스가 스크롤바 영역 위에 있는지(hover 강조 — full alpha·살짝 굵게). hoverCursor가 매 이동 갱신한다.
    // hover/드래그는 활성 pane 한정이라 세션 상태로 둔다(fade 타이머는 per-pane — Pane.scrollbar_idle_ticks).
    scrollbar_hovered: bool = false,
    // 자동 스크롤 중 선택 확장에 쓸 마지막 드래그 열.
    last_drag_col: u16 = 0,
    // mouse-reporting motion(DECSET 1003 any-event)에서 마지막으로 리포트한 셀. 같은 셀로의 연속 이동을
    // 스킵해(셀 단위 변화만 리포트) PTY·트래킹 앱 부하를 막는다(Ghostty cursorPosCallback의 그리드-동일 skip과 동일).
    last_motion_cell: ?struct { col: u16, row: u16 } = null,
    // 큰 붙여넣기의 미전송 잔여(인코딩 완료분). 자식이 stdin을 읽는 속도에 맞춰 tick마다
    // non-blocking으로 흘려보낸다 — 멀티MB 붙여넣기가 UI를 동결시키지 않게.
    pending_paste: std.ArrayList(u8) = .empty,
    pending_paste_offset: usize = 0,
    /// pending_paste가 향하는 surface id를 enqueue 시점에 고정한다(0=아직 없음). flush는 현재 활성
    /// surface가 아니라 이 대상으로 쓴다 — paste/IME 확정 잔여가 다 빠지기 전 탭/pane이 바뀌어도
    /// 바이트가 원래 surface로 가게 한다(과거엔 self.activeSurface()로 써 잔여가 새 탭에 입력되던 버그).
    pending_paste_target: u64 = 0,
    // IME 키 트랜잭션 상태(Ghostty의 keyTextAccumulator 패턴과 같은 구조). Swift keyDown이
    // imeBegin으로 열고 입력기 콜백(imeInsert/imeMarked)이 쌓은 것을 imeEnd가 일괄 판정한다 —
    // 콜백마다 즉석 판단하면 입력기의 비동기/다중 호출에서 이중 전송·유실이 생긴다(라이브에서
    // 실제 발생했던 클래스). 판정 로직이 Zig에 있어 전부 unit으로 고정된다.
    ime_active: bool = false,
    ime_inserted: std.ArrayList(u8) = .empty,
    ime_had_marked: bool = false,
    ime_marked_changed: bool = false,
    // 이번 키 트랜잭션에서 입력기가 deleteBackward 편집 명령을 보냈는지. 한글 마지막 자모
    // 백스페이스에서 입력기는 insertText(조합 글자) + deleteBackward를 같은 keyDown에 보내는데
    // (커밋 후 삭제 = net 0), 이게 있으면 확정 텍스트의 마지막 글자를 그 삭제가 상쇄한다.
    ime_did_delete: bool = false,
    // 이번 트랜잭션에서 imeInsert가 OOM으로 일부를 못 담았는지. 그러면 imeEnd는 잘린 텍스트를
    // 보내지 않고 통째로 버린다(fail-closed — 반쪽 문자열이 PTY에 들어가지 않게).
    ime_insert_failed: bool = false,
    // 커서/오버레이 caret 깜빡임 위상. 30Hz tick 15회(=500ms)마다 토글하고, 입력/출력이 있으면 보이는 상태로
    // 리셋한다(타이핑 중 안 사라짐). 터미널 커서(DECSCUSR blink)와 오버레이 caret(find·palette)이 **같은 위상·같은
    // 메커니즘**을 공유한다 — 커서는 blink 켜졌을 때만, caret은 열린 동안 늘. 렌더도 공유: caret이 오버레이
    // PaneFrame.cursor라 setCursorVisible(suffix-trim)이 재빌드 없이 토글한다(터미널 커서와 동일 경로 재활용).
    blink_visible: bool = true,
    blink_ticks: u32 = 0,
    // 에이전트 감지 polling 카운터 — 매 tick tcgetpgrp+proc_name(syscall)은 비싸므로 N tick마다(≈0.5s) 각 Term의
    // 포그라운드 프로세스명을 polling해 agent_kind를 갱신한다(claude/codex/none).
    agent_poll_ticks: u32 = 0,
    // synchronized output(2026) hold가 이어진 tick 수(활성 surface 기준). sync_timeout_ticks를 넘으면 ESU
    // 유실로 보고 강제 투영해 freeze를 푼다. sync가 꺼지면 0으로 리셋한다.
    sync_hold_ticks: u32 = 0,

    pub fn init(
        self: *AppSession,
        io: std.Io,
        allocator: std.mem.Allocator,
        raw_config: SessionConfig,
    ) !void {
        const config = try normalizeConfig(raw_config);

        self.* = .{
            .allocator = allocator,
            .io = io,
            // chrome 최소화 여부는 세션별로 고정(메인 창=full, quick minimal=true). refreshCellMetrics가
            // 사이드바 폭을 게이트하기 전에 세워야 하므로 reset 시점에 박는다.
            .chrome_minimal = config.chrome_minimal,
            .minimal_tabs = config.minimal_tabs,
        };
        errdefer self.deinit();

        // 사용자 config(~/.config/maru/config 또는 $MARU_CONFIG)를 가장 먼저 로드한다 — PTY를 띄울 때
        // 셸에 줄 TERM 값(`term =`)이 필요하기 때문이다(셸 설정/통합이 $TERM에 따라 키바인딩을 다르게
        // 잡는다). 단위 테스트에서는 개발자의 실제 config를 읽으면 비결정적이라 빈 config로 고정한다
        // (파싱 규칙은 loader 단위 테스트가 본다). loaded_config는 세션 동안 보관(family 슬라이스 빌림).
        // config_loaded 가드를 세워 이후 init 실패가 이 arena를 이중 해제하지 않게 한다.
        self.loaded_config = if (builtin.is_test)
            try config_mod.parseConfig(allocator, "")
        else
            try config_mod.loadConfigDefault(io, allocator);
        self.config_loaded = true;
        self.page_keys_scroll = self.loaded_config.config.input.page_keys == .scroll;
        self.audible_bell = self.loaded_config.config.bell.audible;

        // 전역 단축키 config를 OS 등록용 기술자로 변환해 둔다(Swift가 global_hotkeys ABI로 읽어 등록).
        // 가상 키코드로 매핑 안 되는 chord(+/Insert 등)는 descriptorFor가 null → 건너뛴다(등록 불가).
        for (self.loaded_config.global_bindings) |gb| {
            if (global_hotkey.descriptorFor(gb)) |d| {
                try self.global_hotkeys.append(self.allocator, .{
                    .virtual_key_code = d.virtual_key_code,
                    .carbon_modifiers = d.carbon_modifiers,
                    .action = @intFromEnum(d.action),
                });
            }
        }

        // 커맨드 카탈로그를 빌드한다(메뉴바·팝업 공유). 각 정적 엔트리에 현재 바인딩 chord 표시 문자열을 붙여
        // owned 목록에 담는다 — action_key/title은 정적 리터럴(복사 불요), key_display만 chord에서 만들어 dupeZ한다.
        // 바인딩은 loaded_config resolver로 역스캔(사용자 우선·unbind 존중). 안 묶인 액션은 빈 문자열.
        try self.buildCommandCatalog();

        // 셸 통합: 대화형 셸이 zsh면 macOS 편집키(Cmd+←/→ 등) 바인딩을 주입한다(사용자 .zshrc의
        // keymap 조건과 무관하게 동작하게). ZDOTDIR로 통합 .zshenv를 가리킨다. 실패 시 null(통합
        // 없이 정상 동작). dir 슬라이스는 spawn(EnvStorage가 dupe)까지만 필요하므로 init 끝에 해제.
        const integ_dir: ?[]const u8 = if (config.command_kind == .interactive_shell and
            shell_integration.detect(maru.pty.resolveInteractiveShell()) == .zsh)
            shell_integration.setupZsh(io, allocator)
        else
            null;
        // init 끝에 free하지 않고 보관한다(새 탭 Cmd+T spawn에도 필요) — deinit에서 푼다. 바로 store해
        // 이후 init 실패도 errdefer self.deinit()가 정리하게 한다.
        self.new_tab_zdotdir = integ_dir;
        // opt-in ssh 라우팅(`shell-integration.ssh`): 통합 .zshenv가 로드될 때(integ_dir != null = zsh 통합)만
        // ssh() 함수가 정의되므로 그때만 의미가 있다. 켜졌으면 현재 maru 실행 파일 경로를 잡아 두고 spawn 때
        // MARU_BIN/MARU_SSH_INTEGRATION으로 주입한다(같은 바이너리가 `maru ssh`를 처리 — main.zig). 경로
        // 해석이 실패하면 null로 둬 주입을 건너뛴다(평범한 ssh 그대로 — graceful). 새 탭에도 필요해 보관 후 deinit에서 푼다.
        self.new_tab_ssh_bin = if (integ_dir != null and self.loaded_config.config.shell_integration.ssh)
            (std.process.executablePathAlloc(io, allocator) catch null)
        else
            null;
        self.new_tab_config = config;

        // runtime을 먼저 세운다 — createTab의 attachSurface가 surface를 runtime link에 등록한다.
        self.runtime = app.SurfaceRuntime.init(allocator);
        self.runtime.debug_input = diag_gate.maruDebugEnabled(); // MARU_DEBUG면 zsh redraw 시퀀스 로깅
        self.runtime_initialized = true;

        // appearance·cell 메트릭을 **spawn 전에** 잡는다 — 셸 PTY를 처음부터 실제 창 grid로 띄워 80×24 기본 spawn
        // 후 resize하는 핸드셰이크/레이스(zsh 첫 프롬프트의 PROMPT_EOL_MARK `%` 잔상)를 없앤다. 로더가 valid-아니면-
        // default라 resolve는 사실상 실패 안 하지만 방어적으로 기본값 폴백(loaded_config는 위에서 PTY spawn 전에 로드).
        // scale_milli는 Swift가 창 backingScale로 준 값(없으면 1000=1x). refreshCellMetrics가 cell_width/height_px·
        // sidebar_width_px를 채운다(coretext + scale + sidebar_pt). renderer_state는 메트릭에 무관해 spawn 뒤에 둔다.
        self.scale_milli = if (config.scale_milli > 0) config.scale_milli else 1000;
        self.appearance = config_mod.resolveAppearance(self.loaded_config.config) catch
            try config_mod.resolveAppearance(.{});
        self.base_font_size = self.appearance.font.size; // ⌘0 리셋 기준(런타임에 appearance.font.size는 바뀜)
        // "Reset to Defaults"(resetToInitial)의 단일 출처 — 프로그램 처음 실행 설정. init에서만 잡고 reloadConfig가
        // 파일 새 값으로 appearance를 갈아도 안 바꾼다(reset 기준은 "프로그램 처음"이라 불변).
        self.initial_appearance = self.appearance;
        // config의 무시된 줄(알 수 없는 key·잘못된 값)을 알린다 — 사용자가 오타를 눈치채게.
        for (self.loaded_config.diagnostics) |d| {
            std.log.scoped(.config).warn("config line {d}: {s}", .{ d.line, d.message });
        }
        self.refreshCellMetrics();

        // 첫 spawn 크기 = 창 backing px가 오면 cell 메트릭으로 grid 계산(실제 창 크기), 아니면 cols/rows(헤드리스
        // 테스트·창 미상) 폴백. gridFromBacking은 resize 경로와 같은 단일 출처라 첫 grid와 이후 resize가 일치한다.
        var spawn_config = config;
        if (config.width_px > 0 and config.height_px > 0) {
            spawn_config.size = gridFromBacking(config.width_px, config.height_px, self.cell_width_px, self.cell_height_px, self.sidebar_width_px, self.window_padding_px);
        }
        // MARU_DEBUG 관측: 첫 셸 spawn grid가 무슨 입력(창 backing px·scale·cell·사이드바)에서 어떻게 나왔는지
        // 한 줄로 남긴다. PTY winsize=surface grid=이 값이라, 셸 COLUMNS(첫 프롬프트 PROMPT_EOL_MARK % 폭)와
        // 어긋나는지 데이터로 본다 — DPI별 spawn 크기 회귀를 추측 없이 진단하게 한다(이번 % 잔상 추적의 단일 출처).
        if (diag_gate.maruDebugEnabled()) {
            std.log.scoped(.spawn).info("spawn-size: in width_px={d} height_px={d} scale_milli={d} -> cell={d}x{d} sidebar_px={d} grid {d}x{d} (px_path={})", .{
                config.width_px,        config.height_px,       config.scale_milli,
                self.cell_width_px,     self.cell_height_px,    self.sidebar_width_px,
                spawn_config.size.cols, spawn_config.size.rows, config.width_px > 0 and config.height_px > 0,
            });
        }

        // 첫 탭을 만든다 — Tab + 첫 panel(셸 PTY spawn + surface + runtime attach + pump) + tabs/surface_ptrs
        // append + app_window 갱신을 createTab이 한 묶음으로 한다(create/switch 후속도 같은 경로를 쓴다).
        // Swift는 opaque handle만 보유하고 AppSession은 heap에 고정된다(LivePtySession reader가
        // `&pane.live_pty.reader`를 잡으므로 Pane도 heap-pin — createPane이 allocator.create로 띄운다).
        _ = try self.createTab(
            spawnRequest(spawn_config, self.loaded_config.config.term, integ_dir, self.new_tab_ssh_bin),
            spawn_config.size,
            config.queue_capacity,
            "Maru shell",
            commandName(config.command_kind),
        );
        self.surface_initialized = true;

        self.renderer_state = renderer.RendererState.init(allocator, .{});
        self.renderer_initialized = true;
        // FrameLoop.init이 pump 포인터를 요구해 첫 Term의 pump를 넘기지만, AppSession은 tick에서 모든 Term을
        // 직접 drain하고 `tickAfterDrainWithFrameBuilder`(이미 drain된 summary를 받아 frame만 조립 — frame_loop.pump
        // 무시)만 쓴다. 즉 frame_loop.pump는 이 경로에서 절대 읽히지 않으므로 포커스/닫기마다 재바인딩하지 않는다
        // (읽히지 않는 필드를 유지하는 방어 코드 불필요). frame_loop.tick/tickWithFrameBuilder로 바꾸려면 그때 pump를 살려야 한다.
        // io는 frame 조립 경로의 코어 락에 쓰인다 — frame_loop.pump는 위 주석대로 안 읽히므로 그 queue.io에 기대지
        // 않고(undefined일 수 있다) AppSession이 가진 valid한 io를 직접 넘긴다(docs/io-render-threading.md PR3).
        self.frame_loop = app.AppFrameLoop.init(allocator, &self.app_window, &self.runtime, &self.activePane().activeTerm().pump, &self.renderer_state, io);
        // 활성 panel rect를 초기화한다 — refreshCellMetrics가 사이드바 폭을 채운 '뒤'라야 단일 panel 기준
        // (x = 사이드바 폭, y = 0)이 맞다(createTab 시점엔 사이드바 폭이 아직 0이라 여기서 다시 잡는다).
        self.recomputeActivePaneRect();
        self.writeSummaryFromState();
    }

    /// 현재 활성 탭(`*Tab`). live_pty/pump 등 탭 내부에 접근할 때 쓴다. `app_window.active_tab`을
    /// 인덱스로 쓰므로 surface 라우팅(activeSurface)과 같은 활성 탭을 본다. 호출자는 탭이 있을 때만
    /// 부른다(surface_initialized·tabs 비어있지 않음).
    fn activeTab(self: *AppSession) *Tab {
        return self.tabs.items[self.app_window.active_tab];
    }

    /// 활성 탭의 포커스된 panel. live_pty/pump/surface 접근(입력·커서·frame_loop pump)에 쓴다.
    fn activePane(self: *AppSession) *Pane {
        return self.activeTab().activePane();
    }

    /// 사이드바를 뺀 터미널 영역 사각형(backing px, 좌상단 = (사이드바 폭, 0)). split 레이아웃·resize·렌더가
    /// 공유하는 단일 출처. window padding은 여기서 빼지 않는다 — 탭 바·divider·pane 배경 같은 chrome은 사이드바
    /// 경계/창 가장자리까지 꽉 차고, padding은 paneTermRect가 셀 그리드 영역에만 inset한다. backing 크기는 마지막
    /// resize 값이고, 첫 resize 전(0)이면 폭/높이가 0이라 단일 leaf가 origin에만 그려진다(무해).
    fn termRect(self: *const AppSession) app.SplitRect {
        return .{
            .x = self.sidebar_width_px,
            .y = 0,
            .w = self.backing_width_px -| self.sidebar_width_px,
            .h = self.backing_height_px,
        };
    }

    /// per-pane 가로 탭 바의 backing 픽셀 높이 = cell 높이 + 위아래 tab_bar_pad_y_px 패딩(rich — 텍스트 세로 여유).
    /// tui(pad=0)면 cell 1칸(기존). 제목은 origin_y를 pad_y만큼 내려 바 가운데에 둔다. paneTermRect가 이 높이만큼
    /// 내려 터미널 영역을 잘라 바와 터미널 첫 줄이 안 겹친다. cell 높이 미상이면 0(바 없음).
    /// chrome_minimal(quick terminal minimal)이면 0 — 바를 안 예약해 paneTermRect/paneBarRect가 탭 바를 통째로 끈다.
    fn paneBarHeightPx(self: *const AppSession) u32 {
        if (self.chrome_minimal or self.cell_height_px == 0) return 0; // cell 미상이면 0(바 없음, doc) — buildChromeTokens 읽기 전 가드
        return self.cell_height_px + 2 * @as(u32, self.buildChromeTokens().space.tab_bar_pad_y_px);
    }

    /// panel leaf rect의 상단 탭 바와 window padding을 뺀 '셀 그리드 영역' 사각형. 먼저 leaf rect가 바보다
    /// 충분히 높으면(바 + 최소 1칸) 상단 바 높이만큼 내려 자르고, 그 영역에 좌우·상하 window padding을 inset한다.
    /// chrome(탭 바·divider)은 leaf rect 가장자리까지 꽉 차고 셀 그리드만 여백을 갖는다. 좌표 변환(pxToCell)·
    /// resize·렌더 origin·IME(imeCursorRect)가 이 영역을 단일 출처로 쓰므로, padding을 여기 한 곳에 두면 grid
    /// origin·hit-test·IME 후보창이 함께 안쪽으로 정합한다. saturate(-|)로 바/패딩이 leaf보다 커도 언더플로 없이
    /// 0에 수렴 → gridFromRectPx가 clampGridSize 최소로 떨어진다.
    fn paneTermRect(self: *const AppSession, rect: app.SplitRect) app.SplitRect {
        const bar_h = self.paneBarHeightPx();
        const pad = self.window_padding_px;
        const body: app.SplitRect = if (bar_h > 0 and rect.h > bar_h)
            .{ .x = rect.x, .y = rect.y + bar_h, .w = rect.w, .h = rect.h - bar_h }
        else
            rect;
        // 비대칭 inset: 좌상으로 left/top만큼 들이고, 폭/높이는 (left+right)/(top+bottom)만큼 줄인다.
        return .{
            .x = body.x +| pad.left,
            .y = body.y +| pad.top,
            .w = body.w -| (pad.left +| pad.right),
            .h = body.h -| (pad.top +| pad.bottom),
        };
    }

    /// panel leaf rect의 상단 탭 바 rect(못 그리면 null — 바 없을 만큼 작거나 cell 미상). paneTermRect의 보수.
    fn paneBarRect(self: *const AppSession, rect: app.SplitRect) ?app.SplitRect {
        const bar_h = self.paneBarHeightPx();
        if (bar_h > 0 and rect.h > bar_h) {
            return .{ .x = rect.x, .y = rect.y, .w = rect.w, .h = bar_h };
        }
        return null;
    }

    /// pane 라벨 세그먼트(탭 바 좌측)가 차지할 컬럼 수. custom_name(사용자 rename)이 없으면 0(세그먼트 없음 —
    /// 탭이 바 전체 사용, 기존 동작). 있으면 좌패딩+이름폭+간격을 [3, max]로, 단 탭 영역 최소(min_tab_cols)는
    /// 남게 상한을 둔다 — 라벨이 바를 다 먹어 탭이 사라지지 않게. 폭은 렌더 ellipsize와 같은 titleDisplayWidth로
    /// 잰다(예약 칸 == 실제 글리프). 단일 출처: docs/tabs-splits-layout.md "Pane 이름 표시 자리".
    /// 이름 표시폭(name_width 칸)으로부터 라벨 세그먼트 컬럼 수를 산출하는 코어 — 좌패딩+이름+간격을 [3, max]로,
    /// 탭 영역 최소(min_tab_cols)는 남기고 좁은 바면 0(라벨 생략). custom_name(paneLabelCols)·rename 편집 텍스트
    /// (paneBar)가 공유한다(폭 셈법 단일 출처).
    fn paneLabelColsForWidth(name_width: usize, bar_cols: u32) u32 {
        if (name_width == 0) return 0;
        const min_tab_cols: u32 = 6; // 라벨 뒤 탭 영역 최소 보장(좁은 바면 라벨 생략)
        const max_label: u32 = 20; // 긴 이름이 바를 지배하지 않게 상한
        if (bar_cols <= min_tab_cols) return 0;
        const want = @min(@as(u32, @intCast(name_width)) + 2, max_label); // 좌패딩+이름+간격
        const cols = @min(want, bar_cols - min_tab_cols);
        return if (cols < 3) 0 else cols; // 3칸 미만이면 패딩+글자+간격 불가 → 생략
    }

    fn paneLabelCols(pane: *const Pane, bar_cols: u32) u32 {
        const name = app.pickLabel(pane.custom_name, "");
        if (name.len == 0) return 0;
        return paneLabelColsForWidth(coretext_frame_builder.titleDisplayWidth(name), bar_cols);
    }

    /// rename 중인 대상 판정(렌더가 편집 텍스트로 라벨을 대체할 때 쓴다). 라이브 포인터 동일성 비교.
    fn renamingWorkspace(self: *const AppSession, tab: *Tab) bool {
        const r = self.rename orelse return false;
        return switch (r) {
            .workspace => |t| t == tab,
            else => false,
        };
    }
    fn renamingPane(self: *const AppSession, pane: *Pane) bool {
        const r = self.rename orelse return false;
        return switch (r) {
            .pane => |p| p == pane,
            else => false,
        };
    }
    fn renamingTerm(self: *const AppSession, term: *Term) bool {
        const r = self.rename orelse return false;
        return switch (r) {
            .term => |t| t == term,
            else => false,
        };
    }

    /// rename 편집 표시 텍스트 "query+조합중preedit" + caret 1칸. caret은 `blink_visible`이면 '|', 아니면 공백 —
    /// **폭은 항상 +1로 고정**(renameDisplayWidth와 일치)이라 깜빡여도 텍스트/세그먼트 폭이 안 흔들린다. 토글은
    /// updateCursorBlink가 rename 중 metal_dirty로 rebuild를 일으켜 보인다(터미널 커서 suffix-trim과 달리 인라인
    /// caret은 셀 스트림의 글자라 full rebuild 필요 — text-blink와 같은 경로). 호출자(allocator) 소유.
    fn renameEditText(self: *AppSession, allocator: std.mem.Allocator) ![]const u8 {
        const caret: []const u8 = if (self.blink_visible) "|" else " ";
        return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.rename_input.query.items, self.rename_input.preedit.items, caret });
    }

    /// rename 편집 텍스트의 표시폭(칸) = query(EAW) + preedit(EAW) + caret 1칸. paneBar가 편집 중 라벨 폭을 이걸로
    /// 잡아, 이름이 비어도(편집 시작) 세그먼트가 떠 caret이 보인다.
    fn renameDisplayWidth(self: *const AppSession) usize {
        return self.rename_input.queryCols() + chrome.components.overlay_input.displayCols(self.rename_input.preedit.items) + 1;
    }

    /// 활성 탭의 leaf 중 pane==찾는 pane인 것의 PaneBar(rename caret 위치 계산용). 못 찾으면 null.
    fn paneBarForLeaf(self: *AppSession, pane: *Pane) ?PaneBar {
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return null;
        for (leaf_rects.items) |lr| {
            if (lr.leaf == pane) return self.paneBar(lr.rect, lr.leaf);
        }
        return null;
    }

    const TermBarLoc = struct { pb: PaneBar, tab_index: usize, count: usize, scroll: u32 };
    /// term이 속한 pane의 바·그 탭 인덱스(rename caret 위치 계산용). 못 찾으면 null.
    fn termBarLocation(self: *AppSession, term: *Term) ?TermBarLoc {
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return null;
        for (leaf_rects.items) |lr| {
            for (lr.leaf.terms.items, 0..) |t, ti| {
                if (t == term) {
                    const pb = self.paneBar(lr.rect, lr.leaf) orelse return null;
                    return .{ .pb = pb, .tab_index = ti, .count = lr.leaf.terms.items.len, .scroll = lr.leaf.tab_scroll_cols };
                }
            }
        }
        return null;
    }

    /// "{n} " 번호 prefix(tabNumberLabel) 칸수 — 1-based n의 자릿수 + 공백 1칸. caret 컬럼 계산에 쓴다.
    fn numberPrefixCols(index: usize) u32 {
        var n = index + 1;
        var digits: u32 = 1;
        while (n >= 10) : (n /= 10) digits += 1;
        return digits + 1; // 숫자 + 공백
    }

    /// rename 편집 caret의 셀 rect(backing px, 좌상단 원점) — IME 후보창 위치(imeCursorRect)에 쓴다. 대상별 편집기
    /// 텍스트 origin + caret 컬럼(prefix + query 폭)을 잡는다. preedit는 안 더한다(커서가 조합 글자를 덮는 터미널 IME
    /// 규약 — find.caretRect와 동일). 사이드바 슬롯 y는 slot_height 기준 세로 중앙 근사(후보창은 근처면 충분). 못
    /// 구하면 null(터미널 커서로 폴백). 렌더 geometry(paneBar·barMetrics·segOf, 사이드바 indent/slot)와 같은 셈법.
    fn renameCaretRect(self: *AppSession) ?chrome.draw.Rect {
        const target = self.rename orelse return null;
        const cw = self.cell_width_px;
        const ch = self.cell_height_px;
        if (cw == 0 or ch == 0) return null;
        const qcols: u32 = self.rename_input.queryCols();
        switch (target) {
            .workspace => |tab| {
                const idx = for (self.tabs.items, 0..) |t, i| {
                    if (t == tab) break i;
                } else return null;
                // 사이드바 이름줄(line 0) 좌단 indent(buildSidebarTitleFrame와 같은 ceil(card_gap+accent_bar)/cw).
                // 번호 prefix는 제거됐으므로(이름줄에 번호 없음) caret = indent + query 폭.
                const sp = self.buildChromeTokens().space;
                const indent_cols: u32 = (sp.card_gap_px + sp.accent_bar_width_px + cw - 1) / cw;
                const caret_col = indent_cols + qcols;
                const slot_h = self.sidebar_slot_height_px;
                return .{
                    .x = @intCast(caret_col * cw),
                    .y = @intCast(@as(u32, @intCast(idx)) * slot_h + (slot_h -| ch) / 2), // 슬롯 세로 중앙 근사
                    .w = @intCast(cw),
                    .h = @intCast(ch),
                };
            },
            .pane => |pane| {
                const pb = self.paneBarForLeaf(pane) orelse return null;
                // buildPaneLabelDrawList: 이름이 col 1부터(좌패딩 1). 긴 이름은 말줄임되므로 caret을 라벨 세그먼트
                // 우경계(label_cols-1, 마지막 칸은 탭과의 간격)로 clamp해 후보창이 라벨 밖(탭 위)으로 새지 않게.
                const caret_col = @min(1 + qcols, if (pb.label_cols > 1) pb.label_cols - 1 else 1);
                const pad_y = self.buildChromeTokens().space.tab_bar_pad_y_px;
                return .{
                    .x = @intCast(pb.full.x + caret_col * cw),
                    .y = @intCast(pb.full.y + pad_y),
                    .w = @intCast(cw),
                    .h = @intCast(ch),
                };
            },
            .term => |term| {
                const loc = self.termBarLocation(term) orelse return null;
                const m = barMetrics(loc.pb.tabs, cw, loc.count, self.buildChromeTokens().space.tab_width_cols, loc.scroll) orelse return null;
                const seg = m.segOf(loc.tab_index);
                // 탭 텍스트: 세그먼트 start_col + 1(좌패딩) + "{n} " prefix 뒤. **그 탭 세그먼트 우경계(seg.end_col)**로
                // clamp해 caret/후보창이 인접 탭 위로 새지 않게 한다(end_col<=start_col인 overflow 탭이면 m.cols 폴백).
                const seg_end = if (seg.end_col > seg.start_col) seg.end_col else m.cols;
                const caret_col = @min(seg.start_col + 1 + numberPrefixCols(loc.tab_index) + qcols, seg_end);
                const pad_y = self.buildChromeTokens().space.tab_bar_pad_y_px;
                return .{
                    .x = @intCast(loc.pb.tabs.x + caret_col * cw),
                    .y = @intCast(loc.pb.tabs.y + pad_y),
                    .w = @intCast(cw),
                    .h = @intCast(ch),
                };
            },
        }
    }

    /// 탭 영역 sub-rect — 전체 바에서 좌측 라벨(label_cols)을 뗀 나머지. 탭 hit-test(barMetrics)·탭 제목 렌더가
    /// 이 sub-rect를 공유해 라벨만큼 우측으로 밀린다(label_cols=0이면 전체 바 == 기존 동작).
    fn paneTabBarRect(bar: app.SplitRect, label_cols: u32, cw: u32) app.SplitRect {
        const off = label_cols * cw;
        return .{ .x = bar.x + off, .y = bar.y, .w = bar.w -| off, .h = bar.h };
    }

    /// 한 pane 탭 바의 레이아웃 단일 출처 — `full`(전체 바: 배경·클릭 판정·라벨), `tabs`(라벨 뗀 탭 영역:
    /// barMetrics·탭 제목·활성 밴드), `label_cols`(라벨 폭). 모든 hit-test/렌더가 이 한 함수를 거쳐 "보이는 == 클릭되는"
    /// 을 유지한다(label_cols가 render·hit-test에서 동일). 바가 없거나 cell 미상이면 null.
    const PaneBar = struct { full: app.SplitRect, tabs: app.SplitRect, label_cols: u32 };
    fn paneBar(self: *const AppSession, rect: app.SplitRect, pane: *Pane) ?PaneBar {
        const full = self.paneBarRect(rect) orelse return null;
        const cw = self.cell_width_px;
        if (cw == 0) return null;
        const bar_cols = full.w / cw;
        // rename 편집 중인 pane이면 custom_name이 비어도 편집 텍스트 폭으로 세그먼트를 띄운다(caret이 보이게).
        const label_cols = if (self.renamingPane(pane))
            paneLabelColsForWidth(self.renameDisplayWidth(), bar_cols)
        else
            paneLabelCols(pane, bar_cols);
        return .{ .full = full, .tabs = paneTabBarRect(full, label_cols, cw), .label_cols = label_cols };
    }

    /// 활성 탭의 SplitTree를 터미널 영역 rect 안에서 각 panel(leaf)의 (surface, rect)로 편다(멀티-panel
    /// 렌더용 — 각 surface를 자기 rect에 그린다). 단일 leaf면 [{활성 surface, term_rect}] 하나; split 이후
    /// 여러 rect가 된다. term_rect는 사이드바를 뺀 터미널 영역(렌더가 termRect로 계산해 넘김).
    fn activeTabLeafRects(
        self: *AppSession,
        allocator: std.mem.Allocator,
        term_rect: app.SplitRect,
        out: *std.ArrayList(PaneTree.LeafRect),
    ) !void {
        try PaneTree.layout(allocator, self.activeTab().tree, term_rect, out);
    }

    /// 활성 탭의 각 panel을 자기 leaf rect grid로 resize한다(window resize·split 후 재배치). 단일 leaf면
    /// 활성 surface 하나를 full term grid로 — 기존 resizeActiveSurface와 동일 효과. 활성 panel의 resize
    /// 에러만 전파하고(기존 resize()의 try 동작 보존), 비활성 panel의 죽은 PTY 등은 무시해 한 panel이 다른
    /// panel 재배치를 막지 않게 한다. leaf rect 계산 실패(OOM)는 전파.
    fn resizeActiveTabPanes(self: *AppSession) !void {
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        try self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects);
        const active_pane = self.activePane();
        for (leaf_rects.items) |lr| {
            // 각 panel은 상단 탭 바를 뺀 '터미널 영역'(paneTermRect)에 그려지므로 Term grid도 그 크기로 맞춘다.
            const trect = self.paneTermRect(lr.rect);
            const psize = gridFromRectPx(self.cell_width_px, self.cell_height_px, trect.w, trect.h);
            // panel의 모든 Term(가로 탭)을 같은 rect grid로 맞춘다 — 비활성 Term도 전환 즉시 올바른 크기가 되게.
            // 활성 panel의 활성 Term만 에러를 전파(기존 단일 surface resize의 try 동작 보존), 나머지는 무시.
            for (lr.leaf.terms.items) |term| {
                if (lr.leaf == active_pane and term == lr.leaf.activeTerm()) {
                    try self.runtime.resize(term.surface.id, psize, self.io);
                } else {
                    self.runtime.resize(term.surface.id, psize, self.io) catch {};
                }
            }
        }
    }

    /// 주어진 탭(활성/배경)의 각 panel을 자기 leaf rect grid로 resize한다 — reap collapse 후 형제가 빈자리
    /// 확장. best-effort: 임의 탭이라 모든 Term 에러를 무시한다(resizeActiveTabPanes는 활성 Term 에러를 resize()
    /// try 계약대로 전파하지만, 이 경로는 자동 정리라 한 panel 실패가 다른 재배치를 막지 않게 한다). 레이아웃
    /// 실패(OOM)는 무시(다음 resize/tick이 다시 맞춘다).
    fn resizeTabPanes(self: *AppSession, tab: *Tab) void {
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        PaneTree.layout(self.allocator, tab.tree, self.termRect(), &leaf_rects) catch return;
        for (leaf_rects.items) |lr| {
            const trect = self.paneTermRect(lr.rect);
            const psize = gridFromRectPx(self.cell_width_px, self.cell_height_px, trect.w, trect.h);
            for (lr.leaf.terms.items) |term| self.runtime.resize(term.surface.id, psize, self.io) catch {};
        }
    }

    /// 활성 panel의 픽셀 rect를 다시 계산해 캐시한다(`active_pane_rect`). 활성 탭 tree를 터미널 영역에서
    /// 펴 활성 surface의 leaf rect를 찾는다. 못 찾거나(OOM) 단일 panel이면 터미널 영역 전체로 폴백 —
    /// 단일 panel은 그게 곧 활성 rect라 결과가 같다. 레이아웃/포커스/리사이즈가 바뀔 때(split·switchTab·
    /// resize·focusPane·closeTab·init) 호출해, pxToCell/imeCursorRect가 매 마우스 이벤트마다 재레이아웃
    /// (할당) 없이 캐시된 origin을 읽게 한다.
    fn recomputeActivePaneRect(self: *AppSession) void {
        const active_pane = self.activePane();
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        if (self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects)) |_| {
            for (leaf_rects.items) |lr| {
                if (lr.leaf == active_pane) {
                    self.active_pane_rect = self.paneTermRect(lr.rect); // 상단 탭 바를 뺀 영역(좌표 origin)
                    return;
                }
            }
        } else |_| {}
        self.active_pane_rect = self.paneTermRect(self.termRect()); // 폴백: 터미널 영역(바 아래)
    }

    /// panel 사이 divider 선 색(0xAARRGGBB) — 활성 하이라이트 색을 써서 두 panel 사이 경계가 또렷하게 보이게.
    fn dividerColor(self: *const AppSession) u32 {
        return self.sidebarActiveBg();
    }

    /// 얇은 **세로선**을 overlay 셀로 그린다 — [y_start, y_end) 범위에 행마다(cell 높이 step) origin_x에 sentinel
    /// 셀 1개씩, reserved로 cell의 한 변 ~2px만 칠한다(3=좌측, 5=우측). divider 세로선과 pane 테두리 좌/우가 공유.
    fn appendVerticalLine(self: *AppSession, out: *std.ArrayList(metal_frame.NativeMetalCell), origin_x: u32, y_start: u32, y_end: u32, reserved: u16, color: u32) void {
        const ch = self.cell_height_px;
        if (ch == 0) return;
        var y = y_start;
        while (y < y_end) : (y += ch) {
            var c = sentinelBgCell(0, 1, color, origin_x, y);
            c.reserved = reserved;
            out.append(self.allocator, c) catch return;
        }
    }

    /// 얇은 **가로선**을 overlay 셀로 그린다 — origin_y에 폭(width_px→floor cols, 최소 1)만큼 sentinel 셀 1개,
    /// reserved로 cell의 한 변 ~2px만 칠한다(2=하단, 4=상단). divider 가로선과 pane 테두리 상/하가 공유.
    fn appendHorizontalLine(self: *AppSession, out: *std.ArrayList(metal_frame.NativeMetalCell), origin_x: u32, origin_y: u32, width_px: u32, reserved: u16, color: u32) void {
        const cw = self.cell_width_px;
        if (cw == 0) return;
        const cols = @min(@max(width_px / cw, 1), @as(u32, std.math.maxInt(u16)));
        var c = sentinelBgCell(0, @intCast(cols), color, origin_x, origin_y);
        c.reserved = reserved;
        out.append(self.allocator, c) catch return;
    }

    /// app DividerSeg(라이브 *Split 결합)를 neutral chrome `divider.Seg`로 변환한다 — chrome은 app 트리를 모르므로
    /// host가 떼어 준다(palette Row 선례). 좌우 분할(horizontal)=세로선, 상하 분할(vertical)=가로선. bounds는 u32→i32.
    fn appSegToDivider(seg: PaneTree.DividerSeg) chrome.components.divider.Seg {
        return .{
            .orientation = switch (seg.direction) {
                .horizontal => .vertical_line,
                .vertical => .horizontal_line,
            },
            .bounds = .{ .x = @intCast(seg.bounds.x), .y = @intCast(seg.bounds.y), .w = seg.bounds.w, .h = seg.bounds.h },
            .pos = seg.pos,
        };
    }

    /// 활성 탭의 divider 선들을 overlay 셀로 out에 append한다(렌더). chrome `divider.view`가 seg→Rule op(선)을 내고,
    /// `lowerDividerRules`가 그 Rule을 렌더러 **부분 사각형**(reserved=3 bar=좌측 ~2px / 2 underline=하단 ~2px, 커서
    /// 모양과 같은 경로)으로 lower해 **얇은 선**으로 seam에 얹는다. divider 선/hit-test 수학은 chrome 컴포넌트가 단일
    /// 출처(C2). 단일 panel이면 빈 채. 셀 0이면 무동작. layout과 같은 좌표계(termRect)라 경계에 정확히 얹힌다.
    fn appendActiveTabDividers(self: *AppSession, out: *std.ArrayList(metal_frame.NativeMetalCell)) void {
        if (self.cell_width_px == 0 or self.cell_height_px == 0) return;
        var app_segs: std.ArrayList(PaneTree.DividerSeg) = .empty;
        defer app_segs.deinit(self.allocator);
        self.layoutActiveTabDividers(&app_segs) catch return;
        if (app_segs.items.len == 0) return;
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var neutral: std.ArrayList(chrome.components.divider.Seg) = .empty;
        for (app_segs.items) |seg| neutral.append(arena, appSegToDivider(seg)) catch return;
        var ops: std.ArrayList(chrome.draw.Op) = .empty;
        chrome.components.divider.view(neutral.items, arena, &ops) catch return;
        self.lowerDividerRules(ops.items, out);
    }

    /// chrome `divider.view`가 낸 Rule op(선)을 렌더러 부분 사각형 NativeMetalCell로 lower한다 — 세로선(from.x==to.x)은
    /// 경계 x에 ~2px 센터(−1 offset) reserved=3을 행마다, 가로선은 경계 y에 ~2px(하단 reserved=2, y+1−ch offset) bounds
    /// 폭 한 칸. 색은 `dividerColor()`(tui 토큰 .divider=sidebar_active). divider는 overlay(rasterizeOverlayCells)가
    /// 아니라 pane chrome 셀이라, full-cell이 아닌 이 얇은-선 lowering을 platform이 따로 가진다(옛 appendActiveTabDividers의 offset 보존).
    fn lowerDividerRules(self: *AppSession, ops: []const chrome.draw.Op, out: *std.ArrayList(metal_frame.NativeMetalCell)) void {
        const ch = self.cell_height_px;
        const color = self.dividerColor();
        for (ops) |op| switch (op) {
            .rule => |r| {
                if (r.from.x == r.to.x) { // 세로선: 경계 x −1 offset, y0..y1 행마다
                    const x: u32 = if (r.from.x >= 1) @intCast(r.from.x - 1) else 0;
                    const y0: u32 = @intCast(@max(@min(r.from.y, r.to.y), 0));
                    const y1: u32 = @intCast(@max(@max(r.from.y, r.to.y), 0));
                    self.appendVerticalLine(out, x, y0, y1, 3, color);
                } else { // 가로선(from.y == to.y): 경계 y+1−ch offset, bounds 폭 한 칸
                    const y_pos = r.from.y;
                    const ch_i: i32 = @intCast(ch);
                    const oy: u32 = if (y_pos + 1 >= ch_i) @intCast(y_pos + 1 - ch_i) else 0;
                    const x0: u32 = @intCast(@max(@min(r.from.x, r.to.x), 0));
                    const x1: u32 = @intCast(@max(@max(r.from.x, r.to.x), 0));
                    self.appendHorizontalLine(out, x0, oy, x1 - x0, 2, color);
                }
            },
            else => {},
        };
    }

    /// minimal(chrome 없는 quick terminal) 세션에서 탭이 여러 개일 때 **우상단에 작은 "탭 점" 인디케이터**를 overlay
    /// 셀로 append한다 — 사이드바·pane 탭 바가 숨겨져 안 보이는 탭을 글랜서블하게 보여준다. 적응형: 워크스페이스가
    /// 여러 개면 워크스페이스(⌘1..9)를, 아니면 활성 pane의 Term(⌘])을 점으로 — 한 줄로 가장 관련 있는 차원만.
    /// 점 = sentinel-bg 셀: strip(sidebarBg) 위에 활성=sidebarActiveBg(밝게)·나머지=sidebarHoverBg(중간 톤).
    /// chrome_minimal이 아니거나(full은 사이드바/탭 바가 이미 보여줌) 단일(탭 1개)이면 무동작.
    fn appendMinimalTabIndicator(self: *AppSession, out: *std.ArrayList(metal_frame.NativeMetalCell)) void {
        if (!self.chrome_minimal) return;
        const cw = self.cell_width_px;
        if (cw == 0) return;

        // 적응형 차원: 워크스페이스 우선(여러 개면 그쪽), 아니면 활성 pane의 Term. 둘 다 1개면 표시 안 함.
        const pane = self.activePane();
        var count: u32 = undefined;
        var active: u32 = undefined;
        if (self.tabs.items.len > 1) {
            count = @intCast(self.tabs.items.len);
            active = @intCast(self.app_window.active_tab);
        } else if (pane.terms.items.len > 1) {
            count = @intCast(pane.terms.items.len);
            active = @intCast(pane.active_term);
        } else return;

        // 화면 폭(셀 칸). minimal이라 사이드바 없음. paneTermRect가 window padding을 inset하므로(minimal은 바 없음)
        // 점 인디케이터도 셀 그리드와 같은 padding 안쪽에 정렬된다. 칸 0이면 안 그림.
        const term_rect = self.paneTermRect(self.termRect());
        const cols = term_rect.w / cw;
        if (cols == 0) return;

        // 레이아웃(칸): strip 좌우 1칸 패딩 + 점 1칸 + 점 사이 간격 1칸 → band 폭 = 2*count+1, 점은 band-local 1,3,5...
        const pad: u32 = 1;
        const band_width: u32 = 2 * count + 1;
        const right_margin: u32 = 1;
        // band가 우상단에 안 들어가면(극단적 탭 수 + 좁은 패널) 아예 안 그린다 — 안 그러면 band_start가 0으로
        // saturate돼 좌상단에 전체 폭으로 그려져(우상단 의도와 반대) 터미널을 덮는다.
        if (band_width + right_margin > cols) return;
        // 우상단 정렬(band_width+right_margin <= cols라 saturate 없이 정확히 우측에 붙는다).
        const band_start: u32 = cols - band_width - right_margin;

        const u16_max: u32 = std.math.maxInt(u16);
        // strip 배경(넓은 sentinel 셀 1개) → 그 위에 점들(append 순서 = painter 순서라 점이 strip 위에 그려진다).
        out.append(self.allocator, sentinelBgCell(
            @intCast(@min(band_start, u16_max)),
            @intCast(@min(band_width, u16_max)),
            self.sidebarBg(),
            term_rect.x,
            term_rect.y,
        )) catch return;
        var i: u32 = 0;
        while (i < count) : (i += 1) {
            const col = band_start + pad + i * 2;
            const color = if (i == active) self.sidebarActiveBg() else self.sidebarHoverBg();
            out.append(self.allocator, sentinelBgCell(@intCast(@min(col, u16_max)), 1, color, term_rect.x, term_rect.y)) catch return;
        }
    }

    /// minimal 세션에서 split이면 **활성 pane 둘레에 얇은 테두리**(focus accent)를 overlay 셀로 그린다 — 사이드바·탭
    /// 바가 없는 minimal에선 커서 말고는 어느 pane이 입력을 받는지 단서가 없으므로(full은 탭 바 하이라이트가 보여줌).
    /// 4변을 reserved 부분 사각형(3=좌·5=우·4=상·2=하, 각 ~2px 안쪽 띠)으로 그린다 — 좌/우는 행마다, 상/하는 폭 전체
    /// 한 칸. 색은 divider와 같은 sidebarActiveBg. chrome_minimal이 아니거나 단일 pane(테두리 불필요)이면 무동작.
    fn appendActivePaneBorder(self: *AppSession, out: *std.ArrayList(metal_frame.NativeMetalCell), rect: app.SplitRect, pane_count: usize) void {
        if (!self.chrome_minimal) return; // full은 활성 pane을 탭 바 하이라이트로 구분한다
        if (pane_count <= 1) return; // split 아니면 전체가 활성 pane이라 테두리 불필요
        const cw = self.cell_width_px;
        const ch = self.cell_height_px;
        if (cw == 0 or ch == 0 or rect.w == 0 or rect.h == 0) return;
        const color = self.sidebarActiveBg();
        const y_end = rect.y + rect.h;
        // 4변 thin 테두리(divider와 같은 reserved 부분-사각형 헬퍼 공유). 우측은 cell 우측 ~2px(reserved=5)라
        // origin_x를 rect 우변 한 칸 안쪽에, 하단은 cell 하단 ~2px(reserved=2)라 origin_y를 한 칸 안쪽에 둔다.
        self.appendVerticalLine(out, rect.x, rect.y, y_end, 3, color); // 좌
        self.appendVerticalLine(out, rect.x + rect.w -| cw, rect.y, y_end, 5, color); // 우
        self.appendHorizontalLine(out, rect.x, rect.y, rect.w, 4, color); // 상
        self.appendHorizontalLine(out, rect.x, y_end -| ch, rect.w, 2, color); // 하
    }

    /// 마우스 (x,y)가 활성 탭 어느 divider의 드래그 밴드 안인가 — 맞으면 그 DividerSeg, 아니면 null. 밴드는 경계
    /// pos ± (cell 절반 + margin), 교차축은 bounds 안. 렌더 divider(같은 layoutDividers)와 정렬돼 "보이는 =
    /// 잡히는". 단일 panel이면 항상 null(divider 없음). 마우스 down(1) divider 드래그 시작 판정에 쓴다.
    /// 마우스 (x,y)가 어느 divider 드래그 밴드 안인가 — 맞으면 {neutral Seg, 라이브 *Split}, 아니면 null. app DividerSeg는
    /// hover_divider_scratch에, neutral 변환은 divider_seg_scratch에(index 일치) — chrome `divider.hitTest`가 후자로 판정하고,
    /// 그 index의 **neutral seg**(드래그/커서가 직접 씀 — 재변환 없음)와 split을 돌려준다(보이는==잡히는). split만 app.
    /// ⚠️ 반환값은 두 scratch 버퍼의 **borrow**다 — **다음 dividerAtPoint 호출 전에 소비**하라(scratch를 clear+재기록하므로
    /// 보관/aliasing 금지). 현 호출처(down=divider_drag_seg로 값 복사, hover=hit.seg.orientation 즉시 읽기)는 안전하다.
    fn dividerAtPoint(self: *AppSession, x_px: f64, y_px: f64) ?struct { seg: chrome.components.divider.Seg, split: *PaneTree.Split } {
        const segs = &self.hover_divider_scratch;
        segs.clearRetainingCapacity();
        self.layoutActiveTabDividers(segs) catch return null;
        self.divider_seg_scratch.clearRetainingCapacity();
        for (segs.items) |seg| self.divider_seg_scratch.append(self.allocator, appSegToDivider(seg)) catch return null;
        const i = chrome.components.divider.hitTest(self.divider_seg_scratch.items, self.cell_width_px, self.cell_height_px, x_px, y_px) orelse return null;
        return .{ .seg = self.divider_seg_scratch.items[i], .split = segs.items[i].split };
    }

    fn layoutActiveTabDividers(self: *AppSession, out: *std.ArrayList(PaneTree.DividerSeg)) !void {
        try PaneTree.layoutDividers(self.allocator, self.activeTab().tree, self.termRect(), out);
    }

    /// divider 드래그 중(kind 2) 마우스 위치를 bounds 안 ratio로 매핑해 split.ratio를 바꾸고 panel을 재배치한다.
    /// ratio = (mouse - bounds.origin) / bounds.size를 app.clampRatio(layout과 같은 한도)로 막는다. split이
    /// 사라졌으면(드래그 중 구조 변경) divider_drag가 null로 비워지므로 여기 안 온다.
    fn dragDividerTo(self: *AppSession, x_px: f64, y_px: f64) void {
        const sp = self.divider_drag orelse return;
        // ratio 수학은 chrome `divider.dragRatio`(normal 축 = (mouse − bounds.origin)/bounds.size)가 단일 출처. 클램프는
        // 여기서(app.clampRatio — layout과 같은 한도, chrome은 app 상수를 모른다). 드래그 시작 시 저장한 neutral seg를 쓴다.
        const raw = chrome.components.divider.dragRatio(self.divider_drag_seg, x_px, y_px) orelse return;
        sp.ratio = app.clampRatio(raw);
        self.resizeActiveTabPanes() catch {};
        self.recomputeActivePaneRect();
        self.metal_dirty = true;
    }

    /// 사이드바 우측 경계 드래그(kind 2) — 폭을 x_px(backing, 경계가 갈 위치)로 잡고 [sidebar_min_pt,
    /// sidebar_max_pt] pt로 clamp한다. pt를 권위 있게 저장(DPI 변경에도 유지), backing px·grid는 거기서 파생.
    /// 사이드바 폭이 모든 탭의 터미널 폭을 바꾸므로 전 탭 panel을 새 grid로 resize하고 활성 rect·사이드바를
    /// 갱신한다. 폭이 그대로면(같은 pt) 무동작 — SIGWINCH·재배치 storm 방지.
    fn setSidebarWidthPx(self: *AppSession, x_px: f64) void {
        if (self.scale_milli == 0 or !std.math.isFinite(x_px)) return;
        const clamped_x = if (x_px < 0) 0 else @min(x_px, @as(f64, @floatFromInt(std.math.maxInt(u32))));
        const px: u32 = @intFromFloat(clamped_x);
        const pt: u32 = std.math.clamp(px * 1000 / self.scale_milli, sidebar_min_pt, sidebar_max_pt);
        if (pt == self.sidebar_width_pt) return;
        self.sidebar_width_pt = pt;
        self.sidebar_width_px = ptToPx(pt, self.scale_milli);
        for (self.tabs.items) |tab| self.resizeTabPanes(tab); // 모든 탭의 term 폭이 바뀐다(best-effort)
        self.recomputeActivePaneRect();
        self.rebuildSidebar() catch {}; // sidebar_cols 환산이 바뀌므로 밴드 재생성
        self.metal_dirty = true;
    }

    /// 활성 탭이 split(panel 2개 이상)인가. 마우스 클릭으로 panel을 전환할지(단일이면 무동작) 판정에 쓴다.
    fn activeTabHasSplit(self: *AppSession) bool {
        return PaneTree.leafCount(self.activeTab().tree) > 1;
    }

    /// 활성 탭 안에서 포커스를 panel index로 옮긴다(입력/커서/IME/렌더가 따라간다). 활성 panel surface를
    /// 탭 대표(`surface_ptrs[active_tab]` = `app_window.active()`)와 `frame_loop.pump`에 재바인딩하고
    /// 활성 panel rect를 다시 계산한다. 같은 panel이거나 범위 밖이면 무동작. 탭 자체는 안 바꾼다.
    fn focusPane(self: *AppSession, pane_index: usize) void {
        const tab = self.activeTab();
        if (pane_index >= tab.panes.items.len or tab.active_pane == pane_index) return;
        tab.active_pane = pane_index;
        self.surface_ptrs.items[self.app_window.active_tab] = &tab.activeTerm().surface;
        self.app_window.tabs = self.surface_ptrs.items;
        self.recomputeActivePaneRect();
        self.metal_dirty = true;
    }

    /// 활성 탭에서 주어진 panel을 찾아 포커스한다(찾으면 true). 마우스/키보드 hit-test가 고른 `*Pane`으로
    /// 포커스를 옮길 때 쓴다(panel→index 매핑).
    fn focusPaneByPtr(self: *AppSession, pane: *Pane) bool {
        const tab = self.activeTab();
        for (tab.panes.items, 0..) |p, i| {
            if (p == pane) {
                self.focusPane(i);
                return true;
            }
        }
        return false;
    }

    /// 활성 pane 안에서 보이는 Term(가로 탭)을 term_index로 바꾼다(탭 전환). 활성 Term surface를 탭
    /// 대표(`surface_ptrs[active_tab]` = `app_window.active()`)에 재바인딩하고 좌표 origin을 다시 계산한다.
    /// 같은 Term이거나 범위 밖이면 무동작. pane/워크스페이스는 안 바꾼다.
    /// #2(#505 리뷰): 활성 Term이 가로 스크롤 창 밖이면 보이도록 tab_scroll_cols를 조정한다(focusTerm·⌘[]·클릭 후).
    /// 안 넘침(has_scroll=false)이면 무동작. 활성 탭 좌단이 창보다 왼쪽이면 좌단으로, 우단이 창보다 오른쪽이면 우단이 보이게.
    fn ensureActiveTermVisible(self: *AppSession, pane: *Pane) void {
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return;
        for (leaf_rects.items) |lr| {
            if (lr.leaf != pane) continue;
            const pb = self.paneBar(lr.rect, pane) orelse return;
            const m = barMetrics(pb.tabs, self.cell_width_px, pane.terms.items.len, self.buildChromeTokens().space.tab_width_cols, pane.tab_scroll_cols) orelse return;
            if (!m.has_scroll) return; // 안 넘침 — 다 보임
            const abs_start = @as(u32, @intCast(pane.active_term)) * m.tab_w;
            if (abs_start < m.scroll_cols) {
                pane.tab_scroll_cols = abs_start; // 좌단 잘림 → 좌단이 보이게
            } else if (abs_start + m.tab_w > m.scroll_cols + m.tab_cols) {
                pane.tab_scroll_cols = abs_start + m.tab_w - m.tab_cols; // 우단 잘림 → 우단이 보이게
            }
            return;
        }
    }

    fn focusTerm(self: *AppSession, term_index: usize) void {
        const pane = self.activePane();
        if (term_index >= pane.terms.items.len or pane.active_term == term_index) return;
        pane.active_term = term_index;
        self.surface_ptrs.items[self.app_window.active_tab] = &pane.activeTerm().surface;
        self.app_window.tabs = self.surface_ptrs.items;
        self.ensureActiveTermVisible(pane); // #2(리뷰): 스크롤 밖 탭 선택 시 보이게 tab_scroll_cols 조정
        self.recomputeActivePaneRect();
        self.metal_dirty = true;
    }

    /// 활성 pane의 Term을 delta(+1=다음, -1=이전)만큼 wrap-around로 옮긴다(⌘⌥]/⌘⌥[). Term이 1개면 무동작.
    fn focusTermRelative(self: *AppSession, delta: i64) void {
        const pane = self.activePane();
        const n = pane.terms.items.len;
        if (n <= 1) return;
        const cur: i64 = @intCast(pane.active_term);
        const next = @mod(cur + delta, @as(i64, @intCast(n)));
        self.focusTerm(@intCast(next));
    }

    /// 활성 워크스페이스의 split(pane)을 delta(+1=다음, -1=이전)만큼 wrap-around로 옮긴다(⌘]/⌘[). pane이
    /// 1개(분할 없음)면 무동작. focusPane이 active_pane·대표 surface·active rect를 갱신한다(focusTermRelative와 동형).
    fn focusPaneRelative(self: *AppSession, delta: i64) void {
        const tab = self.activeTab();
        const n = tab.panes.items.len;
        if (n <= 1) return;
        const cur: i64 = @intCast(tab.active_pane);
        const next = @mod(cur + delta, @as(i64, @intCast(n)));
        self.focusPane(@intCast(next));
    }

    /// 드래그 중인 Term 탭을 현재 마우스 x에 따라 소스 pane 바 안에서 재정렬한다(PR-E1: pane 내). 소스 pane의
    /// 바를 찾아 x→타겟 탭(tabIndexInBar, x clamp)을 잡고, 현재 인덱스와 다르면 pane.terms를 rotateMove하고
    /// active_term·drag_index를 타겟으로 옮긴다(드래그 탭이 활성으로 따라간다 — 같은 Term이라 대표 surface는
    /// 안 바뀜). 탭 1개거나 소스 pane을 못 찾으면(레이아웃 실패) 무동작. mouse가 drag(kind 2)에서 호출.
    fn dragTabTo(self: *AppSession, x_px: f64) void {
        const pane = self.tab_drag_pane orelse return;
        if (pane.terms.items.len <= 1) return;
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return;
        for (leaf_rects.items) |lr| {
            if (lr.leaf != pane) continue;
            const pb = self.paneBar(lr.rect, pane) orelse return;
            const m = barMetrics(pb.tabs, self.cell_width_px, pane.terms.items.len, self.buildChromeTokens().space.tab_width_cols, pane.tab_scroll_cols) orelse return;
            const target = m.tabIndex(pane.terms.items.len, x_px);
            if (target != self.tab_drag_index) {
                rotateMove(*Term, pane.terms.items, self.tab_drag_index, target);
                pane.active_term = target; // 드래그한 탭(활성)이 새 위치로 따라간다
                self.tab_drag_index = target;
                self.metal_dirty = true;
            }
            return;
        }
    }

    /// 탭 드래그 up(drop) 시 마우스가 '소스가 아닌 다른 pane'의 바 위면 그 pane으로 Term을 옮긴다(cross-pane,
    /// PR-E2). 같은 pane이거나 바 밖이면 무동작(pane 내 재정렬은 drag(2)가 이미 live로 처리했다). 드롭 위치
    /// (x)로 dst 안 삽입 인덱스를 잡는다. mouse가 up(kind 3)에서 호출.
    fn dropTabAt(self: *AppSession, x_px: f64, y_px: f64) void {
        const src = self.tab_drag_pane orelse return;
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return;
        for (leaf_rects.items) |lr| {
            const pb = self.paneBar(lr.rect, lr.leaf) orelse continue;
            if (pointInRect(x_px, y_px, pb.full)) { // 클릭 판정은 전체 바(라벨 포함)
                if (lr.leaf == src) return; // 같은 pane — 재정렬은 이미 됨
                const dst_count = lr.leaf.terms.items.len; // dst pane은 항상 Term ≥1(빈 pane은 collapse됨)
                const m = barMetrics(pb.tabs, self.cell_width_px, dst_count, self.buildChromeTokens().space.tab_width_cols, lr.leaf.tab_scroll_cols) orelse return;
                self.moveTermToPane(src, self.tab_drag_index, lr.leaf, m.tabIndex(dst_count, x_px));
                return;
            }
        }
        // 바가 아니면 어느 pane '본문' drop-zone(상/하/좌/우 절반) 위인지 — 그 방향으로 새 split을 만든다(④:
        // Term을 다른 pane 본문에 떨어뜨려 재배치). 단일 Term pane을 자기 본문에 떨어뜨리면 무의미라 무동작.
        for (leaf_rects.items) |lr| {
            const body = self.paneTermRect(lr.rect);
            if (paneDropZone(body, x_px, y_px)) |zone| {
                self.moveTermToNewSplit(src, self.tab_drag_index, lr.leaf, zone);
                return;
            }
        }
    }

    /// 드래그한 Term을 src에서 빼 '새 pane'에 담고, target pane의 자리(leaf)를 split{...}로 바꿔 zone 방향으로
    /// 끼운다(④: Term 탭을 다른 pane 본문에 드롭 → 거기 새 split). left/right=좌우(horizontal), top/bottom=
    /// 상하(vertical); left/top은 새 pane이 앞(a), right/bottom은 뒤(b). 모든 alloc을 먼저 해 실패 시 트리/terms를
    /// 안 건드린다(Term은 src에 남는다). 성공 후 새 pane으로 포커스, src가 비면 collapse, 전 panel resize.
    /// target==src인데 src Term이 1개뿐이면(자기를 자기로 split) 무의미 — 무동작.
    fn moveTermToNewSplit(self: *AppSession, src: *Pane, src_idx: usize, target: *Pane, zone: PaneDropZone) void {
        if (src_idx >= src.terms.items.len) return;
        if (target == src and src.terms.items.len <= 1) return;
        const tab = self.activeTab();
        const dir: app.SplitDirection = switch (zone) {
            .left, .right => .horizontal,
            .top, .bottom => .vertical,
        };
        const new_first = switch (zone) {
            .left, .top => true,
            .right, .bottom => false,
        };
        // 1) 실패 가능한 alloc을 먼저(트리/terms는 아직 안 건드림): 빈 새 pane + terms capacity + panes append + split.
        const new_pane = self.allocator.create(Pane) catch return;
        new_pane.* = .{};
        new_pane.terms.ensureTotalCapacity(self.allocator, 1) catch {
            self.allocator.destroy(new_pane);
            return;
        };
        tab.panes.append(self.allocator, new_pane) catch {
            new_pane.terms.deinit(self.allocator);
            self.allocator.destroy(new_pane);
            return;
        };
        const split = self.allocator.create(PaneTree.Split) catch {
            _ = tab.panes.pop();
            new_pane.terms.deinit(self.allocator);
            self.allocator.destroy(new_pane);
            return;
        };
        split.* = .{
            .direction = dir,
            .ratio = 0.5,
            .a = if (new_first) .{ .leaf = new_pane } else .{ .leaf = target },
            .b = if (new_first) .{ .leaf = target } else .{ .leaf = new_pane },
        };
        // 2) 트리에서 target leaf → split{...} 교체. 미발견이면 전부 원복(트리는 변형 전이라 무변).
        if (!PaneTree.replaceLeaf(&tab.tree, target, .{ .split = split })) {
            self.allocator.destroy(split);
            _ = tab.panes.pop();
            new_pane.terms.deinit(self.allocator);
            self.allocator.destroy(new_pane);
            return;
        }
        // 3) 이제 infallible: src에서 Term을 빼 새 pane으로(capacity 확보됨). Term은 heap-pin이라 surface/reader 안 움직임.
        const term = src.terms.orderedRemove(src_idx);
        new_pane.terms.appendAssumeCapacity(term);
        new_pane.active_term = 0;
        src.active_term = if (src.terms.items.len == 0) 0 else @min(src.active_term, src.terms.items.len - 1);
        self.hovered_tab = null; // 트리/탭 변경 — stale 호버 정리
        if (src.terms.items.len == 0) self.collapsePaneIn(tab, src); // src가 비면 collapse(removeLeaf)
        // 4) 새 pane으로 포커스 + 대표 surface 재바인딩 + 전 panel을 새 leaf rect grid로 resize + 좌표 재계산.
        _ = self.focusPaneByPtr(new_pane);
        self.resizeActiveTabPanes() catch {};
        self.recomputeActivePaneRect();
        self.metal_dirty = true;
    }

    /// 탭 드래그 중 마우스가 올라간 드롭 타겟을 판정한다(④b 하이라이트용 — dropTabAt의 커밋 판정과 같은 우선순위).
    /// 다른 pane 탭 바 위 → {pane, zone=null}(이동). 자기 바 → null(재정렬, 드롭 아님). pane 본문 → {pane, zone}
    /// (그 방향 split) — 단, target==src인데 Term 1개뿐이면 무동작이라 null. 레이아웃 실패면 null.
    fn computeDropTarget(self: *AppSession, x_px: f64, y_px: f64) ?DropTarget {
        const src = self.tab_drag_pane orelse return null;
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return null;
        for (leaf_rects.items) |lr| {
            const bar = self.paneBarRect(lr.rect) orelse continue;
            if (pointInRect(x_px, y_px, bar)) {
                if (lr.leaf == src) return null; // 자기 바 — 재정렬(드롭 아님)
                return .{ .pane = lr.leaf, .zone = null };
            }
        }
        for (leaf_rects.items) |lr| {
            const body = self.paneTermRect(lr.rect);
            if (paneDropZone(body, x_px, y_px)) |zone| {
                if (lr.leaf == src and src.terms.items.len <= 1) return null; // 자기-split 무의미
                return .{ .pane = lr.leaf, .zone = zone };
            }
        }
        return null;
    }

    fn dropTargetEql(a: ?DropTarget, b: ?DropTarget) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.?.pane == b.?.pane and a.?.zone == b.?.zone;
    }

    /// 드롭 타겟을 바꾼다 — 바뀌면 metal_dirty(하이라이트 다시 그림). 같은 타겟이면 무동작(매 drag 이벤트 재투영 방지).
    fn setDropTarget(self: *AppSession, target: ?DropTarget) void {
        if (dropTargetEql(self.tab_drop_target, target)) return;
        self.tab_drop_target = target;
        self.metal_dirty = true;
    }

    /// 탭 드래그 중이면 현재 드롭 타겟 zone을 반투명 하이라이트 셀로 out에 append한다(④b). 본문 절반(split)이면
    /// 그 절반을, 탭 바(이동)면 그 pane 바를 칠한다. 행마다 폭 만큼의 sentinel-bg 셀 1개(premultiplied alpha).
    /// 드래그 중이 아니거나 타겟이 없으면 무동작. divider처럼 overlay(터미널 위·커서 아래)로 넘긴다.
    fn appendDropTargetHighlight(self: *AppSession, out: *std.ArrayList(metal_frame.NativeMetalCell)) void {
        if (!self.tab_drag_active) return;
        const target = self.tab_drop_target orelse return;
        const cw = self.cell_width_px;
        const ch = self.cell_height_px;
        if (cw == 0 or ch == 0) return;
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return;
        const bg = premultipliedRgba(self.sidebarActiveBg() & 0x00FF_FFFF, 0x55); // 반투명 강조(≈33%)
        for (leaf_rects.items) |lr| {
            if (lr.leaf != target.pane) continue;
            const zone_rect = if (target.zone) |z| halfRect(self.paneTermRect(lr.rect), z) else (self.paneBarRect(lr.rect) orelse lr.rect);
            if (zone_rect.w == 0 or zone_rect.h == 0) return;
            const cols = @min(@max(zone_rect.w / cw, 1), @as(u32, std.math.maxInt(u16)));
            var y = zone_rect.y;
            const y_end = zone_rect.y + zone_rect.h;
            while (y < y_end) : (y += ch) out.append(self.allocator, sentinelBgCell(0, @intCast(cols), bg, zone_rect.x, y)) catch return;
            return;
        }
    }

    /// 탭 드래그 중이면 끌리는 Term의 제목을 담은 'floating 탭'(박스 + 제목) frame을 만들어 PaneFrame으로 돌려준다
    /// (커서 중심에 배치). built_frames가 소유(deinit)하고, 반환 PaneFrame은 호출자가 pane_frames '맨 뒤'(맨 위)에
    /// 넣는다. 드래그 중이 아니거나 메트릭/제목을 못 구하면 null. macOS 렌더 패스(CoreText)에서만 부른다.
    fn buildFloatingTabFrame(
        self: *AppSession,
        builder: coretext_frame_builder.CoreTextFrameBuilder,
        built_frames: *std.ArrayList(renderer.RenderFrame),
    ) ?metal_frame.PaneFrame {
        if (!self.tab_drag_active) return null;
        const cw = self.cell_width_px;
        const ch = self.cell_height_px;
        if (cw == 0 or ch == 0) return null;
        const pane = self.tab_drag_pane orelse return null;
        if (self.tab_drag_index >= pane.terms.items.len) return null;
        // 드래그 미리보기 라벨도 탭과 같은 해석(rename custom_name 우선). 탭바와 floating 미리보기가 어긋나지 않게.
        const title = termLabel(pane.terms.items[self.tab_drag_index]);
        const cols: u16 = @intCast(std.math.clamp(title.len + 2, @as(usize, 8), @as(usize, 24))); // 제목+패딩, [8,24]
        const fg: terminal.Color = .{ .rgb = self.appearance.theme.foreground };
        const bg: terminal.Color = .{ .rgb = self.appearance.theme.sidebar_active }; // 솔리드 박스 색(활성 강조색)
        const dl = coretext_frame_builder.buildFloatingTabDrawList(self.allocator, title, cols, fg, bg) catch return null;
        var f = builder.buildFromDrawList(self.allocator, dl, &self.renderer_state) catch return null;
        built_frames.append(self.allocator, f) catch {
            f.deinit(self.allocator);
            return null;
        };
        // 커서 중심으로 박스 배치(왼쪽 위가 음수면 0으로 clamp).
        const box_w: f64 = @floatFromInt(@as(u32, cols) * cw);
        const ox = self.tab_drag_x - box_w / 2;
        const oy = self.tab_drag_y - @as(f64, @floatFromInt(ch)) / 2;
        return .{
            .frame = f,
            .origin_x = if (ox > 0) @intFromFloat(@min(ox, @as(f64, @floatFromInt(std.math.maxInt(u32))))) else 0,
            .origin_y = if (oy > 0) @intFromFloat(@min(oy, @as(f64, @floatFromInt(std.math.maxInt(u32))))) else 0,
            .colors = .{ .default_fg = self.appearance.theme.foreground },
        };
    }

    /// 드래그한 Term을 src pane의 src_idx에서 빼 dst pane의 dst_idx에 넣는다(cross-pane 이동). dst를 활성 pane으로,
    /// 옮긴 Term을 dst의 활성 탭으로 만들고, src가 비면 collapse한다. 그 뒤 모든 panel을 새 leaf rect grid로
    /// resize + 좌표 재계산. insert 실패는 src로 원복한다. src==dst거나 인덱스 밖이면 무동작. Term은 heap-pin
    /// (`*Term`)이라 pane 사이를 포인터로 옮겨도 surface/reader 주소가 안 움직인다(runtime link도 그대로).
    fn moveTermToPane(self: *AppSession, src: *Pane, src_idx: usize, dst: *Pane, dst_idx: usize) void {
        if (src == dst or src_idx >= src.terms.items.len) return;
        const term = src.terms.orderedRemove(src_idx);
        const idx = @min(dst_idx, dst.terms.items.len);
        dst.terms.insert(self.allocator, idx, term) catch {
            src.terms.insert(self.allocator, @min(src_idx, src.terms.items.len), term) catch {}; // 원복
            return;
        };
        src.active_term = if (src.terms.items.len == 0) 0 else @min(src.active_term, src.terms.items.len - 1);
        dst.active_term = idx; // 옮긴 Term을 dst의 활성으로

        self.hovered_tab = null; // 트리/탭이 바뀌니 stale 호버 비움
        if (src.terms.items.len == 0) self.collapsePane(src); // 마지막 Term이 나갔으면 src collapse(형제로)

        // dst를 활성 pane으로(collapse로 인덱스가 밀렸을 수 있어 다시 찾는다) + 대표 surface 재바인딩.
        const tab = self.activeTab();
        for (tab.panes.items, 0..) |p, i| {
            if (p == dst) {
                tab.active_pane = i;
                break;
            }
        }
        self.surface_ptrs.items[self.app_window.active_tab] = &dst.activeTerm().surface;
        self.app_window.tabs = self.surface_ptrs.items;
        self.resizeActiveTabPanes() catch {}; // 옮긴 Term을 dst term rect grid로(+ src 형제가 빈자리 확장)
        self.recomputeActivePaneRect();
        self.metal_dirty = true;
    }

    /// 비어 있는 pane(모든 Term이 옮겨 나감/exit)을 활성 탭에서 collapse한다. cross-pane 이동(moveTermToPane)이
    /// 쓰는 활성 탭 전용 래퍼 — 임의 탭은 collapsePaneIn을 직접 쓴다.
    fn collapsePane(self: *AppSession, pane: *Pane) void {
        self.collapsePaneIn(self.activeTab(), pane);
    }

    /// 주어진 탭(tab)에서 비어 있는 pane을 트리에서 떼고(removeLeaf, 형제로 collapse) panes에서 빼고 해제한다.
    /// split에서만(형제가 있을 때) 일어나므로 단일 pane이면 무동작. active_pane은 범위 clamp만(호출자가 필요 시
    /// 다시 잡는다). pane.terms는 비어 있어 destroyPane이 리스트·Pane만 해제한다. 활성/배경 탭 모두에 쓴다.
    fn collapsePaneIn(self: *AppSession, tab: *Tab, pane: *Pane) void {
        if (tab.panes.items.len <= 1) return;
        const freed_split = PaneTree.removeLeaf(&tab.tree, pane) orelse return;
        self.invalidateForFreedSplit(freed_split); // divider_drag가 이 split이면 표적 null(destroy 전, 무관 드래그는 보존)
        self.allocator.destroy(freed_split);
        for (tab.panes.items, 0..) |p, i| {
            if (p == pane) {
                _ = tab.panes.orderedRemove(i);
                break;
            }
        }
        self.destroyPane(pane);
        if (tab.active_pane >= tab.panes.items.len) tab.active_pane = tab.panes.items.len - 1;
    }

    const TermLoc = struct { tab_index: usize, pane: *Pane, term_index: usize };

    /// 모든 탭/panel을 훑어 첫 'terminated'(셸 exit 관측 완료) Term의 위치를 찾는다(reap 대상). 없으면 null.
    fn findTerminatedTerm(self: *AppSession) ?TermLoc {
        for (self.tabs.items, 0..) |tab, ti| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items, 0..) |term, tj| {
                    if (term.terminated) return .{ .tab_index = ti, .pane = pane, .term_index = tj };
                }
            }
        }
        return null;
    }

    /// 셸이 exit한 개별 Term을 자동으로 닫는다(exit 자동 collapse, PR5b). 살아있는 Term이 하나라도
    /// 있으면 죽은 Term을 **Term → pane(빈 pane collapse) → 워크스페이스(빈 탭 close)** cascade로 정리한다.
    /// 전부 죽었으면(단일/마지막 Term) reap하지 않고 세션 종료 latch(allTabsTerminated)에 맡긴다 — 기존 단일 탭
    /// exit→창 닫힘 동작을 보존. 구조가 매번 바뀌므로 한 번에 하나씩 닫고 다시 스캔한다(stale 인덱스/포인터 방지).
    /// guard는 폭주 backstop(정상이면 죽은 Term 수만큼만 돈다). tick의 drain이 종료를 관측한 뒤 부른다.
    fn reapTerminatedTerms(self: *AppSession) void {
        if (self.termination_finished) return;
        var guard: usize = 0;
        while (guard < 4096) : (guard += 1) {
            if (self.allTabsTerminated()) return; // 전부 죽음 → 세션 종료가 마지막을 닫는다(여기선 reap 안 함)
            const loc = self.findTerminatedTerm() orelse return; // 더 닫을 죽은 Term 없음
            self.closeTermAt(loc.tab_index, loc.pane, loc.term_index);
        }
    }

    /// 임의 탭(tab_index)의 pane에서 term_index Term을 닫고 cascade한다(exit 자동 정리·일반화). Term을 teardown·
    /// 제거하고: pane에 Term이 남으면 active_term clamp, 비면 split이면 collapse, 단일 pane이면 워크스페이스(탭)를
    /// close한다. 활성/배경 탭 모두 대상이라 closeActiveTerm(활성 전용)과 달리 위치를 인자로 받는다.
    fn closeTermAt(self: *AppSession, tab_index: usize, pane: *Pane, term_index: usize) void {
        const tab = self.tabs.items[tab_index];
        const term = pane.terms.orderedRemove(term_index);
        self.destroyTerm(term);
        if (pane.terms.items.len > 0) {
            if (pane.active_term >= pane.terms.items.len) pane.active_term = pane.terms.items.len - 1;
            self.refreshAfterReap(tab_index);
        } else if (tab.panes.items.len > 1) {
            self.collapsePaneIn(tab, pane); // 빈 pane을 형제로 collapse(active_pane clamp 포함)
            self.refreshAfterReap(tab_index);
        } else {
            self.closeTab(tab_index); // 탭의 마지막 pane이 비었다 — 워크스페이스 close(대표 surface·active_tab은 closeTab가 처리)
        }
    }

    /// reap으로 구조가 바뀐 탭의 대표 surface를 그 탭의 현재 활성 Term으로 재바인딩하고(닫힌 Term을 가리키던
    /// stale/dangling 방지) panel을 새 leaf rect로 resize한다(collapse면 형제가 빈자리 확장 — 배경 탭도 전환
    /// 즉시 올바른 크기). 활성 탭이면 좌표 origin도 재계산하고 redraw를 표시한다(배경 탭 변경은 화면에 안 보임).
    fn refreshAfterReap(self: *AppSession, tab_index: usize) void {
        const tab = self.tabs.items[tab_index];
        self.surface_ptrs.items[tab_index] = &tab.activeTerm().surface;
        self.app_window.tabs = self.surface_ptrs.items;
        self.resizeTabPanes(tab);
        self.hovered_tab = null; // 트리/탭 변경 — stale 호버 정리
        if (tab_index == self.app_window.active_tab) {
            self.recomputeActivePaneRect();
            self.metal_dirty = true;
        }
    }

    /// 활성 pane에 새 Term(터미널 탭)을 띄우고 그 탭으로 포커스한다(⌘T). 활성 pane의 현재 rect grid
    /// 크기로 새 셸을 spawn해 pane.terms에 더한다. spawn/alloc 실패는 errdefer로 원복하고 무시(pane 불변).
    fn newTermInActivePane(self: *AppSession) !void {
        const pane = self.activePane();
        const size = gridFromRectPx(self.cell_width_px, self.cell_height_px, self.active_pane_rect.w, self.active_pane_rect.h);
        var cfg = self.new_tab_config;
        cfg.size = size;
        const term = try self.createTerm(
            spawnRequest(cfg, self.loaded_config.config.term, self.new_tab_zdotdir, self.new_tab_ssh_bin),
            size,
            cfg.queue_capacity,
            "Maru",
            commandName(cfg.command_kind),
        );
        errdefer self.destroyTerm(term);
        try pane.terms.append(self.allocator, term);
        self.focusTerm(pane.terms.items.len - 1); // 새 Term으로 포커스(surface 재바인딩·rect·dirty)
    }

    /// 키보드 pane 이동 — 활성 panel에서 direction 방향의 인접 panel로 포커스를 옮긴다(있으면). split이 없거나
    /// 그 방향에 panel이 없으면 무동작(best-effort: leaf rect 레이아웃 OOM도 그냥 이동 안 함). 활성 탭 leaf
    /// rect를 펴 paneInDirection으로 대상을 고른 뒤 focusPaneBySurface로 옮긴다.
    fn focusPaneInDirection(self: *AppSession, dir: FocusDirection) void {
        if (!self.activeTabHasSplit()) return;
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return;
        if (paneInDirection(leaf_rects.items, self.activePane(), dir)) |pane| {
            _ = self.focusPaneByPtr(pane);
        }
    }

    /// 활성 panel을 direction으로 둘로 나눈다(사실상 표준 멀티플렉서 split 동작 참고 — 코드 미참고). 활성 panel의
    /// 현재 leaf rect를 splitRect로 a(기존)·b(새)로 나눠, b 크기로 새 셸 panel을 spawn하고, 트리에서 활성
    /// leaf를 split{a: 기존 leaf, b: 새 leaf}로 교체하고, 기존 panel을 a 크기로 줄인 뒤 새 panel로 포커스를
    /// 옮긴다. 단일 panel 탭이면 첫 분할(2개), 이미 split이면 활성 panel이 다시 나뉜다(중첩). spawn/alloc
    /// 실패는 errdefer로 트리/탭을 원복한다(부분 상태를 남기지 않는다).
    fn splitActivePane(self: *AppSession, direction: app.SplitDirection) !void {
        const tab = self.activeTab();
        const active = tab.activePane();

        // 1) 활성 panel의 현재 rect를 레이아웃에서 찾는다(없으면 — 있어선 안 되지만 — 분할 안 함).
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        try self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects);
        var active_rect: ?app.SplitRect = null;
        for (leaf_rects.items) |lr| {
            if (lr.leaf == active) {
                active_rect = lr.rect;
                break;
            }
        }
        const arect = active_rect orelse return error.ActivePaneNotInTree;

        // 2) active rect를 direction·0.5로 a(기존)·b(새)로 나눈 grid.
        // 두 자식 panel 각자 상단 탭 바를 예약하므로, Term grid는 leaf rect가 아니라 paneTermRect(바 아래)로 잰다.
        const parts = app.splitRect(arect, direction, 0.5);
        const a_term = self.paneTermRect(parts.a);
        const b_term = self.paneTermRect(parts.b);
        const a_size = gridFromRectPx(self.cell_width_px, self.cell_height_px, a_term.w, a_term.h);
        const b_size = gridFromRectPx(self.cell_width_px, self.cell_height_px, b_term.w, b_term.h);

        // 3) 새 panel을 b 크기로 spawn(새 셸). 실패하면 트리/탭은 그대로다.
        var cfg = self.new_tab_config;
        cfg.size = b_size;
        const new_pane = try self.createPane(
            spawnRequest(cfg, self.loaded_config.config.term, self.new_tab_zdotdir, self.new_tab_ssh_bin),
            b_size,
            cfg.queue_capacity,
            "Maru",
            commandName(cfg.command_kind),
        );
        errdefer self.destroyPane(new_pane);
        try tab.panes.append(self.allocator, new_pane);
        errdefer _ = tab.panes.pop();

        // 4) split 노드를 heap에 만들고 트리에서 활성 leaf를 split{a: 기존, b: 새}로 교체.
        const split = try self.allocator.create(PaneTree.Split);
        errdefer self.allocator.destroy(split);
        split.* = .{
            .direction = direction,
            .ratio = 0.5,
            .a = .{ .leaf = active },
            .b = .{ .leaf = new_pane },
        };
        if (!PaneTree.replaceLeaf(&tab.tree, active, .{ .split = split })) {
            return error.ActivePaneNotInTree; // errdefer가 split·pane을 원복(트리는 변형 전이라 무변)
        }

        // 5) 기존 panel의 모든 Term을 a 크기로 줄인다(PTY winsize 포함). 죽은 PTY 등의 실패는 무시(split 자체는 성공).
        for (active.terms.items) |term| self.runtime.resize(term.surface.id, a_size, self.io) catch {};

        // 6) 새 panel로 포커스 이동(멀티플렉서 split 관행). focusPane이 탭 대표 surface(= app_window.active())·
        //    frame_loop pump 재바인딩 + 활성 panel rect 재계산 + metal_dirty를 한 곳에서 한다. 탭 인덱스는
        //    그대로라 사이드바 갱신은 불요.
        self.focusPane(tab.panes.items.len - 1);
    }

    /// 한 Term(터미널)을 heap-pin(`create`)으로 만든다 — 셸 PTY spawn → surface init → runtime attach → pump.
    /// `LivePtySession` reader가 `&term.live_pty.reader`를 잡으므로 Term은 heap 고정(ArrayList는 `*Term`만 들어
    /// realloc·탭 재정렬에도 본체 안 움직임). surface_id·pty_id 발급(next_id), 부분 실패는 errdefer로 정리
    /// (create→live_pty→surface 역순). Pane에 거는 건 호출자(createPane/⌘T)가 한다.
    fn createTerm(
        self: *AppSession,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
        queue_capacity: usize,
        title: []const u8,
        command: []const u8,
    ) !*Term {
        const term = try self.allocator.create(Term);
        errdefer self.allocator.destroy(term);
        term.* = .{};

        const id = self.next_id; // surface_id·pty_id 동일 값(서로 다른 네임스페이스라 무방), 재사용 안 함
        try term.live_pty.init(self.io, self.allocator, id, request, queue_capacity);
        errdefer term.live_pty.deinit();
        term.live_initialized = true;

        term.surface = try app.Surface.init(self.allocator, id, size);
        errdefer term.surface.deinit();
        // config 스크롤백 ring 크기를 주입한다(모든 surface가 이 chokepoint를 지난다 — init 첫 탭·새 탭·split·
        // restore). lazy-alloc(첫 scroll) 전이라 안전. 0이면 스크롤백 비활성.
        term.surface.core.max_scrollback = self.loaded_config.config.scrollback.lines;
        // config theme.palette(ANSI 16색 base)를 코어에 주입한다 — OSC 4 query 응답이 렌더(metal_frame)와 같은
        // 우선순위(OSC4 override > config base > xterm256)를 보도록(화면·보고 정합). RIS/OSC104는 override만 리셋.
        term.surface.core.setConfigPalette(self.appearance.theme.palette);
        term.surface.title = title;
        term.surface.command = command;

        // interactive 셸(login 래핑)만 리더 코어-처리를 켠다 — 렌더 tick에 안 묶여 OSC 응답이 즉시 나간다
        // (docs/io-render-threading.md PR3). controlled_smoke(login=false, 테스트)는 큐-드레인 유지.
        _ = try term.live_pty.attachSurface(&self.runtime, &term.surface, request.login);
        term.pump = term.live_pty.pump(&self.runtime);
        self.next_id += 1;
        return term;
    }

    /// 한 Term을 teardown하고 heap 해제한다(closeAndDetach → live_pty.deinit(reader join) → surface.deinit →
    /// destroy). runtime이 살아 있을 때만 detach. createPane/⌘T errdefer·close·split 실패 정리에 쓴다.
    /// (deinit은 runtime.deinit 순서 때문에 이 2-pass를 직접 풀어 쓴다 — 여기 쓰지 않는다.)
    fn destroyTerm(self: *AppSession, term: *Term) void {
        // rename 대상이 이 Term이면 stale 포인터 방지로 비운다(teardown 중 — 직접 null, closeRename 부수효과 없이).
        if (self.renamingTerm(term)) {
            self.rename = null;
            self.rename_input.clear();
        }
        // 컨텍스트 메뉴 대상이 이 Term이면 메뉴를 닫고 대상을 비운다(stale 포인터 방지).
        if (self.context_menu_target) |t| if (std.meta.activeTag(t) == .term and t.term == term) {
            self.context_menu_target = null;
            self.chrome_host.context_menu.hide();
        };
        if (term.live_initialized) {
            if (self.runtime_initialized) term.live_pty.closeAndDetach(&self.runtime);
            term.live_pty.deinit();
            term.live_initialized = false;
        }
        // custom_name(사용자 rename, owned)만 해제 — surface.title은 정적/borrowed라 해제 안 함. Surface.deinit에
        // allocator가 없어 owned 문자열 해제는 세션 allocator를 가진 이 funnel에서 한다.
        if (term.surface.custom_name) |n| self.allocator.free(n);
        // git 브랜치 캐시(owned)도 해제.
        if (term.git_branch) |b| self.allocator.free(b);
        if (term.git_branch_cwd) |c| self.allocator.free(c);
        term.auto_title.deinit(self.allocator);
        term.surface.deinit();
        self.allocator.destroy(term);
    }

    /// 한 panel(Pane)을 heap-pin으로 만든다 — Term 1개를 담은 컨테이너. 탭→pane 모델에서 Pane은 여러 Term을
    /// 가로 탭으로 들 수 있고(⌘T가 추가), 생성 시엔 1개로 시작한다. heap-pin(`*Pane`)이라 트리 회전·ArrayList
    /// realloc에도 본체가 안 움직인다(SplitTree leaf가 이 `*Pane`을 가리킴). 부분 실패는 errdefer로 정리.
    fn createPane(
        self: *AppSession,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
        queue_capacity: usize,
        title: []const u8,
        command: []const u8,
    ) !*Pane {
        const pane = try self.allocator.create(Pane);
        errdefer self.allocator.destroy(pane);
        pane.* = .{};
        errdefer pane.terms.deinit(self.allocator);

        const term = try self.createTerm(request, size, queue_capacity, title, command);
        errdefer self.destroyTerm(term);
        try pane.terms.append(self.allocator, term);
        pane.active_term = 0;
        return pane;
    }

    /// 한 panel을 teardown하고 heap 해제한다 — 담긴 모든 Term을 destroyTerm한 뒤 terms 리스트·Pane을 해제.
    /// createPane errdefer·closeTab·closeActivePane·split 실패 정리에 쓴다. **모든 Pane 해제의 단일 chokepoint라,
    /// 해제 직전 구조-무효화 계약(invalidateForFreedPane)을 부른다 — 이 Pane을 가리키던 호버/드래그 포인터를 정리.**
    fn destroyPane(self: *AppSession, pane: *Pane) void {
        self.invalidateForFreedPane(pane); // S1: 포인터 비교는 해제 전 주소로(deref 없음) — 흩어진 null화 대체
        for (pane.terms.items) |term| self.destroyTerm(term);
        if (pane.custom_name) |n| self.allocator.free(n); // 사용자 rename(owned) 해제
        pane.terms.deinit(self.allocator);
        self.allocator.destroy(pane);
    }

    /// 새 탭을 만든다 — Tab과 첫 panel을 heap-pin하고, panel의 surface로 단일-leaf 트리를 세우고,
    /// `tabs`/`surface_ptrs`에 추가하고 `app_window.tabs`를 갱신하고 새 탭을 활성으로 만든다. 새 Tab 포인터
    /// 반환. 부분 실패는 errdefer로 정리한다(create tab→panes 리스트→pane→append 역순).
    fn createTab(
        self: *AppSession,
        request: maru.pty.SpawnRequest,
        size: terminal.Size,
        queue_capacity: usize,
        title: []const u8,
        command: []const u8,
    ) !*Tab {
        const tab = try self.allocator.create(Tab);
        errdefer self.allocator.destroy(tab);
        tab.* = .{};
        errdefer tab.panes.deinit(self.allocator); // 실패 시 panes 리스트 backing 해제(pane은 아래 errdefer가)

        const pane = try self.createPane(request, size, queue_capacity, title, command);
        errdefer self.destroyPane(pane);

        try tab.panes.append(self.allocator, pane);
        tab.active_pane = 0;
        // SplitTree 루트를 단일 leaf로 — 이 탭은 panel 1개(= 풀 탭 영역). leaf는 Pane을 가리킨다(Pane이
        // heap-pin이라 포인터 안정). split이 이 leaf를 split 노드로 나눈다.
        tab.tree = .{ .leaf = pane };

        try self.tabs.append(self.allocator, tab);
        errdefer _ = self.tabs.pop();
        try self.surface_ptrs.append(self.allocator, &pane.activeTerm().surface); // 탭 대표 = 활성 panel의 활성 Term surface
        // surface_ptrs가 realloc됐을 수 있으니 app_window.tabs를 새 items로 재바인딩(stale 슬라이스 방지).
        self.app_window.tabs = self.surface_ptrs.items;
        self.app_window.active_tab = self.tabs.items.len - 1;
        self.recomputeActivePaneRect(); // 새 탭이 활성이 됐으니 좌표 origin 갱신(init 중엔 사이드바 폭이 아직
        // 0이라 init 끝의 recompute가 다시 잡고, post-init newTab은 여기서 바로 맞는다)
        // 탭 집합/활성이 바뀌었으니 사이드바 셀을 다시 만든다. 실패는 탭 생성을 무르지 않고(탭은 이미
        // 완성·append됨) 빈 사이드바로 degrade한다 — 여기서 try면 errdefer가 멀쩡한 탭을 헐어버린다.
        self.rebuildSidebar() catch {};
        return tab;
    }

    /// 활성 탭을 바꾼다(`app_window.selectTab`). 성공하면 활성 탭이 바뀌었으니 재드로우를 위해
    /// metal_dirty를 세우고 true. 범위 밖 index면 false(활성 불변). 입력/렌더는 activeSurface가
    /// active_tab을 따라가므로 이것만으로 라우팅이 바뀐다.
    pub fn switchTab(self: *AppSession, index: usize) bool {
        if (!self.app_window.selectTab(index)) return false;
        // 전환한 탭을 현재 창 grid로 맞춘다. resize()는 활성 탭만 만지고 last_resize_size는 세션-전역이라, 다른
        // 탭이 활성인 동안 창이 리사이즈됐거나 복원으로 저장 grid로 spawn된 탭은 전환 시점까지 stale grid다 —
        // 여기서 lazy 보정한다(복원·일반 둘 다). best-effort: 죽은 PTY 등은 무시(resizeTabPanes 계약).
        self.resizeTabPanes(self.activeTab());
        self.metal_dirty = true;
        self.recomputeActivePaneRect(); // 새 탭의 활성 panel rect로 좌표 origin 갱신
        self.rebuildSidebar() catch {}; // 활성 탭이 바뀌었으니 하이라이트 밴드를 새 행으로 옮긴다
        return true;
    }

    /// **세션-트리 구조-무효화 계약(S1)의 단일 출처.** 한 Pane이 해제되기 직전 destroyPane이 부른다 — 모든
    /// 트리 변형(closeTab·closeActivePane·collapsePaneIn·applyWorkspaceWindow·reap)이 노드 해제 시 destroyPane을
    /// 거치므로, 이 한 지점이 흩어진 null화 없이 stale 포인터 UAF를 구조적으로 막는다(스냅샷 가드는 UAF를 못 잡는다
    /// — docs/layering-and-portability.md §6, [[devsession-undefined-test-field-trap]]).
    ///
    /// **표적 무효화**(`*Pane` 포인터): 해제되는 바로 이 Pane을 가리키던 hover/drag 포인터만 비운다 — 다른 Pane을
    /// 가리키면 유지한다. 이게 핵심: 무관한 Pane 닫힘(또는 reap)이 진행 중 탭 드래그/호버를 끊지 않으면서, 드래그
    /// 중인 Pane 자체가 reap으로 해제되는 비동기 UAF는 닫는다(tick reap ↔ 마우스 드래그가 메인 스레드에서 교차).
    ///
    /// **보수적 무효화**(`hovered_slot`=슬롯 인덱스): 슬롯 인덱스는 pane 수에 의존해 어느 Pane
    /// 해제든 stale이 되므로 비운다(캐시라 다음 이동이 재설정). `divider_drag`(*Split)는 여기서 안 건드린다 —
    /// removeLeaf가 떼어낸 split을 돌려주므로 그 호출처(collapsePaneIn·closeActivePane)가 invalidateForFreedSplit으로
    /// **표적** 무효화하고, 트리 통째 해제(destroyTabStandalone)는 거기서 따로 비운다.
    fn invalidateForFreedPane(self: *AppSession, pane: *Pane) void {
        if (self.hovered_tab) |ht| {
            if (ht.pane == pane) self.hovered_tab = null;
        }
        if (self.tab_drag_pane == pane) {
            self.tab_drag_pane = null;
            self.tab_drag_active = false; // 드래그 대상이 사라졌으니 제스처 중단(다음 mouse-up은 no-op)
        }
        // rename 대상이 이 pane이면 stale 포인터가 안 되게 비운다(teardown 중이라 closeRename의 부수효과 없이 직접).
        if (self.renamingPane(pane)) {
            self.rename = null;
            self.rename_input.clear();
        }
        // 컨텍스트 메뉴 대상이 이 pane이면 메뉴를 닫고 대상을 비운다(stale 포인터 방지).
        if (self.context_menu_target) |t| if (std.meta.activeTag(t) == .pane and t.pane == pane) {
            self.context_menu_target = null;
            self.chrome_host.context_menu.hide();
        };
        self.hovered_slot = null;
        // chrome ChromeState 훅(현재 무동작). 핸들 기반 드래그 상태가 C2/C3서 ChromeState로 이주하면 여기 한 줄이
        // 그 무효화를 떠맡는다 — destroyPane 단일 chokepoint라 호출처는 그대로 따라온다(docs/chrome-strategy.md §5.5).
        self.chrome_host.interaction.invalidateForStructuralChange();
    }

    /// split 노드가 해제되기 직전(removeLeaf 반환 → destroy 사이) 부른다 — divider_drag가 **바로 이 split**을
    /// 가리키면 표적 null한다(다른 split이면 유지 → 무관한 reap-collapse가 진행 중 divider 드래그를 안 끊는다).
    /// removeLeaf가 freed split을 surface하게 바뀌어 가능해진 표적 무효화(예전 보수적 blanket-null 대체).
    fn invalidateForFreedSplit(self: *AppSession, split: *PaneTree.Split) void {
        if (self.divider_drag == split) self.divider_drag = null;
    }

    /// 탭을 닫는다. 마지막 한 개면 창(세션)을 닫는다 — 탭을 헐지 않고 종료를 latch해 기존 terminate/
    /// deinit 경로가 정리하게 한다(빈 tabs 리스트로 activeSurface가 패닉하는 걸 피한다). 그 외엔 teardown
    /// (deinit과 같은 순서: closeAndDetach(runtime) → live_pty.deinit(reader join) → surface.deinit → Tab
    /// heap 해제) 후 tabs/surface_ptrs에서 빼고 app_window.tabs를 재바인딩하고 active_tab을 clamp한다
    /// (reselectAfterClose). 범위 밖 index면 무동작.
    pub fn closeTab(self: *AppSession, index: usize) void {
        if (index >= self.tabs.items.len) return;
        if (self.tabs.items.len == 1) {
            // 마지막 탭 = 창 닫기. close()와 같은 종료 latch — 탭은 deinit이 정리한다.
            self.ended_seen = true;
            self.activeSurface().process_state = .exited;
            self.metal_dirty = true;
            return;
        }

        const tab = self.tabs.orderedRemove(index);
        _ = self.surface_ptrs.orderedRemove(index);
        // 길이가 줄었으니(realloc은 안 해도) app_window.tabs를 새 items로 재바인딩(stale 슬라이스 방지).
        self.app_window.tabs = self.surface_ptrs.items;

        // teardown — destroyTabStandalone가 모든 panel destroyPane(closeAndDetach → reader join → surface deinit
        // → free) + tree split 노드 해제 + panes/Tab 해제. tabs/surface_ptrs는 위에서 이미 뺐다(이 헬퍼는 컬렉션을
        // 안 건드림). applyWorkspaceWindow와 같은 teardown 단일 출처라 순서가 갈라지지 않는다.
        self.destroyTabStandalone(tab);

        self.app_window.active_tab = reselectAfterClose(index, self.app_window.active_tab, self.tabs.items.len);
        self.recomputeActivePaneRect(); // 새 활성 탭의 활성 panel rect로 좌표 origin 갱신
        // 이 탭의 Pane/split 노드가 해제됐으니 stale 호버·divider 포인터를 비워야 하는데, 위 destroyTabStandalone의
        // destroyPane 루프가 invalidateForFreedPane(S1 chokepoint)으로 이미 처리했다(다음 이동이 재설정).
        self.rebuildSidebar() catch {};
        self.metal_dirty = true;
    }

    /// 활성 탭의 활성 panel을 닫는다(split이 있으면 pane을 하나씩 닫는다). 트리를 형제로
    /// collapse(removeLeaf)하고 panel을 teardown(destroyPane)한 뒤, active_pane을 보정하고, 대표 surface·
    /// pump를 새 활성 panel로 재바인딩하고, 남은 panel을 collapse된 트리의 새 leaf rect로 resize한다. panel이
    /// 1개뿐이면 무동작(그건 closeActivePaneOrTab이 closeTab으로 보낸다). 활성 탭에만 적용한다.
    fn closeActivePane(self: *AppSession) void {
        const tab = self.activeTab();
        if (tab.panes.items.len <= 1) return; // 단일 panel은 탭 close 경로
        const idx = tab.active_pane;
        const closing = tab.panes.items[idx];
        // 1) 트리에서 이 panel(leaf)을 떼고 형제로 collapse — removeLeaf가 떼어낸 split을 돌려주면, divider_drag가
        //    그 split이면 표적 null하고 destroy한다(Term/surface는 아래 destroyPane가).
        const freed_split = PaneTree.removeLeaf(&tab.tree, closing) orelse return;
        self.invalidateForFreedSplit(freed_split);
        self.allocator.destroy(freed_split);
        // 2) panes에서 빼고 panel teardown(모든 Term closeAndDetach → reader join → surface deinit → free).
        _ = tab.panes.orderedRemove(idx);
        self.destroyPane(closing);
        // 3) active_pane 보정: 닫은 게 마지막이면 이전, 아니면 그 자리로 온 다음 panel(같은 인덱스).
        tab.active_pane = if (idx >= tab.panes.items.len) tab.panes.items.len - 1 else idx;
        // 4) 대표 surface(= app_window.active())·pump를 새 활성 panel(의 활성 Term)로 재바인딩(닫은 포인터 dangling 방지).
        self.surface_ptrs.items[self.app_window.active_tab] = &tab.activeTerm().surface;
        self.app_window.tabs = self.surface_ptrs.items;
        // 5) 남은 panel을 collapse된 트리의 새 leaf rect로 resize + 좌표 origin 재계산.
        self.resizeActiveTabPanes() catch {};
        self.recomputeActivePaneRect();
        // 닫은 Pane·해제된 split 노드를 가리키던 호버·divider 포인터는 위 destroyPane이 invalidateForFreedPane
        // (S1 chokepoint)으로 이미 비웠다 — 여기서 따로 리셋하지 않는다.
        self.metal_dirty = true;
    }

    /// Cmd+W 정책: split이 있으면 활성 panel을 하나 닫고(collapse), 단일 panel이면 탭을 닫는다
    /// (마지막 탭이면 창). 즉 Cmd+W를 반복하면 pane이 하나씩 닫히다가 마지막 1개에서 탭이 닫힌다.
    fn closeActivePaneOrTab(self: *AppSession) void {
        if (self.activeTabHasSplit()) {
            self.closeActivePane();
        } else {
            self.closeTab(self.app_window.active_tab);
        }
    }

    /// 활성 pane의 활성 Term(가로 탭)을 닫는다. pane에 Term이 2개 이상일 때만 — teardown(destroyTerm)하고
    /// terms에서 빼고 active_term을 보정한 뒤 새 활성 Term surface로 재바인딩한다. Term이 1개뿐이면 무동작
    /// (closeActiveTermOrPane이 pane/워크스페이스 close로 보낸다). tree leaf는 pane이라 Term close엔 안 바뀐다.
    fn closeActiveTerm(self: *AppSession) void {
        const pane = self.activePane();
        if (pane.terms.items.len <= 1) return;
        const idx = pane.active_term;
        const closing = pane.terms.items[idx];
        _ = pane.terms.orderedRemove(idx);
        self.destroyTerm(closing);
        // active_term 보정: 닫은 게 마지막이면 이전, 아니면 그 자리로 온 다음 Term(같은 인덱스).
        pane.active_term = if (idx >= pane.terms.items.len) pane.terms.items.len - 1 else idx;
        self.surface_ptrs.items[self.app_window.active_tab] = &pane.activeTerm().surface;
        self.app_window.tabs = self.surface_ptrs.items;
        self.recomputeActivePaneRect();
        self.metal_dirty = true;
    }

    /// Cmd+W 정책(계층 cascade): 활성 pane에 Term이 2개 이상이면 활성 Term을 하나 닫고, 1개뿐이면
    /// pane을(split이면 collapse) 또는 워크스페이스를(단일 pane이면 탭/창) 닫는다. 즉 ⌘W를 반복하면 Term →
    /// pane → 워크스페이스 순으로 하나씩 닫힌다.
    fn closeActiveTermOrPane(self: *AppSession) void {
        if (self.activePane().terms.items.len > 1) {
            self.closeActiveTerm();
        } else {
            self.closeActivePaneOrTab();
        }
    }

    /// 사이드바 고정 탭(우클릭 Pin) 개수. 불변식: 고정 탭은 항상 배열 앞쪽 `[0, pinned_count)`에 연속으로 모인다
    /// (toggle/drag 경로가 그 불변식을 유지). 따라서 이 개수가 곧 고정/비고정 영역의 경계 인덱스다(pinned_count).
    /// pin 토글 정렬과 moveTab 그룹 clamp가 단일 출처로 이 헬퍼를 쓴다.
    fn countPinnedTabs(self: *const AppSession) usize {
        var n: usize = 0;
        for (self.tabs.items) |t| if (t.pinned) {
            n += 1;
        };
        return n;
    }

    /// 탭을 from→to로 옮긴다(드래그 재정렬). 베이스/결정: 고정 탭은 배열 앞쪽 `[0, pinned_count)`에 모이는 불변식을
    /// 두고(브라우저 탭 고정의 사실상 표준 — 고정/비고정이 안 섞임), 목표 `to`를 from과 **같은 그룹**으로 clamp한다
    /// (clampMoveToGroup, session core 단일 출처). 그래서 비고정을 위로 끌어도 고정 영역을 침범하지 않고, 고정을 아래로
    /// 끌어도 비고정 영역으로 안 간다 — 고정끼리·비고정끼리만 재정렬된다. clamp 후 from==to면 무동작. tabs/surface_ptrs를
    /// 같이 회전(무할당 in-place)하고 active_tab을 보정한다. Tab은 heap-pin이라 포인터만 셔플되고 surface/PTY/reader
    /// 포인터는 안 흔들린다. app_window.tabs는 surface_ptrs.items(같은 backing 배열, 내용만 재정렬)라 재바인딩 불요.
    /// 범위 밖이면 무동작.
    /// clamp으로 확정된 **최종 안착 인덱스**를 반환한다(no-op·범위 밖이면 from) — 드래그 핫패스가 pre-clamp를
    /// 따로 안 하고 이 반환값을 단일 출처로 쓴다(countPinnedTabs O(n)가 drag당 1회로 준다). 반환값 무시도 호환된다.
    fn moveTab(self: *AppSession, from: usize, raw_to: usize) usize {
        const len = self.tabs.items.len;
        if (from >= len or raw_to >= len) return from;
        const to = clampMoveToGroup(raw_to, self.tabs.items[from].pinned, self.countPinnedTabs(), len);
        if (from == to) return from; // 같은 그룹으로 clamp한 결과 제자리면 무동작
        rotateMove(*Tab, self.tabs.items, from, to);
        rotateMove(*app.Surface, self.surface_ptrs.items, from, to);
        self.app_window.active_tab = adjustActiveForMove(self.app_window.active_tab, from, to);
        self.rebuildSidebar() catch {};
        self.metal_dirty = true;
        return to;
    }

    /// 고정 탭을 앞쪽으로 stable-partition한다(고정끼리·비고정끼리 상대 순서 유지). tabs와 surface_ptrs를 **함께**
    /// 재배열하고 active_tab도 가리키던 *Tab을 추적해 새 인덱스로 보정한다. 복원(applyWorkspaceWindow)이 저장 순서를
    /// 그대로 깔아 고정/비고정이 섞였을 때 불변식([0, pinned_count)에 고정 연속)을 복구한다. two-pass(고정 먼저, 비고정
    /// 뒤)라 안정적이고 무할당이 아닌 임시 버퍼를 쓴다(탭 수는 적다). active *Tab은 재배열 전 캡처해 새 위치를 찾는다.
    fn stablePartitionPinned(self: *AppSession) void {
        const len = self.tabs.items.len;
        if (len == 0) return;
        const active_ptr: ?*Tab = if (self.app_window.active_tab < len) self.tabs.items[self.app_window.active_tab] else null;
        var new_tabs = self.allocator.alloc(*Tab, len) catch return; // 실패 시 재배열 생략(복원은 진행, 불변식만 미보장)
        defer self.allocator.free(new_tabs);
        var new_surfaces = self.allocator.alloc(*app.Surface, len) catch return;
        defer self.allocator.free(new_surfaces);
        var w: usize = 0;
        for (self.tabs.items, self.surface_ptrs.items) |t, s| if (t.pinned) { // pass 1: 고정(상대 순서 유지)
            new_tabs[w] = t;
            new_surfaces[w] = s;
            w += 1;
        };
        for (self.tabs.items, self.surface_ptrs.items) |t, s| if (!t.pinned) { // pass 2: 비고정(상대 순서 유지)
            new_tabs[w] = t;
            new_surfaces[w] = s;
            w += 1;
        };
        @memcpy(self.tabs.items, new_tabs);
        @memcpy(self.surface_ptrs.items, new_surfaces);
        if (active_ptr) |ap| for (self.tabs.items, 0..) |t, i| if (t == ap) { // active *Tab의 새 인덱스로 보정
            self.app_window.active_tab = i;
            break;
        };
    }

    /// 디버그 불변식 확인(런타임 — assertPinnedPrefix는 테스트 전용 std.testing이라 별도). 고정 탭이 앞쪽
    /// [0, pinned_count)에 연속이고 그 뒤는 전부 비고정인지 assert. 위반은 정렬 로직 버그를 디버그에서 노출한다.
    fn assertPinnedPrefixRuntime(self: *const AppSession) void {
        var seen_unpinned = false;
        for (self.tabs.items) |t| {
            if (t.pinned) {
                std.debug.assert(!seen_unpinned); // 비고정 뒤에 고정이 나오면 불변식 위반
            } else seen_unpinned = true;
        }
    }

    /// 워크스페이스 탭의 위치 고정을 토글하고 불변식(고정 탭은 배열 앞쪽 `[0, pinned_count)`에 연속)을 유지한다.
    /// pin(false→true): 그 탭을 고정 영역 끝(새 pinned_count-1)으로 옮긴다. unpin(true→false): 비고정 영역 시작
    /// (새 pinned_count)으로 옮긴다. moveTab이 tabs/surface_ptrs를 같이 회전하고 active_tab을 보정하므로(이미 새
    /// pin 상태 기준으로 같은 그룹에 clamp) 인덱스 추적이 일관된다. tab은 heap-pin `*Tab`이라 회전 후에도 안정 —
    /// 옮긴 뒤 자기 인덱스를 다시 찾을 필요 없이 목적 인덱스로 곧장 옮긴다.
    fn togglePin(self: *AppSession, tab: *Tab) void {
        // 현재 인덱스(heap-pin 포인터 일치로 검색 — 탭 수는 적다). 못 찾으면(있을 수 없음) 토글만 하고 끝.
        var from: ?usize = null;
        for (self.tabs.items, 0..) |t, i| if (t == tab) {
            from = i;
            break;
        };
        const idx = from orelse {
            tab.pinned = !tab.pinned;
            self.metal_dirty = true;
            return;
        };
        tab.pinned = !tab.pinned; // 토글 먼저 — moveTab의 그룹 clamp가 새 pin 상태를 본다.
        // 새 pinned_count 기준 목적 인덱스: pin이면 고정 영역 끝(count-1), unpin이면 비고정 영역 시작(count).
        const pinned_count = self.countPinnedTabs();
        const to: usize = if (tab.pinned) pinned_count - 1 else pinned_count;
        _ = self.moveTab(idx, to); // 같은 그룹 내 clamp이라 그대로 to로 이동(active_tab·surface_ptrs도 같이)
        // 무조건 rebuildSidebar: moveTab은 from==to(이미 그룹 경계 — 단일 탭/경계 탭 토글)면 early-return해 사이드바
        // 밴드/슬롯 상태(rebuildSidebar 산출)를 다시 짓지 않는다. 토글이 reorder 없이도 사이드바 모델을 새 pin 상태로
        // 일관되게 두려고 여기서 무조건 다시 짓는다(토글은 핫패스가 아니라 중복 호출 무해). 📌 prefix 자체는 매 frame
        // buildSidebarTitleFrame이 tab.pinned를 라이브로 읽어 그리므로 metal_dirty=true만으로도 즉시 갱신된다 —
        // 핀 아이콘은 metal_dirty가 단일 트리거다(원래 "from==to 안전망"이 metal_dirty라던 주석을 정정).
        self.rebuildSidebar() catch {};
        self.metal_dirty = true;
    }

    /// live 탭이 모두 종료됐는가(세션/창 종료 판정). 탭이 없으면 false(아직 안 만든 상태).
    fn allTabsTerminated(self: *AppSession) bool {
        if (self.tabs.items.len == 0) return false;
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    if (term.live_initialized and !term.terminated) return false;
                }
            }
        }
        return true;
    }

    /// 사용자 액션(Cmd+T)으로 새 탭을 연다 — 첫 탭과 같은 종류의 셸을 '현재 창 크기'로 띄운다(보관한
    /// new_tab_config/zdotdir, term은 loaded_config). createTab이 새 탭을 활성으로 만든다.
    fn newTab(self: *AppSession) !*Tab {
        var cfg = self.new_tab_config;
        cfg.size = self.activeSurface().core.size; // 첫 탭 크기가 아니라 지금 창 크기로
        return self.createTab(
            spawnRequest(cfg, self.loaded_config.config.term, self.new_tab_zdotdir, self.new_tab_ssh_bin),
            cfg.size,
            cfg.queue_capacity,
            "Maru",
            commandName(cfg.command_kind),
        );
    }

    /// 키바인딩이 만든 app action을 디스패치한다(native 최소 — Swift는 키만 보내고 판정·실행은 Zig).
    /// 탭 생성 실패(셸 spawn 실패 등)는 세션을 죽이지 않고 무시한다(현재 탭 그대로). 재드로우를 위해
    /// metal_dirty를 세운다(새 탭/전환으로 활성 surface가 바뀜).
    /// minimal 스크래치 세션에서 탭(워크스페이스·Term) 생성을 막는가. chrome_minimal이면서 minimal_tabs=false일 때만
    /// true — 사이드바·탭 바가 없어 안 보이는 탭을 만드는 걸 차단한다(split은 divider로 보이므로 막지 않는다).
    /// full 세션(chrome_minimal=false)은 항상 false라 탭이 정상 동작한다.
    fn tabsBlocked(self: *const AppSession) bool {
        return self.chrome_minimal and !self.minimal_tabs;
    }

    fn dispatchAppAction(self: *AppSession, action: config_mod.Action) void {
        switch (action) {
            .new_tab => if (!self.tabsBlocked()) {
                _ = self.newTab() catch return;
            },
            .next_tab => if (self.tabs.items.len > 0) {
                _ = self.switchTab((self.app_window.active_tab + 1) % self.tabs.items.len);
            },
            .previous_tab => if (self.tabs.items.len > 0) {
                _ = self.switchTab((self.app_window.active_tab + self.tabs.items.len - 1) % self.tabs.items.len);
            },
            .select_tab => |index| _ = self.switchTab(index),
            // close_tab(액션)은 워크스페이스 close — 사이드바 ✕는 closeTab을 직접 부르고, 기본 키엔 ⌘W가 아니라
            // Term cascade(close_term)가 묶인다. config로 직접 close_tab을 묶은 경우를 위해 유지한다.
            .close_tab => self.closeActivePaneOrTab(),
            // 분할 실패(셸 spawn/alloc 실패)는 세션을 죽이지 않고 무시한다 — splitActivePane이 errdefer로
            // 트리/탭을 원복하므로 활성 panel 하나가 그대로 남는다.
            .split_horizontal => self.splitActivePane(.horizontal) catch {},
            .split_vertical => self.splitActivePane(.vertical) catch {},
            // 키보드 pane 이동(Cmd+Option+화살표). split이 없거나 그 방향에 panel이 없으면 무동작.
            .focus_pane_left => self.focusPaneInDirection(.left),
            .focus_pane_right => self.focusPaneInDirection(.right),
            .focus_pane_up => self.focusPaneInDirection(.up),
            .focus_pane_down => self.focusPaneInDirection(.down),
            // 인라인 rename 시작 — 활성 워크스페이스/pane/Term의 custom_name을 편집한다. 활성 대상은 항상 ≥1이라
            // 안전. 키보드/팔릿 경로(클릭 대상은 PR4/PR5가 startRename을 직접 부른다).
            .rename_workspace => self.startRename(.{ .workspace = self.activeTab() }),
            .rename_pane => self.startRename(.{ .pane = self.activePane() }),
            .rename_term => self.startRename(.{ .term = self.activePane().activeTerm() }),
            // Term(가로 탭) 단위: ⌘T=활성 pane에 새 Term, ⌘W=활성 Term 닫기(Term→pane→워크스페이스
            // cascade), ⌘]/⌘[=다음/이전 Term. 생성 실패는 무시(newTermInActivePane이 errdefer로 원복).
            .new_term => if (!self.tabsBlocked()) {
                self.newTermInActivePane() catch {};
            },
            .close_term => self.closeActiveTermOrPane(),
            .next_term => self.focusTermRelative(1),
            .previous_term => self.focusTermRelative(-1),
            .next_pane => self.focusPaneRelative(1),
            .previous_pane => self.focusPaneRelative(-1),
            // 전체 선택(⌘A) — 활성 surface 코어의 selection을 스크롤백+화면 전체로. clipboard 쓰기는 네이티브.
            .select_all => {
                // 선택 코어 mutate는 reader로 위임(full (a), docs/io-render-threading.md §9 P3-4).
                self.runtime.enqueueCoreCommand(self.activeSurface().id, .select_all, self.io) catch {};
            },
            // 화면+스크롤백 비우기(⌘K). 코어 mutate(셀·스크롤백)는 락 아래(리더 경합 방지, docs/io-render-threading.md
            // PR3). clearScreen이 "셸에 ^L을 보내 프롬프트를 다시 그릴지"를 돌려주면, form-feed는 락 밖에서 보낸다
            // (writeInput은 블로킹 PTY 쓰기 — PR1 패턴). 프롬프트일 때만 true(alt 화면·비프롬프트면 안 보냄).
            .clear_screen => {
                const s = self.activeSurface();
                s.lockCore(self.io);
                const send_form_feed = s.core.clearScreen();
                s.unlockCore(self.io);
                if (send_form_feed) self.runtime.writeInput(s.id, .{ .bytes = "\x0c" }) catch {};
            },
            // 커맨드 팝업 토글(Cmd+Shift+P). 열려 있으면 닫고, 아니면 연다(상태머신은 PaletteState).
            .toggle_command_palette => self.togglePalette(),
            // 스크롤백 Find 토글(⌘F). 열려 있으면 닫고, 아니면 연다(상태머신은 FindState, 검색은 코어).
            .toggle_find => self.toggleFind(),
            // Find 다음/이전 매치(⌘G/⌘⇧G) — 오버레이 닫힌 채도 동작(보존된 검색어로 네비).
            .find_next => self.findNavigate(true),
            .find_previous => self.findNavigate(false),
            // 런타임 폰트 크기(⌘+/⌘-/⌘0) — cell 메트릭·grid 재계산(setFontSize). 콘텐츠 reflow 없음.
            // 증분은 config `font.size-step`(기본 1pt). ⌘0 reset은 step과 무관하게 base_font_size로 복귀.
            .increase_font_size => self.adjustFontSize(self.appearance.font.size_step),
            .decrease_font_size => self.adjustFontSize(-self.appearance.font.size_step),
            .reset_font_size => self.resetFontSize(),
            // 절대 폰트 크기(config 바인딩 `set_font_size:N`). setFontSize가 [6,72]pt로 클램프.
            .set_font_size => |size| self.setFontSize(size),
        }
        self.metal_dirty = true;
    }

    /// 커맨드 팝업을 토글한다 — 열려 있으면 닫고, 아니면 카탈로그 전체로 연다(빈 쿼리=전부). Find와 배타적이라
    /// Find를 닫고 연다. UI 상태는 chrome_host.palette, 필터 결과는 platform(palette_filtered).
    fn togglePalette(self: *AppSession) void {
        if (self.chrome_host.palette.open) {
            self.chrome_host.palette.hide();
        } else {
            self.chrome_host.notice.dismiss(); // 배타적 — notice 위에 열지 않는다
            self.chrome_host.find.hide(); // 배타적
            self.find_matches.clearRetainingCapacity();
            self.chrome_host.palette.show();
            self.recomputePalette(); // 초기 필터(전체) + setResultCount
        }
    }

    /// 현재 쿼리로 카탈로그를 다시 필터해 palette_filtered를 채우고, 컴포넌트의 result_count를 동기화한다(selected는
    /// 맨 위로 — 증분 검색 관용). 타이핑·Backspace·초기 열기마다. OOM이면 목록을 비워 안전하게 둔다. find의
    /// recomputeFind에 대응(검색은 platform이, UI 동기화는 컴포넌트가).
    fn recomputePalette(self: *AppSession) void {
        command_palette.filter(self.allocator, self.chrome_host.palette.input.query.items, &self.palette_filtered) catch {
            self.palette_filtered.clearRetainingCapacity();
        };
        self.chrome_host.palette.selected = 0; // 쿼리 변경 시 선택 맨 위(레거시 동작 보존)
        self.chrome_host.palette.setResultCount(self.palette_filtered.items.len);
    }

    /// 선택된 명령을 실행한다 — palette_filtered[selected]를 카탈로그 Action으로 해석하고, 팝업을 닫은 뒤 dispatch한다
    /// (레거시 순서: 닫고 실행 — 실행이 또 metal_dirty 등 세움). 매치 없으면 닫기만. palette_accept Action이 부른다.
    fn acceptPalette(self: *AppSession) void {
        const action = command_palette.actionAt(self.palette_filtered.items, self.chrome_host.palette.selected);
        self.chrome_host.palette.hide();
        if (action) |a| self.dispatchAppAction(a);
    }

    /// terminal.KeyEvent → chrome.input.InputEvent. chrome은 terminal 타입을 모르므로(L1/L3 경계) 이 변환을
    /// 플랫폼 어댑터가 소유한다. 모디파이어(shift/ctrl/opt/cmd)도 매핑한다 — find의 Shift+Enter(이전 매치)·
    /// ⌘/⌃/⌥+글자(닫기) 판정에 쓴다. char가 아닌 키의 codepoint는 0.
    fn chromeInputFromKeyEvent(event: terminal.KeyEvent) chrome.input.InputEvent {
        const key: chrome.input.Key = switch (event.key) {
            .enter => .enter,
            .escape => .escape,
            .arrow_up => .up,
            .arrow_down => .down,
            .backspace => .backspace,
            .char => .char,
            else => .other,
        };
        const cp: u21 = switch (event.key) {
            .char => |c| c,
            else => 0,
        };
        return .{ .key = .{
            .key = key,
            .codepoint = cp,
            .mods = .{
                .shift = event.modifiers.shift,
                .control = event.modifiers.control,
                .option = event.modifiers.option,
                .command = event.modifiers.command,
            },
        } };
    }

    /// maru 스크롤백 Find를 지금 끌지 — **단일 정책 출처**(toggleFind/findNavigate/tick-close가 공유). alt screen
    /// (vim/less/htop)에선 그 화면을 앱이 소유하고 스크롤백 뷰포트가 잠겨(scrollToAbs 무동작) 매치로 갈 수 없으니
    /// 앱 자체 검색(`/`)에 맡긴다(iTerm2 관례). surface 미초기화(narrow 테스트)면 false(activeSurfaceConst 보호).
    fn findSuppressed(self: *AppSession) bool {
        if (!self.surface_initialized) return false; // narrow 테스트(surface 미초기화) 보호
        // alt_active는 리더 core.write가 락 아래 토글하므로 같은 락으로 읽는다(docs/io-render-threading.md PR3).
        // 호출처(toggleFind/findNavigate/render-tick close)는 모두 락 밖이라 더블락 없음.
        const s = self.activeSurface();
        s.lockCore(self.io);
        defer s.unlockCore(self.io);
        return s.core.alt_active;
    }

    /// 스크롤백 Find를 토글한다 — 열려 있으면 닫고(매치 하이라이트 정리), 아니면 연다(빈 검색어). 팝업과 배타적
    /// 이라 팝업을 닫고 연다. UI 상태는 chrome_host.find, 검색은 검색어가 생길 때 recomputeFind가 한다.
    fn toggleFind(self: *AppSession) void {
        if (self.chrome_host.find.open) {
            self.chrome_host.find.hide();
            self.find_matches.clearRetainingCapacity(); // 닫힘 — 하이라이트 중단
            self.find_nav = false; // ⌘G 닫힘-네비 세션도 종료
        } else {
            if (self.findSuppressed()) return; // alt screen이면 ⌘F가 오버레이를 안 연다(앱 자체 검색에 맡김)
            self.chrome_host.notice.dismiss(); // 배타적 — notice 위에 열지 않는다
            self.chrome_host.palette.hide();
            self.chrome_host.find.show(); // show가 검색어/현재/카운트를 비운다(새 검색)
            self.find_nav = false; // 오버레이가 주도 — 닫힘-네비 플래그 해제
        }
    }

    /// 인라인 rename을 시작한다 — 대상의 현재 custom_name으로 편집기를 시드(없으면 빈 편집기 = 새 이름)하고 다른
    /// 모달은 닫는다(배타적). 이후 키/IME는 모달 가드가 rename_input으로 라우팅한다. 대상은 dispatchAppAction이
    /// 활성 워크스페이스/pane/Term으로 고른다(또는 PR4/PR5 클릭 대상).
    fn startRename(self: *AppSession, target: RenameTarget) void {
        self.chrome_host.find.hide(); // rename은 별도 모달 — 열려 있던 오버레이를 닫는다(배타적)
        self.chrome_host.palette.hide();
        self.rename_input.clear();
        // 현재 custom_name으로 시드(owned 문자열을 query에 복사) — 없으면 빈 편집기. auto title은 시드하지 않는다
        // (custom_name만 편집 대상). 사용자는 편집기에서 그대로 바꾸거나 지운다.
        const seed: ?[]const u8 = switch (target) {
            .workspace => |t| t.custom_name,
            .pane => |p| p.custom_name,
            .term => |t| t.surface.custom_name,
        };
        if (seed) |s| self.rename_input.query.appendSlice(self.allocator, s) catch {};
        self.rename = target;
        self.resetCursorBlink();
        self.metal_dirty = true;
    }

    /// rename 편집 텍스트(query)를 대상 custom_name으로 확정한다 — 비면 custom_name을 지운다(이름 없음). 조합 중
    /// preedit가 남아 있으면 먼저 query로 확정(IME 글자 손실 방지 — find와 같은 규율). 옛 owned custom_name을 free
    /// 하고 새 owned 문자열로 교체. 그 뒤 편집기를 닫는다.
    fn commitRename(self: *AppSession) void {
        const target = self.rename orelse return;
        _ = self.rename_input.commitPreedit(self.allocator); // 조합 잔여를 query로
        const text = self.rename_input.query.items;
        // 빈 텍스트(의도적 삭제) → null. 비어있지 않은데 dupe가 OOM이면 **기존 이름을 보존**하고 편집기만 닫는다 —
        // catch null로 흡수하면 OOM과 '빈 이름'을 구분 못 해 입력한 이름이 통째로 사라진다(기존 이름까지 free).
        const new_name: ?[]const u8 = if (text.len == 0) null else (self.allocator.dupe(u8, text) catch {
            self.closeRename();
            return;
        });
        switch (target) {
            .workspace => |t| {
                if (t.custom_name) |old| self.allocator.free(old);
                t.custom_name = new_name;
            },
            .pane => |p| {
                if (p.custom_name) |old| self.allocator.free(old);
                p.custom_name = new_name;
            },
            .term => |t| {
                if (t.surface.custom_name) |old| self.allocator.free(old);
                t.surface.custom_name = new_name;
            },
        }
        self.closeRename();
    }

    /// rename 편집기를 닫는다(취소·커밋 공통 종료) — 입력을 비우고 rename을 null로. custom_name은 안 건드린다
    /// (취소면 원래 이름 유지, 커밋이면 위에서 이미 갱신). 대상 teardown 시 invalidate도 이 상태만 비우면 된다.
    fn closeRename(self: *AppSession) void {
        if (self.rename == null) return;
        self.rename = null;
        self.rename_input.clear();
        self.resetCursorBlink();
        self.metal_dirty = true;
    }

    /// rename 활성 중 키 처리(모달 가드가 호출). Enter=확정·Esc=취소·Backspace=삭제·평문 글자=추가. 모디파이어
    /// 글자·기타 키(↑↓ 등)는 무시해 편집기를 유지한다(텍스트 필드라 단축키를 뒤로 안 흘린다). IME 조합은
    /// imeSetPreedit/imeEnd가 rename_input에 직접 넣는다(find/palette와 같은 경로).
    fn handleRenameKey(self: *AppSession, ev: chrome.input.InputEvent) void {
        switch (ev) {
            .key => |k| switch (k.key) {
                .escape => self.closeRename(),
                .enter => self.commitRename(),
                .backspace => {
                    self.rename_input.backspace();
                    self.resetCursorBlink();
                    self.metal_dirty = true;
                },
                .char => {
                    if (k.mods.command or k.mods.control or k.mods.option) return; // 단축키 조합은 편집기에 안 쌓음
                    self.rename_input.appendChar(self.allocator, k.codepoint) catch {};
                    self.resetCursorBlink();
                    self.metal_dirty = true;
                },
                else => {}, // up/down/other — 무시(편집기 유지)
            },
        }
    }

    /// 사이드바 검색바 키 — handleRenameKey 동형(평문 글자·backspace·Enter·Esc). 모달이 아니라 활성 중에만 키를
    /// 소비한다. Enter=첫 매칭 세션으로 이동·검색 종료, Esc=종료(검색어 비움). 단축키 조합(⌘ 등)은 안 쌓는다.
    /// 입력이 바뀌면 rebuildSidebar로 카드 필터(visible_slots)를 다시 적용한다.
    fn handleSidebarSearchKey(self: *AppSession, ev: chrome.input.InputEvent) void {
        switch (ev) {
            .key => |k| switch (k.key) {
                .escape => self.closeSidebarSearch(),
                .enter => {
                    _ = self.sidebar_search_input.commitPreedit(self.allocator); // 조합 잔여 확정
                    self.sidebarSearchActivateFirst();
                },
                .backspace => {
                    self.sidebar_search_input.backspace();
                    self.rebuildSidebar() catch {};
                    self.resetCursorBlink();
                    self.metal_dirty = true;
                },
                .char => {
                    if (k.mods.command or k.mods.control or k.mods.option) return; // 단축키 조합은 안 쌓음
                    self.sidebar_search_input.appendChar(self.allocator, k.codepoint) catch {};
                    self.rebuildSidebar() catch {};
                    self.resetCursorBlink();
                    self.metal_dirty = true;
                },
                else => {},
            },
        }
    }

    /// 검색바를 닫는다(검색어·조합 비움 + 비활성 + 필터 해제 후 재빌드). Esc·Enter(이동 후)처럼 검색을 '끝낼' 때만.
    fn closeSidebarSearch(self: *AppSession) void {
        self.sidebar_search_active = false;
        self.sidebar_search_input.clear();
        self.rebuildSidebar() catch {};
        self.metal_dirty = true;
    }

    /// 검색바를 blur한다(포커스 아웃 — 검색 영역 밖 클릭). 비활성만 하고 **검색어는 보존**한다 — 다시 검색바를
    /// 클릭하면 그 검색어로 이어서 편집·필터한다(rename은 확정/취소뿐이라 다르지만, 검색은 '초안 보존'이 자연스럽다).
    /// 비활성이라 recomputeVisibleTabs가 필터를 일시정지(전체 표시)하므로, blur 중 새 워크스페이스를 만들어도
    /// 필터에 숨지 않는다. 완전히 비우려면 Esc(closeSidebarSearch). 키 포커스는 터미널로 돌아간다(inputFocus).
    fn blurSidebarSearch(self: *AppSession) void {
        self.sidebar_search_active = false;
        self.rebuildSidebar() catch {}; // 비활성 → 필터 일시정지(전체), 검색어 텍스트는 헤더에 유지
        self.metal_dirty = true;
    }

    /// 검색 Enter — 필터된 첫 매칭 세션으로 전환하고 검색을 종료한다. 매칭 없으면 무동작(검색 유지).
    fn sidebarSearchActivateFirst(self: *AppSession) void {
        if (self.firstMatchingTab()) |idx| {
            _ = self.switchTab(idx);
            self.closeSidebarSearch();
        }
    }

    /// 검색어(이름·브랜치·폴더 대소문자 무시 substring)에 맞는 첫 탭 인덱스. 빈 검색어면 null. P3 필터·Enter 공유.
    fn firstMatchingTab(self: *AppSession) ?usize {
        const q = self.sidebar_search_input.query.items;
        if (q.len == 0) return null;
        for (self.tabs.items, 0..) |tab, i| if (self.tabMatchesSearch(tab, q)) return i;
        return null;
    }

    /// 검색 필터로 좁힌 표시 카드 목록(sidebar_visible_tabs)을 다시 계산한다 — 검색 활성 + 검색어 있으면 매칭 탭만,
    /// 아니면 전체. rebuildSidebar/검색 입력 변경 시 호출. 빈 검색어/비활성이면 전체라 필터 없음과 동일하게 동작한다.
    fn recomputeVisibleTabs(self: *AppSession) void {
        self.sidebar_visible_tabs.clearRetainingCapacity();
        const q: []const u8 = if (self.sidebar_search_active) self.sidebar_search_input.query.items else "";
        for (self.tabs.items, 0..) |tab, i| {
            if (self.tabMatchesSearch(tab, q)) self.sidebar_visible_tabs.append(self.allocator, i) catch {};
        }
    }

    /// 표시 슬롯 → 원본 tab 인덱스(검색 필터 역매핑). 범위 밖이면 null. slotAt/click/hover가 표시 슬롯을 실제 탭으로.
    fn visibleTab(self: *const AppSession, display_slot: usize) ?usize {
        if (display_slot < self.sidebar_visible_tabs.items.len) return self.sidebar_visible_tabs.items[display_slot];
        return null;
    }

    /// 원본 tab 인덱스 → 표시 슬롯(검색 필터 정방향). 필터로 숨겨졌으면 null. 활성 밴드를 표시 슬롯에 그릴 때 쓴다.
    fn displaySlotOf(self: *const AppSession, tab_index: usize) ?usize {
        for (self.sidebar_visible_tabs.items, 0..) |orig, slot| if (orig == tab_index) return slot;
        return null;
    }

    /// 탭이 검색어에 매칭하는가 — 이름(라벨)·git 브랜치·폴더(cwd) 중 하나라도 query를 포함(ASCII 대소문자 무시,
    /// 한글 등은 그대로). 빈 query는 항상 true(필터 없음). 사이드바 카드 필터·Enter 첫 매칭이 공유한다.
    fn tabMatchesSearch(self: *AppSession, tab: *Tab, query: []const u8) bool {
        if (query.len == 0) return true;
        const term = tab.activePane().activeTerm();
        const name = workspaceLabel(tab);
        const branch = self.termGitBranch(term) orelse "";
        const folder = term.surface.core.currentCwd();
        return std.ascii.indexOfIgnoreCase(name, query) != null or
            std.ascii.indexOfIgnoreCase(branch, query) != null or
            std.ascii.indexOfIgnoreCase(folder, query) != null;
    }

    /// 검색 caret rect(헤더 검색 영역) — IME 후보창·커서 위치. 🔍(2칸)+공백 다음 입력 텍스트 폭만큼. 헤더 1줄(y=0).
    fn sidebarSearchCaretRect(self: *AppSession) ?chrome.draw.Rect {
        if (!self.sidebar_search_active or self.cell_width_px == 0 or self.cell_height_px == 0) return null;
        const cw = self.cell_width_px;
        const ch = self.cell_height_px;
        const header_rows = @max(@as(u32, 2), self.sidebar_header_height_px / ch);
        const search_row = header_rows - 1; // 검색 줄(buildSidebarHeaderFrame와 동일 — 신호등 아래)
        const prompt_cols: u32 = 3; // 🔍(2칸) + 공백(1)
        const caret_col = prompt_cols + self.sidebar_search_input.queryCols();
        return .{ .x = @intCast(caret_col * cw), .y = @intCast(search_row * ch), .w = cw, .h = ch };
    }

    /// 점(x,y px)에 있는 rename 대상 — 사이드바 슬롯=워크스페이스, pane 라벨 세그먼트=pane, Term 탭=term. 없으면
    /// null(터미널 본문·‹›/+·"+" 슬롯·바 밖). 더블클릭(kind 4)과 우클릭 메뉴가 공유해 **같은 자리를 같은 대상으로**
    /// 친다(단일 출처). hit-test는 paneBar(full/tabs/label_cols)·barMetrics를 재사용.
    fn renameTargetAt(self: *AppSession, x_px: f64, y_px: f64) ?RenameTarget {
        if (self.inSidebar(x_px)) {
            // 사이드바: 슬롯이면 그 워크스페이스. 단 우측 ✕(close) zone은 rename 대상 아님(닫기 자리에서 rename 방지).
            // "+" 슬롯/빈 영역은 sidebarSlotAt이 null이라 자연히 제외.
            if (self.sidebarSlotAt(y_px)) |slot| {
                if (chrome.components.sidebar.closeButton(x_px, self.sidebar_width_px, self.cell_width_px)) return null;
                if (self.visibleTab(slot)) |tab_idx| return .{ .workspace = self.tabs.items[tab_idx] }; // 표시 슬롯 → 원본(검색 필터)
            }
            return null;
        }
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return null;
        for (leaf_rects.items) |lr| {
            const pb = self.paneBar(lr.rect, lr.leaf) orelse continue;
            if (!pointInRect(x_px, y_px, pb.full)) continue;
            // 좌측 라벨 세그먼트 → 그 pane.
            if (pb.label_cols > 0 and x_px < @as(f64, @floatFromInt(pb.tabs.x))) return .{ .pane = lr.leaf };
            const count = lr.leaf.terms.items.len;
            const m = barMetrics(pb.tabs, self.cell_width_px, count, self.buildChromeTokens().space.tab_width_cols, lr.leaf.tab_scroll_cols) orelse return null;
            if (m.inScrollLeftZone(x_px) or m.inScrollRightZone(x_px) or m.inPlusZone(x_px)) return null; // ‹›/+ 은 대상 아님
            const tab = m.tabIndex(count, x_px);
            if (m.inCloseZone(tab, x_px)) return null; // 탭 우측 ✕(close) zone은 rename 대상 아님
            if (tab < count) return .{ .term = lr.leaf.terms.items[tab] };
            return null;
        }
        return null;
    }

    /// 점이 chrome(사이드바 또는 어떤 pane의 탭 바) 위인가 — 우클릭이 chrome이면 consume하고 터미널 본문이면
    /// mouse-reporting으로 흘리는 판정에 쓴다. renameTargetAt가 null인 chrome 영역(사이드바 +/빈칸·바 ‹›/+)과
    /// 터미널 본문을 구분한다(renameTargetAt는 둘 다 null이라 구분 불가).
    fn pointOnChrome(self: *AppSession, x_px: f64, y_px: f64) bool {
        if (self.inSidebar(x_px)) return true;
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return false;
        for (leaf_rects.items) |lr| {
            if (self.paneBar(lr.rect, lr.leaf)) |pb| {
                if (pointInRect(x_px, y_px, pb.full)) return true;
            }
        }
        return false;
    }

    /// 현재 컨텍스트 메뉴 대상에 맞는 항목 라벨을 buf에 채우고 슬라이스 반환. workspace = Rename + Pin/Unpin + 배경
    /// 프리셋, pane/term = Rename만. show가 호출해 len을 박고, itemAt/draws/accept가 contextMenuItems로 같은 리스트를 본다.
    fn buildContextMenuItems(self: *AppSession) []const []const u8 {
        var n: usize = 0;
        self.context_menu_items_buf[n] = "Rename";
        n += 1;
        if (self.context_menu_target) |t| if (std.meta.activeTag(t) == .workspace) {
            self.context_menu_items_buf[n] = if (t.workspace.pinned) "고정 해제" else "위치 고정";
            n += 1;
            for (tab_bg_labels) |lbl| {
                self.context_menu_items_buf[n] = lbl;
                n += 1;
            }
        };
        self.context_menu_items_len = n;
        return self.context_menu_items_buf[0..n];
    }

    fn contextMenuItems(self: *const AppSession) []const []const u8 {
        return self.context_menu_items_buf[0..self.context_menu_items_len];
    }

    /// 컨텍스트 메뉴의 선택 항목을 실행한다. 0=Rename(모든 대상), workspace는 1=위치 고정 토글·2..=배경 tint 프리셋.
    /// 메뉴를 먼저 닫고(대상 teardown 시 context_menu_target은 이미 null화됨) selected로 분기한다.
    fn acceptContextMenu(self: *AppSession) void {
        const target = self.context_menu_target;
        const sel = self.chrome_host.context_menu.selected;
        self.context_menu_target = null;
        self.chrome_host.context_menu.hide();
        self.metal_dirty = true;
        const t = target orelse return;
        if (sel == 0) {
            self.startRename(t); // "Rename"(모든 대상)
            return;
        }
        if (std.meta.activeTag(t) == .workspace) {
            const tab = t.workspace;
            if (sel == ctx_menu_pin) {
                self.togglePin(tab); // 위치 고정 토글 + 불변식 유지(고정은 앞쪽 영역으로 정렬)
            } else if (sel >= ctx_menu_bg_first and sel < ctx_menu_bg_first + tab_bg_presets.len) {
                tab.background_color = tab_bg_presets[sel - ctx_menu_bg_first]; // 배경 tint 프리셋
            }
        }
    }

    /// Find 다음/이전 매치로(⌘G/⌘⇧G). 오버레이가 닫혀 있어도 동작한다 — show가 비우기 전까지 검색어는
    /// chrome_host.find가 보존하므로, 닫은 뒤에도 그 검색어로 재검색해 네비게이션한다(macOS Find Next 관례).
    /// 검색 이력(검색어)이 없으면 무동작. 닫을 때 매치를 비웠으니 비어 있으면 보존 검색어로 다시 채우고(현재
    /// 인덱스는 닫기 전 위치 유지 — setMatchCount가 범위 clamp), find_nav를 세워 하이라이트(현재 매치)·출력
    /// 시 재검색을 닫힌 채로도 유지한다. 오버레이가 열려 있으면 모달 라우팅이 키를 가로채 이 경로는 안 탄다.
    fn findNavigate(self: *AppSession, forward: bool) void {
        if (!self.surface_initialized) return;
        if (self.findSuppressed()) return; // alt screen — maru Find 끔(toggleFind와 같은 정책)
        if (self.chrome_host.find.input.query.items.len == 0) return; // 검색 이력 없음 — 무동작
        if (self.find_matches.items.len == 0) {
            // findMatches는 코어 mutate(스크롤백 rewrap)+읽기 — 락 아래(docs/io-render-threading.md PR3, 리더 경합 방지).
            const s = self.activeSurface();
            s.lockCore(self.io);
            s.core.findMatches(self.allocator, self.chrome_host.find.input.query.items, &self.find_matches) catch self.find_matches.clearRetainingCapacity();
            s.unlockCore(self.io);
            self.chrome_host.find.setMatchCount(self.find_matches.items.len); // current를 범위로 clamp(닫기 전 위치 보존)
        }
        if (self.find_matches.items.len == 0) return; // 매치 없음
        self.find_nav = true;
        if (forward) self.chrome_host.find.next() else self.chrome_host.find.prev();
        self.scrollToCurrentMatch();
        self.metal_dirty = true;
    }

    /// chrome 컴포넌트가 낸 의도(HostAction)를 session 부수효과로 디스패치한다 — chrome은 session을 모르므로(경계)
    /// 재검색·스크롤·닫기를 여기서 실행한다. handleKeyEvent의 chrome 라우팅이 부른다.
    fn dispatchChromeAction(self: *AppSession, action: chrome.host.HostAction) void {
        switch (action) {
            .none => {}, // notice dismiss 등 — session 부수효과 없음(컴포넌트가 닫음)
            .find_close => self.find_matches.clearRetainingCapacity(), // find.hide는 컴포넌트가 이미 — 하이라이트만 정리
            .find_navigated => self.scrollToCurrentMatch(),
            .find_query_changed => self.recomputeFind(),
            .palette_close => {}, // palette.hide는 컴포넌트가 이미 — platform 부수효과 없음
            .palette_query_changed => self.recomputePalette(), // 재필터 + result_count 동기화
            .palette_selection_changed => {}, // 선택만 이동 — 스크롤 윈도우는 buildChromeOverlayFrame이 파생, 부수효과 없음
            .palette_accept => self.acceptPalette(), // 선택 명령 해석·닫기·dispatch
            .context_menu_accept => self.acceptContextMenu(), // selected 항목 실행(현재 "Rename" → 대상 rename)
            .context_menu_close => { // Esc/그 외 키 — 컴포넌트가 이미 hide, 대상 포인터만 비운다
                self.context_menu_target = null;
                self.metal_dirty = true;
            },
            .context_menu_selection_changed => self.metal_dirty = true, // ↑↓ 선택 이동 — 재렌더
        }
    }

    /// 현재 검색어로 활성 surface를 다시 검색해 find_matches를 채우고, 현재 인덱스를 첫 매치로 리셋한 뒤 뷰로
    /// 스크롤한다(증분 검색 — 타이핑·Backspace마다). 검색어가 비면 매치 0. OOM이면 매치를 비워 안전하게 둔다.
    /// chrome_host.find.match_count를 동기화해(setMatchCount) 컴포넌트의 카운터·next/prev wrap이 맞게 한다.
    fn recomputeFind(self: *AppSession) void {
        if (!self.surface_initialized) return;
        {
            // findMatches는 코어 mutate(ensureScrollbackRewrapped로 스크롤백 realloc)+읽기 — 락 아래
            // (docs/io-render-threading.md PR3 — 리더 core.write와 경합 시 UAF/크래시 방지).
            const s = self.activeSurface();
            s.lockCore(self.io);
            defer s.unlockCore(self.io);
            s.core.findMatches(self.allocator, self.chrome_host.find.input.query.items, &self.find_matches) catch {
                self.find_matches.clearRetainingCapacity();
            };
        }
        self.chrome_host.find.setMatchCount(self.find_matches.items.len);
        self.chrome_host.find.current = 0; // 재검색은 첫 매치로 리셋(증분)
        self.scrollToCurrentMatch();
    }

    /// 현재(네비게이션) 매치를 뷰포트로 스크롤한다 — 없으면 무동작. 검색·네비게이션 후 호출(scrollToAbs가
    /// 매치를 세로 중앙쯤에 둬 Find 오버레이(활성 pane 상단 한 줄)에 안 가린다). 현재 인덱스는 chrome_host.find.current.
    fn scrollToCurrentMatch(self: *AppSession) void {
        if (!self.surface_initialized) return;
        const cur = self.chrome_host.find.current;
        if (cur >= self.find_matches.items.len) return;
        const surface = self.activeSurface();
        // scrollToAbs는 코어 mutate라 reader로 위임(full (a), docs/io-render-threading.md §9 P3-4).
        self.runtime.enqueueCoreCommand(surface.id, .{ .scroll_to_abs = self.find_matches.items[cur].start.row }, self.io) catch {};
    }

    /// 현재 활성 탭의 surface. 모든 입력/IME/스크롤/마우스/렌더 경로가 이 seam을 거친다 —
    /// `app_window.active_tab`을 따라가므로 멀티-탭(후속 PR)에서 탭을 전환하면 자동으로 활성 탭에
    /// 라우팅된다. 지금은 단일 탭이라 항상 `surfaces[0]`이고 외부 동작은 불변이다. 호출자는 기존대로
    /// `surface_initialized`로 가드하므로 `active()`는 non-null이 보장된다.
    fn activeSurface(self: *AppSession) *app.Surface {
        return self.app_window.active().?;
    }

    /// kitty graphics(K4c): kitty_uploaded(렌더러 업로드 generation 미러)를 live id 집합으로 prune한다 —
    /// live가 아닌(저장소에서 빠진/Swift가 텍스처를 evict할) image_id를 dedup 상태에서도 제거해, 다시
    /// 활성화되면 planImageUploads가 재업로드하게 한다. id 수가 작아 선형 검색으로 충분하다.
    fn pruneKittyUploaded(self: *AppSession, live_ids: []const u32) void {
        var to_remove: std.ArrayList(u32) = .empty;
        defer to_remove.deinit(self.allocator);
        var it = self.kitty_uploaded.iterator();
        while (it.next()) |kv| {
            if (std.mem.indexOfScalar(u32, live_ids, kv.key_ptr.*) == null) {
                to_remove.append(self.allocator, kv.key_ptr.*) catch {};
            }
        }
        for (to_remove.items) |id| _ = self.kitty_uploaded.remove(id);
    }

    /// `activeSurface`의 읽기 전용(`*const self`) 변형 — `pxToCell`/`imeCursorRect`처럼 surface를
    /// 안 바꾸는 const 메서드가 같은 seam을 거치게 한다.
    fn activeSurfaceConst(self: *const AppSession) *const app.Surface {
        return self.app_window.activeConst().?;
    }

    /// 현재 font·scale_milli에 대한 cell 픽셀 크기(advance 폭 × line-height)를 CoreText에서
    /// 뽑아 갱신한다. 분수 scale을 그대로 곱한 device 픽셀 font size로 조회한다. macOS가
    /// 아니거나(테스트/CI) 조회 실패면 같은 device 픽셀 font size의 정사각으로 대체한다.
    /// scale_milli가 바뀌는 resize에서도 호출한다.
    fn refreshCellMetrics(self: *AppSession) void {
        const device_font_size = renderer.deviceFontSizeFromMilli(self.appearance.font.size, self.scale_milli);
        const square: u32 = @intFromFloat(@round(device_font_size));
        self.cell_width_px = square;
        self.cell_height_px = square;
        // extern native 호출은 macOS에서만 컴파일/링크한다(.m을 링크하지 않는 Linux 계약
        // 빌드에서 undefined symbol이 되지 않게 comptime으로 막는다).
        if (builtin.os.tag == .macos) {
            var metrics: coretext_bridge.CellMetricsResult = .{};
            coretext_bridge.maru_macos_coretext_font_cell_metrics(
                self.appearance.font.family.ptr,
                self.appearance.font.family.len,
                device_font_size,
                &metrics,
            );
            if (metrics.status == 0 and metrics.cell_width_px > 0 and metrics.cell_height_px > 0) {
                self.cell_width_px = metrics.cell_width_px;
                self.cell_height_px = metrics.cell_height_px;
            }
        }
        // line-height(행간)·letter-spacing(자간) config를 cell 두 px에 단일 적용한다 — native/fallback이 base
        // cell 크기를 정한 '직후', grid·atlas·hit-test·IME가 파생되기 '전'. line-height는 cell_height_px에 곱하고,
        // letter-spacing은 논리 pt를 backing px로 환산(× scale_milli/1000, padding px 환산과 동일 방식)해 cell_width_px에
        // 가산한다. 늘어난 cell은 native 셰이퍼가 glyph를 slot 안 가운데로 그려 자동 여백이 된다 — 셰이퍼엔 안 넘긴다
        // (넘기면 Zig grid 계산과 native slot이 어긋난다). 기본값(1.0/0.0)이면 곱 1.0·가산 0이라 현 동작과 동일.
        const spaced = applyFontSpacing(
            self.cell_width_px,
            self.cell_height_px,
            self.appearance.font.line_height,
            self.appearance.font.letter_spacing,
            self.scale_milli,
        );
        self.cell_width_px = spaced.width_px;
        self.cell_height_px = spaced.height_px;
        // 세로 사이드바 폭도 분수 scale에 맞춰 backing 픽셀로 환산한다(메트릭과 같은 단일 출처). 폭은 현재
        // 논리 폭(sidebar_width_pt — 사용자 드래그로 바뀔 수 있음)에서 파생하므로 DPI 변경에도 유지된다.
        // minimal 세션은 사이드바가 없으므로 0 고정(터미널이 전폭을 쓴다).
        self.sidebar_width_px = if (self.chrome_minimal) 0 else ptToPx(self.sidebar_width_pt, self.scale_milli);
        // window padding도 같은 단일 출처(논리 pt × 분수 scale)로 backing px 환산 — DPI 변경에도 유지된다.
        // termRect/gridFromBacking이 이 px를 inset으로 쓴다(렌더 origin·hit-test·IME 자동 정합). minimal 세션도
        // 동일 적용(터미널 콘텐츠 inset이라 chrome 유무와 무관).
        self.window_padding_px = .{
            .left = ptToPx(self.appearance.window_padding_left, self.scale_milli),
            .right = ptToPx(self.appearance.window_padding_right, self.scale_milli),
            .top = ptToPx(self.appearance.window_padding_top, self.scale_milli),
            .bottom = ptToPx(self.appearance.window_padding_bottom, self.scale_milli),
        };
        // 탭 슬롯 높이 = cell 높이 × 2.5(큰 슬롯). cell_height_px가 이미 위에서 갱신됐으므로
        // 그걸 쓴다 — 슬롯 높이도 cell 메트릭과 같은 단일 출처에서 파생한다.
        self.sidebar_slot_height_px = self.cell_height_px * sidebar_slot_height_ratio_milli / 1000;
        self.sidebar_header_height_px = self.cell_height_px * sidebar_header_height_ratio_milli / 1000;
        // 사이드바 폭/cell 폭이 바뀌면 밴드의 칸 환산(sidebar_cols)도 달라지므로 다시 만든다.
        self.rebuildSidebar() catch {};
        // 폰트/DPI 변경을 활성 surface 코어에 즉시 반영(kitty 자동 크기 advance용 — renderFrame 안전망보다
        // 먼저, 변경 직후 첫 PTY 출력에서 정확하도록). surface 생성 전(init 순서)이면 surface_initialized로 가드.
        if (self.surface_initialized) {
            // Phase 3 위임(docs/io-render-threading.md §9 P3-3): 폰트/DPI 변경 시 셀 메트릭을 reader로 위임한다(메인
            // 직접 mutate 없음). 한 reader-턴 지연이 있어도 per-tick 렌더 경로(buildFrame의 setCellMetrics 안전망 —
            // 렌더 준비라 §9 예외로 메인 동기 유지)가 재적용하므로 무해.
            self.runtime.enqueueCoreCommand(self.activeSurface().id, .{ .set_cell_metrics = .{ .width = self.cell_width_px, .height = self.cell_height_px } }, self.io) catch {};
        }
    }

    /// 폰트 크기를 delta(pt)만큼 조절한다(⌘+/⌘-). setFontSize가 클램프·메트릭·grid를 처리한다.
    fn adjustFontSize(self: *AppSession, delta: f32) void {
        self.setFontSize(self.appearance.font.size + delta);
    }

    /// 폰트 크기를 config 기본값으로 되돌린다(⌘0).
    fn resetFontSize(self: *AppSession) void {
        self.setFontSize(self.base_font_size);
    }

    /// 런타임 폰트 크기를 size(pt)로 바꾼다(클램프 [font_size_min, font_size_max]). 변화가 없으면 무동작.
    /// 폰트 크기는 cell 메트릭(→ 글리프 cache key)을 바꾸므로: ① appearance.font.size 갱신 → ② applyMetricsPipeline로
    /// cell 픽셀·사이드바 재계산 + atlas 무효화 + grid 재산출 + 각 pane resize(코어 resize의 reflow 경로 공유 —
    /// PTY winsize/SIGWINCH 포함). 터미널 콘텐츠 reflow는 없다(셀 크기·grid 차원만, Ghostty 동일).
    fn setFontSize(self: *AppSession, size: f32) void {
        const clamped = std.math.clamp(size, font_size_min, font_size_max);
        if (clamped == self.appearance.font.size) return; // 경계에서 더 눌러도 변화 없으면 재작업 스킵
        self.appearance.font.size = clamped;
        self.applyMetricsPipeline();
    }

    /// appearance(폰트·여백·테마)가 통째로 바뀌었을 때의 일반 적용 경로. setFontSize의 메트릭 재계산을 일반화한 것 —
    /// reloadConfig(파일 새 값)·resetToInitial(처음 설정 복원)이 공유한다. appearance를 갈아끼우고 base_font_size를
    /// 새 폰트 크기로 맞춘 뒤(⌘0 기준도 따라감), 메트릭·grid·atlas 파이프라인을 돌린다. palette/scrollback 같은
    /// 코어 behavior 재주입은 호출자가 한다(appearance만 다루는 단일 책임).
    fn applyAppearance(self: *AppSession, new_appearance: config_mod.ResolvedAppearance) void {
        self.appearance = new_appearance;
        self.base_font_size = new_appearance.font.size; // 새 config 기본 폰트 크기 = ⌘0 reset 기준
        self.applyMetricsPipeline();
    }

    /// appearance.font(크기·family·line-height·letter-spacing)·window_padding이 바뀐 뒤 cell 메트릭과 그것에서
    /// 파생되는 모든 것을 다시 잡는다(setFontSize·applyAppearance 공유): ① refreshCellMetrics(cell 픽셀·사이드바·
    /// 패딩 px 재계산) → ② atlas 무효화(새 크기로 재래스터·옛 슬롯 회수) → ③ 같은 창(backing px)에서 grid 재산출
    /// + 각 pane resize(resize 본문과 동일한 reflow). 아직 첫 resize 전(backing 0)이면 grid는 스킵 — 곧 올 Swift
    /// resize가 새 메트릭으로 grid를 잡는다.
    fn applyMetricsPipeline(self: *AppSession) void {
        self.refreshCellMetrics();
        _ = self.renderer_state.atlas.invalidate(.font_size_changed);
        if (self.backing_width_px > 0 and self.backing_height_px > 0) {
            const grid = gridFromBacking(self.backing_width_px, self.backing_height_px, self.cell_width_px, self.cell_height_px, self.sidebar_width_px, self.window_padding_px);
            self.resizeActiveTabPanes() catch {};
            self.recomputeActivePaneRect();
            self.last_resize_size = grid;
        }
        self.metal_dirty = true;
    }

    /// "Reset to Defaults" 메뉴 — 런타임 줌(⌘+/−)·여백 변경을 **프로그램 처음 실행했던** 설정(initial_appearance)으로
    /// 되돌린다. behavior(scrollback/bell/page-keys)는 런타임에 안 바뀌므로 reset 대상이 아니다 — appearance만
    /// 되돌린다. 단 palette는 appearance에 속하므로 applyAppearance가 갈아끼운 initial palette를 모든 surface에
    /// 재주입한다(코어 setConfigPalette 단일 출처). initial_appearance는 init에서만 잡혀 reload 후에도 불변이라,
    /// reset 기준이 항상 "프로그램 처음"이다.
    pub fn resetToInitial(self: *AppSession) void {
        self.applyAppearance(self.initial_appearance);
        self.reapplyConfigPalette();
    }

    /// "Reload Config" 메뉴 — config 파일을 재로드해 재시작 없이 반영한다. 파싱은 forgiving(알 수 없는 key/잘못된
    /// 값은 기본값 유지 + diagnostic), 로드 자체가 실패(OOM 등)하면 무동작이다(기존 config 유지). 적용 순서:
    /// ① 새 Parsed로 loaded_config 교체(옛 arena deinit 후 — appearance가 family 슬라이스를 빌리므로 새 appearance를
    ///    먼저 만들지 말고 loaded_config를 갈아끼운 뒤 resolve한다 → 옛 family를 빌린 옛 appearance는 이 시점에 버린다).
    /// ② appearance resolve + applyAppearance(메트릭·grid·atlas + base_font_size).
    /// ③ 파일 새 값이라 코어 behavior(scrollback/bell/page-keys/palette)도 모든 surface에 재적용.
    /// initial_appearance는 건드리지 않는다 — reset 기준은 "프로그램 처음"이라 reload 후에도 불변(위 필드 주석).
    pub fn reloadConfig(self: *AppSession) void {
        var new_parsed = config_mod.loadConfigDefault(self.io, self.allocator) catch return; // 실패 시 무동작(forgiving)
        // 새 config로 appearance를 먼저 resolve한 뒤에 옛 loaded_config를 버린다 — resolve가 실패하면 옛
        // appearance·loaded_config를 그대로 보존해 use-after-free(옛 arena의 family를 빌린 appearance)를 막는다.
        const new_appearance = config_mod.resolveAppearance(new_parsed.config) catch {
            new_parsed.deinit();
            return;
        };
        self.applyAppearance(new_appearance); // appearance 통째 교체 — 옛 family를 더는 안 읽는다
        self.loaded_config.deinit(); // 이제 옛 loaded_config(arena)를 버려도 안전
        self.loaded_config = new_parsed;
        // 파일 새 값이라 캐시된 behavior도 갱신한다(appearance 밖 — applyAppearance가 안 건드림).
        self.audible_bell = self.loaded_config.config.bell.audible;
        self.page_keys_scroll = self.loaded_config.config.input.page_keys == .scroll;
        self.reapplyScrollback();
        self.reapplyConfigPalette();
        // 사이드바 카드 표시 토글(sidebar.show-branch/folder)이 파일에서 바뀌었을 수 있다 — 카드를 다시
        // 빌드해 즉시 반영한다(config→앱 양방향). rebuildSidebar 실패는 무시(다음 프레임에 자연 복구).
        self.rebuildSidebar() catch {};
        self.metal_dirty = true;
    }

    /// "Reset" 메뉴(⌘⇧R) — 활성 터미널 코어의 잔류 입력 모드(focus 1004·mouse·kitty keyboard 등)만
    /// 끈다. ssh 너머 TUI가 SIGKILL로 죽어 정리 시퀀스를 못 보낸 탓에 포커스/마우스마다 CSI I·좌표가
    /// 흘러나오는 증상의 수동 회복 경로다(셸 통합 precmd 자동 리셋이 안 닿는 타 셸·hang 복구 직후 대비).
    /// fullReset(RIS)과 달리 화면·스크롤백은 보존한다. 코어 변경이라 core_mutex 아래서 한다(focusChanged
    /// 와 같은 PR3 패턴). 입력 인코딩 상태만 바꿔 렌더에 영향이 없으므로 metal_dirty는 세우지 않는다.
    pub fn resetInputModes(self: *AppSession) void {
        if (!self.surface_initialized) return;
        const surface = self.activeSurface();
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        surface.core.resetInputModes();
    }

    /// 현재 appearance.theme.palette를 모든 탭/panel/Term 코어에 재주입한다(reload·reset 공유). createTerm의
    /// setConfigPalette와 같은 chokepoint지만, 여기 surface들은 이미 live(리더 스레드가 코어 접근)라 코어 변경은
    /// core_mutex 아래서 한다(docs/io-render-threading.md PR3 — OSC 4 변경과의 data race 방지). metal_dirty는
    /// 호출자(applyAppearance→applyMetricsPipeline)가 이미 세운다.
    fn reapplyConfigPalette(self: *AppSession) void {
        const palette = self.appearance.theme.palette;
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    // Phase 3 위임(docs/io-render-threading.md §9 P3-3): config 재적용도 메인이 직접 mutate 안 하고
                    // reader로 위임한다(interactive면 큐, 아니면 enqueueCoreCommand 내부 직접 폴백). reload는 attach 후라
                    // 링크 존재(없으면 UnknownSurface로 스킵 — best-effort).
                    self.runtime.enqueueCoreCommand(term.surface.id, .{ .set_config_palette = palette }, self.io) catch {};
                }
            }
        }
    }

    /// config scrollback.lines를 모든 탭/panel/Term 코어 max_scrollback에 재주입한다(reload 전용 — reset은 behavior를
    /// 안 건드린다). createTerm과 같은 chokepoint지만 live surface라 core_mutex 아래서 쓴다(리더 스레드가 ring을
    /// lazy-alloc/scroll로 읽으므로). 이미 할당된 ring을 줄이지는 않는다 — 코어가 다음 eviction에서 새 cap을 본다.
    fn reapplyScrollback(self: *AppSession) void {
        const lines = self.loaded_config.config.scrollback.lines;
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    // Phase 3 위임(P3-3): scrollback cap 재적용도 reader로 위임(config 재적용과 동일 — best-effort).
                    self.runtime.enqueueCoreCommand(term.surface.id, .{ .set_max_scrollback = lines }, self.io) catch {};
                }
            }
        }
    }

    pub fn handleKeyEvent(self: *AppSession, event: terminal.KeyEvent) !FrameSummary {
        // Swift/AppKit는 normalized key event만 전달한다. app-vs-terminal 판정과 PTY
        // write는 기존 FrameLoop 경계를 통과해야 smoke와 제품 app이 같은 shortcut 정책을 쓴다.
        self.total_key_events += 1;
        // 셸이 이미 종료/close된 뒤 도착한 입력은 라우팅할 live surface가 없다. FrameLoop로
        // 내려보내면 UnknownSurface/SessionClosed로 실패하는데, 그건 치명적 세션 fault가
        // 아니라 닫힌 pane의 late input이므로 ignored로 회계만 하고 정상으로 닫는다.
        if (self.ended_seen) {
            self.total_ignored_key_events += 1;
            self.writeSummaryFromState();
            self.last_summary.last_event_kind = @intFromEnum(EventKind.key_down);
            return self.last_summary;
        }
        // 인라인 rename이 활성이면 키를 rename 편집기로 라우팅한다 — chrome 모달과 같은 최상위 규율(배타적: startRename이
        // find/palette를 닫음). Enter=확정·Esc=취소·Backspace·평문 글자를 handleRenameKey가 처리하고 모든 키를 소비한다
        // (텍스트 필드라 터미널/단축키로 안 흘린다). IME 조합은 imeSetPreedit/imeEnd가 rename_input에 직접 넣는다.
        if (self.rename != null) {
            self.handleRenameKey(chromeInputFromKeyEvent(event));
            self.metal_dirty = true;
            self.total_app_key_events += 1; // rename(앱)이 소비
            self.writeSummaryFromState();
            self.last_summary.last_event_kind = @intFromEnum(EventKind.key_down);
            return self.last_summary;
        }
        // 사이드바 검색바가 활성이면 키를 검색 입력으로 라우팅한다(rename과 같은 규율 — 활성 중 모든 키 소비).
        // Enter=첫 매칭 이동·Esc=종료·Backspace·평문 글자를 handleSidebarSearchKey가 처리한다(단축키 조합은 안 쌓음).
        if (self.sidebar_search_active) {
            self.handleSidebarSearchKey(chromeInputFromKeyEvent(event));
            self.metal_dirty = true;
            self.total_app_key_events += 1; // 검색(앱)이 소비
            self.writeSummaryFromState();
            self.last_summary.last_event_kind = @intFromEnum(EventKind.key_down);
            return self.last_summary;
        }
        // chrome 모달(Notice·Find·Palette)이 열려 있으면 키를 chrome으로 라우팅한다 — 최상위(PTY/스크롤보다 먼저,
        // 셋은 배타적). handleInput이 컴포넌트 handle로 보내 의도(HostAction)를 내고, dispatchChromeAction이 session
        // 부수효과(재검색·스크롤·필터·실행·닫기)를 실행한다. 모든 키를 소비한다(모달이라 터미널엔 안 내려간다).
        if (self.chrome_host.notice.open or self.chrome_host.context_menu.open or self.chrome_host.find.open or self.chrome_host.palette.open) {
            if (self.chrome_host.handleInput(self.allocator, chromeInputFromKeyEvent(event))) |action| {
                self.dispatchChromeAction(action);
            }
            self.resetCursorBlink(); // 오버레이 타이핑 직후 caret 보이게(활동 reset — 새 주기 시작)
            self.metal_dirty = true;
            self.total_app_key_events += 1; // chrome(앱)이 소비
            self.writeSummaryFromState();
            self.last_summary.last_event_kind = @intFromEnum(EventKind.key_down);
            return self.last_summary;
        }
        // PageUp/PageDown는 메인 화면에선 Maru 스크롤백을 한 페이지씩 스크롤한다(Mac 네이티브 —
        // Terminal.app/iTerm2 동작). 셸의 기본 keymap엔 \e[5~/\e[6~가 unbound라, PTY로 보내면
        // zsh가 BEL을 울리고 남은 '~'를 입력줄에 그대로 박아 레이아웃이 깨진다(PTY 캡처로 확인:
        // \e[6~ -> 0x07 '~'). alt 화면(vim/less)에선 앱이 자체 페이징하므로 그대로 \e[5~/\e[6~를
        // 인코딩한다(아래 frame_loop 경로). 스크롤 키라 '타이핑하면 바닥으로' 로직보다 먼저 처리해
        // 매 PageUp마다 뷰가 바닥으로 튀지 않게 한다.
        if (self.surface_initialized) {
            const page_alt_active = blk: {
                // alt_active는 리더가 락 아래 토글 — 같은 락으로 읽는다(docs/io-render-threading.md PR3).
                const s = self.activeSurface();
                s.lockCore(self.io);
                defer s.unlockCore(self.io);
                break :blk s.core.alt_active;
            };
            const page_delta = pageScrollDelta(self.page_keys_scroll, page_alt_active, event.key);
            if (page_delta != 0) {
                self.scrollPage(page_delta);
                self.total_app_key_events += 1; // 앱(터미널)이 소비 — PTY로 안 보냄
                self.writeSummaryFromState();
                self.last_summary.last_event_kind = @intFromEnum(EventKind.key_down);
                return self.last_summary;
            }
        }
        // 타이핑하면 live(바닥)로 돌아간다 — 과거를 보다가 입력하면 현재 화면으로 점프(표준 터미널).
        // 스크롤 중이었으면 즉시 다시 그리도록 metal_dirty도 세운다(echo 출력 전에라도 뷰 복귀).
        if (self.surface_initialized) {
            // viewOffset 읽기는 메인 락-아래(§9.1), scrollToBottom mutate는 reader로 위임(full (a), §9 P3-4).
            const surface = self.activeSurface();
            const scrolled = blk: {
                surface.lockCore(self.io);
                defer surface.unlockCore(self.io);
                break :blk surface.core.viewOffset() != 0;
            };
            if (scrolled) {
                self.runtime.enqueueCoreCommand(surface.id, .scroll_to_bottom, self.io) catch {};
                self.metal_dirty = true;
            }
        }
        // 사용자 config의 keybind를 적용한다 — resolver가 사용자 바인딩(앱 액션 + terminal 매크로)을 먼저 보고
        // 없으면 빌트인(`default_*_bindings`)으로 폴백한다(override/추가/`=unbind`로 기본 끄기/`text:`·`esc:`·`ctrl:`
        // 매크로로 셸 바이트 묶기 가능). 빈 config(테스트·파일 없음)면 사용자 바인딩이 비어 곧장 빌트인으로 떨어진다.
        const result = try self.frame_loop.handleKeyEvent(self.loaded_config.keyBindingResolver(), event);
        switch (result) {
            .terminal_input => |terminal_input| {
                self.total_terminal_input_events += 1;
                self.total_terminal_input_bytes += terminal_input.bytes_len;
                self.resetCursorBlink(); // 타이핑 중 커서가 사라지지 않게
                if (self.find_nav) { // 셸에 타이핑 재개 = 검색 종료 — 닫힘-네비 하이라이트 해제
                    self.find_nav = false;
                    self.find_matches.clearRetainingCapacity();
                    self.metal_dirty = true; // 현재-매치 하이라이트가 한 프레임 남지 않게(다른 clear 사이트와 일관)
                }
            },
            .app_action => |action| {
                self.total_app_key_events += 1;
                self.dispatchAppAction(action); // Cmd+T 등 → 탭 생성/전환(native 최소)
            },
            .ignored => self.total_ignored_key_events += 1,
        }
        self.writeSummaryFromState();
        self.last_summary.last_event_kind = @intFromEnum(EventKind.key_down);
        return self.last_summary;
    }

    /// 뷰포트를 delta_up줄만큼 스크롤한다(+위=과거, -아래=현재). 스크롤 로직은 TerminalCore가
    /// 소유하고, 여기선 다음 tick이 새 뷰를 그리도록 metal_dirty만 세운다(Swift는 휠/키 이벤트를
    /// 이 함수로 넘기는 얇은 글루다).
    pub fn scroll(self: *AppSession, delta_up: i32) void {
        if (!self.surface_initialized) return;
        const surface = self.activeSurface();
        // scrollViewport는 코어 mutate라 reader로 위임(full (a), docs/io-render-threading.md §9 P3-4).
        self.runtime.enqueueCoreCommand(surface.id, .{ .scroll = @as(isize, delta_up) }, self.io) catch {};
        self.metal_dirty = true;
    }

    /// 마우스/트랙패드 휠 스크롤. Swift는 raw NSEvent 값(델타 포인트 + 정밀 델타 여부)만 넘기고,
    /// 줄 수 환산은 여기서 실제 cell 메트릭으로 한다(네이티브 최소화). 정밀(트랙패드) 델타는 포인트
    /// 단위라 한 줄 높이(포인트)로 나눠 줄 수로 바꾸고, 줄 단위(마우스 휠) 델타는 그대로 줄 수다.
    /// 한 줄 미만의 정밀 델타는 wheel_accum에 누적해 천천히 스크롤해도 줄이 소실되지 않는다.
    /// NaN/∞·거대값은 무시/clamp한다(@intFromFloat trap 방지).
    pub fn scrollWheel(self: *AppSession, delta_y: f64, delta_x: f64, precise: bool, x_px: f64, y_px: f64) void {
        if (!self.surface_initialized) return;
        // 방향이 뒤집히면 1줄 미만 잔여를 버린다 — 이전 방향의 residue가 첫 반대 틱을 상쇄해
        // 방향 전환이 굼뜨게 느껴지는 것 방지(iTerm2/xterm.js 동작).
        if (std.math.isFinite(delta_y) and delta_y * self.wheel_accum < 0) self.wheel_accum = 0;
        const lines = wheelDeltaToLines(&self.wheel_accum, delta_y, precise, self.cell_height_px, self.scale_milli);
        // 휠은 '커서 아래' panel로 라우팅한다 — split에서 비활성 panel 위 스크롤이 그 panel을 스크롤한다(포커스는
        // 안 바꾼다). 단일 panel이면 활성과 같고, 사이드바/밖이면 활성 surface로 fallback.
        const target = self.surfaceAt(x_px, y_px) orelse self.activeSurface();
        // mouse reporting은 활성 pane(포커스 앱) 기준으로 보낸다 — 좌표(pxToCell)도 활성이라 일관(클릭 reporting과
        // 같은 기준). 커서 아래 비활성 pane이 tracking이어도 활성에 보낸다(pane↔좌표 불일치 방지). non-tracking이면
        // 아래에서 커서 아래 pane(target)을 스크롤백한다. lines>0=위(과거)=64, <0=아래=65, 앱이 휠을 소비한다.
        const active = self.activeSurface();
        // mouse_tracking 읽기 + reportMouse(코어 response 생성)는 락 아래(리더 core.write와 response 경합 방지,
        // docs/io-render-threading.md PR3). writeInput은 락 밖(PR1 패턴).
        // mouse_tracking 읽기는 메인 락-아래(읽기 위임 안 함, §9.1). reportMouse(코어 mutate+응답)는 full (a)
        // (docs/io-render-threading.md §9 P3-4)로 reader에 위임 — 휠 lines만큼 반복 enqueue, reader가 각 적용 후
        // pendingResponse를 PTY로 흘린다.
        const tracking = blk: {
            active.lockCore(self.io);
            defer active.unlockCore(self.io);
            break :blk active.core.mouse_tracking != .none;
        };
        if (tracking) {
            if (lines != 0) {
                if (self.pxToCell(x_px, y_px)) |cell| {
                    const wb: u8 = if (lines > 0) 64 else 65;
                    var n: i32 = if (lines > 0) lines else -lines;
                    while (n > 0) : (n -= 1) self.runtime.enqueueCoreCommand(active.id, .{ .report_mouse = .{ .button = wb, .col = cell.col, .row = cell.row, .x_px = cell.term_x_px, .y_px = cell.term_y_px, .pressed = true, .motion = false, .mods = 0 } }, self.io) catch {};
                }
            }
            return; // 휠을 앱이 소비 — 스크롤백/가로 스크롤 안 함
        }
        self.scrollSurfaceLines(target, lines);
        // 가로 델타(트랙패드 2-finger 가로 스와이프) → 커서 아래 pane 탭 바 가로 스크롤(#2b). 세로(터미널 스크롤백)와
        // 독립 축이라 한 이벤트(대각선 스와이프)에서 둘 다 처리될 수 있다. 탭이 안 넘치면 scrollTabBarAt이 무동작.
        if (std.math.isFinite(delta_x) and delta_x != 0) {
            if (delta_x * self.tab_wheel_accum < 0) self.tab_wheel_accum = 0; // 방향 전환 시 잔여 버림(세로와 같은 규율)
            const cols = wheelDeltaToLines(&self.tab_wheel_accum, delta_x, precise, self.cell_width_px, self.scale_milli); // 셀 환산 범용 — 가로는 cell_width
            if (cols != 0) self.scrollTabBarAt(x_px, y_px, cols);
        }
    }

    /// 창 포커스 변화(OS window key/resign)를 활성 surface 코어에 알린다 — focus reporting(DECSET 1004)이 켜져
    /// 있으면 CSI I(gained)/CSI O(lost)가 PTY로 흐른다(vim FocusGained/Lost). off면 reportFocus가 무동작이라 무전송.
    pub fn focusChanged(self: *AppSession, gained: bool) void {
        self.window_focused = gained; // 완료 알림: 포커스 창의 활성 탭만 "보고 있는" 것으로 친다.
        if (!self.surface_initialized) return;
        // Phase 3 위임(docs/io-render-threading.md §9 P3-3): reportFocus는 코어 mutate(+response 생성)라 메인이
        // 직접 안 하고 reader로 위임한다 — reader가 적용 후 pendingResponse를 PTY로 흘린다(non-interactive 폴백은
        // enqueueCoreCommand가 직접 흘림). focus→응답 인과는 그 명령 처리 시 응답 생성으로 보존.
        self.runtime.enqueueCoreCommand(self.activeSurface().id, .{ .report_focus = gained }, self.io) catch {};
    }

    /// 스크린 점(backing px) 아래 panel의 활성 Term surface(없으면 — 사이드바/밖 — null). 휠 라우팅에 쓴다.
    /// 활성 탭 leaf rect를 펴 paneAtPoint로 그 점의 pane을 찾는다. 단일 panel이면 그 panel(=활성)을 돌려준다.
    fn surfaceAt(self: *AppSession, x_px: f64, y_px: f64) ?*app.Surface {
        if (!self.surface_initialized) return null;
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return null;
        const pane = paneAtPoint(leaf_rects.items, x_px, y_px) orelse return null;
        return &pane.activeTerm().surface;
    }

    /// 가로 스와이프(delta_x→cols)를 커서 아래 pane의 탭 바 가로 스크롤로 바꾼다(#2b). 그 pane이 탭 넘침(has_scroll)이
    /// 아니면 무동작. 클릭 ‹›와 같이 eff(=bm.scroll_cols, [0,max] clamp된 값) 기준이라 stale tab_scroll_cols가 자동
    /// 정정된다(다음 렌더 tabLayout이 다시 clamp). natural 방향: 오른쪽 스와이프(cols>0)면 왼쪽 탭으로(scroll 감소).
    fn scrollTabBarAt(self: *AppSession, x_px: f64, y_px: f64, cols: i32) void {
        var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
        defer leaf_rects.deinit(self.allocator);
        self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch return;
        for (leaf_rects.items) |lr| {
            if (!pointInRect(x_px, y_px, lr.rect)) continue; // 커서가 이 pane(탭 바+터미널) 영역일 때만
            const pb = self.paneBar(lr.rect, lr.leaf) orelse return;
            const count = lr.leaf.terms.items.len;
            const m = barMetrics(pb.tabs, self.cell_width_px, count, self.buildChromeTokens().space.tab_width_cols, lr.leaf.tab_scroll_cols) orelse return;
            if (!m.has_scroll) return; // 탭이 안 넘침 — 가로 스크롤할 것 없음
            const eff = m.scroll_cols; // clamp된 현재 스크롤(stale 정정 기준 — 클릭 ‹›와 동일)
            const mag: u32 = @intCast(@abs(cols));
            lr.leaf.tab_scroll_cols = if (cols > 0) eff -| mag else eff + mag; // cols>0(오른쪽 스와이프)→왼쪽 탭(감소), cols<0→오른쪽(증가, 렌더서 [0,max] clamp)
            self.metal_dirty = true;
            return;
        }
    }

    /// 줄 수만큼 스크롤한다. alt screen + alternate scroll(DECSET 1007)이면 화살표 키로 변환해
    /// 프로그램(less/vim)에 보낸다(iTerm2/Terminal.app 동작, DECCKM이면 SS3 형식). 휠과
    /// Shift+PageUp/Down이 같은 경로를 타 일관되게 동작한다.
    /// 활성 surface를 줄 수만큼 스크롤(키보드 PageUp/Down 경로). 휠은 surfaceAt으로 고른 surface에 직접 쓴다.
    fn scrollLines(self: *AppSession, lines: i32) void {
        self.scrollSurfaceLines(self.activeSurface(), lines);
    }

    /// 주어진 surface를 줄 수만큼 스크롤한다 — 휠은 커서 아래 panel(비활성 가능), 키보드는 활성. alt screen +
    /// alternate scroll(DECSET 1007)이면 그 surface PTY로 화살표 키를 보내고(less/vim 등 프로그램 스크롤),
    /// 아니면 그 surface의 뷰포트를 스크롤한다(scrollback). 줄 0이면 무동작.
    fn scrollSurfaceLines(self: *AppSession, surface: *app.Surface, lines: i32) void {
        if (lines == 0) return;
        const core = &surface.core;
        // alt+alternate_scroll 판정 + (alt면) encodeKey는 코어 read라 메인 락-아래(읽기는 위임 안 함, §9.1).
        // non-alt의 scrollViewport(코어 mutate)는 full (a)(docs/io-render-threading.md §9 P3-4)로 reader에 위임한다.
        var is_alt = false;
        var key_buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
        var alt_len: usize = 0;
        {
            surface.lockCore(self.io);
            defer surface.unlockCore(self.io);
            if (core.alt_active and core.alternate_scroll) {
                is_alt = true;
                const key: terminal.input.Key = if (lines > 0) .arrow_up else .arrow_down;
                const bytes = core.encodeKey(.{ .key = key }, &key_buffer) catch return;
                alt_len = bytes.len;
            }
        }
        if (is_alt) {
            // alt screen + alternate scroll(DECSET 1007): 프로그램에 화살표 키를 보낸다(PTY write — core mutate 아님).
            // 시퀀스를 한 버퍼에 반복해 묶어 보낸다 — 줄마다 writeInput을 하면 빠른 플릭에서 PTY 버퍼가 차 나머지가 드랍.
            const bytes = key_buffer[0..alt_len];
            var batch: [512]u8 = undefined;
            const per_batch = batch.len / bytes.len;
            var remaining: u32 = @abs(lines);
            while (remaining > 0) {
                const count = @min(remaining, @as(u32, @intCast(per_batch)));
                var len: usize = 0;
                var i: u32 = 0;
                while (i < count) : (i += 1) {
                    @memcpy(batch[len..][0..bytes.len], bytes);
                    len += bytes.len;
                }
                self.runtime.writeInput(surface.id, .{ .bytes = batch[0..len] }) catch break; // 쓰기 실패 = 남은 스크롤 드랍, 중단
                remaining -= count;
            }
            return;
        }
        // non-alt: scrollViewport를 reader에 위임.
        self.runtime.enqueueCoreCommand(surface.id, .{ .scroll = @as(isize, lines) }, self.io) catch {};
        self.metal_dirty = true;
    }

    /// 버튼 없는 마우스 이동(hover)을 mouse reporting으로 PTY에 흘린다. Swift가 mouseMoved마다(60~120Hz)
    /// 부르지만, any-event(DECSET 1003)가 아니면 즉시 빠진다 — 매 이동마다 chrome 히트테스트(leaf_rects alloc)·
    /// 셀 변환을 돌리지 않게 tracking gate를 가장 먼저 친다. tracking 읽기·reportMouse(코어 response 생성)는
    /// 락 아래(리더 core.write·response 경합 방지, docs/io-render-threading.md PR3), writeInput은 락 밖(PR1).
    /// 같은 셀로의 반복 이동은 스킵해(셀 단위 변화만 리포트) PTY·트래킹 앱 부하를 막는다. button 3 = no-button.
    /// 베이스: xterm — any-event(1003)는 버튼 없는 motion도 Cb=3(+32 motion 비트)로 인코딩한다.
    pub fn mouseMoved(self: *AppSession, x_px: f64, y_px: f64, mods: i32) void {
        if (!self.surface_initialized) return;
        const active = self.activeSurface();
        // 비-1003이면 dedup도 비운다 — 다음 1003 진입의 첫 셀이 stale last_motion_cell로 막히지 않게.
        {
            active.lockCore(self.io);
            defer active.unlockCore(self.io);
            if (active.core.mouse_tracking != .any) {
                self.last_motion_cell = null;
                return;
            }
        }
        if ((mods & 4) != 0 or (mods & 8) != 0) return; // shift·option은 셀렉션 override — 리포트 안 함
        if (self.pointOnChrome(x_px, y_px)) {
            self.last_motion_cell = null; // chrome(사이드바·탭 바) 경유 — 터미널 재진입 첫 셀이 stale로 막히지 않게
            return;
        }
        // pxToCell은 좌표를 grid 안으로 clamp하므로(영역 밖도 가장자리 셀) chrome 가드를 먼저 통과해야 한다.
        const cell = self.pxToCell(x_px, y_px) orelse return;
        // 같은 셀로의 반복 이동은 스킵 — 셀 단위 변화만 보낸다(중복 motion 억제).
        if (self.last_motion_cell) |last| {
            if (last.col == cell.col and last.row == cell.row) return;
        }
        self.last_motion_cell = .{ .col = cell.col, .row = cell.row };
        // reportMouse(코어 mutate + 응답)는 full (a)(docs/io-render-threading.md §9 P3-4)로 reader에 위임 — reader가
        // 적용 후 pendingResponse를 PTY로 흘린다. button 3 = no-button motion(any-event 1003). 적용 시점에 앱이 1003을
        // 꺼도 reportMouse 자체가 mouse_tracking 가드(.none이면 무동작)라 안전.
        self.runtime.enqueueCoreCommand(active.id, .{ .report_mouse = .{ .button = 3, .col = cell.col, .row = cell.row, .x_px = cell.term_x_px, .y_px = cell.term_y_px, .pressed = true, .motion = true, .mods = @intCast(mods) } }, self.io) catch {};
    }

    /// backing 픽셀 좌표를 (row, col) 셀로 변환한다(grid 안으로 clamp). 핵심: clamp를 float
    /// 도메인에서 먼저 한 뒤 @intFromFloat 한다 — 거대한 finite 좌표(손상/악성 입력)가 i64 변환
    /// 에서 trap(앱 패닉)하던 것을 막는다(wheelDeltaToLines와 같은 규율). 비유한값은 null.
    fn pxToCell(self: *const AppSession, x_px: f64, y_px: f64) ?struct { row: u16, col: u16, term_x_px: u16, term_y_px: u16 } {
        if (!std.math.isFinite(x_px) or !std.math.isFinite(y_px)) return null;
        const core = &self.activeSurfaceConst().core;
        const cw: f64 = @floatFromInt(if (self.cell_width_px > 0) self.cell_width_px else placeholder_cell_width_px);
        const ch: f64 = @floatFromInt(if (self.cell_height_px > 0) self.cell_height_px else placeholder_cell_height_px);
        const max_col: f64 = @floatFromInt(core.size.cols - 1);
        const max_row: f64 = @floatFromInt(core.size.rows - 1);
        // 활성 panel은 자기 rect의 origin(active_pane_rect.x/y = paneTermRect 단일 출처, window padding·사이드바
        // 포함)에서 그려진다 — 단일 panel이면 (사이드바 폭+padding_x, padding_y), split이면 서브-rect의 origin.
        // 셀 렌더 origin과 같은 출처라 정합한다(metalFrame.terminal_origin_x_px는 사이드바 bg strip 폭 전용 — 셀
        // 위치엔 안 쓰임). 스크린 좌표에서 그 origin을 빼야 활성 panel의 열/행이 된다 — 안 빼면 선택/클릭 블록이
        // origin만큼 어긋난다(라이브 제보). panel 왼쪽/위 바깥(음수) 클릭은 0 clamp라 (0,0) 모서리에 붙는다.
        const term_x = x_px - @as(f64, @floatFromInt(self.active_pane_rect.x));
        const term_y = y_px - @as(f64, @floatFromInt(self.active_pane_rect.y));
        const col_f = std.math.clamp(@max(term_x, 0) / cw, 0, max_col);
        const row_f = std.math.clamp(@max(term_y, 0) / ch, 0, max_row);
        // SGR-Pixels(1016) mouse 리포트용 픽셀: 셀과 같은 origin(활성 pane 좌상단)·음수 0 clamp 정책으로
        // 터미널 영역 backing px를 구해 셀 리포트와 같은 지점을 가리키게 한다. 영역 폭/높이-1로 clamp하고
        // u16 상한(65535)으로 saturate해 @intFromFloat가 안전하다.
        const max_x: f64 = @min(@max(@as(f64, @floatFromInt(core.size.cols)) * cw - 1, 0), 65535);
        const max_y: f64 = @min(@max(@as(f64, @floatFromInt(core.size.rows)) * ch - 1, 0), 65535);
        const px_x = std.math.clamp(@max(term_x, 0), 0, max_x);
        const px_y = std.math.clamp(@max(term_y, 0), 0, max_y);
        return .{
            .row = @intFromFloat(row_f),
            .col = @intFromFloat(col_f),
            .term_x_px = @intFromFloat(px_x),
            .term_y_px = @intFromFloat(px_y),
        };
    }

    /// 마우스 선택. kind 1=down(선택 시작), 2=drag(확장), 3=up(확정 — 드래그 선택인데 이동이
    /// 없었으면 클릭으로 보고 해제), 4=더블클릭(단어 선택), 5=트리플클릭(논리 줄 선택). 좌표는
    /// backing 픽셀 — 셀 변환은 권위 있는 cell 메트릭을 가진 여기서 한다.
    pub fn mouse(self: *AppSession, kind: i32, x_px: f64, y_px: f64, button: i32, mods: i32) void {
        if (!self.surface_initialized) return;
        // 인라인 rename 중 마우스 down(어디든)이면 편집을 확정한다(포커스 상실 = 확정 — docs/tabs-splits-layout.md).
        // 그 뒤 클릭은 정상 처리된다(탭 전환·pane 포커스 등). drag/up(2/3)은 down이 선행하므로 여기서 안 걸린다.
        if (kind == 1 and self.rename != null) self.commitRename();
        // 컨텍스트 메뉴가 열려 있으면 클릭(down)을 메뉴로 라우팅한다 — 항목 위면 그 항목 실행, 밖이면 닫는다(다른
        // 마우스 이벤트도 메뉴 중엔 소비). 메뉴는 최상위 모달이라 뒤(터미널/탭)로 안 흘린다.
        if (self.chrome_host.context_menu.open) {
            if (kind == 1) {
                if (chrome.components.context_menu.itemAt(&self.chrome_host.context_menu, self.contextMenuItems(), self.buildChromeProps(), x_px, y_px)) |idx| {
                    self.chrome_host.context_menu.selected = idx;
                    self.acceptContextMenu();
                } else {
                    self.chrome_host.context_menu.hide();
                    self.context_menu_target = null;
                    self.metal_dirty = true;
                }
            }
            return;
        }
        // 우클릭(button==2, down) → rename 대상이면 컨텍스트 메뉴("Rename")를 띄운다. 대상이 없을 때:
        //  - chrome(사이드바·탭 바) 위면 consume(우클릭이 좌클릭처럼 탭 전환·newTab 하지 않게).
        //  - 터미널 본문이면 **fall through** — 아래 mouse-reporting 경로(DECSET 1000~1003)가 우버튼을 트래킹 앱에
        //    리포트한다. 무조건 return하면 우-down은 안 가고 우-drag/up(kind 2/3)만 리포트돼 비대칭이 된다(회귀).
        if (kind == 1 and button == 2) {
            if (self.renameTargetAt(x_px, y_px)) |target| {
                self.context_menu_target = target;
                const items = self.buildContextMenuItems(); // 대상 타입에 맞는 항목(workspace=Rename+Pin+배경, pane/term=Rename)
                self.chrome_host.context_menu.show(@intFromFloat(x_px), @intFromFloat(y_px), items.len);
                self.metal_dirty = true;
                return;
            }
            if (self.pointOnChrome(x_px, y_px)) return; // chrome 위: consume
            // 터미널 본문: 아래 reporting 경로로 흘린다(트래킹 앱 우클릭 보존).
        }
        // 더블클릭(kind 4) → 그 자리의 rename 대상(사이드바 슬롯·pane 라벨·Term 탭)을 인라인 편집한다. 대상이 없으면
        // return 안 하고 아래로 흘러 kind 4 = 터미널 단어 선택으로 폴백한다. 첫 클릭(kind 1)이 이미 포커스했고 그
        // 사이 up(3)이 드래그 arm을 풀었다(더블클릭은 드래그 아님 — 안전하게 한 번 더 해제). 우클릭 메뉴와 같은
        // renameTargetAt를 써 "더블클릭 == 우클릭"이 같은 자리를 같은 대상으로 친다.
        if (kind == 4) {
            if (self.renameTargetAt(x_px, y_px)) |target| {
                self.sidebar_drag_active = false;
                self.tab_drag_active = false;
                self.startRename(target);
                return;
            }
        }
        // 사이드바 탭 드래그가 진행 중이면 drag(2)/up(3)을 캡처한다(x가 사이드바 밖으로 나가도) — 새
        // down(1)은 아래 일반 처리로 흘려 드래그를 새로 시작한다. drag는 타겟 슬롯으로 live 재정렬한다.
        if (self.sidebar_drag_active and (kind == 2 or kind == 3)) {
            if (kind == 2 and self.sidebar_drag_index < self.tabs.items.len) {
                const raw_target = chrome.components.sidebar.dragTargetSlot(y_px, self.sidebar_header_height_px, self.sidebar_slot_height_px, self.tabs.items.len);
                // moveTab이 그룹(고정/비고정)으로 clamp한 **실제 안착 인덱스**를 단일 출처로 받는다(여기서 따로
                // pre-clamp하지 않는다 — countPinnedTabs O(n)가 drag당 1회로 줄고, 이중-clamp 일치 가정이 사라진다).
                // sidebar_drag_index를 안착 인덱스로 갱신해 다음 delta가 *그* 탭을 재정렬한다. no-op이면 from을 그대로 반환.
                self.sidebar_drag_index = self.moveTab(self.sidebar_drag_index, raw_target);
            } else if (kind == 3) {
                self.sidebar_drag_active = false; // up: 드래그 종료
            }
            return;
        }
        // Term 탭 드래그가 진행 중이면 drag(2)/up(3)을 캡처한다 — drag는 소스 pane 바 안에서 x로 타겟 탭을 잡아
        // live 재정렬(PR-E1: pane 내). up이 끝낸다. 새 down(1)은 아래 일반 처리로 흘려 새 드래그를 시작한다.
        if (self.tab_drag_active and (kind == 2 or kind == 3)) {
            if (kind == 2) {
                self.dragTabTo(x_px); // pane 내 live 재정렬(PR-E1)
                self.setDropTarget(self.computeDropTarget(x_px, y_px)); // 드롭 타겟 하이라이트(④b)
                self.tab_drag_x = x_px; // floating 탭이 커서를 따라가게(매 이동 갱신)
                self.tab_drag_y = y_px;
                self.metal_dirty = true;
            } else {
                self.dropTabAt(x_px, y_px); // up: 다른 pane 바면 그 pane으로 이동(PR-E2)·본문이면 split(④)
                self.tab_drag_active = false;
                self.tab_drag_pane = null;
                self.setDropTarget(null); // 드롭 끝 — 하이라이트 해제
            }
            return;
        }
        // divider 드래그가 진행 중이면 drag(2)/up(3)을 캡처한다(PR6) — drag는 마우스를 bounds 안 ratio로 매핑해
        // split.ratio를 live 변경(panel 재배치), up이 끝낸다. 새 down(1)은 아래 일반 처리로 흘려 새 드래그 시작.
        if (self.divider_drag != null and (kind == 2 or kind == 3)) {
            if (kind == 2) self.dragDividerTo(x_px, y_px) else {
                self.divider_drag = null;
            }
            return;
        }
        // 사이드바 폭 조절 드래그가 진행 중이면 drag(2)/up(3)을 캡처한다(③a) — drag는 경계를 x로 잡아 폭을 live
        // 갱신, up이 끝낸다. 새 down(1)은 아래로 흘려 새 드래그를 시작한다.
        if (self.sidebar_resize_active and (kind == 2 or kind == 3)) {
            if (kind == 2) self.setSidebarWidthPx(x_px) else {
                self.sidebar_resize_active = false;
            }
            return;
        }
        // 스크롤바 thumb 드래그가 진행 중이면 drag(2)/up(3)을 캡처한다 — drag는 마우스 y를 view_offset으로
        // 매핑(스크롤), up이 끝낸다. 새 down(1)은 아래로 흘려 새 드래그(또는 일반 클릭)를 시작한다. 다른
        // 드래그 가드처럼 x가 영역 밖으로 나가도 캡처를 유지한다(thumb를 잡았으면 끝까지 따라간다).
        if (self.scrollbar_drag_grab != null and (kind == 2 or kind == 3)) {
            if (kind == 2) self.dragScrollbarTo(y_px) else {
                self.scrollbar_drag_grab = null;
            }
            return;
        }
        // 사이드바 우측 경계 down → 폭 조절 드래그 시작(사이드바 슬롯/터미널보다 먼저 — 경계는 둘 사이 밴드).
        if (kind == 1 and chrome.components.sidebar.onResizeEdge(x_px, self.sidebar_width_px, if (self.cell_width_px > 0) self.cell_width_px else placeholder_cell_width_px)) {
            self.sidebar_resize_active = true;
            self.drag_autoscroll = 0;
            self.mouse_drag_selecting = false;
            return;
        }
        // 사이드바 영역 클릭은 Maru UI다(터미널 선택/리포팅 아님). down(1)에서 슬롯을 hit-test한다 —
        // 슬롯 우측 ✕ zone이고 그 슬롯이 호버 중(✕가 보임)이면 그 탭을 닫고, 아니면 그 탭으로 전환하고
        // 드래그 재정렬을 시작한다(이어지는 drag가 순서를 바꾼다 — 안 움직이면 그냥 클릭=전환). 슬롯 밖
        // (빈 영역)은 무시. 진행 중이던 터미널 드래그 선택은 멈춘다. 사이드바 클릭은 터미널에 안 닿는다.
        if (self.inSidebar(x_px)) {
            if (kind == 1) {
                // 상단 헤더: 새 워크스페이스 아이콘 → 새 탭(하단 "+"를 헤더로 이동), view options 아이콘 → 메뉴(P4),
                // 검색 영역 → 검색 활성(P3). 헤더 밖(none)이면 카드 슬롯 hit-test(✕ 닫기 / 전환 + 드래그 재정렬).
                const header_region = chrome.components.sidebar.headerHit(x_px, y_px, self.sidebar_width_px, self.cell_width_px, self.sidebar_header_height_px);
                switch (header_region) {
                    .new_workspace => _ = self.newTab() catch {},
                    .view_options => {}, // P4: view options 메뉴(아이콘 자리만 — 클릭 핸들은 P4에서 연결)
                    .search => {
                        self.sidebar_search_active = true; // 검색바 클릭 → 활성(키/IME가 검색으로 라우팅)
                        self.rebuildSidebar() catch {}; // 보존된 검색어가 있으면 필터를 즉시 재개(blur 중 일시정지됐던 것)
                        self.resetCursorBlink();
                        self.metal_dirty = true;
                    },
                    .none => if (self.sidebarSlotAt(y_px)) |slot| if (self.visibleTab(slot)) |tab_idx| {
                        // slot=표시 슬롯, tab_idx=원본 탭(검색 필터 역매핑). 닫기/전환/드래그는 원본 인덱스로 한다.
                        const on_close = chrome.components.sidebar.closeButton(x_px, self.sidebar_width_px, self.cell_width_px) and
                            self.hovered_slot != null and self.hovered_slot.? == slot;
                        if (on_close) {
                            self.closeTab(tab_idx);
                        } else {
                            self.hovered_slot = null; // 드래그 중엔 stale 호버 밴드/✕를 안 보이게
                            _ = self.switchTab(tab_idx);
                            // 검색 필터 중엔 드래그 재정렬을 비활성(부분 목록 재정렬은 의미 모호). 비활성/빈 검색이면 visible=전체라
                            // 정상 동작. 고정 탭도 arm — moveTab/드래그 타겟이 같은 그룹으로 clamp(고정/비고정 영역 안 넘음).
                            if (!self.sidebar_search_active and tab_idx < self.tabs.items.len) {
                                self.sidebar_drag_active = true;
                                self.sidebar_drag_index = tab_idx;
                            }
                        }
                    },
                }
                // 검색 영역이 아닌 곳(카드·아이콘·빈 영역)을 클릭하면 검색을 blur한다 — 키 포커스를 터미널로 되돌려
                // '검색 활성 중 터미널 입력 불가'를 푼다(검색어는 보존). 카드 클릭의 visibleTab 역매핑은 위에서 이미
                // 끝나 매핑이 안 깨진다. .search 분기는 방금 active=true로 켠 참이라 제외한다.
                if (kind == 1 and header_region != .search and self.sidebar_search_active) self.blurSidebarSearch();
            }
            // 사이드바 더블클릭(kind 4) rename은 위 통합 kind==4 핸들러(renameTargetAt)가 이미 처리했다.
            self.drag_autoscroll = 0;
            self.mouse_drag_selecting = false;
            return;
        }
        // 사이드바 '밖'(터미널·pane·탭 바)을 클릭하면 검색을 blur한다 — 같은 이유(키를 터미널로 되돌림, 검색어 보존).
        // 사이드바 밖은 visibleTab 의존이 없어 여기서 바로 blur해도 안전하다.
        if (kind == 1 and self.sidebar_search_active) self.blurSidebarSearch();
        // down(1)에서 pane/탭 바 클릭을 hit-test한다(kind!=1이면 단락 평가로 self.tabs를 안 건드린다 — 최소-셋업
        // 드래그 테스트는 kind 2/3만 보낸다). 활성 탭 leaf rect를 한 번 펴 ① 탭 바 클릭(어느 pane의 상단 바면 그
        // pane 포커스 + 클릭한 Term 탭 전환) ② 다른 panel의 터미널 영역 클릭(그 pane 포커스)을 차례로 본다. 둘 다
        // 클릭을 소비한다 — 터미널 선택은 활성 panel의 '바 아래' 클릭에서만 시작한다. 활성 panel의 활성 탭/터미널
        // 클릭은 무전환으로 아래 일반 선택 경로로 흐른다.
        if (kind == 1) {
            var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
            defer leaf_rects.deinit(self.allocator);
            if (self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects)) |_| {
                // ① 탭 바 클릭 → pane 포커스 + Term 탭 전환. 클릭이 호버된 탭의 ✕ zone이면 그 Term을 닫는다
                //    (focusPaneByPtr+focusTerm로 그 탭을 활성으로 만든 뒤 closeActiveTermOrPane cascade). 단일 panel도
                //    Term이 여럿이면 전환/닫기 된다. ✕는 호버 중일 때만 보이므로 hovered_tab과 일치할 때만 닫는다.
                for (leaf_rects.items) |lr| {
                    const pb = self.paneBar(lr.rect, lr.leaf) orelse continue;
                    if (pointInRect(x_px, y_px, pb.full)) {
                        // 좌측 pane 라벨 세그먼트 클릭 → 그 pane만 포커스(탭 전환/드래그 arm 안 함). 탭 hit-test는 라벨 뒤
                        // 영역(pb.tabs)만 대상이라, 라벨 영역 x가 tabIndex의 좌측 clamp로 탭0을 잘못 잡는 걸 막는다.
                        // (PR4/PR5에서 더블클릭·우클릭 rename 트리거가 이 라벨 영역에 붙는다.)
                        if (pb.label_cols > 0 and x_px < @as(f64, @floatFromInt(pb.tabs.x))) {
                            _ = self.focusPaneByPtr(lr.leaf);
                            self.drag_autoscroll = 0;
                            self.mouse_drag_selecting = false;
                            return;
                        }
                        const count = lr.leaf.terms.items.len;
                        const m = barMetrics(pb.tabs, self.cell_width_px, count, self.buildChromeTokens().space.tab_width_cols, lr.leaf.tab_scroll_cols);
                        // 바 우측 ‹›(가로 스크롤) 버튼 클릭 → 그 pane의 tab_scroll_cols를 ±tab_w(한 탭). 넘침 범위로 clamp. "+"·탭보다 먼저.
                        if (m) |bm| if (bm.inScrollLeftZone(x_px)) {
                            _ = self.focusPaneByPtr(lr.leaf);
                            lr.leaf.tab_scroll_cols = bm.scroll_cols -| bm.tab_w; // ‹ 이전 탭 — bm.scroll_cols(=clamp된 eff) 기준이라 stale 자동 정정
                            self.metal_dirty = true;
                            return;
                        };
                        if (m) |bm| if (bm.inScrollRightZone(x_px)) {
                            _ = self.focusPaneByPtr(lr.leaf);
                            lr.leaf.tab_scroll_cols = bm.scroll_cols + bm.tab_w; // › 다음 탭 — 다음 렌더의 tabLayout이 [0,max]로 clamp
                            self.metal_dirty = true;
                            return;
                        };
                        // 바 우측 "+" 버튼 클릭 → 그 pane을 포커스하고 새 Term을 띄운다(⌘T의 마우스 버전). 탭/✕보다 먼저.
                        if (m) |bm| if (bm.inPlusZone(x_px)) {
                            _ = self.focusPaneByPtr(lr.leaf);
                            self.newTermInActivePane() catch {};
                            self.drag_autoscroll = 0;
                            self.mouse_drag_selecting = false;
                            return;
                        };
                        const tab = if (m) |bm| bm.tabIndex(count, x_px) else 0;
                        const on_close = m != null and self.hovered_tab != null and self.hovered_tab.?.pane == lr.leaf and
                            self.hovered_tab.?.tab == tab and
                            m.?.inCloseZone(tab, x_px);
                        _ = self.focusPaneByPtr(lr.leaf); // 다른 pane이면 포커스 이동(같으면 무동작)
                        self.focusTerm(tab); // 그 pane의 클릭한 Term으로(같으면 무동작)
                        if (on_close) {
                            self.hovered_tab = null; // 닫으면 Pane/Term이 바뀔 수 있으니 stale 호버 비움
                            self.closeActiveTermOrPane();
                        } else {
                            // ✕가 아니면 탭 드래그를 arm한다(이어지는 drag(2)가 pane 내 재정렬). 안 끌면 그냥 전환.
                            self.tab_drag_active = true;
                            self.tab_drag_pane = lr.leaf;
                            self.tab_drag_index = tab;
                        }
                        self.drag_autoscroll = 0;
                        self.mouse_drag_selecting = false;
                        return;
                    }
                }
                // ⓐ divider 클릭 → 리사이즈 드래그 시작(PR6). 탭 바(①)보다 뒤·pane 선택(②)보다 앞 — 탭 바는
                //    seam에 붙어 있어 우선권을 주고, divider는 terminal 영역 seam에서 잡는다. drag(2)/up(3)은 위
                //    divider 캡처가 받는다. split일 때만(dividerAtPoint가 단일 panel이면 null).
                if (self.dividerAtPoint(x_px, y_px)) |hit| {
                    self.divider_drag = hit.split;
                    self.divider_drag_seg = hit.seg; // neutral seg 직접(재변환 없음 — 드래그 중 dragRatio가 쓴다)
                    self.drag_autoscroll = 0;
                    self.mouse_drag_selecting = false;
                    return;
                }
                // ② split에서 다른 panel의 터미널 영역 클릭 → 그 pane 포커스(활성 panel이면 아래 선택 경로로).
                if (paneAtPoint(leaf_rects.items, x_px, y_px)) |pane| {
                    if (pane != self.activePane() and self.focusPaneByPtr(pane)) {
                        self.drag_autoscroll = 0;
                        self.mouse_drag_selecting = false;
                        return;
                    }
                }
            } else |_| {}
        }
        // 스크롤바 thumb/트랙 down(활성 pane 우측, 스크롤백 있을 때) → thumb 드래그 시작. 터미널 선택/리포팅
        // 보다 먼저 가로챈다 — 우측 가장자리 얇은 띠라 평소 셀 선택을 거의 안 가린다(스크롤백 없으면 스크롤바
        // 자체가 없어 이 분기도 안 탄다). 트랙(thumb 밖) 클릭은 즉시 그 지점으로 점프하고 이어서 드래그한다.
        if (kind == 1) {
            if (self.scrollbarGrabAt(x_px, y_px)) |grab| {
                self.scrollbar_drag_grab = grab;
                self.drag_autoscroll = 0;
                self.mouse_drag_selecting = false;
                self.dragScrollbarTo(y_px);
                return;
            }
        }
        const cell = self.pxToCell(x_px, y_px) orelse {
            // 비유한(NaN/Inf) 좌표 — 셀로 못 바꾼다. up(3)/down(1)이면 드래그 자동 스크롤을
            // 멈춘다(안 그러면 mouseUp이 좌표 손상으로 와도 autoscroll이 30Hz로 영원히 돈다).
            if (kind == 1 or kind == 3) {
                self.drag_autoscroll = 0;
                self.mouse_drag_selecting = false;
            }
            return;
        };
        const col = cell.col;
        const row = cell.row;
        const click_surface = self.activeSurface();
        const core = &click_surface.core;
        // mouse reporting: 트래킹 모드(DECSET 1000~1003)고 shift·option 미포함이면 셀렉션 대신 앱에 리포트한다 —
        // shift+click은 선형 셀렉션 override, option+click은 블록 override(iTerm2 관례). mods: shift=4·option=8.
        // mouse_tracking 읽기 + reportMouse(코어 response 생성)는 락 아래(리더 core.write와 response 경합 방지,
        // docs/io-render-threading.md PR3). reporting 모드면 진행 중 셀렉션 autoscroll도 멈춘다. writeInput은 락 밖.
        // mouse_tracking 읽기는 메인 락-아래(읽기는 위임 안 함 — §9.1). reportMouse(코어 mutate + PTY 응답)는
        // full (a)(P3-4)로 reader에 위임 — reader가 적용 후 pendingResponse를 PTY로 흘린다(메인 직접 mutate 0).
        click_surface.lockCore(self.io);
        const do_report = core.mouse_tracking != .none and (mods & 4) == 0 and (mods & 8) == 0;
        click_surface.unlockCore(self.io);
        if (do_report) {
            self.drag_autoscroll = 0;
            self.mouse_drag_selecting = false;
            self.runtime.enqueueCoreCommand(click_surface.id, .{ .report_mouse = .{
                .button = @intCast(button),
                .col = col,
                .row = row,
                .x_px = cell.term_x_px,
                .y_px = cell.term_y_px,
                .pressed = kind != 3,
                .motion = kind == 2,
                .mods = @intCast(mods),
            } }, self.io) catch {};
            return;
        }
        // 셀렉션은 left 버튼(0)만 시작한다 — tracking 아닌 상태의 right/middle 클릭은 무시(셀렉션·context 메뉴 없음).
        if (button != 0) return;
        const ch: f64 = @floatFromInt(if (self.cell_height_px > 0) self.cell_height_px else placeholder_cell_height_px);
        // 선택 코어 mutate(selectionStart/Extend/Clear/Word/Line)는 full (a)(docs/io-render-threading.md §9 P3-4)로
        // reader에 위임한다 — read-modify-decide(kind 3 "이동 없는 클릭=해제")는 `select_extend_or_collapse` 명령으로
        // reader가 락 아래 **원자 실행**(메인이 위임 후 옛 상태를 읽어 오판하던 문제 제거). 메인은 UI 상태
        // (mouse_drag_selecting·drag_autoscroll·last_drag_col)만 만지고 코어는 안 만진다.
        switch (kind) {
            1 => {
                self.mouse_drag_selecting = true;
                self.drag_autoscroll = 0;
                self.runtime.enqueueCoreCommand(click_surface.id, .{ .select_start = .{ .row = row, .col = col, .block = (mods & 8) != 0 } }, self.io) catch {};
            },
            2 => {
                // 드래그가 활성 panel grid 위/아래 밖으로 나가면 자동 스크롤을 건다(tick이 수행). grid 높이용 rows는
                // 코어 read(메인 락-아래 — 읽기는 위임 안 함, §9.1). panel은 active_pane_rect.y에서 시작.
                const pane_top: f64 = @floatFromInt(self.active_pane_rect.y);
                const rows: u16 = blk: {
                    click_surface.lockCore(self.io);
                    defer click_surface.unlockCore(self.io);
                    break :blk core.size.rows;
                };
                const grid_height: f64 = @as(f64, @floatFromInt(rows)) * ch;
                self.drag_autoscroll = if (y_px < pane_top) 1 else if (y_px > pane_top + grid_height) -1 else 0;
                self.last_drag_col = col;
                self.runtime.enqueueCoreCommand(click_surface.id, .{ .select_extend = .{ .row = row, .col = col } }, self.io) catch {};
            },
            3 => {
                self.drag_autoscroll = 0;
                // 더블/트리플클릭 직후의 up은 그 선택을 건드리면 안 된다(단어가 1칸이면 "이동 없는 클릭" 판정에 걸려 즉시 해제).
                if (!self.mouse_drag_selecting) return;
                self.mouse_drag_selecting = false;
                self.runtime.enqueueCoreCommand(click_surface.id, .{ .select_extend_or_collapse = .{ .row = row, .col = col } }, self.io) catch {};
            },
            4 => {
                self.mouse_drag_selecting = false;
                self.runtime.enqueueCoreCommand(click_surface.id, .{ .select_word = .{ .row = row, .col = col } }, self.io) catch {};
            },
            5 => {
                self.mouse_drag_selecting = false;
                self.runtime.enqueueCoreCommand(click_surface.id, .{ .select_line = row }, self.io) catch {};
            },
            else => return,
        }
        self.metal_dirty = true;
    }

    /// 커서/오버레이 caret 깜빡임 한 스텝(30Hz tick마다). 깜빡일 대상이 없으면(steady 커서 + 오버레이 닫힘) 보이는
    /// 위상으로 고정한다 — 토글 없으니 idle 재투영도 없다. 오버레이(find·palette)가 열렸으면 커서 blink 설정과 무관
    /// 하게 caret이 깜빡인다(텍스트 입력 caret 관용). 터미널 커서의 기존 메커니즘(틱-카운터 + suffix-trim)을 그대로 탄다.
    fn updateCursorBlink(self: *AppSession) void {
        const surface = self.activeSurface();
        const core = &surface.core;
        // 코어 읽기(cursor 상태 + viewportHasBlink는 셀 스캔)는 락 아래(docs/io-render-threading.md PR3 —
        // 리더 core.write와 경합 방지). 커서/blink 조건을 먼저 다 읽고 락을 푼다.
        surface.lockCore(self.io);
        // 커서 자체가 깜빡이는 조건(DECSCUSR blink·표시·조합 아님).
        const cursor_blinks = core.cursor_blink and core.cursor_visible and core.preedit == null;
        // 텍스트 blink(SGR 5): config text.blink가 켜졌고 보이는 뷰포트에 blink 셀이 있을 때만 위상을 진행한다
        // (없으면 idle 재투영 없음). blink 글자는 커서/caret과 달리 suffix-trim으로 못 숨겨 full rebuild가 필요하다.
        const text_blinks = self.appearance.blink_text and core.viewportHasBlink();
        surface.unlockCore(self.io);
        const overlay_open = self.chrome_host.find.open or self.chrome_host.palette.open;
        // 인라인 rename 편집 caret도 깜빡인다 — 사이드바/탭/라벨 셀 스트림의 '|' 글자라(터미널 커서처럼 suffix-trim
        // 으로 못 숨김) text-blink와 같이 full rebuild가 필요하다(renameEditText가 blink_visible로 '|'↔공백 토글).
        const rename_active = self.rename != null;
        // 에이전트 아이콘 펄스: 사이드바 카드 중 running인 에이전트가 있으면 위상을 진행해야 아이콘이 맥동한다.
        // 사이드바 아이콘은 suffix-trim으로 못 숨기는 별도 frame이라 text-blink/rename처럼 full rebuild(dirty)가 필요.
        const agent_pulsing = self.anyAgentRunning();
        // IME 조합 중에는 커서를 **고정**한다(깜빡이면 커서가 덮은 조합 글자가 깜빡 사라짐). 터미널은 cursor_blinks가
        // core.preedit로 이미 막지만, 오버레이/rename은 imeComposingActive로 막아야 한다(단일 출처).
        if ((!cursor_blinks and !overlay_open and !text_blinks and !rename_active and !agent_pulsing) or self.imeComposingActive()) {
            self.resetCursorBlink(); // 깜빡일 게 없거나 조합 중 — 보이는 위상 고정
            return;
        }
        self.blink_ticks += 1;
        if (self.blink_ticks >= blink_interval_ticks) {
            self.blink_ticks = 0;
            self.blink_visible = !self.blink_visible;
            // suffix-trim 토글(재빌드 없음). 오버레이가 열렸으면 suffix=오버레이 caret이라 caret을, 닫혔으면 suffix=
            // 터미널 커서라 커서를 깜빡인다 — 같은 코드(generation↑만, idle에 full-grid reshape 안 함).
            self.metal_buffer.setCursorVisible(self.blink_visible);
            // 텍스트 blink·rename caret·에이전트 아이콘 펄스는 셀/사이드바 glyph라 full rebuild가 필요하다
            // (suffix-trim으로 못 숨김) — dirty 표시해 사이드바를 위상마다 재투영(아이콘 dimRgb 적용/해제).
            if (text_blinks or rename_active or agent_pulsing) self.metal_dirty = true;
        }
    }

    /// 사이드바에 보이는 워크스페이스 카드(탭별 활성 Term) 중 하나라도 에이전트가 running이면 true. 아이콘 펄스
    /// 위상을 진행할지 결정한다(running이 있어야 blink_visible을 토글하고 사이드바를 재투영한다).
    fn anyAgentRunning(self: *AppSession) bool {
        for (self.tabs.items) |tab| {
            if (tab.activePane().activeTerm().agent_state == .running) return true;
        }
        return false;
    }

    /// 깜빡임을 보이는 위상으로 리셋한다(입력/출력 직후 — caret이 항상 보이며 새 주기를 시작).
    fn resetCursorBlink(self: *AppSession) void {
        self.blink_ticks = 0;
        if (!self.blink_visible) {
            self.blink_visible = true;
            self.metal_buffer.setCursorVisible(true);
        }
    }

    /// 드래그 자동 스크롤 한 스텝(30Hz tick마다). 드래그가 grid 밖에 머무는 동안 한 줄씩
    /// 스크롤하며 선택을 가장자리 행으로 확장한다 — 화면보다 긴 내용을 드래그로 선택하는 표준 UX.
    fn applyDragAutoscroll(self: *AppSession) void {
        if (self.drag_autoscroll == 0) return;
        const surface = self.activeSurface();
        const core = &surface.core;
        // selection_anchor/view_offset/selection_head 읽기 + scrollViewport/selectionExtend(코어 변경)는 리더
        // core.write와 경합 — 메서드 전체를 락 아래(docs/io-render-threading.md PR3). 짧은 메서드라 락 비용 무시 가능;
        // 함수가 metal_dirty 직후 끝나므로 함수-스코프 defer로 풀어 early return도 안전히 unlock.
        // 게이트("확장할 선택이 있는가") + grid rows는 코어 read(메인 락-아래 — 읽기는 위임 안 함, §9.1).
        // mouse_drag_selecting로 걸면 더블/트리플클릭(4/5)으로 시작한 선택을 드래그로 화면 밖까지 늘릴 때 자동
        // 스크롤이 영원히 안 걸린다.
        const rows: u16 = blk: {
            surface.lockCore(self.io);
            defer surface.unlockCore(self.io);
            if (core.selection_anchor == null) return; // 확장할 선택 없음
            break :blk core.size.rows;
        };
        const row: u16 = if (self.drag_autoscroll > 0) 0 else rows - 1;
        // scroll+extend는 full (a)(docs/io-render-threading.md §9 P3-4)로 reader에 위임 — **kind-2 드래그 extend와
        // 같은 명령 큐를 타 순서 보존**(둘이 다른 스레드면 선택이 어긋날 수 있다). 원래의 "변화 시만 재투영" 최적화는
        // reader 렌더 트리거로 대체한다(스크롤백 끝에서 포인터를 grid 밖에 둘 때 cheap render tick 몇 개 — §9 trade-off).
        self.runtime.enqueueCoreCommand(surface.id, .{ .scroll_and_extend = .{ .delta = @as(isize, self.drag_autoscroll), .row = row, .col = self.last_drag_col } }, self.io) catch {};
    }

    /// 입력(키·IME)이 지금 어디로 가는가 — **단일 출처**. 모달은 배타적(show가 서로 닫는다 — showNotice/toggleFind/
    /// togglePalette가 나머지를 닫아 한 번에 하나만 열린다)이다. notice는 텍스트 입력 대상이 아니지만(dismiss만) IME가
    /// 뒤(터미널/find)로 새지 않게 **최우선**으로 잡아 무시한다. 모든 IME 연산(preedit set·조합 판정·caret)이 이걸로
    /// 분기해, 라우팅이 콜백마다 흩어져 일부를 누락하던 단일-출처 위반을 없앤다.
    const InputFocus = enum { terminal, notice, rename, sidebar_search, find, palette };
    fn inputFocus(self: *const AppSession) InputFocus {
        if (self.chrome_host.notice.open) return .notice; // 최우선 모달 — 텍스트/IME를 받지 않고 무시(뒤로 안 샘)
        if (self.rename != null) return .rename; // 인라인 rename(find/palette와 배타적 — startRename이 닫음)
        if (self.sidebar_search_active) return .sidebar_search; // 사이드바 검색바(상주 — 활성이면 키/IME를 받는다)
        if (self.chrome_host.find.open) return .find;
        if (self.chrome_host.palette.open) return .palette;
        return .terminal;
    }

    /// 활성 입력 대상의 IME 조합(marked) 텍스트를 교체한다(빈 bytes=해제). inputFocus 단일 출처로 분기 — exhaustive
    /// switch라 입력 대상 추가 시 컴파일러가 누락을 막는다.
    fn imeSetPreedit(self: *AppSession, bytes: []const u8) void {
        switch (self.inputFocus()) {
            .notice => {}, // notice는 조합을 표시하지 않는다(텍스트 입력 대상 아님)
            .rename => self.rename_input.setPreedit(self.allocator, bytes) catch {},
            .sidebar_search => self.sidebar_search_input.setPreedit(self.allocator, bytes) catch {},
            .find => self.chrome_host.find.input.setPreedit(self.allocator, bytes) catch {},
            .palette => self.chrome_host.palette.input.setPreedit(self.allocator, bytes) catch {},
            .terminal => {
                // Phase 3 위임(docs/io-render-threading.md §9 P3-2): setPreedit는 코어 mutate라 메인이 직접 하지
                // 않고 reader로 위임한다 — IME 조합 확정 중 포커스 상실 재진입 데드락(#700)을 구조적으로 없앤다.
                // 빈 bytes=조합 해제(clear_preedit). interactive면 명령 큐로 enqueue+wake, non-interactive(테스트/
                // smoke, reader 없음)면 runtime이 호출 스레드에서 직접 적용 폴백한다(enqueueCoreCommand 내부 분기).
                const cmd: app.CoreCommand = if (bytes.len > 0) .{ .set_preedit = bytes } else .clear_preedit;
                self.runtime.enqueueCoreCommand(self.activeSurface().id, cmd, self.io) catch {};
            },
        }
    }

    /// 활성 입력 대상이 조합 중(preedit 있음)인가 — imeBegin/imeEnd가 조합 판정에 쓴다. 예전엔 core.preedit만 봐서
    /// find/palette 조합을 놓쳤다(단일-출처 위반 → 조합 보호·표시 버그). inputFocus로 통일.
    fn imeComposingActive(self: *const AppSession) bool {
        return switch (self.inputFocus()) {
            .notice => false, // notice는 조합 상태가 없다
            .rename => self.rename_input.preedit.items.len > 0,
            .sidebar_search => self.sidebar_search_input.preedit.items.len > 0,
            .find => self.chrome_host.find.input.preedit.items.len > 0,
            .palette => self.chrome_host.palette.input.preedit.items.len > 0,
            .terminal => self.activeSurfaceConst().core.preedit != null,
        };
    }

    /// IME 키 트랜잭션 시작(Swift keyDown 진입 — 수정자 없는 키). 이번 키에서 입력기가 만들
    /// 텍스트/조합 변화를 모으기 시작한다.
    pub fn imeBegin(self: *AppSession) void {
        if (!self.surface_initialized) return;
        // 조합도 타이핑이다 — 과거를 보는 중이면 바닥으로 스냅해 preedit이 보이게 한다
        // (handleKeyEvent의 "입력하면 live 복귀"와 같은 동작; 조합 키는 그 경로를 안 타므로 여기서).
        // **터미널 입력일 때만** — find/palette에서 조합하면 뒤 터미널 스크롤백을 건드리면 안 된다(조합은
        // 오버레이 입력칸으로 가지 터미널로 안 간다; inputFocus 단일 출처로 판정).
        if (self.inputFocus() == .terminal) {
            // viewOffset 읽기는 메인 락-아래(§9.1), scrollToBottom mutate는 reader로 위임(full (a), §9 P3-4).
            const surface = self.activeSurface();
            const scrolled = blk: {
                surface.lockCore(self.io);
                defer surface.unlockCore(self.io);
                break :blk surface.core.viewOffset() != 0;
            };
            if (scrolled) {
                self.runtime.enqueueCoreCommand(surface.id, .scroll_to_bottom, self.io) catch {};
                self.metal_dirty = true;
            }
        }
        self.ime_active = true;
        self.ime_inserted.clearRetainingCapacity();
        self.ime_marked_changed = false;
        self.ime_did_delete = false;
        self.ime_insert_failed = false;
        self.ime_had_marked = self.imeComposingActive(); // 단일 출처(터미널/find/palette) — core.preedit만 보던 누락 수정
    }

    /// 입력기가 확정한 텍스트(insertText). 즉시 보내지 않고 누적한다 — 전송 여부·시점은
    /// imeEnd가 일괄 판정한다(이중 전송 차단). 트랜잭션 밖(드물게 입력기가 keyDown 없이 직접
    /// 커밋 — 포커스 전환 등)이면 그대로 확정 전송한다.
    pub fn imeInsert(self: *AppSession, bytes: []const u8) void {
        if (!self.surface_initialized) return;
        if (!self.ime_active) {
            // 트랜잭션 밖 직접 커밋(입력기가 keyDown 없이 직접 — 포커스 전환 등 windowLostKey와 같은
            // AppKit 동기 콜백 클래스)도 현재 입력 대상으로 라우팅한다(#10 후속) — 터미널이면 non-blocking
            // PTY, find/palette 입력칸이면 기존 키 경로(routeCommittedText 참조).
            self.routeCommittedText(bytes);
            return;
        }
        self.ime_inserted.appendSlice(self.allocator, bytes) catch {
            self.ime_insert_failed = true; // imeEnd가 잘린 커밋을 보내지 않게
        };
    }

    /// 입력기의 조합 중(marked) 텍스트 갱신(빈 입력 = 조합 해제). 활성 입력 대상(inputFocus 단일 출처)에 보여준다 —
    /// find/palette 열림이면 그 입력에, 아니면 터미널 core. 조합 상태가 그 자리에 즉시 보이고 뒤로 새지 않는다.
    pub fn imeMarked(self: *AppSession, bytes: []const u8) void {
        if (!self.surface_initialized) return;
        self.imeSetPreedit(bytes);
        self.metal_dirty = true; // 조합 글자는 즉시 보여야 한다
        if (self.ime_active) self.ime_marked_changed = true;
    }

    /// 입력기의 deleteBackward 편집 명령(doCommand). 트랜잭션에 기록만 하고 판정은 imeEnd가 한다.
    pub fn imeDeleteBackward(self: *AppSession) void {
        if (self.ime_active) self.ime_did_delete = true;
    }

    // ImeDecision·imeDecide·dropLastCodepoint는 session core로 추출(src/session/ime.zig). 위 file-scope alias
    // (imeDecide=ime.decide)로 imeEnd가 bare 이름 그대로 호출한다. 정의·단위 테스트는 ime.zig.

    /// IME 키 트랜잭션 종료(Swift keyDown이 interpretKeyEvents 직후 호출) — 일괄 판정.
    /// 규칙(위에서부터 첫 일치):
    /// 1. 확정 텍스트가 쌓였으면 그것만 보낸다(키 자체는 입력기가 소비). 단 조합 중 단일
    ///    C0(예: 조합 조작용 Ctrl+H)는 입력기 소유라 버린다(Ghostty와 같은 보호).
    /// 2. 텍스트는 없지만 조합이 변했으면(자모 삭제 등) 키를 보내지 않는다 — 안 막으면 조합
    ///    중 Backspace가 자모도 줄이고 셸 글자까지 지운다(라이브에서 발생).
    /// 3. 둘 다 아니면 일반 키 — 기존 인코딩 경로(Enter/Backspace/기능키).
    /// IME 키 트랜잭션 종료. event가 null이면(정규화 불가 키 — 정의되지 않은 codepoint/keyCode)
    /// 트랜잭션은 그래도 닫고(누적 텍스트 커밋/조합 무시 판정), 일반 키 인코딩만 건너뛴다 —
    /// ime_begin 후 ime_end를 영영 안 닫아 ime_active가 박히고 누적 텍스트가 유실되던 누수를
    /// 막는다(라이브 회귀 클래스).
    pub fn imeEnd(self: *AppSession, event: ?terminal.KeyEvent) void {
        if (!self.surface_initialized) return;
        const composing = self.imeComposingActive() or self.ime_had_marked; // 단일 출처(find/palette도) — core만 보던 누락 수정
        defer {
            self.ime_active = false;
            self.ime_inserted.clearRetainingCapacity();
            self.ime_marked_changed = false;
            self.ime_did_delete = false;
            self.ime_insert_failed = false;
        }
        // OOM으로 누적이 잘렸으면 통째로 버린다 — 반쪽 문자열을 PTY에 보내지 않는다(#14).
        if (self.ime_insert_failed) return;
        switch (imeDecide(composing, self.ime_inserted.items, self.ime_marked_changed, self.ime_did_delete)) {
            .commit_text => |text| {
                // #10 후속: 확정 텍스트를 현재 입력 대상으로 라우팅한다 — imeEnd는 keyDown(interpretKeyEvents
                // 직후) 동기 콜백이라, 터미널 PTY로 blocking enqueue하면 write_queue 포화 시 tick을 멈춰
                // commitComposition과 같은 backpressure 데드락이 된다(#10이 그쪽만 되돌렸다). 터미널이면
                // non-blocking, find/palette 입력칸이면 기존 키 경로(routeCommittedText 참조). 아래 화살표
                // replay는 그대로 키 경로 — 커서 이동이라 인코딩이 필요하고 단발이라 데드락과 무관하다.
                self.routeCommittedText(text);
                // 한글 후보를 화살표로 확정하는 경우(insertText('안') + 화살표): 텍스트만 보내고
                // 화살표를 버리면 커서가 안 움직인다. 확정 후 그 화살표를 다시 보낸다(Ghostty
                // shouldReplayCommittedPreeditKey와 같은 의미론 — 위/오른/아래는 항상, 왼쪽은
                // 수정자 있을 때만; plain 왼쪽은 AppKit이 이미 커서를 제자리에 둬 중복 이동 방지).
                if (event) |ev| if (shouldReplayAfterCommit(ev)) {
                    _ = self.handleKeyEvent(ev) catch {};
                };
            },
            .ignore => {}, // 조합 조작 키(자모 삭제) 또는 조합 중 단일 C0 — 입력기 소유
            .encode_key => if (event) |ev| {
                _ = self.handleKeyEvent(ev) catch {};
            },
        }
    }

    /// 한글 후보를 확정시키며 함께 온 키를 확정 후 다시 보낼지(Ghostty 정책 동작 비교).
    fn shouldReplayAfterCommit(event: terminal.KeyEvent) bool {
        return switch (event.key) {
            .arrow_up, .arrow_right, .arrow_down => true,
            .arrow_left => event.modifiers.shift or event.modifiers.control or
                event.modifiers.option or event.modifiers.command,
            else => false,
        };
    }

    /// IME 후보창 배치용 커서 셀 사각형(backing px, 좌상단 원점 — 마우스 좌표와 같은 규약).
    /// 입력기가 firstRect로 물어보면 Swift가 이 값을 화면 좌표로 바꿔 후보창을 커서 위치에
    /// 띄운다. 조합 중에는 커서가 preedit 시작(core.cursor)에 있어 후보창이 조합 글자 옆에 뜬다.
    /// 반환: row*cell_h, col*cell_w, cell_w, cell_h.
    // self는 *AppSession(비-const) — rename caret 위치(renameCaretRect)가 leaf-rects 레이아웃을 펴는 *AppSession
    // 헬퍼를 거치기 때문(읽기 전용 계산이지만 activeTabLeafRects 체인이 비-const). ABI·테스트 호출자는 모두 mutable.
    pub fn imeCursorRect(self: *AppSession) struct { x: f64, y: f64, w: f64, h: f64 } {
        const cw: f64 = @floatFromInt(if (self.cell_width_px > 0) self.cell_width_px else placeholder_cell_width_px);
        const ch: f64 = @floatFromInt(if (self.cell_height_px > 0) self.cell_height_px else placeholder_cell_height_px);
        if (!self.surface_initialized) return .{ .x = 0, .y = 0, .w = cw, .h = ch };
        // 활성 입력 대상(inputFocus 단일 출처)의 입력 caret 옆에 후보창을 띄운다 — caretRect가 위치 단일 출처.
        // null(패널 밖)이거나 터미널이면 아래 터미널 커서로 폴백.
        const props = self.buildChromeProps();
        const overlay_caret: ?chrome.draw.Rect = switch (self.inputFocus()) {
            .notice => null, // 조합을 안 받으므로 후보창 위치 무의미 — 아래 터미널 커서로 폴백(실제론 안 뜸)
            // rename 인라인 편집기의 caret(사이드바 슬롯/탭/라벨)에 후보창을 띄운다 — renameCaretRect가 대상별 위치를
            // 잡는다(사이드바 y는 slot 기준 근사). null이면 아래 터미널 커서로 폴백.
            .rename => self.renameCaretRect(),
            .sidebar_search => self.sidebarSearchCaretRect(),
            .find => chrome.components.find.caretRect(&self.chrome_host.find, props),
            .palette => chrome.components.palette.caretRect(&self.chrome_host.palette, props),
            .terminal => null,
        };
        if (overlay_caret) |r| {
            return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
        }
        const cursor = self.activeSurfaceConst().core.cursor;
        return .{
            // 활성 panel은 자기 rect origin(active_pane_rect.x/y)에서 그려지므로 커서의 스크린 좌표도 그 origin을
            // 더해야 한다 — 안 더하면 후보창이 실제 커서보다 origin만큼 왼쪽/위에 뜬다(pxToCell의 역변환:
            // pxToCell은 빼고, 셀→스크린인 여기선 더한다). 단일 panel이면 origin = (사이드바 폭+padding_x, padding_y).
            .x = @as(f64, @floatFromInt(self.active_pane_rect.x)) + @as(f64, @floatFromInt(cursor.col)) * cw,
            .y = @as(f64, @floatFromInt(self.active_pane_rect.y)) + @as(f64, @floatFromInt(cursor.row)) * ch,
            .w = cw,
            .h = ch,
        };
    }

    /// 진행 중인 IME 조합(preedit)을 확정(커밋)한다 — 조합 글자를 대상에 보내고 preedit을 비운다. 포커스 상실
    /// (setFocused)과, IME를 우회하는 특수키/단축키(PageUp 등) '직전'에 호출해 Swift marked text와 화면이 어긋나지
    /// 않게 한다. 활성 입력 대상(inputFocus 단일 출처)으로 분기 — 터미널은 PTY로, find/palette는 검색어/명령어로 확정.
    pub fn commitComposition(self: *AppSession) void {
        if (!self.surface_initialized) return;
        switch (self.inputFocus()) {
            .notice => {}, // notice는 확정할 조합이 없다
            .rename => if (self.rename_input.commitPreedit(self.allocator)) {
                self.metal_dirty = true; // 조합 글자가 편집 텍스트로 확정됨(렌더 갱신)
            },
            .sidebar_search => if (self.sidebar_search_input.commitPreedit(self.allocator)) {
                self.rebuildSidebar() catch {}; // 확정 글자로 필터 재적용
                self.metal_dirty = true;
            },
            .terminal => {
                // preedit 읽기 + setPreedit("") 변경은 코어 mutate — 락 아래(docs/io-render-threading.md PR3,
                // 리더 경합 방지). 단 확정 텍스트 전송(sendTextAsKeys)은 락을 푼 뒤에 한다:
                // sendTextAsKeys→handleKeyEvent가 같은 core_mutex를 재취득하므로 락 보유 중 호출하면
                // self-deadlock이다(std.Io.Mutex는 비재진입). 과거 PTY 직접 쓰기(sendCommittedText)는 락
                // 안에서 안전했지만 sendTextAsKeys 공유(#2, bd5fd14)로 그 가정이 깨졌다 — 한글 조합 중
                // 창 포커스 상실 시 메인 스레드가 ulock_wait에 박혀 hang으로 드러난 회귀.
                const s = self.activeSurface();
                const core = &s.core;
                var committed: ?[]u8 = null;
                {
                    s.lockCore(self.io);
                    defer s.unlockCore(self.io);
                    if (core.preedit) |pending| {
                        // setPreedit가 버퍼를 해제하므로 먼저 사본을 뜬다. dupe 실패(OOM)면 비우지 않고
                        // 그대로 둔다(반쪽 커밋 방지 — 기존 동작 보존).
                        committed = self.allocator.dupe(u8, pending) catch return;
                        core.setPreedit("") catch {};
                        self.metal_dirty = true;
                    }
                }
                // 락 밖 + non-blocking 전송(sendCommittedText) — windowLostKey(AppKit 동기 콜백)에서
                // 호출돼도 메인 run loop(tick)를 막지 않아 #10 write_queue backpressure 데드락을 피한다
                // (과거 sendTextAsKeys→handleKeyEvent의 enqueueBlocking이 tick을 멈춰 hang했다).
                if (committed) |copy| {
                    defer self.allocator.free(copy);
                    self.sendCommittedText(copy);
                }
            },
            .find => if (self.chrome_host.find.input.commitPreedit(self.allocator)) {
                self.recomputeFind(); // 검색어가 바뀜
                self.metal_dirty = true;
            },
            .palette => if (self.chrome_host.palette.input.commitPreedit(self.allocator)) {
                self.recomputePalette(); // 필터가 바뀜
                self.metal_dirty = true;
            },
        }
    }

    /// 포커스 변화. 잃으면 조합 중 텍스트를 버리지 않고 확정(커밋)한다 — 버리면 글자가
    /// 사라졌다가 재포커스 후 입력 위치가 어긋나는 사용감(라이브 제보)이 된다.
    /// Terminal.app/Ghostty와 같은 의미론.
    pub fn setFocused(self: *AppSession, focused: bool) void {
        if (!self.surface_initialized) return;
        if (focused) return;
        // 인라인 rename 중 포커스 상실 = 확정(docs/tabs-splits-layout.md "포커스 상실=확정"). 앱-내 클릭은 mouse()
        // down이 이미 commit하지만, 앱-간 전환(window resign)은 이 경로뿐이라 여기서 확정한다. commitRename이 조합
        // preedit도 먼저 query로 확정하므로 commitComposition을 따로 부를 필요 없다(rename은 find/palette와 배타적).
        if (self.rename != null) {
            self.commitRename();
            return;
        }
        self.commitComposition();
    }

    /// **IME 확정 텍스트 전용** — 코드포인트 단위로 기존 key event 경로(handleKeyEvent)에 태운다. 인코딩 단일 출처
    /// (encodeKey)·입력 회계(terminal_input)·IME preedit 정리 등 부작용을 유지한다(IME 트랜잭션이 이것에 의존). 개행은
    /// .enter(\r)로 정규화. bracketed paste 없음. 드래그앤드롭은 paste 경로(pasteText→encodePaste)로 별도다 — TUI([Image]) 인식을 위해 DECSET 2004가 켜졌을 때 bracketed paste로 감싸야 하므로.
    /// **불변식: 호출 시 surface.core_mutex를 보유하면 안 된다** — handleKeyEvent가 인코딩 중 core_mutex를 재취득하는데
    /// std.Io.Mutex는 비재진입이라 같은 스레드가 이미 보유 중이면 자기 데드락(ulock_wait)이다. imeEnd의 .terminal 확정
    /// 경로는 preedit를 락 아래 복사한 뒤 락을 풀고 이 함수를 호출한다(아래 imeEnd 참조). 신규 호출처도 이 규율을 지킬 것.
    pub fn sendTextAsKeys(self: *AppSession, bytes: []const u8) void {
        const view = std.unicode.Utf8View.init(bytes) catch return;
        var it = view.iterator();
        while (it.nextCodepoint()) |cp| {
            // 개행은 .enter로 보낸다(\r로 인코딩) — 멀티라인 insertText가 LF를 그대로 PTY에 넣으면 셸 line discipline이 어긋난다.
            const key: terminal.input.Key = if (cp == '\n' or cp == '\r')
                .enter
            else
                (terminal.input.charKeyFromCodepoint(cp) catch continue);
            _ = self.handleKeyEvent(.{ .key = key, .modifiers = .{} }) catch return;
        }
    }

    /// IME 확정 텍스트를 **non-blocking**으로 PTY에 보낸다 — paste와 같은 pending 큐 패턴
    /// (`pending_paste` FIFO + `flushPendingPaste`의 `writeInputNonBlocking`). `windowLostKey` 등
    /// AppKit 동기 콜백 안에서 호출돼도 blocking enqueue로 메인 run loop(=tick)를 멈추지 않아 #10
    /// write_queue backpressure 데드락을 피한다(설계 전제 "입력 전송은 tick 안"에 코드를 맞춤 —
    /// P2-3b write_queue 구조는 그대로). 확정 텍스트는 완성된 평문이라 키 인코딩(handleKeyEvent)
    /// 없이 바이트로 보내되 개행만 \r로 정규화한다(sendTextAsKeys와 동일 규약; bracketed 감싸기는
    /// paste 전용이라 IME 확정엔 안 쓴다). pending_paste FIFO는 paste와 공유해 전송 순서를 지킨다.
    fn sendCommittedText(self: *AppSession, bytes: []const u8) void {
        if (!self.surface_initialized or bytes.len == 0) return;
        self.pendingPasteRetarget();
        self.pending_paste.ensureUnusedCapacity(self.allocator, bytes.len) catch return;
        for (bytes) |b| self.pending_paste.appendAssumeCapacity(if (b == '\n') '\r' else b);
        // handleKeyEvent를 우회하므로 terminal input 회계를 여기서 직접 한다(\n→\r는 1:1이라 byte 수 동일).
        self.total_terminal_input_events += 1;
        self.total_terminal_input_bytes += bytes.len;
        self.flushPendingPaste();
    }

    /// IME 확정 텍스트를 현재 입력 대상(inputFocus 단일 출처)으로 라우팅한다. 터미널이면 non-blocking PTY
    /// 전송(sendCommittedText — AppKit 동기 콜백에서 write_queue backpressure 데드락 회피, #10 후속). find/
    /// palette 입력칸이면 그 입력은 메모리 조작이라 write_queue를 안 거쳐 데드락과 무관하므로, inputFocus
    /// 분기를 흡수하는 기존 키 경로(sendTextAsKeys→handleKeyEvent)로 보내 검색어/명령어에 글자가 들어가게
    /// 한다(이 분기를 빼면 find 조합 확정이 PTY로 새 입력칸이 빈다 — 회귀 테스트가 고정). 터미널 타이핑은
    /// "검색 종료(find_nav)"도 함께 처리한다(handleKeyEvent 3478과 동일 의미).
    fn routeCommittedText(self: *AppSession, bytes: []const u8) void {
        if (self.inputFocus() == .terminal) {
            if (self.find_nav) self.find_nav = false;
            self.sendCommittedText(bytes);
        } else {
            self.sendTextAsKeys(bytes);
        }
    }

    /// 클립보드 텍스트 붙여넣기(Cmd+V). 인코딩(개행 정규화 + bracketed paste 감싸기)은 core가
    /// 하고, 여기선 한 번의 writeInput으로 보낸다(부분 쓰기 실패로 감싸기가 깨지지 않게).
    pub fn pasteText(self: *AppSession, bytes: []const u8) void {
        if (!self.surface_initialized or bytes.len == 0) return;
        const encoded = self.activeSurface().core.encodePaste(self.allocator, bytes) catch return;
        defer self.allocator.free(encoded);
        // 큐에 쌓고 즉시 flush를 시도한다. 자식이 읽는 중이면 보통 이 자리에서 다 들어가고,
        // 안 읽으면(vim 다이얼로그 등) 잔여가 tick마다 흘러나간다 — blocking 단일 write로 UI가
        // 동결되던 것을 없앤다. 큐는 FIFO라 bracketed paste 감싸기 순서는 깨지지 않는다.
        self.pendingPasteRetarget();
        self.pending_paste.appendSlice(self.allocator, encoded) catch return;
        self.flushPendingPaste();
    }

    /// pending_paste가 다 빠진 뒤 새로 쌓기 시작할 때만 대상 surface를 현재 활성으로 다시 고정한다.
    /// 잔여가 남아 있으면 대상을 바꾸지 않아, 이미 어떤 surface로 가던 paste/IME 확정 바이트가 탭/pane
    /// 전환으로 다른 surface에 섞여 들어가지 않는다(원래 대상 우선; flushPendingPaste가 이 대상으로 쓴다).
    fn pendingPasteRetarget(self: *AppSession) void {
        if (self.pending_paste_offset >= self.pending_paste.items.len) {
            self.pending_paste.clearRetainingCapacity();
            self.pending_paste_offset = 0;
            self.pending_paste_target = self.activeSurface().id;
        }
    }

    /// pending paste를 지금 쓸 수 있는 만큼 non-blocking으로 흘려보낸다(0이 나오면 다음 tick).
    fn flushPendingPaste(self: *AppSession) void {
        while (self.pending_paste_offset < self.pending_paste.items.len) {
            const remaining = self.pending_paste.items[self.pending_paste_offset..];
            const written = self.runtime.writeInputNonBlocking(self.pending_paste_target, remaining) catch {
                // 세션 종료 등 — 잔여는 버린다(다시 쓸 수 없는 대상).
                self.pending_paste.clearRetainingCapacity();
                self.pending_paste_offset = 0;
                return;
            };
            if (written == 0) return; // PTY 버퍼가 찼다 — 다음 tick에 이어서
            self.pending_paste_offset += written;
        }
        self.pending_paste.clearRetainingCapacity();
        self.pending_paste_offset = 0;
    }

    /// Cmd+hover 갱신. cmd_held가 아니거나 URL이 아니면 hover를 해제한다. URL 위면 밑줄 범위를
    /// 저장하고 true를 돌려준다 — Swift가 이 값으로 마우스 커서(pointingHand)를 정한다.
    /// 마우스 호버 위치의 커서 종류를 판정하고(Swift가 NSCursor로 세움), 부수적으로 사이드바 슬롯·pane 탭 호버·
    /// Cmd+hover URL 밑줄을 갱신한다. 영역 우선순위는 마우스 클릭(mouse down)과 같다: 사이드바 → 탭 바 → divider
    /// → 터미널. 사이드바·탭 바=arrow(default), divider=resize(좌우 split=↔, 상하 split=↕), 터미널=iBeam(text),
    /// Cmd+hover URL=pointingHand(link). 창 밖 sentinel(-1,-1)이면 inSidebar=false→터미널 경로로 호버 해제.
    pub fn hoverCursor(self: *AppSession, x_px: f64, y_px: f64, cmd_held: bool) CursorKind {
        if (!self.surface_initialized) return .text;
        // 스크롤바 hover 강조를 매 이동 갱신한다(어느 zone이든 — 아래 early return 전에 항상). scrollbarGrabAt이
        // 영역+스크롤백 유무를 본다(우측 얇은 띠). 커서 종류는 안 바꾼다(얇은 띠라 iBeam 깜빡임 방지) — 강조만.
        self.setScrollbarHovered(self.scrollbarGrabAt(x_px, y_px) != null);
        // 사이드바 우측 경계(폭 조절) 위면 리사이즈 커서 — 사이드바/터미널보다 먼저(경계는 둘 사이 밴드).
        if (chrome.components.sidebar.onResizeEdge(x_px, self.sidebar_width_px, if (self.cell_width_px > 0) self.cell_width_px else placeholder_cell_width_px)) {
            self.setHoveredSlot(null);
            self.setHoveredTab(null);
            self.clearHoverUrlAnchor();
            return .resize_h; // 좌우로 끄는 세로 경계 ↔
        }
        // 사이드바 영역 호버는 슬롯(또는 상단 헤더)을 추적한다(터미널 URL 호버 아님).
        if (self.inSidebar(x_px)) {
            // 상단 헤더(검색바·아이콘) 영역이면 슬롯 호버 해제 + 아이콘은 pointingHand·검색 영역은 I-beam.
            const region = chrome.components.sidebar.headerHit(x_px, y_px, self.sidebar_width_px, self.cell_width_px, self.sidebar_header_height_px);
            if (region != .none) {
                self.setHoveredSlot(null);
                self.setHoveredTab(null);
                self.clearHoverUrlAnchor();
                return if (region == .search) .text else .link;
            }
            self.setHoveredSlot(self.sidebarSlotAt(y_px));
            self.setHoveredTab(null); // 사이드바로 가면 pane 탭 호버 해제(stale ✕ 방지)
            self.clearHoverUrlAnchor();
            return if (self.hovered_slot != null) .link else .default; // 워크스페이스 슬롯은 클릭(전환) → pointingHand, 빈 영역은 arrow
        }
        self.setHoveredSlot(null); // 터미널 영역으로 나가면 사이드바 호버 해제
        // 어느 pane의 탭 바 위면 호버 탭을 갱신(✕ 표시). 바 위면 URL/divider 아니므로 밑줄 해제하고 arrow.
        if (self.updateHoveredTab(x_px, y_px)) {
            self.clearHoverUrlAnchor();
            return .link; // #5c: 탭 바 위(탭·‹/›·+·pane 포커스 — 클릭 가능) → pointingHand
        }
        // divider 밴드 위면 리사이즈 커서(클릭과 같은 dividerAtPoint — 탭 바 다음 순서). 단일 panel이면 null.
        if (self.dividerAtPoint(x_px, y_px)) |hit| {
            self.clearHoverUrlAnchor();
            return switch (hit.seg.orientation) {
                .vertical_line => .resize_h, // 세로 divider — 좌우로 끈다
                .horizontal_line => .resize_v, // 가로 divider — 위아래로 끈다
            };
        }
        // 터미널 영역: Cmd+hover URL이면 link(pointingHand), 아니면 text(iBeam).
        var next: ?terminal.SelectionPoint = null;
        if (cmd_held) {
            if (self.pxToCell(x_px, y_px)) |cell| {
                const core = &self.activeSurface().core;
                // URL이면 그 시작 셀의 절대 좌표를 저장한다(뷰포트 좌표가 아님) — 스크롤/출력으로
                // 내용이 움직여도 밑줄이 내용을 따라가고, 좁아진 폭에서도 매 frame 뷰포트로 다시
                // 클립(아래 hoverLinkSpan)되므로 stale·OOB가 안 생긴다.
                if (core.urlAnchorAt(cell.row, cell.col)) |anchor| next = anchor;
            }
        }
        const changed = !pointEql(self.hover_url_anchor, next);
        self.hover_url_anchor = next;
        if (changed) self.metal_dirty = true; // 밑줄이 생기거나 사라지면 다시 그린다
        return if (next != null) .link else .text;
    }

    /// 떠 있던 Cmd+hover URL 밑줄 anchor를 해제하고 변경 시 redraw 표시. hoverCursor의 여러 분기(사이드바/탭
    /// 바/divider)가 터미널 URL이 아닌 영역으로 갈 때 공유한다.
    fn clearHoverUrlAnchor(self: *AppSession) void {
        if (self.hover_url_anchor != null) {
            self.hover_url_anchor = null;
            self.metal_dirty = true;
        }
    }

    /// hover URL의 현재 뷰포트 밑줄 범위. 매 frame 절대 좌표 anchor에서 다시 계산해 클립하므로
    /// 스크롤·출력·resize 후에도 항상 현재 폭/위치에 맞는다(stale 좌표 OOB 차단).
    pub fn hoverLinkSpan(self: *AppSession) ?terminal.SelectionSpan {
        const anchor = self.hover_url_anchor orelse return null;
        return self.activeSurface().core.urlSpanAtAbs(anchor);
    }

    fn pointEql(a: ?terminal.SelectionPoint, b: ?terminal.SelectionPoint) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.meta.eql(a.?, b.?);
    }

    /// Cmd+클릭 위치의 URL(없으면 빈 슬라이스). Swift가 NSWorkspace로 연다 — URL 인식(단어 경계,
    /// soft-wrap 이어 붙임, http(s) 검사, 끝 문장부호 다듬기)은 core가 소유한다.
    pub fn urlAt(self: *AppSession, x_px: f64, y_px: f64) []const u8 {
        if (!self.surface_initialized) return &.{};
        // 스크린→셀 변환은 pxToCell 단일 출처를 쓴다(사이드바 offset 차감 포함) — 별도 변환을 두면
        // 사이드바 폭만큼 어긋난 셀에서 URL을 찾는다(직접 x/cw로 계산하던 버그를 여기로 일원화해 고침).
        const cell = self.pxToCell(x_px, y_px) orelse return &.{};
        const core = &self.activeSurface().core;
        if (self.url_buffer.len > 0) {
            self.allocator.free(self.url_buffer);
            self.url_buffer = &.{};
        }
        const url = core.extractUrlAt(self.allocator, cell.row, cell.col) catch null orelse return &.{};
        self.url_buffer = url;
        return self.url_buffer;
    }

    /// 선택 텍스트를 추출해 내부 버퍼로 돌려준다(없으면 빈 슬라이스). Swift가 NSPasteboard에 쓴다.
    pub fn copyText(self: *AppSession) []const u8 {
        if (!self.surface_initialized) return &.{};
        if (self.copy_buffer.len > 0) {
            self.allocator.free(self.copy_buffer);
            self.copy_buffer = &.{};
        }
        // extractSelection은 선택 + 스크롤백을 읽는다 — 락 아래(docs/io-render-threading.md §9.1). full (a)에서 선택이
        // 이제 reader 스레드가 async로 mutate하므로, 락 없이 읽으면 드래그-선택 직후 Cmd+C가 torn/stale 선택을 본다
        // (렌더 경로는 이미 락 아래 selectionViewportSpan을 읽는다 — copyText만 노출됐던 갭). 추출 바이트는 owned이라 unlock 후 안전.
        const s = self.activeSurface();
        s.lockCore(self.io);
        const extracted = s.core.extractSelection(self.allocator) catch null;
        s.unlockCore(self.io);
        self.copy_buffer = extracted orelse return &.{};
        return self.copy_buffer;
    }

    /// OSC 52 클립보드 쓰기 요청을 내부 버퍼로 돌려준다(없으면 빈 슬라이스). Swift가 NSPasteboard에 쓴다.
    /// **정책**(terminal-compatibility-policy.md §OSC52, 사용자 결정 2026-06-20): write는 기본 `allow` — 로컬
    /// 단일 사용자 데스크톱 터미널이라 트래킹 앱의 드래그 복사를 시스템 클립보드에 반영한다(iTerm2/Ghostty도 유사).
    /// **read**는 클립보드 탈취 방지로 계속 deny한다 — core가 `?` 쿼리에 응답하지 않아 read 요청은 여기 안 온다.
    /// 코어 pending을 비워(한 번 쓰고 소비) 같은 데이터가 다음 tick에 또 쓰이지 않게 한다. ask(요청별 확인 UI)는 후속.
    pub fn pendingClipboard(self: *AppSession) []const u8 {
        if (!self.surface_initialized) return &.{};
        const pending = self.activeSurface().core.pendingClipboardWrite();
        if (pending.len == 0) return &.{};
        if (self.clipboard_out_buffer.len > 0) {
            self.allocator.free(self.clipboard_out_buffer);
            self.clipboard_out_buffer = &.{};
        }
        self.clipboard_out_buffer = self.allocator.dupe(u8, pending) catch return &.{};
        self.activeSurface().core.clearClipboardWrite();
        return self.clipboard_out_buffer;
    }

    /// OSC 9/777 데스크톱 알림 pending(title, body)을 내부 버퍼로 돌려준다(없으면 null). Swift가
    /// UNUserNotificationCenter로 띄운다. 코어 pending을 비워(한 번 쓰고 소비) 다음 tick에 같은 알림이 또
    /// 뜨지 않게 한다. 알림은 OS 리소스라 native(Swift)만 띄우고 코어/여기는 데이터만 넘긴다(경계). 클립보드와
    /// 달리 env 게이트 없음 — 알림은 OS authorization이 게이트하는 저위험 표면(iTerm2/Ghostty도 기본 허용).
    pub fn pendingNotification(self: *AppSession) ?struct { title: []const u8, body: []const u8 } {
        // 에이전트 완료 알림(running→idle)을 OSC 9/777보다 먼저 드레인한다 — 큐의 owned 버퍼를 그대로 반환하고
        // 직전 반환 버퍼는 여기서 해제(다음 pendingNotification/destroy까지 유효 규약은 동일).
        if (self.agent_notifications.items.len > 0) {
            const n = self.agent_notifications.orderedRemove(0);
            if (self.notification_title_out.len > 0) self.allocator.free(self.notification_title_out);
            if (self.notification_body_out.len > 0) self.allocator.free(self.notification_body_out);
            self.notification_title_out = n.title;
            self.notification_body_out = n.body;
            return .{ .title = self.notification_title_out, .body = self.notification_body_out };
        }
        if (!self.surface_initialized) return null;
        const pending = self.activeSurface().core.pendingNotification() orelse return null;
        if (self.notification_title_out.len > 0) {
            self.allocator.free(self.notification_title_out);
            self.notification_title_out = &.{};
        }
        if (self.notification_body_out.len > 0) {
            self.allocator.free(self.notification_body_out);
            self.notification_body_out = &.{};
        }
        // title은 빈 문자열일 수 있다(OSC 9). dupe가 실패하면 그 알림은 버린다(best-effort, 코어 pending은 비운다).
        self.notification_title_out = self.allocator.dupe(u8, pending.title) catch {
            self.activeSurface().core.clearNotification();
            return null;
        };
        self.notification_body_out = self.allocator.dupe(u8, pending.body) catch {
            self.allocator.free(self.notification_title_out);
            self.notification_title_out = &.{};
            self.activeSurface().core.clearNotification();
            return null;
        };
        self.activeSurface().core.clearNotification();
        return .{ .title = self.notification_title_out, .body = self.notification_body_out };
    }

    /// G12 BEL: 활성 surface에 pending 벨이 있으면 true(코어 플래그를 비운다). Swift가 시스템 벨(NSSound.beep)을
    /// 울린다 — 코어는 OS 소리를 직접 내지 않는다(OSC 52/9·777과 같은 경계). 한 tick 1회로 합쳐져 벨 폭주 방지.
    pub fn takeBell(self: *AppSession) bool {
        if (!self.surface_initialized) return false;
        // 코어 플래그는 항상 drain(음소거 중에도 누적 방지)하고, 시스템 소리는 audible_bell일 때만 요청한다.
        return self.activeSurface().core.takeBell() and self.audible_bell;
    }

    /// OSC 7로 셸이 보고한 현재 cwd(percent-decode된 경로). 한 번도 안 받았으면 빈 슬라이스.
    /// 반환은 core 소유로 다음 OSC 7/RIS/destroy까지 유효하다(별도 복사 없음 — native 최소).
    /// Swift가 창 제목에 쓴다.
    pub fn currentCwd(self: *AppSession) []const u8 {
        if (!self.surface_initialized) return &.{};
        return self.activeSurface().core.currentCwd();
    }

    /// term의 git 브랜치(owned 캐시). 그 surface의 cwd(OSC 7)가 바뀌었을 때만 .git/HEAD를 walk-up해 재계산한다
    /// (사이드바는 매 프레임 빌드되므로 fs 읽기를 cwd 변경으로 게이트). 없으면 null. 반환은 term 소유(다음 cwd 변경/
    /// teardown까지 유효). 파생값이라 영속 안 함 — restore가 cwd에서 재도출.
    fn termGitBranch(self: *AppSession, term: *Term) ?[]const u8 {
        const cwd = term.surface.core.currentCwd();
        if (cwd.len == 0) return null;
        if (term.git_branch_cwd) |c| {
            if (std.mem.eql(u8, c, cwd)) return term.git_branch; // 캐시 적중(cwd 불변)
        }
        // cwd 변경 → 재계산(옛 캐시 해제 후 갱신).
        if (term.git_branch) |b| self.allocator.free(b);
        if (term.git_branch_cwd) |c| self.allocator.free(c);
        term.git_branch = readGitBranch(self.io, self.allocator, cwd);
        term.git_branch_cwd = self.allocator.dupe(u8, cwd) catch null;
        if (diag_gate.maruDebugEnabled()) std.log.scoped(.git).info("branch: cwd={s} -> {?s}", .{ cwd, term.git_branch });
        return term.git_branch;
    }

    /// config 파일 경로(Open Config 메뉴용). loader.defaultConfigPath(MARU_CONFIG override·$HOME/.config/maru/
    /// config)가 단일 출처 — 한 번 계산해 세션 소유 버퍼에 캐시한다(다음 호출은 캐시, destroy까지 유효).
    /// HOME 없음·OOM이면 빈 슬라이스(Swift가 무동작). 경로 계산만 — 파일 생성/열기는 platform(Swift) OS 동작.
    pub fn configPath(self: *AppSession) []const u8 {
        if (self.config_path_buffer) |b| return b;
        const path = (config_mod.defaultConfigPath(self.allocator) catch null) orelse return &.{};
        self.config_path_buffer = path; // owned 슬라이스 — 세션이 소유(deinit이 해제)
        return path;
    }

    /// 창 제목으로 보여줄 문자열(OSC 0/2 제목 우선, 없으면 cwd basename, 둘 다 없으면 빈 슬라이스).
    /// 우선순위 로직은 core가 소유한다(native 최소) — Swift는 받아서 빈값이면 앱 이름으로 폴백만.
    /// 반환은 core 소유로 다음 OSC 0/2/7·RIS·destroy까지 유효하다(별도 복사 없음).
    pub fn windowTitle(self: *AppSession) []const u8 {
        if (!self.surface_initialized) return &.{};
        return self.activeSurface().core.windowTitle();
    }

    /// 전역(OS) 단축키 등록 기술자 목록(가상 키코드 + Carbon modifier + action). config에서 한 번 만들어
    /// 세션 동안 불변이라 Swift가 시작 시 한 번 읽어 RegisterEventHotKey로 등록한다. 매핑 가능한 chord만.
    pub fn globalHotkeys(self: *const AppSession) []const GlobalHotkey {
        return self.global_hotkeys.items;
    }

    /// 커맨드 카탈로그를 빌드한다(init 1회). 각 정적 엔트리에 대해 현재 바인딩 chord를 역스캔해 표시 문자열을
    /// 만들고(안 묶였으면 빈 문자열), 그걸 owned로 보관한 뒤 CommandEntry(action_key/title=정적 리터럴 포인터,
    /// key_display=owned 포인터)를 append한다. OOM이면 에러를 올려 init이 정리하게 한다(errdefer deinit).
    fn buildCommandCatalog(self: *AppSession) !void {
        const resolver = self.loaded_config.keyBindingResolver();
        for (command_catalog.entries) |entry| {
            const chord = command_catalog.chordForAction(resolver, entry.action);
            // 표시용 chord("⌘T")와 NSMenuItem keyEquivalent("t"+mask)를 둘 다 만든다(안 묶였으면 빈 문자열·mask 0).
            var disp_scratch: [command_catalog.max_chord_display_len]u8 = undefined;
            const display: []const u8 = if (chord) |c| command_catalog.formatChord(c, &disp_scratch) else "";
            var equiv_scratch: [8]u8 = undefined;
            const equiv: []const u8 = if (chord) |c| command_catalog.keyEquivalent(c, &equiv_scratch) else "";
            const modifiers: u32 = if (chord) |c| command_catalog.modifierMask(c) else 0;

            const owned_display = try self.allocator.dupeZ(u8, display);
            errdefer self.allocator.free(owned_display);
            try self.command_key_displays.append(self.allocator, owned_display);
            const owned_equiv = try self.allocator.dupeZ(u8, equiv);
            errdefer self.allocator.free(owned_equiv);
            try self.command_key_equivalents.append(self.allocator, owned_equiv);
            try self.command_entries.append(self.allocator, .{
                .action_key = entry.key.ptr,
                .title = entry.title.ptr,
                .key_display = owned_display.ptr,
                .key_equivalent = owned_equiv.ptr,
                .key_modifiers = modifiers,
            });
        }
    }

    /// 커맨드 카탈로그(메뉴바·팝업이 그릴 액션 목록). 세션 동안 불변. owned — destroy까지 유효.
    pub fn commandCatalog(self: *const AppSession) []const CommandEntry {
        return self.command_entries.items;
    }

    /// action_key(= parseAction 문자열) 한 개를 실행한다 — 메뉴/팝업 선택의 디스패치 경로. 파싱되면
    /// dispatchAppAction으로 넘기고 true, 모르는 키면 무동작 true 반환 없이 false(Swift가 무시). 터미널
    /// Action만 받는다(global/UI 동작은 Swift 소유라 별도).
    pub fn runAction(self: *AppSession, action_key: []const u8) bool {
        // 모달(chrome Notice·커맨드 팝업·스크롤백 Find)이 열린 동안엔 메뉴바 keyEquivalent(Swift가 OS에서 잡아 이
        // 경로로 보낸다)를 무시한다 — 모달 중 단축키가 뒤의 터미널을 조작하면 안 된다. 모달 자신의 키(팝업 Enter,
        // Find 네비게이션)는 chrome_host.handleInput → dispatchChromeAction이 처리하므로 이 경로를 안 거친다.
        if (self.chrome_host.notice.open or self.chrome_host.palette.open or self.chrome_host.find.open) return false;
        const action = config_mod.parseAction(action_key) orelse return false;
        self.dispatchAppAction(action);
        return true;
    }

    /// 이 창(AppSession)의 라이브 상태를 workspace restore 모델(app.workspace.Window)로 캡처한다(R3). 탭→pane
    /// split 트리→Term→surface를 걸어 선언적 상태만 모은다 — live PTY/process/grid는 안 담는다. cwd/title은 OSC
    /// 권위 소스(core.currentCwd/windowTitle), command는 spawn argv[0](surface.command). split 트리는 *Pane leaf를
    /// pane 인덱스로 환원해 preorder TreeNode로 평탄화(직렬화 모델과 같은 형태). 멀티 창 전체 모델은 호출자(R5)가
    /// 각 세션의 Window를 모아 만든다. 모든 슬라이스·문자열은 `arena`가 소유한다(호출자가 deinit).
    pub fn captureWorkspaceWindow(self: *AppSession, arena: std.mem.Allocator) !app.workspace.Window {
        var tabs: std.ArrayList(app.workspace.Tab) = .empty;
        for (self.tabs.items) |tab| try tabs.append(arena, try captureWorkspaceTab(arena, tab));
        return .{ .active_tab = self.app_window.active_tab, .tabs = try tabs.toOwnedSlice(arena) };
    }

    fn captureWorkspaceTab(arena: std.mem.Allocator, tab: *Tab) !app.workspace.Tab {
        var panes: std.ArrayList(app.workspace.Pane) = .empty;
        for (tab.panes.items) |pane| {
            var surfaces: std.ArrayList(app.workspace.Surface) = .empty;
            for (pane.terms.items) |term| {
                const core = &term.surface.core;
                try surfaces.append(arena, .{
                    // custom_name = 사용자 rename(owned, 없으면 ""), title = 자동 제목(OSC). 둘은 별도 필드로 저장한다.
                    .custom_name = try arena.dupe(u8, term.surface.custom_name orelse ""),
                    .title = try arena.dupe(u8, core.windowTitle()),
                    .cwd = try arena.dupe(u8, core.currentCwd()),
                    .command = try arena.dupe(u8, term.surface.command orelse ""),
                    .cols = core.size.cols,
                    .rows = core.size.rows,
                });
            }
            try panes.append(arena, .{
                .active_term = pane.active_term,
                .custom_name = try arena.dupe(u8, pane.custom_name orelse ""), // pane 사용자 rename(없으면 "")
                .surfaces = try surfaces.toOwnedSlice(arena),
            });
        }
        var tree: std.ArrayList(app.workspace.TreeNode) = .empty;
        try flattenPaneTree(arena, tab, tab.tree, &tree);
        return .{
            .active_pane = tab.active_pane,
            // 워크스페이스(탭)의 사용자 rename(없으면 ""). 예전엔 데이터 출처가 없어 reserved placeholder였으나, 이제
            // tab.custom_name이 출처다(docs/workspace-restore.md "사용자 지정 이름과 자동 제목").
            .custom_name = try arena.dupe(u8, tab.custom_name orelse ""),
            .pinned = tab.pinned,
            .background_color = tab.background_color,
            .tree = try tree.toOwnedSlice(arena),
            .panes = try panes.toOwnedSlice(arena),
        };
    }

    /// PaneTree 노드를 preorder로 평탄화한다 — leaf(*Pane)는 그 Pane의 tab.panes 인덱스로, split은 방향+ratio(천분율)
    /// 로. 직렬화 모델(self-delimiting preorder)과 같은 순서·형태.
    fn flattenPaneTree(arena: std.mem.Allocator, tab: *Tab, node: PaneTree.Node, out: *std.ArrayList(app.workspace.TreeNode)) !void {
        switch (node) {
            .leaf => |pane_ptr| {
                const idx = paneIndexOf(tab, pane_ptr) orelse return error.PaneNotFound;
                try out.append(arena, .{ .leaf = idx });
            },
            .split => |s| {
                const milli: u16 = @intFromFloat(@round(std.math.clamp(s.ratio, 0.0, 1.0) * 1000.0));
                try out.append(arena, .{ .split = .{ .direction = s.direction, .ratio_milli = milli } });
                try flattenPaneTree(arena, tab, s.a, out);
                try flattenPaneTree(arena, tab, s.b, out);
            },
        }
    }

    fn paneIndexOf(tab: *Tab, pane: *Pane) ?usize {
        for (tab.panes.items, 0..) |p, i| {
            if (p == pane) return i;
        }
        return null;
    }

    /// 이 창의 workspace 블록(헤더 없는 `window …` 텍스트)을 직렬화해 세션-소유 버퍼로 돌려준다(R5 저장 ABI).
    /// 캡처는 임시 arena로 하고, 결과 텍스트만 self.allocator로 보관한다(다음 호출/deinit까지 유효 — cwd ABI와
    /// 같은 소유 규칙). Swift가 멀티 창 저장에서 세션마다 호출해 `maru.workspace.v1` 헤더 아래로 모은다.
    pub fn serializeWorkspaceWindow(self: *AppSession) ![]const u8 {
        if (self.workspace_buffer) |b| {
            self.allocator.free(b);
            self.workspace_buffer = null;
        }
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const win = try self.captureWorkspaceWindow(arena.allocator());
        const text = try app.workspace.serializeWindow(self.allocator, win);
        self.workspace_buffer = text;
        return text;
    }

    /// 현재 sidebar 토글(show_branch/show_folder)을 config 파일에 반영할 새 텍스트를 직렬화한다(owned, 다음
    /// 호출/deinit까지 유효 — workspace_buffer 패턴). 원본 config를 읽어 updateConfigText로 부분 갱신하므로
    /// 주석·미파싱 키를 보존한다. Swift가 받아 config 경로에 atomic write한다(앱→config 방향). 원본이 없거나
    /// 읽기 실패면 빈 텍스트로 두 키를 append한다(forgiving — config가 없어도 토글이 새 파일을 만든다).
    pub fn serializeSidebarConfig(self: *AppSession) ![]const u8 {
        if (self.sidebar_config_buffer) |b| {
            self.allocator.free(b);
            self.sidebar_config_buffer = null;
        }
        const path = self.configPath();
        const owned: ?[]u8 = if (path.len == 0)
            null
        else
            std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1 << 20)) catch null;
        defer if (owned) |o| self.allocator.free(o);
        const original: []const u8 = owned orelse &.{};

        const updates = [_]config_mod.ConfigKeyValue{
            .{ .key = "sidebar.show-branch", .value = if (self.loaded_config.config.sidebar.show_branch) "true" else "false" },
            .{ .key = "sidebar.show-folder", .value = if (self.loaded_config.config.sidebar.show_folder) "true" else "false" },
        };
        const text = try config_mod.updateConfigText(self.allocator, original, &updates);
        self.sidebar_config_buffer = text;
        return text;
    }

    /// 저장된 workspace 모델(한 창)을 이 세션에 적용해 탭/pane split 트리/Term을 재생성한다(R4 복원). init이 만든
    /// 기본 탭을 모델대로 교체한다 — 각 Term은 저장된 cwd에서 새 셸을 spawn한다(셸 상태가 아니라 cwd·레이아웃 복원).
    /// title/command는 정적 기본(셸이 OSC 0/2로 곧 재설정)·size는 모델값(이후 resize가 창에 맞게 보정). 새 탭들을
    /// 먼저 다 빌드한 뒤 기존 탭을 teardown하고 swap한다 — 빌드 실패면 새 것만 정리하고 기존 세션을 보존한다.
    /// 빈 모델이면 무동작(기본 유지). 빈 cwd면 기본 cwd로 spawn(저장 안 됐거나 셸 통합 없음).
    pub fn applyWorkspaceWindow(self: *AppSession, win: app.workspace.Window) !void {
        if (win.tabs.len == 0) return;

        // 1) 새 탭들을 먼저 다 빌드한다(아직 self.tabs에 안 넣음 — 실패하면 기존 세션 그대로 유지).
        var new_tabs: std.ArrayList(*Tab) = .empty;
        defer new_tabs.deinit(self.allocator);
        errdefer for (new_tabs.items) |t| self.destroyTabStandalone(t);
        try new_tabs.ensureTotalCapacity(self.allocator, win.tabs.len);
        for (win.tabs) |tab_model| {
            new_tabs.appendAssumeCapacity(try self.buildWorkspaceTab(tab_model));
        }

        // 2) swap이 실패하지 않게 컬렉션 capacity를 미리 잡는다(teardown 뒤 append가 무실패여야 half-state가 없다).
        try self.tabs.ensureTotalCapacity(self.allocator, new_tabs.items.len);
        try self.surface_ptrs.ensureTotalCapacity(self.allocator, new_tabs.items.len);

        // 3) 기존 탭 teardown(closeTab의 teardown과 같은 순서 — 마지막-탭 latch는 안 탄다) 후 새 탭 설치.
        for (self.tabs.items) |tab| self.destroyTabStandalone(tab);
        self.tabs.clearRetainingCapacity();
        self.surface_ptrs.clearRetainingCapacity();
        for (new_tabs.items) |tab| {
            self.tabs.appendAssumeCapacity(tab);
            self.surface_ptrs.appendAssumeCapacity(&tab.activePane().activeTerm().surface);
        }
        self.app_window.tabs = self.surface_ptrs.items;
        self.app_window.active_tab = @min(win.active_tab, self.tabs.items.len - 1);
        // 고정-prefix 불변식 강제(복원): clampMoveToGroup/countPinnedTabs는 "고정 탭이 앞쪽 [0, pinned_count)에
        // 연속"을 가정한다. 저장 순서를 그대로 복원하면(재정렬 안 함) #685 이전 빌드가 만든 [P,u,P,u]처럼 섞인
        // workspace가 들어와 드래그/토글 clamp가 엉뚱한 슬롯에 떨어진다. 여기서 stable-partition으로 고정을 전부
        // 앞으로 모은다(고정끼리·비고정끼리 상대 순서 유지). 불변식을 모든 진입 경로(토글·드래그·복원)에서 성립시킨다.
        self.stablePartitionPinned();
        // 트리·탭을 통째로 교체했으니 해제된 옛 트리를 가리키던 상호작용 포인터를 비워야 하는데, 위 destroyTabStandalone
        // 루프의 destroyPane이 invalidateForFreedPane(S1 chokepoint)으로 옛 Pane을 가리키던 호버·드래그 포인터를 이미
        // 비웠다(표적 무효화라 옛 Pane을 가리키던 tab_drag_pane도 포함). 지금은 시작 전용이라 드래그가 없지만,
        // mid-session 재적용(repo별 workspace 후속)에서도 같은 chokepoint가 UAF를 막는다 — 따로 리셋하지 않는다.
        // 복원된 모든 탭을 현재 창 grid로 맞춘다. apply는 resize를 안 부르고 각 surface는 저장 grid로 spawn되며,
        // caller의 resizeAppSessionFromWindow→resize()는 (활성 탭만 + last_resize_size dedup) 배경 탭과 primary
        // 활성 탭을 빠뜨린다. 여기서 전 탭을 명시적으로 맞춰 dedup·활성탭-한정을 둘 다 우회한다(best-effort).
        for (self.tabs.items) |tab| self.resizeTabPanes(tab);
        // 활성 탭의 대표 surface는 위 swap 루프가 이미 surface_ptrs[*]에 바인딩했고 active_pane도 빌드 때
        // 세팅됐다(focusPane(active==active)는 early-return no-op이라 호출하지 않는다). 좌표·사이드바만 갱신.
        self.recomputeActivePaneRect();
        self.rebuildSidebar() catch {};
        self.metal_dirty = true;
        if (builtin.mode == .Debug) assertPinnedPrefixRuntime(self); // 복원 후 불변식 확인(디버그)
    }

    /// 컬렉션에 안 든 Tab을 teardown·해제한다(closeTab의 teardown 부분 — 단, tabs/surface_ptrs는 호출자가 관리).
    /// 트리(tab.tree)가 세팅된 '완성된' 탭에만 쓴다(buildWorkspaceTab은 자기 granular errdefer로 미완성을 정리).
    fn destroyTabStandalone(self: *AppSession, tab: *Tab) void {
        // rename 대상이 이 워크스페이스(또는 그 안 pane/Term)면 비운다 — pane/Term은 아래 destroyPane/destroyTerm
        // 가드가 처리하지만, 워크스페이스 자체 rename은 여기서. teardown 중이라 직접 null(부수효과 없이).
        if (self.renamingWorkspace(tab)) {
            self.rename = null;
            self.rename_input.clear();
        }
        // 컨텍스트 메뉴 대상이 이 워크스페이스면 메뉴를 닫고 대상을 비운다(stale 포인터 방지). pane/Term은 아래
        // destroyPane/destroyTerm가 처리.
        if (self.context_menu_target) |t| if (std.meta.activeTag(t) == .workspace and t.workspace == tab) {
            self.context_menu_target = null;
            self.chrome_host.context_menu.hide();
        };
        for (tab.panes.items) |pane| self.destroyPane(pane);
        // 트리를 통째 해제하기 전에, divider_drag가 이 트리 소속 split이면 표적 null(다른 탭 트리를 가리키면 유지 —
        // 무관한 탭 close가 진행 중 divider 드래그를 안 끊는다). collapse 경로의 invalidateForFreedSplit과 같은 규율.
        if (self.divider_drag) |dd| {
            if (PaneTree.containsSplit(tab.tree, dd)) self.divider_drag = null;
        }
        if (tab.custom_name) |n| self.allocator.free(n); // 워크스페이스 사용자 rename(owned) 해제
        PaneTree.deinit(self.allocator, tab.tree); // heap split 노드 해제(leaf surface는 destroyPane가 이미)
        tab.panes.deinit(self.allocator);
        self.allocator.destroy(tab);
    }

    /// 모델 Tab → 완성된 *Tab(panes + split 트리). pane들을 먼저 만들고(각 첫 surface로 spawn + 나머지 Term 추가),
    /// 트리를 모델 preorder대로 직접 짓는다(leaf 인덱스 → 그 pane, split → 새 PaneTree.Split). 부분 실패는 granular
    /// errdefer로 정리(트리는 아직 미세팅이라 destroyTabStandalone 안 씀). capacity 예약으로 append를 무실패화.
    fn buildWorkspaceTab(self: *AppSession, m: app.workspace.Tab) !*Tab {
        if (m.panes.len == 0) return error.EmptyTab;
        const tab = try self.allocator.create(Tab);
        errdefer self.allocator.destroy(tab);
        tab.* = .{};
        errdefer tab.panes.deinit(self.allocator);
        errdefer for (tab.panes.items) |p| self.destroyPane(p);

        try tab.panes.ensureTotalCapacity(self.allocator, m.panes.len);
        for (m.panes) |pm| tab.panes.appendAssumeCapacity(try self.buildWorkspacePane(pm));

        // 트리 빌드 — 새로 만든 split 노드를 추적해 에러 시 전부 해제(트리 미완성이라 PaneTree.deinit 못 씀).
        // capacity를 split 노드 수만큼 미리 잡아 추적 append를 무실패화한다: create 직후 append가 OOM이면 그
        // split이 추적되지 않아 누수되므로, 예약된 무실패 append로 create↔추적 사이의 빈틈을 없앤다.
        var split_count: usize = 0;
        for (m.tree) |n| switch (n) {
            .split => split_count += 1,
            .leaf => {},
        };
        var splits: std.ArrayList(*PaneTree.Split) = .empty;
        defer splits.deinit(self.allocator);
        try splits.ensureTotalCapacity(self.allocator, split_count);
        errdefer for (splits.items) |s| self.allocator.destroy(s);
        // 트리 leaf↔pane 1:1 검증용(corruption graceful). 손상 파일이 같은 pane을 두 leaf로 참조하면 같은 *Pane이
        // 트리에 두 번 들어가 close 시 removeLeaf가 첫 매치만 접고 destroyPane이 free → 두 번째 leaf가 dangling(UAF).
        // 미참조 pane은 보이지 않는 라이브 셸(고아)이 된다. 각 pane이 정확히 1회 참조되는지 확인해 둘 다 막는다.
        const used = try self.allocator.alloc(bool, tab.panes.items.len);
        defer self.allocator.free(used);
        @memset(used, false);
        var idx: usize = 0;
        const root = try self.buildWorkspaceTreeNode(tab.panes.items, m.tree, &idx, &splits, used);
        if (idx != m.tree.len) return error.MalformedTree; // preorder를 다 안 소비했다(노드 수 불일치)
        for (used) |u| if (!u) return error.MalformedTree; // 트리가 참조 안 한 고아 pane(보이지 않는 라이브 셸) 차단
        tab.tree = root;
        tab.active_pane = @min(m.active_pane, tab.panes.items.len - 1);
        // 워크스페이스 사용자 rename 복원 — 마지막 fallible 단계로 둬, OOM 시 위 errdefer(panes·tab)가 정리하고
        // custom_name은 아직 미할당이라 누수가 없다.
        tab.custom_name = try self.dupeCustomName(m.custom_name);
        tab.pinned = m.pinned; // 위치 고정 복원
        tab.background_color = m.background_color; // 카드 배경 tint 복원
        return tab;
    }

    /// 모델 preorder TreeNode 한 subtree를 소비해 PaneTree.Node를 만든다. leaf는 panes[idx]를, split은 새 Split
    /// (dir/ratio)을 할당하고 뒤따르는 두 subtree(a,b)를 재귀로 짓는다. 할당한 split은 splits에 추적(에러 해제용).
    fn buildWorkspaceTreeNode(self: *AppSession, panes: []const *Pane, nodes: []const app.workspace.TreeNode, idx: *usize, splits: *std.ArrayList(*PaneTree.Split), used: []bool) !PaneTree.Node {
        if (idx.* >= nodes.len) return error.MalformedTree;
        const node = nodes[idx.*];
        idx.* += 1;
        switch (node) {
            .leaf => |pane_index| {
                if (pane_index >= panes.len) return error.MalformedTree;
                if (used[pane_index]) return error.MalformedTree; // 같은 pane을 두 leaf로 참조(중복) — UAF 차단
                used[pane_index] = true;
                return .{ .leaf = panes[pane_index] };
            },
            .split => |s| {
                const split = try self.allocator.create(PaneTree.Split);
                splits.appendAssumeCapacity(split); // capacity 예약됨 — 무실패 추적(create↔추적 사이 누수 없음)
                split.* = .{
                    .direction = s.direction,
                    .ratio = app.split_tree.clampRatio(@as(f32, @floatFromInt(s.ratio_milli)) / 1000.0),
                    .a = try self.buildWorkspaceTreeNode(panes, nodes, idx, splits, used),
                    .b = try self.buildWorkspaceTreeNode(panes, nodes, idx, splits, used),
                };
                return .{ .split = split };
            },
        }
    }

    /// 모델 Pane → 완성된 *Pane. 첫 surface로 createPane(=1 Term)하고 나머지 surface를 Term으로 추가한다.
    fn buildWorkspacePane(self: *AppSession, m: app.workspace.Pane) !*Pane {
        if (m.surfaces.len == 0) return error.EmptyPane;
        const pane = try self.createPaneFromSurface(m.surfaces[0]);
        errdefer self.destroyPane(pane);
        pane.custom_name = try self.dupeCustomName(m.custom_name); // pane 사용자 rename 복원(errdefer destroyPane이 정리)
        try pane.terms.ensureTotalCapacity(self.allocator, m.surfaces.len);
        for (m.surfaces[1..]) |sm| pane.terms.appendAssumeCapacity(try self.createTermFromSurface(sm));
        pane.active_term = @min(m.active_term, pane.terms.items.len - 1);
        return pane;
    }

    /// 복원 surface 하나로 spawn 준비(createPane/createTerm 공통). new_tab_config에 저장 grid를 얹고, 사용 가능한
    /// (존재하는 디렉터리) cwd면 그걸 쓴다 — 마지막 create 호출만 두 함수가 다르다. 모델의 command(argv[0])·title은
    /// v1 복원에선 쓰지 않는다(기본 셸·"Maru"로 spawn; 정확한 argv·제목 복원은 후속) — 저장은 향후 복원용으로만.
    fn restoreSpawn(self: *AppSession, sm: app.workspace.Surface) struct { req: maru.pty.SpawnRequest, size: terminal.Size } {
        var cfg = self.new_tab_config;
        const size = restoreSurfaceSize(sm);
        cfg.size = size;
        var req = spawnRequest(cfg, self.loaded_config.config.term, self.new_tab_zdotdir, self.new_tab_ssh_bin);
        if (usableRestoreCwd(sm.cwd)) |c| req.cwd = c; // 존재하는 디렉터리면 거기서, 아니면 기본 cwd(surface 안 잃음)
        return .{ .req = req, .size = size };
    }

    /// 직렬화 모델의 custom_name(""=없음)을 라이브 owned `?[]const u8`(null=없음)로 변환한다 — 비면 null,
    /// 아니면 세션 allocator로 dupe. 복원과 rename commit(PR3)이 공유하는 ""→null 단일 변환점이라 규칙이 한 곳뿐이다.
    fn dupeCustomName(self: *AppSession, name: []const u8) !?[]const u8 {
        if (name.len == 0) return null;
        return try self.allocator.dupe(u8, name);
    }

    fn createPaneFromSurface(self: *AppSession, sm: app.workspace.Surface) !*Pane {
        const rs = self.restoreSpawn(sm);
        const cfg = self.new_tab_config;
        const pane = try self.createPane(rs.req, rs.size, cfg.queue_capacity, "Maru", commandName(cfg.command_kind));
        errdefer self.destroyPane(pane);
        // 첫 Term(=이 surface)의 사용자 rename 복원. 실패 시 errdefer destroyPane이 정리한다.
        pane.activeTerm().surface.custom_name = try self.dupeCustomName(sm.custom_name);
        return pane;
    }

    fn createTermFromSurface(self: *AppSession, sm: app.workspace.Surface) !*Term {
        const rs = self.restoreSpawn(sm);
        const cfg = self.new_tab_config;
        const term = try self.createTerm(rs.req, rs.size, cfg.queue_capacity, "Maru", commandName(cfg.command_kind));
        errdefer self.destroyTerm(term);
        term.surface.custom_name = try self.dupeCustomName(sm.custom_name);
        return term;
    }

    /// quick terminal 표시 옵션(config에서 파싱). Swift가 패널 크기·화면·자동 숨김에 쓴다. 세션 동안 불변.
    pub fn quickTerminalConfig(self: *const AppSession) QuickTerminalConfig {
        const qt = self.loaded_config.config.quick_terminal;
        return .{
            .height_milli = @intFromFloat(@round(qt.height_fraction * 1000.0)),
            .auto_hide = if (qt.auto_hide) 1 else 0,
            .screen = @intFromEnum(qt.screen),
            .position = @intFromEnum(qt.position),
            .chrome = @intFromEnum(qt.chrome),
            .minimal_tabs = if (qt.minimal_tabs) 1 else 0,
            .width_milli = @intFromFloat(@round(qt.width_fraction * 1000.0)),
        };
    }

    /// 한 화면씩 스크롤(Shift+PageUp/Down). delta_pages>0=위(과거). 한 화면은 rows-1줄(한 줄 겹침)이고,
    /// rows는 app session이 권위 있게 알고 있어 Swift가 stale 값으로 계산하지 않게 여기서 구한다.
    // pageScrollDelta는 session core로 추출됐다(위 file-scope alias=input_math.pageScrollDelta로 호출).
    // 정의·단위 테스트는 src/session/input_math.zig.

    pub fn scrollPage(self: *AppSession, delta_pages: i32) void {
        if (!self.surface_initialized) return;
        const rows = self.activeSurface().core.size.rows;
        const page: i32 = @max(@as(i32, 1), @as(i32, rows) - 1);
        self.scrollLines(delta_pages *| page);
    }

    /// 이전(dir<0)/다음(dir>0) 프롬프트 블록으로 뷰포트를 점프한다(OSC 133 셸 통합 필요 — Cmd+↑/↓).
    /// 분류·이동 로직은 core가 소유하고, 여기선 스크롤됐으면 다음 tick이 다시 그리도록 metal_dirty만
    /// 세운다(Swift는 방향만 넘기는 얇은 글루 — scrollPage와 같은 규율).
    pub fn jumpToPrompt(self: *AppSession, dir: i8) void {
        if (!self.surface_initialized) return;
        // view_offset mutate라 reader로 위임(full (a), docs/io-render-threading.md §9 P3-4) — 위임된 scroll과 같은
        // 큐를 타 순서 보존(메인 직접 mutate면 reader scroll과 view_offset race). "스크롤됨" 최적화는 reader 렌더 트리거로 대체.
        self.runtime.enqueueCoreCommand(self.activeSurface().id, .{ .jump_to_prompt = dir }, self.io) catch {};
        self.metal_dirty = true;
    }

    pub fn resize(self: *AppSession, width_px: u32, height_px: u32, scale_milli: u32) !FrameSummary {
        // resize는 terminal grid와 PTY winsize가 함께 바뀌어야 한다. FrameLoop API를
        // 통해 SurfaceRuntime action으로 내려보내면 Swift가 두 책임을 다시 구현하지 않는다.
        // total_resize_events는 아래 dedup early-return 뒤(실제 변화가 있는 resize)에서만 센다.
        // Swift가 콜백마다 backing 픽셀을 보내므로, 같은 size+scale 중복은 카운트에 넣지 않는다.
        // scale_milli를 [250,8000]로 막아 손상된 값에서도 곱이 비정상으로 커지지 않게 한다.
        const next_scale = std.math.clamp(scale_milli, 250, 8000);
        const scale_changed = next_scale != self.scale_milli;
        // backing scale이 바뀌면(다른 DPI 디스플레이로 이동 등) cell 메트릭을 분수 scale로 먼저
        // 다시 뽑는다. grid 계산이 placeholder가 아니라 실제 cell 크기를 쓰도록 순서가 중요하다.
        if (scale_changed) {
            self.scale_milli = next_scale;
            self.refreshCellMetrics();
        }
        // grid(cols/rows)를 Swift가 아니라 app session이 backing 픽셀 + 자기 cell 메트릭에서 직접
        // 계산한다. init이 메트릭을 미리 뽑으므로 cell 크기는 항상 준비돼 있어, Swift가 첫 resize에서
        // placeholder 크기로 cols/rows를 잘못 잡던(창과 grid가 어긋나던) 문제가 사라진다.
        const size = gridFromBacking(width_px, height_px, self.cell_width_px, self.cell_height_px, self.sidebar_width_px, self.window_padding_px);
        const size_changed = self.last_resize_size == null or
            self.last_resize_size.?.cols != size.cols or self.last_resize_size.?.rows != size.rows;
        // 같은 size+scale이면 비싼 재작업(TerminalCore.resize alloc/memcpy + PTY winsize/SIGWINCH)을
        // 건너뛴다. Swift의 windowDidResize·backing 콜백·tick 폴링이 한 변화에 여러 번 부를 수
        // 있는데, 매번 적용하면 셸이 SIGWINCH storm으로 다시 그린다(중복방지를 Swift가 아니라
        // 여기서 한 곳에서 처리).
        if (!scale_changed and !size_changed) {
            self.writeSummaryFromState();
            self.last_summary.last_event_kind = @intFromEnum(EventKind.resize);
            return self.last_summary;
        }
        // dedup을 통과한(실제 size/scale 변화가 있는) resize만 센다.
        self.total_resize_events += 1;
        // 종료된 세션의 resize도 live surface가 없어 실패한다. 닫히는 창의 late resize는
        // 치명적 오류가 아니므로 무시하고 정상으로 닫는다(key와 같은 정책).
        if (self.ended_seen) {
            self.writeSummaryFromState();
            self.last_summary.last_event_kind = @intFromEnum(EventKind.resize);
            return self.last_summary;
        }
        // backing 크기를 갱신하고(split leaf rect 계산의 입력) 활성 탭의 각 panel을 자기 leaf rect grid로
        // 재배치한다. 단일 leaf면 활성 surface 하나를 full term grid로 — 기존 resizeActiveSurface와 동일.
        self.backing_width_px = width_px;
        self.backing_height_px = height_px;
        try self.resizeActiveTabPanes();
        self.recomputeActivePaneRect(); // backing/grid가 바뀌었으니 활성 panel rect(좌표 origin)도 갱신
        self.last_resize_size = size;
        // grid가 reflow됐으므로 다음 tick이 Metal frame을 재투영하게 dirty로 표시한다.
        self.metal_dirty = true;
        self.writeSummaryFromState();
        self.last_summary.last_event_kind = @intFromEnum(EventKind.resize);
        return self.last_summary;
    }

    /// MARU_DEBUG일 때 활성 surface의 cell 격자를 찍는다. CJK 등 비-ASCII는 텍스트 줄에서
    /// 공백으로 보이지만 배경 줄(b...)의 'B'로 영역을 알 수 있어, 파란 배경 줄과 프롬프트 줄이
    /// 같은 row에 겹치는지(개행 안 됨) 다른 row인지 데이터로 구분한다.
    fn logScreenIfDebug(self: *AppSession) void {
        if (!diag_gate.maruDebugEnabled() or !self.surface_initialized) return;
        const core = &self.activeSurface().core;
        const cols = @min(@as(usize, core.size.cols), 240);
        // 헤더에 OSC 133 마지막 명령 종료코드도 찍는다(셸 통합이 emit하면 채워진다).
        if (core.last_command_exit) |code| {
            screen_diag.info("=== screen {d}x{d} cursor=({d},{d}) last_exit={d} ===", .{
                core.size.cols, core.size.rows, core.cursor.row, core.cursor.col, code,
            });
        } else {
            screen_diag.info("=== screen {d}x{d} cursor=({d},{d}) ===", .{
                core.size.cols, core.size.rows, core.cursor.row, core.cursor.col,
            });
        }
        // OSC 7로 셸이 보고한 cwd(셸 통합이 emit하면 채워진다). 창 제목이 읽는 값을 데이터로 확인.
        const cwd = core.currentCwd();
        if (cwd.len > 0) screen_diag.info("cwd={s}", .{cwd});
        var text: [240]u8 = undefined;
        var bg: [240]u8 = undefined;
        const grid_cols: usize = core.size.cols;
        for (0..core.size.rows) |row| {
            var any = false;
            for (0..cols) |col| {
                const cell = core.cells[row * grid_cols + col];
                const cp = cell.codepoint;
                text[col] = if (cp >= 0x20 and cp < 0x7f) @intCast(cp) else ' ';
                const has_bg = switch (cell.style.background) {
                    .default => false,
                    else => true,
                };
                bg[col] = if (has_bg) 'B' else '.';
                if ((cp != 0 and cp != ' ') or has_bg) any = true;
            }
            // soft-wrap 플래그를 함께 찍는다(w=다음 줄로 이어짐, .=hard 줄끝). reflow 피드백 루프
            // 회귀는 hard 줄(프롬프트)이 w로 잘못 찍히는 것으로 드러나므로, wrapped인 빈 줄도 보인다.
            const w_mark: u8 = if (row < core.wrapped.len and core.wrapped[row]) 'w' else '.';
            // OSC 133 semantic 분류(P=프롬프트 I=입력 C=명령출력 ·=미분류). 셸 통합이 마커를 emit하면
            // 채워진다 — 프롬프트/입력/출력이 어떤 행으로 잡히는지 데이터로 본다(거터 PR 전 조기 확인).
            const p_mark: u8 = if (row < core.prompt_marks.len) switch (core.prompt_marks[row].kind) {
                .unknown => '.',
                .prompt => 'P',
                .input => 'I',
                .command => 'C',
            } else '.';
            if (!any and w_mark != 'w' and p_mark == '.') continue;
            screen_diag.info("r{d:0>2} {c}{c} t|{s}|", .{ row, w_mark, p_mark, text[0..cols] });
            screen_diag.info("r{d:0>2} {c}{c} b|{s}|", .{ row, w_mark, p_mark, bg[0..cols] });
        }
    }

    /// 프레임마다 셸 의미 이벤트(OSC 133/7)를 소비한다 — MARU_DEBUG면 명령 경계를 구조화 한 줄씩
    /// 찍고, 항상 비워 core의 이벤트 버퍼를 bounded하게 유지한다(누구도 drain 안 하면 cap에서 드롭).
    /// 같은 도메인 데이터를 후속 trace writer도 바로 이 자리에서 drain하면 된다(관측 가능성 원칙).
    fn drainShellEventsForFrame(self: *AppSession) void {
        if (!self.surface_initialized) return;
        const core = &self.activeSurface().core;
        if (core.shellEvents().len == 0 and !core.shellEventsOverflowed()) return;
        if (diag_gate.maruDebugEnabled()) {
            for (core.shellEvents()) |ev| switch (ev) {
                .prompt_start => |r| shell_diag.info("shell.prompt-start row={d}", .{r}),
                .input_start => |r| shell_diag.info("shell.input-start row={d}", .{r}),
                .command_start => |r| shell_diag.info("shell.command-start row={d}", .{r}),
                .command_end => |ce| if (ce.exit) |code|
                    shell_diag.info("shell.command-end row={d} exit={d}", .{ ce.row, code })
                else
                    shell_diag.info("shell.command-end row={d} exit=?", .{ce.row}),
                .cwd_changed => shell_diag.info("shell.cwd-changed cwd={s}", .{core.currentCwd()}),
            };
            // 조용한 손실 방지: cap을 넘어 드롭된 이벤트가 있으면 보고한다.
            if (core.shellEventsOverflowed()) shell_diag.info("shell.events OVERFLOW: cap 초과로 일부 이벤트 드롭", .{});
        }
        core.clearShellEvents();
    }

    /// 각 Term의 포그라운드 프로세스(claude/codex)를 throttled로 polling해 agent_kind를 갱신한다. 매 tick
    /// syscall은 비싸므로 agent_poll_interval_ticks(≈0.5s)마다. 변화가 있으면 metal_dirty로 재렌더(심볼 표시 갱신).
    fn pollAgentKinds(self: *AppSession) void {
        self.agent_poll_ticks += 1;
        if (self.agent_poll_ticks < agent_poll_interval_ticks) return;
        self.agent_poll_ticks = 0;
        if (!self.surface_initialized) return;
        // 사이드바가 보여주는 건 워크스페이스별 **활성 pane의 활성 Term** 하나뿐이라(buildSidebarTitleFrame), 그 Term만
        // poll한다 — 모든 split pane·백그라운드 Term까지 poll하면 syscall이 Term 수로 불어나고, 안 보이는 Term의 agent_kind
        // 변화가 metal_dirty를 올려 동일 프레임을 헛 재렌더한다(code-review 지적). 활성 Term은 전환 후 ≤0.5s 안에 갱신.
        var buf: [256]u8 = undefined;
        for (self.tabs.items, 0..) |tab, idx| {
            const term = tab.activePane().activeTerm();
            if (!term.live_initialized) continue;
            const prev = term.agent_kind;
            term.agent_kind = classifyAgent(term.live_pty.session.foregroundProcessName(&buf));
            if (term.agent_kind != prev) {
                self.metal_dirty = true; // 표시되는 Term의 에이전트 변화 → 사이드바 재렌더
                if (diag_gate.maruDebugEnabled()) std.log.scoped(.agent).info("agent: {s}", .{@tagName(term.agent_kind)});
                // kind가 바뀌면(새 에이전트 시작/종료/claude↔codex 직접 전환) 상태 캐시를 **전부** 리셋한다 —
                // 옛 세션의 mtime/상태/답변이 새 에이전트로 새지 않게. 특히 agent_state를 unknown으로 되돌려야
                // 직접 전환(claude .running → codex) 때 stale한 prev_state로 가짜 running→idle 알림이 안 뜬다.
                term.agent_session_mtime = 0;
                term.agent_state = .unknown;
                term.agent_answer_len = 0;
            }
            // "보고 있는" 탭 = 포커스 창의 활성 탭. 그 외(비활성 탭 / 백그라운드 창)에서 완료되면 알림한다.
            const is_current = idx == self.app_window.active_tab and self.window_focused;
            if (term.agent_kind != .none) self.pollAgentState(term, tab, is_current);
        }
    }

    /// 에이전트 포그라운드인 Term의 진행 상태(running/idle)를 세션 JSONL tail로 갱신한다. 세션 파일 위치 I/O는
    /// agent_session(L4)이, 바이트→상태 판정은 session core가 한다. cwd(OSC 7)를 모르면(아직 미보고) 보류한다 —
    /// 잘못된 cwd로 엉뚱한 세션을 읽지 않게. mtime이 직전과 같으면 agent_session.poll이 재파싱을 건너뛴다.
    /// `is_current`=포커스 창의 활성 탭(사용자가 보고 있음) — 그게 아닌데 running→idle로 끝나면 완료 알림을 큐에 넣는다.
    fn pollAgentState(self: *AppSession, term: *Term, tab: *Tab, is_current: bool) void {
        const kind: agent_session.Kind = switch (term.agent_kind) {
            .none => return,
            .claude => .claude,
            .codex => .codex,
        };
        const cwd = term.surface.core.currentCwd();
        if (cwd.len == 0) return; // OSC 7 cwd 아직 없음 — 다음 poll에.
        const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else return;
        const subdir: []const u8 = switch (kind) {
            .claude => ".claude/projects",
            .codex => ".codex/sessions",
        };
        var root_buf: [4096]u8 = undefined;
        const root = std.fmt.bufPrint(&root_buf, "{s}/{s}", .{ home, subdir }) catch return;

        const prev_state = term.agent_state;
        const r = agent_session.poll(self.io, self.allocator, kind, root, cwd, term.agent_session_mtime, &term.agent_answer_buf);
        const new_state = r.state orelse {
            term.agent_session_mtime = r.mtime; // null = mtime 동일 — 갱신 무해, 직전 상태 유지(재파싱 skip)
            return;
        };
        // unknown(세션 못 찾음 / tail에 완전한 엔트리 없음)은 **직전 상태를 보존**한다(AgentState.unknown 계약).
        // running을 unknown으로 덮으면 사이드바가 깜빡이고, running→idle 전환 edge를 놓쳐 완료 알림이 누락된다.
        // mtime을 갱신하지 않아 다음 poll에 다시 시도한다(거대 단일 줄/쓰는 중이던 경우 곧 완전한 줄이 보임).
        if (new_state == .unknown) return;
        term.agent_session_mtime = r.mtime;
        const new_answer_len: usize = if (new_state == .idle) r.answer_len else 0;
        if (new_state != term.agent_state or new_answer_len != term.agent_answer_len) {
            self.metal_dirty = true; // 상태/답변 변화 → 사이드바 재렌더
            if (diag_gate.maruDebugEnabled()) std.log.scoped(.agent).info("agent state: {s}", .{@tagName(new_state)});
        }
        term.agent_state = new_state;
        term.agent_answer_len = new_answer_len;
        // 완료 알림: running→idle 전환을 처음 관측했고(전환 edge가 자연 디바운스 — idle 유지 중엔 mtime-skip으로
        // 재진입 안 함), "보고 있는" 탭이 아니며, config가 켜졌을 때만. unknown→idle(원래 idle이던 세션)은 알림 안 함.
        if (prev_state == .running and new_state == .idle and !is_current and self.loaded_config.config.notifications.agent_complete) {
            self.enqueueAgentCompletion(tab, term);
        }
    }

    /// 완료 알림 한 건을 큐에 넣는다(title=워크스페이스 이름, body=마지막 답변 일부 또는 "완료"). owned dup 실패는
    /// 조용히 버린다(best-effort — 알림은 부가 기능). 큐가 상한이면 가장 오래된 걸 버려 폭주를 막는다.
    fn enqueueAgentCompletion(self: *AppSession, tab: *Tab, term: *Term) void {
        const title = self.allocator.dupe(u8, workspaceLabel(tab)) catch return;
        const body_src: []const u8 = if (term.agent_answer_len > 0) term.agent_answer_buf[0..term.agent_answer_len] else "완료";
        const body = self.allocator.dupe(u8, body_src) catch {
            self.allocator.free(title);
            return;
        };
        if (self.agent_notifications.items.len >= agent_notification_cap) {
            const dropped = self.agent_notifications.orderedRemove(0);
            self.allocator.free(dropped.title);
            self.allocator.free(dropped.body);
        }
        self.agent_notifications.append(self.allocator, .{ .title = title, .body = body }) catch {
            self.allocator.free(title);
            self.allocator.free(body);
        };
    }

    /// 모든 Term의 자동 제목 캐시(auto_title)를 core_mutex 하에 갱신한다 — termLabel(렌더 스레드)이 reader 스레드의
    /// core.title/cwd free(OSC 0/2/7)와 경합하지 않게 owned 복사본을 만든다(io-render-threading PR3). 매 tick 호출.
    /// 라이브 windowTitle(OSC 제목 > cwd basename)이 비면 캐시를 비워 termLabel이 정적 surface.title로 폴백한다.
    /// OOM이면 append만 무시(라벨이 잠깐 비어 surface.title 폴백 — 안전). live_pty 미초기화 Term은 건너뛴다.
    fn syncAutoTitles(self: *AppSession) void {
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    if (!term.live_initialized) continue;
                    term.surface.lockCore(self.io);
                    defer term.surface.unlockCore(self.io);
                    const live = term.surface.core.windowTitle();
                    term.auto_title.clearRetainingCapacity();
                    if (live.len > 0) term.auto_title.appendSlice(self.allocator, live) catch {};
                }
            }
        }
    }

    pub fn tick(self: *AppSession) !FrameSummary {
        // macOS 제품 실행은 실제 CoreText shaper/rasterizer로 frame을 만든다(fake backend
        // 아님). 그래야 summary의 glyph/atlas 통계가 실제 rasterized glyph를 반영하고, 이후
        // 제품 Metal view가 같은 RenderFrame을 그대로 그릴 수 있다. CoreText는 platform
        // 경계라 builder가 소유한다.
        //
        // 비-macOS(주로 Linux CI의 ABI 계약 테스트)에는 CoreText 브리지 심볼이 없다. OS
        // 게이트는 comptime이라 Linux 빌드는 macOS 분기를 codegen에서 제외하므로 extern
        // 참조가 생기지 않고, frame loop 계약만 fake backend로 유지한다.
        // PTY queue를 non-blocking으로 비운다(output/exit 감지). 이 drain은 매 tick 필요하지만
        // 싸다. 생명주기 회계(이벤트 합산, 종료 reap)도 build 여부와 무관하게 매 tick 한다 —
        // Metal 투영이나 비싼 build가 실패/생략돼도 drained 이벤트나 finishAfterTermination
        // (reader join/child reap)을 건너뛰지 않게 한다.
        self.applyDragAutoscroll(); // 드래그가 grid 밖에 머무는 동안 30Hz로 한 줄씩 스크롤+확장
        self.flushPendingPaste(); // 큰 붙여넣기의 잔여를 자식이 읽는 속도에 맞춰 흘려보낸다
        self.pollAgentKinds(); // 포그라운드 프로세스(claude/codex) polling — throttled, 각 Term agent_kind 갱신
        self.syncAutoTitles(); // 라벨용 자동 제목 캐시 갱신(core_mutex 하 owned 복사 — termLabel use-after-free 회피)
        // 모든 탭의 모든 panel의 모든 Term PTY를 drain한다 — 백그라운드 탭/panel/탭(Term)도 출력을 받게
        // (routing은 surface_id로 각 surface에 가고, frame은 아래에서 활성 탭만 빌드한다). summary는 보고용.
        var drain_summary: app.RuntimePumpDrainSummary = .{};
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    if (!term.live_initialized) continue;
                    const ds = try term.pump.drainAvailable();
                    drain_summary.output_events += ds.output_events;
                    drain_summary.exit_events += ds.exit_events;
                    // Term별로 종료를 한 번만 finish(reader join + child reap). 세션 종료는 '모든' Term이 끝났을 때.
                    if (ds.ended != null and !term.terminated) {
                        term.live_pty.finishAfterTermination();
                        term.terminated = true;
                        drain_summary.ended = ds.ended; // 마지막 관측 종료를 frame 보고에 싣는다
                    }
                }
            }
        }
        self.total_output_events += drain_summary.output_events;
        self.total_exit_events += drain_summary.exit_events;
        // 개별 Term이 exit하면(전부는 아닌) 그 Term을 자동으로 닫는다(계층 cascade: Term→pane→워크스페이스,
        // PR5b). 이번 tick에 새 종료가 관측됐을 때만 — 살아있는 Term이 있으면 같은 tick에 reap되고, 전부 죽으면
        // 아래 세션 종료 latch가 마지막을 맡는다(그래서 reap이 빈 세션을 만들지 않는다).
        if (drain_summary.ended != null) self.reapTerminatedTerms();
        // 세션(창) 종료: live 탭이 전부 terminated면. 단일 탭이면 그 탭이 끝나는 즉시(기존 동작 보존).
        if (!self.termination_finished and self.allTabsTerminated()) {
            self.ended_seen = true;
            self.termination_finished = true;
        }

        // 새 output이 있을 때만 frame이 바뀐다(resize는 resize()가 dirty를 세운다). idle tick은
        // 비싼 부분(buildDrawList + 전체 grid CoreText shape + atlas/raster 준비)을 통째로
        // 건너뛴다 — 출력 없는 셸이 매 30Hz tick마다 grid를 다시 shape하느라 CPU를 태우거나
        // 머신이 idle/sleep으로 못 들어가게 하지 않는다. generation도 그대로라 재드로우도 생략된다.
        // 가정: 모든 시각 변화는 PTY output(또는 resize)에서 온다. cursor blink나 주기적 redraw
        // 같은 PTY와 무관한 변화를 넣게 되면, 그 트리거에서도 metal_dirty를 세워야 한다.
        if (drain_summary.output_events > 0) self.metal_dirty = true;
        // 깜빡임: 출력이 흐르면 보이는 위상으로 리셋(커서가 움직이는 동안 항상 보이게), idle이면 500ms마다 토글.
        // steady/숨김 커서 + 오버레이 닫힘이면 updateCursorBlink가 무토글로 고정한다. 오버레이 caret도 같은 위상으로
        // 깜빡이고, suffix-trim(setCursorVisible)이라 재빌드 없이 토글된다(터미널 커서와 같은 메커니즘 재활용).
        if (drain_summary.output_events > 0) self.resetCursorBlink() else self.updateCursorBlink();
        self.updateScrollbarFade(); // 스크롤바 fade: view_offset 변화/hover/드래그로 full↔faint(appendScrollbar 전에 갱신)
        // synchronized output(DECSET 2026): sync 중이면 frame 투영을 멈춘다(metal_dirty는 쌓인 채 유지) — ESU(2026
        // reset)로 sync가 꺼지면 다음 tick에 누적 출력을 한 frame으로 투영한다(render skip과 동형). 단 ESU가
        // 영영 안 오면 freeze되므로 hold가 sync_timeout_ticks를 넘으면 강제 해제한다(아래 sync_blocks).
        const sync_active = blk: {
            // sync_output(DECSET 2026)은 리더 core.write가 set/clear — 락 아래 읽는다(docs/io-render-threading.md PR3).
            const s = self.activeSurface();
            s.lockCore(self.io);
            defer s.unlockCore(self.io);
            break :blk s.core.sync_output;
        };
        if (sync_active) {
            self.sync_hold_ticks +|= 1;
        } else {
            self.sync_hold_ticks = 0;
        }
        // sync가 켜져 있고 아직 timeout 전이면 투영을 막는다(ESU가 누적 출력을 한 frame으로 풀 때까지). timeout을
        // 넘기면 sync_active여도 막지 않아 freeze가 풀린다.
        const sync_blocks = sync_active and self.sync_hold_ticks < sync_timeout_ticks;
        if (self.metal_dirty and !sync_blocks) {
            var tick_result = if (builtin.os.tag == .macos) blk: {
                const frame_builder = coretext_frame_builder.CoreTextFrameBuilder{
                    .appearance = self.appearance,
                    .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
                    .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
                    .scale_milli = self.scale_milli,
                    .cell_width_px = @intCast(self.cell_width_px),
                    .cell_height_px = @intCast(self.cell_height_px),
                };
                break :blk try self.frame_loop.tickAfterDrainWithFrameBuilder(drain_summary, frame_builder);
            } else try self.frame_loop.tickAfterDrain(drain_summary, renderer.FakeFontBackend{});
            defer tick_result.deinit(self.allocator);

            // Find가 열린(또는 ⌘G 닫힘-네비) 채 앱이 출력으로 alt screen에 들어가면 Find를 닫는다 — 같은
            // findSuppressed 정책(surface 가드 포함). 매치도 비워 하이라이트를 정리한다.
            if ((self.chrome_host.find.open or self.find_nav) and self.findSuppressed()) {
                self.chrome_host.find.hide();
                self.find_matches.clearRetainingCapacity();
                self.find_nav = false;
                self.metal_dirty = true;
            }
            // Find 열린 채(또는 ⌘G 닫힘-네비 중) 새 출력이 들어오면 매치 절대 좌표가 어긋날 수 있다(스크롤백
            // eviction). 재검색해 하이라이트를 최신으로 유지하되 현재 인덱스만 clamp하고 스크롤은 하지 않는다.
            const find_active = self.chrome_host.find.open or self.find_nav;
            // 스크롤백 Find 재검색·뷰포트 클립은 활성 surface 코어를 읽고(findMatches는 ensureScrollbackRewrapped로
            // 스크롤백을 mutate) 리더 core.write와 경합하므로 락 아래(docs/io-render-threading.md PR3). matchViewportSpan
            // 루프까지 한 락으로 — find_view_spans/setMatchCount는 app 상태라 락 보유 중 안전.
            self.find_view_spans.clearRetainingCapacity();
            var find_current_span: ?terminal.SelectionSpan = null;
            {
                const fa_surface = self.activeSurface();
                fa_surface.lockCore(self.io);
                defer fa_surface.unlockCore(self.io);
                if (find_active and drain_summary.output_events > 0) {
                    fa_surface.core.findMatches(self.allocator, self.chrome_host.find.input.query.items, &self.find_matches) catch self.find_matches.clearRetainingCapacity();
                    self.chrome_host.find.setMatchCount(self.find_matches.items.len); // 매치 수 동기화 + current clamp(스크롤은 안 함)
                }
                // 활성 surface 매치를 뷰포트 span으로 클립(Find 활성일 때만). 현재 매치는 별도 강조색(current_match),
                // 나머지는 find_view_spans. 닫힌 채 ⌘G 네비(find_nav,!open)면 현재 매치만.
                if (find_active) {
                    for (self.find_matches.items, 0..) |m, mi| {
                        const span = fa_surface.core.matchViewportSpan(m) orelse continue;
                        if (mi == self.chrome_host.find.current) {
                            find_current_span = span;
                        } else if (self.chrome_host.find.open) {
                            self.find_view_spans.append(self.allocator, span) catch {};
                        }
                    }
                }
            }
            // Metal view 데이터 투영 실패(OOM 등)는 터미널 코어 동작과 무관하다. 마지막
            // frame을 유지하고 dirty를 남겨 다음 tick에 재시도한다(세션을 죽이지 않는다).
            // 활성 surface 코어 색/선택 상태(palette 복사·fg/bg·reverse·selection·hover)를 하나의 락 아래
            // 읽는다(docs/io-render-threading.md PR3 — 리더 core.write와 경합 방지). palette는 소유 버퍼로 복사해
            // CellColors가 코어 포인터를 안 들게 한다(복사본은 이 tick 동안 유효, replace가 소비). 리터럴은
            // shaping/GPU 없이 값만 모으므로 락 보유가 짧다(.cursor 등 app state는 코어 무관).
            const cc_surface = self.activeSurface();
            cc_surface.lockCore(self.io);
            self.active_palette_copy = cc_surface.core.paletteOverride().*;
            const cell_colors: metal_frame.CellColors = .{
                // OSC 10/11 색 설정이 있으면 그 색, 없으면 theme 기본. SGR reverse의 default 색 스왑·OSC 11 배경에도 반영.
                .default_fg = self.activeSurface().core.defaultFgOverride() orelse self.appearance.theme.foreground,
                .default_bg = self.activeSurface().core.defaultBgOverride() orelse self.appearance.theme.background,
                .palette = &self.active_palette_copy, // 코어 alias 대신 소유 복사본(OSC 4 .indexed 색 풀이)
                // ANSI 16색 config base(theme.palette). OSC4 override가 없을 때만 index<16에 적용(OSC4 → config → xterm256).
                // appearance는 세션 동안 불변·소유라 포인터 안전(복사 불필요) — OSC4 복사본과 달리 매 tick 변하지 않는다.
                .config_palette = &self.appearance.theme.palette,
                .screen_reverse = self.activeSurface().core.reverseScreen(), // DECSCNM(?5) 화면 전역 반전(G9)
                // blink(SGR 5): config text.blink가 켜졌을 때만 위상(blink_visible)을 반영해 off 위상에 숨긴다.
                // 꺼져 있으면(기본) 항상 on → 정적(안 깜빡임). 접근성 기본값.
                .blink_on = !self.appearance.blink_text or self.blink_visible,
                .selection_bg = self.appearance.theme.selection,
                .selection = self.activeSurface().core.selectionViewportSpan(),
                .hover_link = self.hoverLinkSpan(),
                // 스크롤백 Find 매치 하이라이트(활성 surface에만 적용 — 비활성 pane은 inactive_colors).
                .search_match_bg = self.appearance.theme.search_match,
                .search_matches = self.find_view_spans.items,
                .current_match_bg = self.appearance.theme.search_match_current,
                .current_match = find_current_span,

                // 커서는 반전 블록으로 그린다: 칸 배경=theme.cursor, 그 위 glyph=theme.background.
                // blink와 무관하게 항상 투영한다 — off 위상 숨김은 metal_buffer가 커서 suffix 노출
                // 길이로 처리해(setCursorVisible) frame rebuild가 필요 없다.
                .cursor = .{
                    .block = self.appearance.theme.cursor,
                    .text = self.appearance.theme.background,
                },
            };
            cc_surface.unlockCore(self.io); // cell_colors의 활성 코어 읽기 끝 — 이후 shaping/GPU는 락 밖
            // 사이드바 탭 제목 glyph 패스(macOS만 — buildFromDrawList는 실 CoreText 브리지). 터미널과
            // 같은 frame_builder/renderer_state(atlas)를 써서 제목 glyph도 같은 slot을 재사용한다. 실패는
            // 무시하고 제목 없이 밴드만 그린다(세션을 죽이지 않음). 짧은 제목이라 매 frame 재-shape해도
            // 싸고, atlas dedup이 새 glyph만 업로드한다.
            var sidebar_frame: ?renderer.RenderFrame = null;
            if (builtin.os.tag == .macos) {
                sidebar_frame = self.buildSidebarTitleFrame() catch null;
            }
            defer if (sidebar_frame) |*sf| sf.deinit(self.allocator);
            // 사이드바 상단 헤더 glyph(검색 placeholder + view options ⚙·새 워크스페이스 + 아이콘) — 절대 좌표라
            // 카드(sidebar_frame)와 별도 frame. replace가 origin(0,0) 기반 cells로 헤더 영역 [0,header)에 직접
            // 박는다(카드·밴드만 .m이 header_h 시프트). 실패는 무시(헤더 없이 정상). 같은 atlas라 slot 비충돌.
            var sidebar_header_frame: ?renderer.RenderFrame = null;
            if (builtin.os.tag == .macos) {
                sidebar_header_frame = self.buildSidebarHeaderFrame() catch null;
            }
            defer if (sidebar_header_frame) |*hf| hf.deinit(self.allocator);
            // 최상위 모달 오버레이 frame(열렸을 때만, macOS). Notice·Find·Palette는 배타적이라 하나만 그린다(replace의
            // overlay_frame). 셋 다 chrome 컴포넌트 경로(buildChromeOverlayFrame → collectDraws/collectPaletteDraws →
            // 일반 rasterizer placeText)로 lower한다 — palette도 C1b에서 이주해 같은 EAW-폭 경로를 탄다. 실패는 무시
            // (오버레이 없이 정상). PaneFrame.frame을 deinit해야 하므로 defer로 정리한다.
            self.dropQuadsByLayer(1); // C4b 모달: 이전 프레임 모달 quad(layer1)를 비운다 — 닫혀도 잔존 안 함(아래서 재채움).
            self.dropQuadsByLayer(2); // C4b-5: 탭 밴드 quad(layer2)도 per-frame — 매 프레임 비우고 탭 바 build가 재채운다(미연결 시 no-op).
            self.dropQuadsByLayer(3); // 스크롤바(layer3 over)도 per-frame — drop과 append를 짝지어 깜빡임/누적 방지.
            self.appendPaneScrollbars(); // 모든 pane 우측 thumb(스크롤백 있을 때만) — 활성=fade/hover, 비활성=faint
            self.gpu_shadows.clearRetainingCapacity(); // C4b 모달: 그림자도 per-frame — 매 프레임 비우고 lowering이 재채움.
            var overlay_frame: ?metal_frame.PaneFrame = null;
            if (builtin.os.tag == .macos) {
                if (self.chrome_host.notice.open or self.chrome_host.context_menu.open or self.chrome_host.find.open or self.chrome_host.palette.open) {
                    overlay_frame = self.buildChromeOverlayFrame() catch null;
                }
            }
            defer if (overlay_frame) |*pf| pf.frame.deinit(self.allocator);
            // 제목 glyph 투영용 색(전경=테마 글자색). 밴드는 rebuildSidebar가 이미 색을 박아 넘긴다.
            const sidebar_colors: metal_frame.CellColors = .{ .default_fg = self.appearance.theme.foreground };

            // 활성 탭의 leaf별 frame을 N개 합성한다. 단일 leaf(split 전)면 활성 frame 하나가 터미널 영역
            // 전체에 그려진다(origin = leaf rect = (사이드바 폭, 0)) — 기존 동작 보존. split이면 비활성 panel은
            // 각자 surface snapshot으로 frame을 만들어(커서/선택 없는 plain 색) 먼저 넣고, 활성 panel(frame_loop가
            // 만든 tick_result.frame)을 자기 leaf rect origin으로 '맨 뒤'에 둔다(맨 뒤 = 커서 suffix). 비활성
            // frame 빌드는 실 CoreText 브리지라 macOS에서만; 실패한 panel은 건너뛴다(세션 안 죽임).
            var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
            defer leaf_rects.deinit(self.allocator);
            self.activeTabLeafRects(self.allocator, self.termRect(), &leaf_rects) catch {};
            const active_pane = self.activePane();

            // per-pane 상단 탭 바 chrome: 바 배경(전체) + 활성 Term 탭 하이라이트. 각 panel rect 상단 바에 origin
            // 박은 배경 셀로 만들어 터미널 셀 스트림에 prepend된다(C1). 바 base = chrome 색(sidebarBg). 활성 Term
            // 탭 강조색은 **포커스된 pane을 구분**한다: 활성 pane은 밝은 sidebarActiveBg, 비활성 pane은 dim
            // sidebarHoverBg(중간 톤) — split에서 pane 포커스를 옮기면 어느 bar가 활성인지 시각적으로 갱신된다
            // (세로 분할 등에서 "활성 탭 UI가 안 바뀐다"는 제보 대응). 제목 glyph는 아래 pane_frames에(C2).
            var pane_chrome: std.ArrayList(metal_frame.NativeMetalCell) = .empty;
            defer pane_chrome.deinit(self.allocator);
            // rich(corner>0)면 활성 탭을 VSCode식(평평 약한 배경 + 하단 maru 앰버 언더바) layer 2 quad로, tui(0)면 셀 밴드로.
            const tk = self.buildChromeTokens();
            const tk_space = tk.space;
            const tab_corner = tk_space.corner_radius_px; // rich 판별 게이트(>0이면 quad, 0이면 tui 셀)
            const tab_accent = packOpaqueRgb(tk.palette.get(.accent_bar)); // 활성 탭 하단 언더바(maru 앰버 — 포커스 surface 표시)
            for (leaf_rects.items) |lr| {
                const pb = self.paneBar(lr.rect, lr.leaf) orelse continue;
                const bar = pb.full; // 바 배경·언더바는 전체 바(라벨 영역도 같은 chrome 배경)
                const hl_bg = if (lr.leaf == active_pane) self.sidebarActiveBg() else self.sidebarHoverBg();
                const m_opt = barMetrics(pb.tabs, self.cell_width_px, lr.leaf.terms.items.len, tk_space.tab_width_cols, lr.leaf.tab_scroll_cols); // 활성 밴드·‹›는 라벨 뺀 탭 영역
                if (tab_corner > 0) {
                    // rich: 바 배경(직각)·활성 탭(평평 배경 + 하단 앰버 언더바) 모두 layer 2 quad. 바 배경 먼저(아래),
                    // 활성 탭이 위, 제목 셀(part1)은 그 위 — 불투명 바 배경 셀이 quad를 가리던 z-order 버그 해소(리뷰 #1).
                    self.appendBarBgQuad(bar, self.sidebarBg());
                    self.appendTabBarUnderline(bar, tk.border.line_thickness_px); // 탭바 하단 구분선(터미널 콘텐츠와 경계)
                    if (m_opt) |m| self.appendActiveTabHighlight(m, lr.leaf.active_term, hl_bg, tab_accent, tk.border.line_thickness_px);
                    if (m_opt) |m| if (m.has_scroll) { // #5a/#5b: 우측 ‹·› 사각형 버튼 — hover면 밝게(sidebarActiveBg)로 클릭 가능 표시
                        const lh = if (self.hovered_scroll) |hs| (hs.pane == lr.leaf and !hs.right) else false;
                        const rh = if (self.hovered_scroll) |hs| (hs.pane == lr.leaf and hs.right) else false;
                        self.appendScrollButtonQuad(m, m.tab_cols, if (lh) self.sidebarActiveBg() else self.sidebarHoverBg());
                        self.appendScrollButtonQuad(m, m.tab_cols + 2, if (rh) self.sidebarActiveBg() else self.sidebarHoverBg());
                    };
                } else {
                    // tui: 직각 셀 — 바 배경 후 활성 탭 밴드(셀-셀 append 순서로 밴드가 위).
                    if (paneBarBgCell(bar, self.cell_width_px, self.sidebarBg())) |cell| pane_chrome.append(self.allocator, cell) catch {};
                    if (m_opt) |m| {
                        if (tabbarHighlightCell(m, lr.leaf.active_term, hl_bg)) |cell| pane_chrome.append(self.allocator, cell) catch {};
                    }
                }
                // 활성 pane 강조는 활성 탭 하단 앰버 언더바(appendActiveTabHighlight)로 일원화한다(사용자 요청) — 옛
                // 앰버 사각 ring(pane rect 둘레 border quad)은 제거. chrome_minimal은 아래 appendActivePaneBorder(셀 테두리)가 따로 담당.
            }

            // panel 사이 divider 선(PR6) — split이면 각 경계에 seam 중심 셀 strip을 깐다. chrome(맨 아래)이 아니라
            // overlay로 넘겨 터미널 위·커서 아래에 그린다(seam 위라 터미널에 안 가리게). 단일 panel이면 빈 리스트.
            var pane_overlay: std.ArrayList(metal_frame.NativeMetalCell) = .empty;
            defer pane_overlay.deinit(self.allocator);
            self.appendDropTargetHighlight(&pane_overlay); // ④b 드롭 타겟 반투명 하이라이트(divider보다 먼저 → 아래)
            self.appendActiveTabDividers(&pane_overlay);

            // 활성 panel의 origin(터미널 영역 = 바 아래). 못 구하면(빈 리스트 — OOM) 터미널 영역 전체의 바 아래로 폴백.
            const active_fallback = self.paneTermRect(self.termRect());
            var active_origin_x: u32 = active_fallback.x;
            var active_origin_y: u32 = active_fallback.y;
            var active_term_rect: app.SplitRect = active_fallback;
            for (leaf_rects.items) |lr| {
                if (lr.leaf == active_pane) {
                    const t = self.paneTermRect(lr.rect);
                    active_origin_x = t.x;
                    active_origin_y = t.y;
                    active_term_rect = t;
                    break;
                }
            }
            // minimal split: 활성 pane 둘레 얇은 테두리(full·단일 pane이면 무동작). divider 위에 얹어 focus를 보인다.
            self.appendActivePaneBorder(&pane_overlay, active_term_rect, leaf_rects.items.len);
            // 우상단 탭 점 인디케이터(full·단일이면 무동작) — 테두리 **뒤에** append해 정보 chip이 focus 테두리 위에
            // 올라온다(활성 pane이 우상단일 때 테두리 상/우 선이 점을 가로지르던 코너 겹침 해소; chrome 프레임=아래,
            // 정보 chip=위 z-order).
            self.appendMinimalTabIndicator(&pane_overlay);

            var pane_frames: std.ArrayList(metal_frame.PaneFrame) = .empty;
            defer pane_frames.deinit(self.allocator);
            // 드래그 중 floating 탭 미리보기 frame(맨 위에 둘 것). macOS 블록에서 빌드해 활성 터미널 뒤에 넣는다.
            var floating_pf: ?metal_frame.PaneFrame = null;
            // 탭 바 제목·비활성 panel frame은 여기서 소유하고 replace 뒤에 해제한다(pane_frames의 PaneFrame은 같은
            // frame을 가리키는 view일 뿐이라 따로 deinit하지 않는다 — 이중 free 방지). 활성 frame은 tick_result가 소유.
            var built_frames: std.ArrayList(renderer.RenderFrame) = .empty;
            defer {
                for (built_frames.items) |*bf| bf.deinit(self.allocator);
                built_frames.deinit(self.allocator);
            }
            // 비활성 panel 색: 포커스 안 된 panel이라 커서/선택/호버 없음(default 전경/배경만). config_palette는 ANSI 16색
            // base(theme.palette) — 비활성 pane도 자기 OSC4(palette)를 쓰되, OSC4가 없으면 이 config base로 폴백한다
            // (pane_colors가 inactive_colors를 복사해 쓰므로 여기 한 곳에 둔다). appearance는 세션 불변·소유라 포인터 안전.
            const inactive_colors: metal_frame.CellColors = .{
                .default_fg = self.appearance.theme.foreground,
                .default_bg = self.appearance.theme.background,
                .config_palette = &self.appearance.theme.palette,
            };
            // 탭 바 제목 색: 전경=테마 글자색, 배경은 chrome이 이미 깔아 둠(투명).
            const tabbar_colors: metal_frame.CellColors = .{ .default_fg = self.appearance.theme.foreground };
            if (builtin.os.tag == .macos) {
                const pane_frame_builder = coretext_frame_builder.CoreTextFrameBuilder{
                    .appearance = self.appearance,
                    .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
                    .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
                    .scale_milli = self.scale_milli,
                    .cell_width_px = @intCast(self.cell_width_px),
                    .cell_height_px = @intCast(self.cell_height_px),
                };

                // 1) 각 pane의 탭 바 제목 frame — Term 제목들을 가로 등폭 탭으로(buildPaneTabBarDrawList). 활성 panel
                //    커서 suffix가 합쳐진 cells의 끝에 남도록 '터미널 frame들 앞'에 둔다. 바 없는 작은 pane은 건너뜀.
                for (leaf_rects.items) |lr| {
                    const pb = self.paneBar(lr.rect, lr.leaf) orelse continue;
                    // 제목/라벨을 위 패딩만큼 내려 바 가운데에. tui(pad=0)면 바 상단(full.y).
                    const text_origin_y = pb.full.y + @as(u32, self.buildChromeTokens().space.tab_bar_pad_y_px);

                    // 1a) pane 라벨 세그먼트(좌측) — custom_name이 있으면 [full.x, full.x+label_cols*cw)에 이름 glyph.
                    //     탭 영역(pb.tabs)이 라벨만큼 우측으로 밀려 겹치지 않는다(label_cols=0이면 이 블록 생략 = 기존 동작).
                    if (pb.label_cols > 0) {
                        // 이 pane을 rename 중이면 편집 텍스트(+caret), 아니면 custom_name. 편집 중엔 paneBar가 빈
                        // 이름이어도 세그먼트를 띄워(renameDisplayWidth) caret이 보인다. 편집 텍스트는 owned라 해제.
                        var name_buf: ?[]const u8 = null;
                        defer if (name_buf) |b| self.allocator.free(b);
                        const name = if (self.renamingPane(lr.leaf)) blk: {
                            const e = self.renameEditText(self.allocator) catch break :blk app.pickLabel(lr.leaf.custom_name, "");
                            name_buf = e;
                            break :blk e;
                        } else app.pickLabel(lr.leaf.custom_name, "");
                        const label_fg: terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground }; // 밝은 전경(muted 비활성 탭과 구분)
                        if (coretext_frame_builder.buildPaneLabelDrawList(self.allocator, name, @intCast(pb.label_cols), label_fg)) |ldl| {
                            if (pane_frame_builder.buildFromDrawList(self.allocator, ldl, &self.renderer_state)) |lf| {
                                var label_frame = lf;
                                if (built_frames.append(self.allocator, label_frame)) |_| {
                                    pane_frames.append(self.allocator, .{
                                        .frame = label_frame,
                                        .origin_x = pb.full.x,
                                        .origin_y = text_origin_y,
                                        .colors = tabbar_colors,
                                    }) catch {};
                                } else |_| label_frame.deinit(self.allocator); // 추적 실패 시만 해제(라벨 생략, 탭은 계속)
                            } else |_| {}
                        } else |_| {}
                    }

                    // 1b) Term 탭 제목 — 라벨 뒤 탭 영역(pb.tabs)에. 바 없을 만큼 좁으면 건너뜀.
                    const bar_cols = @min(pb.tabs.w / self.cell_width_px, @as(u32, std.math.maxInt(u16)));
                    if (bar_cols == 0) continue;
                    // Term 탭 라벨 "{n} {title}"(n=1-based 탭 번호) — 사이드바 워크스페이스 라벨과 같은 형식이라
                    // 번호로 탭을 빠르게 식별·⌘]/⌘[ 순환 위치를 안다. allocPrint 소유 버퍼라 아래 defer로 해제한다.
                    var titles: std.ArrayList([]const u8) = .empty;
                    defer {
                        for (titles.items) |l| self.allocator.free(l);
                        titles.deinit(self.allocator);
                    }
                    for (lr.leaf.terms.items, 0..) |term, ti| {
                        // Term 탭 라벨 = surface.custom_name(rename) 우선, 없으면 자동 제목. "{n} {label}".
                        // 이 Term을 rename 중이면 그 탭에 편집 텍스트(+caret)를 그려 탭에서 바로 편집되게 한다.
                        if (self.renamingTerm(term)) {
                            const edit = self.renameEditText(self.allocator) catch continue;
                            defer self.allocator.free(edit);
                            const label = tabNumberLabel(self.allocator, ti, edit) catch continue;
                            titles.append(self.allocator, label) catch self.allocator.free(label);
                        } else {
                            const label = tabNumberLabel(self.allocator, ti, termLabel(term)) catch continue;
                            titles.append(self.allocator, label) catch self.allocator.free(label);
                        }
                    }
                    // 비활성 Term 탭은 흐린 색(muted), 그 pane의 활성 Term 탭은 full sidebar_foreground로 강조한다.
                    const tab_fg: terminal.Color = .{ .rgb = self.mutedForeground() };
                    const active_tab_fg: terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };
                    // 이 pane의 탭이 호버 중이면 그 탭에 ✕를 그린다(다른 pane이면 null).
                    const close_tab: ?usize = if (self.hovered_tab) |h| (if (h.pane == lr.leaf) h.tab else null) else null;
                    const dl = coretext_frame_builder.buildPaneTabBarDrawList(self.allocator, titles.items, @intCast(bar_cols), tab_fg, close_tab, lr.leaf.active_term, active_tab_fg, self.buildChromeTokens().space.tab_width_cols, lr.leaf.tab_scroll_cols) catch continue;
                    var f = pane_frame_builder.buildFromDrawList(self.allocator, dl, &self.renderer_state) catch continue;
                    built_frames.append(self.allocator, f) catch {
                        f.deinit(self.allocator);
                        continue;
                    };
                    pane_frames.append(self.allocator, .{
                        .frame = f,
                        .origin_x = pb.tabs.x, // 라벨 뒤 탭 영역 origin(라벨만큼 우측)
                        .origin_y = text_origin_y,
                        .colors = tabbar_colors,
                    }) catch {};
                }

                // 2) 비활성 panel 터미널 frame(자기 활성 Term surface, 바 아래 origin). split일 때만 여럿이다.
                if (leaf_rects.items.len > 1) {
                    // 비활성 pane palette 복사 버퍼를 leaf 수만큼 예약(루프 중 realloc 없이 → 포인터 안정).
                    self.pane_palette_copies.clearRetainingCapacity();
                    self.pane_palette_copies.ensureTotalCapacity(self.allocator, leaf_rects.items.len) catch {};
                    for (leaf_rects.items) |lr| {
                        if (lr.leaf == active_pane) continue; // 활성은 맨 뒤에 따로 넣는다
                        const pane_surface = &lr.leaf.activeTerm().surface;
                        const pane_core = &pane_surface.core;
                        // 코어 읽기(snapshot→DrawList 복사 + per-pane 색 상태)는 락 아래, CoreText shaping
                        // (buildFromDrawList — DrawList 복사본만 봄)은 락 밖(docs/io-render-threading.md PR3).
                        pane_surface.lockCore(self.io);
                        const dl_or = renderer.buildDrawList(self.allocator, pane_core.renderSnapshot());
                        // palette를 소유 버퍼로 복사(코어 alias 제거). 예약 capacity 부족(OOM)이면 코어 포인터 폴백.
                        const pane_palette_ptr = if (self.pane_palette_copies.items.len < self.pane_palette_copies.capacity) blk: {
                            self.pane_palette_copies.appendAssumeCapacity(pane_core.paletteOverride().*);
                            break :blk &self.pane_palette_copies.items[self.pane_palette_copies.items.len - 1];
                        } else pane_core.paletteOverride();
                        const pane_rev = pane_core.reverseScreen(); // DECSCNM(G9) per-pane
                        const pane_fg = pane_core.defaultFgOverride();
                        const pane_bg = pane_core.defaultBgOverride();
                        pane_surface.unlockCore(self.io);
                        const dl = dl_or catch continue;
                        var f = pane_frame_builder.buildFromDrawList(self.allocator, dl, &self.renderer_state) catch continue;
                        built_frames.append(self.allocator, f) catch {
                            f.deinit(self.allocator);
                            continue;
                        };
                        // 비활성 pane도 자기 core의 OSC 4 팔레트·OSC 10/11 색 설정을 쓴다(둘 다 per-터미널 상태).
                        var pane_colors = inactive_colors;
                        pane_colors.palette = pane_palette_ptr;
                        pane_colors.screen_reverse = pane_rev;
                        pane_colors.blink_on = !self.appearance.blink_text or self.blink_visible; // blink 위상(전역, config 게이트)
                        if (pane_fg) |fg| pane_colors.default_fg = fg;
                        if (pane_bg) |bg| pane_colors.default_bg = bg;
                        const t = self.paneTermRect(lr.rect); // 바 아래 영역 origin
                        pane_frames.append(self.allocator, .{
                            .frame = f, // built_frames가 소유(deinit) — 여기는 같은 frame을 가리키는 view
                            .origin_x = t.x,
                            .origin_y = t.y,
                            .colors = pane_colors,
                        }) catch {};
                    }
                }

                // 3) 드래그 중 floating 탭 미리보기 — 커서 위치에 박스+제목. 활성 터미널 '뒤'(맨 위)에 넣어야 하므로
                //    여기선 빌드만 하고 아래에서 append한다(built_frames가 소유).
                floating_pf = self.buildFloatingTabFrame(pane_frame_builder, &built_frames);
            }
            // 활성 panel 터미널을 맨 뒤에(커서 suffix). 단일 leaf·비-macOS면 이게 유일한 터미널 frame이다(기존 동작).
            pane_frames.append(self.allocator, .{
                .frame = tick_result.frame.render_frame,
                .origin_x = active_origin_x,
                .origin_y = active_origin_y,
                .colors = cell_colors,
            }) catch {};
            // floating 탭은 활성 터미널·커서보다 위(맨 마지막 frame)에 그린다 — 드래그 ghost가 가장 위에 보이게.
            if (floating_pf) |pf| pane_frames.append(self.allocator, pf) catch {};

            if (pane_frames.items.len > 0) {
                // kitty graphics(K2d): 활성 surface(이 frame을 만든 surface)의 placement를 GpuImage로 환산하고,
                // generation이 바뀐 이미지만 업로드 채널로 만든다. dest origin은 활성 panel의 픽셀 origin(사이드바
                // 폭·탭 바 아래)으로 박아 터미널 sub-rect에 그려지게 한다. 비활성 panel 이미지는 후속(단일 활성 기준).
                var kg_images: []metal_frame.GpuImage = &.{};
                var kg_uploads: []metal_frame.GpuImageUpload = &.{};
                var kg_pixels: []u8 = &.{};
                var kg_live_ids: std.ArrayList(u32) = .empty;
                defer self.allocator.free(kg_images);
                defer self.allocator.free(kg_uploads);
                defer self.allocator.free(kg_pixels);
                defer kg_live_ids.deinit(self.allocator);
                if (self.surface_initialized) {
                    // 코어 변경(setCellMetrics·setDefaultColors)과 kitty 이미지 읽기(snap.placements/images는
                    // 코어 alias)는 모두 락 아래(docs/io-render-threading.md PR3 — 리더 core.write와 경합 방지).
                    // buildGpuImages/planImageUploads가 이미지 데이터를 owned 버퍼로 복사하므로(planImageUploads는
                    // img.pixels를 appendSlice로 복사), 락 밖 replace()는 코어를 안 본다.
                    const active_surface = self.activeSurface();
                    active_surface.lockCore(self.io);
                    defer active_surface.unlockCore(self.io);
                    // kitty 자동 크기 이미지의 커서 advance용 셀 메트릭을 활성 surface 코어에 주입한다(매 tick 최신).
                    active_surface.core.setCellMetrics(self.cell_width_px, self.cell_height_px);
                    // OSC 10/11 색 질의 응답용 theme 전경/배경 RGB도 주입(코어는 Color.default 추상만 알아 실제 색 필요).
                    active_surface.core.setDefaultColors(self.appearance.theme.foreground, self.appearance.theme.background);
                    const snap = active_surface.core.renderSnapshot();
                    // K4c: 살아있는 이미지 id 집합(활성 surface 저장소). Swift가 이 집합에 없는 텍스처를 evict.
                    for (snap.images) |img| kg_live_ids.append(self.allocator, img.image_id) catch {};
                    // kitty_uploaded를 같은 집합으로 prune — 텍스처가 evict된(=live 아님) 이미지는 dedup 상태에서도
                    // 빼, 다시 활성화되면 재업로드되게(Swift 캐시와 동기). 멀티 surface 전환 시 정합.
                    self.pruneKittyUploaded(kg_live_ids.items);
                    if (snap.placements.len > 0) {
                        kg_images = metal_frame.buildGpuImages(self.allocator, snap.placements, snap.images, snap.size, self.cell_width_px, self.cell_height_px) catch &.{};
                        for (kg_images) |*gi| {
                            gi.origin_x = active_origin_x;
                            gi.origin_y = active_origin_y;
                        }
                        if (kg_images.len > 0) {
                            if (metal_frame.planImageUploads(self.allocator, kg_images, snap.images, &self.kitty_uploaded)) |plan| {
                                kg_uploads = plan.uploads;
                                kg_pixels = plan.pixels;
                            } else |_| {}
                        }
                    }
                }
                if (self.metal_buffer.replace(self.allocator, pane_frames.items, self.renderer_state.atlas.config, self.cell_width_px, self.cell_height_px, sidebar_frame, sidebar_header_frame, self.sidebar_cells.items, sidebar_colors, pane_chrome.items, pane_overlay.items, overlay_frame, self.gpu_quads.items, self.gpu_shadows.items, kg_images, kg_uploads, kg_pixels, kg_live_ids.items)) |_| {
                    self.metal_dirty = false;
                } else |_| {}
            }

            // tick만 아는 per-frame render 통계와 tick index를 summary에 덧씌운다.
            self.writeSummaryFromTick(tick_result);
            self.logScreenIfDebug();
            self.drainShellEventsForFrame();
        } else {
            // idle: build/project를 건너뛰므로 summary는 마지막 frame render 통계를 그대로 둔다.
            self.writeSummaryFromState();
        }
        // 세션이 종료되면 host가 frame loop를 멈추고 우아하게 내려가도록 app_should_terminate를
        // 싣는다. ABI의 tick export는 이 ended를 SessionEnded status로 올려준다.
        self.last_summary.last_event_kind = @intFromEnum(
            if (self.ended_seen) EventKind.app_should_terminate else EventKind.frame_tick,
        );
        return self.last_summary;
    }

    pub fn close(self: *AppSession) FrameSummary {
        self.total_close_events += 1;
        // 창 close — 모든 탭의 모든 panel PTY를 정리한다(활성만이 아니라). runtime이 살아 있으면 detach까지,
        // 아니면 close만.
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    if (term.live_initialized and self.runtime_initialized) {
                        term.live_pty.closeAndDetach(&self.runtime);
                    } else if (term.live_initialized) {
                        term.live_pty.close();
                    }
                }
            }
        }
        if (self.surface_initialized) {
            // App/window close는 더 이상 이 surface가 live input/output을 받을 수 없다는
            // 뜻이다. exit event를 기다리지 않고 close가 child를 정리한 경우에도 summary가
            // running으로 남으면 close lifecycle을 오해하므로 app session summary에서는
            // 종료 상태로 latch한다.
            self.activeSurface().process_state = .exited;
            self.ended_seen = true;
        }
        self.writeSummaryFromState();
        self.last_summary.last_event_kind = @intFromEnum(EventKind.close_requested);
        return self.last_summary;
    }

    /// 사이드바 strip 배경색(0xAARRGGBB). resolved 테마의 `sidebar_background`를 읽기만 한다 — 색 파생
    /// (명시 없으면 배경 +24)은 config resolver(resolveTheme)가 단일 출처로 소유한다. 테마가 명시하면 그 색.
    fn sidebarBg(self: *const AppSession) u32 {
        return packOpaqueRgb(self.appearance.theme.sidebar_background);
    }

    /// 활성 탭 하이라이트 밴드 배경색(0xAARRGGBB). resolved 테마의 `sidebar_active`를 읽기만 한다 — 명시
    /// 없으면 배경 +48(사이드바 배경보다 한 단계 밝게)로 resolveTheme가 파생한다. 테마가 명시하면 그 색.
    fn sidebarActiveBg(self: *const AppSession) u32 {
        return packOpaqueRgb(self.appearance.theme.sidebar_active);
    }

    /// 호버 슬롯 하이라이트 배경색(0xAARRGGBB) — 사이드바 배경(+24)과 활성(+48)의 중간으로 파생한다.
    /// 별도 테마 필드 없이 두 resolved 색의 채널 평균을 써서, 사용자가 사이드바 색을 커스텀해도 호버가
    /// 그 사이 톤을 따라간다(활성보다 약하고 배경보다 또렷한 호버 피드백).
    fn sidebarHoverBg(self: *const AppSession) u32 {
        const a = self.appearance.theme.sidebar_background;
        const b = self.appearance.theme.sidebar_active;
        const r: u32 = (@as(u32, a.r) + b.r) / 2;
        const g: u32 = (@as(u32, a.g) + b.g) / 2;
        const bch: u32 = (@as(u32, a.b) + b.b) / 2;
        return 0xFF00_0000 | (r << 16) | (g << 8) | bch;
    }

    /// 비활성 탭 제목용 흐린 전경색 — sidebar_foreground(테마화된 사이드바 글자색, 기본=foreground)를 background
    /// 쪽으로 45% 섞어 muted한다. 활성 탭은 full sidebar_foreground라 대비로 글자가 도드라진다. 사이드바·pane 탭 바 공유.
    fn mutedForeground(self: *const AppSession) maru.color.Rgb {
        const f = self.appearance.theme.sidebar_foreground;
        const b = self.appearance.theme.background;
        return .{
            .r = @intCast((@as(u32, f.r) * 55 + @as(u32, b.r) * 45) / 100),
            .g = @intCast((@as(u32, f.g) * 55 + @as(u32, b.g) * 45) / 100),
            .b = @intCast((@as(u32, f.b) * 55 + @as(u32, b.b) * 45) / 100),
        };
    }

    /// 스크린 x가 세로 사이드바 영역 안인가(순수 `xInSidebar` 래퍼).
    fn inSidebar(self: *const AppSession, x_px: f64) bool {
        return chrome.components.sidebar.inSidebar(x_px, self.sidebar_width_px);
    }

    /// 사이드바 y → 탭 슬롯 인덱스(순수 `sidebarSlot` 래퍼 — 슬롯 높이·탭 수로 판정).
    fn sidebarSlotAt(self: *const AppSession, y_px: f64) ?usize {
        return chrome.components.sidebar.slotAt(y_px, self.sidebar_header_height_px, self.sidebar_slot_height_px, self.sidebar_visible_tabs.items.len);
    }

    /// 호버 중인 사이드바 슬롯을 갱신한다. 바뀌면 호버 밴드를 다시 만들고(rebuildSidebar) 재드로우한다.
    /// 같은 슬롯이면 무동작 — 한 슬롯 안에서의 마우스 이동이 매번 재드로우를 유발하지 않게 한다.
    fn setHoveredSlot(self: *AppSession, slot: ?usize) void {
        if (usizeOptEql(self.hovered_slot, slot)) return;
        self.hovered_slot = slot;
        self.rebuildSidebar() catch {};
        self.metal_dirty = true;
    }

    /// 호버 중인 per-pane 탭을 갱신한다. 바뀌면 재드로우한다(호버 ✕가 생기거나 사라진다). 같은 탭이면 무동작.
    fn setHoveredTab(self: *AppSession, tab: ?TabRef) void {
        if (tabRefEql(self.hovered_tab, tab)) return;
        self.hovered_tab = tab;
        self.metal_dirty = true;
    }

    /// #5b: 호버 중인 ‹/› 스크롤 버튼을 갱신한다. 바뀌면 재드로우(버튼이 밝아져 클릭 가능 표시). 같으면 무동작.
    fn setHoveredScroll(self: *AppSession, s: ?ScrollRef) void {
        const same = (self.hovered_scroll == null and s == null) or
            (self.hovered_scroll != null and s != null and self.hovered_scroll.?.pane == s.?.pane and self.hovered_scroll.?.right == s.?.right);
        if (same) return;
        self.hovered_scroll = s;
        self.metal_dirty = true;
    }

    /// 마우스가 어느 pane의 탭 바 위면 (그 pane, 탭 index)으로 호버 탭을 갱신하고, 아니면 null로 비운다. 활성
    /// 탭 leaf rect를 펴 각 pane 바를 hit-test한다(마우스 이동마다 — 작은 트리라 cheap). hoverCursor이 호출한다.
    fn updateHoveredTab(self: *AppSession, x_px: f64, y_px: f64) bool {
        var next: ?TabRef = null;
        var next_scroll: ?ScrollRef = null;
        var on_bar = false; // #5c: 탭 바 위 여부 — hoverCursor가 pointingHand(클릭 가능) 판정에 쓴다
        // 매 이동마다 새 ArrayList를 안 만들고 재사용 scratch에 레이아웃을 다시 깐다(할당 churn 제거, 결과는 최신).
        const leaf_rects = &self.hover_leaf_scratch;
        leaf_rects.clearRetainingCapacity();
        if (self.activeTabLeafRects(self.allocator, self.termRect(), leaf_rects)) |_| {
            for (leaf_rects.items) |lr| {
                const pb = self.paneBar(lr.rect, lr.leaf) orelse continue;
                if (pointInRect(x_px, y_px, pb.full)) {
                    on_bar = true; // 탭 바 위 — 탭·‹/›·+·pane 포커스 모두 클릭 가능 영역
                    // 좌측 pane 라벨 영역은 탭 호버 아님(탭0 ✕ 오표시 방지) — 라벨 뒤 탭 영역(pb.tabs)만 hit-test.
                    if (pb.label_cols > 0 and x_px < @as(f64, @floatFromInt(pb.tabs.x))) break;
                    const count = lr.leaf.terms.items.len;
                    const m = barMetrics(pb.tabs, self.cell_width_px, count, self.buildChromeTokens().space.tab_width_cols, lr.leaf.tab_scroll_cols) orelse break; // 메트릭 불가(초소형 바) → 호버 없음
                    if (m.inScrollLeftZone(x_px)) { // #5b: ‹ 버튼 호버 — 탭 호버 아님
                        next_scroll = .{ .pane = lr.leaf, .right = false };
                        break;
                    }
                    if (m.inScrollRightZone(x_px)) { // #5b: › 버튼 호버
                        next_scroll = .{ .pane = lr.leaf, .right = true };
                        break;
                    }
                    if (m.inPlusZone(x_px)) break; // "+" 버튼 위 — 탭 호버 아님(마지막 탭에 ✕ 오표시 방지)
                    next = .{ .pane = lr.leaf, .tab = m.tabIndex(count, x_px) };
                    break;
                }
            }
        } else |_| {}
        self.setHoveredTab(next);
        self.setHoveredScroll(next_scroll);
        return on_bar;
    }

    fn usizeOptEql(a: ?usize, b: ?usize) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return a.? == b.?;
    }

    /// 세로 사이드바 셀(탭 엔트리 밴드)을 다시 만든다 — 활성 탭 행에 하이라이트 밴드, 그리고 호버 슬롯이
    /// 활성과 다르면 그 행에 (더 약한) 호버 밴드를 emit한다. 탭 i는 행 i에 대응한다(한 탭=한 슬롯). 제목
    /// glyph는 여기서 안 만든다(tick의 제목 패스가 따로 더해 metal_buffer가 밴드와 머지). 사이드바가
    /// 꺼졌거나(폭 0) cell 폭 미상이면 비운다. 탭 추가/전환/메트릭/호버 변경 때 호출한다. 실패(OOM)는
    /// 세션을 죽이지 않고 빈 사이드바로 degrade한다(호출부가 catch).
    fn rebuildSidebar(self: *AppSession) !void {
        self.sidebar_cells.clearRetainingCapacity();
        self.gpu_quads.clearRetainingCapacity();
        self.recomputeVisibleTabs(); // 검색 필터로 표시 카드(sidebar_visible_tabs) 갱신 — 아래는 전부 표시 슬롯 기준
        if (self.tabs.items.len == 0) return;
        // 밴드(활성/호버 슬롯·"+" 호버)는 chrome `sidebar.view`가 fill op으로 단일 출처. `lowerSidebar`가 그 fill을
        // sidebarBandCell(행=슬롯)로 lower한다(색·NativeMetalCell은 platform). host가 중립 Tab(활성)을 주입(palette Row 선례).
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const tabs = self.sidebarTabs(arena) catch return;
        var ops: std.ArrayList(chrome.draw.Op) = .empty;
        chrome.components.sidebar.view(tabs, self.hovered_slot, self.buildChromeProps(), arena, &ops) catch return;
        self.lowerSidebar(ops.items);
        // 헤더(검색바) 하단 구분선 — 검색 줄과 카드 목록 사이 경계를 명확히(사용자 요청 "Searchbar에 언더바"). divider
        // 색·border 두께로 사이드바 폭 전체에 가로선(layer 0=사이드바 retained). 검색 줄 바로 아래(=header_h 하단)에 둔다.
        if (self.sidebar_width_px > 0 and self.sidebar_header_height_px > 0) {
            const tk = self.buildChromeTokens();
            const thickness: f32 = @floatFromInt(@max(@as(u32, 1), tk.border.line_thickness_px));
            const uy: f32 = @as(f32, @floatFromInt(self.sidebar_header_height_px)) - thickness;
            self.appendSolidQuad(0, uy, @floatFromInt(self.sidebar_width_px), thickness, self.dividerColor(), 0);
        }
        // per-tab 배경 tint(우클릭 메뉴 "배경: …") — background_color 설정된 워크스페이스 슬롯(밴드 없는 idle 슬롯)에
        // 반투명(≈40%) 색 quad를 텍스트 셀 아래(layer 0)에 얹는다. 활성/호버 슬롯은 위 lowerSidebar가 밴드 색에
        // tint를 블렌딩해 보이게 한다(tui 불투명 밴드가 이 quad를 덮으므로). chrome draw op은 role 기반이라 임의 RGB를
        // 못 실어, platform이 명시 색 GpuQuad로 직접 lower(사이드바 명시-색 경로). y는 f32 도메인으로 곱해 i32 overflow 회피.
        const slot_h = self.sidebar_slot_height_px;
        if (slot_h > 0 and self.sidebar_width_px > 0) for (self.sidebar_visible_tabs.items, 0..) |orig, i| {
            const tab = self.tabs.items[orig]; // 표시 슬롯 i → 원본 탭(검색 필터)
            if (tab.background_color == 0) continue;
            const c = premultipliedRgba(tab.background_color & 0x00FF_FFFF, tab_bg_tint_alpha);
            self.gpu_quads.append(self.allocator, .{
                .x = 0,
                .y = @as(f32, @floatFromInt(i)) * @as(f32, @floatFromInt(slot_h)) + @as(f32, @floatFromInt(self.sidebar_header_height_px)),
                .w = @floatFromInt(self.sidebar_width_px),
                .h = @floatFromInt(slot_h),
                .corner_radii = .{ 0, 0, 0, 0 },
                .border_widths = .{ 0, 0, 0, 0 },
                .fill_color0 = c,
                .fill_color1 = c,
                .border_color = 0,
                .gradient_kind = 0,
                .layer = 0,
            }) catch {};
        };
    }

    /// C4b 모달: self.gpu_quads에서 모달 배경 quad(layer==1)를 제거한다. sidebar 밴드(layer 0)는 retained
    /// (rebuildSidebar 관리)라 남기고, 모달 quad는 per-frame이라 renderFrame이 매 프레임 비운 뒤 build
    /// ChromeOverlayFrame이 다시 채운다 — 모달이 닫힌 프레임엔 안 채워져 유령 모달이 안 남는다(swapRemove,
    /// 순서 무관 — 렌더러가 layer로 재정렬). 리뷰가 지적한 sidebar/모달 clear-타이밍 충돌 해소.
    /// gpu_quads에서 주어진 layer의 quad를 모두 제거한다(per-frame 레이어 청소). 모달(layer 1)·탭 밴드(layer 2)는
    /// 매 프레임 재채워지므로 그 전에 비운다. 사이드바(layer 0)는 retained(rebuildSidebar 관리)라 대상이 아니다.
    fn dropQuadsByLayer(self: *AppSession, layer: u32) void {
        var i: usize = 0;
        while (i < self.gpu_quads.items.len) {
            if (self.gpu_quads.items[i].layer == layer) {
                _ = self.gpu_quads.swapRemove(i);
            } else {
                i += 1;
            }
        }
    }

    /// 활성 탭 강조(rich) — VSCode식: 평평한 약한 배경(직각·gradient 없음) + 하단 maru 앰버 언더바(active indicator,
    /// 탭 seg 폭). 사용자 요청으로 둥근 밴드·vertical gradient(C4b-5/U3)를 평평 VSCode 탭으로 대체. 배경·언더바 둘 다
    /// layer 2(셀 part1 제목 아래). segOf 픽셀 경계로 hit-test·제목 glyph와 정합(§6 단일 소스). overflow 탭이면 무동작.
    /// per-frame(dropQuadsByLayer(2)가 매 프레임 비움). tui는 tabbarHighlightCell 셀 밴드.
    fn appendActiveTabHighlight(self: *AppSession, m: chrome.components.tabbar.Metrics, tab_index: usize, bg: u32, accent: u32, underline_px: u32) void {
        const seg = m.segOf(tab_index);
        if (seg.end_col <= seg.start_col) return; // overflow(탭 영역 밖, 안 보이는) 탭
        const x: f32 = @floatCast(seg.start_px);
        const w: f32 = @floatCast(seg.end_px - seg.start_px);
        const by: f32 = @floatFromInt(m.bar_y);
        const bh: f32 = @floatFromInt(m.bar_h);
        const uw: f32 = @min(@as(f32, @floatFromInt(underline_px)), bh); // 바보다 두꺼우면 바 높이로 clamp — by+bh-uw≥by라 언더바가 바 위로 안 샌다(형제 appendTabBarUnderline의 -| 가드와 동형, #496 리뷰)
        self.appendSolidQuad(x, by, w, bh, bg, 2); // 평평한 약한 배경(VSCode 탭 — 둥근·gradient 없음)
        self.appendSolidQuad(x, by + bh - uw, w, uw, accent, 2); // 하단 maru 앰버 언더바(active indicator, 탭 폭)
    }

    /// #5a: 우측 가로 스크롤 ‹/› 버튼의 사각형 배경(GpuQuad layer 2) — col 셀(‹=tab_cols, ›=tab_cols+2) 영역을 약한
    /// 배경으로 채워 "클릭 가능한 버튼"으로 보이게 한다. glyph는 coretext가 같은 col에 그린다(배경 위). hover 색은 #5b, 커서는 #5c.
    fn appendScrollButtonQuad(self: *AppSession, m: chrome.components.tabbar.Metrics, col: u32, bg: u32) void {
        const x: f32 = @floatFromInt(m.bar_x + col * m.cell_width_px);
        self.appendSolidQuad(x, @floatFromInt(m.bar_y), @floatFromInt(m.cell_width_px), @floatFromInt(m.bar_h), bg, 2);
    }

    /// solid 직각 GpuQuad(곡률·테두리·gradient 없음)를 지정 layer에 append하는 공통 헬퍼 — appendBarBgQuad·
    /// appendTabBarUnderline이 공유해 같은 11필드 보일러플레이트 반복을 없앤다(GpuQuad는 extern struct라 필드
    /// default가 없어 필드 추가 시 모든 리터럴을 손봐야 하는데, solid 직각 quad는 이 헬퍼 한 곳으로 모은다). 둥근/
    /// 테두리/gradient quad는 따로 — 각자 모양 파라미터를 받아 일반화하지 않는다.
    fn appendSolidQuad(self: *AppSession, x: f32, y: f32, w: f32, h: f32, color: u32, layer: u32) void {
        self.gpu_quads.append(self.allocator, .{
            .x = x,
            .y = y,
            .w = w,
            .h = h,
            .corner_radii = .{ 0, 0, 0, 0 },
            .border_widths = .{ 0, 0, 0, 0 },
            .fill_color0 = color,
            .fill_color1 = color,
            .border_color = 0,
            .gradient_kind = 0,
            .layer = layer,
        }) catch {};
    }

    /// 스크롤바 thumb 기하(보이는 영역 내 y offset·높이, backing px) — 순수 함수라 단위 테스트 가능. sb_count==0
    /// (스크롤백 없음)·메트릭 0이면 null(안 그림). thumb 높이=보이는 비율(view/(sb+view)), 최소 높이로 clamp.
    /// y: view_offset 0(바닥)이면 view_h-thumb_h(아래), sb_count(꼭대기)면 0(위) — 위로 스크롤할수록 thumb가 올라간다.
    fn scrollbarThumbGeom(sb_count: usize, view_offset: usize, cell_height_px: u32, view_h_px: u32) ?struct { y: f32, h: f32 } {
        if (sb_count == 0 or cell_height_px == 0 or view_h_px == 0) return null;
        const ch: f32 = @floatFromInt(cell_height_px);
        const sb_px: f32 = @as(f32, @floatFromInt(sb_count)) * ch; // 스크롤백 총 높이(px)
        const view_px: f32 = @floatFromInt(view_h_px); // 보이는 높이
        const min_thumb: f32 = @max(view_px * 0.04, 18.0);
        var thumb_h: f32 = view_px * view_px / (sb_px + view_px);
        if (thumb_h < min_thumb) thumb_h = min_thumb;
        if (thumb_h > view_px) thumb_h = view_px;
        const t: f32 = if (sb_px > 0) @as(f32, @floatFromInt(view_offset)) * ch / sb_px else 0; // 0..1
        return .{ .y = (view_px - thumb_h) * (1.0 - t), .h = thumb_h };
    }

    /// 드래그 위치 t(0=트랙 바닥, 1=꼭대기)를 view_offset으로 매핑 — scrollbarThumbGeom의 `t = view_offset/sb_count`
    /// 역(逆). [0,1]로 clamp 후 round해 [0,sb_count] 정수 offset. 순수 함수라 단위 테스트 가능.
    fn scrollbarTargetOffset(t: f64, sb_count: usize) usize {
        var tt = t;
        if (tt < 0) tt = 0;
        if (tt > 1) tt = 1;
        return @intFromFloat(@round(tt * @as(f64, @floatFromInt(sb_count))));
    }

    /// 스크롤바 thumb 폭(px) — cell_width 비율, 최소 px 보장. emphasized(hover/드래그)면 +emphasize_px로 굵게.
    /// appendScrollbar(그리기)·scrollbarGrabAt(hit-test)가 공유해 폭이 어긋나지 않게 한다(순수 함수 — 테스트 가능).
    fn scrollbarBarWidthPx(cell_width_px: u32, emphasized: bool) f32 {
        const base = @max(@as(f32, @floatFromInt(cell_width_px)) * scrollbar_bar_mul, scrollbar_bar_min_px);
        return if (emphasized) base + scrollbar_bar_emphasize_px else base;
    }

    /// idle 틱에 따른 스크롤바 alpha(0xAARRGGBB의 A). visible_ticks까지 full, 이어 fade_ticks 동안 full→idle로
    /// 선형 감쇠, 이후 idle(faint) 유지(숨기지 않음). 순수 함수 — 테스트 가능. hover/드래그 override는 호출처에서.
    fn computeScrollbarAlpha(idle_ticks: u32) u8 {
        if (idle_ticks <= scrollbar_visible_ticks) return scrollbar_alpha_full;
        if (idle_ticks >= scrollbar_visible_ticks + scrollbar_fade_ticks) return scrollbar_alpha_idle;
        const into: u32 = idle_ticks - scrollbar_visible_ticks; // 1..fade_ticks-1
        const drop: u32 = @as(u32, scrollbar_alpha_full - scrollbar_alpha_idle) * into / scrollbar_fade_ticks;
        return @intCast(@as(u32, scrollbar_alpha_full) - drop);
    }

    /// 마우스가 스크롤바 영역에 있는지 갱신(hoverCursor가 매 이동 호출). 바뀌면 redraw 표시 — hover 강조가
    /// 곧바로 나타나거나 사라지게. fade 리셋(idle_ticks=0)은 updateScrollbarFade가 hover를 보고 한다.
    fn setScrollbarHovered(self: *AppSession, on: bool) void {
        if (self.scrollbar_hovered == on) return;
        self.scrollbar_hovered = on;
        self.metal_dirty = true;
    }

    /// 매 tick 스크롤바 fade를 갱신한다(updateCursorBlink와 같은 30Hz tick). 한 곳에서 활성 surface의 view_offset
    /// 변화를 감지해(스크롤·드래그·page-key·surface 전환) idle_ticks를 0(full)으로 리셋하고, hover/드래그면 full로
    /// 핀, 그 외엔 매 tick 늘려 fade 창에서 alpha가 바뀔 때만 metal_dirty를 세운다(idle 정착 후엔 정적 — 비용 0).
    fn updateScrollbarFade(self: *AppSession) void {
        if (!self.surface_initialized) return;
        // 활성 탭의 모든 pane을 순회해 각자 fade를 갱신한다(per-pane — pane 목록만 보면 되고 rect/layout 불요라
        // 매 tick 싸다). 활성 pane은 hover/드래그면 full로 핀. 한 pane이라도 alpha가 바뀌면 metal_dirty.
        const active_pane = self.activePane();
        for (self.activeTab().panes.items) |pane| {
            const psurface = &pane.activeTerm().surface;
            // scrollbackLen(리더 core.write가 증가)·viewOffset 스칼라를 락 아래 한 번에 읽는다
            // (docs/io-render-threading.md PR3). 비-const 메서드라 락 가능.
            psurface.lockCore(self.io);
            const sb_len = psurface.core.scrollbackLen();
            const vo = psurface.core.viewOffset();
            psurface.unlockCore(self.io);
            if (sb_len == 0) {
                // 스크롤바 없음 — 다음 등장이 full로 시작하게 타이머 리셋(0→nonzero 전환).
                pane.scrollbar_idle_ticks = 0;
                pane.scrollbar_last_view_offset = 0;
                continue;
            }
            if (vo != pane.scrollbar_last_view_offset) { // 이 pane 스크롤 활동 → full로 복귀
                pane.scrollbar_last_view_offset = vo;
                if (pane.scrollbar_idle_ticks != 0) self.metal_dirty = true;
                pane.scrollbar_idle_ticks = 0;
                continue;
            }
            if (pane == active_pane and (self.scrollbar_hovered or self.scrollbar_drag_grab != null)) { // 활성 pane 상호작용 — full 핀
                if (pane.scrollbar_idle_ticks != 0) {
                    pane.scrollbar_idle_ticks = 0;
                    self.metal_dirty = true;
                }
                continue;
            }
            if (pane.scrollbar_idle_ticks >= scrollbar_visible_ticks + scrollbar_fade_ticks) continue; // faint 정착 — 정적
            pane.scrollbar_idle_ticks += 1;
            if (pane.scrollbar_idle_ticks > scrollbar_visible_ticks) self.metal_dirty = true; // fade 창 — alpha 변함
        }
    }

    /// down 좌표가 활성 pane 스크롤바(thumb 또는 트랙)에 있으면 잡은 grab offset(y_px - thumb_top, px)을 돌려준다.
    /// thumb 위면 그 offset(드래그가 thumb 내 상대 위치를 유지), thumb 밖 트랙이면 thumb_h/2(클릭 지점에 thumb
    /// 중앙을 맞춰 점프). 스크롤백 없음·메트릭 0·영역 밖이면 null. x 영역은 thumb 폭 + 좌측 4px 여유(잡기 쉽게),
    /// y는 트랙(pane) 전체. appendScrollbar와 같은 bar_w(cell_width*0.32, 최소 5)·우측 2px 안쪽 배치를 쓴다.
    fn scrollbarGrabAt(self: *const AppSession, x_px: f64, y_px: f64) ?f32 {
        const rect = self.active_pane_rect;
        if (rect.w == 0 or self.cell_width_px == 0) return null;
        const core = &self.activeSurfaceConst().core;
        const geom = scrollbarThumbGeom(core.scrollbackLen(), core.viewOffset(), self.cell_height_px, rect.h) orelse return null;
        // thumb가 트랙을 꽉 채워 스크롤 여지가 없으면(track<=0, degenerate 작은 pane) 잡지 않는다 — 안 그러면
        // 클릭을 캡처하고도 dragScrollbarTo가 무동작이라 선택도 스크롤도 안 되는 dead zone이 된다.
        if (geom.h >= @as(f32, @floatFromInt(rect.h))) return null;
        // hit-test는 base 폭(비-emphasized) + 4px 여유 — hover로 굵어진 폭이 아니라 안정된 base로 잡는다.
        const bar_w: f64 = scrollbarBarWidthPx(self.cell_width_px, false);
        const right: f64 = @floatFromInt(rect.x + rect.w);
        const zone_left: f64 = right - bar_w - 2.0 - 4.0; // thumb 좌단(우측 2px 안쪽) - 4px grab 여유
        if (x_px < zone_left or x_px > right) return null;
        const top: f64 = @floatFromInt(rect.y);
        const bottom: f64 = top + @as(f64, @floatFromInt(rect.h));
        if (y_px < top or y_px > bottom) return null;
        const thumb_top: f64 = top + @as(f64, geom.y);
        const grab: f64 = y_px - thumb_top;
        if (grab >= 0 and grab <= @as(f64, geom.h)) return @floatCast(grab); // thumb 위 — 상대 위치 유지
        return geom.h * 0.5; // 트랙 — thumb 중앙을 클릭에 맞춤(점프)
    }

    /// 드래그/트랙-점프 중 마우스 y로 view_offset을 절대 설정한다. new_thumb_top(view 내) = (y_px - rect.y) - grab을
    /// [0, track]로 clamp(track = view_h - thumb_h), t = 1 - thumb_top/track(0=바닥, 1=꼭대기), target =
    /// scrollbarTargetOffset(t, sb_count). 현재 viewOffset과의 차이만큼 scrollViewport(절대 위치 → 상대 delta).
    fn dragScrollbarTo(self: *AppSession, y_px: f64) void {
        const grab: f64 = self.scrollbar_drag_grab orelse return;
        const rect = self.active_pane_rect;
        if (rect.h == 0 or self.cell_height_px == 0) return;
        // 코어 읽기(scrollbackLen·viewOffset)는 락 아래(§9.1). scrollViewport mutate는 **락 밖에서** reader에 위임
        // (full (a)) — 락을 잡은 채 enqueueCoreCommand하면 non-interactive 폴백이 같은 core_mutex를 재취득해 재진입
        // (panic/deadlock). 그래서 읽기만 락에 가두고, enqueue는 락 해제 후 한다(다른 위임 사이트와 같은 규율).
        const surface = self.activeSurface();
        const snap = blk: {
            surface.lockCore(self.io);
            defer surface.unlockCore(self.io);
            break :blk .{ .total_sb = surface.core.scrollbackLen(), .view_offset = surface.core.viewOffset() };
        };
        const total_sb = snap.total_sb;
        if (total_sb == 0) return;
        // thumb_h는 view_offset과 무관(sb_count·ch·view_h만) — 현재 offset으로 구해도 .h는 안정적.
        const geom = scrollbarThumbGeom(total_sb, snap.view_offset, self.cell_height_px, rect.h) orelse return;
        const view_px: f64 = @floatFromInt(rect.h);
        const track: f64 = view_px - @as(f64, geom.h); // thumb_top 가동 범위
        if (track <= 0) return; // thumb가 트랙을 꽉 채움 — 스크롤 여지 없음
        var thumb_top: f64 = (y_px - @as(f64, @floatFromInt(rect.y))) - grab;
        if (thumb_top < 0) thumb_top = 0;
        if (thumb_top > track) thumb_top = track;
        const t: f64 = 1.0 - thumb_top / track; // 0=바닥(offset 0), 1=꼭대기(offset sb_count)
        const target = scrollbarTargetOffset(t, total_sb);
        // 절대 목표를 reader에 위임(scroll_to_offset) — reader가 적용 시점의 fresh view_offset에서 delta 계산
        // (메인이 delta를 미리 빼면 연속 드래그가 옛 base로 double-count돼 어긋남).
        if (target != snap.view_offset) {
            self.runtime.enqueueCoreCommand(surface.id, .{ .scroll_to_offset = target }, self.io) catch {};
            self.metal_dirty = true;
        }
    }

    /// 활성 탭의 모든 pane 우측에 스크롤바를 그린다 — **각 pane이 자기 idle_ticks로 독립 fade**(per-pane), 활성
    /// pane만 추가로 hover/드래그 강조(세션 상태). 각 pane은 자기 core의 view_offset/scrollback을 반영. leaf rect는
    /// 재사용 scratch로 계산(per-frame 할당 churn 없음), 실패(OOM)면 활성 pane만(폴백). per-frame(layer3)에서 부른다.
    fn appendPaneScrollbars(self: *AppSession) void {
        if (!self.surface_initialized) return;
        self.scrollbar_leaf_scratch.clearRetainingCapacity();
        if (self.activeTabLeafRects(self.allocator, self.termRect(), &self.scrollbar_leaf_scratch)) |_| {
            const active_pane = self.activePane();
            for (self.scrollbar_leaf_scratch.items) |lr| {
                const trect = self.paneTermRect(lr.rect); // 상단 탭 바를 뺀 터미널 영역(active_pane_rect와 같은 식)
                self.appendScrollbar(trect, lr.leaf, lr.leaf == active_pane);
            }
        } else |_| {
            self.appendScrollbar(self.active_pane_rect, self.activePane(), true);
        }
    }

    /// 한 pane 우측에 스크롤바 thumb(둥근 GpuQuad)를 그린다 — 스크롤백이 있을 때만(sb_count>0). thumb 높이는
    /// 보이는 비율, 위치는 view_offset(0=바닥, sb_count=꼭대기)을 반영한다. 셀 위(layer 3 over)에 뜬다.
    /// alpha는 pane.scrollbar_idle_ticks로 fade(활성·비활성 모두 per-pane 독립). `is_active`면 추가로 hover/드래그
    /// 강조(굵게+full, 세션 상태) — 상호작용(hover/드래그)은 활성 pane만이라 비활성 pane은 fade만(emphasize 없음).
    /// 메모리 'UI는 Zig+GPU 렌더러로' — 네이티브 NSScroller가 아니라 chrome GpuQuad 프리미티브. 좌표는 backing 픽셀.
    fn appendScrollbar(self: *AppSession, rect: app.SplitRect, pane: *Pane, is_active: bool) void {
        if (rect.w == 0) return;
        const core = &pane.activeTerm().surface.core;
        const geom = scrollbarThumbGeom(core.scrollbackLen(), core.viewOffset(), self.cell_height_px, rect.h) orelse return;
        const thumb_y: f32 = @as(f32, @floatFromInt(rect.y)) + geom.y;
        const thumb_h: f32 = geom.h;
        // 활성 pane만 hover/드래그로 굵게+full(세션 상태). alpha는 **per-pane fade**(각 pane scrollbar_idle_ticks) —
        // 활성·비활성 모두 자기 스크롤 활동으로 독립적으로 흐려진다(비활성 pane을 휠로 스크롤하면 그 pane만 full→fade).
        const emphasized = is_active and (self.scrollbar_hovered or self.scrollbar_drag_grab != null);
        const bar_w: f32 = scrollbarBarWidthPx(self.cell_width_px, emphasized);
        const x: f32 = @as(f32, @floatFromInt(rect.x + rect.w)) - bar_w - 2.0; // 우측 가장자리에서 2px 안쪽
        const alpha: u8 = if (emphasized) scrollbar_alpha_full else computeScrollbarAlpha(pane.scrollbar_idle_ticks);
        const rgb = self.mutedForeground(); // muted 전경(사이드바 비활성 탭과 같은 톤)
        const color: u32 = packRgbAlpha(rgb, alpha); // 셰이더가 rgb*=a premultiply
        const r = bar_w * 0.5; // pill 모양(반지름 = 폭 절반)
        self.gpu_quads.append(self.allocator, .{
            .x = x,
            .y = thumb_y,
            .w = bar_w,
            .h = thumb_h,
            .corner_radii = .{ r, r, r, r },
            .border_widths = .{ 0, 0, 0, 0 },
            .fill_color0 = color,
            .fill_color1 = color,
            .border_color = 0,
            .gradient_kind = 0,
            .layer = 3, // over 패스(셀·사이드바 위) per-frame. layer 1(모달)이 gpu_quads에서 뒤에 append돼 위로 — 모달이 스크롤바를 가린다.
        }) catch {};
    }

    /// C4b-5: rich 탭 바 배경(직각)을 layer 2 GpuQuad로 그린다 — 활성 탭 밴드 quad(같은 layer, 뒤에 append되어 위로)가
    /// 불투명 셀 배경(paneBarBgCell)에 가리지 않게(리뷰 z-order #1, #451과 동형). tui는 셀. 둘 다 part1 제목 셀 아래(layer 2).
    fn appendBarBgQuad(self: *AppSession, bar: app.SplitRect, bg: u32) void {
        self.appendSolidQuad(@floatFromInt(bar.x), @floatFromInt(bar.y), @floatFromInt(bar.w), @floatFromInt(bar.h), bg, 2);
    }

    /// 탭바 하단 구분선(divider 색)을 layer 2 GpuQuad로 — 탭바를 터미널 콘텐츠와 시각 분리(rich). 활성 탭 영역은
    /// 활성 밴드(나중 append)가 위에 덮어 자연히 밴드 색이 되고, 비활성 영역엔 divider 구분선이 보인다.
    /// 두께는 `border.line_thickness_px` 토큰(rich 2px)을 받는다 — 1px GpuQuad는 SDF AA(maru_quad_fragment
    /// 78행 `cov=1-smoothstep(-aa,aa,d)`)가 1px-tall(half_size.y=0.5)에서 cov≈0.84로 옅게 그려 선이 흐리고
    /// HiDPI 분수 스케일에서 떨린다. 형제 선 헬퍼(appendHorizontalLine)가 셀+reserved ~2px를 쓰는 것과 같은
    /// 이유로 토큰 두께(≥2px)면 중심 행이 cov≈1로 선명하다. 두께만큼 바 하단 안쪽에 둔다(바 위로 안 새게).
    fn appendTabBarUnderline(self: *AppSession, bar: app.SplitRect, thickness: u32) void {
        self.appendSolidQuad(@floatFromInt(bar.x), @floatFromInt(bar.y + bar.h -| thickness), @floatFromInt(bar.w), @floatFromInt(thickness), self.dividerColor(), 2);
    }

    /// app `*Tab`에서 chrome 중립 `sidebar.Tab`(라벨·활성)을 빌드한다 — chrome은 app 트리를 모르므로 host가 떼어 준다
    /// (palette Row 선례). 라벨 = 활성 panel surface 제목(제목 glyph는 buildSidebarTitleFrame이 이 라벨로 그린다).
    fn sidebarTabs(self: *AppSession, arena: std.mem.Allocator) ![]chrome.components.sidebar.Tab {
        const out = try arena.alloc(chrome.components.sidebar.Tab, self.sidebar_visible_tabs.items.len);
        for (self.sidebar_visible_tabs.items, 0..) |orig, i| {
            const tab = self.tabs.items[orig]; // 표시 슬롯 i → 원본 탭(검색 필터)
            out[i] = .{ .label = workspaceLabel(tab), .active = (orig == self.app_window.active_tab) };
        }
        return out;
    }

    /// chrome `sidebar.view`가 낸 밴드 fill op을 sidebar 셀(NativeMetalCell)로 lower한다 — fill rect.y / slot_h = 슬롯 행,
    /// role(tab_active_bg/tab_hover_bg) → sidebarActiveBg/HoverBg. sidebarBandCell이 폭을 cell로 floor해 한 칸 밴드로.
    /// (옛 rebuildSidebar의 밴드 emit을 view 경로로 — 색 해석·NativeMetalCell은 platform 책임, divider lowerDividerRules와 동형.)
    fn lowerSidebar(self: *AppSession, ops: []const chrome.draw.Op) void {
        const slot_h = self.sidebar_slot_height_px;
        if (slot_h == 0) return;
        // gpu_quad(accent bar·rich 밴드)는 슬롯 상대 y를 절대 좌표로 박으므로 상단 헤더만큼 내려야 한다 — .m이
        // header_h 시프트하는 건 sidebar_cells(텍스트·tui 밴드)뿐이라 gpu_quad는 여기서 header_h를 더한다(위치 정합).
        const header_f: f32 = @floatFromInt(self.sidebar_header_height_px);
        for (ops) |op| switch (op) {
            .quad => |q| {
                if (q.fill_role == .accent_bar) {
                    // U1: 얇은 좌측 maru-accent 막대 — 셀 폭 floor를 피해 항상 GpuQuad(직각, layer 0=under). 색은 palette.accent_bar(앰버).
                    const ac = packOpaqueRgb(self.buildChromeTokens().palette.get(.accent_bar));
                    self.gpu_quads.append(self.allocator, .{
                        .x = @floatFromInt(q.rect.x),
                        .y = @as(f32, @floatFromInt(q.rect.y)) + header_f,
                        .w = @floatFromInt(q.rect.w),
                        .h = @floatFromInt(q.rect.h),
                        .corner_radii = .{ 0, 0, 0, 0 },
                        .border_widths = .{ 0, 0, 0, 0 },
                        .fill_color0 = ac,
                        .fill_color1 = ac,
                        .border_color = 0,
                        .gradient_kind = 0,
                        .layer = 0,
                    }) catch {};
                    continue;
                }
                var color = switch (q.fill_role) {
                    .tab_active_bg => self.sidebarActiveBg(),
                    else => self.sidebarHoverBg(),
                };
                // 이 슬롯 탭에 배경 tint가 있으면 밴드 색에 섞는다 — tui 활성/호버 슬롯은 불투명 밴드(셀)가 tint quad를
                // 덮으므로, 밴드 색 자체를 tint로 당겨 활성/호버 슬롯에서도 색이 보이게 한다(idle 슬롯은 밴드가 없어 quad가 그대로).
                const band_row_i = @divTrunc(q.rect.y, @as(i32, @intCast(slot_h)));
                if (band_row_i >= 0) {
                    const ri: usize = @intCast(band_row_i);
                    if (self.visibleTab(ri)) |orig| { // 표시 슬롯 ri → 원본(검색 필터)
                        if (self.tabs.items[orig].background_color != 0)
                            color = blendRgb(color, self.tabs.items[orig].background_color & 0x00FF_FFFF, tab_bg_tint_alpha);
                    }
                }
                const has_radius = q.corner_radii[0] != 0 or q.corner_radii[1] != 0 or q.corner_radii[2] != 0 or q.corner_radii[3] != 0;
                if (!has_radius) {
                    // tui: 직각 → 셀 밴드(기존 경로). rect.y/slot_h = 슬롯 행.
                    const row_i = @divTrunc(q.rect.y, @as(i32, @intCast(slot_h)));
                    if (row_i < 0) continue;
                    const row: u16 = @intCast(@min(@as(usize, @intCast(row_i)), @as(usize, std.math.maxInt(u16))));
                    if (sidebarBandCell(self.sidebar_width_px, self.cell_width_px, row, color)) |cell| {
                        self.sidebar_cells.append(self.allocator, cell) catch {};
                    }
                } else {
                    // rich: GPU quad 프리미티브(둥근 밴드) — 셀 그리드와 별개 파이프라인으로 렌더된다.
                    self.gpu_quads.append(self.allocator, .{
                        .x = @floatFromInt(q.rect.x),
                        .y = @as(f32, @floatFromInt(q.rect.y)) + header_f,
                        .w = @floatFromInt(q.rect.w),
                        .h = @floatFromInt(q.rect.h),
                        .corner_radii = .{ @floatFromInt(q.corner_radii[0]), @floatFromInt(q.corner_radii[1]), @floatFromInt(q.corner_radii[2]), @floatFromInt(q.corner_radii[3]) },
                        .border_widths = .{ 0, 0, 0, 0 },
                        .fill_color0 = color,
                        .fill_color1 = color,
                        .border_color = 0,
                        .gradient_kind = 0,
                        .layer = 0, // under — 사이드바 밴드(셀 위·제목 아래)
                    }) catch {};
                }
            },
            else => {},
        };
    }

    /// 사이드바 카드 4번째 줄(상태줄) 텍스트를 owned 슬라이스로 만든다. 에이전트 포그라운드가 아니면(none) "" —
    /// 그 줄은 생략된다. running이면 "● 진행중", idle이면 "✓ {답변 첫 줄}"(답변이 없으면 "✓ 완료"). 답변은 Term의
    /// inline 버퍼(이미 UTF-8 경계로 말줄임됨)에서 가져오고, 사이드바가 카드 폭으로 다시 말줄임한다.
    fn agentStatusLine(self: *AppSession, term: *Term) ![]const u8 {
        if (term.agent_kind == .none) return self.allocator.dupe(u8, "");
        return switch (term.agent_state) {
            .running => self.allocator.dupe(u8, "\u{25CF} 진행중"), // ● 진행중
            .idle => if (term.agent_answer_len > 0)
                std.fmt.allocPrint(self.allocator, "\u{2713} {s}", .{term.agent_answer_buf[0..term.agent_answer_len]}) // ✓ {답변}
            else
                self.allocator.dupe(u8, "\u{2713} 완료"), // ✓ 완료(답변 텍스트 없음)
            .unknown => self.allocator.dupe(u8, ""), // 트랜스크립트 못 읽음 — 상태줄 생략(아이콘만)
        };
    }

    /// 탭 제목들을 "{n} {title}" 라벨로 모아 사이드바 제목 glyph RenderFrame을 만든다(한 줄=한 탭,
    /// row=탭 인덱스). `build`(터미널)와 같은 CoreTextFrameBuilder/renderer_state(atlas)를 써서 제목
    /// glyph도 터미널과 같은 slot을 재사용하고 새 glyph만 추가 업로드된다. macOS 전용(실 CoreText
    /// 브리지) — tick의 `builtin.os.tag == .macos` 가드 안에서만 호출한다. 사이드바가 꺼졌거나(폭 0)
    /// 탭이 없으면 error.NoSidebar로 빠져 호출부가 제목 없이 밴드만 그린다.
    fn buildSidebarTitleFrame(self: *AppSession) !renderer.RenderFrame {
        const cw = self.cell_width_px;
        if (cw == 0 or self.tabs.items.len == 0) return error.NoSidebar;
        // U2/B2: 제목 영역 = 슬롯 폭에서 좌측(카드 패딩 + accent 막대)·우측(카드 패딩)을 inset한 content rect(선언적
        // 패딩, Rect.inset). 그 좌단을 셀 col로 ceil 환산(indent_cols)해 제목을 좌측 막대 우측·카드 안에 둔다(rich).
        // tui(0)면 left=right=0이라 전체 폭·indent 0(기존과 동일).
        const sp = self.buildChromeTokens().space;
        const row = chrome.draw.Rect{ .x = 0, .y = 0, .w = self.sidebar_width_px, .h = cw }; // h는 가로 환산에 무관
        const text_area = row.inset(.{ .left = sp.card_gap_px + sp.accent_bar_width_px, .right = sp.card_gap_px });
        const indent_px: u32 = @intCast(text_area.x);
        const indent_cols: u16 = if (indent_px > 0) @intCast(@min((indent_px + cw - 1) / cw, @as(u32, std.math.maxInt(u16)))) else 0;
        // B2 리뷰(e): indent_cols=ceil(left/cw)와 text_area.w/cw=floor의 합이 full_cols를 1 넘어 제목 우단이 터미널 영역을
        // 침범할 수 있어, sidebar_cols를 full_cols-indent_cols로도 clamp한다 → indent_cols+sidebar_cols <= full_cols 보장.
        const full_cols: u32 = self.sidebar_width_px / cw;
        const sidebar_cols: u16 = @intCast(@min(@min(text_area.w / cw, full_cols -| indent_cols), @as(u32, std.math.maxInt(u16))));
        if (sidebar_cols == 0) return error.NoSidebar;

        // 탭 카드를 소유 버퍼로 모은다(buildSidebarDrawList가 코드포인트로 디코드): names=이름줄(📌 포함, 번호 없음),
        // branch_lines=⎇ 브랜치줄, path_lines=경로줄, status_lines=상태줄(빈 보조줄은 생략 → 1~4줄). agents=에이전트
        // 아이콘 코드포인트(0=없음) — 이름과 분리해 슬롯 세로 중앙에 독립 배치(buildSidebarDrawList).
        var names: std.ArrayList([]const u8) = .empty;
        defer {
            for (names.items) |l| self.allocator.free(l);
            names.deinit(self.allocator);
        }
        var branch_lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (branch_lines.items) |l| self.allocator.free(l);
            branch_lines.deinit(self.allocator);
        }
        var path_lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (path_lines.items) |l| self.allocator.free(l);
            path_lines.deinit(self.allocator);
        }
        // 상태줄(4번째 줄): 에이전트 포그라운드일 때만 — running이면 "● 진행중", idle이면 "✓ {답변}"(완료 답변
        // 미리보기). none/unknown이면 ""(그 줄 생략). 아이콘 펄스와 함께 진행 상태를 보여준다(docs/agent-session.md).
        var status_lines: std.ArrayList([]const u8) = .empty;
        defer {
            for (status_lines.items) |l| self.allocator.free(l);
            status_lines.deinit(self.allocator);
        }
        var agents: std.ArrayList(u21) = .empty;
        defer agents.deinit(self.allocator);
        for (self.sidebar_visible_tabs.items) |orig| {
            const tab = self.tabs.items[orig]; // 표시 슬롯 순서 → 원본 탭(검색 필터)
            const term = tab.activePane().activeTerm();
            const renaming = self.renamingWorkspace(tab);
            // 에이전트 아이콘은 슬롯 중앙에 독립 배치. 단 rename 중엔 숨긴다(0) — 안 그러면 편집 텍스트가 icon_cols
            // 만큼 우측으로 밀려 renameCaretRect(아이콘 오프셋 미반영)의 caret/IME 후보창과 어긋난다.
            try agents.append(self.allocator, if (renaming) 0 else agentSymbolCodepoint(term.agent_kind));
            // 이름줄 = custom_name(rename) 우선, 없으면 활성 Term 라벨. rename 중이면 편집 텍스트로 대체하고 보조줄은 숨긴다.
            if (renaming) {
                try names.append(self.allocator, try self.renameEditText(self.allocator)); // owned → names가 소유
                try branch_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try path_lines.append(self.allocator, try self.allocator.dupe(u8, ""));
                try status_lines.append(self.allocator, try self.allocator.dupe(u8, "")); // rename 중엔 상태줄 숨김
            } else {
                const base = workspaceLabel(tab);
                const pin: []const u8 = if (tab.pinned) "\u{1F4CC} " else "";
                // 이름줄 = [📌] + 이름 (에이전트 심볼·번호 없음 — 심볼은 독립 아이콘으로 분리).
                try names.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{s}{s}", .{ pin, base }));
                // 브랜치줄·경로줄: cwd가 git repo 안일 때만(branch != null). 아니면 "" → 그 줄 생략.
                const branch = self.termGitBranch(term); // cwd 변경 시에만 .git/HEAD 재읽기(캐시)
                try branch_lines.append(self.allocator, if (branch) |b| try std.fmt.allocPrint(self.allocator, "\u{2387} {s}", .{b}) else try self.allocator.dupe(u8, ""));
                try path_lines.append(self.allocator, if (branch != null) try sidebarCwdPath(self.allocator, term) else try self.allocator.dupe(u8, ""));
                try status_lines.append(self.allocator, try self.agentStatusLine(term));
            }
        }

        // 비활성 워크스페이스 제목은 흐린 색(muted), 활성 워크스페이스(active_tab 행)는 full sidebar_foreground로 강조한다.
        const fg: terminal.Color = .{ .rgb = self.mutedForeground() };
        const active_fg: terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };
        // 호버 슬롯엔 닫기 ✕(없으면 null). plus_row = 탭 개수 → 목록 아래 행에 "+"(새 워크스페이스) 버튼.
        // plus_row=null — 하단 "+" 버튼은 헤더 우측 아이콘으로 이동·폐기(P2). 호버 슬롯엔 닫기 ✕(없으면 null).
        var draw_list = try coretext_frame_builder.buildSidebarDrawList(self.allocator, names.items, branch_lines.items, path_lines.items, status_lines.items, agents.items, sidebar_cols, fg, self.hovered_slot, null, self.displaySlotOf(self.app_window.active_tab), active_fg);
        // 에이전트 아이콘(✳ claude / ✻ codex)에 **상태색**을 입힌다 — 보편 관례(진행 중=amber, 완료=초록,
        // 불명=회색)로 사용자가 한눈에 진행 상태를 읽게 한다. 종류(claude/codex)는 심볼 모양으로 구분하므로
        // 색은 상태 전용으로 쓴다(브랜드 색에서 전환). 아이콘은 독립 셀(슬롯 중앙)이라 codepoint로 찾는다.
        // running이면 blink 위상으로 밝기를 낮춰 **펄스**(진행 중을 색+움직임 둘로 강조). docs/agent-session.md.
        for (draw_list.cells) |*c| {
            const is_agent_icon = c.codepoint == 0x2733 or c.codepoint == 0x273B; // ✳ claude / ✻ codex
            if (!is_agent_icon) continue;
            // 아이콘 셀 row에서 슬롯(탭) 인덱스를 디코드(row=slot*32+…)해 그 Term의 상태색을 고른다.
            const slot = c.row / coretext_frame_builder.sidebar_line_base; // 표시 슬롯
            const orig = self.visibleTab(slot) orelse continue; // 표시 슬롯 → 원본 탭(검색 필터)
            const t = self.tabs.items[orig].activePane().activeTerm();
            // 보편 관례 상태색: running=진행 중(amber), idle=완료(초록 — 거터 성공 #3FB950과 동일), unknown=불명(회색).
            const state_rgb: maru.color.Rgb = switch (t.agent_state) {
                .running => .{ .r = 0xE5, .g = 0xC0, .b = 0x7B }, // 진행 중 — amber
                .idle => .{ .r = 0x3F, .g = 0xB9, .b = 0x50 }, // 완료 — 초록
                .unknown => .{ .r = 0x80, .g = 0x80, .b = 0x80 }, // 불명 — 회색
            };
            // running이면 펄스(blink off 위상 어둡게) — 색에 더해 움직임으로도 진행 중을 알린다.
            c.style.foreground = .{ .rgb = if (t.agent_state == .running and !self.blink_visible) dimRgb(state_rgb) else state_rgb };
        }
        // U2/B2: 제목·✕·+ 셀을 content rect 좌단(indent_cols)만큼 우측으로 민다 — 좌측 maru-accent 막대 + 카드 패딩 안 가리게(rich만; tui indent=0 no-op).
        if (indent_cols > 0) {
            for (draw_list.cells) |*c| c.col += indent_cols;
            // 시프트로 셀이 [indent_cols, sidebar_cols+indent_cols)로 가므로 surface 폭도 full_cols로 넓힌다 — 안 그러면
            // 폭을 꽉 채운 긴 경로줄이 size.cols(=sidebar_cols)를 넘어 ShapedRecordOutsideSurface로 프레임이 통째로 실패
            // (짧은 이름은 안 걸리던 잠재 버그를 경로줄이 깨움). full_cols ≥ sidebar_cols+indent_cols라 항상 수용한다.
            draw_list.size.cols = @intCast(@min(full_cols, @as(u32, std.math.maxInt(u16))));
        }
        // buildFromDrawList가 draw_list 소유권을 가져간다(실패 시 정리, 성공 시 RenderFrame으로 이동).
        const frame_builder = coretext_frame_builder.CoreTextFrameBuilder{
            .appearance = self.appearance,
            .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
            .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
            .scale_milli = self.scale_milli,
            .cell_width_px = @intCast(self.cell_width_px),
            .cell_height_px = @intCast(self.cell_height_px),
        };
        return frame_builder.buildFromDrawList(self.allocator, draw_list, &self.renderer_state);
    }

    /// 사이드바 상단 헤더 glyph(검색 placeholder + view options ⚙·새 워크스페이스 + 아이콘) frame을 만든다.
    /// 카드(buildSidebarTitleFrame)와 달리 절대 좌표라 .m 헤더 시프트 대상이 아니다 — replace가 origin(0,0)
    /// 기반 cells로 헤더 영역 [0, header)에 직접 박는다(카드·밴드는 .m이 header_h만큼 아래로 시프트). 폭이 너무
    /// 좁거나 헤더 없으면 null(헤더 안 그림). 아이콘 우측 정렬(⚙=cols-4, +=cols-2)은 sidebar.headerHit과 같은
    /// 레이아웃 — 그려진 아이콘과 클릭 영역이 일치한다(§5.4 단일 레이아웃 소스). 검색 입력 텍스트·caret은 P3.
    fn buildSidebarHeaderFrame(self: *AppSession) !?renderer.RenderFrame {
        const cw = self.cell_width_px;
        if (cw == 0 or self.sidebar_header_height_px == 0 or self.tabs.items.len == 0) return null;
        const cols: u16 = @intCast(@min(self.sidebar_width_px / cw, @as(u32, std.math.maxInt(u16))));
        if (cols < 6) return null; // 검색 영역 + 우측 아이콘 2개(각 2칸)가 들어갈 최소 폭

        var cells: std.ArrayList(renderer.DrawCell) = .empty;
        errdefer cells.deinit(self.allocator);
        const muted: terminal.Color = .{ .rgb = self.mutedForeground() };
        const fg: terminal.Color = .{ .rgb = self.appearance.theme.sidebar_foreground };
        // 헤더 2줄: 줄0(신호등 줄)은 좌측 네이티브 신호등(닫기·최소화·확대) 영역을 비우고 우측에 view options(⚙)·
        // 새 워크스페이스(+) 아이콘. 검색은 신호등 아래 줄(search_row)에 🔍 + 입력/placeholder로 둔다(headerHit과
        // 같은 줄/우측 정렬 — view↔hitTest 단일 레이아웃). 줄 수는 header_h/cell_h로 산출(신호등 높이 흡수).
        const header_rows: u16 = @intCast(@max(@as(u32, 2), self.sidebar_header_height_px / @max(self.cell_height_px, 1)));
        const search_row: u16 = header_rows - 1; // 헤더 마지막 줄(신호등 아래)
        // 줄0: 우측 view options(⚙)·새 워크스페이스(+) 아이콘.
        try cells.append(self.allocator, .{ .row = 0, .col = cols - 4, .codepoint = 0x2699, .style = .{ .foreground = fg } });
        try cells.append(self.allocator, .{ .row = 0, .col = cols - 2, .codepoint = '+', .style = .{ .foreground = fg } });
        // 검색 줄: 🔍(EAW 2칸) + 입력 텍스트(query+preedit, EAW 한글 2칸), 비면 placeholder "Search"(muted).
        // 검색어는 blur(비활성)돼도 보존해 그대로 그린다 — 다시 클릭해 이어서 편집·필터(초안 보존). preedit은 활성일
        // 때만 존재. caret/IME 후보창은 sidebarSearchCaretRect가 잡는다(활성일 때만).
        try cells.append(self.allocator, .{ .row = search_row, .col = 0, .codepoint = 0x1F50D, .width = 2, .style = .{ .foreground = muted } });
        const max_col = cols -| 4; // 우측 아이콘 영역 침범 방지
        if (self.sidebar_search_input.query.items.len > 0 or self.sidebar_search_input.preedit.items.len > 0) {
            var col: u16 = 3;
            const texts = [_][]const u8{ self.sidebar_search_input.query.items, self.sidebar_search_input.preedit.items };
            for (texts) |text| {
                var view = std.unicode.Utf8View.init(text) catch continue;
                var iter = view.iterator();
                while (iter.nextCodepoint()) |cp| {
                    if (col >= max_col) break;
                    const w: u2 = @intCast(@max(@as(u8, 1), @min(@as(u8, 2), terminal.width.cellWidth(cp))));
                    try cells.append(self.allocator, .{ .row = search_row, .col = col, .codepoint = cp, .width = w, .style = .{ .foreground = fg } });
                    col += w;
                }
            }
        } else {
            const placeholder = "Search";
            for (placeholder, 0..) |ch, i| {
                const col: u16 = @intCast(3 + i);
                if (col >= max_col) break;
                try cells.append(self.allocator, .{ .row = search_row, .col = col, .codepoint = ch, .style = .{ .foreground = muted } });
            }
        }

        const draw_list = renderer.DrawList{
            .size = .{ .cols = cols, .rows = header_rows },
            .cursor = .{ .row = 0, .col = 0 },
            .dirty = null,
            .cells = try cells.toOwnedSlice(self.allocator),
            .overlays = try self.allocator.alloc(renderer.DrawOverlay, 0),
        };
        const frame_builder = coretext_frame_builder.CoreTextFrameBuilder{
            .appearance = self.appearance,
            .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
            .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
            .scale_milli = self.scale_milli,
            .cell_width_px = @intCast(self.cell_width_px),
            .cell_height_px = @intCast(self.cell_height_px),
        };
        return try frame_builder.buildFromDrawList(self.allocator, draw_list, &self.renderer_state);
    }

    /// 오버레이(커맨드 팝업·Find·Notice) frame의 공통 마무리. 채워진 cells(소유권 인계) + 격자 크기(cols×rows) +
    /// backing-px origin을 받아 DrawList → CoreTextFrameBuilder → PaneFrame으로 굳힌다. 세 빌더가 같은 frame 계약
    /// (DrawList 리터럴·frame_builder 6필드·PaneFrame 반환)을 복제하던 boilerplate를 단일화한다 — frame 계약이
    /// 바뀌면 여기 한 곳만 고친다. cells는 toOwnedSlice로 가져가고, 실패 시 호출자 errdefer가 정리한다(아직 유효).
    fn finishOverlayFrame(
        self: *AppSession,
        cells: *std.ArrayList(renderer.DrawCell),
        cols: u16,
        rows: u16,
        origin_x: u32,
        origin_y: u32,
        appearance: config_mod.ResolvedAppearance,
        cell_w: u32,
        cell_h: u32,
        cursor: ?terminal.Cursor,
    ) !metal_frame.PaneFrame {
        // caret(cursor-role fill에서 lower)이 있으면 **cursor 오버레이**(DrawOverlay.cursor)로 낸다 — buildNativeCellsSplit이
        // frame.overlays에서 .cursor를 찾아 반전-블록으로 그리고(메인 터미널 커서와 같은 경로) suffix-trim으로 깜빡인다.
        // draw_list.cursor 필드만으론 안 그려진다(렌더는 overlays를 본다 — 메인 buildDrawList도 cursor를 overlays에 넣는다).
        const overlays: []renderer.DrawOverlay = if (cursor) |cur| blk: {
            const o = try self.allocator.alloc(renderer.DrawOverlay, 1);
            o[0] = .{ .cursor = .{ .row = cur.row, .col = cur.col, .visible = true, .shape = .block } };
            break :blk o;
        } else try self.allocator.alloc(renderer.DrawOverlay, 0);
        // draw_list 완성 전(toOwnedSlice OOM 등)에 실패하면 overlays를 직접 해제한다. 완성되면 draw_list가
        // overlays·cells를 소유하므로 **disarm**한다 — 안 그러면 buildFromDrawList의 실패 정리(owned_list.deinit가
        // overlays까지 free)와 겹쳐 **이중 해제**된다(coretext_frame_builder의 draw_list_owned 패턴과 동형).
        var overlays_owned = true;
        errdefer if (overlays_owned) self.allocator.free(overlays);
        const draw_list: renderer.DrawList = .{
            .size = .{ .cols = cols, .rows = rows },
            .cursor = cursor orelse .{ .row = 0, .col = 0, .visible = false },
            .dirty = .{ .start_row = 0, .end_row = if (rows == 0) 0 else rows - 1 },
            .cells = try cells.toOwnedSlice(self.allocator),
            .overlays = overlays,
        };
        overlays_owned = false; // 소유권이 draw_list로 — 이후 실패는 buildFromDrawList가 draw_list.deinit로 정리
        // appearance·cell_w/h를 호출자가 준다 — 오버레이는 터미널과 같은 셀·폰트(1×)를 쓴다(buildChromeOverlayFrame가
        // self.cell_width_px·self.appearance를 넘김). 글리프 픽셀(font.size×scale)과 atlas slot(cell)이 같은 메트릭에서
        // 나와 정확히 맞는다 — 1.3× 확대 시절의 스케일 불일치(글자 약간 잘림)가 없다.
        const frame_builder = coretext_frame_builder.CoreTextFrameBuilder{
            .appearance = appearance,
            .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
            .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
            .scale_milli = self.scale_milli,
            .cell_width_px = @intCast(cell_w),
            .cell_height_px = @intCast(cell_h),
        };
        const frame = try frame_builder.buildFromDrawList(self.allocator, draw_list, &self.renderer_state);
        // caret이 있으면 cursor 색을 싣는다 — 컴포지터(metal_frame)가 colors.cursor가 있을 때만 반전 블록을 그린다.
        // block=theme.cursor(caret 색), text=패널 bg(caret 아래 글자가 있으면 가독 — 입력 끝 빈칸이라 보통 무관).
        const cursor_colors: ?metal_frame.CursorColors = if (cursor != null) .{
            .block = self.appearance.theme.cursor,
            .text = self.appearance.theme.sidebar_background,
        } else null;
        return .{ .frame = frame, .origin_x = origin_x, .origin_y = origin_y, .colors = .{ .default_fg = self.appearance.theme.foreground, .cursor = cursor_colors } };
    }

    // 커맨드 팝업·스크롤백 Find 오버레이는 chrome 컴포넌트로 이주했다(palette=C1b, find=C1a). 각 컴포넌트 view가
    // ChromeDraw를 내고 buildChromeOverlayFrame이 일반 rasterizer(placeText, EAW-폭)로 lower한다 — buildPaletteFrame/
    // buildFindFrame은 제거. 팝업은 IME 조합 표시·한글 2칸 폭을 find와 같은 경로로 공짜로 얻는다. 오버레이는 터미널과
    // 같은 셀 크기(1×)로 그린다 — 1.3× 확대는 사용자 요청으로 제거(스케일 불일치로 글자가 약간 잘리던 문제도 함께 사라짐).

    /// chrome 컴포넌트가 읽는 불변 메트릭(props seam). 매 frame 세션 실측값에서 빌드한다 — chrome은 terminal/
    /// config 타입을 모르므로 plain u32만 넘긴다. 오버레이는 터미널과 같은 셀(self.cell_width_px — CoreText 실측)을
    /// 쓴다. sidebar/backing은 실 px 그대로. sidebar_width_px는 런타임 가변(드래그)이라 토큰이 아닌 여기로.
    fn buildChromeProps(self: *const AppSession) chrome.ChromeProps {
        const tk = self.buildChromeTokens();
        return .{
            .metrics = .{
                .cell_width_px = self.cell_width_px,
                .cell_height_px = self.cell_height_px,
                .sidebar_width_px = self.sidebar_width_px,
                .sidebar_slot_height_px = self.sidebar_slot_height_px,
                .backing_width_px = self.backing_width_px,
                .backing_height_px = self.backing_height_px,
                .chrome_minimal = self.chrome_minimal,
            },
            // C4b: 박스 모양 토큰을 tokens.space에서(단일 출처). tui=0(직각·셀 밴드), rich>0(둥근 GPU quad).
            .shape = .{ .corner_radius_px = tk.space.corner_radius_px, .border_width_px = tk.space.border_width_px, .modal_padding_px = tk.space.modal_padding_px, .accent_bar_width_px = tk.space.accent_bar_width_px, .card_gap_px = tk.space.card_gap_px },
            // 활성 pane rect(셀 그리드 영역) — find 오버레이가 활성 pane 우상단에 붙도록(findLayout 단일 출처).
            // palette는 안 쓴다(창 중앙 유지). active_pane_rect는 recomputeActivePaneRect가 포커스·resize마다 갱신.
            .active_pane = .{ .x = self.active_pane_rect.x, .y = self.active_pane_rect.y, .w = self.active_pane_rect.w, .h = self.active_pane_rect.h },
        };
    }

    /// ResolvedTheme(config) → chrome 토큰. chrome은 ResolvedTheme를 import하지 않으므로(경계) 여기서 resolved
    /// Rgb만 뽑아 넘기고, **역할→색 매핑은 chrome.tokens.Tokens.tui가 단일 출처로 소유**한다(2nd 백엔드·rich도
    /// 같은 매핑 재사용). 이 함수는 ResolvedTheme→ThemeColors 투영(필드 추림)만 한다.
    fn buildChromeTokens(self: *const AppSession) chrome.Tokens {
        const t = self.appearance.theme;
        const tc = chrome.tokens.ThemeColors{
            .foreground = t.foreground,
            .sidebar_background = t.sidebar_background,
            .sidebar_foreground = t.sidebar_foreground,
            .sidebar_active = t.sidebar_active,
            .search_match = t.search_match,
            .search_match_current = t.search_match_current,
            .selection = t.selection,
            .cursor = t.cursor,
        };
        // chrome theme = 토큰셋 교체(컴포넌트 불변). rich는 sidebar_active-공유 role(divider/focus_accent 등)을 분리 색으로(C4a).
        return switch (self.appearance.chrome_theme) {
            .tui => chrome.tokens.Tokens.tui(tc),
            .rich => chrome.tokens.Tokens.rich(tc),
        };
    }

    /// 일반 오버레이 lowering: chrome 컴포넌트가 낸 ChromeDraw ops(fill/border/text)를 셀 그리드로 rasterize한다
    /// (painter order). bounding box = 모든 fill/border rect 합집합(패널 외곽), origin = 그 좌상단(backing px 절대).
    /// 각 셀 bg = 그 셀을 덮는 마지막 fill의 role 색(+켜진 변이면 border 색), codepoint·fg = text op이 origin부터
    /// 놓은 글리프. notice(박스 1개)·find(1행 다중 텍스트)·palette(N행 리스트)가 같은 lowering을 공유한다 —
    /// buildNoticeFrame의 "첫 fill+text" 특수형을 일반화(C1). rule op은 컴포넌트가 아직 안 내므로 무시한다.
    /// **순수**(CoreText 무관) — 셀·격자만 산출해 단위 테스트로 고정한다. 빈 box/0칸이면 에러(호출자가 무시).
    /// 반환된 cells는 allocator 소유(호출자가 finishOverlayFrame에 넘겨 frame으로 이전하거나 실패 시 deinit).
    const OverlayRaster = struct {
        cells: std.ArrayList(renderer.DrawCell),
        // C4b 모달: rich 모달 배경 quad(둥근+테두리). buildChromeOverlayFrame이 self.gpu_quads(layer=1 over)에
        // 머지한다. tui(radius=0)면 빈 — 배경은 셀 fill(paintRectBg)로 기존 경로.
        gpu_quads: std.ArrayList(metal_frame.GpuQuad),
        gpu_shadows: std.ArrayList(metal_frame.GpuShadow),
        cols: u16,
        rows: u16,
        origin_x: u32,
        origin_y: u32,
        // cursor-role fill을 PaneFrame.cursor(반전 블록)로 lower한 caret 위치(없으면 null). finishOverlayFrame이
        // draw_list.cursor·colors.cursor에 싣고, 컴포지터가 터미널 커서와 같은 경로로 그리고 suffix-trim으로 깜빡인다.
        cursor: ?terminal.Cursor = null,
    };

    fn rasterizeOverlayCells(
        allocator: std.mem.Allocator,
        draws: []const chrome.ChromeDraw,
        tk: *const chrome.Tokens,
        cw: u32,
        ch: u32,
    ) !OverlayRaster {
        if (cw == 0 or ch == 0) return error.NoMetrics;
        // C4b 모달: rich 모달 배경 quad 수집(painter의 .quad가 radius>0면 append). buildChromeOverlayFrame이
        // self.gpu_quads(layer=1 over)에 머지한다. tui(radius=0)면 비어 셀 fill 경로(무변화).
        var gpu_quads: std.ArrayList(metal_frame.GpuQuad) = .empty;
        errdefer gpu_quads.deinit(allocator);
        var gpu_shadows: std.ArrayList(metal_frame.GpuShadow) = .empty;
        errdefer gpu_shadows.deinit(allocator);
        // C4b 모달: rich 배경 quad(아래 painter .quad)가 있으면 true. 그땐 빈 셀(공백)을 평탄화에서 skip해
        // 불투명 surface_bg 셀이 둥근 quad를 사각으로 덮지 않게 한다(리뷰 #1 — quad가 비치게).
        var modal_bg_quad = false;
        // 1) bounding box = fill/border rect 합집합(backing px). text origin은 box 안이라 박스 산정에 안 쓴다.
        var min_x: i32 = std.math.maxInt(i32);
        var min_y: i32 = std.math.maxInt(i32);
        var max_x: i32 = std.math.minInt(i32);
        var max_y: i32 = std.math.minInt(i32);
        var have_box = false;
        for (draws) |d| for (d.ops) |op| {
            const rect: ?chrome.draw.Rect = switch (op) {
                .fill => |f| f.rect,
                .border => |b| b.rect,
                .quad => |q| q.rect, // C4b 모달: 박스가 모달 배경 quad를 포함해야 셀 그리드가 그 위 텍스트를 담는다
                else => null,
            };
            if (rect) |rr| {
                have_box = true;
                min_x = @min(min_x, rr.x);
                min_y = @min(min_y, rr.y);
                max_x = @max(max_x, rr.x + @as(i32, @intCast(rr.w)));
                max_y = @max(max_y, rr.y + @as(i32, @intCast(rr.h)));
            }
        };
        if (!have_box) return error.NoBox;
        const origin_x: u32 = if (min_x < 0) 0 else @intCast(min_x);
        const origin_y: u32 = if (min_y < 0) 0 else @intCast(min_y);
        const cols_u = @as(u32, @intCast(@max(max_x - min_x, 0))) / cw;
        const rows_u = @as(u32, @intCast(@max(max_y - min_y, 0))) / ch;
        if (cols_u == 0 or rows_u == 0) return error.TooSmall;
        const cols: u16 = @intCast(@min(cols_u, @as(u32, std.math.maxInt(u16))));
        const rows: u16 = @intCast(@min(rows_u, @as(u32, std.math.maxInt(u16))));

        // 2) bg/fg/cp 스크래치 그리드. 기본 bg=surface_bg·fg=surface_fg·cp=공백(패널 fill이 곧 덮는다).
        const n = @as(usize, cols) * @as(usize, rows);
        const bg = try allocator.alloc(terminal.Color, n);
        defer allocator.free(bg);
        const fg = try allocator.alloc(terminal.Color, n);
        defer allocator.free(fg);
        const cp = try allocator.alloc(u21, n);
        defer allocator.free(cp);
        const cwid = try allocator.alloc(u2, n); // 셀별 표시폭(EAW): wide 문자(한글/CJK)=2, 나머지=1
        defer allocator.free(cwid);
        const surface_bg_col = terminal.Color{ .rgb = tk.get(.surface_bg) };
        @memset(bg, surface_bg_col);
        @memset(fg, terminal.Color{ .rgb = tk.get(.surface_fg) });
        @memset(cp, ' ');
        @memset(cwid, 1);

        // 3) painter order로 ops 적용. 좌표는 origin 기준 셀로 환산(음수/범위 밖은 clamp/skip).
        // cursor role fill은 bg로 안 칠하고 caret 셀로 기록한다 — finishOverlayFrame이 PaneFrame.cursor로 lower해
        // 터미널 커서와 같은 반전-블록 렌더·suffix-trim 깜빡임을 재활용한다(컴포넌트는 깜빡임 위상을 모른다).
        var cursor: ?terminal.Cursor = null;
        for (draws) |d| for (d.ops) |op| switch (op) {
            .fill => |f| {
                if (f.role == .cursor) {
                    const col_i = @divTrunc(f.rect.x - @as(i32, @intCast(origin_x)), @as(i32, @intCast(cw)));
                    const row_i = @divTrunc(f.rect.y - @as(i32, @intCast(origin_y)), @as(i32, @intCast(ch)));
                    if (col_i >= 0 and col_i < cols and row_i >= 0 and row_i < rows) {
                        cursor = .{ .row = @intCast(row_i), .col = @intCast(col_i), .visible = true };
                    }
                } else {
                    paintRectBg(bg, cols, rows, origin_x, origin_y, cw, ch, f.rect, .{ .rgb = tk.get(f.role) }, null);
                }
            },
            .border => |b| {
                // C4b 모달: rich(quad 배경 — modal_bg_quad)면 테두리는 quad의 border_widths가 둥글게 그린다.
                // 셀 직각 테두리를 skip해 둥근 quad에 직각 테두리가 겹치지 않게 한다(리뷰 — notice 테두리 정합).
                if (!modal_bg_quad) paintRectBg(bg, cols, rows, origin_x, origin_y, cw, ch, b.rect, .{ .rgb = tk.get(b.role) }, b.sides);
            },
            .text => |t| placeText(cp, fg, cwid, cols, rows, origin_x, origin_y, cw, ch, t, .{ .rgb = tk.get(t.role) }),
            .rule => {}, // 컴포넌트가 아직 안 냄 — 필요해질 때(C2 divider) 셀 라인으로 lower
            .quad => |q| {
                const has_radius = q.corner_radii[0] != 0 or q.corner_radii[1] != 0 or q.corner_radii[2] != 0 or q.corner_radii[3] != 0;
                if (!has_radius) {
                    // tui: 직각 → 셀 배경(기존 fill 경로와 동일).
                    paintRectBg(bg, cols, rows, origin_x, origin_y, cw, ch, q.rect, .{ .rgb = tk.get(q.fill_role) }, null);
                } else {
                    // rich: GPU quad(layer=1 over — 모달 배경, 둥근+테두리). 색 0xAARRGGBB 불투명.
                    // C4b 모달 패딩: 배경 quad/shadow를 텍스트 영역(q.rect)보다 사방 pad만큼 확장한다 — 텍스트 셀은
                    // q.rect 그대로라 텍스트가 박스 안쪽으로 들어가 여백이 생긴다(tui=0이면 확장 0 = 기존과 동일).
                    // C4b 모달 패딩: 배경 박스를 텍스트 영역(q.rect)보다 사방 modal_padding_px만큼 키운다(Rect.outset —
                    // inset의 대칭, 선언적 역패딩). quad·shadow가 같은 box를 공유한다(좌우 중복 산술 제거). tui=0이면 outset 0 = q.rect.
                    const mp = tk.space.modal_padding_px;
                    const box = q.rect.outset(.{ .left = mp, .right = mp, .top = mp, .bottom = mp });
                    const bx: f32 = @floatFromInt(box.x);
                    const by: f32 = @floatFromInt(box.y);
                    const bw: f32 = @floatFromInt(box.w);
                    const bh: f32 = @floatFromInt(box.h);
                    const fr = tk.get(q.fill_role);
                    const fill: u32 = 0xFF000000 | (@as(u32, fr.r) << 16) | (@as(u32, fr.g) << 8) | @as(u32, fr.b);
                    var border: u32 = 0;
                    if (q.border_role) |brole| {
                        const bc = tk.get(brole);
                        border = 0xFF000000 | (@as(u32, bc.r) << 16) | (@as(u32, bc.g) << 8) | @as(u32, bc.b);
                    }
                    gpu_quads.append(allocator, .{
                        .x = bx,
                        .y = by,
                        .w = bw,
                        .h = bh,
                        .corner_radii = .{ @floatFromInt(q.corner_radii[0]), @floatFromInt(q.corner_radii[1]), @floatFromInt(q.corner_radii[2]), @floatFromInt(q.corner_radii[3]) },
                        .border_widths = .{ @floatFromInt(q.border_widths[0]), @floatFromInt(q.border_widths[1]), @floatFromInt(q.border_widths[2]), @floatFromInt(q.border_widths[3]) },
                        .fill_color0 = fill,
                        .fill_color1 = fill,
                        .border_color = border,
                        .gradient_kind = 0,
                        .layer = 1,
                    }) catch {};
                    modal_bg_quad = true;
                    // C4b 모달: 배경 quad에 그림자 동반(gpu_shadows 별 배열, quad·셀보다 아래). 같은 box + 약간 아래 offset + blur.
                    gpu_shadows.append(allocator, .{
                        .x = bx,
                        .y = by + @as(f32, @floatFromInt(tk.space.shadow_offset_y_px)),
                        .w = bw,
                        .h = bh,
                        .corner_radii = .{ @floatFromInt(q.corner_radii[0]), @floatFromInt(q.corner_radii[1]), @floatFromInt(q.corner_radii[2]), @floatFromInt(q.corner_radii[3]) },
                        .blur_radius = @floatFromInt(tk.space.shadow_blur_px),
                        .color = @as(u32, tk.space.shadow_alpha) << 24, // 토큰 alpha + RGB 0(검정). tui=0이면 무관(append 안 됨)
                    }) catch {};
                }
            },
        };

        // 4) 그리드를 DrawCell 배열로 평탄화(allocator 소유). wide 문자(한글/CJK)면 width=2 — frame builder가 그 폭으로
        // 글리프를 그린다. **wide 셀의 continuation 칸(c+1)은 emit하지 않는다** — emit하면 그 칸의 배경 quad가 합성 때
        // wide 글리프의 오른쪽 절반을 surface_bg로 덮어 잘려 보였다(터미널도 cell.continuation을 같은 이유로 스킵한다).
        // wide 셀의 2칸 배경이 그 칸을 덮으므로 패널 bg는 유지된다.
        var cells: std.ArrayList(renderer.DrawCell) = .empty;
        errdefer cells.deinit(allocator);
        try cells.ensureTotalCapacity(allocator, n);
        var r: u16 = 0;
        while (r < rows) : (r += 1) {
            var c: u16 = 0;
            while (c < cols) {
                const idx = @as(usize, r) * @as(usize, cols) + c;
                const w = cwid[idx];
                // C4b 모달: rich 모달은 배경이 GPU quad(layer=1)라, 빈 셀(공백)의 불투명 surface_bg가 둥근
                // quad를 사각으로 덮는다(리뷰 #1) — 빈 셀은 skip해 quad가 비치게 한다(글자 칸만 emit).
                // C4b 모달: 빈 셀 skip은 **기본 배경(surface_bg)인 빈 칸만** — 선택 행 강조(tab_active_bg) 등
                // 다른 배경의 빈 칸은 emit해야 그 칸도 하이라이트된다(빈 칸까지 skip하면 글자만 강조돼 보였던 버그).
                if (modal_bg_quad and cp[idx] == ' ' and std.meta.eql(bg[idx], surface_bg_col)) {
                    c += if (w == 2) @as(u16, 2) else 1;
                    continue;
                }
                cells.appendAssumeCapacity(.{ .row = r, .col = c, .codepoint = cp[idx], .width = w, .style = .{ .foreground = fg[idx], .background = bg[idx] } });
                c += if (w == 2) @as(u16, 2) else 1; // wide면 continuation 칸 스킵
            }
        }
        return .{ .cells = cells, .cols = cols, .rows = rows, .origin_x = origin_x, .origin_y = origin_y, .cursor = cursor, .gpu_quads = gpu_quads, .gpu_shadows = gpu_shadows };
    }

    /// rect(backing px)를 origin 기준 셀 span으로 환산해 bg를 칠한다. sides==null이면 채움(fill), 아니면 켜진 변의
    /// 가장자리 셀만(border). 범위 밖은 clamp. rasterizeOverlayCells 전용 헬퍼.
    fn paintRectBg(bg: []terminal.Color, cols: u16, rows: u16, origin_x: u32, origin_y: u32, cw: u32, ch: u32, rect: chrome.draw.Rect, color: terminal.Color, sides: ?chrome.draw.Sides) void {
        const ox: i32 = @intCast(origin_x);
        const oy: i32 = @intCast(origin_y);
        const c0 = std.math.clamp(@divTrunc(rect.x - ox, @as(i32, @intCast(cw))), 0, @as(i32, cols));
        const r0 = std.math.clamp(@divTrunc(rect.y - oy, @as(i32, @intCast(ch))), 0, @as(i32, rows));
        const c1 = std.math.clamp(@divTrunc(rect.x + @as(i32, @intCast(rect.w)) - ox, @as(i32, @intCast(cw))), 0, @as(i32, cols));
        const r1 = std.math.clamp(@divTrunc(rect.y + @as(i32, @intCast(rect.h)) - oy, @as(i32, @intCast(ch))), 0, @as(i32, rows));
        var r: i32 = r0;
        while (r < r1) : (r += 1) {
            var c: i32 = c0;
            while (c < c1) : (c += 1) {
                const on_edge = if (sides) |s|
                    (s.top and r == r0) or (s.bottom and r == r1 - 1) or (s.left and c == c0) or (s.right and c == c1 - 1)
                else
                    true; // fill = 모든 셀
                if (on_edge) bg[@as(usize, @intCast(r)) * @as(usize, cols) + @as(usize, @intCast(c))] = color;
            }
        }
    }

    /// text op의 runs를 origin 셀부터 가로로 놓는다(EAW 폭만큼 전진, 범위 밖 skip). cp·fg·cwid 그리드에 쓴다.
    /// 표시 폭은 EAW(terminal.width.cellWidth)로 — 한글/CJK는 2칸을 전진하며 시작 칸의 DrawCell.width=2로
    /// 표시한다(coretext_frame_builder line 121/158과 같은 `@max(1, cellWidth)` 캐논 패턴). 그래야 wide 글리프가
    /// 2칸 폭으로 그려지고 다음 글자가 겹치지 않는다(한글이 잘려 보이던 회귀의 루트커즈). continuation 칸은 빈칸
    /// (codepoint ' ')으로 남고, 평탄화(위 4단계)가 그 칸을 emit하지 않는다(배경 quad가 wide 글리프를 덮지 않게).
    /// rasterizeOverlayCells 전용.
    fn placeText(cp: []u21, fg: []terminal.Color, cwid: []u2, cols: u16, rows: u16, origin_x: u32, origin_y: u32, cw: u32, ch: u32, t: chrome.draw.Op.Text, color: terminal.Color) void {
        const row_i = @divTrunc(t.origin.y - @as(i32, @intCast(origin_y)), @as(i32, @intCast(ch)));
        if (row_i < 0 or row_i >= rows) return;
        const row: usize = @intCast(row_i);
        var col_i = @divTrunc(t.origin.x - @as(i32, @intCast(origin_x)), @as(i32, @intCast(cw)));
        for (t.runs) |run| {
            const view = std.unicode.Utf8View.init(run.text) catch continue; // 잘못된 UTF-8 run은 건너뜀
            var it = view.iterator();
            while (it.nextCodepoint()) |c| {
                const w = @max(1, terminal.width.cellWidth(c)); // 결합 문자(0)는 1칸으로 — frame builder와 동일
                if (col_i >= 0 and col_i < cols) {
                    const idx = row * @as(usize, cols) + @as(usize, @intCast(col_i));
                    cp[idx] = c;
                    fg[idx] = color;
                    cwid[idx] = @intCast(@min(w, 2));
                }
                col_i += w;
            }
        }
    }

    /// 팝업의 가시 행(필터된·윈도우잉된 Row)을 arena에 빌드한다 — 카탈로그(command_catalog.entries.title)와 바인딩
    /// 표시(command_key_displays)는 platform 소유라 여기서 Row{title,binding,selected}로 만들어 neutral 컴포넌트에
    /// 주입한다(컴포넌트는 카탈로그를 안 본다). 선택이 보이도록 max_visible 윈도우로 스크롤한다(레거시 buildPaletteFrame
    /// 윈도우 로직 보존). 선택 행만 selected=true. palette_filtered가 비면 빈 슬라이스.
    fn buildPaletteRows(self: *AppSession, arena: std.mem.Allocator) ![]chrome.components.palette.Row {
        const Row = chrome.components.palette.Row;
        const max_visible = chrome.components.palette.max_visible;
        const total = self.palette_filtered.items.len;
        const selected = self.chrome_host.palette.selected;
        const visible_count = @min(total, max_visible);
        var win_start: usize = 0;
        if (selected >= max_visible) win_start = selected - max_visible + 1; // 선택이 창 아래로 나가면 끝맞춤
        if (win_start + visible_count > total) win_start = total - visible_count; // total≥visible_count라 안전
        const rows = try arena.alloc(Row, visible_count);
        var i: usize = 0;
        while (i < visible_count) : (i += 1) {
            const fi = win_start + i; // palette_filtered 안에서의 인덱스
            const entry_idx = self.palette_filtered.items[fi];
            const binding: []const u8 = if (entry_idx < self.command_key_displays.items.len)
                self.command_key_displays.items[entry_idx]
            else
                "";
            rows[i] = .{
                .title = command_catalog.entries[entry_idx].title,
                .binding = binding,
                .selected = (fi == selected),
            };
        }
        return rows;
    }

    /// chrome 오버레이 frame(최상위). chrome_host에서 열린 컴포넌트(Notice·Find·Palette)의 ChromeDraw를 수집해(실제
    /// view 계약을 탄다) 일반 rasterizer로 lower한다(fill·border·text, EAW-폭 placeText). 오버레이는 라우팅상 배타적
    /// 이라 최대 1개만 ops를 낸다(rasterizer가 단일 오버레이 가정). palette는 카탈로그 행을 주입해야 해 collectDraws가
    /// 아니라 collectPaletteDraws로 따로 모은다. 닫혀 있거나 메트릭/박스 미상이면 에러(호출자가 무시). macOS 전용.
    fn buildChromeOverlayFrame(self: *AppSession) !metal_frame.PaneFrame {
        // 오버레이는 터미널과 같은 셀·폰트(1×)로 그린다 — buildChromeProps도 같은 셀을 컴포넌트에 준다. 1.3× 확대는
        // 사용자 요청으로 제거(스케일 불일치로 한글이 약간 잘리던 문제도 함께 사라짐 — 셀=글리프 font size 일치).
        const cw = self.cell_width_px;
        const ch = self.cell_height_px;
        if (cw == 0 or ch == 0) return error.NoMetrics;
        const appearance = self.appearance;

        // 컴포넌트 view 경로를 실제로 타서 열린 오버레이의 ChromeDraw를 모은다(arena가 ops·runs 소유, lower까지 유효).
        var arena_state = std.heap.ArenaAllocator.init(self.allocator);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const tokens = self.buildChromeTokens();
        const props = self.buildChromeProps();
        var draws: std.ArrayList(chrome.ChromeDraw) = .empty;
        try self.chrome_host.collectDraws(props, &tokens, arena, &draws); // Notice·Find
        if (self.chrome_host.palette.open) {
            const rows = try self.buildPaletteRows(arena); // 카탈로그 행 주입(platform 소유)
            try self.chrome_host.collectPaletteDraws(rows, props, &tokens, arena, &draws);
        }
        if (self.chrome_host.context_menu.open) {
            try self.chrome_host.collectContextMenuDraws(self.contextMenuItems(), props, &tokens, arena, &draws); // 항목 라벨 주입(platform 소유, 동적)
        }
        if (draws.items.len == 0) return error.NotOpen;

        var raster = try rasterizeOverlayCells(self.allocator, draws.items, &tokens, cw, ch);
        // C4b 모달-2b: 모달 배경 quad(layer=1)를 self.gpu_quads(over 패스)에 머지. renderFrame이 매 프레임
        // dropQuadsByLayer(1)로 layer1을 비운 직후라 누적되지 않는다. cells 소유권은 finishOverlayFrame이.
        self.gpu_quads.appendSlice(self.allocator, raster.gpu_quads.items) catch {};
        raster.gpu_quads.deinit(self.allocator);
        self.gpu_shadows.appendSlice(self.allocator, raster.gpu_shadows.items) catch {};
        raster.gpu_shadows.deinit(self.allocator);
        // finishOverlayFrame이 cells 소유권을 toOwnedSlice로 가져가기 **전에** 실패하면(예: overlays alloc OOM)
        // raster.cells가 미해제로 남는다 — 그 경로만 정리한다(성공/이전 후엔 cells가 비어 no-op).
        errdefer raster.cells.deinit(self.allocator);
        return self.finishOverlayFrame(&raster.cells, raster.cols, raster.rows, raster.origin_x, raster.origin_y, appearance, cw, ch, raster.cursor);
    }

    /// chrome Notice 모달(손상 알림 등)을 연다. 메시지는 세션 소유 버퍼로 복사한다 — notice.State.message는 slice라
    /// 호출자(ABI/Swift) 버퍼가 transient면 dangling. 512B 초과는 잘라 표시하되 **UTF-8 코드포인트 경계에서** 자른다
    /// (바이트 경계에서 자르면 한글 등 multibyte가 U+FFFD로 깨진다 — 리뷰 발견). 다음 tick이 오버레이로 그린다.
    pub fn showNotice(self: *AppSession, message: []const u8) void {
        // 오버레이 배타 — notice가 뜨면 find/palette를 닫는다(한 번에 하나만: collectDraws·inputFocus가 단일
        // 오버레이를 가정한다 — 안 닫으면 두 박스가 합쳐진 frame으로 깨져 보이고 IME가 뒤 find로 샌다).
        self.chrome_host.find.hide();
        self.find_matches.clearRetainingCapacity(); // find 닫힘 — 매치 하이라이트 정리(toggleFind와 동일)
        self.chrome_host.palette.hide();
        var n = @min(message.len, self.notice_message_buf.len);
        // 잘렸으면 continuation 바이트(0x80~0xBF)에서 멈추지 않게 lead 바이트까지 되돌린다(코드포인트 중간 절단 방지).
        if (n < message.len) {
            while (n > 0 and (message[n] & 0xC0) == 0x80) n -= 1;
        }
        @memcpy(self.notice_message_buf[0..n], message[0..n]);
        self.chrome_host.notice.show(self.notice_message_buf[0..n]);
        self.metal_dirty = true;
    }

    pub fn metalFrame(self: *const AppSession) MetalFrame {
        var frame = self.metal_buffer.view();
        // "surface→rect": 터미널을 사이드바 폭만큼 오른쪽에 그리고, 왼쪽 strip에 사이드바 배경을 칠한다.
        // 렌더러가 origin offset + 배경 quad를 처리한다. split(panel)도 같은 origin 방식을 확장한다.
        frame.terminal_origin_x_px = self.sidebar_width_px;
        frame.sidebar_bg = self.sidebarBg();
        // 화면 clear color(빈 영역/기본 배경 셀이 비치는 색): OSC 11(배경 set)이 있으면 그 색, 없으면
        // theme.background. DECSCNM(?5, G9) 화면 반전이면 전경색으로 스왑한다(빈 영역도 반전돼야 함). 활성
        // surface 기준(렌더 pass clearColor — 셀이 default 배경=A0일 때 드러남). surface_initialized 가드는
        // 다른 surface-touch 메서드와 동일 — activeSurfaceConst()의 .? unwrap이 탭이 빈 시점(teardown 등)에
        // 패닉하지 않게 한다(그땐 theme 기본 배경으로 폴백).
        frame.terminal_bg = if (self.surface_initialized) blk: {
            const active_core = &self.activeSurfaceConst().core;
            const eff_bg = active_core.defaultBgOverride() orelse self.appearance.theme.background;
            const eff_fg = active_core.defaultFgOverride() orelse self.appearance.theme.foreground;
            break :blk packOpaqueRgb(if (active_core.reverseScreen()) eff_fg else eff_bg);
        } else packOpaqueRgb(self.appearance.theme.background);
        // 사이드바 셀(밴드 ++ 제목 glyph)은 metal_buffer가 소유한다 — view()가 frame.sidebar_cells를
        // 세팅한다(self.sidebar_cells는 밴드 source라 replace에만 넘긴다). 여기선 슬롯 높이만 더한다:
        // 렌더러가 사이드바 셀을 cell 높이가 아니라 탭 슬롯 높이(≈2.5×)로 세로 배치하게.
        frame.sidebar_slot_height_px = self.sidebar_slot_height_px;
        // 상단 헤더(검색바 + view options·새 워크스페이스 아이콘) 높이 — 렌더러가 사이드바 셀(밴드·카드 glyph)을
        // 이만큼 아래로 민다(밴드 view는 슬롯 상대 좌표라 .m이 시프트 단일 책임). 헤더 glyph는 절대 좌표 별도 frame.
        frame.sidebar_header_height_px = self.sidebar_header_height_px;
        return frame;
    }

    pub fn deinit(self: *AppSession) void {
        if (self.copy_buffer.len > 0) self.allocator.free(self.copy_buffer);
        if (self.clipboard_out_buffer.len > 0) self.allocator.free(self.clipboard_out_buffer);
        if (self.notification_title_out.len > 0) self.allocator.free(self.notification_title_out);
        if (self.notification_body_out.len > 0) self.allocator.free(self.notification_body_out);
        for (self.agent_notifications.items) |n| {
            self.allocator.free(n.title);
            self.allocator.free(n.body);
        }
        self.agent_notifications.deinit(self.allocator);
        self.pane_palette_copies.deinit(self.allocator);
        if (self.url_buffer.len > 0) self.allocator.free(self.url_buffer);
        if (self.config_path_buffer) |b| self.allocator.free(b);
        self.pending_paste.deinit(self.allocator);
        self.ime_inserted.deinit(self.allocator);

        self.metal_buffer.deinit(self.allocator);
        self.sidebar_cells.deinit(self.allocator);
        self.gpu_quads.deinit(self.allocator);
        self.gpu_shadows.deinit(self.allocator);
        self.kitty_uploaded.deinit(self.allocator);
        self.global_hotkeys.deinit(self.allocator);
        // 커맨드 카탈로그: owned 문자열(key_display·key_equivalent)을 먼저 해제하고 목록들을 deinit(빌드 전이면 empty라 무해).
        for (self.command_key_displays.items) |s| self.allocator.free(s);
        self.command_key_displays.deinit(self.allocator);
        for (self.command_key_equivalents.items) |s| self.allocator.free(s);
        self.command_key_equivalents.deinit(self.allocator);
        self.command_entries.deinit(self.allocator);
        self.palette_filtered.deinit(self.allocator);
        self.chrome_host.deinit(self.allocator); // chrome 컴포넌트 heap(find.query) 해제
        self.rename_input.deinit(self.allocator); // 인라인 rename 입력(query/preedit) heap 해제
        self.sidebar_search_input.deinit(self.allocator); // 사이드바 검색바 입력 heap 해제
        self.sidebar_visible_tabs.deinit(self.allocator); // 검색 필터 표시 슬롯 매핑 heap 해제
        self.find_matches.deinit(self.allocator);
        self.find_view_spans.deinit(self.allocator);
        if (self.workspace_buffer) |b| self.allocator.free(b);
        if (self.sidebar_config_buffer) |b| self.allocator.free(b);
        self.hover_leaf_scratch.deinit(self.allocator);
        self.scrollbar_leaf_scratch.deinit(self.allocator);
        self.hover_divider_scratch.deinit(self.allocator);
        self.divider_seg_scratch.deinit(self.allocator);
        // 1) 각 탭의 각 panel의 각 Term live PTY 정리 — closeAndDetach는 runtime을 쓰므로 runtime.deinit '전에'.
        //    detach 후 deinit이 reader thread join + fd/queue 해제(이동 금지 계약이라 in-place로 정리).
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    if (term.live_initialized) {
                        if (self.runtime_initialized) term.live_pty.closeAndDetach(&self.runtime);
                        term.live_pty.deinit();
                        term.live_initialized = false;
                    }
                }
            }
        }
        if (self.renderer_initialized) {
            self.renderer_state.deinit();
            self.renderer_initialized = false;
        }
        if (self.runtime_initialized) {
            self.runtime.deinit();
            self.runtime_initialized = false;
        }
        // 2) 각 panel의 각 Term surface 정리 + Term/Pane/Tab heap 해제(runtime.deinit 뒤 — surface는 runtime 불요).
        //    appearance가 surface family를 빌리므로 surface 정리는 아래 config/appearance 해제보다 앞이어야
        //    한다(원래 순서 보존).
        for (self.tabs.items) |tab| {
            for (tab.panes.items) |pane| {
                for (pane.terms.items) |term| {
                    // custom_name(사용자 rename) + git_branch 캐시 + auto_title 캐시(owned) 해제 — destroyTerm과 같은
                    // 규율(deinit은 runtime.deinit 순서 때문에 teardown을 직접 풀어 써서 destroyTerm을 못 부르므로 여기서도
                    // 해제한다). destroyTerm의 owned 필드 목록과 동기 유지할 것.
                    if (term.surface.custom_name) |n| self.allocator.free(n);
                    if (term.git_branch) |b| self.allocator.free(b);
                    if (term.git_branch_cwd) |c| self.allocator.free(c);
                    term.auto_title.deinit(self.allocator);
                    term.surface.deinit();
                    self.allocator.destroy(term);
                }
                if (pane.custom_name) |n| self.allocator.free(n);
                pane.terms.deinit(self.allocator);
                self.allocator.destroy(pane);
            }
            if (tab.custom_name) |n| self.allocator.free(n);
            PaneTree.deinit(self.allocator, tab.tree); // heap split 노드 해제(split.deinit은 leaf 미접근)
            tab.panes.deinit(self.allocator);
            self.allocator.destroy(tab);
        }
        self.tabs.deinit(self.allocator);
        self.surface_ptrs.deinit(self.allocator);
        self.surface_initialized = false;
        // appearance가 family를 빌리므로 surface 정리 뒤에 해제. 가드로 init 초반 실패 시 undefined
        // arena를 free하지 않게(다른 자원과 같은 패턴).
        if (self.config_loaded) {
            self.loaded_config.deinit();
            self.config_loaded = false;
        }
        // 새 탭 spawn용으로 보관했던 ZDOTDIR 셸 통합 디렉터리(init에서 안 풀고 들고 있던 것).
        if (self.new_tab_zdotdir) |d| {
            self.allocator.free(d);
            self.new_tab_zdotdir = null;
        }
        // 보관했던 maru 실행 파일 경로(opt-in ssh 라우팅용 — executablePathAlloc owned).
        if (self.new_tab_ssh_bin) |b| {
            self.allocator.free(b);
            self.new_tab_ssh_bin = null;
        }
        self.* = undefined;
    }

    fn writeSummaryFromTick(self: *AppSession, tick_result: app.AppFrameLoopTick) void {
        // 공유 counter/size/state는 writeSummaryFromState가 단일 출처로 채운다. tick만 아는
        // per-frame render 통계와 tick index만 여기서 덧씌운다. 이렇게 해야 두 writer가
        // 필드별로 어긋나지 않고, 새 counter가 추가돼도 한 곳만 고치면 된다. key/resize/close
        // summary의 render 필드는 "마지막으로 그려진 frame" 값(화면의 현재 상태)을 그대로
        // 유지한다.
        self.writeSummaryFromState();
        const stats = tick_result.render_stats;
        self.last_summary.last_tick_index = @intCast(tick_result.index);
        self.last_summary.glyph_count = @intCast(stats.glyph_count);
        self.last_summary.draw_cells = @intCast(stats.draw_cells);
        self.last_summary.atlas_entries = @intCast(stats.atlas_entries);
        self.last_summary.frame_prepared = boolCode(stats.prepared());
        self.last_summary.frame_consistent = boolCode(stats.consistent);
        self.last_summary.glyph_uv_ready = boolCode(stats.glyph_uv_ready);
        self.last_summary.glyph_raster_ready = boolCode(stats.glyph_raster_ready);
    }

    fn writeSummaryFromState(self: *AppSession) void {
        self.last_summary.abi_version = abi_version;
        self.last_summary.terminal_surface = boolCode(self.surface_initialized);
        self.last_summary.frame_loop_ticks = if (self.renderer_initialized) @intCast(self.frame_loop.frame_index) else 0;
        self.last_summary.output_events = self.total_output_events;
        self.last_summary.exit_events = self.total_exit_events;
        self.last_summary.key_events = self.total_key_events;
        self.last_summary.terminal_input_events = self.total_terminal_input_events;
        self.last_summary.terminal_input_bytes = self.total_terminal_input_bytes;
        self.last_summary.app_key_events = self.total_app_key_events;
        self.last_summary.ignored_key_events = self.total_ignored_key_events;
        self.last_summary.resize_events = self.total_resize_events;
        self.last_summary.close_events = self.total_close_events;
        self.last_summary.ended = boolCode(self.ended_seen);
        self.last_summary.metal_generation = @truncate(self.metal_buffer.generation);
        if (self.surface_initialized) {
            self.last_summary.surface_id = self.activeSurface().id;
            self.last_summary.cols = self.activeSurface().core.size.cols;
            self.last_summary.rows = self.activeSurface().core.size.rows;
            self.last_summary.process_state = processStateCode(self.activeSurface().process_state);
        }
    }
};

pub fn normalizeConfig(config: SessionConfig) !NormalizedConfig {
    if (config.abi_version != abi_version) return error.UnsupportedAbi;
    if (config.cols == 0 or config.rows == 0) return error.InvalidConfig;
    if (config.cols > std.math.maxInt(u16) or config.rows > std.math.maxInt(u16)) return error.InvalidConfig;

    const command_kind = std.enums.fromInt(CommandKind, config.command_kind) orelse return error.InvalidConfig;

    return .{
        // PTY spawn winsize와 Surface의 TerminalCore grid가 같은 최소 크기를 쓰도록 clamp한다
        // (cols>=2). 안 그러면 cols=1 config에서 grid는 2칸(core가 clamp)인데 PTY winsize는 1칸이
        // 되어 셸과 어긋난다.
        .size = terminal.clampGridSize(.{ .cols = @intCast(config.cols), .rows = @intCast(config.rows) }),
        .queue_capacity = if (config.queue_capacity == 0) default_queue_capacity else config.queue_capacity,
        .command_kind = command_kind,
        .chrome_minimal = config.chrome_minimal != 0,
        .minimal_tabs = config.minimal_tabs != 0,
        .width_px = config.width_px,
        .height_px = config.height_px,
        .scale_milli = config.scale_milli,
    };
}

fn spawnRequest(config: NormalizedConfig, term: []const u8, zdotdir: ?[]const u8, ssh_bin: ?[]const u8) maru.pty.SpawnRequest {
    var request: maru.pty.SpawnRequest = switch (config.command_kind) {
        .controlled_smoke => .{
            .command = "/bin/sh",
            .args = &.{
                "-c",
                "printf 'Maru app shell\\r\\n'; IFS= read -r line; printf 'Maru app input:%s\\r\\n' \"$line\"; printf 'Maru app frame loop\\r\\n'",
            },
            .size = config.size,
        },
        .interactive_shell => .{
            .command = maru.pty.resolveInteractiveShell(),
            .args = &.{"-i"},
            // login shell로 띄운다(macOS backend가 login(1)으로 감싼다 — Terminal.app·Ghostty와
            // 동일하게 전체 로그인 세션 셋업). PATH·EDITOR·키바인딩 등 사용자 환경이 완전히 잡힌다.
            // controlled_smoke(/bin/sh -c)는 login이 아니다.
            .login = true,
            .size = config.size,
        },
    };
    // 사용자 config의 TERM을 셸에 준다(기본 xterm-256color). env는 빈 채로 둬 부모 상속 +
    // TERM/COLORTERM override 경로를 타게 한다. zdotdir이 있으면 셸 통합용 ZDOTDIR을 주입한다.
    request.term = term;
    request.zdotdir = zdotdir;
    // opt-in ssh 라우팅이 켜졌으면 maru 실행 파일 경로를 실어 EnvStorage가 MARU_BIN/MARU_SSH_INTEGRATION을
    // 주입하게 한다(null이면 주입 안 함 — 평범한 ssh 그대로).
    request.ssh_integration_bin = ssh_bin;
    return request;
}

fn commandName(kind: CommandKind) []const u8 {
    return switch (kind) {
        .controlled_smoke => "/bin/sh -c maru-app-smoke",
        .interactive_shell => maru.pty.resolveInteractiveShell(),
    };
}

fn processStateCode(state: app.ProcessState) u32 {
    return switch (state) {
        .starting => 0,
        .running => 1,
        .exited => 2,
    };
}

fn boolCode(value: bool) u32 {
    return if (value) 1 else 0;
}

test "macOS app session config rejects unsafe fixed-width ABI input" {
    // Swift가 넘긴 config는 Zig allocator나 slice를 포함하지 않는 fixed-width record다.
    // 이 검증이 있어야 잘못된 window size나 오래된 ABI가 PTY spawn까지 내려가지 않는다.
    try std.testing.expectError(error.UnsupportedAbi, normalizeConfig(.{
        .abi_version = abi_version - 1,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    }));
    try std.testing.expectError(error.InvalidConfig, normalizeConfig(.{
        .abi_version = abi_version,
        .cols = 0,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    }));
    try std.testing.expectError(error.InvalidConfig, normalizeConfig(.{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = 999,
    }));
}

test "macOS app session config defaults queue capacity without changing command intent" {
    const normalized = try normalizeConfig(.{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 0,
        .command_kind = @intFromEnum(CommandKind.interactive_shell),
    });
    try std.testing.expectEqual(terminal.Size{ .cols = 80, .rows = 24 }, normalized.size);
    try std.testing.expectEqual(@as(usize, default_queue_capacity), normalized.queue_capacity);
    try std.testing.expectEqual(CommandKind.interactive_shell, normalized.command_kind);
    try std.testing.expectEqual(false, normalized.chrome_minimal); // 기본 full(0)
    try std.testing.expectEqual(false, normalized.minimal_tabs); // 기본 스크래치(0)
}

test "macOS app session normalizeConfig carries chrome_minimal and minimal_tabs flags" {
    const full = try normalizeConfig(.{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
        .chrome_minimal = 0,
    });
    try std.testing.expectEqual(false, full.chrome_minimal);
    try std.testing.expectEqual(false, full.minimal_tabs);

    const minimal = try normalizeConfig(.{
        .abi_version = abi_version,
        .cols = 80,
        .rows = 24,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
        .chrome_minimal = 1,
        .minimal_tabs = 1,
    });
    try std.testing.expectEqual(true, minimal.chrome_minimal);
    try std.testing.expectEqual(true, minimal.minimal_tabs);
}

test "gridFromBacking divides backing pixels by cell size with placeholder + clamps" {
    // 960×600 backing at 8×18 cell -> 120×33 (이전엔 Swift가 placeholder 12×24로 80×25를 잡아
    // 창과 grid가 어긋났다). 이제 app session이 실제 메트릭으로 직접 계산한다.
    try std.testing.expectEqual(terminal.Size{ .cols = 120, .rows = 33 }, gridFromBacking(960, 600, 8, 18, 0, .{}));
    // cell 크기 0(메트릭 없음, 이론상) -> placeholder 12×24.
    try std.testing.expectEqual(terminal.Size{ .cols = 80, .rows = 25 }, gridFromBacking(960, 600, 0, 0, 0, .{}));
    // floor 동작 + 최소 1×1.
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 1 }, gridFromBacking(25, 16, 10, 16, 0, .{}));
    // cols는 최소 2(TerminalCore가 wide glyph continuation 때문에 요구). 1픽셀/100px cell이라도 2칸.
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 1 }, gridFromBacking(1, 1, 100, 100, 0, .{}));
    // 세로 사이드바 폭만큼 터미널 cols가 줄어든다: 960px − 160px 사이드바 = 800px / 8 = 100 cols(vs 120).
    try std.testing.expectEqual(terminal.Size{ .cols = 100, .rows = 33 }, gridFromBacking(960, 600, 8, 18, 160, .{}));
    // 사이드바가 drawable보다 넓은 비정상도 언더플로 없이 최소 grid로 떨어진다(saturate).
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 33 }, gridFromBacking(960, 600, 8, 18, 2000, .{}));
    // window padding(대칭 8/4): 좌우 합 16px·상하 합 8px를 grid에서 뺀다. cols: (960−16)/8=118, rows: (600−8)/18=32.
    try std.testing.expectEqual(terminal.Size{ .cols = 118, .rows = 32 }, gridFromBacking(960, 600, 8, 18, 0, .{ .left = 8, .right = 8, .top = 4, .bottom = 4 }));
    // 사이드바 + padding 동시: cols (960−160−16)/8=98, rows (600−8)/18=32.
    try std.testing.expectEqual(terminal.Size{ .cols = 98, .rows = 32 }, gridFromBacking(960, 600, 8, 18, 160, .{ .left = 8, .right = 8, .top = 4, .bottom = 4 }));
    // 비대칭 padding: left=10·right=20(합 30)·top=4·bottom=8(합 12). cols (960−30)/8=116, rows (600−12)/18=32.
    try std.testing.expectEqual(terminal.Size{ .cols = 116, .rows = 32 }, gridFromBacking(960, 600, 8, 18, 0, .{ .left = 10, .right = 20, .top = 4, .bottom = 8 }));
    // 비정상 큰 padding도 언더플로 없이 최소 grid로 saturate.
    try std.testing.expectEqual(terminal.Size{ .cols = 2, .rows = 1 }, gridFromBacking(960, 600, 8, 18, 0, .{ .left = 10000, .right = 10000, .top = 10000, .bottom = 10000 }));
}

// refreshCellMetrics의 단일 적용점이 호출하는 line-height·letter-spacing 산술을 못박는다(OS·CoreText 없이 곱/가산
// 검증 — 비-macOS CI에서도 돈다). 이 두 px가 grid·atlas·hit-test의 진실 소스라, 여기 곱/가산이 맞으면 나머지가 자동 정합.
test "applyFontSpacing: line-height multiplies height, letter-spacing adds to width (scaled, saturating)" {
    // 기본값(1.0/0.0)은 base 그대로 — 회귀 최소(현 동작과 동일).
    {
        const r = applyFontSpacing(8, 18, 1.0, 0.0, 1000);
        try std.testing.expectEqual(@as(u32, 8), r.width_px);
        try std.testing.expectEqual(@as(u32, 18), r.height_px);
    }
    // line-height 2.0 → 높이 2배(18→36), 폭은 letter-spacing 0이라 불변.
    {
        const r = applyFontSpacing(8, 18, 2.0, 0.0, 1000);
        try std.testing.expectEqual(@as(u32, 8), r.width_px);
        try std.testing.expectEqual(@as(u32, 36), r.height_px);
    }
    // line-height 1.5 → 18×1.5=27(round). letter-spacing 4pt @1x → +4px(8→12).
    {
        const r = applyFontSpacing(8, 18, 1.5, 4.0, 1000);
        try std.testing.expectEqual(@as(u32, 12), r.width_px);
        try std.testing.expectEqual(@as(u32, 27), r.height_px);
    }
    // letter-spacing은 논리 pt × 분수 scale로 환산 — 2x(scale 2000)에서 4pt는 +8px(8→16). 높이는 1.0이라 불변.
    {
        const r = applyFontSpacing(8, 18, 1.0, 4.0, 2000);
        try std.testing.expectEqual(@as(u32, 16), r.width_px);
        try std.testing.expectEqual(@as(u32, 18), r.height_px);
    }
    // 음수 letter-spacing → 폭 좁힘(8 + (-3) = 5). round 동작 확인(-2.5pt → -3px? round(-2.5)= -2 in zig? half-away: -3).
    {
        const r = applyFontSpacing(8, 18, 1.0, -3.0, 1000);
        try std.testing.expectEqual(@as(u32, 5), r.width_px);
    }
    // 큰 음수 letter-spacing이 폭을 1 미만으로 끌어내려도 1px로 saturate(0폭 grid div 폭주 방지).
    {
        const r = applyFontSpacing(8, 18, 1.0, -100.0, 1000);
        try std.testing.expectEqual(@as(u32, 1), r.width_px);
    }
    // 정확히 base를 0으로 만드는 음수도 1로 saturate(8 + (-8) = 0 → 1).
    {
        const r = applyFontSpacing(8, 18, 1.0, -8.0, 1000);
        try std.testing.expectEqual(@as(u32, 1), r.width_px);
    }
}

// window padding이 터미널 영역 rect(termRect)를 좌상으로 들이고 폭/높이를 2배만큼 줄이는지 고정한다 — 이 rect가
// 렌더 origin·마우스 hit-test(pxToCell)·IME·split leaf의 단일 출처라, 여기서 inset이 맞으면 그 전부가 정합한다.
test "classifyAgent: claude/codex 부분일치(대소문자 무시), 그 외·null=none" {
    try std.testing.expectEqual(AgentKind.claude, classifyAgent("claude"));
    try std.testing.expectEqual(AgentKind.claude, classifyAgent("Claude")); // 대소문자 무시
    try std.testing.expectEqual(AgentKind.codex, classifyAgent("codex"));
    try std.testing.expectEqual(AgentKind.codex, classifyAgent("codex-cli")); // 부분일치
    try std.testing.expectEqual(AgentKind.none, classifyAgent("zsh"));
    try std.testing.expectEqual(AgentKind.none, classifyAgent("node")); // "node"는 에이전트명 아님 — foregroundProcessName이 argv[1]("codex")로 먼저 해소
    try std.testing.expectEqual(AgentKind.none, classifyAgent(null));
    try std.testing.expectEqual(AgentKind.none, classifyAgent(""));
    // 아이콘 코드포인트 매핑(독립 아이콘 셀에 쓰임).
    try std.testing.expectEqual(@as(u21, 0), agentSymbolCodepoint(.none));
    try std.testing.expectEqual(@as(u21, 0x2733), agentSymbolCodepoint(.claude));
    try std.testing.expectEqual(@as(u21, 0x273B), agentSymbolCodepoint(.codex));
}

test "dimRgb: 펄스 off 위상은 브랜드색을 45%로 낮춘다(글자 안 사라짐)" {
    // 밝기 변조라 0이 아니다(깜빡임 아님). 200×45/100=90.
    try std.testing.expectEqual(maru.color.Rgb{ .r = 90, .g = 90, .b = 90 }, dimRgb(.{ .r = 200, .g = 200, .b = 200 }));
    try std.testing.expectEqual(maru.color.Rgb{ .r = 0, .g = 0, .b = 0 }, dimRgb(.{ .r = 0, .g = 0, .b = 0 }));
}

test "에이전트 완료 알림: enqueue 후 pendingNotification이 OSC보다 먼저 큐를 드레인" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    const tab = session.tabs.items[0];
    const term = tab.activePane().activeTerm();
    // 완료 답변을 채우고 비활성 탭 완료를 모사해 enqueue(실제 경로 함수 사용).
    const ans = "PR 머지 완료";
    @memcpy(term.agent_answer_buf[0..ans.len], ans);
    term.agent_answer_len = ans.len;
    session.enqueueAgentCompletion(tab, term);
    try std.testing.expectEqual(@as(usize, 1), session.agent_notifications.items.len);

    // pendingNotification이 OSC 9/777보다 먼저 에이전트 큐를 드레인하고, body=답변. 큐가 비워진다.
    const n = session.pendingNotification() orelse return error.TestExpectedNotification;
    try std.testing.expectEqualStrings(ans, n.body);
    try std.testing.expect(n.title.len > 0); // title=워크스페이스 라벨(비어있지 않음)
    try std.testing.expectEqual(@as(usize, 0), session.agent_notifications.items.len);
    // 큐가 비면 OSC 경로로 떨어지고, controlled_smoke엔 OSC 알림이 없어 null.
    try std.testing.expect(session.pendingNotification() == null);

    // 답변이 비면 body="완료"로 폴백.
    term.agent_answer_len = 0;
    session.enqueueAgentCompletion(tab, term);
    const n2 = session.pendingNotification() orelse return error.TestExpectedNotification;
    try std.testing.expectEqualStrings("완료", n2.body);
}

test "parseGitHead: ref branch / nested ref / detached SHA / empty ref / junk" {
    try std.testing.expectEqualStrings("main", parseGitHead("ref: refs/heads/main\n").?);
    try std.testing.expectEqualStrings("feature/x", parseGitHead("ref: refs/heads/feature/x").?); // 슬래시 포함 브랜치
    try std.testing.expectEqualStrings("0123456", parseGitHead("0123456789abcdef0123456789abcdef01234567\n").?); // detached → short
    try std.testing.expect(parseGitHead("ref: refs/heads/\n") == null); // 빈 브랜치
    try std.testing.expect(parseGitHead("garbage here") == null); // hex 아님·ref 아님
    try std.testing.expect(parseGitHead("ref: refs/tags/v1") == null); // heads 아님(태그) → 미지원
    try std.testing.expect(parseGitHead("") == null);
    try std.testing.expect(parseGitHead("abc") == null); // 7자 미만 hex
}

test "window padding insets only the cell grid, not chrome (termRect/paneBarRect to edge, paneTermRect inset)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    // 결정적 padding(scale 1000 기본이라 appearance 8/4가 그대로 8/4px이지만 명시 고정).
    session.window_padding_px = .{ .left = 8, .right = 8, .top = 4, .bottom = 4 };
    session.cell_height_px = 18; // 탭 바 높이 결정적(bar_h = cell_height + 2·tab_bar_pad_y)
    session.backing_width_px = session.sidebar_width_px + 800;
    session.backing_height_px = 600;

    // termRect: 사이드바만 뺀다 — window padding 없음(chrome이 사이드바 경계/창 가장자리까지).
    const r = session.termRect();
    try std.testing.expectEqual(session.sidebar_width_px, r.x);
    try std.testing.expectEqual(@as(u32, 0), r.y);
    try std.testing.expectEqual(@as(u32, 800), r.w);
    try std.testing.expectEqual(@as(u32, 600), r.h);

    // 탭 바: leaf rect 상단·사이드바 경계에 붙는다(padding inset 없음 — chrome은 가장자리까지).
    const bar = session.paneBarRect(r).?;
    try std.testing.expectEqual(session.sidebar_width_px, bar.x);
    try std.testing.expectEqual(@as(u32, 0), bar.y);
    try std.testing.expectEqual(@as(u32, 800), bar.w);

    // 셀 그리드: 탭 바 아래 + window padding inset(여기만 여백).
    const bar_h = session.paneBarHeightPx();
    const g = session.paneTermRect(r);
    try std.testing.expectEqual(session.sidebar_width_px + 8, g.x); // 좌 = 사이드바 + pad_x
    try std.testing.expectEqual(bar_h + 4, g.y); // 상 = 탭 바 + pad_y
    try std.testing.expectEqual(@as(u32, 800 - 16), g.w); // 폭 = backing − 사이드바 − 2·pad_x
    try std.testing.expectEqual(@as(u32, 600) -| bar_h -| 8, g.h); // 높이 = backing − 바 − 2·pad_y

    // padding 0이면 grid도 inset 없음(탭 바만 뺀 영역).
    session.window_padding_px = .{};
    const g0 = session.paneTermRect(r);
    try std.testing.expectEqual(session.sidebar_width_px, g0.x);
    try std.testing.expectEqual(bar_h, g0.y);
    try std.testing.expectEqual(@as(u32, 800), g0.w);
    try std.testing.expectEqual(@as(u32, 600) -| bar_h, g0.h);
}

// 비대칭 window padding(left≠right, top≠bottom) 회귀: paneTermRect가 좌상으로 left/top만큼만 들이고 폭/높이를
// (left+right)/(top+bottom)만큼 줄이며, gridFromBacking이 같은 비대칭 합을 grid에서 빼는지 고정한다. 대칭 합산
// (2×)으로 회귀하면 left≠right일 때 origin·폭이 어긋나므로 이 단언이 잡는다.
test "asymmetric window padding insets paneTermRect by left/top and grid by left+right/top+bottom" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    // 비대칭: 좌 10·우 20·상 4·하 8.
    session.window_padding_px = .{ .left = 10, .right = 20, .top = 4, .bottom = 8 };
    session.cell_height_px = 18; // 탭 바 높이 결정적
    session.backing_width_px = session.sidebar_width_px + 800;
    session.backing_height_px = 600;

    const r = session.termRect();
    const bar_h = session.paneBarHeightPx();
    const g = session.paneTermRect(r);
    // x는 left(10)만큼만, y는 top(4) + 바만큼 들어간다(우/하는 origin에 영향 없음).
    try std.testing.expectEqual(session.sidebar_width_px + 10, g.x);
    try std.testing.expectEqual(bar_h + 4, g.y);
    // 폭은 left+right(30), 높이는 바 + top+bottom(12)만큼 줄어든다.
    try std.testing.expectEqual(@as(u32, 800 - 30), g.w);
    try std.testing.expectEqual(@as(u32, 600) -| bar_h -| 12, g.h);

    // gridFromBacking도 비대칭 합(left+right=30, top+bottom=12)을 grid에서 뺀다(좌우·상하 대칭 가정 없이).
    // 800px term 폭(사이드바 뺀) 기준 cell 8px: (800−30)/8=96 cols, (600−12)/18=32 rows.
    const grid = gridFromBacking(session.sidebar_width_px + 800, 600, 8, 18, session.sidebar_width_px, session.window_padding_px);
    try std.testing.expectEqual(@as(u16, 96), grid.cols);
    try std.testing.expectEqual(@as(u16, 32), grid.rows);
}

test "takeBell respects bell.audible; createTerm injects config scrollback" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // createTerm이 config 스크롤백(is_test 빈 config → 기본 1000)을 활성 surface core에 주입했다.
    try std.testing.expectEqual(@as(usize, 1000), session.activeSurface().core.max_scrollback);

    // audible(기본 true): BEL → takeBell true, 한 번 울리고 drain(두 번째는 false).
    session.audible_bell = true;
    try session.activeSurface().core.write("\x07");
    try std.testing.expect(session.takeBell());
    try std.testing.expect(!session.takeBell());

    // 음소거: BEL → takeBell false(소리 억제). 단 플래그는 drain돼 stale 벨이 안 쌓인다.
    session.audible_bell = false;
    try session.activeSurface().core.write("\x07");
    try std.testing.expect(!session.takeBell());
    session.audible_bell = true; // 다시 켜도 이전 BEL은 이미 소비됨.
    try std.testing.expect(!session.takeBell());
}

// wheelDeltaToLines 단위 테스트는 함수와 함께 src/session/input_math.zig로 이동.

test "commitComposition is a safe no-op when there is no active preedit" {
    // 조합이 없으면(preedit==null) 아무것도 안 보내고 무해해야 한다 — IME 우회 특수키(PageUp)마다
    // 호출되므로 일반 타이핑 경로를 망가뜨리면 안 된다. commit 경로(preedit 있을 때)는 frame_loop가
    // 필요해 헤드리스로 못 돌리고 GUI 수동 검증으로 본다(PR 본문).
    var session: AppSession = undefined;
    session.allocator = std.testing.allocator;
    session.chrome_host = .{}; // inputFocus가 notice/find/palette.open을 읽음([[devsession-undefined-test-field-trap]])
    session.rename = null; // inputFocus가 rename을 읽음(undefined면 garbage가 .rename 분기 → rename_input crash)
    var tab_surface = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 2 });
    defer tab_surface.deinit();
    session.surface_initialized = true;
    var st_ptrs = [_]*app.Surface{&tab_surface};
    session.app_window = .{ .tabs = &st_ptrs };
    session.metal_dirty = false;
    try std.testing.expect(tab_surface.core.preedit == null);
    session.commitComposition(); // 무동작이어야(no preedit)
    try std.testing.expect(tab_surface.core.preedit == null);
    try std.testing.expect(!session.metal_dirty); // 보낼 게 없으니 다시 그릴 것도 없다
}

// (P3-4) 위임 핸들러(scroll/선택/reportMouse)를 호출하는 단위 테스트용 헬퍼. 메인 mutate가 runtime을 거쳐
// reader로 가므로, 테스트는 surface를 빈 runtime에 attach해 **non-interactive 폴백(직접 적용)**으로 동기 검증한다
// (enqueue_command=null → enqueueCoreCommand가 코어 락 아래 즉시 apply). io도 세워 폴백의 lockCore에 넘긴다.
fn testNoopPtyWrite(_: *anyopaque, _: []const u8) anyerror!void {}
fn testNoopPtyResize(_: *anyopaque, _: terminal.Size) anyerror!void {}
fn attachTestRuntime(session: *AppSession, surface: *app.Surface) !void {
    session.io = std.testing.io;
    session.runtime = app.SurfaceRuntime.init(std.testing.allocator);
    _ = try session.runtime.attach(surface, surface.id, .{ .ctx = undefined, .write_input = testNoopPtyWrite, .resize_fn = testNoopPtyResize });
}

test "scrollPage scrolls one screen (rows-1) per page using the core's authoritative rows" {
    var session: AppSession = undefined;
    var tab_surface = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 5 });
    defer tab_surface.deinit();
    session.surface_initialized = true;
    var st_ptrs = [_]*app.Surface{&tab_surface};
    session.app_window = .{ .tabs = &st_ptrs };
    try attachTestRuntime(&session, &tab_surface);
    defer session.runtime.deinit();
    session.metal_dirty = false;
    // 9줄 출력 -> 5행 화면 위로 4줄이 스크롤백에 쌓인다.
    try tab_surface.core.write("1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9");
    try std.testing.expectEqual(@as(usize, 4), tab_surface.core.scrollbackLen());

    session.scrollPage(1); // 위로 한 화면 = rows-1 = 4줄
    try std.testing.expectEqual(@as(usize, 4), tab_surface.core.view_offset);
    try std.testing.expect(session.metal_dirty);

    session.scrollPage(-1); // 아래로 한 화면 -> 바닥
    try std.testing.expectEqual(@as(usize, 0), tab_surface.core.view_offset);
}

test "mouse reporting 진입은 진행 중이던 드래그 autoscroll을 멈춘다 (audit MEDIUM)" {
    var session: AppSession = undefined;
    session.allocator = std.testing.allocator;
    var tab_surface = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 2 });
    defer tab_surface.deinit();
    session.surface_initialized = true;
    var st_ptrs = [_]*app.Surface{&tab_surface};
    session.app_window = .{ .tabs = &st_ptrs };
    try attachTestRuntime(&session, &tab_surface);
    defer session.runtime.deinit();
    session.metal_dirty = false;
    session.chrome_host = .{}; // mouse()가 context_menu.open을 kind 무관하게 읽음([[devsession-undefined-test-field-trap]])
    session.rename = null;
    session.divider_drag = null;
    session.sidebar_resize_active = false;
    session.scrollbar_drag_grab = null; // mouse()의 스크롤바 드래그 캡처가 읽는다(undefined ?f32도 garbage non-null)
    session.cell_width_px = 8;
    session.cell_height_px = 16;
    session.scale_milli = 1000;
    session.sidebar_width_px = 0;
    session.active_pane_rect = .{ .x = 0, .y = 0, .w = 32, .h = 32 };
    session.last_drag_col = 1;

    // 셀렉션 드래그 autoscroll이 걸린 상태에서 앱이 mouse tracking(.normal)을 켰다.
    session.drag_autoscroll = 1;
    session.mouse_drag_selecting = true;
    tab_surface.core.mouse_tracking = .normal;

    // 다음 drag(kind 2) 이벤트가 reporting 분기로 간다 — autoscroll/selecting을 멈춰야 한다(예전엔 조기
    // return하며 안 꺼서 30Hz로 stuck). .normal은 motion을 리포트하지 않아 PTY write-back은 없다.
    session.mouse(2, 8.0, 8.0, 0, 0);
    try std.testing.expectEqual(@as(i8, 0), session.drag_autoscroll);
    try std.testing.expect(!session.mouse_drag_selecting);
}

test "drag autoscroll scrolls one line per tick and extends the selection to the edge row" {
    var session: AppSession = undefined;
    session.allocator = std.testing.allocator;
    var tab_surface = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 2 });
    defer tab_surface.deinit();
    session.surface_initialized = true;
    var st_ptrs = [_]*app.Surface{&tab_surface};
    session.app_window = .{ .tabs = &st_ptrs };
    try attachTestRuntime(&session, &tab_surface);
    defer session.runtime.deinit();
    session.metal_dirty = false;
    session.chrome_host = .{}; // mouse()가 context_menu.open을 kind 무관하게 읽음([[devsession-undefined-test-field-trap]])
    session.rename = null;
    session.mouse_drag_selecting = true;
    session.divider_drag = null; // mouse()의 divider 드래그 캡처가 읽는다(undefined 옵셔널 포인터는 garbage non-null)
    session.sidebar_resize_active = false; // mouse()의 사이드바 폭 조절 캡처가 읽는다(undefined bool도 garbage)
    session.scrollbar_drag_grab = null; // mouse()의 스크롤바 드래그 캡처가 읽는다(undefined ?f32도 garbage non-null)
    session.drag_autoscroll = 0;
    session.last_drag_col = 1;
    session.cell_width_px = 8;
    session.cell_height_px = 16;
    session.scale_milli = 1000;
    session.sidebar_width_px = 0; // 사이드바 없음 — 마우스가 터미널 선택 경로를 타게(inSidebar=false)
    session.active_pane_rect = .{ .x = 0, .y = 0, .w = 32, .h = 32 }; // 단일 panel 좌표 origin(pxToCell이 읽음)

    const core = &tab_surface.core;
    try core.write("a\r\nb\r\nc\r\nd"); // 스크롤백 2(a,b) + 화면 c,d
    core.selectionStart(1, 0); // 화면 행1(d)에서 드래그 시작

    // 드래그가 grid 위 밖으로(y<0) — kind 2가 자동 스크롤 방향을 세운다.
    session.mouse(2, 0.0, -5.0, 0, 0); // col 0, grid 위 밖
    try std.testing.expectEqual(@as(i8, 1), session.drag_autoscroll);

    session.applyDragAutoscroll(); // tick 1: 한 줄 위로 + 선택이 뷰 최상단으로 확장
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
    session.applyDragAutoscroll(); // tick 2: 맨 위까지
    try std.testing.expectEqual(@as(usize, 2), core.view_offset);
    const text = (try core.extractSelection(std.testing.allocator)).?;
    defer std.testing.allocator.free(text);
    // 선택이 a(맨 위)까지 닿았다.
    try std.testing.expectEqualStrings("a\nb\nc\nd", text);

    // up(3)이 자동 스크롤을 멈춘다.
    session.mouse(3, 8.0, 8.0, 0, 0);
    try std.testing.expectEqual(@as(i8, 0), session.drag_autoscroll);
}

test "cursor blink: 틱마다 토글·steady/조합 고정·활동 리셋·오버레이 caret도 깜빡(suffix-trim 재활용)" {
    var session: AppSession = undefined;
    session.allocator = std.testing.allocator;
    var tab_surface = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 2 });
    defer tab_surface.deinit();
    session.surface_initialized = true;
    var st_ptrs = [_]*app.Surface{&tab_surface};
    session.app_window = .{ .tabs = &st_ptrs };
    session.metal_dirty = false;
    session.metal_buffer = .{};
    session.blink_visible = true;
    session.blink_ticks = 0;
    session.chrome_host = .{}; // updateCursorBlink이 find/palette.open을 읽음 — undefined면 UB([[devsession-undefined-test-field-trap]])
    session.rename = null; // inputFocus/updateCursorBlink가 rename을 읽음(undefined면 garbage가 .rename 분기)
    session.tabs = .empty; // updateCursorBlink→anyAgentRunning이 tabs를 순회 — undefined면 UB(같은 함정). 빈 목록=펄스 없음

    // 기본(DECSCUSR 1 = 깜빡 block): interval 틱마다 토글. rebuild(metal_dirty) 없이 generation만(suffix 토글).
    var i: u32 = 0;
    while (i < blink_interval_ticks) : (i += 1) session.updateCursorBlink();
    try std.testing.expect(!session.blink_visible);
    try std.testing.expect(!session.metal_dirty);
    try std.testing.expectEqual(@as(u64, 1), session.metal_buffer.generation);
    try std.testing.expect(!session.metal_buffer.show_cursor);
    while (i < blink_interval_ticks * 2) : (i += 1) session.updateCursorBlink();
    try std.testing.expect(session.blink_visible);

    // 활동(입력/출력) 리셋: off 위상이어도 즉시 보이게.
    session.blink_visible = false;
    session.blink_ticks = 7;
    session.resetCursorBlink();
    try std.testing.expect(session.blink_visible);
    try std.testing.expectEqual(@as(u32, 0), session.blink_ticks);

    // steady 커서(DECSCUSR 2) + 오버레이 닫힘: 토글 안 함(보이는 위상 고정 — idle 절전).
    try tab_surface.core.write("\x1b[2 q");
    session.blink_visible = true;
    i = 0;
    while (i < blink_interval_ticks * 3) : (i += 1) session.updateCursorBlink();
    try std.testing.expect(session.blink_visible);

    // 오버레이(find) 열림: steady 커서여도 caret은 깜빡인다(overlay_open이라 토글 — suffix=오버레이 caret). 회귀:
    // 사용자 제보 "오버레이 커서가 안 깜빡임" 수정 — 터미널 커서와 같은 틱-카운터+suffix-trim 재활용.
    session.chrome_host.find.open = true;
    session.blink_visible = true;
    session.blink_ticks = 0;
    i = 0;
    while (i < blink_interval_ticks) : (i += 1) session.updateCursorBlink();
    try std.testing.expect(!session.blink_visible); // caret이 off 위상으로 토글됨
    session.chrome_host.find.open = false;

    // IME 조합 중(preedit) + 오버레이 닫힘: 깜빡이지 않고 고정 — 조합 글자 옆에서 안 반짝.
    try tab_surface.core.write("\x1b[1 q"); // 다시 blink 커서로
    try tab_surface.core.setPreedit("\xec\x95\x88");
    session.blink_visible = true;
    i = 0;
    while (i < blink_interval_ticks * 3) : (i += 1) session.updateCursorBlink();
    try std.testing.expect(session.blink_visible);
    try tab_surface.core.setPreedit("");
}

// 셸을 처음부터 실제 창 크기로 spawn하는 핸드셰이크 제거(zsh 첫 프롬프트 % 잔상 방지)를 고정한다. backing px가
// 주어지면 init이 cell 메트릭으로 grid를 계산해 그 크기로 spawn하고(80×24 아님), 없으면 cols/rows로 폴백한다.
test "init: backing px가 주어지면 셸을 그 창 grid로 spawn(80×24 핸드셰이크 없음), 없으면 cols/rows 폴백" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // refreshCellMetrics가 실제 CoreText 메트릭을 읽음
    const allocator = std.testing.allocator;
    // backing px(1600×900, 1x) 주어진 경우 — cols/rows(80×24)는 폴백값일 뿐, 실제 spawn은 창 grid여야 한다.
    {
        const session = try allocator.create(AppSession);
        defer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = abi_version,
            .cols = 80,
            .rows = 24,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(CommandKind.controlled_smoke),
            .width_px = 1600,
            .height_px = 900,
            .scale_milli = 1000,
        });
        defer session.deinit();
        // spawn 크기 = gridFromBacking(창 px, 세션 자신의 cell·사이드바 메트릭) — resize 경로와 같은 단일 출처.
        const expected = gridFromBacking(1600, 900, session.cell_width_px, session.cell_height_px, session.sidebar_width_px, session.window_padding_px);
        const got = session.activePane().activeTerm().surface.core.size;
        try std.testing.expectEqual(expected, got);
        try std.testing.expect(got.cols != 80 or got.rows != 24); // 80×24 폴백이 아니다(창이 더 넓어 grid가 다름)
    }
    // 2x(retina) — 진단: width_px=1920·scale_milli=2000일 때 cell·sidebar·grid 실측(MARU_DEBUG 로그).
    {
        const session = try allocator.create(AppSession);
        defer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = abi_version,
            .cols = 80,
            .rows = 24,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(CommandKind.controlled_smoke),
            .width_px = 1920,
            .height_px = 1200,
            .scale_milli = 2000,
        });
        defer session.deinit();
        // 진단으로 확인됨: 2x에서 cell=17×37·sidebar_px=360·grid 91×32. init의 spawn 그리드는 정확하다(불일치 없음).
        const expected = gridFromBacking(1920, 1200, session.cell_width_px, session.cell_height_px, session.sidebar_width_px, session.window_padding_px);
        try std.testing.expectEqual(expected, session.activePane().activeTerm().surface.core.size);
    }
    // backing px 0(헤드리스·창 미상) — cols/rows로 폴백 spawn.
    {
        const session = try allocator.create(AppSession);
        defer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = abi_version,
            .cols = 100,
            .rows = 30,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(CommandKind.controlled_smoke),
            .width_px = 0,
            .height_px = 0,
            .scale_milli = 0,
        });
        defer session.deinit();
        try std.testing.expectEqual(terminal.Size{ .cols = 100, .rows = 30 }, session.activePane().activeTerm().surface.core.size);
    }
}

test "buildSidebarTitleFrame: 에이전트 심볼(✳/✻) prefix여도 프레임 빌드 성공(제목 사라짐 회귀 방지)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 CoreText shaper 경로
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    // 에이전트 없음 → 정상 빌드(baseline).
    {
        var f = try session.buildSidebarTitleFrame();
        f.deinit(allocator);
    }
    // claude/codex 심볼 prefix가 붙어도 buildSidebarTitleFrame이 에러 없이 프레임을 만들어야 한다
    // (catch null로 흘러 전체 사이드바 제목이 사라지면 안 됨).
    session.activeTab().activePane().activeTerm().agent_kind = .claude;
    {
        var f = try session.buildSidebarTitleFrame();
        f.deinit(allocator);
    }
    session.activeTab().activePane().activeTerm().agent_kind = .codex;
    {
        var f = try session.buildSidebarTitleFrame();
        f.deinit(allocator);
    }
    // 3줄 카드(이름/브랜치/경로): buildSidebarTitleFrame은 buildSidebarDrawList 결과를 indent_cols만큼 우측 시프트한다.
    // 폭을 꽉 채운 긴 경로줄이 size.cols를 넘으면 ShapedRecordOutsideSurface로 프레임이 통째로 실패(catch null →
    // 사이드바 텍스트 전부 사라짐). 시프트 후 size.cols를 full_cols로 넓혀 수용하는지 고정 — 실 앱에서 못 봤던 버그.
    {
        const names = [_][]const u8{"\u{2733} maru"};
        const branches = [_][]const u8{"\u{2387} main"};
        const paths = [_][]const u8{"~/documents/workspace/maru"}; // 길어 좁은 폭을 꽉 채움 → 시프트 시 overflow
        const muted: terminal.Color = .{ .rgb = session.appearance.theme.sidebar_foreground };
        const sidebar_cols: u16 = 12;
        const indent_cols: u16 = 3;
        const full_cols: u16 = 20; // ≥ sidebar_cols + indent_cols
        const fb = coretext_frame_builder.CoreTextFrameBuilder{
            .appearance = session.appearance,
            .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
            .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
            .scale_milli = session.scale_milli,
            .cell_width_px = @intCast(session.cell_width_px),
            .cell_height_px = @intCast(session.cell_height_px),
        };
        // (1) 시프트만 하고 size.cols를 안 넓히면 ShapedRecordOutsideSurface로 실패함을 고정(버그 재현 — buildFromDrawList가
        //     실패 시 draw_list를 정리하므로 별도 free 안 함).
        {
            const dl = try coretext_frame_builder.buildSidebarDrawList(allocator, &names, &branches, &paths, &[_][]const u8{}, &[_]u21{}, sidebar_cols, muted, null, 1, 0, muted);
            for (dl.cells) |*c| c.col += indent_cols;
            try std.testing.expectError(error.ShapedRecordOutsideSurface, fb.buildFromDrawList(allocator, dl, &session.renderer_state));
        }
        // (2) 시프트 후 size.cols=full_cols로 넓히면(수정) 정상 빌드 + row 보존(이름 idx0·경로 idx2, count=3).
        {
            var dl = try coretext_frame_builder.buildSidebarDrawList(allocator, &names, &branches, &paths, &[_][]const u8{}, &[_]u21{}, sidebar_cols, muted, null, 1, 0, muted);
            for (dl.cells) |*c| c.col += indent_cols;
            dl.size.cols = full_cols;
            var f = try fb.buildFromDrawList(allocator, dl, &session.renderer_state);
            defer f.deinit(allocator);
            var saw_name = false;
            var saw_path = false;
            for (f.glyph_quad_frame.glyphs) |g| {
                if (g.run.codepoint == 'm' and g.run.row == coretext_frame_builder.sidebarGlyphRow(0, 0, 3)) saw_name = true;
                if (g.run.codepoint == '~' and g.run.row == coretext_frame_builder.sidebarGlyphRow(0, 2, 3)) saw_path = true;
            }
            try std.testing.expect(saw_name);
            try std.testing.expect(saw_path);
        }
    }
}

test "headless ticks toggle the blink phase and bump the metal generation" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실제 CoreText frame builder 경로
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 출력 타이밍에 흔들리지 않게(느린 CI에서 controlled 출력이 여러 tick에 걸쳐 와 위상을
    // 계속 리셋할 수 있다) "첫 토글이 관측될 때까지" 충분한 상한으로 tick한다 — 출력은 유한하니
    // 멎은 뒤 interval 틱이 지나면 반드시 토글된다.
    var toggles: usize = 0;
    var gen_changes: usize = 0;
    var last_vis = session.blink_visible;
    var last_gen: u64 = session.metal_buffer.generation;
    var i: usize = 0;
    while (i < blink_interval_ticks * 20 and toggles == 0) : (i += 1) {
        _ = try session.tick();
        if (session.blink_visible != last_vis) {
            toggles += 1;
            last_vis = session.blink_visible;
        }
        if (session.metal_buffer.generation != last_gen) {
            gen_changes += 1;
            last_gen = session.metal_buffer.generation;
        }
    }
    try std.testing.expect(toggles >= 1);
    // 토글은 rebuild 없이도 재드로우를 유발해야 한다(setCursorVisible의 generation 증가).
    try std.testing.expect(gen_changes >= toggles);
}

// 인라인 rename 동작(PR3): start→입력→commit이 custom_name을 쓰고, cancel은 원래 이름 유지, 빈 텍스트 commit은
// 이름을 지우고, 대상 Term teardown이 rename을 자동 취소(stale 포인터 방지)하는지를 풀-세션 경로로 고정한다.
test "context menu: workspace=Rename+Pin+배경 항목, accept가 pin 토글·배경색 설정; pane/term=Rename만" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    const tab = session.activeTab();

    // workspace 대상: Rename + Pin + 배경 프리셋(없음·앰버·파랑·초록·빨강·보라).
    session.context_menu_target = .{ .workspace = tab };
    const items = session.buildContextMenuItems();
    try std.testing.expectEqual(@as(usize, 2 + tab_bg_presets.len), items.len);
    try std.testing.expectEqualStrings("Rename", items[0]);
    try std.testing.expectEqualStrings("위치 고정", items[1]); // 미고정 → "위치 고정"

    // accept selected=1 → pin 토글(true). acceptContextMenu가 target을 null화하므로 매번 재설정.
    session.context_menu_target = .{ .workspace = tab };
    session.chrome_host.context_menu.selected = 1;
    session.acceptContextMenu();
    try std.testing.expect(tab.pinned);

    // 다시 열면 "고정 해제"가 뜬다(토글 상태 반영).
    session.context_menu_target = .{ .workspace = tab };
    try std.testing.expectEqualStrings("고정 해제", session.buildContextMenuItems()[1]);

    // accept selected=3(배경: 앰버, idx 0=Rename·1=Pin·2=없음·3=앰버) → background_color = 0xDDA15E.
    session.context_menu_target = .{ .workspace = tab };
    session.chrome_host.context_menu.selected = ctx_menu_bg_first + 1;
    session.acceptContextMenu();
    try std.testing.expectEqual(@as(u32, 0xDDA15E), tab.background_color);

    // 배경: 없음(selected=2) → 0으로 해제.
    session.context_menu_target = .{ .workspace = tab };
    session.chrome_host.context_menu.selected = ctx_menu_bg_first;
    session.acceptContextMenu();
    try std.testing.expectEqual(@as(u32, 0), tab.background_color);

    // pane/term 대상은 Rename만(색·고정 없음).
    session.context_menu_target = .{ .pane = session.activePane() };
    try std.testing.expectEqual(@as(usize, 1), session.buildContextMenuItems().len);
    session.context_menu_target = null;
}

test "moveTab: 고정 탭은 고정 영역 안에서만, 비고정은 비고정 영역 안에서만 재정렬(그룹 clamp)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    // 4탭으로(앞 2개 고정, 뒤 2개 비고정). newTab은 끝에 추가.
    inline for (0..3) |_| _ = try session.newTab();
    try std.testing.expectEqual(@as(usize, 4), session.tabs.items.len);
    const t0 = session.tabs.items[0];
    const t1 = session.tabs.items[1];
    const t2 = session.tabs.items[2];
    const t3 = session.tabs.items[3];
    t0.pinned = true;
    t1.pinned = true; // [P0, P1, u2, u3], pinned_count=2

    // 고정(0)을 아래(끝, 3)로 끌어도 고정 영역 [0,2)로 clamp → swap(0↔1)만. 비고정(2,3) 불변.
    // moveTab은 clamp으로 확정된 안착 인덱스(1)를 반환한다.
    try std.testing.expectEqual(@as(usize, 1), session.moveTab(0, 3));
    try std.testing.expectEqual(t1, session.tabs.items[0]);
    try std.testing.expectEqual(t0, session.tabs.items[1]);
    try std.testing.expectEqual(t2, session.tabs.items[2]); // 비고정 불변
    try std.testing.expectEqual(t3, session.tabs.items[3]);

    // 비고정(끝, 3=t3)을 위(0)로 끌어도 비고정 영역 [2,4)로 clamp → t3가 2로, t2가 3으로. 고정(0,1) 불변.
    // 안착 인덱스(2) 반환.
    try std.testing.expectEqual(@as(usize, 2), session.moveTab(3, 0));
    try std.testing.expectEqual(t1, session.tabs.items[0]); // 고정 영역 불변
    try std.testing.expectEqual(t0, session.tabs.items[1]);
    try std.testing.expectEqual(t3, session.tabs.items[2]); // 비고정 영역 시작으로만
    try std.testing.expectEqual(t2, session.tabs.items[3]);
}

test "togglePin: pin은 탭을 고정 영역 끝으로, unpin은 비고정 영역 시작으로 정렬(불변식 유지)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    inline for (0..3) |_| _ = try session.newTab();
    try std.testing.expectEqual(@as(usize, 4), session.tabs.items.len);
    const t0 = session.tabs.items[0];
    const t1 = session.tabs.items[1];
    const t2 = session.tabs.items[2];
    const t3 = session.tabs.items[3];

    // 끝 탭(t3)을 pin → 고정 영역 끝(index 0, 첫 고정)으로 이동. 나머지 한 칸씩 밀림.
    session.togglePin(t3);
    try std.testing.expect(t3.pinned);
    try std.testing.expectEqual(t3, session.tabs.items[0]);
    try std.testing.expectEqual(@as(usize, 1), session.countPinnedTabs());
    // 불변식: tabs[0..pinned_count]가 전부 고정.
    try assertPinnedPrefix(session);

    // 중간 탭(t1, 지금 index 2)을 pin → 고정 영역 끝(index 1)으로 이동.
    session.togglePin(t1);
    try std.testing.expect(t1.pinned);
    try std.testing.expectEqual(t3, session.tabs.items[0]);
    try std.testing.expectEqual(t1, session.tabs.items[1]);
    try std.testing.expectEqual(@as(usize, 2), session.countPinnedTabs());
    try assertPinnedPrefix(session);

    // t3 unpin → 비고정 영역 시작(새 pinned_count=1, index 1)으로 이동. t1만 고정으로 남음(index 0).
    session.togglePin(t3);
    try std.testing.expect(!t3.pinned);
    try std.testing.expectEqual(t1, session.tabs.items[0]);
    try std.testing.expectEqual(t3, session.tabs.items[1]);
    try std.testing.expectEqual(@as(usize, 1), session.countPinnedTabs());
    try assertPinnedPrefix(session);
    // 나머지 비고정(t0,t2)은 t3 뒤.
    try std.testing.expect(!t0.pinned and !t2.pinned);
}

/// 불변식 검사 헬퍼: 고정 탭은 배열 앞쪽 `[0, pinned_count)`에 연속으로 모이고, 그 뒤는 전부 비고정.
fn assertPinnedPrefix(session: *AppSession) !void {
    const pc = session.countPinnedTabs();
    for (session.tabs.items, 0..) |t, i| {
        if (i < pc) try std.testing.expect(t.pinned) else try std.testing.expect(!t.pinned);
    }
}

/// 사이드바 제목 프레임에 📌(U+1F4CC) 핀 prefix 글리프 셀이 있는가 — buildSidebarTitleFrame이 names줄에
/// "📌 "를 붙였을 때만 나타난다. 프레임은 매 frame 재-shape(tab.pinned 라이브)되므로 토글 직후 빌드하면 새 상태가 보인다.
fn frameHasPinGlyph(session: *AppSession) !bool {
    var f = try session.buildSidebarTitleFrame();
    defer f.deinit(session.allocator);
    for (f.draw_list.cells) |c| if (c.codepoint == 0x1F4CC) return true;
    return false;
}

test "togglePin: 경계 탭(from==to)도 토글 즉시 📌 라벨이 갱신된다(불변식 유지)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 CoreText shaper 경로
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000); // 사이드바 grid 확보(제목 프레임 빌드 가능)
    // 단일 탭: pin하면 새 pinned_count=1, to=count-1=0=현재 인덱스 → moveTab이 from==to로 early-return(reorder 없음).
    // togglePin이 무조건 rebuildSidebar를 부르고 metal_dirty를 세워 즉시 재렌더되며, 제목 프레임이 tab.pinned를
    // 라이브로 읽어 📌를 붙인다. 토글 전엔 없고, pin 후엔 있고, unpin 후엔 다시 없어야 한다(경계 탭에서도).
    const t0 = session.tabs.items[0];
    try std.testing.expect(!(try frameHasPinGlyph(session)));
    session.togglePin(t0); // 경계 탭(from==to)
    try std.testing.expect(t0.pinned);
    try std.testing.expect(session.metal_dirty); // 재렌더 트리거
    try std.testing.expect(try frameHasPinGlyph(session)); // 📌가 즉시 떠야 한다
    try assertPinnedPrefix(session); // 불변식 성립
    session.togglePin(t0); // unpin도 경계(from==to)
    try std.testing.expect(!t0.pinned);
    try std.testing.expect(!(try frameHasPinGlyph(session))); // 📌가 즉시 사라져야 한다
    try assertPinnedPrefix(session);
}

test "applyWorkspaceWindow: 섞인 [P,u,P,u] 복원을 고정-prefix로 stable-partition한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY spawn
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000);

    // 4개 단일-pane 탭, 저장 순서 [P, u, P, u](#685 이전 빌드가 만든 섞인 상태). custom_name으로 정렬 추적.
    const s0 = [_]app.workspace.Surface{.{ .cwd = "/tmp", .cols = 40, .rows = 24 }};
    const s1 = [_]app.workspace.Surface{.{ .cwd = "/tmp", .cols = 40, .rows = 24 }};
    const s2 = [_]app.workspace.Surface{.{ .cwd = "/tmp", .cols = 40, .rows = 24 }};
    const s3 = [_]app.workspace.Surface{.{ .cwd = "/tmp", .cols = 40, .rows = 24 }};
    const p0 = [_]app.workspace.Pane{.{ .surfaces = &s0 }};
    const p1 = [_]app.workspace.Pane{.{ .surfaces = &s1 }};
    const p2 = [_]app.workspace.Pane{.{ .surfaces = &s2 }};
    const p3 = [_]app.workspace.Pane{.{ .surfaces = &s3 }};
    const leaf = [_]app.workspace.TreeNode{.{ .leaf = 0 }};
    const tabs = [_]app.workspace.Tab{
        .{ .custom_name = "P0", .pinned = true, .tree = &leaf, .panes = &p0 },
        .{ .custom_name = "u1", .pinned = false, .tree = &leaf, .panes = &p1 },
        .{ .custom_name = "P2", .pinned = true, .tree = &leaf, .panes = &p2 },
        .{ .custom_name = "u3", .pinned = false, .tree = &leaf, .panes = &p3 },
    };
    // active_tab=3(u3, 비고정 끝) — 재배열 후에도 u3을 가리켜야(stable-partition이 active *Tab 추적).
    try session.applyWorkspaceWindow(.{ .active_tab = 3, .tabs = &tabs });

    try std.testing.expectEqual(@as(usize, 4), session.tabs.items.len);
    // stable-partition: 고정(P0,P2)이 앞으로(상대 순서 유지), 비고정(u1,u3)이 뒤로(상대 순서 유지) → [P0, P2, u1, u3].
    try std.testing.expectEqualStrings("P0", session.tabs.items[0].custom_name.?);
    try std.testing.expectEqualStrings("P2", session.tabs.items[1].custom_name.?);
    try std.testing.expectEqualStrings("u1", session.tabs.items[2].custom_name.?);
    try std.testing.expectEqualStrings("u3", session.tabs.items[3].custom_name.?);
    try std.testing.expectEqual(@as(usize, 2), session.countPinnedTabs());
    try assertPinnedPrefix(session); // 불변식 성립
    // active_tab은 가리키던 u3(원래 index 3)의 새 위치(index 3)로 보정 — 여기선 그대로지만 추적 경로를 탄다.
    try std.testing.expectEqualStrings("u3", session.tabs.items[session.app_window.active_tab].custom_name.?);
}

test "사이드바 드래그: 비고정 탭을 위로 끌어도 고정 영역을 침범하지 않는다(그룹 경계)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    inline for (0..3) |_| _ = try session.newTab();
    try std.testing.expectEqual(@as(usize, 4), session.tabs.items.len);
    const t0 = session.tabs.items[0];
    const t1 = session.tabs.items[1];
    const t2 = session.tabs.items[2];
    const t3 = session.tabs.items[3];
    t0.pinned = true;
    t1.pinned = true; // [P0, P1, u2, u3], pinned_count=2
    session.rebuildSidebar() catch {};

    const slot_h: f64 = @floatFromInt(session.sidebar_slot_height_px);
    const header_h: f64 = @floatFromInt(session.sidebar_header_height_px); // 슬롯은 상단 헤더 아래로 시프트
    const x: f64 = @as(f64, @floatFromInt(session.sidebar_width_px)) - 1;

    // 비고정 끝 탭(slot 3=t3)을 잡아 slot 0(고정 영역)으로 드래그 → 비고정 영역 시작(index 2)으로만 안착.
    session.mouse(1, x, header_h + slot_h * 3 + 1, 0, 0); // down on slot 3 → arm
    try std.testing.expect(session.sidebar_drag_active);
    try std.testing.expectEqual(@as(usize, 3), session.sidebar_drag_index);
    session.mouse(2, x, header_h + 1, 0, 0); // drag toward slot 0
    session.mouse(3, x, header_h + 1, 0, 0); // up

    // 고정(t0,t1)은 [0,1] 불변, t3는 비고정 영역 시작(2)으로만, t2가 3으로 밀림.
    try std.testing.expectEqual(t0, session.tabs.items[0]);
    try std.testing.expectEqual(t1, session.tabs.items[1]);
    try std.testing.expectEqual(t3, session.tabs.items[2]);
    try std.testing.expectEqual(t2, session.tabs.items[3]);
    try assertPinnedPrefix(session);
    try std.testing.expect(!session.sidebar_drag_active);
}

test "사이드바 드래그: 고정 탭끼리 재정렬(고정 영역 내 swap, 비고정 불변)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    inline for (0..3) |_| _ = try session.newTab();
    const t0 = session.tabs.items[0];
    const t1 = session.tabs.items[1];
    const t2 = session.tabs.items[2];
    const t3 = session.tabs.items[3];
    t0.pinned = true;
    t1.pinned = true; // [P0, P1, u2, u3], pinned_count=2
    session.rebuildSidebar() catch {};

    const slot_h: f64 = @floatFromInt(session.sidebar_slot_height_px);
    const header_h: f64 = @floatFromInt(session.sidebar_header_height_px); // 슬롯은 상단 헤더 아래로 시프트
    const x: f64 = @as(f64, @floatFromInt(session.sidebar_width_px)) - 1;

    // 고정 탭 0(t0)을 slot 1(다른 고정)로 드래그 → 고정 영역 내 swap. 비고정 영향 없음.
    session.mouse(1, x, header_h + 1, 0, 0); // down slot 0(고정도 이제 arm)
    try std.testing.expect(session.sidebar_drag_active);
    try std.testing.expectEqual(@as(usize, 0), session.sidebar_drag_index);
    session.mouse(2, x, header_h + slot_h * 1 + 1, 0, 0); // drag to slot 1
    session.mouse(3, x, header_h + slot_h * 1 + 1, 0, 0); // up

    try std.testing.expectEqual(t1, session.tabs.items[0]); // swap
    try std.testing.expectEqual(t0, session.tabs.items[1]);
    try std.testing.expectEqual(t2, session.tabs.items[2]); // 비고정 불변
    try std.testing.expectEqual(t3, session.tabs.items[3]);
    try assertPinnedPrefix(session);
}

test "rename: commit writes custom_name, cancel keeps old, empty clears, teardown clears target" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 풀 세션(실 PTY/CoreText) 경로
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    const tab = session.activeTab();
    // 1) 워크스페이스 rename: 시작 → 'h','i' → Enter 확정 → custom_name == "hi", 편집기 닫힘.
    session.startRename(.{ .workspace = tab });
    try std.testing.expect(session.rename != null);
    session.handleRenameKey(.{ .key = .{ .key = .char, .codepoint = 'h' } });
    session.handleRenameKey(.{ .key = .{ .key = .char, .codepoint = 'i' } });
    session.handleRenameKey(.{ .key = .{ .key = .enter } });
    try std.testing.expect(session.rename == null);
    try std.testing.expectEqualStrings("hi", tab.custom_name.?);

    // 2) 취소: 시작 시 현재 이름으로 시드 → 'x' 추가 → Esc → custom_name 그대로("hi").
    session.startRename(.{ .workspace = tab });
    try std.testing.expectEqualStrings("hi", session.rename_input.query.items);
    session.handleRenameKey(.{ .key = .{ .key = .char, .codepoint = 'x' } });
    session.handleRenameKey(.{ .key = .{ .key = .escape } });
    try std.testing.expect(session.rename == null);
    try std.testing.expectEqualStrings("hi", tab.custom_name.?);

    // 3) 빈 텍스트 확정 → custom_name 지워짐(null = 이름 없음).
    session.startRename(.{ .workspace = tab });
    session.handleRenameKey(.{ .key = .{ .key = .backspace } });
    session.handleRenameKey(.{ .key = .{ .key = .backspace } });
    session.handleRenameKey(.{ .key = .{ .key = .enter } });
    try std.testing.expect(tab.custom_name == null);

    // 4) Term rename 중 그 Term을 닫으면 rename이 자동 취소된다(destroyTerm 무효화 — stale 포인터/UAF 방지).
    //    pane에 Term을 하나 더 만들어 닫기가 Term 단위로 끝나게(cascade로 세션 종료 latch를 안 치게) 한다.
    session.newTermInActivePane() catch {};
    session.focusTerm(0); // 첫 Term을 활성으로
    const term0 = session.activePane().activeTerm();
    session.startRename(.{ .term = term0 });
    try std.testing.expect(session.rename != null);
    session.closeActiveTermOrPane(); // 활성(term0) 닫힘 → destroyTerm(term0) → rename null
    try std.testing.expect(session.rename == null);
}

// 더블클릭(kind 4) 트리거(PR4): Term 탭·사이드바 슬롯을 더블클릭하면 그 대상 rename이 시작되는지 — 실 init/
// resize/좌표 hit-test라 macOS 게이트. (kind 1=단일 클릭은 전환·포커스만, 단어 선택은 터미널 영역 kind 4로 폴백.)
test "double-click on a Term tab or sidebar slot starts rename" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    // ① Term 탭 더블클릭 → 그 Term rename(단일 pane, custom_name 없어 라벨 세그먼트 없음 → 탭이 바 좌단부터).
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const bar = session.paneBarRect(lr.items[0].rect).?;
    const term0 = session.activePane().activeTerm();
    session.mouse(4, @floatFromInt(bar.x + 4), @floatFromInt(bar.y + 1), 0, 0);
    try std.testing.expect(session.renamingTerm(term0));
    session.closeRename();

    // ② 사이드바 슬롯 더블클릭 → 그 워크스페이스 rename.
    const tab = session.activeTab();
    const sx = @as(f64, @floatFromInt(session.sidebar_width_px)) * 0.5;
    const sy = @as(f64, @floatFromInt(session.sidebar_header_height_px)) + @as(f64, @floatFromInt(session.sidebar_slot_height_px)) * 0.5; // 슬롯 0 중앙(상단 헤더 아래)
    session.mouse(4, sx, sy, 0, 0);
    try std.testing.expect(session.renamingWorkspace(tab));
    session.closeRename();
}

// 우클릭 컨텍스트 메뉴(PR5): Term 탭 우클릭 → 메뉴 열림 + 대상 세팅, 항목(Rename) 클릭 → 메뉴 닫힘 + 그 대상
// rename 시작. 터미널 본문 우클릭 → 메뉴 안 열림(대상 없음). 실 좌표 hit-test라 macOS 게이트.
test "right-click opens context menu on a rename target; clicking Rename starts rename" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const bar = session.paneBarRect(lr.items[0].rect).?;
    const term0 = session.activePane().activeTerm();

    // ① Term 탭 우클릭(button==2) → 메뉴 열림 + 대상 = term0(아직 rename 아님 — 메뉴만).
    session.mouse(1, @floatFromInt(bar.x + 4), @floatFromInt(bar.y + 1), 2, 0);
    try std.testing.expect(session.chrome_host.context_menu.open);
    try std.testing.expect(session.rename == null);

    // ② 메뉴 항목(Rename, 행 0)을 좌클릭 → 메뉴 닫힘 + term0 rename 시작. anchor = 우클릭 px(작아서 clamp 없음).
    const mx: f64 = @floatFromInt(session.chrome_host.context_menu.anchor_x + 1);
    const my: f64 = @floatFromInt(session.chrome_host.context_menu.anchor_y + 1);
    session.mouse(1, mx, my, 0, 0);
    try std.testing.expect(!session.chrome_host.context_menu.open);
    try std.testing.expect(session.renamingTerm(term0));
    session.closeRename();

    // ③ 터미널 본문(바 아래) 우클릭 → 대상 없음 → 메뉴 안 열림.
    session.mouse(1, @floatFromInt(bar.x + 4), @floatFromInt(bar.y + bar.h + 5), 2, 0);
    try std.testing.expect(!session.chrome_host.context_menu.open);
}

// rename caret 깜빡임(blink_visible로 '|'↔공백, 폭 고정)과 IME 후보창 caret rect(편집기 위치 추적)를 고정한다.
test "rename caret blinks (width-stable) and IME caret rect tracks the editor, not the terminal cursor" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    const term0 = session.activePane().activeTerm();
    session.startRename(.{ .term = term0 });
    session.handleRenameKey(.{ .key = .{ .key = .char, .codepoint = 'h' } });
    session.handleRenameKey(.{ .key = .{ .key = .char, .codepoint = 'i' } });

    // 깜빡임: blink_visible면 '|', 아니면 공백으로 끝난다 — 두 표시폭이 같아야(폭 흔들림 없음).
    session.blink_visible = true;
    const on = try session.renameEditText(allocator);
    defer allocator.free(on);
    session.blink_visible = false;
    const off = try session.renameEditText(allocator);
    defer allocator.free(off);
    try std.testing.expect(std.mem.endsWith(u8, on, "hi|"));
    try std.testing.expect(std.mem.endsWith(u8, off, "hi ")); // 공백 caret
    try std.testing.expectEqual(on.len, off.len); // 폭 고정

    // IME caret rect: rename 활성이면 imeCursorRect가 편집기 caret(탭 바 영역, 화면 상단)에서 난다 — 터미널 본문
    // (바 아래)이 아니다. renameCaretRect와 일치.
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const bar = session.paneBarRect(lr.items[0].rect).?;
    const term_body = session.paneTermRect(lr.items[0].rect);
    const cr = session.renameCaretRect() orelse return error.NoCaret;
    try std.testing.expectEqual(@as(u32, session.cell_width_px), cr.w);
    try std.testing.expect(@as(u32, @intCast(cr.y)) >= bar.y and @as(u32, @intCast(cr.y)) < term_body.y); // 탭 바 안(본문 위)
    const ime = session.imeCursorRect();
    try std.testing.expectEqual(@as(f64, @floatFromInt(cr.y)), ime.y); // imeCursorRect가 rename caret을 씀
    session.closeRename();
}

// 코드리뷰 수정 고정: (#7) 포커스 상실 시 rename 확정, (#2) 터미널 본문 우클릭은 consume 안 하고 mouse-reporting으로
// 흘림(트래킹 앱 보존), (#8) 사이드바 ✕(close) zone은 rename 대상 아님.
test "review fixes: focus-loss commits rename, body right-click reports, close-zone excluded" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    const term0 = session.activePane().activeTerm();

    // (#7) rename 중 setFocused(false) → 확정(custom_name 기록, 편집기 닫힘).
    session.startRename(.{ .term = term0 });
    session.handleRenameKey(.{ .key = .{ .key = .char, .codepoint = 'z' } });
    session.setFocused(false);
    try std.testing.expect(session.rename == null);
    try std.testing.expectEqualStrings("z", term0.surface.custom_name.?);

    // (#8) 사이드바 슬롯 ✕(close) zone은 renameTargetAt가 null(닫기 자리에서 rename 방지), 좌측은 워크스페이스.
    const slot_y = @as(f64, @floatFromInt(session.sidebar_header_height_px)) + @as(f64, @floatFromInt(session.sidebar_slot_height_px)) * 0.5; // 슬롯 0 중앙(상단 헤더 아래)
    const close_x = @as(f64, @floatFromInt(session.sidebar_width_px - session.cell_width_px)); // 우측 ✕ 영역
    try std.testing.expect(session.renameTargetAt(close_x, slot_y) == null);
    try std.testing.expect(session.renameTargetAt(@floatFromInt(session.cell_width_px), slot_y) != null); // 좌측=워크스페이스

    // (#2) mouse_tracking 켠 상태에서 터미널 본문 우클릭(button==2) → 메뉴 안 열림 + reporting 경로 도달
    //      (drag_autoscroll/selecting 리셋이 그 증거). 가드가 본문을 consume하면(회귀) 리셋 안 됨.
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const body = session.paneTermRect(lr.items[0].rect);
    session.activeSurface().core.mouse_tracking = .normal;
    session.drag_autoscroll = 1;
    session.mouse_drag_selecting = true;
    session.mouse(1, @floatFromInt(body.x + 10), @floatFromInt(body.y + 10), 2, 0); // 본문 우클릭
    try std.testing.expect(!session.chrome_host.context_menu.open); // 메뉴 안 열림(본문엔 대상 없음)
    try std.testing.expectEqual(@as(i8, 0), session.drag_autoscroll); // reporting 경로 도달(=consume 안 함)
    try std.testing.expect(!session.mouse_drag_selecting);
}

test "synchronized output(2026) hold: ESU 누락 시 sync_timeout_ticks를 넘으면 강제 투영(freeze 복구)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실제 CoreText frame builder 경로
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // controlled 출력이 멎을 때까지 tick한다 — 이후 output_events=0이라 우리가 세팅한 metal_dirty가 유지된다.
    var i: usize = 0;
    while (i < 150) : (i += 1) _ = try session.tick();

    // BSU 상황 모사: 활성 surface가 sync로 진입하고 누적 출력(metal_dirty)이 한 프레임 대기 중.
    session.activeSurface().core.sync_output = true;
    session.metal_dirty = true;
    session.sync_hold_ticks = 0;
    // timeout 직전(29틱)까지는 sync가 투영을 막아 metal_dirty가 false로 안 풀리고 누적된다(투영 판정엔
    // metal_dirty를 본다 — generation은 blink 토글로 따로 올라 투영 여부의 지표가 못 된다).
    var k: usize = 0;
    while (k + 1 < sync_timeout_ticks) : (k += 1) _ = try session.tick();
    try std.testing.expect(session.metal_dirty); // 아직 hold(투영 skip)
    try std.testing.expectEqual(sync_timeout_ticks - 1, session.sync_hold_ticks);

    // timeout 도달 tick에서 sync_active여도 강제 투영 → metal_dirty가 풀린다(ESU 없이 freeze 해제).
    _ = try session.tick();
    try std.testing.expect(!session.metal_dirty);

    // ESU 모사: sync가 꺼지면 다음 tick에 hold 카운터가 0으로 리셋된다.
    session.activeSurface().core.sync_output = false;
    _ = try session.tick();
    try std.testing.expectEqual(@as(u32, 0), session.sync_hold_ticks);
}

test "chrome_minimal session suppresses the pane tab bar and the sidebar" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // refreshCellMetrics가 CoreText 메트릭 경로
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
        .chrome_minimal = 1,
    });
    defer session.deinit();

    // minimal: 사이드바 폭 0(refreshCellMetrics 게이트), 탭 바 높이 0(paneBarHeightPx 게이트) →
    // paneBarRect가 null, paneTermRect는 바를 빼지 않는다. window padding은 0으로 격리해 바 기하만 본다
    // (paneTermRect가 이제 padding도 inset — minimal grid의 padding 동작은 별도 테스트가 커버).
    session.window_padding_px = .{};
    try std.testing.expectEqual(@as(u32, 0), session.sidebar_width_px);
    try std.testing.expectEqual(@as(u32, 0), session.paneBarHeightPx());
    const rect: app.SplitRect = .{ .x = 0, .y = 0, .w = 800, .h = 600 };
    try std.testing.expect(session.paneBarRect(rect) == null);
    const term = session.paneTermRect(rect);
    try std.testing.expectEqual(@as(u32, 0), term.y);
    try std.testing.expectEqual(@as(u32, 600), term.h);
}

test "minimal scratch session blocks new_tab/new_term; minimal_tabs re-enables them" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY spawn(newTab/newTermInActivePane)
    const allocator = std.testing.allocator;

    // ① chrome_minimal + minimal_tabs=0(기본 스크래치): 탭/Term 생성 액션이 무동작.
    {
        const session = try allocator.create(AppSession);
        defer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = abi_version,
            .cols = 20,
            .rows = 5,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(CommandKind.controlled_smoke),
            .chrome_minimal = 1,
            .minimal_tabs = 0,
        });
        defer session.deinit();
        try std.testing.expect(session.tabsBlocked());
        try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
        try std.testing.expectEqual(@as(usize, 1), session.activePane().terms.items.len);
        session.dispatchAppAction(.new_tab);
        session.dispatchAppAction(.new_term);
        try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len); // 새 워크스페이스 안 생김
        try std.testing.expectEqual(@as(usize, 1), session.activePane().terms.items.len); // 새 Term 안 생김
    }

    // ② chrome_minimal + minimal_tabs=1: 탭/Term 생성이 다시 동작.
    {
        const session = try allocator.create(AppSession);
        defer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = abi_version,
            .cols = 20,
            .rows = 5,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(CommandKind.controlled_smoke),
            .chrome_minimal = 1,
            .minimal_tabs = 1,
        });
        defer session.deinit();
        try std.testing.expect(!session.tabsBlocked());
        session.dispatchAppAction(.new_term); // 활성 pane에 Term 추가
        try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
        session.dispatchAppAction(.new_tab); // 새 워크스페이스
        try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);
    }
}

test "minimal tab indicator: adaptive dots appear only in minimal with >1 tab" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // refreshCellMetrics(cell_width_px) + 실 PTY
    const allocator = std.testing.allocator;
    var out: std.ArrayList(metal_frame.NativeMetalCell) = .empty;
    defer out.deinit(allocator);

    // ① minimal + minimal_tabs: 단일이면 무동작, Term 2개면 strip+점2개(활성=마지막에 그려진 셀).
    {
        const session = try allocator.create(AppSession);
        defer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = abi_version,
            .cols = 40,
            .rows = 5,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(CommandKind.controlled_smoke),
            .chrome_minimal = 1,
            .minimal_tabs = 1,
        });
        defer session.deinit();
        _ = try session.resize(800, 600, 1000); // backing 폭을 잡아야 termRect.w>0(인디케이터 폭 계산)

        out.clearRetainingCapacity();
        session.appendMinimalTabIndicator(&out);
        try std.testing.expectEqual(@as(usize, 0), out.items.len); // 탭 1개 → 점 없음

        session.dispatchAppAction(.new_term); // Term 2개(새 Term이 활성 = index 1)
        out.clearRetainingCapacity();
        session.appendMinimalTabIndicator(&out);
        try std.testing.expectEqual(@as(usize, 3), out.items.len); // strip + 점 2개
        try std.testing.expectEqual(session.sidebarBg(), out.items[0].background); // strip
        try std.testing.expectEqual(session.sidebarHoverBg(), out.items[1].background); // 비활성 점(i=0)
        try std.testing.expectEqual(session.sidebarActiveBg(), out.items[2].background); // 활성 점(i=1)
        // 점은 strip 안에서 우상단(row 0), 활성 점이 비활성보다 오른쪽(+2칸).
        try std.testing.expectEqual(@as(u16, 0), out.items[2].row);
        try std.testing.expectEqual(out.items[1].col + 2, out.items[2].col);

        // 워크스페이스가 여러 개면 그쪽을 우선 표시(차원 전환). 새 워크스페이스 = 활성 index 1.
        session.dispatchAppAction(.new_tab);
        out.clearRetainingCapacity();
        session.appendMinimalTabIndicator(&out);
        try std.testing.expectEqual(@as(usize, 3), out.items.len); // 워크스페이스 2개 → strip + 점 2개
        try std.testing.expectEqual(session.sidebarActiveBg(), out.items[2].background); // 활성 워크스페이스(index 1)

        // band가 화면보다 넓으면(아주 좁은 패널) 아예 안 그린다 — 좌상단 relocate 방지(우상단에 안 들어가면 skip).
        _ = try session.resize(16, 200, 1000); // 폭 16px → cols ≤ 2, band(2 워크스페이스=5)+margin > cols
        out.clearRetainingCapacity();
        session.appendMinimalTabIndicator(&out);
        try std.testing.expectEqual(@as(usize, 0), out.items.len);
    }

    // ② full(chrome_minimal=0): 탭이 여러 개여도 인디케이터 없음(사이드바·탭 바가 보여줌).
    {
        const session = try allocator.create(AppSession);
        defer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = abi_version,
            .cols = 40,
            .rows = 5,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(CommandKind.controlled_smoke),
            .chrome_minimal = 0,
        });
        defer session.deinit();
        session.dispatchAppAction(.new_term); // Term 2개(full은 게이트 없음)
        try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
        out.clearRetainingCapacity();
        session.appendMinimalTabIndicator(&out);
        try std.testing.expectEqual(@as(usize, 0), out.items.len); // full → 무동작
    }
}

test "minimal active pane border: 4 edges only in minimal split" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // refreshCellMetrics(cell 메트릭)
    const allocator = std.testing.allocator;
    var out: std.ArrayList(metal_frame.NativeMetalCell) = .empty;
    defer out.deinit(allocator);
    const rect: app.SplitRect = .{ .x = 0, .y = 0, .w = 400, .h = 600 };

    // ① minimal: 단일 pane이면 무동작, split(>1)이면 4변 테두리(reserved 2/3/4/5)·색=sidebarActiveBg.
    {
        const session = try allocator.create(AppSession);
        defer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = abi_version,
            .cols = 40,
            .rows = 5,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(CommandKind.controlled_smoke),
            .chrome_minimal = 1,
        });
        defer session.deinit();
        _ = try session.resize(800, 600, 1000);

        out.clearRetainingCapacity();
        session.appendActivePaneBorder(&out, rect, 1); // 단일 pane
        try std.testing.expectEqual(@as(usize, 0), out.items.len);

        out.clearRetainingCapacity();
        session.appendActivePaneBorder(&out, rect, 2); // split
        try std.testing.expect(out.items.len >= 6); // 좌/우(행마다 2) + 상/하 2
        // 4변이 모두 그려졌는지(reserved 2=하·3=좌·4=상·5=우 전부 등장) + 색은 focus accent.
        var seen = [_]bool{false} ** 6;
        for (out.items) |c| {
            try std.testing.expectEqual(session.sidebarActiveBg(), c.background);
            if (c.reserved < seen.len) seen[c.reserved] = true;
        }
        try std.testing.expect(seen[2] and seen[3] and seen[4] and seen[5]);
    }

    // ② full(chrome_minimal=0): split이어도 테두리 없음(탭 바 하이라이트가 활성 pane을 보여줌).
    {
        const session = try allocator.create(AppSession);
        defer allocator.destroy(session);
        try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
            .abi_version = abi_version,
            .cols = 40,
            .rows = 5,
            .queue_capacity = 16,
            .command_kind = @intFromEnum(CommandKind.controlled_smoke),
            .chrome_minimal = 0,
        });
        defer session.deinit();
        _ = try session.resize(800, 600, 1000);
        out.clearRetainingCapacity();
        session.appendActivePaneBorder(&out, rect, 2);
        try std.testing.expectEqual(@as(usize, 0), out.items.len); // full → 무동작
    }
}

test "command catalog: 엔트리·바인딩 표시 + runAction 디스패치" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 init(loaded_config resolver) + PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    const catalog = session.commandCatalog();
    try std.testing.expectEqual(command_catalog.entries.len, catalog.len);
    // new_term 엔트리: 제목 + 빌트인 Cmd+T 바인딩 표시. close_tab: 기본 바인딩 없어 빈 표시.
    var saw_new_term = false;
    var saw_close_tab = false;
    for (catalog) |e| {
        const key = std.mem.span(e.action_key);
        if (std.mem.eql(u8, key, "new_term")) {
            try std.testing.expectEqualStrings("New Terminal", std.mem.span(e.title));
            try std.testing.expectEqualStrings("⌘T", std.mem.span(e.key_display));
            try std.testing.expectEqualStrings("t", std.mem.span(e.key_equivalent)); // NSMenuItem keyEquivalent
            try std.testing.expectEqual(command_catalog.mod_command, e.key_modifiers);
            saw_new_term = true;
        } else if (std.mem.eql(u8, key, "close_tab")) {
            try std.testing.expectEqualStrings("", std.mem.span(e.key_display)); // 기본 바인딩 없음
            try std.testing.expectEqualStrings("", std.mem.span(e.key_equivalent));
            try std.testing.expectEqual(@as(u32, 0), e.key_modifiers);
            saw_close_tab = true;
        }
    }
    try std.testing.expect(saw_new_term and saw_close_tab);

    // runAction: new_term → 활성 pane Term +1(full 세션이라 tabsBlocked=false). 모르는 키는 false·무동작.
    try std.testing.expectEqual(@as(usize, 1), session.activePane().terms.items.len);
    try std.testing.expect(session.runAction("new_term"));
    try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
    try std.testing.expect(!session.runAction("bogus_action"));
    try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
}

test "command palette(chrome): 토글 열림 → 타이핑 필터 → IME 조합 표시 → Enter 디스패치+닫힘 → 프레임 빌드" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // buildChromeOverlayFrame=CoreText, 실 PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000); // 메트릭·backing(palette.view가 chrome props로 씀)

    // 토글로 열린다(chrome palette 컴포넌트) — 빈 쿼리라 전체 카탈로그가 필터에(platform palette_filtered).
    try std.testing.expect(!session.chrome_host.palette.open);
    session.dispatchAppAction(.toggle_command_palette);
    try std.testing.expect(session.chrome_host.palette.open);
    try std.testing.expectEqual(command_catalog.entries.len, session.palette_filtered.items.len);
    try std.testing.expectEqual(command_catalog.entries.len, session.chrome_host.palette.result_count); // 컴포넌트 동기화

    // IME 조합 회귀(C1b 버그 수정): 팝업 열린 동안 marked text가 팝업 preedit에 들어간다(뒤의 터미널 core가 아니라).
    // 레거시 팝업은 IME 조합 배선이 없어 한글 조합이 숨은 터미널로 샜다.
    session.imeMarked("\xea\xb0\x80"); // 조합 중 "가"
    try std.testing.expectEqualStrings("\xea\xb0\x80", session.chrome_host.palette.input.preedit.items);
    try std.testing.expect(session.activeSurface().core.preedit == null); // 터미널 core로 안 샌다
    session.imeMarked(""); // 조합 해제(확정 직전)

    // "new t" 타이핑(chrome 라우팅 → palette.handle → query_changed → recomputePalette) → "New Terminal"만 남는다.
    for ("new t") |c| _ = try session.handleKeyEvent(.{ .key = .{ .char = c }, .modifiers = .{} });
    try std.testing.expectEqual(@as(usize, 1), session.palette_filtered.items.len);
    try std.testing.expect(command_palette.actionAt(session.palette_filtered.items, session.chrome_host.palette.selected).? == .new_term);

    // Enter → accept → acceptPalette가 new_term 실행(full이라 게이트 없음) 후 닫힘. 활성 pane Term +1.
    const before = session.activePane().terms.items.len;
    _ = try session.handleKeyEvent(.{ .key = .enter, .modifiers = .{} });
    try std.testing.expect(!session.chrome_host.palette.open);
    try std.testing.expectEqual(before + 1, session.activePane().terms.items.len);

    // 다시 열고 Esc로 닫힌다.
    session.dispatchAppAction(.toggle_command_palette);
    try std.testing.expect(session.chrome_host.palette.open);
    _ = try session.handleKeyEvent(.{ .key = .escape, .modifiers = .{} });
    try std.testing.expect(!session.chrome_host.palette.open);

    // 열린 상태에서 chrome 오버레이 프레임 빌드가 크래시 없이 셀을 낸다(palette.view → 일반 rasterizer).
    session.dispatchAppAction(.toggle_command_palette);
    var pf = try session.buildChromeOverlayFrame();
    defer pf.frame.deinit(allocator);
    try std.testing.expect(pf.frame.draw_list.cells.len > 0);

    // 회귀(메뉴 모달 우회): 팝업이 열린 동안 메뉴바 keyEquivalent 경로(runAction)는 무시된다 — 모달 뒤 터미널이
    // 조작되면 안 된다. (팝업 자신의 Enter는 chrome_host.handleInput → dispatchChromeAction이 처리하므로 별개.)
    try std.testing.expect(session.chrome_host.palette.open);
    const terms_before_runaction = session.activePane().terms.items.len;
    try std.testing.expect(!session.runAction("new_term"));
    try std.testing.expectEqual(terms_before_runaction, session.activePane().terms.items.len);

    // caret 깜빡임: 팝업이 열린 프레임을 tick으로 빌드하면 cursor_cells=1(팝업 입력 caret이 맨 끝 suffix) — 이제
    // caret이 터미널 커서와 같은 suffix-trim 깜빡임을 탄다. (예전엔 0으로 고정해 정적이었음 — caret 깜빡임 추가로 변경.)
    _ = try session.tick();
    try std.testing.expectEqual(@as(usize, 1), session.metal_buffer.cursor_cells);
}

test "scrollback find(chrome): 토글 열림 → 증분 검색 → 매치 네비게이션 → 하이라이트·오버레이 프레임" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // buildChromeOverlayFrame=CoreText, 실 PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 6,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000); // 메트릭·backing(find.view가 chrome props로 씀)

    // 검색 대상 텍스트를 코어에 직접 쓴다(유니크 토큰 2곳 — 셸 출력과 충돌 없게).
    try session.activeSurface().core.write("MARUFIND one\r\ntwo MARUFIND three");

    // 토글로 열린다(chrome find 컴포넌트) — 빈 검색어라 매치 0. 매치 리스트는 session(find_matches) 소유.
    try std.testing.expect(!session.chrome_host.find.open);
    session.dispatchAppAction(.toggle_find);
    try std.testing.expect(session.chrome_host.find.open);
    try std.testing.expectEqual(@as(usize, 0), session.find_matches.items.len);

    // "MARUFIND" 타이핑(chrome 라우팅 → find.handle → query_changed → recomputeFind) → 2곳 매치, 현재는 첫 매치.
    for ("MARUFIND") |c| _ = try session.handleKeyEvent(.{ .key = .{ .char = c }, .modifiers = .{} });
    try std.testing.expectEqual(@as(usize, 2), session.find_matches.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.chrome_host.find.match_count); // 컴포넌트 카운트 동기화
    try std.testing.expectEqual(@as(usize, 0), session.chrome_host.find.current);

    // Enter=다음 매치, Shift+Enter=이전(wrap). 모디파이어가 chrome.input으로 매핑돼 Shift가 prev로 간다.
    _ = try session.handleKeyEvent(.{ .key = .enter, .modifiers = .{} });
    try std.testing.expectEqual(@as(usize, 1), session.chrome_host.find.current);
    _ = try session.handleKeyEvent(.{ .key = .enter, .modifiers = .{ .shift = true } });
    try std.testing.expectEqual(@as(usize, 0), session.chrome_host.find.current);

    // Backspace로 한 글자 지워도("MARUFIN") 부분일치라 두 곳 다 매치 유지.
    _ = try session.handleKeyEvent(.{ .key = .backspace, .modifiers = .{} });
    try std.testing.expectEqual(@as(usize, 2), session.find_matches.items.len);

    // chrome 오버레이 프레임 빌드가 크래시 없이 셀을 낸다(find.view → 일반 rasterizer: "Find: …" + 카운터).
    var ff = try session.buildChromeOverlayFrame();
    defer ff.frame.deinit(allocator);
    try std.testing.expect(ff.frame.draw_list.cells.len > 0);

    // 회귀: Find 열린 동안 메뉴 keyEquivalent(runAction)는 무시된다(모달 뒤 터미널 조작 차단).
    try std.testing.expect(!session.runAction("new_term"));

    // tick으로 Find 열린 프레임을 빌드하면 cursor_cells=1(Find 입력 caret이 맨 끝 suffix) — caret이 터미널 커서와
    // 같은 suffix-trim 깜빡임을 탄다(예전엔 0 고정으로 정적이었음 — caret 깜빡임 추가로 변경).
    _ = try session.tick();
    try std.testing.expectEqual(@as(usize, 1), session.metal_buffer.cursor_cells);

    // ⌘+글자는 검색어에 안 쌓고 닫는다(평문만 입력) — 위 흐름에서 find가 아직 열려 있다.
    try std.testing.expect(session.chrome_host.find.open);
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'c' }, .modifiers = .{ .command = true } });
    try std.testing.expect(!session.chrome_host.find.open);

    // 다시 열고 Esc로 닫힌다.
    session.dispatchAppAction(.toggle_find);
    try std.testing.expect(session.chrome_host.find.open);
    _ = try session.handleKeyEvent(.{ .key = .escape, .modifiers = .{} });
    try std.testing.expect(!session.chrome_host.find.open);
}

test "find ⌘G/⌘⇧G: 오버레이 닫힌 채 다음/이전 매치 네비(보존 검색어 재검색·타이핑이 종료)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY(controlled_smoke)
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 6,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000);
    try session.activeSurface().core.write("MARUFIND one\r\ntwo MARUFIND three\r\nMARUFIND four"); // 3곳 매치

    // 검색: 열고 타이핑 → 3곳 매치, 현재 0.
    session.dispatchAppAction(.toggle_find);
    for ("MARUFIND") |c| _ = try session.handleKeyEvent(.{ .key = .{ .char = c }, .modifiers = .{} });
    try std.testing.expectEqual(@as(usize, 3), session.find_matches.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.chrome_host.find.current);

    // Esc로 닫기 — 매치 정리, 검색어 보존, find_nav false.
    _ = try session.handleKeyEvent(.{ .key = .escape, .modifiers = .{} });
    try std.testing.expect(!session.chrome_host.find.open);
    try std.testing.expectEqual(@as(usize, 0), session.find_matches.items.len);
    try std.testing.expect(!session.find_nav);
    try std.testing.expect(session.chrome_host.find.input.query.items.len > 0); // 검색어 보존(hide는 안 비움)

    // ⌘G(닫힌 채): 보존 검색어로 재검색 + 다음 매치(0→1) + find_nav 세움.
    session.dispatchAppAction(.find_next);
    try std.testing.expect(session.find_nav);
    try std.testing.expectEqual(@as(usize, 3), session.find_matches.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.chrome_host.find.current);
    try std.testing.expect(!session.chrome_host.find.open); // 오버레이는 여전히 닫힘

    // ⌘G 두 번 더 → 2 → 0(wrap).
    session.dispatchAppAction(.find_next);
    try std.testing.expectEqual(@as(usize, 2), session.chrome_host.find.current);
    session.dispatchAppAction(.find_next);
    try std.testing.expectEqual(@as(usize, 0), session.chrome_host.find.current);

    // ⌘⇧G(이전) → 2(뒤로 wrap).
    session.dispatchAppAction(.find_previous);
    try std.testing.expectEqual(@as(usize, 2), session.chrome_host.find.current);

    // 닫힌 채 네비 중 tick 프레임 빌드가 크래시 없이 동작(현재 매치만 하이라이트 — cell_colors 경로).
    _ = try session.tick();

    // 셸에 타이핑 재개 = 검색 종료 → find_nav 해제 + 매치 정리.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'x' }, .modifiers = .{} });
    try std.testing.expect(!session.find_nav);
    try std.testing.expectEqual(@as(usize, 0), session.find_matches.items.len);

    // 빈 검색어면 ⌘G 무동작(새로 열어 show가 검색어를 비우고, 닫은 뒤 find_next).
    session.dispatchAppAction(.toggle_find); // show → query clear
    _ = try session.handleKeyEvent(.{ .key = .escape, .modifiers = .{} });
    session.dispatchAppAction(.find_next);
    try std.testing.expect(!session.find_nav); // 검색어 없음 — 무동작
}

test "alt screen에선 maru Find를 끈다(⌘F 무동작·⌘G 무동작·열린 채 진입 시 tick이 닫음)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 6,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000);

    // 메인 화면: ⌘F가 Find를 연다(정상).
    session.dispatchAppAction(.toggle_find);
    try std.testing.expect(session.chrome_host.find.open);
    session.dispatchAppAction(.toggle_find); // 닫기
    try std.testing.expect(!session.chrome_host.find.open);

    // alt screen 진입(DECSET 1049 — vim/less).
    try session.activeSurface().core.write("\x1b[?1049h");
    try std.testing.expect(session.activeSurface().core.alt_active);

    // alt에선 ⌘F가 Find를 안 연다(앱 자체 검색에 맡김 — iTerm2 관례).
    session.dispatchAppAction(.toggle_find);
    try std.testing.expect(!session.chrome_host.find.open);
    // alt에선 ⌘G(findNavigate)도 무동작(find_nav 안 켜짐).
    session.dispatchAppAction(.find_next);
    try std.testing.expect(!session.find_nav);

    // 엣지: 메인에서 Find를 연 뒤 앱이 출력으로 alt에 들어가면 tick이 Find를 닫는다.
    try session.activeSurface().core.write("\x1b[?1049l"); // 메인 복귀
    try std.testing.expect(!session.activeSurface().core.alt_active);
    session.dispatchAppAction(.toggle_find);
    try std.testing.expect(session.chrome_host.find.open); // 메인에선 열림
    try session.activeSurface().core.write("\x1b[?1049h"); // 앱이 alt 진입
    _ = try session.tick();
    try std.testing.expect(!session.chrome_host.find.open); // tick이 닫음
}

test "find IME 멀티-문자: 커밋이 다음 조합 preedit를 안 지운다(조합 안 보임 회귀)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // handleKeyEvent → chrome 라우팅, 실 PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 6,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000);

    session.dispatchAppAction(.toggle_find);
    try std.testing.expect(session.chrome_host.find.open);

    // 실제 IME 흐름(라이브 로그와 동일): setMarkedText "나" → insertText "나"(커밋) → setMarkedText "다"(다음 조합).
    // 한 keyDown 트랜잭션 안에서 일어난다.
    session.imeBegin();
    session.imeMarked("\xeb\x82\x98"); // 조합 "나"
    session.imeInsert("\xeb\x82\x98"); // "나" 커밋 누적
    session.imeMarked("\xeb\x8b\xa4"); // 다음 조합 "다"
    session.imeEnd(null);

    // 커밋 "나"는 검색어로, 조합 "다"는 preedit로 **유지**돼야 한다. 예전엔 imeEnd의 커밋(appendChar)이 방금 set된
    // "다"를 지워 조합이 화면에서 사라졌다(사용자 제보 "입력중 상태 안 보임"). 단일 출처·core 모델 통일로 수정.
    try std.testing.expectEqualStrings("\xeb\x82\x98", session.chrome_host.find.input.query.items); // "나" 확정
    try std.testing.expectEqualStrings("\xeb\x8b\xa4", session.chrome_host.find.input.preedit.items); // "다" 조합 유지
}

test "오버레이 배타 + IME 단일 출처: showNotice가 find/palette를 닫고 notice가 최우선(IME 무시)·toggle이 notice를 닫음" {
    // 경량 — show/toggle·inputFocus·IME 헬퍼만 탄다(CoreText/PTY 불필요). undefined 세션은 이들이 읽는 필드만 초기화.
    var session: AppSession = undefined;
    session.allocator = std.testing.allocator;
    session.chrome_host = .{}; // inputFocus가 notice/find/palette.open을 읽음([[devsession-undefined-test-field-trap]])
    session.rename = null; // inputFocus가 rename을 읽음([[devsession-undefined-test-field-trap]])
    session.find_matches = .empty; // toggleFind/showNotice가 clearRetainingCapacity 호출
    session.palette_filtered = .empty; // togglePalette→recomputePalette가 채운다
    session.metal_dirty = false;
    defer {
        session.chrome_host.deinit(std.testing.allocator);
        session.find_matches.deinit(std.testing.allocator);
        session.palette_filtered.deinit(std.testing.allocator);
    }

    // 오버레이 없음 → terminal
    try std.testing.expectEqual(AppSession.InputFocus.terminal, session.inputFocus());

    // find 열림 → .find
    session.toggleFind();
    try std.testing.expect(session.chrome_host.find.open);
    try std.testing.expectEqual(AppSession.InputFocus.find, session.inputFocus());

    // showNotice가 find를 닫는다(#2 배타) — notice가 최우선 포커스(#3)
    session.showNotice("corrupt");
    try std.testing.expect(session.chrome_host.notice.open);
    try std.testing.expect(!session.chrome_host.find.open); // #2: 두 박스가 합쳐진 frame으로 안 깨짐
    try std.testing.expectEqual(AppSession.InputFocus.notice, session.inputFocus()); // #3: 최우선
    // #3: notice 중 IME 연산은 무시 — 조합이 뒤(find/터미널)로 새지 않는다
    session.imeSetPreedit("\xea\xb0\x80"); // "가"
    try std.testing.expect(!session.imeComposingActive());

    // toggleFind가 notice를 닫는다(#2)
    session.toggleFind();
    try std.testing.expect(!session.chrome_host.notice.open); // #2
    try std.testing.expect(session.chrome_host.find.open);

    // togglePalette가 notice·find를 닫는다(#2) → palette 포커스
    session.showNotice("corrupt2");
    try std.testing.expect(!session.chrome_host.find.open); // showNotice가 find도 닫음
    session.togglePalette();
    try std.testing.expect(!session.chrome_host.notice.open); // #2
    try std.testing.expect(session.chrome_host.palette.open);
    try std.testing.expectEqual(AppSession.InputFocus.palette, session.inputFocus());
}

test "imeBegin: 터미널 포커스만 바닥으로 스냅 — find 조합은 뒤 터미널 스크롤백을 보존(#4)" {
    var session: AppSession = undefined;
    session.allocator = std.testing.allocator;
    var tab_surface = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 5 });
    defer tab_surface.deinit();
    session.surface_initialized = true;
    var st_ptrs = [_]*app.Surface{&tab_surface};
    session.app_window = .{ .tabs = &st_ptrs };
    try attachTestRuntime(&session, &tab_surface);
    defer session.runtime.deinit();
    session.metal_dirty = false;
    session.chrome_host = .{}; // inputFocus가 읽음
    session.rename = null; // inputFocus가 rename을 읽음([[devsession-undefined-test-field-trap]])
    session.ime_inserted = .empty; // imeBegin이 clearRetainingCapacity 호출
    defer session.chrome_host.deinit(std.testing.allocator);
    defer session.ime_inserted.deinit(std.testing.allocator);

    // 9줄 출력 → 5행 화면 위로 4줄 스크롤백
    try tab_surface.core.write("1\r\n2\r\n3\r\n4\r\n5\r\n6\r\n7\r\n8\r\n9");
    session.scrollPage(1); // 위로 한 화면
    try std.testing.expectEqual(@as(usize, 4), tab_surface.core.view_offset);

    // (a) 터미널 포커스: imeBegin이 바닥으로 스냅한다(조합도 타이핑 — preedit이 보이게)
    session.imeBegin();
    try std.testing.expectEqual(@as(usize, 0), tab_surface.core.view_offset);

    // 다시 위로 스크롤
    session.scrollPage(1);
    try std.testing.expectEqual(@as(usize, 4), tab_surface.core.view_offset);

    // (b) find 포커스: imeBegin은 뒤 터미널을 건드리지 않는다(#4 — 조합은 find 입력칸으로 간다)
    session.chrome_host.find.open = true;
    session.imeBegin();
    try std.testing.expectEqual(@as(usize, 4), tab_surface.core.view_offset); // 보존
}

test "find overlay: 한글(wide)은 atlas slot이 2칸 — ㄱㄴㄷ 잘림 회귀 실측(실 CoreText)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // buildChromeOverlayFrame=CoreText, 실 PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 6,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    session.dispatchAppAction(.toggle_find);
    try std.testing.expect(session.chrome_host.find.open);
    // 'A'(ASCII, span 1)와 '가'(U+AC00, EAW-Wide span 2)를 같은 오버레이 frame에 그린다.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'A' }, .modifiers = .{} });
    _ = try session.handleKeyEvent(.{ .key = .{ .char = '가' }, .modifiers = .{} });

    // scale 1.0과 Retina 2.0 둘 다 검증 — 실제 맥 화면은 2.0이라 1.0만으론 라이브 경로(오버레이 셀 × scale)를
    // 못 잡는다. 같은 세션에서 resize를 반복해 공유 atlas가 두 메트릭을 함께 들었을 때도 잘림이 없는지 본다.
    for ([_]u32{ 1000, 2000 }) |scale_milli| {
        _ = try session.resize(800, 600, scale_milli);
        var ff = try session.buildChromeOverlayFrame();
        defer ff.frame.deinit(allocator);

        // caret 재활용: cursor-role fill이 **cursor 오버레이**(glyph_quad_frame.overlays의 .cursor, visible)로 lower돼야
        // 한다 — buildNativeCellsSplit이 이걸 반전-블록으로 그리고 suffix-trim으로 깜빡인다. draw_list.cursor 필드만으론
        // 안 그려진다(렌더는 overlays를 본다). 회귀: caret이 안 보이던 버그(overlays 누락) 고정.
        var has_caret = false;
        for (ff.frame.glyph_quad_frame.overlays) |ov| {
            if (ov == .cursor and ov.cursor.visible) has_caret = true;
        }
        try std.testing.expect(has_caret);

        // 실측: 결과 글리프에서 '가'와 'A'의 cell_width(span)와 atlas slot 픽셀 폭을 뽑는다.
        var ga_span: ?u2 = null;
        var ga_slot_w: u32 = 0;
        var a_slot_w: u32 = 0;
        for (ff.frame.glyph_quad_frame.glyphs) |q| {
            if (q.run.codepoint == '가') {
                ga_span = q.run.cell_width;
                ga_slot_w = q.slot.width_px;
            } else if (q.run.codepoint == 'A') {
                a_slot_w = q.slot.width_px;
            }
        }
        // 핵심: '가'는 span=2여야 하고, atlas slot이 ASCII(span 1)의 2배 폭이어야 wide 글리프가 안 잘린다.
        // slot이 1칸이면 rasterizer가 글자를 1칸에 가운데정렬+우측 클립해 왼쪽 절반(ㄱ)만 남는다.
        try std.testing.expectEqual(@as(?u2, 2), ga_span);
        try std.testing.expect(a_slot_w > 0);
        try std.testing.expectEqual(a_slot_w * 2, ga_slot_w);
    }
}

test "command palette(chrome): 한글(wide) query는 atlas slot이 2칸 — ㄱㄴㄷ 잘림 회귀 실측(실 CoreText)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // buildChromeOverlayFrame=CoreText, 실 PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 6,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    session.dispatchAppAction(.toggle_command_palette);
    try std.testing.expect(session.chrome_host.palette.open);
    // 'A'(ASCII, span 1)와 '가'(U+AC00, span 2)를 팝업 쿼리에 입력 — row0 프롬프트 "> A가"로 그려진다(필터 결과는
    // 0이어도 쿼리 글리프는 frame에 있다). C1b 전 팝업(putUtf8 span=1)이면 '가'가 1칸 slot에 잘렸다.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'A' }, .modifiers = .{} });
    _ = try session.handleKeyEvent(.{ .key = .{ .char = '가' }, .modifiers = .{} });

    // scale 1.0·Retina 2.0 둘 다(실제 맥은 2.0).
    for ([_]u32{ 1000, 2000 }) |scale_milli| {
        _ = try session.resize(800, 600, scale_milli);
        var ff = try session.buildChromeOverlayFrame();
        defer ff.frame.deinit(allocator);

        // caret 재활용: cursor-role fill이 cursor 오버레이(glyph_quad_frame.overlays의 .cursor, visible)로 lower돼 터미널
        // 커서와 같은 반전-블록 경로로 그려지고 깜빡인다(draw_list.cursor 필드만으론 안 그려짐 — 회귀 고정).
        var has_caret = false;
        for (ff.frame.glyph_quad_frame.overlays) |ov| {
            if (ov == .cursor and ov.cursor.visible) has_caret = true;
        }
        try std.testing.expect(has_caret);

        var ga_span: ?u2 = null;
        var ga_slot_w: u32 = 0;
        var a_slot_w: u32 = 0;
        for (ff.frame.glyph_quad_frame.glyphs) |q| {
            if (q.run.codepoint == '가') {
                ga_span = q.run.cell_width;
                ga_slot_w = q.slot.width_px;
            } else if (q.run.codepoint == 'A') {
                a_slot_w = q.slot.width_px;
            }
        }
        try std.testing.expectEqual(@as(?u2, 2), ga_span); // 팝업 '가'도 span=2(find와 같은 경로)
        try std.testing.expect(a_slot_w > 0);
        try std.testing.expectEqual(a_slot_w * 2, ga_slot_w); // 2칸 slot — 안 잘림
    }
}

test "rasterizeOverlayCells: 다중 fill(painter order) + 다중 행 text → 셀 그리드(헤드리스)" {
    const allocator = std.testing.allocator;
    const c = struct {
        fn rgb(r: u8, g: u8, b: u8) maru.color.Rgb {
            return .{ .r = r, .g = g, .b = b };
        }
    };
    // 2색이 구분되게 토큰을 만든다: surface_bg=(2,2,2), selection=(7,7,7).
    const tk = chrome.tokens.Tokens.tui(.{
        .foreground = c.rgb(1, 1, 1),
        .sidebar_background = c.rgb(2, 2, 2),
        .sidebar_foreground = c.rgb(3, 3, 3),
        .sidebar_active = c.rgb(4, 4, 4),
        .search_match = c.rgb(5, 5, 5),
        .search_match_current = c.rgb(6, 6, 6),
        .selection = c.rgb(7, 7, 7),
        .cursor = c.rgb(8, 8, 8),
    });
    // cw=10, ch=20. 패널 2칸×2행(0,0,20,40). row1만 selection으로 덮고(painter order), 각 행에 텍스트.
    const run_ab = [_]chrome.draw.Run{.{ .text = "ab" }};
    const run_cd = [_]chrome.draw.Run{.{ .text = "cd" }};
    const ops = [_]chrome.draw.Op{
        .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 20, .h = 40 }, .role = .surface_bg } },
        .{ .fill = .{ .rect = .{ .x = 0, .y = 20, .w = 20, .h = 20 }, .role = .selection } },
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &run_ab, .role = .surface_fg } },
        .{ .text = .{ .origin = .{ .x = 0, .y = 20 }, .runs = &run_cd, .role = .surface_fg } },
    };
    const draws = [_]chrome.ChromeDraw{.{ .layer = .modal, .ops = &ops }};

    var raster = try AppSession.rasterizeOverlayCells(allocator, &draws, &tk, 10, 20);
    defer raster.cells.deinit(allocator);
    defer raster.gpu_quads.deinit(allocator);
    defer raster.gpu_shadows.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 2), raster.cols);
    try std.testing.expectEqual(@as(u16, 2), raster.rows);
    try std.testing.expectEqual(@as(u32, 0), raster.origin_x);
    try std.testing.expectEqual(@as(u32, 0), raster.origin_y);
    try std.testing.expectEqual(@as(usize, 4), raster.cells.items.len);
    // 행 0: "ab" + surface_bg, 행 1: "cd" + selection(나중 fill이 이김).
    try std.testing.expectEqual(@as(u21, 'a'), raster.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u21, 'b'), raster.cells.items[1].codepoint);
    try std.testing.expectEqual(@as(u21, 'c'), raster.cells.items[2].codepoint);
    try std.testing.expectEqual(@as(u21, 'd'), raster.cells.items[3].codepoint);
    try std.testing.expectEqual(c.rgb(2, 2, 2), raster.cells.items[0].style.background.rgb); // row0 surface_bg
    try std.testing.expectEqual(c.rgb(7, 7, 7), raster.cells.items[2].style.background.rgb); // row1 selection(painter order)
}

test "rasterizeOverlayCells: wide 글리프 뒤 continuation 칸은 emit 안 함(배경이 글리프 안 덮게 — ㄱ 잘림 회귀)" {
    const allocator = std.testing.allocator;
    const cc = struct {
        fn rgb(r: u8, g: u8, b: u8) maru.color.Rgb {
            return .{ .r = r, .g = g, .b = b };
        }
    };
    const tk = chrome.tokens.Tokens.tui(.{
        .foreground = cc.rgb(1, 1, 1),
        .sidebar_background = cc.rgb(2, 2, 2),
        .sidebar_foreground = cc.rgb(3, 3, 3),
        .sidebar_active = cc.rgb(4, 4, 4),
        .search_match = cc.rgb(5, 5, 5),
        .search_match_current = cc.rgb(6, 6, 6),
        .selection = cc.rgb(7, 7, 7),
        .cursor = cc.rgb(8, 8, 8),
    });
    // cw=10, ch=20. 패널 4칸×1행. "가b" — '가'(wide=2칸) col0, 'b' col2. continuation 칸(col1)은 emit 안 돼야 한다.
    const run = [_]chrome.draw.Run{.{ .text = "가b" }};
    const ops = [_]chrome.draw.Op{
        .{ .fill = .{ .rect = .{ .x = 0, .y = 0, .w = 40, .h = 20 }, .role = .surface_bg } },
        .{ .text = .{ .origin = .{ .x = 0, .y = 0 }, .runs = &run, .role = .surface_fg } },
    };
    const draws = [_]chrome.ChromeDraw{.{ .layer = .modal, .ops = &ops }};

    var raster = try AppSession.rasterizeOverlayCells(allocator, &draws, &tk, 10, 20);
    defer raster.cells.deinit(allocator);
    defer raster.gpu_quads.deinit(allocator);
    defer raster.gpu_shadows.deinit(allocator);

    try std.testing.expectEqual(@as(u16, 4), raster.cols);
    // 셀: 가@col0(w2) + b@col2 + space@col3 = 3개. continuation col1은 스킵(emit하면 그 배경이 '가' 오른쪽 절반을 덮음).
    try std.testing.expectEqual(@as(usize, 3), raster.cells.items.len);
    try std.testing.expectEqual(@as(u21, '가'), raster.cells.items[0].codepoint);
    try std.testing.expectEqual(@as(u16, 0), raster.cells.items[0].col);
    try std.testing.expectEqual(@as(u2, 2), raster.cells.items[0].width); // wide
    try std.testing.expectEqual(@as(u21, 'b'), raster.cells.items[1].codepoint);
    try std.testing.expectEqual(@as(u16, 2), raster.cells.items[1].col); // 가가 2칸 차지 → b는 col2
    // col1(가의 continuation)을 가진 셀이 없어야 한다.
    for (raster.cells.items) |cell| try std.testing.expect(cell.col != 1);
}

test "chrome Notice 모달: showNotice → 메시지 소유 복사·오버레이 프레임·입력 라우팅·메뉴 차단·Esc 닫기" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // buildNoticeFrame=CoreText, 실 PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 6,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000); // 메트릭·backing(buildNoticeFrame이 chrome props로 씀)

    // 닫힘이면 buildNoticeFrame은 NotOpen(오버레이 없음 — 호출자가 무시).
    try std.testing.expect(!session.chrome_host.notice.open);
    try std.testing.expectError(error.NotOpen, session.buildChromeOverlayFrame());

    // showNotice는 메시지를 세션 소유 버퍼로 복사하고 연다 — 호출자의 transient 버퍼를 지워도 모달 메시지는 산다.
    {
        var transient = [_]u8{ 'c', 'o', 'r', 'r', 'u', 'p', 't' };
        session.showNotice(&transient);
        @memset(&transient, 0);
    }
    try std.testing.expect(session.chrome_host.notice.open);
    try std.testing.expectEqualStrings("corrupt", session.chrome_host.notice.message);

    // 오버레이 프레임이 크래시 없이 셀을 낸다(박스 bg + 메시지 glyph — 컴포넌트 view→ChromeDraw→lower 경로).
    var nf = try session.buildChromeOverlayFrame();
    defer nf.frame.deinit(allocator);
    try std.testing.expect(nf.frame.draw_list.cells.len > 0);

    // 회귀: Notice 열린 동안 메뉴 keyEquivalent(runAction)는 무시된다(모달 뒤 터미널 조작 차단).
    try std.testing.expect(!session.runAction("new_term"));

    // 평문 키는 소비하되 모달이라 안 닫힌다.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'a' }, .modifiers = .{} });
    try std.testing.expect(session.chrome_host.notice.open);

    // Esc로 닫힌다(chrome_host 라우팅이 notice.handle로 디스패치).
    _ = try session.handleKeyEvent(.{ .key = .escape, .modifiers = .{} });
    try std.testing.expect(!session.chrome_host.notice.open);
}

test "runtime font size: ⌘+/−/0 cell 메트릭·grid 재계산 + 하한·상한 클램프" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 CoreText 메트릭 + PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(1000, 700, 1000); // backing px 확정 → grid 산출

    const base = session.base_font_size;
    try std.testing.expectEqual(base, session.appearance.font.size);
    const cw0 = session.cell_width_px;
    const cols0 = session.activeSurface().core.snapshot().size.cols;

    // ⌘+ : 폰트 +step(config font.size-step, 기본 1pt) → cell 픽셀이 커지고(메트릭) grid는 줄거나 같다(같은 backing px).
    session.dispatchAppAction(.increase_font_size);
    try std.testing.expectEqual(base + session.appearance.font.size_step, session.appearance.font.size);
    try std.testing.expect(session.cell_width_px > cw0);
    const cols1 = session.activeSurface().core.snapshot().size.cols;
    try std.testing.expect(cols1 <= cols0);

    // ⌘0 : config 기본값 복원 → 폰트·cell 픽셀 원래대로(refreshCellMetrics 재계산은 결정적).
    session.dispatchAppAction(.reset_font_size);
    try std.testing.expectEqual(base, session.appearance.font.size);
    try std.testing.expectEqual(cw0, session.cell_width_px);

    // config font.size-step을 반영: step을 4로 바꾸면 ⌘+가 한 번에 +4pt(증분이 상수 1이 아니라 config 값).
    session.appearance.font.size_step = 4;
    session.dispatchAppAction(.increase_font_size);
    try std.testing.expectEqual(base + 4, session.appearance.font.size);
    session.dispatchAppAction(.reset_font_size); // 다시 base로(아래 경계 테스트 기준 복원)
    session.appearance.font.size_step = 1; // 기본 step으로 되돌려 경계 반복이 1pt씩 움직이게

    // set_font_size:N — 절대 지정(config 바인딩). 그 크기로 바로 설정, [6,72]로 클램프.
    session.dispatchAppAction(.{ .set_font_size = 24 });
    try std.testing.expectEqual(@as(f32, 24), session.appearance.font.size);
    session.dispatchAppAction(.{ .set_font_size = 1000 }); // 상한 클램프
    try std.testing.expectEqual(font_size_max, session.appearance.font.size);
    session.dispatchAppAction(.{ .set_font_size = 1 }); // 하한 클램프
    try std.testing.expectEqual(font_size_min, session.appearance.font.size);
    session.dispatchAppAction(.reset_font_size); // base로 복원(아래 경계 반복 기준)

    // ⌘- 반복 : 하한(font_size_min) 아래로 안 내려간다(경계에서 무동작).
    var i: usize = 0;
    while (i < 100) : (i += 1) session.dispatchAppAction(.decrease_font_size);
    try std.testing.expectEqual(font_size_min, session.appearance.font.size);

    // ⌘+ 반복 : 상한(font_size_max) 위로 안 올라간다.
    i = 0;
    while (i < 200) : (i += 1) session.dispatchAppAction(.increase_font_size);
    try std.testing.expectEqual(font_size_max, session.appearance.font.size);
}

// Reset to Defaults: 런타임 appearance 변경(폰트 줌·여백)을 프로그램 처음(init) 설정으로 되돌리는지.
// resetToInitial이 initial_appearance(init 단일 출처)를 applyAppearance로 복원해 appearance·cell 메트릭이
// init 값으로 돌아오는지 고정한다. initial_appearance가 reset로 안 바뀌어 반복 reset도 같은 기준인지도 본다.
test "resetToInitial: 런타임 폰트 줌·여백을 프로그램 처음 설정으로 되돌린다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 CoreText 메트릭 + PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(1000, 700, 1000); // backing px 확정 → grid 산출

    const init_size = session.initial_appearance.font.size;
    const init_padding_right = session.initial_appearance.window_padding_right;
    const cw0 = session.cell_width_px;
    try std.testing.expectEqual(init_size, session.appearance.font.size); // init 직후 appearance == initial

    // 런타임 줌(폰트 확대)과 여백 변경을 가한다 — reset이 되돌릴 대상.
    session.setFontSize(init_size + 6);
    session.appearance.window_padding_right = init_padding_right + 20;
    try std.testing.expect(session.appearance.font.size != init_size);
    try std.testing.expect(session.cell_width_px > cw0); // 폰트 키우면 cell 픽셀이 커진다(메트릭)

    // Reset to Defaults — appearance·메트릭이 init 값으로 복원된다(applyAppearance가 결정적 재계산).
    session.resetToInitial();
    try std.testing.expectEqual(init_size, session.appearance.font.size);
    try std.testing.expectEqual(init_padding_right, session.appearance.window_padding_right);
    try std.testing.expectEqual(cw0, session.cell_width_px);
    try std.testing.expectEqual(init_size, session.base_font_size); // ⌘0 기준도 init로 복원

    // initial_appearance는 reset로 안 바뀐다 — 반복 reset도 같은 기준("프로그램 처음")이다.
    try std.testing.expectEqual(init_size, session.initial_appearance.font.size);
    session.setFontSize(init_size + 6);
    session.resetToInitial();
    try std.testing.expectEqual(init_size, session.appearance.font.size);
}

// applyAppearance: 새 appearance를 통째로 갈아끼우면 appearance·base_font_size·cell 메트릭이 따라 바뀌는지.
// reloadConfig가 파일 새 값으로 부르는 일반 적용 경로 — 파일 I/O 없이 직접 호출로 핵심(appearance/메트릭 갱신)을 고정한다.
test "applyAppearance: 새 appearance로 appearance·base_font_size·메트릭을 갱신한다" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 CoreText 메트릭 + PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(1000, 700, 1000);

    const cw0 = session.cell_width_px;
    // 폰트가 더 큰 appearance를 만든다(기본 resolve에서 size만 키움).
    var bigger = try config_mod.resolveAppearance(.{});
    bigger.font = session.appearance.font; // family 슬라이스는 살아있는 loaded_config 빌림(undefined family 회피)
    bigger.font.size = session.appearance.font.size + 8;

    session.applyAppearance(bigger);
    try std.testing.expectEqual(bigger.font.size, session.appearance.font.size);
    try std.testing.expectEqual(bigger.font.size, session.base_font_size); // base_font_size도 새 크기로(⌘0 기준)
    try std.testing.expect(session.cell_width_px > cw0); // 메트릭 재계산(큰 폰트 → 큰 cell)
}

test "captureWorkspaceWindow: 라이브 탭/split/Term을 workspace 모델로 캡처" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY + split/탭 생성
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000);

    // 활성 surface에 cwd(OSC 7) 심기 + split으로 pane 2개 + 새 탭(탭 2개).
    try session.activeSurface().core.write("\x1b]7;file://h/tmp/proj\x07");
    session.dispatchAppAction(.split_horizontal);
    session.dispatchAppAction(.new_tab);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const win = try session.captureWorkspaceWindow(arena.allocator());

    // 탭 2개, 활성 탭 = 1(방금 만든 새 탭).
    try std.testing.expectEqual(@as(usize, 2), win.tabs.len);
    try std.testing.expectEqual(@as(usize, 1), win.active_tab);
    // 탭0: split → pane 2개 + tree preorder(split, leaf, leaf).
    const tab0 = win.tabs[0];
    try std.testing.expectEqual(@as(usize, 2), tab0.panes.len);
    try std.testing.expectEqual(@as(usize, 3), tab0.tree.len);
    try std.testing.expect(std.meta.activeTag(tab0.tree[0]) == .split);
    try std.testing.expect(std.meta.activeTag(tab0.tree[1]) == .leaf);
    // cwd /tmp/proj가 어떤 surface에 잡혔고, 모든 surface가 유효 크기를 가진다.
    var saw_cwd = false;
    for (tab0.panes) |pane| {
        for (pane.surfaces) |s| {
            if (std.mem.eql(u8, s.cwd, "/tmp/proj")) saw_cwd = true;
            try std.testing.expect(s.cols > 0 and s.rows > 0);
        }
    }
    try std.testing.expect(saw_cwd);

    // capture → serialize가 크래시 없이 기대 라인을 낸다(R1 writer와 결합).
    const wins = [_]app.workspace.Window{win};
    const text = try app.workspace.serialize(allocator, .{ .windows = &wins });
    defer allocator.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "maru.workspace.v1\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "tree-node split horizontal") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "cwd=\"/tmp/proj\"") != null);
}

test "serializeWorkspaceWindow: 세션-소유 헤더 없는 블록 + 재호출 시 이전 버퍼 해제" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit(); // workspace_buffer 해제 — testing.allocator가 leak을 잡는다
    _ = try session.resize(800, 600, 1000);
    try session.activeSurface().core.write("\x1b]7;file://h/srv\x07");

    const b0 = try session.serializeWorkspaceWindow();
    try std.testing.expect(std.mem.startsWith(u8, b0, "window ")); // 헤더 없는 블록(Swift가 헤더 하나로 모음)
    try std.testing.expect(std.mem.indexOf(u8, b0, "cwd=\"/srv\"") != null);

    // 재호출: 이전 버퍼를 해제하고 새로 만든다(이전 버퍼를 안 free하면 testing.allocator leak).
    const b1 = try session.serializeWorkspaceWindow();
    try std.testing.expect(std.mem.startsWith(u8, b1, "window "));
}

test "applyWorkspaceWindow: 모델 적용 → 캡처 round-trip(탭/split/Term 구조·active 인덱스)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY spawn(cwd chdir이 실패 안 하게 /tmp 사용)
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000);

    // 모델: 창 1, 탭 2. 탭0 = split horizontal { pane0, pane1 }(각 1 Term), 활성 pane 1. 탭1 = 단일 pane 2 Term, 활성 term 1.
    const sa = [_]app.workspace.Surface{.{ .cwd = "/tmp", .cols = 40, .rows = 24 }};
    const sb = [_]app.workspace.Surface{.{ .cwd = "/tmp", .cols = 40, .rows = 24 }};
    const panes0 = [_]app.workspace.Pane{ .{ .surfaces = &sa }, .{ .surfaces = &sb } };
    const tree0 = [_]app.workspace.TreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .leaf = 0 },
        .{ .leaf = 1 },
    };
    const sc = [_]app.workspace.Surface{ .{ .cwd = "/tmp", .cols = 40, .rows = 24 }, .{ .cwd = "/tmp", .cols = 40, .rows = 24 } };
    const panes1 = [_]app.workspace.Pane{.{ .active_term = 1, .surfaces = &sc }};
    const tree1 = [_]app.workspace.TreeNode{.{ .leaf = 0 }};
    const tabs = [_]app.workspace.Tab{
        .{ .active_pane = 1, .tree = &tree0, .panes = &panes0 },
        .{ .active_pane = 0, .tree = &tree1, .panes = &panes1 },
    };
    try session.applyWorkspaceWindow(.{ .active_tab = 1, .tabs = &tabs });

    // 캡처해 구조·active 인덱스가 모델과 일치하는지(cwd는 OSC-side라 round-trip 안 함 — 구조만).
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cap = try session.captureWorkspaceWindow(arena.allocator());
    try std.testing.expectEqual(@as(usize, 2), cap.tabs.len);
    try std.testing.expectEqual(@as(usize, 1), cap.active_tab);
    // 탭0: split horizontal ratio 500 + pane 2, active_pane 1.
    try std.testing.expectEqual(@as(usize, 2), cap.tabs[0].panes.len);
    try std.testing.expectEqual(@as(usize, 3), cap.tabs[0].tree.len);
    try std.testing.expect(std.meta.activeTag(cap.tabs[0].tree[0]) == .split);
    try std.testing.expect(cap.tabs[0].tree[0].split.direction == .horizontal);
    try std.testing.expectEqual(@as(u16, 500), cap.tabs[0].tree[0].split.ratio_milli);
    try std.testing.expectEqual(@as(usize, 1), cap.tabs[0].active_pane);
    // 탭1: 단일 pane, Term 2, active_term 1.
    try std.testing.expectEqual(@as(usize, 1), cap.tabs[1].panes.len);
    try std.testing.expectEqual(@as(usize, 2), cap.tabs[1].panes[0].surfaces.len);
    try std.testing.expectEqual(@as(usize, 1), cap.tabs[1].panes[0].active_term);
}

test "workspace 복원 text → parse → applyWorkspaceWindow (R4b ABI 경로)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY spawn
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000);

    // 저장 텍스트(한 창: 단일 탭, split vertical 2 pane, cwd /tmp). apply ABI가 받는 것과 같은 형태.
    // custom_name(사용자 rename)을 세 계층에 심어 parse→apply(라이브 구조체 복원)→capture 라운드트립을 증명한다.
    const text =
        "maru.workspace.v1\n" ++
        "window tabs=1 active-tab=0\n" ++
        "tab panes=2 active-pane=1 custom-name=\"my work\" pinned=0 background-color=0\n" ++
        "tree-node split vertical ratio=300\n" ++
        "tree-node leaf pane=0\n" ++
        "tree-node leaf pane=1\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"left\"\n" ++
        "surface custom-name=\"editor\" title=\"\" cwd=\"/tmp\" command=\"\" cols=40 rows=12\n" ++
        "pane surfaces=1 active-term=0 custom-name=\"\"\n" ++
        "surface custom-name=\"\" title=\"\" cwd=\"/tmp\" command=\"\" cols=40 rows=12\n";

    var parsed = try app.workspace.parse(allocator, text);
    defer parsed.deinit();
    try session.applyWorkspaceWindow(parsed.workspace.windows[0]);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const cap = try session.captureWorkspaceWindow(arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), cap.tabs.len);
    try std.testing.expectEqual(@as(usize, 2), cap.tabs[0].panes.len);
    try std.testing.expectEqual(@as(usize, 1), cap.tabs[0].active_pane);
    try std.testing.expect(cap.tabs[0].tree[0].split.direction == .vertical);
    try std.testing.expectEqual(@as(u16, 300), cap.tabs[0].tree[0].split.ratio_milli);
    // custom_name 라운드트립(parse→applyWorkspaceWindow 라이브 복원→captureWorkspaceWindow): 세 계층 모두 유지.
    try std.testing.expectEqualStrings("my work", cap.tabs[0].custom_name); // 워크스페이스
    try std.testing.expectEqualStrings("left", cap.tabs[0].panes[0].custom_name); // Pane
    try std.testing.expectEqualStrings("editor", cap.tabs[0].panes[0].surfaces[0].custom_name); // Term
    try std.testing.expectEqualStrings("", cap.tabs[0].panes[1].custom_name); // 빈 custom_name = 이름 없음
}

test "usableRestoreCwd: 절대경로 형식 필터(존재·디렉터리는 childExec graceful이 담당)" {
    // 절대 경로면 존재·디렉터리 여부와 무관하게 통과한다 — 없는 경로·파일도. 자식이 chdir 실패 시 $HOME으로
    // 폴백하므로(pty/macos childExec), 여기선 형식만 거른다(TOCTOU 추측 제거).
    try std.testing.expectEqualStrings("/tmp", usableRestoreCwd("/tmp").?);
    try std.testing.expectEqualStrings("/no/such/maru-restore-xyz-12345", usableRestoreCwd("/no/such/maru-restore-xyz-12345").?);
    try std.testing.expectEqualStrings("/bin/sh", usableRestoreCwd("/bin/sh").?); // 파일이어도 형식은 절대경로
    // 형식 불량(빈값·상대경로)만 거른다 — 상대경로를 cwd로 넘기면 자식이 앱 cwd 기준 chdir해 예측 불가.
    try std.testing.expect(usableRestoreCwd("") == null);
    try std.testing.expect(usableRestoreCwd("relative/path") == null);
}

test "applyWorkspaceWindow: 없는 cwd여도 복원 성공(기본 cwd 폴백, surface 안 잃음)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY spawn
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000);

    // 없는 cwd → usableRestoreCwd가 null → 기본 cwd로 spawn. apply는 성공하고 탭/surface가 복원된다(셸이
    // 잘못된 cwd로 _exit(126) 나는 일 없이 살아 있음). 미리 확인 안 했으면 복원 셸이 즉시 죽었을 것.
    const s = [_]app.workspace.Surface{.{ .cwd = "/no/such/maru-restore-xyz", .cols = 40, .rows = 24 }};
    const panes = [_]app.workspace.Pane{.{ .surfaces = &s }};
    const tree = [_]app.workspace.TreeNode{.{ .leaf = 0 }};
    const tabs = [_]app.workspace.Tab{.{ .tree = &tree, .panes = &panes }};
    try session.applyWorkspaceWindow(.{ .tabs = &tabs }); // 실패 안 함
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().panes.items.len);
}

test "applyWorkspaceWindow: 손상 트리(중복·고아 leaf)는 MalformedTree로 거부(UAF 차단)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY spawn
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000);

    const s = [_]app.workspace.Surface{
        .{ .cwd = "/tmp", .cols = 40, .rows = 24 },
        .{ .cwd = "/tmp", .cols = 40, .rows = 24 },
    };
    const panes = [_]app.workspace.Pane{ .{ .surfaces = s[0..1] }, .{ .surfaces = s[1..2] } };

    // 중복 leaf: split{leaf 0, leaf 0}(panes=2). 노드 3개=2*2-1로 구조 불변식은 통과하지만 pane 0을 두 leaf가
    // 참조(같은 *Pane 두 번 → close 시 UAF)하고 pane 1은 고아다 → MalformedTree로 거부, 기존 세션은 그대로.
    const dup_tree = [_]app.workspace.TreeNode{
        .{ .split = .{ .direction = .horizontal, .ratio_milli = 500 } },
        .{ .leaf = 0 },
        .{ .leaf = 0 },
    };
    const dup_tabs = [_]app.workspace.Tab{.{ .tree = &dup_tree, .panes = &panes }};
    try std.testing.expectError(error.MalformedTree, session.applyWorkspaceWindow(.{ .tabs = &dup_tabs }));
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len); // swap 전 실패 — 기존 세션 보존

    // 고아 leaf: panes=2인데 트리는 leaf 0 하나만(pane 1 미참조) → 고아 검사로 MalformedTree.
    const orphan_tree = [_]app.workspace.TreeNode{.{ .leaf = 0 }};
    const orphan_tabs = [_]app.workspace.Tab{.{ .tree = &orphan_tree, .panes = &panes }};
    try std.testing.expectError(error.MalformedTree, session.applyWorkspaceWindow(.{ .tabs = &orphan_tabs }));
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
}

test "sidebarBandCell sizes the active band to the sidebar width and emits a sentinel-UV bg cell" {
    // 순수 함수: 사이드바 폭/cell 폭/활성 행/색만으로 활성 탭 하이라이트 밴드 셀을 만든다(OS 무관).
    // 사이드바 꺼짐(폭 0)이나 cell 폭 0이면 null.
    try std.testing.expect(sidebarBandCell(0, 8, 0, 0xFF112233) == null);
    try std.testing.expect(sidebarBandCell(180, 0, 0, 0xFF112233) == null);

    // 180px 폭, cell 폭 9px → floor(180/9)=20칸. 밴드는 col 0, width 20, 활성 행, sentinel UV, 배경=색.
    const cell = sidebarBandCell(180, 9, 0, 0xFF112233).?;
    try std.testing.expectEqual(@as(u16, 0), cell.col);
    try std.testing.expectEqual(@as(u16, 20), cell.width);
    try std.testing.expectEqual(@as(u16, 0), cell.row);
    try std.testing.expectEqual(@as(f32, -1.0), cell.u0); // sentinel UV: 셰이더가 atlas 샘플 없이 배경만
    try std.testing.expectEqual(@as(u32, 0xFF112233), cell.background);
    try std.testing.expectEqual(@as(u32, 0), cell.foreground);

    // 밴드 폭은 floor라 origin_x를 넘지 않는다: 17px 폭/8px cell → 2칸(2*8=16<=17). ceil(=3,24px)이면 침범.
    try std.testing.expectEqual(@as(u16, 2), sidebarBandCell(17, 8, 0, 0xFF000000).?.width);
    // 활성 행은 인자대로(탭 i = 행 i): 3번째 탭이면 row 2.
    try std.testing.expectEqual(@as(u16, 2), sidebarBandCell(180, 9, 2, 0xFF000000).?.row);
    // cell 폭이 사이드바 폭보다 크면 0칸 → null(밴드 없음).
    try std.testing.expect(sidebarBandCell(8, 16, 0, 0xFF000000) == null);
}

// 사이드바 활성 하이라이트 밴드가 실제 세션에서 채워지고 탭 생성/전환을 따라 행을 옮기는지 — 실 init이
// CoreText 메트릭과 사이드바 폭을 채우는 macOS 경로라 게이트한다. metalFrame()이 그 밴드를 사이드바
// 셀로 노출하는 것도 함께 본다(렌더러가 origin 0에 그릴 입력).
test "sidebar gets an active-tab highlight band that follows tab create and switch" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // init 후: 사이드바 폭/메트릭이 채워진다. metalFrame이 노출하는 사이드바 셀은 metal_buffer가
    // 소유하므로 첫 tick의 replace가 돌아야 채워진다(밴드 + 제목 glyph). 한 번 tick한다.
    try std.testing.expect(session.sidebar_width_px > 0);
    _ = try session.tick();
    {
        const frame = session.metalFrame();
        // 최소 밴드 1개(활성 탭 하이라이트) — macOS에선 제목 glyph도 더해진다.
        try std.testing.expect(frame.sidebar_cell_count >= 1);
        try std.testing.expect(frame.sidebar_cells != null);
        // 밴드 source(self.sidebar_cells)는 활성 행을 추적한다 — metal_buffer로 옮겨도 source는 그대로.
        try std.testing.expectEqual(@as(u16, 0), session.sidebar_cells.items[0].row);
        try std.testing.expect(session.sidebar_cells.items[0].width > 0);
        // 밴드를 그릴 사이드바 폭은 터미널 origin offset과 같은 단일 출처다.
        try std.testing.expectEqual(session.sidebar_width_px, frame.terminal_origin_x_px);
        // 탭 슬롯 높이는 cell 높이 × 비율(큰 슬롯, 2줄 카드 수용) — 단일 출처 상수에서 파생, cell 높이보다 크다.
        try std.testing.expectEqual(session.cell_height_px * sidebar_slot_height_ratio_milli / 1000, frame.sidebar_slot_height_px);
        try std.testing.expect(frame.sidebar_slot_height_px > session.cell_height_px);
    }

    // 2번째 탭 생성 → 활성=1 → 밴드가 row 1로 이동(여전히 1개).
    _ = try session.createTab(
        .{ .command = "/bin/sh", .args = &.{ "-c", "true" }, .size = .{ .cols = 20, .rows = 5 } },
        .{ .cols = 20, .rows = 5 },
        16,
        "tab 2",
        "sh",
    );
    try std.testing.expectEqual(@as(usize, 1), session.sidebar_cells.items.len);
    try std.testing.expectEqual(@as(u16, 1), session.sidebar_cells.items[0].row);

    // switchTab(0) → 밴드가 다시 row 0.
    try std.testing.expect(session.switchTab(0));
    try std.testing.expectEqual(@as(u16, 1), session.sidebar_cells.items.len);
    try std.testing.expectEqual(@as(u16, 0), session.sidebar_cells.items[0].row);
}

// 활성 탭이 단일 leaf SplitTree로 만들어지고, activeTabLeafRects가 그 leaf를 터미널 영역 전체에 펴는지
// — createTab이 tree를 세팅하는 macOS 경로라 게이트한다. split(PR3) 전엔 panel 1개 = 풀 rect다.
test "active tab is a single-leaf SplitTree laid out to the full terminal rect" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 활성 탭은 panel 1개(split 전), active_pane 0, tree는 단일 leaf(= 활성 panel surface).
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().panes.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.activeTab().active_pane);
    try std.testing.expectEqual(session.activeSurface(), &session.activePane().activeTerm().surface);
    try std.testing.expectEqual(@as(usize, 1), PaneTree.leafCount(session.activeTab().tree));

    var out: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer out.deinit(allocator);
    const rect: app.SplitRect = .{ .x = 180, .y = 0, .w = 800, .h = 600 };
    try session.activeTabLeafRects(allocator, rect, &out);
    // 단일 leaf → rect 1개 = 입력 rect 전체, leaf = 활성 panel.
    try std.testing.expectEqual(@as(usize, 1), out.items.len);
    try std.testing.expectEqual(session.activePane(), out.items[0].leaf);
    try std.testing.expectEqual(rect, out.items[0].rect);
}

// splitActivePane이 활성 panel을 둘로 나눠 트리를 split 노드로 바꾸고 새 panel로 포커스를 옮기는지 —
// createPane(셸 spawn)·트리 변형·resize·포커스 재바인딩이 한데 도는 macOS 경로라 게이트한다. split 후
// N-panel 렌더(비활성 frame 빌드 + 활성 맨 뒤)가 tick에서 크래시 없이 도는 것도 함께 본다.
test "splitActivePane splits the active leaf, focuses the new panel, and renders N panels" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 분할은 창이 떠 backing이 잡힌 뒤에야 의미 있으므로, resized 창을 흉내 내 backing을 채운다(termRect의
    // 입력). 터미널 영역 = backing − 사이드바. 좌우 분할이라 폭이 둘로 갈린다.
    session.backing_width_px = session.sidebar_width_px + 800;
    session.backing_height_px = 600;
    session.window_padding_px = .{}; // split 기하만 검증 — window padding(기본 8/4) inset은 gridFromBacking·loader 테스트가 커버

    const old_pane = session.activePane();
    const old_surface = session.activeSurface();
    try session.splitActivePane(.horizontal);

    // 트리/포커스: panel 2개, 새 panel(인덱스 1)이 활성, tree는 horizontal split{a: 기존, b: 새}.
    try std.testing.expectEqual(@as(usize, 2), session.activeTab().panes.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().active_pane);
    try std.testing.expectEqual(@as(usize, 2), PaneTree.leafCount(session.activeTab().tree));
    const new_pane = session.activePane();
    const new_surface = session.activeSurface();
    try std.testing.expect(new_pane != old_pane); // 포커스가 새 panel로 이동
    try std.testing.expect(new_surface != old_surface);
    try std.testing.expectEqual(new_surface, &session.activePane().activeTerm().surface);
    switch (session.activeTab().tree) {
        .leaf => return error.TestExpectedSplitNode,
        .split => |sp| {
            try std.testing.expectEqual(app.SplitDirection.horizontal, sp.direction);
            try std.testing.expectEqual(old_pane, sp.a.leaf); // a = 기존 panel(왼쪽)
            try std.testing.expectEqual(new_pane, sp.b.leaf); // b = 새 panel(오른쪽)
        },
    }

    // 레이아웃: 2개 rect, 합이 터미널 폭과 같고(틈 없음) 기존이 왼쪽·새가 오른쪽.
    var out: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer out.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &out);
    try std.testing.expectEqual(@as(usize, 2), out.items.len);
    try std.testing.expectEqual(old_pane, out.items[0].leaf);
    try std.testing.expectEqual(new_pane, out.items[1].leaf);
    try std.testing.expectEqual(@as(u32, 800), out.items[0].rect.w + out.items[1].rect.w);
    try std.testing.expectEqual(session.sidebar_width_px, out.items[0].rect.x); // 왼쪽 panel은 사이드바 바로 옆

    // N-panel 렌더 경로(비활성 frame 빌드 + 활성 맨 뒤 합성)가 크래시 없이 돈다.
    _ = try session.tick();
}

test "S1 구조-무효화 계약: destroyPane이 해제 Pane 포인터를 표적 무효화(무관 드래그 보존)·divider도 표적" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // splitActivePane = 실 PTY/CoreText
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.backing_width_px = session.sidebar_width_px + 800; // split이 의미 있으려면 backing 필요
    session.backing_height_px = 600;
    session.window_padding_px = .{}; // split 기하만 검증 — window padding(기본 8/4) inset은 gridFromBacking·loader 테스트가 커버

    // 모든 트리 변형(close/collapse/apply/reap)은 노드 해제 시 destroyPane을 거치므로, closeActivePane 한 경로로
    // chokepoint 동작을 고정한다(나머지 호출처는 같은 chokepoint를 공유).

    // ── 케이스 1: 닫는 Pane을 가리키던 포인터는 표적 null; divider도 '닫는 split'이라 표적 null; 슬롯은 보수적 null ──
    const pane_a = session.activePane();
    try session.splitActivePane(.horizontal); // panes [a, b], 활성 b(닫을 대상)
    const pane_b = session.activePane();
    try std.testing.expect(pane_b != pane_a);
    const split_node = switch (session.activeTab().tree) {
        .split => |sp| sp,
        .leaf => return error.TestExpectedSplit,
    };
    session.tab_drag_pane = pane_b;
    session.tab_drag_active = true;
    session.hovered_tab = .{ .pane = pane_b, .tab = 0 };
    session.divider_drag = split_node;
    session.hovered_slot = 3;

    session.closeActivePane(); // b 해제 → destroyPane(b) → invalidateForFreedPane(b)
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().panes.items.len);
    try std.testing.expect(session.tab_drag_pane == null); // 표적: b를 가리켰으니 null
    try std.testing.expect(!session.tab_drag_active); // 드래그 대상 사라짐 → 제스처 중단
    try std.testing.expect(session.hovered_tab == null); // 표적: b를 가리켰으니 null
    try std.testing.expect(session.divider_drag == null); // 표적: 닫힌 게 바로 이 split이라 null
    try std.testing.expect(session.hovered_slot == null);

    // ── 케이스 2: 무관한 Pane을 닫아도 다른 Pane을 가리키던 드래그/호버는 보존(tab-drag 불변식) ──
    try session.splitActivePane(.horizontal); // panes [a, c], 활성 c
    const pane_c = session.activePane();
    try std.testing.expect(pane_c != pane_a);
    session.tab_drag_pane = pane_a; // 살아남을 Pane(a)을 가리킨다
    session.tab_drag_active = true;
    session.hovered_tab = .{ .pane = pane_a, .tab = 0 };

    session.closeActivePane(); // c 해제(a와 무관) → invalidateForFreedPane(c)
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().panes.items.len);
    try std.testing.expect(session.tab_drag_pane == pane_a); // 보존: c≠a라 안 끊김
    try std.testing.expect(session.tab_drag_active); // 드래그 계속
    try std.testing.expect(session.hovered_tab != null and session.hovered_tab.?.pane == pane_a); // 보존
}

test "S1 표적 divider: 무관한 split의 pane이 collapse돼도 divider_drag 보존(removeLeaf가 freed split surface)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // splitActivePane = 실 PTY/CoreText
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.backing_width_px = session.sidebar_width_px + 800;
    session.backing_height_px = 600;
    session.window_padding_px = .{}; // split 기하만 검증 — window padding(기본 8/4) inset은 gridFromBacking·loader 테스트가 커버

    // 3 pane: tree = split{P0, split{P1, P2}}(루트 split + 중첩 inner split). 두 번 분할로 만든다.
    try session.splitActivePane(.horizontal); // [P0, P1], 활성 P1, tree=split{P0,P1}
    try session.splitActivePane(.horizontal); // P1→split{P1,P2}; [P0,P1,P2], 활성 P2, tree=split{P0, split{P1,P2}}
    try std.testing.expectEqual(@as(usize, 3), session.activeTab().panes.items.len);
    const root_split = switch (session.activeTab().tree) {
        .split => |sp| sp,
        .leaf => return error.TestExpectedSplit,
    };

    // 루트 split을 divider_drag로 잡는다. 활성(P2)을 닫으면 inner split이 collapse·해제되지만, divider_drag는
    // root split이라 표적 비교로 **보존**돼야 한다(예전 보수적 blanket-null이면 여기서 잘못 끊겼다).
    session.divider_drag = root_split;
    session.closeActivePane(); // P2 해제 → removeLeaf가 inner split 반환 → invalidateForFreedSplit(inner≠root)
    try std.testing.expectEqual(@as(usize, 2), session.activeTab().panes.items.len);
    try std.testing.expect(session.divider_drag == root_split); // 보존: 닫힌 split(inner)≠divider_drag(root)

    // 남은 한 pane을 더 닫으면 이번엔 root split이 collapse → divider_drag(=root) 표적 null.
    session.closeActivePane(); // removeLeaf가 root split 반환 → invalidateForFreedSplit(root==divider_drag)
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().panes.items.len);
    try std.testing.expect(session.divider_drag == null); // 표적: 닫힌 게 root split
}

// paneAtPoint가 스크린 점을 담는 leaf rect의 panel을 고르는지(반열린 구간 경계·밖·비유한) — 마우스
// pane 전환의 hit-test 코어라 헤드리스 단위로 고정한다(레이아웃 rect만 입력, OS 무관). leaf는 deref되지
// 않아(pointer-identity만) 빈 Pane 더미로 충분하다.
test "paneAtPoint hit-tests which leaf rect contains a screen point" {
    var a: Pane = .{};
    var b: Pane = .{};
    // 좌우 2-panel: a=[0,100)×[0,200), b=[100,200)×[0,200).
    const rects = [_]PaneTree.LeafRect{
        .{ .leaf = &a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 } },
        .{ .leaf = &b, .rect = .{ .x = 100, .y = 0, .w = 100, .h = 200 } },
    };
    try std.testing.expectEqual(&a, paneAtPoint(&rects, 50, 100).?);
    try std.testing.expectEqual(&b, paneAtPoint(&rects, 150, 100).?);
    try std.testing.expectEqual(&a, paneAtPoint(&rects, 0, 0).?); // 좌상단 경계 포함
    try std.testing.expectEqual(&b, paneAtPoint(&rects, 100, 0).?); // x=100 경계는 b(반열린 [x, x+w))
    try std.testing.expect(paneAtPoint(&rects, 200, 0) == null); // 오른쪽 밖
    try std.testing.expect(paneAtPoint(&rects, 50, 200) == null); // 아래 밖
    try std.testing.expect(paneAtPoint(&rects, std.math.nan(f64), 5) == null); // 비유한
}

// paneInDirection이 활성 panel 기준 방향 인접 panel을 고르는지(반평면 + 정렬, 잘못된 축은 null) — 키보드
// pane 이동의 기하 코어라 헤드리스 단위로 고정한다. 좌우 split·2×2 격자·미발견을 다 본다.
test "paneInDirection picks the adjacent pane in a direction" {
    var a: Pane = .{};
    var b: Pane = .{};
    var c: Pane = .{};
    var d: Pane = .{};

    // 좌우 2-panel: a 왼쪽, b 오른쪽.
    const lr = [_]PaneTree.LeafRect{
        .{ .leaf = &a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 200 } },
        .{ .leaf = &b, .rect = .{ .x = 100, .y = 0, .w = 100, .h = 200 } },
    };
    try std.testing.expectEqual(&b, paneInDirection(&lr, &a, .right).?);
    try std.testing.expectEqual(&a, paneInDirection(&lr, &b, .left).?);
    try std.testing.expect(paneInDirection(&lr, &a, .up) == null); // 좌우 split이라 위/아래 없음
    try std.testing.expect(paneInDirection(&lr, &a, .down) == null);
    try std.testing.expect(paneInDirection(&lr, &c, .left) == null); // 활성 panel이 leaf에 없음

    // 2×2 격자: a=좌상, b=우상, c=좌하, d=우하. 정렬(같은 행/열)을 우대한다.
    const grid = [_]PaneTree.LeafRect{
        .{ .leaf = &a, .rect = .{ .x = 0, .y = 0, .w = 100, .h = 100 } },
        .{ .leaf = &b, .rect = .{ .x = 100, .y = 0, .w = 100, .h = 100 } },
        .{ .leaf = &c, .rect = .{ .x = 0, .y = 100, .w = 100, .h = 100 } },
        .{ .leaf = &d, .rect = .{ .x = 100, .y = 100, .w = 100, .h = 100 } },
    };
    try std.testing.expectEqual(&b, paneInDirection(&grid, &a, .right).?); // a→우: b(같은 행)
    try std.testing.expectEqual(&c, paneInDirection(&grid, &a, .down).?); // a→하: c(같은 열)
    try std.testing.expectEqual(&d, paneInDirection(&grid, &b, .down).?); // b→하: d
    try std.testing.expectEqual(&c, paneInDirection(&grid, &d, .left).?); // d→좌: c(같은 행, a 아님)
}

// paneBarBgCell이 바 rect를 sentinel-UV 배경 셀(origin 박힌, 폭=cols)로 만들고, 너무 작으면 null인지 — pane
// 탭 바 배경의 코어라 헤드리스 단위로 고정한다(순수 함수, OS 무관).
test "paneBarBgCell builds a bar-width background cell at the bar origin" {
    // 바 rect (x=180, y=0, w=96, h=12), cell 12 → 8칸. origin 박히고 sentinel UV(배경만), bg 지정색.
    const cell = paneBarBgCell(.{ .x = 180, .y = 0, .w = 96, .h = 12 }, 12, 0xFF112233).?;
    try std.testing.expectEqual(@as(u16, 8), cell.width); // 96/12 = 8칸(아래 터미널과 정렬)
    try std.testing.expectEqual(@as(u32, 180), cell.origin_x);
    try std.testing.expectEqual(@as(u32, 0), cell.origin_y);
    try std.testing.expectEqual(@as(u16, 0), cell.row);
    try std.testing.expectEqual(@as(u32, 0), cell.slot_id); // 배경 셀(밴드) — glyph 아님
    try std.testing.expectEqual(@as(f32, -1.0), cell.u0); // sentinel UV = 배경만
    try std.testing.expectEqual(@as(u32, 0xFF112233), cell.background);
    // 폭/높이/cell 0이면 null.
    try std.testing.expect(paneBarBgCell(.{ .x = 0, .y = 0, .w = 0, .h = 12 }, 12, 0xFF000000) == null);
    try std.testing.expect(paneBarBgCell(.{ .x = 0, .y = 0, .w = 96, .h = 12 }, 0, 0xFF000000) == null);
    try std.testing.expect(paneBarBgCell(.{ .x = 0, .y = 0, .w = 8, .h = 12 }, 12, 0xFF000000) == null); // 1칸 미만
}

// 탭 바 컬럼 분할 hit-test(tabIndex/inCloseZone/inPlusZone/hasPlusZone)는 chrome `tabbar.Metrics` 메서드로 이주(C3b) —
// 단위 테스트는 src/chrome/components/tabbar.zig. 여기선 platform이 그 hit-test와 공유하는 pointInRect 경계만 고정한다.
// barMetrics가 바를 [탭 영역 | "+" zone]으로 나누고 극단(셀·바·탭 0)에 null을 주는지, tabbarHighlightCell이 활성 탭
// 세그먼트 강조 셀(col=start·width·origin=bar)을 만드는지 — 탭 바 hit-test/렌더의 platform 측(메서드는 chrome tabbar.zig가
// 테스트). 옛 BarMetrics 단위 테스트의 init-null·highlightCell 케이스를 이리로 보존한다(C3b 리뷰 반영 — 이주로 빠졌던 커버리지).
test "barMetrics splits bar + tabbarHighlightCell active-tab band" {
    const bar: app.SplitRect = .{ .x = 180, .y = 0, .w = 240, .h = 12 }; // cell 12 → 20칸, "+" zone 3 제외 탭 영역 17, 2탭 → tab_w=8
    const m = barMetrics(bar, 12, 2, 0, 0).?;
    try std.testing.expectEqual(@as(u32, 20), m.cols);
    try std.testing.expectEqual(@as(u32, 17), m.tab_cols);
    try std.testing.expectEqual(@as(u32, 8), m.tab_w);
    try std.testing.expectEqual(@as(u32, 180), m.bar_x);
    // 극단(셀 0·바 폭 0·탭 0)이면 null — 호출자가 탭 처리를 건너뛴다.
    try std.testing.expect(barMetrics(bar, 0, 2, 0, 0) == null);
    try std.testing.expect(barMetrics(.{ .x = 0, .y = 0, .w = 0, .h = 12 }, 12, 2, 0, 0) == null);
    try std.testing.expect(barMetrics(bar, 12, 0, 0, 0) == null);
    // tabbarHighlightCell: 탭 1 = col [8,16), origin=bar.x, sentinel-bg(slot_id 0).
    const cell = tabbarHighlightCell(m, 1, 0xFF445566).?;
    try std.testing.expectEqual(@as(u16, 8), cell.col); // 1*tab_w
    try std.testing.expectEqual(@as(u16, 8), cell.width);
    try std.testing.expectEqual(@as(u32, 180), cell.origin_x);
    try std.testing.expectEqual(@as(u32, 0xFF445566), cell.background);
    try std.testing.expectEqual(@as(u32, 0), cell.slot_id);
    try std.testing.expect(tabbarHighlightCell(m, 3, 0xFF000000) == null); // start(24) >= tab_cols(17) → 세그먼트 없음
}

// pane 라벨 세그먼트(PR2)의 폭 산출·탭 영역 offset 단일 출처 — custom_name 유무·좁은 바·max cap을 헤드리스로 고정한다.
// 이 두 함수가 render(라벨/탭 origin)와 hit-test(barMetrics 입력)에서 같은 결과를 줘 "보이는 == 클릭되는"을 유지한다.
test "paneLabelCols/paneTabBarRect: 라벨 없으면 0(전체 바), 있으면 폭 예약·탭 우측 offset" {
    const full: app.SplitRect = .{ .x = 100, .y = 0, .w = 320, .h = 24 }; // cell 8 → 40칸

    // custom_name 없음 → label_cols 0, 탭 sub-rect == 전체 바(기존 동작).
    var bare: Pane = .{ .custom_name = null };
    try std.testing.expectEqual(@as(u32, 0), AppSession.paneLabelCols(&bare, 40));
    const t0 = AppSession.paneTabBarRect(full, 0, 8);
    try std.testing.expectEqual(@as(u32, 100), t0.x);
    try std.testing.expectEqual(@as(u32, 320), t0.w);

    // "build"(5칸) → want = 5 + 2(좌패딩·간격) = 7. bar_cols 40이라 cap 충분 → 7칸 예약, 탭이 그만큼 우측으로.
    var named: Pane = .{ .custom_name = "build" };
    const lc = AppSession.paneLabelCols(&named, 40);
    try std.testing.expectEqual(@as(u32, 7), lc);
    const t1 = AppSession.paneTabBarRect(full, lc, 8);
    try std.testing.expectEqual(@as(u32, 100 + 7 * 8), t1.x); // 라벨만큼 우측 offset
    try std.testing.expectEqual(@as(u32, 320 - 7 * 8), t1.w);

    // 좁은 바(bar_cols ≤ min_tab_cols=6)면 라벨 생략(탭 우선).
    try std.testing.expectEqual(@as(u32, 0), AppSession.paneLabelCols(&named, 6));

    // 긴 이름은 max_label(20)로 cap.
    var long: Pane = .{ .custom_name = "this-is-a-very-long-pane-name-indeed" };
    try std.testing.expectEqual(@as(u32, 20), AppSession.paneLabelCols(&long, 100));

    // 빈 custom_name("")도 없음으로 본다(app.pickLabel 규칙).
    var empty: Pane = .{ .custom_name = "" };
    try std.testing.expectEqual(@as(u32, 0), AppSession.paneLabelCols(&empty, 40));
}

test "pointInRect uses half-open bounds (탭 바·divider·pane hit-test 공유)" {
    const bar: app.SplitRect = .{ .x = 180, .y = 0, .w = 240, .h = 12 }; // 우경계 = 180+240 = 420
    try std.testing.expect(pointInRect(180, 0, bar)); // 좌상단 포함
    try std.testing.expect(pointInRect(419, 11, bar)); // 우하 안쪽
    try std.testing.expect(!pointInRect(420, 0, bar)); // x = x+w 제외
    try std.testing.expect(!pointInRect(180, 12, bar)); // y = y+h 제외
    try std.testing.expect(!pointInRect(179, 0, bar)); // 좌측 밖
    try std.testing.expect(!pointInRect(std.math.nan(f64), 0, bar)); // 비유한
}

// paneDropZone이 rect를 X자 4등분해 가장 가까운 가장자리를 고르는지(④ split 재배치 drop-zone). 순수 함수.
test "paneDropZone classifies a point into the nearest edge half" {
    const r: app.SplitRect = .{ .x = 0, .y = 0, .w = 100, .h = 100 };
    try std.testing.expectEqual(PaneDropZone.left, paneDropZone(r, 10, 50).?); // 좌측 가장자리 근처
    try std.testing.expectEqual(PaneDropZone.right, paneDropZone(r, 90, 50).?); // 우측
    try std.testing.expectEqual(PaneDropZone.top, paneDropZone(r, 50, 10).?); // 상단
    try std.testing.expectEqual(PaneDropZone.bottom, paneDropZone(r, 50, 90).?); // 하단
    try std.testing.expectEqual(PaneDropZone.left, paneDropZone(r, 25, 50).?); // 중앙 좌측(dx<dy)
    // rect 밖·0 크기·비유한이면 null.
    try std.testing.expect(paneDropZone(r, 150, 50) == null);
    try std.testing.expect(paneDropZone(.{ .x = 0, .y = 0, .w = 0, .h = 100 }, 0, 50) == null);
    try std.testing.expect(paneDropZone(r, std.math.nan(f64), 50) == null);
}

// halfRect가 rect를 zone 방향 절반으로 자르고, premultipliedRgba가 alpha로 rgb를 미리 곱하는지(④b 하이라이트). 순수.
test "halfRect splits a rect by zone; premultipliedRgba premultiplies rgb by alpha" {
    const r: app.SplitRect = .{ .x = 10, .y = 20, .w = 100, .h = 80 };
    try std.testing.expectEqual(app.SplitRect{ .x = 10, .y = 20, .w = 50, .h = 80 }, halfRect(r, .left));
    try std.testing.expectEqual(app.SplitRect{ .x = 60, .y = 20, .w = 50, .h = 80 }, halfRect(r, .right));
    try std.testing.expectEqual(app.SplitRect{ .x = 10, .y = 20, .w = 100, .h = 40 }, halfRect(r, .top));
    try std.testing.expectEqual(app.SplitRect{ .x = 10, .y = 60, .w = 100, .h = 40 }, halfRect(r, .bottom));
    // 0xFFFFFFFF를 alpha 0x80(=128)으로 → rgb 각 255*128/255=128, a=0x80. premultiplied.
    try std.testing.expectEqual(@as(u32, 0x80_80_80_80), premultipliedRgba(0x00FF_FFFF, 0x80));
    try std.testing.expectEqual(@as(u32, 0x00_00_00_00), premultipliedRgba(0x00FF_FFFF, 0)); // alpha 0 → 전부 0
}

// 사이드바·pane 탭 라벨 "{n} {title}"(1-based) 형식 — 번호 prefix가 두 곳에서 일관되게 나오는지 고정.
test "tabNumberLabel formats {n} {title} with 1-based numbering" {
    const allocator = std.testing.allocator;
    const a = try tabNumberLabel(allocator, 0, "sh");
    defer allocator.free(a);
    try std.testing.expectEqualStrings("1 sh", a);
    const b = try tabNumberLabel(allocator, 4, "vim");
    defer allocator.free(b);
    try std.testing.expectEqualStrings("5 vim", b);
}

// paneTermRect/paneBarRect가 leaf rect 상단에서 탭 바(cell 높이 1칸)를 떼는지 — 충분히 크면 바+터미널, 너무
// 작으면 바 없음(터미널이 전체). 좌표/resize/렌더가 공유하는 '바 아래' 영역의 단일 출처라 헤드리스로 고정.
test "paneTermRect reserves a top tab-bar strip; tiny rects get no bar" {
    var session: AppSession = undefined;
    // paneBarHeightPx → buildChromeTokens가 appearance(theme·chrome_theme)를 읽으므로 undefined 세션에 명시 초기화한다
    // (chrome_theme=.tui → tab_bar_pad_y_px=0 → 바=cell 1칸). undefined 필드 읽기 UB(0xaa 우연 green) 회피.
    session.appearance = config_mod.resolveAppearance(.{}) catch unreachable;
    session.chrome_minimal = false; // paneBarHeightPx가 읽는다(false=바 있음)
    session.cell_width_px = 12;
    session.cell_height_px = 12; // paneBarHeightPx = cell_height + 2*pad_y(tui 0) = 12
    session.window_padding_px = .{}; // paneTermRect가 이제 padding을 읽는다 — 바 기하만 격리(undefined UB 회피)

    const rect: app.SplitRect = .{ .x = 180, .y = 0, .w = 800, .h = 600 };
    const term = session.paneTermRect(rect);
    try std.testing.expectEqual(app.SplitRect{ .x = 180, .y = 12, .w = 800, .h = 588 }, term); // 바 12 아래
    const bar = session.paneBarRect(rect).?;
    try std.testing.expectEqual(app.SplitRect{ .x = 180, .y = 0, .w = 800, .h = 12 }, bar);
    // 바 + 터미널 = leaf rect(틈 없음).
    try std.testing.expectEqual(rect.h, bar.h + term.h);

    // 바 높이 이하의 작은 rect는 바 없음 — 터미널이 leaf rect 전체, paneBarRect는 null.
    const tiny: app.SplitRect = .{ .x = 0, .y = 0, .w = 100, .h = 12 };
    try std.testing.expectEqual(tiny, session.paneTermRect(tiny));
    try std.testing.expect(session.paneBarRect(tiny) == null);
}

// per-pane 탭 바가 실제로 예약·렌더되는지 — 실 init/resize/tick이 도는 macOS 경로라 게이트. 터미널 영역이
// 바 아래에서 시작하고(active_pane_rect.y = 바 높이), tick이 cells 맨 앞에 바 배경 chrome 셀을 낸다.
test "pane reserves a top tab-bar strip and renders a bar chrome cell" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 창 크기를 잡는다(resize가 backing 보관 + 모든 panel을 바 아래 grid로 + active_pane_rect 재계산).
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    // 단일 panel: 터미널 영역(active_pane_rect)은 사이드바 옆·바 아래(y = 바 높이)에서 시작, 높이가 바만큼 줄었다.
    try std.testing.expectEqual(session.sidebar_width_px, session.active_pane_rect.x);
    try std.testing.expectEqual(session.paneBarHeightPx(), session.active_pane_rect.y);
    try std.testing.expect(session.active_pane_rect.h < session.backing_height_px);

    // tick이 바 chrome 셀을 포함해 크래시 없이 돈다. chrome(바 배경)은 cells 맨 앞에 prepend된다 —
    // 첫 셀은 바 top(origin_y = leaf rect top = 0)·sentinel UV(slot_id 0)·불투명 bg.
    _ = try session.tick();
    const frame = session.metalFrame();
    try std.testing.expect(frame.cell_count >= 1);
    const first = frame.cells.?[0];
    try std.testing.expectEqual(@as(u32, 0), first.origin_y);
    try std.testing.expectEqual(@as(u32, 0), first.slot_id);
    try std.testing.expectEqual(@as(u32, 0xFF), first.background >> 24); // 불투명 바 배경
}

// pane에 Term이 여럿이면 탭 바가 제목 탭들 + 활성 Term 하이라이트를 그리는지(PR-C2) — 실 init/spawn/tick이
// 도는 macOS 경로라 게이트. ⌘T로 Term 2개를 만들고 tick이 바 배경 + 활성 탭 하이라이트 chrome을 내는지 본다.
test "pane tab bar draws Term-title tabs with an active-Term highlight" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    // ⌘T → 활성 pane에 Term 2개(활성 = 1).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.activePane().active_term);

    // tick이 크래시 없이 돈다(탭 바 제목 frame + 비활성 Term은 안 그림 — 활성 Term surface만). chrome은 cells
    // 맨 앞에 바 배경(전체) + 활성 Term 탭 하이라이트(세그먼트) 두 종류가 prepend된다. 첫 둘은 origin_y 0·slot 0.
    _ = try session.tick();
    const frame = session.metalFrame();
    try std.testing.expect(frame.cell_count >= 2);
    const c0 = frame.cells.?[0]; // 바 배경(전체 폭)
    const c1 = frame.cells.?[1]; // 활성 Term 탭 하이라이트(세그먼트)
    try std.testing.expectEqual(@as(u32, 0), c0.origin_y);
    try std.testing.expectEqual(@as(u32, 0), c0.slot_id);
    try std.testing.expectEqual(@as(u32, 0), c1.origin_y);
    try std.testing.expectEqual(@as(u32, 0), c1.slot_id);
    // 하이라이트(c1)는 활성 Term(1) 세그먼트 = col tab_w(2탭이라 cols/2)에서 시작 — 바 배경(col 0)과 다르다.
    try std.testing.expect(c1.col > 0);
    try std.testing.expect(c1.width < c0.width); // 세그먼트는 바 전체보다 좁다
}

// 세로(상하) 분할에서 '아래' pane의 탭 바가 자기 y(≈ 화면 절반)에 그려지는지 — 사용자 제보(세로 분할 시
// 탭 활성화 UI가 안 갱신됨) 회귀. 가로 분할은 두 바 모두 y=0(top)이라 안 드러나지만, 세로면 아래 바가
// origin_y>0에 있어야 한다. tick chrome 셀에 origin_y>0인 바 배경 셀이 있는지로 본다.
test "vertical split renders the bottom pane tab bar at its own y (not overlapping top at 0)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    try session.splitActivePane(.vertical); // 상/하 — 아래(새) pane 활성
    try std.testing.expectEqual(@as(usize, 2), session.activeTab().panes.items.len);
    _ = try session.tick();

    const frame = session.metalFrame();
    // 위 pane 바(origin_y=0)와 아래 pane 바(origin_y>0, ≈ 화면 절반)가 둘 다 chrome으로 그려져야 한다. 그리고
    // 활성 pane(아래) 탭은 밝은 sidebarActiveBg, 비활성 pane(위) 탭은 dim sidebarHoverBg로 — 포커스 구분.
    var found_top_bar = false;
    var found_bottom_bar = false;
    var found_active_hl = false; // 활성 pane(아래)의 밝은 강조색
    var found_inactive_hl = false; // 비활성 pane(위)의 dim 강조색
    const active_bg = session.sidebarActiveBg();
    const inactive_bg = session.sidebarHoverBg();
    var i: usize = 0;
    while (i < frame.cell_count) : (i += 1) {
        const c = frame.cells.?[i];
        // chrome 바 셀: slot_id 0(배경) + row 0 + sentinel UV(u0=-1) + 불투명 bg.
        if (c.slot_id == 0 and c.row == 0 and c.u0 == -1.0 and (c.background >> 24) == 0xFF) {
            if (c.origin_y == 0) found_top_bar = true;
            if (c.origin_y > 0) found_bottom_bar = true;
            if (c.origin_y > 0 and c.background == active_bg) found_active_hl = true; // 아래(활성) = 밝게
            if (c.origin_y == 0 and c.background == inactive_bg) found_inactive_hl = true; // 위(비활성) = dim
        }
    }
    try std.testing.expect(found_top_bar);
    try std.testing.expect(found_bottom_bar); // 아래 pane 바가 자기 y(>0)에 있어야 함 — 0에 안 겹침
    try std.testing.expect(active_bg != inactive_bg); // 두 색이 달라야 구분된다
    try std.testing.expect(found_active_hl); // 활성 pane 탭 = 밝은 강조
    try std.testing.expect(found_inactive_hl); // 비활성 pane 탭 = dim 강조

    // 아래 pane(활성)에 Term 2개를 만들고, 아래 바의 탭 0을 클릭해 전환되는지(세로 분할 hit-test) 본다.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.activePane().active_term);
    // 아래 pane 바 y = 위 pane 높이(termRect.h/2 ≈ 300) + 1, 탭 0 = 바 좌단.
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const bottom_rect = lr.items[1].rect; // tree 순서: [0]=위, [1]=아래
    const bottom_bar_y: f64 = @floatFromInt(bottom_rect.y + 1);
    // 사이드바 우측 리사이즈 밴드보다 안쪽(+30) — 아래 pane은 full-width라 x가 사이드바 경계에서 시작한다.
    session.mouse(1, @floatFromInt(bottom_rect.x + 30), bottom_bar_y, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), session.activePane().active_term); // 아래 바 탭 0으로 전환
}

// 탭 바의 탭을 클릭하면 그 Term으로 전환하는지(PR-D1) — 실 init/spawn이라 macOS 게이트. ⌘T로 Term 2개(활성
// =1)를 만들고 탭 0 영역(바 좌단)을 클릭하면 활성 Term이 0으로, 다시 탭 1을 클릭하면 1로 돌아온다.
test "clicking a tab in the pane bar switches to that Term" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    // ⌘T → Term 2개, 활성 = 1.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.activePane().active_term);

    // 탭 바는 단일 panel이라 터미널 영역 전체 폭의 상단 strip(y in [0, 바 높이)). 탭 0 = 바 좌단, 탭 1 = 바 우반.
    const bar_y: f64 = 1; // 바 안(y < 바 높이)
    const left_tab_x: f64 = @floatFromInt(session.sidebar_width_px + 30); // 탭 0 세그먼트(사이드바 우측 리사이즈 밴드보다 안쪽)
    session.mouse(1, left_tab_x, bar_y, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), session.activePane().active_term); // 탭 0으로 전환

    // 탭 1(바 우반, 2탭이라 폭의 절반 이후) 클릭 → 다시 Term 1.
    const right_tab_x: f64 = @floatFromInt(session.sidebar_width_px + 600); // 바 폭(800)의 우반
    session.mouse(1, right_tab_x, bar_y, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), session.activePane().active_term);

    // 탭 바 클릭은 터미널 선택을 시작하지 않는다(소비). 선택 드래그 플래그가 안 켜진다.
    try std.testing.expect(!session.mouse_drag_selecting);
}

// 탭에 호버하면 ✕가 뜨고(hovered_tab 설정), 그 ✕ zone을 클릭하면 그 Term이 닫히는지(PR-D2) — 실 init/spawn/
// teardown이라 macOS 게이트. ⌘T로 Term 3개를 만들고, 탭 1의 ✕ zone에 호버 후 클릭해 Term이 2개로 준다.
test "hovering a tab shows a close X; clicking it closes that Term" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    // ⌘T 두 번 → Term 3개. 단일 panel이라 바 폭 = 터미널 폭(800/cw cols), 3탭 등폭.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 3), session.activePane().terms.items.len);

    // 활성 pane의 바 rect를 구해 탭 1의 ✕ zone x를 계산한다.
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const bar = session.paneBarRect(lr.items[0].rect).?;
    const m = barMetrics(bar, session.cell_width_px, 3, 0, 0).?;
    // 탭 1 ✕ zone col = (1+1)*tab_w - 1(우측 안쪽). x = bar.x + (2*tab_w - 1)*cw.
    const close_x: f64 = @floatFromInt(bar.x + (2 * m.tab_w - 1) * session.cell_width_px);
    const bar_y: f64 = @floatFromInt(bar.y + 1);

    // 호버 → hovered_tab이 (활성 pane, 탭 1)로 설정된다(✕가 그려질 대상).
    _ = session.hoverCursor(close_x, bar_y, false);
    try std.testing.expect(session.hovered_tab != null);
    try std.testing.expectEqual(@as(usize, 1), session.hovered_tab.?.tab);
    try std.testing.expect(m.inCloseZone(1, close_x)); // ✕ zone 안

    // ✕ 클릭 → 탭 1 Term 닫힘 → 2개. 닫은 뒤 호버는 비워진다(stale 방지).
    session.mouse(1, close_x, bar_y, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
    try std.testing.expect(session.hovered_tab == null);
    try std.testing.expect(!session.ended_seen); // 아직 Term 남음 — 세션 유지
}

// 바 우측 "+" 버튼을 클릭하면 그 pane에 새 Term이 뜨는지(PR-F) — ⌘T의 마우스 버전. 실 init/spawn이라 macOS 게이트.
// 단일 pane으로 시작(Term 1개) → 바의 "+" zone을 클릭하면 activePane.terms가 2개가 되고 새 Term이 활성.
test "clicking the bar '+' button spawns a new Term in that pane" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    try std.testing.expectEqual(@as(usize, 1), session.activePane().terms.items.len);

    // 활성 pane(단일)의 바 rect → "+" zone x를 계산한다.
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const bar = session.paneBarRect(lr.items[0].rect).?;
    const m = barMetrics(bar, session.cell_width_px, 1, 0, 0).?;
    try std.testing.expect(m.hasPlusZone()); // 바가 넓어 "+" zone이 존재
    // "+" zone = col [tab_cols, cols). 첫 col 중앙을 클릭.
    const plus_x: f64 = @floatFromInt(bar.x + m.tab_cols * session.cell_width_px + session.cell_width_px / 2);
    const bar_y: f64 = @floatFromInt(bar.y + 1);
    try std.testing.expect(m.inPlusZone(plus_x)); // "+" zone 안

    // "+" 클릭 → 새 Term → 2개.
    session.mouse(1, plus_x, bar_y, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
    try std.testing.expect(!session.ended_seen); // 세션 유지
}

// "+" zone 위에 호버하면 마지막 탭에 ✕가 잘못 뜨면 안 된다(updateHoveredTab이 inPlusZone을 먼저 검사). PR-F가
// tabIndexInBar의 우측 clamp 때문에 "+" 위 호버를 마지막 탭으로 오인해 ✕를 그리던 회귀를 고정한다. 실 init/spawn.
test "hovering the '+' button does not mark the last tab for close" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } }); // Term 2개

    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const bar = session.paneBarRect(lr.items[0].rect).?;
    const m = barMetrics(bar, session.cell_width_px, 2, 0, 0).?;
    const bar_y: f64 = @floatFromInt(bar.y + 1);

    // 마지막 탭(탭 1) 위 호버 → hovered_tab = 탭 1(정상).
    const tab1_x: f64 = @floatFromInt(bar.x + (m.tab_cols - 1) * session.cell_width_px); // 탭 영역 우측 끝(탭 1)
    _ = session.hoverCursor(tab1_x, bar_y, false);
    try std.testing.expect(session.hovered_tab != null);
    try std.testing.expectEqual(@as(usize, 1), session.hovered_tab.?.tab);

    // "+" zone 위 호버 → hovered_tab 비워짐(마지막 탭로 clamp되지 않는다 — ✕ 오표시 방지).
    const plus_x: f64 = @floatFromInt(bar.x + m.tab_cols * session.cell_width_px + session.cell_width_px / 2);
    try std.testing.expect(m.inPlusZone(plus_x));
    _ = session.hoverCursor(plus_x, bar_y, false);
    try std.testing.expect(session.hovered_tab == null);
}

// 탭을 드래그하면 pane 안에서 순서가 바뀌는지(PR-E1) — 실 init/spawn이라 macOS 게이트. ⌘T로 Term 3개를
// 만들고, 탭 0을 탭 2 위치로 드래그(down→drag→up)하면 terms 순서가 [T1,T2,T0]로 회전하고 드래그 탭이 활성.
test "dragging a Term tab reorders it within the pane" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    const pane = session.activePane();
    try std.testing.expectEqual(@as(usize, 3), pane.terms.items.len);
    const id0 = pane.terms.items[0].surface.id; // 드래그할 탭(T0)
    const id1 = pane.terms.items[1].surface.id;
    const id2 = pane.terms.items[2].surface.id;

    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const bar = session.paneBarRect(lr.items[0].rect).?;
    const m = barMetrics(bar, session.cell_width_px, 3, 0, 0).?;
    const tab0_x: f64 = @floatFromInt(bar.x + (0 * m.tab_w + 1) * session.cell_width_px); // 탭 0 세그먼트(✕ 아님)
    const tab2_x: f64 = @floatFromInt(bar.x + (2 * m.tab_w + 1) * session.cell_width_px); // 탭 2 세그먼트
    const bar_y: f64 = @floatFromInt(bar.y + 1);

    // 탭 0 down → 드래그 arm. drag to 탭 2 → 재정렬. up → 종료.
    session.mouse(1, tab0_x, bar_y, 0, 0);
    try std.testing.expect(session.tab_drag_active);
    session.mouse(2, tab2_x, bar_y, 0, 0);
    session.mouse(3, tab2_x, bar_y, 0, 0);
    try std.testing.expect(!session.tab_drag_active);

    // [T0,T1,T2] → T0를 2로 옮기면 [T1,T2,T0]. 드래그 탭(T0)이 새 위치(2)에서 활성.
    try std.testing.expectEqual(id1, pane.terms.items[0].surface.id);
    try std.testing.expectEqual(id2, pane.terms.items[1].surface.id);
    try std.testing.expectEqual(id0, pane.terms.items[2].surface.id);
    try std.testing.expectEqual(@as(usize, 2), pane.active_term);
    try std.testing.expectEqual(id0, session.activeTab().activeTerm().surface.id); // 활성 = 드래그한 T0
}

// 탭을 다른 pane으로 드래그하면 그 pane으로 Term이 옮겨가고, 소스 pane의 마지막 Term이 나가면 collapse되는지
// (PR-E2) — 실 init/split/spawn/teardown이라 macOS 게이트. 좌우 split에서 오른쪽 pane의 탭을 왼쪽 pane 바에
// drop한다. ① 오른쪽에 Term 2개면 1개만 옮기고 collapse 없음 ② 마지막 1개를 옮기면 오른쪽 collapse.
test "dragging a tab to another pane moves the Term; emptying the source collapses it" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    try session.splitActivePane(.horizontal); // 좌(기존)·우(새, 활성)
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } }); // 우 pane Term 2개
    const right = session.activePane();
    try std.testing.expectEqual(@as(usize, 2), right.terms.items.len);

    // leaf rect로 좌/우 pane과 바를 잡는다(tree 순서: [0]=좌, [1]=우).
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const left = lr.items[0].leaf;
    try std.testing.expect(lr.items[1].leaf == right);
    const left_bar = session.paneBarRect(lr.items[0].rect).?;
    const right_bar = session.paneBarRect(lr.items[1].rect).?;
    const moved_id = right.terms.items[0].surface.id; // 옮길 Term(우 탭 0)

    // ① 우 탭 0을 좌 pane 바에 drop → 좌 2개·우 1개, 좌 활성. collapse 없음(우에 1개 남음).
    session.mouse(1, @floatFromInt(right_bar.x + 5), @floatFromInt(right_bar.y + 1), 0, 0); // down on 우 탭 0
    try std.testing.expect(session.tab_drag_active);
    session.mouse(3, @floatFromInt(left_bar.x + 5), @floatFromInt(left_bar.y + 1), 0, 0); // up over 좌 바 → cross-move
    try std.testing.expectEqual(@as(usize, 2), session.activeTab().panes.items.len); // 아직 2 pane
    try std.testing.expectEqual(@as(usize, 1), right.terms.items.len);
    try std.testing.expectEqual(@as(usize, 2), left.terms.items.len);
    try std.testing.expectEqual(left, session.activePane()); // 옮긴 곳이 활성
    var found = false;
    for (left.terms.items) |t| {
        if (t.surface.id == moved_id) found = true;
    }
    try std.testing.expect(found); // 옮긴 Term이 좌 pane에 있다

    // ② 우 pane의 '마지막' Term을 좌로 drop → 우 비어 collapse → 단일 pane(좌, Term 3개).
    session.mouse(1, @floatFromInt(right_bar.x + 5), @floatFromInt(right_bar.y + 1), 0, 0); // down on 우 탭 0(마지막)
    session.mouse(3, @floatFromInt(left_bar.x + 5), @floatFromInt(left_bar.y + 1), 0, 0); // up over 좌 바
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().panes.items.len); // 우 collapse → 1 pane
    try std.testing.expectEqual(@as(usize, 1), PaneTree.leafCount(session.activeTab().tree));
    try std.testing.expectEqual(@as(usize, 3), session.activePane().terms.items.len); // 좌가 3개 다 가짐
    try std.testing.expect(!session.ended_seen);
}

// ④: Term 탭을 다른 pane '본문 가장자리'에 드롭하면 거기에 새 split이 생기는지(split 재배치). 좌우 split에서
// 오른쪽 pane(단일 Term)의 탭을 왼쪽 pane 본문 '좌측 절반'에 drop → 왼쪽 자리에 split{새, 좌}(좌우), 오른쪽은
// 비어 collapse → 결과적으로 [새(옮긴 Term), 좌] 좌우 배치. 실 init/split/spawn/teardown이라 macOS 게이트.
test "④: dropping a tab on a pane body edge creates a new split there (rearrange)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    try session.splitActivePane(.horizontal); // 좌(기존)·우(새, 활성), 각 Term 1개
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const right = session.activePane();
    try std.testing.expect(lr.items[1].leaf == right);
    const left_body = session.paneTermRect(lr.items[0].rect); // 좌 pane 본문(바 아래)
    const right_bar = session.paneBarRect(lr.items[1].rect).?;
    const moved_id = right.terms.items[0].surface.id; // 옮길 Term(우 pane의 유일 Term)

    // 우 pane 탭 down(드래그 arm) → 좌 pane 본문 '좌측 절반'에 up(drop). 우는 비어 collapse, 새 split 좌우.
    session.mouse(1, @floatFromInt(right_bar.x + 5), @floatFromInt(right_bar.y + 1), 0, 0);
    try std.testing.expect(session.tab_drag_active);
    const drop_x: f64 = @floatFromInt(left_body.x + left_body.w / 10); // 좌측 가장자리 근처
    const drop_y: f64 = @floatFromInt(left_body.y + left_body.h / 2);
    try std.testing.expectEqual(PaneDropZone.left, paneDropZone(left_body, drop_x, drop_y).?);
    session.mouse(3, drop_x, drop_y, 0, 0);

    // 여전히 2 pane(새 + 좌), leafCount 2. 옮긴 Term은 새(활성) pane에, 그게 가장 왼쪽.
    try std.testing.expectEqual(@as(usize, 2), session.activeTab().panes.items.len);
    try std.testing.expectEqual(@as(usize, 2), PaneTree.leafCount(session.activeTab().tree));
    try std.testing.expectEqual(@as(usize, 1), session.activePane().terms.items.len);
    try std.testing.expectEqual(moved_id, session.activePane().activeTerm().surface.id); // 새 pane이 옮긴 Term·활성
    var lr2: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr2.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr2);
    try std.testing.expectEqual(@as(usize, 2), lr2.items.len);
    try std.testing.expect(lr2.items[0].leaf == session.activePane()); // 새 pane이 좌측(left zone)
    try std.testing.expect(lr2.items[0].rect.x < lr2.items[1].rect.x); // 좌우 배치
    try std.testing.expect(!session.ended_seen);
    _ = try session.tick();
}

// ④b: 탭 드래그 중 드롭 타겟 zone이 추적되고 반투명 하이라이트 셀이 나오는지 — drag(2)가 computeDropTarget로
// tab_drop_target을 세팅, up이 비운다. 실 init/split/spawn이라 macOS 게이트.
test "④b: tab drag tracks the drop target and emits a translucent highlight" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    try session.splitActivePane(.horizontal); // 좌(기존)·우(새, 활성)
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const left = lr.items[0].leaf;
    const left_body = session.paneTermRect(lr.items[0].rect);
    const left_bar = session.paneBarRect(lr.items[0].rect).?;
    const right_bar = session.paneBarRect(lr.items[1].rect).?;

    // 우 pane 탭 down(드래그 arm). 처음엔 드롭 타겟 없음.
    session.mouse(1, @floatFromInt(right_bar.x + 5), @floatFromInt(right_bar.y + 1), 0, 0);
    try std.testing.expect(session.tab_drag_active);
    try std.testing.expect(session.tab_drop_target == null);

    // drag(2)로 좌 pane 본문 상단 절반 위 → 드롭 타겟 = {좌, top}.
    session.mouse(2, @floatFromInt(left_body.x + left_body.w / 2), @floatFromInt(left_body.y + left_body.h / 5), 0, 0);
    try std.testing.expect(session.tab_drop_target != null);
    try std.testing.expectEqual(left, session.tab_drop_target.?.pane);
    try std.testing.expectEqual(PaneDropZone.top, session.tab_drop_target.?.zone.?);

    // 하이라이트 셀이 나온다(반투명: premultiplied alpha 0x55, reserved 0 fill).
    var hl: std.ArrayList(metal_frame.NativeMetalCell) = .empty;
    defer hl.deinit(allocator);
    session.appendDropTargetHighlight(&hl);
    try std.testing.expect(hl.items.len > 0);
    for (hl.items) |c| {
        try std.testing.expectEqual(@as(u8, 0x55), @as(u8, @intCast((c.background >> 24) & 0xFF))); // alpha
        try std.testing.expectEqual(@as(u16, 0), c.reserved); // 채우기(부분 사각형 아님)
    }

    // drag(2)로 좌 pane 탭 바 위 → 드롭 타겟 = {좌, null}(이동).
    session.mouse(2, @floatFromInt(left_bar.x + 5), @floatFromInt(left_bar.y + 1), 0, 0);
    try std.testing.expect(session.tab_drop_target != null);
    try std.testing.expect(session.tab_drop_target.?.zone == null);

    // up → 드롭 타겟 비워짐(하이라이트 사라짐).
    session.mouse(3, @floatFromInt(left_bar.x + 5), @floatFromInt(left_bar.y + 1), 0, 0);
    try std.testing.expect(session.tab_drop_target == null);
    var hl2: std.ArrayList(metal_frame.NativeMetalCell) = .empty;
    defer hl2.deinit(allocator);
    session.appendDropTargetHighlight(&hl2);
    try std.testing.expectEqual(@as(usize, 0), hl2.items.len);
    _ = try session.tick();
}

// 탭 드래그 중 마우스를 따라가는 floating 탭 미리보기 frame이 빌드되는지 — drag(2)가 tab_drag_x/y를 갱신하고,
// buildFloatingTabFrame이 그때만 non-null frame을 준다. 실 init/spawn·CoreText라 macOS 게이트.
test "floating tab preview frame is built (and positioned) while dragging a tab" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } }); // Term 2개

    const builder = coretext_frame_builder.CoreTextFrameBuilder{
        .appearance = session.appearance,
        .shape_draw_list = coretext_bridge.maru_macos_coretext_shape_draw_list,
        .rasterize_glyph = coretext_bridge.maru_macos_coretext_smoke_rasterize_glyph,
        .scale_milli = session.scale_milli,
        .cell_width_px = @intCast(session.cell_width_px),
        .cell_height_px = @intCast(session.cell_height_px),
    };
    var built: std.ArrayList(renderer.RenderFrame) = .empty;
    defer {
        for (built.items) |*bf| bf.deinit(allocator);
        built.deinit(allocator);
    }

    // 드래그 전엔 floating 탭 없음.
    try std.testing.expect(session.buildFloatingTabFrame(builder, &built) == null);

    // 탭 down(arm) → drag(2)로 마우스 이동 → tab_drag_x/y 갱신.
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const bar = session.paneBarRect(lr.items[0].rect).?;
    session.mouse(1, @floatFromInt(bar.x + 20), @floatFromInt(bar.y + 1), 0, 0); // 탭 down → arm
    try std.testing.expect(session.tab_drag_active);
    session.mouse(2, 333, 222, 0, 0); // 드래그
    try std.testing.expectEqual(@as(f64, 333), session.tab_drag_x);
    try std.testing.expectEqual(@as(f64, 222), session.tab_drag_y);

    // 드래그 중엔 floating 탭 frame이 빌드된다(커서 중심에 박스).
    const pf = session.buildFloatingTabFrame(builder, &built);
    try std.testing.expect(pf != null);
    try std.testing.expect(pf.?.origin_x < 333); // 박스가 커서 좌측으로 센터됨(폭/2 만큼)

    // up → 드래그 끝 → floating 탭 없음.
    session.mouse(3, 333, 222, 0, 0);
    try std.testing.expect(!session.tab_drag_active);
    try std.testing.expect(session.buildFloatingTabFrame(builder, &built) == null);
    _ = try session.tick();
}

// split 탭에서 다른 panel을 클릭하면 포커스가 그 panel로 옮겨가고(입력/커서가 따라간다), 활성 panel을
// 클릭하면 그대로인지 — 실 init이 사이드바 폭/메트릭을 채우고 mouse hit-test가 leaf rect를 펴는 macOS
// 경로라 게이트한다. 좌표 origin(active_pane_rect)이 새 활성 panel로 갱신되는 것도 함께 본다.
test "clicking another pane in a split focuses it; clicking the active pane keeps focus" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    session.backing_width_px = session.sidebar_width_px + 800;
    session.backing_height_px = 600;
    session.window_padding_px = .{}; // split 기하만 검증 — window padding(기본 8/4) inset은 gridFromBacking·loader 테스트가 커버
    const old_surface = session.activeSurface();
    try session.splitActivePane(.horizontal); // 좌우 분할 — 새 panel(오른쪽)이 활성
    const new_surface = session.activeSurface();
    try std.testing.expect(new_surface != old_surface);
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().active_pane);

    // 클릭은 탭 바 '아래'(터미널 영역)에서 — 바 클릭은 Term 탭 전환이라 panel 터미널 hit-test와 구분된다.
    const click_y: f64 = @floatFromInt(session.paneBarHeightPx() + 20);
    // 왼쪽(기존, 비활성) panel 영역 클릭 → 포커스가 기존 panel로. 좌표 origin도 왼쪽 rect(사이드바 옆)로 갱신.
    const left_x: f64 = @floatFromInt(session.sidebar_width_px + 10);
    session.mouse(1, left_x, click_y, 0, 0);
    try std.testing.expectEqual(old_surface, session.activeSurface());
    try std.testing.expectEqual(@as(usize, 0), session.activeTab().active_pane);
    try std.testing.expectEqual(session.sidebar_width_px, session.active_pane_rect.x);

    // 활성(왼쪽) panel을 다시 클릭 → 전환 없음(같은 panel 클릭은 선택 경로). active_pane 불변.
    session.mouse(1, left_x, click_y, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), session.activeTab().active_pane);

    // 오른쪽(비활성) panel 클릭 → 다시 오른쪽 panel로 포커스.
    const right_x: f64 = @floatFromInt(session.sidebar_width_px + 410);
    session.mouse(1, right_x, click_y, 0, 0);
    try std.testing.expectEqual(new_surface, session.activeSurface());
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().active_pane);
}

// 비활성 panel 위 휠 스크롤이 그 panel(커서 아래)로 라우팅되는지 — 좌우 split에서 오른쪽이 활성이어도 왼쪽
// (비활성) 위에서 스크롤하면 왼쪽 뷰포트가 움직이고 오른쪽은 그대로다(포커스도 안 바뀐다). 실 init/split이라 macOS 게이트.
test "wheel over an inactive pane scrolls that pane (not the active one)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    try session.splitActivePane(.horizontal); // 좌(기존)·우(새, 활성)

    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const left_surface = &lr.items[0].leaf.activeTerm().surface;
    const right_surface = &lr.items[1].leaf.activeTerm().surface;
    // 양쪽에 스크롤백을 만든다(split 후 pane은 창 높이만큼 행이 커서 100줄로 충분히 넘긴다). 비-alt-screen이라 휠=뷰포트.
    try left_surface.core.write("L\r\n" ** 100);
    try right_surface.core.write("R\r\n" ** 100);
    try std.testing.expectEqual(@as(usize, 0), left_surface.core.view_offset);
    try std.testing.expectEqual(@as(usize, 0), right_surface.core.view_offset);

    const left_body = session.paneTermRect(lr.items[0].rect);
    const right_body = session.paneTermRect(lr.items[1].rect);
    // 왼쪽(비활성) 본문 위에서 위로 스크롤 → 왼쪽 뷰포트만 위로(과거), 오른쪽 불변·활성 pane 불변.
    session.scrollWheel(3, 0, false, @floatFromInt(left_body.x + left_body.w / 2), @floatFromInt(left_body.y + left_body.h / 2));
    try std.testing.expect(left_surface.core.view_offset > 0);
    try std.testing.expectEqual(@as(usize, 0), right_surface.core.view_offset);
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().active_pane); // 포커스 안 바뀜

    // 오른쪽(활성) 본문 위에서 스크롤 → 오른쪽 뷰포트가 움직인다.
    session.scrollWheel(3, 0, false, @floatFromInt(right_body.x + right_body.w / 2), @floatFromInt(right_body.y + right_body.h / 2));
    try std.testing.expect(right_surface.core.view_offset > 0);
}

// #2b: 트랙패드 가로 스와이프(scroll_wheel delta_x)가 커서 아래 pane 탭 바를 가로 스크롤하는지 — rich 고정폭에서
// 탭이 넘칠 때만(has_scroll). natural 방향: 왼쪽 스와이프(delta_x<0)→오른쪽 탭(scroll 증가), 오른쪽(delta_x>0)→감소.
// delta_y=0이라 터미널 뷰포트는 안 움직인다(독립 축). 실 init/탭이라 macOS 게이트.
test "horizontal trackpad swipe scrolls the overflowing tab bar of the pane under the cursor" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.appearance.chrome_theme = .rich; // 고정폭 탭(tab_width_cols>0) — 넘쳐야 ‹›/has_scroll
    _ = try session.resize(session.sidebar_width_px + 400, 300, session.scale_milli);
    for (0..6) |_| session.newTermInActivePane() catch {}; // 탭 여러 개 → 고정폭×N이 바를 넘침
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const leaf = lr.items[0].leaf;
    const bar = session.paneBarRect(lr.items[0].rect).?;
    const bx: f64 = @floatFromInt(bar.x + bar.w / 2);
    const by: f64 = @floatFromInt(bar.y + 1);
    // 넘침 전제(has_scroll) 확인 — 아니면 가로 스크롤 자체가 무의미.
    const m = barMetrics(bar, session.cell_width_px, leaf.terms.items.len, session.buildChromeTokens().space.tab_width_cols, leaf.tab_scroll_cols).?;
    try std.testing.expect(m.has_scroll);
    // newTerm가 마지막 탭을 활성화하며 자동 스크롤-인(#508)하므로 시작 tab_scroll_cols는 끝 쪽(>0)이다 — 가로 스와이프가
    // 클릭/⌘[]와 같은 tab_scroll_cols 상태를 공유한다는 방증.
    const start = leaf.tab_scroll_cols;
    try std.testing.expect(start > 0);
    // 오른쪽 스와이프(delta_x>0) → 왼쪽 탭(scroll 감소).
    session.scrollWheel(0, 100, false, bx, by);
    try std.testing.expect(leaf.tab_scroll_cols < start);
    // 왼쪽 스와이프(delta_x<0) → 오른쪽 탭(scroll 증가, 되돌아감).
    const mid = leaf.tab_scroll_cols;
    session.scrollWheel(0, -100, false, bx, by);
    try std.testing.expect(leaf.tab_scroll_cols > mid);
}

// Cmd+Option+화살표가 키 경로(handleKeyEvent → resolver → app_action → focusPaneInDirection)로 pane 포커스를
// 방향 이동하는지 — 실 init + 실제 분할이라 macOS 게이트. 좌우 split에서 좌/우는 전환, 위/아래는 불변.
test "Cmd+Option+arrow moves pane focus directionally through the key path" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    session.backing_width_px = session.sidebar_width_px + 800;
    session.backing_height_px = 600;
    session.window_padding_px = .{}; // split 기하만 검증 — window padding(기본 8/4) inset은 gridFromBacking·loader 테스트가 커버
    const old_surface = session.activeSurface();
    try session.splitActivePane(.horizontal); // 좌우 분할 — 오른쪽(새) panel 활성
    const new_surface = session.activeSurface();
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().active_pane);

    const mods: terminal.ModifierSet = .{ .command = true, .option = true };
    // Cmd+Opt+Left → 왼쪽(기존) panel로.
    _ = try session.handleKeyEvent(.{ .key = .arrow_left, .modifiers = mods });
    try std.testing.expectEqual(old_surface, session.activeSurface());
    try std.testing.expectEqual(@as(usize, 0), session.activeTab().active_pane);

    // Cmd+Opt+Right → 오른쪽(새) panel로.
    _ = try session.handleKeyEvent(.{ .key = .arrow_right, .modifiers = mods });
    try std.testing.expectEqual(new_surface, session.activeSurface());
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().active_pane);

    // Cmd+Opt+Up → 좌우 split이라 위 panel 없음 → 포커스 불변.
    _ = try session.handleKeyEvent(.{ .key = .arrow_up, .modifiers = mods });
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().active_pane);
}

// Cmd+W가 split 탭에서 활성 panel을 먼저 닫고(트리 collapse + 남은 panel이 빈자리 차지), 단일 panel이 되면
// 그땐 탭을 닫는지(계층 cascade 정책) — 실 init + 실제 분할/teardown이라 macOS 게이트. 키 경로(handleKeyEvent)로 돈다.
test "Cmd+W closes the active pane first and collapses the split, leaving the sibling" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    session.backing_width_px = session.sidebar_width_px + 800;
    session.backing_height_px = 600;
    session.window_padding_px = .{}; // split 기하만 검증 — window padding(기본 8/4) inset은 gridFromBacking·loader 테스트가 커버
    const left = session.activeSurface(); // 분할 전 surface = 분할 후 왼쪽(기존) panel
    try session.splitActivePane(.horizontal); // 좌우 — 오른쪽(새) panel 활성, 2 panes
    try std.testing.expectEqual(@as(usize, 2), session.activeTab().panes.items.len);
    try std.testing.expect(session.activeTabHasSplit());

    // Cmd+W → 활성(오른쪽) panel 닫힘 → 트리가 형제(왼쪽)로 collapse → 1 panel만 남고 그게 활성.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'w' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().panes.items.len);
    try std.testing.expectEqual(left, session.activeSurface());
    try std.testing.expectEqual(@as(usize, 0), session.activeTab().active_pane);
    try std.testing.expect(!session.activeTabHasSplit());
    try std.testing.expectEqual(@as(usize, 1), PaneTree.leafCount(session.activeTab().tree));
    // 남은 panel이 빈자리를 차지해 터미널 영역 전체로 resize됐다(좌표 origin도 사이드바 옆·전체 폭).
    try std.testing.expectEqual(session.sidebar_width_px, session.active_pane_rect.x);
    try std.testing.expectEqual(@as(u32, 800), session.active_pane_rect.w);

    // 세션은 아직 살아 있다(panel이 닫혔을 뿐 탭/창은 그대로) — 다음 tick이 크래시 없이 돈다.
    try std.testing.expect(!session.ended_seen);
    _ = try session.tick();
}

// PR6(divider 드래그 리사이즈): 좌우 split의 divider를 잡아 끌면 split.ratio가 바뀌어 panel이 재배치된다.
// down이 divider 밴드에서 시작하면 divider_drag를 잡고, drag가 마우스→ratio로 매핑, up이 끝낸다. 실 init/spawn.
test "PR6: dragging a split divider resizes the panes via split.ratio" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    try session.splitActivePane(.horizontal); // 좌우 — 오른쪽(새) pane 활성, ratio 0.5
    try std.testing.expectEqual(@as(usize, 2), session.activeTab().panes.items.len);

    // 활성 탭 divider(1개, 세로선)를 구해 그 위를 클릭한다 — y는 터미널 영역 중간(바 아래).
    var segs: std.ArrayList(PaneTree.DividerSeg) = .empty;
    defer segs.deinit(allocator);
    try session.layoutActiveTabDividers(&segs);
    try std.testing.expectEqual(@as(usize, 1), segs.items.len);
    const seg = segs.items[0];
    try std.testing.expectEqual(app.SplitDirection.horizontal, seg.direction);
    const split = seg.split;
    const div_x: f64 = @floatFromInt(seg.pos);
    const div_y: f64 = @floatFromInt(seg.bounds.y + seg.bounds.h / 2);

    // 활성(=오른쪽) pane의 현재 폭. 초기 ratio 0.5.
    const right_w_before = session.active_pane_rect.w;
    try std.testing.expect(split.ratio > 0.45 and split.ratio < 0.55);

    // down on divider → 드래그 시작.
    session.mouse(1, div_x, div_y, 0, 0);
    try std.testing.expect(session.divider_drag != null);

    // 왼쪽으로 200px 드래그 → ratio = 200/800 = 0.25(왼쪽 작아지고 오른쪽=활성 커진다).
    session.mouse(2, div_x - 200, div_y, 0, 0);
    try std.testing.expect(split.ratio < 0.3); // 왼쪽 비율 감소
    try std.testing.expect(session.active_pane_rect.w > right_w_before); // 오른쪽 pane 넓어짐

    // up → 드래그 종료.
    session.mouse(3, div_x - 200, div_y, 0, 0);
    try std.testing.expect(session.divider_drag == null);

    // divider가 아닌 곳(왼쪽 pane 터미널 중앙) down은 divider 드래그를 시작하지 않는다.
    session.mouse(1, @floatFromInt(seg.bounds.x + 20), div_y, 0, 0);
    try std.testing.expect(session.divider_drag == null);
    _ = try session.tick();
}

// divider가 full-cell이 아니라 얇은 선(렌더러 부분 사각형 reserved=3 bar / 2 underline)으로 그려지는지 — 너무
// 굵어 터미널을 가리던 문제 수정. 좌우 split=세로선(reserved=3, 행마다·경계 x 센터), 상하 split=가로선(reserved=2).
test "split dividers render as thin lines (reserved bar/underline), not full cells" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    // 좌우 split → 세로 divider. 모든 divider 셀이 reserved=3(bar=얇은 세로선), 경계 x 근처(±cw)에 센터.
    try session.splitActivePane(.horizontal);
    var segs: std.ArrayList(PaneTree.DividerSeg) = .empty;
    defer segs.deinit(allocator);
    try session.layoutActiveTabDividers(&segs);
    const seam_x = segs.items[0].pos;
    var cells: std.ArrayList(metal_frame.NativeMetalCell) = .empty;
    defer cells.deinit(allocator);
    session.appendActiveTabDividers(&cells);
    try std.testing.expect(cells.items.len > 1); // 행마다 한 셀 → 여러 개
    for (cells.items) |c| {
        try std.testing.expectEqual(@as(u16, 3), c.reserved); // bar
        try std.testing.expectEqual(@as(u16, 1), c.width); // 한 칸(부분 사각형이 ~2px만 칠함)
        try std.testing.expect(c.origin_x + 1 >= seam_x and c.origin_x <= seam_x + 1); // 경계 x 센터
    }

    // 상하 split → 가로 divider는 reserved=2(셀 하단 가로선) 한 칸(폭=cols).
    try session.splitActivePane(.vertical);
    cells.clearRetainingCapacity();
    session.appendActiveTabDividers(&cells);
    var saw_underline = false;
    for (cells.items) |c| {
        if (c.reserved == 2) {
            saw_underline = true;
            try std.testing.expect(c.width > 1); // 가로선은 bounds 폭만큼
        }
    }
    try std.testing.expect(saw_underline);
}

// hoverCursor가 위치별 커서 종류를 돌려주는지(터미널=text, divider=resize, 탭 바/사이드바=default) — 전부
// I-beam이던 걸 영역별로 바꾸는 hit-test의 코어라 결정적으로 고정한다. 실 init/spawn이라 macOS 게이트.
test "hoverCursor returns region-specific cursor kinds" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    // 단일 pane: 터미널 영역(바 아래) = text(iBeam).
    const term_x: f64 = @floatFromInt(session.active_pane_rect.x + 50);
    const term_y: f64 = @floatFromInt(session.active_pane_rect.y + 50);
    try std.testing.expectEqual(CursorKind.text, session.hoverCursor(term_x, term_y, false));

    // pane 탭 바 위 = link(pointingHand) — #5c: 탭·‹/›·+·pane 포커스 모두 클릭 가능.
    var lr: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer lr.deinit(allocator);
    try session.activeTabLeafRects(allocator, session.termRect(), &lr);
    const bar = session.paneBarRect(lr.items[0].rect).?;
    try std.testing.expectEqual(CursorKind.link, session.hoverCursor(@floatFromInt(bar.x + 20), @floatFromInt(bar.y + 1), false));

    // 사이드바 워크스페이스 슬롯 위 = link(클릭=전환), "+" 슬롯 아래 빈 영역 = default(arrow) — #5c.
    if (session.sidebar_width_px > 0 and session.sidebar_slot_height_px > 0) {
        const sb_x: f64 = @floatFromInt(session.sidebar_width_px / 2);
        const slot0_y: f64 = @as(f64, @floatFromInt(session.sidebar_header_height_px)) + @as(f64, @floatFromInt(session.sidebar_slot_height_px / 2)); // 슬롯 0 중앙(상단 헤더 아래) — 확실히 슬롯 안
        try std.testing.expectEqual(CursorKind.link, session.hoverCursor(sb_x, slot0_y, false));
        const empty_y: f64 = @floatFromInt((session.tabs.items.len + 2) * session.sidebar_slot_height_px); // "+" 슬롯 아래(빈)
        try std.testing.expectEqual(CursorKind.default, session.hoverCursor(sb_x, empty_y, false));
    }

    // 좌우 split → 세로 divider 위 = resize_h(↔). 상하 split → 가로 divider 위 = resize_v(↕).
    try session.splitActivePane(.horizontal);
    var segs: std.ArrayList(PaneTree.DividerSeg) = .empty;
    defer segs.deinit(allocator);
    try session.layoutActiveTabDividers(&segs);
    const hseg = segs.items[0];
    const hdiv_y: f64 = @floatFromInt(hseg.bounds.y + hseg.bounds.h / 2);
    try std.testing.expectEqual(CursorKind.resize_h, session.hoverCursor(@floatFromInt(hseg.pos), hdiv_y, false));

    try session.splitActivePane(.vertical);
    segs.clearRetainingCapacity();
    try session.layoutActiveTabDividers(&segs);
    var saw_v = false;
    for (segs.items) |seg| {
        if (seg.direction == .vertical) {
            saw_v = true;
            const vdiv_x: f64 = @floatFromInt(seg.bounds.x + seg.bounds.w / 2);
            // seam 바로 위(밴드 안·위쪽 pane 터미널 영역). 정확히 seam y면 아래 pane 탭 바가 잡혀 default다(탭 바 우선).
            const vdiv_y: f64 = @floatFromInt(seg.pos - 3);
            try std.testing.expectEqual(CursorKind.resize_v, session.hoverCursor(vdiv_x, vdiv_y, false));
        }
    }
    try std.testing.expect(saw_v);
}

// PR5b(exit 자동 collapse): 개별 Term의 셸이 exit하면 그 Term을 자동으로 닫고(Term→pane→워크스페이스 cascade)
// 살아있는 Term이 남아 있으면 세션을 유지한다. 비동기 PTY exit 폴링은 flaky하므로, drain이 종료를 관측한 상태
// (term.terminated=true)를 세팅하고 reapTerminatedTerms를 직접 호출해 cascade를 결정적으로 고정한다(구조 연산
// 단위 테스트 관행 — closeTab/Cmd+W 테스트와 같은 방식). 실 init/spawn이라 macOS 게이트.

// ① pane 안 형제 Term: 한 Term이 exit하면 그 Term만 닫히고 형제가 활성으로 남는다(pane/탭 그대로).
test "PR5b: a Term whose shell exits is reaped, the sibling Term survives" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.backing_width_px = session.sidebar_width_px + 800;
    session.backing_height_px = 600;
    session.window_padding_px = .{}; // split 기하만 검증 — window padding(기본 8/4) inset은 gridFromBacking·loader 테스트가 커버

    // ⌘T → 활성 pane에 Term 2개([T0, T1], T1 활성).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    const pane = session.activePane();
    try std.testing.expectEqual(@as(usize, 2), pane.terms.items.len);
    try std.testing.expectEqual(@as(usize, 1), pane.active_term);
    const t1_id = pane.terms.items[1].surface.id; // 살아남을(활성) Term

    // 배경 Term T0의 셸이 exit → reap. T0만 닫히고 T1이 인덱스 0·활성으로 clamp, 대표 surface = T1.
    pane.terms.items[0].terminated = true;
    session.reapTerminatedTerms();
    try std.testing.expectEqual(@as(usize, 1), pane.terms.items.len);
    try std.testing.expectEqual(t1_id, pane.terms.items[0].surface.id);
    try std.testing.expectEqual(@as(usize, 0), pane.active_term);
    try std.testing.expectEqual(t1_id, session.activeSurface().id);
    try std.testing.expect(!session.ended_seen);
    _ = try session.tick(); // 다음 tick 크래시 없음
}

// ② split pane: 한 pane의 유일한 Term이 exit하면 그 pane이 collapse되고 형제 pane이 전체를 차지한다.
test "PR5b: a split pane whose only Term exits collapses to its sibling" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.backing_width_px = session.sidebar_width_px + 800;
    session.backing_height_px = 600;
    session.window_padding_px = .{}; // split 기하만 검증 — window padding(기본 8/4) inset은 gridFromBacking·loader 테스트가 커버

    const left = session.activeSurface(); // 분할 전 = 분할 후 왼쪽(기존) pane P0
    try session.splitActivePane(.horizontal); // 오른쪽(새) pane P1 활성, 2 panes
    try std.testing.expectEqual(@as(usize, 2), session.activeTab().panes.items.len);
    const right_id = session.activeSurface().id; // P1(활성)
    try std.testing.expect(left.id != right_id);

    // 왼쪽(배경) pane P0의 유일한 Term 셸이 exit → reap → P0 collapse, P1만 전체 폭으로 남고 활성 유지.
    const active_pane = session.activePane();
    for (session.activeTab().panes.items) |p| {
        if (p != active_pane) p.terms.items[0].terminated = true; // P0
    }
    session.reapTerminatedTerms();
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().panes.items.len);
    try std.testing.expectEqual(@as(usize, 1), PaneTree.leafCount(session.activeTab().tree));
    try std.testing.expect(!session.activeTabHasSplit());
    try std.testing.expectEqual(right_id, session.activeSurface().id); // P1 유지·활성
    try std.testing.expectEqual(@as(u32, 800), session.active_pane_rect.w); // 전체 폭으로 확장
    try std.testing.expect(!session.ended_seen);
    _ = try session.tick();
}

// ③ 배경 워크스페이스: 다른 탭에서 셸이 exit해 그 탭의 마지막 Term이 나가면 그 워크스페이스(탭)가 닫히고
//    활성 탭이 보정된다(다른 탭은 유지).
test "PR5b: a background workspace whose last Term exits is closed; the other survives" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.backing_width_px = session.sidebar_width_px + 800;
    session.backing_height_px = 600;
    session.window_padding_px = .{}; // split 기하만 검증 — window padding(기본 8/4) inset은 gridFromBacking·loader 테스트가 커버

    // 탭 1: cat(stdin 대기로 살아 있음), 활성이 된다. 탭 0(controlled_smoke)은 read 대기로 살아 있다.
    _ = try session.createTab(
        .{ .command = "/bin/sh", .args = &.{ "-c", "cat" }, .size = .{ .cols = 20, .rows = 5 } },
        .{ .cols = 20, .rows = 5 },
        16,
        "tab 2",
        "sh",
    );
    try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);
    const survivor_id = session.tabs.items[1].activePane().activeTerm().surface.id;

    // 배경 탭 0의 유일한 Term이 exit → reap → 탭 0 워크스페이스 닫힘, 탭 1만 남고 active 0으로 보정.
    session.tabs.items[0].activePane().terms.items[0].terminated = true;
    session.reapTerminatedTerms();
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.app_window.active_tab);
    try std.testing.expectEqual(survivor_id, session.activeSurface().id);
    try std.testing.expect(!session.ended_seen);
    _ = try session.tick();
}

// ④ 마지막 Term: 살아있는 Term이 하나도 없으면(단일/마지막 Term exit) reap하지 않는다 — 기존 세션 종료 latch
//    (allTabsTerminated → ended_seen)가 마지막을 맡으므로 reap이 빈 세션을 만들지 않게 한다.
test "PR5b: the last Term exiting is not reaped (session-end latch owns it)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 단일 탭·단일 pane·단일 Term이 exit → reap 무동작(구조 유지). 세션 종료는 reap이 아니라 tick latch가 한다.
    session.activePane().terms.items[0].terminated = true;
    session.reapTerminatedTerms();
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.activePane().terms.items.len);
    try std.testing.expect(!session.ended_seen);
}

// 사이드바 클릭이 슬롯 hit-test로 탭을 전환하고, 호버가 호버 밴드를 더하는지 — 실 init이 사이드바
// 폭/슬롯 높이를 채우는 macOS 경로라 게이트한다. 마우스 좌표는 backing px, 슬롯 = y / slot_height.
test "sidebar click switches tabs and hover adds a hover band via hit-test" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    // 2번째 탭 생성 → 활성=1.
    _ = try session.createTab(
        .{ .command = "/bin/sh", .args = &.{ "-c", "true" }, .size = .{ .cols = 20, .rows = 5 } },
        .{ .cols = 20, .rows = 5 },
        16,
        "tab 2",
        "sh",
    );
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);

    const slot_h: f64 = @floatFromInt(session.sidebar_slot_height_px);
    const header_h: f64 = @floatFromInt(session.sidebar_header_height_px); // 슬롯은 상단 헤더만큼 아래로 시프트
    const x_in: f64 = @as(f64, @floatFromInt(session.sidebar_width_px)) - 1; // 사이드바 영역 안

    // 슬롯 0(y in [header, header+slot_h)) 다운클릭 → 탭 0으로 전환.
    session.mouse(1, x_in, header_h + 1, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), session.app_window.active_tab);
    // 슬롯 1 클릭 → 탭 1.
    session.mouse(1, x_in, header_h + slot_h + 1, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);
    // 슬롯 밖(마지막 슬롯 아래 빈 영역) 클릭은 전환 안 함.
    session.mouse(1, x_in, header_h + slot_h * 10, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);
    // 터미널 영역(x ≥ 사이드바 폭, 우측 경계 리사이즈 밴드보다 충분히 안쪽) 클릭은 탭 전환 경로가 아님(활성 불변).
    session.mouse(1, @floatFromInt(session.sidebar_width_px + 50), 1, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);

    // 호버: 비활성 슬롯(0, 활성은 1) 위면 호버 밴드가 추가된다(활성 밴드 + 호버 밴드 = 2).
    _ = session.hoverCursor(x_in, header_h + 1, false);
    try std.testing.expectEqual(@as(?usize, 0), session.hovered_slot);
    try std.testing.expectEqual(@as(usize, 2), session.sidebar_cells.items.len);
    // 호버가 활성 슬롯(1) 위면 별도 호버 밴드 없음(활성 색 우선) → 밴드 1개.
    _ = session.hoverCursor(x_in, header_h + slot_h + 1, false);
    try std.testing.expectEqual(@as(?usize, 1), session.hovered_slot);
    try std.testing.expectEqual(@as(usize, 1), session.sidebar_cells.items.len);
    // 터미널 영역(리사이즈 밴드보다 안쪽)으로 나가면 호버 해제.
    _ = session.hoverCursor(@floatFromInt(session.sidebar_width_px + 50), 1, false);
    try std.testing.expectEqual(@as(?usize, null), session.hovered_slot);
}

// "+"(새 워크스페이스) 슬롯 호버 시 그 행(row=탭 개수)에 호버 밴드가 추가되는지 — 탭 슬롯과 동형 affordance
// (글리프+커서뿐 아니라 밴드로도 클릭 가능함을 보여준다). 실 init이 사이드바 폭/슬롯 높이를 채우는 macOS 경로라 게이트.
test "hovering the sidebar + slot adds a hover band at the plus row" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    // 2번째 탭 생성 → 탭 2개, 활성=1. "+"는 row 2(y in [2*slot_h, 3*slot_h)).
    _ = try session.createTab(
        .{ .command = "/bin/sh", .args = &.{ "-c", "true" }, .size = .{ .cols = 20, .rows = 5 } },
        .{ .cols = 20, .rows = 5 },
        16,
        "tab 2",
        "sh",
    );
    const header_h: f64 = @floatFromInt(session.sidebar_header_height_px);
    const x_in: f64 = @as(f64, @floatFromInt(session.sidebar_width_px)) - 1; // 사이드바 우측 끝(헤더 새 워크스페이스 아이콘 영역)

    // 헤더 새 워크스페이스 아이콘(우측 끝) 호버 → link 커서. 카드 슬롯이 아니라 hovered_slot=null(하단 "+" → 헤더로 이동).
    const cursor = session.hoverCursor(x_in, header_h / 2, false);
    try std.testing.expectEqual(CursorKind.link, cursor);
    try std.testing.expectEqual(@as(?usize, null), session.hovered_slot);

    // 탭 슬롯(0, 비활성)으로 이동(헤더 아래) → 호버 밴드가 그 탭 행으로(slotAt이 header_h를 빼고 슬롯 0).
    _ = session.hoverCursor(x_in, header_h + 1, false);
    try std.testing.expectEqual(@as(?usize, 0), session.hovered_slot);
    try std.testing.expectEqual(@as(usize, 2), session.sidebar_cells.items.len);
}

// 호버 중인 슬롯의 ✕ zone을 클릭하면 그 탭이 닫히고(switchTab 아님), ✕ zone이 아니면 전환만 된다 —
// 실 PTY teardown이라 macOS 게이트. ✕는 호버 시에만 보이므로 hovered_slot==클릭 슬롯일 때만 닫는다.
test "clicking the hovered slot close zone closes that tab, elsewhere switches" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.createTab(
        .{ .command = "/bin/sh", .args = &.{ "-c", "cat" }, .size = .{ .cols = 20, .rows = 5 } },
        .{ .cols = 20, .rows = 5 },
        16,
        "tab 2",
        "sh",
    );
    try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);

    const w: f64 = @floatFromInt(session.sidebar_width_px);
    const cw: f64 = @floatFromInt(session.cell_width_px);
    const close_x = w - cw; // ✕ zone(우측 2칸) 안
    const slot0_y: f64 = @as(f64, @floatFromInt(session.sidebar_header_height_px)) + 1; // 슬롯 0(상단 헤더 아래)

    // 슬롯 0 좌측(✕ zone 밖) 클릭 → 닫지 않고 전환(active 0). 닫기 전 전환 동작 가드.
    session.mouse(1, 2, slot0_y, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.app_window.active_tab);

    // 슬롯 0을 호버(✕ 표시)한 뒤 그 ✕ zone 클릭 → 탭 0 닫힘(switchTab 아님).
    _ = session.hoverCursor(close_x, slot0_y, false);
    try std.testing.expectEqual(@as(?usize, 0), session.hovered_slot);
    session.mouse(1, close_x, slot0_y, 0, 0);
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
}

// 사이드바 탭을 드래그하면 tabs 순서가 바뀌고 활성이 드래그한 탭을 따라가는지 — 실 PTY라 macOS
// 게이트. down(슬롯0)→drag(슬롯2)→up: tabs[0]을 끝으로 옮긴다(live 재정렬).
test "dragging a sidebar tab reorders the list and active follows the dragged tab" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    inline for (.{ "tab 2", "tab 3" }) |title| {
        _ = try session.createTab(
            .{ .command = "/bin/sh", .args = &.{ "-c", "cat" }, .size = .{ .cols = 20, .rows = 5 } },
            .{ .cols = 20, .rows = 5 },
            16,
            title,
            "sh",
        );
    }
    try std.testing.expectEqual(@as(usize, 3), session.tabs.items.len);
    try std.testing.expectEqualStrings("Maru shell", session.tabs.items[0].activePane().activeTerm().surface.title);
    try std.testing.expectEqual(@as(usize, 2), session.app_window.active_tab);

    const slot_h: f64 = @floatFromInt(session.sidebar_slot_height_px);
    const header_h: f64 = @floatFromInt(session.sidebar_header_height_px); // 슬롯은 상단 헤더 아래로 시프트
    const x: f64 = @as(f64, @floatFromInt(session.sidebar_width_px)) - 1;

    // 탭 0(Maru)을 슬롯 2로 드래그: down(슬롯0)=전환+드래그 시작 → drag(슬롯2)=moveTab(0,2) → up.
    session.mouse(1, x, header_h + 1, 0, 0);
    try std.testing.expectEqual(@as(usize, 0), session.app_window.active_tab);
    try std.testing.expect(session.sidebar_drag_active);
    session.mouse(2, x, header_h + slot_h * 2 + 1, 0, 0);
    session.mouse(3, x, header_h + slot_h * 2 + 1, 0, 0);

    // 순서 [tab 2, tab 3, Maru], 활성=드래그 탭(Maru)=2, 드래그 종료.
    try std.testing.expectEqualStrings("tab 2", session.tabs.items[0].activePane().activeTerm().surface.title);
    try std.testing.expectEqualStrings("tab 3", session.tabs.items[1].activePane().activeTerm().surface.title);
    try std.testing.expectEqualStrings("Maru shell", session.tabs.items[2].activePane().activeTerm().surface.title);
    try std.testing.expectEqual(@as(usize, 2), session.app_window.active_tab);
    try std.testing.expect(!session.sidebar_drag_active);
}

// 사이드바·탭 라벨이 라이브 OSC 0/2 창 제목을 반영하는지 — 이전엔 정적 surface.title(= 워크스페이스 복원 시
// 저장된 옛 OSC 제목)에 고정돼, 새로 실행한 프로그램(Claude Code/Codex 등 OSC 제목을 설정하는 TUI)의 제목이
// 반영되지 않고 stale 제목이 남았다. termLabel이 core.windowTitle()(OSC 제목 > cwd basename > 정적 폴백)을
// 우선하므로 회귀를 막는다. 실 PTY라 macOS 게이트.
test "사이드바·탭 라벨이 라이브 OSC 제목을 반영한다(복원된 정적 surface.title에 고정 안 됨)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    const tab = session.tabs.items[0];
    const term = tab.activePane().activeTerm();
    // 정적 초기 제목(= 워크스페이스 복원 시 저장된 옛 OSC 제목을 흉내 — stale 라벨의 원인이었다).
    try std.testing.expectEqualStrings("Maru shell", term.surface.title);

    // 1) 프로그램(Claude Code/Codex 등 TUI)이 OSC 2로 라이브 제목 설정 → syncAutoTitles가 core_mutex 하에
    //    auto_title 캐시로 복사(렌더 스레드 use-after-free 회피) → termLabel이 그 캐시를 반영한다.
    try term.surface.core.write("\x1b]2;claude\x1b\\");
    session.syncAutoTitles();
    try std.testing.expectEqualStrings("claude", workspaceLabel(tab));

    // 2) OSC 제목 해제 + cwd만 있으면 cwd basename 폴백(라이브 우선의 일관성).
    try term.surface.core.write("\x1b]7;file://h/Users/me/proj\x1b\\");
    try term.surface.core.write("\x1b]2;\x1b\\"); // 빈 OSC 2 = 제목 해제
    session.syncAutoTitles();
    try std.testing.expectEqualStrings("proj", workspaceLabel(tab));

    // 3) OSC 제목도 cwd도 없으면(RIS로 둘 다 초기화) 정적 surface.title로 폴백 — spawn 직후 빈 라벨 방지.
    try term.surface.core.write("\x1bc");
    session.syncAutoTitles();
    try std.testing.expectEqualStrings("Maru shell", workspaceLabel(tab));

    // 4) 사용자 rename(custom_name)은 라이브 OSC 제목보다 우선한다 — 사용자 의도 보존(pickLabel custom_name 우선).
    try term.surface.core.write("\x1b]2;vim\x1b\\");
    session.syncAutoTitles();
    term.surface.custom_name = try allocator.dupe(u8, "myproj"); // destroyTerm(session.deinit)이 해제
    try std.testing.expectEqualStrings("myproj", workspaceLabel(tab));
}

// ③a: 사이드바 우측 경계를 드래그하면 폭이 바뀌는지 — 경계 호버=resize_h, down=리사이즈 시작, drag=폭 갱신,
// up=종료, 극단값은 [min,max] pt로 clamp(pt 저장이라 DPI 생존). 실 init/spawn이라 macOS 게이트.
test "③a: dragging the sidebar right edge resizes the sidebar width (cursor, clamp)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    try std.testing.expect(session.sidebar_width_px > 0);

    const start_px = session.sidebar_width_px;
    const edge: f64 = @floatFromInt(start_px);
    // 경계 호버 → resize_h(↔). 경계 안쪽(사이드바)은 default.
    try std.testing.expectEqual(CursorKind.resize_h, session.hoverCursor(edge, 100, false));

    // 경계 down → 리사이즈 시작. 넓게 드래그(+60) → 폭 증가. up → 종료.
    session.mouse(1, edge, 100, 0, 0);
    try std.testing.expect(session.sidebar_resize_active);
    session.mouse(2, edge + 60, 100, 0, 0);
    try std.testing.expect(session.sidebar_width_px > start_px);
    try std.testing.expect(session.sidebar_width_pt > default_sidebar_width_pt);
    session.mouse(3, edge + 60, 100, 0, 0);
    try std.testing.expect(!session.sidebar_resize_active);

    // 극단값 clamp(직접 호출): 아주 넓게 → max_pt, 아주 좁게 → min_pt.
    session.setSidebarWidthPx(1_000_000);
    try std.testing.expectEqual(sidebar_max_pt, session.sidebar_width_pt);
    session.setSidebarWidthPx(0);
    try std.testing.expectEqual(sidebar_min_pt, session.sidebar_width_pt);
    _ = try session.tick(); // 폭 변경 후 다음 tick 크래시 없음
}

// ③b: 사이드바 하단 "+" 버튼을 클릭하면 새 워크스페이스가 열리는지(⌘⇧T의 마우스 버전) — 호버 시 pointingHand.
// 실 init/spawn이라 macOS 게이트.
test "③b: clicking the sidebar '+' button opens a new workspace" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리 — window padding(기본 8/4) inset은 gridFromBacking·loader 전용 테스트가 커버
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);

    // 새 워크스페이스 아이콘 = 헤더 영역(y<header) 우측 끝 2칸. headerHit이 new_workspace 반환(하단 "+" → 헤더로 이동).
    const header_y: f64 = @as(f64, @floatFromInt(session.sidebar_header_height_px)) / 2;
    const new_ws_x: f64 = @as(f64, @floatFromInt(session.sidebar_width_px)) - 1;
    try std.testing.expectEqual(chrome.components.sidebar.HeaderRegion.new_workspace, chrome.components.sidebar.headerHit(new_ws_x, header_y, session.sidebar_width_px, session.cell_width_px, session.sidebar_header_height_px));

    // 새 워크스페이스 아이콘 호버 → pointingHand(link) affordance.
    try std.testing.expectEqual(CursorKind.link, session.hoverCursor(new_ws_x, header_y, false));

    // 새 워크스페이스 아이콘 클릭 → 워크스페이스 2개, 새 탭이 활성.
    session.mouse(1, new_ws_x, header_y, 0, 0);
    try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);
    try std.testing.expect(!session.ended_seen);
    _ = try session.tick();
}

// 회귀: 사이드바 검색이 활성인 채 검색 영역 '밖'(터미널·카드)을 클릭하면 검색을 blur해 키 포커스를 터미널로
// 되돌린다. P3에서 검색이 한번 켜지면 평문 키가 전부 검색으로 들어가 '터미널에 입력 불가'로 갇히던 것을 방지한다
// (rename focus-loss와 같은 규율 — Esc 외에 클릭으로도 빠져나온다). 실 좌표 hit-test라 macOS 게이트.
test "sidebar search blurs when clicking outside it (terminal/card) — restores terminal key focus" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    session.window_padding_px = .{}; // 레이아웃 기하만 격리
    _ = try session.resize(session.sidebar_width_px + 800, 600, session.scale_milli);

    // 검색 줄(헤더 하단)을 클릭 → 검색 활성, 키 포커스가 검색으로 라우팅.
    const search_x: f64 = @as(f64, @floatFromInt(session.sidebar_width_px)) * 0.5;
    const search_y: f64 = @as(f64, @floatFromInt(session.sidebar_header_height_px)) * 0.8;
    try std.testing.expectEqual(chrome.components.sidebar.HeaderRegion.search, chrome.components.sidebar.headerHit(search_x, search_y, session.sidebar_width_px, session.cell_width_px, session.sidebar_header_height_px));
    session.mouse(1, search_x, search_y, 0, 0);
    try std.testing.expect(session.sidebar_search_active);
    try std.testing.expectEqual(AppSession.InputFocus.sidebar_search, session.inputFocus());

    // 검색어를 입력한 채 터미널 본문 클릭 → blur(검색어 '보존'), 키 포커스가 터미널로 복구.
    session.sidebar_search_input.appendChar(allocator, 'a') catch {};
    const term_x: f64 = @floatFromInt(session.active_pane_rect.x + 50);
    const term_y: f64 = @floatFromInt(session.active_pane_rect.y + 50);
    session.mouse(1, term_x, term_y, 0, 0);
    try std.testing.expect(!session.sidebar_search_active);
    try std.testing.expectEqual(AppSession.InputFocus.terminal, session.inputFocus());
    try std.testing.expectEqualStrings("a", session.sidebar_search_input.query.items); // blur는 검색어를 안 지운다

    // 다시 검색 활성 → 검색어가 그대로 이어진다(초안 보존).
    session.mouse(1, search_x, search_y, 0, 0);
    try std.testing.expect(session.sidebar_search_active);
    try std.testing.expectEqualStrings("a", session.sidebar_search_input.query.items);

    // 사이드바 카드 슬롯 클릭도 blur(카드 전환 + 검색 비활성, 검색어 보존).
    const card_x: f64 = @as(f64, @floatFromInt(session.cell_width_px));
    const card_y: f64 = @as(f64, @floatFromInt(session.sidebar_header_height_px)) + @as(f64, @floatFromInt(session.sidebar_slot_height_px)) * 0.5; // 슬롯 0 중앙
    session.mouse(1, card_x, card_y, 0, 0);
    try std.testing.expect(!session.sidebar_search_active);
    try std.testing.expectEqual(AppSession.InputFocus.terminal, session.inputFocus());

    // Esc 경로(closeSidebarSearch)만 검색어를 완전히 비운다 — blur와 구분.
    session.mouse(1, search_x, search_y, 0, 0); // 재활성
    session.closeSidebarSearch();
    try std.testing.expect(!session.sidebar_search_active);
    try std.testing.expectEqual(@as(usize, 0), session.sidebar_search_input.query.items.len);
}

// 멀티-탭 핵심 계약: 두 번째 탭을 만들면 자기 셸 PTY가 spawn되고, tick이 '모든' 탭을 drain하므로
// 그 탭 surface가 자기 출력을 받는다(백그라운드여도). 실 PTY라 macOS 게이트 — 약속한 "탭 2개 동시
// 출력" 반-E2E를 결정적으로 고정한다. switchTab이 활성 라우팅을 바꾸는 것도 함께 검증.
test "two tabs: createTab spawns a second shell and tick drains both (multi-tab)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);

    // 2번째 탭: 알려진 마커를 출력하고 cat으로 stdin을 읽으며 살아 있는 controlled 셸. createTab이 Tab을
    // heap-pin하고 같은 runtime에 별개 surface_id로 attach한다. 새 탭이 활성이 된다. (printf만 쓰면 셸이 즉시
    // exit해 PR5b reap이 탭을 닫으므로, 멀티-탭 drain을 관측하려면 탭이 살아 있어야 한다 — cat으로 유지.)
    _ = try session.createTab(
        .{ .command = "/bin/sh", .args = &.{ "-c", "printf 'TAB_TWO_MARK\\n'; cat" }, .size = .{ .cols = 20, .rows = 5 } },
        .{ .cols = 20, .rows = 5 },
        16,
        "tab 2",
        "sh",
    );
    try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);

    // tick이 모든 탭을 drain → 2번째 탭 surface가 자기 셸 출력을 받는다(멀티-탭 drain).
    var saw = false;
    var i: usize = 0;
    while (i < 400 and !saw) : (i += 1) {
        _ = try session.tick();
        const dump = try session.tabs.items[1].activePane().activeTerm().surface.core.dumpUtf8(allocator);
        defer allocator.free(dump);
        if (std.mem.indexOf(u8, dump, "TAB_TWO_MARK") != null) saw = true;
    }
    try std.testing.expect(saw);

    // switchTab으로 활성 탭을 0으로 — activeSurface가 탭 0 surface를 가리킨다(라우팅 전환).
    try std.testing.expect(session.switchTab(0));
    try std.testing.expectEqual(session.tabs.items[0].activePane().activeTerm().surface.id, session.activeSurface().id);
    try std.testing.expect(!session.switchTab(5)); // 범위 밖이면 false, 활성 불변
    try std.testing.expectEqual(@as(usize, 0), session.app_window.active_tab);
}

// Cmd+T가 키 경로(handleKeyEvent → resolver → app_action)로 '활성 pane에 새 Term(가로 탭)'을 열고,
// Cmd+Shift+T가 '새 워크스페이스'를 여는지 — 탭 풀 모델. native 최소(Swift는 키만, 판정·실행은 Zig).
// 실 PTY라 macOS 게이트.
test "Cmd+T opens a new Term in the active pane; Cmd+Shift+T opens a workspace" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.activePane().terms.items.len);

    // Cmd+T → new_term → 활성 pane에 Term 추가(워크스페이스 수 불변), 새 Term이 활성.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.activePane().active_term);
    try std.testing.expect(session.total_app_key_events >= 1); // 앱 액션으로 회계(PTY로 안 샘)

    // Cmd+Shift+T → new_tab → 새 워크스페이스(활성), 그 워크스페이스는 Term 1개로 시작.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'T' }, .modifiers = .{ .command = true, .shift = true } });
    try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);
    try std.testing.expectEqual(@as(usize, 1), session.activePane().terms.items.len);

    // 안 묶인 Cmd 조합(Cmd+S)은 아무것도 안 만들고 무시(ignored).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 's' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);
}

// Cmd+1~9가 N번째 워크스페이스(사이드바 탭)로 전환하는지(select_tab) — 사용자 요청. 범위 밖(탭보다 큰 번호)은
// no-op. 실 init/spawn이라 macOS 게이트.
test "Cmd+1..9 switches to the Nth workspace (out-of-range is a no-op)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 워크스페이스 3개(⌘⇧T 두 번). 활성 = 마지막(2).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'T' }, .modifiers = .{ .command = true, .shift = true } });
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'T' }, .modifiers = .{ .command = true, .shift = true } });
    try std.testing.expectEqual(@as(usize, 3), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.app_window.active_tab);

    // Cmd+1 → 워크스페이스 0.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = '1' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 0), session.app_window.active_tab);
    // Cmd+3 → 워크스페이스 2.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = '3' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 2), session.app_window.active_tab);
    // Cmd+2 → 워크스페이스 1.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = '2' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);
    // Cmd+9 → 9번째 없음(3개뿐) → no-op(활성 불변).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = '9' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);
}

// handleKeyEvent가 사용자 config의 keybind를 적용하는지(빈 resolver가 아니라 loaded_config.keyBindingResolver())
// — 기본엔 없는 조합(Cmd+E)을 사용자 바인딩으로 new_term에 묶어 실제로 디스패치되는지 본다. 실 PTY라 macOS 게이트.
test "handleKeyEvent applies user config keybindings (resolver wired from loaded_config)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 사용자 keybind 주입: Cmd+E = new_term(기본 바인딩엔 없는 조합). keybindings 슬라이스만 바꾼다(arena·appearance
    // 빌림은 그대로) — handleKeyEvent가 loaded_config.keyBindingResolver()를 읽으므로 이게 곧 사용자 config 효과다.
    var user_binds = [_]config_mod.AppBinding{
        .{ .chord = try config_mod.KeyChord.parse("Cmd+E"), .action = .new_term },
    };
    session.loaded_config.keybindings = &user_binds;

    // Cmd+E는 빈 resolver였다면 ignored지만, 사용자 바인딩이 먹어 활성 pane에 Term이 추가된다.
    try std.testing.expectEqual(@as(usize, 1), session.activePane().terms.items.len);
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'e' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);

    // 사용자 바인딩에 없는 기본 조합(Cmd+T)도 여전히 동작한다(resolver가 default_app_bindings로 폴백).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = .{ .command = true } });
    try std.testing.expectEqual(@as(usize, 3), session.activePane().terms.items.len);
}

// Term 생명주기: ⌘T가 활성 pane에 Term을 쌓고, ⌘]/⌘[가 Term을 wrap 순환하고, ⌘W가 Term →(마지막이면)
// pane →(마지막이면) 워크스페이스 순으로 cascade close하는지 — 실 PTY teardown이라 macOS 게이트. 키 경로 전체.
test "Term lifecycle: Cmd+T adds, Cmd+Opt+]/[ cycle, Cmd+W cascades Term to workspace" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    const cmd: terminal.ModifierSet = .{ .command = true };

    // ⌘T 두 번 → 활성 pane Term 3개(0,1,2), 활성 Term 2(마지막). 워크스페이스/ pane 수는 불변.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = cmd });
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 't' }, .modifiers = cmd });
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().panes.items.len);
    try std.testing.expectEqual(@as(usize, 3), session.activePane().terms.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.activePane().active_term);

    // ⌘⌥] → 다음(wrap): 2→0. ⌘⌥[ → 이전(wrap): 0→2. (⌘[]는 이제 split 순환이라 Term 순환은 ⌘⌥[]로 옮겼다.)
    const cmd_opt: terminal.ModifierSet = .{ .command = true, .option = true };
    _ = try session.handleKeyEvent(.{ .key = .{ .char = ']' }, .modifiers = cmd_opt });
    try std.testing.expectEqual(@as(usize, 0), session.activePane().active_term);
    _ = try session.handleKeyEvent(.{ .key = .{ .char = '[' }, .modifiers = cmd_opt });
    try std.testing.expectEqual(@as(usize, 2), session.activePane().active_term);

    // ⌘W → 활성 Term(2) 닫힘 → Term 2개, 활성 1(보정). pane/워크스페이스 수 불변.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'w' }, .modifiers = cmd });
    try std.testing.expectEqual(@as(usize, 2), session.activePane().terms.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.activePane().active_term);
    try std.testing.expectEqual(@as(usize, 1), session.activeTab().panes.items.len);

    // ⌘W → Term(1) 닫힘 → Term 1개. 아직 pane/워크스페이스 그대로(세션 유지).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'w' }, .modifiers = cmd });
    try std.testing.expectEqual(@as(usize, 1), session.activePane().terms.items.len);
    try std.testing.expect(!session.ended_seen);

    // ⌘W → 이제 Term 1·pane 1·워크스페이스 1 → 마지막 워크스페이스 close = 세션 종료 latch(cascade 끝).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'w' }, .modifiers = cmd });
    try std.testing.expect(session.ended_seen);
}

// Cmd+]/[ 가 키 경로(handleKeyEvent → resolver → app_action)로 split(pane)을 순환하는지 — 실 PTY라 macOS
// 게이트. ⌘D로 pane 2개 만든 뒤 ⌘]는 활성 pane을 다음으로, ⌘[는 이전(wrap)으로 옮긴다. (⌘[]는 Term이 아니라
// split 순환 — Term은 ⌘⌥[]로 옮겼다, 사용자 요청 배치.)
test "Cmd bracket keys cycle split panes through the key path" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    const cmd: terminal.ModifierSet = .{ .command = true };
    // ⌘D=좌우 split → 활성 워크스페이스에 pane 2개(splitActivePane이 새 pane으로 포커스).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'd' }, .modifiers = cmd });
    try std.testing.expectEqual(@as(usize, 2), session.activeTab().panes.items.len);
    const start = session.activeTab().active_pane;
    // ⌘] → 다음 pane(wrap, 2개라 토글), ⌘[ → 다시 원래.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = ']' }, .modifiers = cmd });
    try std.testing.expectEqual((start + 1) % 2, session.activeTab().active_pane);
    _ = try session.handleKeyEvent(.{ .key = .{ .char = '[' }, .modifiers = cmd });
    try std.testing.expectEqual(start, session.activeTab().active_pane);
}

// Cmd+Shift+]/[ 가 키 경로(handleKeyEvent → resolver → app_action)로 다음/이전 탭을 순환하는지 — 실
// PTY라 macOS 게이트. 2탭에서 ]는 활성을 1→0, [는 0→1(wrap)으로 옮긴다.
test "Cmd+Shift bracket keys cycle tabs through the key path" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.handleKeyEvent(.{ .key = .{ .char = 'T' }, .modifiers = .{ .command = true, .shift = true } }); // ⌘⇧T=새 워크스페이스 → 2탭, 활성 1
    try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);

    // Cmd+Shift+] → next_tab → (1+1)%2 = 0.
    _ = try session.handleKeyEvent(.{ .key = .{ .char = ']' }, .modifiers = .{ .command = true, .shift = true } });
    try std.testing.expectEqual(@as(usize, 0), session.app_window.active_tab);
    // Cmd+Shift+[ → previous_tab → (0+2-1)%2 = 1(wrap).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = '[' }, .modifiers = .{ .command = true, .shift = true } });
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);
    // 닫는 중괄호 변형(}/{)도 같은 액션(OS가 Shift를 적용해 줄 수 있음).
    _ = try session.handleKeyEvent(.{ .key = .{ .char = '}' }, .modifiers = .{ .command = true, .shift = true } });
    try std.testing.expectEqual(@as(usize, 0), session.app_window.active_tab);
}

// closeTab이 탭을 teardown하고 active_tab을 재선택하며, 마지막 탭은 창(세션) 종료로 latch하는지 — 실
// PTY teardown(detach + reader join)이라 macOS 게이트. cat는 PTY가 닫힐 때까지 살아 있어 live 탭 teardown을 본다.
test "closeTab tears down a tab and reselects, last tab closes the session" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 살아있는 탭 2개 더(cat은 PTY 닫힐 때까지 stdin을 읽으며 대기). 활성=2.
    inline for (.{ "tab 2", "tab 3" }) |title| {
        _ = try session.createTab(
            .{ .command = "/bin/sh", .args = &.{ "-c", "cat" }, .size = .{ .cols = 20, .rows = 5 } },
            .{ .cols = 20, .rows = 5 },
            16,
            title,
            "sh",
        );
    }
    try std.testing.expectEqual(@as(usize, 3), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 2), session.app_window.active_tab);

    // 백그라운드 탭 0 닫기 → 2탭, 인덱스 밀림으로 active 2→1.
    session.closeTab(0);
    try std.testing.expectEqual(@as(usize, 2), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 1), session.app_window.active_tab);

    // 활성 탭(=마지막 인덱스 1) 닫기 → 1탭, active clamp 0.
    session.closeTab(1);
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
    try std.testing.expectEqual(@as(usize, 0), session.app_window.active_tab);
    try std.testing.expect(!session.ended_seen);

    // 마지막 탭 닫기 → 창 닫힘(종료 latch). 탭은 헐지 않고(빈 리스트 패닉 회피) deinit이 정리한다.
    session.closeTab(0);
    try std.testing.expectEqual(@as(usize, 1), session.tabs.items.len);
    try std.testing.expect(session.ended_seen);
}

test "drag autoscroll works after a double-click word selection and skips redraw when nothing moves" {
    var session: AppSession = undefined;
    session.allocator = std.testing.allocator;
    var tab_surface = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 4, .rows = 2 });
    defer tab_surface.deinit();
    session.surface_initialized = true;
    var st_ptrs = [_]*app.Surface{&tab_surface};
    session.app_window = .{ .tabs = &st_ptrs };
    try attachTestRuntime(&session, &tab_surface);
    defer session.runtime.deinit();
    session.metal_dirty = false;
    session.metal_buffer = .{};
    session.chrome_host = .{}; // mouse()가 context_menu.open을 kind 무관하게 읽음([[devsession-undefined-test-field-trap]])
    session.rename = null;
    session.mouse_drag_selecting = false; // 더블클릭(kind 4) 후 상태
    session.divider_drag = null; // mouse()의 divider 드래그 캡처가 읽는다(undefined 옵셔널 포인터는 garbage non-null)
    session.sidebar_resize_active = false; // mouse()의 사이드바 폭 조절 캡처가 읽는다(undefined bool도 garbage)
    session.scrollbar_drag_grab = null; // mouse()의 스크롤바 드래그 캡처가 읽는다(undefined ?f32도 garbage non-null)
    session.drag_autoscroll = 0;
    session.last_drag_col = 0;
    session.cell_width_px = 8;
    session.cell_height_px = 16;
    session.scale_milli = 1000;
    session.sidebar_width_px = 0; // 사이드바 없음 — 마우스가 터미널 선택 경로를 타게(inSidebar=false)
    session.active_pane_rect = .{ .x = 0, .y = 0, .w = 32, .h = 32 }; // 단일 panel 좌표 origin(pxToCell이 읽음)

    const core = &tab_surface.core;
    try core.write("aa\r\nbb\r\ncc"); // 스크롤백 1(aa) + 화면 bb,cc
    core.selectWordAt(1, 0); // 더블클릭 단어 선택(cc)
    try std.testing.expect(core.selection_anchor != null);

    // 더블클릭 직후 드래그가 grid 위 밖으로 — mouse_drag_selecting=false여도 autoscroll이 돈다.
    session.mouse(2, 0.0, -5.0, 0, 0);
    try std.testing.expectEqual(@as(i8, 1), session.drag_autoscroll);
    session.applyDragAutoscroll();
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
    try std.testing.expect(session.metal_dirty);

    // 더 갈 곳이 없으면(스크롤백 끝 + head 그대로) 재투영을 걸지 않는다 — 30Hz 루프 방지.
    session.metal_dirty = false;
    session.applyDragAutoscroll();
    try std.testing.expectEqual(@as(usize, 1), core.view_offset);
    try std.testing.expect(!session.metal_dirty);
}

test "large paste drains through the non-blocking queue without freezing ticks" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실제 PTY 경로
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // PTY 입력 버퍼보다 큰 페이로드 — blocking 단일 write라면 여기서 동결됐을 크기. 개행을
    // 포함한 줄 단위로 만든다: controlled 자식(read -r line)은 canonical 모드라 개행 없는
    // 대용량은 줄을 영영 못 끝내 read에 갇히고, deinit의 자식 reap(wait4)이 hang된다 — 첫
    // 줄이 들어가면 자식이 진행해 정상 종료한다.
    const big = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(big);
    @memset(big, 'x');
    var li: usize = 79;
    while (li < big.len) : (li += 80) big[li] = '\n';
    session.pasteText(big);

    // pasteText는 즉시 반환해야 하고(동결 없음), 잔여는 tick들이 흘려보낸다.
    var i: usize = 0;
    while (i < 600 and session.pending_paste.items.len > session.pending_paste_offset) : (i += 1) {
        _ = try session.tick();
    }
    // 자식(read 대기 중)이 소비하므로 결국 큐가 빈다.
    try std.testing.expectEqual(session.pending_paste_offset, session.pending_paste.items.len);
}

// imeDecide(이제 ime.decide) 단위 테스트는 함수와 함께 src/session/ime.zig로 이동. imeEnd(부작용 포함)의
// 통합 테스트는 아래에 그대로 둔다(라이브 PTY/트랜잭션 닫힘 검증).

test "imeEnd always closes the transaction even with a null key (no leak) and fails closed on OOM" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // null 키로 닫아도 트랜잭션이 닫히고(ime_active=false), 누적 텍스트는 커밋된다.
    session.imeBegin();
    session.imeInsert("\xec\x95\x88"); // '안'
    const before = session.total_terminal_input_bytes;
    session.imeEnd(null); // 정규화 불가 키
    try std.testing.expect(!session.ime_active);
    try std.testing.expectEqual(before + 3, session.total_terminal_input_bytes);

    // OOM 플래그면 커밋을 통째로 버린다(잘린 문자열 방지).
    session.imeBegin();
    session.imeInsert("ab");
    session.ime_insert_failed = true;
    const before2 = session.total_terminal_input_bytes;
    session.imeEnd(.{ .key = .{ .char = 'x' }, .modifiers = .{} });
    try std.testing.expectEqual(before2, session.total_terminal_input_bytes);
    try std.testing.expect(!session.ime_active);
}

test "shouldReplayAfterCommit: arrows replay after candidate commit (left only when modified)" {
    try std.testing.expect(AppSession.shouldReplayAfterCommit(.{ .key = .arrow_right, .modifiers = .{} }));
    try std.testing.expect(AppSession.shouldReplayAfterCommit(.{ .key = .arrow_down, .modifiers = .{} }));
    try std.testing.expect(AppSession.shouldReplayAfterCommit(.{ .key = .arrow_up, .modifiers = .{} }));
    try std.testing.expect(!AppSession.shouldReplayAfterCommit(.{ .key = .arrow_left, .modifiers = .{} }));
    try std.testing.expect(AppSession.shouldReplayAfterCommit(.{ .key = .arrow_left, .modifiers = .{ .shift = true } }));
    try std.testing.expect(!AppSession.shouldReplayAfterCommit(.{ .key = .enter, .modifiers = .{} }));
}

test "sendTextAsKeys normalizes newlines to CR and imeBegin snaps to bottom" {
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    const core = &session.activeSurface().core;

    // 스크롤백을 만들고 과거를 본 뒤 imeBegin → 바닥으로 스냅(조합이 보이게).
    try core.write("a\r\nb\r\nc\r\nd\r\ne\r\nf");
    core.scrollViewport(3);
    try std.testing.expect(core.viewOffset() != 0);
    session.imeBegin();
    try std.testing.expectEqual(@as(usize, 0), core.viewOffset());
    session.imeEnd(null);

    // 멀티라인 확정 텍스트의 \n이 \r로 정규화돼 PTY에 들어간다(LF 아님).
    // (controlled 셸의 read가 \r에 반응하도록 — 바이트 카운트만 확인: "a\nb" → 'a',\r,'b' = 3바이트)
    const before = session.total_terminal_input_bytes;
    session.imeBegin();
    session.imeInsert("a\nb");
    session.imeEnd(null);
    try std.testing.expectEqual(before + 3, session.total_terminal_input_bytes);
}

test "commitComposition during terminal preedit does not deadlock (회귀: bd5fd14)" {
    // 한글 조합 중(core.preedit 존재) 창 키포커스를 잃으면 setFocused(false)→commitComposition이
    // 조합을 확정 전송한다. 과거엔 core_mutex를 쥔 채 sendTextAsKeys→handleKeyEvent가 같은 락을
    // 재취득해 메인 스레드가 ulock_wait에 박혀 hang했다(std.Io.Mutex는 비재진입 → self-deadlock;
    // sendCommittedText→sendTextAsKeys 통일 #2/bd5fd14로 "락 보유 중 호출 안전" 가정이 깨진 회귀).
    // 이 테스트가 끝까지 반환한다는 것 자체가 데드락이 사라졌다는 증거다(데드락이면 영영 멈춘다).
    // 더해서, 이제는 같은 클래스 회귀가 들어오면 디버그 빌드의 core_mutex 재진입 안전망
    // (CoreOwner, docs/io-render-threading.md §6-5)이 hang 대신 즉시 panic으로 노출한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    const core = &session.activeSurface().core;

    // 터미널 조합 중 상태를 만든다(inputFocus 기본 .terminal → core.preedit 세팅).
    session.imeMarked("한");
    try std.testing.expect(core.preedit != null);

    const before = session.total_terminal_input_bytes;
    session.setFocused(false); // 창 키포커스 상실 → commitComposition(.terminal)

    try std.testing.expect(core.preedit == null); // 조합이 확정되며 비워짐(다시 안 남음)
    try std.testing.expect(session.total_terminal_input_bytes > before); // "한"이 PTY로 확정 전송됨
}

test "commitComposition sends committed text via non-blocking path, not blocking key path (#10)" {
    // #10: 한글 조합 중 창 포커스 상실 시 commitComposition이 확정 텍스트를 보내는데, 과거엔
    // sendTextAsKeys→handleKeyEvent(write_queue enqueueBlocking)를 탔다. windowLostKey는 AppKit이 메인
    // run loop를 동기 점유한 콜백이라, 그 안에서 enqueueBlocking이 write_queue 포화로 막히면 다음
    // tick(output drain)이 영영 안 와 reader도 멈추는 양방향 backpressure 데드락이 됐다(실측 hang
    // 리포트 2건, 28s·53s). 수정: sendCommittedText가 paste와 같은 non-blocking pending 경로로 보내
    // handleKeyEvent를 경유하지 않는다. backpressure 데드락 자체는 blocking이 본질이라 단위로 hang
    // 없이 재현이 어려워(재현하면 테스트가 멈춘다), 이 경로 불변식(handleKeyEvent 미경유 =
    // total_key_events 불변)으로 회귀를 고정하고, 실제 재현·소멸은 maru 실행으로 확인한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    const core = &session.activeSurface().core;

    session.imeMarked("한");
    try std.testing.expect(core.preedit != null);

    const keys_before = session.total_key_events;
    const bytes_before = session.total_terminal_input_bytes;
    session.setFocused(false); // windowLostKey → commitComposition(.terminal)

    try std.testing.expect(core.preedit == null); // 확정됨
    try std.testing.expect(session.total_terminal_input_bytes > bytes_before); // PTY로 전송됨
    // 핵심 불변식: blocking key 경로(handleKeyEvent)를 경유하지 않는다(non-blocking pending 전송).
    // 수정 전이면 sendTextAsKeys→handleKeyEvent로 total_key_events가 늘어 이 단언이 깨진다(#10 가드).
    try std.testing.expectEqual(keys_before, session.total_key_events);
}

test "imeEnd commit + transaction-less imeInsert send via non-blocking path (#10 follow-up)" {
    // #10은 commitComposition(windowLostKey)만 non-blocking으로 되돌렸으나, 같은 backpressure 데드락
    // 클래스인 두 경로가 남아 있었다: imeEnd(.commit_text)는 keyDown(interpretKeyEvents 직후) 동기
    // 콜백에서, 트랜잭션-밖 imeInsert(!ime_active — 입력기가 keyDown 없이 직접 커밋, 포커스 전환 등)는
    // AppKit 콜백에서 blocking sendTextAsKeys→handleKeyEvent(enqueueBlocking)를 탔다. 둘 다 같은
    // 불변식(handleKeyEvent 미경유 = total_key_events 불변)으로 non-blocking 경로를 고정한다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // (1) imeEnd(.commit_text): 조합 시작 → 텍스트 누적 → 키 없이 종료 = 확정 텍스트만 전송.
    session.imeBegin(); // ime_active=true
    session.imeMarked("한"); // 조합 중 표시 → 종료 시 composing 판정 + ime_marked_changed
    session.imeInsert("한"); // 트랜잭션 안 — ime_inserted에 누적만
    const keys1 = session.total_key_events;
    const bytes1 = session.total_terminal_input_bytes;
    session.imeEnd(null); // 정규화 불가 키 없이 종료 → commit_text("한")
    try std.testing.expect(session.total_terminal_input_bytes > bytes1); // PTY로 확정 전송됨
    try std.testing.expectEqual(keys1, session.total_key_events); // 수정 전이면 sendTextAsKeys로 늘어 깨짐

    // (2) imeInsert(!ime_active): 위 imeEnd가 ime_active를 꺼 트랜잭션 밖 직접 커밋 경로.
    const keys2 = session.total_key_events;
    const bytes2 = session.total_terminal_input_bytes;
    session.imeInsert("을");
    try std.testing.expect(session.total_terminal_input_bytes > bytes2);
    try std.testing.expectEqual(keys2, session.total_key_events);
}

test "pendingPasteRetarget: 빈 큐는 활성 surface로 고정, 잔여 있으면 대상 유지(탭 전환 오라우팅 방지)" {
    // paste/IME 확정 잔여가 다 빠지기 전 탭/pane이 바뀌면, 과거엔 flushPendingPaste가 self.activeSurface()로
    // 써 잔여가 새 surface에 입력됐다(선존 버그, code-review max 발견). 이제 대상을 enqueue 시점에
    // pending_paste_target으로 고정한다: 큐가 비었을 때만 현재 활성으로 다시 잡고, 잔여가 있으면 안 바꾼다.
    if (builtin.os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 20,
        .rows = 5,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();

    // 빈 큐 → 현재 활성 surface로 대상 고정.
    session.pendingPasteRetarget();
    try std.testing.expectEqual(session.activeSurface().id, session.pending_paste_target);

    // 잔여를 남긴 채 다른(가짜) 대상을 박고 retarget → 대상이 안 바뀐다(원래 대상 우선 = 탭 전환에도 보존).
    try session.pending_paste.appendSlice(allocator, "AB");
    const other: u64 = session.activeSurface().id +% 1; // 다른 surface 대상 가정
    session.pending_paste_target = other;
    session.pendingPasteRetarget();
    try std.testing.expectEqual(other, session.pending_paste_target);
}

test "scrollbarThumbGeom: null without scrollback, thumb size/position track view_offset" {
    // 스크롤백 없으면 안 그림(null).
    try std.testing.expect(AppSession.scrollbarThumbGeom(0, 0, 16, 320) == null);
    try std.testing.expect(AppSession.scrollbarThumbGeom(20, 0, 0, 320) == null); // cell_height 0
    try std.testing.expect(AppSession.scrollbarThumbGeom(20, 0, 16, 0) == null); // view 0

    // sb_count=20(=20행 @16px=320px), view 320px. total 640px → thumb_h = 320*320/640 = 160.
    const bottom = AppSession.scrollbarThumbGeom(20, 0, 16, 320).?; // view_offset 0 = 바닥
    try std.testing.expectApproxEqAbs(@as(f32, 160), bottom.h, 0.5);
    try std.testing.expectApproxEqAbs(@as(f32, 160), bottom.y, 0.5); // 바닥: y = view-thumb = 320-160
    const top = AppSession.scrollbarThumbGeom(20, 20, 16, 320).?; // view_offset 20 = 꼭대기
    try std.testing.expectApproxEqAbs(@as(f32, 0), top.y, 0.5); // 꼭대기: y = 0
    const mid = AppSession.scrollbarThumbGeom(20, 10, 16, 320).?; // 중간(t=0.5)
    try std.testing.expectApproxEqAbs(@as(f32, 80), mid.y, 0.5); // (320-160)*(1-0.5)

    // 스크롤백이 많으면 thumb는 최소 높이(18px)로 clamp.
    const tiny = AppSession.scrollbarThumbGeom(10000, 0, 16, 320).?;
    try std.testing.expectApproxEqAbs(@as(f32, 18), tiny.h, 0.5);
}

test "scrollbarTargetOffset: clamp + round, and round-trips scrollbarThumbGeom" {
    // t(0=바닥, 1=꼭대기)를 view_offset으로. 경계·중간.
    try std.testing.expectEqual(@as(usize, 0), AppSession.scrollbarTargetOffset(0.0, 20)); // 바닥
    try std.testing.expectEqual(@as(usize, 20), AppSession.scrollbarTargetOffset(1.0, 20)); // 꼭대기
    try std.testing.expectEqual(@as(usize, 10), AppSession.scrollbarTargetOffset(0.5, 20)); // 중간
    // [0,1] 밖은 clamp.
    try std.testing.expectEqual(@as(usize, 0), AppSession.scrollbarTargetOffset(-0.3, 20));
    try std.testing.expectEqual(@as(usize, 20), AppSession.scrollbarTargetOffset(1.5, 20));
    // round(0.5*20=10 정수경계 위 1.54→2).
    try std.testing.expectEqual(@as(usize, 2), AppSession.scrollbarTargetOffset(0.077, 20));

    // 역매핑은 scrollbarThumbGeom의 정확한 역이어야 한다 — 각 view_offset에서 thumb_top(geom.y)을 뽑아
    // t로 되돌리면 같은 offset이 나온다(드래그 위치 ↔ scroll 위치가 1:1, drift 없음).
    const sb: usize = 20;
    const ch: u32 = 16;
    const view: u32 = 320;
    inline for (.{ 0, 3, 7, 13, 20 }) |V| {
        const g = AppSession.scrollbarThumbGeom(sb, V, ch, view).?;
        const track: f64 = @as(f64, @floatFromInt(view)) - @as(f64, g.h);
        const t: f64 = 1.0 - @as(f64, g.y) / track;
        try std.testing.expectEqual(@as(usize, V), AppSession.scrollbarTargetOffset(t, sb));
    }
}

test "scrollbarBarWidthPx: cell 비율·최소 px·emphasize 가산" {
    // cell_width 큰 경우 비율(0.5)이 최소(7)를 넘는다.
    try std.testing.expectApproxEqAbs(@as(f32, 10), AppSession.scrollbarBarWidthPx(20, false), 0.01); // 20*0.5
    try std.testing.expectApproxEqAbs(@as(f32, 12), AppSession.scrollbarBarWidthPx(20, true), 0.01); // +2 emphasize
    // 작은 cell이면 최소 px로 clamp.
    try std.testing.expectApproxEqAbs(@as(f32, 7), AppSession.scrollbarBarWidthPx(8, false), 0.01); // 8*0.5=4 < 7
    try std.testing.expectApproxEqAbs(@as(f32, 9), AppSession.scrollbarBarWidthPx(8, true), 0.01); // 7+2
}

test "computeScrollbarAlpha: full→idle 감쇠(visible 유지·fade 후 faint·단조 감소)" {
    // visible_ticks까지 full.
    try std.testing.expectEqual(scrollbar_alpha_full, AppSession.computeScrollbarAlpha(0));
    try std.testing.expectEqual(scrollbar_alpha_full, AppSession.computeScrollbarAlpha(scrollbar_visible_ticks));
    // fade 완료 후(visible+fade 이상) faint 정착.
    try std.testing.expectEqual(scrollbar_alpha_idle, AppSession.computeScrollbarAlpha(scrollbar_visible_ticks + scrollbar_fade_ticks));
    try std.testing.expectEqual(scrollbar_alpha_idle, AppSession.computeScrollbarAlpha(scrollbar_visible_ticks + scrollbar_fade_ticks + 100));
    // fade 창 안은 full~idle 사이에서 단조 감소(틱이 늘수록 alpha가 줄거나 같다).
    var prev: u8 = scrollbar_alpha_full;
    var k: u32 = scrollbar_visible_ticks;
    while (k <= scrollbar_visible_ticks + scrollbar_fade_ticks) : (k += 1) {
        const a = AppSession.computeScrollbarAlpha(k);
        try std.testing.expect(a <= prev);
        try std.testing.expect(a >= scrollbar_alpha_idle);
        prev = a;
    }
}

test "appendPaneScrollbars: split 각 pane이 자기 idle_ticks로 독립 fade (per-pane)" {
    if (builtin.os.tag != .macos) return error.SkipZigTest; // 실 PTY + split 생성
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = abi_version,
        .cols = 40,
        .rows = 6,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(CommandKind.controlled_smoke),
    });
    defer session.deinit();
    _ = try session.resize(800, 600, 1000);

    session.dispatchAppAction(.split_horizontal); // pane 2개(좌우)
    // 두 pane 모두 스크롤백을 만든다 — resize(800x600)가 grid를 backing px로 재계산해 rows가 init값(6)이
    // 아니라 ~33이므로, 그보다 충분히 많은 줄(200)을 각 core에 직접 써서 어느 rows든 스크롤백을 보장한다.
    for (session.activeTab().panes.items) |pane| {
        const core = &pane.activeTerm().surface.core;
        var n: usize = 0;
        while (n < 200) : (n += 1) try core.write("line\r\n");
        try std.testing.expect(core.scrollbackLen() > 0);
    }

    // per-pane fade: 한 pane은 full(idle 0), 다른 pane은 faint(fade 정착)로 둔다 — alpha가 각 pane 자기
    // idle_ticks를 따른다(세션 단일 값이 아님을 증명). hover/드래그 없음.
    session.dropQuadsByLayer(3);
    session.scrollbar_hovered = false;
    session.scrollbar_drag_grab = null;
    const panes = session.activeTab().panes.items;
    panes[0].scrollbar_idle_ticks = 0; // full
    panes[1].scrollbar_idle_ticks = scrollbar_visible_ticks + scrollbar_fade_ticks; // faint 정착
    session.appendPaneScrollbars();

    // pane 2개 → layer3 thumb 2개. 각 pane 자기 idle_ticks 반영 — 하나 full, 하나 faint.
    var count: usize = 0;
    var saw_full = false;
    var saw_faint = false;
    for (session.gpu_quads.items) |q| {
        if (q.layer != 3) continue;
        count += 1;
        const a: u8 = @intCast((q.fill_color0 >> 24) & 0xff);
        if (a == scrollbar_alpha_full) saw_full = true;
        if (a == scrollbar_alpha_idle) saw_faint = true;
    }
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expect(saw_full); // idle_ticks 0 pane
    try std.testing.expect(saw_faint); // fade 정착 pane
}

test "configPath caches the resolved config path (single alloc, freed in deinit)" {
    var session: AppSession = undefined;
    session.allocator = std.testing.allocator;
    session.config_path_buffer = null;
    defer if (session.config_path_buffer) |b| std.testing.allocator.free(b);
    const p1 = session.configPath();
    const p2 = session.configPath();
    // 두 번째 호출은 캐시 — 같은 포인터/길이(재할당 없음, 안 그러면 testing.allocator가 leak 잡음).
    try std.testing.expectEqual(p1.ptr, p2.ptr);
    try std.testing.expectEqual(p1.len, p2.len);
}

test "imeCursorRect returns the cursor cell rect in backing px for IME candidate placement" {
    var session: AppSession = undefined;
    session.allocator = std.testing.allocator;
    var tab_surface = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 10, .rows = 5 });
    defer tab_surface.deinit();
    session.surface_initialized = true;
    var st_ptrs = [_]*app.Surface{&tab_surface};
    session.app_window = .{ .tabs = &st_ptrs };
    session.cell_width_px = 8;
    session.cell_height_px = 16;
    session.active_pane_rect = .{ .x = 0, .y = 0, .w = 80, .h = 80 }; // 활성 panel origin (0,0): 커서 좌표는 col*cw/row*ch 그대로
    // imeCursorRect는 inputFocus()(chrome_host.*.open)와 buildChromeProps→buildChromeTokens(appearance.chrome_theme
    // enum switch)를 읽는다. `var session = undefined`라 이 둘을 안 채우면 0xaa 쓰레기 → enum switch가 corrupt로
    // 패닉한다(타깃·struct 레이아웃에 따라 우연히 통과 또는 크래시 — devsession-undefined-test-field-trap). 명시
    // 초기화로 결정적 `.terminal`(오버레이 caret 없음) 경로를 타게 한다.
    session.chrome_host = .{};
    session.rename = null; // inputFocus(imeCursorRect)가 rename을 읽음([[devsession-undefined-test-field-trap]])
    session.appearance = config_mod.resolveAppearance(.{}) catch unreachable;

    const core = &tab_surface.core;
    try core.write("ab"); // 커서가 (0,2)로
    const r = session.imeCursorRect();
    try std.testing.expectEqual(@as(f64, 16), r.x); // col 2 * 8
    try std.testing.expectEqual(@as(f64, 0), r.y); // row 0 * 16
    try std.testing.expectEqual(@as(f64, 8), r.w);
    try std.testing.expectEqual(@as(f64, 16), r.h);

    try core.write("\r\nXY"); // 둘째 줄로
    const r2 = session.imeCursorRect();
    try std.testing.expectEqual(@as(f64, 16), r2.x); // col 2
    try std.testing.expectEqual(@as(f64, 16), r2.y); // row 1 * 16

    // 활성 panel이 서브-rect에 있으면(split/사이드바) 커서 스크린 좌표가 panel origin만큼 이동한다 — 후보창이
    // 실제 커서 아래에 뜬다. origin (24, 32): x는 +24, y는 +32(단일 panel일 땐 origin = (사이드바 폭, 0)).
    session.active_pane_rect = .{ .x = 24, .y = 32, .w = 80, .h = 80 };
    const r3 = session.imeCursorRect();
    try std.testing.expectEqual(@as(f64, 24 + 16), r3.x); // origin_x(24) + col 2 * 8
    try std.testing.expectEqual(@as(f64, 32 + 16), r3.y); // origin_y(32) + row 1 * 16
}

test "pxToCell subtracts the active pane origin so clicks map to that pane's columns and rows" {
    // 활성 panel은 자기 rect origin에서 그려지므로, 스크린 픽셀에서 origin(x,y)을 뺀 뒤에야 그 panel의
    // 열/행이 된다(단일 panel이면 origin = (사이드바 폭, 0)이라 기존과 동일). 안 빼면 선택/클릭 블록이
    // origin만큼 어긋난다(라이브 제보 회귀). split이면 origin은 서브-rect의 좌상단이다.
    var session: AppSession = undefined;
    session.allocator = std.testing.allocator;
    var tab_surface = try app.Surface.init(std.testing.allocator, 1, .{ .cols = 10, .rows = 5 });
    defer tab_surface.deinit();
    session.surface_initialized = true;
    var st_ptrs = [_]*app.Surface{&tab_surface};
    session.app_window = .{ .tabs = &st_ptrs };
    session.cell_width_px = 8;
    session.cell_height_px = 16;
    session.active_pane_rect = .{ .x = 24, .y = 0, .w = 80, .h = 80 }; // origin_x 24(=3칸), origin_y 0

    // panel 왼쪽 끝(스크린 x=origin_x=24) → col 0.
    try std.testing.expectEqual(@as(u16, 0), session.pxToCell(24, 0).?.col);
    // origin_x + 2*cw = 24+16=40 → col 2.
    try std.testing.expectEqual(@as(u16, 2), session.pxToCell(40, 0).?.col);
    // origin 왼쪽(x=10 < origin_x) → 음수 clamp → col 0(panel 왼쪽 끝).
    try std.testing.expectEqual(@as(u16, 0), session.pxToCell(10, 0).?.col);

    // y origin도 뺀다(상하 split의 아래 panel): origin (0, 16) → 스크린 y에서 16을 뺀 뒤 행.
    session.active_pane_rect = .{ .x = 0, .y = 16, .w = 80, .h = 80 };
    try std.testing.expectEqual(@as(u16, 2), session.pxToCell(16, 16).?.col); // x=16 → col 2(origin_x 0)
    try std.testing.expectEqual(@as(u16, 0), session.pxToCell(16, 16).?.row); // y=16 - origin_y 16 = 0 → row 0
    try std.testing.expectEqual(@as(u16, 1), session.pxToCell(16, 32).?.row); // y=32 - 16 = 16 → row 1
}

// pageScrollDelta 단위 테스트는 함수와 함께 src/session/input_math.zig로 이동.
