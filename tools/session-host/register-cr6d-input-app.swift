// Register only the isolated CR6d app. A bundle under /tmp can be launched by
// path while TCC still cannot resolve its bundle ID through LaunchServices.
import AppKit
import CoreServices
import Foundation

let expectedID = "dev.maru.apphost.cr6d-input-smoke"
guard CommandLine.arguments.count == 2 else {
    fputs("usage: register-cr6d-input-app.swift <test-app>\n", stderr)
    exit(2)
}
let appURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
    .resolvingSymlinksInPath().standardizedFileURL
guard Bundle(url: appURL)?.bundleIdentifier == expectedID else {
    fputs("CR6d registration identity drifted\n", stderr)
    exit(2)
}
guard LSRegisterURL(appURL as CFURL, true) == noErr else {
    fputs("CR6d LaunchServices registration failed\n", stderr)
    exit(2)
}
guard let registered = NSWorkspace.shared.urlForApplication(withBundleIdentifier: expectedID),
      registered.resolvingSymlinksInPath().standardizedFileURL == appURL else {
    fputs("CR6d LaunchServices ID does not resolve to the staged app\n", stderr)
    exit(2)
}
