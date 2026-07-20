import {
  isNonNegativeSafeInteger,
  isPositiveSafeInteger,
  sourceRangeIsValid,
} from "./live-preview-identity";

type IntentIdentity = Readonly<{
  editorEpoch: number;
  documentRevision: number;
  projectionGeneration: number;
  from: number;
  to: number;
  trusted: boolean;
}>;

export type LinkActivationDisposition =
  | "primary-pointer"
  | "command-pointer"
  | "command-shift-pointer"
  | "keyboard";

export type LivePreviewIntent =
  | (IntentIdentity & Readonly<{ type: "place-caret"; input: "pointer"; gestureNonce: null }>)
  | (IntentIdentity &
      Readonly<{
        type: "toggle-task";
        input: "pointer" | "keyboard";
        gestureNonce: null;
      }>)
  | (IntentIdentity &
      Readonly<{
        type: "activate-link";
        disposition: LinkActivationDisposition;
        gestureNonce: number;
      }>)
  | (IntentIdentity &
      Readonly<{
        type: "select-atomic";
        input: "pointer" | "keyboard";
        gestureNonce: null;
      }>)
  | (IntentIdentity &
      Readonly<{
        type: "move-table-cell";
        input: "keyboard";
        direction: "forward" | "backward";
        gestureNonce: null;
      }>)
  | (IntentIdentity &
      Readonly<{ type: "append-table-row"; input: "keyboard"; gestureNonce: null }>);

export type EditorInteractionGuard = Readonly<{
  editorEpoch: number;
  documentRevision: number;
  projectionGeneration: number;
  mode: "read" | "live-preview" | "source-edit";
  closeLockRequestId: number | null;
  composing: boolean;
  readonly: boolean;
}>;

export type InteractionRejectReason =
  | "stale-epoch"
  | "stale-revision"
  | "stale-projection"
  | "stale-range"
  | "close-locked"
  | "readonly"
  | "composing"
  | "untrusted-event"
  | "duplicate-gesture"
  | "invalid-intent";

export type IntentResult =
  | Readonly<{ type: "committed" }>
  | Readonly<{ type: "consumed-no-change"; reason: InteractionRejectReason }>
  | Readonly<{ type: "rejected"; reason: InteractionRejectReason }>;

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function hasExactKeys(value: Record<string, unknown>, expected: readonly string[]): boolean {
  const actual = Object.keys(value).sort();
  return actual.length === expected.length && actual.every((key, index) => key === expected[index]);
}

const identityKeys = [
  "documentRevision",
  "editorEpoch",
  "from",
  "projectionGeneration",
  "to",
  "trusted",
] as const;

export function isLivePreviewIntent(value: unknown): value is LivePreviewIntent {
  if (!isRecord(value)) return false;
  if (
    !isPositiveSafeInteger(value.editorEpoch) ||
    !isNonNegativeSafeInteger(value.documentRevision) ||
    !isPositiveSafeInteger(value.projectionGeneration) ||
    !isNonNegativeSafeInteger(value.from) ||
    !isNonNegativeSafeInteger(value.to) ||
    typeof value.trusted !== "boolean"
  ) {
    return false;
  }
  const commonKeys = [...identityKeys, "gestureNonce", "type"];
  switch (value.type) {
    case "place-caret":
      return (
        hasExactKeys(value, [...commonKeys, "input"].sort()) &&
        value.input === "pointer" &&
        value.gestureNonce === null
      );
    case "toggle-task":
    case "select-atomic":
      return (
        hasExactKeys(value, [...commonKeys, "input"].sort()) &&
        (value.input === "pointer" || value.input === "keyboard") &&
        value.gestureNonce === null
      );
    case "activate-link":
      return (
        hasExactKeys(value, [...commonKeys, "disposition"].sort()) &&
        (value.disposition === "primary-pointer" ||
          value.disposition === "command-pointer" ||
          value.disposition === "command-shift-pointer" ||
          value.disposition === "keyboard") &&
        isPositiveSafeInteger(value.gestureNonce)
      );
    case "move-table-cell":
      return (
        hasExactKeys(value, [...commonKeys, "direction", "input"].sort()) &&
        value.input === "keyboard" &&
        (value.direction === "forward" || value.direction === "backward") &&
        value.gestureNonce === null
      );
    case "append-table-row":
      return (
        hasExactKeys(value, [...commonKeys, "input"].sort()) &&
        value.input === "keyboard" &&
        value.gestureNonce === null
      );
    default:
      return false;
  }
}

export function interactionGuardRejection(
  intent: LivePreviewIntent,
  guard: EditorInteractionGuard,
  documentLength: number,
  gestureNonceFresh: boolean,
): InteractionRejectReason | null {
  if (!isLivePreviewIntent(intent) || !isNonNegativeSafeInteger(documentLength))
    return "invalid-intent";
  if (!sourceRangeIsValid(intent.from, intent.to, documentLength, true)) return "stale-range";
  if (intent.editorEpoch !== guard.editorEpoch) return "stale-epoch";
  if (intent.documentRevision !== guard.documentRevision) return "stale-revision";
  if (intent.projectionGeneration !== guard.projectionGeneration) return "stale-projection";
  if (guard.closeLockRequestId !== null) return "close-locked";
  if (guard.readonly || guard.mode !== "live-preview") return "readonly";
  if (guard.composing) return "composing";
  if (!intent.trusted) return "untrusted-event";
  if (intent.type === "activate-link") {
    if (!isPositiveSafeInteger(intent.gestureNonce)) return "invalid-intent";
    if (!gestureNonceFresh) return "duplicate-gesture";
  }
  return null;
}
