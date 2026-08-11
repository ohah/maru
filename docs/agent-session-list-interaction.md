# 에이전트 세션 도크 — 선택·확장·geometry (§2.2)

카드 선택과 확장, 그 geometry 계약이다. 카드가 **어떻게 그려지는지**는 [카드 레이아웃](agent-session-list-layout.md)이 소유한다.

> **절 번호는 파일을 넘어 이어진다.** 본문이 `§2.1.3`처럼 절만 가리키면 아래에서 소유 파일을 찾는다 — §1~§2·§2.3·§3~§5·§7~§8 [agent-session-list.md](agent-session-list.md) · §2.1~§2.1.3 [카드 레이아웃](agent-session-list-layout.md) · §2.2 [선택·확장·geometry](agent-session-list-interaction.md) · §2.1.4·§6 [구현 계획](plans/agent-session-list.md)

### 2.2 선택·확장·geometry 계약

- `SessionDockProps`는 `expanded_identity: ?ArchiveIdentity`와 그 identity에만 결합된
  immutable `ExpandedSessionProps`를 받는다. `selected` boolean만으로 expanded를
  추측하거나 row index를 persistent identity로 쓰지 않는다. snapshot generation 또는
  `(provider, session_id, device, inode)`가 달라지면 expansion/capture/focus/action table을
  함께 폐기한다.
- `SessionDockLayout`은 기본 card와 expanded card의 높이, 내부 recent-turn card,
  tool/permission summary, action row, divider, scrollbar을 **한 번** 계산한다. view, clip, pointer hit-test,
  keyboard focus, visible row window, scroll anchor가 같은 completed tree를 쓴다. 선택 행의
  content만 host가 별도 y-offset으로 덧그리거나 click rect를 재계산해서는 안 된다.
- expanded height는 최대 3 recent-turn slot, summary slot, action row의 **고정된 예약 높이**에서
  결정한다. ready content가 짧으면 turn slot 안에서만 빈 영역을 줄이고, loading/stale/unavailable도
  같은 outer rect와 action slots를 유지해 pointer target이 frame마다 점프하지 않게 한다.
  recent turn은 최대 3개이며, tool/permission summary가 없으면 그 section을 숨기되 action row와
  outer padding은 남긴다. nested subagent transcript/목록은 provider 입력 정책과 개인정보 범위 밖이므로
  expansion에 투영하지 않는다. 따라서 모든 세션을 미리 detail parse하거나
  모든 행을 항상 큰 card로 만들지 않는다.
- anchor가 expanded card보다 위이면 open/close가 같은 anchor의 screen y를 보존한다. anchor가
  선택 card 자신이면 title row가 content clip 안에 남도록 최소 scroll만 보정한다. group collapse,
  filter/scope 변경, snapshot identity 교체는 expansion을 닫고 기존 AS3-c identity-first fallback을
  적용한다. 숫자 offset만으로 이전 expanded row를 추측해 다시 열지 않는다.
- title/summary/metadata는 기본 행의 기존 typography role을 유지하되, selected title row는
  title·chevron·more action의 visual center를 같은 baseline artifact로 정렬한다. expansion의
  role label, body, pill, button은 비례 font의 measured advance와 line-height를 사용한다.
  terminal cell count나 fallback glyph ink에 맞추어 label별 nudge를 두지 않는다.
- pointer/Enter는 card disclosure만 toggle하며 provider를 실행하지 않는다. `터미널에서 이어하기`,
  `로그 보기`, `열린 세션으로 이동`은 expanded action table의 distinct enabled intent여야 한다.
  `⌘↵`/`⌘L`은 expanded ready state에서만 같은 intents를 호출하며, closed/loading/stale state에서는
  no-op이다. Escape는 search를 먼저 닫고, 그 다음 expanded card를 닫는다.

