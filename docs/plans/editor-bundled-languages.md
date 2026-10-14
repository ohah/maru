# 번들 언어 확대 계획

상태: 계획(2026-10-14 사용자 결정 — 후보 열둘 전부). 번들 언어 목록·크기는 [네이티브 계획](native-editor.md)의 「번들 언어 목록」이, 라이선스 동봉은 [제3자 라이선스](../third-party-licenses.md)가 소유한다. 이 문서는 후보 실측·결정·배선 설계·조각·검증을 소유한다.

## 왜

[잔여 점검](editor-remaining-work.md)의 「번들 언어 확대」다. grammar 가 없는 확장자는 무색이고(§5) 구문 트리 위의 기능이 전부 빠진다. 빠지는 것은 다음과 같다.
- 접힘·심볼·괄호 색
- 타이핑 규칙의 문맥([들여쓰기·자동 닫기](editor-typing-rules.md) TR4)

사용자 워크스페이스(`~/Documents/workspace` 의 git 저장소 전부, 2026-10-14)에서 grammar 없는 확장자를 셌다.
- 많은 쪽: `.swift` 263 · `.yml`/`.yaml` 181 · `.toml` 125 · `.xml`/`.plist` 99 · `.m` 81
- 이름만 있는 파일: `Makefile`·`Dockerfile`

## 실측 — 후보 열둘 (2026-10-14)

전부 MIT 다. 생성 파서의 ABI 는 14·15 로, 우리 코어(tree-sitter 0.26.13 — 13~15 를 받는다)와 맞는다. 스캐너는 전부 C 다(C++ 없음). 우리 플래그(`-std=c11 -fno-sanitize=undefined`)로 다 컴파일된다. 크기는 기존 표와 같은 방법(`zig build-obj -OReleaseFast`, 파서 + 스캐너)으로 쟀고, 그 방법은 기존 JSON 20KB·Go 266KB 로 맞춰 봤다.

| 언어 | grammar | 고정할 판 | 크기 | 특이점 |
| --- | --- | --- | --- | --- |
| YAML | `tree-sitter-grammars/tree-sitter-yaml` | v0.7.2 | 277KB | 스캐너가 `schema.core.c` 를 include(tarball 안) |
| TOML | `tree-sitter-grammars/tree-sitter-toml` | v0.7.0 | 59KB | — |
| XML · DTD | `tree-sitter-grammars/tree-sitter-xml` | v0.7.0 | 110KB + 74KB | 한 저장소 두 grammar(`xml/src`·`dtd/src`), 쿼리가 `queries/xml/`·`queries/dtd/` |
| Lua | `tree-sitter-grammars/tree-sitter-lua` | v0.5.0 | 103KB | 라이선스 파일이 `LICENSE.md` |
| Dockerfile | `camdencheek/tree-sitter-dockerfile` | v0.2.0 | 107KB | 확장자 없는 파일 이름 |
| Make | `tree-sitter-grammars/tree-sitter-make` | v1.1.1 | 212KB | 확장자 없는 파일 이름, 스캐너 없음 |
| Swift | `alex-pinkus/tree-sitter-swift` | `0.7.4-with-generated-files` | 4393KB | 기본 태그에는 생성 파서가 없다(저장소 방침) — 생성 파일이 든 태그로 고정 |
| SQL | `DerekStride/tree-sitter-sql` | v0.3.11 **release asset** | 2576KB | 태그 tarball 에는 생성 파서가 없다 — release asset(최상위 폴더 없음) |
| Dart | `UserNobody14/tree-sitter-dart` | 커밋 `3f0c7a8309d8` | 1290KB | 태그·릴리스가 없다 — 커밋 archive 로 고정 |
| C# | `tree-sitter/tree-sitter-c-sharp` | v0.23.5 | 5319KB | 진입점 `tree_sitter_c_sharp` |
| Objective-C | `tree-sitter-grammars/tree-sitter-objc` | v3.0.2 | 5329KB | 쿼리가 `; inherits: c` — C 쿼리를 앞에 잇는다(C++ 와 같다) |
| Scala | `tree-sitter/tree-sitter-scala` | v0.26.2 | 4064KB | — |

