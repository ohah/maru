# Rust 진단 미수신 조사 (2026-10-26)

대상은 Draft #4592의 `0b75a11e7`과 rust-analyzer 1.96.1 (`31fca3ad`)이다.
제품 코드는 바꾸지 않고, 보존한 Debug judge와 새 소유 프로젝트로 조사했다.

## 확인한 경계

원래 실패에서는 Maru의 `didChange(version=2)`와 `didSave`가 실제 서버에 전달됐지만,
그 뒤 `publishDiagnostics`가 오지 않았다. Maru 수신·좌표 변환 과정에서 오류 진단이 사라진 사례가 아니다.
정상 실행의 E0308은 `source=rust-analyzer`였다. 초기에는 Cargo 실행 지연을 의심했으나
자체 의미 진단과 `rustc`의 저장 후 진단을 따로 보아야 한다.

RA_LOG와 Salsa 취소 추적을 켜자 진단 해소의 누락도 재현됐다.
서버 스레드 sample에서 main loop와 worker는 대기 중이었다. 오래 걸리는 분석이 계속 돌아가는 상태와 구분된다.
다만 sample만으로 이전 순간의 취소 원인을 직접 계측한 것은 아니다.

## 원인 경로

1. 서버는 변경을 받은 뒤 문법/의미 진단을 비동기로 예약한다.
2. 프로젝트 재적재·캐시 예열 완료·idle GC는 Salsa snapshot의 작업을 취소할 수 있다.
3. 이 SDK의 자체 진단 계산은 취소 결과를 빈 진단으로 바꾸고, push 재시도를 예약하지 않는다.
   이미 빈 목록이면 내용이 같으므로 새 문서 버전에도 재발행하지 않는다.
4. 저장 후 Cargo 검사를 시작하는 비동기 작업도 취소될 수 있다. 그 내부의 `Err(Cancelled)`는
   바깥 panic 처리와 구별되는데, 해당 경로는 정상 반환 안의 취소를 다시 예약하지 않는다.
5. Maru의 Rust 서버 항목은 push 전용이다(`pull_diagnostics=false`). 서버가 광고한
   `diagnosticProvider`를 이용한 최신 본문 재조회 경로를 사용하지 않아 누락이 남는다.

이는 SDK 소스와 아래 실제 실행의 결합으로 좁힌 경로다. 기존 10월 25일 실패에는 Salsa 추적이 없으므로
그 실행의 개별 취소 호출까지 소급해 확정하지 않는다. **같은 미수신 증상은 새 추적 실행에서도 재현했다.**

조사한 SDK 소스는 `references/rust-analyzer-1.96.1/`에서 읽었으며 제품에 복사하지 않았다.
태그와 `31fca3ad`의 main_loop 소스 SHA256은 모두
`0f118f81d347c9bc67bf57d3d3247cf29c1bb57b2754797c8b984ac1a5976959`였다.

