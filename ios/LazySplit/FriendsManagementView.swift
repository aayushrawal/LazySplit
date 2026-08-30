import SwiftUI

struct FriendsManagementView: View {
    @Environment(AppSession.self) private var session
    @State private var friends: [SplitwiseFriend] = []
    @State private var groups: [FriendGroup] = []
    @State private var sort: FriendSort = .custom
    @State private var renamingFriend: SplitwiseFriend?
    @State private var groupEditor: GroupEditorContext?
    @State private var message: String?
    @State private var loading = false
    @State private var showingAddFriends = false

    private var displayedFriends: [SplitwiseFriend] {
        switch sort {
        case .custom:
            friends.sorted {
                let lhs = $0.sortOrder ?? Int.max, rhs = $1.sortOrder ?? Int.max
                return lhs == rhs ? $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending : lhs < rhs
            }
        case .mostInteracted:
            friends.sorted { $0.interactionCount == $1.interactionCount ? $0.displayName < $1.displayName : $0.interactionCount > $1.interactionCount }
        case .alphabetical:
            friends.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
        }
    }

    var body: some View {
        List {
            Section {
                Picker("Friend order", selection: $sort) {
                    ForEach(FriendSort.allCases) { option in Text(option.title).tag(option) }
                }.pickerStyle(.segmented)
            } footer: {
                Text(sort == .mostInteracted ? "Based on how often each person appears in your published LazySplit expenses." : sort == .custom ? "Use Edit to drag friends into your preferred order." : "Uses your local nickname when one is set.")
            }

            Section("Groups") {
                Button { groupEditor = GroupEditorContext(group: nil) } label: { Label("Create a group", systemImage: "person.3.fill") }
                if groups.isEmpty {
                    Text("Create groups for roommates, trips, or people you split with often.").font(.subheadline).foregroundStyle(.secondary)
                }
                ForEach(groups) { group in
                    Button { groupEditor = GroupEditorContext(group: group) } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "person.3.sequence.fill").foregroundStyle(.teal)
                                .frame(width: 38, height: 38).background(Color.teal.opacity(0.12), in: .circle)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(group.name).foregroundStyle(.primary).font(.headline)
                                Text("\(group.friendIDs.count) member\(group.friendIDs.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                        }
                    }
                    .swipeActions { Button("Delete", role: .destructive) { Task { await delete(group) } } }
                }
            }

            Section("Friends") {
                Button { showingAddFriends = true } label: { Label("Add friends from Splitwise", systemImage: "person.badge.plus") }
                if loading && friends.isEmpty { HStack { Spacer(); ProgressView(); Spacer() } }
                if !loading && friends.isEmpty {
                    ContentUnavailableView("Your friends list is empty", systemImage: "person.2", description: Text("Add only the people you split with from your Splitwise friends. Nobody is added automatically."))
                }
                ForEach(displayedFriends) { friend in
                    FriendManagementRow(friend: friend)
                        .moveDisabled(sort != .custom)
                        .contentShape(.rect)
                        .onTapGesture { renamingFriend = friend }
                        .swipeActions {
                            Button("Remove", role: .destructive) { Task { await remove(friend) } }
                            Button("Rename") { renamingFriend = friend }.tint(.indigo)
                        }
                }
                .onMove(perform: moveFriends)
            }

            if session.isDemoMode { Section { Text("Changes in demo mode last until you leave the demo.").font(.caption).foregroundStyle(.secondary) } }
            if let message { Section { Text(message).foregroundStyle(.secondary) } }
        }
        .navigationTitle("Friends")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) { if sort == .custom && !friends.isEmpty { EditButton() } }
            ToolbarItem(placement: .topBarTrailing) { Button { Task { await load() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }.disabled(loading) }
        }
        .task { await load() }
        .sheet(isPresented: $showingAddFriends) {
            AddFriendsView(addedIDs: Set(friends.map(\.id))) { selected in
                if session.isDemoMode {
                    session.demoFriends.append(contentsOf: selected.filter { item in !session.demoFriends.contains(where: { $0.id == item.id }) })
                } else { try await session.api.addFriends(ids: selected.map(\.id)) }
                await load()
            }
        }
        .sheet(item: $renamingFriend) { friend in
            RenameFriendView(friend: friend) { alias in await rename(friend, alias: alias) }
        }
        .sheet(item: $groupEditor) { context in
            FriendGroupEditorView(friends: displayedFriends, group: context.group) { name, friendIDs in
                try await saveGroup(context.group, name: name, friendIDs: friendIDs)
            }
        }
    }

    @MainActor private func load() async {
        loading = true; defer { loading = false }
        if session.isDemoMode {
            friends = session.demoFriends
            return
        }
        do {
            async let loadedFriends = session.api.friends()
            async let loadedGroups = session.api.friendGroups()
            friends = try await loadedFriends
            groups = try await loadedGroups
            message = nil
        } catch { message = error.localizedDescription }
    }

    private func moveFriends(from source: IndexSet, to destination: Int) {
        var ordered = displayedFriends
        ordered.move(fromOffsets: source, toOffset: destination)
        friends = ordered.enumerated().map { index, friend in
            SplitwiseFriend(id: friend.id, firstName: friend.firstName, lastName: friend.lastName, alias: friend.alias, sortOrder: index, interactionCount: friend.interactionCount)
        }
        guard !session.isDemoMode else { session.demoFriends = friends; return }
        Task { do { try await session.api.reorderFriends(ids: friends.map(\.id)) } catch { message = error.localizedDescription } }
    }

    @MainActor private func rename(_ friend: SplitwiseFriend, alias: String?) async {
        if !session.isDemoMode {
            do { try await session.api.renameFriend(id: friend.id, alias: alias) }
            catch { message = error.localizedDescription; return }
        }
        guard let index = friends.firstIndex(where: { $0.id == friend.id }) else { return }
        friends[index] = SplitwiseFriend(id: friend.id, firstName: friend.firstName, lastName: friend.lastName, alias: alias, sortOrder: friend.sortOrder, interactionCount: friend.interactionCount)
        if session.isDemoMode { session.demoFriends = friends }
    }

    @MainActor private func remove(_ friend: SplitwiseFriend) async {
        if !session.isDemoMode {
            do { try await session.api.removeFriend(id: friend.id) }
            catch { message = error.localizedDescription; return }
        }
        friends.removeAll { $0.id == friend.id }
        if session.isDemoMode { session.demoFriends = friends }
        message = "Removed from your LazySplit list. Splitwise, existing groups, and past expenses are unchanged."
    }

    @MainActor private func saveGroup(_ existing: FriendGroup?, name: String, friendIDs: [Int]) async throws {
        if session.isDemoMode {
            if let existing, let index = groups.firstIndex(where: { $0.id == existing.id }) {
                groups[index] = FriendGroup(id: existing.id, name: name, friendIDs: friendIDs, createdAt: existing.createdAt)
            } else { groups.append(FriendGroup(id: UUID(), name: name, friendIDs: friendIDs, createdAt: .now)) }
        } else if let existing {
            try await session.api.updateFriendGroup(id: existing.id, name: name, friendIDs: friendIDs)
            await load()
        } else {
            groups.append(try await session.api.createFriendGroup(name: name, friendIDs: friendIDs))
        }
    }

    @MainActor private func delete(_ group: FriendGroup) async {
        if !session.isDemoMode {
            do { try await session.api.deleteFriendGroup(id: group.id) }
            catch { message = error.localizedDescription; return }
        }
        groups.removeAll { $0.id == group.id }
    }
}