- 합계는 약 23.4MB 다. 작은 여섯은 0.9MB, Swift 4.4MB, SQL·Dart 3.9MB, C#·Objective-C·Scala 14.7MB 다.
- 지금 번들은 실측 약 22.2MB 다. 그래서 늘어난 뒤 object 합은 약 45.6MB 가 된다. 링크·strip 전 값이라 `.app` 증가분의 상한으로 읽는다.
- **기존 표의 Kotlin 「0KB」는 틀렸다** — 같은 방법으로 4108KB 다(합계 17.7MB 도 Kotlin 을 뺀 값이었다). BL1 이 고친다.
- **쿼리 대조(정적)**: 쿼리마다 노드·필드 이름과 따옴표 낱말을 파서의 `ts_symbol_names`·`ts_field_names` 와 맞대 봤다. 열셋 모두 깨끗했다(Objective-C 는 C 쿼리를 앞에 이은 것으로). 구조 오류는 정적 대조가 못 잡으므로 실제 `ts_query_new` 판정자가 조각마다 잡는다(쿼리가 깨지면 그 언어만 조용히 무색이다).
- **색 표에 없는 capture**: `syntax_capture` 표가 모르는 이름이 있다. 그대로 두면 그 자리는 무색이다.
  - `markup.*`(XML·DTD)
  - `field`·`method`·`method.call`·`preproc`·`storageclass`(Lua·SQL·Objective-C·Scala)
  - `clean`·`text.*`(Make)
  - `identifier.constant`·`identifier.parameter`(Dart)

## 결정 (2026-10-14 사용자)

