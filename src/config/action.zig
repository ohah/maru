const std = @import("std");

pub const Action = union(enum) {
    // 워크스페이스(사이드바 탭) 단위. 탭 풀 모델에선 ⌘⇧T/⌘⇧[]가 워크스페이스, ⌘T/⌘[]는 아래 Term이다.
    new_tab,
    close_tab,
    select_tab: usize,
    previous_tab,
    next_tab,
    // 활성 pane 안의 Term(가로 탭 = 터미널) 단위(탭 모델). ⌘T=새 Term, ⌘W=활성 Term 닫기(마지막이면 pane→워크
    // 스페이스로 cascade), ⌘]/⌘[=다음/이전 Term. 워크스페이스(위)와 modifier(shift 유무)로 갈린다.
    new_term,
    // 활성 pane에 web(브라우저) Term을 생성한다 — new_term의 web 버전(PTY/셸 없이 WKWebView surface). 4c/4e의 디버그
    // env 훅 MARU_WEB_PANEL을 사용자 command/메뉴로 승격(docs/plans/web-panel.md §10 4e-5). panel_kind는 .browser(markdown은
    // 후속). 기본 키바인딩 **⌘⌥T**(⌘T=new_term의 web 버전, ⌥로 구분 — ⌘⇧T=new_tab 워크스페이스와도 구분). 메뉴 File·커맨드 팔릿에도 노출.
    new_web_tab,
    // Markdown/HTML 파일 선택창을 열어 현재 창의 전역 도크에 연다. 기본 Cmd+O(macOS Open 관례), 커맨드 팔릿·메뉴와
    // 사용자 keybind에서도 같은 액션을 쓴다. 파일 선택/경로 I/O는 Swift, 종류·도크 라우팅 정책은 Zig가 소유한다.
    open_file_panel,
    // FP8 도크 editor group 전용 커맨드. 일반 pane split과 구분해 팔릿에서 포커스와 무관하게 명시 실행할 수 있고,
    // 기본 키바인딩은 두지 않는다. 새 group은 빈 leaf로 생성되어 다음 파일 열기/트리 클릭의 target이 된다.
    toggle_file_panel_dock_side,
    // workspace terminal/browser pane과 파일 도크(tree 포함) 사이를 왕복한다. 기본 Cmd+Shift+E이며 command
    // catalog/settings에 노출되어 사용자 rebind/unbind가 가능하다.
    toggle_file_panel_focus,
    /// 활성 파일 Term의 표시 모드를 읽기↔소스로 토글한다. 헤더 밴드의 mode 선택기 클릭과 같은 경로다.
    toggle_file_panel_mode,
    // project tree에 transient keyboard focus를 주고 Metal view를 first responder로 만든다. one-way 호환 action이라
    // 남기되 기본 chord는 FP9의 toggle_file_panel_focus로 이전한다.
    focus_file_tree,
    // project tree mutations. 생성은 선택한 directory 또는 file의 parent에, rename/delete는 project
    // directory/file row에만 적용된다. F2/Cmd+Backspace와 context menu도 이 action funnel을 공유한다.
    new_file,
    new_directory,
    rename_file_tree_entry,
    delete_file_tree_entry,
    // 기본 Cmd+W. Zig가 소유한 입력 focus가 파일 도크면 활성 파일 탭, 아니면 기존 Term cascade를 닫는다.
    // close_term은 사용자 명시 바인딩 호환을 위해 terminal 전용으로 남긴다.
    close_focused,
    close_term,
    previous_term,
    next_term,
    // 활성 panel을 둘로 나눈다(split). horizontal=좌우(새 panel이 오른쪽), vertical=상하(새 panel이 아래).
    // 방향 이름은 분할선(divider)의 방향이 아니라 '나란히 놓이는 축'을 따른다 — 단일 출처: docs/tabs-splits-layout.md.
    split_horizontal,
    split_vertical,
    // split 탭에서 포커스를 방향으로 옮긴다(키보드 pane 이동). 방향 반평면 + 정렬로 인접 panel을 고른다.
    focus_pane_left,
    focus_pane_right,
    focus_pane_up,
    focus_pane_down,
    // 활성 워크스페이스의 split(pane)을 순서대로 순환한다(⌘]/⌘[ wrap-around). 방향 이동(focus_pane_*)과 달리
    // 공간 배치와 무관하게 panes 리스트 순서로 다음/이전 pane을 고른다. split이 1개(분할 없음)면 무동작.
    // (Term 순환 previous_term/next_term은 ⌘⌥[/⌘⌥]로 옮겨 ⌘[]를 split에 양보 — 사용자 요청.)
    previous_pane,
    next_pane,
    // 활성 pane(분할 영역)을 통째로 떼어 **새 단독 워크스페이스로 분리**한다 — grip 드래그를 사이드바 빈 영역에
    // 드롭하는 것의 키보드/팔릿 버전(dispatchAppAction이 promotePaneToNewWorkspace로 넘긴다). 단독 pane 워크스페이스면
    // 무동작(no-op 가드). 기본 키바인딩은 없다(macOS 단일 관례 부재 — 발견성은 커맨드 팔릿; rename·split과 같은 베이스
    // 명시 규칙). 단일 출처: docs/tabs-splits-layout.md "Pane을 워크스페이스로 분리·합치기".
    move_pane_to_new_workspace,
    // 활성 pane을 **N번 워크스페이스에 합친다**(merge) — grip 드래그를 다른 카드에 드롭하는 것의 키보드/팔릿 버전
    // (dispatchAppAction이 mergePaneIntoWorkspace로 넘긴다). index는 0-based(select_tab과 동일 — :0=워크스페이스 1).
    // 타겟의 활성 pane을 좌우 split해 들어온 pane을 우측·활성으로 둔다. 자기 워크스페이스·범위 밖·단독 pane이면 무동작.
    // tmux `join-pane -t N` 결. 드래그는 카드로 타겟을 정하지만 키는 번호로 정한다(타겟 명시). 기본 키바인딩은 없다.
    move_pane_to_workspace: usize,
    // 사용자 지정 이름(rename) 시작 — 활성 대상의 이름을 인라인으로 편집한다. workspace=활성 사이드바 탭,
    // pane=활성 분할 영역, term=활성 가로 탭. dispatchAppAction이 인라인 편집기를 연다(custom_name을 쓴다).
    // 기본 키바인딩은 없다(macOS 단일 관례 부재 — 발견성은 커맨드 팔릿·더블클릭·우클릭). 단일 출처:
    // docs/tabs-splits-layout.md "사용자 지정 이름(rename)".
    rename_workspace,
    rename_pane,
    rename_term,
    // 사이드바 그룹(접이식 워크스페이스 묶음) — 위치 파생 그룹 마커(`Tab.group_start`)를 세팅/제거한다(소속은 저장하지
    // 않고 self.tabs 순서에서 파생한다). create_group=활성/클릭 워크스페이스에 그룹 시작 마커를 얹어 그 아래 연속 카드를
    // 한 그룹으로 묶는다(dispatchAppAction→createGroupForTab). ungroup=그 워크스페이스가 속한 그룹의 시작 마커를 제거해
    // 아래 카드를 상위/최상위로 되돌린다(ungroupTab). rename_group=그룹 이름 인라인 편집(헤더 더블클릭과 동형). **기본
    // 단축키는 create_group만 `Cmd+Opt+G`**(Cmd+Shift+G는 find_previous 선점 — 사용자 결정, docs/sidebar-groups.md §7),
    // ungroup/rename_group은 팔레트·우클릭·설정 리바인더로만. 단일 출처: docs/sidebar-groups.md.
    create_group,
    // create_sibling_group=SG5-3 중첩과 **명시적 분리** — 그룹 안 카드에서 실행하면 그 카드의 현재 그룹과 **같은 depth**의
    // 형제 그룹을 시작한다(create_group은 depth+1 중첩). 최상위 카드면 depth 1(create_group과 결과 동일). 위치 파생 연속
    // 파티션상 첫 그룹이 끝까지 뻗어 create_group만으론 형제 최상위 그룹을 못 만드는 tension(§10)을 해소한다. 기본 키
    // `Cmd+Opt+Shift+G`(create_group Cmd+Opt+G와 modifier로 구분, docs/sidebar-groups.md §7·§10).
    create_sibling_group,
    ungroup,
    rename_group,
    // remove_from_group=이 워크스페이스 하나만 자기 그룹에서 빼 **완전 최상위**(어느 그룹에도 안 속함)로 옮긴다 —
    // 그 카드를 첫 group_start 마커 직전(§2.1 최상위 구간)으로 moveTab한다(중첩 깊이 무관). ungroup이 그룹을 통째
    // 해제하는 반면 이건 카드 하나만 뺀다(그룹은 살아남는다 — 마커 카드면 다음 소속 카드로 승계). 이미 최상위면 no-op.
    // 저빈도라 기본 키 없이 우클릭 "그룹에서 빼기"·팔레트·config 리바인더가 발견 경로다(docs/sidebar-groups.md §7).
    remove_from_group,
    // promote_to_top_level=이 워크스페이스 하나를 **제자리에서** 최상위 섬으로 승격한다(§2.1 재설계 §14.5·§14.7 promote-in-place)
    // — 그 카드에 `top_level:=true`만 세팅해 그룹 안 gap에 최상위로 남긴다(위치·순서 불변, sticky-reset로 뒤 멤버까지 그룹에서
    // 끊김). remove_from_group(첫 마커 앞으로 **이동** + **고정 상실**)과 구별되는 eject flavor: promote는 **pin을 안 건드린다**
    // (고정 리전 안이면 고정 top카드로 남음). 저빈도라 기본 키 없이 우클릭 "여기서 최상위로 분리"·팔레트가 발견 경로다.
    promote_to_top_level,
    // 활성 터미널의 전체 내용(스크롤백 + 화면)을 선택한다(Select All, 관례상 ⌘A). 코어 selection 상태라
    // dispatchAppAction이 core.selectAll로 넘긴다. clipboard 쓰기(copy)는 NSPasteboard(OS) 소유라 Action이
    // 아니다(경계: Zig는 selection, Swift는 clipboard).
    select_all,
    // 활성 터미널의 화면 + 스크롤백을 비운다(⌘K — iTerm2/Terminal.app/Ghostty 공통). 코어 상태라 dispatchAppAction이
    // core.clearScreen으로 넘긴다. 베이스/결정·세 경로(alt=무동작, 프롬프트=clear+^L 재그림, 그 외=커서 위만)는
    // core.clearScreen 주석과 docs/key-input-and-shortcuts.md가 단일 출처. clipboard·PTY 쓰기 경계는 select_all과 동일.
    clear_screen,
    // 커맨드 팝업(Cmd+Shift+P)을 토글한다. 앱 UI 상태(PaletteState)라 dispatchAppAction이 열고/닫는다.
    // 카탈로그(command_catalog.entries)에는 안 넣는다 — 팝업이 자기 토글을 목록에 보이는 재귀를 피한다.
    toggle_command_palette,
    // 세팅 화면(⌘,)을 토글한다(config-gui.md CS-4). 앱 UI 상태(chrome settings 컴포넌트)라 dispatchAppAction이
    // 열고/닫는다. ⌘,는 macOS Settings 관례 — 기존 "Open Config…"(파일 열기) 메뉴의 ⌘, keyEquivalent를 양보받는다.
    toggle_settings,
    // 스크롤백 Find(⌘F)를 토글한다. 앱 UI 상태(chrome find 컴포넌트)라 dispatchAppAction이 열고/닫는다.
    // 모달이 열린 동안 키는 검색 입력으로 라우팅된다(handleKeyEvent). **카탈로그에 넣어 커맨드 팝업에 노출한다**
    // (선택 시 acceptPalette가 팝업을 닫고 Find를 연다) — 자기 토글이라 재귀인 toggle_command_palette와 달리 Find는
    // 별개 모달이라 띄워도 된다. 단 메뉴 Find 서브메뉴는 keyEquivalent 없이 따로(키바인딩 가림 방지).
    toggle_find,
    /// 찾기 오버레이를 **바꾸기 줄과 함께** 연다(§5.1 — macOS `⌥⌘F` 관례).
    toggle_find_replace,
    /// 찾기의 대소문자 토글(§5.1 — VSCode `⌥⌘C`). **편집기 문서에서만** 뜻이 있다:
    /// 스크롤백·웹은 이 값을 안 읽는다(웹은 WebKit 에 낱말 경계가 없어 짝이 안 맞는다).
    toggle_find_match_case,
    /// 찾기의 낱말 단위 토글(§5.1 — VSCode `⌥⌘W`). 낱말 판정은
    /// `session/editor/selection.zig` 의 `wordRangeAt` 이 소유한다(더블클릭이 잡는 그 범위).
    toggle_find_whole_word,
    /// 찾기를 **켤 때의 선택 범위 안으로** 한정한다(§5.1 — VSCode `⌥⌘L`). 범위는 **사본**이라
    /// 그 뒤 선택이 움직여도 안 흔들린다(현재 일치가 선택을 옮기는 계약과 충돌하지 않게).
    toggle_find_in_selection,
    /// ⌥⌘D — 비교 뷰에서 검색할 열을 왼쪽↔오른쪽으로 넘긴다(§5.1).
    toggle_find_diff_side,
    /// 걸친 줄들을 지운다(§3.9a — 빌트인 `⇧⌘K`).
    delete_lines,
    /// 걸친 줄들을 아래에 복사한다(§3.9a). **기본 chord 없음** — VSCode 의 `⇧⌥↓` 는 `⌘` 없는 `⌥` 라
    /// 터미널 Meta 입력을 뺏는다(configuration-input.md 가 그 부류를 소유한다).
    duplicate_lines,
    /// 걸친 블록을 위/아래 줄과 맞바꾼다(§3.9a). **기본 chord 없음** — 위와 같은 근거.
    move_lines_up,
    move_lines_down,
    /// 걸친 줄들을 한 단계 들여쓴다/내어쓴다(§3.9a). 선택이 여러 줄이면 `Tab`·`⇧Tab` 으로도 닿는다.
    indent_lines,
    outdent_lines,
    /// 선택(없으면 caret 의 낱말)을 대문자/소문자로 바꾼다(§3.9b). **기본 chord 없음** — 선례도
    /// 팔레트 전용이고, 남는 자리는 `⌘` 없는 `⌥` 뿐인데 그것은 터미널 Meta 입력을 뺏는다.
    transform_to_uppercase,
    transform_to_lowercase,
    // 활성 편집기 뷰의 랩(긴 줄 자동 줄바꿈)을 뒤집는다(visual-mapping §4 "가로 스크롤이 기본이고 랩은 토글").
    // **기본 chord가 없다** — VSCode의 `⌥Z`를 그대로 두면 터미널의 Meta-z를 전역으로 가져간다. 키 계약의
    // context-aware resolver에는 파일 트리·웹 편집기 컨텍스트만 있고 **편집기 Term 컨텍스트가 아직 없어서**,
    // 조건부로 양보할 자리가 없다(그 컨텍스트는 편집 입력이 붙는 N2의 몫이다). 그때까지는 커맨드 팝업과
    // 사용자 키바인딩으로 쓴다 — 아무 chord도 뺏지 않는다.
    toggle_editor_wrap,
    // 활성 편집기의 들여쓰기 접힘을 전부 접는다/펼친다(visual-mapping §4.1f). **기본 chord가 없다** —
    // VSCode의 `⌘K ⌘0`/`⌘K ⌘J`는 두 벌 chord라 키 계약에 그 개념이 없고, 랩 토글과 같은 이유로
    // 편집기 Term 컨텍스트가 아직 없어 조건부로 양보할 자리도 없다(N2의 몫). 그때까지는 커맨드
    // 팝업과 사용자 키바인딩으로 쓴다 — 아무 chord도 뺏지 않는다.
    fold_all,
    unfold_all,
    // 활성 편집기의 **본문 선택을 클립보드로** 복사한다(§4.1g). **기본 chord가 없다** — ⌘C는
    // 터미널 선택 복사가 이미 쓰고 있고, 편집기 Term 컨텍스트가 아직 없어 조건부로 양보할 자리가
    // 없다(위 `fold_all`과 같은 이유·같은 N2 몫). 그때까지는 커맨드 팝업과 사용자 키바인딩으로 쓴다.
    copy_editor_selection,
    // 활성 편집기에서 **지금 고른 것과 같은 다음 자리에 커서를 하나 더** 놓는다(VSCode `⌘D` —
    // native-editor-ui.md §9.1).
    //
    // **기본 chord가 `⌘⌃D`다 — 임시다**(2026-08-24 사용자 결정). §9.1은 편집기 포커스에서 `⌘D`가
    // 이것이라고 확정했지만, 그러려면 `FocusOwner`에 편집기 Term 칸이 있어야 한다(지금은
    // `.workspace`가 터미널·브라우저·파일 Term을 함께 담는다). 그 칸이 서기 전에 `⌘D`를 가져가면
    // **터미널에서 pane split이 사라진다.** 그래서 아무도 안 쓰는 chord로 먼저 열어 두고, 포커스
    // 컨텍스트가 서는 슬라이스에서 `⌘D`로 옮긴다.
    add_next_occurrence,
    jump_to_bracket,
    add_cursor_above,
    add_cursor_below,
    column_select_up,
    column_select_down,
    column_select_left,
    column_select_right,
    // 편집기의 **되돌리기·다시 하기**(§3.3 — 선형 스택, 연속 타이핑은 한 묶음).
    //
    // **기본 chord가 없다** — `⌘Z`는 터미널·웹 편집기 컨텍스트가 이미 쓰고, 편집기 Term 컨텍스트가
    // 서기 전에는 조건부로 양보할 자리가 없다(`copy_editor_selection`·`fold_all`과 같은 이유·같은
    // N2 몫). 그때까지는 커맨드 팝업과 사용자 키바인딩으로 쓴다.
    editor_undo,
    editor_redo,
    // 편집기 문서를 디스크에 쓴다(§3.5 — BOM·끝 개행을 연 그대로 되돌린다).
    //
    // **기본 chord가 없다** — `⌘S`는 파일 패널(CM6)이 이미 쓰고, 편집기 Term 컨텍스트가 서기
    // 전에는 조건부로 양보할 자리가 없다(같은 N2 몫). 그때까지는 커맨드 팝업과 사용자 키바인딩.
    editor_save,
    // 그 **중첩 레벨**의 블록만 접는다(VSCode `editor.foldLevelN`). 레벨 1이 문서 맨 바깥이다.
    // **셋까지만 낸다** — 커맨드 팝업 항목이 레벨마다 하나씩 늘고, 4단계보다 깊은 곳을 레벨로
    // 지목하는 일은 드물다(그 깊이는 전체 접기가 더 빠르다). VSCode는 7까지 두지만 그쪽은 chord로
    // 부르므로 목록을 늘리는 비용이 없다.
    fold_level_1,
    fold_level_2,
    fold_level_3,
    // 파일 안 심볼을 필터해 그 자리로 간다(VSCode `⇧⌘O` — Go to Symbol in File).
    // native-editor-ui.md §7.5 「피커는 팔레트를 다시 쓴다」.
    //
    // **찾기(⌘F)와 다른 축이다** — 찾기는 모든 글자에서 문자열을, 이쪽은 **심볼 이름만** 본다.
    // **기본 chord 는 아직 없다** — `editor_save` 와 같은 이유로 커맨드 팝업과 사용자 키바인딩으로 부른다.
    toggle_symbol_picker,
    // 스크롤백 Find의 다음/이전 매치로 이동(⌘G/⌘⇧G) — **오버레이가 닫혀 있어도** 동작한다(보존된 검색어로
    // 재검색해 네비게이션, macOS Find Next 관례). dispatchAppAction이 findNavigate로 넘긴다. 오버레이가 열린
    // 동안엔 모달 라우팅이 키를 가로채므로(Enter/Shift+Enter가 next/prev) 이 액션은 닫힌 경우를 위한 것이다.
    find_next,
    find_previous,
    // 런타임 폰트 크기 조절(⌘+/⌘-/⌘0). dispatchAppAction이 appearance.font.size를 바꾸고 cell 메트릭·grid를
    // 다시 잡는다(코어 resize와 같은 reflow). step은 AppSession 상수(1pt 고정 — 파라미터화는 후속). reset은
    // config 기본값(base_font_size)으로 되돌린다. 콘텐츠 reflow는 없다(셀 크기·grid 차원만 변경, Ghostty 동일).
    increase_font_size,
    decrease_font_size,
    reset_font_size,
    // maru CLI를 PATH(~/.local/bin/maru)에 설치한다(VS Code "Install 'code' command" 결). dispatchAppAction이
    // installCli로 넘겨 GUI 바이너리의 형제 `maru` CLI를 symlink한다(sudo 불요 user-level, 결과는 notice).
    // **카탈로그에 넣어 커맨드 팝업(Cmd+Shift+P)에 노출** — 기본 키바인딩은 없다(발견 경로=팝업). 단일 출처: cli/install.zig.
    install_cli,
    // **모든 설정을 내장 기본값으로** 초기화한다(통합 리셋). 메뉴 "Reset to Defaults"(ABI)와 이 팝업 액션 둘 다
    // requestResetAll로 확인 모달을 연 뒤, 확정 시 resetAllSettings가 loaded_config.config=기본값 재적용 + **config 파일
    // 삭제**한다(부분 write-back이 아닌 삭제라 비-schema 키·주석까지 전부 기본값). 커맨드 팝업에 노출, 기본 키바인딩 없음.
    reset_settings,
    // 런타임 폰트 크기를 절대값(pt)으로 지정한다. config 바인딩 전용(`set_font_size:18`처럼) — 절대값이라
    // 메뉴/팝업엔 안 넣는다(어느 크기인지 고정 못 함). dispatchAppAction이 setFontSize로 넘겨 [6,72]pt로 클램프.
    // 키 프리셋(예: ⌘⌥1=14, ⌘⌥2=18)을 사용자가 직접 묶을 수 있다.
    set_font_size: f32,
};

