import Foundation
import Security

/// Generic-password storage for the Anthropic API key. Falls back to the
/// ANTHROPIC_API_KEY environment variable when the Keychain has no entry
/// (handy for development builds).
final class KeychainStore: KeychainProtocol, @unchecked Sendable {
    private let service: String
    private let keyAccount = "anthropic-api-key"
    private let providersAccount = "providers-v1"

    init(service: String = "com.local.cosmos") {
        self.service = service
    }

    func getApiKey() throws -> String? {
        guard let data = readData(account: keyAccount) else { return envFallback() }
        let key = String(decoding: data, as: UTF8.self)
        return key.isEmpty ? envFallback() : key
    }

    func setApiKey(_ key: String) throws {
        try upsert(Data(key.utf8), account: keyAccount)
    }

    func deleteApiKey() throws {
        try delete(account: keyAccount)
    }

    func getProvidersData() throws -> Data? {
        readData(account: providersAccount)
    }

    func setProvidersData(_ data: Data) throws {
        if data.isEmpty {
            try delete(account: providersAccount)
        } else {
            try upsert(data, account: providersAccount)
        }
    }

    // MARK: SecItem plumbing

    private func readData(account: String) -> Data? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        // Ad-hoc-signed builds can hit ACL denials; degrade, don't crash.
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }

    private func upsert(_ data: Data, account: String) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(
            baseQuery(account: account) as CFDictionary, attributes as CFDictionary)
        if updateStatus == errSecSuccess { return }
        if updateStatus == errSecItemNotFound {
            var add = baseQuery(account: account)
            add[kSecValueData as String] = data
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            guard addStatus == errSecSuccess else { throw Self.error(addStatus) }
            return
        }
        throw Self.error(updateStatus)
    }

    private func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw Self.error(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func envFallback() -> String? {
        let env = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]
        return (env?.isEmpty ?? true) ? nil : env
    }

    private static func error(_ status: OSStatus) -> NSError {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus \(status)"
        return NSError(domain: NSOSStatusErrorDomain, code: Int(status),
                       userInfo: [NSLocalizedDescriptionKey: "Keychain: \(message)"])
    }
}
