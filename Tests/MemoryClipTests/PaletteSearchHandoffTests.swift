import Foundation
@testable import MemoryClip
import Testing

@MainActor
struct PaletteSearchHandoffTests {
    @Test func `operator query is handed to search`() {
        #expect(CommandPaletteView.searchQuery(for: " app:brave AND type:secret ") == "app:brave AND type:secret")
    }

    @Test func `plain words stay actions`() {
        #expect(CommandPaletteView.searchQuery(for: "upper") == nil)
        #expect(CommandPaletteView.searchQuery(for: "app:") == nil)
    }

    @Test func `type accepts state words`() {
        let query = ClipQuery("app:brave AND type:secret")
        #expect(query.constraints.apps == ["brave"])
        #expect(query.constraints.states == [.secret])
        #expect(query.terms.isEmpty)
        let allKnown = query.operatorTokens.allSatisfy { $0.valueIsKnown }
        #expect(allKnown)
        #expect(ClipQuery("-type:pinned").constraints.notStates == [.pinned])
    }

    @Test func `unknown type value still unknown`() {
        #expect(ClipQuery("type:banana").operatorTokens.first?.valueIsKnown == false)
    }
}
