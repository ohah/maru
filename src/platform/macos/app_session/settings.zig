//! 세팅·컨텍스트 메뉴·이름 변경·config 적용 — 세팅 UI의 필드/섹션/드롭다운, 컨텍스트 메뉴 구성과
//! 수락, 인라인 이름 변경, 그리고 바뀐 config를 실행 중인 터미널·외형에 다시 먹이는 경로.
//!
//! `app_session.zig`에서 목적별로 떼어낸 그룹이다(docs/app-session-decomposition.md §4.1 F9).
//!
//! config 재적용(`applyLoadedConfig`·`reapplyConfigPalette`·`reapplyScrollback`·`reapplyAmbiguousWidth`·
//! `reapplyEmojiWidth`·`reapplyDefaultCursorShape`·`applyThemePreset`)을 함께 가진다 — 세팅 UI가 값을
//! 바꾸고 이 경로가 그것을 살아 있는 세션에 반영하므로 한 덩어리다. F8이 `reapplyScrollback`을 여기로
//! 미뤄 둔 것도 같은 이유다(이름은 scroll이지만 하는 일은 config 재적용이다).
//!
//! 이름 함정을 넷 걸렀다.
//!   - `maybeDebugOpenSettings`(568줄): 이름은 settings지만 본문은 `MARU_*` 환경변수 게이트 39개로
//!     사이드바 접힘·가짜 브랜치·그룹 상태·드래그 고스트를 강제하는 **디버그 픽스처 하네스**다.
//!     세팅 로직이 아니다 — 별도 후속으로 등록했다(§4.1).
//!   - `togglePin`·`cardPinRole`: 컨텍스트 메뉴가 부르지만 본문은 `self.tabs`의 고정 구획을 수술한다.
//!     소유는 tab이다(F6 보정과 같은 계열).
//!   - `webSurfaceRect`: `web_panel_prev`를 읽는 web-panel 기하다.
//!   - `termBarLocation`: 터미널 바 위치 질의로 chrome/pane 기하다. rename caret이 유일한 호출자일 뿐이다.
//!
//! 여기서 말하는 palette는 **색 팔레트**(`theme.palette`)다 — 명령 팔레트(⌘K)와 다른 도메인이라
//! `reapplyConfigPalette`·`paletteCellHex`만 가져오고 `togglePalette`·`acceptPalette`는 두고 왔다.

const std = @import("std");
const builtin = @import("builtin");
const maru = @import("maru");

const chrome = maru.chrome;
const terminal = maru.terminal;
const app_session_mod = @import("../app_session.zig");
const AppSession = app_session_mod.AppSession;
const setShellArgs = AppSession.setShellArgs;
const macroRhsString = AppSession.macroRhsString;
const isExecutablePath = app_session_mod.isExecutablePath;
const SettingsSectionEntry = AppSession.SettingsSectionEntry;
const SettingsSectionFields = AppSession.SettingsSectionFields;
const resolverUnbinds = AppSession.resolverUnbinds;
const workspace_ops = @import("workspace.zig");
const term_ops = @import("term.zig");
const editor_ops = @import("editor.zig");
const git_ops = @import("git.zig");
const agent_ops = @import("agent.zig");
const find_ops = @import("find.zig"); // 검색 매치 목록 둘을 함께 비운다(clearAllFindMatches)
const input_ops = @import("input.zig");
const web_ops = @import("web.zig");
const ctx_group_menu_color_first = app_session_mod.ctx_group_menu_color_first;
const ctx_group_menu_ungroup = app_session_mod.ctx_group_menu_ungroup;
const ctx_group_menu_pin = app_session_mod.ctx_group_menu_pin;
const ctx_menu_group_color_first = app_session_mod.ctx_menu_group_color_first;
const ctx_menu_accent_first = app_session_mod.ctx_menu_accent_first;
const tab_color_presets = app_session_mod.tab_color_presets;
const ctx_menu_bg_first = app_session_mod.ctx_menu_bg_first;
const ctx_menu_group_promote = app_session_mod.ctx_menu_group_promote;
const ctx_menu_group_remove = app_session_mod.ctx_menu_group_remove;
const ctx_menu_group_ungroup = app_session_mod.ctx_menu_group_ungroup;
const ctx_menu_group_sibling = app_session_mod.ctx_menu_group_sibling;
const ctx_menu_group_create = app_session_mod.ctx_menu_group_create;
const ctx_menu_pin = app_session_mod.ctx_menu_pin;
const barMetrics = app_session_mod.barMetrics;
const file_tree = app_session_mod.file_tree;
const layout_math = app_session_mod.layout_math;
const tab_group_color_labels = app_session_mod.tab_group_color_labels;
const ClipboardAction = app_session_mod.ClipboardAction;
const FileContentMenu = AppSession.FileContentMenu;
const PaneTree = app_session_mod.PaneTree;
const font_size_max = app_session_mod.font_size_max;
const pane_ops = @import("pane.zig");
const tab_accent_labels = app_session_mod.tab_accent_labels;
const content_menu = app_session_mod.content_menu;
const detectThemePreset = AppSession.detectThemePreset;
const dock_ops = @import("dock.zig");
const scm_dock_ops = @import("scm_dock.zig"); // 도크 `∨` 메뉴 선택 적용(P6b)
const fontDirectInputLabel = AppSession.fontDirectInputLabel;
const font_size_min = app_session_mod.font_size_min;
const setAppKeepAlivePolicy = app_session_mod.setAppKeepAlivePolicy;
const replaceAppKeepAlivePolicyFromReload = app_session_mod.replaceAppKeepAlivePolicyFromReload;
const appKeepAliveResetPlan = app_session_mod.appKeepAliveResetPlan;
const commitAppKeepAliveReset = app_session_mod.commitAppKeepAliveReset;
const appKeepAliveSnapshot = app_session_mod.appKeepAliveSnapshot;
const sidebar_ops = @import("sidebar.zig");
const tab_bg_labels = app_session_mod.tab_bg_labels;
const FileMenuAction = AppSession.FileMenuAction;
const KeyHintConfigAbi = AppSession.KeyHintConfigAbi;
const QuickTerminalConfig = app_session_mod.QuickTerminalConfig;
const RenameTarget = app_session_mod.RenameTarget;
const SettingsDefaults = AppSession.SettingsDefaults;
const chromeInputFromKeyEvent = @import("input.zig").chromeInputFromKeyEvent;
const command_catalog = app_session_mod.command_catalog;
const config_mod = app_session_mod.config_mod;
const file_panel_ops = @import("file_panel.zig");
const git_backend_mod = app_session_mod.git_backend_mod;
const git_command = app_session_mod.git_command;
const pending_writeback_lists = AppSession.pending_writeback_lists;
const rgbToHex = AppSession.rgbToHex;
const tab_ops = @import("tab.zig");
const workspaceHasStatusLine = @import("workspace.zig").workspaceHasStatusLine;

/// rename 편집 표시 텍스트 "query+조합중preedit" + caret 1칸. caret은 `blink_visible`이면 '|', 아니면 공백 —
/// **폭은 항상 +1로 고정**(renameDisplayWidth와 일치)이라 깜빡여도 텍스트/세그먼트 폭이 안 흔들린다. 토글은
/// updateCursorBlink가 rename 중 metal_dirty로 rebuild를 일으켜 보인다(터미널 커서 suffix-trim과 달리 인라인
/// caret은 셀 스트림의 글자라 full rebuild 필요 — text-blink와 같은 경로). 호출자(allocator) 소유.
pub fn renameEditText(self: *AppSession, allocator: std.mem.Allocator) ![]const u8 {
    const caret: []const u8 = if (self.blink_visible) "|" else " ";
    return std.fmt.allocPrint(allocator, "{s}{s}{s}", .{ self.rename_input.query.items, self.rename_input.preedit.items, caret });
}

/// rename 편집 텍스트(query)의 표시 칸 수 — **방출자와 같은 단위**여야 한다.
///
/// rename 편집기는 `appendEllipsizedTitle`이 그린다(사이드바 카드 이름줄·파일 트리 행·pane 탭·라벨). 그 방출은
/// CG1 이후 **grapheme cluster 하나 = 셀 하나**인데, 여기서 `overlay_input.displayCols`(코드포인트당
/// Σ max(1,cellWidth))를 쓰면 NFD 이름에서 두 모델이 갈라진다 — macOS FS가 주는 '한'(U+1112 U+1161 U+11AB)이
/// 렌더는 2칸인데 displayCols는 4칸으로 세, caret과 IME 후보창이 글자에서 ~2배 오른쪽으로 떠 버린다
/// (code-review max). 그래서 방출과 같은 폭 함수(`chrome.text_layout.displayCols`)를 단일 출처로 쓴다.
///
/// `overlay_input.displayCols`는 폐기 대상이 아니다 — find·palette·context menu·모달은 `placeText`(오버레이
/// raster)가 **코드포인트 단위로** 그리므로 그쪽 폭 모델과 짝이 맞다. 두 폭 함수는 각자의 방출자를 따라간다.
pub fn renameQueryCols(self: *const AppSession) u32 {
    return @intCast(chrome.text_layout.displayCols(self.rename_input.query.items, null));
}

/// rename 편집 caret의 셀 rect(backing px, 좌상단 원점) — IME 후보창 위치(imeCursorRect)에 쓴다. 대상별 편집기
/// 텍스트 origin + caret 컬럼(prefix + query 폭)을 잡는다. preedit는 안 더한다(조합 글자는 query 끝 caret에 겹쳐
/// 그려짐 — 단일 줄 append라 뒤 텍스트 없음, find.caretRect와 동일). 사이드바 슬롯 y는 slot_height 기준 세로 중앙 근사(후보창은 근처면 충분). 못
/// 구하면 null(터미널 커서로 폴백). 렌더 geometry(paneBar·barMetrics·segOf, 사이드바 indent/slot)와 같은 셈법.
pub fn renameCaretRect(self: *AppSession) ?chrome.draw.Rect {
    const target = self.rename orelse return null;
    const cw = self.cell_width_px;
    const ch = self.cell_height_px;
    if (cw == 0 or ch == 0) return null;
    const qcols: u32 = renameQueryCols(self); // 방출자(appendEllipsizedTitle)와 같은 cluster 단위
    switch (target) {
        .workspace => |tab| {
            const idx = for (self.tabs.items, 0..) |t, i| {
                if (t == tab) break i;
            } else return null;
            // 사이드바 이름줄(line 0) 좌단 indent(buildSidebarTitleFrame와 같은 ceil(card_gap+accent_bar)/cw).
            // 번호 prefix는 제거됐으므로(이름줄에 번호 없음) caret = indent + query 폭.
            const sp = self.buildChromeTokens().space;
            const indent_cols: u32 = (sp.card_gap_px + sp.accent_bar_width_px + cw - 1) / cw;
            // 이름줄이 사이드바 폭을 넘치면 렌더(buildSidebarDrawList editing_row)가 tail 앵커로 caret을 이름영역 **우경계**에
            // 두므로, caret_col도 거기로 clamp해야 IME 후보창이 잘린 caret 아래(사이드바 안)에 온다 — 안 그러면 head-anchored
            // 열이 사이드바 밖 터미널 위로 떠 조합창이 caret과 분리된다(.pane/.term의 세그먼트 우경계 clamp와 같은 규율).
            const full_cols: u32 = self.sidebar_width_px / cw;
            const caret_col = @min(indent_cols + qcols, full_cols -| 2);
            // 리네임 카드 줄 수: 이름줄(항상) + 상태줄(running·idle 에이전트면). 리네임 중 branch/path 보조줄은
            // buildSidebarTitleDrawList가 항상 숨겨 줄 수에 안 든다. 렌더러(maru_metal_renderer.m)가 n줄 블록을 슬롯
            // 세로 중앙 정렬하므로, 상태줄이 생기면 이름줄이 위로 (ch/2) 올라간다 — caret y도 같은 n을 써야 IME
            // 후보창이 이름 caret 아래에 오고 파형 상태줄과 안 겹친다(buildSidebarDrawList의 line_count 인코딩과 동형).
            // rename 중 카드 줄 수 = 이름줄 + **상태줄**(있으면). 보조줄(브랜치·경로)만 편집 중 숨긴다.
            // 렌더(buildSidebarTitleDrawList의 rename 분기)가 workspaceStatusLine을 여전히 append하므로 여기서
            // 1로 고정하면 caret이 반 줄 아래로 밀려 IME 후보창이 상태줄을 덮는다(code-review max — 원래 있던
            // 계산을 되돌린다).
            const line_count: u32 = if (workspaceHasStatusLine(tab)) 2 else 1;
            // 카드 이름줄(line 0)의 view 절대 y — Swift firstRect가 backing px 좌상단 원점을 view 좌표로 변환만
            // 하므로(사이드바 origin 보정 없음), 렌더러(maru_metal_renderer.m: slot_idx*slot_h + header − scroll +
            // 블록중앙)와 같은 절대 y를 줘야 한다. 예전엔 idx*slot_h만 써서 헤더 높이만큼 위·스크롤만큼 아래로
            // 어긋났다(검색 caret sidebarSearchCaretRect가 search_row*ch로 헤더 영역 절대 y를 쓰는 것과 같은 규약).
            // slotTop이 header 더하고 scroll 뺀 슬롯 상단(단일 출처, i64), 거기에 n줄 블록 세로 중앙 오프셋을 더한다.
            // 헤더 위로 스크롤돼 음수면 헤더 아래로 clamp — IME 후보창이 고정 검색 헤더 위로 뜨지 않게(scissor가 편집
            // 텍스트를 헤더에서 자르는 것과 짝, slotAt이 헤더 영역을 슬롯에서 제외하는 것과 일관).
            // 옛 버그(조사 확인): idx는 원본 탭 인덱스인데 slotTop에 슬롯으로 넣어 검색 필터 활성 시 표시 슬롯과
            // 어긋났다. displaySlotOf로 원본 탭→표시 row로 바꿔 교정하고, 가변 높이 rowTop을 쓴다. 필터로 숨었으면
            // (rename 중엔 드묾) null → 터미널 커서 폴백.
            // SG8d: 카드 드래그 프리뷰 중이면 렌더가 preview_rows를 쓰므로 caret도 그 도메인에서 이 탭 카드의 표시 row를
            // 찾아 rowTop을 잰다(rename↔카드 드래그는 사실상 배타지만, 공존해도 caret이 그려진 카드와 어긋나지 않게).
            // 비드래그면 sidebarRenderRows()==sidebar_rows라 displaySlotOf와 동일 결과(회귀 없음).
            const rrows = sidebar_ops.sidebarRenderRows(self);
            const slot_row = blk_sr: {
                for (rrows, 0..) |r, s| switch (r) {
                    .card => |c| if (c.tab == idx) break :blk_sr s,
                    .agent_toggle, .agent => {},
                    .group_header, .recovered_sessions_header, .recovered_session => {},
                };
                break :blk_sr (self.displaySlotOf(idx) orelse return null);
            };
            const slot_top = chrome.components.sidebar.rowTop(rrows, slot_row, self.sidebar_header_height_px, sidebar_ops.sidebarMetrics(self), self.sidebar_scroll_offset_px);
            // 블록중앙은 **그 row의 실제 높이**로 잡는다 — 카드 높이가 줄 수 가변이라 옛 고정 슬롯을 쓰면
            // 리네임 caret이 카드 밖으로 밀린다(fillSidebarGlyphPyTop과 같은 계산을 공유). 이름줄=line 0이라 +block_off만.
            const row_h_caret = chrome.components.sidebar.rowHeight(rrows[slot_row], sidebar_ops.sidebarMetrics(self));
            const block_off: i64 = @intCast((row_h_caret -| sidebar_ops.sidebarBlockHeight(line_count, ch)) / 2);
            const caret_y = @max(slot_top + block_off, @as(i64, self.sidebar_header_height_px));
            return .{
                .x = @intCast(caret_col * cw),
                .y = @intCast(caret_y),
                .w = @intCast(cw),
                .h = @intCast(ch),
            };
        },
        .pane => |pane| {
            const pb = pane_ops.paneBarForLeaf(self, pane) orelse return null;
            // buildPaneLabelDrawList: 이름이 col 1부터(좌패딩 1). 긴 이름은 말줄임되므로 caret을 라벨 세그먼트
            // 우경계(label_cols-1, 마지막 칸은 탭과의 간격)로 clamp해 후보창이 라벨 밖(탭 위)으로 새지 않게.
            const caret_col = @min(1 + qcols, if (pb.label_cols > 1) pb.label_cols - 1 else 1);
            const text_offset_y = self.chromeBarTextOffsetY(pb.full.h); // 렌더 text_origin_y와 같은 식
            return .{
                .x = @intCast(pb.full.x + (pb.grip_cols + caret_col) * cw), // 이름은 grip 핸들 뒤에서 시작
                .y = @intCast(pb.full.y + text_offset_y),
                .w = @intCast(cw),
                .h = @intCast(ch),
            };
        },
        .term => |term| {
            const loc = term_ops.termBarLocation(self, term) orelse return null;
            const m = barMetrics(loc.pb.tabs, cw, loc.count, self.buildChromeTokens().space.tab_width_cols, loc.scroll) orelse return null;
            const seg = m.segOf(loc.tab_index);
            // 탭 텍스트: 세그먼트 start_col + 1(좌패딩) 뒤(번호 prefix 제거 — U-tab2). **그 탭 세그먼트 우경계(seg.end_col)**로
            // clamp해 caret/후보창이 인접 탭 위로 새지 않게 한다(end_col<=start_col인 overflow 탭이면 m.cols 폴백).
            const seg_end = if (seg.end_col > seg.start_col) seg.end_col else m.cols;
            const caret_col = @min(seg.start_col + 1 + qcols, seg_end);
            const text_offset_y = self.chromeBarTextOffsetY(loc.pb.tabs.h); // 렌더 text_origin_y와 같은 식
            return .{
                .x = @intCast(loc.pb.tabs.x + caret_col * cw),
                .y = @intCast(loc.pb.tabs.y + text_offset_y),
                .w = @intCast(cw),
                .h = @intCast(ch),
            };
        },
        .group => |gtab| {
            // 그룹 헤더 rename caret — 헤더 텍스트 "{삼각} {편집}"에서 삼각(1칸)+공백(1칸) 뒤가 편집 시작이라 col=2+qcols.
            // 헤더 표시 row를 찾아(group_header.tab == 대상 인덱스) rowTop + 헤더 1줄 세로 중앙에 caret y를 둔다.
            const idx = for (self.tabs.items, 0..) |t, i| {
                if (t == gtab) break i;
            } else return null;
            var slot_row: ?usize = null;
            var hdr_depth: u8 = 1;
            // SG8d: 렌더 도메인(카드 드래그 중=preview_rows)에서 헤더 표시 row를 찾아 caret을 그려진 헤더와 정합시킨다.
            const rrows = sidebar_ops.sidebarRenderRows(self);
            for (rrows, 0..) |row, s| switch (row) {
                .group_header => |gh| if (gh.tab == idx) {
                    slot_row = s;
                    hdr_depth = gh.depth;
                    break;
                },
                .agent_toggle, .agent, .recovered_sessions_header, .recovered_session => {},
                .card => {},
            };
            const sr = slot_row orelse return null;
            // buildSidebarTitleDrawList는 모든 사이드바 glyph(헤더 삼각/이름 포함)를 indent_cols(=ceil((card_gap+
            // accent_bar)/cw))만큼 우측으로 민다(13936). .workspace caret(2053)이 그 항을 더하듯 헤더 caret도 더해야
            // 삼각/이름과 정렬된다 — 옛 코드는 이 항이 없어 캐럿·IME 후보창이 indent_cols만큼 왼쪽으로 어긋났다(code-review #5).
            const sp = self.buildChromeTokens().space;
            const indent_cols: u32 = (sp.card_gap_px + sp.accent_bar_width_px + cw - 1) / cw;
            // 중첩 헤더(SG5-3)는 (depth-1)*group_indent 만큼 더 들여써 있으므로 caret도 그만큼 우측으로. 최상위(depth 1)=0이라
            // 비중첩 caret은 그대로. group_indent_cols = ceil(group_indent_px / cw)(buildSidebarTitleDrawList와 단일 출처).
            const gindent_px = sp.group_indent_px;
            const gindent_cols: u32 = if (gindent_px > 0) (@as(u32, gindent_px) + cw - 1) / cw else 0;
            const hindent_cols: u32 = (if (hdr_depth > 0) hdr_depth - 1 else 0) * gindent_cols;
            // head 위치 = 사이드바 indent + 중첩 들여쓰기 + 삼각 + 공백 + 편집 폭. 헤더 이름이 사이드바 폭을 넘치면
            // 렌더가 tail 앵커(editing_row)로 caret을 이름영역 우경계에 두므로, 여기도 full_cols-2로 clamp해 IME 후보창이
            // 사이드바 밖 터미널 위로 안 뜨게 한다(.workspace와 같은 규율 + main #5의 indent_cols 항 보존).
            const full_cols: u32 = self.sidebar_width_px / cw;
            const caret_col: u32 = @min(indent_cols + hindent_cols + 2 + qcols, full_cols -| 2);
            const slot_top = chrome.components.sidebar.rowTop(rrows, sr, self.sidebar_header_height_px, sidebar_ops.sidebarMetrics(self), self.sidebar_scroll_offset_px);
            const block_off: i64 = @intCast((self.sidebar_header_row_h_px -| ch) / 2); // 헤더 1줄 세로 중앙
            const caret_y = @max(slot_top + block_off, @as(i64, self.sidebar_header_height_px));
            return .{ .x = @intCast(caret_col * cw), .y = @intCast(caret_y), .w = @intCast(cw), .h = @intCast(ch) };
        },
        .file_tree => |edit| {
            const index = file_tree.findIdentity(self.file_tree_rows.items, .{ .kind = edit.row_kind, .path = edit.path() }) orelse
                file_panel_ops.selectedFileTreeRow(self) orelse return null;
            const dg = dock_ops.dockGeometry(self);
            // 픽셀 스크롤이라 행의 y는 content 좌표에서 offset을 뺀 값이다. 위·아래로 완전히 벗어난
            // 행에는 caret을 두지 않는다 — 부분적으로 걸친 행은 pane clip이 자르므로 그대로 둔다.
            const row_top: i64 = @as(i64, @intCast(index)) * @as(i64, ch) - @as(i64, file_panel_ops.fileTreeEffectiveScrollPx(self));
            if (row_top + @as(i64, ch) <= 0 or row_top >= @as(i64, dg.tree_content.h)) return null;
            const depth = file_tree.rowDepth(self.file_tree_rows.items[index]) orelse 0;
            const start_col: u32 = @min(@as(u32, 4) + @as(u32, depth) * 2, dg.tree_content.w / cw -| 1);
            const max_col = dg.tree_content.w / cw -| 1;
            return .{
                .x = @intCast(dg.tree_content.x + @min(start_col + qcols, max_col) * cw),
                .y = @intCast(@as(i64, dg.tree_content.y) + row_top),
                .w = @intCast(cw),
                .h = @intCast(ch),
            };
        },
    }
}

/// 세팅 화면(⌘,)을 토글한다 — 열려 있으면 닫고, 아니면 다른 오버레이를 닫고 연다(배타적, palette/find와 같은 규율).
/// 열 때 bool 스키마 필드 수를 컴포넌트에 주입해(setFieldCount) 키 라우팅(↑↓ wrap·Space/Enter 토글 가드)이 동작하게 한다.
pub fn toggleSettings(self: *AppSession) void {
    if (self.chrome_host.settings.open) {
        self.chrome_host.settings.hide();
    } else {
        self.chrome_host.notice.dismiss(); // 배타적
        self.chrome_host.find.hide();
        self.chrome_host.palette.hide();
        find_ops.clearAllFindMatches(self); // 목록은 둘이다 — 한쪽만 비우면 편집기 강조가 남는다
        self.chrome_host.settings.show();
        self.chrome_host.settings.section = 0; // 항상 첫 섹션부터(네비 — config-gui §4)
        refreshSettingsFieldCount(self);
    }
}

/// 현재 섹션의 필드 수를 컴포넌트에 주입한다(setFieldCount — ↑↓ wrap·Space/Enter 가드). 섹션 전환/열기 때 호출.
/// scratch arena로 빌드(핸들러와 같은 currentSectionFields 단일 출처).
pub fn refreshSettingsFieldCount(self: *AppSession) void {
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    // 네비 키보드 ↓는 섹션 수를 모르는 컴포넌트가 section을 +1만 하므로(상한 미지), 여기서 실제 섹션 수로 clamp한다.
    // 안 하면 section이 범위를 넘어 계속 커져 ↑가 한참 먹지 않는다(currentSectionFields는 min clamp로 보기만 보정).
    // 네비 맨 아래에 "↺ 초기화" 액션 행(§6.4)이 실제 섹션들 뒤에 하나 더 있으므로 상한은 sections.len(=리셋 행 인덱스)까지
    // 허용한다 — nav_reset_row로 그 인덱스를 컴포넌트에 알려 Enter/클릭이 폼 진입 대신 .reset_all을 내게 한다.
    if (buildSectionList(self, scratch.allocator())) |sections| {
        self.chrome_host.settings.nav_reset_row = sections.len;
        if (self.chrome_host.settings.section > sections.len)
            self.chrome_host.settings.section = sections.len;
    } else |_| {
        self.chrome_host.settings.nav_reset_row = null;
    }
    const cf = currentSectionFields(self, scratch.allocator()) catch return;
    self.chrome_host.settings.setFieldCount(cf.total());
}

/// 세팅 검색 매칭 — 쿼리가 비었으면 항상 true, 아니면 **모든 언어의** 문서 문장 또는 키에 부분일치
/// (ASCII 대소문자 무시; 한글은 대소문자가 없어 그대로 부분일치). 필터의 단일 출처 —
/// `currentSectionFields` 가 모든 행 종류에 같은 규칙을 적용한다.
///
/// **판정이 현재 언어를 안 본다는 것이 이 함수의 계약이다.** 예전에는 현재 언어로 푼 문자열 하나만 봤고,
/// 그래서 통과 행 집합과 순서가 언어를 탔다 — `selected` 는 인덱스일 뿐이라 언어가 바뀌는 순간 다른 설정을
/// 가리키게 되고, 확정이 **사용자가 열지도 않은 키**에 값을 썼다. 실측(쿼리 4186개, 전 섹션, 순서 포함
/// 비교)으로 **1499개(35.8%)** 가 두 언어에서 서로 다른 나열을 냈다. 전환 지점마다 선택을 다시 앉히는 방식으로도 막아 봤지만, 다른 창이 언어를 바꾼
/// 경우처럼 **이 창이 아무 코드도 안 도는 경로**가 남았다(i18n 계약 §5.2). 판정에서 언어를 빼면 그 경로가
/// 통째로 사라진다 — 흔들릴 것이 없으므로 붙잡을 것도 없다.
///
/// 대가는 **화면에 안 보이는 문장으로 행이 통과하는 것**이다(영어 UI 에서 `폰트` 로 걸러도 그 행이 남는다).
/// 그 성질 자체는 새롭지 않다 — 키 매칭이 이미 그랬다. 실측으로 통과 행이 **+15.8%** 늘고, 그 증가는
/// 한국어 화면에 몰린다(en +8.2% / ko +24.5% — 한국어 화면이 이제 영어 문장으로도 걸리기 때문이다).
/// 짧은 쿼리라고 특별히 더 늘지는 않는다(≤3자 +15.7%로 전체와 같다).
/// 그것을 감수하는 이유는, "결과가 조금 많다" 와 "선택이 조용히 다른 키로 미끄러진다" 가 같은 무게가 아니기
/// 때문이다. 부수 효과로 **영어 이름으로도 찾을 수 있다**(한국어 화면에서 `language` 로 `ui.language` 를).
pub fn settingsRowMatches(doc_key: ?maru.i18n.Key, label: []const u8, key: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    if (std.ascii.indexOfIgnoreCase(key, query) != null) return true;
    // 키가 있으면 **모든 언어**를 본다. 없으면(환경변수 이름·chord 표기처럼 번역 대상이 아닌 라벨) 그 라벨
    // 하나만 보는데, 그런 라벨은 애초에 언어를 안 타므로 판정도 언어 독립이다.
    if (doc_key) |dk| {
        inline for (@typeInfo(maru.i18n.Lang).@"enum".fields) |lf| {
            const sentence = maru.i18n.tIn(@field(maru.i18n.Lang, lf.name), dk);
            if (std.ascii.indexOfIgnoreCase(sentence, query) != null) return true;
        }
        return false;
    }
    return std.ascii.indexOfIgnoreCase(label, query) != null;
}

/// 언어 드롭다운의 표시 목록. **`Preference` 선언 순서 그대로** 만든다 — 팝업 선택은 인덱스로
/// 적용되므로(`enumIndex`·`dropdown.show(len, cur_idx)`) 이 순서가 스키마의 변형 순서와 어긋나면
/// **다른 언어가 저장된다.** enum 을 한 바퀴 도는 것이 그 어긋남을 정의상 불가능하게 만든다.
fn uiLanguageVariants(arena: std.mem.Allocator) ![]const []const u8 {
    const fields = @typeInfo(maru.i18n.Preference).@"enum".fields;
    const out = try arena.alloc([]const u8, fields.len);
    inline for (fields, 0..) |f, i| out[i] = maru.i18n.preferenceLabel(@field(maru.i18n.Preference, f.name));
    return out;
}

/// 섹션 표시 라벨. null=스키마 섹션 미지정 그룹("기타"). 표시 문자열은 `i18n` 이 소유하므로
/// **현재 UI 언어를 따른다** — 예전에는 여기서 한국어 리터럴을 직접 돌려줬다.
pub fn settingsSectionLabel(sec: ?config_mod.Section) []const u8 {
    const s = sec orelse return maru.i18n.t(.set_section_other);
    return maru.i18n.t(switch (s) {
        .app => .set_section_app,
        .font => .set_section_font,
        .theme => .set_section_theme,
        .cursor => .set_section_cursor,
        .window => .set_section_window,
        .input => .set_section_input,
        .terminal => .set_section_terminal,
        .workspace => .set_section_workspace,
        .quick_terminal => .set_section_quick_terminal,
        .sidebar => .set_section_sidebar,
        .global_hotkey => .set_section_global_hotkey,
        .editor => .set_section_editor,
    });
}

/// 이 섹션에 보일 행이 하나라도 있는가(좌측 네비에 그 섹션을 넣을지 판정).
///
/// 앞 세 줄은 `settingsExposesConfigKey` 라는 **이름 기반 예외 필터**를 설명하고 있었는데, 그 함수는
/// 동어반복이라 지워졌다(키 존재와 무관하게 늘 같은 답을 냈다). 지금 `chrome.theme`·`chrome.preset` 이
/// 안 보이는 이유는 그 필터가 아니라 **스키마에 없어서**이고, 되살아남을 막는 것은 실제 행 목록을 훑는
/// 테스트다. 지운 메커니즘을 설명하는 주석이 남아 있으면 다음 사람이 없는 방어를 믿는다.
pub fn settingsSectionHasField(bools: []const config_mod.schema.BoolField, nums: []const config_mod.schema.NumberField, enums: []const config_mod.schema.EnumField, texts: []const config_mod.schema.TextField, colors: []const config_mod.schema.ColorField, sec: ?config_mod.Section) bool {
    // `.global_hotkey`는 schema 필드가 없는 특수 섹션이라 강제로 목록에 넣는다(전역 단축키 녹음 행만 — theme의
    // palette·input의 keybind 특수 행 패턴처럼 currentSectionFields가 행을 합성한다). 좌측 네비에 항상 보여야 한다.
    if (sec == .global_hotkey) return true;
    for (bools) |b| if (b.section == sec) return true;
    for (nums) |n| if (n.section == sec) return true;
    for (enums) |e| if (e.section == sec) return true;
    for (texts) |t| if (t.section == sec) return true;
    for (colors) |c| if (c.section == sec) return true;
    return false;
}

/// config 스키마의 **현재 섹션** 필드를 세팅 폼 행으로 빌드한다(메타가 곧 UI, config-gui §2·§4). 라벨=meta.doc
/// (없으면 키), 값=현재 raw config. buildPaletteRows의 settings 짝 — arena 소유. macOS 전용.
/// 교차 검색(cross)일 때 행 라벨 앞에 섹션명을 붙인다(`<섹션> › <라벨>`) — 결과가 어느 섹션 설정인지 보이게.
/// 빈 쿼리(현재 섹션만)면 라벨 그대로. 모든 행 종류(scalar=필드 .section, palette=.theme·keybind=.input·global=
/// .global_hotkey)가 이 단일 헬퍼를 거쳐 접두 규칙이 한 곳. 단일 출처: docs/config-gui.md §6.8.
pub fn settingsRowLabel(arena: std.mem.Allocator, cross: bool, section: ?config_mod.Section, label: []const u8) ![]const u8 {
    if (!cross) return label;
    return std.fmt.allocPrint(arena, "{s} › {s}", .{ settingsSectionLabel(section), label });
}

