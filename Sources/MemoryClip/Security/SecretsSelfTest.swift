import Foundation

/// Manual probe for the secrets design: proves on a real Mac what CI never
/// can, since CI has neither a Secure Enclave nor a biometric prompt.
///
///     dist/MemoryClip.app/Contents/MacOS/MemoryClip --secrets-selftest
///
/// The run prints one numbered PASS/FAIL line per check and exits:
///   1. the `.userPresence` enclave key is created (first run) or reloaded
///      from its persisted handle;
///   2. the persisted handle file is mode 0600;
///   3. sealing needs no private key, so it cannot prompt;
///   4. opening demands user presence (the prompt is the check) and returns
///      the plaintext;
///   5. a second open inside the LAContext reuse window does not prompt
///      again;
///   6. a payload sealed by a previous run still opens: the persisted key
///      survives the binary being rebuilt ad-hoc.
///
/// Check 6 is the one that needs two runs: build with `Scripts/make_app.sh`,
/// run once, rebuild, run again.
enum SecretsSelfTest {
    static let launchArgument = "--secrets-selftest"

    static var isRequested: Bool {
        CommandLine.arguments.contains(launchArgument)
    }

    /// Payload file each run leaves behind so the NEXT binary can prove it
    /// still opens ciphertext produced before it existed.
    private static let sealedFileName = "secrets-selftest.sealed"

    private static let probePlaintext = Data("memoryclip-secrets-selftest".utf8)

    @MainActor
    static func runAndExit() -> Never {
        var failures = 0
        func emit(_ line: String) {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        }
        func pass(_ check: Int, _ detail: String) {
            emit("PASS \(check): \(detail)")
        }
        func fail(_ check: Int, _ detail: String) {
            failures += 1
            emit("FAIL \(check): \(detail)")
        }
        func info(_ detail: String) {
            emit("INFO: \(detail)")
        }

        let directory = ClipStore.storeDirectory
        let keyURL = directory.appendingPathComponent(SecureEnclaveSealer.keyFileName)
        let sealedURL = directory.appendingPathComponent(Self.sealedFileName)
        let fileManager = FileManager.default
        let keyExisted = fileManager.fileExists(atPath: keyURL.path)
        let sealedExisted = fileManager.fileExists(atPath: sealedURL.path)

        emit("MemoryClip secrets self-test")
        info("store directory: \(directory.path)")

        // (a) Create the `.userPresence` key on first run, or reload the
        // persisted handle on later ones.
        let sealer: SecureEnclaveSealer
        do {
            sealer = try SecureEnclaveSealer(directory: directory)
            if keyExisted {
                pass(1, "(a) reloaded the persisted Secure Enclave key handle")
            } else {
                pass(1, "(a) created a Secure Enclave key with .privateKeyUsage + .userPresence")
            }
        } catch {
            fail(1, "(a) Secure Enclave key unavailable: \(error.localizedDescription)")
            emit("SELFTEST RESULT: FAIL (no key, remaining checks skipped)")
            exit(1)
        }

        // The persisted handle must be owner-only.
        if let mode = (try? fileManager.attributesOfItem(atPath: keyURL.path))?[.posixPermissions] as? Int {
            if mode == 0o600 {
                pass(2, "(a) persisted key handle \(keyURL.lastPathComponent) is mode 0600")
            } else {
                fail(2, "(a) key handle mode is \(String(mode, radix: 8)), expected 600")
            }
        } else {
            fail(2, "(a) could not stat the key handle at \(keyURL.lastPathComponent)")
        }

        // (b) Seal: public-key work only, so no prompt is possible.
        let sealed: Data
        do {
            sealed = try sealer.seal(Self.probePlaintext)
            let expected = 65 + 12 + Self.probePlaintext.count + 16
            if sealed.count == expected {
                pass(3, "(b) sealed \(Self.probePlaintext.count) bytes into \(sealed.count) (ephemeralPublicKey || nonce || ciphertext || tag); no private-key use, no prompt")
            } else {
                fail(3, "(b) sealed payload is \(sealed.count) bytes, expected \(expected)")
            }
        } catch {
            fail(3, "(b) seal failed: \(error.localizedDescription)")
            emit("SELFTEST RESULT: FAIL")
            exit(1)
        }

        // (c) Open: the key agreement demands user presence.
        info("check 4 opens the payload; a Touch ID (or password) prompt is expected now")
        do {
            let opened = try sealer.open(sealed)
            if opened == Self.probePlaintext {
                pass(4, "(c) open returned the plaintext after user presence")
            } else {
                fail(4, "(c) open returned different bytes")
            }
        } catch {
            fail(4, "(c) open failed: \(error.localizedDescription)")
            emit("SELFTEST RESULT: FAIL")
            exit(1)
        }

        // Same open again inside the LAContext reuse window.
        info("check 5 opens again inside the 60 s reuse window; no second prompt should appear")
        do {
            let opened = try sealer.open(sealed)
            if opened == Self.probePlaintext {
                pass(5, "(c) second open succeeded; if no prompt appeared, the LAContext reuse window held")
            } else {
                fail(5, "(c) second open returned different bytes")
            }
        } catch {
            fail(5, "(c) second open failed: \(error.localizedDescription)")
        }

        // (d) The persisted key still opens a payload written by the previous
        // binary, which is the whole point of the probe: an ad-hoc rebuild
        // must not orphan the secrets.
        switch (keyExisted, sealedExisted) {
        case (true, true):
            do {
                let prior = try Data(contentsOf: sealedURL)
                let reopened = try sealer.open(prior)
                if reopened == Self.probePlaintext {
                    pass(6, "(d) ciphertext written by an earlier run opened; with a rebuild between runs this proves the persisted key survives a replaced binary")
                } else {
                    fail(6, "(d) earlier ciphertext opened to different bytes")
                }
            } catch {
                fail(6, "(d) could not open the earlier run's payload: \(error.localizedDescription)")
            }
        case (true, false):
            pass(6, "(d) persisted key handle from an earlier run loaded and opened payloads in this binary (no prior payload file to cross-check)")
        case (false, true):
            fail(6, "(d) found \(Self.sealedFileName) but no key file; delete both under \(directory.lastPathComponent) and run again")
        case (false, false):
            info("check 6 (d) is PENDING: this first run wrote the key and a sealed payload; rebuild with Scripts/make_app.sh and run the self-test again")
        }

        // Leave fresh ciphertext for the next binary to open.
        do {
            try SecureEnclaveSealer.writeOwnerOnly(sealed, to: sealedURL)
        } catch {
            info("could not write \(Self.sealedFileName): \(error.localizedDescription)")
        }

        emit("SELFTEST RESULT: \(failures == 0 ? "PASS" : "FAIL (\(failures) check(s))")")
        exit(failures == 0 ? 0 : 1)
    }
}
