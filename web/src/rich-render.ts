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

export function sanitizeMermaidSvg(svg: string, targetWindow: Window): string {
  const purifier = createDOMPurify(targetWindow);
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
