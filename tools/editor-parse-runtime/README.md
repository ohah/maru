# 파싱 메인 큐와 문서 수명 검증

`dispatch.submit`은 문서의 request lease와 지속되는 Gate로 작업을 준비한다.
`ready`의 Completion은 다음 poll·submit·close·shutdown 전까지만 빌린다.
워커는 Registry·뷰 포인터를 받지 않는다. 문서 참조는 두 Snapshot이 메인에서 반환될 때까지 유지한다.

```sh
mise exec -- zig build test-editor-parse-runtime test-editor-parse-host test-editor-parse-main-queue test-editor-parse-worker test-editor-parse-request -j2
mise exec -- zig build test-editor-parse-runtime test-editor-parse-host test-editor-parse-main-queue -Doptimize=ReleaseFast -j2
python3 tools/editor-parse-runtime/review.py --output /tmp/new-parse-runtime --deps /path/to/deps --cache /path/to/cache
```

Runtime 판정 12개는 마지막 뷰·실제 revision·공유 뷰·할당 실패·동일 문서 재생성 serial·늦은 전달을
검사한다. AppSession 판정 target은 실제 창 소유자 파괴 2개와 기존 익명 초기화 4개다.
Linux에서는 macOS 전용 익명 초기화 3개가 빠져 총 3개를 수집하고, 실제 창 수명 2개는 skip한다.
플랫폼별 정확한 개수를 검사해 target 누락을 허용하지 않는다.
이 두 target의 OS 전달은 명시적으로 제어한다. 별도 production-mode probe는 제품의
`main_queue.c.inc`와 CoreFoundation run loop를 사용한다. 수동 poll이나 렌더 tick 없이
메인 스레드 수락·닫힌 문서 회수·종료 후 늦은 실제 전달을 확인한다.

독립 소스에서 문서 조기 해제·revision 검사 제거·Gate 초기화·재무장 제거·닫기 무효화 제거를
각각 컴파일하고 실행 assertion 실패를 요구한다. 정상 전후 대조는 통과해야 한다.
컴파일 실패를 검출 성공으로 세지 않는다. 새 소스는 먼저 stage하며 기존 output을 재사용하지 않는다.
원본/변형 소스·실행 파일·로그·전체 해시는 외부 output의 result.json에 보존한다.

