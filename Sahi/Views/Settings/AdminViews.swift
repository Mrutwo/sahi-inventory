import SwiftUI

/// Admin: approve new volunteers, promote coordinators, revoke access.
struct MembersView: View {
    @Environment(SessionStore.self) private var session
    @Environment(ToastCenter.self) private var toasts

    @State private var members: [Member] = []
    @State private var isLoading = false
    @State private var error: AppError?
    @State private var search = ""
    @State private var confirmingDeactivation: Member?

    var body: some View {
        List {
            if let error, members.isEmpty {
                ContentUnavailableView {
                    Label("לא הצלחנו לטעון את המתנדבים", systemImage: "person.2.slash")
                } description: {
                    Text(error.localizedDescription)
                }
            }
            let pending = filtered.filter { $0.isActive && $0.role == .pending }
            if !pending.isEmpty {
                Section {
                    ForEach(pending) { member in
                        memberRow(member)
                    }
                } header: {
                    Text("ממתינים לאישור")
                } footer: {
                    Text("מתנדבים שנרשמו אך עדיין לא הזינו קוד הצטרפות. אשרו רק מי שאתם מכירים.")
                }
            }
            Section("פעילים") {
                ForEach(filtered.filter { $0.isActive && $0.role != .pending }) { member in
                    memberRow(member)
                }
            }
            let inactive = filtered.filter { !$0.isActive }
            if !inactive.isEmpty {
                Section("גישה הושבתה") {
                    ForEach(inactive) { member in
                        memberRow(member)
                    }
                }
            }
        }
        .overlay {
            if isLoading && members.isEmpty {
                ProgressView()
            }
        }
        .searchable(text: $search, prompt: Text("חיפוש מתנדב/ת"))
        .navigationTitle(Text("ניהול מתנדבים"))
        .refreshable { await load() }
        .task { await load() }
        .confirmationDialog(
            Text("השבתת גישה"),
            isPresented: Binding(get: { confirmingDeactivation != nil }, set: { if !$0 { confirmingDeactivation = nil } }),
            titleVisibility: .visible,
            presenting: confirmingDeactivation
        ) { member in
            Button("השבתת הגישה של \(member.displayName)", role: .destructive) {
                update(member, role: member.role == .pending ? .volunteer : member.role, isActive: false)
            }
            Button("ביטול", role: .cancel) {}
        } message: { _ in
            Text("המתנדב/ת לא יוכל/תוכל לראות או לעדכן את המלאי, החל מעכשיו. ההיסטוריה שלו/ה נשמרת. אפשר להחזיר גישה בכל עת.")
        }
    }

    private var filtered: [Member] {
        let needle = search.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return members }
        return members.filter {
            $0.displayName.lowercased().contains(needle) || ($0.email?.lowercased().contains(needle) ?? false)
        }
    }

    private func memberRow(_ member: Member) -> some View {
        let isMe = member.id == session.profile?.id

        return HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.displayName)
                        .font(.headline)
                    if isMe {
                        Text("(את/ה)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                if let email = member.email {
                    Text(email)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(member.isActive ? member.role.title : String(localized: "גישה הושבתה"))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(member.isActive ? Brand.blue : Brand.danger)
            }
            Spacer()
            Menu {
                if member.isActive {
                    if member.role == .pending {
                        Button {
                            update(member, role: .volunteer, isActive: true)
                        } label: {
                            Label("אישור כמתנדב/ת", systemImage: "checkmark.circle")
                        }
                    }
                    if member.role == .volunteer {
                        Button {
                            update(member, role: .admin, isActive: true)
                        } label: {
                            Label("מינוי למנהל/ת", systemImage: "star")
                        }
                    }
                    if member.role == .admin && !isMe {
                        Button {
                            update(member, role: .volunteer, isActive: true)
                        } label: {
                            Label("הסרת הרשאות ניהול", systemImage: "star.slash")
                        }
                    }
                    if !isMe {
                        Button(role: .destructive) {
                            confirmingDeactivation = member
                        } label: {
                            Label("השבתת גישה", systemImage: "person.crop.circle.badge.xmark")
                        }
                    }
                } else {
                    Button {
                        update(member, role: member.role == .pending ? .volunteer : member.role, isActive: true)
                    } label: {
                        Label("החזרת גישה", systemImage: "person.crop.circle.badge.checkmark")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.title3)
                    .frame(minWidth: 44, minHeight: 44)
            }
            .accessibilityLabel(Text("פעולות עבור \(member.displayName)"))
        }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            members = try await session.admin.listMembers()
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? AppError) ?? AppError.fromGeneric(error)
        }
    }

    private func update(_ member: Member, role: MemberRole, isActive: Bool) {
        Task {
            do {
                try await session.admin.updateMember(id: member.id, role: role, isActive: isActive)
                toasts.show(String(localized: "העדכון נשמר"))
                await load()
            } catch {
                let appError = (error as? AppError) ?? AppError.fromGeneric(error)
                toasts.show(appError.localizedDescription, style: .error)
            }
        }
    }
}

