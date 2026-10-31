#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include "native.h"
#define REQUIRE(x) do { if (!(x)) { fprintf(stderr, "FAIL line %d: %s\n", __LINE__, #x); return 1; } } while (0)
int main(void) {
    uint32_t file = 0, folder = 0;
    REQUIRE(maru_windows_file_dialog_probe_options(1, &file) == 0);
    REQUIRE(maru_windows_file_dialog_probe_options(2, &folder) == 0);
    const uint32_t required = 0x40 | 0x8 | 0x800 | 0x1000 | 0x02000000;
    REQUIRE((file & required) == required);
    REQUIRE((folder & required) == required);
    REQUIRE((file & 0x20) == 0);
    REQUIRE((folder & 0x20) != 0);
    uint32_t invalid = 123;
    REQUIRE((uint32_t)maru_windows_file_dialog_probe_options(99, &invalid) == 0x80070057u);
    REQUIRE(invalid == 0);
    REQUIRE((uint32_t)maru_windows_file_dialog_run(NULL, NULL, 1, NULL, NULL) == 0x80004003u);
    REQUIRE(maru_windows_file_dialog_path(NULL) == NULL);
    maru_windows_file_dialog_cancel(NULL);
    maru_windows_file_dialog_destroy(NULL);
    MaruFileDialog *once = maru_windows_file_dialog_create();
    REQUIRE(once != NULL);
    REQUIRE((uint32_t)maru_windows_file_dialog_run(once, NULL, 0, NULL, NULL) == 0x80070057u);
    REQUIRE((uint32_t)maru_windows_file_dialog_run(once, NULL, 0, NULL, NULL) == 0x8000ffffu);
    REQUIRE(maru_windows_file_dialog_path(once) == NULL);
    maru_windows_file_dialog_destroy(once);
    REQUIRE(SUCCEEDED(CoInitializeEx(NULL, COINIT_MULTITHREADED)));
    MaruFileDialog *canceled = maru_windows_file_dialog_create();
    REQUIRE(canceled != NULL);
    maru_windows_file_dialog_cancel(canceled);
    REQUIRE((uint32_t)maru_windows_file_dialog_run(canceled, NULL, 1, NULL, NULL) == 0x800704c7u);
    REQUIRE(maru_windows_file_dialog_path(canceled) == NULL);
    maru_windows_file_dialog_destroy(canceled);
    CoUninitialize();
    printf("PASS native COM options, canceled-before-initialize, invalid inputs and one-shot ownership; file=%08x folder=%08x\n", file, folder);
    return 0;
}
