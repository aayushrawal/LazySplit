import SwiftData
import SwiftUI
import UIKit

private struct FocusReviewUndoEntry {
    let transactionID: UUID
    let previousState: ReviewState
}

enum InboxQuickFilter: String, CaseIterable, Identifiable {
    case all, new, large, dining, travel

    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "All"
        case .new: "New"
        case .large: ">$100"
        case .dining: "Dining"
        case .travel: "Travel"
        }
    }
    var symbol: String {
        switch self {
        case .all: "line.3.horizontal.decrease"
        case .new: "sparkles"
        case .large: "dollarsign.circle"
        case .dining: "fork.knife"
        case .travel: "airplane"
        }
    }

    func includes(_ transaction: TransactionRecord) -> Bool {
        let category = TransactionClassification.category(for: transaction).name.lowercased()
        switch self {
        case .all: return true
        case .new: return transaction.isNewInInbox
        case .large: return transaction.amountMinor >= 10_000
        case .dining: return category.contains("food") || category.contains("drink") || category.contains("dining") || category.contains("restaurant")
        case .travel: return category.contains("travel") || category.contains("transport") || category.contains("airline") || category.contains("hotel")
        }
    }
}

struct InboxQuickFilterBar: View {
    @Binding var selection: InboxQuickFilter

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(InboxQuickFilter.allCases) { filter in
                    Button {
                        withAnimation(.snappy) { selection = filter }
                        UISelectionFeedbackGenerator().selectionChanged()
                    } label: {
                        Label(filter.title, systemImage: filter.symbol)
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 11).padding(.vertical, 7)
                            .foregroundStyle(selection == filter ? Color.white : .primary)
                            .background(selection == filter ? Color.indigo : Color(.tertiarySystemFill), in: .capsule)
                    }
                    .buttonStyle(.plain)
                }
            }.padding(.horizontal, 16).padding(.vertical, 8)
        }
        .background(.regularMaterial)
        .accessibilityLabel("Quick transaction filters")
    }
}

struct ReviewSummaryCard: View {
    let transactions: [TransactionRecord]
    let allPostedTransactions: [TransactionRecord]
    let reviewNext: () -> Void

    private var reviewedCount: Int {
        allPostedTransactions.filter { $0.state != .needsReview && $0.state != .pending }.count
    }
    private var reviewableCount: Int { transactions.filter { $0.state == .needsReview }.count }
    private var progress: Double {
        let total = reviewedCount + reviewableCount
        return total == 0 ? 1 : Double(reviewedCount) / Double(total)
    }
    private var amountText: String {
        let totals = Dictionary(grouping: transactions.filter { $0.state == .needsReview }, by: \.currencyCode)
            .mapValues { $0.reduce(0) { $0 + $1.amountMinor } }
        guard totals.count == 1, let total = totals.first else { return totals.isEmpty ? "$0" : "Multiple currencies" }
        return (Decimal(total.value) / 100).formatted(.currency(code: total.key))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Your review queue").font(.headline)
                    Text(reviewableCount == 0 ? "You’re all caught up" : "\(reviewableCount.formatted()) charges · \(amountText)")
                        .font(.title3.weight(.bold)).contentTransition(.numericText())
                }
                Spacer()
                ZStack {
                    Circle().stroke(Color.indigo.opacity(0.14), lineWidth: 6)
                    Circle().trim(from: 0, to: progress).stroke(Color.indigo, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                    Text(progress, format: .percent.precision(.fractionLength(0)))
                        .font(.caption2.bold()).monospacedDigit()
                }.frame(width: 48, height: 48)
            }
            Button(action: reviewNext) {
                Label(reviewableCount == 0 ? "Review complete" : "Review next", systemImage: reviewableCount == 0 ? "checkmark.circle.fill" : "arrow.right.circle.fill")
                    .font(.headline).frame(maxWidth: .infinity).frame(height: 44)
            }
            .buttonStyle(.borderedProminent).tint(.indigo).disabled(reviewableCount == 0)
        }
        .padding(16)
        .background(
            LinearGradient(colors: [Color.indigo.opacity(0.14), Color.blue.opacity(0.06)], startPoint: .topLeading, endPoint: .bottomTrailing),
            in: .rect(cornerRadius: 20)
        )
        .overlay { RoundedRectangle(cornerRadius: 20).stroke(Color.indigo.opacity(0.12)) }
        .accessibilityElement(children: .combine)
    }
}

