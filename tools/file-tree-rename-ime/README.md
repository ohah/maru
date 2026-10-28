# 파일 탐색기 이름 변경 IME

첫 저장 GUI 하네스의 source-copy·입력 relay·입력 소스 복원·native 캡처를 재사용한다.
private fixture가 무관한 dirty 문서와 일반 파일 `base`를 준비하고 materialized 파일 행에서
제품 `startFileTreeEdit(.rename)`을 실행한다. 이후 파일명 입력은 실제 OS 키를 사용한다.

```sh
python3 tools/file-tree-rename-ime/run.py --output <새 외부 경로> --case hanja
python3 tools/file-tree-rename-ime/run.py --app <첫 실행 snapshot의 maru-macos-app> --output <새 외부 경로> --case collision
mise exec -- zig build test-file-tree-model test-file-tree-rename-ime-oracles -j2
```

`--case`는 `hanja`, `korean`, `cancel`, `collision`, `write-failure`다.
후보 선택/취소 Return 뒤에는 `base`를 유지하고, 별도 Enter 뒤에만 `base韓`/`base한`으로 변경한다.
취소·충돌·권한 오류는 원본을 보존하고, 충돌은 기존 목적지를 덮지 않는다.
성공은 새 트리 선택·pending 정산·동일 device/inode·실제 bytes로 판정한다.

`--capture-app` 기본값은 이미 허용한 `~/Applications/Maru Screen Capture.app`이다.
캡처 도구는 재빌드하지 않는다. 후보/이름 입력 창의 ID·소유 PID·PNG 해시를 기록한다.
창 연결·IHDR 크기·해시와 실제 이미지 확인을 사용하며 후보 OCR이나 공용 five-window reducer
통과를 주장하지 않는다. 원격·디렉터리·열린 문서 remap·VoiceOver도 이 도구 범위 밖이다.

실제 root의 `setup.json`·`before-commit.json`·`after-identity.json`은 실행 전/확정 전/완료 뒤
원본 identity와 bytes의 증거다. live 검사기는 원래 파일의 stat를 직접 대조한다.
`run/`은 증거 복사본이므로 inode가 달라진다. 복사본 독립 검증은 원본 identity 기록과 복사된
bytes/hash를 대조하며, 복사본 inode를 원본 inode로 간주하지 않는다.
공용 `first-save-harness.json`은 재사용한 runner의 해시, `file-tree-harness.json`은 이 장면의
fixture·driver·verifier 해시를 기록한다. `private-root.txt`는 보존된 원래 root를 가리킨다.

```sh
python3 - <<'PY'
import json, sys
from pathlib import Path
sys.path.insert(0, 'tools/file-tree-rename-ime')
from verify import validate_diagnostic
root = Path('<출력 경로>/run')
print(validate_diagnostic(json.loads((root/'result.json').read_text()), root))
PY
```

권한 오류는 오직 사유 `project` 폴더의 쓰기 권한을 잠시 제거해 재현하며 finally에서 복원한다.
사용자 문서·설정·폴더 권한은 바꾸지 않는다. PNG/원시 자료는 저장소 밖에 보존하고 이미지는
PR 본문에만 업로드한다. 발견한 선택 유실과 수정·실패 증거는 [계획](../../docs/plans/file-tree-rename-ime-gui.md)을 따른다.
