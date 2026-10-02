import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// Boundary between the secrets feature and whoever does the cryptography.
///
/// The protocol exists so the round trip is testable with a software key: CI
/// has no Secure Enclave, so `SecureEnclaveSealer` below is exercised by the
/// `--secrets-selftest` launch argument on a Mac instead (see
/// `SecretsSelfTest`), not by `swift test`.
/// `Sendable` because `open` deliberately runs off the main actor: the
/// enclave's user-presence prompt blocks its caller until the user answers,
/// and a reveal must not freeze the panel while the prompt is up.
protocol SecretSealer: Sendable {
    /// Seal `plaintext`. Never prompts: sealing only needs public keys.
    func seal(_ plaintext: Data) throws -> Data

    /// Recover the plaintext. The enclave implementation demands user
    /// presence here (Touch ID, or the account password as fallback).
    func open(_ sealed: Data) throws -> Data
}

enum SecretSealerError: Error {
    /// This machine has no Secure Enclave to hold the key.
    case secureEnclaveUnavailable
    /// The access-control object for a new key could not be created.
    case accessControlFailed
    /// The persisted key handle exists but cannot be read back.
    case keyHandleUnreadable
    /// A sealed payload is too short to contain all its parts.
    case malformedSealedData
    /// An owner-only file could not be written.
    case fileWriteFailed
}

/// Seals with a P-256 key-agreement key that never leaves the Secure Enclave.
///
/// The key is created with `.privateKeyUsage + .userPresence`, so *using* it
/// (the key agreement inside `open`) demands user presence while everything
/// on the `seal` path touches only the public key and a fresh ephemeral key:
/// encryption can never prompt.
///
/// `open` rides on one `LAContext` whose 60 s reuse duration means a run of
/// reveals prompts once, the same window `AppLockService.unlockWindow` gives
/// the app lock. CryptoKit binds the context to the key at creation or load
/// (`init(..., authenticationContext:)`); the agreement call itself takes
/// none.
///
/// The key is persisted as its `dataRepresentation`, an opaque handle only
/// this Mac's enclave can unwrap, written 0600 into the store directory. It
/// is deliberately not a keychain item: the app is ad-hoc signed, and a
/// login-keychain ACL is keyed to the code signature, which changes on every
/// rebuild.
/// `@unchecked Sendable`: the `privateKey` handle is an immutable value
/// and `authenticationContext` is configured once at init and only read
/// afterwards — `open` touches both but mutates neither, so concurrent
/// reveals are safe (the system serialises the prompts itself).
final class SecureEnclaveSealer: SecretSealer, @unchecked Sendable {
    /// Name of the persisted key-handle file inside the store directory.
    static let keyFileName = "secrets-enclave.key"

    /// Seconds one user-presence approval is reused; matches
    /// `AppLockService.unlockWindow`.
    static let authenticationReuseSeconds: TimeInterval = 60

    /// Byte layout of a sealed payload: the 65-byte uncompressed x963
    /// ephemeral public key, then `AES.GCM.SealedBox.combined`, which is
    /// `nonce || ciphertext || tag` (12-byte nonce, 16-byte tag).
    private static let ephemeralKeyLength = 65
    private static let nonceLength = 12
    private static let tagLength = 16

    private static let hkdfSalt = Data("app.memoryclip.secrets.salt".utf8)
    private static let hkdfInfo = Data("app.memoryclip.secrets.v1".utf8)

    /// One context for the sealer's life, so opens within
    /// `authenticationReuseSeconds` of each other prompt only once.
    private let authenticationContext = LAContext()

    private let privateKey: SecureEnclave.P256.KeyAgreement.PrivateKey