struct FocusReviewView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var modelContext
    @Environment(AppSession.self) private var session
    @Query private var suggestionRules: [SuggestionRule]
    let transactions: [TransactionRecord]
    @State private var dragOffset: CGSize = .zero
    @State private var splitTransaction: TransactionRecord?
    @State private var deferredIDs = Set<UUID>()
    @State private var randomizedID: UUID?
    @State private var undoHistory = [FocusReviewUndoEntry]()

    private var remaining: [TransactionRecord] {
        transactions.filter { $0.state == .needsReview && !$0.isCredit && !$0.isRemovedFromSource }.sorted { $0.date > $1.date }
    }
    private var currentTransaction: TransactionRecord? {
        if let randomizedID, let randomized = remaining.first(where: { $0.id == randomizedID }) { return randomized }
        return remaining.first(where: { !deferredIDs.contains($0.id) }) ?? remaining.first
    }

    var body: some View {
        NavigationStack {
            ZStack {
                LinearGradient(colors: [Color(.systemGroupedBackground), Color.indigo.opacity(0.08)], startPoint: .top, endPoint: .bottom).ignoresSafeArea()
                if let transaction = currentTransaction {
                    VStack(spacing: 18) {
                        HStack {
                            Text("\(remaining.count.formatted()) left").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                            Spacer()
                            Button { undoLastReview() } label: {
                                Label("Undo", systemImage: "arrow.uturn.backward")
                            }
                            .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                            .disabled(undoHistory.isEmpty)
                            Button { randomize(excluding: transaction.id) } label: {
                                Label("Random", systemImage: "dice.fill")
                            }
                            .font(.caption.weight(.semibold)).buttonStyle(.bordered)
                            .disabled(remaining.count < 2)
                        }.padding(.horizontal, 4)
                        focusCard(transaction)
                            .offset(x: dragOffset.width, y: dragOffset.height * 0.15)
                            .rotationEffect(.degrees(Double(dragOffset.width / 24)))
                            .contentShape(.rect)
                            .onTapGesture {
                                guard abs(dragOffset.width) < 12, abs(dragOffset.height) < 12 else { return }
                                splitTransaction = transaction
                                UISelectionFeedbackGenerator().selectionChanged()
                            }
                            .overlay(alignment: dragOffset.width < 0 ? .topTrailing : .topLeading) {
                                if abs(dragOffset.width) > 35 {
                                    Label(dragOffset.width < 0 ? "PERSONAL" : "SHARED", systemImage: dragOffset.width < 0 ? "person.fill" : "person.2.fill")
                                        .font(.headline.bold()).foregroundStyle(dragOffset.width < 0 ? Color.secondary : Color.indigo)
                                        .padding(12).background(.regularMaterial, in: .rect(cornerRadius: 12)).padding(18)
                                }
                            }
                            .gesture(DragGesture().onChanged { dragOffset = $0.translation }.onEnded { value in
                                if value.translation.width < -95 { classify(transaction, as: .personal) }
                                else if value.translation.width > 95 { classify(transaction, as: .sharedDraft) }
                                else { withAnimation(.spring) { dragOffset = .zero } }
                            })
                            .accessibilityAddTraits(.isButton)
                            .accessibilityHint("Opens transaction details. Swipe left for personal or right for shared.")
                        HStack(spacing: 8) {
                            Button { classify(transaction, as: .personal) } label: {
                                VStack(spacing: 3) { Image(systemName: "person.fill"); Text("Personal").font(.caption.weight(.semibold)) }
                                    .frame(maxWidth: .infinity).frame(height: 50)
                            }.buttonStyle(.bordered).tint(.secondary)
                            Button { deferForLater(transaction) } label: {
                                VStack(spacing: 3) { Image(systemName: "clock.arrow.circlepath"); Text("Later").font(.caption.weight(.semibold)) }
                                    .frame(maxWidth: .infinity).frame(height: 50)
                            }.buttonStyle(.bordered).tint(.orange)
                            Button { splitTransaction = transaction } label: {
                                VStack(spacing: 3) { Image(systemName: "person.2.fill"); Text("Split").font(.caption.weight(.semibold)) }
                                    .frame(maxWidth: .infinity).frame(height: 50)
                            }.buttonStyle(.borderedProminent).tint(.indigo)
                        }
                        Text("Swipe left for personal · right for shared")
                            .font(.caption).foregroundStyle(.secondary)
                    }.padding(18)
                } else {
                    ReviewCompleteView(done: { dismiss() })
                }
            }
            .navigationTitle("Focus review").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
            .sheet(item: $splitTransaction) { transaction in
                NavigationStack { SplitEditorView(transaction: transaction) }
            }
        }
    }

    private func focusCard(_ transaction: TransactionRecord) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            HStack {
                Label(TransactionClassification.category(for: transaction).name, systemImage: "creditcard.fill")
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.indigo)
                Spacer()
                Text(transaction.date.formatted(date: .abbreviated, time: .omitted)).font(.subheadline).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(transaction.merchant).font(.title2.bold()).lineLimit(2)
                Text(transaction.amount, format: .currency(code: transaction.currencyCode))
                    .font(.system(.largeTitle, design: .rounded, weight: .bold)).monospacedDigit()
            }
            Divider()
            Label(transaction.cardLabel, systemImage: "creditcard")
            if transaction.locationLabel != "Unknown location" { Label(transaction.locationLabel, systemImage: "mappin.and.ellipse") }
            if let suggestion = suggestion(for: transaction) {
                Button { splitTransaction = transaction } label: {
                    HStack {
                        Label("Suggested", systemImage: "sparkles")
                        Spacer()
                        Text(suggestion).lineLimit(1)
                        Image(systemName: "chevron.right").font(.caption)
                    }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(.indigo)
                    .padding(12).background(Color.indigo.opacity(0.08), in: .rect(cornerRadius: 12))
                }.buttonStyle(.plain)
            }
        }
        .padding(24).frame(maxWidth: .infinity, minHeight: 330, alignment: .topLeading)
        .background(Color(.secondarySystemGroupedBackground), in: .rect(cornerRadius: 28))
        .shadow(color: .black.opacity(0.08), radius: 20, y: 10)
    }

    private func classify(_ transaction: TransactionRecord, as state: ReviewState) {
        let previousState = transaction.state
        let direction: CGFloat = state == .personal ? -480 : 480
        withAnimation(.easeIn(duration: 0.18)) { dragOffset.width = direction }
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18) {
            undoHistory.append(FocusReviewUndoEntry(transactionID: transaction.id, previousState: previousState))
            transaction.state = state
            transaction.reviewNeedsSync = !session.isDemoMode
            try? modelContext.save()
            session.scheduleReviewPersistence(in: modelContext)
            deferredIDs.remove(transaction.id)
            randomizedID = nil
            dragOffset = .zero
        }
    }

    private func deferForLater(_ transaction: TransactionRecord) {
        deferredIDs.insert(transaction.id)
        randomizedID = nil
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        if remaining.allSatisfy({ deferredIDs.contains($0.id) }) { deferredIDs.removeAll() }
        withAnimation(.snappy) { dragOffset = .zero }
    }

    private func randomize(excluding currentID: UUID) {
        let choices = remaining.filter { $0.id != currentID }
        guard let next = choices.randomElement() else { return }
        randomizedID = next.id
        UISelectionFeedbackGenerator().selectionChanged()
    }

    private func undoLastReview() {
        guard let entry = undoHistory.popLast(),
              let transaction = transactions.first(where: { $0.id == entry.transactionID }) else { return }
        transaction.state = entry.previousState
        transaction.reviewNeedsSync = !session.isDemoMode
        deferredIDs.remove(transaction.id)
        randomizedID = transaction.id
        dragOffset = .zero
        try? modelContext.save()
        session.scheduleReviewPersistence(in: modelContext)
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }

    private func suggestion(for transaction: TransactionRecord) -> String? {
        guard let rule = suggestionRules.first(where: { $0.normalizedMerchant == TransactionFingerprint.normalize(transaction.merchant) }),
              let data = rule.participantNamesJSON.data(using: .utf8),
              let names = try? JSONDecoder().decode([String].self, from: data), !names.isEmpty else { return nil }
        return names.joined(separator: ", ")
    }
}

