# 재부팅 뒤 부활(RB) 구현 계획

**계약은 [workspace-restore.md](../workspace-restore.md) 「재부팅 뒤 부활(RB)」이 소유한다.** 이 문서는 그 계약을
**어떤 순서로 세울지**만 정한다 — 무엇이 옳은가는 저쪽, 언제 어떻게 짓는가는 여기다.

**결정(2026-09-23 사용자 결정)**: 맥을 껐다 켜면 ⑴ 터미널이 저장된 cwd에서 새 셸로 자동으로 뜨고 ⑵ 로컬
claude·codex가 돌던 Term은 그 대화를 이어간다. 스크롤백·화면 내용·일반 명령은 범위 밖이다. 재부팅이 아닌 세션
소실은 지금처럼 묘비와 `⏎`로 남는다.

## 왜 이렇게 나누나

두 축은 **서로 없이도 선다**. 새 셸 자동 실행은 에이전트를 몰라도 말이 되고(RB1), 에이전트 이어가기는 「재부팅이
증명됐다」는 한 비트만 RB1에서 빌린다(RB2). 한 PR에 몰면 「셸이 안 떴다」와 「대화가 안 이어졌다」 중 어느 축이
깨졌는지 판정이 안 선다.

## 이미 있는 재료 (2026-09-23 코드 대조)

| 필요한 것 | 있는 자리 | 이 계획이 하는 일 |
|---|---|---|
| 새 셸을 저장 cwd로 띄우는 요청 | `pane.zig` `restoreSpawn` — in-process Term이 이미 이것으로 뜬다 | 재부팅 증명이면 host identity Term도 이 길로 보낸다 |
| 복원 한 Term의 단일 분기점 | `pane.zig` `createRestoredTerm` — 묘비·attach·spawn이 여기서 갈린다 | 맨 앞에 「재부팅 증명」 갈래 하나 |
| 복원 뒤 알림 | `recordEndedPlaceholder` → `ended_placeholder_notice_pending` | 같은 모양의 부활 카운터 |
| Term의 에이전트·신원 | `term.agent_kind`, `primaryHookSlot(…).transcript.identity()` | 캡처가 읽는다 |
| 대화 파일 찾기 | `agent.zig` `refreshClaudeTranscript`(cwd slug)·`refreshCodexTranscript`(`findCodexByThreadId`) | 경로 계산만 떼어 공유한다 |
| 권한 모드·모델 → argv | `agent_session_archive.zig` `Parser`·`resumeArgv` | 끝부분만 먹이는 입구 하나 |
| provider를 로그인 셸로 띄우기 | `agent.zig` `resumeAgentSessionInNewTerm`·`buildResumeShellCommand` | spawn 요청 조립을 떼어 도크와 공유한다 |

## RB0 — 계약 (이 PR)

- workspace-restore.md에 「재부팅 뒤 부활(RB)」 절, 표의 재부팅 행을 둘로 가른다.
- 뒤집히는 문장에 예외 링크: persistent-session-host.md(비목표·§7)·agent-session.md·window-surface-mobility.md·
  terminal-compatibility-policy.md·implementation-plan.md(P1 절).
- verification-matrix.md에 RB 행(계획).

## RB1 — 재부팅을 증명하고 새 셸을 띄운다 (완료)

**구현하며 계획과 달라진 것 셋**(계약은 그대로다):
- 「부활 직후 checkpoint를 더럽힌다」는 복원 자리에서 할 수 없었다 — checkpoint는 복원이 **끝난 뒤** 무장되고
  무장 전의 `markChanged`는 버려진다. 그래서 앱 전역 표식(`AppSession.reboot_revival_checkpoint_dirty`)을 세우고
  `maru_macos_workspace_checkpoint_arm`이 한 번 소비해 `initial_dirty`에 OR 한다.
- 묘비(`ended`)를 되살리면 복원 끝의 `assignEndedManifestOrdinals`(파일의 `ended`마다 짝이 되는 묘비 Term을
  요구한다)가 「ended인데 묘비가 없다」를 손상으로 읽어 창 전체를 실패시켰다. 재부팅 증명일 때 그 단계를 건너뛴다 —
  짝 맞출 묘비가 원래 없다.
