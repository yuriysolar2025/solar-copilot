import Foundation

let failures = MacDesktopToolPolicy.selfTest()
if failures.isEmpty {
    print("PASS desktop-policy=16")
} else {
    fputs("FAIL: \(failures.joined(separator: "; "))\n", stderr)
    exit(1)
}
