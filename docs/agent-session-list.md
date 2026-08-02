# 에이전트 세션 기록 도크 (Codex·Claude)

우측 도크의 `agent_sessions` 뷰가 보이는 **로컬 과거 세션 기록**의 단일 출처다. 진행·검증 상태는 [검증 매트릭스](verification-matrix.md)의 "에이전트 세션 기록 도크" 행, 구현 순서는 [실제 구현 계획](implementation-plan.md)의 AS1~AS4가 소유한다.

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
Agent 세션 기록                           Local Mac   [새로 고침]
N개 표시 · 최근 500개
[현재 작업공간] [현재 프로젝트] [전체]
[⌕ 세션 검색]
────────────────────────────────────────────────────────────────
⌄ project-or-workspace                                      12
  제목                                                        ⌄  …
  마지막 사용자 요청의 안전한 짧은 요약
  Codex | 메시지 140개 | 22시간 전 | gpt-…
```

- header의 `Local Mac`은 현재 사용자 홈 아래 provider log만 읽는다는 provenance label이며 host 선택기가 아니다. v1 정렬은 mtime 내림차순 하나로 고정한다. 탭 재진입은 현재 앱 실행 중의 snapshot을 즉시 보이고, 마지막 완료 scan 뒤 **15초** 안이면 새 refresh를 시작하지 않는다. 목록 첫 행의 `AI 세션 · ⟳ 새로 고침`은 명시적인 refresh control이며 클릭은 이 TTL을 우회한다. worker가 실행 중이면 같은 control은 `분석 중`으로 바뀌고 추가 job을 만들지 않는다.
- 도크 view bar의 `AI 세션`을 누르면 archive refresh를 요청한다. 스캔 중에도 기존 snapshot을 유지하고, 새 결과는 batch로만 publish한다. 빈 snapshot은 skeleton/진행 문구를 보이며 frame tick에서 파일 I/O를 하지 않는다. 창 재포커스와 새 provider session identity 감지는 같은 refresh를 요청하되, forced refresh는 5초 전역 throttle로 합친다. filesystem polling/watcher는 v1에 없다.
- scope는 `현재 작업공간`, `현재 프로젝트`, `전체`다. 기본값은 `전체`이며 마지막 선택만 창 UI 상태로 보존한다. `현재 작업공간`은 탐색기의 canonical explicit/inferred root 집합 중 **현재 창의 표시 root** 아래에 `cwd`가 있는 기록이다. root가 없으면 비활성화하고 이유를 표시한다. `현재 프로젝트`는 활성 local Term의 canonical git root 아래 `cwd`가 있는 기록이며, local git root가 없으면 비활성화한다. `전체`는 모든 provider의 검증된 사용자 세션이다. remote/불명 `cwd`는 전체에서만 보인다.
- 이 필터는 접근 제어가 아닌 표시 범위다. 경로는 provider log의 `cwd`를 canonicalize할 수 있을 때만 containment 비교하며, 실패·삭제·비로컬 값은 workspace/project에 억지로 넣지 않는다.
- 검색은 이미 publish된 snapshot만 대상으로 한다. UTF-8 byte substring(ASCII만 case-insensitive)으로 제목·요약·cwd leaf·branch·model을 찾고, 입력은 256 byte로 자른다. 검색 키 입력은 재스캔·파일 stat·정렬을 일으키지 않는다. 한국어처럼 case가 없는 문자열은 정확 byte match로 검색된다.
- 최근 window는 provider를 합쳐 mtime 내림차순 최대 500 **검증 완료** 세션이다. 후보 탐색 상한 또는 parser byte budget 때문에 더 오래된 항목을 보장하지 않으므로 header와 empty state는 항상 `최근`이라고 말하고 `전체 이력`이라고 주장하지 않는다.
- 기본 그룹은 canonical `cwd`의 프로젝트/폴더 이름이다. cwd가 없거나 project 밖이면 `알 수 없는 위치` 한 그룹으로 낸다. 그룹 접힘은 현재 view 수명 안에서만 유지하며 JSONL이나 workspace에 저장하지 않는다.
- 행 제목은 provider 고유 제목이 있으면 그것, 없으면 첫 신뢰 가능한 사용자 요청의 single-line prefix(최대 120 display bytes), 끝내 없으면 `제목 없는 세션`이다. 요약은 마지막 사용자 요청 우선, 없으면 마지막 assistant text의 single-line prefix(최대 240 display bytes)다. raw escape/control byte·경로 외 홈 사용자명은 렌더 전에 제거/일반화하며 Markdown/ANSI를 해석하지 않는다.
- `메시지 n개`는 전체 파일을 budget 안에서 끝까지 분석한 경우만 정확한 수다. cap에 걸리면 `메시지 ≥n개`, 아직 분석하지 않았으면 메시지 수를 생략한다. 숫자를 추정치처럼 표시하지 않는다.
- 한 번 클릭/Enter는 행을 선택하고 detail을 펼칠 뿐 provider를 실행하지 않는다. 이 동작은 행을 대량 훑을 때 실수로 provider를 시작하지 않게 한다. detail은 provider, session id의 짧은 복사본, source 위치, cwd/branch/model, 시각, 메시지 수, 분석 상태와 최근 세 turn을 보인다. 행 hover의 ▶와 detail의 primary `새 탭에서 이어하기`, `…`의 같은 명령은 모두 같은 resume action이다.
- `새 탭에서 이어하기`는 사용자가 그 명시 버튼을 누르는 즉시 새 local Term 탭을 만들고 활성화한다(추가 확인 dialog 없음). shell 없이 정확한 argv로 실행한다: Claude는 `claude --resume <session-id>`, Codex는 `codex resume <session-id>`. 실행 cwd는 archive record의 canonical local cwd가 아직 directory일 때만 쓰며, 아니면 새 Term의 기본 cwd와 함께 "원래 cwd를 찾지 못함"을 보여 준다. 기존 Term에 키를 주입하지 않는다.
- open live Term과 provider+session id가 정확히 일치하면 detail에 **부가 동작**으로 `열린 세션으로 이동`을 제공한다. 이것은 archive 후보 선정·정렬·표시를 바꾸지 않으며, 일치하지 않는 과거 세션도 완전히 같은 행으로 보인다. mapping은 live session identity가 다시 검증된 경우만 만들며 path/mtime 유사성으로 추정하지 않는다.
- 새 focus owner `agent_session_list`가 선택 identity `{ provider, session_id, source_file_identity }`를 소유한다. Up/Down, PageUp/PageDown, Home/End는 보이는 행을 움직이고, Right/Left는 그룹/detail을 펼치고 접으며, Enter는 detail, Escape는 search focus를 먼저 해제한다. 도크를 떠나거나 snapshot 교체 뒤 identity가 사라지면 선택을 해제한다. `⌘⇧E`는 기존대로 탐색기로 돌아간다.

## 3. provider 입력과 신뢰 등급

| provider | discovery root | 사용자 세션 확정 | title/summary 신호 |
| --- | --- | --- | --- |
| Claude Code | `~/.claude/projects/*/*.jsonl`의 **직속** 파일만 | 직속 JSONL만; 하위 `subagents` 계층은 절대 재귀하지 않음 | `custom-title`, `ai-title`, first/last user message 순 |
| Codex | `~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl` | `session_meta.payload.thread_source == "user"`가 있어야 함 | `session_index.jsonl` title(검증 가능한 경우), 없으면 user event |

Codex의 과거 파일에는 `thread_source`가 없을 수 있다. 이 경우 user/subagent를 구별할 근거가 없으므로 v1 기본 목록에서 **제외**하고 `검증할 수 없는 이전 Codex 기록 n개`로만 알린다. 사용자가 토글 하나로 섞어 보게 하는 방식은 잘못된 worker 재개와 목록 오염을 정상화하므로 v1에 넣지 않는다. Claude의 nested subagent transcript도 같은 이유로 제외한다.

각 record의 안정 identity는 provider의 session id와 source file `(device,inode)`다. 같은 provider/session id가 여러 source에 있으면 newest verified source 하나만 표시하고, id 또는 file identity가 충돌/변경되면 둘 다 불신하고 다음 refresh까지 publish하지 않는다. title index는 보조 정보이며 session transcript의 provider/id와 맞을 때만 적용한다.

## 4. 스캔·성능·수명

`SessionArchiveScanner`는 worker에서만 directory enumerate·open·stat·JSONL parse를 하고, main actor에는 immutable `SessionArchiveSnapshot` batch만 건넨다. main actor는 마지막 snapshot을 메모리에 보존해 재진입 즉시 렌더하며, file I/O·JSON parse·정렬·worker wait를 하지 않는다. 대기 중 refresh는 하나로 coalesce하며 old worker completion은 request generation이 맞을 때만 publish한다. dock을 닫거나 앱을 종료하면 cancel을 요청하고, 이미 열린 fd와 staged allocation은 worker가 회수한다.

1. trusted discovery root에서 no-follow directory traversal로 regular file만 수집한다. symlink, socket, FIFO, device, nested Claude directory, 예상 밖 파일명은 skip하며 debug artifact에는 raw 제목/프롬프트/경로를 남기지 않는다.
2. provider별 최대 4,096개 후보 metadata를 mtime 순으로 고르고, 합쳐 최근 순으로 분석한다. 이 상한을 넘으면 header에 `일부 최근 후보만 검사함`을 표시한다.
3. worker는 최근 후보를 제한된 worker pool(동시 parse 최대 4)로 분석한다. 첫 verified batch(최대 50개)가 준비되면 즉시 publish하고, 이후 batch도 최신순으로 합친다. 파일은 streaming JSONL parser로 읽고 파일당 128 MiB, refresh당 512 MiB budget을 둔다. 손상 JSON line은 그 line만 버리고 record를 추측해 만들지 않는다. cap/cancel/OOM이면 완성된 record만 publish하고, 해당 record의 분석 상태를 partial로 표시한다.
4. first guard는 앱 실행 중의 완료 snapshot TTL 15초다. TTL hit는 filesystem I/O 없이 현재 snapshot만 보이고, force refresh만 이를 우회한다. worker는 다음 guard로 `(device,inode,mtime,size)`가 같은 파일의 verified parse 결과를 재사용한다. cache miss/identity 변경 파일만 다시 분석하며, 새 snapshot은 cache 결과와 최신 batch를 mtime 순으로 합친다. 500개 verified record가 완성되면 더 오래된 후보는 v1 refresh에서 분석하지 않는다. memory-only snapshot과 parse cache이므로 앱 종료 후 title/prompt metadata, source path, session id를 디스크에 남기지 않는다. persistent cache는 개인정보 보존·삭제 정책을 별도로 승인하기 전 비목표다.

따라서 첫 진입이 즉시 500개를 완성한다는 보장은 없다. UI는 `228개 표시 · 최근 500개 중 분석 중`처럼 현재 snapshot과 scan 상태를 분리해 말해야 하며, search/scope가 partial snapshot을 완전한 결과인 것처럼 보이게 해서는 안 된다.

## 5. 보안·개인정보·관측

- provider log는 민감한 개인 데이터다. 원문·prompt·token·절대 home path를 trace, crash artifact, fixture, analytics, config에 쓰지 않는다. fixture는 synthetic·redacted JSONL만 허용하며 [project-rules.md](project-rules.md)의 redaction 기준을 공유한다.
- scanner는 no-follow로 열고 fstat identity를 discovery snapshot과 다시 대조한다. parse 중 교체되거나 permission이 바뀐 파일은 stale로 버린다. published record는 앱 실행 중에만 absolute source path와 `(device,inode)`를 함께 보존하며, `로그 보기`는 사용자가 누른 때에만 그 identity를 다시 검사해 OS file reveal API에 넘긴다. 교체·삭제·비정규 파일이면 reveal을 거부한다.
- resume command는 shell string concat이 아니라 argv array다. session id/provider/cwd는 UI text나 log에서 명령으로 재해석되지 않는다. parse한 prompt는 실행 인자로 절대 넣지 않는다.
- metrics는 candidate/verified/partial/rejected 개수와 scan duration/bytes만 남긴다. title·요약·cwd·session id는 observability event의 payload가 될 수 없다.

## 6. 구현 순서와 완료 조건

1. **AS1 — 순수 모델·parser:** provider-neutral record, Claude/Codex streaming parser, trust grade, dedup/title/summary/redaction/filter/sort pure tests. 실제 사용자 log는 fixture로 넣지 않는다.
2. **AS2 — bounded scanner:** no-follow discovery, candidate/file/total caps, cancellation/generation, in-memory identity parse cache, 최신순 bounded worker pool과 first/continuation batch snapshot, metrics. main tick filesystem I/O=0·JSON parse=0·worker wait=0을 counter와 source boundary test로 고정한다.
3. **AS3 — 도크 chrome:** header/scope/search/group/row/detail/action menu, `agent_session_list` focus owner, virtualized visible-row rendering과 selection identity. search keypress I/O=0, row 한 번 클릭 실행=0을 integration test로 고정한다.
4. **AS4 — explicit actions·제품 gate:** live exact mapping, copy/reveal, hover/detail `새 탭에서 이어하기`와 argv-only immediate new-Term activation, macOS manual fixture E2E. 실제 provider 계정/개인 이력에 대한 재개는 사용자가 직접 승인한 수동 gate일 뿐 CI 증거가 아니다.

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
| M1 | workspace/project의 의미 | explorer canonical root와 active local git root로 각각 고정; 없으면 비활성화 (§2) |
| M2 | 정확하지 않은 count/검색 | partial 상태·`≥n` 표기와 snapshot-only search를 명시 (§2, §4) |
| M3 | resume cwd·실행 경계 | 삭제 cwd fallback, shell 미사용, 명시 ▶/resume 버튼의 즉시 새 탭 실행을 명시 (§2, §5) |
| M4 | 중복·변경·손상 log | provider/id+file identity, conflict discard, line-level corruption 정책을 명시 (§3, §4) |
| M5 | 키보드·취소·영속 | dedicated focus, generation cancel, memory-only metadata와 nonpersistent query를 명시 (§2, §4) |

이 10회 검토 뒤에도 **정책적으로 남긴 비목표**는 원문 대화 뷰어, legacy-unknown opt-in, remote history, 다른 provider, persistent archive cache다. 이들은 데이터 보존·개인정보·성능 범위를 바꾸므로 별도 사용자 결정 없이 AS1~AS4에 넣지 않는다.