- 판정자의 keep-alive는 **세션을 만든 뒤에** 켜야 한다 — 테스트 하니스(`initSmokeSessionSized`)가 keep-alive를
  끄고, 꺼진 채면 `createTerm`이 identity를 무시해 「identity를 비우지 않는다」 변이가 살아남는다(실제로 그랬다).

- **`boot-session` 읽기**: OS 중립 층은 값을 모른다 — macOS 층이 `sysctlbyname("kern.bootsessionuuid")`로 읽어
  넘긴다. 형식 검사(36자, `8-4-4-4-12` 16진)는 순수 층 하나가 소유한다(쓰는 쪽·읽는 쪽이 같은 함수).
- **포맷**: `workspace.Window`에 `boot_session` 필드. writer는 값이 있을 때만 `boot-session="…"`, reader는 형식이
  깨지면 **빈 값**(키 없음과 같다). 옛 파일 byte 고정점을 안 바꾼다(빈 값이면 생략).
- **판정**: 순수 함수 `rebootProven(windows, current) bool` — 유효한 값이 하나 이상이고 전부 `current`와 다를 때만
  참. `current`가 비면 거짓.
- **판정은 창 목록 전체로**: 창마다 `AppSession`이 따로이고 각자 자기 블록만 복원한다. 자기 창의 값만 보면 창끼리
  갈릴 수 있다. 다행히 각 창의 apply(`maru_macos_app_session_apply_workspace_window`)가 **파일 전체를 다시
  파싱**하므로, 그 자리에서 `windows` 전체로 판정해 넘기면 같은 텍스트라 모든 창이 같은 답을 얻는다.
- **복원**: 그 값을 받은 창의 `createRestoredTerm` 맨 앞에서 참이고 host identity가
  있으면(`runtime_host_id`·`runtime_id` 어느 하나라도, `runtime_state` 무관) identity를 비운 `restoreSpawn` 요청으로
  `createTerm` — attach·probe·묘비 없음. 부활 카운터 +1.
- **알림**: 창마다가 아니라 **앱에 한 번**(창 셋이면 셋이 뜨면 안 된다). 개수만 싣는다(cwd는 싣지 않는다 —
  redaction 기준). 문구는 i18n 표(ko·en)에 둔다.
- **checkpoint**: 부활이 하나라도 있었으면 `workspaceChanged(.runtime_binding)`.
- **판정자**
  - 포맷: 왕복 · 형식 손상 → 빈 값 · 빈 값이면 줄에 키가 안 나온다(옛 고정점).
  - 판정: 증명 없음(키 없음) · 지금 값 못 읽음 · 값 같음 · 창 둘 중 하나만 같음 → 거짓. 전부 다름 → 참.
  - 복원: 증명된 복원이 live·ended·legacy 세 모양 모두에서 **attach 시도 0**(restore identity 채널이 빈 채로
    `createTerm`에 닿는다) · 저장 cwd가 요청에 실린다 · 묘비 0. 증명 없는 복원은 지금과 같다(기존 묘비 판정자
    그대로 초록).
  - 변이: 판정 함수를 `true`로 · identity 비우기 제거 · ended 갈래 누락 — 각각 한 판정자가 죽어야 한다.

## RB2 — 에이전트 대화를 이어간다 (완료)

**구현하며 계획과 달라진 것**(계약은 그대로다 — 계약 문서에는 4번 조건과 공유 자리 이름만 더했다):
- 「첫 줄은 잘렸을 수 있어 버린다」를 새 입구에 두지 않았다 — 그 규칙은 사이드바 대화 줄이 이미 쓰는
  `agent_transcript.readTail` 이 소유하고 있었다. 두 벌이면 갈리므로 `feedResumeTail` 은 온전한 줄만 먹이고,
  `readTail` 에 그 규칙의 판정자(RB2-5)를 붙였다(없었다).
- 저장 cwd 가 사라진 claude Term 은 이어가지 않는 조건을 더했다. 첫 판의 가드(`req.cwd == null`)는
  `spawnRequest` 가 기본 cwd 를 미리 채워 영영 거짓이었고, 둘째 판(`usableRestoreCwd`)은 형식만 보는 필터라 없는
  디렉터리를 통과시켰다 — 판정자 RB2-8 이 둘 다 잡았다. 디렉터리를 실제로 연다.
