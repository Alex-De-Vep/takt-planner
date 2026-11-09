import CryptoKit
import Foundation
import Security

/// Проверка только подписанных OpenAI удостоверений для собственного клиента OAuth.
enum ChatGPTIdentity {
    static let issuer = "https://auth.openai.com"
    static let resource = "https://api.openai.com/v1"
    static let planScope = "chatgpt.tokens.use.direct"
    static let scopes = "openid profile email offline_access resource.invoke " + planScope

    struct Claims: Decodable {
        let iss: String
        let aud: [String]
        let sub: String
        let exp: Double
        let nonce: String
        let azp: String?
        let email: String?

        init(from decoder: Decoder) throws {
            enum Key: String, CodingKey { case iss, aud, sub, exp, nonce, azp, email }
            let values = try decoder.container(keyedBy: Key.self)
            iss = try values.decode(String.self, forKey: .iss)
            if let single = try? values.decode(String.self, forKey: .aud) { aud = [single] }
            else { aud = try values.decode([String].self, forKey: .aud) }
            sub = try values.decode(String.self, forKey: .sub)
            exp = try values.decode(Double.self, forKey: .exp)
            nonce = try values.decode(String.self, forKey: .nonce)
            azp = try values.decodeIfPresent(String.self, forKey: .azp)
            email = try values.decodeIfPresent(String.self, forKey: .email)
        }
    }

    static func random() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw invalid }
        return urlBase64(Data(bytes))
    }

    static func challenge(_ verifier: String) -> String {
        urlBase64(Data(SHA256.hash(data: Data(verifier.utf8))))
    }

    static func verify(token: String, keys: Data, clientID: String, nonce: String, now: Date = .now) throws -> Claims {
        struct Header: Decodable { let alg: String; let kid: String }
        struct KeySet: Decodable {
            struct Key: Decodable {
                let kid: String?
                let kty: String
                let alg: String?
                let use: String?
                let n: String?
                let e: String?
            }
            let keys: [Key]
        }
        let parts = token.split(separator: ".", omittingEmptySubsequences: false)
        let decoder = JSONDecoder()
        guard token.utf8.count <= 32_768, parts.count == 3,
              let headerData = base64(parts[0]), let payload = base64(parts[1]), let signature = base64(parts[2]),
              let header = try? decoder.decode(Header.self, from: headerData), header.alg == "RS256",
              let key = try? decoder.decode(KeySet.self, from: keys).keys.first(where: {
                  $0.kid == header.kid && $0.kty == "RSA" && ($0.alg == nil || $0.alg == "RS256") && ($0.use == nil || $0.use == "sig")
              }), let n = key.n.flatMap({ base64($0[...]) }), let e = key.e.flatMap({ base64($0[...]) }),
              (256...1024).contains(n.count), (1...8).contains(e.count) else { throw invalid }
        let der = tagged(0x30, integer(n) + integer(e))
        let attributes = [kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeyClass: kSecAttrKeyClassPublic] as CFDictionary
        guard let publicKey = SecKeyCreateWithData(der as CFData, attributes, nil),
              SecKeyVerifySignature(publicKey, .rsaSignatureMessagePKCS1v15SHA256,
                                    Data((parts[0] + "." + parts[1]).utf8) as CFData, signature as CFData, nil),
              let claims = try? decoder.decode(Claims.self, from: payload),
              claims.iss == issuer, claims.aud.contains(clientID),
              claims.aud.count == 1 || claims.azp == clientID,
              claims.azp == nil || claims.azp == clientID,
              !claims.sub.isEmpty, claims.exp.isFinite, claims.exp > now.timeIntervalSince1970 - 5,
              claims.nonce == nonce else { throw invalid }
        return claims
    }

    private static var invalid: AssistantFailure { AssistantFailure(message: "Не удалось проверить ответ входа в ChatGPT.") }

    private static func urlBase64(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }

    private static func base64(_ value: Substring) -> Data? {
        var text = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return Data(base64Encoded: text)
    }

    private static func integer(_ bytes: Data) -> Data {
        var value = Data(bytes.drop(while: { $0 == 0 }))
        if value.isEmpty || value[0] & 0x80 != 0 { value.insert(0, at: 0) }
        return tagged(0x02, value)
    }

    private static func tagged(_ tag: UInt8, _ value: Data) -> Data {
        if value.count < 128 { return Data([tag, UInt8(value.count)]) + value }
        var count = value.count
        var length: [UInt8] = []
        while count > 0 {
            length.insert(UInt8(count & 0xff), at: 0)
            count >>= 8
        }
        return Data([tag, 0x80 | UInt8(length.count)] + length) + value
    }
}
