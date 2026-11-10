import Foundation
import Security

enum GigaChatTrust {
    static let tokenURL = URL(string: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")!
    static let apiBase = URL(string: "https://api.giga.chat/v1")!
    private static let endpoints = [tokenURL, apiBase]

    // Корневой сертификат с Госуслуг, указанный в документации GigaChat.
    // https://gu-st.ru/content/lending/russian_trusted_root_ca_pem.crt
    static let bundledAnchor = Bundle.main.resourceURL
        .map { $0.appending(path: "GigaChatTrust.bundle/RussianTrustedRootCA.der") }
        .flatMap { try? Data(contentsOf: $0) }

    static func allows(host: String, port: Int) -> Bool {
        endpoints.contains { $0.host() == host && ($0.port ?? 443) == port }
    }

    static func allows(_ url: URL) -> Bool {
        guard url.scheme == "https", let host = url.host(), url.user() == nil, url.password() == nil else { return false }
        return allows(host: host, port: url.port ?? 443)
    }

    static func evaluate(chain: [SecCertificate], host: String, port: Int, anchor: Data) -> SecTrust? {
        guard allows(host: host, port: port), !chain.isEmpty,
              let root = SecCertificateCreateWithData(nil, anchor as CFData) else { return nil }
        // Независимая проверка сохраняет исходный объект доверия URLSession для стандартной обработки.
        let policy = SecPolicyCreateSSL(true, host as CFString)
        var trust: SecTrust?
        guard SecTrustCreateWithCertificates(chain as CFArray, policy, &trust) == errSecSuccess, let trust,
              SecTrustSetAnchorCertificates(trust, [root] as CFArray) == errSecSuccess,
              SecTrustSetAnchorCertificatesOnly(trust, true) == errSecSuccess,
              SecTrustSetNetworkFetchAllowed(trust, false) == errSecSuccess,
              SecTrustEvaluateWithError(trust, nil) else { return nil }
        return trust
    }
}

final class AssistantGatewaySessionDelegate: NSObject, URLSessionTaskDelegate {
    private let gigaChatAnchor: Data?

    init(gigaChatAnchor: Data? = nil) {
        self.gigaChatAnchor = gigaChatAnchor
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        urlSession(session, didReceive: challenge, completionHandler: completionHandler)
    }

    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        let space = challenge.protectionSpace
        guard let gigaChatAnchor, space.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              space.protocol == "https", GigaChatTrust.allows(host: space.host, port: space.port),
              let systemTrust = space.serverTrust, !SecTrustEvaluateWithError(systemTrust, nil) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var result = SecTrustResultType.invalid
        guard SecTrustGetTrustResult(systemTrust, &result) == errSecSuccess, result == .recoverableTrustFailure,
              let chain = SecTrustCopyCertificateChain(systemTrust) as? [SecCertificate],
              let trust = GigaChatTrust.evaluate(chain: chain, host: space.host, port: space.port, anchor: gigaChatAnchor) else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        completionHandler(.useCredential, URLCredential(trust: trust))
    }
}