pub fn parseAction(value: []const u8) ?Action {
    // Action parsing lives away from theme/config structs because keybinding
    // grammar will grow independently from colors and font settings.
    if (std.mem.eql(u8, value, "new_tab")) return .new_tab;
    if (std.mem.eql(u8, value, "close_tab")) return .close_tab;
    if (std.mem.eql(u8, value, "previous_tab")) return .previous_tab;
    if (std.mem.eql(u8, value, "next_tab")) return .next_tab;
    if (std.mem.eql(u8, value, "split_horizontal")) return .split_horizontal;
    if (std.mem.eql(u8, value, "split_vertical")) return .split_vertical;
    if (std.mem.eql(u8, value, "focus_pane_left")) return .focus_pane_left;
    if (std.mem.eql(u8, value, "focus_pane_right")) return .focus_pane_right;
    if (std.mem.eql(u8, value, "focus_pane_up")) return .focus_pane_up;
    if (std.mem.eql(u8, value, "focus_pane_down")) return .focus_pane_down;
    if (std.mem.eql(u8, value, "previous_pane")) return .previous_pane;
    if (std.mem.eql(u8, value, "next_pane")) return .next_pane;
    if (std.mem.eql(u8, value, "move_pane_to_new_workspace")) return .move_pane_to_new_workspace;
    if (std.mem.eql(u8, value, "rename_workspace")) return .rename_workspace;
    if (std.mem.eql(u8, value, "rename_pane")) return .rename_pane;
    if (std.mem.eql(u8, value, "rename_term")) return .rename_term;
    if (std.mem.eql(u8, value, "create_group")) return .create_group;
    if (std.mem.eql(u8, value, "create_sibling_group")) return .create_sibling_group;
    if (std.mem.eql(u8, value, "ungroup")) return .ungroup;
    if (std.mem.eql(u8, value, "rename_group")) return .rename_group;
    if (std.mem.eql(u8, value, "remove_from_group")) return .remove_from_group;
    if (std.mem.eql(u8, value, "promote_to_top_level")) return .promote_to_top_level;
    if (std.mem.eql(u8, value, "new_term")) return .new_term;
    if (std.mem.eql(u8, value, "new_web_tab")) return .new_web_tab;
    if (std.mem.eql(u8, value, "open_file_panel")) return .open_file_panel;
    if (std.mem.eql(u8, value, "toggle_file_panel_dock_side")) return .toggle_file_panel_dock_side;
    if (std.mem.eql(u8, value, "toggle_file_panel_focus")) return .toggle_file_panel_focus;
    if (std.mem.eql(u8, value, "toggle_file_panel_mode")) return .toggle_file_panel_mode;
    if (std.mem.eql(u8, value, "focus_file_tree")) return .focus_file_tree;
    if (std.mem.eql(u8, value, "new_file")) return .new_file;
    if (std.mem.eql(u8, value, "new_directory")) return .new_directory;
    if (std.mem.eql(u8, value, "rename_file_tree_entry")) return .rename_file_tree_entry;
    if (std.mem.eql(u8, value, "delete_file_tree_entry")) return .delete_file_tree_entry;
    if (std.mem.eql(u8, value, "close_focused")) return .close_focused;
    if (std.mem.eql(u8, value, "close_term")) return .close_term;
    if (std.mem.eql(u8, value, "previous_term")) return .previous_term;
    if (std.mem.eql(u8, value, "next_term")) return .next_term;
    if (std.mem.eql(u8, value, "select_all")) return .select_all;
    if (std.mem.eql(u8, value, "clear_screen")) return .clear_screen;
    if (std.mem.eql(u8, value, "toggle_command_palette")) return .toggle_command_palette;
    if (std.mem.eql(u8, value, "toggle_settings")) return .toggle_settings;
    if (std.mem.eql(u8, value, "install_cli")) return .install_cli;
    if (std.mem.eql(u8, value, "toggle_find")) return .toggle_find;
    if (std.mem.eql(u8, value, "toggle_find_replace")) return .toggle_find_replace;
    if (std.mem.eql(u8, value, "toggle_find_match_case")) return .toggle_find_match_case;
    if (std.mem.eql(u8, value, "toggle_find_whole_word")) return .toggle_find_whole_word;
    if (std.mem.eql(u8, value, "toggle_find_in_selection")) return .toggle_find_in_selection;
    if (std.mem.eql(u8, value, "toggle_find_diff_side")) return .toggle_find_diff_side;
    if (std.mem.eql(u8, value, "outdent_lines")) return .outdent_lines;
    if (std.mem.eql(u8, value, "transform_to_uppercase")) return .transform_to_uppercase;
    if (std.mem.eql(u8, value, "transform_to_lowercase")) return .transform_to_lowercase;
    if (std.mem.eql(u8, value, "indent_lines")) return .indent_lines;
    if (std.mem.eql(u8, value, "move_lines_down")) return .move_lines_down;
    if (std.mem.eql(u8, value, "move_lines_up")) return .move_lines_up;
    if (std.mem.eql(u8, value, "duplicate_lines")) return .duplicate_lines;
    if (std.mem.eql(u8, value, "delete_lines")) return .delete_lines;
    if (std.mem.eql(u8, value, "toggle_editor_wrap")) return .toggle_editor_wrap;
    if (std.mem.eql(u8, value, "copy_editor_selection")) return .copy_editor_selection;
    if (std.mem.eql(u8, value, "add_next_occurrence")) return .add_next_occurrence;
    if (std.mem.eql(u8, value, "jump_to_bracket")) return .jump_to_bracket;
    if (std.mem.eql(u8, value, "add_cursor_above")) return .add_cursor_above;
    if (std.mem.eql(u8, value, "add_cursor_below")) return .add_cursor_below;
    if (std.mem.eql(u8, value, "column_select_up")) return .column_select_up;
    if (std.mem.eql(u8, value, "column_select_down")) return .column_select_down;
    if (std.mem.eql(u8, value, "column_select_left")) return .column_select_left;
    if (std.mem.eql(u8, value, "column_select_right")) return .column_select_right;
    if (std.mem.eql(u8, value, "editor_undo")) return .editor_undo;
    if (std.mem.eql(u8, value, "editor_redo")) return .editor_redo;
    if (std.mem.eql(u8, value, "editor_save")) return .editor_save;
    if (std.mem.eql(u8, value, "fold_all")) return .fold_all;
    if (std.mem.eql(u8, value, "unfold_all")) return .unfold_all;
    if (std.mem.eql(u8, value, "fold_level_1")) return .fold_level_1;
    if (std.mem.eql(u8, value, "fold_level_2")) return .fold_level_2;
    if (std.mem.eql(u8, value, "fold_level_3")) return .fold_level_3;
    if (std.mem.eql(u8, value, "toggle_symbol_picker")) return .toggle_symbol_picker;
    if (std.mem.eql(u8, value, "find_next")) return .find_next;
    if (std.mem.eql(u8, value, "find_previous")) return .find_previous;
    if (std.mem.eql(u8, value, "increase_font_size")) return .increase_font_size;
    if (std.mem.eql(u8, value, "decrease_font_size")) return .decrease_font_size;
    if (std.mem.eql(u8, value, "reset_font_size")) return .reset_font_size;
    if (std.mem.eql(u8, value, "reset_settings")) return .reset_settings;

    const prefix = "select_tab:";
    if (std.mem.startsWith(u8, value, prefix)) {
        const index = std.fmt.parseUnsigned(usize, value[prefix.len..], 10) catch return null;
        return .{ .select_tab = index };
    }

    const mpw_prefix = "move_pane_to_workspace:";
    if (std.mem.startsWith(u8, value, mpw_prefix)) {
        const index = std.fmt.parseUnsigned(usize, value[mpw_prefix.len..], 10) catch return null;
        return .{ .move_pane_to_workspace = index };
    }

    const fs_prefix = "set_font_size:";
    if (std.mem.startsWith(u8, value, fs_prefix)) {
        const size = std.fmt.parseFloat(f32, value[fs_prefix.len..]) catch return null;
        if (!std.math.isFinite(size)) return null; // nan/inf 거부(std.meta.eql 비교·클램프 안전)
        return .{ .set_font_size = size };
    }

    return null;
}

