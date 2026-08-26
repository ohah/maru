#import <Foundation/Foundation.h>
#import <UserNotifications/UserNotifications.h>
#import "session_host_notification_adapter.h"

// The daemon has one owner thread, but UserNotifications completion handlers run on framework
// queues. This tiny process-local slot bridges that asynchronous result without blocking the PTY
// owner loop. Stable identity is scalar; presentation bytes are copied into NSString before return.
static NSLock *maruNotificationLock;
static NSString *maruInflightIdentifier;
static uint32_t maruInflightResult = MARU_NOTIFICATION_PENDING;
static NSTimeInterval maruInflightStartedUptime = 0;
static uint64_t maruInflightGeneration = 0;
static const NSTimeInterval maruInflightTimeoutSeconds = 10.0;

static NSString *maruRouteIdentifier(uint64_t hid_hi, uint64_t hid_lo,
                                     uint64_t rid_hi, uint64_t rid_lo, uint64_t eid) {
    return [NSString stringWithFormat:@"maru-%016llx%016llx-%016llx%016llx-%llu",
            (unsigned long long)hid_hi, (unsigned long long)hid_lo,
            (unsigned long long)rid_hi, (unsigned long long)rid_lo,
            (unsigned long long)eid];
}

static void maruFinishNotification(NSString *identifier, uint64_t generation, uint32_t result) {
    [maruNotificationLock lock];
    if (maruInflightGeneration == generation &&
        [maruInflightIdentifier isEqualToString:identifier]) maruInflightResult = result;
    [maruNotificationLock unlock];
}

