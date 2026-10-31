# 외부 생산자의 고정 주기 입력 측정

기존 [닫힌 루프 측정](../editor-input-latency/README.md)은 앱 메인이 다음 입력도 게시한다.
앱이 멈추면 생산자도 느려지므로 외부 연타의 대기열을 측정할 수 없다. 이 도구는 별도 Swift
프로세스가 앱 진행을 기다리지 않고 절대 시각에 ASCII 키를 게시한다. 제품 소스·설정·배포물은
바꾸지 않고, `prepare.py --stream`으로 만든 외부 ReleaseFast 사본만 사용한다.

## 실행

```sh
python3 tools/editor-input-latency/prepare.py --stream \
  --output /absolute/new/build --deps /absolute/existing/zig-pkg --cache /absolute/cache
python3 tools/editor-input-stream/run.py --build /absolute/new/build --output /absolute/new/evidence
python3 tools/editor-input-stream/verify.py /absolute/new/evidence --output /absolute/new/verified.json
python3 tools/editor-input-stream/summarize.py /absolute/new/evidence --output /absolute/new/summary.json
python3 tools/editor-input-stream/review.py /absolute/new/evidence --output /absolute/new/review
python3 -m unittest discover -s tools/editor-input-stream -p 'test_*.py'
```

실제 입력은 잠금 해제된 Mac과 이벤트 게시 권한이 필요하다. 앱은 격리한 profile·설정·백업 경로를
사용하고 LSP·workspace 복원·줄바꿈을 끈다. 실행 중 클릭·키 입력·입력 소스 전환은 피한다.
기본값은 3,000/50,000 함수 × 100/50ms × 일반/공유 2분할 × 동기/비동기 × 독립 3프로세스,
각 30입력이다. `--sizes`, `--periods`, `--flows`, `--modes`, `--repetitions`, `--count`로
범위를 명시한다. 요청한 전체 행렬이 없으면 전체 검증을 통과하지 못한다.

`--stream` 사본은 provider 훅 설치·제거, legacy 상태줄 복구, 이벤트 로그 정리와 새 로그 profile
준비를 측정 opt-in 환경에서 건너뛴다. 사용자 `HOME`·`CODEX_HOME`을 다른 용도로 바꾸지 않는다.
runner는 실제 Claude 설정·Codex 훅·Codex 설정 세 파일의 실행 전후 해시도 검사한다.
외부 프로세스에 의한 변경과 구분할 수 없으므로 달라지면 그 실행을 거절하고 파일을 덮어쓰지 않는다.

준비 도구는 프로세스 잠금으로 동일 사본의 중복 빌드를 거절한다. 수집을 시작한 실행 파일은 다시 빌드하지 않는다.
`--resume`은 수집 전 사본 준비에만 쓰고 다른 프로토콜·HEAD·외부 소스 변경을 거절한다.
출력 경로는 매번 새로 만들며 실패한 실행도 보존한다. runner는 첫 예상 밖 실패에서 멈춘다.

## 시각과 입력 계약

