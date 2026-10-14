# 번들 언어 확대 계획

상태: BL1(작은 여섯)·BLP(쿼리 술어 평가) 완료, BL2~BL4 계획(2026-10-14 사용자 결정 — 후보 열둘 전부). 번들 언어 목록·크기는 [네이티브 계획](native-editor.md)의 「번들 언어 목록」이, 라이선스 동봉은 [제3자 라이선스](../third-party-licenses.md)가 소유한다. 이 문서는 후보 실측·결정·배선 설계·조각·검증을 소유한다.

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
| BL1 | 배선 기반과 작은 여섯을 함께 싣는다. <br>· 기반: 라이선스 경로 필드, 파일 이름 판정, 한 저장소 두 grammar(XML·DTD), 새 capture 의 색 역할, Kotlin 크기 행 정정. <br>· 언어: YAML·TOML·XML·DTD·Lua·Dockerfile·Make — 규칙 표·VS Code 대조·판정자까지. | 완료 |
| BLP | **쿼리 술어 평가** — `#eq?`·`#any-of?`·`#match?`·`#lua-match?`(와 `not-` 갈래)를 평가해 조건이 안 맞는 캡처를 버린다(아래 「BL1 이 드러낸 것」) | 완료 |
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
- **Zig**: 같다. 소문자 식별자가 `constant`(술어 `^[A-Z][A-Z_0-9]+$`)를 받아 숫자 색이었다 — 도크 시각 골든 `editor-viewport-scrolled` 가
  그 색(`n`·`x`·`greeting` 이 숫자 색)을 박고 있었다(BLP 에서 다시 찍었다).
- Go 는 호출마다 `function.builtin` 이 붙지만 역할이 같은 함수 색이라 화면에는 안 보였다.

번들 쿼리의 술어를 전수로 셌다(현재 번들 + BL1). `#match?` 37·`#eq?` 12·`#any-of?` 7·`#lua-match?` 3 이다. 정규식은 31종으로, 전부 작은 부분집합이다(`^`·`$`·묶음과 `|`·문자 묶음 `[A-Z\d_]`·`*`·`+`·`?`·이스케이프). 그래서 PCRE2 를 구문 모듈에 끌어오지 않고 그 부분집합을 평가하는 작은 판정기로 닫는다 — 그것이 BLP 다. BL2(Swift `#match?` 4)·BL4(Scala `#match?` 10) 전에 하는 것이 맞다 — 늘어날수록 이 결함도 는다.

## BLP 설계 — 쿼리 술어 평가

- **어디서**: 하이라이트 캡처를 모으는 한 자리(`tree_sitter.collect` — 1층 색·TR4 문맥 조각이 다 지난다)에서, 매치마다 그 패턴의 술어
  (`ts_query_predicates_for_pattern`)를 잰다. 안 맞으면 그 매치를 통째로 버린다(`ts_query_cursor_remove_match` — 한 매치의 다른 캡처도 같이).
  통과한 매치는 최근 열여섯을 기억해 같은 매치의 둘째 캡처에서 다시 재지 않는다.
- **무엇을**: `#eq?`(문자열·캡처)·`#any-of?`·`#match?`·`#lua-match?` 와 `not-` 갈래. `any-` 접두(캡처 묶음용)는 첫 노드로 같게 본다.
  그 밖(`#set!`·`#is-not?`·`#has-ancestor?` …)은 통과 — 색을 가르지 않는 지시이거나 우리가 쓰지 않는 문맥이다.
- **정규식**(`src/syntax/predicate.zig`): 번들 쿼리가 쓰는 부분집합만 — `^`·`$`·`.`·문자 묶음(범위·부정·`\d` 이스케이프)·묶음과 `|`·`*`·`+`·`?`
  (묶음에는 `?` 만)·이스케이프(`\d`·`\w`·`\s`·`\.`). Lua 패턴은 `%` 를 이스케이프로 읽는 같은 부분집합이다. 모르는 구문(`{n}`·반복 묶음·짝
  없는 괄호)과 되돌아가기 걸음 상한(20 만)은 통과다. PCRE2 를 구문 모듈에 끌어오지 않는다 — 문법 C 와 같은 층에 정규식 엔진을 두면 그 경계가
  넓어진다.
