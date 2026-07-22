import createDOMPurify from "dompurify";
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
function styleContentIsUnsafe(text: string): boolean {
  const normalized = normalizeCssEscapes(text);
  if (normalized === null) return true;
  if (/@import/i.test(normalized)) return true;
  const urlPattern = /url\s*\(\s*(['"]?)([^)]*?)\1\s*\)/gi;
  let match: RegExpExecArray | null;
  while ((match = urlPattern.exec(normalized)) !== null) {
    if (!match[2].trim().startsWith("#")) return true;
  }
  return false;
}

export function sanitizeMermaidSvg(svg: string, targetWindow: Window): string {
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
