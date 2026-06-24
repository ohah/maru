# app 레이어 분해 (3차 추출) — 실행 플랜

> 위상 골격의 단일 출처는 [레이어링과 이식성](layering-and-portability.md) §3.2이고, 이 문서는 그 **실행 플랜과 착수 전 선결 결정**을 담는다. S2(§3.1 + `session_model.zig`)와 같은 doc-first → 스택 PR 방식으로 진행한다.

## 1. 배경

S2로 세션 모델(`Term`/`Pane`/`Tab`)은 `src/session/session_model.zig`로 갔지만, 그 모델이 의존하는 **중립 모델이 아직 `src/app`에 남아** `session→app` 의존이 잔류한다(`session_model`이 `app/surface.zig`·`split_tree.zig`·`workspace.zig`를 참조). `src/app`은 **중립 모델 + OS-중립 런타임**이 섞인 혼합 레이어다(코드 분류는 §3.2 표):

- 중립 모델(`pty` 미참조): `surface`·`split_tree`·`workspace`·`window`·`core_command`·`label`·`agent_resume`·`artifact_io`
- OS-중립 런타임(`pty` 참조): `live_pty`·`runtime`·`runtime_pump`·`frame_loop`·`host`·`pty_reader`·`live_pty_registry`

**목표:** 중립 모델을 session으로 모아 `session→app` 의존을 **0**으로. 그러면 session(L2)은 terminal·renderer 계약만 의존하고, 이식 시 모델 전부가 OS-중립으로 재사용된다.

**위상은 깨지지 않는다(§3.2 재확인):** 남는 런타임(L4적)이 모델(L2: `surface`)을 참조하는 건 **L4→L2 정상 방향**이다. 본질적 트레이드오프는 거의 없고, 비용은 작업량 + 단위(묶어서 해야 의미)뿐이다.

## 2. 선결 결정 (착수 전 사용자 합의 필요)

**문제:** 중립 모델이 빠지면 `src/app`엔 **OS-중립 런타임만** 남는다. 이게 layering 4층(L1~L4) 어디인가? — 이 정체성을 못박는 게 3차의 선결이다.

**현황(코드로 확인):** `pty/macos.zig`(OS별 PTY syscall)는 이미 OS-종속이고, `app/live_pty.zig`(그 위 OS-중립 래퍼·이벤트 펌프)는 `pty.zig`→`pty/macos.zig`를 호출하는 **OS-비종속 래퍼**다. 즉 런타임이 이미 **"OS 어댑터(`pty/`) + OS-중립 래퍼(`src/app`)" 2단**으로 갈려 있다.

**옵션:**

| 옵션 | `src/app` 정체성 | 장점 | 단점 |
|---|---|---|---|
| **A (추천)** | L4의 **OS-중립 런타임 절반** — L4 = `src/app`(공통 런타임) + `platform/macos`·`pty/macos`(OS 어댑터) | 기존 구조와 정합(`pty/` OS별·`src/app` 래퍼가 이미 그러함). `architecture.md:37` "app layer SurfaceRuntime"과 일치. **개명 0** | "L4는 공통 런타임 + OS 어댑터 2단"임을 layering §2에 한 줄 명문화 필요 |
| B | 새 층 **L2.5 runtime**(session과 platform 사이) | 런타임이 독립 층으로 또렷 | 4층→5층, 기존 문서·`check-boundaries` 대폭 갱신. 과설계 위험 |
| C | `src/runtime/`로 개명 | 이름이 역할을 드러냄 | 전역 rename(import 경로 다수), 이득 작음 |

**결정 (사용자 합의 2026-06): 3차는 A, 그 위에 C를 별도 4차로 등록한다.**

- **3차 = A**: `src/app`을 "L4 공통 런타임"으로 규정(개명 0). 3차의 목적인 `session→app` 의존 0은 A로 100% 달성된다(session이 app을 import 안 하면 됨 — `src/app`의 층 정체성과 무관).
- **4차 = C (장기, 별도)**: 장기적으로는 런타임을 `src/runtime/`로 **독립**시키는 게 layering의 "재사용/재작성 단위" 원칙에 더 정합하다 — `src/app` 런타임(본문은 OS-중립, syscall은 `pty/*`·`platform/*`로 위임 = **재사용** 쪽)과 `platform/macos`(OS 어댑터 = **재작성**)는 재사용 특성이 정반대라, 같은 L4로 묶으면 "L4=재작성"이라는 잣대가 흐려진다. C(런타임 독립 + 개명)가 그 정보를 또렷하게 한다. 단 **3차의 의존-0 목표엔 불필요**하므로 A로 3차를 끝낸 뒤 별도 4차로 진행한다 — A는 C로 가는 길을 막지 않는다(나중에 `src/app`→`src/runtime/` 개명 + 층 명문화만). (B는 개념만 나누고 물리는 안 옮겨 또 헷갈리므로, 갈 거면 C까지.)

## 3. 단계 (의존 순서, 각 green + 헤드리스 — A 옵션 기준)

| 단계 | 옮길 것 / 할 것 | 비고 | 위험 |
|---|---|---|---|
| **D0** | 선결 결정(§2)을 layering §2 4층 표·§3.2에 명문화. 코드 0 | doc-first(S2-1과 같은 결) | 없음 |
| **D1** | 순수 모델 `split_tree`·`workspace`·`label`·`agent_resume`·`artifact_io`(import 0)를 `src/session/`로 | 파일 이동 + barrel/참조 경로. `session_model`이 이미 `split_tree`/`workspace` 참조 → 경로만 변경 | 낮음 |
| **D2** | `surface`·`window`·`core_command`(`terminal`만 참조)를 `src/session/`로 | 런타임 참조처(`live_pty`·`runtime`·`runtime_pump`·`frame_loop`·`host` 등 10+)의 import 경로 갱신. 동작 보존 | 중 |
| **D3** | `check-boundaries`에 **`session`의 `app` 금지** 추가 + `session→app` 잔여 0 확인 | 의존 소거를 가드로 고정 | 낮음 |

각 단계 독립 PR(스택), `zig build test`·`check-boundaries`·`macos-app-build` + 머지 전 실기(`zig build macos-app`). 순수 이동이라 기존 테스트가 그대로 그물.

## 4. 검증

- **`check-boundaries`**: D3에서 `session`의 forbidden 목록에 `app`을 추가해 `session→app`을 빌드 시 0으로 강제(현재 forbidden = `pty`·`platform`·`chrome`).
- **헤드리스**: 이동만이라 기존 `session_model` 테스트(fake `Rt`)가 그대로. `surface` 이동 후, session 테스트가 surface까지 PTY 없이 다룸을 확인(이식성 증거 확장).
- **실기**: 매 단계 `zig build macos-app`로 탭/split/포커스/닫기·workspace 복원.

## 5. 리스크 / 한계 (정직)

- **작업량**: D2의 import 경로 변경이 런타임 10+ 파일(기계적·저위험, 동작 보존).
- **본질적 단점 없음**: L4(런타임)→L2(모델) 참조는 정상 방향(§3.2). 순수 이동이라 동작 변화 0, `/code-review max`로 확인.
- **선결 미합의 시 중간 상태**: D1만 하면 `surface`가 남아 `session→app`이 잔존(절반 정리). §2 결정 후 D1~D3을 **묶어** 진행해야 의존이 0으로 닫힌다.
- **범위 밖**: `agent_transcript`(이미 session)와 `agent_session`(platform, 파일 I/O)의 경계는 유지 — 이번 대상 아님. 런타임(`live_pty` 등) 자체는 `src/app`에 잔류(L4 공통 런타임).
