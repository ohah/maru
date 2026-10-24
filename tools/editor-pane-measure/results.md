# pane 프레임 비용 귀속 결과

제품 최적화가 아니라 같은 소스 사본의 중첩 함수 계측이다. 공유 완료 트리 재사용 후보 `007c93058` 기준이며, 후속 `e2fbaaf76`의 함수 수/줄 수 설명 수정은 제품 코드를 바꾸지 않았다.
5파일 × 일반/공유 × 3반복 = 성능 30실행·600입력, 별도 매 입력 독립 대조 10실행·200입력이다. 첫 입력을 포함한다. 백그라운드 부하는 통제하지 않았고 GUI/HID·present·RSS 측정은 아니다.

이 표는 schema 2의 17구간·원본/계측 15파일 자료다. 초기 schema 1의 14구간·14파일 자료는 `pane-frame-attribution-probe/`에 별도로 보존한다. 다른 실행의 수치로 연속 개선량을 주장하지 않는다.
합성 파일 이름의 N은 함수 수다. 각 함수가 네 줄이며 줄 인덱스는 마지막 빈 줄도 센다.

| 원문 | 바이트 | 줄바꿈 수 |
| --- | ---: | ---: |
| flat-15000.zig | 922,780 | 60,000 |
| flat-3000.zig | 180,780 | 12,000 |
| flat-50000.zig | 3,127,780 | 200,000 |
| real-build.zig | 744,535 | 11,561 |
| real-host.swift | 1,169,769 | 18,311 |

단위 ms. 각 구간의 중앙값은 별도로 계산하며 중첩 값을 더하거나 중앙값끼리 빼서 잔여 비중을 만들지 않는다.

| 파일/입력 | 전체 p50 | pane p50 | sticky p50 | 요약 p50 | 요약 C 비교 p50 | 조상 조회 p50 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| flat-15000.zig/typing | 11.120 | 4.318 | 2.468 | 2.442 | 2.124 | 0.015 |
| flat-15000.zig/shared | 16.854 | 7.033 | 4.392 | 4.352 | 3.969 | 0.030 |
| flat-3000.zig/typing | 2.658 | 1.526 | 0.404 | 0.385 | 0.334 | 0.012 |
| flat-3000.zig/shared | 3.655 | 1.980 | 0.712 | 0.683 | 0.635 | 0.024 |
| flat-50000.zig/typing | 49.060 | 14.440 | 10.595 | 10.560 | 8.647 | 0.020 |
| flat-50000.zig/shared | 71.138 | 25.465 | 18.785 | 18.729 | 17.169 | 0.037 |
| real-build.zig/typing | 7.822 | 4.343 | 0.854 | 0.828 | 0.476 | 0.015 |
| real-build.zig/shared | 9.418 | 5.201 | 1.380 | 1.315 | 0.894 | 0.038 |
| real-host.swift/typing | 8.281 | 5.672 | 1.694 | 0.431 | 0.376 | 0.071 |
| real-host.swift/shared | 11.845 | 8.466 | 3.272 | 0.831 | 0.745 | 0.139 |

| 파일/입력 | pane p95 | pane 최대 | sticky p95 | sticky 최대 | 요약 C 비교 p95 | 요약 C 비교 최대 |
| --- | ---: | ---: | ---: | ---: | ---: | ---: |
| flat-15000.zig/typing | 5.413 | 6.556 | 3.572 | 4.690 | 2.962 | 3.140 |
| flat-15000.zig/shared | 8.528 | 8.913 | 5.894 | 6.250 | 5.342 | 5.819 |
| flat-3000.zig/typing | 1.647 | 1.925 | 0.485 | 0.784 | 0.408 | 0.425 |
| flat-3000.zig/shared | 2.317 | 3.060 | 0.957 | 1.729 | 0.774 | 0.888 |
| flat-50000.zig/typing | 16.654 | 17.797 | 12.825 | 13.840 | 10.652 | 10.935 |
| flat-50000.zig/shared | 28.638 | 30.903 | 22.123 | 24.335 | 19.769 | 22.825 |
| real-build.zig/typing | 4.620 | 5.090 | 1.164 | 1.529 | 0.623 | 0.714 |
| real-build.zig/shared | 5.721 | 6.004 | 1.658 | 1.890 | 1.109 | 1.315 |
| real-host.swift/typing | 6.080 | 10.493 | 1.874 | 4.820 | 0.465 | 3.417 |
| real-host.swift/shared | 8.801 | 9.135 | 3.416 | 3.581 | 0.851 | 0.891 |

큰 합성 Zig 공유 입력에서 고정 머리줄 p50 18.785ms 안의 심볼 요약은 18.729ms이며, 포함된 C 변경 범위 비교는 17.169ms였다. 조상 조회는 0.037ms다. 공유 입력의 요약·C 비교·조상 조회는 각각 뷰별 한 번, 합계 두 번 실행된 것을 매 입력 확인했다.
다음 개선 후보는 `Summary.hasSymbols`의 두 트리 비교에 같은 Provider가 이미 계산한 변경 범위를 재사용하는 것이다. 이전 세대·편집 수·실제 이전 트리의 일치를 증명해야 하며, 이 계측만으로 제품 변경의 안전성·개선량을 주장하지 않는다. 늦은 조회·다중 편집·전체 재설정·보관 한도 초과는 따로 대조해야 한다.

증거는 `/Users/yoonhb/.cache/maru-agent-artifacts/pane-frame-attribution-detail/`의 원본/계측 소스, 바이너리 해시, 입력 manifest, 원문 로그, `pane-summary.json`에 보존한다.
`run-order.stdout`·`verify-order.stdout`은 실제 실행 뒤 출력된 원본이다. 그 원본에서 실행 순서 JSON을 만들었으며 집계 때 둘의 일치와 기대 실행 전부를 확인한다. 미실행 계획을 실행 증거로 사용하지 않는다.
원문 표본·실행 순서·호출/시간 포함 관계·상위 제품/oracle·원본/계측/schema/실행 파일·CLI의 다섯 독립 실패 가설을 공격했고 앞뒤 원본 대조군이 유지됐다. 세 도구 파일 해시는 `pane-frame-detail-review-immutable.json`에 묶었다.

```sh
python3 tools/editor-pane-measure/run.py --output <새 외부 디렉터리> --fixtures <고정 입력 디렉터리> --deps <zig-pkg> --modes 1 --workloads typing,shared --repetitions 0
python3 tools/editor-pane-measure/run.py --output <같은 디렉터리> --deps <zig-pkg> --modes 1 --workloads typing,shared --resume --run-only --repetitions 3
python3 tools/editor-pane-measure/run.py --output <같은 디렉터리> --deps <zig-pkg> --modes 1 --workloads typing,shared --resume --run-only --repetitions 1 --prefix verify --verify-each-edit 1
python3 tools/editor-pane-measure/summarize.py <같은 디렉터리>
python3 tools/editor-pane-measure/verify.py <같은 디렉터리> --receipt <새 검증 결과.json>
```

후속 [변경 범위 재사용 측정](../editor-sticky-changes/results.md)은 schema 3으로 실제 C 호출·성공 차용·별도 전체 sticky oracle을 구분한다. 기존 schema 1/2 자료와 계약을 유지하며, 이 문서의 기존 분포를 후보 개선량으로 해석하지 않는다.