- [main_loop.rs](https://github.com/rust-lang/rust/blob/31fca3ad/src/tools/rust-analyzer/crates/rust-analyzer/src/main_loop.rs):
  캐시 예열 완료/idle GC, 변경 시 진단 예약, 취소 결과의 빈 목록 전환, 변경된 진단만 push.
- [ide/lib.rs](https://github.com/rust-lang/rust/blob/31fca3ad/src/tools/rust-analyzer/crates/ide/src/lib.rs):
  `trigger_garbage_collection`이 진행 중 query를 취소함을 명시한다.
- [diagnostics.rs](https://github.com/rust-lang/rust/blob/31fca3ad/src/tools/rust-analyzer/crates/rust-analyzer/src/diagnostics.rs):
  계산의 취소를 빈 값으로 처리하고 같은 진단 내용의 재발행을 생략한다.
- [notification.rs](https://github.com/rust-lang/rust/blob/31fca3ad/src/tools/rust-analyzer/crates/rust-analyzer/src/handlers/notification.rs):
  `run_flycheck` 작업의 취소 결과를 재예약하지 않는 경로.

## 재현과 대조

증거 루트는 `/Users/yoonhb/.cache/maru-agent-artifacts/rust-diagnostics-20261026/`이다.
로그·manifest·실험 wrapper를 보존했다. SDK 응답은 만들어 내지 않았다.

- `run-1`~`run-16`: 설정을 바꾸지 않은 실제 SDK 16회. 10회 통과, 6회 `TypeErrorNotCleared`.
  각 실행의 원본 wire, 서버 내부 로그와 제품 결과를 보존했다. 이 횟수는 20개 적대적 검증의 대체가 아니다.
- `priming-on-1`~`5`: Cargo 검사만 끄고 자체 진단을 분리했다. 4회 통과,
  `priming-on-5`는 원래와 같은 `TypeErrorNotPublished`.
- `priming-off-1`~`5`: 동일하게 Cargo 검사를 끄고 캐시 예열도 껐다. 5회 통과.
  작은 대조군이므로 예열 비활성화가 모든 레이스를 해결한다는 보장은 아니다.

설정 대조 실험의 wrapper는 initialize의 명시적 설정만 바꾸고,
실제로 전송한 initialize를 `experiment-transmitted-initialize.json`에 저장했다.
관찰기에 기록된 변경 전 initialize와 다르므로 일반 회귀 증거로 합산하지 않는다.

`priming-on-5` 서버 로그의 시간순서는 다음과 같다.

| 시각 (+09:00) | 사건 |
|---|---|
| 01:38:12.619 | 잘못된 인수의 version 2 변경과 저장 수신 |
| 01:38:14.158 | 문법 진단 작업 결과 도착 |
| 01:38:14.373 | 캐시 예열 완료와 Salsa 취소 flag |
| 01:38:14.406 | 의미 진단이 빈 목록으로 끝남 |
| 01:38:22 | 잘못된 본문을 유지한 채 오류 진단 대기 실패 |

별도의 해소 누락 사례 `run-9`에서는 version 2의 오류와 곧바로 빈 목록이 서버에서 나갔다.
클라이언트가 version 3으로 복원한 시점에는 빈 목록의 version이 아직 2여서 Maru는 이를 거절했다.
이후 version 3의 자체 분석도 빈 목록이지만 같은 내용이므로 새 push가 없었다.
지난 버전을 허용하는 해결책은 잘못된 진단을 새 문서에 적용할 위험이 있다.

## 명시적 pull 대조

`pull-native-1`~`8`은 Cargo 검사를 끄고 캐시 예열을 켠 조건에서, 첫 편집 4초 뒤에
실제 SDK에 진단 요청을 한 번 더 보냈다. 이 요청은 실험 wrapper가 보내며 제품 구현 변경은 아니다.
요청/응답은 `experiment-pull.ndjson`에 따로 보존했다. observer의 client wire에는 이 추가 요청이
없으므로 이 실험을 일반 회귀 통과 증거에 합산하지 않는다.

8회 중 5회(`2, 3, 5, 7, 8`)는 push 오류 미수신으로 `TypeErrorNotPublished`가 됐지만,
**그 5회 모두 pull 응답에는 실제 rust-analyzer의 E0308이 있었다.**
따라서 같은 본문을 분석할 수 없거나 오류가 없는 경우와 구분된다.
제품으로 가는 응답을 만들어 넣거나 편집/저장을 반복하지 않았다.

```text
요청: textDocument/diagnostic, identifier=rust-analyzer
응답: kind=full, source=rust-analyzer, code=E0308
내용: expected i32, found &'static str
범위: line 2, UTF-8 character 50..55
```

해소 누락 실험 `pull-3`, `pull-4`에서도 명시적 pull은 수정된 본문의 빈 목록을 반환했다.
서버가 현재 분석 결과를 알고 있어도 push의 최신 버전 재발행이 보장되지 않는 점을 확인했다.

## 제품 수정 방향

Rust의 진단을 서버가 제공하는 pull 경로로 요청하고, 현재 문서 버전/요청 순번에 맞는 결과만 적용하는 것이 우선이다.
서버의 초기 준비·refresh·편집 후 재조회와 취소/재진입을 함께 검증해야 한다.
고정 sleep, 캐시 예열 전역 비활성화, 오래된 push 진단의 무조건 수용으로 처리하지 않는다.
위 조사 이후 사용자 승인으로 아래 pull 복구를 구현했다.


## 제품 복구 구현

Rust 서버 표의 pull 선택을 켜고 기존의 version/seq/dirty 처리, 처음 열기·편집·refresh·파일 간
의존 문서 재조회를 사용한다. pull provider를 협상한 서버의 파일 진단은 pull만 적용하고,
provider가 없거나 pull을 선택하지 않은 서버는 기존 push를 유지한다.

실제 초기 Rust 실행에서 `-32802`와 `retriggerRequest=true`를 관찰했다. 이 명시적 신호만
L2 `DiagnosticRetry`로 예약한다. 120ms부터 지수 backoff해 2초에서 제한하며, 정상 결과·새 편집·
refresh·재시작·경로 퇴역은 예약을 비운다. 취소 금지·영구 오류·잘못된 data를 자동 반복하지 않는다.
요청 seq가 달라진 응답은 새 요청의 대기를 해제하지 않는다. SDK 캐시 예열·저장·실행 신뢰는 바꾸지 않았다.

판정자의 관찰기도 pull을 해석한다. 요청 때의 본문 version/URI에 대응한 `full.items`를 검사하고
Rust의 bad/fixed가 모두 pull 응답에 있어야 성공한다. 협상된 pull 결과를 push로 대체할 수 없다.
진단 오류·누락·협상 부재·다른 URI·근거 없는 unchanged를 거부하는 Python 검사는 총 51개다.

실행 명령:

```sh
mise exec -- zig build test-editor-rust-pull -j2
mise exec -- zig build test-editor-rust-pull -Doptimize=ReleaseFast -j2
mise exec -- zig build test-editor-real-lsp-oracles
```

### 서로 다른 적대 조건 20개

`LSJDP`의 실제 RPC 분류와 L2 `RDP diagnostic`의 주입 시계로 다음 입력을 검사한다.
정상 `ServerCancelled + true`와 시한 도달 대조군도 함께 확인한다. 동일 실행의 반복으로 세지 않는다.

| # | 공격 입력/상태 | 기대 결과 |
|---|---|---|
| 1 | retriggerRequest=false | 자동 재시도 신호 없음 |
| 2 | 취소 응답에 data 없음 | 자동 재시도 신호 없음 |
| 3 | data=null | 거부, panic 없음 |
| 4 | data=[] | 거부, panic 없음 |
| 5 | data 객체에 flag 없음 | 자동 재시도 신호 없음 |
| 6 | flag가 문자열 true | 자동 재시도 신호 없음 |
| 7 | flag가 숫자 1 | 자동 재시도 신호 없음 |
| 8 | 클라이언트 취소 코드와 true | 자동 재시도 신호 없음 |
| 9 | ContentModified 코드와 true | 같은 요청의 자동 재시도 신호 없음 |
| 10 | InvalidParams 코드와 true | 영구 오류 반복 없음 |
| 11 | 오류 코드가 문자열 | 자동 재시도 신호 없음 |
| 12 | error=null | 거부, panic 없음 |
| 13 | 예약 없이 최대 시각 도달 | 요청을 만들지 않음 |
| 14 | 취소 직후 같은 시각 pump | 곧바로 재시도하지 않음 |
| 15 | 시한 1ms 전 | 아직 재시도하지 않음 |
| 16 | 시계가 과거로 이동 | 일찍 재시도하지 않음 |
| 17 | 같은 만기 타이머 두 번 소비 | 한 번만 실행 |
| 18 | 취소 횟수 300번 누적 | 카운터 wrap 없이 2초 상한 유지 |
| 19 | 최대 u64 직전 예약 | 시한 overflow 없이 포화 |
| 20 | 시각 0에 예약 | 예약 없음과 혼동하지 않음 |

`RDP1`은 실제 AppSession과 fake process로 PCANCEL(별도 refresh 없음) 복구와 PREFRESH,
같은 버전의 늦은 push, 다른 seq와 지연된 이전 seq, 지난 문서 version, null 결과,
오류 해소와 다른 열린 파일의 의존 진단을 검사한다. TS·Ruby·ESLint의 기존 제품 대조군도 함께 실행한다.
순수 31/제품 9개에는 모듈 참조 테스트가 포함되며 SDK 사례 수와 구분한다.


### 수정 후 실제 SDK 결과

구현 커밋 `19e9e02fa`(dirty=false)에서 다섯 언어의 실제 편집 흐름을 두 프로필로 확인했다.
각각 진단 발생/해소·호버·정의 이동/복귀·완성 적용/Undo와 독립 wire 검증을 통과했다.
Rust의 진단 경로는 pull로, 다른 네 언어는 기존 push로 확인했다.

이전 RA_LOG 조건의 별도 Rust 반복은 Debug 8회와 ReleaseFast 8회 모두 통과했다.
이 16회에는 실제 ServerCancelled 응답 23건이 있었고, 재요청 이후 정상 완료했다.
같은 SDK의 이전 push 전용 16회에는 해소 미수신 6회가 있었다. 반복 수는 위 적대 조건 20개와 별개다.

증거 루트: `/Users/yoonhb/.cache/maru-agent-artifacts/rust-pull-fix-20261026/`.
`final-debug`, `real-fast`, `race-debug-1`~`8`, `race-fast-1`~`8`의 총 18개 디렉터리를
SDK 없이 `verify.py`로 다시 검사해 모두 통과했고 `all-offline-verification.json`에 결과를 남겼다.
`final-debug/tool-sources/verify.py`의 보관한 판정기 사본으로도 재검사했다.
31개 순수/9개 제품 테스트는 Debug·ReleaseFast에서 전부 통과했고 Python 51개도 통과했다.
위 적대 조건의 기대 결과를 두 프로필에서 확인했다. GUI/물리 입력 증거로 확대하지 않는다.

전체 `mise run check`는 1071.38초에 종료 코드 0으로 통과했다. 현재 코드의 경계 검사와
리베이스된 첫 구현 커밋 `907412a9c`의 별도 경계 검사도 통과했다. 그 다음 `5e811e08b`는
README/조사 문서만 추가한 커밋으로 게이트 대상 Zig 소스가 같다. Swift·최종 문서 링크/줄 참조도 통과했다.
Draft 주요 CI의 생략과 로컬 통과를 구분하며, 위 로그는 로컬 산출물이다.
