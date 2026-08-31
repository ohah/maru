//! Frozen product bytes에서 파생한 Apple 서명·공증 관측의 의미를 검증한다.
//! 실제 command 실행이나 DMG mount를 흉내 내지 않고, executable adapter가 받은 bounded capture를
//! caller 제작 `Signing` 없이 manifest 타입으로 수렴시키는 component 경계만 고정한다.

const std = @import("std");
const product = @import("release_adapter_apple_product");

const executable_sha = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
const plist =
    \\{"CFBundleIdentifier":"dev.maru.apphost","CFBundleShortVersionString":"1.2.3","CFBundleVersion":"1","additive":true}
;
const detail =
    \\Executable=/Applications/Maru.app/Contents/MacOS/maru-macos-app
    \\Identifier=dev.maru.apphost
    \\TeamIdentifier=ABCDEFGHIJ
;
const requirement =
    \\Executable=/Applications/Maru.app/Contents/MacOS/maru-macos-app
    \\designated => identifier "dev.maru.apphost" and anchor apple generic and certificate leaf[subject.OU] = "ABCDEFGHIJ"
;

fn captures() product.Captures {
    return .{
        .executable_sha256 = executable_sha,
        .plist_json = plist,
        .codesign_detail = detail,
        .designated_requirement = requirement,
        .architectures = "arm64 x86_64\n",
        .strict_signature_verified = true,
        .app_staple_verified = true,
        .dmg_staple_verified = true,
        .dmg_gatekeeper_verified = true,
    };
}

test "creates manifest signing only from fully verified Apple product observations" {
    var observed = try product.parseAndBind(std.testing.allocator, captures(), "1.2.3");
    defer observed.deinit(std.testing.allocator);
    const signing = observed.signing();
    try std.testing.expectEqualStrings(executable_sha, observed.executableSha256());
    try std.testing.expectEqualStrings(product.product_bundle_id, signing.bundle_id);
    try std.testing.expectEqualStrings("1.2.3", signing.bundle_short_version);
    try std.testing.expectEqualStrings(product.product_bundle_version, signing.bundle_version);
    try std.testing.expectEqualStrings("ABCDEFGHIJ", signing.team_id);
    try std.testing.expectEqual(@as(usize, 2), signing.architectures.len);
    try std.testing.expectEqualStrings("arm64", signing.architectures[0]);
    try std.testing.expectEqualStrings("x86_64", signing.architectures[1]);
    try std.testing.expectEqualStrings("accepted", signing.notarization);
    try std.testing.expect(signing.stapled);
    try std.testing.expectEqual(@as(usize, 64), signing.designated_requirement_sha256.len);
}

