# 명시적 증분 파싱 인계

`Service.submitFrom`은 caller가 보유한 `Completion`을 호출 동안만 빌린다. 문서 신원·문법 판·실제
언어가 같고 ready 트리가 있으면 메인에서 `Provider.copyReady`와 `Snapshot.clone`을 준비한다.
성공 뒤 원본 Completion은 곧바로 반납해도 된다. native 복사 실패나 기준 불일치는 cold 경로를 쓴다.
기존 `submit`의 cold 계약과 기존 제품 파싱 정책은 유지한다. UI·완료 wake에는 연결하지 않았다.

워커는 이전/새 원문을 각각 복사하고 `edit_ops.reloadChange`로 UTF-8 경계를 보존한 범위를 만든다.
`syntax.pointAt`의 좌표는 LF 행·byte 열이며 CRLF 원문을 보존한다. 동일 본문은 복사 트리를 그대로
사용하고, 나머지는 `Provider.onEditCancellable`의 실제 완료 상태를 확인한다. 중단된 증분 파싱은
옛 트리를 남길 수 있으므로 tree 존재만으로 수락하지 않는다.

`Completion.mode()`는 cold/incremental/reused를, `basis()`는 사용한 기준 Request를 노출한다.
범위 소비자는 자신의 이전 표시 판과 basis가 일치함을 별도로 증명한다. 별도 내부 트리 캐시는 없다.
기준 트리를 보유한 대기도 워커에서 native 핸들을 해제한 뒤 메인에서 두 Snapshot과 Job을 회수한다.
Snapshot·서비스 allocator context는 최종 reap/deinit까지 살아 있어야 한다.

## 실행

```sh
mise exec -- zig build test-editor-snapshot-clone test-editor-parse-worker test-editor-parse-worker-native test-syntax -j2
mise exec -- zig build test-editor-snapshot-clone test-editor-parse-worker test-editor-parse-worker-native test-syntax -Doptimize=ReleaseFast -j2
python3 tools/editor-parse-incremental/review.py --output /tmp/new-incremental-review --deps /path/to/deps --cache /path/to/cache
python3 tools/editor-parse-incremental/run.py --output /tmp/new-incremental-measure --deps /path/to/deps --cache /path/to/cache --fixtures /path/to/five-fixtures
```

새 외부 output을 사용한다. 새 소스는 stage해 독립 사본/해시 원장에 포함한다. macOS 전용 서비스
검사와 production-mode 실행은 기본 test·macOS 게이트에 포함된다. Snapshot clone도 기존 editor
core 실행에 포함되며 별도 집중 target을 제공한다. 실측 target은 opt-in이다.

서비스 19개·Provider 100개와 Snapshot clone의 실제 실행을 확인한다. 서비스 검사는 한글 NFD·emoji·
CRLF·여러 곳의 편집·동일 본문·빈 문서 전환/복구·다른 문서/문법/언어·기준 조기 반환·대기 교체·기준 원문 복사 OOM을
포함한다. 전체 C 노드 종류·구조·필드·byte/point·오류 플래그를 cold 파싱과 비교한다. 내부 변경 플래그는
동일성 조건이 아니다. 원본 트리는 worker 편집 중에도 별도 cold 결과와 비교한다.

## 독립 결함 대조

`review.py`는 독립 소스 사본에서 다음 결함을 실제 컴파일하고 assertion 실패를 요구한다.

- 중단 후 남은 tree를 성공으로 처리
- 다른 grammar generation을 증분 기준으로 사용
- 실제 이전 Request 대신 새 Request를 basis로 기록
- UTF-8 byte 열을 잘못 계산
- 대기 기준 native 핸들을 메인에서 해제

정상 소스는 전후에 서비스 19개를 모두 통과해야 한다. 컴파일 오류는 탐지로 세지 않는다.
좌표 결함의 최초 주입은 전체 트리 비교만으로 탐지되지 않았다. 넓은 재파싱이 잘못된 편집 좌표를
덮을 수 있어서, CRLF·한글·emoji의 입력 point 계약을 별도로 확인하도록 보강했다.

## 실측 범위

`run.py`는 기존 고정 fixture `flat-3000.zig`, `flat-15000.zig`, `flat-50000.zig`, `real-build.zig`,
`real-host.swift`를 복사·해시 기록한다. 줄 시작 중간 위치에 공백을 20회 삽입한다. 초기 cold 준비는
표본에서 제외하며 매 입력의 Buffer 수정·Snapshot 준비도 시간 밖이다. 이전 결과는 두 모드 모두
보유하고, 새 결과를 받은 뒤 반납한다. 모드별 독립 프로세스의 순서를 교대한다.

각 fixture·모드별 3프로세스, 총 600입력의 submit 호출 비용과 submit 시작부터 완료 take까지 경과를
기록한다. 별도 200입력은 매번 전체 C 트리를 cold oracle과 비교하며 성능 표본에 섞지 않는다.
완료 경과에는 원문 복사·차이 계산·좌표·파싱·큐/스케줄링과 이전 퇴역 작업의 영향이 포함된다.
`take`를 `Thread.yield`와 함께 반복하는 시험용 대기이며 제품 완료 wake를 재현하지 않는다.
C parse만의 시간이나 GUI/HID 입력 지연이 아니다. 실측 중 소스가 바뀌면 결과 발행을 거절한다.
실행 바이너리·소스 원장·입력·원시 로그·JSON을 함께 보관한다.

## 한계

C 내부 malloc 실패 전수·race detector·실제 wake/IME·표시 설치·공유 뷰 수명·여러 문서의
대규모 공정성·RSS 예산은 검증하지 않는다. 기준 핸들 복사 실패 주입도 C allocator를 대체한 것이
아니다. 기존 `max_parse_bytes` 외의 새 예산이나 사용자 실패 UX를 추가하지 않는다.
최종 결과와 아티팩트 경로는 [실측 기록](results.md)을 따른다.

완료 통지의 선택적 hook과 재무장 순서는 [추가 계약](../editor-parse-notify/README.md)을 따른다. 실제 OS dispatch는 후속이다.
