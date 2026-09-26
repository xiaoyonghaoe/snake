import AppKit
import Combine
import LocalAuthentication
import SwiftUI

enum CredentialAuthenticationError: Error {
    case cancelled, unavailable, failed, windowNotReady
}

@MainActor
protocol CredentialAuthenticating: AnyObject {
    func authenticate() async throws
    func invalidate()
}

@MainActor
final class DeviceOwnerCredentialAuthentication: CredentialAuthenticating {
    private let context = LAContext()

    func authenticate() async throws {
        context.localizedCancelTitle = L10n.text("取消")
        context.touchIDAuthenticationAllowableReuseDuration = 0
        var error: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthentication, error: &error) else {
            throw CredentialAuthenticationError.unavailable
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            context.evaluatePolicy(
                .deviceOwnerAuthentication,
                localizedReason: L10n.text("验证身份以查看 Snake 中已保存的密码或私钥口令")
            ) { approved, error in
                if approved {
                    continuation.resume()
                } else if let error = error as? LAError,
                          [.userCancel, .appCancel, .systemCancel].contains(error.code) {
                    continuation.resume(throwing: CredentialAuthenticationError.cancelled)
                } else {
                    continuation.resume(throwing: CredentialAuthenticationError.failed)
                }
            }
        }
    }

    func invalidate() { context.invalidate() }
}

/// A form-lifetime draft distinguishes authenticated backfill from user edits.
/// Hiding only masks the draft; reset/teardown erases it without graph re-entry.
@MainActor
final class CredentialRevealController: @preconcurrency ObservableObject {
    // AppKit teardown may run inside SwiftUI's graph destruction. Secrets must
    // clear synchronously there, but notifying SwiftUI synchronously re-enters
    // that graph and traps in swift_beginAccess. Keep storage separate from the
    // coalesced, next-main-queue notification used by the live view.
    let objectWillChange = ObservableObjectPublisher()
    private(set) var draft = ""
    private(set) var hasUserEdits = false
    private var hasLoadedCredential = false
    private(set) var isRevealed = false
    var plaintext: String? { isRevealed ? draft : nil }
    var valueToSave: String? { hasUserEdits && !draft.isEmpty ? draft : nil }
    private(set) var isAuthenticating = false
    private(set) var isLoading = false
    private(set) var errorMessage: String?
    var canPresent: () -> Bool
    private let makeAuthentication: () -> any CredentialAuthenticating
    private let read: (String) async throws -> Data?
    private let timeoutNanoseconds: UInt64
    private let focusReturnTimeoutNanoseconds: UInt64
    private var authentication: (any CredentialAuthenticating)?
    private var requestID = UUID()
    private var requestTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var presentationID: UUID?
    private var updatesEnabled = true
    private var pendingUpdateID: UUID?

    init(
        timeoutNanoseconds: UInt64 = 30_000_000_000,
        focusReturnTimeoutNanoseconds: UInt64 = 3_000_000_000,
        canPresent: @escaping () -> Bool = { false },
        makeAuthentication: @escaping () -> any CredentialAuthenticating = { DeviceOwnerCredentialAuthentication() },
        read: @escaping (String) async throws -> Data? = { account in
            try await Task.detached(priority: .userInitiated) { try CredentialStore.readData(account: account) }.value
        }
    ) {
        self.timeoutNanoseconds = timeoutNanoseconds
        self.focusReturnTimeoutNanoseconds = focusReturnTimeoutNanoseconds
        self.canPresent = canPresent
        self.makeAuthentication = makeAuthentication
        self.read = read
    }

    func edit(_ value: String) {
        draft = value
        hasUserEdits = true
        scheduleViewUpdate()
    }

    func canReveal(account: String?) -> Bool {
        !isLoading && (!draft.isEmpty || (!hasUserEdits && !hasLoadedCredential && account != nil))
    }

