import { projectionFallbackReasons } from "../src/live-preview-diagnostics";
import {
  maxLivePreviewProjectionEntries,
  maxLivePreviewSyntaxNodes,
  maxLivePreviewTableCells,
} from "../src/live-preview-projection";
import { maxLivePreviewProjectionCodeUnits } from "../src/live-preview-protocol";
import { maxMathDelimiterScanCodeUnits } from "../src/markdown-language";
import { maxRetainedLivePreviewIntents } from "../src/live-preview-interaction";

export const livePreviewPerfSchemaVersion = 4;

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
  table_intent_events: number;
  table_cm6_transactions: number;
  table_source_transactions: number;
  table_appended_rows: number;
  table_zero_effect_rejections: number;
  table_cell_cap: number;
  table_cap_plus_one_transactions: number;
  table_multirange_transactions: number;
  table_context_record_checks: number;
  table_context_cells_retained_max: number;
  table_queue_max_retained: number;
  table_external_actions: number;
  table_bridge_calls: number;
  table_iframe_create: number;
  table_iframe_destroy: number;
  table_copied_bytes: number;
  table_event_record_checks_max: number;
  table_projection_record_count: number;
  table_non_table_record_count: number;
  table_projection_record_checks_max: number;
  table_group_build_record_checks_max: number;
  table_group_cell_arrays_created_max: number;
  projection_fallback_counts: Readonly<Record<string, number>>;
}>;

export type LivePreviewPerfArtifact = Readonly<{
  schema_version: typeof livePreviewPerfSchemaVersion;
  scenario: "fp11d-8mib-1000-editable-projection-table-interactions";
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
  "table_intent_events",
  "table_cm6_transactions",
  "table_source_transactions",
  "table_appended_rows",
  "table_zero_effect_rejections",
  "table_cell_cap",
  "table_cap_plus_one_transactions",
  "table_multirange_transactions",
  "table_context_record_checks",
  "table_context_cells_retained_max",
  "table_queue_max_retained",
  "table_external_actions",
  "table_bridge_calls",
  "table_iframe_create",
  "table_iframe_destroy",
  "table_copied_bytes",
  "table_event_record_checks_max",
  "table_projection_record_count",
  "table_non_table_record_count",
  "table_projection_record_checks_max",
  "table_group_build_record_checks_max",
  "table_group_cell_arrays_created_max",
  "projection_fallback_counts",
] as const;

export function validateLivePreviewPerfArtifact(artifact: LivePreviewPerfArtifact): void {
  if (artifact.schema_version !== livePreviewPerfSchemaVersion)
    throw new Error("live preview perf schema mismatch");
  if (artifact.scenario !== "fp11d-8mib-1000-editable-projection-table-interactions")
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
    artifact.counters.intent_bridge_calls !== 2 ||
    artifact.counters.table_intent_events !== 10 ||
    artifact.counters.table_cm6_transactions !== 8 ||
    artifact.counters.table_source_transactions !== 2 ||
    artifact.counters.table_appended_rows !== 2 ||
    artifact.counters.table_zero_effect_rejections !== 2 ||
    artifact.counters.table_cell_cap !== maxLivePreviewTableCells ||
    artifact.counters.table_cap_plus_one_transactions !== 0 ||
    artifact.counters.table_multirange_transactions !== 0 ||
    artifact.counters.table_context_record_checks <= 0 ||
    artifact.counters.table_context_record_checks >
      32 * (artifact.counters.table_intent_events + 2) ||
    artifact.counters.table_context_cells_retained_max !== maxLivePreviewTableCells ||
    artifact.counters.table_queue_max_retained !== 1 ||
    artifact.counters.table_external_actions !== 0 ||
    artifact.counters.table_bridge_calls !== 0 ||
    artifact.counters.table_iframe_create !== 0 ||
    artifact.counters.table_iframe_destroy !== 0 ||
    artifact.counters.table_copied_bytes !== 0 ||
    artifact.counters.table_event_record_checks_max <= 0 ||
    artifact.counters.table_event_record_checks_max > 32 ||
    artifact.counters.table_projection_record_count !== maxLivePreviewProjectionEntries ||
    artifact.counters.table_non_table_record_count !==
      maxLivePreviewProjectionEntries - maxLivePreviewTableCells ||
    artifact.counters.table_projection_record_checks_max !== maxLivePreviewProjectionEntries ||
    artifact.counters.table_group_build_record_checks_max <= 0 ||
    artifact.counters.table_group_build_record_checks_max > maxLivePreviewProjectionEntries ||
    artifact.counters.table_group_cell_arrays_created_max !== 1
  ) {
    throw new Error("FP11d editable projection and table interaction budget exceeded");
  }
  for (const reason of projectionFallbackReasons) {
    const expected = reason === "atomic-not-enabled" ? 1 : 0;
    if (artifact.counters.projection_fallback_counts[reason] !== expected)
      throw new Error("FP11d projection fallback mismatch");
  }
}
