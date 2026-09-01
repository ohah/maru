//! UI 표시 문자열의 언어별 테이블과 조회 — 어느 facade에도 속하지 않는 **중립 leaf**다
//! (`redact.zig`·`width.zig`와 같은 결). chrome(L3)·session(L2)·config·platform이 전부 import한다.
//!
//! 단일 출처는 [docs/i18n.md](../docs/i18n.md)이고 이 파일은 그 계약의 코드 반영이다. 왜 이 모양인지의
//! 근거는 그 문서에 있으며, 여기 주석은 "코드가 그 결정을 어떻게 지키는가"만 적는다.
//!
//! **왜 중립 leaf인가**(계약 §1.2·§4): 사용자가 읽고 판단하는 한국어 문장의 실제 소유자가
//! `platform/macos/app_session/`이었다. platform에 문자열이 갇혀 있으면 Windows host가 오는 순간 같은
//! 문장을 다시 써야 한다. `app_session`은 macOS 앱 로직이라 통째로 옮길 수 없으므로, **문자열만** 여기로
//! 빼는 것이 번역과 이식성을 동시에 푸는 유일한 길이다.
//!
//! **왜 comptime struct인가**(계약 §3.1): `Table`에 기본값을 주지 않으므로 언어 테이블이 키 하나를
//! 빠뜨리면 `error: missing struct field`로 **컴파일이 멈춘다**. 번역 누락이 런타임까지 살아남지 않는다.
//! 값이 전부 컴파일타임 리터럴이라 언어 전환에 heap이 없고, `command_catalog.Entry`의 "컴파일타임
//! 리터럴을 ABI가 그대로 가리킨다"는 계약도 언어를 바꿔도 유지된다.

const std = @import("std");
const width = @import("width.zig"); // UTF-8 경계 절단(truncateToBoundary) 단일 출처 — 보간 버퍼 부족 처리에 쓴다

/// 지원 언어. 계약 §2가 영어·한국어로 범위를 정했고, 중국어·일본어는 이 enum과 `Table`만 늘리면 확장된다
/// (CJK는 한글과 같은 EAW Wide라 배치 규칙이 그대로 성립한다 — 계약 §6.5).
///
/// 태그 타입을 명시하는 이유는 하나다 — 현재 언어가 `std.atomic.Value` 에 들어가고(아래 `current`),
/// 그 안의 extern struct 는 크기가 정해진 타입만 담는다.
pub const Lang = enum(u8) { en, ko };