test "rejects missing duplicate and foreign codesign identity" {
    var input = captures();
    input.codesign_detail = "Identifier=dev.maru.apphost\n";
    try std.testing.expectError(error.InvalidCodesignDetail, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.codesign_detail = "Identifier=dev.maru.apphost\nIdentifier=dev.maru.apphost\nTeamIdentifier=ABCDEFGHIJ\n";
    try std.testing.expectError(error.InvalidCodesignDetail, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input = captures();
    input.codesign_detail = "Identifier=dev.attacker.app\nTeamIdentifier=ABCDEFGHIJ\n";
    try std.testing.expectError(error.IdentityMismatch, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.plist_json = "{\"CFBundleIdentifier\":\"dev.attacker.app\",\"CFBundleShortVersionString\":\"1.2.3\",\"CFBundleVersion\":\"1\"}";
    try std.testing.expectError(error.IdentityMismatch, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
}

test "rejects non Apple duplicate and foreign-team designated requirements" {
    var input = captures();
    input.designated_requirement = "designated => identifier \"dev.maru.apphost\" and cdhash H\"0011\"\n";
    try std.testing.expectError(error.InvalidRequirement, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.designated_requirement = "designated => identifier \"dev.maru.apphost\" and info[subject] = \"anchor apple generic\" and certificate leaf[subject.OU] = \"ABCDEFGHIJ\"\n";
    try std.testing.expectError(error.InvalidRequirement, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.designated_requirement = "designated => notidentifier \"dev.maru.apphost\" and notanchor apple generic and certificate leaf[subject.OU] = \"ABCDEFGHIJ\"\n";
    try std.testing.expectError(error.InvalidRequirement, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.designated_requirement = "designated => identifier \"dev.maru.apphost\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDEFGHIJ\" and info[x] = \"unterminated\n";
    try std.testing.expectError(error.InvalidRequirement, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.designated_requirement = requirement ++ "\ndesignated => identifier \"dev.maru.apphost\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDEFGHIJ\"\n";
    try std.testing.expectError(error.InvalidRequirement, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.designated_requirement = "designated => identifier \"dev.maru.apphost\" and identifier \"dev.maru.apphost\" and anchor apple generic and certificate leaf[subject.OU] = \"ABCDEFGHIJ\"\n";
    try std.testing.expectError(error.InvalidRequirement, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.designated_requirement = "designated => identifier \"dev.maru.apphost\" or anchor apple generic and certificate leaf[subject.OU] = \"ABCDEFGHIJ\"\n";
    try std.testing.expectError(error.InvalidRequirement, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.designated_requirement = "designated => identifier \"dev.maru.apphost\" and not anchor apple generic and certificate leaf[subject.OU] = \"ABCDEFGHIJ\"\n";
    try std.testing.expectError(error.InvalidRequirement, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.designated_requirement = "designated => identifier \"dev.maru.apphost\" and ! anchor apple generic and certificate leaf[subject.OU] = \"ABCDEFGHIJ\"\n";
    try std.testing.expectError(error.InvalidRequirement, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.designated_requirement = "designated => identifier \"dev.maru.apphost\" and anchor apple generic and certificate leaf[subject.OU] = \"ZZZZZZZZZZ\"\n";
    try std.testing.expectError(error.IdentityMismatch, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
}

test "rejects plist wire errors and release identity mismatch" {
    var input = captures();
    input.plist_json = "{\"CFBundleIdentifier\":\"dev.maru.apphost\",\"CFBundleIdentifier\":\"dev.maru.apphost\",\"CFBundleShortVersionString\":\"1.2.3\",\"CFBundleVersion\":\"1\"}";
    try std.testing.expectError(error.InvalidPlist, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input = captures();
    try std.testing.expectError(error.VersionMismatch, product.parseAndBind(std.testing.allocator, input, "1.2.4"));
    input.plist_json = "{\"CFBundleIdentifier\":\"dev.maru.apphost\",\"CFBundleShortVersionString\":1,\"CFBundleVersion\":\"1\"}";
    try std.testing.expectError(error.InvalidPlist, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input.plist_json = "{\"CFBundleIdentifier\":\"dev.maru.apphost\",\"CFBundleShortVersionString\":\"1.2.3\",\"CFBundleVersion\":\"2\"}";
    try std.testing.expectError(error.VersionMismatch, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
}

test "requires exact sorted universal architectures and every product receipt" {
    var input = captures();
    input.architectures = "x86_64 arm64";
    try std.testing.expectError(error.InvalidArchitectures, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input = captures();
    input.dmg_gatekeeper_verified = false;
    try std.testing.expectError(error.UnverifiedProduct, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input = captures();
    input.strict_signature_verified = false;
    try std.testing.expectError(error.UnverifiedProduct, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
}

test "rejects noncanonical digest control scalar and capture cap before allocation" {
    var input = captures();
    input.executable_sha256 = "ABC";
    try std.testing.expectError(error.InvalidDigest, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input = captures();
    input.codesign_detail = "Identifier=dev.maru.apphost\nTeamIdentifier=ABCDE\nFGHIJ\n";
    try std.testing.expectError(error.InvalidCodesignDetail, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
    input = captures();
    input.plist_json = " " ** (product.max_capture_bytes + 1);
    try std.testing.expectError(error.CaptureTooLarge, product.parseAndBind(std.testing.allocator, input, "1.2.3"));
}

test "successful Apple product observation unwinds every allocation fail index" {
    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        product.parseAndBindForTest,
        .{ captures(), "1.2.3" },
    );
}
