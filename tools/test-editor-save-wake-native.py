#!/usr/bin/env python3
"""제품 Dispatch 어댑터를 실제 macOS main run loop와 worker join으로 검증한다."""
from pathlib import Path
import subprocess
import tempfile
import sys

if sys.platform != "darwin":
    raise SystemExit("macOS is required")
root = Path(__file__).resolve().parents[1]
output = Path(tempfile.mkdtemp(prefix="maru-save-wake-native-"))
source = output / "main.c"
program = r'''
#include <assert.h>
#include <CoreFoundation/CoreFoundation.h>
#include <pthread.h>
#include <stdatomic.h>
#include <stdio.h>
#include <stdlib.h>
#include "MAIN_QUEUE_INCLUDE"
static pthread_t producer;
static atomic_int done;
static int deliveries;
static void deliver(void *ctx) {
    assert(ctx == NULL);
    assert(pthread_main_np());
    // 실제 Service.take처럼 callback에서 게시 스레드를 join한다.
    if (deliveries == 0) assert(pthread_join(producer, NULL) == 0);
    assert(atomic_load(&done) == 1);
    if (++deliveries == 1000) { puts("MAIN_QUEUE native: async delivery, main ownership, worker join, 1000 callbacks passed"); exit(0); }
}
static void *post(void *ctx) {
    (void)ctx;
    atomic_store(&done, 1);
    for (int i = 0; i < 1000; ++i) maru_macos_dispatch_main(deliver);
    return NULL;
}
int main(void) {
    assert(pthread_create(&producer, NULL, post, NULL) == 0);
    CFRunLoopRun();
}
'''
source.write_text(program.replace("MAIN_QUEUE_INCLUDE", str(root / "src/platform/macos/main_queue.c.inc")))
binary = output / "native"
subprocess.run(["clang", "-Wall", "-Wextra", "-Werror", str(source), "-framework", "CoreFoundation", "-o", str(binary)], check=True, timeout=60)
result = subprocess.run([str(binary)], check=True, capture_output=True, text=True, timeout=10)
(output / "result.log").write_text(result.stdout + result.stderr)
print(result.stdout.strip())
print(output)
