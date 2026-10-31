#ifndef MARU_WINDOWS_FILE_DIALOG_NATIVE_H
#define MARU_WINDOWS_FILE_DIALOG_NATIVE_H
#include <stdint.h>
typedef struct MaruFileDialog MaruFileDialog;
/* Modes are native adapter inputs: 1=file, 2=directory. One run per handle.
 * cancel may run concurrently; destroy requires run to have returned. */
MaruFileDialog *maru_windows_file_dialog_create(void);
void maru_windows_file_dialog_cancel(MaruFileDialog *state);
int32_t maru_windows_file_dialog_run(MaruFileDialog *state, void *parent,
    uint32_t mode, const uint16_t *initial_directory, const uint16_t *title);
const uint16_t *maru_windows_file_dialog_path(const MaruFileDialog *state);
void maru_windows_file_dialog_destroy(MaruFileDialog *state);
/* Runs the same COM configuration without showing a dialog, for native checks. */
int32_t maru_windows_file_dialog_probe_options(uint32_t mode, uint32_t *out_options);
#endif
