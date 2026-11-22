import Foundation
import PDFKit
import RefereeCore
import PDFBridge

// Seed of the command-line tool (plan.md section 11.4, WP0b): only `dump-raw`, because the fixtures need it.
// Gate 1 writes the eight subcommands of section 10.2.
//
// Exit codes (section 10.2): 0 success; 1 the job failed; 2 usage error.

func fail(_ message: String, code: Int32) -> Never {
    FileHandle.standardError.write(Data("referee-cli: \(message)\n".utf8))
    exit(code)
}

let arguments = Array(CommandLine.arguments.dropFirst())
guard arguments.count == 2, arguments[0] == "dump-raw" else {
    fail("usage: referee-cli dump-raw <pdf>     prints the RawDocument JSON of the file (the other subcommands are not in this build yet)", code: 2)
}

guard let document = PDFDocument(url: URL(fileURLWithPath: arguments[1])) else {
    fail("this file could not be opened as a PDF", code: 1)
}
if document.isLocked { fail("this PDF is password-protected", code: 1) }

// The format of everything this project writes to disk (plan section 3.7): the output is what Fixtures/raw holds.
let encoder = JSONEncoder()
encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
do {
    var output = try encoder.encode(RawExtractor.extract(from: document))
    output.append(0x0A)
    FileHandle.standardOutput.write(output)
} catch {
    fail("the document could not be encoded", code: 1)
}
