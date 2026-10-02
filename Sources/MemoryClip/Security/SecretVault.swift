import CryptoKit
import Foundation

/// Everything about the secrets feature that lives in files next to the
/// store rather than inside it: the sealer, the HMAC key that makes secret
/// hashes, and the "Not a Secret" allow-list.
///
/// Neither file is itself a credential, but both sit in the protected set —
/// a copied store directory must not let an attacker re-derive secret
/// identity — so both are mode 0600 and both live for the life of the store.
final class SecretVault: @unchecked Sendable {

    /// Serialises the mutable slots — `enclaveSealer`, `dedupKeyCache`,
    /// `allowlistCache` — because `open` runs off the main actor (its prompt
    /// must not block the panel) while `seal`, `hash` and `allow` run on it.
    /// Held for whole calls: two reveals at once then serialise, which is
    /// what the prompts want anyway.
    private let lock = NSLock()

    /// A hash left in an "allow" list intentionally, versus one trying to
    /// *be* a hash, read back out of a clip's `contentHash` column. The
    /// domain label in the HMAC input keeps the two lists on different keys.
    enum HashUse: String {
        /// `contentHash` semantics: "this plaintext already lives in the
        /// store as a secret — refresh its row instead of adding a twin".
        case dedup
        /// The allow-list's semantics: "this plaintext has been judged not
        /// a secret — never classify it again".
        case allowlist
    }

    /// Where the feature's state lives: `ClipStore.storeDirectory` in the
    /// app, a temporary directory under tests.
    let directory: URL

    /// `sealer:` lets tests inject the software implementation; nil means
    /// the production default, resolved lazily on first use.
    init(directory: URL, sealer: (any SecretSealer)? = nil) {
        self.directory = directory
        self.injectedSealer = sealer
    }

    // MARK: - The sealer

    /// A sealer the caller brought (tests). When set, it wins over the
    /// enclave and is never rebuilt: its failures are the test's to see.
    private let injectedSealer: (any SecretSealer)?

    /// The production sealer once it has been resolved. Never cached while
    /// its init failed: an enclave key that cannot load must stay loud.
    private var enclaveSealer: (any SecretSealer)?

    /// The active sealer, or nil when the enclave cannot be built.
    ///
    /// An injected sealer is always returned untouched. Otherwise the
    /// persisted `SecureEnclaveSealer` is resolved once and reused — its
    /// init throws `keyHandleUnreadable` rather than silently orphan every
    /// secret a corrupt handle ever sealed, so a failure retries on the
    /// next call and stays loud.
    private func sealer() -> (any SecretSealer)? {
        if let injectedSealer { return injectedSealer }
        if let enclaveSealer { return enclaveSealer }
        let built = try? SecureEnclaveSealer(directory: directory)
        enclaveSealer = built
        return built
    }

    /// Seal a plaintext value for storage on a row.
    ///
    /// A failed seal is retried once against a freshly built sealer: the
    /// enclave key handle is a runtime object, and the one produced before a
    /// reboot is not valid after it. The persisted handle file is never
    /// deleted here — a rebuild that cannot load it is the loud failure the
    /// spike promised to keep.
    func seal(_ plaintext: String) throws -> Data {
        try seal(Data(plaintext.utf8))
    }

    func seal(_ plaintext: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let first = sealer() else {
            throw SecretSealerError.secureEnclaveUnavailable
        }
        do {
            return try first.seal(plaintext)
        } catch {
            guard injectedSealer == nil else { throw error }
            enclaveSealer = nil
            guard let rebuilt = sealer() else { throw error }
            return try rebuilt.seal(plaintext)
        }
    }

