// maru ↔ wuffs PNG 다리.
//
// **왜 C 셰임인가**: wuffs 의 C API 는 구조체를 **값으로** 주고받는다(io_buffer·pixel_buffer·
// image_config). 그걸 Zig 에서 손으로 선언하면 상류가 필드를 바꿀 때 조용히 어긋난다. 여기서 값
// 전달을 다 흡수하고 Zig 에는 **평평한 함수 둘**만 노출한다.
//
// **왜 두 단계인가**: 할당을 Zig 가 쥐어야 한다. 코어에 320MB 이미지 총량 회계가 있고(kitty.zig),
// 디코더가 자기 마음대로 malloc 하면 그 회계 밖에서 메모리가 늘어난다. 그래서 ① 머리만 읽어
// 치수·필요 바이트를 알려주고 ② 호출자가 준 버퍼에 풀어 넣는다.
//
// **libc 할당자를 안 쓴다.** 디코더 구조체(실측 44,632 B)도 호출자가 준다 — 그래서 이 파일이
// 링크에 요구하는 것은 `mem*`/`str*` 몇 개뿐이고 그건 Zig 의 compiler-rt 가 모든 타깃에서 준다.
// 덕분에 wasm32-freestanding 이 **import 하나 없이** 선다(실측: Debug·ReleaseSmall 양쪽).
#include <stddef.h>

// **libc 할당자를 아예 안 남긴다.** calloc/free 를 부르는 것은 wuffs 의 `..._alloc()` 편의 생성자
// 뿐이고(디코더를 자기가 할당해 주는 길), 우리는 하나도 안 쓴다. 그런데 그 함수들은 extern 이라
// 최적화가 약한 모드에서는 살아남아 **wasm32-freestanding 링크에 없는 심볼을 요구한다**. 이름을
// 바꿔치기해 그 가지를 컴파일 시점에 끊는다 — NULL 반환은 그 생성자들의 문서화된 실패 경로다.
// (셰임 `stdlib.h` 가 둘을 선언하지 않아 재선언 충돌이 없다 — wuffs_cshim/README.md)
static void *maru_wuffs_no_calloc(size_t n, size_t sz) {
    (void)n;
    (void)sz;
    return NULL;
}
static void maru_wuffs_no_free(void *p) { (void)p; }
#define calloc maru_wuffs_no_calloc
#define free maru_wuffs_no_free

#define WUFFS_IMPLEMENTATION
#define WUFFS_CONFIG__MODULES
#define WUFFS_CONFIG__MODULE__BASE
#define WUFFS_CONFIG__MODULE__ADLER32
#define WUFFS_CONFIG__MODULE__CRC32
#define WUFFS_CONFIG__MODULE__DEFLATE
#define WUFFS_CONFIG__MODULE__ZLIB
#define WUFFS_CONFIG__MODULE__PNG
#include "wuffs-v0.4.c"

#include <stdint.h>
#include <string.h>

// 반환 코드 — Zig 쪽 enum 과 1:1 이다.
#define MARU_PNG_OK 0
#define MARU_PNG_MALFORMED 1
#define MARU_PNG_UNSUPPORTED 2
#define MARU_PNG_TOO_BIG 3

// ① 머리만 읽는다. 픽셀은 건드리지 않는다.
size_t maru_png_decoder_size(void) { return sizeof__wuffs_png__decoder(); }