- **정답**: 번들 쿼리의 정규식 25 종(tree-sitter 의 문자열 해석 뒤)을 표본 문자열 51 개에 맞대 Python `re.search` 의 답과 1,275 칸이 같다(`PRD2`
  — 생성 표). 제품 효과는 `PRD3` 이 잰다(Python·Ruby·Lua 의 소문자 식별자에 상수 캡처가 없고, 대문자 상수에는 있다; Make 는 `%` 패턴만
  `string.regex`; `#any-of?` 는 목록 밖 글자 — Zig `@This`·XML `&foo;` — 에 안 붙는다). `not-` 갈래는 번들 쿼리에 아직 없어 `PRD4` 가 손으로 만든
  쿼리로 잰다.
- **기존 판정자가 결함을 박아 두고 있었다** — `SMT1`·`SMT2` 가 C 매개변수 `a_ty` 의 1층 색을 「숫자」로 단언했고(`#match? "^[A-Z]…"` 가 안 걸러진
  결과), `ES6`·`ES40`·`SYN9` 이 소문자 `x` 에 붙는 캡처 넷을 골든으로 들고 있었다. 지금 답으로 고치고 겹침 규칙은 대문자 상수(`X_Y` — `type`·`constant`
  가 둘 다 맞는다)로 잰다. 도크 시각 골든 14 장도 같은 결함을 그림으로 들고 있었다 — Zig 의 소문자 식별자(`n`·`greeting`·`std`)가 숫자
  색, TypeScript 의 지역 이름(`raw`·`path`·`readFile`)이 `variable.builtin` 색이었다. 다시 찍어 한 장씩 눈으로 대조했다: 바뀐 것은 그 식별자의
  색뿐이고, Zig `_` 가 `variable.builtin`(`#eq? "_"`), `@import` 앞 `std` 가 모듈 색으로 남는 것까지 술어가 고른 그대로다.

## 한계 (받아들일 것)

- 배포물이 커진다(위 크기 — object 합 약 2 배). 사용자 결정이다.
- 술어 정규식은 번들 쿼리가 쓰는 부분집합만 안다(위 「BLP 설계」). 모르는 구문·모르는 술어 이름은 통과라 그 패턴은 종전처럼 조건 없이 걸린다 — grammar 를 더할 때 `PRD2` 표를 다시 뽑는다.
- Dart 는 태그가 없어 커밋으로 고정한다 — 올리는 기준이 판 번호가 아니다.

## 적대적 검증 (BL1, 5회)

1. 변이 — 22개. 셋이 살아남았다: YAML offSide(호스트 표 — `IGP4` 에 YAML 장면), 새 캡처의 색 역할(`HL18` 이 이름만 봤다 — 역할까지),
   XML·DTD 괄호 쌍 색 끄기(괄호 규칙 판정자에 XML·DTD). 장면을 더해 모두 잡았다.
2. 실제 파일 — 사용자 워크스페이스의 해당 파일 802 개(YAML·TOML·XML·plist·svg·Lua·Dockerfile·Makefile)를 새 grammar 로 파싱·색·접힘까지
   돌렸다(임시 판정자). 죽거나 색이 비는 파일은 없었고, 오류 트리 셋은 실제로 잘못된 YAML 이었다(PyYAML 도 거절). 가장 느린 것은 큰 SVG 의
   183 ms 다 — 여는 파싱은 프레임 예산으로 나뉜다(§2.1).
3. 상호작용 — 파일 트리 아이콘·이미지 보기는 확장자로 따로 가른다(`.svg` 는 이미지로 열린다 — 이 축은 텍스트로 열 때의 문법만 정한다).
   언어 서버 후보·외부 포매터 설정 칸이 문법 열거를 따라야 한다 — 포매터 칸이 `EXF4` 로 드러났다(고쳤다). 결함 없음.
