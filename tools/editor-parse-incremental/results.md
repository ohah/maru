# 증분 인계 실행 결과

제품 소스 기준: `d6cba13ec7472ccad20e209f1f159f4b34c90326`. 이후 문서 보완 뒤에도 실제 제품 소스 해시를 대조한다.

Apple M4 Max · macOS 26.5.1 · Zig 0.17.0 · ReleaseFast. 자체 빌드/검사를 동시에 실행하지 않았다. 다른 앱과 OS 부하는 통제하지 않았고, 기록한 1분 load average는 20.24~21.67이다. 수치는 관측 표본이며 성능 상한이나 GUI 지연 보장이 아니다.

## 서비스 완료 경과

단위는 ms다. 각 파일·모드별 60입력의 중앙값/최댓값이다. 초기 준비와 Buffer 편집·Snapshot 준비는 시간 밖이다. 원문 복사·차이 계산·파싱·스케줄링과 이전 퇴역 작업의 영향은 포함한다.

| 고정 fixture | byte | cold 중앙값 | 증분 중앙값 | cold 최대 | 증분 최대 |
|---|---:|---:|---:|---:|---:|
| flat-3000.zig | 180,780 | 12.992 | 1.412 | 16.146 | 3.004 |
| flat-15000.zig | 922,780 | 64.089 | 8.961 | 70.119 | 10.579 |
| flat-50000.zig | 3,127,780 | 219.798 | 39.046 | 231.294 | 50.073 |
| real-build.zig | 767,683 | 28.600 | 5.326 | 30.404 | 6.314 |
| real-host.swift | 1,169,769 | 79.283 | 2.947 | 84.778 | 4.465 |

## 메인 submit 호출

단위는 us다. native 핸들 준비·Snapshot 참조 유지·큐 처리/회수가 포함되며 순수 tree copy만의 시간이 아니다.

| fixture | cold 중앙값 | 증분 중앙값 | cold 최대 | 증분 최대 |
|---|---:|---:|---:|---:|
| flat-3000.zig | 21.83 | 31.75 | 36.25 | 51.04 |
| flat-15000.zig | 21.67 | 30.21 | 40.21 | 57.38 |
| flat-50000.zig | 21.56 | 31.67 | 49.21 | 54.58 |
| real-build.zig | 21.88 | 30.40 | 40.83 | 49.12 |
| real-host.swift | 22.42 | 36.88 | 43.50 | 76.79 |

## 정확성과 실패 경로

성능 600입력과 분리한 200입력에서 각 결과의 전체 C 노드 구조·필드·byte/point·오류 플래그를 cold 결과와 대조했다. 원시 로그에서 중앙값/최댓값도 독립적으로 다시 계산해 JSON과 일치함을 확인했다.

Debug·ReleaseFast에서 서비스 14개·Provider 100개·Snapshot clone 1개와 익명 import 28개, production-mode cold→증분 실행을 통과했다. 빈 문서 전환과 재입력도 확인했다. 문서/config 검사와 전체 경계 693/693 빌드 단계도 통과했다. 빌드 그래프 원장은 실측 target의 모듈 1개/import 3개 증가와 맞춰 같은 커밋에서 갱신했다.

미완료 tree 수락·다른 grammar 기준·잘못된 basis 태그·잘못된 byte 열·메인 native 해제 결함을 컴파일한 뒤 assertion 실패로 탐지했고 정상 전후 대조를 통과했다. 넓은 재파싱이 잘못된 point를 덮는 최초 검증 빈틈은 입력 좌표 계약의 직접 검사로 보강했다.

## 증거와 범위

- 최종 실측: `/Users/yoonhb/.cache/maru-agent-artifacts/parse-incremental-measure-isolated/` — 입력·바이너리·40개 로그·source inventory·result.json·summary.json.
- 결함 대조: `/Users/yoonhb/.cache/maru-agent-artifacts/parse-incremental-review-complete/` — 원본/변형 소스·7개 실행 바이너리/로그·result.json. 최종 제품 소스 원장과 일치함을 확인했다.
- 전체 경계: `/Users/yoonhb/.cache/maru-agent-artifacts/parse-incremental-final-boundaries.log`.
- 집중 실행: `/Users/yoonhb/.cache/maru-agent-artifacts/parse-incremental-rebased-debug.log`, `parse-incremental-complete-release.log`.

실측 도중 소스 변경으로 거절한 이전 실행, 컴파일 오류가 난 준비 실행과 좌표 결함이 살아남은 최초 대조는 최종 통과 자료에 포함하지 않는다. 최종 실측 전 예비 자료도 위 표에 섞지 않았다.

기존 제품 UI·wake·IME·공유 뷰 수명은 미연결이다. C 내부 malloc 실패 전수·race detector·RSS 상한·다중 문서 대규모 공정성은 확인하지 않았다. 가장 큰 fixture의 완료 경과도 프레임 예산 안이라는 주장은 하지 않는다. 다음 제품 연결에서는 완료 알림과 현재 판 설치, 실제 입력 지연을 따로 확인해야 한다.

## CI 집계 보완

첫 macOS CI는 프로젝트 검색 target의 실제 검사 수가 299개인데 기대값이 298개여서 실행 전에 거절했다. 새 Snapshot clone 검사가 registry의 Buffer import를 통해 이 target에도 수집된 것이 원인이다. 검사를 제외하지 않고 기대 수를 299개·macOS 성공 수를 298개로 맞췄다. Windows 전용 경로 비교 한 개의 기존 skip은 유지한다. 집중 재현 로그는 `/Users/yoonhb/.cache/maru-agent-artifacts/parse-incremental-ci-fix-local.log`다.