private struct ReviewCompleteView: View {
    let done: () -> Void
    var body: some View {
        VStack(spacing: 18) {
            Image("LazySplitSlothAccountantLogo").resizable().scaledToFit().frame(width: 150, height: 150)
                .accessibilityHidden(true)
            Text("Inbox zero").font(.largeTitle.bold())
            Text("Every posted charge has been reviewed. Your accountant sloth approves.")
                .multilineTextAlignment(.center).foregroundStyle(.secondary)
            Button("Back to LazySplit", action: done).buttonStyle(.borderedProminent).tint(.indigo)
        }.padding(30).onAppear { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    }
}

enum ActivitySection: String, CaseIterable, Identifiable {
    case reviewed = "Reviewed"
    case outbox = "Outbox"
    var id: String { rawValue }
}

struct ActivityView: View {
    @State private var section = ActivitySection.reviewed
    var body: some View {
        VStack(spacing: 0) {
            Picker("Activity", selection: $section) {
                ForEach(ActivitySection.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented).padding(.horizontal, 16).padding(.vertical, 8).background(.regularMaterial)
            if section == .reviewed { InboxView(reviewScope: .reviewed) }
            else { OutboxView() }
        }
    }
}

struct WeeklyRecapCard: View {
    let transactions: [TransactionRecord]
    @State private var shareImage: ShareableImage?

