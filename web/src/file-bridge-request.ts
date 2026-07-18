export type DirtyReport = { dirty: boolean; revision: number; request_id: number };
export type OpenLinkRequest = { href: string; forceSystem: boolean };

export type FileBridgeRequest =
  | { method: "read" }
  | { method: "readAsset"; path: string }
  | { method: "write"; content: string }
  | ({ method: "setDirty" } & DirtyReport)
  | { method: "resolveExternalChange"; success: boolean }
  | ({ method: "openLink" } & OpenLinkRequest);

export type FileMethod = FileBridgeRequest["method"];

export function encodeFileBridgeRequest(request: FileBridgeRequest): Record<string, unknown> {
  switch (request.method) {
    case "read":
      return { method: request.method };
    case "readAsset":
      return { method: request.method, path: request.path };
    case "write":
      return { method: request.method, content: request.content };
    case "setDirty":
      return {
        method: request.method,
        dirty: request.dirty,
        revision: request.revision,
        request_id: request.request_id,
      };
    case "resolveExternalChange":
      return { method: request.method, success: request.success };
    case "openLink":
      return {
        method: request.method,
        href: request.href,
        forceSystem: request.forceSystem,
      };
  }
}
