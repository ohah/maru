import { normalizeAssetReference } from "./asset-path";
import { renderMarkdown } from "./markdown";
import { sanitizeMermaidSvg } from "./rich-render";

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

type FileMethod = "read" | "readAsset";

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
  method: FileMethod,
  path?: string,
  timeoutMs = 15_000,
): Promise<BridgeResult> {
  return new Promise((resolve, reject) => {
    const node = document.createElement("span");
    node.hidden = true;
    node.dataset.maruFileRequest = "pending";
    node.dataset.maruFileRequestId = String(++bridgeRequestId);
    node.textContent = JSON.stringify(method === "read" ? { method } : { method, path });
    document.documentElement.append(node);

    const cleanup = () => {
      clearTimeout(timer);
      document.removeEventListener("maru:file-response", onResponse);
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
    const timer = setTimeout(() => {
      cleanup();
      reject(new Error("file bridge timeout"));
    }, timeoutMs);
    document.addEventListener("maru:file-response", onResponse);
    const EventConstructor = document.defaultView?.Event ?? Event;
    document.dispatchEvent(new EventConstructor("maru:file-request"));
  });
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
  if (raster.has(mime)) return `data:${mime};base64,${dataBase64}`;
  if (mime !== "image/svg+xml") return null;

  try {
    const binary = targetWindow.atob(dataBase64);
    const bytes = Uint8Array.from(binary, (char) => char.charCodeAt(0));
    const source = new TextDecoder("utf-8", { fatal: true }).decode(bytes);
    const sanitized = sanitizeMermaidSvg(source, targetWindow);
    const encoded = bytesToBase64(new TextEncoder().encode(sanitized), targetWindow);
    return `data:image/svg+xml;base64,${encoded}`;
  } catch {
    return null;
  }
}

export function bootShell(document: Document, targetWindow: Window): void {
  const frame = document.querySelector<HTMLIFrameElement>("#renderer");
  const status = document.querySelector<HTMLElement>("#viewer-status");
  if (frame === null) return;

  let started = false;
  const start = async () => {
    if (started) return;
    started = true;
    if (status !== null) status.dataset.rendererLoaded = "true";
    try {
      const result = await requestFileBridge(document, "read");
      if (typeof result.content !== "string") throw new Error("invalid file content");
      if (status !== null) status.dataset.fileRead = "true";
      frame.contentWindow?.postMessage(
        { channel: viewerChannel, type: "render", markdown: result.content },
        "*",
      );
      if (status !== null) status.textContent = "";
    } catch {
      if (status !== null) status.dataset.fileRead = "false";
      if (status !== null) status.textContent = "파일을 읽을 수 없습니다.";
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

  let assetBase64Bytes = 0;
  let assetRequests = 0;
  let assetQueue = Promise.resolve();
  targetWindow.addEventListener("message", (event) => {
    if (event.source !== frame.contentWindow) return;
    if (isRendererReady(event.data)) {
      if (status !== null) {
        status.dataset.rendererScriptReady = "true";
        status.dataset.rendererBridgeType = event.data.bridgeType;
        status.dataset.rendererHandlerType = event.data.handlerType;
        status.dataset.rendererParentAccessible = String(event.data.parentAccessible);
      }
      void start();
      return;
    }
    if (isRendererReport(event.data)) {
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
}

export function bootRenderer(document: Document, targetWindow: Window): void {
  const root = document.querySelector<HTMLElement>("#app");
  if (root === null) return;
  let generation = 0;
  let requestSequence = 0;
  const pending = new Map<string, (value: AssetResult) => void>();

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

  const ready: RendererReady = {
    channel: viewerChannel,
    type: "renderer-ready",
    ...rendererCapabilityTypes(targetWindow),
  };
  targetWindow.parent.postMessage(ready, "*");
}
