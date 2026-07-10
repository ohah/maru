// Phase 5c placeholder 스크립트(script-src 'self' 하에 same-origin 스크립트가 로드·실행되는지 확인). 실행되면
// 상태 텍스트에 origin을 찍어, 손 테스트에서 신뢰 origin(maru-app://app)과 CSP 하 script 실행을 눈으로 확인한다.
// Phase 7 실 UI가 이 파일을 대체한다. docs/web-panel.md §7.1.
document.getElementById("status").textContent = "app.js 로드됨 (script-src 'self' OK) · " + location.origin;
