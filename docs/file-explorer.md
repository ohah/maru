# 파일 탐색기 (도크 트리·watcher·root)

창 레벨 도크에 사는 **파일 탐색기**(프로젝트 트리)의 단일 출처 문서다. 트리의 root 모델·스캔·감시·선택·키보드 탐색·파일 변경 명령을 소유한다.

> **[파일 패널](file-panel.md)과의 경계**: 파일 *콘텐츠*(뷰어/편집기)는 워크스페이스 pane 트리의 `Term`으로 살고 그 계약은 file-panel.md가 소유한다. 이 문서는 도크의 **파일 탐색기 콘텐츠**만 다룬다(FP16에서 파일 콘텐츠를 보관하던 별도 도크 그룹은 없어졌으며, 도크의 다른 view는 각자 문서가 소유한다). 두 문서가 만나는 지점은 셋이다 — ⑴ 트리에서 파일을 열면 [file-panel.md §6](file-panel.md#6-열기-규칙)의 열기 규칙을 탄다, ⑵ 도크 배치·표시 상태와 root 영속은 [file-panel.md §5.1](file-panel.md#51-도크트리-포맷-현행--레거시-읽기-경로)의 workspace.v1 포맷이 소유한다, ⑶ 트리↔터미널 입력 포커스 왕복은 [file-panel.md §3.4](file-panel.md#34-terminal파일-도크-입력-포커스-표시왕복)가 소유한다.
>
> 진행·검증 상태는 이 문서가 아니라 [검증 매트릭스](verification-matrix.md)의 "파일 패널 FP7" 행과 "파일 도크 닫기·트리 키보드·파일 변경" 행이 소유한다.


## 1. 활성 터미널 cwd 따라가기 (ET-CWD, 2026-07-28 사용자 요청)

활성 터미널의 작업 디렉터리가 바뀌면 탐색기가 **그 자리를 펼쳐 보여준다**(reveal). 사용자 요청은 "탐색기가 활성 터미널 베이스 경로를 따라가면 좋겠다"였고, 구현 모델은 **root 교체가 아니라 reveal**이다.

**왜 root를 갈지 않는가.** `replaceExplicitRoots`는 주석 그대로 *"기존 expanded snapshot은 root 변경의 correctness 권위가 아니므로 버리고 새 lazy scan을 예약한다"* — 즉 root 교체는 **접힘·펼침 상태를 통째로 버리고** `root_generation`을 올리며 watcher를 재등록한다. cwd는 `cd` 한 번에 바뀌는 값이라, 그걸 root에 묶으면:

| 문제 | 내용 |
| --- | --- |
| 상태 소실 | `cd`마다 트리가 접히고 재스캔 + watcher 재등록(debounce 200ms) — 디렉터리를 오가는 작업에서 트리가 계속 깜빡인다 |
| 대상 모호 | 도크는 **창 전역**인데 cwd는 **Term별**이다. split이 셋이면 cwd가 셋이고, pane 포커스만 옮겨도 트리가 갈린다 |
| 비-로컬 cwd | OSC 7을 안 쏘는 셸은 관측이 비고, `maru ssh` 원격 세션은 **로컬에 없는 경로**를 준다 |
| 원치 않은 스캔 | `cd ~`·`cd /` 한 번에 홈·루트 전체가 root가 된다 |
| 영속 충돌 | `explicit` root는 `dock-tree-roots`로 저장된다 — 따라가기가 그걸 덮으면 재시작 시 **고른 적 없는 root**가 복원된다 |

reveal은 이 다섯을 전부 피한다: root·접힘·watcher·영속을 **하나도 건드리지 않고** 해당 경로의 ancestor만 펼친다.

**정책(4가지)**

1. **어느 cwd인가** — 활성 워크스페이스 → 활성 pane → 활성 Term의 관측 cwd. 그 Term이 파일·브라우저라 cwd가 없으면 **직전 값을 유지**한다(비우지 않는다 — 문서를 보다 터미널로 돌아왔을 때 트리가 리셋되면 안 된다).
2. **언제 reveal하나** — cwd가 **변할 때만**, 그리고 도크가 보일 때만. 같은 값이 다시 관측되면 무동작이다(관측은 폴링이라 매 tick 같은 값이 온다).
3. **root 밖이면 아무것도 하지 않는다** — 자동으로 root를 추가하지 않는다(위 표의 "원치 않은 스캔"·"영속 충돌"이 그대로 돌아온다). 사용자가 명시적으로 폴더를 열면 기존 `inferred` 경로가 root를 잡는다.
4. **스크롤은 필요할 때만 뺏는다** — 대상 행이 이미 **온전히** 보이면 스크롤을 건드리지 않는다. 뷰포트 밖이거나 부분적으로만 걸쳐 있을 때만 그 행이 보이도록 최소한으로 맞춘다(좌표가 픽셀이라 "보인다"의 기준이 행 경계가 아니다 — §3.1).

**메커니즘은 새로 만들지 않는다.** 트리에는 이미 Zed형 auto-reveal(`reveal_path` + `continueReveal`)이 있고 파일을 열 때 그 경로를 쓴다 — 보이는 ancestor를 순서대로 펼치며 안 읽은 폴더만 lazy scan하고, 대상에 도달하거나 없으면 intent를 끝내 무한 재시도를 막는다. cwd 따라가기는 **그 intent에 디렉터리 경로를 넣는 것**이 전부다(디렉터리가 대상이면 그 폴더 자체까지 펼친다).

**남는 것(이 슬라이스 밖)**: root 밖 cwd에 대한 "이 폴더를 루트로 추가" 어포던스, 끄기 위한 config 키. 둘 다 실사용 근거가 생기면 한다(measure-first) — 지금은 reveal이 비파괴적이라 끌 이유가 약하다.

자동 gate는 pane/Term 전환, 같은 pane의 `cd`, root 밖 no-op, visible target 무스크롤, lazy reveal 완료/취소, explicit root·watcher 불변을 포함한다.

## 2. root 모델과 열기 UX

**탐색기 열기와 root 권위(ABI v137)**: 빈 도크 launcher는 `DockPanel.presented=true, collapsed=false`만 만들며 picker를 열지 않는다. `file_tree.Tree.mode`는 `inferred | explicit`이다. inferred에서는 `openFilePanelPath`가 파일의 git root(없으면 부모)를 합류시키고, explicit에서는 root 밖 파일을 열어도 recent MRU만 갱신한다. context menu의 `폴더 열기…`는 선택 directory 하나로 explicit root snapshot을 교체하고, `작업공간에 폴더 추가…`는 현재 보이는 root를 보존해 explicit으로 전환하며, root row의 `작업공간에서 폴더 제거`는 마지막 root도 제거해 explicit-empty를 유지한다. 이 open/add/remove UX는 VS Code workspace·multi-root workspace를 clean-room 행동 기준으로 삼고, 기존 Zed 기준은 scan/sort/exclusion/lazy expansion에만 유지한다.

root picker callback은 path를 소유한 bounded backend request만 제출한다. worker는 `.`/`..`·trailing slash를 정리한 절대 UTF-8 path를 directory fd로 열고 `realpath`와 device/inode/kind를 얻어 symlink/case/Unicode alias를 canonical target 하나로 합친다. 모델/wire/watch/mutation root는 이 canonical path와 pinned identity를 공유하고 commit 직전 descriptor-relative/no-follow 재검증을 거친다. 2차 검증이 연 no-follow directory descriptor는 결과에 retained capability로 남아 main actor의 fallible staging을 통과한 뒤 **no-fail publish 직전에 그 exact root의 첫 scan job으로 소유권이 이전**되며, 첫 scan은 path를 다시 열지 않는다. 첫 scan 뒤 materialized file row 활성화는 pinned root identity부터 parent component까지 descriptor-relative/no-follow로 다시 열고, 최종 leaf를 `O_NONBLOCK|O_NOFOLLOW` regular-file fd로 연 뒤 같은 fd의 identity가 row snapshot과 일치할 때만 승인한다. 이 leaf capability는 Markdown/HTML 도크 commit 또는 비지원 파일 external-open one-shot admission이 끝날 때까지 유지한다. 새 Markdown entry는 row identity를 transient initial-hydration token으로도 보존하고, bridge read가 path를 `O_NOFOLLOW`로 연 같은 fd의 identity를 대조해 교체됐으면 bytes를 commit하지 않는다. symlink/FIFO/device/socket/directory row, identity 없는 row, stale root/leaf는 fail-closed한다. HTML `loadFileURL`과 비지원 파일 `NSWorkspace.open`은 공개 API가 pathname만 받아 admission 뒤 동일 UID가 다시 namespace를 바꾸는 경쟁을 원자적으로 막을 수 없으므로, 해당 **admission 이후 race는 명시적 위협 경계 밖**이다. main actor는 commit 직전에 **현재 live dock entry/recent 집합**으로 projected rows와 safety watcher union을 다시 fallible staging한 뒤 root/rows/watch를 한 번에 swap하고, old tree는 row swap 뒤 해제한다. 그래서 validation 중 open/close가 바뀌어도 stale entry snapshot을 publish하지 않는다. merge/restore/rename은 root pending을 포함한 `fileTreeNamespaceMutationBusy`로 거부한다. `Tree.root_generation`은 성공 publish 뒤에만 증가하고 context target과 scrollbar drag가 이를 snapshot한다. scan completion은 기존 backend generation retirement로 거부한다. picker request는 request id와 expected root generation을 함께 가져 cancel/invalid/cap/OOM/stale completion이 root/watch/rows/selection/presented와 열린 entry를 바꾸지 않게 한다. namespace mutation이 waiting/inflight/trash rollback/manual recovery 중이면 picker 진입과 replace/add/remove commit을 busy로 거부하고, root validation/publish가 pending인 동안에는 create/rename/delete/merge/restore를 거부한다. root completion은 tick당 최대 하나만 apply하며 frame tick의 blocking path lookup/read는 0이다. 완료 result의 descriptor close처럼 비차단 수명 정리 syscall은 main actor에서 수행할 수 있다.

표시 root를 교체해도 열린 entry·active group·dirty/conflict/editor buffer는 byte-for-byte 보존한다. 외부 변경 안전 watcher set은 표시 root와 별개로 `explorer roots ∪ 모든 열린 dock entry를 덮는 최소 parent/root`를 사용해 root 밖 열린 파일도 계속 감시하고, 마지막 entry close 뒤 불필요한 safety root만 제거한다. watcher union의 cap/OOM도 기존 watcher set을 유지한다. safety roots는 표시하거나 workspace에 저장하지 않는다. inferred open은 tree/recent/dock entry에 필요한 allocation을 먼저 staging한 뒤 한 번에 commit해 OOM 시 부분 root/recent가 남지 않는다.

**빈 영역·context menu**: 논리적 emptiness의 authority는 projection row 수가 아니라 `Tree.hasContent()==false`다. 그 상태의 empty placeholder 또는 trailing content background primary-click만 기존 Markdown/HTML file picker one-shot을 요청한다. zero-count recent header와 tree header는 primary-click으로 picker를 열지 않고, populated tree의 row 밖 여백도 no-op이다. tree header와 row 밖 여백의 secondary-click은 `파일 열기… | 폴더 열기… | 작업공간에 폴더 추가…`를 연다. root row menu는 기존 새 파일/새 폴더에 root 추가/제거를 더하고, file/directory row의 rename/Trash 계약은 유지한다. context target은 path identity와 `Tree.root_generation`을 함께 들고 accept 직전 다시 조회한다.

## 3. 렌더 — 스크롤바·아이콘

### 3.1 스크롤 좌표는 backing pixel이다

목록의 세로 스크롤 상태는 `chrome.ui.scroll_area.State`(픽셀)이고, 행 index는 그 좌표에서 파생된다
([ScrollArea](scroll-area.md) §3). 행 높이가 셀 높이로 균일하므로 파생은 나눗셈이다 — 창의 시작 행은
`offset / cell_h`, 첫 행이 뷰포트 위로 밀린 양은 `offset % cell_h`, 그릴 행 수는 그 밀린 양까지 포함해
뷰포트를 덮는 **올림**이다. 렌더는 pane 원점을 밀린 양만큼 올리고, 위·아래로 삐져나온 부분 행은 pane
clip(ABI v147 셀 격자 scissor)이 자른다. 행 하이라이트 quad는 셀 경로가 아니므로 자기 clip을 들고 간다
(`GpuQuad.clip_*`).

그래서 **뷰포트 바닥의 부분 행이 잘린 채 보인다** — 행 좌표였을 때 그 자리에 남던 배경 띠가 없다. 휠은
트랙패드에서 논리 픽셀 단위(스무스), 그 외에는 한 행이 한 틱이다. hit-test는 같은 좌표계를 역으로 읽어
보이는 부분 행도 클릭 대상이 되며, 키보드 Page 이동만은 **온전히 보이는 행 수**를 단위로 쓴다(반쯤
걸친 행을 한 페이지로 세면 그 행을 건너뛴다).

스크롤바 기하(`file_tree_scrollbar`)도 같은 픽셀 도메인을 소비한다. 상태가 픽셀인데 스크롤바만 행이면
thumb이 셀 경계로 스냅해 목록과 어긋난다.


**스크롤바·아이콘(같은 tree snapshot 소비)**: rows가 viewport를 넘을 때만 tree content 우측에 GPU thumb를 표시한다. 중립 `src/chrome/components/file_tree_scrollbar.zig`의 content/viewport/offset(px) 공용 geometry를 render·hover·track click·drag가 함께 쓰고, L4 `AppSession`은 `PointerGestureOwner.file_tree_scrollbar`와 fade timer만 소유한다. resize/root 교체/rebuild가 generation 또는 geometry를 무효화하면 drag를 취소한다. row renderer는 track 폭+우측 inset의 실제 px를 cell 폭으로 올림한 열 수를 예약하며, 손상된 초협폭에서 콘텐츠 셀이 남지 않으면 track 아래에 glyph를 겹쳐 그리지 않는다. 중립 `src/chrome/file_tree_icon.zig`은 row projection 때 각 materialized row당 최대 한 번, filesystem/MIME 조회 없이 basename/extension을 ASCII-insensitive semantic `IconKind`로 분류하고 renderer/platform은 저장된 kind를 coverage PUA로만 lower한다. 폴더 open/closed와 source/test/docs/assets/config/dependency/output 이름군, 주요 개발 언어·web·data/config·git·image/document/archive/package 파일군, generic fallback을 제공한다. 아이콘은 모두 theme foreground 단색이고 focused selection에서는 contrast foreground를 쓴다. disclosure/icon/label 열과 우측 dirty/conflict slot은 겹치지 않는다. 제품-path artifact는 row projection 방문≤16,384, row당 classify≤1, pointer/frame당 geometry build≤1, allocation과 dock layout rebuild 0, thumb quad≤1을 실제 counter로 검증한다. filesystem/MIME·worker·lock·CoreText 부재는 숫자 0인 척하는 sentinel을 두지 않고 중립 모듈 import 경계와 코드 검토 대상으로 명시한다. 상세 hard gate는 [performance-budget.md](performance-budget.md#파일-탐색기-scrollbaricon-예산)가 소유한다. 기존 Octicons 자산으로 표현할 수 없는 SVG를 추가하면 exact name/version/source/license를 `third-party-licenses.md`에 기록하고 generator의 manifest/hash/`--check`가 coverage/C/Zig registry drift를 실패시킨 뒤에만 포함한다.

## 3.5 도크 뷰 스위처 (여러 뷰를 담는 하나의 도크)

**도크는 이제 뷰 하나가 아니라 뷰 여러 개를 담는 컬럼이다.** 상단에 아이콘 한 줄(뷰 바)이 있고 그 아래가 **현재 뷰**의
본문이다. 탐색기는 그중 하나다.

```text
┌ 도크(우측 고정) ───────────────────────┐
│ [탐색기] [소스 컨트롤] [AI 세션]       │ ← 뷰 바: pane 탭 바와 **같은 높이**
├────────────────────────────────────────┤
│ 현재 뷰 본문 (스크롤)                  │ ← Geometry.tree_content = 뷰 영역 전체
└────────────────────────────────────────┘
```

**새 도크를 만들지 않는다.** 폭 조절(outer divider)·접기·`⌘⇧E` 왕복·`FocusOwner.file_tree`·workspace 영속은 **뷰와 무관하게
도크 하나가 계속 소유**한다. 뷰는 그 안에서 무엇을 그릴지만 고른다. 이 선택이 "도크를 종류별로 늘리지 않는다"는 FP16 방향과
같은 결이다 — 컬럼이 둘이 되면 폭·접힘·포커스 규칙이 통째로 이중이 된다.

- **제목 행은 없다.** 뷰 바가 지금 보는 뷰를 이미 알려 주므로 `탐색기` 같은 제목을 글자로 한 번 더 적지 않는다(옛
  `Geometry.tree_header`는 제거했다). 그 자리는 아이콘 영역이 가져갔다.
- **바 높이 = 도크의 Chrome logical metric(40pt)이며 뷰와 무관하다.** 예전에는 탐색기·소스 컨트롤만 왼쪽 터미널 탭 바와
  높이를 맞추려고 `paneBarHeightPx`(= `cell_height + 2*pad`)를 그대로 받았다. 그러면 **같은 아이콘 세 개가 뷰를 바꿀 때마다
  오르내리고**(실측 53px ↔ 80px, 사용자 보고) 터미널 폰트 크기가 도크 기하를 정하게 된다. view bar는 도크가 소유한 chrome이므로
  모든 뷰가 `DockMetrics.view_switcher_h` 하나를 쓰고, 도크 시작선도 같은 이유로 뷰와 무관한 28pt safety band다. 그 대가로 터미널
  탭 바와의 한 줄 정렬은 포기한다(단일 출처는 [agent-session-list.md](agent-session-list.md) §2.1.3). 도크가 그 높이를 넣으면
  본문이 사라질 만큼 낮으면 바를 접는다 — 스위처가 콘텐츠를 굶기지 않는다.
- **아이콘은 2셀**(`DrawCell.width = 2`). 합성 아이콘은 슬롯 크기에 맞춰 스케일되므로(`icon_glyph.fillCoverage`의
  `side = min(w, h)`) 2칸이면 1칸보다 크고 또렷하다 — 사이드바 에이전트 아이콘이 같은 이유로 이미 2칸이다. 슬롯은 4셀
  (여백 1 + 아이콘 2 + 여백 1)이고, 아이콘은 셀 한 줄을 패딩만큼 내려 그려 바 안에서 세로 중앙에 온다.
- **슬롯 기하는 중립 모듈**(`src/chrome/components/dock_view_bar.zig`)이 소유하고 render·hover·클릭이 같은 계산을 공유한다
  (스크롤바·아이콘과 같은 패턴). **chrome은 도메인 enum을 모른다** — 슬롯을 index로만 세고 뷰↔index 대응은 session이 소유한다.
  폭이 모자라면 **일부만 그리지 않는다** — 반쯤 잘린 스위처는 눌러도 되는지 알 수 없다.
- **호버**: 슬롯 위에서 포인터가 `pointingHand`로 바뀌고 배경이 옅게 밝아진다. 바 안이라도 **슬롯 밖 여백은 화살표**다.
  호버를 먼저 깔고 활성을 위에 얹어 활성 슬롯을 호버해도 활성 표시가 유지된다.
- **선택 상태**: `DockPanel.view`가 소유하고 workspace에 저장한다(`dock-view`). **모르는 값은 `explorer`로 clamp**한다 —
  뷰가 나중에 늘어도 옛 파일이 fail-close되지 않게 하기 위함이고, mode 복원이 `defaultFor`로 clamp하는 것과 같은 관용이다.
- **포커스와 `⌘⇧E`**: 트리 키보드 포커스(`FocusOwner.file_tree`)는 **탐색기 뷰일 때만** 유효하다. 다른 뷰를 보는 중에
  `focus_file_tree`/`⌘⇧E`가 오면 접힘 해제와 같은 급으로 먼저 뷰를 탐색기로 되돌린 뒤 포커스를 준다 — 보이지 않는 트리에
  키 입력이 가지 않게 한다. 같은 이유로 `fileTreeRowAt`은 다른 뷰에서 null이다.

**v1 뷰 셋.**

| 뷰 | 아이콘 | 내용 | 계약 소유 |
|---|---|---|---|
| 탐색기 | 폴더 | 파일 트리(§4) | 이 문서 |
| 소스 컨트롤 | git | 변경 목록·스테이징 | [editor-surface.md](editor-surface.md) §3.5 |
| AI 세션 | 코드 | 창의 **모든 탭**을 가로지르는 에이전트 세션 목록 | 아래 |

**AI 세션 뷰.** 행 문자열은 사이드바 에이전트 행과 **같은 출처**(마지막 사용자 프롬프트 우선 + 상태 마커)를 쓴다 — 같은 것을
두 곳에서 다르게 부르지 않는다. 사이드바가 워크스페이스 카드별로 나누는 것과 달리 이 뷰는 **창 전체를 한 목록**으로 낸다.
그게 이 뷰가 사이드바와 별개로 존재하는 이유다. 활성 Term의 세션은 강조색으로 표시한다. 표시 형태의 단일 출처는
[사이드바 에이전트 목록](sidebar-agent-list.md)이고 이 뷰는 그 데이터를 다른 묶음으로 보여 주는 것이다.

## 4. 트리 계약

- **배치**: 트리가 **도크의 현재 뷰 영역 전체**다 — `Geometry.tree = dock - view_bar`(§3.5)이고 `editor`/`tab_bar`/`header`/`content`/`tree_divider` rect와 그 hit-test·드래그(`treeDividerHitRect`·`treeSizePtForPointer`·`dock_tree_divider` 제스처)는 삭제됐다. 도크 폭이 곧 트리 폭이라 폭 조절은 outer divider 하나뿐이다(`dock.tree_size`와 `dock-tree-size` 키는 B-4에서 제거했다 — 도크 폭이 곧 트리 폭이라 잴 것이 없다). 부작용: **트리 좌측 가장자리가 outer divider의 grab band와 겹친다**(옛 배치에선 트리가 우측이라 안 겹쳤다). 그래서 `min_editor_cols`(28셀)·`min_tree_cols`(12셀)·`default_tree_cols`(18셀) 상수와 editor↔tree divider도 함께 사라졌다(B-4에서 삭제). 남은 폭 하한은 pt 기준 `min_right_pt`를 계속 강제한다(`@max(requested_px, @min(min_dock, max_dock))`). 옛 420pt 기본·240pt 하한은 **editor + tree를 함께 담던 시절의 값**이라 트리 전용에는 과했다(화면 절반 가까이 차지 — 사용자 확인 2026-07-28). 자동 도크(`dock.size == 0`)의 탐색기·소스 컨트롤은 좌측 사이드바와 같은 성격의 목록 열이므로 **기본 180pt·하한 120pt**(`theme.SidebarConfig.width_pt`의 기본·범위와 같은 값. 레이어가 달라 상수는 공유하지 않고 값만 맞춘다)을 쓴다. `agent_sessions`만 같은 자동 sentinel에서 480pt를 쓰는 consumer-specific 예외이며, 수동으로 저장한 0 이외 폭은 어느 뷰도 바꾸지 않는다([agent-session-list.md](agent-session-list.md) §2.1). bottom은 가로 띠라 성격이 달라(폭이 아니라 높이) 300/160pt를 유지한다. 폭 조절은 이제 **terminal↔dock outer divider 하나**가 담당하며, 그 divider가 곧 트리 폭이다(현행 `dock-size`가 그 값이다 — `dock-tree-size`는 **키 자체가 제거**돼 더는 쓰지도 읽지도 않고, 옛 파일의 그 키는 unknown field 관용으로 조용히 무시된다). 확장 grab band·live reframe·mouse-down offset 보존 계약은 outer divider에 그대로 남는다. **트리 자체는 WKWebView가 아니라 GPU 셀 chrome이므로 도크에 web surface가 하나도 없고**, 그 결과 §4의 도크-aware 예외 둘이 제거된다.
- **루트**: inferred mode에서는 열린 파일이 git repo 안이면 repo 루트, 밖이면 부모 폴더를 합류시킨다. explicit mode에서는 open/add/remove 명령만 표시 root를 바꾼다. 서로 겹치지 않는 루트는 멀티루트 섹션으로 두고, parent/child로 겹치면 가장 바깥 ancestor 하나로 정규화한다. root가 없으면 cwd를 암묵 추가하지 않고 빈 안내를 표시한다.
- **내용**: 폴더 접기(lazy 열거), 파일 클릭=열기(§6), 열린 파일 하이라이트 + dirty 점, **최근 파일 접이식 섹션**(파일 열람 히스토리 흡수처).
- **선택과 키보드 포커스(ABI v127)**: 트리는 row index가 아니라 `절대 경로 + row kind` identity로 transient selection을 소유한다. scan 완료·접기·FSEvents rebuild로 row index가 바뀌어도 같은 row가 남으면 선택을 복원하고, 사라지면 가장 가까운 조작 가능한 조상/이웃으로 결정적으로 이동한다. 클릭 또는 `focus_file_tree`가 Zig의 단일 `FocusOwner`를 `.file_tree { restore_surface: ?surface_id }`로 바꾸고 Metal view를 first responder로 만든다. 현재 구현의 기본 `⌘⇧E`는 이 action에 연결되어 있으며, FP9에서 §3.4의 `toggle_file_panel_focus`로 기본 chord만 이전한다. surface id는 앱 전역 비재사용이라 generation token을 겸하며 Esc 때 entry와 native WKWebView 존재를 다시 검증한다. `file_tree_focus`는 이 union의 파생 getter일 뿐 별도 mutable boolean이 아니다. 선택과 keyboard focus는 workspace에 저장하지 않는다. 포커스 중 선택은 theme accent 배경과 WCAG 4.5 이상 대비가 나는 파생 전경을 marker·이름·dirty/conflict 표시 전체에 적용하고, 포커스 밖에서는 dim으로 그린다. active 파일 표시는 별도 marker로 유지한다.
- **표준 탐색**: `↑/↓`는 이전/다음 조작 가능한 row, `←`는 열린 directory를 접고 그 외에는 부모 row, `→`는 닫힌 directory를 펼치고 이미 열렸으면 첫 자식, `Enter`는 directory toggle 또는 파일 열기, `Home/End`는 첫/마지막 row, `PageUp/PageDown`은 현재 tree viewport의 표시 row 수만큼 이동한다. 선택 이동은 같은 row layout/scroll 상태를 사용해 최소 거리로 scroll-into-view한다. `Esc`는 트리 진입 직전 도크 WKWebView를 복원하고, 없거나 stale이면 활성 terminal/browser pane으로 돌아간다. tree focus 동안 평문·IME와 terminal macro는 PTY로 전달하지 않는다.
- **파일 변경 명령**: `new_file`, `new_directory`, `rename_file_tree_entry`, `delete_file_tree_entry`를 command catalog와 project tree context menu에 노출한다. rename은 `F2`, delete는 `⌘Backspace`도 사용한다. project root/directory/file row만 대상이며 recent row/header와 root 자체의 rename/delete는 금지한다. 생성 위치는 선택이 directory면 그 안, file이면 부모다. 빈 이름·`.`·`..`·`/` 포함·기존 항목 충돌은 거부하고 dotfile은 허용한다.
- **root-pinned mutation capability**: 요청은 절대경로 문자열이 아니라 `{root_generation, root_fd, parent_file_id, leaf_name, leaf_dev, leaf_ino, leaf_kind}`를 소유한다. root부터 parent까지 descriptor-relative/no-follow로 열고 component boundary를 대조하며, symlink-directory는 표시·펼치기는 가능해도 생성 컨테이너가 될 수 없다. symlink row rename/delete는 parent descriptor 기준으로 링크 자체만 처리한다. create는 exclusive create/mkdir, rename과 delete staging은 macOS `renameatx_np(..., RENAME_EXCL)` 또는 동등한 atomic no-replace를 써 precheck 뒤 경쟁 생성도 덮어쓰지 않는다. confirm과 worker 실행 직전에 root/parent/leaf identity를 다시 검증하고 불일치면 아무 mutation 없이 실패한다.
- **휴지통 경계(ABI v129)**: delete 승인 뒤 worker는 확인된 leaf를 같은 parent의 예측 불가능한 **비-dot** staging 이름(`<원래 basename>.maru-trash-<request>-<nonce>`)으로 descriptor-relative atomic no-replace 이동한다. 예전 `.maru-trash-*` 이름은 Finder 휴지통 기본 보기에서 숨겨졌으므로 사용하지 않는다. AppKit adapter는 staged dev/ino/kind를 다시 확인한 뒤 `NSWorkspace.recycle`에 넘기고, 완료를 `not_moved / moved_verified / moved_unverified { last_known_destination? }`로 구분한다. 한 입력의 destination map과 휴지통 destination의 dev/ino/kind가 모두 일치한 `moved_verified`에서만 clean tab·recent·tree를 commit한다. `not_moved`만 staging→original rollback하며, 이미 이동했지만 검증할 수 없는 `moved_unverified`는 존재하지 않는 staged path를 rollback하지 않고 마지막 destination 또는 경로 불명 recovery 상태로 정상 종료와 후속 mutation을 차단한다. Foundation이 APFS에서 진짜 file-reference URL 대신 path URL을 돌려줄 수 있어 file-reference 여부를 안전성 전제로 두지 않는다. 공개 inode-conditional Trash/rename API가 없으므로 same-UID 프로세스가 마지막 identity 검사와 namespace syscall 사이에 경로를 악의적으로 교체하는 공격은 원자적으로 막지 못하며 명시적 위협 경계 밖이다. 경쟁이 감지된 결과에서는 모델 commit 없이 fail-close한다.
- **변경 안전성**: rename은 row 내부 `OverlayInput`을 재사용한다. dirty/dirty-sync-pending/external-conflict/reload-pending entry와 이를 포함하는 directory의 rename/delete는 차단한다. `DockPanel.Entry.path`가 열린 파일 경로의 유일한 권위이고 recent index만 함께 갱신하며, 다음 workspace capture가 entry path를 직렬화한다(별도 mutable workspace path cache를 두지 않는다). queue admission을 먼저 확보해 cap+1 거부는 plan allocation 0이고, main actor는 entry 256/recent 32 상한 안에서 target/generation과 영향 path를 **단일 contiguous snapshot allocation**으로만 복사한다(경로 join·개별 새 문자열 할당은 하지 않음). worker가 descendant 새 문자열을 모두 할당한 `PathRemapPlan`을 만들고, 성공 결과가 같은 tree/mutation generation일 때 main actor가 실패 없는 swap 한 번으로 적용한다. OOM/stale completion은 plan을 폐기하고 background coarse rescan만 예약한다. pin path가 바뀐 live WKWebView는 기존 surface를 폐기하되 비활성 view는 surface-less로 두고 재선택 시 lazy 재생성하며, 보이는 affected view만 bounded recreate queue에서 tick당 하나씩 새 surface id로 복구한다. delete는 확인 뒤 macOS 휴지통으로만 이동하며 영구 삭제와 undo는 제공하지 않는다. symlink는 링크 자체만 대상으로 하고, 휴지통 이동 성공 뒤에만 clean open 탭을 닫는다. 실패하면 tree/tab을 유지하고 notice를 표시한다.
- **비동기 mutation reservation**: submit 전에 영향 entry 전체에 `mutation_pending { request_id, root_generation, tree_generation, state_generation, file_identity }`를 설정한다. Markdown editable mode(`live-preview|source-edit`)는 먼저 revision sync와 read-only 전환 ack를 받아 clean을 재검증하고, mutation pending 동안 edit/save/reload/close를 막는다. `Mode.isEditable()`를 close/group-close/merge/LRU/rename/delete/exit/⌘Q/terminal auto-exit의 모든 clean-but-unsynced 보호가 공유한다(**FP16**: `LRU`와 `group-close`는 소비처가 사라지고 나머지는 그대로 — 공유 술어 자체는 유지한다). path swap 전에 old surface의 file bridge capability와 pending one-shot/ack를 revoke하며, revoke/read-only ack 실패면 FS mutation을 시작하지 않는다. success completion은 exact request+identity를 한 번 더 검증한 뒤 remap/close와 새 surface id 발급을 정확히 한 번 수행한다. failure는 원래 path/surface와 편집 가능 상태를 복원하고 late/duplicate completion 및 old surface의 read/write/setDirty를 거부한다.
- **rename kind 전이**: 확장자 판정은 기존 `openKindForPath`와 같은 ASCII case-insensitive `.md`/`.html` 단일 출처를 쓴다. `.md↔.html`은 성공 commit에서 `Entry.kind`를 다시 계산하고 mode를 `.read`로 강등하며 old bridge/WebView를 revoke한 뒤 해당 trust config의 새 surface id를 발급한다. 지원 확장자에서 비지원 확장자로 rename하면 FS rename 성공 뒤 clean file-panel entry를 닫고 tree selection은 새 파일을 유지한다. directory rename은 descendant basename 확장자가 바뀌지 않으므로 kind를 보존하되 모든 `{path, kind}`를 commit 전 재검증한다. mismatched live/workspace state는 허용하지 않는다.
- **변경 실행 경계**: create/rename은 bounded backend(request 64, in-flight 1, completion 16)에서 순서대로 실행하고 휴지통 이동만 AppKit adapter(queue 16, in-flight 1)가 담당한다. cap+1은 명시적 busy notice로 거부하며 pending을 남기지 않고, tick은 completion과 WKWebView recreate를 각각 최대 1개만 drain한다. user mutation 자체는 coalesce하지 않고 watcher/coarse-rescan만 `{root, deepest expanded ancestor}` key로 합친다. 현재 backend는 요청마다 `pump()`에서 `Job` allocation과 detached worker thread 생성을 수행하므로 frame tick의 blocking path lookup/read 0은 지키지만 completion descriptor close, thread-spawn/allocator 0까지 증명하지는 못했다. persistent worker+condition queue 전환은 별도 성능 gate다. worker completion은 검증된 kind·project root·경로 metadata와 필요 snapshot을 소유해 tick이 기존 동기 `openFilePanelPath`/`rebuildFileTreeFromDock`를 호출하지 않게 한다. mutation completion과 watcher event가 동시에 scan queue에 있으면 path key로 합치지만, staging rename·native completion·recycle이 서로 다른 FSEvents batch로 지연되면 이미 완료된 scan 뒤 추가 scan이 생길 수 있고 현재 엄격한 횟수 상한은 없다. provenance 없이 suppress하면 실제 외부 변경을 놓치므로 scheduler quiet-window를 도입하기 전에는 correctness를 우선한다. `NSWorkspace.recycle` callback이 오지 않으면 결과가 불명확하므로 자동 성공·재시도·unlock하지 않고 queue/exit gate를 유지한다.
- **층 배치**: `file_tree.zig`은 L2 root mode/snapshot/generation과 접힘을, `file_tree_icon.zig`과 `file_tree_scrollbar.zig`은 중립 semantic classifier/geometry를 소유하고 `tests/boundary/imports.zig`가 import 방향을 고정한다. L3 renderer는 row와 semantic icon을 glyph cell로 투영할 뿐 root policy를 모르며, L4 AppSession/AppKit은 picker/context menu/gesture/fade/watcher adapter만 소유한다.
- **FS 백엔드는 완전 신규**(디렉터리 열거·감시 선례 0 — pty kqueue는 proc reap 전용): 이벤트 구동 watcher(FSEvents) + debounce + bounded queue. **frame tick의 blocking path lookup/read 금지**([performance-budget.md] micro-slice 규율 — bounded 증명 artifact). 완료 result가 소유한 descriptor close는 허용한다.
- **FP7 구현 정책(2026-07-17, 사용자 승인 — Zed Project Panel 기준)**: [Zed Project Panel](https://zed.dev/docs/project-panel)의 자연 정렬·폴더 우선·active/open 표시·lazy directory 경험과 [Zed settings](https://zed.dev/docs/reference/all-settings)의 `file_scan_exclusions`/expanded symlink 관례를 clean-room 기준으로 삼는다. 기본 제외는 `.git`, `.svn`, `.hg`, `.jj`, `CVS`, `.DS_Store`, `Thumbs.db`, `.classpath`, `.settings`이고 일반 dotfile·`.github`·`.env`는 보인다. 폴더와 symlink 폴더는 펼칠 때만 scan한다. 서로 다른 repo/부모는 multi-root로 합류하고 최근 32개를 MRU로 보존한다.
- **FP7 I/O 경계**: `src/session/file_tree.zig`은 최대 root 256·materialized node 16,384·directory child 4,096·scan request 1,024의 L2 snapshot만 소유한다. `file_tree_backend.zig` worker는 동시 scan 4·고정 완료 queue 16으로 `openDir/iterate/stat`을 수행한다. frame tick은 결과 queue를 drain해 snapshot/rows를 바꾸고 새 요청을 submit할 뿐 blocking path lookup/read를 수행하지 않는다. result 소유 descriptor의 close는 main actor 수명 정리다. backend 교체/세션 종료는 generation ref를 놓을 뿐 느린 FS worker를 main actor에서 기다리지 않으며 마지막 worker가 heap state를 회수한다. overflow/OOM은 event/result drop으로 영구 loading을 남기지 않고 root coarse rescan 또는 fail+retry로 회복한다. Swift FSEvents는 file-level + watch-root stream을 200ms latency로 main queue에 coalesce하고, dropped/must-scan/root-change flag는 모든 root coarse invalidate로 승격하며 stream 재구성 때 마지막 event ID를 이어 event-loss window를 닫는다.
- **root picker 보안(ABI v137)**: Swift `NSOpenPanel`은 directory-only 단일 선택 adapter이고 정책 상태를 소유하지 않는다. ABI one-shot `replace | add`와 선택 path를 받은 Zig가 위의 normalize/no-follow/identity 정책과 root transaction을 실행한다. 성공 commit만 watcher reset·lazy scan을 예약하고 실패·취소·busy는 `FileTreeRootOutcome`(`picker_canceled`, `invalid_path`, `busy`, `stale_generation`, `identity_changed`, staging 실패, `committed_replace|add|remove` 등)의 안정된 typed reason과 사용자 notice를 남긴다. frame tick에는 directory stat이나 picker I/O를 넣지 않는다.
- **외부 변경 정책**: clean으로 열린 Markdown은 shell의 직렬 mutation queue에서 disk 내용을 다시 읽고, clean HTML은 핀 URL을 reload한다. dirty/dirty-sync-pending이면 CM6 buffer를 덮지 않고 `external_change`를 latch해 트리·헤더에 `!`를 표시하며 저장은 `ExternalConflict`로 거부한다. 사용자가 헤더 `!`를 누르고 "다시 읽기" 확인을 통과하면 2-phase reload를 시작하고, web shell이 실제 disk read와 editor replacement 성공을 ack한 뒤에만 dirty/conflict를 내린다. 읽기 실패·취소·일반 clean ack는 원래 buffer 보호를 유지하며 reload 중 더 새 event가 오면 generation 불일치로 성공 ack도 conflict를 지우지 못한다. atomic save 직후 event는 background content hash가 저장 bytes와 같을 때만 자기 event로 소비하므로 grace 구간의 실제 외부 overwrite도 conflict가 된다. create/delete/rename은 가장 깊은 펼친 ancestor snapshot을 background에서 다시 만든다.
- **레이아웃 비용(2차 검증 정정)**: `termRect`(app_session.zig:2335)는 폭(사이드바)+높이(titlebar strip) inset 선례가 이미 있고 파생 ~30 호출처가 자동 추종한다. **단 "한 곳"이 아니라 두 곳 동기 규율** — spawn/resize grid는 termRect 파생이 아니라 `gridFromBacking`+`gridPadding()` 별도 경로(호출처 3곳)라, 도크 inset도 titlebar 선례대로 rect 한 곳+grid 한 곳을 동기한다. 비용의 본체는 도크 자신의 렌더·스크롤·hit-test 배관(사이드바 급 신규) + ChromeProps 소비처 4곳(폭 기준 — modal_box·overlay_input·context_menu·dropdown) + **하단 도크의 높이 방향 추가 대상**(modal_box 세로 중앙[backing_height 전체 기준]·context_menu/dropdown 하단 clamp·notifications 가용 높이·settings 행 수). 추가 표면 2개(실측): ⑴ **web seam** — collectWebSurfaces가 "termRect 바깥 경계=divider 없음"을 가정(app_session.zig:7587)해 도크 경계에 붙은 워크스페이스 web pane의 WKWebView가 도크 리사이즈 드래그를 삼킨다 → `seam_edges`에 도크 edge 비트 추가. ⑵ **드래그 중 WKWebView 가림 규범([web-panel.md] §3)은 현재 미구현**(4c 생략 상태) — 도크 리사이즈는 도크 웹뷰 자체가 매 tick resize라 FP3에서 실물 구현(드래그 세션 단위 hide)하거나 명시 백로그로.
