import { encodeFileBridgeRequest } from "../src/file-bridge-request";

void encodeFileBridgeRequest({ method: "read", editor_epoch: 1 });
void encodeFileBridgeRequest({ method: "beginDocument", document_id: 1 });
void encodeFileBridgeRequest({
  method: "setDirty",
  dirty: true,
  editor_epoch: 1,
  revision: 1,
  request_id: 0,
});
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
void encodeFileBridgeRequest({
  method: "openLink",
  // @ts-expect-error openLink는 DirtyReport payload를 받을 수 없다.
  dirty: true,
  editor_epoch: 1,
  revision: 1,
  request_id: 0,
});
// @ts-expect-error request-scoped setDirty는 revision/request_id가 모두 필요하다.
void encodeFileBridgeRequest({ method: "setDirty", dirty: true });
