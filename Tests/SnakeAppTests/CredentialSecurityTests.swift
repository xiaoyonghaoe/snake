import CryptoKit
import Combine
import Foundation
import XCTest
@testable import SnakeApp

private final class MemoryCredentialKeys: CredentialEncryptionKeyProviding, @unchecked Sendable {
    // Each test owns its provider; production tests never access the Keychain.
    var data: Data?
    var creationCount = 0
    var failure: Error?
    func loadKey() throws -> Data? {
        if let failure { throw failure }
        return data
    }
    func createKey() throws -> Data {
        if let failure { throw failure }
        creationCount += 1
        let key = SymmetricKey(size: .bits256).withUnsafeBytes { Data($0) }
        data = key
        return key
    }
}

final class CredentialSecurityTests: XCTestCase {
    private func fixture() throws -> (URL, MemoryCredentialKeys, EncryptedCredentialStore) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("snake-vault-test-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("credentials.json")
        let keys = MemoryCredentialKeys()
        return (url, keys, EncryptedCredentialStore(fileURL: url, keys: keys))
    }

    func testRoundTripRandomNoncePermissionsAndReload() throws {
        let (url, keys, store) = try fixture()
        try store.save("test-only-密码-🔑", account: "test/password")
        let first = try Data(contentsOf: url)
        let text = try XCTUnwrap(String(data: first, encoding: .utf8))
        XCTAssertFalse(text.contains("test-only"))
        XCTAssertFalse(text.contains("test/password"))
        XCTAssertEqual(try store.read(account: "test/password"), "test-only-密码-🔑")
        try store.save("test-only-密码-🔑", account: "test/password")
        XCTAssertNotEqual(first, try Data(contentsOf: url))
        XCTAssertEqual(keys.creationCount, 1)
        let reloaded = EncryptedCredentialStore(fileURL: url, keys: keys)
        XCTAssertEqual(try reloaded.read(account: "test/password"), "test-only-密码-🔑")
        for (path, expected) in [(url, 0o600), (url.deletingLastPathComponent(), 0o700)] {
            let attributes = try FileManager.default.attributesOfItem(atPath: path.path)
            XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, expected)
        }
        try store.save("phrase", account: "test/key-passphrase")
        try store.delete(account: "test/password")
        XCTAssertNil(try reloaded.read(account: "test/password"))
        XCTAssertEqual(try reloaded.read(account: "test/key-passphrase"), "phrase")
    }

    func testStartupPreparationDoesNotCreateEmptyVaultAndMigratesWithoutConnection() throws {
        let (url, keys, store) = try fixture()
        try store.prepare()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        XCTAssertEqual(keys.creationCount, 0)
        try JSONEncoder().encode(["test/password": "startup-fixture"]).write(to: url)
        try store.prepare()
        XCTAssertFalse(String(decoding: try Data(contentsOf: url), as: UTF8.self).contains("startup-fixture"))
        XCTAssertEqual(try store.read(account: "test/password"), "startup-fixture")
    }

    func testLegacyMigrationEncryptsAllAccountsAndIsIdempotent() throws {
        let (url, keys, store) = try fixture()
        let legacy = ["one/password": "one-secret", "two/key-passphrase": "two-secret"]
        try JSONEncoder().encode(legacy).write(to: url)
        XCTAssertEqual(try store.read(account: "one/password"), legacy["one/password"])
        let encrypted = try Data(contentsOf: url)
        XCTAssertFalse(String(decoding: encrypted, as: UTF8.self).contains("one-secret"))
        XCTAssertEqual(try store.read(account: "two/key-passphrase"), legacy["two/key-passphrase"])
        XCTAssertEqual(encrypted, try Data(contentsOf: url))
        XCTAssertEqual(keys.creationCount, 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["credentials.json"])
    }

    func testFailedMigrationAndSaveKeepOriginalAndCleanTemporaryCiphertext() throws {
        let (url, keys, _) = try fixture()
        let legacy = try JSONEncoder().encode(["test/password": "migration-test-only"])
        try legacy.write(to: url)
        let failing = EncryptedCredentialStore(fileURL: url, keys: keys, replace: { _, _ in
            throw CredentialStoreError.cannotCreateFile
        })
        XCTAssertThrowsError(try failing.read(account: "test/password"))
        XCTAssertEqual(try Data(contentsOf: url), legacy)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path), ["credentials.json"])
        let good = EncryptedCredentialStore(fileURL: url, keys: keys)
        _ = try good.read(account: "test/password")
        let encrypted = try Data(contentsOf: url)
        XCTAssertThrowsError(try failing.save("replacement", account: "test/password"))
        XCTAssertEqual(try Data(contentsOf: url), encrypted)
        XCTAssertEqual(try good.read(account: "test/password"), "migration-test-only")
    }

    func testMissingWrongAndInvalidKeysNeverOverwriteOrRegenerate() throws {
        let (url, keys, store) = try fixture()
        try store.save("fixture", account: "test/password")
        let original = try Data(contentsOf: url)
        for key in [nil, Data(repeating: 1, count: 32), Data(repeating: 1, count: 3)] as [Data?] {
            keys.data = key
            XCTAssertThrowsError(try store.read(account: "test/password"))
            XCTAssertThrowsError(try store.save("new", account: "test/password"))
            XCTAssertThrowsError(try store.delete(account: "test/password"))
            XCTAssertEqual(try Data(contentsOf: url), original)
            XCTAssertEqual(keys.creationCount, 1)
        }
    }

    func testTamperingUnsupportedVersionAndMalformedFileFailClosed() throws {
        let (url, keys, store) = try fixture()
        try store.save("fixture", account: "test/password")
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        var tampered = original
        var box = try XCTUnwrap(Data(base64Encoded: original["sealedBox"] as! String))
        box[box.count - 1] ^= 1
        tampered["sealedBox"] = box.base64EncodedString()
        var unsupported = original
        unsupported["version"] = 99
        let inputs = [
            try JSONSerialization.data(withJSONObject: tampered),
            try JSONSerialization.data(withJSONObject: unsupported),
            Data("{broken".utf8),
            Data("{\"version\":\"1\",\"sealedBox\":\"bad\"}".utf8)
        ]
        for input in inputs {
            try input.write(to: url)
            XCTAssertThrowsError(try store.read(account: "test/password"))
            XCTAssertThrowsError(try store.save("new", account: "test/password"))
            XCTAssertEqual(try Data(contentsOf: url), input)
        }
        XCTAssertEqual(keys.creationCount, 1)
    }

    func testKeychainFailurePreservesLegacyFile() throws {
        let (url, keys, store) = try fixture()
        let original = try JSONEncoder().encode(["test/password": "fixture"])
        try original.write(to: url)
        keys.failure = CredentialStoreError.missingKey
        XCTAssertThrowsError(try store.read(account: "test/password"))
        XCTAssertEqual(try Data(contentsOf: url), original)
        XCTAssertEqual(keys.creationCount, 0)
    }
}

