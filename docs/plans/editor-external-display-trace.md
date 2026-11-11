# GPU 완료 이후 표시의 외부 추적

상태: 진단 앱 빌드·검사 154개·독립 Metal label 추적·실제 Darwin 시작 알림 전달 검증 완료. 실제 편집기 예비 수집·surface 연결·전체 cohort 비교는 미착수다.

## 목적과 범위

[표시 timing 진단](editor-display-timing.md)의 앱 내부 display-link 관측기가 분포에 영향을 줬으므로, 새 display link 없이 Instruments Metal System Trace를 off/on 비교한다. 외부 추적 자체도 무비용이 아니므로 제품의 무관측 상태를 대신한다고 가정하지 않는다. 제품 Timer·프레임 예약·레이어 설정을 변경하지 않는다.

`prepare.py --external-display-trace`는 `--submit-display`를 요구하고 `--display-timing`과 혼합을 거절한다. 외부 사본의 command buffer에 `maru-submit:<generation>:<renderer invocation ns>` 라벨만 더한다. 기존 GPU/첫 표시 계측은 양쪽 enabled·CPU 구간 계측 untimed다. 따라서 GPU callback까지 없는 완전 무계측 제품 비교는 아니다.

## 시작과 종료

`external_display_trace.Marker`는 제품 ready 이후 Instruments를 해당 PID에 attach한다. Darwin notification을 먼저 등록하고 `--notify-tracing-started` 알림을 받아야 입력 생산을 허용한다. 문자열 로그를 readiness 증거로 쓰지 않는다. off/on 모두 ready 후 10초 settling을 두며 연결이 그 창을 넘으면 무효로 보존한다. 앱 종료 후 trace가 저장될 때까지 기다려 내보낸 XML 해시를 meta에 남긴다. 초기 연결·정리·export 오류는 정상 자료에 넣지 않는다.

`external_display_pilot.py`는 일반 뷰 30키·off/on 한 pair(총 60키)의 예비 수집이다. 실제 표면의 schema/신원 연결이 확인되기 전 12프로세스 전체 수집으로 확대하지 않는다. 원시 JSON·trace·XML·tool 사본과 해시를 외부 경로에 보존한다.

## 프레임·시계 연결

`external_trace_xml.Table`은 XML의 typed raw 값과 명시적 id/ref를 해석한다. 반올림된 fmt 시각은 계산에 쓰지 않으며 missing/cyclic ref·중복 id·schema/열/행 불일치를 거절한다. command buffer는 대상 PID와 정확한 label로 연결한다. 가까운 시간이나 객체 주소의 유사성으로 엮지 않는다. trace command buffer ID는 앱의 Objective-C pointer와 다른 신원이므로 직접 비교하지 않는다.

`time-info`의 mach absolute epoch와 rational timebase를 사용해 trace 상대 ns를 앱 host clock ns로 옮긴다. command buffer 완료와 present request를 같은 trace ID로 연결한다. present request의 typed surface payload는 실제 자료를 확인하기 전 보존만 하며, surface swap/compositor와의 연결은 아직 완료하지 않았다. 앱의 presentedTime을 다른 surface의 가까운 swap 시각으로 대체하지 않는다.

## 준비 증거와 한계

- 독립 예제 `external-metal-probe-1`: GPU 제출/완료 각 1행과 VSync 41행을 export했다. 창이 없으므로 surface swap/compositor 행은 0개였다. 실제 편집기 표시 증거가 아니다.
- `external-metal-label-probe-1`: 독립 예제의 정확한 `maru-submit:17:123456789` label을 export에서 확인했다.
- Darwin notify 등록→실제 notifyutil post→file descriptor 수신을 확인했다. 입력이나 제품 창을 조작하지 않았다.
- 합성 검사는 raw 시각·PID·정확한 label·중복 buffer·시간 부호·누락/순환 reference를 검사한다. 실제 원시 자료의 독립 손상 검증은 미착수다.
- 현재 trace schema는 설치된 Xcode의 관측 포맷이다. 다른 버전에서 필요한 열이 없으면 실패하며 추정으로 이어 붙이지 않는다.

```sh
python3 tools/editor-input-latency/prepare.py --stream --fold-reuse-control --parse-stages --display-stages --input-display --submit-display --external-display-trace --output <새 외부 빌드> --deps <zig-pkg> --cache <외부 캐시>
python3 tools/editor-input-stream/external_display_pilot.py --build <고정 빌드> --output <새 외부 예비 수집>
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

고정 앱: `~/.cache/maru-agent-artifacts/external-display-build-1`. 제품 HEAD `adf9937b3e80f8f72086500146c835a80c227c53`, 앱 SHA-256 `46b1acd7a5a6a10e2e68e097221c1efd3ef4086951a01e496d1daaadcc7e261b`. 계측 소스·실행 파일 해시를 source.json에 대조했다.
