import Foundation
import Network

/// Loopback-only HTTP listener. Each connection carries one request and is
/// closed after the reply, which keeps the server free of keep-alive state.
@MainActor
final class McpHTTPServer {
    enum State: Equatable {
        case stopped
        case starting
        case listening(port: Int)
        case failed(String)
    }

    private let queue = DispatchQueue(label: "com.snake.mcp.http", qos: .userInitiated)
    private var listener: NWListener?
    private let handler: McpRequestHandler
    private(set) var state: State = .stopped {
        didSet { onStateChange?(state) }
    }
    var onStateChange: ((State) -> Void)?
    /// A request that has not arrived completely by then is dropped.
    static let receiveTimeout: TimeInterval = 30

    init(handler: McpRequestHandler) {
        self.handler = handler
    }

    func start() {
        stop()
        guard let port = NWEndpoint.Port(rawValue: UInt16(clamping: handler.port)) else {
            state = .failed("invalid port")
            return
        }
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        // Binding the loopback address keeps the port unreachable from the network.
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: port)
        do {
            let listener = try NWListener(using: parameters)
            listener.stateUpdateHandler = { [weak self] update in
                Task { @MainActor [weak self] in self?.listenerChanged(update, port: Int(port.rawValue)) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor [weak self] in self?.accept(connection) }
            }
            self.listener = listener
            state = .starting
            listener.start(queue: queue)
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        state = .stopped
    }

    private func listenerChanged(_ update: NWListener.State, port: Int) {
        switch update {
        case .ready: state = .listening(port: port)
        case .failed(let error):
            listener?.cancel()
            listener = nil
            state = .failed(Self.describe(error))
        case .cancelled: if case .failed = state {} else { state = .stopped }
        default: break
        }
    }

    private static func describe(_ error: NWError) -> String {
        if case .posix(.EADDRINUSE) = error { return L10n.text("端口已被占用") }
        return error.localizedDescription
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        let deadline = DispatchWorkItem { connection.cancel() }
        queue.asyncAfter(deadline: .now() + Self.receiveTimeout, execute: deadline)
        receive(on: connection, buffer: Data(), deadline: deadline)
    }

    private nonisolated func receive(on connection: NWConnection, buffer: Data, deadline: DispatchWorkItem) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1_024) { [weak self] data, _, isComplete, error in
            var buffer = buffer
            if let data { buffer.append(data) }
            switch McpHTTPParser.parse(buffer) {
            case .incomplete:
                if isComplete || error != nil {
                    deadline.cancel()
                    connection.cancel()
                } else {
                    self?.receive(on: connection, buffer: buffer, deadline: deadline)
                }
            case .invalid(let response):
                deadline.cancel()
                Self.send(response, on: connection)
            case .complete(let request):
                // Commands may legitimately outlast the receive deadline.
                deadline.cancel()
                Task { @MainActor [weak self] in
                    guard let self else { return connection.cancel() }
                    let response = await self.handler.handle(request)
                    Self.send(response, on: connection)
                }
            }
        }
    }

    private nonisolated static func send(_ response: McpHTTPResponse, on connection: NWConnection) {
        connection.send(content: response.serialized(), contentContext: .finalMessage, isComplete: true,
                        completion: .contentProcessed { _ in connection.cancel() })
    }
}
