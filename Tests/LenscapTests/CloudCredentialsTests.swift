import Foundation
import XCTest
@testable import Lenscap

final class CloudCredentialsTests: XCTestCase {
    private let configuration = PersonalCloudConfiguration(
        apiURL: URL(string: "https://example.invalid/lenscap")!,
        deviceToken: String(repeating: "a", count: 40),
        projectID: "test-project"
    )

    func testEmptyStorageHasNoCloudConfiguration() throws {
        let store = CloudCredentialStore(persistence: MemoryCloudCredentialPersistence())
        XCTAssertNil(try store.load())
    }

    func testSaveRoundTripsConfigurationUsingTheSetupJSONKeys() throws {
        let persistence = MemoryCloudCredentialPersistence()
        let store = CloudCredentialStore(persistence: persistence)

        try store.save(configuration)

        XCTAssertEqual(try store.load(), configuration)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: XCTUnwrap(persistence.data)) as? [String: String])
        XCTAssertEqual(Set(object.keys), ["apiURL", "deviceToken", "projectID"])
        XCTAssertEqual(object["apiURL"], "https://example.invalid/lenscap")
        XCTAssertEqual(object["projectID"], "test-project")
    }

    func testExplicitSaveCanReconnectAndDeleteRemovesTheConfiguration() throws {
        let persistence = MemoryCloudCredentialPersistence()
        let store = CloudCredentialStore(persistence: persistence)
        try store.save(configuration)
        let replacement = PersonalCloudConfiguration(
            apiURL: URL(string: "https://another.invalid/api")!,
            deviceToken: String(repeating: "b", count: 40), projectID: nil
        )

        try store.save(replacement)
        XCTAssertEqual(try store.load(), replacement)

        try store.delete()
        XCTAssertNil(try store.load())
    }

    func testSaveRejectsUnsafeEndpointURLsBeforeWriting() {
        let endpoints = [
            "http://example.invalid", "ftp://example.invalid", "https:relative",
            "https://user@example.invalid", "https://user:password@example.invalid",
            "https://example.invalid?token=secret", "https://example.invalid#fragment",
            "file:///tmp/cloud", "/relative"
        ]
        for endpoint in endpoints {
            let persistence = MemoryCloudCredentialPersistence()
            let store = CloudCredentialStore(persistence: persistence)
            let invalid = PersonalCloudConfiguration(apiURL: URL(string: endpoint)!,
                                                     deviceToken: configuration.deviceToken, projectID: nil)

            XCTAssertThrowsError(try store.save(invalid)) { error in
                XCTAssertEqual(error as? CloudCredentialError, .invalidAPIURL)
            }
            XCTAssertEqual(persistence.writeCount, 0)
        }
    }

    func testSaveRejectsShortOrWhitespaceTokensBeforeWriting() {
        for token in ["", "short", String(repeating: "a", count: 31), String(repeating: " ", count: 40),
                      String(repeating: "a", count: 40) + "\n"] {
            let persistence = MemoryCloudCredentialPersistence()
            let store = CloudCredentialStore(persistence: persistence)
            let invalid = PersonalCloudConfiguration(apiURL: configuration.apiURL, deviceToken: token, projectID: nil)

            XCTAssertThrowsError(try store.save(invalid)) { error in
                XCTAssertEqual(error as? CloudCredentialError, .invalidDeviceToken)
            }
            XCTAssertEqual(persistence.writeCount, 0)
        }
    }

    func testMalformedStoredDataIsNotAccepted() {
        let persistence = MemoryCloudCredentialPersistence()
        persistence.data = Data("not JSON".utf8)
        let store = CloudCredentialStore(persistence: persistence)

        XCTAssertThrowsError(try store.load()) { error in
            XCTAssertEqual(error as? CloudCredentialError, .invalidConfigurationData)
        }
    }

    func testMissingSetupFileLeavesCloudUnconfigured() throws {
        try withTemporaryDirectory { directory in
            let persistence = MemoryCloudCredentialPersistence()
            let store = CloudCredentialStore(persistence: persistence)

            XCTAssertFalse(try store.importSetupFile(at: directory.appendingPathComponent("missing.json")))
            XCTAssertNil(persistence.data)
        }
    }

    func testImportSavesAndReadsBackBeforeRemovingTheSetupFile() throws {
        try withSetupFile { url in
            let persistence = MemoryCloudCredentialPersistence()
            let store = CloudCredentialStore(persistence: persistence)
            var verifiedWhileFileStillExisted = false
            persistence.onRead = { data in
                if data != nil {
                    verifiedWhileFileStillExisted = FileManager.default.fileExists(atPath: url.path)
                }
            }

            XCTAssertTrue(try store.importSetupFile(at: url))

            XCTAssertTrue(verifiedWhileFileStillExisted)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try store.load(), configuration)
        }
    }

    func testImportRejectsGroupOrWorldReadableOrWritableSetupFiles() throws {
        for mode in [0o640, 0o620, 0o604, 0o602, 0o666] {
            try withSetupFile(mode: mode) { url in
                let persistence = MemoryCloudCredentialPersistence()
                let store = CloudCredentialStore(persistence: persistence)

                XCTAssertThrowsError(try store.importSetupFile(at: url)) { error in
                    XCTAssertEqual(error as? CloudCredentialError, .unsafeSetupFile)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                XCTAssertEqual(persistence.writeCount, 0)
            }
        }
    }

    func testImportRejectsACLGrantsEvenWhenPOSIXPermissionsArePrivate() throws {
        for permission in ["read", "write", "append", "writesecurity", "chown"] {
            try withSetupFile { url in
                try addACL("everyone allow \(permission)", to: url)
                let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
                XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
                let persistence = MemoryCloudCredentialPersistence()
                let store = CloudCredentialStore(persistence: persistence)

                XCTAssertThrowsError(try store.importSetupFile(at: url)) { error in
                    XCTAssertEqual(error as? CloudCredentialError, .unsafeSetupFile)
                }
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
                XCTAssertEqual(persistence.writeCount, 0)
            }
        }
    }

    func testRestrictiveACLDoesNotPreventPrivateSetupImport() throws {
        try withSetupFile { url in
            try addACL("everyone deny execute", to: url)
            let store = CloudCredentialStore(persistence: MemoryCloudCredentialPersistence())

            XCTAssertTrue(try store.importSetupFile(at: url))
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testImportRejectsSymlinksAndLeavesTheirTargetsUntouched() throws {
        try withSetupFile { target in
            let link = target.deletingLastPathComponent().appendingPathComponent("link.json")
            try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
            let persistence = MemoryCloudCredentialPersistence()
            let store = CloudCredentialStore(persistence: persistence)

            XCTAssertThrowsError(try store.importSetupFile(at: link)) { error in
                XCTAssertEqual(error as? CloudCredentialError, .unsafeSetupFile)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: target.path))
            XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: link.path))
            XCTAssertEqual(persistence.writeCount, 0)
        }
    }

    func testImportRejectsDirectoriesAndRemoteURLs() throws {
        try withTemporaryDirectory { directory in
            let persistence = MemoryCloudCredentialPersistence()
            let store = CloudCredentialStore(persistence: persistence)
            for url in [directory, URL(string: "https://example.invalid/cloud-setup.json")!] {
                XCTAssertThrowsError(try store.importSetupFile(at: url)) { error in
                    XCTAssertEqual(error as? CloudCredentialError, .unsafeSetupFile)
                }
            }
            XCTAssertEqual(persistence.writeCount, 0)
        }
    }

    func testInvalidSetupConfigurationIsRetainedWithoutWriting() throws {
        try withSetupFile(contents: Data("{\"deviceToken\":\"invalid\"}".utf8)) { url in
            let persistence = MemoryCloudCredentialPersistence()
            let store = CloudCredentialStore(persistence: persistence)

            XCTAssertThrowsError(try store.importSetupFile(at: url))
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(persistence.writeCount, 0)
        }
    }

    func testPersistenceFailureRetainsTheSetupAndDoesNotExposeTheTokenInErrors() throws {
        try withSetupFile { url in
            let persistence = MemoryCloudCredentialPersistence()
            persistence.writeError = NSError(domain: configuration.deviceToken, code: 1)
            let store = CloudCredentialStore(persistence: persistence)

            XCTAssertThrowsError(try store.importSetupFile(at: url)) { error in
                XCTAssertEqual(error as? CloudCredentialError, .storageWriteFailed)
                XCTAssertFalse(error.localizedDescription.contains(self.configuration.deviceToken))
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertNil(persistence.data)
        }
    }

    func testUnconfirmedStorageWriteRetainsTheSetupFile() throws {
        try withSetupFile { url in
            let persistence = MemoryCloudCredentialPersistence()
            persistence.discardWrites = true
            let store = CloudCredentialStore(persistence: persistence)

            XCTAssertThrowsError(try store.importSetupFile(at: url)) { error in
                XCTAssertEqual(error as? CloudCredentialError, .storageVerificationFailed)
            }
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
        }
    }

    func testImportDoesNotOverwriteADifferentExistingEndpointOrAccount() throws {
        let existingConfigurations = [
            PersonalCloudConfiguration(apiURL: URL(string: "https://another.invalid/api")!,
                                       deviceToken: configuration.deviceToken, projectID: configuration.projectID),
            PersonalCloudConfiguration(apiURL: configuration.apiURL,
                                       deviceToken: String(repeating: "b", count: 40), projectID: configuration.projectID),
            PersonalCloudConfiguration(apiURL: configuration.apiURL,
                                       deviceToken: configuration.deviceToken, projectID: "another-project")
        ]
        for existing in existingConfigurations {
            try withSetupFile { url in
                let persistence = MemoryCloudCredentialPersistence()
                persistence.data = try JSONEncoder().encode(existing)
                let store = CloudCredentialStore(persistence: persistence)

                XCTAssertThrowsError(try store.importSetupFile(at: url)) { error in
                    XCTAssertEqual(error as? CloudCredentialError, .alreadyConfigured)
                }
                XCTAssertEqual(try store.load(), existing)
                XCTAssertEqual(persistence.writeCount, 0)
                XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            }
        }
    }

    func testIdenticalExistingConfigurationAllowsRemovingDuplicateSetup() throws {
        try withSetupFile { url in
            let persistence = MemoryCloudCredentialPersistence()
            persistence.data = try JSONEncoder().encode(configuration)
            let store = CloudCredentialStore(persistence: persistence)

            XCTAssertTrue(try store.importSetupFile(at: url))
            XCTAssertEqual(try store.load(), configuration)
            XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
        }
    }

    private func withSetupFile(mode: Int = 0o600, contents: Data? = nil,
                               body: (URL) throws -> Void) throws {
        try withTemporaryDirectory { directory in
            let url = directory.appendingPathComponent("cloud-setup.json")
            let data = try contents ?? JSONEncoder().encode(configuration)
            guard FileManager.default.createFile(atPath: url.path, contents: data,
                                                  attributes: [.posixPermissions: mode]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            // Explicit mode avoids dependence on the test runner's umask.
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
            try body(url)
        }
    }

    private func addACL(_ entry: String, to url: URL) throws {
        // Only this test's private temporary fixture is changed; no user files or Keychain items.
        let command = Process()
        command.executableURL = URL(fileURLWithPath: "/bin/chmod")
        command.arguments = ["+a", entry, url.path]
        command.standardOutput = Pipe()
        command.standardError = Pipe()
        try command.run()
        command.waitUntilExit()
        guard command.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
    }

    private func withTemporaryDirectory(_ body: (URL) throws -> Void) throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LenscapCloudCredentialsTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        try body(directory)
    }
}

private final class MemoryCloudCredentialPersistence: CloudCredentialPersistence {
    var data: Data?
    var writeError: Error?
    var discardWrites = false
    var writeCount = 0
    var onRead: ((Data?) -> Void)?

    func read() throws -> Data? {
        onRead?(data)
        return data
    }

    func write(_ data: Data) throws {
        writeCount += 1
        if let writeError { throw writeError }
        if !discardWrites { self.data = data }
    }

    func delete() throws { data = nil }
}