@MainActor
private final class FakeCredentialAuthentication: CredentialAuthenticating {
    var completion: CheckedContinuation<Void, Error>?
    var invalidated = false
    func authenticate() async throws {
        try await withCheckedThrowingContinuation { completion = $0 }
    }
    func invalidate() { invalidated = true }
    func resolve(_ error: Error? = nil) {
        let continuation = completion
        completion = nil
        if let error { continuation?.resume(throwing: error) }
        else { continuation?.resume() }
    }
}

@MainActor
final class CredentialRevealTests: XCTestCase {
    private func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<200 {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        XCTFail("Reveal state did not settle")
    }

    func testOnlyReadAfterApprovalAndRequireFreshApprovalAfterHide() async {
        var verifiers: [FakeCredentialAuthentication] = []
        var reads = 0
        let controller = CredentialRevealController(canPresent: { true }, makeAuthentication: {
            let verifier = FakeCredentialAuthentication()
            verifiers.append(verifier)
            return verifier
        }, read: { _ in reads += 1; return Data("test-only-secret".utf8) })
        controller.reveal(account: "test/password")
        await waitUntil { verifiers.first?.completion != nil }
        XCTAssertEqual(reads, 0)
        XCTAssertNil(controller.plaintext)
        verifiers[0].resolve()
        await waitUntil { controller.plaintext != nil }
        XCTAssertEqual(reads, 1)
        controller.hide()
        XCTAssertNil(controller.plaintext)
        controller.reveal(account: "test/password")
        await waitUntil { verifiers.count == 2 && verifiers[1].completion != nil }
        XCTAssertEqual(reads, 1)
        verifiers[1].resolve()
        await waitUntil { controller.plaintext != nil }
        XCTAssertEqual(reads, 1) // Fresh authorization, but keep the existing draft.
        controller.hide()
    }

