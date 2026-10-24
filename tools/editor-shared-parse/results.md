# 공유 입력의 완료 트리 재사용 측정

실제 선행 커밋 `cd9e60281b60d45aafa5dd1b0b126b5481c3ee2d`와 후보를 동일 도구·입력으로 번갈아 실행했다.
5파일 × 일반/공유 × 3반복 × 2버전, 총 60실행·1,200입력이다. 별도 매 입력 대조는 20실행·400입력이다.
첫 입력을 포함하며 실행 순서·원문·계측 소스·바이너리 해시와 호출 수를 검증했다.
백그라운드 검사와 동시에 실행한 제품 함수 계측이다. GUI/HID 입력 지연·RSS·메모리 압력의 증거는 아니다.

단위 ms. 각 열은 개별 전체 처리 시간 분포이며 중첩 구간의 중앙값을 합하지 않는다.

| 파일/입력 | 이전 p50 | 재사용 p50 | 이전 p95 | 재사용 p95 | 이전 최대 | 재사용 최대 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| flat-15000.zig/typing | 10.597 | 10.472 | 13.073 | 12.570 | 14.087 | 13.371 |
| flat-15000.zig/shared | 19.070 | 16.761 | 22.145 | 20.913 | 23.525 | 30.160 |
| flat-3000.zig/typing | 2.666 | 2.633 | 3.046 | 2.872 | 3.875 | 3.020 |
| flat-3000.zig/shared | 4.070 | 3.601 | 4.559 | 4.012 | 5.095 | 4.583 |
| flat-50000.zig/typing | 45.782 | 42.733 | 54.012 | 52.307 | 60.885 | 55.143 |
| flat-50000.zig/shared | 72.478 | 67.191 | 81.603 | 78.455 | 82.428 | 80.314 |
| real-build.zig/typing | 7.679 | 7.530 | 8.423 | 8.542 | 8.657 | 8.985 |
| real-build.zig/shared | 12.126 | 9.229 | 13.119 | 10.130 | 13.664 | 10.301 |
| real-host.swift/typing | 7.948 | 7.939 | 8.524 | 8.512 | 9.064 | 9.154 |
| real-host.swift/shared | 12.457 | 11.793 | 13.253 | 12.496 | 13.756 | 12.788 |

공유 입력은 실제 C 파싱 2→1회, 완료 트리 인계 0→1회였다. 일반 입력은 C 파싱 1회·인계 0회를 유지했다.
모든 공유 중앙값은 낮아졌지만 1만5천 줄 Zig의 최대는 증가했다. 단일 실행 환경의 수치로 모든 입력의 최악 지연 개선을 보장하지 않는다.
뷰별 구조 변경 범위 비교는 계속 필요하다. 5만 줄 공유의 C 범위 계산 중앙값은 13.160→15.885ms였다.
추가 Debug coordinator 대조에서는 공유 뷰 3개에 입력할 때 매번 인계 2회와 세 뷰의 색·심볼·접힘 결과를 확인했다. 비관련 문서 0개/128개에서 각 20입력의 전체 함수 중앙값은 2.077/2.182ms, 최대는 2.178/2.252ms였다. 이는 작은 문서의 Debug 참고값으로, 선행 제품 대비 개선율이나 임의의 뷰 수에 대한 상한 증거는 아니다.
재현: `python3 tools/editor-shared-parse/stress.py --source <독립 검증의 현재 제품 사본> --output <새 외부 디렉터리>`. 원본 사본은 실행 뒤 복구하며 `shared-parse-stress-final/`에 정확한 추가 소스·해시·로그를 보존했다.

원본 artifact: `/Users/yoonhb/.cache/maru-agent-artifacts/shared-parse-comparison/`.
분포 전체는 `summary.json`, 순서는 `run-order.json`·`verify-order.json`, 원문 기록은 각 variant 디렉터리에 보존한다.

```sh
python3 tools/editor-shared-parse/run.py --output <비교 디렉터리>/baseline --fixtures <고정 fixture 디렉터리> --deps <zig-pkg> --modes 1 --workloads typing,shared --repetitions 0 --baseline-ref cd9e60281b60d45aafa5dd1b0b126b5481c3ee2d
python3 tools/editor-shared-parse/run.py --output <비교 디렉터리>/cursor --fixtures <같은 fixture 디렉터리> --deps <같은 zig-pkg> --modes 1 --workloads typing,shared --repetitions 0
python3 tools/editor-shared-parse/compare.py <준비한 비교 디렉터리> --workloads typing,shared --repetitions 3
python3 tools/editor-shared-parse/compare.py <같은 디렉터리> --workloads typing,shared --prefix verify --verify-each-edit 1 --repetitions 1
python3 tools/editor-shared-parse/summarize.py <같은 디렉터리>
```
