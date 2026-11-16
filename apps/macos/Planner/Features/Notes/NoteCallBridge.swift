import Foundation
import Network

struct NoteCallRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data

    enum Parse {
        case waiting, invalid
        case ready(NoteCallRequest)
    }

    static let headerLimit = 8192
    static let bodyLimit = 192_000

    static func parse(_ packet: Data) -> Parse {
        guard let split = packet.range(of: Data([13, 10, 13, 10])) else {
            return packet.count < headerLimit ? .waiting : .invalid
        }
        guard split.lowerBound <= headerLimit, let text = String(data: packet[..<split.lowerBound], encoding: .utf8) else {
            return .invalid
        }
        let lines = text.components(separatedBy: "\r\n")
        let first = lines[0].split(separator: " ")
        guard first.count == 3, ["GET", "POST"].contains(first[0]), first[2] == "HTTP/1.1" else { return .invalid }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            let pair = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard pair.count == 2 else { return .invalid }
            let key = pair[0].lowercased()
            guard headers[key] == nil else { return .invalid }
            headers[key] = pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard headers["transfer-encoding"] == nil,
              let length = Int(headers["content-length"] ?? (first[0] == "GET" ? "0" : "")),
              (0...bodyLimit).contains(length) else { return .invalid }
        let remaining = packet.count - split.upperBound
        guard remaining == length else { return remaining < length ? .waiting : .invalid }
        return .ready(Self(method: String(first[0]), path: String(first[1]), headers: headers,
                           body: Data(packet[split.upperBound...])))
    }

    func isAuthorized(port: UInt16) -> Bool {
        let host = "127.0.0.1:\(port)"
        return headers["host"] == host && (method == "GET" ||
            (headers["origin"] == "http://" + host && headers["x-takt-call"] == "1"))
    }
}

@MainActor
final class NoteCallBridge {
    struct Response {
        var status = "200 OK"
        var type = "text/plain; charset=utf-8"
        var body = Data()
    }

    private let listener: NWListener
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private let routes: (NoteCallRequest) -> Response

    init(routes: @escaping (NoteCallRequest) -> Response) throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        listener = try NWListener(using: parameters)
        self.routes = routes
    }

    func start(ready: @escaping @MainActor @Sendable (UInt16) -> Void, failed: @escaping @MainActor @Sendable () -> Void) {
        listener.stateUpdateHandler = { @Sendable [weak self] state in
            Task { @MainActor in
                switch state {
                case .ready:
                    if let port = self?.listener.port { ready(port.rawValue) }
                case .failed: failed()
                default: break
                }
            }
        }
        listener.newConnectionHandler = { @Sendable [weak self] connection in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                self.accept(connection)
            }
        }
        listener.start(queue: .main)
    }

    func close() {
        listener.cancel()
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
    }

    private func accept(_ connection: NWConnection) {
        guard connections.count < 12 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: .main)
        receive(connection, packet: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            self?.connections.removeValue(forKey: id)?.cancel()
        }
    }

    private func receive(_ connection: NWConnection, packet: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { @Sendable [weak self] incoming, _, ended, error in
            Task { @MainActor in
                guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
                var data = packet
                if let incoming { data.append(incoming) }
                switch NoteCallRequest.parse(data) {
                case .ready(let request):
                    guard let port = self.listener.port?.rawValue, request.isAuthorized(port: port) else {
                        self.send(.init(status: "403 Forbidden"), to: connection)
                        return
                    }
                    self.send(self.routes(request), to: connection)
                case .waiting where !ended && error == nil:
                    self.receive(connection, packet: data)
                default:
                    self.send(.init(status: "400 Bad Request"), to: connection)
                }
            }
        }
    }

    private func send(_ response: Response, to connection: NWConnection) {
        let headers = [
            "HTTP/1.1 " + response.status,
            "Content-Type: " + response.type,
            "Content-Length: \(response.body.count)",
            "Cache-Control: no-store",
            "Referrer-Policy: no-referrer",
            "X-Content-Type-Options: nosniff",
            "Content-Security-Policy: default-src 'none'; script-src 'self'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'",
            "Connection: close", "", ""
        ]
        var data = Data(headers.joined(separator: "\r\n").utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { @Sendable [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeValue(forKey: ObjectIdentifier(connection)) }
        })
    }

    deinit { listener.cancel() }
}
