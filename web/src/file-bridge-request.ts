export type DirtyReport = {
  dirty: boolean;
  editor_epoch: number;
  revision: number;
  request_id: number;
};
export type BeginDocumentRequest = { document_id: number };
export type ReadRequest = { editor_epoch: number };
export type WriteRequest = { editor_epoch: number; content: string };
export type ResolveExternalChangeRequest = { editor_epoch: number; success: boolean };
export type OpenLinkRequest = { editor_epoch: number; href: string; forceSystem: boolean };
export type RenderMermaidRequest = {
  editor_epoch: number;
  document_revision: number;
  projection_generation: number;
  widget_id: number;
  widget_generation: number;
  renderer_instance: number;
  fence_id: number;
  source_hash: string;
  source: string;
};
export type RevokeMermaidRequest = Pick<
  RenderMermaidRequest,
  | "editor_epoch"
  | "document_revision"
  | "projection_generation"
  | "widget_id"
  | "widget_generation"
  | "renderer_instance"
>;

export type FileBridgeRequest =
  | ({ method: "read" } & ReadRequest)
  | ({ method: "beginDocument" } & BeginDocumentRequest)
  | { method: "readAsset"; path: string }
  | { method: "readSelfImage" }
  | ({ method: "write" } & WriteRequest)
  | ({ method: "setDirty" } & DirtyReport)
  | ({ method: "resolveExternalChange" } & ResolveExternalChangeRequest)
  | ({ method: "openLink" } & OpenLinkRequest)
  | ({ method: "renderMermaid" } & RenderMermaidRequest)
  | ({ method: "revokeMermaid" } & RevokeMermaidRequest)
  | { method: "livePreviewReady"; editor_epoch: number };

export type FileMethod = FileBridgeRequest["method"];

export function encodeFileBridgeRequest(request: FileBridgeRequest): Record<string, unknown> {
  switch (request.method) {
    case "read":
      return { method: request.method, editor_epoch: request.editor_epoch };
    case "beginDocument":
      return { method: request.method, document_id: request.document_id };
    case "readAsset":
      return { method: request.method, path: request.path };
    case "readSelfImage":
      return { method: request.method };
    case "write":
      return {
        method: request.method,
        editor_epoch: request.editor_epoch,
        content: request.content,
      };
    case "setDirty":
      return {
        method: request.method,
        dirty: request.dirty,
        editor_epoch: request.editor_epoch,
        revision: request.revision,
        request_id: request.request_id,
      };
    case "resolveExternalChange":
      return {
        method: request.method,
        editor_epoch: request.editor_epoch,
        success: request.success,
      };
    case "openLink":
      return {
        method: request.method,
        editor_epoch: request.editor_epoch,
        href: request.href,
        forceSystem: request.forceSystem,
      };
    case "renderMermaid":
      return {
        method: request.method,
        editor_epoch: request.editor_epoch,
        document_revision: request.document_revision,
        projection_generation: request.projection_generation,
        widget_id: request.widget_id,
        widget_generation: request.widget_generation,
        renderer_instance: request.renderer_instance,
        fence_id: request.fence_id,
        source_hash: request.source_hash,
        source: request.source,
      };
    case "revokeMermaid":
      return {
        method: request.method,
        editor_epoch: request.editor_epoch,
        document_revision: request.document_revision,
        projection_generation: request.projection_generation,
        widget_id: request.widget_id,
        widget_generation: request.widget_generation,
        renderer_instance: request.renderer_instance,
      };
    case "livePreviewReady":
      return { method: request.method, editor_epoch: request.editor_epoch };
  }
}
