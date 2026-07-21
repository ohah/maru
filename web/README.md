# File-panel web package

`web/`는 파일 패널의 프레임워크 없는 TypeScript 패키지다. zntc 번들, 신뢰 shell, 격리 Markdown renderer, sanitizer를 결정적으로 검증하고 앱 bundle의 `Resources/web/`로 패키징한다.

## 명령

```sh
bun install --cwd web --frozen-lockfile
mise run web:build
mise run web:test
mise run web:lint
mise run web:fmt-check
mise run web:licenses
mise run web:check
```

`web:build`는 `@zntc/core` NAPI API를 `write:false`로 호출하고 diagnostics가 하나라도 있거나 각 entry output이 정확히 하나가 아니면 bytes를 쓰기 전에 실패한다. 성공한 Safari 16 대상 ESM만 shell `bundle.js`, DOM-free worker `live-preview-worker.js`, 별도 native helper 전용 `mermaid-helper.js`의 닫힌 이름으로 `web/dist/`에 쓴다. SHA-384 SRI는 세 bundle을 `integrity.json`에 기록하고 실제 bytes와 다시 대조하며, HTML은 shell bundle만 SRI로 로드한다. Mermaid helper bundle은 main app resource에 넣지 않고 서명된 `MaruMermaidRenderer.app` 안에만 한 벌 넣는다. production dependency graph만 순회한 `THIRD_PARTY_NOTICES.txt`도 생성하며, 고지 전문이 없는 새 runtime package는 fail-closed다. `dist/`는 생성물이라 커밋하지 않고 `build.zig`가 앱 bundle 전에 재생성한다.

## 고정된 선택

- Bun `1.3.11`, `@zntc/core` `0.1.4`, oxlint `1.74.0`, oxfmt `0.59.0`을 exact version과 `bun.lock`으로 고정한다.
- vanilla TS 단일 앱에는 `@zntc/web`의 PostCSS/Sass/HMR 계층이 필요하지 않아 넣지 않는다. core CLI/API가 bundle과 단순 serve를 맡는다.
- Markdown은 remark/unified + rehype-sanitize를 쓴다. raw HTML은 HAST 변환 전에 버리고, renderer가 만든 `data-maru-source-start/end`만 allowlist로 보존한다.
- KaTeX는 MathML-only로 출력하고 KaTeX/Prism 뒤 최종 hardening pass가 error fallback의 inline style·event/resource 속성도 제거한다. CSP의 유일한 inline style 예외는 두 entry HTML에 공통인 초기 배경의 exact SHA-256이며, Markdown 파생 markup에는 적용되지 않는다. 코드는 Prism 계열 `rehype-prism-plus`로 강조한다.
- shell은 `maru-app://app`, renderer는 `sandbox="allow-scripts allow-same-origin"`인 `maru-app://render` iframe이다. host 분리로 same-origin이 아니며 renderer에는 bridge/message handler가 없다. 실제 WKWebView smoke가 부모 DOM 접근도 거부되는지 확인한다.
- Mermaid는 FP11f에서 별도 sandbox helper의 strict CSP·API 차단 계측·SVG sanitize·external request 0을 통과한 뒤 라이브 프리뷰 atomic widget으로 활성화됐다. Web shell/worker/renderer iframe 안에서는 Mermaid layout을 실행하지 않으며 실패·timeout은 source-preserving fallback으로 끝난다.

`web:licenses`는 현재 플랫폼에 설치된 전체 lock graph의 SPDX license를 allowlist로 검사한다. 별도로 build의 runtime notice walker는 root production dependencies에서 Node resolution 규칙으로 transitive graph를 따라가 dev tool을 제외하고 각 license/notice 전문을 동봉한다. `khroma@2.1.0` 예외는 이름+버전+전문 SHA-256을 모두 핀한다. 배포 정책은 [third-party 라이선스](../docs/third-party-licenses.md)를 따른다.