static uint32_t maruSubmitNotification(
    uint64_t hid_hi, uint64_t hid_lo, uint64_t rid_hi, uint64_t rid_lo, uint64_t eid,
    const uint8_t *title, size_t title_len, const uint8_t *body, size_t body_len,
    const uint8_t *label, size_t label_len) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ maruNotificationLock = [[NSLock alloc] init]; });
    if (NSBundle.mainBundle.bundleIdentifier == nil) return MARU_NOTIFICATION_BUNDLE_MISSING;

    NSString *identifier = maruRouteIdentifier(hid_hi, hid_lo, rid_hi, rid_lo, eid);
    [maruNotificationLock lock];
    if (maruInflightIdentifier != nil) {
        if (![maruInflightIdentifier isEqualToString:identifier]) {
            [maruNotificationLock unlock];
            return MARU_NOTIFICATION_TRANSIENT;
        }
        uint32_t result = maruInflightResult;
        if (result == MARU_NOTIFICATION_PENDING &&
            NSProcessInfo.processInfo.systemUptime - maruInflightStartedUptime >= maruInflightTimeoutSeconds) {
            // A framework callback is not allowed to pin the daemon adapter forever. Clearing the
            // process-local slot lets the bounded Zig machine create a genuinely fresh request on
            // its next backoff turn; a late callback is ignored by maruFinishNotification because
            // its identifier no longer owns the slot.
            maruInflightIdentifier = nil;
            maruInflightResult = MARU_NOTIFICATION_PENDING;
            maruInflightStartedUptime = 0;
            [maruNotificationLock unlock];
            return MARU_NOTIFICATION_TRANSIENT;
        }
        if (result != MARU_NOTIFICATION_PENDING) {
            maruInflightIdentifier = nil;
            maruInflightResult = MARU_NOTIFICATION_PENDING;
            maruInflightStartedUptime = 0;
        }
        [maruNotificationLock unlock];
        return result;
    }
    if (maruInflightGeneration == UINT64_MAX) {
        [maruNotificationLock unlock];
        return MARU_NOTIFICATION_TRANSIENT;
    }
    maruInflightGeneration += 1;
    uint64_t attemptGeneration = maruInflightGeneration;
    maruInflightIdentifier = identifier;
    maruInflightResult = MARU_NOTIFICATION_PENDING;
    maruInflightStartedUptime = NSProcessInfo.processInfo.systemUptime;
    [maruNotificationLock unlock];

    NSString *titleString = [[NSString alloc] initWithBytes:title length:title_len encoding:NSUTF8StringEncoding];
    NSString *bodyString = [[NSString alloc] initWithBytes:body length:body_len encoding:NSUTF8StringEncoding];
    NSString *labelString = [[NSString alloc] initWithBytes:label length:label_len encoding:NSUTF8StringEncoding];
    if (titleString == nil || bodyString == nil || labelString == nil) {
        maruFinishNotification(identifier, attemptGeneration, MARU_NOTIFICATION_TRANSIENT);
        return MARU_NOTIFICATION_PENDING;
    }

    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center getNotificationSettingsWithCompletionHandler:^(UNNotificationSettings *settings) {
        if (settings.authorizationStatus == UNAuthorizationStatusDenied) {
            maruFinishNotification(identifier, attemptGeneration, MARU_NOTIFICATION_DENIED);
            return;
        }
        if (settings.authorizationStatus == UNAuthorizationStatusNotDetermined) {
            // Permission prompts belong to the foreground app/settings path. A headless daemon must
            // not manufacture UI; a transient result lets the bounded daemon retry window observe
            // the foreground app's authorization decision without opening its own prompt.
            maruFinishNotification(identifier, attemptGeneration, MARU_NOTIFICATION_TRANSIENT);
            return;
        }
        UNMutableNotificationContent *content = [[UNMutableNotificationContent alloc] init];
        content.title = titleString;
        content.body = bodyString;
        content.subtitle = labelString;
        content.userInfo = @{
            @"hid": [NSString stringWithFormat:@"%016llx%016llx", (unsigned long long)hid_hi, (unsigned long long)hid_lo],
            @"rid": [NSString stringWithFormat:@"%016llx%016llx", (unsigned long long)rid_hi, (unsigned long long)rid_lo],
            @"eid": @(eid),
        };
        UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:identifier content:content trigger:nil];
        [center addNotificationRequest:request withCompletionHandler:^(NSError *error) {
            if (error == nil) {
                maruFinishNotification(identifier, attemptGeneration, MARU_NOTIFICATION_ACCEPTED);
            } else if ([error.domain isEqualToString:UNErrorDomain] && error.code == UNErrorCodeNotificationsNotAllowed) {
                maruFinishNotification(identifier, attemptGeneration, MARU_NOTIFICATION_DENIED);
            } else {
                maruFinishNotification(identifier, attemptGeneration, MARU_NOTIFICATION_TRANSIENT);
            }
        }];
    }];
    return MARU_NOTIFICATION_PENDING;
}

uint32_t maru_session_host_notification_submit(
    uint64_t hid_hi, uint64_t hid_lo, uint64_t rid_hi, uint64_t rid_lo, uint64_t eid,
    const uint8_t *title, size_t title_len, const uint8_t *body, size_t body_len,
    const uint8_t *label, size_t label_len) {
    // `maru __session-host` is a long-lived command-line daemon, not an NSApplication event-loop
    // thread. Bound autoreleased Foundation temporaries per owner tick while ARC/block captures
    // retain the strings required by asynchronous UserNotifications callbacks.
    @autoreleasepool {
        return maruSubmitNotification(
            hid_hi, hid_lo, rid_hi, rid_lo, eid,
            title, title_len, body, body_len, label, label_len);
    }
}

void maru_session_host_notification_expire(
    uint64_t hid_hi, uint64_t hid_lo, uint64_t rid_hi, uint64_t rid_lo, uint64_t eid) {
    @autoreleasepool {
        NSString *identifier = maruRouteIdentifier(hid_hi, hid_lo, rid_hi, rid_lo, eid);
        [maruNotificationLock lock];
        if ([maruInflightIdentifier isEqualToString:identifier]) {
            maruInflightIdentifier = nil;
            maruInflightResult = MARU_NOTIFICATION_PENDING;
            maruInflightStartedUptime = 0;
        }
        [maruNotificationLock unlock];
    }
}
