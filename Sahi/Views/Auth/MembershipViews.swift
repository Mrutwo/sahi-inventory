import SwiftUI

/// Signed in but not yet a member: enter the organization's join code
/// (or wait for a coordinator to approve the account).
struct JoinView: View {
    @Environment(SessionStore.self) private var session
    let profile: UserProfile

    @State private var code = ""
    @State private var isJoining = false
    @State private var error: AppError?
    @FocusState private var codeFocused: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                SahiLogoView(size: 96)
                    .padding(.top, 24)
                VStack(spacing: 8) {
                    Text("ברוכים הבאים, \(profile.displayName)!")
                        .font(.title2.weight(.bold))
                        .foregroundStyle(Brand.navy)
                        .multilineTextAlignment(.center)
                    Text("כדי להצטרף למלאי המשותף, הזינו את קוד ההצטרפות שקיבלתם מרכז/ת המתנדבים.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                VStack(spacing: 14) {
                    TextField("קוד הצטרפות", text: $code)
                        .font(.title3.monospaced())
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.characters)
                        .autocorrectionDisabled()
                        .submitLabel(.join)
                        .onSubmit(join)
                        .focused($codeFocused)
                        .padding(14)
                        .frame(minHeight: 56)
                        .background(Brand.blueSoft, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .environment(\.layoutDirection, .leftToRight)

                    if let error {
                        StatusBanner(kind: .warning, title: error.localizedDescription)
                    }

                    Button(action: join) {
                        ProgressLabel(title: "הצטרפות", systemImage: "person.badge.plus", isLoading: isJoining)
                    }
                    .buttonStyle(.sahiPrimary)
                    .disabled(isJoining || code.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                .cardStyle(padding: 20)

                VStack(spacing: 6) {
                    Text("אין לכם קוד?")
                        .font(.subheadline.weight(.semibold))
                    Text("רכז/ת המתנדבים יכול/ה לאשר את החשבון שלכם ישירות מהאפליקציה. המסך יתעדכן אוטומטית.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }

                Button("התנתקות") {
                    Task { await session.signOut() }
                }
                .frame(minHeight: 44)
            }
            .padding(20)
            .frame(maxWidth: 520)
            .frame(maxWidth: .infinity)
        }
        .background(Brand.background.ignoresSafeArea())
        .task {
            // Pick up approval by an admin without any action from the volunteer.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                guard !Task.isCancelled else { break }
                await session.refreshProfile()
            }
        }
    }

    private func join() {
        guard !isJoining, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        isJoining = true
        error = nil
        codeFocused = false
        Task {
            defer { isJoining = false }
            do {
                try await session.join(code: code)
            } catch {
                self.error = (error as? AppError) ?? AppError.fromGeneric(error)
            }
        }
    }
}

/// Shown when an admin revoked this volunteer's access.
struct AccessRevokedView: View {
    @Environment(SessionStore.self) private var session
    let profile: UserProfile

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "person.crop.circle.badge.xmark")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text("הגישה למלאי הושבתה")
                .font(.title2.weight(.bold))
            Text("החשבון \(profile.displayName) אינו פעיל כרגע. אם זו טעות, פנו לרכז/ת המתנדבים.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button("בדיקה מחדש") {
                Task { await session.refreshProfile() }
            }
            .buttonStyle(.sahiSecondary)
            Button("התנתקות", role: .destructive) {
                Task { await session.signOut() }
            }
            .frame(minHeight: 44)
        }
        .padding(24)
        .frame(maxWidth: 480)
    }
}

/// Shown when the build has no backend configuration. Aimed at whoever sets
/// up the project, so it includes short technical instructions.
struct SetupRequiredView: View {
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Spacer()
                    SahiLogoView(size: 96)
                    Spacer()
                }
                Text("נדרשת הגדרת שרת")
                    .font(.title2.weight(.bold))
                Text("האפליקציה שומרת את המלאי בענן כדי שכל המתנדבים יראו את אותם נתונים. עדיין לא הוגדרו פרטי החיבור לשרת Supabase.")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 10) {
                    Text("להגדרה (למפתחים):")
                        .font(.headline)
                    Text("1. העתיקו את Config/Secrets.example.xcconfig לקובץ Config/Secrets.xcconfig")
                    Text("2. מלאו SUPABASE_HOST ו-SUPABASE_ANON_KEY של הפרויקט")
                    Text("3. בנו והריצו מחדש. פרטים מלאים בקובץ README.md")
                }
                .font(.callout)
                .cardStyle()
                .environment(\.layoutDirection, .rightToLeft)
            }
            .padding(24)
        }
        .background(Brand.background.ignoresSafeArea())
    }
}
