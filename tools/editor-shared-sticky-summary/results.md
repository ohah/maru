# 공유 분할 고정 머리줄 요약 복사 실측

## 범위와 방법

동일한 계측 사본에서 `Summary.copyReady`와 `Provider.copyReady`의 요약 전달 두 변경만
적용해 비교했다. 실제 브랜치의 두 변경과 사본의 해시 일치를 별도로 확인했다. 계측은
제품 구문·분할·프레임 경로를 실행하지만 GUI/HID·Metal present·RSS를 측정하지 않는다.
원본은 입력 두 번으로 준비한 뒤 원문을 복원한다. 분할 준비부터 첫 입력까지 포함한다.

5개 파일에서 기준/후보 실행 순서를 번갈아 3번 반복했다. 성능 실행 30개·600편집과
매 입력 전체 결과 대조 10개·200편집을 분리했다. 준비 시간 표는 실행별 중앙값이고,
입력 p50/p95는 파일·변형별 실제 입력 60개를 합친 값이다. 준비 p95는 표본 3개라 최댓값과
같다. 적은 반복과 공유 개발 머신의 결과를 모든 환경의 성능 보장으로 해석하지 않는다.

모든 실행에서 첫 입력을 포함한 FRAME·STORAGE·복사 계보 기록 20개, 캐시 준비 완료,
준비 구간 native parse 시간 0, 전체 결과 불일치 0·지연 0을 확인했다. native parse 시간
계측을 C 파싱 호출 횟수의 직접 계측으로 표현하지 않는다. 후보의 새 뷰 전체 요약 재순회는
모든 파일에서 0개였고 원본 뷰의 추가 재순회도 양쪽 모두 0개였다.

원시 실행 40개를 다시 읽어 기록 중복·누락·해시·타이밍·모든 입력을 검사했다. 첫 입력 누락,
잘못된 재순회 횟수, 부모 구간 초과 시간, 원본 뷰 계측 누락, 정확성 검사 비활성화로 손상시킨
로그는 모두 검출했고 정상 대조는 통과했다. 이는 제품 소스에 결함을 주입한 5건과 별개다.

## 준비 시간과 첫 입력

단위는 ms다. 준비+첫 입력은 같은 실행의 두 값을 더한 뒤 중앙값을 구하며, 서로 다른
중앙값을 더하지 않는다. 첫 입력 자체는 작은 증가가 관측된 파일도 있으므로 개선으로
표현하지 않는다. 후속 입력의 작은 증가 표본은 별도 반복으로 확인한다.

| File | Ready before | Ready after | Ready+first before | Ready+first after | Rebuilt nodes before | After |
|---|---:|---:|---:|---:|---:|---:|
| flat-15000.zig | 61.080 | 23.353 | 75.151 | 37.563 | 375001 | 0 |
| flat-3000.zig | 14.230 | 7.244 | 17.332 | 10.370 | 75001 | 0 |
| flat-50000.zig | 202.431 | 72.449 | 260.669 | 131.054 | 1250001 | 0 |
| real-build.zig | 26.354 | 19.479 | 34.883 | 28.059 | 124915 | 0 |
| real-host.swift | 48.885 | 35.780 | 60.143 | 47.022 | 200850 | 0 |

| File | First before | First after | Input p50 before | Input p50 after | Input p95 before | Input p95 after |
|---|---:|---:|---:|---:|---:|---:|
| flat-15000.zig | 14.071 | 14.325 | 13.295 | 13.229 | 14.313 | 14.616 |
| flat-3000.zig | 3.112 | 3.124 | 2.695 | 2.727 | 2.815 | 3.124 |
| flat-50000.zig | 57.576 | 58.604 | 52.198 | 51.553 | 61.941 | 60.109 |
| real-build.zig | 8.530 | 8.593 | 8.440 | 8.779 | 9.015 | 9.330 |
| real-host.swift | 11.258 | 11.338 | 11.116 | 10.987 | 11.624 | 11.510 |

## 후속 입력 반복 대조

후속 입력의 작은 증가가 관측된 두 파일은 동일 실행 파일로 파일별 10쌍씩 다시 실행했다.
추가 성능 실행 40개·800편집이며, 정확성 대조를 추가한 실행으로 세지 않는다. real-build의
입력 p50 증가는 반복되지 않았지만 대형 Zig의 p95는 약 0.42ms 증가했다. 준비 개선과
후속 입력의 작은 변동을 분리하며 모든 입력이 빨라졌다고 주장하지 않는다.

| File | Ready before | Ready after | Input p50 before | Input p50 after | Input p95 before | Input p95 after |
|---|---:|---:|---:|---:|---:|---:|
| flat-50000.zig | 203.233 | 70.929 | 50.847 | 49.318 | 57.866 | 58.285 |
| real-build.zig | 26.666 | 19.653 | 8.506 | 8.479 | 8.899 | 8.780 |

## 보존한 실행 파일과 재검사

| Variant | SHA-256 |
|---|---|
| baseline | `f4981eaa4fd08d2c964108347e2ec6856ab691f3c23cc2ac607217e3536b4343` |
| candidate | `386ffc84c62bac5e508f8022222290c98b887448951ad6511791bfa059c9d178` |

원시 자료의 기준 경로는 `/Users/yoonhb/.cache/maru-agent-artifacts`다.
`shared-sticky-summary-measure-1`에 첫 교차 측정, `shared-sticky-summary-input-repeat-1`에
후속 반복, `split-ready-attribution-8`에 원인 귀속을 보존한다. `binaries.json`·`prebuild.json`·
`inputs.json`·`order.json`·`canonical-method-proof.json`·`readback-adversarial.json`으로
실행 파일·소스·입력과 결과의 관계를 확인한다. 일부 파일은 첫 교차 측정 디렉터리에만 있다.

기준 경로의 `run-shared-sticky-measure.py`와 `run-shared-sticky-input-repeat.py`가 실행
순서·환경·검증·집계를 소유한다. 이미 사용한 출력 경로에 다시 실행하면 원시 로그를
덮어쓰지 않고 거절한다. `readback-shared-sticky-measure.py`와
`readback-shared-sticky-input-repeat.py`로 보존 로그를 다시 검사할 수 있다.