    private var weekly: [TransactionRecord] {
        let start = Calendar.current.date(byAdding: .day, value: -7, to: .now) ?? .distantPast
        return transactions.filter { $0.updatedAt >= start && $0.state != .needsReview && $0.state != .pending }
    }
    private var sharedCount: Int { weekly.filter { [.sharedDraft, .queued, .published, .failed].contains($0.state) }.count }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("This week", systemImage: "chart.line.uptrend.xyaxis").font(.headline)
                Spacer()
                Button { makeShareImage() } label: { Image(systemName: "square.and.arrow.up") }.disabled(weekly.isEmpty)
            }
            HStack(spacing: 24) {
                metric(weekly.count, "reviewed")
                metric(sharedCount, "shared")
                metric(weekly.filter { $0.state == .personal }.count, "personal")
            }
            Text(weekly.isEmpty ? "Review charges to build your weekly recap." : "A calm summary—no spending judgment, no streak pressure.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .padding(16).background(Color.indigo.opacity(0.08), in: .rect(cornerRadius: 18))
        .sheet(item: $shareImage) { image in ActivityShareSheet(items: [image.image]) }
    }

    private func metric(_ value: Int, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) { Text(value.formatted()).font(.title2.bold()).monospacedDigit(); Text(label).font(.caption).foregroundStyle(.secondary) }
    }
    @MainActor private func makeShareImage() {
        let renderer = ImageRenderer(content: RecapPoster(reviewed: weekly.count, shared: sharedCount).frame(width: 360, height: 450))
        renderer.scale = 3
        if let image = renderer.uiImage { shareImage = ShareableImage(image: image) }
    }
}

private struct RecapPoster: View {
    let reviewed: Int
    let shared: Int
    var body: some View {
        ZStack {
            LinearGradient(colors: [.indigo, .blue.opacity(0.75)], startPoint: .topLeading, endPoint: .bottomTrailing)
            VStack(spacing: 18) {
                Image("LazySplitSlothAccountantLogo").resizable().scaledToFit().frame(width: 130, height: 130)
                Text("LazySplit weekly recap").font(.title.bold())
                Text("I reviewed \(reviewed) charges\nand found \(shared) shared expenses.")
                    .font(.title2.weight(.semibold)).multilineTextAlignment(.center)
                Text("Money admin, minus the drama.").font(.subheadline).opacity(0.8)
            }.foregroundStyle(.white).padding(30)
        }.clipShape(.rect(cornerRadius: 32))
    }
}

private struct ShareableImage: Identifiable { let id = UUID(); let image: UIImage }
private struct ActivityShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
