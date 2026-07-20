export const maxLivePreviewSyntaxNodes = 8_192;
export const maxLivePreviewProjectionEntries = 4_096;

export type StyleRole =
  | "heading-1"
  | "heading-2"
  | "heading-3"
  | "heading-4"
  | "heading-5"
  | "heading-6"
  | "emphasis"
  | "strong"
  | "strike"
  | "inline-code"
  | "quote"
  | "list"
  | "thematic-break";

export type HiddenSyntaxRole =
  | "heading-marker"
  | "emphasis-marker"
  | "strong-marker"
  | "strike-marker"
  | "code-fence"
  | "list-marker"
  | "quote-marker"
  | "link-bracket"
  | "link-destination"
  | "escape";

export type AtomicRole = "image" | "math" | "fenced-code" | "mermaid";

type SourceRange = Readonly<{ from: number; to: number }>;

export type ProjectionEntry =
  | (SourceRange & Readonly<{ type: "style"; role: StyleRole }>)
  | (SourceRange & Readonly<{ type: "hidden-syntax"; role: HiddenSyntaxRole }>)
  | (SourceRange & Readonly<{ type: "task"; checked: boolean }>)
  | (SourceRange &
      Readonly<{
        type: "link";
        labelFrom: number;
        labelTo: number;
        destinationFrom: number;
        destinationTo: number;
      }>)
  | (SourceRange & Readonly<{ type: "table-cell"; row: number; column: number }>)
  | (SourceRange & Readonly<{ type: "atomic"; role: AtomicRole }>);

function compareNumber(left: number, right: number): number {
  return left === right ? 0 : left < right ? -1 : 1;
}

function compareString(left: string, right: string): number {
  return left === right ? 0 : left < right ? -1 : 1;
}

export function compareProjectionEntries(left: ProjectionEntry, right: ProjectionEntry): number {
  if (left.from !== right.from) return left.from - right.from;
  if (left.to !== right.to) return left.to - right.to;
  if (left.type !== right.type) return left.type < right.type ? -1 : 1;
  switch (left.type) {
    case "style":
    case "hidden-syntax":
    case "atomic":
      return compareString(left.role, (right as typeof left).role);
    case "task":
      return compareNumber(Number(left.checked), Number((right as typeof left).checked));
    case "link": {
      const candidate = right as typeof left;
      return (
        compareNumber(left.labelFrom, candidate.labelFrom) ||
        compareNumber(left.labelTo, candidate.labelTo) ||
        compareNumber(left.destinationFrom, candidate.destinationFrom) ||
        compareNumber(left.destinationTo, candidate.destinationTo)
      );
    }
    case "table-cell": {
      const candidate = right as typeof left;
      return compareNumber(left.row, candidate.row) || compareNumber(left.column, candidate.column);
    }
  }
}

export function projectionEntriesEqual(left: ProjectionEntry, right: ProjectionEntry): boolean {
  return compareProjectionEntries(left, right) === 0;
}
