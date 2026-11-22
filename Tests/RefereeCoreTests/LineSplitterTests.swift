import Foundation
import Testing
import RefereeCore

/// LineSplitter (Appendix A.8): bytes in, complete lines out, empty lines kept.
@Suite struct LineSplitterTests {
    /// Feeds the text one byte at a time, as a stream delivers it, and collects every line.
    private func lines(of text: String) -> [String] {
        var splitter = LineSplitter()
        var result: [String] = []
        for byte in Array(text.utf8) {
            if let line = splitter.push(byte) { result.append(line) }
        }
        if let last = splitter.finish() { result.append(last) }
        return result
    }

    @Test func linesEndAtLineFeedsAndEmptyLinesAreKept() {
        #expect(lines(of: "event: ping\ndata: {}\n\nevent: stop\n") == ["event: ping", "data: {}", "", "event: stop"])
        #expect(lines(of: "\n\n") == ["", ""])
        #expect(lines(of: "").isEmpty)
    }

    @Test func aCarriageReturnBeforeTheLineFeedIsDropped() {
        #expect(lines(of: "one\r\ntwo\r\n\r\n") == ["one", "two", ""])
        #expect(lines(of: "a\rb\n") == ["a\rb"])          // only the one directly before the line feed
    }

    @Test func theUnterminatedLastLineComesFromFinishOnce() {
        var splitter = LineSplitter()
        for byte in Array("first\nlast".utf8) { _ = splitter.push(byte) }
        #expect(splitter.finish() == "last")
        #expect(splitter.finish() == nil)
        #expect(lines(of: "first\nlast") == ["first", "last"])
    }

    @Test func aCharacterSplitAcrossBytesIsPutTogetherAgain() {
        #expect(lines(of: "Sørensen — “ok” 🙂\nµi\n") == ["Sørensen — “ok” 🙂", "µi"])
    }

    @Test func bytesThatAreNotUTF8DoNotStopTheSplitter() {
        var splitter = LineSplitter()
        var result: [String] = []
        for byte in [0xFF, 0xFE, 0x41, 0x0A, 0x42, 0x0A] as [UInt8] {
            if let line = splitter.push(byte) { result.append(line) }
        }
        #expect(result.count == 2)
        #expect(result.first?.hasSuffix("A") == true)
        #expect(result.last == "B")
    }
}
