# 에이전트 세션 기록 도크 (Codex·Claude)

우측 도크의 `agent_sessions` 뷰가 보이는 **로컬 과거 세션 기록**의 단일 출처다. 진행·검증 상태는 [검증 매트릭스](verification-matrix.md)의 "에이전트 세션 기록 도크" 행, 구현 순서는 [에이전트 세션 기록 도크 구현 계획](plans/agent-session-dock.md)의 AS1~AS4가 소유한다.

## 계약 문서 구성

에이전트 세션 도크 계약은 아래 문서가 나눠 소유한다. **절 번호는 파일을 넘어 이어진다** — 다른 문서와
코드 주석이 `agent-session-list.md §2.1.3`처럼 절 번호로 가리키므로 재번호하지 않는다.

| 절 | 문서 | 소유 |
|---|---|---|
| §1~§2 · §2.3 · §3~§5 · §7~§8 | 이 문서 | 목표와 경계, 화면과 상호작용, 카드가 싣는 값, provider 입력과 신뢰 등급, 스캔·성능·수명, 보안·개인정보·관측, 설계 검토 기록 |
| §2.1~§2.1.3 | [카드 레이아웃](agent-session-list-layout.md) | Metal GPU 카드 레이아웃·시각 계약·측정형 Button·spacing 토큰 |
| §2.2 | [선택·확장·geometry](agent-session-list-interaction.md) | 카드 선택·확장과 그 geometry |
| §2.1.4 · §6 | [구현 계획](plans/agent-session-list.md) | B1-button 이관 순서, AS3·AS4 슬라이스와 완료 조건 |

## 1. 목표와 경계

목표는 첨부된 레퍼런스처럼 제목·요약·provider·메시지 수·갱신 시각을 가진, 검색 가능한 최근 세션 목록이다. v1 provider는 **Codex와 Claude Code만**이다. 둘 다 사용자가 이미 자신의 Mac에서 만든 JSONL 이력을 읽을 뿐, provider API·계정·네트워크를 사용하지 않는다. **열려 있는지, Maru가 만든 것인지와 무관하게** 검증된 사용자 세션은 모두 같은 목록 후보이며, 기본 범위는 `전체`다.

이 목록은 다음과 엄격히 다르다.

| 구분 | 권위 | 용도 |
| --- | --- | --- |
| live agent | 열린 `Term`과 child PID의 환경 변수 | 현재 pane의 상태·마지막 교환·사이드바 표시; archive 행의 optional `열린 세션으로 이동` 표식 |
| `SessionArchive` | provider가 쓴 닫힌/과거 JSONL의 불변 스냅샷 | 도크 이력 검색·선택·명시적 재개 |

따라서 `agent_transcript.zig`의 256 KiB tail cache나 사이드바의 현재 Term 매핑을 archive index로 재사용하지 않는다. 그것들은 빠른 현재 상태용이며, 역사 목록의 완전성·중복 제거·보안 경계가 아니다. 파일 내용 편집, 원문 대화 뷰어, 다른 provider, 자동 재개, provider hook 설치와 원격/SSH 이력은 v1 범위 밖이다.

아래 계약은 Maru의 `SessionArchive`에 독립적으로 적용한다. 외부 레퍼런스 정책은 [references.md](references.md)를 따른다.

## 2. 화면과 상호작용

```text
Agent 세션 기록                              로컬   [새로 고침]
N개 표시                                      [최신순 ⇄ 오래된순]
[현재 작업공간] [현재 프로젝트] [전체]
[⌕ 세션 검색]
────────────────────────────────────────────────────────────────
⌄ project-or-workspace                                      12
  제목                                                     Codex
  마지막 사용자 요청의 안전한 짧은 요약
  메시지 140개 · 22시간 전 · gpt-…
  ────────────────────────────────────────────────────────────
  제목                                                   Claude
  마지막 사용자 요청의 안전한 짧은 요약
  메시지 94개 · 3분 전 · claude-… · 서브에이전트 4
```

