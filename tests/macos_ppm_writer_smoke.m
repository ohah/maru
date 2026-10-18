// Exercise the product writer with real stdio buffering and failing OS-style streams.
#import <Foundation/Foundation.h>
#include <assert.h>
#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

static int mode;
static size_t remaining;
static int limited_write(void *cookie, const char *bytes, int count) {
    (void)cookie; (void)bytes;
    if (remaining >= (size_t)count) { remaining -= count; return count; }
    errno = mode == 5 ? 0 : ENOSPC;
    return -1;
}
static int limited_close(void *cookie) {
    (void)cookie;
    // A second error must not erase an earlier write failure.
    errno = EACCES;
    return -1;
}
static FILE *test_open(const char *path, const char *access) {
    if (mode == 1) { errno = ENOSPC; return NULL; }
    if (mode == 0) return fopen(path, access);
    remaining = mode == 2 ? 0 : (mode == 3 || mode == 5 ? 11 : 1000);
    FILE *file = funopen(NULL, NULL, limited_write, NULL, limited_close);
    assert(file != NULL);
    setvbuf(file, NULL, _IONBF, 0);
    return file;
}
#define fopen test_open
#include "../src/platform/macos/maru_ppm_writer.h"
#undef fopen

int main(int argc, char **argv) {
    assert(argc == 2);
    // Padded rows exercise stride and RGB order, not just file length.
    uint8_t pixels[] = {1,2,3,255, 4,5,6,255, 90,90,90,90,
                        7,8,9,255, 10,11,12,255, 91,91,91,91};
    const unsigned char expected[] = "P6\n2 2\n255\n\x03\x02\x01\x06\x05\x04\x09\x08\x07\x0c\x0b\x0a";
    MaruPPMWriteError error = {"stale", 99};
    assert(maru_write_ppm_from_bgra8_buffer_with_error(argv[1], pixels, 2, 2, 12, &error));
    assert(error.stage == NULL && error.code == 0);
    FILE *file = fopen(argv[1], "rb"); assert(file);
    unsigned char actual[sizeof(expected) + 1];
    size_t count = fread(actual, 1, sizeof(actual), file); fclose(file);
    assert(count == sizeof(expected)-1 && memcmp(actual, expected, count) == 0);
    assert(!maru_write_ppm_from_bgra8_buffer_with_error(argv[1], pixels, 2, 2, 7, &error));
    assert(!strcmp(error.stage, "argument") && error.code == EINVAL);
    assert(!maru_write_ppm_from_bgra8_buffer_with_error(argv[1], pixels, SIZE_MAX, 2, 12, &error));
    const char *stages[] = {NULL, "open", "header", "pixels", "close", "pixels"};
    for (mode = 1; mode <= 5; mode++) {
        assert(!maru_write_ppm_from_bgra8_buffer_with_error(argv[1], pixels, 2, 2, 12, &error));
        assert(!strcmp(error.stage, stages[mode]));
        int expected_code = mode == 4 ? EACCES : (mode == 5 ? EIO : ENOSPC);
        assert(error.code == expected_code && errno == expected_code);
    }
    mode = 1;
    assert(!maru_write_ppm_from_bgra8_buffer(argv[1], pixels, 2, 2, 12));
    assert(errno == ENOSPC);
    mode = 0;
    assert(maru_write_ppm_from_bgra8_buffer(argv[1], pixels, 2, 2, 12));
    puts("PPM RGB/stride, argument, open/header/pixels/close, first-error and legacy controls passed");
}