pub fn buildSettingsDefaults(arena: std.mem.Allocator) !SettingsDefaults {
    const def = config_mod.Config{};
    var bools: std.ArrayList(config_mod.schema.BoolField) = .empty;
    try config_mod.schema.appendBoolFields(arena, def, &bools);
    var nums: std.ArrayList(config_mod.schema.NumberField) = .empty;
    try config_mod.schema.appendNumberFields(arena, def, &nums);
    var enums: std.ArrayList(config_mod.schema.EnumField) = .empty;
    try config_mod.schema.appendEnumFields(arena, def, &enums);
    var texts: std.ArrayList(config_mod.schema.TextField) = .empty;
    try config_mod.schema.appendTextFields(arena, def, &texts);
    var colors: std.ArrayList(config_mod.schema.ColorField) = .empty;
    try config_mod.schema.appendColorFields(arena, def, &colors);
    return .{ .bools = bools.items, .nums = nums.items, .enums = enums.items, .texts = texts.items, .colors = colors.items };
}

/// 합성(synthetic) text 행이 기본값과 같은가(§6.11) — 동기화 키(env/macro)는 값 존재=override, 추가 sentinel은 항상 기본,
/// shell.args/workspace.root는 빈 값이 기본, 나머지 schema text는 기본 문자열 비교. buildSettingsFields의 is_default 주입용.
pub fn settingsTextIsDefault(t: config_mod.schema.TextField, defaults: SettingsDefaults) bool {
    if (std.mem.eql(u8, t.key, "env.") or std.mem.eql(u8, t.key, "macro.")) return true; // 추가 sentinel 행 — ↺ 없음
    if (std.mem.startsWith(u8, t.key, "env.") or std.mem.startsWith(u8, t.key, "macro.")) return false; // 실제 env/macro = override
    if (std.mem.eql(u8, t.key, "shell.args") or std.mem.eql(u8, t.key, "workspace.root")) return t.value.len == 0;
    if (defaults.textFor(t.key)) |dv| return std.mem.eql(u8, dv, t.value);
    return true;
}

/// 액션에 사용자 지정 in-app 키바인딩이 있는가(§6.11 keybind 행 is_default 판정). 있으면 ↺(=빌트인으로 unbind)를 띄운다.
/// unbindActionEntry의 found_user 검사와 같은 기준(빌트인은 loaded_config.keybindings에 없다). 순수 unbind만 한 경우는
/// 못 잡는다(chord 기준이라 — v1 한계, 전체 리셋이 담당).
pub fn settingsActionHasUserBinding(self: *AppSession, action: config_mod.Action) bool {
    // Action은 union(enum)이라 ==가 아니라 std.meta.eql로 비교한다(command_catalog.chordForAction 선례).
    for (self.loaded_config.keybindings) |b| if (std.meta.eql(b.action, action)) return true;
    return false;
}

pub fn buildSettingsFields(self: *AppSession, arena: std.mem.Allocator) ![]chrome.components.settings.FieldRow {
    const Row = chrome.components.settings.FieldRow;
    const cf = try currentSectionFields(self, arena);
    const defaults = try buildSettingsDefaults(arena); // §6.11 is_default 판정용(기본 config 대비)
    // 교차 검색(쿼리 있음)이면 행 라벨에 섹션명 접두 — currentSectionFields의 cross 게이트와 같은 조건(단일 출처).
    const cross = self.chrome_host.settings.searchQuery().len > 0;
    // 결합 순서: bool(toggle) → number(입력 박스) → enum(dropdown) → text(편집) → color(스와치). selected/handler
    // 인덱싱이 이 순서를 공유한다(toggle/adjust/commitSelectedText가 같은 currentSectionFields 빌드로 구간 매핑).
    const rows = try arena.alloc(Row, cf.total());
    var i: usize = 0;
    for (cf.bools) |b| {
        // §6.11: 기본값과 같은가 — 기본 config의 같은 키 값과 비교(못 찾으면 기본으로 봄=↺ 없음).
        const is_def = if (defaults.boolFor(b.key)) |dv| dv == b.value else true;
        rows[i] = .{ .label = try settingsRowLabel(arena, cross, b.section, if (b.doc.len > 0) b.doc else b.key), .kind = .{ .toggle = b.value }, .is_default = is_def };
        i += 1;
    }
    for (cf.nums) |n| {
        const is_def = if (defaults.numFor(n.key)) |dv| dv == n.value else true;
        rows[i] = .{ .label = try settingsRowLabel(arena, cross, n.section, if (n.doc.len > 0) n.doc else n.key), .kind = .{ .number = .{ .value = n.value, .min = n.min, .max = n.max } }, .is_default = is_def };
        i += 1;
    }
    for (cf.enums) |e| {
        // theme.preset(synthetic)은 v1에서 ↺ 제외(테마 되돌리기는 프리셋 드롭다운·개별 색 ↺·전체 리셋이 담당 — §6.11).
        // 나머지 enum은 기본 변형 토큰과 현재 토큰 비교(둘 다 같은 appendEnumFields 변환이라 직접 비교 가능).
        const is_def = if (std.mem.eql(u8, e.key, "theme.preset"))
            true
        else if (defaults.enumCurrentFor(e.key)) |dv| std.mem.eql(u8, dv, e.current) else true;
        // `ui.language` 만 **표시명**을 쓴다(`자동`/`English`/`한국어`). 저장값(`e.current`)은 건드리지
        // 않는다 — 바로 위 `is_def` 가 그 값으로 기본값 여부를 재기 때문이다. 계약 §5 가 짚은 함정이
        // 그것이고, 여기서 표시와 비교가 갈라져 있어 표시만 바꾸면 된다.
        const shown: []const u8 = if (std.mem.eql(u8, e.key, "ui.language"))
            maru.i18n.preferenceLabel(std.meta.stringToEnum(maru.i18n.Preference, e.current) orelse .auto)
        else
            e.current;
        rows[i] = .{ .label = try settingsRowLabel(arena, cross, e.section, if (e.doc.len > 0) e.doc else e.key), .kind = .{ .dropdown = shown }, .is_default = is_def };
        i += 1;
    }
    for (cf.texts) |t| {
        const label = try settingsRowLabel(arena, cross, t.section, if (t.doc.len > 0) t.doc else t.key);
        // font.family는 dropdown 스타일 폰트 피커(←→로 번들 폰트 순환, Enter로 직접입력) — 나머지 텍스트 필드는 인라인 편집.
        const kind: chrome.components.settings.FieldRow.Kind = if (std.mem.eql(u8, t.key, "font.family")) .{ .font = t.value } else .{ .text = t.value };
        rows[i] = .{ .label = label, .kind = kind, .is_default = settingsTextIsDefault(t, defaults) };
        i += 1;
    }
    // 테마 프리셋이 활성이면 색·팔레트 행을 잠근다(프리셋이 색을 정하므로) — 회색 표시 + 입력은 핸들러가 전환/차단.
    const preset_active = self.themePresetActive();
    for (cf.colors) |c| {
        // 현재 hex를 RGB로 파싱해 스와치에. 저장 config는 검증돼 유효하지만 방어적으로 회색 폴백(상수 hex로 — 타입을
        // parseHexColor 반환과 일치시켜 별도 color import 불요; #808080은 항상 유효).
        const rgb = config_mod.appearance.parseHexColor(c.value) catch (config_mod.appearance.parseHexColor("#808080") catch unreachable);
        const is_def = if (defaults.colorFor(c.key)) |dv| std.mem.eql(u8, dv, c.value) else true;
        rows[i] = .{ .label = try settingsRowLabel(arena, cross, c.section, if (c.doc.len > 0) c.doc else c.key), .kind = .{ .color = .{ .hex = c.value, .rgb = rgb } }, .disabled = preset_active, .is_default = is_def };
        i += 1;
    }
    // 구문 색 역할 행(§9.0). **효과색을 보여 준다** — override 가 있으면 그 색, 없으면 팔레트에서
    // 파생한 색이다(그래야 스와치가 화면에 실제로 뜨는 색과 같다). `is_default` 는 override 가
    // 없을 때 참이므로, 안 정한 역할에는 ↺ 가 안 뜬다.
    if (cf.syntax_roles > 0) {
        const derived = maru.session.syntax_theme.fromTheme(self.appearance.theme);
        inline for (@typeInfo(config_mod.theme.SyntaxRole).@"enum".fields) |f| {
            const role: config_mod.theme.SyntaxRole = @enumFromInt(f.value);
            const label_text = maru.session.syntax_theme.roleLabel(role);
            // **마스크가 정본이다** — 여기서 검색 일치를 다시 계산하면 `keyAtRow`·핸들러와 갈릴 수 있다.
            if (cf.syntax_mask & (@as(u32, 1) << @intCast(f.value)) != 0) {
                const override = self.loaded_config.config.theme.syntax[f.value];
                const rgb = if (override) |hex|
                    (config_mod.appearance.parseHexColor(hex) catch maru.session.syntax_theme.colorFor(derived, role))
                else
                    maru.session.syntax_theme.colorFor(derived, role);
                const hex_text = try rgbToHex(arena, rgb);
                rows[i] = .{
                    .label = try settingsRowLabel(arena, cross, .theme, label_text),
                    .kind = .{ .color = .{ .hex = hex_text, .rgb = rgb } },
                    .is_default = override == null,
                    .disabled = preset_active,
                };
                i += 1;
            }
        }
    }
    if (cf.has_palette) {
        // ANSI 16색 팔레트 그리드(theme.palette.0~15). 각 셀의 효과색 = config override 있으면 그 hex, 없으면 표준
        // xterm256 기본(index<16=ansi16). hex는 편집 시드용(override는 그대로, 기본은 RGB→#rrggbb 포맷). 선택 셀은
        // State.grid_cell(클램프). arena 소유(이 프레임만 — view가 읽고 버린다).
        var cells: [16]Row.PaletteGrid.Cell = undefined;
        for (&cells, 0..) |*cell, idx| {
            if (self.loaded_config.config.theme.palette[idx]) |hex| {
                const rgb = config_mod.appearance.parseHexColor(hex) catch (config_mod.appearance.parseHexColor("#808080") catch unreachable);
                cell.* = .{ .rgb = rgb, .hex = hex };
            } else {
                const rgb = terminal.types.xterm256(@intCast(idx));
                cell.* = .{ .rgb = rgb, .hex = try rgbToHex(arena, rgb) };
            }
        }
        const sel = @min(self.chrome_host.settings.grid_cell, cells.len - 1);
        // §6.11: 팔레트 행 ↺는 **선택 셀**이 override(config.theme.palette[sel] 있음)일 때만 — ↺/Backspace가 그 셀만 리셋.
        const pal_is_def = self.loaded_config.config.theme.palette[sel] == null;
        rows[i] = .{ .label = try settingsRowLabel(arena, cross, .theme, maru.i18n.t(.set_ansi_palette)), .kind = .{ .palette_grid = .{ .cells = cells, .selected = sel } }, .disabled = preset_active, .is_default = pal_is_def };
        i += 1;
    }
    if (cf.keybind_entries.len > 0) {
        // (검색으로 필터된) keybind 행(라벨=title, 값=현재 chord 표시). 현재 chord는 resolver에서 fresh 계산
        // (리바인딩 즉시 반영). 빈 chord(미지정)는 컴포넌트가 "(미지정)"으로 표시. arena 소유(이 프레임만).
        const resolver = self.loaded_config.keyBindingResolver();
        for (cf.keybind_entries) |entry| {
            const chord = command_catalog.chordForAction(resolver, entry.action);
            var disp_scratch: [command_catalog.max_chord_display_len]u8 = undefined;
            const display: []const u8 = if (chord) |c| command_catalog.formatChord(c, &disp_scratch) else "";
            // §6.11: 사용자 지정 rebinding이 있으면 ↺(=빌트인으로 unbind). 순수 unbind만 한 경우는 못 잡음(v1 한계).
            const is_def = !settingsActionHasUserBinding(self, entry.action);
            rows[i] = .{ .label = try settingsRowLabel(arena, cross, .input, entry.title), .kind = .{ .keybind = try arena.dupe(u8, display) }, .is_default = is_def };
            i += 1;
        }
    }
    if (cf.global_entries.len > 0) {
        // 전역(OS) 단축키 행(라벨=title, 값=현재 chord 표시). in-app과 달리 빌트인 기본이 없어 사용자 global_bindings만
        // 스캔(chordForGlobalAction) — 없으면 빈 문자열(컴포넌트가 "(미지정)"으로 표시). 같은 `.keybind` 위젯 재사용.
        for (cf.global_entries) |entry| {
            const chord = command_catalog.chordForGlobalAction(self.loaded_config.global_bindings, entry.action);
            var disp_scratch: [command_catalog.max_chord_display_len]u8 = undefined;
            const display: []const u8 = if (chord) |c| command_catalog.formatChord(c, &disp_scratch) else "";
            // §6.11: 전역은 빌트인 기본이 없어 사용자 바인딩(chord 존재)이 곧 override — 있으면 ↺(=해제).
            rows[i] = .{ .label = try settingsRowLabel(arena, cross, .global_hotkey, entry.title()), .kind = .{ .keybind = try arena.dupe(u8, display) }, .is_default = chord == null };
            i += 1;
        }
    }
    return rows;
}

/// 좌측 네비 라벨 목록(현재 섹션 강조는 컴포넌트가 settings.section으로). arena 소유.
pub fn buildSettingsSectionLabels(self: *AppSession, arena: std.mem.Allocator) ![]const []const u8 {
    const sections = try buildSectionList(self, arena);
    // +1 = 네비 맨 아래 "↺ 초기화" 액션 행(§6.4). 실제 섹션(폼 매핑=buildSectionList)과 분리해 라벨 목록에만 더한다 —
    // 이 행은 섹션이 아니라 requestResetAll 액션(nav_reset_row=sections.len으로 컴포넌트에 알림). 라벨 글리프는 단일 출처.
    const labels = try arena.alloc([]const u8, sections.len + 1);
    for (sections, 0..) |s, i| labels[i] = s.label;
    // 라벨은 arena 소유여야 하는데 `i18n.format` 은 **빌려준 버퍼에 쓰고 슬라이스를 돌려준다**(할당하지
    // 않는다). 그래서 스택 버퍼에 만든 뒤 arena 로 복사한다 — 반환 슬라이스가 이 함수보다 오래 산다.
    var reset_buf: [64]u8 = undefined;
    labels[sections.len] = try arena.dupe(u8, maru.i18n.format(&reset_buf, maru.i18n.t(.set_reset_named), &.{
        .{ .s = chrome.components.settings.reset_glyph },
    }));
    return labels;
}

pub fn isDesktopNotificationSettingKey(key: []const u8) bool {
    return std.mem.eql(u8, key, "notifications.osc");
}

/// 드롭다운 팝업이 열렸을 때 그 변형 라벨 목록(enum 변형 또는 번들 폰트 + "직접 입력…"). 팝업이 닫혔거나 선택 행이
/// enum/font가 아니면 빈 슬라이스. settings.view/handlePointer에 dropdown_items로 주입해 팝업 목록·hit-test를 그린다.
pub fn buildSettingsDropdownItems(self: *AppSession, arena: std.mem.Allocator) ![]const []const u8 {
    if (!self.chrome_host.settings.dropdown.open) return &.{};
    const cf = try currentSectionFields(self, arena);
    const sel = self.chrome_host.settings.selected;
    const after_nums = cf.bools.len + cf.nums.len;
    const after_enums = after_nums + cf.enums.len;
    const after_texts = after_enums + cf.texts.len;
    if (sel >= after_nums and sel < after_enums) {
        const e = cf.enums[sel - after_nums];
        if (std.mem.eql(u8, e.key, "theme.preset")) return themePresetVariants(self, arena);
        if (std.mem.eql(u8, e.key, "ui.language")) return uiLanguageVariants(arena);
        return (try config_mod.schema.enumVariants(arena, self.loaded_config.config, e.key)) orelse &.{};
    }
    if (sel >= after_enums and sel < after_texts) {
        const ti = sel - after_enums;
        if (ti < cf.texts.len and std.mem.eql(u8, cf.texts[ti].key, "font.family")) {
            // 번들 폰트 + "직접 입력…"(마지막 슬롯 — 목록 밖 임의 설치 폰트를 인라인 편집으로 넣는다).
            const fonts = config_mod.theme.bundled_font_families;
            const out = try arena.alloc([]const u8, fonts.len + 1);
            for (fonts, 0..) |fam, i| out[i] = fam;
            out[fonts.len] = fontDirectInputLabel();
            return out;
        }
    }
    return &.{};
}

/// 설정 팔레트 그리드 행의 폼-포커스 ←→를 16색 셀 이동으로 가로챈다(host가 rows를 모르는 특수 행 — platform 전용).
/// 처리하면 true(키 소비). 조건: 설정 열림·폼 포커스·다른 모드(팝업/picker/편집/녹음) 아님·선택 행=팔레트 그리드·
/// 평범한 ←/→. **검색 중에도 동작한다** — `currentSectionFields`가 검색 필터를 적용해 `paletteRowIndex`와 `selected`가
/// 같은 필터-인덱스라 정합하고, 검색의 ←→는 원래 소비만 되던 미사용 키라 셀 이동으로 재활용해도 충돌 없다(↑↓·글자는
/// 여전히 검색 나비·쿼리 편집). ← 셀0·→ 셀15(끝)에선 false를 돌려(intercept 안 함) 컴포넌트가 처리한다(검색 중엔 그 방향
/// 키가 소비돼 no-op, 비-검색이면 영역 포커스 이동으로 이어진다).
pub fn settingsPaletteArrowIntercept(self: *AppSession, event: terminal.KeyEvent) bool {
    const s = &self.chrome_host.settings;
    if (!s.open or s.nav_focused or s.dropdown.open or s.picking or s.editing or s.recording) return false;
    const dir: i32 = switch (chromeInputFromKeyEvent(event)) {
        .key => |k| switch (k.key) {
            .left => -1,
            .right => 1,
            else => return false,
        },
        else => return false,
    };
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const cf = currentSectionFields(self, scratch.allocator()) catch return false;
    const pi = cf.paletteRowIndex() orelse return false;
    if (pi != s.selected) return false;
    const gc = @min(s.grid_cell, 15);
    if (dir < 0 and gc == 0) return false; // ← 셀0 → 영역 이동(nav)으로 넘김
    if (dir > 0 and gc == 15) return false; // → 셀15(끝) → 컴포넌트로(폼이라 no-op)
    s.moveGridCell(dir);
    return true;
}

pub fn toggleSelectedSetting(self: *AppSession) void {
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const cf = currentSectionFields(self, scratch.allocator()) catch return;
    const sel = self.chrome_host.settings.selected;
    if (sel < cf.bools.len) {
        // bool 행 — flip.
        const f = cf.bools[sel];
        const new_value = !f.value;
        if (config_mod.schema.setBool(&self.loaded_config.config, f.key, new_value)) {
            // daemon-owned notification snapshot 갱신이 실패했는데 GUI 값만 저장하면 이후 GUI 0에서도 host가 이전
            // 정책으로 동작한다. 따라서 live runtime 전부가 새 generation을 확인하기 전에는 config commit을 열지 않고,
            // 실패 시 이전 값으로 보상 갱신한 뒤 UI/config도 되돌린다.
            if (isDesktopNotificationSettingKey(f.key) and app_session_mod.is_macos) {
                if (app_session_mod.app_remote_backend) |*rb| {
                    rb.configureNotifications(new_value) catch {
                        _ = rb.configureNotifications(f.value) catch {};
                        _ = config_mod.schema.setBool(&self.loaded_config.config, f.key, f.value);
                        return;
                    };
                }
            }
            // **전역을 config 갱신 직후, 재적용 전에 세운다.** keep-alive 는 앱 전역이 정본이고
            // `loaded_config.config` 는 창마다의 미러다. 재적용 경로가 그 미러를 전역에서 되동기화하므로
            // (`currentSectionFields` 의 첫 문장), 전역을 나중에 세우면 **방금 쓴 새 값이 옛 전역으로
            // 되돌려진다** — 껐는데 켜진 채로 남고 그 값이 파일로 간다. 순서 하나가 그 창을 닫는다.
            if (std.mem.eql(u8, f.key, "session.keep-alive-after-quit")) {
                setAppKeepAlivePolicy(new_value);
                const snapshot = appKeepAliveSnapshot();
                self.loaded_config.session_keep_alive_provenance = snapshot.provenance;
                self.loaded_config.file_provenance = snapshot.file_provenance;
            }
            // theme.follow-system은 단순 재resolve로 부족하다 — 켜면 현재 시스템 외관 프리셋을 즉시 덮고(reapply만
            // 하면 system_is_dark가 안 반영돼 토글이 무효처럼 보임), 끄면 덮기 전 사용자 테마로 복귀해야 한다(F2-9).
            if (std.mem.eql(u8, f.key, "theme.follow-system")) {
                if (self.loaded_config.config.theme_follow_system)
                    self.applyFollowSystemTheme()
                else
                    disableFollowSystemTheme(self);
                // theme.preset synthetic 행이 follow-system on/off로 사라지거나 나타나 theme 섹션 행 수가 바뀐다 —
                // setFieldCount가 selected를 clamp하도록 갱신한다(안 하면 선택 인덱스가 stale, 리뷰 C).
                refreshSettingsFieldCount(self);
            } else {
                reapplyLoadedConfig(self);
            }
            // 전역은 위에서 이미 세웠다 — 여기서는 그 값에 딸린 부수 작업만 한다.
            if (std.mem.eql(u8, f.key, "session.keep-alive-after-quit")) {
                if (new_value and !self.is_quick) self.ensureRemoteBackend();
            }
            if (new_value and isDesktopNotificationSettingKey(f.key)) {
                self.notification_authorization_pending = true;
            }
            markConfigKeyDirty(self, f.key);
        }
        return;
    }
    const after_nums = cf.bools.len + cf.nums.len;
    if (sel >= cf.bools.len and sel < after_nums) {
        // number 행 — 활성(클릭/Enter) = 인라인 수치 편집 시작(입력 박스, 현재값 시드). 커밋 Enter→commitSelectedText가
        // 파싱+범위 clamp+setNumber. (프로그레스바 슬라이더 대체 — 사용자가 값을 직접 타이핑.) 시드는 표시값과 같은 포맷.
        const ni = sel - cf.bools.len;
        if (ni < cf.nums.len) {
            const seed = chrome.components.settings.formatNumberValue(scratch.allocator(), cf.nums[ni].value) catch return;
            self.chrome_host.settings.enterEdit(seed);
        }
        return;
    }
    const after_enums = after_nums + cf.enums.len;
    if (sel >= after_nums and sel < after_enums) {
        // enum 행 — 활성(클릭/Enter/Space) = **드롭다운 팝업 열기**(변형 목록 + 현재 인덱스에서 선택 시작). 선택 확정은
        // dropdown_accept → applyDropdownSelection. theme.preset은 synthetic(스키마 enum 아님)이라 팝업 대신 프리셋 순환(특수).
        const e = cf.enums[sel - after_nums];
        if (std.mem.eql(u8, e.key, "theme.preset")) {
            // theme.preset은 synthetic이지만 명백한 선택 목록이라 드롭다운 팝업으로(16 프리셋 + "사용자 지정").
            // 취소 복원 스냅샷: 인덱스로 못 되살리는 커스텀 테마 색을 통째로 저장(code-review 데이터 손실 수정).
            self.dropdown_snapshot_kind = .preset;
            self.dropdown_snapshot_theme = self.loaded_config.config.theme;
            self.dropdown_snapshot_user_custom = self.theme_user_custom;
            const variants = themePresetVariants(self, scratch.allocator()) catch return;
            self.chrome_host.settings.dropdown.show(variants.len, themePresetCurrentIndex(self));
            self.metal_dirty = true;
            return;
        }
        self.dropdown_snapshot_kind = .none; // enum은 인덱스 복원으로 충분
        const variants = (config_mod.schema.enumVariants(scratch.allocator(), self.loaded_config.config, e.key) catch null) orelse return;
        const cur_idx = config_mod.schema.enumIndex(self.loaded_config.config, e.key) orelse 0;
        self.chrome_host.settings.dropdown.show(variants.len, cur_idx);
        self.metal_dirty = true;
        return;
    }
    const after_texts = after_enums + cf.texts.len;
    if (sel >= after_enums and sel < after_texts) {
        // text 행 — 활성(클릭/Enter). font.family는 **번들 폰트 드롭다운 팝업**(선택 목록 + "직접 입력…"),
        // window.background-image는 파일 선택창, 나머지는 인라인 편집 시작(현재값 시드). 커밋은 Enter→commitSelectedText.
        const ti = sel - after_enums;
        if (ti < cf.texts.len) {
            const tkey = cf.texts[ti].key;
            if (std.mem.eql(u8, tkey, "font.family")) {
                const fonts = config_mod.theme.bundled_font_families;
                // 취소 복원 스냅샷: 목록 밖 커스텀 폰트를 열 때 통째로 저장(인덱스로는 못 되살림 — 데이터 손실 수정).
                self.dropdown_snapshot_kind = .font;
                self.dropdown_snapshot_font = self.loaded_config.arena.allocator().dupe(u8, cf.texts[ti].value) catch "";
                var cur_idx: usize = fonts.len; // 현재값이 목록 안이면 그 인덱스, 밖(커스텀)이면 "직접 입력…" 슬롯(=fonts.len)
                for (fonts, 0..) |fam, i| if (std.mem.eql(u8, fam, cf.texts[ti].value)) {
                    cur_idx = i;
                    break;
                };
                self.chrome_host.settings.dropdown.show(fonts.len + 1, cur_idx); // +1 = "직접 입력…"
                self.metal_dirty = true;
            } else if (std.mem.eql(u8, tkey, "window.background-image")) {
                self.file_pick_pending = true;
            } else {
                self.chrome_host.settings.enterEdit(cf.texts[ti].value);
            }
        }
        return;
    }
    const after_colors = after_texts + cf.colors.len;
    if (sel >= after_texts and sel < after_colors) {
        // color 행 — 활성(스와치 클릭/Enter) = HSV picker 열기(현재 색으로 시드). 확정은 settings_color_picked →
        // commitPickerColor. ←→는 별개로 16색 프리셋 순환(adjustSelectedSetting), hex 영역 클릭은 컴포넌트가 enterEdit.
        const ci = sel - after_texts;
        if (ci < cf.colors.len) {
            // 프리셋 잠금 상태면 "사용자 지정"으로 전환(잠금 해제)한 뒤 편집 — 클릭 시 자동 전환 후 편집(plan A).
            if (self.themePresetActive()) self.theme_user_custom = true;
            const c = cf.colors[ci];
            const rgb = config_mod.appearance.parseHexColor(c.value) catch (config_mod.appearance.parseHexColor("#808080") catch unreachable);
            self.chrome_host.settings.openPicker(rgb);
            self.metal_dirty = true;
        }
        return;
    }
    if (syntaxRoleAt(cf, sel)) |role| {
        // 색 행과 같은 규율: 프리셋 잠금이면 "사용자 지정" 으로 전환한 뒤 편집한다.
        if (self.themePresetActive()) self.theme_user_custom = true;
        const derived = maru.session.syntax_theme.fromTheme(self.appearance.theme);
        const cur = self.loaded_config.config.theme.syntax[@intFromEnum(role)];
        const rgb = if (cur) |hex|
            (config_mod.appearance.parseHexColor(hex) catch maru.session.syntax_theme.colorFor(derived, role))
        else
            maru.session.syntax_theme.colorFor(derived, role);
        self.chrome_host.settings.openPicker(rgb);
        self.metal_dirty = true;
        return;
    }
    if (cf.paletteRowIndex()) |pi| if (sel == pi) {
        // 팔레트 그리드 행 — Enter/Space = 선택 셀 hex 인라인 편집 시작(현재 효과색 시드). 커밋은 commitSelectedText.
        if (self.themePresetActive()) self.theme_user_custom = true; // 프리셋 잠금이면 사용자 지정으로 전환 후 편집
        const gi = @min(self.chrome_host.settings.grid_cell, 15);
        const seed = paletteCellHex(self, scratch.allocator(), gi) catch return;
        self.chrome_host.settings.enterEdit(seed);
        return;
    };
    if (cf.keybindRowStart()) |ks| if (sel >= ks and sel - ks < cf.keybind_entries.len) {
        // keybind 행 — Enter/Space/클릭 = 녹음 시작. 다음 raw 키를 handleKeyEvent가 가로채 captureKeybindRecording로 rebind.
        self.chrome_host.settings.recording = true;
        self.metal_dirty = true;
        return;
    };
    if (cf.globalKeybindRowStart()) |gs| if (sel >= gs and sel - gs < cf.global_entries.len) {
        // 전역 단축키 행 — in-app keybind 행과 동일 경로(녹음 시작 → captureKeybindRecording가 글로벌 분기로 rebind).
        self.chrome_host.settings.recording = true;
        self.metal_dirty = true;
        return;
    };
    // number 행(bool..after_nums)은 위 number 분기에서 입력 박스 편집을 이미 열었다 — 여기 fall-through 대상 아님.
}

/// 팔레트 셀 idx의 효과색 hex(arena 소유) — config override 있으면 그 hex(빌림), 없으면 xterm256 기본을 #rrggbb로.
/// 그리드 행의 편집 시드용(enterEdit가 즉시 고정 버퍼에 복사하므로 arena 수명은 호출 직후까지면 충분).
pub fn paletteCellHex(self: *AppSession, arena: std.mem.Allocator, idx: usize) ![]const u8 {
    if (idx >= self.loaded_config.config.theme.palette.len) return "#000000";
    if (self.loaded_config.config.theme.palette[idx]) |hex| return hex;
    return try rgbToHex(arena, terminal.types.xterm256(@intCast(idx)));
}

/// 터미널 매크로 삭제(Backspace) — chord_str의 binding을 라이브 제거 + write-back 줄 제거 예약.
pub fn removeTerminalMacro(self: *AppSession, chord_str: []const u8) void {
    const a = self.loaded_config.arena.allocator();
    const chord = config_mod.keybinding.KeyChord.parse(chord_str) catch return;
    var list: std.ArrayList(config_mod.keybinding.TerminalBinding) = .empty;
    for (self.loaded_config.terminal_bindings) |b| {
        if (!b.chord.eql(chord)) list.append(a, b) catch return;
    }
    self.loaded_config.terminal_bindings = list.toOwnedSlice(a) catch return;
    self.cancelPendingMacro(chord_str); // 같은 chord 대기 추가 예약 상쇄 + 중복 삭제 예약 방지
    const chord_owned = a.dupe(u8, chord_str) catch return;
    self.config_terminal_macro_removes.append(self.allocator, chord_owned) catch return;
    self.metal_dirty = true;
}