- 종류가 바뀔 때의 뒷정리를 `noteAgentKind` 로 떼어 냈다. `pollAgentKinds` 는 진짜 포그라운드 프로세스를 읽어
  판정자가 종류 변화를 흉내 낼 수 없었다(이름이 `claude` 인 실행 파일을 테스트가 만들 수 없다 — 복사한 시스템
  바이너리는 커널이 죽이고, 심볼릭 링크는 원래 이름으로 보인다).
- 부활 요청 조립(`rebootRevivalSpawn`)을 `createTerm` 과 떼어 냈다 — 판정자가 진짜 `claude` 를 띄우지 않고(계정
  세션이 열린다) 요청만 잰다. 끝까지 도는 판정자는 도크 스모크의 가짜 provider 자리를 `/usr/bin/true` 로 쓴다.

- **포맷**: `workspace.Surface`에 `agent_resume: ?{provider, session_id}`. writer는 있을 때만
  `agent-resume="claude:<id>"`. reader는 provider·토큰 규칙 위반을 **없는 것**으로.
- **캡처**: `captureWorkspaceTab`의 터미널 갈래 — 로컬·`agent_kind`·신원·비원격·비묘비일 때만.
- **갱신 신호**: `agent_kind`가 바뀌는 자리와 신원을 채택하는 두 자리(`refreshAgentSessionIdentity`·
  `adoptHookSessionIdentity`)에서 checkpoint를 더럽힌다.
- **힌트 읽기**: 순수 층에 「끝부분 바이트 → 마지막 권한 모드·모델」 입구 하나(`Parser.consumeLine`을 그대로
  쓰고 `finish`를 거치지 않는다 — codex는 머리의 `session_meta`가 끝부분에 없다). 첫 줄은 잘렸을 수 있어 버린다.
- **대화 파일 경로**: claude slug·codex 조회를 `refresh*Transcript`에서 떼어 둘이 공유한다.
- **실행**: `resumeAgentSessionInNewTerm`의 spawn 요청 조립을 떼어 도크와 부활이 공유한다(셸 래핑·ZDOTDIR·cwd 규칙이
  한 자리). 부활 쪽은 `createRestoredTerm`의 재부팅 갈래에서 그 요청으로 `createTerm`.
- **판정자**
  - 캡처: 네 조건 각각을 하나씩 깬 Term에서 키가 안 나온다 · 다 맞으면 나온다.
  - 포맷: 왕복 · 모르는 provider · 토큰 위반 id → 없음.
  - 힌트: 끝 1 MiB 안의 **마지막** 권한 모드·모델이 이긴다 · 잘린 첫 줄을 먹지 않는다 · 줄이 없으면 unknown.
  - 실행: 같은 `Parsed`에 대해 도크 재개와 부활이 **같은 argv**를 만든다 · 파일 없음 → 셸만·못 이어간 수 +1 ·
    증명 없는 복원은 provider 실행 0.
  - 변이: 원격 조건 제거 · 끝부분 대신 머리 읽기 · 증명 게이트 제거 — 각각 죽어야 한다.
- verification-matrix.md와 persistent-session-host 행의 「provider resume/fork는 canonical 경로에 없다」를 이
  PR에서 고친다.

## 손 테스트 (헤드리스로 못 하는 것)

실제 재부팅은 자동 게이트로 못 만든다. 재부팅 없이 같은 상황을 만드는 절차:

1. 앱에서 터미널 몇 개와 `claude` 하나를 띄우고 앱을 종료한다(keep-alive라 host는 산다).
2. host를 내린다 — **launch PID로만**(이름 매칭 `pkill` 금지 — 사용자 앱까지 죽는다).
3. `workspace.v1`의 `boot-session` 값을 다른 UUID로 바꾼다.
4. 앱을 실행한다 → 모든 터미널이 cwd에서 새 셸로 뜨고, claude Term은 그 대화로 이어지고, 알림이 한 번 뜬다.

마지막으로 **사용자가 실제로 맥을 껐다 켜서** 같은 결과를 확인한다.
