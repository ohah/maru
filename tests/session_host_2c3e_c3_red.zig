const std = @import("std");

fn red() !void {
    return error.C3CadenceNotImplemented;
}

test "2c3e C3 미구현 socket cadence는 완성 response 직후 EOF를 commit 다음 turn terminal로 보존한다" {
    try red();
}

test "2c3e C3 미구현 socket cadence는 partial header 뒤 EOF에서 decoder 없이 source-zero로 닫힌다" {
    try red();
}

test "2c3e C3 미구현 socket cadence는 partial payload 뒤 EOF에서 decoder 없이 source-zero로 닫힌다" {
    try red();
}

test "2c3e C3 미구현 socket cadence는 response 뒤 revoke를 다음 turn에 exact once settle한다" {
    try red();
}

test "2c3e C3 미구현 socket cadence는 response 뒤 metadata event를 다음 turn에 exact once settle한다" {
    try red();
}

test "2c3e C3 미구현 socket cadence는 response 뒤 snapshot을 다음 turn에 byte-exact 보존한다" {
    try red();
}

test "2c3e C3 미구현 socket cadence는 response 전 malformed frame을 decoder 없이 terminalize한다" {
    try red();
}

test "2c3e C3 미구현 socket cadence는 unknown kind와 wrong correlation을 decoder 없이 terminalize한다" {
    try red();
}

test "2c3e C3 미구현 socket cadence는 unread revoke를 queued TX보다 먼저 처리한다" {
    try red();
}
