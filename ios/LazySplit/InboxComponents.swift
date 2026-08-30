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
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(month.title).font(.headline.weight(.bold)).foregroundStyle(.primary)
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
            .padding(.vertical, 4)
            .frame(minHeight: 44)
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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transactions: [TransactionRecord]
    let filtering: Bool
    private var reviewCount: Int { transactions.filter { $0.state == .needsReview }.count }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                context
                Spacer(minLength: 8)
                reviewCountLabel
            }
            VStack(alignment: .leading, spacing: 6) {
                context
                reviewCountLabel
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 16))
        .accessibilityElement(children: .combine)
        .accessibilityHint("Credits and refunds are excluded from Inbox.")
    }

    private var context: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(filtering ? "FILTERED INBOX" : "YOUR SPLIT INBOX")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text("\(transactions.count) charges").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var reviewCountLabel: some View {
        HStack(alignment: .firstTextBaseline, spacing: 5) {
            Text(reviewCount.formatted()).font(.system(.title2, design: .rounded, weight: .bold))
            Text("to review").font(.caption.weight(.medium)).foregroundStyle(.secondary)
        }
        .fixedSize(horizontal: !dynamicTypeSize.isAccessibilitySize, vertical: true)
    }
}

struct InboxAccountLegend: View {
    let accounts: [TransactionRecord]
    let colors: [String: Int]

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("CARDS & ACCOUNTS").font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            if accounts.isEmpty {
                Text("Connected accounts will appear here.").font(.caption).foregroundStyle(.secondary)
                    .padding(.horizontal, 20)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(accounts, id: \.accountColorKey) { account in
                            HStack(spacing: 6) {
                                Circle().fill(AccountColors.color(for: account.accountColorKey, in: colors))
                                    .frame(width: 8, height: 8).accessibilityHidden(true)
                                Text(account.cardLabel).font(.caption.weight(.medium))
                                    .fixedSize(horizontal: true, vertical: false)
                            }
                            .padding(.horizontal, 10).padding(.vertical, 6)
                            .background(Color(.secondarySystemGroupedBackground), in: .capsule)
                        }
                    }.padding(.horizontal, 20)
                }
                .accessibilityLabel("Card and account color legend")
                .accessibilityHint("Scroll horizontally to see additional accounts.")
            }
        }
        .padding(.top, 4).padding(.bottom, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial)
    }
}

struct TransactionRow: View {
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    let transaction: TransactionRecord
    var accountColor: Color? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 17, weight: .medium))
                .frame(width: 36, height: 38)
                .background((accountColor ?? .indigo).opacity(0.10), in: .rect(cornerRadius: 11))
                .foregroundStyle(accountColor ?? .indigo)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
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
        .padding(.vertical, 5)
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
