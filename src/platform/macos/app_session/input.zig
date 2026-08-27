//! 키 입력 · IME · 키바인딩 — 키 이벤트 라우팅과 소비 판정, IME 조합 수명, 커밋 텍스트 전달,
//! 키 힌트 오버레이, 전역 핫키와 재지정.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F12).
//!
//! 이름 함정을 걸렀다 — `ime`가 `formatRelativeTime`·`logFrameTime`·`sessionHostRuntimeBase`의
//! **부분 문자열**(T`ime`·Runt`ime`)로 걸린다. F6의 `tab`↔`stable`과 같은 유형이라 `ime`는 단어
//! 시작에서만 잡도록 좁혔다. 그 밖에 `assertPinnedPrefixRuntime`(탭 고정 구획 — F6 보정 소유)과
//! `webKeyRoute`(F11이 이미 가져간 것의 허브 facade)도 제외했다.
//!
//! IME는 **터미널과 chrome 필드 둘 다**를 상대한다 — `imeSetPreedit`가 `addr_field`·
//! `agent_session_archive_search`를 먼저 보고 없으면 터미널로 간다. 그래서 web(F11)이나 특정 표면
//! 그룹이 아니라 입력 라우팅 그룹의 소유다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const terminal = maru.terminal;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const input_ops = app_session_mod.input_ops;
const web_ops = app_session_mod.web_ops;
const agent_dock = app_session_mod.agent_dock;
const scm_dock_ops = app_session_mod.scm_dock_ops;
const placeholder_cell_height_px = app_session_mod.placeholder_cell_height_px;
const placeholder_cell_width_px = app_session_mod.placeholder_cell_width_px;
const ImeCursorRect = app_session_mod.ImeCursorRect;
const term_ops = @import("term.zig");
const barMetrics = app_session_mod.barMetrics;
const pane_ops = @import("pane.zig");
const editor_ops = @import("editor.zig");
const settings_ops = @import("settings.zig");
const shouldReplayAfterCommit = AppSession.shouldReplayAfterCommit;
const sidebar_ops = @import("sidebar.zig");
const workspace_ops = @import("workspace.zig");
const EventKind = app_session_mod.EventKind;
const FrameSummary = app_session_mod.FrameSummary;
const GlobalHotkey = app_session_mod.GlobalHotkey;
const InputFocus = AppSession.InputFocus;
const KeyHintConfigAbi = AppSession.KeyHintConfigAbi;
const Term = app_session_mod.Term;
const command_catalog = app_session_mod.command_catalog;
const config_mod = app_session_mod.config_mod;
const global_hotkey = app_session_mod.global_hotkey;
const keyhint_hold = app_session_mod.keyhint_hold;

/// 본문 분리: app_session/settings.zig(F9). ABI가 직접 부르므로 진입만 남긴다.
pub fn keyHintConfig(self: *const AppSession) KeyHintConfigAbi {
    return settings_ops.keyHintConfig(self);
}

/// chord가 빌트인 단축키(default_app_bindings·default_terminal_bindings)에 묶여 있나 — 매크로가 빌트인을 덮는지 경고용
/// (KeyBindingResolver.validate는 사용자 바인딩만 보므로 빌트인 충돌은 여기서 별도로 본다).
pub fn chordShadowsBuiltin(chord: config_mod.keybinding.KeyChord) bool {
    for (config_mod.keybinding.default_app_bindings) |db| if (db.chord.eql(chord)) return true;
    for (config_mod.keybinding.default_terminal_bindings) |db| if (db.chord.eql(chord)) return true;
    return false;
}

