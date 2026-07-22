import { normalizeAssetReference } from "./asset-path";
import { renderMarkdown } from "./markdown";
import { sanitizeMermaidSvg } from "./rich-render";
import { createMarkdownEditor, createSourceEditor } from "./editor";
import { sourceLanguageExtensions } from "./source-language";
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
import type { EditorView, ViewUpdate } from "@codemirror/view";
import type { Text } from "@codemirror/state";
import { EditorRevisionClock, isEditableFileMode, type FilePanelMode } from "./live-preview-state";
import {
  atomicRendererChannel,
  capabilitiesEqual,
  isAtomicRendererInit,
  isAtomicRendererRender,
  type RendererCapability,
} from "./renderer-capability";
import { EditableProjectionController } from "./editable-projection-view";
import { AtomicProjectionController } from "./live-preview-editor";
import type { AssetGrant } from "./atomic-projection";
import { createLivePreviewDiagnosticsSnapshot } from "./live-preview-diagnostics";
import {
  LivePreviewIntentCoordinator,
  type LivePreviewDispatchResult,
  type LivePreviewIntentQueueMetrics,
} from "./live-preview-interaction";
import type { LivePreviewIntent } from "./live-preview-intent";

export const viewerChannel = "maru.file.viewer.v1";
export const maxAssetRequests = 64;
export const maxAssetBase64Bytes = 48 * 1024 * 1024;

export function assetRequestCountAllowed(count: number): boolean {
  return Number.isInteger(count) && count >= 0 && count <= maxAssetRequests;
}

export function assetBase64BudgetAllowed(currentBytes: number, nextBytes: number): boolean {
  return (
    Number.isInteger(currentBytes) &&
    currentBytes >= 0 &&
    Number.isInteger(nextBytes) &&
    nextBytes >= 0 &&
    currentBytes <= maxAssetBase64Bytes - nextBytes
  );
}

