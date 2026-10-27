# 파싱 메인 큐와 문서 수명 검증

`dispatch.submit`은 문서의 request lease와 지속되는 Gate로 작업을 준비한다.
`ready`의 Completion은 다음 poll·submit·close·shutdown 전까지만 빌린다.
워커는 Registry·뷰 포인터를 받지 않는다. 문서 참조는 두 Snapshot이 메인에서 반환될 때까지 유지한다.

```sh
mise exec -- zig build test-editor-parse-runtime test-editor-parse-host test-editor-parse-main-queue test-editor-parse-worker test-editor-parse-request -j2
mise exec -- zig build test-editor-parse-runtime test-editor-parse-host test-editor-parse-main-queue -Doptimize=ReleaseFast -j2
python3 tools/editor-parse-runtime/review.py --output /tmp/new-parse-runtime --deps /path/to/deps --cache /path/to/cache
```

Runtime 판정 6개는 마지막 뷰·실제 revision·공유 뷰·할당 실패·동일 문서 재생성 serial·늦은 전달을
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
