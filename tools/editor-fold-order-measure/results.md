# 접힘 후보 정렬 재사용의 전후 비교

기존 main `a5b7b22ca` 기반의 두 사본은 `src/syntax/folds.zig` 하나만 다르다.
전체 소스/빌드 1,288개 목록, 입력·바이너리 해시를 빌드 전과 실행 후 대조했다.
Zig 0.17.0 ReleaseFast와 테스트 allocator를 사용했으며 반복마다 두 구현의 실행 순서를 뒤집었다.

전체 편집·다음 프레임 비교는 3반복 × 5입력 × 8상황 × 두 구현의 240개 프로세스,
3,090편집이다. 구간 비교는 3반복 × 5입력 × 일반/공유 × 두 구현의 60개 프로세스,
1,200편집이다. 매 편집 전체 접힘 oracle을 켰고 결과 불일치는 모두 0이었다.
구간 비교는 기존 FRAME·STORAGE·PROVIDER·PANE·LOWERING·INNER·full sticky 대조와
부모/자식 시간·호출 수 검증을 유지했다. 각 구간 셀은 60표본이며 shared는 두 뷰 합계다.

모든 열 개 구간 셀에서 조회 중앙값이 감소했다. 대형 Zig 일반 조회는 0.820→0.507ms,
공유 조회는 1.595→0.977ms였다. 이 구간의 약 38%·39% 감소를 전체 입력 개선율로 쓰지 않는다.
전체 편집 시간 차이는 작고 일부 중앙값은 증가했다. 15,000함수의 느린 입력은
9.615→10.125ms였다. 동시 컴파일을 관측했으므로 전체 지연은 탐색 자료다.

## 의미 검증

최종 main `fd953386b` 기반 구현의 정렬·캐시·변경 범위·좌표 게이트는 Debug·ReleaseFast
각각 25개 테스트를 통과했다. 실제 정렬 함수 추출 사본에 비교 방향 반전, 원소 이동 누락,
추가 후보 처리 누락, 큰 추가분의 전체 정렬 누락, 끝 위치 훼손을 주입했다. 다섯 의미 결함을
모두 거절했고 각 전후 정상 대조와 소스 불변을 확인했다. 4,096개 배열과 200개 삭제/좌표
이동 주기이며 native·제품 대조를 대체하지 않는다.
추가 검토에서는 비교 함수와 oracle의 공통 오류 가능성을 보강했다. 고정 정답이 끝 위치의
비교 방향 반전을 거절하고 정상 전후 대조도 통과했다. 제품 Debug·ReleaseFast의 정렬
게이트도 보강 후 각각 4개 테스트를 다시 통과했다. 원시 자료는 `fold-order-golden-adversarial/`에 있다.

native 첫 경로 검사는 구조 범위가 생기는 숫자 삽입을 잘못 골라 실패했다. 결과는 전체
재계산과 일치했다. 함수명 변경과 구조 추가를 분리해 빈 범위와 구조 범위 양쪽을 확인했다.
보조 도구의 함수명 치환 충돌과 Zig 실패 요약 판정 오류도 수정하고 실패 로그를 보존했다.

## 재현과 증거

기존 [제품 비교](../editor-fold-product/run.py)와 [구간 계측](../editor-fold-promotion-measure/run.py)
도구를 사용한다. 두 판의 외부 사본을 같은 고정 fixture로 `--repetitions 0` 준비하고,
기록된 바이너리를 번갈아 실행한다. `MARU_EW2_FILE`, `MARU_EW2_WORKLOAD`,
`MARU_EW2_VERIFY_EACH_EDIT=1`을 설정하고 `--maru-expect-tests=5 --maru-expect-passed=5`를
전달한다. 구간 비교는 기존 `summarize.py`의 `rows`로 부모/자식 시간·호출 수도 검사한다.
별도 범용 비교 CLI는 추가하지 않는다.

로컬 원시 증거 루트는 `/Users/yoonhb/.cache/maru-agent-artifacts/`다. 저장소에는 집계·방법을
기록하며 원시 로그·바이너리는 외부 경로에 보존했다.