/// 표시 문자열의 키 = 이 struct의 필드.
///
/// **기본값을 주지 않는 것이 이 설계의 핵심이다.** 아래 `en`/`ko` 중 하나라도 필드를 빠뜨리면 그 자리에서
/// 컴파일이 멈춘다(`error: missing struct field: <키>`). 키 목록을 손으로 두 벌 유지하지 않도록 `Key`는
/// 이 struct에서 파생한다.
///
/// **이름 규칙**: `<영역>_<의미>`. 영역 접두로 그 키가 어디 것인지 코드에서 읽힌다.
///   - `fp_root_*` — 파일 탐색기 루트 변경·제거·선택의 결과 안내(`app_session/file_panel.zig`)
///   - `set_*` — 세팅 페이지의 배너/토스트(`app_session/settings.zig`·`input.zig`)
///   - `git_*`·`ws_*`·`ad_*` — git 도크·워크스페이스 이동·에이전트 도크의 notice 토스트
///   - `common_*` — **두 파일 이상이 같은 의미로 쓰는 문장**. 파일 접두를 쓰면 그 키가 한 곳 것처럼
///     읽혀 다른 소비처가 안 보이므로, 공유가 확인되면 이 접두로 옮긴다(같은 문장에 키를 둘 두면
///     이중 출처가 되어 한쪽만 고쳐지는 드리프트가 생긴다).
const Table = struct {
    // ── 파일 탐색기 루트 (I3a 첫 슬라이스) ────────────────────────────────
    // 전부 `reportFileTreeRootOutcome`의 인자로만 쓰인다. 그 함수가 유일한 소비처라
    // 파라미터 타입을 `?Key`로 바꿔 리터럴이 애초에 넘어갈 수 없게 했다(계약 §7.2 1차).
    fp_root_stale_generation: [:0]const u8,
    fp_root_open_failed: [:0]const u8,
    fp_root_identity_unknown: [:0]const u8,
    fp_root_revalidate_alloc_failed: [:0]const u8,
    fp_root_revalidate_start_failed: [:0]const u8,
    fp_root_revalidate_invalid: [:0]const u8,
    fp_root_identity_gone: [:0]const u8,
    fp_root_capability_gone: [:0]const u8,
    fp_root_identity_changed: [:0]const u8,
    fp_root_change_alloc_failed: [:0]const u8,
    fp_root_replace_failed: [:0]const u8,
    fp_root_add_failed: [:0]const u8,
    fp_root_watch_change_failed: [:0]const u8,
    fp_root_rows_change_failed: [:0]const u8,
    fp_root_first_scan_alloc_failed: [:0]const u8,
    fp_root_scan_start_failed: [:0]const u8,
    fp_root_busy_retry: [:0]const u8,
    fp_root_remove_alloc_failed: [:0]const u8,
    fp_root_remove_failed: [:0]const u8,
    fp_root_missing: [:0]const u8,
    fp_root_watch_remove_failed: [:0]const u8,
    fp_root_rows_remove_failed: [:0]const u8,
    fp_root_invalid_path: [:0]const u8,
    fp_root_request_id_exhausted: [:0]const u8,
    fp_root_picker_alloc_failed: [:0]const u8,
    fp_root_validate_busy: [:0]const u8,

    // ── 세팅 페이지 배너/토스트 (I3a 슬라이스 2) ──────────────────────────
    // `settingsMessageOrNotice`(세팅이 열려 있으면 배너, 아니면 토스트)의 인자로만 쓰인다.
    // 그 함수도 단일 sink 라 파라미터를 `Key`로 바꿔 1차 방어를 완성했다.
    set_global_key_not_allowed: [:0]const u8,
    set_global_chord_taken: [:0]const u8,
    set_no_chord_assigned: [:0]const u8,
    set_no_global_chord_assigned: [:0]const u8,
    set_env_format: [:0]const u8,
    set_env_key_empty: [:0]const u8,
    set_chord_parse_failed: [:0]const u8,
    set_macro_format: [:0]const u8,
    set_chord_conflict: [:0]const u8,
    set_macro_overrides_default: [:0]const u8,
    set_macro_line_format: [:0]const u8,
    set_chord_empty: [:0]const u8,
    /// 값이 끼어드는 유일한 항목 — `{0}`에 이미 그 chord 를 쓰는 명령 이름이 들어간다(§6.3 보간).
    set_chord_taken_by: [:0]const u8,

    // ── notice 토스트 (I3a 슬라이스 3) ────────────────────────────────────
    // `showNoticeKey`/`showNoticeFmt`의 인자로만 쓰인다. 파일별 접두로 소유를 읽는다.
    git_branch_list_failed: [:0]const u8,
    git_path_outside_repo: [:0]const u8,
    git_submodule_no_diff: [:0]const u8,
    ws_move_target_has_file: [:0]const u8,
    ws_move_target_tabs_full: [:0]const u8,
    ad_session_list_apply_failed: [:0]const u8,
    ad_workspace_path_missing: [:0]const u8,
    ad_terminal_git_project_missing: [:0]const u8,
    ad_path_scan_start_failed: [:0]const u8,
    ad_path_scan_restart_failed: [:0]const u8,
    ad_session_archive_open_failed: [:0]const u8,
    ad_session_resume_failed: [:0]const u8,
    ad_log_source_changed: [:0]const u8,
    ad_open_session_not_found: [:0]const u8,

    // ── notice 토스트 계속 (I3a 슬라이스 3) — app_session·settings 본체 ──
    app_attach_observer_mode: [:0]const u8,
    common_unsaved_tabs_first: [:0]const u8,
    app_cli_install_path_missing: [:0]const u8,
    app_cli_install_binary_missing: [:0]const u8,
    app_cli_install_no_home: [:0]const u8,
    app_cli_install_symlink_failed: [:0]const u8,
    app_shell_restart_failed: [:0]const u8,
    app_shell_start_failed: [:0]const u8,
    app_file_send_sync_failed: [:0]const u8,
    app_file_send_prepare_failed: [:0]const u8,
    app_file_send_start_failed: [:0]const u8,
    app_file_send_failed: [:0]const u8,
    app_image_send_sync_failed: [:0]const u8,
    app_image_send_too_large: [:0]const u8,
    app_image_send_prepare_failed: [:0]const u8,
    app_image_send_oom: [:0]const u8,
    app_image_send_start_failed: [:0]const u8,
    app_image_send_failed: [:0]const u8,
    app_no_measured_terminal: [:0]const u8,
    set_git_backend_start_failed: [:0]const u8,
    set_git_not_found: [:0]const u8,
    set_no_branches: [:0]const u8,
    set_branch_name_invalid: [:0]const u8,
    set_link_open_failed: [:0]const u8,
    set_root_changed_cancel: [:0]const u8,
    set_selection_changed_cancel: [:0]const u8,
    set_reset_write_failed: [:0]const u8,
    set_reset_done_keepalive: [:0]const u8,
    set_keepalive_reset_preserved: [:0]const u8,
    set_reset_done: [:0]const u8,

    // ── 파일 패널 notice (I3a 슬라이스 3) ──
    fp_view_rebuild_failed: [:0]const u8,
    fp_mutation_in_progress: [:0]const u8,
    fp_select_first: [:0]const u8,
    fp_root_rename_denied: [:0]const u8,
    fp_symlink_dir_create_denied: [:0]const u8,
    fp_path_too_long: [:0]const u8,
    fp_dir_changed_reopen: [:0]const u8,
    fp_trash_in_progress: [:0]const u8,
    fp_trash_queue_full: [:0]const u8,
    fp_select_to_delete: [:0]const u8,
    fp_root_delete_denied: [:0]const u8,
    fp_symlink_alias_delete_blocked: [:0]const u8,
    fp_tab_state_changed_close_cancel: [:0]const u8,
    fp_file_tab_only: [:0]const u8,
    fp_outside_root_denied: [:0]const u8,
    fp_symlink_alias_rename_blocked: [:0]const u8,
    fp_identity_not_ready: [:0]const u8,
    fp_mutation_queue_full: [:0]const u8,
    fp_mutation_id_exhausted: [:0]const u8,
    fp_mutation_prepare_failed: [:0]const u8,
    fp_rename_plan_failed: [:0]const u8,
    fp_entry_busy: [:0]const u8,
    fp_editor_lock_rename_failed: [:0]const u8,
    fp_trash_verify_failed: [:0]const u8,
    fp_root_changed_delete_cancel: [:0]const u8,
    fp_state_changed_dir_delete_cancel: [:0]const u8,
    fp_state_changed_delete_cancel: [:0]const u8,
    fp_delete_recovery_prepare_failed: [:0]const u8,
    fp_editor_lock_trash_failed: [:0]const u8,
    fp_edit_state_changed_rename_cancel: [:0]const u8,
    fp_edit_state_changed_trash_cancel: [:0]const u8,
    fp_trash_adapter_queue_full: [:0]const u8,
    fp_trash_failed_restored: [:0]const u8,
    fp_close_after_mutation: [:0]const u8,
    fp_close_id_exhausted: [:0]const u8,
    fp_close_prepare_failed: [:0]const u8,
    fp_nothing_to_focus: [:0]const u8,
    fp_trash_done_tab_kept: [:0]const u8,
    fp_edit_state_recheck_failed: [:0]const u8,
    fp_save_failed_tab_kept: [:0]const u8,
    fp_post_save_check_failed: [:0]const u8,
    fp_web_content_restarted: [:0]const u8,
    fp_web_content_terminated: [:0]const u8,
    fp_edit_state_check_failed: [:0]const u8,

    // ── 터미널 클립보드 (I3a 슬라이스 3) — 값이 끼므로 `showNoticeFmt` 가 받는다 ──
    term_clipboard_too_large: [:0]const u8,
    term_remote_clipboard_too_large: [:0]const u8,

    // ── 분기·보간형 notice (I3a 슬라이스 4) ──
    app_host_connect_failed: [:0]const u8,
    app_session_host_upgrade_result: [:0]const u8,
    app_agent_hook_trust_stale: [:0]const u8,
    app_agent_hook_trust_refreshed: [:0]const u8,
    app_agent_hook_trust_diverged: [:0]const u8,
    app_ended_placeholder: [:0]const u8,
    app_recovered_session_failed: [:0]const u8,
    app_shell_died_startup: [:0]const u8,
    app_save_external_conflict: [:0]const u8,
    app_save_too_large: [:0]const u8,
    app_save_failed: [:0]const u8,
    app_cli_installed: [:0]const u8,
    app_cli_installed_path_hint: [:0]const u8,
    app_upload_done_pane_closed: [:0]const u8,
    fp_delete_protected: [:0]const u8,
    fp_delete_denied: [:0]const u8,
    fp_name_invalid: [:0]const u8,
    fp_change_protected: [:0]const u8,
    fp_name_unchanged: [:0]const u8,
    fp_change_denied: [:0]const u8,
    fp_mutation_collision: [:0]const u8,
    fp_mutation_not_found: [:0]const u8,
    fp_mutation_denied: [:0]const u8,
    fp_mutation_failed: [:0]const u8,
    fp_manual_recovery: [:0]const u8,
    /// 위 문장의 **폴백**(계약 §6.3) — 경로가 길어 잘릴 상황에서 쓴다. 잘린 경로는 어느 파일인지 알려
    /// 주지 못하므로 "로그를 보라"는 **다른 행동**을 안내한다. 그래서 같은 문장의 축약이 아니라 별도 키다.
    fp_manual_recovery_fallback: [:0]const u8,
    fp_abort_unsaved: [:0]const u8,
    fp_abort_edit_check: [:0]const u8,
    dbg_editor_not_utf8: [:0]const u8,
    /// 심볼 피커: 이 파일에는 갈 심볼이 없다(§7.5 저하 표 — 「없다」와 「아직 모른다」는 다르다).
    symbol_picker_empty: [:0]const u8,
    /// 심볼 피커 프롬프트에서 **부모가 없을 때**(최상위 심볼들의 목록) 쓰는 이름(§7.5).
    /// 부모가 있으면 그 **심볼 이름**을 그대로 쓰므로 번역할 것이 이 하나뿐이다.
    symbol_picker_top_level: [:0]const u8,
    dbg_editor_too_large: [:0]const u8,
    dbg_editor_unreadable: [:0]const u8,
    dbg_editor_oom: [:0]const u8,

    // ── 확인 대화상자와 버튼 라벨 (I3a 슬라이스 5) ──
    // `btn_*` 는 여러 대화상자가 공유하는 **행동 이름**이라 대화상자별 접두를 쓰지 않는다.
    common_confirm: [:0]const u8,
    common_cancel: [:0]const u8,
    btn_quit: [:0]const u8,
    btn_quit_end_session: [:0]const u8,
    btn_reset: [:0]const u8,
    btn_reload: [:0]const u8,
    btn_move_to_trash: [:0]const u8,
    btn_discard_changes: [:0]const u8,
    btn_save: [:0]const u8,
    btn_paste: [:0]const u8,
    btn_close: [:0]const u8,
    btn_allow: [:0]const u8,
    btn_deny: [:0]const u8,
    app_quit_confirm_keepalive: [:0]const u8,
    app_quit_confirm: [:0]const u8,
    app_reset_confirm: [:0]const u8,
    app_reload_external_confirm: [:0]const u8,
    fp_trash_confirm: [:0]const u8,
    fp_close_external_confirm: [:0]const u8,
    fp_unsaved_confirm: [:0]const u8,
    term_paste_confirm: [:0]const u8,

    // ── 닫기 확인 (I3a 슬라이스 5 후속) ──
    // `app_close_window_running` 은 **두 파일이 같은 문장을 리터럴로 중복**하고 있었다
    // (`app_session.zig` 의 닫기 분기와 `app_session/workspace.zig` 의 창 닫기). 키로 합치면서
    // 그 이중 출처가 사라진다 — 한쪽만 고쳐지는 드리프트가 원천에서 없어진다.
    app_close_running: [:0]const u8,
    app_close_window_running: [:0]const u8,
    app_close_browser: [:0]const u8,
    app_close_window_browser: [:0]const u8,
    /// 저장하지 않은 편집이 있는 편집기를 닫으려 할 때(file-panel-dock-ui.md §3.2 "dirty 보호").
    /// **`app_close_running`을 재사용하지 않는다** — 실행 중 명령이 없는데 "명령이 돌고 있다"고
    /// 말하면 사용자가 무엇을 잃는지 모른다. 브라우저 탭이 같은 이유로 자기 문구를 갖는다.
    app_close_unsaved: [:0]const u8,
    app_close_window_unsaved: [:0]const u8,

    // ── 세팅 섹션 이름 (I4) ──
    // 스키마의 `Section` 과 1:1 이다. 새 섹션을 넣고 여기 키를 빠뜨리면 `settingsSectionLabel` 의
    // switch 가 미처리 변형으로 **컴파일에 걸린다** — 이름 없는 섹션이 화면에 생기지 않는다.
    set_section_app: [:0]const u8,
    set_section_font: [:0]const u8,
    set_section_theme: [:0]const u8,
    set_section_cursor: [:0]const u8,
    set_section_window: [:0]const u8,
    set_section_input: [:0]const u8,
    set_section_terminal: [:0]const u8,
    set_section_workspace: [:0]const u8,
    set_section_quick_terminal: [:0]const u8,
    set_section_sidebar: [:0]const u8,
    set_section_global_hotkey: [:0]const u8,
    set_section_editor: [:0]const u8,
    set_section_other: [:0]const u8,

    // ── 컨텍스트 메뉴 (I3a 슬라이스 6) ──
    // 계약 §7.2 가 "정적·동적이 한 배열에 섞여 타입 전환이 불가능하다"고 지목한 자리다
    // (`context_menu_items_buf` 는 `[N][]const u8` 이고 리터럴과 동적 라벨이 같은 배열을 쓴다).
    // 키로 옮겨도 그 배열의 타입은 못 바꾸므로 **2 차 리터럴 검사가 여기서는 영구 방어로 남는다.**
    ctx_new_file: [:0]const u8,
    ctx_new_folder: [:0]const u8,
    ctx_rename: [:0]const u8,
    ctx_move_to_trash: [:0]const u8,
    ctx_open_file: [:0]const u8,
    ctx_open_folder: [:0]const u8,
    ctx_add_folder_to_workspace: [:0]const u8,
    ctx_remove_folder_from_workspace: [:0]const u8,
    ctx_group_create: [:0]const u8,
    ctx_group_sibling: [:0]const u8,
    ctx_group_ungroup: [:0]const u8,
    ctx_group_remove: [:0]const u8,
    ctx_group_promote: [:0]const u8,
    ctx_copy: [:0]const u8,
    ctx_paste: [:0]const u8,
    // pin 라벨 6 종 — 세 축(그룹째·그룹 내·개별)이 각각 켬/끔을 갖는다.
    ctx_group_unpin: [:0]const u8,
    ctx_group_pin: [:0]const u8,
    ctx_local_unpin: [:0]const u8,
    ctx_local_pin: [:0]const u8,
    ctx_unpin: [:0]const u8,
    ctx_pin: [:0]const u8,

    // ── config 설명문 = 세팅 GUI 라벨 (I3b) ──
    // `Meta.doc` 은 **문서용 설명이자 동시에 세팅 화면의 행 라벨**이다(`schema.zig` 의 "GUI 라벨" 단언,
    // `settingsRowLabel`). 그래서 번역 대상이고, 키 이름은 config 키에서 유도했다(`font.size` →
    // `cfg_font_size`) — 그래야 어느 설정의 설명인지 키만 보고 안다.
    cfg_font_size: [:0]const u8,
    cfg_font_line_height: [:0]const u8,
    cfg_mob_font_line_height: [:0]const u8,
    cfg_font_letter_spacing: [:0]const u8,
    cfg_font_family: [:0]const u8,
    cfg_font_fallback: [:0]const u8,
    cfg_font_family_bold: [:0]const u8,
    cfg_font_family_italic: [:0]const u8,
    cfg_font_ligatures: [:0]const u8,
    cfg_theme_background: [:0]const u8,
    cfg_theme_foreground: [:0]const u8,
    cfg_theme_cursor: [:0]const u8,
    cfg_theme_selection: [:0]const u8,
    cfg_cursor_shape: [:0]const u8,
    cfg_cursor_blink: [:0]const u8,
    cfg_cursor_blink_interval_ms: [:0]const u8,
    cfg_cursor_blink_fade_ms: [:0]const u8,
    cfg_cursor_unfocused: [:0]const u8,
    cfg_input_page_keys: [:0]const u8,
    cfg_input_shift_enter: [:0]const u8,
    cfg_input_ime_enter: [:0]const u8,
    cfg_input_url_click_modifier: [:0]const u8,
    cfg_input_mouse_hide_while_typing: [:0]const u8,
    cfg_input_option_as_meta: [:0]const u8,
    cfg_input_right_click: [:0]const u8,
    cfg_input_word_separators: [:0]const u8,
    cfg_input_link_detection: [:0]const u8,
    cfg_input_link_open_target: [:0]const u8,
    cfg_input_paste_protection: [:0]const u8,
    cfg_input_bracketed_paste_is_safe: [:0]const u8,
    cfg_input_selection_clear_on_typing: [:0]const u8,
    cfg_keyhint_enabled: [:0]const u8,
    cfg_keyhint_delay: [:0]const u8,
    cfg_keyhint_modifier: [:0]const u8,
    cfg_session_keep_alive_after_quit: [:0]const u8,
    cfg_sidebar_show_branch: [:0]const u8,
    cfg_sidebar_show_folder: [:0]const u8,
    cfg_sidebar_agent_hooks: [:0]const u8,
    /// 이미지 갤러리 도크(docs/agent-image-gallery.md §2). **셋을 가른다** — 「에이전트가 없다」·
    /// 「훑었는데 없다」·「못 봤다」. 한 문구로 접으면 사용자가 «이미지가 없는 것» 과 «갤러리가 고장난 것» 을
    /// 구분할 수 없다(SCM 도크의 3-상태 안내와 같은 규율).
    image_gallery_no_agent: [:0]const u8,
    image_gallery_empty: [:0]const u8,
    image_gallery_partial: [:0]const u8,
    /// 워커가 아직 훑는 중. 3.6초 동안 「없습니다」라고 거짓말하지 않기 위해 따로 든다.
    image_gallery_scanning: [:0]const u8,
    /// 개수 뒤에 붙는 단위. 「12장」처럼 숫자와 이어 붙인다.
    image_gallery_count_suffix: [:0]const u8,
    /// 격자에 다 못 들어갈 때. **「없다」와 「안 보인다」는 다른 사실이다** — 접으면 사용자가
    /// 이미지를 놓치고도 모른다(계약 §2). `{0}` 보이는 수, `{1}` 전체 수. 두 언어의 **어순이
    /// 반대**라(en "4 of 12" / ko "12장 중 4장") 조각을 이어 붙이면 한쪽이 반드시 틀린다.
    image_gallery_shown_of: [:0]const u8,
    /// 크게 보기에서 그 이미지를 못 풀었을 때. **닫고 없던 일로 하지 않는다** — 눌렀는데
    /// 아무 일도 안 일어나면 사용자는 클릭이 안 먹은 줄 안다.
    image_gallery_open_failed: [:0]const u8,
    /// 검색줄의 앞머리. 뒤에 사용자가 친 글자가 붙는다.
    image_gallery_search_prompt: [:0]const u8,
    /// 검색어에 걸린 것이 없을 때. 「이 세션에 이미지가 없다」와 **다른 사실**이라 나눈다.
    image_gallery_no_match: [:0]const u8,
    agent_hook_notice_done: [:0]const u8,
    agent_hook_notice_failed: [:0]const u8,
    agent_hook_notice_attention: [:0]const u8,
    cfg_sidebar_width_pt: [:0]const u8,
    cfg_editor_wrap: [:0]const u8,
    cfg_editor_tab_width: [:0]const u8,
    cfg_editor_cursor_shape: [:0]const u8,
    cfg_statusbar_show: [:0]const u8,
    cfg_quick_height_fraction: [:0]const u8,
    cfg_quick_width_fraction: [:0]const u8,
    cfg_quick_auto_hide: [:0]const u8,
    cfg_quick_screen: [:0]const u8,
    cfg_quick_position: [:0]const u8,
    cfg_quick_chrome: [:0]const u8,
    cfg_quick_minimal_tabs: [:0]const u8,
    cfg_ui_language: [:0]const u8,
    cfg_chrome_tab_style: [:0]const u8,
    cfg_theme_follow_system: [:0]const u8,
    cfg_theme_preset_light: [:0]const u8,
    cfg_theme_preset_dark: [:0]const u8,
    cfg_text_blink: [:0]const u8,
    cfg_text_ambiguous_width: [:0]const u8,
    cfg_text_emoji_width: [:0]const u8,
    cfg_theme_bold_is_bright: [:0]const u8,
    cfg_theme_min_contrast: [:0]const u8,
    cfg_window_padding_top: [:0]const u8,
    cfg_window_padding_right: [:0]const u8,
    cfg_window_padding_bottom: [:0]const u8,
    cfg_window_padding_left: [:0]const u8,
    cfg_window_opacity: [:0]const u8,
    cfg_render_frame_rate: [:0]const u8,
    cfg_window_background_image: [:0]const u8,
    cfg_window_blur: [:0]const u8,
    cfg_window_unfocused_dim: [:0]const u8,
    cfg_split_divider_thickness: [:0]const u8,
    cfg_term: [:0]const u8,
    cfg_filepanel_external_link_target: [:0]const u8,
    cfg_shell_command: [:0]const u8,
    cfg_shell_windows_shell: [:0]const u8,
    cfg_workspace_tab_inherit_cwd: [:0]const u8,
    cfg_workspace_split_inherit_cwd: [:0]const u8,
    cfg_workspace_hold_on_startup_failure: [:0]const u8,
    cfg_shellint_ssh: [:0]const u8,
    cfg_ssh_server_alive_interval: [:0]const u8,
    cfg_ssh_server_alive_count_max: [:0]const u8,
    cfg_ssh_reconnect: [:0]const u8,
    cfg_notif_osc: [:0]const u8,
    cfg_notif_update_check: [:0]const u8,
    cfg_notif_history_limit: [:0]const u8,
    cfg_scrollback_lines: [:0]const u8,
    cfg_scrollback_sticky_command: [:0]const u8,
    cfg_scroll_multiplier: [:0]const u8,
    cfg_osc52_read: [:0]const u8,
    cfg_bell_audible: [:0]const u8,
    cfg_bell_visual: [:0]const u8,
    cfg_bell_dock_badge: [:0]const u8,

    // ── 알림 패널 (I3c) ──
    // 이 여섯은 **패널 최소 폭을 정한다** — 헤더가 제목 + 두 버튼이라, 라벨이 길어지면 겹친다.
    // 그래서 폭을 상수로 두지 않고 이 값들에서 계산한다(계약 §6.1).
    notif_heading: [:0]const u8,
    notif_empty_heading: [:0]const u8,
    notif_empty_subtext: [:0]const u8,
    notif_empty_title: [:0]const u8,
    notif_mark_all: [:0]const u8,
    notif_clear_all: [:0]const u8,

    // ── 세션 도크 (I3c) ──
    // `common_` 접두 여섯은 **archive_detail 과 session_dock 이 같은 뜻으로 쓴다**(둘 다 에이전트
    // 세션의 상태·역할을 말한다). 한쪽 접두를 쓰면 그 키를 읽는 사람이 다른 소비처를 못 보고,
    // 같은 문장에 키를 둘 두면 이중 출처가 되어 한쪽만 고쳐진다 — 슬라이스 3 에서 같은 판단을 했다.
    sd_host_local: [:0]const u8,
    sd_count_analyzing: [:0]const u8,
    sd_count_partial: [:0]const u8,
    sd_count: [:0]const u8,
    sd_header: [:0]const u8,
    sd_scope_workspace: [:0]const u8,
    sd_scope_project: [:0]const u8,
    sd_scope_all: [:0]const u8,
    sd_search: [:0]const u8,
    common_session_analyzing: [:0]const u8,
    common_recent_conversation: [:0]const u8,
    sd_detail_stale: [:0]const u8,
    common_session_unavailable: [:0]const u8,
    common_action_records: [:0]const u8,
    common_role_user: [:0]const u8,
    common_role_assistant: [:0]const u8,
    sd_stale_hint: [:0]const u8,
    sd_unavailable_hint: [:0]const u8,
    sd_resume: [:0]const u8,
    sd_reveal: [:0]const u8,
    sd_sort_newest: [:0]const u8,
    sd_sort_oldest: [:0]const u8,

    // ── 아카이브 상세 · SCM 도크 (I3c) ──
    ad_detail_aborted: [:0]const u8,
    ad_summary_subtitle: [:0]const u8,
    ad_stale_badge: [:0]const u8,
    ad_unavailable_badge: [:0]const u8,
    ad_stale_body: [:0]const u8,
    ad_unavailable_body: [:0]const u8,
    common_focus_live: [:0]const u8,
    scm_loading: [:0]const u8,
    scm_load_failed: [:0]const u8,
    scm_show_all_more: [:0]const u8,
    /// 히스토리 목록 끝에서 커밋을 **더 읽는다**(P4). `모두 보기`와 다른 말이다 — 그쪽은 이미 읽은 것을
    /// 다 펴는 것이고, 이쪽은 git을 다시 부른다.
    scm_load_more: [:0]const u8,
    scm_commit_placeholder: [:0]const u8,
    scm_commit: [:0]const u8,
    scm_committing: [:0]const u8,
    scm_commit_slow: [:0]const u8,
    /// 브랜치 줄의 원격 갱신 버튼(P6). **`push`/`pull`은 이 버튼이 아니다** — 그 둘은 터미널에 명령을
    /// 넣어 주고 실행은 사용자가 한다(docs/editor-surface-dock-write.md §4).
    /// 편집기 pane 상태바(native-editor-layering.md §2.2). **읽기 전용은 상시 자리**이고(편집이 막혀
    /// 있음을 알리는 유일한 표시), 저하는 축소가 일어났을 때만 나타난다.
    editor_readonly: [:0]const u8,
    /// 행 수를 아직 다 못 셌다 — 그동안 스크롤바 길이가 실제보다 짧다(§2.1의 "없는 대로 그린다").
    editor_counting_rows: [:0]const u8,
    /// 원격이 없어 fetch를 누를 수 없다는 진술. **왜 안 되는지 말한다** — 비활성만 두면 고장으로 읽힌다.
    scm_no_remote: [:0]const u8,
    /// fetch가 끝났고 새로 온 것이 없다. 실패와 구별해야 한다 — 그쪽은 stderr가 이유를 말한다.
    scm_fetch_done: [:0]const u8,
    /// `∨` 보조 메뉴의 두 줄(P6b). **우리가 실행하지 않는다** — 활성 터미널에 명령을 넣어 주고 엔터는
    /// 사용자가 친다. 그래서 문구가 동작이 아니라 **넣어 줄 명령**을 말한다.
    scm_menu_push: [:0]const u8,
    scm_menu_pull: [:0]const u8,
    /// 브랜치 줄 `∨` 메뉴 — ahead/behind의 **기준**을 고른다(§3.5. `origin/HEAD`가 없는 저장소에 필요하다).
    scm_menu_pick_base: [:0]const u8,
    /// 기준 목록의 첫 줄 — 고른 기준을 버리고 `origin/HEAD`로 돌아간다.
    scm_base_default: [:0]const u8,
    /// 고른 기준을 **기억하지 못했다**(기억할 저장소 수 상한). 조용히 돌아가면 사용자는 "골랐는데
    /// 아무 일도 안 일어난다"만 겪는다 — 그것이 이 기능의 가장 나쁜 실패다(§3.5).
    scm_base_limit: [:0]const u8,
    /// 원격(SSH) 저장소를 보는 동안 아직 못 하는 동작을 눌렀을 때(RS2 — docs/plans/remote-scm.md).
    /// **「안 됩니다」가 아니라 「아직」이다** — RS3·RS4 가 diff 와 쓰기를 원격으로 잇는다.
    scm_remote_read_only: [:0]const u8,
    /// 명령을 넣을 터미널이 없다(활성 surface가 터미널이 아니다).
    scm_no_terminal: [:0]const u8,
    scm_changes: [:0]const u8,
    scm_history: [:0]const u8,
    scm_staged: [:0]const u8,

    // ── session 레이어 (I3d) ──
    // **L2 중립 레이어에도 UI 문자열이 있다** — 컨텍스트 메뉴·도크 배지·아카이브 제목. 위상 문제는
    // 없고(이미 중립) 번역만 하면 된다. `ctx_copy`·`ctx_paste`·`scm_staged`·`scm_changes` 는 이미
    // 있는 키를 **재사용**한다 — 같은 문장을 두 키로 두면 이중 출처가 된다.
    ctx_cut: [:0]const u8,
    ctx_select_all: [:0]const u8,
    /// 편집기 우클릭 메뉴의 보내기 구획 머리글(NS5 — docs/send-selection-to-agent.md §5.1).
    ctx_send_selection: [:0]const u8,
    /// 대상이 자리(`max_agent_targets`)를 넘어 잘렸을 때 머리글에 붙는 꼬리. `{0}`=실린 수, `{1}`=전체 수.
    ctx_send_selection_truncated: [:0]const u8,
    /// 멀티 커서일 때 머리글에 붙는 꼬리 — **주 선택만 간다**는 사실을 말한다.
    ctx_send_selection_primary_only: [:0]const u8,
    /// 보내기 대상 줄에서 **에이전트가 아닌** Term 을 부르는 말(§5 — 일반 셸도 후보다).
    ctx_target_shell: [:0]const u8,
    ctx_open_link: [:0]const u8,
    ctx_copy_link: [:0]const u8,
    ctx_save_image: [:0]const u8,
    ctx_copy_path: [:0]const u8,
    ctx_open_source_mode: [:0]const u8,
    dock_read: [:0]const u8,
    dock_rich: [:0]const u8,
    dock_source: [:0]const u8,
    dock_staged: [:0]const u8,
    dock_worktree: [:0]const u8,
    dock_new_file: [:0]const u8,
    /// diff 탭 라벨: 히스토리에서 고른 커밋 하나(`커밋^ ↔ 커밋`).
    dock_commit: [:0]const u8,
    /// diff 탭 라벨: 에이전트 타임라인의 완료된 턴 하나(`스냅샷 ↔ 스냅샷`).
    dock_turn: [:0]const u8,
    dock_conflict: [:0]const u8,
    arch_untitled: [:0]const u8,
    arch_unknown_location: [:0]const u8,
    res_memory: [:0]const u8,
    scm_output_truncated: [:0]const u8,

    // ── 에이전트 도크 · 세팅 잔여 (I3a 슬라이스 7) ──
    ad_time_now: [:0]const u8,
    ad_time_minutes: [:0]const u8,
    ad_time_hours: [:0]const u8,
    ad_time_days: [:0]const u8,
    ad_time_months: [:0]const u8,
    ad_time_years: [:0]const u8,
    scm_log_read_failed: [:0]const u8,
    scm_no_commits: [:0]const u8,
    /// 목록이 상한에서 잘렸다 — "더 없다"와 "더 못 읽었다"는 다른 사실이다(P4b).
    scm_list_truncated: [:0]const u8,
    /// 펼친 커밋의 파일 목록을 읽지 못했다.
    scm_commit_files_failed: [:0]const u8,
    /// 펼친 커밋의 파일 목록이 상한에서 잘렸다.
    scm_commit_files_truncated: [:0]const u8,
    /// 그 커밋이 바꾼 파일이 없다(빈 커밋 — `--allow-empty`가 실제로 있다).
    scm_commit_no_files: [:0]const u8,
    /// 에이전트 탭: 이번 실행에서 관측한 턴이 없다. **오류가 아니다**(링은 메모리·창 로컬이다).
    scm_no_turns: [:0]const u8,
    /// 에이전트 탭: 그 Term 에 에이전트가 있는데 **세션 신원을 모른다**. 훅 모드에서만 이 목록이 서므로
    /// (계약 §6.1) 빈 이유를 «아직 턴이 없다» 와 구별해 말한다 — 관측 모드에서는 영영 안 뜨기 때문이다.
    scm_turns_need_hooks: [:0]const u8,
    /// 에이전트 탭: **기록하지 못한 턴 수.** 백엔드의 스냅샷 자리가 하나라 다른 세션의 캡처가 도는 중에
    /// 턴이 끝나면 그 요청이 거절되고 그 턴은 영영 안 찍힌다. 재시도하지 않는 대신(스냅샷 시점이 어긋나
    /// 내용이 틀린 턴이 된다) **몇 개를 놓쳤는지 말한다** — 한계를 숨기지 않는다.
    scm_turns_missed: [:0]const u8,
    /// 에이전트 탭: **그 세션의 이전 기록이 밀려났다.** 링 맵은 최근 세션 신원 몇 개까지만 들고, 넘으면
    /// 가장 오래 안 쓴 세션부터 버린다(`turn_snapshot.max_sessions`). 이 줄이 없으면 화면은 「밀려났다」를
    /// 「이번 실행에서 관측한 턴이 없다」로 말해, 있었던 기록을 없었던 것처럼 만든다.
    ///
    /// **목록이 비어 있든 아니든 뜬다**(`scm_turns_missed` 와 같은 규율) — 밀린 세션이 다시 돌기 시작하면
    /// 새 턴이 목록을 채우는데, 그때 이 줄이 없으면 그 몇 개가 전부인 것처럼 보인다.
    scm_turns_evicted: [:0]const u8,
    /// 에이전트 탭: 마지막 스냅샷 이후 작업트리에 생긴 변경(오른쪽이 작업트리라 계속 변한다).
    ///
    /// ⚠️ **에이전트 상태가 아니다.** 이 줄은 링에 스냅샷이 하나라도 있으면 **늘 선다** — 에이전트가
    /// 놀고 있어도, 사용자가 에디터로 고친 것만 있어도 선다. 예전 문구가 `진행 중` 이라 «에이전트가
    /// 지금 돌고 있다» 로 읽혔고, 실제로 그렇게 오해됐다(사용자 지적 2026-08-23). 진짜 실행 상태는
    /// 사이드바 배지가 말한다.
    scm_turn_live: [:0]const u8,
    /// 에이전트 탭: 직전에 끝난 턴.
    scm_turn_last: [:0]const u8,
    /// 에이전트 탭: `N턴 전`의 접미. 숫자는 host가 붙인다.
    scm_turn_back_suffix: [:0]const u8,
    /// 에이전트 탭: 그 턴이 바꾼 파일 수. 0이면 **자리를 비운다**(«0개»를 그리지 않는다 — 읽지 못한
    /// 턴도 0으로 오기 때문이다).
    scm_turn_file_count: [:0]const u8,
    /// 그 턴에 **에이전트 편집 도구가 실제로 바꾼** 파일 수. 문구는 계약 §4.2 의 배지 이름을 그대로 쓴다.
    /// 옆의 `scm_turn_file_count` 와 **다른 질문의 답**이다 — 그쪽은 작업트리 전체가 바뀐 수라
    /// 셸 편집·사용자·다른 세션이 섞이고, 이쪽은 세션별로 확정된 수다.
    scm_turn_edited_count: [:0]const u8,
    /// 펼친 턴의 파일 행 **뒤**에 서는 고지(계약 §5). 그 턴에 셸 도구를 부른 횟수를 말한다.
    ///
    /// **커버리지가 아니라 귀속을 말한다.** tree 가 셸 편집도 잡으므로 그 파일들은 목록에 이미 `·` 로
    /// 떠 있다 — 모르는 것은 「그 N개 중 무엇이 어느 파일을 고쳤는가」다. (계약 §5 의 예시 문구는
    /// **캡처만 남는 세계**를 그린 것이라 커버리지 어투다.)
    scm_turn_shell_notice: [:0]const u8,
    /// 에이전트 탭: 그 턴의 파일 목록을 읽지 못했다.
    scm_turn_files_failed: [:0]const u8,
    /// 에이전트 탭: 그 턴이 바꾼 파일이 없다.
    scm_turn_no_files: [:0]const u8,
    ad_no_model: [:0]const u8,
    ad_meta_messages: [:0]const u8,
    ad_meta_subagents: [:0]const u8,
    ad_meta_subagents_more: [:0]const u8,
    ctx_group_pin_header: [:0]const u8,
    set_ansi_palette: [:0]const u8,
    set_syntax_color: [:0]const u8,
    set_reset_named: [:0]const u8,
    set_theme_preset: [:0]const u8,
    set_custom: [:0]const u8,
    set_shell_args_ph: [:0]const u8,
    set_env_ph: [:0]const u8,
    set_macro_ph: [:0]const u8,
    set_cwd_ph: [:0]const u8,
    set_shell_not_found: [:0]const u8,

    // ── app_session 본체 (I3a 슬라이스 8) ──
    app_last_activity: [:0]const u8,
    app_shared_all_windows: [:0]const u8,
    app_session_host_shared: [:0]const u8,
    app_editor: [:0]const u8,
    set_direct_input: [:0]const u8,
    app_more_lines: [:0]const u8,
    upd_available_ver: [:0]const u8,
    upd_github: [:0]const u8,
    upd_brew: [:0]const u8,
    st_blocked: [:0]const u8,
    st_running: [:0]const u8,
    app_count_items: [:0]const u8,
    col_name: [:0]const u8,
    col_resource: [:0]const u8,
    app_closed_tab: [:0]const u8,
    exit_immediate: [:0]const u8,
    exit_code: [:0]const u8,
    exit_signal: [:0]const u8,
    exit_abnormal: [:0]const u8,
    exit_read_error: [:0]const u8,

    // ── I3a 잔여: git·diff·SCM·탐색기 (슬라이스 9) ──
    // `git_not_a_repo` 는 `app_session/git.zig` 와 `shell_integration.zig` 가 **같은 문장을 각자**
    // 적고 있었다 — 키로 합치며 그 이중 출처가 사라진다.
    cmd_toggle_window: [:0]const u8,
    cmd_show_window: [:0]const u8,
    cmd_toggle_quick: [:0]const u8,
    fp_no_branch: [:0]const u8,
    fp_recent_files: [:0]const u8,
    fp_open_to_show_tree: [:0]const u8,
    diff_loading: [:0]const u8,
    diff_no_changes: [:0]const u8,
    diff_too_large: [:0]const u8,
    diff_not_text: [:0]const u8,
    diff_read_failed: [:0]const u8,
    diff_ready: [:0]const u8,
    git_not_a_repo: [:0]const u8,
    git_repo_unknown: [:0]const u8,
    git_no_changes: [:0]const u8,
    git_not_installed: [:0]const u8,
    git_read_failed: [:0]const u8,
    scm_repo_unread: [:0]const u8,
    scm_nothing_to_stage: [:0]const u8,
    scm_git_spawn_failed: [:0]const u8,
    scm_git_command_failed: [:0]const u8,
    /// 원격 명령이 **git 에 닿지 못했다**(ssh 가 255 로 끝났다). git 이 한 말이 아니므로 그 stderr 를
    /// 저장소 이야기로 보여 주면 안 된다 — 사용자가 자기 저장소를 의심한다.
    scm_remote_transport_failed: [:0]const u8,
    scm_need_commit_message: [:0]const u8,
    scm_nothing_staged: [:0]const u8,
    scm_commit_msg_write_failed: [:0]const u8,
    sb_in_progress: [:0]const u8,
    /// 에이전트 상태줄의 나머지 셋. `sb_in_progress`(running)와 **같은 자리에 서는 문구**라 함께 산다 —
    /// 하나만 키로 옮기면 화면 한 줄에서 언어가 섞인다(실제로 그 상태로 나갔다).
    sb_awaiting_input: [:0]const u8,
    sb_agent_idle: [:0]const u8,
    sb_agent_unknown: [:0]const u8,
    /// 설정 화면의 키 힌트 넷. 화살표·기호는 그대로 두고 **낱말만** 옮긴다 — 기호는 번역 단위가 아니다.
    set_nav_hint: [:0]const u8,
    set_search_hint: [:0]const u8,
    set_search_prompt: [:0]const u8,
    set_color_pick_help: [:0]const u8,
    /// 색 선택 모달·단축키 행의 문구. 위 힌트들과 같은 화면에 서므로 함께 옮긴다.
    set_color_pick_title: [:0]const u8,
    set_color_hex_prompt: [:0]const u8,
    set_key_recording: [:0]const u8,
    set_key_unset: [:0]const u8,
    sb_group: [:0]const u8,
    tab_group_n: [:0]const u8,
    ws_cwd_must_be_absolute: [:0]const u8,
    arch_redacted: [:0]const u8,

    // ── 아카이브 상세 액션 (I2) ──
    // **아이콘·단축키를 뺀 이름만** 든다. 예전에는 `icons.utf8(.recent) ++ " 터미널에서 이어하기  ⌘↵"`
    // 처럼 셋이 한 문자열이었다(계약 §6.2 가 "최악 사례"로 지목한 자리) — 아이콘을 바꾸려면 번역
    // 테이블을 고쳐야 하고, 단축키가 keybinding 이 아니라 문장에서 왔다.
    ad_resume_action: [:0]const u8,
    ad_reveal_action: [:0]const u8,

    // ── 보기 옵션 메뉴 (I2) ──
    // **기호를 빼고 이름만 든다.** 예전에는 `"✓ 브랜치 표시"` / `"  브랜치 표시"` 두 문자열이었고,
    // 그러면 체크 기호와 정렬 공백이 번역 단위에 섞인다(계약 §6.2). 켜짐 여부는 이제 컴포넌트의
    // `checked_mask` 가 든다.
    set_show_branch: [:0]const u8,
    set_show_folder: [:0]const u8,

    // ── 모바일 (I3e) ──
    // `터미널`·`커서`·`기타`·`테마 프리셋` 은 이미 있는 `set_section_*`·`set_theme_preset` 을 **재사용**한다.
    mob_sessions: [:0]const u8,
    mob_settings: [:0]const u8,
    mob_servers: [:0]const u8,
    mob_servers_empty: [:0]const u8,
    /// 원격 세션 목록(S10d-2). **"아직 모른다" 와 "없다" 를 가른다** — 같은 문구면 화면이 없는
    /// 사실을 말한다.
    mob_sessions_loading: [:0]const u8,
    mob_sessions_none: [:0]const u8,
    /// 컨트롤 축이 꺼진 이유. 사용자가 **고칠 자리를 알 수 있게** 갈라 적는다.
    mob_control_off_timeout: [:0]const u8,
    mob_control_off_noise: [:0]const u8,
    mob_control_off_protocol: [:0]const u8,
    mob_control_off_frame: [:0]const u8,
    mob_control_off_open: [:0]const u8,
    mob_control_off_missing: [:0]const u8,
    mob_control_off_failed: [:0]const u8,
    mob_remote_screen_title: [:0]const u8,
    mob_remote_screen_readonly: [:0]const u8,
    mob_remote_screen_waiting: [:0]const u8,
    mob_remote_screen_off: [:0]const u8,
    mob_server_incomplete: [:0]const u8,
    mob_server_first_connect: [:0]const u8,
    mob_server_add: [:0]const u8,
    mob_server_edit: [:0]const u8,
    mob_server_name: [:0]const u8,
    mob_server_host: [:0]const u8,
    mob_server_port: [:0]const u8,
    mob_server_user: [:0]const u8,
    mob_server_fingerprint: [:0]const u8,
    mob_server_save: [:0]const u8,
    mob_server_delete: [:0]const u8,
    mob_server_edit_short: [:0]const u8,
    mob_pubkey: [:0]const u8,
    mob_pubkey_copied: [:0]const u8,
    mob_pubkey_absent: [:0]const u8,
    mob_password_title: [:0]const u8,
    mob_password_hint: [:0]const u8,
    mob_password_empty: [:0]const u8,
    mob_password_ok: [:0]const u8,
    mob_password_cancel: [:0]const u8,
    mob_copy: [:0]const u8,
    mob_keyboard: [:0]const u8,
    mob_disconnect: [:0]const u8,
    mob_hostkey_title: [:0]const u8,
    mob_hostkey_hint: [:0]const u8,
    mob_hostkey_ok: [:0]const u8,
    mob_hostkey_cancel: [:0]const u8,
    mob_conn_connecting: [:0]const u8,
    mob_conn_ready: [:0]const u8,
    mob_conn_unreachable: [:0]const u8,
    mob_conn_auth: [:0]const u8,
    mob_conn_hostkey: [:0]const u8,
    mob_conn_rejected: [:0]const u8,
    mob_conn_timeout: [:0]const u8,
    mob_conn_closed: [:0]const u8,
    mob_conn_ended: [:0]const u8,
    mob_conn_failed: [:0]const u8,
    mob_appearance: [:0]const u8,

    // ── 작업공간 복원 (I3f) ──
    ws_restore_incomplete: [:0]const u8,
    ws_checkpoint_capture_failed: [:0]const u8,
    /// 상태바 항목 — host 연결이 죽어 새 터미널이 유지되지 않는 상태(status-bar.md §4.3).
    status_session_not_persisted: [:0]const u8,
    ws_checkpoint_write_failed: [:0]const u8,

    // ── 브라우저 권한 확인 (리뷰 후속) ──
    // **로그인 토큰 접근을 묻는 문장이다.** 영어 UI 아래 한국어 동의문이 뜨면 사용자가 무엇을
    // 허용하는지 못 읽는다 — 버튼(`btn_allow`/`btn_deny`)은 이미 번역돼 있어 더 어긋나 보였다.
    grant_scope_storage: [:0]const u8,
    grant_scope_control: [:0]const u8,
    grant_prompt: [:0]const u8,

    // ── 파일 선택 패널 (I3f) ──
    // **Swift 는 이 문장을 만들지 않는다**(계약 §7.2) — ABI 로 키를 받아 표시만 한다.
    pick_background_png: [:0]const u8,
    pick_dock_file: [:0]const u8,
    pick_explorer_folder: [:0]const u8,
    pick_workspace_folder: [:0]const u8,

    // ── 언어 선택 (I4b) ──
    // `auto` 만 키로 둔다 — 아래 `preferenceLabel` 참고.
    set_language_auto: [:0]const u8,
};

