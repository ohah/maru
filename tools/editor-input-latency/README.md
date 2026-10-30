# 일반 입력의 표시 지연 비교

제품 파일을 바꾸지 않고 외부 사본을 빌드한다. 같은 실행 파일에서 기존 `editor_syntax_async=false`
동기 경로와 현재 비동기 제품 경로를 비교한다. 과거 출시 바이너리와의 비교가 아니다.
LSP를 끄고 같은 문서·창·설정을 사용하며 초기 문서 분석과 괄호 목록이 준비된 뒤 입력한다.

```sh
python3 tools/editor-input-latency/prepare.py --output <새 외부 빌드 경로> --deps <기존 의존성> --cache <외부 Zig 캐시>
python3 tools/editor-input-latency/suite.py --build <빌드 경로> --output <새 외부 결과 경로>
# 중단 후 같은 설정으로 재개: 위 명령에 --resume 추가
python3 tools/editor-input-latency/verify.py <개별 묶음 경로: 3000-typing-attempt-0 등>
python3 -m unittest discover -s tools/editor-input-latency -p 'test_*.py'
# 동일 fixture·모집단의 전후 비교(두 suite의 원시 증거를 모두 다시 검증)
python3 tools/editor-input-latency/compare.py --before <이전 suite> --after <수정 후 suite> --output <새 비교 JSON>
```

`prepare.py --resume`은 같은 HEAD·기록된 원본/계측 사본의 해시가 일치할 때만 기존 사본을 다시 만든다.
제품의 Swift/Zig/C ABI에 API를 추가하지 않는다. 소스·계측·실행 파일 해시를 외부 `source.json`에 둔다.
실험의 `manifest.json`은 실행 순서·fixture·PID·실행 파일·결과 해시를 기록한다.

## 측정 경계

- OS CGEvent HID 게시 직전부터 해당 입력을 담은 drawable의 표시까지를 잰다. 실제 키보드 하드웨어를 누르는 실험은 아니다.
- native keyDown 도착을 별도로 기록한다. 읽기 전용 문서 판·IME preedit·실제 입력 문자열로 키가 올바른 문서에 들어갔는지 확인한다.
- 성공한 전체 Metal frame 게시에서 문서 판·preedit·구문 준비·괄호 준비·뷰 수·실제 비동기 모드를 기록한다.
  렌더러는 인코딩 직전 그 프레임 세대와 일치하는 증명만 복사한다. 표시 callback에서 현재 모델을 다시 읽지 않는다.
