# 파일 탐색기 (도크 트리·watcher·root)

창 레벨 도크에 사는 **파일 탐색기**(프로젝트 트리)의 단일 출처 문서다. 트리의 root 모델·스캔·감시·선택·키보드 탐색·파일 변경 명령을 소유한다.

> **[파일 패널](file-panel.md)과의 경계**: 파일 *콘텐츠*(뷰어/편집기)는 워크스페이스 pane 트리의 `Term`으로 살고 그 계약은 file-panel.md가 소유한다. 이 문서는 도크의 **파일 탐색기 콘텐츠**만 다룬다(FP16에서 파일 콘텐츠를 보관하던 별도 도크 그룹은 없어졌으며, 도크의 다른 view는 각자 문서가 소유한다). 두 문서가 만나는 지점은 셋이다 — ⑴ 트리에서 파일을 열면 [file-panel.md §6](file-panel.md#6-열기-규칙)의 열기 규칙을 탄다, ⑵ 도크 배치·표시 상태와 root 영속은 [file-panel.md §5.1](file-panel.md#51-도크트리-포맷-현행--레거시-읽기-경로)의 workspace.v1 포맷이 소유한다, ⑶ 트리↔터미널 입력 포커스 왕복은 [file-panel-dock-ui.md §3.4](file-panel-dock-ui.md#34-terminal파일-도크-입력-포커스-표시왕복)가 소유한다.
>
> 진행·검증 상태는 이 문서가 아니라 [검증 매트릭스](verification-matrix.md)의 "파일 패널 FP7" 행과 "파일 도크 닫기·트리 키보드·파일 변경" 행이 소유한다.
>
> **행 렌더 기반은 이관 중이다.** §3이 적는 셀 격자 계약은 현행이고, 이 트리를 `chrome/ui` typed tree로 옮기는 단계와 그때의 시각 계약은 [파일 탐색기 트리 컴포넌트 이관 계획](plans/file-tree-component.md)이 소유한다. 이 문서는 그 계획이 단계를 끝낼 때마다 해당 절을 현재형으로 바꾼다.


## 1. 활성 터미널 cwd 따라가기 (ET-CWD, 2026-07-28 사용자 요청)

탐색기 root는 **활성 pane 터미널의 cwd와 항상 같다**. `cd` 한 폴더가 곧 트리 최상위다. 그 이상의 규칙은 없다 — 저장소 루트로 올려 세우지도, 홈이나 `/`를 예외로 빼지도 않는다.

**cwd를 어디서 얻는가는 이 문서가 소유하지 않는다.** 해석 지점은 소스 컨트롤 뷰·사이드바·상태바·사이드바 검색·에이전트 세션 기록 도크의 범위 칩과 공유하며(`git_ops.activeTerminalCwd` — 임의 Term은 `git_ops.termCwd`), 규칙은 [editor-surface-dock.md §3.5](editor-surface-dock.md)의 "대상 저장소를 정하는 규칙"이 단일 출처다. 요약하면 **OSC 7 → 커널 조회** 2단이다. 2026-08-10 전까지 이 기능은 OSC 7 단독이었고, 그래서 셸 통합이 없는 셸(bash/fish)이 떠 있는 터미널에서는 **따라가기가 조용히 동작하지 않았다**. 커널 폴백이 그 빈칸을 메운다. 이들이 같은 지점을 쓰는 이유는 단순하다 — 탐색기가 선 자리, 목록이 보는 저장소, 사이드바 카드가 적는 폴더·브랜치, 그리고 아카이브 범위 칩이 거르는 범위가 서로 달라지면 안 된다.

**사이드바와 아카이브 범위 칩은 2026-08-12에야 이 축으로 들어왔다.** 그전까지 카드·에이전트 행은 관측(OSC 7)만 봐서, 같은 화면에서 소스 컨트롤 뷰가 저장소를 멀쩡히 찾는 동안 사이드바만 폴더줄·브랜치줄을 통째로 지웠다. bash/fish 사용자에게는 상시였고, 재개 Term에서는 그 Term의 수명 내내였다.

> **2026-08-31 사용자 결정 — root는 cwd 하나를 그대로 따른다.** 이 절은 두 번 뒤집혔다. 처음(2026-07-28)은
> root를 안 건드리고 그 자리만 펼치는 **reveal**이었고, 다음(2026-08-11)은 cwd가 root **밖**일 때만 그 cwd를
> 품은 **저장소 루트**로 갈아끼우는 절충이었다. 지금은 둘 다 없다.
>
> **왜 절충을 버렸나 — 홈이 흡수 상태가 됐다.** 저장소 루트로 올려 세우는 규칙은 홈처럼 저장소가 아닌
> 곳에서는 cwd 자신을 root로 세운다. 거기에 "root 안이면 reveal만" 규칙이 겹치면 홈 아래는 **전부 root 안**
> 이라, 한 번 홈이 root가 된 뒤에는 `cd ~/Documents/workspace` 로도 빠져나오지 못한다. 새 탭이 홈에서 뜨는
> 것만으로 그 상태에 들어갔고, 그때부터 트리는 어디로 가든 홈에 머물렀다. 사용자가 보고한 증상이 그것이다.
> 흡수 상태를 없애는 길은 둘이었다(홈을 root 후보에서 빼거나, 안쪽 이동도 교체하거나) — 사용자는 규칙이
> 하나뿐인 쪽을 택했다.
>
> **대가를 안다.** 아래 기각 표는 지우지 않는다 — 그것이 지금 치르는 값이다. `cd` 마다 접힘 상태가 사라지고
> watcher가 재등록되며, `cd ~` 면 홈이 · `cd /` 면 루트가 root가 되고, 저장소 하위로 들어가면 형제 디렉터리가
> 안 보이며, `dock-tree-roots` 영속이 자동 전환으로 덮인다. 표에 없는 둘을 더 적는다:
>
> - **multi-root가 오래 못 산다.** "작업공간에 폴더 추가…"로 둘째 root를 세워도 다음 `cd` 한 번이 전부
>   교체한다(`rootIsExactly`는 root가 **하나**이고 그것이 cwd일 때만 참이다). 앞 판에서는 root 안을
>   오가는 동안은 살아남았다.
> - **소스 컨트롤 뷰와 시야가 갈린다.** 2026-08-11 결정의 근거가 "두 뷰가 다른 곳을 보면 안 된다"였는데,
>   `repo/src` 에서는 목록이 `repo`(저장소 단위)를 보고 트리는 `src` 를 본다. **다른 저장소를 보는 것은
>   아니라서** 그때의 불일치와 성격이 다르지만, 완전히 같은 곳을 보던 상태는 아니다.
>
> 완화는 §1.1 하나뿐이다 — **사용자 조작이 항상 우선**이다. 이 값을 치르고 얻는 것은 규칙이 하나라는
> 것이다: 터미널이 있는 자리가 곧 트리의 자리다.
>
> 아래 원문은 그 결정에 이른 기록이며, **reveal 모델과 "root 밖에서만 교체" 정책은 무효**다.

**왜 root를 갈지 않았는가(원 기각 사유).** `replaceExplicitRoots`는 주석 그대로 *"기존 expanded snapshot은 root 변경의 correctness 권위가 아니므로 버리고 새 lazy scan을 예약한다"* — 즉 root 교체는 **접힘·펼침 상태를 통째로 버리고** `root_generation`을 올리며 watcher를 재등록한다. cwd는 `cd` 한 번에 바뀌는 값이라, 그걸 root에 묶으면:

| 문제 | 내용 | 지금은 |
| --- | --- | --- |
| 상태 소실 | `cd`마다 트리가 접히고 재스캔 + watcher 재등록(debounce 200ms) — 디렉터리를 오가는 작업에서 트리가 계속 깜빡인다 | 그대로 치른다 |
| 대상 모호 | 도크는 **창 전역**인데 cwd는 **Term별**이다. split이 셋이면 cwd가 셋이고, pane 포커스만 옮겨도 트리가 갈린다 | 그대로 치른다 — 활성 pane 하나만 본다(정책 1) |
| 비-로컬 cwd | OSC 7을 안 쏘는 셸은 관측이 비고, `maru ssh` 원격 세션은 **로컬에 없는 경로**를 준다 | 검증 파이프라인이 거른다(정책 3) — 실패는 조용하고 root는 그대로다 |
| 원치 않은 스캔 | `cd ~`·`cd /` 한 번에 홈·루트 전체가 root가 된다 | 그대로 치른다 — 사용자가 예외 없음을 택했다 |
| 영속 충돌 | `explicit` root는 `dock-tree-roots`로 저장된다 — 따라가기가 그걸 덮으면 재시작 시 **고른 적 없는 root**가 복원된다 | 그대로 치른다 |

~~reveal은 이 다섯을 전부 피한다: root·접힘·watcher·영속을 **하나도 건드리지 않고** 해당 경로의 ancestor만 펼친다.~~ (reveal 모델은 2026-08-31에 폐기됐다.)

**정책(4가지)**

1. **어느 cwd인가** — 활성 워크스페이스 → 활성 pane → 활성 Term의 관측 cwd. 그 Term이 파일·브라우저라 cwd가 없으면 **직전 값을 유지**한다(비우지 않는다 — 문서를 보다 터미널로 돌아왔을 때 트리가 리셋되면 안 된다).
2. **언제 바꾸나** — cwd가 **변할 때만**, 그리고 도크가 보이고 view가 탐색기일 때만(§1.1). 같은 값이 다시 관측되면 무동작이다(관측은 폴링이라 매 tick 같은 값이 온다). **root가 이미 그 cwd면 아무것도 하지 않는다** — 이 가드가 없으면 복원된 root가 마침 터미널 cwd와 같을 때 시작하자마자 불필요한 재스캔이 돈다.
3. **무엇을 root로 세우나** — **cwd 폴더 그 자체**다. 저장소 루트로 올리지 않고 홈·`/`도 예외가 아니다. 전환은 사용자가 "폴더 열기…"로 고를 때와 **같은 검증 파이프라인**(`provideFileTreeRootPick` + `.replace`)을 탄다 — realpath·identity pinning·watcher union 재구성·영속이 그 배관에 이미 있어서, 여기서 `replaceExplicitRoots`를 직접 부르면 반쪽 전환이 된다. 원격·삭제된 경로가 걸러지는 자리도 여기다.
4. **스크롤은 필요할 때만 뺏는다** — 대상 행이 이미 **온전히** 보이면 스크롤을 건드리지 않는다. 뷰포트 밖이거나 부분적으로만 걸쳐 있을 때만 그 행이 보이도록 최소한으로 맞춘다(좌표가 픽셀이라 "보인다"의 기준이 행 경계가 아니다 — §3.1).

**reveal 메커니즘은 이 축에서 빠졌다.** root가 곧 cwd라 펼칠 ancestor가 없다 — 트리 최상위 행이 이미 그 폴더다. `reveal_path` + `continueReveal` 자체는 **파일 열기**가 계속 쓰므로 남아 있고(열린 파일의 ancestor를 펼친다), 없어진 것은 그 intent에 cwd를 넣던 `Tree.revealDirectory` 하나다.

### 1.1 자동 전환은 사용자 조작보다 아래다

자동 root 전환은 **사용자가 고른 것이 아니다.** 그래서 두 가지를 지킨다.

- **사용자 요청이 밀어낸다.** root 검증 슬롯은 하나이고 `fileTreeNamespaceMutationBusy`가 그 사이의 폴더 열기·추가·제거를 거절한다. `cd` 직후 자동 전환이 그 슬롯을 잡고 있으면 사용자가 방금 누른 "폴더 열기…"가 busy로 조용히 거절된다 — 누른 사람은 왜 안 먹는지 알 수 없다. 그래서 대기 중인 검증이 **자동**이면 그것을 버리고 자리를 내준다(뒤늦게 온 결과는 `request_id` 대조가 이미 거른다).
- **같은 busy 판정을 쓴다.** 자동 전환도 `fileTreeNamespaceMutationBusy` 앞에서 멈춘다 — 이름 변경·삭제·휴지통 롤백·수동 복구 중에는 root가 갈리지 않는다(§2가 정한 그 규칙이다). 판정을 손으로 다시 적으면 항목이 빠진다.
- **탐색기를 보고 있을 때만 바꾼다.** 도크가 보여도 view가 소스 컨트롤·에이전트면 트리는 화면에 없다. 그때 root를 갈면 보이지도 않는 트리의 접힘·스크롤을 버리고 영속까지 덮는다. reveal 모델에서는 비파괴적이라 상관없었지만 **교체는 다르다** — 그리고 이제 모든 `cd`가 교체다.
- **실패는 조용하다.** 자동 전환이 실패해도 알림을 띄우지 않는다(`outcome`은 남겨 진단·테스트가 본다). 사용자가 시킨 적 없는 동작의 "선택한 폴더를 열 수 없습니다"는 무엇을 잘못했는지 알 수 없는 알림이다. **제출 시점만이 아니라 검증 완료 경로까지** 그렇다 — 실패는 대개 완료 쪽에서 난다.
- **미룬 것은 다시 시도한다.** 위 세 이유로 못 걸었으면 그 cwd를 "따라간 것"으로 표시하지 않는다. 표시하면 다음 `cd` 전까지 영영 재시도되지 않아, 잠깐 바쁜 순간에 걸린 첫 따라가기가 통째로 사라진다. 표시하지 않으면 다음 tick이 자연히 다시 시도하고, 조건이 풀리는 즉시 걸린다. **건 뒤에는** 표시하므로 같은 cwd로 요청이 쌓이지 않는다.
- **트리를 갈아끼우면 기억도 버린다.** 워크스페이스 복원·병합은 트리를 통째로 교체한다. 따라간 cwd 기억을 남기면 "이미 따라갔다"로 읽혀, 복원된 root가 활성 터미널과 달라도 `cd` 전까지 따라가지 않는다.

이 보장들은 회귀 테스트가 지킨다 — 전부 증상이 "조용히 안 따라간다" 하나로 같아 눈으로는 구분되지 않는다.

**남는 것(이 슬라이스 밖)**: 끄기 위한 config 키(실사용 근거가 생기면 — measure-first). "이 폴더를 루트로 추가" 어포던스는 자동 전환이 대신하므로 더 이상 필요 목록에 없다.

자동 gate는 pane/Term 전환, 같은 pane의 `cd`, root가 이미 그 cwd일 때의 no-op, visible target 무스크롤, 그리고 미룸 조건(mutation busy·비탐색기 view)에서의 재시도를 포함한다.

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

스크롤바 기하도 같은 픽셀 도메인을 쓴다(`chrome/ui/scroll_area.zig`). 상태가 픽셀인데 스크롤바만 행이면
thumb이 셀 경계로 스냅해 목록과 어긋난다.


**행 렌더는 typed component다(FT1).** 행의 기하·페인트는 `src/chrome/components/file_tree/`(`types`·`build`·`view`)가 소유하고, 제품 배선은 `app_session/file_tree_dock.zig`가 Session Dock·SCM Dock과 **같은 순서**(투영 → props → build → view → paint)로 한다. 그래서 **행 높이가 터미널 셀에서 떨어져 나왔다** — `types.Metrics`가 logical pt를 backing scale로 한 번 환산하며, 그 값의 단일 소비 지점이 `file_tree_dock.fileTreeRowHeightPx`다(창 산술·히트테스트·스크롤 상한·reveal이 전부 그 함수를 지난다). 라벨은 measured CoreText 경로로 `list_row` role(14pt)로 그리고, 등록 PUA 아이콘만 셀 draw list로 간다. 선택·활성·호버 밴드는 컴포넌트가 낸 카드 rect를 `ui_paint`가 그리며, 포커스된 선택은 accent **막대**로 표시한다(면을 accent로 칠하면 이 층에 "accent 위 전경" role이 없어 글자가 안 읽힌다). **히트테스트도 그 tree를 본다(FT2).** 행은 `opacity = 0`인 card로 발행돼 **누르는 자리가 곧 그린 자리**이고, 포인터는 `chrome.ui.interaction.dispatch`를 지나 action 표(세대 검증)로 풀린다 — 여는 것은 `up`이며, 그 사이 투영이 바뀌면 세대가 안 맞아 거부되고 tree가 교체되면 capture가 풀린다. 호버의 주인도 `InteractionState` 하나다. 밴드가 좌우로 들어가 보이는 것은 `view`가 그리기 때문이고 **행의 히트 rect는 전폭**이다(여백을 컨테이너에서 떼면 그 여백이 클릭 사각지대가 된다). 좌표→행 산술(`file_tree_layout.rowAtLocalY`)은 Windows chrome 낮추기가 계속 쓰므로 남아 있고, 두 답이 같은지는 제품-path 테스트가 창 전체를 훑어 대조한다. 아래 셀 열 서술은 **Windows가 쓰는 셀 경로**의 것이다 — 그 투영은 macOS 파일이 아니라 `src/platform/cell_text.zig`(macOS·Windows 공유 L4)가 소유하고, macOS에는 호출이 하나도 없다. Windows는 제품 도크 트리를 그것으로 그리고(W8.7a2) 같은 투영을 스모크가 픽셀까지 확인한다. 정의 위치와 호출 수를 `tests/boundary/imports.zig`가 센다(FT3). 함수가 사라지는 것은 Windows가 `ChromeDraw` 낮추기를 갖고 컴포넌트 경로로 갈아탈 때이며, 그 판단은 [단계 계획](plans/file-tree-component.md)의 FT3가 소유한다.

**좁은 폭의 열화 규칙 — "이름은 마지막까지 남는다".** 행이 쓸 수 있는 폭이 줄면 **들여쓰기 → 상태 슬롯
→ chevron** 순으로 버리고, 좌우 패딩과 종류 아이콘은 못 버린다(그것까지 버리면 무엇의 행인지 알 수 없다).
라벨은 `label_floor`(80pt — role 이 정한 14pt 기준 약 9~10자)를 **목표**로 삼는다. 다 버려도 모자라면
라벨이 남은 것을 전부 받는다 — **보장이 아니다**. 트리 행 폭은 도크 폭에서 스크롤 거터(8 + 8 = 16pt)를
뺀 값이라, 도크 하한 120pt 면 행이 104pt 이고 라벨은 66pt(약 7~8자)다. 목표가 달성되는 것은 도크
134pt 부터다. 결정은 **폭만
본다**: 깊이나 dirty 여부로 갈리면 행마다 x 가 달라져 목록이 들쭉날쭉해지고 스크롤로 흔들린다. 그래서
상태 슬롯은 항상 있다고 치고 자리를 잡고, 실제로 그릴지는 행이 정한다. 값의 소유자는
`components/file_tree/types.zig`의 `Metrics.rowLayout` 하나이고, 밴드·안내선·chevron·아이콘·라벨·상태
점이 전부 그것을 되읽는다 — 각자 계산하면 좁은 폭에서 서로 어긋난다.

들여쓰기가 0 이 되면 안내선도 그리지 않는다(같은 x 에 겹쳐 한 줄로 보일 뿐이라 깊이를 말하지 못한다).
즉 가장 좁은 구간에서 트리는 **평평한 목록**이 된다 — 깊이를 포기하고 이름을 지키는 것이 이 규칙의 선택이다.

**밴드는 둘뿐이다 — 선택과 호버.** 선택은 `tab_active_bg`(+ 포커스면 왼쪽 accent 막대), 호버는 한 단
약한 `tab_hover_bg`다(`view.bandRole`). 즉 **켜진 밴드는 언제나 "포인터가 여기"거나 "이 행을 골랐다"**이다.

- **`row_hover_bg`는 이 목록에서 쓰지 않는다.** 그 role 은 "활성 밴드 위에 겹쳐도 구분되게 활성보다
  밝다"가 계약이라 카드 목록용이고, 상태가 배타인 이 트리에서는 호버가 선택보다 밝아져 무엇을 고른
  상태인지 사라진다(Chrome Lab 실측: 선택 rgb 80 대 호버 140).
- **열린 파일에는 밴드가 없다.** 한때 호버와 같은 `tab_hover_bg`를 나눠 썼는데, 그러면 켜진 밴드가
  "포인터가 여기"인지 "이 파일이 열려 있다"인지 구별되지 않는다(실측: 두 행이 같은 밝기 68). 신호가
  빠진 것이 아니라 **거짓**이었다. 색을 하나 더 만들어 가르는 길은 닫혀 있다 — rich 팔레트의 상호작용
  단계는 배경 10 위에서 88·94·100 이라 그 사이는 읽히지 않는다(`tokens.zig`의 `control_press_bg` 주석).
  그래서 빼서 푼다. 열린 파일은 **라벨이 `surface_fg`로 올라가는 유일한 행**이라는 신호를 그대로 갖고,
  덕분에 열린 파일도 호버에 반응한다.

이 계약은 값 테스트(`chrome/components/file_tree/view.zig` — 세기 순서·활성 무밴드·호버 반응)와 시각
골든(`file-tree-hover-weaker-than-selection`)이 함께 지킨다.

**스크롤바·아이콘(같은 tree snapshot 소비)**: 목록이 viewport를 넘을 때만 tree content 우측에 track/thumb이 나온다. 그 둘은 `chrome/ui/tree.zig`의 **`scrollArea` 선언 하나**가 내는 entry이고(소스 컨트롤 뷰도 같은 선언·같은 발행 저장소를 쓴다 — 도크 뷰는 한 번에 하나만 보이므로 `dockListScroll()`이 사각형과 좌표계만 갈아끼운다), 그리기는 공용 `ui_paint` → `chrome_draw_lowering`이 한다 — 기하를 render·hover·track click·drag가 각자 계산하지 않고 **발행된 그 rect를 되읽는다**. L4 `AppSession`은 fade timer와 down 시점 domain 신원만 소유하고, 드래그 수명(잡은 지점·기하 고정·tick coalescing)은 `scroll_area.Drag`가 갖는다. resize/root 교체/rebuild가 generation 또는 기하를 무효화하면 drag를 취소한다. track이 놓일 자리는 컨테이너가 자기 폭에서 떼는 **픽셀 gutter**이고 스크롤바 유무와 무관하게 상시 예약되므로, 행 텍스트도 하이라이트 밴드도 그 안으로 넘어오지 않고 목록이 reflow하지 않는다. 중립 `src/chrome/file_tree_icon.zig`은 row projection 때 각 materialized row당 최대 한 번, filesystem/MIME 조회 없이 basename/extension을 ASCII-insensitive semantic `IconKind`로 분류하고 renderer/platform은 저장된 kind를 coverage PUA로만 lower한다. 폴더 open/closed와 source/test/docs/assets/config/dependency/output 이름군, 주요 개발 언어·web·data/config·git·image/document/archive/package 파일군, generic fallback을 제공한다. 아이콘은 모두 theme foreground 단색이고 focused selection에서는 contrast foreground를 쓴다. disclosure/icon/label 열과 우측 dirty/conflict slot은 겹치지 않는다. **행 아이콘은 2칸으로 그린다** — 합성 아이콘은 슬롯의 짧은 변에 맞춰 그려지므로(`icon_glyph.fillCoverage`) 칸 수가 곧 크기이고, 1칸이면 셀 폭(~8px)까지 줄어 실루엣이 뭉개진다. 사이드바 보조줄(`wideIconGlyph`)·도크 뷰 바(`dock_view_bar.icon_cols`)가 같은 이유로 이미 2칸이라, 트리만 1칸이던 동안에는 같은 화면에서 트리 아이콘만 절반 크기였다(사용자 보고 2026-08-22). 아이콘이 슬롯을 꽉 채우므로 라벨은 `icon_col + 3`(아이콘 2칸 + 간격 1칸)에서 시작한다 — 사이드바 `sidebar_row_icon_cols = 3`·소스 컨트롤 파일 행과 같은 규약이고, 간격이 없으면 아이콘이 첫 글자에 붙어 한 글리프처럼 읽힌다. 두 번째 칸이 dirty/conflict slot을 침범하는 좁은 폭에서만 1칸으로 접는다. 제품-path artifact는 row projection 방문≤16,384, row당 classify≤1, pointer/frame당 geometry build≤1, allocation과 dock layout rebuild 0, 스크롤바 quad≤2(track+thumb)를 실제 counter로 검증한다. filesystem/MIME·worker·lock·CoreText 부재는 숫자 0인 척하는 sentinel을 두지 않고 중립 모듈 import 경계와 코드 검토 대상으로 명시한다. 상세 hard gate는 [performance-budget.md](performance-budget.md#파일-탐색기-scrollbaricon-예산)가 소유한다. 기존 Octicons 자산으로 표현할 수 없는 SVG를 추가하면 exact name/version/source/license를 `third-party-licenses.md`에 기록하고 generator의 manifest/hash/`--check`가 coverage/C/Zig registry drift를 실패시킨 뒤에만 포함한다.

## 3.5 도크 뷰 스위처 (여러 뷰를 담는 하나의 도크)

**도크는 이제 뷰 하나가 아니라 뷰 여러 개를 담는 컬럼이다.** 상단에 아이콘 한 줄(뷰 바)이 있고 그 아래가 **현재 뷰**의
본문이다. 탐색기는 그중 하나다.

```text
┌ 도크(우측 고정) ───────────────────────┐
│ [탐색기] [소스 컨트롤] [AI 세션]       │ ← 뷰 바: pane 탭 바와 **같은 높이**(공유 chrome token)
├────────────────────────────────────────┤
│ 현재 뷰 본문 (스크롤)                  │ ← Geometry.tree_content = 뷰 영역 전체
└────────────────────────────────────────┘
```

**새 도크를 만들지 않는다.** 폭 조절(outer divider)·접기·`⌘⇧E` 왕복·`FocusOwner.file_tree`·workspace 영속은 **뷰와 무관하게
도크 하나가 계속 소유**한다. 뷰는 그 안에서 무엇을 그릴지만 고른다. 이 선택이 "도크를 종류별로 늘리지 않는다"는 FP16 방향과
같은 결이다 — 컬럼이 둘이 되면 폭·접힘·포커스 규칙이 통째로 이중이 된다.

- **제목 행은 없다.** 뷰 바가 지금 보는 뷰를 이미 알려 주므로 `탐색기` 같은 제목을 글자로 한 번 더 적지 않는다(옛
  `Geometry.tree_header`는 제거했다). 그 자리는 아이콘 영역이 가져갔다.
- **바 높이 = 터미널 탭 바와 공유하는 chrome token이며 뷰·터미널 폰트와 무관하다.** 두 바는 같은 y에서 시작하므로 높이가
  갈리면 아래 경계선이 어긋나 보인다(사용자 보고). 그래서 둘 다 `space.bar_height_pt`(rich 40pt) 하나를 쓴다
  (`AppSession.chromeBarHeightPx`). **terminal cell은 `@max`로도 섞지 않는다** — 한때 `@max(pt, cell + 2*pad)`였는데
  그러면 terminal 폰트가 도크 기하를 정하게 되어 `font-scale-rects` fixture가 실제로 깨졌다(14pt↔24pt 도크 rect 12px 이동,
  `tab_bar_pad_y_px`가 backing px 고정이라 1x↔2x 비례도 이탈). 셀 항이 막으려던 것은 큰 폰트에서 탭 제목이 바 밖으로
  넘치는 것인데, 그 원인은 탭 제목이 terminal 셀 그리드로 렌더된다는 점이고 해법은 그 텍스트를 chrome 폰트로 옮기는
  것이지 chrome을 폰트에 묶는 것이 아니다(Ghostty·VS Code 모두 chrome을 콘텐츠 폰트에 묶지 않는다).

  **tui는 token 0이라 셀 파생(`cell_height + 2*tab_bar_pad_y_px`)으로 떨어진다.** tui는 셀 격자 정렬이 정체성이고 탭 바
  배경도 셀 한 행(`paneBarBgCell`)이라 그 경로에서는 폰트 파생이 요구사항이다. **어느 쪽이든 두 바가 같은 식을 쓰므로
  정렬은 유지된다.**

- **사이드바 헤더도 같은 두 밴드를 쓴다(창 전폭 정렬).** 창 상단은 좌우가 한 줄로 읽혀야 하므로, 왼쪽 사이드바 헤더의
  두 줄이 오른쪽의 두 밴드와 1:1로 대응한다.

  ```text
  y=0 ──────────────────────────────────────────────────────────
      [0, titlebar_strip_px)      신호등 띠
        왼쪽: 사이드바 헤더 아이콘 줄(🔔 ◧ ⚙ +)
        오른쪽: (터미널·도크는 이 띠 아래에서 시작)
      ────────────────────────────────────────────────────────
      [titlebar_strip_px, +bar_h) 상단 바
        왼쪽: 사이드바 검색 줄(🔍 Search)
        오른쪽: pane 탭 바 / 도크 뷰 스위처
      ────────────────────────────────────────────────────────
      그 아래                      본문
        왼쪽: 워크스페이스 카드 / 오른쪽: 터미널·도크 본문
  ```

  따라서 `sidebar_header_height_px = titlebar_strip_px + chromeBarHeightPx()`다. **예전에는 `cell_height × 3.0`이었고,
  그래서 왼쪽만 terminal 폰트에 묶여 있었다** — 14pt에서 검색 줄 중심이 45pt인데 탭 바 중심은 48pt였고(3pt 어긋남),
  헤더 하단은 54pt인데 상단 바 하단은 68pt였다(14pt 어긋남). 고정 오차가 아니라 **단위계 불일치**라 폰트를 키우면
  벌어진다(24pt면 헤더만 93pt로 늘어난다). 위 "terminal cell을 섞지 않는다"가 오른쪽 두 바에만 적용되고 사이드바
  헤더가 빠져 있던 것이 원인이다(사용자 보고 2026-08-09).

  **헤더 glyph의 세로 위치는 셀 격자가 아니라 밴드에서 나온다.** 두 줄을 각각 자기 밴드의 세로 중앙에 놓아야 하는데
  셀 row 인덱스는 `row × cell_height`만 표현할 수 있어 `2.17 × cell` 같은 위치를 못 만든다. 그래서 헤더를 아이콘 줄과
  검색 줄 **두 draw list**로 나눈다. 다만 두 줄의 처리는 **비대칭이고, 그 비대칭은 필수다**.

  - **아이콘 줄은 origin `(0,0)`을 유지한다.** 렌더러가 `origin_x == 0 && origin_y == 0`을 헤더 셀의 **식별자**로 쓰고
    있고(`maru_metal_renderer.m`), 그 판정이 `◧⚙+🔔`의 1.7× 합성 아이콘 확대를 켠다. origin을 옮기면 헤더로 인식되지
    않아 아이콘이 셀 크기로 쪼그라든다. 대신 이 줄의 세로 정렬은 렌더러가 이미 접힘 상태에 쓰던 **띠 중앙 공식**
    (`(titlebar_strip_px - cell_h) / 2`)을 펼침에도 적용해 얻는다 — 펼침에만 걸려 있던 `0.30ch` py_nudge는 띠 높이와
    무관한 근사여서 폰트가 커지면 다시 어긋난다.
  - **검색 줄만 px origin을 갖는 별도 frame이다.** `origin_y = titlebar_strip_px + (bar_h - cell_h) / 2`, `row = 0`으로
    두면 `py_top = origin_y`가 되어 정확히 밴드 중앙에 온다. 이 줄은 렌더러의 헤더 특수 처리(1.7× 확대·py_nudge·띠
    정렬)가 **전부 `row == 0` 조건에 묶여 있어** 원래도 아무것도 받지 않으므로, 헤더 식별자를 잃어도 잃는 것이 없다.
    `.status_bar`가 항목마다 자기 frame과 px origin을 갖는 것과 같은 패턴이다.

  ABI(`MetalFrame` 레이아웃·인자 순서)는 바뀌지 않는다. 렌더러 변경은 아이콘 줄 정렬 공식 하나뿐이고, 밴드 값
  (`titlebar_strip_px`)은 이미 Zig가 넘기고 있다 — 수치 계산은 Zig가 소유한다는 host-boundary 규칙 그대로다.

  hit-test(`sidebar.headerHit`)도 같은 밴드 경계를 본다. "그려진 것 = 클릭되는 것"이 이 컴포넌트의 규약이므로, 렌더가
  밴드로 옮겨 가면 hit-test가 셀 row에 남아 있을 수 없다.

  ~~**남은 결함과 그 이관 계획.**~~ → **이관 완료(2026-08-29 재확인).** 아래는 착수 전 서술이고, 그 결함은 이미 닫혔다 — 검색 줄과 pane 탭 제목이 **둘 다 chrome measured 경로로 옮겨 갔다**(`sidebarSearchCaretRect` 가 "렌더가 measured로 옮겨 갔으므로 셰이핑된 advance에서 얻는다"고 적고, pane 탭 제목도 measured 높이를 쓴다). 아래 선행 조건 셋은 **그때 무엇이 필요했는지의 기록**으로 남긴다.

  <details><summary>착수 전 서술(보존)</summary>

  위 밴드는 *위치*만 정한다. 밴드 안 텍스트는 여전히 terminal 셀 그리드로 그려지므로,
  큰 폰트에서 셀이 40pt 바를 넘으면 검색 글자와 탭 제목이 밴드 아래로 삐져나온다. 근본 해법은 그 텍스트를 chrome
  measured 경로(`platform/macos/chrome/system_text.zig`)로 옮기는 것이다 — measured 텍스트의 line box는 role 토큰(pt)에서
  나와 폰트에 불변이므로 밴드 안에 정확히 들어간다.

  </details>

  착수 전에 **다음 세 가지가 선행 조건**이다. 검증에서 드러난 순서이며, 건너뛰면 되돌아온다.

  1. **measured 셰이핑 캐시를 다중 소비처로 확장한다.** 지금 캐시는 도크 전용 단일 슬롯(fingerprint 하나)이다. 그런데
     `rebuildSidebar`·탭 바 rebuild는 hover·드래그·탭 전환 등 tick 사이의 수십 개 이벤트 핸들러에서 불린다. 캐시 없이
     옮기면 마우스를 움직일 때마다 CoreText 셰이핑이 돈다. `richTextFingerprint`는 순수 함수라 그대로 재사용할 수 있고,
     `collectMeasuredTextFromCache`도 dest를 받으므로 슬롯만 소비처별로 늘리면 된다.

     **슬롯 하나는 "프레임당 한 번 발행하는 소비처"를 전제한다.** `MeasuredTextCache.store`는 새 아티팩트를 넣기 전에
     옛 것을 **해제**하는데, `collectMeasuredTextFromCache`는 아티팩트를 복사하지 않고 슬라이스 참조만 `collected`에
     실어 두었다가 **프레임 말미**에 읽는다(`system_text.appendGpuGlyphs`가 `placements[i]`로 좌표·색을 정한다).
     그래서 한 소비처가 한 프레임에 두 번 이상 store하면 **뒤 발행이 앞 발행의 아티팩트를 해제**해, 앞의 텍스트가
     조용히 사라지거나 엉뚱한 좌표로 날아간다. 해제된 버퍼가 다음 셰이핑에 재사용되는지에 따라 갈리므로 레이아웃을
     조금만 바꿔도 증상이 오락가락하고, 단위 테스트로는 잡히지 않는다(다중 pane 탭 제목에서 실제로 겪었다).

     **소비처가 화면에 여러 개 있으면 슬롯을 늘리지 말고 op을 모아 한 번에 발행한다.** measured op의 origin은 창
     절대 좌표라 아티팩트 하나가 같은 종류의 모든 인스턴스를 담을 수 있다(pane 탭 제목의 `TabTitleBatch`가 그 예다 —
     pane 루프는 쌓기만 하고 루프가 끝난 뒤 한 번 셰이핑한다). 인스턴스마다 슬롯을 두면 개수가 가변인 소비처에서
     슬롯 수명 관리가 따라붙고, 캐시 hit률도 나빠진다.
  2. **오버플로 앵커를 measured 경로에 전달한다.** 입력 줄은 넘칠 때 **앞을 잘라야** 한다 — caret과 방금 친 글자가
     문자열 끝에 있어서, 뒤를 자르면 지금 입력하는 곳이 화면 밖으로 나간다. 셀 경로는 이것을
     `chrome.components.overlay_input.inputLineView`(tail 창 + 선두 `…`)로 풀고 사이드바 검색·find·palette가 공유한다.

     **이 규칙을 픽셀 도메인으로 다시 구현할 필요는 없다.** `chrome.draw.Op.text`에 이미 `anchor: .head | .tail`이 있고
     CoreText가 `kCTLineTruncationStart`로 "앞을 자르고 앞에 `…`"를 네이티브로 지원한다. measured 경로가 그 앵커를
     브리지까지 흘리기만 하면 된다(`Request.Run`에 anchor, 브리지에 truncation type 인자). 즉 **소비처를 한 단계에
     묶을 필요가 없고**, 옮긴 소비처는 `inputLineView`를 더 이상 쓰지 않으며 남은 소비처는 계속 그 함수를 공유한다.
  3. **tui는 이관 대상이 아니다(사용자 결정 2026-08-09).** tui는 셀 격자 정렬이 정체성이고 탭 바 배경도 셀 한 행이라
     measured 텍스트를 얹으면 룩이 깨진다. [Chrome 전략](chrome-strategy.md)의 "TUI 룩은 최종적으로 제거한다"·"새
     component에 TUI fallback을 추가하지 않는다"를 따라 **rich만 이관하고 tui는 셀 경로를 그대로 둔다.** 두 경로는 tui
     제거까지 공존하며, 그동안 tui 쪽에 새 기능을 얹지 않는다.

  이관 순서는 **캐시 확장 → 사이드바 검색 줄 → 탭 제목 → (남으면) find·palette**다(사용자 결정: 단계적으로 나눠 각
  단계를 독립 PR로). 캐시는 나머지 전부의 선행 조건이다. 사이드바 검색 줄을 먼저 두는 이유는 그것이 **바 밴드를
  넘치는 두 곳 중 하나**라 이 이관의 실제 목적이기 때문이고, 위 (2)에서 앵커를 브리지로 흘리면 단독으로 옮길 수
  있음이 확인됐다. 탭 제목은 hit-test(`segCols`)가 셀 칸을 유지해도 되어(칸→`colPx()` 변환 구조) 파급이 작다.

  **find·palette는 이 이관의 대상이 아니다.** 둘은 화면 중앙 오버레이 패널이라 40pt 바 안에 있지 않고, 따라서 밴드를
  넘치는 결함이 없다. 셀 경로에 남겨 두어도 이 문서가 고치려는 문제와 무관하다. 옮긴다면 이유는 "가변폭 정확한
  셰이핑"이지 정렬이 아니므로, 별도 근거가 생길 때 판단한다.

  **증상 완화(raster clamp)는 하지 않는다.** `cache_key.raster_*_px`를 주입하면 셀 배수 대신 임의 크기로 직접
  래스터되므로(헤더 아이콘 1.7× 확대가 쓰는 그 메커니즘), 바를 넘는 경우에만 텍스트를 축소해 증상만 없앨 수도 있다.
  훨씬 싸지만 곧 지울 코드가 되고 `inputLineView`의 셀 도메인도 그대로 남아, 위 순서대로 근본 이관을 진행한다.
  1단계가 끝나기 전에 큰 폰트 사용자가 실제로 불편을 겪을 때에 한해 임시로 검토한다.

  **정렬을 terminal 식으로 맞추지 않는다.** 예전에는 탐색기·소스 컨트롤만 `paneBarHeightPx`를 그대로 받았고, 그러면 **같은
  아이콘 세 개가 뷰를 바꿀 때마다 오르내리고**(실측 53px ↔ 80px, 사용자 보고) 터미널 폰트가 도크 기하를 정하게 된다. 지금은
  방향이 반대다 — 도크가 터미널 식을 물려받는 게 아니라, 터미널 탭 바가 도크가 쓰던 40pt 하한을 **함께 본다**. 그래서 뷰
  전환은 여전히 아이콘 위치를 움직이지 않고, 폰트를 키우면 두 바가 함께 커진다
  ([agent-session-list-layout.md](agent-session-list-layout.md) §2.1.3이 예고한 "두 chrome이 공유하는 logical token" 해법이다).
  바 높이를 넣으면 본문이 사라질 만큼 도크가 낮으면 바를 접는다 — 스위처가 콘텐츠를 굶기지 않는다.

  **시작선도 같은 이유로 하나다.** 도크는 터미널과 **같은 상단 띠**(`titlebar_strip_px`)에서 시작한다. 예전에는 도크만
  28pt 고정 safety band를 따로 받았는데, 높이를 맞춰 놔도 시작이 갈리면 아래 경계선은 여전히 어긋난다 — 사이드바를 접어
  띠가 30pt(신호등 세로 높이)로 바뀔 때가 그렇다. `dock_layout`은 이제 기준선 입력을 하나만 받아(`titlebar_height_px`)
  갈래 자체가 없다.

  그 띠도 **폰트 독립**이다(`computeTitlebarStripPx` = 펼침 28pt / 접힘 30pt). 예전에는 `@max(cell_height, pt)`라 큰
  폰트에서 셀 항이 이겼는데, 이 값은 도크 시작선이기도 해서 terminal 폰트가 도크 rect를 밀어냈다 — 바 높이와 똑같은
  결함이고 같은 fixture가 잡았다. 확보해야 하는 것은 **신호등 세로 높이**이지 터미널 한 줄이 아니므로 pt 하나면 충분하다.

  바 높이가 `cell_height + 2*pad`와 항상 같지는 않으므로, **바 안 텍스트의 세로 오프셋은 pad가 아니라 실제 바 높이에서
  파생한다**(`chromeBarTextOffsetY` = `(bar_h - cell_height) / 2`). 탭 제목·파일 헤더 밴드·주소 밴드·IME caret이 모두 이
  식을 공유한다 — 한 곳만 pad로 남으면 하한이 이기는 구간에서 그 글자만 바 위쪽에 붙는다.
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
| 소스 컨트롤 | git | 변경 목록·스테이징 | [editor-surface-dock.md](editor-surface-dock.md) §3.5 |
| AI 세션 | 코드 | 창의 **모든 탭**을 가로지르는 에이전트 세션 목록 | 아래 |

**AI 세션 뷰.** 행 문자열은 사이드바 에이전트 행과 **같은 출처**(마지막 사용자 프롬프트 우선 + 상태 마커)를 쓴다 — 같은 것을
두 곳에서 다르게 부르지 않는다. 사이드바가 워크스페이스 카드별로 나누는 것과 달리 이 뷰는 **창 전체를 한 목록**으로 낸다.
그게 이 뷰가 사이드바와 별개로 존재하는 이유다. 활성 Term의 세션은 강조색으로 표시한다. 표시 형태의 단일 출처는
[사이드바 에이전트 목록](sidebar-agent-list.md)이고 이 뷰는 그 데이터를 다른 묶음으로 보여 주는 것이다.

## 4. 트리 계약

- **배치**: 트리가 **도크의 현재 뷰 영역 전체**다 — `Geometry.tree = dock - view_bar`(§3.5)이고 `editor`/`tab_bar`/`header`/`content`/`tree_divider` rect와 그 hit-test·드래그(`treeDividerHitRect`·`treeSizePtForPointer`·`dock_tree_divider` 제스처)는 삭제됐다. 도크 폭이 곧 트리 폭이라 폭 조절은 outer divider 하나뿐이다(`dock.tree_size`와 `dock-tree-size` 키는 B-4에서 제거했다 — 도크 폭이 곧 트리 폭이라 잴 것이 없다). 부작용: **트리 좌측 가장자리가 outer divider의 grab band와 겹친다**(옛 배치에선 트리가 우측이라 안 겹쳤다). 그래서 `min_editor_cols`(28셀)·`min_tree_cols`(12셀)·`default_tree_cols`(18셀) 상수와 editor↔tree divider도 함께 사라졌다(B-4에서 삭제). 남은 폭 하한은 pt 기준 `min_right_pt`를 계속 강제한다(`@max(requested_px, @min(min_dock, max_dock))`). 옛 420pt 기본·240pt 하한은 **editor + tree를 함께 담던 시절의 값**이라 트리 전용에는 과했다(화면 절반 가까이 차지 — 사용자 확인 2026-07-28). 자동 도크(`dock.size == 0`)의 탐색기·소스 컨트롤은 좌측 사이드바와 같은 성격의 목록 열이므로 **기본 180pt·하한 120pt**(`theme.SidebarConfig.width_pt`의 기본·범위와 같은 값. 레이어가 달라 상수는 공유하지 않고 값만 맞춘다)을 쓴다. `agent_sessions`만 같은 자동 sentinel에서 480pt를 쓰는 consumer-specific 예외이며, 수동으로 저장한 0 이외 폭은 어느 뷰도 바꾸지 않는다([agent-session-list-layout.md](agent-session-list-layout.md) §2.1). bottom은 가로 띠라 성격이 달라(폭이 아니라 높이) 300/160pt를 유지한다. 폭 조절은 이제 **terminal↔dock outer divider 하나**가 담당하며, 그 divider가 곧 트리 폭이다(현행 `dock-size`가 그 값이다 — `dock-tree-size`는 **키 자체가 제거**돼 더는 쓰지도 읽지도 않고, 옛 파일의 그 키는 unknown field 관용으로 조용히 무시된다). 확장 grab band·live reframe·mouse-down offset 보존 계약은 outer divider에 그대로 남는다. **트리 자체는 WKWebView가 아니라 GPU 셀 chrome이므로 도크에 web surface가 하나도 없고**, 그 결과 §4의 도크-aware 예외 둘이 제거된다.
- **루트**: inferred mode에서는 열린 파일이 git repo 안이면 repo 루트, 밖이면 부모 폴더를 합류시킨다. explicit mode에서는 open/add/remove 명령만 표시 root를 바꾼다. 서로 겹치지 않는 루트는 멀티루트 섹션으로 두고, parent/child로 겹치면 가장 바깥 ancestor 하나로 정규화한다. ~~root가 없으면 cwd를 암묵 추가하지 않고 빈 안내를 표시한다.~~ → **root가 없으면 §1의 자동 따라가기가 활성 터미널의 저장소를 root로 세운다**(2026-08-11 결정). 빈 상태에서 "아무것도 없음"을 보여 주는 것보다 지금 일하는 곳을 보여 주는 편이 맞고, root **밖**과 root **없음**을 다르게 다룰 이유가 없다. 터미널이 cwd를 안 주면(파일 Term·원격 세션) 예전대로 빈 안내다.
- **내용**: 폴더 접기(lazy 열거), 파일 클릭=열기(§6), 열린 파일 하이라이트 + dirty 점, **최근 파일 접이식 섹션**(파일 열람 히스토리 흡수처).
- **선택과 키보드 포커스(ABI v127)**: 트리는 row index가 아니라 `절대 경로 + row kind` identity로 transient selection을 소유한다. scan 완료·접기·FSEvents rebuild로 row index가 바뀌어도 같은 row가 남으면 선택을 복원하고, 사라지면 가장 가까운 조작 가능한 조상/이웃으로 결정적으로 이동한다. 클릭 또는 `focus_file_tree`가 Zig의 단일 `FocusOwner`를 `.file_tree { restore_surface: ?surface_id }`로 바꾸고 Metal view를 first responder로 만든다. 현재 구현의 기본 `⌘⇧E`는 이 action에 연결되어 있으며, FP9에서 §3.4의 `toggle_file_panel_focus`로 기본 chord만 이전한다. surface id는 앱 전역 비재사용이라 generation token을 겸하며 Esc 때 entry와 native WKWebView 존재를 다시 검증한다. `file_tree_focus`는 이 union의 파생 getter일 뿐 별도 mutable boolean이 아니다. 선택과 keyboard focus는 workspace에 저장하지 않는다. 포커스 중 선택은 theme accent 배경과 WCAG 4.5 이상 대비가 나는 파생 전경을 marker·이름·dirty/conflict 표시 전체에 적용하고, 포커스 밖에서는 dim으로 그린다. active 파일 표시는 별도 marker로 유지한다.

  ⚠️ **그래서 트리를 통째로 갈아끼우는 자리도 선택을 지우지 않는다**(2026-08-27 사용자 보고 — "열면 맨 위로
  팅겨서요"). 파일을 열면 트리 상태가 바뀌므로(MRU·root 합류·ancestor 펼치기) 사본에 만들어 한 번에 교체하는데
  (`commitFileTreeCandidate`), 그 함수가 첫 줄에서 선택을 지우고 있었다. 그러면 선택이 사라진 자리에서
  `reconcileFileTreeSelection` 이 「포커스가 트리에 있으면 첫 행」규칙으로 떨어져 **스크롤이 맨 위로 튄다** —
  목록을 내려 파일을 하나 열 때마다 그 자리를 다시 찾아 내려와야 했다.

  **루트커즈는 정책이 기계와 한 몸이었던 것**이다. 그 함수는 2026-07-20 에 **root 교체 전용**으로 태어났고
  (`220c09dd`), 그때는 호출자가 직후에 같은 clear 를 한 번 더 부르는 중복이었다. 파일 열기가 같은 헬퍼를
  재사용하면서 root 교체용 정책만 따라왔다. 지울 필요도 없다 — 위 문단대로 선택은 신원 기반이라 `reconcile`
  이 새 목록에서 같은 항목을 찾고 **없으면 스스로 지운다**. 초기화가 실제 정책인 자리(root 교체·제거, 선택된
  항목의 삭제)는 그 호출자가 계속 자기 손으로 부른다.

  ⚠️ **그리고 재투영은 스크롤도 뺏지 않는다**(2026-08-28 사용자 보고 — "선택한 것보다 밑으로 내려가면
  스크롤이 원복된다"). 위 수정으로 선택은 살아남게 됐는데, 이번에는 `reconcileFileTreeSelection` 이
  살아남은 그 선택으로 **매번** `scrollFileTreeRowIntoView` 를 걸고 있었다. 재투영은 사용자 조작과
  무관하게 돈다 — FSEvents, 배경 스캔 완료, git ignore 판정 도착, 활성 파일 변경이 전부
  `file_tree_rows_dirty` 를 세우고 `updateFileTree` 가 매 frame tick 그것을 본다. 그래서 목록을 선택
  행보다 아래로 내려 두면 다음 tick 이 그 자리를 선택 행의 top 으로 되감았다(위 §1 정책 4 의 `top <
  offset` 갈래가 그 되감기다).

  **정책 4 의 "필요할 때"는 그 선택을 아직 안 보여 준 때이지 목록을 다시 그린 때가 아니다.** 그것을
  `reconcile` 의 반환값으로는 못 가른다 — 제자리 exact match 에서도 인덱스가 나오는 것이
  `reconcileIdentity` 의 첫 갈래다. **`Selection.generation` 만으로도 부족하다**: 생성·이름변경은 행이
  투영되기 **전에** `setIdentity` 로 선택을 예약해 그 시점에 generation 을 올리므로, "바뀌었나"로 물으면
  정작 새 항목이 도착한 재투영이 "제자리"로 보여 방금 만든 파일이 뷰포트 밖에 조용히 남는다. 그래서 축을
  하나 더 둔다 — `file_tree_revealed_selection_generation` 이 **보여 준 신원**을 기억하고, 스크롤을 실제로
  건 자리(`setFileTreeSelection`·이 함수)만 그 값을 옮긴다.

  **그리고 보여 주지 못했으면 기록하지 않는다.** `scrollFileTreeRowIntoView` 는 렌더 메트릭이 아직
  없거나(첫 프레임 — `fileTreeRowHeightPx` 가 0) 도크가 접혀 뷰포트가 0이면 아무것도 못 하고 돌아간다.
  그때도 "보여 줬다"고 표시하면 **도크를 다시 열어도 그 선택은 영영 뷰포트 밖에 남는다** — 재투영은 매
  tick 도니 도크를 접어 둔 채 파일 하나를 만들기만 해도 그 예약이 통째로 삼켜지는 자리다. 그래서 그
  함수는 "판정할 수 있었는가"를 `bool` 로 돌려주고 호출자는 참일 때만 기록한다.
  `scrollFileTreeToFollowedCwd` 가 같은 위험을 pending 유지로 다루는 것과 같은 규율이다.

  결과: 행이 재정렬돼 인덱스만 달라진 경우(스캔이 형제를 끼워 넣는 흔한 경로)에도 스크롤은 사용자 것으로
  남고, 선택 행이 사라져 조상·이웃으로 옮겨간 경우와 아직 못 보여 준 예약이 도착한 경우에만 그 행을 보여
  준다. 판정자는 `test-macos-file-explorer-perf` 의 "file tree reprojection keeps the user's scroll unless
  the selection actually moved" 이고, 대조군 넷(선택 행 삭제 · `setIdentity` 예약 도착 · 보여 준 뒤
  다시 민 스크롤 · 렌더 메트릭 없는 동안의 재투영)이 없으면 그 단언은 reveal 호출을 통째로 지워도, 축을
  generation 으로 되돌려도, 보여 주지 못한 것을 기록해도 통과한다.
- **표준 탐색**: `↑/↓`는 이전/다음 조작 가능한 row, `←`는 열린 directory를 접고 그 외에는 부모 row, `→`는 닫힌 directory를 펼치고 이미 열렸으면 첫 자식, `Enter`는 directory toggle 또는 파일 열기, `Home/End`는 첫/마지막 row, `PageUp/PageDown`은 현재 tree viewport의 표시 row 수만큼 이동한다. 선택 이동은 같은 row layout/scroll 상태를 사용해 최소 거리로 scroll-into-view한다. `Esc`는 트리 진입 직전 도크 WKWebView를 복원하고, 없거나 stale이면 활성 terminal/browser pane으로 돌아간다. tree focus 동안 평문·IME와 terminal macro는 PTY로 전달하지 않는다.
- **파일 변경 명령**: `new_file`, `new_directory`, `rename_file_tree_entry`, `delete_file_tree_entry`를 command catalog와 project tree context menu에 노출한다. rename은 `F2`, delete는 `⌘Backspace`도 사용한다. project root/directory/file row만 대상이며 recent row/header와 root 자체의 rename/delete는 금지한다. 생성 위치는 선택이 directory면 그 안, file이면 부모다. 빈 이름·`.`·`..`·`/` 포함·기존 항목 충돌은 거부하고 dotfile은 허용한다.
- **identity 는 축이 셋이고 섞으면 안 된다**(2026-08-21 사용자 보고). 같은 경로라도 재는 방법마다 다른 값이
  나온다: `readdir`(순회가 준 inode — 부모 스캔이 자식 항목에 싣는 값) · `lstat`(`fstatat` +
  `SYMLINK_NOFOLLOW` — 링크 자신, 삭제·이름변경 가드가 쓰는 값) · `fstat`(열린 핸들 — 링크가 가리키는
  실체, **디렉터리 스냅샷 검증**이 쓰는 값). macOS 에서 셋은 실제로 갈린다 — 심링크(`/etc`·`/tmp`·`/var`)는
  물론이고 **firmlink**(`/Users`·`/private`·`/opt`·`/cores`)에서는 `readdir` 이 주는 합성 inode 가 `lstat`
  과도 다르다(실측: `Users` readdir=1152921500312570703 · lstat=14494 · fstat=14494).
  그래서 스냅샷 검증은 **`fstat` 축끼리만** 견준다(`file_tree.ScanIdentity`). 예전에는 부모가 준 값을
  기대값으로 삼아 직접 잰 값과 비교했는데, 재배치가 없어도 어긋나는 비교라 **첫 회부터 거짓 경보**였다 —
  탐색기 root 를 `/` 로 열면 `System` 을 뺀 거의 모든 항목이 걸려 "폴더가 바뀌었으니 다시 여세요" 안내가
  끊이지 않았고 조작이 막혔다. 첫 스캔은 기준선을 세우고(비교 없음) 그다음부터 재배치를 잡는다.
  **타입은 축을 표시할 뿐 봉인하지 못한다** — Zig 는 필드 프라이버시가 없어 `.{ .value = 아무거나 }` 를
  문법으로 막을 수 없다. 그 자리의 개수는 `tests/boundary/scan_identity_axis.zig` 가 고정한다(`cwd_axis`
  와 같은 결). `readdir`·`lstat` 두 축은 아직 타입이 없다(`Identity` 하나를 공유한다) — root 계열까지
  입히는 일이 남은 범위다.
- **root-pinned mutation capability**: 요청은 절대경로 문자열이 아니라 `{root_generation, root_fd, parent_file_id, leaf_name, leaf_dev, leaf_ino, leaf_kind}`를 소유한다. root부터 parent까지 descriptor-relative/no-follow로 열고 component boundary를 대조하며, symlink-directory는 표시·펼치기는 가능해도 생성 컨테이너가 될 수 없다. symlink row rename/delete는 parent descriptor 기준으로 링크 자체만 처리한다. create는 exclusive create/mkdir, rename과 delete staging은 macOS `renameatx_np(..., RENAME_EXCL)` 또는 동등한 atomic no-replace를 써 precheck 뒤 경쟁 생성도 덮어쓰지 않는다. confirm과 worker 실행 직전에 root/parent/leaf identity를 다시 검증하고 불일치면 아무 mutation 없이 실패한다.
- **휴지통 경계(ABI v129)**: delete 승인 뒤 worker는 확인된 leaf를 같은 parent의 예측 불가능한 **비-dot** staging 이름(`<원래 basename>.maru-trash-<request>-<nonce>`)으로 descriptor-relative atomic no-replace 이동한다. 예전 `.maru-trash-*` 이름은 Finder 휴지통 기본 보기에서 숨겨졌으므로 사용하지 않는다. AppKit adapter는 staged dev/ino/kind를 다시 확인한 뒤 `NSWorkspace.recycle`에 넘기고, 완료를 `not_moved / moved_verified / moved_unverified { last_known_destination? }`로 구분한다. 한 입력의 destination map과 휴지통 destination의 dev/ino/kind가 모두 일치한 `moved_verified`에서만 clean tab·recent·tree를 commit한다. `not_moved`만 staging→original rollback하며, 이미 이동했지만 검증할 수 없는 `moved_unverified`는 존재하지 않는 staged path를 rollback하지 않고 마지막 destination 또는 경로 불명 recovery 상태로 정상 종료와 후속 mutation을 차단한다. Foundation이 APFS에서 진짜 file-reference URL 대신 path URL을 돌려줄 수 있어 file-reference 여부를 안전성 전제로 두지 않는다. 공개 inode-conditional Trash/rename API가 없으므로 same-UID 프로세스가 마지막 identity 검사와 namespace syscall 사이에 경로를 악의적으로 교체하는 공격은 원자적으로 막지 못하며 명시적 위협 경계 밖이다. 경쟁이 감지된 결과에서는 모델 commit 없이 fail-close한다.
- **변경 안전성**: rename은 row 내부 `OverlayInput`을 재사용한다. dirty/dirty-sync-pending/external-conflict/reload-pending entry와 이를 포함하는 directory의 rename/delete는 차단한다. `DockPanel.Entry.path`가 열린 파일 경로의 유일한 권위이고 recent index만 함께 갱신하며, 다음 workspace capture가 entry path를 직렬화한다(별도 mutable workspace path cache를 두지 않는다). queue admission을 먼저 확보해 cap+1 거부는 plan allocation 0이고, main actor는 entry 256/recent 32 상한 안에서 target/generation과 영향 path를 **단일 contiguous snapshot allocation**으로만 복사한다(경로 join·개별 새 문자열 할당은 하지 않음). worker가 descendant 새 문자열을 모두 할당한 `PathRemapPlan`을 만들고, 성공 결과가 같은 tree/mutation generation일 때 main actor가 실패 없는 swap 한 번으로 적용한다. OOM/stale completion은 plan을 폐기하고 background coarse rescan만 예약한다. pin path가 바뀐 live WKWebView는 기존 surface를 폐기하되 비활성 view는 surface-less로 두고 재선택 시 lazy 재생성하며, 보이는 affected view만 bounded recreate queue에서 tick당 하나씩 새 surface id로 복구한다. delete는 확인 뒤 macOS 휴지통으로만 이동하며 영구 삭제와 undo는 제공하지 않는다. symlink는 링크 자체만 대상으로 하고, 휴지통 이동 성공 뒤에만 clean open 탭을 닫는다. 실패하면 tree/tab을 유지하고 notice를 표시한다.
- **비동기 mutation reservation**: submit 전에 영향 entry 전체에 `mutation_pending { request_id, root_generation, tree_generation, state_generation, file_identity }`를 설정한다. Markdown editable mode(`live-preview|source-edit`)는 먼저 revision sync와 read-only 전환 ack를 받아 clean을 재검증하고, mutation pending 동안 edit/save/reload/close를 막는다. `Mode.isEditable()`를 close/group-close/merge/LRU/rename/delete/exit/⌘Q/terminal auto-exit의 모든 clean-but-unsynced 보호가 공유한다(**FP16**: `LRU`와 `group-close`는 소비처가 사라지고 나머지는 그대로 — 공유 술어 자체는 유지한다). path swap 전에 old surface의 file bridge capability와 pending one-shot/ack를 revoke하며, revoke/read-only ack 실패면 FS mutation을 시작하지 않는다. success completion은 exact request+identity를 한 번 더 검증한 뒤 remap/close와 새 surface id 발급을 정확히 한 번 수행한다. failure는 원래 path/surface와 편집 가능 상태를 복원하고 late/duplicate completion 및 old surface의 read/write/setDirty를 거부한다.
- **rename kind 전이**: 확장자 판정은 기존 `openKindForPath`와 같은 ASCII case-insensitive `.md`/`.html` 단일 출처를 쓴다. `.md↔.html`은 성공 commit에서 `Entry.kind`를 다시 계산하고 mode를 `.read`로 강등하며 old bridge/WebView를 revoke한 뒤 해당 trust config의 새 surface id를 발급한다. 지원 확장자에서 비지원 확장자로 rename하면 FS rename 성공 뒤 clean file-panel entry를 닫고 tree selection은 새 파일을 유지한다. directory rename은 descendant basename 확장자가 바뀌지 않으므로 kind를 보존하되 모든 `{path, kind}`를 commit 전 재검증한다. mismatched live/workspace state는 허용하지 않는다.
- **변경 실행 경계**: create/rename은 bounded backend(request 64, in-flight 1, completion 16)에서 순서대로 실행하고 휴지통 이동만 AppKit adapter(queue 16, in-flight 1)가 담당한다. cap+1은 명시적 busy notice로 거부하며 pending을 남기지 않고, tick은 completion과 WKWebView recreate를 각각 최대 1개만 drain한다. user mutation 자체는 coalesce하지 않고 watcher/coarse-rescan만 `{root, deepest expanded ancestor}` key로 합친다. 현재 backend는 요청마다 `pump()`에서 `Job` allocation과 detached worker thread 생성을 수행하므로 frame tick의 blocking path lookup/read 0은 지키지만 completion descriptor close, thread-spawn/allocator 0까지 증명하지는 못했다. persistent worker+condition queue 전환은 별도 성능 gate다. worker completion은 검증된 kind·project root·경로 metadata와 필요 snapshot을 소유해 tick이 기존 동기 `openFilePanelPath`/`rebuildFileTreeFromDock`를 호출하지 않게 한다. mutation completion과 watcher event가 동시에 scan queue에 있으면 path key로 합치지만, staging rename·native completion·recycle이 서로 다른 FSEvents batch로 지연되면 이미 완료된 scan 뒤 추가 scan이 생길 수 있고 현재 엄격한 횟수 상한은 없다. provenance 없이 suppress하면 실제 외부 변경을 놓치므로 scheduler quiet-window를 도입하기 전에는 correctness를 우선한다. `NSWorkspace.recycle` callback이 오지 않으면 결과가 불명확하므로 자동 성공·재시도·unlock하지 않고 queue/exit gate를 유지한다.
- **층 배치**: `file_tree.zig`은 L2 root mode/snapshot/generation과 접힘을, `file_tree_icon.zig`은 중립 semantic classifier를 소유하고(스크롤바 기하는 공용 `chrome/ui/scroll_area.zig`이 가진다) `tests/boundary/imports.zig`가 import 방향을 고정한다. L3 renderer는 row와 semantic icon을 glyph cell로 투영할 뿐 root policy를 모르며, L4 AppSession/AppKit은 picker/context menu/gesture/fade/watcher adapter만 소유한다.
- **FS 백엔드는 완전 신규**(디렉터리 열거·감시 선례 0 — pty kqueue는 proc reap 전용): 이벤트 구동 watcher(FSEvents) + debounce + bounded queue. **frame tick의 blocking path lookup/read 금지**([performance-budget.md] micro-slice 규율 — bounded 증명 artifact). 완료 result가 소유한 descriptor close는 허용한다.
- **FP7 구현 정책(2026-07-17, 사용자 승인 — Zed Project Panel 기준)**: [Zed Project Panel](https://zed.dev/docs/project-panel)의 자연 정렬·폴더 우선·active/open 표시·lazy directory 경험과 [Zed settings](https://zed.dev/docs/reference/all-settings)의 `file_scan_exclusions`/expanded symlink 관례를 clean-room 기준으로 삼는다. 기본 제외는 `.git`, `.svn`, `.hg`, `.jj`, `CVS`, `.DS_Store`, `Thumbs.db`, `.classpath`, `.settings`이고 일반 dotfile·`.github`·`.env`는 보인다. 폴더와 symlink 폴더는 펼칠 때만 scan한다. 서로 다른 repo/부모는 multi-root로 합류하고 최근 32개를 MRU로 보존한다.
- **FP7 I/O 경계**: `src/session/file_tree.zig`은 최대 root 256·materialized node 16,384·directory child 4,096·scan request 1,024의 L2 snapshot만 소유한다. `file_tree_backend.zig` worker는 동시 scan 4·고정 완료 queue 16으로 `openDir/iterate/stat`을 수행한다. frame tick은 결과 queue를 drain해 snapshot/rows를 바꾸고 새 요청을 submit할 뿐 blocking path lookup/read를 수행하지 않는다. result 소유 descriptor의 close는 main actor 수명 정리다. backend 교체/세션 종료는 generation ref를 놓을 뿐 느린 FS worker를 main actor에서 기다리지 않으며 마지막 worker가 heap state를 회수한다. overflow/OOM은 event/result drop으로 영구 loading을 남기지 않고 root coarse rescan 또는 fail+retry로 회복한다. Swift FSEvents는 file-level + watch-root stream을 200ms latency로 main queue에 coalesce하고, dropped/must-scan/root-change flag는 모든 root coarse invalidate로 승격하며 stream 재구성 때 마지막 event ID를 이어 event-loss window를 닫는다.
- **root picker 보안(ABI v137)**: Swift `NSOpenPanel`은 directory-only 단일 선택 adapter이고 정책 상태를 소유하지 않는다. ABI one-shot `replace | add`와 선택 path를 받은 Zig가 위의 normalize/no-follow/identity 정책과 root transaction을 실행한다. 성공 commit만 watcher reset·lazy scan을 예약하고 실패·취소·busy는 `FileTreeRootOutcome`(`picker_canceled`, `invalid_path`, `busy`, `stale_generation`, `identity_changed`, staging 실패, `committed_replace|add|remove` 등)의 안정된 typed reason과 사용자 notice를 남긴다. frame tick에는 directory stat이나 picker I/O를 넣지 않는다.
- **외부 변경 정책**: clean으로 열린 Markdown은 shell의 직렬 mutation queue에서 disk 내용을 다시 읽고, clean HTML은 핀 URL을 reload한다. dirty/dirty-sync-pending이면 CM6 buffer를 덮지 않고 `external_change`를 latch해 트리·헤더에 `!`를 표시하며 저장은 `ExternalConflict`로 거부한다. 사용자가 헤더 `!`를 누르고 "다시 읽기" 확인을 통과하면 2-phase reload를 시작하고, web shell이 실제 disk read와 editor replacement 성공을 ack한 뒤에만 dirty/conflict를 내린다. 읽기 실패·취소·일반 clean ack는 원래 buffer 보호를 유지하며 reload 중 더 새 event가 오면 generation 불일치로 성공 ack도 conflict를 지우지 못한다. atomic save 직후 event는 background content hash가 저장 bytes와 같을 때만 자기 event로 소비하므로 grace 구간의 실제 외부 overwrite도 conflict가 된다. create/delete/rename은 가장 깊은 펼친 ancestor snapshot을 background에서 다시 만든다.
- **레이아웃 비용(2차 검증 정정)**: `termRect`(app_session.zig)는 폭(사이드바)+높이(titlebar strip) inset 선례가 이미 있고 파생 ~30 호출처가 자동 추종한다. **단 "한 곳"이 아니라 두 곳 동기 규율** — spawn/resize grid는 termRect 파생이 아니라 `gridFromBacking`+`gridPadding()` 별도 경로(호출처 3곳)라, 도크 inset도 titlebar 선례대로 rect 한 곳+grid 한 곳을 동기한다. 비용의 본체는 도크 자신의 렌더·스크롤·hit-test 배관(사이드바 급 신규) + ChromeProps 소비처 4곳(폭 기준 — modal_box·overlay_input·context_menu·dropdown) + **하단 도크의 높이 방향 추가 대상**(modal_box 세로 중앙[backing_height 전체 기준]·context_menu/dropdown 하단 clamp·notifications 가용 높이·settings 행 수). 추가 표면 2개(실측): ⑴ **web seam** — collectWebSurfaces가 "termRect 바깥 경계=divider 없음"을 가정(app_session/web.zig:206)해 도크 경계에 붙은 워크스페이스 web pane의 WKWebView가 도크 리사이즈 드래그를 삼킨다 → `seam_edges`에 도크 edge 비트 추가. ⑵ **드래그 중 WKWebView 가림 규범([web-panel.md] §3)은 현재 미구현**(4c 생략 상태) — 도크 리사이즈는 도크 웹뷰 자체가 매 tick resize라 FP3에서 실물 구현(드래그 세션 단위 hide)하거나 명시 백로그로.
