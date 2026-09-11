import Darwin
import Foundation
import Security

struct PersonalCloudConfiguration: Codable, Equatable, Sendable {
    let apiURL: URL
    let deviceToken: String
    let projectID: String?
}

enum CloudCredentialError: Error, LocalizedError, Equatable {
    case invalidAPIURL
    case invalidDeviceToken
    case invalidConfigurationData
    case unsafeSetupFile
    case setupFileReadFailed
    case setupFileChanged
    case setupFileRemovalFailed
    case alreadyConfigured
    case storageReadFailed
    case storageWriteFailed
    case storageDeleteFailed
    case storageVerificationFailed
    case keychain(OSStatus)

    var errorDescription: String? {
        switch self {
        case .invalidAPIURL:
            return "The personal cloud API must use an absolute HTTPS URL without a username, password, query, or fragment."
        case .invalidDeviceToken:
            return "The personal cloud device token must contain at least 32 characters and no whitespace or control characters."
        case .invalidConfigurationData:
            return "The personal cloud configuration is malformed or is missing required fields."
        case .unsafeSetupFile:
            return "Personal cloud setup must be a regular local file owned by your user, with permissions 0600 and no ACL grants for reading, writing, or changing permissions."
        case .setupFileReadFailed:
            return "The personal cloud setup file could not be read. It has been kept."
        case .setupFileChanged:
            return "The personal cloud setup file changed during import. It has not been removed."
        case .setupFileRemovalFailed:
            return "The credentials were securely stored, but the setup file could not be removed."
        case .alreadyConfigured:
            return "Lenscap already has a different personal cloud configuration. Reconnect explicitly before importing this setup file."
        case .storageReadFailed:
            return "The personal cloud credentials could not be read from secure storage."
        case .storageWriteFailed:
            return "The personal cloud credentials could not be saved to secure storage."
        case .storageDeleteFailed:
            return "The personal cloud credentials could not be removed from secure storage."
        case .storageVerificationFailed:
            return "The saved personal cloud credentials could not be verified. The setup file has been kept."
        case .keychain(let status):
            return "Keychain could not complete the personal cloud credential operation (status \(status))."
        }
    }
}

protocol CloudCredentialPersistence {
    func read() throws -> Data?
    func write(_ data: Data) throws
    func delete() throws
}

/// All persistence operations, including import's existing-account check, are serialized.
final class CloudCredentialStore: @unchecked Sendable {
    private let persistence: any CloudCredentialPersistence
    private let lock = NSRecursiveLock()
    private static let maximumSetupBytes = 64 * 1024

    init(persistence: any CloudCredentialPersistence) {
        self.persistence = persistence
    }

    func load() throws -> PersonalCloudConfiguration? {
        lock.lock()
        defer { lock.unlock() }
        let data: Data?
        do {
            data = try persistence.read()
        } catch let error as CloudCredentialError {
            throw error
        } catch {
            throw CloudCredentialError.storageReadFailed
        }
        guard let data else { return nil }
        return try Self.decode(data)
    }

    /// Explicit save is also the reconnect path; importing setup never silently reconnects.
    func save(_ configuration: PersonalCloudConfiguration) throws {
        lock.lock()
        defer { lock.unlock() }
        try Self.validate(configuration)
        let data: Data
        do {
            data = try JSONEncoder().encode(configuration)
        } catch {
            throw CloudCredentialError.invalidConfigurationData
        }
        do {
            try persistence.write(data)
        } catch let error as CloudCredentialError {
            throw error
        } catch {
            throw CloudCredentialError.storageWriteFailed
        }
        guard try load() == configuration else {
            throw CloudCredentialError.storageVerificationFailed
        }
    }

    func delete() throws {
        lock.lock()
        defer { lock.unlock() }
        do {
            try persistence.delete()
        } catch let error as CloudCredentialError {
            throw error
        } catch {
            throw CloudCredentialError.storageDeleteFailed
        }
    }