/// 선택 행을 삭제한다(Backspace). **env.<KEY> 행** → env 변수 삭제, **keybind 행** → 사용자 지정 단축키 해제(unbind).
/// 그 외(schema·shell.args·env 추가 sentinel·palette)는 무동작. 둘 다 spawn/입력 시점이라 appearance 재적용 없음.
/// 선택된 세팅 폼 행을 **기본값으로 되돌린다**(§6.11) — ↺ 클릭(settings_reset_field)·Backspace(settings_delete_row)의
/// 공통 경로. 행 종류로 분기: scalar(bool/number/enum)·color·schema text는 기본 config 값으로 setter + **override 줄 제거**
/// (markConfigKeyRemoved — override-only 정책상 파일엔 key=default를 안 쓰고 줄을 뺀다), palette 셀은 override 제거(null),
/// env/macro/keybind/global은 삭제/해제(=그들의 기본값 "없음"). 인덱스 산술은 toggleSelectedSetting·buildSettingsFields와
/// 같은 구간 순서(bool→num→enum→text→color→palette→keybind→global)를 공유한다. 이미 기본값인 행은 조용히 무동작
/// (컴포넌트가 is_default 행엔 ↺를 안 그리므로 ↺ 경로로는 안 오고, Backspace로는 no-op).
pub fn resetSelectedSettingRow(self: *AppSession) void {
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const cf = currentSectionFields(self, scratch.allocator()) catch return;
    const defaults = buildSettingsDefaults(scratch.allocator()) catch return;
    const sel = self.chrome_host.settings.selected;

    // bool 행 → 기본값으로 flip(theme.follow-system은 toggle과 같은 특수 재적용).
    if (sel < cf.bools.len) {
        const key = cf.bools[sel].key;
        if (std.mem.eql(u8, key, "session.keep-alive-after-quit")) {
            // 이 값의 기본값 복귀는 다음 Quit의 runtime 소유권을 바꾸는 파괴적 우회다. G2는 row ↺와
            // Backspace 모두 exact no-op으로 막고 사용자가 Workspace 토글에서 명시적으로 결정하게 한다.
            self.showNoticeKey(.set_keepalive_reset_preserved);
            return;
        }
        const dv = defaults.boolFor(key) orelse return;
        if (config_mod.schema.setBool(&self.loaded_config.config, key, dv)) {
            if (std.mem.eql(u8, key, "theme.follow-system")) {
                if (self.loaded_config.config.theme_follow_system) self.applyFollowSystemTheme() else disableFollowSystemTheme(self);
                refreshSettingsFieldCount(self);
            } else reapplyLoadedConfig(self);
            markConfigKeyRemoved(self, key);
            self.metal_dirty = true;
        }
        return;
    }
    const after_nums = cf.bools.len + cf.nums.len;
    if (sel >= cf.bools.len and sel < after_nums) {
        const key = cf.nums[sel - cf.bools.len].key;
        const dv = defaults.numFor(key) orelse return;
        if (config_mod.schema.setNumber(&self.loaded_config.config, key, dv)) {
            reapplyLoadedConfig(self);
            markConfigKeyRemoved(self, key);
            self.metal_dirty = true;
        }
        return;
    }
    const after_enums = after_nums + cf.enums.len;
    if (sel >= after_nums and sel < after_enums) {
        const e = cf.enums[sel - after_nums];
        if (std.mem.eql(u8, e.key, "theme.preset")) return; // theme.preset은 v1 ↺ 제외(is_default=true라 안 옴) — 방어적 무동작
        const di = config_mod.schema.enumIndex(config_mod.Config{}, e.key) orelse return; // 기본 변형의 선언순 인덱스
        if (config_mod.schema.setEnumIndex(&self.loaded_config.config, e.key, di)) {
            reapplyLoadedConfig(self);
            markConfigKeyRemoved(self, e.key);
            self.metal_dirty = true;
        }
        return;
    }
    const after_texts = after_enums + cf.texts.len;
    if (sel >= after_enums and sel < after_texts) {
        resetSelectedTextRow(self, cf.texts[sel - after_enums], defaults);
        return;
    }
    // 구문 색 행 되돌리기 — **파생으로 되돌린다**(기본값이 따로 없다. `null` 이 곧 "팔레트에서 판다").
    //
    // **줄을 지우는 것이 핵심이다.** 슬롯만 비우면 직렬화가 그 키를 안 쓸 뿐 **파일에 있던 줄은
    // 그대로 남아** 다음 로드에 되살아난다(적대적 검증 2회차에서 확인한 자리). `markConfigKeyRemoved`
    // 가 `removeConfigLines` 로 그 줄을 지운다 — 팔레트 셀 되돌리기가 같은 규율을 쓴다.
    if (syntaxRoleAt(cf, sel)) |role| {
        if (self.themePresetActive()) return; // 잠금 행은 ↺가 안 뜨므로 Backspace로도 금지(위 색 행과 같다)
        const idx = @intFromEnum(role);
        if (self.loaded_config.config.theme.syntax[idx] != null) {
            self.loaded_config.config.theme.syntax[idx] = null;
            reapplyLoadedConfig(self);
            markConfigKeyRemoved(self, syntaxRoleKeyOf(role));
            self.metal_dirty = true;
        }
        return;
    }
    const after_colors = after_texts + cf.colors.len;
    if (sel >= after_texts and sel < after_colors) {
        if (self.themePresetActive()) return; // 프리셋 잠금 색 행은 ↺가 안 뜨므로 Backspace로도 리셋 금지(잠금 우회 방지 — buildSettingsFields의 disabled와 일치)
        const c = cf.colors[sel - after_texts];
        const dv = defaults.colorFor(c.key) orelse return; // 기본 색 hex(#RRGGBB)
        const owned = self.loaded_config.arena.allocator().dupe(u8, dv) catch return; // setText는 config arena 소유 슬라이스를 요구
        if (config_mod.schema.setText(&self.loaded_config.config, c.key, owned)) {
            reapplyLoadedConfig(self);
            markConfigKeyRemoved(self, c.key);
            self.metal_dirty = true;
        }
        return;
    }
    // palette 그리드 행 → **선택 셀** override 제거(null → 표준 xterm256 기본색, §6.5·§6.11).
    if (cf.paletteRowIndex()) |pi| if (sel == pi) {
        if (self.themePresetActive()) return; // 프리셋 잠금이면 ↺ 미표시와 일치 — Backspace로도 리셋 금지
        const gi = @min(self.chrome_host.settings.grid_cell, 15);
        if (self.loaded_config.config.theme.palette[gi] != null) {
            self.loaded_config.config.theme.palette[gi] = null;
            reapplyLoadedConfig(self);
            markConfigKeyRemoved(self, config_mod.schema.paletteKey(gi));
            self.metal_dirty = true;
        }
        return;
    };
    // keybind 행 → 사용자 지정 단축키 해제(빌트인 복귀 — 그들의 "기본값").
    if (cf.keybindRowStart()) |ks| if (sel >= ks and sel - ks < cf.keybind_entries.len) {
        unbindActionEntry(self, cf.keybind_entries[sel - ks]);
        self.metal_dirty = true;
        return;
    };
    // 전역 단축키 행 → global_bindings에서 제거(unbind) + 줄 제거 예약(전역은 빌트인 없어 "없음"이 기본).
    if (cf.globalKeybindRowStart()) |gs| if (sel >= gs and sel - gs < cf.global_entries.len) {
        unbindGlobalEntry(self, cf.global_entries[sel - gs]);
        self.metal_dirty = true;
        return;
    };
}

/// text 행 리셋(§6.11 resetSelectedSettingRow의 text 분기 — 케이스가 많아 분리). 동기화 키(env/macro)는 삭제, bg-image·
/// shell.args·workspace.root는 빈 값(직접 클리어 — setText는 빈 값 거부라 필드 직접 세팅), 나머지 schema text(font.family 등)는
/// 기본 문자열로 setText. 모두 override 줄 제거(markConfigKeyRemoved). env/macro/shell.args/workspace.root는 spawn 시점
/// 값이라 라이브 재적용 생략(removeEnvVar 선례), font.family 등 렌더 영향 키만 reapplyLoadedConfig.
pub fn resetSelectedTextRow(self: *AppSession, t: config_mod.schema.TextField, defaults: SettingsDefaults) void {
    if (std.mem.startsWith(u8, t.key, "env.") and t.key.len > "env.".len) {
        removeEnvVar(self, t.key["env.".len..]); // env.<KEY> 삭제(= 그 변수의 기본값 "없음")
        refreshSettingsFieldCount(self);
        self.metal_dirty = true;
        return;
    }
    if (std.mem.startsWith(u8, t.key, "macro.") and t.key.len > "macro.".len) {
        removeTerminalMacro(self, t.key["macro.".len..]); // 터미널 매크로 제거
        refreshSettingsFieldCount(self);
        self.metal_dirty = true;
        return;
    }
    if (std.mem.eql(u8, t.key, "window.background-image")) {
        // 빈 값(배경 없음)으로 — setText는 빈 값을 거부하므로 필드를 직접 빈 리터럴로. 라이브 반영 + override 줄 제거.
        self.loaded_config.config.window_background_image = "";
        reapplyLoadedConfig(self);
        markConfigKeyRemoved(self, "window.background-image");
        self.metal_dirty = true;
        return;
    }
    if (std.mem.eql(u8, t.key, "shell.args")) {
        self.loaded_config.config.shell.args = &.{}; // 기본값 = 빈 argv(셸 spawn 시점 반영)
        markConfigKeyRemoved(self, "shell.args");
        self.metal_dirty = true;
        return;
    }
    if (std.mem.eql(u8, t.key, "workspace.root")) {
        self.loaded_config.config.workspace.root = ""; // 기본값 = 빈(상속 cwd)
        markConfigKeyRemoved(self, "workspace.root");
        self.metal_dirty = true;
        return;
    }
    const dv = defaults.textFor(t.key) orelse return;
    if (dv.len == 0) {
        // 기본값이 빈 문자열인 schema text(font.fallback 등) — setText가 빈 값을 거부해 라이브 클리어 불가. override 줄만
        // 제거해 다음 로드에서 기본값(빈)이 되게 한다(드묾 — 대부분 비-빈 기본값). 라이브 반영은 reapply로도 config 필드가
        // 안 비어 못하므로 생략(한계, §6.11 문서화).
        markConfigKeyRemoved(self, t.key);
        self.metal_dirty = true;
        return;
    }
    const owned = self.loaded_config.arena.allocator().dupe(u8, dv) catch return; // setText는 config arena 소유 슬라이스 요구
    if (config_mod.schema.setText(&self.loaded_config.config, t.key, owned)) {
        reapplyLoadedConfig(self);
        markConfigKeyRemoved(self, t.key);
        self.metal_dirty = true;
    }
}

/// env.<name>을 config.env에서 제거 + 파일 줄 삭제 예약(removeConfigLines). setEnvVar의 짝. name 키는 동적이라
/// loaded_config.arena 소유로 config_removed_keys에 둔다(serializeConfig drain까지 유효).
pub fn removeEnvVar(self: *AppSession, name: []const u8) void {
    const a = self.loaded_config.arena.allocator();
    var list: std.ArrayList([]const u8) = .empty;
    for (self.loaded_config.config.env) |entry| {
        const eq = std.mem.indexOfScalar(u8, entry, '=') orelse entry.len;
        if (!std.mem.eql(u8, entry[0..eq], name)) list.append(a, entry) catch return; // 그 KEY만 제외
    }
    self.loaded_config.config.env = list.toOwnedSlice(a) catch return;
    const removed_key = std.fmt.allocPrint(a, "env.{s}", .{name}) catch return;
    markConfigKeyRemoved(self, removed_key);
}

/// config 키 줄 삭제를 예약한다(중복은 한 번만 — markConfigKeyDirty의 삭제 짝). serializeConfig가 removeConfigLines로 반영.
pub fn markConfigKeyRemoved(self: *AppSession, key: []const u8) void {
    for (self.config_removed_keys.items) |k| if (std.mem.eql(u8, k, key)) return;
    self.config_removed_keys.append(self.allocator, key) catch {};
}

/// **[보류된 dead code — 프로덕션 호출 없음]** 옛 ←→ 값 조절 라우터: 선택 행 종류에 따라 number 스텝(범위 4%)·
/// enum 순환·폰트 순환·색 프리셋 순환·팔레트 셀 이동·theme 프리셋 순환(dir=-1/+1)을 했다. **재설계로 ←→가 "영역
/// 포커스 이동"(←네비·→폼)이 되면서 `handle`이 더는 adjust를 방출하지 않아 죽었다**(테스트만 호출). 지우지 않은 건
/// "숫자·드롭다운도 ←→로 조절하면 일관적일까?" 결정이 **보류 중**이라 — ←→ adjust를 다시 넣기로 하면 이게 그 구현이다.
/// 현재 모델을 영구 확정하면 이 함수 + `applyThemePreset(dir)` + deprecated Action(slider_set/adjust_left/right)을 함께
/// 제거한다. (docs/config-gui.md §4 "←→ adjust 보류" 참조.)
pub fn adjustSelectedSetting(self: *AppSession, dir: i8) void {
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const cf = currentSectionFields(self, scratch.allocator()) catch return;
    const sel = self.chrome_host.settings.selected;
    if (sel < cf.bools.len) return; // bool 행 — ←/→ 무동작
    const after_nums = cf.bools.len + cf.nums.len;
    if (sel < after_nums) {
        // slider 행 — 한 스텝 조절.
        const n = cf.nums[sel - cf.bools.len];
        const span = n.max - n.min;
        const step = if (n.is_int) @max(@as(f64, 1), span * 0.04) else span * 0.04;
        const value = std.math.clamp(n.value + @as(f64, @floatFromInt(dir)) * step, n.min, n.max);
        if (config_mod.schema.setNumber(&self.loaded_config.config, n.key, value)) {
            reapplyLoadedConfig(self);
            markConfigKeyDirty(self, n.key);
        }
        return;
    }
    const after_enums = after_nums + cf.enums.len;
    if (sel < after_enums) {
        // enum(dropdown) 행 — ←/→ = 이전/다음 변형 순환. theme.preset은 synthetic(특수)이라 별도 적용.
        const e = cf.enums[sel - after_nums];
        if (std.mem.eql(u8, e.key, "theme.preset")) {
            applyThemePreset(self, dir);
        } else if (config_mod.schema.cycleEnum(&self.loaded_config.config, e.key, dir)) {
            reapplyLoadedConfig(self);
            markConfigKeyDirty(self, e.key);
        }
        return;
    }
    const after_texts = after_enums + cf.texts.len;
    const after_colors = after_texts + cf.colors.len;
    if (sel < after_texts) {
        // text 행 — font.family만 ←/→로 번들 폰트(theme.bundled_font_families) 순환(테마 프리셋처럼 키보드 선택).
        // 나머지 텍스트 필드는 ←/→ 무동작(편집은 Enter/클릭). 목록 밖 시스템·직접입력 폰트는 첫/마지막 항목으로
        // 진입한다(cycleFontFamily) — 커스텀 폰트 복귀는 Enter 직접입력.
        const t = cf.texts[sel - after_enums];
        if (std.mem.eql(u8, t.key, "font.family")) {
            if (config_mod.schema.cycleFontFamily(&self.loaded_config.config, dir)) {
                reapplyLoadedConfig(self);
                markConfigKeyDirty(self, "font.family");
            }
        }
        return;
    }
    if (sel >= after_texts and sel < after_colors) {
        // color 행 — ←/→ = 이전/다음 16색 프리셋 순환. 단 테마 프리셋 잠금이면 막는다(색을 풀려면 클릭으로
        // "사용자 지정" 전환해야 — ←/→로 슬쩍 바뀌는 혼란 방지).
        if (self.themePresetActive()) return;
        const ci = sel - after_texts;
        if (ci < cf.colors.len) {
            const c = cf.colors[ci];
            if (config_mod.schema.cycleColor(&self.loaded_config.config, c.key, dir)) {
                reapplyLoadedConfig(self);
                markConfigKeyDirty(self, c.key);
            }
        }
        return;
    }
    if (cf.paletteRowIndex()) |pi| if (sel == pi) {
        // 팔레트 그리드 행 — ←/→ = 선택 셀 이동(색 변경 아님, 재렌더만). 색 변경은 Enter→hex 편집.
        self.chrome_host.settings.moveGridCell(dir);
        return;
    };
    // keybind/global 행은 ←/→ 무동작(녹음은 Enter/클릭). text 행은 위 after_texts 분기에서 처리(font.family만 순환).
}

/// 세팅 GUI 라이브 재적용(토글·슬라이더·enum·색·배경 이미지·테마)의 공통 진입점. **런타임 ⌘+/− 줌을 보존한다** —
/// 폰트와 무관한 토글(커서 깜빡임 등)이 확대/축소를 리셋하지 않게(버그 수정). 통합 리셋(resetAllSettings)은 줌까지
/// config 기본으로 되돌려야 하므로 applyLoadedConfig(false)를 직접 부른다.
pub fn reapplyLoadedConfig(self: *AppSession) void {
    applyLoadedConfig(self, true);
    agent_ops.removeAgentStatuslineHook(self); // 토글을 껐으면 여기서 복원·제거까지 간다
    agent_ops.reconcileAgentHooks(self); // 훅 게이트도 여기서 설치·**제거**까지 간다(계약 §5 — 끄면 지운다)
}

/// reapplyLoadedConfig 본체. 메모리의 loaded_config(스키마 필드 in-place 변경)에서 appearance를 다시 resolve해 적용한다.
/// reloadConfig(파일 재로드)의 적용 단계만 떼어낸 것 — loaded_config를 교체/free하지 않으므로(같은 arena 유지)
/// appearance가 그 arena를 계속 빌려도 안전하다(reloadConfig의 swap-then-free 순서 가드는 불필요). resolve 실패면
/// 무동작(forgiving — appearance 보존). behavior 캐시·palette·scrollback·ambiguous-width·사이드바도 함께 갱신.
/// preserve_zoom이면 ⌘+/− 런타임 줌을 보존하고(applyAppearancePreservingZoom — 단 폰트 크기 자체가 바뀐 GUI
/// 변경이면 그 값이 사용자 의도라 줌을 안 얹는다), false면(통합 리셋) 줌까지 config 기본 크기로 되돌린다.
pub fn applyLoadedConfig(self: *AppSession, preserve_zoom: bool) void {
    const new_appearance = config_mod.resolveAppearance(self.loaded_config.config) catch return;
    // 사이드바 폭(sidebar.width, pt)을 메모리 config에서 되읽는다 — 세팅 GUI number 위젯·통합 리셋이 바꿨을 수 있다.
    // 아래 applyAppearance→applyMetricsPipeline→refreshCellMetrics 전에 세워야 clamp·px 환산·grid 재배치가 새 폭을
    // 따라간다. 드래그 write-back이 이 미러(loaded_config)도 갱신하므로 런타임↔config가 일치 → 되읽어도 사용자가
    // 끈 폭을 보존한다(reapply가 런타임 전용 override를 날리는 부류의 회피 — loaded_config 미러 경로).
    self.sidebar_width_pt = self.loaded_config.config.sidebar.width_pt;
    if (preserve_zoom)
        applyAppearancePreservingZoom(self, new_appearance)
    else
        applyAppearance(self, new_appearance); // 통합 리셋 — 줌도 config 기본 크기로(applyAppearance가 base=appearance=config)
    self.audible_bell = self.loaded_config.config.bell.audible;
    self.bell_visual = self.loaded_config.config.bell.visual;
    self.bell_dock_badge = self.loaded_config.config.bell.dock_badge;
    // **열려 있는 편집기에 새 탭 폭을 넣는다**(§9). 이 값은 캐시가 아니라 **파생값의 입력**이라
    // 스칼라 대입으로 끝나지 않는다 — 접힘 겹수·`max_cols`·가로 위치·행 수 캐시가 옛 폭으로
    // 계산돼 있고, 세터가 그것들을 한 단위로 버리고 보던 줄을 지킨다.
    editor_ops.applyConfigTabWidth(self);
    self.page_keys_scroll = self.loaded_config.config.input.page_keys == .scroll;
    self.shift_enter_meta = self.loaded_config.config.input.shift_enter == .newline;
    self.ime_enter_newline = self.loaded_config.config.input.ime_enter == .newline;
    self.option_as_meta = self.loaded_config.config.input.option_as_meta;
    reapplyUiLanguage(self);
    reapplyScrollback(self);
    reapplyConfigPalette(self);
    reapplyAmbiguousWidth(self);
    reapplyEmojiWidth(self);
    reapplyDefaultCursorShape(self);
    sidebar_ops.rebuildSidebar(self) catch {};
    // 커맨드 카탈로그는 여기서 재빌드하지 않는다 — reapplyLoadedConfig 자체는 keybindings/unbinds를 바꾸지 않는다
    // (GUI 토글·슬라이더·색 선택은 스키마 GUI 필드라 keybind 무관). keybind를 실제로 바꾸는 경로가 직접 재빌드한다:
    // rebind/unbindActionEntry·reloadConfig·resetAllSettings. **resetAllSettings는 keybind 4종을 빈 슬라이스로 비운 뒤**
    // applyLoadedConfig(false)로 재적용하고, 그 **뒤에** 자체적으로 rebuildCommandCatalog를 호출한다(#2-b). 즉 이 경로는
    // keybind-불변이라 여기서 카탈로그를 안 건드리는 게 맞고, reset의 keybind 변경 반영은 resetAllSettings의 명시 재빌드가 책임진다.
    self.metal_dirty = true;
}

/// 인라인 rename을 시작한다 — 대상의 현재 custom_name으로 편집기를 시드(없으면 빈 편집기 = 새 이름)하고 다른
/// 모달은 닫는다(배타적). 이후 키/IME는 모달 가드가 rename_input으로 라우팅한다. 대상은 dispatchAppAction이
/// 활성 워크스페이스/pane/Term으로 고른다(또는 PR4/PR5 클릭 대상).
pub fn startRename(self: *AppSession, target: RenameTarget) void {
    self.chrome_host.find.hide(); // rename은 별도 모달 — 열려 있던 오버레이를 닫는다(배타적)
    // **하이라이트도 멎어야 한다.** `hide()`는 오버레이만 지운다 — ⌘G 닫힘-네비 중이면
    // `find_nav`가 살아 있어 강조가 그대로 남는다(적대적 검증 2026-08-23 2라운드가 이 네 번째
    // 자리를 찾았다. 앞의 셋을 모으면서 여기를 빠뜨렸다).
    find_ops.clearAllFindMatches(self);
    self.chrome_host.palette.hide();
    self.rename_input.clear();
    // 현재 custom_name으로 시드(owned 문자열을 query에 복사) — 없으면 빈 편집기. auto title은 시드하지 않는다
    // (custom_name만 편집 대상). 사용자는 편집기에서 그대로 바꾸거나 지운다.
    const seed: ?[]const u8 = switch (target) {
        .workspace => |t| t.custom_name,
        .pane => |p| p.custom_name,
        .term => |t| t.surface.custom_name,
        .group => |t| t.group_start, // 그룹 이름 = group_start 마커
        .file_tree => |t| if (t.edit_kind == .rename) std.fs.path.basename(t.path()) else null,
    };
    if (seed) |s| self.rename_input.query.appendSlice(self.allocator, s) catch {};
    self.rename = target;
    self.resetCursorBlink();
    self.metal_dirty = true;
}

/// rename 편집 텍스트(query)를 대상 custom_name으로 확정한다 — 비면 custom_name을 지운다(이름 없음). 조합 중
/// preedit가 남아 있으면 먼저 query로 확정(IME 글자 손실 방지 — find와 같은 규율). 옛 owned custom_name을 free
/// 하고 새 owned 문자열로 교체. 그 뒤 편집기를 닫는다.
pub fn commitRename(self: *AppSession) void {
    const target = self.rename orelse return;
    _ = self.rename_input.commitPreedit(self.allocator); // 조합 잔여를 query로
    const text = self.rename_input.query.items;
    if (target == .file_tree) {
        if (file_panel_ops.enqueueFileTreeEdit(self, target.file_tree, text)) closeRename(self);
        return;
    }
    const old_name: []const u8 = switch (target) {
        .workspace => |t| t.custom_name orelse "",
        .pane => |p| p.custom_name orelse "",
        .term => |t| t.surface.custom_name orelse "",
        .group => |t| t.group_start orelse "",
        .file_tree => unreachable,
    };
    if (std.mem.eql(u8, old_name, text)) {
        closeRename(self);
        return;
    }
    // 빈 텍스트(의도적 삭제) → null. 비어있지 않은데 dupe가 OOM이면 **기존 이름을 보존**하고 편집기만 닫는다 —
    // catch null로 흡수하면 OOM과 '빈 이름'을 구분 못 해 입력한 이름이 통째로 사라진다(기존 이름까지 free).
    const new_name: ?[]const u8 = if (text.len == 0) null else (self.allocator.dupe(u8, text) catch {
        closeRename(self);
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
        .group => |t| {
            // 그룹 이름은 비어도 마커(group_start)를 지우지 않는다 — null이면 그룹이 사라지므로(§2.1) 빈 문자열로
            // 둔다(이름 없는 그룹 시작, 폴백 "그룹" 표시). 그룹 해제는 ungroup 액션이 담당(rename과 분리).
            if (t.group_start) |old| self.allocator.free(old);
            t.group_start = new_name orelse (self.allocator.dupe(u8, "") catch null);
            sidebar_ops.rebuildSidebar(self) catch {}; // 헤더 라벨 즉시 갱신
        },
        .file_tree => unreachable,
    }
    closeRename(self);
    self.workspaceChanged(.naming);
}

/// rename 편집기를 닫는다(취소·커밋 공통 종료) — 입력을 비우고 rename을 null로. custom_name은 안 건드린다
/// (취소면 원래 이름 유지, 커밋이면 위에서 이미 갱신). 대상 teardown 시 invalidate도 이 상태만 비우면 된다.
pub fn closeRename(self: *AppSession) void {
    if (self.rename == null) return;
    self.rename = null;
    self.rename_input.clear();
    self.resetCursorBlink();
    self.metal_dirty = true;
}

/// rename 활성 중 키 처리(모달 가드가 호출). Enter=확정·Esc=취소·Backspace=삭제·평문 글자=추가. 모디파이어
/// 글자·기타 키(↑↓ 등)는 무시해 편집기를 유지한다(텍스트 필드라 단축키를 뒤로 안 흘린다). IME 조합은
/// imeSetPreedit/imeEnd가 rename_input에 직접 넣는다(find/palette와 같은 경로).
pub fn handleRenameKey(self: *AppSession, ev: chrome.input.InputEvent) void {
    switch (ev) {
        .key => |k| switch (k.key) {
            .escape => closeRename(self),
            .enter => commitRename(self),
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
        .pointer => {}, // rename 텍스트 편집기는 포인터를 안 받는다(CS-4-0 — 모달 위젯 포인터는 chrome_host 경로).
    }
}

/// 점(x,y px)에 있는 rename 대상 — 사이드바 슬롯=워크스페이스, pane 라벨 세그먼트=pane, Term 탭=term. 없으면
/// null(터미널 본문·‹›/+·"+" 슬롯·바 밖). 더블클릭(kind 4)과 우클릭 메뉴가 공유해 **같은 자리를 같은 대상으로**
/// 친다(단일 출처). hit-test는 paneBar(full/tabs/label_cols)·barMetrics를 재사용.
pub fn renameTargetAt(self: *AppSession, x_px: f64, y_px: f64) ?RenameTarget {
    if (sidebar_ops.inSidebar(self, x_px)) {
        // 사이드바: 슬롯이면 그 워크스페이스. 단 우측 ✕(close) zone은 rename 대상 아님(닫기 자리에서 rename 방지).
        // "+" 슬롯/빈 영역은 sidebarSlotAt이 null이라 자연히 제외.
        if (sidebar_ops.sidebarSlotAt(self, y_px)) |slot| {
            // 그룹 헤더 더블클릭 → 그룹 이름 rename(rename_group과 같은 대상). onGroupHeader가 헤더/카드를 가른다.
            if (chrome.components.sidebar.onGroupHeader(self.sidebar_rows.items, slot)) {
                const gh = self.sidebar_rows.items[slot].group_header;
                if (gh.tab < self.tabs.items.len) return .{ .group = self.tabs.items[gh.tab] };
                return null;
            }
            if (sidebar_ops.sidebarCloseButtonAt(self, x_px)) return null;
            if (tab_ops.visibleTab(self, slot)) |tab_idx| return .{ .workspace = self.tabs.items[tab_idx] }; // 표시 슬롯 → 원본(검색 필터)
        }
        return null;
    }
    var leaf_rects: std.ArrayList(PaneTree.LeafRect) = .empty;
    defer leaf_rects.deinit(self.allocator);
    tab_ops.activeTabLeafRects(self, self.allocator, self.termRect(), &leaf_rects) catch return null;
    for (leaf_rects.items) |lr| {
        const pb = pane_ops.paneBar(self, lr.rect, lr.leaf) orelse continue;
        if (!layout_math.pointInRect(x_px, y_px, pb.full)) continue;
        // 좌측 grip+라벨 세그먼트 → 그 pane(grip은 항상 예약돼 더블/우클릭 rename 대상도 grip 영역 포함).
        if ((pb.grip_cols > 0 or pb.label_cols > 0) and x_px < @as(f64, @floatFromInt(pb.tabs.x))) return .{ .pane = lr.leaf };
        const count = lr.leaf.terms.items.len;
        const m = barMetrics(pb.tabs, self.cell_width_px, count, self.buildChromeTokens().space.tab_width_cols, lr.leaf.tab_scroll_cols) orelse return null;
        if (m.inScrollLeftZone(x_px) or m.inScrollRightZone(x_px) or m.inPlusZone(x_px)) return null; // ‹›/+ 은 대상 아님
        const tab = m.tabIndex(count, x_px);
        if (m.inCloseZone(tab, x_px)) return null; // 탭 우측 ✕(close) zone은 rename 대상 아님
        // 보이는 순서에서 고른다 — 드래그 중이면 사용자가 본 자리가 preview이고, rename은 그 제스처를
        // 취소하지 않으므로 model 순서로 고르면 눌린 것과 다른 탭이 대상이 된다(§4.4 "paint와 hit-test가 함께").
        const order = pane_ops.paneTermOrder(self, lr.leaf);
        if (tab < order.len) return .{ .term = order[tab] };
        return null;
    }
    return null;
}

/// 현재 컨텍스트 메뉴 대상에 맞는 항목 라벨을 buf에 채우고 슬라이스 반환. workspace = Rename + Pin/Unpin + 배경
/// 프리셋 + 그룹 액션/색, group(헤더) = Rename + 그룹 풀기 + 그룹 색, pane/term = Rename만. show가 호출해 len을
/// 박고, itemAt/draws/accept가 contextMenuItems로 같은 리스트를 본다.
pub fn buildContextMenuItems(self: *AppSession) []const []const u8 {
    var n: usize = 0;
    self.context_menu_items_buf[n] = "Rename";
    n += 1;
    if (self.context_menu_target) |t| if (std.meta.activeTag(t) == .workspace) {
        // 카드 pin 라벨 = cardPinRole 단일 판정(dispatch와 공유, ctx_menu_pin=1 인덱스 고정). GL §13 GL2 세 컨텍스트:
        //  · 마커 카드(.group) = 그룹째 고정(헤더 동형, 개별 pin이면 C2 캐시 권위 §12.2가 깨져 그룹째가 유일 안전)
        //  · 비마커 멤버(.local) = **그룹 내 위치 고정**(toggleLocalPin, 현행 그룹째 위임 되돌림 — 그룹-로컬 축)
        //  · 최상위 카드(.individual) = 개별 전역 위치 고정(togglePin, 현행)
        self.context_menu_items_buf[n] = switch (tab_ops.cardPinRole(self, t.workspace)) {
            .group => if (tab_ops.enclosingGroupMarkerTab(self, t.workspace)) |mk|
                (if (mk.pinned) maru.i18n.t(.ctx_group_unpin) else maru.i18n.t(.ctx_group_pin))
            else
                (if (t.workspace.pinned) maru.i18n.t(.ctx_unpin) else maru.i18n.t(.ctx_pin)),
            .local => if (t.workspace.local_pinned) maru.i18n.t(.ctx_local_unpin) else maru.i18n.t(.ctx_local_pin),
            .individual => if (t.workspace.pinned) maru.i18n.t(.ctx_unpin) else maru.i18n.t(.ctx_pin),
        };
        n += 1;
        for (tab_bg_labels) |lbl| {
            self.context_menu_items_buf[n] = lbl;
            n += 1;
        }
        for (tab_accent_labels) |lbl| { // 좌측 accent 막대색(배경과 직교) — ctx_menu_accent_first부터
            self.context_menu_items_buf[n] = lbl;
            n += 1;
        }
        // 사이드바 그룹(SG3c·SG5-3) — 위치 파생 마커(group_start) 세팅/제거(단축키·팔레트와 같은 세션 메서드).
        // 항상 노출(pin처럼 인덱스 고정) — ungroup은 그룹에 안 속하면 no-op이라 안전. "새 그룹으로 묶기"=중첩(depth+1),
        // "형제 그룹으로 분리"=같은 depth 형제(SG5-3, 명시적 분리 — 그룹 안 카드에서 형제 최상위/형제 그룹 생성).
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_group_create); // ctx_menu_group_create
        n += 1;
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_group_sibling); // ctx_menu_group_sibling
        n += 1;
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_group_ungroup); // ctx_menu_group_ungroup
        n += 1;
        for (tab_group_color_labels) |lbl| { // 그룹 공통 색(SG5-2) — ctx_menu_group_color_first부터. 소속 그룹 마커에 색 세팅
            self.context_menu_items_buf[n] = lbl;
            n += 1;
        }
        // "그룹에서 빼기"(remove_from_group) — **그룹 소속 카드에만** 맨 끝에 붙인다(최상위 카드엔 안 뜸 — tabIsInGroup).
        // ungroup(그룹 통째 해제)과 달리 이 카드 하나만 최상위로 뺀다. 맨 끝 조건부라 앞 고정 인덱스를 안 흔든다(sel==ctx_menu_group_remove).
        if (tab_ops.tabIsInGroup(self, t.workspace)) {
            self.context_menu_items_buf[n] = maru.i18n.t(.ctx_group_remove); // ctx_menu_group_remove
            n += 1;
            // "여기서 최상위로 분리"(promote-in-place, §14.5·§14.7) — remove 바로 뒤. removeFromGroup(그룹 밖 이동+unpin)과
            // 달리 **제자리** top_level만 세팅(위치·pin 불변 — 고정 top카드 가능). **마커 카드(group_start!=null)에선 숨긴다**
            // (§14.8 SR5 결정 (a)): promoteTabToTopLevelInPlace가 leaf-only(§13.8)상 마커에 no-op이라, 뜨면 "눌러도 무동작"인
            // 죽은 항목이 된다(remove는 마커에서도 nested subgroup 빼기로 유효해 유지). 조건부라 마커면 promote 슬롯이 비어
            // 메뉴가 한 칸 짧아지고(ctx_menu_group_remove까지), sel이 ctx_menu_group_promote에 절대 도달 못 해 인덱스가 안 흔들린다.
            if (t.workspace.group_start == null) {
                self.context_menu_items_buf[n] = maru.i18n.t(.ctx_group_promote); // ctx_menu_group_promote
                n += 1;
            }
        }
    };
    // 그룹 헤더 우클릭(SG5-2-header) — 대상은 group_start 마커 탭(renameTargetAt). 헤더 스코프 액션만: Rename(0)=그룹
    // 이름 편집은 위에서 이미 넣었고, 여기서 "그룹 풀기"(ungroup)와 "그룹 색: …" 프리셋을 붙인다. 색 라벨/팔레트/세팅은
    // 카드 메뉴와 같은 인프라(tab_group_color_labels·tab_color_presets·setGroupColorForTab)를 재사용해 같은 색 메뉴를 공유한다.
    if (self.context_menu_target) |t| if (std.meta.activeTag(t) == .group) {
        // 그룹 고정/해제(toggleGroupPin — GP3 §12.10). 마커 pinned = 그룹 고정 권위(§12.2)라 헤더에서 그룹째 토글한다.
        self.context_menu_items_buf[n] = if (t.group.pinned) maru.i18n.t(.ctx_group_unpin) else maru.i18n.t(.ctx_group_pin_header); // ctx_group_menu_pin
        n += 1;
        self.context_menu_items_buf[n] = maru.i18n.t(.ctx_group_ungroup); // ctx_group_menu_ungroup
        n += 1;
        for (tab_group_color_labels) |lbl| { // 그룹 색 프리셋 — ctx_group_menu_color_first부터(카드 메뉴와 같은 라벨)
            self.context_menu_items_buf[n] = lbl;
            n += 1;
        }
    };
    self.context_menu_items_len = n;
    return self.context_menu_items_buf[0..n];
}