    /// `directory` is the store directory (`ClipStore.storeDirectory`). It is
    /// created owner-only here too, so the self-test can run without opening
    /// the store first.
    init(directory: URL) throws {
        guard SecureEnclave.isAvailable else {
            throw SecretSealerError.secureEnclaveUnavailable
        }
        try Self.ensureDirectory(directory)

        authenticationContext.touchIDAuthenticationAllowableReuseDuration =
            Self.authenticationReuseSeconds

        let keyURL = directory.appendingPathComponent(Self.keyFileName)
        if FileManager.default.fileExists(atPath: keyURL.path) {
            guard let data = try? Data(contentsOf: keyURL),
                  let key = try? SecureEnclave.P256.KeyAgreement.PrivateKey(
                      dataRepresentation: data,
                      authenticationContext: authenticationContext
                  ) else {
                // A handle that cannot be read back would silently orphan
                // every secret it ever sealed, so it fails loudly rather
                // than being overwritten.
                throw SecretSealerError.keyHandleUnreadable
            }
            privateKey = key
        } else {
            var accessError: Unmanaged<CFError>?
            guard let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleWhenUnlockedThisDeviceOnly,
                [.privateKeyUsage, .userPresence],
                &accessError
            ) else {
                if let cfError = accessError?.takeRetainedValue() {
                    throw cfError as Error
                }
                throw SecretSealerError.accessControlFailed
            }
            privateKey = try SecureEnclave.P256.KeyAgreement.PrivateKey(
                accessControl: access,
                authenticationContext: authenticationContext
            )
            try Self.writeOwnerOnly(privateKey.dataRepresentation, to: keyURL)
        }
    }

    /// Ephemeral P-256 agreement with the enclave key's public key,
    /// HKDF-SHA256, AES-GCM. Nothing on this path can prompt.
    func seal(_ plaintext: Data) throws -> Data {
        let ephemeral = P256.KeyAgreement.PrivateKey()
        let shared = try ephemeral.sharedSecretFromKeyAgreement(with: privateKey.publicKey)
        let box = try AES.GCM.seal(plaintext, using: Self.deriveKey(from: shared))
        guard let combined = box.combined else {
            throw SecretSealerError.malformedSealedData
        }
        var payload = ephemeral.publicKey.x963Representation
        payload.append(combined)
        return payload
    }

    /// The key agreement on the enclave private key is the step that demands
    /// user presence, evaluated against `authenticationContext`.
    func open(_ sealed: Data) throws -> Data {
        let headerLength = Self.ephemeralKeyLength + Self.nonceLength + Self.tagLength
        guard sealed.count > headerLength else {
            throw SecretSealerError.malformedSealedData
        }
        let ephemeralPublicKey = try P256.KeyAgreement.PublicKey(
            x963Representation: sealed.prefix(Self.ephemeralKeyLength)
        )
        let box = try AES.GCM.SealedBox(combined: sealed.dropFirst(Self.ephemeralKeyLength))
        let shared = try privateKey.sharedSecretFromKeyAgreement(with: ephemeralPublicKey)
        return try AES.GCM.open(box, using: Self.deriveKey(from: shared))
    }

    /// HKDF-SHA256 over the agreed secret, salted and labelled for this app
    /// so the derived key cannot be mistaken for another protocol's.
    private static func deriveKey(from shared: SharedSecret) -> SymmetricKey {
        shared.hkdfDerivedSymmetricKey(
            using: SHA256.self,
            salt: hkdfSalt,
            sharedInfo: hkdfInfo,
            outputByteCount: 32
        )
    }

    /// Create `directory` owner-only, tightening it when it already exists.
    static func ensureDirectory(_ directory: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: directory.path) {
            try? fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        } else {
            try fileManager.createDirectory(
                at: directory,
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
        }
    }

    /// Write `data` at mode 0600: created with the mode set (so the bytes are
    /// never world-readable) and tightened again after an overwrite.
    static func writeOwnerOnly(_ data: Data, to url: URL) throws {
        let fileManager = FileManager.default
        if fileManager.fileExists(atPath: url.path) {
            try data.write(to: url, options: .atomic)
        } else if !fileManager.createFile(
            atPath: url.path,
            contents: data,
            attributes: [.posixPermissions: 0o600]
        ) {
            throw SecretSealerError.fileWriteFailed
        }
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