### 2.3 카드가 싣는 값과 정렬

카드의 `메시지 N개`는 전체 transcript를 세어 얻는다. 목록 스캔이 파일 전체를 읽으므로(§4) 정확하며,
이 값을 근사치로 낮추는 대가로 읽기를 줄이지 않는다 — 요약이 **마지막** 메시지에서 나오기 때문에
앞뒤 일부만 읽는 방식은 목록의 30%가 틀린 요약을 보이게 한다(실측 2026-08-08).

`서브에이전트 N`은 Claude 세션 파일과 같은 이름의 디렉터리 아래 `subagents/`의 transcript 개수다.
**파일을 열지 않고 디렉터리 항목만 센다** — read budget과 무관하다. 실측(2026-08-08): Claude 세션
96개에 대한 `subagents/` 순회가 **1.4 ms**로, 후보 수집 전체(2.4 ms)와 같은 크기다.
0이면 그리지 않는다. 값은 스캔 시점 기준이므로 다음 refresh까지 갱신되지 않는다. Codex는 worker가 별도
파일이 아니라 같은 rollout 트리에 섞여 있어 부모 세션과 연결할 규칙이 없으므로 이 표시의 대상이 아니다.

정렬은 **최신순**이 기본이고 토글로 **오래된순**을 고른다. 토글은 header의 `로컬` provenance label과
refresh 사이에 두어 새 행을 만들지 않는다 — 목록 높이를 뺏지 않으면서 정렬이 화면 상태의 일부임을 보인다.

정렬 키는 **transcript의 마지막 활동 시각**이고, 그 값을 얻지 못하면 파일 mtime으로 폴백한다. 두 provider
모두 각 줄 최상위에 RFC 3339 UTC `timestamp`를 싣는다. 실측(2026-08-08, 로컬 이력 362개):

| | timestamp 보유 | mtime과의 차이(중앙값) | 최대 차이 |
|---|---|---|---|
| Claude | 39/40 | 17.2초 | **144시간** |
| Codex | 40/40 | 0.0초 | 0초 |

**mtime으로 정렬하면 362개 중 257개(70%)가 제자리가 아니다.** mtime은 대화 외의 이유(복사·도구의 메타
갱신·백업 복원)로도 밀리므로 내부 시각이 있으면 그쪽이 정확하다. 40개 중 1개는 `timestamp`가 없어
폴백이 필요하다 — 폴백은 선택이 아니라 실측된 요구다.

토글은 **표시 계층에서만** 방향을 바꾸고 스캔 순서는 항상 최신 우선이다(부분 publish가 최신부터
차오르는 것과 같은 근거). 방향은 앱 실행 중에만 유지하며 디스크에 쓰지 않는다.

## 3. provider 입력과 신뢰 등급