private struct FriendManagementRow: View {
    let friend: SplitwiseFriend
    private var initials: String { String(friend.displayName.split(separator: " ").prefix(2).compactMap(\.first)) }

    var body: some View {
        HStack(spacing: 12) {
            Text(initials.uppercased()).font(.subheadline.bold()).foregroundStyle(.indigo)
                .frame(width: 42, height: 42).background(Color.indigo.opacity(0.12), in: .circle)
            VStack(alignment: .leading, spacing: 2) {
                Text(friend.displayName).font(.headline)
                if friend.alias != nil { Text(friend.originalName).font(.caption).foregroundStyle(.secondary) }
            }
            Spacer()
            if friend.interactionCount > 0 {
                VStack(alignment: .trailing, spacing: 1) {
                    Text("\(friend.interactionCount)").font(.headline.monospacedDigit())
                    Text("splits").font(.caption2).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 3)
    }
}

private struct RenameFriendView: View {
    @Environment(\.dismiss) private var dismiss
    let friend: SplitwiseFriend
    let onSave: @MainActor (String?) async -> Void
    @State private var alias: String
    @State private var saving = false

    init(friend: SplitwiseFriend, onSave: @escaping @MainActor (String?) async -> Void) {
        self.friend = friend; self.onSave = onSave; _alias = State(initialValue: friend.alias ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(friend.originalName, text: $alias).textInputAutocapitalization(.words)
                } header: { Text("Local nickname") } footer: { Text("This changes the name only inside LazySplit. Splitwise keeps the original name.") }
                if friend.alias != nil { Section { Button("Use Splitwise name") { alias = "" } } }
            }
            .navigationTitle("Rename friend").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { saving = true; await onSave(alias.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty); saving = false; dismiss() } }.disabled(saving)
                }
            }
        }
    }
}

private struct FriendGroupEditorView: View {
    @Environment(\.dismiss) private var dismiss
    let friends: [SplitwiseFriend]
    let group: FriendGroup?
    let onSave: @MainActor (String, [Int]) async throws -> Void
    @State private var name: String
    @State private var selected: Set<Int>
    @State private var saving = false
    @State private var errorMessage: String?

