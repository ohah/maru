/**
 * 번들 폰트 로딩.
 *
 * maru 본체는 한글 폴백으로 **Jetendard** 를 쓴다 — 한글을 라틴 2배 폭으로 디자인해 등폭 격자에
 * 정확히 맞는 폰트다. 이게 없으면 브라우저의 시스템 cascade 가 한글을 비례 폰트로 그려서 셀마다
 * 여백이 남는다(본체 실측: 13pt 에서 글자당 4.76px). 앱 번들 안에만 있는 자산이라 브라우저에서는
 * 시스템 폰트로 잡히지 않으므로, 웹폰트로 실어야 같은 결과가 나온다.
 *
 * **기본은 로드하지 않는다**(1.6 MB). `loadFont: "jetendard"` 로 켜면 그때 받는다.
 */

/** 패키지에 함께 실린 Jetendard 의 기본 위치(weight 별). */
export function bundledFontUrl(weight: "Regular" | "Bold" = "Regular"): URL {
  // 소스(`src/font.ts`)와 번들(`dist/index.js`) 모두 `fonts/` 가 한 단계 위라 보정이 필요 없다.
  const base = import.meta.url || (typeof location !== "undefined" ? location.href : "");
  if (!base) throw new Error("maru-term: 폰트 경로를 정할 수 없다 — fontUrl 을 직접 넘겨라");
  return new URL(`../fonts/Jetendard-${weight}.woff2`, base);
}

/** 이미 로드한 URL. 터미널을 여러 개 열어도 한 번만 받는다. */
const loaded = new Map<string, Promise<void>>();

/**
 * 폰트를 현재 실행 문맥에 등록한다. **워커에서도 불러야 한다** — OffscreenCanvas 가 쓰는 폰트
 * 집합은 워커의 것이고, 메인에서 등록한 것은 거기 없다.
 */
/**
 * Regular 와 Bold 를 함께 등록한다. Bold 를 빼면 SGR 1 이 걸린 한글을 브라우저가 합성으로
 * 굵게 만드는데, 획이 뭉개지고 advance 가 흔들려 격자가 어긋난다.
 *
 * `url` 을 직접 주면 그 하나만 등록한다(weight 는 호출자가 관리한다).
 */
export function loadBundledFont(url?: string | URL): Promise<void> {
  if (url === undefined) {
    return Promise.all([
      loadFace(String(bundledFontUrl("Regular")), "400"),
      loadFace(String(bundledFontUrl("Bold")), "700"),
    ]).then(() => undefined);
  }
  return loadFace(String(url), "400");
}

function loadFace(src: string, weight: string): Promise<void> {
  const hit = loaded.get(src);
  if (hit) return hit;
  // 폰트 집합은 문맥마다 이름이 다르다 — 워커는 `self.fonts`, 메인은 `document.fonts` 다.
  // `globalThis.fonts` 만 보면 메인에서 조용히 아무것도 안 하고 끝난다.
  const target =
    (globalThis as { fonts?: FontFaceSet }).fonts ??
    (typeof document === "undefined" ? undefined : document.fonts);
  if (typeof FontFace === "undefined" || !target) return Promise.resolve();
  const task = new FontFace("Jetendard", `url(${src})`, { weight })
    .load()
    .then((face) => {
      target.add(face);
    })
    .catch((err: unknown) => {
      // 폰트를 못 받아도 터미널은 떠야 한다 — 시스템 폴백으로 계속 간다. 다만 **조용히**
      // 넘어가면 왜 격자가 벌어지는지 알 수 없으므로 한 줄 남긴다.
      console.warn("maru-term: 번들 폰트를 못 불러왔다 —", src, err);
    });
  loaded.set(src, task);
  return task;
}
