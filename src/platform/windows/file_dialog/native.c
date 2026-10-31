/* Windows-only COM adapter. All IFileDialog calls stay on the worker STA.
 * A private message-only window receives asynchronous cancellation; bare thread
 * messages were not sufficient inside the observed native modal loop.
 * https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-sendnotifymessagew
 * https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features#message-only-windows
 * https://learn.microsoft.com/en-us/windows/win32/api/shobjidl_core/nf-shobjidl_core-ifiledialog-close
 */
#define COBJMACROS
#ifndef UNICODE
#define UNICODE 1
#endif
#ifndef _UNICODE
#define _UNICODE 1
#endif
#include <windows.h>
#include <initguid.h>
#include <shobjidl.h>
#include <oleidl.h>
#include <stdint.h>
#include "native.h"

struct MaruFileDialog {
    volatile LONG canceled;
    SRWLOCK cancel_lock;
    HWND cancel_window;
    ULONGLONG cookie;
    volatile LONG used;
    IFileDialog *dialog; /* STA-only, never accessed by cancel. */
    PWSTR path;             /* Published only after run has returned. */
    int closing;           /* Reentrant modal callbacks must not recurse Close. */
};
static _Thread_local MaruFileDialog *current_dialog;
static const HRESULT canceled_hr = (HRESULT)0x800704c7L;
/* Public IOleWindow IID (00000114-0000-0000-C000-000000000046).
 * Keep the ABI identifier local rather than adding a UUID import library. */
static const IID ole_window_iid = {0x00000114, 0, 0, {0xc0, 0, 0, 0, 0, 0, 0, 0x46}};

static INIT_ONCE cancel_class_once = INIT_ONCE_STATIC_INIT;
static const WCHAR cancel_class_name[] = L"MaruNativeFileDialogWake";
static UINT cancel_message;
_Alignas(8) static volatile LONG64 next_cookie;

/* IFileDialog::Close returned S_OK without settling Show in the native probe.
 * A queued close on this object's IOleWindow completed normal cancellation.
 * Only Show returning retires the request; retry while initialization has not
 * yet produced a visible window. Never enumerate or target unrelated windows.
 * IOleWindow access is part of the Common Item Dialog contract:
 * https://learn.microsoft.com/en-us/windows/win32/shell/common-file-dialog */
static void cancel_shown_dialog(MaruFileDialog *state) {
    if (state && state->dialog && !state->closing &&
        InterlockedCompareExchange(&state->canceled, 0, 0)) {
        state->closing = 1;
        IOleWindow *window = NULL;
        HRESULT hr = IFileDialog_QueryInterface(state->dialog, &ole_window_iid, (void **)&window);
        if (SUCCEEDED(hr)) {
            HWND hwnd = NULL;
            hr = IOleWindow_GetWindow(window, &hwnd);
            if (SUCCEEDED(hr) && hwnd && IsWindowVisible(hwnd)) {
                DWORD pid = 0;
                DWORD tid = GetWindowThreadProcessId(hwnd, &pid);
                /* This callback runs on the dialog STA. No other thread can
                 * destroy/reuse its HWND between validation and this request. */
                if (pid == GetCurrentProcessId() && tid == GetCurrentThreadId())
                    PostMessageW(hwnd, WM_CLOSE, 0, 0);
            }
            IOleWindow_Release(window);
        } else {
            (void)IFileDialog_Close(state->dialog, canceled_hr);
        }
        state->closing = 0;
    }
}
static LRESULT CALLBACK cancellation_window(HWND hwnd, UINT message, WPARAM wparam, LPARAM lparam) {
    MaruFileDialog *state = (MaruFileDialog *)GetWindowLongPtrW(hwnd, GWLP_USERDATA);
    if (message == WM_NCCREATE) {
        const CREATESTRUCTW *created = (const CREATESTRUCTW *)lparam;
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, (LONG_PTR)created->lpCreateParams);
        return TRUE;
    }
    if (message == cancel_message) {
        ULONGLONG cookie = (ULONGLONG)(uint32_t)wparam | ((ULONGLONG)(uint32_t)lparam << 32);
        if (state && cookie == state->cookie &&
            InterlockedCompareExchange(&state->canceled, 0, 0)) {
            SetTimer(hwnd, 1, 25, NULL);
            cancel_shown_dialog(state);
        }
        return 0;
    }
    if (message == WM_TIMER && wparam == 1) {
        cancel_shown_dialog(state);
        return 0;
    }
    if (message == WM_NCDESTROY) {
        KillTimer(hwnd, 1);
        SetWindowLongPtrW(hwnd, GWLP_USERDATA, 0);
    }
    return DefWindowProcW(hwnd, message, wparam, lparam);
}
static BOOL CALLBACK register_cancel_class(PINIT_ONCE once, PVOID argument, PVOID *context) {
    (void)once; (void)argument; (void)context;
    cancel_message = RegisterWindowMessageW(L"Maru.Native.FileDialog.Cancel.v1");
    if (!cancel_message) return FALSE;
    WNDCLASSW cls = {0};
    cls.lpfnWndProc = cancellation_window;
    cls.hInstance = GetModuleHandleW(NULL);
    cls.lpszClassName = cancel_class_name;
    if (RegisterClassW(&cls)) return TRUE;
    if (GetLastError() == ERROR_CLASS_ALREADY_EXISTS) {
        WNDCLASSW existing;
        if (GetClassInfoW(cls.hInstance, cancel_class_name, &existing) &&
            existing.lpfnWndProc == cancellation_window) return TRUE;
        SetLastError(ERROR_CLASS_ALREADY_EXISTS);
    }
    return FALSE;
}