pub fn contextMenuItems(self: *const AppSession) []const []const u8 {
    return self.context_menu_items_buf[0..self.context_menu_items_len];
}

/// view options(⚙) 메뉴 항목 — 사이드바 카드 표시 토글. 라벨 체크마크 prefix로 현재 on/off를 보인다(✓+공백=표시,
/// 공백 2칸=숨김 — EAW 폭 정렬). 이름줄은 항상 표시라 토글 없음(사용자 요청). rename 메뉴와 같은 context_menu_items_buf·
/// itemAt/draws/accept 경로를 공유하고, 분기는 view_options_menu 플래그로 한다. 라벨은 정적 리터럴이라 소유 불요.
pub fn buildViewOptionsMenuItems(self: *AppSession) []const []const u8 {
    const sb = self.loaded_config.config.sidebar;
    // **라벨은 이름만, 켜짐은 상태로**(i18n 계약 §6.2). 예전에는 `"✓ 브랜치 표시"` / `"  브랜치 표시"`
    // 두 문자열을 만들어 넘겼는데, 그러면 기호와 정렬 공백이 번역 단위에 섞이고 켜짐 여부가 문자열
    // 비교로만 드러난다. 기호는 컴포넌트가 `checked_mask` 를 보고 그린다.
    self.context_menu_items_buf[0] = maru.i18n.t(.set_show_branch);
    self.context_menu_items_buf[1] = maru.i18n.t(.set_show_folder);
    self.context_menu_items_len = 2;
    self.chrome_host.context_menu.checked_mask =
        (@as(u64, @intFromBool(sb.show_branch)) << 0) | (@as(u64, @intFromBool(sb.show_folder)) << 1);
    return self.context_menu_items_buf[0..2];
}

/// 터미널 본문 우클릭 메뉴 항목(input.right-click=menu) — 복사/붙여넣기. rename·view_options와 같은
/// context_menu_items_buf·itemAt/draws/accept 경로를 공유하고 분기는 terminal_context_menu 플래그로 한다(F2-5).
pub fn buildTerminalContextMenuItems(self: *AppSession) []const []const u8 {
    self.context_menu_items_buf[0] = maru.i18n.t(.ctx_copy);
    self.context_menu_items_buf[1] = maru.i18n.t(.ctx_paste);
    self.context_menu_items_len = 2;
    return self.context_menu_items_buf[0..2];
}

/// 본문 우클릭 → 메뉴를 연다. 좌표는 shell 뷰포트 CSS px이라 그 web surface rect + backing scale로 창 좌표를 만든다.
/// **모드는 web에서 받지 않는다** — 그 Term의 entry가 이미 안다(두 출처가 갈리지 않게).
pub fn openFileContentMenu(
    self: *AppSession,
    surface_id: u64,
    request: maru.session.control_bridge.MenuRequest,
) !void {
    const entry = file_panel_ops.fileEntryForSurfaceId(self, surface_id) orelse return error.Unsupported;
    var buf: [content_menu.max_items]content_menu.Item = undefined;
    const items = content_menu.build(request.target, entry.mode, request.has_selection, &buf);
    if (items.len == 0) return; // 낼 항목이 없으면 빈 메뉴를 띄우지 않는다

    const rect = web_ops.webSurfaceRect(self, surface_id) orelse return error.Unsupported;
    const scale: f64 = @as(f64, @floatFromInt(@max(@as(u32, 1), self.scale_milli))) / 1000.0;
    // 좌표는 rect 안으로 clamp한다 — 렌더러가 준 값이라 뷰 밖을 가리킬 수 있고, 그러면 메뉴가 자기 문서와
    // 무관한 자리에 뜬다. clamp는 "고쳐서 통과"가 아니라 **이 surface 안에서만 뜬다**는 계약이다.
    const x = std.math.clamp(
        @as(f64, @floatFromInt(rect.x)) + request.x * scale,
        @as(f64, @floatFromInt(rect.x)),
        @as(f64, @floatFromInt(rect.x + rect.w)),
    );
    const y = std.math.clamp(
        @as(f64, @floatFromInt(rect.y)) + request.y * scale,
        @as(f64, @floatFromInt(rect.y)),
        @as(f64, @floatFromInt(rect.y + rect.h)),
    );

    closeContextMenu(self); // 열려 있던 다른 메뉴가 있으면 먼저 정리(대상·플래그 배타)
    var state: FileContentMenu = .{ .surface_id = surface_id, .editor_epoch = request.editor_epoch };
    if (request.href.len > 0) state.href = self.allocator.dupe(u8, request.href) catch &.{};
    for (items, 0..) |item, i| {
        self.context_menu_items_buf[i] = item.label();
        state.items[i] = item;
    }
    state.len = items.len;
    self.context_menu_items_len = items.len;
    self.file_content_menu = state;
    self.chrome_host.context_menu.show(@intFromFloat(x), @intFromFloat(y), items.len);
    self.metal_dirty = true;
}

/// web이 실행할 메뉴 동작을 drain한다(있으면 그 동작, 비우고). Swift가 매 tick 호출한다.
pub fn takeFileMenuAction(self: *AppSession) ?FileMenuAction {
    const action = self.pending_file_menu_action;
    self.pending_file_menu_action = null;
    return action;
}

/// 터미널 본문 (x,y backing px)에 복사/붙여넣기 컨텍스트 메뉴를 띄운다(input.right-click=menu). 항목 선택은
/// acceptContextMenu가 terminal_context_menu 분기로 pending_clipboard_action을 세운다(Swift가 OS 클립보드 실행).
/// 편집기 본문 우클릭 메뉴를 연다(NS4). 열렸으면 true — 호출자가 그때 이벤트를 소비한다.
///
/// **항목 정책은 `session/content_menu.zig` 가 소유한다**(파일 패널 웹이 쓰는 그 모듈). 두 표면이
/// 같은 메뉴를 다른 규칙으로 채우면 사용자가 "여기서는 되는데 저기서는 안 되네" 를 겪는다 —
/// [선택 영역 보내기](../../../../docs/send-selection-to-agent.md) 가 "그 뒤는 한 벌" 로 정한 것과
/// 같은 결이다.
///
/// **선택이 없어도 복사를 낸다.** 편집기의 복사는 선택이 없으면 caret 이 있는 줄을 담으므로
/// (문서 모델 §3.4), 그 자리에서 항목을 감추면 `⌘C` 와 메뉴가 서로 다른 말을 한다.
/// 보내기 구획의 머리글을 만든다 — 고정 문구에 **잘린 수**와 **주 선택만 감**을 덧붙인다.
///
/// 자리에 안 들어가면 **덧말을 버리고 기본 문구**로 떨어진다. 잘린 머리글은 다른 말로 읽히므로
/// 자르지 않는다(`writeLabel` 이 라벨에 쓰는 그 규율과 같다).
/// 판정자용 진입점 — 위 머리글 조립을 제품 경로 그대로 부른다. 판정자가 이 함수를 못 부르면
/// 「잘린 수를 말한다」는 계약을 잴 수 없고, 잴 수 없는 계약은 계약이 아니라 우연이다.
pub fn testSendSelectionHeader(
    self: *AppSession,
    source: *app_session_mod.Term,
    collected: term_ops.AgentTargets,
) []const u8 {
    return sendSelectionHeader(self, source, collected);
}

fn sendSelectionHeader(
    self: *AppSession,
    source: *app_session_mod.Term,
    collected: term_ops.AgentTargets,
) []const u8 {
    const base = maru.i18n.t(.ctx_send_selection);
    const truncated = collected.eligible > collected.items.len;
    const multi = source.rt.editor_extra_selections.len > 0;
    if (!truncated and !multi) return base;

    // **서식은 `i18n.format` 이 푼다** — `Writer.print` 는 comptime 서식 문자열을 요구하는데
    // `i18n.t` 는 런타임 값이다. 그리고 위치 자리표시자(`{0}`)라야 어순이 다른 언어에서 수가
    // 제자리를 지킨다(그 계약의 판정자가 `i18n.zig` 에 있다).
    var writer = std.Io.Writer.fixed(&self.agent_send_header_buf);
    writer.writeAll(base) catch return base;
    if (truncated) {
        var tail_buf: [64]u8 = undefined;
        writer.writeAll(maru.i18n.format(&tail_buf, maru.i18n.t(.ctx_send_selection_truncated), &.{
            .{ .d = @intCast(collected.items.len) },
            .{ .d = @intCast(collected.eligible) },
        })) catch return base;
    }
    if (multi) writer.writeAll(maru.i18n.t(.ctx_send_selection_primary_only)) catch return base;
    return writer.buffered();
}

pub fn showEditorContextMenu(self: *AppSession, term: *app_session_mod.Term, x_px: f64, y_px: f64) bool {
    if (term.kind != .editor) return false;
    if (term.rt.editor_diff != null) return false; // 비교 뷰는 이 메뉴의 대상이 아니다(§8.1 대상 판정)
    const doc = term.rt.editor_doc orelse return false;

    var buf: [maru.session.content_menu.max_items]maru.session.content_menu.Item = undefined;
    const built = maru.session.content_menu.build(
        .text,
        if (doc.file.read_only) .read else .source_edit,
        true, // 위 주석 — 편집기는 선택이 없어도 복사·잘라내기 대상이 있다
        &buf,
    );
    if (built.len == 0) return false;

    var stored: @typeInfo(@FieldType(AppSession, "editor_context_menu")).optional.child = .{
        .surface_id = term.surface.id,
        .items = undefined,
        .len = @min(built.len, 4),
    };

    // ── 보내기 구획(NS5 — §5). **머리글 + 대상 줄들이고 위에 온다.**
    //
    // 컴포넌트는 머리글을 **앞에서만** 센다(`header_count`) — 가운데에 고를 수 없는 줄을 둘 방법이
    // 없다. 그래서 §5.1 의 모양(라벨 + 그 아래 대상들)을 지키려면 이 구획이 위로 온다. 아래에 두고
    // 라벨 없이 대상만 나열하면 `→ Claude` 가 "그쪽으로 전환" 으로도 읽힌다.
    //
    // **보낼 것이 없으면 구획도 없다** — 편집기 하나만 열린 창에서 머리글만 뜨면 그 줄이 "눌러도
    // 아무 일 없는 줄" 이 된다.
    var target_buf: [app_session_mod.max_agent_targets]maru.session.agent_selection.Candidate = undefined;
    // 폴더 문자열이 살 자리 — 후보가 라벨로 굳을 때까지 살아 있어야 한다(스택이지만 이 함수가
    // 끝나기 전에 `writeLabel` 이 전부 복사한다).
    var folder_bufs: [app_session_mod.max_agent_targets][std.fs.max_path_bytes]u8 = undefined;
    const collected = term_ops.collectAgentTargets(self, &target_buf, &folder_bufs);
    const targets = collected.items;
    var row: usize = 0;
    if (targets.len > 0) {
        // **머리글이 두 가지 사실을 진다.**
        //
        // ⑴ 자리를 넘겨 **잘린** 대상이 있으면 그 수를 말한다. 안 말하면 아홉 번째 pane 이 목록에
        //    없다는 것도, 왜 없는지도 알 방법이 없다 — 옛 판은 그냥 `break` 였다.
        // ⑵ 멀티 커서면 **주 선택만** 간다(`buildSelectionPayload` §3). 그 코드가 스스로
        //    「조용히 첫 조각만 보내면 사용자는 나머지가 갔다고 믿는다」고 적어 두었는데, 정작
        //    사용자에게 말하는 자리가 없었다. 여기가 그 자리다.
        //
        // 뒤에 줄을 못 단다 — 컴포넌트는 머리글을 **앞에서만** 세므로(위 §5 주석) 가운데·끝에
        // 고를 수 없는 줄을 둘 방법이 없다. 그래서 머리글 자체에 싣는다.
        self.context_menu_items_buf[row] = sendSelectionHeader(self, term, collected);
        row += 1;
        // **줄과 id 의 1:1 은 `writeRows` 가 든다** — 여기서 두 배열을 각자 채우다가 어긋났었다
        // (라벨이 자리에 안 들어가면 줄만 건너뛰고 목록에는 남겨, 그 뒤가 한 칸씩 밀렸다).
        // 라벨은 **행마다 자기 버퍼**를 쓴다 — 공유 버퍼 하나면 다음 행이 앞 행을 덮는다.
        var label_bufs: [app_session_mod.max_agent_targets][]u8 = undefined;
        for (&label_bufs, 0..) |*b, i| b.* = &self.agent_target_label_buf[i];
        const stored_n = maru.session.agent_selection.writeRows(
            targets,
            &label_bufs,
            stored.targets[0..],
            self.context_menu_items_buf[row..][0..app_session_mod.max_agent_targets],
        );
        row += stored_n;
        stored.target_len = stored_n;
        stored.send_rows = if (stored_n == 0) 0 else row; // 대상이 하나도 못 실렸으면 머리글도 뺀다
        if (stored_n == 0) row = 0; // 머리글 줄을 되돌린다 — 눌러도 아무 일 없는 줄을 남기지 않는다
    }

    for (built[0..stored.len], 0..) |item, i| {
        stored.items[i] = item;
        self.context_menu_items_buf[row + i] = item.label();
    }
    self.context_menu_items_len = row + stored.len;
    self.editor_context_menu = stored;
    self.chrome_host.context_menu.showWithHeaders(
        @intFromFloat(x_px),
        @intFromFloat(y_px),
        self.context_menu_items_len,
        if (stored.send_rows > 0) 1 else 0, // 머리글 한 줄만 고를 수 없다
    );
    // **마지막으로 보낸 대상이 아직 있으면 그 줄에서 시작한다**(§5 — "다음 호출의 기본값").
    // `show` 는 첫 고를 수 있는 줄을 고르므로 그 뒤에 덮어쓴다. 그 Term 이 닫혔으면 못 찾고
    // 기본값 그대로다.
    if (self.last_agent_target) |last| {
        for (stored.targets[0..stored.target_len], 0..) |id, i| {
            if (id != last) continue;
            self.chrome_host.context_menu.selected = 1 + i; // 머리글 한 줄
            break;
        }
    }
    self.metal_dirty = true;
    return true;
}

pub fn showTerminalContextMenu(self: *AppSession, x_px: f64, y_px: f64) void {
    self.terminal_context_menu = true;
    const items = buildTerminalContextMenuItems(self);
    self.chrome_host.context_menu.show(@intFromFloat(x_px), @intFromFloat(y_px), items.len);
    self.metal_dirty = true;
}

/// 컨텍스트/뷰옵션/터미널 메뉴 공통 teardown — hide + 대상·플래그 비움. 바깥 클릭·Esc 경로가 공유한다.
pub fn clearBranchMenuText(self: *AppSession) void {
    // **해제와 닫기를 묶는다.** 메뉴 항목(`context_menu_items_buf`)이 이 버퍼를 빌리므로, 열린 채로 해제하면
    // 다음 draw가 해제된 메모리를 읽는다. 재발행이 늘 뒤따르지도 않는다 — 새 목록이 0개면 `openBranchMenu`가
    // 알림만 띄우고 돌아온다.
    // **기준 목록도 같은 버퍼를 빌린다**(§3.5 — 도크 `∨`에서 갈라져 나온 목록이라 이름 슬라이스의
    // 출처가 같다). 이 조건에 그쪽을 빠뜨리면 그 메뉴가 열린 채 버퍼가 해제돼 같은 UAF가 난다 —
    // 위 주석이 막으려던 것과 **한 글자도 다르지 않은 상황**이고, 플래그만 다르다.
    if (self.branch_menu_open or self.scm_base_menu_open) closeContextMenu(self);
    if (self.branch_menu_text.len > 0) self.allocator.free(self.branch_menu_text);
    self.branch_menu_text = &.{};
    self.branch_menu_len = 0;
}

/// 상태바 브랜치 항목에서 브랜치 목록을 **요청**한다. 결과는 다음 tick에 `drainGitStatus`가 걷어 메뉴를 연다.
/// git 실행은 백엔드 스레드라 클릭이 UI를 멈추지 않는다.
pub fn requestBranchMenu(self: *AppSession, purpose: app_session_mod.BranchMenuPurpose) void {
    if (self.branch_menu_pending) return; // 연타로 프로세스가 쌓이지 않게
    // **용도를 요청과 함께 기억한다**(§3.5). 결과 슬롯이 하나라 도착한 목록만 보고는 어느 클릭의 답인지
    // 알 수 없다 — 기준을 고르려고 연 목록이 전환 메뉴로 열리면 고른 이름이 터미널에 들어간다.
    self.branch_menu_purpose = purpose;
    // 백엔드는 **지연 생성**이다(소스 컨트롤을 연 적 없으면 없다). 없으면 조용히 무시되던 것을 여기서 만든다 —
    // `refreshGitStatus`와 같은 규율. 안 그러면 도크를 한 번도 안 연 사용자에겐 브랜치 클릭이 아무 일도 안 한다.
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch {
            self.showNoticeKey(.set_git_backend_start_failed);
            return;
        };
    }
    var backend = &(self.git_backend orelse return);
    var exe_buf: [1024]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse {
        self.showNoticeKey(.set_git_not_found);
        return;
    };
    var repo_buf: [1024]u8 = undefined;
    // **도크의 빈 안내와 같은 3-상태 구분을 쓴다**(editor-surface-dock.md "빈 상태"). `gitRepoRoot`는
    // "저장소가 아니다"(`.none`)와 "물어볼 곳이 없다"(`.unknown` — 원격 세션·파일 Term)를 같은 null로
    // 뭉개므로, 그걸로 안내를 고르면 저장소 안에 서 있는 사용자에게 없는 사실을 단정한다. 도크만 고치고
    // 이 경로를 놓쳤던 것을 적대적 검증에서 잡았다 — 안내를 내는 소비처는 전수로 같은 구분을 써야 한다.
    const repo = switch (git_ops.gitRepoTarget(self, &repo_buf)) {
        .repo => |found| found,
        .none => {
            self.showNotice(git_ops.noticeNotARepo());
            return;
        },
        .unknown => {
            self.showNotice(git_ops.noticeRepoUnknown());
            return;
        },
    };
    self.git_request_seq +%= 1;
    const kind: git_command.Kind = switch (purpose) {
        // 전환 목록은 로컬 브랜치만이다 — 원격 추적 ref로 checkout하면 detached HEAD가 된다.
        .switch_branch => .branches,
        // 기준 후보는 원격 추적 ref까지다: `origin/HEAD`가 없는 저장소에서 고르고 싶은 이름이 보통 거기 있다.
        .pick_base => .base_candidates,
    };
    if (backend.submitBranches(git_exe, repo, kind, self.git_request_seq)) self.branch_menu_pending = true;
}

/// 걷은 목록으로 메뉴를 연다. 앵커는 **상태바 브랜치 항목 위**다 — 메뉴는 위로 펼쳐야 바에 가리지 않는다.
pub fn openBranchMenu(self: *AppSession) void {
    if (self.branch_menu_len == 0) {
        self.showNoticeKey(.set_no_branches);
        return;
    }
    // **앵커가 있어야 연다.** 목록 읽기는 비동기라 그 사이 바가 사라질 수 있다(`status-bar.show` 끄기·
    // quick terminal 전환). 그때 열면 앵커 없이 창 바닥에 붙어, 사용자는 누른 적 없는 메뉴를 보게 된다.
    // 조용히 접는 게 맞다 — 클릭 대상이 화면에 없으므로 알릴 것도 없다.
    var anchor_x: f64 = 0;
    var anchor_y: f64 = 0;
    var anchored = false;
    for (self.statusBarTree().entries) |e| {
        if (e.id != @intFromEnum(chrome.components.status_bar.ItemId.git_branch)) continue;
        anchor_x = e.rect.x;
        anchor_y = e.rect.y;
        anchored = true;
    }
    if (!anchored) return;
    closeContextMenu(self);
    for (self.branch_menu_names[0..self.branch_menu_len], 0..) |name, i| self.context_menu_items_buf[i] = name;
    self.context_menu_items_len = self.branch_menu_len;
    self.branch_menu_open = true;
    self.chrome_host.context_menu.show(@intFromFloat(anchor_x), @intFromFloat(anchor_y), self.branch_menu_len);
    self.metal_dirty = true;
}

/// 고른 브랜치를 **활성 터미널에 명령으로 넣어 준다.** 우리가 checkout을 실행하지 않는 이유는
/// `docs/editor-surface-tooling.md` §6의 읽기 전용 계약이다 — hook 실행·index 쓰기는 그 밖이고, 실행 주체가
/// 셸이어야 dirty tree·충돌·hook 출력이 평소처럼 사용자에게 보인다. 엔터는 사용자가 친다.
pub fn applyBranchMenuSelection(self: *AppSession, index: usize) void {
    if (index >= self.branch_menu_len) return;
    const name = self.branch_menu_names[index];
    var buf: [512]u8 = undefined;
    const cmd = git_command.branchSwitchCommand(name, &buf) orelse {
        self.showNoticeKey(.set_branch_name_invalid);
        return;
    };
    self.pasteText(cmd, false);
}

pub fn closeContextMenu(self: *AppSession) void {
    self.chrome_host.context_menu.hide();
    self.context_menu_target = null;
    self.file_tree_context_target = null;
    self.file_tree_background_menu = false;
    self.view_options_menu = false;
    self.terminal_context_menu = false;
    // **값 자체를 비운다** — 이 메뉴는 플래그가 아니라 대상(surface id)과 굳힌 항목을 든다.
    // 남겨 두면 다음 우클릭이 다른 메뉴를 열어도 accept 가 이 분기로 먼저 들어온다.
    self.editor_context_menu = null;
    self.branch_menu_open = false; // 목록 텍스트는 다음 요청까지 살려 둔다(재열기 비용 절약)
    self.scm_remote_menu_open = false; // 도크 `∨`도 같은 규율(P6b)
    // **항목 표는 여기서 지우지 않는다.** accept 경로가 **닫은 뒤에** 고른 자리를 뜻으로 되돌리기
    // 때문이다(브랜치 목록 텍스트를 살려 두는 것과 같은 이유). 표는 열 때마다 다시 만들고, 그 사이
    // 열려 있다는 플래그가 없으면 accept가 이 분기로 오지 않는다.
    self.scm_base_menu_open = false; // 그 `∨`에서 갈라져 나온 기준 목록(§3.5)
    self.resource_menu_open = false; // 얼린 행 순서도 여기서 놓는다(다음에 열 때 다시 정렬한다)
    self.resource_menu_len = 0;
    self.agent_menu_open = false; // 에이전트 팝오버도 같은 규율 — 플래그를 빠뜨리면 다음 메뉴의 accept가 엉뚱한 분기로 간다
    self.agent_menu_len = 0;
    clearFileContentMenu(self);
    self.metal_dirty = true;
}

/// 파일 본문 메뉴 상태를 비운다(§2.6). 메뉴를 닫는 **모든** 경로가 이걸 지나야 href가 새지 않는다 —
/// 바깥 클릭·Esc(`closeContextMenu`)와 오버레이 일괄 정리(`dismissMessageOverlays`) 둘 다 소유자다.
pub fn clearFileContentMenu(self: *AppSession) void {
    const menu = self.file_content_menu orelse return;
    if (menu.href.len > 0) self.allocator.free(menu.href);
    self.file_content_menu = null;
}

/// 컨텍스트 메뉴의 선택 항목을 실행한다. 0=Rename(모든 대상), workspace는 1=위치 고정 토글·bg_first..=배경 tint 프리셋·accent_first..=좌측 막대색 프리셋.
/// 메뉴를 먼저 닫고(대상 teardown 시 context_menu_target은 이미 null화됨) selected로 분기한다.
pub fn acceptContextMenu(self: *AppSession) void {
    // 리소스 팝오버 — 고른 행의 Term으로 점프하고 닫는다. 점프는 `activateSurfaceById` 단일 출처
    // (알림 클릭이 쓰는 그 경로: switchTab → focusPaneByPtr → focusTerm). 닫힌 탭이면 false라 무동작.
    if (self.resource_menu_open) {
        const selected = self.chrome_host.context_menu.selected;
        // 선택 인덱스는 **머리글을 포함한** 행 번호다 — 빼지 않으면 한 칸 밀린 탭으로 점프한다.
        const row = selected -| app_session_mod.resource_header_rows;
        const key: ?u64 = if (selected >= app_session_mod.resource_header_rows and row < self.resource_menu_len)
            self.resource_menu_keys[row]
        else
            null;
        closeContextMenu(self); // 먼저 닫는다 — 점프 뒤 메뉴가 남지 않게
        if (key) |k| _ = self.activateSurfaceById(k);
        return;
    }
    // 에이전트 팝오버 — 고른 행의 Term으로 점프한다. 리소스와 **같은 경로**이고, 인덱스에서 머리글을 빼는
    // 규율도 같다(빼지 않으면 한 칸 밀린 탭으로 간다).
    if (self.agent_menu_open) {
        const selected = self.chrome_host.context_menu.selected;
        const row = selected -| app_session_mod.agent_header_rows;
        const key: ?u64 = if (selected >= app_session_mod.agent_header_rows and row < self.agent_menu_len)
            self.agent_menu_keys[row]
        else
            null;
        closeContextMenu(self);
        if (key) |k| _ = self.activateSurfaceById(k);
        return;
    }
    // 도크 브랜치 줄의 `∨`(P6b) — 고른 명령을 터미널에 넣고 닫는다. 브랜치 목록과 같은 규율이다.
    if (self.scm_remote_menu_open) {
        const selected = self.chrome_host.context_menu.selected;
        closeContextMenu(self); // 먼저 닫는다 — 주입한 명령이 메뉴에 가리지 않게
        scm_dock_ops.applyRemoteMenuSelection(self, selected);
        return;
    }
    // 기준 브랜치 목록(§3.5) — `∨` 메뉴에서 갈라져 나왔고 브랜치 전환 목록과 **같은 버퍼**를 쓴다.
    // 그래서 전환 분기보다 먼저 본다: 뒤에 두면 두 플래그가 함께 서는 순간 고르기만 하려던 이름이
    // `git switch`로 터미널에 들어간다.
    if (self.scm_base_menu_open) {
        const selected = self.chrome_host.context_menu.selected;
        closeContextMenu(self);
        scm_dock_ops.applyBaseMenuSelection(self, selected);
        return;
    }
    // 브랜치 목록이 그다음이다 — 다른 메뉴 상태와 배타이고, 고른 이름을 터미널에 넣고 닫는다.
    if (self.branch_menu_open) {
        const selected = self.chrome_host.context_menu.selected;
        closeContextMenu(self); // 먼저 닫는다 — 주입한 명령이 메뉴에 가리지 않게
        applyBranchMenuSelection(self, selected);
        return;
    }
    // 터미널 본문 우클릭 메뉴(input.right-click=menu): 0=복사·1=붙여넣기 → pending_clipboard_action을 세워 Swift가
    // OS 클립보드 동작을 한다. 메뉴를 닫고 return(rename·view_options와 배타). copy는 선택이 없으면 Swift가 no-op.
    // 파일 본문 우클릭 메뉴(§2.6): 항목마다 실행 주인이 다르다. native가 이미 소유한 동작(링크 열기·복사·모드
    // 전환)은 여기서 실행하고, 선택에 붙은 것(복사·잘라내기·붙여넣기·전체 선택)은 web으로 되돌려 보낸다.
    if (self.file_content_menu) |menu| {
        const selected = self.chrome_host.context_menu.selected;
        if (selected >= menu.len) {
            closeContextMenu(self);
            return;
        }
        const item = menu.items[selected];
        const surface_id = menu.surface_id;
        const editor_epoch = menu.editor_epoch;
        // href는 메뉴 teardown에서 해제되므로 **닫기 전에** 복사해 쓴다.
        switch (item.owner()) {
            .web => {
                self.pending_file_menu_action = .{ .surface_id = surface_id, .item = item };
                // **그 문서로 포커스를 돌려준다.** 메뉴 클릭은 오버레이 통과 경로라 터미널 뷰가 받는데, 그대로
                // 두면 이어지는 ⌘Z·타이핑이 편집기까지 못 간다 — 잘라내기는 됐는데 되돌리기가 안 되던 원인이다.
                if (file_panel_ops.fileEntryForSurfaceId(self, surface_id)) |entry| dock_ops.requestDockEntryFocus(self, entry);
                closeContextMenu(self);
            },
            .native => switch (item) {
                .open_link => {
                    const href = self.allocator.dupe(u8, menu.href) catch {
                        closeContextMenu(self);
                        return;
                    };
                    defer self.allocator.free(href);
                    closeContextMenu(self);
                    self.openFilePanelDocumentLink(surface_id, editor_epoch, href, false) catch {
                        self.showNoticeKey(.set_link_open_failed);
                    };
                },
                .copy_link, .copy_path => {
                    // OSC 52 write와 같은 drain으로 Swift가 NSPasteboard에 쓴다(새 ABI 불요).
                    const captured = self.allocator.dupe(u8, menu.href) catch {
                        closeContextMenu(self);
                        return;
                    };
                    if (self.chrome_clipboard_write.len > 0) self.allocator.free(self.chrome_clipboard_write);
                    self.chrome_clipboard_write = captured;
                    closeContextMenu(self);
                },
                .open_source => {
                    closeContextMenu(self);
                    _ = self.setFilePanelModeBySurface(surface_id, .source_edit);
                    if (file_panel_ops.fileEntryForSurfaceId(self, surface_id)) |entry| dock_ops.requestDockEntryFocus(self, entry);
                },
                // 이미지 저장은 저장 패널 ABI가 필요해 이 슬라이스에 없다(§2.6) — 항목도 만들지 않는다.
                .save_image, .copy, .cut, .paste, .select_all => closeContextMenu(self),
            },
        }
        return;
    }
    // 편집기 본문 메뉴 — 열 때 굳힌 항목으로 실행한다(고를 때 다시 계산하면 그 사이 선택이 바뀌어
    // 다른 항목이 돈다). 클립보드는 OS 것이라 잘라내기·복사·붙여넣기는 Swift 로 넘기고, 전체 선택만
    // 그 자리에서 한다.
    if (self.editor_context_menu) |menu| {
        const selected = self.chrome_host.context_menu.selected;
        // **보내기 구획이 앞에 있다** — 편집 항목 인덱스는 그만큼 밀려 있다. 빼지 않으면 "붙여넣기"
        // 를 눌렀는데 "복사" 가 도는 그 한 칸 밀림이 된다(리소스 팝오버가 같은 실수를 했다).
        if (menu.send_rows > 0 and selected < menu.send_rows) {
            const target_index = selected - 1; // 머리글 한 줄
            const target_id: ?u64 = if (target_index < menu.target_len) menu.targets[target_index] else null;
            const source = term_ops.termBySurfaceId(self, menu.surface_id);
            closeContextMenu(self);
            if (target_id) |tid| if (source) |src| {
                // **보낸 뒤에만 기억한다.** 못 보낸 대상을 기본값으로 두면 다음 메뉴가 안 되는 줄에서
                // 시작한다(대상이 터미널이 아니거나 선택이 없으면 `sendSelectionToAgent` 가 접힌다).
                if (editor_ops.sendSelectionToAgent(self, src, tid)) self.last_agent_target = tid;
            };
            return;
        }
        const edit_index = selected -| menu.send_rows;
        const item: ?maru.session.content_menu.Item = if (edit_index < menu.len) menu.items[edit_index] else null;
        const target = term_ops.termBySurfaceId(self, menu.surface_id);
        closeContextMenu(self);
        const t = target orelse return; // 메뉴가 떠 있는 동안 닫힌 Term — 조용히 접는다
        switch (item orelse return) {
            // 잘라내기·복사는 **편집기 것**이다 — 터미널 선택을 집는 `ClipboardAction.copy` 로 보내면
            // 편집기 선택이 아니라 터미널 선택이 클립보드에 간다. 두 경로가 이름만 같고 대상이 다르다.
            .cut => _ = editor_ops.cutSelection(self, t),
            .copy => _ = editor_ops.copySelection(self),
            // 붙여넣기는 OS 클립보드를 읽어야 해서 Swift 를 거친다. 되돌아온 바이트는
            // `AppSession.pasteText` 가 §3.4 대로 편집기 Term 으로 라우팅한다.
            .paste => self.pending_clipboard_action = .paste,
            .select_all => _ = editor_ops.selectAll(self, t),
            else => {},
        }
        return;
    }
    if (self.terminal_context_menu) {
        const action: ClipboardAction = switch (self.chrome_host.context_menu.selected) {
            0 => .copy,
            1 => .paste,
            else => .none,
        };
        self.pending_clipboard_action = action;
        closeContextMenu(self); // hide + terminal_context_menu 비움
        return;
    }
    // view options 메뉴: 항목 선택 = 표시 토글. 메뉴를 '닫지 않고'(체크박스 패널) config bool을 뒤집고 라벨(체크마크)을
    // 갱신한 뒤 카드를 재빌드하고, config 파일 반영을 예약한다(config_dirty_keys → Swift persist). 닫기는 바깥 클릭/Esc.
    if (self.view_options_menu) {
        switch (self.chrome_host.context_menu.selected) {
            0 => self.loaded_config.config.sidebar.show_branch = !self.loaded_config.config.sidebar.show_branch,
            1 => self.loaded_config.config.sidebar.show_folder = !self.loaded_config.config.sidebar.show_folder,
            else => {},
        }
        _ = buildViewOptionsMenuItems(self); // 라벨 체크마크 갱신(메뉴 열린 채)
        sidebar_ops.rebuildSidebar(self) catch {}; // 카드 표시 즉시 반영
        // config 파일 persist 예약(앱→config) — 두 사이드바 표시 키를 dirty 집합에 넣는다(옛 동작과 동일하게 둘 다 기록).
        markConfigKeyDirty(self, "sidebar.show-branch");
        markConfigKeyDirty(self, "sidebar.show-folder");
        self.metal_dirty = true;
        return;
    }
    if (self.file_tree_background_menu) {
        const selected = self.chrome_host.context_menu.selected;
        closeContextMenu(self);
        switch (selected) {
            0 => file_panel_ops.requestFilePanelPick(self),
            1 => file_panel_ops.requestFileTreeRootPick(self, .replace),
            2 => file_panel_ops.requestFileTreeRootPick(self, .add),
            else => {},
        }
        return;
    }
    if (self.file_tree_context_target) |target| {
        const sel = self.chrome_host.context_menu.selected;
        const create_allowed = !(target.symlink and (target.row_kind == .root or target.row_kind == .directory));
        self.file_tree_context_target = null;
        self.chrome_host.context_menu.hide();
        if (target.root_generation != self.file_tree.rootGeneration()) {
            self.showNoticeKey(.set_root_changed_cancel);
            return;
        }
        const current_index = file_tree.findIdentity(self.file_tree_rows.items, .{ .kind = target.row_kind, .path = target.path() }) orelse {
            self.showNoticeKey(.set_selection_changed_cancel);
            return;
        };
        _ = file_panel_ops.setFileTreeSelection(self, current_index);
        if (target.row_kind == .root) {
            switch (sel) {
                0 => file_panel_ops.startFileTreeEdit(self, .create_file),
                1 => file_panel_ops.startFileTreeEdit(self, .create_directory),
                2 => file_panel_ops.requestFilePanelPick(self),
                3 => file_panel_ops.requestFileTreeRootPick(self, .replace),
                4 => file_panel_ops.requestFileTreeRootPick(self, .add),
                5 => file_panel_ops.removeFileTreeRoot(self, target.path()),
                else => {},
            }
        } else if (create_allowed and sel == 0) file_panel_ops.startFileTreeEdit(self, .create_file) else if (create_allowed and sel == 1)
            file_panel_ops.startFileTreeEdit(self, .create_directory)
        else {
            const base: usize = if (create_allowed) 2 else 0;
            if (sel == base) file_panel_ops.startFileTreeEdit(self, .rename) else if (sel == base + 1) file_panel_ops.requestDeleteSelectedFileTreeEntry(self);
        }
        self.metal_dirty = true;
        return;
    }
    const target = self.context_menu_target;
    const sel = self.chrome_host.context_menu.selected;
    self.context_menu_target = null;
    self.chrome_host.context_menu.hide();
    self.metal_dirty = true;
    const t = target orelse return;
    if (sel == 0) {
        startRename(self, t); // "Rename"(모든 대상)
        return;
    }
    if (std.meta.activeTag(t) == .workspace) {
        const tab = t.workspace;
        if (sel == ctx_menu_pin) {
            // GL §13 GL2 — cardPinRole 분기(라벨과 공유). 비마커 멤버=그룹-로컬 위치 고정(toggleLocalPin, 현행 그룹째
            // 위임 되돌림)·마커 카드=그룹째 고정(toggleGroupPin, C2 권위 §12.2 — 개별 pin이면 캐시 desync)·최상위=개별 togglePin.
            switch (tab_ops.cardPinRole(self, tab)) {
                .group => if (tab_ops.enclosingGroupMarkerTab(self, tab)) |mk| tab_ops.toggleGroupPin(self, mk),
                .local => tab_ops.toggleLocalPin(self, tab),
                .individual => tab_ops.togglePin(self, tab),
            }
        } else if (sel == ctx_menu_group_create) {
            tab_ops.createGroupForTab(self, tab); // 새 그룹으로 묶기=중첩(단축키 Cmd+Opt+G·팔레트 공유 — 클릭 대상 기준)
        } else if (sel == ctx_menu_group_sibling) {
            tab_ops.createSiblingGroupForTab(self, tab); // 형제 그룹으로 분리=같은 depth 형제(단축키 Cmd+Opt+Shift+G·팔레트 공유, SG5-3)
        } else if (sel == ctx_menu_group_ungroup) {
            tab_ops.ungroupTab(self, tab); // 그룹 풀기(클릭 대상이 속한 그룹의 시작 마커 제거)
        } else if (sel == ctx_menu_group_remove) {
            tab_ops.removeFromGroupForTab(self, tab); // 그룹에서 빼기(이 카드 하나만 최상위로 — 그룹 유지). 그룹 소속 카드에만 뜨는 항목
        } else if (sel == ctx_menu_group_promote) {
            tab_ops.promoteTabToTopLevelInPlace(self, tab); // 여기서 최상위로 분리(제자리 top_level·pin 불변 — remove의 이동+unpin과 구별, §14.7)
        } else if (sel >= ctx_menu_bg_first and sel < ctx_menu_bg_first + tab_color_presets.len) {
            tab.background_color = tab_color_presets[sel - ctx_menu_bg_first]; // 배경 tint 프리셋
        } else if (sel >= ctx_menu_accent_first and sel < ctx_menu_accent_first + tab_color_presets.len) {
            tab.accent_color = tab_color_presets[sel - ctx_menu_accent_first]; // 좌측 accent 막대색 프리셋(bound·index 모두 tab_color_presets — 공유 팔레트)
        } else if (sel >= ctx_menu_group_color_first and sel < ctx_menu_group_color_first + tab_color_presets.len) {
            tab_ops.setGroupColorForTab(self, tab, tab_color_presets[sel - ctx_menu_group_color_first]); // 그룹 공통 색(SG5-2) — 소속 그룹 마커에 세팅(카드 색과 같은 팔레트)
        }
    } else if (std.meta.activeTag(t) == .group) {
        // 그룹 헤더 우클릭(SG5-2-header) — 대상 tab은 group_start 마커. sel==0(Rename)은 위에서 startRename(.group)로 처리됨.
        // ungroup·색은 카드 메뉴와 같은 세션 메서드를 쓴다(대상이 마커라 enclosingGroupMarkerIndex가 자기 자신을 찾아 동작).
        const tab = t.group;
        if (sel == ctx_group_menu_pin) {
            // 그룹 고정/해제(마커 pinned 토글 → 멤버 동기 → 리전 안착, GP3 §12.10). **top-level 해소**(§12.1
            // pin ⊃ group ⊃ nest): 중첩 subgroup 헤더에서 눌러도 그 subtree만 pin돼 부모에서 떨어지지 않게
            // enclosingGroupMarkerTab(depth 1까지 상향)으로 최상위 마커를 잡는다. 마커는 항상 자기 그룹에 속하니 non-null.
            if (tab_ops.enclosingGroupMarkerTab(self, tab)) |mk| tab_ops.toggleGroupPin(self, mk);
        } else if (sel == ctx_group_menu_ungroup) {
            tab_ops.ungroupTab(self, tab); // 그룹 풀기(헤더가 가리키는 그룹의 시작 마커 제거)
        } else if (sel >= ctx_group_menu_color_first and sel < ctx_group_menu_color_first + tab_color_presets.len) {
            tab_ops.setGroupColorForTab(self, tab, tab_color_presets[sel - ctx_group_menu_color_first]); // 그룹 색(카드 메뉴와 같은 dispatch·팔레트)
        }
    }
}

