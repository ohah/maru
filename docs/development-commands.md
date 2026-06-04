# 개발 명령

Maru 작업에서 사용하는 기본 명령이다.

## 도구

- 도구 설치/선택: `mise install`
- Zig 버전 확인: `zig version`
- mise가 선택한 Zig 확인: `mise current zig`

테스트된 Zig 버전은 정확히 `0.16.0`이다(`.mise.toml`, `build.zig.zon`의 `minimum_zig_version`). 0.16 개발 주기에서 `std.Io`(I/O 인터페이스), Writer/Reader, process 진입 API가 크게 바뀌었으므로, 같은 `0.16.0`이라도 다른 스냅샷/커밋에서는 빌드가 깨질 수 있다. 빌드가 std API 불일치로 실패하면 먼저 `mise current zig`로 정확한 버전을 확인한다.

## 빌드와 테스트

- 빌드: `mise run build`
- 테스트: `mise run test`
- E2E 테스트: `mise run e2e`
- 오라클 비교 테스트: `mise run oracle`
- 외부 오라클(opt-in, libvterm 필요): `mise run oracle-ext`
- 외부 오라클(opt-in, Ghostty libghostty-vt 필요): `mise run oracle-ghostty`
- 외부 오라클(opt-in, Alacritty Rust dumper 필요): `mise run oracle-alacritty`
- 빠른 스트레스 테스트: `mise run stress`
- 긴 opt-in 스트레스 테스트: `mise run stress-soak`
- 성능 예산 측정: `mise run perf`
- macOS PTY opt-in 테스트: `mise run pty`
- 포맷: `mise run fmt`
- 포맷 검사(변경 없이): `mise run fmt-check`
- facade import 경계 검사: `mise run check-boundaries`
- 전체 확인: `mise run check`
- Zig 테스트 직접 실행: `zig build test`

## 완료 전 확인

코드나 빌드 설정을 바꾼 PR은 기본적으로 다음을 통과해야 한다.

```sh
mise run check
git diff --check
```

문서만 바꾼 PR은 `git diff --check`를 최소 검증으로 사용한다. 다만 문서가 명령, 구조, 테스트 경로를 바꾸면 관련 명령도 함께 실행한다.