const en: Table = .{
    .fp_root_stale_generation = "Explorer root changed, so the folder selection was discarded.",
    .fp_root_open_failed = "Cannot open the selected folder.",
    .fp_root_identity_unknown = "Cannot verify the selected folder's identity.",
    .fp_root_revalidate_alloc_failed = "Cannot prepare folder revalidation state.",
    .fp_root_revalidate_start_failed = "Could not start folder revalidation.",
    .fp_root_revalidate_invalid = "Folder revalidation state is not valid.",
    .fp_root_identity_gone = "Folder identity disappeared, so the change was discarded.",
    .fp_root_capability_gone = "Folder verification capability disappeared, so the change was discarded.",
    .fp_root_identity_changed = "The selected folder was replaced during verification, so the change was discarded.",
    .fp_root_change_alloc_failed = "Cannot prepare explorer root change state.",
    .fp_root_replace_failed = "Cannot replace the explorer root.",
    .fp_root_add_failed = "Cannot add the folder to the workspace.",
    .fp_root_watch_change_failed = "Cannot refresh folder watching, so the root change was discarded.",
    .fp_root_rows_change_failed = "Cannot prepare explorer row state, so the root change was discarded.",
    .fp_root_first_scan_alloc_failed = "Cannot prepare the first scan of the verified explorer root.",
    .fp_root_scan_start_failed = "Could not start the verified folder scan, so the change was discarded.",
    .fp_root_busy_retry = "Try again after the file change or folder selection finishes.",
    .fp_root_remove_alloc_failed = "Cannot prepare explorer root removal state.",
    .fp_root_remove_failed = "Cannot remove the explorer root.",
    .fp_root_missing = "The selected explorer root no longer exists.",
    .fp_root_watch_remove_failed = "Cannot refresh folder watching, so the root removal was discarded.",
    .fp_root_rows_remove_failed = "Cannot prepare explorer row state, so the root removal was discarded.",
    .fp_root_invalid_path = "The selected folder path is not valid.",
    .fp_root_request_id_exhausted = "Cannot issue more folder selection request numbers.",
    .fp_root_picker_alloc_failed = "Cannot prepare folder selection state.",
    .fp_root_validate_busy = "Folder verification is busy, so the request could not start.",

    .set_global_key_not_allowed = "This key cannot be registered as a global shortcut",
    .set_global_chord_taken = "This global shortcut is already bound to another action — overwriting",
    .set_no_chord_assigned = "No shortcut is assigned yet",
    .set_no_global_chord_assigned = "No global shortcut is assigned yet",
    .set_env_format = "Environment variables must be in KEY=VALUE form",
    .set_env_key_empty = "The environment variable KEY is empty",
    .set_chord_parse_failed = "Could not read the shortcut notation",
    .set_macro_format = "Macros must be in text:/esc:/ctrl: form",
    .set_chord_conflict = "Could not apply — it conflicts with another shortcut",
    .set_macro_overrides_default = "A macro overrides the default shortcut",
    .set_macro_line_format = "Macros must be in 'chord = text:...' form",
    .set_chord_empty = "The shortcut is empty",
    .set_chord_taken_by = "This shortcut is already bound to '{0}' — overwriting",

    .git_branch_list_failed = "Could not read the branch list",
    .git_path_outside_repo = "Paths outside the repository are not opened",
    .git_submodule_no_diff = "Submodules do not show a diff",
    .ws_move_target_has_file = "The target window already has that file open, so the workspace was not moved.",
    .ws_move_target_tabs_full = "The target window has too many file tabs, so the workspace was not moved.",
    .ad_session_list_apply_failed = "Could not apply the new session list, so the previous list was kept.",
    .ad_workspace_path_missing = "Cannot find a local path for the active workspace.",
    .ad_terminal_git_project_missing = "Cannot find a local git project for the current terminal.",
    .ad_path_scan_start_failed = "Could not start workspace path analysis.",
    .ad_path_scan_restart_failed = "Could not restart workspace path analysis.",
    .ad_session_archive_open_failed = "Could not open the session history.",
    .ad_session_resume_failed = "Could not resume the session. Check the Claude or Codex CLI installation and the working path.",
    .ad_log_source_changed = "The log source changed or can no longer be opened.",
    .ad_open_session_not_found = "Could not find the same session already open.",

    .app_attach_observer_mode = "Another window controls this session, so it was attached in observer mode. The screen updates but input is not delivered.",
    .common_unsaved_tabs_first = "Save or close the unsaved file tabs first.",
    .app_cli_install_path_missing = "CLI install failed: could not find the maru CLI path",
    .app_cli_install_binary_missing = "CLI install failed: could not find the maru CLI binary",
    .app_cli_install_no_home = "CLI install failed: $HOME is not set",
    .app_cli_install_symlink_failed = "CLI install failed: could not create the symlink",
    .app_shell_restart_failed = "Failed to restart the shell — check Settings (⌘,).",
    .app_shell_start_failed = "Could not start the shell — check shell.command and shell.args in Settings (⌘,).",
    .app_file_send_sync_failed = "Could not sync session info. Try the file transfer again.",
    .app_file_send_prepare_failed = "Could not prepare the remote file transfer. The local path was not pasted.",
    .app_file_send_start_failed = "Could not start the remote file transfer. Check the file size and permissions.",
    .app_file_send_failed = "The remote file transfer failed. Check the SSH connection and try again.",
    .app_image_send_sync_failed = "Could not sync session info. Try the image transfer again.",
    .app_image_send_too_large = "The remote image transfer limit is 16MB. It did not fall back to a local paste.",
    .app_image_send_prepare_failed = "Could not prepare the remote image transfer. It did not fall back to a local paste.",
    .app_image_send_oom = "Not enough memory to prepare the remote image transfer. It did not fall back to a local paste.",
    .app_image_send_start_failed = "Could not start the remote image transfer. It did not fall back to a local paste.",
    .app_image_send_failed = "The remote image transfer failed. Check the SSH connection and try again. It did not fall back to a local paste.",
    .app_no_measured_terminal = "No terminal has been measured yet",
    .set_git_backend_start_failed = "Could not start the git backend",
    .set_git_not_found = "Could not find git",
    .set_no_branches = "There are no branches",
    .set_branch_name_invalid = "Cannot turn the branch name into a command",
    .set_link_open_failed = "Could not open the link.",
    .set_root_changed_cancel = "The explorer root changed, so the command was cancelled.",
    .set_selection_changed_cancel = "The selection changed, so the command was cancelled.",
    .set_reset_write_failed = "Reset to defaults (applied on screen) — writing the config file failed",
    .set_reset_done_keepalive = "All settings were reset to defaults — session keep-alive was left as is to protect live terminals. Turn it off in Settings > workspace.",
    .set_keepalive_reset_preserved = "Session keep-alive was left as is to protect live terminals. Change it directly in Settings > workspace.",
    .set_reset_done = "All settings were reset to defaults",

    .fp_view_rebuild_failed = "Could not rebuild the file view, so the previous view was kept.",
    .fp_mutation_in_progress = "Wait until the previous file change finishes.",
    .fp_select_first = "Select a project file or folder first.",
    .fp_root_rename_denied = "The project root itself cannot be renamed.",
    .fp_symlink_dir_create_denied = "Entries cannot be created inside a symlinked folder.",
    .fp_path_too_long = "The path is too long to change.",
    .fp_dir_changed_reopen = "The explorer folder changed to a different directory, so the refresh stopped. Open the folder again.",
    .fp_trash_in_progress = "Wait until the previous move to Trash finishes.",
    .fp_trash_queue_full = "The Trash request queue is full. Try again after the previous work finishes.",
    .fp_select_to_delete = "Select the project file or folder to delete first.",
    .fp_root_delete_denied = "The project root itself cannot be deleted.",
    .fp_symlink_alias_delete_blocked = "A file being edited in the same project may be a symlink alias, so folder deletion was blocked.",
    .fp_tab_state_changed_close_cancel = "The file tab state changed, so closing was cancelled.",
    .fp_file_tab_only = "Available only on a file tab.",
    .fp_outside_root_denied = "Entries outside the project root cannot be changed.",
    .fp_symlink_alias_rename_blocked = "A file being edited in the same project may be a symlink alias, so folder rename was blocked.",
    .fp_identity_not_ready = "The file identity is not ready yet. Refresh the tree and try again.",
    .fp_mutation_queue_full = "The file change request queue is full. Try again shortly.",
    .fp_mutation_id_exhausted = "Cannot issue more file change request numbers.",
    .fp_mutation_prepare_failed = "Cannot prepare the file change request.",
    .fp_rename_plan_failed = "Cannot prepare the rename path plan.",
    .fp_entry_busy = "Another file change is using the same entry.",
    .fp_editor_lock_rename_failed = "Could not lock the editor, so the rename did not start.",
    .fp_trash_verify_failed = "Cannot verify the move to Trash. Check the Trash. Clean shutdown and file changes were blocked.",
    .fp_root_changed_delete_cancel = "The explorer root changed, so the deletion was cancelled.",
    .fp_state_changed_dir_delete_cancel = "The state changed, so folder deletion was cancelled.",
    .fp_state_changed_delete_cancel = "The state changed, so the deletion was cancelled.",
    .fp_delete_recovery_prepare_failed = "Could not prepare the delete recovery path, so it did not start.",
    .fp_editor_lock_trash_failed = "Could not lock the editor, so the move to Trash did not start.",
    .fp_edit_state_changed_rename_cancel = "The edit state changed, so the rename was cancelled.",
    .fp_edit_state_changed_trash_cancel = "The edit state changed, so the move to Trash was cancelled.",
    .fp_trash_adapter_queue_full = "The Trash adapter queue is full, so it is restored to the original location.",
    .fp_trash_failed_restored = "The move to Trash failed, so it was restored to the original location.",
    .fp_close_after_mutation = "The tab can be closed after the file change finishes.",
    .fp_close_id_exhausted = "Cannot issue more file close request numbers, so the tab was not closed.",
    .fp_close_prepare_failed = "Cannot prepare the file close state, so the tab was not closed.",
    .fp_nothing_to_focus = "There is nothing to focus in the file panel.",
    .fp_trash_done_tab_kept = "The move to Trash finished, but the edit state changed so the open tab is kept.",
    .fp_edit_state_recheck_failed = "Could not re-check the edit state, so the file tab was protected.",
    .fp_save_failed_tab_kept = "Could not save the file, so the tab was not closed.",
    .fp_post_save_check_failed = "Could not check the edit state after saving, so the tab was not closed.",
    .fp_web_content_restarted = "The web content being edited restarted, so file work is blocked until automatic recovery.",
    .fp_web_content_terminated = "The web content being edited terminated, so file work is blocked until automatic recovery.",
    .fp_edit_state_check_failed = "Could not check the edit state, so the tab was not closed.",

    .term_clipboard_too_large = "The clipboard copy was too large and was cancelled (about {0}MB max).",
    .term_remote_clipboard_too_large = "The remote session's clipboard copy was too large to deliver (about {0}KB max).",

    .app_host_connect_failed = "Could not connect to the persistent session host ({0}). Terminals in this session will not persist (they close with the app).",
    .app_session_host_upgrade_result = "Persistent session host update result: {0}",
    .app_agent_hook_trust_diverged = "Codex stores a different approval value than maru computes for {0} of its hooks. If you approved them in codex, they are running and this needs nothing. Otherwise start codex once and check whether it still asks to review hooks.",
    .app_agent_hook_trust_refreshed = "Refreshed the codex approval for {0} of maru's hooks, which had gone stale. They run again the next time codex starts.",
    .app_agent_hook_trust_stale = "Codex has not approved {0} of maru's hooks, so they will not run — agent status falls back to reading the screen. Start codex once and choose \"Trust all and continue\".",
    .app_ended_placeholder = "{0} previous sessions had already ended, so those slots are empty — the layout was restored.",
    .app_recovered_session_failed = "Could not recover this session. Refresh the session list and try again.",
    .app_shell_died_startup = "The shell exited abnormally right after start ({0}). Press Enter to retry, or check shell.command and shell.args in Settings (⌘,).",
    .app_save_external_conflict = "The file changed outside, so it cannot be saved. Reload the file and save again.",
    .app_save_too_large = "The file is too large to save.",
    .app_save_failed = "Cannot save the file.",
    .app_cli_installed = "maru CLI installed: {0}",
    .app_cli_installed_path_hint = "maru CLI installed: {0} — add {1} to PATH (for example in ~/.zshrc)",
    .app_upload_done_pane_closed = "Upload finished (the pane you dropped on closed): {0}",
    .fp_delete_protected = "Cannot delete because it includes an unsaved file or one being synced or resolved.",
    .fp_delete_denied = "This entry cannot be deleted.",
    .fp_name_invalid = "The name cannot be empty, '.', '..', or contain '/'.",
    .fp_change_protected = "Cannot change because it includes an unsaved file or one being synced or resolved.",
    .fp_name_unchanged = "That is the same name.",
    .fp_change_denied = "This entry cannot be changed.",
    .fp_mutation_collision = "An entry with the same name already exists.",
    .fp_mutation_not_found = "The target disappeared, so the file change did not complete.",
    .fp_mutation_denied = "No permission to change the file.",
    .fp_mutation_failed = "The file change failed. The tree and open tabs are kept.",
    .fp_manual_recovery = "Manual recovery is needed. Check the file at this path: {0}",
    .fp_manual_recovery_fallback = "Manual recovery is needed. Check the file at the recovery path in the log.",
    .fp_abort_unsaved = "There are unsaved edits, so the file change was cancelled.",
    .fp_abort_edit_check = "Could not check the edit state, so the file change was cancelled.",
    .dbg_editor_not_utf8 = "Native editor: not UTF-8, so it was not opened.",
    .symbol_picker_empty = "This file has no symbols to jump to.",
    .symbol_picker_top_level = "top level",
    .dbg_editor_too_large = "Native editor: the file exceeds the read limit.",
    .dbg_editor_unreadable = "Native editor: could not read the file.",
    .dbg_editor_oom = "Native editor: out of memory.",

    .common_confirm = "OK",
    .common_cancel = "Cancel",
    .btn_quit = "Quit",
    .btn_quit_end_session = "Quit and end sessions",
    .btn_reset = "Reset",
    .btn_reload = "Reload",
    .btn_move_to_trash = "Move to Trash",
    .btn_discard_changes = "Discard changes",
    .btn_save = "Save",
    .btn_paste = "Paste",
    .btn_close = "Close",
    .btn_allow = "Allow",
    .btn_deny = "Deny",
    .app_quit_confirm_keepalive = "Quit maru? Open terminals stay in the background.",
    .app_quit_confirm = "Quit maru?",
    .app_reset_confirm = "This resets all settings to defaults and overwrites the config file. Continue?",
    .app_reload_external_confirm = "The file changed outside. Discard your edits and reload from disk?",
    .fp_trash_confirm = "Move the selected item to the macOS Trash?",
    .fp_close_external_confirm = "This file changed on disk. Discard changes and close?",
    .fp_unsaved_confirm = "There are unsaved changes.",
    .term_paste_confirm = "The pasted content has newlines or control characters, so a command could run immediately. Paste anyway?",
    .app_close_running = "A command is still running. Close anyway?",
    .app_close_window_running = "A command is still running. Close this window?",
    .app_close_browser = "You have open browser tabs. Close anyway?",
    .app_close_unsaved = "You have unsaved changes. Close anyway?",
    .app_close_window_browser = "You have open browser tabs. Close this window?",
    .app_close_window_unsaved = "You have unsaved changes. Close this window?",
    .set_section_app = "App",
    .set_section_font = "Font",
    .set_section_theme = "Theme",
    .set_section_cursor = "Cursor",
    .set_section_window = "Window",
    .set_section_input = "Input",
    .set_section_terminal = "Terminal",
    .set_section_workspace = "Workspace",
    .set_section_quick_terminal = "Quick Terminal",
    .set_section_sidebar = "Sidebar",
    .set_section_global_hotkey = "Global Hotkey",
    .set_section_editor = "Editor",
    .set_section_other = "Other",
    .set_language_auto = "Automatic (OS language)",
    .notif_heading = "Notifications",
    .notif_empty_heading = "No notifications yet",
    .notif_empty_subtext = "Desktop notifications will appear here.",
    .notif_empty_title = "(No title)",
    .notif_mark_all = "Mark all read",
    .notif_clear_all = "Clear all",
    .sd_host_local = "Local",
    .sd_count_analyzing = "{0} shown · analyzing",
    .sd_count_partial = "{0} shown · partially analyzed",
    .sd_count = "{0} shown",
    .sd_header = "Agent session history",
    .sd_scope_workspace = "Workspace",
    .sd_scope_project = "Project",
    .sd_scope_all = "All",
    .sd_search = "Search sessions",
    .common_session_analyzing = "Analyzing session",
    .common_recent_conversation = "Recent conversation",
    .sd_detail_stale = "The session source changed",
    .common_session_unavailable = "Cannot open the session",
    .common_action_records = "{0} tool/permission records",
    .common_role_user = "User",
    .common_role_assistant = "Agent",
    .sd_stale_hint = "Cannot safely resume or open logs.",
    .sd_unavailable_hint = "Cannot read the source.",
    .sd_resume = "Resume in terminal",
    .sd_reveal = "View log",
    .sd_sort_newest = "Newest first",
    .sd_sort_oldest = "Oldest first",
    .ad_detail_aborted = "Session analysis was interrupted",
    .ad_summary_subtitle = "Recent conversation and action summary",
    .ad_stale_badge = "Source changed",
    .ad_unavailable_badge = "Source unreadable",
    .ad_stale_body = "The source session changed, so it is not shown for safety.",
    .ad_unavailable_body = "Cannot read the session source.",
    .common_focus_live = "Go to the open session",
    .scm_loading = "Loading…",
    .scm_load_failed = "Failed to load",
    .ctx_cut = "Cut",
    .ctx_select_all = "Select All",
    .ctx_send_selection = "Send selection to",
    .ctx_send_selection_truncated = " ({0} of {1} shown)",
    .ctx_send_selection_primary_only = " — primary selection only",
    .ctx_target_shell = "Shell",
    .ctx_open_link = "Open Link",
    .ctx_copy_link = "Copy Link Address",
    .ctx_save_image = "Save Image",
    .ctx_copy_path = "Copy Path",
    .ctx_open_source_mode = "Open in Source Mode",
    .dock_read = "Read",
    .dock_rich = "Rich",
    .dock_source = "Source",
    .dock_staged = "Staged",
    .dock_worktree = "Worktree",
    .dock_new_file = "New file",
    .dock_commit = "Commit",
    .dock_turn = "Turn",
    .dock_conflict = "Conflict",
    .arch_untitled = "Untitled session",
    .arch_unknown_location = "Unknown location",
    .res_memory = "Memory",
    .scm_output_truncated = "The git output was too large, so the list was truncated",
    .ad_time_now = "just now",
    .ad_time_minutes = "{0}m ago",
    .ad_time_hours = "{0}h ago",
    .ad_time_days = "{0}d ago",
    .ad_time_months = "{0}mo ago",
    .ad_time_years = "{0}y ago",
    .scm_log_read_failed = "Could not read commits",
    .scm_no_commits = "No commits",
    .scm_list_truncated = "Output too large — the list was truncated",
    .scm_commit_files_failed = "Could not read this commit's files",
    .scm_commit_files_truncated = "This commit's file list was truncated",
    .scm_commit_no_files = "This commit changed no files",
    .scm_no_turns = "No agent turns observed in this run",
    .scm_turns_need_hooks = "Agent turns need hooks enabled",
    .scm_turns_missed = "{0} turns were not recorded",
    .scm_turns_evicted = "Earlier turns were dropped for newer sessions",
    .scm_turn_live = "Since last turn",
    .scm_turn_last = "Last turn",
    .scm_turn_back_suffix = " turns ago",
    .scm_turn_file_count = "{0} files",
    .scm_turn_edited_count = "✎ AI edits {0}",
    .scm_turn_shell_notice = "⚠ {0} shell commands — their edits cannot be attributed to the agent",
    .scm_turn_files_failed = "Could not read this turn's files",
    .scm_turn_no_files = "This turn changed no files",
    .ad_no_model = "No model info",
    .ad_meta_messages = "{0} messages",
    .ad_meta_subagents = "{0} subagents",
    .ad_meta_subagents_more = "{0}+ subagents",
    .ctx_group_pin_header = "Pin group",
    .set_ansi_palette = "ANSI palette",
    .set_syntax_color = "Syntax color",
    .set_reset_named = "Reset {0}",
    .set_theme_preset = "Theme preset",
    .set_custom = "Custom",
    .set_shell_args_ph = "Shell args (space separated)",
    .set_env_ph = "Add environment variable (KEY=VALUE)",
    .set_macro_ph = "Add terminal macro (chord = text:...)",
    .set_cwd_ph = "Start directory (absolute or ~, empty = inherit)",
    .set_shell_not_found = "The shell executable was not found, so the default shell runs (needs an absolute path to the executable · this field is not the start directory)",
    .app_last_activity = "Last activity",
    .app_shared_all_windows = "Maru (app · shared by all windows)",
    .app_session_host_shared = "Session host (shared by all windows)",
    .app_editor = "Editor",
    .set_direct_input = "Enter directly\u{2026}",
    .app_more_lines = "\u{2026} {0} more lines",
    .upd_available_ver = "New version {0} available",
    .upd_github = "Get the latest release from GitHub",
    .upd_brew = "Update with brew upgrade maru",
    .st_blocked = "Blocked",
    .st_running = "Running",
    .app_count_items = "{0} items",
    .col_name = "Name",
    .col_resource = "Resource",
    .app_closed_tab = "(closed tab)",
    .exit_immediate = "Immediate exit",
    .exit_code = "Exit code {0}",
    .exit_signal = "Signal {0}",
    .exit_abnormal = "Abnormal exit",
    .exit_read_error = "Read error",
    .cmd_toggle_window = "Toggle window",
    .cmd_show_window = "Show window",
    .cmd_toggle_quick = "Toggle quick terminal",
    .fp_no_branch = "(no branch)",
    .fp_recent_files = "Recent files",
    .fp_open_to_show_tree = "Open a file to show the tree",
    .diff_loading = "Loading the diff\u{2026}",
    .diff_no_changes = "No changes.",
    .diff_too_large = "The change is too large to show a diff.",
    .diff_not_text = "Not text, so no diff is shown.",
    .diff_read_failed = "Could not read the diff.",
    .diff_ready = "Diff ready",
    .git_not_a_repo = "Not a git repository",
    .git_repo_unknown = "Cannot determine the repository",
    .git_no_changes = "No changes",
    .git_not_installed = "git is not installed",
    .git_read_failed = "Failed to read from git",
    .scm_repo_unread = "That repository has not been read yet",
    .scm_nothing_to_stage = "There is nothing to stage",
    .scm_git_spawn_failed = "Could not run git",
    .scm_git_command_failed = "The git command failed",
    .scm_remote_transport_failed = "Lost the connection to the remote — the command did not reach git",
    .scm_need_commit_message = "Enter a commit message",
    .scm_nothing_staged = "There are no staged changes",
    .scm_commit_msg_write_failed = "Could not write the commit message to a temporary file",
    .sb_in_progress = "In progress",
    .sb_awaiting_input = "Awaiting input",
    .sb_agent_idle = "Idle",
    .sb_agent_unknown = "Checking status",
    .set_nav_hint = "← section · → setting · ↑↓ move · ⏎ select",
    .set_search_hint = "/ search",
    .set_search_prompt = "search: ",
    .set_color_pick_help = "←→ saturation  ↑↓ brightness  [ ] hue  ⇧ fine  # hex  i eyedropper  Enter confirm  Esc cancel",
    .set_color_pick_title = "HSV color picker",
    .set_color_hex_prompt = "hex input",
    .set_key_recording = "Waiting for key…",
    .set_key_unset = "(unset)",
    .sb_group = "Group",
    .tab_group_n = "Group {0}",
    .ws_cwd_must_be_absolute = "The start directory must be an absolute path or ~/… (relative paths and ~user are ignored)",
    .arch_redacted = "[sensitive content hidden]",
    .ad_resume_action = "Resume in terminal",
    .ad_reveal_action = "View log",
    .set_show_branch = "Show branch",
    .set_show_folder = "Show folder",
    .mob_sessions = "Sessions",
    .mob_settings = "Settings",
    .mob_servers = "Servers",
    .mob_servers_empty = "No servers added yet",
    .mob_sessions_loading = "Loading sessions...",
    .mob_sessions_none = "No sessions are running",
    .mob_control_off_timeout = "The server is not responding. Make sure maru is running on it",
    .mob_control_off_noise = "Unexpected response. The server appears to enforce a fixed command",
    .mob_control_off_protocol = "The maru version on the server is not compatible. It needs an update",
    .mob_control_off_frame = "The response was too large",
    .mob_control_off_open = "Could not open the session list. The terminal still works",
    .mob_control_off_missing = "maru was not found on the server. Set its path in the server settings",
    .mob_control_off_failed = "maru on the server exited immediately",
    .mob_remote_screen_title = "Session",
    .mob_remote_screen_readonly = "viewing",
    .mob_remote_screen_waiting = "Receiving the screen...",
    .mob_remote_screen_off = "The screen stopped. Go back and open it again.",
    .mob_server_incomplete = "Enter an address and user to connect",
    .mob_server_first_connect = "Connecting for the first time. You will be asked to verify the fingerprint",
    .mob_server_add = "Add server",
    .mob_server_edit = "Edit server",
    .mob_server_name = "Name",
    .mob_server_host = "Address",
    .mob_server_port = "Port",
    .mob_server_user = "User",
    .mob_server_fingerprint = "Fingerprint",
    .mob_server_save = "Save",
    .mob_server_delete = "Delete",
    .mob_server_edit_short = "Edit",
    .mob_pubkey = "This device's public key",
    .mob_pubkey_copied = "Copied. Paste it into authorized_keys",
    .mob_pubkey_absent = "No key yet",
    .mob_password_title = "Password",
    .mob_password_hint = "The server asks for a password. It is not stored.",
    .mob_password_empty = "Enter your password",
    .mob_password_ok = "Connect",
    .mob_password_cancel = "Cancel",
    .mob_copy = "copy",
    .mob_keyboard = "kbd",
    .mob_disconnect = "disc",
    .mob_hostkey_title = "First time connecting",
    .mob_hostkey_hint = "Check this fingerprint against the server. It is saved once you accept.",
    .mob_hostkey_ok = "Fingerprint matches - Connect",
    .mob_hostkey_cancel = "Cancel",
    .mob_conn_connecting = "Connecting...",
    .mob_conn_ready = "Connected",
    .mob_conn_unreachable = "Could not reach the server. Check the address and port",
    .mob_conn_auth = "Authentication failed",
    .mob_conn_hostkey = "The server key does not match. The connection was stopped",
    .mob_conn_rejected = "You rejected the server fingerprint",
    .mob_conn_timeout = "The request timed out",
    .mob_conn_closed = "The server closed the connection",
    .mob_conn_ended = "Disconnected. You can reconnect from the list",
    .mob_conn_failed = "Could not connect",
    .mob_appearance = "Appearance",
    .ws_restore_incomplete = "The saved workspace was only partially restored — on quit the previous checkpoint is kept as workspace.v1.bak before saving.",
    .ws_checkpoint_capture_failed = "Workspace checkpoint capture failed",
    .status_session_not_persisted = "New terminals will not persist",
    .ws_checkpoint_write_failed = "Workspace checkpoint save failed",
    .grant_scope_storage = "read and write this site's cookies and storage (including login tokens)",
    .grant_scope_control = "control this browser (navigate, click, type, read)",
    .grant_prompt = "An agent wants to {0}. Target: {1}. Allow?",
    .pick_background_png = "Choose a PNG to use as the background",
    .pick_dock_file = "Choose a file to open in the dock (Markdown, HTML, SVG, text/code, images, media, PDF)",
    .pick_explorer_folder = "Choose a folder to open in the explorer",
    .pick_workspace_folder = "Choose a folder to add to the workspace",
    .scm_show_all_more = "Show all ({0} more)",
    .scm_load_more = "Load more commits",
    .scm_commit_placeholder = "Commit message…",
    .scm_commit = "Commit",
    .scm_committing = "Committing…",
    .scm_commit_slow = "The commit is taking a while",
    .editor_readonly = "Read-only",
    .editor_counting_rows = "Counting rows…",
    .scm_no_remote = "This repository has no remote",
    .scm_fetch_done = "Fetched from the remote",
    .scm_menu_push = "Type git push",
    .scm_menu_pull = "Type git pull",
    .scm_menu_pick_base = "Choose base branch…",
    .scm_base_default = "Default (origin/HEAD)",
    .scm_base_limit = "Too many repositories remembered, so the base branch was not changed",
    .scm_remote_read_only = "This is a remote session, so the list is read-only for now",
    .scm_no_terminal = "No terminal to type into",
    .scm_changes = "Changes",
    .scm_history = "History",
    .scm_staged = "Staged changes",
    .cfg_font_size = "Font size (pt)",
    .cfg_font_line_height = "Line height multiplier",
    .cfg_mob_font_line_height = "Line height (%, 100 = font size)",
    .cfg_font_letter_spacing = "Letter spacing (logical pt, negative allowed)",
    .cfg_font_family = "Font family (inner spaces preserved)",
    .cfg_font_fallback = "Fallback fonts (comma separated)",
    .cfg_font_family_bold = "Bold font family (empty = bold of main font)",
    .cfg_font_family_italic = "Italic font family (empty = italic of main font)",
    .cfg_font_ligatures = "Programming ligatures (=> != // etc.)",
    .cfg_theme_background = "Background color (#RRGGBB)",
    .cfg_theme_foreground = "Foreground color (#RRGGBB)",
    .cfg_theme_cursor = "Cursor color (#RRGGBB)",
    .cfg_theme_selection = "Selection highlight background (#RRGGBB)",
    .cfg_cursor_shape = "Cursor shape",
    .cfg_cursor_blink = "Cursor blink",
    .cfg_cursor_blink_interval_ms = "Cursor blink half-period (ms)",
    .cfg_cursor_blink_fade_ms = "Cursor blink fade (ms, 0 = instant)",
    .cfg_cursor_unfocused = "Cursor when unfocused",
    .cfg_input_page_keys = "PageUp/Down on the main screen",
    .cfg_input_shift_enter = "Shift+Enter encoding",
    .cfg_input_ime_enter = "Enter during IME composition",
    .cfg_input_url_click_modifier = "URL click modifier",
    .cfg_input_mouse_hide_while_typing = "Hide mouse while typing",
    .cfg_input_option_as_meta = "Option as Meta (Alt)",
    .cfg_input_right_click = "Terminal right-click action",
    .cfg_input_word_separators = "Double-click word separators",
    .cfg_input_link_detection = "Link auto-detection scope",
    .cfg_input_link_open_target = "Where to open web links",
    .cfg_input_paste_protection = "Confirm risky pastes",
    .cfg_input_bracketed_paste_is_safe = "Treat bracketed paste as safe",
    .cfg_input_selection_clear_on_typing = "Clear selection when typing",
    .cfg_keyhint_enabled = "Show shortcut hints while holding a modifier",
    .cfg_keyhint_delay = "Hold time before hints appear (ms)",
    .cfg_keyhint_modifier = "Modifier that raises hints (held alone)",
    .cfg_session_keep_alive_after_quit = "Keep terminal sessions alive after a normal GUI quit and reattach on relaunch (experimental, tmux-like)",
    .cfg_sidebar_show_branch = "Show git branch on sidebar cards",
    .cfg_sidebar_show_folder = "Show folder path on sidebar cards",
    .cfg_sidebar_agent_hooks = "Install provider hooks for agent state, notifications and turns",
    .image_gallery_no_agent = "No agent session in this pane",
    .image_gallery_empty = "No images in this session",
    .image_gallery_partial = "Could not read the whole session",
    .image_gallery_scanning = "Scanning…",
    .image_gallery_count_suffix = " images",
    .image_gallery_shown_of = "{0} of {1} images",
    .image_gallery_open_failed = "Could not open this image",
    .image_gallery_search_prompt = "Filter: ",
    .image_gallery_no_match = "No image matches",
    .agent_hook_notice_done = "Turn finished",
    .agent_hook_notice_failed = "Turn ended with an error",
    .agent_hook_notice_attention = "Waiting for your approval",
    .cfg_sidebar_width_pt = "Sidebar width (pt)",
    .cfg_editor_wrap = "Wrap long lines",
    .cfg_editor_tab_width = "Tab width (columns)",
    .cfg_editor_cursor_shape = "Caret shape",
    .cfg_statusbar_show = "Show the bottom status bar",
    .cfg_quick_height_fraction = "Thickness ratio (of the screen)",
    .cfg_quick_width_fraction = "Center width ratio (0 = follow height)",
    .cfg_quick_auto_hide = "Auto-hide when focus is lost",
    .cfg_quick_screen = "Which screen to show on",
    .cfg_quick_position = "Which edge to slide from",
    .cfg_quick_chrome = "Panel chrome level",
    .cfg_quick_minimal_tabs = "Allow tabs in minimal chrome",
    .cfg_ui_language = "UI language (auto = OS locale)",
    .cfg_chrome_tab_style = "Active tab look (connected|underline|pill)",
    .cfg_theme_follow_system = "Follow the system light/dark appearance",
    .cfg_theme_preset_light = "Light appearance preset",
    .cfg_theme_preset_dark = "Dark appearance preset",
    .cfg_text_blink = "Blink SGR 5 text",
    .cfg_text_ambiguous_width = "Width of EAW Ambiguous characters",
    .cfg_text_emoji_width = "Width of emoji (VS16, keycap)",
    .cfg_theme_bold_is_bright = "Render bold in bright colors",
    .cfg_theme_min_contrast = "Minimum ANSI palette contrast (0 = off, readability on light backgrounds)",
    .cfg_window_padding_top = "Top padding (pt)",
    .cfg_window_padding_right = "Right padding (pt)",
    .cfg_window_padding_bottom = "Bottom padding (pt)",
    .cfg_window_padding_left = "Left padding (pt)",
    .cfg_window_opacity = "Window background opacity (0-1)",
    .cfg_render_frame_rate = "App refresh rate (Hz)",
    .cfg_window_background_image = "Background image PNG path",
    .cfg_window_blur = "Blur radius behind the window (px, 0 = off, only when opacity < 1)",
    .cfg_window_unfocused_dim = "Dimming of inactive split panes (0-1)",
    .cfg_split_divider_thickness = "Split divider thickness (pt, 0 = hidden)",
    .cfg_term = "$TERM value",
    .cfg_filepanel_external_link_target = "Where the file panel opens external links",
    .cfg_shell_command = "Shell executable path (absolute, empty = automatic)",
    .cfg_shell_windows_shell = "Default Windows shell (when shell.command is empty)",
    .cfg_workspace_tab_inherit_cwd = "New tabs/terms inherit the focused cwd",
    .cfg_workspace_split_inherit_cwd = "New splits inherit the focused cwd",
    .cfg_workspace_hold_on_startup_failure = "Keep the window open if the shell exits abnormally right after start",
    .cfg_shellint_ssh = "Route plain ssh through maru ssh",
    .cfg_ssh_server_alive_interval = "maru ssh keepalive interval in seconds (0 leaves your ~/.ssh/config alone)",
    .cfg_ssh_server_alive_count_max = "How many unanswered maru ssh keepalives before the connection counts as dead",
    .cfg_ssh_reconnect = "Reconnect automatically when a maru ssh session drops (a reconnect starts a new remote shell)",
    .cfg_notif_osc = "OSC 9/777 desktop notifications",
    .cfg_notif_update_check = "Check for and announce new releases",
    .cfg_notif_history_limit = "Notification center history size",
    .cfg_scrollback_lines = "Scrollback lines to keep",
    .cfg_scrollback_sticky_command = "Pin the current command line to the top while scrolling (sticky)",
    .cfg_scroll_multiplier = "Wheel scroll multiplier",
    .cfg_osc52_read = "OSC 52 clipboard read",
    .cfg_bell_audible = "System sound on BEL",
    .cfg_bell_visual = "Screen flash on BEL",
    .cfg_bell_dock_badge = "Dock badge on BEL",
    .ctx_new_file = "New File\u{2026}",
    .ctx_new_folder = "New Folder\u{2026}",
    .ctx_rename = "Rename",
    .ctx_move_to_trash = "Move to Trash",
    .ctx_open_file = "Open File\u{2026}",
    .ctx_open_folder = "Open Folder\u{2026}",
    .ctx_add_folder_to_workspace = "Add Folder to Workspace\u{2026}",
    .ctx_remove_folder_from_workspace = "Remove Folder from Workspace",
    .ctx_group_create = "Group Selection",
    .ctx_group_sibling = "Split into Sibling Group",
    .ctx_group_ungroup = "Ungroup",
    .ctx_group_remove = "Remove from Group",
    .ctx_group_promote = "Promote to Top Level",
    .ctx_copy = "Copy",
    .ctx_paste = "Paste",
    .ctx_group_unpin = "Unpin Group",
    .ctx_group_pin = "Pin Group",
    .ctx_local_unpin = "Unpin in Group",
    .ctx_local_pin = "Pin in Group",
    .ctx_unpin = "Unpin",
    .ctx_pin = "Pin",
};