- header의 `로컬`은 현재 사용자 홈 아래 provider log만 읽는다는 provenance label이며 host 선택기가 아니다. 정렬 방향은 header의 토글이 정하고(§2.3), 키는 transcript의 마지막 활동 시각이다. 탭 재진입은 현재 앱 실행 중의 snapshot을 즉시 보이고, 마지막 완료 scan 뒤 **15초** 안이면 새 refresh를 시작하지 않는다. `SessionDockHeader`의 refresh control은 이 TTL을 우회한다. worker가 실행 중이면 동일 rect의 muted registered refresh/disabled state로 바뀌고 추가 job을 만들지 않는다.
- 도크 view bar의 `AI 세션`을 누르면 archive refresh를 요청한다. **refresh 중에는 직전 완료 snapshot과 current scroll/selection을 그대로 paint하고, 새 bounded scan 전체가 끝난 뒤에만 새 immutable snapshot으로 한 번에 교체한다.** AS3-c부터 교체 commit은 first partially-visible card의 exact identity와 intra-card pixel offset을 restore하고, identity가 없으면 기존 numeric offset만 새 상한에 clamp한다. 결과 큐의 OOM 등 새 snapshot을 publish할 수 없는 완료는 spinner만 끝내고 기존 목록과 scroll/selection을 유지하며 notice를 보인다. 따라서 새로 고침이 기존 목록을 비우거나 첫 record/중간 batch로 목록을 흔들지 않는다. 첫 진입처럼 이전 snapshot이 없을 때만 skeleton/진행 문구를 보이며, frame tick에서 파일 I/O를 하지 않는다. 창 재포커스와 새 provider session identity 감지는 같은 refresh를 요청하되, forced refresh는 5초 전역 throttle로 합친다. filesystem polling/watcher는 v1에 없다.
- scope는 `현재 작업공간`, `현재 프로젝트`, `전체`다. 기본값은 `전체`이며 마지막 선택만 창 UI 상태로 보존한다. **`현재 작업공간`은 활성 워크스페이스 탭의 활성 local Term이 마지막으로 보고한 CWD를 worker가 canonicalize한 단일 root snapshot 아래에 `cwd`가 있는 기록**이다. 창 전역 탐색기 root와 다른 권위이므로, 다른 워크스페이스 탭의 폴더가 섞이지 않는다. `현재 프로젝트`는 같은 active Term CWD에서 worker가 찾은 canonical git root 아래 `cwd`가 있는 기록이며, local CWD 또는 git root가 없으면 각각 비활성화한다. `전체`는 모든 provider의 검증된 사용자 세션이다. remote/불명 `cwd`는 전체에서만 보인다. 도크 진입, scope click, 활성 workspace/pane/Term 전환 **및 같은 활성 pane의 CWD 보고 변경**에서 root snapshot을 갱신하며, 결과가 오기 전에는 이전 tab 또는 이전 CWD의 범위를 재사용하지 않는다. CWD 비교는 main actor의 메모리 observation만 사용하고 canonicalize·git walk는 worker만 수행한다. 이후 scope/search/scroll/frame은 그 메모리 snapshot만 읽는다.
- 이 필터는 접근 제어가 아닌 표시 범위다. 경로는 provider log의 `cwd`를 canonicalize할 수 있을 때만 containment 비교하며, 실패·삭제·비로컬 값은 workspace/project에 억지로 넣지 않는다.
- 검색은 이미 publish된 snapshot만 대상으로 한다. search field click 또는 `/`가 `query + IME preedit` 입력 owner를
  활성화한다. marked text는 field와 native IME 후보창에만 즉시 보이고, commit된 query만 목록 필터를 바꾼다.
  Esc는 query/preedit를 함께 지우고 닫으며, Backspace는 UTF-8 codepoint 경계를 지킨다. UTF-8 byte substring
  (ASCII만 case-insensitive)으로 제목·요약·cwd leaf·branch·model을 찾고 입력은 256 byte로 자른다. 검색 키·IME
  입력은 재스캔·파일 stat·정렬을 일으키지 않으며 terminal PTY로 새지 않는다. 한국어처럼 case가 없는 문자열은 정확 byte
  match로 검색된다.