/// Admin: set a new join code (e.g. at the start of a season or after a leak).
struct JoinCodeView: View {
    @Environment(SessionStore.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @State private var code = ""
    @State private var isSaving = false
    @State private var error: AppError?

    var body: some View {
        Form {
            Section {
                TextField("קוד חדש", text: $code)
                    .textInputAutocapitalization(.characters)
                    .autocorrectionDisabled()
                    .font(.title3.monospaced())
                    .environment(\.layoutDirection, .leftToRight)
                Button("יצירת קוד אקראי") {
                    code = Self.randomCode()
                }
            } footer: {
                Text("מתנדבים חדשים מזינים את הקוד פעם אחת אחרי ההרשמה. החלפת הקוד לא משפיעה על מי שכבר הצטרף. הקוד נשמר בשרת רק בצורה מוצפנת (hash), ולכן לא ניתן להציג את הקוד הנוכחי.")
            }
            if let error {
                Text(error.localizedDescription)
                    .foregroundStyle(Brand.danger)
            }
            Section {
                Button {
                    save()
                } label: {
                    if isSaving {
                        ProgressView()
                    } else {
                        Text("שמירת הקוד")
                    }
                }
                .disabled(code.trimmingCharacters(in: .whitespaces).count < 6 || isSaving)
            } footer: {
                Text("לפחות 6 תווים. שתפו את הקוד רק עם מתנדבים מוכרים.")
            }
        }
        .navigationTitle(Text("קוד הצטרפות"))
    }

    private func save() {
        isSaving = true
        error = nil
        Task {
            defer { isSaving = false }
            do {
                try await session.admin.setJoinCode(code.trimmingCharacters(in: .whitespaces))
                toasts.show(String(localized: "קוד ההצטרפות עודכן"))
            } catch {
                self.error = (error as? AppError) ?? AppError.fromGeneric(error)
            }
        }
    }

    static func randomCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let part = { String((0..<4).map { _ in alphabet.randomElement()! }) }
        return "SAHI-\(part())-\(part())"
    }
}

/// Admin: products removed from the active inventory, with restore.
struct ArchivedProductsView: View {
    @Environment(InventoryStore.self) private var store
    @Environment(ToastCenter.self) private var toasts
    @State private var items: [InventoryItem] = []
    @State private var isLoading = false
    @State private var error: AppError?

    var body: some View {
        List {
            if items.isEmpty && !isLoading {
                ContentUnavailableView("אין מוצרים שהוסרו", systemImage: "archivebox",
                                       description: Text(error?.localizedDescription ?? ""))
            }
            ForEach(items) { item in
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name).font(.headline)
                        Text("\(store.unit(for: item.unitCode).displayName) · \(item.updatedAt.sahiDateTime)")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("החזרה למלאי") {
                        restore(item)
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .overlay {
            if isLoading && items.isEmpty { ProgressView() }
        }
        .navigationTitle(Text("מוצרים שהוסרו"))
        .refreshable { await load() }
        .task { await load() }
    }

    private func load() async {
        isLoading = true
        defer { isLoading = false }
        do {
            items = try await store.fetchArchivedProducts()
            error = nil
        } catch is CancellationError {
            return
        } catch {
            self.error = (error as? AppError) ?? AppError.fromGeneric(error)
        }
    }

    private func restore(_ item: InventoryItem) {
        Task {
            do {
                try await store.restoreProduct(id: item.id)
                toasts.show(String(localized: "\(item.name) הוחזר למלאי"))
                await load()
            } catch {
                let appError = (error as? AppError) ?? AppError.fromGeneric(error)
                toasts.show(appError.localizedDescription, style: .error)
            }
        }
    }
}