const ko: Table = .{
    .fp_root_stale_generation = "탐색기 루트가 바뀌어 폴더 선택 결과를 취소했습니다.",
    .fp_root_open_failed = "선택한 폴더를 열 수 없습니다.",
    .fp_root_identity_unknown = "선택한 폴더 identity를 확인할 수 없습니다.",
    .fp_root_revalidate_alloc_failed = "폴더 재검증 상태를 준비할 수 없습니다.",
    .fp_root_revalidate_start_failed = "폴더 재검증 작업을 시작하지 못했습니다.",
    .fp_root_revalidate_invalid = "폴더 재검증 상태가 유효하지 않습니다.",
    .fp_root_identity_gone = "폴더 identity가 사라져 변경을 취소했습니다.",
    .fp_root_capability_gone = "폴더 검증 capability가 사라져 변경을 취소했습니다.",
    .fp_root_identity_changed = "선택한 폴더가 검증 중 교체되어 변경을 취소했습니다.",
    .fp_root_change_alloc_failed = "탐색기 루트 변경 상태를 준비할 수 없습니다.",
    .fp_root_replace_failed = "탐색기 루트를 교체할 수 없습니다.",
    .fp_root_add_failed = "작업공간에 폴더를 추가할 수 없습니다.",
    .fp_root_watch_change_failed = "폴더 감시를 갱신할 수 없어 루트 변경을 취소했습니다.",
    .fp_root_rows_change_failed = "탐색기 행 상태를 준비할 수 없어 루트 변경을 취소했습니다.",
    .fp_root_first_scan_alloc_failed = "검증된 탐색기 루트의 첫 scan을 준비할 수 없습니다.",
    .fp_root_scan_start_failed = "검증된 폴더 scan을 시작하지 못해 변경을 취소했습니다.",
    .fp_root_busy_retry = "파일 변경 또는 폴더 선택이 끝난 뒤 다시 시도하세요.",
    .fp_root_remove_alloc_failed = "탐색기 루트 제거 상태를 준비할 수 없습니다.",
    .fp_root_remove_failed = "탐색기 루트를 제거할 수 없습니다.",
    .fp_root_missing = "선택한 탐색기 루트가 더 이상 존재하지 않습니다.",
    .fp_root_watch_remove_failed = "폴더 감시를 갱신할 수 없어 루트 제거를 취소했습니다.",
    .fp_root_rows_remove_failed = "탐색기 행 상태를 준비할 수 없어 루트 제거를 취소했습니다.",
    .fp_root_invalid_path = "선택한 폴더 경로가 올바르지 않습니다.",
    .fp_root_request_id_exhausted = "폴더 선택 요청 번호를 더 발급할 수 없습니다.",
    .fp_root_picker_alloc_failed = "폴더 선택 상태를 준비할 수 없습니다.",
    .fp_root_validate_busy = "폴더 검증 작업이 바빠 요청을 시작하지 못했습니다.",

    .set_global_key_not_allowed = "이 키는 전역 단축키로 등록할 수 없습니다",
    .set_global_chord_taken = "이 전역 단축키는 이미 다른 동작에 묶여 있습니다 — 덮어씁니다",
    .set_no_chord_assigned = "이미 지정된 단축키가 없습니다",
    .set_no_global_chord_assigned = "이미 지정된 전역 단축키가 없습니다",
    .set_env_format = "환경 변수는 KEY=VALUE 형식이어야 합니다",
    .set_env_key_empty = "환경 변수 KEY가 비어 있습니다",
    .set_chord_parse_failed = "단축키 표기를 읽지 못했습니다",
    .set_macro_format = "매크로는 text:/esc:/ctrl: 형식이어야 합니다",
    .set_chord_conflict = "다른 단축키와 충돌해 적용하지 못했습니다",
    .set_macro_overrides_default = "기본 단축키를 매크로가 덮어씁니다",
    .set_macro_line_format = "매크로는 'chord = text:...' 형식이어야 합니다",
    .set_chord_empty = "단축키가 비어 있습니다",
    .set_chord_taken_by = "이 단축키는 '{0}'에 이미 묶여 있습니다 — 덮어씁니다",

    .git_branch_list_failed = "브랜치 목록을 읽지 못했습니다",
    .git_path_outside_repo = "저장소 밖을 가리키는 경로는 열지 않습니다",
    .git_submodule_no_diff = "하위 모듈은 비교를 표시하지 않습니다",
    .ws_move_target_has_file = "대상 창에 같은 파일이 이미 열려 있어 워크스페이스를 옮기지 못했습니다.",
    .ws_move_target_tabs_full = "대상 창의 파일 탭이 너무 많아 워크스페이스를 옮기지 못했습니다.",
    .ad_session_list_apply_failed = "새 세션 목록을 적용하지 못해 기존 목록을 유지했습니다.",
    .ad_workspace_path_missing = "활성 작업공간의 로컬 경로를 찾을 수 없습니다.",
    .ad_terminal_git_project_missing = "현재 터미널의 로컬 git 프로젝트를 찾을 수 없습니다.",
    .ad_path_scan_start_failed = "작업공간 경로 분석을 시작하지 못했습니다.",
    .ad_path_scan_restart_failed = "작업공간 경로 분석을 다시 시작하지 못했습니다.",
    .ad_session_archive_open_failed = "세션 기록을 열지 못했습니다.",
    .ad_session_resume_failed = "세션을 다시 시작하지 못했습니다. Claude 또는 Codex CLI 설치와 작업 경로를 확인하세요.",
    .ad_log_source_changed = "로그 원본이 변경되었거나 더 이상 열 수 없습니다.",
    .ad_open_session_not_found = "현재 열린 동일 세션을 찾지 못했습니다.",

    .app_attach_observer_mode = "다른 창이 이 세션을 제어 중이라 관찰 모드로 연결했습니다. 화면은 갱신되지만 입력은 전달되지 않습니다.",
    .common_unsaved_tabs_first = "저장하지 않은 파일 탭을 먼저 저장하거나 닫아 주세요.",
    .app_cli_install_path_missing = "CLI 설치 실패: maru CLI 경로를 찾지 못했습니다",
    .app_cli_install_binary_missing = "CLI 설치 실패: maru CLI 바이너리를 찾지 못했습니다",
    .app_cli_install_no_home = "CLI 설치 실패: $HOME가 없습니다",
    .app_cli_install_symlink_failed = "CLI 설치 실패: symlink를 만들 수 없습니다",
    .app_shell_restart_failed = "셸 재시작에 실패했습니다 — 설정(⌘,)을 확인하세요.",
    .app_shell_start_failed = "셸을 시작하지 못했습니다 — 설정(⌘,)에서 shell.command·shell.args를 확인하세요.",
    .app_file_send_sync_failed = "세션 정보를 동기화하지 못했습니다. 파일 전송을 다시 시도해주세요.",
    .app_file_send_prepare_failed = "원격 파일 전송을 준비하지 못했습니다. 로컬 경로를 붙여넣지 않았습니다.",
    .app_file_send_start_failed = "원격 파일 전송을 시작하지 못했습니다. 파일 크기와 접근 권한을 확인해주세요.",
    .app_file_send_failed = "원격 파일 전송에 실패했습니다. SSH 연결을 확인한 뒤 다시 시도해주세요.",
    .app_image_send_sync_failed = "세션 정보를 동기화하지 못했습니다. 이미지 전송을 다시 시도해주세요.",
    .app_image_send_too_large = "원격 이미지 전송 한도는 16MB입니다. 로컬 붙여넣기로 전환하지 않았습니다.",
    .app_image_send_prepare_failed = "원격 이미지 전송을 준비하지 못했습니다. 로컬 붙여넣기로 전환하지 않았습니다.",
    .app_image_send_oom = "원격 이미지 전송을 준비할 메모리가 부족합니다. 로컬 붙여넣기로 전환하지 않았습니다.",
    .app_image_send_start_failed = "원격 이미지 전송을 시작하지 못했습니다. 로컬 붙여넣기로 전환하지 않았습니다.",
    .app_image_send_failed = "원격 이미지 전송에 실패했습니다. SSH 연결을 확인한 뒤 다시 시도해주세요. 로컬 붙여넣기로 전환하지 않았습니다.",
    .app_no_measured_terminal = "아직 측정된 터미널이 없습니다",
    .set_git_backend_start_failed = "git 백엔드를 시작하지 못했습니다",
    .set_git_not_found = "git을 찾지 못했습니다",
    .set_no_branches = "브랜치가 없습니다",
    .set_branch_name_invalid = "브랜치 이름을 명령으로 만들 수 없습니다",
    .set_link_open_failed = "링크를 열지 못했습니다.",
    .set_root_changed_cancel = "탐색기 루트가 바뀌어 명령을 취소했습니다.",
    .set_selection_changed_cancel = "선택한 항목이 변경되어 명령을 취소했습니다.",
    .set_reset_write_failed = "기본값으로 초기화(화면은 적용됨) — config 파일 쓰기에 실패했습니다",
    .set_reset_done_keepalive = "모든 설정을 기본값으로 초기화했습니다 — 세션 유지(keep-alive)는 살아 있는 터미널을 지키려 그대로 뒀습니다. 끄려면 세팅 › workspace에서 직접 변경하세요",
    .set_keepalive_reset_preserved = "세션 유지(keep-alive)는 살아 있는 터미널을 지키기 위해 그대로 뒀습니다. 세팅 › workspace에서 직접 변경하세요",
    .set_reset_done = "모든 설정을 기본값으로 초기화했습니다",

    .fp_view_rebuild_failed = "파일 뷰를 다시 만들 수 없어 이전 보기를 유지했습니다.",
    .fp_mutation_in_progress = "이전 파일 변경이 끝날 때까지 기다려 주세요.",
    .fp_select_first = "프로젝트 파일 또는 폴더를 먼저 선택해 주세요.",
    .fp_root_rename_denied = "프로젝트 루트 자체는 이름을 바꿀 수 없습니다.",
    .fp_symlink_dir_create_denied = "심볼릭 링크 폴더 안에는 항목을 만들 수 없습니다.",
    .fp_path_too_long = "경로가 너무 길어 변경할 수 없습니다.",
    .fp_dir_changed_reopen = "탐색기 폴더가 다른 디렉터리로 바뀌어 갱신을 중단했습니다. 폴더를 다시 여세요.",
    .fp_trash_in_progress = "이전 휴지통 이동이 끝날 때까지 기다려 주세요.",
    .fp_trash_queue_full = "휴지통 요청 큐가 가득 찼습니다. 이전 작업이 끝난 뒤 다시 시도해 주세요.",
    .fp_select_to_delete = "삭제할 프로젝트 파일 또는 폴더를 먼저 선택해 주세요.",
    .fp_root_delete_denied = "프로젝트 루트 자체는 삭제할 수 없습니다.",
    .fp_symlink_alias_delete_blocked = "같은 프로젝트의 편집 중 파일이 symlink alias일 수 있어 폴더 삭제를 차단했습니다.",
    .fp_tab_state_changed_close_cancel = "파일 탭 상태가 바뀌어 닫기를 취소했습니다.",
    .fp_file_tab_only = "파일 탭에서만 쓸 수 있습니다.",
    .fp_outside_root_denied = "프로젝트 루트 밖의 항목은 변경할 수 없습니다.",
    .fp_symlink_alias_rename_blocked = "같은 프로젝트의 편집 중 파일이 symlink alias일 수 있어 폴더 이름 변경을 차단했습니다.",
    .fp_identity_not_ready = "파일 identity가 아직 준비되지 않았습니다. 트리 새로고침 뒤 다시 시도해 주세요.",
    .fp_mutation_queue_full = "파일 변경 요청 큐가 가득 찼습니다. 잠시 후 다시 시도해 주세요.",
    .fp_mutation_id_exhausted = "파일 변경 요청 번호를 더 발급할 수 없습니다.",
    .fp_mutation_prepare_failed = "파일 변경 요청을 준비할 수 없습니다.",
    .fp_rename_plan_failed = "이름 변경 경로 계획을 준비할 수 없습니다.",
    .fp_entry_busy = "다른 파일 변경이 같은 항목을 사용 중입니다.",
    .fp_editor_lock_rename_failed = "편집기를 잠글 수 없어 이름 변경을 시작하지 않았습니다.",
    .fp_trash_verify_failed = "휴지통 이동 결과를 검증할 수 없습니다. 휴지통을 확인하세요. 정상 종료와 파일 변경을 차단했습니다.",
    .fp_root_changed_delete_cancel = "탐색기 루트가 바뀌어 삭제를 취소했습니다.",
    .fp_state_changed_dir_delete_cancel = "상태가 바뀌어 폴더 삭제를 취소했습니다.",
    .fp_state_changed_delete_cancel = "상태가 바뀌어 삭제를 취소했습니다.",
    .fp_delete_recovery_prepare_failed = "삭제 복구 경로를 준비할 수 없어 시작하지 않았습니다.",
    .fp_editor_lock_trash_failed = "편집기를 잠글 수 없어 휴지통 이동을 시작하지 않았습니다.",
    .fp_edit_state_changed_rename_cancel = "편집 상태가 바뀌어 이름 변경을 취소했습니다.",
    .fp_edit_state_changed_trash_cancel = "편집 상태가 바뀌어 휴지통 이동을 취소했습니다.",
    .fp_trash_adapter_queue_full = "휴지통 어댑터 큐가 가득 차 원래 위치로 복원합니다.",
    .fp_trash_failed_restored = "휴지통 이동에 실패해 원래 위치로 복원했습니다.",
    .fp_close_after_mutation = "파일 변경이 끝난 뒤 탭을 닫을 수 있습니다.",
    .fp_close_id_exhausted = "파일 닫기 요청 번호를 더 발급할 수 없어 탭을 닫지 않았습니다.",
    .fp_close_prepare_failed = "파일 닫기 상태를 준비할 수 없어 탭을 닫지 않았습니다.",
    .fp_nothing_to_focus = "파일 패널에 포커스할 내용이 없습니다.",
    .fp_trash_done_tab_kept = "휴지통 이동은 완료됐지만 편집 상태가 바뀌어 열린 탭은 유지합니다.",
    .fp_edit_state_recheck_failed = "편집 상태를 다시 확인할 수 없어 파일 탭을 보호했습니다.",
    .fp_save_failed_tab_kept = "파일을 저장할 수 없어 탭을 닫지 않았습니다.",
    .fp_post_save_check_failed = "저장 후 편집 상태를 확인할 수 없어 탭을 닫지 않았습니다.",
    .fp_web_content_restarted = "편집 중 웹 콘텐츠가 다시 시작되어 자동 복구 전까지 파일 작업을 차단했습니다.",
    .fp_web_content_terminated = "편집 중 웹 콘텐츠가 종료되어 자동 복구 전까지 파일 작업을 차단했습니다.",
    .fp_edit_state_check_failed = "편집 상태를 확인할 수 없어 탭을 닫지 않았습니다.",

    .term_clipboard_too_large = "클립보드 복사가 너무 커서 취소되었습니다(최대 약 {0}MB).",
    .term_remote_clipboard_too_large = "원격 세션의 클립보드 복사가 너무 커서 전달되지 않았습니다(최대 약 {0}KB).",

    .app_host_connect_failed = "영속 세션 host에 연결하지 못했습니다({0}). 이번 세션의 터미널은 유지되지 않습니다(종료 시 함께 종료).",
    .app_session_host_upgrade_result = "영속 세션 host 업데이트 결과: {0}",
    .app_agent_hook_trust_diverged = "codex에 저장된 승인 값이 maru가 계산한 값과 다릅니다(훅 {0}개). codex에서 승인하셨다면 정상 동작 중이며 하실 일이 없습니다. 그게 아니라면 codex를 한 번 실행해 훅 검토를 다시 묻는지 확인하세요.",
    .app_agent_hook_trust_refreshed = "낡아 있던 maru 훅 {0}개의 codex 승인을 갱신했습니다. 다음 codex 실행부터 다시 동작합니다.",
    .app_agent_hook_trust_stale = "codex가 maru 훅 {0}개를 승인하지 않아 실행되지 않습니다 — 에이전트 상태를 화면 관측으로 대신합니다. codex를 한 번 실행해 \"Trust all and continue\"를 고르세요.",
    .app_ended_placeholder = "이전 세션 {0}개가 이미 종료돼 해당 자리는 비어 있습니다 — 레이아웃은 복원했습니다.",
    .app_recovered_session_failed = "이 세션을 복구하지 못했습니다. 세션 목록을 새로 고친 뒤 다시 시도하세요.",
    .app_shell_died_startup = "셸이 시작 직후 비정상 종료됐습니다 ({0}). ⏎ 다시 시도 · ⌘, 설정에서 shell.command·shell.args 확인.",
    .app_save_external_conflict = "파일이 외부에서 바뀌어 저장할 수 없습니다. 파일을 다시 불러온 뒤 저장하세요.",
    .app_save_too_large = "파일이 너무 커서 저장할 수 없습니다.",
    .app_save_failed = "파일을 저장할 수 없습니다.",
    .app_cli_installed = "maru CLI 설치됨: {0}",
    .app_cli_installed_path_hint = "maru CLI 설치됨: {0} — PATH에 {1} 추가 필요(예: ~/.zshrc)",
    .app_upload_done_pane_closed = "업로드 완료(드롭한 pane이 닫힘): {0}",
    .fp_delete_protected = "저장되지 않았거나 동기화·충돌 처리 중인 파일을 포함해 삭제할 수 없습니다.",
    .fp_delete_denied = "이 항목은 삭제할 수 없습니다.",
    .fp_name_invalid = "이름은 비어 있거나 '.', '..'일 수 없고 '/'를 포함할 수 없습니다.",
    .fp_change_protected = "저장되지 않았거나 동기화·충돌 처리 중인 파일을 포함해 변경할 수 없습니다.",
    .fp_name_unchanged = "같은 이름입니다.",
    .fp_change_denied = "이 항목은 변경할 수 없습니다.",
    .fp_mutation_collision = "같은 이름의 항목이 이미 있습니다.",
    .fp_mutation_not_found = "대상이 사라져 파일 변경을 완료하지 못했습니다.",
    .fp_mutation_denied = "권한이 없어 파일을 변경할 수 없습니다.",
    .fp_mutation_failed = "파일 변경에 실패했습니다. 트리와 열린 탭은 유지됩니다.",
    .fp_manual_recovery = "수동 복구가 필요합니다. 이 경로의 파일을 확인하세요: {0}",
    .fp_manual_recovery_fallback = "수동 복구가 필요합니다. 로그의 recovery 경로에서 파일을 확인하세요.",
    .fp_abort_unsaved = "저장되지 않은 편집 내용이 있어 파일 변경을 취소했습니다.",
    .fp_abort_edit_check = "편집 상태를 확인할 수 없어 파일 변경을 취소했습니다.",
    .dbg_editor_not_utf8 = "네이티브 편집기: UTF-8이 아니라 열지 않았습니다.",
    .symbol_picker_empty = "이 파일에는 갈 심볼이 없습니다.",
    .symbol_picker_top_level = "최상위",
    .dbg_editor_too_large = "네이티브 편집기: 파일이 읽기 상한을 넘었습니다.",
    .dbg_editor_unreadable = "네이티브 편집기: 파일을 읽지 못했습니다.",
    .dbg_editor_oom = "네이티브 편집기: 메모리가 모자랍니다.",

    .common_confirm = "확인",
    .common_cancel = "취소",
    .btn_quit = "종료",
    .btn_quit_end_session = "종료 및 세션 끝내기",
    .btn_reset = "초기화",
    .btn_reload = "다시 읽기",
    .btn_move_to_trash = "휴지통으로 이동",
    .btn_discard_changes = "변경사항 버리기",
    .btn_save = "저장",
    .btn_paste = "붙여넣기",
    .btn_close = "닫기",
    .btn_allow = "허용",
    .btn_deny = "거부",
    .app_quit_confirm_keepalive = "maru를 종료할까요? 열린 터미널은 백그라운드에서 유지됩니다.",
    .app_quit_confirm = "maru를 종료할까요?",
    .app_reset_confirm = "모든 설정을 기본값으로 되돌리고 config 파일을 덮어씁니다. 계속할까요?",
    .app_reload_external_confirm = "외부에서 파일이 변경되었습니다. 편집 중인 내용을 버리고 디스크에서 다시 읽을까요?",
    .fp_trash_confirm = "선택한 항목을 macOS 휴지통으로 이동할까요?",
    .fp_close_external_confirm = "디스크에서 변경된 파일입니다. 변경사항을 버리고 닫을까요?",
    .fp_unsaved_confirm = "저장하지 않은 변경사항이 있습니다.",
    .term_paste_confirm = "붙여넣을 내용에 줄바꿈이나 제어 문자가 있어 명령이 바로 실행될 수 있습니다. 붙여넣을까요?",
    .app_close_running = "실행 중인 명령이 있습니다. 닫을까요?",
    .app_close_window_running = "실행 중인 명령이 있습니다. 이 창을 닫을까요?",
    .app_close_browser = "열린 브라우저 탭이 있습니다. 닫을까요?",
    .app_close_unsaved = "저장하지 않은 편집이 있습니다. 닫을까요?",
    .app_close_window_browser = "열린 브라우저 탭이 있습니다. 이 창을 닫을까요?",
    .app_close_window_unsaved = "저장하지 않은 편집이 있습니다. 이 창을 닫을까요?",
    .set_section_app = "앱",
    .set_section_font = "폰트",
    .set_section_theme = "테마",
    .set_section_cursor = "커서",
    .set_section_window = "창",
    .set_section_input = "입력",
    .set_section_terminal = "터미널",
    .set_section_workspace = "워크스페이스",
    .set_section_quick_terminal = "퀵 터미널",
    .set_section_sidebar = "사이드바",
    .set_section_global_hotkey = "글로벌 핫키",
    .set_section_editor = "편집기",
    .set_section_other = "기타",
    .set_language_auto = "자동 (OS 언어)",
    .notif_heading = "알림",
    .notif_empty_heading = "아직 알림이 없습니다",
    .notif_empty_subtext = "데스크톱 알림이 여기에 표시됩니다.",
    .notif_empty_title = "(제목 없음)",
    .notif_mark_all = "모두 읽음",
    .notif_clear_all = "모두 지우기",
    .sd_host_local = "로컬",
    .sd_count_analyzing = "{0}개 표시 · 분석 중",
    .sd_count_partial = "{0}개 표시 · 일부만 분석함",
    .sd_count = "{0}개 표시",
    .sd_header = "Agent 세션 기록",
    .sd_scope_workspace = "작업공간",
    .sd_scope_project = "프로젝트",
    .sd_scope_all = "전체",
    .sd_search = "세션 검색",
    .common_session_analyzing = "세션 분석 중",
    .common_recent_conversation = "최근 대화",
    .sd_detail_stale = "세션 원본이 변경되었습니다",
    .common_session_unavailable = "세션을 열 수 없습니다",
    .common_action_records = "도구/권한 관련 기록 {0}건",
    .common_role_user = "사용자",
    .common_role_assistant = "에이전트",
    .sd_stale_hint = "안전하게 재개하거나 로그를 열 수 없습니다.",
    .sd_unavailable_hint = "원본을 읽을 수 없습니다.",
    .sd_resume = "터미널에서 이어하기",
    .sd_reveal = "로그 보기",
    .sd_sort_newest = "최신순",
    .sd_sort_oldest = "오래된순",
    .ad_detail_aborted = "세션 분석을 중단했습니다",
    .ad_summary_subtitle = "최근 대화와 동작 요약",
    .ad_stale_badge = "원본 변경 감지",
    .ad_unavailable_badge = "원본을 읽을 수 없음",
    .ad_stale_body = "원본 세션이 변경되어 안전하게 표시하지 않습니다.",
    .ad_unavailable_body = "세션 원본을 읽을 수 없습니다.",
    .common_focus_live = "열린 세션으로 이동",
    .scm_loading = "읽는 중…",
    .scm_load_failed = "읽지 못함",
    .ctx_cut = "잘라내기",
    .ctx_select_all = "전체 선택",
    .ctx_send_selection = "선택 영역 보내기",
    .ctx_send_selection_truncated = " ({0}/{1} 표시)",
    .ctx_send_selection_primary_only = " — 주 선택만",
    .ctx_target_shell = "셸",
    .ctx_open_link = "링크 열기",
    .ctx_copy_link = "주소 복사",
    .ctx_save_image = "이미지 저장",
    .ctx_copy_path = "경로 복사",
    .ctx_open_source_mode = "소스 모드로 열기",
    .dock_read = "읽기",
    .dock_rich = "리치",
    .dock_source = "소스",
    .dock_staged = "스테이지됨",
    .dock_worktree = "작업트리",
    .dock_new_file = "새 파일",
    .dock_commit = "커밋",
    .dock_turn = "턴",
    .dock_conflict = "충돌",
    .arch_untitled = "제목 없는 세션",
    .arch_unknown_location = "알 수 없는 위치",
    .res_memory = "메모리",
    .scm_output_truncated = "git 출력이 너무 커서 목록이 잘렸습니다",
    .ad_time_now = "방금",
    .ad_time_minutes = "{0}분 전",
    .ad_time_hours = "{0}시간 전",
    .ad_time_days = "{0}일 전",
    .ad_time_months = "{0}개월 전",
    .ad_time_years = "{0}년 전",
    .scm_log_read_failed = "커밋을 읽지 못했습니다",
    .scm_no_commits = "커밋이 없습니다",
    .scm_list_truncated = "출력이 너무 커서 목록이 잘렸습니다",
    .scm_commit_files_failed = "이 커밋의 파일을 읽지 못했습니다",
    .scm_commit_files_truncated = "이 커밋의 파일 목록이 잘렸습니다",
    .scm_commit_no_files = "이 커밋이 바꾼 파일이 없습니다",
    .scm_no_turns = "이번 실행에서 관측한 에이전트 턴이 없습니다",
    .scm_turns_need_hooks = "에이전트 훅을 켜야 턴이 기록됩니다",
    .scm_turns_missed = "기록하지 못한 턴 {0}개",
    .scm_turns_evicted = "최근 세션에 밀려 이전 턴 기록이 사라졌습니다",
    .scm_turn_live = "마지막 턴 이후",
    .scm_turn_last = "마지막 턴",
    .scm_turn_back_suffix = "턴 전",
    .scm_turn_file_count = "{0}개 파일",
    .scm_turn_edited_count = "✎ AI 편집 {0}",
    .scm_turn_shell_notice = "⚠ 셸 명령 {0}개 — 그 편집은 에이전트 소행으로 확정할 수 없습니다",
    .scm_turn_files_failed = "이 턴의 파일을 읽지 못했습니다",
    .scm_turn_no_files = "이 턴이 바꾼 파일이 없습니다",
    .ad_no_model = "모델 정보 없음",
    .ad_meta_messages = "메시지 {0}개",
    .ad_meta_subagents = "서브에이전트 {0}",
    .ad_meta_subagents_more = "서브에이전트 {0}+",
    .ctx_group_pin_header = "그룹 고정",
    .set_ansi_palette = "ANSI 팔레트",
    .set_syntax_color = "구문 색",
    .set_reset_named = "{0} 초기화",
    .set_theme_preset = "테마 프리셋",
    .set_custom = "사용자 지정",
    .set_shell_args_ph = "셸 인자 (공백 구분)",
    .set_env_ph = "환경 변수 추가 (KEY=VALUE)",
    .set_macro_ph = "터미널 매크로 추가 (chord = text:...)",
    .set_cwd_ph = "시작 디렉터리 (절대경로 또는 ~, 빈 값=상속)",
    .set_shell_not_found = "셸 실행 파일을 찾을 수 없어 기본 셸로 실행됩니다 (실행 파일 절대경로 필요 · 시작 위치는 이 필드가 아님)",
    .app_last_activity = "마지막 활동",
    .app_shared_all_windows = "Maru(앱 · 모든 창 공유)",
    .app_session_host_shared = "세션 호스트(모든 창 공유)",
    .app_editor = "편집기",
    .set_direct_input = "직접 입력\u{2026}",
    .app_more_lines = "\u{2026} {0}줄 더",
    .upd_available_ver = "새 버전 {0} 사용 가능",
    .upd_github = "GitHub 릴리스에서 최신 버전을 받으세요",
    .upd_brew = "brew upgrade maru 로 업데이트하세요",
    .st_blocked = "막힘",
    .st_running = "실행 중",
    .app_count_items = "{0}개",
    .col_name = "이름",
    .col_resource = "리소스",
    .app_closed_tab = "(닫힌 탭)",
    .exit_immediate = "즉시 종료",
    .exit_code = "종료 코드 {0}",
    .exit_signal = "시그널 {0}",
    .exit_abnormal = "비정상 종료",
    .exit_read_error = "읽기 오류",
    .cmd_toggle_window = "창 토글",
    .cmd_show_window = "창 표시",
    .cmd_toggle_quick = "퀵 터미널 토글",
    .fp_no_branch = "(브랜치 없음)",
    .fp_recent_files = "최근 파일",
    .fp_open_to_show_tree = "파일을 열면 트리가 표시됩니다",
    .diff_loading = "비교를 읽는 중입니다\u{2026}",
    .diff_no_changes = "바뀐 곳이 없습니다.",
    .diff_too_large = "변경이 너무 커서 비교를 표시하지 않습니다.",
    .diff_not_text = "텍스트가 아니라 비교를 표시하지 않습니다.",
    .diff_read_failed = "비교를 읽지 못했습니다.",
    .diff_ready = "비교 준비됨",
    .git_not_a_repo = "git 저장소가 아닙니다",
    .git_repo_unknown = "저장소를 확인할 수 없습니다",
    .git_no_changes = "변경 사항 없음",
    .git_not_installed = "git이 설치되어 있지 않습니다",
    .git_read_failed = "git 읽기에 실패했습니다",
    .scm_repo_unread = "그 저장소를 아직 읽지 못했습니다",
    .scm_nothing_to_stage = "스테이지할 변경이 없습니다",
    .scm_git_spawn_failed = "git을 실행하지 못했습니다",
    .scm_git_command_failed = "git 명령이 실패했습니다",
    .scm_need_commit_message = "커밋 메시지를 입력하세요",
    .scm_nothing_staged = "스테이지된 변경이 없습니다",
    .scm_commit_msg_write_failed = "커밋 메시지를 임시 파일에 쓰지 못했습니다",
    .sb_in_progress = "진행중",
    .sb_awaiting_input = "입력 대기",
    .sb_agent_idle = "대기중",
    .sb_agent_unknown = "상태 확인 중",
    .set_nav_hint = "← 섹션 · → 설정 · ↑↓ 이동 · ⏎ 선택",
    .set_search_hint = "/ 검색",
    .set_search_prompt = "검색: ",
    .set_color_pick_help = "←→ 채도  ↑↓ 명도  [ ] 색상  ⇧ 미세  # hex  i 스포이드  Enter 확정  Esc 취소",
    .set_color_pick_title = "HSV 색 선택",
    .set_color_hex_prompt = "hex 입력",
    .set_key_recording = "키 입력 대기…",
    .set_key_unset = "(미지정)",
    .sb_group = "그룹",
    .tab_group_n = "그룹 {0}",
    .ws_cwd_must_be_absolute = "시작 디렉터리는 절대경로 또는 ~/… 여야 합니다 (상대경로·~user 무시)",
    .arch_redacted = "[민감한 내용은 표시하지 않음]",
    .ad_resume_action = "터미널에서 이어하기",
    .ad_reveal_action = "로그 보기",
    .set_show_branch = "브랜치 표시",
    .set_show_folder = "폴더 표시",
    .mob_sessions = "세션",
    .mob_settings = "설정",
    .mob_servers = "서버",
    .mob_servers_empty = "등록된 서버가 없습니다",
    .mob_sessions_loading = "세션 목록을 불러오는 중...",
    .mob_sessions_none = "실행 중인 세션이 없습니다",
    .mob_control_off_timeout = "서버가 응답하지 않습니다. maru가 실행 중인지 확인해 주세요",
    .mob_control_off_noise = "예상과 다른 응답이 왔습니다. 서버가 지정된 명령만 허용하는 것 같습니다",
    .mob_control_off_protocol = "서버의 maru 버전이 호환되지 않습니다. 업데이트가 필요합니다",
    .mob_control_off_frame = "응답이 너무 큽니다",
    .mob_control_off_open = "세션 목록을 열지 못했습니다. 터미널은 그대로 사용할 수 있습니다",
    .mob_control_off_missing = "서버에서 maru를 찾을 수 없습니다. 서버 설정에서 경로를 지정해 주세요",
    .mob_control_off_failed = "서버의 maru가 즉시 종료되었습니다",
    .mob_remote_screen_title = "세션",
    .mob_remote_screen_readonly = "보는 중",
    .mob_remote_screen_waiting = "화면을 받는 중입니다",
    .mob_remote_screen_off = "화면이 끊겼습니다. 나갔다 다시 열어 주세요.",
    .mob_server_incomplete = "주소와 사용자를 입력해야 연결할 수 있습니다",
    .mob_server_first_connect = "처음 연결하는 서버입니다. 지문 확인을 거칩니다",
    .mob_server_add = "서버 추가",
    .mob_server_edit = "서버 편집",
    .mob_server_name = "이름",
    .mob_server_host = "주소",
    .mob_server_port = "포트",
    .mob_server_user = "사용자",
    .mob_server_fingerprint = "지문(SHA256:...)",
    .mob_server_save = "저장",
    .mob_server_delete = "삭제",
    .mob_server_edit_short = "편집",
    .mob_pubkey = "이 기기의 공개키",
    .mob_pubkey_copied = "복사했습니다. authorized_keys에 붙여 넣으세요",
    .mob_pubkey_absent = "아직 키가 없습니다",
    .mob_password_title = "비밀번호",
    .mob_password_hint = "서버가 비밀번호를 요구합니다. 저장하지 않습니다.",
    .mob_password_empty = "비밀번호를 입력하세요",
    .mob_password_ok = "접속",
    .mob_password_cancel = "취소",
    .mob_copy = "복사",
    .mob_keyboard = "자판",
    .mob_disconnect = "끊기",
    .mob_hostkey_title = "처음 연결하는 서버",
    .mob_hostkey_hint = "이 지문이 서버의 것과 같은지 확인해 주세요. 승인하면 저장됩니다.",
    .mob_hostkey_ok = "지문이 일치합니다 — 연결",
    .mob_hostkey_cancel = "취소",
    .mob_conn_connecting = "연결 중...",
    .mob_conn_ready = "연결됨",
    .mob_conn_unreachable = "서버에 연결할 수 없습니다. 주소와 포트를 확인해 주세요",
    .mob_conn_auth = "인증에 실패했습니다",
    .mob_conn_hostkey = "서버 키가 일치하지 않아 연결을 중단했습니다",
    .mob_conn_rejected = "서버 지문을 거부했습니다",
    .mob_conn_timeout = "응답 시간이 초과되었습니다",
    .mob_conn_closed = "서버에서 연결을 종료했습니다",
    .mob_conn_ended = "연결을 종료했습니다. 목록에서 다시 연결할 수 있습니다",
    .mob_conn_failed = "연결하지 못했습니다",
    .mob_appearance = "모양",
    .ws_restore_incomplete = "저장된 작업 공간을 일부만 복원했습니다 — 종료 시 이전 체크포인트를 workspace.v1.bak으로 남기고 저장합니다.",
    .ws_checkpoint_capture_failed = "작업 공간 체크포인트 캡처에 실패했습니다",
    .status_session_not_persisted = "새 터미널이 유지되지 않습니다",
    .ws_checkpoint_write_failed = "작업 공간 체크포인트 저장에 실패했습니다",
    .grant_scope_storage = "이 사이트의 쿠키·스토리지(로그인 토큰 포함)를 읽고 쓰려",
    .grant_scope_control = "이 브라우저(이동·클릭·입력·읽기)를 제어하려",
    .grant_prompt = "에이전트가 {0} 합니다. 대상: {1}. 허용하시겠습니까?",
    .pick_background_png = "배경 이미지로 쓸 PNG를 고르세요",
    .pick_dock_file = "도크에서 열 파일을 고르세요 (Markdown·HTML·SVG·텍스트/코드·이미지·미디어·PDF)",
    .pick_explorer_folder = "탐색기에서 열 폴더를 고르세요",
    .pick_workspace_folder = "작업공간에 추가할 폴더를 고르세요",
    .scm_show_all_more = "모두 보기 ({0}개 더)",
    .scm_load_more = "커밋 더 보기",
    .scm_commit_placeholder = "커밋 메시지…",
    .scm_commit = "커밋",
    .scm_committing = "커밋 중…",
    .scm_commit_slow = "커밋이 오래 걸리는 중",
    .editor_readonly = "읽기 전용",
    .editor_counting_rows = "행 수 세는 중…",
    .scm_no_remote = "이 저장소에는 원격이 없습니다",
    .scm_fetch_done = "원격에서 가져왔습니다",
    .scm_menu_push = "git push 넣기",
    .scm_menu_pull = "git pull 넣기",
    .scm_menu_pick_base = "기준 브랜치 고르기…",
    .scm_base_default = "기본값(origin/HEAD)",
    .scm_base_limit = "기억하는 저장소가 너무 많아 기준을 바꾸지 못했습니다",
    .scm_remote_read_only = "원격 세션이라 아직 목록만 읽습니다",
    .scm_remote_transport_failed = "원격 연결이 끊겨 git 까지 닿지 못했습니다",
    .scm_no_terminal = "명령을 넣을 터미널이 없습니다",
    .scm_changes = "변경 사항",
    .scm_history = "히스토리",
    .scm_staged = "스테이지된 변경",
    .cfg_font_size = "폰트 크기(pt)",
    .cfg_font_line_height = "행간 배수",
    .cfg_mob_font_line_height = "줄 높이(%, 100=글자 크기)",
    .cfg_font_letter_spacing = "자간(논리 pt, 음수 허용)",
    .cfg_font_family = "폰트 패밀리(내부 공백 보존)",
    .cfg_font_fallback = "폴백 폰트(쉼표 구분)",
    .cfg_font_family_bold = "bold 폰트 패밀리(빈 값=주 폰트 bold)",
    .cfg_font_family_italic = "italic 폰트 패밀리(빈 값=주 폰트 italic)",
    .cfg_font_ligatures = "프로그래밍 합자(=> != // 등)",
    .cfg_theme_background = "배경색(#RRGGBB)",
    .cfg_theme_foreground = "전경색(#RRGGBB)",
    .cfg_theme_cursor = "커서색(#RRGGBB)",
    .cfg_theme_selection = "선택 하이라이트 배경(#RRGGBB)",
    .cfg_cursor_shape = "커서 모양",
    .cfg_cursor_blink = "커서 깜빡임",
    .cfg_cursor_blink_interval_ms = "커서 깜빡임 반주기(ms)",
    .cfg_cursor_blink_fade_ms = "커서 깜빡임 페이드(ms, 0=즉각)",
    .cfg_cursor_unfocused = "포커스 잃을 때 커서",
    .cfg_input_page_keys = "메인 화면 PageUp/Down",
    .cfg_input_shift_enter = "Shift+Enter 인코딩",
    .cfg_input_ime_enter = "IME 조합 중 Enter",
    .cfg_input_url_click_modifier = "URL 클릭 수식키",
    .cfg_input_mouse_hide_while_typing = "타이핑 중 마우스 숨김",
    .cfg_input_option_as_meta = "Option을 Meta(Alt)로",
    .cfg_input_right_click = "터미널 우클릭 동작",
    .cfg_input_word_separators = "더블클릭 단어 구분자",
    .cfg_input_link_detection = "링크 자동 감지 범위",
    .cfg_input_link_open_target = "웹 링크 열기 대상",
    .cfg_input_paste_protection = "위험한 붙여넣기 확인",
    .cfg_input_bracketed_paste_is_safe = "bracketed paste는 안전으로",
    .cfg_input_selection_clear_on_typing = "타이핑하면 선택 해제",
    .cfg_keyhint_enabled = "모디파이어 홀드 시 단축키 힌트 표시",
    .cfg_keyhint_delay = "힌트 표시까지 홀드 시간(ms)",
    .cfg_keyhint_modifier = "힌트를 띄우는 모디파이어(단독 홀드)",
    .cfg_session_keep_alive_after_quit = "정상 GUI 종료 후에도 터미널 세션을 유지하고 재실행 시 재접속(실험적, tmux식)",
    .cfg_sidebar_show_branch = "사이드바 카드에 git 브랜치 표시",
    .cfg_sidebar_show_folder = "사이드바 카드에 폴더 경로 표시",
    .cfg_sidebar_agent_hooks = "에이전트 상태·알림·턴을 받는 provider 훅 설치",
    .image_gallery_no_agent = "이 pane에 에이전트 세션이 없습니다",
    .image_gallery_empty = "이 세션에는 이미지가 없습니다",
    .image_gallery_partial = "세션을 다 읽지 못했습니다",
    .image_gallery_scanning = "세는 중…",
    .image_gallery_count_suffix = "장",
    .image_gallery_shown_of = "{1}장 중 {0}장",
    .image_gallery_open_failed = "이 이미지를 열 수 없습니다",
    .image_gallery_search_prompt = "거르기: ",
    .image_gallery_no_match = "걸린 이미지가 없습니다",
    .agent_hook_notice_done = "턴이 끝났습니다",
    .agent_hook_notice_failed = "턴이 오류로 끝났습니다",
    .agent_hook_notice_attention = "승인을 기다리는 중",
    .cfg_sidebar_width_pt = "사이드바 폭(pt)",
    .cfg_editor_wrap = "긴 줄 자동 줄바꿈",
    .cfg_editor_tab_width = "탭 폭(칸)",
    .cfg_editor_cursor_shape = "커서 모양",
    .cfg_statusbar_show = "하단 상태표시줄 표시",
    .cfg_quick_height_fraction = "두께 비율(화면 대비)",
    .cfg_quick_width_fraction = "center 가로 비율(0=height 따라감)",
    .cfg_quick_auto_hide = "포커스 잃으면 자동 숨김",
    .cfg_quick_screen = "어느 화면에 띄울지",
    .cfg_quick_position = "어느 가장자리에서 나올지",
    .cfg_quick_chrome = "패널 chrome 수준",
    .cfg_quick_minimal_tabs = "minimal에서 탭 허용",
    .cfg_ui_language = "UI 표시 언어(auto=OS 로케일)",
    .cfg_chrome_tab_style = "활성 탭 룩(connected|underline|pill)",
    .cfg_theme_follow_system = "시스템 라이트/다크 따라 테마 전환",
    .cfg_theme_preset_light = "라이트 외관 프리셋",
    .cfg_theme_preset_dark = "다크 외관 프리셋",
    .cfg_text_blink = "SGR5 blink 글자 깜빡임",
    .cfg_text_ambiguous_width = "EAW Ambiguous 문자 폭",
    .cfg_text_emoji_width = "이모지(VS16·키캡) 폭",
    .cfg_theme_bold_is_bright = "bold를 bright 색으로",
    .cfg_theme_min_contrast = "ANSI 팔레트 최소 명암비(0=끔, 라이트 배경 가독성)",
    .cfg_window_padding_top = "위 여백(pt)",
    .cfg_window_padding_right = "오른쪽 여백(pt)",
    .cfg_window_padding_bottom = "아래 여백(pt)",
    .cfg_window_padding_left = "왼쪽 여백(pt)",
    .cfg_window_opacity = "창 배경 투명도(0~1)",
    .cfg_render_frame_rate = "앱 주사율(Hz)",
    .cfg_window_background_image = "배경 이미지 PNG 경로",
    .cfg_window_blur = "창 뒤 배경 블러 반경(px, 0=끔, opacity<1일 때만)",
    .cfg_window_unfocused_dim = "비활성 split pane 디밍(0~1)",
    .cfg_split_divider_thickness = "split 경계선 두께(pt, 0=숨김)",
    .cfg_term = "$TERM 값",
    .cfg_filepanel_external_link_target = "파일 패널 외부 링크 열기 대상",
    .cfg_shell_command = "셸 실행 파일 경로(절대경로, 빈 값=자동)",
    .cfg_shell_windows_shell = "Windows 기본 셸 종류(shell.command가 비었을 때)",
    .cfg_workspace_tab_inherit_cwd = "새 탭/Term이 포커스 cwd 상속",
    .cfg_workspace_split_inherit_cwd = "새 분할이 포커스 cwd 상속",
    .cfg_workspace_hold_on_startup_failure = "셸이 시작 직후 비정상 종료 시 창 유지(닫지 않음)",
    .cfg_shellint_ssh = "평범한 ssh를 maru ssh로 라우팅",
    .cfg_ssh_server_alive_interval = "maru ssh keepalive 간격(초) — 0이면 ~/.ssh/config를 그대로 둡니다",
    .cfg_ssh_server_alive_count_max = "maru ssh keepalive가 몇 번 응답 없으면 연결이 죽은 것으로 볼지",
    .cfg_ssh_reconnect = "maru ssh 세션이 끊기면 자동으로 다시 붙기(재접속은 새 원격 셸입니다)",
    .cfg_notif_osc = "OSC 9/777 데스크톱 알림",
    .cfg_notif_update_check = "새 버전 출시 확인·안내",
    .cfg_notif_history_limit = "알림 센터 보관 개수",
    .cfg_scrollback_lines = "스크롤백 보관 줄 수",
    .cfg_scrollback_sticky_command = "스크롤 시 현재 명령줄을 최상단 고정(sticky)",
    .cfg_scroll_multiplier = "휠 스크롤 배수",
    .cfg_osc52_read = "OSC 52 클립보드 읽기",
    .cfg_bell_audible = "BEL 수신 시 시스템 소리",
    .cfg_bell_visual = "BEL 수신 시 화면 번쩍임",
    .cfg_bell_dock_badge = "BEL 수신 시 Dock 배지",
    .ctx_new_file = "새 파일\u{2026}",
    .ctx_new_folder = "새 폴더\u{2026}",
    .ctx_rename = "이름 변경",
    .ctx_move_to_trash = "휴지통으로 이동",
    .ctx_open_file = "파일 열기\u{2026}",
    .ctx_open_folder = "폴더 열기\u{2026}",
    .ctx_add_folder_to_workspace = "작업공간에 폴더 추가\u{2026}",
    .ctx_remove_folder_from_workspace = "작업공간에서 폴더 제거",
    .ctx_group_create = "새 그룹으로 묶기",
    .ctx_group_sibling = "형제 그룹으로 분리",
    .ctx_group_ungroup = "그룹 풀기",
    .ctx_group_remove = "그룹에서 빼기",
    .ctx_group_promote = "여기서 최상위로 분리",
    .ctx_copy = "복사",
    .ctx_paste = "붙여넣기",
    .ctx_group_unpin = "그룹 고정 해제",
    .ctx_group_pin = "그룹째 고정",
    .ctx_local_unpin = "그룹 내 고정 해제",
    .ctx_local_pin = "그룹 내 위치 고정",
    .ctx_unpin = "고정 해제",
    .ctx_pin = "위치 고정",
};