    func testFailedCancelledAndUnavailableAuthenticationNeverRead() async {
        for error in [CredentialAuthenticationError.failed, .cancelled, .unavailable] {
            let verifier = FakeCredentialAuthentication()
            var reads = 0
            let controller = CredentialRevealController(canPresent: { true }, makeAuthentication: { verifier }, read: { _ in
                reads += 1; return Data("fixture".utf8)
            })
            controller.reveal(account: "test/password")
            await waitUntil { verifier.completion != nil }
            verifier.resolve(error)
            await waitUntil { !controller.isLoading }
            XCTAssertNil(controller.plaintext)
            XCTAssertEqual(reads, 0)
            if case .cancelled = error { XCTAssertNil(controller.errorMessage) }
            else { XCTAssertNotNil(controller.errorMessage) }
        }
    }

    func testDismissDuringAuthenticationDiscardsLateApproval() async {
        let verifier = FakeCredentialAuthentication()
        var reads = 0
        let controller = CredentialRevealController(canPresent: { true }, makeAuthentication: { verifier }, read: { _ in
            reads += 1; return Data("fixture".utf8)
        })
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        controller.hide()
        XCTAssertTrue(verifier.invalidated)
        verifier.resolve()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(controller.plaintext)
        XCTAssertEqual(reads, 0)
    }

    func testTimeoutAndFocusLossHidePlaintext() async {
        let verifier = FakeCredentialAuthentication()
        let controller = CredentialRevealController(timeoutNanoseconds: 20_000_000, canPresent: { true }, makeAuthentication: { verifier }, read: { _ in Data("fixture".utf8) })
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        controller.focusLost() // The system authentication panel may take focus.
        verifier.resolve()
        await waitUntil { controller.plaintext != nil }
        await waitUntil { controller.plaintext == nil }
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        verifier.resolve()
        await waitUntil { controller.plaintext != nil }
        controller.focusLost()
        XCTAssertNil(controller.plaintext)
    }

    func testLateReadCannotRevealInClosedOrDifferentWindow() async {
        let verifier = FakeCredentialAuthentication()
        var readCompletion: CheckedContinuation<Data?, Error>?
        let controller = CredentialRevealController(canPresent: { true }, makeAuthentication: { verifier }, read: { _ in
            try await withCheckedThrowingContinuation { readCompletion = $0 }
        })
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        verifier.resolve()
        await waitUntil { readCompletion != nil }
        controller.hide()
        readCompletion?.resume(returning: Data("fixture".utf8))
        for _ in 0..<10 { await Task.yield() }
        XCTAssertNil(controller.plaintext)
        XCTAssertFalse(controller.isLoading)
    }

    func testInactiveWindowCannotReadEvenAfterAuthentication() async {
        let verifier = FakeCredentialAuthentication()
        var reads = 0
        let controller = CredentialRevealController(focusReturnTimeoutNanoseconds: 20_000_000, canPresent: { false }, makeAuthentication: { verifier }, read: { _ in reads += 1; return nil })
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        verifier.resolve()
        await waitUntil { !controller.isLoading }
        XCTAssertEqual(reads, 0)
        XCTAssertNil(controller.plaintext)
        XCTAssertTrue(controller.errorMessage?.contains("恢复焦点") == true)
    }

    func testMissingAndDamagedCredentialsNeverDisplayPlaintext() async {
        for damaged in [false, true] {
            let verifier = FakeCredentialAuthentication()
            let controller = CredentialRevealController(canPresent: { true }, makeAuthentication: { verifier }, read: { _ in
                if damaged { throw CredentialStoreError.authenticationFailed }
                return nil
            })
            controller.reveal(account: "test/password")
            await waitUntil { verifier.completion != nil }
            verifier.resolve()
            await waitUntil { !controller.isLoading }
            XCTAssertNil(controller.plaintext)
            XCTAssertNotNil(controller.errorMessage)
        }
    }

