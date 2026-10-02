import AppKit
import Foundation
import LocalAuthentication
import Security

/// The panel-facing side of secrets: opening a row's cipher, writing its
/// plaintext as a concealed pasteboard string, and the calls around both
/// ("Not a Secret" demotion, the auth-failure line).
///
/// Every open lands in `SecretVault.open`, whose Secure Enclave key demands
/// user presence — and whose `LAContext` reuses one approval for 60 s, which
/// is what makes a queue run or a reveal-then-paste a single prompt.
///
/// Owns no UI state: the 30 s reveal window is the panel's to run, because
/// it ends on screen ("Hides in 30 s") and dies with the pane that showed it.
@MainActor
final class SecretsService {
    private let store: ClipStore
    private let pasteService: PasteService

    init(store: ClipStore, pasteService: PasteService) {
        self.store = store
        self.pasteService = pasteService
    }

    /// The vault the store was built with, or nil for a store that has none
    /// (an in-memory test store that did not bring one).
    private var vault: SecretVault? { store.secrets }

    /// Whether `error` is the user declining the prompt — the case the panel
    /// answers with its quiet "Not authenticated." line rather than a
    /// failure message.
    static func isAuthCancel(_ error: Error) -> Bool {
        if let laError = error as? LAError {
            return [.userCancel, .systemCancel, .appCancel].contains(laError.code)
        }
        // The enclave's key agreement reports a declined prompt as
        // errSecUserCanceled, not LAError — same refusal, different costume.
        let nsError = error as NSError
        return nsError.domain == NSOSStatusErrorDomain && nsError.code == Int(errSecUserCanceled)
    }

    /// Open a secret row's cipher and return the plaintext.
    ///
    /// The open runs off the main actor: the user-presence prompt blocks its
    /// caller until the user answers, and that cannot be the thread the
    /// panel is drawn on.
    func reveal(_ item: ClipItem) async -> Result<String, Error> {
        guard let vault, let cipher = item.secretCipher else {
            return .failure(SecretSealerError.malformedSealedData)
        }
        return await Task.detached(priority: .userInitiated) { () -> Result<String, Error> in
            do {
                let data = try vault.open(cipher)
                guard let text = String(data: data, encoding: .utf8) else {
                    return .failure(SecretSealerError.malformedSealedData)
                }
                return .success(text)
            } catch {
                return .failure(error)
            }
        }.value
    }

    /// Authenticate, then put the secret on the pasteboard as plain text —
    /// concealed, and armed for the clear-after-paste pass. No ⌘V: this is
    /// the dropdown's and ⌘C's answer, not Return's.
    ///
    /// - Returns: whether the plaintext is now on the pasteboard.
    func copy(_ item: ClipItem) async -> Bool {
        guard case .success(let text) = await reveal(item) else { return false }
        return pasteService.copyConcealed(text: text, item: item)
    }

    /// Authenticate, then paste the secret into `target` — a concealed
    /// write plus the synthetic ⌘V when auto-paste is on.
    func paste(_ item: ClipItem, target: NSRunningApplication?) async -> Bool {
        guard case .success(let text) = await reveal(item) else { return false }
        return pasteService.pasteConcealed(text: text, item: item, target: target)
    }

    /// The queue-run spelling of `paste`: a `PasteOutcome` the run can
    /// switch on. A run of secrets prompts once — the sealer's reuse window
    /// covers every open between the first and the last.
    func pasteOutcome(_ item: ClipItem, target: NSRunningApplication?) async -> PasteService.PasteOutcome {
        guard case .success(let text) = await reveal(item) else { return .failed }
        return await pasteService.pasteConcealedAndWait(text: text, item: item, target: target)
    }

    /// "Not a Secret": authenticate by opening the cipher once — the verdict
    /// and the plaintext the row is demoted to both come from that open —
    /// then make the row ordinary and allow-list its hash.
    func markNotSecret(_ item: ClipItem) async -> Bool {
        guard case .success(let text) = await reveal(item) else { return false }
        store.markNotSecret(item, plaintext: text)
        return true
    }

    /// "Mark as Secret" — sealing touches only the enclave's public key, so
    /// it needs no prompt.
    func markAsSecret(_ item: ClipItem) -> Bool {
        store.markAsSecret(item)
    }
}