/// 키 목록은 `Table`에서 **자동 파생**한다 — 손으로 두 벌 유지하면 그 둘이 갈리는 순간 조용히 어긋난다.
///
/// **분기 한도를 올린다.** 이 파생은 필드 수만큼 comptime 루프를 도는데(`std.meta.FieldEnum` →
/// `std.simd.iota`), 표가 자라 기본값(1000)을 넘겼다 — 넘긴 순간 **이 파일을 쓰는 모든 모듈이
/// 컴파일 실패**한다(모바일 브리지에서 그렇게 드러났다). 표는 앞으로도 자라므로 넉넉히 둔다.
pub const Key = blk: {
    @setEvalBranchQuota(20_000);
    break :blk std.meta.FieldEnum(Table);
};

/// 현재 언어. **UI 스레드가 소유한다**(계약 §5.2) — 쓰기는 config 로드·설정 변경 경로에서만이고, 읽기는
/// 문자열을 DrawList로 옮기는 락 아래 구간이다. 렌더 스레드는 이 값을 보지 않고 이미 해석된 슬라이스만
/// 만지므로(문자열이 static이라 언어가 바뀌어도 그 슬라이스는 유효하다) 언어 전환은 **프레임 경계에서만**
/// 일어나고 한 프레임 안에 두 언어가 섞이지 않는다.
///
/// **초기값은 `en` 이다 — 이 값은 config 를 읽기 전에만 쓰인다.** 세션 init 이 `ui.language` 를 읽어
/// `applyPreference` 로 즉시 덮으므로(기본 `auto` → 로케일 판정), 한국어 로케일에서 초기값이 화면에
/// 남지 않는다. 계약 §5 가 "해석 실패는 `en`"으로 정한 것과 같은 값이라, 배선이 없는 경로(config 를
/// 만들지 않는 도구·테스트)에서도 계약과 어긋나지 않는다.
///
/// 전환 도중(I3-0~I3a 슬라이스 5)에는 이 값이 한시적으로 `ko` 였다 — 배선 전에 `en` 을 두면 키로 옮긴
/// 문자열이 전부 영어로 나와 **옮기는 작업이 표시를 바꿔** 버렸기 때문이다. I4a 가 배선을 붙이며 계약이
/// 정한 값으로 되돌렸다.
///
/// **원자적으로 읽고 쓴다.** 소유 규칙(쓰기는 UI 스레드)은 그대로이고, 원자성은 **읽는 쪽이 UI 스레드만이
/// 아닐 수 있다**는 것에 대한 대비다.
///
/// 이것을 넣게 만든 실제 사고는 아카이브 상세를 읽는 **떼어낸 워커**가 민감 내용을 대체 문구로 바꾸며
/// `t()` 를 부르던 것이었다 — 평범한 `var` 였을 때 UI 스레드의 쓰기와 동기화 없이 겹치는 자료 경합이다.
/// **그 호출부는 이제 없다**(워커는 `Turn.redacted` 플래그만 세우고 문구는 UI 스레드가 푼다 — 계약 §5.2
/// "번역 문자열의 수명은 프레임을 넘기지 않는다"). 그래도 원자성을 되돌리지 않는 이유는, 그 규칙이
/// **깨졌다는 것을 컴파일러가 말해 주지 않기 때문**이다. 워커에서 `t()` 를 한 줄 부르는 것은 아무 경고
/// 없이 통과하고, 그때 이 `var` 는 조용히 UB 가 된다. `.monotonic` 한 쌍의 값이 그 위험보다 싸다.
///
/// `.monotonic` 으로 충분한 이유는 이 값과 **함께 건너가는 다른 상태가 없기** 때문이다 — 문자열은 static
/// 이라 어느 쪽 언어를 보든 문장은 온전하다.
var current: std.atomic.Value(Lang) = .init(.en);

