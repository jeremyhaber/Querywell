import Testing
@testable import QuerywellCore

@Suite("LatencyFormatter")
struct LatencyFormatterTests {
    @Test func formats() {
        #expect(LatencyFormatter.string(for: .zero) == "<1 ms")
        #expect(LatencyFormatter.string(for: .microseconds(400)) == "<1 ms")
        #expect(LatencyFormatter.string(for: .microseconds(1000)) == "1 ms")
        #expect(LatencyFormatter.string(for: .milliseconds(38)) == "38 ms")
        #expect(LatencyFormatter.string(for: .microseconds(38_400)) == "38 ms")
        #expect(LatencyFormatter.string(for: .milliseconds(999)) == "999 ms")
        #expect(LatencyFormatter.string(for: .milliseconds(1000)) == "1.0 s")
        #expect(LatencyFormatter.string(for: .milliseconds(1234)) == "1.2 s")
        #expect(LatencyFormatter.string(for: .seconds(12)) == "12.0 s")
    }
}