static HRESULT last_error_hr(void) {
    DWORD error = GetLastError();
    return HRESULT_FROM_WIN32(error ? error : ERROR_GEN_FAILURE);
}
static HRESULT configure_dialog(IFileDialog *dialog, uint32_t mode,
                                const uint16_t *initial_directory,
                                const uint16_t *title, uint32_t *out_options) {
    if (mode != 1 && mode != 2) return E_INVALIDARG;
    FILEOPENDIALOGOPTIONS options = 0;
    HRESULT hr = IFileDialog_GetOptions(dialog, &options);
    if (FAILED(hr)) return hr;
    options |= FOS_FORCEFILESYSTEM | FOS_NOCHANGEDIR | FOS_PATHMUSTEXIST |
               FOS_FILEMUSTEXIST | FOS_DONTADDTORECENT;
    if (mode == 2) options |= FOS_PICKFOLDERS;
    hr = IFileDialog_SetOptions(dialog, options);
    if (FAILED(hr)) return hr;
    if (title) {
        hr = IFileDialog_SetTitle(dialog, (LPCWSTR)title);
        if (FAILED(hr)) return hr;
    }
    if (initial_directory) {
        IShellItem *folder = NULL;
        hr = SHCreateItemFromParsingName((LPCWSTR)initial_directory, NULL,
                                        &IID_IShellItem, (void **)&folder);
        if (FAILED(hr)) return hr;
        hr = IFileDialog_SetFolder(dialog, folder);
        IShellItem_Release(folder);
        if (FAILED(hr)) return hr;
    }
    if (out_options) {
        hr = IFileDialog_GetOptions(dialog, &options);
        if (FAILED(hr)) return hr;
        *out_options = (uint32_t)options;
    }
    return S_OK;
}
MaruFileDialog *maru_windows_file_dialog_create(void) {
    MaruFileDialog *state = (MaruFileDialog *)HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY,
                                                     sizeof(MaruFileDialog));
    if (state) {
        InitializeSRWLock(&state->cancel_lock);
        state->cookie = (ULONGLONG)InterlockedIncrement64(&next_cookie);
    }
    return state;
}
void maru_windows_file_dialog_cancel(MaruFileDialog *state) {
    if (!state) return;
    InterlockedExchange(&state->canceled, 1);
    /* Resolve the exact window under a lifetime lock. Cleanup cannot destroy it
     * until this non-blocking cross-thread notification has been submitted.
     * The nonce rejects notifications for an earlier request after HWND reuse. */
    AcquireSRWLockShared(&state->cancel_lock);
    if (state->cancel_window) {
        SendNotifyMessageW(state->cancel_window, cancel_message,
                          (WPARAM)(uint32_t)state->cookie,
                          (LPARAM)(uint32_t)(state->cookie >> 32));
    }
    ReleaseSRWLockShared(&state->cancel_lock);
}
int32_t maru_windows_file_dialog_run(MaruFileDialog *state, void *parent,
    uint32_t mode, const uint16_t *initial_directory, const uint16_t *title) {
    if (!state) return (int32_t)E_POINTER;
    if (InterlockedCompareExchange(&state->used, 1, 0)) return (int32_t)E_UNEXPECTED;
    if (InterlockedCompareExchange(&state->canceled, 0, 0)) return (int32_t)canceled_hr;
    if (mode != 1 && mode != 2) return (int32_t)E_INVALIDARG;
    if (current_dialog) return (int32_t)E_UNEXPECTED;
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(hr)) return (int32_t)hr;
    HWND wake = NULL;
    if (!InitOnceExecuteOnce(&cancel_class_once, register_cancel_class, NULL, NULL)) {
        hr = last_error_hr(); goto cleanup;
    }
    current_dialog = state;
    wake = CreateWindowExW(0, cancel_class_name, L"", 0, 0, 0, 0, 0,
                           HWND_MESSAGE, NULL, GetModuleHandleW(NULL), state);
    if (!wake) { hr = last_error_hr(); goto cleanup; }
    AcquireSRWLockExclusive(&state->cancel_lock);
    state->cancel_window = wake;
    ReleaseSRWLockExclusive(&state->cancel_lock);
    hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER,
                         &IID_IFileDialog, (void **)&state->dialog);
    if (FAILED(hr)) goto cleanup;
    hr = configure_dialog(state->dialog, mode, initial_directory, title, NULL);
    if (FAILED(hr)) goto cleanup;
    if (InterlockedCompareExchange(&state->canceled, 0, 0)) {
        hr = canceled_hr;
    } else {
        hr = IFileDialog_Show(state->dialog, (HWND)parent);
    }
    if (SUCCEEDED(hr)) {
        IShellItem *item = NULL;
        hr = IFileDialog_GetResult(state->dialog, &item);
        if (SUCCEEDED(hr)) {
            hr = IShellItem_GetDisplayName(item, SIGDN_FILESYSPATH, &state->path);
            IShellItem_Release(item);
        }
    }
    if (InterlockedCompareExchange(&state->canceled, 0, 0)) hr = canceled_hr;
