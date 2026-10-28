# 심볼 이름 변경의 실제 IME GUI

기존 name-input GUI launcher·HID relay·입력 소스 복원·native 캡처를 재사용한다.
기존 `tools/fake_lsp.zig`를 별도 서버 프로세스로 실행하고 proxy가 JSON-RPC를 바꾸지 않고 기록한다.
**제어용 서버 증거이며 실제 Rust/Go SDK 증거가 아니다.** 실제 SDK의 별도 headless 범위는
[기존 rename 도구](../editor-lsp-real/rename.md)를 따른다.

```sh
python3 tools/symbol-rename-ime/run.py --output <새 외부 경로> --case hanja
python3 tools/symbol-rename-ime/run.py --app <첫 실행 snapshot의 maru-macos-app> --output <새 외부 경로> --case stale
mise exec -- zig build test-symbol-rename-ime-oracles test-editor-workspace-edit test-inline-rename-ime -j2
```

`--case`는 `hanja`, `korean`, `cancel`, `server-error`, `stale`다.
첫 실행은 사본 앱을 빌드한다. `--app`으로 고정 앱을 재사용해도 서버는 현재 source에서 별도 빌드한다.
한자는 `changes`/UTF-8, 한글은 `documentChanges`/UTF-16 제어 응답을 사용한다. 범위 자체는 ASCII
원문 위이며 일반 Unicode 위치 전체를 검증했다고 말하지 않는다. 입력한 newName은 실제 한글/한자다.

fixture가 자체 `.git` root·`main.c`·닫힌 `other.c`와 서버를 준비한다. 자체 root의 신뢰 준비는 기존
기본 취소·명시적 재확인 절차를 따르며, 사용자 신뢰 UX를 물리 키로 승인한 증거로 세지 않는다.
프로필 HOME/config/trust·서버·proxy·bootstrap stderr를 모두 사유 경로에 둔다.

후보 취소/선택 Return 뒤 송신 수 0·본문/version 불변, 별도 Enter 뒤 정확한 newName 한 건을
검사한다. 성공은 두 파일 적용/저장과 열린 버퍼의 Undo 이력, 이후 제품 `undo_workspace_edit`
명령으로 두 파일을 복원한 결과를 확인한다. Workspace Undo는 inverse 편집이므로 일반 문서의
Undo 이력 항목을 추가한다. 로컬 Undo 키로 이력을 0으로 만드는 것과 혼동하지 않는다.
`stale`의 문서 변경과 Workspace Undo 실행은 명시적인 fixture 동작이며 물리 사용자 입력이 아니다.

`--capture-app`은 기본적으로 이미 허용한 `~/Applications/Maru Screen Capture.app`을 사용한다.
캡처 앱은 재빌드하지 않는다. 창 ID·소유 PID·PNG hash/크기와 실제 이미지 확인은 포함하지만
후보 OCR·five-window reducer·VoiceOver는 이 도구의 성공 조건이 아니다.

`run/result.json`, `run/applied.json`(성공만), `run/model.json`, `run/wire.ndjson`, 실제 `run/project`
파일을 독립 대조한다. 닫힌 파일이 열리지 않고, 취소·stale는 요청 0건, 서버 오류는 요청/오류 응답
1건 및 두 파일 보존이어야 한다. `symbol-harness.json`과 공용 manifest는 도구/서버/실행 파일 해시를
보존한다. 출력·PNG는 저장소 밖에 두며 이미지는 PR 본문에만 업로드한다.

```sh
python3 - <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, 'tools/symbol-rename-ime')
from verify import validate_diagnostic
root = Path('<출력 경로>/run')
print(validate_diagnostic(json.loads((root/'result.json').read_text()), root))
PY
```

합성 기록 손상 및 검사기 판정 제거 사본은 실제 GUI나 제품 결함 주입으로 세지 않는다.
상세 계획·실행 결과와 한계는 [계획](../../docs/plans/symbol-rename-ime-gui.md)을 따른다.