/// 전역(OS) 단축키 전용 동작 — 앱이 비활성이어도 OS가 단축키를 잡아 Swift가 수행한다. 창 가시성 같은
/// NSWindow 동작이라 Zig의 `dispatchAppAction`(터미널/탭 조작)이 할 수 없다. 그래서 in-app `Action`과
/// 분리한다(별도 enum — `dispatchAppAction`의 exhaustive switch를 오염시키지 않는다. unbind와 같은 결정).
pub const GlobalAction = enum {
    toggle_window, // 창이 숨김/비활성이면 보이고 앞으로(show+activate), 활성+보임이면 숨김(orderOut) — 진짜 토글.
    show_window, // 항상 창을 보이고 앞으로 가져온다(숨기지 않음).
    toggle_quick_terminal, // quick terminal(별도 세션 오버레이 패널)을 토글한다 — 숨김이면 보이고, 보임이면 숨김.
};

/// 전역 단축키 동작 문자열을 파싱한다(`global:<chord> = <여기>`). 알 수 없으면 null(forgiving).
pub fn parseGlobalAction(value: []const u8) ?GlobalAction {
    if (std.mem.eql(u8, value, "toggle_window")) return .toggle_window;
    if (std.mem.eql(u8, value, "show_window")) return .show_window;
    if (std.mem.eql(u8, value, "toggle_quick_terminal")) return .toggle_quick_terminal;
    return null;
}

