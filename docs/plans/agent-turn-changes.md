# 에이전트 턴 변경분 — 단계 계획

[에이전트 턴 변경분](../agent-turn-changes.md)이 정한 넷(훅 경계·AI 소행 확정·셸 사각지대 표시·스냅샷 영속)을
**무엇을 어느 순서로 만들고 각 단계를 무엇으로 검증하는가**만 정한다. 계약의 단일 출처는 그 문서이고, 그
아래 층(턴 경계의 의미·스냅샷 메커니즘·링 정책·화면 소유)은 [에디터 Surface 도구](../editor-surface-tooling.md)
§6.1과 [도크 소스 컨트롤 뷰](../editor-surface-dock.md) §3.5.4가 소유한다.

## 0. 전제 — 이미 도는 것

[scm-dock 2판 계획](scm-dock.md) **P5(2026-08-18 완료)** 로 아래가 제품에서 돈다. 이 계획은 그 위에만 얹는다.

- `session/turn_snapshot.zig` 링 8개(tree OID·`surface_id`·캡처 시각·`agent_kind`)
- `platform/macos/git_backend.zig` 스냅샷(`read-tree HEAD` → `add -A` → `write-tree`, 임시 index는 저장소 밖)
- `session/git_command.zig` `turn_name_status`(`git diff --name-status <treeA> <treeB>`)
- 에이전트 탭 턴 타임라인 + 파일 클릭 시 네이티브 diff 뷰

## 1. 단계

각 단계는 독립 PR이고 문서 갱신을 포함한다. **AT1과 AT5는 서로 독립**이라 순서를 바꿔도 된다.

### AT1 — 훅을 턴 경계 트리거로

- **선행: [훅 통합 계획](agent-hooks.md) AH1~AH3.** 전달 채널·설치·모드 판정은 그쪽이 소유한다.
- 이 단계가 하는 일은 이벤트를 **턴 경계로 해석**하는 것뿐이다: `SessionStart`→턴 0 스냅샷,
  `Stop`(단 `stop_hook_active` 무시)→턴 종료 스냅샷. 스냅샷 생성 코드는 건드리지 않는다(§6.1 메커니즘,
  수확 지점은 `app_session/git.zig`의 `takeSnapshotResult`).
- 턴 식별자(`prompt_id`/`turn_id`)를 링 항목에 싣는다 — AT3 귀속이 이 키에 의존한다(계약 §3.1).
- 관측 경로(`isTurnEnd`)는 관측 모드에서 그대로 남는다. 두 경로가 같은 링으로 수렴하되 **한 Term에서
  동시에 돌지는 않는다**(모드가 하나다).
- 검증: 이벤트→경계 해석 단위 테스트, `stop_hook_active` 무시, 턴 식별자 왕복, 모드별로 한 소스만
  링을 채우는지.

### AT2 — 턴 제목

- `Stop`의 `last_assistant_message`를 그 턴 라벨로 싣는다(양 provider 공통, 실측 확인).
- 링 항목에 제목 슬롯을 더한다. **`turn_snapshot.zig`는 순수 층**이라 문자열 소유 규칙을 지킨다(고정 버퍼 +
  길이, 할당 없음).
- 검증: 제목 절단·비ASCII·빈 문자열·개행 포함 케이스 단위 테스트.

### AT3 — provider 기록 파서 (AI 소행)

- 순수 모듈 신설: 세션 파일에서 **턴별 편집 경로 집합**을 뽑는다.
  - Claude: transcript user 라인 `toolUseResult{filePath, structuredPatch, …}`
  - Codex: rollout `patch_apply_end.changes{type, unified_diff, content, move_path}` + `turn_id`
- **경로 집합만 뽑는다.** 내용은 §6.1 tree 비교에서 오므로 diff 본문을 여기서 만들지 않는다(계약 §4.1 재생 금지).
- 셸 도구 호출 수도 함께 센다(AT4의 고지 줄용).
- 검증: synthetic·redacted JSONL fixture로 양 provider의 add/update/delete/rename, 손상 라인 무시,
  절대경로·저장소 밖 경로, 빈 턴.

### AT4 — 배지·고지 합류

