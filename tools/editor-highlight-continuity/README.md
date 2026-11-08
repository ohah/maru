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

## 메인 실행 검증

`prepare_ime.py --build <검증된 stream 빌드> --output <새 외부 경로> --cache <외부 cache>`는
고정 사본에서만 provider 설정 쓰기 격리와 Redo·두 번째 Undo 검사, 단계별 앱 Metal readback을 넣는다.
기존 사본이나 설치된 앱을 덮어쓰지 않는다. 이 촬영 앱은 지연 측정에 사용하지 않는다.

실행은 `tools/test-macos-editor-ime.sh`의 `document.txt`만 외부 사본에서 `document.zig`로
바꾸어 같은 텍스트를 지원 문법의 일반 비동기 경로로 연다. 출력 디렉터리에 `frames`를 만든 뒤
`MARU_HIGHLIGHT_APP_CAPTURE=1 MARU_HIGHLIGHT_APP_CAPTURE_ROOT=<절대 frames 경로>`를 넘긴다.
script의 마지막 인자 `0`은 직접 native callback, `1`은 실제 두벌식, `3`은 공유 소유자 전환이다.
성공 판단은 summary의 `failure_count=0`과 기존 script의 저장 bytes 비교가 함께 통과해야 한다.
실제 OS 입력의 callback 종류도 summary에 남으며 직접 marked 호출과 섞지 않는다.

`paired.py --before <수정 전 stream 빌드> --after <메인 stream 빌드> --output <새 외부 경로>`는
5만 함수·50/100ms·일반/공유 뷰·3개 독립 프로세스 반복을 버전별로 수집한다.
반복마다 버전 순서를 교대하고 첫 입력을 포함한다. 최초 오류에서 중단하고 원시 기록을 보존한다.
전체 행렬이 완성되기 전에는 summary를 만들지 않는다. 완료하면 기존 검증기와 24개 독립 손상·
정상 전후 대조를 실행한다. 입력 소스·전면 앱·물리 modifier·문서·실행 파일 신원 검사를 완화하지 않는다.

현재 결과는 `live-results.json`과 [표시 연속성 계획](../../docs/plans/editor-highlight-continuity.md)이 소유한다.
기능 검증은 통과했다. 두 비교 수집은 각각 전면 포커스 전환·물리 modifier로 중단되어 제외했다.
별도 세 번째 수집은 전체 24프로세스·720입력과 판정자 손상 검사를 통과했다.
성공 pilot을 전체 행렬의 대체 결과로 사용하거나, 계측 포함 관측치를 제품 고유/광학 지연으로 확대하지 않는다.
이 표본에서 일관된 지연 개선은 확인하지 못했다.
