# 파싱 서비스의 실제 큐·취소·자원 회수

구현은 `platform/macos/app_session/editor/parse/worker.zig`다. UI·AppSession·완료 wake에 연결하지 않은
native 서비스 기반이며, 기존 편집기 파싱 경로는 유지한다. 메타데이터 수락은 L2의 `request.Gate`,
스레드와 수명 조정은 native 호스트 계층, 실제 파싱과 협력 취소는 `syntax.Provider`가 소유한다.

```sh
mise exec -- zig build test-editor-parse-worker test-editor-parse-worker-native test-syntax -j2
mise exec -- zig build test-editor-parse-worker test-editor-parse-worker-native -Doptimize=ReleaseFast -j2
python3 tools/editor-parse-worker/review.py --output /tmp/new-parse-worker --deps /path/to/deps --cache /path/to/cache
```

native 서비스 target은 macOS에서 실행한다. 새 외부 output과 기존 추출 dependencies·캐시를 사용한다.
새 소스 파일은 Git에 stage해 독립 사본에 포함한다. 기본 `test`·macOS 게이트에 서비스
판정자를 포함했고, 테스트 전용 필드가 빠지는 실제 production-mode 실행도 기본/macOS 게이트에 포함했다.
`test-syntax`는 기존 Provider 전체 판정자의 별도 진입점이다.

## 소유권 계약

- `Service`는 이동 후 복사하지 않고 메인에서만 호출한다. 자체 I/O executor와 상주 worker 하나를 소유한다.
- `submit`은 `Gate.begin`을 먼저 수행한다. 성공할 때만 Snapshot을 가져가며 실패 시 caller가 계속 소유한다.
- 같은 문서 신원의 대기는 최신 하나만 남긴다. 새 요청은 아직 빌리지 않은 이전 완료도 퇴역시킨다.
  다른 문서의 대기는 유지하며 대기 순서는 FIFO다. 교체된 요청은 뒤로 들어간다.
- `cancelDocument` 전에 caller가 Gate를 무효화한다. 실행 중에는 취소 플래그만 저장한다. native 기준 핸들이 없는
  대기는 메인에서 회수할 수 있지만 C 호출 중인 작업은 실제 반환 전까지 해제하지 않는다.
- `take`의 Completion은 복사하지 않는다. `accept`는 성공한 결과만 Gate에 넘기며, 현재 실패 결과는
  Gate의 수락 가능성만 지운다. 설치와 parser/tree provenance는 별도 책임이다.
- `provider`는 release 전까지만 빌리는 const 참조다. `release` 후 사용하지 않는다. 복사하거나 편집한
  별도 native 핸들의 수명까지 서비스가 보장하지 않는다. UI 공유 뷰 연결은 후속이다.
- `release`는 워커 퇴역 목록에 넣는다. 파서·트리는 워커에서 해제하고, `reap`은 원본 Snapshot과 Job을
  메인에서 회수한다. cancel/submit도 이미 반환된 자료를 reap한다.
- Snapshot의 원본 allocator와 서비스 allocator는 최종 reap/deinit까지 살아 있어야 한다.
  copy_allocator는 워커에서만 사용하고 그 context도 서비스 종료까지 보존한다.
- 빌린 Completion이 있으면 `deinit`은 `ResultsHeld`를 반환하고 서비스를 유지한다. caller가 결과를
  반환한 뒤 다시 종료한다. 종료는 실행 취소·대기/완료 퇴역·join·메인 회수를 수행한다.

완료·퇴역 자료의 개수와 빌린 결과까지 포함한 전체 메모리 상한을 주장하지 않는다. native 취소는 협력적이며
종료 join에 엄격한 시간 상한은 없다. 서비스 자체는 메인 callback의 응답을 기다리지 않는다.
이 내부 API 조건은 사용자 닫기/실패 UX를 정한 것이 아니다.

## 검증

실제 스레드와 C 콜백 장벽으로 집중 판정 19개를 실행한다. 최신 교체, 문서 격리, 준비 OOM,
본문 복사 OOM, 완료 후 취소, 빌린 결과와 종료, 실행·대기의 종료 정산, 빈 입력/미지원,
미수령 완료의 퇴역을 확인한다. 테스트에서만 Provider 소유 객체의 생성/해제 스레드와 회수 횟수를
계수하고, worker copy allocator의 실제 할당/해제 byte도 비교한다. C 내부 malloc 전체 원장을 센 것은 아니다.

실제 production-mode 실행은 테스트 전용 gate/audit 필드가 없는 서비스에서 요청·C 파싱·수락·반환·종료를
수행한다. 기존 구문 파서 판정과 증분 중단/좌표 oracle 대조도 별도로 대조한다. UI는 열지 않는다.

독립 사본에서 native 취소 무시, 이전 대기 유지, 복사 OOM 오분류, 이전 완료 유지,
준비 OOM에서 이전 Gate 복원 다섯 코드를 실제로 컴파일해 assertion 실패를 요구한다.
현재 정상 소스는 전후에 19개 모두 통과해야 하며 컴파일 실패는 탐지로 세지 않는다.
증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/parse-worker-review-2/`의 source·변형 소스·
실행 바이너리·로그·runner·result.json에 보존한다. 이 자료는 당시 9개 판정자의 실행 기록이며, 현재 소스의 재실행 기록과 구분한다.
수집 기준 Git ID와 실제 source inventory를 구분한다.

`submit`은 cold parse를 유지한다. `submitFrom`은 독립 native 핸들과 Snapshot 참조를 준비해
명시적 증분 인계를 수행한다. [추가 계약·검증·실측](../editor-parse-incremental/README.md)을 따른다.
따라서 서비스 동작 검증을 제품 입력 지연 개선으로 해석하지 않는다.

## 미검증 범위

실제 창 닫기·앱 종료·wake 배선·렌더·IME·공유 뷰의 복사 트리 참조·성능/메모리 예산·
멀티 문서 대규모 공정성·race detector·C 내부 malloc 실패는 후속이다. 기존 4MiB 파싱 제한을
그대로 따르며 새 문서 크기/메모리 제한이나 사용자 실패 알림 정책을 도입하지 않는다.

완료 통지의 선택적 hook과 재무장 순서는 [추가 계약](../editor-parse-notify/README.md)을 따른다. 실제 OS dispatch는 후속이다.