    func testReplacingRequestIgnoresOldCompletion() async {
        var verifiers: [FakeCredentialAuthentication] = []
        var accountsRead: [String] = []
        let controller = CredentialRevealController(canPresent: { true }, makeAuthentication: {
            let verifier = FakeCredentialAuthentication()
            verifiers.append(verifier)
            return verifier
        }, read: { account in accountsRead.append(account); return Data("new-fixture".utf8) })
        controller.reveal(account: "old/password")
        await waitUntil { verifiers[0].completion != nil }
        controller.reveal(account: "new/password")
        await waitUntil { verifiers.count == 2 && verifiers[1].completion != nil }
        verifiers[1].resolve()
        await waitUntil { controller.plaintext != nil }
        verifiers[0].resolve()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(accountsRead, ["new/password"])
        XCTAssertEqual(controller.plaintext, "new-fixture")
        controller.hide()
    }

    func testAuthenticationWaitsForSystemPanelToReturnFocus() async {
        let verifier = FakeCredentialAuthentication()
        var ready = false
        var reads = 0
        let controller = CredentialRevealController(focusReturnTimeoutNanoseconds: 200_000_000, canPresent: { ready }, makeAuthentication: { verifier }, read: { _ in
            reads += 1
            return Data("focus-fixture".utf8)
        })
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        verifier.resolve()
        await waitUntil { !controller.isAuthenticating }
        XCTAssertTrue(controller.isLoading)
        XCTAssertEqual(reads, 0)
        controller.focusLost()
        ready = true
        await waitUntil { controller.plaintext != nil }
        XCTAssertEqual(controller.plaintext, "focus-fixture")
        XCTAssertEqual(reads, 1)
        controller.hide()
    }

    func testKeychainPanelFocusHandoffDoesNotDiscardDecryptedValue() async {
        let verifier = FakeCredentialAuthentication()
        var ready = true
        var readCompleted = false
        let controller = CredentialRevealController(focusReturnTimeoutNanoseconds: 200_000_000, canPresent: { ready }, makeAuthentication: { verifier }, read: { _ in
            ready = false
            readCompleted = true
            return Data("keychain-fixture".utf8)
        })
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        verifier.resolve()
        await waitUntil { readCompleted }
        XCTAssertNil(controller.plaintext)
        controller.focusLost()
        ready = true
        await waitUntil { controller.plaintext != nil }
        XCTAssertEqual(controller.plaintext, "keychain-fixture")
        controller.hide()
    }

    func testDismantleClearsVisibleSecretWithoutPublishingIntoSwiftUIGraph() async {
        let verifier = FakeCredentialAuthentication()
        let controller = CredentialRevealController(makeAuthentication: { verifier }, read: { _ in Data("teardown-fixture".utf8) })
        let view = CredentialRevealWindowObserver.ObservationView(controller: controller)
        controller.canPresent = { true }
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        verifier.resolve()
        await waitUntil { controller.plaintext != nil }
        var notifications = 0
        let subscription = controller.objectWillChange.sink { notifications += 1 }
        // Exactly the entry point in the supplied crash report, without
        // opening an app window or using real authentication/credentials.
        CredentialRevealWindowObserver.dismantleNSView(view, coordinator: ())
        XCTAssertNil(controller.plaintext)
        XCTAssertFalse(controller.isLoading)
        XCTAssertEqual(notifications, 0)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(notifications, 0)
        withExtendedLifetime(subscription) {}
    }

    func testDismantleDropsLateAuthenticationWithoutPublishing() async {
        let verifier = FakeCredentialAuthentication()
        var reads = 0
        let controller = CredentialRevealController(makeAuthentication: { verifier }, read: { _ in reads += 1; return Data("fixture".utf8) })
        let view = CredentialRevealWindowObserver.ObservationView(controller: controller)
        controller.canPresent = { true }
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        var notifications = 0
        let subscription = controller.objectWillChange.sink { notifications += 1 }
        CredentialRevealWindowObserver.dismantleNSView(view, coordinator: ())
        verifier.resolve()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(notifications, 0)
        XCTAssertNil(controller.plaintext)
        withExtendedLifetime(subscription) {}
    }

    func testLiveViewNotificationsAreDeferredAndCoalesced() async {
        let controller = CredentialRevealController()
        var notifications = 0
        let subscription = controller.objectWillChange.sink { notifications += 1 }
        controller.hide()
        controller.hide()
        XCTAssertEqual(notifications, 0)
        await waitUntil { notifications > 0 }
        XCTAssertEqual(notifications, 1)
        withExtendedLifetime(subscription) {}
    }