/// appearance(폰트·여백·테마)가 통째로 바뀌었을 때의 일반 적용 경로. setFontSize의 메트릭 재계산을 일반화한 것 —
/// reloadConfig(파일 새 값)·reapplyLoadedConfig(통합 리셋 resetAllSettings 등)이 공유한다. appearance를 갈아끼우고 base_font_size를
/// 새 폰트 크기로 맞춘 뒤(⌘0 기준도 따라감), 메트릭·grid·atlas 파이프라인을 돌린다. palette/scrollback 같은
/// 코어 behavior 재주입은 호출자가 한다(appearance만 다루는 단일 책임).
pub fn applyAppearance(self: *AppSession, new_appearance: config_mod.ResolvedAppearance) void {
    self.appearance = new_appearance;
    self.base_font_size = new_appearance.font.size; // 새 config 기본 폰트 크기 = ⌘0 reset 기준
    self.applyMetricsPipeline();
}

/// applyAppearance에 런타임 ⌘+/− 줌 보존을 얹은 변형 — config를 라이브 재적용하는 두 경로(GUI 토글
/// reapplyLoadedConfig·파일 재로드 reloadConfig)가 공유해 줌 처리를 일치시킨다. setFontSize(⌘+/−)는 런타임
/// appearance.font.size만 바꾸고 config는 안 건드리므로, config 재resolve가 그 줌을 날린다. 이를 막되:
///   - **config 폰트 크기가 그대로일 때만**(`config_size == base_font_size`) base 대비 줌 델타를 새 크기 위에
///     다시 얹는다. 폰트 크기 자체를 GUI(슬라이더/스텝)나 파일로 바꿨다면 그 값이 사용자가 의도한 절대 크기이므로
///     줌을 안 얹고 그대로 둔다 — 안 그러면 슬라이더 표시값과 렌더 크기가 어긋난다(code-review high #1).
///   - 경계 클램프는 ⌘+/− 와 동일하게 초과분을 흡수한다(clamp-forget): 줌 델타를 별도 저장하지 않고 appearance에서
///     유도하므로, max/min을 넘긴 줌은 그만큼만 남는다. ⌘+/− 도 같은 의미라(누른 만큼 못 가면 잊음) 일관적이다.
/// ⌘0 기준 base_font_size는 줌 제외한 config 크기로 둔다(applyAppearance가 줌 포함 크기로 세운 것을 교정).
pub fn applyAppearancePreservingZoom(self: *AppSession, new_appearance: config_mod.ResolvedAppearance) void {
    var appe = new_appearance;
    const config_size = new_appearance.font.size; // ⌘0 기준이 될 config 폰트 크기(줌 제외)
    if (config_size == self.base_font_size) {
        const zoom_delta = self.appearance.font.size - self.base_font_size;
        appe.font.size = std.math.clamp(config_size + zoom_delta, font_size_min, font_size_max);
    }
    applyAppearance(self, appe);
    self.base_font_size = config_size; // applyAppearance가 줌 포함 크기로 세운 ⌘0 기준을 줌 제외 config 값으로 교정
}

/// "Reload Config" 메뉴 — config 파일을 재로드해 재시작 없이 반영한다. 파싱은 forgiving(알 수 없는 key/잘못된
/// 값은 기본값 유지 + diagnostic), 로드 자체가 실패(OOM 등)하면 무동작이다(기존 config 유지). 적용 순서:
/// ① 새 Parsed로 loaded_config 교체(옛 arena deinit 후 — appearance가 family 슬라이스를 빌리므로 새 appearance를
///    먼저 만들지 말고 loaded_config를 갈아끼운 뒤 resolve한다 → 옛 family를 빌린 옛 appearance는 이 시점에 버린다).
/// ② appearance resolve + applyAppearance(메트릭·grid·atlas + base_font_size).
/// ③ 파일 새 값이라 코어 behavior(scrollback/bell/page-keys/palette/ambiguous-width)도 모든 surface에 재적용.
/// resetAllSettings(통합 리셋)와 형제 경로다 — reload는 파일 값으로, reset은 기본 Config로 같은 appearance/behavior 적용을 한다.
pub fn reloadConfig(self: *AppSession) void {
    // **행 집합이 바뀌기 전에** 지금 선택된 행의 키를 떠 둔다(아래 `restoreSelectedRowKey` 가 쓴다).
    var anchored_buf: [128]u8 = undefined;
    const anchored = captureSelectedRowKey(self, &anchored_buf);

    var new_parsed = config_mod.loadConfigDefault(self.io, self.allocator) catch return; // 실패 시 무동작(forgiving)
    // 새 config로 appearance를 먼저 resolve한 뒤에 옛 loaded_config를 버린다 — resolve가 실패하면 옛
    // appearance·loaded_config를 그대로 보존해 use-after-free(옛 arena의 family를 빌린 appearance)를 막는다.
    const new_appearance = config_mod.resolveAppearance(new_parsed.config) catch {
        new_parsed.deinit();
        return;
    };
    // 파일의 새 사이드바 폭(sidebar.width, pt)을 메트릭 파이프라인 전에 세운다 — 바로 아래 applyAppearancePreservingZoom이
    // 부르는 refreshCellMetrics가 동적 하한으로 clamp·px 환산하고, 이어지는 grid 재배치가 새 폭을 반영한다(파일→앱
    // 양방향). loaded_config 교체 전이라 new_parsed에서 읽는다. reload는 "파일에서 다시 읽기"라 미저장 드래그 편집을
    // 덮는 게 맞다(아래 clearConfigDirty가 write-back 대기열을 비우는 것과 일관).
    self.sidebar_width_pt = new_parsed.config.sidebar.width_pt;
    // appearance 통째 교체 — 옛 family를 더는 안 읽는다. 줌 보존(GUI 토글과 일치 — code-review high #2)은
    // 옛 appearance.font.size·base_font_size(둘 다 스칼라 f32)만 읽으므로 옛 arena family slice를 deref하지 않아 UAF 없음.
    // **새 config를 먼저 세운다.** `applyAppearancePreservingZoom`이 타는 메트릭 파이프라인은 pane/PTY
    // 크기를 다시 재는데, 그 계산이 `gridPadding` → `statusBarHeightPx` → `loaded_config`를 읽는다.
    // 교체가 뒤에 오면 **옛 값으로 재고 새 값으로 그리게** 되어, 예컨대 `status-bar.show`를 끈 reload에서
    // 바는 사라졌는데 셸은 늘어난 행을 못 받는다(실측 36행이어야 할 것이 35행). 옛 arena는 appearance를
    // 통째로 바꾼 뒤에 버려야 UAF가 없으므로 deinit만 마지막에 남긴다.
    var old_loaded = self.loaded_config;
    self.loaded_config = new_parsed;
    applyAppearancePreservingZoom(self, new_appearance);
    old_loaded.deinit(); // appearance를 새것으로 갈아끼운 뒤라 옛 arena를 버려도 안전
    replaceAppKeepAlivePolicyFromReload(self.loaded_config);
    // 옛 arena를 버렸으니 follow-system 복귀 스냅샷(옛 arena slice)도 비운다(dangling 방지). 아래 applyFollowSystemTheme가
    // 새 파일 테마로 다시 스냅샷·적용한다(F2-9). null 대입은 옛 slice를 deref하지 않아 free 후라도 안전.
    self.theme_pre_follow = null;
    self.follow_applied_dark = null; // 새 config라 외관 게이트도 리셋 — 아래 applyFollowSystemTheme가 다시 적용
    // 옛 arena를 버렸으니 write-back 대기열(config_dirty_keys·theme_preset_persist·keybind/global rebind·removed 등 9개)도
    // 비운다 — 이 큐들은 옛 arena의 문자열(동적 env 키·keybind chord·프리셋 이름)을 가리키므로 free 후 다음 serializeConfig가
    // 읽으면 use-after-free다. reload는 "파일에서 다시 읽기"라 대기 중 미저장 편집을 버리는 게 의미상 맞다. clearConfigDirty는
    // list 길이만 리셋·옵셔널 null 대입이라 옛 slice를 deref하지 않아 free 후 호출도 안전.
    clearConfigDirty(self);
    // 파일 새 값이라 캐시된 behavior도 갱신한다(appearance 밖 — applyAppearance가 안 건드림).
    self.audible_bell = self.loaded_config.config.bell.audible;
    self.bell_visual = self.loaded_config.config.bell.visual;
    self.bell_dock_badge = self.loaded_config.config.bell.dock_badge;
    // **파일에서 다시 읽은 탭 폭도 넣는다**(§9). 위 `applyLoadedConfig`는 세팅 GUI 재적용 경로이고
    // 이쪽은 파일 reload라 **둘 다 필요하다**. 함수가 값이 같으면 건너뛰므로 중복 호출은 무해하다.
    editor_ops.applyConfigTabWidth(self);
    self.page_keys_scroll = self.loaded_config.config.input.page_keys == .scroll;
    self.shift_enter_meta = self.loaded_config.config.input.shift_enter == .newline;
    self.ime_enter_newline = self.loaded_config.config.input.ime_enter == .newline;
    self.option_as_meta = self.loaded_config.config.input.option_as_meta;
    reapplyUiLanguage(self);
    reapplyScrollback(self);
    reapplyConfigPalette(self);
    reapplyAmbiguousWidth(self);
    reapplyEmojiWidth(self);
    reapplyDefaultCursorShape(self);
    // 사이드바 카드 표시 토글(sidebar.show-branch/folder)이 파일에서 바뀌었을 수 있다 — 카드를 다시
    // 빌드해 즉시 반영한다(config→앱 양방향). rebuildSidebar 실패는 무시(다음 프레임에 자연 복구).
    sidebar_ops.rebuildSidebar(self) catch {};
    // 파일에서 새로 깔았으니 "사용자 지정" 명시 플래그를 해제 — 색이 어떤 프리셋과 일치하면 다시 잠금(derive 기준).
    self.theme_user_custom = false;
    self.metal_dirty = true;
    // 파일 새 값이라 keybind도 바뀌었을 수 있다 — 커맨드 카탈로그를 재빌드해 Zig-side 커맨드 팔레트의 표시 chord를
    // 갱신한다(buildPaletteRows가 command_key_displays를 라이브로 읽는다). 키 디스패치는 resolver를 매 이벤트마다
    // 라이브로 읽어 이미 새 값이지만, 캐시된 표시 문자열은 재빌드해야 바뀐다(rebind/unbindActionEntry와 동일).
    // Swift 메뉴바 keyEquivalent도 rebuildCommandCatalog가 세우는 command_catalog_dirty를 drainMenuDirty가 다음 tick에
    // drain해 갱신된다(v85 — 더는 재시작 필요 없음).
    self.rebuildCommandCatalog();
    // 파일 새 값이라 전역 단축키도 다시 빌드해 라이브 OS 재등록(PR2 — 지금까지 reload가 global을 재반영 못 하던 버그도 같이 고침).
    input_ops.rebuildGlobalHotkeys(self) catch {};
    self.global_hotkeys_dirty = true;
    // follow-system이 켜져 있으면(파일 새 값) 위에서 깐 파일 테마 위에 현재 시스템 외관 프리셋을 다시 덮는다(F2-9).
    self.applyFollowSystemTheme();
    // **설정 폼이 열린 채로 이 경로가 돈다.** reload 는 모달을 닫지 않으므로(닫는 것은 confirm/notice 경로뿐),
    // 파일이 `env.*`·`macro.*` 를 더하거나 지웠으면 통과 행 집합이 그 자리에서 바뀐다. `selected` 는 인덱스라
    // 그 자리에 다른 설정이 들어와도 모르고, `count` 도 옛 값에 멈춰 ↑↓ 가 갇힌다.
    //
    // 이것은 **언어와 무관한 축**이라 필터를 언어 독립으로 만든 것으로는 안 닫힌다 — 행 집합을 바꾸는 것이
    // 언어가 아니라 파일이기 때문이다. 그래서 키로 다시 앉히는 그 기계를 여기에 붙인다.
    restoreSelectedRowKey(self, anchored);
}

/// 행 집합이 바뀌기 **전에** 지금 선택된 행의 키를 떠 둔다. `null` 이면 앉힐 자리가 없다는 뜻이다.
///
/// **바뀐 뒤에 뜨면 늦다** — 그때 `selected` 가 가리키는 것은 이미 다른 행이라, 그 키로 앉히면 미끄러진
/// 자리를 그대로 고정한다. 같은 실수를 다중 창 경로에서 한 번 했고, 그때는 애초에 뜰 기회가 없어 못
/// 고쳤다. 여기서는 기회가 있으므로 순서만 지키면 된다.
fn captureSelectedRowKey(self: *AppSession, buf: []u8) ?[]const u8 {
    if (!self.chrome_host.settings.open) return null;
    return selectedSettingsKey(self, buf);
}

/// 행 집합이 바뀐 뒤, 앞서 떠 둔 키로 선택을 다시 앉히고 행 수를 다시 알린다.
///
/// 뜰 키가 아예 없었으면(설정 폼이 닫혀 있었거나 통과 행이 0이었으면) 행 수만 갱신한다 — 그때 컴포넌트가
/// `selected` 를 범위 안으로 clamp 한다.
///
/// **키는 있는데 그 행이 사라졌으면**(파일이 지운 `env.FOO`) `reanchorSelectedByKey` 의 폴백이 돈다 —
/// 검색 쿼리를 지우고 그 키가 살던 섹션으로 옮긴 뒤 다시 찾는다. 여기서도 그 폴백이 맞다고 본 이유는,
/// 사라진 행을 가리키는 선택을 그대로 두면 **다음 Enter 가 남의 행에 간다**는 것이 언어 축과 똑같기
/// 때문이다. 다만 사용자가 친 검색어가 지워지는 것은 눈에 띄는 부작용이라 여기 적어 둔다.
fn restoreSelectedRowKey(self: *AppSession, anchored: ?[]const u8) void {
    if (!self.chrome_host.settings.open) return;
    if (anchored) |key| {
        reanchorSelectedByKey(self, key);
    } else {
        refreshSettingsFieldCount(self);
    }
}

/// **통합 리셋** — 모든 config를 **내장 기본값**으로 되돌린다. 메뉴 "Reset to Defaults"(ABI `reset_defaults`)와 커맨드
/// 팝업 "Reset All Settings to Defaults"(`reset_settings` 액션) **두 진입점이 모두 이 단일 함수**를 호출한다(통일 —
/// code-review #829 후속: 옛 메뉴 전용 부분 갱신이 preset/alias 오염·런타임 드리프트를 내던 걸 검증된 단일 경로로
/// 일원화). loaded_config.config를 정적 기본값으로 갈고(새 arena 불요 — 기본값은 정적 리터럴), keybind 바인딩 4종도
/// 빈 슬라이스(빌트인만)로 비우고, reloadConfig와 같은 재적용(appearance·behavior·scrollback·palette·ambiguous·사이드바)
/// + 카탈로그·전역 단축키 재빌드를 한 뒤, **config 파일을 안내 주석만 남긴 기본
/// 상태로 덮어쓴다**(삭제가 아니라 — 파일·경로 보존, 사용자가 기본 상태를 보고 편집 가능; 사용자 요청).
/// **예외 하나: `session.keep-alive-after-quit`은 초기화하지 않고 보존한다.** 이 키는 취향이 아니라 살아 있는
/// PTY의 소유권 모드이고, 기본값으로 되돌리면 다음 Quit이 host-backed runtime을 terminate해 사용자의 터미널
/// 세션이 경고 없이 사라진다. 보존 근거와 notice 문구는 함수 본문 주석을 단일 출처로 둔다.
pub fn resetAllSettings(self: *AppSession) void {
    // `session.keep-alive-after-quit`은 취향 설정이 아니라 **runtime 소유권 모드**다. true면 PTY를 host
    // (`maru-sessiond`)가 소유하고 GUI는 뷰어일 뿐이라 Quit이 detach지만, false면 PTY 수명이 이 앱 프로세스에
    // 묶여 **다음 Quit이 살아 있는 host-backed runtime까지 terminate**한다(docs/persistent-session-host.md
    // 토글 의미론 표 + docs/configuration.md `session.keep-alive-after-quit` 행). 그래서 "모든 설정 초기화"가
    // 이 키까지 기본값으로 되돌리면, 사용자가 켜 둔 터미널 세션 전부가 **다음 종료에 경고 없이 전멸**한다 —
    // 파괴는 명시적이어야 한다며 `Quit and End All Sessions`를 전용 경로로 따로 둔 같은 문서의 원칙과 정면으로
    // 어긋난다(실제 사고: 리셋 뒤 평범한 Quit으로 host-backed runtime 12개가 소멸). 따라서 리셋은 이 키만
    // 보존하고, 끄는 결정은 사용자가 세팅 workspace 섹션 토글로 직접 하도록 아래 notice로 안내한다.
    // 다른 Window가 토글/reload한 뒤 이 Window의 parsed mirror가 아직 낡았을 수 있다. Reset은 process-global
    // owner의 최신 값을 보존해야 하며, 창 로컬 값을 정본으로 승격하면 stale Window가 새 정책을 되돌린다.
    const keep_alive = appKeepAliveSnapshot().value;
    self.loaded_config.config = config_mod.Config{}; // 내장 기본값(정적 — 옛 arena 문자열은 미참조로 남았다 다음 reload/deinit에 해제)
    self.loaded_config.config.session.keep_alive_after_quit = keep_alive; // 보존 — 아래 파일 write도 같은 값을 남긴다
    // 리터럴 false가 아니라 `Config{}` 기본값을 기준으로 "보존이 실제 override인지" 판정한다. 문서가 기능 완성
    // 뒤 기본값을 true로 전환한다고 예고했으므로(persistent-session-host.md), 그때 리터럴 비교로 두면 사용자가
    // 명시적으로 끈 false를 리셋이 도로 켜 버려 같은 사고가 반대 방향으로 난다.
    const keep_alive_reset_plan = appKeepAliveResetPlan();
    const keep_alive_preserved = std.meta.activeTag(keep_alive_reset_plan) == .preserve;
    // live/app-global snapshot은 이미 `keep_alive`를 소유한다. 여기서 일반 토글 setter를 부르면 absent도
    // explicit intent로 바뀌고, write 실패 전 invalid provenance도 성급히 canonicalize되므로 mutation 0으로 둔다.
    // keybind도 config다 — "모든 설정 초기화"는 인앱/파일 keybind 바인딩(keybindings·unbinds·terminal_bindings·
    // global_bindings)도 즉시 기본값(빈 슬라이스=빌트인만)으로 되돌린다. 옛 슬라이스는 arena 소유라 미참조로 남았다
    // 다음 reload/deinit에 해제(config.* 정적 교체와 같은 수명 규칙 — 여기서 free 금지). 이렇게 비워야 keyBindingResolver
    // (매 키 라이브)가 빌트인만 적용하고, 아래 rebuildGlobalHotkeys가 전역 단축키를 실제로 해제하며, rebuildCommandCatalog가
    // 기본 chord를 표시한다(빈 슬라이스 대입은 옛 slice를 deref하지 않아 안전).
    self.loaded_config.keybindings = &.{};
    self.loaded_config.unbinds = &.{};
    self.loaded_config.terminal_bindings = &.{};
    self.loaded_config.global_bindings = &.{};
    self.theme_pre_follow = null; // 기본값으로 갈았으니 follow-system 복귀 스냅샷(옛 arena slice)도 무효 — 비운다(F2-9 dangling 방지)
    self.follow_applied_dark = null; // 외관 게이트도 리셋(기본값은 follow off라 어차피 무적용)
    applyLoadedConfig(self, false); // resolve→apply→behavior 캐시→reapply* 재적용. false=런타임 줌도 config 기본으로(통합 리셋이라 ⌘+/− 확대 해제; resolve-first 안전, reloadConfig 미러 — 리뷰 #827)
    // **config 파일을 기본 상태로 덮어쓴다**(삭제 아님) → 빈+주석이라 다음 로드는 schema·특수 키·주석 전부 기본값.
    // 부분 갱신(updateForKeys)이 아닌 전체 덮어쓰기인 이유: 기본값 위 override만 쓰는 정책상 (a) 비-schema 키
    // (theme.preset/palette/env/cursor.color/shell.args)가 안 지워지고 (b) 빈 항목까지 40여 줄을 쏟는다(리뷰 #827).
    var wrote = false;
    const path = configWritePath(self); // 안전 chokepoint: 테스트가 tmp redirect 안 했으면 ""(쓰기 스킵) — 실 config 보호
    if (path.len > 0) {
        // 아래 `body` peer 타입(보존 override가 있으면 owned `[]u8`, 없으면 이 헤더)을 하나로 맞추려 슬라이스로 못박는다.
        const header: []const u8 = "# Maru config — Reset to Defaults로 초기화됨(모든 설정 기본값). 키 설명: docs/configuration.md\n";
        // atomic write(temp + replace=rename) — 부분 쓰기가 원본 config를 손상하지 않게(serializeConfig→Swift atomic·
        // workspace write와 같은 보장). .replace=true는 File.Atomic.replace 계약(Dir.zig:1878), .make_path=true는 신규
        // 사용자의 ~/.config[/maru] 부모까지 재귀 생성(리뷰 #844-followup — 수동 단계별 mkdir 대체). 실패는 forgiving이되
        // wrote로 추적해 거짓 성공 notice는 피한다(파일 미반영이면 재부팅 시 옛 설정 부활하므로 사용자에게 알린다).
        write_blk: {
            // 보존한 keep-alive가 기본값과 다르면 override 한 줄을 **같은 atomic write에** 담는다. 다음 tick
            // serializeConfig에 미루면 그 사이 앱이 죽었을 때 파일(기본값)과 live 정책(보존값)이 갈라지고, 다음
            // 실행이 조용히 in-process로 떨어져 지금 고치는 사고와 같은 결과가 된다. 키 문자열과 값 포맷은 스키마
            // 직렬화 단일 출처(`updateConfigForKeys`)에 맡겨 손으로 렌더하지 않는다 — 키 rename 시 같이 따라간다.
            const owned: ?[]u8 = if (keep_alive_preserved)
                (config_mod.updateConfigForKeys(self.allocator, header, self.loaded_config.config, &.{"session.keep-alive-after-quit"}) catch break :write_blk)
            else
                null;
            defer if (owned) |b| self.allocator.free(b);
            const body: []const u8 = if (owned) |b| b else header;
            var af = std.Io.Dir.cwd().createFileAtomic(self.io, path, .{ .replace = true, .make_path = true }) catch break :write_blk;
            defer af.deinit(self.io); // replace 성공 시 no-op, 실패/중도 탈출 시 temp 정리
            var wbuf: [256]u8 = undefined;
            var fw = af.file.writer(self.io, &wbuf);
            fw.interface.writeAll(body) catch break :write_blk;
            fw.interface.flush() catch break :write_blk;
            af.replace(self.io) catch break :write_blk;
            wrote = true;
        }
    }
    if (wrote) {
        commitAppKeepAliveReset();
        const snapshot = appKeepAliveSnapshot();
        self.loaded_config.session_keep_alive_provenance = snapshot.provenance;
        self.loaded_config.file_provenance = snapshot.file_provenance;
    }
    // 모든 dirty 컬렉션을 비워 Swift 부분 write-back을 막는다(리뷰 #844-followup) — config_dirty_keys 하나만 비우면
    // 리셋 직전 예약된 keybind rebind/unbind·env 삭제가 살아남아, 다음 tick serializeConfig가 takeConfigDirty()=true로
    // 방금 리셋한 파일에 그 변경을 도로 써넣는다(takeConfigDirty가 5개 컬렉션을 OR로 본다).
    clearConfigDirty(self);
    self.theme_user_custom = false; // 기본값으로 되돌렸으니 "사용자 지정" 해제 — 기본 테마(maru 프리셋)는 잠금이 맞다
    // keybind를 빌트인만으로 비웠으니 커맨드 카탈로그(팔레트·메뉴바 표시 chord)도 재빌드한다. reapplyLoadedConfig는
    // keybind 불변 경로라 카탈로그를 안 건드린다 — reset은 keybind를 바꾸는 유일한 reapply 호출자라 여기서 명시 재빌드.
    self.rebuildCommandCatalog();
    // 위에서 global_bindings를 비웠으니 global_hotkeys도 비고, 라이브 OS 재등록(dirty)으로 등록 해제까지 따라간다(PR2).
    input_ops.rebuildGlobalHotkeys(self) catch {};
    self.global_hotkeys_dirty = true;
    self.metal_dirty = true;
    if (!wrote and path.len > 0)
        self.showNoticeKey(.set_reset_write_failed)
    else if (keep_alive_preserved)
        // 보존을 조용히 처리하면 사용자는 "모든 설정 초기화"라는 말대로 세션 유지도 꺼졌다고 믿고, 나중에
        // 예상과 다른 Quit 동작을 만난다. 보존 사실과 **수동 변경 경로**를 같이 알려야 결정권이 사용자에게 남는다.
        self.showNoticeKey(.set_reset_done_keepalive)
    else
        self.showNoticeKey(.set_reset_done);
}

