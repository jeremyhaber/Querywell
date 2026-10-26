import Testing
import QuerywellCore
@testable import Querywell

@Suite("App linkage")
struct QuerywellTests {
    @Test("QuerywellCore links and exposes three engines")
    func coreLinks() {
        #expect(DatabaseEngine.allCases.count == 3)
    }

    @Test("App module is importable")
    @MainActor
    func appModuleLinks() {
        _ = LauncherView()
    }
}
