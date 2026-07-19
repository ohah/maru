import { maxLivePreviewResultBytes } from "./live-preview-protocol";

export const fragmentChannel = "maru.file.fragment.v1";

export type RendererCapability = Readonly<{
  documentRevision: number;
  projectionGeneration: number;
  widgetId: number;
  widgetGeneration: number;
  rendererInstance: number;
}>;

export type FragmentInit = Readonly<{
  channel: typeof fragmentChannel;
  type: "fragment-init";
  capability: RendererCapability;
}>;

export type FragmentRender = Readonly<{
  channel: typeof fragmentChannel;
  type: "fragment-render";
  capability: RendererCapability;
  html: string;
}>;

export type FragmentReady = Readonly<{
  channel: typeof fragmentChannel;
  type: "fragment-ready";
  capability: RendererCapability;
}>;

export type FragmentRendered = Readonly<{
  channel: typeof fragmentChannel;
  type: "fragment-rendered";
  capability: RendererCapability;
  height: number;
}>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isSafeIdentity(value: unknown, allowZero: boolean): value is number {
  return Number.isSafeInteger(value) && (allowZero ? Number(value) >= 0 : Number(value) > 0);
}

export function isRendererCapability(value: unknown): value is RendererCapability {
  return (
    isRecord(value) &&
    isSafeIdentity(value.documentRevision, true) &&
    isSafeIdentity(value.projectionGeneration, false) &&
    isSafeIdentity(value.widgetId, false) &&
    isSafeIdentity(value.widgetGeneration, false) &&
    isSafeIdentity(value.rendererInstance, false)
  );
}

export function capabilitiesEqual(left: RendererCapability, right: RendererCapability): boolean {
  return (
    left.documentRevision === right.documentRevision &&
    left.projectionGeneration === right.projectionGeneration &&
    left.widgetId === right.widgetId &&
    left.widgetGeneration === right.widgetGeneration &&
    left.rendererInstance === right.rendererInstance
  );
}

export function isFragmentInit(value: unknown): value is FragmentInit {
  return (
    isRecord(value) &&
    value.channel === fragmentChannel &&
    value.type === "fragment-init" &&
    isRendererCapability(value.capability)
  );
}

export function isFragmentRender(value: unknown): value is FragmentRender {
  return (
    isRecord(value) &&
    value.channel === fragmentChannel &&
    value.type === "fragment-render" &&
    isRendererCapability(value.capability) &&
    typeof value.html === "string" &&
    new TextEncoder().encode(value.html).byteLength <= maxLivePreviewResultBytes
  );
}

export function isFragmentReady(value: unknown): value is FragmentReady {
  return (
    isRecord(value) &&
    value.channel === fragmentChannel &&
    value.type === "fragment-ready" &&
    isRendererCapability(value.capability)
  );
}

export function isFragmentRendered(value: unknown): value is FragmentRendered {
  return (
    isRecord(value) &&
    value.channel === fragmentChannel &&
    value.type === "fragment-rendered" &&
    isRendererCapability(value.capability) &&
    typeof value.height === "number" &&
    Number.isFinite(value.height) &&
    value.height >= 1 &&
    value.height <= 1_000_000
  );
}

export function fragmentMessageMatches(
  value: FragmentReady | FragmentRendered,
  current: RendererCapability,
): boolean {
  return capabilitiesEqual(value.capability, current);
}