pub fn setLang(l: Lang) void {
    current.store(l, .monotonic);
}

pub fn lang() Lang {
    return current.load(.monotonic);
}

/// 제품 호출부가 쓰는 조회. 인자는 키 하나뿐이라 호출부에 언어를 실어 나르지 않는다.
pub fn t(key: Key) [:0]const u8 {
    return tIn(lang(), key);
}

/// 언어를 명시하는 조회 — **테스트가 전역을 건드리지 않고** 양쪽 언어를 확인할 때 쓴다.
///
/// `inline else`가 런타임 `key`를 comptime으로 펼쳐 `@field` 접근을 가능하게 한다. 반환 타입
/// `[:0]const u8`은 chrome의 `[]const u8` 소비자로 그대로 coerce되고 ABI가 요구하는 널 종단도 만족해
/// 양쪽에 하나의 타입으로 통한다(계약 §3.1).
pub fn tIn(l: Lang, key: Key) [:0]const u8 {
    const tbl: *const Table = switch (l) {
        .en => &en,
        .ko => &ko,
    };
    return switch (key) {
        inline else => |k| @field(tbl.*, @tagName(k)),
    };
}

// ── 런타임 보간 ─────────────────────────────────────────────────────────
//
// **왜 std.fmt을 못 쓰나**(계약 §6.3): `std.fmt.bufPrint`는 `comptime fmt`를 요구하는데 번역 문자열은
// 언어에 따라 런타임에 고른 값이다. 그대로 넘기면 `error: unable to resolve comptime value`가 난다.
// gettext·i18next가 자체 보간을 갖는 것도 같은 이유다(C `printf`는 런타임 틀을 받으므로 gettext는 그것을
// 그대로 쓴다 — Zig는 못 쓴다).