    @discardableResult
    func importSetupFile(at url: URL) throws -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard url.isFileURL, url.path.hasPrefix("/"), !url.path.utf8.contains(0),
              url.host == nil || url.host == "" || url.host == "localhost",
              url.query == nil, url.fragment == nil else {
            throw CloudCredentialError.unsafeSetupFile
        }

        // Keep the directory open so a renamed/replaced parent path cannot redirect deletion.
        let directory = Darwin.open(url.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW)
        if directory < 0 {
            if errno == ENOENT { return false }
            throw CloudCredentialError.unsafeSetupFile
        }
        defer { Darwin.close(directory) }

        let filename = url.lastPathComponent
        let descriptor = openat(directory, filename, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        if descriptor < 0 {
            if errno == ENOENT { return false }
            throw CloudCredentialError.unsafeSetupFile
        }
        defer { Darwin.close(descriptor) }

        var original = stat()
        guard fstat(descriptor, &original) == 0 else { throw CloudCredentialError.setupFileReadFailed }
        let exposedPermissions = mode_t(S_IRGRP | S_IWGRP | S_IROTH | S_IWOTH)
        guard original.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), original.st_uid == getuid(),
              original.st_mode & exposedPermissions == 0 else {
            throw CloudCredentialError.unsafeSetupFile
        }
        var filesystem = statfs()
        guard fstatfs(descriptor, &filesystem) == 0 else { throw CloudCredentialError.setupFileReadFailed }
        guard filesystem.f_flags & UInt32(MNT_LOCAL) != 0 else { throw CloudCredentialError.unsafeSetupFile }
        try Self.validatePrivateACL(descriptor: descriptor)
        guard original.st_size >= 0, original.st_size <= Self.maximumSetupBytes else {
            throw CloudCredentialError.invalidConfigurationData
        }

        let configuration = try Self.decode(Self.readSetupData(from: descriptor))
        if let existing = try load() {
            guard existing == configuration else { throw CloudCredentialError.alreadyConfigured }
        } else {
            try save(configuration)
        }

