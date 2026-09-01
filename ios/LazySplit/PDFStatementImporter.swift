import Foundation
import PDFKit
import Vision
import UIKit

struct PDFStatementRow: Identifiable, Sendable, Equatable {
    let id = UUID()
    let rawDate: String
    let originalLine: String
    let page: Int
    var merchant: String
    var amountText: String
    var isCredit: Bool
    var included = true
    var editedDate: Date?
    var currencyCode: String? = nil

    func date(endingOn: Date) -> Date? { editedDate ?? PDFStatementImporter.date(rawDate, endingOn: endingOn) }
}

struct PDFStatementPreview: Sendable {
    var rows: [PDFStatementRow]
    let pageCount: Int
    let scannedPages: Int
    let unmatchedDatedLines: Int
    let pagesWithoutRows: Int
    var excludedRows: Int = 0
    var statementPeriod: PDFStatementPeriod? = nil
}

struct PDFStatementPeriod: Sendable, Equatable {
    let endingOn: Date
    let isYearly: Bool
    let message: String
}

enum PDFStatementError: LocalizedError {
    case unreadable, locked, tooLarge, noRows, invalidSelection
    var errorDescription: String? {
        switch self {
        case .unreadable: "This PDF couldn't be read. Try downloading the statement again or use CSV."
        case .locked: "This PDF is password-protected. Export an unlocked copy from your bank, or use CSV."
        case .tooLarge: "Choose a statement under 25 MB with no more than 50 pages."
        case .noRows: "No supported transaction rows were found. Try a bank-downloaded PDF or CSV. PDFs must have a numeric or month-name date, description, and amount on the same line."
        case .invalidSelection: "Check the date, description, and amount for every selected transaction."
        }
    }
}

enum PDFStatementImporter {
    static let maxBytes = 25 * 1024 * 1024
    // Restrict parsing to transaction-shaped rows, not statement balances or summaries.
    private static let monthName = #"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"#
    private static let dateToken = #"(?:\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}(?:/\d{4}|/\d{2})?|"# + monthName + #"\s+\d{1,2}(?:,?\s+\d{4})?)\*?"#
    private static let rowPattern = #"^\s*("# + dateToken + #")\s+(?:"# + dateToken + #"\s+)?(.+?)\s+([\-(]?\s*[$£€₹]?\s*\d[\d,]*\.\d{2}\s*\)?\s*(?:CR|DR|-)?\s*[♦†‡#]*)\s*$"#

