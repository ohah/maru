# PR 체크리스트

모든 PR은 기능 구현 여부와 상관없이 이 문서의 관점으로 평가한다.

GitHub PR 본문은 `.github/pull_request_template.md`를 사용한다. 이 문서는 템플릿에 들어가는 질문의 기준과 해석을 설명하는 단일 출처다.

## PR 메타데이터 (필수)

모든 PR은 다음을 반드시 갖춘다.

- 라벨: 하나 이상 단다.
- assignee: `ohah`로 지정한다.

```sh
# 새 PR
gh pr create --assignee ohah --label <label> ...
# 이미 만든 PR
gh pr edit <번호> --add-assignee ohah --add-label <label>
```

이 규칙은 `.github/workflows/pr-metadata.yml`가 확인한다. 체크 실패가 실제로 머지를 막으려면 GitHub branch protection에서 `PR metadata / require label and assignee=ohah`를 required check로 지정한다(저장소 설정이라 코드에는 없다).

## 전략 영향 평가

PR 설명에는 다음 질문에 대한 답이 있어야 한다.

```text
이 PR은 기존 Maru 전략을 유지하는가?
아키텍처 경계가 흐려지지 않았는가?
테스트/TDD/E2E 전략에 빈틈이 생기지 않았는가?
로그, snapshot, trace, replay, future inspector가 같은 데이터를 공유하는 방향을 해치지 않았는가?
구현과 문서가 같은 상태를 설명하는가?
새 의존성이 추가되었다면 왜 지금 필요한가?
메모리 전략을 성급하게 복잡하게 만들지 않았는가?
플러그인/확장 경계를 나중에 막지 않는가?
사용자 UX 목표인 가벼운 native shell/workspace 포지션을 해치지 않는가?
VT/parser 동작을 추가·변경했다면 유도한 공개 명세 섹션(ECMA-48, vt100.net DEC parser, xterm ctlseqs)을 인용했는가? (해당 없으면 N/A)
renderer/storage/platform interop를 추가·변경했다면 public spec, platform 문서, 또는 독립 설계 문서에서 유도했는가? (해당 없으면 N/A)
reference terminal의 코드 표현(자료구조 레이아웃, 함수 분해, control flow)을 옮기지 않았는가?
```

## 전략 수정 규칙

PR을 만들거나 리뷰하는 중 기존 전략을 수정해야 한다고 판단되면, 그 변경은 PR 안에서 임의로 처리하지 않는다.

반드시 사용자와 먼저 논의해야 하는 예시는 다음과 같다.

- Ghostty reference-only 원칙을 바꾸는 경우
- 레퍼런스 코드 표현을 구현 기준으로 삼으려는 경우
- macOS-first 범위를 바꾸는 경우
- 외부 의존성을 핵심 경로에 추가하는 경우
- 테스트/E2E가 불가능한 구조를 받아들이는 경우
- 관측 가능성 모델 없이 기능을 먼저 구현하려는 경우
- 코드가 구현된 뒤 문서가 실제 구조, 명령, 테스트 경로, artifact 포맷과 달라지는 경우
- 메모리 전략을 `std.mem.Allocator` 중심에서 외부 allocator 중심으로 바꾸는 경우
- plugin/extension boundary를 앞당기거나 늦추는 경우
- 실제 구현이 문서화된 전략과 달라지는 경우
- 예상하지 못한 플랫폼, 렌더러, PTY, parser, 테스트 자동화 한계가 드러나는 경우
- 구현에 필요한 결정이 설계 문서에 없고, 그 결정이 아키텍처, UX, 의존성, 테스트, 보안, 데이터 포맷, plugin boundary에 영향을 주는 경우

## PR 설명 필수 항목

```text
의도:
  이 PR이 해결하려는 문제

구현:
  어떤 책임 영역을 변경했는지

문서 정합성:
  관련 문서를 함께 수정했는지, 수정하지 않았다면 왜 필요 없었는지

clean-room 근거:
  구현 근거가 "공개 명세/platform 문서 유도", "Maru 독립 설계", "동작 비교만 reference 사용" 중 무엇인지. 해당 없으면 N/A

전략 영향 평가:
  기존 전략과 충돌하는 부분이 있는지

테스트:
  실행한 명령과 결과

E2E/관측 가능성:
  어떤 snapshot, trace, replay, artifact 경로가 있는지

한계:
  자동 검증이 안 된 영역, 실제 구현 중 발견한 한계, 수동 검증 방법

사용자 논의 필요 여부:
  전략 수정이 필요한지, 문서에 없는 결정을 사용자와 논의했는지, 발견한 한계를 사용자와 논의했는지
```

## 서술 수준과 다이어그램 (필수)

PR 본문은 **최대한 자세히** 적는다. 리뷰어가 변경 코드를 직접 열지 않고도 "무엇을·왜·어떻게" 바꿨는지 본문만으로 재구성할 수 있어야 한다.

- 위 9개 항목을 **전부** 채우고 축약하지 않는다. 해당 없는 항목도 비워 두지 말고 `N/A`로 명시하고 그 이유를 적는다.
- 변경한 파일·함수·타입·ABI 버전을 **실제 식별자 이름**으로 짚고, 핵심 분기·불변식·엣지 케이스·실패 경로를 글로 설명한다.
- 동작을 바꿨다면 **Before → After**를 대비해 적는다. 근거가 캡처/실측이면 그 값(시퀀스 바이트, 메트릭, PTY 캡처 등)을 그대로 인용한다("추측 말고 캡처").
- VT/parser·키 입력을 추가·변경했다면 유도한 공개 명세 섹션(ECMA-48, xterm ctlseqs, vt100.net DEC parser)을 인용하고 clean-room 근거와 연결한다.

**Mermaid 다이어그램을 가능하면 포함한다.** 글로만 설명하기 어려운 구조·흐름·상태 전이는 GitHub가 렌더링하는 ` ```mermaid ` 코드블록으로 그린다. 다이어그램이 설명을 더 명확하게 하는 경우가 사실상 대부분이므로, **넣지 못할 명확한 이유가 없으면 넣는 것을 기본**으로 한다. 종류는 내용에 맞게 고른다:

- **흐름/데이터 경로** (`flowchart`): 키 입력→인코딩→ABI→PTY 같은 파이프라인, 컴포넌트·facade 경계, 분기 결정 트리.
- **시퀀스** (`sequenceDiagram`): Swift↔Zig ABI 호출 순서, IME 트랜잭션(begin/insert/marked/end), `close → reader.join → deinit` 수명, login(1) 래핑 spawn 경로.
- **상태 머신** (`stateDiagram-v2`): 모드 전환(DECCKM·alt screen·DEC mode 2027), preedit/조합 상태, autowrap pending_wrap, 셀렉션/드래그 자동 스크롤.

다이어그램 노드는 **코드의 실제 식별자**(함수·타입·ABI 버전·escape 시퀀스)를 이름으로 써서 본문 설명과 1:1로 대응시킨다. 장식이 아니라 리뷰를 돕는 설명이어야 한다 — 다이어그램만 넣고 본문 서술을 줄이지 않는다.
