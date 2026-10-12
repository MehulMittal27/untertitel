import Foundation
import Security

/// Storage for secrets such as API keys. Secrets never go through `AppSettings`.
protocol SecretStore: Sendable {
    /// Whether a secret is stored, without reading it. Safe to call at launch: unlike
    /// reading the value, it never makes macOS ask for Keychain access.
    func hasSecret(for account: String) -> Bool
    func secret(for account: String) -> String?
    func setSecret(_ secret: String, for account: String) throws
    func removeSecret(for account: String) throws
}

enum SecretAccount {
    static let openAIAPIKey = "openai-api-key"
    static let sonioxAPIKey = "soniox-api-key"
}

struct KeychainStoreError: Error, Equatable {
    let status: OSStatus
}

/// Generic-password items in the user's login Keychain.
struct KeychainStore: SecretStore {
    private let service: String

    init(service: String = "com.franklioxygen.v2s") {
        self.service = service
    }

    func hasSecret(for account: String) -> Bool {
        var query = baseQuery(for: account)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    func secret(for account: String) -> String? {
        var query = baseQuery(for: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let secret = String(data: data, encoding: .utf8),
              secret.isEmpty == false else {
            return nil
        }

        return secret
    }

    func setSecret(_ secret: String, for account: String) throws {
        let data = Data(secret.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(for: account) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        switch updateStatus {
        case errSecSuccess:
            return
        case errSecItemNotFound:
            var attributes = baseQuery(for: account)
            attributes[kSecValueData as String] = data
            let addStatus = SecItemAdd(attributes as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw KeychainStoreError(status: addStatus)
            }
        default:
            throw KeychainStoreError(status: updateStatus)
        }
    }

    func removeSecret(for account: String) throws {
        let status = SecItemDelete(baseQuery(for: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError(status: status)
        }
    }

    private func baseQuery(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }
}
