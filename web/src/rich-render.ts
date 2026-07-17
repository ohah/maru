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

export function sanitizeMermaidSvg(svg: string, targetWindow: Window): string {
  const purifier = createDOMPurify(targetWindow);
  purifier.addHook("uponSanitizeAttribute", (_node, data) => {
    if (hasUnsafeSvgUrl(data.attrValue)) data.keepAttr = false;
  });
  return purifier.sanitize(svg, {
    USE_PROFILES: { svg: true, svgFilters: true },
    // strict Mermaid mode disables click links, so these URL-bearing elements have
    // no allowed use. Removing the element and href forms also blocks SVG image,
    // external <use>, filter image, and anchor navigation after render.
    FORBID_TAGS: ["script", "foreignObject", "style", "image", "use", "feImage", "a"],
    FORBID_ATTR: ["style", "href", "xlink:href", "xlinkHref", "src"],
    ALLOW_UNKNOWN_PROTOCOLS: false,
  });
}
