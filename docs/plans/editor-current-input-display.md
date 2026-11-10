# 현재 제품의 입력→첫 표시 구간 귀속

상태: 진단 구현·ReleaseFast 앱 빌드·합성 계약/실제 시계 검증 완료. 실제 Mac 입력 수집은 조작 중단 시간 확인을 기다린다. 제품 원인이나 개선량은 아직 판정하지 않았다.

## 목적

[강조 연속성 검증](editor-highlight-continuity.md)에서 메인의 native 도착→첫 표시 p95가
39.26~45.61ms였다. 이 값에는 입력 handler·프레임 준비·예약/표시 대기·관측자 비용이 섞였다.
과거 display 단계 자료는 마지막 구문 준비 입력을, frame-tail/observer 자료는 예약 정책 실험의
사본을 포함하므로 현재 제품의 모든 첫 표시를 설명하는 값으로 합치지 않는다.

## 진단 계약

- 제품 소스와 예약/투영 정책은 바꾸지 않는다. 기존 `--stream --fold-reuse-control --parse-stages --display-stages` 사본에만 `--input-display`를 추가한다. 즉시 프레임 요청·대상 coalescing·deferred retry 실험과 함께 사용하지 못하게 한다.
- 모든 키의 첫 표시를 기존 token·native 도착·문서 revision·접두부·generation·스레드·동일 drawable의 `presentedTime`으로 연결한다. 구문 준비가 0인 첫 본문 프레임도 분석한다. 최종 구문 준비 표시는 기존 reader로 계속 검증한다.
- native→tick, tick의 프레임 준비/마무리, Swift draw 대기/준비, C renderer 준비, terminal/overlay `nextDrawable` 획득, 나머지 renderer, arm→commit, commit→present를 나눈다. 개별 키의 구간 합은 해당 키의 전체 경과와 일치해야 한다. 단계별 중앙값이나 p95를 더하지 않는다.
- drawable 획득은 renderer invocation 시각까지 맞춰 연결한다. 같은 generation의 다른 draw를 붙이지 않는다. nil 획득 횟수도 별도로 보존한다. 획득 이후 나머지 renderer는 인코딩 외 작업도 포함하고 commit→present도 GPU 실행 시간만을 뜻하지 않는다.
- Swift 입력 handler와 관측 handler의 wall 구간·해당 main thread CPU를 기록한다. 경계에 걸친 CPU를 비례 배분하지 않고, 완전히 포함된 CPU와 경계 구간 수를 나눈다. observer의 포함 CPU와 입력 handler CPU를 무조건 더하지 않는다. `native→tick` 구간도 단순 유휴 대기로 부르지 않는다.
- 기록 snapshot을 만드는 마지막 관측 handler는 아직 끝나지 않았으므로 첫 표시들이 그 handler 시작 전에 끝났는지 확인한다. 미완료 handler와 겹친 첫 표시를 누락된 CPU처럼 조용히 집계하지 않는다.
- 동일 사본에서 CPU 계측 켬/끔을 교대한다. 두 조건 모두 기존 포커스·입력 소스·문서·완료 JSON·실제 표시 검사를 그대로 수행한다. 켬/끔은 CPU 시계·구간 저장의 추가 비용을 비교하는 진단 대조이며 모든 계측 비용이 제거된 제품 기준선은 아니다.

## 수집과 재현

```sh
python3 tools/editor-input-latency/prepare.py --stream --fold-reuse-control --parse-stages --display-stages --input-display --output <새 외부 빌드> --deps <zig-pkg> --cache <외부 캐시>
python3 tools/editor-input-stream/input_display_study.py --build <고정 빌드> --output <새 외부 수집>
python3 tools/editor-input-stream/input_display_report.py <수집> --output <새 보고서>
python3 tools/editor-input-stream/input_display_review.py <수집> --output <새 독립 손상 경로>
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

5만 함수·여러 줄 Zig·50ms·30입력·비동기·일반/공유 뷰를 각 3프로세스, 두 CPU 계측 조건으로
실행한다. 총 12프로세스·360입력이다. 첫 입력을 버리지 않고 첫 예상 밖 실패에서 멈춘다.
전면 포커스·물리 modifier 간섭 자료도 삭제하지 않고 정상 수집과 분리한다.
LSP·복원·자동 줄바꿈은 끄며 실제 접기를 실행하는 workload는 아니다.

## 준비된 증거와 확인한 범위

- 제품 HEAD: `940a6c1edff4d1127f8d494c1cbdfcbbc4f05f12`.
- 진단 앱 SHA-256: `731c876b469eac432badb3530873b35cc545f38a29fc5713bbd182f4a89bc4b8`.
- 고정 빌드: `~/.cache/maru-agent-artifacts/input-display-build-1`. 원본/계측 소스 해시와 실행 파일의 일치를 재확인했다.
- 합성 판정은 pending 첫 프레임·overlay 없음·진행 중 tick·coalesced 입력의 개별 지연·다른 frame/drawable·잘못된 스레드/구간/CPU·완료 불일치를 검사한다.
- 같은 Swift 기록기를 실제 C thread CPU 시계와 함께 별도 실행해 계측 켬/끔, 넘침, 시계 실패를 검사한다. 최초 독립 fixture는 main actor 문맥을 지정하지 않아 컴파일이 거절됐다. fixture를 main actor에서 실행하도록 고쳤으며 앱/기록기 구현은 바꾸지 않았다.
- 실제 자료의 손상 대조 코드는 준비했으나 아직 현재 Mac 수집 자료로 실행하지 않았다. 합성 검사를 실제 입력·GPU 표시 검증으로 확대하지 않는다.

## 남은 검증과 판정 기준

실제 입력 수집과 원시 자료 재판정, 독립 손상/정상 전후 대조, 계측 켬/끔의 지연 차이를 확인한다.
CPU 계측 오버헤드가 크게 나오면 그 수치를 제품 지연으로 빼거나 원인으로 단정하지 않는다.
반복 재현된 구간만 다음 조사/개선 후보로 고른다. 프레임율·예약·전력 정책 변경은 이 진단의 범위가 아니다.
광학 표시·물리 키보드·IME/스크롤·실제 접기와 다른 문서 크기는 별도 범위다.