| 경로 | 내용 |
|---|---|
| `fold-order-product-1/` | prebuild, binary, pair-source-proof, paired-order, paired-summary, postrun-proof와 240개 로그 |
| `fold-order-scoped-1/` | 기존 기준 바이너리 참조, 전체 소스 목록, 정렬만 바꾼 사본, 60개 로그와 order/summary |
| `fold-order-adversarial-3/receipt.json` | 다섯 의미 결함과 각 전후 정상 대조의 15개 실행·해시 |
| `fold-order-product-main-debug.log` | 최종 main 기반 Debug 25개 테스트 |
| `fold-order-product-main-releasefast.log` | 최종 main 기반 ReleaseFast 25개 테스트 |

## 한계

계측·배경 부하가 포함된다. 실제 AppKit/HID·Metal present·RSS를 측정하지 않았다.
모든 언어·입력의 최대 이득을 보장하지 않으며 접힘 설치·열 폭·스크롤을 생략하지 않았다.
실측 기반은 `a5b7b22ca`이고 최종 구현은 이름 변경 IME가 추가된 `fd953386b`로,
최종 판에서는 native 검사를 다시 했다. 이 구현의 PR CI·머지는 아직 완료하지 않았다.
`flat-50000.zig`의 숫자는 함수 수이고 LF 개행은 200,000개다.

## 전체 분포

시간 단위는 ms이며 각 셀은 중앙값 / p95 / 최댓값이다. 포함된 구간 시간을 서로 더하지 않는다.

| Fixture | Bytes | LF | SHA-256 |
|---|---:|---:|---|
| flat-15000.zig | 922780 | 60000 | `0f0ef90b549c133c0ab4eaec1687fcaf7f7dcfc795934057fa06e415f2122efa` |
| flat-3000.zig | 180780 | 12000 | `b69dc1621343607e723a5dd499e0454b1d23828fe55d846f43bcf5588fbc89a7` |
| flat-50000.zig | 3127780 | 200000 | `09c28a6aefec900b9938d2ca8605b07f58fca90503afccedf60de01384cb015c` |
| real-build.zig | 744535 | 11561 | `8b4b0da83a30d1032f87c09a43d23a2ad73bf74e95a025e6e373d20167c6e570` |
| real-host.swift | 1169769 | 18311 | `d2335fd637f1d97bc41ee80ea8e1fa597c88769bc2ac1a8bf2df4affd97b57ba` |

