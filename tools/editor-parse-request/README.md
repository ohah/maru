# 파싱 요청 수락 API의 실제 Zig 결함 대조

구현 API는 `session.editor.syntax.request.Gate`이며
[검토안](../../docs/plans/editor-async-parse.md)의 결과 수락 규칙을 소유한다.
워커·큐·문서 자원·UI는 소유하지 않는다. 실행 경로에는 아직 연결하지 않았다.

```sh
mise exec -- zig build test-editor-parse-request test-editor-syntax-stamp -j2
python3 tools/editor-parse-request/review.py --output /tmp/new-request-gate --deps /path/to/deps --cache /path/to/cache
```

첫 명령은 `Gate` 판정 8개와 import 판정자 28개, 기존 입력 증명 판정자 30개를 각각 실행한다.
새 gate target은 기본 `zig build test`에도 연결돼 있다. 두 target의 import 판정자는 중복되므로
실행 개수의 합을 고유 기능 테스트 수로 해석하지 않는다.

결함 대조는 실제 소스 사본에서 문서 generation 검사 누락, serial 검사 누락, 준비 전 수락,
중복 수락, 번호 고갈 시 이전 판 유지의 다섯 변형을 각각 컴파일·실행한다.
컴파일 실패는 결함 탐지로 세지 않는다. 정상 소스는 전후에 전체 집중 target을 통과해야 한다.
원본 worktree를 수정하지 않고 독립 사본을 마지막에 원상 복구해 모든 제품 입력 해시를 대조한다.
새 파일을 실험 사본에 포함하려면 Git에 stage돼 있어야 한다.

보존 위치는 `/Users/yoonhb/.cache/maru-agent-artifacts/parse-request-gate-1/`이다.
각 정상·결함 source, 실제 실행 바이너리, 로그, runner와 제품 입력 해시·명령을 보존했다.
전체 product commit과 아직 커밋 전인 수집 시점의 source inventory는 구분한다.

이 검증은 수락 API의 실제 Zig 판정이다. 실제 파싱 완료·취소·할당 실패·wake·참조 반환·
IME·제품 UX 검증으로 일반화하지 않는다. 준비 실패는 `begin` 후 `abandon`을 부르는 순서로 대조한다.
API 자체는 할당하지 않으며 실제 OOM을 주입한 것이 아니다.