    func reveal(account: String?) {
        hide()
        let id = requestID
        let verifier = makeAuthentication()
        authentication = verifier
        isAuthenticating = true
        isLoading = true
        requestTask = Task { [weak self] in
            do {
                // Settings and profile sheets may still be moving to the key
                // window when their button becomes clickable. Starting LA in
                // that gap can result in no system prompt at all.
                try await self?.waitForPresentation(requestID: id)
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                try await verifier.authenticate()
                guard self.requestID == id, !Task.isCancelled else { return }
                verifier.invalidate()
                self.authentication = nil
                self.isAuthenticating = false
                self.scheduleViewUpdate()
                // LA's completion can precede the native panel's dismissal and
                // didBecomeActive/didBecomeKey notifications. Do not interpret
                // that brief handoff as a cancelled reveal.
                try await self.waitForPresentation(requestID: id)
                if !self.hasUserEdits && !self.hasLoadedCredential {
                    let data: Data?
                    if let account { data = try await self.read(account) }
                    else { data = nil }
                    guard self.requestID == id, !Task.isCancelled else { return }
                    // A first Keychain access approval can also take focus.
                    try await self.waitForPresentation(requestID: id)
                    // Typing while authentication/read is in flight wins over
                    // the older saved credential, even when the user cleared it.
                    if !self.hasUserEdits {
                        guard let data else {
                            self.errorMessage = L10n.text("此会话尚未保存该密码或口令。")
                            self.finishRequest()
                            return
                        }
                        guard let secret = String(data: data, encoding: .utf8) else { throw KeychainStoreError.invalidData }
                        self.draft = secret
                        self.hasLoadedCredential = true
                    }
                }
                self.isRevealed = true
                self.finishRequest()
                let duration = self.timeoutNanoseconds
                self.expiryTask = Task { [weak self] in
                    do { try await Task.sleep(nanoseconds: duration) } catch { return }
                    guard let self, self.requestID == id else { return }
                    self.hide()
                }
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.isRevealed = false
                switch error {
                case CredentialAuthenticationError.cancelled:
                    self.errorMessage = nil
                case CredentialAuthenticationError.unavailable:
                    self.errorMessage = L10n.text("系统身份验证不可用，请检查 Mac 登录密码或 Touch ID 设置。")
                case CredentialAuthenticationError.failed:
                    self.errorMessage = L10n.text("身份验证未通过，未显示密码。")
                case CredentialAuthenticationError.windowNotReady:
                    self.errorMessage = L10n.text("编辑窗口尚未获得焦点。请回到原窗口后重新查看。")
                case let storageError as CredentialStoreError:
                    self.errorMessage = storageError.localizedDescription
                case let keychainError as KeychainStoreError:
                    self.errorMessage = keychainError.localizedDescription
                default:
                    self.errorMessage = L10n.text("无法读取已保存的凭据，请检查凭据文件和钥匙串权限。")
                }
                self.finishRequest()
            }
        }
    }

    private func finishRequest() {
        authentication?.invalidate()
        authentication = nil
        isAuthenticating = false
        isLoading = false
        scheduleViewUpdate()
    }

    func hide() {
        requestID = UUID()
        requestTask?.cancel()
        requestTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        isRevealed = false
        errorMessage = nil
        finishRequest()
    }

    func focusLost() {
        // A system authentication panel can temporarily take focus. It never
        // reveals data itself; completion checks the originating window again.
        if !isLoading { hide() }
    }

    func reset() {
        hide()
        draft = ""
        hasUserEdits = false
        hasLoadedCredential = false
    }

    private func waitForPresentation(requestID id: UUID) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .nanoseconds(Int64(clamping: focusReturnTimeoutNanoseconds)))
        var wasReady = false
        while true {
            guard requestID == id, !Task.isCancelled else { throw CancellationError() }
            let ready = canPresent()
            // Two observations on different run-loop turns avoid publishing
            // just before a delayed native focus-loss event arrives.
            if ready && wasReady { return }
            wasReady = ready
            guard clock.now < deadline else { throw CredentialAuthenticationError.windowNotReady }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
    }

    func attachPresentation(id: UUID, canPresent: @escaping () -> Bool) {
        presentationID = id
        self.canPresent = canPresent
        updatesEnabled = true
    }

    func detachPresentation(id: UUID) {
        // SwiftUI may create a replacement native view before dismantling the
        // old one. An obsolete observer must not disable its replacement.
        guard presentationID == id else { return }
        presentationID = nil
        updatesEnabled = false
        pendingUpdateID = nil
        canPresent = { false }
        reset()
    }

    private func scheduleViewUpdate() {
        guard updatesEnabled, pendingUpdateID == nil else { return }
        let id = UUID()
        pendingUpdateID = id
        DispatchQueue.main.async { [weak self] in
            guard let self, self.updatesEnabled, self.pendingUpdateID == id else { return }
            self.pendingUpdateID = nil
            self.objectWillChange.send()
        }
    }
}

struct CredentialInputView: View {
    let account: String?
    let isPassphrase: Bool
    @ObservedObject var reveal: CredentialRevealController
    @FocusState private var inputFocused: Bool