| Fixture | Work | Full edit baseline | Full edit candidate |
|---|---|---:|---:|
| flat-15000.zig | typing | 10.688 / 11.969 / 14.699 | 10.544 / 12.181 / 13.311 |
| flat-15000.zig | slow | 9.615 / 12.326 / 12.326 | 10.125 / 15.907 / 15.907 |
| flat-15000.zig | structure | 10.471 / 12.509 / 13.235 | 10.679 / 14.040 / 15.176 |
| flat-15000.zig | paste | 20.204 / 20.522 / 20.522 | 19.828 / 23.049 / 23.049 |
| flat-15000.zig | undo | 9.860 / 12.049 / 12.049 | 9.753 / 15.416 / 15.416 |
| flat-15000.zig | shared | 15.188 / 17.627 / 19.000 | 15.369 / 18.627 / 21.508 |
| flat-15000.zig | folded | 10.480 / 12.429 / 15.539 | 10.281 / 12.377 / 14.632 |
| flat-15000.zig | command | 12.493 / 14.734 / 15.361 | 12.656 / 14.943 / 21.120 |
| flat-3000.zig | typing | 2.478 / 2.700 / 3.080 | 2.451 / 2.747 / 6.721 |
| flat-3000.zig | slow | 2.568 / 4.531 / 4.531 | 2.525 / 2.811 / 2.811 |
| flat-3000.zig | structure | 2.655 / 2.932 / 3.151 | 2.634 / 2.851 / 2.953 |
| flat-3000.zig | paste | 8.100 / 8.111 / 8.111 | 7.876 / 8.608 / 8.608 |
| flat-3000.zig | undo | 2.523 / 3.548 / 3.548 | 2.443 / 2.655 / 2.655 |
| flat-3000.zig | shared | 3.271 / 3.681 / 3.888 | 3.143 / 4.188 / 5.810 |
| flat-3000.zig | folded | 2.464 / 2.668 / 3.009 | 2.465 / 2.716 / 2.875 |
| flat-3000.zig | command | 4.825 / 5.394 / 6.266 | 4.746 / 5.008 / 5.167 |
| flat-50000.zig | typing | 25.438 / 28.375 / 32.180 | 25.304 / 27.030 / 32.306 |
| flat-50000.zig | slow | 25.954 / 31.169 / 31.169 | 25.952 / 35.219 / 35.219 |
| flat-50000.zig | structure | 25.460 / 33.129 / 33.265 | 25.708 / 30.739 / 33.953 |
| flat-50000.zig | paste | 58.401 / 58.435 / 58.435 | 54.526 / 55.677 / 55.677 |
| flat-50000.zig | undo | 24.839 / 51.836 / 51.836 | 24.875 / 54.072 / 54.072 |
| flat-50000.zig | shared | 36.646 / 40.488 / 47.801 | 36.239 / 42.357 / 45.054 |
| flat-50000.zig | folded | 25.425 / 27.085 / 32.213 | 25.310 / 26.934 / 33.283 |
| flat-50000.zig | command | 27.893 / 31.290 / 112.924 | 27.636 / 28.739 / 34.815 |
| real-build.zig | typing | 7.544 / 8.088 / 11.424 | 7.626 / 8.081 / 8.587 |
| real-build.zig | slow | 7.747 / 8.043 / 8.043 | 7.684 / 7.999 / 7.999 |
| real-build.zig | structure | 7.747 / 8.326 / 8.558 | 7.771 / 8.015 / 8.155 |
| real-build.zig | paste | 12.832 / 13.428 / 13.428 | 12.741 / 12.851 / 12.851 |
| real-build.zig | undo | 7.751 / 9.533 / 9.533 | 7.665 / 14.497 / 14.497 |
| real-build.zig | shared | 8.988 / 9.940 / 11.798 | 9.117 / 10.138 / 10.405 |
| real-build.zig | folded | 7.847 / 8.265 / 8.505 | 7.791 / 8.199 / 13.274 |
| real-build.zig | command | 87.044 / 89.358 / 95.791 | 87.395 / 91.651 / 96.324 |
| real-host.swift | typing | 7.886 / 10.067 / 12.904 | 7.873 / 9.136 / 11.692 |
| real-host.swift | slow | 7.950 / 10.251 / 10.251 | 7.916 / 10.520 / 10.520 |
| real-host.swift | structure | 9.659 / 12.260 / 13.605 | 8.750 / 12.052 / 13.044 |
| real-host.swift | paste | 20.109 / 20.178 / 20.178 | 19.335 / 20.002 / 20.002 |
| real-host.swift | undo | 7.709 / 10.451 / 10.451 | 7.760 / 10.315 / 10.315 |
| real-host.swift | shared | 11.430 / 13.484 / 15.723 | 11.248 / 14.489 / 16.245 |
| real-host.swift | folded | 6.070 / 7.239 / 8.871 | 6.043 / 7.786 / 8.388 |
| real-host.swift | command | 43.703 / 46.555 / 47.608 | 43.389 / 46.226 / 49.404 |