    static func preview(data: Data) throws -> PDFStatementPreview {
        guard data.count <= maxBytes else { throw PDFStatementError.tooLarge }
        guard let document = PDFDocument(data: data) else { throw PDFStatementError.unreadable }
        guard !document.isLocked else { throw PDFStatementError.locked }
        guard document.pageCount > 0 else { throw PDFStatementError.unreadable }
        guard document.pageCount <= 50 else { throw PDFStatementError.tooLarge }
        var texts: [String] = [], metadataTexts: [String] = [], scanned = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw PDFStatementError.unreadable }
            let logicalText = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let visualText = visuallyAlignedText(page)
            metadataTexts.append(logicalText)
            let digitalCandidates = [logicalText, visualText].filter { !$0.isEmpty }
            let bestDigital = digitalCandidates.max { parse(pages: [$0]).rows.count < parse(pages: [$1]).rows.count } ?? ""
            if !parse(pages: [bestDigital]).rows.isEmpty { texts.append(bestDigital) }
            else {
                scanned += 1
                let recognized = try recognize(page)
                texts.append(recognized.isEmpty ? bestDigital : recognized)
            }
        }
        var parsed = parse(pages: texts, scannedPages: scanned)
        parsed.statementPeriod = statementPeriod(in: metadataTexts) ?? parsed.statementPeriod
        guard !parsed.rows.isEmpty else { throw PDFStatementError.noRows }
        return parsed
    }

    static func parse(pages: [String], scannedPages: Int = 0) -> PDFStatementPreview {
        let regex = try! NSRegularExpression(pattern: rowPattern, options: .caseInsensitive)
        let appleRegex = try! NSRegularExpression(pattern: #"^\s*("# + dateToken + #")\s+(.+?)\s+(\d+(?:\.\d+)?%)\s+(\(?\s*-?\s*\$\s*\d[\d,]*\.\d{2}\s*\)?(?:\s*CR)?)\s+(\(?\s*-?\s*\$\s*\d[\d,]*\.\d{2}\s*\)?(?:\s*CR)?)\s*$"#, options: .caseInsensitive)
        let startsWithDate = try! NSRegularExpression(pattern: #"^\s*"# + dateToken + #"\s"#)
        let documentText = pages.joined(separator: "\n")
        let isAppleCard = documentText.range(of: #"(?i)\bApple Card\b"#, options: .regularExpression) != nil
        let isAmex = documentText.range(of: #"(?i)\b(?:American Express|Amex)\b"#, options: .regularExpression) != nil
        var rows: [PDFStatementRow] = [], unmatched = 0, emptyPages = 0, excluded = 0
        var amexSection = AmexStatementSection.none
        for (index, text) in pages.enumerated() {
            let before = rows.count
            var appleSection = AppleStatementSection.none
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.replacingOccurrences(of: "\u{00a0}", with: " ")
                let normalizedLine = line.trimmingCharacters(in: .whitespaces).lowercased()
                if isAppleCard && (normalizedLine == "transactions" || normalizedLine.hasPrefix("transactions date")) {
                    appleSection = .transactions; continue
                }
                if isAppleCard && (normalizedLine == "payments" || normalizedLine.hasPrefix("payments date")) {
                    appleSection = .payments; continue
                }
                if isAppleCard && (normalizedLine.contains("apple card monthly installments") || normalizedLine == "monthly installments") {
                    appleSection = .installments; continue
                }
                if isAmex {
                    if normalizedLine == "new charges" || normalizedLine.hasPrefix("new charges ") || normalizedLine.contains("new pay over time charges") || normalizedLine.contains("new pay in full charges") {
                        amexSection = .charges; continue
                    }
                    if normalizedLine == "payments" || normalizedLine == "credits" || normalizedLine.hasPrefix("payments and credits") {
                        amexSection = .payments; continue
                    }
                    if normalizedLine == "fees" || normalizedLine == "interest charged" || normalizedLine.hasPrefix("fees and interest") {
                        amexSection = .adjustments; continue
                    }
                }
                let range = NSRange(line.startIndex..., in: line)
                let dated = startsWithDate.firstMatch(in: line, range: range) != nil
                if dated && ((isAppleCard && appleSection != .none && appleSection != .transactions) || (isAmex && amexSection != .none && amexSection != .charges)) {
                    excluded += 1; continue
                }
                if let match = appleRegex.firstMatch(in: line, range: range) {
                    func appleValue(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]).trimmingCharacters(in: .whitespaces) } ?? "" }
                    let merchant = appleValue(2), rawAmount = appleValue(5).uppercased()
                    let amount = rawAmount.replacingOccurrences(of: #"[^0-9.]"#, with: "", options: .regularExpression)
                    guard minorUnits(amount) != nil else { unmatched += 1; continue }
                    let credit = rawAmount.contains("CR") || rawAmount.contains("-") || rawAmount.contains("(") || merchant.range(of: #"(?i)\b(refund|credit|reversal|return)\b"#, options: .regularExpression) != nil
                    rows.append(PDFStatementRow(rawDate: appleValue(1), originalLine: line, page: index + 1, merchant: merchant, amountText: amount, isCredit: credit))
                    continue
                }
                guard let match = regex.firstMatch(in: line, range: range) else {
                    if dated { unmatched += 1 }
                    continue
                }
                func value(_ index: Int) -> String { Range(match.range(at: index), in: line).map { String(line[$0]).trimmingCharacters(in: .whitespaces) } ?? "" }
                let merchant = value(2), rawAmount = value(3).uppercased()
                if merchant.range(of: #"(?i)\b(ach deposit|internet transfer|daily cash deposit|apple card monthly installments?|acmi|this month'?s installment|total financed|total remaining)\b"#, options: .regularExpression) != nil {
                    excluded += 1; continue
                }
                // Running-balance tables have multiple monetary columns: do not mistake the balance for the charge.
                guard merchant.range(of: #"\d[\d,]*\.\d{2}"#, options: .regularExpression) == nil,
                      merchant.range(of: #"(?i)\b(previous balance|new balance|balance forward|payment due|minimum payment|total payments|total purchases|total fees|total interest)\b"#, options: .regularExpression) == nil else {
                    unmatched += 1; continue
                }
                let amount = rawAmount.replacingOccurrences(of: #"[^0-9.]"#, with: "", options: .regularExpression)
                guard minorUnits(amount) != nil else { unmatched += 1; continue }
                let credit = rawAmount.contains("CR") || rawAmount.contains("-") || rawAmount.contains("(") || merchant.range(of: #"(?i)\b(payment|refund|credit|reversal)\b"#, options: .regularExpression) != nil
                rows.append(PDFStatementRow(rawDate: value(1), originalLine: line, page: index + 1, merchant: merchant, amountText: amount, isCredit: credit))
            }
            if rows.count == before { emptyPages += 1 }
        }
        return PDFStatementPreview(rows: rows, pageCount: pages.count, scannedPages: scannedPages, unmatchedDatedLines: unmatched, pagesWithoutRows: emptyPages, excludedRows: excluded, statementPeriod: statementPeriod(in: pages))
    }

    private enum AppleStatementSection { case none, transactions, payments, installments }
    private enum AmexStatementSection { case none, payments, charges, adjustments }

    static func minorUnits(_ value: String) -> Int? {
        let cleaned = value.trimmingCharacters(in: .whitespaces)
        guard cleaned.range(of: #"^\d{1,9}(?:\.\d{1,2})?$"#, options: .regularExpression) != nil,
              let decimal = Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX")), decimal > 0 else { return nil }
        let minor = NSDecimalNumber(decimal: decimal * 100).intValue
        return minor <= Int(Int32.max) ? minor : nil
    }

    static func date(_ value: String, endingOn: Date) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        let trimmed = value.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "*")))
        let namedPattern = #"^("# + monthName + #")\s+(\d{1,2})(?:,?\s+(\d{4}))?$"#
        if let regex = try? NSRegularExpression(pattern: namedPattern, options: .caseInsensitive),
           let match = regex.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)),
           let monthRange = Range(match.range(at: 1), in: trimmed),
           let dayRange = Range(match.range(at: 2), in: trimmed) {
            let key = trimmed[monthRange].prefix(3).lowercased()
            let months = ["jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6, "jul": 7, "aug": 8, "sep": 9, "oct": 10, "nov": 11, "dec": 12]
            guard let month = months[key], let day = Int(trimmed[dayRange]) else { return nil }
            var year = calendar.component(.year, from: endingOn)
            if match.range(at: 3).location != NSNotFound, let yearRange = Range(match.range(at: 3), in: trimmed) { year = Int(trimmed[yearRange]) ?? year }
            else if month > calendar.component(.month, from: endingOn) { year -= 1 }
            return validDate(year: year, month: month, day: day, calendar: calendar)
        }
        let parts = trimmed.split(separator: trimmed.contains("-") ? "-" : "/").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var year = calendar.component(.year, from: endingOn)
        let month: Int, day: Int
        if trimmed.contains("-") { guard parts.count == 3 else { return nil }; year = parts[0]; month = parts[1]; day = parts[2] }
        else {
            month = parts[0]; day = parts[1]
            if parts.count == 3 { year = parts[2] < 100 ? 2000 + parts[2] : parts[2] }
            else if month > calendar.component(.month, from: endingOn) { year -= 1 }
        }
        return validDate(year: year, month: month, day: day, calendar: calendar)
    }

    private static func validDate(year: Int, month: Int, day: Int, calendar: Calendar) -> Date? {
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return date
    }

    static func statementPeriod(in pages: [String]) -> PDFStatementPeriod? {
        let text = pages.joined(separator: "\n")
        let numeric = #"(\d{1,2}[/.]\d{1,2}[/.]\d{2,4})"#
        let patterns: [(String, Int, String)] = [
            (#"(?i)opening\s*/\s*closing\s+date\s*:?[ \t]*"# + numeric + #"\s*[-–—]\s*"# + numeric, 2, "opening/closing date"),
            (#"(?i)statement\s+period\s*:?.*?\b(?:to|through|-|–|—)\s*"# + numeric, 1, "statement period"),
            (#"(?i)(?:statement\s+)?closing\s+date\s*:?[ \t]*"# + numeric, 1, "closing date"),
            (#"(?i)(?:billing\s+(?:period|cycle)\s+)?(?:ending|ends|through)\s*:?[ \t]*"# + numeric, 1, "billing period"),
            (#"(?i)statement\s+includes\s+.*?\bby\s+"# + numeric, 1, "statement period")
        ]
        for (pattern, capture, source) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
                  let range = Range(match.range(at: capture), in: text),
                  let end = fullDate(String(text[range])) else { continue }
            return PDFStatementPeriod(endingOn: end, isYearly: false, message: "Used the \(source) printed inside the PDF. Confirm it before importing.")
        }
        let monthYear = #"(?im)^\s*(January|February|March|April|May|June|July|August|September|October|November|December)\s+(20\d{2})\s*$"#
        if let regex = try? NSRegularExpression(pattern: monthYear), let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
           let monthRange = Range(match.range(at: 1), in: text), let yearRange = Range(match.range(at: 2), in: text),
           let month = Calendar.current.monthSymbols.firstIndex(where: { $0.caseInsensitiveCompare(String(text[monthRange])) == .orderedSame }), let year = Int(text[yearRange]) {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
            let start = calendar.date(from: DateComponents(year: year, month: month + 1, day: 1))!
            let end = calendar.date(byAdding: DateComponents(month: 1, day: -1), to: start)!
            return PDFStatementPeriod(endingOn: end, isYearly: false, message: "Inferred the month from the statement heading inside the PDF. Confirm it before importing.")
        }
        return nil
    }

    private static func fullDate(_ value: String) -> Date? {
        let parts = value.split(whereSeparator: { $0 == "/" || $0 == "." }).compactMap { Int($0) }
        guard parts.count == 3 else { return nil }
        let year = parts[2] < 100 ? 2000 + parts[2] : parts[2]
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = .gmt
        return validDate(year: year, month: parts[0], day: parts[1], calendar: calendar)
    }

    private static func visuallyAlignedText(_ page: PDFPage) -> String {
        guard let selection = page.selection(for: page.bounds(for: .mediaBox)) else { return "" }
        let fragments = selection.selectionsByLine().compactMap { item -> (String, CGRect)? in
            let value = item.string?.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return nil }
            return (value, item.bounds(for: page))
        }.sorted { lhs, rhs in
            abs(lhs.1.midY - rhs.1.midY) > 2 ? lhs.1.midY > rhs.1.midY : lhs.1.minX < rhs.1.minX
        }
        var rows: [[(String, CGRect)]] = []
        for fragment in fragments {
            if let last = rows.last, let anchor = last.first,
               abs(anchor.1.midY - fragment.1.midY) <= max(2, min(anchor.1.height, fragment.1.height) * 0.45) {
                rows[rows.count - 1].append(fragment)
            } else { rows.append([fragment]) }
        }
        return rows.map { row in row.sorted { $0.1.minX < $1.1.minX }.map(\.0).joined(separator: " ") }.joined(separator: "\n")
    }

    // Feed reviewed rows into the existing statement normalization/duplicate detection path.
    static func reviewedCSV(rows: [PDFStatementRow], endingOn: Date, currency: String) throws -> Data {
        let selected = rows.filter(\.included)
        guard !selected.isEmpty else { throw PDFStatementError.invalidSelection }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.timeZone = .gmt; formatter.dateFormat = "yyyy-MM-dd"
        func escape(_ value: String) -> String { "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Date,Description,Amount,Currency"]
        for row in selected {
            guard let date = row.date(endingOn: endingOn), minorUnits(row.amountText) != nil, !row.merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw PDFStatementError.invalidSelection }
            lines.append([formatter.string(from: date), row.merchant, (row.isCredit ? "-" : "") + row.amountText.trimmingCharacters(in: .whitespaces), currency].map(escape).joined(separator: ","))
        }
        return Data(lines.joined(separator: "\n").utf8)
    }

    private static func recognize(_ page: PDFPage) throws -> String {
        guard let image = page.thumbnail(of: CGSize(width: 1700, height: 2200), for: .mediaBox).cgImage else { throw PDFStatementError.unreadable }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image).perform([request])
        // OCR often returns each table column separately. Rejoin boxes on the same baseline.
        let observations = (request.results ?? []).sorted { $0.boundingBox.midY > $1.boundingBox.midY }
        var lines: [[VNRecognizedTextObservation]] = []
        for observation in observations {
            if let last = lines.last, let anchor = last.first,
               abs(anchor.boundingBox.midY - observation.boundingBox.midY) < min(anchor.boundingBox.height, observation.boundingBox.height) * 0.5 {
                lines[lines.count - 1].append(observation)
            } else { lines.append([observation]) }
        }
        return lines.map { line in line.sorted { $0.boundingBox.minX < $1.boundingBox.minX }.compactMap { $0.topCandidates(1).first?.string }.joined(separator: " ") }.joined(separator: "\n")
    }
}