/// terminal.KeyEvent → chrome.input.InputEvent. chrome은 terminal 타입을 모르므로(L1/L3 경계) 이 변환을
/// 플랫폼 어댑터가 소유한다. 모디파이어(shift/ctrl/opt/cmd)도 매핑한다 — find의 Shift+Enter(이전 매치)·
/// ⌘/⌃/⌥+글자(닫기) 판정에 쓴다. char가 아닌 키의 codepoint는 0.
pub fn chromeInputFromKeyEvent(event: terminal.KeyEvent) chrome.input.InputEvent {
    const key: chrome.input.Key = switch (event.key) {
        .enter => .enter,
        .escape => .escape,
        .arrow_up => .up,
        .arrow_down => .down,
        .arrow_left => .left,
        .arrow_right => .right,
        .backspace => .backspace,
        .char => .char,
        .tab => .tab,
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

/// Metal TerminalView에서 들어온 key는 물리 responder가 최신 사용자 intent다. file-tree와 surface-publish
/// pending은 의도적으로 Metal responder를 쓰므로 보존하고, overlay가 없는 stale dock owner는 native/Zig
/// race로 판정해 workspace로 정합한다. WebView key는 dispatchWebAppAction의 surface-aware 경로를 따로 쓴다.
pub fn handleMetalKeyEvent(self: *AppSession, event: terminal.KeyEvent) !FrameSummary {
    const stale_dock_owner = switch (self.focus_owner) {
        .dock_pending => self.inputFocus() == .terminal,
        .workspace, .file_tree => false,
    };
    if (stale_dock_owner) workspace_ops.focusWorkspaceInput(self);
    return self.handleKeyEvent(event);
}

/// key-down 처리의 공통 종결부 — 요약을 상태에서 다시 쓰고 이벤트 종류를 key_down으로 확정한다.
/// `handleKeyEvent`의 라우팅 분기는 20개가 넘는데 전부 이 두 줄로 끝나므로, 한 분기만 빠뜨려도
/// 그 경로의 요약이 이전 이벤트 값을 물고 나간다. 종결을 한 곳에 모아 그 실수를 구조적으로 막는다.
pub fn settleKeyEventSummary(self: *AppSession) void {
    self.writeSummaryFromState();
    self.last_summary.last_event_kind = @intFromEnum(EventKind.key_down);
}

/// PTY write 없이 여기서 종결되는 모든 경로 — chrome 오버레이·rename·주소창·사이드바 검색·도크·
/// 파일 트리, 그리고 스크롤백 페이지 스크롤처럼 **터미널 자신이** 소비하는 경우까지 포함한다.
/// 열거가 아니라 이 판정 기준으로 읽어야 새 분기가 늘어도 낡지 않는다.
pub fn keyConsumedByApp(self: *AppSession) FrameSummary {
    self.total_app_key_events += 1;
    settleKeyEventSummary(self);
    return self.last_summary;
}

/// 라우팅할 live surface가 없거나(닫힌 pane의 late input) 터미널 write가 실패한 키.
/// 치명적 fault가 아니므로 회계만 하고 정상으로 닫는다.
pub fn keyIgnored(self: *AppSession) FrameSummary {
    self.total_ignored_key_events += 1;
    settleKeyEventSummary(self);
    return self.last_summary;
}

/// 머신 Action을 적용한다 — show/hide면 chrome_host.key_hints.visible 토글(렌더 게이트가 본다). 타이머 시작/취소는
/// Swift(OS clock 책임)가 반환 action으로 한다. arm/cancel/none은 가시성 불변.
///
/// **가시성을 바꿀 땐 metal_dirty도 세운다**(단일 트리거). tick의 투영·chrome 오버레이 재빌드(buildChromeOverlayPrep)는
/// 전부 `if (self.metal_dirty)` 게이트 안이라, visible만 바꾸고 dirty를 안 세우면 frame이 그대로다 — 배지가 blink·셸
/// 출력 같은 **무관한** dirty 트리거가 올 때까지 안 뜨거나(show) 안 사라진다(hide). 특히 커서 blink가 꺼진(steady)
/// 화면에선 Cmd를 떼도 metal_dirty가 안 서서 배지가 남는다("누르고 떼면 사라져야 하는데 유지" — 사용자 지적).
/// Swift의 markMetalNeedsRedraw는 Swift측 present 게이트라 Zig 재빌드(metal_dirty)와 별개다 — 둘 다 필요.
pub fn applyKeyHintAction(self: *AppSession, action: keyhint_hold.Action) void {
    switch (action) {
        .show => {
            self.chrome_host.key_hints.visible = true;
            self.metal_dirty = true;
        },
        .hide => {
            self.chrome_host.key_hints.visible = false;
            self.metal_dirty = true;
        },
        .none, .arm_timer, .cancel => {},
    }
}

/// Swift flagsChanged → 홀드 머신. config(enabled·trigger)를 적용해 arm/cancel/hide를 판정하고, 가시성 변화를 반영한 뒤
/// action을 돌려준다(Swift가 OS 타이머 시작/취소·redraw). mods는 현재 눌린 4 modifier.
pub fn keyHintOnFlags(self: *AppSession, mods: keyhint_hold.Mods) keyhint_hold.Action {
    const kh = self.loaded_config.config.keyhint;
    const action = self.key_hint_hold.onFlags(mods, kh.enabled, kh.modifier);
    applyKeyHintAction(self, action);
    return action;
}

/// Swift 타이머 만료 → 홀드 머신. armed면 show(글로벌 재읽기 없음). 취소된 늦은 fire는 none(race 안전).
/// config `keyhint.enabled`(라이브)를 넘겨, arm 후 비활성화됐으면 만료가 배지를 깜빡이지 않게 한다.
pub fn keyHintOnTimer(self: *AppSession) keyhint_hold.Action {
    const action = self.key_hint_hold.onTimerFire(self.loaded_config.config.keyhint.enabled);
    applyKeyHintAction(self, action);
    return action;
}

/// Swift keyDown(실제 단축키 실행)·포커스 상실 → 홀드 머신 취소(표시 중이면 hide).
pub fn keyHintCancel(self: *AppSession) keyhint_hold.Action {
    const action = self.key_hint_hold.onKeyOrBlur();
    applyKeyHintAction(self, action);
    return action;
}

/// 활성 입력 대상의 IME 조합(marked) 텍스트를 교체한다(빈 bytes=해제). inputFocus 단일 출처로 분기 — exhaustive
/// switch라 입력 대상 추가 시 컴파일러가 누락을 막는다.
pub fn imeSetPreedit(self: *AppSession, bytes: []const u8) void {
    // 이미 terminal composition이 시작됐으면 current UI focus보다 pin이 우선한다. palette/settings 등
    // 다른 owner가 먼저 열려도 AppKit의 후속 clear/commit이 새 owner로 새지 않게 원 Surface에서 끝낸다.
    if (self.ime_terminal_target_id != null or self.inputFocus() == .terminal) {
        if (bytes.len > 0 and self.ime_terminal_target_id == null) {
            const active = self.app_window.active() orelse return;
            self.ime_terminal_target_id = active.id;
        }
        const target_id = self.ime_terminal_target_id orelse return;
        const surface = imeTerminalSurfaceById(self, target_id) orelse {
            // 진행 중 target 소멸은 transaction 끝까지 tombstone으로 유지한다. 다음 non-empty
            // callback이 새 active surface를 다시 pin하면 오삽입되므로 여기서 null로 바꾸지 않는다.
            if (bytes.len == 0 and !self.ime_active) self.ime_terminal_target_id = null;
            return;
        };
        // **편집기 Term이면 코어가 아니라 문서 쪽에 둔다**(N3). 편집기의 코어는 1×1 sentinel이라
        // 거기 얹은 조합 글자는 **화면에 닿지 않는다** — 실측: 한글을 치면 조합 중에는 아무것도
        // 안 보이고 음절이 확정될 때만 툭 나타났다(적대적 검증 2026-08-27). 확정 텍스트는 이미
        // 편집기로 가고 있었으므로(`sendCommittedText`) 조합만 갈 곳이 없었던 것이다.
        if (editorTermBySurfaceId(self, target_id)) |editor_term| {
            editor_ops.setEditorPreedit(self, editor_term, bytes);
            self.metal_dirty = true; // 편집기는 출력이 없어 아무도 안 깨운다
            if (bytes.len == 0 and !self.ime_active) self.ime_terminal_target_id = null;
            return;
        }
        surface.lockCore(self.io);
        _ = surface.setPreeditLocked(bytes);
        surface.unlockCore(self.io);
        if (bytes.len == 0 and !self.ime_active) self.ime_terminal_target_id = null;
        return;
    }
    switch (self.inputFocus()) {
        .confirm, .notice, .file_tree, .dock_pending => {}, // 구조 input owner는 조합을 표시하지 않는다.
        .settings => self.chrome_host.settings.setSearchPreedit(bytes), // 세팅 검색줄 조합(고정 버퍼 — OverlayInput과 별개)
        .rename => self.rename_input.setPreedit(self.allocator, bytes) catch {},
        .sidebar_search => self.sidebar_search_input.setPreedit(self.allocator, bytes) catch {},
        .agent_session_search => self.agent_session_archive_search.setPreedit(self.allocator, bytes) catch {},
        // **조합은 포커스를 따라간다**(§5.1 — "두 입력 사이 포커스 이동과 IME 조합이 각각 독립").
        // 검색어 칸에 고정하면 바꿀 문자열을 한글로 치는 동안 조합 글자가 **위 줄에 쌓인다**
        // (적대적 검증 2026-08-27이 계약 문장을 근거로 잡았다).
        .find => self.chrome_host.find.focused().setPreedit(self.allocator, bytes) catch {},
        .palette => self.chrome_host.palette.input.setPreedit(self.allocator, bytes) catch {},
        // 커밋 상자 조합. **NFC 조합을 하지 않는다** — 주소창이 그것을 하는 이유는 codepoint당 셀
        // 하나로 그리기 때문이고(자모가 안 합쳐진다), 이 상자는 CoreText 셰이핑 경로라 NFD 자모도
        // 한 글자로 합쳐 그려진다(터미널·find와 같다).
        .scm_commit => scm_dock_ops.setCommitPreedit(self, bytes),
        .addr_edit => {
            // 조합 중 텍스트를 addr_field에. **NFC 조합**: macOS IME가 NFD conjoining 자모(ㄱ+ㅏ)를 주면 주소창은
            // codepoint당 단일 셀이라 안 합쳐지므로(터미널·find는 클러스터/shaping) 저장 경계서 완성형으로 합친다.
            if (maru.grapheme.composeHangul(self.allocator, bytes)) |composed| {
                defer self.allocator.free(composed);
                self.addr_field.setPreedit(self.allocator, composed) catch {};
            } else |_| self.addr_field.setPreedit(self.allocator, bytes) catch {};
        },
        .terminal => unreachable, // 위 terminal/pin 우선 경로가 소비한다.
    }
}

/// 활성 입력 대상이 조합 중(preedit 있음)인가 — imeBegin/imeEnd가 조합 판정에 쓴다. 예전엔 terminal preedit만 봐서
/// find/palette 조합을 놓쳤다(단일-출처 위반 → 조합 보호·표시 버그). inputFocus로 통일.
pub fn imeComposingActive(self: *AppSession) bool {
    if (self.ime_terminal_target_id) |target_id| {
        // 편집기 Term의 조합은 문서 쪽에 있다(N3) — 코어를 물으면 늘 "조합 없음"이라, 조합 보호가
        // 걸려야 할 자리에서 안 걸린다.
        if (editorTermBySurfaceId(self, target_id)) |editor_term| return editor_term.rt.editor_preedit.len > 0;
        const surface = imeTerminalSurfaceById(self, target_id) orelse return false;
        surface.lockCore(self.io);
        defer surface.unlockCore(self.io);
        return surface.preeditActiveLocked();
    }
    return switch (self.inputFocus()) {
        .confirm, .notice, .file_tree, .dock_pending => false, // 구조 input owner는 조합 상태가 없다.
        .settings => self.chrome_host.settings.searchPreedit().len > 0,
        .rename => self.rename_input.preedit.items.len > 0,
        .sidebar_search => self.sidebar_search_input.preedit.items.len > 0,
        .agent_session_search => self.agent_session_archive_search.preedit.items.len > 0,
        .find => self.chrome_host.find.focused().preedit.items.len > 0,
        .palette => self.chrome_host.palette.input.preedit.items.len > 0,
        .addr_edit => self.addr_field.preedit.items.len > 0, // 주소창 조합 중이면 true
        .scm_commit => self.scm_commit_field.preedit.items.len > 0,
        .terminal => blk: {
            const surface = self.app_window.active() orelse break :blk false;
            surface.lockCore(self.io);
            defer surface.unlockCore(self.io);
            break :blk surface.preeditActiveLocked();
        },
    };
}

/// IME 키 트랜잭션 시작(Swift keyDown 진입 — 수정자 없는 키). 이번 키에서 입력기가 만들
/// 텍스트/조합 변화를 모으기 시작한다.
pub fn imeBegin(self: *AppSession) void {
    if (!self.surface_initialized) return;
    // missing pin에서도 transaction은 반드시 열린 뒤 imeEnd에서 닫혀야 한다. 예전 조기 반환은
    // ime_active=false를 남겨 imeMarked 변화가 기록되지 않았고, imeEnd가 다음 active terminal로
    // 물리 키를 encode/replay했다.
    self.ime_active = true;
    self.ime_inserted.clearRetainingCapacity();
    self.ime_marked_changed = false;
    self.ime_did_delete = false;
    self.ime_insert_failed = false;
    self.ime_terminal_target_tombstoned = false;
    // 조합도 타이핑이다 — 과거를 보는 중이면 바닥으로 스냅해 preedit이 보이게 한다
    // (handleKeyEvent의 "입력하면 live 복귀"와 같은 동작; 조합 키는 그 경로를 안 타므로 여기서).
    // **터미널 입력일 때만** — find/palette에서 조합하면 뒤 터미널 스크롤백을 건드리면 안 된다(조합은
    // 오버레이 입력칸으로 가지 터미널로 안 간다; inputFocus 단일 출처로 판정).
    if (self.ime_terminal_target_id != null or self.inputFocus() == .terminal) {
        // viewOffset 읽기는 메인 락-아래(§9.1), scrollToBottom mutate는 reader로 위임(full (a), §9 P3-4).
        const surface = if (self.ime_terminal_target_id) |target_id|
            imeTerminalSurfaceById(self, target_id) orelse {
                self.ime_terminal_target_tombstoned = true;
                self.ime_had_marked = false;
                return;
            }
        else
            self.app_window.active() orelse {
                self.ime_terminal_target_tombstoned = true;
                self.ime_had_marked = false;
                return;
            };
        const scrolled = blk: {
            surface.lockCore(self.io);
            defer surface.unlockCore(self.io);
            break :blk surface.baseViewportScrolledLocked();
        };
        if (scrolled == true) {
            self.runtime.enqueueCoreCommand(surface.id, .scroll_to_bottom, self.io) catch {};
            self.metal_dirty = true;
        }
        if (self.ime_terminal_target_id == null) self.ime_terminal_target_id = surface.id;
    }
    self.ime_had_marked = imeComposingActive(self); // 단일 출처(터미널/find/palette)
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
        routeCommittedText(self, bytes);
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
    imeSetPreedit(self, bytes);
    self.metal_dirty = true; // 조합 글자는 즉시 보여야 한다
    if (self.ime_active) self.ime_marked_changed = true;
}

/// 입력기의 deleteBackward 편집 명령(doCommand). 트랜잭션에 기록만 하고 판정은 imeEnd가 한다.
pub fn imeDeleteBackward(self: *AppSession) void {
    if (self.ime_active) self.ime_did_delete = true;
}

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
    // target이 imeBegin 뒤 사라진 경우도 같은 transaction에서 tombstone으로 승격한다. pin id가
    // 존재한다는 이유만으로 routeCommittedText는 새 active로 fallback하지 않지만, encode_key/replay는
    // handleKeyEvent를 직접 타므로 이 명시 상태가 없으면 새 terminal로 샌다.
    if (self.ime_terminal_target_id) |target_id| {
        if (imeTerminalSurfaceById(self, target_id) == null) {
            self.ime_terminal_target_tombstoned = true;
        }
    }
    const composing = imeComposingActive(self) or self.ime_had_marked; // 단일 출처(find/palette도) — core만 보던 누락 수정
    defer {
        self.ime_active = false;
        self.ime_inserted.clearRetainingCapacity();
        self.ime_marked_changed = false;
        self.ime_did_delete = false;
        self.ime_insert_failed = false;
        self.ime_terminal_target_tombstoned = false;
        if (self.ime_terminal_target_id) |target_id| {
            const still_composing = if (imeTerminalSurfaceById(self, target_id)) |surface| active: {
                surface.lockCore(self.io);
                defer surface.unlockCore(self.io);
                break :active surface.preeditActiveLocked();
            } else false;
            if (!still_composing) self.ime_terminal_target_id = null;
        }
    }
    // 사라진 pinned target의 AppKit transaction은 소비하되 어떤 payload/key도 현재 active로
    // 재지정하지 않는다. defer가 tombstone pin과 transaction state를 함께 정리한다.
    if (self.ime_terminal_target_tombstoned) return;
    // OOM으로 누적이 잘렸으면 통째로 버린다 — 반쪽 문자열을 PTY에 보내지 않는다(#14).
    if (self.ime_insert_failed) return;
    switch (imeDecide(composing, self.ime_inserted.items, self.ime_marked_changed, self.ime_did_delete)) {
        .commit_text => |text| {
            // #10 후속: 확정 텍스트를 현재 입력 대상으로 라우팅한다 — imeEnd는 keyDown(interpretKeyEvents
            // 직후) 동기 콜백이라, 터미널 PTY로 blocking enqueue하면 write_queue 포화 시 tick을 멈춰
            // commitComposition과 같은 backpressure 데드락이 된다(#10이 그쪽만 되돌렸다). 터미널이면
            // non-blocking, find/palette 입력칸이면 기존 키 경로(routeCommittedText 참조). 아래 replay(화살표·Enter)는
            // 인코딩이 필요해 그대로 키 경로(handleKeyEvent)를 쓴다 — 버퍼 포화 시 순서/blocking 한계는 그 블록 주석 참조.
            const terminal_target: ?u64 =
                if (self.ime_terminal_target_id) |target_id|
                    target_id
                else if (self.inputFocus() == .terminal)
                    (if (self.app_window.active()) |surface| surface.id else null)
                else
                    null;
            const replay_event: ?terminal.KeyEvent = if (event) |ev|
                if (shouldReplayAfterCommit(ev, self.ime_enter_newline)) ev else null
            else
                null;
            const admitted = if (terminal_target) |target_id|
                if (replay_event) |ev|
                    routeTerminalCommittedWithReplay(self, target_id, text, ev)
                else
                    routeCommittedTextAccepted(self, text)
            else
                routeCommittedTextAccepted(self, text);
            // 한글 후보를 화살표로 확정하는 경우(insertText('안') + 화살표): 텍스트만 보내고
            // 화살표를 버리면 커서가 안 움직인다. 확정 후 그 화살표를 다시 보낸다(Ghostty
            // shouldReplayCommittedPreeditKey와 같은 의미론 — 위/오른/아래는 항상, 왼쪽은
            // 수정자 있을 때만; plain 왼쪽은 AppKit이 이미 커서를 제자리에 둬 중복 이동 방지).
            // Enter는 config(input.ime-enter=newline, 기본)면 함께 replay해 조합 확정과 개행을 한 번에
            // 처리한다(브라우저 동작). replay되는 Enter는 handleKeyEvent를 거쳐 일반 Enter=`\r`,
            // Shift+Enter=Meta 변형(`\x1b\r`)으로 인코딩된다(shift→meta 변환·kitty 인코딩·find_nav 등 부작용 유지).
            // 터미널 replay도 확정 텍스트와 **같은 surface FIFO** 뒤에 append한다. socket/PTY가
            // 막혀도 Enter/화살표가 텍스트를 추월하지 않고 AppKit callback도 block하지 않는다.
            // 텍스트 admission이 OOM이면 replay만 보내는 반쪽 transaction도 만들지 않는다.
            if (admitted and terminal_target == null) {
                if (replay_event) |ev| {
                    _ = self.handleKeyEvent(ev) catch {};
                }
            }
        },
        .ignore => {}, // 조합 조작 키(자모 삭제) 또는 조합 중 단일 C0 — 입력기 소유
        .encode_key => if (event) |ev| {
            _ = self.handleKeyEvent(ev) catch {};
        },
    }
}

/// 비터미널 입력 owner(addr/find/palette 등)에 확정 텍스트를 코드포인트 key event로 전달한다.
/// terminal IME 확정은 이 함수를 쓰지 않고 surface별 ordered queue에 UTF-8을 직접 admission한다.
/// 여기서는 개행을 `.enter`(\r)로 정규화한다. bracketed paste 없음. 드래그앤드롭은
/// paste 경로(pasteText→encodePaste)로 별도다 — TUI([Image]) 인식을 위해 DECSET 2004가
/// 켜졌을 때 bracketed paste로 감싸야 하므로.
/// **불변식: 호출 시 surface.core_mutex를 보유하면 안 된다** — handleKeyEvent가 인코딩 중 core_mutex를 재취득하는데
/// std.Io.Mutex는 비재진입이라 같은 스레드가 이미 보유 중이면 자기 데드락(ulock_wait)이다.
/// 신규 비터미널 호출처도 이 규율을 지킬 것.
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
/// (surface별 paste 큐 `pending_pastes` + `flushPendingPaste`의 `writeInputNonBlocking`). `windowLostKey` 등
/// AppKit 동기 콜백 안에서 호출돼도 blocking enqueue로 메인 run loop(=tick)를 멈추지 않아 #10
/// write_queue backpressure 데드락을 피한다(설계 전제 "입력 전송은 tick 안"에 코드를 맞춤 —
/// P2-3b write_queue 구조는 그대로). 확정 텍스트는 완성된 평문이라 키 인코딩(handleKeyEvent)
/// 없이 바이트로 보내되 개행만 \r로 정규화한다(sendTextAsKeys와 동일 규약; bracketed 감싸기는
/// paste 전용이라 IME 확정엔 안 쓴다). 큐는 **surface별**이라 paste와 같은 큐를 공유해 그 surface 안에서 전송
/// 순서를 지킨다(다른 surface의 잔여와는 애초에 안 섞인다 — 옛 단일 FIFO는 서로 막고 섞였다).
pub fn sendCommittedText(self: *AppSession, bytes: []const u8) bool {
    if (!self.surface_initialized or bytes.len == 0) return true;

    // imeBegin/첫 marked update가 고정한 대상이 있으면 그 surface로 보낸다. AppKit 콜백 사이에
    // 활성 pane/tab이 바뀌어도 확정 바이트가 새 터미널로 새지 않는다.
    const target_id = self.ime_terminal_target_id orelse term_ops.activeSurface(self).id;

    // **편집기 Term이면 PTY가 아니라 문서로 간다**(N2 — §3.3).
    //
    // macOS는 평범한 글자를 `NSTextInputClient` 확정으로 보내므로 **타이핑의 실제 경로가 여기다** —
    // `handleKeyEvent`에는 Option+글자 같은 meta chord만 도달한다(아래 `.terminal_input` 주석이 같은
    // 사실을 적어 둔다). 그래서 편집기 분기를 키 경로에만 두면 **글자가 하나도 안 들어간다.**
    //
    // **판정은 활성 Term이 아니라 위에서 고른 대상으로 한다.** 처음에 `activePane().activeTerm()`을
    // 봤는데, 그것은 바로 위 주석이 막으려는 바로 그 누출을 반대 방향으로 낸다 — 터미널에서 조합을
    // 시작한 뒤 pane이 편집기로 바뀌면 **그 글자가 문서에 들어간다.** 고정의 요점은 "확정은 조합을
    // 시작한 곳으로 간다"이고, 편집기도 그 규칙 안에 있어야 한다(적대적 검증 2026-08-25).
    if (editorTermBySurfaceId(self, target_id)) |editor_term| {
        _ = editor_ops.insertText(self, editor_term, bytes);
        self.metal_dirty = true;
        return true; // 편집기가 삼켰다 — PTY로 흘리지 않는다
    }
    return sendCommittedTextTo(self, target_id, bytes);
}

/// IME transaction이 pin한 surface로 보내는 대상 명시형. target이 닫혔거나 다른 창으로
/// 이동했으면 새 active로 fallback하지 않고 폐기해 오삽입을 막는다.
pub fn sendCommittedTextTo(self: *AppSession, target_id: u64, bytes: []const u8) bool {
    if (!self.surface_initialized or bytes.len == 0) return true;
    if (imeTerminalSurfaceById(self, target_id) == null) return false;
    if (!self.enqueueTypedInputBytes(target_id, .ime_commit, bytes, true)) return false;
    // handleKeyEvent를 우회하므로 terminal input 회계를 여기서 직접 한다(\n→\r는 1:1이라 byte 수 동일).
    self.total_terminal_input_events += 1;
    self.total_terminal_input_bytes += bytes.len;
    // 선택 해제도 같은 이유로 여기가 사이트다 — macOS는 평범한 글자 입력을 IME 확정으로 커밋해
    // handleKeyEvent를 우회하므로(mouse-hide-while-typing과 같은 사정), 키 경로에만 걸면 실제 타이핑에
    // 반응하지 않는다. 바이트가 **실제로 큐에 수락된 뒤에만** 해제해 폐기된 확정이 하이라이트를 지우지 않게 한다.
    if (self.loaded_config.config.input.selection_clear_on_typing) term_ops.clearSurfaceSelection(self, target_id);
    return true;
}

/// IME 확정 텍스트를 현재 입력 대상(inputFocus 단일 출처)으로 라우팅한다. 터미널이면 non-blocking PTY
/// 전송(sendCommittedText — AppKit 동기 콜백에서 write_queue backpressure 데드락 회피, #10 후속). find/
/// palette 입력칸이면 그 입력은 메모리 조작이라 write_queue를 안 거쳐 데드락과 무관하므로, inputFocus
/// 분기를 흡수하는 기존 키 경로(sendTextAsKeys→handleKeyEvent)로 보내 검색어/명령어에 글자가 들어가게
/// 한다(이 분기를 빼면 find 조합 확정이 PTY로 새 입력칸이 빈다 — 회귀 테스트가 고정). 터미널 타이핑은
/// "검색 종료(find_nav)"도 함께 처리한다(handleKeyEvent 3478과 동일 의미).
pub fn routeCommittedText(self: *AppSession, bytes: []const u8) void {
    _ = routeCommittedTextAccepted(self, bytes);
}

/// routeCommittedText와 같은 부작용을 수행하되, 터미널 ordered queue가 bytes를 실제로
/// 수락했는지를 돌려준다. imeEnd는 false일 때 replay key까지 억제해 반쪽 transaction을 막는다.
pub fn routeCommittedTextAccepted(self: *AppSession, bytes: []const u8) bool {
    // 진행 중 terminal transaction의 insertText는 UI focus가 먼저 바뀌었어도 pin된 원 target으로 간다.
    const focus: InputFocus = if (self.ime_terminal_target_id != null) .terminal else self.inputFocus();
    if (focus == .file_tree) return true; // tree focus에서 평문/IME가 뒤 PTY로 새지 않는다.
    if (focus == .terminal) {
        if (self.find_nav) self.find_nav = false;
        // 타이핑(글자 입력) 중 마우스 숨김(config). IME 확정 텍스트가 터미널로 갈 때 = 실제 글자 타이핑(ASCII·한글·
        // CJK 모두 이 경로 — macOS NSTextInputClient가 평범한 키 입력을 여기로 커밋, handleKeyEvent 우회). find/
        // palette 입력칸(else 분기)은 chrome 타이핑이라 안 숨긴다. Swift가 takeMouseHide로 drain → setHiddenUntilMouseMoves.
        // 베이스: Ghostty mouse-hide-while-typing(press+utf8.len>0) — utf8 텍스트 produce가 곧 IME 확정이다(F1-6).
        if (self.loaded_config.config.input.mouse_hide_while_typing and bytes.len > 0) self.mouse_hide_pending = true;
        return sendCommittedText(self, bytes);
    } else if (focus == .addr_edit) {
        // 주소창 확정 텍스트는 **NFC 조합** 후 키 경로로(codepoint당 셀이라 NFD 자모 미조합 — imeSetPreedit과 동일 사유).
        // find/palette/rename/sidebar_search는 shaping/클러스터라 이 분기 밖(무해하나 불필요).
        if (maru.grapheme.composeHangul(self.allocator, bytes)) |composed| {
            defer self.allocator.free(composed);
            sendTextAsKeys(self, composed);
        } else |_| sendTextAsKeys(self, bytes);
    } else {
        sendTextAsKeys(self, bytes);
    }
    return true;
}

/// 터미널 IME 확정 문자열과 replay key를 먼저 모두 준비한 뒤 한 번의 capacity reservation으로
/// pending FIFO에 원자적으로 append한다. 둘 중 하나만 admission되는 partial transaction은 없다.
pub fn routeTerminalCommittedWithReplay(self: *AppSession, target_id: u64, text: []const u8, event: terminal.KeyEvent) bool {
    if (self.find_nav) self.find_nav = false;
    if (self.loaded_config.config.input.mouse_hide_while_typing and text.len > 0) self.mouse_hide_pending = true;
    var buffer: [terminal.input.encoded_key_buffer_len]u8 = undefined;
    const replay = encodeImeReplayKeyTo(self, target_id, event, &buffer) orelse return false;
    if (!queueInputPair(self, target_id, text, true, replay)) return false;
    self.total_terminal_input_events += 2;
    self.total_terminal_input_bytes += text.len + replay.len;
    // 확정+replay 쌍도 타이핑이다 — sendCommittedTextTo와 같은 규율로 수락 후에만 선택을 해제한다.
    if (self.loaded_config.config.input.selection_clear_on_typing) term_ops.clearSurfaceSelection(self, target_id);
    self.flushPendingPaste();
    return true;
}

/// IME 확정과 함께 replay할 Enter/화살표를 target surface의 현재 입력 모드로 인코딩한다.
/// 반환 slice는 caller가 준 stack buffer를 빌리므로 즉시 ordered queue에 복사해야 한다.
pub fn encodeImeReplayKeyTo(
    self: *AppSession,
    target_id: u64,
    event: terminal.KeyEvent,
    buffer: *[terminal.input.encoded_key_buffer_len]u8,
) ?[]const u8 {
    const surface = imeTerminalSurfaceById(self, target_id) orelse return null;
    var key_event = event;
    if (self.shift_enter_meta and key_event.key == .enter and key_event.modifiers.shift and
        !key_event.modifiers.control and !key_event.modifiers.option and !key_event.modifiers.command)
    {
        key_event.modifiers = .{ .option = true };
    }

    var options: terminal.input.EncodeOptions = .{};
    if (surface.remote != null) {
        // RemoteRuntime observation이 현재 wire로 노출하는 입력 모드는 DECCKM뿐이다. 나머지는
        // 기존 remote key path와 같은 placeholder 기본값을 쓰며, protocol 확장은 별도 범위다.
        if (term_ops.findTermWhere(self, target_id, struct {
            fn pred(id: u64, term: *Term) bool {
                return term.kind == .terminal and term.surface.id == id;
            }
        }.pred)) |loc| {
            const term = loc.pane.terms.items[loc.term_index];
            if (term.rt.observation.availability != .unavailable)
                options.application_cursor_keys = term.rt.observation.app_cursor_keys;
        }
    } else {
        surface.lockCore(self.io);
        options = surface.core.encodeOptions();
        surface.unlockCore(self.io);
    }
    options.option_as_meta = self.option_as_meta;
    return terminal.input.encodeKey(key_event, buffer, options) catch null;
}

/// IME transaction이 pin한 terminal surface를 찾는다. id가 없거나 그 Term이 web이면 null이며
/// 호출자는 새 active surface로 fallback하지 않는다.
/// 이 surface를 든 **편집기 Term**. 터미널이거나 없으면 `null`.
///
/// `terminalSurfaceById`가 `kind != .terminal`을 걸러 내는 것과 짝이다 — 그쪽은 "터미널만",
/// 이쪽은 "편집기만"이다. 둘을 한 함수로 합치면 호출자가 kind를 다시 물어야 하고, 그 물음이
/// 빠지는 날 확정 바이트가 엉뚱한 Term으로 간다.
/// 조합이 향하는 편집기 Term — 고정(pin)이 있으면 그것, 없으면 활성 Term.
fn activeEditorTermForIme(self: *AppSession) ?*Term {
    if (self.ime_terminal_target_id) |target_id| return editorTermBySurfaceId(self, target_id);
    if (!self.surface_initialized or self.tabs.items.len == 0) return null;
    const term = pane_ops.activePane(self).activeTerm();
    return if (term.kind == .editor) term else null;
}

/// 이 surface id가 편집기 Term인가 — 그룹 밖(app_session)에서도 묻는다(포커스 상실 확정).
pub fn editorTermForIme(self: *AppSession, id: u64) ?*Term {
    return editorTermBySurfaceId(self, id);
}

fn editorTermBySurfaceId(self: *AppSession, id: u64) ?*Term {
    const loc = term_ops.findTermWhere(self, id, struct {
        fn pred(want: u64, term: *Term) bool {
            return term.kind == .editor and term.surface.id == want;
        }
    }.pred) orelse return null;
    return loc.pane.terms.items[loc.term_index];
}

pub fn imeTerminalSurfaceById(self: *AppSession, id: u64) ?*maru.session.Surface {
    // 정상 입력 중인 target은 대부분 app_window.active와 같다. 이 fast path는 전체 Term 순회를
    // 피하고, 최소 fixture가 app_window만 세운 기존 IME 계약 테스트도 같은 제품 경로를 탄다.
    if (self.app_window.active()) |active| if (active.id == id) return active;
    return term_ops.terminalSurfaceById(self, id);
}

/// first+second를 한 capacity reservation 뒤에 append한다. first는 IME 확정 문자열이라 선택적으로
/// LF→CR 정규화하고, second는 이미 인코딩된 replay bytes다. OOM이면 기존 queue를 전혀 바꾸지 않는다.
pub fn queueInputPair(
    self: *AppSession,
    target_id: u64,
    first: []const u8,
    normalize_first_newlines: bool,
    second: []const u8,
) bool {
    return self.queueInputBatch(target_id, .ime_commit, first, normalize_first_newlines, second);
}

/// 전역(OS) 단축키 기술자 목록(global_hotkeys)을 loaded_config.global_bindings에서 다시 빌드한다. init이 한 번 부르고,
/// 라이브 변경(rebindGlobalEntry/unbindGlobalEntry/reloadConfig/resetAllSettings)이 부른다 — 기존 목록을 비우고 각
/// 바인딩을 descriptorFor로 매핑해 채운다(가상 키코드로 매핑 안 되는 chord는 null → 스킵, 등록 불가라 init과 같은 동작).
/// descriptor는 POD라 self.allocator로 복사(arena 무관 — global_bindings arena가 reload에서 갈려도 안전). dirty는
/// 여기서 세우지 않는다(앱 시작 1회 vs 라이브 재등록을 호출자가 가른다 — init은 false 유지, 라이브 경로는 true로 세움).
pub fn rebuildGlobalHotkeys(self: *AppSession) !void {
    self.global_hotkeys.clearRetainingCapacity();
    for (self.loaded_config.global_bindings) |gb| {
        if (global_hotkey.descriptorFor(gb)) |d| {
            try self.global_hotkeys.append(self.allocator, .{
                .virtual_key_code = d.virtual_key_code,
                .carbon_modifiers = d.carbon_modifiers,
                .action = @intFromEnum(d.action),
            });
        }
    }
}

/// 전역(OS) 단축키 등록 기술자 목록(가상 키코드 + Carbon modifier + action). config에서 만들어 Swift가
/// 읽어 RegisterEventHotKey로 등록한다(시작 시 1회 + 라이브 변경 시 takeGlobalHotkeysDirty drain → 재등록). 매핑 가능한 chord만.
pub fn globalHotkeys(self: *const AppSession) []const GlobalHotkey {
    return self.global_hotkeys.items;
}

/// 액션을 새 chord로 다시 묶는다(keybind recorder). loaded_config.keybindings를 새 슬라이스로 교체(그 액션 줄을 새
/// chord로, 없으면 추가 — resolver가 매 키 이벤트마다 이 슬라이스를 읽으므로 즉시 반영), 카탈로그 재빌드, write-back
/// 예약(updateKeybindLines가 `keybind = chord = action` 줄로 영속). 옛 슬라이스는 미참조로 남아 reload/deinit에 해제.
/// 한계(v1): 옛 chord가 빌트인이면 그 chord도 계속 액션을 발동한다(새 chord를 **추가**하는 셈 — unbind는 후속).
/// 한 액션의 **빌트인 chord(들)**(default_app_bindings)를 unbind한다 — loaded_config.unbinds에 넣어(라이브 ignored)
/// `keybind = chord = unbind`로 영속한다. `except`가 주어지면 그 chord는 안 죽인다(완전 교체에서 새 chord가 빌트인과
/// 같을 때 그 키를 살린다 — 사용자 바인딩이 resolver 우선이라 동작은 같지만 파일에 중복 unbind 줄을 안 남긴다). 이미
/// unbinds에 있으면 스킵(중복 누적 방지). 다중-chord 빌트인(next/previous_tab·increase/decrease_font_size=2개)은 전부
/// 처리(리뷰 #840). 카탈로그 재빌드는 호출자가 한다. **rebind(완전 교체)·unbind(완전 해제)가 공유하는 단일 출처.**
pub fn unbindBuiltinChords(self: *AppSession, entry: command_catalog.Entry, except: ?config_mod.KeyChord) void {
    const a = self.loaded_config.arena.allocator();
    var ub: std.ArrayList(config_mod.KeyChord) = .empty;
    ub.appendSlice(a, self.loaded_config.unbinds) catch return;
    var added_any = false;
    for (config_mod.keybinding.default_app_bindings) |db| {
        if (!std.meta.eql(db.action, entry.action)) continue;
        if (except) |x| if (x.eql(db.chord)) continue; // 새 chord(=빌트인)는 안 죽임
        var dup = false;
        for (ub.items) |u| if (u.eql(db.chord)) {
            dup = true;
            break;
        };
        if (dup) continue;
        ub.append(a, db.chord) catch return;
        added_any = true;
        var chord_buf: [command_catalog.max_chord_display_len]u8 = undefined;
        markKeybindUnbind(self, a.dupe(u8, db.chord.toConfigString(&chord_buf)) catch return);
    }
    if (added_any) self.loaded_config.unbinds = ub.toOwnedSlice(a) catch return;
}

pub fn rebindActionEntry(self: *AppSession, entry: command_catalog.Entry, chord: config_mod.KeyChord) void {
    const a = self.loaded_config.arena.allocator();
    // 충돌 경고: 이 chord가 **다른 액션**에 이미 묶여 있으면 알린다(rebind는 진행 — 사용자 의도, last-wins). 현재 effective
    // chord(사용자/빌트인) 기준으로 카탈로그 액션을 스캔. 메시지는 스택 버퍼 → showNotice가 복사하므로 안전.
    const resolver_pre = self.loaded_config.keyBindingResolver();
    for (command_catalog.entries) |other| {
        if (std.meta.eql(other.action, entry.action)) continue;
        const oc = command_catalog.chordForAction(resolver_pre, other.action) orelse continue;
        if (oc.eql(chord)) {
            // 값이 끼는 유일한 자리 — §6.3 보간 진입점을 쓴다(std.fmt은 comptime 틀만 받아 번역 문자열에 못 쓴다).
            settings_ops.settingsMessageOrNoticeFmt(self, .set_chord_taken_by, &.{.{ .s = other.title }});
            break;
        }
    }
    var list: std.ArrayList(config_mod.AppBinding) = .empty;
    var replaced = false;
    for (self.loaded_config.keybindings) |b| {
        if (std.meta.eql(b.action, entry.action)) {
            list.append(a, .{ .chord = chord, .action = entry.action }) catch return;
            replaced = true;
        } else list.append(a, b) catch return;
    }
    if (!replaced) list.append(a, .{ .chord = chord, .action = entry.action }) catch return;
    self.loaded_config.keybindings = list.toOwnedSlice(a) catch return;
    // **완전 교체**: 새 chord를 묶는 데 더해, 그 액션의 빌트인 chord(새 chord 제외)를 unbind한다 — 안 그러면 빌트인이
    // 살아 있어 옛 키 + 새 키 둘 다 동작한다(추가가 아니라 교체여야 표시=동작·옛 키 되찾기). 새 chord가 빌트인과
    // 같으면(재확인) 그건 살린다(except). 키바인드 완전 교체 — docs/config-gui.md §6.7.
    unbindBuiltinChords(self, entry, chord);
    // stale unbind 정리: 이 새 chord가 옛 `keybind = chord = unbind`로 죽어 있었으면 그 모순 줄을 뺀다(사용자 바인딩으로 부활).
    self.clearStaleUnbind(chord);
    self.rebuildCommandCatalog();

    // 영속 예약 — action 키별 upsert(같은 액션 여러 번 바꾸면 마지막만). chord는 config 표기로 arena에 둔다.
    var chord_buf: [command_catalog.max_chord_display_len]u8 = undefined;
    const chord_str = a.dupe(u8, chord.toConfigString(&chord_buf)) catch return;
    for (self.config_keybind_rebinds.items) |*rb| {
        if (std.mem.eql(u8, rb.action, entry.key)) {
            rb.chord = chord_str;
            self.metal_dirty = true;
            return;
        }
    }
    self.config_keybind_rebinds.append(self.allocator, .{ .action = entry.key, .chord = chord_str }) catch return;
    self.metal_dirty = true;
}

/// 전역(OS) 액션을 새 chord로 다시 묶는다(rebindActionEntry의 글로벌 미러). chord가 전역 등록 불가(descriptorFor가
/// null — 가상 키코드 매핑 없음, 예 Plus·Insert)면 notice로 거부하고 중단한다(파일에 못 쓸 chord를 안 받는다). 아니면
/// loaded_config.global_bindings를 새 슬라이스로 교체(그 액션을 새 chord로, 없으면 추가, 같은 action 중복 제거),
/// write-back 예약(updateGlobalKeybindLines가 `keybind = global:<chord> = <action>` 줄로 영속). 옛 슬라이스는 미참조로
/// 남아 reload/deinit에 arena 통째 해제. OS 재등록(라이브)은 PR2 — 이번엔 "재시작 후 적용"이다.
pub fn rebindGlobalEntry(self: *AppSession, entry: command_catalog.GlobalEntry, chord: config_mod.KeyChord) void {
    const a = self.loaded_config.arena.allocator();
    // 전역 등록 가능한 chord인지 먼저 확인(가상 키코드 매핑) — 안 되면 파일에 못 쓸 chord라 거부.
    if (global_hotkey.descriptorFor(.{ .chord = chord, .action = entry.action }) == null) {
        settings_ops.settingsMessageOrNotice(self, .set_global_key_not_allowed); // 세팅 열림이면 배너(모달 유지), 아니면 토스트
        return;
    }
    // 충돌 경고(선택): 이 chord가 **다른 전역 액션**에 이미 묶여 있으면 알린다(rebind는 진행 — last-wins).
    for (self.loaded_config.global_bindings) |other| {
        if (other.action == entry.action) continue;
        if (other.chord.eql(chord)) {
            settings_ops.settingsMessageOrNotice(self, .set_global_chord_taken);
            break;
        }
    }
    // global_bindings를 새 슬라이스로 교체 — 이 액션은 새 chord로 갈고(같은 action 중복은 한 번만), 다른 액션은 보존.
    var list: std.ArrayList(config_mod.GlobalBinding) = .empty;
    var replaced = false;
    for (self.loaded_config.global_bindings) |b| {
        if (b.action == entry.action) {
            if (replaced) continue; // 같은 action 중복 제거(첫 매칭만 새 chord로)
            list.append(a, .{ .chord = chord, .action = entry.action }) catch return;
            replaced = true;
        } else list.append(a, b) catch return;
    }
    if (!replaced) list.append(a, .{ .chord = chord, .action = entry.action }) catch return;
    self.loaded_config.global_bindings = list.toOwnedSlice(a) catch return;

    // 영속 예약 — action 키별 upsert(같은 액션 여러 번 바꾸면 마지막만). chord는 config 표기로 arena에 둔다.
    var chord_buf: [command_catalog.max_chord_display_len]u8 = undefined;
    const chord_str = a.dupe(u8, chord.toConfigString(&chord_buf)) catch return;
    markGlobalRebind(self, entry.key, chord_str);
    // 라이브 OS 재등록(PR2) — global_hotkeys를 새 global_bindings로 다시 빌드하고 dirty를 세운다(Swift가 drain해 재등록).
    rebuildGlobalHotkeys(self) catch {};
    self.global_hotkeys_dirty = true;
    self.metal_dirty = true;
}

/// 전역 keybind 재바인딩 예약(markConfigKeyDirty·rebind upsert의 글로벌 미러 — action 키별 한 건). action은
/// command_catalog 정적 키, chord는 loaded_config.arena 소유(config 표기). serializeConfig가 updateGlobalKeybindLines로 반영.
pub fn markGlobalRebind(self: *AppSession, action_key: []const u8, chord_str: []const u8) void {
    for (self.config_global_rebinds.items) |*rb| {
        if (std.mem.eql(u8, rb.action, action_key)) {
            rb.chord = chord_str;
            return;
        }
    }
    self.config_global_rebinds.append(self.allocator, .{ .action = action_key, .chord = chord_str }) catch {};
}

/// `keybind = chord = unbind` 지시어 예약(중복 한 번만). chord는 config 표기(loaded_config.arena 소유).
pub fn markKeybindUnbind(self: *AppSession, chord_str: []const u8) void {
    for (self.config_keybind_unbinds.items) |c| if (std.mem.eql(u8, c, chord_str)) return;
    self.config_keybind_unbinds.append(self.allocator, chord_str) catch {};
}

/// keybind 녹음 중 raw 키 한 개를 처리한다(handleKeyEvent가 가로채 호출). 평범한 Esc(모디파이어 없음)는 취소(rebind
/// 안 함 — 흔한 recorder 관례). 그 외 키는 KeyChord로 만들어 선택된 keybind 행의 액션에 묶는다. 녹음은 한 키로 끝난다.
pub fn captureKeybindRecording(self: *AppSession, event: terminal.KeyEvent) void {
    self.chrome_host.settings.recording = false; // 취소든 캡처든 한 키로 종료
    self.chrome_host.settings.clearMessage(); // 새 녹음 시도 — 직전 안내 배너 정리(아래에서 실패/충돌 시 다시 세운다)
    const m = event.modifiers;
    if (event.key == .escape and !m.shift and !m.control and !m.option and !m.command) return; // 취소
    const chord = config_mod.KeyChord.fromKeyEvent(event) orelse return; // 매핑 불가 키는 무시(녹음만 끝남)
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const cf = settings_ops.currentSectionFields(self, scratch.allocator()) catch return;
    const sel = self.chrome_host.settings.selected;
    // in-app keybind 행이면 그 액션에 rebind, 전역 단축키 행이면 글로벌 분기로 rebind(둘은 selected 구간으로 갈린다).
    if (cf.keybindRowStart()) |start| {
        if (sel >= start and sel - start < cf.keybind_entries.len) {
            rebindActionEntry(self, cf.keybind_entries[sel - start], chord);
            return;
        }
    }
    if (cf.globalKeybindRowStart()) |gstart| {
        if (sel >= gstart and sel - gstart < cf.global_entries.len) {
            rebindGlobalEntry(self, cf.global_entries[sel - gstart], chord);
            return;
        }
    }
}

/// 단축키 힌트 배지(요소 rect + chord)를 요소 레이아웃에서 빌드해 host.collectKeyHintsDraws에 넘긴다 — 모디파이어
/// 홀드 시 각 chrome 요소 **우상단**에 그 단축키를 띄운다. 위치가 있는 요소만(요소 없는 ⌘F/⌘K/⌘A/폰트는 생략 —
/// 사용자 결정). chord는 command_catalog가 사용자 리바인드/unbind를 반영(없으면 그 요소 배지 생략). chord 문자열·배지
/// 배열은 arena 소유(rasterize까지 유효). macOS 전용. 단일 출처: docs/keybind-hints.md.
pub fn buildKeyHintBadges(self: *AppSession, props: chrome.ChromeProps, tokens: *const chrome.Tokens, arena: std.mem.Allocator, draws: *std.ArrayList(chrome.ChromeDraw)) !void {
    const Badge = chrome.components.shortcut_hints.Badge;
    const Action = config_mod.Action;
    const resolver = self.loaded_config.keyBindingResolver();
    var badges: std.ArrayList(Badge) = .empty;

    // 한 액션의 현재 chord를 표시 문자열로(arena dupe). 안 묶였으면 null(그 요소 배지 생략).
    const Local = struct {
        fn chordStr(res: anytype, action: Action, a: std.mem.Allocator) !?[]const u8 {
            const chord = command_catalog.chordForAction(res, action) orelse return null;
            var buf: [command_catalog.max_chord_display_len]u8 = undefined;
            return try a.dupe(u8, command_catalog.formatChord(chord, &buf));
        }
    };

    // 사이드바 워크스페이스 카드 → ⌘1~⌘9(select_tab). 접힘이면 카드가 없어 생략. 카드는 **검색-필터된 표시 목록**
    // (sidebar_rows) 순으로 그려지므로, 배지도 **표시 슬롯 s**(slotTop, slotAt의 역) 기준에 두고 chord는 그
    // 슬롯이 가리키는 **절대 워크스페이스 abs**의 ⌘(abs+1)을 쓴다 — 필터 활성 시 표시/절대 인덱스가 갈라지는 버그 방지.
    const sidebar = chrome.components.sidebar;
    if (!self.sidebar_collapsed and self.sidebar_width_px > 0 and self.sidebar_slot_height_px > 0) {
        const header_h: i64 = @intCast(self.sidebar_header_height_px);
        // 배지 뷰포트 하단도 상태바 위에서 끝난다 — 주석이 말하는 "render scissor와 정합"의 그 scissor가
        // 이 스택에서 상태바만큼 짧아졌으므로(같은 값), 여기만 창 바닥이면 상태바 뒤 배지를 계속 그린다.
        const vp_bottom: i64 = @intCast(self.backing_height_px -| self.statusBarHeightPx());
        // SG8d: 카드 드래그 중이면 배지도 고스트 레이아웃(preview_rows)을 따라간다 — 렌더 도메인 단일화(놓친 소비자 이주).
        const brows = sidebar_ops.sidebarRenderRows(self);
        for (brows, 0..) |row, s| {
            const abs = switch (row) {
                .card => |c| c.tab,
                .agent_toggle, .agent => continue, // 목록 행엔 ⌘숫자 배지가 없다
                .group_header, .recovered_sessions_header, .recovered_session => continue, // system/header row엔 ⌘숫자 배지가 없다
            };
            if (abs >= 9) continue; // select_tab 0..8 → ⌘1~9만 바인딩이 있다
            const cs = (try Local.chordStr(resolver, Action{ .select_tab = abs }, arena)) orelse continue;
            const y = sidebar.rowTop(brows, s, self.sidebar_header_height_px, sidebar_ops.sidebarMetrics(self), self.sidebar_scroll_offset_px);
            const row_h_badge: i64 = @intCast(chrome.components.sidebar.rowHeight(row, sidebar_ops.sidebarMetrics(self)));
            if (y + row_h_badge <= header_h or y >= vp_bottom) continue; // 헤더 위로 스크롤·뷰포트 아래로 벗어난 카드 생략(render scissor와 정합)
            try badges.append(arena, .{ .rect = .{ .x = 0, .y = @intCast(@max(y, header_h)), .w = self.sidebar_width_px, .h = @intCast(row_h_badge) }, .chord = cs });
        }
        // 새 워크스페이스 + 버튼(헤더 줄0) → ⌘⇧T(new_tab). **헤더 아이콘 render 가드(cols<13이면 아이콘 안 그림)와 같게**
        // cols>=13에서만. 배지 rect 우단을 + 글리프 우단((cols-1)*cw, headerIconCol=cols-2의 셀 우단)에 맞춰 사이드바 밖으로 안 샌다.
        const cw = @max(self.cell_width_px, 1);
        const cols = self.sidebar_width_px / cw;
        if (cols >= 13) {
            if (try Local.chordStr(resolver, Action.new_tab, arena)) |cs| {
                try badges.append(arena, .{ .rect = .{ .x = 0, .y = 0, .w = (cols - 1) * cw, .h = self.cell_height_px }, .chord = cs });
            }
        }
    }

    // 활성 pane → ⌘D(split_horizontal). 활성 pane rect 우상단.
    if (self.active_pane_rect.w > 0) {
        if (try Local.chordStr(resolver, Action.split_horizontal, arena)) |cs| {
            try badges.append(arena, .{ .rect = .{ .x = @intCast(self.active_pane_rect.x), .y = @intCast(self.active_pane_rect.y), .w = @intCast(self.active_pane_rect.w), .h = @intCast(self.active_pane_rect.h) }, .chord = cs });
        }
    }

    // 활성 pane 탭바: + 버튼(plus zone) → ⌘T(new_term), 활성 탭(seg) → ⌘W(close_focused의 workspace 경로). barMetrics(렌더·hit-test와
    // 같은 메트릭)로 위치 단일 출처 — +/탭 seg를 인라인 재계산하지 않는다.
    {
        const pane = pane_ops.activePane(self);
        if (pane_ops.paneBarForLeaf(self, pane)) |pb| {
            const cw2 = self.cell_width_px;
            if (barMetrics(pb.tabs, cw2, pane.terms.items.len, tokens.space.tab_width_cols, pane.tab_scroll_cols)) |m| {
                if (try Local.chordStr(resolver, Action.new_term, arena)) |cs| {
                    // + 글리프 col = plusZoneStart + (has_scroll? 0 : 1) (coretext buildPaneTabBarDrawList plus_start+1과 정합).
                    // 배지 rect 우단을 그 글리프 우단((plus_glyph+1)*cw)에 맞춰 ⌘T가 + 위에 오게(바 우단 패딩 아님).
                    const plus_glyph: u32 = m.plusZoneStart() + (if (m.has_scroll) @as(u32, 0) else 1);
                    if (plus_glyph < m.cols) try badges.append(arena, .{ .rect = .{ .x = @intCast(pb.tabs.x), .y = @intCast(pb.tabs.y), .w = (plus_glyph + 1) * cw2, .h = pb.tabs.h }, .chord = cs });
                }
                if (try Local.chordStr(resolver, Action.close_term, arena)) |cs| {
                    // ⌘W 배지는 **보이는** 활성 탭 세그먼트에 얹는다 — 드래그 중이면 model 인덱스와
                    // 갈려(§4.4) 배지가 활성이 아닌 탭 위에 앉는다(닫힐 탭을 잘못 알려 준다).
                    const seg = m.segOf(pane_ops.paneActiveTermIndex(self, pane));
                    if (seg.end_col > seg.start_col) try badges.append(arena, .{ .rect = .{ .x = @intCast(pb.tabs.x + seg.start_col * cw2), .y = @intCast(pb.tabs.y), .w = (seg.end_col - seg.start_col) * cw2, .h = pb.tabs.h }, .chord = cs });
                }
            }
        }
    }

    try self.chrome_host.collectKeyHintsDraws(badges.items, props, tokens, arena, draws);
}

// --- `app_session.zig`에서 함께 옮겨 온 파일 레벨 헬퍼 ---
// 이 그룹만 쓰고 허브 제품 경로는 쓰지 않는다(실측). 허브에 두면 그 pub 표면만 넓힌다.

// IME 순수 판정도 session core로 추출(src/session/ime.zig). bare 호출(imeEnd) 유지용 alias.
pub const imeDecide = maru.session.ime.decide;

// --- 익명 struct 반환에 이름을 준 뒤 옮겨 온 함수 ---
// 반환 타입이 `?struct { ... }`이던 동안은 허브 facade가 만든 타입과 이 파일이 만든 타입이 서로
// 다른 타입이 되어 옮길 수 없었다. `AppSession`에 이름 있는 타입을 두어 해결했다.

/// IME 후보창 배치용 커서 셀 사각형(backing px, 좌상단 원점 — 마우스 좌표와 같은 규약).
/// 입력기가 firstRect로 물어보면 Swift가 이 값을 화면 좌표로 바꿔 후보창을 커서 위치에
/// 띄운다. 조합 중에는 canonical base snapshot의 cursor가 preedit 시작 anchor라 후보창이 그 위치에 뜬다.
/// 반환: row*cell_h, col*cell_w, cell_w, cell_h.
// self는 *AppSession(비-const) — rename caret 위치(renameCaretRect)가 leaf-rects 레이아웃을 펴는 *AppSession
// 헬퍼를 거치기 때문(읽기 전용 계산이지만 activeTabLeafRects 체인이 비-const). ABI·테스트 호출자는 모두 mutable.
pub fn imeCursorRect(self: *AppSession) ImeCursorRect {
    const cw: f64 = @floatFromInt(if (self.cell_width_px > 0) self.cell_width_px else placeholder_cell_width_px);
    const ch: f64 = @floatFromInt(if (self.cell_height_px > 0) self.cell_height_px else placeholder_cell_height_px);
    if (!self.surface_initialized) return .{ .x = 0, .y = 0, .w = cw, .h = ch };
    // 활성 입력 대상(inputFocus 단일 출처)의 입력 caret 옆에 후보창을 띄운다 — caretRect가 위치 단일 출처.
    // null(패널 밖)이거나 터미널이면 아래 터미널 커서로 폴백.
    const props = self.buildChromeProps();
    const focus: InputFocus = if (self.ime_terminal_target_id != null) .terminal else self.inputFocus();
    const overlay_caret: ?chrome.draw.Rect = switch (focus) {
        .confirm, .notice, .file_tree, .dock_pending => null, // 조합을 안 받으므로 후보창 위치 무의미.
        // rename 인라인 편집기의 caret(사이드바 슬롯/탭/라벨)에 후보창을 띄운다 — renameCaretRect가 대상별 위치를
        // 잡는다(사이드바 y는 slot 기준 근사). null이면 아래 터미널 커서로 폴백.
        .rename => settings_ops.renameCaretRect(self),
        // 세팅 검색줄 caret — buildChromeOverlayPrep이 캐시한 rect(검색 중이 아니면 null → 터미널 커서 폴백).
        .settings => self.settings_search_caret,
        .sidebar_search => sidebar_ops.sidebarSearchCaretRect(self),
        .agent_session_search => agent_dock.agentSessionDockSearchCaretRect(self),
        .find => chrome.components.find.caretRect(&self.chrome_host.find, props),
        .palette => chrome.components.palette.caretRect(&self.chrome_host.palette, props),
        // 주소창 편집 caret은 밴드가 자체 block caret으로 그린다 — 후보창을 그 caret 셀 옆에 띄운다(addrEditCaretRect가
        // 렌더 "1c"와 같은 밴드·nav_end·편집폭 셈법으로 위치 단일 소스). null이면(밴드 못 찾음) 아래 폴백. web term 활성 중
        // (activeTermIsTerminal=false) 본문 origin 폴백은 caret과 어긋나므로 이 rect가 필요하다(리뷰 [4]).
        .addr_edit => web_ops.addrEditCaretRect(self),
        // 커밋 상자 caret — 후보창을 그 자리에 띄운다. null이면(상자가 아직 안 그려짐) 터미널 커서 폴백.
        .scm_commit => scm_dock_ops.commitCaretRect(self),
        .terminal => null,
    };
    if (overlay_caret) |r| {
        return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
    }
    // [4e-2, §6·1-B] 활성 Term이 web이면 터미널 커서(sentinel)가 없다 — 본문 origin 폴백 rect를 준다(WebKit이 웹
    // 포커스 IME 후보창 위치를 자체 관리, 4d). web Term 없으면 이 분기 미진입(byte-identical).
    // **편집기 Term은 문서 caret 아래에 둔다**(N3). 아래 폴백은 pane **좌상단**이라, 조합 글자가
    // 문서 한가운데 있는데 후보창은 구석에 뜬다 — 한글은 후보창을 보며 고르는 입력이라 그 어긋남이
    // 곧바로 걸린다.
    if (activeEditorTermForIme(self)) |editor_term| {
        if (editor_ops.editorImeCaretRect(self, editor_term)) |r| {
            return .{ .x = @floatFromInt(r.x), .y = @floatFromInt(r.y), .w = @floatFromInt(r.w), .h = @floatFromInt(r.h) };
        }
    }
    if (!term_ops.activeTermIsTerminal(self)) {
        return .{ .x = @floatFromInt(self.active_pane_rect.x), .y = @floatFromInt(self.active_pane_rect.y), .w = cw, .h = ch };
    }
    // [P4-3, §12] 터미널 커서 위치를 **활성 surface 코어에서 lockCore 아래** 읽는다 — 예전 무락 직접
    // (core.screen.cursor) 읽기는 리더 write와 torn read 잠재 race였다(값 struct라 크래시는 아니나 한 프레임 잘못된
    // 위치 가능). imeCursorRect는 IME 후보창 질의 시에만(조합 중) 불리는 event-driven 경로라 per-tick 아님 — 여기 lock은
    // 경합/비용 무관하고, **같은 활성 surface**에서 origin(active_pane_rect)과 커서를 함께 잡아 팬 전환 시점 차도 없다
    // (스냅샷 캐시는 active_pane_rect가 동기 갱신인데 캐시는 per-tick이라 전환 한 프레임 오위치를 냈다 — code-review [2]).
    const cursor = blk: {
        const s = if (self.ime_terminal_target_id) |target_id| input_ops.imeTerminalSurfaceById(self, target_id) orelse {
            // 사라진 pin을 새 active cursor로 위장하지 않는다. 후보창은 neutral pane origin에 둔다.
            return .{
                .x = @floatFromInt(self.active_pane_rect.x),
                .y = @floatFromInt(self.active_pane_rect.y),
                .w = cw,
                .h = ch,
            };
        } else term_ops.activeSurface(self);
        s.lockCore(self.io);
        defer s.unlockCore(self.io);
        break :blk s.baseCursorLocked() orelse {
            // capability를 협상하지 않은 구 live host의 cursor는 viewport 의미를 판정할 수
            // 없다. hidden origin을 실제 anchor로 위장하지 않고 pane origin으로 fail-closed한다.
            return .{
                .x = @floatFromInt(self.active_pane_rect.x),
                .y = @floatFromInt(self.active_pane_rect.y),
                .w = cw,
                .h = ch,
            };
        };
    };
    const cur_row = cursor.row;
    const cur_col = cursor.col;
    return .{
        // 활성 panel은 자기 rect origin(active_pane_rect.x/y)에서 그려지므로 커서의 스크린 좌표도 그 origin을
        // 더해야 한다 — 안 더하면 후보창이 실제 커서보다 origin만큼 왼쪽/위에 뜬다(pxToCell의 역변환:
        // pxToCell은 빼고, 셀→스크린인 여기선 더한다). 단일 panel이면 origin = (사이드바 폭+padding_x, padding_y).
        .x = @as(f64, @floatFromInt(self.active_pane_rect.x)) + @as(f64, @floatFromInt(cur_col)) * cw,
        .y = @as(f64, @floatFromInt(self.active_pane_rect.y)) + @as(f64, @floatFromInt(cur_row)) * ch,
        .w = cw,
        .h = ch,
    };
}
