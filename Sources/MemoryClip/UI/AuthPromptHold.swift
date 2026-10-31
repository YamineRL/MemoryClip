/// Keeps the panel up while one of its own Touch ID prompts is on screen.
///
/// The prompt belongs to a system process, so it takes activation from the
/// app; without the hold, `appDidResignActive` hides the panel the moment the
/// prompt appears. A resign that arrives during a hold is remembered and acted
/// on when the last prompt ends, if the app is still inactive by then.
struct AuthPromptHold: Equatable {
    private(set) var depth = 0
    private(set) var deferredResign = false

    var isHolding: Bool { depth > 0 }

    mutating func begin() {
        depth += 1
    }

    /// True when the resign should hide the panel now.
    mutating func resign() -> Bool {
        guard isHolding else { return true }
        deferredResign = true
        return false
    }

    /// True when the panel should hide now: the last prompt ended, a resign
    /// came in during it, and the app is still not active.
    mutating func end(appIsActive: Bool) -> Bool {
        depth = max(0, depth - 1)
        guard depth == 0, deferredResign else { return false }
        deferredResign = false
        return !appIsActive
    }
}