현재 증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/parse-runtime-review-1/`이다.
다섯 결함 모두 실행 중 거절됐고 정상 전후 대조는 통과했다.
기존 worker 19개·요청 Gate 36개도 별도 회귀 target을 유지한다.

일반 편집기의 입력·렌더 경로는 아직 전환하지 않았다. 뷰별 캐시 설치·실제 GUI/IME·입력 지연·
race detector·C malloc 실패 전수 검증은 이 결과에 포함하지 않는다.
준비 실패는 내부 호출자에게 오류를 반환하며 본문·Undo를 바꾸거나 동기 파싱으로 우회하지 않는다.

## 화면 연결 전 상태 조회

`dispatch.observe`/`Runtime.observe`는 현재 문서·본문 판·언어 설정에 해당하는 게시 대기와
실패를 포함한 완료를 구분한다. 완료 값은 Request와 Outcome 값만 보유하며 트리나 Job을 빌리지 않는다.
`submit` 준비 실패는 오류 반환과 `none`으로 표시하며 자동 재시도하지 않는다.
호출자가 알림·재시도를 결정하기 위한 기반이고 일반 입력·표시 경로는 전환하지 않았다.

```sh
python3 tools/editor-parse-runtime/review.py --scope observation --output /tmp/new-parse-observation --deps /path/to/deps --cache /path/to/cache
```

실패 버리기·옛 실패의 새 요청 덮어쓰기·grammar 무시·revision 무시·재시도에서 옛 실패 보존의
다섯 실제 결함을 컴파일한다. 옛 완료 검사는 이전 작업과 새 작업의 실제 copy allocator를 각각 장벽으로 멈춰
완료 순서를 결정한다. 고정 sleep이나 경쟁이 우연히 일어났다는 추정에 의존하지 않는다.
기본 `--scope lifetime`은 기존 수명 결함 대조를 유지한다. 두 모드 모두 runtime 12개·host 6개와
실제 Apple 전달 실행을 요구한다. UI·알림 정책은 별도다.

## 소비자 보유 참조

`acquire`는 현재 결과를 검증해 보유하고 `Completion.retain`은 그 보유를 추가한다.
각 핸들은 정확히 한 번 release한다. 반환 전에는 읽기 전용 provider 자원을 빌릴 수 있으나
이전 본문의 결과를 새 본문에 사용하는 허가는 아니다. 마지막 반환만 워커 퇴역을 게시한다.
뷰 연결 시 독립 뷰 자원을 먼저 반납하고 이 핸들을 나중에 반환해야 최종 해제 경계가 유지된다.

`Runtime.deinit`와 `dispatch.tryShutdown`은 외부 참조가 있으면 ResultsHeld로 거절하며
현재 Gate·결과·전역 소유자를 보존한다. 기존 `shutdown`은 소비자가 모두 반환됐다는 선행 조건을
갖는다. 일반 입력/뷰는 이 참조를 보유하며 AppSession 종료 전에 모두 반환한다.

```sh
python3 tools/editor-parse-runtime/review.py --scope leases --output /tmp/new-parse-leases --deps /path/to/deps --cache /path/to/cache
```

Job 참조 증가 누락·전체 참조 증가 누락·마지막 반환 전 퇴역·종료 가드 제거·현재 입력 검사 없는
acquire의 다섯 실제 결함을 컴파일·실행한다. runtime 12개·host 6개·worker 19개와 실제 Apple
전달을 요구한다. worker C 장벽 아래에서 큐 게시를 검사하고, 잘못된 참조 수와 조기 게시를 주입한
경우에도 테스트 cleanup만 복구해 assertion 결과와 별개 누수/이중 해제를 섞지 않는다.
Apple probe의 `retained_result=1`은 실제 메인 큐 수락 후 보유 중 종료 거절·반환 후 종료 증거다.

## 실제 구문 뷰 상태 설치

`prepareView`는 결과 보유와 독립 native 복사를 준비하고 `installView`는 실제 view lease와
현재 요청을 다시 검증해 syntax.State에 이동한다. 캐시를 무효화하되 배열 용량을 유지하고,
기존 뷰 native 자원 → 완료 보유 참조 순서로 반환한다. legacy provider는 교체하지 않는다.
일반 입력 연결과 완료 뒤 접힘·심볼 피커·redraw는 `parse/client.zig`가 담당한다. 아래 제품 입력 검사를 따로 실행한다.

```sh
mise exec -- zig build test-editor-parse-view test-editor-parse-runtime test-editor-parse-host test-editor-parse-main-queue -j2
python3 tools/editor-parse-runtime/review.py --scope view --output /tmp/new-parse-view --deps /path/to/deps --cache /path/to/cache
```

전용 target은 실제 뷰 상태 검사 4개와 root 초기화 1개(5개)를 실행한다. 색과 전체 native 노드
좌표를 cold 결과와 대조하고 실제 접힘·괄호·심볼 캐시를 채운 뒤 교체를 검사한다. 준비 뒤 같은
본문 재요청·편집·다른 문서/참조와 legacy/빈 문서, split 보유와 overflow도 검사한다.
`--scope view`는 낡은 준비 설치·Provider 얕은 복사·잘못된 입력 stamp·괄호 무효화 누락·뷰 반환
누락을 실제 컴파일·실행한다. 잘못된 얕은 복사/반환 누락에서는 테스트 cleanup만 복구해
검사 실패와 이중 해제·누수를 섞지 않는다. 컴파일 실패를 탐지로 세지 않는다.

Runtime native 모듈은 `editor/parse.zig`를, 판정은 `editor/parse_test.zig`를 루트로 사용한다.
기존 구현 폴더를 유지하면서 같은 editor의 syntax.State를 상대 import할 수 있는 모듈 경계다.
Apple probe의 `installed_view=1`은 실제 메인 큐 완료 뒤 설치·뷰 보유 중 종료 거절·반환 후 종료를
검사하며 제품 화면/HID·IME의 시각 증거는 아니다. native malloc 실패 전수 검증도 아니다.

## 공유 입력의 요청 재사용

`ensure`는 같은 문서 identity·revision·grammar 설정·native language의 게시 요청을
재사용한다. pending/ready/실패 완료 모두 새 게시 없이 tag를 반환하며 `published=false`다.
이미 완료된 입력의 재사용은 알림을 다시 보내지 않으므로 새 뷰는 observe/prepareView도 확인한다.
같은 입력을 강제로 다시 시도하는 기존 submit과 구분한다. 준비 오류는 submit과 같은 오류로
반환하며 이 API가 UI 재시도 시점을 정하지는 않는다.

```sh
python3 tools/editor-parse-runtime/review.py --scope sharing --output /tmp/new-parse-sharing --deps /path/to/deps --cache /path/to/cache
```

Runtime 12개는 공유 뷰의 pending/ready 재사용을 할당이 실패하도록 설정한 상태에서도 확인한다.
독립 문서·revision/설정/native 언어 변경은 새 게시를 요구한다. 실제 복사 OOM 후 같은 입력의
실패를 재사용하고, 소비자가 옛 결과를 보유해 Entry가 살아 있는 동안 마지막 뷰를 닫고 다시 열면
새 요청이 게시되는지도 검사한다. Apple probe의 shared_request=1은 실제 main queue의 대기·
완료 재사용 뒤 기존 설치·반환 경로가 정상임을 뜻한다.

다섯 실제 결함은 공유 입력 재게시·revision 무시·grammar 무시·native 언어 무시·닫힌 시도의
실패 유지다. 정상 전후 대조와 실행 assertion을 요구하며, 일반 입력·실패 알림 정책은 별도다.

## 이용 불가 원인

`Completion.unavailableReason`과 `Runtime.observe().finished.unavailable_reason`은 미지원 문법,
기존 입력 크기 제한, native 초기화 실패, 취소 없는 분석 미완료를 구분한다. 복사 OOM은 기존
Outcome을 유지하며 이유는 null이다. 새 시도에서 옛 이유를 지우고, 낡은 실패는 최신 이유를
덮어쓰지 않는다. 화면 알림이나 재시도 정책을 활성화하는 API는 아니다.

```sh
python3 tools/editor-parse-runtime/review.py --scope reasons --output /tmp/new-parse-reasons --deps /path/to/deps --cache /path/to/cache
```

워커 19개·Runtime 12개·호스트 6개와 실제 메인 큐 probe를 실행한다. 미지원 문법·크기 제한·
progress 중단의 오분류, Runtime 원인 누락, 취소 뒤 옛 원인 노출의 실제 결함을 각각
컴파일·실행하고 정상 전후 대조군을 요구한다. C allocator 고갈을 직접 재현한 증거는 아니다.

## 실패 후 자동 재초기화 차단

`ensure`는 실패한 문법을 편집 revision 변경만으로 다시 초기화하지 않는다. 문서가 직접 보관하는
`SyntaxRecovery` 덕분에 공유 뷰와 Runtime 재생성 뒤에도 기록이 남는다. 알려진 실패에서
`dispatch.ensure`는 worker를 다시 만들기 전에 차단한다. 정상 엔진의 편집 분석은 계속 유지한다.
명시적 `submit`, 문법 설정/native 언어 변경, 마지막 뷰 닫기 뒤 재열기가 초기화 계기다.
일반 실패는 로그로 기록하며 토스트를 추가하지 않는다. 실제 팔레트 명령과 입력 화면 전환은 후속이다.

```sh
python3 tools/editor-parse-runtime/review.py --scope recovery --output /tmp/new-parse-recovery --deps /path/to/deps --cache /path/to/cache
```

Runtime 12개·호스트 6개와 실제 main queue probe를 실행한다. 실제 copy OOM 뒤 편집·공유 뷰
차단과 다른 문서 격리, 명시적 재분석·설정 변경·재열기, Entry/Gate 준비 OOM과 Runtime 재생성을
검사한다. 편집 차단·worker 실패 기록·준비 실패 기록·명시적 해제·문법 키의 다섯 실제 결함을
컴파일·실행하고 정상 전후 대조군을 요구한다. UI/HID·IME·native malloc 고갈 검증은 아니다.

## 일반 제품 입력 연결

`test-editor-parse-input`은 macOS 10개(제품 6 + 초기화 4), 다른 플랫폼 7개(제품 제외)를 수집한다.
테스트용 동기 대조군과 달리 실제 AppSession 기본 모드가 비동기인지 먼저 확인한다.
완료는 실제 wake 정산으로만 설치하며 프레임 fallback으로 전달 누락을 숨기지 않는다.

```sh
python3 tools/editor-parse-runtime/review.py --scope input --output /tmp/new-parse-input --deps /path/to/deps --cache /path/to/cache
```

기본 모드·편집 요청·완료 전달·실패 뷰 재시도·심볼 목록에 실제 결함 다섯 개를 컴파일한다.
runtime 12개·host 6개·제품 입력 10개와 실제 Apple 전달을 요구한다.
실제 UI·OS IME와 지연 수치는 별도 제품 앱 실행으로 검증하며, 이 검사를 그 증거로 확대하지 않는다.