| Fixture | Work | Stage | Baseline | Candidate |
|---|---|---|---:|---:|
| flat-15000.zig | typing | promote | 0.368 / 0.397 / 2.097 | 0.256 / 0.279 / 0.297 |
| flat-15000.zig | typing | query | 0.265 / 0.288 / 1.997 | 0.153 / 0.167 / 0.198 |
| flat-15000.zig | typing | ranges | 0.025 / 0.057 / 0.058 | 0.024 / 0.046 / 0.057 |
| flat-15000.zig | typing | install | 0.071 / 0.075 / 0.104 | 0.071 / 0.073 / 0.075 |
| flat-15000.zig | typing | visible | 0.047 / 0.048 / 0.058 | 0.047 / 0.048 / 0.048 |
| flat-15000.zig | typing | finish | 0.016 / 0.016 / 0.017 | 0.016 / 0.016 / 0.020 |
| flat-15000.zig | shared | promote | 0.746 / 0.783 / 0.802 | 0.536 / 0.579 / 0.639 |
| flat-15000.zig | shared | query | 0.518 / 0.547 / 0.560 | 0.304 / 0.349 / 0.399 |
| flat-15000.zig | shared | ranges | 0.048 / 0.056 / 0.092 | 0.049 / 0.057 / 0.093 |
| flat-15000.zig | shared | install | 0.174 / 0.182 / 0.193 | 0.176 / 0.180 / 0.186 |
| flat-15000.zig | shared | visible | 0.094 / 0.095 / 0.110 | 0.094 / 0.095 / 0.097 |
| flat-15000.zig | shared | finish | 0.032 / 0.033 / 0.037 | 0.032 / 0.033 / 0.036 |
| flat-3000.zig | typing | promote | 0.084 / 0.092 / 0.134 | 0.061 / 0.070 / 0.076 |
| flat-3000.zig | typing | query | 0.059 / 0.067 / 0.108 | 0.036 / 0.044 / 0.049 |
| flat-3000.zig | typing | ranges | 0.005 / 0.005 / 0.006 | 0.005 / 0.006 / 0.006 |
| flat-3000.zig | typing | install | 0.019 / 0.020 / 0.021 | 0.019 / 0.021 / 0.023 |
| flat-3000.zig | typing | visible | 0.009 / 0.010 / 0.010 | 0.009 / 0.010 / 0.012 |
| flat-3000.zig | typing | finish | 0.003 / 0.004 / 0.004 | 0.003 / 0.004 / 0.004 |
| flat-3000.zig | shared | promote | 0.176 / 0.199 / 0.400 | 0.128 / 0.137 / 0.144 |
| flat-3000.zig | shared | query | 0.120 / 0.129 / 0.290 | 0.073 / 0.079 / 0.084 |
| flat-3000.zig | shared | ranges | 0.011 / 0.012 / 0.023 | 0.011 / 0.012 / 0.019 |
| flat-3000.zig | shared | install | 0.043 / 0.058 / 0.089 | 0.042 / 0.045 / 0.046 |
| flat-3000.zig | shared | visible | 0.019 / 0.019 / 0.035 | 0.019 / 0.019 / 0.019 |
| flat-3000.zig | shared | finish | 0.007 / 0.007 / 0.013 | 0.007 / 0.007 / 0.007 |
| flat-50000.zig | typing | promote | 1.133 / 1.186 / 1.453 | 0.812 / 0.870 / 0.906 |
| flat-50000.zig | typing | query | 0.820 / 0.883 / 1.144 | 0.507 / 0.566 / 0.603 |
| flat-50000.zig | typing | ranges | 0.077 / 0.085 / 0.125 | 0.076 / 0.082 / 0.087 |
| flat-50000.zig | typing | install | 0.223 / 0.229 / 0.248 | 0.222 / 0.227 / 0.231 |
| flat-50000.zig | typing | visible | 0.156 / 0.157 / 0.157 | 0.156 / 0.157 / 0.159 |
| flat-50000.zig | typing | finish | 0.053 / 0.054 / 0.054 | 0.053 / 0.053 / 0.054 |
| flat-50000.zig | shared | promote | 2.320 / 2.381 / 2.811 | 1.683 / 1.735 / 1.754 |
| flat-50000.zig | shared | query | 1.595 / 1.658 / 1.834 | 0.977 / 1.005 / 1.022 |
| flat-50000.zig | shared | ranges | 0.158 / 0.171 / 0.191 | 0.155 / 0.169 / 0.174 |
| flat-50000.zig | shared | install | 0.551 / 0.571 / 0.807 | 0.543 / 0.571 / 0.606 |
| flat-50000.zig | shared | visible | 0.312 / 0.316 / 0.454 | 0.312 / 0.316 / 0.318 |
| flat-50000.zig | shared | finish | 0.106 / 0.107 / 0.220 | 0.106 / 0.107 / 0.110 |
| real-build.zig | typing | promote | 0.123 / 0.134 / 0.149 | 0.108 / 0.118 / 0.133 |
| real-build.zig | typing | query | 0.093 / 0.102 / 0.115 | 0.080 / 0.087 / 0.091 |
| real-build.zig | typing | ranges | 0.007 / 0.008 / 0.017 | 0.006 / 0.007 / 0.007 |
| real-build.zig | typing | install | 0.021 / 0.022 / 0.025 | 0.020 / 0.022 / 0.038 |
| real-build.zig | typing | visible | 0.013 / 0.015 / 0.015 | 0.013 / 0.014 / 0.017 |
| real-build.zig | typing | finish | 0.003 / 0.004 / 0.004 | 0.003 / 0.004 / 0.004 |
| real-build.zig | shared | promote | 0.229 / 0.257 / 0.272 | 0.211 / 0.235 / 0.463 |
| real-build.zig | shared | query | 0.175 / 0.194 / 0.199 | 0.155 / 0.169 / 0.180 |
| real-build.zig | shared | ranges | 0.010 / 0.013 / 0.013 | 0.010 / 0.013 / 0.014 |
| real-build.zig | shared | install | 0.041 / 0.047 / 0.058 | 0.042 / 0.047 / 0.055 |
| real-build.zig | shared | visible | 0.023 / 0.026 / 0.027 | 0.023 / 0.026 / 0.027 |
| real-build.zig | shared | finish | 0.006 / 0.007 / 0.010 | 0.007 / 0.007 / 0.007 |
| real-host.swift | typing | promote | 0.224 / 0.233 / 0.242 | 0.207 / 0.214 / 0.217 |
| real-host.swift | typing | query | 0.167 / 0.171 / 0.176 | 0.150 / 0.155 / 0.157 |
| real-host.swift | typing | ranges | 0.017 / 0.018 / 0.025 | 0.017 / 0.018 / 0.026 |
| real-host.swift | typing | install | 0.039 / 0.040 / 0.057 | 0.038 / 0.040 / 0.041 |
| real-host.swift | typing | visible | 0.029 / 0.029 / 0.029 | 0.027 / 0.029 / 0.029 |
| real-host.swift | typing | finish | 0.005 / 0.005 / 0.005 | 0.005 / 0.005 / 0.006 |
| real-host.swift | shared | promote | 0.449 / 0.470 / 0.480 | 0.423 / 0.452 / 0.600 |
| real-host.swift | shared | query | 0.323 / 0.340 / 0.349 | 0.295 / 0.312 / 0.354 |
| real-host.swift | shared | ranges | 0.034 / 0.036 / 0.036 | 0.034 / 0.037 / 0.053 |
| real-host.swift | shared | install | 0.089 / 0.093 / 0.098 | 0.089 / 0.096 / 0.264 |
| real-host.swift | shared | visible | 0.052 / 0.056 / 0.057 | 0.052 / 0.056 / 0.056 |
| real-host.swift | shared | finish | 0.010 / 0.011 / 0.011 | 0.010 / 0.011 / 0.186 |

SHA-256:

- `fold-order-product-1/paired-order.json`: `17d916d47d58354d96c9e3d4352efde821a22c788373678e19547051636e3d3e`
- `fold-order-product-1/postrun-proof.json`: `83af1c3360fea60afb2d15f7bdb6e06e3dee4d4ee9bf6a9290dc75a8054b82d2`
- `fold-order-scoped-1/order.json`: `1f766e748cda15c8b5d11e55d89af398a19f34b0f224ef09f7e0f0301ecfe2d8`
- `fold-order-scoped-1/summary.json`: `fb9a3323946a9f16d912a99b4d757da575264dc487e5a3b7b33e5f749b9d2643`
- `fold-order-adversarial-3/receipt.json`: `18f6855ab773e64053e82e26d01f47115762f1502a9b61f6693f5d2adbacf5b5`