pub fn clearConfigDirty(self: *AppSession) void {
    inline for (pending_writeback_lists) |n| @field(self, n).clearRetainingCapacity();
    self.theme_preset_persist = null; // 리스트가 아닌 optional이라 registry 밖 — 같은 집합으로 폐기
}

/// **[보류된 dead code — `adjustSelectedSetting`(옛 ←→ adjust)에서만 호출되어 프로덕션 미사용]** 테마 드롭다운 팝업은
/// 절대-인덱스 `applyThemePresetIndex`가 대체했다. 이 dir-순환은 ←→ adjust 보류 결정과 함께 유지한다(재도입 시 재활용).
/// 테마 프리셋을 dir(+1 다음/-1 이전)으로 순환한다(테마 섹션 dropdown). 순환 슬롯 = [프리셋 0..n-1] + ["사용자 지정"=n].
/// 현재 위치는 theme_user_custom이거나 detect=null이면 "사용자 지정"(n), 아니면 그 프리셋. "사용자 지정"으로 가면 색을
/// 그대로 두고 잠금만 해제(theme_user_custom=true — 색·팔레트 행 편집 허용), 프리셋으로 가면 그 색 세트를 통째로 깔고
/// (presetColors — 정적 리터럴이라 dupe 불요) 잠금(theme_user_custom=false) + 라이브 재resolve·`theme.preset` write-back.
/// **프리셋 전체가 영속된다**(persistThemePreset — `theme.preset = <name>` 한 줄을 쓰고 로더가 16색 팔레트·파생색까지
/// 통째로 펼친다; 옛 "주 색 4개만 영속" 한계 해소, 팔레트 영속 리뷰). search/sidebar 색은 그 테마에서 derive돼 자동 복원.
pub fn applyThemePreset(self: *AppSession, dir: i8) void {
    const Preset = config_mod.theme.ThemePreset;
    const n: i64 = @typeInfo(Preset).@"enum".fields.len; // 프리셋 수; 슬롯 인덱스 n = "사용자 지정"
    const detected = detectThemePreset(self.loaded_config.config.theme);
    const cur: i64 = if (self.theme_user_custom or detected == null) n else @intFromEnum(detected.?);
    const slots = n + 1;
    const next = @mod(cur + @as(i64, dir) + slots, slots);
    if (next == n) {
        // "사용자 지정" — 색은 그대로, 잠금만 해제. detect가 우연히 프리셋과 일치해도 이 플래그가 우선(themePresetActive).
        self.theme_user_custom = true;
        self.metal_dirty = true;
        return;
    }
    self.theme_user_custom = false;
    const preset: config_mod.theme.ThemePreset = @enumFromInt(@as(usize, @intCast(next)));
    self.loaded_config.config.theme = config_mod.theme.presetColors(preset);
    reapplyLoadedConfig(self);
    persistThemePreset(self, preset);
}

/// 테마 프리셋 드롭다운의 변형 라벨 — 16 프리셋 @tagName(underscore, viewPopup이 dash 변환) + "사용자 지정"(마지막 슬롯).
pub fn themePresetVariants(_: *AppSession, arena: std.mem.Allocator) ![]const []const u8 {
    const fields = @typeInfo(config_mod.theme.ThemePreset).@"enum".fields;
    const out = try arena.alloc([]const u8, fields.len + 1);
    inline for (fields, 0..) |f, i| out[i] = f.name;
    out[fields.len] = maru.i18n.t(.set_custom);
    return out;
}

/// 테마 프리셋 드롭다운의 현재 선택 인덱스 — 활성 프리셋의 ordinal, 아니면 "사용자 지정" 슬롯(=프리셋 수).
pub fn themePresetCurrentIndex(self: *AppSession) usize {
    const n = @typeInfo(config_mod.theme.ThemePreset).@"enum".fields.len;
    const detected = detectThemePreset(self.loaded_config.config.theme);
    return if (self.theme_user_custom or detected == null) n else @intFromEnum(detected.?);
}

/// follow-system을 끌 때(세팅 토글 OFF) 호출 — 덮기 전 스냅샷한 사용자(파일) 테마로 config.theme를 복귀하고
/// 라이브 재적용한다. 스냅샷이 없으면(켠 적 없음) config.theme가 이미 파일 값이라 그대로 재적용만. follow-system
/// 색은 파일에 write-back을 안 했으므로 이 메모리 복원이 복귀의 단일 경로다(reload는 async write 경합 위험). F2-9.
pub fn disableFollowSystemTheme(self: *AppSession) void {
    if (self.theme_pre_follow) |saved| {
        self.loaded_config.config.theme = saved;
        self.theme_user_custom = self.theme_user_custom_pre_follow; // 색과 함께 잠금 상태도 복원(F2-9 리뷰 라운드2)
        self.theme_pre_follow = null;
    }
    self.follow_applied_dark = null; // follow 종료 — 다음에 다시 켜면 같은 외관이어도 재적용
    reapplyLoadedConfig(self);
}

/// 현재 appearance.theme.palette를 모든 탭/panel/Term 코어에 재주입한다(reload·reset 공유). createTerm의
/// setConfigPalette와 같은 chokepoint지만, 여기 surface들은 이미 live(리더 스레드가 코어 접근)라 코어 변경은
/// core_mutex 아래서 한다(docs/io-render-threading.md PR3 — OSC 4 변경과의 data race 방지). metal_dirty는
/// 호출자(applyAppearance→applyMetricsPipeline)가 이미 세운다.
pub fn reapplyConfigPalette(self: *AppSession) void {
    const palette = self.appearance.theme.palette;
    const default_colors: maru.session.core_command.DefaultColors = .{
        .foreground = self.appearance.theme.foreground,
        .background = self.appearance.theme.background,
    };
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                // Phase 3 위임(docs/plans/io-render-threading.md §9 P3-3): config 재적용도 메인이 직접 mutate 안 하고
                // reader로 위임한다(interactive면 큐, 아니면 enqueueCoreCommand 내부 직접 폴백). reload는 attach 후라
                // 링크 존재(없으면 UnknownSurface로 스킵 — best-effort).
                self.enqueueCoreCommandForTerm(term, .{ .set_config_palette = palette }) catch {};
                // OSC 10/11 query의 default fg/bg도 renderer theme와 같은 값을 보게 한다. buildFrame의 direct
                // setDefaultColors는 local render 안전망이고 remote placeholder에는 host 효과가 없으므로 이 경계가 필요하다.
                self.enqueueCoreCommandForTerm(term, .{ .set_default_colors = default_colors }) catch {};
            }
        }
    }
}

/// config scrollback.lines를 모든 탭/panel/Term 코어 max_scrollback에 재주입한다(reload 전용 — reset은 behavior를
/// 안 건드린다). createTerm과 같은 chokepoint지만 live surface라 core_mutex 아래서 쓴다(리더 스레드가 ring을
/// lazy-alloc/scroll로 읽으므로). 이미 할당된 ring을 줄이지는 않는다 — 코어가 다음 eviction에서 새 cap을 본다.
pub fn reapplyScrollback(self: *AppSession) void {
    const lines = self.loaded_config.config.scrollback.lines;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                // Phase 3 위임(P3-3): scrollback cap 재적용도 reader로 위임(config 재적용과 동일 — best-effort).
                self.enqueueCoreCommandForTerm(term, .{ .set_max_scrollback = lines }) catch {};
            }
        }
    }
}

/// `ui.language` 를 현재 UI 언어에 반영한다.
///
/// **재시작을 요구하지 않는다**(i18n 계약 §5.1) — 번역 대상이 전부 chrome 이 매 프레임 그리는 표면이라
/// 전역만 바꾸면 다음 프레임에 반영된다. 그래서 여기서 하는 일은 전역 갱신뿐이고, 다시 그리라는 신호는
/// 이 함수를 부르는 경로들이 이미 세운다.
///
/// **선택을 다시 앉히지 않는다 — 앉힐 필요가 없다.** 예전에는 여기서 선택 행의 키를 붙잡았다가 언어를
/// 바꾼 뒤 다시 앉혔다. 설정 폼 필터가 현재 언어의 문장으로 판정해서, 언어가 바뀌면 통과 행 집합과 순서가
/// 함께 바뀌었기 때문이다. 그 방식은 "언어가 바뀌는 지점" 을 하나씩 세는 것이라 **네 번 연속으로 구멍을
/// 냈고**, 마지막에는 다른 창이 언어를 바꾼 경우처럼 **이 창이 아무 코드도 안 도는 경로**가 남았다.
/// 지금은 `settingsRowMatches` 가 언어를 안 보므로(그 함수의 계약) 행 집합도 순서도 안 흔들린다 —
/// 흔들릴 것이 없으므로 붙잡을 것도 없다. 그 성질은 전칭 테스트가 지킨다.
pub fn reapplyUiLanguage(self: *AppSession) void {
    maru.i18n.applyPreference(self.loaded_config.config.ui_language);
}

/// 지금 선택된 행의 config 키를 `buf` 에 **복사해서** 돌려준다.
///
/// 복사하는 이유는 `env.`·`macro.` 행의 키가 `currentSectionFields` 의 arena 소유이기 때문이다 — 그 arena
/// 는 이 함수가 끝날 때 죽는다. 원본 슬라이스를 그대로 돌려주면 호출부가 해제된 바이트를 비교한다.
fn selectedSettingsKey(self: *AppSession, buf: []u8) ?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const cf = currentSectionFields(self, scratch.allocator()) catch return null;
    // 합성 키는 곧장 `buf` 에 쓰이고, 스키마 키는 정적이라 복사가 필요 없다. 어느 쪽이든 `scratch` 가
    // 죽은 뒤에도 유효해야 하므로, `buf` 를 가리키지 않는 것만 복사한다.
    var scratch_key: [128]u8 = undefined;
    const key = keyAtRow(cf, self.chrome_host.settings.selected, &scratch_key) orelse return null;
    if (key.len > buf.len) return null;
    @memcpy(buf[0..key.len], key);
    return buf[0..key.len];
}

/// `currentSectionFields` 의 행 순서에서 `i` 번째 행의 **앵커 키**.
///
/// 스키마 필드(bool → number → enum → text → color) 뒤에 **스키마가 모르는 행 셋**이 더 있다 — ANSI
/// 팔레트 그리드 한 줄, in-app 단축키 행들, 전역 단축키 행들(`SettingsSectionFields.total()`). 그 셋을
/// 여기서 빠뜨리면 그 행에 서 있을 때 앵커가 `null` 이 되어 **재고정이 통째로 안 돈다** — 그리고 전역
/// 단축키 행의 라벨은 `GlobalEntry.title()` 이 `t(title_key)` 로 만들므로 **언어를 정통으로 탄다**.
/// 즉 재고정이 가장 필요한 행에서 가장 안 돌던 상태였다.
///
/// 그 셋은 config 키가 없으므로 **합성 키**를 만든다. `buf` 는 호출부 소유이고, 돌려주는 슬라이스는
/// 스키마 키(정적)이거나 이 버퍼를 가리킨다 — 어느 쪽이든 호출부가 수명을 안다.
fn keyAtRow(cf: SettingsSectionFields, i: usize, buf: []u8) ?[]const u8 {
    var n = i;
    if (n < cf.bools.len) return cf.bools[n].key;
    n -= cf.bools.len;
    if (n < cf.nums.len) return cf.nums[n].key;
    n -= cf.nums.len;
    if (n < cf.enums.len) return cf.enums[n].key;
    n -= cf.enums.len;
    if (n < cf.texts.len) return cf.texts[n].key;
    n -= cf.texts.len;
    if (n < cf.colors.len) return cf.colors[n].key;
    n -= cf.colors.len;
    // 구문 색 행 — **행 순서와 같은 순회**로 역할을 찾는다(검색으로 걸러진 것만 센다). 이 가지가 없으면
    // 행은 `total()` 에 잡히는데 키가 없어, 행을 훑는 쪽이 `null` 을 받고 죽는다(실측으로 그랬다).
    if (cf.syntax_roles > 0) {
        if (n < cf.syntax_roles) {
            const ri = cf.syntaxRoleIndexAt(n) orelse return null;
            return syntaxRoleKeyOf(@enumFromInt(ri));
        }
        n -= cf.syntax_roles;
    }
    if (cf.has_palette) {
        if (n == 0) return synthKey(buf, palette_row_key, "");
        n -= 1;
    }
    if (n < cf.keybind_entries.len) return synthKey(buf, keybind_row_prefix, cf.keybind_entries[n].key);
    n -= cf.keybind_entries.len;
    if (n < cf.global_entries.len) return synthKey(buf, global_row_prefix, cf.global_entries[n].key);
    return null;
}

/// 스키마 밖 행의 앵커 키. config 파일에 쓰이지 않고 **이 프레임 안에서 행을 다시 찾는 데만** 쓰인다.
const palette_row_key = "theme.palette";
const keybind_row_prefix = "keybind.";
const global_row_prefix = "global.";

fn synthKey(buf: []u8, prefix: []const u8, tail: []const u8) ?[]const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ prefix, tail }) catch null;
}

/// text.ambiguous-width reload를 라이브 코어에 재적용한다(createTerm chokepoint와 같은 값을 이미 떠 있는
/// surface에도). reader 단일 mutator 계약상 set_max_scrollback과 같이 CoreCommand로 위임한다. 이후 putCell부터
/// 새 폭이 반영된다(이미 저장된 셀은 옛 폭 유지 — 폭 변경은 본래 redraw 필요; max_scrollback과 같은 best-effort).
pub fn reapplyAmbiguousWidth(self: *AppSession) void {
    const wide = self.loaded_config.config.ambiguous_width == .wide;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                self.enqueueCoreCommandForTerm(term, .{ .set_ambiguous_wide = wide }) catch {};
            }
        }
    }
}

/// text.emoji-width reload를 라이브 코어에 재적용한다(reapplyAmbiguousWidth와 같은 best-effort 패턴 — 이후
/// putCell부터 새 폭, 이미 저장된 셀은 옛 폭 유지). 이모지(VS16/키캡)를 2칸으로 볼지를 라이브 surface에 반영.
pub fn reapplyEmojiWidth(self: *AppSession) void {
    const wide = self.loaded_config.config.emoji_width == .wide;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                self.enqueueCoreCommandForTerm(term, .{ .set_emoji_wide = wide }) catch {};
            }
        }
    }
}

/// cursor.shape reload를 라이브 코어에 재적용한다(createTerm chokepoint와 같은 값을 이미 떠 있는 surface에도 —
/// reapplyEmojiWidth와 같은 위임·best-effort 패턴). **앱이 DECSCUSR로 모양을 명시 중인 Term은 코어가 스스로
/// 건너뛴다**(setDefaultCursorShape의 `cursor_shape_overridden` 가드) — 설정 한 번 바꿨다고 vim insert-mode의
/// bar가 block으로 튀지 않는다. 원격 Term도 같은 명령이 host core에서 같은 규칙으로 적용된다.
pub fn reapplyDefaultCursorShape(self: *AppSession) void {
    const shape = configCursorShape(self);
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                self.enqueueCoreCommandForTerm(term, .{ .set_default_cursor_shape = shape }) catch {};
            }
        }
    }
}

pub fn keyHintConfig(self: *const AppSession) KeyHintConfigAbi {
    const kh = self.loaded_config.config.keyhint;
    return .{
        .enabled = kh.enabled,
        .delay_ms = kh.delay,
        .modifier = switch (kh.modifier) {
            .command => 0,
            .control => 1,
            .option => 2,
        },
    };
}

/// 파일 본문 메뉴가 떠 있고, 그것 말고 입력을 가져갈 오버레이가 없나. 다른 모달(확인·팔레트·세팅)이 함께
/// 열려 있으면 그쪽이 이긴다 — 그 화면들은 키가 Zig로 가야 동작한다.
pub fn fileContentMenuHoldsWebFocus(self: *const AppSession) bool {
    if (self.file_content_menu == null) return false;
    const h = &self.chrome_host;
    return !(h.confirm.open or h.notifications.open or h.find.open or h.palette.open or h.settings.open);
}

/// config `cursor.shape`(config enum)를 코어/렌더가 쓰는 terminal enum으로 옮긴다. 두 enum은 **멤버 순서가 다르다**
/// (config: block/bar/underline, terminal: block/underline/bar) — `@intFromEnum` 재해석은 bar↔underline을 조용히
/// 뒤바꾼다. 명시 switch라 어느 쪽에 variant가 늘면 컴파일이 멈춘다(unfocusedCursorMode와 같은 경계 규율).
pub fn configCursorShape(self: *const AppSession) terminal.CursorShape {
    return switch (self.appearance.cursor.shape) {
        .block => .block,
        .bar => .bar,
        .underline => .underline,
    };
}

/// config `input.link-detection`을 자동 감지 범위(scopes)로 변환한다. osc8-only=자동 감지 끔(OSC 8 명시 링크만),
/// web=http(s)만(이전 동작), full=추가 스킴+절대/홈/상대/bare 경로. hover·클릭이 매 호출 현재 config를 넘겨
/// reload-safe(코어는 토글 상태를 안 든다 — word_separators 주입과 동형). 단일 출처: docs/link-detection.md.
pub fn linkScopesFromConfig(self: *const AppSession) terminal.LinkScopes {
    return switch (self.loaded_config.config.input.link_detection) {
        .osc8_only => terminal.link_scopes_none,
        .web => terminal.link_scopes_web,
        .full => terminal.link_scopes_full,
    };
}

/// 세팅 GUI에서 바뀐 config 키를 write-back 예약 집합에 넣는다(중복은 무시 — 한 번만). 키는 스키마 정적 리터럴.
pub fn markConfigKeyDirty(self: *AppSession, key: []const u8) void {
    for (self.config_dirty_keys.items) |k| if (std.mem.eql(u8, k, key)) return;
    self.config_dirty_keys.append(self.allocator, key) catch {};
}