4. 극단 입력 — YAML·Lua 규칙의 경계(따옴표 속 `:`·주석 속 `#`·블록 스칼라 꼴·앵커·한 줄로 닫힌 Lua 함수·문자열 속 낱말)를 따라가 결함이
   없음을 확인하고 판정자로 박았다(`BLR1`).
5. 문서 — 주석·문서의 낡은 서술(offSide 의 「YAML 은 grammar 가 없다」, Makefile 을 경로로 본다는 서술 셋)을 지금 코드에 맞췄다.

## 적대적 검증 (BLP, 5회)

1. 변이 — 12개. 셋이 살아남았다: 갈래 안 `^` 의 위치 확인(맨 앞 `^` 는 시작 위치 루프가 먼저 끊어 가렸다), `not-` 부정(번들
   쿼리에 없다), `#any-of?` 비교(목록 밖 글자를 재는 장면이 없었다). 장면(`PRD1`·`PRD3`·`PRD4`)을 더해 셋 다 잡았다. **그 장면이 결함 하나를
   드러냈다** — 맨 위 갈래(`x|b` 처럼 묶음 없는 `|`)를 머리 갈래 하나만 재서 둘째 갈래부터 영영 안 맞았다. 번들 쿼리는 갈래를 늘 묶음에 넣어
   (`^(a|b)$`) 제품에선 안 드러났지만, 「`|` 를 안다」는 계약이 거짓이었다. 고치고 Python `re` 와 맞댄 행을 `PRD1` 에 박았다.
2. 의미 — tree-sitter-highlight(Rust `regex` 의 찾기)·Neovim 과 같은 축인가: `#match?` 는 어디서든 찾기(`^`·`$` 로 묶는다)이고, 정규식은
   tree-sitter 가 문자열을 해석한 **뒤** 값이다(쿼리 원문 `"[A-Z\\d_]"` 는 `[A-Z\d_]`, 한 겹 `"[A-Z\d_]"` 는 `[A-Zd_]` — 두 엔진도 같은 값을 본다). 캡처 묶음(`@x+`)은 첫 노드로
   잰다. 갈리는 자리 없음.
3. 상호작용 — 쿼리 커서를 쓰는 자리는 `collect` 하나뿐이라(1층 색·Provider·TR4 문맥 조각이 다 지난다) 술어를 건너는 길이 없다.
   `comment.documentation`(Rust `^//!`)은 어느 쪽이든 주석 역할로 접혀 문맥 판정이 안 바뀐다. 결함 없음.
4. 성능 — `ReleaseFast`, 문서 **전체** 쿼리(파싱 포함), 7 회 중 최솟값. 술어를 켠 것/끈 것: Python 280 KB 18.0/16.8 ms · Ruby 67 KB 10.1/9.5 ms ·
   Lua 169 KB 13.4/13.0 ms · Makefile 652 KB 99/58 ms. Make 만 크다 — 낱말마다 `[%*?]` 와 내장 변수 목록(갈래 오십여 개)을 잰다. 바이트당
   약 63 ns 라 화면 창(수 KB)을 묻는 편집 경로에서는 1 ms 아래다. 병적 입력은 걸음 상한(20 만)이 끊고 통과로 둔다.
5. 문서 — 한계 절의 낡은 위치 표기(「아래」→「위」)·`PRD4` 를 이 문서에 맞췄다.

## 검증

- 순수: `grammarForPath`(확장자·파일 이름)·언어별 규칙 표(`LANG*`)·Enter 규칙(`INDR*` + VS Code 대조).
- 구문: 언어마다 실제 트리로 색·접힘·심볼(`SYN*`)·괄호 규칙.
- 제품 경로: 새 언어 파일을 열어 색이 뜨고 타이핑 규칙이 타는 실제 키 판정자.
- 번들: `macos-app-bundle` 의 라이선스 확인 목록.
