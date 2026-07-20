import { maxLivePreviewResultBytes } from "./live-preview-protocol";
import { isNonNegativeSafeInteger, isPositiveSafeInteger } from "./live-preview-identity";

export const fragmentChannel = "maru.file.fragment.v1";

export type RendererCapability = Readonly<{
  editorEpoch: number;
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
