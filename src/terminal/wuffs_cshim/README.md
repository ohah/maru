# wuffs C 셰임 헤더

wuffs(`release/c/wuffs-v0.4.c`)는 `<stdlib.h>`와 `<string.h>`를 포함한다. **wasm32-freestanding 에는
libc 가 없어** 그 둘이 없다 — clang 이 주는 것은 `stdint.h`·`stdbool.h`·`limits.h` 같은 컴파일러
헤더뿐이다. 여기 있는 두 파일이 wuffs 가 실제로 쓰는 선언만 담아 그 자리를 메운다.

**모든 타깃이 이 셰임을 쓴다**(`-I` 가 시스템 경로보다 먼저 검색된다). 타깃마다 다른 헤더를 보면
wasm 에서만 터지는 결함이 생기고, 그 빌드는 CI 에서 제일 늦게 도는 자리다. 실측으로 macOS·
wasm32-freestanding 양쪽이 이 헤더로 컴파일·링크된다.

**`calloc`/`free` 를 일부러 안 적었다.** 그 둘을 부르는 것은 wuffs 의 `..._alloc()` 편의 생성자뿐이고
우리는 하나도 쓰지 않는다(할당은 Zig 가 한다 — `png_wuffs.c` 머리말). 선언이 없으면 `png_wuffs.c`
가 그 이름을 자기 스텁으로 바꿔치기할 수 있고, 그래야 **최적화 모드와 무관하게** libc 할당자 심볼이
링크에 안 남는다.
