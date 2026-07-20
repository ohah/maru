import type { markdown } from "@codemirror/lang-markdown";

type MarkdownOptions = NonNullable<Parameters<typeof markdown>[0]>;
type MarkdownExtension = NonNullable<MarkdownOptions["extensions"]>;

export const maxMathDelimiterScanCodeUnits = 32 * 1024;

type MathDelimiterScanProbe = Readonly<{ stop: () => number }>;
let activeMathDelimiterScan: { scanned: number } | null = null;
const inlineMathScanByContext = new WeakMap<object, number>();

/** Test/performance instrumentation at the parser site; only actually visited candidate code units are counted. */
export function startMathDelimiterScanProbe(): MathDelimiterScanProbe {
  if (activeMathDelimiterScan !== null) throw new Error("math delimiter scan probe already active");
  const probe = { scanned: 0 };
  activeMathDelimiterScan = probe;
  return {
    stop: () => {
      if (activeMathDelimiterScan !== probe)
        throw new Error("math delimiter scan probe is not active");
      activeMathDelimiterScan = null;
      return probe.scanned;
    },
  };
}

function inspectedCodeUnit(): void {
  if (activeMathDelimiterScan !== null) activeMathDelimiterScan.scanned += 1;
}

function inspectInlineCodeUnit(context: object): boolean {
  const scanned = inlineMathScanByContext.get(context) ?? 0;
  if (scanned >= maxMathDelimiterScanCodeUnits) return false;
  inlineMathScanByContext.set(context, scanned + 1);
  inspectedCodeUnit();
  return true;
}

function whitespace(character: number): boolean {
  return character === 9 || character === 10 || character === 13 || character === 32;
}

function decimalDigit(character: number): boolean {
  return character >= 48 && character <= 57;
}

/**
 * Dollar math is deliberately conservative and source preserving:
 * - `$x$` is single-line, non-empty, and cannot have whitespace next to either delimiter.
 * - a closing inline `$` followed by a decimal digit is rejected, so `$5 and $10` stays currency text.
 * - `$$` is admitted only as a line-delimited block (`$$\n...\n$$`). Inline `$$x$$` stays source.
 * - every delimiter search stops after maxMathDelimiterScanCodeUnits; an unclosed candidate stays source.
 */
export const maruMathMarkdownExtension: MarkdownExtension = {
  defineNodes: ["InlineMath", { name: "BlockMath", block: true }, "MathMark"],
  parseBlock: [
    {
      name: "MaruBlockMath",
      before: "FencedCode",
      leaf(_context, leaf) {
        if (leaf.content !== "$$") return null;
        let scanned = 0;
        let exceeded = false;
        return {
          nextLine(context, line, activeLeaf) {
            if (exceeded) return false;
            const remaining = maxMathDelimiterScanCodeUnits - scanned;
            const inspected = Math.min(remaining, line.text.length + 1);
            scanned += inspected;
            if (activeMathDelimiterScan !== null) activeMathDelimiterScan.scanned += inspected;
            if (inspected < line.text.length + 1) {
              exceeded = true;
              return false;
            }
            if (line.text.slice(line.pos) !== "$$") return false;
            const closerFrom = context.lineStart + line.pos;
            context.addLeafElement(
              activeLeaf,
              context.elt("BlockMath", activeLeaf.start, closerFrom + 2, [
                context.elt("MathMark", activeLeaf.start, activeLeaf.start + 2),
                context.elt("MathMark", closerFrom, closerFrom + 2),
              ]),
            );
            context.nextLine();
            return true;
          },
          finish() {
            return false;
          },
        };
      },
    },
  ],
  parseInline: [
    {
      name: "MaruMath",
      after: "Escape",
      parse(context, next, position) {
        if (next !== 36) return -1; // U+0024 DOLLAR SIGN
        if (context.char(position - 1) === 36 || context.char(position + 1) === 36) return -1;
        const contentFrom = position + 1;
        if (whitespace(context.char(contentFrom))) return -1;

        for (let cursor = contentFrom; cursor < context.end; cursor += 1) {
          if (!inspectInlineCodeUnit(context)) return -1;
          const character = context.char(cursor);
          if (character === 92) {
            if (cursor + 1 < context.end) {
              if (!inspectInlineCodeUnit(context)) return -1;
              cursor += 1;
            }
            continue;
          }
          if (character === 10 || character === 13) return -1;
          if (character !== 36) continue;
          if (cursor === contentFrom || whitespace(context.char(cursor - 1))) continue;
          if (decimalDigit(context.char(cursor + 1))) continue;
          const to = cursor + 1;
          return context.addElement(
            context.elt("InlineMath", position, to, [
              context.elt("MathMark", position, contentFrom),
              context.elt("MathMark", cursor, to),
            ]),
          );
        }
        return -1;
      },
    },
  ],
};
