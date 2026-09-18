import XCTest
@testable import OpenUsage

/// Regression test: reading a Chromium cookie pops a "<Browser> Safe Storage"
/// keychain approval per `security` invocation. Without memoization every
/// refresh that reaches the cookie fallback re-prompts (once per installed
/// browser, per poll). The store must read the keychain once per process and
/// serve the rest from memory, re-reading only after an explicit reset.
private final class CountingKeychain: KeychainAccessing, @unchecked Sendable {
    var reads = 0
    var value: String?
    init(_ value: String? = nil) { self.value = value }
    func readGenericPassword(service: String) throws -> String? {
        reads += 1
        return value
    }
    func writeGenericPassword(service: String, value: String) throws {}
}

final class MuseSessionCookieMemoTests: XCTestCase {
    func testBrowserCookieMemoizesKeychainReads() {
        // Fake an encrypted cookie row everywhere so the code reaches the
        // keychain read; the password is wrong so decryption fails and the
        // outcome is .unreadable — the memo must still hold for call two.
        let keychain = CountingKeychain("wrong-password")
        let sqlite = KeyValueSQLite(values: ["hex(encrypted_value)": "00"])
        // No real files: nil binary blobs (Safari/Firefox absent) and no
        // profiles. Without this the test parses the machine's live
        // Cookies.binarycookies, which must never happen in tests.
        let store = MuseSessionCookieStore(
            sqlite: sqlite,
            keychain: keychain,
            binaryReader: { _ in nil },
            profileNames: { _ in [] })

        XCTAssertEqual(store.loadBrowserCookie(), .unreadable)
        let readsAfterFirst = keychain.reads
        XCTAssertGreaterThan(readsAfterFirst, 0, "first read must reach the keychain")

        XCTAssertEqual(store.loadBrowserCookie(), .unreadable)
        XCTAssertEqual(
            keychain.reads, readsAfterFirst,
            "second read must be memoized: no new keychain approval")

        store.resetBrowserCookieMemo()
        XCTAssertEqual(store.loadBrowserCookie(), .unreadable)
        XCTAssertGreaterThan(
            keychain.reads, readsAfterFirst,
            "reset must allow exactly one fresh keychain read")
    }
}
