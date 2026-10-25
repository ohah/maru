# 괄호 범위 수집 실측

ReleaseFast의 동일한 보존 앱 문맥에서 `BracketIndex` 블록만 기존 main과 후보로
교환했다. 시작·중간·끝 각각 전후 3회 교차 실행하고, 별도 정확성 실행 1회씩을
추가했다. 오류 입력은 첫 `)`와 후속 공백으로 오류 트리가 계속 유지되는 것을 확인했다.
총 112프로세스·2,240편집이며 성능 1,680편집과 별도 정확성 560편집을 구분한다.

입력+프레임 CPU 구간이다. GUI/HID 지연이나 최신 제품 전체의 절대 성능이 아니다.
첫 입력을 포함한 모든 20표본을 보존했다. `normal`은 공백 삽입이며 오류 없는
트리를 뜻하지 않는다. Zig normal의 root는 오류가 없었고 Swift normal의 root는
전후 모든 성능 표본에서 오류가 있었다. 오류가 없는 하위 부모만 빠른 이동 대상이다. 다른 빌드/검사와 동일 머신을 사용했으며
실행 전후 프로세스 관측을 각 로그 옆에 남겼다. 작은 차이는 개선으로 일반화하지 않는다.

| 입력 / 위치 | p50 전→후 ms | p95 전→후 ms | 첫 입력 중앙값 전→후 ms |
|---|---:|---:|---:|
| error/flat-50000.zig/start | 41.248 → 41.034 | 49.722 → 49.772 | 49.722 → 49.031 |
| error/real-build.zig/start | 3.327 → 3.333 | 3.967 → 3.900 | 4.115 → 4.147 |
| normal/flat-3000.zig/end | 1.985 → 1.836 | 2.229 → 2.153 | 2.350 → 2.037 |
| normal/flat-3000.zig/middle | 2.690 → 2.597 | 2.998 → 2.910 | 2.998 → 2.801 |
| normal/flat-3000.zig/start | 2.509 → 2.446 | 2.736 → 3.683 | 2.767 → 2.816 |
| normal/flat-50000.zig/end | 42.080 → 39.510 | 52.728 → 47.729 | 44.452 → 47.609 |
| normal/flat-50000.zig/middle | 45.762 → 40.624 | 54.053 → 49.464 | 49.920 → 49.203 |
| normal/flat-50000.zig/start | 41.923 → 42.428 | 49.705 → 49.613 | 49.444 → 44.173 |
| normal/real-build.zig/end | 1.733 → 1.741 | 1.998 → 1.974 | 1.998 → 1.964 |
| normal/real-build.zig/middle | 7.968 → 7.930 | 9.470 → 8.690 | 8.108 → 8.164 |
| normal/real-build.zig/start | 3.288 → 3.288 | 3.769 → 3.739 | 3.796 → 3.684 |
| normal/real-host.swift/end | 5.955 → 5.803 | 7.140 → 6.348 | 6.538 → 6.369 |
| normal/real-host.swift/middle | 10.240 → 10.230 | 11.191 → 16.284 | 10.635 → 10.417 |
| normal/real-host.swift/start | 4.173 → 4.154 | 4.698 → 4.565 | 4.431 → 4.476 |

큰 Zig 문서 중간·끝은 개선됐지만 시작과 실제 소스의 일부 분포는 느려졌다.
원시 값의 불리한 표본도 그대로 남긴다. 모든 입력에서 부분 수집은 양쪽 모두 1회이고
준비된 공유 뷰의 재수집은 없다. 정확성 실행은 두 뷰의 본문·줄·접힘·잎·토큰·색·탐색을
각 편집 후 cold 결과와 비교했다. 저장 필드는 추가하지 않았다.

## 독립 native 구간

동일 트리·재사용 용량에서 순차 수집과 후보를 각각 6개 교차 배치로 측정했다.
Zig 10,000개 함수는 배치당 128회, Markdown은 4,000회다. 각 배치 ns/호출의 중앙값이며
개별 호출 p95로 해석하지 않는다. 측정 전 결과 잎과 cover를 대조했다.

| 입력 | 기존 μs/호출 | 후보 μs/호출 |
|---|---:|---:|
| zig-0 | 0.266 | 0.381 |
| zig-1 | 216.496 | 0.709 |
| zig-2 | 487.410 | 0.310 |
| markdown-0 | 0.257 | 0.407 |
| markdown-1 | 0.257 | 0.407 |
| markdown-2 | 0.256 | 0.407 |

Zig 시작은 추가 검증 비용이 있고, 중간·끝의 앞 형제 재귀는 크게 줄었다. Markdown의
세 행은 **같은** padding 복귀 지점의 반복이며 서로 다른 위치가 아니다. 실제 cursor 이동
실패와 오류 없는 section을 assert했다. 기존 약 0.257μs에서 후보 약 0.407μs로 늘어
복귀 비용을 확인했다. 오류 트리 보호 경로는 위 제품 오류 입력으로 따로 측정했다.

## 원시 근거와 재검증

모든 경로는 `/Users/yoonhb/.cache/maru-agent-artifacts/` 아래다.

- `bracket-range-measure-1/{order.json,error/order.json,summary.json,readback.json}`
- `bracket-range-measure-1/{baseline,candidate}/{prebuild.json,test}` 및 각 실행 로그/부하 관측
- `prepare-bracket-range-measure.py`, `run-bracket-range-measure.py`, `run-bracket-range-error-measure.py`
- `python3 readback-bracket-range-measure.py`: 이진·전체 source/build·각 로그 해시와 표본/정확성 수를 재검증
- `bracket-range-native-measure-1/{run-2.log,final-source.json,summary.json}`
- `prepare-range-native-measure.py`: native 구간 생성기. 최초 Timer API 컴파일 실패는 성능 근거에서 제외했다.

native 측정은 함수 미시 비용이며 전체 앱의 배수 개선을 뜻하지 않는다. API 내부는 여전히
선형 탐색일 수 있다. GUI·픽셀·RSS·실제 입력기·C allocator 실패 전수는 측정하지 않았다.
