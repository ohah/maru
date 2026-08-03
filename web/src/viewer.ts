import { type WindowLike } from "dompurify";
import { normalizeAssetReference } from "./asset-path";
import { renderMarkdown } from "./markdown";
import { sanitizeMermaidSvg } from "./rich-render";
import { createMarkdownEditor, createSourceEditor } from "./editor";
import { createRichEditor, type RichEditorHandle } from "./rich-editor";
import { sourceLanguageExtensions } from "./source-language";
import {
  installRendererContextMenu,
  installShellContextMenu,
  type MenuOpenParams,
} from "./content-menu";
import {
  type BeginDocumentRequest,
  encodeFileBridgeRequest,
  type DirtyReport,
  type FileBridgeRequest,
  type FileMethod,
  type OpenLinkRequest,
  type ReadRequest,
  type RenderMermaidRequest,
  type RevokeMermaidRequest,
  type ResolveExternalChangeRequest,
  type WriteRequest,
} from "./file-bridge-request";
import type { EditorView } from "@codemirror/view";
import type { Text } from "@codemirror/state";
import { EditorRevisionClock, isEditableFileMode, type FilePanelMode } from "./file-panel-state";
import { type RendererCapability } from "./renderer-capability";
import { sha256Hex } from "./sha256";

export const viewerChannel = "maru.file.viewer.v1";
export const maxAssetRequests = 64;
export const maxAssetBase64Bytes = 48 * 1024 * 1024;

export function assetRequestCountAllowed(count: number): boolean {
  return isInt(count) && count >= 0 && count <= maxAssetRequests;
}

export function assetBase64BudgetAllowed(currentBytes: number, nextBytes: number): boolean {
  return (
    isInt(currentBytes) &&
    currentBytes >= 0 &&
    isInt(nextBytes) &&
    nextBytes >= 0 &&
    currentBytes <= maxAssetBase64Bytes - nextBytes
  );
}

type BridgeResult = Record<string, unknown>;

type AssetRequest = {
  channel: typeof viewerChannel;
  type: "asset-request";
  requestId: string;
  path: string;
};

type AssetResult = {
  channel: typeof viewerChannel;
  type: "asset-result";
  requestId: string;
  mime?: string;
  dataBase64?: string;
  error?: string;
};

// 읽기 프리뷰 mermaid: render iframe이 펜스별로 요청하면 shell이 native 헬퍼로 렌더한 sanitized SVG를 돌려준다.
type MermaidReadResult = {
  channel: typeof viewerChannel;
  type: "mermaid-result";
  requestId: string;
  svg?: string;
  error?: string;
};

type LinkActivation = {
  channel: typeof viewerChannel;
  type: "link-activate";
  href: string;
  forceSystem: boolean;
};

type RendererReport = {
  channel: typeof viewerChannel;
  type: "rendered";
  text: string;
  imageCount: number;
  loadedImageCount: number;
  bridgeType: string;
  handlerType: string;
  parentAccessible: boolean;
};

type RendererReady = {
  channel: typeof viewerChannel;
  type: "renderer-ready";
  bridgeType: string;
  handlerType: string;
  parentAccessible: boolean;
};

let bridgeRequestId = 0;

/// 이 모듈이 창에서 실제로 쓰는 것만 요구한다. `Window & typeof globalThis`로 두면 브라우저 전역 전체를 요구해
/// jsdom 창(DOMWindow)이 안 맞아 테스트가 캐스팅투성이가 된다 — 필요한 생성자만 적으면 둘 다 만족한다.
/// (그 창의 생성자로 `instanceof`를 하는 이유는 다른 창/iframe 인스턴스를 정확히 가리기 위해서다.)
export type ViewerWindow = Window &
  Pick<typeof globalThis, "MouseEvent" | "Element"> &
  // SVG asset을 sanitize할 때 그 창을 DOMPurify에 넘긴다 — 그쪽이 요구하는 목록을 여기 포함시켜 호출 지점마다
  // 캐스팅하지 않는다.
  WindowLike;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/// `Number.isInteger`도 같은 이유로 가드가 아니다 — 정수 검사 뒤의 비교를 위해 좁혀 준다.
function isInt(value: unknown): value is number {
  return Number.isInteger(value);
}

/// `Number.isSafeInteger`는 타입 가드가 아니라 boolean만 준다 — 그래서 검사한 뒤에도 값이 `unknown`으로 남아
/// 비교·산술이 전부 타입 오류였다(이 파일이 타입 검사 밖이라 여태 안 드러났다). 같은 판정을 가드로 감싸 좁힌다.
function isSafeInt(value: unknown): value is number {
  return Number.isSafeInteger(value);
}