    private var text: Binding<String> {
        Binding(get: { reveal.draft }, set: { reveal.edit($0) })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(isPassphrase ? L10n.text("私钥口令") : L10n.text("密码"))
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(SnakeStyle.muted)
                Spacer()
                if reveal.isLoading {
                    Text(reveal.isAuthenticating ? L10n.text("正在验证…") : L10n.text("正在读取…"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            HStack(spacing: 8) {
                Group {
                    if reveal.isRevealed {
                        TextField("", text: text)
                    } else {
                        SecureField(isPassphrase ? L10n.text("可选，留空保留原口令") : L10n.text("留空保留原密码"), text: text)
                    }
                }
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 13, design: .monospaced))
                .frame(height: 32)
                .focused($inputFocused)
                .accessibilityLabel(isPassphrase ? L10n.text("私钥口令") : L10n.text("密码"))
                Button {
                    if reveal.isLoading || reveal.isRevealed { reveal.hide() }
                    else { reveal.reveal(account: account) }
                } label: {
                    Label(
                        reveal.isLoading ? L10n.text("取消验证") : (reveal.isRevealed ? L10n.text("隐藏") : L10n.text("查看")),
                        systemImage: reveal.isLoading ? "xmark.circle" : (reveal.isRevealed ? "eye.slash" : "eye")
                    )
                    .fixedSize()
                }
                .buttonStyle(SnakeOutlineButtonStyle())
                .disabled(!reveal.isLoading && !reveal.isRevealed && !reveal.canReveal(account: account))
                .help("验证身份后在原输入框显示并编辑；30 秒后恢复隐藏，保留草稿")
                if reveal.isLoading {
                    ProgressView().controlSize(.small)
                }
            }
            if let error = reveal.errorMessage {
                Text(error).font(.system(size: 11)).foregroundStyle(.red)
            }
        }
        .font(.system(size: 11))
        .background(CredentialRevealWindowObserver(controller: reveal))
        .onChange(of: account) { _, _ in reveal.reset() }
        .onChange(of: reveal.isRevealed) { _, revealed in
            if revealed { inputFocused = true }
        }
        .onDisappear { reveal.reset() }
    }
}

struct CredentialRevealWindowObserver: NSViewRepresentable {
    let controller: CredentialRevealController
    func makeNSView(context: Context) -> ObservationView { ObservationView(controller: controller) }
    func updateNSView(_ nsView: ObservationView, context: Context) {}
    static func dismantleNSView(_ nsView: ObservationView, coordinator: ()) { nsView.stopObserving() }

    final class ObservationView: NSView {
        let controller: CredentialRevealController
        private let presentationID = UUID()
        init(controller: CredentialRevealController) {
            self.controller = controller
            super.init(frame: .zero)
            NotificationCenter.default.addObserver(self, selector: #selector(focusLost(_:)), name: NSWindow.didResignKeyNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(focusLost(_:)), name: NSApplication.didResignActiveNotification, object: nil)
            NotificationCenter.default.addObserver(self, selector: #selector(windowClosing(_:)), name: NSWindow.willCloseNotification, object: nil)
            controller.attachPresentation(id: presentationID) { [weak self] in
                guard let window = self?.window else { return false }
                return Self.canReveal(in: window, applicationIsActive: NSApp.isActive, keyWindow: NSApp.keyWindow)
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        @objc private func focusLost(_ notification: Notification) {
            if notification.name == NSApplication.didResignActiveNotification || notification.object as? NSWindow === window {
                controller.focusLost()
            }
        }
        @objc private func windowClosing(_ notification: Notification) {
            if notification.object as? NSWindow === window || notification.object as? NSWindow === window?.sheetParent {
                controller.reset()
            }
        }
        func stopObserving() {
            NotificationCenter.default.removeObserver(self)
            controller.detachPresentation(id: presentationID)
        }

        static func canReveal(in window: NSWindow, applicationIsActive: Bool, keyWindow: NSWindow?) -> Bool {
            guard applicationIsActive, window.isVisible, window.attachedSheet == nil, let keyWindow else { return false }
            if keyWindow === window { return true }
            // SwiftUI sheets can be hosted in a child sheet while the native
            // parent remains key. Never accept an unrelated window or sheet.
            return window.sheetParent === keyWindow && keyWindow.attachedSheet === window
        }
        deinit { NotificationCenter.default.removeObserver(self) }
    }
}