/// 반영할 config 키가 있으면 true(앱→파일 write-back 예약 — 사이드바 view options·세팅 화면 공용). 여기선 비우지
/// 않는다 — serializeConfig가 성공적으로 직렬화한 뒤 비운다(실패 시 키 유지→다음 tick 재시도). Swift가 매 tick
/// take_sidebar_config_dirty(ABI 이름 유지)로 drain해 1이면 serialize→atomic write한다.
pub fn takeConfigDirty(self: *AppSession) bool {
    inline for (pending_writeback_lists) |n| if (@field(self, n).items.len > 0) return true;
    return self.theme_preset_persist != null; // 리스트가 아닌 optional이라 registry 밖 — 따로 본다
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

/// **config 파일을 실제로 쓰는 경로**가 대상 경로를 얻을 때 쓰는 안전 chokepoint(configPath는 resolve+캐시 read 전용).
/// 테스트에서 config_path_buffer를 tmp로 명시 redirect하지 않았으면 빈 경로를 돌려줘 쓰기를 스킵시킨다 — zig build
/// test(macOS)가 실제 사용자 config($HOME/.config/maru/config)를 절대 못 건드리게 한다. 과거 reset 테스트가 tmp 가드를
/// 빠뜨려 실 config를 헤더만 남기고 날린 footgun을 **개별 테스트 가드 누락과 무관하게 원천 차단**한다(새 config-쓰기
/// 테스트가 가드를 잊어도 안전). 프로덕션(is_test=false)은 configPath() 그대로. 새 config-파일 writer는 이걸 거쳐야 한다.
pub fn configWritePath(self: *AppSession) []const u8 {
    if (builtin.is_test and self.config_path_buffer == null) return &.{};
    return configPath(self);
}

/// 액션의 단축키를 **완전히 해제**한다(keybind 행 Backspace). 현재 effective chord Y(resolver — 사용자/빌트인 무관)를
/// 구해, 사용자 바인딩이면 빼고 + Y를 loaded_config.unbinds에 넣어 빌트인이어도 ignored로 만든다(라이브 즉시 — resolver가
/// unbinds를 본다). 영속: 사용자 줄 제거 예약 + `keybind = Y = unbind` 지시어 예약. 펜딩 rebind 취소. 해제 후
/// chordForAction(Y가 unbinds라)이 null → 행은 "(미지정)". 이미 미지정이면 notice.
pub fn unbindActionEntry(self: *AppSession, entry: command_catalog.Entry) void {
    const a = self.loaded_config.arena.allocator();
    const resolver = self.loaded_config.keyBindingResolver();
    if (command_catalog.chordForAction(resolver, entry.action) == null) {
        settingsMessageOrNotice(self, .set_no_chord_assigned);
        return;
    }
    // ① 사용자 바인딩 제거(사용자 chord는 제거만으로 죽는다 — config 줄 제거 + 라이브 슬라이스에서 드롭).
    var list: std.ArrayList(config_mod.AppBinding) = .empty;
    var found_user = false;
    for (self.loaded_config.keybindings) |b| {
        if (std.meta.eql(b.action, entry.action)) {
            found_user = true; // 드롭
        } else list.append(a, b) catch return;
    }
    if (found_user) self.loaded_config.keybindings = list.toOwnedSlice(a) catch return;
    // ② **빌트인 chord 전부**를 unbind(except=null) — 사용자 chord만 빼면 빌트인이 되살아나므로 모두 죽인다(완전 해제).
    // 다중-chord 빌트인도 전부(리뷰 #840). rebind(완전 교체)와 공유하는 unbindBuiltinChords 단일 출처.
    input_ops.unbindBuiltinChords(self, entry, null);
    self.rebuildCommandCatalog();
    // 펜딩 rebind 취소(unbind가 우선).
    var i: usize = 0;
    while (i < self.config_keybind_rebinds.items.len) {
        if (std.mem.eql(u8, self.config_keybind_rebinds.items[i].action, entry.key)) {
            _ = self.config_keybind_rebinds.orderedRemove(i);
        } else i += 1;
    }
    if (found_user) markKeybindRemoved(self, entry.key); // 영속: 사용자 줄 제거
    self.metal_dirty = true;
}

/// 전역(OS) 액션의 단축키를 해제한다(전역 행 Backspace — unbindActionEntry의 글로벌 미러). 빌트인 기본이 없으므로
/// global_bindings에서 그 액션 줄을 빼면 끝이다(in-app처럼 unbind 지시어가 필요 없다). 안 묶여 있으면 notice. 펜딩
/// rebind는 취소하고 줄 제거를 예약(markGlobalRemoved → removeGlobalKeybindLines). OS 반영은 재시작 후.
pub fn unbindGlobalEntry(self: *AppSession, entry: command_catalog.GlobalEntry) void {
    const a = self.loaded_config.arena.allocator();
    if (command_catalog.chordForGlobalAction(self.loaded_config.global_bindings, entry.action) == null) {
        settingsMessageOrNotice(self, .set_no_global_chord_assigned);
        return;
    }
    var list: std.ArrayList(config_mod.GlobalBinding) = .empty;
    for (self.loaded_config.global_bindings) |b| {
        if (b.action == entry.action) continue; // 드롭(중복 포함 전부)
        list.append(a, b) catch return;
    }
    self.loaded_config.global_bindings = list.toOwnedSlice(a) catch return;
    cancelGlobalRebind(self, entry.key); // 펜딩 rebind 취소(제거가 우선)
    markGlobalRemoved(self, entry.key); // 영속: 전역 줄 제거
    // 라이브 OS 재등록(PR2) — 그 액션이 빠진 global_bindings로 global_hotkeys를 다시 빌드하고 dirty(Swift drain → 재등록).
    input_ops.rebuildGlobalHotkeys(self) catch {};
    self.global_hotkeys_dirty = true;
    self.metal_dirty = true;
}

/// 전역 keybind 줄 제거 예약(중복 한 번만). action은 command_catalog 정적 키. serializeConfig가 removeGlobalKeybindLines로 반영.
pub fn markGlobalRemoved(self: *AppSession, action_key: []const u8) void {
    for (self.config_global_removed.items) |k| if (std.mem.eql(u8, k, action_key)) return;
    self.config_global_removed.append(self.allocator, action_key) catch {};
}

/// 펜딩 전역 rebind를 액션 키로 취소한다(unbind가 rebind보다 우선 — 같은 액션을 바꿨다 지우면 결국 제거).
pub fn cancelGlobalRebind(self: *AppSession, action_key: []const u8) void {
    var i: usize = 0;
    while (i < self.config_global_rebinds.items.len) {
        if (std.mem.eql(u8, self.config_global_rebinds.items[i].action, action_key)) {
            _ = self.config_global_rebinds.orderedRemove(i);
        } else i += 1;
    }
}

/// keybind 줄 제거 예약(중복 한 번만). action은 command_catalog 정적 키. serializeConfig가 removeKeybindLines로 반영.
pub fn markKeybindRemoved(self: *AppSession, action_key: []const u8) void {
    for (self.config_keybind_removed.items) |k| if (std.mem.eql(u8, k, action_key)) return;
    self.config_keybind_removed.append(self.allocator, action_key) catch {};
}

/// 현재 sidebar 토글(show_branch/show_folder)을 config 파일에 반영할 새 텍스트를 직렬화한다(owned, 다음
/// 호출/deinit까지 유효 — workspace_buffer 패턴). 원본 config를 읽어 updateConfigText로 부분 갱신하므로
/// 주석·미파싱 키를 보존한다. Swift가 받아 config 경로에 atomic write한다(앱→config 방향). 원본이 없거나
/// 읽기 실패면 빈 텍스트로 두 키를 append한다(forgiving — config가 없어도 토글이 새 파일을 만든다).
pub fn serializeConfig(self: *AppSession) ![]const u8 {
    if (self.sidebar_config_buffer) |b| {
        self.allocator.free(b);
        self.sidebar_config_buffer = null;
    }
    const path = configPath(self);
    const owned: ?[]u8 = if (path.len == 0)
        null
    else
        std.Io.Dir.cwd().readFileAlloc(self.io, path, self.allocator, .limited(1 << 20)) catch null;
    defer if (owned) |o| self.allocator.free(o);
    const original: []const u8 = owned orelse &.{};

    // 바뀐 키만 현재값으로 부분 갱신(override-only write-back, S0-1b 일반화 — 사이드바 view options·세팅 화면
    // 공용). 값은 스키마 직렬화(configKeyValues)가 단일 출처라 타입별 손코드 중복이 없다. 성공 시 dirty 집합을
    // 비운다(아래) — updateConfigForKeys가 실패하면 try가 빠져나가 키가 남아 다음 tick 재시도된다.
    var text = try config_mod.updateConfigForKeys(self.allocator, original, self.loaded_config.config, self.config_dirty_keys.items);
    errdefer self.allocator.free(text); // 이후 체이닝 패스(theme.preset·keybind 등) 중 try 실패 시 현재 text 버퍼 누수 방지 —
    // text는 패스마다 reassign되므로 errdefer는 항상 최신 버퍼를 free하고, 성공 경로(sidebar_config_buffer 보관·return)에선 미발화.
    // 테마 프리셋 영속(팔레트 포함): `theme.preset = <name>` 줄을 set/update한다 — configKeyValues가 derive 키
    // theme.preset을 emit하지 않으므로(round-trip 대칭 유지) 전용 패스로 쓴다. 충돌할 개별 theme.* override는
    // config_removed_keys(아래 제거 패스)가 빼므로 base 프리셋 색이 온전히 산다. 성공해야 비운다(실패 시 재시도).
    if (self.theme_preset_persist) |name| {
        const kv = [_]config_mod.ConfigKeyValue{.{ .key = "theme.preset", .value = name }};
        const chained = try config_mod.updateConfigText(self.allocator, text, &kv);
        self.allocator.free(text);
        text = chained;
        self.theme_preset_persist = null;
    }
    // keybind 재바인딩은 `keybind = chord = action` 줄이라 key=value 패스로 못 다룬다 — 전용 패스로 체이닝한다
    // (앞 단계 결과 텍스트 위에 keybind 줄을 action 기준 갱신/추가). 성공해야 양쪽 dirty를 비운다.
    if (self.config_keybind_rebinds.items.len > 0) {
        const chained = try config_mod.updateKeybindLines(self.allocator, text, self.config_keybind_rebinds.items);
        self.allocator.free(text);
        text = chained;
        self.config_keybind_rebinds.clearRetainingCapacity();
    }
    // 삭제 예약된 키(env 변수 삭제 등)는 줄을 제거한다 — 갱신 패스 뒤에 체이닝(삭제 우선). 같은 키를 갱신+삭제 둘 다면
    // 갱신이 먼저 줄을 남겨도 여기서 빠진다.
    if (self.config_removed_keys.items.len > 0) {
        const chained = try config_mod.removeConfigLines(self.allocator, text, self.config_removed_keys.items);
        self.allocator.free(text);
        text = chained;
        self.config_removed_keys.clearRetainingCapacity();
    }
    // keybind unbind — `keybind = chord = action` 줄을 action 기준으로 제거(keybind 갱신 패스 뒤, 제거 우선).
    if (self.config_keybind_removed.items.len > 0) {
        const chained = try config_mod.removeKeybindLines(self.allocator, text, self.config_keybind_removed.items);
        self.allocator.free(text);
        text = chained;
        self.config_keybind_removed.clearRetainingCapacity();
    }
    // 터미널 매크로 upsert — `keybind = <chord> = text:/esc:/ctrl:` 줄을 chord 기준 갱신/추가(전용 패스).
    if (self.config_terminal_macros.items.len > 0) {
        const chained = try config_mod.updateTerminalMacroLines(self.allocator, text, self.config_terminal_macros.items);
        self.allocator.free(text);
        text = chained;
        self.config_terminal_macros.clearRetainingCapacity();
    }
    // 터미널 매크로 삭제 — `keybind = <chord> = <매크로 rhs>` 줄을 chord 기준 제거(갱신 패스 뒤, 제거 우선).
    if (self.config_terminal_macro_removes.items.len > 0) {
        const chained = try config_mod.removeTerminalMacroLines(self.allocator, text, self.config_terminal_macro_removes.items);
        self.allocator.free(text);
        text = chained;
        self.config_terminal_macro_removes.clearRetainingCapacity();
    }
    // 빌트인 죽이기 — `keybind = chord = unbind` 지시어 append(사용자 줄 제거 뒤, 마지막).
    if (self.config_keybind_unbinds.items.len > 0) {
        const chained = try config_mod.appendKeybindUnbinds(self.allocator, text, self.config_keybind_unbinds.items);
        self.allocator.free(text);
        text = chained;
        self.config_keybind_unbinds.clearRetainingCapacity();
    }
    // stale unbind 정리 — 재바인딩으로 부활한 chord의 옛 `keybind = chord = unbind` 줄을 제거(append 패스 뒤 — append가 안
    // 쓴 chord를 여기서 빼 정리; 같은 chord를 죽임+부활 둘 다면 append는 펜딩에서 빠져 안 쓰고 여기서 옛 줄만 뺀다).
    if (self.config_keybind_unbind_removed.items.len > 0) {
        const chained = try config_mod.removeKeybindUnbindLines(self.allocator, text, self.config_keybind_unbind_removed.items);
        self.allocator.free(text);
        text = chained;
        self.config_keybind_unbind_removed.clearRetainingCapacity();
    }
    // 전역(OS) 단축키 재바인딩 — `keybind = global:<chord> = <action>` 줄을 action 기준 갱신/추가(in-app keybind 줄과
    // 별도 패스, global: 좌측만 매칭). 기존 keybind 체이닝 뒤에 둔다.
    if (self.config_global_rebinds.items.len > 0) {
        const chained = try config_mod.updateGlobalKeybindLines(self.allocator, text, self.config_global_rebinds.items);
        self.allocator.free(text);
        text = chained;
        self.config_global_rebinds.clearRetainingCapacity();
    }
    // 전역 단축키 해제 — `keybind = global:<chord> = <action>` 줄을 action 기준 제거(전역 갱신 패스 뒤, 제거 우선).
    if (self.config_global_removed.items.len > 0) {
        const chained = try config_mod.removeGlobalKeybindLines(self.allocator, text, self.config_global_removed.items);
        self.allocator.free(text);
        text = chained;
        self.config_global_removed.clearRetainingCapacity();
    }
    self.sidebar_config_buffer = text;
    self.config_dirty_keys.clearRetainingCapacity();
    return text;
}

/// quick terminal 표시 옵션(config에서 파싱). Swift가 auto_hide/screen/chrome·재생성 판정에 쓴다. 이 세션의
/// **현재** config를 읽는 라이브 스냅샷 — Swift가 매 토글마다 다시 불러 설정 변경을 반영한다(세션-불변 아님).
/// 패널 사각형은 quickTerminalFrames(위치 기하)가 따로 계산한다.
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

/// claude 설정 디렉터리(존재 여부는 호출부가 판정). 규칙 자체는 OS 중립이라 session 레이어가 갖고, 여기서는
/// env 조회만 해서 넘긴다. 결과는 `buf` 소유.
pub fn claudeConfigDir(buf: []u8) ?[]const u8 {
    const env = struct {
        fn get(name: [*:0]const u8) ?[]const u8 {
            return if (std.c.getenv(name)) |value| std.mem.span(value) else null;
        }
    };
    return maru.session.agent_statusline.configDir(buf, env.get("CLAUDE_CONFIG_DIR"), env.get("HOME"));
}

/// 안내 메시지를 **세팅 모달이 열려 있으면 폼 상단 인라인 배너**(§6.9)로, 아니면 일반 notice 토스트로 보인다.
/// keybind 녹음(세팅 안)의 검증 실패("등록 불가 키")·충돌 경고가 showNotice로 가면 dismissMessageOverlays가 세팅
/// 모달까지 닫아(단일-오버레이 불변식) 사용자가 녹음하던 화면이 사라지던 문제를 고친다 — 배너는 세팅 자체 그리드
/// 안 텍스트라 모달을 닫지 않고 위에 얹힌다. 세팅 밖(메뉴 rebind 등)에서 온 같은 메시지는 기존대로 토스트.
pub fn settingsMessageOrNotice(self: *AppSession, message: maru.i18n.Key) void {
    // 문자열이 아니라 **키**를 받는다(docs/i18n.md §7.2 1차) — 이 자리에 리터럴을 넘기면 컴파일되지 않는다.
    settingsMessageOrNoticeText(self, maru.i18n.t(message));
}

/// 값이 끼어드는 문장용 — `key`를 §6.3 보간으로 채운 뒤 같은 경로로 보낸다.
///
/// 버퍼가 모자라면 `i18n.format`이 UTF-8 경계에서 자르므로 별도 폴백 문장을 두지 않는다. 여기 끼는 값은
/// 명령 이름(영문 카탈로그 title)이라 짧고, 잘린 문장보다 짧은 대체 문장이 더 낫다고 볼 근거가 없다.
pub fn settingsMessageOrNoticeFmt(self: *AppSession, key: maru.i18n.Key, args: []const maru.i18n.Arg) void {
    var buf: [192]u8 = undefined;
    settingsMessageOrNoticeText(self, maru.i18n.format(&buf, maru.i18n.t(key), args));
}

/// 표시 경로 자체(세팅이 열려 있으면 배너, 아니면 토스트). 위 둘이 해석을 끝낸 뒤 여기로 모인다.
fn settingsMessageOrNoticeText(self: *AppSession, message: []const u8) void {
    if (self.chrome_host.settings.open) {
        self.chrome_host.settings.setMessage(message);
        self.metal_dirty = true;
    } else {
        self.showNotice(message);
    }
}

// --- 호출 그래프로 소유가 확인돼 옮겨 온 함수 ---
// 이름에 도메인 단어가 없어 F 시리즈가 못 잡았고, 이 그룹을 과반으로 부르며 만지는 상태도 이 그룹이다.

/// 필드가 있는 섹션만 선언 순으로 모은다(좌측 네비 — config-gui §4). 미지정 필드가 있으면 끝에 "기타". arena 소유.
pub fn buildSectionList(self: *AppSession, arena: std.mem.Allocator) ![]SettingsSectionEntry {
    var bools: std.ArrayList(config_mod.schema.BoolField) = .empty;
    try config_mod.schema.appendBoolFields(arena, self.loaded_config.config, &bools);
    var nums: std.ArrayList(config_mod.schema.NumberField) = .empty;
    try config_mod.schema.appendNumberFields(arena, self.loaded_config.config, &nums);
    var enums: std.ArrayList(config_mod.schema.EnumField) = .empty;
    try config_mod.schema.appendEnumFields(arena, self.loaded_config.config, &enums);
    var texts: std.ArrayList(config_mod.schema.TextField) = .empty;
    try config_mod.schema.appendTextFields(arena, self.loaded_config.config, &texts);
    var colors: std.ArrayList(config_mod.schema.ColorField) = .empty;
    try config_mod.schema.appendColorFields(arena, self.loaded_config.config, &colors);
    var list: std.ArrayList(SettingsSectionEntry) = .empty;
    inline for (@typeInfo(config_mod.Section).@"enum".fields) |ef| {
        const sec: config_mod.Section = @enumFromInt(ef.value);
        if (settingsSectionHasField(bools.items, nums.items, enums.items, texts.items, colors.items, sec))
            try list.append(arena, .{ .section = sec, .label = settingsSectionLabel(sec) });
    }
    if (settingsSectionHasField(bools.items, nums.items, enums.items, texts.items, colors.items, null))
        try list.append(arena, .{ .section = null, .label = settingsSectionLabel(null) });
    return list.items;
}

/// 행 집합이 바뀐 **직후** 선택 행을 `key` 에 다시 맞춘다.
///
/// `selected` 는 인덱스일 뿐이라 통과 행 집합이 바뀌면 그 자리에 다른 설정이 들어와도 모르고, 그 상태로
/// Enter 를 누르면 **사용자가 열지도 않은 키**에 값이 써진다. 그래서 인덱스가 아니라 키로 다시 앉힌다.
///
/// 집합을 바꾸는 축은 **파일**이다(`reloadConfig` — 다른 창이나 편집기가 `env.*`·`macro.*` 를 더하거나
/// 지운다). 언어 축은 필터가 언어를 안 보게 되면서 사라졌다(`settingsRowMatches` 의 계약).
///
/// 새 언어의 라벨이 쿼리와 안 맞아 행 자체가 사라지면(한국어 라벨로 찾아 놓고 영어로 바꾼 경우) 쿼리를
/// 지운다 — 편집 중인 행이 목록 밖에 있는 상태가 그대로 남는 것보다, 필터가 풀려 그 행이 다시 보이는
/// 쪽이 되돌리기 쉽다.
///
/// **쿼리를 지우는 것만으로는 부족하다 — 섹션도 함께 옮긴다.** 검색은 교차 섹션이라(`cross`), 사용자는
/// `font` 섹션에 서서 `terminal` 섹션의 행을 고를 수 있다. 그 상태에서 쿼리만 지우면 섹션 게이트가
/// 되살아나 그 행이 **여전히 목록에 없고**, `selected` 는 남의 행을 가리킨 채로 남는다.
fn reanchorSelectedByKey(self: *AppSession, key: []const u8) void {
    // 행이 아직 필터를 통과하더라도 **행 수는 이미 달라졌을 수 있다** — `doc` 이 언어를 타므로 통과
    // 집합 자체가 바뀐다. 그래서 이 갱신은 두 분기 **앞**에 둔다. 앞선 판은 폴백에만 두어, 행이 남아
    // 있는 흔한 경우에 `settings.count` 가 옛 값으로 멈추고 ↑↓ 가 옛 셈 안에 갇혔다.
    refreshSettingsFieldCount(self);
    if (indexOfSettingsKey(self, key)) |i| {
        self.chrome_host.settings.selected = i;
        return;
    }
    self.chrome_host.settings.endSearch();
    if (sectionIndexOfSettingsKey(self, key)) |sec| self.chrome_host.settings.section = sec;
    refreshSettingsFieldCount(self); // 섹션까지 옮겼으면 행 수가 또 바뀐다
    if (indexOfSettingsKey(self, key)) |i| self.chrome_host.settings.selected = i;
}

/// 현재 필터를 통과하는 행들에서 `key` 의 행 인덱스. `currentSectionFields` 와 **같은 순서**(bool → number
/// → enum → text → color)로 세야 핸들러의 인덱싱과 어긋나지 않는다.
fn indexOfSettingsKey(self: *AppSession, key: []const u8) ?usize {
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const cf = currentSectionFields(self, scratch.allocator()) catch return null;
    // `keyAtRow` 의 **역방향**이다. 둘이 같은 순서·같은 합성 규칙을 써야 하므로 여기서 따로 세지 않고
    // 그 함수를 행마다 돌린다 — 규칙을 두 벌 두면 그 둘이 갈리는 순간 조용히 어긋난다.
    var probe: [128]u8 = undefined;
    for (0..cf.total()) |i| {
        const candidate = keyAtRow(cf, i, &probe) orelse continue;
        if (std.mem.eql(u8, candidate, key)) return i;
    }
    return null;
}

/// `key` 가 사는 섹션의 **네비 인덱스**(`settings.section` 이 쓰는 그 축).
///
/// 스키마를 훑지 않고 **실제 행 목록을 섹션마다 만들어 본다.** 스키마만 보면 `theme.preset`·`shell.args`·
/// `workspace.root`·`env.*`·`macro.*` 처럼 **행은 있는데 스키마 필드가 아닌** 것들을 못 찾고, 그 행에서는
/// 섹션 이동이 통째로 무동작이 된다 — 폴백이 광고한 것을 못 지킨다. 행을 만드는 함수가 그 합성 행까지
/// 아는 유일한 자리이므로 그것을 쓴다.
///
/// 쿼리가 이미 비워진 뒤에 불린다는 것이 전제다(그래야 섹션 게이트가 살아 있다). 비용은 섹션 수만큼의
/// arena 빌드인데, **앵커 행이 사라졌을 때만** 도는 폴백이라 문제가 되지 않는다.
fn sectionIndexOfSettingsKey(self: *AppSession, key: []const u8) ?usize {
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const sections = buildSectionList(self, scratch.allocator()) catch return null;
    const saved = self.chrome_host.settings.section;
    defer self.chrome_host.settings.section = saved; // 못 찾으면 원래 자리로 — 찾으면 호출부가 덮는다
    for (0..sections.len) |i| {
        self.chrome_host.settings.section = i;
        if (indexOfSettingsKey(self, key) != null) return i;
    }
    return null;
}

/// 현재 선택 섹션(settings.section)으로 필터한 필드(bool→num→enum→text→color + 팔레트·단축키 특수 행).
/// arena 소유. 핸들러가 `selected` 를 이 순서로 매핑한다.
///
/// **첫 문장이 `loaded_config.config` 를 쓴다**(다른 창에서 바꾼 앱 전역 policy 되동기화). 읽기 전용처럼
/// 보이는 이름과 달리 부수 효과가 있고, 실제로 그것이 회귀를 두 번 냈다 — 부르는 자리를 늘릴 때 이
/// 문장이 그 순간 도는 것이 맞는지 먼저 본다.
pub fn currentSectionFields(self: *AppSession, arena: std.mem.Allocator) !SettingsSectionFields {
    // 다른 Window에서 바꾼 앱 전역 policy를 이 창의 설정 스냅샷에도 반영한다. 이 동기화 뒤 field 생성과
    // toggle의 `new_value` 계산이 같은 SSOT를 보므로 stale 창이 값을 되돌리지 않는다.
    self.loaded_config.config.session.keep_alive_after_quit = app_session_mod.appKeepAlivePolicyValue();
    const sections = try buildSectionList(self, arena);
    const sel_sec: ?config_mod.Section = if (sections.len > 0)
        sections[@min(self.chrome_host.settings.section, sections.len - 1)].section
    else
        null;
    var bools_all: std.ArrayList(config_mod.schema.BoolField) = .empty;
    try config_mod.schema.appendBoolFields(arena, self.loaded_config.config, &bools_all);
    var nums_all: std.ArrayList(config_mod.schema.NumberField) = .empty;
    try config_mod.schema.appendNumberFields(arena, self.loaded_config.config, &nums_all);
    var enums_all: std.ArrayList(config_mod.schema.EnumField) = .empty;
    try config_mod.schema.appendEnumFields(arena, self.loaded_config.config, &enums_all);
    var texts_all: std.ArrayList(config_mod.schema.TextField) = .empty;
    try config_mod.schema.appendTextFields(arena, self.loaded_config.config, &texts_all);
    var colors_all: std.ArrayList(config_mod.schema.ColorField) = .empty;
    try config_mod.schema.appendColorFields(arena, self.loaded_config.config, &colors_all);
    // 합성 행도 `doc_key` 를 함께 싣는다. 이 행들의 필터 판정은 **그 자리에서** 키를 직접 넘기므로 지금은
    // 안 실어도 무해하지만, 나중에 누군가 `doc_key` 로 다시 거르면 그 행에서만 조용히 언어 의존이 되살아난다.
    // 검색 쿼리(폼 필터 — 라벨/키 부분일치). 모든 행 종류에 같은 settingsRowMatches 규칙을 적용해 view·핸들러 인덱싱이
    // 일관되게 한다(필터는 여기 단일 출처). 빈 쿼리면 전부 통과. **쿼리가 있으면(cross) 섹션 게이트를 무시**해 전 섹션의
    // 매칭 행을 보여준다(교차 섹션 검색 — 설정이 어느 섹션인지 몰라도 찾는다). 빈 쿼리면 현재 섹션만.
    const q = self.chrome_host.settings.searchQuery();
    const cross = q.len > 0;
    var bools: std.ArrayList(config_mod.schema.BoolField) = .empty;
    for (bools_all.items) |b| if ((cross or b.section == sel_sec) and settingsRowMatches(b.doc_key, b.doc, b.key, q)) try bools.append(arena, b);
    var nums: std.ArrayList(config_mod.schema.NumberField) = .empty;
    for (nums_all.items) |n| if ((cross or n.section == sel_sec) and settingsRowMatches(n.doc_key, n.doc, n.key, q)) try nums.append(arena, n);
    var enums: std.ArrayList(config_mod.schema.EnumField) = .empty;
    for (enums_all.items) |e| if ((cross or e.section == sel_sec) and settingsRowMatches(e.doc_key, e.doc, e.key, q)) try enums.append(arena, e);
    // theme 섹션엔 named 테마 프리셋(특수 — schema 필드 아님)을 synthetic enum 행으로 주입한다(dropdown 재사용).
    // 현재값은 config 색에서 derive(매칭 프리셋 @tagName 또는 "사용자 지정"). 핸들러가 key="theme.preset"만 특수 처리.
    // follow-system이 켜지면 색을 preset-light/dark가 정하므로 단일 theme.preset 행은 무의미(골라도 곧 덮임) — 숨긴다(리뷰 C).
    if ((cross or sel_sec == .theme) and !self.loaded_config.config.theme_follow_system and settingsRowMatches(.set_theme_preset, "", "theme.preset", q)) {
        // 프리셋 행을 enum 구간 **맨 앞**에 둬 테마 섹션 최상단(색·팔레트보다 먼저)에 도드라지게 한다. 표시값은
        // 활성(themePresetActive)이면 그 프리셋명, 아니면 "사용자 지정"(detect=null이거나 사용자가 명시로 푼 경우).
        const cur_name: []const u8 = if (self.themePresetActive()) @tagName(detectThemePreset(self.loaded_config.config.theme).?) else maru.i18n.t(.set_custom);
        try enums.insert(arena, 0, .{ .key = "theme.preset", .doc = maru.i18n.t(.set_theme_preset), .doc_key = .set_theme_preset, .current = cur_name, .section = .theme });
    }
    var texts: std.ArrayList(config_mod.schema.TextField) = .empty;
    for (texts_all.items) |t| if ((cross or t.section == sel_sec) and settingsRowMatches(t.doc_key, t.doc, t.key, q)) try texts.append(arena, t);
    // terminal 섹션엔 특수 키(schema 필드 아님)를 synthetic text 행으로 주입한다(theme.preset enum 선례 — .text 위젯
    // 재사용, 핸들러가 key로 라우팅). shell.args(공백-토큰 리스트) + env.<KEY> 각 행(값 편집) + env 추가 행(KEY=VALUE).
    if (cross or sel_sec == .terminal) {
        if (settingsRowMatches(.set_shell_args_ph, "", "shell.args", q))
            try texts.append(arena, .{ .key = "shell.args", .doc = maru.i18n.t(.set_shell_args_ph), .doc_key = .set_shell_args_ph, .value = try std.mem.join(arena, " ", self.loaded_config.config.shell.args), .section = .terminal });
        for (self.loaded_config.config.env) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue; // 형식 오류(= 없음)는 건너뜀
            if (settingsRowMatches(null, entry[0..eq], "env", q))
                try texts.append(arena, .{ .key = try std.fmt.allocPrint(arena, "env.{s}", .{entry[0..eq]}), .doc = entry[0..eq], .value = entry[eq + 1 ..], .section = .terminal });
        }
        if (settingsRowMatches(.set_env_ph, "", "env", q))
            try texts.append(arena, .{ .key = "env.", .doc = maru.i18n.t(.set_env_ph), .doc_key = .set_env_ph, .value = "", .section = .terminal }); // 추가 행(빈 KEY = sentinel)
    }
    // 입력 섹션엔 사용자 터미널 매크로(keybind = chord = text:/esc:/ctrl:)를 rhs 편집 text 행으로 노출한다(env 특수 행
    // 선례). 라벨=chord 표시(formatChord), 값=rhs config 문자열(macroRhsString, 예 "text:hello"). 키="macro.<chord
    // config>"로 커밋/삭제 시 chord를 식별한다(toConfigString). 마지막에 "추가" 행(빈 sentinel "macro.").
    if (cross or sel_sec == .input) {
        for (self.loaded_config.terminal_bindings) |b| {
            var disp_buf: [command_catalog.max_chord_display_len]u8 = undefined;
            const disp = command_catalog.formatChord(b.chord, &disp_buf);
            if (settingsRowMatches(null, disp, "macro", q)) {
                var chord_buf: [64]u8 = undefined; // 매치된 행만 chord config 표기 계산(필터된 행 낭비 제거)
                const chord_cfg = b.chord.toConfigString(&chord_buf);
                try texts.append(arena, .{ .key = try std.fmt.allocPrint(arena, "macro.{s}", .{chord_cfg}), .doc = try arena.dupe(u8, disp), .value = try macroRhsString(arena, b.input), .section = .input });
            }
        }
        if (settingsRowMatches(.set_macro_ph, "", "macro", q))
            try texts.append(arena, .{ .key = "macro.", .doc = maru.i18n.t(.set_macro_ph), .doc_key = .set_macro_ph, .value = "", .section = .input }); // 추가 행(빈 chord = sentinel)
    }
    // Workspace 섹션엔 시작 디렉터리(workspace.root)를 합성 text 행으로 노출한다(schema 필드 아님 — loader 명시
    // 핸들러 특수 키, shell.args 선례). 값=현재 root(빈 값=상속 cwd). 커밋은 setWorkspaceRoot(loader와 형식 검증 공유).
    if (cross or sel_sec == .workspace) {
        if (settingsRowMatches(.set_cwd_ph, "", "workspace.root", q))
            try texts.append(arena, .{ .key = "workspace.root", .doc = maru.i18n.t(.set_cwd_ph), .doc_key = .set_cwd_ph, .value = self.loaded_config.config.workspace.root, .section = .workspace });
    }
    var colors: std.ArrayList(config_mod.schema.ColorField) = .empty;
    for (colors_all.items) |c| if ((cross or c.section == sel_sec) and settingsRowMatches(c.doc_key, c.doc, c.key, q)) try colors.append(arena, c);
    // theme 섹션엔 ANSI 16색 팔레트 그리드 한 행, input 섹션엔 command_catalog 액션별 keybind 행(둘 다 특수 — schema
    // 필드 아님). 검색 쿼리로도 필터한다(palette=한 행, keybind=매칭 액션만). 핸들러가 selected 인덱스로 라우팅.
    // 교차 검색에선 palette(theme)·keybind(input)가 함께 나올 수 있어 keybindRowStart가 palette 오프셋을 더한다.
    var keybinds: std.ArrayList(command_catalog.Entry) = .empty;
    if (cross or sel_sec == .input) {
        for (command_catalog.entries) |entry| if (settingsRowMatches(null, entry.title, entry.key, q)) try keybinds.append(arena, entry);
    }
    const palette_on = (cross or sel_sec == .theme) and settingsRowMatches(.set_ansi_palette, "", "theme.palette", q);
    // 구문 색 역할 행 — theme 섹션이고 검색에 걸린 것만 센다. **검색이 역할 이름으로 걸린다**
    // (`keyword`·`string` — 그것이 행을 그리드가 아니라 열하나로 둔 이유다).
    var syntax_rows: usize = 0;
    var syntax_mask: u32 = 0;
    if (cross or sel_sec == .theme) {
        inline for (@typeInfo(config_mod.theme.SyntaxRole).@"enum".fields) |f| {
            const role: config_mod.theme.SyntaxRole = @enumFromInt(f.value);
            if (settingsRowMatches(.set_syntax_color, maru.session.syntax_theme.roleLabel(role), comptime config_mod.theme.syntaxRoleKey(role), q)) {
                syntax_rows += 1;
                syntax_mask |= @as(u32, 1) << @intCast(f.value);
            }
        }
    }
    // `.global_hotkey` 섹션엔 전역(OS) 단축키 녹음 행(GlobalEntry별 한 행 — schema 필드 아님, keybind 특수 행 선례).
    // 검색 쿼리로도 필터(매칭 액션만). 핸들러가 selected>=globalKeybindRowStart면 global_entries로 라우팅.
    var globals: std.ArrayList(command_catalog.GlobalEntry) = .empty;
    if (cross or sel_sec == .global_hotkey) {
        for (command_catalog.global_entries) |entry| if (settingsRowMatches(entry.title_key, "", entry.key, q)) try globals.append(arena, entry);
    }
    return .{ .bools = bools.items, .nums = nums.items, .enums = enums.items, .texts = texts.items, .colors = colors.items, .has_palette = palette_on, .syntax_roles = syntax_rows, .syntax_mask = syntax_mask, .keybind_entries = keybinds.items, .global_entries = globals.items };
}

/// 드롭다운 팝업의 **선택 행 변형을 절대 인덱스(idx)로 config에 set + 라이브 적용**한다(팝업은 안 닫음). enum=setEnumIndex,
/// font.family=그 폰트 setText, theme.preset=applyThemePresetIndex. **persist=false면 파일 영속을 예약하지 않는다(인메모리
/// 라이브만)** — 라이브 프리뷰(↑↓)는 persist=false로, 확정만 persist=true로 부른다. **미리보기가 영속까지 하면 취소해도
/// 파일엔 미리본 값이 써져 커스텀이 사라지는 데이터 손실**이 났기에(code-review high) 영속은 확정에서만 한다.
pub fn applyDropdownIndex(self: *AppSession, idx: usize, persist: bool) void {
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const cf = currentSectionFields(self, scratch.allocator()) catch return;
    const sel = self.chrome_host.settings.selected;
    const after_nums = cf.bools.len + cf.nums.len;
    const after_enums = after_nums + cf.enums.len;
    const after_texts = after_enums + cf.texts.len;
    if (sel >= after_nums and sel < after_enums) {
        const e = cf.enums[sel - after_nums];
        if (std.mem.eql(u8, e.key, "theme.preset")) {
            applyThemePresetIndex(self, idx, persist); // synthetic 프리셋 — 절대 인덱스로 적용
            return;
        }
        if (config_mod.schema.setEnumIndex(&self.loaded_config.config, e.key, idx)) {
            // follow-system preset-light/dark는 라이브 색도 새 프리셋으로 재해석해야 한다(cycle 경로와 동일 특수 처리).
            if (self.loaded_config.config.theme_follow_system and
                (std.mem.eql(u8, e.key, "theme.preset-dark") or std.mem.eql(u8, e.key, "theme.preset-light")))
            {
                self.follow_applied_dark = null;
                self.applyFollowSystemTheme();
            } else {
                reapplyLoadedConfig(self);
            }
            if (persist) markConfigKeyDirty(self, e.key);
        }
        return;
    }
    if (sel >= after_enums and sel < after_texts) {
        const ti = sel - after_enums;
        if (ti < cf.texts.len and std.mem.eql(u8, cf.texts[ti].key, "font.family")) {
            const fonts = config_mod.theme.bundled_font_families;
            // idx < fonts.len = 번들 폰트(정적 문자열이라 dupe 불요), idx >= fonts.len = "직접 입력…" 슬롯 → 프리뷰는 원본
            // 폰트(스냅샷)를 다시 보여준다(선택 표시용, 안 바꿈). "직접 입력" 확정은 applyDropdownSelection이 편집을 연다.
            const value: []const u8 = if (idx < fonts.len) fonts[idx] else self.dropdown_snapshot_font;
            if (config_mod.schema.setText(&self.loaded_config.config, "font.family", value)) {
                reapplyLoadedConfig(self);
                if (persist and idx < fonts.len) markConfigKeyDirty(self, "font.family");
            }
        }
        return;
    }
}

/// 드롭다운 프리뷰를 **열 때 값으로 인메모리 복원**한다(영속 안 함 — 미리보기가 영속을 안 했으니 파일은 원본 그대로).
/// font/theme.preset은 스냅샷으로, enum은 original 인덱스로 되돌린다(인덱스로 못 되살리는 커스텀 폰트·테마는 스냅샷이 정확히 복원).
pub fn restoreDropdownSnapshot(self: *AppSession) void {
    switch (self.dropdown_snapshot_kind) {
        .font => {
            if (config_mod.schema.setText(&self.loaded_config.config, "font.family", self.dropdown_snapshot_font))
                reapplyLoadedConfig(self); // 인메모리만 — markDirty 없음(파일은 원본 폰트 그대로)
        },
        .preset => {
            self.loaded_config.config.theme = self.dropdown_snapshot_theme;
            self.theme_user_custom = self.dropdown_snapshot_user_custom;
            reapplyLoadedConfig(self);
        },
        .none => applyDropdownIndex(self, self.chrome_host.settings.dropdown.original, false), // enum — 인덱스 복원(persist=false, 안 바뀐 값 영속 안 함)
    }
}

/// 인라인 편집 커밋(text 행 Enter) — settings.editText()를 config arena에 dupe해 schema.setText로 적용하고 라이브
/// 재resolve + write-back 예약. 편집 종료. 라이브/직렬화가 계속 슬라이스를 읽으므로 loaded_config.arena가 소유한다.
pub fn commitSelectedText(self: *AppSession) void {
    self.chrome_host.settings.clearMessage(); // 새 커밋 시도 — 직전 안내 배너 정리(아래 env/macro 검증이 실패 시 다시 세운다)
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const cf = currentSectionFields(self, scratch.allocator()) catch return;
    const sel = self.chrome_host.settings.selected;
    const after_enums = cf.bools.len + cf.nums.len + cf.enums.len;
    const after_texts = after_enums + cf.texts.len;
    const after_colors = after_texts + cf.colors.len;
    defer self.chrome_host.settings.cancelEdit(); // 성공/실패 무관 편집 종료(키는 다시 네비로)
    // 팔레트 그리드 행은 setText가 아니라 setPaletteColor로 커밋(theme.palette.N은 schema 필드가 아님). 그 칸 키를
    // dirty로 — write-back(serialize)이 set된 palette.N을 이미 직렬화하므로 영속된다.
    if (cf.paletteRowIndex()) |pi| if (sel == pi) {
        const gi = @min(self.chrome_host.settings.grid_cell, 15);
        const owned = self.loaded_config.arena.allocator().dupe(u8, self.chrome_host.settings.editText()) catch return;
        if (config_mod.schema.setPaletteColor(&self.loaded_config.config, gi, owned)) {
            reapplyLoadedConfig(self);
            markConfigKeyDirty(self, config_mod.schema.paletteKey(gi));
        }
        return;
    };
    // number 행(bools.len..after_nums): 입력 박스 편집 버퍼를 f64로 파싱해 setNumber(범위 clamp) + 라이브 적용 + 영속.
    // 파싱 실패면 값 유지(편집만 종료 — defer cancelEdit). 슬라이더 대체 경로.
    const after_nums = cf.bools.len + cf.nums.len;
    if (sel >= cf.bools.len and sel < after_nums) {
        const ni = sel - cf.bools.len;
        if (ni >= cf.nums.len) return;
        const nkey = cf.nums[ni].key;
        const parsed = std.fmt.parseFloat(f64, std.mem.trim(u8, self.chrome_host.settings.editText(), " ")) catch return;
        if (config_mod.schema.setNumber(&self.loaded_config.config, nkey, parsed)) {
            reapplyLoadedConfig(self);
            markConfigKeyDirty(self, nkey);
        }
        return;
    }
    const editor = self.chrome_host.settings.editText();
    // text 행(after_enums..after_texts): shell.args·env.*는 특수 setter, 나머지 schema 텍스트(폰트 패밀리·term 등)는 setText.
    if (sel >= after_enums and sel < after_texts) {
        const ti = sel - after_enums;
        if (ti >= cf.texts.len) return;
        const tkey = cf.texts[ti].key;
        if (std.mem.eql(u8, tkey, "shell.args")) {
            self.setShellArgs(editor); // 공백-토큰 분리
        } else if (std.mem.eql(u8, tkey, "workspace.root")) {
            workspace_ops.setWorkspaceRoot(self, editor); // 시작 디렉터리 — loader와 형식 검증 공유
        } else if (std.mem.eql(u8, tkey, "env.")) {
            addEnvVar(self, editor); // 추가 행 — "KEY=VALUE" 파싱
            refreshSettingsFieldCount(self); // 행 늘어남 → count 갱신(연속 추가가 키보드로 도달 가능)
        } else if (std.mem.startsWith(u8, tkey, "env.")) {
            self.setEnvVar(tkey["env.".len..], editor); // 기존 env 값 편집
        } else if (std.mem.eql(u8, tkey, "macro.")) {
            addTerminalMacro(self, editor); // 추가 행 — "chord = text:..." 파싱
            refreshSettingsFieldCount(self); // 행 늘어남 → count 갱신(연속 추가가 키보드로 도달 가능)
        } else if (std.mem.startsWith(u8, tkey, "macro.")) {
            setTerminalMacro(self, tkey["macro.".len..], editor); // 기존 매크로 rhs 편집
        } else {
            // schema 텍스트(.text) — config arena dupe 후 검증·적용.
            const owned = self.loaded_config.arena.allocator().dupe(u8, editor) catch return;
            if (config_mod.schema.setText(&self.loaded_config.config, tkey, owned)) {
                reapplyLoadedConfig(self);
                markConfigKeyDirty(self, tkey);
                // 셸 경로가 실행 불가능하면(없는 경로·`~`·상대경로·디렉터리·비실행 파일) spawn 시 기본 셸로
                // 폴백된다(resolveConfiguredShell). 저장은 그대로 두되 즉시 안내해, 예전처럼 다음 실행에 앱이 조용히
                // 종료되지 않음을 알린다. `~`/시작 디렉터리는 이 필드가 아니라 config workspace.root임을 함께 안내.
                if (std.mem.eql(u8, tkey, "shell.command")) {
                    // setText는 validatedText로 **trim해 저장**하므로(schema.zig) 안내는 저장된 값을 검사한다 —
                    // owned(untrimmed)를 쓰면 "/bin/zsh "처럼 공백이 섞인 유효 경로를 실행 불가로 오탐한다.
                    const stored = self.loaded_config.config.shell.command;
                    if (stored.len > 0 and !isExecutablePath(stored))
                        self.chrome_host.settings.setMessage(maru.i18n.t(.set_shell_not_found));
                }
            }
        }
        return;
    }
    // color hex 행(after_texts..after_colors): setText로 커밋(hex 검증).
    if (sel >= after_texts and sel < after_colors) {
        const ci = sel - after_texts;
        if (ci >= cf.colors.len) return;
        const owned = self.loaded_config.arena.allocator().dupe(u8, editor) catch return;
        if (config_mod.schema.setText(&self.loaded_config.config, cf.colors[ci].key, owned)) {
            reapplyLoadedConfig(self);
            markConfigKeyDirty(self, cf.colors[ci].key);
        }
        return;
    }
}

/// HSV picker 확정(Enter → settings_color_picked) — settings.pickerRgb()를 #rrggbb로 직렬화해 선택 color 행 키에
/// setText로 적용(commitSelectedText의 color 분기와 같은 인덱스 매핑·setter). 라이브 재resolve + write-back 예약 후
/// picker 닫기. hex 문자열은 loaded_config.arena 소유(라이브/직렬화가 계속 읽는다). picker 외 행이면 무동작.
/// 역할 → config 키. `syntaxRoleKey` 는 `comptime role` 을 받으므로 런타임 값에서 쓰려면 이 다리가
/// 필요하다 — 문자열은 여전히 그 함수 하나에서 나온다(두 곳에 적지 않는다).
fn syntaxRoleKeyOf(role: config_mod.theme.SyntaxRole) []const u8 {
    return switch (role) {
        inline else => |r| comptime config_mod.theme.syntaxRoleKey(r),
    };
}

/// 선택 인덱스가 **구문 색 행**이면 그 역할을 돌려준다. 세 핸들러(열기·커밋·되돌리기)가 같은 함수를
/// 써야 인덱싱이 갈리지 않는다 — 색 행이 검색으로 걸러지므로 **보이는 행만 세어** 순서를 맞춘다.
fn syntaxRoleAt(cf: anytype, sel: usize) ?config_mod.theme.SyntaxRole {
    const start = cf.syntaxRowStart() orelse return null;
    if (sel < start or sel >= start + cf.syntax_roles) return null;
    const ri = cf.syntaxRoleIndexAt(sel - start) orelse return null;
    return @enumFromInt(ri);
}

