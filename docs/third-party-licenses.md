# Third-party 라이선스와 Attribution

Maru 자체는 MIT 라이선스다([LICENSE](../LICENSE)). 이 문서는 Maru가 **번들·재배포하는 제3자 자산**과 그 라이선스, 그리고 우리가 지켜야 하는 의무를 단일 출처로 정리한다. 새 제3자 자산(폰트·아이콘·코드 등)을 동봉하면 반드시 이 문서를 갱신한다.

> 빌드/실행에만 쓰고 산출물에 **포함하지 않는** dev/test 의존성(libvterm·libghostty-vt 등)은 여기 대상이 아니다 — [project-rules.md](project-rules.md) §의존성, [references.md](references.md) 참고. 이 문서는 **배포물(`.app`/`.dmg`)에 실제로 들어가는** 자산만 다룬다.

## 번들 코드 라이브러리

바이너리에 링크되어 배포물에 포함되는 제3자 코드다. **폰트와 달리 원본 무수정 재배포가 아니라 컴파일 산출물이 들어가므로**, 라이선스 전문을 앱 리소스에 동봉하고 attribution을 유지한다.

| 라이브러리 | 용도 | 라이선스 | 출처 |
| --- | --- | --- | --- |
| tree-sitter (core) v0.26.13 | 편집기 syntax 1층 — 증분 파싱 런타임([native-editor-visual-mapping.md](native-editor-visual-mapping.md) §5.3) | MIT (© 2018 Max Brunsfeld) | <https://github.com/tree-sitter/tree-sitter> — 받는 것은 **crates.io 소스 배포본**이다(아래) |
| tree-sitter grammar (언어별) | 각 언어의 생성 파서(`parser.c`) | **개별 확인** — permissive(MIT·Apache-2.0·BSD·ISC)만 채택하고 copyleft는 받지 않는다 | 언어별 저장소 |
| └ tree-sitter-zig v1.1.2 | `.zig` 파일의 생성 파서와 `queries/highlights.scm` | MIT (© 2024 Amaan Qureshi) | <https://github.com/tree-sitter-grammars/tree-sitter-zig> |
| └ tree-sitter-json v0.24.8 | `.json` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-json> |
| └ tree-sitter-markdown v0.5.1 | `.md` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter-grammars/tree-sitter-markdown> |
| └ tree-sitter-javascript v0.25.0 | `.js`·`.jsx`·`.mjs`·`.cjs` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-javascript> |
| └ tree-sitter-typescript v0.23.2 | `.ts`·`.tsx`·`.mts`·`.cts` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-typescript> |
| └ tree-sitter-c v0.24.1 | `.c`·`.h` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-c> |
| └ tree-sitter-cpp v0.23.4 | `.cc`·`.cpp`·`.hpp` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-cpp> |
| └ tree-sitter-python v0.25.0 | `.py`·`.pyi` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-python> |
| └ tree-sitter-go v0.25.0 | `.go` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-go> |
| └ tree-sitter-rust v0.24.0 | `.rs` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-rust> |
| └ tree-sitter-java v0.23.5 | `.java` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-java> |
| └ tree-sitter-ruby v0.23.1 | `.rb`·`.rake` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-ruby> |
| └ tree-sitter-php v0.24.2 | `.php`·`.phtml` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-php> |
| └ tree-sitter-kotlin 0.3.8 | `.kt`·`.kts` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/fwcd/tree-sitter-kotlin> |
| └ tree-sitter-bash v0.25.0 | `.sh`·`.bash`·`.zsh` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-bash> |
| └ tree-sitter-css v0.23.2 | `.css`·`.scss`·`.less` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-css> |
| └ tree-sitter-html v0.23.2 | `.html`·`.htm` 파일의 생성 파서와 `queries/highlights.scm` | MIT | <https://github.com/tree-sitter/tree-sitter-html> |

