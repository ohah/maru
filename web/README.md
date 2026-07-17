# File-panel web package

`web/`는 파일 패널의 프레임워크 없는 TypeScript 패키지다. Zig/Swift 제품 경로와 별개로 zntc 번들, Markdown 렌더러, sanitizer를 먼저 결정적으로 검증한다.

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

`web:build`는 `@zntc/core` NAPI API로 Safari 16 대상 ESM을 `web/dist/`에 만들고, SHA-384 SRI를 `index.html`과 `integrity.json`에 기록한 뒤 실제 bundle bytes와 다시 대조한다. `dist/`는 생성물이라 커밋하지 않는다. 이 패키지는 별도 path-filtered CI를 가지며 기존 의존성 없는 `mise run check`에는 들어가지 않는다.

## 고정된 선택

- Bun `1.3.11`, `@zntc/core` `0.1.3`, oxlint `1.74.0`, oxfmt `0.59.0`을 exact version과 `bun.lock`으로 고정한다.
- vanilla TS 단일 앱에는 `@zntc/web`의 PostCSS/Sass/HMR 계층이 필요하지 않아 넣지 않는다. core CLI/API가 bundle과 단순 serve를 맡는다.
- Markdown은 remark/unified + rehype-sanitize를 쓴다. raw HTML은 HAST 변환 전에 버리고, renderer가 만든 `data-maru-source-start/end`만 allowlist로 보존한다.
- KaTeX는 MathML-only로 출력해 현재 `style-src 'self'` CSP에 inline style 예외를 만들지 않는다. 코드는 Prism 계열 `rehype-prism-plus`로 강조한다.
- Mermaid 소스는 FP2에서 inert code로 남긴다. 설정은 `securityLevel: strict`, `htmlLabels: false`로 고정하고 SVG sanitizer를 단위 검증하지만, 실제 untrusted diagram render는 FP4의 bridge 없는 격리 origin+CSP 전에는 실행하지 않는다.

`web:licenses`는 현재 플랫폼에 설치된 전체 lock graph의 SPDX license를 allowlist로 검사하고 감사한 패키지 수·라이선스별 수를 출력한다. `khroma@2.1.0`은 `package.json`에 license 필드가 없지만 패키지에 MIT 전문을 동봉하므로 그 정확한 예외만 코드로 확인한다. 현재 `web/dist`는 앱/DMG에 포함되지 않으므로 배포 고지 대상은 아니다. FP4에서 제품 bundle에 연결할 때 [third-party 라이선스](../docs/third-party-licenses.md)를 갱신하고 실제 포함 graph의 고지 파일을 동봉한다.
