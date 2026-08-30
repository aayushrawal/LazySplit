import SwiftUI

struct InboxMonth: Identifiable {
    let id: Date
    let transactions: [TransactionRecord]

    // Plaid supplies calendar dates at midnight UTC, not instants in the phone's time zone.
    static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
    static var titleFormat: Date.FormatStyle {
        var format = Date.FormatStyle().month(.wide).year()
        format.timeZone = calendar.timeZone
        return format
    }
    static var dayFormat: Date.FormatStyle {
        var format = Date.FormatStyle().month(.abbreviated).day()
        format.timeZone = calendar.timeZone
        return format
    }
    var title: String { id.formatted(Self.titleFormat) }
    var reviewCount: Int { transactions.filter { $0.state == .needsReview }.count }
    var pendingCount: Int { transactions.filter { $0.state == .pending }.count }
    var postedTotals: [(currency: String, amount: Decimal)] {
        Dictionary(grouping: transactions.filter { !$0.isCredit && $0.state != .pending }, by: \.currencyCode)
            .map { (currency: $0.key, amount: $0.value.reduce(Decimal.zero) { $0 + $1.amount }) }
            .sorted { $0.currency < $1.currency }
    }

    static func group(_ transactions: [TransactionRecord], sort: InboxSort) -> [InboxMonth] {
        var ordering = InboxFilters()
        ordering.sort = sort
        let charges = transactions.filter { !$0.isCredit && $0.amountMinor > 0 }
        return Dictionary(grouping: charges) { calendar.dateInterval(of: .month, for: $0.date)!.start }
            .map { InboxMonth(id: $0.key, transactions: ordering.ordered($0.value)) }
            .sorted { sort == .oldest ? $0.id < $1.id : $0.id > $1.id }
    }
}

struct InboxMonthHeader: View {
    let month: InboxMonth
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline) {
                    Text(month.title).font(.title3.weight(.bold)).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                Text("\(month.transactions.count) charges · \(month.reviewCount) to review")
                    .font(.caption).foregroundStyle(.secondary)
                if !month.postedTotals.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) { totals }
                        VStack(alignment: .leading, spacing: 4) { totals }
                    }
                }
                if month.pendingCount > 0 {
                    Text("\(month.pendingCount) pending · not included in totals")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(month.title), \(month.transactions.count) charges, \(month.reviewCount) to review")
        .accessibilityValue("\(expanded ? "Expanded" : "Collapsed"). Posted charges: \(month.postedTotals.map { "\($0.amount.formatted(.currency(code: $0.currency))) \($0.currency)" }.joined(separator: ", ")). \(month.pendingCount) pending, excluded from totals.")
        .accessibilityHint("Double tap to \(expanded ? "collapse" : "expand") this month.")
    }

    @ViewBuilder private var totals: some View {
        Text("Posted charges").font(.caption2).foregroundStyle(.secondary)
        ForEach(month.postedTotals, id: \.currency) { total in
            Text("\(total.amount.formatted(.currency(code: total.currency))) \(total.currency)")
                .font(.caption.weight(.semibold).monospacedDigit()).foregroundStyle(.primary)
        }
    }
}

struct InboxSummaryCard: View {
    let transactions: [TransactionRecord]
    let filtering: Bool
    private var reviewCount: Int { transactions.filter { $0.state == .needsReview }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(filtering ? "FILTERED INBOX" : "YOUR SPLIT INBOX", systemImage: "tray")
                    .font(.caption2.weight(.semibold)).tracking(1)
                Spacer()
                Image(systemName: "person.2.fill").accessibilityHidden(true)
            }.foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(reviewCount.formatted()).font(.system(.largeTitle, design: .rounded, weight: .bold))
                Text("to review").font(.headline).foregroundStyle(.secondary)
            }
            Text("\(transactions.count) charges · Credits & refunds excluded")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(Color(.secondarySystemGroupedBackground))
                .overlay(alignment: .topTrailing) {
                    RoundedRectangle(cornerRadius: 24).fill(.indigo.opacity(0.06))
                        .frame(width: 100).allowsHitTesting(false)
                }
        }
    }
}

struct TransactionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transaction: TransactionRecord
    var accountColor: Color? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 19, weight: .medium))
                .frame(width: 42, height: 46)
                .background((accountColor ?? .indigo).opacity(0.10), in: .rect(cornerRadius: 13))
                .foregroundStyle(accountColor ?? .indigo)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 6) {
                if dynamicTypeSize.isAccessibilitySize {
                    merchant
                    amount
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        merchant
                        Spacer(minLength: 4)
                        amount
                    }
                }
                Text(transaction.cardLabel).font(.caption).foregroundStyle(.secondary)
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(transaction.date.formatted(InboxMonth.dayFormat))
                    if let city = transaction.city, !city.isEmpty {
                        Text("· \(city)").lineLimit(1)
                    }
                    Spacer(minLength: 2)
                    if !dynamicTypeSize.isAccessibilitySize { status }
                }.font(.caption2).foregroundStyle(.secondary)
                if dynamicTypeSize.isAccessibilitySize { status }
            }
        }
        .padding(.vertical, 10)
        .accessibilityElement(children: .combine)
    }

    private var merchant: some View {
        Text(transaction.merchant).font(.subheadline.weight(.semibold)).foregroundStyle(.primary)
            .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
    }
    private var amount: some View {
        Text(transaction.amount, format: .currency(code: transaction.currencyCode))
            .font(.subheadline.weight(.semibold).monospacedDigit()).foregroundStyle(.primary)
            .fixedSize(horizontal: true, vertical: false)
    }
    private var status: some View {
        Text(transaction.state.title).font(.caption2.weight(.medium))
            .foregroundStyle(transaction.state == .failed ? Color.red : transaction.state == .needsReview ? .indigo : .secondary)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background((transaction.state == .needsReview ? Color.indigo : Color.secondary).opacity(0.08), in: .capsule)
    }
    private var icon: String {
        let category = TransactionClassification.category(for: transaction).name.lowercased()
        if category.contains("food") || category.contains("drink") { return "fork.knife" }
        if category.contains("grocer") { return "basket.fill" }
        if category.contains("travel") { return "airplane" }
        if category.contains("transport") { return "car.fill" }
        if category.contains("shop") || category.contains("merchandise") { return "bag.fill" }
        if category.contains("entertainment") { return "play.rectangle.fill" }
        if category.contains("medical") { return "cross.case.fill" }
        return "creditcard.fill"
    }
}
