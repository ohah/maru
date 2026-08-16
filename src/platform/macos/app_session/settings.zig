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
const git_ops = @import("git.zig");
const agent_ops = @import("agent.zig");
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
const font_direct_input_label = AppSession.font_direct_input_label;
const font_size_min = app_session_mod.font_size_min;
const setAppKeepAlivePolicy = app_session_mod.setAppKeepAlivePolicy;
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
                    .group_header => {},
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
                .agent_toggle, .agent => {},
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
        self.find_matches.clearRetainingCapacity();
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

/// 세팅 검색 매칭 — 쿼리가 비었으면 항상 true, 아니면 라벨(보이는 텍스트) 또는 키에 부분일치(ASCII 대소문자 무시;
/// 한글은 대소문자가 없어 그대로 부분일치). 필터의 단일 출처 — currentSectionFields가 모든 행 종류에 같은 규칙 적용.
pub fn settingsRowMatches(label: []const u8, key: []const u8, query: []const u8) bool {
    if (query.len == 0) return true;
    return std.ascii.indexOfIgnoreCase(label, query) != null or std.ascii.indexOfIgnoreCase(key, query) != null;
}

/// 섹션 표시 라벨(config_mod.Section → 한국어). null=스키마 섹션 미지정 그룹("기타").
pub fn settingsSectionLabel(sec: ?config_mod.Section) []const u8 {
    const s = sec orelse return "기타";
    return switch (s) {
        .font => "폰트",
        .theme => "테마",
        .cursor => "커서",
        .window => "창",
        .input => "입력",
        .terminal => "터미널",
        .workspace => "워크스페이스",
        .quick_terminal => "퀵 터미널",
        .sidebar => "사이드바",
        .global_hotkey => "글로벌 핫키",
        .editor => "편집기",
    };
}

/// UI에 새로 노출해도 되는 config 키인가. `chrome.theme=tui`와 `chrome.preset=cell`은 이미 저장된
/// config를 읽는 호환 경로만 남기며, GUI·검색에서 다시 선택·변경할 수 있게 만들지 않는다.
/// 이 예외를 field 생성과 section 생성이 함께 써야 검색/직접 섹션 전환 중 되살아나는 우회가 없다.
/// 단일 출처: docs/chrome-strategy.md "Chrome 전용 전환 정책".
pub fn settingsExposesConfigKey(key: []const u8) bool {
    return !std.mem.eql(u8, key, "chrome.theme") and
        !std.mem.eql(u8, key, "chrome.preset");
}