- Apple의 [`presentedTime`](https://developer.apple.com/documentation/metal/mtldrawable/presentedtime)은 화면에 표시된 host 시각이다.
  [`addPresentedHandler`](https://developer.apple.com/documentation/metal/mtldrawable/addpresentedhandler(_:))에서 읽으며,
  0(미표시/드롭)은 표본에 넣지 않는다. command-buffer 제출/완료 시간을 표시 시간으로 대체하지 않는다.
  카메라로 측정하는 광자 도달 지연은 아니다.
- 첫 변경 프레임·문법 준비 프레임·괄호 색까지 준비된 프레임을 구분한다.
- macOS `getrusage(RUSAGE_SELF).ru_maxrss`는 bytes이며, 앱 자신의 시작부터 측정 종료까지 최대 RSS다.
  자식 세션 호스트의 메모리나 시스템 전체 메모리는 포함하지 않는다. 초기 준비 뒤 RSS와 마지막 입력 완료 직후 RSS도 기록한다.

## 모집단과 거절

기본값은 3,000/50,000 함수의 Zig 원문, 일반 입력/실제 두벌식/공유 분할, 독립 프로세스 3개씩이다.
각 반복은 AB/BA 순서를 교대하고, 프로세스당 30입력을 모두 보관한다. 첫 5입력 뒤 25개를 안정 구간으로 집계한다.
첫 입력과 전체 입력의 값은 원시 자료에서 지우지 않는다. 각 프로세스의 중앙값·p95·최댓값을 구분하며
서로 다른 프로세스의 표본을 독립 반복으로 부풀리지 않는다.

게시 전과 결과 수락 때 전면 앱·key window·first responder·입력 소스를 확인한다. 앱/창의 focus 상실 알림도
기억하고 한 번 잃으면 그 실행 전체를 거절한다. 잘못된 실제 문자열, 다른 모드, 낡은 프레임 세대,
시계 역전·표시 callback 부재·불완전한 A/B 쌍·중복 프로세스 기록/경로는 계산 전에 거절한다.
단순히 느린 올바른 표본은 제외하지 않는다. 실행 마감은 멈춘 하네스를 검출하는 장치이며 성능 예산이 아니다.

문서와 백업·설정은 실행별 외부 디렉터리에 격리하고, 디스크 원문이 바뀌지 않았는지 확인한다.
입력 소스는 종료 시 우리가 선택한 소스인 경우에만 복원한다. 사용자 중간 선택을 덮어쓰지 않는다.
입력은 첫 글자 프레임이 표시된 뒤 최소 120ms 간격으로 이어간다. 중간 입력의 색이 다음 입력 전에
완성되지 않은 경우 0을 빠른 완료로 집계하지 않고 완료 비율로 구분한다. 마지막 입력 뒤
문법·괄호 색 완성은 별도로 기다린다. 매 입력마다 색이 끝날 때까지 멈추는 workload가 아니다.
측정은 기존 IME 제품 smoke의 초기화 경로를 쓰며, 원래 IME smoke driver는 사본에서 설치하지 않는다.
일반 workspace 복원·LSP·문서 열기 지연, 다중 창, 연속 입력 폭주, native OOM은 별도 범위다.

`--drop-present`는 실제 표시 callback을 생략하는 음성 대조다. 지연 수치 대신 실행 실패를 요구한다.


## 원시 필드

`timing`은 `[seq, post_ns, event_ns, keydown_ns, keycode, first_ns, syntax_ns, first_gen,
syntax_gen, full_color_ns, full_color_gen]`이다. 색 시각 0은 표본 수락 시점까지 완료 통지를 관측하지 못했다는 뜻이다. 입력 사이의 완료 관측 비율은 마지막 입력을 제외한 24개 창으로 집계하며, 마지막 입력의 긴 색 복구 대기를 그 비율에 섞지 않는다.
`before`/`after`는 `[full_frame_gen, revision, preedit_hash, syntax_ready, shared_view_count,
content_bytes, flags]`이며 flags bit 0은 괄호 준비, bit 1은 실제 비동기 뷰 모드다.
세대는 성공한 전체 frame 게시에서만 스탬프하고, 인코딩 시 세대가 맞지 않으면 측정하지 않는다.
문자열 확인은 NSTextInputClient의 가상 문서이며 매 표본의 PNG/OCR 검증은 아니다.

fixture는 첫 주석에 `x`를 입력하거나 두벌식 `가나 `를 반복한다. 구조 변경·붙여넣기·Undo의
입력 지연은 이 모집단에 포함하지 않는다. 공유 분할은 ASCII 입력이며 공유 분할+IME는 별도 범위다.
`--diagnostic` 실행은 원인 관측용이며 성능 집계에서 거절한다.

## 완료한 실측

[결과](results.md)와 [기계 판독 집계](results.json)를 함께 보관한다.
[후속 요청 보존 결과](continuation-results.md)와 [전후 비교](continuation-results.json)는
같은 fixture·모집단의 두 suite를 `compare.py`로 다시 검증했다.
`diagnose.py`는 별도 blink 진단을, `review.py`는 원시 자료의 의미 변조 거절을 재현한다.
최초 측정 커밋의 `prepare.py --continuation-fix`는 당시 실패한 실험 옵션이다.
제품에 요청 보존이 반영된 뒤에는 중복 패치를 제거했다. 과거 실험 자료의 일반 성능 집계 거절은 유지한다.
실패 결과에는 당시 시각·모델 상태·문자열도 보존해 callback 부재와 입력 부재를 구분한다.
현재 소스가 기록된 제품 HEAD와 다르면 새 실행으로 취급하며 과거 수치를 그대로 재현한다고 주장하지 않는다.
