# VS Code 방향의 편집기 검색 판정

상태: **2026-10-06 사용자 승인, 구현·집중 자동 검증 완료.** 이전 검색 계약과 현재 변경을 구분한다.
새 런타임 의존성·프로젝트 검색 worker·도크의 채택을 뜻하지 않는다.

## 승인된 변경

단어 옵션은 더블클릭 낱말과의 정확한 동일성이 아니라 **매치 양끝의 경계**를 검사한다.
VS Code 기본 구분자 정책을 참고해 ASCII 문장부호(`_` 제외), space·tab을 구분자로 사용한다.
구체적인 문장부호는 `` ` ~ ! @ # $ % ^ & * ( ) - = + [ { ] } \ | ; : ' " , . < > / ? ``다.
이 설정 문자열은 공개 기본값의 데이터이며 구현 코드 표현을 옮기지 않는다.

- 문서 시작/끝 또는 매치 바깥의 구분자·CR/LF가 경계다.
- 매치 자체의 첫/마지막 문자가 구분자여도 해당 끝의 경계를 인정한다.
- 따라서 `foo$bar`의 `foo`, `foo bar` 전체, `--`의 각 `-`는 단어 검색에 걸린다.
- `_`·한글·emoji·NBSP는 기본 구분자가 아니다. `foo_bar`·`한foo글`·`foo😀bar`·`foo bar`의 `foo`는 걸리지 않는다.
- 여러 줄 정규식도 전체 매치의 양끝이 경계이면 허용한다. 한 논리 줄/단일 낱말 제한을 제거한다.
- 더블클릭·단어 이동·다음 occurrence의 선택 규칙은 별도 기능이다. 그 tokenizer를 검색 때문에 바꾸지 않는다.
- 설정 GUI의 사용자 지정 word separators는 이번 범위에 추가하지 않는다. 기본값에 대한 호환 정책이다.

정규식은 엔진이 먼저 반환한 대안을 사용한다. `^|foo`는 길이 0인 시작 위치, `foo|^`는 `foo`를 반환한다.
빈 일치에서 같은 위치의 비어 있지 않은 대안을 다시 고르는 기존 호출자 정책을 제거한다.
빈 일치 뒤에는 다음 Unicode 코드포인트로 진행하고 EOF에서는 끝낸다.
소비한 일치가 subject 끝에 도달하면 그 끝에서 추가 빈 일치를 반환하지 않는다(`foo|$`는 `foo` 1건).
빈 subject의 `^$`는 1건이고, 빈 검색 입력은 검색을 실행하지 않아 0건이다.
치환은 보고한 동일 범위를 재사용해 빈 일치의 경우 삽입하며 주변 글자를 소비하지 않는다.

## 유지하는 문서 계약과 경계

원문 UTF-8, BOM 처리, PCRE2의 문서 전체 MULTILINE·ANYCRLF·ALT_CIRCUMFLEX, Unicode 17 평문 접기는 유지한다.
VS Code의 JavaScript 정규식 문법/모델 LF 정규화를 전부 복제하지 않는다. lookaround·역참조·PCRE2 고유 문법은
기존 계약이다. 이 변경으로 rg 전체 검색과 모든 빈 파일/EOF/Unicode 범위가 같아진다고 주장하지 않는다.
터미널 코어 자체의 정규식 순회 계약은 이번 편집기 변경과 구분한다.

## 근거와 검증

VS Code의 commit `24a41178148f72f49e4ac0756ddb3b5347429a91`에서
[기본 단어 구분자](https://github.com/microsoft/vscode/blob/24a41178148f72f49e4ac0756ddb3b5347429a91/src/vs/editor/common/core/wordHelper.ts#L10),
[검색 양끝 판정과 빈 일치 순회](https://github.com/microsoft/vscode/blob/24a41178148f72f49e4ac0756ddb3b5347429a91/src/vs/editor/common/model/textModelSearch.ts#L431-L551)를 확인했다.
MIT reference는 `references/vscode/search-policy/`에서 읽기 전용으로만 보며 구현 코드 표현을 복사하지 않는다.
Maru 구현은 위 입력/출력 계약으로 독립 작성하고 PCRE2의 기존 공개 API를 호출한다.

`FND40~41`은 기본 구분자·Unicode 비구분자·여러 줄·대안 순서·Unicode 빈 일치 진행·EOF·치환을 고정한다.
기존 찾기·치환·공유 뷰·Undo 검증과 전체 범위 대조를 유지한다. 프로젝트 검색 도구의 예전 반례는
정책 변경 전 기록으로 보존하고 현재 비교 산출물은 별도로 만든다.

실제 VS Code Searcher와 공통 문법·단일 줄·기본 구분자 1,380조합의 byte 범위가 모두 일치했다.
단어 필터에서 거절된 마지막 소비 매치 뒤 빈 EOF를 추가하는 변형은 실제 오라클에서 실패했고 수정 후 통과했다.
`EDREG5`는 단일/전체 치환에서 `^|foo`가 `foo`를 지우지 않고 `Xfoo`로 삽입하며 Undo로 복원함을 확인한다.
제품 Metal의 `word` 시나리오는 `$` 경계·독립 낱말의 강조와 emoji/underscore 안의 비강조를 실제 픽셀로 대조한다.
여러 프로세스의 독립 프레임이며 OS 키 입력이나 하나의 분할 창 전체 촬영은 아니다.
[검증 기록](../../tools/editor-project-search/results/vscode-search-policy-macos-arm64.json)을 보존한다.

```sh
mise exec -- zig build test-editor-document-regex -Doptimize=ReleaseFast
mise exec -- zig build editor-project-search-probe -Doptimize=ReleaseFast
node tools/editor-project-search/vscode-oracle.mjs \
  zig-out/bin/maru-project-search-probe references/vscode/search-policy/textModelSearch.ts \
  zig-out/vscode-search-oracle-<새이름>
python3 tools/shared-ime-gpu/capture.py --scenario word --output zig-out/vscode-search-word-<새이름>
```

오라클은 명시한 read-only reference를 Node 24+에서 변환 실행하는 opt-in 도구다.
reference 소스를 자동 설치하거나 기본 CI/제품 의존성으로 추가하지 않는다.
