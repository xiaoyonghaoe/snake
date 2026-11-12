import AppKit
import SwiftUI
import XCTest
@testable import SnakeApp

/// Probing showed an explicit content type wins over the system's guess:
/// `.password` brings up the Passwords popup and an unknown type shows none.
@MainActor
final class PasswordAutoFillTests: XCTestCase {
    private func contentTypes(autoFill: Bool?) throws -> [String?] {
        let suite = "snake.tests.autofill.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if let autoFill { defaults.set(autoFill, forKey: PasswordAutoFill.defaultsKey) }

        let view = VStack {
            CredentialInputView(account: nil, isPassphrase: false, reveal: CredentialRevealController.sharingGrace())
            SecureField("", text: .constant("")).snakePasswordAutoFill()
        }
        .padding()
        .defaultAppStorage(defaults)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: view)
        window.layoutIfNeeded()
        func secureFields(_ view: NSView) -> [NSSecureTextField] {
            ((view as? NSSecureTextField).map { [$0] } ?? []) + view.subviews.flatMap(secureFields)
        }
        let fields = secureFields(try XCTUnwrap(window.contentView))
        XCTAssertEqual(fields.count, 2)
        return fields.map { $0.contentType?.rawValue }
    }

    func testAutoFillIsLeftToTheSystemByDefault() throws {
        XCTAssertEqual(try contentTypes(autoFill: nil), [nil, nil])
        XCTAssertEqual(try contentTypes(autoFill: true), [nil, nil])
    }

    func testTurningAutoFillOffMarksEveryPasswordField() throws {
        let suppressed = PasswordAutoFill.suppressedContentType.rawValue
        XCTAssertEqual(try contentTypes(autoFill: false), [suppressed, suppressed])
    }
}
