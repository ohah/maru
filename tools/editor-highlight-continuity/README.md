# 비동기 강조의 대기 프레임

`capture.py`는 지정한 이전 커밋과 현재 작업 트리를 별도 외부 사본에 둔다.
`PaneFixture.initWithSyntax`로 실제 비동기 문서를 만들고 `insertText` 뒤 완료 전달 전에
`appendPaneFrame → CoreTextFrameBuilder → Metal`로 대기 화면을 촬영한다.
색을 유지하려고 worker를 느리게 하거나 제품의 트리를 보관하지 않는다.

```sh
python3 tools/editor-highlight-continuity/capture.py \
  --output /absolute/new/evidence \
  --baseline cdb01f1246160932fb27a89df5b8e0a2632fa1a0 \
  --deps /absolute/existing/zig-pkg --cache /absolute/cache
```

기본 어두운 테마, 800×480에서 함수 이름에 ASCII 한 글자를 넣는다.
첫 프레임의 헤더 배치와 caret을 고정한 뒤 ready/pending/completed PNG와 PPM을 남긴다.
입력 전과 완료 후 PNG가 각각 이전/후보에서 동일하고, 대기 PNG만 다른지 검사한다.
각 사본의 원본/계측 src 해시·build 해시·빌드 로그를 보존한다.

이는 제품 렌더와 native 편집 경로의 픽셀 증거다. 실제 AppKit 키 입력·IME·화면 표시 시각이나
연속 영상은 별도 검증이며 이 캡처로 첫 표시 지연이나 전력 개선을 주장하지 않는다.

`test-editor-syntax-paint`는 편집 위치와 신원 검증을, `test-editor-parse-input`은 공유 뷰·
본문/미니맵·실패 중단·Undo·현재 완료와 cold parse 일치를 검사한다.
표시 배열의 주소와 capacity를 비교하여 보정 자체에 할당이 추가되지 않는지도 확인한다.
