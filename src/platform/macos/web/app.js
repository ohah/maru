// Phase 5c placeholder 스크립트(script-src 'self' 하에 same-origin 스크립트가 로드·실행되는지 확인). 이 스크립트는
// **page world**에서 실행되므로 isolated world에만 주입된 브리지(window.maru, 5b)는 여기서 안 보여야 한다 —
// typeof window.maru === "undefined"면 격리 OK(page-world 미접근). Phase 7 실 UI가 이 파일을 대체한다.
// docs/web-panel.md §7.1, control-plane.md §8.1.1.
document.getElementById("status").textContent =
    "app.js 로드됨 (script-src 'self' OK) · " + location.origin + " · page-world window.maru=" + typeof window.maru;