/// 보간에 끼울 값. **타입 지정자(`{d}`·`{s}`)를 틀에 두지 않는 이유**가 여기 있다 — 타입이 이 union에
/// 이미 있으므로 번역자가 `{s}`를 `{d}`로 잘못 옮기는 실패 모드가 아예 없다.
pub const Arg = union(enum) {
    s: []const u8,
    d: i64,
};

/// `template`의 `{N}`을 `args[N]`으로 치환해 `buf`에 쓰고, 쓴 부분을 돌려준다.
///
/// 문법은 **`{0}`·`{1}` 위치 자리표시자만**이다. 번호가 필요한 이유는 어순이다 — 같은 문장이
/// `"Moved {0} to {1}"`과 `"{1}(으)로 {0}을(를) 옮겼습니다"`처럼 자리를 바꿔야 하고, 순서대로 채우는
/// 방식으로는 그것을 표현할 수 없다.
///
/// **실패해도 에러를 올리지 않는다**(계약 §6.3). 이 자리의 실패는 "번역이 이상하다"이지 앱이 멈출 일이
/// 아니고, 호출부 수백 곳에 에러 처리를 물리면 그 자체가 부채가 된다.
///   - 범위 밖 인덱스(`{9}`인데 인자 2개) → **원문 그대로** 남긴다. 무엇이 잘못됐는지 화면에 보인다.
///   - 자리표시자가 아닌 중괄호(`{abc}`) → 그대로 복사한다.
///   - 버퍼 부족 → UTF-8 경계에서 자른다(`width.truncateToBoundary` — 깨진 바이트를 남기지 않는다).
pub fn format(buf: []u8, template: []const u8, args: []const Arg) []u8 {
    var w: usize = 0;
    var i: usize = 0;
    while (i < template.len) {
        if (template[i] == '{') {
            if (std.mem.indexOfScalarPos(u8, template, i, '}')) |close| {
                if (std.fmt.parseInt(usize, template[i + 1 .. close], 10)) |idx| {
                    if (idx < args.len) {
                        w += writeArg(buf[w..], args[idx]);
                    } else {
                        // 인자 부족 — 원문을 남겨 번역 실수가 화면에 드러나게 한다.
                        w += appendTruncated(buf[w..], template[i .. close + 1]);
                    }
                    i = close + 1;
                    continue;
                } else |_| {}
            }
        }
        // 자리표시자가 아닌 바이트는 그대로. 여기서 잘리면 더 쓸 공간이 없다는 뜻이라 멈춘다.
        if (w >= buf.len) break;
        buf[w] = template[i];
        w += 1;
        i += 1;
    }
    return buf[0..w];
}

