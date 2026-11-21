import Foundation
import Observation
import Security

/// Where a secret is kept (design, section 9: `SecretStore`): the Keychain in the apps, memory in tests.
public protocol SecretStore: Sendable {
    /// Whether one is kept, without reading it, which on the Mac can ask the person to allow it.
    func exists() -> Bool
    func read() throws -> String?
    func write(_ secret: String) throws
    func delete() throws
}

/// A generic password in the person's Keychain, the same on the Mac and the iPad.
public struct KeychainStore: SecretStore {
    public let service: String
    public let account: String

    public init(service: String = "Synesthesia: Claude API key", account: String = "anthropic") {
        self.service = service
        self.account = account
    }

    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service, kSecAttrAccount as String: account]
    }

    public func exists() -> Bool {
        var query = query
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        return SecItemCopyMatching(query as CFDictionary, nil) == errSecSuccess
    }

    public func read() throws -> String? {
        var query = query
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var found: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &found)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = found as? Data else { throw KeychainError(status: status) }
        return String(decoding: data, as: UTF8.self)
    }

    public func write(_ secret: String) throws {
        let data = Data(secret.utf8)
        let status = SecItemUpdate(query as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrLabel as String] = service
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            let added = SecItemAdd(item as CFDictionary, nil)
            guard added == errSecSuccess else { throw KeychainError(status: added) }
        } else if status != errSecSuccess {
            throw KeychainError(status: status)
        }
    }

    public func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError(status: status) }
    }
}

public struct KeychainError: Error, LocalizedError, Equatable {
    public let status: OSStatus
    public var errorDescription: String? {
        let reason = SecCopyErrorMessageString(status, nil) as String? ?? "error \(status)"
        return "The Keychain couldn't do that: \(reason)."
    }
}

/// A secret kept in memory, for tests and previews.
public final class MemoryStore: SecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secret: String?

    public init(_ secret: String? = nil) { self.secret = secret }

    public func exists() -> Bool { lock.withLock { secret != nil } }
    public func read() throws -> String? { lock.withLock { secret } }
    public func write(_ secret: String) throws { lock.withLock { self.secret = secret } }
    public func delete() throws { lock.withLock { secret = nil } }
}

/// The person's Anthropic API key: whether one is kept, saving and removing it. It's read from the store once, when a
/// request first needs it, and held in memory after; it's never shown, logged or put anywhere but a request's header.
@MainActor @Observable
public final class ClaudeKey {
    public private(set) var isSaved: Bool
    /// Why it couldn't be read, saved or removed, if it couldn't.
    public private(set) var problem: String?
    @ObservationIgnored private let store: any SecretStore
    @ObservationIgnored private var held: String?

    public init(store: any SecretStore) {
        self.store = store
        isSaved = store.exists()
    }

    /// Saves a key the person typed or pasted, trimmed of spaces and line breaks.
    public func save(_ key: String) {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do {
            try store.write(trimmed)
            held = trimmed
            isSaved = true
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    public func remove() {
        do {
            try store.delete()
            held = nil
            isSaved = false
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
    }

    /// The key, for a request's header, or nil if none is kept.
    func value() -> String? {
        if let held { return held }
        do {
            held = try store.read()
            isSaved = held != nil
            problem = nil
        } catch {
            problem = error.localizedDescription
        }
        return held
    }

    /// Forgets the key held in memory, so the next request reads it again: after the API refused it, say.
    func forget() {
        held = nil
        isSaved = store.exists()
    }
}
