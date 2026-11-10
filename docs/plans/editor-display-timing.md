# GPU 종료 후 표시 timing 진단

상태: 진단 관측기·판정기·수집기·독립 손상 도구 구현. 합성 검사 포함 147개 통과. macOS 11 target 제품 진단 앱 빌드는 통과했다. 실제 수집·실제 자료 손상 대조는 미착수다.

## 진단 계약

[GPU 제출 진단](editor-submit-display.md)의 후속으로 terminal 레이어의 runtime 설정과 같은 화면의 display-link timing을 읽는다. 제품의 Timer·present·레이어 설정은 바꾸지 않는다. 외부 빌드 사본에서만 NSScreen의 CADisplayLink를 관측기로 추가한다. 새 관측기는 프레임 요청이나 draw를 하지 않는다. callback의 CPU 진입·종료와 timestamp·targetTimestamp·duration을 따로 기록한다. targetTimestamp는 예상 표시 경계이며 특정 drawable의 실제 presentedTime과 혼동하지 않는다.

같은 사본에서 관측기 off/on을 교대하고 기존 GPU 계측은 켠다. 기존 CPU 구간 계측은 끈다. off/on 모두 레이어와 화면 식별을 observer tick마다 읽고, 관측 시점에서 화면·레이어·표시 설정·앱 Timer Hz가 바뀌면 무효로 보존한다. 실제 display-link callback의 기록 비용과 native→present 변화를 보고한다. 기록 용량 초과·빈 timing·시계 오류·관측 범위 부족은 조용히 제외하지 않는다.

기존 cohort와 첫 입력/drawable 소유권 검사를 유지한다. display-link가 전달한 구간이 GPU 종료를 포함하는지, 이후 관측된 표시 timestamp가 해당 drawable의 presentedTime에 얼마나 가까운지 계산한다. 구간이 비거나 중복되면 보간하지 않고 별도로 센다. 표시 경계와 가까워도 compositor 내부 원인이나 광학 표시 지연을 확정하지 않는다. callback이 main run loop의 부하에 영향을 받으므로 지연된 callback과 경계 timestamp를 구분한다.

## API 근거

- [CADisplayLink](https://developer.apple.com/documentation/quartzcore/cadisplaylink): 화면 갱신에 맞춘 callback과 timestamp/targetTimestamp 의미.
- [duration](https://developer.apple.com/documentation/quartzcore/cadisplaylink/duration): 첫 callback 전 값은 미정이며 예상 구간은 targetTimestamp−timestamp로 계산한다.
- [timestamp](https://developer.apple.com/documentation/quartzcore/cadisplaylink/timestamp): 마지막 표시 경계 시각.

새 관측기는 macOS 14 이상 NSScreen API를 사용한다. 미지원 OS·화면 미확인은 오류로 기록한다. 표시 타이밍의 관측 빈도가 실제 모든 패널 갱신을 포함한다고 가정하지 않는다.

## 구현과 재현

`prepare.py --display-timing`은 `--submit-display`를 필요로 한다. `display_timing.swift.inc`의 `DisplayTiming`은 같은 화면의 display link를 main RunLoop common 모드에 붙인다. 화면 ID·maximumFramesPerSecond·레이어 객체·displaySyncEnabled·presentsWithTransaction·maximumDrawableCount·앱 frame-loop Hz를 observer마다 대조한다. maximumFramesPerSecond는 화면이 보고한 상한이며 실제 측정 주사율이 아니다. callback을 중지한 뒤 기록을 복사하며 고정 예약 용량 초과는 오류다. 두 조건 모두 설정 관측 비용을 포함한다.

`display_timing_report.py`는 기존 첫 표시/GPU 판정을 먼저 수행하고 같은 프로세스의 관측 lifetime과 GPU 종료 포함 범위를 확인한다. 키의 첫 drawable을 generation과 실제 presentedTime으로 다시 연결한다. GPU 종료를 포함하는 예상 구간 수가 0 또는 여러 개면 그대로 보고한다. 다음 관측 timestamp까지의 시간과 거기서 presentedTime까지의 잔여는 각 입력에서만 계산하며 음수 잔여도 숨기지 않는다. 구간의 합은 관측한 GPU 종료→표시 시간이다. 관측되지 않은 경계를 보간하지 않는다.

`display_timing_study.py`는 5만 함수·여러 줄 Zig·50ms·30키·일반/공유 뷰·각 3회·off/on을 반복별 교대한다. GPU callback 계측은 양쪽 enabled, CPU 구간 계측은 untimed다. 동일 pair의 화면과 표시 설정이 달라도 무효로 판정한다. 레이어 객체 주소는 서로 다른 프로세스 사이에서 같을 필요가 없다.

```sh
python3 tools/editor-input-latency/prepare.py --stream --fold-reuse-control --parse-stages --display-stages --input-display --submit-display --display-timing --output <새 외부 빌드> --deps <zig-pkg> --cache <외부 캐시>
python3 tools/editor-input-stream/display_timing_study.py --build <고정 빌드> --output <새 외부 수집>
python3 tools/editor-input-stream/display_timing_report.py <수집> --output <새 보고서>
python3 tools/editor-input-stream/display_timing_review.py <수집> --output <새 독립 손상 경로>
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

## 준비 중 확인한 사항

첫 진단 앱 빌드에서 제품 macOS 11 target에 macOS 12/14 API를 무조건 사용한 호환성 오류를 확인했다. `DisplayTiming`과 호출부에 macOS 14 availability 경계를 추가했고, macOS 11 target 독립 typecheck를 통과했다. 미지원 환경은 unsupported 기록으로 남고 reader가 유효 수집으로 받지 않는다. 실패 빌드는 `~/.cache/maru-agent-artifacts/display-timing-build-1`에 보존한다.

합성 검사는 24개 독립 값/시계/상태 오류와 늦은 callback·중복 timestamp·관측 구간 공백/중첩·음수 잔여·disabled 설정 유지·첫 drawable 연결 실패를 검사한다. 실제 원시 자료 손상 대조는 아직 수행하지 않았다. callback body 비용은 selector dispatch와 OS display-link 전체 비용을 포함하지 않으므로 off/on 전체 입력 지연도 함께 비교한다.

관측기는 display-link 기본 선호 범위를 변경하지 않는다. 관측기 생성 자체가 OS의 갱신 정책이나 main run loop 부하에 영향을 줄 수 있으므로 on 자료를 관측기 없는 제품의 완전한 대체로 보지 않는다. off/on 차이를 일정 비용으로 빼서 보정하지 않는다. 설정 동일성은 observer가 샘플링한 시점 사이의 일시적 변경까지 증명하지 않는다.

고정 진단 빌드: `~/.cache/maru-agent-artifacts/display-timing-build-2`. 제품 HEAD `d39f1d942a47939c63df30605e857a0c83518e95`, 앱 SHA-256 `d3aa34b7ffda79bafd1141194c69e9f9b4ff2773d06fc1639ac487597c21d26b`. 계측 소스와 실행 파일 해시를 receipt에 대조했다. 실제 수집은 사용자 조작 중단 확인 뒤 실행한다.
