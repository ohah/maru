import { encodeFileBridgeRequest } from "../src/file-bridge-request";

void encodeFileBridgeRequest({ method: "read" });
void encodeFileBridgeRequest({ method: "setDirty", dirty: true, revision: 1, request_id: 0 });
void encodeFileBridgeRequest({
  method: "openLink",
  href: "https://example.com",
  forceSystem: false,
});

void encodeFileBridgeRequest({
  method: "setDirty",
  // @ts-expect-error setDirty는 openLink payload를 받을 수 없다.
  href: "https://example.com",
  forceSystem: false,
});
// @ts-expect-error openLink는 DirtyReport payload를 받을 수 없다.
void encodeFileBridgeRequest({ method: "openLink", dirty: true, revision: 1, request_id: 0 });
// @ts-expect-error request-scoped setDirty는 revision/request_id가 모두 필요하다.
void encodeFileBridgeRequest({ method: "setDirty", dirty: true });