// **픽셀 버퍼 크기는 안 돌려준다.** 호출자가 `w*h*4` 로 직접 계산해 할당한다 — 그래야 그 산술이
// 총량 회계와 같은 자리에 있고, 우리 계산이 wuffs 의 기대와 어긋나면 `set_from_slice` 가 ②에서
// 거절한다(조용히 어긋난 stride 로 그리는 대신 fail-closed).
int32_t maru_png_probe(void *dec_mem, size_t dec_len,
                       const uint8_t *src, size_t src_len,
                       uint32_t *out_w, uint32_t *out_h,
                       uint64_t *out_workbuf_len) {
    // wuffs 의 `initialize` 는 크기가 **정확히** 같기를 요구한다(크거나 같은 것으로는 안 된다).
    // 호출자에겐 「이만큼 이상 주라」가 맞는 계약이므로 그 차이를 여기서 흡수한다.
    if (dec_len < sizeof__wuffs_png__decoder()) return MARU_PNG_UNSUPPORTED;
    wuffs_png__decoder *dec = (wuffs_png__decoder *)dec_mem;
    wuffs_base__status st = wuffs_png__decoder__initialize(
        dec, sizeof__wuffs_png__decoder(), WUFFS_VERSION, WUFFS_INITIALIZE__DEFAULT_OPTIONS);
    if (!wuffs_base__status__is_ok(&st)) return MARU_PNG_UNSUPPORTED;

    wuffs_base__io_buffer io = wuffs_base__ptr_u8__reader((uint8_t *)src, src_len, true);
    wuffs_base__image_config ic = {0};
    st = wuffs_png__decoder__decode_image_config(dec, &ic, &io);
    if (!wuffs_base__status__is_ok(&st)) return MARU_PNG_MALFORMED;

    // **언제나 RGBA 8비트로 받는다.** palette·grayscale·16-bit 를 wuffs 가 여기서 흡수하므로
    // 코어는 색 종류를 몰라도 된다(손코덱 시절에는 그 분기가 전부 코어에 있었다).
    wuffs_base__pixel_config__set(&ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
                                  WUFFS_BASE__PIXEL_SUBSAMPLING__NONE,
                                  wuffs_base__pixel_config__width(&ic.pixcfg),
                                  wuffs_base__pixel_config__height(&ic.pixcfg));
    *out_w = wuffs_base__pixel_config__width(&ic.pixcfg);
    *out_h = wuffs_base__pixel_config__height(&ic.pixcfg);
    *out_workbuf_len = wuffs_png__decoder__workbuf_len(dec).max_incl;
    return (*out_w == 0 || *out_h == 0) ? MARU_PNG_MALFORMED : MARU_PNG_OK;
}

// ② 호출자가 준 버퍼에 푼다. `pixels` 는 probe 가 알려준 길이, `workbuf` 도 마찬가지다.
int32_t maru_png_decode(void *dec_mem, size_t dec_len,
                        const uint8_t *src, size_t src_len,
                        uint8_t *pixels, size_t pixels_len,
                        uint8_t *workbuf, size_t workbuf_len) {
    // wuffs 의 `initialize` 는 크기가 **정확히** 같기를 요구한다(크거나 같은 것으로는 안 된다).
    // 호출자에겐 「이만큼 이상 주라」가 맞는 계약이므로 그 차이를 여기서 흡수한다.
    if (dec_len < sizeof__wuffs_png__decoder()) return MARU_PNG_UNSUPPORTED;
    wuffs_png__decoder *dec = (wuffs_png__decoder *)dec_mem;
    wuffs_base__status st = wuffs_png__decoder__initialize(
        dec, sizeof__wuffs_png__decoder(), WUFFS_VERSION, WUFFS_INITIALIZE__DEFAULT_OPTIONS);
    if (!wuffs_base__status__is_ok(&st)) return MARU_PNG_UNSUPPORTED;

    wuffs_base__io_buffer io = wuffs_base__ptr_u8__reader((uint8_t *)src, src_len, true);
    wuffs_base__image_config ic = {0};
    st = wuffs_png__decoder__decode_image_config(dec, &ic, &io);
    if (!wuffs_base__status__is_ok(&st)) return MARU_PNG_MALFORMED;
    wuffs_base__pixel_config__set(&ic.pixcfg, WUFFS_BASE__PIXEL_FORMAT__RGBA_NONPREMUL,
                                  WUFFS_BASE__PIXEL_SUBSAMPLING__NONE,
                                  wuffs_base__pixel_config__width(&ic.pixcfg),
                                  wuffs_base__pixel_config__height(&ic.pixcfg));

    wuffs_base__pixel_buffer pb = {0};
    st = wuffs_base__pixel_buffer__set_from_slice(
        &pb, &ic.pixcfg, wuffs_base__make_slice_u8(pixels, pixels_len));
    if (!wuffs_base__status__is_ok(&st)) return MARU_PNG_TOO_BIG;

    st = wuffs_png__decoder__decode_frame(dec, &pb, &io, WUFFS_BASE__PIXEL_BLEND__SRC,
                                          wuffs_base__make_slice_u8(workbuf, workbuf_len), NULL);
    return wuffs_base__status__is_ok(&st) ? MARU_PNG_OK : MARU_PNG_MALFORMED;
}