pub fn settingsSectionHasField(bools: []const config_mod.schema.BoolField, nums: []const config_mod.schema.NumberField, enums: []const config_mod.schema.EnumField, texts: []const config_mod.schema.TextField, colors: []const config_mod.schema.ColorField, sec: ?config_mod.Section) bool {
    // `.global_hotkey`는 schema 필드가 없는 특수 섹션이라 강제로 목록에 넣는다(전역 단축키 녹음 행만 — theme의
    // palette·input의 keybind 특수 행 패턴처럼 currentSectionFields가 행을 합성한다). 좌측 네비에 항상 보여야 한다.
    if (sec == .global_hotkey) return true;
    for (bools) |b| if (settingsExposesConfigKey(b.key) and b.section == sec) return true;
    for (nums) |n| if (settingsExposesConfigKey(n.key) and n.section == sec) return true;
    for (enums) |e| if (settingsExposesConfigKey(e.key) and e.section == sec) return true;
    for (texts) |t| if (settingsExposesConfigKey(t.key) and t.section == sec) return true;
    for (colors) |c| if (settingsExposesConfigKey(c.key) and c.section == sec) return true;
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
        rows[i] = .{ .label = try settingsRowLabel(arena, cross, e.section, if (e.doc.len > 0) e.doc else e.key), .kind = .{ .dropdown = e.current }, .is_default = is_def };
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
        rows[i] = .{ .label = try settingsRowLabel(arena, cross, .theme, "ANSI 팔레트"), .kind = .{ .palette_grid = .{ .cells = cells, .selected = sel } }, .disabled = preset_active, .is_default = pal_is_def };
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
            rows[i] = .{ .label = try settingsRowLabel(arena, cross, .global_hotkey, entry.title), .kind = .{ .keybind = try arena.dupe(u8, display) }, .is_default = chord == null };
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
    labels[sections.len] = try std.fmt.allocPrint(arena, "{s} 초기화", .{chrome.components.settings.reset_glyph});
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
        return (try config_mod.schema.enumVariants(arena, self.loaded_config.config, e.key)) orelse &.{};
    }
    if (sel >= after_enums and sel < after_texts) {
        const ti = sel - after_enums;
        if (ti < cf.texts.len and std.mem.eql(u8, cf.texts[ti].key, "font.family")) {
            // 번들 폰트 + "직접 입력…"(마지막 슬롯 — 목록 밖 임의 설치 폰트를 인라인 편집으로 넣는다).
            const fonts = config_mod.theme.bundled_font_families;
            const out = try arena.alloc([]const u8, fonts.len + 1);
            for (fonts, 0..) |fam, i| out[i] = fam;
            out[fonts.len] = font_direct_input_label;
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
            if (std.mem.eql(u8, f.key, "session.keep-alive-after-quit")) {
                setAppKeepAlivePolicy(new_value);
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
    agent_ops.reconcileAgentStatusline(self); // 토글을 껐으면 여기서 복원·제거까지 간다
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
    self.page_keys_scroll = self.loaded_config.config.input.page_keys == .scroll;
    self.shift_enter_meta = self.loaded_config.config.input.shift_enter == .newline;
    self.ime_enter_newline = self.loaded_config.config.input.ime_enter == .newline;
    self.option_as_meta = self.loaded_config.config.input.option_as_meta;
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
                (if (mk.pinned) "그룹 고정 해제" else "그룹째 고정")
            else
                (if (t.workspace.pinned) "고정 해제" else "위치 고정"),
            .local => if (t.workspace.local_pinned) "그룹 내 고정 해제" else "그룹 내 위치 고정",
            .individual => if (t.workspace.pinned) "고정 해제" else "위치 고정",
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
        self.context_menu_items_buf[n] = "새 그룹으로 묶기"; // ctx_menu_group_create
        n += 1;
        self.context_menu_items_buf[n] = "형제 그룹으로 분리"; // ctx_menu_group_sibling
        n += 1;
        self.context_menu_items_buf[n] = "그룹 풀기"; // ctx_menu_group_ungroup
        n += 1;
        for (tab_group_color_labels) |lbl| { // 그룹 공통 색(SG5-2) — ctx_menu_group_color_first부터. 소속 그룹 마커에 색 세팅
            self.context_menu_items_buf[n] = lbl;
            n += 1;
        }
        // "그룹에서 빼기"(remove_from_group) — **그룹 소속 카드에만** 맨 끝에 붙인다(최상위 카드엔 안 뜸 — tabIsInGroup).
        // ungroup(그룹 통째 해제)과 달리 이 카드 하나만 최상위로 뺀다. 맨 끝 조건부라 앞 고정 인덱스를 안 흔든다(sel==ctx_menu_group_remove).
        if (tab_ops.tabIsInGroup(self, t.workspace)) {
            self.context_menu_items_buf[n] = "그룹에서 빼기"; // ctx_menu_group_remove
            n += 1;
            // "여기서 최상위로 분리"(promote-in-place, §14.5·§14.7) — remove 바로 뒤. removeFromGroup(그룹 밖 이동+unpin)과
            // 달리 **제자리** top_level만 세팅(위치·pin 불변 — 고정 top카드 가능). **마커 카드(group_start!=null)에선 숨긴다**
            // (§14.8 SR5 결정 (a)): promoteTabToTopLevelInPlace가 leaf-only(§13.8)상 마커에 no-op이라, 뜨면 "눌러도 무동작"인
            // 죽은 항목이 된다(remove는 마커에서도 nested subgroup 빼기로 유효해 유지). 조건부라 마커면 promote 슬롯이 비어
            // 메뉴가 한 칸 짧아지고(ctx_menu_group_remove까지), sel이 ctx_menu_group_promote에 절대 도달 못 해 인덱스가 안 흔들린다.
            if (t.workspace.group_start == null) {
                self.context_menu_items_buf[n] = "여기서 최상위로 분리"; // ctx_menu_group_promote
                n += 1;
            }
        }
    };
    // 그룹 헤더 우클릭(SG5-2-header) — 대상은 group_start 마커 탭(renameTargetAt). 헤더 스코프 액션만: Rename(0)=그룹
    // 이름 편집은 위에서 이미 넣었고, 여기서 "그룹 풀기"(ungroup)와 "그룹 색: …" 프리셋을 붙인다. 색 라벨/팔레트/세팅은
    // 카드 메뉴와 같은 인프라(tab_group_color_labels·tab_color_presets·setGroupColorForTab)를 재사용해 같은 색 메뉴를 공유한다.
    if (self.context_menu_target) |t| if (std.meta.activeTag(t) == .group) {
        // 그룹 고정/해제(toggleGroupPin — GP3 §12.10). 마커 pinned = 그룹 고정 권위(§12.2)라 헤더에서 그룹째 토글한다.
        self.context_menu_items_buf[n] = if (t.group.pinned) "그룹 고정 해제" else "그룹 고정"; // ctx_group_menu_pin
        n += 1;
        self.context_menu_items_buf[n] = "그룹 풀기"; // ctx_group_menu_ungroup
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
    self.context_menu_items_buf[0] = if (sb.show_branch) "\u{2713} 브랜치 표시" else "  브랜치 표시";
    self.context_menu_items_buf[1] = if (sb.show_folder) "\u{2713} 폴더 표시" else "  폴더 표시";
    self.context_menu_items_len = 2;
    return self.context_menu_items_buf[0..2];
}

/// 터미널 본문 우클릭 메뉴 항목(input.right-click=menu) — 복사/붙여넣기. rename·view_options와 같은
/// context_menu_items_buf·itemAt/draws/accept 경로를 공유하고 분기는 terminal_context_menu 플래그로 한다(F2-5).
pub fn buildTerminalContextMenuItems(self: *AppSession) []const []const u8 {
    self.context_menu_items_buf[0] = "복사";
    self.context_menu_items_buf[1] = "붙여넣기";
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
    if (self.branch_menu_open) closeContextMenu(self);
    if (self.branch_menu_text.len > 0) self.allocator.free(self.branch_menu_text);
    self.branch_menu_text = &.{};
    self.branch_menu_len = 0;
}

/// 상태바 브랜치 항목에서 브랜치 목록을 **요청**한다. 결과는 다음 tick에 `drainGitStatus`가 걷어 메뉴를 연다.
/// git 실행은 백엔드 스레드라 클릭이 UI를 멈추지 않는다.
pub fn requestBranchMenu(self: *AppSession) void {
    if (self.branch_menu_pending) return; // 연타로 프로세스가 쌓이지 않게
    // 백엔드는 **지연 생성**이다(소스 컨트롤을 연 적 없으면 없다). 없으면 조용히 무시되던 것을 여기서 만든다 —
    // `refreshGitStatus`와 같은 규율. 안 그러면 도크를 한 번도 안 연 사용자에겐 브랜치 클릭이 아무 일도 안 한다.
    if (self.git_backend == null) {
        self.git_backend = git_backend_mod.Backend.init(self.io) catch {
            self.showNotice("git 백엔드를 시작하지 못했습니다");
            return;
        };
    }
    var backend = &(self.git_backend orelse return);
    var exe_buf: [1024]u8 = undefined;
    const git_exe = git_backend_mod.locate(&exe_buf) orelse {
        self.showNotice("git을 찾지 못했습니다");
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
            self.showNotice(git_ops.notice_not_a_repo);
            return;
        },
        .unknown => {
            self.showNotice(git_ops.notice_repo_unknown);
            return;
        },
    };
    self.git_request_seq +%= 1;
    if (backend.submitBranches(git_exe, repo, self.git_request_seq)) self.branch_menu_pending = true;
}

/// 걷은 목록으로 메뉴를 연다. 앵커는 **상태바 브랜치 항목 위**다 — 메뉴는 위로 펼쳐야 바에 가리지 않는다.
pub fn openBranchMenu(self: *AppSession) void {
    if (self.branch_menu_len == 0) {
        self.showNotice("브랜치가 없습니다");
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
        self.showNotice("브랜치 이름을 명령으로 만들 수 없습니다");
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
    self.branch_menu_open = false; // 목록 텍스트는 다음 요청까지 살려 둔다(재열기 비용 절약)
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
                        self.showNotice("링크를 열지 못했습니다.");
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
            self.showNotice("탐색기 루트가 바뀌어 명령을 취소했습니다.");
            return;
        }
        const current_index = file_tree.findIdentity(self.file_tree_rows.items, .{ .kind = target.row_kind, .path = target.path() }) orelse {
            self.showNotice("선택한 항목이 변경되어 명령을 취소했습니다.");
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
    setAppKeepAlivePolicy(self.loaded_config.config.session.keep_alive_after_quit);
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
    self.page_keys_scroll = self.loaded_config.config.input.page_keys == .scroll;
    self.shift_enter_meta = self.loaded_config.config.input.shift_enter == .newline;
    self.ime_enter_newline = self.loaded_config.config.input.ime_enter == .newline;
    self.option_as_meta = self.loaded_config.config.input.option_as_meta;
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
    const keep_alive = self.loaded_config.config.session.keep_alive_after_quit;
    self.loaded_config.config = config_mod.Config{}; // 내장 기본값(정적 — 옛 arena 문자열은 미참조로 남았다 다음 reload/deinit에 해제)
    self.loaded_config.config.session.keep_alive_after_quit = keep_alive; // 보존 — 아래 파일 write도 같은 값을 남긴다
    // 리터럴 false가 아니라 `Config{}` 기본값을 기준으로 "보존이 실제 override인지" 판정한다. 문서가 기능 완성
    // 뒤 기본값을 true로 전환한다고 예고했으므로(persistent-session-host.md), 그때 리터럴 비교로 두면 사용자가
    // 명시적으로 끈 false를 리셋이 도로 켜 버려 같은 사고가 반대 방향으로 난다.
    const default_keep_alive = (config_mod.Config{}).session.keep_alive_after_quit;
    const keep_alive_preserved = keep_alive != default_keep_alive;
    setAppKeepAlivePolicy(keep_alive); // 보존값 그대로 — 리셋이 live 소유권 정책을 뒤집지 않는다.
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
        self.showNotice("기본값으로 초기화(화면은 적용됨) — config 파일 쓰기에 실패했습니다")
    else if (keep_alive_preserved)
        // 보존을 조용히 처리하면 사용자는 "모든 설정 초기화"라는 말대로 세션 유지도 꺼졌다고 믿고, 나중에
        // 예상과 다른 Quit 동작을 만난다. 보존 사실과 **수동 변경 경로**를 같이 알려야 결정권이 사용자에게 남는다.
        self.showNotice("모든 설정을 기본값으로 초기화했습니다 — 세션 유지(keep-alive)는 살아 있는 터미널을 지키려 그대로 뒀습니다. 끄려면 세팅 › workspace에서 직접 변경하세요")
    else
        self.showNotice("모든 설정을 기본값으로 초기화했습니다");
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
    out[fields.len] = "사용자 지정";
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
                self.runtime.enqueueCoreCommand(term.surface.id, .{ .set_config_palette = palette }, self.io) catch {};
                // OSC 10/11 query의 default fg/bg도 renderer theme와 같은 값을 보게 한다. buildFrame의 direct
                // setDefaultColors는 local render 안전망이고 remote placeholder에는 host 효과가 없으므로 이 경계가 필요하다.
                self.runtime.enqueueCoreCommand(term.surface.id, .{ .set_default_colors = default_colors }, self.io) catch {};
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
                self.runtime.enqueueCoreCommand(term.surface.id, .{ .set_max_scrollback = lines }, self.io) catch {};
            }
        }
    }
}

