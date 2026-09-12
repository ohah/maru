#!/bin/sh
set -eu

source_file=$1
binary=$2

grep -Fq 'kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: false' "$source_file"
grep -Fq 'CGSessionCopyCurrentDictionary()' "$source_file"
grep -Fq 'kCGSessionOnConsoleKey' "$source_file"
grep -Fq 'kCGSessionLoginDoneKey' "$source_file"
grep -Fq 'AXUIElementPerformAction(target, kAXPressAction as CFString)' "$source_file"
grep -Fq 'clicked > observed' "$source_file"
grep -Fq 'clicked < deadline' "$source_file"
grep -Fq 'com.apple.notificationcenterui' "$source_file"
! grep -Fq 'UNNotificationResponse' "$source_file"
! grep -Fq 'requestAuthorization' "$source_file"
! grep -Fq 'CGSSessionScreenIsLocked' "$source_file"
! grep -Fq 'removeAllDeliveredNotifications' "$source_file"

if "$binary"; then
    exit 1
else
    test "$?" -eq 64
fi

if "$binary" click invalid 1; then
    exit 1
else
    test "$?" -eq 64
fi