    init(friends: [SplitwiseFriend], group: FriendGroup?, onSave: @escaping @MainActor (String, [Int]) async throws -> Void) {
        self.friends = friends; self.group = group; self.onSave = onSave
        _name = State(initialValue: group?.name ?? ""); _selected = State(initialValue: Set(group?.friendIDs ?? []))
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Group name") { TextField("Roommates, ski trip…", text: $name).textInputAutocapitalization(.words) }
                Section("Members") {
                    ForEach(friends) { friend in
                        Button { if selected.contains(friend.id) { selected.remove(friend.id) } else { selected.insert(friend.id) } } label: {
                            HStack { Text(friend.displayName).foregroundStyle(.primary); Spacer(); Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.indigo) }
                        }
                    }
                    let hiddenCount = selected.subtracting(Set(friends.map(\.id))).count
                    if hiddenCount > 0 {
                        Text("\(hiddenCount) existing member(s) are not in your friends list. They will stay in this group; add them from Splitwise to edit their membership.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                if let errorMessage { Section { Text(errorMessage).foregroundStyle(.red) } }
            }
            .navigationTitle(group == nil ? "New group" : "Edit group").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        Task { @MainActor in
                            saving = true; defer { saving = false }
                            do { try await onSave(name.trimmingCharacters(in: .whitespacesAndNewlines), selected.sorted()); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }.disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || selected.isEmpty || saving)
                }
            }
        }
    }
}

private struct AddFriendsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppSession.self) private var session
    let addedIDs: Set<Int>
    let onAdd: @MainActor ([SplitwiseFriend]) async throws -> Void
    @State private var directory: [SplitwiseFriend] = []
    @State private var selected: Set<Int> = []
    @State private var search = ""
    @State private var loading = false
    @State private var saving = false
    @State private var errorMessage: String?

    private var available: [SplitwiseFriend] {
        directory.filter { !addedIDs.contains($0.id) }
    }
    private var results: [SplitwiseFriend] {
        available.filter { search.isEmpty || $0.displayName.localizedCaseInsensitiveContains(search) || $0.originalName.localizedCaseInsensitiveContains(search) }
            .sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text("Choose who appears in LazySplit. This won't create or change friendships in Splitwise.").font(.subheadline).foregroundStyle(.secondary)
                }
                if loading { ProgressView("Loading Splitwise friends…") }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
                if !loading && errorMessage == nil && results.isEmpty {
                    ContentUnavailableView(search.isEmpty ? "No friends to add" : "No matches", systemImage: "person.2", description: Text(search.isEmpty ? "Everyone on this list is already added, or Splitwise has no friends yet. Pull to refresh after adding someone in Splitwise." : "Try another name."))
                }
                ForEach(results) { friend in
                    Button {
                        if selected.contains(friend.id) { selected.remove(friend.id) } else { selected.insert(friend.id) }
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(friend.displayName).foregroundStyle(.primary)
                                if friend.alias != nil { Text(friend.originalName).font(.caption).foregroundStyle(.secondary) }
                            }
                            Spacer()
                            Image(systemName: selected.contains(friend.id) ? "checkmark.circle.fill" : "circle").foregroundStyle(.indigo)
                        }
                    }.accessibilityAddTraits(selected.contains(friend.id) ? .isSelected : [])
                }
            }
            .searchable(text: $search, prompt: "Search Splitwise friends")
            .refreshable { await load(refresh: true) }
            .navigationTitle("Add friends")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() }.disabled(saving) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add\(selected.isEmpty ? "" : " (\(selected.count))")") {
                        Task { @MainActor in
                            saving = true; defer { saving = false }
                            do { try await onAdd(available.filter { selected.contains($0.id) }); dismiss() }
                            catch { errorMessage = error.localizedDescription }
                        }
                    }.disabled(selected.isEmpty || saving || loading)
                }
            }
            .interactiveDismissDisabled(saving)
            .task { await load(refresh: false) }
        }
    }

    @MainActor private func load(refresh: Bool) async {
        guard !saving else { return }
        loading = true; defer { loading = false }
        do {
            directory = session.isDemoMode ? DemoData.friends : try await session.api.availableFriends(refresh: refresh)
            selected.formIntersection(Set(available.map(\.id)))
            errorMessage = nil
        } catch { errorMessage = error.localizedDescription }
    }
}

private enum FriendSort: String, CaseIterable, Identifiable {
    case custom, mostInteracted, alphabetical
    var id: String { rawValue }
    var title: String { self == .custom ? "My Order" : self == .mostInteracted ? "Most Used" : "A–Z" }
}

private struct GroupEditorContext: Identifiable {
    let id = UUID()
    let group: FriendGroup?
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
