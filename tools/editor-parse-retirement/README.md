# Provider 최종 해제의 워커 인계

제품을 변경하지 않는 독립 실험이다. [수명 검토안](../../docs/plans/editor-async-parse.md)의
트리 해제 후보를 확인하며, 제품 큐·문서 닫기·취소 서비스를 구현한 것이 아니다.

```sh
python3 tools/editor-parse-retirement/run.py --output /tmp/new-retirement --deps /path/to/deps --fixtures /path/to/pinned-fixtures
python3 tools/editor-parse-retirement/verify.py /tmp/new-retirement
python3 tools/editor-parse-retirement/review.py /tmp/new-retirement
python3 tools/editor-parse-retirement/memory.py /tmp/new-retirement --output /tmp/new-retirement-memory
```

새 외부 output, 실제 추출 dependencies, 기존 파싱 예산 실험의 다섯 fixture가 필요하다.
macOS·Zig 0.17·ReleaseFast 조건이다. `--cache`로 기존 Zig 캐시를 재사용할 수 있다.
수집기 준비는 기존 인계 실험과 같은 독립 소스 사본 방식이다.

15프로세스·300표본에서 `Provider.copyReady`, 메인 `Provider.deinit`, 워커의 마지막
`Provider.deinit`, 스레드 생성부터 join까지를 따로 기록한다. 원본을 먼저 해제하고 복사본의 root
종류·끝 byte와 실제 worker thread ID를 확인한다. 전체 트리 정확성 검사는 앞선 인계 도구의 별도 범위다.
매번 만드는 스레드는 이 실험의 조건이며 제품에 권장하는 상주 워커가 아니다.
`turnaround_ns`는 join을 포함하므로 UI 무차단을 증명하는 수치가 아니다.

트리 좌표 변조·잘못된 예상 좌표·다른 Provider·메인에서 실행·해제 누락을 각각 별도 프로세스에서
주입하고 assertion 실패를 요구한다. 누락된 해제는 검사 실패 시 테스트 메인이 회수한다.
잘못된 fault 실험이나 빌드 확인 표본을 정상 성능 집계에 포함하지 않는다.

메모리 실험은 별도 다섯 프로세스에서 `/usr/bin/time -l`로 전체 peak RSS를 잰다.
초기 파싱·20회 반복·스레드 생성 등을 포함한 프로세스 전체 값이며, 제품 큐 추가 메모리나
메인에서 해제하는 구현 대비 증감으로 해석하지 않는다.

실측 수치와 증거 범위는 [결과](results.md)에 기록한다.