- **후보 열둘을 다 싣는다**(작은 여섯 · Swift · SQL·Dart · C#·Objective-C·Scala) — 크기 표를 보고 정했다.
- 고정은 기존과 같이 tarball URL + hash(`build.zig.zon`)다. 생성 파서가 기본 태그에 없는 판(Swift·SQL)은 생성 파일이 든 태그·release asset 을 쓴다. 태그가 없는 판(Dart)은 커밋 archive 를 쓴다.

## 설계

### 언어 하나를 더하는 자리

표 주도다(2026-08-29 열일곱을 실을 때 세운 구조). 아래 표가 같은 목록을 따른다. 하나만 빠지면 그 언어만 조용히 무색이거나 규칙이 빠진다. 그래서 `languageFor` 의 컴파일 오류와 판정자가 묶는다.

| 자리 | 하는 일 |
| --- | --- |
| `build.zig.zon` | tarball URL·hash |
| `build.zig` grammar 표 | `src`·`scanner`·`queries`·`import`, **라이선스 경로**(새 필드 — Lua 가 `LICENSE.md`) |
| `syntax/tree_sitter.zig` | 진입점 `extern`·쿼리 `@embedFile`·`Language` 열거·`Slot`(접힘·심볼 노드 종류)·`bracketRuleFor` |
| `session/editor/language.zig` | `Grammar` 열거·`grammarForPath`(**파일 이름도 본다** — `Dockerfile`·`Containerfile`·`Makefile`·`GNUmakefile`)·`displayName`·`stringQuotes`·`lineComment`·`bracketEnterAnywhere` |
| `session/syntax_capture.zig` | 새 capture 이름 → 색 역할(점 접두 폴백을 먼저 본다 — `method.call` 은 `method` 로, `markup.heading` 은 Markdown 과 같은 역할로) |
| 타이핑 규칙(`enter_rules`·`typing_ops`·`indent_guides`·`guides`) | 블록 주석 이어쓰기 문법·언어 규칙·낱말 내어쓰기·언어 기본 들여쓰기·offSide |
| `docs/third-party-licenses.md`·네이티브 계획의 번들 표 | 라이선스 행·크기 행 |

언어 서버 후보(`session/lsp/servers.zig`)는 이 계획 밖이다. 예컨대 Swift 의 `sourcekit-lsp` 는 번들과 별개로 「언어 서버 확대」에서 다룬다.

### 언어별 규칙 — VS Code 내장 언어 설정(핀 커밋 `faa67179693e`)의 동작을 따른다

| 언어 | 확장자·이름 | 줄 주석 | 블록 주석 이어쓰기 | 따옴표(줄 스캐너) | 「어디든」 | Enter 언어 규칙 | 낱말 내어쓰기 | 들여쓰기 기본·offSide |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| YAML | `yml` `yaml` | `#` | — | `"'` | 아니오 | `key:`·`- ` 뒤 한 단계(VS Code `increaseIndentPattern` — 원문의 `&amp;` 오타는 따르지 않고 앵커 `&a` 를 받는다) | — | 공백 2(VS Code `[yaml]`) · offSide |
| TOML | `toml` | `#` | — | `"'` | 예 | — | — | — |
| XML · DTD | `xml` `plist` `svg` `xsd` `xsl` `xslt` · `dtd` | — | — | 없음(HTML 과 같다 — 본문의 아포스트로피) | 아니오 | 여는 태그 뒤(HTML 규칙을 같이 쓴다) | — | — |
| Lua | `lua` | `--` | — | `"'` | 예 | `function`·`then`·`do`·`repeat`·`else` 뒤, 줄 끝 `{` 뒤 한 단계(VS Code `increaseIndentPattern`) | `end`·`else`·`elseif`·`until`(VS Code `decreaseIndentPattern`) | — |
| Dockerfile | `Dockerfile` `Containerfile` `*.dockerfile` | `#` | — | `"'` | 아니오 | — (VS Code 설정은 YAML 것을 베낀 꼴이라 Dockerfile 에 맞지 않는다 — 「의도한 차이」) | — | — |
| Make | `Makefile` `GNUmakefile` `makefile` `*.mk` | `#` | — | 없음 | 아니오 | — | — | 탭(지금처럼 — 경로 대신 문법으로) |
| Swift | `swift` | `//` | 예 | `"` | 예 | `case …:`·`default:` 뒤 | — | — |
| SQL | `sql` | `--` | 예 | `'"` | 예 | — | — | offSide(VS Code `folding.offSide`) |
| Dart | `dart` | `//` | 예 | `"'` | 예 | `case …:`·`default:` 뒤 | — | — |
| C# | `cs` `csx` | `//`(+ `///` 문서 주석은 `/// ` 로 잇는다 — VS Code csharp `onEnterRules`) | 예 | `"'` | 예 | `case …:`·`default:` 뒤 | — | — |
| Objective-C | `m` | `//` | 예 | `"'` | 예 | `case …:`·`default:` 뒤 | — | — |
| Scala | `scala` `sc` `sbt` | `//` | 예 | `"'` | 예 | — | — | — |

- **자동 닫기의 문맥 제외**는 기존 규칙 하나다. 따옴표는 문자열 안이면 닫지 않고, `'`·`` ` `` 는 주석 안에서도 닫지 않는다([들여쓰기·자동 닫기](editor-typing-rules.md) TR4). 새 언어도 따로 두지 않는다.
- `.mm`(Objective-C++)은 싣지 않는다 — objc grammar 는 C++ 를 모른다. `.h` 는 지금처럼 C 다(확장자로 못 가른다).
- **VS Code 대조 판정자**(`INDR1`)의 말뭉치를 VS Code 에 내장 설정이 있는 언어로 넓힌다 — YAML·Lua·SQL·Dockerfile·Make·XML·Swift·C#·Objective-C. Dart·Scala 는 VS Code 내장이 없어(확장) 대조하지 않는다. 갈리는 것은 「의도한 차이」 목록에 이유와 함께 둔다.

## 조각

| 조각 | 내용 | 상태 |
| --- | --- | --- |
| BL1 | 배선 기반과 작은 여섯을 함께 싣는다. <br>· 기반: 라이선스 경로 필드, 파일 이름 판정, 한 저장소 두 grammar(XML·DTD), 새 capture 의 색 역할, Kotlin 크기 행 정정. <br>· 언어: YAML·TOML·XML·DTD·Lua·Dockerfile·Make — 규칙 표·VS Code 대조·판정자까지. | 계획 |
| BLP | **쿼리 술어 평가** — `#eq?`·`#any-of?`·`#match?`·`#lua-match?`(와 `not-` 갈래)를 평가해 조건이 안 맞는 캡처를 버린다(아래 「BL1 이 드러낸 것」) | 계획 |
| BL2 | Swift(생성 파일 태그) | 계획 |
| BL3 | SQL(release asset)·Dart(커밋 고정) | 계획 |
| BL4 | C#(`///` 이어쓰기)·Objective-C(C 쿼리 상속)·Scala | 계획 |

조각마다 같은 완료 조건이다.
- 쿼리가 실제 `ts_query_new` 를 통과한다.
- 언어마다 대표 원문에 색·접힘·심볼이 선다(기존 `SYN*` 표에 행).
- 라이선스가 번들에 들어간다.
- 크기 표를 갱신한다.

## BL1 이 드러낸 것 — 술어 미평가가 기존 언어의 식별자를 칠한다 (2026-10-14 실측)

우리는 쿼리 술어(`#match?` 등)를 평가하지 않는다. 그래서 그 패턴이 **조건 없이** 걸리고, 겹친 캡처는 마지막이 이긴다(§5.3). 새 grammar 의 캡처를 실제 트리로 찍어 보니 이것이 **기존 언어에서 이미** 보이는 결함이었다.
- **Python**: `def f(a): return a.b + c` 의 식별자마다 `variable`·`constructor`·`constant` 가 붙는다. 마지막 `constant` 가 이겨 **모든 식별자가 숫자 색**이다.
- **Ruby**: 식별자마다 `constant.builtin` 이 마지막이라 숫자 색이다.
- **Lua(BL1)**: 같다. 식별자가 `constant`(술어 `^[A-Z][A-Z_0-9]*$`)로 숫자 색이 된다.
- **Make(BL1)**: 낱말마다 `string.regex`(술어 `[%*?]`)가 붙는다.
- Zig·Go 처럼 마지막 패턴이 무색(`variable.builtin`)인 언어만 우연히 옳다.

번들 쿼리의 술어를 전수로 셌다(현재 번들 + BL1). `#match?` 37·`#eq?` 12·`#any-of?` 7·`#lua-match?` 3 이다. 정규식은 31종으로, 전부 작은 부분집합이다(`^`·`$`·묶음과 `|`·문자 묶음 `[A-Z\d_]`·`*`·`+`·`?`·이스케이프). 그래서 PCRE2 를 구문 모듈에 끌어오지 않고 그 부분집합을 평가하는 작은 판정기로 닫는다 — 그것이 BLP 다. BL2(Swift `#match?` 4)·BL4(Scala `#match?` 10) 전에 하는 것이 맞다 — 늘어날수록 이 결함도 는다.

## 한계 (받아들일 것)

- 배포물이 커진다(위 크기 — object 합 약 2 배). 사용자 결정이다.
- BLP 전까지 쿼리의 술어(`#match?` 등)는 평가하지 않는다 — 위 「BL1 이 드러낸 것」.
- Dart 는 태그가 없어 커밋으로 고정한다 — 올리는 기준이 판 번호가 아니다.

## 검증

- 순수: `grammarForPath`(확장자·파일 이름)·언어별 규칙 표(`LANG*`)·Enter 규칙(`INDR*` + VS Code 대조).
- 구문: 언어마다 실제 트리로 색·접힘·심볼(`SYN*`)·괄호 규칙.
- 제품 경로: 새 언어 파일을 열어 색이 뜨고 타이핑 규칙이 타는 실제 키 판정자.
- 번들: `macos-app-bundle` 의 라이선스 확인 목록.
