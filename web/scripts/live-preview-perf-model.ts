import { projectionFallbackReasons } from "../src/live-preview-diagnostics";
import {
  maxLivePreviewProjectionEntries,
  maxLivePreviewSyntaxNodes,
} from "../src/live-preview-projection";
import { maxLivePreviewProjectionCodeUnits } from "../src/live-preview-protocol";
import { maxMathDelimiterScanCodeUnits } from "../src/markdown-language";
import { maxRetainedLivePreviewIntents } from "../src/live-preview-interaction";

export const livePreviewPerfSchemaVersion = 3;

export type LivePreviewPerfCounters = Readonly<{
  visited_code_units: number;
  visited_syntax_nodes: number;
  selection_range_checks: number;
  math_scanned_code_units: number;
  dense_math_scanned_code_units: number;
  emitted_decorations: number;
  diffed_decorations: number;
  copied_bytes: number;
  source_transactions: number;
  projection_transactions: number;
  dom_mutations: number;
  iframe_create: number;
  iframe_destroy: number;
  retained_html_bytes: number;
  generated_outside_retention: number;
  intent_events: number;
  intent_cm6_transactions: number;
  intent_external_actions: number;
  intent_dual_effects: number;
  intent_zero_effect_rejections: number;
  intent_range_checks: number;
  intent_queue_capacity: number;
  intent_queue_max_retained: number;
  intent_queue_dropped: number;
  intent_bridge_calls: number;
  projection_fallback_counts: Readonly<Record<string, number>>;
}>;

export type LivePreviewPerfArtifact = Readonly<{
  schema_version: typeof livePreviewPerfSchemaVersion;
  scenario: "fp11c-8mib-1000-editable-projection-interactions";
  counters: LivePreviewPerfCounters;
}>;

const counterNames = [
  "visited_code_units",
  "visited_syntax_nodes",
  "selection_range_checks",
  "math_scanned_code_units",
  "dense_math_scanned_code_units",
  "emitted_decorations",
  "diffed_decorations",
  "copied_bytes",
  "source_transactions",
  "projection_transactions",
  "dom_mutations",
  "iframe_create",
  "iframe_destroy",
  "retained_html_bytes",
  "generated_outside_retention",
  "intent_events",
  "intent_cm6_transactions",
  "intent_external_actions",
  "intent_dual_effects",
  "intent_zero_effect_rejections",
  "intent_range_checks",
  "intent_queue_capacity",
  "intent_queue_max_retained",
  "intent_queue_dropped",
  "intent_bridge_calls",
  "projection_fallback_counts",
] as const;

export function validateLivePreviewPerfArtifact(artifact: LivePreviewPerfArtifact): void {
  if (artifact.schema_version !== livePreviewPerfSchemaVersion)
    throw new Error("live preview perf schema mismatch");
  if (artifact.scenario !== "fp11c-8mib-1000-editable-projection-interactions")
    throw new Error("live preview perf scenario mismatch");
  const actualNames = Object.keys(artifact.counters).sort();
  const expectedNames = [...counterNames].sort();
  if (JSON.stringify(actualNames) !== JSON.stringify(expectedNames))
    throw new Error("live preview perf counter set mismatch");
  for (const name of counterNames) {
    if (name === "projection_fallback_counts") continue;
    const value = artifact.counters[name];
    if (!Number.isSafeInteger(value) || value < 0)
      throw new Error(`invalid live preview perf counter: ${name}`);
  }
  const fallbackNames = Object.keys(artifact.counters.projection_fallback_counts).sort();
  if (JSON.stringify(fallbackNames) !== JSON.stringify([...projectionFallbackReasons].sort()))
    throw new Error("live preview fallback counter set mismatch");
  for (const value of Object.values(artifact.counters.projection_fallback_counts)) {
    if (!Number.isSafeInteger(value) || value < 0)
      throw new Error("invalid live preview fallback counter");
  }
  if (artifact.counters.copied_bytes !== 0)
    throw new Error("live preview input copied source bytes");
  if (artifact.counters.source_transactions !== 1_000)
    throw new Error("live preview source transaction fixture incomplete");
  if (
    artifact.counters.visited_code_units <= 0 ||
    artifact.counters.visited_code_units > maxLivePreviewProjectionCodeUnits * 1_100 ||
    artifact.counters.visited_syntax_nodes <= 0 ||
    artifact.counters.visited_syntax_nodes > maxLivePreviewSyntaxNodes * 1_100 ||
    artifact.counters.selection_range_checks <= 0 ||
    artifact.counters.selection_range_checks > maxLivePreviewSyntaxNodes * 1_100 ||
    artifact.counters.math_scanned_code_units <= 0 ||
    artifact.counters.math_scanned_code_units > maxMathDelimiterScanCodeUnits * 1_100 ||
    artifact.counters.dense_math_scanned_code_units <= 0 ||
    artifact.counters.dense_math_scanned_code_units > maxMathDelimiterScanCodeUnits ||
    artifact.counters.emitted_decorations <= 0 ||
    artifact.counters.emitted_decorations > maxLivePreviewProjectionEntries ||
    artifact.counters.diffed_decorations <= 0 ||
    artifact.counters.diffed_decorations > maxLivePreviewProjectionEntries * 1_100 ||
    artifact.counters.projection_transactions !== 1 ||
    artifact.counters.dom_mutations !== 0 ||
    artifact.counters.iframe_create !== 0 ||
    artifact.counters.iframe_destroy !== 0 ||
    artifact.counters.retained_html_bytes !== 0 ||
    artifact.counters.generated_outside_retention !== 0 ||
    artifact.counters.intent_events !== 6 ||
    artifact.counters.intent_cm6_transactions !== 1 ||
    artifact.counters.intent_external_actions !== 1 ||
    artifact.counters.intent_dual_effects !== 0 ||
    artifact.counters.intent_zero_effect_rejections !== 4 ||
    artifact.counters.intent_range_checks <= 0 ||
    artifact.counters.intent_range_checks > maxLivePreviewProjectionEntries ||
    artifact.counters.intent_queue_capacity !== maxRetainedLivePreviewIntents ||
    artifact.counters.intent_queue_max_retained !== maxRetainedLivePreviewIntents ||
    artifact.counters.intent_queue_dropped !== 1 ||
    artifact.counters.intent_bridge_calls !== 2
  ) {
    throw new Error("FP11c editable projection and interaction budget exceeded");
  }
  for (const reason of projectionFallbackReasons) {
    const expected = reason === "atomic-not-enabled" ? 1 : 0;
    if (artifact.counters.projection_fallback_counts[reason] !== expected)
      throw new Error("FP11c projection fallback mismatch");
  }
}
