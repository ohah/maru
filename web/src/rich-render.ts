import createDOMPurify, { type WindowLike } from "dompurify";
import type { MermaidConfig } from "mermaid";

// 실제 Mermaid 실행은 FP4의 bridge 없는 격리 origin이 생긴 뒤에만 연다. Mermaid는
// SVG를 반환하기 전에 레이아웃을 위해 DOM을 만들 수 있어, 출력 사후 sanitize만으로는
// untrusted diagram의 선행 네트워크 요청을 막지 못한다.
export const mermaidConfig: MermaidConfig = {
  startOnLoad: false,
  securityLevel: "strict",
  htmlLabels: false,
  suppressErrorRendering: true,
};

function normalizeCssEscapes(value: string): string | null {
  let invalidScalar = false;
  const normalized = value
    .replace(/\/\*[\s\S]*?\*\//g, "")
    .replace(/\\([0-9a-f]{1,6})\s?/gi, (_match, hex: string) => {
      const scalar = Number.parseInt(hex, 16);
      if (scalar === 0 || scalar > 0x10ffff || (scalar >= 0xd800 && scalar <= 0xdfff)) {
        invalidScalar = true;
        return "\uFFFD";
      }
      return String.fromCodePoint(scalar);
    })
    .replace(/\\([^\n\r\f])/g, "$1");
  return invalidScalar ? null : normalized;
}

function hasUnsafeSvgUrl(value: string): boolean {
  const decoded = normalizeCssEscapes(value);
  if (decoded === null) return true;
  const normalized = decoded.trim();
  if (!/url\s*\(/i.test(normalized)) return false;

  // Mermaid가 만드는 paint/filter 참조는 같은 SVG document의 fragment만 필요하다.
  // fallback을 포함한 복합 CSS 값은 해석 차이를 피하려고 fail-closed로 제거한다.
  return !/^url\(\s*(["']?)#[A-Za-z0-9_.:-]+\1\s*\)$/i.test(normalized);
}

// `<style>`/style 속성 내용이 외부 리소스를 참조하는지(=exfil 벡터). @import 또는 로컬 fragment(`url(#id)`)가 아닌
// url()이 있으면 unsafe다. Mermaid 테마는 fill/stroke 색과 로컬 marker `url(#arrowhead)`만 쓰므로 정상 스타일은
// 통과한다. sanitize된 SVG는 항상 격리 `<img>` data URL로만 표시돼(스크립트·외부요청 차단) 이 검사는 심층 방어다.
function isCssWhitespace(ch: string): boolean {
  return ch === " " || ch === "\t" || ch === "\n" || ch === "\r" || ch === "\f";
}

function styleContentIsUnsafe(text: string): boolean {
  const normalized = normalizeCssEscapes(text);
  if (normalized === null) return true;
  if (/@import/i.test(normalized)) return true;
  // url() 인자를 선형(indexOf) 스캔으로 검사한다. 이전 정규식 /url\s*\(\s*(['"]?)([^)]*?)\1\s*\)/gi 는
  // 선택적 인용부 backreference(\1)와 lazy([^)]*?) 조합이라 mermaid 테마 CSS의 긴 url() 값에서 catastrophic
  // backtracking으로 sanitize가 동기 hang했다(JIT 없는 macOS 26에서 하드행, JIT 있는 CI에서 near-timeout 플래키
  // — 2026-07-23 진단). 의미는 동일하게 유지: url() 인자가 로컬 fragment(`#id`)가 아니면 fail-closed.
  const lower = normalized.toLowerCase();
  let searchFrom = 0;
  for (;;) {
    const found = lower.indexOf("url", searchFrom);
    if (found === -1) return false;
    let cursor = found + 3;
    while (cursor < normalized.length && isCssWhitespace(normalized[cursor] ?? "")) cursor += 1;
    if (normalized[cursor] !== "(") {
      searchFrom = found + 3;
      continue;
    }
    const close = normalized.indexOf(")", cursor + 1);
    if (close === -1) return true; // 닫히지 않은 url( → fail-closed
    let argument = normalized.slice(cursor + 1, close).trim();
    const quote = argument[0];
    if ((quote === '"' || quote === "'") && argument.at(-1) === quote) {
      argument = argument.slice(1, -1).trim();
    }
    if (!argument.startsWith("#")) return true;
    searchFrom = close + 1;
  }
}

// DOMPurify가 요구하는 타입을 **그대로** 쓴다(그 창의 `Node`·`Element` 등으로 판정하기 때문이다). 직접 적으면
// 라이브러리가 요구하는 목록과 어긋날 수 있고, jsdom 창도 이 타입을 만족해 테스트가 캐스팅 없이 돈다.
export function sanitizeMermaidSvg(svg: string, targetWindow: WindowLike): string {
  const purifier = createDOMPurify(targetWindow);
  purifier.addHook("uponSanitizeAttribute", (_node, data) => {
    if (hasUnsafeSvgUrl(data.attrValue)) data.keepAttr = false;
  });
  // Mermaid는 노드 색을 SVG 내부 `<style>`로 칠하므로 이를 유지해야 테마가 보인다(격리 img라 안전 — 사용자 결정
  // 2026-07-22). 단 @import·외부 url()을 담은 `<style>`은 통째로 제거해 exfil을 이중 차단한다.
  purifier.addHook("uponSanitizeElement", (node, data) => {
    if (data.tagName === "style" && styleContentIsUnsafe(node.textContent ?? ""))
      node.parentNode?.removeChild(node);
  });
  return purifier.sanitize(svg, {
    USE_PROFILES: { svg: true, svgFilters: true },
    // strict Mermaid mode disables click links, so these URL-bearing elements have
    // no allowed use. Removing the element and href forms also blocks SVG image,
    // external <use>, filter image, and anchor navigation after render. `<style>`/style은
    // 테마 색을 위해 유지하되 위 hook이 외부 참조를 막는다(격리 img 표시가 1차 경계).
    FORBID_TAGS: ["script", "foreignObject", "image", "use", "feImage", "a"],
    FORBID_ATTR: ["href", "xlink:href", "xlinkHref", "src"],
    ALLOW_UNKNOWN_PROTOCOLS: false,
  });
}