test "parse configured actions" {
    try std.testing.expectEqual(Action.new_tab, parseAction("new_tab").?);
    try std.testing.expectEqual(Action.close_tab, parseAction("close_tab").?);

    try std.testing.expectEqual(Action.split_horizontal, parseAction("split_horizontal").?);
    try std.testing.expectEqual(Action.split_vertical, parseAction("split_vertical").?);
    try std.testing.expectEqual(Action.focus_pane_left, parseAction("focus_pane_left").?);
    try std.testing.expectEqual(Action.focus_pane_down, parseAction("focus_pane_down").?);
    try std.testing.expectEqual(Action.move_pane_to_new_workspace, parseAction("move_pane_to_new_workspace").?);
    try std.testing.expectEqual(Action.rename_workspace, parseAction("rename_workspace").?);
    try std.testing.expectEqual(Action.rename_pane, parseAction("rename_pane").?);
    try std.testing.expectEqual(Action.rename_term, parseAction("rename_term").?);
    try std.testing.expectEqual(Action.create_group, parseAction("create_group").?);
    try std.testing.expectEqual(Action.create_sibling_group, parseAction("create_sibling_group").?);
    try std.testing.expectEqual(Action.ungroup, parseAction("ungroup").?);
    try std.testing.expectEqual(Action.rename_group, parseAction("rename_group").?);
    try std.testing.expectEqual(Action.remove_from_group, parseAction("remove_from_group").?);
    try std.testing.expectEqual(Action.promote_to_top_level, parseAction("promote_to_top_level").?);
    try std.testing.expectEqual(Action.new_term, parseAction("new_term").?);
    try std.testing.expectEqual(Action.new_web_tab, parseAction("new_web_tab").?);
    try std.testing.expectEqual(Action.open_file_panel, parseAction("open_file_panel").?);
    try std.testing.expectEqual(Action.toggle_file_panel_dock_side, parseAction("toggle_file_panel_dock_side").?);
    try std.testing.expectEqual(Action.focus_file_tree, parseAction("focus_file_tree").?);
    try std.testing.expectEqual(Action.new_file, parseAction("new_file").?);
    try std.testing.expectEqual(Action.new_directory, parseAction("new_directory").?);
    try std.testing.expectEqual(Action.rename_file_tree_entry, parseAction("rename_file_tree_entry").?);
    try std.testing.expectEqual(Action.delete_file_tree_entry, parseAction("delete_file_tree_entry").?);
    try std.testing.expectEqual(Action.close_focused, parseAction("close_focused").?);
    try std.testing.expectEqual(Action.close_term, parseAction("close_term").?);
    try std.testing.expectEqual(Action.next_term, parseAction("next_term").?);
    try std.testing.expectEqual(Action.previous_term, parseAction("previous_term").?);
    try std.testing.expectEqual(Action.select_all, parseAction("select_all").?);
    try std.testing.expectEqual(Action.clear_screen, parseAction("clear_screen").?);
    try std.testing.expectEqual(Action.toggle_command_palette, parseAction("toggle_command_palette").?);
    try std.testing.expectEqual(Action.toggle_find, parseAction("toggle_find").?);
    try std.testing.expectEqual(Action.find_next, parseAction("find_next").?);
    try std.testing.expectEqual(Action.find_previous, parseAction("find_previous").?);
    try std.testing.expectEqual(Action.increase_font_size, parseAction("increase_font_size").?);
    try std.testing.expectEqual(Action.decrease_font_size, parseAction("decrease_font_size").?);
    try std.testing.expectEqual(Action.reset_font_size, parseAction("reset_font_size").?);

    const action = parseAction("select_tab:3").?;
    try std.testing.expectEqual(@as(usize, 3), action.select_tab);

    // move_pane_to_workspace:N — 활성 pane을 N번 워크스페이스에 합치기(파라미터 액션, 0-based).
    try std.testing.expectEqual(@as(usize, 2), parseAction("move_pane_to_workspace:2").?.move_pane_to_workspace);
    try std.testing.expect(parseAction("move_pane_to_workspace:abc") == null);
    try std.testing.expect(parseAction("move_pane_to_workspace:") == null);
    try std.testing.expect(parseAction("unknown") == null);

    // set_font_size:N — 절대 폰트 크기(파라미터 액션). 정수·소수 모두, 비숫자·비유한은 null.
    try std.testing.expectEqual(@as(f32, 18), parseAction("set_font_size:18").?.set_font_size);
    try std.testing.expectEqual(@as(f32, 13.5), parseAction("set_font_size:13.5").?.set_font_size);
    try std.testing.expect(parseAction("set_font_size:abc") == null);
    try std.testing.expect(parseAction("set_font_size:") == null);
    try std.testing.expect(parseAction("set_font_size:inf") == null); // 비유한 거부
}

test "parse global actions" {
    try std.testing.expectEqual(GlobalAction.toggle_window, parseGlobalAction("toggle_window").?);
    try std.testing.expectEqual(GlobalAction.show_window, parseGlobalAction("show_window").?);
    try std.testing.expectEqual(GlobalAction.toggle_quick_terminal, parseGlobalAction("toggle_quick_terminal").?);
    try std.testing.expect(parseGlobalAction("new_tab") == null); // in-app action은 전역 동작이 아님
    try std.testing.expect(parseGlobalAction("unknown") == null);
}
