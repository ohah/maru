export type FilePanelMode = "read" | "source-edit" | "live-preview";

export function isEditableFileMode(mode: FilePanelMode): boolean {
  return mode === "source-edit" || mode === "live-preview";
}

export type ProjectionSnapshot = Readonly<{
  documentRevision: number;
  projectionGeneration: number;
}>;

/**
 * The CodeMirror document is the only source buffer. Worker projections receive immutable snapshots whose
 * document revision and projection generation are independent, so a late render can never replace a newer one.
 */
export class EditorRevisionClock {
  documentRevision = 0;
  projectionGeneration = 0;

  documentChanged(): number {
    this.documentRevision += 1;
    return this.documentRevision;
  }

  nextProjection(): ProjectionSnapshot {
    this.projectionGeneration += 1;
    return {
      documentRevision: this.documentRevision,
      projectionGeneration: this.projectionGeneration,
    };
  }
}
