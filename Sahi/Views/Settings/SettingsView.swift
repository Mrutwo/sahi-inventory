import SwiftUI

struct SettingsView: View {
    @Environment(SessionStore.self) private var session
    @Environment(InventoryStore.self) private var store
    @AppStorage(AppearancePreference.storageKey) private var appearance: AppearancePreference = .system
    @AppStorage(InventoryLayout.storageKey) private var layout: InventoryLayout = .cards

    @State private var isEditingName = false
    @State private var isConfirmingSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                accountSection

                Section("תצוגה") {
                    Picker(selection: $appearance) {
                        ForEach(AppearancePreference.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    } label: {
                        Label("ערכת נושא", systemImage: "circle.lefthalf.filled")
                    }
                    Picker(selection: $layout) {
                        ForEach(InventoryLayout.allCases) { option in
                            Label(option.title, systemImage: option.symbol).tag(option)
                        }
                    } label: {
                        Label("תצוגת המלאי", systemImage: "rectangle.grid.1x2")
                    }
                }

                Section {
                    LabeledContent {
                        Text(syncStatus)
                            .foregroundStyle(.secondary)
                    } label: {
                        Label("סנכרון", systemImage: store.isRealtimeConnected ? "checkmark.icloud" : "icloud.slash")
                    }
                    if let synced = store.lastSyncedAt {
                        LabeledContent("עדכון אחרון", value: synced.sahiDateTime)
                    }
                } header: {
                    Text("מלאי משותף")
                } footer: {
                    Text("כל השינויים נשמרים בשרת המשותף ומופיעים מיד אצל כל המתנדבים.")
                }

                if session.isAdmin {
                    Section {
                        NavigationLink {
                            MembersView()
                        } label: {
                            Label("ניהול מתנדבים", systemImage: "person.2")
                        }
                        NavigationLink {
                            JoinCodeView()
                        } label: {
                            Label("קוד הצטרפות", systemImage: "key")
                        }
                        NavigationLink {
                            ArchivedProductsView()
                        } label: {
                            Label("מוצרים שהוסרו", systemImage: "archivebox")
                        }
                    } header: {
                        Text("ניהול")
                    }
                }

                aboutSection

                Section {
                    Button(role: .destructive) {
                        isConfirmingSignOut = true
                    } label: {
                        Label("התנתקות", systemImage: "rectangle.portrait.and.arrow.right")
                    }
                }
            }
            .navigationTitle(Text("הגדרות"))
            .confirmationDialog(Text("להתנתק מהאפליקציה?"), isPresented: $isConfirmingSignOut, titleVisibility: .visible) {
                Button("התנתקות", role: .destructive) {
                    Task { await session.signOut() }
                }
                Button("ביטול", role: .cancel) {}
            } message: {
                if store.pending.waiting.isEmpty {
                    Text("המלאי נשמר בשרת. אפשר להתחבר שוב בכל עת.")
                } else {
                    Text("יש שינויים שעדיין לא נשלחו. התנתקות תמחק אותם מהמכשיר.")
                }
            }
            .sheet(isPresented: $isEditingName) {
                DisplayNameSheet(currentName: session.profile?.displayName ?? "")
                    .presentationDetents([.medium])
            }
        }
    }

    private var syncStatus: String {
        if !store.isOnline { return String(localized: "לא מקוון") }
        return store.isRealtimeConnected ? String(localized: "מחובר בזמן אמת") : String(localized: "מתחבר…")
    }

    private var accountSection: some View {
        Section("החשבון שלי") {
            HStack(spacing: 14) {
                Text(initials)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(width: 48, height: 48)
                    .background(Brand.blue, in: Circle())
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(session.profile?.displayName ?? "")
                        .font(.headline)
                    if let email = session.email {
                        Text(email)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    if let role = session.profile?.role {
                        Text(role.title)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Brand.blue)
                    }
                }
            }
            .padding(.vertical, 4)
            Button {
                isEditingName = true
            } label: {
                Label("שינוי שם תצוגה", systemImage: "pencil")
            }
        }
    }

    private var initials: String {
        let name = session.profile?.displayName ?? ""
        let parts = name.split(separator: " ").prefix(2)
        let letters = parts.compactMap { $0.first }.map(String.init).joined()
        return letters.isEmpty ? "?" : letters
    }

    private var aboutSection: some View {
        Section {
            VStack(spacing: 12) {
                SahiLogoView(size: 84)
                Text(verbatim: "סח״י – סיירת חסד ייחודית")
                    .font(.headline)
                    .foregroundStyle(Brand.navy)
                Text("„הדבר הכי גדול בעולם זה לעשות טוב למישהו אחר“")
                    .font(.subheadline)
                    .italic()
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            Link(destination: AppConfig.organizationWebsite) {
                Label("לאתר הארגון", systemImage: "safari")
            }
            LabeledContent("גרסה", value: appVersion)
        } header: {
            Text("אודות")
        } footer: {
            Text("אפליקציית מלאי משותפת למתנדבי סח״י: איסוף מזון, מעקב אחר המלאי וחלוקה למשפחות.")
        }
    }

    private var appVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "\(version) (\(build))"
    }
}

private struct DisplayNameSheet: View {
    @Environment(SessionStore.self) private var session
    @Environment(ToastCenter.self) private var toasts
    @Environment(\.dismiss) private var dismiss

    let currentName: String
    @State private var name = ""
    @State private var isSaving = false
    @State private var error: AppError?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("שם תצוגה", text: $name)
                        .textContentType(.name)
                } footer: {
                    Text("השם מופיע בהיסטוריית השינויים, כדי שכולם ידעו מי עדכן.")
                }
                if let error {
                    Text(error.localizedDescription)
                        .foregroundStyle(Brand.danger)
                }
            }
            .navigationTitle(Text("שם תצוגה"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("ביטול") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if isSaving {
                        ProgressView()
                    } else {
                        Button("שמירה") { save() }
                            .disabled(ProductNameNormalizer.displayName(name).isEmpty)
                    }
                }
            }
            .onAppear { name = currentName }
        }
    }

    private func save() {
        isSaving = true
        Task {
            defer { isSaving = false }
            do {
                try await session.updateDisplayName(name)
                toasts.show(String(localized: "השם עודכן"))
                dismiss()
            } catch {
                self.error = (error as? AppError) ?? AppError.fromGeneric(error)
            }
        }
    }
}