cleanup:
    AcquireSRWLockExclusive(&state->cancel_lock);
    state->cancel_window = NULL;
    ReleaseSRWLockExclusive(&state->cancel_lock);
    if (wake) { KillTimer(wake, 1); DestroyWindow(wake); }
    current_dialog = NULL;
    if (state->dialog) { IFileDialog_Release(state->dialog); state->dialog = NULL; }
    if (FAILED(hr) && state->path) { CoTaskMemFree(state->path); state->path = NULL; }
    CoUninitialize();
    return (int32_t)hr;
}
const uint16_t *maru_windows_file_dialog_path(const MaruFileDialog *state) {
    return state ? (const uint16_t *)state->path : NULL;
}
void maru_windows_file_dialog_destroy(MaruFileDialog *state) {
    if (!state) return;
    if (state->path) CoTaskMemFree(state->path);
    HeapFree(GetProcessHeap(), 0, state);
}
int32_t maru_windows_file_dialog_probe_options(uint32_t mode, uint32_t *out_options) {
    if (!out_options) return (int32_t)E_POINTER;
    *out_options = 0;
    if (mode != 1 && mode != 2) return (int32_t)E_INVALIDARG;
    HRESULT hr = CoInitializeEx(NULL, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    if (FAILED(hr)) return (int32_t)hr;
    IFileDialog *dialog = NULL;
    hr = CoCreateInstance(&CLSID_FileOpenDialog, NULL, CLSCTX_INPROC_SERVER,
                         &IID_IFileDialog, (void **)&dialog);
    if (SUCCEEDED(hr)) {
        hr = configure_dialog(dialog, mode, NULL, NULL, out_options);
        IFileDialog_Release(dialog);
    }
    CoUninitialize();
    return (int32_t)hr;
}
