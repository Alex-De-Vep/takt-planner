import Foundation
import Network

/// Принимает один OAuth-ответ от системного браузера. Слушатель доступен только на loopback.
@MainActor
final class ChatGPTLoopback {
    static let path = "/auth/callback"
    struct Grant: Equatable, Sendable {
        let code: String
        let clientID: String
    }
    private let state: String
    private let registeredClientID: String?
    private let openRouterPath: String?
    private let russian: Bool
    private var listener: NWListener?
    private var connections: [ObjectIdentifier: NWConnection] = [:]
    private var completion: CheckedContinuation<Grant, Error>?
    private var timeout: Task<Void, Never>?

    init(state: String, registeredClientID: String?, russian: Bool, openRouterPath: String? = nil) {
        self.state = state
        self.registeredClientID = registeredClientID
        self.russian = russian
        self.openRouterPath = openRouterPath
    }

    func receive(openBrowser: @escaping @MainActor (URL) -> Bool) async throws -> Grant {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                completion = continuation
                if Task.isCancelled {
                    finish(.failure(CancellationError()))
                    return
                }
                listener.stateUpdateHandler = { @Sendable [weak self] state in
                    Task { @MainActor in
                        guard let self, self.completion != nil else { return }
                        switch state {
                        case .ready:
                            guard let port = self.listener?.port,
                                  let url = URL(string: "http://127.0.0.1:\(port.rawValue)\(self.openRouterPath ?? Self.path)"),
                                  openBrowser(url) else {
                                self.finish(.failure(AssistantFailure(message: "Не удалось открыть страницу входа.")))
                                return
                            }
                        case .failed, .cancelled:
                            self.finish(.failure(AssistantFailure(message: "Не удалось принять ответ браузера.")))
                        default: break
                        }
                    }
                }
                listener.newConnectionHandler = { @Sendable [weak self] connection in
                    Task { @MainActor in self?.accept(connection) }
                }
                listener.start(queue: .main)
                timeout = Task { [weak self] in
                    do { try await Task.sleep(for: .seconds(180)) } catch { return }
                    self?.finish(.failure(AssistantFailure(message: "Время входа истекло.")))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.finish(.failure(CancellationError())) }
        }
    }

    private func accept(_ connection: NWConnection) {
        guard completion != nil, connections.count < 8 else { connection.cancel(); return }
        let id = ObjectIdentifier(connection)
        connections[id] = connection
        connection.start(queue: .main)
        receiveHeader(on: connection, buffer: Data())
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            self?.close(id)
        }
    }

    private func receiveHeader(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { @Sendable [weak self] data, _, ended, error in
            Task { @MainActor in
                guard let self, self.connections[ObjectIdentifier(connection)] != nil else { return }
                var buffer = buffer
                if let data { buffer.append(data) }
                if buffer.count <= 8192, let end = buffer.range(of: Data([13, 10, 13, 10])) {
                    let header = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
                    self.handle(header, on: connection)
                } else if ended || error != nil || buffer.count >= 8192 {
                    self.close(ObjectIdentifier(connection))
                } else {
                    self.receiveHeader(on: connection, buffer: buffer)
                }
            }
        }
    }

    private func handle(_ header: String, on connection: NWConnection) {
        let result: Result<Grant, Error>?
        if let openRouterPath {
            result = Self.openRouterCallback(header, path: openRouterPath, expectedState: state).map {
                $0.map { Grant(code: $0, clientID: "") }
            }
        } else {
            result = Self.callback(header, expectedState: state, registeredClientID: registeredClientID)
        }
        let id = ObjectIdentifier(connection)
        let status: String
        let message: String
        if case .success? = result {
            status = "200 OK"
            message = russian ? "Ответ получен. Вернитесь в приложение «Задачи»." : "Response received. Return to Tasks."
        } else {
            status = "400 Bad Request"
            message = russian ? "Вход не завершён. Вернитесь в приложение «Задачи»." : "Sign-in did not complete. Return to Tasks."
        }
        let body = Data(message.utf8)
        var response = Data("HTTP/1.1 \(status)\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nConnection: close\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        response.append(body)
        // Отсоединяем успешное соединение от списка, чтобы отправить ответ браузеру до закрытия.
        if result != nil { connections.removeValue(forKey: id) }
        connection.send(content: response, completion: .contentProcessed { @Sendable [weak self] _ in
            connection.cancel()
            Task { @MainActor in self?.connections.removeValue(forKey: id) }
        })
        if let result { finish(result) }
    }

    /// Неверное состояние не должно завершать попытку, даже если запрос пришёл с этого Mac.
    static func callback(_ header: String, expectedState: String, registeredClientID: String?) -> Result<Grant, Error>? {
        let line = header.components(separatedBy: "\r\n").first ?? ""
        let parts = line.split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/"),
              parts[1].hasPrefix(path + "?"),
              let components = URLComponents(string: "http://127.0.0.1" + parts[1]),
              components.path == path else { return nil }
        let items = components.queryItems ?? []
        func value(_ key: String) -> String? {
            let matches = items.filter { $0.name == key }
            return matches.count == 1 ? matches[0].value : nil
        }
        guard value("state") == expectedState else { return nil }
        if items.contains(where: { $0.name == "error" }) {
            return .failure(AssistantFailure(message: "Вход в ChatGPT не завершён."))
        }
        let returnedID = value("client_id")
        guard let code = value("code"), !code.isEmpty, code.count <= 4096,
              items.filter({ $0.name == "client_id" }).count <= 1,
              let clientID = returnedID ?? registeredClientID,
              !clientID.isEmpty, clientID.count <= 256, clientID != "dynamic_agent_client",
              registeredClientID == nil || registeredClientID == clientID else {
            return .failure(AssistantFailure(message: "Не удалось проверить ответ входа в ChatGPT."))
        }
        return .success(Grant(code: code, clientID: clientID))
    }

    /// Случайный путь привязывает ответ к попытке входа, а PKCE привязывает обмен к этому приложению.
    static func openRouterCallback(_ header: String, path: String, expectedState: String) -> Result<String, Error>? {
        let parts = (header.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
        guard parts.count == 3, parts[0] == "GET", parts[2].hasPrefix("HTTP/"),
              parts[1].hasPrefix(path + "?"),
              let url = URLComponents(string: "http://127.0.0.1" + parts[1]), url.path == path else { return nil }
        let items = url.queryItems ?? []
        if items.contains(where: { $0.name == "error" }) {
            return .failure(AssistantFailure(message: "Вход в OpenRouter не завершён."))
        }
        let states = items.filter { $0.name == "state" }
        guard states.count == 1, states[0].value == expectedState else { return nil }
        let codes = items.filter { $0.name == "code" }
        guard codes.count == 1, let code = codes[0].value, !code.isEmpty, code.utf8.count <= 4096 else {
            return .failure(AssistantFailure(message: "Вход в OpenRouter не завершён."))
        }
        return .success(code)
    }

    private func close(_ id: ObjectIdentifier) { connections.removeValue(forKey: id)?.cancel() }

    private func finish(_ result: Result<Grant, Error>) {
        guard let completion else { return }
        self.completion = nil
        timeout?.cancel()
        timeout = nil
        listener?.cancel()
        listener = nil
        connections.values.forEach { $0.cancel() }
        connections.removeAll()
        completion.resume(with: result)
    }
}
