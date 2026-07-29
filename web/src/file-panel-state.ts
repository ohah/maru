/**
 * 파일 패널 shell의 모드와 편집 revision 시계다.
 *
 * 모드는 셋이다 — `read`(격리 render origin이 그린 프리뷰), `rich`(툴바를 가진 문서모델 WYSIWYG),
 * `source-edit`(CM6 생 텍스트). 편집 화면에 렌더를 겹치는 라이브 프리뷰는 폐기했다(docs/file-panel.md §1·§2.5).
 */

export type FilePanelMode = "read" | "rich" | "source-edit";

export function isEditableFileMode(mode: FilePanelMode): boolean {
  return mode === "source-edit" || mode === "rich";
}

/**
 * CodeMirror 문서가 유일한 source buffer다. revision은 저장 identity가 아니라 **단조 시계**이며,
 * 늦게 도착한 native 응답이 더 새로운 문서 상태를 덮어쓰지 못하게 막는 것이 유일한 역할이다.
 */
export class EditorRevisionClock {
  documentRevision = 0;

  documentChanged(): number {
    this.documentRevision += 1;
    return this.documentRevision;
  }
}
