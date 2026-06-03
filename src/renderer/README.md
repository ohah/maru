# `src/renderer`

렌더러 내부 구현이 커질 때 사용하는 폴더다.

`src/renderer.zig`는 renderer facade로 유지한다. Metal/WebGPU backend, glyph atlas, frame stats, render snapshot 변환은 이 폴더 아래에 책임별로 둔다.

