# 설치 이후 프레임·제출·표시 단계 진단

상태: 외부 진단 앱에서 수집·독립 재계산·실제 자료 손상 대조를 완료했다. 제품 코드는 바꾸지 않았다.

## 결과

5만 개 여러 줄 Zig 함수·50ms·30키·비동기·단일/공유 뷰별 3프로세스다. 총 6프로세스·180키의
입력/문서/Metal 표시가 검증됐고, 각 프로세스의 마지막 입력 1개씩 **6개 입력만 단계별 귀속**했다.
이전 단계 진단과 앱/HEAD가 다른 별도 모집단이며 이전 값과 합치거나 개선율을 계산하지 않는다.

단위 ms, 뷰별 3프로세스 중앙값이다. 각 행의 중앙값을 더해 전체 중앙값으로 쓰지 않는다.

| 설치 이후 구간 | 단일 뷰 | 공유 2뷰 |
| --- | --- | --- |
| 다음 tick 진입 대기 | 11.887 | 9.339 |
| tick 내 프레임 준비 | 3.416 | 5.654 |
| 나머지 tick 처리 | 0.014 | 0.019 |
| Swift draw 진입 대기 | 0.003 | 0.003 |
| Swift 준비 | 0.021 | 0.021 |
| renderer 준비 | 0.284 | 0.244 |
| drawable arm → commit 직전 | 0.007 | 0.007 |
| commit 직전 → 실제 표시 | 16.541 | 20.675 |
| 설치 → 실제 표시 | 34.755 | 38.632 |

전체 6개 마지막 입력에서 tick 진입 대기는 5.86~14.53ms, renderer 준비는 0.24~0.30ms,
commit 직전부터 실제 표시까지는 15.13~27.21ms였다. 이번에는 설치가 모두 tick 시작 전에
완료됐다. tick 도중 설치를 계산하는 경로는 별도 합성 양성 대조로 확인했으며 실제 관측으로
표현하지 않는다. 단일 뷰의 게시→제출에 19.24ms가 걸린 실행도 보존했다.

이 표본에서 설치 이후에는 다음 프레임 진입 대기와 제출 이후 표시 구간의 비중이 컸다.
특정 timer·GPU 실행이나 VSync가 원인이라고 확정하지 않는다. 다음 실험 후보는 완료 이후
프레임 예약 경로의 대조이며, 프레임율/전력/메모리 정책 변경은 이 단계에서 하지 않는다.

## 측정 계약

[요청 단계 진단](parse-stage-results.md)의 마지막 입력을 유지하면서 그 입력의 첫 구문 준비
프레임을 세대·본문 revision·입력 접두부·ready·스레드로 연결한다. 여러 번 그린 같은 세대는
실제 presentedTime이 기존 구문 표시 기록과 같은 drawable 하나만 선택한다.

- tick 진입/종료와 현재 Metal 버퍼의 입력 증명을 기록한다.
- Swift draw 진입, C 렌더러 진입, drawable에 표시 콜백을 붙이는 시점과 commit 직전을 기록한다.
- 콜백은 자기 행 번호를 값으로 보유해 뒤의 다른 프레임으로 귀속하지 않는다.
- 콜백은 drawable의 presentedTime을 기록한다. 콜백 실행 시각으로 표시 시각을 대신하지 않는다.
- 별도 2,048행 frame/draw 배열의 넘침·미완료 콜백·누락/모순된 시각·준비/세대/스레드 불일치는 거절한다.

구간은 설치→tick 대기, tick 내 프레임 준비, 나머지 tick, Swift draw 대기/준비,
C renderer 준비, arm→commit, commit→표시로 나눈다. 설치가 이미 실행 중인 tick 내부에서
이뤄지면 tick 대기를 0으로 하고 설치 이후의 준비만 센다. 개별 실행의 구간 합은
설치→표시 경과와 일치해야 한다. 단계 중앙값을 더해 전체 중앙값으로 쓰지 않는다.

renderer 준비에는 drawable/resource 대기와 인코딩이 함께 들어간다. commit→표시도
GPU 실행 시간 자체가 아니며 큐·표시 대기를 포함한다. 특정 timer/GPU 원인이나 개선율은
이 계측만으로 확정하지 않는다. 계측 부하가 있는 진단 모집단을 일반 성능 자료와 합치지 않는다.

## 재현

```sh
python3 tools/editor-input-latency/prepare.py --stream --fold-reuse-control --parse-stages --display-stages --output <새 외부 빌드 경로> --deps <실제 zig-pkg 경로> --cache <빌드 캐시>
python3 tools/editor-input-stream/parse_stage_study.py --build <고정 빌드 경로> --output <새 외부 수집 경로>
python3 tools/editor-input-stream/parse_stage_report.py <수집 경로> --output <새 외부 보고서 파일>
python3 tools/editor-input-stream/display_stage_review.py <수집 경로> --output <새 외부 손상 대조 경로>
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

진단 앱은 기존과 같이 private profile·cwd·허용 목록 환경을 사용한다. 전면 입력을 위한
Mac 조작 중단 시간을 사용자와 조율하고, 문서·입력 소스·provider 설정·실제 Metal 표시의
기존 검증을 유지한다. 일반 입력 성능 reader는 이 parse-stages 빌드를 거절한다.

## 한계

제품 코드는 바꾸지 않는다. PID 대상 ASCII 입력이며 물리 HID·IME·광학 표시·CPU 시간·전력을
측정하지 않는다. 수집 시 5만 개 여러 줄 Zig 함수·50ms·단일/공유 각 3프로세스의 마지막
입력 6개만 귀속한다. LSP·복원·자동 줄바꿈은 끄고 실제 접기를 실행하지 않는다.

## 검증과 원본

- 진단용 ReleaseFast 앱 빌드와 Python 계약 94개 통과.
- 실제 자료를 독립 손상한 32가지를 모두 거절했다. 정상 대조 33회와 전체 원본 재판정을 유지했다.
- 다른 세대/drawable·revision·접두부·준비·스레드·누락 시각·넘침·미완료 콜백·잘못된 숫자와 숨긴 진단 라벨을 검사했다.
- 기존 parse-stage 모집단도 새 reader로 다시 읽어 통과했다.
- 제품 HEAD: `500af08bb82bf0cdc06311980baee048bbe79663`.
- 앱 SHA-256: `e68dace66cd4eda5ddfa6d0d28b1010872a8b2bea64ac5d4c2f404a2d3a4b436`.
- 고정 빌드: `~/.cache/maru-agent-artifacts/post-install-display-build-1`.
- 원본: `~/.cache/maru-agent-artifacts/post-install-display-study-1`.
- 손상 대조: `~/.cache/maru-agent-artifacts/post-install-display-review-1`.
- [개별 실행과 해시](display-stage-results.json), [독립 손상 판정](display-stage-validation.json).