function isLocalDocumentHref(href: string): boolean {
  const path = href.split(/[?#]/, 1)[0];
  if (path.length === 0 || path.startsWith("//") || path.includes("\\")) return false;
  if (/^[a-z][a-z0-9+.-]*:/i.test(path)) return false;
  try {
    const decoded = decodeURIComponent(path);
    if (
      decoded.startsWith("//") ||
      decoded.includes("\\") ||
      /^[a-z][a-z0-9+.-]*:/i.test(decoded) ||
      Array.from(decoded).some((char) => {
        const code = char.codePointAt(0) ?? 0;
        return code < 0x20 || code === 0x7f;
      })
    ) {
      return false;
    }
    return /\.(?:md|html)$/i.test(decoded);
  } catch {
    return false;
  }
}

function isExplicitHttpHref(href: string): boolean {
  if (!/^https?:\/\//i.test(href) || href.includes("\\")) return false;
  if (
    Array.from(href).some((char) => {
      const code = char.codePointAt(0) ?? 0;
      return code <= 0x20 || code === 0x7f;
    })
  ) {
    return false;
  }
  try {
    const url = new URL(href);
    return (url.protocol === "http:" || url.protocol === "https:") && url.hostname.length > 0;
  } catch {
    return false;
  }
}

export function isLinkActivation(value: unknown): value is LinkActivation {
  return (
    isRecord(value) &&
    value.channel === viewerChannel &&
    value.type === "link-activate" &&
    typeof value.href === "string" &&
    value.href.length > 0 &&
    value.href.length <= 4096 &&
    typeof value.forceSystem === "boolean" &&
    (isLocalDocumentHref(value.href) || isExplicitHttpHref(value.href))
  );
}

/** 클릭 하나가 링크 열기가 되려면 만족해야 하는 것들. DOM 없이 판정할 수 있도록 값만 받는다. */
export type LinkClick = {
  isTrusted: boolean;
  button: number;
  metaKey: boolean;
  shiftKey: boolean;
  href: string | null;
  /** 링크가 렌더된 문서 안에 있는가. 밖의 링크(shell chrome)는 이 경로가 다루지 않는다. */
  linkInRoot: boolean;
};

/**
 * 이 클릭이 링크 열기를 발급해도 되는지 판정한다. 열면 안 되면 `null`이다.
 *
 * **판정을 리스너에서 떼어 낸 이유**: `isTrusted`는 브라우저만 세울 수 있어 테스트가 진짜 값을 만들 수
 * 없다(JSDOM에서 own·unconfigurable). 값으로 받으면 정상 경로와 거부 경로를 **둘 다** 단위로 고정할 수 있다.
 *
 * `isTrusted`는 **사용자가 실제로 누른 것만 통과시킨다**(file-panel.md §13 경화 1단계). 합성
 * `anchor.click()`이나 `dispatchEvent`로 만든 이벤트는 여기서 걸린다. 지금 문서 스크립트는 sanitize와 CSP
 * `script-src 'self'`로 이중 차단되므로 이건 심층 방어다 — 다만 이 판정이 **page world에서 도는 한** 그 둘이
 * 뚫리면 리스너 제거·`postMessage` 직접 호출이 여전히 가능하고, 그 경로는 isolated world 이관이 닫는다(§13).
 */
export function linkActivationFor(click: LinkClick): LinkActivation | null {
  if (!click.isTrusted || click.button !== 0) return null;
  if (click.href === null || !click.linkInRoot) return null;
  if (!isLocalDocumentHref(click.href) && !isExplicitHttpHref(click.href)) return null;
  return {
    channel: viewerChannel,
    type: "link-activate",
    href: click.href,
    forceSystem: click.metaKey && click.shiftKey,
  };
}

export function closeUnlockOwnsLock(
  currentRequestId: number | null,
  unlockRequestId: number,
): boolean {
  return (
    currentRequestId !== null && isSafeInt(unlockRequestId) && unlockRequestId >= currentRequestId
  );
}

export function closeLockCanAcquire(currentRequestId: number | null, requestId: number): boolean {
  return (
    isSafeInt(requestId) &&
    requestId > 0 &&
    (currentRequestId === null || requestId >= currentRequestId)
  );
}

export function isAssetRequest(value: unknown): value is AssetRequest {
  return (
    isRecord(value) &&
    value.channel === viewerChannel &&
    value.type === "asset-request" &&
    typeof value.requestId === "string" &&
    value.requestId.length > 0 &&
    value.requestId.length <= 128 &&
    typeof value.path === "string" &&
    value.path.length <= 4096 &&
    normalizeAssetReference(value.path) === value.path
  );
}

function isAssetResult(value: unknown): value is AssetResult {
  return (
    isRecord(value) &&
    value.channel === viewerChannel &&
    value.type === "asset-result" &&
    typeof value.requestId === "string"
  );
}

export function isRendererReport(value: unknown): value is RendererReport {
  return (
    isRecord(value) &&
    value.channel === viewerChannel &&
    value.type === "rendered" &&
    typeof value.text === "string" &&
    value.text.length <= 512 &&
    isInt(value.imageCount) &&
    value.imageCount >= 0 &&
    value.imageCount <= maxAssetRequests &&
    isInt(value.loadedImageCount) &&
    value.loadedImageCount >= 0 &&
    value.loadedImageCount <= value.imageCount &&
    typeof value.bridgeType === "string" &&
    value.bridgeType.length <= 32 &&
    typeof value.handlerType === "string" &&
    value.handlerType.length <= 32 &&
    typeof value.parentAccessible === "boolean"
  );
}

function rendererCapabilityTypes(
  targetWindow: ViewerWindow,
): Pick<RendererReady, "bridgeType" | "handlerType" | "parentAccessible"> {
  let parentAccessible = false;
  try {
    void targetWindow.parent.document;
    parentAccessible = true;
  } catch {
    parentAccessible = false;
  }
  return {
    bridgeType: typeof (targetWindow as Window & { maru?: unknown }).maru,
    handlerType: typeof (
      targetWindow as Window & {
        webkit?: { messageHandlers?: { maru?: unknown } };
      }
    ).webkit?.messageHandlers?.maru,
    parentAccessible,
  };
}

function isRendererReady(value: unknown): value is RendererReady {
  return (
    isRecord(value) &&
    value.channel === viewerChannel &&
    value.type === "renderer-ready" &&
    typeof value.bridgeType === "string" &&
    value.bridgeType.length <= 32 &&
    typeof value.handlerType === "string" &&
    value.handlerType.length <= 32 &&
    typeof value.parentAccessible === "boolean"
  );
}

// page world는 `window.maru`를 직접 보지 않는다. 고정 DOM mailbox에 요청을 쓰고 isolated-world shim이 처리한
// JSON-RPC reply만 읽는다. 완료/오류에서 항상 node와 listener를 제거해 파일 bytes가 shell DOM에 남지 않는다.
export function requestFileBridge(
  document: Document,
  method: "read",
  value: ReadRequest,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "revokeMermaid",
  value: RevokeMermaidRequest,
  timeoutMs?: number | null,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "rendererReady",
  value: ReadRequest,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "renderMermaid",
  value: RenderMermaidRequest,
  timeoutMs?: number | null,
  signal?: AbortSignal,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "beginDocument",
  value: BeginDocumentRequest,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "readAsset",
  value: string,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "readSelfImage",
  value?: undefined,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "diffOpen",
  value?: undefined,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "write",
  value: WriteRequest,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "setDirty",
  value: DirtyReport,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "resolveExternalChange",
  value: ResolveExternalChangeRequest,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "openLink",
  value: OpenLinkRequest,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "menuOpen",
  value: MenuOpenParams,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: FileMethod,
  value?: unknown,
  timeoutMs: number | null = 15_000,
  signal?: AbortSignal,
): Promise<BridgeResult> {
  return new Promise((resolve, reject) => {
    const node = document.createElement("span");
    node.hidden = true;
    node.dataset.maruFileRequest = "pending";
    node.dataset.maruFileRequestId = String(++bridgeRequestId);
    let request: FileBridgeRequest;
    switch (method) {
      case "read":
        if (!isRecord(value) || !isSafeInt(value.editor_epoch) || value.editor_epoch <= 0)
          throw new TypeError("invalid read payload");
        request = { method, editor_epoch: value.editor_epoch as number };
        break;
      case "beginDocument":
        if (!isRecord(value) || !isSafeInt(value.document_id) || value.document_id <= 0)
          throw new TypeError("invalid beginDocument payload");
        request = { method, document_id: value.document_id as number };
        break;
      case "readAsset":
        if (typeof value !== "string") throw new TypeError("invalid readAsset payload");
        request = { method, path: value };
        break;
      case "readSelfImage":
        request = { method };
        break;
      case "diffOpen":
        request = { method };
        break;
      case "write":
        if (
          !isRecord(value) ||
          !isSafeInt(value.editor_epoch) ||
          value.editor_epoch <= 0 ||
          typeof value.content !== "string"
        )
          throw new TypeError("invalid write payload");
        request = {
          method,
          editor_epoch: value.editor_epoch as number,
          content: value.content,
        };
        break;
      case "setDirty":
        if (
          !isRecord(value) ||
          typeof value.dirty !== "boolean" ||
          !isSafeInt(value.editor_epoch) ||
          value.editor_epoch <= 0 ||
          !isSafeInt(value.revision) ||
          value.revision < 0 ||
          !isSafeInt(value.request_id) ||
          value.request_id < 0
        ) {
          throw new TypeError("invalid setDirty payload");
        }
        request = {
          method,
          dirty: value.dirty,
          editor_epoch: value.editor_epoch as number,
          revision: value.revision as number,
          request_id: value.request_id as number,
        };
        break;
      case "resolveExternalChange":
        if (
          !isRecord(value) ||
          !isSafeInt(value.editor_epoch) ||
          value.editor_epoch <= 0 ||
          typeof value.success !== "boolean"
        )
          throw new TypeError("invalid resolveExternalChange payload");
        request = {
          method,
          editor_epoch: value.editor_epoch as number,
          success: value.success,
        };
        break;
      case "openLink":
        if (
          !isRecord(value) ||
          !isSafeInt(value.editor_epoch) ||
          value.editor_epoch <= 0 ||
          typeof value.href !== "string" ||
          typeof value.forceSystem !== "boolean"
        ) {
          throw new TypeError("invalid openLink payload");
        }
        request = {
          method,
          editor_epoch: value.editor_epoch as number,
          href: value.href,
          forceSystem: value.forceSystem,
        };
        break;
      case "renderMermaid":
        if (
          !isRecord(value) ||
          !isSafeInt(value.editor_epoch) ||
          value.editor_epoch <= 0 ||
          !isSafeInt(value.document_revision) ||
          value.document_revision < 0 ||
          !isSafeInt(value.projection_generation) ||
          value.projection_generation <= 0 ||
          !isSafeInt(value.widget_id) ||
          value.widget_id <= 0 ||
          !isSafeInt(value.widget_generation) ||
          value.widget_generation <= 0 ||
          !isSafeInt(value.renderer_instance) ||
          value.renderer_instance <= 0 ||
          !isSafeInt(value.fence_id) ||
          value.fence_id <= 0 ||
          typeof value.source_hash !== "string" ||
          !/^[0-9a-f]{64}$/.test(value.source_hash) ||
          typeof value.source !== "string" ||
          value.source.length === 0 ||
          new TextEncoder().encode(value.source).byteLength > 32 * 1024
        ) {
          throw new TypeError("invalid renderMermaid payload");
        }
        request = {
          method,
          editor_epoch: value.editor_epoch as number,
          document_revision: value.document_revision as number,
          projection_generation: value.projection_generation as number,
          widget_id: value.widget_id as number,
          widget_generation: value.widget_generation as number,
          renderer_instance: value.renderer_instance as number,
          fence_id: value.fence_id as number,
          source_hash: value.source_hash,
          source: value.source,
        };
        break;
      case "revokeMermaid":
        if (
          !isRecord(value) ||
          !isSafeInt(value.editor_epoch) ||
          value.editor_epoch <= 0 ||
          !isSafeInt(value.document_revision) ||
          value.document_revision < 0 ||
          !isSafeInt(value.projection_generation) ||
          value.projection_generation <= 0 ||
          !isSafeInt(value.widget_id) ||
          value.widget_id <= 0 ||
          !isSafeInt(value.widget_generation) ||
          value.widget_generation <= 0 ||
          !isSafeInt(value.renderer_instance) ||
          value.renderer_instance <= 0
        ) {
          throw new TypeError("invalid revokeMermaid payload");
        }
        request = {
          method,
          editor_epoch: value.editor_epoch as number,
          document_revision: value.document_revision as number,
          projection_generation: value.projection_generation as number,
          widget_id: value.widget_id as number,
          widget_generation: value.widget_generation as number,
          renderer_instance: value.renderer_instance as number,
        };
        break;
      case "rendererReady":
        if (!isRecord(value) || !isSafeInt(value.editor_epoch) || value.editor_epoch <= 0)
          throw new TypeError("invalid rendererReady payload");
        request = { method, editor_epoch: value.editor_epoch as number };
        break;
      case "menuOpen": {
        // 좌표·대상은 문서(적대적일 수 있다)가 정하는 값이라 여기서 한 번, native가 다시 한 번 검사한다.
        if (
          !isRecord(value) ||
          !isSafeInt(value.editor_epoch) ||
          (value.editor_epoch as number) <= 0 ||
          typeof value.x !== "number" ||
          !Number.isFinite(value.x) ||
          typeof value.y !== "number" ||
          !Number.isFinite(value.y) ||
          typeof value.has_selection !== "boolean" ||
          typeof value.href !== "string" ||
          value.href.length > 4096
        ) {
          throw new TypeError("invalid menuOpen payload");
        }
        const target = value.target;
        if (target !== "text" && target !== "link" && target !== "image" && target !== "empty")
          throw new TypeError("invalid menuOpen payload");
        request = {
          method,
          editor_epoch: value.editor_epoch as number,
          x: value.x,
          y: value.y,
          target,
          has_selection: value.has_selection,
          href: value.href,
        };
        break;
      }
      case "menuOpen": {
        // 좌표·대상은 문서(적대적일 수 있다)가 정하는 값이라 여기서 한 번, native가 다시 한 번 검사한다.
        if (
          !isRecord(value) ||
          !isSafeInt(value.editor_epoch) ||
          (value.editor_epoch as number) <= 0 ||
          typeof value.x !== "number" ||
          !Number.isFinite(value.x) ||
          typeof value.y !== "number" ||
          !Number.isFinite(value.y) ||
          typeof value.has_selection !== "boolean" ||
          typeof value.href !== "string" ||
          value.href.length > 4096
        ) {
          throw new TypeError("invalid menuOpen payload");
        }
        const target = value.target;
        if (target !== "text" && target !== "link" && target !== "image" && target !== "empty")
          throw new TypeError("invalid menuOpen payload");
        request = {
          method,
          editor_epoch: value.editor_epoch as number,
          x: value.x,
          y: value.y,
          target,
          has_selection: value.has_selection,
          href: value.href,
        };
        break;
      }
    }
    node.textContent = JSON.stringify(encodeFileBridgeRequest(request));
    document.documentElement.append(node);

    let settled = false;
    const cleanup = () => {
      if (settled) return;
      settled = true;
      if (timer !== null) clearTimeout(timer);
      document.removeEventListener("maru:file-response", onResponse);
      signal?.removeEventListener("abort", onAbort);
      node.remove();
    };
    const onResponse = () => {
      if (node.dataset.maruFileRequest !== "done") return;
      try {
        const reply: unknown = JSON.parse(node.textContent ?? "null");
        if (!isRecord(reply) || !isRecord(reply.result) || reply.error !== undefined) {
          throw new Error("file bridge rejected the request");
        }
        cleanup();
        resolve(reply.result);
      } catch (error) {
        cleanup();
        reject(error instanceof Error ? error : new Error("invalid file bridge response"));
      }
    };
    // 수명 전환(disable/destroy/replacement)이 응답 없는 mailbox를 로컬에서 정확히 한 번 종료한다. native
    // 응답 timeout(있으면)과 별개로 listener·hidden node를 즉시 회수하고 Promise를 reject해 stuck await를 푼다.
    const onAbort = () => {
      cleanup();
      reject(new DOMException("file bridge request aborted", "AbortError"));
    };
    const timer =
      timeoutMs === null
        ? null
        : setTimeout(() => {
            cleanup();
            reject(new Error("file bridge timeout"));
          }, timeoutMs);
    document.addEventListener("maru:file-response", onResponse);
    if (signal !== undefined) {
      if (signal.aborted) {
        onAbort();
        return;
      }
      signal.addEventListener("abort", onAbort);
    }
    const EventConstructor = document.defaultView?.Event ?? Event;
    document.dispatchEvent(new EventConstructor("maru:file-request"));
  });
}

// rehype-prism-plus가 코드 각 줄을 span으로 쪼개므로 `code.language-mermaid`의 textContent는 줄 사이 개행을 잃는다
// ("flowchart TB"+"A --> B" → "flowchart TBA --> B" → mermaid 파싱 에러). markdown.ts의 rehypeSourcePositions가
// <pre>/<code>에 붙인 원본 오프셋(data-maru-source-start/end="line:column:offset")으로 원본 마크다운에서 펜스를 그대로
// 잘라 개행을 보존한다. 오프셋이 없거나 범위가 이상하면 null → 호출부가 textContent로 폴백한다.
function sliceMermaidFence(element: HTMLElement, markdown: string): string | null {
  const start = decodeSourceOffset(element.dataset.maruSourceStart);
  const end = decodeSourceOffset(element.dataset.maruSourceEnd);
  if (start === null || end === null || end <= start || end > markdown.length) return null;
  const sliced = markdown.slice(start, end);
  return sliced.length > 0 ? sliced : null;
}

function decodeSourceOffset(encoded: string | undefined): number | null {
  if (encoded === undefined) return null;
  const offset = Number(encoded.split(":")[2]);
  return isInt(offset) && offset >= 0 ? offset : null;
}

/// Product Mermaid adapter. The native exact terminal and the action-relative Swift fallback are the
/// only timeout authorities, so this mailbox deliberately has no independent Web timer.
export async function renderMermaidFromBridge(
  document: Document,
  status: HTMLElement | null,
  capability: RendererCapability,
  fenceId: number,
  sourceHash: string,
  source: string,
  signal?: AbortSignal,
): Promise<string | null> {
  if (status !== null) status.dataset.mermaidRequest = "pending";
  try {
    const result = await requestFileBridge(
      document,
      "renderMermaid",
      {
        editor_epoch: capability.editorEpoch,
        document_revision: capability.documentRevision,
        projection_generation: capability.projectionGeneration,
        widget_id: capability.widgetId,
        widget_generation: capability.widgetGeneration,
        renderer_instance: capability.rendererInstance,
        fence_id: fenceId,
        source_hash: sourceHash,
        source,
      },
      null,
      signal,
    );
    const svg = typeof result.svg === "string" ? result.svg : null;
    if (status !== null) status.dataset.mermaidRequest = svg === null ? "invalid" : "ok";
    return svg;
  } catch {
    if (status !== null) status.dataset.mermaidRequest = "error";
    return null;
  }
}

/// Revoke is a best-effort lifecycle command rather than a render result. Bound its page mailbox so an
/// unresponsive isolated bridge cannot retain retired widget nodes/listeners for the generic 15s timeout.
export function revokeMermaidFromBridge(
  document: Document,
  capability: RendererCapability,
): Promise<BridgeResult> {
  return requestFileBridge(
    document,
    "revokeMermaid",
    {
      editor_epoch: capability.editorEpoch,
      document_revision: capability.documentRevision,
      projection_generation: capability.projectionGeneration,
      widget_id: capability.widgetId,
      widget_generation: capability.widgetGeneration,
      renderer_instance: capability.rendererInstance,
    },
    2_500,
  );
}

function bytesToBase64(bytes: Uint8Array, targetWindow: ViewerWindow): string {
  let binary = "";
  const chunkSize = 0x8000;
  for (let offset = 0; offset < bytes.length; offset += chunkSize) {
    binary += String.fromCharCode(...bytes.subarray(offset, offset + chunkSize));
  }
  return targetWindow.btoa(binary);
}

export function assetDataUrl(
  mime: string,
  dataBase64: string,
  targetWindow: ViewerWindow,
): string | null {
  const raster = new Set(["image/png", "image/jpeg", "image/gif", "image/webp", "image/avif"]);
  try {
    const binary = targetWindow.atob(dataBase64);
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    if (!assetMimeMatchesMagic(mime, bytes)) return null;
    if (raster.has(mime)) return `data:${mime};base64,${dataBase64}`;
    if (mime !== "image/svg+xml") return null;
    const source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    const sanitized = sanitizeMermaidSvg(source, targetWindow);
    const encoded = bytesToBase64(new TextEncoder().encode(sanitized), targetWindow);
    return `data:image/svg+xml;base64,${encoded}`;
  } catch {
    return null;
  }
}

// FP13: svg 파일 프리뷰. 원문 SVG를 sanitize(script/event/외부 URL 제거)한 뒤 `data:` URL로 만든다. `<img>`로
// 표시하므로 sanitize를 뚫어도 이미지 컨텍스트라 스크립트가 실행되지 않는다(격리 render origin, capability 0).
export function svgToDataUrl(source: string, targetWindow: ViewerWindow): string | null {
  const trimmed = source.trimStart();
  if (!(trimmed.startsWith("<svg") || /^<\?xml[^>]*>\s*<svg\b/i.test(trimmed))) return null;
  try {
    const sanitized = sanitizeMermaidSvg(source, targetWindow);
    const encoded = bytesToBase64(new TextEncoder().encode(sanitized), targetWindow);
    return `data:image/svg+xml;base64,${encoded}`;
  } catch {
    return null;
  }
}

export function assetMimeMatchesMagic(mime: string, bytes: Uint8Array): boolean {
  const starts = (...prefix: number[]) =>
    bytes.length >= prefix.length && prefix.every((value, index) => bytes[index] === value);
  if (mime === "image/png") return starts(0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a);
  if (mime === "image/jpeg") return starts(0xff, 0xd8, 0xff);
  if (mime === "image/gif") {
    const header = String.fromCharCode(...bytes.subarray(0, 6));
    return header === "GIF87a" || header === "GIF89a";
  }
  if (mime === "image/webp") {
    return (
      String.fromCharCode(...bytes.subarray(0, 4)) === "RIFF" &&
      String.fromCharCode(...bytes.subarray(8, 12)) === "WEBP"
    );
  }
  if (mime === "image/avif") {
    const header = String.fromCharCode(...bytes.subarray(4, Math.min(bytes.length, 32)));
    return header.startsWith("ftyp") && (header.includes("avif") || header.includes("avis"));
  }
  if (mime !== "image/svg+xml") return false;
  try {
    const source = new TextDecoder("utf-8", { fatal: true }).decode(bytes).trimStart();
    return source.startsWith("<svg") || /^<\?xml[^>]*>\s*<svg\b/i.test(source);
  } catch {
    return false;
  }
}

/// Save completion compares the persistent CM6 Text snapshot, not revision equality. A later edit keeps dirty;
/// an edit followed by undo may advance the monotonic revision while returning to the exact saved content.
export function documentIsDirtyAgainstSnapshot(current: Text, saved: Text | null): boolean {
  return saved === null || !current.eq(saved);
}

// `Window & typeof globalThis`인 이유: 이 함수는 `targetWindow.MouseEvent`처럼 **그 창의 전역 생성자**로
// instanceof 판정을 한다(다른 창/iframe 인스턴스를 정확히 가르려면 그 창의 생성자여야 한다). 그냥 `Window`면
// 그 속성들이 타입에 없다 — 이 파일이 타입 검사 밖이라 여태 안 드러났다.
export function bootShell(document: Document, targetWindow: ViewerWindow): void {
  const frame = document.querySelector<HTMLIFrameElement>("#renderer");
  const editorHost = document.querySelector<HTMLElement>("#editor");
  const status = document.querySelector<HTMLElement>("#viewer-status");
  if (frame === null || editorHost === null) return;

  // text/svg kind(docs/file-panel.md §2.2·§2.3): shell URL `?lang=`은 소스 편집기 문법, `?kind=svg`는 svg의
  // read(격리 sanitize 프리뷰)+source(xml 편집) 두 모드를 켠다. 둘 다 mermaid 없이 read/write·dirty·⌘S·
  // 외부변경 배관만 markdown과 공유하고 rendererReady(markdown 전용 gate)는 호출하지 않는다.
  const shellParams = new URL(targetWindow.location.href).searchParams;
  const sourceLanguageWire = shellParams.get("lang");
  const isSvg = shellParams.get("kind") === "svg";
  // text = read 모드 없는 소스 전용. svg는 read 프리뷰가 있어 source-only가 아니다.
  // (FP14b: image는 격리 loadFileURL 문서로 옮겨가 이 shell을 더 이상 타지 않는다.)
  const isSourceOnly = sourceLanguageWire !== null && !isSvg;

  let editor: EditorView | null = null;
  // 리치 모드(§2.5)의 문서모델 편집기. CM6와 동시에 살 수 있지만 화면에는 한 번에 하나만 보인다.
  let richEditor: RichEditorHandle | null = null;
  let richHost: HTMLElement | null = null;
  let savedContent = "";
  let savedDocument: Text | null = null;
  let contentLoaded = false;
  let dirty = false;
  let editorEpoch: number | null = null;
  const revisions = new EditorRevisionClock();
  // text는 source_edit 단일 모드다(allowedFor). 처음부터 source-edit로 시작해 read용 render iframe이 잠깐도
  // 뜨지 않게 한다.
  let mode: FilePanelMode = isSourceOnly ? "source-edit" : "read";
  let rendererReady = false;
  // didFinish의 native dirty-sync가 shell beginDocument+initial read보다 먼저 올 수 있다. 모든 mutation은 이
  // hydration barrier 뒤에서 기다리고, start 자체는 queue 밖에서 barrier를 해소해 순환 대기를 만들지 않는다.
  let settleDocumentInitialization: () => void = () => {};
  let mutationQueue = new Promise<void>((resolve) => {
    settleDocumentInitialization = resolve;
  });
  let dirtySyncInFlight: Promise<boolean> | null = null;
  let closeLockRequestId: number | null = null;
  let applyingDiskContent = false;
  let assetBase64Bytes = 0;
  let assetRequests = 0;
  // 읽기 프리뷰 mermaid: render iframe이 펜스별로 SVG를 요청하면 여기서 native 헬퍼로 렌더한다.
  // 순차 queue라 헬퍼 1개를 순서대로 태운다. widget_id는 펜스마다 달라야 coordinator가 dedup 안 한다(단조 증가).
  let readMermaidQueue = Promise.resolve();
  let readMermaidWidget = 0;

  /// 두 편집기 중 지금 보이는 쪽이 IME 조합 중인가. close lock·dirty ACK가 이 판정을 공유한다.
  const isComposing = (): boolean =>
    mode === "rich" ? (richEditor?.isComposing() ?? false) : editor?.composing === true;

  /// 지금 화면이 가진 내용을 마크다운 한 벌로 만든다. 모드 전환·저장·읽기 프리뷰가 모두 이 하나를 쓴다(§2.5).
  const currentMarkdown = (): string => {
    if (mode === "rich" && richEditor !== null) return richEditor.getMarkdown();
    return editor?.state.doc.toString() ?? savedContent;
  };

  const currentDocumentIsDirty = (): boolean => {
    // 리치는 문서모델이라 CM6 `Text` 비교를 쓸 수 없다. 직렬화 결과를 마지막 저장 내용과 견준다 —
    // 왕복 정규화가 일어나면 사용자가 타이핑하지 않아도 dirty가 될 수 있고, 그것이 §2.5가 수용한 대가다.
    if (mode === "rich") return richEditor !== null && richEditor.getMarkdown() !== savedContent;
    return editor !== null && documentIsDirtyAgainstSnapshot(editor.state.doc, savedDocument);
  };

  /**
   * 리치가 보여 줄 이미지 바이트를 shell 브리지로 읽어 data URL로 만든다.
   *
   * 읽기 경로가 쓰는 것과 **같은 브리지·같은 변환**이다(`readAsset` → `assetDataUrl`) — `assetDataUrl`이
   * mime과 매직 바이트가 맞는지 다시 보고, SVG는 sanitize를 거친다. 리치만의 완화 경로를 만들지 않는다.
   *
   * 실패는 조용하다. 이미지가 안 보일 뿐 문서와 저장 결과는 영향받지 않는다.
   */
  const resolveRichAsset = async (path: string): Promise<string | null> => {
    try {
      const result = await requestFileBridge(document, "readAsset", path);
      if (typeof result.mime !== "string" || typeof result.data_base64 !== "string") return null;
      return assetDataUrl(result.mime, result.data_base64, targetWindow);
    } catch {
      return null;
    }
  };

  const setCloseLocked = (requestId: number | null) => {
    closeLockRequestId = requestId;
    if (editor !== null) editor.contentDOM.contentEditable = requestId === null ? "true" : "false";
    // 리치도 함께 잠근다. 여기서 빠뜨리면 close-confirm이 떠 있는 동안 사용자가 계속 타이핑하고, ACK가
    // clean이었다면 native가 프롬프트 없이 탭을 닫아 그 입력이 통째로 버려진다.
    richEditor?.setEditable(requestId === null);
  };

  const syncDirty = async (next: boolean, requestId = 0) => {
    if (editorEpoch === null) throw new Error("editor document epoch is unavailable");
    let lastError: unknown;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        await requestFileBridge(document, "setDirty", {
          dirty: next,
          editor_epoch: editorEpoch,
          revision: revisions.documentRevision,
          request_id: requestId,
        });
        return;
      } catch (error) {
        lastError = error;
      }
    }
    throw lastError;
  };

  const syncDirtyForClose = async (requestId: number): Promise<boolean> => {
    // 오래 지연된 request가 더 최신 close owner를 덮지 못한다. 같은 request 재호출은 idempotent이고 새 request만
    // 이전 owner를 supersede한다. 진행 중 IME marked text는 CM6 state transaction에 아직 없을 수 있으므로
    // contentEditable을 끄기 전에 fail-closed한다(조합이 끝난 뒤 사용자가 다시 닫는다).
    // 조합 중이면 fail-closed한다 — CM6든 리치든 marked text가 아직 문서에 없을 수 있다. 리치에서
    // `editor?.composing`은 항상 undefined라 CM6만 보면 한글 조합 중에도 탭이 닫힌다.
    if (!closeLockCanAcquire(closeLockRequestId, requestId) || isComposing()) return false;
    setCloseLocked(requestId);
    const operation = mutationQueue.then(async () => {
      const actual = currentDocumentIsDirty();
      dirty = actual;
      await syncDirty(actual, requestId);
      return true;
    });
    mutationQueue = operation.then(
      () => undefined,
      () => undefined,
    );
    try {
      return await operation;
    } catch {
      if (closeLockRequestId === requestId) setCloseLocked(null);
      return false;
    }
  };

  const syncDirtyNow = (): Promise<boolean> => {
    // 탭 이탈 snapshot은 editor hydration 전에도 clean=false가 아니라 **편집 불가능한 clean**으로 ACK할 수 있다.
    // 함수 자체를 boot 시 설치해 native one-shot이 listener 등록/CM6 생성 사이에서 유실되지 않게 하고, 실제 dirty
    // 판정과 bridge ack는 다른 mutation과 같은 직렬 queue에서 수행한다.
    if (dirtySyncInFlight !== null) return dirtySyncInFlight;
    const operation = mutationQueue.then(async () => {
      const actual = currentDocumentIsDirty();
      dirty = actual;
      await syncDirty(actual);
    });
    mutationQueue = operation.then(
      () => undefined,
      () => undefined,
    );
    const result = operation.then(
      () => true,
      () => false,
    );
    dirtySyncInFlight = result;
    void result.then(() => {
      if (dirtySyncInFlight === result) dirtySyncInFlight = null;
    });
    return result;
  };

  const reportDirty = (next: boolean, force = false) => {
    if (!force && next === dirty) return;
    dirty = next;
    mutationQueue = mutationQueue
      .then(async () => {
        // save가 queue 앞에서 savedContent 기준점을 바꿀 수 있으므로 예약 당시의 boolean을 재사용하지 않고
        // 실행 시점 문서로 다시 계산한다. 그러면 save 중 입력/undo가 어떤 순서여도 마지막 native dirty가 맞다.
        const actual = currentDocumentIsDirty();
        dirty = actual;
        await syncDirty(actual);
      })
      .catch(() => {
        if (status !== null) status.textContent = "편집 상태를 동기화할 수 없습니다.";
      });
  };

  const save = async (): Promise<boolean> => {
    if (editorEpoch === null) return false;
    // epoch도 **지금** 고정한다(아래 mode와 같은 이유). queue 콜백은 나중에 도는데 그 사이 document가 교체되면
    // `editorEpoch`가 다른 값이 되어, 방금 검사한 것과 다른 문서에 쓰게 된다. 타입 검사가 이 구멍을 짚어 줬다.
    const saving_epoch = editorEpoch;
    if (editor === null && richEditor === null) return false;
    // mode는 **지금** 고정한다. queue 콜백 안에서 읽으면 저장이 끝나기 전 사용자가 모드를 바꿨을 때
    // 다른 모드의 기준점을 갱신해 dirty 판정이 어긋난다.
    const savingMode = mode;
    const documentSnapshot = editor?.state.doc ?? null;
    const content = currentMarkdown();
    const operation = mutationQueue.then(async () => {
      await requestFileBridge(document, "write", { editor_epoch: saving_epoch, content });
      savedContent = content;
      if (documentSnapshot !== null && savingMode !== "rich") savedDocument = documentSnapshot;
      // Native write는 dirty를 임의로 내리지 않는다. 저장 중 문서가 다시 바뀌었는지 같은 직렬 queue에서 판정해
      // 최종 값 하나를 보내므로 write 완료와 재편집 사이에 eviction 가능한 false 구간이 생기지 않는다.
      const nextDirty = currentDocumentIsDirty();
      dirty = nextDirty;
      await syncDirty(nextDirty);
    });
    mutationQueue = operation.catch(() => {});
    try {
      await operation;
      if (status !== null) status.textContent = "";
      return true;
    } catch {
      // 저장 실패 안내는 native가 chrome 모달(showNotice)로 띄운다. 웹뷰 안 sticky 텍스트는 한 번 뜨면 안 사라져
      // (성공해야만 지워짐) 자연스럽지 않았다 — 여기서는 남은 텍스트만 지우고 native 알림에 맡긴다.
      if (status !== null) status.textContent = "";
      return false;
    }
  };
  const closeApi = targetWindow as Window & {
    __maruSyncDirty?: () => Promise<boolean>;
    __maruSyncDirtyForClose?: (requestId: number) => Promise<boolean>;
    __maruSaveForClose?: (
      requestId: number,
    ) => Promise<{ success: boolean; revision: number; dirty: boolean }>;
    __maruUnlockFileClose?: (requestId: number) => Promise<boolean>;
    __maruSelectAll?: () => boolean;
  };
  closeApi.__maruSyncDirty = syncDirtyNow;
  closeApi.__maruSyncDirtyForClose = syncDirtyForClose;
  // 메뉴 Edit>Select All(클릭)은 native selectAll:을 responder chain으로 보내는데, 그건 WKWebView의 렌더된(가상화)
  // DOM만 고른다. CM6 문서 전체를 선택하는 명령을 노출해 native가 이걸 우선 호출한다(키보드 ⌘A는 아래 capture
  // 리스너가 직접 처리). 편집기가 없으면(읽기 프리뷰) false를 돌려 native selectAll:로 폴백.
  const selectWholeDocument = (): boolean => {
    // 리치 모드에서는 CM6가 살아 있어도 화면 밖(display:none)이다. mode를 안 보면 숨은 문서를 선택하고
    // true를 돌려 native selectAll: 폴백까지 막아, 사용자 화면에서는 아무것도 선택되지 않는다.
    if (mode === "rich") return richEditor?.selectAll() ?? false;
    if (mode !== "source-edit" || editor === null) return false;
    editor.dispatch({ selection: { anchor: 0, head: editor.state.doc.length } });
    editor.focus();
    return true;
  };
  closeApi.__maruSelectAll = selectWholeDocument;
  // 키보드 ⌘A: web_editor route라 keyDown이 WKWebView에 도달하지만, WKWebView 기본 selectAll:이 렌더된 DOM만
  // 고른다. capture 단계에서 먼저 잡아 CM6 문서 전체를 동기적으로 선택하고 기본 동작을 막는다(비동기 왕복 없이
  // 즉시 반영). 편집기 포커스일 때만 개입한다.
  document.addEventListener(
    "keydown",
    (event) => {
      if (
        (event.metaKey || event.ctrlKey) &&
        !event.shiftKey &&
        !event.altKey &&
        (event.key === "a" || event.key === "A") &&
        editor !== null &&
        editor.hasFocus
      ) {
        if (selectWholeDocument()) {
          event.preventDefault();
          event.stopPropagation();
        }
      }
    },
    true,
  );
  closeApi.__maruSaveForClose = async (requestId: number) => {
    if (!isSafeInt(requestId) || closeLockRequestId !== requestId) {
      return { success: false, revision: revisions.documentRevision, dirty: true };
    }
    const success = await save();
    const actual = currentDocumentIsDirty();
    if ((!success || actual) && closeLockRequestId === requestId) setCloseLocked(null);
    return { success, revision: revisions.documentRevision, dirty: actual };
  };
  closeApi.__maruUnlockFileClose = async (requestId: number) => {
    if (!closeUnlockOwnsLock(closeLockRequestId, requestId)) return false;
    // close request ids never wrap/reuse. A newer cancelled request retires an older lock when its own sync was
    // cancelled before reaching the page; an older stale unlock can never retire the current newer owner.
    setCloseLocked(null);
    try {
      const actual = currentDocumentIsDirty();
      dirty = actual;
      await syncDirty(actual);
      return true;
    } catch {
      return false;
    }
  };

  const ensureRichEditor = (): RichEditorHandle => {
    if (richEditor !== null) return richEditor;
    if (richHost === null) {
      richHost = document.createElement("div");
      richHost.id = "rich-editor";
      editorHost.parentElement?.insertBefore(richHost, editorHost);
    }
    richEditor = createRichEditor(
      richHost,
      currentMarkdown(),
      () => {
        if (applyingDiskContent) return;
        revisions.documentChanged();
        reportDirty(currentDocumentIsDirty());
      },
      () => void save(),
      resolveRichAsset,
    );
    if (closeLockRequestId !== null) richEditor.setEditable(false);
    return richEditor;
  };

  const ensureEditor = (): EditorView => {
    if (editor !== null) return editor;
    if (editorEpoch === null) throw new Error("editor document epoch is unavailable");
    if (isSourceOnly || isSvg) {
      // text 소스 전용·svg 소스 모드 공용 경로. onChange는 dirty 추적만 한다. svg는 read 모드에서 프리뷰를 갱신한다.
      editor = createSourceEditor(
        editorHost,
        savedContent,
        sourceLanguageExtensions(sourceLanguageWire),
        (update) => {
          // 디스크 내용을 적용하는 중의 transaction은 사용자 편집이 아니므로 dirty를 올리지 않는다.
          if (applyingDiskContent) return;
          if (update.docChanged) {
            revisions.documentChanged();
            reportDirty(savedDocument === null || !update.state.doc.eq(savedDocument));
          }
        },
        () => void save(),
      );
      savedDocument = editor.state.doc;
      if (closeLockRequestId !== null) editor.contentDOM.contentEditable = "false";
      return editor;
    }
    // markdown 소스 모드. 읽기 프리뷰는 별도 render iframe이 소유하므로 편집기는 생 Markdown만 다룬다.
    editor = createMarkdownEditor(
      editorHost,
      savedContent,
      (update) => {
        // 디스크 내용을 적용하는 중의 transaction은 사용자 편집이 아니므로 dirty를 올리지 않는다.
        if (applyingDiskContent) return;
        if (update.docChanged) {
          revisions.documentChanged();
          reportDirty(savedDocument === null || !update.state.doc.eq(savedDocument));
        }
      },
      () => void save(),
    );
    savedDocument = editor.state.doc;
    if (closeLockRequestId !== null) editor.contentDOM.contentEditable = "false";
    return editor;
  };

  // 읽기 모드 프리뷰를 render iframe에 보낸다. svg=sanitize 프리뷰(`renderSvg`), markdown=`render`.
  // text는 프리뷰가 없어 no-op이다. 현재 편집 중 내용(editor)이 있으면 그걸, 없으면 마지막 로드/저장 snapshot을 쓴다.
  const postPreview = () => {
    if (!rendererReady || isSourceOnly) return;
    const content = currentMarkdown();
    frame.contentWindow?.postMessage(
      isSvg
        ? { channel: viewerChannel, type: "renderSvg", svg: content }
        : { channel: viewerChannel, type: "render", markdown: content },
      "*",
    );
  };

  const applyMode = (next: FilePanelMode) => {
    const previous = mode;
    // 전환 시점의 내용을 마크다운 한 벌로 만들어 상대 편집기에 넘긴다(§2.5). 이 텍스트가 이후의 유일한 기준이다.
    const carried = previous === next ? null : currentMarkdown();
    mode = next;
    if (carried !== null && contentLoaded) {
      if (next === "rich") {
        // 방금 만든 편집기는 이미 그 내용으로 파싱됐다. 다시 setMarkdown하면 같은 문서를 두 번 파싱한다.
        const existed = richEditor !== null;
        const rich = ensureRichEditor();
        if (existed) rich.setMarkdown(carried);
      } else if (previous === "rich") {
        // 리치를 **어느 모드로 벗어나든** 그 결과를 CM6 문서로 확정한다. 읽기 프리뷰(`postPreview`)와 저장이
        // 모두 CM6/savedContent를 보므로, 여기서 넘기지 않으면 리치에서 편집한 내용이 프리뷰에 반영되지 않는다.
        const cm = ensureEditor();
        cm.dispatch({ changes: { from: 0, to: cm.state.doc.length, insert: carried } });
        // 리치에서 이미 저장을 마쳤다면 이 문서가 곧 saved 상태다. 기준점을 함께 옮기지 않으면 CM6 dirty
        // 판정이 옛 snapshot과 비교해 저장 직후에도 dirty로 남는다(탭 ●·닫기 확인이 계속 뜬다).
        if (carried === savedContent) savedDocument = cm.state.doc;
      }
    }
    if (isEditableFileMode(mode)) {
      frame.hidden = true;
      const rich = mode === "rich";
      editorHost.hidden = rich;
      if (richHost !== null) richHost.hidden = !rich;
      if (contentLoaded) {
        if (rich) ensureRichEditor().focus();
        else ensureEditor().focus();
      }
    } else {
      if (editor !== null || richEditor !== null) reportDirty(currentDocumentIsDirty(), true);
      frame.hidden = false;
      editorHost.hidden = true;
      if (richHost !== null) richHost.hidden = true;
      postPreview();
    }
    document.body.dataset.fileMode = mode;
  };

  targetWindow.addEventListener("maru:file-mode", (event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    if (!isRecord(detail)) return;
    // text는 source_edit 단일 모드라 read 신호는 무시한다(native도 보내지 않지만 방어적으로 고정).
    if (isSourceOnly) {
      if (detail.mode === "source-edit") applyMode("source-edit");
      return;
    }
    if (detail.mode === "read" || detail.mode === "rich" || detail.mode === "source-edit")
      applyMode(detail.mode);
  });
  // §2.6: 본문 우클릭 → native 메뉴. web은 대상·좌표만 올린다. **고른 항목의 실행은 native가 표준 편집
  // 명령(cut:/copy:/paste:/selectAll:)으로 한다** — 키보드 단축키와 같은 경로라 서식도 되돌리기도 같다.
  // §2.6: 우클릭 직전의 **편집기 좌표** 선택. DOM Range는 편집기가 DOM을 다시 만들면 죽어서(실측) 못 쓴다.
  let menuEditorSelection: { from: number; to: number } | null = null;
  document.addEventListener(
    "mousedown",
    (event) => {
      if (event.button !== 2) return;
      menuEditorSelection =
        mode === "rich"
          ? (richEditor?.selectionRange() ?? null)
          : editor === null
            ? null
            : { from: editor.state.selection.main.from, to: editor.state.selection.main.to };
    },
    true,
  );

  installShellContextMenu({
    doc: document,
    targetWindow,
    channel: viewerChannel,
    getEditorEpoch: () => editorEpoch,
    frameRect: () => {
      const rect = frame.getBoundingClientRect();
      return { left: rect.left, top: rect.top };
    },
    openMenu: (request) => {
      void requestFileBridge(document, "menuOpen", request);
    },
    postToRenderer: (message: unknown) => {
      frame.contentWindow?.postMessage(message, "*");
    },
    restoreEditorSelection: () => {
      const range = menuEditorSelection;
      if (range === null || range.from === range.to) {
        return false;
      }
      if (mode === "rich") {
        if (richEditor === null) {
          return false;
        }
        richEditor.setSelectionRange(range.from, range.to);
        return true;
      }
      if (editor === null) {
        return false;
      }
      editor.dispatch({ selection: { anchor: range.from, head: range.to } });
      editor.focus();
      return true;
    },
  });

  // §2.3: ⌘+/− 폰트 줌을 읽기 프리뷰에도 반영한다(사용자 결정 2026-07-23). native가 `maru:file-zoom`으로 현재
  // 배율(현재 폰트/base)을 주면 render iframe에 `setZoom`으로 전달해 iframe이 `documentElement.zoom`으로 페이지
  // 줌한다(cross-origin이라 shell이 iframe DOM을 직접 못 건드림). iframe이 아직 준비 전이면 최신 배율을 캐시해
  // renderer-ready에서 다시 보낸다. 편집기(#editor)는 native가 `--maru-editor-font-size`(**px** — CoreText의 AppKit 포인트와 논리 픽셀이 1:1이라, CSS `pt`(1/72in)를 쓰면 터미널보다 33% 커진다)로 직접 스케일한다.
  let previewZoom = 1;
  const sendPreviewZoom = () => {
    frame.contentWindow?.postMessage(
      { channel: viewerChannel, type: "setZoom", zoom: previewZoom },
      "*",
    );
  };
  targetWindow.addEventListener("maru:file-zoom", (event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    if (!isRecord(detail) || typeof detail.zoom !== "number" || !Number.isFinite(detail.zoom))
      return;
    previewZoom = Math.min(10, Math.max(0.1, detail.zoom));
    sendPreviewZoom();
  });
  const loadFromDisk = async (
    syncNative: boolean,
    abortIfDirty = false,
    abortIfEditedDuringRead = false,
  ) => {
    const revisionBeforeRead = revisions.documentRevision;
    if (editorEpoch === null) throw new Error("editor document epoch is unavailable");
    const result = await requestFileBridge(document, "read", { editor_epoch: editorEpoch });
    if (typeof result.content !== "string") throw new Error("invalid file content");
    // clean auto-reload를 bridge read 대기 중 사용자가 편집하기 시작했다면 buffer를 절대 덮지 않는다.
    if (abortIfDirty && dirty) throw new Error("file became dirty during external reload");
    if (abortIfEditedDuringRead && revisions.documentRevision !== revisionBeforeRead) {
      throw new Error("file was edited during external reload");
    }
    const previousSavedContent = savedContent;
    savedContent = result.content;
    contentLoaded = true;
    if (editor !== null) {
      const previousDocument = editor.state.doc;
      if (dirty || result.content !== previousSavedContent) {
        applyingDiskContent = true;
        try {
          editor.dispatch({
            changes: { from: 0, to: editor.state.doc.length, insert: result.content },
          });
        } finally {
          applyingDiskContent = false;
        }
      }
      savedDocument = editor.state.doc;
      if (!editor.state.doc.eq(previousDocument)) revisions.documentChanged();
    } else {
      savedDocument = null;
    }
    // 리치 편집기도 같은 내용으로 다시 시드한다. **CM6 유무와 무관하게** 해야 한다 — 리치로 바로 들어온
    // 문서에는 CM6가 아직 없어서 위 블록을 타지 않는다. 여기서 빠뜨리면 리치 화면이 옛 문서를 들고 있다가
    // 다음 저장에 그 옛 내용을 디스크에 써서 **외부 편집을 조용히 되돌린다**(native는 conflict 해소로 안다).
    richEditor?.setMarkdown(result.content);
    dirty = false;
    if (syncNative) await syncDirty(false);
    // svg=sanitize 프리뷰, markdown=render. text(source-only)는 프리뷰가 없어 postPreview가 no-op이다.
    postPreview();
    if (isEditableFileMode(mode)) applyMode(mode);
  };

  targetWindow.addEventListener("maru:file-reload", (event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    const conflict = isRecord(detail) && detail.conflict === true;
    mutationQueue = mutationQueue
      .then(async () => {
        await loadFromDisk(false, !conflict, true);
        if (conflict) {
          if (editorEpoch === null) throw new Error("editor document epoch is unavailable");
          await requestFileBridge(document, "resolveExternalChange", {
            editor_epoch: editorEpoch,
            success: true,
          });
        }
        if (status !== null) {
          status.dataset.fileRead = "true";
          status.textContent = "";
        }
      })
      .catch(async () => {
        try {
          if (editorEpoch !== null)
            await requestFileBridge(document, "resolveExternalChange", {
              editor_epoch: editorEpoch,
              success: false,
            });
        } catch {}
        if (status !== null) {
          status.dataset.fileRead = "false";
          status.textContent = "외부 변경을 다시 읽을 수 없습니다.";
        }
      });
  });

  let started = false;
  const start = async () => {
    if (started) return;
    started = true;
    if (status !== null) status.dataset.rendererLoaded = "true";
    // 실제 파일 읽기(beginDocument + loadFromDisk)와 렌더 admission gate(rendererReady)를 **분리**한다. read가
    // 성공해 내용이 이미 렌더된 뒤 gate가 StaleDocument 등으로 일시 실패해도 "파일을 읽을 수 없습니다"로 덮어
    // 에러 텍스트와 렌더 내용이 겹치던 버그를 없앤다(간헐 race, 2026-07-22). read 실패만 사용자 에러다.
    let readOk = false;
    try {
      const documentId = Number(new URL(targetWindow.location.href).searchParams.get("document"));
      if (!isSafeInt(documentId) || documentId <= 0) throw new Error("invalid editor document id");
      const documentResult = await requestFileBridge(document, "beginDocument", {
        document_id: documentId,
      });
      if (!isSafeInt(documentResult.editor_epoch) || (documentResult.editor_epoch as number) <= 0)
        throw new Error("invalid editor document epoch");
      editorEpoch = documentResult.editor_epoch as number;
      if (status !== null) status.dataset.editorEpoch = String(editorEpoch);
      await loadFromDisk(false);
      readOk = true;
      if (status !== null) status.dataset.fileRead = "true";
      if (status !== null) status.textContent = "";
    } catch {
      if (status !== null) status.dataset.fileRead = "false";
      if (status !== null) status.textContent = "파일을 읽을 수 없습니다.";
    }
    // rendererReady는 markdown 전용 native gate라 text·svg에서 호출하면 StaleDocument로 실패한다(§2.2).
    // read 성공 후에만 시도하고, 일시 실패는 조용히 삼킨다 — 내용은 이미 표시됐으므로 read-error로 덮지 않는다.
    if (readOk && !isSourceOnly && !isSvg && editorEpoch !== null) {
      try {
        await requestFileBridge(document, "rendererReady", { editor_epoch: editorEpoch });
      } catch {
        // live gate 일시 실패 — 렌더된 내용을 유지한다(에러 표시 없음).
      }
    }
    // read 실패도 barrier를 해소한다. 뒤의 mutation은 editorEpoch null 검사로 false/error가 되어 native 보호를
    // 유지하며, 영구 대기 Promise를 남기지 않는다.
    settleDocumentInitialization();
  };
  frame.addEventListener(
    "load",
    () => {
      if (status !== null) status.dataset.rendererLoaded = "true";
      frame.contentWindow?.postMessage({ channel: viewerChannel, type: "ping" }, "*");
    },
    { once: true },
  );

  let assetQueue = Promise.resolve();
  targetWindow.addEventListener("message", (event) => {
    if (event.source !== frame.contentWindow) return;
    if (isRendererReady(event.data)) {
      rendererReady = true;
      if (status !== null) {
        status.dataset.rendererScriptReady = "true";
        status.dataset.rendererBridgeType = event.data.bridgeType;
        status.dataset.rendererHandlerType = event.data.handlerType;
        status.dataset.rendererParentAccessible = String(event.data.parentAccessible);
      }
      sendPreviewZoom(); // 새로/재로드된 iframe이 현재 ⌘+/− 배율로 착지하게 최신 값을 다시 보낸다(§2.3).
      if (contentLoaded) postPreview();
      return;
    }
    if (isRendererReport(event.data)) {
      // 첫 렌더 완료에서 읽기 iframe을 페이드인한다(app.css `#renderer[data-content-ready]`). 한 번 세우면
      // 유지돼 모드 왕복·재렌더에서 다시 깜빡이지 않는다.
      frame.dataset.contentReady = "true";
      if (status !== null) {
        status.dataset.viewerReady = "true";
        status.dataset.viewerText = event.data.text;
        status.dataset.viewerImages = String(event.data.imageCount);
        status.dataset.viewerLoadedImages = String(event.data.loadedImageCount);
        status.dataset.rendererBridgeType = event.data.bridgeType;
        status.dataset.rendererHandlerType = event.data.handlerType;
        status.dataset.rendererParentAccessible = String(event.data.parentAccessible);
      }
      return;
    }
    if (isLinkActivation(event.data)) {
      if (editorEpoch === null) return;
      void requestFileBridge(document, "openLink", {
        editor_epoch: editorEpoch,
        href: event.data.href,
        forceSystem: event.data.forceSystem,
      }).catch(() => {
        if (status !== null) status.textContent = "링크 파일을 열 수 없습니다.";
      });
      return;
    }
    if (
      isRecord(event.data) &&
      event.data.channel === viewerChannel &&
      event.data.type === "mermaid-request" &&
      typeof event.data.requestId === "string" &&
      typeof event.data.source === "string"
    ) {
      const requestId = event.data.requestId;
      const source = event.data.source;
      readMermaidQueue = readMermaidQueue.then(async () => {
        const response: Record<string, unknown> = {
          channel: viewerChannel,
          type: "mermaid-result",
          requestId,
        };
        try {
          // 읽기 프리뷰는 markdown 전용이라 editorEpoch가 있다(image는 beginDocument 안 해 null → 요청도 안 옴).
          if (editorEpoch === null) throw new Error("no document");
          readMermaidWidget += 1;
          // 읽기 프리뷰용 합성 capability(라이브 projection 없음). validRenderer가 요구하는 필드는 전부 non-zero,
          // widget_id는 펜스마다 달라 dedup을 피한다. source_hash는 헬퍼가 받는 그대로의 fence를 해시한다.
          const capability = {
            editorEpoch,
            documentRevision: 0,
            projectionGeneration: 1,
            widgetId: readMermaidWidget,
            widgetGeneration: 1,
            rendererInstance: 1,
          };
          const svg = await renderMermaidFromBridge(
            document,
            status,
            capability,
            readMermaidWidget,
            sha256Hex(source),
            source,
          );
          if (typeof svg !== "string")
            throw new Error(`no-svg(state=${status?.dataset.mermaidRequest ?? "?"})`);
          response.svg = svg;
        } catch (error) {
          response.error =
            error instanceof Error ? error.message : `unavailable(ep=${String(editorEpoch)})`;
        }
        frame.contentWindow?.postMessage(response, "*");
      });
      return;
    }
    if (!isAssetRequest(event.data)) return;
    const request = event.data;
    assetQueue = assetQueue.then(async () => {
      const response: AssetResult = {
        channel: viewerChannel,
        type: "asset-result",
        requestId: request.requestId,
      };
      try {
        assetRequests += 1;
        if (!assetRequestCountAllowed(assetRequests)) throw new Error("asset count exceeded");
        const result = await requestFileBridge(document, "readAsset", request.path);
        if (typeof result.mime !== "string" || typeof result.data_base64 !== "string") {
          throw new Error("invalid asset result");
        }
        if (!assetBase64BudgetAllowed(assetBase64Bytes, result.data_base64.length)) {
          throw new Error("asset budget exceeded");
        }
        assetBase64Bytes += result.data_base64.length;
        response.mime = result.mime;
        response.dataBase64 = result.data_base64;
      } catch {
        response.error = "asset unavailable";
      }
      frame.contentWindow?.postMessage(response, "*");
    });
  });
  // 파일 document 수명은 renderer handshake와 독립이다. renderer가 실패해도 begin/read barrier를 terminal하게
  // 해소해 native dirty-sync Promise가 영구 in-flight로 남지 않으며, renderer-ready는 현재 snapshot만 뒤늦게 받는다.
  void start();
  targetWindow.addEventListener(
    "pagehide",
    () => {
      editor?.destroy();
      editor = null;
      richEditor?.destroy();
      richEditor = null;
    },
    { once: true },
  );
}

// bootShell과 같은 이유로 `Window & typeof globalThis`다.
export function bootRenderer(document: Document, targetWindow: ViewerWindow): void {
  const root = document.querySelector<HTMLElement>("#app");
  if (root === null) return;
  let generation = 0;
  let requestSequence = 0;
  const pending = new Map<string, (value: AssetResult) => void>();
  // 읽기 프리뷰 mermaid 요청의 대기 resolver(asset과 분리 — 결과 타입이 다름).
  const mermaidPending = new Map<string, (value: MermaidReadResult) => void>();

  // §2.6: 우클릭 좌표·대상을 shell에 넘긴다(브리지는 안 부른다 — 이 origin은 capability 0이다).
  installRendererContextMenu(document, targetWindow, viewerChannel);

  // §2.3: ⌘+/− 페이지 줌. shell이 `setZoom`으로 현재 배율(현재 폰트/base)을 준다. 마크다운 읽기 프리뷰에만
  // `documentElement.zoom`으로 적용한다 — svg 프리뷰는 자체 fit이 크기를 소유하므로 제외하고,
  // 그 모드에서는 zoom을 비워 이중 스케일을 막는다(previewIsMarkdown 게이트). 배율 1은 빈 문자열로 두어 기본 렌더.
  let previewZoom = 1;
  let previewIsMarkdown = false;
  const applyPreviewZoom = () => {
    // setProperty/removeProperty로 다룬다(CSS `zoom`은 CSSStyleDeclaration 타입에 없을 수 있어 직접 대입 회피).
    if (previewIsMarkdown && previewZoom !== 1) {
      document.documentElement.style.setProperty("zoom", String(previewZoom));
    } else {
      document.documentElement.style.removeProperty("zoom");
    }
  };

  root.addEventListener("click", (event) => {
    if (!(event instanceof targetWindow.MouseEvent)) return;
    const target = event.target;
    const link =
      target instanceof targetWindow.Element ? target.closest<HTMLAnchorElement>("a[href]") : null;
    const activation = linkActivationFor({
      isTrusted: event.isTrusted,
      button: event.button,
      metaKey: event.metaKey,
      shiftKey: event.shiftKey,
      href: link?.getAttribute("href") ?? null,
      linkInRoot: link !== null && root.contains(link),
    });
    if (activation === null) return;
    event.preventDefault();
    targetWindow.parent.postMessage(activation, "*");
  });

  const requestAsset = (path: string): Promise<AssetResult> => {
    const requestId = `${generation}:${++requestSequence}`;
    return new Promise((resolve) => {
      pending.set(requestId, resolve);
      targetWindow.parent.postMessage(
        { channel: viewerChannel, type: "asset-request", requestId, path },
        "*",
      );
    });
  };

  // 읽기 프리뷰의 mermaid 펜스를 shell(→native 헬퍼)에 렌더 요청한다. source는 헬퍼의 mermaidFenceBody가 요구하는
  // 완전한 ```mermaid 펜스다.
  const requestMermaid = (source: string): Promise<MermaidReadResult> => {
    const requestId = `${generation}:mermaid:${++requestSequence}`;
    return new Promise((resolve) => {
      mermaidPending.set(requestId, resolve);
      targetWindow.parent.postMessage(
        { channel: viewerChannel, type: "mermaid-request", requestId, source },
        "*",
      );
    });
  };

  targetWindow.addEventListener("message", (event) => {
    if (event.source !== targetWindow.parent || !isRecord(event.data)) return;
    if (event.data.channel !== viewerChannel) return;
    if (event.data.type === "setZoom" && typeof event.data.zoom === "number") {
      // ⌘+/− 배율 갱신(§2.3). 마크다운 프리뷰면 즉시
      // 반영하고, svg/image면 값만 저장했다가 다음 마크다운 render에서 적용한다(applyPreviewZoom이 게이트).
      const zoom = event.data.zoom;
      if (Number.isFinite(zoom)) previewZoom = Math.min(10, Math.max(0.1, zoom));
      applyPreviewZoom();
      return;
    }
    if (event.data.type === "ping") {
      const ready: RendererReady = {
        channel: viewerChannel,
        type: "renderer-ready",
        ...rendererCapabilityTypes(targetWindow),
      };
      targetWindow.parent.postMessage(ready, "*");
      return;
    }
    if (event.data.type === "asset-result" && isAssetResult(event.data)) {
      const resolve = pending.get(event.data.requestId);
      if (resolve !== undefined) {
        pending.delete(event.data.requestId);
        resolve(event.data);
      }
      return;
    }
    if (event.data.type === "mermaid-result" && typeof event.data.requestId === "string") {
      const resolve = mermaidPending.get(event.data.requestId);
      if (resolve !== undefined) {
        mermaidPending.delete(event.data.requestId);
        resolve(event.data as MermaidReadResult);
      }
      return;
    }
    if (event.data.type === "renderSvg" && typeof event.data.svg === "string") {
      // FP13 svg 프리뷰: 원문 SVG를 sanitize→data URL→<img>로 격리 표시한다(§2.2).
      previewIsMarkdown = false;
      applyPreviewZoom(); // svg는 자체 fit(max-height:100vh)이 크기를 소유 — 페이지 줌 해제(§2.3).
      ++generation;
      for (const resolve of pending.values())
        resolve({
          channel: viewerChannel,
          type: "asset-result",
          requestId: "stale",
          error: "stale",
        });
      pending.clear();
      const dataUrl = svgToDataUrl(event.data.svg, targetWindow);
      root.replaceChildren();
      if (dataUrl === null) {
        const notice = document.createElement("p");
        notice.textContent = "이 SVG를 표시할 수 없습니다.";
        notice.className = "maru-svg-error";
        root.appendChild(notice);
      } else {
        const img = document.createElement("img");
        img.src = dataUrl;
        img.alt = "SVG 미리보기";
        img.className = "maru-svg-preview";
        root.appendChild(img);
      }
      targetWindow.parent.postMessage(
        {
          channel: viewerChannel,
          type: "rendered",
          text: "svg",
          imageCount: dataUrl === null ? 0 : 1,
          loadedImageCount: dataUrl === null ? 0 : 1,
          ...rendererCapabilityTypes(targetWindow),
        },
        "*",
      );
      return;
    }
    if (event.data.type !== "render" || typeof event.data.markdown !== "string") return;
    const currentGeneration = ++generation;
    for (const resolve of pending.values()) {
      resolve({ channel: viewerChannel, type: "asset-result", requestId: "stale", error: "stale" });
    }
    pending.clear();
    for (const resolve of mermaidPending.values())
      resolve({
        channel: viewerChannel,
        type: "mermaid-result",
        requestId: "stale",
        error: "stale",
      });
    mermaidPending.clear();
    root.innerHTML = renderMarkdown(event.data.markdown);
    previewIsMarkdown = true;
    applyPreviewZoom(); // ⌘+/− 페이지 줌은 마크다운 읽기 프리뷰에만 적용(§2.3).
    // 읽기 프리뷰 mermaid: prism이 남긴 `code.language-mermaid` 코드 블록을 shell(→헬퍼)로 렌더한 SVG `<img>`로
    // 교체한다. 헬퍼가 요구하는 완전한 ```mermaid 펜스로 재구성해 보내고, 실패/스테일이면 원래 코드 블록을 남긴다.
    for (const codeEl of Array.from(
      root.querySelectorAll<HTMLElement>("code.language-mermaid"),
    ).slice(0, maxAssetRequests)) {
      const pre = codeEl.closest("pre");
      if (pre === null) continue;
      // 원본 오프셋 슬라이스로 개행을 보존한 완전한 펜스를 만든다(prism의 줄-span 구조 무관). 오프셋이 없으면
      // 옛 textContent 재구성으로 폴백한다(개행 손실 가능하나 최소 동작 보장).
      const fence =
        sliceMermaidFence(pre, event.data.markdown) ??
        sliceMermaidFence(codeEl, event.data.markdown) ??
        `\`\`\`mermaid\n${codeEl.textContent ?? ""}\n\`\`\``;
      void requestMermaid(fence).then((result) => {
        if (currentGeneration !== generation || pre.parentNode === null) return;
        if (typeof result.svg !== "string") {
          return; // 렌더 실패/스테일이면 원래 코드 블록을 그대로 남긴다(fallback)
        }
        const img = document.createElement("img");
        img.src = `data:image/svg+xml;base64,${bytesToBase64(new TextEncoder().encode(result.svg), targetWindow)}`;
        img.className = "maru-mermaid-diagram";
        img.alt = "mermaid 다이어그램";
        pre.replaceWith(img);
      });
    }
    const images = Array.from(
      root.querySelectorAll<HTMLImageElement>("img[data-maru-asset-path]"),
    ).slice(0, maxAssetRequests);
    void (async () => {
      let loadedImageCount = 0;
      for (const image of images) {
        if (currentGeneration !== generation) return;
        const path = image.dataset.maruAssetPath;
        if (path === undefined) continue;
        const result = await requestAsset(path);
        if (currentGeneration !== generation || result.error !== undefined) continue;
        if (typeof result.mime !== "string" || typeof result.dataBase64 !== "string") continue;
        const url = assetDataUrl(result.mime, result.dataBase64, targetWindow);
        if (url !== null) {
          image.src = url;
          loadedImageCount += 1;
        }
      }
      const report: RendererReport = {
        channel: viewerChannel,
        type: "rendered",
        text: (root.textContent ?? "").slice(0, 512),
        imageCount: images.length,
        loadedImageCount,
        ...rendererCapabilityTypes(targetWindow),
      };
      targetWindow.parent.postMessage(report, "*");
    })();
  });

  const ready: RendererReady = {
    channel: viewerChannel,
    type: "renderer-ready",
    ...rendererCapabilityTypes(targetWindow),
  };
  targetWindow.parent.postMessage(ready, "*");
}