    func testOldObserverDismantleCannotDisableReplacementObserver() {
        let controller = CredentialRevealController()
        let oldID = UUID()
        let newID = UUID()
        controller.attachPresentation(id: oldID, canPresent: { false })
        controller.attachPresentation(id: newID, canPresent: { true })
        controller.detachPresentation(id: oldID)
        XCTAssertTrue(controller.canPresent())
        controller.detachPresentation(id: newID)
        XCTAssertFalse(controller.canPresent())
    }

    func testDismissDuringFocusRestorationNeverReadsEvenWhenWindowReturns() async {
        let verifier = FakeCredentialAuthentication()
        var ready = false
        var reads = 0
        let controller = CredentialRevealController(canPresent: { ready }, makeAuthentication: { verifier }, read: { _ in reads += 1; return nil })
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        verifier.resolve()
        await waitUntil { !controller.isAuthenticating }
        controller.hide()
        ready = true
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(reads, 0)
        XCTAssertNil(controller.plaintext)
        XCTAssertFalse(controller.isLoading)
    }

    func testBackfillIsNotAnEditAndMaskingKeepsDraft() async {
        let verifier = FakeCredentialAuthentication()
        let controller = CredentialRevealController(timeoutNanoseconds: 30_000_000, canPresent: { true }, makeAuthentication: { verifier }, read: { _ in Data("saved-fixture".utf8) })
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        verifier.resolve()
        await waitUntil { controller.isRevealed }
        XCTAssertEqual(controller.draft, "saved-fixture")
        XCTAssertNil(controller.valueToSave)
        XCTAssertFalse(controller.hasUserEdits)
        await waitUntil { !controller.isRevealed }
        XCTAssertEqual(controller.draft, "saved-fixture")
        controller.edit("new-fixture")
        controller.focusLost()
        XCTAssertEqual(controller.draft, "new-fixture")
        XCTAssertEqual(controller.valueToSave, "new-fixture")
        controller.reset() // Close form or switch authentication method.
        XCTAssertEqual(controller.draft, "")
        XCTAssertNil(controller.valueToSave)
        XCTAssertFalse(controller.hasUserEdits)
    }

    func testUserDraftRevealsOnlyAfterApprovalWithoutReadingSavedSecret() async {
        let verifier = FakeCredentialAuthentication()
        var reads = 0
        let controller = CredentialRevealController(canPresent: { true }, makeAuthentication: { verifier }, read: { _ in
            reads += 1; return Data("old-fixture".utf8)
        })
        XCTAssertFalse(controller.canReveal(account: nil))
        controller.edit("user-fixture")
        XCTAssertTrue(controller.canReveal(account: nil))
        controller.reveal(account: nil)
        await waitUntil { verifier.completion != nil }
        XCTAssertNil(controller.plaintext)
        verifier.resolve()
        await waitUntil { controller.isRevealed }
        XCTAssertEqual(controller.plaintext, "user-fixture")
        XCTAssertEqual(reads, 0)
        XCTAssertEqual(controller.valueToSave, "user-fixture")
        controller.edit("")
        controller.hide()
        XCTAssertNil(controller.valueToSave)
        XCTAssertFalse(controller.canReveal(account: "test/password"))
        controller.reset()
    }

    func testTypingDuringReadWinsOverBackfillAndCancelKeepsDraftMasked() async {
        let verifier = FakeCredentialAuthentication()
        var completion: CheckedContinuation<Data?, Error>?
        let controller = CredentialRevealController(canPresent: { true }, makeAuthentication: { verifier }, read: { _ in
            try await withCheckedThrowingContinuation { completion = $0 }
        })
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        verifier.resolve()
        await waitUntil { completion != nil }
        controller.edit("typed-during-read")
        completion?.resume(returning: Data("old-fixture".utf8))
        await waitUntil { controller.isRevealed }
        XCTAssertEqual(controller.draft, "typed-during-read")
        XCTAssertEqual(controller.valueToSave, "typed-during-read")
        controller.hide()
        controller.reveal(account: "test/password")
        await waitUntil { verifier.completion != nil }
        verifier.resolve(CredentialAuthenticationError.cancelled)
        await waitUntil { !controller.isLoading }
        XCTAssertNil(controller.plaintext)
        XCTAssertEqual(controller.draft, "typed-during-read")
        controller.reset()
    }
}
