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
}

enum PDFStatementError: LocalizedError {
    case unreadable, locked, tooLarge, noRows, invalidSelection
    var errorDescription: String? {
        switch self {
        case .unreadable: "This PDF couldn't be read. Try downloading the statement again or use CSV."
        case .locked: "This PDF is password-protected. Export an unlocked copy from your bank, or use CSV."
        case .tooLarge: "Choose a statement under 25 MB with no more than 50 pages."
        case .noRows: "No supported transaction rows were found. Try a bank-downloaded PDF or CSV. PDFs must have a numeric date, description, and amount on the same line."
        case .invalidSelection: "Check the date, description, and amount for every selected transaction."
        }
    }
}

enum PDFStatementImporter {
    static let maxBytes = 25 * 1024 * 1024
    // Restrict parsing to transaction-shaped rows, not statement balances or summaries.
    private static let dateToken = #"(?:\d{4}-\d{2}-\d{2}|\d{1,2}/\d{1,2}(?:/\d{4}|/\d{2})?)"#
    private static let rowPattern = #"^\s*("# + dateToken + #")\s+(?:"# + dateToken + #"\s+)?(.+?)\s+([\-(]?\s*[$£€₹]?\s*\d[\d,]*\.\d{2}\s*\)?\s*(?:CR|DR|-)?)\s*$"#

    static func preview(data: Data) throws -> PDFStatementPreview {
        guard data.count <= maxBytes else { throw PDFStatementError.tooLarge }
        guard let document = PDFDocument(data: data) else { throw PDFStatementError.unreadable }
        guard !document.isLocked else { throw PDFStatementError.locked }
        guard document.pageCount > 0 else { throw PDFStatementError.unreadable }
        guard document.pageCount <= 50 else { throw PDFStatementError.tooLarge }
        var texts: [String] = [], scanned = 0
        for index in 0..<document.pageCount {
            try Task.checkCancellation()
            guard let page = document.page(at: index) else { throw PDFStatementError.unreadable }
            let text = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !parse(pages: [text]).rows.isEmpty { texts.append(text) }
            else {
                scanned += 1
                let recognized = try recognize(page)
                texts.append(recognized.isEmpty ? text : recognized)
            }
        }
        let parsed = parse(pages: texts, scannedPages: scanned)
        guard !parsed.rows.isEmpty else { throw PDFStatementError.noRows }
        return parsed
    }

    static func parse(pages: [String], scannedPages: Int = 0) -> PDFStatementPreview {
        let regex = try! NSRegularExpression(pattern: rowPattern, options: .caseInsensitive)
        let appleRegex = try! NSRegularExpression(pattern: #"^\s*("# + dateToken + #")\s+(.+?)\s+(\d+(?:\.\d+)?%)\s+(\(?\s*-?\s*\$\s*\d[\d,]*\.\d{2}\s*\)?(?:\s*CR)?)\s+(\(?\s*-?\s*\$\s*\d[\d,]*\.\d{2}\s*\)?(?:\s*CR)?)\s*$"#, options: .caseInsensitive)
        let startsWithDate = try! NSRegularExpression(pattern: #"^\s*"# + dateToken + #"\s"#)
        var rows: [PDFStatementRow] = [], unmatched = 0, emptyPages = 0, excluded = 0
        for (index, text) in pages.enumerated() {
            let before = rows.count
            var appleSection = AppleStatementSection.none
            for raw in text.components(separatedBy: .newlines) {
                let line = raw.replacingOccurrences(of: "\u{00a0}", with: " ")
                let normalizedLine = line.trimmingCharacters(in: .whitespaces).lowercased()
                if normalizedLine == "transactions" || normalizedLine.hasPrefix("transactions date") {
                    appleSection = .transactions; continue
                }
                if normalizedLine == "payments" || normalizedLine.hasPrefix("payments date") {
                    appleSection = .payments; continue
                }
                if normalizedLine.contains("apple card monthly installments") || normalizedLine == "monthly installments" {
                    appleSection = .installments; continue
                }
                let range = NSRange(line.startIndex..., in: line)
                let dated = startsWithDate.firstMatch(in: line, range: range) != nil
                if dated && appleSection != .none && appleSection != .transactions {
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
        return PDFStatementPreview(rows: rows, pageCount: pages.count, scannedPages: scannedPages, unmatchedDatedLines: unmatched, pagesWithoutRows: emptyPages, excludedRows: excluded)
    }

    private enum AppleStatementSection { case none, transactions, payments, installments }

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
        let parts = value.split(separator: value.contains("-") ? "-" : "/").compactMap { Int($0) }
        guard parts.count == 2 || parts.count == 3 else { return nil }
        var year = calendar.component(.year, from: endingOn)
        let month: Int, day: Int
        if value.contains("-") { guard parts.count == 3 else { return nil }; year = parts[0]; month = parts[1]; day = parts[2] }
        else {
            month = parts[0]; day = parts[1]
            if parts.count == 3 { year = parts[2] < 100 ? 2000 + parts[2] : parts[2] }
            else if month > calendar.component(.month, from: endingOn) { year -= 1 }
        }
        let components = DateComponents(year: year, month: month, day: day)
        guard let date = calendar.date(from: components), calendar.dateComponents([.year, .month, .day], from: date) == components else { return nil }
        return date
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
