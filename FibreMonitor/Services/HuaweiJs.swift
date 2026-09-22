import Foundation

/// Parses the JavaScript the Huawei ONT web UI returns instead of JSON.
///
/// Data endpoints answer with snippets like
/// `function() { return new Array(new WaninfoStats("dom","123",...),null); }`
/// where every string is `\xNN`-escaped. Many responses also carry the
/// constructor definition (`function USERDevice(Domain, IpAddr, ...)`), which
/// lets us map positional arguments to field names without hard-coding them.
public enum HuaweiJs {

    /// Removes a UTF-8 BOM and surrounding whitespace.
    public static func clean(_ text: String) -> String {
        var s = Substring(text)
        while let first = s.first, first == "\u{FEFF}" || first.isWhitespace { s = s.dropFirst() }
        return String(s).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when the text is a data snippet rather than an HTML page
    /// (the router serves the login page instead of data once the session expires).
    public static func looksLikeData(_ text: String) -> Bool {
        let s = clean(text)
        if s.hasPrefix("function") || s.hasPrefix("var ") { return true }
        return !s.lowercased().contains("<html")
    }

    /// Decodes one JS string literal body (without the quotes).
    public static func unescape(_ body: Substring) -> String {
        var out = ""
        var it = body.makeIterator()
        while let c = it.next() {
            guard c == "\\" else { out.append(c); continue }
            guard let e = it.next() else { break }
            switch e {
            case "x":
                let hex = String([it.next(), it.next()].compactMap { $0 })
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            case "u":
                let hex = String([it.next(), it.next(), it.next(), it.next()].compactMap { $0 })
                if let v = UInt32(hex, radix: 16), let u = Unicode.Scalar(v) { out.unicodeScalars.append(u) }
            case "n": out.append("\n")
            case "t": out.append("\t")
            case "r": out.append("\r")
            default: out.append(e)
            }
        }
        return out
    }

    /// Parameter names of every `function Name(a, b, c)` in the text.
    public static func definitions(in text: String) -> [String: [String]] {
        var result: [String: [String]] = [:]
        let pattern = #"function\s+([A-Za-z_][A-Za-z0-9_]*)\s*\(([^)]*)\)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return result }
        let ns = text as NSString
        for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
            let name = ns.substring(with: m.range(at: 1))
            let params = ns.substring(with: m.range(at: 2))
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            if result[name] == nil { result[name] = params }
        }
        return result
    }

    /// Positional arguments of every `new Name(...)` call. String literals are
    /// unescaped; bare tokens (numbers, null) are returned as written.
    public static func instances(of name: String, in text: String) -> [[String]] {
        var result: [[String]] = []
        let marker = "new \(name)("
        var searchStart = text.startIndex
        while let r = text.range(of: marker, range: searchStart..<text.endIndex) {
            var i = r.upperBound
            var args: [String] = []
            var closed = false
            while i < text.endIndex {
                // skip whitespace
                while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
                guard i < text.endIndex else { break }
                let c = text[i]
                if c == ")" { closed = true; i = text.index(after: i); break }
                if c == "\"" || c == "'" {
                    let quote = c
                    var j = text.index(after: i)
                    let bodyStart = j
                    while j < text.endIndex, text[j] != quote {
                        if text[j] == "\\" { j = text.index(after: j) }
                        if j < text.endIndex { j = text.index(after: j) }
                    }
                    args.append(unescape(text[bodyStart..<min(j, text.endIndex)]))
                    i = j < text.endIndex ? text.index(after: j) : j
                } else {
                    var j = i
                    while j < text.endIndex, text[j] != ",", text[j] != ")" { j = text.index(after: j) }
                    args.append(text[i..<j].trimmingCharacters(in: .whitespacesAndNewlines))
                    i = j
                }
                while i < text.endIndex, text[i].isWhitespace { i = text.index(after: i) }
                if i < text.endIndex, text[i] == "," { i = text.index(after: i) }
            }
            if closed { result.append(args) }
            searchStart = i
        }
        return result
    }

    /// `new Name(...)` calls mapped to field names, taken from the definition in the
    /// same text when present, otherwise from `fallbackParams`.
    public static func records(of name: String, in text: String, fallbackParams: [String] = []) -> [[String: String]] {
        let params = definitions(in: text)[name] ?? fallbackParams
        return instances(of: name, in: text).map { args in
            var dict: [String: String] = [:]
            for (index, key) in params.enumerated() where index < args.count {
                dict[key] = args[index]
            }
            return dict
        }
    }

    /// Value of `var name = '...'` / `var name = "..."`.
    public static func stringVar(_ name: String, in text: String) -> String? {
        let pattern = "var\\s+\(NSRegularExpression.escapedPattern(for: name))\\s*=\\s*(['\"])((?:\\\\.|(?!\\1).)*)\\1"
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let m = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let r = Range(m.range(at: 2), in: text) else { return nil }
        return unescape(text[r])
    }
}
