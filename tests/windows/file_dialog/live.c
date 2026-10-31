/* Isolated native UI probe. Only this process's hidden owner and STA dialog
 * are observed; cancellation uses the adapter handle, never foreign HWNDs. */
#ifndef UNICODE
#define UNICODE 1
#endif
#ifndef _UNICODE
#define _UNICODE 1
#endif
#include <windows.h>
#include <stdint.h>
#include <stdio.h>
#include <wchar.h>
#include "native.h"

typedef struct Probe {
    MaruFileDialog *state;
    HWND owner;
    HWND dialog;
    DWORD thread;
    uint32_t mode;
    const WCHAR *directory;
    volatile LONG hr;
} Probe;
static void pump(void) {
    MSG msg;
    while (PeekMessageW(&msg, NULL, 0, 0, PM_REMOVE)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
}
static DWORD WINAPI run_dialog(void *raw) {
    Probe *p = (Probe *)raw;
    int32_t hr = maru_windows_file_dialog_run(p->state, p->owner, p->mode,
        (const uint16_t *)p->directory,
        (const uint16_t *)L"Maru private native picker probe");
    InterlockedExchange(&p->hr, (LONG)hr);
    return 0;
}
static BOOL CALLBACK find_dialog(HWND hwnd, LPARAM raw) {
    Probe *p = (Probe *)raw;
    DWORD pid = 0;
    GetWindowThreadProcessId(hwnd, &pid);
    if (pid == GetCurrentProcessId() && GetAncestor(hwnd, GA_ROOTOWNER) == p->owner && IsWindowVisible(hwnd)) {
        WCHAR cls[80];
        GetClassNameW(hwnd, cls, 80);
        if (wcscmp(cls, L"#32770") == 0) { p->dialog = hwnd; return FALSE; }
    }
    return TRUE;
}
static int wait_thread(HANDLE thread, DWORD timeout) {
    ULONGLONG deadline = GetTickCount64() + timeout;
    do {
        pump();
        if (WaitForSingleObject(thread, 0) == WAIT_OBJECT_0) return 1;
        Sleep(5);
    } while (GetTickCount64() < deadline);
    return 0;
}
int wmain(int argc, WCHAR **argv) {
    if (argc != 3) { fprintf(stderr, "expected mode and private directory\n"); return 1; }
    uint32_t mode = (uint32_t)wcstoul(argv[1], NULL, 10);
    if (mode != 1 && mode != 2) return 1;
    HINSTANCE instance = GetModuleHandleW(NULL);
    const WCHAR *class_name = L"MaruPrivatePickerOwnerProbe";
    WNDCLASSW cls = {0}; cls.lpfnWndProc = DefWindowProcW;
    cls.hInstance = instance; cls.lpszClassName = class_name;
    if (!RegisterClassW(&cls)) return 1;
    HWND owner = CreateWindowExW(WS_EX_TOOLWINDOW, class_name, L"Private picker owner",
        WS_OVERLAPPEDWINDOW, 10, 10, 600, 400, NULL, NULL, instance, NULL);
    if (!owner) return 1;
    ShowWindow(owner, SW_SHOWNOACTIVATE);
    Probe p = {0}; p.mode = mode; p.owner = owner; p.directory = argv[2];
    p.state = maru_windows_file_dialog_create();
    if (!p.state) return 1;
    HANDLE thread = CreateThread(NULL, 0, run_dialog, &p, 0, &p.thread);
    if (!thread) { maru_windows_file_dialog_destroy(p.state); DestroyWindow(owner); return 1; }
    ULONGLONG deadline = GetTickCount64() + 15000;
    do {
        pump();
        EnumWindows(find_dialog, (LPARAM)&p);
        if (p.dialog || WaitForSingleObject(thread, 0) == WAIT_OBJECT_0) break;
        Sleep(5);
    } while (GetTickCount64() < deadline);
    int seen = p.dialog != NULL;
    int disabled = seen && !IsWindowEnabled(owner);
    fprintf(stderr, "dialog_seen=%d caller_thread=%lu dialog_thread=%lu owner_disabled=%d\n", seen, (unsigned long)p.thread, (unsigned long)(p.dialog ? GetWindowThreadProcessId(p.dialog, NULL) : 0), disabled);
    fflush(stderr);
    maru_windows_file_dialog_cancel(p.state);
    if (!wait_thread(thread, 10000)) {
        fprintf(stderr, "FAIL native picker did not finish after cancellation; terminating owned probe only\n");
        fflush(stderr); ExitProcess(2);
    }
    pump();
    uint32_t hr = (uint32_t)InterlockedCompareExchange(&p.hr, 0, 0);
    int empty = maru_windows_file_dialog_path(p.state) == NULL;
    int restored = IsWindowEnabled(owner);
    int dialog_gone = !p.dialog || !IsWindow(p.dialog);
    int valid = seen && disabled && restored && empty && dialog_gone && hr == 0x800704c7u;
    printf("{\"valid\":%s,\"mode\":%u,\"dialog_seen\":%s,\"owner_disabled\":%s,\"owner_restored\":%s,\"dialog_gone\":%s,\"path_empty\":%s,\"hr\":\"%08x\",\"pid\":%lu,\"thread\":%lu}\n",
        valid ? "true" : "false", mode, seen ? "true" : "false", disabled ? "true" : "false",
        restored ? "true" : "false", dialog_gone ? "true" : "false", empty ? "true" : "false",
        hr, (unsigned long)GetCurrentProcessId(), (unsigned long)p.thread);
    CloseHandle(thread);
    maru_windows_file_dialog_destroy(p.state);
    DestroyWindow(owner);
    UnregisterClassW(class_name, instance);
    return valid ? 0 : 1;
}
