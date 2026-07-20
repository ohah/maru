import { maxAtomicAssetGrants } from "./atomic-projection";
import { maxLivePreviewResultBytes } from "./live-preview-protocol";
import { isNonNegativeSafeInteger, isPositiveSafeInteger } from "./live-preview-identity";

export const atomicRendererChannel = "maru.file.atomic.v1";

export type RendererCapability = Readonly<{
  editorEpoch: number;
  documentRevision: number;
  projectionGeneration: number;
  widgetId: number;
  widgetGeneration: number;
  rendererInstance: number;
}>;

export type AtomicRenderAsset = Readonly<{ opaqueId: number; dataUrl: string }>;

export type AtomicRendererInit = Readonly<{
  channel: typeof atomicRendererChannel;
  type: "atomic-init";
  capability: RendererCapability;
}>;

export type AtomicRendererRender = Readonly<{
  channel: typeof atomicRendererChannel;
  type: "atomic-render";
  capability: RendererCapability;
  payload: string;
  assets: readonly AtomicRenderAsset[];
}>;

export type AtomicRendererReady = Readonly<{
  channel: typeof atomicRendererChannel;
  type: "atomic-ready";
  capability: RendererCapability;
}>;

export type AtomicRendererRendered = Readonly<{
  channel: typeof atomicRendererChannel;
  type: "atomic-rendered";
  capability: RendererCapability;
  height: number;
}>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function isRendererCapability(value: unknown): value is RendererCapability {
  return (
    isRecord(value) &&
    isPositiveSafeInteger(value.editorEpoch) &&
    isNonNegativeSafeInteger(value.documentRevision) &&
    isPositiveSafeInteger(value.projectionGeneration) &&
    isPositiveSafeInteger(value.widgetId) &&
    isPositiveSafeInteger(value.widgetGeneration) &&
    isPositiveSafeInteger(value.rendererInstance)
  );
}

export function capabilitiesEqual(left: RendererCapability, right: RendererCapability): boolean {
  return (
    left.editorEpoch === right.editorEpoch &&
    left.documentRevision === right.documentRevision &&
    left.projectionGeneration === right.projectionGeneration &&
    left.widgetId === right.widgetId &&
    left.widgetGeneration === right.widgetGeneration &&
    left.rendererInstance === right.rendererInstance
  );
}

export function isAtomicRendererInit(value: unknown): value is AtomicRendererInit {
  return (
    isRecord(value) &&
    value.channel === atomicRendererChannel &&
    value.type === "atomic-init" &&
    isRendererCapability(value.capability)
  );
}

function atomicAssetValid(value: unknown): value is AtomicRenderAsset {
  return (
    isRecord(value) &&
    isPositiveSafeInteger(value.opaqueId) &&
    typeof value.dataUrl === "string" &&
    /^data:image\/(?:png|jpeg|gif|webp|avif|svg\+xml);base64,[A-Za-z0-9+/=]+$/.test(value.dataUrl)
  );
}

export function isAtomicRendererRender(value: unknown): value is AtomicRendererRender {
  if (
    !isRecord(value) ||
    value.channel !== atomicRendererChannel ||
    value.type !== "atomic-render" ||
    !isRendererCapability(value.capability) ||
    typeof value.payload !== "string" ||
    new TextEncoder().encode(value.payload).byteLength > maxLivePreviewResultBytes ||
    !Array.isArray(value.assets) ||
    value.assets.length > maxAtomicAssetGrants ||
    !value.assets.every(atomicAssetValid)
  ) {
    return false;
  }
  return new Set(value.assets.map(({ opaqueId }) => opaqueId)).size === value.assets.length;
}

export function isAtomicRendererReady(value: unknown): value is AtomicRendererReady {
  return (
    isRecord(value) &&
    value.channel === atomicRendererChannel &&
    value.type === "atomic-ready" &&
    isRendererCapability(value.capability)
  );
}

export function isAtomicRendererRendered(value: unknown): value is AtomicRendererRendered {
  return (
    isRecord(value) &&
    value.channel === atomicRendererChannel &&
    value.type === "atomic-rendered" &&
    isRendererCapability(value.capability) &&
    typeof value.height === "number" &&
    Number.isFinite(value.height) &&
    value.height >= 1 &&
    value.height <= 1_000_000
  );
}

export function atomicRendererMessageMatches(
  value: AtomicRendererReady | AtomicRendererRendered,
  current: RendererCapability,
): boolean {
  return capabilitiesEqual(value.capability, current);
}
