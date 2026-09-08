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
        case .noRows: "No supported transaction rows were found. Try a bank-downloaded PDF or CSV. Transactions must include a numeric or month-name date, description, and amount."
        case .invalidSelection: "Check the date, description, and amount for every selected transaction."
        }
    }
}

enum PDFStatementImporter {
    static let maxBytes = 25 * 1024 * 1024
    // Restrict parsing to transaction-shaped rows, not statement balances or summaries.
    private static let monthName = #"(?:Jan(?:uary)?|Feb(?:ruary)?|Mar(?:ch)?|Apr(?:il)?|May|Jun(?:e)?|Jul(?:y)?|Aug(?:ust)?|Sep(?:t(?:ember)?)?|Oct(?:ober)?|Nov(?:ember)?|Dec(?:ember)?)"#
    private static let dateToken = #"(?:\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}(?:/\d{4}|/\d{2})?|"# + monthName + #"\s+\d{1,2}(?:,?\s+\d{4})?)\*?"#
    // Some 2023 Amex PDFs encode the visible Pay Over Time diamond in a custom
    // font whose extracted Unicode value is a trailing lowercase "t".
    private static let rowPattern = #"^\s*("# + dateToken + #")\s+(?:"# + dateToken + #"\s+)?(.+?)\s+([\-(]?\s*[$£€₹]?\s*\d[\d,]*\.\d{2}\s*\)?\s*(?:CR|DR|-)?\s*[♦†‡#⧫◆t]*)\s*$"#

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
        let isAmex = isAmexStatement(documentText)
        var rows: [PDFStatementRow] = [], unmatched = 0, emptyPages = 0, excluded = 0
        for (index, text) in pages.enumerated() {
            let before = rows.count
            var appleSection = AppleStatementSection.none
            let sourceLines = text.components(separatedBy: .newlines)
            let transactionLines = isAmex ? coalescedAmexTransactionLines(sourceLines) : sourceLines
            for raw in transactionLines {
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
                        continue
                    }
                    if normalizedLine == "payments" || normalizedLine == "credits" || normalizedLine.hasPrefix("payments and credits") {
                        continue
                    }
                    if normalizedLine == "fees" || normalizedLine == "interest charged" || normalizedLine.hasPrefix("fees and interest") {
                        continue
                    }
                }
                let range = NSRange(line.startIndex..., in: line)
                let dated = startsWithDate.firstMatch(in: line, range: range) != nil
                if dated && isAppleCard && appleSection != .none && appleSection != .transactions {
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
                var merchant = value(2)
                let rawAmount = value(3).uppercased()
                if isAmex {
                    // Modern Amex statements add a Foreign Spend column before the
                    // billed USD amount. The generic balance-table guard would reject
                    // that extra decimal, so remove only the final foreign-spend value
                    // while we are inside the issuer's explicit New Charges section.
                    merchant = merchant.replacingOccurrences(
                        of: #"\s+(?:[A-Z]{3}\s+)?[$£€₹]?\s*\d[\d,]*\.\d{2}\s*$"#,
                        with: "",
                        options: [.regularExpression, .caseInsensitive]
                    )
                }
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
                if isAmex && (credit || merchant.range(of: #"(?i)\b(?:payments?|returns?|refunds?|credits?|reversals?|fees?|interest|adjustments?|cash advances?)\b"#, options: .regularExpression) != nil) {
                    excluded += 1; continue
                }
                rows.append(PDFStatementRow(rawDate: value(1), originalLine: line, page: index + 1, merchant: merchant, amountText: amount, isCredit: credit))
            }
            if rows.count == before { emptyPages += 1 }
        }
        return PDFStatementPreview(rows: rows, pageCount: pages.count, scannedPages: scannedPages, unmatchedDatedLines: unmatched, pagesWithoutRows: emptyPages, excludedRows: excluded, statementPeriod: statementPeriod(in: pages))
    }

    /// Older Amex PDFs sometimes expose one visible transaction row as several
    /// adjacent text lines (date, merchant, then amount). Join only a bounded run
    /// that starts with a date and ends in a valid transaction shape.
    private static func coalescedAmexTransactionLines(_ lines: [String]) -> [String] {
        let rowRegex = try! NSRegularExpression(pattern: rowPattern, options: .caseInsensitive)
        let datedRegex = try! NSRegularExpression(pattern: #"^\s*"# + dateToken + #"(?:\s|$)"#, options: .caseInsensitive)
        func matches(_ regex: NSRegularExpression, _ value: String) -> Bool {
            regex.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)) != nil
        }

        var output: [String] = []
        var index = 0
        while index < lines.count {
            let current = lines[index].replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespaces)
            guard matches(datedRegex, current), !matches(rowRegex, current) else {
                output.append(current)
                index += 1
                continue
            }

            var combined = current
            var consumed = 0
            for offset in 1...4 where index + offset < lines.count {
                let next = lines[index + offset].replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespaces)
                if next.isEmpty { continue }
                if matches(datedRegex, next) { break }
                combined += " " + next
                consumed = offset
                if matches(rowRegex, combined) { break }
            }
            if consumed > 0, matches(rowRegex, combined) {
                output.append(combined)
                index += consumed + 1
            } else {
                output.append(current)
                index += 1
            }
        }
        return output
    }

    private enum AppleStatementSection { case none, transactions, payments, installments }

    private static func isAmexStatement(_ text: String) -> Bool {
        if text.range(of: #"(?i)\b(?:American Express|Amex)\b"#, options: .regularExpression) != nil { return true }
        // Some statement generations draw the issuer/card title as an image. These
        // three labels together are a stable Amex transaction-detail signature.
        return text.range(of: #"(?i)\b(?:Card|Account) Ending\b"#, options: .regularExpression) != nil
            && text.range(of: #"(?i)\bClosing Date\b"#, options: .regularExpression) != nil
            && text.range(of: #"(?i)\b(?:Payments and Credits|Pay Over Time)\b"#, options: .regularExpression) != nil
    }

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
        let fragments = selection.selectionsByLine().compactMap { item -> (text: String, bounds: CGRect)? in
            let value = item.string?.replacingOccurrences(of: "\u{00a0}", with: " ").trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !value.isEmpty else { return nil }
            return (text: value, bounds: item.bounds(for: page))
        }
        return alignedText(fragments, minimumTolerance: 2, relativeTolerance: 0.7)
    }

    /// Reconstructs visual rows when PDFKit or Vision emits each table column as a
    /// separate fragment. Amex statements commonly place the amount a few pixels
    /// below the date/merchant baseline, so exact-baseline grouping loses charges.
    static func alignedText(
        _ fragments: [(text: String, bounds: CGRect)],
        minimumTolerance: CGFloat,
        relativeTolerance: CGFloat
    ) -> String {
        struct Row {
            var fragments: [(text: String, bounds: CGRect)]
            var midpoint: CGFloat
            var height: CGFloat
        }

        let ordered = fragments.sorted {
            if abs($0.bounds.midY - $1.bounds.midY) > 0.000_001 {
                return $0.bounds.midY > $1.bounds.midY
            }
            return $0.bounds.minX < $1.bounds.minX
        }
        var rows: [Row] = []
        for fragment in ordered {
            let candidate = rows.indices
                .map { index in (index: index, distance: abs(rows[index].midpoint - fragment.bounds.midY)) }
                .min { $0.distance < $1.distance }

            if let candidate {
                let row = rows[candidate.index]
                let rowTop = row.midpoint + row.height / 2
                let rowBottom = row.midpoint - row.height / 2
                let overlapTop = min(rowTop, fragment.bounds.maxY)
                let overlapBottom = max(rowBottom, fragment.bounds.minY)
                let overlap = max(0, overlapTop - overlapBottom)
                let smallerHeight = max(0.000_001, min(row.height, fragment.bounds.height))
                let tolerance = max(minimumTolerance, smallerHeight * relativeTolerance)
                if overlap / smallerHeight >= 0.25 || candidate.distance <= tolerance {
                    let count = CGFloat(row.fragments.count)
                    rows[candidate.index].fragments.append(fragment)
                    rows[candidate.index].midpoint = (row.midpoint * count + fragment.bounds.midY) / (count + 1)
                    rows[candidate.index].height = max(row.height, fragment.bounds.height)
                    continue
                }
            }
            rows.append(Row(fragments: [fragment], midpoint: fragment.bounds.midY, height: fragment.bounds.height))
        }

        return rows.sorted { $0.midpoint > $1.midpoint }.map { row in
            row.fragments.sorted { $0.bounds.minX < $1.bounds.minX }.map(\.text).joined(separator: " ")
        }.joined(separator: "\n")
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
        let pageBounds = page.bounds(for: .mediaBox)
        let width: CGFloat = 2200
        let height = width * max(pageBounds.height, 1) / max(pageBounds.width, 1)
        guard let image = page.thumbnail(of: CGSize(width: width, height: height), for: .mediaBox).cgImage else { throw PDFStatementError.unreadable }
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = false
        request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: image).perform([request])
        let fragments = (request.results ?? []).compactMap { observation -> (text: String, bounds: CGRect)? in
            guard let text = observation.topCandidates(1).first?.string.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else { return nil }
            return (text: text, bounds: observation.boundingBox)
        }
        let text = alignedText(fragments, minimumTolerance: 0.003, relativeTolerance: 0.9)
        return text.components(separatedBy: .newlines).map(normalizeOCRTransactionLine).joined(separator: "\n")
    }

    private static func normalizeOCRTransactionLine(_ line: String) -> String {
        var result = line
        let datePrefix = #"^[0-9OoIl|]{1,2}\s*[/|.]\s*[0-9OoIl|]{1,2}(?:\s*[/|.]\s*[0-9OoIl|]{2,4})?\*?"#
        if let range = result.range(of: datePrefix, options: .regularExpression) {
                var date = String(result[range])
                    .replacingOccurrences(of: "O", with: "0")
                    .replacingOccurrences(of: "o", with: "0")
                    .replacingOccurrences(of: "I", with: "1")
                    .replacingOccurrences(of: "l", with: "1")
                    .replacingOccurrences(of: "|", with: "/")
                    .replacingOccurrences(of: " ", with: "")
                date = date.replacingOccurrences(of: ".", with: "/")
                result.replaceSubrange(range, with: date)
        }
        result = result.replacingOccurrences(
            of: #"\s[§S](\d[\d,]*\.\d{2})(\s*[♦†‡#⧫◆]*)$"#,
            with: " $1$2",
            options: .regularExpression
        )
        return result
    }
}
