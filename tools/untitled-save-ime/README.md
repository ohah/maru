# 새 문서 첫 저장의 실제 IME 검증

`rename-ime`의 공용 입력 하네스를 재사용하고 `untitled_save` owner와 문서·디스크 판정을 추가한다.
제품 입력·저장 소스는 바꾸지 않는다. private fixture만 새 문서·본문·사유 root를 준비한다.

```sh
python3 tools/untitled-save-ime/run.py --output <새 외부 경로> --case hanja
python3 tools/untitled-save-ime/run.py --app <첫 실행 snapshot의 maru-macos-app> --output <새 외부 경로> --case korean
mise exec -- zig build test-untitled-save-ime-oracles test-editor-first-save-async test-editor-untitled test-inline-rename-ime -j2
```

`--case`는 `hanja`, `korean`, `cancel`, `overwrite`, `reject`, `write-failure`다.
한글/한자 파일명은 확장자 없이 실제 키로만 입력한다. 한자 장면은 후보 취소 후 다시 열어 선택하고,
후보 Return 뒤에도 문서가 이름 없음·dirty·pending=0인지 확인한 다음 별도 Enter로 저장한다.
일반 한글 장면도 조합 확정 Return과 저장 확정 Return을 구분한다.
`cancel`은 이름 입력 취소, `reject`는 기존 목적지 덮어쓰기 거부다.
`write-failure`는 테스트 전용 `project` 폴더만 일시적으로 읽기/탐색 가능하게 두어 실제 쓰기 오류를
재현한다. 실행의 finally에서 이 사유 폴더의 권한을 복원한다. 사용자 폴더 권한은 바꾸지 않는다.

`--capture-app` 기본값은 이미 허용한 `~/Applications/Maru Screen Capture.app`이다.
화면 캡처 도구는 재빌드하지 않는다. 실제 후보 창·앱 창 ID와 캡처 소유 PID·PNG 해시를 기록한다.
픽셀은 직접 확인할 수 있는 PNG로 남기며 **후보 OCR·공용 5-window reducer 통과를 주장하지 않는다**.
물리 키는 기존 별도 HID relay가 foreground·입력 소스·generation을 검사한 뒤 전송한다.

실행 결과는 `run/result.json`, `run/model.json`, `run/project`, `run/captures`, `run/hid-relay.log`와
`validation.json`이다. `first-save-harness.json`과 공용 manifest에 도구·실행 파일 해시를 기록한다.
공용 runner가 사유 `/tmp` root를 생성하지만 저장 root는 실제 `/private/tmp` 경로로 지정한다.
캡처·원시 자료·PNG는 저장소 밖에 보존하며 이미지는 PR 본문에만 올린다.

보관 자료의 독립 재검증:

```sh
python3 - <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, 'tools/untitled-save-ime')
from verify import validate_diagnostic
root = Path('<실행 출력>/run')
print(validate_diagnostic(json.loads((root/'result.json').read_text()), root))
PY
```

정상·손상 대조군은 `test_verify.py`가 검사하며 실제 GUI 실행 횟수로 세지 않는다.
상세 범위와 이전 검증과의 차이는 [계획](../../docs/plans/untitled-first-save-ime-gui.md)을 따른다.
