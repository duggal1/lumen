import Foundation

public enum SensitiveCategory: String, Codable, CaseIterable, Sendable {
    case email, phone, card, apiKey, jwt, privateKey, envSecret, entropy, custom
}
public struct SensitiveHit: Sendable, Equatable {
    public var range: Range<String.Index>
    public var category: SensitiveCategory
}

/// FNV-1a 64. `salt` makes hashes project-specific.
public func fnv1a64(_ s: String, salt: UInt64 = 0) -> UInt64 {
    var h: UInt64 = 0xcbf29ce484222325 ^ salt
    for b in s.utf8 { h ^= UInt64(b); h = h &* 0x100000001b3 }
    return h
}

/// Deterministic UUID from two integers (stable ids survive replans).
public func stableUUID(_ a: UInt64, _ b: UInt64) -> UUID {
    func by(_ v: UInt64, _ i: Int) -> UInt8 { UInt8((v >> UInt64(56 - 8 * i)) & 255) }
    return UUID(uuid: (by(a, 0), by(a, 1), by(a, 2), by(a, 3), by(a, 4), by(a, 5), by(a, 6), by(a, 7),
                       by(b, 0), by(b, 1), by(b, 2), by(b, 3), by(b, 4), by(b, 5), by(b, 6), by(b, 7)))
}

/// Pure sensitive-data classifier. Returns sub-ranges of one OCR line so only the secret itself is masked.
public enum SensitivePatterns {
    static let keyPrefixes: [(prefix: String, minLen: Int)] = [
        ("sk-ant-", 30), ("sk-proj-", 30), ("sk-", 24), ("AKIA", 20), ("ASIA", 20), ("ghp_", 30), ("gho_", 30), ("ghu_", 30), ("ghs_", 30),
        ("ghr_", 30), ("github_pat_", 40), ("xoxb-", 20), ("xoxa-", 20), ("xoxp-", 20), ("AIza", 35), ("sk_live_", 24), ("pk_live_", 24),
        ("rk_live_", 24), ("hf_", 30), ("glpat-", 20), ("npm_", 36), ("SG.", 30), ("dop_v1_", 30), ("shpat_", 30), ("ya29.", 30),
    ]
    static let secretWords: Set<String> = ["key", "secret", "token", "password", "passwd", "pwd", "auth", "authorization", "credential",
                                           "credentials", "apikey", "passphrase", "bearer"]
    static let wrap: Set<Character> = ["\"", "'", "`", "(", ")", "[", "]", "{", "}", "<", ">", ",", ";"]

    public static func entropy(_ s: Substring) -> Double {
        guard !s.isEmpty else { return 0 }
        var counts: [Character: Int] = [:]
        for c in s { counts[c, default: 0] += 1 }
        let n = Double(s.count)
        return -counts.values.reduce(0.0) { $0 + (Double($1) / n) * log2(Double($1) / n) }
    }

    public static func luhn(_ d: [Int]) -> Bool {
        guard d.count >= 12 else { return false }
        var sum = 0
        for (i, v) in d.reversed().enumerated() {
            var x = v
            if i % 2 == 1 { x *= 2; if x > 9 { x -= 9 } }
            sum += x
        }
        return sum % 10 == 0
    }

    static func isSecretName(_ k: String) -> Bool {
        for comp in k.lowercased().split(whereSeparator: { !$0.isLetter && !$0.isNumber }) {
            if secretWords.contains(String(comp)) { return true }
            if comp.count > 4, ["token", "secret", "apikey", "password"].contains(where: { comp.hasSuffix($0) }) { return true }
        }
        return false
    }

    static func isEmail(_ s: Substring) -> Bool {
        let p = s.split(separator: "@", omittingEmptySubsequences: false)
        guard p.count == 2, p[0].count >= 1, p[0].count <= 64 else { return false }
        guard p[0].allSatisfy({ $0.isLetter || $0.isNumber || "._%+-".contains($0) }),
              p[1].allSatisfy({ $0.isLetter || $0.isNumber || ".-".contains($0) }) else { return false }
        let labels = p[1].split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2, labels.allSatisfy({ !$0.isEmpty }), let tld = labels.last, tld.count >= 2, tld.allSatisfy(\.isLetter) else { return false }
        return true
    }

