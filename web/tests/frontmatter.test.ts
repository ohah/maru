/**
 * frontmatter 가르기·되붙이기(docs/file-panel.md §2.5).
 *
 * 왜 중요한가: 이 왕복이 원문을 바꾸면 리치로 **열었다 저장하는 것만으로** 파일이 달라진다. frontmatter가 있는
 * 문서는 대부분 그 값이 빌드·배포에 쓰이므로, 한 글자만 어긋나도 조용히 사고가 된다.
 */

import { describe, expect, test } from "bun:test";
import { joinFrontmatter, splitFrontmatter } from "../src/frontmatter";

describe("frontmatter 가르기", () => {
  test("문서 맨 앞의 블록만 가른다", () => {
    const source = "---\ntitle: 문서\ntags: [a, b]\n---\n\n# 제목\n\n본문\n";
    const split = splitFrontmatter(source);
    expect(split.frontmatter).toBe("title: 문서\ntags: [a, b]");
    expect(split.body).toBe("\n# 제목\n\n본문\n");
    // 되붙이면 **원문 그대로**여야 한다 — 이게 깨지면 저장이 파일을 바꾼다.
    expect(joinFrontmatter(split.frontmatter, split.body)).toBe(source);
  });

  test("본문 중간의 `---`는 구분선이지 frontmatter가 아니다", () => {
    // 위치가 정의의 전부다. 중간 구분선을 삼키면 본문이 통째로 메타데이터가 된다.
    const source = "# 제목\n\n---\n\n본문\n";
    expect(splitFrontmatter(source)).toEqual({ frontmatter: null, body: source });
  });

  test("닫는 구분선이 없으면 가르지 않는다", () => {
    const source = "---\ntitle: 끝나지 않음\n\n본문만 이어짐\n";
    expect(splitFrontmatter(source)).toEqual({ frontmatter: null, body: source });
  });

  test("빈 frontmatter는 **있는 것**이다(null과 구분된다)", () => {
    const source = "---\n---\n본문\n";
    const split = splitFrontmatter(source);
    expect(split.frontmatter).toBe("");
    expect(joinFrontmatter(split.frontmatter, split.body)).toBe(source);
  });

  test("frontmatter가 없는 문서는 원문 그대로 지난다", () => {
    const source = "# 제목\n\n본문\n";
    const split = splitFrontmatter(source);
    expect(split.frontmatter).toBeNull();
    expect(joinFrontmatter(split.frontmatter, split.body)).toBe(source);
  });

  test("CRLF 문서와 구분선 뒤 공백을 견딘다", () => {
    const split = splitFrontmatter("--- \r\ntitle: 문서\r\n---\t\r\n본문\r\n");
    expect(split.frontmatter).toBe("title: 문서");
    expect(split.body).toBe("본문\r\n");
  });

  test("`---`로 시작하지만 첫 줄에 다른 글자가 있으면 아니다", () => {
    const source = "---주의\n본문\n";
    expect(splitFrontmatter(source).frontmatter).toBeNull();
  });
});
