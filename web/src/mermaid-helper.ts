import type { Mermaid } from "mermaid";
import { mermaidFenceBody } from "./mermaid-fence";
import { mermaidConfig, sanitizeMermaidSvg } from "./rich-render";

declare global {
  interface MermaidExternalRequestAttempts {
    fetch: number;
    xhr: number;
    webSocket: number;
    eventSource: number;
    cspViolation: number;
  }

  interface Window {
    __maruExternalRequestSnapshot?: () => MermaidExternalRequestAttempts;
    __maruRenderMermaid?: (
      source: string,
      palette?: unknown,
    ) => Promise<{ svg: string; externalRequests: MermaidExternalRequestAttempts }>;
    mermaid: Mermaid;
  }
}

window.mermaid.initialize(mermaidConfig);
let nextRenderId = 0;

// native가 넘긴 터미널 팔레트(#rrggbb hex dict)를 mermaid themeVariables로 매핑한다(v3). 값은 native가
// u8 RGB에서 만든 hex라 항상 유효하지만, themeVariables가 SVG `<style>`로 들어가므로 방어적으로 #rrggbb만
// 통과시키고(CSS 주입 차단) 아니면 안전한 기본값으로 떨어진다. 최종 SVG는 sanitizeMermaidSvg가 다시 검사한다.
function safeHex(value: unknown, fallback: string): string {
  return typeof value === "string" && /^#[0-9a-fA-F]{6}$/.test(value) ? value : fallback;
}

function hexLuminance(hex: string): number {
  const r = Number.parseInt(hex.slice(1, 3), 16) / 255;
  const g = Number.parseInt(hex.slice(3, 5), 16) / 255;
  const b = Number.parseInt(hex.slice(5, 7), 16) / 255;
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

function mermaidThemeVariables(palette: unknown): Record<string, unknown> {
  const p = (typeof palette === "object" && palette !== null ? palette : {}) as Record<
    string,
    unknown
  >;
  const background = safeHex(p.background, "#101010");
  const primary = safeHex(p.primary, "#282828");
  const primaryBorder = safeHex(p.primaryBorder, "#dda15e");
  const primaryText = safeHex(p.primaryText, "#e8e8e8");
  const line = safeHex(p.line, "#888888");
  const text = safeHex(p.text, "#e8e8e8");
  const secondary = safeHex(p.secondary, primary);
  const tertiary = safeHex(p.tertiary, primary);
  return {
    darkMode: hexLuminance(background) < 0.5,
    background,
    primaryColor: primary,
    primaryBorderColor: primaryBorder,
    primaryTextColor: primaryText,
    lineColor: line,
    textColor: text,
    secondaryColor: secondary,
    tertiaryColor: tertiary,
    secondaryBorderColor: primaryBorder,
    tertiaryBorderColor: primaryBorder,
    secondaryTextColor: text,
    tertiaryTextColor: text,
    noteBkgColor: secondary,
    noteTextColor: text,
    noteBorderColor: primaryBorder,
    mainBkg: primary,
    nodeBorder: primaryBorder,
    clusterBkg: secondary,
    clusterBorder: primaryBorder,
    titleColor: text,
    edgeLabelBackground: background,
  };
}

function externalRequestDelta(
  before: MermaidExternalRequestAttempts,
  after: MermaidExternalRequestAttempts,
): MermaidExternalRequestAttempts {
  const delta = {
    fetch: after.fetch - before.fetch,
    xhr: after.xhr - before.xhr,
    webSocket: after.webSocket - before.webSocket,
    eventSource: after.eventSource - before.eventSource,
    cspViolation: after.cspViolation - before.cspViolation,
  };
  if (Object.values(delta).some((value) => !Number.isSafeInteger(value) || value < 0))
    throw new Error("invalid external request counters");
  return delta;
}

window.__maruRenderMermaid = async (
  source: string,
  palette?: unknown,
): Promise<{ svg: string; externalRequests: MermaidExternalRequestAttempts }> => {
  if (typeof window.__maruExternalRequestSnapshot !== "function") {
    throw new Error("external request guard unavailable");
  }
  const externalRequestsBefore = window.__maruExternalRequestSnapshot();
  const body = mermaidFenceBody(source);
  if (body === null || body.length === 0) throw new Error("invalid Mermaid fence");
  nextRenderId += 1;
  if (!Number.isSafeInteger(nextRenderId)) throw new Error("Mermaid render id exhausted");
  const id = `maru-mermaid-${nextRenderId}`;
  // native가 넘긴 터미널 파생 팔레트를 themeVariables로 적용한다(v3). theme:"base"라야 themeVariables가 온전히
  // 먹는다. 팔레트가 없으면(구프레임 등) mermaidThemeVariables 내부 폴백으로 안전한 기본값을 쓴다.
  window.mermaid.initialize({
    ...mermaidConfig,
    theme: "base",
    themeVariables: mermaidThemeVariables(palette),
  });
  const rendered = await window.mermaid.render(id, body);
  const sanitized = sanitizeMermaidSvg(rendered.svg, window);
  if (!/^<svg(?:\s|>)/i.test(sanitized.trim())) throw new Error("invalid Mermaid SVG");
  // CSP violation delivery is asynchronous. Yield once before taking the after snapshot so a blocked
  // DOM subresource created by this render cannot be attributed to a later, otherwise clean render.
  await new Promise((resolve) => setTimeout(resolve, 0));
  return {
    svg: sanitized,
    externalRequests: externalRequestDelta(
      externalRequestsBefore,
      window.__maruExternalRequestSnapshot(),
    ),
  };
};
