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
    ) => Promise<{ svg: string; externalRequests: MermaidExternalRequestAttempts }>;
    mermaid: Mermaid;
  }
}

window.mermaid.initialize(mermaidConfig);
let nextRenderId = 0;

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
  // 렌더 직전 현재 appearance로 테마를 정한다(헬퍼는 별도 프로세스라 터미널 팔레트를 직접 모른다 — 시스템
  // light/dark만 관측 가능. 터미널이 시스템을 따르면 일치한다. 정확한 터미널 팔레트 매칭은 프로토콜로 색을 넘기는
  // 후속). Mermaid `<style>`가 sanitize에서 유지되므로 이 theme가 실제로 적용된다.
  const prefersDark = window.matchMedia("(prefers-color-scheme: dark)").matches;
  window.mermaid.initialize({ ...mermaidConfig, theme: prefersDark ? "dark" : "default" });
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