    static func isKeyToken(_ s: Substring) -> Bool {
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }) else { return false }
        for (p, m) in keyPrefixes where s.hasPrefix(p) && s.count >= m { return true }
        return false
    }

    static func isJWT(_ s: Substring) -> Bool {
        guard s.hasPrefix("eyJ") else { return false }
        let p = s.split(separator: ".", omittingEmptySubsequences: false)
        guard p.count == 3, p.allSatisfy({ $0.count >= 8 }) else { return false }
        return s.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || "_-.=".contains($0)) }
    }

    static func isHighEntropy(_ s: Substring, _ thr: Double) -> Bool {
        guard s.count >= 20, s.count <= 256, !s.contains("://") else { return false }
        guard s.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-+/=".contains($0)) }) else { return false }
        if s.filter({ $0 == "/" }).count >= 2 { return false }
        var classes = 0
        if s.contains(where: \.isLowercase) { classes += 1 }
        if s.contains(where: \.isUppercase) { classes += 1 }
        if s.contains(where: \.isNumber) { classes += 1 }
        return classes >= 2 && entropy(s) > thr
    }

    static func groups(_ s: Substring) -> [Int] {
        var g: [Int] = [], c = 0
        for ch in s { if ch.isASCII && ch.isNumber { c += 1 } else if c > 0 { g.append(c); c = 0 } }
        if c > 0 { g.append(c) }
        return g
    }

    /// Card numbers (Luhn) and phone numbers, which can span several tokens.
    static func numberHits(_ line: String) -> [SensitiveHit] {
        var out: [SensitiveHit] = []
        let seps: Set<Character> = [" ", "-", ".", "(", ")", "+"]
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i], nx = line.index(after: i)
            let opens = (c.isASCII && c.isNumber) || ((c == "+" || c == "(") && nx < line.endIndex && line[nx].isASCII && line[nx].isNumber)
            if !opens { i = nx; continue }
            if i > line.startIndex {
                let p = line[line.index(before: i)]
                if p.isLetter || p.isNumber || p == "_" { i = nx; continue }
            }
            var j = i, last = i, spaces = 0
            while j < line.endIndex {
                let ch = line[j]
                if ch.isASCII && ch.isNumber { last = line.index(after: j); spaces = 0 }
                else if ch == " " { spaces += 1; if spaces > 1 { break } }
                else if seps.contains(ch) { spaces = 0 }
                else { break }
                j = line.index(after: j)
            }
            guard last > i else { i = nx; continue }
            if last < line.endIndex, line[last].isLetter { i = last; continue }
            let run = line[i..<last]
            let digits = run.compactMap { $0.isASCII ? $0.wholeNumberValue : nil }
            let g = groups(run)
            let plus = run.first == "+"
            var cat: SensitiveCategory?
            if g.count == 1, (13...19).contains(digits.count), let f = digits.first, (3...6).contains(f), luhn(digits) { cat = .card }
            else if g.count > 1, (13...19).contains(digits.count), g.allSatisfy({ (4...6).contains($0) }), luhn(digits) { cat = .card }
            else if g == [3, 3, 4] || g == [1, 3, 3, 4] { cat = .phone }
            else if plus, (9...15).contains(digits.count), g.count >= 2 { cat = .phone }
            if let cat { out.append(SensitiveHit(range: i..<last, category: cat)) }
            i = last
        }
        return out
    }

    public static func scan(_ line: String, custom: [String] = [], entropyThreshold: Double = 3.5) -> [SensitiveHit] {
        if let r = line.range(of: "-----BEGIN") { return [SensitiveHit(range: r.lowerBound..<line.endIndex, category: .privateKey)] }
        var hits: [SensitiveHit] = []
        func add(_ r: Range<String.Index>, _ c: SensitiveCategory) {
            guard !r.isEmpty, !hits.contains(where: { $0.range.overlaps(r) }) else { return }
            hits.append(SensitiveHit(range: r, category: c))
        }
        func trim(_ r: Range<String.Index>) -> Range<String.Index> {
            var a = r.lowerBound, b = r.upperBound
            while a < b, wrap.contains(line[a]) { a = line.index(after: a) }
            while a < b, wrap.contains(line[line.index(before: b)]) { b = line.index(before: b) }
            return a..<b
        }
        for pat in custom where !pat.isEmpty {
            guard let re = try? Regex(pat) else { continue }
            for m in line.matches(of: re) { add(m.range, .custom) }
        }
        for h in numberHits(line) { add(h.range, h.category) }

        var prevKey = false
        var i = line.startIndex
        while i < line.endIndex {
            if line[i].isWhitespace { i = line.index(after: i); continue }
            var j = i
            while j < line.endIndex, !line[j].isWhitespace { j = line.index(after: j) }
            let raw = i..<j
            i = j
            let lastCh = line[line.index(before: raw.upperBound)]
            let endsKey = lastCh == ":" || lastCh == "="
            var r = trim(raw)
            guard !r.isEmpty else { continue }
            let wasKey = prevKey
            prevKey = false
            let low = line[r].lowercased()
            if endsKey, isSecretName(low.trimmingCharacters(in: CharacterSet(charactersIn: "\"':=`"))) { prevKey = true; continue }
            if wasKey && low == "bearer" { prevKey = true; continue }
            if let eq = line[r].firstIndex(of: "="), eq > r.lowerBound {
                let v = trim(line.index(after: eq)..<r.upperBound)
                if isSecretName(String(line[r.lowerBound..<eq])), line[v].count >= 6 { add(v, .envSecret); continue }
                r = v
                if r.isEmpty { continue }
            }
            let tok = line[r]
            if wasKey, tok.count >= 8 { add(r, isKeyToken(tok) ? .apiKey : .envSecret); continue }
            if isEmail(tok) { add(r, .email) }
            else if isKeyToken(tok) { add(r, .apiKey) }
            else if isJWT(tok) { add(r, .jwt) }
            else if isHighEntropy(tok, entropyThreshold) { add(r, .entropy) }
        }
        return hits
    }
}