export function writeLivePreviewIntentQueueMetrics(
  target: HTMLElement,
  metrics: LivePreviewIntentQueueMetrics,
  bridgeCalls: number,
): void {
  target.dataset.liveIntentQueueRetained = String(metrics.retained);
  target.dataset.liveIntentQueueMaxRetained = String(metrics.maxRetained);
  target.dataset.liveIntentQueueDropped = String(metrics.dropped);
  target.dataset.liveIntentQueueCompleted = String(metrics.completed);
  target.dataset.liveIntentBridgeCalls = String(bridgeCalls);
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

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
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

export function closeUnlockOwnsLock(
  currentRequestId: number | null,
  unlockRequestId: number,
): boolean {
  return (
    currentRequestId !== null &&
    Number.isSafeInteger(unlockRequestId) &&
    unlockRequestId >= currentRequestId
  );
}

export function closeLockCanAcquire(currentRequestId: number | null, requestId: number): boolean {
  return (
    Number.isSafeInteger(requestId) &&
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
    Number.isInteger(value.imageCount) &&
    value.imageCount >= 0 &&
    value.imageCount <= maxAssetRequests &&
    Number.isInteger(value.loadedImageCount) &&
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
  targetWindow: Window,
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
  method: "livePreviewReady",
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
        if (
          !isRecord(value) ||
          !Number.isSafeInteger(value.editor_epoch) ||
          value.editor_epoch <= 0
        )
          throw new TypeError("invalid read payload");
        request = { method, editor_epoch: value.editor_epoch as number };
        break;
      case "beginDocument":
        if (!isRecord(value) || !Number.isSafeInteger(value.document_id) || value.document_id <= 0)
          throw new TypeError("invalid beginDocument payload");
        request = { method, document_id: value.document_id as number };
        break;
      case "readAsset":
        if (typeof value !== "string") throw new TypeError("invalid readAsset payload");
        request = { method, path: value };
        break;
      case "write":
        if (
          !isRecord(value) ||
          !Number.isSafeInteger(value.editor_epoch) ||
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
          !Number.isSafeInteger(value.editor_epoch) ||
          value.editor_epoch <= 0 ||
          !Number.isSafeInteger(value.revision) ||
          value.revision < 0 ||
          !Number.isSafeInteger(value.request_id) ||
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
          !Number.isSafeInteger(value.editor_epoch) ||
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
          !Number.isSafeInteger(value.editor_epoch) ||
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
          !Number.isSafeInteger(value.editor_epoch) ||
          value.editor_epoch <= 0 ||
          !Number.isSafeInteger(value.document_revision) ||
          value.document_revision < 0 ||
          !Number.isSafeInteger(value.projection_generation) ||
          value.projection_generation <= 0 ||
          !Number.isSafeInteger(value.widget_id) ||
          value.widget_id <= 0 ||
          !Number.isSafeInteger(value.widget_generation) ||
          value.widget_generation <= 0 ||
          !Number.isSafeInteger(value.renderer_instance) ||
          value.renderer_instance <= 0 ||
          !Number.isSafeInteger(value.fence_id) ||
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
          !Number.isSafeInteger(value.editor_epoch) ||
          value.editor_epoch <= 0 ||
          !Number.isSafeInteger(value.document_revision) ||
          value.document_revision < 0 ||
          !Number.isSafeInteger(value.projection_generation) ||
          value.projection_generation <= 0 ||
          !Number.isSafeInteger(value.widget_id) ||
          value.widget_id <= 0 ||
          !Number.isSafeInteger(value.widget_generation) ||
          value.widget_generation <= 0 ||
          !Number.isSafeInteger(value.renderer_instance) ||
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
      case "livePreviewReady":
        if (
          !isRecord(value) ||
          !Number.isSafeInteger(value.editor_epoch) ||
          value.editor_epoch <= 0
        )
          throw new TypeError("invalid livePreviewReady payload");
        request = { method, editor_epoch: value.editor_epoch as number };
        break;
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
  if (status !== null) status.dataset.liveMermaidRequest = "pending";
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
    if (status !== null) status.dataset.liveMermaidRequest = svg === null ? "invalid" : "ok";
    return svg;
  } catch {
    if (status !== null) status.dataset.liveMermaidRequest = "error";
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

function bytesToBase64(bytes: Uint8Array, targetWindow: Window): string {
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
  targetWindow: Window,
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
export function svgToDataUrl(source: string, targetWindow: Window): string | null {
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

export function bootShell(document: Document, targetWindow: Window): void {
  const frame = document.querySelector<HTMLIFrameElement>("#renderer");
  const editorHost = document.querySelector<HTMLElement>("#editor");
  const status = document.querySelector<HTMLElement>("#viewer-status");
  if (frame === null || editorHost === null) return;

  // text/svg kind(docs/file-panel.md §2.2·§2.3): shell URL `?lang=`은 소스 편집기 문법, `?kind=svg`는 svg의
  // read(격리 sanitize 프리뷰)+source(xml 편집) 두 모드를 켠다. 둘 다 markdown projection/worker/mermaid 없이
  // read/write·dirty·⌘S·외부변경 배관만 markdown과 공유하고 livePreviewReady(markdown+live 전용)는 호출하지 않는다.
  const shellParams = new URL(targetWindow.location.href).searchParams;
  const sourceLanguageWire = shellParams.get("lang");
  const isSvg = shellParams.get("kind") === "svg";
  // text = read 모드 없는 소스 전용. svg는 read 프리뷰가 있어 source-only가 아니다.
  const isSourceOnly = sourceLanguageWire !== null && !isSvg;

  let editor: EditorView | null = null;
  let livePreviewController: EditableProjectionController | null = null;
  let atomicProjectionController: AtomicProjectionController | null = null;
  let atomicProjectionAdmitted = false;
  const livePreviewDiagnostics = createLivePreviewDiagnosticsSnapshot();
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
  let pendingDiskUpdate: ViewUpdate | null = null;
  let assetBase64Bytes = 0;
  let assetRequests = 0;
  let liveIntentCm6Transactions = 0;
  let liveIntentExternalActions = 0;
  let liveIntentDualEffects = 0;
  let liveIntentRejections = 0;
  let liveIntentBridgeCalls = 0;
  let livePreviewIntentCoordinator: LivePreviewIntentCoordinator | null = null;

  const currentDocumentIsDirty = (): boolean =>
    editor !== null && documentIsDirtyAgainstSnapshot(editor.state.doc, savedDocument);

  const setCloseLocked = (requestId: number | null) => {
    closeLockRequestId = requestId;
    if (requestId !== null) livePreviewIntentCoordinator?.clearPending();
    if (editor !== null) editor.contentDOM.contentEditable = requestId === null ? "true" : "false";
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
    if (!closeLockCanAcquire(closeLockRequestId, requestId) || editor?.composing === true)
      return false;
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
    if (editor === null || editorEpoch === null) return false;
    const documentSnapshot = editor.state.doc;
    const content = documentSnapshot.toString();
    const operation = mutationQueue.then(async () => {
      await requestFileBridge(document, "write", { editor_epoch: editorEpoch, content });
      savedContent = content;
      savedDocument = documentSnapshot;
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
      if (status !== null) status.textContent = "파일을 저장할 수 없습니다.";
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
  };
  closeApi.__maruSyncDirty = syncDirtyNow;
  closeApi.__maruSyncDirtyForClose = syncDirtyForClose;
  closeApi.__maruSaveForClose = async (requestId: number) => {
    if (!Number.isSafeInteger(requestId) || closeLockRequestId !== requestId) {
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

  const publishLiveIntentQueueMetrics = (metrics?: LivePreviewIntentQueueMetrics) => {
    if (status === null) return;
    const current = metrics ?? livePreviewIntentCoordinator?.metrics();
    if (current === undefined) return;
    writeLivePreviewIntentQueueMetrics(status, current, liveIntentBridgeCalls);
  };

  const recordLivePreviewDispatch = (dispatch: LivePreviewDispatchResult) => {
    liveIntentCm6Transactions += dispatch.cm6Transactions;
    liveIntentExternalActions += dispatch.externalActions;
    liveIntentDualEffects += Number(dispatch.cm6Transactions > 0 && dispatch.externalActions > 0);
    liveIntentRejections += Number(dispatch.result.type !== "committed");
    if (status !== null) {
      status.dataset.liveIntentResult = dispatch.result.type;
      status.dataset.liveIntentCm6Transactions = String(liveIntentCm6Transactions);
      status.dataset.liveIntentExternalActions = String(liveIntentExternalActions);
      status.dataset.liveIntentDualEffects = String(liveIntentDualEffects);
      status.dataset.liveIntentRejections = String(liveIntentRejections);
    }
  };

  livePreviewIntentCoordinator = new LivePreviewIntentCoordinator({
    scheduleDocumentOperation: (operation) => {
      const scheduled = mutationQueue.then(operation);
      mutationQueue = scheduled.then(
        () => undefined,
        () => undefined,
      );
      return scheduled;
    },
    currentContext: (intent) => {
      if (editor === null || editorEpoch === null || livePreviewController === null) return null;
      const projectionIdentity = livePreviewController.interactionIdentity();
      const interaction = livePreviewController.interactionContextForIntent(intent);
      return {
        view: editor,
        guard: {
          editorEpoch,
          documentRevision: revisions.documentRevision,
          projectionGeneration: projectionIdentity.projectionGeneration,
          mode,
          closeLockRequestId,
          composing: editor.composing,
          readonly: mode !== "live-preview" || editor.contentDOM.contentEditable === "false",
        },
        currentEntry: interaction.currentEntry,
        currentTableCells: interaction.currentTableCells,
      };
    },
    hrefAllowed: (href) =>
      isLinkActivation({
        channel: viewerChannel,
        type: "link-activate",
        href,
        forceSystem: false,
      }),
    openExternalAction: async (intent, action) => {
      liveIntentBridgeCalls += 1;
      publishLiveIntentQueueMetrics();
      await requestFileBridge(document, "openLink", {
        editor_epoch: intent.editorEpoch,
        href: action.href,
        forceSystem: action.forceSystem,
      });
    },
    onDispatch: recordLivePreviewDispatch,
    onError: () => {
      if (status !== null) status.textContent = "라이브 프리뷰 동작을 완료할 수 없습니다.";
    },
    onMetricsChanged: publishLiveIntentQueueMetrics,
  });

  const enqueueLivePreviewIntent = (intent: LivePreviewIntent) => {
    if (livePreviewIntentCoordinator?.enqueue(intent) !== true && status !== null)
      status.dataset.liveIntentResult = "queue-full";
  };

  const ensureEditor = (): EditorView => {
    if (editor !== null) return editor;
    if (editorEpoch === null) throw new Error("editor document epoch is unavailable");
    if (isSourceOnly || isSvg) {
      // text 소스 전용·svg 소스 모드 공용 경로. livePreview/atomic controller를 만들지 않고 onChange는 dirty
      // 추적만 하며 markdown용 `?.` controller 호출은 null이라 no-op이다. svg는 read 모드에서 프리뷰를 갱신한다.
      editor = createSourceEditor(
        editorHost,
        savedContent,
        sourceLanguageExtensions(sourceLanguageWire),
        (update) => {
          if (applyingDiskContent) {
            pendingDiskUpdate = update;
            return;
          }
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
    editor = createMarkdownEditor(
      editorHost,
      savedContent,
      (update) => {
        if (applyingDiskContent) {
          pendingDiskUpdate = update;
          return;
        }
        const baseRevision = revisions.documentRevision;
        if (update.docChanged) {
          livePreviewIntentCoordinator?.clearPending();
          revisions.documentChanged();
          reportDirty(savedDocument === null || !update.state.doc.eq(savedDocument));
        }
        atomicProjectionController?.handleUpdate(update, baseRevision, revisions.documentRevision);
        livePreviewController?.handleUpdate(update);
      },
      () => void save(),
    );
    savedDocument = editor.state.doc;
    livePreviewController = new EditableProjectionController(
      editor,
      editorEpoch,
      revisions,
      ({ state, metrics, atomicEntries }) => {
        const identity = livePreviewController?.interactionIdentity();
        if (identity !== undefined)
          atomicProjectionController?.submitEntries(
            identity.documentRevision,
            identity.projectionGeneration,
            atomicEntries,
          );
        if (status === null) return;
        livePreviewController?.writeDiagnostics(livePreviewDiagnostics);
        const diagnostics = livePreviewDiagnostics;
        status.dataset.liveProjection = state;
        status.dataset.liveProjectionDecorations = String(diagnostics.decorationCount);
        status.dataset.liveProjectionGeneration = String(diagnostics.projectionGeneration);
        status.dataset.liveProjectionDocumentRevision = String(diagnostics.documentRevision);
        status.dataset.liveProjectionActiveSourceRanges = String(
          diagnostics.activeSourceRangeCount,
        );
        status.dataset.liveProjectionAtomicFallbacks = String(
          diagnostics.fallbackCounts["atomic-not-enabled"],
        );
        status.dataset.liveProjectionVisitedNodes = String(metrics.visitedSyntaxNodes);
        status.dataset.liveGeneralFragments = "0";
      },
      enqueueLivePreviewIntent,
    );
    const currentEditorEpoch = editorEpoch;
    atomicProjectionController = new AtomicProjectionController(
      editor,
      currentEditorEpoch,
      revisions,
      targetWindow.Worker ?? null,
      async (grant: AssetGrant) => {
        if (grant.editorEpoch !== currentEditorEpoch) return null;
        assetRequests += 1;
        if (!assetRequestCountAllowed(assetRequests)) return null;
        const result = await requestFileBridge(document, "readAsset", grant.normalizedPath);
        if (typeof result.mime !== "string" || typeof result.data_base64 !== "string") return null;
        if (!assetBase64BudgetAllowed(assetBase64Bytes, result.data_base64.length)) return null;
        assetBase64Bytes += result.data_base64.length;
        const svg = result.mime === "image/svg+xml";
        if (
          (grant.expectedMimeFamily === "svg-image" && !svg) ||
          (grant.expectedMimeFamily === "raster-image" && svg)
        )
          return null;
        return assetDataUrl(result.mime, result.data_base64, targetWindow);
      },
      (state, reason) => {
        if (status === null) return;
        status.dataset.liveAtomicState = state;
        if (reason !== undefined) status.dataset.liveAtomicFailure = reason;
      },
      (metrics) => {
        livePreviewController?.updateAtomicDiagnostics(metrics);
        if (status === null) return;
        livePreviewController?.writeDiagnostics(livePreviewDiagnostics);
        status.dataset.liveAtomicDesired = String(metrics.desired);
        status.dataset.liveAtomicMounted = String(metrics.mounted);
        status.dataset.liveAtomicStaleTotal = String(metrics.staleCapabilityTotal);
        status.dataset.liveProjectionAtomicFallbacks = String(
          livePreviewDiagnostics.fallbackCounts["atomic-not-enabled"],
        );
      },
      enqueueLivePreviewIntent,
      (capability, fenceId, sourceHash, source, signal) =>
        renderMermaidFromBridge(document, status, capability, fenceId, sourceHash, source, signal),
      (capability) => {
        void revokeMermaidFromBridge(document, capability).catch(() => {});
      },
    );
    if (atomicProjectionAdmitted && mode === "live-preview") atomicProjectionController.enable();
    if (closeLockRequestId !== null) editor.contentDOM.contentEditable = "false";
    return editor;
  };

  // 읽기 모드 프리뷰를 render iframe에 보낸다. svg=sanitize 프리뷰(`renderSvg`), markdown=`render`. text는 프리뷰가
  // 없어 no-op이다. 현재 편집 중 내용(editor)이 있으면 그걸, 없으면 마지막 로드/저장 snapshot을 쓴다.
  const postPreview = () => {
    if (!rendererReady || isSourceOnly) return;
    const content = editor?.state.doc.toString() ?? savedContent;
    frame.contentWindow?.postMessage(
      isSvg
        ? { channel: viewerChannel, type: "renderSvg", svg: content }
        : { channel: viewerChannel, type: "render", markdown: content },
      "*",
    );
  };

  const applyMode = (next: FilePanelMode) => {
    mode = next;
    if (mode !== "live-preview") livePreviewIntentCoordinator?.clearPending();
    if (isEditableFileMode(mode)) {
      frame.hidden = true;
      editorHost.hidden = false;
      if (contentLoaded) {
        ensureEditor().focus();
        if (mode === "live-preview") {
          livePreviewController?.enable();
          if (atomicProjectionAdmitted) atomicProjectionController?.enable();
          else atomicProjectionController?.disable();
        } else {
          atomicProjectionController?.disable();
          livePreviewController?.disable();
        }
      }
    } else {
      atomicProjectionController?.disable();
      livePreviewController?.disable();
      if (editor !== null) reportDirty(currentDocumentIsDirty(), true);
      frame.hidden = false;
      editorHost.hidden = true;
      postPreview();
    }
    document.body.dataset.fileMode = mode;
  };

  targetWindow.addEventListener("maru:file-mode", (event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    if (!isRecord(detail)) return;
    // text는 source_edit 단일 모드라 read/live 신호는 무시한다(native도 보내지 않지만 방어적으로 고정).
    if (isSourceOnly) {
      if (detail.mode === "source-edit") applyMode("source-edit");
      return;
    }
    // svg는 read|source 두 모드만(라이브 없음).
    if (isSvg) {
      if (detail.mode === "read" || detail.mode === "source-edit") applyMode(detail.mode);
      return;
    }
    if (detail.mode === "read" || detail.mode === "source-edit" || detail.mode === "live-preview")
      applyMode(detail.mode);
  });
  targetWindow.addEventListener("maru:file-live-preview-active", (event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    if (!isRecord(detail) || typeof detail.active !== "boolean") return;
    atomicProjectionAdmitted = detail.active;
    if (atomicProjectionAdmitted && mode === "live-preview") atomicProjectionController?.enable();
    else atomicProjectionController?.disable();
    if (status !== null) status.dataset.liveAtomicAdmitted = String(detail.active);
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
        pendingDiskUpdate = null;
        try {
          editor.dispatch({
            changes: { from: 0, to: editor.state.doc.length, insert: result.content },
          });
        } finally {
          applyingDiskContent = false;
        }
      }
      savedDocument = editor.state.doc;
      const reloadBaseRevision = revisions.documentRevision;
      if (!editor.state.doc.eq(previousDocument)) revisions.documentChanged();
      if (pendingDiskUpdate !== null) {
        atomicProjectionController?.handleUpdate(
          pendingDiskUpdate,
          reloadBaseRevision,
          revisions.documentRevision,
        );
        livePreviewController?.handleUpdate(pendingDiskUpdate);
        pendingDiskUpdate = null;
      }
    } else {
      savedDocument = null;
    }
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
    const operation = (async () => {
      const documentId = Number(new URL(targetWindow.location.href).searchParams.get("document"));
      if (!Number.isSafeInteger(documentId) || documentId <= 0)
        throw new Error("invalid editor document id");
      const documentResult = await requestFileBridge(document, "beginDocument", {
        document_id: documentId,
      });
      if (
        !Number.isSafeInteger(documentResult.editor_epoch) ||
        (documentResult.editor_epoch as number) <= 0
      )
        throw new Error("invalid editor document epoch");
      editorEpoch = documentResult.editor_epoch as number;
      if (status !== null) status.dataset.editorEpoch = String(editorEpoch);
      await loadFromDisk(false);
      // livePreviewReady는 markdown+live 전용 native gate라 text·svg에서 호출하면 StaleDocument로 실패한다(§2.2).
      if (!isSourceOnly && !isSvg)
        await requestFileBridge(document, "livePreviewReady", { editor_epoch: editorEpoch });
    })();
    try {
      await operation;
      if (status !== null) status.dataset.fileRead = "true";
      if (status !== null) status.textContent = "";
    } catch {
      if (status !== null) status.dataset.fileRead = "false";
      if (status !== null) status.textContent = "파일을 읽을 수 없습니다.";
    } finally {
      // 실패도 barrier를 해소한다. 뒤의 mutation은 editorEpoch null 검사로 false/error가 되어 native 보호를
      // 유지하며, 영구 대기 Promise를 남기지 않는다.
      settleDocumentInitialization();
    }
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
      livePreviewIntentCoordinator?.destroy();
      atomicProjectionController?.destroy();
      livePreviewController?.destroy();
      editor?.destroy();
      editor = null;
    },
    { once: true },
  );
}

export function bootRenderer(document: Document, targetWindow: Window): void {
  const root = document.querySelector<HTMLElement>("#app");
  if (root === null) return;
  let generation = 0;
  let requestSequence = 0;
  const pending = new Map<string, (value: AssetResult) => void>();
  let atomicPort: MessagePort | null = null;
  let atomicCapability: RendererCapability | null = null;
  let atomicRenderConsumed = false;

  const revokeAtomic = () => {
    atomicPort?.close();
    atomicPort = null;
    atomicCapability = null;
    atomicRenderConsumed = false;
  };

  const waitForAtomicImages = async (images: readonly HTMLImageElement[]): Promise<boolean> => {
    if (images.length === 0) return true;
    const settled = Promise.all(
      images.map(
        (image) =>
          new Promise<boolean>((resolve) => {
            if (image.complete) {
              resolve(image.naturalWidth > 0);
              return;
            }
            if (typeof image.decode === "function") {
              void image.decode().then(
                () => resolve(true),
                () => resolve(false),
              );
              return;
            }
            const done = (loaded: boolean) => {
              image.removeEventListener("load", loadedImage);
              image.removeEventListener("error", failedImage);
              resolve(loaded);
            };
            const loadedImage = () => done(true);
            const failedImage = () => done(false);
            image.addEventListener("load", loadedImage, { once: true });
            image.addEventListener("error", failedImage, { once: true });
          }),
      ),
    ).then((values) => values.every(Boolean));
    const timeout = new Promise<false>((resolve) =>
      targetWindow.setTimeout(() => resolve(false), 1_500),
    );
    return Promise.race([settled, timeout]);
  };

  root.addEventListener("click", (event) => {
    // Atomic renderer는 pointer/action capability가 없다. 위젯 outer overlay가 source selection만 소유한다.
    if (!(event instanceof targetWindow.MouseEvent) || event.button !== 0) return;
    const target = event.target;
    if (!(target instanceof targetWindow.Element)) return;
    const link = target.closest<HTMLAnchorElement>("a[href]");
    if (document.body.dataset.rendererMode === "atomic") {
      if (link !== null && root.contains(link)) {
        event.preventDefault();
        event.stopPropagation();
      }
      return;
    }
    const href = link?.getAttribute("href");
    if (
      link === null ||
      href === null ||
      !root.contains(link) ||
      (!isLocalDocumentHref(href) && !isExplicitHttpHref(href))
    )
      return;
    event.preventDefault();
    const activation: LinkActivation = {
      channel: viewerChannel,
      type: "link-activate",
      href,
      forceSystem: event.metaKey && event.shiftKey,
    };
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

  targetWindow.addEventListener("message", (event) => {
    if (event.source !== targetWindow.parent || !isRecord(event.data)) return;
    if (isAtomicRendererInit(event.data)) {
      const port = event.ports[0];
      if (port === undefined || event.ports.length !== 1) return;
      revokeAtomic();
      atomicCapability = event.data.capability;
      atomicPort = port;
      atomicRenderConsumed = false;
      document.body.dataset.rendererMode = "atomic";
      root.setAttribute("aria-live", "off");
      root.innerHTML = "";
      port.onmessage = async (portEvent) => {
        if (
          atomicCapability === null ||
          atomicRenderConsumed ||
          !isAtomicRendererRender(portEvent.data) ||
          !capabilitiesEqual(portEvent.data.capability, atomicCapability)
        ) {
          return;
        }
        atomicRenderConsumed = true;
        const capability = atomicCapability;
        const renderPort = port;
        root.innerHTML = portEvent.data.payload;
        const assets = new Map(
          portEvent.data.assets.map((asset) => [asset.opaqueId, asset.dataUrl]),
        );
        for (const image of root.querySelectorAll<HTMLImageElement>("img[data-maru-asset-id]")) {
          const opaqueId = Number(image.dataset.maruAssetId);
          const dataUrl = assets.get(opaqueId);
          if (dataUrl !== undefined) image.src = dataUrl;
          delete image.dataset.maruAssetId;
        }
        const images = [...root.querySelectorAll<HTMLImageElement>("img")];
        if (!(await waitForAtomicImages(images))) return;
        // WKWebView may indefinitely throttle requestAnimationFrame inside an offscreen replacement iframe.
        // The reads below force a current layout after all admitted images settle, so no visual-frame callback
        // is needed to establish the measured-height acknowledgement.
        if (
          atomicPort !== renderPort ||
          atomicCapability === null ||
          !capabilitiesEqual(atomicCapability, capability)
        )
          return;
        const measured = Math.max(
          1,
          Math.ceil(root.getBoundingClientRect().height),
          root.scrollHeight,
        );
        renderPort.postMessage({
          channel: atomicRendererChannel,
          type: "atomic-rendered",
          capability,
          height: measured,
        });
        renderPort.close();
        if (atomicPort === renderPort) {
          atomicPort = null;
          atomicCapability = null;
        }
      };
      port.start();
      port.postMessage({
        channel: atomicRendererChannel,
        type: "atomic-ready",
        capability: atomicCapability,
      });
      return;
    }
    if (document.body.dataset.rendererMode === "atomic") return;
    if (event.data.channel !== viewerChannel) return;
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
    if (event.data.type === "renderSvg" && typeof event.data.svg === "string") {
      // FP13 svg 프리뷰: 원문 SVG를 sanitize→data URL→<img>로 격리 표시한다(§2.2).
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
    root.innerHTML = renderMarkdown(event.data.markdown);
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

  if (new URL(targetWindow.location.href).searchParams.get("atomic") === "1") {
    targetWindow.parent.postMessage({ channel: atomicRendererChannel, type: "atomic-boot" }, "*");
  } else {
    const ready: RendererReady = {
      channel: viewerChannel,
      type: "renderer-ready",
      ...rendererCapabilityTypes(targetWindow),
    };
    targetWindow.parent.postMessage(ready, "*");
  }
  targetWindow.addEventListener("pagehide", revokeAtomic, { once: true });
}
