# 파싱 완료 통지 기반

`Options.notify`는 context 포인터 없는 함수다. 워커가 결과를 게시하거나 native 퇴역 자료를 메인
회수 목록으로 옮긴 뒤 요청한다. `notification_pending`으로 합치며 callback은 큐 mutex 밖에서
실행한다. callback은 메인 작업을 예약만 하고 UI 처리를 기다리거나 Service를 역호출하지 않는다.

메인 처리 순서는 `beginDrain` → `reap` → `take` 반복이다. 재무장은 drain 앞에서 수행해야 처리
도중 완료된 자료의 다음 통지를 놓치지 않는다. 함수는 join까지, 이미 예약한 외부 전달의 저장소는
서비스와 독립적으로 보존한다. beginDrain의 반환값은 통지 플래그였다는 뜻이며, 큐가 비었다는 판정은 아니다. stopping 설정 후에는 새 통지를 예약하지 않고 남은 자료를 회수한다. 먼저 예약된 함수 호출은 join 중 끝날 수 있으므로 함수의 수명은 join까지 보장한다. 늦은 전달은 이전
Service/문서/창 포인터 대신 현재 소유자를 다시 찾아야 한다.

기존 기본 옵션은 통지를 설치하지 않는다. 이번 단계는 실제 OS main dispatch·AppSession registry·
표시 설치·실패 UX를 연결하지 않는다. production-mode probe도 원자적 신호를 기다리는 headless
실행이며 AppKit run loop나 GUI wake 검증이 아니다.

```sh
mise exec -- zig build test-editor-parse-worker test-editor-parse-worker-native -j2
mise exec -- zig build test-editor-parse-worker test-editor-parse-worker-native -Doptimize=ReleaseFast -j2
python3 tools/editor-parse-notify/review.py --output /tmp/new-parse-notify --deps /path/to/deps --cache /path/to/cache
```

서비스 판정자 19개 중 통지 판정은 mutex 밖의 워커 게시, 여러 문서의 통지 합치기, drain 도중
다음 완료 재무장, native 퇴역의 메인 회수 통지, 미전달 완료가 있는 종료를 검사한다. 합치기 검사는
세 번째 C 호출 장벽까지 워커를 진행시켜 앞선 callback 반환을 확인한 뒤 통지 수를 비교한다.
고정 시간 대기로 합치기 성공을 추정하지 않는다.

독립 사본에서 완료 통지 누락·퇴역 통지 누락·합치기 제거·재무장 누락·잠금 안 callback 실행을
실제로 컴파일하고 assertion 실패를 요구한다. 정상 소스는 전후에 통과해야 한다. 컴파일 실패는
탐지로 세지 않는다. 새 소스는 stage해 사본에 포함하며 새 외부 output과 기존 deps/cache를 사용한다.

실제 OS 전달·닫힌 창의 지연 callback·GUI/IME·공유 뷰·C malloc 실패 전수·race detector와
제품 지연/RSS 예산은 미검증이다. 사용자 파싱 실패 정책과 새 메모리 한도를 정하지 않는다.

실행 증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/parse-notify-main-review/`에 원본/변형 소스·실행 바이너리·로그·해시 원장으로 보존한다. 정상 전후 대조와 다섯 assertion 실패를 확인했다. 수집 기준 Git ID와 실제 작업 소스 inventory는 구분하며, 최종 소스도 inventory와 대조한다. 집중 ReleaseFast 및 production-mode 실행 로그는 `parse-notify-main-release.log`다.

후속 [메인 큐·문서 수명 연결](../editor-parse-runtime/README.md)은 실제 Apple 전달과 AppSession 파괴를 별도로 검증한다. 위 독립 서비스 검증의 범위를 GUI/IME 검증으로 확대하지 않는다.
