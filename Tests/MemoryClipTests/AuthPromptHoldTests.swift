@testable import MemoryClip
import Testing

struct AuthPromptHoldTests {
    @Test func `resign without prompt hides`() {
        var hold = AuthPromptHold()
        let hides = hold.resign()
        #expect(hides)
    }

    @Test func `resign during prompt keeps panel`() {
        var hold = AuthPromptHold()
        hold.begin()
        let hidesOnResign = hold.resign()
        let hidesOnEnd = hold.end(appIsActive: true)
        #expect(!hidesOnResign)
        #expect(!hidesOnEnd)
    }

    @Test func `prompt ending while inactive hides`() {
        var hold = AuthPromptHold()
        hold.begin()
        _ = hold.resign()
        let hidesOnEnd = hold.end(appIsActive: false)
        let hidesAfter = hold.resign()
        #expect(hidesOnEnd)
        #expect(hidesAfter)
    }

    @Test func `nested prompts hide only after the last`() {
        var hold = AuthPromptHold()
        hold.begin()
        hold.begin()
        _ = hold.resign()
        let first = hold.end(appIsActive: false)
        let last = hold.end(appIsActive: false)
        #expect(!first)
        #expect(last)
    }

    @Test func `end without resign never hides`() {
        var hold = AuthPromptHold()
        hold.begin()
        let hides = hold.end(appIsActive: false)
        #expect(!hides)
    }
}