pub fn commitPickerColor(self: *AppSession) void {
    defer self.chrome_host.settings.closePicker(); // 성공/실패 무관 picker 종료(폼 복귀)
    var scratch = std.heap.ArenaAllocator.init(self.allocator);
    defer scratch.deinit();
    const cf = currentSectionFields(self, scratch.allocator()) catch return;
    const sel = self.chrome_host.settings.selected;
    const after_texts = cf.bools.len + cf.nums.len + cf.enums.len + cf.texts.len;
    const after_colors = after_texts + cf.colors.len;
    // sel<after_texts면 다음 줄 `sel - after_texts`가 usize 언더플로(panic)라 그 범위 가드는 필수다(방어가 아니라
    // 언더플로 안전). picker는 color 행에서만 열리므로 sel은 [after_texts, after_colors)이지만, 호출 계약을 코드로 못박는다.
    // 구문 색 행에서 열린 picker — schema 키가 아니라 `theme.syntax[role]` 슬롯에 담는다.
    if (syntaxRoleAt(cf, sel)) |role| {
        const hex = rgbToHex(self.loaded_config.arena.allocator(), self.chrome_host.settings.pickerRgb()) catch return;
        self.loaded_config.config.theme.syntax[@intFromEnum(role)] = hex;
        // 키는 `syntaxRoleKey` 단일 출처다 — 손으로 적으면 로더와 갈린다.
        markConfigKeyDirty(self, syntaxRoleKeyOf(role));
        reapplyLoadedConfig(self);
        self.metal_dirty = true;
        return;
    }
    if (sel < after_texts or sel >= after_colors) return;
    const ci = sel - after_texts;
    if (ci >= cf.colors.len) return;
    const hex = rgbToHex(self.loaded_config.arena.allocator(), self.chrome_host.settings.pickerRgb()) catch return;
    if (config_mod.schema.setText(&self.loaded_config.config, cf.colors[ci].key, hex)) {
        reapplyLoadedConfig(self);
        markConfigKeyDirty(self, cf.colors[ci].key);
    }
}

/// env 추가 행 커밋 — "KEY=VALUE" 텍스트를 파싱해 setEnvVar로 upsert. '=' 없거나 KEY(양끝 trim)가 비면 notice.
pub fn addEnvVar(self: *AppSession, text: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse {
        settingsMessageOrNotice(self, .set_env_format);
        return;
    };
    const name = std.mem.trim(u8, text[0..eq], &std.ascii.whitespace);
    if (name.len == 0) {
        settingsMessageOrNotice(self, .set_env_key_empty);
        return;
    }
    self.setEnvVar(name, text[eq + 1 ..]);
}

/// 터미널 매크로 upsert(rhs 편집·추가 공유) — chord_str(config 표기)에 rhs(text:/esc:/ctrl:)를 묶는다. rhs 파싱 실패·
/// chord 표기 오류·충돌이면 notice(미적용). 성공 시 loaded_config.terminal_bindings를 라이브 교체(resolver가 즉시 반영)
/// + write-back 예약(config_terminal_macros). config-gui §6.7.
pub fn setTerminalMacro(self: *AppSession, chord_str: []const u8, rhs_str: []const u8) void {
    const a = self.loaded_config.arena.allocator();
    const rhs_trim = std.mem.trim(u8, rhs_str, &std.ascii.whitespace);
    const chord = config_mod.keybinding.KeyChord.parse(chord_str) catch {
        settingsMessageOrNotice(self, .set_chord_parse_failed);
        return;
    };
    const macro = config_mod.parseMacroRhs(a, rhs_trim) orelse {
        settingsMessageOrNotice(self, .set_macro_format);
        return;
    };
    // 같은 chord면 교체, 없으면 추가(한 chord=한 매크로).
    var list: std.ArrayList(config_mod.keybinding.TerminalBinding) = .empty;
    var found = false;
    for (self.loaded_config.terminal_bindings) |b| {
        if (b.chord.eql(chord)) {
            list.append(a, .{ .chord = chord, .input = macro }) catch return;
            found = true;
        } else list.append(a, b) catch return;
    }
    if (!found) list.append(a, .{ .chord = chord, .input = macro }) catch return;
    const new_binds = list.toOwnedSlice(a) catch return;
    // 충돌 검증(app↔terminal·중복 chord) — 새 셋으로 resolver를 만들어 validate. 실패면 적용 안 함(best-effort 경고).
    var probe = self.loaded_config.keyBindingResolver();
    probe.terminal_bindings = new_binds;
    probe.validate() catch {
        settingsMessageOrNotice(self, .set_chord_conflict);
        return;
    };
    // validate는 **사용자** 바인딩만 본다(loaded_config.keybindings엔 빌트인 없음, default_*는 resolve 내부에만).
    // 그래서 빌트인 chord(Cmd+T 등)는 위 검증을 통과해 매크로가 조용히 빌트인을 가린다 — 차단은 아니고(오버라이드는
    // 사용자 의도, rebind 충돌 경고와 동일 last-wins) **경고**로 알린다(code-review max). unbinds로 죽인 chord는 제외.
    if (!resolverUnbinds(self.loaded_config.unbinds, chord) and input_ops.chordShadowsBuiltin(chord))
        settingsMessageOrNotice(self, .set_macro_overrides_default);
    self.loaded_config.terminal_bindings = new_binds; // 라이브 반영(다음 keyBindingResolver가 본다)
    // 이 chord를 죽인 옛 `keybind = <chord> = unbind` 지시어가 남아 있으면 정리(rebind 경로와 동일) — 안 그러면
    // 나중에 이 매크로를 지웠을 때 stale unbind가 빌트인을 영영 비활성으로 둔다(code-review max).
    self.clearStaleUnbind(chord);
    // write-back 예약 — 같은 chord 대기 예약(추가/삭제)을 먼저 비워 중복·모순을 막고 새로 단다. chord·rhs는
    // loaded_config.arena 소유(serialize drain까지 유효).
    self.cancelPendingMacro(chord_str);
    const chord_owned = a.dupe(u8, chord_str) catch return;
    const rhs_owned = a.dupe(u8, rhs_trim) catch return;
    self.config_terminal_macros.append(self.allocator, .{ .chord = chord_owned, .rhs = rhs_owned }) catch return;
    self.metal_dirty = true;
}

/// 매크로 추가 행 커밋 — "chord = text:..." 텍스트를 파싱(첫 `=`로 chord/rhs 분리, chord 정규화)해 setTerminalMacro로
/// upsert. `=` 없거나 chord가 비면 notice.
pub fn addTerminalMacro(self: *AppSession, text: []const u8) void {
    const eq = std.mem.indexOfScalar(u8, text, '=') orelse {
        settingsMessageOrNotice(self, .set_macro_line_format);
        return;
    };
    const chord_part = std.mem.trim(u8, text[0..eq], &std.ascii.whitespace);
    if (chord_part.len == 0) {
        settingsMessageOrNotice(self, .set_chord_empty);
        return;
    }
    // chord 정규화(파싱 → toConfigString) — 행 키·write-back 줄이 표준 표기를 쓰게.
    const chord = config_mod.keybinding.KeyChord.parse(chord_part) catch {
        settingsMessageOrNotice(self, .set_chord_parse_failed);
        return;
    };
    var chord_buf: [64]u8 = undefined;
    setTerminalMacro(self, chord.toConfigString(&chord_buf), text[eq + 1 ..]);
}

/// 테마 프리셋을 **절대 인덱스**로 적용한다(드롭다운 팝업 — applyThemePreset의 dir-순환 짝). idx가 프리셋 수 이상
/// (="사용자 지정")이면 **열 때 스냅샷한 원본 커스텀 색으로 복원** + 잠금 해제(예전엔 잠금만 풀어 미리본 프리셋 색이
/// 남던 데이터 손실 — code-review high 수정). idx<n이면 그 프리셋 색을 깔고 라이브 적용, persist=true일 때만 파일 영속.
pub fn applyThemePresetIndex(self: *AppSession, idx: usize, persist: bool) void {
    const n = @typeInfo(config_mod.theme.ThemePreset).@"enum".fields.len;
    if (idx >= n) {
        // "사용자 지정" — 원본 커스텀 색(스냅샷)으로 되돌리고 잠금 해제. 커스텀은 theme.preset 줄을 안 남기므로 별도 영속 없음
        // (미리보기가 persist를 안 했으니 파일의 커스텀 색 줄이 그대로라, 여기선 인메모리 복원만 하면 파일도 정합).
        self.loaded_config.config.theme = self.dropdown_snapshot_theme;
        self.theme_user_custom = true;
        reapplyLoadedConfig(self);
        return;
    }
    self.theme_user_custom = false;
    const preset: config_mod.theme.ThemePreset = @enumFromInt(idx);
    self.loaded_config.config.theme = config_mod.theme.presetColors(preset);
    reapplyLoadedConfig(self);
    if (persist) persistThemePreset(self, preset); // 확정에서만 파일에 theme.preset 예약(미리보기는 인메모리만)
}

/// 프리셋을 **통째로 영속**한다(4색만 쓰던 옛 한계 해소 — ANSI 16색 팔레트·파생색 포함, 리뷰). `theme.preset = <name>`
/// 한 줄을 쓰도록 예약하고(serializeConfig가 set/update), 그 줄과 충돌할 개별 theme.* 색·palette override 줄은 제거
/// 예약한다 — 로더가 theme.preset을 통째 프리셋 색으로 펼치므로 남은 override가 위에 덮어쓰면 반쪽만 적용되기 때문.
pub fn persistThemePreset(self: *AppSession, preset: config_mod.theme.ThemePreset) void {
    const a = self.loaded_config.arena.allocator();
    // @tagName은 underscore(gruvbox_dark), config 파일은 dash(gruvbox-dark) — 로더 parseEnum이 받는 형식으로 변환.
    self.theme_preset_persist = std.mem.replaceOwned(u8, a, @tagName(preset), "_", "-") catch null;
    // 개별 override 줄 제거(theme.preset이 base를 깔므로 남으면 충돌). 4 주 색 + 16 팔레트.
    markConfigKeyRemoved(self, "theme.background");
    markConfigKeyRemoved(self, "theme.foreground");
    markConfigKeyRemoved(self, "theme.cursor");
    markConfigKeyRemoved(self, "theme.selection");
    for (0..16) |i| {
        const k = std.fmt.allocPrint(a, "theme.palette.{d}", .{i}) catch continue;
        markConfigKeyRemoved(self, k);
    }
    // 구문 색 역할 override도 같은 이유로 지운다(native-editor-ui.md §9.0). 이것이 빠지면 메모리에서는
    // 프리셋이 색을 가져가는데(applyThemePresetIndex가 `config.theme`를 통째로 간다) 파일에는 옛 줄이
    // 남아, 다음에 열 때 **줄 순서에 따라** 되살아나거나 안 되살아난다 — 위 주석이 말한 "반쪽만 적용"이다.
    // 키는 `syntaxRoleKey` 단일 출처라 역할이 늘어도 여기서 빠지지 않는다.
    inline for (@typeInfo(config_mod.theme.SyntaxRole).@"enum".fields) |f| {
        markConfigKeyRemoved(self, comptime config_mod.theme.syntaxRoleKey(@enumFromInt(f.value)));
    }
}

/// Swift NSOpenPanel이 고른 파일의 절대경로를 받아 window.background-image에 적용한다 — config arena에 dupe해 setText,
/// 라이브 반영(reapplyLoadedConfig가 metal_dirty → 다음 frame ensureBackgroundImage가 새 경로 디코드) + 영속 예약
/// (markConfigKeyDirty). 빈 경로(취소 등)면 무동작 — 지우기는 행 Backspace가 담당. (배경 이미지 파일 선택)
pub fn providePickedFile(self: *AppSession, path: []const u8) void {
    if (path.len == 0) return;
    const owned = self.loaded_config.arena.allocator().dupe(u8, path) catch return;
    if (config_mod.schema.setText(&self.loaded_config.config, "window.background-image", owned)) {
        reapplyLoadedConfig(self);
        markConfigKeyDirty(self, "window.background-image");
    }
}

// 새 섹션이 **좌측 네비에 실제로 뜨는지** 본다.
//
// 스키마에 키를 등록하고 `Section` 에 변형을 더하는 것만으로 GUI 에 나오리라 **믿을 근거가 없다** —
// 섹션은 "필드가 있는 섹션만" 모으고(`settingsSectionHasField`), 그 판정은 스키마가 이 필드를
// `EnumField` 로 펼쳤을 때만 참이다. 하나라도 어긋나면 설정을 만들었는데 **아무 데서도 못 고른다**.
// 그 상태는 컴파일도 되고 파싱도 되므로 다른 어떤 테스트도 잡지 않는다.
test "ui.language 는 세팅 좌측 네비의 app 섹션에 뜬다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sections = try buildSectionList(session, arena);
    var has_app = false;
    for (sections) |entry| {
        if (entry.section == .app) has_app = true;
    }
    try std.testing.expect(has_app);

    // 그 섹션 안에 실제로 이 키가 있어야 한다 — 섹션만 뜨고 행이 비면 빈 화면이다.
    var enums: std.ArrayList(config_mod.schema.EnumField) = .empty;
    try config_mod.schema.appendEnumFields(arena, session.loaded_config.config, &enums);
    var found = false;
    for (enums.items) |e| {
        if (std.mem.eql(u8, e.key, "ui.language")) {
            try std.testing.expectEqual(config_mod.Section.app, e.section.?);
            found = true;
        }
    }
    try std.testing.expect(found);
}

// 네비 **순서**를 못 박는다.
//
// `buildSectionList` 가 `Section` 선언 순으로 모으므로, enum 을 재정렬하면 사용자가 보는 순서가 바뀐다 —
// 알파벳 정렬 같은 무해해 보이는 이유로 충분히 일어난다. 언어가 첫 자리여야 하는 이유는 읽을 수 없는
// 언어로 뜬 화면에서는 **다른 섹션을 고르는 것부터** 어렵기 때문이다. 그 의도를 주석이 아니라 여기서 든다.
test "세팅 네비의 첫 섹션은 app 이다 — 읽을 수 없는 화면에서 언어부터 찾을 수 있어야 한다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const sections = try buildSectionList(session, arena);
    try std.testing.expect(sections.len > 0);
    try std.testing.expectEqual(config_mod.Section.app, sections[0].section.?);
}

// 표시 목록과 저장 변형의 **순서**를 잠근다.
//
// 팝업 선택은 인덱스로 적용된다(`enumIndex` → `dropdown.show(len, cur_idx)` → 고른 인덱스로 저장).
// 그래서 표시 목록의 순서가 스키마 변형 순서와 갈리면 **"한국어"를 골랐는데 `en` 이 저장된다** —
// 크래시도 경고도 없이 다른 언어가 된다. 지금은 둘 다 같은 enum(`i18n.Preference`)을 도므로 정의상
// 맞지만, 표시 목록을 손으로 나열하는 쪽으로 바뀌는 순간 그 보장이 사라진다.
test "언어 드롭다운: 표시 목록이 저장 변형과 같은 순서다" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const cfg: config_mod.theme.Config = .{};
    const shown = try uiLanguageVariants(arena);
    const stored = (try config_mod.schema.enumVariants(arena, cfg, "ui.language")) orelse
        return error.KeyHasNoVariants;

    try std.testing.expectEqual(stored.len, shown.len);
    for (stored, 0..) |token, i| {
        const pref = std.meta.stringToEnum(maru.i18n.Preference, token) orelse return error.UnknownVariant;
        try std.testing.expectEqualStrings(maru.i18n.preferenceLabel(pref), shown[i]);
    }
}

// 표시명이 저장값과 **실제로 다른지** 본다. 같으면 이 기능이 아무것도 안 한 것인데, 위 순서 테스트는
// 그 상태에서도 통과한다(양쪽이 나란히 `auto`·`en`·`ko`가 되므로).
test "언어 드롭다운: 표시명은 저장 토큰과 다르다 — 언어 이름은 자기 언어로 적힌다" {
    const lang_before = maru.i18n.lang();
    defer maru.i18n.setLang(lang_before);

    try std.testing.expectEqualStrings("English", maru.i18n.preferenceLabel(.en));
    try std.testing.expectEqualStrings("한국어", maru.i18n.preferenceLabel(.ko));

    // 언어 이름은 **현재 UI 언어와 무관하게 고정**이다 — 영어 화면에서 "한국어"를 "Korean"으로 쓰면
    // 한국어만 읽는 사람이 자기 줄을 못 알아본다.
    maru.i18n.setLang(.en);
    try std.testing.expectEqualStrings("한국어", maru.i18n.preferenceLabel(.ko));
    maru.i18n.setLang(.ko);
    try std.testing.expectEqualStrings("English", maru.i18n.preferenceLabel(.en));

    // `auto` 는 언어 이름이 아니라 동작이라 **읽는 사람의 언어를 따른다.**
    maru.i18n.setLang(.en);
    const auto_en = maru.i18n.preferenceLabel(.auto);
    maru.i18n.setLang(.ko);
    const auto_ko = maru.i18n.preferenceLabel(.auto);
    try std.testing.expect(!std.mem.eql(u8, auto_en, auto_ko));
}

/// 필터를 통과하는 행들 중 `i` 번째 행의 키(테스트용 — `indexOfSettingsKey` 의 역방향).
///
/// `keyAtRow` 에 위임하고 **결과를 복사한다.** 규칙을 두 벌 두면 갈리고, 복사를 빼면 `env.`·`macro.` 행의
/// 키가 arena 소유라 이 함수가 돌려준 슬라이스가 곧장 dangling 이 된다(프로덕션 쪽에서 이미 한 번 낸 결함).
fn settingsKeyAt(self: *AppSession, allocator: std.mem.Allocator, i: usize) !?[]const u8 {
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const cf = try currentSectionFields(self, scratch.allocator());
    var probe: [128]u8 = undefined;
    const key = keyAtRow(cf, i, &probe) orelse return null;
    return try allocator.dupe(u8, key);
}

// **`keyAtRow` 는 모든 행에 답해야 한다** — 시나리오가 아니라 성질로 못 박는다.
//
// 4차가 잡은 결함은 "`keyAtRow` 가 여덟 종류 중 다섯만 안다"였고, 그것을 막는 것이 시나리오 테스트
// 하나(전역 단축키 행)뿐이었다. 그러면 `SettingsSectionFields` 에 **아홉 번째 행 종류**가 붙는 순간
// 같은 구멍이 조용히 다시 생긴다 — 앵커가 `null` 이 되어 재고정이 통째로 안 돌고, 그 상태는 컴파일도
// 되고 다른 테스트도 전부 통과한다. 행 수(`total()`)와 앵커 가능 행 수가 **같다**는 것이 계약이다.
test "keyAtRow 는 모든 섹션의 모든 행에 앵커를 준다 (행 종류가 늘어도)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    session.chrome_host.settings.show();

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const sections = try buildSectionList(session, arena_state.allocator());
    try std.testing.expect(sections.len > 0); // 섹션이 0 이면 아래 루프가 아무것도 안 본다

    var rows_seen: usize = 0;
    for (0..sections.len) |sec| {
        session.chrome_host.settings.section = sec;
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const cf = try currentSectionFields(session, arena.allocator());
        var probe: [128]u8 = undefined;
        for (0..cf.total()) |i| {
            rows_seen += 1;
            if (keyAtRow(cf, i, &probe) == null) {
                std.debug.print("\n섹션 {d} 의 {d}번 행에 앵커가 없다 — 행 종류가 늘었는데 `keyAtRow` 가 모른다.\n", .{ sec, i });
                return error.TestUnexpectedResult;
            }
        }
    }
    // 행을 하나도 안 봤으면 위 루프가 무의미하다 — 그 상태도 "전부 앵커 가능" 으로 통과한다.
    try std.testing.expect(rows_seen > 0);
}

// 앵커를 **못 잡는** 경로에도 행 수 갱신은 와야 한다.
//
// 쿼리가 0행을 통과시키면 붙잡을 키가 없고 재고정은 할 것이 없다. 그래도 통과 행 수는 달라졌으므로
// `setFieldCount` 는 줘야 한다 — 안 주면 `moveSelection` 이 옛 셈으로 wrap 해 ↑↓ 가 갇힌다.
test "앵커를 못 잡아도 행 수는 다시 알린다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    session.chrome_host.settings.show();

    // 아무 행도 통과시키지 않는 쿼리 — 그러면 선택이 가리킬 행이 없어 앵커가 `null` 이다.
    session.chrome_host.settings.startSearch();
    for ("zzqqxx") |c| session.chrome_host.settings.appendSearchCp(c);
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const empty = try currentSectionFields(session, arena.allocator());
        try std.testing.expectEqual(@as(usize, 0), empty.total()); // 전제가 성립하는지 먼저 본다
    }
    session.chrome_host.settings.setFieldCount(999); // 낡은 셈을 심어 둔다

    var probe_buf: [128]u8 = undefined;
    restoreSelectedRowKey(session, captureSelectedRowKey(session, &probe_buf));

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const visible = try currentSectionFields(session, arena.allocator());
    try std.testing.expectEqual(visible.total(), session.chrome_host.settings.count);
}

// 행 집합이 **파일 때문에** 바뀌어도 선택은 같은 설정에 남는다.
//
// `reloadConfig` 는 설정 폼을 닫지 않으므로(닫는 것은 confirm/notice 경로뿐) 폼이 열린 채로 돈다. 파일이
// `env.*`·`macro.*` 를 더하거나 지우면 통과 행 집합이 그 자리에서 바뀌는데, `selected` 는 인덱스라 그 자리에
// 다른 설정이 들어와도 모른다. **이것은 언어와 무관한 축**이라 필터를 언어 독립으로 만든 것으로는 안 닫힌다 —
// 행 집합을 바꾸는 것이 언어가 아니라 파일이기 때문이다.
//
// **`reloadConfig` 를 실제로 부른다.** 앞선 판은 `capture` → 바꿈 → `restore` 세 줄을 테스트가 손으로 올바른
// 순서에 늘어놓고 그 셋이 서로 맞는지만 봤다. 그러면 정작 **프로덕션 배선**(그 세 줄이 `reloadConfig` 안
// 어디에 놓였는가)은 무엇을 해도 초록이다 — 적대적 검증이 capture 를 맨 뒤로 옮기고 두 줄을 통째로 지워도
// 통과하는 것을 보였다. 순서가 이 배선의 전부인데 그 순서를 안 재고 있었다.
test "파일이 행을 더해도 선택은 같은 설정에 남는다 (reload 축)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;

    // config 를 임시 파일로 박는다 — 개발자의 실제 파일을 읽지도 쓰지도 않는다.
    const io = std.Io.Threaded.global_single_threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root = root_buf[0..try tmp.dir.realPath(io, &root_buf)];
    const cfg_path = try std.fmt.allocPrintSentinel(allocator, "{s}/config", .{root}, 0);
    defer allocator.free(cfg_path);

    const prev = std.c.getenv("MARU_CONFIG");
    defer if (prev) |v| {
        _ = app_session_mod.setenv("MARU_CONFIG", v, 1);
    } else {
        _ = app_session_mod.unsetenv("MARU_CONFIG");
    };
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "env.ZZZ_LAST = 1\n" });
    try std.testing.expectEqual(@as(c_int, 0), app_session_mod.setenv("MARU_CONFIG", cfg_path.ptr, 1));

    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(io, allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    session.chrome_host.settings.show();
    const home = sectionIndexOfSettingsKey(session, "env.") orelse return error.TestUnexpectedResult;
    session.chrome_host.settings.section = home;
    refreshSettingsFieldCount(session);

    // 앵커는 env 행들 **뒤에** 서는 sentinel("환경변수 추가" 행)이다. 앞에 행이 늘면 밀린다.
    const anchor = "env.";
    const before = indexOfSettingsKey(session, anchor) orelse return error.TestUnexpectedResult;
    session.chrome_host.settings.selected = before;

    // 파일이 env 변수를 하나 더 얻는다 → 다음 reload 에서 행이 는다.
    try tmp.dir.writeFile(io, .{ .sub_path = "config", .data = "env.AAA_FIRST = 1\nenv.ZZZ_LAST = 1\n" });
    reloadConfig(session);

    // 선택은 여전히 그 행이고, 행 수도 다시 알렸다.
    const after = indexOfSettingsKey(session, anchor) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(after, session.chrome_host.settings.selected);
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const visible = try currentSectionFields(session, arena.allocator());
    try std.testing.expectEqual(visible.total(), session.chrome_host.settings.count);

    // 이 자리가 **실제로 밀리는** 자리였는지 — 아니면 위 단언이 아무것도 안 지킨다.
    try std.testing.expect(after != before);
}

// **통과 행 집합과 순서는 `i18n.lang()` 에 의존하지 않는다** — 이 브랜치의 핵심 계약을 전칭으로 못 박는다.
//
// 앞서 이 결함은 "언어가 바뀌는 지점마다 선택을 다시 앉히는" 방식으로 막았는데, 그 방식은 지점을 하나씩
// 세는 것이라 **네 번 연속으로 구멍을 냈다**(경로 넷 중 둘만 막음 → 스키마 밖 행을 못 봄 → 앵커를 뜨는
// 쪽이 행 종류 다섯만 앎 → 다른 창은 그 지점을 아예 안 지남). 세는 방식으로는 다 셀 수 없다는 것이
// 그 네 번이 보여 준 것이다. 그래서 지점이 아니라 **성질**을 잰다.
//
// 성질이 참이면 선택뿐 아니라 `count`·스크롤 위치·열린 팝업의 인덱스·사용자의 검색어까지 전부 따라온다 —
// 흔들릴 것이 없으므로 붙잡을 것도 없다.
test "통과 행 집합과 순서는 화면 언어에 의존하지 않는다 (i18n 계약 §5.2)" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    const lang_before = maru.i18n.lang();
    defer maru.i18n.setLang(lang_before);
    session.chrome_host.settings.show();

    // 두 언어의 문장 조각·config 키 조각·짧은 접두어를 섞는다. 짧은 쿼리가 통과 행이 가장 많이 갈리는
    // 자리라 일부러 넣는다(증분 검색이 실제로 지나는 길이기도 하다).
    const queries = [_][]const u8{
        "",
        "언어",
        "표시",
        "커서",
        "폰트",
        "테마",
        "알림",
        "font",
        "cursor",
        "theme",
        "language",
        "notification",
        "shell",
        "o",
        "on",
        "in",
        "the",
        "to",
        "ui",
        ".",
        "zzqq", // 아무것도 통과 못 하는 쿼리 — 빈 집합도 두 언어에서 같아야 한다
    };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const sections = try buildSectionList(session, arena_state.allocator());
    try std.testing.expect(sections.len > 0);

    var compared: usize = 0;
    for (queries) |query| {
        for (0..sections.len) |sec| {
            session.chrome_host.settings.section = sec;
            session.chrome_host.settings.startSearch();
            var it = (try std.unicode.Utf8View.init(query)).iterator();
            while (it.nextCodepoint()) |cp| session.chrome_host.settings.appendSearchCp(cp);

            // 같은 상태를 두 언어로 각각 펼쳐 **키 나열**을 통째로 비교한다. 집합이 아니라 나열이라
            // 순서까지 함께 본다 — 순서가 갈리면 인덱스가 미끄러지는 것은 마찬가지다.
            const ko = try settingsRowKeys(session, allocator, .ko);
            defer freeKeyList(allocator, ko);
            const en = try settingsRowKeys(session, allocator, .en);
            defer freeKeyList(allocator, en);

            if (ko.len != en.len) {
                std.debug.print("\n쿼리 '{s}' 섹션 {d}: 통과 행 수가 언어마다 다르다 (ko {d} / en {d})\n", .{ query, sec, ko.len, en.len });
                return error.TestUnexpectedResult;
            }
            for (ko, en, 0..) |a, b, i| {
                if (!std.mem.eql(u8, a, b)) {
                    std.debug.print("\n쿼리 '{s}' 섹션 {d}: {d}번 행이 다르다 (ko '{s}' / en '{s}')\n", .{ query, sec, i, a, b });
                    return error.TestUnexpectedResult;
                }
            }
            compared += 1;
        }
    }
    // 아무것도 안 비교했으면 위 루프가 무의미하다 — 그 상태도 "전부 같다" 로 통과한다.
    try std.testing.expect(compared > 0);
}

/// `lang` 으로 펼친 현재 섹션·현재 쿼리의 행 키 나열(테스트 헬퍼). 호출자가 해제한다.
fn settingsRowKeys(self: *AppSession, allocator: std.mem.Allocator, lang: maru.i18n.Lang) ![][]const u8 {
    maru.i18n.setLang(lang);
    var scratch = std.heap.ArenaAllocator.init(allocator);
    defer scratch.deinit();
    const cf = try currentSectionFields(self, scratch.allocator());
    var out: std.ArrayList([]const u8) = .empty;
    errdefer freeKeyList(allocator, out.items);
    var probe: [128]u8 = undefined;
    for (0..cf.total()) |i| {
        const key = keyAtRow(cf, i, &probe) orelse return error.TestUnexpectedResult;
        try out.append(allocator, try allocator.dupe(u8, key));
    }
    return out.toOwnedSlice(allocator);
}

fn freeKeyList(allocator: std.mem.Allocator, keys: [][]const u8) void {
    for (keys) |k| allocator.free(k);
    allocator.free(keys);
}

// `reapplyLoadedConfig` 는 **config 미러를 되쓰지 않는다** — 성질로 못 박는다.
//
// 예전에 `reapplyUiLanguage` 가 행 목록을 만들면서 `currentSectionFields` 를 불렀고, 그 함수의 첫 문장이
// `keep_alive_after_quit` 를 앱 전역으로 되동기화했다. keep-alive 토글은 ①config 에 새 값 ②재적용 ③전역
// 세우기 순서라 ②가 ①을 **옛 전역으로 되돌렸다** — 껐는데 켜진 채로 남는, 화면만 보면 성공처럼 보이는
// 손실이다. 지금은 재적용 경로에서 `currentSectionFields` 로 가는 길이 없어 그 위험이 **구조적으로** 없다.
//
// 그 사실을 시나리오가 아니라 성질로 잰다. 시나리오로 재던 앞선 판은 조기 반환이 먼저 막아 주는 바람에
// **아무것도 안 지키면서 초록**이었다(적대적 검증이 그것을 뮤테이션으로 보였다). 여기서는 미러와 전역을
// 일부러 어긋나게 해 두고 재적용이 그 어긋남을 **건드리지 않는지** 본다 — 되쓰는 길이 다시 생기면 실패한다.
test "재적용은 config 미러를 되쓰지 않는다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    const keep_before = app_session_mod.app_keep_alive_after_quit;
    defer app_session_mod.app_keep_alive_after_quit = keep_before;

    // 전역과 미러를 **일부러 어긋나게** 둔다 — 되쓰는 길이 있으면 재적용이 미러를 전역 값으로 덮는다.
    app_session_mod.app_keep_alive_after_quit = true;
    session.loaded_config.config.session.keep_alive_after_quit = false;
    session.chrome_host.settings.show(); // 폼이 열려 있어야 그 길이 열릴 여지가 생긴다

    reapplyLoadedConfig(session);

    try std.testing.expect(!session.loaded_config.config.session.keep_alive_after_quit);
}

// 앵커 행이 **사라졌을 때** 폴백이 그 키의 섹션까지 옮기는가.
//
// `sectionIndexOfSettingsKey` 는 스키마가 아니라 **행 빌더**로 섹션을 찾는다 — 스키마만 보면
// `theme.preset`·`shell.args`·`env.*`·`macro.*` 처럼 **행은 있는데 스키마 필드가 아닌** 것을 못 찾아
// 섹션 이동이 통째로 무동작이 된다. 그 함수를 `null` 만 돌려주게 만들어도 다른 테스트는 전부 통과했다
// (그것을 부르던 유일한 테스트가 FAIL 이 아니라 **SKIP** 으로 새어 나갔다) — 그 구멍을 여기서 막는다.
test "앵커 행이 사라지면 그 키가 살던 섹션으로 옮겨 다시 찾는다" {
    if (@import("builtin").os.tag != .macos) return error.SkipZigTest;
    const allocator = std.testing.allocator;
    const session = try allocator.create(AppSession);
    defer allocator.destroy(session);
    try session.init(std.Io.Threaded.global_single_threaded.io(), allocator, .{
        .abi_version = app_session_mod.abi_version,
        .cols = 40,
        .rows = 10,
        .queue_capacity = 16,
        .command_kind = @intFromEnum(app_session_mod.CommandKind.controlled_smoke),
    });
    defer session.deinit();

    session.chrome_host.settings.show();

    // 합성 행(스키마 필드가 아님)의 섹션을 찾는다 — 스키마만 보는 구현은 여기서 `null` 을 낸다.
    const home = sectionIndexOfSettingsKey(session, "env.") orelse return error.TestUnexpectedResult;

    // 그 행이 사는 곳이 **아닌** 섹션에 서서, 교차 검색으로 그 행을 고른 상태를 만든다.
    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const sections = try buildSectionList(session, arena_state.allocator());
    var elsewhere: ?usize = null;
    for (0..sections.len) |i| if (i != home) {
        elsewhere = i;
        break;
    };
    session.chrome_host.settings.section = elsewhere orelse return error.TestUnexpectedResult;
    session.chrome_host.settings.startSearch();
    for ("env") |c| session.chrome_host.settings.appendSearchCp(c);
    session.chrome_host.settings.selected =
        indexOfSettingsKey(session, "env.") orelse return error.TestUnexpectedResult;

    // 쿼리를 그 행이 안 걸리는 것으로 바꿔 **행이 사라진** 상태를 만든다(파일이 그 행을 지운 것과 같다).
    session.chrome_host.settings.startSearch();
    for ("zzqqxx") |c| session.chrome_host.settings.appendSearchCp(c);
    reanchorSelectedByKey(session, "env.");

    // 쿼리가 풀리고 **섹션도 그 키가 살던 곳으로** 옮겨져 그 행이 다시 목록에 있다.
    try std.testing.expectEqual(@as(usize, 0), session.chrome_host.settings.searchQuery().len);
    try std.testing.expectEqual(home, session.chrome_host.settings.section);
    const found = indexOfSettingsKey(session, "env.") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(found, session.chrome_host.settings.selected);
}