- tree 비교 목록 ∪ AT3 경로 집합 → `✎ AI 편집` / `· 턴 중 변경` / `↩ 순변경 없음` 3분류.
- 셸 명령 수가 1 이상이면 고지 줄을 붙인다. 0이면 줄이 없다.
- git 저장소가 아니면 tree 비교가 없으므로 `✎` 목록만 렌더하고 머리에 불완전함을 명시한다.
- 검증: 3분류 분기 단위 테스트, git 아닌 디렉터리에서 목록이 서는지, 필터 토글이 기본 off인지.

### AT5 — 스냅샷 ref 고정

- **`<owner-key>`를 먼저 정한다**(계약 §6, A12). 요구는 둘이다 — ⑴ 창마다 달라야 하고(링이 창당 하나인데
  ref 이름 공간은 저장소 공유다) ⑵ **재시작을 넘어 안정적**이어야 한다. 현행 임시 index 키
  (`@intFromPtr(self)`)는 ⑵를 어기므로 쓸 수 없다. workspace restore가 이미 영속시키는 식별자를 후보로 본다.
- 링의 각 tree를 `refs/maru/turn/<owner-key>/<n>`으로 고정하고, 밀려나면 ref를 지운다. `gc`를 직접 부르지
  않는다.
- 저장소 교체 시 링을 버리는 기존 규칙에 **ref 삭제**를 더한다. 시작 시 자기 키 아래의 고아 ref만 정리하고
  **다른 키는 건드리지 않는다**(다른 창의 것일 수 있다).
- 검증: ref 생성·회전·삭제, `git gc --prune=now` 후에도 tree가 살아 있는지(임시 저장소 통합 테스트),
  창 두 개가 같은 저장소를 열었을 때 서로의 ref를 지우지 않는지, 재시작 후 같은 키로 자기 ref를 되찾는지.

### AT6 — git 아닌 워크스페이스 (보류)

- FSEvents 워처(`MaruAppHost.swift` FP7 어댑터) + 턴 안 첫 변경 시 1회 백업.
- **실제 수요가 생기기 전에는 만들지 않는다.** AT4까지면 git 아닌 곳에서도 `✎` 목록은 이미 선다.

## 2. 이 계획이 함께 고치는 현행 결함

| 결함 | 지금 | 고치는 단계 |
| --- | --- | --- |
| 화면 관측이 전이를 놓치면 두 턴이 하나로 합쳐지고 복구 불가 | `isTurnEnd`가 유일 트리거 | AT1 |
| 턴 목록에 사용자 편집이 섞여도 구분이 없다 | 근거 표기 없음 | AT3·AT4 |
| 앱 재시작 후 링이 비고, tree 객체도 `gc` 대상이라 복원 불가 | 메모리·창 로컬 | AT5 |
| 셸 편집 비중이 큰데 그 사실이 화면에 안 보인다 | 고지 없음 | AT4 |

## 3. 알려진 한계 (구현 전에 적어 둔다)

- **셸 편집의 소행은 끝내 모른다.** tree 비교가 "무엇이"는 답하지만 "누가"는 어떤 소스로도 답할 수 없다
  (계약 §2.3의 원리).
- **Codex `PostToolUse` payload가 미검증**이다. 그래서 AT3의 Codex 경로는 **rollout 파일 파싱을 1차**로 두고
  훅 payload에 의존하지 않는다. 검증이 채워지면 훅 경로를 보조로 얹는다.
- 링 8개 상한은 §6.1의 결정이라 이 계획이 바꾸지 않는다.
- 목록 자체의 디스크 영속(재시작 후 타임라인 복원)은 AT5 범위 밖이다. AT5는 **객체 보존**까지다.
- 훅 설치는 사용자 소유 설정 파일을 고친다. `sidebar.agent-transcript-hook`과 같은 계열의 **config 게이트**가
  필요하며, 기본값은 AT1 리뷰에서 사용자와 정한다.
- **AT1은 배관을 새로 만드는 단계다.** 초판 계획은 "기존 매핑 훅에 얹으면 된다"고 봤으나 코드 대조에서 그
  채널이 이 용도에 맞지 않음이 드러났다(계약 A11). 그래서 AT1의 실제 비용은 "훅 항목 추가"가 아니라
  **append 로그 + tail 소비기 + 설치/제거 규율** 셋이다. 이 단계를 작게 잡으면 안 된다.
- **`<owner-key>` 선정이 AT5의 선결 조건**이다(계약 A12). 후보가 workspace restore의 영속 식별자인데, 그
  값의 수명·재사용 정책을 먼저 확인해야 한다 — 재사용되는 id면 옛 창의 ref를 새 창이 자기 것으로 오인한다.
