# Native 내부 샘플링

제품을 수정하지 않고 기존 Provider 기준 바이너리를 실행 전부터 Time Profiler로 기록한다.
[계획](../../docs/plans/editor-native-sampling.md)이 범위·채택 기준을 소유한다.
[실측 결과](results.md)는 측정 커밋·시간 분포·상위 함수와 한계를 구분한다.
실제 수집·전체 검증·적대적 검증에는 macOS와 Xcode의 `xctrace`·`dsymutil`·`atos`가 필요하다.
순수 단위 검사는 SDK나 실측 자료 없이 실행하며 기존 `check` CI에도 포함한다.

## 명령

먼저 [기준 실측 도구](../editor-native-parse-measure/README.md)의 다섯 고정 원문으로
새 기준 모집단을 수집한다. `zig-pkg`는 기존 프로젝트 의존성 폴더다.
각 output은 저장소 밖의 새 경로여야 하며, `FULL_COMMIT_ID`는 기준 수집 당시의 전체 Git ID다.

```sh
python3 tools/editor-native-parse-measure/baseline.py --output /tmp/native-sampling-new/baseline --deps /path/to/zig-pkg --fixtures /path/to/pinned-fixtures
python3 tools/editor-native-sampling/run.py --baseline /tmp/native-sampling-new/baseline --expected-head FULL_COMMIT_ID --output /tmp/native-sampling-new/profiles
python3 tools/editor-native-sampling/verify.py --baseline /tmp/native-sampling-new/baseline --profiles /tmp/native-sampling-new/profiles --expected-head FULL_COMMIT_ID --output /tmp/native-sampling-new/verified.json
python3 tools/editor-native-sampling/adversarial.py --baseline /tmp/native-sampling-new/baseline --profiles /tmp/native-sampling-new/profiles --expected-head FULL_COMMIT_ID --output /tmp/native-sampling-new/adversarial
python3 -m unittest discover -s tools/editor-native-sampling -p 'test_*.py'
```

기준은 기존 모집단인 성능 30프로세스·600입력과 별도 정확성 10프로세스·200입력이다.
샘플링은 별도 30프로세스다. 원문 다섯 개·일반/공유 입력 각각 3프로세스이며,
프로세스마다 첫 입력을 포함한 공백 삽입 20회를 실행한다. 준비 실행은 구분한다.
프로파일러가 연결된 대상의 시간 기록은 제품 대조용이며 기준 성능 표에 섞지 않는다.

## 대상과 주소 검증

주소 reader는 GUI 앱 조사에서 명시적 실행 이미지 이름도 받는다. 기본 `archived-test` 계약은 유지하며
다른 이름을 허용하더라도 경로·UUID·코드 영역·atos 출력의 이미지 이름은 정확히 일치해야 한다.
GUI 진단의 모집단과 실행 절차는 [고정 입력 조사](../editor-input-attribution/README.md)가 소유한다.

기준의 전체 Git 소스·실제 사본·생산자·보관 실행 파일·원문·40개 원시 로그를 먼저 검증한다.
같은 보관 바이너리에서 dSYM을 만들고 UUID를 대조한다. trace는 실제 대상의 정상 종료까지
기록한다. 실행 중인 유효 편집을 관측 시간 초과로 취소하지 않는다.

실행 이미지가 빠진 Zig frame도 실제 export에 있다. XML의 표시 이름만으로 분류하지 않고,
보관 Mach-O의 UUID·`__TEXT.__text`와 trace의 유일한 실행 이미지 load address를 결합한다.
코드 영역의 전체 주소를 보관 dSYM의 `atos`로 해석하며, 검증에서도 SDK로 다시 해석한다.
확인할 수 없는 주소·스택 누락은 별도 계수로 보존한다. 외부 코드의 세부 함수 이름은
비용 판정에 사용하지 않고 대상 코드 영역 밖으로 집계한다.

최종 검증은 원시 trace도 SDK로 다시 내보낸다. 시각·스레드·PID·core·상태·weight·스택 주소
순서를 원래 export와 대조한다. 표시 이름이나 XML ID의 차이는 이 사실 대조와 구분한다.
`verified.json.sdk-replays/`에 SDK 재내보내기 근거를 남긴다.

## 계수 해석

`all`은 전체 스택 표본, `edit`은 실제 함수 주소로 식별된 편집 진입점이 있는 표본이다.
그 밖의 표본을 모두 초기 준비라고 단정하지 않는다. 재귀 frame은 한 행의 포함 weight에
중복 가산하지 않는다. self weight와 누락 weight의 합은 전체 weight와 같아야 한다.

포함 함수의 weight는 서로 겹친다. 이를 더하거나 호출별 경과시간·정확한 CPU 시간으로
읽지 않는다. 노드 재사용 개수·GUI/HID·GPU present·RSS·모든 언어의 최악 비용은 이 도구의
결과가 아니다. 프로파일링은 원인 위치를 좁히며, 개선율은 별도 전후 측정이 필요하다.

## 보존

초기 `producer.json`, 도구 snapshot, dSYM, 원시 trace, 대상 출력, SDK 명령·출력과 모든 해시를
보존한다. 완료 표시는 전 모집단과 제품 결과를 검증한 뒤에만 만든다. 실패 출력은 덮어쓰지 않는다.
실행 파일·원문·로그·심벌을 빌드 캐시 밖에 두므로 캐시 정리와 원시 증거 보존을 분리할 수 있다.
현재 머신의 기기 이름·UUID·전체 환경을 공개 결과 문서에 옮기지 않는다.
