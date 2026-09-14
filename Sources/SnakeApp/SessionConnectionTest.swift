import Combine
import Foundation
import SnakeCoreBindings
import SwiftUI

struct SessionConnectionTarget: Equatable, Sendable {
    let host: String
    let port: UInt16
}

struct SessionHandshakeResult: Equatable, Sendable {
    let algorithm: String
    let fingerprint: String
}

enum SessionConnectionTestState: Equatable {
    case idle
    case testing(SessionConnectionTarget)
    case success(SessionConnectionTarget, SessionHandshakeResult)
    case failure(SessionConnectionTarget?, String)

    var target: SessionConnectionTarget? {
        switch self {
        case .idle: nil
        case .testing(let target), .success(let target, _): target
        case .failure(let target, _): target
        }
    }
}

/// A host/port-bound handshake probe, not a password authentication test.
@MainActor
final class SessionConnectionTestController: @preconcurrency ObservableObject {
    let objectWillChange = ObservableObjectPublisher()
    private(set) var state: SessionConnectionTestState = .idle
    var isTesting: Bool { if case .testing = state { true } else { false } }
    private let probe: (SessionConnectionTarget) async throws -> SessionHandshakeResult
    private var requestID = UUID()
    private var task: Task<Void, Never>?
    private var updateID: UUID?

    init(probe: @escaping (SessionConnectionTarget) async throws -> SessionHandshakeResult = { target in
        try await Task.detached(priority: .userInitiated) {
            let key = try probeHostKey(host: target.host, port: target.port)
            return SessionHandshakeResult(algorithm: key.algorithm, fingerprint: key.fingerprint)
        }.value
    }) {
        self.probe = probe
    }

    func start(host: String, port: String) {
        reset()
        let cleanHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanHost.isEmpty, let number = UInt16(port), number > 0 else {
            state = .failure(nil, L10n.text("请填写有效主机和 1 到 65535 之间的端口。"))
            return
        }
        let target = SessionConnectionTarget(host: cleanHost, port: number)
        let id = requestID
        state = .testing(target)
        task = Task { [weak self, probe] in
            do {
                let result = try await probe(target)
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.state = .success(target, result)
                self.publishLater()
            } catch {
                guard let self, self.requestID == id, !Task.isCancelled else { return }
                self.state = .failure(target, L10n.format("无法完成 SSH 握手：%@", error.localizedDescription))
                self.publishLater()
            }
        }
    }

    func reset() {
        requestID = UUID()
        task?.cancel()
        task = nil
        state = .idle
        publishLater()
    }

    private func publishLater() {
        guard updateID == nil else { return }
        let id = UUID()
        updateID = id
        DispatchQueue.main.async { [weak self] in
            guard let self, self.updateID == id else { return }
            self.updateID = nil
            self.objectWillChange.send()
        }
    }
}

struct SessionConnectionTestFeedback: View {
    let state: SessionConnectionTestState

    var body: some View {
        if state != .idle {
            VStack(alignment: .leading, spacing: 8) {
                Divider()
                HStack(spacing: 6) {
                    switch state {
                    case .testing:
                        ProgressView().controlSize(.small)
                        Text("正在检测 SSH 握手…")
                    case .success:
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(SnakeStyle.secure)
                        Text("SSH 握手成功")
                    case .failure:
                        Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
                        Text("SSH 握手未完成")
                    case .idle: EmptyView()
                    }
                }
                .font(.system(size: 11, weight: .semibold))
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        if let target = state.target {
                            Text(target.host)
                            Text(L10n.format("端口 · %@", target.port))
                        }
                        switch state {
                        case .success(_, let result):
                            Text(result.algorithm)
                            Text(result.fingerprint)
                        case .failure(_, let message):
                            Text(message).foregroundStyle(.red)
                        case .idle, .testing: EmptyView()
                        }
                    }
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(SnakeStyle.muted)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .scrollBounceBehavior(.basedOnSize)
                .frame(height: 112)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