    /// Recover a row's plaintext. May prompt (Touch ID / password) — callers
    /// run this off the main actor so the prompt cannot freeze the panel.
    /// Same retry policy as `seal`: a stale key handle is rebuilt once.
    func open(_ sealed: Data) throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        guard let first = sealer() else {
            throw SecretSealerError.secureEnclaveUnavailable
        }
        do {
            return try first.open(sealed)
        } catch {
            guard injectedSealer == nil else { throw error }
            enclaveSealer = nil
            guard let rebuilt = sealer() else { throw error }
            return try rebuilt.open(sealed)
        }
    }

    // MARK: - Hashing

    /// The identity a secret clip gets: `HMAC-SHA256(key, "use:plaintext")`,
    /// hex.
    ///
    /// The key is local and unknowable off-device, so the hash cannot be
    /// precomputed against a dictionary of known credentials — a store
    /// exfiltration tells an attacker nothing about which clips map to
    /// which services. The `use` prefix keeps a hash written for dedup and
    /// a hash written into the allow-list from colliding: they are separate
    /// verdicts with separate names.
    func hash(_ plaintext: String, for use: HashUse) -> String {
        lock.lock()
        defer { lock.unlock() }
        let input = "\(use.rawValue):\(plaintext)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: dedupKey())
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    /// The 32-byte key that makes secret hashes. Created on first use in
    /// the store directory, mode 0600, and stable for the life of the
    /// store: rotating it would orphan every secret's `contentHash` and its
    /// dedup identity at once.
    private func dedupKey() -> SymmetricKey {
        if let dedupKeyCache { return dedupKeyCache }
        let url = directory.appendingPathComponent("secrets-dedup.key")
        if let raw = try? Data(contentsOf: url), raw.count == 32 {
            let key = SymmetricKey(data: raw)
            dedupKeyCache = key
            return key
        }
        let key = SymmetricKey(size: .bits256)
        try? SecureEnclaveSealer.ensureDirectory(directory)
        try? SecureEnclaveSealer.writeOwnerOnly(key.withUnsafeBytes { Data($0) }, to: url)
        dedupKeyCache = key
        return key
    }

    private var dedupKeyCache: SymmetricKey?

    // MARK: - The "Not a Secret" allow-list

    /// One allow-list hash per line. A plain text file: it is not a store
    /// of secrets, it is a store of *verdicts*, and an entry can only
    /// reclassify a clip whose plaintext is already in hand.
    private var allowlistURL: URL {
        directory.appendingPathComponent("secrets-allowlist")
    }

    /// Add a plaintext's hash.
    func allow(_ plaintext: String) {
        lock.lock()
        defer { lock.unlock() }
        let line = hashLocked(plaintext, for: .allowlist)
        guard !allowlistEntries().contains(line) else { return }
        let content = (allowlistContents() ?? "") + line + "\n"
        try? SecureEnclaveSealer.writeOwnerOnly(Data(content.utf8), to: allowlistURL)
        allowlistCache = nil
    }

    /// Whether this plaintext is on the allow-list.
    func allows(_ plaintext: String) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return allowlistEntries().contains(hashLocked(plaintext, for: .allowlist))
    }

    /// Forget the whole list ("Reset"). The file is deleted rather than
    /// truncated so a file that somehow became unreadable cannot keep
    /// swallowing new entries.
    func resetAllowlist() {
        lock.lock()
        defer { lock.unlock() }
        try? FileManager.default.removeItem(at: allowlistURL)
        allowlistCache = nil
    }

    /// `hash(_:for:)` for callers already holding `lock` — `allow` and
    /// `allows` must not take it twice (NSLock is not recursive).
    private func hashLocked(_ plaintext: String, for use: HashUse) -> String {
        let input = "\(use.rawValue):\(plaintext)"
        let mac = HMAC<SHA256>.authenticationCode(for: Data(input.utf8), using: dedupKey())
        return mac.map { String(format: "%02x", $0) }.joined()
    }

    private var allowlistCache: Set<String>?

    private func allowlistEntries() -> Set<String> {
        if let allowlistCache { return allowlistCache }
        let entries = Set(
            (allowlistContents() ?? "")
                .split(separator: "\n")
                .map(String.init)
        )
        allowlistCache = entries
        return entries
    }

    private func allowlistContents() -> String? {
        try? String(contentsOf: allowlistURL, encoding: .utf8)
    }
}
