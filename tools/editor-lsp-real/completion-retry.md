# 정의 재시도 알림이 가린 자동완성 조사

## 원인과 수정

2026-10-26 적대적 검증의 `synced-race-1`은 실제 rust-analyzer가 `probe_result`를
183회 반환했는데도 `ExpectedServerCompletionMissing`으로 끝났다. 진단 발생/해소와
hover·정의 이동은 통과했다. 당시 product JSON에는 팝업을 가린 오버레이 상태가 없어
그 상태를 소급해서 직접 관측했다고 주장하지 않는다.

보존한 wire의 정의 응답 순서는 `null` → `ContentModified(-32801)` → 올바른 같은 파일
대상이었다. LSP null은 초기 인덱싱 때 생길 수 있는 정상적인 읽기 결과이며, 제품은
`definition.onDefinitionResponse`에서 `nav_no_definition` 알림을 보여 준다.
이 알림은 타이머로 닫히지 않고 실제 확인 입력이 필요하다.

검증기는 키 입력 대신 `gotoDefinitionAtCaret`를 직접 다시 불러 성공했다. 앞선 알림은
남아 있었고, 이후 `completion.refresh`는 `editorHelpersSuppressed()` 때문에 완성
항목을 지웠다. 목록 재요청 횟수를 늘려도 이 상태는 풀리지 않는다.

실패 응답을 로컬 재생 서버로 제품에 넣어 같은 경로를 재현했다. 이는 실제 SDK가 새로
응답한 검증과 별개인 합성 재생 실험이다. URI는 소유한 새 프로젝트로 바꿨고, 응답
지연은 최대 100ms로 제한했다. 원래 프로세스의 모든 시간 순서를 재현한 것은 아니다.
원본 로그와 재생 실험은 저장소 밖에 보존하며 제품/SDK 소스에서 가져온 구현은 없다.

수정은 opt-in judge에만 있다. `acknowledgeDefinitionMiss`는 현재 재시도에서
`notified_none`이 새로 증가했고, 열린 notice의 문자열이 현재 번역의
`nav_no_definition`일 때만 `handleKeyEvent(Escape)`로 확인한다. 알림을 직접 지우거나
제품 알림 정책을 바꾸지 않는다. 다른 메시지는 `UnexpectedDefinitionNotice`로 실패하고,
Escape가 다른 입력 소유자에게 소비되어 알림이 남으면 `DefinitionNoticeNotAcknowledged`로
실패한다. 이미 확인한 카운터·감소한 카운터에는 키를 보내지 않는다.

`definition_notices_acknowledged`를 product JSON에 남긴다. `completion_observation`은
처음 16개 스냅샷과 마지막 스냅샷, 대기/필터/refresh 실패 수를 보존한다. 프레임 준비
전후와 refresh 뒤의 항목·기대 항목·팝업·오버레이·hit 행·caret을 고정 크기 저장소로
기록해 다음 실패를 서버 결과 누락과 표시 차단으로 구분한다. 전체 보고서 스키마 v1의
추가 필드이며 이전 저장 증거의 읽기는 유지한다.

## 회귀와 적대적 조건

```sh
mise exec -- zig build test-editor-real-lsp-retry -Doptimize=Debug
mise exec -- zig build test-editor-real-lsp-retry -Doptimize=ReleaseFast
```

각 타깃은 제품 회귀 2개와 모듈 참조 4개, 합계 6개다. SDK를 설치하지 않는다.
macOS-only 게이트에 연결하고 기본 macOS 제품 테스트에도 포함한다.

- RLC1은 실제 정의 컨트롤러에 null을 넣고 실제 Escape 라우팅을 거쳐 notice가 닫힌 뒤,
  실제 완성 컨트롤러/프레임 준비에서 서버 항목이 표시되고 Enter/Undo 되는지 검사한다.
  확인 입력 자체가 본문·caret·Undo 이력을 바꾸지 않는지도 확인한다.
- RLC2의 20개 상태 입력은 반복 실행으로 횟수를 채운 것이 아니다. 카운터 출처, 경계,
  다른 메시지, 입력을 다른 소유자가 받은 실패를 구분한다.

| 번호 | 상태 입력 | 기대 |
|---|---|---|
| 1 | 초기 카운터, 닫힌 notice | 키 없음 |
| 2 | 새 카운터 없는 다른 오류 | 오류 notice 유지 |
| 3 | 새 카운터 없는 동일 문구 | 이전 notice 유지 |
| 4 | 이미 확인한 카운터 | 재확인하지 않음 |
| 5 | 카운터가 이전 값보다 작음 | 상태/notice 유지 |
| 6 | 카운터 0으로 감소 | 상태/notice 유지 |
| 7 | 새로운 miss지만 notice 이미 닫힘 | 입력 없이 관측값만 갱신 |
| 8 | 여러 miss, notice 이미 닫힘 | 입력 없이 최신 카운터 수용 |
| 9 | 닫힌 notice와 u64 최댓값 | overflow 없이 수용 |
| 10 | 최초 own miss | Escape 한 번으로 확인 |
| 11 | 다음 own miss | 새 notice만 확인 |
| 12 | 여러 miss 뒤 한 열린 notice | Escape 한 번 |
| 13 | 최댓값 직전에서 최댓값의 miss | overflow 없이 확인 |
| 14 | 새로운 miss 뒤 다른 오류 | UnexpectedDefinitionNotice |
| 15 | 반복 miss 뒤 다른 오류 | 오류/카운터 보존 |
| 16 | 최댓값 miss 뒤 다른 오류 | 오류/카운터 보존 |
| 17 | ended 세션이 Escape를 받지 못함 | DefinitionNoticeNotAcknowledged |
| 18 | inspector가 Escape를 먼저 받음 | notice/미확인 카운터 보존 |
| 19 | trust 확인창과 이미 닫힌 notice | trust를 닫지 않음 |
| 20 | 최댓값 관측 뒤 닫힌 카운터 0 | 감소를 새 이벤트로 취급하지 않음 |

모든 상태 입력에서 본문·caret·Undo를 보존한다. 재시도 자체는 기존의 시한을 유지하며
진단 편집·저장을 자동 반복하지 않는다. 전체 SDK 검증은 README의 별도 명령을 따른다.

## 관측 범위

증거 루트는 `/Users/yoonhb/.cache/maru-agent-artifacts/lsp-completion-20261026/`이다.
`replay-01`, `replay-02`는 수정 전 오버레이 차단, `regression-before.log`는 수정 전
제품 회귀 실패다. 재생 응답을 일반 실제 SDK 성공 수에 합산하지 않는다.
관측만 넣은 첫 40회와 프레임을 기다린 40회는 모두 통과했다. 단순 반복 통과를 원인
수정 증거로 사용하지 않았고, null 응답 재생과 제품 회귀를 전후 대조로 삼았다.
GUI·Metal 캡처와 실제 SDK 결과는 PR에서 각각 경로와 검증 범위를 구분한다.
