/* Private owner for the opt-in Zig worker probe. No foreign windows touched. */
#ifndef UNICODE
#define UNICODE 1
#endif
#include <windows.h>
#include <stdbool.h>
#include <stdint.h>
#include <wchar.h>
static HWND modal;
static BOOL CALLBACK find_modal(HWND hwnd, LPARAM owner) {
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == GetCurrentProcessId() && GetAncestor(hwnd, GA_ROOTOWNER) == (HWND)owner && IsWindowVisible(hwnd)) {
        WCHAR cls[80];
        GetClassNameW(hwnd, cls, 80);
        if (!wcscmp(cls, L"#32770")) { modal = hwnd; return FALSE; }
    }
    return TRUE;
}
void *maru_picker_probe_owner(void) {
    HINSTANCE instance = GetModuleHandleW(NULL);
    WNDCLASSW cls = {0};
    cls.lpfnWndProc = DefWindowProcW;
    cls.hInstance = instance;
    cls.lpszClassName = L"MaruPrivateZigPickerOwner";
    if (!RegisterClassW(&cls)) return NULL;
    HWND hwnd = CreateWindowExW(WS_EX_TOOLWINDOW, cls.lpszClassName,
        L"Private Zig picker owner", WS_OVERLAPPEDWINDOW,
        10, 10, 600, 400, NULL, NULL, instance, NULL);
    if (hwnd) ShowWindow(hwnd, SW_SHOWNOACTIVATE);
    return hwnd;
}
void maru_picker_probe_pump(void) {
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg); DispatchMessageW(&msg);
    }
}
bool maru_picker_probe_modal(void *owner) {
    modal = NULL; EnumWindows(find_modal, (LPARAM)owner); return modal != NULL;
}
bool maru_picker_probe_enabled(void *owner) { return IsWindowEnabled(owner) != 0; }
void maru_picker_probe_destroy(void *owner) { DestroyWindow(owner); }
uint64_t maru_picker_probe_tick(void) { return GetTickCount64(); }
void maru_picker_probe_pause(void) { Sleep(5); }

const uint16_t *maru_picker_probe_directory(void) {
    static WCHAR path[32768];
    DWORD count = GetTempPathW(32768, path);
    return count && count < 32768 ? (const uint16_t *)path : NULL;
}