- **코어는 GitHub 태그 tarball이 아니라 crates.io 소스 배포본을 받는다**(`build.zig.zon`이 근거를 갖는다). 상류 저장소의 `build.zig`가 Zig 0.16에서 제거된 API를 부르는데 `lazyDependency`는 그 파일을 **실행**하므로, 우리가 거기서 아무것도 안 가져와도 빌드가 죽는다. crates.io 배포본에는 `build.zig`가 없고 `src/`는 두 배포본이 동일하다 — **같은 코드, 같은 MIT 라이선스**이며 경로 접두사(`lib/`)만 다르다.
- **번들 언어는 명시 목록으로 관리한다** — grammar마다 `parser.c`가 붙어 배포물이 커지므로 열린 집합으로 두지 않는다. 목록과 추가 절차는 [네이티브 편집기 구현 계획](plans/native-editor.md)이 소유한다.
- **grammar를 추가하는 PR은 이 표에 행을 더한다.** 라이선스 확인 없이 grammar를 넣지 않는다.
- **라이선스 전문을 동봉한다 — 배포물에 들어간다.** `app_session/editor_syntax.zig`가 `syntax` 모듈을 `@import`하면서 코어와 grammar가 exe에 링크됐다(`nm` 실측: tree-sitter 심볼이 0개 → 8개). 폰트가 `Resources/Fonts/<Family>-OFL.txt`로 동봉되는 것과 같은 자리에 넣는다 — `Resources/Licenses/tree-sitter-LICENSE`와 `tree-sitter-<언어>-LICENSE` **열여덟 개**다(2026-08-29 실측: 번들에 18개 파일).
- **목록을 손으로 적지 않는다.** `build.zig`의 grammar 표가 복사 명령과 **확인 목록을 함께** 만든다 — 손으로 적으면 언어를 늘릴 때 한쪽만 빠지고, 그 누락은 아무 테스트도 안 깨뜨린다(재배포 의무의 성질이다). 빠지면 번들이 `error: bundled code library license missing or empty: … — 재배포 의무`로 **소리 내어 죽는다**.
- **한 저장소가 두 grammar 를 내면 라이선스는 하나다**(TypeScript/TSX). 표가 dep 단위로 중복을 걷는다.
- 이것이 [project-rules.md](project-rules.md) §의존성의 "런타임 의존성 기본 0"에 대한 **첫 예외**이며, 그 문서가 요구한 사용자 논의를 거쳤다(2026-08-09).

## 번들 폰트

`assets/fonts/<Family>/`의 폰트를 `build.zig`가 `Maru.app/Contents/Resources/Fonts/`로 복사하고, `MaruAppHost-Info.plist.in`에서 생성한 plist의 `ATSApplicationFontsPath`가 실행 시 등록한다(메커니즘 단일 출처: [font-strategy.md](font-strategy.md) §번들 폰트). 동봉 폰트는 모두 **원본 무수정**으로 재배포한다.

| 패밀리 | 버전 | 라이선스 | 저작권 | 출처 |
| --- | --- | --- | --- | --- |
| JetBrains Mono | 2.304 | OFL 1.1 | Copyright 2020 The JetBrains Mono Project Authors | <https://github.com/JetBrains/JetBrainsMono> |
| Fira Code | 6.2 | OFL 1.1 | Copyright 2014–2021 The Fira Code Project Authors | <https://github.com/tonsky/FiraCode> |
| Cascadia Code | v2407.24 | OFL 1.1 (RFN "Cascadia Code") | © 2021 Microsoft Corporation | <https://github.com/microsoft/cascadia-code> |
| Hack | v3.003 | MIT + Bitstream Vera | © 2018 Source Foundry Authors / © 2003 Bitstream, Inc. | <https://github.com/source-foundry/Hack> |
| Jetendard | v0.1.0 | OFL 1.1 (RFN "Jetendard") | Copyright © 2026 Jung Woong Park | <https://github.com/kuskhan/jetendard> |

각 라이선스 전문은 폰트 옆(`assets/fonts/<Family>/OFL.txt` 또는 `LICENSE.md`)에 두고, 번들에도 패밀리명 프리픽스로 함께 들어간다(`Resources/Fonts/<Family>-OFL.txt` 등).

## 번들 아이콘 (GitHub Octicons)

`assets/icons/`의 SVG 중 아래 15종은 **GitHub Octicons**(primer/octicons, MIT) 유래다. 빌드 준비 단계에서 `tools/svg_to_coverage.py`가 coverage 마스터로 변환해 커밋된 `src/renderer/icon_coverage_data.zig`(+ `src/platform/macos/icon_codepoints.h`)에 들어가고, 앱이 이 데이터를 렌더하므로 **파생 형태(coverage 데이터)로 배포물에 포함**된다. SVG 파일 자체는 번들에 복사되지 않는다.

