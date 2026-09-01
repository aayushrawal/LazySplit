import SwiftUI

struct InboxCountBadge: View {
    let count: Int

    var body: some View {
        Text(count.formatted())
            .font(.caption.weight(.semibold).monospacedDigit())
            .lineLimit(1)
            .fixedSize(horizontal: true, vertical: false)
            .frame(minWidth: 18)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(.indigo.opacity(0.1), in: .capsule)
    }
}

enum InboxArrivalGroups {
    static func newTransactions(in records: [TransactionRecord]) -> [TransactionRecord] {
        records.filter(\.isNewInInbox).sorted {
            if $0.inboxReceivedAt != $1.inboxReceivedAt { return ($0.inboxReceivedAt ?? .distantPast) > ($1.inboxReceivedAt ?? .distantPast) }
            return $0.date == $1.date ? $0.id.uuidString < $1.id.uuidString : $0.date > $1.date
        }
    }

    static func monthlyTransactions(in records: [TransactionRecord]) -> [TransactionRecord] {
        records.filter { !$0.isNewInInbox }
    }
}

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

enum InboxGrouping: String, CaseIterable, Identifiable {
    case month, year, account
    var id: String { rawValue }
    var title: String {
        switch self { case .month: "Month"; case .year: "Year"; case .account: "Card / account" }
    }
    var sectionTitle: String {
        switch self { case .month: "Monthly"; case .year: "Yearly"; case .account: "By card / account" }
    }
}

struct InboxHistoryGroup: Identifiable {
    let id: String
    let title: String
    let transactions: [TransactionRecord]
    var reviewCount: Int { transactions.filter { $0.state == .needsReview }.count }
    var pendingCount: Int { transactions.filter { $0.state == .pending }.count }
    var postedTotals: [(currency: String, amount: Decimal)] {
        InboxMonth(id: .distantPast, transactions: transactions).postedTotals
    }

    static func group(_ records: [TransactionRecord], by grouping: InboxGrouping, sort: InboxSort) -> [InboxHistoryGroup] {
        let records = InboxArrivalGroups.monthlyTransactions(in: records).filter { !$0.isCredit && $0.amountMinor > 0 }
        var ordering = InboxFilters()
        ordering.sort = sort
        switch grouping {
        case .month:
            return InboxMonth.group(records, sort: sort).map {
                InboxHistoryGroup(id: "month:\($0.id.timeIntervalSince1970)", title: $0.title, transactions: $0.transactions)
            }
        case .year:
            return Dictionary(grouping: records) { InboxMonth.calendar.component(.year, from: $0.date) }
                .sorted { sort == .oldest ? $0.key < $1.key : $0.key > $1.key }
                .map { InboxHistoryGroup(id: "year:\($0.key)", title: String($0.key), transactions: ordering.ordered($0.value)) }
        case .account:
            return Dictionary(grouping: records, by: \.accountColorKey)
                .map { InboxHistoryGroup(id: "account:\($0.key)", title: $0.value.first!.cardLabel, transactions: ordering.ordered($0.value)) }
                .sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }
}

struct InboxGroupHeader: View {
    let group: InboxHistoryGroup
    let expanded: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline) {
                    Text(group.title).font(.headline.weight(.bold)).foregroundStyle(.primary)
                    Spacer(minLength: 8)
                    Image(systemName: expanded ? "chevron.up" : "chevron.down")
                        .font(.caption.weight(.bold)).foregroundStyle(.secondary)
                }
                Text("\(group.transactions.count) charges · \(group.reviewCount) to review")
                    .font(.caption).foregroundStyle(.secondary)
                if !group.postedTotals.isEmpty {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline) { totals }
                        VStack(alignment: .leading, spacing: 4) { totals }
                    }
                }
                if group.pendingCount > 0 {
                    Text("\(group.pendingCount) pending · not included in totals")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            .padding(.vertical, 4)
            .frame(minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(group.title), \(group.transactions.count) charges, \(group.reviewCount) to review")
        .accessibilityValue("\(expanded ? "Expanded" : "Collapsed"). Posted charges: \(group.postedTotals.map { "\($0.amount.formatted(.currency(code: $0.currency))) \($0.currency)" }.joined(separator: ", ")). \(group.pendingCount) pending, excluded from totals.")
        .accessibilityHint("Double tap to \(expanded ? "collapse" : "expand") this group.")
    }

    @ViewBuilder private var totals: some View {
        Text("Posted charges").font(.caption2).foregroundStyle(.secondary)
        ForEach(group.postedTotals, id: \.currency) { total in
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
        VStack(alignment: .leading, spacing: 5) {
            Text(filtering ? "FILTERED INBOX" : "INBOX")
                .font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                .padding(.horizontal, 20)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    Label("\(transactions.count) charges", systemImage: "tray")
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(.secondarySystemGroupedBackground), in: .capsule)
                    Label("\(reviewCount) to review", systemImage: "checklist")
                        .font(.caption.weight(.medium)).foregroundStyle(.indigo)
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color(.secondarySystemGroupedBackground), in: .capsule)
                }.fixedSize(horizontal: true, vertical: false).padding(.horizontal, 20)
            }
        }
        .padding(.top, 4).padding(.bottom, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityHint("Credits and refunds are excluded from Inbox.")
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
