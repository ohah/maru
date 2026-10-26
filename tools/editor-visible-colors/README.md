# 본문 색 조회 범위 재현

이 도구의 결과표는 #4600의 메인 `711591ffa` 기준이다. 후속 제품은 일반 본문에 표시 예산을
넘긴다. 이 도구의 직접 `syntaxColors` 호출은 `null`로 기존 창을 골라 고정 256줄과 후보의
함수 범위를 비교하며, 현재 제품 프레임의 실제 조회량으로 해석하지 않는다. 현재 표시 행과의
대조는 `test-editor-visible-color-window`를 사용한다.

제품 소스를 바꾸지 않고 별도 사본에 `query.zig.inc`를 추가한다. macOS·Zig 0.17과
현재 저장소의 잠긴 `zig-pkg` 의존성이 필요하다. 출력은 저장소 밖의 새 디렉터리여야 한다.

```sh
python3 tools/editor-visible-colors/reproduce.py --output /tmp/maru-visible-colors-new --deps "$PWD/zig-pkg"
python3 tools/editor-visible-colors/analyze.py /tmp/maru-visible-colors-new
python3 -m unittest discover -s tools/editor-visible-colors -p 'test_*.py'
```

실제 `PaneFixture`, `editorBodyRect`, `syntaxColors`와 `lineColorsInto`를 호출한다.
화면 크기마다 현재 색과 동일 범위 재조회, 남은 문서 전체 조회의 앞부분, 화면 높이 기반 후보를
값으로 대조한다. 같은 색 알고리즘의 범위 대조이며 독립 문법 정확성 oracle은 아니다.
색 배열은 렌더 축의 절대 줄로 색인한다. 앞쪽 빈 슬롯을 조회 행 수에 포함하지 않는다.

각 파일은 별도 프로세스에서 세 높이를 실행한다. 높이마다 기존·후보를 번갈아 6쌍,
각 32호출로 재사용 버퍼의 함수 경과시간을 잰다. 프로세스 반복·정확성 전용 패스·GUI 입력
측정이 아니므로 이전 입력 지연 분포와 빼거나 더하지 않는다. 준비 빌드의 실행은 표본에서 제외한다.

`result.json`은 모든 실행과 소스·입력·실행 파일 해시 대조가 끝나야 생성된다.
분석기는 근거 파일 해시와 파일/높이/표본 모집단·좌표·색 대조 성공을 검사한다.
실패 출력은 보존하고 수정한 재실행에는 새 경로를 쓴다. 완료 자료의 실행 파일은 캐시 밖에도 보존한다.

현재 결과와 후속 제품 채택 조건은 [계획](../../docs/plans/editor-visible-color-range.md)에 있다.

## 제품 Metal 전후 캡처

```sh
python3 tools/editor-visible-colors/capture.py --output /tmp/maru-color-gpu-new --deps "$PWD/zig-pkg"
```

기준 메인과 현재 소스를 별도 사본에서 촬영한다. 800×4800px·기본 appearance·첫 줄 31의
동일 Zig 원문으로 256행 뒤의 색을 확인한다. 실제 `appendPaneFrame` → CoreText → 제품
Metal 오프스크린 readback이며 GUI/HID/입력기 검증은 아니다. 소스·입력 fixture·실행 파일·
PNG/PPM·로그 해시와 GPU 성공 필드를 남기고, 기존 색이 있던 위쪽 픽셀 보존과 아래쪽의
픽셀 변화도 검사한다. 결과 `result.json`은 모든 검사 성공 후에만 생성된다.

[전후 편집·프레임 실측 결과](results.md)는 함수 미시 비용과 실제 표시 색 대조를 구분한다.
