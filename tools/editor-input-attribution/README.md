# 외부 고정 주기 입력의 메인 스레드 샘플링

[독립 입력 도구](../editor-input-stream/README.md)의 불변 ReleaseFast 앱을 다시 빌드하지 않고
재사용한다. 50,000 함수·공유 2분할·100ms·30입력의 동기/비동기를 독립 3프로세스씩 기록한다.
프로파일러가 붙은 6프로세스·180입력의 시각은 기존 정상 성능 모집단에 넣지 않는다.

```sh
python3 tools/editor-input-attribution/collect.py --build <기존 불변 사본> --output <새 외부 수집 경로>
python3 tools/editor-input-attribution/analyze.py <수집 경로> --output <새 외부 분석 경로>
python3 -m unittest discover -s tools/editor-input-attribution -p 'test_*.py'
```

`collect.py`는 문서·구문 준비 뒤에 Time Profiler를 대상 PID에 붙인다. SDK `notify.h`의
`notify_register_file_descriptor`로 먼저 등록하고 `--notify-tracing-started`의 해당 토큰을
받은 후 생산자를 시작한다. 고정 sleep이나 로그 문구로 연결 완료를 추정하지 않는다.
`notify_register_check`는 SDK에 false positive 가능성이 명시돼 있어 사용하지 않는다.
실제 등록·자체 통지에서 network-order 토큰을 확인했고 잘못된 토큰·길이는 거절한다.

실행·수집 도구 snapshot과 해시, 대상/생산자 PID, 정상 입력 기록, 원시 trace·TOC·XML을 보존한다.
대상과 생산자가 종료된 뒤에만 recorder를 정리한다. 입력 소스 복원·provider 설정 보존은 기존
입력 판정기로 검사한다. `diagnostic` 기록은 정상 `verify.read`/집계 진입점에서 거절한다.
실패 자료는 덮어쓰지 않으며 수집 전체가 끝나고 도구 해시가 유지돼야 `complete`를 기록한다.

## 환경과 자료 보호

Instruments TOC는 대상의 환경 목록을 저장한다. 대상과 recorder에는 필요한 키의 허용 목록만
전달하며 `HOME`·`CODEX_HOME` 등은 기존 값을 보존한다. 알 수 없는 변수는 이름을 추측해서
거르는 대신 전달하지 않는다. 분석기는 알려진 측정·OS 주입 키 외의 키나 중복을 거절한다.
환경 값·TOC 원문을 stdout·PR·공개 결과로 출력하지 않는다. 원시 자료는 외부 0700 경로에 둔다.

허용 목록 적용 전의 사전 실행은 최종 분석에서 제외한다. 환경을 포함하는 원시 TOC는
민감 자료로 취급하며 원문을 출력하지 않는다. 공개 결과에는 정제한 집계·해시만 기록한다.

## 주소와 스택 검증

기존 `editor-native-sampling`의 Mach-O UUID·`__TEXT.__text` reader와 dSYM/`atos` reader를 재사용한다.
이미지 이름만 실제 앱 이름으로 명시할 수 있도록 확장했으며 기존 `archived-test` 기본 계약은 유지한다.
이미지가 빠진 frame도 실행 코드 영역 안의 실제 주소로 해석하고 raw 표시 이름은 비용 분류에 쓰지 않는다.
미해결·deduplicated symbol은 알려진 특정 함수로 분류하지 않는다.

SDK로 원본 trace를 다시 내보내 시각·PID/TID·core·state·weight·스택 주소와 main thread ID를 대조한다.
분석 중 원본 trace가 바뀌지 않았는지 확인하고 주소 해석도 SDK로 다시 대조한다.
다른 PID·실행 경로·정상 종료가 없는 trace·잘못된 열/참조·누락 주소·중복 표본은 거절한다.
스택 없는 표본도 전체 main weight에 남기고 self 합계가 전체와 같아야 한다.
재귀 함수의 포함 weight는 한 표본에서 중복 가산하지 않는다.

## 해석의 한계

준비 뒤 전체 trace의 Running 표본이다. 키별 입력 대기 구간과 trace 시계를 정밀하게 맞춘
결과가 아니며, sample weight를 함수 호출 경과시간이나 정확한 CPU 시간으로 바꾸지 않는다.
포함 비중은 서로 중첩될 수 있다. 프로파일러 부하·종료 비용도 포함하므로 개선율은 별도의
프로파일러 없는 대조가 필요하다. 제품 코드·설정 기본값·UI는 이 단계에서 바꾸지 않는다.

[결과](results.md)와 [정제한 기계 판독 요약](results.json)은 환경 값·기기 이름·기기 UUID를 싣지 않는다.
