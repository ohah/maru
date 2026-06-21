#ifndef MARU_PLATFORM_MACOS_PPM_WRITER_H
#define MARU_PLATFORM_MACOS_PPM_WRITER_H

#import <Foundation/Foundation.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>

/* BGRA8 픽셀 버퍼(드로어블/오프스크린 readback)를 PPM(P6) 파일로 쓴다. Metal smoke들과 제품
   Metal renderer screenshot 경로가 공유하는 단일 출처다(예전에는 같은 함수가 두 smoke .m에
   각자 static으로 복제돼 있었다 — 한 곳으로 모은다).

   PPM(P6)은 압축도 메타데이터도 없지만, 외부 이미지 라이브러리 없이도 사람이 Preview/이미지
   도구로 열어볼 수 있는 가장 단순한 artifact 포맷이다. summary 숫자만으로는 glyph bitmap이
   통째로 뒤집힌 회귀 같은 시각 결함을 사람이 확인할 수 없으므로, 실제로 그려진 픽셀을 그대로
   남겨 눈으로 확인하게 한다. 목적은 픽셀 압축 효율이 아니라 그 시각 확인이다.

   bgra_pixels는 행마다 bytes_per_row 간격(stride)으로 놓인 BGRA8 픽셀이다(Metal blit-to-buffer
   정렬 때문에 stride는 width*4보다 클 수 있다). 픽셀 채널 순서는 B,G,R,A로 가정하고(CAMetalLayer
   기본 pixelFormat이 BGRA8Unorm), R/G/B만 골라 P6로 쓴다(알파는 버린다). 성공 시 YES.

   static 정의를 헤더에 두는 이유: 이 함수를 쓰는 세 .m(두 smoke + renderer)은 서로 다른
   실행 바이너리에 컴파일되므로 심볼 충돌이 없고, static이면 include한 각 TU가 자기 복사본을
   갖는다(소스 단일 출처는 유지하면서 별도 .m 빌드 배선 없이 공유한다). */
static BOOL maru_write_ppm_from_bgra8_buffer(
    const char *path,
    const uint8_t *bgra_pixels,
    size_t width,
    size_t height,
    size_t bytes_per_row
) {
    if (path == NULL || bgra_pixels == NULL || width == 0 || height == 0) {
        return NO;
    }

    FILE *file = fopen(path, "wb");
    if (file == NULL) {
        return NO;
    }

    if (fprintf(file, "P6\n%zu %zu\n255\n", width, height) < 0) {
        fclose(file);
        return NO;
    }

    BOOL ok = YES;
    for (size_t y = 0; y < height && ok; y++) {
        const uint8_t *row = bgra_pixels + y * bytes_per_row;
        for (size_t x = 0; x < width; x++) {
            const uint8_t *pixel = row + x * 4;
            const uint8_t rgb[3] = { pixel[2], pixel[1], pixel[0] };
            if (fwrite(rgb, sizeof(rgb), 1, file) != 1) {
                ok = NO;
                break;
            }
        }
    }

    if (fclose(file) != 0) {
        ok = NO;
    }
    return ok;
}

#endif
