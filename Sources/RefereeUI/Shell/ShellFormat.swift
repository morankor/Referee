import Foundation

/// Numbers and sizes as the Shell writes them. The output is the same on every machine, whatever its locale, so that
/// the sentences of plan.md section 9.7 ("about 153,000 tokens", "2.1 MB") read alike everywhere and can be tested.
enum ShellFormat {
    /// 153000 -> "153,000".
    static func grouped(_ value: Int) -> String {
        let digits = String(value.magnitude)
        var result = ""
        for (index, character) in digits.enumerated() {
            if index > 0 && (digits.count - index) % 3 == 0 { result.append(",") }
            result.append(character)
        }
        return value < 0 ? "-" + result : result
    }

    /// A token estimate is rough (3.5 characters per token, section 6.4), so it is shown rounded: to the nearest
    /// thousand from 10,000, the nearest hundred from 1,000, the nearest ten below. 153,456 -> "153,000".
    static func approximately(_ tokens: Int) -> String {
        let value = max(0, tokens)
        let step = value >= 10_000 ? 1_000 : value >= 1_000 ? 100 : 10
        let rounded = ((value + step / 2) / step) * step
        return grouped(rounded)
    }

    /// File sizes in decimal units, as Finder gives them: "640 bytes", "184 KB", "2.1 MB", "1.3 GB".
    static func bytes(_ count: Int) -> String {
        let value = max(0, count)
        if value < 1_000 { return value == 1 ? "1 byte" : "\(value) bytes" }
        let kilobytes = Int((Double(value) / 1_000).rounded())
        if kilobytes < 1_000 { return "\(kilobytes) KB" }
        let megabytes = Double(value) / 1_000_000
        if (megabytes * 10).rounded() < 10_000 { return oneDecimal(megabytes) + " MB" }
        return oneDecimal(Double(value) / 1_000_000_000) + " GB"
    }

    /// "1 request", "3 requests".
    static func count(_ value: Int, _ singular: String, _ plural: String) -> String {
        "\(grouped(value)) \(value == 1 ? singular : plural)"
    }

    /// 2.14 -> "2.1"; 12.0 -> "12.0".
    private static func oneDecimal(_ value: Double) -> String {
        let tenths = Int((value * 10).rounded())
        return "\(grouped(tenths / 10)).\(tenths % 10)"
    }
}