| 아이콘 | 파일 | 라이선스 | 저작권 | 출처 |
| --- | --- | --- | --- | --- |
| bell · folder · gear · git-branch · mark-github · plus · search · sidebar-collapse | `assets/icons/<이름>.svg` | MIT | © GitHub, Inc. | <https://github.com/primer/octicons> |
| chevron-down · chevron-right | `assets/icons/<이름>.svg` | MIT | © GitHub, Inc. | 〃 |
| reset(Octicons `sync` 파생) | `assets/icons/reset.svg` | MIT | © GitHub, Inc. | 〃 |
| tight 변형: chevron-down-tight · chevron-right-tight · reset-tight · search-tight | `assets/icons/<이름>.svg` | MIT | © GitHub, Inc. | 〃 |

- **tight 변형도 같은 유래다.** 이들은 새 그림이 아니라 위 Octicon을 슬롯에 더 채우도록 조정한 변형이고(`search-tight.svg`는 path가 `search.svg`와 완전히 동일, `reset-tight.svg`는 `reset.svg`와 동일), 코드에서는 별도 이름이 아니라 `icons.Fit.tight`로 고른다([chrome-strategy.md](chrome-strategy.md) §9.7). 파생물도 MIT 고지 대상이므로 여기 함께 적는다.
- 라이선스 전문은 `assets/icons/LICENSE-octicons.txt`에 둔다(MIT — 저작권·허가 고지 유지 의무). **그 파일이 실제 번들 고지의 단일 출처이고, 이 표는 그것을 문서에 비추는 사본이다** — 자산을 추가·변형하면 둘 다 갱신한다.
- `sparkle.svg`·`diamond.svg`·`host.svg`는 Maru 자작이라 이 표 대상이 아니다(Maru 본체 MIT). `host.svg`는 파일 헤더 주석에, `sparkle.svg`·`diamond.svg`는 `assets/icons/LICENSE-octicons.txt`의 예외 문단에 provenance가 있다.
- **상표 주의**: `mark-github.svg`는 GitHub 로고 마크다. 라이선스(MIT)와 별개로 GitHub 상표이므로, GitHub(리포·프로필)로 연결하는 표시 용도로만 쓴다(<https://github.com/logos> 가이드라인). 현재 용도(사이드바 카드의 GitHub 리포 표시)는 이 범위 안이다.
- 배포물 내 고지 노출은 아래 "About 화면 attribution"과 같은 후속으로 묶는다(현재는 리포 내 라이선스 파일 + 이 문서로 기록).

### Maru 자작 Explorer 아이콘

아래 18종은 이 Explorer scrollbar/icon 작업에서 처음 만든 **Maru 원본 자산**이며 외부 SVG를 복사·변형하지 않았다. 자산 세트 이름/버전은 `Maru Explorer Icons v1`, source는 이 저장소의 해당 파일, 라이선스는 Maru 본체와 같은 MIT([LICENSE](../LICENSE)), 저작권자는 Maru contributors다. 따라서 third-party 고지 대상은 아니지만 provenance가 모호해지지 않도록 여기에 고정한다.

| 분류 | 파일 |
| --- | --- |
| 공통/파일 형식 | `recent.svg`, `folder-open.svg`, `file.svg`, `file-code.svg`, `document.svg`, `image.svg`, `file-config.svg`, `archive.svg`, `package.svg`, `web.svg`, `data.svg` |
| 의미 폴더 | `folder-source.svg`, `folder-test.svg`, `folder-docs.svg`, `folder-assets.svg`, `folder-config.svg`, `folder-dependency.svg`, `folder-output.svg` |

### Maru 자작 방향키 아이콘

`arrow-up.svg`·`arrow-down.svg`·`arrow-left.svg`·`arrow-right.svg` 넷은 **모바일 보조 키바**용으로
이 작업에서 처음 만든 **Maru 원본 자산**이며 외부 SVG를 복사·변형하지 않았다. 기존
`chevron-*.svg`의 획 굵기(.75)와 `0 0 16 16` viewBox를 맞춰 같은 세트로 보이게 그렸다.
라이선스는 Maru 본체와 같은 MIT([LICENSE](../LICENSE)), 저작권자는 Maru contributors다.

**왜 폰트 글자가 아니라 아이콘인가**: `↑↓←→`(U+2190~2193)는 폰트마다 작게 디자인돼 44px 키캡
안에서 `esc`·`tab` 라벨보다 훨씬 작아 보였다(화면으로 확인). 합성 아이콘은 슬롯을 가장자리까지
채우므로 크기를 우리가 정한다. 같은 이유가 §9.6(헤더 아이콘)에도 적혀 있다.

`tools/svg_to_coverage.py`의 manifest는 각 exact path/codepoint/SHA-256을 커밋된 Zig 데이터에 기록한다. 기본 Zig test는 외부 도구 없이 실제 SVG SHA-256과 C/Zig registry를 검증하고, `mise run icons:check`는 `rsvg-convert`/Pillow가 있는 개발 환경에서 SVG→coverage 재생성 drift까지 확인하는 opt-in gate다.

## 파일 패널 웹 런타임

FP4부터 `web/dist/bundle.js`가 앱 `Resources/web/`에 포함된다. 직접 런타임 의존성은 DOMPurify, Mermaid, remark/unified·rehype 계열, KaTeX, Prism 계열과 CodeMirror 6이며 exact 버전은 `web/package.json`·`bun.lock`이 단일 출처다. 실제 번들에 들어갈 수 있는 transitive production graph의 이름·버전·SPDX와 license/notice 전문은 build가 `Resources/web/THIRD_PARTY_NOTICES.txt`로 생성한다.

FP12(text kind 소스 편집기, docs/file-panel-kinds.md §2.2)는 CodeMirror 6 언어 패키지를 추가한다: `@codemirror/lang-json@6.0.2`, `@codemirror/lang-python@6.2.1`, `@codemirror/lang-xml@6.1.0`, `@codemirror/lang-yaml@6.1.3`(신규)와 이미 transitive로 있던 `@codemirror/lang-javascript@6.2.5`·`@codemirror/lang-css@6.3.1`(직접 선언). 후속(VSCode식 확장·들여쓰기)으로 `@codemirror/legacy-modes@6.5.3`(toml·shell·rust·go·c/c++ 등 StreamLanguage)와 `@codemirror/autocomplete@6.20.3`(closeBrackets)을 더한다. 모두 MIT이며 각 Lezer 문법(`@lezer/json`·`@lezer/python`·`@lezer/xml`·`@lezer/yaml` 등)도 MIT다. `web:licenses` 감사가 전체 lock 그래프 SPDX를 allowlist로 검증하고 exact 버전은 위 SSOT를 따른다.

FP14b(2026-07-28)에서 image가 격리 `loadFileURL`(WebKit image document + 주입 뷰어 스크립트)로 옮겨가며 **`panzoom@9.4.4` 직접 의존을 제거했다** — 팬/줌은 이제 네이티브 문서에 주입하는 스크립트가 담당한다(`amator`·`ngraph.events`·`wheel`·`bezier-easing` transitive도 함께 빠진다). FP14 당시 이 의존을 둔 이유는 신뢰 shell 안 `<img>`의 CSSOM transform 조작이었고, 그 shell 경로 자체가 사라졌다.

- walker는 root `dependencies`에서 시작해 production dependency/optionalDependency만 Node resolution 규칙으로 추적하고 devDependencies(`@zntc/core`, Oxc, Bun types, jsdom)는 제외한다.
- 새 runtime package의 manifest·license 판정·전문이 없으면 build가 실패한다. npm workspace 배포본에 전문이 없는 `rehype-katex@7.0.1`·`remark-math@6.0.0`은 해당 remark-math 릴리스의 MIT 전문을 `web/licenses/remark-math-MIT.txt`에 고정한 exact-version fallback만 사용한다.
- `web:licenses`는 설치된 전체 lock graph의 SPDX allowlist를 별도로 감사하고 GPL/LGPL/AGPL 계열을 허용하지 않는다. runtime notice test는 production 포함/dev 제외와 전문 누락 fail-closed를 고정한다.

## 라이선스별 의무와 충족 방법

### SIL Open Font License 1.1 (OFL) — JetBrains Mono · Fira Code · Cascadia Code · Jetendard

OFL은 폰트 전용 자유 라이선스로, **앱에 임베드·번들·재배포(무료/상용 무관)가 명시적으로 허용된 사용 방식**이다. 로열티·사용료 없음. 의무는 셋:

1. **라이선스·저작권 고지 동봉** — 폰트 사본마다 OFL 전문과 copyright를 함께 배포한다.
   - 충족: `assets/fonts/<Family>/OFL.txt`를 두고 빌드가 번들 `Resources/Fonts/`에 복사한다.
2. **폰트 단독 판매 금지** — 폰트는 더 큰 소프트웨어 패키지의 일부로만 배포·판매할 수 있다(폰트 파일만 따로 팔 수 없다).
   - 충족: Maru 앱 번들의 일부로만 배포한다.
3. **Reserved Font Name(RFN)** — RFN이 지정된 폰트는 **수정본**에 그 이름을 쓸 수 없다(수정본은 다른 이름으로, 역시 OFL로 배포).
   - 충족: RFN이 걸린 Cascadia Code("Cascadia Code")와 Jetendard("Jetendard")는 각각 해당 이름으로 배포되는 릴리스 자산을 사용한다. 향후 이 자산을 다시 서브셋·패치하는 경우에는 반드시 RFN과 다른 패밀리명으로 바꾸고 OFL로 배포한다.

### MIT + Bitstream Vera — Hack

Hack는 두 부분으로 나뉜다:
- **Hack 본체(MIT, Source Foundry)**: 저작권·라이선스 고지만 유지하면 단독 판매·이름·임베드 제약이 없다.
- **DejaVu 유래 부분(Bitstream Vera License)**: 저작권 고지 유지에 더해 **Reserved Font Name "Bitstream"·"Vera"**가 걸려 있다 — 수정본(파생)에 이 이름을 쓸 수 없다(Cascadia의 RFN과 동형). 우리는 **무수정 원본**을 재배포하므로 현재는 무관하지만, Hack을 서브셋·패치하려면 "Bitstream"/"Vera"를 패밀리명에 쓰면 안 된다.

의무 요약: 저작권·라이선스 고지 유지 + (수정 시) Bitstream Vera RFN 회피. 임베드·번들 자체는 제약 없음.
- 충족: `assets/fonts/Hack/LICENSE.md`(MIT + Bitstream Vera 전문, RFN 조항 포함)를 두고 번들에 동봉한다.

### Jetendard의 파생 폰트 고지

Jetendard는 JetBrains Mono Nerd Font Mono와 Pretendard를 결합해 만든 OFL 1.1 파생 폰트다. Maru는 upstream 릴리스 v0.1.0의 `Regular`·`Bold`·`Italic`·`BoldItalic` TTF와 upstream `LICENSE` 전문을 원본 그대로 번들한다. Jetendard 자체의 Reserved Font Name은 `Jetendard`이며, 자산을 다시 수정하지 않으므로 이 이름을 사용한다. 상위 프로젝트의 고지와 라이선스는 upstream 라이선스 문서가 참조하는 각 프로젝트의 원문을 따른다.

## About 화면 attribution(권장)

법적 최소 의무는 번들 내 라이선스 파일로 충족되지만, 관례상 앱 About/정보 화면이나 배포 페이지에 동봉 폰트의 라이선스 고지를 노출하는 것을 권장한다. 노출 시 위 표(패밀리·버전·라이선스·저작권)를 그대로 쓴다. (미구현 — 후속.)

## 동봉 자산 추가 규칙

새 폰트(또는 그 밖의 제3자 자산)를 번들에 추가할 때:

1. **라이선스 호환 확인** — 재배포·임베드 허용 라이선스인지 본다(OFL·MIT·Apache-2.0 등). 불확실하면 사용자와 논의한다([project-rules.md](project-rules.md) §의존성).
2. **원본 무수정 원칙** — 가능하면 원본을 그대로 넣는다. 수정(서브셋·패치)이 필요하면 RFN·상표·라이선스 표기 의무를 먼저 확인한다.
3. **라이선스 파일 동봉** — 자산 옆에 라이선스 전문을 둔다. 폰트는 `assets/fonts/<Family>/`(`OFL.txt`/`LICENSE.md` — `build.zig` 번들 단계가 패밀리명 프리픽스로 자동 복사), 아이콘처럼 파생 형태로만 배포물에 들어가는 자산은 원본 옆(`assets/icons/LICENSE-*.txt` 등)에 둔다.
4. **이 문서 갱신**(폰트는 [font-strategy.md](font-strategy.md) 표도) — 이름·버전·라이선스·저작권·출처를 기록한다.