/// text.ambiguous-width reload를 라이브 코어에 재적용한다(createTerm chokepoint와 같은 값을 이미 떠 있는
/// surface에도). reader 단일 mutator 계약상 set_max_scrollback과 같이 CoreCommand로 위임한다. 이후 putCell부터
/// 새 폭이 반영된다(이미 저장된 셀은 옛 폭 유지 — 폭 변경은 본래 redraw 필요; max_scrollback과 같은 best-effort).
pub fn reapplyAmbiguousWidth(self: *AppSession) void {
    const wide = self.loaded_config.config.ambiguous_width == .wide;
    for (self.tabs.items) |tab| {
        for (tab.panes.items) |pane| {
            for (pane.terms.items) |term| {
                self.runtime.enqueueCoreCommand(term.surface.id, .{ .set_ambiguous_wide = wide }, self.io) catch {};
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
                self.runtime.enqueueCoreCommand(term.surface.id, .{ .set_emoji_wide = wide }, self.io) catch {};
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
                self.runtime.enqueueCoreCommand(term.surface.id, .{ .set_default_cursor_shape = shape }, self.io) catch {};
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

/// 현재 선택 섹션(settings.section)으로 필터한 필드(bool→num→enum→text). arena 소유. 핸들러가 selected를 이 순서로 매핑.
pub fn currentSectionFields(self: *AppSession, arena: std.mem.Allocator) !SettingsSectionFields {
    // 다른 Window에서 바꾼 앱 전역 policy를 이 창의 설정 스냅샷에도 반영한다. 이 동기화 뒤 field 생성과
    // toggle의 `new_value` 계산이 같은 SSOT를 보므로 stale 창이 값을 되돌리지 않는다.
    self.loaded_config.config.session.keep_alive_after_quit = app_session_mod.app_keep_alive_after_quit;
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
    // 검색 쿼리(폼 필터 — 라벨/키 부분일치). 모든 행 종류에 같은 settingsRowMatches 규칙을 적용해 view·핸들러 인덱싱이
    // 일관되게 한다(필터는 여기 단일 출처). 빈 쿼리면 전부 통과. **쿼리가 있으면(cross) 섹션 게이트를 무시**해 전 섹션의
    // 매칭 행을 보여준다(교차 섹션 검색 — 설정이 어느 섹션인지 몰라도 찾는다). 빈 쿼리면 현재 섹션만.
    const q = self.chrome_host.settings.searchQuery();
    const cross = q.len > 0;
    var bools: std.ArrayList(config_mod.schema.BoolField) = .empty;
    for (bools_all.items) |b| if (settingsExposesConfigKey(b.key) and (cross or b.section == sel_sec) and settingsRowMatches(b.doc, b.key, q)) try bools.append(arena, b);
    var nums: std.ArrayList(config_mod.schema.NumberField) = .empty;
    for (nums_all.items) |n| if (settingsExposesConfigKey(n.key) and (cross or n.section == sel_sec) and settingsRowMatches(n.doc, n.key, q)) try nums.append(arena, n);
    var enums: std.ArrayList(config_mod.schema.EnumField) = .empty;
    for (enums_all.items) |e| if (settingsExposesConfigKey(e.key) and (cross or e.section == sel_sec) and settingsRowMatches(e.doc, e.key, q)) try enums.append(arena, e);
    // theme 섹션엔 named 테마 프리셋(특수 — schema 필드 아님)을 synthetic enum 행으로 주입한다(dropdown 재사용).
    // 현재값은 config 색에서 derive(매칭 프리셋 @tagName 또는 "사용자 지정"). 핸들러가 key="theme.preset"만 특수 처리.
    // follow-system이 켜지면 색을 preset-light/dark가 정하므로 단일 theme.preset 행은 무의미(골라도 곧 덮임) — 숨긴다(리뷰 C).
    if ((cross or sel_sec == .theme) and !self.loaded_config.config.theme_follow_system and settingsRowMatches("테마 프리셋", "theme.preset", q)) {
        // 프리셋 행을 enum 구간 **맨 앞**에 둬 테마 섹션 최상단(색·팔레트보다 먼저)에 도드라지게 한다. 표시값은
        // 활성(themePresetActive)이면 그 프리셋명, 아니면 "사용자 지정"(detect=null이거나 사용자가 명시로 푼 경우).
        const cur_name: []const u8 = if (self.themePresetActive()) @tagName(detectThemePreset(self.loaded_config.config.theme).?) else "사용자 지정";
        try enums.insert(arena, 0, .{ .key = "theme.preset", .doc = "테마 프리셋", .current = cur_name, .section = .theme });
    }
    var texts: std.ArrayList(config_mod.schema.TextField) = .empty;
    for (texts_all.items) |t| if (settingsExposesConfigKey(t.key) and (cross or t.section == sel_sec) and settingsRowMatches(t.doc, t.key, q)) try texts.append(arena, t);
    // terminal 섹션엔 특수 키(schema 필드 아님)를 synthetic text 행으로 주입한다(theme.preset enum 선례 — .text 위젯
    // 재사용, 핸들러가 key로 라우팅). shell.args(공백-토큰 리스트) + env.<KEY> 각 행(값 편집) + env 추가 행(KEY=VALUE).
    if (cross or sel_sec == .terminal) {
        if (settingsRowMatches("셸 인자 (공백 구분)", "shell.args", q))
            try texts.append(arena, .{ .key = "shell.args", .doc = "셸 인자 (공백 구분)", .value = try std.mem.join(arena, " ", self.loaded_config.config.shell.args), .section = .terminal });
        for (self.loaded_config.config.env) |entry| {
            const eq = std.mem.indexOfScalar(u8, entry, '=') orelse continue; // 형식 오류(= 없음)는 건너뜀
            if (settingsRowMatches(entry[0..eq], "env", q))
                try texts.append(arena, .{ .key = try std.fmt.allocPrint(arena, "env.{s}", .{entry[0..eq]}), .doc = entry[0..eq], .value = entry[eq + 1 ..], .section = .terminal });
        }
        if (settingsRowMatches("환경 변수 추가 (KEY=VALUE)", "env", q))
            try texts.append(arena, .{ .key = "env.", .doc = "환경 변수 추가 (KEY=VALUE)", .value = "", .section = .terminal }); // 추가 행(빈 KEY = sentinel)
    }
    // 입력 섹션엔 사용자 터미널 매크로(keybind = chord = text:/esc:/ctrl:)를 rhs 편집 text 행으로 노출한다(env 특수 행
    // 선례). 라벨=chord 표시(formatChord), 값=rhs config 문자열(macroRhsString, 예 "text:hello"). 키="macro.<chord
    // config>"로 커밋/삭제 시 chord를 식별한다(toConfigString). 마지막에 "추가" 행(빈 sentinel "macro.").
    if (cross or sel_sec == .input) {
        for (self.loaded_config.terminal_bindings) |b| {
            var disp_buf: [command_catalog.max_chord_display_len]u8 = undefined;
            const disp = command_catalog.formatChord(b.chord, &disp_buf);
            if (settingsRowMatches(disp, "macro", q)) {
                var chord_buf: [64]u8 = undefined; // 매치된 행만 chord config 표기 계산(필터된 행 낭비 제거)
                const chord_cfg = b.chord.toConfigString(&chord_buf);
                try texts.append(arena, .{ .key = try std.fmt.allocPrint(arena, "macro.{s}", .{chord_cfg}), .doc = try arena.dupe(u8, disp), .value = try macroRhsString(arena, b.input), .section = .input });
            }
        }
        if (settingsRowMatches("터미널 매크로 추가 (chord = text:...)", "macro", q))
            try texts.append(arena, .{ .key = "macro.", .doc = "터미널 매크로 추가 (chord = text:...)", .value = "", .section = .input }); // 추가 행(빈 chord = sentinel)
    }
    // Workspace 섹션엔 시작 디렉터리(workspace.root)를 합성 text 행으로 노출한다(schema 필드 아님 — loader 명시
    // 핸들러 특수 키, shell.args 선례). 값=현재 root(빈 값=상속 cwd). 커밋은 setWorkspaceRoot(loader와 형식 검증 공유).
    if (cross or sel_sec == .workspace) {
        if (settingsRowMatches("시작 디렉터리 (절대경로 또는 ~, 빈 값=상속)", "workspace.root", q))
            try texts.append(arena, .{ .key = "workspace.root", .doc = "시작 디렉터리 (절대경로 또는 ~, 빈 값=상속)", .value = self.loaded_config.config.workspace.root, .section = .workspace });
    }
    var colors: std.ArrayList(config_mod.schema.ColorField) = .empty;
    for (colors_all.items) |c| if (settingsExposesConfigKey(c.key) and (cross or c.section == sel_sec) and settingsRowMatches(c.doc, c.key, q)) try colors.append(arena, c);
    // theme 섹션엔 ANSI 16색 팔레트 그리드 한 행, input 섹션엔 command_catalog 액션별 keybind 행(둘 다 특수 — schema
    // 필드 아님). 검색 쿼리로도 필터한다(palette=한 행, keybind=매칭 액션만). 핸들러가 selected 인덱스로 라우팅.
    // 교차 검색에선 palette(theme)·keybind(input)가 함께 나올 수 있어 keybindRowStart가 palette 오프셋을 더한다.
    var keybinds: std.ArrayList(command_catalog.Entry) = .empty;
    if (cross or sel_sec == .input) {
        for (command_catalog.entries) |entry| if (settingsRowMatches(entry.title, entry.key, q)) try keybinds.append(arena, entry);
    }
    const palette_on = (cross or sel_sec == .theme) and settingsRowMatches("ANSI 팔레트", "theme.palette", q);
    // `.global_hotkey` 섹션엔 전역(OS) 단축키 녹음 행(GlobalEntry별 한 행 — schema 필드 아님, keybind 특수 행 선례).
    // 검색 쿼리로도 필터(매칭 액션만). 핸들러가 selected>=globalKeybindRowStart면 global_entries로 라우팅.
    var globals: std.ArrayList(command_catalog.GlobalEntry) = .empty;
    if (cross or sel_sec == .global_hotkey) {
        for (command_catalog.global_entries) |entry| if (settingsRowMatches(entry.title, entry.key, q)) try globals.append(arena, entry);
    }
    return .{ .bools = bools.items, .nums = nums.items, .enums = enums.items, .texts = texts.items, .colors = colors.items, .has_palette = palette_on, .keybind_entries = keybinds.items, .global_entries = globals.items };
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
                        self.chrome_host.settings.setMessage("셸 실행 파일을 찾을 수 없어 기본 셸로 실행됩니다 (실행 파일 절대경로 필요 · 시작 위치는 이 필드가 아님)");
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
