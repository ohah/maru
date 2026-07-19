import { normalizeAssetReference } from "./asset-path";
import { renderMarkdown } from "./markdown";
import { sanitizeMermaidSvg } from "./rich-render";
import { createMarkdownEditor } from "./editor";
import {
  encodeFileBridgeRequest,
  type DirtyReport,
  type FileBridgeRequest,
  type FileMethod,
  type OpenLinkRequest,
} from "./file-bridge-request";
import type { EditorView } from "@codemirror/view";
import type { Text } from "@codemirror/state";
import { EditorRevisionClock, isEditableFileMode, type FilePanelMode } from "./live-preview-state";
import {
  capabilitiesEqual,
  fragmentChannel,
  isFragmentInit,
  isFragmentRender,
  type RendererCapability,
} from "./renderer-capability";
import { LivePreviewEditorController } from "./live-preview-editor";

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
  value?: undefined,
  timeoutMs?: number,
): Promise<BridgeResult>;
export function requestFileBridge(
  document: Document,
  method: "readAsset" | "write",
  value: string,
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
  value: boolean,
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
  timeoutMs = 15_000,
): Promise<BridgeResult> {
  return new Promise((resolve, reject) => {
    const node = document.createElement("span");
    node.hidden = true;
    node.dataset.maruFileRequest = "pending";
    node.dataset.maruFileRequestId = String(++bridgeRequestId);
    let request: FileBridgeRequest;
    switch (method) {
      case "read":
        request = { method };
        break;
      case "readAsset":
        if (typeof value !== "string") throw new TypeError("invalid readAsset payload");
        request = { method, path: value };
        break;
      case "write":
        if (typeof value !== "string") throw new TypeError("invalid write payload");
        request = { method, content: value };
        break;
      case "setDirty":
        if (
          !isRecord(value) ||
          typeof value.dirty !== "boolean" ||
          !Number.isSafeInteger(value.revision) ||
          !Number.isSafeInteger(value.request_id)
        ) {
          throw new TypeError("invalid setDirty payload");
        }
        request = {
          method,
          dirty: value.dirty,
          revision: value.revision as number,
          request_id: value.request_id as number,
        };
        break;
      case "resolveExternalChange":
        if (typeof value !== "boolean")
          throw new TypeError("invalid resolveExternalChange payload");
        request = { method, success: value };
        break;
      case "openLink":
        if (
          !isRecord(value) ||
          typeof value.href !== "string" ||
          typeof value.forceSystem !== "boolean"
        ) {
          throw new TypeError("invalid openLink payload");
        }
        request = { method, href: value.href, forceSystem: value.forceSystem };
        break;
    }
    node.textContent = JSON.stringify(encodeFileBridgeRequest(request));
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
  const editorHost = document.querySelector<HTMLElement>("#editor");
  const status = document.querySelector<HTMLElement>("#viewer-status");
  if (frame === null || editorHost === null) return;

  let editor: EditorView | null = null;
  let livePreviewController: LivePreviewEditorController | null = null;
  let savedContent = "";
  let savedDocument: Text | null = null;
  let contentLoaded = false;
  let dirty = false;
  const revisions = new EditorRevisionClock();
  let mode: FilePanelMode = "read";
  let livePreviewAdmitted = false;
  let mutationQueue = Promise.resolve();
  let closeLockRequestId: number | null = null;
  let applyingDiskContent = false;

  const currentDocumentIsDirty = (): boolean =>
    editor !== null && (savedDocument === null || !editor.state.doc.eq(savedDocument));

  const setCloseLocked = (requestId: number | null) => {
    closeLockRequestId = requestId;
    if (editor !== null) editor.contentDOM.contentEditable = requestId === null ? "true" : "false";
  };

  const syncDirty = async (next: boolean, requestId = 0) => {
    let lastError: unknown;
    for (let attempt = 0; attempt < 3; attempt += 1) {
      try {
        await requestFileBridge(document, "setDirty", {
          dirty: next,
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
    if (editor === null) return false;
    const documentSnapshot = editor.state.doc;
    const content = documentSnapshot.toString();
    const operation = mutationQueue.then(async () => {
      await requestFileBridge(document, "write", content);
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
    __maruSyncDirtyForClose?: (requestId: number) => Promise<boolean>;
    __maruSaveForClose?: (
      requestId: number,
    ) => Promise<{ success: boolean; revision: number; dirty: boolean }>;
    __maruUnlockFileClose?: (requestId: number) => Promise<boolean>;
  };
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

  const ensureEditor = (): EditorView => {
    if (editor !== null) return editor;
    editor = createMarkdownEditor(
      editorHost,
      savedContent,
      (update) => {
        if (applyingDiskContent) return;
        const baseRevision = revisions.documentRevision;
        let targetRevision = baseRevision;
        if (update.docChanged) {
          targetRevision = revisions.documentChanged();
          reportDirty(savedDocument === null || !update.state.doc.eq(savedDocument));
        }
        livePreviewController?.handleUpdate(update, baseRevision, targetRevision);
      },
      () => void save(),
    );
    savedDocument = editor.state.doc;
    const workerConstructor =
      "Worker" in targetWindow
        ? ((targetWindow as Window & { Worker: typeof Worker }).Worker ?? null)
        : null;
    livePreviewController = new LivePreviewEditorController(
      editor,
      revisions,
      workerConstructor,
      (state, reason) => {
        if (status === null) return;
        status.dataset.liveWorker = state;
        if (reason !== undefined) status.dataset.liveWorkerFailure = reason;
        if (state === "recovering") status.textContent = "라이브 프리뷰를 복구하는 중입니다.";
        else if (state === "disabled")
          status.textContent = "라이브 프리뷰를 사용할 수 없어 소스를 유지합니다.";
        else if (status.textContent?.includes("라이브 프리뷰")) status.textContent = "";
      },
      (desired, mounted) => {
        if (status === null) return;
        status.dataset.liveFragmentsDesired = String(desired);
        status.dataset.liveFragmentsMounted = String(mounted);
      },
    );
    if (closeLockRequestId !== null) editor.contentDOM.contentEditable = "false";
    return editor;
  };

  const applyMode = (next: FilePanelMode) => {
    mode = next;
    if (isEditableFileMode(mode)) {
      frame.hidden = true;
      editorHost.hidden = false;
      if (contentLoaded) {
        ensureEditor().focus();
        if (mode === "live-preview" && livePreviewAdmitted) livePreviewController?.enable();
        else livePreviewController?.disable();
      }
    } else {
      livePreviewController?.disable();
      if (editor !== null) reportDirty(currentDocumentIsDirty(), true);
      frame.hidden = false;
      editorHost.hidden = true;
      frame.contentWindow?.postMessage(
        {
          channel: viewerChannel,
          type: "render",
          markdown: editor?.state.doc.toString() ?? savedContent,
        },
        "*",
      );
    }
    document.body.dataset.fileMode = mode;
  };

  targetWindow.addEventListener("maru:file-mode", (event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    if (!isRecord(detail)) return;
    if (detail.mode === "read" || detail.mode === "source-edit" || detail.mode === "live-preview")
      applyMode(detail.mode);
  });
  targetWindow.addEventListener("maru:file-live-preview-active", (event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    if (!isRecord(detail) || typeof detail.active !== "boolean") return;
    livePreviewAdmitted = detail.active;
    if (mode !== "live-preview" || !contentLoaded) return;
    if (livePreviewAdmitted) livePreviewController?.enable();
    else livePreviewController?.disable();
  });
  targetWindow.addEventListener("maru:file-sync-dirty", () => {
    if (editor !== null) reportDirty(currentDocumentIsDirty(), true);
  });

  const loadFromDisk = async (
    syncNative: boolean,
    abortIfDirty = false,
    abortIfEditedDuringRead = false,
  ) => {
    const revisionBeforeRead = revisions.documentRevision;
    const result = await requestFileBridge(document, "read");
    if (typeof result.content !== "string") throw new Error("invalid file content");
    // clean auto-reload를 bridge read 대기 중 사용자가 편집하기 시작했다면 buffer를 절대 덮지 않는다.
    if (abortIfDirty && dirty) throw new Error("file became dirty during external reload");
    if (abortIfEditedDuringRead && revisions.documentRevision !== revisionBeforeRead) {
      throw new Error("file was edited during external reload");
    }
    savedContent = result.content;
    contentLoaded = true;
    if (editor !== null) {
      applyingDiskContent = true;
      try {
        editor.dispatch({
          changes: { from: 0, to: editor.state.doc.length, insert: result.content },
        });
        savedDocument = editor.state.doc;
      } finally {
        applyingDiskContent = false;
      }
      livePreviewController?.resync();
    } else {
      savedDocument = null;
    }
    dirty = false;
    if (syncNative) await syncDirty(false);
    frame.contentWindow?.postMessage(
      { channel: viewerChannel, type: "render", markdown: result.content },
      "*",
    );
    if (isEditableFileMode(mode)) applyMode(mode);
  };

  targetWindow.addEventListener("maru:file-reload", (event) => {
    const detail = (event as CustomEvent<unknown>).detail;
    const conflict = isRecord(detail) && detail.conflict === true;
    mutationQueue = mutationQueue
      .then(async () => {
        await loadFromDisk(false, !conflict, true);
        if (conflict) await requestFileBridge(document, "resolveExternalChange", true);
        if (status !== null) {
          status.dataset.fileRead = "true";
          status.textContent = "";
        }
      })
      .catch(async () => {
        try {
          await requestFileBridge(document, "resolveExternalChange", false);
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
    try {
      await loadFromDisk(false);
      if (status !== null) status.dataset.fileRead = "true";
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
    if (isLinkActivation(event.data)) {
      void requestFileBridge(document, "openLink", {
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
  targetWindow.addEventListener(
    "pagehide",
    () => {
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
  let fragmentPort: MessagePort | null = null;
  let fragmentCapability: RendererCapability | null = null;

  const revokeFragment = () => {
    fragmentPort?.close();
    fragmentPort = null;
    fragmentCapability = null;
  };

  root.addEventListener("click", (event) => {
    // Live fragment renderer는 asset/link capability가 없다. shell의 isolated trusted-click 경로가 붙기 전까지
    // 모든 fragment activation은 inert이며 부모 window로 action을 내보내지 않는다.
    if (!(event instanceof targetWindow.MouseEvent) || event.button !== 0) return;
    const target = event.target;
    if (!(target instanceof targetWindow.Element)) return;
    const link = target.closest<HTMLAnchorElement>("a[href]");
    if (fragmentPort !== null) {
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
    if (isFragmentInit(event.data)) {
      const port = event.ports[0];
      if (port === undefined || event.ports.length !== 1) return;
      revokeFragment();
      fragmentCapability = event.data.capability;
      fragmentPort = port;
      document.body.dataset.rendererMode = "fragment";
      root.setAttribute("aria-live", "off");
      root.innerHTML = "";
      port.onmessage = (portEvent) => {
        if (
          fragmentCapability === null ||
          !isFragmentRender(portEvent.data) ||
          !capabilitiesEqual(portEvent.data.capability, fragmentCapability)
        ) {
          return;
        }
        root.innerHTML = portEvent.data.html;
        const measured = Math.max(
          1,
          Math.ceil(root.getBoundingClientRect().height),
          root.scrollHeight,
        );
        port.postMessage({
          channel: fragmentChannel,
          type: "fragment-rendered",
          capability: fragmentCapability,
          height: measured,
        });
      };
      port.start();
      port.postMessage({
        channel: fragmentChannel,
        type: "fragment-ready",
        capability: fragmentCapability,
      });
      return;
    }
    if (fragmentPort !== null) return;
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
  targetWindow.addEventListener("pagehide", revokeFragment, { once: true });
}