| provider | discovery root | 사용자 세션 확정 | title/summary 신호 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/*/*.jsonl`의 **직속** 파일만 | 직속 JSONL만; 하위 `subagents` 계층은 절대 재귀하지 않음 | `custom-title`, `ai-title`, first/last user message 순 |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `session_meta`의 worker 판정(§3.1)이 사용자 세션일 것 | `session_index.jsonl` title(검증 가능한 경우), 없으면 user event |

### 3.1 Codex worker 판정

`thread_source`는 최근 Codex가 추가한 필드다. 판정은 신호 순서로 한다.

| 신호 | 판정 |
| --- | --- |
| `thread_source`(또는 `threadSource`)가 있음 | `"user"`면 사용자 세션, 그 외 값은 worker |
| 없고 `payload.source.subagent`가 객체 | worker |
| 둘 다 없음 | **사용자 세션**(목록에 포함) |

기본을 "제외"가 아니라 **"포함"** 으로 둔다. 목록에서 조용히 사라진 세션은 사용자가 알아챌 방법이 없지만,
worker가 섞이면 보고 무시할 수 있다. 실측(2026-08-08, 개발자 머신): `thread_source`가 없는 구버전 Codex
파일 67개가 전부 실제 사용자 대화였고 모두 `payload.id`를 갖고 있어 식별에도 문제가 없었다. 이 67개는
제외 규칙 때문에 목록에서 통째로 빠져 있었다.

**한 파일에 `session_meta`가 여러 번 나온다.** 실측상 Codex 파일 256개 중 123개가 그렇고, 그중 118개는
첫 메타가 `subagent`이지만 마지막 메타가 `user`인 정상 세션이다. 따라서 **판정은 파일 안에서 마지막으로
관측한 `session_meta`를 따른다.** 첫 메타로 확정하면 그 118개가 사라진다.

읽기를 조기에 끊어 비용을 아끼는 경우에도 같은 규율을 지킨다 — worker 확정은 **앞 512 KiB를 다 읽고도
`user` 신호를 한 번도 보지 못했을 때만** 한다(실측 `user` 메타 최대 위치 18.6 KiB의 27배 여유). 판정에
필요한 메타를 못 본 파일은 제외하지 않고 끝까지 읽는다. 제외는 확신할 때만 한다.

Claude의 nested subagent transcript는 discovery 단계에서 재귀하지 않으므로 애초에 후보가 아니다(§3 표).
다만 그 존재는 부모 세션의 정보이므로 개수를 세어 카드에 보인다(§2.3).

각 record의 안정 identity는 provider의 session id와 source file `(device,inode)`다. 같은 provider/session id가 여러 source에 있으면 newest verified source 하나만 표시하고, id 또는 file identity가 충돌/변경되면 둘 다 불신하고 다음 refresh까지 publish하지 않는다. title index는 보조 정보이며 session transcript의 provider/id와 맞을 때만 적용한다.

## 4. 스캔·성능·수명

`SessionArchiveScanner`는 worker에서만 directory enumerate·open·stat·JSONL parse를 하고, main actor에는 immutable `SessionArchiveSnapshot`만 건넨다. **보여 줄 목록이 있으면 새 완료본 하나로만 교체**하며, 첫 진입처럼 보여 줄 목록이 없을 때만 부분 snapshot을 점진 publish한다(§4.1). main actor는 마지막 snapshot을 메모리에 보존해 재진입 즉시 렌더하며, file I/O·JSON parse·정렬·worker wait를 하지 않는다. 대기 중 refresh는 하나로 coalesce하며 old worker completion은 request generation이 맞을 때만 publish한다. dock을 닫거나 앱을 종료하면 cancel을 요청하고, 이미 열린 fd와 staged allocation은 worker가 회수한다.

`SessionDock`의 비례 system-UI text는 이와 **다른** 규율을 따른다. provider JSONL은 worker의 일이지만
텍스트 셰이핑은 아니다. render tick은 rich-text artifact cache가 miss하면 **그 자리에서 CoreText로 셰이핑해
이번 frame에 그린다**. host는 `{ fingerprint, scale, text role, origin, max-width, foreground, UTF-8 bytes }`를
deep-copy한 불변 request 하나를 만들어 같은 tick 안에서 소비하며, 결과를 fingerprint와 함께 cache한다. 즉
cache는 CoreText 호출을 건너뛰기 위한 **순수 최적화**이지, 텍스트 없는 frame을 정당화하는 장치가 아니다.
다른 geometry/content의 이전 artifact를 새 frame에 재사용하지 않는 것은 그대로다.

이 결정에는 근거가 있다. 도크의 **모든** 텍스트와 등록 SVG 아이콘이 이 artifact 하나에 실리므로
(`shapesTextOp`가 `wide_icons`가 아닌 op 전부를 담는다), 셰이핑을 다음 tick으로 미루면 그 frame의 도크는
카드 배경만 남은 빈 상자가 된다. 게다가 detached worker 시절에는 in-flight가 하나로 coalesce돼 있어, 스크롤처럼
매 frame 내용이 바뀌는 동안에는 도착한 결과가 계속 fingerprint 불일치로 폐기되어 한 frame 깜빡임이 아니라
**스크롤하는 내내** 빈 상태가 유지됐다. 비동기의 근거였던 "render tick에서 `CTLine`을 만들지 않는다"는 이
코드베이스에서 성립하지 않는다 — 같은 tick의 터미널 본문 셰이핑이 이미 **셀마다** `CTLine`을 하나씩 만든다.
사이드바·탭바도 `CoreTextFrameBuilder.shapeOnly`로 같은 tick에 CoreText를 부른다.

동기 셰이핑이 frame 예산 안에 있으려면 브리지가 **face를 run마다 다시 만들지 않아야 한다**. chrome 텍스트의
role은 아홉 종뿐이고 그 (point size, weight) 조합은 frame마다 반복되므로, native bridge가 그 face와 PostScript
이름을 잡아 두고 재사용한다(터미널 draw list가 style별 face를 재사용하는 것과 같은 규율). 이 재사용이 없으면
같은 frame이 3배 이상 비싸진다. 그 비용 구조는 [성능 예산](performance-budget.md)의 도크 절이 소유한다.
이 face cache는 lock이 없으므로 chrome 텍스트 셰이핑은 **main actor 전용**이다.

**단, 스크롤은 이 무효화의 대상이 아니다.** CoreText 셰이핑 결과(글리프 id·advance·선택된 face)는 위치의
함수가 아니므로, 목록이 통째로 위아래로 움직인 프레임은 **같은 artifact를 그대로 재사용해야 한다**. 이것은 위
문단이 금지하는 "다른 geometry의 artifact 재사용"이 아니라, 같은 artifact를 올바른 위치에 놓는 일이다.
그래서 fingerprint는 스크롤 목록에 속한 op의 y를 **스크롤 기준 상대값**으로 섞어 평행이동에 불변인 키를 만들고,
host는 셰이핑 당시의 스크롤 원점을 cache와 함께 보관해 재사용할 때 그 차이만큼 스크롤 소속 glyph만 옮긴다.
고정 chrome(header·scope·search)은 스크롤해도 제자리이므로 절대 y를 유지한다 — 전체가 같은 delta로 움직이지
않으므로 단일 평행이동으로는 보정할 수 없다. 스크롤 뷰포트 사각형이나 스크롤 오프셋 자체를 semantic op에
실어서는 안 된다. 그러면 스크롤 1px마다 op이 달라져 cache가 통째로 무효화되고, cache가 빗나간 프레임은 measured
텍스트를 하나도 그리지 않으므로(§아래 all-or-cell-fallback) 스크롤이 끝날 때까지 글자가 사라진다. op이 싣는 것은
**"이 op이 스크롤 영역에 속한다"는 소속 표시뿐**이며, 그 사실은 스크롤해도 바뀌지 않는다.

가상화로 카드가 실제로 교체되면 텍스트 바이트가 달라져 fingerprint가 정상적으로 바뀐다. 그 경우에만 새 셰이핑을
기다리며, 이전 카드의 artifact를 새 카드 자리에 재사용하지 않는다.

이 text worker는 CoreText의 scalar 결과와 postscript font name을 **소유한 DTO**로만 반환한다. CoreText는 macOS
SDK의 `CoreText.h` thread-safety 계약에 따라 worker에서 호출할 수 있지만, `FontIdentityRegistry`, atlas,
`RenderFrame`, Metal/AppKit handle은 worker가 import하거나 소유하지 않는다. main actor는 완료 DTO를 poll한 뒤에만
현재 registry에 font identity를 intern하고 renderer-neutral `ShapedGlyphRecord`·placement cache로 변환한다. 이
변환은 파일 I/O·native text shaping·wait 없이 bounded DTO를 순회하는 작업이다. 종료 시 host는 새 request를 막고
worker completion을 폐기하며 worker가 자신의 request/result allocation을 회수한다. 따라서 stale completion, app
teardown, 연속 resize에서도 main actor가 native shaping이나 join으로 멈추지 않는다.

AS2는 한 PR에 병렬 parser까지 억지로 섞지 않는다. **AS2-a**는 backend-owned monotonic request generation, dock 이탈/종료 cancel, candidate/file 경계의 cooperative cancel, cancelled generation의 publish 폐기와 재진입 latest-wins 재요청을 닫는다. **AS2-b**가 그 동일 cancellation token과 총 byte reservation을 소비하는 최대 4개 parse worker pool 및 actual peak-concurrency metric/fixture gate를 추가한다. 따라서 AS2-a가 끝나기 전에는 현재 단일 scanner thread를 “동시 parse≤4 구현”이라고 주장하지 않는다.

1. trusted discovery root에서 no-follow directory traversal로 regular file만 수집한다. symlink, socket, FIFO, device, nested Claude directory, 예상 밖 파일명은 skip하며 debug artifact에는 raw 제목/프롬프트/경로를 남기지 않는다.
2. 후보 metadata는 디렉터리 순회와 `stat`만으로 모으므로 개수 상한을 두지 않는다. 실측(2026-08-08) 351개
   후보 수집이 **2.4 ms**다 — 여기에 상한을 두면 목록의 완전성만 잃고 아끼는 비용이 없다.
3. worker는 후보를 최근 순으로 분석한다. 파일은 **streaming JSONL parser**로 읽는다: 고정 크기 버퍼로
   순차 읽고 줄 단위로 소비하며, 청크 경계에 걸친 줄만 이어 붙인다. **파일 전체를 메모리에 올리지
   않는다** — 그래야 파일 크기와 무관하게 메모리가 일정하고, 아래 4의 상한들이 필요 없어진다.
   손상 JSON line은 그 line만 버리고 record를 추측해 만들지 않는다. 한 줄이 16 MiB를 넘으면 그 줄을
   버리고 `partial`에 기록한다(손상 파일이 줄 버퍼를 무한히 키우는 것만 막는 방어이며, 정상 파일은
   전부 통과한다 — 실측 최장 줄 6.85 MB).
4. **read budget을 두지 않는다.** 예전에는 파일당 128 MiB·refresh당 512 MiB 상한이 있었는데, 그 둘은
   "파일 전체를 메모리에 올린다"를 방어하려고 존재했다. streaming으로 그 전제가 사라지면 상한도 함께
   사라진다. 남는 상한은 한 refresh가 무한히 돌지 않게 하는 **시간 상한 하나**이며, 그 상한에 걸려
   끊긴 refresh는 `partial`로 표시한다.

   read budget이 목록을 자르면 **캐시 상태가 결과를 바꾼다.** 캐시 히트는 budget을 쓰지 않으므로, 같은
   데이터·같은 코드인데 몇 번째 refresh냐에 따라 보이는 세션 수가 달라진다. 실측(2026-08-08)에서 첫
   refresh 69개가 12번 반복 뒤 272개가 됐고 그래도 완성되지 않았다. **캐시는 순수 최적화여야 하며
   관측 가능한 결과를 바꿔서는 안 된다.** budget 제거가 그 조건을 회복시킨다.
5. first guard는 앱 실행 중의 완료 snapshot TTL 15초다. TTL hit는 filesystem I/O 없이 현재 snapshot만
   보이고, force refresh만 이를 우회한다. worker는 다음 guard로 `(device,inode,mtime,size)`가 같은 파일의
   verified parse 결과를 재사용한다. cache miss/identity 변경 파일만 다시 분석하며, cache 결과와 새 parse
   결과를 정렬해 합친 snapshot을 publish한다. `(device,inode)`는 캐시를 위해서가 아니라 **스캔 시점과
   열기 시점 사이의 파일 교체를 막기 위한 identity**이며(§5), 캐시 키는 그것을 재사용한다.
   캐시 항목은 프로세스 수명 동안 유지되며 삭제된 세션의 항목도 남는다 — 레코드당 약 250 B라
   실사용 규모(수백 개)에서 수십 KB이고 앱을 다시 켜면 사라진다. 상한에 닿으면 축출하지 않고 새
   항목을 버리는데, 상한이 후보 수보다 훨씬 크므로 실제로 도달하지 않는다.
   memory-only snapshot과 parse cache이므로 앱 종료 후 title/prompt metadata와 source path를 디스크에
   남기지 않는다. persistent cache는 개인정보 보존·삭제 정책을 별도로 승인하기 전 비목표다.

### 4.1 첫 진입의 점진 publish

read budget을 없애면 첫 진입이 사용자 이력 전체를 한 번에 분석한다. 구현 후 실측(2026-08-08, 제품
backend, 351개/8.1 GB, `ReleaseSafe`·제품 allocator):

```
라운드 1   337개  partial=false   24.0 초   ← 첫 진입
라운드 2   337개  partial=false    1.4 초   ← 캐시 워밍
라운드 3+  337개  partial=false   0.03 초   ← 전부 캐시 히트
```

**개수가 라운드마다 같다.** budget이 있던 때는 69 → 77 → 96 → … 로 늘며 12라운드에도 완성되지 않았다
(캐시 히트가 budget을 아껴 주므로 결과가 캐시 상태에 좌우됐다). 비용의 97.5%는 JSON parse이며 I/O는
1.2초다.

그래서 **보여 줄 목록이 하나도 없을 때만** 완료를 기다리지 않고 부분 snapshot을 주기적으로 publish한다.

- **보여 줄 목록이 있으면**: 지금과 같다. 완료본 하나로 원자 교체하고 scroll/selection anchor를
  보존한다. refresh가 목록을 흔들지 않는다는 계약은 그대로다.
- **없으면**(첫 진입): 정렬 순서대로 분석하며 부분 snapshot을 발행해 목록이 위에서부터 찬다.
  구현 후 실측: 첫 발행 **1.3초**, 20개 **4.1초**, 전체 24.0초(총 61회 발행). 첫 카드가 즉시 뜨지 않는
  것은 이 머신의 최신 파일이 **439 MB**여서다 — budget이 있던 때는 그 파일을 아예 건너뛰어 작은 것만
  빨리 쌓였다(그 대신 목록이 잘렸다). 잘린 목록을 빨리 보여 주는 것보다 완전한 목록을 정직하게
  채우는 쪽을 택한다.
- 진행 요청 여부는 **"지금 보여 줄 목록이 있는가"**로 판정한다. 점진 publish의 목적이 빈 화면을 피하는
  것이기 때문이다. 부분 snapshot도 목록을 통째로 교체하므로, 목록이 이미 있는데 점진 경로를 타면 첫
  발행이 그 목록을 **더 짧은 목록으로 덮어** 줄었다가 다시 차오르는 것처럼 보인다. 부분만 받고 취소된
  뒤 재진입하는 경우가 정확히 그 상황이며, 이럴 때는 완성본 하나로 교체하는 편이 조용하다.
- 부분 snapshot은 **완료로 취급하지 않는다.** TTL 갱신에 쓰지 않으며(쓰면 재스캔이 막혀 목록이
  불완전한 채 고정된다) spinner도 끄지 않는다. "완주했는가"는 완료 snapshot에서만 세우는 별개의 신호다.
- 미수령 부분 snapshot은 **쌓지 않고 최신 것으로 대체한다.** 부분 진행은 최신 하나만 의미가 있고,
  쌓이면 main actor가 낡은 목록마다 filter/projection/anchor 복원을 다시 한다. 캐시가 따뜻한 채 첫
  진입하는 경로(도크를 열자마자 닫고 다시 열면 그렇게 된다)에서는 발행 조건이 수 ms 안에 수십 번
  걸리므로 가정이 아니라 실제로 도달한다.
- 발행 간격은 초반을 촘촘히 하고 이후 넓힌다. main actor가 발행마다 filter/projection/anchor 복원을
  다시 하므로 너무 잦으면 그 자체가 비용이다.

**budget이 없어도 UI는 여전히 불완전을 말해야 한다.** 시간 상한, 16 MiB 초과 줄, 읽기·parse 실패는
`partial`로 남고, UI는 `228개 표시 · 분석 중`처럼 현재 snapshot과 scan 상태를 분리해 말한다.
search/scope가 부분 snapshot을 완전한 결과처럼 보이게 해서는 안 된다. 이미 완료 snapshot이 있으면 같은
문구를 overlay로만 보이고 카드 목록은 유지한다. **정책적 제외(worker)는 이 경고에 포함하지 않는다** —
정상 동작이 상시 경고로 보이면 경고가 무의미해진다.

## 5. 보안·개인정보·관측

- provider log는 민감한 개인 데이터다. 원문·prompt·token·절대 home path를 trace, crash artifact, fixture, analytics, config에 쓰지 않는다. fixture는 synthetic·redacted JSONL만 허용하며 [project-rules.md](project-rules.md)의 redaction 기준을 공유한다.
- scanner는 no-follow로 열고 fstat identity를 discovery snapshot과 다시 대조한다. parse 중 교체되거나 permission이 바뀐 파일은 stale로 버린다. published record는 앱 실행 중에만 absolute source path와 `(device,inode)`를 함께 보존하며, `로그 보기`는 사용자가 누른 때에만 그 identity를 다시 검사해 OS file reveal API에 넘긴다. 교체·삭제·비정규 파일이면 reveal을 거부한다.
- resume은 **사용자 로그인 셸을 거쳐** provider를 실행한다. `/usr/bin/env <provider>`를 직접 exec하면
  provider를 **부모 프로세스의 PATH에서만** 찾으므로, Dock/Finder에서 띄운 앱은 실패한다 — GUI 앱이
  물려받는 PATH에는 `~/.local/bin`이나 버전 매니저 shim이 없다(실측 2026-08-08: `launchctl getenv PATH`
  미설정, `env -i … zsh -lc 'command -v claude'` 실패, `-lic`는 성공). 터미널에서 띄웠을 때만 우연히
  동작하던 것이라 재현이 갈렸다.
  - 셸을 `-l -i -c "exec <provider> --resume <id>"` 형태로 부른다. `-i`가 필요한 이유는 PATH를
    `.zshrc`에 두는 환경이 흔하고 zsh는 `-l`만으로는 그 파일을 읽지 않기 때문이다. 일반 새 탭은 이미
    대화형 로그인 셸이므로 이 경로가 오히려 나머지 탭과 동작을 일치시킨다.
  - **셸 종류로 분기하지 않는다.** 분기해 직접 exec으로 폴백해 봐야 그건 이 계약이 고치는 바로 그
    실패(GUI 실행에서 PATH를 못 찾음)로 되돌아가는 것이고, 경로가 둘이 되어 유지보수만 는다. 셸이
    이 인자를 못 받으면 그 셸이 에러를 내고 PTY 화면에 뜨므로 실패가 조용하지 않다.
  - ZDOTDIR은 새 탭과 **같은 지점**(`shellIntegrationZdotdir`)에서 얻는다. 그 함수는 캐시의 `.zshenv`가
    사라졌으면 다시 써 주는 자가 복구를 한다 — 보관 필드를 직접 읽으면 캐시가 비워진 뒤 재개 탭만 셸
    통합이 통째로 빠진다.
  - **이 형태의 Term은 OSC 7을 한 번도 보내지 않는다.** `-c`는 프롬프트를 그리지 않으므로 통합의
    `_maru_osc7` precmd 훅이 돌지 않는다(`.zshrc`는 source되고 훅 등록도 되지만 precmd는 안 돈다 — 실측
    2026-08-12). 그래서 이 Term의 폴더·브랜치·저장소는 전부 **커널 cwd 폴백**에 의존한다
    ([editor-surface-dock.md §3.5](editor-surface-dock.md)). 사이드바가 그 폴백 밖에 있던 2026-08-12 전까지
    재개 탭에서만 카드·행의 폴더줄과 브랜치줄이 사라졌다.
  - 명령 문자열에 들어가는 각 인자는 예외 없이 single-quote escape한다. **cwd는 명령 문자열에 넣지
    않고 spawn request의 작업 디렉터리로만 전달한다.** parse한 prompt는 실행 인자로 절대 넣지 않는다.
  - session id/provider는 UI text나 log에서 명령으로 재해석되지 않는다.
- metrics는 candidate/verified/partial/rejected 개수와 scan duration/bytes만 남긴다. title·요약·cwd·session id는 observability event의 payload가 될 수 없다.

## 7. 설계 검토 기록 — 적대적 5회

| 회차 | 공격 관점 | 발견한 결함 | 반영한 방어 |
| --- | --- | --- | --- |
| A1 | live 목록을 archive로 오인 | 열린 Term cache만 쓰면 앱 밖/과거 세션과 screenshot UX를 만들 수 없음 | §1의 두 authority와 별도 scanner/snapshot |
| A2 | Codex worker 오염 | 같은 날짜 계층에 subagent가 섞이고 legacy record는 판별 불가 | §3 verified-user만 표시, legacy unknown 기본 제외 |
| A3 | 성능·UI freeze | 500개의 큰 JSONL을 main tick에서 전량 parse하면 입력/렌더가 멎음 | §4 worker, streaming, 4,096/128MiB/512MiB cap, partial truthfulness |
| A4 | 클릭이 명령 실행 | 행 선택/유사 mtime mapping이 잘못된 session에 입력·resume할 수 있음 | §2 row click은 detail만, 명시 ▶/resume만 new Term/exact provider+id/argv-only |
| A5 | 개인정보·TOCTOU | 기록 제목·prompt가 trace에 새고 symlink 교체 파일을 읽을 수 있음 | §5 redaction/no-follow/fstat recheck/metadata-only metrics |

## 8. 설계 누락 탐색 — 5회

| 회차 | 점검한 빈칸 | 결정 |
| --- | --- | --- |
| M1 | workspace/project의 의미 | active workspace의 active local Term canonical CWD와 그 git root로 각각 고정; 없으면 비활성화 (§2). 그 CWD는 소스 컨트롤·탐색기·사이드바와 **같은 지점**(`git_ops.termCwd` — OSC 7 → 커널 조회 2단, [editor-surface-dock.md §3.5](editor-surface-dock.md))에서 온다. 2026-08-12 전에는 이 자리만 관측을 직독해, OSC 7이 없는 Term(셸 통합 없는 셸·재개 Term)에서 두 칩이 **눌리지 않았다** — `enabled`는 paint가 아니라 hit-test만 바꾸므로 겉모습에 단서가 없었다 |
| M2 | 정확하지 않은 count/검색 | partial 상태·`≥n` 표기와 snapshot-only search를 명시 (§2, §4) |
| M3 | resume cwd·실행 경계 | 삭제 cwd fallback, shell 미사용, 명시 ▶/resume 버튼의 즉시 새 탭 실행을 명시 (§2, §5) |
| M4 | 중복·변경·손상 log | provider/id+file identity, conflict discard, line-level corruption 정책을 명시 (§3, §4) |
| M5 | 키보드·취소·영속 | dedicated focus, generation cancel, memory-only metadata와 nonpersistent query를 명시 (§2, §4) |

이 10회 검토 뒤에도 **정책적으로 남긴 비목표**는 원문 대화 뷰어, legacy-unknown opt-in, remote history, 다른 provider, persistent archive cache다. 이들은 데이터 보존·개인정보·성능 범위를 바꾸므로 별도 사용자 결정 없이 AS1~AS4에 넣지 않는다.