`CGEventPostToPid`로 소유한 측정 앱 PID에만 게시한다. 전역 HID tap 게시·물리 키보드 입력과
같은 경로라고 주장하지 않는다. 근거는 Apple의 [CGEvent](https://developer.apple.com/documentation/coregraphics/cgevent)와
[postToPid](https://developer.apple.com/documentation/coregraphics/cgevent/posttopid(_:)) 공개 API다.
타사 코드 표현은 사용하지 않는다.

- `CACurrentMediaTime`의 공통 단조 시계에서 `origin + index × period`에 게시한다.
  producer는 앱의 입력 처리·표시 완료를 기다리지 않는다. 종료 파일 확인은 중단에만 사용한다.
- 게시가 마감보다 20ms 넘게 늦으면 실행 전체를 거절한다. 이는 수집기 유효성 한도이며
  제품의 입력 지연 예산이 아니다. 실제 지각 시간도 결과에 남긴다.
- 각 키는 서로 다른 ASCII와 이벤트 ID를 가진다. 1–36개만 허용한다. native `keyDown` 도착,
  본문의 정확한 접두부·revision·같은 문서 소유자, 성공한 전체 Metal 프레임의 세대를 연결한다.
- `MTLDrawable.presentedTime`이 양수인 실제 표시만 사용한다. 여러 키가 한 프레임에 나오면
  같은 첫 표시 시각을 배정한다. 미완료 presented callback이 남으면 결과를 확정하지 않는다.
- 본문 꼬리 SHA-256은 준비·종료에만 계산한다. 매 프레임 전체 문서를 해싱해 비용을 섞지 않는다.
  시작 fixture·최종 문자열·revision 증가량·뷰 수·실제 파싱 모드·preedit 부재도 확인한다.

원시 행은 `present.m.inc`, 해석은 `verify.py`가 소유한다. `post_to_native_ms`는 게시→native
도착, `native_to_present_ms`는 도착→첫 표시, `post_to_present_ms`는 둘을 합한 값이다.
색 완성은 마지막 게시→문법·괄호 준비 프레임의 표시로 별도 기록한다. 첫 입력도 포함하며
임의로 초기 표본을 버리지 않는다. RSS peak는 앱 시작 비용을 포함한다.

원시 배열의 순서는 다음과 같다. 모든 시각은 단조 시계의 ns이며 모드는 동기 0·비동기 1이다.

```text
keys: seq, token, event_ns, keydown_ns, keycode, modifiers, first_present_ns, first_gen,
      frame_prefix_count, syntax_ready, full_color_ready, native_seen_count
header: errors, requested, received, assigned_first_present, final_color_ns, final_color_gen,
        highest_presented_prefix, actual_mode, pending_callbacks
baseline/state: full_frame_gen, revision, preedit_hash, syntax_ready, views, bytes, flags, prefix_count
flags: bit 0 = brackets ready, bit 1 = async view enabled
```

## 소유권과 실패 대조

전면 앱·창·first responder·편집 입력 owner·ABC 소스를 확인하고, focus/source/modifier 변화 시
중단한다. 원래 입력 소스를 선택 전에 기록한다. 앱이 아직 소유하고 입력 소스도 허용된 상태일 때
복원한다. 소유권을 잃은 뒤 사용자의 다른 앱 입력 소스를 바꾸지 않는다. 복원 실패는 정상 측정으로
쓰지 않는다. 정리는 자신이 실행한 PID에만 적용한다.

측정 준비에서는 시작 알림의 내용을 로그에 남기고 제품의 Esc 처리로 닫은 뒤
`focusWorkspaceInput()`을 거친다. 전면 창만으로 입력 대상을 추정하지 않는다. 첫 사전 실행에서
`notice`가 키를 가로채는 상태를 발견했으며, 그 실패 자료는 성능 결과와 분리한다.

`--kind main-pause`는 첫 native 입력 뒤 앱 메인만 500ms 멈춘다. 그 사이 최소 두 게시와
native 도착 지연을 원시 시각으로 검증한다. 인위적 정지 결과는 제품 성능 모집단과 분리한다.
`--kind drop-present`는 native 입력과 본문 반영은 유지하고 표시 관측 등록을 끈다. 실제 억제
프레임이 있어야 예상 실패로 인정한다. `--kind skip`은 세 번째 이벤트 ID를 보내지 않아
입력 순서 결함 검출을 확인한다. 두 실패 대조는 정상 지연 수치로 집계하지 않는다.

## 증거와 한계

앱·생산자·외부 계측 소스의 해시, fixture·raw JSON·log·입력 소스 기록의 해시와 독립 프로세스
PID를 보관한다. `verify.py`는 저장한 요약을 믿지 않고 원시 파일에서 다시 계산한다.
테스트는 누락·중복·순서·문서 손상·callback 미완료·지각·포커스 손실과 기록 변조를 거절하고
정상 및 프레임 병합 대조를 통과시킨다.

`review.py`는 실제 정상 원시 기록에 입력·문서·일정·표시·소유권 손상을 주고, 각 거절 전후의
정상 대조를 재검사한다. 원시 파일을 직접 고치지 않고 손상 사본과 거절 이유를 새 경로에 남긴다.
`summarize.py`는 정상 전체 행렬만 집계하며 첫 입력을 포함한 모든 키의 pooled 중앙값과
nearest-rank p95·최댓값을 적는다. 키 수는 독립 프로세스 반복 수와 구분한다.

ASCII 1키=1편집인 한정된 workload다. IME·물리 키보드·광학 표시·매 프레임 PNG/OCR 증거가
아니다. 이전 HID 게시 수치와 동일한 전송 경로의 비교로 합치지 않는다. 공통 계측 비용,
호스트 부하와 디스플레이 스케줄링이 포함되며 CPU 귀속이나 전력 개선을 증명하지 않는다.