- 최근 window는 provider를 합쳐 mtime 내림차순 최대 500 **검증 완료** 세션이다. 후보 탐색 상한 또는 parser byte budget 때문에 더 오래된 항목을 보장하지 않으므로 header와 empty state는 항상 `최근`이라고 말하고 `전체 이력`이라고 주장하지 않는다.
- fixed chrome은 header·scope segmented control·검색뿐이다. scope control은 **그룹 헤더가 아니며**, 목록 본문을 밀거나 선택된 세션의 detail/action으로 대체하지 않는다. 목록의 workspace/project 그룹만 본문에서 독립적으로 접고 펼친다.
- 기본 그룹은 canonical `cwd`의 프로젝트/폴더 이름이다. cwd가 없거나 project 밖이면 `알 수 없는 위치` 한 그룹으로 낸다. 각 그룹 header는 chevron·이름·표시 개수를 갖고 click/Left/Right로 접고 편다. 접힌 그룹은 header만 남기며 다른 그룹과 고정 chrome의 위치는 바꾸지 않는다. 그룹 접힘은 현재 view 수명 안에서만 유지하며 JSONL이나 workspace에 저장하지 않는다.
- 세션 행은 **세 줄 카드**다: 제목과 provider badge, 마지막 사용자 요청의 안전한 짧은 요약, 메시지 수·상대 시각·model metadata. 카드 내부의 provider/title/summary를 한 줄 label로 합치거나 raw JSONL line을 그대로 표시하지 않는다. 행 제목은 provider 고유 제목이 있으면 그것, 없으면 첫 신뢰 가능한 사용자 요청의 single-line prefix(최대 120 display bytes), 끝내 없으면 `제목 없는 세션`이다. 요약은 마지막 사용자 요청 우선, 없으면 마지막 assistant text의 single-line prefix(최대 240 display bytes)다. raw escape/control byte·경로 외 홈 사용자명은 렌더 전에 제거/일반화하며 Markdown/ANSI를 해석하지 않는다.
- `메시지 n개`는 전체 파일을 budget 안에서 끝까지 분석한 경우만 정확한 수다. cap에 걸리면 `메시지 ≥n개`, 아직 분석하지 않았으면 메시지 수를 생략한다. 숫자를 추정치처럼 표시하지 않는다.
- 한 번 클릭/Enter는 provider를 실행하지 않고 **도크 안의 해당 card를 확장**한다. 도크 목록의 fixed header/scope/search는 움직이지 않으며, expanded detail/action은 선택 row 바로 아래 같은 scroll area 안에만 나타난다. expansion은 PTY 없는 Metal-rendered read-only component이고, 먼저 `세션 분석 중` 상태가 되어도 UI를 막지 않는다. detail worker가 source를 no-follow로 다시 열어 `(device,inode)`를 대조한 뒤 마지막 **512 KiB** 안의 완결 JSONL record만 해석해, 안전하게 정규화한 최근 세 user/assistant turn과 `도구/권한 관련 record n건`처럼 원문을 숨긴 action 요약만 publish한다. raw JSONL·tool payload·환경 변수·명령 출력의 전체 원문은 expansion에 넣지 않는다. tail 밖의 더 오래된 대화·불완전 마지막 JSON line은 의도적으로 표시하지 않는다.
- expansion의 `터미널에서 이어하기`와 `로그 보기`는 명시 action이다. 각각 `⌘↵`, `⌘L`로 실행하고 ready action row에 shortcut을 보조 정보로 표시한다. `로그 보기`는 source-reveal만 수행하고, raw JSONL을 terminal에 paste하거나 WebView에 trusted content로 넣지 않는다. 같은 identity를 다시 선택하면 expansion을 닫고, 다른 identity를 선택하면 먼저 이전 expansion의 detail request/action capture를 폐기한 뒤 새 하나를 연다. snapshot 교체 뒤 source identity가 달라지거나 detail worker가 재검증에 실패하면 expansion은 stale 상태로 남기고 resume/reveal을 비활성화한다.
- `터미널에서 이어하기`는 사용자가 그 명시 버튼을 누르는 즉시 새 local Term 탭을 만들고 활성화한다(추가 확인 dialog 없음). shell 없이 정확한 argv로 실행한다: Claude는 `claude --resume <session-id>`, Codex는 `codex resume <session-id>`. 실행 cwd는 archive record의 canonical local cwd가 아직 directory일 때만 쓰며, 아니면 새 Term의 기본 cwd와 함께 "원래 cwd를 찾지 못함"을 보여 준다. 기존 Term에 키를 주입하지 않는다. 이 action은 worktree를 생성·선택·변경하지 않는다.
- open live Term과 provider+session id가 정확히 일치하면 expansion에 **부가 동작**으로 `열린 세션으로 이동`을 제공한다. 이것은 archive 후보 선정·정렬·표시를 바꾸지 않으며, 일치하지 않는 과거 세션도 완전히 같은 행으로 보인다. mapping은 live session identity가 다시 검증된 경우만 만들며 path/mtime 유사성으로 추정하지 않는다.
- 새 focus owner `agent_session_list`가 선택 identity `{ provider, session_id, source_file_identity }`를 소유한다. Up/Down, PageUp/PageDown, Home/End는 보이는 카드를 움직이고, Right/Left는 그룹을 펼치고 접으며, Enter는 selected card expansion을 toggle한다. Escape는 search focus를 먼저 해제하고 그 다음 expansion을 닫는다. 도크를 떠나거나 snapshot 교체 뒤 identity가 사라지면 선택과 expansion을 해제한다. `⌘⇧E`는 기존대로 탐색기로 돌아간다.
  이 키들은 **도크가 실제로 키보드를 갖고 있을 때만** 도크 동작이다. 소유권은 도크 안 primary down이 주고,
  도크 밖 primary click·view 전환·도크 접기/펴기가 놓는다(선택·expansion·scroll 위치는 유지). 도크가 보이는
  것만으로는 부족하다 — 선택된 카드가 남아 있다는 이유로 터미널에서 친 Enter를 도크가 가져가면 셸의 명령
  실행이 조용히 사라진다. 수식키 없는 `/`(도크 검색 열기)와 `Escape`(expansion 닫기)도 같은 게이트를 쓴다 —
  전자는 경로·정규식 타이핑의 첫 글자를, 후자는 vim의 Esc를 삼킨다. 반면 `⌘↵`/`⌘L`은 어떤 경우에도 PTY
  바이트가 아니라 앱 명령이므로 이 focus 게이트를 쓰지 않는다. 대신 **소비는 실행의 결과여야 한다**:
  published ready expansion이 없어 실행할 것이 없으면 키를 삼키지 않고 keybind resolver로 흘려보낸다.
  삼키면 메뉴 항목이 없는 액션 바인딩과 터미널 매크로(`keybind = Cmd+L = text:…`)가 조용히 죽는다
  (메뉴 항목이 있는 액션은 AppKit keyEquivalent가 먼저 가져가 이 경로에 오지 않는다).
  도크 검색은 **소유권을 놓을 때 함께 blur**한다(사이드바 검색의 blur와 같은 규율 — 비활성만 하고 검색어는
  보존, 조합 중이던 IME preedit는 확정). 검색은 활성인 동안 모든 키를 소비하므로, blur가 없으면 터미널로
  돌아온 뒤의 타이핑 **전체**가 도크 검색으로 들어간다. 완전히 비우는 것은 Esc의 몫으로 남는다.
  이 소유권은 **session-level 상태**여야 한다. 도크의 component-local `InteractionState.focused`는 published
  node id라, 카드를 여는 바로 그 클릭이 snapshot을 무효화하면서(그리고 action이 `item` → `card_header`로
  옮겨가면서) 지워진다 — 그 값으로 판정하면 카드를 연 직후 Enter로 다시 접을 수 없다.
  view bar로 `AI 세션`을 켜는 것은 소유권을 주지 않는다(도크 **내용**을 누른 게 아니다). 따라서 도크를 막
  연 뒤의 `/`는 터미널 입력이며, 도크 검색은 한 번 클릭한 뒤에 연다.