fn writeArg(dst: []u8, arg: Arg) usize {
    switch (arg) {
        .s => |v| return appendTruncated(dst, v),
        .d => |v| {
            // 숫자 포맷의 틀은 리터럴이라 std.fmt을 쓸 수 있다(런타임 틀이 아니다).
            var tmp: [24]u8 = undefined;
            const printed = std.fmt.bufPrint(&tmp, "{d}", .{v}) catch return 0;
            return appendTruncated(dst, printed);
        },
    }
}

/// `src`를 `dst`에 쓰되 공간이 모자라면 UTF-8 경계에서 자른다. 쓴 바이트 수를 돌려준다.
fn appendTruncated(dst: []u8, src: []const u8) usize {
    const n = width.truncateToBoundary(src, dst.len);
    @memcpy(dst[0..n], src[0..n]);
    return n;
}

// ── 로케일 판정 ─────────────────────────────────────────────────────────

/// OS가 준 로케일 식별자 → `Lang`.
///
/// **platform은 문자열을 읽어 그대로 넘기고, 해석은 여기서 한다**(계약 §5.1). 표기가 플랫폼마다 다르므로
/// (macOS `NSLocale`은 `ko-KR`, POSIX는 `ko_KR`, 짧게는 `ko`) 언어 부분만 본다. 이 분리가 있어야
/// 판정 규칙이 플랫폼 수만큼 복제되지 않고, 로케일 문자열을 주입해 **OS 없이 테스트**할 수 있다.
///
/// 모르는 값은 `en`으로 떨어진다 — 읽을 수 없는 언어보다 영어가 낫다.
pub fn fromLocale(tag: []const u8) Lang {
    if (tag.len >= 2 and std.ascii.eqlIgnoreCase(tag[0..2], "ko")) {
        // "ko"로 시작해도 구분자가 오지 않으면 다른 언어다(가상의 "kor"류 오탐 방지).
        if (tag.len == 2 or tag[2] == '-' or tag[2] == '_' or tag[2] == '.') return .ko;
    }
    return .en;
}

/// 사용자가 고르는 값(`ui.language`). `Lang`과 **일부러 다른 타입**이다 — `auto`는 표시할 수 있는
/// 언어가 아니라 "OS에게 물어보라"는 지시라서, 같은 enum에 섞으면 `t()`가 `auto`를 받는 상태가
/// 타입으로 표현 가능해진다. `config/theme.zig`가 이 타입을 그대로 재노출한다(판정은 여기가 소유).
pub const Preference = enum { auto, en, ko };

/// OS 로케일 식별자. platform이 시작 시 한 번 넣는다(계약 §5.1 — platform은 읽어서 넘기기만 한다).
///
/// 힙을 쓰지 않는 이유: 이 leaf는 할당자를 받지 않는다(중립 leaf 관행). 로케일 태그는 `ko-KR` 류의
/// 짧은 ASCII라 고정 버퍼로 충분하고, 넘치면 잘라도 **언어 부분은 앞에 있어** 판정이 살아남는다.
var os_locale_buf: [64]u8 = undefined;
var os_locale_len: usize = 0;

pub fn setOsLocale(tag: []const u8) void {
    const n = @min(tag.len, os_locale_buf.len);
    @memcpy(os_locale_buf[0..n], tag[0..n]);
    os_locale_len = n;
}

pub fn osLocale() ?[]const u8 {
    return if (os_locale_len == 0) null else os_locale_buf[0..os_locale_len];
}

/// 설정값 + 로케일 → 실제 언어. **로케일을 인자로 받는다** — 전역을 읽으면 OS 없이 테스트할 수 없다.
pub fn resolve(pref: Preference, locale: ?[]const u8) Lang {
    return switch (pref) {
        .en => .en,
        .ko => .ko,
        // 로케일이 없으면(주입 실패·미지원 platform) `en`. 계약 §5의 "해석 실패는 en" 그대로다.
        .auto => if (locale) |tag| fromLocale(tag) else .en,
    };
}

/// 언어 선택 드롭다운의 **표시명**.
///
/// **번역 테이블에 통째로 두지 않는다.** 언어 이름은 자기 언어로 적어야 한다 — 자기가 읽을 수 있는
/// 언어를 찾는 자리이므로 현재 UI 언어로 번역하면 오히려 못 찾는다(영어 화면에서 `한국어`를 `Korean`
/// 으로 쓰면 한국어만 읽는 사람이 그 줄을 못 알아본다). 그래서 `en`·`ko` 는 **고정**이다.
///
/// `auto` 만 예외로 키를 쓴다 — 그것은 언어 이름이 아니라 "OS 를 따른다"는 **동작**이라, 읽는 사람의
/// 언어로 적히는 편이 맞다.
pub fn preferenceLabel(p: Preference) [:0]const u8 {
    return switch (p) {
        .auto => t(.set_language_auto),
        .en => "English",
        .ko => "한국어",
    };
}

/// 설정값을 현재 언어로 적용한다 — config 로드·변경 경로(UI 스레드)가 부른다(계약 §5.2).
pub fn applyPreference(pref: Preference) void {
    setLang(resolve(pref, osLocale()));
}

// ════════════════════════════════════════════════════════════════════════
//  테스트 — 이 파일이 증명하는 것
//
//  터미널에서 왜 중요한가: 이 leaf가 틀리면 **화면의 모든 안내 문장이 함께 틀린다**. 번역 누락은
//  컴파일에 잡히지만(아래 첫 테스트가 그 구조를 고정한다), 조회·보간·로케일 판정의 오류는 런타임에만
//  드러나고 사용자에게는 "앱이 이상한 말을 한다"로 보인다.
// ════════════════════════════════════════════════════════════════════════

const testing = std.testing;

test "언어 테이블은 모든 키를 채운다 — 누락은 컴파일에 잡히므로 여기서는 값이 비지 않음을 본다" {
    // `Table`에 기본값이 없어 필드를 빠뜨리면 이 파일이 컴파일되지 않는다. 그 구조가 지켜지는 한
    // 런타임에 남는 실패는 "빈 문자열을 넣었다"뿐이라 그것만 본다.
    inline for (@typeInfo(Table).@"struct".fields) |f| {
        try testing.expect(@field(en, f.name).len > 0);
        try testing.expect(@field(ko, f.name).len > 0);
    }
}

/// 테스트 보조 — 문자열에서 `{N}` 자리표시자 인덱스를 오름차순 집합으로 뽑는다.
fn placeholderSet(s: []const u8, out: *[8]u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] != '{') continue;
        const close = std.mem.indexOfScalarPos(u8, s, i, '}') orelse continue;
        const idx = std.fmt.parseInt(u8, s[i + 1 .. close], 10) catch continue;
        var seen = false;
        for (out[0..n]) |v| {
            if (v == idx) seen = true;
        }
        if (!seen and n < out.len) {
            out[n] = idx;
            n += 1;
        }
        i = close;
    }
    std.mem.sort(u8, out[0..n], {}, std.sort.asc(u8));
    return out[0..n];
}

test "언어 테이블은 자리표시자 집합이 같아야 한다 — 번역이 값을 잃거나 더하면 화면이 틀린다" {
    // 번역자가 `{0}`을 빠뜨리면 값이 사라지고, 없던 `{1}`을 넣으면 원문이 그대로 남는다(§6.3).
    // 둘 다 그 언어에서만 나타나므로 사람이 두 테이블을 나란히 보지 않으면 못 잡는다.
    inline for (@typeInfo(Table).@"struct".fields) |f| {
        var be: [8]u8 = undefined;
        var bk: [8]u8 = undefined;
        const pe = placeholderSet(@field(en, f.name), &be);
        const pk = placeholderSet(@field(ko, f.name), &bk);
        testing.expectEqualSlices(u8, pe, pk) catch |err| {
            std.debug.print("자리표시자 불일치: .{s}\n  en={any}\n  ko={any}\n", .{ f.name, pe, pk });
            return err;
        };
    }
}

test "영어 테이블에 한글이 남아 있지 않다 — 옮기다 만 항목을 잡는다" {
    // 리터럴을 키로 옮길 때 `en` 쪽에 원문을 그대로 붙여 두는 실수가 가장 흔하다.
    inline for (@typeInfo(Table).@"struct".fields) |f| {
        const v = @field(en, f.name);
        var it = std.unicode.Utf8Iterator{ .bytes = v, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (cp >= 0xAC00 and cp <= 0xD7A3) {
                std.debug.print("영어 테이블에 한글: .{s} = \"{s}\"\n", .{ f.name, v });
                return error.TestUnexpectedResult;
            }
        }
    }
}

test "한국어 테이블에는 한글이 있다 — 번역을 빠뜨리고 영어를 복사한 항목을 잡는다" {
    inline for (@typeInfo(Table).@"struct".fields) |f| {
        const v = @field(ko, f.name);
        var has = false;
        var it = std.unicode.Utf8Iterator{ .bytes = v, .i = 0 };
        while (it.nextCodepoint()) |cp| {
            if (cp >= 0xAC00 and cp <= 0xD7A3) has = true;
        }
        if (!has) {
            std.debug.print("한국어 테이블에 한글 없음: .{s} = \"{s}\"\n", .{ f.name, v });
            return error.TestUnexpectedResult;
        }
    }
}

test "로드 전 초기 언어는 en 이다 — 계약이 정한 폴백과 같은 값이어야 한다" {
    // 이 값은 config 를 읽기 전에만 쓰인다(세션 init 이 applyPreference 로 즉시 덮는다). 그래도 배선이
    // 없는 경로에서는 이 값이 그대로 남으므로, **계약 §5 의 "해석 실패는 en"과 같은 값**이어야 한다.
    // 다른 값으로 새면 배선 없는 경로만 다른 언어를 쓰게 되어 어디가 정답인지 알 수 없어진다.
    //
    // 다른 테스트가 setLang 으로 전역을 바꿔 놓고 복원하지 않으면 여기서 드러난다 — 이 파일의 테스트는
    // 전부 defer 로 되돌린다.
    try testing.expectEqual(resolve(.auto, null), lang());
}

test "tIn: 언어별로 다른 문자열을 준다 — 전역을 건드리지 않는다" {
    const before = lang();
    try testing.expectEqualStrings("Cannot open the selected folder.", tIn(.en, .fp_root_open_failed));
    try testing.expectEqualStrings("선택한 폴더를 열 수 없습니다.", tIn(.ko, .fp_root_open_failed));
    try testing.expectEqual(before, lang()); // tIn은 전역을 읽지도 쓰지도 않는다
}

test "t: 전역 언어를 따른다" {
    const before = lang();
    defer setLang(before);

    setLang(.ko);
    try testing.expectEqualStrings("선택한 폴더를 열 수 없습니다.", t(.fp_root_open_failed));
    setLang(.en);
    try testing.expectEqualStrings("Cannot open the selected folder.", t(.fp_root_open_failed));
}

test "문자열은 static이다 — 언어를 바꿔도 앞서 받은 슬라이스가 살아 있다" {
    // 계약 §3.1: ABI가 포인터를 그대로 들고 있어도 안전하고, 렌더 스레드가 이미 해석된 슬라이스를
    // 만지는 동안 UI 스레드가 언어를 바꿔도 그 슬라이스는 유효하다(§5.2).
    const before = lang();
    defer setLang(before);

    setLang(.ko);
    const held = t(.fp_root_missing);
    setLang(.en);
    try testing.expectEqualStrings("선택한 탐색기 루트가 더 이상 존재하지 않습니다.", held);
    try testing.expectEqual(held.ptr, tIn(.ko, .fp_root_missing).ptr); // 매번 새로 만들지 않는다
    try testing.expectEqual(@as(u8, 0), held[held.len]); // 널 종단 유지(C ABI 요구)
}

test "보간: 위치 자리표시자가 어순이 다른 언어에서 자리를 바꾼다" {
    var buf: [128]u8 = undefined;
    const args = [_]Arg{ .{ .s = "report.md" }, .{ .s = "docs/" } };
    try testing.expectEqualStrings(
        "Moved report.md to docs/",
        format(&buf, "Moved {0} to {1}", &args),
    );
    try testing.expectEqualStrings(
        "docs/(으)로 report.md을(를) 옮겼습니다",
        format(&buf, "{1}(으)로 {0}을(를) 옮겼습니다", &args),
    );
}

test "보간: 숫자 인자" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("7분 전", format(&buf, "{0}분 전", &.{.{ .d = 7 }}));
    try testing.expectEqualStrings("-3 items", format(&buf, "{0} items", &.{.{ .d = -3 }}));
}

test "보간: 인자가 모자라면 원문을 남긴다 — 번역 실수로 앱이 죽지 않는다" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("a {9} b", format(&buf, "a {9} b", &.{.{ .s = "x" }}));
}

test "보간: 자리표시자가 아닌 중괄호는 그대로 복사한다" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{abc} 값", format(&buf, "{abc} 값", &.{}));
    try testing.expectEqualStrings("여는 { 만", format(&buf, "여는 { 만", &.{}));
}

test "보간: 버퍼가 모자라면 UTF-8 경계에서 자른다 — 깨진 바이트를 남기지 않는다" {
    // "가"는 3바이트다. 4바이트 버퍼에 "가나"를 넣으면 첫 글자만 남아야 하고,
    // 두 번째 글자의 앞 1바이트가 남아 화면에 U+FFFD가 뜨면 안 된다.
    var small: [4]u8 = undefined;
    const out = format(&small, "{0}", &.{.{ .s = "가나" }});
    try testing.expectEqualStrings("가", out);
    try testing.expect(std.unicode.utf8ValidateSlice(out));

    // 틀의 리터럴 부분도 같은 규율을 따른다(공간이 없으면 멈춘다).
    var tiny: [2]u8 = undefined;
    try testing.expect(std.unicode.utf8ValidateSlice(format(&tiny, "ab{0}", &.{.{ .s = "cd" }})));
}

test "보간: 자리표시자 문법의 경계 — 닫히지 않음·빈 중괄호·음수·거대 인덱스" {
    // 이 케이스들은 번역자가 틀을 잘못 옮겼을 때 실제로 나오는 모양이다. 어느 것도 앱을 멈추면 안 되고,
    // 무엇이 잘못됐는지 화면에 남아야 고칠 수 있다.
    var buf: [64]u8 = undefined;
    const one = [_]Arg{.{ .s = "X" }};
    try testing.expectEqualStrings("a {0", format(&buf, "a {0", &one)); // 닫히지 않음
    try testing.expectEqualStrings("{}", format(&buf, "{}", &one)); // 빈 중괄호
    try testing.expectEqualStrings("{-1}", format(&buf, "{-1}", &one)); // 음수(usize 파싱 실패)
    try testing.expectEqualStrings("{99999999999999999999}", format(&buf, "{99999999999999999999}", &one)); // 오버플로
    try testing.expectEqualStrings("X}", format(&buf, "{0}}", &one)); // 치환 뒤 남은 닫는 괄호
    try testing.expectEqualStrings("", format(&buf, "", &one)); // 빈 틀
    try testing.expectEqualStrings("인자 없음", format(&buf, "인자 없음", &one)); // 자리표시자 없음
}

test "보간: 같은 인자를 여러 번 쓸 수 있다" {
    // 한국어는 조사 때문에 같은 값을 두 번 부르는 문장이 나온다("X는 X다" 류).
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("A와 A", format(&buf, "{0}와 {0}", &.{.{ .s = "A" }}));
}

test "보간: 인자가 하나도 없을 때 자리표시자는 원문으로 남는다" {
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("{0} 값", format(&buf, "{0} 값", &.{}));
}

test "fromLocale: 플랫폼별 표기를 하나로 정규화한다" {
    try testing.expectEqual(Lang.ko, fromLocale("ko"));
    try testing.expectEqual(Lang.ko, fromLocale("ko-KR")); // macOS NSLocale
    try testing.expectEqual(Lang.ko, fromLocale("ko_KR")); // POSIX
    try testing.expectEqual(Lang.ko, fromLocale("ko_KR.UTF-8"));
    try testing.expectEqual(Lang.ko, fromLocale("KO-kr")); // 대소문자 무시
}

test "fromLocale: 모르는 값은 영어로 떨어진다" {
    try testing.expectEqual(Lang.en, fromLocale("en-US"));
    try testing.expectEqual(Lang.en, fromLocale("ja-JP"));
    try testing.expectEqual(Lang.en, fromLocale(""));
    try testing.expectEqual(Lang.en, fromLocale("k"));
    try testing.expectEqual(Lang.en, fromLocale("kor")); // "ko" 접두지만 구분자가 없다
}

test "resolve: 명시값은 로케일을 무시하고, auto 만 로케일을 본다" {
    // 명시값이 로케일에 흔들리면 "영어 고정"이 고정이 아니게 된다.
    try testing.expectEqual(Lang.en, resolve(.en, "ko-KR"));
    try testing.expectEqual(Lang.ko, resolve(.ko, "en-US"));

    try testing.expectEqual(Lang.ko, resolve(.auto, "ko-KR"));
    try testing.expectEqual(Lang.en, resolve(.auto, "en-US"));
}

test "resolve: auto 인데 로케일이 없으면 en 이다 — 읽을 수 없는 언어보다 영어가 낫다" {
    // 주입이 실패하거나 로케일 개념이 없는 platform 에서 이 경로를 탄다. 계약 §5 의 "해석 실패는 en".
    try testing.expectEqual(Lang.en, resolve(.auto, null));
}

test "setOsLocale: 버퍼보다 긴 태그는 잘려도 언어 판정이 살아남는다" {
    const before_len = os_locale_len;
    defer os_locale_len = before_len;

    os_locale_len = 0;
    try testing.expectEqual(@as(?[]const u8, null), osLocale());

    // 언어 부분(`ko`)은 태그의 **앞**에 있으므로, 뒤가 잘려도 판정은 그대로다.
    var long: [200]u8 = undefined;
    @memset(&long, 'x');
    @memcpy(long[0..6], "ko-KR.");
    setOsLocale(&long);
    try testing.expectEqual(@as(usize, os_locale_buf.len), os_locale_len);
    try testing.expectEqual(Lang.ko, resolve(.auto, osLocale()));
}

test "Preference 는 Lang 과 다른 타입이다 — auto 를 표시 언어로 쓸 수 없다" {
    // `auto`가 `Lang`에 섞이면 `t()`가 "OS에게 물어보라"는 지시를 문자열로 그리려는 상태가
    // 타입으로 표현 가능해진다. 두 enum 의 변형 집합이 갈라져 있는 것이 그 방어다.
    try testing.expectEqual(@as(usize, 2), @typeInfo(Lang).@"enum".fields.len);
    try testing.expectEqual(@as(usize, 3), @typeInfo(Preference).@"enum".fields.len);

    // 이름이 겹치는 둘(`en`·`ko`)은 뜻이 같아야 한다 — 갈리면 설정값과 표시 언어가 어긋난다.
    inline for (@typeInfo(Lang).@"enum".fields) |f| {
        try testing.expectEqual(@field(Lang, f.name), resolve(@field(Preference, f.name), null));
    }
}

test "applyPreference: 전역 로케일을 거쳐 현재 언어를 바꾼다" {
    const lang_before = lang();
    const locale_before_len = os_locale_len;
    defer {
        setLang(lang_before);
        os_locale_len = locale_before_len;
    }

    setOsLocale("ko-KR");
    applyPreference(.auto);
    try testing.expectEqual(Lang.ko, lang());

    applyPreference(.en); // 명시값은 로케일을 덮는다
    try testing.expectEqual(Lang.en, lang());
}