        // The bytes must be safely stored and read back before removing the same file we opened.
        var current = stat()
        guard fstatat(directory, filename, &current, AT_SYMLINK_NOFOLLOW) == 0,
              Self.isSameFile(original, current) else {
            throw CloudCredentialError.setupFileChanged
        }
        guard unlinkat(directory, filename, 0) == 0 else {
            throw CloudCredentialError.setupFileRemovalFailed
        }
        return true
    }

    private static func validatePrivateACL(descriptor: Int32) throws {
        // macOS ACL grants can expose a file even when its POSIX mode is 0600.
        // Read the ACL from the already verified descriptor, not the mutable path.
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else {
            // Darwin uses ENOENT for a valid open file with no extended ACL.
            if errno == ENOENT { return }
            throw CloudCredentialError.unsafeSetupFile
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        guard acl_valid(acl) == 0 else { throw CloudCredentialError.unsafeSetupFile }
        let unsafePermissions = acl_permset_mask_t(
            ACL_READ_DATA.rawValue | ACL_WRITE_DATA.rawValue | ACL_APPEND_DATA.rawValue
                | ACL_WRITE_SECURITY.rawValue | ACL_CHANGE_OWNER.rawValue
        )
        var selector = ACL_FIRST_ENTRY.rawValue
        while true {
            var entry: acl_entry_t?
            if acl_get_entry(acl, selector, &entry) != 0 {
                // Darwin reports EINVAL when a valid ACL has no further entries.
                guard errno == EINVAL else { throw CloudCredentialError.unsafeSetupFile }
                return
            }
            selector = ACL_NEXT_ENTRY.rawValue
            guard let entry else { throw CloudCredentialError.unsafeSetupFile }
            var tag = ACL_UNDEFINED_TAG
            guard acl_get_tag_type(entry, &tag) == 0 else { throw CloudCredentialError.unsafeSetupFile }
            if tag == ACL_EXTENDED_DENY { continue }
            guard tag == ACL_EXTENDED_ALLOW else { throw CloudCredentialError.unsafeSetupFile }
            var permissions: acl_permset_mask_t = 0
            guard acl_get_permset_mask_np(entry, &permissions) == 0,
                  permissions & unsafePermissions == 0 else {
                throw CloudCredentialError.unsafeSetupFile
            }
        }
    }

    private static func validate(_ configuration: PersonalCloudConfiguration) throws {
        guard let components = URLComponents(url: configuration.apiURL, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https", let host = components.host, !host.isEmpty,
              components.user == nil, components.password == nil,
              components.query == nil, components.fragment == nil else {
            throw CloudCredentialError.invalidAPIURL
        }
        let forbidden = CharacterSet.whitespacesAndNewlines.union(.controlCharacters)
        guard configuration.deviceToken.count >= 32,
              configuration.deviceToken.rangeOfCharacter(from: forbidden) == nil else {
            throw CloudCredentialError.invalidDeviceToken
        }
    }

    private static func decode(_ data: Data) throws -> PersonalCloudConfiguration {
        let configuration: PersonalCloudConfiguration
        do {
            configuration = try JSONDecoder().decode(PersonalCloudConfiguration.self, from: data)
        } catch {
            // Decoding errors can embed input values. Never forward those descriptions.
            throw CloudCredentialError.invalidConfigurationData
        }
        try validate(configuration)
        return configuration
    }

    private static func readSetupData(from descriptor: Int32) throws -> Data {
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        var data = Data()
        do {
            while data.count <= maximumSetupBytes {
                let remaining = maximumSetupBytes + 1 - data.count
                guard let chunk = try handle.read(upToCount: min(4096, remaining)), !chunk.isEmpty else { break }
                data.append(chunk)
            }
        } catch {
            throw CloudCredentialError.setupFileReadFailed
        }
        guard data.count <= maximumSetupBytes else { throw CloudCredentialError.invalidConfigurationData }
        return data
    }

    private static func isSameFile(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino && first.st_size == second.st_size
            && first.st_uid == second.st_uid && first.st_mode == second.st_mode
            && first.st_mtimespec.tv_sec == second.st_mtimespec.tv_sec
            && first.st_mtimespec.tv_nsec == second.st_mtimespec.tv_nsec
            && first.st_ctimespec.tv_sec == second.st_ctimespec.tv_sec
            && first.st_ctimespec.tv_nsec == second.st_ctimespec.tv_nsec
    }
}

enum CloudCredentials {
    private static let store = CloudCredentialStore(persistence: LoginKeychainCredentialPersistence())

    static func load() throws -> PersonalCloudConfiguration? { try store.load() }
    static func save(_ configuration: PersonalCloudConfiguration) throws { try store.save(configuration) }
    static func delete() throws { try store.delete() }

    @discardableResult
    static func importSetupFile(at url: URL) throws -> Bool { try store.importSetupFile(at: url) }
}

/// Intentional deployment policy for the current, non-sandboxed macOS app:
/// use the user's local login Keychain and its app ACL, without iCloud synchronization.
/// This is not the Data Protection Keychain and does not claim ThisDeviceOnly semantics.
/// That alternative requires authorized Keychain entitlements/provisioning in this app.
private struct LoginKeychainCredentialPersistence: CloudCredentialPersistence {
    private var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "com.rutmehta.lenscap.personal-cloud",
            kSecAttrAccount as String: "device",
            kSecUseDataProtectionKeychain as String: false,
            kSecAttrSynchronizable as String: false
        ]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw CloudCredentialError.keychain(status) }
        guard let data = result as? Data else { throw CloudCredentialError.invalidConfigurationData }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        var status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var request = query
            request[kSecValueData as String] = data
            request[kSecAttrLabel as String] = "Lenscap Personal Cloud"
            status = SecItemAdd(request as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw CloudCredentialError.keychain(status) }
    }

    func delete() throws {
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw CloudCredentialError.keychain(status)
        }
    }
}
